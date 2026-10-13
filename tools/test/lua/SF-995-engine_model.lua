-- SF-995-engine_model.lua
--
-- The engine under the value-map sync, MODELED for the #995 cost bar: bit vector
-- maps as pixel tables at the resolution a persisted map adopts (SoilValueMaps
-- adopts the first loaded layer's size, :270-300, so a 64 px file gives a 64-row
-- sync grid instead of the 1024 px minimum a fresh map gets), the density-map
-- modifier writing world-coordinate parallelograms and polygons through a BETWEEN
-- filter the way SoilValueMaps calls it, and the two engine calls the cost bar
-- counts per tick: getBitVectorMapPoint (readSyncRow) and executeSet (applySyncRow).
--
-- Loaded AFTER the prelude, so it overwrites the prelude's shape-only stubs.

ENGINE = ENGINE or {}
ENGINE.TERRAIN = 64          -- metres, centred on the origin
ENGINE.RESOLUTION = 64       -- the persisted resolution the maps adopt: 1 m/px, stride 1
ENGINE.calls = { getBitVectorMapPoint = 0, executeSet = 0, executeAdd = 0 }
ENGINE.maxPerTick = { getBitVectorMapPoint = 0, executeSet = 0 }

--- Close one tick's accounting: fold the tick's counts into the maxima, reset them,
--- and return the closed tick's counts.
function ENGINE.tickBoundary()
    local closed = {}
    for k, v in pairs(ENGINE.calls) do
        closed[k] = v
        if ENGINE.maxPerTick[k] ~= nil and v > ENGINE.maxPerTick[k] then ENGINE.maxPerTick[k] = v end
        ENGINE.calls[k] = 0
    end
    return closed
end
function ENGINE.resetMax()
    for k in pairs(ENGINE.maxPerTick) do ENGINE.maxPerTick[k] = 0 end
    for k in pairs(ENGINE.calls) do ENGINE.calls[k] = 0 end
end

-- ── bit vector maps ─────────────────────────────────────────────────────────
local BVMS = {}
local nextId = 0
function createBitVectorMap(name)
    nextId = nextId + 1
    BVMS[nextId] = { name = name, size = 0, cells = {} }
    return nextId
end
function loadBitVectorMapNew(bvm, w, _h, _channels, _unused)
    local m = BVMS[bvm]
    m.size, m.cells = w, {}
    return true
end
-- Every layer file "exists" and loads at the model's resolution; a file this session
-- saved (saveBitVectorMapToFile, by path) loads back with its content, as a savegame does.
ENGINE.disk = ENGINE.disk or {}
function loadBitVectorMapFromFile(bvm, path, _channels)
    local m = BVMS[bvm]
    m.size, m.cells = ENGINE.RESOLUTION, {}
    local saved = ENGINE.disk[path]
    if saved ~= nil then for k, v in pairs(saved) do m.cells[k] = v end end
    return true
end
function saveBitVectorMapToFile(bvm, path)
    local m = BVMS[bvm]
    local copy = {}
    for k, v in pairs(m.cells) do copy[k] = v end
    ENGINE.disk[path] = copy
    return true
end
function getBitVectorMapSize(bvm)
    local m = BVMS[bvm]
    return m.size, m.size
end
function getBitVectorMapPoint(bvm, px, pz, _first, _num)
    ENGINE.calls.getBitVectorMapPoint = ENGINE.calls.getBitVectorMapPoint + 1
    local m = BVMS[bvm]
    return m.cells[pz * m.size + px] or 0
end
--- The bench's own read of a pixel (not an engine call, not counted).
function ENGINE.pixel(bvm, px, pz)
    local m = BVMS[bvm]
    return m.cells[pz * m.size + px] or 0
end
function fileExists(_path) return true end
function getTerrainSize(_node) return ENGINE.TERRAIN end
g_terrainNode = 1
DensityCoordType = { POINT_POINT_POINT = 1 }
DensityValueCompareType = { GREATER = 1, BETWEEN = 2, EQUAL = 3 }
DensityRoundingMode = { INCLUSIVE = 1 }
PerlinNoiseFilter = nil   -- seeding without noise (SoilValueMaps:_initNoiseMasks returns)

-- The map's pixel of a world point, as SoilValueMaps.worldToPixel maps it.
local function pixelOf(size, x, z)
    local half = ENGINE.TERRAIN * 0.5
    local px = math.floor((x + half) / ENGINE.TERRAIN * size)
    local pz = math.floor((z + half) / ENGINE.TERRAIN * size)
    return math.max(0, math.min(size - 1, px)), math.max(0, math.min(size - 1, pz))
end

-- ── filters and the modifier ────────────────────────────────────────────────
DensityMapFilter = { new = function(_modifierOrMap)
    local f = { op = nil, a = nil, b = nil }
    f.setValueCompareParams = function(_self, op, a, b) f.op, f.a, f.b = op, a, b end
    return f
end }
local function filterPasses(filter, v)
    if filter == nil or filter.op == nil then return true end
    if filter.op == DensityValueCompareType.BETWEEN then return v >= filter.a and v <= filter.b end
    if filter.op == DensityValueCompareType.EQUAL then return v == filter.a end
    if filter.op == DensityValueCompareType.GREATER then return v > filter.a end
    return true
end

DensityMapModifier = { new = function(bvm, _first, _num, _node)
    local m = { bvm = bvm, region = nil }
    -- world-coordinate parallelogram: start, width point, height point
    m.setParallelogramWorldCoords = function(_self, sx, sz, wx, wz, hx, hz, _coordType)
        m.region = { kind = "para", sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz }
    end
    m.clearPolygonPoints = function(_self) m.region = { kind = "poly", verts = {} } end
    m.addPolygonPointWorldCoords = function(_self, x, z)
        if m.region == nil or m.region.kind ~= "poly" then m.region = { kind = "poly", verts = {} } end
        local v = m.region.verts
        v[#v + 1] = { x = x, z = z }
    end
    local function inside(r, x, z)
        if r.kind == "para" then
            local ux, uz = r.wx - r.sx, r.wz - r.sz
            local vx, vz = r.hx - r.sx, r.hz - r.sz
            local det = ux * vz - uz * vx
            if math.abs(det) < 1e-9 then return false end
            local dx, dz = x - r.sx, z - r.sz
            local a = (dx * vz - dz * vx) / det
            local b = (ux * dz - uz * dx) / det
            return a >= 0 and a <= 1 and b >= 0 and b <= 1
        end
        -- ray casting, the shape of SoilValueMaps.isPointInPoly
        local verts = r.verts
        local n = #verts
        if n < 3 then return false end
        local ins, j = false, n
        for i = 1, n do
            local xi, zi, xj, zj = verts[i].x, verts[i].z, verts[j].x, verts[j].z
            if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then ins = not ins end
            j = i
        end
        return ins
    end
    local function each(fn)
        local map = BVMS[m.bvm]
        local size = map.size
        local r = m.region
        if r == nil or size == 0 then return end
        local half = ENGINE.TERRAIN * 0.5
        local mPerPx = ENGINE.TERRAIN / size
        local x0, x1, z0, z1
        local function span(x, z)
            if x0 == nil or x < x0 then x0 = x end
            if x1 == nil or x > x1 then x1 = x end
            if z0 == nil or z < z0 then z0 = z end
            if z1 == nil or z > z1 then z1 = z end
        end
        if r.kind == "para" then
            span(r.sx, r.sz); span(r.wx, r.wz); span(r.hx, r.hz); span(r.wx + r.hx - r.sx, r.wz + r.hz - r.sz)
        else
            for _, v in ipairs(r.verts) do span(v.x, v.z) end
        end
        if x0 == nil then return end
        local px0, pz0 = pixelOf(size, x0, z0)
        local px1, pz1 = pixelOf(size, x1, z1)
        for pz = pz0, pz1 do
            for px = px0, px1 do
                local cx, cz = -half + (px + 0.5) * mPerPx, -half + (pz + 0.5) * mPerPx
                if inside(r, cx, cz) then fn(map, pz * size + px) end
            end
        end
    end
    m.executeSet = function(_self, value, filter)
        ENGINE.calls.executeSet = ENGINE.calls.executeSet + 1
        each(function(map, i)
            if filterPasses(filter, map.cells[i] or 0) then map.cells[i] = value end
        end)
    end
    m.executeAdd = function(_self, delta, filter)
        ENGINE.calls.executeAdd = ENGINE.calls.executeAdd + 1
        each(function(map, i)
            local v = map.cells[i] or 0
            if filterPasses(filter, v) then map.cells[i] = v + delta end
        end)
    end
    m.executeGet = function(_self, filter)
        local sum, n, total = 0, 0, 0
        each(function(map, i)
            local v = map.cells[i] or 0
            total = total + 1
            if filterPasses(filter, v) then sum = sum + v; n = n + 1 end
        end)
        return sum, n, total
    end
    return m
end }
