-- =========================================================
-- FS25 Soil & Fertilizer - PolygonClip (RSF-F211)
-- =========================================================
-- Pure planar geometry for the standing-material reader: a field polygon (a point
-- table {{x=,z=}, ...}, either winding) is checked simple, triangulated into
-- non-overlapping triangles by ear clipping, and each Soil cell square is clipped
-- against those triangles (Sutherland-Hodgman, a convex clip) so the cell's uniform
-- native volume can be allocated by its actual overlap with the field. No GIANTS
-- polygon API is assumed; the decompiled MathUtil has no point-in-polygon or clip.
-- Everything here is deterministic and allocation-light: no engine calls.
--
-- Invalid input refuses: fewer than three finite points, a degenerate (zero-area)
-- polygon, or a self-intersecting one returns nil from triangulate, and the caller
-- refuses the standing decision rather than guess (RSF-F211 :120).
-- =========================================================

PolygonClip = PolygonClip or {}
local P = PolygonClip

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

--- Twice the signed area of a point-table polygon (positive when counter-clockwise
--- in the x/z plane as used here).
local function signedArea2(poly)
    local a = 0
    local n = #poly
    for i = 1, n do
        local p, q = poly[i], poly[i % n + 1]
        a = a + (p.x * q.z - q.x * p.z)
    end
    return a
end
function P.area(poly)
    return math.abs(signedArea2(poly)) * 0.5
end

local function cross(ax, az, bx, bz) return ax * bz - az * bx end

--- Proper segment intersection (excluding shared endpoints), for the simplicity test.
local function segmentsCross(a, b, c, d)
    local d1 = cross(b.x - a.x, b.z - a.z, c.x - a.x, c.z - a.z)
    local d2 = cross(b.x - a.x, b.z - a.z, d.x - a.x, d.z - a.z)
    local d3 = cross(d.x - c.x, d.z - c.z, a.x - c.x, a.z - c.z)
    local d4 = cross(d.x - c.x, d.z - c.z, b.x - c.x, b.z - c.z)
    return ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
end

--- A valid simple polygon: at least three finite points, positive area, and no two
--- non-adjacent edges crossing. Consecutive duplicate points are tolerated by the
--- caller's copy in triangulate.
function P.isSimple(poly)
    if type(poly) ~= "table" or #poly < 3 then return false end
    for i = 1, #poly do
        local v = poly[i]
        if type(v) ~= "table" or not finite(v.x) or not finite(v.z) then return false end
    end
    if math.abs(signedArea2(poly)) < 1e-9 then return false end
    local n = #poly
    for i = 1, n do
        local a, b = poly[i], poly[i % n + 1]
        for j = i + 1, n do
            local adjacent = (j == i + 1) or (i == 1 and j == n)
            if not adjacent then
                local c, d = poly[j], poly[j % n + 1]
                if segmentsCross(a, b, c, d) then return false end
            end
        end
    end
    return true
end

--- A triangle (three counter-clockwise points) carrying its bounding box, so a clip can
--- skip the triangles a cell's square cannot touch.
local function triangle(a, b, c)
    return { a, b, c,
             minX = math.min(a.x, b.x, c.x), maxX = math.max(a.x, b.x, c.x),
             minZ = math.min(a.z, b.z, c.z), maxZ = math.max(a.z, b.z, c.z) }
end

local function pointInTriangle(px, pz, a, b, c)
    local d1 = cross(b.x - a.x, b.z - a.z, px - a.x, pz - a.z)
    local d2 = cross(c.x - b.x, c.z - b.z, px - b.x, pz - b.z)
    local d3 = cross(a.x - c.x, a.z - c.z, px - c.x, pz - c.z)
    local hasNeg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local hasPos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (hasNeg and hasPos)
end

--- Ear-clipping triangulation of a simple polygon into non-overlapping triangles,
--- each a counter-clockwise point table of three. Returns nil for an invalid polygon.
function P.triangulate(poly)
    if not P.isSimple(poly) then return nil end
    -- Work on a counter-clockwise copy without consecutive duplicates.
    local pts = {}
    for i = 1, #poly do
        local v = poly[i]
        local last = pts[#pts]
        if last == nil or math.abs(last.x - v.x) > 1e-9 or math.abs(last.z - v.z) > 1e-9 then
            pts[#pts + 1] = { x = v.x, z = v.z }
        end
    end
    if #pts > 1 and math.abs(pts[1].x - pts[#pts].x) < 1e-9 and math.abs(pts[1].z - pts[#pts].z) < 1e-9 then pts[#pts] = nil end
    if #pts < 3 then return nil end
    if signedArea2(pts) < 0 then
        local rev = {}
        for i = #pts, 1, -1 do rev[#rev + 1] = pts[i] end
        pts = rev
    end
    local tris = {}
    local guard = 0
    while #pts > 3 and guard < 10000 do
        guard = guard + 1
        local n = #pts
        local clipped = false
        for i = 1, n do
            local prev, cur, nxt = pts[(i - 2) % n + 1], pts[i], pts[i % n + 1]
            local convex = cross(cur.x - prev.x, cur.z - prev.z, nxt.x - cur.x, nxt.z - cur.z) > 1e-12
            if convex then
                local ear = true
                for j = 1, n do
                    local q = pts[j]
                    if q ~= prev and q ~= cur and q ~= nxt and pointInTriangle(q.x, q.z, prev, cur, nxt) then
                        ear = false
                        break
                    end
                end
                if ear then
                    tris[#tris + 1] = triangle(prev, cur, nxt)
                    table.remove(pts, i)
                    clipped = true
                    break
                end
            end
        end
        if not clipped then return nil end   -- no ear found: not a simple polygon after all
    end
    if #pts == 3 then tris[#tris + 1] = triangle(pts[1], pts[2], pts[3]) end
    return tris
end

--- Sutherland-Hodgman: clip a convex subject polygon against a convex clip polygon
--- (both counter-clockwise point tables). Returns the clipped polygon (may be empty).
function P.clipConvex(subject, clip)
    local output = subject
    local m = #clip
    for i = 1, m do
        if #output == 0 then break end
        local a, b = clip[i], clip[i % m + 1]
        local input = output
        output = {}
        local function inside(p) return cross(b.x - a.x, b.z - a.z, p.x - a.x, p.z - a.z) >= 0 end
        local function intersect(p, q)
            local dx, dz = q.x - p.x, q.z - p.z
            local ex, ez = b.x - a.x, b.z - a.z
            local denom = cross(dx, dz, ex, ez)
            if math.abs(denom) < 1e-12 then return { x = p.x, z = p.z } end
            local t = cross(a.x - p.x, a.z - p.z, ex, ez) / denom
            return { x = p.x + t * dx, z = p.z + t * dz }
        end
        local s = input[#input]
        for k = 1, #input do
            local e = input[k]
            if inside(e) then
                if not inside(s) then output[#output + 1] = intersect(s, e) end
                output[#output + 1] = e
            elseif inside(s) then
                output[#output + 1] = intersect(s, e)
            end
            s = e
        end
    end
    return output
end

--- The fraction (0..1) of the axis-aligned square [x0,x1) x [z0,z1) that lies inside
--- the union of non-overlapping triangles (from triangulate): the sum of the clipped
--- areas over the square's area, clamped to 1 against rounding.
function P.overlapFraction(x0, z0, x1, z1, triangles)
    local w, h = x1 - x0, z1 - z0
    if not (finite(w) and finite(h)) or w <= 0 or h <= 0 or type(triangles) ~= "table" then return 0 end
    local square = { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } }
    local total = 0
    for _, tri in ipairs(triangles) do
        -- Only a triangle whose box meets the square can contribute (a triangle from
        -- triangulate carries its box; one without is always clipped).
        if tri.minX == nil or (tri.maxX > x0 and tri.minX < x1 and tri.maxZ > z0 and tri.minZ < z1) then
            local piece = P.clipConvex(square, tri)
            if #piece >= 3 then total = total + P.area(piece) end
        end
    end
    local frac = total / (w * h)
    if frac > 1 then frac = 1 end
    if frac < 1e-9 then frac = 0 end
    return frac
end

--- The polygon's bounding box: minX, minZ, maxX, maxZ.
function P.bounds(poly)
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, v in ipairs(poly) do
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end
    return minX, minZ, maxX, maxZ
end
