-- SF-78-growth_block_restore_spec_test.lua
-- SF-78 GROWTH BLOCK: the hold half of the SF-2M pair. The executable bar for
-- the write-once capture, the R2 discriminator (three halves), the restore
-- cap bounds, the unconditional capture clear, and the neutral flows.
--
-- THE INVARIANTS THAT MATTER:
--   capture is write-once across a bracket,
--   R2 needs all three halves (fruit unchanged, not cut/withered, strictly
--   above captured) or the cell is abandoned with nothing written,
--   the restore never goes below the captured value,
--   the capture is CLEARED UNCONDITIONALLY at every drained delivery,
--   the family is inert until the release gate opens AND the mask is enabled.
--!load: src/utils/Logger.lua, src/ReleaseGate.lua, src/ViabilityMask.lua, src/GrowthBlock.lua

local GB = GrowthBlock

-- 1. THE WRITE-ONCE CAPTURE: a held capture is never re-captured, so a
--    catch-up that fires the NEXT START before the CURRENT FINISHED cannot
--    destroy the restore basis.
do
  local gc = GB.new({})
  gc.isInitialized = true
  gc._captureHeld = true
  local calls = 0
  local ss = {
    fieldData = { [7] = {} },
    _getFieldPolyVerts = function() calls = calls + 1; return {} end,
  }
  gc.manager = { viability = { getCellGrowthInfo = function() return { blocked = true } end },
                 soilSystem = ss }
  local prev = g_currentMission
  g_currentMission = { getIsServer = function() return true end }
  gc:onStartGrowthPeriod()
  T.eq('capture.writeOnceHeld', calls, 0)
  gc._captureHeld = false
  g_currentMission = prev
end

-- 2. THE R2 DISCRIMINATOR, three halves.
do
  local fruitDesc = {
    terrainDataPlaneId = 5, cutState = 0,
    getIsCut = function(_self, s) return s == 0 end,
    getIsWithered = function(_self, s) return s == 4 end,
  }
  local prevFtm = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function() return fruitDesc end }

  local gc = GB.new({})
  gc.isInitialized = true

  -- Half 2: cut and withered refuse.
  T.eq('r2.cutRefuses', gc:_passesR2CutWither(1, 0), false)
  T.eq('r2.witheredRefuses', gc:_passesR2CutWither(1, 4), false)
  T.eq('r2.growingPasses', gc:_passesR2CutWither(1, 2), true)

  -- Half 3: current strictly above captured.
  local header = { originX = 4, originZ = 4, step = 8, maxX = 24, maxZ = 24 }
  local calls = {}
  local prevUtil = FSDensityMapUtil
  FSDensityMapUtil = { getFruitTypeIndexAtWorldPos = function(_x, _z)
    calls[#calls + 1] = true
    return 1, 3  -- current state 3
  end }
  local capture = { header = header, cells = { { gx = 0, gz = 0, state = 2, fruitIndex = 1 } } }
  local wrote = gc:_restoreField(7, capture, 1)
  T.ok('r2.strictlyAboveWrites', wrote == true)
  T.ok('r2.stateReadOnce', #calls == 1)

  -- Half 1: fruit changed, abandon.
  FSDensityMapUtil = { getFruitTypeIndexAtWorldPos = function() return 9, 3 end }
  local capture2 = { header = header, cells = { { gx = 0, gz = 0, state = 2, fruitIndex = 1 } } }
  T.ok('r2.fruitChangedAbandons', gc:_restoreField(7, capture2, 1) == false)

  -- Half 3: current not strictly above captured, abandon.
  FSDensityMapUtil = { getFruitTypeIndexAtWorldPos = function() return 1, 2 end }
  T.ok('r2.notAboveAbandons', gc:_restoreField(7, capture2, 1) == false)

  FSDensityMapUtil = prevUtil
  g_fruitTypeManager = prevFtm
end

-- 3. THE RESTORE TARGET: max(captured, current - cap), never below captured.
do
  local gc = GB.new({})
  gc.isInitialized = true
  gc._agronomyMultCached = 1.0
  T.eq('target.capOneBasic', gc:_restoreTarget(3, 2, 1), 2)   -- 3-1 = 2
  T.eq('target.capTwo', gc:_restoreTarget(5, 2, 2), 3)        -- 5-2 = 3
  T.eq('target.neverBelowCaptured', gc:_restoreTarget(3, 2, 5), 2) -- 3-5 < 0 clamp to captured
  T.eq('target.holdingAtCaptured', gc:_restoreTarget(2, 2, 1), 2)  -- not above, clamp
end

-- 4. THE UNCONDITIONAL CLEAR at every drained delivery.
do
  local gc = GB.new({})
  gc.isInitialized = true
  gc._capture = { [7] = { header = {}, cells = {} } }
  gc._captureHeld = true
  local prev = g_currentMission
  g_currentMission = { getIsServer = function() return true end,
                       missionInfo = { growthMode = 1 } }

  -- DISABLED: no writes, but the capture still clears.
  g_currentMission.missionInfo.growthMode = 3
  gc:onFinishedGrowthPeriod(1, false)
  T.eq('clear.disabledStillClears', gc._captureHeld, false)
  T.eq('clear.disabledEmptiesStore', next(gc._capture) == nil, true)

  -- Re-capture, then a drained delivery with writes clears it.
  gc._capture = { [7] = { header = {}, cells = {} } }
  gc._captureHeld = true
  gc._agronomyMultCached = 1.0
  gc._viability = function() return nil end  -- no restores possible, but clear still runs
  g_currentMission.missionInfo.growthMode = 1
  gc:onFinishedGrowthPeriod(1, false)
  T.eq('clear.drainedClears', gc._captureHeld, false)

  -- hasPendingGrowth true: hold, do not clear.
  gc._capture = { [7] = { header = {}, cells = {} } }
  gc._captureHeld = true
  gc:onFinishedGrowthPeriod(1, true)
  T.eq('clear.pendingHolds', gc._captureHeld, true)
  gc:onFinishedGrowthPeriod(1, false)
  T.eq('clear.pendingDrainedClears', gc._captureHeld, false)
  g_currentMission = prev
end

-- 5. THE NEUTRAL FLOWS.
do
  local gc = GB.new({})
  gc.isInitialized = false
  local prev = g_currentMission
  g_currentMission = { getIsServer = function() return true end }
  gc:onStartGrowthPeriod()
  T.eq('neutral.uninitializedCapture', gc._captureHeld, nil)
  gc.isInitialized = true
  -- No viability/soilSystem: an initialized module without the family's data
  -- captures nothing and never holds a bracket.
  gc:onStartGrowthPeriod()
  T.eq('neutral.noDataCapturesNothing', gc._captureHeld == true and next(gc._capture) ~= nil, false)
  g_currentMission = prev
end

-- 6. THE RELEASE GATE: growth_modulation gates the module, and the mask
--    disable gates hard.
do
  T.ok('gate.lockedByDefault', ReleaseGate.isReleased("growth_modulation", false) == false)
  T.ok('gate.releasedWhenOptIn', ReleaseGate.isReleased("growth_modulation", true) == true)

  local gc = GB.new({})
  gc.isInitialized = true
  local prev = g_SoilFertilityManager
  g_SoilFertilityManager = { settings = { experimentalSystems = false,
    allowsExperimentalSystems = function(self) return self.experimentalSystems end } }
  T.ok('live.lockedWhenOptInOff', gc:isLive() == false)
  g_SoilFertilityManager = { settings = { experimentalSystems = true,
    allowsExperimentalSystems = function(self) return self.experimentalSystems end } }
  T.ok('live.liveWhenOptInOn', gc:isLive() == true)
  g_SoilFertilityManager = nil
  gc.manager = { viability = { enabled = false, getCellGrowthInfo = function() end } }
  T.ok('live.maskOffGatesHard', gc:isLive() == false)
  g_SoilFertilityManager = prev
end

T.summary()
