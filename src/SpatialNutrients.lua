-- =========================================================
-- FS25 Soil & Fertilizer - SPATIAL NUTRIENTS (SF-23)
-- =========================================================
-- Make the four soil chemistry values follow the water. The shipped leach
-- already weighs the loss by SCS moisture x organic matter, but at one number
-- per field; this feature distributes that SAME loss across moisture bands
-- within the field, so the wet hollow runs hungry and drifts acid while the
-- dry knoll holds. A feature inside SoilFertilizer on the Refined-engine line;
-- no new mod, no new handle, no money.
--
-- The field-level model is UNTOUCHED and stays the aggregate truth. This adds
-- only WHERE the map distribution lands. Degrades to today's exact behaviour
-- when its inputs are absent (no SCS = one band = the uniform leach).
--
-- Mechanism (from the brief, section 3):
--   1. BAND ASSIGNMENT, cached, never per-frame. Per field, group the field's
--      area into 3 to 5 moisture bands from the positional SCS read
--      getMoisture(fieldId, x, z). Refreshed on the day cadence, never in the
--      per-frame leach path.
--   2. PER-TICK BANDED ACCUMULATION. Split the tick's field-level loss across
--      the cached bands by weight (band moisture x band OM x texture),
--      normalised so the band shares sum exactly to the field loss. Accumulate
--      into a per-band-per-key pending store; flush a band only when its
--      accumulation crosses one raw map step.
--   3. THE FLOOR RULE (measured, not optional). applyDeltaToPolygon returns the
--      INTENDED shift and its filter skips (does not clamp) any pixel a
--      negative delta would push below the raw floor. Settle the pending store
--      against the RETURNED value, never the intended one recomputed.
--   4. CONSERVATION. Band shares sum exactly to the field-level loss; the field
--      scalar path is not modified.
--
-- Texture: tier 0 = the field-level soil type read from SCS, neutral to loam
-- when the getter is absent (F157). Tiers 1-2 (positional terrain / soilTexture
-- map) are maturity-asks, neutral-when-absent.
--
-- Phosphorus: NO deep leaching (it binds; the 0.5 field-level multiplier stays
-- the model's business). Its spatial pathways are application (already
-- positional via the boom writes) and crop removal (banded at harvest).
--
-- Server-only. Writes only the value maps SoilFertilizer already owns. No write
-- crosses the firewall to SeasonalCropStress.
-- =========================================================
-- Author: TisonK
-- =========================================================

SpatialNutrients = SpatialNutrients or {}

SpatialNutrients.ENABLED = true

-- Tunables (the brief's numbers; neutral defaults until the spine dial lands)
SpatialNutrients.BAND_COUNT_MIN = 3        -- fewest moisture bands per field
SpatialNutrients.BAND_COUNT_MAX = 5        -- most moisture bands per field
SpatialNutrients.SAMPLE_STEP_M   = 10      -- field grid sample step for banding (m)
SpatialNutrients.TEXTURE_SANDY   = 1.1     -- coarse soil leaches faster
SpatialNutrients.TEXTURE_LOAMY   = 1.0     -- reference
SpatialNutrients.TEXTURE_CLAY    = 0.85    -- heavy soil holds more

-- The spine Agronomy dial this feature reads (neutral 1.0 when absent/off).
SpatialNutrients.SPINE_DIAL = "agronomy"

-- =========================================================
-- Texture tier 0: field-level soil type from SCS, neutral to loam.
-- F157: SCS has not published getSoilType/getFieldSoilType, so this probes
-- both spellings and falls back to loamy. Never throws.
-- =========================================================
local SOIL_TEXTURE = {
    sandy = SpatialNutrients.TEXTURE_SANDY,
    loamy = SpatialNutrients.TEXTURE_LOAMY,
    clay  = SpatialNutrients.TEXTURE_CLAY,
    loam  = SpatialNutrients.TEXTURE_LOAMY,  -- tolerate "loam" spelling
}

--- Field-level texture weight for a field. pcall + neutral: the getter may be
--- absent (F157), throw, or return an unknown string; all degrade to loamy.
---@param field table|nil
---@return number weight  1.0 = loamy reference
function SpatialNutrients:textureWeight(field)
    local csMgr = g_currentMission and g_currentMission.cropStressManager
    if not csMgr then return SpatialNutrients.TEXTURE_LOAMY end
    local soilType
    local ok, a = pcall(function() return csMgr:getSoilType(field and field.fieldId) end)
    if ok and type(a) == "string" then soilType = a end
    if soilType == nil then
        local ok2, b = pcall(function() return csMgr:getFieldSoilType(field and field.fieldId) end)
        if ok2 and type(b) == "string" then soilType = b end
    end
    if soilType == nil then return SpatialNutrients.TEXTURE_LOAMY end
    local w = SOIL_TEXTURE[string.lower(soilType)]
    return w or SpatialNutrients.TEXTURE_LOAMY
end

-- =========================================================
-- Band assignment
-- =========================================================

--- Convex hull of a set of {x,z} points (Andrew monotone chain). Used to turn a
--- band's sample points into a sub-polygon for applyDeltaToPolygon. Returns nil
--- when fewer than 3 distinct points.
---@param pts table array of {x=, z=}
---@return table|nil hull
function SpatialNutrients:convexHull(pts)
    if not pts or #pts < 3 then return nil end
    local sorted = {}
    for i = 1, #pts do sorted[#sorted + 1] = { x = pts[i].x, z = pts[i].z } end
    table.sort(sorted, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.z < b.z
    end)
    local cross = function(o, a, b)
        return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
    end
    local lower, upper = {}, {}
    for _, p in ipairs(sorted) do
        while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do
            table.remove(lower)
        end
        lower[#lower + 1] = p
    end
    for i = #sorted, 1, -1 do
        local p = sorted[i]
        while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do
            table.remove(upper)
        end
        upper[#upper + 1] = p
    end
    -- The last point of each chain is the other chain's first (both extreme
    -- points are shared); drop them before combining so no corner duplicates.
    table.remove(lower)
    table.remove(upper)
    for _, p in ipairs(upper) do lower[#lower + 1] = p end
    if #lower < 3 then return nil end
    return lower
end

--- Refresh a field's cached moisture bands from the positional SCS read.
--- Samples the field polygon on a grid, reads moisture at each point, buckets
--- into 3-5 bands by moisture level, and stores each band's sample points for
--- hull derivation. One band (the uniform fallback) when SCS is absent or the
--- field has no polygon.
---@param fieldId number
---@param field table
---@param poly table|nil field polygon verts {x,z} (nil = fall back to one band)
---@return table bands  { {key, moisture, points={...}}, ... } or one-band table
function SpatialNutrients:refreshBands(fieldId, field, poly)
    local csMgr = g_currentMission and g_currentMission.cropStressManager
    local samples = {}
    if csMgr and field and poly and #poly >= 3 then
        local step = SpatialNutrients.SAMPLE_STEP_M
        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
        for _, v in ipairs(poly) do
            if v.x < minX then minX = v.x end
            if v.x > maxX then maxX = v.x end
            if v.z < minZ then minZ = v.z end
            if v.z > maxZ then maxZ = v.z end
        end
        -- Sample the AABB on a grid, keep points inside the polygon (ray cast).
        local z = minZ
        while z <= maxZ do
            local x = minX
            while x <= maxX do
                if self:_pointInPoly(x, z, poly) then
                    local ok, m = pcall(csMgr.getMoisture, csMgr, fieldId, x, z)
                    if ok and type(m) == "number" then
                        samples[#samples + 1] = { x = x, z = z, moisture = m }
                    end
                end
                x = x + step
            end
            z = z + step
        end
    end

    -- No samples -> one band (today's uniform leach).
    if #samples == 0 then
        return { { key = 0, moisture = 0.5, points = {} } }
    end

    -- Bucket into 3-5 bands by moisture percentile. Equal-count buckets keep
    -- the split meaningful on skewed moisture distributions.
    table.sort(samples, function(a, b) return a.moisture < b.moisture end)
    local bandCount = math.min(SpatialNutrients.BAND_COUNT_MAX,
        math.max(SpatialNutrients.BAND_COUNT_MIN, math.floor(#samples / 8)))
    local bands = {}
    for b = 1, bandCount do
        bands[b] = { key = b, moisture = 0, points = {}, _sum = 0 }
    end
    for i, s in ipairs(samples) do
        local b = math.min(bandCount, math.max(1, math.ceil(i / #samples * bandCount)))
        local band = bands[b]
        band.points[#band.points + 1] = s
        band._sum = band._sum + s.moisture
    end
    for _, band in ipairs(bands) do
        band.moisture = band._sum / math.max(1, #band.points)
        band._sum = nil
    end
    return bands
end

--- Point-in-polygon (ray cast) for the band sampling grid.
---@param x number
---@param z number
---@param poly table {x,z} verts
---@return boolean
function SpatialNutrients:_pointInPoly(x, z, poly)
    local inside = false
    local n = #poly
    local j = n
    for i = 1, n do
        local xi, zi = poly[i].x, poly[i].z
        local xj, zj = poly[j].x, poly[j].z
        if ((zi > z) ~= (zj > z)) and
           (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- =========================================================
-- Band weights + the spine multiplier
-- =========================================================

--- Weight of one band: moisture x OM x texture, with a floor so a dry band
--- still carries a sliver (the field loss must land somewhere). Returns >= 0.
---@param band table
---@param field table
---@param texture number
---@return number weight
function SpatialNutrients:bandWeight(band, field, texture)
    local moisture = math.max(0.05, band.moisture or 0)  -- floor so dry bands count
    local om  = math.max(0.1, (field.organicMatter or 0) / 10.0)  -- 0..1-ish
    return moisture * om * (texture or 1.0)
end

--- The spine Agronomy multiplier for every water-driven rate. Reads the vendored
--- OptionScaling resolver; NEUTRAL 1.0 when absent, off, or not yet built.
---@return number mult
function SpatialNutrients:severityMult()
    if SpatialNutrients._resolverMult ~= nil then return SpatialNutrients._resolverMult end
    local mult = 1.0
    local ok, resolver = pcall(function()
        return (g_currentMission and g_currentMission.optionScalingResolver)
            or getfenv(0)["g_OptionScalingResolver"]
    end)
    if ok and resolver and type(resolver.value) == "function" then
        local ok2, v = pcall(resolver.value, resolver, SpatialNutrients.SPINE_DIAL)
        if ok2 and type(v) == "number" and v >= 0 then mult = v end
    end
    SpatialNutrients._resolverMult = mult
    return mult
end

-- =========================================================
-- Banded accumulation + flush (the floor rule)
-- =========================================================

--- Queue a field-level delta split across the field's cached bands. Mutates
--- field._snPend[bandKey][mapKey] and field._snBandHull[bandKey]. When the field
--- has no bands yet, or SCS is absent, falls back to the existing single-band
--- uniform path (caller decides).
---@param selfSoilSystem table the SoilFertilitySystem
---@param fieldId number
---@param field table
---@param mapKey string  "nitrogen" | "potassium" | "phosphorus" | "pH"
---@param delta number   the field-level loss for this tick (negative)
---@param bands table    cached bands (field._snBands)
function SpatialNutrients:queueBandedDelta(selfSoilSystem, fieldId, field, mapKey, delta)
    if delta == 0 then return end
    local bands = field._snBands
    if not bands or #bands <= 1 then
        -- One band: the uniform path, exactly today's behaviour.
        selfSoilSystem:_vmQueueFieldDelta(field, mapKey, delta)
        return
    end
    if not field._snPend then field._snPend = {} end
    if not field._snBandHull then field._snBandHull = {} end

    local texture = self:textureWeight(field)
    local mult = self:severityMult()
    local total = 0
    for _, band in ipairs(bands) do
        total = total + self:bandWeight(band, field, texture)
    end
    if total <= 0 then
        selfSoilSystem:_vmQueueFieldDelta(field, mapKey, delta)
        return
    end

    local remain = delta * mult
    local n = #bands
    for i, band in ipairs(bands) do
        local share = (i == n) and remain or (delta * mult) * (self:bandWeight(band, field, texture) / total)
        -- Normalise: the last band absorbs any float drift so shares sum exactly.
        if i == n then share = remain end
        if share ~= 0 then
            if not field._snPend[band.key] then field._snPend[band.key] = {} end
            field._snPend[band.key][mapKey] = (field._snPend[band.key][mapKey] or 0) + share
            remain = remain - share
            if not field._snBandHull[band.key] then
                field._snBandHull[band.key] = self:convexHull(band.points)
            end
        end
    end
end

--- Flush the field's banded pending deltas through applyDeltaToPolygon per band
--- hull, settling each pending value against the RETURNED shift (the floor rule).
---@param selfSoilSystem table the SoilFertilitySystem
---@param fieldId number
---@param field table
function SpatialNutrients:flushBands(selfSoilSystem, fieldId, field)
    local pend = field._snPend
    if not pend or not selfSoilSystem:vmAvailable() then return end
    local upr = nil
    for bandKey, keys in pairs(pend) do
        local hull = field._snBandHull and field._snBandHull[bandKey]
        if hull and #hull >= 3 then
            for mapKey, amount in pairs(keys) do
                if amount ~= 0 then
                    local applied = selfSoilSystem.valueMaps:applyDeltaToPolygon(mapKey, hull, amount)
                    if applied ~= 0 then
                        keys[mapKey] = amount - applied
                    end
                end
            end
        else
            -- No derivable hull: settle the whole band's delta through the field
            -- uniform path rather than losing it to a nil polygon.
            for mapKey, amount in pairs(keys) do
                if amount ~= 0 then
                    selfSoilSystem:_vmQueueFieldDelta(field, mapKey, amount)
                    keys[mapKey] = 0
                end
            end
        end
    end
    -- Drop exhausted bands.
    for bandKey in pairs(pend) do
        local empty = true
        for _, amount in pairs(pend[bandKey]) do
            if amount ~= 0 then empty = false break end
        end
        if empty then pend[bandKey] = nil end
    end
end

-- =========================================================
-- Day-cadence refresh (called from the daily pass / Time Guard registrant)
-- =========================================================

--- Refresh every active field's cached bands. Called once per day, server-side,
--- never in the per-frame leach path. Bands that cannot be derived collapse to
--- the one-band uniform fallback.
---@param selfSoilSystem table the SoilFertilitySystem
function SpatialNutrients:refreshAllBands(selfSoilSystem)
    local fields = selfSoilSystem and selfSoilSystem.fieldData
    if not fields then return end
    for fieldId, field in pairs(fields) do
        local poly = selfSoilSystem:_getFieldPolyVerts(fieldId, field)
        field._snBands = self:refreshBands(fieldId, field, poly)
    end
end

-- =========================================================
-- Reciprocal read (brief item 10): publish a positional nutrient sample so
-- SeasonalCropStress can read SF's spatial state the way SF reads its moisture.
-- Read-only by contract; nil when the value map has no data at the position.
-- =========================================================

---@param key string  "nitrogen" | "phosphorus" | "potassium" | "pH" | "organicMatter"
---@param x number
---@param z number
---@return number|nil
function SpatialNutrients:getSoilValueAtWorld(selfSoilSystem, key, x, z)
    if not selfSoilSystem or not selfSoilSystem:vmAvailable() then return nil end
    return selfSoilSystem.valueMaps:readValueAtWorld(key, x, z)
end

-- =========================================================
-- Phosphorus: no deep leach. The field-level 0.5 multiplier is the model's
-- business; P's spatial pathways are application (already positional via the
-- boom writes) and crop removal (banded at harvest). This is a marker, not a
-- mechanism, so a future reader knows the inert P map is agronomy, not a bug.
-- =========================================================
SpatialNutrients.PHOSPHORUS_BINDS = true
