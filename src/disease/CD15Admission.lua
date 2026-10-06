-- =========================================================
-- FS25 Soil & Fertilizer - CD-15 local disease: discovery and admission (step 1c)
-- =========================================================
-- CD-15 implementation brief v1.14 (certificate 08-CD15):
--   :220      candidate discovery from actual cultivated polygons (and the retained rows), not
--             rectangular field centres or the disease-row list; a deterministic cursor, at most
--             256 cells per update, saved; a changed geometry, plane or native transition
--             invalidates cached membership;
--   :222      living state by the descriptor's own vocabulary: growing, harvest-ready or
--             harvestable, preparable or prepared are living; cut, withered and the mapped
--             destroyed state are not; an unknown state, plane or descriptor is UNKNOWN, never
--             empty. getIsGrowing alone stops before harvest and preparing states;
--   :239-243  the whole-cell witness: every distinct registered plane (fruit planes, and haulm
--             planes under their own meaning: residue, not another living crop), each plane's
--             getDensityMapSize, the loaded transform (the terrain centred on the origin), every
--             native pixel overlapping the cell, boundary partials included, read with
--             getDensityTypeIndexAtWorldPos and getDensityStatesAtWorldPos at its interior, the
--             descriptor's plane association validated before getGrowthStateByDensityState;
--   :99-103   admission of a completely classified standing crop: one occurrence token from the
--             saved sequence, cropName, nativeCropWitness.basis = OBSERVED_CURRENT_CROP, the cell's
--             cursor at the actual current monotonic day; no NEW-sow branch, no resistance halving,
--             no reset stamp, no harvested history.
--
-- THE PROFILE GATE (:220, :243; Bob's intake, Tyson 2026-09-30 "1c ships answering
-- UNKNOWN_OCCURRENCE"). A KNOWN witness needs a supported native profile that records the worst
-- synchronous read count and latency. TESTING rows 32 and 33 (the native cell probe) have no
-- result, so PROFILES is empty in production: every witness answers UNKNOWN_OCCURRENCE before any
-- pixel read, nothing is admitted, and the status names the reason. The procedure is whole and is
-- benched under a bench-only profile.
--
-- WHERE IT RUNS. CD15Model:update calls discover with what the day work left of the one 256 bound,
-- behind the model's hold (RESTORING, QUARANTINED, a seam that threw), so a held model discovers and
-- admits nothing and its cursor does not move. Server only.
-- =========================================================

CD15Admission = CD15Admission or {}
local A = CD15Admission
local G = CD15Grid

A.BASIS = "OBSERVED_CURRENT_CROP"
A.UNKNOWN_OCCURRENCE = "UNKNOWN_OCCURRENCE"
A.LIVING, A.NOT_LIVING, A.UNKNOWN = "LIVING", "NOT_LIVING", "UNKNOWN"
--- Supported native profiles: { id, maxReadsPerCell }. EMPTY in production (see the header).
A.PROFILES = A.PROFILES or {}
A.stats = A.stats or { reads = 0 }

local isFinite, isInteger = G.isFinite, G.isInteger
local function nonempty(s, n) return type(s) == "string" and s ~= "" and #s <= (n or 128) end

--- A short deterministic digest of a string (the plane set in a witness: the save keeps witness
--- strings to 256 bytes, CD15Save's decode). Arithmetic only, so it needs no bit library, and every
--- step stays below 2^31, so a double (the game) and a 32-bit integer agree exactly.
A.DIGEST_MOD = 16777213
function A.digest(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % A.DIGEST_MOD end
    return string.format("%06x", h)
end

--- The first supported profile, or nil.
function A.supportedProfile()
    for _, p in ipairs(A.PROFILES) do
        if type(p) == "table" and nonempty(p.id, 64) and isInteger(p.maxReadsPerCell) and p.maxReadsPerCell > 0 then return p end
    end
    return nil
end

-- ---------------------------------------------------------
-- Classification (:222)
-- ---------------------------------------------------------
local function call(desc, name, growth)
    local f = desc[name]
    if type(f) ~= "function" then return false end
    local ok, v = pcall(f, desc, growth)
    return ok and v == true
end

--- One decoded growth state by its descriptor's vocabulary: EMPTY, LIVING, NONLIVING or UNKNOWN.
function A.classifyState(desc, growth)
    if type(desc) ~= "table" or not isInteger(growth) or growth < 0 then return "UNKNOWN" end
    if growth == 0 then return "EMPTY" end
    if call(desc, "getIsCut", growth) or call(desc, "getIsWithered", growth) then return "NONLIVING" end
    if isInteger(desc.disasterDestructionState) and desc.disasterDestructionState > 0 and growth == desc.disasterDestructionState then return "NONLIVING" end
    if call(desc, "getIsGrowing", growth) or call(desc, "getIsHarvestReady", growth) or call(desc, "getIsHarvestable", growth)
        or call(desc, "getIsPreparable", growth) or (isInteger(desc.preparedGrowthState) and desc.preparedGrowthState > 0 and growth == desc.preparedGrowthState) then
        return "LIVING"
    end
    return "UNKNOWN"
end

-- ---------------------------------------------------------
-- The planes (:239)
-- ---------------------------------------------------------
--- The distinct registered planes, sorted by id: { id, kind = FRUIT|HAULM, size }, and their
--- fingerprint; or nil and a reason. A plane registered as both kinds is UNKNOWN (PLANE_KIND).
function A.resolvePlanes()
    local ftm = g_fruitTypeManager
    if ftm == nil or type(ftm.getFruitTypes) ~= "function" or getDensityMapSize == nil then return nil, "NO_FRUIT_PLANES" end
    local ok, descs = pcall(ftm.getFruitTypes, ftm)
    if not ok or type(descs) ~= "table" then return nil, "NO_FRUIT_PLANES" end
    local byId = {}
    local function add(id, kind)
        if not isInteger(id) or id == 0 then return true end
        local p = byId[id]
        if p == nil then byId[id] = { id = id, kind = kind } return true end
        return p.kind == kind
    end
    for _, desc in pairs(descs) do
        if type(desc) == "table" then
            if not add(desc.terrainDataPlaneId, "FRUIT") or not add(desc.terrainDataPlaneIdHaulm, "HAULM") then return nil, "PLANE_KIND" end
        end
    end
    local planes, parts = {}, {}
    for _, p in pairs(byId) do planes[#planes + 1] = p end
    if #planes == 0 then return nil, "NO_FRUIT_PLANES" end
    table.sort(planes, function(a, b) return a.id < b.id end)
    for _, p in ipairs(planes) do
        local okS, size = pcall(getDensityMapSize, p.id)
        if not okS or not isInteger(size) or size <= 0 then return nil, "PLANE_SIZE" end
        p.size = size
        parts[#parts + 1] = string.format("%d:%s:%d", p.id, p.kind, size)
    end
    return planes, table.concat(parts, ";")
end

-- ---------------------------------------------------------
-- The whole-cell witness (:239-243)
-- ---------------------------------------------------------
--- The native pixel index range [i0, i1] of a plane overlapping [lo, hi) (world metres).
local function pixelRange(lo, hi, half, pixel, size)
    local i0 = math.floor((lo + half) / pixel)
    local i1 = math.ceil((hi + half) / pixel) - 1
    if i0 < 0 then i0 = 0 end
    if i1 > size - 1 then i1 = size - 1 end
    return i0, i1
end

--- Witness one fine cell. Returns { state = LIVING|NOT_LIVING|UNKNOWN, reason, cropName, fields }.
--- With no supported profile it answers UNKNOWN_OCCURRENCE before any read.
function A.witness(geom, planes, planeFingerprint, gx, gz, profile)
    if profile == nil then return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. ":NO_SUPPORTED_PROFILE" } end
    if planes == nil then return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. ":" .. tostring(planeFingerprint) } end
    if getDensityTypeIndexAtWorldPos == nil or getDensityStatesAtWorldPos == nil then return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. ":NO_PIXEL_READ" } end
    local half = geom.terrainSize / 2
    local minX, minZ = -half + gx * geom.cellSize, -half + gz * geom.cellSize
    local maxX, maxZ = minX + geom.cellSize, minZ + geom.cellSize
    -- The read count first, against the profile's observed budget (:220): never start a cell
    -- the profile cannot finish.
    local ranges, total = {}, 0
    for i, p in ipairs(planes) do
        local pixel = geom.terrainSize / p.size
        local x0, x1 = pixelRange(minX, maxX, half, pixel, p.size)
        local z0, z1 = pixelRange(minZ, maxZ, half, pixel, p.size)
        ranges[i] = { pixel = pixel, x0 = x0, x1 = x1, z0 = z0, z1 = z1 }
        total = total + math.max(0, x1 - x0 + 1) * math.max(0, z1 - z0 + 1)
    end
    if total > profile.maxReadsPerCell then return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. ":READ_BUDGET" } end
    local ftm = g_fruitTypeManager
    local living, unknown, nonliving, empty, haulm = {}, 0, 0, 0, 0
    for i, p in ipairs(planes) do
        local r = ranges[i]
        for ix = r.x0, r.x1 do
            local x = -half + (ix + 0.5) * r.pixel
            for iz = r.z0, r.z1 do
                local z = -half + (iz + 0.5) * r.pixel
                local typeIndex = getDensityTypeIndexAtWorldPos(p.id, x, 0, z)
                local states = getDensityStatesAtWorldPos(p.id, x, 0, z)
                A.stats.reads = A.stats.reads + 1
                if states == 0 then
                    empty = empty + 1
                elseif not isInteger(states) or states < 0 then
                    unknown = unknown + 1
                elseif p.kind == "HAULM" then
                    haulm = haulm + 1          -- residue under its own meaning, never a living crop
                else
                    local desc = ftm ~= nil and type(ftm.getFruitTypeByDensityTypeIndex) == "function" and ftm:getFruitTypeByDensityTypeIndex(typeIndex) or nil
                    if type(desc) ~= "table" or desc.terrainDataPlaneId ~= p.id or type(desc.getGrowthStateByDensityState) ~= "function" then
                        unknown = unknown + 1
                    else
                        local okG, growth = pcall(desc.getGrowthStateByDensityState, desc, states)
                        local class = okG and A.classifyState(desc, growth) or "UNKNOWN"
                        if class == "LIVING" then
                            local name = nonempty(desc.name, 64) and string.lower(desc.name) or nil
                            if name == nil then unknown = unknown + 1 else living[name] = (living[name] or 0) + 1 end
                        elseif class == "NONLIVING" then nonliving = nonliving + 1
                        elseif class == "EMPTY" then empty = empty + 1
                        else unknown = unknown + 1 end
                    end
                end
            end
        end
    end
    local fields = { basis = A.BASIS, profile = profile.id, planes = #planes, planeSet = A.digest(planeFingerprint), pixels = total,
                     empty = empty, nonliving = nonliving, haulm = haulm }
    if unknown > 0 then return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. ":UNCLASSIFIED_PIXELS", fields = fields } end
    local crops = {}
    for name in pairs(living) do crops[#crops + 1] = name end
    if #crops == 0 then return { state = A.NOT_LIVING, fields = fields } end
    if #crops > 1 then
        table.sort(crops)
        return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. ":MIXED_CROPS", fields = fields }
    end
    fields.living = living[crops[1]]
    return { state = A.LIVING, cropName = crops[1], fields = fields }
end

-- ---------------------------------------------------------
-- Candidates (:220)
-- ---------------------------------------------------------
--- Even-odd point in polygon over { {x, z}, ... }.
local function inside(points, x, z)
    local n, c = #points, false
    local j = n
    for i = 1, n do
        local xi, zi, xj, zj = points[i][1], points[i][2], points[j][1], points[j][2]
        if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then c = not c end
        j = i
    end
    return c
end
local function segmentsCross(ax, az, bx, bz, cx, cz, dx, dz)
    local function orient(px, pz, qx, qz, rx, rz) return (qx - px) * (rz - pz) - (qz - pz) * (rx - px) end
    local d1, d2 = orient(cx, cz, dx, dz, ax, az), orient(cx, cz, dx, dz, bx, bz)
    local d3, d4 = orient(ax, az, bx, bz, cx, cz), orient(ax, az, bx, bz, dx, dz)
    return ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0))
end
--- Does the fine cell's square overlap the polygon with some area: its centre inside, a vertex
--- strictly inside the cell, or an edge properly crossing a cell edge? Touching along an edge or at a
--- corner is no overlap.
function A.cellOverlaps(geom, points, gx, gz)
    local half = geom.terrainSize / 2
    local x0, z0 = -half + gx * geom.cellSize, -half + gz * geom.cellSize
    local x1, z1 = x0 + geom.cellSize, z0 + geom.cellSize
    if inside(points, (x0 + x1) / 2, (z0 + z1) / 2) then return true end
    for _, p in ipairs(points) do
        if p[1] > x0 and p[1] < x1 and p[2] > z0 and p[2] < z1 then return true end
    end
    local edges = { { x0, z0, x1, z0 }, { x1, z0, x1, z1 }, { x1, z1, x0, z1 }, { x0, z1, x0, z0 } }
    local n = #points
    local j = n
    for i = 1, n do
        for _, e in ipairs(edges) do
            if segmentsCross(points[j][1], points[j][2], points[i][1], points[i][2], e[1], e[2], e[3], e[4]) then return true end
        end
        j = i
    end
    return false
end

--- The cultivated polygons, by field id: { id, points, gx0, gz0, w, h } with the cell box clipped
--- to the grid. Field:getPolygonPoints are scene nodes, read with getWorldTranslation
--- (MathUtil.getPolygon2DSize does the same). Nil and a reason when the fields are not readable.
function A.resolveFields(geom)
    local fm = g_fieldManager
    if fm == nil or type(fm.getFields) ~= "function" or getWorldTranslation == nil then return nil, "NO_FIELDS" end
    local ok, fields = pcall(fm.getFields, fm)
    if not ok or type(fields) ~= "table" then return nil, "NO_FIELDS" end
    local out = {}
    for _, field in pairs(fields) do
        local okId, id = pcall(field.getId, field)
        local okP, nodes = pcall(field.getPolygonPoints, field)
        if okId and isInteger(id) and okP and type(nodes) == "table" and #nodes >= 3 then
            local points, minX, minZ, maxX, maxZ = {}, math.huge, math.huge, -math.huge, -math.huge
            local good = true
            for _, node in ipairs(nodes) do
                local x, _, z = getWorldTranslation(node)
                if not isFinite(x) or not isFinite(z) then good = false break end
                points[#points + 1] = { x, z }
                minX, maxX, minZ, maxZ = math.min(minX, x), math.max(maxX, x), math.min(minZ, z), math.max(maxZ, z)
            end
            if good then
                local half = geom.terrainSize / 2
                local gx0 = math.max(0, math.floor((minX + half) / geom.cellSize))
                local gz0 = math.max(0, math.floor((minZ + half) / geom.cellSize))
                -- The last cell the box reaches into: a maximum on a cell boundary does not reach the next.
                local gx1 = math.min(geom.resolution - 1, math.ceil((maxX + half) / geom.cellSize) - 1)
                local gz1 = math.min(geom.resolution - 1, math.ceil((maxZ + half) / geom.cellSize) - 1)
                if gx1 >= gx0 and gz1 >= gz0 then
                    out[#out + 1] = { id = id, points = points, gx0 = gx0, gz0 = gz0, w = gx1 - gx0 + 1, h = gz1 - gz0 + 1 }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- ---------------------------------------------------------
-- Admission (:99-103)
-- ---------------------------------------------------------
--- Admit one living cell at `day`: a fresh baseline row, or the retained row the cell already has
--- (its resistance, protection and history kept). Returns the row, or nil and a reason.
function A.admit(model, gx, gz, cropName, fields, day)
    if not isInteger(day) then return nil, "DAY_UNAVAILABLE" end
    local store = model.store
    local row = store:get(gx, gz)
    if row ~= nil and row.cropName ~= nil then return nil, "ALREADY_ADMITTED" end
    model.occurrenceSeq = model.occurrenceSeq + 1
    local token = "occ:" .. tostring(model.occurrenceSeq)
    local cell = row ~= nil and G.copyCell(row) or G.baselineCell(model.geometry.fingerprint)
    cell.cropName = cropName
    cell.cropOccurrence = token
    local w = {}
    for k, v in pairs(fields or {}) do w[k] = v end
    w.basis, w.day = A.BASIS, day
    cell.nativeCropWitness = w
    if row == nil then cell.lastSettledDay = day end
    local okPut, why = store:put(gx, gz, cell)
    if not okPut then
        model.occurrenceSeq = model.occurrenceSeq - 1
        return nil, "STORE:" .. tostring(why)
    end
    return cell
end

-- ---------------------------------------------------------
-- Discovery and membership (:220)
-- ---------------------------------------------------------
--- The model's discovery state. A changed geometry (checked every call) or plane set (checked at
--- the start of each pass) rebuilds it, which invalidates every cached membership; the field
--- polygons are re-read at the start of each pass.
local function freshState(model, planes, planeFp)
    local fields, whyFields = A.resolveFields(model.geometry)
    local planeKey = planes ~= nil and planeFp or ("UNAVAILABLE:" .. tostring(planeFp))
    local d = { geometry = model.geometry.fingerprint, planeKey = planeKey, planes = planes, planeFingerprint = planeFp,
                fields = fields, fieldsReason = whyFields, member = {}, lastReason = nil,
                counts = { examined = 0, living = 0, notLiving = 0, unknown = 0, admitted = 0 } }
    model.discovery = d
    return d
end
local function stateOf(model, passStart)
    local d = model.discovery
    if d == nil or d.geometry ~= model.geometry.fingerprint then
        local planes, planeFp = A.resolvePlanes()
        return freshState(model, planes, planeFp)
    end
    if passStart then
        local planes, planeFp = A.resolvePlanes()
        local planeKey = planes ~= nil and planeFp or ("UNAVAILABLE:" .. tostring(planeFp))
        if planeKey ~= d.planeKey then return freshState(model, planes, planeFp) end
        d.fields, d.fieldsReason = A.resolveFields(model.geometry)
    end
    return d
end

local function key(gx, gz) return tostring(gx) .. ":" .. tostring(gz) end

--- The ordinal-th candidate (0-based): each field's cell box in field-id order, then the store's
--- rows in store order. Returns gx, gz, inPolygon (nil past the end) and the total.
local function candidateAt(model, d, ordinal, rows)
    local o = ordinal
    for _, f in ipairs(d.fields or {}) do
        local n = f.w * f.h
        if o < n then
            local gz = f.gz0 + math.floor(o / f.w)
            local gx = f.gx0 + (o % f.w)
            return gx, gz, f
        end
        o = o - n
    end
    if o < #rows then return rows[o + 1].gx, rows[o + 1].gz, nil end
    return nil
end
local function candidateTotal(d, rows)
    local n = 0
    for _, f in ipairs(d.fields or {}) do n = n + f.w * f.h end
    return n + #rows
end

--- Classify one candidate cell, record its membership, and admit a living one at today.
local function discoverCell(model, d, gx, gz, profile, day)
    local r = A.witness(model.geometry, d.planes, d.planeFingerprint, gx, gz, profile)
    d.counts.examined = d.counts.examined + 1
    local k = key(gx, gz)
    if r.state == A.LIVING then
        d.counts.living = d.counts.living + 1
        d.member[k] = { state = A.LIVING, cropName = r.cropName, fields = r.fields }
        local row = model.store:get(gx, gz)
        if row == nil or row.cropName == nil then
            local cell, why = A.admit(model, gx, gz, r.cropName, r.fields, day)
            if cell ~= nil then d.counts.admitted = d.counts.admitted + 1 else d.lastReason = why end
        end
    elseif r.state == A.NOT_LIVING then
        d.counts.notLiving = d.counts.notLiving + 1
        d.member[k] = nil
    else
        d.counts.unknown = d.counts.unknown + 1
        d.member[k] = nil
        d.lastReason = r.reason
    end
end

--- Discover up to `budget` candidates from the saved cursor. Returns the work done.
function A.discover(model, budget)
    if budget <= 0 or model.geometry == nil then return 0 end
    local d = stateOf(model, model.discoveryCursor == 0)
    if d.fields == nil then d.lastReason = d.fieldsReason return 0 end
    local rows = model.store:orderedCells()
    local total = candidateTotal(d, rows)
    if total == 0 then return 0 end
    local profile = A.supportedProfile()
    local day = CD15Day.readDay(model.lastDay)
    local work = 0
    while work < budget do
        if model.discoveryCursor >= total then
            -- The pass is complete: the next update starts the next one (re-reading the planes and
            -- the fields there), so no cell is examined twice in one update.
            model.discoveryCursor = 0
            break
        end
        local gx, gz, f = candidateAt(model, d, model.discoveryCursor, rows)
        model.discoveryCursor = model.discoveryCursor + 1
        work = work + 1
        if gx ~= nil and (f == nil or A.cellOverlaps(model.geometry, f.points, gx, gz)) then
            discoverCell(model, d, gx, gz, profile, day)
        end
    end
    return work
end

--- Membership of a destination with no row (#1062's MINOR 3): a discovered living cell is admitted
--- now, at `day`, by the same rule; an undiscovered or unclassified cell is none.
function A.memberRow(model, gx, gz, day)
    local d = model.discovery
    if d == nil then return nil end
    local m = d.member[key(gx, gz)]
    if m == nil or m.state ~= A.LIVING then return nil end
    local cell = A.admit(model, gx, gz, m.cropName, m.fields, day)
    if cell ~= nil then d.counts.admitted = d.counts.admitted + 1 end
    return cell
end

--- A native transition (step 2's writers) invalidates the cell's cached membership.
function A.invalidate(model, gx, gz)
    if model.discovery ~= nil then model.discovery.member[key(gx, gz)] = nil end
end

--- The status: the counts and the reason nothing was admitted.
function A.status(model)
    local d = model.discovery
    local profile = A.supportedProfile()
    return { profile = profile ~= nil and profile.id or nil, reads = A.stats.reads,
             examined = d ~= nil and d.counts.examined or 0, living = d ~= nil and d.counts.living or 0,
             unknown = d ~= nil and d.counts.unknown or 0, admitted = d ~= nil and d.counts.admitted or 0,
             reason = d ~= nil and d.lastReason or nil, cursor = model.discoveryCursor }
end
