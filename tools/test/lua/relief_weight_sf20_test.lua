-- relief_weight_sf20_test.lua
-- SF-20 THE RELIEF WEIGHT: the executable bar for the seed-time maths.
-- Locks the three properties the design claims hold BY CONSTRUCTION rather than
-- by tuning, across four field shapes and four amplitudes:
--   * DIRECTION  - low ground reads richer than high ground (acceptance check 4)
--   * CONSERVATION - deviations sum to exactly zero, so the field figure cannot
--     move (acceptance check 5)
--   * MAGNITUDE  - peak-to-peak spread is exactly the amplitude and never more,
--     including the valley strip that broke an earlier design (check 6)
--   * FLAT GUARD - a field below the relief threshold yields no deviations at
--     all and the caller falls back to today's behaviour (check 3)
-- Engine-free: drives SoilValueMaps.computeReliefDeviations directly.
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua

local compute = SoilValueMaps.computeReliefDeviations

local EPS = 1e-9

-- Field shapes, as terrain heights per sample block.
local SHAPES = {}

-- 1. A clean slope: heights rise steadily across the field.
SHAPES.slope = {}
for i = 1, 40 do SHAPES.slope[i] = 100 + i * 0.5 end

-- 2. A bowl: low in the middle, high at both ends.
SHAPES.bowl = {}
for i = 1, 41 do
  local d = math.abs(i - 21)
  SHAPES.bowl[i] = 100 + d * 0.4
end

-- 3. THE VALLEY STRIP - a narrow band of low ground in otherwise flat field.
--    This is the shape that broke an earlier version of this design: nearly
--    every sample sits at one height and a handful sit far below.
SHAPES.valleyStrip = {}
for i = 1, 60 do SHAPES.valleyStrip[i] = 120.0 end
for i = 28, 32 do SHAPES.valleyStrip[i] = 112.0 end

-- 4. A ridge - the mirror of the valley strip, a narrow band of HIGH ground.
SHAPES.ridge = {}
for i = 1, 60 do SHAPES.ridge[i] = 95.0 end
for i = 10, 13 do SHAPES.ridge[i] = 103.0 end

local AMPLITUDES = { 0.15, 0.45, 1.2, 3.0 }

local function sum(t)
  local s = 0
  for i = 1, #t do s = s + t[i] end
  return s
end

local function minMax(t)
  local lo, hi = t[1], t[1]
  for i = 2, #t do
    if t[i] < lo then lo = t[i] end
    if t[i] > hi then hi = t[i] end
  end
  return lo, hi
end

-- 1. CONSERVATION + MAGNITUDE + BOUND across every shape and amplitude.
for shapeName, heights in pairs(SHAPES) do
  for _, amp in ipairs(AMPLITUDES) do
    local tag = shapeName .. "@" .. tostring(amp)
    local dev = compute(heights, amp, 1.5)
    T.ok(tag .. ".produced", dev ~= nil)

    -- CONSERVATION: the deviations sum to zero, so the field total cannot move.
    T.near(tag .. ".zeroMean", sum(dev), 0, 1e-9)

    -- MAGNITUDE: peak-to-peak is exactly the amplitude, never more.
    local lo, hi = minMax(dev)
    T.near(tag .. ".spreadIsAmplitude", hi - lo, amp, 1e-9)

    -- BOUND: no single deviation may exceed the amplitude in either direction.
    T.ok(tag .. ".withinBound", (hi <= amp + EPS) and (lo >= -amp - EPS))
  end
end

-- 2. DIRECTION: the lowest ground must gain and the highest must lose.
--    Getting this backwards is agronomically inverted and is an easy slip.
do
  local heights = SHAPES.slope
  local dev = compute(heights, 1.0, 1.5)
  local lowIdx, highIdx = 1, 1
  for i = 2, #heights do
    if heights[i] < heights[lowIdx]  then lowIdx  = i end
    if heights[i] > heights[highIdx] then highIdx = i end
  end
  T.ok("direction.lowGroundGains",  dev[lowIdx]  > 0)
  T.ok("direction.highGroundLoses", dev[highIdx] < 0)
  T.ok("direction.lowBeatsHigh",    dev[lowIdx]  > dev[highIdx])
  -- The extremes carry the full amplitude between them.
  T.near("direction.extremeSpread", dev[lowIdx] - dev[highIdx], 1.0, 1e-9)
end

-- 3. THE VALLEY STRIP, called out on its own because it is the failure case.
--    A handful of low cells among many flat ones must NOT blow the bound.
do
  local dev = compute(SHAPES.valleyStrip, 0.45, 1.5)
  local lo, hi = minMax(dev)
  T.near("valley.spread", hi - lo, 0.45, 1e-9)
  T.ok("valley.valleyIsRicher", dev[30] > dev[1])
  -- The valley is the minority, so the mean weight sits near zero and the
  -- majority's deviation is small and negative while the strip carries most
  -- of the amplitude. Asymmetry is correct; exceeding the bound is not.
  T.ok("valley.majorityNearZero", math.abs(dev[1]) < 0.45 * 0.25)
  T.ok("valley.stripCarriesMost", dev[30] > 0.45 * 0.75)
end

-- 4. FLAT GUARD: below the relief threshold there is nothing to paint.
do
  local flat = {}
  for i = 1, 30 do flat[i] = 88.0 end
  T.eq("flat.identical", compute(flat, 1.0, 1.5), nil)

  -- Gently undulating, but still under the 1.5 m guard.
  local gentle = {}
  for i = 1, 30 do gentle[i] = 88.0 + (i % 3) * 0.4 end   -- range 0.8 m
  T.eq("flat.underThreshold", compute(gentle, 1.0, 1.5), nil)

  -- Just over the guard: it must engage.
  local justOver = {}
  for i = 1, 30 do justOver[i] = 88.0 + (i % 2) * 1.6 end -- range 1.6 m
  T.ok("flat.overThresholdEngages", compute(justOver, 1.0, 1.5) ~= nil)
end

-- 5. DEGENERATE INPUTS never produce a deviation.
do
  T.eq("degenerate.empty",        compute({}, 1.0, 1.5), nil)
  T.eq("degenerate.nilHeights",   compute(nil, 1.0, 1.5), nil)
  T.eq("degenerate.zeroAmp",      compute(SHAPES.slope, 0, 1.5), nil)
  T.eq("degenerate.negativeAmp",  compute(SHAPES.slope, -1.0, 1.5), nil)
  -- A single sample has no range and must be treated as flat, not divided by 0.
  T.eq("degenerate.singleSample", compute({ 100.0 }, 1.0, 0), nil)
end

-- 6. SCALE INVARIANCE: the spread follows the amplitude, not the terrain.
--    A 200 m mountain and a 2 m rise produce the same OM spread for the same
--    amplitude - relief decides WHERE, the dial decides HOW MUCH.
do
  local gentle, steep = {}, {}
  for i = 1, 25 do
    gentle[i] = 50 + i * 0.1     -- 2.4 m of range
    steep[i]  = 50 + i * 8.0     -- 192 m of range
  end
  local dg = compute(gentle, 0.6, 1.5)
  local ds = compute(steep,  0.6, 1.5)
  local glo, ghi = minMax(dg)
  local slo, shi = minMax(ds)
  T.near("scale.gentleSpread", ghi - glo, 0.6, 1e-9)
  T.near("scale.steepSpread",  shi - slo, 0.6, 1e-9)
  -- Same shape, same normalised weights, so identical deviations throughout.
  for i = 1, #dg do
    T.near("scale.identical." .. i, dg[i], ds[i], 1e-9)
  end
end

T.summary()
