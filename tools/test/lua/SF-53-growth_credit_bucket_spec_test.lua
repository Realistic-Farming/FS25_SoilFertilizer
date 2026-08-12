-- SF-53-growth_credit_bucket_spec_test.lua
-- SF-53 GROWTH CREDIT: the reward half of the SF-2M pair. The executable bar
-- for the daily bookkeeper, the engine-true target derivation, the bucketing,
-- the guard chain and the neutral flows. Written from the brief's contract
-- (the design-side spec bar lives in the draft workspace; this is the repo
-- bar that travels with the build).
--
-- THE INVARIANTS THAT MATTER:
--   an unreadable cell earns nothing (nil band does not vote),
--   blocked cells never advance,
--   the write never reaches cut/withered/max states,
--   a failed stroke keeps its credit (retry next bell),
--   the family is inert until the release gate opens AND the mask is enabled.
--!load: src/utils/Logger.lua, src/ReleaseGate.lua, src/ViabilityMask.lua, src/GrowthCredit.lua

local GC = GrowthCredit

-- 1. THE EXCELLENCE TEST, both presets.
do
  local B, N, E = ViabilityMask.BAND_BLOCKED, ViabilityMask.BAND_NORMAL, ViabilityMask.BAND_EXCELLENT

  -- Casual: the composer's own rule (at least one excellent, none blocked).
  T.eq('casual.oneExcellent',   GC.isExcellent({ n = E, compaction = N, moisture = nil }, true), true)
  T.eq('casual.allExcellent',   GC.isExcellent({ n = E, compaction = E, moisture = nil }, true), true)
  T.eq('casual.blockedLoses',   GC.isExcellent({ n = E, compaction = B, moisture = nil }, true), false)
  T.eq('casual.noneExcellent',  GC.isExcellent({ n = N, compaction = N, moisture = nil }, true), false)
  T.eq('casual.nilAbstains',    GC.isExcellent({ n = N, compaction = nil, moisture = nil }, true), false)
  T.eq('casual.nilBands',       GC.isExcellent(nil, true), false)

  -- Realistic: at least TWO voters, every voter excellent.
  T.eq('real.twoVotersAllExcellent', GC.isExcellent({ n = E, compaction = E, moisture = nil }, false), true)
  T.eq('real.threeVotersAllExcellent', GC.isExcellent({ n = E, compaction = E, moisture = E }, false), true)
  T.eq('real.oneVoterIsNotQuorum', GC.isExcellent({ n = E, compaction = nil, moisture = nil }, false), false)
  T.eq('real.normalVoterFails', GC.isExcellent({ n = E, compaction = N, moisture = nil }, false), false)
  T.eq('real.blockedVoterFails', GC.isExcellent({ n = E, compaction = B, moisture = nil }, false), false)
  T.eq('real.partialReadEarnsNothing', GC.isExcellent({ n = E, compaction = nil, moisture = nil }, false), false)
  T.eq('real.nilBands', GC.isExcellent(nil, false), false)
end

-- 2. THE ENGINE-TRUE TARGET. Seasonal uses the period's growthMapping; daily
--    uses the non-seasonal mapping; no data falls back to state + 1; a target
--    that does not advance (identity) is a HOLD, not a step.
do
  local mission = g_currentMission
  local env = { currentPeriod = 3 }
  local realEnv = mission.environment
  mission.environment = env

  local fruitTypes = {
    wheat = {
      terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
      cutState = 0, maxHarvestingGrowthState = 7,
      getIsCut = function() return false end, getIsWithered = function() return false end,
      getSeasonalGrowthData = function()
        return { periods = { [3] = { growthMapping = { [2] = 3, [3] = 3, [4] = 5 } } } }
      end,
      getNonSeasonalGrowthData = function()
        return { growthMapping = { [2] = 2, [3] = 4, [4] = 5 } }
      end,
    },
  }
  local prevFtm = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function(_self, i) return fruitTypes.wheat end }

  local gc = GC.new({})
  gc.isInitialized = true
  gc._agronomyMultCached = 1.0

  mission.missionInfo = { growthMode = 1 } -- SEASONAL
  T.eq('target.seasonalMapsForward', gc:_engineTarget(1, 2), 3)
  T.eq('target.seasonalIdentityHolds', gc:_engineTarget(1, 3), nil)  -- 3 -> 3, not > current
  T.eq('target.seasonalMapsMultiStep', gc:_engineTarget(1, 4), 5)

  mission.missionInfo = { growthMode = 2 } -- DAILY
  T.eq('target.dailyMapsForward', gc:_engineTarget(1, 3), 4)
  T.eq('target.dailyIdentityHolds', gc:_engineTarget(1, 2), nil)
  T.eq('target.dailyMapsMultiStep', gc:_engineTarget(1, 4), 5)

  mission.missionInfo = { growthMode = 1 }
  local bare = { getSeasonalGrowthData = function() return nil end,
                 getNonSeasonalGrowthData = function() return nil end,
                 maxHarvestingGrowthState = 7 }
  g_fruitTypeManager = { getFruitTypeByIndex = function() return bare end }
  T.eq('target.noDataStepsByOne', gc:_engineTarget(1, 2), 3)

  -- The engine-true target follows the mapping toward max; the "never at or
  -- past maxHarvestingGrowthState" guard is on the CURRENT state (guard chain),
  -- not a target filter - writing the engine's own next state is the point.
  local maxed = { getSeasonalGrowthData = function()
                    return { periods = { [3] = { growthMapping = { [6] = 7 } } } } end,
                  getNonSeasonalGrowthData = function() return nil end,
                  maxHarvestingGrowthState = 7 }
  g_fruitTypeManager = { getFruitTypeByIndex = function() return maxed end }
  T.eq('target.engineTrueTowardMax', gc:_engineTarget(1, 6), 7)

  -- A mapping that points BACKWARD or at itself is a hold, never a step back.
  local hold = { getSeasonalGrowthData = function()
                    return { periods = { [3] = { growthMapping = { [5] = 4 } } } } end,
                  getNonSeasonalGrowthData = function() return nil end,
                  maxHarvestingGrowthState = 7 }
  g_fruitTypeManager = { getFruitTypeByIndex = function() return hold end }
  T.eq('target.backwardMappingHolds', gc:_engineTarget(1, 5), nil)

  g_fruitTypeManager = prevFtm
  mission.environment = realEnv
end

-- 3. THE LATTICE STORE: header derivation matches the survey's own rules and
--    cell indexing round-trips world positions.
do
  local verts = { {x = 0, z = 0}, {x = 100, z = 0}, {x = 100, z = 100}, {x = 0, z = 100} }
  local gc = GC.new({})
  gc.isInitialized = true
  local header = gc:_deriveHeader(1, verts)
  T.eq('lattice.stepDefault', header.step, ViabilityMask.SAMPLE_STEP_M)
  T.near('lattice.originX', header.originX, 4.0, 1e-9)
  T.near('lattice.originZ', header.originZ, 4.0, 1e-9)

  local entry = gc:_ensureStore(1, header)
  T.ok('lattice.storeCreated', gc._store[1] ~= nil)
  T.eq('lattice.storeOriginX', entry.originX, header.originX)
  T.eq('lattice.storeStep', entry.step, header.step)

  -- A sample at a cell centre resolves to that cell, and back.
  local gx, gz = gc:_cellIndex(entry, 4.0, 4.0)
  T.eq('lattice.indexOrigin', gx, 0); T.eq('lattice.indexOriginZ', gz, 0)
  local wx, wz = gc:_cellCentre(entry, 0, 0)
  T.near('lattice.centreWorldX', wx, 4.0, 1e-9)
  T.near('lattice.centreWorldZ', wz, 4.0, 1e-9)

  -- A different lattice re-derive (field moved) resets the store.
  local moved = { {x = 200, z = 200}, {x = 300, z = 200}, {x = 300, z = 300}, {x = 200, z = 300} }
  local header2 = gc:_deriveHeader(1, moved)
  gc:_ensureStore(1, header2)
  T.ok('lattice.storeResetsOnMovedHeader', gc._store[1].originX ~= 4.0)
end

-- 4. THE DAILY ACCRUAL AND THE THRESHOLD.
do
  local gc = GC.new({ settings = { difficulty = 1 } })  -- Casual preset
  gc.isInitialized = true
  gc._daysPerPeriod = 2
  gc._agronomyMultCached = 1.0
  T.eq('bookkeeper.thresholdDays', gc:_thresholdDays(), 4)  -- 2 periods * 2 days

  local calls = {}
  local vm = {
    enabled = true,
    getCellGrowthInfo = function(_self, _fid, x, z)
      calls[#calls + 1] = { x = x, z = z }
      return { bands = { n = ViabilityMask.BAND_EXCELLENT, compaction = ViabilityMask.BAND_EXCELLENT, moisture = nil } }
    end,
  }
  local ss = {
    fieldData = { [7] = { _polyVerts = { {x = 0, z = 0}, {x = 24, z = 0}, {x = 24, z = 24}, {x = 0, z = 24} } } },
    _getFieldPolyVerts = function(_self, _fid, field) return field._polyVerts end,
  }
  gc.manager = { viability = vm, soilSystem = ss }

  local n = gc:runDailyPass({ daysPerPeriod = 2 })
  T.ok('bookkeeper.passRan', n == 1)
  T.ok('bookkeeper.sampledCells', #calls > 0)

  -- Every sampled cell accrued one day (all excellent on casual).
  local entry = gc._store[7]
  local accrued = 0
  for _, row in pairs(entry.cells) do
    for _, cell in pairs(row) do
      if cell.credit >= 1 then accrued = accrued + 1 end
    end
  end
  T.ok('bookkeeper.accruedAllSamples', accrued == #calls)
end

-- 5. THE NEUTRAL FLOWS.
do
  local gc = GC.new({})
  gc.isInitialized = false
  T.eq('neutral.uninitializedRead', gc:readCreditAt(1, 0, 0), nil)
  gc.isInitialized = true
  T.eq('neutral.untrackedField', gc:readCreditAt(99, 0, 0), nil)

  -- A blocked cell never advances through the guard.
  local fruitDesc = {
    terrainDataPlaneId = 5, cutState = 0, maxHarvestingGrowthState = 7,
    getIsCut = function(_self, s) return s == 0 end,
    getIsWithered = function() return false end,
  }
  local prevFtm = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function() return fruitDesc end }
  local gc2 = GC.new({})
  gc2.isInitialized = true
  local entry = { originX = 4, originZ = 4, step = 8, cells = {} }
  local vm = {
    enabled = true,
    getCellGrowthInfo = function() return { blocked = true } end,
  }
  T.ok('guard.blockedRefuses',
    gc2:_guardCell(7, 1, 2, { fruitIndex = nil }, entry, 0, 0, vm) == false)

  -- Cut and withered refuse.
  local vmClear = { getCellGrowthInfo = function() return { blocked = false } end }
  T.ok('guard.cutRefuses', gc2:_guardCell(7, 1, 0, { fruitIndex = nil }, entry, 0, 0, vmClear) == false)
  fruitDesc.getIsWithered = function(_self, s) return s == 4 end
  T.ok('guard.witheredRefuses', gc2:_guardCell(7, 1, 4, { fruitIndex = nil }, entry, 0, 0, vmClear) == false)
  fruitDesc.getIsWithered = function() return false end

  -- Orphan guard: a cell that changed fruit keeps its credit and skips.
  T.ok('guard.orphanRefuses',
    gc2:_guardCell(7, 1, 2, { fruitIndex = 9 }, entry, 0, 0, vmClear) == false)
  -- Matching fruit passes.
  T.ok('guard.matchingFruitPasses',
    gc2:_guardCell(7, 1, 2, { fruitIndex = 1 }, entry, 0, 0, vmClear) == true)
  g_fruitTypeManager = prevFtm
end

-- 5b. F165 THE STORE HAS AN INVALIDATION PATH. A cell credited while bare
--     (fruitIndex nil) must never spend its bank on a crop sown later: the
--     guard treats a nil stored index as a RESET, clearing the credit, and a
--     cell that reads fruit UNKNOWN at the bell is invalidated the same way.
do
  local fruitDesc = {
    terrainDataPlaneId = 5, cutState = 0, maxHarvestingGrowthState = 7,
    getIsCut = function(_self, s) return s == 0 end,
    getIsWithered = function() return false end,
  }
  local prevFtm = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function() return fruitDesc end }
  local gc = GC.new({})
  gc.isInitialized = true
  local entry = { originX = 4, originZ = 4, step = 8, cells = {} }
  local vmClear = { getCellGrowthInfo = function() return { blocked = false } end }

  -- A cell with a NIL stored fruitIndex and a full bank is reset, never spent:
  -- the guard refuses and the credit is cleared.
  local bare = { credit = 60, fruitIndex = nil }
  T.ok('f165.nilIndexRefuses', gc:_guardCell(7, 1, 2, bare, entry, 0, 0, vmClear) == false)
  T.eq('f165.nilIndexClearsCredit', bare.credit, 0)

  -- A matching stored index still passes (the normal path is untouched).
  local banked = { credit = 40, fruitIndex = 1 }
  T.ok('f165.matchingStillPasses', gc:_guardCell(7, 1, 2, banked, entry, 0, 0, vmClear) == true)
  T.eq('f165.matchingKeepsCredit', banked.credit, 40)

  -- A cell that reads fruit UNKNOWN at the bell is invalidated in the stroke:
  -- its bank is cleared so a gsFieldSetState or cultivated-to-UNKNOWN field
  -- cannot carry credit into the next sowing.
  local prevUtil = FSDensityMapUtil
  FSDensityMapUtil = { getFruitTypeIndexAtWorldPos = function() return nil, nil end }
  local store = {
    originX = 4, originZ = 4, step = 8, maxX = 24, maxZ = 24,
    cells = { [0] = { [0] = { credit = 50, fruitIndex = nil } } },
  }
  local stroked = gc:_strokeField(7, store, vmClear, 1)
  T.ok('f165.unknownAtBellStrokes', stroked == false or stroked == nil)
  T.eq('f165.unknownAtBellCleared', store.cells[0][0].credit, 0)
  FSDensityMapUtil = prevUtil

  g_fruitTypeManager = prevFtm
end

-- 6. THE WRITE BUCKET: rings over a bucket's cells, feed the stored header.
do
  local gc = GC.new({})
  gc.isInitialized = true
  local entry = { originX = 4, originZ = 4, step = 8 }
  local rings = gc:_bucketRings({ {gx = 0, gz = 0} }, entry)
  T.ok('write.singleCellRing', rings ~= nil and #rings == 1)
  T.ok('write.ringHasFourPoints', rings[1] ~= nil and #rings[1] == 4)

  -- Two adjacent cells form one 6-point ring (shared edge removed).
  local rings2 = gc:_bucketRings({ {gx = 0, gz = 0}, {gx = 1, gz = 0} }, entry)
  T.ok('write.adjacentOneRegion', rings2 ~= nil and #rings2 == 1)
  T.ok('write.adjacentSixPoints', rings2[1] ~= nil and #rings2[1] == 6)

  -- Two separated cells form two rings.
  local rings3 = gc:_bucketRings({ {gx = 0, gz = 0}, {gx = 5, gz = 5} }, entry)
  T.ok('write.separatedTwoRings', rings3 ~= nil and #rings3 == 2)
end

-- 7. THE RELEASE GATE: growth_modulation is LOCKED until the opt-in, and
--    isLive consults it (bench path fails open to live when settings unreadable).
do
  T.ok('gate.growthModulationRegistered', ReleaseGate.EXPERIMENTAL.growth_modulation ~= nil)
  T.ok('gate.lockedByDefault', ReleaseGate.isReleased("growth_modulation", false) == false)
  T.ok('gate.releasedWhenOptIn', ReleaseGate.isReleased("growth_modulation", true) == true)

  local gc = GC.new({})
  gc.isInitialized = true
  local prev = g_SoilFertilityManager
  g_SoilFertilityManager = { settings = { experimentalSystems = false,
    allowsExperimentalSystems = function(self) return self.experimentalSystems end } }
  T.ok('live.lockedWhenOptInOff', gc:isLive() == false)
  g_SoilFertilityManager = { settings = { experimentalSystems = true,
    allowsExperimentalSystems = function(self) return self.experimentalSystems end } }
  T.ok('live.liveWhenOptInOn', gc:isLive() == true)
  -- Mask disabled gates hard even when the gate is open.
  g_SoilFertilityManager = nil
  gc.manager = { viability = { enabled = false, getCellGrowthInfo = function() end } }
  T.ok('live.maskOffGatesHard', gc:isLive() == false)
  g_SoilFertilityManager = prev
end

T.summary()
