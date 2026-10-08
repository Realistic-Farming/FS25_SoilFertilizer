-- MAINT-248-scs_moisture_handle_spec_test.lua
--
-- MAINTENANCE row 248 (Bob's fleet sweep row 7): SF-55's moisture blend uses SeasonalCropStress in a
-- game.
--
-- THE DEFECT THIS PINS (development ab39998c): SoilFertilityManager:_blendedWetness01 read SCS
-- through the bare global g_cropStressManager (src/SoilFertilityManager.lua:1911). SCS writes that
-- global into its own mod environment (getfenv(0), SCS main.lua:282), so the read was nil in a game
-- and every compaction and traffic-drag pass took the rain-scalar fallback, never SCS's field
-- moisture. SCS also publishes the manager on the mission (main.lua:285, mission.cropStressManager).
--
-- THE FIX: the blend reads g_currentMission.cropStressManager first, the bare global as the
-- fallback, as Soil's own CD15Model moistureSource does (src/disease/CD15Model.lua:317).
--
-- THE ENTRY-POINT BAR IS GROUP E. Soil's code runs in Soil's mod environment (--!env: modenv) with
-- the real SoilFertilityManager.lua and TrafficDrag.lua loaded there; the manager is a table over the
-- real class (as GC-6's bench builds it), carrying only the state the pass reads. SCS is modelled in
-- its own mod environment, built as dataS mods.lua:482-520 builds one, and its load (SCS main.lua:282,
-- :285) puts its manager into that environment and onto the mission; its getMoisture returns per-field
-- moisture (0..1, nil for an untracked field, the facade SF-55's brief names). The engine side is the
-- mission's vehicle list with one heavy vehicle whose wheels touch the ground. The pass enters where
-- production enters it: _checkVehicleCompaction, the pass update() runs every CHECK_INTERVAL_MS
-- (SoilFertilityManager.lua:1713-1720), which walks the vehicle list and asks the blend for the
-- wetness under each vehicle. The wetness the pass hands the compaction model is recorded.
--
--   E0  the world: Soil's environment has no g_cropStressManager; SCS's has it, and the mission carries it
--   E1  over a field SCS tracks at 0.9, the pass uses SCS's moisture, not the rain scalar 0.2
--   E2  over a field SCS does not track, the pass uses the rain scalar exactly as before
--   E3  with SCS drier than the rain scalar, the rain scalar still wins (the blend's floor holds)
--
--!env: modenv
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/TrafficDrag.lua, src/SoilFertilityManager.lua

local SOIL_ENV = _ENV
local REAL_G = getmetatable(SOIL_ENV).__index

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the engine: the mission and one heavy vehicle on the ground ────────────────
local POS = { x = 100, z = 100 }
local vehicle = {
    id = 1, rootNode = "veh1",
    spec_wheels = { wheels = { { physics = { hasGroundContact = true } } } },
}
function vehicle:getTotalMass() return 20 end
REAL_G.getWorldTranslation = function(node) return POS.x, 0, POS.z end
local savedMission = REAL_G.g_currentMission
local mission = {
    environment = { currentDay = 10, dayTime = 12 * 3600000 },
    vehicleSystem = { vehicles = { vehicle } },
}
function mission:getIsServer() return true end
REAL_G.g_currentMission = mission

-- ── SCS, in its own mod environment (mods.lua:482-520) ──────────────────────────
local scsEnv = setmetatable({}, { __index = REAL_G })
scsEnv._G = scsEnv
scsEnv.getfenv = function() return scsEnv end
local SCS_LOAD = [==[
local mission = ...
-- Per-field soil moisture, 0..1; a field SCS does not track returns nil.
local MOISTURE = { [5] = 0.9, [6] = 0.1 }
local g_csManager = {}
function g_csManager:getMoisture(fieldId, x, z) return MOISTURE[fieldId] end
-- SCS main.lua:282 and :285 at a6757f7 (Mission00.load, self is the mission).
getfenv(0)["g_cropStressManager"] = g_csManager
mission.cropStressManager = g_csManager
return g_csManager
]==]
local csm = assert(load(SCS_LOAD, "=FS25_SeasonalCropStress main.lua (model)", "t", scsEnv))(mission)

-- ── Soil's manager over the real class, and the field under the vehicle ─────────
local FIELD_AT = 5
local mgr = setmetatable({
    settings = { compactionEnabled = true },
    soilSystem = {
        hookManager = { getFieldIdAtWorldPosition = function() return FIELD_AT end },
        vmAvailable = function() return false end,
        onCompaction = function() end,
    },
    _soilWetness01 = 0.2,
}, { __index = SoilFertilityManager })
mgr._updateSoilWetness = function() end   -- the rain scalar is held at 0.2 for the bench

-- The wetness the pass hands the compaction model, recorded.
local WET = {}
SoilCompactionModel = { pointsForVehicle = function(_v, wet) WET[#WET + 1] = wet; return 0, "bench" end }

local function pass()
    WET = {}
    mgr:_checkVehicleCompaction()
    return WET[1]
end

group("E0", function()
    T.eq("E0 Soil's environment has no g_cropStressManager", rawget(SOIL_ENV, "g_cropStressManager"), nil)
    T.eq("E0 nor does the real global table", rawget(REAL_G, "g_cropStressManager"), nil)
    T.ok("E0 SCS's own environment has it, and the mission carries it",
        scsEnv.g_cropStressManager == csm and mission.cropStressManager == csm)
end)

group("E1", function()
    FIELD_AT = 5
    T.eq("E1 over a field SCS tracks at 0.9 the pass uses SCS's moisture", pass(), 0.9)
end)

group("E2", function()
    FIELD_AT = 7
    T.eq("E2 over a field SCS does not track the pass uses the rain scalar", pass(), 0.2)
end)

group("E3", function()
    FIELD_AT = 6
    T.eq("E3 SCS drier (0.1) than the rain scalar (0.2): the rain scalar holds", pass(), 0.2)
end)

REAL_G.g_currentMission = savedMission
