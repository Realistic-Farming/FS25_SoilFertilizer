-- ============================================================
-- ZoneYield.lua  (SF-14)
--
-- ZONE YIELD OF THE ESTABLISHED CROP. Yield varies per cell
-- because conditions during growth varied, and that variation is
-- captured at the moment the conditions were real (growth time),
-- never recomputed live at harvest.
--
-- THE TWO HALVES.
--   The capture (per drained growth period): rides the engine's
--   FINISHED_GROWTH_PERIOD message (GrowthSystem publishes
--   finishedPeriod, hasPendingGrowth), scores each cell's N/P/K
--   against the efficiency band, clamps at write time, and writes
--   to the `yieldEfficiency` value-map layer. One drained delivery
--   produces one capture pass. Time Guard creates no second
--   ordinary capture.
--   The read (per harvest work-area pass): a pre-cut spatial
--   context method prepares the scalar BEFORE the destructive base
--   Cutter call, reading the captured, growth-time-static
--   `yieldEfficiency` layer across the true work-area polygon,
--   fruit-masked, area-weighted per SF-25's ratified rule.
--
-- THE FREEZE SUPERSESSION. On the spatial path (value maps
--   present and a fresh capture exists), the per-pass modifier is
--   the fruit-filtered polygon read of the captured layer. The
--   scalar `frozenYieldModifier` freeze stays exactly as built for
--   the non-spatial fallback (maps absent, field-average path) and
--   for contract fields, one branch, untouched. The same crop does
--   not change its yield result halfway through harvest because
--   earlier passes depleted nutrients: the capture is frozen at
--   growth time and the scalar freeze holds the field-average
--   fallback for the harvest run.
--
-- THE CALIBRATION BAR (reconciliation invariant). A uniform field,
--   where every cell shares the same growth-time conditions, must
--   yield exactly what it yields today. The capture formula IS
--   `_yieldModifierFromNutrients` (the same single source of truth
--   computeYieldModifier uses) evaluated with the CELL's own N/P/K,
--   clamped to the band. On a uniform field every cell carries the
--   field average, so every captured cell equals computeYieldModifier
--   output and the area-weighted read reconciles exactly, within the
--   band's own floor/ceiling.
--
-- COMPOSITION WITH SF-55 (addendum 2026-08-05): the per-pass read
--   applies `effective = captured * (1 - drag)` from day one; a nil
--   drag (the SF-55 layer is not present yet) reads as zero and the
--   read is unchanged. One writer per value still holds: SF-14 writes
--   capture, SF-55 writes drag, the read composes them.
--
-- The family ships LOCKED: inert unless the growth_modulation
-- release gate is open AND the mask is enabled.
-- ============================================================

ZoneYield = ZoneYield or {}
local ZoneYield_mt = Class(ZoneYield)

-- ── THE EFFICIENCY BAND ──────────────────────────────────────
-- AWAITING-SPINE: a tunable magnitude with no dial today, neutral
-- default the band above. Registered as ONE grouped declaration
-- when the Option-Scaling Spine ships, never a local knob.
ZoneYield.BAND_FLOOR   = 0.7
ZoneYield.BAND_CEILING = 1.15

-- Capture lattice: 8 m step, coarsened only enough to stay at or
-- below 600 accepted points per field per drained growth event.
ZoneYield.CAPTURE_LATTICE_STEP_M = 8
ZoneYield.CAPTURE_MAX_POINTS     = 600

-- Drag lattice: 4 m step under a 256 accepted-point ceiling. Each
-- accepted point performs one harvestable-fruit query plus one
-- yieldEfficiency point read and one trafficDrag point read.
ZoneYield.DRAG_LATTICE_STEP_M = 4
ZoneYield.DRAG_MAX_POINTS     = 256

function ZoneYield.new(manager)
    local self = setmetatable({}, ZoneYield_mt)
    self.manager = manager
    self.isInitialized = false
    self._messageSubscribed = false
    -- (fruitTypeIndex, allowsForageGrowthState) -> DensityMapFilter
    self._fruitFilterCache = {}
    -- fieldId -> fruitTypeIndex last contract-refreshed for
    self._contractRefreshed = {}
    return self
end

function ZoneYield:initialize()
    self.isInitialized = true
end

function ZoneYield:delete()
    self.isInitialized = false
    if self._messageSubscribed then
        local mc = g_messageCenter
        if mc and type(mc.unsubscribe) == 'function' then
            pcall(function() mc:unsubscribe(MessageType.FINISHED_GROWTH_PERIOD, self) end)
        end
        self._messageSubscribed = false
    end
    self._fruitFilterCache = {}
    self._contractRefreshed = {}
end

-- ============================================================
-- THE INPUTS (read-only access to the family's own data)
-- ============================================================

function ZoneYield:_soilSystem()
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and type(ss._getFieldPolyVerts) == 'function' then return ss end
    return nil
end

function ZoneYield:_valueMaps()
    local ss = self.manager and self.manager.soilSystem
    local vm = ss and ss.valueMaps
    if vm ~= nil and vm.available then return vm end
    return nil
end

function ZoneYield:_viability()
    local v = self.manager and self.manager.viability
    if v ~= nil and type(v.getCellGrowthInfo) == 'function' then return v end
    return nil
end

-- ============================================================
-- THE CAPTURE FORMULA (pure, bench-drivable)
-- ============================================================

--- The per-cell captured score: the same single source of truth
--- computeYieldModifier uses (`_yieldModifierFromNutrients`) with the
--- CELL's own N/P/K, clamped to the efficiency band at write time.
--- On a uniform field every cell carries the field average, so this
--- equals computeYieldModifier output and the area-weighted read
--- reconciles exactly. nil inputs score as the band's neutral 1.0
--- (an unreadable cell never captures as "dead ground").
---@param soilSystem table
---@param field table
---@param cropName string
---@param n number|nil
---@param p number|nil
---@param k number|nil
---@return number  multiplier in [BAND_FLOOR, BAND_CEILING]
function ZoneYield.captureScore(soilSystem, field, cropName, n, p, k)
    local raw = 1.0
    if soilSystem ~= nil and type(soilSystem._yieldModifierFromNutrients) == 'function'
       and type(n) == 'number' and type(p) == 'number' and type(k) == 'number' then
        local ok, mod = pcall(function()
            return soilSystem:_yieldModifierFromNutrients(field, cropName, n, p, k, nil)
        end)
        if ok and type(mod) == 'number' then raw = mod end
    end
    return math.max(ZoneYield.BAND_FLOOR, math.min(ZoneYield.BAND_CEILING, raw))
end

-- ============================================================
-- THE CAPTURE PASS (per drained growth period, per cell)
-- ============================================================

--- Ray-casting point-in-polygon test. Pure, bench-drivable.
---@param x number
---@param z number
---@param verts table list of {x=, z=}
---@return boolean
function ZoneYield.pointInPolygon(x, z, verts)
    local inside = false
    local n = #verts
    if n < 3 then return false end
    local j = n
    for i = 1, n do
        local vi, vj = verts[i], verts[j]
        if (vi.z > z) ~= (vj.z > z) then
            local xint = (vj.x - vi.x) * (z - vi.z) / (vj.z - vi.z) + vi.x
            if x < xint then inside = not inside end
        end
        j = i
    end
    return inside
end

--- The capture lattice for one field: an 8 m grid over the polygon
--- bounding box, coarsened only enough to stay at or below
--- CAPTURE_MAX_POINTS accepted centres. Returns the list of
--- {x=, z=} centres that fall inside the polygon.
---@param verts table list of {x=, z=}
---@return table list of {x=, z=}
function ZoneYield:_deriveCapturePoints(verts)
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        local v = verts[i]
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end
    local step = ZoneYield.CAPTURE_LATTICE_STEP_M
    local est = math.ceil((maxX - minX) / step) * math.ceil((maxZ - minZ) / step)
    if est > ZoneYield.CAPTURE_MAX_POINTS then
        step = step * math.ceil(math.sqrt(est / ZoneYield.CAPTURE_MAX_POINTS))
    end
    local out = {}
    local x = minX + step * 0.5
    while x <= maxX do
        local z = minZ + step * 0.5
        while z <= maxZ do
            if ZoneYield.pointInPolygon(x, z, verts) then
                out[#out + 1] = { x = x, z = z }
            end
            z = z + step
        end
        x = x + step
    end
    return out
end

--- The live fruit type index for one field, resolved once per pass.
--- Uses the live FieldState at the field centre (mirrors getFieldInfo);
--- `field.lastCrop` alone is NOT proof that a crop still stands, so a
--- field with no live fruit resolves to nil and captures nothing.
---@param fieldId number
---@return number|nil fruitTypeIndex
function ZoneYield:_resolveLiveFruit(fieldId)
    if g_fieldManager ~= nil and g_fieldManager.fields then
        local fsField = nil
        for _, f in ipairs(g_fieldManager.fields) do
            if f and f.farmland and f.farmland.id == fieldId then
                fsField = f
                break
            end
        end
        if fsField and fsField.posX and fsField.posZ then
            local ok, fieldState = pcall(function()
                local fs = FieldState.new()
                fs:update(fsField.posX, fsField.posZ)
                return fs
            end)
            if ok and fieldState and fieldState.fruitTypeIndex ~= FruitType.UNKNOWN then
                return fieldState.fruitTypeIndex
            end
        end
    end
    return nil
end

--- One capture field: walk the capture lattice, read N/P/K per cell
--- through the value maps (three reads), score, clamp, write to the
--- yieldEfficiency layer at that position. Sets the ready marker only
--- after at least one successful write.
---@param fieldId number
---@param field table
---@param fruitTypeIndex number
---@param ss table the soil system
---@param vm table the value maps
---@return boolean captured
function ZoneYield:_captureField(fieldId, field, fruitTypeIndex, ss, vm)
    if type(ss._getFieldPolyVerts) ~= 'function' then return false end
    local verts = ss:_getFieldPolyVerts(fieldId, field)
    if verts == nil or #verts < 3 then return false end

    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local cropName = fruitDesc and fruitDesc.name or ""
    if cropName == "" then return false end

    local points = self:_deriveCapturePoints(verts)
    if #points == 0 then return false end

    local writes = 0
    local reads = 0
    for _, pt in ipairs(points) do
        local n = vm:readValueAtWorld('nitrogen', pt.x, pt.z)
        local p = vm:readValueAtWorld('phosphorus', pt.x, pt.z)
        local k = vm:readValueAtWorld('potassium', pt.x, pt.z)
        reads = reads + 3
        if type(n) == 'number' and type(p) == 'number' and type(k) == 'number' then
            local score = ZoneYield.captureScore(ss, field, cropName, n, p, k)
            vm:writeValueAtWorld('yieldEfficiency', pt.x, pt.z, score * 100, ZoneYield.CAPTURE_LATTICE_STEP_M * 0.5)
            writes = writes + 1
        end
    end

    if writes > 0 then
        field.zoneYieldCaptureReady = true
    end

    if SoilLogger ~= nil and type(SoilLogger.info) == 'function' then
        SoilLogger.info("SF14_CAPTURE field=%d fruit=%d accepted=%d reads=%d writes=%d ready=%d skipped=none ms=0",
            fieldId, fruitTypeIndex, #points, reads, writes, field.zoneYieldCaptureReady and 1 or 0)
    end
    return writes > 0
end

--- The whole capture pass: every tracked field, one drained growth
--- delivery. Returns the number of fields captured.
---@return number fields captured
function ZoneYield:runCapturePass()
    if not self:isLive() then return 0 end
    local ss = self:_soilSystem()
    local vm = self:_valueMaps()
    if ss == nil or vm == nil then return 0 end
    if ss.fieldData == nil then return 0 end

    local captured = 0
    for fieldId in pairs(ss.fieldData) do
        local field = ss.fieldData[fieldId]
        if field ~= nil then
            local fruitTypeIndex = self:_resolveLiveFruit(fieldId)
            if fruitTypeIndex == nil then
                if SoilLogger ~= nil and type(SoilLogger.info) == 'function' then
                    SoilLogger.info("SF14_CAPTURE field=%d fruit=none accepted=0 reads=0 writes=0 ready=0 skipped=no-live-fruit ms=0", fieldId)
                end
            elseif field.frozenYieldFruitType == fruitTypeIndex then
                -- The same harvest retains its earlier capture.
                if SoilLogger ~= nil and type(SoilLogger.info) == 'function' then
                    SoilLogger.info("SF14_CAPTURE field=%d fruit=%d accepted=0 reads=0 writes=0 ready=%d skipped=frozen ms=0",
                        fieldId, fruitTypeIndex, field.zoneYieldCaptureReady and 1 or 0)
                end
            elseif self:_captureField(fieldId, field, fruitTypeIndex, ss, vm) then
                captured = captured + 1
            end
        end
    end
    return captured
end

--- Server-only FINISHED_GROWTH_PERIOD handler. One drained delivery
--- produces one capture pass. Returns unless the manager and server
--- are live, growth is enabled, and hasPendingGrowth == false.
---@param finishedPeriod number
---@param hasPendingGrowth boolean
function ZoneYield:onFinishedGrowthPeriod(finishedPeriod, hasPendingGrowth)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    if hasPendingGrowth ~= false then return end
    local growthMode = mission.missionInfo and mission.missionInfo.growthMode
    if growthMode == GrowthMode.DISABLED then return end
    self:runCapturePass()
end

--- Register the FINISHED_GROWTH_PERIOD subscription (server-only by
--- the value-map write's nature). Same shape and version-skew guard
--- as the rest of the family. Time Guard creates no second capture.
function ZoneYield:registerGrowthMessage()
    if self._messageSubscribed then return true end
    if g_messageCenter ~= nil
        and MessageType ~= nil and MessageType.FINISHED_GROWTH_PERIOD ~= nil
        and type(g_messageCenter.subscribe) == 'function' then
        local ok = pcall(function()
            g_messageCenter:subscribe(MessageType.FINISHED_GROWTH_PERIOD, self.onFinishedGrowthPeriod, self)
        end)
        if ok then self._messageSubscribed = true end
        return ok
    end
    return false
end

-- ============================================================
-- THE FRUIT FILTER CACHE (harvest-state DensityMapFilter)
-- ============================================================

--- Build (and cache) one harvest-state DensityMapFilter per
--- (fruitTypeIndex, allowsForageGrowthState) pair. The accepted range
--- is minForageGrowthState when forage is allowed, else
--- minHarvestingGrowthState, up to maxHarvestingGrowthState. Built
--- from FruitTypeDesc.terrainDataPlaneId / startStateChannel /
--- numStateChannels. Supersampling is set to ALL when available,
--- following the base-shipped mixed-map technique (NitrogenMap).
---@param fruitTypeIndex number
---@param allowsForageGrowthState boolean
---@return table|nil DensityMapFilter
function ZoneYield:_getFruitFilter(fruitTypeIndex, allowsForageGrowthState)
    local key = fruitTypeIndex .. ":" .. (allowsForageGrowthState and "1" or "0")
    local cached = self._fruitFilterCache[key]
    if cached ~= nil then return cached end

    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil or desc.terrainDataPlaneId == nil then return nil end

    local minState = desc.minHarvestingGrowthState
    if allowsForageGrowthState then
        minState = desc.minForageGrowthState
    end
    local maxState = desc.maxHarvestingGrowthState

    local ok, filter = pcall(function()
        local f = DensityMapFilter.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
        if DensityFilterSupersamplingMode ~= nil and DensityFilterSupersamplingMode.ALL ~= nil
           and type(f.setSupersamplingMode) == 'function' then
            f:setSupersamplingMode(DensityFilterSupersamplingMode.ALL)
        end
        f:setValueCompareParams(DensityValueCompareType.BETWEEN, minState, maxState)
        return f
    end)
    if not ok or filter == nil then return nil end

    self._fruitFilterCache[key] = filter
    return filter
end

-- ============================================================
-- THE PRE-CUT SPATIAL CONTEXT (per harvest work-area pass)
-- ============================================================

--- SF-55 composition line, applied per-cell from day one. A nil drag
--- (the SF-55 layer is not present yet) reads as zero, leaving the
--- captured efficiency unchanged. The drag itself is bounded to [0,1]
--- and may legitimately push the effective below SF-14's band floor
--- (that is SF-55's own domain, per the addendum); the captured side
--- is guarded at the band ceiling so a malformed read can never blow
--- past it. Pure, so the bench can prove it.
---@param captured number captured efficiency (0.7..1.15)
---@param drag number|nil traffic drag (0..1), nil = none
---@return number
function ZoneYield.composeDrag(captured, drag)
    if type(captured) ~= 'number' then return 1.0 end
    local d = type(drag) == 'number' and math.max(0, math.min(1, drag)) or 0
    local eff = captured * (1 - d)
    return math.max(0, math.min(ZoneYield.BAND_CEILING, eff))
end

--- SF-25's ratified area-weighted positional integral. samples is a
--- list of { value = number, area = number }. Unwritten cells
--- (value nil) contribute no area, so a partially-captured header
--- reads honestly over what it actually knows. Empty input returns
--- nil (fall back to the field-average path), never 0.
---@param samples table list of {value, area}
---@return number|nil
function ZoneYield.aggregateAreaWeighted(samples)
    local sum, area = 0.0, 0.0
    for _, s in ipairs(samples or {}) do
        if type(s) == 'table' and type(s.value) == 'number' then
            local a = type(s.area) == 'number' and s.area or 1.0
            sum = sum + s.value * a
            area = area + a
        end
    end
    if area <= 0 then return nil end
    return sum / area
end

--- The true parallelogram of one work area, preserved as the three
--- corner points (start, width, height) the engine uses.
---@param workArea table
---@return table|nil { start={x,z}, width={x,z}, height={x,z} }
function ZoneYield:_workAreaParallelogram(workArea)
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then
        return nil
    end
    local ok, sx, _, sz = pcall(getWorldTranslation, workArea.start)
    if not ok or not sx then return nil end
    local ok2, xw, _, zw = pcall(getWorldTranslation, workArea.width)
    if not ok2 or not xw then return nil end
    local ok3, xh, _, zh = pcall(getWorldTranslation, workArea.height)
    if not ok3 or not xh then return nil end
    return {
        start  = { x = sx, z = sz },
        width  = { x = xw, z = zw },
        height = { x = xh, z = zh },
    }
end

--- Resolve the field id from a work-area parallelogram using the
--- existing HookManager field resolver (field manager then farmland
--- manager at the start corner, with attached-implement fallback).
---@param cutterSelf table
---@param para table { start={x,z}, ... }
---@return number|nil
function ZoneYield:_resolveFieldId(cutterSelf, para)
    local function atWorld(x, z)
        if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
            local field = g_fieldManager:getFieldAtWorldPosition(x, z)
            if field and field.farmland then return field.farmland.id end
        end
        if g_farmlandManager then
            local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
            if farmland then return farmland.id end
        end
        return nil
    end

    local fieldId = atWorld(para.start.x, para.start.z)
    if fieldId and fieldId > 0 then return fieldId end

    -- Fallback: attached implements' work areas.
    local attachedImpls = cutterSelf.spec_attacherJoints and cutterSelf.spec_attacherJoints.attachedImplements
    if attachedImpls then
        for _, impl in ipairs(attachedImpls) do
            local obj = impl and impl.object
            if obj then
                local ix, _, iz = pcall(getWorldTranslation, obj.rootNode)
                if ix then
                    fieldId = atWorld(ix, iz)
                end
                if (not fieldId or fieldId <= 0) and obj.spec_workArea and obj.spec_workArea.workAreas then
                    for _, wa in ipairs(obj.spec_workArea.workAreas) do
                        if wa.start then
                            local ok, wx, _, wz = pcall(getWorldTranslation, wa.start)
                            if ok and wx then
                                fieldId = atWorld(wx, wz)
                            end
                        end
                        if fieldId and fieldId > 0 then break end
                    end
                end
            end
            if fieldId and fieldId > 0 then break end
        end
    end
    return fieldId
end

--- The fruit-filtered traffic drag over a polygon. Reads the SF-55
--- trafficDrag layer masked by the fruit filter; nil or zero is
--- identity (drag = 0). Returns a fraction in [0,1] or nil.
---@param vm table value maps
---@param verts table polygon
---@param fruitFilter table|nil
---@return number|nil
function ZoneYield:_readTrafficDragPolygon(vm, verts, fruitFilter)
    local drag, _ = vm:readAverageOfPolygon('trafficDrag', verts, fruitFilter)
    if type(drag) ~= 'number' or drag <= 0 then return nil end
    return math.max(0, math.min(1, drag))
end

--- The fruit-filtered yieldEfficiency polygon mean, divided by 100
--- exactly once. nil when the spatial path cannot answer.
---@param vm table value maps
---@param verts table polygon
---@param fruitFilter table|nil
---@return number|nil multiplier in [BAND_FLOOR, BAND_CEILING]
function ZoneYield:_readYieldPolygon(vm, verts, fruitFilter)
    local mean, _ = vm:readAverageOfPolygon('yieldEfficiency', verts, fruitFilter)
    if type(mean) ~= 'number' then return nil end
    return mean / 100
end

--- The drag path: one 4 m candidate lattice under a 256 accepted-point
--- ceiling. Each accepted point performs one harvestable-fruit query
--- plus one yieldEfficiency point read and one trafficDrag point read.
--- Skip unwritten capture; unwritten drag is zero. Returns the
--- composed scalar or nil.
---@param vm table value maps
---@param para table parallelogram
---@param fruitTypeIndex number
---@param allowsForageGrowthState boolean
---@param drag number positive drag fraction
---@return number|nil
function ZoneYield:_readDragPath(vm, para, fruitTypeIndex, allowsForageGrowthState, drag)
    local minX = math.min(para.start.x, para.width.x, para.height.x)
    local maxX = math.max(para.start.x, para.width.x, para.height.x)
    local minZ = math.min(para.start.z, para.width.z, para.height.z)
    local maxZ = math.max(para.start.z, para.width.z, para.height.z)

    local step = ZoneYield.DRAG_LATTICE_STEP_M
    local samples = {}
    local count = 0
    local x = minX + step * 0.5
    while x <= maxX and count < ZoneYield.DRAG_MAX_POINTS do
        local z = minZ + step * 0.5
        while z <= maxZ and count < ZoneYield.DRAG_MAX_POINTS do
            -- One harvestable-fruit query per accepted point.
            local ok, area = pcall(function()
                return FSDensityMapUtil.getFruitArea(fruitTypeIndex, x, z, x + step, z, x, z + step, false, allowsForageGrowthState)
            end)
            if ok and type(area) == 'number' and area > 0 then
                local captured = vm:readValueAtWorld('yieldEfficiency', x, z)
                if type(captured) == 'number' then
                    local pointDrag = vm:readValueAtWorld('trafficDrag', x, z)
                    local d = type(pointDrag) == 'number' and math.max(0, math.min(1, pointDrag)) or 0
                    samples[#samples + 1] = {
                        value = ZoneYield.composeDrag(captured / 100, d),
                        area  = step * step,
                    }
                end
            end
            count = count + 1
            z = z + step
        end
        x = x + step
    end
    if #samples == 0 then return nil end
    return ZoneYield.aggregateAreaWeighted(samples)
end

--- Prepare the pre-cut spatial context for one active work area,
--- BEFORE the destructive base Cutter call. Returns a context table
--- or nil (fallback). The context carries the resolved fruit type,
--- field id, the chosen path, and the scalar to apply.
---
--- Paths:
---   "spatial"  - fruit-filtered yieldEfficiency polygon mean (or the
---                drag lattice when drag is positive)
---   "fallback" - no fresh capture / no spatial answer; the caller
---                uses the frozen field-average scalar
---   "contract" - NPC-disabled or contract-exempt field; scalar path
---
--- Any missing field, fruit, filter, geometry, capture or accepted
--- point returns a fallback context, never zero yield.
---@param cutterSelf table the harvesting vehicle
---@param workArea table the active work area
---@return table|nil context
function ZoneYield:preparePreCutContext(cutterSelf, workArea)
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end

    local spec = cutterSelf.spec_cutter
    if spec == nil or spec.workAreaParameters == nil then return nil end

    local para = self:_workAreaParallelogram(workArea)
    if para == nil then return nil end

    -- Walk fruitTypeIndicesToUse in engine order; stop at the first
    -- candidate with positive harvestable area and cache its filter.
    local fruitTypeIndex = nil
    local allowsForageGrowthState = spec.allowsForageGrowthState or false
    local fruitFilter = nil
    local candidates = spec.workAreaParameters.fruitTypeIndicesToUse
    if candidates ~= nil then
        for _, candidate in ipairs(candidates) do
            local ok, area = pcall(function()
                return FSDensityMapUtil.getFruitArea(candidate, para.start.x, para.start.z,
                    para.width.x, para.width.z, para.height.x, para.height.z, false, allowsForageGrowthState)
            end)
            if ok and type(area) == 'number' and area > 0 then
                fruitTypeIndex = candidate
                fruitFilter = self:_getFruitFilter(candidate, allowsForageGrowthState)
                break
            end
        end
    end
    if fruitTypeIndex == nil then return nil end

    -- Resolve field id from the work-area corners.
    local fieldId = self:_resolveFieldId(cutterSelf, para)
    if fieldId == nil or fieldId <= 0 then return nil end

    -- Before classifying the first cut of a crop, refresh the contract
    -- cache, then read isFieldSimDisabled. NPC reason or contractExempt
    -- selects the scalar fallback.
    if self._contractRefreshed[fieldId] ~= fruitTypeIndex then
        if FieldSentry_API ~= nil and type(FieldSentry_API.refreshContract) == 'function' then
            pcall(FieldSentry_API.refreshContract, fieldId)
        end
        self._contractRefreshed[fieldId] = fruitTypeIndex
    end
    local disabled, reason, _, hints = false, nil, false, nil
    if FieldSentry_API ~= nil and type(FieldSentry_API.isFieldSimDisabled) == 'function' then
        local ok, d, r, _, h = pcall(FieldSentry_API.isFieldSimDisabled, fieldId)
        if ok then disabled, reason, hints = d, r, h end
    end
    local contractExempt = hints ~= nil and hints.contractExempt == true
    local npcReason = FieldSentry_Core ~= nil and FieldSentry_Core.BLACKLIST ~= nil
        and FieldSentry_Core.BLACKLIST.NPC or nil
    if disabled and ((npcReason ~= nil and reason == npcReason) or contractExempt) then
        return { path = "contract", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = nil, drag = nil }
    end

    -- No fresh capture yet: fallback until one capture pass succeeds.
    local field = self.manager and self.manager.soilSystem and self.manager.soilSystem.fieldData and self.manager.soilSystem.fieldData[fieldId]
    if field == nil or field.zoneYieldCaptureReady ~= true then
        return { path = "fallback", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = nil, drag = nil }
    end

    -- Build the polygon from the parallelogram corners.
    local verts = {
        { x = para.start.x,  z = para.start.z },
        { x = para.width.x,  z = para.width.z },
        { x = para.height.x, z = para.height.z },
        { x = para.width.x + para.height.x - para.start.x, z = para.width.z + para.height.z - para.start.z },
    }

    -- Fruit-filtered traffic drag by polygon; nil or zero is identity.
    local drag = self:_readTrafficDragPolygon(vm, verts, fruitFilter)

    local scalar
    if drag ~= nil and drag > 0 then
        scalar = self:_readDragPath(vm, para, fruitTypeIndex, allowsForageGrowthState, drag)
    else
        scalar = self:_readYieldPolygon(vm, verts, fruitFilter)
    end

    if scalar == nil then
        return { path = "fallback", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = nil, drag = drag }
    end
    return { path = "spatial", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = scalar, drag = drag }
end

--- Published per-cell captured efficiency, the socket ViabilityMask's
--- getCellGrowthInfo contract carries. Reads the captured layer at a
--- world position; nil when the spatial path cannot answer (not live,
--- no maps, or the pixel is unwritten) - the neutral reading. Returns
--- the multiplier (0.7..1.15), percent stored on the layer / 100.
---@param fieldId number
---@param x number
---@param z number
---@return number|nil
function ZoneYield:readCapturedEfficiency(_fieldId, x, z)
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local value = vm:readValueAtWorld('yieldEfficiency', x, z)
    if type(value) ~= 'number' then return nil end
    return value / 100
end

-- ============================================================
-- THE LIVE GATE + CADENCE
-- ============================================================

--- The family's live gate: the growth_modulation release gate must
--- be open AND the mask enabled. FAIL-OPEN on the release gate (nil
--- settings on the bench means live), but the mask switch is a real
--- toggle and gates hard.
function ZoneYield:isLive()
    local vm = self:_viability()
    if vm ~= nil and vm.enabled == false then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == 'function' then
        return ReleaseGate.isSystemLive('growth_modulation')
    end
    return true
end
