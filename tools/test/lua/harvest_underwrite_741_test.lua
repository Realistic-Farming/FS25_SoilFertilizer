-- harvest_underwrite_741_test.lua - #741 / SF-29 harvest contract underwrite.
--   HarvestContractUnderwrite.correct(mission, vanilla) tops a base-game harvest contract's
--   liters-based completion up to the vanilla expectation by dividing out SF's own yield
--   modifier for the field. Guards: the exact-invert math, the 1.0 ceiling (never overpay),
--   the "credit only from real harvest" partial case, the no-op paths (no reduction, already
--   complete, disabled, client), and fail-safe returns on every missing input.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/HarvestContractUnderwrite.lua

local UW = HarvestContractUnderwrite

-- ── fixtures ───────────────────────────────────────────────
local function missionWith(fruitTypeIndex, farmlandId)
  return {
    field    = { farmland = { id = farmlandId or 7 }, getId = function() return 42 end },
    fruitTypeIndex = fruitTypeIndex or 14,
    farmId   = 1,
    uniqueId = "m1",
  }
end

-- Inject a soil system whose computeYieldModifier returns `ym` for any field/fruit.
local function withYieldModifier(ym)
  g_SoilFertilityManager = { soilSystem = { computeYieldModifier = function() return ym end } }
end

-- Server by default (the correction is server-authoritative). No local player, so the
-- one-shot notification path stays a no-op in tests.
g_server = {}
g_localPlayer = nil
SoilConstants.HARVEST_UNDERWRITE.ENABLED = true

-- ── exact invert: a fully harvested+delivered degraded field reads 100% ──
do
  withYieldModifier(0.32)                 -- SF cut this field's yield to 32%
  -- Fully harvested & delivered: vanilla completion == yield modifier (deposited/expected).
  local c = UW.correct(missionWith(), 0.32)
  T.near("741: full harvest on a 32% field completes (0.32 / 0.32 -> 1.0)", c, 1.0, 1e-9)
end

-- ── partial harvest gets partial credit - no free money ──
do
  withYieldModifier(0.5)                  -- 50% modifier
  -- Half the field harvested+delivered: vanilla 0.25 -> corrected 0.5 (still incomplete).
  local c = UW.correct(missionWith(), 0.25)
  T.near("741: half-harvested field reads 0.5 (0.25 / 0.5), not complete", c, 0.5, 1e-9)
  T.ok("741: partial stays below the 0.995 success line", c < UW.SUCCESS_THRESHOLD)
end

-- ── the 1.0 ceiling: correction can never exceed vanilla expectation ──
do
  withYieldModifier(0.5)
  local c = UW.correct(missionWith(), 0.6)  -- 0.6 / 0.5 = 1.2, must cap
  T.near("741: corrected completion is capped at 1.0 (never overpay)", c, 1.0, 1e-9)
end

-- ── no reduction (modifier 1.0): pure passthrough ──
do
  withYieldModifier(1.0)
  T.eq("741: yield modifier 1.0 leaves completion untouched", UW.correct(missionWith(), 0.4), 0.4)
end

-- ── already complete: no-op ──
do
  withYieldModifier(0.3)
  T.eq("741: vanilla already >= 1.0 is returned unchanged", UW.correct(missionWith(), 1.0), 1.0)
end

-- ── disabled master switch: passthrough ──
do
  withYieldModifier(0.3)
  SoilConstants.HARVEST_UNDERWRITE.ENABLED = false
  T.eq("741: disabled underwrite is a passthrough", UW.correct(missionWith(), 0.32), 0.32)
  SoilConstants.HARVEST_UNDERWRITE.ENABLED = true
end

-- ── client (no g_server): passthrough, correction stays server-authoritative ──
do
  withYieldModifier(0.3)
  g_server = nil
  T.eq("741: a pure client returns the synced vanilla completion", UW.correct(missionWith(), 0.32), 0.32)
  g_server = {}
end

-- ── fail-safe: every missing input returns the vanilla value unchanged ──
do
  withYieldModifier(0.3)
  T.eq("741: non-number completion is returned as-is", UW.correct(missionWith(), "x"), "x")

  local noFarmland = missionWith(); noFarmland.field.farmland = nil
  T.eq("741: missing farmland -> vanilla", UW.correct(noFarmland, 0.3), 0.3)

  local noFruit = missionWith(0); -- fruitTypeIndex <= 0
  T.eq("741: missing/zero fruit type -> vanilla", UW.correct(noFruit, 0.3), 0.3)

  g_SoilFertilityManager = nil
  T.eq("741: no soil system -> vanilla", UW.correct(missionWith(), 0.3), 0.3)
  withYieldModifier(0.3)

  g_SoilFertilityManager = { soilSystem = { computeYieldModifier = function() return 0 end } }
  T.eq("741: a zero/garbage modifier -> vanilla (no divide-by-zero)", UW.correct(missionWith(), 0.3), 0.3)
end

-- ── invariant sweep: corrected is always in [vanilla, 1.0] for any valid modifier ──
do
  local bad = 0
  for i = 1, 99 do
    local ym = i / 100                    -- 0.01 .. 0.99
    withYieldModifier(ym)
    for j = 0, 98 do
      local vanilla = j / 100             -- 0 .. 0.98
      local c = UW.correct(missionWith(), vanilla)
      if not (c >= vanilla - 1e-9 and c <= 1.0 + 1e-9) then bad = bad + 1 end
    end
  end
  T.eq("741: corrected completion always within [vanilla, 1.0]", bad, 0)
end
