-- no_till_om_spec_test.lua - #738 no-till organic-matter dynamics.
--   The tillage choice is a long-term soil-carbon decision. Three coordinated terms
--   on the existing OM model: (1) a per-tillage OXIDATION gradient, (2) a fenced
--   no-till daily credit, (3) the retirement of strip-till's separate OM_BOOST into
--   the single residue+oxidation gradient (Tyson's ruling, 2026-07-24).
--   The contract this bench locks: the SEASON OM trajectory ranks
--   direct-drill > strip-till > cultivator > plough, with physical monotonicity
--   (oxidation strictly tracks soil disturbance) preserved.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local om = SoilConstants.OM_DYNAMICS
local ri = SoilConstants.RESIDUE_INCORPORATION

-- ── Constants contract: the gradient, the credit, the retirement ──
do
  T.ok("PLOW_OXIDATION_LOSS retired (folded into the OXIDATION gradient)", om.PLOW_OXIDATION_LOSS == nil)
  T.ok("OXIDATION gradient table present", type(om.OXIDATION) == "table")
  T.near("oxidation PLOW = 0.14",         om.OXIDATION.PLOW,         0.14)
  T.near("oxidation CULTIVATOR = 0.06",   om.OXIDATION.CULTIVATOR,   0.06)
  T.near("oxidation STRIP_TILL = 0.02",   om.OXIDATION.STRIP_TILL,   0.02)
  T.near("oxidation DIRECT_DRILL = 0.00", om.OXIDATION.DIRECT_DRILL, 0.00)

  T.near("no-till daily credit = 0.004", om.NO_TILL_DAILY_CREDIT, 0.004)
  T.ok("no-till daily credit is positive", om.NO_TILL_DAILY_CREDIT > 0)

  -- The separate strip-till OM_BOOST is retired (Tyson's ruling): one gain term
  -- (residue) and one loss term (oxidation) per tillage type.
  T.ok("strip-till OM_BOOST retired", SoilConstants.STRIP_TILL.OM_BOOST == nil)

  -- Residue incorporation is UNCHANGED by #738 (the ruled candidate set). Strip-till's
  -- generosity is preserved by its LOW oxidation, not a bloated residue value - folding
  -- the old +0.10 in here would have tied/beaten direct-drill and broken the ordering.
  T.near("residue OM PLOW unchanged 0.15",         ri.PLOW.OM,         0.15)
  T.near("residue OM CULTIVATOR unchanged 0.08",   ri.CULTIVATOR.OM,   0.08)
  T.near("residue OM STRIP_TILL unchanged 0.05",   ri.STRIP_TILL.OM,   0.05)
  T.near("residue OM DIRECT_DRILL unchanged 0.03", ri.DIRECT_DRILL.OM, 0.03)
end

-- ── Oxidation monotone with disturbance; per-pass and season ordering ──
do
  local ox = om.OXIDATION
  T.ok("oxidation strictly monotone with disturbance PLOW>CULT>STRIP>DRILL",
       ox.PLOW > ox.CULTIVATOR and ox.CULTIVATOR > ox.STRIP_TILL and ox.STRIP_TILL >= ox.DIRECT_DRILL)

  -- Per-pass net OM = residue gain minus that type's own oxidation.
  local netPlow  = ri.PLOW.OM         - ox.PLOW
  local netCult  = ri.CULTIVATOR.OM   - ox.CULTIVATOR
  local netStrip = ri.STRIP_TILL.OM   - ox.STRIP_TILL
  local netDrill = ri.DIRECT_DRILL.OM - ox.DIRECT_DRILL

  T.ok("per-pass net rises as disturbance falls: plough < cultivator < strip-till",
       netPlow < netCult and netCult < netStrip)
  T.ok("every tilled type still nets positive per pass (residue outweighs its own oxidation)",
       netPlow > 0 and netCult > 0 and netStrip > 0)

  -- Ruled SEASON ordering. Indicative 3 tillage passes over a ~60-day season; the daily
  -- no-till credit lifts direct-drill above the tilled lineup. The universal daily OM
  -- decay hits every field equally, so it is a common baseline excluded from the ranking.
  local PASSES, DAYS = 3, 60
  local sPlow  = PASSES * netPlow
  local sCult  = PASSES * netCult
  local sStrip = PASSES * netStrip
  local sDrill = PASSES * netDrill + DAYS * om.NO_TILL_DAILY_CREDIT

  T.ok("season OM ranks direct-drill > strip-till > cultivator > plough (#738 ruling)",
       sDrill > sStrip and sStrip > sCult and sCult > sPlow)
end

-- ── _applyTillageOxidation helper (scalar path) ──
do
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.vmAvailable = function() return false end

  local f = { organicMatter = 5.0 }
  T.ok("oxid: a real loss returns changed", s:_applyTillageOxidation(f, 0.14, 1.0, 0.01) == true)
  T.near("oxid: full-field pass subtracts oxid*factor", f.organicMatter, 5.0 - 0.14, 1e-6)

  local f2 = { organicMatter = 5.0 }
  T.ok("oxid: zero oxidation is a no-op (direct-drill)", s:_applyTillageOxidation(f2, 0.0, 1.0, 0.01) == false)
  T.near("oxid: zero oxidation leaves OM untouched", f2.organicMatter, 5.0, 1e-6)

  local floor = om.DECAY_FLOOR
  local f3 = { organicMatter = floor + 0.01 }
  s:_applyTillageOxidation(f3, 5.0, 1.0, 0.01)  -- oversized loss
  T.near("oxid: floored at DECAY_FLOOR", f3.organicMatter, floor, 1e-6)

  local f4 = { organicMatter = 5.0 }
  s:_applyTillageOxidation(f4, 0.06, 0.5, 0.01)
  T.near("oxid: scales by field-fraction (factor)", f4.organicMatter, 5.0 - 0.06 * 0.5, 1e-6)
end

-- ── Daily no-till credit: applied under an active crop, fenced from fallow recovery ──
-- Exercises the REAL _processOneDailyField with the value map and all feature toggles
-- off, so only OM decay + the fallow/credit branch + neutral pH drift run.
local function newDailySys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.vmAvailable         = function() return false end
  s.settings            = {}          -- every feature toggle off
  s._dailyBatchDay      = 100
  s._dailyBatchSeason   = 2
  s.herbicideAppliedDay = {}
  -- The daily pass ends by refreshing the yield layer via getFieldInfo; stub it (an
  -- unrelated collaborator here) so the OM-credit unit does not drag in field lookup.
  s.getFieldInfo        = function() return { yieldEfficiency = 0 } end
  return s
end

local function newField(over)
  local f = {
    organicMatter = 5.0, nitrogen = 50, phosphorus = 50, potassium = 50,
    pH = 6.8, lastHarvest = 100,      -- daysSinceFallow = 0 => an active crop, NOT fallow
    compaction = 0, weedPressure = 0,
  }
  for k, v in pairs(over or {}) do f[k] = v end
  return f
end

do
  local s = newDailySys()
  local timeFactor = 1.0 / g_currentMission.environment.daysPerPeriod

  -- Two identical fields differing only in noTillActive: the difference isolates the credit.
  local conv   = newField({ noTillActive = false })
  local notill = newField({ noTillActive = true })
  s:_processOneDailyField(1, conv)
  s:_processOneDailyField(2, notill)

  local credit = om.NO_TILL_DAILY_CREDIT * timeFactor
  T.ok("credit: a no-till crop ends the day with more OM than a conventional one",
       notill.organicMatter > conv.organicMatter)
  T.near("credit: the gap is exactly the daily credit (isolated from decay)",
         notill.organicMatter - conv.organicMatter, credit, 1e-6)

  -- Fence: deep in the fallow window, the IF branch (fallow recovery) runs, not the
  -- credit elseif - even with noTillActive still true. The OM delta must be
  -- recovery - decay, distinct from credit - decay, proving they never stack.
  local threshold = SoilConstants.TIMING.FALLOW_THRESHOLD * g_currentMission.environment.daysPerPeriod
  local fallow = newField({ noTillActive = true, lastHarvest = 100 - (threshold + 10) })
  local before = fallow.organicMatter
  s:_processOneDailyField(3, fallow)
  local decay = om.DAILY_DECAY * timeFactor
  local recov = SoilConstants.FALLOW_RECOVERY.organicMatter * timeFactor
  T.near("fence: fallow window applies fallow recovery, not the no-till credit",
         fallow.organicMatter - before, recov - decay, 1e-6)
end
