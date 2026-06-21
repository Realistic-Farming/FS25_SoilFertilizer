-- compaction_test.lua — pure scoring for the ground-pressure compaction model.
-- Guards SoilCompactionModel.scorePoints / advanceWetness: the agronomy-based math that
-- replaced the old flat "≥8 t = +8 points" rule (Talia's Discord feedback). Expected
-- values are derived from the constants so tuning changes don't false-fail the test.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilCompactionModel.lua

local cp  = SoilConstants.COMPACTION
local gp  = cp.GROUND_PRESSURE
local al  = cp.AXLE_LOAD
local m   = cp.MOISTURE

local score   = SoilCompactionModel.scorePoints
local wetnessOf = SoilCompactionModel.advanceWetness

-- Pressures/axle loads chosen relative to the floors/refs so the test tracks tuning.
local LOW_P   = gp.FLOOR_KPA - 10    -- below surface floor → no surface term
local LIGHT_A = al.FLOOR_T  - 1      -- below axle floor → no subsoil term

-- 1. Big flotation tyres on dry soil, light axle → nothing. (The whole point Talia made:
--    a well-tyred machine should NOT compact just for being heavy.)
T.eq("dry low-pressure light-axle adds nothing", score(LOW_P, LIGHT_A, 0, 1), 0)

-- 2. Full surface pressure, sub-floor axle, dry → exactly SURFACE_MAX × DRY_MULT.
T.near("full surface dry = SURFACE_MAX*DRY_MULT",
       score(gp.REF_KPA, LIGHT_A, 0, 1), gp.SURFACE_MAX * m.DRY_MULT)

-- 3. Sub-floor pressure, full axle load, dry → exactly SUBSOIL_MAX × DRY_MULT.
--    Deep damage a big tyre can't dodge (PSU: subsoil ∝ axle load).
T.near("full subsoil dry = SUBSOIL_MAX*DRY_MULT",
       score(LOW_P, al.REF_T, 0, 1), al.SUBSOIL_MAX * m.DRY_MULT)

-- 4. nil pressure still scores the subsoil term (geometry unavailable but mass known).
T.near("nil pressure → subsoil only",
       score(nil, al.REF_T, 0, 1), al.SUBSOIL_MAX * m.DRY_MULT)

-- 5. Wet soil compacts more than dry at the same pressure ("hydraulic ram").
local midP = (gp.FLOOR_KPA + gp.REF_KPA) * 0.5
T.ok("wet > dry at same pressure", score(midP, LIGHT_A, 1, 1) > score(midP, LIGHT_A, 0, 1))
T.near("saturated = SURFACE @mid × WET_MULT",
       score(midP, LIGHT_A, 1, 1),
       gp.SURFACE_MAX * ((midP - gp.FLOOR_KPA) / (gp.REF_KPA - gp.FLOOR_KPA)) * m.WET_MULT)

-- 6. Variable Tire Pressure payoff: FIELD mode (≈1 bar) packs less than ROAD (≈2 bar).
--    VTP surface pressure = bar*BAR_TO_KPA + CONTACT_OFFSET_KPA.
local fieldKPa = 1.0 * gp.BAR_TO_KPA + gp.CONTACT_OFFSET_KPA
local roadKPa  = 2.0 * gp.BAR_TO_KPA + gp.CONTACT_OFFSET_KPA
T.ok("VTP field mode compacts less than road mode",
     score(fieldKPa, LIGHT_A, 0, 1) < score(roadKPa, LIGHT_A, 0, 1))

-- 7. Monotonic in pressure and in axle load.
T.ok("more pressure → more compaction", score(220, LIGHT_A, 0, 1) > score(160, LIGHT_A, 0, 1))
T.ok("more axle load → more compaction", score(LOW_P, al.REF_T, 0, 1) > score(LOW_P, al.FLOOR_T + 1, 0, 1))

-- 8. tuningCompactionRate = 0 disables build-up entirely (idx 1 in the ZERO_MULT LUT).
T.eq("rate 0 → no compaction", score(gp.REF_KPA, al.REF_T, 1, 0), 0)
-- ...and doubling the rate doubles the result.
T.near("rate 2x doubles", score(gp.REF_KPA, LIGHT_A, 0, 2), score(gp.REF_KPA, LIGHT_A, 0, 1) * 2)

-- 9. Wetness tracker: rain pins to 1; dries to 0 over DECAY_HOURS; never goes negative.
T.eq("rain pins wetness to 1", wetnessOf(0.0, 5, true), 1.0)
T.near("half decay → 0.5", wetnessOf(1.0, m.DECAY_HOURS * 0.5, false), 0.5)
T.near("full decay → 0", wetnessOf(1.0, m.DECAY_HOURS, false), 0)
T.eq("over-decay clamps at 0 (no negative)", wetnessOf(1.0, m.DECAY_HOURS * 3, false), 0)

T.summary()
