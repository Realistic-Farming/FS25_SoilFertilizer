-- ============================================================
-- GrowthCredit.lua  (SF-53)
--
-- THE REWARD HALF OF THE SF-2M MODULATION FAMILY. A patch of
-- ground held in excellent condition long enough ripens one growth
-- step ahead of the field's own clock, on the real crop, in patches
-- at the survey's grain.
--
-- TWO CLOCKS, ONE STORE.
--   The bookkeeper (daily): a Time Guard accrual that counts, per
--   surveyed cell, days of excellence. It never touches the fruit
--   plane.
--   The hand (per growth period): inside the FINISHED_GROWTH_PERIOD
--   handler, on the drained delivery only, it advances every cell
--   whose credit crossed the threshold, by buckets, one filtered
--   executeSet per bucket.
--   The store: per-field, server-only, ephemeral (never saved),
--   keyed by the survey's own adaptive lattice.
--
-- ENGINE-TRUE WRITE, PER THE RATIFIED FAMILY RULING (2026-08-12):
-- bucket-and-set on the engine's own fruit plane at the drained
-- FINISHED_GROWTH_PERIOD bracket with hasPendingGrowth false, 8 m
-- grain, skip-at-own-cutState, never into cut/withered/max, advance
-- by one. DensityMapMultiModifier batching is sanctioned.
-- ============================================================

GrowthCredit = {}
local GrowthCredit_mt = Class(GrowthCredit)

-- Time Guard accrual. Priority 97 lands one behind the foundation's 96
-- (ViabilityMask), so the ground has settled and the dead have been counted
-- before anyone earns a reward.
GrowthCredit.DAILY_ACCURAL_ID       = 'SF53_growthCredit'
GrowthCredit.DAILY_ACCURAL_PRIORITY = 97

-- The credit threshold in growth periods. Neutral until the Option-Scaling
-- Spine resolves the Agronomy dial (the SpatialNutrients vendored-read
-- pattern; neutral 1.0 when the resolver handle is absent).
GrowthCredit.THRESHOLD_PERIODS_DEFAULT = 2
GrowthCredit.SPINE_DIAL = "agronomy"

function GrowthCredit.new(manager)
    local self = setmetatable({}, GrowthCredit_mt)
    self.manager = manager
    self.isInitialized = false
    self._tgAccrualRegistered = false
    self._messageSubscribed = false
    self._daysPerPeriod = 1
    -- fieldId -> { originX, originZ, step, maxX, maxZ,
    --              cells = { [gx] = { [gz] = { credit, fruitIndex } } } }
    self._store = {}
    return self
end

function GrowthCredit:initialize()
    self.isInitialized = true
end

function GrowthCredit:delete()
    self.isInitialized = false
    if self._messageSubscribed then
        local mc = g_messageCenter
        if mc and type(mc.unsubscribe) == 'function' then
            pcall(function() mc:unsubscribe(MessageType.FINISHED_GROWTH_PERIOD, self) end)
        end
        self._messageSubscribed = false
    end
    self._store = {}
end

-- ============================================================
-- THE INPUTS (read-only access to the family's own data)
-- ============================================================

function GrowthCredit:_viability()
    local v = self.manager and self.manager.viability
    if v ~= nil and type(v.getCellGrowthInfo) == 'function' then return v end
    return nil
end

function GrowthCredit:_soilSystem()
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and type(ss._getFieldPolyVerts) == 'function' then return ss end
    return nil
end

function GrowthCredit:_valueMaps()
    local soilSystem = self.manager and self.manager.soilSystem
    local vm = soilSystem and soilSystem.valueMaps
    if vm ~= nil and vm.available then return vm end
    return nil
end

-- ============================================================
-- THE LATTICE
-- Re-derive the survey's own adaptive grid exactly as ViabilityMask
-- does, reading BOTH constants off ViabilityMask at runtime, never
-- copied literals. originX/originZ are the walk's FIRST SAMPLE
-- CENTRES (min + step * 0.5), so a sample always lands at its own
-- cell's centre. gx = floor((x - originX) / step), likewise gz.
-- If a field's re-derived (origin, step) differs from the stored
-- header, reset that field's store (ephemeral trade: a delayed
-- reward).
-- ============================================================

---@param fieldId number
---@param verts table list of {x=, z=}
---@return table header { originX, originZ, step, maxX, maxZ }
function GrowthCredit:_deriveHeader(fieldId, verts)
    local vm = ViabilityMask
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        local v = verts[i]
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end

    local step = vm.SAMPLE_STEP_M
    local est = math.ceil((maxX - minX) / step) * math.ceil((maxZ - minZ) / step)
    if est > vm.MAX_SAMPLES then
        step = step * math.ceil(math.sqrt(est / vm.MAX_SAMPLES))
    end

    return {
        originX = minX + step * 0.5,
        originZ = minZ + step * 0.5,
        step    = step,
        maxX    = maxX,
        maxZ    = maxZ,
    }
end

--- Ensure a field has a store entry matching the current lattice header.
---@param fieldId number
---@param header table
function GrowthCredit:_ensureStore(fieldId, header)
    local entry = self._store[fieldId]
    if entry == nil
        or entry.originX ~= header.originX
        or entry.originZ ~= header.originZ
        or entry.step    ~= header.step then
        self._store[fieldId] = {
            originX = header.originX,
            originZ = header.originZ,
            step    = header.step,
            maxX    = header.maxX,
            maxZ    = header.maxZ,
            cells   = {},
        }
    end
    return self._store[fieldId]
end

--- World x/z of a lattice cell's centre.
function GrowthCredit:_cellCentre(entry, gx, gz)
    return entry.originX + gx * entry.step, entry.originZ + gz * entry.step
end

--- Cell index at a world position, or nil when outside the stored header's box.
function GrowthCredit:_cellIndex(entry, x, z)
    if x < entry.originX - entry.step * 0.5 or x > entry.maxX + entry.step * 0.5 then return nil end
    if z < entry.originZ - entry.step * 0.5 or z > entry.maxZ + entry.step * 0.5 then return nil end
    return math.floor((x - entry.originX) / entry.step), math.floor((z - entry.originZ) / entry.step)
end

-- ============================================================
-- THE PUBLISHED READ (ViabilityMask._readCredit's socket)
-- ============================================================

--- Days of credit at a world position, via the stored header's own lattice.
--- nil when the field is not tracked, the store was reset (a lattice re-derive
--- that does not match), or the cell has never accrued. This is the neutral
--- reading every consumer expects: nil, never zero.
function GrowthCredit:readCreditAt(fieldId, x, z)
    if not self.isInitialized then return nil end
    local entry = self._store[fieldId]
    if entry == nil then return nil end
    local gx, gz = self:_cellIndex(entry, x, z)
    if gx == nil then return nil end
    local row = entry.cells[gx]
    local cell = row and row[gz]
    if cell == nil then return nil end
    return cell.credit
end

-- ============================================================
-- THE DAILY PASS (the bookkeeper)
-- ============================================================

-- The excellence test per the brief's two presets. The preset accessor's
-- mapping (which index is easiest) is verified at build, not assumed:
-- SoilConstants.DIFFICULTY.EASY = 1 is the easiest on SF's own scale, so
-- Casual = EASY. Everything else uses the realistic quorum.
--   casual:   the shipped composer's own rule (at least one band excellent,
--             none blocked; combine's semantics).
--   realistic: at least TWO bands must vote (non-nil) and EVERY voter must
--             be excellent. A nil band does not vote; a partially unreadable
--             cell earns nothing that day.
---@param bands table { n = band, compaction = band, moisture = band }
---@param casual boolean
---@return boolean
function GrowthCredit.isExcellent(bands, casual)
    if bands == nil then return false end
    if casual then
        return ViabilityMask.combine(bands) == ViabilityMask.BAND_EXCELLENT
    end
    local voters, allExcellent = 0, true
    for _, b in pairs(bands) do
        if b ~= nil then
            voters = voters + 1
            if b ~= ViabilityMask.BAND_EXCELLENT then allExcellent = false end
        end
    end
    return voters >= 2 and allExcellent
end

function GrowthCredit:_isCasualPreset()
    local s = self.manager and self.manager.settings
    if s == nil or s.difficulty == nil then return false end
    local easy = SoilConstants and SoilConstants.DIFFICULTY and SoilConstants.DIFFICULTY.EASY
    return easy ~= nil and s.difficulty == easy
end

--- The credit threshold in days: thresholdPeriods * daysPerPeriod. The
--- Agronomy dial scales the period count (base * curve, neutral 1.0).
function GrowthCredit:_thresholdDays()
    local periods = GrowthCredit.THRESHOLD_PERIODS_DEFAULT * self:_agronomyMult()
    periods = math.max(1, math.floor(periods + 0.5))
    return periods * self._daysPerPeriod
end

--- The spine Agronomy multiplier, neutral 1.0 when the resolver handle is
--- absent. The vendored-read pattern SpatialNutrients ships (SpatialNutrients.lua
--- severityMult); a nil or non-number value degrades to neutral.
function GrowthCredit:_agronomyMult()
    if self._agronomyMultCached ~= nil then return self._agronomyMultCached end
    local mult = 1.0
    local ok, resolver = pcall(function()
        return (g_currentMission and g_currentMission.optionScalingResolver)
            or getfenv(0)["g_OptionScalingResolver"]
    end)
    if ok and resolver and type(resolver.value) == "function" then
        local ok2, v = pcall(resolver.value, resolver, GrowthCredit.SPINE_DIAL)
        if ok2 and type(v) == "number" and v >= 0 then mult = v end
    end
    self._agronomyMultCached = mult
    return mult
end

--- One daily settle. Walks each field's survey lattice; every cell whose
--- bands pass the excellence test accrues one day of TOTAL credit. Never
--- touches the fruit plane.
function GrowthCredit:runDailyPass(_ctx)
    if self._tgAccrualRegistered and _ctx ~= nil and type(_ctx) == "table" then
        self._daysPerPeriod = (type(_ctx.daysPerPeriod) == "number" and _ctx.daysPerPeriod >= 1)
            and _ctx.daysPerPeriod or 1
    end
    if not self.isInitialized then return 0 end
    local vm = self:_viability()
    local ss = self:_soilSystem()
    if vm == nil or ss == nil then return 0 end
    if not self:isLive() then return 0 end

    local passed = 0
    for fieldId in pairs(ss.fieldData) do
        local field = ss.fieldData and ss.fieldData[fieldId]
        if field ~= nil then
            local verts = ss:_getFieldPolyVerts(fieldId, field)
            if verts ~= nil and #verts >= 3 then
                if self:_accrueField(fieldId, verts, vm) then passed = passed + 1 end
            end
        end
    end
    return passed
end

function GrowthCredit:_accrueField(fieldId, verts, vm)
    local header = self:_deriveHeader(fieldId, verts)
    local entry  = self:_ensureStore(fieldId, header)
    local casual = self:_isCasualPreset()
    local threshold = self:_thresholdDays()

    local x = header.originX
    local gx = 0
    while x <= header.maxX do
        local z = header.originZ
        local gz = 0
        while z <= header.maxZ do
            local info = vm:getCellGrowthInfo(fieldId, x, z)
            if info ~= nil and GrowthCredit.isExcellent(info.bands, casual) then
                local row = entry.cells[gx]
                if row == nil then row = {}; entry.cells[gx] = row end
                local cell = row[gz]
                if cell == nil then cell = { credit = 0, fruitIndex = nil }; row[gz] = cell end
                cell.credit = cell.credit + 1
            end
            z = z + header.step
            gz = gz + 1
        end
        x = x + header.step
        gx = gx + 1
    end
    return true
end

-- ============================================================
-- THE PERIOD HAND (the bell)
-- ============================================================

--- The drained FINISHED_GROWTH_PERIOD delivery. Reads each eligible cell's
--- current state FRESH (no daily state caching), runs the guard chain, buckets
--- survivors by (fruitIndex, currentState, targetState), and strokes one
--- filtered executeSet per bucket on the fruit's own plane. On failure a cell
--- keeps its credit and retries at the next bell. On success the written credit
--- resets and the fruit index is stored for the orphan guard.
---@param finishedPeriod number
---@param hasPendingGrowth boolean
function GrowthCredit:onFinishedGrowthPeriod(finishedPeriod, hasPendingGrowth)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    if hasPendingGrowth ~= false then return end
    local growthMode = mission.missionInfo and mission.missionInfo.growthMode
    if growthMode == GrowthMode.DISABLED then return end

    local ss = self:_soilSystem()
    local vm = self:_viability()
    if ss == nil or vm == nil then return end

    for fieldId, entry in pairs(self._store) do
        self:_strokeField(fieldId, entry, vm, finishedPeriod)
    end
end

function GrowthCredit:_strokeField(fieldId, entry, vm, _finishedPeriod)
    local threshold = self:_thresholdDays()
    local eligible = {}
    for gx, row in pairs(entry.cells) do
        for gz, cell in pairs(row) do
            if cell.credit >= threshold then
                eligible[#eligible + 1] = { gx = gx, gz = gz, cell = cell }
            end
        end
    end
    if #eligible == 0 then return end

    -- Read current state fresh per cell, then run the guard chain.
    local candidates = {}
    for _, e in ipairs(eligible) do
        local x, z = self:_cellCentre(entry, e.gx, e.gz)
        local state, fruitIndex = self:_readCellState(x, z)
        if state ~= nil and fruitIndex ~= nil then
            if self:_guardCell(fieldId, fruitIndex, state, e.cell, entry, e.gx, e.gz, vm) then
                local target = self:_engineTarget(fruitIndex, state)
                if target ~= nil and target > state then
                    candidates[#candidates + 1] = {
                        gx = e.gx, gz = e.gz, cell = e.cell,
                        fruitIndex = fruitIndex, current = state, target = target,
                    }
                end
            end
        end
    end
    if #candidates == 0 then return end

    -- Bucket survivors by (fruitIndex, currentState, targetState).
    local buckets = {}
    for _, c in ipairs(candidates) do
        local key = c.fruitIndex .. "|" .. c.current .. "|" .. c.target
        local b = buckets[key]
        if b == nil then
            b = { fruitIndex = c.fruitIndex, current = c.current, target = c.target, cells = {} }
            buckets[key] = b
        end
        b.cells[#b.cells + 1] = { gx = c.gx, gz = c.gz }
    end

    local fruitDesc = nil
    for _, b in pairs(buckets) do
        fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(b.fruitIndex)
        if fruitDesc ~= nil and fruitDesc.terrainDataPlaneId ~= nil then
            if self:_strokeBucket(b, fruitDesc, entry) then
                -- Written: reset credit, store the fruit index.
                for _, c in ipairs(b.cells) do
                    local row = entry.cells[c.gx]
                    local cell = row and row[c.gz]
                    if cell then
                        cell.credit = 0
                        cell.fruitIndex = b.fruitIndex
                    end
                end
            end
            -- On failure the cells keep their credit and retry at the next bell.
        end
    end
end

-- The engine's per-cell get: FSDensityMapUtil.getFruitTypeIndexAtWorldPos
-- (FSDensityMapUtil.lua:2849) returns (fruitTypeIndex, growthState) in one
-- call - the point read that supplies both the orphan guard and the current
-- state. Confirmed at the decompile (E4).
function GrowthCredit:_readCellState(x, z)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= 'function' then
        return nil, nil
    end
    local ok, fruitIndex, state = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok or fruitIndex == nil or state == nil then return nil, nil end
    return state, fruitIndex
end

-- The guard chain, in order:
--   orphan: stored fruitIndex exists AND unchanged, AND not cut AND not
--           withered (the SET-based cut test is the load-bearing one; the
--           scalar cutState compare sits beside it as defense in depth),
--   never at or past maxHarvestingGrowthState,
--   never a blocked cell (one getCellGrowthInfo at the bell, on the real field).
function GrowthCredit:_guardCell(fieldId, fruitIndex, state, cell, entry, gx, gz, vm)
    if cell.fruitIndex ~= nil and cell.fruitIndex ~= fruitIndex then return false end
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return false end
    if fruitDesc:getIsCut(state) then return false end
    if fruitDesc:getIsWithered(state) then return false end
    if state == fruitDesc.cutState then return false end
    if state >= fruitDesc.maxHarvestingGrowthState then return false end

    local x, z = self:_cellCentre(entry, gx, gz)
    local info = vm:getCellGrowthInfo(fieldId, x, z)
    if info ~= nil and info.blocked then return false end
    return true
end

-- The ENGINE-TRUE next state. Upcoming period index = environment.currentPeriod
-- (the engine derives the FINISHING period as currentPeriod - 1 with a 0-to-12
-- wrap; the upcoming one is currentPeriod itself). Seasonal: periods[idx]
-- growthMapping[state]; daily: nonSeasonal growthMapping[state]. No data:
-- state + 1. A mapping that does not advance the state (identity, or target not
-- greater than current) returns nil so the cell keeps its credit and waits.
function GrowthCredit:_engineTarget(fruitIndex, state)
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return nil end
    local mission = g_currentMission
    local growthMode = mission and mission.missionInfo and mission.missionInfo.growthMode
    local idx = mission and mission.environment and mission.environment.currentPeriod
    if idx == nil then return nil end

    local target = nil
    if growthMode == GrowthMode.SEASONAL then
        local gd = fruitDesc:getSeasonalGrowthData()
        local p = gd and gd.periods and gd.periods[idx]
        if p ~= nil and p.growthMapping ~= nil then target = p.growthMapping[state] end
    elseif growthMode == GrowthMode.DAILY then
        local gd = fruitDesc:getNonSeasonalGrowthData()
        if gd ~= nil and gd.growthMapping ~= nil then target = gd.growthMapping[state] end
    end

    if target == nil then target = state + 1 end
    if type(target) ~= "number" or target <= state then return nil end
    return target
end

-- ============================================================
-- THE WRITE HAND
-- One polygon over the bucket's cells, filtered BETWEEN(current,
-- current) on the fruit's own channel pair, one executeSet(target,
-- filter). The grouping and ring machinery mirrors the shipped
-- substrate (EstablishmentFailure.lua:333-416), with cellSize and
-- origin fed from the STORED HEADER. DensityMapMultiModifier
-- batching is sanctioned; a plain per-bucket modifier loop is the
-- fallback. pcall per stroke; do NOT wrap in setIgnoreDensityChanges
-- (empty stub at GrowthSystem.lua:303).
-- ============================================================

function GrowthCredit:_strokeBucket(bucket, fruitDesc, entry)
    local ok, err = pcall(function()
        local rings = self:_bucketRings(bucket.cells, entry)
        if rings == nil or #rings == 0 then return end

        local modifier = DensityMapModifier.new(
            fruitDesc.terrainDataPlaneId, fruitDesc.startStateChannel, fruitDesc.numStateChannels, g_terrainNode)
        local filter = DensityMapFilter.new(modifier)
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, bucket.current, bucket.current)

        local multi = DensityMapMultiModifier.new()
        for _, ring in ipairs(rings) do
            if #ring >= 3 then
                modifier:clearPolygonPoints()
                for _, pt in ipairs(ring) do
                    modifier:addPolygonPointWorldCoords(pt.x, pt.z)
                end
                multi:addExecuteSet(bucket.target, modifier, filter)
            end
        end
        multi:execute()
    end)
    if not ok then
        SoilLogger.error("[SF-53] field growth credit write failed: %s", tostring(err))
    end
    return ok
end

-- Group a list of {gx=, gz=} cells into contiguous 4-connected regions, then
-- build each region's outline ring(s) in world space. Mirrors
-- EstablishmentFailure._groupRegions / _regionPolygon; ring points carry the
-- stored header's origin so the write lands on the survey's own cells.
function GrowthCredit:_bucketRings(cells, entry)
    local set = {}
    for _, c in ipairs(cells) do set[c.gx .. "," .. c.gz] = c end
    local regions = {}
    local visited = {}
    for _, c in ipairs(cells) do
        local key = c.gx .. "," .. c.gz
        if not visited[key] then
            local region = {}
            local queue = { c }
            visited[key] = true
            local head = 1
            while head <= #queue do
                local cur = queue[head]
                head = head + 1
                region[#region + 1] = cur
                for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
                    local nk = (cur.gx + d[1]) .. "," .. (cur.gz + d[2])
                    if set[nk] and not visited[nk] then
                        visited[nk] = true
                        queue[#queue + 1] = set[nk]
                    end
                end
            end
            regions[#regions + 1] = region
        end
    end

    local rings = {}
    local step = entry.step
    local originX, originZ = entry.originX, entry.originZ
    for _, region in ipairs(regions) do
        local rset = {}
        for _, c in ipairs(region) do rset[c.gx .. "," .. c.gz] = true end

        local function hasCell(nx, nz) return rset[nx .. "," .. nz] ~= nil end
        local function cornerKey(x, z) return x .. "," .. z end

        local nextEdge = {}
        for _, c in ipairs(region) do
            local gx, gz = c.gx, c.gz
            if not hasCell(gx, gz - 1) then nextEdge[cornerKey(gx, gz)] = cornerKey(gx + 1, gz) end
            if not hasCell(gx + 1, gz) then nextEdge[cornerKey(gx + 1, gz)] = cornerKey(gx + 1, gz + 1) end
            if not hasCell(gx, gz + 1) then nextEdge[cornerKey(gx + 1, gz + 1)] = cornerKey(gx, gz + 1) end
            if not hasCell(gx - 1, gz) then nextEdge[cornerKey(gx, gz + 1)] = cornerKey(gx, gz) end
        end

        local used = {}
        local keys = {}
        for k in pairs(nextEdge) do keys[#keys + 1] = k end
        for _, startKey in ipairs(keys) do
            if not used[startKey] then
                local ring = {}
                local k = startKey
                local steps = 0
                while k and not used[k] and steps <= 4096 do
                    used[k] = true
                    local x, z = k:match("^(-?%d+),(-?%d+)$")
                    if x then
                        ring[#ring + 1] = {
                            x = originX + (tonumber(x) - 0.5) * step,
                            z = originZ + (tonumber(z) - 0.5) * step,
                        }
                    end
                    k = nextEdge[k]
                    steps = steps + 1
                    if k == startKey then break end
                end
                if #ring >= 3 then rings[#rings + 1] = ring end
            end
        end
    end
    return rings
end

-- ============================================================
-- CADENCE + LIFECYCLE
-- ============================================================

--- Register the daily bookkeeper with Time Guard (simulation flow) and the
--- period bell with the message center. Server-only, by the write's nature.
--- Version-skew guard: an older Time Guard silently coerces an unknown
--- flowClass to calendar, so refuse rather than run on a clock the design
--- never meant. pcall both registrations; failures leave the module inert.
function GrowthCredit:register()
    if self._tgAccrualRegistered and self._messageSubscribed then return true end

    local ok = true
    if not self._tgAccrualRegistered then
        local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
        if tg ~= nil and type(tg.registerAccrual) == 'function' then
            if tg.flowClasses == nil or tg.flowClasses.simulation == true then
                local ok2 = pcall(function()
                    tg:registerAccrual(GrowthCredit.DAILY_ACCURAL_ID, {
                        cadence = 'day',
                        flowClass = 'simulation',
                        firstPeriodPolicy = 'skip',
                        priority = GrowthCredit.DAILY_ACCURAL_PRIORITY,
                        onSettle = function(ctx) self:runDailyPass(ctx) end,
                    })
                end)
                if ok2 then self._tgAccrualRegistered = true else ok = false end
            else
                ok = false
            end
        end
    end

    if ok and not self._messageSubscribed and g_messageCenter ~= nil
        and MessageType ~= nil and MessageType.FINISHED_GROWTH_PERIOD ~= nil
        and type(g_messageCenter.subscribe) == 'function' then
        local ok2 = pcall(function()
            g_messageCenter:subscribe(MessageType.FINISHED_GROWTH_PERIOD, self.onFinishedGrowthPeriod, self)
        end)
        if ok2 then self._messageSubscribed = true else ok = false end
    end
    return ok
end

--- The family's live gate: the release gate must be open AND the mask enabled.
--- FAIL-OPEN on the release gate (nil settings on the bench means live), but
--- the mask switch is a real toggle and gates hard.
function GrowthCredit:isLive()
    local vm = self:_viability()
    if vm ~= nil and vm.enabled == false then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == 'function' then
        return ReleaseGate.isSystemLive("growth_modulation")
    end
    return true
end
