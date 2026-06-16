-- coverage_test.lua — spray-coverage accounting, incl. the #650 dry-spreader fix.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

-- Build a `self` that resolves SoilFertilitySystem methods (so self:method() works)
-- without running .new() (which would pull in HookManager and the live game).
local function newSys(fields)
  return setmetatable({ fieldData = fields }, { __index = SoilFertilitySystem })
end

-- ── trackSprayerCoverage: liter-based session fraction (the dry-spreader counter) ──
do
  local sys = newSys({ [1] = { fieldArea = 2.0 } })
  local rate = SoilConstants.SPRAYER_RATE.BASE_RATES.FERTILIZER.value  -- L/ha
  -- Apply exactly 0.5 ha worth of product onto a 2.0 ha field → 25% covered.
  sys:trackSprayerCoverage(1, rate * 0.5, "FERTILIZER", true)
  T.near("trackSprayerCoverage: 0.5ha on 2ha field = 25%",
         sys.fieldData[1].sessionCoverageFraction, 0.25)
end

-- updateFractions=false must NOT advance the counter (markBoomCells owns it for VWW).
do
  local sys = newSys({ [1] = { fieldArea = 2.0, sessionCoverageFraction = 0 } })
  sys:trackSprayerCoverage(1, 100000, "FERTILIZER", false)
  T.eq("trackSprayerCoverage: updateFractions=false leaves fraction at 0",
       sys.fieldData[1].sessionCoverageFraction, 0)
end

-- ── markBoomCells overlayOnly (#650): paint the overlay, do NOT touch the counter ──
-- Two boom points 10 m apart land in two distinct 10×10 m cells.
local boom = { { x = 5, z = 5 }, { x = 15, z = 5 } }

do  -- full mode: advances the session counter
  local sys = newSys({ [1] = { fieldArea = 1.0 } })
  sys:markBoomCells(1, boom, false)
  T.ok("markBoomCells full: session ha advances",
       (sys.fieldData[1].sessionCoverageHa or 0) > 0)
end

do  -- overlayOnly: counter stays put, overlay still painted (preserves #626)
  local sys = newSys({ [1] = { fieldArea = 1.0 } })
  sys:markBoomCells(1, boom, true)
  T.eq("markBoomCells overlayOnly: session ha stays 0 (counter owned by liter path)",
       sys.fieldData[1].sessionCoverageHa or 0, 0)
  T.ok("markBoomCells overlayOnly: overlay zoneData still stamped",
       sys.fieldData[1].zoneData ~= nil and next(sys.fieldData[1].zoneData) ~= nil)
end

-- ── Fertilizer profile sanity: every profile is a real number table ──
do
  local bad = 0
  for name, prof in pairs(SoilConstants.FERTILIZER_PROFILES) do
    if type(prof) ~= "table" then bad = bad + 1 end
    for _, key in ipairs({ "N", "P", "K", "OM", "pH" }) do
      if prof[key] ~= nil and type(prof[key]) ~= "number" then bad = bad + 1 end
    end
  end
  T.eq("FERTILIZER_PROFILES: all N/P/K/OM/pH values are numbers", bad, 0)
end
