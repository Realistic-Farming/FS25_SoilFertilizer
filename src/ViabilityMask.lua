-- ============================================================
-- ViabilityMask.lua  (SF-52 v1)
--
-- THE 2M GROWTH FAMILY'S FOUNDATION. A cell whose soil condition is bad does
-- not deserve to advance like one whose soil is good. This computes that
-- judgement per cell from SoilFertilizer's own data, and PUBLISHES it as the
-- contract three other systems are waiting on.
--
-- SCOPE IS v1, PER ARISSANI'S SPLIT RULING (2026-08-09). Steps 1 to 4 of the
-- brief (read, classify, compose) plus the whole getter family build here.
-- STEP 5, THE `setGrowthMask` ENGINE WRITE, IS DELIBERATELY NOT BUILT and is
-- held at stage 3 with its route question open. Do not add it here without
-- that ruling: the slot is shared with MissionManager's access map, and
-- `setGrowthMask` fans one map to two engine natives whose polarities point
-- opposite ways.
--
-- WHAT v1 IS FOR: SF-53 (growth credit), SF-54 (the growth surface) and
-- SCS-020 (transpiration feedback) all name `getCellGrowthInfo` or
-- `getFieldGrowthSummary` as their entire data contract. None of them could
-- start while nobody published it. That is the whole point of shipping this
-- half now.
--
-- The family ships LOCKED, so nothing here reaches a player yet.
-- ============================================================

ViabilityMask = ViabilityMask or {}
local ViabilityMask_mt = Class(ViabilityMask)

-- ── THE THREE-BAND DIAL FAMILY ──────────────────────────────
-- This is the DEFINING declaration; SF-53 and SF-14 cite these and must never
-- redefine them. Recorded AWAITING-SPINE with the neutral defaults below, and
-- registered as ONE GROUPED declaration when the Option-Scaling Spine ships,
-- per steward condition 1. Never six loose dials, and never an SF-local knob.
ViabilityMask.N_BLOCKED_BELOW      = 20.0   -- ppm
ViabilityMask.N_EXCELLENT_ABOVE    = 60.0   -- ppm
ViabilityMask.COMPACTION_BLOCKED_ABOVE   = 70.0   -- 0..100 scale
ViabilityMask.COMPACTION_EXCELLENT_BELOW = 30.0   -- 0..100 scale

-- Band names. Deliberately strings: they cross a mod boundary in the published
-- getter, where a magic number would be a decoding job for every consumer.
ViabilityMask.BAND_BLOCKED   = 'blocked'
ViabilityMask.BAND_NORMAL    = 'normal'
ViabilityMask.BAND_EXCELLENT = 'excellent'

-- The per-period pass samples on a bounded grid rather than every pixel: the
-- summary is an area fraction and does not get more honest from more samples
-- than the field has variation.
ViabilityMask.SAMPLE_STEP_M  = 8
ViabilityMask.MAX_SAMPLES    = 600

-- Time Guard accrual. Priority 96 sits AFTER the moisture store (SCS-018, 90)
-- and AFTER establishment failure (SF-18, 95), so the ground has settled and
-- the dead have been counted before anyone judges the day's viability.
ViabilityMask.DAILY_ACCURAL_ID       = 'SoilFertilizer_viability_daily'
ViabilityMask.DAILY_ACCURAL_PRIORITY = 96

function ViabilityMask.new(manager)
    local self = setmetatable({}, ViabilityMask_mt)
    self.manager = manager
    self.isInitialized = false
    self._tgAccrualRegistered = false
    -- fieldId -> { blockedFrac, excellentFrac, samples, day }
    self._summaries = {}
    -- The mask enable. RULED DEFAULT-ON by Tyson (2026-08-05): soil condition is
    -- a difficulty-neutral fact, not a difficulty setting. Kept as an
    -- Administrative control rather than a player dial.
    self.enabled = true
    return self
end

function ViabilityMask:initialize()
    self.isInitialized = true
end

-- ============================================================
-- THE INPUTS
-- ============================================================

--- SoilFertilizer's own per-cell store. Read-only here, always.
function ViabilityMask:_valueMaps()
    local soilSystem = self.manager and self.manager.soilSystem
    local vm = soilSystem and soilSystem.valueMaps
    if vm ~= nil and vm.available then return vm end
    return nil
end

-- [SF-52] The SCS moisture facade discovery is gone: moisture is no longer read
-- into the active point path (bandMoisture stays a deliberate nil; see its note).

-- ============================================================
-- THE THREE BANDS
-- Pure classifiers. No engine, no state, so the bench drives them directly.
-- ============================================================

--- Nitrogen band. nil input is NOT a block: an unreadable layer means we do not
--- know, and "we do not know" must never be rendered as "this ground is dead".
function ViabilityMask.bandNitrogen(ppm)
    if type(ppm) ~= 'number' then return nil end
    if ppm < ViabilityMask.N_BLOCKED_BELOW then return ViabilityMask.BAND_BLOCKED end
    if ppm > ViabilityMask.N_EXCELLENT_ABOVE then return ViabilityMask.BAND_EXCELLENT end
    return ViabilityMask.BAND_NORMAL
end

--- Compaction band, on the existing 0..100 scale. Higher is worse, so the
--- comparisons invert relative to nitrogen.
function ViabilityMask.bandCompaction(value)
    if type(value) ~= 'number' then return nil end
    if value > ViabilityMask.COMPACTION_BLOCKED_ABOVE then return ViabilityMask.BAND_BLOCKED end
    if value < ViabilityMask.COMPACTION_EXCELLENT_BELOW then return ViabilityMask.BAND_EXCELLENT end
    return ViabilityMask.BAND_NORMAL
end

--- Moisture band.
---
--- INERT IN v1, AND DELIBERATELY SO. The brief specifies this band against
--- `FruitTypeDesc.minWaterLitersPerSqm` / `maxWaterLitersPerSqm`. Certified at
--- the decompile, those fields are STANDING WATER IN LITRES PER SQUARE METRE:
--- `RiceFieldUpdateTask:performPerlinNoiseDestruction` (`:22-38`) compares them
--- against `waterFillLevelPerSqm`, the water lying on a rice paddy.
---
--- SCS's `getMoisture` returns a 0..1 SOIL MOISTURE FRACTION. These are
--- different physical quantities and comparing them is not a rounding error, it
--- is a category error: a 0..1 value sits below any litres-per-sqm minimum, so
--- EVERY crop shipping a window would classify as permanently BLOCKED and
--- growth would stop on it forever, silently.
---
--- So this returns nil until the design side rules what defines the window in
--- SCS's units. nil is the brief's own specified fallback for a crop with no
--- window ("moisture does not block for that crop"), which makes inert the
--- correct and honest behaviour rather than a stub.
function ViabilityMask.bandMoisture(_moisture01, _fruitDesc, _growthState)
    return nil
end

--- Combine the three. BLOCKED if any band that has an opinion says BLOCKED;
--- EXCELLENT only when at least one is excellent and none is blocked.
--- Bands that returned nil simply do not vote.
function ViabilityMask.combine(bands)
    local anyBlocked, anyExcellent, anyKnown = false, false, false
    for _, band in pairs(bands or {}) do
        if band ~= nil then
            anyKnown = true
            if band == ViabilityMask.BAND_BLOCKED then anyBlocked = true end
            if band == ViabilityMask.BAND_EXCELLENT then anyExcellent = true end
        end
    end
    if not anyKnown then return nil end
    if anyBlocked then return ViabilityMask.BAND_BLOCKED end
    if anyExcellent then return ViabilityMask.BAND_EXCELLENT end
    return ViabilityMask.BAND_NORMAL
end

-- ============================================================
-- [SF-52] PARCEL-UNION GEOMETRY (brief section 2; invariant 2)
--
-- Farmland id is NOT one engine field polygon. Point membership, the region
-- plan and the area-weighted summary all span the COMPLETE polygon collection
-- for the farmland. The gaps between a parcel's separate fields are never
-- filled: a point must land inside an actual field polygon, not merely inside
-- the parcel's bounding hull. Pure helpers, so the bench drives them directly.
-- ============================================================

--- Strict terrain domain [-half, half) on both axes. Runs BEFORE any value-map
--- read because the point transform clamps an outside coordinate to the nearest
--- edge pixel (brief 3.3), which would otherwise read a false in-field value for
--- an off-map point.
function ViabilityMask.inTerrainDomain(x, z, half)
    if type(x) ~= 'number' or type(z) ~= 'number' or type(half) ~= 'number' then return false end
    return x >= -half and x < half and z >= -half and z < half
end

--- Point in ONE polygon, boundary INCLUSIVE (a point on an edge is inside). Ray
--- cast with an on-segment pre-test so a boundary sample is never dropped.
function ViabilityMask._pointInPolygon(x, z, verts)
    if type(verts) ~= 'table' or #verts < 3 then return false end
    local n = #verts
    local inside = false
    local j = n
    for i = 1, n do
        local a, b = verts[j], verts[i]
        local cross = (x - a.x) * (b.z - a.z) - (z - a.z) * (b.x - a.x)
        if math.abs(cross) <= 1e-9 then
            local dot  = (x - a.x) * (b.x - a.x) + (z - a.z) * (b.z - a.z)
            local len2 = (b.x - a.x) ^ 2 + (b.z - a.z) ^ 2
            if dot >= 0 and dot <= len2 then return true end
        end
        if (a.z > z) ~= (b.z > z) then
            local xAtZ = (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x
            if x < xAtZ then inside = not inside end
        end
        j = i
    end
    return inside
end

--- Point in ANY polygon of the parcel's union collection.
function ViabilityMask.pointInFarmlandUnion(x, z, polygons)
    for _, verts in ipairs(polygons or {}) do
        if ViabilityMask._pointInPolygon(x, z, verts) then return true end
    end
    return false
end

--- Deterministic fingerprint of the parcel's polygon union. Each polygon's
--- vertices render to fixed-precision text and the polygon rows are sorted, so
--- field-manager iteration order cannot change the fingerprint. Identical
--- geometry shares a fingerprint; any vertex change alters it (brief 3.4).
function ViabilityMask.polygonUnionFingerprint(polygons)
    local rows = {}
    for _, verts in ipairs(polygons or {}) do
        local pts = {}
        for _, v in ipairs(verts) do
            pts[#pts + 1] = string.format('%.3f,%.3f', v.x, v.z)
        end
        rows[#rows + 1] = table.concat(pts, ';')
    end
    table.sort(rows)
    return table.concat(rows, '|')
end

-- ============================================================
-- THE PUBLISHED CONTRACT (brief section 4, Provides)
--
-- These two getters ARE this build's reason to exist. SF-53, SF-54 and SCS-020
-- bind to them. Both are pcall-safe for the caller, nil off-field, and never
-- throw across the mod boundary.
-- ============================================================

--- Per-cell growth judgement at a world position. The public `fieldId` argument
--- means FARMLAND id (kept for compatibility). Returns the stable original
--- fields plus additive provenance, or nil unless the point is proved
--- (brief 3.3). A returned table always describes proven TRUTH at one place.
--- @return table|nil { blocked, blockedBy, bands, n, p, k, credit=nil,
---                     capturedEfficiency=nil, fieldId, role="TRUTH",
---                     grainMetres, growthInputRevision, farmlandInputRevision,
---                     unscopedInputRevision }
function ViabilityMask:getCellGrowthInfo(fieldId, x, z)
    if not self.enabled then return nil end
    if fieldId == nil or type(x) ~= 'number' or type(z) ~= 'number' then return nil end

    local vm = self:_valueMaps()
    if vm == nil or type(vm.getGrowthInputToken) ~= 'function' then return nil end

    -- (1) Server truth must be coherent: without established growth-input
    -- coordinates there is no proof the ground under this point is not mid-write.
    local before = vm:getGrowthInputToken(fieldId)
    if before == nil then return nil end

    -- (2) Strict terrain domain [-half, half), BEFORE any value-map read: the
    -- point transform clamps an outside coordinate to the nearest edge pixel, so
    -- an off-map point would otherwise read a false in-field value.
    local half = (vm.terrainSize or 0) * 0.5
    if half <= 0 or not ViabilityMask.inTerrainDomain(x, z, half) then return nil end

    -- (3) The named farmland must exist.
    local fm = g_farmlandManager
    if fm == nil or type(fm.getFarmlandById) ~= 'function' then return nil end
    local okFarm, farmland = pcall(function() return fm:getFarmlandById(fieldId) end)
    if not okFarm or farmland == nil then return nil end

    -- (4) The point must lie inside or on the boundary of ANY field polygon in
    -- this farmland's deterministic union. Gaps between the parcel's fields are
    -- never filled.
    local soilSystem = self.manager and self.manager.soilSystem
    local polygons = soilSystem and type(soilSystem._getFarmlandPolygons) == 'function'
        and soilSystem:_getFarmlandPolygons(fieldId) or nil
    if polygons == nil or not ViabilityMask.pointInFarmlandUnion(x, z, polygons) then return nil end

    -- Read the four growth inputs once. N/compaction keep their classifiers; P/K
    -- ride raw for the family. The SCS moisture read is gone from the active
    -- path (it was a units category error, see bandMoisture); moisture stays nil.
    local nitrogen   = vm:readValueAtWorld('nitrogen', x, z)
    local phosphorus = vm:readValueAtWorld('phosphorus', x, z)
    local potassium  = vm:readValueAtWorld('potassium', x, z)
    local compaction = vm:readValueAtWorld('compaction', x, z)

    -- (5) At least one SF voting input must be known.
    if nitrogen == nil and compaction == nil then return nil end

    -- (6) Farmland and unscoped revisions must match before and after the read:
    -- a same-farmland or unscoped write during the read cancels it; a write
    -- proven to ANOTHER farmland does not.
    local after = vm:getGrowthInputToken(fieldId)
    if after == nil
       or before.farmlandRevision ~= after.farmlandRevision
       or before.unscopedRevision ~= after.unscopedRevision then return nil end

    local bands = {
        n          = ViabilityMask.bandNitrogen(nitrogen),
        compaction = ViabilityMask.bandCompaction(compaction),
        moisture   = nil,
    }
    local overall = ViabilityMask.combine(bands)

    return {
        blocked = (overall == ViabilityMask.BAND_BLOCKED),
        blockedBy = {
            n          = bands.n          == ViabilityMask.BAND_BLOCKED,
            compaction = bands.compaction == ViabilityMask.BAND_BLOCKED,
            moisture   = false,
        },
        bands = bands,
        -- The family's raw input set for members that consume more than the
        -- mask's two. SF-14's capture reads these; nil means unreadable here, and
        -- "we do not know" must never capture as "dead".
        n = nitrogen,
        p = phosphorus,
        k = potassium,
        -- Sibling provenance stays nil until its owner supplies a current
        -- matching witness (brief 3.3; invariant 9). No sibling reader is called
        -- here: GrowthCredit is stored against first-polygon geometry and
        -- ZoneYield's captured read has no matching farmland-union witness.
        credit = nil,
        capturedEfficiency = nil,
        -- Additive provenance.
        fieldId               = fieldId,
        role                  = 'TRUTH',
        grainMetres           = vm:getGrainMetres(),
        growthInputRevision   = after.globalRevision,
        farmlandInputRevision = after.farmlandRevision,
        unscopedInputRevision = after.unscopedRevision,
    }
end

--- Field-level area fractions, for consumers that work per field rather than
--- per cell. SCS-020 (transpiration feedback) is the first, scaling a field's
--- moisture draw by how much of it is struggling.
--- @return table|nil { blockedFrac, excellentFrac }
function ViabilityMask:getFieldGrowthSummary(fieldId)
    if not self.enabled or fieldId == nil then return nil end
    local s = self._summaries[fieldId]
    if s == nil then return nil end
    return { blockedFrac = s.blockedFrac, excellentFrac = s.excellentFrac }
end

--- SF-53's growth credit, resolved through the same header snap SF-53 itself
--- derives (origin from the survey's first sample centre, floor index, step
--- coarsening per MAX_SAMPLES). Reads the ephemeral store only; nil is neutral
--- (no accrual yet, or the field is not tracked) and every consumer treats it
--- as such. Returns days of credit at the cell, or nil.
function ViabilityMask:_readCredit(fieldId, x, z)
    local gc = self.manager and self.manager.growthCredit
    if gc == nil or type(gc.readCreditAt) ~= 'function' then return nil end
    local ok, credit = pcall(function() return gc:readCreditAt(fieldId, x, z) end)
    if not ok then return nil end
    return credit
end

--- SF-14's captured yield efficiency. Reads the captured layer through the
--- manager's zone-yield subsystem; nil when SF-14 is not live (the neutral
--- reading every consumer treats as such). Percent on the layer, returned as a
--- 0.7..1.15 multiplier like the mask's own bands.
function ViabilityMask:_readCapturedEfficiency(fieldId, x, z)
    local zy = self.manager and self.manager.zoneYield
    if zy == nil or type(zy.readCapturedEfficiency) ~= 'function' then return nil end
    local ok, eff = pcall(function() return zy:readCapturedEfficiency(fieldId, x, z) end)
    if not ok then return nil end
    return eff
end

-- ============================================================
-- THE PER-PERIOD PASS (brief section 3, steps 1 to 4)
--
-- Reads the family's input set ONCE per field per period, classifies, and
-- composes. In v1 the composed result feeds the field summary; in v2 the same
-- array is what the engine write would hand over, which is why v2 lands on top
-- of this with no rework.
-- ============================================================

function ViabilityMask:runPass()
    if not self.enabled then return 0 end
    local vm = self:_valueMaps()
    if vm == nil then return 0 end
    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil or soilSystem.fieldData == nil then return 0 end

    local passed = 0
    for fieldId in pairs(soilSystem.fieldData) do
        if self:_passField(fieldId, soilSystem) then passed = passed + 1 end
    end
    return passed
end

function ViabilityMask:_passField(fieldId, soilSystem)
    local field = soilSystem.fieldData and soilSystem.fieldData[fieldId]
    if field == nil then return false end
    if type(soilSystem._getFieldPolyVerts) ~= 'function' then return false end
    local verts = soilSystem:_getFieldPolyVerts(fieldId, field)
    if verts == nil or #verts < 3 then return false end

    local counts = ViabilityMask.summariseSamples(
        self:_sampleField(fieldId, verts))
    if counts == nil then return false end

    counts.day = (g_currentMission and g_currentMission.environment
                  and g_currentMission.environment.currentMonotonicDay) or nil
    self._summaries[fieldId] = counts
    return true
end

--- Walk the field on a bounded grid, classifying each sample.
--- Returns a list of overall bands (strings), skipping off-field points.
function ViabilityMask:_sampleField(fieldId, verts)
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        local v = verts[i]
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end

    local step = ViabilityMask.SAMPLE_STEP_M
    local est = math.ceil((maxX - minX) / step) * math.ceil((maxZ - minZ) / step)
    if est > ViabilityMask.MAX_SAMPLES then
        step = step * math.ceil(math.sqrt(est / ViabilityMask.MAX_SAMPLES))
    end

    local out, n = {}, 0
    local x = minX + step * 0.5
    while x <= maxX and n < ViabilityMask.MAX_SAMPLES do
        local z = minZ + step * 0.5
        while z <= maxZ and n < ViabilityMask.MAX_SAMPLES do
            local info = self:getCellGrowthInfo(fieldId, x, z)
            if info ~= nil then
                n = n + 1
                out[n] = ViabilityMask.combine(info.bands)
            end
            z = z + step
        end
        x = x + step
    end
    return out
end

--- Turn a list of bands into the published area fractions. Pure, so the bench
--- can prove the fractions without a map under it.
function ViabilityMask.summariseSamples(bands)
    local n = bands and #bands or 0
    if n == 0 then return nil end
    local blocked, excellent = 0, 0
    for i = 1, n do
        if bands[i] == ViabilityMask.BAND_BLOCKED then blocked = blocked + 1
        elseif bands[i] == ViabilityMask.BAND_EXCELLENT then excellent = excellent + 1 end
    end
    return {
        blockedFrac   = blocked / n,
        excellentFrac = excellent / n,
        samples       = n,
    }
end

-- ============================================================
-- CADENCE
-- Time Guard's `simulation` flow class, for catch-up bookkeeping only. This
-- does not gate any engine tick in v1 because v1 makes no engine call.
-- ============================================================

function ViabilityMask:registerDailyAccrual()
    if self._tgAccrualRegistered then return true end
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.registerAccrual) ~= 'function' then return false end

    -- Version-skew guard, the same one SF-18 carries: an older Time Guard
    -- silently coerces an unknown flowClass to calendar, which would run this
    -- on a clock it was never designed for.
    if tg.flowClasses ~= nil and tg.flowClasses.simulation ~= true then
        return false
    end

    local ok = pcall(function()
        tg:registerAccrual(ViabilityMask.DAILY_ACCURAL_ID, {
            cadence = 'day',
            flowClass = 'simulation',
            firstPeriodPolicy = 'skip',
            priority = ViabilityMask.DAILY_ACCURAL_PRIORITY,
            onSettle = function() self:runPass() end,
        })
    end)
    if ok then self._tgAccrualRegistered = true end
    return ok
end

--- The mask enable (Administrative, server-authoritative, shared-world).
--- The one control this feature adds. Default-on by ruling.
function ViabilityMask:setEnabled(enabled)
    self.enabled = enabled ~= false
    return self.enabled
end

function ViabilityMask:delete()
    self.isInitialized = false
    self._summaries = {}
end
