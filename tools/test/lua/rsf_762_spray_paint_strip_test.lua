-- rsf_762_spray_paint_strip_test.lua - RSF-762 additive strip painter bar.
--   Exercises SoilValueMaps:addPaintStrip directly - the single additive
--   parallelogram write primitive future per-cell consumers route through.
--   Asserts the additive contract: semantic delta -> raw steps, the BETWEEN
--   filter guarding the sentinel wrap and the layer's rawFloor, executeAdd under
--   pcall, sub-step deltas apply nothing, and the additive path is refused rather
--   than fabricating a coarse write when executeAdd is unavailable.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/maps/SoilValueMaps.lua

-- Engine enum stubs (the real values are engine-side; the code compares against
-- the same constants, so the tests assert identity, never a magic number).
DensityCoordType = { POINT_POINT_POINT = 1 }
DensityValueCompareType = { BETWEEN = 1, EQUAL = 2, NOTEQUAL = 3 }

local calls = {}

local function newMaps()
  calls = {}
  local mock = {
    available    = true,
    hasExecuteAdd = true,
    layers = {
      nitrogen = {
        def = { minVal = 0, maxVal = 100 },   -- 0..100 ppm over 254 raw steps
        modifier = {
          setParallelogramWorldCoords = function() end,
          executeAdd = function(_m, rawDelta, filter)
            calls[#calls + 1] = { raw = rawDelta, filter = filter }
          end,
        },
        filter = { setValueCompareParams = function(_f, kind, lo, hi)
          calls[#calls + 1] = { filter = kind, lo = lo, hi = hi }
        end },
      },
    },
  }
  return setmetatable(mock, { __index = SoilValueMaps })
end

-- one raw step = 100 / 254 ppm, so delta 10 ppm = floor(10 / (100/254)) = 25 steps
do
  local m = newMaps()
  local applied = m:addPaintStrip("nitrogen", 0, 0, 20, 0, 0, 2, 10)
  T.ok("762: a >=1-step delta applies", applied > 0)
  local f = calls[1]   -- the BETWEEN guard runs before the add
  T.ok("762: filter guard is BETWEEN for a positive delta", f and f.filter == DensityValueCompareType.BETWEEN)
  T.eq("762: positive guard floors at rawFloor/RawMin", f and f.lo, 1)
  T.eq("762: positive guard leaves headroom for the add", f and f.hi, 255 - 25)
  local add = calls[2]
  T.eq("762: executeAdd called with the raw step delta", add and add.raw, 25)
end

-- negative delta: the BETWEEN window inverts to protect the no-data floor
do
  local m = newMaps()
  m:addPaintStrip("nitrogen", 0, 0, 20, 0, 0, 2, -10)
  local f = calls[1]   -- BETWEEN guard first
  T.ok("762: filter guard is BETWEEN for a negative delta", f and f.filter == DensityValueCompareType.BETWEEN)
  T.eq("762: negative guard starts below the floor so pixels near it are excluded",
       f and f.lo, 1 + 25)
  local add = calls[2]
  T.eq("762: negative delta is a negative raw step", add and add.raw, -25)
end

-- sub-step delta applies nothing (quantisation floor, no fabricated write)
do
  local m = newMaps()
  local applied = m:addPaintStrip("nitrogen", 0, 0, 20, 0, 0, 2, 0.0001)
  T.eq("762: a sub-step delta applies nothing", applied, 0)
  T.eq("762: a sub-step delta makes no executeAdd call", #calls, 0)
end

-- executeAdd unavailable: refused, never a coarse fallback write
do
  local m = newMaps()
  m.hasExecuteAdd = false
  local applied = m:addPaintStrip("nitrogen", 0, 0, 20, 0, 0, 2, 10)
  T.eq("762: no executeAdd -> refused (no fabricated write)", applied, 0)
  T.eq("762: no executeAdd -> no modifier call", #calls, 0)
end

-- unknown layer is a silent no-op
do
  local m = newMaps()
  T.eq("762: unknown layer applies nothing", m:addPaintStrip("bogus", 0, 0, 20, 0, 0, 2, 10), 0)
end

-- executeAdd failure is caught, logged, and the additive path stands down
do
  local m = newMaps()
  m.layers.nitrogen.modifier.executeAdd = function() error("engine refused") end
  local applied = m:addPaintStrip("nitrogen", 0, 0, 20, 0, 0, 2, 10)
  T.eq("762: executeAdd failure applies nothing", applied, 0)
  T.eq("762: executeAdd failure disables the additive path", m.hasExecuteAdd, false)
end

T.summary()
