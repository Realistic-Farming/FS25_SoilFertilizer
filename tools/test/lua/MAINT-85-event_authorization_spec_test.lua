-- MAINT-85-event_authorization_spec_test.lua
--
-- MAINTENANCE rows 85, 110 and 111: who may make SoilFertilizer's network events do
-- what, on which side. Every event is delivered the way the engine delivers it: the
-- sender's writeStream into a fresh instance's readStream, which calls run with the
-- receiving connection (network/Server.lua:436, Client.lua:418). No row calls run.
--
-- The two sides and their connections, modelled on the decompiled engine: a listen
-- host is BOTH g_server and g_client (gui/MPLoadingScreen.lua:436-437) and reads a
-- client's event on its connection to that client, created with isServer = false
-- (Server.lua:454); a pure client is g_client only and reads on its server
-- connection, created with isServer = true (Client.lua:152); the host's own local
-- delivery is the loopback on stream 0 with the reversed flag (Connection.lua:47).
-- The sender's farm is the mission's player record for the connection
-- (FSBaseMission:getFarmId, FSBaseMission.lua:1067-1085, modelled line for line), and
-- a vehicle's access is the engine's AccessHandler:canFarmAccess (AccessHandler.lua
-- :19-49, modelled line for line over a farm manager with contracting).
--
-- THE ENTRY-POINT BAR IS EVERY ROW: production enters these events at readStream,
-- and nothing a row asserts on is populated by hand: the organic state is written by
-- the real optIn of the owner, the sprayer rate by the real manager, the field
-- tables by the real readers. Sources run under the mod's own environment.
--
--!env: modenv
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, src/ResistanceBands.lua, src/config/SettingsSchema.lua, src/SprayerRateManager.lua, src/network/NetworkEvents.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── connections (Connection.lua:24-27, :146-151) ────────────────────────────
local function conn(isServer, streamId)
    return {
        isServer = isServer, streamId = streamId,
        getIsServer = function(self) return self.isServer end,
        getIsClient = function(self) return not self.isServer end,
        getIsLocal = function(self) return self.streamId == 0 end,
    }
end
local AT_HOST_FROM_FARM1 = conn(false, 7)   -- the host's connection to a farm-1 client
local AT_HOST_FROM_FARM2 = conn(false, 8)   -- the host's connection to a farm-2 client
local AT_HOST_UNPLAYERED = conn(false, 9)   -- a connection with no player record
local AT_CLIENT_FROM_SERVER = conn(true, 1) -- a pure client's server connection
local LOOPBACK = conn(false, 0)             -- the host's own local delivery

--- The engine's delivery: writeStream on the sender, readStream (which runs) on the
--- receiver. Returns the received instance and the stream's fault count.
local function deliver(event, class, connection)
    local s = _sfMockStream()
    event:writeStream(s, connection)
    local dst = class.emptyNew()
    dst:readStream(s, connection)
    return dst, _sfStreamFaults(s)
end

-- ── the world ───────────────────────────────────────────────────────────────
local W = {}
local function sampleField(nitrogen)
    return {
        fieldArea = 3.5, nitrogen = nitrogen or 55, phosphorus = 40, potassium = 30,
        organicMatter = 4.2, pH = 6.4,
        lastCrop = "wheat", lastCrop2 = "barley", lastCrop3 = "canola",
        rotationBonusDaysLeft = 3, lastHarvest = 12, fertilizerApplied = 220,
        weedPressure = 5, herbicideDaysLeft = 2, pestPressure = 3, insecticideDaysLeft = 1,
        diseasePressure = 17, fungicideDaysLeft = 4, dryDayCount = 6, burnDaysLeft = 2,
        coverageFraction = 0.5, compaction = 11, amendBurnPenalty = 0.42,
        nutrientBuffer = { [12] = 4.5, [3] = 1.25 },
        activeDisease = "septoria", diseaseDiscovered = true, fieldEverScouted = true,
        organic = { state = SoilConstants.ORGANIC.STATE_CONVENTIONAL, startDay = 0, certifiedDay = 0, breaches = 0 },
        resistance = { ["3"] = 10, ["M2"] = 3.5 },
        zoneData = {},
    }
end
local Settings_mt = { __index = { save = function(self) self.saves = (self.saves or 0) + 1 end } }
-- ── the engine's access rule (AccessHandler.lua:2-3, :19-49; Farm.lua:476-478) ──
AccessHandler = { EVERYONE = 0, NOBODY = 2 ^ 4 - 1 }
local function farm(id)
    return { farmId = id, contractingFor = {},
        getIsContractingFor = function(self, other) return self.contractingFor[other] or false end,
        setIsContractingFor = function(self, other, on) self.contractingFor[other] = on or nil end }
end
local function accessHandler()
    return {
        canFarmAccess = function(self, farmId, object, allowEqualAlways)
            if object == nil then return false end
            local ownerFarmId = object:getOwnerFarmId()
            if farmId == 0 and (not allowEqualAlways or farmId ~= ownerFarmId) then return false end
            if ownerFarmId == nil or ownerFarmId == AccessHandler.EVERYONE then return true end
            if farmId ~= nil then return self:canFarmAccessOtherId(farmId, ownerFarmId) end
            return ownerFarmId == AccessHandler.EVERYONE
        end,
        canFarmAccessOtherId = function(_, farmId, objectFarmId)
            if objectFarmId == AccessHandler.EVERYONE then return true
            elseif objectFarmId == AccessHandler.NOBODY then return false
            elseif objectFarmId == farmId then return true
            else
                local f = g_farmManager:getFarmById(farmId)
                if f == nil then return false end
                return f:getIsContractingFor(objectFarmId)
            end
        end,
    }
end
--- side: "host" (a listen host), "client" (a pure client) or "dedi" (a dedicated
--- server). The mission's player records: the farm-1 and farm-2 connections; the
--- local player is farm 1 unless opts.noLocalPlayer. Farmland 7 belongs to farm 1,
--- farmland 9 to farm 2, farmland 11 to nobody.
local function world(side, opts)
    opts = opts or {}
    W.broadcasts, W.fullSyncReceived, W.sent = {}, 0, {}
    local recorder = { broadcastEvent = function(_, ev, sendLocal, ignore) W.broadcasts[#W.broadcasts + 1] = { ev = ev, sendLocal = sendLocal, ignore = ignore } end }
    -- A client's server connection sends; what it sent is recorded (Client.lua:152).
    local client = { getServerConnection = function() return { sendEvent = function(_, ev) W.sent[#W.sent + 1] = ev end } end }
    if side == "host" then g_server, g_client = recorder, client
    elseif side == "client" then g_server, g_client = nil, client
    else g_server, g_client = recorder, nil end
    g_localPlayer = (not opts.noLocalPlayer) and { farmId = 1 } or nil
    local mission = {
        environment = { currentDay = 12, daysPerPeriod = 1 },
        missionDynamicInfo = { isMultiplayer = true },
        connectionsToPlayer = { [AT_HOST_FROM_FARM1] = { farmId = 1 }, [AT_HOST_FROM_FARM2] = { farmId = 2 } },
        hud = { warnings = 0, showBlinkingWarning = function(self) self.warnings = self.warnings + 1 end },
        getIsServer = function() return g_server ~= nil end,
        getPlayerByConnection = function(self, c) return self.connectionsToPlayer[c] end,   -- FSBaseMission.lua:1098
        accessHandler = accessHandler(),   -- FSBaseMission.lua:159
    }
    g_farmManager = { farms = { [1] = farm(1), [2] = farm(2) }, getFarmById = function(self, id) return self.farms[id] end }
    -- FSBaseMission.lua:1067-1085, as decompiled.
    mission.getFarmId = function(self, connection)
        if self:getIsServer() then
            if g_localPlayer == nil or connection ~= nil then
                if connection == nil then return nil end
                local player = self:getPlayerByConnection(connection)
                if player == nil then return nil end
                return player.farmId
            else
                return g_localPlayer.farmId
            end
        else
            return g_localPlayer == nil and 0 or g_localPlayer.farmId
        end
    end
    g_currentMission = mission
    g_farmlandManager = {
        farmlandMapping = { [7] = 1, [9] = 2 },
        getFarmlandOwner = function(self, id)   -- FarmlandManager.lua:275-281
            if id == nil or self.farmlandMapping[id] == nil then return 0 end
            return self.farmlandMapping[id]
        end,
    }
    W.vehicles = {
        [500] = { id = 5000, ownerFarmId = 1, getOwnerFarmId = function(self) return self.ownerFarmId end },   -- Object.lua:132
        [501] = { id = 5001, ownerFarmId = 2, getOwnerFarmId = function(self) return self.ownerFarmId end },
        [502] = { id = 5002, ownerFarmId = 0, getOwnerFarmId = function(self) return self.ownerFarmId end },   -- EVERYONE's
    }
    NetworkUtil = { getObject = function(id) return W.vehicles[id] end }
    local settings = setmetatable({ enabled = true, difficulty = 2 }, Settings_mt)
    for _, def in ipairs(SettingsSchema.definitions) do
        if settings[def.id] == nil then settings[def.id] = def.default end
    end
    local soilSystem = { fieldData = { [7] = sampleField(), [9] = sampleField(), [11] = sampleField() }, activeFieldIds = {} }
    soilSystem._addToActiveSet = function(self, id) self.activeFieldIds[id] = true end
    local organic = OrganicCertification.new(soilSystem)
    local rm = SprayerRateManager.new()
    g_SoilFertilityManager = {
        settings = settings, soilSystem = soilSystem, organic = organic, sprayerRateManager = rm,
        settingsUI = { refreshes = 0, refreshUI = function(self) self.refreshes = self.refreshes + 1 end },
        soilMapOverlay = { refreshes = 0, requestRefresh = function(self) self.refreshes = self.refreshes + 1 end },
    }
    SoilNetworkEvents_OnFullSyncReceived = function() W.fullSyncReceived = W.fullSyncReceived + 1 end
    W.settings, W.soilSystem, W.organic, W.rm, W.mission = settings, soilSystem, organic, rm, mission
    return W
end
local function forgedSettings()
    local s = {}
    for _, def in ipairs(SettingsSchema.definitions) do
        if def.type == "boolean" then s[def.id] = false elseif def.type == "number" then s[def.id] = (def.default or 1) + 1 end
    end
    s.enabled, s.difficulty = false, 3
    return s
end
local function organicState(fieldId)
    local f = W.soilSystem.fieldData[fieldId]
    return f and f.organic and f.organic.state or "none"
end
local function lines(list, needle)
    local n = 0
    for _, l in ipairs(list) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ══════════════════════════════════════════════════════════════════════════
-- H. A LISTEN HOST REFUSES WHAT A CLIENT SENDS ON THE FOUR SYNC EVENTS (row 85)
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    world("host")
    local before7 = W.soilSystem.fieldData[7]
    local beforeData = W.soilSystem.fieldData
    local _, faults = deliver(SoilSettingSyncEvent.new("difficulty", 3), SoilSettingSyncEvent, AT_HOST_FROM_FARM2)
    T.eq("H1 a setting sync from a client leaves the host's setting and its UI alone (the stream itself is clean)",
        tostring(W.settings.difficulty) .. "/" .. g_SoilFertilityManager.settingsUI.refreshes .. "/" .. faults, "2/0/0")
    deliver(SoilSettingSyncEvent.new("save", 1), SoilSettingSyncEvent, AT_HOST_FROM_FARM2)
    T.eq("H1b a forged setting named after the settings' own method does not shadow it on the host",
        type(W.settings.save) .. "/" .. tostring(rawget(W.settings, "save")), "function/nil")

    deliver(SoilFullSyncEvent.new(forgedSettings(), { [7] = sampleField(99) }), SoilFullSyncEvent, AT_HOST_FROM_FARM2)
    T.eq("H2 a full sync from a client leaves the host's settings, its fieldData table and its field alone, and does not count as a received sync",
        tostring(W.settings.enabled) .. "/" .. tostring(W.settings.difficulty) .. "/" .. tostring(W.soilSystem.fieldData == beforeData) .. "/" .. tostring(W.soilSystem.fieldData[7] == before7) .. "/" .. W.fullSyncReceived,
        "true/2/true/true/0")
    deliver(SoilFullSyncEvent.new(forgedSettings(), { [7] = sampleField(0 / 0) }), SoilFullSyncEvent, AT_HOST_FROM_FARM2)
    T.eq("H2b a corrupt full sync from a client does not blink the host's HUD, and since row 112 the host reads none of it (no corruption line either)",
        W.mission.hud.warnings .. "/" .. tostring(lines(WARN, "Corrupt MP data") >= 1), "0/false")

    deliver(SoilFieldBatchSyncEvent.new({ [7] = sampleField(99) }, true), SoilFieldBatchSyncEvent, AT_HOST_FROM_FARM2)
    T.eq("H3 a field batch from a client changes no field on the host and refreshes nothing",
        tostring(W.soilSystem.fieldData[7] == before7) .. "/" .. W.soilSystem.fieldData[7].nitrogen .. "/" .. g_SoilFertilityManager.soilMapOverlay.refreshes, "true/55/0")

    deliver(SoilFieldUpdateEvent.new(7, sampleField(99)), SoilFieldUpdateEvent, AT_HOST_FROM_FARM2)
    T.eq("H4 a field update from a client changes no field on the host",
        tostring(W.soilSystem.fieldData[7] == before7) .. "/" .. W.soilSystem.fieldData[7].nitrogen, "true/55")
    T.eq("H5 the host logged no client-side apply line", lines(INFO, "Client:"), 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A PURE CLIENT APPLIES THE SAME PAYLOADS FROM ITS SERVER CONNECTION
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    world("client")
    deliver(SoilSettingSyncEvent.new("difficulty", 3), SoilSettingSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("C1 a pure client applies a setting sync from its server and refreshes its UI",
        tostring(W.settings.difficulty) .. "/" .. g_SoilFertilityManager.settingsUI.refreshes, "3/1")

    local before7 = W.soilSystem.fieldData[7]
    deliver(SoilFullSyncEvent.new(forgedSettings(), { [7] = sampleField(99) }), SoilFullSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("C2 a pure client applies the full sync: the settings, the legacy inline field, and the sync counts as received",
        tostring(W.settings.enabled) .. "/" .. tostring(W.settings.difficulty) .. "/" .. tostring(W.soilSystem.fieldData[7] ~= before7) .. "/" .. W.soilSystem.fieldData[7].nitrogen .. "/" .. W.fullSyncReceived,
        "false/3/true/99/1")
    deliver(SoilFullSyncEvent.new(forgedSettings(), { [7] = sampleField(0 / 0) }), SoilFullSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("C2b a corrupt full sync blinks the client's HUD once", W.mission.hud.warnings, 1)

    world("client")
    before7 = W.soilSystem.fieldData[7]
    deliver(SoilFieldBatchSyncEvent.new({ [7] = sampleField(77) }, true), SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("C3 a pure client merges a field batch, rebuilds its active set from the farmland owners and refreshes the overlay",
        W.soilSystem.fieldData[7].nitrogen .. "/" .. tostring(W.soilSystem.activeFieldIds[7]) .. "/" .. tostring(W.soilSystem.activeFieldIds[11]) .. "/" .. g_SoilFertilityManager.soilMapOverlay.refreshes, "77/true/nil/1")
    deliver(SoilFieldUpdateEvent.new(7, sampleField(66)), SoilFieldUpdateEvent, AT_CLIENT_FROM_SERVER)
    T.eq("C4 a pure client applies a field update", W.soilSystem.fieldData[7].nitrogen .. "/" .. g_SoilFertilityManager.soilMapOverlay.refreshes, "66/2")

    -- The connection half of the side test: with no server here, an event that did
    -- not come in on the server connection is still refused.
    world("client")
    deliver(SoilFieldUpdateEvent.new(7, sampleField(66)), SoilFieldUpdateEvent, AT_HOST_FROM_FARM2)
    T.eq("C5 DIFFERENCE: with no server on this side, an event that did not arrive on the server connection is refused all the same",
        W.soilSystem.fieldData[7].nitrogen, 55)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A DEDICATED SERVER REFUSES THEM TOO
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    world("dedi", { noLocalPlayer = true })
    deliver(SoilSettingSyncEvent.new("difficulty", 3), SoilSettingSyncEvent, AT_HOST_FROM_FARM2)
    deliver(SoilFieldUpdateEvent.new(7, sampleField(99)), SoilFieldUpdateEvent, AT_HOST_FROM_FARM2)
    deliver(SoilFieldBatchSyncEvent.new({ [7] = sampleField(99) }, true), SoilFieldBatchSyncEvent, AT_HOST_FROM_FARM2)
    deliver(SoilFullSyncEvent.new(forgedSettings(), { [7] = sampleField(99) }), SoilFullSyncEvent, AT_HOST_FROM_FARM2)
    T.eq("D1 a dedicated server refuses all four sync events from a client",
        tostring(W.settings.difficulty) .. "/" .. W.soilSystem.fieldData[7].nitrogen .. "/" .. W.fullSyncReceived, "2/55/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE ORGANIC REQUEST ACTS FOR THE SENDER'S OWN FARM ON ITS OWN FIELD (row 110)
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    world("host")
    local TR, CONV = SoilConstants.ORGANIC.STATE_TRANSITION, SoilConstants.ORGANIC.STATE_CONVENTIONAL
    deliver(SoilOrganicOptEvent.new(7, true), SoilOrganicOptEvent, AT_HOST_FROM_FARM1)
    T.eq("O0 [world] the owner's client opts its field 7 into transition; the field update broadcasts",
        organicState(7) .. "/" .. #W.broadcasts, TR .. "/1")

    deliver(SoilOrganicOptEvent.new(7, false), SoilOrganicOptEvent, AT_HOST_FROM_FARM2)
    T.eq("O1 farm 2's client opting farm 1's field out changes nothing and broadcasts nothing",
        organicState(7) .. "/" .. #W.broadcasts, TR .. "/1")
    deliver(SoilOrganicOptEvent.new(7, true), SoilOrganicOptEvent, AT_HOST_FROM_FARM2)
    T.eq("O1b nor can it opt that field in", organicState(7) .. "/" .. #W.broadcasts, TR .. "/1")

    deliver(SoilOrganicOptEvent.new(7, false), SoilOrganicOptEvent, AT_HOST_FROM_FARM1)
    T.eq("O2 the owner's own opt-out applies and broadcasts", organicState(7) .. "/" .. #W.broadcasts, CONV .. "/2")

    deliver(SoilOrganicOptEvent.new(7, true), SoilOrganicOptEvent, AT_HOST_UNPLAYERED)
    T.eq("O3 a connection with no player record is refused", organicState(7) .. "/" .. #W.broadcasts, CONV .. "/2")

    deliver(SoilOrganicOptEvent.new(9, true), SoilOrganicOptEvent, AT_HOST_FROM_FARM1)
    deliver(SoilOrganicOptEvent.new(11, true), SoilOrganicOptEvent, AT_HOST_FROM_FARM1)
    T.eq("O4 farm 1 can opt neither farm 2's field nor unowned land", organicState(9) .. "/" .. organicState(11) .. "/" .. #W.broadcasts, CONV .. "/" .. CONV .. "/2")

    -- The host's own doors (console, PDA) act for the local player's farm.
    local okOwn, msgOwn = W.organic:requestOptIn(7)
    local okOther, msgOther = W.organic:requestOptIn(9)
    T.eq("O5 the host's own door opts its own field in and is refused on farm 2's field, with a message that names it",
        tostring(okOwn) .. "/" .. organicState(7) .. "/" .. tostring(okOther) .. "/" .. tostring(msgOther), "true/" .. TR .. "/false/Field 9 is not owned by your farm")

    world("dedi", { noLocalPlayer = true })
    local okDedi = W.organic:requestOptIn(7)
    T.eq("O6 a dedicated server's console, with no local player, is refused on any field", tostring(okDedi) .. "/" .. organicState(7), "false/" .. CONV)

    -- A pure client asks its server and changes nothing itself (unchanged behaviour).
    world("client")
    local okClient = W.organic:requestOptIn(7)
    T.eq("O7 a pure client sends the request to its server and writes nothing locally",
        tostring(okClient) .. "/" .. #W.sent .. "/" .. tostring(W.sent[1] and W.sent[1].fieldId) .. "/" .. organicState(7), "true/1/7/" .. CONV)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SPRAYER EVENTS APPLY ON THE SERVER ONLY FOR THE SENDER'S OWN VEHICLE (row 111)
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    world("host")
    local v1, v2 = W.vehicles[500], W.vehicles[501]
    deliver(SoilSprayerRateEvent.new(501, 3), SoilSprayerRateEvent, AT_HOST_FROM_FARM1)
    T.eq("S1 farm 1's client cannot set the rate on farm 2's sprayer; nothing is rebroadcast",
        tostring(W.rm.vehicleRates[v2.id]) .. "/" .. #W.broadcasts, "nil/0")
    deliver(SoilSprayerRateEvent.new(500, 3), SoilSprayerRateEvent, AT_HOST_FROM_FARM1)
    local b = W.broadcasts[1]
    T.eq("S2 the owner's change applies and is rebroadcast to every other client, the sender skipped",
        tostring(W.rm.vehicleRates[v1.id]) .. "/" .. #W.broadcasts .. "/" .. tostring(b and b.ev.vehicleNetId) .. "/" .. tostring(b and b.ev.rateIndex) .. "/" .. tostring(b and b.ignore == AT_HOST_FROM_FARM1), "3/1/500/3/true")

    -- A contractor is admitted by the engine's own rule, and refused again when the
    -- contract ends; a vehicle owned by EVERYONE takes any player's change.
    g_farmManager.farms[2]:setIsContractingFor(1, true)
    deliver(SoilSprayerRateEvent.new(500, 5), SoilSprayerRateEvent, AT_HOST_FROM_FARM2)
    T.eq("S2b farm 2's client, contracting for farm 1, sets the rate on farm 1's sprayer: applied and rebroadcast (the engine's access rule)",
        tostring(W.rm.vehicleRates[v1.id]) .. "/" .. #W.broadcasts, "5/2")
    g_farmManager.farms[2]:setIsContractingFor(1, false)
    deliver(SoilSprayerRateEvent.new(500, 6), SoilSprayerRateEvent, AT_HOST_FROM_FARM2)
    T.eq("S2c with the contract ended the same client is refused again", tostring(W.rm.vehicleRates[v1.id]) .. "/" .. #W.broadcasts, "5/2")
    deliver(SoilSprayerRateEvent.new(502, 7), SoilSprayerRateEvent, AT_HOST_FROM_FARM2)
    T.eq("S2d a vehicle owned by EVERYONE takes any player's change", tostring(W.rm.vehicleRates[W.vehicles[502].id]) .. "/" .. #W.broadcasts, "7/3")
    deliver(SoilSprayerAutoModeEvent.new(501, true), SoilSprayerAutoModeEvent, AT_HOST_FROM_FARM1)
    local autoOther = W.rm:getAutoMode(v2.id)
    deliver(SoilSprayerAutoModeEvent.new(500, true), SoilSprayerAutoModeEvent, AT_HOST_FROM_FARM1)
    T.eq("S3 auto mode: refused on farm 2's sprayer, applied on the owner's, rebroadcast once",
        tostring(autoOther) .. "/" .. tostring(W.rm:getAutoMode(v1.id)) .. "/" .. #W.broadcasts, "false/true/4")

    deliver(SoilSprayerRateEvent.new(501, 2), SoilSprayerRateEvent, LOOPBACK)
    T.eq("S4 the host's own local delivery (the loopback) still controls any sprayer, as before",
        tostring(W.rm.vehicleRates[v2.id]) .. "/" .. #W.broadcasts, "2/5")

    deliver(SoilSprayerRateEvent.new(500, 4), SoilSprayerRateEvent, AT_HOST_UNPLAYERED)
    T.eq("S5 a connection with no player record is refused", tostring(W.rm.vehicleRates[v1.id]), "5")

    world("client")
    deliver(SoilSprayerRateEvent.new(501, 4), SoilSprayerRateEvent, AT_CLIENT_FROM_SERVER)
    deliver(SoilSprayerAutoModeEvent.new(501, true), SoilSprayerAutoModeEvent, AT_CLIENT_FROM_SERVER)
    T.eq("S6 a pure client applies the server's rebroadcast for any vehicle, unchanged",
        tostring(W.rm.vehicleRates[W.vehicles[501].id]) .. "/" .. tostring(W.rm:getAutoMode(W.vehicles[501].id)), "4/true")

    world("dedi", { noLocalPlayer = true })
    deliver(SoilSprayerRateEvent.new(501, 3), SoilSprayerRateEvent, AT_HOST_FROM_FARM1)
    deliver(SoilSprayerRateEvent.new(500, 3), SoilSprayerRateEvent, AT_HOST_FROM_FARM1)
    T.eq("S7 a dedicated server applies the same rule", tostring(W.rm.vehicleRates[W.vehicles[501].id]) .. "/" .. tostring(W.rm.vehicleRates[W.vehicles[500].id]), "nil/3")
end)

T.summary()
