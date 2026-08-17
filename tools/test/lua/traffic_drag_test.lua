-- traffic_drag_test.lua - SF-55 TRAFFIC ON WET GROUND: the pure arithmetic bench.
-- Covers the drag cap (binds at write time), the SCS-to-rain-scalar blend rule, the
-- F111 all-vehicle enumeration shape, and the cell-and-day dedupe (TimeGuard
-- monotonicDay keyed, never environment.currentDay). Loads the real layer
-- registration so the SoilValueMaps-registered def is part of the proof.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/maps/SoilValueMaps.lua, src/TrafficDrag.lua

FruitType = FruitType or { UNKNOWN = 0 }

local tdCfg = SoilConstants.COMPACTION.TRAFFIC_DRAG
local CAP   = tdCfg.CAP

-- 1. THE DRAG CAP BINDS AT WRITE TIME (Steward invariant).
T.near("accrue from nil births the record", TrafficDrag.accrue(nil, tdCfg.MAGNITUDE_PER_EVENT, CAP), tdCfg.MAGNITUDE_PER_EVENT)
T.near("accrue accumulates across events", TrafficDrag.accrue(0.10, tdCfg.MAGNITUDE_PER_EVENT, CAP), 0.15)
T.near("accrue clamps AT the cap", TrafficDrag.accrue(0.28, tdCfg.MAGNITUDE_PER_EVENT, CAP), CAP)
T.near("accrue never exceeds the cap", TrafficDrag.accrue(0.5, tdCfg.MAGNITUDE_PER_EVENT, CAP), CAP)
T.eq("accrue floors at zero", TrafficDrag.accrue(0.02, -0.05, CAP), 0)

-- 1b. THE LAYER IS SoilValueMaps-REGISTERED, bounded 0..CAP, server-only.
local tdDef = nil
for _, def in ipairs(SoilValueMaps.LAYER_DEFS) do
    if def.key == "trafficDrag" then tdDef = def break end
end
T.ok("trafficDrag layer is registered in SoilValueMaps", tdDef ~= nil)
if tdDef then
    T.eq("trafficDrag minVal is 0", tdDef.minVal, 0)
    T.eq("trafficDrag maxVal is the cap", tdDef.maxVal, CAP)
    T.eq("trafficDrag is serverOnly (no client allocation)", tdDef.serverOnly, true)
    T.ok("trafficDrag has a persistence file", type(tdDef.file) == "string" and tdDef.file ~= "")
end

-- 2. THE SCS-TO-RAIN-SCALAR BLEND RULE (confirm 2: max, rain as the calibrated floor).
T.eq("no SCS -> rain scalar unchanged", TrafficDrag.blendWetness(nil, 0.7), 0.7)
T.eq("no SCS and no rain -> 0", TrafficDrag.blendWetness(nil, nil), 0)
T.eq("SCS wetter than rain -> SCS", TrafficDrag.blendWetness(0.9, 0.4), 0.9)
T.eq("rain wetter than SCS -> rain (floor holds)", TrafficDrag.blendWetness(0.3, 0.8), 0.8)
T.eq("equal signals -> either", TrafficDrag.blendWetness(0.5, 0.5), 0.5)
T.eq("untracked field (nil) degrades to rain", TrafficDrag.blendWetness(nil, 0.2), 0.2)

-- 3. THE F111 ENUMERATION SHAPE (all vehicles, vehicleSystem first, mission fallback).
local oldMission = g_currentMission
g_currentMission = { vehicleSystem = { vehicles = { { id = 1 } } }, vehicles = { { id = 99 } } }
local vList = TrafficDrag.resolveVehicleList()
T.eq("vehicleSystem.vehicles wins", #vList, 1)
T.eq("mission.vehicles not double-counted", vList[1].id, 1)
g_currentMission = { vehicles = { { id = 42 } } }
local vFallback = TrafficDrag.resolveVehicleList()
T.eq("older mission.vehicles fallback", #vFallback, 1)
T.eq("fallback vehicle id", vFallback[1].id, 42)
g_currentMission = {}
T.eq("no list -> empty table", #TrafficDrag.resolveVehicleList(), 0)
g_currentMission = oldMission

-- 4. THE CELL-AND-DAY DEDUPE (once per cell per day).
local cellA  = TrafficDrag.cellKey(1234.0, 5678.0, 10)
local cellA2 = TrafficDrag.cellKey(1236.0, 5678.0, 10)   -- same cell
local cellB  = TrafficDrag.cellKey(1244.0, 5678.0, 10)   -- adjacent cell
T.eq("same cell -> same key", cellA, cellA2)
T.ok("adjacent cell -> different key", cellA ~= cellB)

local dedupe = {}
T.ok("not fired before mark", not TrafficDrag.dedupeFired(dedupe, cellA, 7))
dedupe = TrafficDrag.markDedupe(dedupe, cellA, 7)
T.ok("fired same day", TrafficDrag.dedupeFired(dedupe, cellA, 7))
T.ok("not fired next day", not TrafficDrag.dedupeFired(dedupe, cellA, 8))
T.ok("unrelated cell not fired", not TrafficDrag.dedupeFired(dedupe, cellB, 7))

-- 5. THE DAY SOURCE: TimeGuard monotonicDay, never environment.currentDay.
T.eq("no TimeGuard -> nil day (accrual stands down)", TrafficDrag.getMonotonicDay(), nil)
g_currentMission = {
    environment = { currentDay = 3 },   -- MUST be ignored
    timeGuard = { getContext = function() return { monotonicDay = 214 } end },
}
T.eq("TimeGuard monotonicDay read", TrafficDrag.getMonotonicDay(), 214)
g_currentMission = { timeGuard = { getContext = function() error("throw") end } }
T.eq("throwing getContext -> nil", TrafficDrag.getMonotonicDay(), nil)
g_currentMission = oldMission

-- 6. THE STANDING-CROP TEST (confirm 1).
T.ok("standing crop at min state", TrafficDrag.isStandingCrop(3, 1, 1))
T.ok("standing crop above min", TrafficDrag.isStandingCrop(3, 4, 1))
T.ok("nil fruit is not standing", not TrafficDrag.isStandingCrop(nil, 4, 1))
T.ok("UNKNOWN fruit is not standing", not TrafficDrag.isStandingCrop(FruitType.UNKNOWN, 4, 1))
T.ok("state below min is not standing", not TrafficDrag.isStandingCrop(3, 0, 1))
T.ok("nil state is not standing", not TrafficDrag.isStandingCrop(3, nil, 1))

-- readStandingCrop rides the engine point read (stubbed to the in-mod GrowthCredit
-- shape: (fruitTypeIndex, growthState) in one call).
local realFruitRead = FSDensityMapUtil.getFruitTypeIndexAtWorldPos
FSDensityMapUtil.getFruitTypeIndexAtWorldPos = function(_x, _z) return 5, 3 end
local fi, gs = TrafficDrag.readStandingCrop(10, 20)
T.eq("readStandingCrop returns fruit index", fi, 5)
T.eq("readStandingCrop returns growth state", gs, 3)
FSDensityMapUtil.getFruitTypeIndexAtWorldPos = function() return 0, 0 end
local fi0, gs0 = TrafficDrag.readStandingCrop(10, 20)
T.ok("empty-state read is not standing", not TrafficDrag.isStandingCrop(fi0, gs0, 1))
FSDensityMapUtil.getFruitTypeIndexAtWorldPos = realFruitRead

-- 7. THE READ-TIME COMPOSITION (the SF-14 addendum contract, documented not wired).
T.near("nil drag composes as identity", TrafficDrag.composeRead(100, nil), 100)
T.near("one event drag -> 95%", TrafficDrag.composeRead(100, 0.05), 95)
T.near("cap drag -> 70%", TrafficDrag.composeRead(100, 0.3), 70)
T.near("zero drag -> identity", TrafficDrag.composeRead(82, 0), 82)

T.summary()
