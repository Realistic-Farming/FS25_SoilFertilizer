-- =========================================================
-- FS25 Soil & Fertilizer - SPATIAL SCOUTING bridges (SF-26)
-- =========================================================
-- Three optional-mod bridges for the walked mask, kept together because they
-- are its only outside contact:
--
--   1. TIME GUARD - one day-cadence aging accrual (NON-MONEY, the Time Guard
--      fence). Each walked cell fades after N in-game days.
--   2. STATE LEDGER - the mask sidecar, delegate-when-present with an own-XML
--      fallback.
--   3. NETWORK SYNC - farm-scoped delivery of the mask payload (LAW 3: each
--      entry carries {cell, walkDay, sampledTruth} so a client composes from
--      the payload, never from the gated mirrors).
--
-- All three are strictly delegate-when-present. When ANY is absent the mask
-- degrades to the STANDALONE FALLBACK (session-transient, client-local):
-- behaviourally identical minus persistence, sharing and aging.
-- =========================================================
-- Author: TisonK
-- =========================================================

SoilScoutingBridge = SoilScoutingBridge or {}

-- =========================================================
-- Time Guard
-- =========================================================

SoilScoutingBridge.ACCRUAL_AGE = "SoilFertilizer_SpatialScouting_age"

-- Settles on its own priority slot. The ground-material package owns 10-40; the
-- walked mask is independent of that family's ordering, so a dedicated slot
-- keeps it from being pushed around by a sibling's day. NON-MONEY: flowClass
-- "calendar", exactly like the MaterialDown accruals.
SoilScoutingBridge.PRIORITY_AGE = 5

local function getTimeGuard()
    return (g_currentMission ~= nil and g_currentMission.timeGuard) or nil
end

--- Register the aging accrual. Server only (the mask is server-authoritative).
--- firstPeriodPolicy = "skip": the scheduler's silent default is "prorate",
--- which would retroactively age cells the mod happened to load in with.
---@param spatialScouting SpatialScouting|nil
---@return boolean registered
function SoilScoutingBridge.registerAccruals(spatialScouting)
    if spatialScouting == nil then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[SpatialScouting] Time Guard not detected - walked cells never fade")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilScoutingBridge.ACCRUAL_AGE, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilScoutingBridge.PRIORITY_AGE,
            onSettle          = function(ctx)
                spatialScouting:age(ctx and tonumber(ctx.monotonicDay))
            end,
        })
    end)

    if not ok then
        SoilLogger.warning("[SpatialScouting] Time Guard registration failed: %s", tostring(err))
        return false
    end
    if not okReg then
        SoilLogger.warning("[SpatialScouting] Time Guard rejected the aging accrual")
        return false
    end
    SoilLogger.info("[OK] SpatialScouting registered its day aging accrual (skip, prio %d)",
        SoilScoutingBridge.PRIORITY_AGE)
    return true
end

function SoilScoutingBridge.unregisterAccruals()
    local tg = getTimeGuard()
    if tg == nil or tg.unregisterAccrual == nil then return end
    pcall(function() tg:unregisterAccrual(SoilScoutingBridge.ACCRUAL_AGE) end)
end

-- =========================================================
-- State Ledger sidecar
-- =========================================================

SoilScoutingBridge.MODULE_ID = "SoilFertilizer_SpatialScouting"
SoilScoutingBridge.XML_FILE  = "sfSpatialScouting.xml"
SoilScoutingBridge.ledgerActive = false

local function getLedger()
    return (g_currentMission ~= nil and g_currentMission.stateLedger) or nil
end

local function xmlPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
       or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. SoilScoutingBridge.XML_FILE
end

--- Register the sidecar with StateLedger when present. deserialize MERGES on
--- the far side (SpatialScouting:deserialize is merge-never-replace), so an
--- omitted block can never wipe the mask.
---@param spatialScouting SpatialScouting|nil
---@return boolean registered
function SoilScoutingBridge.registerLedger(spatialScouting)
    SoilScoutingBridge.ledgerActive = false
    if spatialScouting == nil then return false end
    if g_server == nil then return false end

    local ledger = getLedger()
    if ledger == nil or ledger.registerModule == nil then
        SoilLogger.info("[SpatialScouting] StateLedger not detected - using %s",
            SoilScoutingBridge.XML_FILE)
        return false
    end

    local ok, err = pcall(function()
        ledger:registerModule(SoilScoutingBridge.MODULE_ID, {
            serialize   = function() return spatialScouting:serialize() end,
            deserialize = function(data)
                if data ~= nil then spatialScouting:deserialize(data) end
            end,
        })
    end)

    if not ok then
        SoilLogger.warning("[SpatialScouting] StateLedger registration failed: %s (using %s)",
            tostring(err), SoilScoutingBridge.XML_FILE)
        return false
    end

    SoilScoutingBridge.ledgerActive = true
    SoilLogger.info("[OK] SpatialScouting registered with StateLedger as '%s'",
        SoilScoutingBridge.MODULE_ID)
    return true
end

--- Own-XML fallback save. Runs only when StateLedger is absent.
---@param spatialScouting SpatialScouting|nil
function SoilScoutingBridge.saveFallback(spatialScouting)
    if spatialScouting == nil or SoilScoutingBridge.ledgerActive then return end
    if g_server == nil then return end
    local path = xmlPath()
    if path == nil or createXMLFile == nil then return end

    local state = spatialScouting:serialize()
    local ok, err = pcall(function()
        local xmlFile = createXMLFile("sfSpatialScouting", path, "spatialScouting")
        if xmlFile == nil then return end
        setXMLInt(xmlFile, "spatialScouting#schema", state.schema or 1)
        setXMLInt(xmlFile, "spatialScouting#ageLimitDays", state.ageLimitDays or SpatialScouting.AGE_DAYS)
        local maskXML = xmlFile:createChild("spatialScouting", "masks")
        for farmId, farm in pairs(state.masks or {}) do
            for fieldId, field in pairs(farm) do
                for cellKey, e in pairs(field) do
                    local cell = maskXML:createChild("masks", "cell")
                    cell:setInt("cell#farmId", farmId)
                    cell:setInt("cell#fieldId", fieldId)
                    cell:setString("cell#key", cellKey)
                    cell:setInt("cell#day", e.day or 0)
                    cell:setFloat("cell#truth", e.truth or 0)
                    cell:setFloat("cell#x", e.x or 0)
                    cell:setFloat("cell#z", e.z or 0)
                end
            end
        end
        saveXMLFile(xmlFile)
        delete(xmlFile)
    end)
    if not ok then
        SoilLogger.warning("[SpatialScouting] fallback save failed: %s", tostring(err))
    end
end

--- Own-XML fallback load. Merges through SpatialScouting:deserialize.
---@param spatialScouting SpatialScouting|nil
function SoilScoutingBridge.loadFallback(spatialScouting)
    if spatialScouting == nil or SoilScoutingBridge.ledgerActive then return end
    if g_server == nil then return end
    local path = xmlPath()
    if path == nil or loadXMLFile == nil or fileExists == nil or not fileExists(path) then return end

    local ok, err = pcall(function()
        local xmlFile = loadXMLFile("sfSpatialScouting", path)
        if xmlFile == nil then return end
        local age = xmlFile:getInt("spatialScouting#ageLimitDays")
        local masks = {}
        local maskXML = xmlFile:getChild("spatialScouting", "masks")
        if maskXML ~= nil then
            for cell in maskXML:getChildren("masks", "cell") do
                -- [SF-22] A missing/non-ordinary farm id, missing field id or empty
                -- cell key skips that cell. NEVER `farmId or 1`: a malformed row
                -- must not deposit stray knowledge under farm 1.
                local farmId  = cell:getInt("cell#farmId")
                local fieldId = cell:getInt("cell#fieldId")
                local cellKey = cell:getString("cell#key")
                if SpatialScouting.isOrdinaryFarmId(farmId)
                   and type(fieldId) == "number"
                   and type(cellKey) == "string" and cellKey ~= "" then
                    local farm     = masks[farmId] or {}
                    local field    = farm[fieldId] or {}
                    field[cellKey] = {
                        day   = cell:getInt("cell#day") or 0,
                        truth = cell:getFloat("cell#truth") or 0,
                        x     = cell:getFloat("cell#x") or 0,
                        z     = cell:getFloat("cell#z") or 0,
                    }
                    farm[fieldId] = field
                    masks[farmId] = farm
                end
            end
        end
        delete(xmlFile)
        local data = { schema = 1, ageLimitDays = age, masks = masks }
        spatialScouting:deserialize(data)
    end)
    if not ok then
        SoilLogger.warning("[SpatialScouting] fallback load failed: %s", tostring(err))
    end
end

-- =========================================================
-- [SF-22] Farm-private mask transport (host-owned event route)
-- =========================================================
-- NetworkSync cannot express "send farm X's bytes only to farm X", so the
-- walked mask rides SoilFertilizer's own server-authoritative event route
-- (SoilScoutingMaskSyncEvent / SoilScoutingMaskRequestEvent, in
-- NetworkEvents.lua). This module owns the pure serialisation, the remote-
-- teammate selector, the client-side apply/buffer, and the pure-client
-- farm-switch subscriber. Another farm never receives a byte of this mask.

SoilScoutingBridge.MASK_CELLS_PER_EVENT = 32
SoilScoutingBridge.MASK_MODE_FULL  = 0
SoilScoutingBridge.MASK_MODE_DELTA = 1

-- ── Serialisation (pure) ──────────────────────────────────

--- Flatten ONE farm's mask into an ordered entry list (numeric fieldId, then
--- string cellKey) so a chunked FULL is deterministic. Only masks[farmId] is
--- ever read; no other farm's bytes are touched.
---@param spatialScouting SpatialScouting|nil
---@param farmId number
---@return table entries  array of { fieldId, cellKey, day, truth, x, z, gen }
function SoilScoutingBridge.serializeFarmMask(spatialScouting, farmId)
    local entries = {}
    if spatialScouting == nil or spatialScouting.masks == nil then return entries end
    local farm = spatialScouting.masks[farmId]
    if farm == nil then return entries end
    local fieldIds = {}
    for fieldId in pairs(farm) do fieldIds[#fieldIds + 1] = fieldId end
    table.sort(fieldIds)
    for _, fieldId in ipairs(fieldIds) do
        local field = farm[fieldId]
        local keys = {}
        for cellKey in pairs(field) do keys[#keys + 1] = cellKey end
        table.sort(keys)
        for _, cellKey in ipairs(keys) do
            local e = field[cellKey]
            entries[#entries + 1] = {
                fieldId = fieldId, cellKey = cellKey,
                day = e.day or 0, truth = e.truth or 0,
                x = e.x or 0, z = e.z or 0, gen = e.gen or 0,
            }
        end
    end
    return entries
end

--- Serialise a specific changed-cell list (for a DELTA) by reading the live
--- mask. A reference whose cell no longer exists is skipped.
---@param spatialScouting SpatialScouting|nil
---@param farmId number
---@param changedList table  array of { fieldId, cellKey }
---@return table entries
function SoilScoutingBridge.serializeEntries(spatialScouting, farmId, changedList)
    local entries = {}
    if spatialScouting == nil or spatialScouting.masks == nil or type(changedList) ~= "table" then
        return entries
    end
    local farm = spatialScouting.masks[farmId]
    if farm == nil then return entries end
    for _, ref in ipairs(changedList) do
        local field = ref.fieldId ~= nil and farm[ref.fieldId] or nil
        local e = field and ref.cellKey ~= nil and field[ref.cellKey] or nil
        if e ~= nil then
            entries[#entries + 1] = {
                fieldId = ref.fieldId, cellKey = ref.cellKey,
                day = e.day or 0, truth = e.truth or 0,
                x = e.x or 0, z = e.z or 0, gen = e.gen or 0,
            }
        end
    end
    return entries
end

-- ── Remote teammate selection ─────────────────────────────

--- Every remote user connection whose farm equals farmId. Rejects non-ordinary
--- target farms, and per user: nil / disconnected / not-ready connections, the
--- LOCAL (listen-host loopback) connection, and any user on a different farm.
--- The loopback is rejected because a local-stream sendEvent runs the event
--- in-process on the host, and the host's authoritative state must never be
--- overwritten by a display payload.
---@param users table|nil          g_currentMission.userManager:getUsers()
---@param farmManager table|nil     g_farmManager
---@param farmId number
---@return table connections
function SoilScoutingBridge.selectRemoteConnections(users, farmManager, farmId)
    local conns = {}
    if type(users) ~= "table" or farmManager == nil then return conns end
    if not SpatialScouting.isOrdinaryFarmId(farmId) then return conns end
    for _, user in ipairs(users) do
        local conn = (type(user.getConnection) == "function" and user:getConnection()) or user.connection
        local isLocal = conn ~= nil and type(conn.getIsLocal) == "function" and conn:getIsLocal()
        if conn ~= nil
           and conn.isConnected ~= false
           and conn.isReadyForEvents ~= false
           and not isLocal then
            local uid = (type(user.getId) == "function" and user:getId()) or user.id
            local farm = type(farmManager.getFarmByUserId) == "function"
                and farmManager:getFarmByUserId(uid) or nil
            if farm ~= nil and farm.farmId == farmId then
                conns[#conns + 1] = conn
            end
        end
    end
    return conns
end

-- ── Server-side send (server only) ────────────────────────

local function sfNowMs()
    if type(getTimeSec) == "function" then return getTimeSec() * 1000 end
    return 0
end

--- Send one farm's whole mask to one connection as a contiguous chunk sequence.
--- An empty farm sends exactly one empty chunk. Server only.
---@param spatialScouting SpatialScouting|nil
---@param connection table|nil
---@param farmId number
function SoilScoutingBridge.sendFarmFull(spatialScouting, connection, farmId)
    if g_server == nil or connection == nil then return end
    if not SpatialScouting.isOrdinaryFarmId(farmId) then return end
    if SoilScoutingMaskSyncEvent == nil then return end
    local t0 = sfNowMs()
    local entries    = SoilScoutingBridge.serializeFarmMask(spatialScouting, farmId)
    local per        = SoilScoutingBridge.MASK_CELLS_PER_EVENT
    local chunkCount = math.max(1, math.ceil(#entries / per))
    for chunkIndex = 1, chunkCount do
        local startI = (chunkIndex - 1) * per + 1
        local endI   = math.min(chunkIndex * per, #entries)
        local slice  = {}
        for i = startI, endI do slice[#slice + 1] = entries[i] end
        connection:sendEvent(SoilScoutingMaskSyncEvent.newFull(farmId, chunkIndex, chunkCount, slice))
    end
    SoilLogger.info("SF22_MASK_FULL_SENT farm=%d entries=%d chunks=%d remotes=1 ms=%d",
        farmId, #entries, chunkCount, math.floor(sfNowMs() - t0 + 0.5))
end

--- Send a farm's changed cells as DELTA events to that farm's remote teammates.
--- Each DELTA event is independently applicable (chunk 1 of 1) and carries at
--- most MASK_CELLS_PER_EVENT cells. Server only.
---@param spatialScouting SpatialScouting|nil
---@param farmId number
---@param changedList table  array of { fieldId, cellKey }
function SoilScoutingBridge.sendFarmDelta(spatialScouting, farmId, changedList)
    if g_server == nil then return end
    if not SpatialScouting.isOrdinaryFarmId(farmId) then return end
    if SoilScoutingMaskSyncEvent == nil then return end
    local entries = SoilScoutingBridge.serializeEntries(spatialScouting, farmId, changedList)
    if #entries == 0 then return end
    local users = g_currentMission and g_currentMission.userManager
        and g_currentMission.userManager:getUsers()
    local conns = SoilScoutingBridge.selectRemoteConnections(users, g_farmManager, farmId)
    if #conns == 0 then return end
    local per   = SoilScoutingBridge.MASK_CELLS_PER_EVENT
    local total = 0
    local i = 1
    while i <= #entries do
        local slice = {}
        for j = i, math.min(i + per - 1, #entries) do slice[#slice + 1] = entries[j] end
        for _, conn in ipairs(conns) do
            conn:sendEvent(SoilScoutingMaskSyncEvent.newDelta(farmId, slice))
        end
        total = total + #slice
        i = i + per
    end
    SoilLogger.info("SF22_MASK_DELTA_SENT farm=%d entries=%d remotes=%d", farmId, total, #conns)
end

-- ── Client-side apply (client only) ───────────────────────

SoilScoutingBridge._maskBuffer = nil   -- in-flight FULL: { farmId, chunkCount, chunks, received }

local function sfRejectMask(reason)
    SoilLogger.warning("SF22_MASK_REJECT reason=%s", tostring(reason))
end

--- Merge entries into one farm's live tables. isFull replaces that farm's slice
--- atomically (only ever called with a complete, validated chunk set); a DELTA
--- never clears. Every entry raises the field generation before freshness and
--- keeps the freshest walk day per cell.
local function sfApplyEntries(spatialScouting, farmId, entries, isFull)
    if type(entries) ~= "table" then return end
    spatialScouting.masks = spatialScouting.masks or {}
    spatialScouting.generations = spatialScouting.generations or {}
    if isFull then
        spatialScouting.masks[farmId] = {}
        spatialScouting.generations[farmId] = {}
        if spatialScouting.seenDiscovered then spatialScouting.seenDiscovered[farmId] = {} end
    end
    local farm = spatialScouting.masks[farmId]
    if farm == nil then farm = {}; spatialScouting.masks[farmId] = farm end
    local gens = spatialScouting.generations[farmId]
    if gens == nil then gens = {}; spatialScouting.generations[farmId] = gens end
    for _, e in ipairs(entries) do
        if e.fieldId ~= nil and e.cellKey ~= nil then
            local eGen = e.gen or 0
            if (gens[e.fieldId] or 0) < eGen then gens[e.fieldId] = eGen end
            local field = farm[e.fieldId]
            if field == nil then field = {}; farm[e.fieldId] = field end
            local cur = field[e.cellKey]
            if cur == nil or (e.day or 0) >= (cur.day or 0) then
                field[e.cellKey] = { day = e.day or 0, truth = e.truth or 0, x = e.x or 0, z = e.z or 0, gen = eGen }
            end
        end
    end
end

--- Buffer a FULL chunk; apply the whole farm atomically once every index has
--- arrived exactly once. Chunk 1 (re)starts the buffer; duplicates, gaps,
--- out-of-range indices and a farm/chunkCount mismatch are rejected without
--- touching live tables.
local function sfBufferFullChunk(spatialScouting, localFarmId, payload)
    local ci, cc = payload.chunkIndex, payload.chunkCount
    if type(ci) ~= "number" or type(cc) ~= "number" or cc < 1 or ci < 1 or ci > cc then
        SoilScoutingBridge._maskBuffer = nil; sfRejectMask("chunkrange"); return
    end
    if ci == 1 then
        SoilScoutingBridge._maskBuffer = { farmId = localFarmId, chunkCount = cc, chunks = {}, received = 0 }
    end
    local buf = SoilScoutingBridge._maskBuffer
    if buf == nil or buf.farmId ~= localFarmId or buf.chunkCount ~= cc then
        SoilScoutingBridge._maskBuffer = nil; sfRejectMask("nostart"); return
    end
    if buf.chunks[ci] ~= nil then sfRejectMask("dup"); return end
    buf.chunks[ci] = payload.entries or {}
    buf.received = buf.received + 1
    if buf.received >= buf.chunkCount then
        local all = {}
        for idx = 1, buf.chunkCount do
            local part = buf.chunks[idx]
            if part == nil then SoilScoutingBridge._maskBuffer = nil; sfRejectMask("incomplete"); return end
            for _, e in ipairs(part) do all[#all + 1] = e end
        end
        SoilScoutingBridge._maskBuffer = nil
        sfApplyEntries(spatialScouting, localFarmId, all, true)   -- FULL: atomic replace
    end
end

--- Apply one received mask event (client side). Rejects a non-ordinary local
--- farm, a non-table payload, an unknown mode, or a payload for a different
--- farm, all BEFORE any mutation.
---@param spatialScouting SpatialScouting|nil
---@param localFarmId any
---@param payload table  { mode, farmId, chunkIndex, chunkCount, entries }
function SoilScoutingBridge.applyMaskEvent(spatialScouting, localFarmId, payload)
    if spatialScouting == nil then return end
    if type(payload) ~= "table" then sfRejectMask("payload"); return end
    if not SpatialScouting.isOrdinaryFarmId(localFarmId) then sfRejectMask("localfarm"); return end
    if payload.farmId ~= localFarmId then sfRejectMask("wrongfarm"); return end
    if payload.mode == SoilScoutingBridge.MASK_MODE_DELTA then
        sfApplyEntries(spatialScouting, localFarmId, payload.entries, false)
    elseif payload.mode == SoilScoutingBridge.MASK_MODE_FULL then
        sfBufferFullChunk(spatialScouting, localFarmId, payload)
    else
        sfRejectMask("mode")
    end
end

-- ── Pure-client farm-switch route ─────────────────────────

--- Classify a local farm-id observation. The first observation and an unchanged
--- id are no-ops. A later change clears (the old farm's knowledge must not
--- linger) and requests a fresh FULL only when the new farm is ordinary.
---@param initialized boolean
---@param previousFarmId any
---@param currentFarmId any
---@return table|nil  nil for no-op, else { clear=true, request=boolean }
function SoilScoutingBridge.classifyLocalFarmTransition(initialized, previousFarmId, currentFarmId)
    if not initialized then return nil end
    if previousFarmId == currentFarmId then return nil end
    return { clear = true, request = SpatialScouting.isOrdinaryFarmId(currentFarmId) }
end

SoilScoutingBridge._transition = nil   -- { scouting, lastFarmId, initialized }

--- Pure-client only. Subscribe to PLAYER_FARM_CHANGED so a farm switch drops the
--- old farm's mask and pulls a fresh FULL for the new one.
---@param spatialScouting SpatialScouting|nil
---@return boolean registered
function SoilScoutingBridge.registerFarmTransitionSubscriber(spatialScouting)
    if spatialScouting == nil then return false end
    if g_server ~= nil then return false end            -- pure client only
    if g_messageCenter == nil then return false end
    if SoilScoutingBridge._transition ~= nil then return false end
    SoilScoutingBridge._transition = {
        scouting    = spatialScouting,
        lastFarmId  = g_localPlayer and g_localPlayer.farmId or nil,
        initialized = g_localPlayer ~= nil and g_localPlayer.farmId ~= nil,
    }
    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED,
        SoilScoutingBridge.onPlayerFarmChanged, SoilScoutingBridge)
    return true
end

--- PLAYER_FARM_CHANGED handler. MessageCenter invokes this as (target, player),
--- so `self` is SoilScoutingBridge and `player` is the switched player. Only the
--- LOCAL player's own switch matters; another player's switch does nothing.
---@param self any
---@param player any
function SoilScoutingBridge.onPlayerFarmChanged(self, player)
    local st = SoilScoutingBridge._transition
    if st == nil then return end
    if player == nil or player ~= g_localPlayer then return end
    local oldFarmId = st.lastFarmId
    local newFarmId = g_localPlayer and g_localPlayer.farmId
    local decision  = SoilScoutingBridge.classifyLocalFarmTransition(st.initialized, oldFarmId, newFarmId)
    st.initialized = true
    st.lastFarmId  = newFarmId
    if decision == nil then return end
    if decision.clear then
        SoilScoutingBridge._maskBuffer = nil              -- abandon any in-flight FULL
        local sc = st.scouting
        if sc ~= nil then
            sc.masks = {}
            sc.generations = {}
            if sc.seenDiscovered then sc.seenDiscovered = {} end
        end
    end
    SoilLogger.info("SF22_MASK_TRANSITION old=%s new=%s clear=%s request=%s",
        tostring(oldFarmId), tostring(newFarmId),
        decision.clear and "1" or "0", decision.request and "1" or "0")
    if decision.request and SoilScoutingMaskRequestEvent ~= nil
       and g_client ~= nil and type(g_client.getServerConnection) == "function" then
        g_client:getServerConnection():sendEvent(SoilScoutingMaskRequestEvent.new())
    end
end

--- Drop the farm-switch subscriber and any in-flight FULL buffer (on unload).
function SoilScoutingBridge.unregisterFarmTransitionSubscriber()
    if g_messageCenter ~= nil and type(g_messageCenter.unsubscribeAll) == "function" then
        g_messageCenter:unsubscribeAll(SoilScoutingBridge)
    end
    SoilScoutingBridge._transition = nil
    SoilScoutingBridge._maskBuffer = nil
end
