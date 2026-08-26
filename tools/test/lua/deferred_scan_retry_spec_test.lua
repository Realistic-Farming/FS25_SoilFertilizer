-- deferred_scan_retry_spec_test.lua
-- #880: fresh-save field seeding can race mods that alter the mission-start
-- lifecycle (Starting Spring etc.). If the first scanFields() runs while
-- g_fieldManager.fields is still empty, fieldData stays empty and the post-load
-- layer seeds loop over nothing - the maps read as every field at zero. This
-- locks the bounded deferred re-scan that fixes that class: scanFields arms a
-- pending flag on every deferral, the retry pump re-runs the scan at a fixed
-- cadence until fields appear or the window closes, and a deferred success
-- replays the post-load seed steps a normal fresh save would have had.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local SFS = SoilFertilitySystem

-- Minimal system shell. Mirrors the constructor fields the paths under test
-- touch; everything else is nil and skipped by guards.
local function newSystem()
  local s = setmetatable({}, { __index = SFS })
  s.settings = { enabled = true }
  s.fieldData = {}
  s.genesisActive = false
  s.genesisSeed = 0
  s.bundledMaps = nil
  s.layerSystem = nil
  s.fieldsScanPending = false
  s.scanRetryTimer = 0
  s.scanRetryAttempts = 0
  s.reseeded = 0
  return s
end

local function makeField(id, area)
  return { farmland = { id = id, areaInHa = area }, areaHa = area }
end

-- Farmland manager is not stubbed in the prelude; scanFields touches it only on
-- the populated path (ownership read + secondary scan).
g_farmlandManager = {
  farmlands = {},
  getFarmlandOwner = function() return 0 end,
  getFarmlandById = function() return nil end,
}

-- 1. DEFER: an empty field table arms the pending flag; a populated one clears
--    it, creates the field and seeds non-zero defaults.
do
  local s = newSystem()
  g_fieldManager.fields = {}
  local ok = s:scanFields()
  T.ok('defer.emptyArmsPending', s.fieldsScanPending == true)
  T.ok('defer.emptyReturnsFalse', ok == false)

  g_fieldManager.fields = { makeField(1, 3.2) }
  local ok2 = s:scanFields()
  T.ok('defer.populatedClearsPending', s.fieldsScanPending == false)
  T.ok('defer.populatedReturnsTrue', ok2 == true)
  T.ok('defer.fieldCreated', s.fieldData[1] ~= nil)
  T.ok('defer.fieldSeededNonZero', (s.fieldData[1].nitrogen or 0) > 0)
end

-- 2. THE PUMP: pending ticks on the cadence and keeps retrying while empty.
do
  local s = newSystem()
  g_fieldManager.fields = {}
  s:scanFields()  -- arms pending
  s:_scanRetryTick(1000)
  T.ok('pump.retriesWhileEmpty', s.fieldsScanPending == true)
  T.ok('pump.attemptsIncrement', s.scanRetryAttempts == 1)
  -- A sub-interval tick accumulates but does not fire a retry.
  s:_scanRetryTick(500)
  T.ok('pump.accumulatesBeforeFire', s.scanRetryTimer > 0 and s.scanRetryAttempts == 1)
end

-- 3. THE RESEED: once fields appear, a retry succeeds, clears pending, and
--    replays the post-load seed steps.
do
  local s = newSystem()
  g_fieldManager.fields = {}
  s:scanFields()
  s._reseedAfterDeferredScan = function() s.reseeded = s.reseeded + 1 end
  g_fieldManager.fields = { makeField(2, 4.5) }
  s:_scanRetryTick(1000)
  T.ok('reseed.successClearsPending', s.fieldsScanPending == false)
  T.ok('reseed.fieldCreated', s.fieldData[2] ~= nil)
  T.ok('reseed.replayed', s.reseeded == 1)
  -- The pump is inert once the flag is cleared.
  s:_scanRetryTick(1000)
  T.ok('reseed.noFurtherRetries', s.reseeded == 1)
end

-- 4. THE WINDOW: after SCAN_RETRY_MAX attempts the pump gives up instead of
--    spinning forever (the lazy getOrCreateField path remains as the backstop).
do
  local s = newSystem()
  g_fieldManager.fields = {}
  s:scanFields()
  for _ = 1, 21 do s:_scanRetryTick(1000) end
  T.ok('window.givesUpAfterCap', s.fieldsScanPending == false)
  T.ok('window.countedCap', s.scanRetryAttempts == 21)
end

-- 5. THE CLIENT: a multiplayer client never arms pending (it returns done and
--    waits for the server sync), so the retry pump stays off on clients.
do
  local s = newSystem()
  g_currentMission.missionDynamicInfo = { isMultiplayer = true }
  g_server = nil
  local ok = s:scanFields()
  T.ok('client.returnsDone', ok == true)
  T.ok('client.notPending', s.fieldsScanPending == false)
  g_currentMission.missionDynamicInfo = nil
end

T.summary()
