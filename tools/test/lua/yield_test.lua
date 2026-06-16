-- yield_test.lua — the shared field-average yield helper _yieldModifierFromNutrients.
-- Guards the one formula that the harvest path and the soil monitor both read (see the
-- "yield is field-average, monitor mirrors it" project note). Expected values are derived
-- from the constants so tuning changes don't false-fail the test — it checks the formula.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local ys     = SoilConstants.YIELD_SENSITIVITY
local thresh = ys.OPTIMAL_THRESHOLD
local scale  = ys.TIERS[ys.DEFAULT_TIER].scale

-- Only the nutrient term active; pressures off so the test is about N/P/K → yield.
local function newSys()
  return setmetatable({
    settings = {
      nutrientCycles  = true,
      weedPressure    = false,
      pestPressure    = false,
      diseasePressure = false,
    },
  }, { __index = SoilFertilitySystem })
end

local UNKNOWN = "zzz_not_a_real_crop"  -- → DEFAULT_TIER via CROP_TIERS fallback

-- Nutrients at/above the optimal threshold → no penalty.
do
  local sys = newSys()
  local m = sys:_yieldModifierFromNutrients({}, UNKNOWN, thresh, thresh, thresh, nil)
  T.near("yield: nutrients at threshold → 1.0 (no penalty)", m, 1.0)
end

-- Partial deficiency → penalty follows min(MAX_PENALTY, avgDef * tierScale).
do
  local sys = newSys()
  local v = thresh * 0.75                       -- 25% short of optimal on each nutrient
  local avgDef = (thresh - v) / thresh          -- 0.25
  local expected = 1.0 - math.min(ys.MAX_PENALTY, avgDef * scale)
  local m = sys:_yieldModifierFromNutrients({}, UNKNOWN, v, v, v, nil)
  T.near("yield: 25%-deficient nutrients match the formula", m, expected)
end

-- Fully depleted → penalty saturates at MAX_PENALTY.
do
  local sys = newSys()
  local m = sys:_yieldModifierFromNutrients({}, UNKNOWN, 0, 0, 0, nil)
  T.near("yield: depleted nutrients cap at MAX_PENALTY", m, 1.0 - ys.MAX_PENALTY)
end

-- Grass / non-crop fields are exempt from the nutrient penalty entirely.
do
  local grassName = next(ys.NON_CROP_NAMES)      -- whatever the first non-crop key is
  T.ok("yield: NON_CROP_NAMES is populated", grassName ~= nil)
  local sys = newSys()
  local m = sys:_yieldModifierFromNutrients({}, grassName, 0, 0, 0, nil)
  T.near("yield: grass/non-crop ignores nutrient deficiency", m, 1.0)
end

-- Amendment burn penalty multiplies the modifier (lime/OM on a growing crop).
do
  local sys = newSys()
  local field = { amendBurnPenalty = 0.20 }
  local m = sys:_yieldModifierFromNutrients(field, UNKNOWN, thresh, thresh, thresh, nil)
  T.near("yield: amendment burn penalty multiplies (0.20 → x0.80)", m, 0.80)
end
