-- SF-77-topography_cache_spec_test.lua
-- THE LOAD-TIME TOPOGRAPHY CACHE. Terrain-derived facts computed once at map
-- load, invalidated never recomputed: an adaptive grid (12-48 m by map size,
-- floor rounding, 180k hard cap) in row-major order, carrying per-cell
-- height, slope class, sink data and distance-to-water. The executable bar
-- for the pure core, written from the brief's contract.
--
-- THE INVARIANTS THAT MATTER:
--   the cap arithmetic holds (axis * axis <= 180k, floor rounding),
--   two loads of one save are byte-identical (pure + deterministic),
--   slope and sink classify correctly from a height set,
--   distance-to-water is a deterministic multi-source flood, 0 on water,
--   a stale cell returns the shaped default, never nil.
--!load: src/utils/Logger.lua, src/TopographyCache.lua

local TC = TopographyCache

-- 1. THE ADAPTIVE GRID: cap arithmetic, floor rounding, cell-size selection.
do
  -- A standard 2 km map: 2048 / 12 = 170 (floor), 170^2 = 28900 << 180k, so 12 m.
  local size = TC.pickCellSize(2048)
  T.eq('grid.pick2048', size, 12)
  local ax, az = TC.axisCount(2048, size)
  T.eq('grid.axis2048', ax, 170)
  T.ok('grid.underCap2048', ax * az <= TC.HARD_CELL_CAP)

  -- A 16 km map exceeds the cap at 12 m (1365^2 > 180k), so it grows.
  local size16 = TC.pickCellSize(16384)
  T.ok('grid.pick16384Coarsens', size16 > 12)
  local ax16, az16 = TC.axisCount(16384, size16)
  T.ok('grid.underCap16384', ax16 * az16 <= TC.HARD_CELL_CAP)

  -- The cap is a hard ceiling: even at 48 m a huge map is clamped, never
  -- oversized.
  local huge = TC.axisCount(100000, 48)
  T.ok('grid.capClamped', huge * huge <= TC.HARD_CELL_CAP)

  -- Floor rounding: 2048 / 170 would be 12.04; the axis is exactly 170.
  T.eq('grid.floorRounding', math.floor(2048 / 12), ax)
end

-- 2. ROW-MAJOR INDEXING + WORLD MAPPING.
do
  local axis = 4
  T.eq('index.rowMajor00', TC.index(0, 0, axis), 1)
  T.eq('index.rowMajor10', TC.index(1, 0, axis), 2)
  T.eq('index.rowMajor01', TC.index(0, 1, axis), 5)
  T.eq('index.rowMajor33', TC.index(3, 3, axis), 16)

  -- World position to cell, 0-centred terrain.
  local gx, gz = TC.cellIndicesAtWorld(-1020, -1020, 2048, 12)
  T.eq('world.negCorner', gx, 0); T.eq('world.negCornerZ', gz, 0)
  local gx2, gz2 = TC.cellIndicesAtWorld(1000, 1000, 2048, 12)
  T.ok('world.midCell', gx2 > 100 and gx2 < 170 and gz2 > 100 and gz2 < 170)

  -- Off-map: nil, never a spurious cell.
  local offx, offz = TC.cellIndicesAtWorld(5000, 5000, 2048, 12)
  T.eq('world.offMap', offx, nil)
  T.eq('world.offMapZ', offz, nil)
end

-- 3. SLOPE CLASSIFICATION.
do
  T.eq('slope.flat', TC.slopeClass(0), TC.SLOPE_FLAT)
  T.eq('slope.flat2pct', TC.slopeClass(2.0), TC.SLOPE_FLAT)
  T.eq('slope.gentle', TC.slopeClass(3.0), TC.SLOPE_GENTLE)
  T.eq('slope.moderate', TC.slopeClass(8.0), TC.SLOPE_MODERATE)
  T.eq('slope.steep', TC.slopeClass(15.0), TC.SLOPE_STEEP)
  T.eq('slope.negativeClamped', TC.slopeClass(-5), TC.SLOPE_FLAT)
  T.eq('slope.nilFlat', TC.slopeClass(nil), TC.SLOPE_FLAT)
end

-- 4. CLASSIFY: slope + sink from a height set.
do
  -- Flat ground at 10 m, 12 m cells: no rise, not a sink.
  local flat = { self = 10, n = 10, s = 10, e = 10, w = 10 }
  local slope, sink = TC.classify(flat, 12)
  T.eq('classify.flatSlope', slope, TC.SLOPE_FLAT)
  T.eq('classify.flatNotSink', sink, false)

  -- A steep pit: neighbours 12 m away at 10 m, self at 1 m.
  local pit = { self = 1, n = 10, s = 10, e = 10, w = 10 }
  local pSlope, pSink = TC.classify(pit, 12)
  T.eq('classify.pitSteep', pSlope, TC.SLOPE_STEEP)
  T.eq('classify.pitIsSink', pSink, true)

  -- A mild rise: gentle, not a sink.
  local rise = { self = 10, n = 10.3, s = 10, e = 10, w = 10 }
  local rSlope, rSink = TC.classify(rise, 12)
  T.eq('classify.riseGentle', rSlope, TC.SLOPE_GENTLE)
  T.eq('classify.riseNotSink', rSink, false)

  -- A cell that is NOT lower than a neighbour (a ridge) is not a sink even if
  -- two neighbours are higher.
  local ridge = { self = 10, n = 12, s = 8, e = 10, w = 10 }
  local rdSlope, rdSink = TC.classify(ridge, 12)
  T.eq('classify.ridgeNotSink', rdSink, false)

  -- Map edge: no neighbours at all, not a sink.
  local lone = { self = 5 }
  local lSlope, lSink = TC.classify(lone, 12)
  T.eq('classify.loneNotSink', lSink, false)
  T.eq('classify.loneFlat', lSlope, TC.SLOPE_FLAT)

  -- Nil heights: shaped default.
  local nilSlope, nilSink = TC.classify(nil, 12)
  T.eq('classify.nilFlat', nilSlope, TC.SLOPE_FLAT)
  T.eq('classify.nilNotSink', nilSink, false)
end

-- 5. DISTANCE-TO-WATER: deterministic multi-source flood.
do
  local axis = 5
  -- Water down the left column (indices 1, 6, 11, 16, 21 for axis=5).
  local water = { [1] = true, [6] = true, [11] = true, [16] = true, [21] = true }
  local dist = TC.waterDistances(water, axis, axis, 12)

  T.eq('water.onWaterIsZero', dist[1], 0)
  -- One cell right of a water cell: 12 m away.
  T.eq('water.nextColumn', dist[2], 12)
  -- Far right: 4 cells right of water = 48 m.
  T.eq('water.farColumn', dist[5], 48)

  -- Determinism: two calls, identical tables (the byte-identical-load bar).
  local dist2 = TC.waterDistances(water, axis, axis, 12)
  local same = true
  for k, v in pairs(dist) do
    if dist2[k] ~= v then same = false break end
  end
  T.ok('water.deterministic', same)

  -- No water at all: every cell nil (honest, never a fabricated number).
  local dry = TC.waterDistances({}, axis, axis, 12)
  T.ok('water.dryHasNoDist', next(dry) == nil)
end

-- 6. THE READ PATH: shaped defaults for stale cells, never nil.
do
  -- Not built: nil, honestly.
  local fresh = TC.new({})
  T.eq('read.unbuiltIsNil', fresh:getCellInfo(0, 0), nil)

  local tc = TC.new({})
  tc.isInitialized = true
  tc.terrainSize = 2048
  tc.cellSize = 12
  tc.axisX, tc.axisZ = TC.axisCount(2048, 12)

  -- A built cell answers shaped data.
  tc._cells[TC.index(0, 0, tc.axisX)] = { height = 5, slope = TC.SLOPE_FLAT, sink = false }
  tc._waterDist[TC.index(0, 0, tc.axisX)] = 24
  local info = tc:getCellInfo(-1020, -1020)
  T.ok('read.builtAnswers', info ~= nil)
  T.eq('read.height', info.height, 5)
  T.eq('read.waterDist', info.waterDist, 24)

  -- A stale cell returns the SHAPED DEFAULT, never nil.
  tc._stale[TC.index(0, 0, tc.axisX)] = true
  local stale = tc:getCellInfo(-1020, -1020)
  T.ok('read.staleAnswers', stale ~= nil)
  T.eq('read.staleHeight', stale.height, TC.STALE_DEFAULT.height)
  T.eq('read.staleSlope', stale.slope, TC.STALE_DEFAULT.slope)
  T.eq('read.staleSink', stale.sink, TC.STALE_DEFAULT.sink)

  -- Off-map: nil.
  T.eq('read.offMapIsNil', tc:getCellInfo(5000, 5000), nil)
end

-- 7. PERSISTENCE ROUND-TRIP: the static table survives a save/load cycle
--    (the two-loads-byte-identical bar).
do
  local tc = TC.new({})
  tc.isInitialized = true
  tc.cellSize = 12
  tc.axisX, tc.axisZ = 4, 4
  tc._waterDist = { [1] = 0, [2] = 12, [5] = 24 }

  local state = tc:getStateTable()
  T.eq('persist.schema', state.schema, 1)
  T.eq('persist.cellSize', state.cellSize, 12)
  T.eq('persist.axisX', state.axisX, 4)

  local tc2 = TC.new({})
  tc2.isInitialized = true
  tc2.cellSize = 12
  tc2.axisX, tc2.axisZ = 4, 4
  T.ok('persist.applies', tc2:applyStateTable(state))
  T.eq('persist.waterSurvives', tc2._waterDist[2], 12)

  -- A different map's table is not ours: refused.
  local tc3 = TC.new({})
  tc3.isInitialized = true
  tc3.cellSize = 48
  tc3.axisX, tc3.axisZ = 4, 4
  T.ok('persist.wrongGridRefused', tc3:applyStateTable(state) == false)
end

T.summary()
