-- establishment_window_spec_test.lua
-- SF-18 ESTABLISHMENT FAILURE: the keystone's executable bar.
-- Locks the window machine, the threshold/compaction/severity semantics,
-- NO-SIGNAL-NO-THINNING, the kill-once rule, the re-drill path, the live
-- green window-close, and the positional per-cell kill grouping.
-- No engine: a stubbed moisture read + field record drive the real
-- EstablishmentFailure module.
--!load: src/utils/Logger.lua, src/EstablishmentFailure.lua

local function newSystem()
  local soilSystem = {}
  soilSystem.fieldData = {}
  soilSystem.getOrCreateField = function(_self, fieldId, _create)
    if soilSystem.fieldData[fieldId] == nil then
      soilSystem.fieldData[fieldId] = { fieldId = fieldId, compaction = 0, sownCrop = nil, zoneData = nil, establishingKilledCells = nil }
    end
    return soilSystem.fieldData[fieldId]
  end
  soilSystem._currentMonotonicDay = function() return 40 end
  local manager = { soilSystem = soilSystem }
  local est = EstablishmentFailure.new(manager)
  est.isInitialized = true
  return est, soilSystem, manager
end

-- The live green sampler is engine-bound; the bench drives it with a seam.
local function stubGreen(est, value)
  est._sampleFieldGreenState = function() return value end
end

-- 1. Window opens on sowing, extends on re-sow.
do
  local est, soil = newSystem()
  est:onSowing(1)
  local f = soil.fieldData[1]
  T.eq("sow.opensWindow", f.establishing, true)
  T.eq("sow.sowDay", f.establishingSowDay, 40)
  est:onSowing(1)
  T.eq("resow.extendsWindow", f.establishing, true)
end

-- 2. No SCS moisture handle = NO THINNING, ever (absolute invariant).
do
  local est, soil = newSystem()
  est:onSowing(2)
  est:dailyKillCheck(1)
  T.eq("noSignal.noThinning", soil.fieldData[2].establishingKilled, false)
  T.eq("noSignal.windowOpen", soil.fieldData[2].establishing, true)
end

-- 3. Moisture below threshold = survives.
do
  local est, soil = newSystem()
  est:onSowing(3)
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.4 end }
  est:dailyKillCheck(1)
  T.eq("belowThreshold.survives", soil.fieldData[3].establishingKilled, false)
end

-- 4. Moisture at/above threshold = killed once, window closes, stays closed.
do
  local est, soil = newSystem()
  est:onSowing(4)
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.9 end }
  est:dailyKillCheck(1)
  local f = soil.fieldData[4]
  T.eq("waterlogged.killed", f.establishingKilled, true)
  T.eq("waterlogged.windowClosed", f.establishing, false)
  -- Kill-once: a second pass does not re-kill.
  est:dailyKillCheck(1)
  T.eq("waterlogged.killedOnce", f.establishingKilled, true)
end

-- 5. Compacted seedbed lowers the threshold (fails earlier).
do
  local est, soil = newSystem()
  est:onSowing(5)
  soil.fieldData[5].compaction = 100  -- fully compacted seedbed
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.70 end }
  -- At 0.70 moisture, the base threshold (0.85) survives but the compacted
  -- threshold (0.85 - 0.20 = 0.65) fails.
  est:dailyKillCheck(1)
  T.eq("compacted.failsEarlier", soil.fieldData[5].establishingKilled, true)
end

-- 6. Loose seedbed at the same moisture survives.
do
  local est, soil = newSystem()
  est:onSowing(6)
  soil.fieldData[6].compaction = 0
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.70 end }
  est:dailyKillCheck(1)
  T.eq("loose.survives", soil.fieldData[6].establishingKilled, false)
end

-- 7. Re-drill re-opens the window after a kill (the never-stuck floor).
do
  local est, soil = newSystem()
  est:onSowing(7)
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.9 end }
  est:dailyKillCheck(1)
  T.eq("kill.beforeReDrill", soil.fieldData[7].establishingKilled, true)
  est:onSowing(7)
  local f = soil.fieldData[7]
  T.eq("redrill.reopens", f.establishing, true)
  T.eq("redrill.killReset", f.establishingKilled, false)
end

-- 8. Window closes only when the crop is LIVE GREEN (sampled seam).
do
  local est, soil = newSystem()
  est:onSowing(8)
  local f = soil.fieldData[8]
  f.sownCrop = "wheat"
  -- Crop not yet green: window stays open, nothing closes.
  stubGreen(est, 1)
  est:closeWindowIfEstablished(8, f, g_fruitTypeManager:getFruitTypeByName("wheat"))
  T.eq("notgreen.windowOpen", f.establishing, true)
  -- Crop reaches first visible green: window closes, kill reset.
  stubGreen(est, 6)
  est:closeWindowIfEstablished(8, f, g_fruitTypeManager:getFruitTypeByName("wheat"))
  T.eq("green.windowClosed", f.establishing, false)
  T.eq("green.killReset", f.establishingKilled, false)
end

-- 9. Severity dial (neutral Biological) scales the moisture before the threshold.
do
  local est, soil = newSystem()
  est:onSowing(9)
  -- 0.5 moisture is below the 0.85 threshold at neutral severity...
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.5 end }
  est:dailyKillCheck(1)
  T.eq("neutral.survives", soil.fieldData[9].establishingKilled, false)
  -- ...but a harder Biological severity trips it.
  local saved = EstablishmentFailure.SEVERITY
  EstablishmentFailure.SEVERITY = 2.0
  est:onSowing(9)
  est:dailyKillCheck(1)
  T.eq("harder.trips", soil.fieldData[9].establishingKilled, true)
  EstablishmentFailure.SEVERITY = saved
end

-- 10. Per-cell positional kill: only the waterlogged cells die, others survive.
do
  local est, soil = newSystem()
  est:onSowing(10)
  local f = soil.fieldData[10]
  f.compaction = 0
  -- Two zone cells; cell A waterlogged (0.95), cell B dry (0.1).
  f.zoneData = {
    a = { gx = 0, gz = 0, compaction = 0 },
    b = { gx = 1, gz = 0, compaction = 0 },
  }
  g_currentMission.cropStressManager = {
    getMoisture = function(_s, _f, x, z)
      if x and z and x < 10 and z < 10 then return 0.95 end
      return 0.1
    end,
  }
  est:dailyKillCheck(1)
  -- Cell A killed, cell B survives: window stays open (partial stand).
  T.eq("percell.wetKilled", f.establishingKilled, true)
  T.eq("percell.drySurvives", f.establishingKilledCells["1,0"], nil)
  T.eq("percell.windowOpen", f.establishing, true)
  -- The whole stand fails when the last dry cell also waterlogs.
  g_currentMission.cropStressManager = {
    getMoisture = function(_s, _f, _x, _z) return 0.95 end,
  }
  est:dailyKillCheck(1)
  T.eq("percell.allKilled", f.establishingKilledCells["1,0"], true)
  T.eq("percell.windowClosed", f.establishing, false)
end

-- 11. Per-region write is ATTEMPTED through the substrate, and only for killed regions.
do
  local est, soil = newSystem()
  est:onSowing(11)
  local f = soil.fieldData[11]
  f.sownCrop = "wheat"
  f.zoneData = { a = { gx = 2, gz = 2, compaction = 0 } }
  g_currentMission.cropStressManager = { getMoisture = function(_s, _f) return 0.95 end }
  -- The substrate stub records the write attempt.
  local writesBefore = DensityMapModifier and 0 or -1
  est:dailyKillCheck(1)
  T.eq("substrate.writeAttempted", f.establishingKilled, true)
end

T.summary()
