-- MAINT-166-grant_weed_map_spec_test.lua: MAINTENANCE row 166, the herbicide
-- protection grant writes no weed map.
--
-- On the first protection grant, onHerbicideAppliedDirect called
-- applyWeedMapState(fieldId, WITHERED). That reads ONE weed state at the field's
-- centre, takes its herbicide replacement, and enqueues a FieldUpdateTask over the
-- whole field polygon (SoilFertilitySystem.lua:2029-2066 at 657c0b0a). With a live
-- centre on a field sprayed to the 80% threshold, the unsprayed ground lost its live
-- weeds in the game's weed map and clean ground took withered ones. Vanilla herbicide
-- already withers what the pass sprays, so the write is removed; the dead
-- once-per-day onHerbicideApplied loses the same call.
--
-- ENTRY-POINT BAR: group G drives herbicide passes through the real sprayer hook into
-- the real soil system (MAINT-166-protection_sprayer_world.lua): the field record
-- comes from scanFields, coverage from the passes' own markBoomCells, the settings
-- from a real Settings object. Nothing sets a coverage fraction or a days count.
--
--   W  the world can fail the way production failed: applyWeedMapState itself, called
--      directly on this live-centre field, still enqueues one whole-polygon task
--   G  herbicide sprayed past 80% through the hook: protection is granted, and no
--      weed-map task is enqueued
--   D  the dead onHerbicideApplied grants and enqueues nothing either
--
-- Targeted mutations: put the call back in onHerbicideAppliedDirect (G must fail), and
-- in onHerbicideApplied (D must fail).
--
-- Not proven here: the engine's own herbicide browning of sprayed ground
-- (FSDensityMapUtil.updateHerbicideArea, read, not run), and anything in game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group
local WITHERED = SoilConstants.WEED_PRESSURE.WEED_STATE_WITHERED

-- ── W: the world can detect the write ───────────────────────────────────────────
group("W world", function()
  local w = PSW.new()
  T.eq("W1 [reached: scanFields made the field record]", w:field() ~= nil, true)
  w.sys:applyWeedMapState(7, WITHERED)
  T.eq("W2 [reached: with a live centre, applyWeedMapState enqueues one task]", #w.tasks, 1)
  T.eq("W3 over the whole field polygon", w.tasks[1] and w.tasks[1].area, "field7-polygon")
  T.eq("W4 with the live state's replacement (fixture state 2 -> 6)", w.tasks[1] and w.tasks[1].weedState, 6)
end)

-- ── G: the grant through the real hook ──────────────────────────────────────────
group("G grant through the hook", function()
  local w = PSW.new()
  T.eq("G1 [reached: the real installSprayerAreaHook installed]", w.installed, true)
  -- One new cell of twenty per pass, a little herbicide each pass, far under the day's
  -- cap. Within a pass the hook runs onHerbicideAppliedDirect before markBoomCells, so
  -- the grant reads the fraction the previous pass left.
  for i = 1, 15 do w:tick(0.2, w:cells(i, i)) end
  local f = w:field()
  T.ok("G2 [reached: after 15 passes the coverage is under 80%]", (f.sessionCoverageFraction or 0) < 0.80)
  T.eq("G3 and there is no protection yet", f.herbicideDaysLeft or 0, 0)
  w:tick(0.2, w:cells(16, 16))
  T.ok("G4 [reached: pass 16 takes the passes' own coverage past 80%]", (f.sessionCoverageFraction or 0) >= 0.80)
  w:tick(0.2, w:cells(17, 17))
  T.ok("G5 [reached: pass 17 grants protection]", (f.herbicideDaysLeft or 0) > 0)
  T.eq("G6 NAMED: the first grant enqueues no weed-map task", #w.tasks, 0)
  for i = 18, 20 do w:tick(0.2, w:cells(i, i)) end
  T.eq("G7 further passes on the protected field enqueue nothing either", #w.tasks, 0)
  T.ok("G8 and protection holds", (f.herbicideDaysLeft or 0) > 0)
end)

-- ── D: the dead once-per-day path ───────────────────────────────────────────────
group("D dead onHerbicideApplied", function()
  local w = PSW.new()
  w.sys:onHerbicideApplied(7, 1.0)
  T.ok("D1 [reached: the once-per-day path granted]", (w:field().herbicideDaysLeft or 0) > 0)
  T.eq("D2 NAMED: and enqueued no weed-map task", #w.tasks, 0)
end)

PSW.restore()
