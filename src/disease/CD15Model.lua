-- =========================================================
-- FS25 Soil & Fertilizer - CD-15 local disease: the server model (step 1a)
-- =========================================================
-- Owns the sparse grid (CD15Grid), the day clock and the daily local pass (CD15Day)
-- on the server, beside the old field model, which keeps running until step 2
-- removes it (brief :224, :233). Step 1a writes ONLY its own grid: no field scalar,
-- display map, packet, save field or player text.
--
-- WHERE IT RUNS. SoilFertilitySystem creates it with the value maps in its
-- constructor, calls onDayChanged from the existing daily settlement
-- (onEnvironmentUpdate's new-day branch) and update from its update(dt); both return
-- at once where g_server is nil, so a client holds an idle model. Each logical day d:
--   1. at the settlement: read the CD-15 day (CD15Day.readDay). A day skipped since the
--      last one has no captured input, so it closes UNAVAILABLE with its range recorded
--      and changes nothing (brief :107); d's own input is captured once;
--   2. SETTLE: every stored cell, in store order, through d (CD15Day.settleCell);
--   3. SPREAD: the source snapshot taken after SETTLE, one hop per source
--      (CD15Day.spreadFrom), so a cell infected this pass is never a source.
-- Both phases share ONE work bound of 256 cells or sources per server update (brief
-- :127), a work count, not an FPS claim; a day not finished in one update resumes on
-- the next, and a cell already settled through d is not settled again.
--
-- GEOMETRY. The grid binds to Soil's value maps and the native default fruit plane's
-- size (CD15Grid.resolveGeometry). Until both exist the model is UNAVAILABLE with its
-- reason and does no day work; it never guesses a grid.
--
-- FIRST ACTIVATION AND RESTORE (step 1b). The save participant (CD15Save) holds the
-- model in RESTORING from its install until the restore decides, and no day's work runs
-- meanwhile. The decision is one of: RESTORED (a saved attempt's cells, day work and
-- occurrence sequence, minting nothing), FIRST_ACTIVATION (no earlier CD-15 evidence:
-- the ratified clean baseline with earlier history explicitly unavailable, brief :97),
-- or QUARANTINED (evidence that did not form one valid attempt, :101): no day work, and
-- the saves keep the quarantine. A model no participant holds (a client, or the 1a
-- bench) runs as 1a did. Cells are allocated by admission (1c) and the native writers
-- (step 2); until those exist the grid stays empty in production.
--
-- A SEAM THAT THREW (#1062's MINOR 1): SoilFertilitySystem calls onDayChanged and update
-- under pcall; a raise marks the model UNAVAILABLE with its reason (fail), logged once,
-- and the field pass runs on.
--
-- NOT HERE: the settle-before-mutation entry (:133) arrives with step 2's writers,
-- which are its only callers; candidate discovery and the native witness are 1c.
-- =========================================================

CD15Model = CD15Model or {}
local M = CD15Model
local M_mt = { __index = M }

M.WORK_BOUND = 256
M.BASELINE_CLEAN = "CLEAN_FIRST_ACTIVATION"
M.BASELINE_RESTORED = "RESTORED_ATTEMPT"
M.GAPS_KEPT = 64
-- The restore states (step 1b). nil: no save participant holds this model.
M.RESTORING, M.RESTORED, M.FIRST_ACTIVATION, M.QUARANTINED = "RESTORING", "RESTORED", "FIRST_ACTIVATION", "QUARANTINED"

local function log(msg)
    if SoilLogger ~= nil and type(SoilLogger.info) == "function" then
        SoilLogger.info("[CD15] %s", msg)
    else
        print("[CD15] " .. msg)
    end
end

function M.new(system)
    local self = setmetatable({}, M_mt)
    self.system = system
    self.store = CD15Grid.newStore()
    self.geometry = nil
    self.state, self.reason = "PENDING", "GEOMETRY_PENDING"
    self.baseline = M.BASELINE_CLEAN
    self.historyAvailable = false
    self.lastDay = nil
    self.dayReason, self.daySource = nil, nil
    self.queue = {}          -- captured logical days, oldest first
    self.gaps = {}           -- { from, to, reason }: day ranges closed UNAVAILABLE
    self.lastClosedDay = nil
    self.stats = { settled = 0, spreadPairs = 0, maxWork = 0 }
    self.restoreState = nil  -- step 1b: set by the save participant (awaitRestore)
    self.quarantineReason = nil
    self.failed = nil        -- the seam that threw, once
    self.occurrenceSeq = 0   -- the mission/save occurrence sequence 1c allocates from (:85)
    self.discoveryCursor = 0 -- 1c's discovery cursor, saved as an explicit start value (:220)
    return self
end

-- ---------------------------------------------------------
-- Restore (step 1b)
-- ---------------------------------------------------------
--- The save participant holds the model until the restore decides.
function M:awaitRestore()
    self.restoreState = M.RESTORING
end

--- Is day work held? While RESTORING or QUARANTINED, and after a seam threw.
function M:isHeld()
    if self.failed ~= nil then return true end
    local rs = self.restoreState
    return rs ~= nil and rs ~= M.RESTORED and rs ~= M.FIRST_ACTIVATION
end

--- No earlier CD-15 evidence: the ratified clean baseline (:97).
function M:firstActivation()
    self.restoreState = M.FIRST_ACTIVATION
    self.baseline = M.BASELINE_CLEAN
    self.historyAvailable = false
end

--- Evidence that did not form one valid attempt: no day work, nothing reinitialized (:101).
function M:quarantine(reason)
    self.restoreState = M.QUARANTINED
    self.quarantineReason = reason
    self.queue = {}
end

--- A validated saved attempt (CD15Save.decodePayload): the cells, the day work and the
--- occurrence sequence, exactly as saved. Nothing is minted.
function M:importSaved(d)
    self.store = d.store
    self.lastDay, self.lastClosedDay = d.lastDay, d.lastClosedDay
    self.gaps = d.gaps
    self.queue = {}
    for i, w in ipairs(d.queue) do
        -- A SETTLE day restarts its cursor: a cell already settled through the day is skipped
        -- (settleEntry), so the day still finishes exactly once.
        self.queue[i] = { phase = w.phase, input = w.input, sources = w.sources, scursor = w.scursor }
    end
    self.occurrenceSeq, self.discoveryCursor = d.occurrenceSeq, d.discoveryCursor
    self.baseline = M.BASELINE_RESTORED
    self.historyAvailable = true
    self.restoreState = M.RESTORED
end

--- The day-work state the payload carries (:218): plain copies.
function M:exportWork()
    local gaps, queue = {}, {}
    for i, g in ipairs(self.gaps) do gaps[i] = { from = g.from, to = g.to, reason = g.reason } end
    for i, w in ipairs(self.queue) do
        local input = {}
        for k, v in pairs(w.input) do input[k] = v end
        local item = { phase = w.phase, input = input }
        if w.phase == "SPREAD" then
            item.scursor = w.scursor
            item.sources = {}
            for j, src in ipairs(w.sources or {}) do
                local res = {}
                for k, v in pairs(src.resistance or {}) do res[k] = v end
                item.sources[j] = { gx = src.gx, gz = src.gz, diseaseName = src.diseaseName, resistance = res }
            end
        end
        queue[i] = item
    end
    return { lastDay = self.lastDay, lastClosedDay = self.lastClosedDay, gaps = gaps, queue = queue,
             occurrenceSeq = self.occurrenceSeq, discoveryCursor = self.discoveryCursor }
end

--- A seam threw (#1062's MINOR 1): UNAVAILABLE with its reason, logged once.
function M:fail(where, err)
    if self.failed ~= nil then return end
    self.failed = tostring(where)
    self.state, self.reason = "UNAVAILABLE", "SEAM_ERROR:" .. tostring(where)
    if SoilLogger ~= nil and type(SoilLogger.warning) == "function" then
        SoilLogger.warning("[CD15] %s raised (%s); local disease is unavailable for this session, the field pass runs on", tostring(where), tostring(err))
    end
end

-- ---------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------
local function nativeMapSize()
    if getDensityMapSize == nil or g_fruitTypeManager == nil or type(g_fruitTypeManager.getDefaultDataPlaneId) ~= "function" then return nil end
    local okP, plane = pcall(g_fruitTypeManager.getDefaultDataPlaneId, g_fruitTypeManager)
    if not okP or plane == nil then return nil end
    local okS, size = pcall(getDensityMapSize, plane)
    return okS and size or nil
end

function M:ensureGeometry()
    if self.geometry ~= nil then return true end
    local geom, why = CD15Grid.resolveGeometry(self.system ~= nil and self.system.valueMaps or nil, nativeMapSize())
    if geom == nil then
        self.state, self.reason = "UNAVAILABLE", why
        return false
    end
    self.geometry = geom
    self.state, self.reason = "READY", nil
    log(string.format("local disease grid ready: %s (%.3f m cells, %s; earlier history unavailable)", geom.fingerprint, geom.cellSize, self.baseline))
    return true
end

-- ---------------------------------------------------------
-- The daily settlement
-- ---------------------------------------------------------
local function addGap(self, from, to, reason)
    self.gaps[#self.gaps + 1] = { from = from, to = to, reason = reason }
    while #self.gaps > M.GAPS_KEPT do table.remove(self.gaps, 1) end
end

--- Called from the existing server daily settlement.
function M:onDayChanged()
    if g_server == nil then return end
    if self:isHeld() then return end
    if not self:ensureGeometry() then return end
    local day, why, source = CD15Day.readDay(self.lastDay)
    self.daySource = source
    if day == nil then
        self.dayReason = why
        return
    end
    self.dayReason = nil
    if self.lastDay ~= nil and day == self.lastDay then return end
    if self.lastDay ~= nil and day > self.lastDay + 1 then addGap(self, self.lastDay + 1, day - 1, "NO_CAPTURED_INPUT") end
    self.lastDay = day
    local input, whyInput = CD15Day.captureInput(self.system, day)
    if input == nil then
        addGap(self, day, day, whyInput)
        return
    end
    self.queue[#self.queue + 1] = { input = input, phase = "SETTLE" }
end

--- The bounded cursor: at most WORK_BOUND cells or sources per call.
function M:update(dt)
    if g_server == nil or #self.queue == 0 then return end
    if self:isHeld() then return end
    local budget, work = M.WORK_BOUND, 0
    while budget > 0 and #self.queue > 0 do
        local w = self.queue[1]
        if w.phase == "SETTLE" then
            if w.cells == nil then w.cells, w.cursor = self.store:orderedCells(), 1 end
            while budget > 0 and w.cursor <= #w.cells do
                local e = w.cells[w.cursor]
                w.cursor = w.cursor + 1
                budget, work = budget - 1, work + 1
                self:settleEntry(e, w.input)
            end
            if w.cursor > #w.cells then
                w.phase, w.sources, w.scursor = "SPREAD", CD15Day.snapshotSources(self.store, w.input.day), 1
            end
        else
            local input = w.input
            local admits = function(dest, gx, gz, name) return self:admits(dest, gx, gz, name, input) end
            while budget > 0 and w.scursor <= #w.sources do
                local s = w.sources[w.scursor]
                w.scursor = w.scursor + 1
                budget, work = budget - 1, work + 1
                self.stats.spreadPairs = self.stats.spreadPairs + CD15Day.spreadFrom(self.store, s, admits)
            end
            if w.scursor > #w.sources then
                table.remove(self.queue, 1)
                self.lastClosedDay = input.day
            end
        end
    end
    if work > self.stats.maxWork then self.stats.maxWork = work end
end

function M:settleEntry(e, input)
    local c = self.store:get(e.gx, e.gz)
    if c == nil then return false end
    if c.lastSettledDay ~= nil and c.lastSettledDay >= input.day then return false end
    CD15Day.settleCell(c, e.gx, e.gz, input, self:cellInputs(e.gx, e.gz))
    self.stats.settled = self.stats.settled + 1
    return true
end

-- ---------------------------------------------------------
-- A cell's local facts
-- ---------------------------------------------------------
--- The cell's field, its FieldSentry state, and its own soil pH/N/OM from the value
--- maps (a missing component stays missing).
function M:cellInputs(gx, gz)
    local x, z = CD15Grid.cellCentre(self.geometry, gx, gz)
    local ci = { soil = {}, meadow = false, disabled = false, fieldId = nil, x = x, z = z }
    local hm = self.system ~= nil and self.system.hookManager or nil
    if hm ~= nil and type(hm.getFieldIdAtWorldPosition) == "function" then
        local ok, fid = pcall(hm.getFieldIdAtWorldPosition, hm, x, z, false)
        if ok then ci.fieldId = fid end
    end
    if ci.fieldId ~= nil and FieldSentry_API ~= nil and type(FieldSentry_API.isFieldSimDisabled) == "function" then
        local ok, disabled, _, meadow = pcall(FieldSentry_API.isFieldSimDisabled, ci.fieldId)
        if ok then ci.disabled, ci.meadow = disabled == true, meadow == true end
    end
    local vm = self.system ~= nil and self.system.valueMaps or nil
    if vm ~= nil and vm.available == true and type(vm.readValueAtWorld) == "function" then
        for _, key in ipairs({ "pH", "nitrogen", "organicMatter" }) do
            local ok, v = pcall(vm.readValueAtWorld, vm, key, x, z)
            if ok and CD15Grid.isFinite(v) then ci.soil[key] = v end
        end
    end
    return ci
end

--- SCS's positional moisture store, as EstablishmentFailure reaches it (:193-199).
local function moistureSource()
    local cs = (g_currentMission ~= nil and g_currentMission.cropStressManager) or (getfenv ~= nil and getfenv(0) ~= nil and getfenv(0).g_cropStressManager) or nil
    if cs ~= nil and type(cs.getMoisture) == "function" then return cs end
    return nil
end

--- Wet or conducive (brief :124): SCS positional moisture >= .75 when the provider
--- returns a real grain no coarser than this cell; otherwise the day's weather wet
--- flag, the stated neutral input. Returns (wet, source).
function M:wetAt(ci, input)
    local cs = moistureSource()
    if cs ~= nil and ci.fieldId ~= nil then
        local ok, m, grain = pcall(cs.getMoisture, cs, ci.fieldId, ci.x, ci.z)
        if ok and CD15Grid.isFinite(m) and m >= 0 and m <= 1 and CD15Grid.isFinite(grain) and grain > 0 and grain <= self.geometry.cellSize then
            return m >= CD15Day.WET_MOISTURE, "SCS"
        end
    end
    return input.isWet == true, "WEATHER"
end

--- May this destination receive this source's disease today?
function M:admits(dest, gx, gz, diseaseName, input)
    if dest.cropName == nil then return false end
    if CD15Day.isProtected(dest, input.day) then return false end
    if not CD15Day.cropCompatible(diseaseName, dest.cropName) then return false end
    local ci = self:cellInputs(gx, gz)
    if ci.disabled or ci.meadow then return false end
    return (self:wetAt(ci, input))
end

-- ---------------------------------------------------------
-- Status and teardown
-- ---------------------------------------------------------
function M:getStatus()
    return {
        state = self.state, reason = self.reason, baseline = self.baseline, historyAvailable = self.historyAvailable,
        fingerprint = self.geometry ~= nil and self.geometry.fingerprint or nil, cells = self.store.count,
        lastDay = self.lastDay, dayReason = self.dayReason, daySource = self.daySource,
        pendingDays = #self.queue, gaps = #self.gaps, lastClosedDay = self.lastClosedDay,
        settled = self.stats.settled, spreadPairs = self.stats.spreadPairs, maxWork = self.stats.maxWork,
        restoreState = self.restoreState, quarantineReason = self.quarantineReason, failed = self.failed,
        occurrenceSeq = self.occurrenceSeq,
    }
end

function M:delete()
    self.queue = {}
    self.store = CD15Grid.newStore()
    self.geometry = nil
    self.state, self.reason = "UNAVAILABLE", "DELETED"
end
