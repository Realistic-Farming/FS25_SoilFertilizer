-- MAINT-168-insecticide_coverage_name_spec_test.lua: MAINTENANCE row 168, the
-- insecticide direct route tags coverage with the pass's real fill name.
--
-- The sprayer hook tracks every pass under fillType.name (HookManager :6106, the trackSprayerCoverage call), and
-- onInsecticideAppliedDirect tracked it again under the literal "INSECTICIDE" with the
-- fractions on. The only name that reaches this route is PESTICIDE, a compatibility slot
-- for a mod that registers a fill type by that name; no base-game, PF or known mod does, so
-- this bar pins real code on a route no base-game product reaches. SF's own INSECTICIDE is
-- a fertilizer profile and takes applyFertilizer. For such a mod product,
-- sessionLastProduct flipped twice a pass and the product-change reset (#442) wiped
-- the session's coverage and work trail every tick. The route now receives the name from
-- the hook and tracks name-only, the twin of the named-fungicide fix (8463752d).
--
-- ENTRY-POINT BAR: PESTICIDE passes through the real sprayer hook into the real soil
-- system (MAINT-166-protection_sprayer_world.lua) on a rig with no variable-width
-- sections, so coverage takes the hook's litres path: litres over the product's reference
-- rate (PESTICIDE has no BASE_RATES entry, so SPRAYER_RATE.BASE_RATES.DEFAULT, 93.5 L/ha)
-- over the field's 0.2 ha, so one 6 L pass is about 32%. Nothing sets a fraction by hand.
--
--   L1  one 6 L pass counts its litres ONCE (about 32%, not 64%)
--   L2  the session keeps the pass's own name (no flip)
--   L3  a second pass adds to the first (about 64%): no reset between the hook and the route
--   L4  the third pass reaches about 96% and grants protection in that pass
--   L5  the work trail holds every pass's cell
--
-- Targeted mutations: revert to the literal "INSECTICIDE" (L2 to L5 must fail), and drop
-- `false` (L1 must fail).
--
-- Not proven here: the multi-tank replay's own tracking of a second product (a separate
-- question, raised by Bob with Desk), and anything in game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group
local BR = SoilConstants.SPRAYER_RATE.BASE_RATES
local PER_PASS = 6 / (BR.PESTICIDE or BR.DEFAULT).value / 0.2   -- one 6 L pass, as a fraction of 0.2 ha

group("L litres path", function()
  local w = PSW.new({ product = "PESTICIDE", noVww = true })
  T.eq("L0 [reached: the real installSprayerAreaHook installed on a rig with no VWW sections]", w.installed == true and w.vehicle.spec_variableWorkWidth == nil, true)
  w:tick(6, w:cells(1, 1))
  local f = w:field()
  T.ok("L1 NAMED: one 6 L pass counts its litres once (about 32% of the field)", math.abs((f.sessionCoverageFraction or 0) - PER_PASS) < 1e-6)
  T.eq("L2 NAMED: the session keeps the pass's own name, PESTICIDE", f.sessionLastProduct, "PESTICIDE")
  w:tick(6, w:cells(2, 2))
  T.ok("L3 NAMED: a second pass adds to the first (about 64%)", math.abs((f.sessionCoverageFraction or 0) - 2 * PER_PASS) < 1e-6)
  T.eq("L3b [reached: no protection below 80%]", f.insecticideDaysLeft or 0, 0)
  T.ok("L3c [reached: three passes cross 80%, two do not]", 2 * PER_PASS < 0.80 and 3 * PER_PASS >= 0.80)
  w:tick(6, w:cells(3, 3))
  T.ok("L4 NAMED: the third pass reaches about 96% and grants protection in that pass", math.abs((f.sessionCoverageFraction or 0) - 3 * PER_PASS) < 1e-6 and (f.insecticideDaysLeft or 0) > 0)
  T.eq("L5 NAMED: the work trail holds every pass's cell", f.sprayTrailPts ~= nil and #f.sprayTrailPts or 0, 3)
end)

PSW.restore()
