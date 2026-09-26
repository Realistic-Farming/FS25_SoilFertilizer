-- MAINT-106-store_floor_before_add_spec_test.lua
--
-- MAINTENANCE row 106 (Bob's widened intake, 2026-09-24; origin SF-49 store code).
-- The two aimed-delta paths of SoilValueMaps ran their edge pass AFTER the add:
--   (a) a negative band floored only at the RAW_MIN edge, so the dry pass (floorTo the
--       EMC ceiling) took a pixel a few raw above the floor below it, and from raw
--       32..46 into the reserved band as a REFUSAL; the tedder passed no floorTo at all;
--   (b) the positive side's saturate followed the add, so a wetting step carried a
--       pixel into the saturate window and it was then set to the ceiling (over-wet);
--   (c) applyRawDeltaToLayer had the same order, so a MaterialDown catch-up of d days
--       aged a pixel near the ceiling by up to d - 1 days more than it lived.
-- Now the edge pass runs first in both paths, a negative add starts at floorTo + step,
-- the floor pass takes only pixels at or above the floor (a sentinel inside a caller's
-- band is left as it is), and HayBet passes floorTo = RAW_FLOOR.
--
-- THE ENTRY-POINT BAR IS GROUPS D, A AND W. The store is a SoilValueMaps through its
-- own initialize over the SF-995 pixel engine model (64 px, one metre a pixel); the
-- owners are MaterialDown, MaterialWetness and HayBet through their own new and arm.
-- The dry day enters through MaterialWetness:onConditionAccrual (the Time Guard
-- accrual) with a WeatherGuard sky; the age catch-up through MaterialDown:onAgeTick;
-- the wet pass is MaterialWetness:wetPass, the call settleOneDay makes after the dry
-- pass. Pixels are written through the store's own setPolygonWhere. Nothing sets a
-- window, a band or a pixel by hand. Group T drives HayBet:applyTedderDelta, the call
-- HookManager's tedder hook makes, not the hook itself. Group S is the store's own
-- contract, for the one clause no caller reaches (a band starting below its floor)
-- and for PositionalPH's call shape.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

g_server = {}
local SKY = { humidity = 20, temperature = 30, cloudCoverage = 0 }
local RAIN = { rainScale = 0 }
g_currentMission = {
    weatherGuard = {
        getCurrentSky = function() return SKY end,
        getEffectiveRain = function() return RAIN end,
    },
    environment = { currentSeason = 2, currentMonotonicDay = 10, daysPerPeriod = 1 },
}

local vm = SoilValueMaps.new()
vm:initialize("/save")
local FIELDS = {}
local soilSystem = { fieldData = {}, _getFieldPolyVerts = function(_, fieldId) return FIELDS[fieldId] end }
local md = MaterialDown.new()
local mw = MaterialWetness.new()
local hb = HayBet.new()
local armed = tostring(md:arm(vm)) .. "/" .. tostring(mw:arm(vm, md, soilSystem)) .. "/" .. tostring(hb:arm(md, mw))

local HALF = ENGINE.TERRAIN * 0.5
--- The world box of pixels ix0..ix1 by iz0..iz1, inset so only their centres are inside.
local function box(ix0, iz0, ix1, iz1)
    local x0, z0, x1, z1 = -HALF + ix0 + 0.1, -HALF + iz0 + 0.1, -HALF + ix1 + 0.9, -HALF + iz1 + 0.9
    return { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } }
end
local function put(key, ix, iz, raw) return vm:setPolygonWhere(key, box(ix, iz, ix, iz), raw, 0, SoilValueMaps.RAW_MAX) end
local function at(key, ix, iz) return vm:readRawAtWorld(key, -HALF + ix + 0.5, -HALF + iz + 0.5) end
local WET, AGE = MaterialWetness.LAYER_KEY, MaterialDown.LAYER_KEY

T.eq("R0 [reached] the store initialized and the three owners armed through their own arm", tostring(vm.available) .. "/" .. armed, "true/true/true/true")

-- ══════════════════════════════════════════════════════════════════════════
-- D. A DRY DAY FLOORS AT THE EMC CEILING, BEFORE THE STEP (row 106 (a))
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local emcRaw = MaterialWetness.pctToRaw(MaterialWetness.emcFor(SKY.humidity, SKY.temperature))
    local step = MaterialWetness.pointsToRawDelta(6 * MaterialWetness.weatherMultiplier(SKY.cloudCoverage, nil))
    T.eq("D0 the sky's EMC floor is raw 32 and the bound phase's step is 18 raw", emcRaw .. "/" .. step, "32/18")
    FIELDS[1] = box(10, 10, 12, 10)
    md:markFieldActive(1)
    put(WET, 10, 10, emcRaw + 3)
    put(WET, 11, 10, emcRaw + step + 2)
    put(WET, 12, 10, 90)
    mw:onConditionAccrual({ monotonicDay = 10, boundariesCrossed = 1 })
    T.eq("D1 a dry day through the accrual: a pixel 3 above the EMC floor parks at the floor (32) instead of stepping 18 into the reserved band, and the field's probe reads ok, not a refusal",
        at(WET, 10, 10) .. "/" .. tostring(mw:probeCondition(FIELDS[1]).status), "32/ok")
    T.eq("D2 a pixel two above floor plus a step drops by exactly the step, to 34, one at 90 to 72, and the day is settled",
        at(WET, 11, 10) .. "/" .. at(WET, 12, 10) .. "/" .. tostring(mw.appliedThroughDay), "34/72/10")
    md:markFieldClear(1)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. THE TEDDER FLOORS AT THE RESERVED BAND (row 106, HayBet)
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local verts = box(10, 20, 11, 20)
    put(WET, 10, 20, 200)
    put(WET, 11, 20, 35)
    local ok = hb:applyTedderDelta(verts)
    T.eq("T1 the tedder over a swath with a nearly dry pixel: that pixel parks at 32, the wet one dries to 179, and the area probe reads ok, not a refusal",
        tostring(ok) .. "/" .. at(WET, 10, 20) .. "/" .. at(WET, 11, 20) .. "/" .. tostring(mw:probeCondition(verts).status), "true/179/32/ok")

    -- A humid, cold sky: the EMC ceiling sits well above the reserved band.
    local dry = SKY
    SKY = { humidity = 90, temperature = 5, cloudCoverage = 0 }
    local emcRaw = MaterialWetness.emcRawFor(SKY)
    local humid = box(10, 24, 12, 24)
    put(WET, 10, 24, 200)
    put(WET, 11, 24, emcRaw + 5)
    put(WET, 12, 24, emcRaw - 10)
    local okH = hb:applyTedderDelta(humid)
    T.eq("T2 under a humid, cold sky (EMC raw 62) the tedder parks a pixel at 67 at the EMC, not a step below it, and dries the wet one by its step to 180",
        tostring(okH) .. "/" .. emcRaw .. "/" .. at(WET, 10, 24) .. "/" .. at(WET, 11, 24), "true/62/180/62")
    T.eq("T3 a pixel already drier than the EMC (52 under an EMC of 62) is neither raised to the EMC nor dried further",
        tostring(at(WET, 12, 24)), "52")
    SKY = dry

    -- No WeatherGuard: no sky, so no EMC to read.
    local wg = g_currentMission.weatherGuard
    g_currentMission.weatherGuard = nil
    local bare = box(10, 26, 11, 26)
    put(WET, 10, 26, 200)
    put(WET, 11, 26, 40)
    local okN = hb:applyTedderDelta(bare)
    g_currentMission.weatherGuard = wg
    T.eq("T4 with no sky there is no EMC: the tedder floors at RAW_FLOOR, so a pixel at 40 parks at 32 and the area probe reads ok, not a refusal",
        tostring(okN) .. "/" .. at(WET, 10, 26) .. "/" .. at(WET, 11, 26) .. "/" .. tostring(mw:probeCondition(bare).status), "true/180/32/ok")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. A CATCH-UP AGES BY THE DAYS LIVED, NO MORE (row 106 (c))
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    put(AGE, 20, 10, 250)
    put(AGE, 21, 10, 253)
    put(AGE, 22, 10, 100)
    md:onAgeTick({ monotonicDay = 5, boundariesCrossed = 3 })
    T.eq("A1 a three-day catch-up ages a pixel at 250 to 253, not to the ceiling; one at 253 saturates at 255, one at 100 reaches 103, and bare ground stays 0",
        at(AGE, 20, 10) .. "/" .. at(AGE, 21, 10) .. "/" .. at(AGE, 22, 10) .. "/" .. at(AGE, 23, 10), "253/255/103/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. A WET STEP ADDS ITS STEP, NO MORE (row 106 (b))
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    FIELDS[3] = box(10, 30, 12, 30)
    md:markFieldActive(3)
    put(WET, 10, 30, 200)
    put(WET, 11, 30, 230)
    put(WET, 12, 30, 24)
    local watered, source = mw:wetPass({ rainScale = 1 })
    T.eq("W1 a full rain day's 38-raw step takes a pixel at 200 to 238, not to the ceiling; one at 230 saturates at 255, and a refusal at 24 stays a refusal",
        tostring(watered) .. "/" .. source .. "/" .. MaterialWetness.pointsToRawDelta(MaterialWetness.RAIN_SETBACK_PER_DAY) .. "/" .. at(WET, 10, 30) .. "/" .. at(WET, 11, 30) .. "/" .. at(WET, 12, 30), "true/rain/38/238/255/24")
    md:markFieldClear(3)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE STORE'S OWN CONTRACT
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    put(WET, 40, 40, 24)
    vm:applyRawDeltaToPolygonBand(WET, box(40, 40, 40, 40), -10, 16, SoilValueMaps.RAW_MAX, { floorTo = 32 })
    put("pH", 41, 40, 10)
    put("pH", 42, 40, 3)
    vm:applyRawDeltaToPolygonBand("pH", box(41, 40, 42, 40), -5, 1, SoilValueMaps.RAW_MAX, {})
    T.eq("S1 a caller band that starts below its floor leaves a sentinel pixel at 24 as it is: not raised to the floor, not stepped deeper",
        tostring(at(WET, 40, 40)), "24")
    T.eq("S2 PositionalPH's call shape (no floorTo): a -5 step takes raw 10 to 5 and raw 3 floors at 1; the floor pass no longer takes the pixel the add just lowered",
        at("pH", 41, 40) .. "/" .. at("pH", 42, 40), "5/1")
end)
