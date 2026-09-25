--
-- GroundNativeObserver
--
-- RSF-F208, section 2 of GROUND-CONDITION-CONTRACT v1.5: the native-cell observer
-- the Soil-alone movement carriers of section 3 need.
--
-- ONE PRIMITIVE, ONE WRAP. The Mower, Tedder and Windrower move ground material
-- through exactly one engine function, DensityMapHeightUtil.tipToGroundAroundLine
-- (densityMaps/DensityMapHeightUtil.lua:157). A negative delta is a pickup and
-- returns the negative litres actually picked up; a positive delta is a drop and
-- returns the litres actually dropped plus the new line offset. It is called
-- through the DensityMapHeightUtil table, so one table wrap reaches every caller.
--
-- INERT UNLESS A CARRIER ASKED. The wrap records a primitive only while a carrier
-- frame for THAT vehicle is on top of the stack. Every other tip in the game (a
-- tipping trailer, another mod, a carrier call with no frame because a StockGuard
-- lease owns it) goes straight to the native function with its arguments and
-- returns untouched.
--
-- A LITRES-ONLY FRAME (MAINTENANCE row 145) asks for the returned litres and nothing
-- else: while one for that vehicle is on top, each of its tips adds its positive first
-- return (the litres actually dropped) to frame.litres. It records no primitive, reads
-- no cells, calls no handler, takes no admission snapshot and projects no condition, so
-- no condition rule of section 2 applies to it. The generic straw birth uses it to learn
-- what really landed.
--
-- IN NATIVE ORDER, ONE AT A TIME. Each recorded primitive is handed to its frame's
-- handler as soon as the native call returns, before the next one runs, so a later
-- pickup in the same processing call sees the condition an earlier primitive
-- projected (contract section 2).
--
-- WHAT IS RECORDED. The resolved arguments, the actual returned litres and line
-- offset, and the affected Soil cells: the line plus its reach (inner radius plus
-- the effective outer radius; a nil radius is the native default,
-- getDefaultMaxRadius :403, exactly what the native call itself resolves at :167).
-- Per cell, the native occupancy of each windrow type before and after
-- (getFillLevelAtArea :80 over the cell's own world parallelogram), because the
-- destination rule and the clear rule are about the WHOLE Soil cell, not the
-- brush's changed pixels. Generic by primitive kind, so F211's baler and forage
-- wagon pickups and SG2-4 reuse it.
--
-- A THROW INSIDE THE NATIVE CALL is re-raised unchanged after the handler is told
-- the primitive failed; the frame is the carrier's to close, in its own finally.
--
-- STANDING ASIDE FOR AN INNER ADMISSION (SG2-4, Bob's intake item 3b). This wrap sits
-- on the Lua util (the OUTER slot). The util calls the engine global
-- addDensityMapHeightAtWorldLine at DensityMapHeightUtil.lua:290, and that is where
-- StockGuard's SG2-4 observes and admits (the INNER slot): its lease is opened,
-- delivered and closed INSIDE this wrapper's native call, so neither a pre-call nor a
-- post-call hasLiveLeaseFor sees it. The frame therefore snapshots the admission's
-- count of admitted leases before the native call and, when it moved during the
-- call (the call is synchronous, so that lease is the inner slot's for this very
-- primitive), discards its own record: no handler call, no projection, no marks.
-- The pre-call stand-aside for a lease already live stays with the carrier.
--

GroundNativeObserver = GroundNativeObserver or {}
local O = GroundNativeObserver

O.MARKER             = "_sfGroundNativeObserver"
O.PRIMITIVE_TIP_LINE = "TIP_TO_GROUND_AROUND_LINE"
-- The native types whose occupancy decides a Soil cell (contract section 2).
O.OCCUPANCY_TYPES    = { "GRASS_WINDROW", "DRYGRASS_WINDROW", "STRAW" }
-- An envelope covering more Soil cells than this is not READ: its occupancy would
-- cost too many reads per frame. It is still ENUMERATED, so the carrier can mark
-- every cell it covers unavailable; the cap bounds reads, not marking.
O.MAX_CELLS          = 256
-- A hard bound on enumeration alone, against a pathological reach. Beyond it the
-- primitive cannot even be placed on cells.
O.MAX_MARK_CELLS     = 16384

O.frames = O.frames or {}
O.nextOrdinal = O.nextOrdinal or 0
-- Diagnostics: how much reading one primitive costs (Bob's intake asked for a number),
-- and how often this wrap stood aside for an admission made inside its native call.
O.stats = O.stats or { primitives = 0, occupancyReads = 0, cellsRead = 0, refusedEnvelopes = 0, stoodAside = 0 }
O.stats.litresOnly = O.stats.litresOnly or 0   -- tips served by a litres-only frame (row 145)

local function packn(...)
    return select("#", ...), { ... }
end

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- =========================================================
-- Frames
-- =========================================================

--- Open a carrier frame. `spec` names the owner vehicle (only its own tips are
--- recorded) and the handler whose beforePrimitive/onPrimitive/onPrimitiveFailed
--- receive the observations. Everything else on the spec travels with the frame.
---@return table frame
function O.open(spec)
    O.nextOrdinal = O.nextOrdinal + 1
    local frame = spec or {}
    frame.ordinal = O.nextOrdinal
    frame.depth = #O.frames + 1
    frame.closed = false
    frame.primitives = 0
    O.frames[frame.depth] = frame
    return frame
end

--- Close a frame BY FRAME: anything opened above it and not closed is abandoned
--- with it, so a frame can never be left on the stack by a throw below it.
function O.close(frame)
    if type(frame) ~= "table" or frame.closed then return end
    while #O.frames >= (frame.depth or 1) do
        local top = O.frames[#O.frames]
        O.frames[#O.frames] = nil
        if top ~= nil then top.closed = true end
        if top == frame then break end
    end
    frame.closed = true
end

function O.current()
    return O.frames[#O.frames]
end

function O.isAtRest()
    return #O.frames == 0
end

-- =========================================================
-- Envelope and occupancy
-- =========================================================

local function distanceToSegment(px, pz, sx, sz, ex, ez)
    local dx, dz = ex - sx, ez - sz
    local len2 = dx * dx + dz * dz
    local t = 0
    if len2 > 0 then
        t = ((px - sx) * dx + (pz - sz) * dz) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local qx, qz = sx + t * dx, sz + t * dz
    return math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
end

--- The Soil cells a line of this reach can touch. A cell is in when its centre is
--- within reach plus half its diagonal of the segment: a superset, because a cell
--- whose occupancy did not change is skipped by the handler anyway.
---@param limit number|nil  the most cells to enumerate (default MAX_MARK_CELLS)
---@return table|nil cells  { { gx, gz, x0, z0, x1, z1, x2, z2 }, ... }, string|nil reason
function O.envelopeCells(geometry, sx, sz, ex, ez, reach, limit)
    limit = limit or O.MAX_MARK_CELLS
    if type(geometry) ~= "table" then return nil, "NO_GEOMETRY" end
    if not (finite(sx) and finite(sz) and finite(ex) and finite(ez) and finite(reach)) or reach < 0 then
        return nil, "NONFINITE_ENVELOPE"
    end
    local grain, n = geometry.grainMetres, geometry.resolution
    local ox, oz = geometry.originX, geometry.originZ
    local pad = reach + grain * 0.7072
    local gx0 = math.max(0, math.floor((math.min(sx, ex) - reach - ox) / grain))
    local gx1 = math.min(n - 1, math.floor((math.max(sx, ex) + reach - ox) / grain))
    local gz0 = math.max(0, math.floor((math.min(sz, ez) - reach - oz) / grain))
    local gz1 = math.min(n - 1, math.floor((math.max(sz, ez) + reach - oz) / grain))
    if gx1 < gx0 or gz1 < gz0 then return nil, "OFF_MAP" end
    local cells = {}
    for gx = gx0, gx1 do
        for gz = gz0, gz1 do
            local x0, z0 = ox + gx * grain, oz + gz * grain
            if distanceToSegment(x0 + grain * 0.5, z0 + grain * 0.5, sx, sz, ex, ez) <= pad then
                if #cells >= limit then return nil, "ENVELOPE_UNBOUNDED" end
                cells[#cells + 1] = { gx = gx, gz = gz, x0 = x0, z0 = z0, x1 = x0 + grain, z1 = z0, x2 = x0, z2 = z0 + grain }
            end
        end
    end
    return cells, nil
end

--- The Soil cells a world parallelogram (x0,z0 to x1,z1 and x2,z2, the density
--- modifier's three points) can touch, by the same superset rule: a cell is in when
--- its centre lies inside the parallelogram or within half its diagonal of an edge.
---@return table|nil cells, string|nil reason
function O.parallelogramCells(geometry, x0, z0, x1, z1, x2, z2, limit)
    limit = limit or O.MAX_MARK_CELLS
    if type(geometry) ~= "table" then return nil, "NO_GEOMETRY" end
    if not (finite(x0) and finite(z0) and finite(x1) and finite(z1) and finite(x2) and finite(z2)) then
        return nil, "NONFINITE_ENVELOPE"
    end
    local x3, z3 = x1 + x2 - x0, z1 + z2 - z0
    local ux, uz, vx, vz = x1 - x0, z1 - z0, x2 - x0, z2 - z0
    local det = ux * vz - uz * vx
    local function inside(px, pz)
        if math.abs(det) < 1e-9 then return false end
        local dx, dz = px - x0, pz - z0
        local a = (dx * vz - dz * vx) / det
        local b = (ux * dz - uz * dx) / det
        return a >= 0 and a <= 1 and b >= 0 and b <= 1
    end
    local function near(px, pz, pad)
        if inside(px, pz) then return true end
        return distanceToSegment(px, pz, x0, z0, x1, z1) <= pad or distanceToSegment(px, pz, x0, z0, x2, z2) <= pad
            or distanceToSegment(px, pz, x1, z1, x3, z3) <= pad or distanceToSegment(px, pz, x2, z2, x3, z3) <= pad
    end
    local grain, n = geometry.grainMetres, geometry.resolution
    local ox, oz = geometry.originX, geometry.originZ
    local pad = grain * 0.7072
    local minX, maxX = math.min(x0, x1, x2, x3), math.max(x0, x1, x2, x3)
    local minZ, maxZ = math.min(z0, z1, z2, z3), math.max(z0, z1, z2, z3)
    local gx0 = math.max(0, math.floor((minX - pad - ox) / grain))
    local gx1 = math.min(n - 1, math.floor((maxX + pad - ox) / grain))
    local gz0 = math.max(0, math.floor((minZ - pad - oz) / grain))
    local gz1 = math.min(n - 1, math.floor((maxZ + pad - oz) / grain))
    if gx1 < gx0 or gz1 < gz0 then return nil, "OFF_MAP" end
    local cells = {}
    for gx = gx0, gx1 do
        for gz = gz0, gz1 do
            local cx0, cz0 = ox + gx * grain, oz + gz * grain
            if near(cx0 + grain * 0.5, cz0 + grain * 0.5, pad) then
                if #cells >= limit then return nil, "ENVELOPE_UNBOUNDED" end
                cells[#cells + 1] = { gx = gx, gz = gz, x0 = cx0, z0 = cz0, x1 = cx0 + grain, z1 = cz0, x2 = cx0, z2 = cz0 + grain }
            end
        end
    end
    return cells, nil
end

--- The fill type indices this observer reads, resolved once per call.
function O.occupancyTypeIndices(extraIndex)
    local out, seen = {}, {}
    local ftm = g_fillTypeManager
    if ftm ~= nil and type(ftm.getFillTypeIndexByName) == "function" then
        for _, name in ipairs(O.OCCUPANCY_TYPES) do
            local ok, index = pcall(ftm.getFillTypeIndexByName, ftm, name)
            if ok and type(index) == "number" and not seen[index] then
                seen[index] = true
                out[#out + 1] = index
            end
        end
    end
    if type(extraIndex) == "number" and not seen[extraIndex] then out[#out + 1] = extraIndex end
    return out
end

--- The type indices to read for a primitive of `fillTypeIndex` (nil for a primitive
--- of no single type) and the set of windrow types whose sum is the whole cell.
function O.occupancySets(fillTypeIndex)
    local typeIndices = O.occupancyTypeIndices(fillTypeIndex)
    local windrowSet = {}
    for _, ft in ipairs(O.occupancyTypeIndices(nil)) do windrowSet[ft] = true end
    return typeIndices, windrowSet
end

--- Whether the height map can be read at all: the native reads return zero for
--- every area when it is not valid (DensityMapHeightUtil.lua:81-83), which is not an
--- observation.
function O.heightMapValid()
    local hm = g_densityMapHeightManager
    return hm ~= nil and type(hm.getIsValid) == "function" and hm:getIsValid() == true
end

--- The default outer radius the native call resolves for a nil radius
--- (DensityMapHeightUtil.lua:167-169, :403), or 0 when it cannot be asked.
function O.defaultRadius(fillTypeIndex)
    if type(DensityMapHeightUtil) ~= "table" or type(DensityMapHeightUtil.getDefaultMaxRadius) ~= "function" then return 0 end
    local ok, r = pcall(DensityMapHeightUtil.getDefaultMaxRadius, fillTypeIndex)
    if ok and finite(r) and r >= 0 then return r end
    return 0
end

--- Native occupancy of one Soil cell per type, plus the whole-cell sum over the
--- windrow types. A read that fails makes that cell's occupancy unknown (nil),
--- which the handler must never treat as bare ground.
local function readCell(cell, typeIndices, windrowSet)
    local read = type(DensityMapHeightUtil) == "table" and DensityMapHeightUtil.getFillLevelAtArea or nil
    if type(read) ~= "function" then return nil, nil end
    local levels, whole = {}, 0
    for _, ft in ipairs(typeIndices) do
        O.stats.occupancyReads = O.stats.occupancyReads + 1
        local ok, litres = pcall(read, ft, cell.x0, cell.z0, cell.x1, cell.z1, cell.x2, cell.z2)
        if not ok or not finite(litres) or litres < 0 then return nil, nil end
        levels[ft] = litres
        if windrowSet[ft] then whole = whole + litres end
    end
    return levels, whole
end
O.readCell = readCell

-- =========================================================
-- The wrap
-- =========================================================

--- Everything the primitive needs recorded BEFORE the native call. Returns nil when
--- this primitive cannot be observed; the native call then runs with no record.
local function prepare(frame, delta, fillTypeIndex, sx, sz, ex, ez, innerRadius, radius)
    local hm = g_densityMapHeightManager
    if hm == nil or type(hm.getIsValid) ~= "function" or not hm:getIsValid() then return nil end
    if not finite(delta) and delta ~= -math.huge then return nil end
    local outer = radius
    if outer == nil and type(DensityMapHeightUtil.getDefaultMaxRadius) == "function" then
        outer = DensityMapHeightUtil.getDefaultMaxRadius(fillTypeIndex)
    end
    local reach = (innerRadius or 0) + (outer or 0)
    local rec = {
        kind = O.PRIMITIVE_TIP_LINE, pickup = delta < 0, delta = delta, fillTypeIndex = fillTypeIndex,
        sx = sx, sz = sz, ex = ex, ez = ez, reach = reach, cells = nil, refused = nil,
    }
    local cells, why = O.envelopeCells(frame.geometry, sx, sz, ex, ez, reach)
    if cells == nil then
        rec.refused = why
        O.stats.refusedEnvelopes = O.stats.refusedEnvelopes + 1
        return rec
    end
    if #cells > O.MAX_CELLS then
        -- Too many cells to read every frame. Keep the indices, read nothing: the
        -- carrier marks them all unavailable rather than let old records stand.
        rec.refused, rec.unobservable, rec.cells = "ENVELOPE_TOO_LARGE", true, cells
        O.stats.refusedEnvelopes = O.stats.refusedEnvelopes + 1
        return rec
    end
    local typeIndices, windrowSet = O.occupancySets(fillTypeIndex)
    rec.typeIndices, rec.windrowSet = typeIndices, windrowSet
    for _, cell in ipairs(cells) do
        cell.before, cell.beforeWhole = readCell(cell, typeIndices, windrowSet)
    end
    rec.cells = cells
    O.stats.cellsRead = O.stats.cellsRead + #cells
    return rec
end

local function complete(frame, rec, litres, lineOffset)
    rec.litres, rec.lineOffset = litres, lineOffset
    if rec.cells ~= nil and not rec.unobservable then
        for _, cell in ipairs(rec.cells) do
            cell.after, cell.afterWhole = readCell(cell, rec.typeIndices, rec.windrowSet)
        end
    end
    O.stats.primitives = O.stats.primitives + 1
    frame.primitives = frame.primitives + 1
end

--- Wrap DensityMapHeightUtil.tipToGroundAroundLine once per process. Idempotent.
---@return boolean installed, string|nil why
function O.install()
    if g_server == nil then return false, "CLIENT" end
    if DensityMapHeightUtil == nil or type(DensityMapHeightUtil.tipToGroundAroundLine) ~= "function" then
        return false, "NO_PRIMITIVE"
    end
    local rec = rawget(DensityMapHeightUtil, O.MARKER)
    if rec ~= nil and DensityMapHeightUtil.tipToGroundAroundLine == rec.wrapper then return true, "ALREADY" end

    local native = DensityMapHeightUtil.tipToGroundAroundLine
    local wrapper = function(vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, ...)
        local frame = O.frames[#O.frames]
        -- A litres-only frame (header): the native call, its dropped litres added, and
        -- nothing else. A throw is re-raised unchanged and every return forwarded.
        if frame ~= nil and not frame.closed and frame.litresOnly and frame.owner == vehicle then
            O.stats.litresOnly = O.stats.litresOnly + 1
            local ln, lr = packn(pcall(native, vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, ...))
            if lr[1] and finite(lr[2]) and lr[2] > 0 then frame.litres = (frame.litres or 0) + lr[2] end
            if not lr[1] then error(lr[2], 0) end
            return unpack(lr, 2, ln)
        end
        if frame == nil or frame.closed or frame.owner ~= vehicle or type(frame.handler) ~= "table" then
            return native(vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, ...)
        end
        local okPrep, prim = pcall(prepare, frame, delta, fillTypeIndex, sx, sz, ex, ez, innerRadius, radius)
        if not okPrep then
            SoilLogger.warning("[GroundObserver] primitive preparation failed (%s) - native work unaffected", tostring(prim))
            prim = nil
        end
        if prim ~= nil and type(frame.handler.beforePrimitive) == "function" then
            local okB, errB = pcall(frame.handler.beforePrimitive, frame, prim)
            if not okB then SoilLogger.warning("[GroundObserver] beforePrimitive failed (%s)", tostring(errB)) end
        end
        -- The admission count before the native call (header: standing aside).
        local admission = frame.admission
        local admittedBefore = (admission ~= nil and type(admission.admissionCount) == "function")
            and admission:admissionCount() or nil

        local n, r = packn(pcall(native, vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, ...))

        -- A lease admitted during the synchronous call means StockGuard observed and
        -- delivered this movement at the inner slot: Soil's own record is discarded,
        -- with no handler call, no projection and no marks.
        if prim ~= nil and admittedBefore ~= nil and admission:admissionCount() ~= admittedBefore then
            prim = nil
            O.stats.stoodAside = O.stats.stoodAside + 1
        end

        if prim ~= nil then
            if r[1] then
                local okC, errC = pcall(complete, frame, prim, r[2], r[3])
                if okC and type(frame.handler.onPrimitive) == "function" then
                    local okH, errH = pcall(frame.handler.onPrimitive, frame, prim)
                    if not okH then SoilLogger.warning("[GroundObserver] onPrimitive failed (%s)", tostring(errH)) end
                elseif not okC then
                    SoilLogger.warning("[GroundObserver] primitive completion failed (%s)", tostring(errC))
                end
            elseif type(frame.handler.onPrimitiveFailed) == "function" then
                pcall(frame.handler.onPrimitiveFailed, frame, prim)
            end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    DensityMapHeightUtil.tipToGroundAroundLine = wrapper
    rawset(DensityMapHeightUtil, O.MARKER, { native = native, wrapper = wrapper })
    return true
end

--- Is our wrapper the one DensityMapHeightUtil.tipToGroundAroundLine holds now?
function O.isInstalled()
    local rec = DensityMapHeightUtil ~= nil and rawget(DensityMapHeightUtil, O.MARKER) or nil
    return rec ~= nil and DensityMapHeightUtil.tipToGroundAroundLine == rec.wrapper
end

--- Restore the native function, only while ours is still the current one.
---@return boolean restored, string|nil why
function O.uninstall()
    local rec = DensityMapHeightUtil ~= nil and rawget(DensityMapHeightUtil, O.MARKER) or nil
    if rec == nil then return false, "NOT_INSTALLED" end
    rawset(DensityMapHeightUtil, O.MARKER, nil)
    if DensityMapHeightUtil.tipToGroundAroundLine ~= rec.wrapper then return false, "REPLACED_BY_ANOTHER" end
    DensityMapHeightUtil.tipToGroundAroundLine = rec.native
    return true
end
