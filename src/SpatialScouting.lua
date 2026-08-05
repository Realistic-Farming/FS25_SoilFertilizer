-- =========================================================
-- FS25 Soil & Fertilizer - SPATIAL SCOUTING (SF-26)
-- =========================================================
-- Walking your crop reveals the trouble's pattern where you walked, for a
-- while. The scout fee still buys the whole field's pattern permanently, the
-- paid report still buys the name; the walked mask adds the middle rung.
--
-- THE WALKED MASK (B1): a per-farm, per-field set of walked cells. Each cell
-- records WHICH in-game day it was walked and WHAT was there when it was
-- walked (a sampled truth value). The mask is:
--   - PER-FARM SERVER STATE in its OWN home (LAW 2): never on fieldData,
--     never on another owner's state.
--   - Delivered to clients through NetworkSync's dirty-flag pattern (LAW 3):
--     each synced entry carries {cell, walkDay, sampledTruth}, so a client
--     composes from the payload, never from the gated mirrors.
--   - AGED by a Time Guard day tick (each cell fades after N in-game days).
--   - DELEGATE-WHEN-PRESENT: with any of the three services absent it degrades
--     to the STANDALONE FALLBACK (session-transient, client-local buffer),
--     behaviourally identical minus persistence, sharing and aging.
--
-- THE COMPOSE (B2): on the disease display, where a field is DISCOVERED the
-- gate paints truth as it already does. Where undiscovered, the gate paints
-- the UNKNOWN marker, EXCEPT inside the mask's fresh cells, which paint their
-- sampled truth. The mask only ever ADDS; nothing becomes transparent.
--
-- THE SAMPLER (LAW 1 + LAW 4): only on foot (a vehicle or implement never
-- reveals), server-side against the server's authoritative player position,
-- farm resolved from the server's player record, never from client-reported
-- cells or a wire-supplied farm id.
-- =========================================================
-- Author: TisonK
-- =========================================================

SpatialScouting = {}

-- Age limit default. The brief says "N in XML, ratio-pass-tuned, never infinite
-- by default". The ratio pass has not run; this is the flagged placeholder, one
-- line to move to SettingsSchema when it does. A cell walked more than this many
-- in-game days ago no longer paints truth.
SpatialScouting.AGE_DAYS = 7

-- The cell key is ENCODED FROM LIVE POSITIONS ONLY (the never-decode
-- discipline). We never decode a key back into coordinates; the walk sample
-- keeps the live world position alongside the key so painting never has to
-- reverse the encoding (the standing cx*10000+cz collision hazard).
---@param worldX number
---@param worldZ number
---@return string cellKey
function SpatialScouting.cellKey(worldX, worldZ)
    local cell = SoilConstants.ZONE.CELL_SIZE
    local cx = math.floor((worldX or 0) / cell)
    local cz = math.floor((worldZ or 0) / cell)
    return tostring(cx * 10000 + cz)
end

function SpatialScouting.new()
    return setmetatable({
        armed = false,
        stoodDown = false,
        -- masks[farmId][fieldId][cellKey] = { day, truth, x, z, gen }
        masks = {},
        -- generations[farmId][fieldId] = number: the field's knowledge epoch.
        -- Bumped when a fresh infection re-hides a field that was scouted, so
        -- walks from before the re-hide never resurrect (acceptance criterion 4:
        -- "the mask composes with CURRENT truth only").
        generations = {},
        -- seenDiscovered[farmId][fieldId] = last diseaseDiscovered we observed,
        -- so the mask can detect the scouted->re-hidden transition without
        -- touching the disease system's own re-hide logic (B3).
        seenDiscovered = {},
        ageLimitDays = SpatialScouting.AGE_DAYS,
        -- last day the aging pass ran, for catch-up safety
        agedThroughDay = nil,
    }, { __index = SpatialScouting })
end

function SpatialScouting:isArmed()
    return self.armed and not self.stoodDown
end

---@return boolean
function SpatialScouting:arm(valueMaps, ageLimitDays)
    self.armed = false
    self.valueMaps = nil
    if g_server == nil then
        -- The mask is server-authoritative. On a client it exists only to hold
        -- the synced payload (LAW 3); sampling stays off. This is not an error.
        self.armed = true
        return true
    end
    if valueMaps == nil or not valueMaps.available then
        SoilLogger.warning("[SpatialScouting] value maps unavailable - WALKED MASK stands down")
        return false
    end
    if valueMaps.readValueAtWorld == nil or valueMaps.writeValueAtWorld == nil then
        SoilLogger.warning("[SpatialScouting] the SoilValueMaps in scope lacks the read/write API - stands down")
        return false
    end
    self.valueMaps = valueMaps
    if type(ageLimitDays) == "number" and ageLimitDays > 0 then
        self.ageLimitDays = ageLimitDays
    end
    self.armed = true
    SoilLogger.info("[OK] SpatialScouting walked mask armed (age limit %d in-game days)", self.ageLimitDays)
    return true
end

---@return boolean
function SpatialScouting:isStandalone()
    -- True when the mask must live without the bedrock services: no persistence,
    -- no sharing, no aging. The mask still works in-memory; it simply does not
    -- fade and does not survive a reload.
    local tg = g_currentMission and g_currentMission.timeGuard
    local ledger = g_currentMission and g_currentMission.stateLedger
    local ns = (g_currentMission and g_currentMission.networkSync) or g_networkSync
    return tg == nil or ledger == nil or ns == nil
end

-- =========================================================
-- The mask itself (pure, testable)
-- =========================================================

--- Record a walked cell. Server-side sampler entry point.
--- Dedup: a re-walk of the same cell refreshes walkDay and re-samples truth
--- (the player is there again, so the older sample is stale by definition).
---@param farmId number
---@param fieldId number
---@param cellKey string
---@param day number   in-game day the walk happened
---@param truth number sampled truth value at walk time
---@param worldX number live position kept for painting (never decoded from key)
---@param worldZ number
function SpatialScouting:noteWalk(farmId, fieldId, cellKey, day, truth, worldX, worldZ)
    if not self:isArmed() then return false end
    local farm = self.masks[farmId]
    if farm == nil then farm = {}; self.masks[farmId] = farm end
    local field = farm[fieldId]
    if field == nil then field = {}; farm[fieldId] = field end
    local gen = (self.generations[farmId] or {})[fieldId] or 0
    field[cellKey] = { day = day or 0, truth = truth or 0, x = worldX, z = worldZ, gen = gen }
    return true
end

--- THE KNOWLEDGE-GENERATION BOOKKEEPING (acceptance criterion 4). The mask must
--- compose with CURRENT truth only: when a fresh infection re-hides a field that
--- was scouted, walks made before the re-hide must not resurrect. We detect that
--- scouted->re-hidden transition here, in the mask's own home, WITHOUT touching
--- the disease system's re-hide logic (B3). A walk records the generation it was
--- made under; compose ignores cells from an older generation.
---@param farmId number
---@param fieldId number
---@param fieldDiscovered boolean the field's current diseaseDiscovered
function SpatialScouting:_observeDiscovery(farmId, fieldId, fieldDiscovered)
    local genTable = self.generations[farmId]
    if genTable == nil then genTable = {}; self.generations[farmId] = genTable end
    local seenTable = self.seenDiscovered[farmId]
    if seenTable == nil then seenTable = {}; self.seenDiscovered[farmId] = seenTable end

    local was = seenTable[fieldId]
    if was == true and fieldDiscovered == false then
        -- Scouted -> re-hidden: a fresh infection. All prior walks are dead.
        genTable[fieldId] = (genTable[fieldId] or 0) + 1
    elseif genTable[fieldId] == nil then
        genTable[fieldId] = 0
    end
    seenTable[fieldId] = fieldDiscovered
end

--- The mask entry for a cell, or nil.
---@param farmId number
---@param fieldId number
---@param cellKey string
---@return table|nil
function SpatialScouting:maskEntry(farmId, fieldId, cellKey)
    local farm = self.masks[farmId]
    if farm == nil then return nil end
    local field = farm[fieldId]
    if field == nil then return nil end
    return field[cellKey]
end

--- Is a cell in the mask AND fresh (walked within the age window) AND of the
--- field's current knowledge generation? Freshness is age; generation is the
--- re-hide gate.
---@param farmId number
---@param fieldId number
---@param cellKey string
---@param currentDay number
---@return boolean
function SpatialScouting:isFresh(farmId, fieldId, cellKey, currentDay)
    local e = self:maskEntry(farmId, fieldId, cellKey)
    if e == nil then return false end
    if (currentDay or 0) - e.day > self.ageLimitDays then return false end
    local gen = (self.generations[farmId] or {})[fieldId] or 0
    return e.gen == gen
end

--- THE COMPOSE READ (B2). Given what the gate would paint, decide what to paint.
---
--- Truth table:
---   field discovered            -> baseShown (the gate's truth, whole field)
---   undiscovered, cell fresh    -> the mask's sampled truth
---   undiscovered, cell not fresh-> baseShown (the gate's UNKNOWN marker)
---
--- "The mask only ever adds; nothing becomes transparent."
---@param farmId number
---@param fieldId number
---@param cellKey string
---@param currentDay number
---@param baseShown number what the discovery gate already decided (may be the
---        UNKNOWN sentinel < 0 for undiscovered ground)
---@param fieldDiscovered boolean true when the field's whole pattern is known
---@return number value to paint
function SpatialScouting:composeShown(farmId, fieldId, cellKey, currentDay, baseShown, fieldDiscovered)
    if fieldDiscovered then
        self:_observeDiscovery(farmId, fieldId, true)
        return baseShown
    end
    self:_observeDiscovery(farmId, fieldId, false)
    if not self:isFresh(farmId, fieldId, cellKey, currentDay) then return baseShown end
    local e = self:maskEntry(farmId, fieldId, cellKey)
    if e == nil then return baseShown end
    return e.truth
end

--- World-coordinate compose helper for the map surfaces. Encodes the cell key
--- from the live position (never decode) and delegates to composeShown.
---@param farmId number
---@param fieldId number
---@param worldX number
---@param worldZ number
---@param currentDay number
---@param baseShown number
---@param fieldDiscovered boolean
---@return number value to paint
function SpatialScouting:composeAtWorld(farmId, fieldId, worldX, worldZ, currentDay, baseShown, fieldDiscovered)
    local key = SpatialScouting.cellKey(worldX, worldZ)
    return self:composeShown(farmId, fieldId, key, currentDay, baseShown, fieldDiscovered)
end

-- =========================================================
-- Aging (Time Guard day tick). NON-MONEY by the Time Guard fence.
-- =========================================================

--- Fade every cell walked more than ageLimitDays ago. IDEMPOTENT and
--- CATCH-UP-SAFE: it compares absolute days, never a running delta, so a
--- retried or skipped day can neither double-fade nor miss a cell.
---@param throughDay number the in-game day the tick is settling
---@return number removedCells
function SpatialScouting:age(throughDay)
    if not self:isArmed() then return 0 end
    if throughDay == nil then return 0 end
    if self.agedThroughDay ~= nil and throughDay <= self.agedThroughDay then
        return 0   -- idempotency: never re-fade a day already faded
    end
    self.agedThroughDay = throughDay

    local removed = 0
    local limit = self.ageLimitDays
    for farmId, farm in pairs(self.masks) do
        for fieldId, field in pairs(farm) do
            for cellKey, e in pairs(field) do
                if throughDay - e.day > limit then
                    field[cellKey] = nil
                    removed = removed + 1
                end
            end
            if next(field) == nil then farm[fieldId] = nil end
        end
        if next(farm) == nil then self.masks[farmId] = nil end
    end
    return removed
end

--- Enumerate a field's FRESH cells (for the display overlay).
---@param farmId number
---@param fieldId number
---@param currentDay number
---@param visitor function(cellKey, entry) called per fresh cell
function SpatialScouting:enumerateFresh(farmId, fieldId, currentDay, visitor)
    local farm = self.masks[farmId]
    if farm == nil then return end
    local field = farm[fieldId]
    if field == nil then return end
    local gen = (self.generations[farmId] or {})[fieldId] or 0
    for cellKey, e in pairs(field) do
        if (currentDay or 0) - e.day <= self.ageLimitDays and e.gen == gen then
            visitor(cellKey, e)
        end
    end
end

--- Paint a field's fresh walked cells onto the diseasePressure display layer.
--- Server-side (the value maps are server-authoritative). Only called for
--- UNDISCOVERED fields; for a discovered field the gate paints truth everywhere
--- and the older sampled values must not fight the live ones.
---@param farmId number
---@param fieldId number
---@param currentDay number
---@return number paintedCells
function SpatialScouting:overlayField(farmId, fieldId, currentDay)
    if g_server == nil or self.valueMaps == nil then return 0 end
    local half = SoilConstants.ZONE.CELL_SIZE * 0.5
    local painted = 0
    self:enumerateFresh(farmId, fieldId, currentDay, function(_cellKey, e)
        if e.x ~= nil and e.z ~= nil then
            self.valueMaps:writeValueAtWorld("diseasePressure", e.x, e.z, e.truth, half)
            painted = painted + 1
        end
    end)
    return painted
end

-- =========================================================
-- Persistence (StateLedger sidecar; merge-never-replace)
-- =========================================================

---@return table
function SpatialScouting:serialize()
    return {
        schema = 1,
        ageLimitDays = self.ageLimitDays,
        masks = self.masks,
        generations = self.generations,
    }
end

--- MERGE, never replace. StateLedger OMITS a block when serialize fails and
--- cannot tell an omitted block from a brand-new save (it decides resume-vs-
--- defaults purely on data ~= nil). A replace-on-nil would wipe the whole
--- walked mask after one bad save.
---@param data table|nil
---@return boolean
function SpatialScouting:deserialize(data)
    if type(data) ~= "table" then return false end
    if type(data.ageLimitDays) == "number" and data.ageLimitDays > 0 then
        self.ageLimitDays = data.ageLimitDays
    end
    if type(data.generations) == "table" then
        for farmId, g in pairs(data.generations) do
            local target = self.generations[farmId] or {}
            for fieldId, gen in pairs(g) do
                if (target[fieldId] or 0) < gen then target[fieldId] = gen end
            end
            self.generations[farmId] = target
        end
    end
    if type(data.masks) ~= "table" then return false end
    for farmId, farm in pairs(data.masks) do
        local targetFarm = self.masks[farmId]
        if targetFarm == nil then targetFarm = {}; self.masks[farmId] = targetFarm end
        for fieldId, field in pairs(farm) do
            local targetField = targetFarm[fieldId]
            if targetField == nil then targetField = {}; targetFarm[fieldId] = targetField end
            for cellKey, e in pairs(field) do
                -- A re-walk in the running session beats the saved sample.
                if targetField[cellKey] == nil then
                    targetField[cellKey] = { day = e.day, truth = e.truth, x = e.x, z = e.z, gen = e.gen or 0 }
                end
            end
        end
    end
    return true
end

-- =========================================================
-- The sampler (server-side, on foot only, LAW 1 + LAW 4)
-- =========================================================

--- Sample one player's on-foot position into the walked mask.
--- Server-authoritative: the farm comes from the server's player record
--- (player.farmId), never from a wire-supplied value. The truth is read from
--- the value maps at the player's position; when the map has no value there,
--- the field average stands in (a sampled truth is better than none and the
--- cell is still walked).
---@param player table  a Player from g_currentMission.players
---@param currentDay number
---@return boolean walked
function SpatialScouting:_samplePlayer(player, currentDay)
    if player == nil then return false end
    -- LAW 1: on foot only.
    if type(player.getIsInVehicle) == "function" then
        local ok, inVeh = pcall(function() return player:getIsInVehicle() end)
        if ok and inVeh then return false end
    end

    local px, pz
    if type(player.getPosition) == "function" then
        local ok, x, _, z = pcall(function() return player:getPosition() end)
        if ok then px, pz = x, z end
    end
    if px == nil and player.rootNode then
        local ok, x, _, z = pcall(getWorldTranslation, player.rootNode)
        if ok then px, pz = x, z end
    end
    if px == nil then return false end

    -- Resolve the field under the player (LAW 4: server-side, from the server's
    -- authoritative world, not client-reported cells).
    local fieldId
    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
        local ok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(px, pz) end)
        if ok and f and f.farmland and f.farmland.id then fieldId = f.farmland.id end
    end
    if not fieldId and g_farmlandManager and type(g_farmlandManager.getFarmlandAtWorldPosition) == "function" then
        local ok, land = pcall(function() return g_farmlandManager:getFarmlandAtWorldPosition(px, pz) end)
        if ok and land and land.id and land.id > 0 then fieldId = land.id end
    end
    if not fieldId then return false end   -- not on a field: nothing to scout

    -- Farm from the server's player record.
    local farmId = player.farmId
    if farmId == nil or farmId <= 0 then
        if g_currentMission and type(g_currentMission.getFarmId) == "function" then
            farmId = g_currentMission:getFarmId()
        end
    end
    if farmId == nil or farmId <= 0 then farmId = 1 end

    -- Sample the truth at walk time.
    local truth = 0
    if self.valueMaps then
        local v = self.valueMaps:readValueAtWorld("diseasePressure", px, pz)
        if v ~= nil then truth = v end
    end
    if truth <= 0 then
        local field = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
            and g_SoilFertilityManager.soilSystem.fieldData and g_SoilFertilityManager.soilSystem.fieldData[fieldId]
        if field and field.diseasePressure then truth = field.diseasePressure end
    end

    local key = SpatialScouting.cellKey(px, pz)
    return self:noteWalk(farmId, fieldId, key, currentDay, truth, px, pz)
end

--- Per-frame server sampling. Iterates the server's authoritative player list;
--- each on-foot player who is inside a field fills their farm's mask. When a
--- walk lands, flags the NetworkSync module dirty so the next 1Hz batch carries
--- the fresh cells to that farm's clients (LAW 3).
---@param currentDay number
---@return number sampled
function SpatialScouting:onUpdate(currentDay)
    if g_server == nil or not self:isArmed() then return 0 end
    local players = g_currentMission and g_currentMission.players
    if players == nil then return 0 end
    local sampled = 0
    for _, player in pairs(players) do
        if self:_samplePlayer(player, currentDay) then sampled = sampled + 1 end
    end
    if sampled > 0 and SoilScoutingBridge and SoilScoutingBridge.markDirty then
        SoilScoutingBridge.markDirty()
    end
    return sampled
end

--- [SF-37] THE KNEEL: the active, precise reveal verb. One cell written to the
--- walked mask, server-side, exactly like a walk but explicit. THE KNOWLEDGE
--- SPLIT holds: only the disease-knowledge cell is written; soil facts are the
--- player's own ground and need no reveal.
---
--- LAW 4: the client key press is a REQUEST, never a reported cell. The request
--- carries the spot (x, z); the server resolves the FARM from the requesting
--- player's record (via the connection, supplied by the event's run), samples
--- the truth server-side at that spot, and writes. The farm is never taken from
--- the wire.
---@param connection table|nil the client connection (nil on the host/SP)
---@param x number
---@param z number
---@param currentDay number
---@return boolean written
function SpatialScouting:revealCellAt(connection, x, z, currentDay)
    if g_server == nil or not self:isArmed() then return false end
    if x == nil or z == nil then return false end

    -- Resolve the requesting player from the connection (LAW 4). On the host or
    -- in SP the connection is nil and the local player is authoritative.
    local player = nil
    if connection ~= nil and g_currentMission and g_currentMission.playerSystem
       and type(g_currentMission.playerSystem.getPlayerByConnection) == "function" then
        local ok, p = pcall(function()
            return g_currentMission.playerSystem:getPlayerByConnection(connection)
        end)
        if ok then player = p end
    end
    if player == nil then player = g_localPlayer end
    if player == nil then return false end

    -- The field is resolved SERVER-SIDE at the spot, never from the wire.
    local fieldId
    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
        local ok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(x, z) end)
        if ok and f and f.farmland and f.farmland.id then fieldId = f.farmland.id end
    end
    if not fieldId and g_farmlandManager and type(g_farmlandManager.getFarmlandAtWorldPosition) == "function" then
        local ok, land = pcall(function() return g_farmlandManager:getFarmlandAtWorldPosition(x, z) end)
        if ok and land and land.id and land.id > 0 then fieldId = land.id end
    end
    if not fieldId then return false end   -- not on a field: nothing to reveal

    -- Farm from the player record, exactly as the walk sampler does.
    local farmId = player.farmId
    if farmId == nil or farmId <= 0 then
        if g_currentMission and type(g_currentMission.getFarmId) == "function" then
            farmId = g_currentMission:getFarmId()
        end
    end
    if farmId == nil or farmId <= 0 then farmId = 1 end

    -- Sample the truth server-side at kneel time (LAW 3: sampled at reveal time).
    local truth = 0
    if self.valueMaps then
        local v = self.valueMaps:readValueAtWorld("diseasePressure", x, z)
        if v ~= nil then truth = v end
    end
    if truth <= 0 then
        local field = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
            and g_SoilFertilityManager.soilSystem.fieldData and g_SoilFertilityManager.soilSystem.fieldData[fieldId]
        if field and field.diseasePressure then truth = field.diseasePressure end
    end

    local key = SpatialScouting.cellKey(x, z)
    local ok = self:noteWalk(farmId, fieldId, key, currentDay, truth, x, z)
    if ok and SoilScoutingBridge and SoilScoutingBridge.markDirty then
        SoilScoutingBridge.markDirty()
    end
    return ok
end
