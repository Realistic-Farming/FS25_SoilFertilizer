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

-- [SF-52] SF-52's own summary no longer uses this lattice: its pass enumerates
-- the complete parcel union at the execution grain with no omission ceiling
-- (invariant 4). SF-53 (GrowthCredit) conformed on 2026-09-09 and no longer
-- snaps to them. These two constants are RETAINED because SF-78 (GrowthBlock)
-- still snaps its header geometry to them; they are removed only when that
-- sibling conforms later in the coordinated set.
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
    -- [SF-52] farmlandId -> last-complete area-weighted summary (new shape:
    -- fractions + revisions + geometry + grains + areas + generation + hash).
    -- Derived and restartable; never persisted.
    self._summaries = {}
    -- [SF-52] farmlandId -> last-complete immutable ground-only region plan,
    -- and the fair recompute queue of farmlands with pending replacement work.
    self._plans = {}
    self._planGeneration = 0
    self._pendingFarmlands = {}
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

--- Fixed-precision fingerprint of ONE polygon (the union fingerprint's per-row
--- form), so an enumerated carrier square can name the specific source polygon it
--- sits in and overlaps resolve to the lowest lexicographic fingerprint.
function ViabilityMask.polygonFingerprint(verts)
    local pts = {}
    for _, v in ipairs(verts or {}) do
        pts[#pts + 1] = string.format('%.3f,%.3f', v.x, v.z)
    end
    return table.concat(pts, ';')
end

-- ============================================================
-- [SF-52] GROUND-ONLY PLAN ASSEMBLY (brief section 3.4; bar Group H)
--
-- Pure assembly over an enumerated region set. The engine raster enumeration
-- that produces the candidate regions is the in-game portion; given the
-- candidates, ownership, hashing and ordering are decidable and mirror the
-- reference contract exactly.
-- ============================================================

--- Carrier-ownership partition. For each physical carrier square, the farmland
--- with the greatest positive intersection area owns consequence writes; an
--- exact area tie selects the lowest numeric farmland id.
---@param candidates table[]  { {key, farmlandId, area}, ... }
---@return table owners  key -> winning candidate
function ViabilityMask.assignCarrierOwners(candidates)
    local owners = {}
    for _, c in ipairs(candidates or {}) do
        local prior = owners[c.key]
        if prior == nil or c.area > prior.area
            or (c.area == prior.area and c.farmlandId < prior.farmlandId) then
            owners[c.key] = c
        end
    end
    return owners
end

--- Deterministic ownership digest: sorted "key:farmlandId" pairs. Every farmland
--- plan in one generation carries the same digest.
function ViabilityMask.carrierOwnershipHash(owners)
    local keys, parts = {}, {}
    for key in pairs(owners or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. ':' .. tostring(owners[key].farmlandId)
    end
    return table.concat(parts, '|')
end

--- Area-weighted band fractions over the visited region set (brief 3.6). Unknown
--- area stays unknown and is NEVER counted as normal; the four fractions sum to
--- one within quantization. nil when nothing was visited.
function ViabilityMask.areaWeightedSummary(regions)
    local total, blocked, excellent, normal, unknown = 0, 0, 0, 0, 0
    for _, r in ipairs(regions or {}) do
        local a = r.area or 0
        total = total + a
        local band = r.band
        if     band == ViabilityMask.BAND_BLOCKED   then blocked   = blocked   + a
        elseif band == ViabilityMask.BAND_EXCELLENT then excellent = excellent + a
        elseif band == ViabilityMask.BAND_NORMAL    then normal    = normal    + a
        else                                             unknown   = unknown   + a end
    end
    if total <= 0 then return nil end
    return {
        blockedFrac   = blocked   / total,
        excellentFrac = excellent / total,
        normalFrac    = normal    / total,
        unknownFrac   = unknown   / total,
        eligibleArea  = total,
    }
end

--- Assemble the immutable ground-only plan from the enumerated regions. Within
--- one farmland, overlapping source polygons resolve to the lowest lexicographic
--- source-polygon fingerprint. planContentHash proves deterministic membership
--- and blocked content; resultHash describes the committed summary output; the
--- two are distinct. The plan is ground-only: no fruit identity, state or period
--- (brief 3.4; bar Group H).
---@param regions table[]  { {key, sourcePolygonFingerprint, blocked, area}, ... }
---@param resultHash string
---@param farmlandId number
---@param carrierOwners table  key -> owning candidate (from assignCarrierOwners)
function ViabilityMask.assembleGroundPlan(regions, resultHash, farmlandId, carrierOwners)
    local owned = {}
    for _, region in ipairs(regions or {}) do
        local prior = owned[region.key]
        if prior == nil or region.sourcePolygonFingerprint < prior.sourcePolygonFingerprint then
            owned[region.key] = region
        end
    end
    local ordered = {}
    for key, region in pairs(owned) do
        local ownerFarmlandId = (carrierOwners and carrierOwners[key]
            and carrierOwners[key].farmlandId) or farmlandId
        ordered[#ordered + 1] = {
            key = key,
            sourcePolygonFingerprint = region.sourcePolygonFingerprint,
            blocked = region.blocked,
            area = region.area,
            carrierOwnerFarmlandId = ownerFarmlandId,
            writableForFarmland = (ownerFarmlandId == farmlandId),
        }
    end
    table.sort(ordered, function(a, b) return a.key < b.key end)
    local ownershipDigest = ViabilityMask.carrierOwnershipHash(carrierOwners)
    local parts = { 'OWNERS=' .. ownershipDigest }
    for _, region in ipairs(ordered) do
        parts[#parts + 1] = table.concat({
            region.key, region.sourcePolygonFingerprint,
            region.blocked and 'B' or 'N', tostring(region.area),
            tostring(region.carrierOwnerFarmlandId), region.writableForFarmland and 'W' or 'R',
        }, ':')
    end
    return {
        regions = ordered,
        resultHash = resultHash,
        planContentHash = table.concat(parts, '|'),
        carrierOwnershipHash = ownershipDigest,
        fruitIdentity = nil, fruitState = nil, periodKey = nil,
    }
end

--- The live polygon-union fingerprint for a farmland, or nil when its geometry
--- is unresolvable. Used to detect a geometry change against a stored summary.
function ViabilityMask:_farmlandFingerprint(farmlandId)
    local soilSystem = self.manager and self.manager.soilSystem
    local polygons = soilSystem and type(soilSystem._getFarmlandPolygons) == 'function'
        and soilSystem:_getFarmlandPolygons(farmlandId) or nil
    if polygons == nil then return nil end
    return ViabilityMask.polygonUnionFingerprint(polygons)
end

--- Currentness of a farmland's last-complete summary (brief 3.6; bar Group E):
--- UNAVAILABLE (no summary and no work), PENDING (replacement/first work queued),
--- STALE (farmland or unscoped revision, or the polygon union, moved), or
--- CURRENT. An unrelated farmland's global advance does NOT stale this one.
---@return string status
function ViabilityMask:_summaryStatus(farmlandId)
    if self._pendingFarmlands[farmlandId] then return 'PENDING' end
    local s = self._summaries[farmlandId]
    if s == nil then return 'UNAVAILABLE' end

    local vm = self:_valueMaps()
    if vm == nil or type(vm.getGrowthInputToken) ~= 'function' then return 'STALE' end
    local token = vm:getGrowthInputToken(farmlandId)
    if token == nil then return 'STALE' end
    if s.farmlandInputRevision ~= token.farmlandRevision
        or s.unscopedInputRevision ~= token.unscopedRevision
        or s.polygonUnionFingerprint ~= self:_farmlandFingerprint(farmlandId) then
        return 'STALE'
    end
    return 'CURRENT'
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

--- Field-level area fractions plus the additive One Ground currentness metadata,
--- for consumers that work per farmland rather than per cell. SCS-020 may keep
--- reading the two original fractions; a current-aware consumer reads `current`
--- and getFieldGrowthSummaryStatus (brief 3.6). Returns a copy of the
--- last-complete summary; a stale last-complete summary stays readable, marked
--- current=false and pending=true while replacement work exists.
--- @return table|nil
function ViabilityMask:getFieldGrowthSummary(fieldId)
    if not self.enabled or fieldId == nil then return nil end
    local s = self._summaries[fieldId]
    if s == nil then return nil end
    local out = {}
    for k, v in pairs(s) do out[k] = v end
    local status = self:_summaryStatus(fieldId)
    out.current = (status == 'CURRENT')
    out.pending = (status == 'PENDING')
    return out
end

--- Current-aware status of the farmland's summary: UNAVAILABLE, PENDING, CURRENT
--- or STALE (brief 3.6). Never invents fractions.
--- @return string
function ViabilityMask:getFieldGrowthSummaryStatus(fieldId)
    if not self.enabled or fieldId == nil then return 'UNAVAILABLE' end
    return self:_summaryStatus(fieldId)
end

--- One immutable complete ground-only plan for a farmland, or nil (brief 3.4).
--- SF-52 owns its enumeration, identity and hashes; consequence modules never
--- build a second enumerator or digest.
--- @return table|nil
function ViabilityMask:getGrowthEligibleRegionPlan(farmlandId)
    if not self.enabled or farmlandId == nil then return nil end
    return self._plans[farmlandId]
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
    -- Establish the growth-input coordinates on first use, after seeding has
    -- produced coherent server truth (brief 3.1); idempotent + server-only, and
    -- it seeds any farmland bought since the last generation.
    if type(vm.establishGrowthInputRevisions) == 'function' then
        vm:establishGrowthInputRevisions(self:_currentFarmlandIds())
    end
    local grain = self:_executionGrain(vm)
    if grain == nil then return 0 end
    local soilSystem = self.manager and self.manager.soilSystem
    if soilSystem == nil or soilSystem.fieldData == nil then return 0 end

    -- Resolve one coherent generation of live geometry.
    if type(soilSystem._invalidateFarmlandPolygons) == 'function' then
        soilSystem:_invalidateFarmlandPolygons()
    end
    self._planGeneration = self._planGeneration + 1
    local generation = self._planGeneration
    local monotonicDay = self:_monotonicDay()

    -- Enumerate every tracked farmland's parcel union into this generation, then
    -- derive ONE global carrier-ownership partition before committing, so a
    -- carrier square shared by touching parcels resolves to a single owner
    -- (brief 3.4). Complete work with no omission ceiling.
    --
    -- NOTE (perf gate #6, in-game measured): this v1 enumerates every farmland
    -- fully per daily pass. The per-frame cursor/time budget and any measured
    -- execution-grain coarsening (brief 3.5) are runtime tuning deferred to the
    -- in-game acceptance measurements; the contract here is complete, atomic and
    -- deterministic regardless of how the work is later spread across frames.
    local perFarmland, allCandidates = {}, {}
    for farmlandId in pairs(soilSystem.fieldData) do
        local polygons = (type(soilSystem._getFarmlandPolygons) == 'function')
            and soilSystem:_getFarmlandPolygons(farmlandId) or nil
        if polygons ~= nil then
            local regions, candidates = self:_enumerateFarmland(farmlandId, polygons, grain, vm)
            if #regions > 0 then
                perFarmland[farmlandId] = { regions = regions, polygons = polygons }
                for _, c in ipairs(candidates) do allCandidates[#allCandidates + 1] = c end
            end
        end
    end

    local carrierOwners = ViabilityMask.assignCarrierOwners(allCandidates)
    local committed = 0
    for farmlandId, data in pairs(perFarmland) do
        if self:_commitFarmland(farmlandId, data, carrierOwners, generation, monotonicDay, grain, vm) then
            committed = committed + 1
        end
        self._pendingFarmlands[farmlandId] = nil
    end
    return committed
end

--- Execution grain: the loaded truth grain by default. No fixed lattice or
--- omission ceiling (brief 3.4; invariant 4).
function ViabilityMask:_executionGrain(vm)
    local grain = (type(vm.getGrainMetres) == 'function') and vm:getGrainMetres() or nil
    if type(grain) ~= 'number' or grain <= 0 then return nil end
    return grain
end

--- In-game day coordinate from Time Guard context, else the host fallback. Never
--- environment.currentDay (brief 3.7).
function ViabilityMask:_monotonicDay()
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg ~= nil and type(tg.getContext) == 'function' then
        local ok, ctx = pcall(function() return tg:getContext() end)
        if ok and type(ctx) == 'table' and type(ctx.monotonicDay) == 'number' then
            return ctx.monotonicDay
        end
    end
    if type(self._currentMonotonicDay) == 'number' then return self._currentMonotonicDay end
    return nil
end

--- The source polygon for a carrier-square centre: the lowest-fingerprint field
--- polygon on the farmland that contains the point, or nil when the centre is in
--- a gap between the parcel's fields (gaps are never filled).
function ViabilityMask:_squareSource(x, z, polygons)
    local best
    for _, verts in ipairs(polygons) do
        if ViabilityMask._pointInPolygon(x, z, verts) then
            local fp = ViabilityMask.polygonFingerprint(verts)
            if best == nil or fp < best then best = fp end
        end
    end
    return best
end

--- Enumerate a farmland's parcel union at the execution grain into carrier-square
--- region candidates. Reads the value maps inline (getCellGrowthInfo is the
--- single-point public API; the bulk pass must not re-resolve farmland geometry
--- per square). Each square is sampled once at its centre on a world-origin
--- aligned grid, so a square shared by touching parcels carries ONE global key.
function ViabilityMask:_enumerateFarmland(farmlandId, polygons, grain, vm)
    local regions, candidates = {}, {}
    local area = grain * grain
    local minX, maxX, minZ, maxZ
    for _, verts in ipairs(polygons) do
        for _, v in ipairs(verts) do
            if minX == nil or v.x < minX then minX = v.x end
            if maxX == nil or v.x > maxX then maxX = v.x end
            if minZ == nil or v.z < minZ then minZ = v.z end
            if maxZ == nil or v.z > maxZ then maxZ = v.z end
        end
    end
    if minX == nil then return regions, candidates end

    local half = grain * 0.5
    for gx = math.floor(minX / grain), math.floor(maxX / grain) do
        local cx = gx * grain + half
        for gz = math.floor(minZ / grain), math.floor(maxZ / grain) do
            local cz = gz * grain + half
            local srcFp = self:_squareSource(cx, cz, polygons)
            if srcFp ~= nil then
                local n = vm:readValueAtWorld('nitrogen', cx, cz)
                local compaction = vm:readValueAtWorld('compaction', cx, cz)
                local band = ViabilityMask.combine({
                    n = ViabilityMask.bandNitrogen(n),
                    compaction = ViabilityMask.bandCompaction(compaction),
                    moisture = nil,
                })
                local key = gx .. ':' .. gz
                regions[#regions + 1] = {
                    key = key, sourcePolygonFingerprint = srcFp,
                    blocked = (band == ViabilityMask.BAND_BLOCKED),
                    band = band, area = area,
                }
                candidates[#candidates + 1] = { key = key, farmlandId = farmlandId, area = area }
            end
        end
    end
    return regions, candidates
end

--- Commit one farmland's complete plan and area-weighted summary atomically,
--- pinning the farmland+unscoped revisions and polygon-union fingerprint at
--- enumeration. A same-farmland or unscoped write, or a geometry change, that
--- lands before this commit cancels it (getGrowthInputToken re-read); an
--- unrelated farmland's global advance does not. No partial fraction is exposed.
function ViabilityMask:_commitFarmland(farmlandId, data, carrierOwners, generation, monotonicDay, grain, vm)
    local weighted = ViabilityMask.areaWeightedSummary(data.regions)
    if weighted == nil then return false end
    local token = vm:getGrowthInputToken(farmlandId)
    if token == nil then return false end
    local fingerprint = ViabilityMask.polygonUnionFingerprint(data.polygons)

    local resultHash = string.format('%d|%.6f|%.6f|%.6f|%.6f', generation,
        weighted.blockedFrac, weighted.excellentFrac, weighted.normalFrac, weighted.unknownFrac)
    local plan = ViabilityMask.assembleGroundPlan(data.regions, resultHash, farmlandId, carrierOwners)
    plan.planId                = string.format('%d:%d', farmlandId, generation)
    plan.fieldId               = farmlandId
    plan.globalInputRevision   = token.globalRevision
    plan.farmlandInputRevision = token.farmlandRevision
    plan.unscopedInputRevision = token.unscopedRevision
    plan.polygonUnionFingerprint = fingerprint
    plan.truthGrainMetres      = vm:getGrainMetres()
    plan.executionGrainMetres  = grain
    plan.settingsFingerprint   = ''       -- SF-52 adds no setting
    plan.releaseGateState      = 'LOCKED'

    self._plans[farmlandId] = plan
    self._summaries[farmlandId] = {
        blockedFrac = weighted.blockedFrac, excellentFrac = weighted.excellentFrac,
        normalFrac  = weighted.normalFrac,  unknownFrac   = weighted.unknownFrac,
        globalInputRevision   = token.globalRevision,
        farmlandInputRevision = token.farmlandRevision,
        unscopedInputRevision = token.unscopedRevision,
        summaryGeneration     = generation,
        polygonUnionFingerprint = fingerprint,
        truthGrainMetres = vm:getGrainMetres(), executionGrainMetres = grain,
        eligibleArea = weighted.eligibleArea, visitedArea = weighted.eligibleArea,
        coverage = 1, asOfMonotonicDay = monotonicDay, resultHash = resultHash,
    }
    return true
end

--- Queue one farmland for a recompute; repeated dirties coalesce (brief 3.5).
--- Marks its summary PENDING until the next pass commits a replacement.
function ViabilityMask:requestRecompute(farmlandId)
    if farmlandId ~= nil then self._pendingFarmlands[farmlandId] = true end
    return true
end

--- Host monotonic-day fallback, used when Time Guard is absent (brief 3.7).
function ViabilityMask:setCurrentMonotonicDay(day)
    if type(day) == 'number' then self._currentMonotonicDay = day end
end

--- Every current public farmland id, so each owned farmland has a growth-input
--- token from the first generation (brief 3.2). A farmland bought later is
--- seeded on the next pass; one never seen is minted on its first observed write.
function ViabilityMask:_currentFarmlandIds()
    local ids = {}
    local fm = g_farmlandManager
    if fm == nil then return ids end
    local farmlands
    if type(fm.getFarmlands) == 'function' then
        local ok, result = pcall(function() return fm:getFarmlands() end)
        if ok then farmlands = result end
    end
    farmlands = farmlands or fm.farmlands
    if type(farmlands) == 'table' then
        for id in pairs(farmlands) do
            if type(id) == 'number' then ids[#ids + 1] = id end
        end
    end
    return ids
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

-- [SF-52] The public setEnabled surface is removed (brief section 4, Core
-- services): it was an unregistered Administrative control. self.enabled remains
-- only as a private internal circuit-breaker.

function ViabilityMask:delete()
    -- Unregister the Time Guard accrual when supported (brief 3.7).
    if self._tgAccrualRegistered then
        local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
        if tg ~= nil and type(tg.unregisterAccrual) == 'function' then
            pcall(function() tg:unregisterAccrual(ViabilityMask.DAILY_ACCURAL_ID) end)
        end
        self._tgAccrualRegistered = false
    end
    -- Clear plans, summaries, status and the fallback cursor; every getter
    -- becomes unavailable. SoilValueMaps and sibling state belong to their owners
    -- (SoilValueMaps discards its own growth-input coordinates on its delete).
    self.isInitialized        = false
    self._summaries           = {}
    self._plans               = {}
    self._pendingFarmlands    = {}
    self._planGeneration      = 0
    self._currentMonotonicDay = nil
end
