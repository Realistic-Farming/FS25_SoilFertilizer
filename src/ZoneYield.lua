-- ============================================================
-- ZoneYield.lua  (SF-14)
--
-- ZONE YIELD OF THE ESTABLISHED CROP. Yield varies per cell
-- because conditions during growth varied, and that variation is
-- captured at the moment the conditions were real (growth time),
-- never recomputed live at harvest.
--
-- THE TWO HALVES.
--   The capture (per growth period): rides the family's shared
--   read (ViabilityMask:getCellGrowthInfo, extended to carry the
--   full input set), scores each cell's N/P/K against the
--   efficiency band, clamps at write time, and writes to the
--   `yieldEfficiency` value-map layer.
--   The read (per harvest work-area pass): reads the captured,
--   growth-time-static `yieldEfficiency` layer across the header,
--   area-weighted per SF-25's ratified rule, producing one scalar.
--
-- THE FREEZE SUPERSESSION. On the spatial path (value maps
-- present), the SF-16 scalar `frozenYieldModifier` freeze is
-- BYPASSED, not reused: the per-pass modifier is the area-weighted
-- read of the captured layer, computed fresh each pass. The scalar
-- freeze stays exactly as built for the non-spatial fallback (maps
-- absent, field-average path), one branch, untouched.
--
-- THE CALIBRATION BAR (reconciliation invariant). A uniform field,
-- where every cell shares the same growth-time conditions, must
-- yield exactly what it yields today. The capture formula IS
-- `_yieldModifierFromNutrients` (the same single source of truth
-- computeYieldModifier uses) evaluated with the CELL's own N/P/K,
-- clamped to the band. On a uniform field every cell carries the
-- field average, so every captured cell equals computeYieldModifier
-- output and the area-weighted read reconciles exactly, within the
-- band's own floor/ceiling.
--
-- COMPOSITION WITH SF-55 (addendum 2026-08-05): the per-pass read
-- applies `effective = captured * (1 - drag)` from day one; a nil
-- drag (the SF-55 layer is not present yet) reads as zero and the
-- read is unchanged. One writer per value still holds: SF-14 writes
-- capture, SF-55 writes drag, the read composes them.
--
-- The family ships LOCKED: inert unless the growth_modulation
-- release gate is open AND the mask is enabled.
-- ============================================================

ZoneYield = {}
local ZoneYield_mt = Class(ZoneYield)

-- ── THE EFFICIENCY BAND ──────────────────────────────────────
-- AWAITING-SPINE: a tunable magnitude with no dial today, neutral
-- default the band above. Registered as ONE grouped declaration
-- when the Option-Scaling Spine ships, never a local knob.
ZoneYield.BAND_FLOOR   = 0.7
ZoneYield.BAND_CEILING = 1.15

-- Time Guard accrual. Priority 98 lands one behind the credit
-- bookkeeper (97), so the ground has settled, the dead have been
-- counted, and rewards have been accrued before the day's capture.
ZoneYield.DAILY_ACCURAL_ID       = 'SF14_zoneYieldCapture'
ZoneYield.DAILY_ACCURAL_PRIORITY = 98

-- Header read sample step, and the hard cap. The per-cell VALUE-MAP
-- read cost at harvest cadence is a NAMED bench item (brief section
-- 6), NOT asserted equal to boom-section cadence: this bounds the
-- worst case so a pathological header can never spin the frame.
ZoneYield.HEADER_SAMPLE_STEP_M = 4
ZoneYield.HEADER_MAX_SAMPLES   = 256

function ZoneYield.new(manager)
    local self = setmetatable({}, ZoneYield_mt)
    self.manager = manager
    self.isInitialized = false
    self._tgAccrualRegistered = false
    self._lastFallbackDay = nil
    return self
end

function ZoneYield:initialize()
    self.isInitialized = true
end

function ZoneYield:delete()
    self.isInitialized = false
    self._lastFallbackDay = nil
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
-- THE CAPTURE PASS (per growth period, per cell)
-- ============================================================

-- The survey lattice. Re-derive the family's own adaptive grid
-- exactly as ViabilityMask/GrowthCredit do, reading BOTH constants
-- off ViabilityMask at runtime, never copied literals.
---@param fieldId number
---@param verts table list of {x=, z=}
---@return table header { originX, originZ, step, maxX, maxZ }
function ZoneYield:_deriveHeader(fieldId, verts)
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

--- The growing crop's name for one field, resolved once per pass.
--- The live fruit read mirrors getFieldInfo (FieldState at the
--- field centre); `field.lastCrop` is the fallback. nil means
--- nothing growing, and a field with no crop captures nothing
--- (SF-18 orthogonality: an empty cell contributes no area).
---@param fieldId number
---@param field table
---@return string|nil
function ZoneYield:_resolveCropName(fieldId, field)
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
                local fruitDesc = g_fruitTypeManager and
                    g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
                if fruitDesc and fruitDesc.name then return fruitDesc.name end
            end
        end
    end
    if field and field.lastCrop and field.lastCrop ~= "" then
        return field.lastCrop
    end
    return nil
end

--- One capture field: walk the survey lattice, read N/P/K per cell
--- through the family's shared read, score, clamp, write to the
--- yieldEfficiency layer at that position.
---@param fieldId number
---@param field table
---@param ss table the soil system
---@param vm table the value maps
---@return boolean
function ZoneYield:_captureField(fieldId, field, ss, vm)
    if type(ss._getFieldPolyVerts) ~= 'function' then return false end
    local verts = ss:_getFieldPolyVerts(fieldId, field)
    if verts == nil or #verts < 3 then return false end

    local cropName = self:_resolveCropName(fieldId, field)
    if cropName == nil then return false end

    local viability = self:_viability()
    if viability == nil then return false end

    local header = self:_deriveHeader(fieldId, verts)
    local x = header.originX
    local gx = 0
    while x <= header.maxX do
        local z = header.originZ
        local gz = 0
        while z <= header.maxZ do
            local info = viability:getCellGrowthInfo(fieldId, x, z)
            if info ~= nil then
                local n = info.n
                local p = info.p
                local k = info.k
                if type(n) == 'number' and type(p) == 'number' and type(k) == 'number' then
                    local score = ZoneYield.captureScore(ss, field, cropName, n, p, k)
                    vm:writeValueAtWorld('yieldEfficiency', x, z, score * 100, header.step * 0.5)
                end
            end
            z = z + header.step
            gz = gz + 1
        end
        x = x + header.step
        gx = gx + 1
    end
    return true
end

--- The whole capture pass: every tracked field, every period.
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
            if self:_captureField(fieldId, field, ss, vm) then
                captured = captured + 1
            end
        end
    end
    return captured
end

-- ============================================================
-- THE HARVEST READ (per work-area pass, area-weighted)
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

--- Build the header polygon(s) from a combine's work areas: the
--- combine's own spec_workArea plus any attached implements, the
--- same iteration the fieldId fallback uses. Returns a list of
--- {x=, z=} polygons (one per work area), or nil when none resolves.
---@param combineSelf table the harvesting vehicle
---@return table|nil
function ZoneYield:_headerPolygons(combineSelf)
    local polygons = {}
    local function tryVehicle(vehicle)
        if vehicle == nil then return end
        if vehicle.spec_workArea and vehicle.spec_workArea.workAreas then
            for _, wa in ipairs(vehicle.spec_workArea.workAreas) do
                if wa and wa.start and wa.width and wa.height then
                    local ok, poly = pcall(function()
                        local xs, _, zs = getWorldTranslation(wa.start)
                        local xw, _, zw = getWorldTranslation(wa.width)
                        local xh, _, zh = getWorldTranslation(wa.height)
                        if not xs or not xw or not xh then return nil end
                        local x4 = xw + xh - xs
                        local z4 = zw + zh - zs
                        local minX = math.min(xs, xw, xh, x4)
                        local maxX = math.max(xs, xw, xh, x4)
                        local minZ = math.min(zs, zw, zh, z4)
                        local maxZ = math.max(zs, zw, zh, z4)
                        return {
                            { x = minX, z = minZ },
                            { x = maxX, z = minZ },
                            { x = maxX, z = maxZ },
                            { x = minX, z = maxZ },
                        }
                    end)
                    if ok and poly and #poly >= 3 then
                        polygons[#polygons + 1] = poly
                    end
                end
            end
        end
        if vehicle.spec_attacherJoints and vehicle.spec_attacherJoints.attachedImplements then
            for _, impl in ipairs(vehicle.spec_attacherJoints.attachedImplements) do
                local obj = impl and impl.object
                if obj then tryVehicle(obj) end
            end
        end
    end
    tryVehicle(combineSelf)
    if #polygons == 0 then return nil end
    return polygons
end

--- Sample a polygon on a bounded grid; every sample is the centre of
--- an equal-area cell (step squared), which is what makes the
--- aggregation an area-weighted integral rather than a scatter of
--- points. Capped so a pathological header cannot spin the frame.
---@param verts table {x=,z=} polygon
---@return table list of {x=, z=}
function ZoneYield:_samplePolygon(verts)
    local step = ZoneYield.HEADER_SAMPLE_STEP_M
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        local v = verts[i]
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end
    local out = {}
    local count = 0
    local x = minX + step * 0.5
    while x <= maxX and count < ZoneYield.HEADER_MAX_SAMPLES do
        local z = minZ + step * 0.5
        while z <= maxZ and count < ZoneYield.HEADER_MAX_SAMPLES do
            out[#out + 1] = { x = x, z = z }
            count = count + 1
            z = z + step
        end
        x = x + step
    end
    return out
end

--- The harvest-time modifier for one vehicle pass over a field: the
--- area-weighted read of the captured `yieldEfficiency` layer under
--- the header, with the SF-55 drag composition applied per cell.
--- Returns nil when the spatial path cannot answer (not live, no
--- maps, no header geometry, or no captured data under the header) -
--- the caller then falls back to the field-average `computeYieldModifier`
--- with its scalar freeze, untouched.
---@param combineSelf table the harvesting vehicle
---@param fieldId number
---@return number|nil modifier in [BAND_FLOOR, BAND_CEILING]
function ZoneYield:readHeaderAreaWeighted(combineSelf, fieldId)
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local polygons = self:_headerPolygons(combineSelf)
    if polygons == nil then return nil end

    local samples = {}
    for _, poly in ipairs(polygons) do
        for _, pt in ipairs(self:_samplePolygon(poly)) do
            local value = vm:readValueAtWorld('yieldEfficiency', pt.x, pt.z)
            if type(value) == 'number' then
                local drag = self:_readTrafficDrag(fieldId, pt.x, pt.z)
                samples[#samples + 1] = {
                    value = ZoneYield.composeDrag(value / 100, drag),
                    area  = ZoneYield.HEADER_SAMPLE_STEP_M * ZoneYield.HEADER_SAMPLE_STEP_M,
                }
            end
        end
    end
    if #samples == 0 then return nil end
    return ZoneYield.aggregateAreaWeighted(samples)
end

--- SF-55's traffic drag, not present yet. Returns nil (reads as zero
--- in composeDrag) until that layer lands; the read path composes it
--- from day one per the addendum. The SF-55 write will read its own
--- layer through this socket.
function ZoneYield:_readTrafficDrag(_fieldId, _x, _z)
    return nil
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

--- Time Guard accrual (simulation flow), same shape and version-skew
--- guard as the rest of the family. Server-only by the value-map
--- write's nature; registered from the manager at activation.
function ZoneYield:registerDailyAccrual()
    if self._tgAccrualRegistered then return true end
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.registerAccrual) ~= 'function' then return false end
    if tg.flowClasses ~= nil and tg.flowClasses.simulation ~= true then
        return false
    end
    local ok = pcall(function()
        tg:registerAccrual(ZoneYield.DAILY_ACCURAL_ID, {
            cadence = 'day',
            flowClass = 'simulation',
            firstPeriodPolicy = 'skip',
            priority = ZoneYield.DAILY_ACCURAL_PRIORITY,
            onSettle = function() self:runCapturePass() end,
        })
    end)
    if ok then self._tgAccrualRegistered = true end
    return ok
end

--- SF day-tracking fallback (Time Guard absent): the capture runs on
--- SF's own monotonic-day rollover, less precisely timed, never
--- incorrectly. Pumped from the soil system's daily pump, the same
--- shape as EstablishmentFailure:checkDayFallback.
function ZoneYield:checkDayFallback()
    if self._tgAccrualRegistered then return end
    local env = g_currentMission ~= nil and g_currentMission.environment
    if env == nil then return end
    local day = env.currentMonotonicDay or env.currentDay or 0
    if self._lastFallbackDay ~= nil and day ~= self._lastFallbackDay then
        self:runCapturePass()
    end
    self._lastFallbackDay = day
end
