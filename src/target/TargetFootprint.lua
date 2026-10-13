-- =========================================================
-- FS25 Realistic Soil & Fertilizer - SF-73 target footprint
-- =========================================================
-- The read-only geometry and the pre-spend width witness of target-accurate
-- N/P/K (SF-73 Implementation v1.1, section 3).
--
--   * treatment geometry: the boom line from the sprayer's own active SPRAYER work
--     areas only (never an attached implement or a VWW effect tip), and for
--     usageScale.workAreaIndex the moved corners of exactly that work area, which
--     is the area native reads its width from (Sprayer.lua:520-524);
--   * the swept quad between the anchor line and this cycle's line, paired tip to
--     tip the way paintBoomStrip pairs them so a swapped pair never folds;
--   * the witness: every fruit-plane cell whose square, inflated by an outer guard,
--     meets the swept quad or a native paint parallelogram, classified by the
--     engine's own point readers at the cell centre. A centre, four-corner or
--     whole-field sample is not this witness.
--
-- Engine reads go through F.ENGINE so the bench can model the rasters. Nothing
-- here writes anything, spends anything or keeps state between calls; the caller
-- owns the per-vehicle cell cache it passes in.
-- =========================================================

TargetFootprint = TargetFootprint or {}
local F = TargetFootprint

F.MERGE_TOLERANCE = 0.10    -- metres: collinear work-area pieces closer than this are one line
F.MAX_CELLS       = 60000   -- a region needing more cells than this is refused, never sampled thin
F.GUARD_CELLS     = 1       -- the outer guard ring, in fine cells

-- ── the engine surface (verified against the decompiled scripts) ────────────
-- FSDensityMapUtil.getFruitTypeIndexAtWorldPos        utils/FSDensityMapUtil.lua:2849
-- FSDensityMapUtil.getFieldDataAtWorldPosition        utils/FSDensityMapUtil.lua:13
-- FruitTypeManager:getDefaultDataPlaneId              fruits/FruitTypeManager.lua:472
-- getDensityMapSize (the fruit plane's size)          FSBaseMission.lua:1333
-- FarmlandManager:getFarmlandIdAtWorldPosition        economy/FarmlandManager.lua:282
-- FarmlandManager:getCanAccessLandAtWorldPosition     economy/FarmlandManager.lua:267
-- FieldManager.farmlandIdFieldMapping                 field/FieldManager.lua:43, :119
F.ENGINE = {
    terrainSize = function()
        local m = g_currentMission
        return m and m.terrainSize or nil
    end,
    fruitGrain = function(terrainSize)
        if g_fruitTypeManager == nil or type(g_fruitTypeManager.getDefaultDataPlaneId) ~= "function"
           or getDensityMapSize == nil then
            return nil
        end
        local id = g_fruitTypeManager:getDefaultDataPlaneId()
        if id == nil or id == 0 then return nil end
        local size = getDensityMapSize(id)
        if type(size) ~= "number" or size <= 0 or type(terrainSize) ~= "number" or terrainSize <= 0 then
            return nil
        end
        return terrainSize / size
    end,
    fruitAt = function(x, z)
        if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then return nil end
        return FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    end,
    fruitDesc = function(index)
        return g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(index) or nil
    end,
    onField = function(x, z)
        if FSDensityMapUtil == nil or FSDensityMapUtil.getFieldDataAtWorldPosition == nil then return nil end
        local isOnField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
        return isOnField == true
    end,
    farmlandAt = function(x, z)
        if g_farmlandManager == nil then return nil end
        return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    end,
    canAccess = function(farmId, x, z)
        if g_farmlandManager == nil then return false end
        return g_farmlandManager:getCanAccessLandAtWorldPosition(farmId, x, z) == true
    end,
    engineFieldFor = function(farmlandId)
        local fm = g_fieldManager
        return fm and fm.farmlandIdFieldMapping and fm.farmlandIdFieldMapping[farmlandId] or nil
    end,
}

local function worldXZ(node)
    if node == nil then return nil end
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or type(x) ~= "number" or type(z) ~= "number" then return nil end
    return x, z
end

--- The polygon native paints for one work area: start, width, width+height-start,
--- height (the parallelogram updateSprayArea is handed, Sprayer.lua:314-331).
local function paintPolygon(wa)
    local sx, sz = worldXZ(wa.start)
    local wx, wz = worldXZ(wa.width)
    local hx, hz = worldXZ(wa.height)
    if sx == nil or wx == nil or hx == nil then return nil end
    return {
        { x = sx, z = sz }, { x = wx, z = wz },
        { x = wx + hx - sx, z = wz + hz - sz }, { x = hx, z = hz },
    }, { ax = sx, az = sz, bx = wx, bz = wz }
end

--- Is this work area processed right now? The engine's own predicate, which on a
--- sprayer also refuses an area bound to another spray type (Sprayer.lua:726-733).
local function areaActive(sprayer, wa)
    if type(sprayer.getIsWorkAreaActive) ~= "function" then return false end
    local ok, active = pcall(sprayer.getIsWorkAreaActive, sprayer, wa)
    return ok and active == true
end

local function isSprayerArea(wa)
    local sprayerType = WorkAreaType ~= nil and WorkAreaType.SPRAYER or nil
    if sprayerType == nil then return wa.type ~= nil end
    return wa.type == sprayerType
end

--- Merge collinear, touching line pieces into one line; nil when they are not one line.
local function mergeLines(lines, tol)
    local base = lines[1]
    local dx, dz = base.bx - base.ax, base.bz - base.az
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1e-6 then return nil end
    local ux, uz = dx / len, dz / len
    local spans = {}
    for _, l in ipairs(lines) do
        for _, p in ipairs({ { l.ax, l.az }, { l.bx, l.bz } }) do
            local rx, rz = p[1] - base.ax, p[2] - base.az
            local off = math.abs(rx * (-uz) + rz * ux)
            if off > tol then return nil end
        end
        local t1 = (l.ax - base.ax) * ux + (l.az - base.az) * uz
        local t2 = (l.bx - base.ax) * ux + (l.bz - base.az) * uz
        spans[#spans + 1] = { math.min(t1, t2), math.max(t1, t2) }
    end
    table.sort(spans, function(a, b) return a[1] < b[1] end)
    local lo, hi = spans[1][1], spans[1][2]
    for i = 2, #spans do
        if spans[i][1] > hi + tol then return nil end
        if spans[i][2] > hi then hi = spans[i][2] end
    end
    return { ax = base.ax + ux * lo, az = base.az + uz * lo, bx = base.ax + ux * hi, bz = base.az + uz * hi }
end

--- The cycle's treatment geometry from the sprayer's own active SPRAYER work areas.
---@return table|nil geometry { line, paintPolys, areaKey, width }, string|nil refusal
function F.treatmentGeometry(sprayer)
    local waSpec = sprayer and sprayer.spec_workArea
    local spec = sprayer and sprayer.spec_sprayer
    if waSpec == nil or type(waSpec.workAreas) ~= "table" or spec == nil then return nil, nil end

    local usageScale = spec.usageScale
    if type(sprayer.getActiveSprayType) == "function" then
        local ok, st = pcall(sprayer.getActiveSprayType, sprayer)
        if ok and st ~= nil and st.usageScale ~= nil then usageScale = st.usageScale end
    end

    local chosen = {}
    local areaKey = "ROOT"
    local idx = usageScale and usageScale.workAreaIndex
    if idx ~= nil then
        local wa = waSpec.workAreas[idx]
        if wa == nil or not areaActive(sprayer, wa) then return nil, nil end
        chosen[1] = wa
        areaKey = "WA" .. tostring(idx)
    else
        for i, wa in ipairs(waSpec.workAreas) do
            if isSprayerArea(wa) and areaActive(sprayer, wa) then
                chosen[#chosen + 1] = wa
                areaKey = (#chosen == 1) and ("WA" .. tostring(i)) or "ROOT"
            end
        end
        if #chosen == 0 then return nil, nil end
    end

    local polys, lines = {}, {}
    for _, wa in ipairs(chosen) do
        local poly, line = paintPolygon(wa)
        if poly == nil then return nil, "UNKNOWN_GROUND" end
        polys[#polys + 1] = poly
        lines[#lines + 1] = line
    end
    local line = lines[1]
    if #lines > 1 then
        line = mergeLines(lines, F.MERGE_TOLERANCE)
        -- Disjoint pieces would need non-overlapping carrier cells proved; refuse
        -- rather than risk counting a cell twice.
        if line == nil then return nil, "CELL_OVERLAP" end
    end
    local dx, dz = line.bx - line.ax, line.bz - line.az
    local width = math.sqrt(dx * dx + dz * dz)
    if width < 0.01 then return nil, "UNKNOWN_GROUND" end
    return { line = line, paintPolys = polys, areaKey = areaKey, width = width }, nil
end

--- The swept quad between the anchor line and this line, tip-paired.
---@return table|nil verts, number travel, number areaM2
function F.sweptQuad(anchor, line)
    if anchor == nil or line == nil then return nil, 0, 0 end
    -- Pair each tip with its nearer anchor tip by the summed squared tip distances.
    -- (The summed displacement vector cannot tell a swapped pair from a straight one:
    -- for a boom moved straight ahead both sums are the same vector.)
    local function d2(x1, z1, x2, z2) return (x1 - x2) * (x1 - x2) + (z1 - z2) * (z1 - z2) end
    local straight = d2(line.ax, line.az, anchor.ax, anchor.az) + d2(line.bx, line.bz, anchor.bx, anchor.bz)
    local swapped  = d2(line.ax, line.az, anchor.bx, anchor.bz) + d2(line.bx, line.bz, anchor.ax, anchor.az)
    local ax, az, bx, bz = line.ax, line.az, line.bx, line.bz
    if swapped < straight then
        ax, az, bx, bz = line.bx, line.bz, line.ax, line.az
    end
    -- travel is the movement of the line's midpoint
    local tx = (ax + bx - anchor.ax - anchor.bx) * 0.5
    local tz = (az + bz - anchor.az - anchor.bz) * 0.5
    local verts = {
        { x = anchor.ax, z = anchor.az }, { x = anchor.bx, z = anchor.bz },
        { x = bx, z = bz }, { x = ax, z = az },
    }
    local area = 0
    for i = 1, 4 do
        local p, q = verts[i], verts[i % 4 + 1]
        area = area + (p.x * q.z - q.x * p.z)
    end
    return verts, math.sqrt(tx * tx + tz * tz), math.abs(area) * 0.5
end

--- The x-extent of a polygon over the horizontal band [z0, z1]: every vertex in the
--- band and every edge crossing a band edge. nil when the polygon misses the band.
local function bandExtent(poly, z0, z1)
    local lo, hi = nil, nil
    local function take(x)
        if lo == nil or x < lo then lo = x end
        if hi == nil or x > hi then hi = x end
    end
    local n = #poly
    for i = 1, n do
        local p, q = poly[i], poly[i % n + 1]
        if p.z >= z0 and p.z <= z1 then take(p.x) end
        for _, zc in ipairs({ z0, z1 }) do
            if (p.z - zc) * (q.z - zc) < 0 then
                take(p.x + (q.x - p.x) * (zc - p.z) / (q.z - p.z))
            end
        end
        -- a horizontal edge lying inside the band is covered by its two vertices
    end
    return lo, hi
end

--- Every fine cell whose square, grown by `halo` cells, meets one of the polygons.
--- The cell (i, j) spans [-T/2 + i*g, -T/2 + (i+1)*g] on each axis; fn(i, j, cx, cz)
--- receives its centre. Returns the number of distinct cells, or nil with a reason
--- (OUTSIDE_MAP when a polygon leaves the terrain, UNKNOWN_GROUND over budget).
function F.forEachCell(polys, grain, halo, terrainSize, fn)
    local half = terrainSize * 0.5
    local h = halo * grain
    local seen, count = {}, 0
    local cellsPerRow = math.floor(terrainSize / grain + 0.5)
    for _, poly in ipairs(polys) do
        local minZ, maxZ
        for _, v in ipairs(poly) do
            if v.x < -half or v.x > half or v.z < -half or v.z > half then return nil, "OUTSIDE_MAP" end
            if minZ == nil or v.z < minZ then minZ = v.z end
            if maxZ == nil or v.z > maxZ then maxZ = v.z end
        end
        local j0 = math.max(0, math.floor((minZ - h + half) / grain))
        local j1 = math.min(cellsPerRow - 1, math.floor((maxZ + h + half) / grain))
        for j = j0, j1 do
            local z0 = -half + j * grain - h
            local z1 = -half + (j + 1) * grain + h
            local lo, hi = bandExtent(poly, z0, z1)
            if lo ~= nil then
                local i0 = math.max(0, math.floor((lo - h + half) / grain))
                local i1 = math.min(cellsPerRow - 1, math.floor((hi + h + half) / grain))
                for i = i0, i1 do
                    local key = j * cellsPerRow + i
                    if not seen[key] then
                        seen[key] = true
                        count = count + 1
                        if count > F.MAX_CELLS then return nil, "UNKNOWN_GROUND" end
                        fn(i, j, -half + (i + 0.5) * grain, -half + (j + 0.5) * grain, key)
                    end
                end
            end
        end
    end
    return count, nil
end

--- Classify one cell centre: its farmland, whether it is field ground, and its fruit.
local function readCell(env, x, z)
    local farmland = env.farmlandAt(x, z)
    local onField = env.onField(x, z)
    local fruitIndex, growthState = env.fruitAt(x, z)
    return { farmland = farmland, onField = onField, fruit = fruitIndex, growth = growthState, x = x, z = z }
end

--- The witness over the swept quad and the native paint polygons, with the guard.
---@param polys table        the polygons that can meet treated ground
---@param opts table         { farmId, env, cache, soilRecordFor(farmlandId), cropKeyFor(desc) }
---@return table verdict { accepted, state, reasons = {..}, fruitIndex, cropKey, farmlandId, cells }
function F.witness(polys, opts)
    local env = opts.env or F.ENGINE
    local verdict = { accepted = false, reasons = {}, cells = 0, newCells = 0 }
    local reasons = {}
    local function add(reason) reasons[reason] = true end

    local terrainSize = env.terrainSize()
    local grain = terrainSize and env.fruitGrain(terrainSize)
    if terrainSize == nil or grain == nil or grain <= 0 then
        add("UNKNOWN_GROUND")
    else
        local cache = opts.cache or {}
        local access = opts.accessCache or {}
        local cropKeys = opts.cropKeyCache or {}
        local fruit, farmland = nil, nil
        local count, why = F.forEachCell(polys, grain, F.GUARD_CELLS, terrainSize, function(_i, _j, cx, cz, key)
            local c = cache[key]
            if c == nil then
                c = readCell(env, cx, cz)
                cache[key] = c
                verdict.newCells = verdict.newCells + 1
            end
            if c.farmland == nil or c.farmland == 0 or c.onField ~= true then add("UNKNOWN_GROUND") return end
            if opts.soilRecordFor ~= nil and not opts.soilRecordFor(c.farmland) then add("UNKNOWN_GROUND") return end
            if env.engineFieldFor(c.farmland) == nil then add("UNKNOWN_GROUND") return end
            local ok = access[c.farmland]
            if ok == nil then
                ok = env.canAccess(opts.farmId, c.x, c.z) == true
                access[c.farmland] = ok
            end
            if not ok then add("FARM_ACCESS") end
            if farmland ~= nil and c.farmland ~= farmland then add("MIXED_FIELD") end
            farmland = farmland or c.farmland
            -- Bare ground is not a crop an ordinary sprayer can target.
            if c.fruit == nil or c.fruit == 0 then add("UNKNOWN_GROUND") return end
            local desc = env.fruitDesc(c.fruit)
            local ck = cropKeys[c.fruit]
            if ck == nil then
                ck = (desc ~= nil and opts.cropKeyFor ~= nil and opts.cropKeyFor(desc)) or false
                cropKeys[c.fruit] = ck
            end
            -- A cut or withered state is not a growing crop to feed.
            local living = desc ~= nil and type(c.growth) == "number" and c.growth > 0
            if living and type(desc.getIsCut) == "function" and desc:getIsCut(c.growth) then living = false end
            if living and type(desc.getIsWithered) == "function" and desc:getIsWithered(c.growth) then living = false end
            if not ck or not living then add("UNSUPPORTED_CROP") end
            if fruit ~= nil and c.fruit ~= fruit then add("MIXED_CROP") end
            fruit = fruit or c.fruit
        end)
        if count == nil then add(why) else verdict.cells = count end
        if count == 0 then add("UNKNOWN_GROUND") end
        verdict.fruitIndex = fruit
        verdict.farmlandId = farmland
        verdict.cropKey = (fruit ~= nil and cropKeys[fruit]) or nil
        if verdict.cropKey == false then verdict.cropKey = nil end
    end

    for _, r in ipairs(TargetNutrientCore.REASON_ORDER) do
        if reasons[r] then verdict.reasons[#verdict.reasons + 1] = r end
    end
    if #verdict.reasons == 0 then
        verdict.accepted = true
        verdict.state = nil
    elseif reasons.UNKNOWN_GROUND or reasons.OUTSIDE_MAP then
        verdict.state = TargetNutrientCore.STATE.UNDETERMINED
    else
        verdict.state = TargetNutrientCore.STATE.INACTIVE
    end
    return verdict
end
