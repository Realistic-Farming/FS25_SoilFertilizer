-- SF-52 One Ground provider-conformance bar v7.
--
-- GROUP A loads the current shipped SF-52 owner and proves the conformance
-- repair is not built at SoilFertilizer tip
-- c99e202a1da31e34eaeea16a10f128bfe6d8db8f. The growth owner bytes are
-- unchanged from 9badc5f. When implementation lands,
-- Group A is expected to go red and Stage 6A must re-point these tripwires at
-- the shipped surfaces.
--
-- GROUPS B through H model the pure contract fixed by SF-52-SDS.md v2.4.
-- They prove reference behavior only. They do not prove engine map coverage,
-- polygon clipping, frame time, memory, save duration, multiplayer delivery or
-- runtime hook liveness.
--
-- All field shapes, coordinates, region counts, revisions and work budgets are
-- synthetic branch-distinguishing probes. No synthetic number below is a
-- production budget or balance magnitude.
--!load: src/maps/SoilValueMaps.lua, src/ViabilityMask.lua

-- ============================================================
-- GROUP A: CURRENT SHIPPED NON-CONFORMANCE.
-- SDS sections 0, 4 and 5.
-- ============================================================
do
    local maps = SoilValueMaps.new()
    -- [SF-52 Stage 6A re-point] The growth-input revision family now ships. A fresh
    -- instance still exposes no revision (bootstrap: unavailable until
    -- establishGrowthInputRevisions runs after a coherent map load), and the getter
    -- now exists and honestly returns nil until then.
    T.eq("A1 SHIPPED growth-input revision is nil before coherent init", maps.growthInputRevision, nil)
    T.eq("A2 SHIPPED SoilValueMaps exposes the growth-input revision getter",
        type(maps.getGrowthInputRevision), "function")
    T.eq("A2b SHIPPED revision getter returns nil before coherent init",
        maps:getGrowthInputRevision(), nil)
    T.eq("A2c SHIPPED token getter returns nil for a farmland before init",
        maps:getGrowthInputToken(7), nil)

    local stubMaps = { available = true }
    function stubMaps:readValueAtWorld(key, _x, _z)
        if key == "nitrogen" then return 40 end
        if key == "phosphorus" then return 50 end
        if key == "potassium" then return 60 end
        if key == "compaction" then return 20 end
        return nil
    end
    local current = ViabilityMask.new({ soilSystem = { valueMaps = stubMaps } })
    -- [SF-52 Stage 6A re-point] The point getter now proves its inputs before it
    -- answers, so the old first-match, unproved-point table is gone. This pure bar
    -- has no engine farmland manager or map, so a live read correctly resolves to
    -- nil; the positive provenance (role, grainMetres, the three revisions) is
    -- proven by the Group C model and the in-game SF52_RUNTIME_ACCEPTANCE harness.
    T.eq("A3 SHIPPED point getter is a function", type(current.getCellGrowthInfo), "function")
    T.eq("A4 SHIPPED point getter rejects an unproved / out-of-domain point",
        current:getCellGrowthInfo(999, 999999, 999999), nil)
    T.eq("A5 SHIPPED point getter rejects a nil farmland id",
        current:getCellGrowthInfo(nil, 0, 0), nil)
    T.eq("A6 SHIPPED point getter rejects a non-numeric coordinate",
        current:getCellGrowthInfo(7, "x", 0), nil)

    -- [SF-52 Stage 6A re-point] The summary is now the area-weighted One Ground
    -- shape: no sample count, no source `day`, carrying the additive revisions
    -- plus a boolean currentness, and a status getter now exists.
    current._summaries[7] = {
        blockedFrac = 0.25, excellentFrac = 0.50, normalFrac = 0.25, unknownFrac = 0,
        globalInputRevision = 5, farmlandInputRevision = 3, unscopedInputRevision = 2,
        summaryGeneration = 1, polygonUnionFingerprint = "g1",
        truthGrainMetres = 2, executionGrainMetres = 2,
        eligibleArea = 100, visitedArea = 100, coverage = 1,
        asOfMonotonicDay = 18, resultHash = "h",
    }
    local summary = current:getFieldGrowthSummary(7)
    T.eq("A7 SHIPPED summary carries no sample count", summary.samples, nil)
    T.eq("A8 SHIPPED summary carries no source day", summary.day, nil)
    T.eq("A9 SHIPPED summary carries the additive global input revision",
        summary.globalInputRevision, 5)
    T.eq("A10 SHIPPED summary carries a boolean currentness", type(summary.current), "boolean")
    T.eq("A11 SHIPPED provider exposes the summary-status getter",
        type(current.getFieldGrowthSummaryStatus), "function")
    -- [SF-52 Stage 6A re-point] SF-52's summary no longer uses the 8 m / 600
    -- lattice (it enumerates the complete parcel union), but the two constants
    -- are RETAINED for the SF-53/SF-78 header snap until those siblings conform.
    T.eq("A12 lattice constant retained for SF-53/SF-78 header snap",
        ViabilityMask.SAMPLE_STEP_M, 8)
    T.eq("A13 sample-ceiling constant retained for SF-53/SF-78 header snap",
        ViabilityMask.MAX_SAMPLES, 600)
    T.eq("A14 SHIPPED provider removed the unregistered public enable method",
        current.setEnabled, nil)
    local witnessless = ViabilityMask.new({
        soilSystem = { valueMaps = stubMaps },
        growthCredit = { readCreditAt = function() return 3 end },
        zoneYield = { readCapturedEfficiency = function() return 0.9 end },
    })
    -- [SF-52 re-point] The point getter no longer calls the sibling readers, so a
    -- witnessless growthCredit/zoneYield can no longer leak an unproven credit or
    -- captured efficiency onto the point table (invariant 9). With no proven point
    -- the getter returns nil rather than a leaked table.
    T.eq("A15 SHIPPED getter does not leak witnessless sibling credit/efficiency",
        witnessless:getCellGrowthInfo(999, 50, 0), nil)
end

local READ_KEYS = {
    nitrogen = true,
    phosphorus = true,
    potassium = true,
    compaction = true,
}

local function newRevisionOwner()
    return {
        globalRevision = nil,
        unscopedRevision = nil,
        farmlandRevisions = {},
        initialized = false,
        advances = 0,
    }
end

local function establishRevision(owner, farmlandIds)
    owner.initialized = true
    owner.globalRevision = 1
    owner.unscopedRevision = 1
    for _, farmlandId in ipairs(farmlandIds or {}) do
        owner.farmlandRevisions[farmlandId] = 1
    end
    return owner.globalRevision
end

local function observeMutation(owner, key, authority, outcome, farmlandIds)
    if not owner.initialized then return owner.globalRevision end
    if authority ~= "server" then return owner.globalRevision end
    if not READ_KEYS[key] then return owner.globalRevision end
    if outcome ~= "EXECUTED" then return owner.globalRevision end
    owner.globalRevision = owner.globalRevision + 1
    owner.advances = owner.advances + 1
    if type(farmlandIds) == "table" and #farmlandIds > 0 then
        for _, farmlandId in ipairs(farmlandIds) do
            owner.farmlandRevisions[farmlandId] =
                (owner.farmlandRevisions[farmlandId] or 1) + 1
        end
    else
        owner.unscopedRevision = owner.unscopedRevision + 1
    end
    return owner.globalRevision
end

local function revisionToken(owner, farmlandId)
    if not owner.initialized then return nil end
    local farmlandRevision = owner.farmlandRevisions[farmlandId]
    if farmlandRevision == nil then return nil end
    return {
        globalRevision = owner.globalRevision,
        farmlandRevision = farmlandRevision,
        unscopedRevision = owner.unscopedRevision,
    }
end

-- ============================================================
-- GROUP B: ONE SERVER REVISION FAMILY AT THE MUTATOR BOUNDARY.
-- SDS section 4, SoilValueMaps authority.
-- ============================================================
do
    local owner = newRevisionOwner()
    T.eq("B1 revision is unavailable during bootstrap", owner.globalRevision, nil)
    T.eq("B2 bootstrap writes do not mint a partial revision",
        observeMutation(owner, "nitrogen", "server", "EXECUTED", { 7 }), nil)
    T.eq("B3 coherent initialization establishes the first revision",
        establishRevision(owner, { 7, 8 }), 1)
    T.eq("B4 an executed N write advances the global coordinate",
        observeMutation(owner, "nitrogen", "server", "EXECUTED", { 7 }), 2)
    T.eq("B5 proven farmland 7 advances locally", owner.farmlandRevisions[7], 2)
    T.eq("B6 unrelated farmland 8 remains stable", owner.farmlandRevisions[8], 1)
    T.eq("B7 an executed P write advances",
        observeMutation(owner, "phosphorus", "server", "EXECUTED", { 8 }), 3)
    T.eq("B8 unscoped executed K write advances globally",
        observeMutation(owner, "potassium", "server", "EXECUTED", nil), 4)
    T.eq("B9 unscoped executed write advances the unscoped coordinate",
        owner.unscopedRevision, 2)
    T.eq("B10 an executed maybe-same write advances conservatively",
        observeMutation(owner, "compaction", "server", "EXECUTED", { 7 }), 5)
    T.eq("B11 a known refused call does not advance",
        observeMutation(owner, "nitrogen", "server", "REFUSED", { 7 }), 5)
    T.eq("B12 another layer does not advance the growth read-set",
        observeMutation(owner, "pH", "server", "EXECUTED", { 7 }), 5)
    T.eq("B13 client projection never mints server revision",
        observeMutation(owner, "nitrogen", "client", "EXECUTED", { 7 }), 5)
    T.eq("B14 four executed read-set writes advanced four times",
        owner.advances, 4)
    local token7 = revisionToken(owner, 7)
    T.eq("B15 token keeps the global observation coordinate", token7.globalRevision, 5)
    T.eq("B16 token keeps the farmland coordinate", token7.farmlandRevision, 3)
    T.eq("B17 token keeps the unscoped coordinate", token7.unscopedRevision, 2)
    T.eq("B18 unknown farmland has no token", revisionToken(owner, 99), nil)
end

local function pointOnSegment(x, z, a, b)
    local cross = (x - a.x) * (b.z - a.z) - (z - a.z) * (b.x - a.x)
    if math.abs(cross) > 1e-9 then return false end
    local dot = (x - a.x) * (b.x - a.x) + (z - a.z) * (b.z - a.z)
    if dot < 0 then return false end
    local len2 = (b.x - a.x) ^ 2 + (b.z - a.z) ^ 2
    return dot <= len2
end

local function pointInPolygonInclusive(x, z, verts)
    local inside = false
    local j = #verts
    for i = 1, #verts do
        local a, b = verts[j], verts[i]
        if pointOnSegment(x, z, a, b) then return true end
        if (a.z > z) ~= (b.z > z) then
            local xAtZ = (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x
            if x < xAtZ then inside = not inside end
        end
        j = i
    end
    return inside
end

local function inTerrainDomain(x, z, half)
    return x >= -half and x < half and z >= -half and z < half
end

local function pointInPolygonUnion(x, z, polygons)
    for _, verts in ipairs(polygons or {}) do
        if pointInPolygonInclusive(x, z, verts) then return true end
    end
    return false
end

local function polygonUnionFingerprint(polygons)
    local polygonRows = {}
    for _, verts in ipairs(polygons or {}) do
        local points = {}
        for _, v in ipairs(verts) do
            points[#points + 1] = string.format("%.3f,%.3f", v.x, v.z)
        end
        polygonRows[#polygonRows + 1] = table.concat(points, ";")
    end
    table.sort(polygonRows)
    return table.concat(polygonRows, "|")
end

local function stablePointRead(owner, fieldId, x, z, half, polygons, values, mutateDuring)
    local before = revisionToken(owner, fieldId)
    if before == nil or fieldId == nil then return nil end
    if not inTerrainDomain(x, z, half) then return nil end
    if not pointInPolygonUnion(x, z, polygons) then return nil end
    local n = values.n
    local p = values.p
    local k = values.k
    local compaction = values.compaction
    if mutateDuring == "same" then
        observeMutation(owner, "nitrogen", "server", "EXECUTED", { fieldId })
    elseif mutateDuring == "other" then
        observeMutation(owner, "nitrogen", "server", "EXECUTED", { fieldId + 1 })
    elseif mutateDuring == "unscoped" then
        observeMutation(owner, "nitrogen", "server", "EXECUTED", nil)
    end
    local after = revisionToken(owner, fieldId)
    if before.farmlandRevision ~= after.farmlandRevision
        or before.unscopedRevision ~= after.unscopedRevision then return nil end
    local bands = {
        n = ViabilityMask.bandNitrogen(n),
        compaction = ViabilityMask.bandCompaction(compaction),
        moisture = nil,
    }
    local overall = ViabilityMask.combine(bands)
    if overall == nil then return nil end
    return {
        blocked = overall == ViabilityMask.BAND_BLOCKED,
        blockedBy = {
            n = bands.n == ViabilityMask.BAND_BLOCKED,
            compaction = bands.compaction == ViabilityMask.BAND_BLOCKED,
            moisture = false,
        },
        bands = bands,
        n = n,
        p = p,
        k = k,
        credit = nil,
        capturedEfficiency = nil,
        fieldId = fieldId,
        role = "TRUTH",
        grainMetres = 2,
        growthInputRevision = after.globalRevision,
        farmlandInputRevision = after.farmlandRevision,
        unscopedInputRevision = after.unscopedRevision,
    }
end

-- ============================================================
-- GROUP C: STRICT DOMAIN, FIELD MEMBERSHIP AND STABLE POINT READ.
-- SDS sections 4 and 5.2.
-- ============================================================
do
    local squareA = {
        { x = -20, z = -20 },
        { x = 20, z = -20 },
        { x = 20, z = 20 },
        { x = -20, z = 20 },
    }
    local squareB = {
        { x = 40, z = -10 },
        { x = 60, z = -10 },
        { x = 60, z = 10 },
        { x = 40, z = 10 },
    }
    local union = { squareA, squareB }
    T.eq("C1 first farmland polygon interior is accepted",
        pointInPolygonUnion(0, 0, union), true)
    T.eq("C2 second polygon on the same farmland is accepted",
        pointInPolygonUnion(50, 0, union), true)
    T.eq("C3 polygon boundary is accepted", pointInPolygonUnion(20, 0, union), true)
    T.eq("C4 space between the farmland polygons is refused",
        pointInPolygonUnion(30, 0, union), false)
    T.eq("C5 polygon-union fingerprint ignores polygon enumeration order",
        polygonUnionFingerprint({ squareA, squareB }),
        polygonUnionFingerprint({ squareB, squareA }))
    T.eq("C6 negative terrain edge is inside the half-open domain",
        inTerrainDomain(-100, 0, 100), true)
    T.eq("C7 positive terrain edge is outside the half-open domain",
        inTerrainDomain(100, 0, 100), false)

    local owner = newRevisionOwner()
    establishRevision(owner, { 7, 8 })
    local values = { n = 40, p = 50, k = 60, compaction = 20 }
    local info = stablePointRead(owner, 7, 0, 0, 100, union, values, nil)
    T.ok("C8 stable farmland-proven point returns truth", info ~= nil)
    T.eq("C9 local result reports the farmland ID", info.fieldId, 7)
    T.eq("C10 local result reports TRUTH role", info.role, "TRUTH")
    T.eq("C11 local result reports positive carrier grain", info.grainMetres, 2)
    T.eq("C12 local result reports the stable farmland revision",
        info.farmlandInputRevision, 1)
    T.eq("C13 current moisture band is explicitly non-voting", info.bands.moisture, nil)
    T.eq("C14 current moisture reason is false", info.blockedBy.moisture, false)
    local secondInfo = stablePointRead(owner, 7, 50, 0, 100, union, values, nil)
    T.eq("C15 second polygon returns the same farmland context", secondInfo.fieldId, 7)
    T.eq("C16 second-polygon point withholds witnessless credit", secondInfo.credit, nil)
    T.eq("C17 second-polygon point withholds witnessless captured efficiency",
        secondInfo.capturedEfficiency, nil)
    T.eq("C18 between polygons is unavailable",
        stablePointRead(owner, 7, 30, 0, 100, union, values, nil), nil)
    T.eq("C19 out-of-domain coordinate is unavailable",
        stablePointRead(owner, 7, 100, 0, 100, union, values, nil), nil)
    T.eq("C20 same-farmland mutation during read refuses mixed answer",
        stablePointRead(owner, 7, 0, 0, 100, union, values, "same"), nil)
    T.eq("C21 unrelated farmland mutation does not invalidate this point",
        stablePointRead(owner, 7, 0, 0, 100, union, values, "other") ~= nil, true)
    T.eq("C22 unscoped mutation during read refuses mixed answer",
        stablePointRead(owner, 7, 0, 0, 100, union, values, "unscoped"), nil)
end

local BAND_ORDER = { BLOCKED = 1, NORMAL = 2, EXCELLENT = 3, UNKNOWN = 4 }

local function stableResultHash(regions)
    local rows = {}
    for _, r in ipairs(regions) do
        rows[#rows + 1] = string.format("%s:%d:%d", r.key, BAND_ORDER[r.band], r.area)
    end
    table.sort(rows)
    return table.concat(rows, "|")
end

local function newPlan(regions, globalRevision, farmlandRevision, unscopedRevision,
    polygonUnionFingerprint)
    return {
        regions = regions,
        globalRevision = globalRevision,
        farmlandRevision = farmlandRevision,
        unscopedRevision = unscopedRevision,
        polygonUnionFingerprint = polygonUnionFingerprint,
        cursor = 1,
        visited = 0,
        visitedArea = 0,
        totals = { BLOCKED = 0, NORMAL = 0, EXCELLENT = 0, UNKNOWN = 0 },
        status = "PENDING",
    }
end

local function advancePlan(plan, budget)
    if budget <= 0 then return 0 end
    local stepped = 0
    while plan.cursor <= #plan.regions and stepped < budget do
        local r = plan.regions[plan.cursor]
        plan.totals[r.band] = plan.totals[r.band] + r.area
        plan.visitedArea = plan.visitedArea + r.area
        plan.visited = plan.visited + 1
        plan.cursor = plan.cursor + 1
        stepped = stepped + 1
    end
    if plan.cursor > #plan.regions then plan.status = "READY" end
    return stepped
end

local function commitPlan(plan, currentGlobal, currentFarmland, currentUnscoped,
    currentGeometry, generation)
    if plan.status ~= "READY" then return nil, "PENDING" end
    if plan.farmlandRevision ~= currentFarmland
        or plan.unscopedRevision ~= currentUnscoped
        or plan.polygonUnionFingerprint ~= currentGeometry then
        plan.status = "CANCELLED"
        return nil, "STALE"
    end
    local total = plan.visitedArea
    if total <= 0 then return nil, "UNAVAILABLE" end
    local summary = {
        blockedFrac = plan.totals.BLOCKED / total,
        normalFrac = plan.totals.NORMAL / total,
        excellentFrac = plan.totals.EXCELLENT / total,
        unknownFrac = plan.totals.UNKNOWN / total,
        globalInputRevision = currentGlobal,
        farmlandInputRevision = plan.farmlandRevision,
        unscopedInputRevision = plan.unscopedRevision,
        summaryGeneration = generation,
        polygonUnionFingerprint = plan.polygonUnionFingerprint,
        eligibleArea = total,
        visitedArea = total,
        coverage = 1,
        resultHash = stableResultHash(plan.regions),
    }
    plan.status = "COMMITTED"
    return summary, "CURRENT"
end

local function runPlan(regions, budget, globalRevision, farmlandRevision,
    unscopedRevision, geometry)
    local plan = newPlan(regions, globalRevision, farmlandRevision,
        unscopedRevision, geometry)
    while plan.status == "PENDING" do advancePlan(plan, budget) end
    return commitPlan(plan, globalRevision, farmlandRevision, unscopedRevision,
        geometry, 1)
end

-- ============================================================
-- GROUP D: COMPLETE AREA-WEIGHTED WORK WITH NO TOTAL CEILING.
-- SDS sections 5.3 and 5.4.
-- ============================================================
do
    local weighted = {
        { key = "a", area = 1, band = "BLOCKED" },
        { key = "b", area = 2, band = "EXCELLENT" },
        { key = "c", area = 1, band = "UNKNOWN" },
    }
    local summary = runPlan(weighted, 1, 4, 2, 1, "geom-a")
    T.near("D1 blocked fraction is area-weighted", summary.blockedFrac, 0.25, 1e-12)
    T.near("D2 excellent fraction is area-weighted", summary.excellentFrac, 0.50, 1e-12)
    T.near("D3 unknown area remains unknown", summary.unknownFrac, 0.25, 1e-12)
    T.near("D4 fractions sum to one", summary.blockedFrac + summary.normalFrac
        + summary.excellentFrac + summary.unknownFrac, 1, 1e-12)
    T.eq("D5 complete work reports full coverage", summary.coverage, 1)

    local many = {}
    for i = 1, 801 do
        many[i] = {
            key = string.format("r%04d", i),
            area = 1,
            band = i == 801 and "BLOCKED" or "NORMAL",
        }
    end
    local plan = newPlan(many, 9, 4, 2, "geom-many")
    T.eq("D6 zero budget performs no hidden work", advancePlan(plan, 0), 0)
    T.eq("D7 zero budget remains visibly pending", plan.status, "PENDING")
    T.eq("D8 first 600 operations do not claim complete", advancePlan(plan, 600), 600)
    T.eq("D9 work at the former ceiling remains pending", plan.status, "PENDING")
    T.eq("D10 the remaining eligible region is still visited", advancePlan(plan, 600), 201)
    T.eq("D11 all 801 regions were visited", plan.visited, 801)
    local allSummary = commitPlan(plan, 9, 4, 2, "geom-many", 2)
    T.near("D12 the 801st blocked region affects the final result",
        allSummary.blockedFrac, 1 / 801, 1e-12)

    local byOne = runPlan(many, 1, 9, 4, 2, "geom-many")
    local bySeventeen = runPlan(many, 17, 9, 4, 2, "geom-many")
    T.near("D13 frame budget does not change blocked result",
        byOne.blockedFrac, bySeventeen.blockedFrac, 1e-12)
    T.eq("D14 frame budget does not change result hash",
        byOne.resultHash, bySeventeen.resultHash)

    local reversed = {}
    for i = #many, 1, -1 do reversed[#reversed + 1] = many[i] end
    local reverseSummary = runPlan(reversed, 23, 9, 4, 2, "geom-many")
    T.near("D15 traversal order does not change fractions",
        reverseSummary.blockedFrac, byOne.blockedFrac, 1e-12)
    T.eq("D16 traversal order does not change stable result hash",
        reverseSummary.resultHash, byOne.resultHash)

    local stableOtherField = newPlan(weighted, 4, 2, 1, "geom-a")
    advancePlan(stableOtherField, 99)
    local accepted, reason = commitPlan(stableOtherField, 5, 2, 1, "geom-a", 3)
    T.ok("D17 unrelated farmland global advance does not cancel", accepted ~= nil)
    T.eq("D18 unrelated farmland commit is CURRENT", reason, "CURRENT")

    local staleFarmland = newPlan(weighted, 4, 2, 1, "geom-a")
    advancePlan(staleFarmland, 99)
    local rejected
    rejected, reason = commitPlan(staleFarmland, 5, 3, 1, "geom-a", 3)
    T.eq("D19 changed farmland revision refuses stale commit", rejected, nil)
    T.eq("D20 changed farmland revision reports STALE", reason, "STALE")

    local staleUnscoped = newPlan(weighted, 4, 2, 1, "geom-a")
    advancePlan(staleUnscoped, 99)
    rejected, reason = commitPlan(staleUnscoped, 5, 2, 2, "geom-a", 3)
    T.eq("D21 changed unscoped revision refuses stale commit", rejected, nil)
    T.eq("D22 changed unscoped revision reports STALE", reason, "STALE")

    local staleGeometry = newPlan(weighted, 4, 2, 1, "geom-a")
    advancePlan(staleGeometry, 99)
    rejected, reason = commitPlan(staleGeometry, 4, 2, 1, "geom-b", 3)
    T.eq("D23 changed polygon union refuses stale commit", rejected, nil)
    T.eq("D24 changed polygon union reports STALE", reason, "STALE")
end

local function newProvider()
    return {
        globalRevision = 1,
        farmlandRevision = 1,
        unscopedRevision = 1,
        polygonUnionFingerprint = "g1",
        summary = nil,
        pending = false,
        queued = 0,
        deleted = false,
    }
end

local function requestRecompute(provider)
    if provider.deleted then return false end
    if not provider.pending then
        provider.pending = true
        provider.queued = provider.queued + 1
    end
    return true
end

local function publishSummary(provider, summary)
    provider.summary = summary
    provider.pending = false
end

local function getSummary(provider)
    if provider.deleted then return nil end
    if provider.summary == nil then return nil end
    local out = {}
    for key, value in pairs(provider.summary) do out[key] = value end
    out.current = out.farmlandInputRevision == provider.farmlandRevision
        and out.unscopedInputRevision == provider.unscopedRevision
        and out.polygonUnionFingerprint == provider.polygonUnionFingerprint
        and not provider.pending
    out.pending = provider.pending
    return out
end

local function getSummaryStatus(provider)
    if provider.deleted or provider.summary == nil then
        return provider.pending and "PENDING" or "UNAVAILABLE"
    end
    if provider.pending then return "PENDING" end
    if provider.summary.farmlandInputRevision ~= provider.farmlandRevision
        or provider.summary.unscopedInputRevision ~= provider.unscopedRevision
        or provider.summary.polygonUnionFingerprint ~= provider.polygonUnionFingerprint then
        return "STALE"
    end
    return "CURRENT"
end

local function deleteProvider(provider)
    provider.deleted = true
    provider.summary = nil
    provider.pending = false
end

-- ============================================================
-- GROUP E: LAST-COMPLETE SUMMARY, CURRENTNESS, FALLBACK AND TEARDOWN.
-- SDS sections 5.5, 5.7 and 5.8.
-- ============================================================
do
    local provider = newProvider()
    T.eq("E1 no generation is unavailable before first commit",
        getSummaryStatus(provider), "UNAVAILABLE")
    T.eq("E2 initialization queues one current recompute", requestRecompute(provider), true)
    T.eq("E3 initialization is visibly pending", getSummaryStatus(provider), "PENDING")
    T.eq("E4 repeated dirty signals coalesce", requestRecompute(provider), true)
    T.eq("E5 coalescing keeps one queued generation", provider.queued, 1)

    publishSummary(provider, {
        blockedFrac = 0.20,
        excellentFrac = 0.30,
        globalInputRevision = 1,
        farmlandInputRevision = 1,
        unscopedInputRevision = 1,
        polygonUnionFingerprint = "g1",
        summaryGeneration = 1,
    })
    local summary = getSummary(provider)
    T.eq("E6 complete matching summary is current", summary.current, true)
    T.eq("E7 status reports CURRENT", getSummaryStatus(provider), "CURRENT")
    T.near("E8 legacy blocked fraction remains readable", summary.blockedFrac, 0.20, 1e-12)
    T.near("E9 legacy excellent fraction remains readable", summary.excellentFrac, 0.30, 1e-12)

    provider.globalRevision = 2
    summary = getSummary(provider)
    T.eq("E10 last-complete summary survives as historical data", summary.summaryGeneration, 1)
    T.eq("E11 unrelated farmland global change keeps this summary current",
        summary.current, true)
    T.eq("E12 status remains CURRENT after unrelated global change",
        getSummaryStatus(provider), "CURRENT")
    provider.farmlandRevision = 2
    summary = getSummary(provider)
    T.eq("E13 farmland revision mismatch marks it non-current", summary.current, false)
    T.eq("E14 farmland revision mismatch reports STALE", getSummaryStatus(provider), "STALE")
    requestRecompute(provider)
    T.eq("E15 replacement work reports PENDING", getSummaryStatus(provider), "PENDING")

    local timeGuardProvider = newProvider()
    local fallbackProvider = newProvider()
    requestRecompute(timeGuardProvider)
    requestRecompute(fallbackProvider)
    T.eq("E16 Time Guard and local fallback queue the same current work",
        timeGuardProvider.queued, fallbackProvider.queued)
    T.eq("E17 skipped-day count does not invent historical summary generations",
        fallbackProvider.queued, 1)

    local unscoped = newProvider()
    publishSummary(unscoped, {
        blockedFrac = 0.10,
        excellentFrac = 0.10,
        farmlandInputRevision = 1,
        unscopedInputRevision = 1,
        polygonUnionFingerprint = "g1",
    })
    unscoped.unscopedRevision = 2
    T.eq("E18 unscoped write stales every farmland summary",
        getSummaryStatus(unscoped), "STALE")

    deleteProvider(provider)
    T.eq("E19 teardown makes summary unavailable", getSummary(provider), nil)
    T.eq("E20 teardown clears pending work", provider.pending, false)
    T.eq("E21 teardown status is unavailable", getSummaryStatus(provider), "UNAVAILABLE")
    T.eq("E22 teardown refuses new work", requestRecompute(provider), false)
end

local function newFairQueue()
    return { order = {}, present = {} }
end

local function enqueueFarmland(queue, farmlandId)
    if queue.present[farmlandId] then return false end
    queue.present[farmlandId] = true
    queue.order[#queue.order + 1] = farmlandId
    return true
end

local function popFarmland(queue)
    if #queue.order == 0 then return nil end
    local farmlandId = table.remove(queue.order, 1)
    queue.present[farmlandId] = nil
    return farmlandId
end

-- ============================================================
-- GROUP Q: FAIR FIELD SERVICE UNDER REPEATED LOCAL DIRTIES.
-- SDS sections 5.4 and 5.5.
-- ============================================================
do
    local queue = newFairQueue()
    T.eq("Q1 first farmland enters the queue", enqueueFarmland(queue, 7), true)
    T.eq("Q2 second farmland enters behind it", enqueueFarmland(queue, 8), true)
    T.eq("Q3 repeated dirty for queued farmland coalesces", enqueueFarmland(queue, 7), false)
    T.eq("Q4 oldest farmland receives service first", popFarmland(queue), 7)
    T.eq("Q5 unstable farmland re-enters at the tail", enqueueFarmland(queue, 7), true)
    T.eq("Q6 unrelated stable farmland cannot be starved", popFarmland(queue), 8)
end

-- ============================================================
-- GROUP F: CURRENT CLASSIFIER COMPATIBILITY REMAINS.
-- SDS sections 4 and 6.
-- ============================================================
do
    T.eq("F1 N below 20 remains blocked", ViabilityMask.bandNitrogen(10), "blocked")
    T.eq("F2 N between the current thresholds remains normal",
        ViabilityMask.bandNitrogen(40), "normal")
    T.eq("F3 N above 60 remains excellent", ViabilityMask.bandNitrogen(61), "excellent")
    T.eq("F4 high compaction remains blocked", ViabilityMask.bandCompaction(80), "blocked")
    T.eq("F5 low compaction remains excellent", ViabilityMask.bandCompaction(20), "excellent")
    T.eq("F6 current moisture classification remains non-voting",
        ViabilityMask.bandMoisture(0.1, nil, nil), nil)
    T.eq("F7 unknown inputs remain unavailable rather than normal",
        ViabilityMask.combine({ n = nil, compaction = nil, moisture = nil }), nil)
    T.eq("F8 any known blocked band wins",
        ViabilityMask.combine({ n = "normal", compaction = "blocked" }), "blocked")
    T.eq("F9 excellence requires no blocked band",
        ViabilityMask.combine({ n = "excellent", compaction = "normal" }), "excellent")
end

-- ============================================================
-- GROUP G: THE BAR'S OWN LIMITS STAY VISIBLE.
-- ============================================================
do
    T.ok("G1 pure model cannot prove engine polygon coverage", true)
    T.ok("G2 pure model cannot select a runtime work budget", true)
    T.ok("G3 pure model cannot prove save duration or bytes", true)
    T.ok("G4 pure model cannot prove client delivery", true)
end

-- ============================================================
-- GROUP H: GROWTH-SET R1 PROVIDER CONTRACT.
-- SF-52-SDS.md:30-54 and the SF-52 candidate amendment:20-30.
-- This models the unbuilt ground-only plan. Group A remains the real-source
-- tripwire and must go red when the provider lands.
-- ============================================================
local function assignCarrierOwners(candidates)
    local owners = {}
    for _, candidate in ipairs(candidates or {}) do
        local prior = owners[candidate.key]
        if prior == nil or candidate.area > prior.area
            or (candidate.area == prior.area and candidate.farmlandId < prior.farmlandId) then
            owners[candidate.key] = candidate
        end
    end
    return owners
end

local function carrierOwnershipHash(owners)
    local keys, parts = {}, {}
    for key in pairs(owners or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = key .. ":" .. tostring(owners[key].farmlandId)
    end
    return table.concat(parts, "|")
end

local function assembleGroundPlan(regions, resultHash, farmlandId, carrierOwners)
    table.sort(regions, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.sourcePolygonFingerprint < b.sourcePolygonFingerprint
    end)
    local owned, ordered = {}, {}
    for _, region in ipairs(regions) do
        local prior = owned[region.key]
        if prior == nil or region.sourcePolygonFingerprint < prior.sourcePolygonFingerprint then
            owned[region.key] = region
        end
    end
    for key, region in pairs(owned) do
        local carrierOwnerFarmlandId = carrierOwners ~= nil and carrierOwners[key] ~= nil
            and carrierOwners[key].farmlandId or farmlandId
        ordered[#ordered + 1] = { key = key, sourcePolygonFingerprint = region.sourcePolygonFingerprint,
            blocked = region.blocked, area = region.area,
            carrierOwnerFarmlandId = carrierOwnerFarmlandId,
            writableForFarmland = carrierOwnerFarmlandId == farmlandId }
    end
    table.sort(ordered, function(a, b) return a.key < b.key end)
    local ownershipDigest = carrierOwnershipHash(carrierOwners)
    local parts = { "OWNERS=" .. ownershipDigest }
    for _, region in ipairs(ordered) do
        parts[#parts + 1] = table.concat({region.key, region.sourcePolygonFingerprint,
            region.blocked and "B" or "N", tostring(region.area),
            tostring(region.carrierOwnerFarmlandId), region.writableForFarmland and "W" or "R"}, ":")
    end
    return {
        regions = ordered,
        resultHash = resultHash,
        planContentHash = table.concat(parts, "|"),
        carrierOwnershipHash = ownershipDigest,
        fruitIdentity = nil,
        fruitState = nil,
        periodKey = nil,
    }
end

do
    local carrierOwners = assignCarrierOwners({
        {key="7:1:1",farmlandId=7,area=4},
        {key="7:2:1",farmlandId=7,area=4},
    })
    local plan = assembleGroundPlan({
        {key="7:2:1",sourcePolygonFingerprint="poly-b",blocked=false,area=4},
        {key="7:1:1",sourcePolygonFingerprint="poly-z",blocked=true,area=4},
        {key="7:1:1",sourcePolygonFingerprint="poly-a",blocked=true,area=4},
    }, "summary-25-75", 7, carrierOwners)
    T.eq("H1 overlapping key has one provider owner", #plan.regions, 2)
    T.eq("H2 lowest polygon fingerprint owns an overlap",
        plan.regions[1].sourcePolygonFingerprint, "poly-a")
    T.eq("H3 each region carries its source polygon fingerprint",
        plan.regions[2].sourcePolygonFingerprint, "poly-b")
    T.eq("H4 plan content hash is distinct from summary result hash",
        plan.planContentHash == plan.resultHash, false)
    T.eq("H5 ground plan carries no farmland-wide fruit identity", plan.fruitIdentity, nil)
    T.eq("H6 ground plan carries no farmland-wide fruit state", plan.fruitState, nil)
    T.eq("H7 ground plan carries no growth-period identity", plan.periodKey, nil)
    T.eq("H8 deterministic plan content follows stable key order",
        plan.planContentHash, "OWNERS=7:1:1:7|7:2:1:7|7:1:1:poly-a:B:4:7:W|7:2:1:poly-b:N:4:7:W")

    local boundaryOwners = assignCarrierOwners({
        {key="edge",farmlandId=9,area=1.5},
        {key="edge",farmlandId=2,area=2.5},
        {key="tie",farmlandId=9,area=2},
        {key="tie",farmlandId=2,area=2},
    })
    T.eq("H9 greatest positive farmland intersection owns a boundary cell",
        boundaryOwners.edge.farmlandId, 2)
    T.eq("H10 exact area tie selects the lowest numeric farmland id",
        boundaryOwners.tie.farmlandId, 2)
    local nonOwner = assembleGroundPlan({
        {key="edge",sourcePolygonFingerprint="poly-nine",blocked=true,area=1.5},
    }, "summary-nine", 9, boundaryOwners)
    T.eq("H11 non-owner plan region remains available for weighted summary",
        #nonOwner.regions, 1)
    T.eq("H12 non-owner plan region cannot receive consequence writes",
        nonOwner.regions[1].writableForFarmland, false)
    T.eq("H13 carrier ownership hash is deterministic by stable key",
        carrierOwnershipHash(boundaryOwners), "edge:2|tie:2")
    T.eq("H14 every farmland plan in one generation carries the same ownership hash",
        nonOwner.carrierOwnershipHash, carrierOwnershipHash(boundaryOwners))
    -- SF-52-SDS.md:37,51: ownership elsewhere in the generation changes the
    -- complete plan digest even when this plan's own region is unchanged.
    local changedOwners = assignCarrierOwners({
        {key="edge",farmlandId=2,area=2.5},
        {key="tie",farmlandId=9,area=2},
    })
    local changed = assembleGroundPlan({
        {key="edge",sourcePolygonFingerprint="poly-nine",blocked=true,area=1.5},
    }, "summary-nine", 9, changedOwners)
    T.eq("H15 global ownership digest participates in plan content proof",
        changed.planContentHash == nonOwner.planContentHash, false)
end

T.summary()
