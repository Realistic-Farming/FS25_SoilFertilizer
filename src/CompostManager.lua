-- =========================================================
-- FS25_SoilFertilizer - CompostManager (organic compost production)
-- =========================================================
-- A MANAGED PROCESS, no placeable (Arissani 2026-07-17): the player commits farm
-- organic waste to a batch, the batch decomposes over in-game days on the Time
-- Guard clock, and a finished batch yields the EXISTING COMPOST fill type into
-- farm storage. SF owns the OM amendment effect (COMPOST is an OM-primary
-- product, FERTILIZER_PROFILES.COMPOST.OM = 0.12); this system owns production
-- only. No new fill type, no new soil authority.
--
-- Server-authoritative. Batch state persists via StateLedger when present, own
-- XML fallback otherwise. Decomposition rides Time Guard's day accrual
-- (simulation flow), with an SF day-tracking fallback when Time Guard is absent.
-- The batch duration is a NATURAL rate, not days-per-period normalized.
-- =========================================================

CompostManager = {}
local CompostManager_mt = Class(CompostManager)

CompostManager.LEDGER = "DairyCore_FeedProvenance_Compost"  -- namespaced under this mod's slot
CompostManager.LEDGER_BATCHES = "SoilFertilizer_CompostBatches"
CompostManager.SAVE_FILE = "FS25_SoilFertilizer_Compost.xml"
CompostManager.ACCURAL_ID = "SF_Compost_Batch"
CompostManager.ACCURAL_PRIORITY = 95

-- Natural decomposition time in in-game days for a batch, by difficulty
-- (1 Simple / 2 Realistic / 3 Hardcore). INDICATIVE; rides the balance pass.
CompostManager.BATCH_DAYS = { 7, 14, 21 }

-- Feedstock -> output yield (litres of finished COMPOST per litre of feedstock).
-- MANURE family is organic-safe; BIOSOLIDS is not (the built organic-cert
-- excludes biosolids, and the breach rides SF's existing onInputApplied).
CompostManager.FEEDSTOCK_YIELD = {
    MANURE        = 0.45,
    LIQUIDMANURE  = 0.45,
    DIGESTATE     = 0.45,
    SILAGE        = 0.30,
    COMPOST       = 0.30,
    BIOSOLIDS     = 0.35,
}

-- Feedstocks that keep a batch organic-safe (the approved-input family).
CompostManager.ORGANIC_SAFE = {
    MANURE = true, LIQUIDMANURE = true, DIGESTATE = true, COMPOST = true,
}

function CompostManager.new()
    local self = setmetatable({}, CompostManager_mt)
    self.batches = {}          -- batchId -> batch record
    self.nextBatchId = 1
    self.bedrockBound = false
    self._tgAccrualRegistered = false
    self.lastProcessedDay = nil   -- SF day-tracking fallback
    return self
end

-- =========================================================
-- Batch lifecycle
-- =========================================================

-- Start a compost batch. feedstocks: { [fillTypeName] = litres }. The batch is
-- organic-safe when every feedstock is in the approved family; a biosolids-fed
-- batch is a valid soil amendment but not organic-cert-safe.
-- Returns the batchId, or nil + a reason.
function CompostManager:startBatch(farmId, feedstocks)
    if not self:_isServer() then return nil, "server_only" end
    if type(feedstocks) ~= "table" then return nil, "no_feedstocks" end

    local totalIn, organicSafe = 0, true
    local have = false
    for fillTypeName, litres in pairs(feedstocks) do
        if type(litres) == "number" and litres > 0 then
            have = true
            totalIn = totalIn + litres
            if not CompostManager.ORGANIC_SAFE[fillTypeName] then
                organicSafe = false
            end
        end
    end
    if not have or totalIn <= 0 then return nil, "no_feedstocks" end

    -- Finished output: the feedstock-weighted yield of finished COMPOST.
    local output = 0
    for fillTypeName, litres in pairs(feedstocks) do
        if type(litres) == "number" and litres > 0 then
            output = output + litres * (CompostManager.FEEDSTOCK_YIELD[fillTypeName] or 0)
        end
    end
    output = math.max(1, math.floor(output))

    local difficulty = self:_difficulty()
    local days = CompostManager.BATCH_DAYS[difficulty] or 14

    local batchId = self.nextBatchId
    self.nextBatchId = self.nextBatchId + 1
    self.batches[batchId] = {
        batchId = batchId, farmId = farmId,
        feedstocks = feedstocks, organicSafe = organicSafe,
        totalDays = days, daysRemaining = days, outputLitres = output,
        ready = false,
    }
    self:_markDirty()
    self:_ensureAccrual()
    return batchId, "ok"
end

-- One in-game day of decomposition. Called by the Time Guard accrual onSettle
-- (server-only), or the SF day-tracking fallback.
function CompostManager:tickDay(days)
    days = math.max(1, math.floor(days or 1))
    for _, b in pairs(self.batches) do
        if not b.ready then
            b.daysRemaining = b.daysRemaining - days
            if b.daysRemaining <= 0 then
                b.daysRemaining = 0
                b.ready = true
            end
        end
    end
    self:_markDirty()
end

-- Collect a finished batch: deposit the COMPOST into the farm's compatible
-- storage and clear the batch. Returns the deposited litres.
function CompostManager:collectBatch(batchId)
    local b = self.batches[batchId]
    if b == nil then return nil, "no_batch" end
    if not b.ready then return nil, "not_ready" end
    if not self:_isServer() then return nil, "server_only" end

    local deposited = self:_depositCompost(b.farmId, b.outputLitres)
    self.batches[batchId] = nil
    self:_markDirty()
    return deposited, (deposited > 0) and "ok" or "no_storage"
end

function CompostManager:collectAllForFarm(farmId)
    local done = 0
    for batchId, b in pairs(self.batches) do
        if b.farmId == farmId and b.ready then
            local n, _ = self:collectBatch(batchId)
            if n and n > 0 then done = done + 1 end
        end
    end
    return done
end

-- Deposit finished COMPOST into the farm's compatible storage. The no-placeable
-- process writes through the storage system: any storage owned by the farm that
-- supports COMPOST gets the fill level added. Returns the deposited litres.
function CompostManager:_depositCompost(farmId, litres)
    local deposited = 0
    local ftm = g_fillTypeManager
    local ftIndex = ftm ~= nil and ftm:getFillTypeIndexByName("COMPOST") or 0
    if ftIndex == 0 then return 0 end

    pcall(function()
        local ss = g_currentMission ~= nil and g_currentMission.storageSystem
        if ss == nil or ss.getStorages == nil then return end
        local remaining = litres
        for _, storage in ipairs(ss:getStorages() or {}) do
            if remaining <= 0 then break end
            if storage.getOwnerFarmId == nil then
                -- pass
            elseif storage:getOwnerFarmId() == farmId
                and storage.getFillUnitCapacity ~= nil then
                local cap = storage:getFillUnitCapacity(ftIndex)
                if cap and cap > 0 then
                    local cur = 0
                    if storage.getFillLevel ~= nil then
                        local ok, lvl = pcall(function() return storage:getFillLevel(ftIndex) end)
                        if ok and type(lvl) == "number" then cur = lvl end
                    end
                    local room = cap - cur
                    if room > 0 then
                        local add = math.min(remaining, room)
                        if storage.addFillLevelFromTool ~= nil then
                            storage:addFillLevelFromTool(farmId, add, ftIndex, nil, ToolType.UNDEFINED)
                        elseif storage.setFillLevel ~= nil then
                            storage:setFillLevel(cur + add, ftIndex)
                        else
                            add = 0
                        end
                        deposited = deposited + add
                        remaining = remaining - add
                    end
                end
            end
        end
    end)
    return deposited
end

-- =========================================================
-- Accrual (Time Guard day tick; SF fallback when absent)
-- =========================================================

function CompostManager:_ensureAccrual()
    if self._tgAccrualRegistered then return end
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.registerAccrual) ~= "function" then return end
    local ok = pcall(function()
        tg:registerAccrual(CompostManager.ACCURAL_ID, {
            cadence = "day",
            flowClass = "simulation",
            firstPeriodPolicy = "skip",
            priority = CompostManager.ACCURAL_PRIORITY,
            onSettle = function(ctx)
                local days = (ctx ~= nil and ctx.boundariesCrossed) or 1
                if g_currentMission ~= nil and g_currentMission:getIsServer() then
                    self:tickDay(days)
                end
            end,
        })
    end)
    if ok then self._tgAccrualRegistered = true end
end

-- SF day-tracking fallback (Time Guard absent): the manager is advanced from the
-- mission update on a monotonic-day change, exactly the SF-18 fallback shape.
function CompostManager:updateDayFallback()
    if self._tgAccrualRegistered then return end
    local env = g_currentMission ~= nil and g_currentMission.environment
    local day = env ~= nil and (env.currentMonotonicDay or env.currentDay) or nil
    if day == nil or day == self.lastProcessedDay then return end
    local skipped = (self.lastProcessedDay ~= nil) and (day - self.lastProcessedDay) or 1
    self.lastProcessedDay = day
    if self:_isServer() and skipped > 0 then
        self:tickDay(skipped)
    end
end

-- =========================================================
-- Persistence
-- =========================================================

function CompostManager:_isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function CompostManager:_difficulty()
    local d
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        d = g_SoilFertilityManager.settings.difficulty
    end
    if type(d) ~= "number" or d < 1 or d > 3 then d = 2 end
    return d
end

function CompostManager:serialize()
    local out = {}
    for id, b in pairs(self.batches) do
        out[tostring(id)] = {
            farmId = b.farmId, feedstocks = b.feedstocks, organicSafe = b.organicSafe,
            totalDays = b.totalDays, daysRemaining = b.daysRemaining,
            outputLitres = b.outputLitres, ready = b.ready,
        }
    end
    out._nextId = self.nextBatchId
    return out
end

function CompostManager:deserialize(data)
    if type(data) ~= "table" then return end
    self.nextBatchId = data._nextId or self.nextBatchId
    for key, s in pairs(data) do
        if key ~= "_nextId" then
            local id = tonumber(key) or key
            self.batches[id] = {
                batchId = id, farmId = s.farmId, feedstocks = s.feedstocks or {},
                organicSafe = s.organicSafe ~= false, totalDays = s.totalDays or 14,
                daysRemaining = s.daysRemaining or 0, outputLitres = s.outputLitres or 0,
                ready = s.ready == true,
            }
            if tonumber(id) and self.nextBatchId <= id then self.nextBatchId = id + 1 end
        end
    end
end

function CompostManager:_markDirty()
    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger ~= nil and ledger.markDirty ~= nil then
        pcall(function() ledger:markDirty(CompostManager.LEDGER_BATCHES) end)
    end
end

-- =========================================================
-- Console / read
-- =========================================================

function CompostManager:getBatchRows(farmId)
    local rows = {}
    for _, b in pairs(self.batches) do
        if farmId == nil or b.farmId == farmId then
            rows[#rows + 1] = {
                batchId = b.batchId, farmId = b.farmId, organicSafe = b.organicSafe,
                totalDays = b.totalDays, daysRemaining = b.daysRemaining,
                outputLitres = b.outputLitres, ready = b.ready,
            }
        end
    end
    return rows
end

function CompostManager:consoleStatus()
    local lines = {}
    local n = 0
    for _, b in pairs(self.batches) do n = n + 1 end
    table.insert(lines, string.format("Compost batches: %d", n))
    for _, b in pairs(self.batches) do
        table.insert(lines, string.format("  batch %d farm %d: %s, %d/%d days, %d L %s",
            b.batchId, b.farmId, b.organicSafe and "organic-safe" or "not organic-safe",
            b.totalDays - b.daysRemaining, b.totalDays, b.outputLitres,
            b.ready and "READY" or "decomposing"))
    end
    return table.concat(lines, "\n")
end
