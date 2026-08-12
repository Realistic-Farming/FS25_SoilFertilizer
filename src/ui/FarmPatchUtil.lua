-- =========================================================
-- FarmPatchUtil â€” session UI farm patches (presentation only)
-- =========================================================
-- George GO WITH CONSTRAINTS 2026-08-11: polygon edge-proximity
-- union-find; optional sparse densmap confirm on shared edges.
-- Never StateLedger. Rebuild on Esc open / list rebuild only.
-- Patch id = min(member farmland ids). Labels per Samantha CLOSED.
-- =========================================================

FarmPatchUtil = {}

local EDGE_EPSILON_M = 1.5
local MIN_SHARED_EDGE_M = 2.0
local MAX_SAMPLES_PER_EDGE = 8
local MAX_SAMPLES_PER_REBUILD = 200

--- World XZ ring from Field.polygonPoints (SCS getFieldPolygonWorld pattern).
---@param field table
---@return table|nil vx, table|nil vz, number|nil n
function FarmPatchUtil.getFieldPolygonWorld(field)
    if field == nil then
        return nil
    end
    local pts = field.polygonPoints
    if pts == nil then
        return nil
    end
    local n = #pts
    if n < 3 then
        return nil
    end
    local vx, vz = {}, {}
    for i = 1, n do
        local node = pts[i]
        if node == nil or node == 0 then
            return nil
        end
        local wx, _, wz = getWorldTranslation(node)
        vx[i] = wx
        vz[i] = wz
    end
    return vx, vz, n
end

local function ringAabb(vx, vz, n)
    local minX, maxX = vx[1], vx[1]
    local minZ, maxZ = vz[1], vz[1]
    for i = 2, n do
        if vx[i] < minX then minX = vx[i] end
        if vx[i] > maxX then maxX = vx[i] end
        if vz[i] < minZ then minZ = vz[i] end
        if vz[i] > maxZ then maxZ = vz[i] end
    end
    return minX, maxX, minZ, maxZ
end

local function aabbOverlap(a, b, pad)
    return not (a.maxX + pad < b.minX or b.maxX + pad < a.minX
        or a.maxZ + pad < b.minZ or b.maxZ + pad < a.minZ)
end

local function dist2(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return dx * dx + dz * dz
end

--- Squared distance from point to segment.
local function pointSegDistSq(px, pz, ax, az, bx, bz)
    local abx, abz = bx - ax, bz - az
    local apx, apz = px - ax, pz - az
    local ab2 = abx * abx + abz * abz
    if ab2 < 1e-12 then
        return dist2(px, pz, ax, az)
    end
    local t = (apx * abx + apz * abz) / ab2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qz = ax + abx * t, az + abz * t
    return dist2(px, pz, qx, qz)
end

--- Approximate shared-edge length when two segments are within epsilon.
--- Returns length along the longer segment of the near-overlap corridor.
local function sharedEdgeLength(ax, az, bx, bz, cx, cz, dx, dz, eps)
    local eps2 = eps * eps
    -- Endpoint proximity to other segment
    local aNear = pointSegDistSq(ax, az, cx, cz, dx, dz) <= eps2
    local bNear = pointSegDistSq(bx, bz, cx, cz, dx, dz) <= eps2
    local cNear = pointSegDistSq(cx, cz, ax, az, bx, bz) <= eps2
    local dNear = pointSegDistSq(dx, dz, ax, az, bx, bz) <= eps2

    local minSeg = math.min(
        pointSegDistSq(ax, az, cx, cz, dx, dz),
        pointSegDistSq(bx, bz, cx, cz, dx, dz),
        pointSegDistSq(cx, cz, ax, az, bx, bz),
        pointSegDistSq(dx, dz, ax, az, bx, bz)
    )
    if minSeg > eps2 then
        return 0
    end

    -- Project endpoints onto the other segment; measure overlap span.
    local function projT(px, pz, ox, oz, tx, tz)
        local vx, vz = tx - ox, tz - oz
        local len2 = vx * vx + vz * vz
        if len2 < 1e-12 then return 0, 0 end
        local t = ((px - ox) * vx + (pz - oz) * vz) / len2
        return t, math.sqrt(len2)
    end

    local nearCount = (aNear and 1 or 0) + (bNear and 1 or 0) + (cNear and 1 or 0) + (dNear and 1 or 0)
    if nearCount < 2 and minSeg > (eps * 0.25) * (eps * 0.25) then
        -- Corner kiss only
        return 0
    end

    local t1, lenAB = projT(cx, cz, ax, az, bx, bz)
    local t2 = select(1, projT(dx, dz, ax, az, bx, bz))
    local lo = math.max(0, math.min(t1, t2))
    local hi = math.min(1, math.max(t1, t2))
    local overlapAB = math.max(0, hi - lo) * lenAB

    local t3, lenCD = projT(ax, az, cx, cz, dx, dz)
    local t4 = select(1, projT(bx, bz, cx, cz, dx, dz))
    local lo2 = math.max(0, math.min(t3, t4))
    local hi2 = math.min(1, math.max(t3, t4))
    local overlapCD = math.max(0, hi2 - lo2) * lenCD

    local shared = math.max(overlapAB, overlapCD)
    if shared < 0.01 and nearCount >= 2 then
        -- Nearly coincident short stubs: use min segment length as shared proxy
        shared = math.min(lenAB, lenCD) * 0.5
    end
    return shared
end

local function densmapOnField(x, z, sampleBudget)
    if sampleBudget.used >= sampleBudget.max then
        return true -- budget exhausted: do not veto join
    end
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFieldDataAtWorldPosition == nil then
        return true
    end
    sampleBudget.used = sampleBudget.used + 1
    local ok, isOnField = pcall(function()
        local onField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
        return onField
    end)
    if not ok then
        return true
    end
    return isOnField == true
end

--- Sample corridor midpoints between two near edges; require most samples on field.
local function densmapConfirmSharedEdge(ax, az, bx, bz, cx, cz, dx, dz, sampleBudget)
    local n = math.min(MAX_SAMPLES_PER_EDGE, 8)
    local hits = 0
    local tried = 0
    for i = 1, n do
        if sampleBudget.used >= sampleBudget.max then
            break
        end
        local t = (i - 0.5) / n
        local mx1 = ax + (bx - ax) * t
        local mz1 = az + (bz - az) * t
        local mx2 = cx + (dx - cx) * t
        local mz2 = cz + (dz - cz) * t
        local mx = (mx1 + mx2) * 0.5
        local mz = (mz1 + mz2) * 0.5
        tried = tried + 1
        if densmapOnField(mx, mz, sampleBudget) then
            hits = hits + 1
        end
    end
    if tried == 0 then
        return true
    end
    return hits >= math.max(1, math.floor(tried * 0.5 + 0.5))
end

local function polygonsEdgeAdjacent(ra, rb, sampleBudget, useDensmap)
    if not aabbOverlap(ra, rb, EDGE_EPSILON_M) then
        return false
    end
    local na, nb = ra.n, rb.n
    for i = 1, na do
        local i2 = (i % na) + 1
        local ax, az = ra.vx[i], ra.vz[i]
        local bx, bz = ra.vx[i2], ra.vz[i2]
        for j = 1, nb do
            local j2 = (j % nb) + 1
            local cx, cz = rb.vx[j], rb.vz[j]
            local dx, dz = rb.vx[j2], rb.vz[j2]
            local shared = sharedEdgeLength(ax, az, bx, bz, cx, cz, dx, dz, EDGE_EPSILON_M)
            if shared >= MIN_SHARED_EDGE_M then
                if not useDensmap then
                    return true
                end
                if densmapConfirmSharedEdge(ax, az, bx, bz, cx, cz, dx, dz, sampleBudget) then
                    return true
                end
            end
        end
    end
    return false
end

--- Samantha labels: Block Â· fields aâ€“b / comma list; singleton Field {id}.
---@param memberIds number[] sorted
---@param tr fun(key:string, fallback:string):string|nil
---@return string
function FarmPatchUtil.formatPatchLabel(memberIds, tr)
    tr = tr or function(_, fb) return fb end
    local n = #(memberIds or {})
    if n == 0 then
        return tr("rf_farm_patch_unknown", "Field ?")
    end
    if n == 1 then
        local tpl = tr("rf_farm_patch_singleton", "Field %s")
        local ok, s = pcall(string.format, tpl, tostring(memberIds[1]))
        return ok and s or ("Field " .. tostring(memberIds[1]))
    end

    local contiguous = true
    for i = 2, n do
        if tonumber(memberIds[i]) ~= tonumber(memberIds[i - 1]) + 1 then
            contiguous = false
            break
        end
    end
    if contiguous then
        local tpl = tr("rf_farm_patch_block_range", "Block Â· fields %sâ€“%s")
        local ok, s = pcall(string.format, tpl, tostring(memberIds[1]), tostring(memberIds[n]))
        return ok and s or string.format("Block Â· fields %sâ€“%s", tostring(memberIds[1]), tostring(memberIds[n]))
    end

    local show = {}
    local limit = math.min(4, n)
    for i = 1, limit do
        show[#show + 1] = tostring(memberIds[i])
    end
    local list = table.concat(show, ", ")
    if n > 4 then
        local tpl = tr("rf_farm_patch_block_list_more", "Block Â· fields %s +%d")
        local ok, s = pcall(string.format, tpl, list, n - 4)
        return ok and s or string.format("Block Â· fields %s +%d", list, n - 4)
    end
    local tpl = tr("rf_farm_patch_block_list", "Block Â· fields %s")
    local ok, s = pcall(string.format, tpl, list)
    return ok and s or ("Block Â· fields " .. list)
end

--- Format pivot cover subset for switcher: "1â€“3" or "1, 3, 5".
---@param ids number[]
---@return string
function FarmPatchUtil.formatFieldIdSubset(ids)
    local n = #(ids or {})
    if n == 0 then
        return "-"
    end
    local sorted = {}
    for i = 1, n do
        sorted[i] = tonumber(ids[i]) or ids[i]
    end
    table.sort(sorted, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a) < tostring(b)
    end)
    local contiguous = true
    for i = 2, n do
        if tonumber(sorted[i]) ~= tonumber(sorted[i - 1]) + 1 then
            contiguous = false
            break
        end
    end
    if contiguous and n > 1 then
        return string.format("%sâ€“%s", tostring(sorted[1]), tostring(sorted[n]))
    end
    local parts = {}
    for i = 1, math.min(n, 6) do
        parts[#parts + 1] = tostring(sorted[i])
    end
    if n > 6 then
        parts[#parts + 1] = "+" .. tostring(n - 6)
    end
    return table.concat(parts, ", ")
end

local function ufFind(parent, i)
    while parent[i] ~= i do
        parent[i] = parent[parent[i]]
        i = parent[i]
    end
    return i
end

local function ufUnion(parent, a, b)
    local ra, rb = ufFind(parent, a), ufFind(parent, b)
    if ra ~= rb then
        parent[rb] = ra
    end
end

--- Build session patches from owned farmland ids.
---@param ownedFieldIds number[] farmland ids
---@param opts table|nil { fieldLookup=fn(id)->Field, useDensmapConfirm=bool, tr=fn }
---@return table[] { patchId, memberFieldIds, label }
function FarmPatchUtil.buildPatches(ownedFieldIds, opts)
    opts = opts or {}
    local tr = opts.tr
    local useDensmap = opts.useDensmapConfirm ~= false
    local fieldLookup = opts.fieldLookup
    local patches = {}

    local ids = {}
    for _, id in ipairs(ownedFieldIds or {}) do
        if id ~= nil then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a) < tostring(b)
    end)

    if #ids == 0 then
        return patches
    end

    -- Default field lookup via g_fieldManager (farmland.id key).
    if fieldLookup == nil then
        fieldLookup = function(fid)
            if g_fieldManager == nil or g_fieldManager.fields == nil then
                return nil
            end
            for _, field in pairs(g_fieldManager.fields) do
                local fl = field and field.farmland
                if fl ~= nil and fl.id == fid then
                    return field
                end
            end
            return nil
        end
    end

    local rings = {}
    for i, fid in ipairs(ids) do
        local field = fieldLookup(fid)
        local vx, vz, n = FarmPatchUtil.getFieldPolygonWorld(field)
        if vx ~= nil then
            local minX, maxX, minZ, maxZ = ringAabb(vx, vz, n)
            rings[i] = {
                fid = fid,
                vx = vx, vz = vz, n = n,
                minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ,
            }
        else
            rings[i] = { fid = fid, n = 0 }
        end
    end

    local parent = {}
    for i = 1, #ids do
        parent[i] = i
    end

    local sampleBudget = { used = 0, max = MAX_SAMPLES_PER_REBUILD }
    for i = 1, #ids do
        local ri = rings[i]
        if ri.n ~= nil and ri.n >= 3 then
            for j = i + 1, #ids do
                local rj = rings[j]
                if rj.n ~= nil and rj.n >= 3 then
                    if polygonsEdgeAdjacent(ri, rj, sampleBudget, useDensmap) then
                        ufUnion(parent, i, j)
                    end
                end
            end
        end
    end

    local groups = {}
    for i = 1, #ids do
        local root = ufFind(parent, i)
        if groups[root] == nil then
            groups[root] = {}
        end
        groups[root][#groups[root] + 1] = ids[i]
    end

    local roots = {}
    for root, _ in pairs(groups) do
        roots[#roots + 1] = root
    end
    table.sort(roots, function(a, b)
        local ma = groups[a][1]
        local mb = groups[b][1]
        local na, nb = tonumber(ma), tonumber(mb)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(ma) < tostring(mb)
    end)

    for _, root in ipairs(roots) do
        local members = groups[root]
        table.sort(members, function(a, b)
            local na, nb = tonumber(a), tonumber(b)
            if na ~= nil and nb ~= nil then return na < nb end
            return tostring(a) < tostring(b)
        end)
        local patchId = members[1]
        for _, m in ipairs(members) do
            local nm, np = tonumber(m), tonumber(patchId)
            if nm ~= nil and np ~= nil then
                if nm < np then patchId = m end
            elseif tostring(m) < tostring(patchId) then
                patchId = m
            end
        end
        patches[#patches + 1] = {
            patchId = patchId,
            memberFieldIds = members,
            label = FarmPatchUtil.formatPatchLabel(members, tr),
        }
    end

    return patches
end
