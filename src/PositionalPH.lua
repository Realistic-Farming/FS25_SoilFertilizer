-- ============================================================
-- PositionalPH.lua  (SF-79)
--
-- POSITIONAL, CHEMICAL PH FOR SPRAYED-AREA LIME AND PH.
--
-- The existing `sfSoilMap_PH.grle` layer is the chemical-soil
-- authority; the field number is a REPORT derived from the written
-- pixels over the complete cultivated parcel domain. A report never
-- paints chemical pH. Native LIME_LEVEL remains a separate local
-- result of the same physical pass.
--
-- This module owns the private writer/cache routines the brief names
-- (`_applyPHFootprint`, `_ensurePHReport`) and hangs them on the
-- existing `SoilFertilitySystem` so the source-order witness in the
-- SF-79 bar can reach them. It adds no new grid, map, product, rate
-- curve, clock, app or automatic repeat-job policy.
--
-- The pure kernel (raw cohorts, normalization cohorts, raw-delta
-- quantization) is a static surface so the offline bar guards the
-- shipped arithmetic, not a private copy. Native density-map
-- execution, savegame IO, rendering and real multiplayer transport
-- remain in-game proof (release LOCKED).
-- ============================================================

PositionalPH = PositionalPH or {}
local PositionalPH_mt = Class(PositionalPH)

-- Writer result statuses (brief 3.A).
PositionalPH.STATUS_APPLIED       = 'APPLIED'
PositionalPH.STATUS_NO_CHANGE     = 'NO_CHANGE'
PositionalPH.STATUS_INVALID       = 'INVALID'
PositionalPH.STATUS_UNAVAILABLE   = 'UNAVAILABLE'
PositionalPH.STATUS_ERROR_PARTIAL = 'ERROR_PARTIAL'

-- Operations and scopes (brief 3.A).
PositionalPH.OP_DELTA     = 'DELTA'
PositionalPH.OP_SET       = 'SET'
PositionalPH.OP_NORMALIZE = 'NORMALIZE'

PositionalPH.SCOPE_POINT   = 'POINT'
PositionalPH.SCOPE_STRIP   = 'STRIP'
PositionalPH.SCOPE_POLYGON = 'POLYGON'
PositionalPH.SCOPE_FIELD   = 'FIELD'

-- Derived-report statuses (brief 3.B).
PositionalPH.REPORT_CURRENT     = 'CURRENT'
PositionalPH.REPORT_EMPTY       = 'EMPTY'
PositionalPH.REPORT_UNAVAILABLE = 'UNAVAILABLE'

-- Read-contract statuses (brief 3.D).
PositionalPH.READ_LOCAL       = 'LOCAL'
PositionalPH.READ_FIELD       = 'FIELD_REPORT'
PositionalPH.READ_APPROXIMATE = 'APPROXIMATE'
PositionalPH.READ_STALE       = 'STALE'
PositionalPH.READ_UNAVAILABLE = 'UNAVAILABLE'

PositionalPH.PH_LAYER = 'pH'

-- ============================================================
-- PURE KERNEL (driven directly by the bar).
-- ============================================================

--- Semantic pH units represented by one raw step, matching the
--- SoilValueMaps quantizer for the pH def.
--- @return number
function PositionalPH.unitsPerRaw()
    local limits = SoilConstants and SoilConstants.NUTRIENT_LIMITS
    if limits == nil then return 0 end
    local span = SoilValueMaps.RAW_MAX - SoilValueMaps.RAW_MIN
    if span <= 0 then return 0 end
    return (limits.PH_MAX - limits.PH_MIN) / span
end

--- The raw step count for a semantic pH delta, TRUNCATED TOWARD ZERO to
--- match the current quantizer. Zero means a sub-step change.
--- @return number
function PositionalPH.rawDeltaFor(delta)
    local upr = PositionalPH.unitsPerRaw()
    if upr <= 0 or type(delta) ~= 'number' then return 0 end
    if delta >= 0 then return math.floor(delta / upr) end
    return -math.floor(-delta / upr)
end

--- Apply a raw cohort delta to an array of raw values in place (index 1..n).
--- The saturation cohort is established BEFORE the interior add so a pixel the
--- add would carry past the ceiling lands AT the ceiling, never one step short
--- and never wrapped into the raw-0 sentinel. Mirrors the reference model the
--- bar drives.
--- @param values number[] raw values, mutated
--- @param delta number raw steps
function PositionalPH.rawCohortDelta(values, delta)
    if type(values) ~= 'table' or type(delta) ~= 'number' or delta == 0 then return end
    local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
    local span = RMAX - RMIN

    local function runBand(lo, hi, add, target)
        if lo > hi then return end
        for i = 1, #values do
            local raw = values[i]
            if type(raw) == 'number' and raw >= lo and raw <= hi then
                values[i] = target or (raw + add)
            end
        end
    end

    if delta >= span then runBand(RMIN, RMAX, 0, RMAX); return end
    if delta <= -span then runBand(RMIN, RMAX, 0, RMIN); return end
    if delta > 0 then
        runBand(RMAX - delta + 1, RMAX - 1, 0, RMAX)
        runBand(RMIN, RMAX - delta, delta, nil)
    else
        local mag = -delta
        runBand(RMIN + 1, RMIN + mag - 1, 0, RMIN)
        runBand(RMIN + mag, RMAX, delta, nil)
    end
end

--- Move an array of raw values toward the neutral band [lowRaw, highRaw] by
--- `step` raw units per pass. In-band pixels are untouched; a pixel within one
--- step of the band lands exactly on the bound. Mirrors the reference model.
--- @param values number[] raw values, mutated
--- @param step number positive raw steps
--- @param lowRaw number
--- @param highRaw number
function PositionalPH.normalizeRawCohorts(values, step, lowRaw, highRaw)
    if type(values) ~= 'table' or type(step) ~= 'number' or step <= 0 then return end
    local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
    local lo = math.max(RMIN, math.floor(lowRaw or RMIN))
    local hi = math.min(RMAX, math.floor(highRaw or RMAX))

    local function runBand(from, to, add, target)
        if from > to then return end
        for i = 1, #values do
            local raw = values[i]
            if type(raw) == 'number' and raw >= from and raw <= to then
                values[i] = target or (raw + add)
            end
        end
    end

    runBand(math.max(RMIN, lo - step + 1), lo - 1, 0, lo)
    runBand(RMIN, lo - step, step, nil)
    runBand(hi + 1, math.min(RMAX, hi + step - 1), 0, hi)
    runBand(hi + step, RMAX, -step, nil)
end

-- ============================================================
-- RAW / DOMAIN HELPERS
-- ============================================================

--- The pH layer definition from SoilValueMaps, or nil.
function PositionalPH.phDef()
    for _, def in ipairs(SoilValueMaps.LAYER_DEFS or {}) do
        if def.key == PositionalPH.PH_LAYER then return def end
    end
    return nil
end

--- Encode a semantic pH value to a raw step using the pH def.
--- @return number
function PositionalPH.phRaw(value, def)
    def = def or PositionalPH.phDef()
    if def == nil then return SoilValueMaps.RAW_MIN end
    local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
    local span = RMAX - RMIN
    local clamped = math.max(def.minVal, math.min(def.maxVal, value or def.minVal))
    local raw = RMIN + math.floor((clamped - def.minVal) / (def.maxVal - def.minVal) * span + 0.5)
    if raw < RMIN then raw = RMIN end
    if raw > RMAX then raw = RMAX end
    return raw
end

--- Decode a raw step to a semantic pH value.
--- @return number|nil
function PositionalPH.phValue(raw, def)
    if type(raw) ~= 'number' or raw <= 0 then return nil end
    def = def or PositionalPH.phDef()
    if def == nil then return nil end
    local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
    return def.minVal + ((raw - RMIN) / (RMAX - RMIN)) * (def.maxVal - def.minVal)
end

--- The pH carrier grain in metres (terrainSize / PH width), or nil. The PH
--- carrier shares the store resolution, so this is the store grain.
--- @return number|nil
function SoilFertilitySystem:_phGrainMetres()
    local vm = self.valueMaps
    if vm == nil or not vm.available then return nil end
    return vm:getGrainMetres()
end

--- The complete cultivated parcel domain for a farmland as an array of vertex
--- arrays, or nil. Gaps are excluded and overlapping polygons are returned
--- separately (the engine applies overlap once per executeSet).
--- @return table|nil
function SoilFertilitySystem:_phFieldPolygons(fieldId)
    if type(self._getFarmlandPolygons) ~= 'function' then return nil end
    return self:_getFarmlandPolygons(fieldId)
end

--- Canonical domain key for a farmland (brief 3.B): parcel id, terrain size,
--- PH width and the canonical polygon coordinates. Used to restore a small
--- finite FIELD remainder only onto a matching domain.
--- @return string
function SoilFertilitySystem:_phDomainKey(fieldId)
    local polys = self:_phFieldPolygons(fieldId)
    if polys == nil then return '' end
    local vm = self.valueMaps
    local terrain = (vm and vm.terrainSize) or 0
    local width = (vm and vm.resolution) or 0
    local parts = { tostring(fieldId), tostring(terrain), tostring(width) }
    for _, verts in ipairs(polys) do
        local coords = {}
        for _, v in ipairs(verts) do
            coords[#coords + 1] = string.format("%.17g,%.17g", v.x + 0.0, v.z + 0.0)
        end
        parts[#parts + 1] = table.concat(coords, ';')
    end
    return table.concat(parts, '|')
end

--- The geometric bounds of a polygon list, or nil.
local function polygonBounds(polys)
    local minX, maxX, minZ, maxZ
    for _, verts in ipairs(polys or {}) do
        for _, v in ipairs(verts) do
            if minX == nil or v.x < minX then minX = v.x end
            if maxX == nil or v.x > maxX then maxX = v.x end
            if minZ == nil or v.z < minZ then minZ = v.z end
            if maxZ == nil or v.z > maxZ then maxZ = v.z end
        end
    end
    if minX == nil then return nil end
    return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
end

--- Resolve a request's geometry to a list of polygons plus bounds, or nil when
--- the geometry is malformed for the scope.
local function resolveGeometry(self, fieldId, request)
    local scope = request.scope
    if scope == PositionalPH.SCOPE_FIELD then
        local polys = self:_phFieldPolygons(fieldId)
        if polys == nil or #polys == 0 then return nil end
        return polys, polygonBounds(polys)
    elseif scope == PositionalPH.SCOPE_POLYGON then
        local verts = request.verts
        if type(verts) ~= 'table' or #verts < 3 then return nil end
        for _, v in ipairs(verts) do
            if type(v) ~= 'table' or type(v.x) ~= 'number' or type(v.z) ~= 'number' then return nil end
        end
        return { verts }, polygonBounds({ verts })
    elseif scope == PositionalPH.SCOPE_STRIP then
        local sx, sz, wx, wz, hx, hz = request.sx, request.sz, request.wx, request.wz, request.hx, request.hz
        if type(sx) ~= 'number' or type(sz) ~= 'number' or type(wx) ~= 'number'
            or type(wz) ~= 'number' or type(hx) ~= 'number' or type(hz) ~= 'number' then return nil end
        local verts = {
            { x = sx, z = sz }, { x = wx, z = wz }, { x = hx, z = hz },
            { x = wx + hx - sx, z = wz + hz - sz },
        }
        return { verts }, polygonBounds({ verts })
    elseif scope == PositionalPH.SCOPE_POINT then
        local x, z, r = request.x, request.z, request.radius
        if type(x) ~= 'number' or type(z) ~= 'number' then return nil end
        r = (type(r) == 'number' and r > 0) and r or (self:_phGrainMetres() or 1.5) * 0.5
        local verts = {
            { x = x - r, z = z - r }, { x = x + r, z = z - r },
            { x = x + r, z = z + r }, { x = x - r, z = z + r },
        }
        return { verts }, polygonBounds({ verts })
    end
    return nil
end

-- ============================================================
-- THE WRITER
-- ============================================================

--- Apply one pH footprint request. Returns
--- { status, mapRevision, reportDirty, bounds, reason }.
---@param fieldId number
---@param request table
function SoilFertilitySystem:_applyPHFootprint(fieldId, request)
    local result = {
        status = PositionalPH.STATUS_INVALID,
        mapRevision = self._phMapRevision or 0,
        reportDirty = false,
        bounds = nil,
        reason = nil,
    }
    if g_server == nil then
        result.status = PositionalPH.STATUS_UNAVAILABLE
        result.reason = 'not-server'
        return result
    end
    if type(fieldId) ~= 'number' or type(request) ~= 'table' then
        result.reason = 'bad-request'
        return result
    end
    local vm = self.valueMaps
    if vm == nil or not vm.available then
        result.status = PositionalPH.STATUS_UNAVAILABLE
        result.reason = 'no-maps'
        return result
    end
    local entry = vm:getLayerEntry(PositionalPH.PH_LAYER)
    local def = entry and entry.def
    if def == nil then
        result.status = PositionalPH.STATUS_UNAVAILABLE
        result.reason = 'no-ph-layer'
        return result
    end

    local op = request.operation
    if op ~= PositionalPH.OP_DELTA and op ~= PositionalPH.OP_SET and op ~= PositionalPH.OP_NORMALIZE then
        result.reason = 'bad-operation'
        return result
    end

    local polys, bounds = resolveGeometry(self, fieldId, request)
    if polys == nil then
        result.reason = 'bad-geometry'
        return result
    end
    result.bounds = bounds

    -- Growth-domain attribution so a pH write never advances the growth read-set
    -- (pH is not a growth key) but is still attributed where a caller proves it.
    local growthDomain = request.growthDomain

    local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
    local span = RMAX - RMIN
    local applied = false
    local refused = false
    local changed = false

    local function runSet(verts, rawValue, bandLow, bandHigh)
        local ok = vm:setPolygonWhere(PositionalPH.PH_LAYER, verts, rawValue, bandLow, bandHigh, growthDomain)
        if ok == false then refused = true else applied = true end
    end
    local function runDelta(verts, rawDelta, bandLow, bandHigh)
        local r = vm:applyRawDeltaToPolygonBand(PositionalPH.PH_LAYER, verts, rawDelta, bandLow, bandHigh, {}, growthDomain)
        if r == nil then refused = true else applied = true end
    end

    if op == PositionalPH.OP_DELTA then
        local rawDelta = PositionalPH.rawDeltaFor(request.value)
        if rawDelta == 0 then
            result.status = PositionalPH.STATUS_NO_CHANGE
            result.reason = 'sub-step'
            return result
        end
        changed = true
        for _, verts in ipairs(polys) do
            if rawDelta >= span then
                runSet(verts, RMAX, RMIN, RMAX)
            elseif rawDelta <= -span then
                runSet(verts, RMIN, RMIN, RMAX)
            elseif rawDelta > 0 then
                -- Saturation cohort FIRST, then the interior add.
                runSet(verts, RMAX, RMAX - rawDelta + 1, RMAX - 1)
                runDelta(verts, rawDelta, RMIN, RMAX - rawDelta)
            else
                local mag = -rawDelta
                runSet(verts, RMIN, RMIN + 1, RMIN + mag - 1)
                runDelta(verts, rawDelta, RMIN + mag, RMAX)
            end
        end
    elseif op == PositionalPH.OP_SET then
        local rawValue = PositionalPH.phRaw(request.value, def)
        changed = true
        for _, verts in ipairs(polys) do
            runSet(verts, rawValue, 0, RMAX)
        end
    else -- NORMALIZE
        local lowRaw = PositionalPH.phRaw(request.targetLow, def)
        local highRaw = PositionalPH.phRaw(request.targetHigh, def)
        if lowRaw > highRaw then lowRaw, highRaw = highRaw, lowRaw end
        local step = PositionalPH.rawDeltaFor(math.abs(request.value or 0))
        if step <= 0 then
            result.status = PositionalPH.STATUS_NO_CHANGE
            result.reason = 'sub-step'
            return result
        end
        changed = true
        for _, verts in ipairs(polys) do
            -- Near-target SET before farther ADD, so no pixel is processed twice.
            runSet(verts, lowRaw, math.max(RMIN, lowRaw - step + 1), lowRaw - 1)
            runDelta(verts, step, RMIN, lowRaw - step)
            runSet(verts, highRaw, highRaw + 1, math.min(RMAX, highRaw + step - 1))
            runDelta(verts, -step, highRaw + step, RMAX)
        end
    end

    if refused and applied then
        result.status = PositionalPH.STATUS_ERROR_PARTIAL
        result.reason = 'partial-native-refusal'
    elseif refused then
        result.status = PositionalPH.STATUS_UNAVAILABLE
        result.reason = 'native-refused'
    elseif not changed then
        result.status = PositionalPH.STATUS_NO_CHANGE
    else
        result.status = PositionalPH.STATUS_APPLIED
        self._phMapRevision = (self._phMapRevision or 0) + 1
        result.mapRevision = self._phMapRevision
        result.reportDirty = true
    end
    return result
end

--- Seed raw-zero supported ground from a frozen scalar (brief 3.B). Only pixels
--- with no record are touched (band [0,0]), so a valid pixel is preserved.
--- @return number seeded
function SoilFertilitySystem:_seedPHFootprint(fieldId, scalar)
    local vm = self.valueMaps
    if vm == nil or not vm.available or g_server == nil then return 0 end
    local def = PositionalPH.phDef()
    local polys = self:_phFieldPolygons(fieldId)
    if def == nil or polys == nil then return 0 end
    local raw = PositionalPH.phRaw(scalar, def)
    local seeded = 0
    for _, verts in ipairs(polys) do
        local ok = vm:setPolygonWhere(PositionalPH.PH_LAYER, verts, raw, 0, 0)
        if ok then seeded = seeded + 1 end
    end
    return seeded
end
