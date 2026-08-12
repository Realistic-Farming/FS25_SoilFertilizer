-- ============================================================
-- GrowthBlock.lua  (SF-78)
--
-- THE HOLD HALF OF THE SF-2M MODULATION FAMILY. Ground SF-52
-- classifies BLOCKED does not keep the growth step the engine just
-- gave it: the cell is captured before the pass and put back after,
-- so the hollow that drains badly visibly falls behind the field.
--
-- CAPTURE at START_GROWTH_PERIOD, RESTORE at the drained
-- FINISHED_GROWTH_PERIOD delivery, through the family's one write
-- hand (bucket-and-set on the engine's own fruit plane, exactly the
-- machine SF-53's brief section 2d describes; self-contained here so
-- the two members can land in any order).
--
-- R2, THREE HALVES, ALL REQUIRED: fruit index unchanged; current
-- state NOT cut AND NOT withered (the SET tests; never getIsGrowing,
-- which is false on harvest-ready states); current state STRICTLY
-- ABOVE captured. Any half fails: abandon, write nothing.
--
-- THE CAPTURE CLEAR IS UNCONDITIONAL at every drained delivery,
-- writes or no writes, DISABLED included. growthMode is
-- runtime-settable; a surviving capture plus the write-once rule
-- would wedge the bracket forever. This is a cert assertion
-- (steward condition 2), not a comment.
-- ============================================================

GrowthBlock = {}
local GrowthBlock_mt = Class(GrowthBlock)

-- The restore cap: max growth steps held back per bracket. Default 1. Neutral
-- until the Option-Scaling Spine resolves the Agronomy dial (the family's ONE
-- grouped declaration; the vendored-read pattern, neutral 1.0 when absent).
GrowthBlock.RESTORE_CAP_DEFAULT = 1
GrowthBlock.SPINE_DIAL = "agronomy"

function GrowthBlock.new(manager)
    local self = setmetatable({}, GrowthBlock_mt)
    self.manager = manager
    self.isInitialized = false
    self._messageSubscribed = false
    -- Per-field capture, held across ONE bracket (seconds): fieldId -> list of
    -- { gx, gz, state, fruitIndex }. Never saved, never synced.
    self._capture = {}
    return self
end

function GrowthBlock:initialize()
    self.isInitialized = true
end

function GrowthBlock:delete()
    self.isInitialized = false
    if self._messageSubscribed then
        local mc = g_messageCenter
        if mc and type(mc.unsubscribe) == 'function' then
            pcall(function() mc:unsubscribe(MessageType.START_GROWTH_PERIOD, self) end)
            pcall(function() mc:unsubscribe(MessageType.FINISHED_GROWTH_PERIOD, self) end)
        end
        self._messageSubscribed = false
    end
    self._capture = {}
end

-- ============================================================
-- THE INPUTS (read-only access to the family's own data)
-- ============================================================

function GrowthBlock:_viability()
    local v = self.manager and self.manager.viability
    if v ~= nil and type(v.getCellGrowthInfo) == 'function' then return v end
    return nil
end

function GrowthBlock:_soilSystem()
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and type(ss._getFieldPolyVerts) == 'function' then return ss end
    return nil
end

-- ============================================================
-- THE LATTICE (identical to SF-53's store: the survey's own grid)
-- ============================================================

function GrowthBlock:_deriveHeader(verts)
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

function GrowthBlock:_cellCentre(header, gx, gz)
    return header.originX + gx * header.step, header.originZ + gz * header.step
end

-- ============================================================
-- 1a. CAPTURE, on START_GROWTH_PERIOD (published GrowthSystem.lua:240)
-- ============================================================

function GrowthBlock:onStartGrowthPeriod()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    -- Write-once: on a catch-up the NEXT period's START fires before the
    -- CURRENT period's FINISHED (GrowthSystem.lua:269 into :240 before :271),
    -- so re-capturing would destroy the restore basis.
    if self._captureHeld then return end

    local vm = self:_viability()
    local ss = self:_soilSystem()
    if vm == nil or ss == nil then return end

    self._capture = {}
    self._captureHeld = true
    for fieldId in pairs(ss.fieldData) do
        local field = ss.fieldData and ss.fieldData[fieldId]
        if field ~= nil then
            local verts = ss:_getFieldPolyVerts(fieldId, field)
            if verts ~= nil and #verts >= 3 then
                self:_captureField(fieldId, verts, vm)
            end
        end
    end
end

function GrowthBlock:_captureField(fieldId, verts, vm)
    local header = self:_deriveHeader(verts)
    local captured = {}
    local x = header.originX
    local gx = 0
    while x <= header.maxX do
        local z = header.originZ
        local gz = 0
        while z <= header.maxZ do
            local info = vm:getCellGrowthInfo(fieldId, x, z)
            if info ~= nil and info.blocked then
                local state, fruitIndex = self:_readCellState(x, z)
                if state ~= nil and fruitIndex ~= nil then
                    captured[#captured + 1] = { gx = gx, gz = gz, state = state, fruitIndex = fruitIndex }
                end
            end
            z = z + header.step
            gz = gz + 1
        end
        x = x + header.step
        gx = gx + 1
    end
    if #captured > 0 then
        self._capture[fieldId] = { header = header, cells = captured }
    end
end

-- ============================================================
-- 1b. RESTORE, on FINISHED_GROWTH_PERIOD (publish shape :262-272)
-- ============================================================

function GrowthBlock:onFinishedGrowthPeriod(_finishedPeriod, hasPendingGrowth)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    -- Hold while the queue is still draining; act on the drained delivery.
    if hasPendingGrowth == true then return end

    local growthMode = mission.missionInfo and mission.missionInfo.growthMode
    local writesTried = false
    if growthMode ~= GrowthMode.DISABLED then
        writesTried = self:_applyRestore()
    end

    -- THE UNCONDITIONAL CLEAR. Every drained delivery, writes or no writes,
    -- DISABLED included. growthMode is runtime-settable; a surviving capture
    -- plus the write-once rule would wedge the bracket forever. CERT ASSERTION.
    self._capture = {}
    self._captureHeld = false
    return writesTried
end

function GrowthBlock:_applyRestore()
    local vm = self:_viability()
    if vm == nil then return false end
    local cap = self:_restoreCap()
    local wroteAny = false

    for fieldId, capture in pairs(self._capture) do
        if self:_restoreField(fieldId, capture, cap) then wroteAny = true end
    end
    return wroteAny
end

function GrowthBlock:_restoreField(fieldId, capture, cap)
    local candidates = {}
    for _, e in ipairs(capture.cells) do
        local x, z = self:_cellCentre(capture.header, e.gx, e.gz)
        local state, fruitIndex = self:_readCellState(x, z)
        if state ~= nil and fruitIndex ~= nil then
            -- R2, three halves, all required.
            if fruitIndex ~= e.fruitIndex then
                -- half 1 fails: abandon this cell
            elseif not self:_passesR2CutWither(fruitIndex, state) then
                -- half 2 fails
            elseif state <= e.state then
                -- half 3 fails: current strictly above captured
            else
                local target = self:_restoreTarget(state, e.state, cap)
                candidates[#candidates + 1] = {
                    gx = e.gx, gz = e.gz,
                    fruitIndex = fruitIndex, current = state, target = target,
                }
            end
        end
    end
    if #candidates == 0 then return false end

    -- Bucket by (fruitIndex, currentState, targetState); one filtered
    -- executeSet per bucket on the fruit's own plane.
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

    local anyWritten = false
    for _, b in pairs(buckets) do
        local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(b.fruitIndex)
        if fruitDesc ~= nil and fruitDesc.terrainDataPlaneId ~= nil then
            if self:_strokeBucket(b, fruitDesc, capture.header) then anyWritten = true end
        end
    end
    return anyWritten
end

-- Half 2: the SET-based cut/withered tests. Do NOT use getIsGrowing, which is
-- false on harvest-ready states, and there is no stored isGrowing flag.
function GrowthBlock:_passesR2CutWither(fruitIndex, state)
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
    if fruitDesc == nil then return false end
    if fruitDesc:getIsCut(state) then return false end
    if fruitDesc:getIsWithered(state) then return false end
    return true
end

-- Target per cell: max(captured, current - cap), never below the captured value.
function GrowthBlock:_restoreTarget(current, captured, cap)
    local heldBack = current - cap
    if heldBack < captured then heldBack = captured end
    return heldBack
end

-- The engine's per-cell get, exactly as SF-53's hand uses it.
function GrowthBlock:_readCellState(x, z)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= 'function' then
        return nil, nil
    end
    local ok, fruitIndex, state = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok or fruitIndex == nil or state == nil then return nil, nil end
    return state, fruitIndex
end

-- ============================================================
-- THE WRITE HAND (the family machine, exactly SF-53's brief 2d)
-- ============================================================

function GrowthBlock:_strokeBucket(bucket, fruitDesc, header)
    local ok, err = pcall(function()
        local rings = self:_bucketRings(bucket.cells, header)
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
        SoilLogger.error("[SF-78] field growth block restore write failed: %s", tostring(err))
    end
    return ok
end

function GrowthBlock:_bucketRings(cells, header)
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
    local step = header.step
    local originX, originZ = header.originX, header.originZ
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
-- No Time Guard registration of any kind: the engine's own bracket
-- (START -> FINISHED) is the clock.
-- ============================================================

--- Register both message subscriptions. Server-only, by the write's nature.
--- pcall both; failures leave the module inert.
function GrowthBlock:register()
    if self._messageSubscribed then return true end
    if g_messageCenter == nil or MessageType == nil
        or MessageType.START_GROWTH_PERIOD == nil or MessageType.FINISHED_GROWTH_PERIOD == nil
        or type(g_messageCenter.subscribe) ~= 'function' then
        return false
    end
    local ok = pcall(function()
        g_messageCenter:subscribe(MessageType.START_GROWTH_PERIOD, self.onStartGrowthPeriod, self)
        g_messageCenter:subscribe(MessageType.FINISHED_GROWTH_PERIOD, self.onFinishedGrowthPeriod, self)
    end)
    if ok then self._messageSubscribed = true end
    return ok
end

--- The family's live gate, identical to SF-53's: the release gate open AND the
--- mask enabled. The restore cap's Agronomy multiplier is neutral 1.0 when the
--- resolver handle is absent.
function GrowthBlock:isLive()
    local vm = self:_viability()
    if vm ~= nil and vm.enabled == false then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == 'function' then
        return ReleaseGate.isSystemLive("growth_modulation")
    end
    return true
end

function GrowthBlock:_restoreCap()
    local cap = GrowthBlock.RESTORE_CAP_DEFAULT * self:_agronomyMult()
    return math.max(1, math.floor(cap + 0.5))
end

function GrowthBlock:_agronomyMult()
    if self._agronomyMultCached ~= nil then return self._agronomyMultCached end
    local mult = 1.0
    local ok, resolver = pcall(function()
        return (g_currentMission and g_currentMission.optionScalingResolver)
            or getfenv(0)["g_OptionScalingResolver"]
    end)
    if ok and resolver and type(resolver.value) == "function" then
        local ok2, v = pcall(resolver.value, resolver, GrowthBlock.SPINE_DIAL)
        if ok2 and type(v) == "number" and v >= 0 then mult = v end
    end
    self._agronomyMultCached = mult
    return mult
end
