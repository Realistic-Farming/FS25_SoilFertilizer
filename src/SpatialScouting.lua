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

SpatialScouting = SpatialScouting or {}

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

-- =========================================================
-- [SF-22] FARM-PRIVATE AUTHORISATION (pure, testable)
-- =========================================================

--- An ordinary farm is one of the eight playable farms. The base game pins the
--- range at FarmManager: SPECTATOR 0, MAX_NUM_FARMS 8, GUIDED_TOUR 14, INVALID
--- 15. Spectator, guided-tour, invalid, nil and any non-integer reject - only an
--- ordinary farm may own walked knowledge.
---@param farmId any
---@return boolean
function SpatialScouting.isOrdinaryFarmId(farmId)
    return type(farmId) == "number"
        and farmId == math.floor(farmId)
        and farmId >= 1
        and farmId <= 8
end

--- The reveal gate (LAW 2, farm-private). A walk or kneel may write a cell only
--- when the walking farm owns the land, or is actively contracting the owner's
--- land. Both ids must be ordinary; an unrelated neighbour reveals nothing.
---@param playerFarmId any         the walking player's farm (server player record)
---@param ownerFarmId any          g_farmlandManager:getFarmlandOwner(farmlandId)
---@param contractingForOwner any  farm:getIsContractingFor(ownerFarmId)
---@return boolean
function SpatialScouting.isRevealAuthorized(playerFarmId, ownerFarmId, contractingForOwner)
    if not SpatialScouting.isOrdinaryFarmId(playerFarmId) then return false end
    if not SpatialScouting.isOrdinaryFarmId(ownerFarmId) then return false end
    return playerFarmId == ownerFarmId or contractingForOwner == true
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
    -- [SF-22] Report transport-dirty ONLY on a material change: a new cell, or a
    -- changed walk day, sampled truth or knowledge generation. A re-walk of the
    -- same cell on the same day with the same truth and generation writes the
    -- same bytes and must not put a DELTA on the wire.
    local newDay, newTruth = day or 0, truth or 0
    local prev = field[cellKey]
    local changed = prev == nil
        or prev.day ~= newDay
        or prev.truth ~= newTruth
        or (prev.gen or 0) ~= gen
    field[cellKey] = { day = newDay, truth = newTruth, x = worldX, z = worldZ, gen = gen }
    return changed
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

--- Resolve the farmland id under a world position, server-side (LAW 4), from the
--- authoritative world and never from a client-reported cell. The walked mask
--- keys on the farmland id, so this is the field key a walk or kneel fills.
---@param x number
---@param z number
---@return number|nil farmlandId
function SpatialScouting:_resolveFarmlandAt(x, z)
    local fieldId
    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
        local ok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(x, z) end)
        if ok and f and f.farmland and f.farmland.id then fieldId = f.farmland.id end
    end
    if not fieldId and g_farmlandManager and type(g_farmlandManager.getFarmlandAtWorldPosition) == "function" then
        local ok, land = pcall(function() return g_farmlandManager:getFarmlandAtWorldPosition(x, z) end)
        if ok and land and land.id and land.id > 0 then fieldId = land.id end
    end
    return fieldId
end

--- [SF-22] Is a farm allowed to reveal this land? Resolves the land owner and
--- the walking farm's contract state server-side, then applies the reveal gate.
--- Every id is the server's own truth; nothing is taken from the wire.
---@param playerFarmId number  the walking farm (already known ordinary)
---@param farmlandId number
---@return boolean
function SpatialScouting._isWalkAuthorized(playerFarmId, farmlandId)
    local ownerFarmId = nil
    if g_farmlandManager and type(g_farmlandManager.getFarmlandOwner) == "function" then
        local ok, owner = pcall(function() return g_farmlandManager:getFarmlandOwner(farmlandId) end)
        if ok then ownerFarmId = owner end
    end
    local contractingForOwner = false
    if SpatialScouting.isOrdinaryFarmId(ownerFarmId)
       and g_farmManager and type(g_farmManager.getFarmById) == "function" then
        local ok, farm = pcall(function() return g_farmManager:getFarmById(playerFarmId) end)
        if ok and farm and type(farm.getIsContractingFor) == "function" then
            local ok2, res = pcall(function() return farm:getIsContractingFor(ownerFarmId) end)
            if ok2 then contractingForOwner = res == true end
        end
    end
    return SpatialScouting.isRevealAuthorized(playerFarmId, ownerFarmId, contractingForOwner)
end

--- Sample the disease truth at a spot. The value map answers first; the field
--- average stands in when the map has no value there (a sampled truth is better
--- than none and the cell is still walked).
---@param x number
---@param z number
---@param farmlandId number
---@return number truth
function SpatialScouting:_sampleTruthAt(x, z, farmlandId)
    local truth = 0
    if self.valueMaps then
        local v = self.valueMaps:readValueAtWorld("diseasePressure", x, z)
        if v ~= nil then truth = v end
    end
    if truth <= 0 then
        local field = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
            and g_SoilFertilityManager.soilSystem.fieldData
            and g_SoilFertilityManager.soilSystem.fieldData[farmlandId]
        if field and field.diseasePressure then truth = field.diseasePressure end
    end
    return truth
end

--- Sample one player's on-foot position into the walked mask.
--- Server-authoritative: the farm comes from the server's player record
--- (player.farmId), never from a wire-supplied value or a farm-1 fallback. The
--- truth is read only AFTER the reveal gate passes, so an unrelated neighbour
--- walk reads nothing and writes nothing.
---@param player table  a Player from g_currentMission.players
---@param currentDay number
---@return boolean changed, number|nil farmId, number|nil farmlandId, string|nil cellKey
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

    local farmlandId = self:_resolveFarmlandAt(px, pz)
    if not farmlandId then return false end   -- not on a field: nothing to scout

    -- [SF-22] The walking farm comes straight from the server's player record.
    -- No getFarmId() and no farm-1 fallback: an unresolved or non-ordinary farm
    -- is not a farm that may learn anything.
    local playerFarmId = player.farmId
    if not SpatialScouting.isOrdinaryFarmId(playerFarmId) then return false end

    -- [SF-22] Authorise BEFORE any truth read (LAW 2).
    if not SpatialScouting._isWalkAuthorized(playerFarmId, farmlandId) then
        return false
    end

    local truth = self:_sampleTruthAt(px, pz, farmlandId)
    local key = SpatialScouting.cellKey(px, pz)
    local changed = self:noteWalk(playerFarmId, farmlandId, key, currentDay, truth, px, pz)
    return changed, playerFarmId, farmlandId, key
end

--- Per-frame server sampling. Iterates the server's authoritative player list;
--- each on-foot player inside their own (or a contracted) field fills that
--- farm's mask. Changed cells are grouped by farm and each farm's group is
--- handed to the DELTA sender, so a farm's fresh cells reach only that farm's
--- own remote teammates (LAW 3, farm-private). Another farm receives nothing.
---@param currentDay number
---@return number sampled
function SpatialScouting:onUpdate(currentDay)
    if g_server == nil or not self:isArmed() then return 0 end
    local players = g_currentMission and g_currentMission.players
    if players == nil then return 0 end
    local sampled = 0
    local changedByFarm = nil
    for _, player in pairs(players) do
        local changed, farmId, farmlandId, cellKey = self:_samplePlayer(player, currentDay)
        if changed then
            sampled = sampled + 1
            changedByFarm = changedByFarm or {}
            local list = changedByFarm[farmId]
            if list == nil then list = {}; changedByFarm[farmId] = list end
            list[#list + 1] = { fieldId = farmlandId, cellKey = cellKey }
        end
    end
    if changedByFarm and SoilScoutingBridge and SoilScoutingBridge.sendFarmDelta then
        for farmId, list in pairs(changedByFarm) do
            SoilScoutingBridge.sendFarmDelta(self, farmId, list)
        end
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

    -- The farmland is resolved SERVER-SIDE at the spot, never from the wire.
    local farmlandId = self:_resolveFarmlandAt(x, z)
    if not farmlandId then return false end   -- not on a field: nothing to reveal

    -- [SF-22] Farm from the player record; no getFarmId() and no farm-1 fallback.
    local playerFarmId = player.farmId
    if not SpatialScouting.isOrdinaryFarmId(playerFarmId) then return false end

    -- [SF-22] Authorise BEFORE the truth read, exactly as the walk sampler does:
    -- the kneeling farm must own this land or be contracting its owner (LAW 2).
    if not SpatialScouting._isWalkAuthorized(playerFarmId, farmlandId) then
        return false
    end

    -- Sample the truth server-side at kneel time (LAW 3: sampled at reveal time).
    local truth = self:_sampleTruthAt(x, z, farmlandId)

    local key = SpatialScouting.cellKey(x, z)
    local changed = self:noteWalk(playerFarmId, farmlandId, key, currentDay, truth, x, z)
    if changed and SoilScoutingBridge and SoilScoutingBridge.sendFarmDelta then
        SoilScoutingBridge.sendFarmDelta(self, playerFarmId, { { fieldId = farmlandId, cellKey = key } })
    end
    return changed
end
