-- SF-73-mode_and_result_events_spec_test.lua
--
-- SF-73 section 6, the network half. Every event is delivered the way the engine
-- delivers it: writeStream on the sender into a fresh instance's readStream, which
-- calls run with the receiving connection (network/Server.lua:436, Client.lua:418).
--
-- M. SoilSprayerAutoModeEvent stays a mode-only request, and on the server it now
--    also requires a resolved user (UserManager:getUserByConnection, UserManager.lua
--    :74) of a real, non-spectator farm (FarmManager.SPECTATOR_FARM_ID = 0) that is
--    the vehicle combination's ACTIVE farm (Enterable.lua:1150-1157, Vehicle.lua:1905),
--    on a vehicle not being deleted; the access rule of row 111 still applies first.
-- R. SoilApplicationTargetResultEvent is server to client only, schema 1 in its field
--    order, with presence flags on every optional number; the client keeps only a
--    strictly newer sequence of the current epoch, expires an active result after two
--    display intervals and keeps an inactive final one inspectable.
--
--!env: modenv
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, src/ResistanceBands.lua, src/config/SettingsSchema.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/network/NetworkEvents.lua

SoilLogger.info = function() end
SoilLogger.debug = function() end
SoilLogger.warning = function() end

local function conn(isServer, streamId)
    return {
        isServer = isServer, streamId = streamId,
        getIsServer = function(self) return self.isServer end,
        getIsClient = function(self) return not self.isServer end,
        getIsLocal = function(self) return self.streamId == 0 end,
    }
end
local FROM_FARM1   = conn(false, 7)
local FROM_FARM2   = conn(false, 8)
local FROM_SPECTATOR = conn(false, 9)
local FROM_NOUSER  = conn(false, 10)
local LOOPBACK     = conn(false, 0)
local CLIENT_SIDE  = conn(true, 1)

local function deliver(event, class, connection)
    local s = _sfMockStream()
    event:writeStream(s, connection)
    local dst = class.emptyNew()
    dst:readStream(s, connection)
    return dst, _sfStreamFaults(s)
end

AccessHandler = { EVERYONE = 0, NOBODY = 2 ^ 4 - 1 }
local W = {}
local function world(side)
    W.broadcasts = {}
    local recorder = { broadcastEvent = function(_, ev) W.broadcasts[#W.broadcasts + 1] = ev end }
    if side == "client" then g_server = nil else g_server = recorder end
    g_localPlayer = nil
    local players = { [FROM_FARM1] = { farmId = 1 }, [FROM_FARM2] = { farmId = 2 },
                      [FROM_SPECTATOR] = { farmId = 0 }, [FROM_NOUSER] = { farmId = 1 } }
    local mission = {
        time = 10000,
        missionDynamicInfo = { isMultiplayer = true },
        getIsServer = function() return g_server ~= nil end,
        getPlayerByConnection = function(_, c) return players[c] end,
        userManager = {
            users = { { c = FROM_FARM1 }, { c = FROM_FARM2 }, { c = FROM_SPECTATOR } },   -- no user for FROM_NOUSER
            getUserByConnection = function(self, c) for _, u in ipairs(self.users) do if u.c == c then return u end end return nil end,
        },
    }
    mission.getFarmId = function(self, connection)   -- FSBaseMission.lua:1067-1085 (dedicated: no local player)
        if connection == nil then return nil end
        local p = self:getPlayerByConnection(connection)
        return p and p.farmId or nil
    end
    local farms = { [1] = { contracting = {} }, [2] = { contracting = {} } }
    g_farmManager = { getFarmById = function(_, id) local f = farms[id]; if f == nil then return nil end
        return { getIsContractingFor = function(_, other) return f.contracting[other] == true end } end }
    W.farms = farms
    mission.accessHandler = {   -- AccessHandler.lua:19-49
        canFarmAccess = function(self, farmId, object)
            local owner = object:getOwnerFarmId()
            if farmId == 0 then return false end
            if owner == AccessHandler.EVERYONE then return true end
            if owner == farmId then return true end
            local f = g_farmManager:getFarmById(farmId)
            return f ~= nil and f:getIsContractingFor(owner)
        end,
    }
    g_currentMission = mission
    local function vehicle(id, owner)
        local v = { id = id, ownerFarmId = owner, controllerFarm = 0 }
        v.getOwnerFarmId = function(self) return self.ownerFarmId end
        v.getActiveFarm = function(self) if self.controllerFarm ~= 0 then return self.controllerFarm end return self.ownerFarmId end
        v.rootVehicle = v
        return v
    end
    W.vehicles = { [500] = vehicle(5000, 1), [501] = vehicle(5001, 2) }
    NetworkUtil = { getObject = function(id) return W.vehicles[id] end,
                    getObjectId = function(obj) for k, v in pairs(W.vehicles) do if v == obj then return k end end return nil end }
    W.rm = SprayerRateManager.new()
    local ss = { }
    ss.targetApplication = TargetApplication.new(ss)
    g_SoilFertilityManager = { sprayerRateManager = W.rm, soilSystem = ss, settings = { enabled = true } }
    W.ta = ss.targetApplication
    return W
end
local function auto(id, connection, on)
    deliver(SoilSprayerAutoModeEvent.new(id, on ~= false), SoilSprayerAutoModeEvent, connection)
    return W.rm:getAutoMode(W.vehicles[id].id)
end

-- ── M: the mode request ──────────────────────────────────────────────────────
do
    world("dedi")
    T.eq("M1 the owner's player switches AUTO on the owner's sprayer", auto(500, FROM_FARM1), true)
    T.eq("M1b and the server rebroadcasts it", #W.broadcasts, 1)
    T.eq("M2 another farm's player is refused (the access rule)", auto(501, FROM_FARM1), false)
    W.vehicles[500].ownerFarmId = 0   -- EVERYONE's, so only the new checks can refuse
    T.eq("M3 a spectator (farm 0) is refused", auto(500, FROM_SPECTATOR, true) and W.broadcasts[2] ~= nil, false)
    W.rm:setAutoMode(5000, false)
    T.eq("M4 a connection with no user record is refused", auto(500, FROM_NOUSER), false)
    W.vehicles[500].ownerFarmId = 1
    W.vehicles[500].isDeleted = true
    T.eq("M5 a vehicle being deleted is refused", auto(500, FROM_FARM1), false)
    W.vehicles[500].isDeleted = nil
    W.farms[2].contracting[1] = true
    W.vehicles[500].controllerFarm = 2
    T.eq("M6 a contractor DRIVING the owner's machine is its active farm and may switch AUTO", auto(500, FROM_FARM2), true)
    W.rm:setAutoMode(5000, false)
    W.vehicles[500].controllerFarm = 0
    T.eq("M7 the same contractor, not driving it, is refused (the owner's farm is active)", auto(500, FROM_FARM2), false)
    T.eq("M8 the host's own loopback still controls it, as before", auto(500, LOOPBACK), true)
    world("client")
    T.eq("M9 a pure client applies the server's rebroadcast unchanged", auto(501, CLIENT_SIDE), true)
end

-- ── R: the result event ──────────────────────────────────────────────────────
local function sample(epoch, seq, active)
    return {
        schema = 1, epoch = epoch, sequence = seq, active = active ~= false, scope = "FOOTPRINT",
        productFillType = 101, productName = "UREA", cropFruitIndex = 1, cropKey = "wheat", fieldId = 7,
        grainMetres = 2, knowledgeState = "KNOWN",
        nutrients = {
            N = { reading = 40.5, after = 54.6, lower = 54.21, upper = 55, relationship = "IDEAL",
                  knowledgeState = "KNOWN", requestedDelta = 14.2, usefulDelta = 14.17, approachingWidth = 0.79 },
            P = { reading = 39.8, after = 39.8, lower = 39.21, upper = 40, relationship = "IDEAL", knowledgeState = "KNOWN",
                  requestedDelta = 0, usefulDelta = 0 },
            K = { reading = 30.0, after = 30.0, lower = 39.21, upper = 40, relationship = "BELOW", knowledgeState = "KNOWN",
                  approachingDistance = 9.21, approachingWidth = 0.79 },
        },
        binding = "N", doseState = "SHORT_BINDING", reasons = { "SHORT_QUANTIZED" },
        plannedLitres = 0.6, physicalLitres = 0.6, agronomicLitres = nil, continuationLitres = nil,
    }
end
do
    world("client")
    local ev, faults = deliver(SoilApplicationTargetResultEvent.new(500, sample("3", "7")), SoilApplicationTargetResultEvent, CLIENT_SIDE)
    local r = ev.result
    T.eq("R1 the stream round-trips with no fault", faults, 0)
    T.eq("R2 in field order: epoch, sequence, scope", r and (r.epoch .. "/" .. r.sequence .. "/" .. r.scope), "3/7/FOOTPRINT")
    T.eq("R3 identifiers with their presence", r and (r.productName .. "/" .. r.cropKey .. "/" .. r.fieldId), "UREA/wheat/7")
    T.near("R4 the N record's useful delta", r and r.nutrients.N.usefulDelta, 14.17, 1e-4)
    T.eq("R5 K's absent requested delta stays absent, never an invented zero", r and r.nutrients.K.requestedDelta, nil)
    T.eq("R6 absent agronomic litres stay absent", r and r.agronomicLitres, nil)
    T.eq("R7 absent continuation litres stay absent", r and r.continuationLitres, nil)
    T.eq("R8 the dose state and every reason", r and (r.doseState .. "/" .. r.reasons[1]), "SHORT_BINDING/SHORT_QUANTIZED")
    T.ok("R9 the client stored the confirmed result for the current object", W.ta:getApplicationTargetResult(W.vehicles[500]) ~= nil)
end
do
    world("dedi")
    local ev = deliver(SoilApplicationTargetResultEvent.new(500, sample("1", "1")), SoilApplicationTargetResultEvent, FROM_FARM1)
    T.eq("R10 a server never takes a result from a client (wrong side, nothing read)", ev.refused, "WRONG_SIDE")
    world("client")
    local s = _sfMockStream()
    streamWriteInt32(s, 2)
    local bad = SoilApplicationTargetResultEvent.emptyNew()
    bad:readStream(s, CLIENT_SIDE)
    T.eq("R11 a different schema is refused, reading no further", bad.refused, "SCHEMA")
    local lost = SoilApplicationTargetResultEvent.new(999, sample("1", "1"))
    local _, f2 = deliver(lost, SoilApplicationTargetResultEvent, CLIENT_SIDE)
    T.eq("R12 an unknown object is dropped, never held", next(W.ta.client), nil)
end
do
    world("client")
    local v = W.vehicles[500]
    local ta = W.ta
    T.ok("R13 a first result of an epoch is taken", ta:receive(v, sample("4", "2")))
    T.ok("R14 an older sequence of the same epoch is dropped", not ta:receive(v, sample("4", "1")))
    T.ok("R15 an equal sequence is dropped", not ta:receive(v, sample("4", "2")))
    T.ok("R16 a strictly newer sequence is taken", ta:receive(v, sample("4", "10")))
    T.ok("R17 a stale epoch cannot repopulate the result", not ta:receive(v, sample("3", "900")))
    T.ok("R18 a newer epoch replaces the old current result", ta:receive(v, sample("5", "1")))
    g_currentMission.time = g_currentMission.time + 999
    T.ok("R19 an active result shows within two display intervals", ta:getApplicationTargetResult(v) ~= nil)
    g_currentMission.time = g_currentMission.time + 1
    T.eq("R20 an active result expires after two missed intervals", ta:getApplicationTargetResult(v), nil)
    ta:receive(v, sample("5", "2", false))
    g_currentMission.time = g_currentMission.time + 60000
    T.ok("R21 an inactive final result stays inspectable", ta:getApplicationTargetResult(v) ~= nil)
    v.isDeleted = true
    ta:update()
    T.eq("R22 a deleted object's result is forgotten", ta.client[v], nil)
    local fresh = { id = 77 }
    T.eq("R23 a new object never inherits a result", ta:getApplicationTargetResult(fresh), nil)
    local st = ta:newState(fresh)
    st.result = sample("1", "1")
    ta:publish(st, true)
    T.eq("R24 a client never publishes", #W.broadcasts, 0)
end

T.summary()
