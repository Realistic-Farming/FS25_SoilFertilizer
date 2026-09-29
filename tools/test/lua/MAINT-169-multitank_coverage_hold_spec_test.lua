-- MAINT-169-multitank_coverage_hold_spec_test.lua: MAINTENANCE row 169, a multi-tank
-- rig's coverage builds across the pass.
--
-- In the sprayer hook's secondary-tank replay, every secondary tracked coverage under its
-- own product name. A name different from the active tank's tripped the #442 product
-- reset (trackSprayerCoverage runs it before its name-only return), so the session was
-- wiped every tick and never built past one tick's worth; the work trail went with it and
-- RSF-F226's >= 99% overlap gate could never arm. The hook now holds coverage while the
-- secondaries replay (set just before the loop, cleared just after it and at the top of
-- every tick), and trackSprayerCoverage returns at once while the hold is set. The rule:
-- in one tick the active tank's product is the pass's identity, and a secondary is
-- neither a product change nor new ground.
--
-- ENTRY-POINT BAR: every tick runs through the real installSprayerAreaHook into the real
-- SoilFertilitySystem on the row-166 world, with a real second fill unit
-- (opts.secondTank). Coverage comes from the passes: the hook's litres path on a rig with
-- no VWW sections, markBoomCells' cells on one with them. Nothing sets a fraction.
--
--   C  one-tank controls: FERTILIZER on both paths and HERBICIDE on the litres path
--      accumulate tick by tick (the values the other groups are compared against), and a
--      FERTILIZER litres tick keeps development's absolute figure
--   T  FERTILIZER + LIQUIDFERTILIZER: accumulates exactly as the control, the session
--      stays FERTILIZER, and tank 2 drains (the loop ran)
--   H  FERTILIZER + a HERBICIDE secondary: the same, and the herbicide still reduces
--   S  #442 kept: switching tank 1's product restarts the session
--   X  a secondary that throws mid-loop leaves no hold behind: the next tick counts
--   F  a two-tank field reaches the >= 99% the overlap gate reads (HookManager :2647-2648)
--
-- Targeted mutations: remove the guard in trackSprayerCoverage (T, H and F fail); remove
-- the clear after the loop (C1b and T3b fail); remove the clear at the tick's top
-- (X fails); hold coverage around the pre-loop track at :5953 too (the HERBICIDE
-- control fails).
--
-- Not proven here: the F196 multi-tank quantity questions (Design's), per-product
-- sessions (not proposed), and anything in game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group

local function cellCount(f)
  local n = 0
  for _ in pairs(f.sessionCoverageCells or {}) do n = n + 1 end
  return n
end

--- Three ticks of 10 L over three distinct cells; one snapshot per tick.
local function run(opts)
  local w = PSW.new(opts)
  local snaps = {}
  for i = 1, 3 do
    w:tick(10, w:cells(i, i))
    local f = w:field()
    snaps[i] = { ha = f.sessionCoverageHa or 0, cells = cellCount(f), last = f.sessionLastProduct }
  end
  return w, snaps
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

-- ── C: one-tank controls ─────────────────────────────────────────────────────
local CL, CV, CH
group("C controls", function()
  local _, s = run({ product = "FERTILIZER", noVww = true, areaHa = 1.0 })
  CL = s
  T.ok("C1 [reached: FERTILIZER on the litres path counts a tick]", s[1].ha > 0)
  -- Development's value, unchanged here: a one-tank FERTILIZER tick on the litres path is
  -- counted by two tracks, the pre-loop one at :5953 (its updateFractions is nil, not
  -- false, for a fertilizer with no crop-protection effect) and the post-loop one. That
  -- doubling is pre-existing and raised separately; this row pins that row 169 leaves the
  -- one-tank figure exactly as it was.
  T.ok("C1b one FERTILIZER tick counts 2 x 10 L / 225 L/ha, development's figure", near(s[1].ha, 2 * 10 / SoilConstants.SPRAYER_RATE.BASE_RATES.FERTILIZER.value))
  T.ok("C2 and accumulates tick by tick", near(s[2].ha, 2 * s[1].ha) and near(s[3].ha, 3 * s[1].ha))
  local _, v = run({ product = "FERTILIZER", areaHa = 1.0 })
  CV = v
  T.eq("C3 FERTILIZER on the VWW path marks cells 1/2/3", v[1].cells .. "/" .. v[2].cells .. "/" .. v[3].cells, "1/2/3")
  local _, h = run({ product = "HERBICIDE", noVww = true, areaHa = 1.0 })
  CH = h
  T.ok("C4 NAMED: HERBICIDE on the litres path (the pre-loop track) accumulates", h[1].ha > 0 and near(h[3].ha, 3 * h[1].ha))
end)

-- ── T: two fertilizers ───────────────────────────────────────────────────────
group("T two fertilizers", function()
  local w, s = run({ product = "FERTILIZER", secondTank = "LIQUIDFERTILIZER", noVww = true, areaHa = 1.0 })
  T.ok("T1 [reached: tank 2 drained, so the secondary loop ran]", w.units[2].fillLevel < 5000)
  T.ok("T2 NAMED: litres path, the two-tank session accumulates exactly as the one-tank control",
    near(s[1].ha, CL[1].ha) and near(s[2].ha, CL[2].ha) and near(s[3].ha, CL[3].ha))
  T.eq("T3 the session stays the active tank's product", s[3].last, "FERTILIZER")
  T.eq("T3b NAMED: the hold is released once the secondary loop ends", w.sys._multiTankCoverageHold, nil)
  local wv, v = run({ product = "FERTILIZER", secondTank = "LIQUIDFERTILIZER", areaHa = 1.0 })
  T.ok("T4 [reached: VWW rig, tank 2 drained]", wv.units[2].fillLevel < 5000)
  T.eq("T5 NAMED: VWW path, cells 1/2/3 as the control", v[1].cells .. "/" .. v[2].cells .. "/" .. v[3].cells, "1/2/3")
  T.ok("T6 and the work trail holds all three passes", #(wv:field().sprayTrailPts or {}) >= 3)
end)

-- ── H: a herbicide secondary ─────────────────────────────────────────────────
group("H herbicide secondary", function()
  local w, s = run({ product = "FERTILIZER", secondTank = "HERBICIDE", noVww = true, areaHa = 1.0 })
  T.ok("H1 [reached: the herbicide tank drained]", w.units[2].fillLevel < 5000)
  T.ok("H2 NAMED: the session accumulates exactly as the one-tank control",
    near(s[1].ha, CL[1].ha) and near(s[2].ha, CL[2].ha) and near(s[3].ha, CL[3].ha))
  T.eq("H3 the session stays FERTILIZER", s[3].last, "FERTILIZER")
  local d = w.sys.herbicideDailyApplied and w.sys.herbicideDailyApplied[7]
  T.ok("H4 the herbicide route still reduced weed pressure (the day's reduction is spent into)", d ~= nil and d.applied > 0)
  local _, v = run({ product = "FERTILIZER", secondTank = "HERBICIDE", areaHa = 1.0 })
  T.eq("H5 VWW path, cells 1/2/3", v[1].cells .. "/" .. v[2].cells .. "/" .. v[3].cells, "1/2/3")
end)

-- ── S: #442 kept ─────────────────────────────────────────────────────────────
group("S product switch", function()
  local _, one = run({ product = "LIQUIDFERTILIZER", noVww = true, areaHa = 1.0 })
  local w = PSW.new({ product = "FERTILIZER", secondTank = "LIQUIDFERTILIZER", noVww = true, areaHa = 1.0 })
  w:tick(10, w:cells(1, 1)); w:tick(10, w:cells(2, 2))
  T.ok("S1 [reached: two ticks of FERTILIZER counted]", near(w:field().sessionCoverageHa or 0, CL[2].ha))
  w:setProduct("LIQUIDFERTILIZER")
  w:tick(10, w:cells(3, 3))
  local f = w:field()
  T.eq("S2 NAMED: switching tank 1's product restarts the session under the new product", f.sessionLastProduct, "LIQUIDFERTILIZER")
  T.ok("S3 with that one tick's coverage only (#442)", near(f.sessionCoverageHa or 0, one[1].ha))
end)

-- ── X: a throwing secondary leaves no hold ───────────────────────────────────
group("X throwing secondary", function()
  local w = PSW.new({ product = "HERBICIDE", secondTank = "LIQUIDFERTILIZER", noVww = true, areaHa = 1.0 })
  local sys = w.sys
  local real = sys.onFertilizerApplied
  sys.onFertilizerApplied = function() error("synthetic secondary failure") end
  local okTick = pcall(w.tick, w, 10, w:cells(1, 1))
  T.eq("X1 [reached: the throw inside the secondary loop is contained by the hook]", okTick, true)
  T.ok("X2 [reached: the tick's pre-loop track had counted]", near(w:field().sessionCoverageHa or 0, CH[1].ha))
  sys.onFertilizerApplied = real
  w:tick(10, w:cells(2, 2))
  T.ok("X3 NAMED: the next tick's pre-loop track still counts: no hold was left set", near(w:field().sessionCoverageHa or 0, CH[2].ha))
end)

-- ── F: RSF-F226's gate input ─────────────────────────────────────────────────
group("F overlap gate input", function()
  -- A trickle per tick, so only the passes' own cells can carry the field to 99% (on this
  -- small field 10 L of litres alone would).
  local w = PSW.new({ product = "FERTILIZER", secondTank = "LIQUIDFERTILIZER", areaHa = 0.05 })
  for i = 1, 4 do w:tick(0.1, w:cells(i, i)) end
  T.ok("F0 [reached: four of five cells leave the field under 99%]", (w:field().sessionCoverageFraction or 0) < 0.99)
  w:tick(0.1, w:cells(5, 5))
  T.ok("F1 NAMED: the fifth cell carries the two-tank field to the >= 99% the overlap gate reads",
    (w:field().sessionCoverageFraction or 0) >= 0.99)
end)

PSW.restore()
