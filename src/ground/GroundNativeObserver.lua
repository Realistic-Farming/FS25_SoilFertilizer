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

GroundNativeObserver = GroundNativeObserver or {}
local O = GroundNativeObserver

O.MARKER             = "_sfGroundNativeObserver"
O.PRIMITIVE_TIP_LINE = "TIP_TO_GROUND_AROUND_LINE"
-- The native types whose occupancy decides a Soil cell (contract section 2).
O.OCCUPANCY_TYPES    = { "GRASS_WINDROW", "DRYGRASS_WINDROW", "STRAW" }
-- An envelope covering more Soil cells than this is refused as unobservable rather
-- than read cell by cell every frame; the affected cells then go unavailable.
O.MAX_CELLS          = 256

O.frames = O.frames or {}
O.nextOrdinal = O.nextOrdinal or 0
-- Diagnostics: how much reading one primitive costs (Bob's intake asked for a number).
O.stats = O.stats or { primitives = 0, occupancyReads = 0, cellsRead = 0, refusedEnvelopes = 0 }

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
---@return table|nil cells  { { gx, gz, x0, z0, x1, z1, x2, z2 }, ... }, string|nil reason
function O.envelopeCells(geometry, sx, sz, ex, ez, reach)
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
                if #cells >= O.MAX_CELLS then return nil, "ENVELOPE_TOO_LARGE" end
                cells[#cells + 1] = { gx = gx, gz = gz, x0 = x0, z0 = z0, x1 = x0 + grain, z1 = z0, x2 = x0, z2 = z0 + grain }
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

--- Native occupancy of one Soil cell per type, plus the whole-cell sum over the
--- windrow types. A read that fails makes that cell's occupancy unknown (nil),
--- which the handler must never treat as bare ground.
local function readCell(cell, typeIndices, windrowSet)
    local levels, whole = {}, 0
    for _, ft in ipairs(typeIndices) do
        O.stats.occupancyReads = O.stats.occupancyReads + 1
        local ok, litres = pcall(DensityMapHeightUtil.getFillLevelAtArea, ft, cell.x0, cell.z0, cell.x1, cell.z1, cell.x2, cell.z2)
        if not ok or not finite(litres) or litres < 0 then return nil, nil end
        levels[ft] = litres
        if windrowSet[ft] then whole = whole + litres end
    end
    return levels, whole
end

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
    local typeIndices = O.occupancyTypeIndices(fillTypeIndex)
    local windrowSet = {}
    for _, ft in ipairs(O.occupancyTypeIndices(nil)) do windrowSet[ft] = true end
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
    if rec.cells ~= nil then
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

        local n, r = packn(pcall(native, vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, ...))

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
