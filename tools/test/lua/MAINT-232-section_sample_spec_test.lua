-- MAINT-232-section_sample_spec_test.lua
--
-- MAINTENANCE row 232: Soil's three sprayer section hooks read the ground under each
-- section, not one point halfway between the vehicle root and the section's tip.
--
-- THE DEFECT THIS PINS (development 766401f5): Smart Sensor (HookManager.lua:1923), See &
-- Spray (:2085) and Variable Rate (:2298) each decided a section from
-- `sx = (rootX + tip[1]) * 0.5`. An outer section read the ground inside an inner
-- section's strip, and the outer half of the boom was never read.
--
-- THE FIX: one shared sampler (HookManager:sectionSamplePoints) gives each section points
-- evenly across its own lateral ground on its boom line (#1104's section geometry).
-- - See & Spray reads every point: a section skips only when every readable point says
--   its product is not needed, and the graduated rate takes the highest share any point
--   needs (its own "never under-treat a section the check said needs spraying").
-- - Smart Sensor ("that section's world position") and Variable Rate ("the cell directly
--   under each boom section") read the section's own centre.
--
-- THE ENTRY-POINT BAR: every row installs the REAL hooks in production's order
-- (installSectionControlHook, installSeeAndSprayHook, installVariableRateHook, then the
-- REAL installSectionStatePreserver's prepend, which caches the root and the tips) and
-- drives the class Sprayer.onStartWorkAreaProcessing, through the REAL SoilSensorManager,
-- resolveCellPressure and the See & Spray weed check on FieldState. The world is in
-- MAINT-232-section_sample_world.lua: nodes, the bought option, the native weed state per
-- point, the field per point and the soil store. No sample point, section ground or rate
-- is set by hand. Asserted: which sections the hooks left spraying, and the rate stored
-- per section.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilSensorManager.lua, src/specializations/SFNozzleEffects.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-232-section_sample_world.lua

local W, boom, install, tick, spraying, section, cellKey =
    SSW.W, SSW.boom, SSW.install, SSW.tick, SSW.spraying, SSW.section, SSW.cellKey
local VR = SoilConstants.VARIABLE_RATE
local SS = SoilConstants.SEE_AND_SPRAY
local ALL = "18,15,12,9,6,3,-3,-6,-9,-12,-15,-18"

local function fields(f7, f8)
    local base = function(t)
        t.zoneData = t.zoneData or {}
        t.pestPressure = t.pestPressure or 0
        t.diseasePressure = t.diseasePressure or 0
        t.weedPressure = t.weedPressure or 0
        return t
    end
    return { [7] = base(f7 or {}), [8] = base(f8 or {}) }
end
local function stored(rate) return 1.0 * 0.6 + rate * 0.4 end   -- the hooks' 0.6/0.4 blend from a cleared tick
local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-9 end

-- ══════════════════════════════════════════════════════════
-- W: SEE & SPRAY, WEEDS (the native weed state at each point)
-- ══════════════════════════════════════════════════════════
do
    W.weeds, W.splitX = {}, math.huge
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    T.eq("W0 no weeds anywhere: every section skips", spraying(v), "")
end
do
    W.weeds, W.splitX = { { -20, 20 } }, math.huge
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    T.eq("W0b weeds everywhere: every section sprays", spraying(v), ALL)
end
do
    W.weeds, W.splitX = { { 15.2, 17.8 } }, math.huge
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    T.eq("W1 weeds only under the outermost section: it sprays, from its own ground", spraying(v), "18")
end
do
    W.weeds, W.splitX = { { 6.2, 6.8 } }, math.huge
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    T.eq("W2 weeds only near one section's inner edge, between the old halfway points: that section sprays",
         spraying(v), "9")
end
do
    -- The field ends at x 40 (lateral 15): the outermost section's points are all off it.
    W.weeds, W.splitX, W.endX = {}, math.huge, 40
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    W.endX = math.huge
    T.eq("W3 a section with no point on a field is left as it was; every other section, on clean ground, skips",
         spraying(v), "18")
end

-- ══════════════════════════════════════════════════════════
-- C: THE POINTS FOLLOW THE SPRAYER FROM TICK TO TICK
-- ══════════════════════════════════════════════════════════
do
    W.weeds, W.splitX = { { 15.2, 17.8 } }, math.huge      -- world x 40.2 to 42.8
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    local first = spraying(v)
    Sprayer.onEndWorkAreaProcessing(v, 100, true)           -- the preserver restores the sections
    SSW.ROOT.x = 35                                          -- the next tick, 10 m on across
    tick(v)
    SSW.ROOT.x = 25
    T.eq("C1 the same weeds, the sprayer 10 m along: first the outermost section, then the sections now over them",
         first .. " / " .. spraying(v), "18 / 9,6")
end

-- ══════════════════════════════════════════════════════════
-- P: SEE & SPRAY, PEST PRESSURE PER CELL, GRADUATED RATE
-- The section with its tip 6 m out spans x 28-31, across the zone cells at x 20-30
-- (pressure 20) and 30-40 (45); its points sit at 28.5, 29.5 and 30.5.
-- ══════════════════════════════════════════════════════════
do
    W.weeds, W.splitX = {}, math.huge
    local f = fields({ pestPressure = 5 })
    f[7].zoneData[cellKey(28.5, 48)] = { pestPressure = 20 }
    f[7].zoneData[cellKey(30.5, 48)] = { pestPressure = 45 }
    local sensorMgr = install(f)
    sensorMgr:toggleVariableRate("boom")
    local v = boom("INSECTICIDE", true)
    tick(v)
    local frac = (45 - SS.PEST_THRESHOLD) / (SS.FULL_RATE_PRESSURE - SS.PEST_THRESHOLD)
    local want = stored(VR.MIN_RATE + frac * (VR.MAX_RATE - VR.MIN_RATE))
    local got = sensorMgr.sectionRates.boom and sensorMgr.sectionRates.boom[section(v, 6)]
    T.ok("P1 a section across two cells takes the highest share any of its points needs (45, not 20): "
         .. string.format("%.4f", got or -1) .. " want " .. string.format("%.4f", want), near(got, want))
    T.eq("P2 and the outermost section, over pressure 5 only, skips", tostring(section(v, 18).isActive), "false")
end

-- ══════════════════════════════════════════════════════════
-- S: SMART SENSOR, "THAT SECTION'S WORLD POSITION"
-- Field 8 starts at x 39 (lateral 14) and has no pest pressure; field 7 has 30.
-- ══════════════════════════════════════════════════════════
do
    W.weeds, W.splitX = {}, 39
    local sensorMgr = install(fields({ pestPressure = 30 }, { pestPressure = 0 }))
    sensorMgr:togglePest("boom")
    local v = boom("INSECTICIDE", false)
    tick(v)
    T.eq("S1 the outermost section's own centre is on field 8, which needs no insecticide: it alone skips",
         spraying(v), "15,12,9,6,3,-3,-6,-9,-12,-15,-18")
end

-- ══════════════════════════════════════════════════════════
-- V: VARIABLE RATE, "THE CELL DIRECTLY UNDER EACH BOOM SECTION"
-- Field 7 has N 30 (a deficit), field 8 N 80 (none), split at x 39.
-- ══════════════════════════════════════════════════════════
do
    W.weeds, W.splitX = {}, 39
    local sensorMgr = install(fields({ nitrogen = 30 }, { nitrogen = 80 }))
    sensorMgr:toggleVariableRate("boom")
    local v = boom("UAN32", false)
    tick(v)
    local rates = sensorMgr.sectionRates.boom or {}
    local deficit7 = (VR.NUTRIENT_TARGET - 30) / VR.NUTRIENT_TARGET
    T.ok("V1 the outermost section's own centre is on field 8: the lowest rate, from its own ground",
         near(rates[section(v, 18)], stored(VR.MIN_RATE)))
    T.ok("V2 the next section's centre is on field 7: the rate for N 30",
         near(rates[section(v, 15)], stored(VR.MIN_RATE + deficit7 * (VR.MAX_RATE - VR.MIN_RATE))))
end

SSW.restore()
