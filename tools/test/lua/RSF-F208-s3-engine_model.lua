-- RSF-F208-s3-engine_model.lua - the engine the section 3 carrier bench runs against.
--
-- NOT A TEST (no _test suffix). A bar lists it first in --!load. Bodies marked
-- VERBATIM follow D:\FS25_Decoded\dataS\scripts_decompiled at the cited lines.
-- Bodies marked MODELED stand in for engine code with no Lua body to port:
-- addDensityMapHeightAtWorldLine and the density-map reads are C functions, so the
-- height map below is a pixel grid with the same CONTRACT (a pickup returns the
-- negative litres it removed, a drop returns the litres it placed, occupancy is read
-- per area), not the same algorithm.
--
-- The world owners (MaterialDown, MaterialWetness, HayBet) are STAND-INS built by
-- SoilFertilitySystem.new through their own .new, exactly where production builds
-- them. Their behaviour is not under test here: the age and wetness owners only
-- carry the cursors the settlement barrier reads, and HayBet records what the ground
-- looked like when it ran.

g_server = g_server or {}
g_terrainNode = 1
DensityCoordType = DensityCoordType or { POINT_POINT_POINT = 1 }
MathUtil = MathUtil or {}
MathUtil.vector3Length = MathUtil.vector3Length or function(x, y, z) return math.sqrt(x * x + y * y + z * z) end
FillType = FillType or {}
FillType.UNKNOWN = FillType.UNKNOWN or 0

ENGINE = {
    TERRAIN = 64,          -- metres, centred on the origin
    RESOLUTION = 16,       -- Soil condition cells: 4 m grain
    PIXEL = 1,             -- native height-map pixel, 1 m
    PIXEL_CAP = 400,       -- litres one pixel can hold before a drop spills short
    DEFAULT_RADIUS = 1,    -- the modeled getDefaultMaxRadius
    FT = { GRASS_WINDROW = 11, DRYGRASS_WINDROW = 12, STRAW = 13 },
}
local FT_NAME = {}
for name, index in pairs(ENGINE.FT) do FT_NAME[index] = name; FillType[name] = index end

-- Nodes are tables carrying their world position.
function getWorldTranslation(node)
    if type(node) == "table" then return node.x or 0, node.y or 0, node.z or 0 end
    return 0, 0, 0
end

g_fillTypeManager = {
    getFillTypeIndexByName = function(_, name) return ENGINE.FT[name] end,
    getFillTypeNameByIndex = function(_, index) return FT_NAME[index] end,
}

-- ── the two condition layers (after RSF-F208-ground_condition_cells_spec_test) ──
local BVMS = {}
function ENGINE.newLayer(fill)
    local layer = { cells = {}, fill = fill or 0, id = {} }
    BVMS[layer.id] = layer
    return layer
end
function ENGINE.layerGet(layer, gx, gz)
    local v = layer.cells[gx .. ":" .. gz]
    if v == nil then return layer.fill end
    return v
end
function ENGINE.layerSet(layer, gx, gz, v) layer.cells[gx .. ":" .. gz] = v end

getBitVectorMapPoint = function(bvm, gx, gz, _first, _num)
    local layer = BVMS[bvm]
    if layer == nil then error("unknown bvm") end
    return ENGINE.layerGet(layer, gx, gz)
end
getBitVectorMapSize = function(bvm)
    return BVMS[bvm] ~= nil and ENGINE.RESOLUTION or nil
end
DensityMapModifier = {
    new = function(bvm, _first, _num, _node)
        local m = { bvm = bvm }
        m.setParallelogramUVCoords = function(_self, u0, v0, u1, _v1b, _u2, v2, _coordType)
            m.u0, m.v0, m.u1, m.v1 = u0, v0, u1, v2
        end
        local function each(fn)
            for gx = 0, ENGINE.RESOLUTION - 1 do
                for gz = 0, ENGINE.RESOLUTION - 1 do
                    local cu, cv = (gx + 0.5) / ENGINE.RESOLUTION, (gz + 0.5) / ENGINE.RESOLUTION
                    if cu >= m.u0 and cu <= m.u1 and cv >= m.v0 and cv <= m.v1 then fn(gx, gz) end
                end
            end
        end
        m.executeGet = function(_self, _filter)
            if m.u0 == nil then return 0, 0, 0 end
            local sum, n = 0, 0
            each(function(gx, gz) sum = sum + ENGINE.layerGet(BVMS[m.bvm], gx, gz); n = n + 1 end)
            return sum, n, ENGINE.RESOLUTION * ENGINE.RESOLUTION
        end
        m.executeSet = function(_self, value, _filter)
            if m.u0 == nil then return end
            each(function(gx, gz) ENGINE.layerSet(BVMS[m.bvm], gx, gz, value) end)
        end
        return m
    end,
}
DensityMapFilter = { new = function() return { setValueCompareParams = function() end } end }

--- The value maps the condition cells arm over: resolution, terrain and the two
--- layer entries, as SoilValueMaps exposes them.
function ENGINE.newValueMaps()
    local age, wet = ENGINE.newLayer(0), ENGINE.newLayer(0)
    return {
        available = true, resolution = ENGINE.RESOLUTION, terrainSize = ENGINE.TERRAIN,
        layers = { materialAge = { bvm = age.id }, materialWetness = { bvm = wet.id } },
        getLayerEntry = function(self, key) return self.layers[key] end,
        readRawAtWorld = function() return nil end,
    }, age, wet
end

-- ── the native height map (MODELED) ─────────────────────────────────────────
HEIGHT = { pixels = {}, throwNext = false }
local function pkey(px, pz) return px .. ":" .. pz end
function HEIGHT.get(ft, px, pz) local t = HEIGHT.pixels[ft] return t and t[pkey(px, pz)] or 0 end
function HEIGHT.set(ft, px, pz, litres)
    HEIGHT.pixels[ft] = HEIGHT.pixels[ft] or {}
    HEIGHT.pixels[ft][pkey(px, pz)] = litres
end
--- Lay `litres` of `ft` on every pixel of the world box [x0, x1) x [z0, z1).
function HEIGHT.fill(ft, x0, z0, x1, z1, litres)
    for px = math.floor(x0 / ENGINE.PIXEL), math.floor(x1 / ENGINE.PIXEL) - 1 do
        for pz = math.floor(z0 / ENGINE.PIXEL), math.floor(z1 / ENGINE.PIXEL) - 1 do HEIGHT.set(ft, px, pz, litres) end
    end
end
function HEIGHT.total(ft)
    local n = 0
    for _, v in pairs(HEIGHT.pixels[ft] or {}) do n = n + v end
    return n
end
local function pixelCentre(px, pz) return (px + 0.5) * ENGINE.PIXEL, (pz + 0.5) * ENGINE.PIXEL end
local function distanceToSegment(px, pz, sx, sz, ex, ez)
    local dx, dz = ex - sx, ez - sz
    local len2 = dx * dx + dz * dz
    local t = 0
    if len2 > 0 then t = math.max(0, math.min(1, ((px - sx) * dx + (pz - sz) * dz) / len2)) end
    return math.sqrt((px - (sx + t * dx)) ^ 2 + (pz - (sz + t * dz)) ^ 2)
end
local function pixelsNear(sx, sz, ex, ez, reach)
    local out = {}
    local half = ENGINE.TERRAIN / 2
    for px = math.floor((math.min(sx, ex) - reach) / ENGINE.PIXEL), math.floor((math.max(sx, ex) + reach) / ENGINE.PIXEL) do
        for pz = math.floor((math.min(sz, ez) - reach) / ENGINE.PIXEL), math.floor((math.max(sz, ez) + reach) / ENGINE.PIXEL) do
            local cx, cz = pixelCentre(px, pz)
            if cx >= -half and cx < half and cz >= -half and cz < half and distanceToSegment(cx, cz, sx, sz, ex, ez) <= reach then
                out[#out + 1] = { px = px, pz = pz }
            end
        end
    end
    return out
end

g_densityMapHeightManager = {
    valid = true,
    getIsValid = function(self) return self.valid end,
    getDensityMapHeightTypeByFillTypeIndex = function(_, ft) return FT_NAME[ft] ~= nil and { index = ft } or nil end,
    getMinValidLiterValue = function() return 1 end,
}

DensityMapHeightUtil = {}
-- densityMaps/DensityMapHeightUtil.lua:425-449 VERBATIM.
function DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, radiusOverlap)
    local swDirX, swDirY, swDirZ = wx - sx, wy - sy, wz - sz
    local shDirX, shDirY, shDirZ = hx - sx, hy - sy, hz - sz
    local swLength = MathUtil.vector3Length(swDirX, swDirY, swDirZ)
    local shLength = MathUtil.vector3Length(shDirX, shDirY, shDirZ)
    shDirX, shDirY, shDirZ = shDirX / shLength, shDirY / shLength, shDirZ / shLength
    swDirX, swDirY, swDirZ = swDirX / swLength, swDirY / swLength, swDirZ / swLength
    if shLength < swLength then
        local radius = shLength * 0.5
        local shrink = radiusOverlap ~= nil and radiusOverlap and 0 or radius
        return sx + shDirX * shLength * 0.5 + swDirX * shrink, sy + shDirY * shLength * 0.5 + swDirY * shrink, sz + shDirZ * shLength * 0.5 + swDirZ * shrink, wx + shDirX * shLength * 0.5 - swDirX * shrink, wy + shDirY * shLength * 0.5 - swDirY * shrink, wz + shDirZ * shLength * 0.5 - swDirZ * shrink, radius
    else
        local radius = swLength * 0.5
        local shrink = radiusOverlap ~= nil and radiusOverlap and 0 or radius
        return sx + swDirX * swLength * 0.5 + shDirX * shrink, sy + swDirY * swLength * 0.5 + shDirY * shrink, sz + swDirZ * swLength * 0.5 + shDirZ * shrink, hx + swDirX * swLength * 0.5 - shDirX * shrink, hy + swDirY * swLength * 0.5 - shDirY * shrink, hz + swDirZ * swLength * 0.5 - shDirZ * shrink, radius
    end
end
-- :450-455 VERBATIM.
function DensityMapHeightUtil.getLineByArea(start, width, height, radiusOverlap)
    local sx, sy, sz = getWorldTranslation(start)
    local wx, wy, wz = getWorldTranslation(width)
    local hx, hy, hz = getWorldTranslation(height)
    return DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, radiusOverlap)
end
-- :403 MODELED: the native computes maxHeight / tan(maxSurfaceAngle).
function DensityMapHeightUtil.getDefaultMaxRadius(_fillTypeIndex) return ENGINE.DEFAULT_RADIUS end
-- :80 MODELED: the litres of one type on the pixels whose centres lie in the area.
function DensityMapHeightUtil.getFillLevelAtArea(fillTypeIndex, x0, z0, x1, z1, x2, z2)
    if not g_densityMapHeightManager:getIsValid() then return 0, 0, 0 end
    if g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex) == nil then return 0, 0, 0 end
    local minX, maxX = math.min(x0, x1, x2), math.max(x0, x1, x2)
    local minZ, maxZ = math.min(z0, z1, z2), math.max(z0, z1, z2)
    local sum, n = 0, 0
    for px = math.floor(minX / ENGINE.PIXEL), math.floor(maxX / ENGINE.PIXEL) do
        for pz = math.floor(minZ / ENGINE.PIXEL), math.floor(maxZ / ENGINE.PIXEL) do
            local cx, cz = pixelCentre(px, pz)
            if cx >= minX and cx < maxX and cz >= minZ and cz < maxZ then
                local v = HEIGHT.get(fillTypeIndex, px, pz)
                if v > 0 then sum = sum + v; n = n + 1 end
            end
        end
    end
    return sum, n, n
end
-- THE INNER SLOT (MODELED): the engine global the util calls at :290, where
-- StockGuard's SG2-4 observes and admits. The pixel work lives here so a bench can
-- wrap this global as StockGuard does, inside Soil's wrap of the util. Signed like
-- the util's own return: a pickup returns the negative litres it removed, a drop the
-- litres it placed. A pickup removes the type within inner radius plus radius of the
-- line; a drop spreads over the pixels within the inner radius (at least the line's
-- own pixels), each capped at PIXEL_CAP.
function addDensityMapHeightAtWorldLine(_updater, sx, _sy, sz, ex, _ez2, ez, delta, fillTypeIndex, innerRadius, radius, _limitToLineHeight, lineOffset, _applyChanges, _ttsId)
    if delta < 0 then
        local collected = 0
        for _, p in ipairs(pixelsNear(sx, sz, ex, ez, innerRadius + radius)) do
            local v = HEIGHT.get(fillTypeIndex, p.px, p.pz)
            if v > 0 then
                collected = collected + v
                HEIGHT.set(fillTypeIndex, p.px, p.pz, 0)
            end
        end
        return -collected, lineOffset
    end
    local targets = pixelsNear(sx, sz, ex, ez, math.max(innerRadius, ENGINE.PIXEL * 0.5))
    if #targets == 0 then return 0, lineOffset end
    local share, placed = delta / #targets, 0
    for _, p in ipairs(targets) do
        local current = HEIGHT.get(fillTypeIndex, p.px, p.pz)
        local add = math.max(0, math.min(share, ENGINE.PIXEL_CAP - current))
        if add > 0 then
            HEIGHT.set(fillTypeIndex, p.px, p.pz, current + add)
            placed = placed + add
        end
    end
    return placed, lineOffset + 1
end
-- :157-300 MODELED. The returns and early exits are the native's; the resolved
-- arguments go to the inner slot above as the util's :290 call does.
function DensityMapHeightUtil.tipToGroundAroundLine(vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius, lineOffset, limitToLineHeight, occlusionAreas, useOcclusionAreas, applyChanges)
    if not g_densityMapHeightManager:getIsValid() then return 0, 0 end
    if g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex) == nil then return 0, 0 end
    if HEIGHT.throwNext or (HEIGHT.throwOnDrop and delta > 0) then
        HEIGHT.throwNext, HEIGHT.throwOnDrop = false, false
        error("native tip failed")
    end
    if radius == nil then radius = DensityMapHeightUtil.getDefaultMaxRadius(fillTypeIndex) end
    innerRadius = innerRadius == nil and 0 or innerRadius
    lineOffset = lineOffset == nil and 0 or lineOffset
    return addDensityMapHeightAtWorldLine(1, sx, sy, sz, ex, ey, ez, delta, fillTypeIndex, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, 0)
end
-- The pixels whose centres lie in the bounding box of the modifier's three points,
-- as getFillLevelAtArea above reads them.
local function pixelsInArea(x0, z0, x1, z1, x2, z2)
    local minX, maxX = math.min(x0, x1, x2), math.max(x0, x1, x2)
    local minZ, maxZ = math.min(z0, z1, z2), math.max(z0, z1, z2)
    local out = {}
    for px = math.floor(minX / ENGINE.PIXEL), math.floor(maxX / ENGINE.PIXEL) do
        for pz = math.floor(minZ / ENGINE.PIXEL), math.floor(maxZ / ENGINE.PIXEL) do
            local cx, cz = pixelCentre(px, pz)
            if cx >= minX and cx < maxX and cz >= minZ and cz < maxZ then out[#out + 1] = { px = px, pz = pz } end
        end
    end
    return out
end
-- :362 MODELED: every type's height in the area goes to zero (the native sets the
-- height and type channels to 0).
function DensityMapHeightUtil.clearArea(x0, z0, x1, z1, x2, z2)
    for ft, _ in pairs(HEIGHT.pixels) do
        for _, p in ipairs(pixelsInArea(x0, z0, x1, z1, x2, z2)) do HEIGHT.set(ft, p.px, p.pz, 0) end
    end
end
-- :335 MODELED: the type channel of the area's pixels holding `fillTypeIndex` becomes
-- `newFillTypeIndex`; returns the litres changed.
function DensityMapHeightUtil.changeFillTypeAtArea(x0, z0, x1, z1, x2, z2, fillTypeIndex, newFillTypeIndex)
    if g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(fillTypeIndex) == nil
        or g_densityMapHeightManager:getDensityMapHeightTypeByFillTypeIndex(newFillTypeIndex) == nil then return 0 end
    local changed = 0
    for _, p in ipairs(pixelsInArea(x0, z0, x1, z1, x2, z2)) do
        local v = HEIGHT.get(fillTypeIndex, p.px, p.pz)
        if v > 0 then
            HEIGHT.set(fillTypeIndex, p.px, p.pz, 0)
            HEIGHT.set(newFillTypeIndex, p.px, p.pz, HEIGHT.get(newFillTypeIndex, p.px, p.pz) + v)
            changed = changed + v
        end
    end
    return changed
end
-- :491 MODELED as a stand-in: the native smoothAroundLine moves material within the
-- ground through a C function (smoothDensityMapHeightAtWorldPos) on a node's line.
-- Here the type's litres on the pixels within `reach` of the world line are spread
-- evenly over them, the total preserved: the contract (material moves, nothing is
-- created or lost), not the algorithm.
function HEIGHT.smooth(fillTypeIndex, sx, sz, ex, ez, reach)
    local pixels = pixelsNear(sx, sz, ex, ez, reach)
    if #pixels == 0 then return 0 end
    local total = 0
    for _, p in ipairs(pixels) do total = total + HEIGHT.get(fillTypeIndex, p.px, p.pz) end
    for _, p in ipairs(pixels) do HEIGHT.set(fillTypeIndex, p.px, p.pz, total / #pixels) end
    return total
end

-- ── the Tedder (vehicles/specializations/Tedder.lua) ────────────────────────
Tedder = {}
Tedder.CLIENT_DM_UPDATE_RADIUS = 50
-- :275-278 VERBATIM.
function Tedder.preprocessTedderArea(_, workArea)
    workArea.lastPickupLiters = 0
    workArea.lastDroppedLiters = 0
end
-- :279-347 VERBATIM, including the decompile's local shadow of targetFillType at :293.
function Tedder:processTedderArea(workArea, _)
    local spec = self.spec_tedder
    if not self.isServer and self.currentUpdateDistance > Tedder.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, true)
    for targetFillType, inputFillTypes in pairs(spec.fillTypeConvertersReverse) do
        local pickedUpLiters = 0
        for _, inputFillType in ipairs(inputFillTypes) do
            pickedUpLiters = pickedUpLiters + DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, inputFillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, nil, false, nil)
        end
        if pickedUpLiters == 0 and workArea.lastDropFillType ~= FillType.UNKNOWN then
            local targetFillType = workArea.lastDropFillType
        end
        workArea.lastPickupLiters = -pickedUpLiters
        workArea.litersToDrop = workArea.litersToDrop + workArea.lastPickupLiters
        local dropArea = self.spec_workArea.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil and workArea.litersToDrop > 0 then
            local dropped = self:processDropArea(dropArea, targetFillType, workArea.litersToDrop)
            workArea.lastDropFillType = targetFillType
            workArea.lastDroppedLiters = dropped
            spec.lastDroppedLiters = spec.lastDroppedLiters + dropped
            workArea.litersToDrop = workArea.litersToDrop - dropped
            if self.isServer then
                local lastSpeed = self:getLastSpeed(true)
                if dropped > 0 and lastSpeed > 0.5 then
                    local _ = false
                    if spec.tedderWorkAreaFillTypes[workArea.tedderWorkAreaIndex] ~= targetFillType then
                        spec.tedderWorkAreaFillTypes[workArea.tedderWorkAreaIndex] = targetFillType
                        _ = true
                    end
                end
            end
        end
    end
    if self:getLastSpeed() > 0.5 then
        spec.stoneLastState = 0
    else
        spec.stoneLastState = 0
    end
    local area = MathUtil.vector3Length(lsx - lex, lsy - ley, lsz - lez) * self.lastMovedDistance
    return area, area
end
-- :351-357 VERBATIM.
function Tedder:processDropArea(dropArea, fillType, litersToDrop)
    if not self.isServer and self.currentUpdateDistance > Tedder.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height, true)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, litersToDrop, fillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset
    return dropped
end

--- A tedder as the engine builds it: its registered functions COPIED into the
--- instance, then the work-area pointers CAPTURED from them (WorkArea.lua:266, :276).
--- One tedding area at x in [x0, x0 + width], z in [z0, z0 + depth]; its drop area a
--- narrow strip at z = dropZ. The converter turns GRASS_WINDROW into DRYGRASS_WINDROW.
function ENGINE.newTedder(opts)
    local v = { isServer = true, isClient = false, currentUpdateDistance = 0, lastMovedDistance = 1, uniqueId = opts.uid or "tedder" }
    v.processTedderArea = Tedder.processTedderArea
    v.preprocessTedderArea = Tedder.preprocessTedderArea
    v.processDropArea = Tedder.processDropArea
    v.getLastSpeed = function() return 0 end
    v.spec_tedder = {
        fillTypeConvertersReverse = { [ENGINE.FT.DRYGRASS_WINDROW] = { ENGINE.FT.GRASS_WINDROW } },
        tedderWorkAreaFillTypes = {}, lastDroppedLiters = 0,
    }
    local x0, z0, w, d = opts.x0, opts.z0, opts.width, opts.depth
    local work = {
        index = 1, functionName = "processTedderArea", preprocessFunctionName = "preprocessTedderArea",
        start = { x = x0, z = z0 }, width = { x = x0 + w, z = z0 }, height = { x = x0, z = z0 + d },
        litersToDrop = 0, lastDropFillType = FillType.UNKNOWN, dropWindrowWorkAreaIndex = 2, tedderWorkAreaIndex = 1,
    }
    local drop = {
        index = 2, functionName = nil,
        start = { x = x0, z = opts.dropZ }, width = { x = x0 + w, z = opts.dropZ }, height = { x = x0, z = opts.dropZ + (opts.dropDepth or 1) },
        lineOffset = 0,
    }
    v.spec_workArea = { workAreas = { work, drop } }
    work.processingFunction = v[work.functionName]
    work.preprocessingFunction = v[work.preprocessFunctionName]
    return v, work, drop
end

--- WorkArea:onUpdateTick's order: raise onStartWorkAreaProcessing (:126), run each
--- area's captured pointers (:179-193), raise onEndWorkAreaProcessing (:206). Events
--- dispatch through each spec CLASS at call time (SpecializationUtil.raiseEvent
--- :17-26), so a class wrap installed later is the one that runs.
function ENGINE.tick(vehicle, dt)
    local workAreas = vehicle.spec_workArea.workAreas
    for _, class in ipairs(vehicle.specClasses or {}) do
        if type(class.onStartWorkAreaProcessing) == "function" then class.onStartWorkAreaProcessing(vehicle, dt, workAreas) end
    end
    local hasProcessed = false
    for _, workArea in ipairs(workAreas) do
        if workArea.preprocessingFunction ~= nil then
            workArea.preprocessingFunction(vehicle, workArea, dt)
        end
        if workArea.processingFunction ~= nil then
            local xs, _ = workArea.processingFunction(vehicle, workArea, dt)
            if xs > 0 then workArea.lastWorkedHectares = xs else workArea.lastWorkedHectares = 0 end
            hasProcessed = true
        end
    end
    for _, class in ipairs(vehicle.specClasses or {}) do
        if type(class.onEndWorkAreaProcessing) == "function" then class.onEndWorkAreaProcessing(vehicle, dt, hasProcessed) end
    end
end

-- ── the Windrower (vehicles/specializations/Windrower.lua) ───────────────────
Windrower = {}
Windrower.CLIENT_DM_UPDATE_RADIUS = 50
-- :285-292 VERBATIM: the per-frame reset the engine raises before the areas.
function Windrower:onStartWorkAreaProcessing(_, workAreas)
    for _, workArea in pairs(workAreas) do
        workArea.lastValidPickupFillType = FillType.UNKNOWN
        workArea.lastPickupLiters = 0
        workArea.lastDroppedLiters = 0
    end
    self.spec_windrower.isWorking = false
end
-- :309-384 VERBATIM through the drop; the dirty-flag and effect block inside
-- `getLastSpeed(true) > 0.5` is abbreviated (presentation only; this bench's machines
-- report speed 0, so it is never entered), and so is the stone read under isWorking.
function Windrower:processWindrowerArea(workArea, _)
    local spec = self.spec_windrower
    if not self.isServer and self.currentUpdateDistance > Windrower.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local sx = self:getLastSpeed() > 0.5
    spec.isWorking = sx
    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)
    spec.stoneLastState = 0
    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz)
    local pickupLiters = 0
    local pickupFillType = FillType.UNKNOWN
    if workArea.lastPickupLiters == 0 and (workArea.lastValidPickupFillType == FillType.UNKNOWN or workArea.litersToDrop < g_densityMapHeightManager:getMinValidLiterValue(workArea.lastValidPickupFillType)) then
        for _, fillTypeIndex in ipairs(spec.supportedFillTypes) do
            pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillTypeIndex, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, spec.limitToLineHeight, nil)
            if pickupLiters > 0 then
                pickupFillType = fillTypeIndex
                break
            end
        end
    else
        pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, workArea.lastValidPickupFillType, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        if workArea.lastValidPickupFillType == FillType.GRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        elseif workArea.lastValidPickupFillType == FillType.DRYGRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.GRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, nil, false, nil)
        end
        if pickupLiters > 0 then
            pickupFillType = workArea.lastValidPickupFillType
        end
    end
    if pickupFillType ~= FillType.UNKNOWN then
        workArea.lastValidPickupFillType = pickupFillType
    end
    workArea.lastPickupLiters = pickupLiters
    workArea.litersToDrop = workArea.litersToDrop + pickupLiters
    local area = MathUtil.vector3Length(lsx - lex, lsy - ley, lsz - lez) * self.lastMovedDistance
    if workArea.lastPickupLiters > 0 then
        local dropArea = self.spec_workArea.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil then
            local _ = workArea.lastValidPickupFillType
            local fillTypeIndex = self:processDropArea(dropArea, workArea.lastPickupLiters, _)
            workArea.lastDroppedLiters = fillTypeIndex
            workArea.litersToDrop = workArea.litersToDrop - fillTypeIndex
        end
    end
    return workArea.lastDroppedLiters, area
end
-- :385-390 VERBATIM.
function Windrower:processDropArea(dropArea, litersToDrop, fillType)
    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, litersToDrop, fillType, lsx, lsy, lsz, lex, ley, lez, radius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset
    return dropped
end

--- A windrower as the engine builds it: functions copied into the instance, the
--- work-area pointer captured (WorkArea.lua:266), the start listener on its class.
--- Rakes x 0..8, z 0..2 onto a drop strip at z = dropZ.
function ENGINE.newWindrower(opts)
    local v = { isServer = true, isClient = false, currentUpdateDistance = 0, lastMovedDistance = 1, uniqueId = opts.uid or "windrower" }
    v.processWindrowerArea = Windrower.processWindrowerArea
    v.processDropArea = Windrower.processDropArea
    v.getLastSpeed = function() return 0 end
    v.specClasses = { Windrower }
    v.spec_windrower = {
        supportedFillTypes = { ENGINE.FT.GRASS_WINDROW, ENGINE.FT.DRYGRASS_WINDROW, ENGINE.FT.STRAW },
        limitToLineHeight = false, windrowerWorkAreaFillTypes = {}, isWorking = false,
    }
    local x0, z0, w, d = opts.x0, opts.z0, opts.width, opts.depth
    local work = {
        index = 1, functionName = "processWindrowerArea",
        start = { x = x0, z = z0 }, width = { x = x0 + w, z = z0 }, height = { x = x0, z = z0 + d },
        litersToDrop = 0, lastPickupLiters = 0, lastValidPickupFillType = FillType.UNKNOWN, lastDroppedLiters = 0,
        dropWindrowWorkAreaIndex = 2, windrowerWorkAreaIndex = 1,
    }
    local drop = {
        index = 2, functionName = nil,
        start = { x = x0, z = opts.dropZ }, width = { x = x0 + w, z = opts.dropZ }, height = { x = x0, z = opts.dropZ + (opts.dropDepth or 1) },
        lineOffset = 0,
    }
    v.spec_workArea = { workAreas = { work, drop } }
    work.processingFunction = v[work.functionName]
    return v, work, drop
end

-- utils/Utils.lua:380-402 VERBATIM: the class-hook composers installAll's other hooks use.
Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(oldFunc, newFunc)
    return oldFunc ~= nil and function(...) oldFunc(...) newFunc(...) end or newFunc
end
Utils.prependedFunction = Utils.prependedFunction or function(oldFunc, newFunc)
    return oldFunc ~= nil and function(...) newFunc(...) oldFunc(...) end or newFunc
end
Utils.overwrittenFunction = Utils.overwrittenFunction or function(oldFunc, newFunc)
    return oldFunc == nil and function(self, ...) return newFunc(self, nil, ...) end
        or function(self, ...) return newFunc(self, oldFunc, ...) end
end

-- MODELED: the engine's mod event listener registry. A later installAll hook registers
-- a listener; nothing a carrier does goes through it.
addModEventListener = addModEventListener or function(_listener) end

-- ── the Mower (vehicles/specializations/Mower.lua) ───────────────────────────
WorkAreaType = WorkAreaType or { DEFAULT = 1, MOWER = 7, AUXILIARY = 9 }
ToolType = ToolType or { UNDEFINED = 0 }
g_time = g_time or 0
ENGINE.FRUIT = { GRASS = 21 }
-- MODELED: the fruit density map is C. updateMowerArea returns the pixels it cut this
-- call from ENGINE.mowable[fruit] (set by a bar), and one cut pixel is one litre.
ENGINE.mowable = {}
FSDensityMapUtil = FSDensityMapUtil or {}
function FSDensityMapUtil.updateMowerArea(fruitType, _xs, _zs, _xw, _zw, _xh, _zh, _limitToField)
    local cut = ENGINE.mowable[fruitType] or 0
    return cut, cut, 0, 0, 0, 0, 0, 0, 0, 1, nil
end
g_fruitTypeManager = g_fruitTypeManager or {}
g_fruitTypeManager.getFruitTypeAreaLiters = function(_, _fruitType, area, _useWindrowed) return area end
Mower = {}
Mower.CLIENT_DM_UPDATE_RADIUS = 50
-- :541-561: the per-frame reset VERBATIM; the server drop-effect block before it is
-- presentation (dirty flags, effects) and abbreviated.
function Mower:onStartWorkAreaProcessing(_)
    local spec = self.spec_mower
    local workAreas = self:getTypedWorkAreas(WorkAreaType.MOWER)
    for _ = 1, #workAreas do
        workAreas[_].pickedUpLiters = 0
    end
    spec.workAreaParameters.lastChangedArea = 0
    spec.workAreaParameters.lastStatsArea = 0
    spec.workAreaParameters.lastTotalArea = 0
    spec.isWorking = false
end
-- :328-382 VERBATIM through the quantities: the per-converter cut, the direct-to-
-- FillUnit branch, the shared drop area's pending litres, the type retarget, the old
-- DRYGRASS pickup under a GRASS_WINDROW cut and the 1000 L cap. Abbreviated: the
-- stone read and the statistics lines (not quantity), and getHarvestScaleMultiplier,
-- held at 1. The decompile's `pickup` is an undeclared global; it is local here.
function Mower:processMowerArea(workArea, _)
    local spec = self.spec_mower
    if not self.isServer and self.currentUpdateDistance > Mower.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local xs, _, zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)
    local workAreaChanged = 0
    local workAreaTotal = 0
    local limitToField = false
    for inputFruitType, converterData in pairs(spec.fruitTypeConverters) do
        local changedArea, totalArea = FSDensityMapUtil.updateMowerArea(inputFruitType, xs, zs, xw, zw, xh, zh, limitToField)
        if changedArea > 0 then
            local multiplier = 1
            local litersToDrop = g_fruitTypeManager:getFruitTypeAreaLiters(inputFruitType, changedArea, true) * multiplier * converterData.conversionFactor
            workArea.lastPickupLiters = litersToDrop
            workArea.pickedUpLiters = litersToDrop
            local dropArea = self:getDropArea(workArea)
            if dropArea == nil then
                if spec.fillUnitIndex ~= nil and self.isServer then
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, litersToDrop, converterData.fillTypeIndex, ToolType.UNDEFINED)
                end
            else
                dropArea.litersToDrop = dropArea.litersToDrop + litersToDrop
                dropArea.fillType = converterData.fillTypeIndex
                dropArea.workAreaIndex = workArea.index
                if dropArea.fillType == FillType.GRASS_WINDROW then
                    local lsx, lsy, lsz, lex, ley, lez, radius = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height, true)
                    local pickup
                    pickup, workArea.lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, radius, nil, workArea.lineOffset or 0, false, nil, false)
                    dropArea.litersToDrop = dropArea.litersToDrop - pickup
                end
                local lsy = dropArea.litersToDrop
                dropArea.litersToDrop = math.min(lsy, 1000)
            end
            workAreaTotal = totalArea
        end
    end
    return workAreaChanged, workAreaTotal
end
-- :383-405 MODELED. The decompile collapses the second random into `ex`; kept: the
-- server/distance gate, the minimum-valid gate, ONE tip of the whole pending amount on
-- a line across the drop area, the actual dropped subtracted, the offset kept. The
-- random line position is fixed at the drop area's own line.
function Mower:processDropArea(dropArea, _)
    if self.isServer or self.currentUpdateDistance <= Mower.CLIENT_DM_UPDATE_RADIUS then
        if dropArea.litersToDrop > g_densityMapHeightManager:getMinValidLiterValue(dropArea.fillType) then
            local sx, sy, sz, ex, ey, ez = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height)
            local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, dropArea.litersToDrop, dropArea.fillType, sx, sy, sz, ex, ey, ez, 0, nil, dropArea.dropLineOffset, false, nil, false)
            dropArea.litersToDrop = dropArea.litersToDrop - dropped
            dropArea.dropLineOffset = lineOffset
            if dropped ~= 0 then
                self.spec_mower.lastDropTime = g_time
            end
        end
    end
end
-- :406-424 VERBATIM without its two warnings.
function Mower:getDropArea(workArea)
    if not workArea.dropWindrow then
        return nil
    end
    local dropArea = nil
    if workArea.dropAreaIndex ~= nil then
        dropArea = self.spec_workArea.workAreas[workArea.dropAreaIndex]
        if dropArea ~= nil and dropArea.type ~= WorkAreaType.AUXILIARY then
            workArea.dropAreaIndex = nil
            dropArea = nil
        end
    end
    return dropArea
end
-- :562-566 VERBATIM: every drop area drops through the INSTANCE copy. The effect and
-- statistics lines after it are presentation and abbreviated.
function Mower:onEndWorkAreaProcessing(dt, _)
    local spec = self.spec_mower
    for _, dropArea in ipairs(spec.dropAreas) do
        self:processDropArea(dropArea, dt)
    end
end

--- A mower as the engine builds it: functions copied into the instance, each mower
--- work area's pointer captured (WorkArea.lua:266), its listeners on its class.
--- opts.areas mower work areas side by side (x0 + (i-1)*width), each depth deep from
--- z0, all feeding drop area opts.dropIndex (an AUXILIARY strip at z = dropZ), or
--- no drop area at all with opts.noDrop (the direct-to-FillUnit branch).
function ENGINE.newMower(opts)
    local v = { isServer = true, isClient = false, currentUpdateDistance = 0, uniqueId = opts.uid or "mower",
                fill = { level = 0, calls = 0 } }
    v.processMowerArea = Mower.processMowerArea
    v.processDropArea = Mower.processDropArea
    v.getDropArea = Mower.getDropArea
    v.specClasses = { Mower }
    v.getOwnerFarmId = function() return 1 end
    v.addFillUnitFillLevel = function(self, _farm, _i, delta) self.fill.level = self.fill.level + delta; self.fill.calls = self.fill.calls + 1 return delta end
    v.spec_mower = {
        fruitTypeConverters = { [ENGINE.FRUIT.GRASS] = { fillTypeIndex = ENGINE.FT.GRASS_WINDROW, conversionFactor = 1 } },
        workAreaParameters = { lastChangedArea = 0, lastStatsArea = 0, lastTotalArea = 0 },
        dropAreas = {}, fillUnitIndex = opts.noDrop and 1 or nil, lastDropTime = 0, isWorking = false,
    }
    local n, x0, z0, w, d = opts.areas or 1, opts.x0, opts.z0, opts.width, opts.depth
    local areas, mowers = {}, {}
    for i = 1, n do
        local xa = x0 + (i - 1) * w
        local wa = { index = i, type = WorkAreaType.MOWER, functionName = "processMowerArea",
            start = { x = xa, z = z0 }, width = { x = xa + w, z = z0 }, height = { x = xa, z = z0 + d },
            dropWindrow = not opts.noDrop, dropAreaIndex = n + 1, lastPickupLiters = 0, pickedUpLiters = 0 }
        areas[#areas + 1] = wa
        mowers[#mowers + 1] = wa
    end
    local drop = { index = n + 1, type = WorkAreaType.AUXILIARY, functionName = nil,
        start = { x = x0, z = opts.dropZ }, width = { x = x0 + n * w, z = opts.dropZ }, height = { x = x0, z = opts.dropZ + (opts.dropDepth or 1) },
        litersToDrop = 0, fillType = FillType.UNKNOWN }
    areas[#areas + 1] = drop
    v.spec_mower.dropAreas = { drop }
    v.spec_workArea = { workAreas = areas }
    v.getTypedWorkAreas = function(self, areaType)
        local out = {}
        for _, a in ipairs(self.spec_workArea.workAreas) do if a.type == areaType then out[#out + 1] = a end end
        return out
    end
    for _, wa in ipairs(mowers) do wa.processingFunction = v[wa.functionName] end
    return v, mowers, drop
end

-- ── world owners, built by SoilFertilitySystem.new through their own .new ────
MaterialDown = {
    LAYER_KEY = "materialAge",
    new = function()
        return { armed = true, ageAppliedThroughDay = nil,
                 isArmed = function(self) return self.armed end,
                 onAgeTick = function(self, ctx) self.ageAppliedThroughDay = ctx.monotonicDay end }
    end,
}
MaterialWetness = {
    LAYER_KEY = "materialWetness",
    new = function()
        return { armed = true, appliedThroughDay = nil, hold = false,
                 isArmed = function(self) return self.armed end,
                 onConditionAccrual = function(self, ctx) if not self.hold then self.appliedThroughDay = ctx.monotonicDay end end }
    end,
}
HayBet = {
    new = function()
        return { armed = true, seen = {},
                 isArmed = function(self) return self.armed end,
                 applyTedderDelta = function(self, poly) self.seen[#self.seen + 1] = ENGINE.snapshot and ENGINE.snapshot() or true end,
                 enqueueCorrection = function() end }
    end,
}
