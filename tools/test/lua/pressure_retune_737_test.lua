-- pressure_retune_737_test.lua - issue #737, option D as ruled by Arissani and
-- derived by Claude(A) as a ratio pass.
--
-- The defect: pest and disease could never reach their own first effect tier.
-- Pest grows A pts/year and a harvest resets it to fraction f, so the pre-harvest
-- steady state is the geometric limit
--
--     P = A / (1 - f)
--
-- At A = 8.52 (the low-tier seasonal sum) and f = 0.30 that is 12.2, against a
-- first costing tier of 20. Unreachable at any save length. Disease was suppressed
-- separately by a plough reset worth ~6 years and by a dry branch that REPLACED
-- growth instead of damping it.
--
-- This test locks the three constants that were changed and the arithmetic that
-- justifies them, so a future tuning drift fails a line rather than silently
-- re-breaking the feature.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua

local pp = SoilConstants.PEST_PRESSURE
local dp = SoilConstants.DISEASE_PRESSURE

-- The seasonal sum that sets A for pest at the low tier: 0.8/day base, three
-- months per season, spring 1.1 + summer 1.8 + autumn 0.6 + winter 0.05.
local function pestYearlyGain()
  local seasonSum = 3 * (pp.SEASONAL_SPRING + pp.SEASONAL_SUMMER
                       + pp.SEASONAL_FALL   + pp.SEASONAL_WINTER)
  return pp.GROWTH_RATE_LOW * seasonSum
end

-- Pre-harvest steady state under an annual harvest.
local function steadyState(gain, resetFraction)
  return gain / (1.0 - resetFraction)
end

-- ── 1. The arithmetic that defined the bug is reproduced ─────────────────────
local A = pestYearlyGain()
T.near("pest gains ~8.52 pts/year at the low tier", A, 8.52, 0.01)
T.near("the OLD reset of 0.30 converged to ~12.2, below the tier", steadyState(A, 0.30), 12.17, 0.05)
T.ok("...which is below the first costing tier", steadyState(A, 0.30) < pp.LOW)

-- ── 2. The retuned reset crosses the tier ────────────────────────────────────
T.near("pest harvest reset is now 0.60", pp.HARVEST_RESET_FRACTION, 0.60, 0.0001)
local P = steadyState(A, pp.HARVEST_RESET_FRACTION)
T.near("steady peak is now ~21.3", P, 21.3, 0.1)
T.ok("neglect now crosses the first costing tier", P > pp.LOW)
-- ...but stays gentle: it must not run away into the mid tier on its own.
T.ok("and stays in the low band rather than running to the mid tier", P < pp.MEDIUM)

-- A harvest must remain a meaningful dispersal, not a no-op.
T.ok("a harvest still disperses at least a third", (1.0 - pp.HARVEST_RESET_FRACTION) >= 0.33)

-- ── 3. Plough disease relief is a reset, not an erase ────────────────────────
-- Disease accrues ~6.8 pts/year, so 40 cleared roughly six years in one pass.
local diseaseYearly = dp.GROWTH_RATE_LOW * 3 * (dp.SEASONAL_SPRING + dp.SEASONAL_SUMMER
                                              + dp.SEASONAL_FALL   + dp.SEASONAL_WINTER)
T.near("disease gains ~6.8 pts/year before rain", diseaseYearly, 6.84, 0.05)
T.near("plough disease relief is now 15", SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION, 15, 0.0001)
local yearsCleared = SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION / diseaseYearly
T.ok("a plough now clears about two years, not six", yearsCleared > 1.5 and yearsCleared < 3.0)

-- Physical ordering: a plough disturbs at least as much as a cultivator.
-- NOTE: the #737 ruling assumed the cultivator's disease figure was 10; it is 15,
-- so these are currently EQUAL. Locked as >= so the ordering can never invert,
-- and flagged to Claude(A) for whether the plough should sit strictly above.
T.ok("plough relief is not weaker than the cultivator's",
  SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION >= SoilConstants.CULTIVATION.DISEASE_PRESSURE_REDUCTION)

-- ── 4. A dry spell damps growth, it no longer replaces it ────────────────────
T.near("dry-day growth is 40% of the wet base rate", dp.DRY_GROWTH_MULT, 0.40, 0.0001)
T.ok("a dry day still GROWS disease rather than losing it", dp.DRY_GROWTH_MULT > 0)
T.ok("but grows it more slowly than a wet day", dp.DRY_GROWTH_MULT < 1.0)

-- Decay now waits for a genuine drought at a strictly higher threshold, so there
-- is always a damped band between "dry" and "drought".
T.ok("the drought threshold is strictly above the dry threshold", dp.DROUGHT_THRESHOLD_MULT > 1.0)
for climate = 1, 4 do
  local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[climate]
  local dry     = cm.dryThreshold
  local drought = dry * dp.DROUGHT_THRESHOLD_MULT
  T.ok("climate " .. climate .. " keeps a damped band before decay", drought > dry)
end

-- Climate scaling survives the change: a wet map still tolerates far longer dry
-- spells before anything decays than an arid one.
local aridDrought = SoilConstants.DISEASE_CLIMATE_MOISTURE[1].dryThreshold * dp.DROUGHT_THRESHOLD_MULT
local wetDrought  = SoilConstants.DISEASE_CLIMATE_MOISTURE[4].dryThreshold * dp.DROUGHT_THRESHOLD_MULT
T.ok("wet climates still resist drought decay far longer than arid", wetDrought > aridDrought * 3)

T.summary()
