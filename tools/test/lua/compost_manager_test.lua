-- compost_manager_test.lua
-- The organic compost PRODUCTION layer: a managed process (no placeable) that
-- commits farm organic waste to a batch, decomposes it over in-game days on the
-- Time Guard clock, and yields the existing COMPOST fill type. SF owns the OM
-- amendment effect; this owns production only.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/CompostManager.lua

g_currentMission = { _isServer = true }
function g_currentMission:getIsServer() return self._isServer end
g_SoilFertilityManager = { settings = { difficulty = 2 } }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) if name == "COMPOST" then return 1 end return 0 end }
ToolType = { UNDEFINED = 0 }

local function newManager()
  local m = CompostManager.new()
  m._markDirty = function() end
  return m
end

-- 1. START A BATCH: validates, computes the finished output and the organic flag.
do
  local m = newManager()
  local id, why = m:startBatch(1, { MANURE = 1000 })
  T.eq('start.batchCreated', id, 1)
  T.eq('start.okReason', why, "ok")
  local b = m.batches[1]
  T.eq('start.outputFromManure', b.outputLitres, 450)
  T.eq('start.manureIsOrganicSafe', b.organicSafe, true)
  T.eq('start.daysAtRealistic', b.totalDays, 14)
  T.eq('start.notReadyInitially', b.ready, false)
end

-- 2. BIOSOLIDS MAKES A BATCH NOT ORGANIC-SAFE (the organic-cert excludes biosolids).
do
  local m = newManager()
  m:startBatch(1, { BIOSOLIDS = 500 })
  T.eq('organic.biosolidsNotSafe', m.batches[1].organicSafe, false)
  local m2 = newManager()
  m2:startBatch(1, { MANURE = 400, BIOSOLIDS = 100 })
  T.eq('organic.mixedIsNotSafe', m2.batches[1].organicSafe, false)
end

-- 3. DECOMPOSITION: tickDay advances, a batch becomes ready when its days run out.
do
  local m = newManager()
  m:startBatch(1, { MANURE = 1000 })   -- 14 days at realistic
  m:tickDay(13)
  T.eq('decompose.notReadyAt13', m.batches[1].ready, false)
  T.eq('decompose.oneDayLeft', m.batches[1].daysRemaining, 1)
  m:tickDay(1)
  T.eq('decompose.readyAtEnd', m.batches[1].ready, true)
  T.eq('decompose.daysRemainingFloor', m.batches[1].daysRemaining, 0)
end

-- 4. COLLECT: deposits the finished compost into farm storage and clears the batch.
do
  local deposited = {}
  local m = newManager()
  m:startBatch(1, { MANURE = 1000 })
  m:tickDay(99)
  T.eq('collect.ready', m.batches[1].ready, true)
  m._depositCompost = function(_self, farmId, litres)
    deposited[#deposited + 1] = { farmId = farmId, litres = litres }
    return litres
  end
  local n, why = m:collectBatch(1)
  T.eq('collect.depositsOutput', n, 450)
  T.eq('collect.toFarm', deposited[1].farmId, 1)
  T.eq('collect.clearsBatch', m.batches[1], nil)
end

-- 5. A NOT-READY BATCH CANNOT BE COLLECTED.
do
  local m = newManager()
  m:startBatch(1, { MANURE = 100 })
  local n, why = m:collectBatch(1)
  T.eq('collect.notReadyRefused', n, nil)
  T.eq('collect.notReadyReason', why, "not_ready")
end

-- 6. PERSISTENCE ROUND TRIP (the ledger table shape).
do
  local m = newManager()
  m:startBatch(1, { MANURE = 800 })
  m:tickDay(5)
  local ser = m:serialize()
  local m2 = newManager()
  m2:deserialize(ser)
  T.eq('persist.batchSurvives', m2.batches[1] ~= nil, true)
  T.eq('persist.daysRemaining', m2.batches[1].daysRemaining, m.batches[1].daysRemaining)
  T.eq('persist.outputSurvives', m2.batches[1].outputLitres, m.batches[1].outputLitres)
  T.eq('persist.organicSafeSurvives', m2.batches[1].organicSafe, true)
  T.eq('persist.nextIdSurvives', m2.nextBatchId, m.nextBatchId)
end

-- 7. THE BATCH NEVER RUNS ON A CLIENT.
do
  local m = newManager()
  g_currentMission._isServer = false
  local id, why = m:startBatch(1, { MANURE = 100 })
  T.eq('client.cannotStart', id, nil)
  T.eq('client.reason', why, "server_only")
  g_currentMission._isServer = true
end

T.summary()
