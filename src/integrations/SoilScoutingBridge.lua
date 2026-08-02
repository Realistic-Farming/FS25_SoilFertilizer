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

SoilScoutingBridge = {}

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
                local farmId   = cell:getInt("cell#farmId") or 1
                local fieldId  = cell:getInt("cell#fieldId") or 0
                local cellKey  = cell:getString("cell#key") or ""
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
        delete(xmlFile)
        local data = { schema = 1, ageLimitDays = age, masks = masks }
        spatialScouting:deserialize(data)
    end)
    if not ok then
        SoilLogger.warning("[SpatialScouting] fallback load failed: %s", tostring(err))
    end
end

-- =========================================================
-- Network Sync (LAW 3 delivery)
-- =========================================================

SoilScoutingBridge.SYNC_MODULE_ID = "SoilFertilizer_SpatialScouting_Sync"
SoilScoutingBridge.CHANNEL        = "SoilFertilizer_SpatialScouting_Sync"
SoilScoutingBridge.syncActive     = false

local function getNetworkSync()
    return (g_currentMission and g_currentMission.networkSync) or g_networkSync
end

--- The client-side local farm id, used to scope which synced entries this
--- client may compose. On a client the player record is authoritative for the
--- local farm; a different farm's entries are ignored ("a different farm's
--- client sees nothing").
---@return number farmId
function SoilScoutingBridge.localFarmId()
    if g_localPlayer and g_localPlayer.farmId and g_localPlayer.farmId > 0 then
        return g_localPlayer.farmId
    end
    if g_currentMission and type(g_currentMission.getFarmId) == "function" then
        local ok, id = pcall(function() return g_currentMission:getFarmId() end)
        if ok and id and id > 0 then return id end
    end
    return 1
end

--- Flatten the mask into one primitive array. Shape:
---   arr[1] = farm count; then per farm: farmId, cell count, then per cell:
---   fieldId, cellKey, walkDay, sampledTruth, x, z, gen
---@param spatialScouting SpatialScouting|nil
---@return table
function SoilScoutingBridge.serializeMask(spatialScouting)
    local arr = { 0 }
    local farmCount = 0
    for farmId, farm in pairs(spatialScouting and spatialScouting.masks or {}) do
        local cells = {}
        for fieldId, field in pairs(farm) do
            for cellKey, e in pairs(field) do
                cells[#cells + 1] = { fieldId, cellKey, e.day, e.truth, e.x, e.z, e.gen or 0 }
            end
        end
        if #cells > 0 then
            farmCount = farmCount + 1
            arr[#arr + 1] = farmId
            arr[#arr + 1] = #cells
            for _, c in ipairs(cells) do
                for i = 1, 7 do arr[#arr + 1] = c[i] end
            end
        end
    end
    arr[1] = farmCount
    return arr
end

--- Rebuild the mask from the flat array. Pure: no painting, no side effects.
---@param arr table
---@param spatialScouting SpatialScouting|nil
function SoilScoutingBridge.deserializeMask(arr, spatialScouting)
    if spatialScouting == nil or type(arr) ~= "table" then return end
    local i = 1
    local farmCount = tonumber(arr[i]) or 0
    i = i + 1
    for _ = 1, farmCount do
        local farmId = arr[i]; i = i + 1
        local cellCount = tonumber(arr[i]) or 0; i = i + 1
        if farmId == nil then break end
        local farm = spatialScouting.masks[farmId] or {}
        for _ = 1, cellCount do
            local fieldId = arr[i]; i = i + 1
            local cellKey = arr[i]; i = i + 1
            local day     = tonumber(arr[i]) or 0; i = i + 1
            local truth   = tonumber(arr[i]) or 0; i = i + 1
            local x       = tonumber(arr[i]) or 0; i = i + 1
            local z       = tonumber(arr[i]) or 0; i = i + 1
            local gen     = tonumber(arr[i]) or 0; i = i + 1
            local field = farm[fieldId] or {}
            -- The freshest sample wins; a re-walk in the running session beats
            -- the synced payload for a cell this client also walked.
            local cur = field[cellKey]
            if cur == nil or day >= cur.day then
                field[cellKey] = { day = day, truth = truth, x = x, z = z, gen = gen }
            end
            farm[fieldId] = field
        end
        spatialScouting.masks[farmId] = farm
    end
end

--- Register with NetworkSync when present.
---@param spatialScouting SpatialScouting|nil
---@return boolean registered
function SoilScoutingBridge.registerSync(spatialScouting)
    SoilScoutingBridge.syncActive = false
    if spatialScouting == nil then return false end

    local ns = getNetworkSync()
    if ns == nil or ns.registerModule == nil then
        SoilLogger.info("[SpatialScouting] NetworkSync not detected - mask is not shared (standalone fallback)")
        return false
    end

    local ok, err = pcall(function()
        ns:registerModule(SoilScoutingBridge.SYNC_MODULE_ID, {
            channel      = SoilScoutingBridge.CHANNEL,
            onWriteState = function() return SoilScoutingBridge.serializeMask(spatialScouting) end,
            onReadState  = function(arr) SoilScoutingBridge.deserializeMask(arr, spatialScouting) end,
        })
    end)

    if not ok then
        SoilLogger.warning("[SpatialScouting] NetworkSync registration failed: %s (mask not shared)", tostring(err))
        return false
    end

    SoilScoutingBridge.syncActive = true
    SoilLogger.info("[OK] SpatialScouting registered with NetworkSync as '%s'",
        SoilScoutingBridge.SYNC_MODULE_ID)
    return true
end

--- Flag the mask dirty for the next 1Hz NetworkSync batch.
function SoilScoutingBridge.markDirty()
    if not SoilScoutingBridge.syncActive then return end
    local ns = getNetworkSync()
    if ns ~= nil and ns.markDirty then
        ns:markDirty(SoilScoutingBridge.SYNC_MODULE_ID)
    end
end
