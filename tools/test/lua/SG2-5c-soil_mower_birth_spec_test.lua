-- SG2-5c-soil_mower_birth_spec_test.lua
--
-- SG2-5 slice 5c-soil (Bob's 5c ruling of 2026-10-02; SG-2 v2.3 :351, GCC v1.5 section 4 :68
-- and :74, :106 read through :129): Soil's half of StockGuard framing the Mower.
--   * A drop's contribution may be a BIRTH, { litres, birth = { kind = "MOWER", fillTypeIndex } }.
--     Soil makes it at the deposit as its own mower carrier does: age raw 1, the fresh-grass
--     profile (FRESH_GRASS_V1, raw 204) with its id, revision and provenance on GRASS_WINDROW,
--     unknown wetness on any other output, unknown for a kind Soil makes no birth for
--     (GroundConditionAdmission.birthPart).
--   * A settle report may name PENDING FRESH litres per part (outcomeEvidence pendingFresh), and
--     Soil's combine leaves them out of its floor and its coverage (GroundConditionProperty).
--   * A MOWER_CUT admission (the work area's footprint, admitted before the native cut and closed
--     in its finally) stands Soil's cut frame aside: before the call when StockGuard's bracket is
--     outside Soil's (hasLiveLeaseFor), after it when inside (mowerCutAdmittedSince). It derives
--     no cells and marks none.
--
-- THE ENTRY-POINT BAR IS GROUP E, TWO-SIDED. Production's world: SoilFertilitySystem.new, the
-- ground family armed in production's order, the property registered, HookManager:installAll on
-- a mower the engine builds, WorkArea's order through ENGINE.tick. The same pass runs through
-- Soil alone and with a StockGuard stand-in framing the mower as Bob's 5c ruling shapes it, in
-- both wrap orders, and the deposit must read the same. The stand-in is NOT StockGuard's code
-- (StockGuard 5c is unbuilt). It reaches Soil only through what production publishes:
--   * the admission table, read through SoilFertilityManager.getCapabilities at revision 2;
--   * each line admitted at the engine global inside Soil's wrap of the util, as SG2-4 does;
--   * each ground pixel's record captured through Soil's own registered resolveResident;
--   * the buffer settled through Soil's own registered combine, with SG-1's arguments: a BIRTH
--     slot portion with no properties, one TRANSFER per pixel, the remainder as destinationBefore
--     (SGOperations.lua:1030-1065, :1110-1126), and the evidence naming the pending fresh litres;
--   * each drop split by the buffer's fresh fraction into a birth and the stock's record.
-- Nothing is hand-written into a cell, an account or a record. Two controls show the bar can
-- fail: without the pending evidence, or with the fresh share dropped as record-less litres, the
-- StockGuard side deposits unknown.
--
-- NOT RUN, and why:
--   - A birth whose profile cannot be encoded (MaterialWetness.pctToRaw absent): the ground family
--     arms only with MaterialWetness loaded, and Soil's own carrier already warns of it.
--   - StockGuard's SG-1 settle itself: StockGuard 5c's bench and its joined run carry it.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/GroundConditionProperty.lua, src/SoilFertilityManager.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG25CS_BENCH()
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local FT = ENGINE.FT
local GRASS = ENGINE.FRUIT.GRASS
local A, C = GroundConditionAdmission, GroundMovementCarrier
local PID = "soil.groundCondition"

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
--- A quantity as text, with no integer/float spelling.
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
local function lines(list, needle)
    local n = 0
    for _, line in ipairs(list) do if line:find(needle, 1, true) then n = n + 1 end end
    return n
end
--- The REAL global table, where the engine's util resolves addDensityMapHeightAtWorldLine
--- (RSF-F208-s3c, group D): under the mod's environment an assignment lands in the mod's table.
local function realGlobals()
    local mt = getmetatable(_G)
    return (mt ~= nil and mt.__index) or _G
end
local G = realGlobals()
local NATIVE_SLOT = G.addDensityMapHeightAtWorldLine

-- ── the world, armed as production arms it (the RSF-F212 world, with the property) ──
local PRISTINE = {
    mowerStart = Mower.onStartWorkAreaProcessing, mowerEnd = Mower.onEndWorkAreaProcessing,
    combineStart = Combine.onStartWorkAreaProcessing, combineEnd = Combine.onEndWorkAreaProcessing,
    tedderStart = Tedder.onStartWorkAreaProcessing, tedderEnd = Tedder.onEndWorkAreaProcessing,
    windrowerStart = Windrower.onStartWorkAreaProcessing, windrowerEnd = Windrower.onEndWorkAreaProcessing,
}
local W = {}
local function world(today)
    HEIGHT.pixels = {}
    ENGINE.mowable = {}
    G.addDensityMapHeightAtWorldLine = NATIVE_SLOT
    Mower.onStartWorkAreaProcessing, Mower.onEndWorkAreaProcessing = PRISTINE.mowerStart, PRISTINE.mowerEnd
    Combine.onStartWorkAreaProcessing, Combine.onEndWorkAreaProcessing = PRISTINE.combineStart, PRISTINE.combineEnd
    Tedder.onStartWorkAreaProcessing, Tedder.onEndWorkAreaProcessing = PRISTINE.tedderStart, PRISTINE.tedderEnd
    Windrower.onStartWorkAreaProcessing, Windrower.onEndWorkAreaProcessing = PRISTINE.windrowerStart, PRISTINE.windrowerEnd
    INFO, WARN = {}, {}
    C.firstPassLogged, C.firstBirthLogged, A.firstBirthLogged = {}, {}, {}
    g_densityMapHeightManager.valid = true
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = ENGINE.newVehicleSystem() }
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    sys.hookManager.getFieldIdAtWorldPosition = function() return 7 end
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    -- The property registers on the armed coordinator as initialize registers it, through a
    -- handle that keeps the spec (StockGuard's registry would).
    W.spec = nil
    local handle = {
        registerProperty = function(_id, spec) W.spec = spec return { leaseId = "1:1" } end,
        unregisterOwner = function() return true end,
    }
    local d = c and sys.groundConditionProperty:register(sys.groundConditionCoordinator, { stockGuard = handle })
    return (a and b and c and d) and true or false
end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return ENGINE.layerGet(W.age, gx, gz) .. "/" .. ENGINE.layerGet(W.wet, gx, gz) end
--- The drop line's two cells, (8,9) and (9,9).
local function landed() return condition(8, 9) .. " " .. condition(9, 9) end
--- A new day, as the owners' own ticks leave it.
local function day(n)
    g_currentMission.environment.currentMonotonicDay = n
    W.sys.materialDown.ageAppliedThroughDay = n
    W.sys.materialWetness.appliedThroughDay = n
    W.sys.groundConditionCoordinator:invalidateBarrier()
end
local function installAll()
    local ok = pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys)
    return ok
end
--- A mower in the mission's vehicle list: its cut strip x 0..8*areas, z 0..2, its drop line at
--- z = 6 (cells (8,9) and (9,9)).
local function mowerInWorld(opts)
    opts = opts or {}
    local v, mowers, drop = ENGINE.newMower({ uid = opts.uid or "mower", x0 = opts.x0 or 0, z0 = 0, width = 8, depth = 2,
        dropZ = 6, areas = opts.areas, outputFillType = opts.outputFillType })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, mowers, drop
end
--- An old dry windrow under the first cut strip: 400 L over cells (8,8) and (9,8).
local function oldWindrow(ageRaw, wetRaw)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 25)
    setCell(8, 8, ageRaw, wetRaw)
    setCell(9, 8, ageRaw, wetRaw)
end
--- The drop line full (nothing can land) or free.
local function fullLine() HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 400) end
local function freeLine() HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 0) end
local function onLine(ft) return DensityMapHeightUtil.getFillLevelAtArea(ft, 0, 6, 8, 6, 0, 7) end

--- The published table, as StockGuard binds it (SGSoilCondition.receiver): the revision through
--- the manager's getCapabilities, the calls through its `groundCondition` field. Nil when either fails.
local function gc()
    local sfm = { soilSystem = W.sys, getCapabilities = SoilFertilityManager.getCapabilities,
                  groundCondition = W.sys.groundConditionAdmission.groundCondition }
    local caps = sfm:getCapabilities()
    if type(caps.groundCondition) ~= "table" or caps.groundCondition.admissionRevision ~= 2 then return nil end
    local published = sfm.groundCondition
    if type(published) ~= "table" or type(published.admitPrimitive) ~= "function" then return nil end
    return published
end
local function lineFP(sx, sz, ex, ez, ft, inner, radius)
    return { schemaVersion = 1, kind = "LINE", sx = sx, sz = sz, ex = ex, ez = ez, fillTypeIndex = ft, innerRadius = inner, radius = radius }
end
--- A mower work area's footprint: its start, width and height corners, read as the engine reads them.
local function areaFP(wa)
    local xs, _, zs = getWorldTranslation(wa.start)
    local xw, _, zw = getWorldTranslation(wa.width)
    local xh, _, zh = getWorldTranslation(wa.height)
    return { schemaVersion = 1, kind = "AREA", x0 = xs, z0 = zs, x1 = xw, z1 = zw, x2 = xh, z2 = zh }
end
--- The record a pixel's material carries off the ground: Soil's own property resolves it, as
--- SG-1's capture does before the native pickup.
local function carried(x, z, litres)
    return W.spec.resolveResident({ purpose = "CAPTURE", amount = litres, unit = "LITRE",
        footprint = { kind = "GROUND_CELL", x = x, z = z, size = ENGINE.PIXEL } })
end
--- The contributions production hands the coordinator's combine, recorded where the projector
--- calls it. Restored by the returned function.
local function recordCombine()
    local real = GroundConditionCoordinator.combine
    local seen = {}
    GroundConditionCoordinator.combine = function(destination, contributions)
        for _, c in ipairs(contributions or {}) do seen[#seen + 1] = c end
        return real(destination, contributions)
    end
    return seen, function() GroundConditionCoordinator.combine = real end
end
--- The distinct "profile/revision/provenance" stamps among recorded contributions.
local function stamps(seen)
    local out, have = {}, {}
    for _, c in ipairs(seen) do
        local s = tostring(c.profile or "-") .. "/" .. tostring(c.revision or "-") .. "/" .. tostring(c.provenance or "-")
        if not have[s] then have[s] = true; out[#out + 1] = s end
    end
    table.sort(out)
    return table.concat(out, " ")
end

-- ══════════════════════════════════════════════════════════════════════════
-- THE STOCKGUARD STAND-IN (StockGuard 5c's half, as Bob's 5c ruling shapes it; header)
-- ══════════════════════════════════════════════════════════════════════════
local SG = {}
local function sgReset()
    SG.frame, SG.buffers = nil, setmetatable({}, { __mode = "k" })
    SG.cuts = { admitted = 0, refused = 0 }
    SG.lines = { admitted = 0, delivered = 0 }
    SG.noPending, SG.noBirth = false, false
end
sgReset()
--- The buffer StockGuard keeps for a drop area: the native amount, the fresh litres counted from
--- admitted cuts, and the stock's soil.groundCondition record (nil: none).
local function sgBuffer(dropArea)
    local b = SG.buffers[dropArea]
    if b == nil then b = { amount = 0, fresh = 0, record = nil } SG.buffers[dropArea] = b end
    return b
end
local function pixelOf(key)
    local px, pz = key:match("^(-?%d+):(-?%d+)$")
    return tonumber(px), tonumber(pz)
end
--- Every ground pixel holding `ft`, with the record Soil resolves for it, before the native call.
local function sgCapture(ft)
    local out = {}
    for key, litres in pairs(HEIGHT.pixels[ft] or {}) do
        if litres > 0 then
            local px, pz = pixelOf(key)
            out[key] = { litres = litres, record = carried((px + 0.5) * ENGINE.PIXEL, (pz + 0.5) * ENGINE.PIXEL, litres) }
        end
    end
    return out
end
--- A drop's contributions: the buffer's uniform fresh fraction as a birth, the rest as its record.
local function sgSplit(buf, placed, ft)
    local frac = buf.amount > 0 and math.min(1, buf.fresh / buf.amount) or 0
    local fresh = placed * frac
    if SG.noBirth then
        return { { litres = fresh }, { litres = placed - fresh, record = buf.record } }
    end
    return { { litres = fresh, birth = { kind = "MOWER", fillTypeIndex = ft } }, { litres = placed - fresh, record = buf.record } }
end
--- The engine global inside Soil's wrap of the util (SG2-4's admission point): admit, capture,
--- the native slot, deliver, close.
local function sgSlot(updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts)
    local f = SG.frame
    local t = gc()
    if f == nil or t == nil then return NATIVE_SLOT(updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts) end
    local lease = t.admitPrimitive(lineFP(sx, sz, ex, ez, ft, inner, radius), A.KIND_TIP_LINE, f.owner, f.identity)
    local admitted = lease.status == "ADMITTED"
    if admitted then SG.lines.admitted = SG.lines.admitted + 1 end
    local captured = delta < 0 and sgCapture(ft) or nil
    local okN, moved, off2 = pcall(NATIVE_SLOT, updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts)
    local obs = { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = okN, fillTypeIndex = ft, deltaRequested = delta,
                  litresReturned = okN and moved or nil, lineOffset = okN and off2 or nil }
    if okN and captured ~= nil then
        local keys = {}
        for key in pairs(captured) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local px, pz = pixelOf(key)
            local lost = captured[key].litres - HEIGHT.get(ft, px, pz)
            if lost > 0 then f.picks[#f.picks + 1] = { litres = lost, record = captured[key].record } end
        end
    elseif okN and delta > 0 and moved > 0 then
        obs.contributions = sgSplit(f.buffer, moved, ft)
    end
    if admitted then
        t.deliverMovement(lease.leaseToken, obs)
        SG.lines.delivered = SG.lines.delivered + 1
        t.closePrimitive(lease.leaseToken)
    end
    if not okN then error(moved, 0) end
    return moved, off2
end
--- The cut's settle into the buffer, as SG-1 hands Soil's combine its arguments; then the cap,
--- a loss from the now-uniform mixture (Mower.lua:366-367).
local function sgSettleCut(buf, dropArea, fresh, picks, admitted)
    local total = buf.amount + fresh
    for _, p in ipairs(picks) do total = total + p.litres end
    if fresh > 0 or #picks > 0 then
        local contributions, alloc, any = {}, {}, buf.record ~= nil
        if fresh > 0 then
            contributions[1] = { allocationRef = "cut:a1", amount = fresh, unit = "LITRE", properties = {} }
            if admitted and not SG.noPending then alloc[1] = { allocation = 1, litres = fresh } end
        end
        for _, p in ipairs(picks) do
            local props = {}
            if p.record ~= nil then props[PID] = p.record any = true end
            contributions[#contributions + 1] = { allocationRef = "cut:a" .. tostring(#contributions + 1), amount = p.litres, unit = "LITRE", properties = props }
        end
        -- SG-1 consults an owner only for a property already present (interpretDestination :741-748).
        if any then
            local before = nil
            if buf.amount > 0 then
                before = { observedAmount = buf.amount, amountUnit = "LITRE", properties = { [PID] = buf.record } }
            end
            local pending = { allocations = alloc }
            if buf.fresh > 0 and not SG.noPending then pending.destinationBefore = buf.fresh end
            buf.record = W.spec.combine({ operationId = "cut", report = { outcomeEvidence = { [PID] = { pendingFresh = pending } } } },
                contributions, before)
        end
        if admitted then buf.fresh = buf.fresh + fresh end
    end
    local after = tonumber(dropArea.litersToDrop) or 0
    if total > 0 then buf.fresh = buf.fresh * math.min(1, after / total) end
    buf.amount = after
end
--- The bracket on the captured processMowerArea pointer: the MOWER_CUT admitted before the call
--- and closed in its finally.
local function sgCut(real, mower, workArea, dt)
    local dropArea = mower:getDropArea(workArea)
    local t = gc()
    local lease = t ~= nil and t.admitPrimitive(areaFP(workArea), A.KIND_MOWER_CUT, mower, workArea) or { status = "REFUSED" }
    local admitted = lease.status == "ADMITTED"
    if admitted then SG.cuts.admitted = SG.cuts.admitted + 1 else SG.cuts.refused = SG.cuts.refused + 1 end
    local buf = dropArea ~= nil and sgBuffer(dropArea) or nil
    local before = tonumber(workArea.pickedUpLiters) or 0
    local prev, frame = SG.frame, { owner = mower, identity = workArea, picks = {}, buffer = buf }
    SG.frame = frame
    local ok, xs, total = pcall(real, mower, workArea, dt)
    SG.frame = prev
    if admitted then t.closePrimitive(lease.leaseToken) end
    if not ok then error(xs, 0) end
    if buf ~= nil then sgSettleCut(buf, dropArea, (tonumber(workArea.pickedUpLiters) or 0) - before, frame.picks, admitted) end
    return xs, total
end
--- The bracket on the instance processDropArea: the drop's line is admitted at the slot.
local function sgDrop(real, mower, dropArea, dt)
    local buf = sgBuffer(dropArea)
    local before = tonumber(dropArea.litersToDrop) or 0
    local prev = SG.frame
    SG.frame = { owner = mower, identity = dropArea, picks = {}, buffer = buf }
    local ok, err = pcall(real, mower, dropArea, dt)
    SG.frame = prev
    if not ok then error(err, 0) end
    local after = tonumber(dropArea.litersToDrop) or 0
    if before > 0 then buf.fresh = buf.fresh * math.min(1, after / before) end
    buf.amount = after
end
local function sgInstall(v, mowers)
    for _, wa in ipairs(mowers) do
        local real = wa.processingFunction
        wa.processingFunction = function(self, workArea, dt) return sgCut(real, self, workArea, dt) end
    end
    local realDrop = rawget(v, "processDropArea")
    v.processDropArea = function(self, dropArea, dt) return sgDrop(realDrop, self, dropArea, dt) end
    G.addDensityMapHeightAtWorldLine = sgSlot
end
--- One side's mower: "soil" alone; "sgOuter", StockGuard's brackets installed after Soil's (outside
--- them); "sgInner", installed first, so Soil wraps the cut outside StockGuard's (Soil leaves a
--- foreign processDropArea alone, HookManager wrapDrop).
local function mowerFor(side, opts)
    sgReset()
    local v, mowers, drop = mowerInWorld(opts)
    if side == "sgInner" then sgInstall(v, mowers) end
    local okAll = installAll()
    if side == "sgOuter" then sgInstall(v, mowers) end
    return v, mowers, drop, okAll
end
local SIDES = { "soil", "sgOuter", "sgInner" }

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: one pass, Soil alone and under StockGuard's frames
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local r = {}
    for _, side in ipairs(SIDES) do
        local armed = world(100)
        local v, _, drop, okAll = mowerFor(side, { uid = side })
        ENGINE.mowable[GRASS] = 400
        oldWindrow(5, 100)
        local births0, skipped0 = C.stats.births, C.stats.skippedLease
        ENGINE.tick(v, 16)
        r[side] = {
            armed = armed and okAll, placed = num(onLine(FT.GRASS_WINDROW)) .. "/" .. num(drop.litersToDrop), landed = landed(),
            births = C.stats.births - births0, skipped = C.stats.skippedLease - skipped0,
            firstMower = lines(INFO, "FIRST MOWER PASS OBSERVED"), firstFresh = lines(INFO, "FIRST FRESH GRASS_WINDROW BIRTH: "),
            admittedLine = lines(INFO, "FIRST FRESH GRASS_WINDROW BIRTH ON AN ADMITTED DROP: 400.0 L born at the deposit with profile FRESH_GRASS_V1 revision 1 (80% wet basis, raw 204)"),
            generic = #W.sys.materialDown.births, cuts = SG.cuts.admitted, lines = SG.lines.admitted .. "/" .. SG.lines.delivered,
        }
    end
    T.ok("E0 [world] each side arms in production's order and installAll ran",
        r.soil.armed and r.sgOuter.armed and r.sgInner.armed)
    T.eq("E1 [native] each side's pass landed the old 400 L and the fresh 400 L on the line and emptied the drop area",
        r.soil.placed .. " " .. r.sgOuter.placed .. " " .. r.sgInner.placed, "800/0 800/0 800/0")
    T.eq("E2 [reached] under StockGuard the cut was admitted and both lines (the dry pickup, the drop) were admitted and delivered, in either wrap order",
        r.sgOuter.cuts .. ":" .. r.sgOuter.lines .. " " .. r.sgInner.cuts .. ":" .. r.sgInner.lines, "1:2/2 1:2/2")
    T.eq("E3 Soil alone: the old windrow's age (5) and the fresh profile's band (204), as RSF-F212 O2", r.soil.landed, "5/204 5/204")
    T.eq("E4 [entry point] StockGuard's frames outside Soil's: the same deposit", r.sgOuter.landed, r.soil.landed)
    T.eq("E5 [entry point] StockGuard's cut bracket inside Soil's cut frame (the reverse wrap order): the same deposit", r.sgInner.landed, r.soil.landed)
    T.eq("E6 Soil alone made the birth and logged FIRST MOWER; under StockGuard, in either order, Soil's cut frame made no birth, FIRST MOWER and the carrier's birth line never printed, the admitted drop's birth line printed once, and the generic birth never ran (births/skipped/firstMower/firstFresh/admitted/generic)",
        table.concat({ r.soil.births, r.soil.skipped, r.soil.firstMower, r.soil.firstFresh, r.soil.admittedLine, r.soil.generic }, "/") .. " " ..
        table.concat({ r.sgOuter.births, r.sgOuter.skipped, r.sgOuter.firstMower, r.sgOuter.firstFresh, r.sgOuter.admittedLine, r.sgOuter.generic }, "/") .. " " ..
        table.concat({ r.sgInner.births, r.sgInner.skipped, r.sgInner.firstMower, r.sgInner.firstFresh, r.sgInner.admittedLine, r.sgInner.generic }, "/"),
        "1/0/1/1/0/0 0/1/0/0/1/0 0/1/0/0/1/0")

    -- A pass held in the buffer across a day boundary still deposits the fresh share at age raw 1.
    local held, pure = {}, {}
    for _, side in ipairs(SIDES) do
        world(100)
        local v, _, drop = mowerFor(side, { uid = side .. "Held" })
        ENGINE.mowable[GRASS] = 400
        oldWindrow(5, 100)
        fullLine()
        ENGINE.tick(v, 16)
        local waiting = num(drop.litersToDrop)
        day(101)
        freeLine()
        ENGINE.mowable[GRASS] = 0
        ENGINE.tick(v, 16)
        held[side] = waiting .. ":" .. num(onLine(FT.GRASS_WINDROW)) .. ":" .. landed()

        world(100)
        local v2, _, drop2 = mowerFor(side, { uid = side .. "Pure" })
        ENGINE.mowable[GRASS] = 400
        fullLine()
        ENGINE.tick(v2, 16)
        local waiting2 = num(drop2.litersToDrop)
        day(103)
        freeLine()
        ENGINE.mowable[GRASS] = 0
        ENGINE.tick(v2, 16)
        pure[side] = waiting2 .. ":" .. num(onLine(FT.GRASS_WINDROW)) .. ":" .. landed()
    end
    T.eq("E7 Soil alone, a cut over the old windrow held over one night: the old windrow aged one day (6), the fresh share born at the deposit",
        held.soil, "800:800:6/204 6/204")
    T.eq("E8 [entry point] under StockGuard, in either order, the same", held.sgOuter .. " " .. held.sgInner, held.soil .. " " .. held.soil)
    T.eq("E9 a pure fresh cut held over three nights lands at age raw 1 through Soil alone and through StockGuard in either order",
        pure.soil .. " " .. pure.sgOuter .. " " .. pure.sgInner, "400:400:1/204 1/204 400:400:1/204 1/204 400:400:1/204 1/204")

    -- The bar can fail: each control removes one of this slice's pieces from the StockGuard side.
    world(100)
    local v3 = mowerFor("sgOuter", { uid = "noPending" })
    SG.noPending = true
    ENGINE.mowable[GRASS] = 400
    oldWindrow(5, 100)
    ENGINE.tick(v3, 16)
    T.eq("E10 [control] without the pending evidence the buffer's BIRTH slot reads as unknown (SG-1 gives it no record) and the deposit is unknown",
        landed(), "0/24 0/24")
    world(100)
    local v4 = mowerFor("sgOuter", { uid = "noBirth" })
    SG.noBirth = true
    ENGINE.mowable[GRASS] = 400
    oldWindrow(5, 100)
    ENGINE.tick(v4, 16)
    T.eq("E11 [control] with the fresh share dropped as record-less litres, not as a birth, the deposit is unknown", landed(), "0/24 0/24")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE MOWER_CUT KIND
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    world(100)
    local v, mowers, drop = mowerInWorld({ uid = "kind" })
    local adm = W.sys.groundConditionAdmission
    local t = gc()
    setCell(8, 8, 5, 100)
    local count0, open0 = adm:admissionCount(), adm:getOpenLeaseCount()
    local lease = t.admitPrimitive(areaFP(mowers[1]), A.KIND_MOWER_CUT, v, mowers[1])
    T.eq("K1 a mower's cut over its work area is admitted, counted and open; it is live for that work area and no other",
        tostring(lease.status) .. "/" .. (adm:admissionCount() - count0) .. "/" .. (adm:getOpenLeaseCount() - open0) .. "/" ..
        tostring(adm:hasLiveLeaseFor(v, mowers[1])) .. "/" .. tostring(adm:hasLiveLeaseFor(v, drop)), "ADMITTED/1/1/true/false")
    local function said(out) return tostring(out.status) .. ":" .. tostring(out.reason) .. ":" .. tostring(out.projected) .. ":" .. tostring(out.unavailable) end
    local d1 = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_MOWER_CUT, ok = true })
    local d2 = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_MOWER_CUT, ok = false })
    T.eq("K2 a delivery carries nothing for the ground, whether the cut returned or raised", said(d1) .. " " .. said(d2), "ADMITTED:OK:0:0 ADMITTED:OK:0:0")
    local d3 = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = true })
    local d4 = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_MOWER_CUT })
    T.eq("K3 an observation of another kind, or without ok, is a bad observation", d3.reason .. " " .. d4.reason, A.DELIVER_BAD_OBS .. " " .. A.DELIVER_BAD_OBS)
    local closed = t.closePrimitive(lease.leaseToken)
    T.eq("K4 the close marks nothing: the known cell under the work area keeps its record and is not unavailable, and the lease is gone",
        tostring(closed.unavailable) .. "/" .. condition(8, 8) .. "/" .. tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)) .. "/" ..
        tostring(adm:hasLiveLeaseFor(v, mowers[1])) .. "/" .. (adm:getOpenLeaseCount() - open0), "0/5/100/false/false/0")
    local quiet = t.admitPrimitive(areaFP(mowers[1]), A.KIND_MOWER_CUT, v, mowers[1])
    local quietClosed = t.closePrimitive(quiet.leaseToken)
    T.eq("K5 a cut closed with no delivery at all marks nothing either", tostring(quietClosed.unavailable) .. "/" .. tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)), "0/false")
    local clear = t.admitPrimitive(areaFP(mowers[1]), A.KIND_CLEAR_AREA, v, "sg-clear")
    t.closePrimitive(clear.leaseToken)
    T.eq("K6 [control] a CLEAR_AREA lease over the same footprint, closed undelivered, does mark that cell unavailable", tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)), "true")

    world(100)
    local v2, mowers2 = mowerInWorld({ uid = "refusals" })
    adm, t = W.sys.groundConditionAdmission, gc()
    local before = adm:admissionCount()
    local function reason(fp, owner, identity) return tostring(t.admitPrimitive(fp, A.KIND_MOWER_CUT, owner, identity).reason) end
    T.eq("K7 refused: a LINE footprint, an owner that is not a mower, an identity that is not a work area table, no identity; nothing counted",
        table.concat({ reason(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), v2, mowers2[1]), reason(areaFP(mowers2[1]), { isServer = true }, mowers2[1]),
            reason(areaFP(mowers2[1]), v2, "area1"), reason(areaFP(mowers2[1]), v2, nil) }, "/") .. "/" .. (adm:admissionCount() - before),
        table.concat({ A.REFUSE_ARGS, A.REFUSE_ARGS, A.REFUSE_ARGS, A.REFUSE_ARGS }, "/") .. "/0")

    local stale = t.admitPrimitive(areaFP(mowers2[1]), A.KIND_MOWER_CUT, v2, mowers2[1])
    setCell(8, 8, 5, 100)
    ENGINE.setFrameIndex(g_updateLoopIndex + 1)
    T.eq("K8 a cut left open past its frame is not live, leaves the table and marks nothing",
        tostring(stale.status) .. "/" .. tostring(adm:hasLiveLeaseFor(v2, mowers2[1])) .. "/" .. adm:getOpenLeaseCount() .. "/" ..
        tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)), "ADMITTED/false/0/false")

    -- Under a refused barrier: no lease, so Soil's own cut frame runs and makes the output explicit
    -- unknown (RSF-F212 B), and StockGuard counts no fresh: the two sides agree.
    local refused = {}
    for _, side in ipairs({ "soil", "sgOuter" }) do
        world(100)
        local v3, _, drop3 = mowerFor(side, { uid = side .. "Refused" })
        ENGINE.mowable[GRASS] = 400
        fullLine()
        g_currentMission.environment.currentMonotonicDay = 101
        W.sys.materialWetness.hold = true
        local count = W.sys.groundConditionAdmission:admissionCount()
        ENGINE.tick(v3, 16)
        local admittedDuring = W.sys.groundConditionAdmission:admissionCount() - count
        W.sys.materialWetness.hold = false
        freeLine()
        ENGINE.mowable[GRASS] = 0
        ENGINE.tick(v3, 16)
        refused[side] = admittedDuring .. ":" .. SG.cuts.refused .. ":" .. num(drop3.litersToDrop) .. ":" .. landed()
    end
    T.eq("K9 a cut under a refused barrier is refused (nothing admitted that frame); its output lands unknown through Soil alone and through StockGuard",
        refused.soil .. " " .. refused.sgOuter, "0:0:0:0/24 0/24 0:1:0:0/24 0/24")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. STANDING ASIDE FROM INSIDE: mowerCutAdmittedSince
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    world(100)
    local v, mowers = mowerInWorld({ uid = "z", areas = 2 })
    local other = mowerInWorld({ uid = "zOther", x0 = 40 })
    local adm, t = W.sys.groundConditionAdmission, gc()
    local count = adm:admissionCount()
    t.closePrimitive(t.admitPrimitive(areaFP(mowers[2]), A.KIND_MOWER_CUT, v, mowers[2]).leaseToken)
    T.eq("Z1 a cut admitted for another work area of the same mower does not count for this one", tostring(adm:mowerCutAdmittedSince(v, mowers[1], count)), "false")
    t.closePrimitive(t.admitPrimitive(areaFP(mowers[1]), A.KIND_MOWER_CUT, other, mowers[1]).leaseToken)
    T.eq("Z2 a cut another mower admitted naming this work area does not count for this mower", tostring(adm:mowerCutAdmittedSince(v, mowers[1], count)), "false")
    t.closePrimitive(t.admitPrimitive(areaFP(mowers[1]), A.KIND_MOWER_CUT, v, mowers[1]).leaseToken)
    T.eq("Z3 this mower's cut for this work area, admitted after the count, counts, and still does once its lease has closed",
        tostring(adm:mowerCutAdmittedSince(v, mowers[1], count)), "true")
    T.eq("Z4 a cut admitted before the count does not; an identity no cut named never does",
        tostring(adm:mowerCutAdmittedSince(v, mowers[1], adm:admissionCount())) .. "/" .. tostring(adm:mowerCutAdmittedSince(v, "area", count)), "false/false")

    -- Through the tick: StockGuard's bracket inside Soil's names the wrong work area, so Soil's frame
    -- must still make its own birth.
    world(100)
    local v2, mowers2 = mowerFor("sgInner", { uid = "zWrong", areas = 2 })
    local real = gc().admitPrimitive
    W.sys.groundConditionAdmission.groundCondition.admitPrimitive = function(fp, kind, owner, identity)
        if kind == A.KIND_MOWER_CUT then identity = identity == mowers2[1] and mowers2[2] or mowers2[1] end
        return real(fp, kind, owner, identity)
    end
    ENGINE.mowable[GRASS] = 400
    local births0 = C.stats.births
    ENGINE.tick(v2, 16)
    W.sys.groundConditionAdmission.groundCondition.admitPrimitive = real
    T.eq("Z5 [control] a cut admitted inside Soil's frame for the other work area does not stand that frame aside: both areas' frames made their births",
        C.stats.births - births0, 2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A BIRTH CONTRIBUTION AT AN ADMITTED DROP
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local MOWER = { isServer = true, uniqueId = "sg-mower", spec_mower = {} }
    --- admit, the real primitive, deliver (with the caller's contributions), close.
    local function drop(ft, contributions)
        local t = gc()
        local lease = t.admitPrimitive(lineFP(0, 6.5, 8, 6.5, ft, 0.5, 1), A.KIND_TIP_LINE, MOWER, "drop")
        if lease.status ~= "ADMITTED" then return tostring(lease.reason) end
        local okN, litres, off = pcall(DensityMapHeightUtil.tipToGroundAroundLine, MOWER, 800, ft, 0, 0, 6.5, 8, 0, 6.5, 0.5, 1, 0, false, nil)
        local out = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = okN, fillTypeIndex = ft,
            deltaRequested = 800, litresReturned = okN and litres or nil, lineOffset = okN and off or nil, contributions = contributions })
        t.closePrimitive(lease.leaseToken)
        return tostring(out.reason)
    end
    local function born(litres, kind, ft) return { litres = litres, birth = { kind = kind or "MOWER", fillTypeIndex = ft or FT.GRASS_WINDROW } } end

    world(100)
    local seen, restore = recordCombine()
    local said = drop(FT.GRASS_WINDROW, { born(800) })
    restore()
    T.eq("B1 a mower birth lands born at the deposit with the fresh-grass profile: age raw 1, raw 204", said .. " " .. landed(), "OK 1/204 1/204")
    T.eq("B2 its contributions carry FRESH_GRASS_V1, revision 1, ESTIMATED_AT_BIRTH, and the first such birth says so once", stamps(seen) .. " " ..
        lines(INFO, "FIRST FRESH GRASS_WINDROW BIRTH ON AN ADMITTED DROP: 800.0 L born at the deposit with profile FRESH_GRASS_V1 revision 1 (80% wet basis, raw 204), provenance estimated-at-birth"),
        "FRESH_GRASS_V1/1/ESTIMATED_AT_BIRTH 1")
    drop(FT.GRASS_WINDROW, { born(800) })
    T.eq("B3 a second birth does not repeat the line", lines(INFO, "BIRTH ON AN ADMITTED DROP"), 1)

    world(100)
    day(105)
    drop(FT.GRASS_WINDROW, { born(800) })
    T.eq("B4 a birth has no stamp to age: delivered on a later day it is still age raw 1", landed(), "1/204 1/204")

    world(100)
    local seenHay, restoreHay = recordCombine()
    drop(FT.DRYGRASS_WINDROW, { born(800, "MOWER", FT.DRYGRASS_WINDROW) })
    restoreHay()
    T.eq("B5 a mower birth of another output (a converter that makes hay) is born today with unknown wetness and no profile, as RSF-F212 H2-H3",
        landed() .. " " .. stamps(seenHay), "1/24 1/24 -/-/-")

    world(100)
    drop(FT.GRASS_WINDROW, { born(800, "TEDDER") })
    T.eq("B6 a birth of a kind Soil makes no birth for is unknown", landed(), "0/24 0/24")

    world(100)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 25)
    setCell(8, 8, 5, 100)
    local known = carried(2.5, 1.5, 400)
    drop(FT.GRASS_WINDROW, { born(400), { litres = 400, record = known } })
    T.eq("B7 a birth with a known record takes the floor: the record's age (5), the profile's band (204), as RSF-F212 O2", landed(), "5/204 5/204")
    world(100)
    drop(FT.GRASS_WINDROW, { born(400), { litres = 400 } })
    T.eq("B8 a birth with positive record-less litres lands unknown", landed(), "0/24 0/24")
    world(100)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 25)
    setCell(8, 8, 5, 100)
    local known2 = carried(2.5, 1.5, 800)
    drop(FT.GRASS_WINDROW, { born(0), { litres = 800, record = known2 } })
    T.eq("B9 a zero-litre birth imports nothing", landed(), "5/100 5/100")

    world(100)
    local function bad(c) return drop(FT.GRASS_WINDROW, { c }) end
    T.eq("B10 a malformed birth is a bad observation: not a table, a kind that is not a string, no fill type, a record beside it",
        table.concat({ bad({ litres = 800, birth = "MOWER" }), bad({ litres = 800, birth = { kind = 1, fillTypeIndex = FT.GRASS_WINDROW } }),
            bad({ litres = 800, birth = { kind = "MOWER" } }), bad({ litres = 800, record = known, birth = { kind = "MOWER", fillTypeIndex = FT.GRASS_WINDROW } }) }, "/"),
        table.concat({ A.DELIVER_BAD_OBS, A.DELIVER_BAD_OBS, A.DELIVER_BAD_OBS, A.DELIVER_BAD_OBS }, "/"))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. PENDING FRESH LITRES IN THE COMBINE
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    world(100)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 25)
    setCell(8, 8, 5, 100)
    local known = carried(2.5, 1.5, 400)
    T.eq("P0 [world] Soil's own record of the dry grass: KNOWN 5/100 day 100 over 400 L",
        known.knowledge .. "/" .. known.payload.ageRaw .. "/" .. known.payload.wetnessRaw .. "/" .. known.payload.ageDay .. "/" .. num(known.basisAmount), "KNOWN/5/100/100/400")
    local function settle(contributions, before, pending, other)
        local mine = {}
        if pending ~= nil then mine.pendingFresh = pending end
        local evidence = { [other or PID] = mine }
        local rec, why = W.spec.combine({ operationId = "op", report = { outcomeEvidence = evidence } }, contributions, before)
        if rec == nil then return "nil/" .. tostring(why) end
        return rec.knowledge .. "/" .. rec.payload.ageRaw .. "/" .. rec.payload.wetnessRaw .. "/" .. num(rec.basisAmount) .. "/" .. num(rec.knownAmount)
    end
    local function slot(i, litres) return { allocationRef = "op:a" .. i, amount = litres, unit = "LITRE", properties = {} } end
    local function part(i, litres, rec) return { allocationRef = "op:a" .. i, amount = litres, unit = "LITRE", properties = { [PID] = rec } } end
    local function fresh(i, litres) return { allocations = { { allocation = i, litres = litres } } } end
    local cut = { slot(1, 400), part(2, 400, known) }

    T.eq("P1 a BIRTH slot (no record) beside known dry grass: unknown without the evidence (SG-1's slot portion), the dry grass's own condition over its own 400 L with it",
        settle(cut, nil, nil) .. " " .. settle(cut, nil, fresh(1, 400)), "UNKNOWN/0/24/800/0 KNOWN/5/100/400/400")
    local allFresh = { observedAmount = 400, amountUnit = "LITRE", properties = {} }
    T.eq("P2 a buffer holding only fresh litres (no record) takes known dry grass: unknown without, known over the dry 400 L with destinationBefore named",
        settle({ part(1, 400, known) }, allFresh, nil) .. " " .. settle({ part(1, 400, known) }, allFresh, { destinationBefore = 400 }),
        "UNKNOWN/0/24/800/0 KNOWN/5/100/400/400")
    local carriedBuffer = W.spec.combine({ operationId = "op", report = { outcomeEvidence = { [PID] = { pendingFresh = fresh(1, 400) } } } }, cut, nil)
    local mixed = { observedAmount = 800, amountUnit = "LITRE", properties = { [PID] = carriedBuffer } }
    T.eq("P3 a buffer whose record covers its dry share takes another birth: both fresh shares named, the record holds over the dry 400 L",
        settle({ slot(1, 200) }, mixed, { destinationBefore = 400, allocations = { { allocation = 1, litres = 200 } } }), "KNOWN/5/100/400/400")
    T.eq("P4 a birth named for half its litres leaves the other half unknown (an unexplained output, SG-2 :517)",
        settle(cut, nil, fresh(1, 200)), "UNKNOWN/0/24/600/0")
    local unread = {}
    for _, p in ipairs({ fresh(1, -1), fresh(1, 0 / 0), fresh(1, math.huge), { allocations = { { allocation = 0, litres = 400 } } },
        { allocations = { { allocation = 1.5, litres = 400 } } }, { allocations = { { allocation = 1, litres = 400 }, { allocation = 1, litres = 400 } } },
        fresh(1, 401), { allocations = "x" }, { allocations = { "x" } } }) do
        unread[#unread + 1] = settle(cut, nil, p)
    end
    unread[#unread + 1] = settle({ part(1, 400, known) }, allFresh, { destinationBefore = -5 })
    unread[#unread + 1] = settle({ part(1, 400, known) }, allFresh, { destinationBefore = "400" })
    T.eq("P5 a figure that cannot be read names nothing: negative, NaN, infinite, allocation 0 or 1.5, named twice, more than the part, a malformed list, a bad destinationBefore",
        table.concat(unread, " "), string.rep("UNKNOWN/0/24/800/0 ", 10) .. "UNKNOWN/0/24/800/0")
    T.eq("P6 a figure within the tolerance above the part names the whole part; a residue within the tolerance imports nothing; one litre short is unknown",
        settle(cut, nil, fresh(1, 400 + 1e-7)) .. " " .. settle(cut, nil, fresh(1, 400 - 1e-7)) .. " " .. settle(cut, nil, fresh(1, 399)),
        "KNOWN/5/100/400/400 KNOWN/5/100/400/400 UNKNOWN/0/24/401/0")
    T.eq("P7 every part pending: no material to carry",
        settle({ slot(1, 400) }, { observedAmount = 400, amountUnit = "LITRE", properties = { [PID] = known } }, { destinationBefore = 400, allocations = { { allocation = 1, litres = 400 } } }),
        "nil/" .. GroundConditionProperty.NO_MATERIAL)
    T.eq("P8 no evidence, or the evidence under another property, leaves combine unchanged",
        settle(cut, nil, nil) .. " " .. settle(cut, nil, fresh(1, 400), "other.property"), "UNKNOWN/0/24/800/0 UNKNOWN/0/24/800/0")
    local acc = { carrierLitres = 300, knownCarrierLitres = 300, unknownCarrierLitres = 0, refusedCarrierLitres = 0, knownWeightedPctSum = 300 * 40 }
    local function accounted(pending)
        local evidence = { collectedAccounts = { { allocation = 1, account = acc } }, pendingFresh = pending }
        local rec = W.spec.combine({ operationId = "op", report = { outcomeEvidence = { [PID] = evidence } } }, { part(1, 400, known) }, nil)
        return num(rec.payload.account.carrierLitres) .. ":" .. num(rec.payload.account.knownCarrierLitres)
    end
    T.eq("P9 a collected account is adopted on the part's litres less its pending ones: 300 L named beside 100 L pending is adopted; without them it does not match and is unknown",
        accounted(fresh(1, 100)) .. " " .. accounted(nil), "300:300 400:0")
end)
end
SG25CS_BENCH()
