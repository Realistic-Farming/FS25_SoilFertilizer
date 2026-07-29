-- coverage_test.lua - spray-coverage accounting, incl. the #650 dry-spreader fix.
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

-- ── #726 sanity floor: a re-confirm must not shrink fieldArea below session coverage ──
-- Drives the real onHerbicideAppliedDirect area-confirm block. liters=0 skips the
-- reduction branch; _resolveCropAreaHa is overridden on the instance to force the
-- resolve value. sessionCoverageCells={} makes it a "new session" so the re-confirm fires.
do
  -- Bogus tiny resolve (e.g. a wrong farmland->field mapping) must NOT collapse the denominator.
  local sys = newSys({
    [1] = { fieldArea = 5.0, sessionCoverageHa = 3.0, sessionCoverageCells = {}, weedPressure = 10 },
  })
  sys.settings = { weedPressure = true }
  sys._resolveCropAreaHa = function() return 0.5 end
  sys:onHerbicideAppliedDirect(1, 1.0, 0)
  T.near("#726 floor: fieldArea held at session coverage, not collapsed to 0.5",
         sys.fieldData[1].fieldArea, 3.0)
end

do
  -- Healthy path: a legit crop area above the covered ha still takes effect (floor is a no-op).
  local sys = newSys({
    [1] = { fieldArea = 10.0, sessionCoverageHa = 2.0, sessionCoverageCells = {}, weedPressure = 10 },
  })
  sys.settings = { weedPressure = true }
  sys._resolveCropAreaHa = function() return 5.0 end
  sys:onHerbicideAppliedDirect(1, 1.0, 0)
  T.near("#726 floor: healthy re-confirm still applies the true crop area",
         sys.fieldData[1].fieldArea, 5.0)
end

-- ── #726 root cause: liter fallback must defer to the geometric path ──
-- When markBoomCells has stamped cells (crop protection WITH boom points, e.g. See &
-- Spray), the liter estimate must NOT also write coverage, or the two writers
-- double-count and pin Pass% at 100%.
do
  local sys = newSys({
    [1] = {
      fieldArea = 2.0,
      sessionCoverageHa = 0.5,                  -- geometric path already recorded 0.5 ha
      sessionCoverageFraction = 0.25,
      sessionCoverageCells = { ["c1"] = 123 },
      _geometricCoverageOwner = true,           -- #753: markBoomCells owns the counter
    },
  })
  -- A huge liter estimate that WOULD saturate to 100% if it were counted here.
  sys:trackSprayerCoverage(1, 100000, "HERBICIDE", true)
  T.eq("#726: liter path defers when the geometric path OWNS coverage (fraction unchanged)",
       sys.fieldData[1].sessionCoverageFraction, 0.25)
  T.near("#726: liter path leaves session ha untouched",
         sys.fieldData[1].sessionCoverageHa, 0.5)
end

-- ── #753: stamped cells alone are NOT the deferral signal ──
-- overlayOnly mode fills sessionCoverageCells for spray-trail dedup while leaving
-- the counter to the liter path, so the guard reads _geometricCoverageOwner rather
-- than "are there cells". Cells without the owner flag must still track, otherwise
-- an overlayOnly pass silently suppresses coverage accounting entirely.
do
  local sys = newSys({
    [1] = {
      fieldArea = 2.0,
      sessionCoverageCells = { ["c1"] = 123 },  -- stamped by an overlayOnly pass
    },
  })
  local rate = SoilConstants.SPRAYER_RATE.BASE_RATES.HERBICIDE.value
  sys:trackSprayerCoverage(1, rate * 0.5, "HERBICIDE", true)  -- 0.5 ha of a 2 ha field
  T.near("#753: cells without the owner flag do NOT suppress the liter fallback",
         sys.fieldData[1].sessionCoverageFraction, 0.25)
end

-- ── #753: a product change clears the owner flag so the new product re-detects ──
do
  local sys = newSys({
    [1] = {
      fieldArea = 2.0,
      sessionLastProduct = "FERTILIZER",
      sessionCoverageHa = 1.5,
      sessionCoverageFraction = 0.75,
      _geometricCoverageOwner = true,
    },
  })
  local rate = SoilConstants.SPRAYER_RATE.BASE_RATES.HERBICIDE.value
  sys:trackSprayerCoverage(1, rate * 0.5, "HERBICIDE", true)
  T.ok("#753: switching product clears the geometric owner flag",
       sys.fieldData[1]._geometricCoverageOwner == nil)
  T.near("#753: the new product's session starts from the liter path, not the old total",
         sys.fieldData[1].sessionCoverageFraction, 0.25)
end

do
  -- True no-boom fallback: no geometric cells -> the liter path still runs as before.
  local sys = newSys({ [1] = { fieldArea = 2.0, sessionCoverageCells = {} } })
  local rate = SoilConstants.SPRAYER_RATE.BASE_RATES.HERBICIDE.value
  sys:trackSprayerCoverage(1, rate * 0.5, "HERBICIDE", true)  -- 0.5 ha of a 2 ha field
  T.near("#726: liter fallback still tracks with no boom cells (25%)",
         sys.fieldData[1].sessionCoverageFraction, 0.25)
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
