-- =========================================================
-- FS25 Soil & Fertilizer - CD-15 NATIVE CELL PROBE (chore, read-only)
-- =========================================================
-- Measures, on a live map, what the CD-15 local-disease design needs to know
-- before its kernel is built: how the native fruit density planes line up
-- with Soil's cells, what a DensityMapMultiModifier count over one Soil cell
-- returns against a full per-pixel enumeration of the same cell, how those
-- counts change around real cut, mow and sow work, and what one execute
-- costs. It logs; it never writes a density map, a value map, a save field or
-- any gameplay state, and every hook it installs delegates unchanged and is
-- removed by "hooks off". Removing this file and its source line leaves no
-- trace.
--
-- Console: sfCd15Probe planes | here | cell <gx> <gz> | at <x> <z>
--          | area <x1> <z1> <x2> <z2> | hooks on|off | bench <n> | report | reset
--
-- Engine seams (D:\FS25_Decoded\dataS\scripts_decompiled):
--   HarvestMission:createModifier missions/field/HarvestMission.lua:187-199
--     (DensityMapModifier.new(desc.terrainDataPlaneId, desc.startStateChannel,
--     desc.numStateChannels, g_terrainNode); DensityMapFilter.new(modifier);
--     DensityMapMultiModifier.new(); addExecuteGet(name, modifier, filter));
--     execute at :288-290 (resetStats; execute(nil, statsTable, nil))
--   FieldGetInfoTask:setFruitTypes field/FieldGetInfoTask.lua:20-31 (one
--     EQUAL filter per foliage state), execute :72 returns the touched count
--   Parallelogram: debug/elements/DebugDensityMap.lua:52
--     (setParallelogramWorldCoords with DensityCoordType.POINT_POINT_POINT)
--   Inclusive rounding: utils/FSDensityMapUtil.lua:3-8; executeGet returns
--     ret, numPixels, totalNumPixels :232
--   FruitTypeDesc fields fruits/FruitTypeDesc.lua:127-128 (state channels),
--     :142-143 and :233/:240 (cutStates, witheredState), :601 (plane id)
--   Per-pixel reads getDensityTypeIndexAtWorldPos / getDensityStatesAtWorldPos
--     (engine, LUADOC docs/engine/Terrain Detail; no decompiled script calls
--     them, so their return shapes are logged raw here)
--   Work-area pointer capture vehicles/specializations/WorkArea.lua:266,
--     called at :182-183; hook sites Cutter.lua:584, Mower.lua:328,
--     SowingMachine.lua:362; Soil's four-surface wrap pattern
--     src/hooks/HookManager.lua:2726-2800
--   Timer getTimeSec() (field/course/ai/AIFieldCourse.lua:184)
-- =========================================================

CD15NativeCellProbe = CD15NativeCellProbe or {}
local P = CD15NativeCellProbe

P.VERSION = 1
P.HOOK_SITES = {
    { class = "Cutter",        fn = "processCutterArea" },
    { class = "Mower",         fn = "processMowerArea" },
    { class = "SowingMachine", fn = "processSowingMachineArea" },
}
P.DEFAULT_INSET_FRACTION = 0.1

local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function log(fmt, ...)
    local msg = "[CD15 probe] " .. string.format(fmt, ...)
    if SoilLogger ~= nil and SoilLogger.info ~= nil then SoilLogger.info(msg) else print(msg) end
    P.state.log[#P.state.log + 1] = msg
end

-- =========================================================
-- Pure geometry and classification (bench-covered)
-- =========================================================

--- Soil cell size in metres for a terrain and value-map resolution.
function P.cellSizeMetres(terrainSize, resolution)
    if not isFinite(terrainSize) or not isFinite(resolution) or resolution <= 0 then return nil end
    return terrainSize / resolution
end

--- The Soil cell (gx, gz) holding a world position, half-open like the
--- reference bar's cell(): the negative edge is admitted, the positive edge
--- refuses, off-map and non-finite refuse (nil), never clamp.
function P.cellOfWorld(x, z, terrainSize, resolution)
    if not isFinite(x) or not isFinite(z) or not isFinite(terrainSize) or not isFinite(resolution) or resolution <= 0 then return nil end
    local half = terrainSize / 2
    if x < -half or z < -half or x >= half or z >= half then return nil end
    return math.floor((x + half) * resolution / terrainSize), math.floor((z + half) * resolution / terrainSize)
end

--- World bounds of a cell: minX, minZ, maxX, maxZ.
function P.cellBounds(gx, gz, terrainSize, resolution)
    local size = P.cellSizeMetres(terrainSize, resolution)
    if size == nil or not isFinite(gx) or not isFinite(gz) then return nil end
    local half = terrainSize / 2
    local minX, minZ = -half + gx * size, -half + gz * size
    return minX, minZ, minX + size, minZ + size
end

--- Parallelogram corners for setParallelogramWorldCoords (start, width, height)
--- with an inset in metres pulled in from every edge (0 for the exact cell).
function P.cellParallelogram(gx, gz, terrainSize, resolution, inset)
    local minX, minZ, maxX, maxZ = P.cellBounds(gx, gz, terrainSize, resolution)
    if minX == nil then return nil end
    inset = isFinite(inset) and inset or 0
    if inset < 0 or 2 * inset >= (maxX - minX) then return nil end
    return minX + inset, minZ + inset, maxX - inset, minZ + inset, minX + inset, maxZ - inset
end

--- Classify one raw growth state of a fruit: "empty" (0), "cut", "withered"
--- or "living". Out-of-range states (a modded plane) are "other".
function P.classifyState(desc, state)
    if not isFinite(state) or state < 0 then return "other" end
    if state == 0 then return "empty" end
    if desc == nil then return "other" end
    if type(desc.cutStates) == "table" and desc.cutStates[state] then return "cut" end
    if desc.witheredState ~= nil and state == desc.witheredState then return "withered" end
    local maxState = desc.numStateChannels ~= nil and (2 ^ desc.numStateChannels - 1) or nil
    if maxState ~= nil and state > maxState then return "other" end
    return "living"
end

--- Compare per-class counts from the point enumeration with the modifier.
--- Returns rows { class, point, modifier, delta } in a fixed order.
function P.compareCounts(pointCounts, modifierCounts)
    local rows = {}
    for _, cls in ipairs({ "living", "cut", "withered", "empty", "other", "any", "total" }) do
        local p = pointCounts and pointCounts[cls] or 0
        local m = modifierCounts and modifierCounts[cls] or 0
        rows[#rows + 1] = { class = cls, point = p, modifier = m, delta = m - p }
    end
    return rows
end

--- Timing summary in microseconds over an array of seconds samples.
function P.summarizeTimings(samples)
    local n, sum, max = 0, 0, 0
    for _, s in ipairs(samples or {}) do
        if isFinite(s) then
            n = n + 1
            sum = sum + s
            if s > max then max = s end
        end
    end
    if n == 0 then return { n = 0, meanUs = 0, maxUs = 0 } end
    return { n = n, meanUs = sum / n * 1e6, maxUs = max * 1e6 }
end

--- Bounding-box cells under a work area's start/width/height corners.
function P.cellsUnderQuad(xs, zs, xw, zw, xh, zh, terrainSize, resolution)
    local x4, z4 = xw + xh - xs, zw + zh - zs
    local minX, maxX = math.min(xs, xw, xh, x4), math.max(xs, xw, xh, x4)
    local minZ, maxZ = math.min(zs, zw, zh, z4), math.max(zs, zw, zh, z4)
    local size = P.cellSizeMetres(terrainSize, resolution)
    if size == nil then return {} end
    local out, seen = {}, {}
    local half = terrainSize / 2
    local eps = size * 1e-6
    local x = minX
    while x <= maxX do
        local z = minZ
        while z <= maxZ do
            local gx, gz = P.cellOfWorld(math.max(-half, math.min(half - eps, x)), math.max(-half, math.min(half - eps, z)), terrainSize, resolution)
            if gx ~= nil then
                local key = gx .. ":" .. gz
                if not seen[key] then seen[key] = true out[#out + 1] = { gx = gx, gz = gz } end
            end
            z = z + size
        end
        x = x + size
    end
    return out
end

-- =========================================================
-- Runtime state (nothing here runs unless a console command asks)
-- =========================================================
P.state = P.state or { enabled = false, hooks = nil, fruits = nil, timings = {}, frameMax = {}, log = {}, insetFraction = P.DEFAULT_INSET_FRACTION }

local function terrainFacts()
    local sfm = g_SoilFertilityManager
    local vm = sfm and sfm.soilSystem and sfm.soilSystem.valueMaps or nil
    local terrainSize = vm and vm.terrainSize or (g_terrainNode ~= nil and getTerrainSize ~= nil and getTerrainSize(g_terrainNode) or nil)
    local resolution = vm and vm.resolution or nil
    return terrainSize, resolution, vm
end

--- Per-fruit cached modifier machine: one modifier on the fruit's plane, one
--- EQUAL filter per raw state, one multi-modifier with an executeGet per state
--- (FieldGetInfoTask's shape), plus the fruit pixel size for point stepping.
function P.ensureFruitCache()
    if P.state.fruits ~= nil then return P.state.fruits end
    local fruits = {}
    if g_fruitTypeManager == nil or DensityMapModifier == nil or DensityMapFilter == nil or DensityMapMultiModifier == nil then return fruits end
    local terrainSize = terrainFacts()
    local planeUsers = {}
    for _, desc in pairs(g_fruitTypeManager:getFruitTypes()) do
        if desc.terrainDataPlaneId ~= nil and desc.terrainDataPlaneId ~= 0 then
            local modifier = DensityMapModifier.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels, g_terrainNode)
            local multi = DensityMapMultiModifier.new()
            local maxState = 2 ^ desc.numStateChannels - 1
            for state = 1, maxState do
                local filter = DensityMapFilter.new(modifier)
                filter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
                multi:addExecuteGet("s" .. state, modifier, filter)
            end
            local anyFilter = DensityMapFilter.new(modifier)
            anyFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
            multi:addExecuteGet("any", modifier, anyFilter)
            local mapSize = getDensityMapSize ~= nil and getDensityMapSize(desc.terrainDataPlaneId) or nil
            local pixelMetres = (isFinite(terrainSize) and isFinite(mapSize) and mapSize > 0) and (terrainSize / mapSize) or nil
            planeUsers[desc.terrainDataPlaneId] = (planeUsers[desc.terrainDataPlaneId] or 0) + 1
            fruits[#fruits + 1] = { desc = desc, name = desc.name, planeId = desc.terrainDataPlaneId, modifier = modifier, multi = multi,
                maxState = maxState, mapSize = mapSize, pixelMetres = pixelMetres, stats = {} }
        end
    end
    for _, f in ipairs(fruits) do f.planeShared = (planeUsers[f.planeId] or 0) > 1 end
    P.state.fruits = fruits
    return fruits
end

--- Modifier counts of one cell for one fruit (per class), and the seconds it took.
function P.countCellModifier(f, gx, gz, inset)
    local terrainSize, resolution = terrainFacts()
    local sx, sz, wx, wz, hx, hz = P.cellParallelogram(gx, gz, terrainSize, resolution, inset)
    if sx == nil then return nil, 0 end
    f.modifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    local stats = {}
    f.multi:resetStats()
    local t0 = getTimeSec ~= nil and getTimeSec() or 0
    local _, _, _, touched = f.multi:execute(nil, stats, nil)
    local dt = (getTimeSec ~= nil and getTimeSec() or 0) - t0
    local counts = { living = 0, cut = 0, withered = 0, empty = 0, other = 0, any = stats.any or 0, total = touched or 0 }
    local classified = 0
    for state = 1, f.maxState do
        local n = stats["s" .. state] or 0
        if n > 0 then
            local cls = P.classifyState(f.desc, state)
            counts[cls] = counts[cls] + n
            classified = classified + n
        end
    end
    counts.empty = math.max(0, (touched or 0) - classified)
    return counts, dt
end

--- Point enumeration of one cell for one fruit: every fruit pixel centre in
--- the cell is read with the two per-pixel functions; raw return shapes are
--- kept for the log the first time they are seen.
function P.countCellPoints(f, gx, gz)
    local terrainSize, resolution = terrainFacts()
    local minX, minZ, maxX, maxZ = P.cellBounds(gx, gz, terrainSize, resolution)
    if minX == nil or f.pixelMetres == nil or getDensityTypeIndexAtWorldPos == nil or getDensityStatesAtWorldPos == nil then return nil end
    local counts = { living = 0, cut = 0, withered = 0, empty = 0, other = 0, any = 0, total = 0 }
    local typeSeen = {}
    local step = f.pixelMetres
    local x = minX + step * 0.5
    while x < maxX do
        local z = minZ + step * 0.5
        while z < maxZ do
            local typeIndex = getDensityTypeIndexAtWorldPos(f.planeId, x, 0, z)
            local states = getDensityStatesAtWorldPos(f.planeId, x, 0, z)
            typeSeen[tostring(typeIndex)] = (typeSeen[tostring(typeIndex)] or 0) + 1
            counts.total = counts.total + 1
            local cls = P.classifyState(f.desc, states)
            counts[cls] = counts[cls] + 1
            if isFinite(states) and states > 0 then counts.any = counts.any + 1 end
            z = z + step
        end
        x = x + step
    end
    counts.typeIndexHistogram = typeSeen
    return counts
end

local function histogramText(h)
    local parts = {}
    for k, v in pairs(h or {}) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
end

--- Log one cell: both modifier passes (exact and inset) against the point
--- enumeration, per fruit that has any pixel in the cell, plus timing.
function P.reportCell(gx, gz, tag)
    local terrainSize, resolution = terrainFacts()
    if terrainSize == nil or resolution == nil then log("no terrain or value-map facts (Soil not armed)") return end
    local size = P.cellSizeMetres(terrainSize, resolution)
    local fruits = P.ensureFruitCache()
    log("%scell %d,%d (size %.3f m, terrain %d, resolution %d)", tag and (tag .. " ") or "", gx, gz, size, terrainSize, resolution)
    for _, f in ipairs(fruits) do
        local inset = (f.pixelMetres or size) * P.state.insetFraction
        local exact, dtExact = P.countCellModifier(f, gx, gz, 0)
        local insetCounts, dtInset = P.countCellModifier(f, gx, gz, inset)
        local points = P.countCellPoints(f, gx, gz)
        P.state.timings[#P.state.timings + 1] = dtExact
        local anyHere = (exact and exact.any or 0) > 0 or (points and points.any or 0) > 0
        if anyHere then
            log("  %s plane %s%s pixel %.3f m (%s px per cell edge) exact %.1f us inset %.1f us",
                f.name, tostring(f.planeId), f.planeShared and " SHARED" or "", f.pixelMetres or -1,
                f.pixelMetres and string.format("%.2f", size / f.pixelMetres) or "?", dtExact * 1e6, dtInset * 1e6)
            for _, row in ipairs(P.compareCounts(points, exact)) do
                local ins = insetCounts and insetCounts[row.class] or 0
                log("    %-8s point %5d  modifier %5d (delta %+d)  inset %5d", row.class, row.point, row.modifier, row.delta, ins)
            end
            if points and points.typeIndexHistogram then log("    typeIndex histogram: %s", histogramText(points.typeIndexHistogram)) end
        end
    end
end

function P.reportPlanes()
    local terrainSize, resolution = terrainFacts()
    local fruits = P.ensureFruitCache()
    local planes, distinct = {}, 0
    for _, f in ipairs(fruits) do
        if not planes[f.planeId] then planes[f.planeId] = true distinct = distinct + 1 end
    end
    log("terrain %s, Soil resolution %s, cell %s m, %d fruit planes, %d distinct", tostring(terrainSize), tostring(resolution),
        terrainSize and resolution and string.format("%.3f", terrainSize / resolution) or "?", #fruits, distinct)
    for _, f in ipairs(fruits) do
        log("  %-16s plane %-6s mapSize %-5s pixel %s m%s channels %d..%d cut %s withered %s", f.name, tostring(f.planeId), tostring(f.mapSize),
            f.pixelMetres and string.format("%.3f", f.pixelMetres) or "?", f.planeShared and " SHARED" or "",
            f.desc.startStateChannel or -1, f.desc.numStateChannels or -1, (function() local t = {} for s in pairs(f.desc.cutStates or {}) do t[#t + 1] = s end table.sort(t) return table.concat(t, ",") end)(),
            tostring(f.desc.witheredState))
    end
end

function P.reportArea(x1, z1, x2, z2)
    local terrainSize, resolution = terrainFacts()
    local a = P.cellOfWorld(math.min(x1, x2), math.min(z1, z2), terrainSize, resolution)
    local ax, az = P.cellOfWorld(math.min(x1, x2), math.min(z1, z2), terrainSize, resolution)
    local bx, bz = P.cellOfWorld(math.max(x1, x2), math.max(z1, z2), terrainSize, resolution)
    if ax == nil or bx == nil then log("area refused: a corner is off the map") return end
    local n = 0
    for gx = ax, bx do for gz = az, bz do P.reportCell(gx, gz) n = n + 1 end end
    log("area done: %d cells", n)
end

function P.benchExecute(n)
    local fruits = P.ensureFruitCache()
    local terrainSize, resolution = terrainFacts()
    local gx, gz = P.cellOfWorld(0, 0, terrainSize, resolution)
    if gx == nil or #fruits == 0 then log("bench refused: no map or no fruit planes") return end
    local samples = {}
    for i = 1, n do
        for _, f in ipairs(fruits) do
            local _, dt = P.countCellModifier(f, gx, gz, 0)
            samples[#samples + 1] = dt
        end
    end
    local s = P.summarizeTimings(samples)
    log("bench: %d executes, mean %.1f us, max %.1f us (%s, %s)", s.n, s.meanUs, s.maxUs,
        g_dedicatedServer ~= nil and "dedicated" or "singleplayer/listen", tostring(terrainSize))
end

-- =========================================================
-- Hooks: four surfaces, delegate unchanged, removable
-- =========================================================
local function workAreaQuad(workArea)
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then return nil end
    local xs, _, zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)
    if xs == nil or xw == nil or xh == nil then return nil end
    return xs, zs, xw, zw, xh, zh
end

local function snapshotCells(cells)
    local fruits = P.ensureFruitCache()
    local out = {}
    for _, c in ipairs(cells) do
        for _, f in ipairs(fruits) do
            local m = P.countCellModifier(f, c.gx, c.gz, 0)
            local p = P.countCellPoints(f, c.gx, c.gz)
            if (m and m.any or 0) > 0 or (p and p.any or 0) > 0 then
                out[#out + 1] = { gx = c.gx, gz = c.gz, fruit = f.name, modifier = m, point = p }
            end
        end
    end
    return out
end

local function describe(rows)
    local parts = {}
    for _, r in ipairs(rows) do
        parts[#parts + 1] = string.format("%s@%d,%d mod[l%d c%d w%d any%d] pt[l%d c%d w%d any%d]", r.fruit, r.gx, r.gz,
            r.modifier.living, r.modifier.cut, r.modifier.withered, r.modifier.any,
            r.point and r.point.living or -1, r.point and r.point.cut or -1, r.point and r.point.withered or -1, r.point and r.point.any or -1)
    end
    return #parts > 0 and table.concat(parts, "; ") or "(no fruit in the touched cells)"
end

--- One wrapper factory for every surface. When the probe is off it is a pure
--- delegate; when on it snapshots the touched cells before the native call,
--- delegates once with unchanged arguments, and reads again in the same frame.
function P.makeWrapper(site, chainFn)
    return function(vehicleSelf, workArea, dt)
        if not P.state.enabled then return chainFn(vehicleSelf, workArea, dt) end
        local terrainSize, resolution = terrainFacts()
        local cells = {}
        local ok, quad = pcall(function() return { workAreaQuad(workArea) } end)
        if ok and quad[1] ~= nil and terrainSize ~= nil and resolution ~= nil then
            cells = P.cellsUnderQuad(quad[1], quad[2], quad[3], quad[4], quad[5], quad[6], terrainSize, resolution)
        end
        local before = {}
        pcall(function() before = snapshotCells(cells) end)
        local t0 = getTimeSec ~= nil and getTimeSec() or 0
        local r1, r2, r3, r4, r5 = chainFn(vehicleSelf, workArea, dt)
        local tNative = (getTimeSec ~= nil and getTimeSec() or 0) - t0
        local after = {}
        local t1 = getTimeSec ~= nil and getTimeSec() or 0
        pcall(function() after = snapshotCells(cells) end)
        local tProbe = (getTimeSec ~= nil and getTimeSec() or 0) - t1
        local frame = g_currentMission ~= nil and g_currentMission.time or 0
        P.state.frameMax[frame] = math.max(P.state.frameMax[frame] or 0, tProbe)
        log("%s.%s frame %s cells %d native %.1f us probe %.1f us | before %s | after (same frame) %s",
            site.class, site.fn, tostring(frame), #cells, tNative * 1e6, tProbe * 1e6, describe(before), describe(after))
        return r1, r2, r3, r4, r5
    end
end

--- Wrap the class function, every registered vehicle type's function slot,
--- every live vehicle's instance slot and every live work area's stored
--- processing pointer (WorkArea.lua:266 copies self[functionName] at load and
--- :182-183 calls only that copy). Originals are kept for "hooks off".
function P.hooksOn()
    if P.state.hooks ~= nil then P.state.enabled = true log("hooks already installed; enabled") return true end
    local hooks = { originals = {} }
    local function wrapSlot(holder, key, site, label)
        local fn = holder[key]
        if type(fn) ~= "function" then return end
        hooks.originals[#hooks.originals + 1] = { holder = holder, key = key, fn = fn, label = label }
        holder[key] = P.makeWrapper(site, fn)
    end
    for _, site in ipairs(P.HOOK_SITES) do
        local cls = _G[site.class]
        if cls ~= nil then wrapSlot(cls, site.fn, site, site.class .. " class") end
        if g_vehicleTypeManager ~= nil and g_vehicleTypeManager.getTypes ~= nil then
            for typeName, vType in pairs(g_vehicleTypeManager:getTypes()) do
                if vType.functions ~= nil and type(vType.functions[site.fn]) == "function" then
                    wrapSlot(vType.functions, site.fn, site, "type " .. tostring(typeName))
                end
            end
        end
        local vs = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
        if vs ~= nil and vs.vehicles ~= nil then
            for _, vehicle in pairs(vs.vehicles) do
                if rawget(vehicle, site.fn) ~= nil then wrapSlot(vehicle, site.fn, site, "instance") end
                local wa = vehicle.spec_workArea
                if wa ~= nil and wa.workAreas ~= nil then
                    for _, workArea in ipairs(wa.workAreas) do
                        if workArea.functionName == site.fn and type(workArea.processingFunction) == "function" then
                            wrapSlot(workArea, "processingFunction", site, "work area pointer")
                        end
                    end
                end
            end
        end
    end
    P.state.hooks = hooks
    P.state.enabled = true
    log("hooks on: %d slots wrapped (class, registered types, live instances, live work-area pointers)", #hooks.originals)
    return true
end

function P.hooksOff()
    local hooks = P.state.hooks
    P.state.enabled = false
    if hooks == nil then log("hooks off: nothing installed") return true end
    local restored = 0
    for i = #hooks.originals, 1, -1 do
        local o = hooks.originals[i]
        o.holder[o.key] = o.fn
        restored = restored + 1
    end
    P.state.hooks = nil
    log("hooks off: %d slots restored", restored)
    return true
end

function P.report()
    local s = P.summarizeTimings(P.state.timings)
    local worst, worstFrame = 0, nil
    for frame, t in pairs(P.state.frameMax) do if t > worst then worst, worstFrame = t, frame end end
    log("report: %d cell executes, mean %.1f us, max %.1f us; per-frame probe max %.1f us (frame %s); %s; log lines %d",
        s.n, s.meanUs, s.maxUs, worst * 1e6, tostring(worstFrame), g_dedicatedServer ~= nil and "dedicated" or "singleplayer/listen", #P.state.log)
    return P.state.log[#P.state.log]
end

function P.reset()
    P.hooksOff()
    P.state.fruits = nil
    P.state.timings = {}
    P.state.frameMax = {}
    P.state.log = {}
    return "probe reset"
end

local function playerPosition()
    local p = g_localPlayer
    if p == nil then return nil end
    if type(p.getPosition) == "function" then
        local ok, x, y, z = pcall(p.getPosition, p)
        if ok and x ~= nil then return x, z end
    end
    if p.rootNode ~= nil and getWorldTranslation ~= nil then
        local x, _, z = getWorldTranslation(p.rootNode)
        return x, z
    end
    return nil
end

function P.console(sub, a, b, c, d)
    sub = tostring(sub or "")
    local terrainSize, resolution = terrainFacts()
    if sub == "planes" then P.reportPlanes() return "planes logged"
    elseif sub == "cell" then
        local gx, gz = tonumber(a), tonumber(b)
        if gx == nil or gz == nil then return "usage: sfCd15Probe cell <gx> <gz>" end
        P.reportCell(gx, gz) return "cell logged"
    elseif sub == "at" then
        local gx, gz = P.cellOfWorld(tonumber(a), tonumber(b), terrainSize, resolution)
        if gx == nil then return "off map or no map" end
        P.reportCell(gx, gz, "at") return string.format("cell %d,%d logged", gx, gz)
    elseif sub == "here" then
        local x, z = playerPosition()
        if x == nil then return "no local player position" end
        local gx, gz = P.cellOfWorld(x, z, terrainSize, resolution)
        if gx == nil then return "off map or no map" end
        P.reportCell(gx, gz, string.format("here (%.1f, %.1f)", x, z)) return string.format("cell %d,%d logged", gx, gz)
    elseif sub == "area" then
        local x1, z1, x2, z2 = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        if x1 == nil or z1 == nil or x2 == nil or z2 == nil then return "usage: sfCd15Probe area <x1> <z1> <x2> <z2>" end
        P.reportArea(x1, z1, x2, z2) return "area logged"
    elseif sub == "hooks" then
        if a == "on" then P.hooksOn() return "hooks on" end
        if a == "off" then P.hooksOff() return "hooks off" end
        return "usage: sfCd15Probe hooks on|off"
    elseif sub == "bench" then P.benchExecute(math.max(1, math.floor(tonumber(a) or 20))) return "bench logged"
    elseif sub == "inset" then
        local f = tonumber(a)
        if f == nil or f < 0 or f >= 0.5 then return "usage: sfCd15Probe inset <fraction 0..0.5 of a fruit pixel>" end
        P.state.insetFraction = f return "inset fraction " .. tostring(f)
    elseif sub == "report" then return P.report()
    elseif sub == "reset" then return P.reset()
    end
    return "sfCd15Probe planes | here | cell <gx> <gz> | at <x> <z> | area <x1> <z1> <x2> <z2> | hooks on|off | bench <n> | inset <f> | report | reset"
end

function consoleCd15Probe(sub, a, b, c, d)
    local ok, result = pcall(P.console, sub, a, b, c, d)
    if not ok then return "[CD15 probe] error: " .. tostring(result) end
    return result
end

if addConsoleCommand ~= nil and not P._commandRegistered then
    P._commandRegistered = true
    addConsoleCommand("sfCd15Probe", "CD-15 native cell probe (read-only logging): planes | here | cell | at | area | hooks on|off | bench | inset | report | reset", "consoleCd15Probe", nil)
end
