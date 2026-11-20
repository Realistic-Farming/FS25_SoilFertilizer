-- daily_catchup_test.lua - the skipped-day / batch-cursor repair.
--   * A new day arriving before the async batch drained must FINISH the prior
--     day's tail, not reset the cursor and freeze it (the stranded-tail bug).
--   * A multi-day skip must apply each missed day (the daily logic runs once per
--     elapsed day) rather than collapsing into a single pass.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

-- A SoilFertilitySystem with the value-map + per-field-work collaborators stubbed,
-- counting how many times each field's daily pass runs.
local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.DAILY_BATCH_SIZE       = 25
  s.vmAvailable            = function() return false end
  s._vmSnapshotField       = function() return nil end
  s._vmApplySnapshotDeltas = function() end
  s._vmMirrorDisplayField  = function() end
  s._calls = {}
  s._processOneDailyField  = function(self2, fid, _fd) self2._calls[fid] = (self2._calls[fid] or 0) + 1 end
  return s
end

-- ── Stranding + catch-up via the synchronous drain ──────────────
do
  local s = newSys()
  s._activeFieldList   = { 1, 2, 3, 4, 5 }
  s.fieldData          = { [1] = {}, [2] = {}, [3] = {}, [4] = {}, [5] = {} }
  s._dailyBatchCursor  = 2      -- fields 1,2 already done by the async batch
  s._dailyBatchRepeat  = 3      -- this batch stands in for 3 days
  s._pendingDailyUpdate = true
  s._dailyBatchSeason  = 2

  s:_drainDailyBatchSync()

  T.eq("already-processed field 1 not touched", s._calls[1], nil)
  T.eq("already-processed field 2 not touched", s._calls[2], nil)
  T.eq("stranded tail field 3 processed x3", s._calls[3], 3)
  T.eq("stranded tail field 4 processed x3", s._calls[4], 3)
  T.eq("stranded tail field 5 processed x3", s._calls[5], 3)
  T.eq("cursor settled to n", s._dailyBatchCursor, 5)
  T.eq("batch closed", s._pendingDailyUpdate, false)
  T.eq("season committed", s.lastSeason, 2)
end

-- ── updateDailySoil drains a pending prior batch, then queues the new day ──
do
  local s = newSys()
  s.settings           = { enabled = true, nutrientCycles = true }
  s._activeFieldList   = { 10, 11 }
  s.fieldData          = { [10] = {}, [11] = {} }
  s._activeListDirty   = false
  -- a prior day's batch left pending mid-way (field 10 done, field 11 stranded)
  s._pendingDailyUpdate = true
  s._dailyBatchDay     = 4
  s._dailyBatchCursor  = 1
  s._dailyBatchRepeat  = 1

  g_currentMission.environment.currentDay = 5   -- a new day
  s:updateDailySoil(2)                           -- 2 monotonic days elapsed

  T.eq("prior-day stranded field 11 drained once", s._calls[11], 1)
  T.eq("prior-day done field 10 not re-drained", s._calls[10], nil)
  T.eq("new batch day = 5", s._dailyBatchDay, 5)
  T.eq("new repeat = elapsed 2", s._dailyBatchRepeat, 2)
  T.eq("new cursor reset to 0", s._dailyBatchCursor, 0)
  T.eq("new batch pending", s._pendingDailyUpdate, true)
end

-- ── same-day duplicate trigger is still guarded (no double queue) ──
do
  local s = newSys()
  s.settings            = { enabled = true, nutrientCycles = true }
  s._activeFieldList    = { 20 }
  s.fieldData           = { [20] = {} }
  s._pendingDailyUpdate = true
  s._dailyBatchDay      = 7
  s._dailyBatchCursor   = 0
  s._dailyBatchRepeat   = 1

  g_currentMission.environment.currentDay = 7   -- SAME day, duplicate trigger
  s:updateDailySoil(1)

  T.eq("same-day duplicate does not drain", s._calls[20], nil)
  T.eq("same-day cursor untouched", s._dailyBatchCursor, 0)
end
