-- RSF-F208-s3-tedder_carrier_spec_test.lua
--
-- RSF-F208, contract section 3, slice S2a: the Tedder carrier. A tedder picks up
-- windrowed grass and drops it again further back; the age and wetness the ground
-- recorded for that grass must land where the grass landed, before HayBet dries it.
--
-- THE ENTRY-POINT BAR IS GROUP S. Production enters through
-- SoilFertilitySystem.new (which builds the ground family and the hook manager),
-- the family armed in production's own order (SoilFertilitySystem.lua:339-346), and
-- HookManager:installTedderHook, which installs the native observer and wraps the
-- tedder's CAPTURED work-area pointer (WorkArea.lua:266). A pass is the engine's
-- per-area order (WorkArea.lua:179-193) calling that pointer, the native
-- processTedderArea body calling the real (wrapped) tipToGroundAroundLine. Nothing
-- here opens a frame, writes an account, or places a projection by hand; the world
-- is the ground's material and the condition a save carried.
--
-- Groups:
--   S  the ordinary pass: pickup, drop, projection, clearing, HayBet after
--   P  a partial removal keeps its condition; whole-cell occupancy decides
--   R  the remainder: its stamp, one ageing across days, a reversed clock
--   B  refusals: a refused barrier, a live StockGuard lease, a client, a throw
--   O  the observer is inert without a frame
--   W  two contributors in one drop update each cell once
--   E  an envelope too large to read: every cell it covers goes unavailable
--   Z  the observer's cleanup is registered and restores the native primitive
--
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementCarrier.lua

local INFO = {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function() end

local FT = ENGINE.FT
local O, C = GroundNativeObserver, GroundMovementCarrier

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the world, armed as production arms it ─────────────────────────────────
local W = {}
local function world(today)
    HEIGHT.pixels = {}
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = { vehicles = {} } }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    -- The cursors a save carried: both owners settled through the day before.
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

--- A tedder on the ground at x 0..8, z 0..2, dropping along z 6..7, added to the
--- mission before the hook installs (the install-time sweep reaches it).
local function tedderInWorld(uid, dropZ)
    local tedder, work, drop = ENGINE.newTedder({ uid = uid or "tedder", x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = dropZ or 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = tedder
    return tedder, work, drop
end
--- Windrowed grass on the tedding strip: 16 pixels at 50 L, 800 L. Cell (8,8) holds
--- x 0..4, cell (9,8) holds x 4..8 (4 m grain, origin -32).
local function grass() HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 8, 2, 50) end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ORDINARY PASS
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    T.ok("S0 [world] the family arms in production's order", world(100) == true)
    local tedder, work = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)    -- 2 days down, wetness 60
    setCell(9, 8, 5, 100)   -- 4 days down, wetness 100
    W.sys.hookManager:installTedderHook()
    T.ok("S1 the hook installed the native observer", rawget(DensityMapHeightUtil, O.MARKER) ~= nil)
    T.ok("S2 and wrapped the tedder's captured work-area pointer", work.processingFunction ~= Tedder.processTedderArea)

    ENGINE.snapshot = function() return condition(8, 9) end
    ENGINE.tick(tedder, 16)
    T.eq("S3 [native] the pass picked up the 800 L of grass ...", HEIGHT.total(FT.GRASS_WINDROW), 0)
    T.eq("S4 [native] ... and dropped 800 L of dry grass, nothing left over", HEIGHT.total(FT.DRYGRASS_WINDROW) .. "/" .. work.litersToDrop, "800.0/0.0")
    T.eq("S5 the drop cells carry the oldest age and the wettest band of what arrived", condition(8, 9) .. " " .. condition(9, 9), "5/100 5/100")
    T.eq("S6 including the edge cells the drop spilled onto", condition(7, 9) .. " " .. condition(10, 9), "5/100 5/100")
    T.eq("S7 the emptied source cells are cleared", condition(8, 8) .. " " .. condition(9, 8), "0/0 0/0")
    T.eq("S8 HayBet ran AFTER the projection: it saw the moved condition, not bare ground", W.sys.hayBet.seen[1], "5/100")
    T.eq("S9 the frame closed and the account is empty", tostring(O.isAtRest()) .. "/" .. C.accountTotal(C.accountOf(work)), "true/0")
    T.eq("S10 nothing was marked unavailable", W.sys.groundConditionCoordinator:getUnavailableCount(), 0)
    local function firstPassLines()
        local n = 0
        for _, line in ipairs(INFO) do if line:find("FIRST TEDDER PASS OBSERVED", 1, true) then n = n + 1 end end
        return n
    end
    T.eq("S10b the first observed pass says so in the log, once", firstPassLines(), 1)
    ENGINE.tick(tedder, 16)
    T.eq("S10c and a second pass does not repeat it", firstPassLines(), 1)

    -- A tedder added later through VehicleSystem.addVehicle gets the carrier too.
    local late, lateWork = ENGINE.newTedder({ uid = "late", x0 = 16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem:addVehicle(late)
    HEIGHT.fill(FT.GRASS_WINDROW, 16, 0, 24, 2, 50)
    setCell(12, 8, 7, 80)
    setCell(13, 8, 7, 80)
    ENGINE.tick(late, 16)
    T.eq("S11 a tedder added later is carried by the same wrapper", condition(12, 9) .. "/" .. tostring(lateWork.processingFunction ~= Tedder.processTedderArea), "7/80/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. PARTIAL REMOVAL AND WHOLE-CELL OCCUPANCY
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    world(100)
    local tedder = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    -- Straw in cell (8,8) beyond the pickup's reach: the cell is not empty after.
    HEIGHT.fill(FT.STRAW, 0, 3, 1, 4, 100)
    -- Straw already lying in drop cell (8,9) (world z 4..8), off the drop strip
    -- itself (z 6..7), with an older, drier record.
    HEIGHT.fill(FT.STRAW, 0, 4, 1, 5, 100)
    setCell(8, 9, 9, 40)
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(tedder, 16)
    T.eq("P1 a cell only partly emptied keeps its source condition", condition(8, 8), "3/60")
    T.eq("P2 [reached] twin: the fully emptied neighbour is cleared", condition(9, 8), "0/0")
    T.eq("P3 a drop cell already holding straw keeps the worse (older) age and the wetter incoming band", condition(8, 9), "9/100")
    T.eq("P4 [reached] twin: the drop cell with nothing lying there takes the incoming condition", condition(9, 9), "5/100")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE REMAINDER: ITS STAMP, ONE AGEING, A REVERSED CLOCK
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    world(100)
    local tedder, work, drop = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    -- The drop strip is nearly full: 10 pixels with 40 L of room each.
    HEIGHT.fill(FT.DRYGRASS_WINDROW, -1, 6, 9, 7, 360)
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(tedder, 16)
    T.eq("R1 [native] the drop spilled short: 400 L placed, 400 L remain on the tedder", work.litersToDrop, 400)
    T.eq("R2 the account carries the remainder, both components still stamped", C.accountTotal(C.accountOf(work)) .. "/" .. #C.accountOf(work).components, "400.0/2")

    -- Three days later the tedder drops the remainder onto fresh ground.
    g_currentMission.environment.currentMonotonicDay = 103
    drop.start.z, drop.width.z, drop.height.z = 12, 12, 13
    ENGINE.PIXEL_CAP = 1000
    ENGINE.tick(tedder, 16)
    ENGINE.PIXEL_CAP = 400
    T.eq("R3 the remainder aged exactly three days from its stamp (5 + 3 = 8), wetness kept", condition(8, 11), "8/100")
    T.eq("R4 and the account emptied with the native remainder", tostring(work.litersToDrop) .. "/" .. C.accountTotal(C.accountOf(work)), "0.0/0")

    -- Once more, with the drop split over two passes on the same later day: the
    -- second pass must not add the span again.
    world(100)
    local t2, w2, d2 = tedderInWorld("t2")
    grass()
    setCell(8, 8, 5, 100)
    setCell(9, 8, 5, 100)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, -1, 6, 9, 7, 360)
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(t2, 16)
    g_currentMission.environment.currentMonotonicDay = 102
    d2.start.z, d2.width.z, d2.height.z = 12, 12, 13
    HEIGHT.fill(FT.DRYGRASS_WINDROW, -1, 12, 9, 13, 380)   -- room for 200 of the 400
    -- That strip's own record is younger and drier, so the carried 5 + 2 decides.
    for gx = 7, 10 do setCell(gx, 11, 2, 40) end
    ENGINE.tick(t2, 16)
    local first = condition(8, 11)
    d2.start.z, d2.width.z, d2.height.z = 20, 20, 21
    ENGINE.tick(t2, 16)
    T.eq("R5 a remainder dropped over two passes ages once: both drops read 5 + 2", first .. " " .. condition(8, 13), "7/100 7/100")

    -- A clock that runs backwards makes the carried age unknown.
    world(100)
    local t3, w3, d3 = tedderInWorld("t3")
    grass()
    setCell(8, 8, 5, 100)
    setCell(9, 8, 5, 100)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, -1, 6, 9, 7, 360)
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(t3, 16)
    g_currentMission.environment.currentMonotonicDay = 99
    W.sys.groundConditionCoordinator:invalidateBarrier()
    d3.start.z, d3.width.z, d3.height.z = 12, 12, 13
    ENGINE.PIXEL_CAP = 1000
    ENGINE.tick(t3, 16)
    ENGINE.PIXEL_CAP = 400
    T.eq("R6 a reversed clock makes the carried age unknown (raw 0); wetness is kept", condition(8, 11), "0/100")
    -- Another mod clears the tedder's remainder between passes: the native number is
    -- the truth, so the stale condition must not ride on into the next drop.
    world(100)
    local t4, w4 = tedderInWorld("t4")
    grass()
    setCell(8, 8, 9, 200)
    setCell(9, 8, 9, 200)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, -1, 6, 9, 7, 360)
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(t4, 16)
    T.eq("R8a [reached] a 9-day remainder is carried", C.accountTotal(C.accountOf(w4)), 400)
    w4.litersToDrop = 0
    HEIGHT.pixels[FT.DRYGRASS_WINDROW] = {}
    grass()
    setCell(8, 8, 2, 40)
    setCell(9, 8, 2, 40)
    ENGINE.PIXEL_CAP = 1000
    ENGINE.tick(t4, 16)
    ENGINE.PIXEL_CAP = 400
    T.eq("R8 once another mod clears the native remainder, only the fresh pickup's condition lands", condition(8, 9), "2/40")

    T.eq("R7 the stamp rule by itself: missing clock unknown, ceiling stays, saturation at 255",
        tostring(C.agedRaw(5, 100, nil)) .. "/" .. tostring(C.agedRaw(255, 100, 101)) .. "/" .. tostring(C.agedRaw(250, 100, 110)), "nil/255/255")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. REFUSALS
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    -- A held wetness day: the barrier refuses. Native work runs, the touched cells
    -- go unavailable, and no condition is written.
    world(100)
    local tedder, work = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installTedderHook()
    g_currentMission.environment.currentMonotonicDay = 101
    W.sys.materialWetness.hold = true
    ENGINE.tick(tedder, 16)
    local coord = W.sys.groundConditionCoordinator
    T.eq("B1 [native] a refused barrier does not stop the tedder", HEIGHT.total(FT.DRYGRASS_WINDROW), 800)
    T.eq("B2 the cells it moved are unavailable", tostring(coord:isUnavailable(8, 8)) .. "/" .. tostring(coord:isUnavailable(8, 9)), "true/true")
    T.eq("B3 and no condition was written: the source keeps its bytes, the drop has none", condition(8, 8) .. " " .. condition(8, 9), "3/60 0/0")

    -- A live StockGuard lease owns the primitive: the standalone carrier stands aside.
    world(100)
    local t2, w2 = tedderInWorld("t2")
    grass()
    setCell(8, 8, 3, 60)
    W.sys.hookManager:installTedderHook()
    local lease = W.sys.groundConditionAdmission:_admitPrimitive({ cells = {} }, "TIP_LINE", t2, w2)
    T.eq("B4 [world] StockGuard holds a lease for this tedder's work area", lease.status, "ADMITTED")
    local frames = C.stats.frames
    ENGINE.tick(t2, 16)
    T.eq("B5 with a live lease the standalone carrier opens no frame", C.stats.frames - frames, 0)
    T.eq("B6 native work still ran, and no condition was projected", HEIGHT.total(FT.DRYGRASS_WINDROW) .. "/" .. condition(8, 9), "800.0/0/0")
    W.sys.groundConditionAdmission:_closePrimitive(lease.leaseToken)

    -- A client's tedder projects nothing.
    world(100)
    local t3 = tedderInWorld("t3")
    grass()
    setCell(8, 8, 3, 60)
    t3.isServer = false
    W.sys.hookManager:installTedderHook()
    local f3 = C.stats.frames
    ENGINE.tick(t3, 16)
    T.eq("B7 a client's pass opens no frame and writes no condition", tostring(C.stats.frames - f3) .. "/" .. condition(8, 9), "0/0/0")
    -- The carrier refuses a client vehicle itself, whatever its caller gated: the
    -- mower and windrower wrappers (S2b) call the same begin.
    local clientFrame = C.begin(W.sys, { isServer = false }, {}, C.KIND_TEDDER, C.tedderRemainder)
    local serverFrame = C.begin(W.sys, { isServer = true }, { litersToDrop = 0 }, C.KIND_TEDDER, C.tedderRemainder)
    C.finish(serverFrame)
    T.eq("B7b the carrier itself opens no frame for a client vehicle", tostring(clientFrame), "nil")
    T.ok("B7c [reached] twin: it opens one for a server vehicle", serverFrame ~= nil)

    -- The mod switched off in its settings: no carrier.
    world(100)
    local t5 = tedderInWorld("t5")
    grass()
    setCell(8, 8, 3, 60)
    W.sys.hookManager:installTedderHook()
    g_SoilFertilityManager.settings.enabled = false
    local f5 = C.stats.frames
    ENGINE.tick(t5, 16)
    T.eq("B11 with the mod switched off the pass opens no frame and writes no condition", tostring(C.stats.frames - f5) .. "/" .. condition(8, 9), "0/0/0")

    -- A throw inside the native call: the error reaches the engine unchanged, the
    -- frame closes, and the cells it may have touched go unavailable.
    world(100)
    local t4, w4 = tedderInWorld("t4")
    grass()
    setCell(8, 8, 3, 60)
    W.sys.hookManager:installTedderHook()
    HEIGHT.throwNext = true
    local okT, errT = pcall(ENGINE.tick, t4, 16)
    T.eq("B8 the native error reaches the engine unchanged", tostring(okT) .. "/" .. tostring(errT ~= nil and tostring(errT):find("native tip failed", 1, true) ~= nil), "false/true")
    T.eq("B9 the frame closed", O.isAtRest(), true)
    T.eq("B10 the cells the failed pickup covered are unavailable, and nothing was projected", tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 8)) .. "/" .. condition(8, 8), "true/3/60")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE OBSERVER IS INERT WITHOUT A FRAME
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    world(100)
    tedderInWorld()
    W.sys.hookManager:installTedderHook()
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 4, 1, 50)
    setCell(8, 8, 3, 60)
    local prims = O.stats.primitives
    local other = {}
    local got, off = DensityMapHeightUtil.tipToGroundAroundLine(other, -math.huge, FT.GRASS_WINDROW, 0, 0, 0.5, 4, 0, 0.5, 0.5, nil, nil, false, nil)
    T.eq("O1 a tip from any other caller returns the native result untouched", tostring(got) .. "/" .. tostring(off), "-200/0")
    T.eq("O2 and is not recorded, projected or cleared", tostring(O.stats.primitives - prims) .. "/" .. condition(8, 8), "0/3/60")
    T.eq("O3 a second install is a no-op", select(2, O.install()), "ALREADY")

    -- Another vehicle tips while the tedder's frame is open (here, from inside the
    -- tedder's own drop call): it is not the tedder's primitive.
    world(100)
    local tedder = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installTedderHook()
    local stranger = {}
    local ownDrop = tedder.processDropArea
    tedder.processDropArea = function(self, ...)
        DensityMapHeightUtil.tipToGroundAroundLine(stranger, 50, FT.DRYGRASS_WINDROW, 0, 0, 20.5, 4, 0, 20.5, 0.5, nil, nil, false, nil)
        return ownDrop(self, ...)
    end
    ENGINE.tick(tedder, 16)
    T.eq("O4 [native] the stranger's drop landed", HEIGHT.total(FT.DRYGRASS_WINDROW) > 800, true)
    T.eq("O5 but it is not the tedder's: its cell gets no condition", condition(8, 13), "0/0")
    T.eq("O6 [reached] twin: the tedder's own drop was projected", condition(8, 9), "5/100")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. TWO CONTRIBUTORS IN ONE DROP UPDATE EACH CELL ONCE
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    world(100)
    local tedder = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installTedderHook()
    local cells = W.sys.groundConditionCells
    local realWrite = cells.writeConditionCell
    local writes = {}
    cells.writeConditionCell = function(self, geometry, gx, gz, ...)
        local key = gx .. ":" .. gz
        writes[key] = (writes[key] or 0) + 1
        return realWrite(self, geometry, gx, gz, ...)
    end
    ENGINE.tick(tedder, 16)
    cells.writeConditionCell = nil
    T.eq("W1 [reached] the drop's two contributors both reached cell (8,9)", condition(8, 9), "5/100")
    T.eq("W2 and each drop cell was written exactly once", tostring(writes["8:9"]) .. "/" .. tostring(writes["9:9"]) .. "/" .. tostring(writes["7:9"]), "1/1/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. AN ENVELOPE TOO LARGE TO READ
-- ══════════════════════════════════════════════════════════════════════════
-- Over the read cap the observer reads nothing, but it still names every cell the
-- line can reach, and the carrier marks each one unavailable with its bytes kept.
-- Otherwise a drop through it would leave the old known condition standing under
-- material that just arrived (contract section 2). A small cap forces the case.
group("E", function()
    world(100)
    local tedder = tedderInWorld()
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    setCell(8, 9, 9, 40)
    W.sys.hookManager:installTedderHook()
    local reads = O.stats.occupancyReads
    local saved = O.MAX_CELLS
    O.MAX_CELLS = 2
    local ok = pcall(ENGINE.tick, tedder, 16)
    O.MAX_CELLS = saved
    local coord = W.sys.groundConditionCoordinator
    T.eq("E1 [native] the pass still ran", tostring(ok) .. "/" .. HEIGHT.total(FT.DRYGRASS_WINDROW), "true/800.0")
    T.eq("E2 the drop cell's old record is marked unavailable, its bytes kept", tostring(coord:isUnavailable(8, 9)) .. "/" .. condition(8, 9), "true/9/40")
    T.eq("E3 the source cells are too, their bytes kept", tostring(coord:isUnavailable(8, 8)) .. "/" .. condition(8, 8), "true/3/60")
    T.eq("E4 and no occupancy was read for an envelope over the read cap", O.stats.occupancyReads - reads, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Z. THE OBSERVER'S CLEANUP (last: it unwraps the primitive)
-- ══════════════════════════════════════════════════════════════════════════
group("Z", function()
    world(100)
    tedderInWorld()
    O.uninstall()
    T.eq("Z0 [world] the primitive starts unwrapped, so this install is the one that wraps it", rawget(DensityMapHeightUtil, O.MARKER), nil)
    local hm = W.sys.hookManager
    hm:installTedderHook()
    local entry
    for _, h in ipairs(hm.hooks) do
        if tostring(h.name):find("ground-condition observer", 1, true) then entry = h end
    end
    T.ok("Z1 the tedder hook registered a cleanup for the observer it installed", entry ~= nil and type(entry.cleanup) == "function")
    if entry ~= nil then entry.cleanup() end
    T.eq("Z2 and the cleanup restores the native primitive", rawget(DensityMapHeightUtil, O.MARKER), nil)
end)
