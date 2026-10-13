-- RSF-F208-s3c-lease_delivery_spec_test.lua
--
-- SG2-4 S3 (Iris's answer 2 of 2026-09-23; Bob's intake of 2026-09-23 with item 3b):
-- the StockGuard lease path delivers a NATIVE observation and Soil derives its own
-- Soil cells from the footprint, captures their condition at admit, reads their
-- whole-cell occupancy itself before and after, and projects through the one
-- projector it shares with its standalone carriers. Admission revision 2.
--
-- THE ENTRY-POINT BAR IS GROUP S. The family is built by SoilFertilitySystem.new and
-- armed in production's order; the lease is taken through the PUBLISHED groundCondition
-- table (dot calls), the real DensityMapHeightUtil primitive runs on the engine model
-- between admit and deliver exactly as StockGuard's bracket will run it, and the
-- delivery carries only what the primitive returned. Nothing here builds a cell, a
-- mixture, an occupancy or a lease record by hand.
--
-- Groups:
--   S  the entry-point bar: capability 2, a LINE pickup, a LINE drop, the close
--   Q  parity: the same tip through the standalone tedder pass and through a lease
--      projects the source cells the same way (one projector)
--   A  an AREA kind: clearArea clears only on a known whole-cell zero
--   M  smoothing: the losing cells' captured condition lands on the gainers
--   U  a drop of carried stock arrives of unknown condition; so does a conversion
--   X  refusals: the cells array, a kind or type mismatch, bad footprints, a throw,
--      a height map that is not valid
--   E  an envelope over the limit is admitted and every cell goes unavailable at
--      delivery; an envelope off the map projects nothing
--   D  the inner admission (item 3b): the standalone carrier stands aside when
--      StockGuard admits inside its native call, and projects when nobody does
--   K  a lease that ends undelivered marks its cells (closed with no delivery, a
--      refused observation then the close, a delivery in a later frame); a lease never
--      closed expires by the frame rule and is not live; a pickup's removals come back
--      in the result
--   Y  MAINTENANCE rows 100 and 101: a delivery that ends on an early return (a native
--      error, an unobservable envelope, an invalid height map) keeps its own reason
--      through the close and through the frame rule, and the close marks nothing more;
--      an expired lease leaves the table, admit sweeps earlier frames, so leaked leases
--      are bounded by the frame and a late deliver or close on a dead token is NO_LEASE
--
-- THE SOURCES RUN IN THE MOD'S OWN ENVIRONMENT (--!env: modenv, run-tests.mjs): the
-- engine's globals reach them only through __index, as in a game (mods.lua:436-442),
-- and the frame counter is set engine-side (ENGINE.setFrameIndex). Bob's finding on
-- #1003: the admission's rawget on _G passed here and read nil in a game, so the
-- frame rule (K4, K6) never fired. Row K0 pins the environment's shape.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

local INFO = {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function() end

local FT = ENGINE.FT
local O, C, P, A = GroundNativeObserver, GroundMovementCarrier, GroundMovementProjector, GroundConditionAdmission

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the world, armed as production arms it ─────────────────────────────────
local W = {}
local function world(today)
    HEIGHT.pixels = {}
    g_densityMapHeightManager.valid = true
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = { vehicles = {} } }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    local armedCells = sys.groundConditionCells:arm(vm)
    local armedCoord = armedCells and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local armedAdmit = armedCoord and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    return armedCells and armedCoord and armedAdmit
end
local function cellAge(gx, gz) return ENGINE.layerGet(W.age, gx, gz) end
local function cellWet(gx, gz) return ENGINE.layerGet(W.wet, gx, gz) end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return cellAge(gx, gz) .. "/" .. cellWet(gx, gz) end
local function unavailable() return W.sys.groundConditionCoordinator:getUnavailableCount() end
--- Windrowed grass on the strip x 0..8, z 0..2: 16 pixels at 50 L, 800 L. Cell (8,8)
--- holds x 0..4, cell (9,8) holds x 4..8 (4 m grain, origin -32).
local function grass() HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 8, 2, 50) end
local function tedderInWorld(uid, dropZ)
    local tedder, work, drop = ENGINE.newTedder({ uid = uid or "tedder", x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = dropZ or 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = tedder
    return tedder, work, drop
end

-- ── the lease path, as StockGuard's SG2-4 bracket will run it ──────────────
local function gc() return W.sys.groundConditionAdmission.groundCondition end
local function lineFP(sx, sz, ex, ez, ft, inner, radius)
    return { schemaVersion = 1, kind = "LINE", sx = sx, sz = sz, ex = ex, ez = ez, fillTypeIndex = ft, innerRadius = inner, radius = radius }
end
local function areaFP(x0, z0, x1, z1, x2, z2)
    return { schemaVersion = 1, kind = "AREA", x0 = x0, z0 = z0, x1 = x1, z1 = z1, x2 = x2, z2 = z2 }
end
local function tipObs(ok, ft, delta, litres, off)
    return { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = ok, fillTypeIndex = ft, deltaRequested = delta, litresReturned = litres, lineOffset = off }
end
--- admit, the real primitive, deliver, close: the bracket.
local function bracketTip(vehicle, ft, delta, sx, sz, ex, ez, inner, radius, area)
    local t = gc()
    local lease = t.admitPrimitive(lineFP(sx, sz, ex, ez, ft, inner, radius), A.KIND_TIP_LINE, vehicle, area or "area1")
    if lease.status ~= "ADMITTED" then return lease, nil, nil end
    local okN, litres, off = pcall(DensityMapHeightUtil.tipToGroundAroundLine, vehicle, delta, ft, sx, 0, sz, ex, 0, ez, inner, radius, 0, false, nil)
    local out = t.deliverMovement(lease.leaseToken, tipObs(okN, ft, delta, okN and litres or nil, okN and off or nil))
    t.closePrimitive(lease.leaseToken)
    return lease, out, okN and litres or nil
end
local TRUCK = { isServer = true, uniqueId = "sg-truck" }

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    T.ok("S0 [world] the family arms in production's order", world(100) == true)
    local caps = W.sys.groundConditionAdmission:getCapabilities()
    T.eq("S1 the capability publishes admission revision 2", caps.groundCondition and caps.groundCondition.admissionRevision, 2)
    T.eq("S1b [reached] twin: the published table carries the three calls at revision 2", type(gc().admitPrimitive) .. "/" .. type(gc().deliverMovement) .. "/" .. type(gc().closePrimitive) .. "/" .. gc().admissionRevision, "function/function/function/2")
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local reads0, frames0 = O.stats.occupancyReads, C.stats.frames
    -- The pickup StockGuard brackets: the line the tedder's own geometry resolves
    -- (x 0..8 at z 1, inner radius 1, the default outer radius).
    local lease, out, litres = bracketTip(TRUCK, FT.GRASS_WINDROW, -math.huge, 0, 1, 8, 1, 1, nil)
    T.eq("S2 [world] the lease was admitted and the native pickup took the 800 L", lease.status .. "/" .. tostring(litres), "ADMITTED/-800")
    T.ok("S3 Soil read the cells' whole occupancy itself, before at admit and after at delivery", O.stats.occupancyReads - reads0 >= 4)
    T.eq("S4 the delivery was accepted and cleared both emptied source cells", out.status .. "/" .. out.reason .. "/" .. out.cleared, "ADMITTED/OK/2")
    T.eq("S5 the source cells' condition is cleared", condition(8, 8) .. " " .. condition(9, 8), "0/0 0/0")
    T.eq("S6 nothing was marked unavailable and the lease closed", unavailable() .. "/" .. W.sys.groundConditionAdmission:getOpenLeaseCount(), "0/0")
    -- The drop of carried stock onto z 6..7 (cell row 9).
    local lease2, out2, placed = bracketTip(TRUCK, FT.DRYGRASS_WINDROW, 800, 0, 6.5, 8, 6.5, 0.5, 1)
    T.eq("S7 [world] the native drop placed the 800 L", placed, 800)
    T.ok("S8 the delivery projected the cells the drop landed on", out2.projected >= 2)
    T.eq("S9 a drop of carried stock Soil never captured arrives of UNKNOWN condition", condition(8, 9) .. " " .. condition(9, 9), "0/24 0/24")
    T.eq("S10 a delivery after the close is refused", gc().deliverMovement(lease2.leaseToken, tipObs(true, FT.DRYGRASS_WINDROW, 800, 800, 1)).reason, A.DELIVER_NO_LEASE)
    T.eq("S11 no carrier frame was opened: the standalone observer is inert under the lease path", tostring(O.isAtRest()) .. "/" .. (C.stats.frames - frames0), "true/0")
    T.eq("S12 the published log line names the revision", (function()
        for _, l in ipairs(INFO) do if l:find("GroundConditionAdmission published (admissionRevision 2)", 1, true) then return true end end
        return false
    end)(), true)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Q. PARITY: ONE PROJECTOR
-- ══════════════════════════════════════════════════════════════════════════
group("Q", function()
    -- The standalone tedder pass, the P group of the tedder bar: a partial source cell
    -- keeps its condition, the emptied one is cleared.
    world(100)
    local tedder = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    HEIGHT.fill(FT.STRAW, 0, 3, 1, 4, 100)   -- straw in cell (8,8) beyond the pickup's reach
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(tedder, 16)
    local carrier = condition(8, 8) .. " " .. condition(9, 8) .. " u" .. unavailable()
    T.eq("Q1 [world] the carrier's pass: the partial cell keeps 3/60, the emptied one is cleared", carrier, "3/60 0/0 u0")

    -- The same pickup as a lease: the tedder's own line, reach and type.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    HEIGHT.fill(FT.STRAW, 0, 3, 1, 4, 100)
    local _, out = bracketTip(TRUCK, FT.GRASS_WINDROW, -math.huge, 0, 1, 8, 1, 1, nil)
    local lease = condition(8, 8) .. " " .. condition(9, 8) .. " u" .. unavailable()
    T.eq("Q2 the lease path projects the source cells exactly as the carrier did", lease, carrier)
    T.eq("Q3 and reports the one clearing", out.cleared .. "/" .. out.unavailable, "1/0")

    -- An unreadable cell is unavailable on both paths, never cleared: the height
    -- manager goes invalid before the after read.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    local t = gc()   -- the new world's published table, not the one above
    local l3 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, nil), A.KIND_TIP_LINE, TRUCK, "area1")
    local got = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, nil, 0, false, nil)
    g_densityMapHeightManager.valid = false
    local out3 = t.deliverMovement(l3.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got, 0))
    g_densityMapHeightManager.valid = true
    T.eq("Q4 a height map that cannot be read at delivery marks every lease cell unavailable and clears nothing", tostring(out3.unavailable > 0) .. "/" .. out3.cleared .. "/" .. condition(8, 8), "true/0/3/60")

    -- One cell's read throws at delivery (the map is valid, the read is not): that cell is
    -- unavailable, never cleared, and the readable neighbour is still cleared.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    t = gc()   -- again the new world's table
    local l4 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, nil), A.KIND_TIP_LINE, TRUCK, "area1")
    local got4 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, nil, 0, false, nil)
    local realRead = DensityMapHeightUtil.getFillLevelAtArea
    DensityMapHeightUtil.getFillLevelAtArea = function(ft, x0, z0, x1, z1, x2, z2)
        if x0 == 0 and z0 == 0 then error("read failed") end   -- cell (8,8)'s parallelogram
        return realRead(ft, x0, z0, x1, z1, x2, z2)
    end
    local out4 = t.deliverMovement(l4.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got4, 0))
    DensityMapHeightUtil.getFillLevelAtArea = realRead
    t.closePrimitive(l4.leaseToken)
    T.eq("Q5 a cell whose occupancy read throws at delivery is marked unavailable and keeps its bytes; its readable neighbour is cleared", tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)) .. "/" .. condition(8, 8) .. "/" .. condition(9, 8) .. "/" .. out4.cleared, "true/3/60/0/0/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. AN AREA KIND: clearArea
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local t = gc()
    -- The whole of cell (8,8): x 0..4, z 0..4.
    local lease = t.admitPrimitive(areaFP(0, 0, 4, 0, 0, 4), A.KIND_CLEAR_AREA, TRUCK, "area1")
    T.eq("A1 [world] an AREA lease is admitted for clearArea", lease.status, "ADMITTED")
    DensityMapHeightUtil.clearArea(0, 0, 4, 0, 0, 4)
    local out = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_CLEAR_AREA, ok = true })
    t.closePrimitive(lease.leaseToken)
    T.eq("A2 [native] the area's grass is gone and the neighbour's stays", HEIGHT.total(FT.GRASS_WINDROW), 400)
    T.eq("A3 the emptied cell is cleared, the untouched neighbour keeps its condition", condition(8, 8) .. " " .. condition(9, 8) .. " " .. out.cleared, "0/0 5/100 1")
    -- Half of cell (9,8): x 4..6. Its whole occupancy stays positive, so it keeps its condition.
    local l2 = t.admitPrimitive(areaFP(4, 0, 6, 0, 4, 4), A.KIND_CLEAR_AREA, TRUCK, "area1")
    DensityMapHeightUtil.clearArea(4, 0, 6, 0, 4, 4)
    local out2 = t.deliverMovement(l2.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_CLEAR_AREA, ok = true })
    t.closePrimitive(l2.leaseToken)
    T.eq("A4 a partially cleared cell keeps its condition: clearing only on a known whole-cell zero", condition(9, 8) .. " " .. out2.cleared .. " u" .. unavailable(), "5/100 0 u0")
    -- A LINE footprint for an AREA kind is not a footprint for it.
    T.eq("A5 a LINE footprint for clearArea is refused as bad arguments", t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_CLEAR_AREA, TRUCK, "area1").reason, A.REFUSE_ARGS)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. SMOOTHING: THE LOSING CELLS' CONDITION LANDS ON THE GAINERS
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    world(100)
    -- 400 L of grass in cell (8,8) only, old and wet; cells (9,8) and (7,8) empty.
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 4, 2, 50)
    setCell(8, 8, 9, 200)
    local t = gc()
    local lease = t.admitPrimitive(lineFP(-4, 1, 12, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_SMOOTH_LINE, TRUCK, "area1")
    T.eq("M1 [world] a LINE lease is admitted for smoothing", lease.status, "ADMITTED")
    local moved = HEIGHT.smooth(FT.GRASS_WINDROW, -4, 1, 12, 1, 2)
    local out = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_SMOOTH_LINE, ok = true })
    t.closePrimitive(lease.leaseToken)
    T.eq("M2 [native] the grass was spread along the line, none lost", math.floor(moved + 0.5) .. "/" .. math.floor(HEIGHT.total(FT.GRASS_WINDROW) + 0.5), "400/400")
    T.ok("M3 the cells that gained were projected", out.projected >= 2)
    T.eq("M4 the gainers take the losing cell's captured condition, litre-weighted", condition(9, 8) .. " " .. condition(7, 8), "9/200 9/200")
    T.eq("M5 the losing cell, still holding material, keeps its condition", condition(8, 8) .. " u" .. unavailable(), "9/200 u0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNKNOWN ARRIVALS
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    world(100)
    -- Straw already lying in cell (8,9) with a known record.
    HEIGHT.fill(FT.STRAW, 0, 4, 1, 5, 100)
    setCell(8, 9, 9, 40)
    local _, out = bracketTip(TRUCK, FT.DRYGRASS_WINDROW, 800, 0, 6.5, 8, 6.5, 0.5, 1)
    T.eq("U1 carried stock landing on a cell with a known record makes it unknown: positive unknown makes the component unknown", condition(8, 9) .. " " .. condition(9, 9), "0/24 0/24")
    T.eq("U2 [reached] twin: the drop was projected, not refused", tostring(out.projected >= 2) .. "/" .. out.refusedCells, "true/0")

    -- A conversion in place: grass to dry grass in cell (8,8), no registered basis.
    world(100)
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 4, 2, 50)
    setCell(8, 8, 3, 60)
    local t = gc()
    local lease = t.admitPrimitive(areaFP(0, 0, 4, 0, 0, 4), A.KIND_CHANGE_TYPE, TRUCK, "area1")
    local changed = DensityMapHeightUtil.changeFillTypeAtArea(0, 0, 4, 0, 0, 4, FT.GRASS_WINDROW, FT.DRYGRASS_WINDROW)
    local out2 = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_CHANGE_TYPE, ok = true, sourceTypeIndex = FT.GRASS_WINDROW, destinationTypeIndex = FT.DRYGRASS_WINDROW, litresReturned = changed })
    t.closePrimitive(lease.leaseToken)
    T.eq("U3 [native] the type changed in place, the litres stayed", changed .. "/" .. HEIGHT.total(FT.DRYGRASS_WINDROW) .. "/" .. HEIGHT.total(FT.GRASS_WINDROW), "400/400/0")
    T.eq("U4 an unexplained conversion makes the cell's condition unknown, the bytes are not cleared", condition(8, 8) .. " " .. out2.projected .. " u" .. unavailable(), "0/24 1 u0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. REFUSALS
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    local t = gc()
    local lease = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local got = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local withCells = tipObs(true, FT.GRASS_WINDROW, -math.huge, got, 0)
    withCells.cells = { { gx = 8, gz = 8, destination = { occupied = false }, contributions = { { litres = 10, ageRaw = 60, wetnessRaw = 80 } }, occupancy = { known = true, positive = false } } }
    T.eq("X1 a caller-supplied cells array is refused as a bad observation, even on an otherwise valid v1 observation", t.deliverMovement(lease.leaseToken, withCells).reason, A.DELIVER_BAD_OBS)
    T.eq("X1b the revision 1 shape alone is refused too", t.deliverMovement(lease.leaseToken, { cells = {} }).reason, A.DELIVER_BAD_OBS)
    local wrongKind = tipObs(true, FT.GRASS_WINDROW, -math.huge, got, 0)
    wrongKind.primitiveKind = A.KIND_SMOOTH_LINE
    T.eq("X2 an observation of another primitive kind is refused, whatever else it carries", t.deliverMovement(lease.leaseToken, wrongKind).reason .. "/" .. t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_CLEAR_AREA, ok = true }).reason, A.DELIVER_BAD_OBS .. "/" .. A.DELIVER_BAD_OBS)
    T.eq("X3 an observation of another fill type than the footprint's is refused", t.deliverMovement(lease.leaseToken, tipObs(true, FT.STRAW, -math.huge, got, 0)).reason, A.DELIVER_BAD_OBS)
    T.eq("X4 an observation without the schema or without ok is refused", t.deliverMovement(lease.leaseToken, { primitiveKind = A.KIND_TIP_LINE, ok = true, fillTypeIndex = FT.GRASS_WINDROW, deltaRequested = -1, litresReturned = got }).reason .. "/" .. t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, fillTypeIndex = FT.GRASS_WINDROW, deltaRequested = -1, litresReturned = got }).reason, A.DELIVER_BAD_OBS .. "/" .. A.DELIVER_BAD_OBS)
    T.eq("X5 a refused observation leaves the lease open and the ground unprojected", tostring(W.sys.groundConditionAdmission:hasLiveLeaseFor(TRUCK, "area1")) .. "/" .. condition(8, 8), "true/3/60")
    local out = t.deliverMovement(lease.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got, 0))
    T.eq("X6 [reached] twin: the right observation on the same lease then projects", out.status .. "/" .. out.cleared .. "/" .. condition(8, 8), "ADMITTED/2/0/0")
    t.closePrimitive(lease.leaseToken)

    -- Footprints.
    local bothShapes = areaFP(0, 0, 4, 0, 0, 4)
    bothShapes.sx, bothShapes.sz, bothShapes.ex, bothShapes.ez, bothShapes.fillTypeIndex = 0, 1, 8, 1, FT.GRASS_WINDROW
    T.eq("X7 a footprint whose kind is AREA is refused for a LINE primitive even when it also carries the LINE fields", t.admitPrimitive(bothShapes, A.KIND_TIP_LINE, TRUCK, "area1").reason .. "/" .. t.admitPrimitive(areaFP(0, 0, 4, 0, 0, 4), A.KIND_TIP_LINE, TRUCK, "area1").reason, A.REFUSE_ARGS .. "/" .. A.REFUSE_ARGS)
    T.eq("X8 a LINE footprint without its fill type is refused", t.admitPrimitive({ schemaVersion = 1, kind = "LINE", sx = 0, sz = 1, ex = 8, ez = 1, innerRadius = 1, radius = 1 }, A.KIND_TIP_LINE, TRUCK, "area1").reason, A.REFUSE_ARGS)
    T.eq("X9 a nonfinite coordinate is refused", t.admitPrimitive(lineFP(0 / 0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1").reason, A.REFUSE_ARGS)
    T.eq("X10 a negative radius is refused", t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, -1), A.KIND_TIP_LINE, TRUCK, "area1").reason, A.REFUSE_ARGS)
    T.eq("X11 a footprint of another schema is refused", t.admitPrimitive({ schemaVersion = 2, kind = "LINE", sx = 0, sz = 1, ex = 8, ez = 1, fillTypeIndex = FT.GRASS_WINDROW }, A.KIND_TIP_LINE, TRUCK, "area1").reason, A.REFUSE_ARGS)
    T.eq("X12 a colon call is refused rather than read as a footprint", t:admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK).reason, A.REFUSE_COLON_CALL)
    T.eq("X13 [reached] twin: the same footprint by a dot call is admitted", t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1").status, "ADMITTED")

    -- The primitive threw: ok = false marks every lease cell, projects nothing.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    HEIGHT.throwNext = true
    local lease2, out2, litres2 = bracketTip(TRUCK, FT.GRASS_WINDROW, -math.huge, 0, 1, 8, 1, 1, 1)
    T.eq("X14 a primitive that threw is delivered as ok = false: every lease cell unavailable, nothing projected, bytes kept", tostring(litres2) .. "/" .. out2.status .. "/" .. tostring(out2.unavailable >= 2) .. "/" .. out2.projected .. "/" .. condition(8, 8), "nil/ADMITTED/true/0/3/60")
    T.eq("X15 and the coordinator reports them", tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)) .. "/" .. tostring(W.sys.groundConditionCoordinator:isUnavailable(9, 8)), "true/true")

    -- No height map at admit: admitted, and every cell unavailable at delivery.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()   -- the new world's table
    g_densityMapHeightManager.valid = false
    local l3 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    g_densityMapHeightManager.valid = true
    local got3 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local out3 = t.deliverMovement(l3.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got3, 0))
    t.closePrimitive(l3.leaseToken)
    T.eq("X16 a height map that was not valid at admit: the lease is admitted and its delivery marks every cell", l3.status .. "/" .. tostring(out3.unavailable >= 2) .. "/" .. out3.cleared .. "/" .. tostring(out3.envelopeRefused), "ADMITTED/true/0/HEIGHT_MAP_INVALID")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENVELOPE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local t = gc()
    local saved = O.MAX_CELLS
    O.MAX_CELLS = 2
    local lease = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    O.MAX_CELLS = saved
    T.eq("E1 an envelope over the read limit is still admitted", lease.status, "ADMITTED")
    local got = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local out = t.deliverMovement(lease.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got, 0))
    t.closePrimitive(lease.leaseToken)
    T.eq("E2 its delivery marks every cell it covers unavailable and projects nothing, bytes kept", tostring(out.unavailable > 2) .. "/" .. out.projected .. "/" .. out.cleared .. "/" .. tostring(out.envelopeRefused) .. "/" .. condition(8, 8), "true/0/0/ENVELOPE_TOO_LARGE/3/60")
    -- Off the map: nothing to place on cells, nothing marked.
    local l2 = t.admitPrimitive(lineFP(1000, 1, 1008, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local out2 = t.deliverMovement(l2.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, 0, 0))
    t.closePrimitive(l2.leaseToken)
    T.eq("E3 an envelope off the map is admitted, projects nothing and marks nothing", l2.status .. "/" .. out2.projected .. "/" .. out2.unavailable .. "/" .. tostring(out2.envelopeRefused), "ADMITTED/0/0/OFF_MAP")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE INNER ADMISSION (item 3b)
-- ══════════════════════════════════════════════════════════════════════════
--- The REAL global table, where the engine's own Lua (DensityMapHeightUtil.lua:290)
--- resolves addDensityMapHeightAtWorldLine. Under the mod's environment a bare
--- assignment, rawset(_G, ...) and getfenv(0) all land in the mod's own table
--- (mods.lua:436-447), so an admitter that must be seen by the engine's util can only
--- reach the real table through the environment's __index. StockGuard's SG2-4b
--- bracket has the same constraint; noted for its intake.
local function realGlobals()
    local mt = getmetatable(_G)
    return (mt ~= nil and mt.__index) or _G
end

group("D", function()
    -- StockGuard's SG2-4 admits at the engine global INSIDE Soil's wrap of the util:
    -- the stub admitter below does exactly that, admitting, running the inner native,
    -- delivering and closing, for every primitive of the tedder's pass. It is
    -- installed where the engine's util resolves the global (realGlobals above).
    world(100)
    local tedder, work = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installTedderHook()
    local G = realGlobals()
    local native = G.addDensityMapHeightAtWorldLine
    local admitted, delivered = 0, 0
    G.addDensityMapHeightAtWorldLine = function(updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts)
        local t = gc()
        local lease = t.admitPrimitive(lineFP(sx, sz, ex, ez, ft, inner, radius), A.KIND_TIP_LINE, tedder, "sg-bracket")
        if lease.status == "ADMITTED" then admitted = admitted + 1 end
        local okN, moved, off2 = pcall(native, updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts)
        if lease.status == "ADMITTED" then
            t.deliverMovement(lease.leaseToken, tipObs(okN, ft, delta, okN and moved or nil, okN and off2 or nil))
            delivered = delivered + 1
            t.closePrimitive(lease.leaseToken)
        end
        if not okN then error(moved, 0) end
        return moved, off2
    end
    local projected0, stood0, frames0 = C.stats.projected, O.stats.stoodAside, C.stats.frames
    ENGINE.tick(tedder, 16)
    G.addDensityMapHeightAtWorldLine = native
    T.eq("D1 [world] the inner admitter admitted and delivered both of the pass's primitives inside Soil's native call", admitted .. "/" .. delivered, "2/2")
    T.eq("D2 [world] Soil's carrier had opened its frame for the pass (the pre-call check saw no lease)", C.stats.frames - frames0, 1)
    T.eq("D3 the carrier stood aside for both primitives: no projection of its own", (C.stats.projected - projected0) .. "/" .. (O.stats.stoodAside - stood0), "0/2")
    T.eq("D4 exactly one projection reached the ground, the lease's: the drop cells read the lease's unknown arrival, not the carrier's 5/100", condition(8, 9) .. " " .. condition(9, 9), "0/24 0/24")
    T.eq("D5 the source cells were cleared once, by the lease", condition(8, 8) .. " " .. condition(9, 8) .. " u" .. unavailable(), "0/0 0/0 u0")
    T.eq("D6 the frame closed and the account is empty", tostring(O.isAtRest()) .. "/" .. C.accountTotal(C.accountOf(work)), "true/0")

    -- The reverse: nobody admits inside, so Soil projects.
    world(100)
    local t2 = tedderInWorld("t2")
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installTedderHook()
    local stood1 = O.stats.stoodAside
    ENGINE.tick(t2, 16)
    T.eq("D7 with no inner admitter the carrier projects the pass itself", condition(8, 9) .. " " .. condition(9, 9) .. "/" .. (O.stats.stoodAside - stood1), "5/100 5/100/0")

    -- A refused inner admission mints no lease: Soil's own observation stands.
    world(100)
    local t3 = tedderInWorld("t3")
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installTedderHook()
    local refused = 0
    G.addDensityMapHeightAtWorldLine = function(updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts)
        local lease = gc().admitPrimitive({ cells = {} }, A.KIND_TIP_LINE, t3, "sg-bracket")   -- the revision 1 shape: refused
        if lease.status == "REFUSED" then refused = refused + 1 end
        return native(updater, sx, sy, sz, ex, ey, ez, delta, ft, inner, radius, limit, off, apply, tts)
    end
    local stood2 = O.stats.stoodAside
    ENGINE.tick(t3, 16)
    G.addDensityMapHeightAtWorldLine = native
    T.eq("D8 a refused inner admission (no lease minted) leaves Soil's own projection standing", refused .. "/" .. (O.stats.stoodAside - stood2) .. "/" .. condition(8, 9), "2/0/5/100")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. A LEASE THAT ENDS UNDELIVERED (Bob's verdict on #1002)
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    -- Closed with no delivery: the primitive ran (the material moved) and nobody vouched
    -- for the cells, so every cell the lease named goes unavailable, bytes kept.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local t = gc()
    local coord = W.sys.groundConditionCoordinator
    local l1 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local closed = t.closePrimitive(l1.leaseToken)
    T.eq("K1 a lease closed with no delivery marks every cell it named unavailable, bytes kept, nothing cleared", tostring(closed.unavailable >= 2) .. "/" .. tostring(coord:isUnavailable(8, 8)) .. "/" .. tostring(coord:isUnavailable(9, 8)) .. "/" .. condition(8, 8), "true/true/true/3/60")
    T.eq("K1b and the reason names it", tostring(coord:unavailableReason(8, 8)), "LEASE_CLOSED_UNDELIVERED")

    -- A refused observation, then the close: the refusal accepted nothing, so the close marks.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    local l2 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local got2 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local bad = t.deliverMovement(l2.leaseToken, { cells = {} })
    local closed2 = t.closePrimitive(l2.leaseToken)
    T.eq("K2 a refused observation followed by the close: refused, then every cell marked at the close", bad.reason .. "/" .. tostring(closed2.unavailable >= 2) .. "/" .. tostring(coord:isUnavailable(8, 8)) .. "/" .. condition(8, 8), A.DELIVER_BAD_OBS .. "/true/true/3/60")
    -- [reached] twin: an accepted delivery, then the close: nothing more is marked.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    local l3 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local got3 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local out3 = t.deliverMovement(l3.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got3, 0))
    local closed3 = t.closePrimitive(l3.leaseToken)
    T.eq("K3 [reached] twin: an accepted delivery then the close marks nothing and the pickup's removals came back in the result", closed3.unavailable .. "/" .. coord:getUnavailableCount() .. "/" .. #out3.collected .. "/" .. tostring(out3.collected[1].ageRaw), "0/0/2/3")

    -- A delivery in a later frame: refused, the lease closed and its cells marked.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    ENGINE.setFrameIndex(700)
    T.eq("K0 [world] the sources run in a mod-shaped environment: _G is the mod's own table, rawget(_G, 'g_updateLoopIndex') is nil, and the plain read reaches the engine's counter through __index",
        tostring(rawget(_G, "g_updateLoopIndex") == nil) .. "/" .. tostring(g_updateLoopIndex) .. "/" .. tostring(getmetatable(_G) ~= nil and getmetatable(_G).__index ~= nil), "true/700/true")
    local l4 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local got4 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    ENGINE.setFrameIndex(701)
    local late = t.deliverMovement(l4.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got4, 0))
    T.eq("K4 a delivery in a later frame is refused and the lease's cells are marked as crossed", late.reason .. "/" .. tostring(coord:isUnavailable(8, 8)) .. "/" .. tostring(coord:unavailableReason(8, 8)) .. "/" .. W.sys.groundConditionAdmission:getOpenLeaseCount(), A.DELIVER_STALE_FRAME .. "/true/LEASE_CROSSED_A_FRAME/0")
    ENGINE.setFrameIndex(nil)

    -- A lease never closed: live in its frame, expired by the frame rule in the next, so
    -- the standalone carrier is not kept standing aside for the mission.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    local adm = W.sys.groundConditionAdmission
    ENGINE.setFrameIndex(800)
    local l5 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    T.eq("K5 [reached] a lease is live for its owner in its own frame", tostring(adm:hasLiveLeaseFor(TRUCK, "area1")) .. "/" .. adm:getOpenLeaseCount(), "true/1")
    ENGINE.setFrameIndex(801)
    T.eq("K6 a lease nobody closed is not live in the next frame: expired, closed and its cells marked", tostring(adm:hasLiveLeaseFor(TRUCK, "area1")) .. "/" .. adm:getOpenLeaseCount() .. "/" .. tostring(coord:isUnavailable(8, 8)), "false/0/true")
    T.eq("K7 and a tedder pass in that frame runs the standalone carrier again (no stand-aside on a leaked lease)", (function()
        local tedder = tedderInWorld()
        W.sys.hookManager:installTedderHook()
        local frames = C.stats.frames
        ENGINE.tick(tedder, 16)
        return tostring(C.stats.frames - frames)
    end)(), "1")
    ENGINE.setFrameIndex(nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Y. ROWS 100 AND 101: THE REASON STANDS, THE DEAD TOKEN LEAVES
-- ══════════════════════════════════════════════════════════════════════════
group("Y", function()
    -- Row 100. A native error at delivery: the cells are marked NATIVE_ERROR there, and
    -- the close finds nothing left to mark, so the reason is not overwritten.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local t = gc()
    local coord = W.sys.groundConditionCoordinator
    local l1 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    HEIGHT.throwNext = true
    local okN = pcall(DensityMapHeightUtil.tipToGroundAroundLine, TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local out1 = t.deliverMovement(l1.leaseToken, tipObs(okN, FT.GRASS_WINDROW, -math.huge, nil, nil))
    local closed1 = t.closePrimitive(l1.leaseToken)
    T.eq("Y1 a native error at delivery marks the cells once, and the close re-marks nothing: the reason stays NATIVE_ERROR",
        tostring(okN) .. "/" .. tostring(out1.unavailable >= 2) .. "/" .. closed1.unavailable .. "/" .. tostring(coord:unavailableReason(8, 8)) .. "/" .. tostring(coord:unavailableReason(9, 8)),
        "false/true/0/NATIVE_ERROR/NATIVE_ERROR")

    -- An envelope over the read limit: marked ENVELOPE:<reason> at delivery, nothing at the close.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    local saved = O.MAX_CELLS
    O.MAX_CELLS = 2
    local l2 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    O.MAX_CELLS = saved
    local got2 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    local out2 = t.deliverMovement(l2.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got2, 0))
    local closed2 = t.closePrimitive(l2.leaseToken)
    T.eq("Y2 an unobservable envelope keeps its ENVELOPE reason through the close",
        tostring(out2.unavailable > 2) .. "/" .. closed2.unavailable .. "/" .. tostring(string.find(tostring(coord:unavailableReason(8, 8)), "^ENVELOPE:") ~= nil),
        "true/0/true")

    -- The height map gone between admit and delivery: HEIGHT_MAP_INVALID stands.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    local l3 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local got3 = DensityMapHeightUtil.tipToGroundAroundLine(TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    g_densityMapHeightManager.valid = false
    local out3 = t.deliverMovement(l3.leaseToken, tipObs(true, FT.GRASS_WINDROW, -math.huge, got3, 0))
    g_densityMapHeightManager.valid = true
    local closed3 = t.closePrimitive(l3.leaseToken)
    T.eq("Y3 a height map invalid at delivery keeps HEIGHT_MAP_INVALID through the close",
        tostring(out3.unavailable >= 2) .. "/" .. closed3.unavailable .. "/" .. tostring(coord:unavailableReason(8, 8)),
        "true/0/HEIGHT_MAP_INVALID")

    -- The frame-cross variant: the early-return delivery in one frame, the lease never
    -- closed, the frame rule in the next: the reason stands and the record is gone.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    local adm = W.sys.groundConditionAdmission
    ENGINE.setFrameIndex(900)
    local l4 = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    HEIGHT.throwNext = true
    local ok4 = pcall(DensityMapHeightUtil.tipToGroundAroundLine, TRUCK, -math.huge, FT.GRASS_WINDROW, 0, 0, 1, 8, 0, 1, 1, 1, 0, false, nil)
    t.deliverMovement(l4.leaseToken, tipObs(ok4, FT.GRASS_WINDROW, -math.huge, nil, nil))
    ENGINE.setFrameIndex(901)
    local live4 = adm:hasLiveLeaseFor(TRUCK, "area1")
    local n4 = 0
    for _ in pairs(adm.leases) do n4 = n4 + 1 end
    T.eq("Y4 the frame rule on a lease whose delivery ended on a native error keeps NATIVE_ERROR and removes the record",
        tostring(live4) .. "/" .. tostring(coord:unavailableReason(8, 8)) .. "/" .. n4 .. "/" .. adm:getOpenLeaseCount(),
        "false/NATIVE_ERROR/0/0")
    ENGINE.setFrameIndex(nil)

    -- Row 101. A caller that leaks a lease every frame: each admit sweeps the last
    -- frame's, so the table never holds more than this frame's lease; when the caller
    -- stops, the next question empties it.
    world(100)
    grass()
    setCell(8, 8, 3, 60)
    t = gc()
    coord = W.sys.groundConditionCoordinator
    adm = W.sys.groundConditionAdmission
    local maxHeld, tokens = 0, {}
    for i = 1, 6 do
        ENGINE.setFrameIndex(1000 + i)
        local li = t.admitPrimitive(lineFP(0, 1, 8, 1, FT.GRASS_WINDROW, 1, 1), A.KIND_TIP_LINE, TRUCK, "area" .. i)
        tokens[i] = li.leaseToken
        local n = 0
        for _ in pairs(adm.leases) do n = n + 1 end
        if n > maxHeld then maxHeld = n end
    end
    ENGINE.setFrameIndex(1007)
    local live5 = adm:hasLiveLeaseFor(TRUCK, "area6")
    local n5 = 0
    for _ in pairs(adm.leases) do n5 = n5 + 1 end
    T.eq("Y5 six leaked leases across six frames: the table never holds more than one, and the next frame's question empties it",
        tostring(tokens[6] ~= nil) .. "/" .. maxHeld .. "/" .. tostring(live5) .. "/" .. n5 .. "/" .. adm:getOpenLeaseCount(),
        "true/1/false/0/0")
    -- A late deliver or close on a dead token: NO_LEASE (the declared change; the old
    -- answers were STALE_FRAME for the deliver and an ADMITTED close of nothing).
    local lateD = t.deliverMovement(tokens[3], tipObs(true, FT.GRASS_WINDROW, -math.huge, 0, 0))
    local lateC = t.closePrimitive(tokens[3])
    T.eq("Y6 a late deliver or close on a swept token is refused as NO_LEASE",
        lateD.status .. "/" .. lateD.reason .. "/" .. lateC.status .. "/" .. lateC.reason,
        "REFUSED/" .. A.DELIVER_NO_LEASE .. "/REFUSED/" .. A.DELIVER_NO_LEASE)
    ENGINE.setFrameIndex(nil)
end)

