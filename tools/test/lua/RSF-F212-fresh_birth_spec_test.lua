-- RSF-F212-fresh_birth_spec_test.lua
--
-- RSF-F212, GROUND-CONDITION-CONTRACT v1.5 section 4 (P-GROUND-2): fresh material is
-- born with its starting condition. A GENUINE fresh birth, proved by a positive native
-- production observation from the accepted mower or combine straw branch, enters the
-- carrier's account born at the deposit with the Soil-owned profile (FRESH_GRASS_V1 80%
-- wet basis, raw 204; FRESH_STRAW_V1 25%, raw 65), its provenance estimated-at-birth on
-- the contribution. A cut over an old or unknown windrow cannot reset it; a refused
-- barrier writes explicit unknown, never the profile; a fill-type name alone earns no
-- profile (a converter that makes hay gets none, an import stays unknown); a
-- redischarge never re-seeds; and the generic no-record birth (noteMaterialAt over the
-- work area) stands down in every admitted context, running only while the ground
-- family is not armed.
--
-- THE ENTRY-POINT BAR IS GROUP G FOR GRASS AND GROUP S FOR STRAW. Production enters
-- through SoilFertilitySystem.new, the ground family armed in production's order
-- (SoilFertilitySystem.lua:339-346) and HookManager:installAll, which installs the
-- mower's class-end birth append, the mower carrier (the captured cut pointer and the
-- processDropArea instance copy) and the combine swath hook (the captured
-- processCombineSwathArea pointer) together, in production's order. A pass is the
-- engine's order (ENGINE.tick, with the frame index advancing as main.lua does).
-- Nothing here opens a frame, writes an account, stamps a vehicle or places a
-- projection by hand; the contributions are read where production hands them to the
-- coordinator's combine.
--
-- THE SOURCES RUN IN THE MOD'S OWN ENVIRONMENT (--!env: modenv, run-tests.mjs): the
-- engine's globals reach them only through __index, as in a game (mods.lua:436-442).
-- Bob's finding on #1003 at 043f11f1: a rawget on _G passed here and read nil in a
-- game, so the stamp never landed. Row E3 pins the environment's shape.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local FT = ENGINE.FT
local GRASS = ENGINE.FRUIT.GRASS
local O, C = GroundNativeObserver, GroundMovementCarrier

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

--- A quantity as text, with no integer/float spelling (the engine's arithmetic decides).
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

local W = {}
-- The engine's class tables as loaded: installAll appends class-level listeners
-- (the mower's birth and yield hooks), and each world starts from a fresh engine.
local PRISTINE = {
    mowerStart = Mower.onStartWorkAreaProcessing, mowerEnd = Mower.onEndWorkAreaProcessing,
    combineStart = Combine.onStartWorkAreaProcessing, combineEnd = Combine.onEndWorkAreaProcessing,
    tedderStart = Tedder.onStartWorkAreaProcessing, tedderEnd = Tedder.onEndWorkAreaProcessing,
    windrowerStart = Windrower.onStartWorkAreaProcessing, windrowerEnd = Windrower.onEndWorkAreaProcessing,
}
--- The world: a fresh engine, production's system, the family armed in production's
--- order unless opts.unarmed (then the ground family is off, as on a save without the
--- gate), and the engine's field lookup answering field 7 for every position (the
--- MapDataGrid is the engine's; the birth hooks only pass its answer on).
local function world(today, opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    ENGINE.mowable = {}
    Mower.onStartWorkAreaProcessing, Mower.onEndWorkAreaProcessing = PRISTINE.mowerStart, PRISTINE.mowerEnd
    Combine.onStartWorkAreaProcessing, Combine.onEndWorkAreaProcessing = PRISTINE.combineStart, PRISTINE.combineEnd
    Tedder.onStartWorkAreaProcessing, Tedder.onEndWorkAreaProcessing = PRISTINE.tedderStart, PRISTINE.tedderEnd
    Windrower.onStartWorkAreaProcessing, Windrower.onEndWorkAreaProcessing = PRISTINE.windrowerStart, PRISTINE.windrowerEnd
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = { vehicles = {} } }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    sys.hookManager.getFieldIdAtWorldPosition = function() return 7 end
    if opts.unarmed then return true end
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    return a and b and c
end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return ENGINE.layerGet(W.age, gx, gz) .. "/" .. ENGINE.layerGet(W.wet, gx, gz) end
local function installAll()
    local ok, err = pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys)
    return ok, err
end
--- A mower in the mission's vehicle list: its cut strip x 0..8*areas, z 0..2, its drop
--- line at z = dropZ (cells (8,9) and (9,9) for one area at dropZ 6).
local function mowerInWorld(opts)
    opts = opts or {}
    local v, mowers, drop = ENGINE.newMower({ uid = opts.uid or "mower", x0 = opts.x0 or 0, z0 = 0, width = 8, depth = 2,
        dropZ = opts.dropZ or 6, areas = opts.areas, noDrop = opts.noDrop, outputFillType = opts.outputFillType })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, mowers, drop
end
--- A combine in the mission's vehicle list, its swath line x 0..8 at z = 6 (cells (8,9)
--- and (9,9)), the crop in its straw buffer opts.crop (WHEAT lays STRAW).
local function combineInWorld(opts)
    opts = opts or {}
    local v, swath = ENGINE.newCombine({ uid = opts.uid or "combine", crop = opts.crop, swath = opts.swath, x0 = opts.x0 or 0, swathZ = opts.swathZ or 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, swath
end
--- An old dry windrow under the first cut strip: 400 L over cells (8,8) and (9,8).
local function oldWindrow() HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 25) end
local function windrowOnLine() return DensityMapHeightUtil.getFillLevelAtArea(FT.GRASS_WINDROW, 0, 6, 8, 6, 0, 7) end
local function births() return W.sys.materialDown.births end
local function lines(list, needle)
    local n = 0
    for _, line in ipairs(list) do if line:find(needle, 1, true) then n = n + 1 end end
    return n
end
--- The contributions production hands to the coordinator's combine, recorded where
--- the projector calls it (GroundMovementProjector.land). Restored by the returned fn.
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
--- An account's components as "age:wetness:litres:provenance", oldest last.
local function accountShape(acc)
    local parts = {}
    for _, comp in ipairs(acc.components) do parts[#parts + 1] = comp end
    table.sort(parts, function(a, b)
        if (a.ageRaw or 0) ~= (b.ageRaw or 0) then return (a.ageRaw or 0) < (b.ageRaw or 0) end
        return tostring(a.provenance or "") < tostring(b.provenance or "")
    end)
    local out = {}
    for _, comp in ipairs(parts) do
        out[#out + 1] = tostring(comp.ageRaw or "-") .. ":" .. tostring(comp.wetnessRaw or "-") .. ":" .. num(comp.litres) .. ":" .. tostring(comp.provenance or "-")
    end
    return table.concat(out, " ")
end
local function cutLease(v, area, z)
    return W.sys.groundConditionAdmission:_admitPrimitive(
        { schemaVersion = 1, kind = "LINE", sx = 0, sz = z, ex = 8, ez = z, fillTypeIndex = FT.GRASS_WINDROW, innerRadius = 1, radius = 1 },
        GroundConditionAdmission.KIND_TIP_LINE, v, area)
end

-- ══════════════════════════════════════════════════════════════════════════
-- I. THE SWATH HOOK INSTALLS THE OBSERVER ITSELF
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    world(100)
    T.eq("I0 [world] nothing has wrapped the primitive yet", rawget(DensityMapHeightUtil, O.MARKER), nil)
    W.sys.hookManager:installCombineSwathHook()
    local n, entry = 0, nil
    for _, h in ipairs(W.sys.hookManager.hooks) do
        if tostring(h.name):find("ground-condition observer", 1, true) then n, entry = n + 1, h end
    end
    T.ok("I1 the swath hook installs the observer on its own and registers its cleanup",
        rawget(DensityMapHeightUtil, O.MARKER) ~= nil and n == 1 and entry ~= nil and type(entry.cleanup) == "function")
    if entry ~= nil then entry.cleanup() end
    T.eq("I2 the cleanup restores the native primitive", rawget(DensityMapHeightUtil, O.MARKER), nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. GRASS: THE ORDINARY CUT (the entry-point bar, through installAll)
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    T.ok("G0 [world] the family arms in production's order", world(100) == true)
    local v, mowers, drop = mowerInWorld()
    ENGINE.mowable[GRASS] = 400
    local okAll, errAll = installAll()
    T.ok("G1 [reached] production's installAll installed the mower birth append, the mower carrier and the swath hook in this world",
        okAll and mowers[1].processingFunction ~= Mower.processMowerArea and rawget(v, "processDropArea") ~= Mower.processDropArea
        and Mower.onEndWorkAreaProcessing ~= nil, tostring(errAll))
    local seen, restore = recordCombine()
    local birthsBefore = C.stats.births
    ENGINE.tick(v, 16)
    restore()
    T.eq("G2 [native] 400 L of fresh grass landed on the windrow line", num(windrowOnLine()) .. "/" .. num(drop.litersToDrop), "400/0")
    T.eq("G3 the fresh cut lands born today with the fresh-grass profile: age raw 1, wetness raw 204 (80% wet basis)",
        condition(8, 9) .. " " .. condition(9, 9), "1/204 1/204")
    T.eq("G4 the birth contribution carries profile FRESH_GRASS_V1, revision 1, provenance ESTIMATED_AT_BIRTH, and nothing else arrived",
        stamps(seen), "FRESH_GRASS_V1/1/ESTIMATED_AT_BIRTH")
    T.eq("G5 the generic no-record birth (noteMaterialAt) did not run on a carrier-handled frame", #births(), 0)
    T.eq("G6 the first fresh grass birth says so in the log, once, with the profile, the revision, the percentage and the raw value",
        lines(INFO, "FIRST FRESH GRASS_WINDROW BIRTH: 400.0 L born at the deposit with profile FRESH_GRASS_V1 revision 1 (80% wet basis, raw 204), provenance estimated-at-birth"), 1)
    T.eq("G7 every frame closed and the account emptied with the native remainder", tostring(O.isAtRest()) .. "/" .. num(C.accountTotal(C.accountOf(drop))), "true/0")
    ENGINE.tick(v, 16)
    T.eq("G8 a second cut births again, the line does not repeat, and still no generic birth",
        tostring(C.stats.births - birthsBefore) .. "/" .. lines(INFO, "FIRST FRESH GRASS_WINDROW BIRTH") .. "/" .. #births(), "2/1/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE GENERIC BIRTH STILL RUNS WHERE THE CARRIER DOES NOT OWN THE DEPOSIT
--    (the other side of G5, and the admitted contexts that stand it down)
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    -- The ground family is not armed: no carrier, the birth as it always was.
    world(100, { unarmed = true })
    local v = mowerInWorld({ uid = "gateOff" })
    ENGINE.mowable[GRASS] = 400
    local okAll = installAll()
    local frames = C.stats.frames
    ENGINE.tick(v, 16)
    local b = births()
    T.eq("N1 [reached] with the ground family unarmed the mower opens no frame and the generic birth records the cut strip as GRASS_WINDROW on field 7",
        tostring(okAll) .. "/" .. tostring(C.stats.frames - frames) .. "/" .. #b .. "/" .. tostring(b[1] and b[1].name) .. "/" .. tostring(b[1] and b[1].fieldId), "true/0/1/GRASS_WINDROW/7")
    T.eq("N2 and it wrote no condition: the layer has no fresh-grass profile to give", condition(8, 9) .. " " .. condition(8, 8), "0/0 0/0")

    -- StockGuard owns both the cut and the drop: the standalone frames stand aside,
    -- and the generic birth stands down with them (section 4: every admitted context).
    world(100)
    local v2, mowers2, drop2 = mowerInWorld({ uid = "leased" })
    ENGINE.mowable[GRASS] = 400
    installAll()
    local leaseCut = cutLease(v2, mowers2[1], 1)
    local leaseDrop = cutLease(v2, drop2, 6)
    T.eq("N3 [world] StockGuard holds a lease on the cut and on the drop", leaseCut.status .. "/" .. leaseDrop.status, "ADMITTED/ADMITTED")
    local f2 = C.stats.frames
    ENGINE.tick(v2, 16)
    T.eq("N4 no standalone frame opened, the native cut and drop ran, and the generic birth did NOT run: the deposit is the admission's",
        tostring(C.stats.frames - f2) .. "/" .. num(windrowOnLine()) .. "/" .. #births(), "0/400/0")
    W.sys.groundConditionAdmission:_closePrimitive(leaseCut.leaseToken)
    W.sys.groundConditionAdmission:_closePrimitive(leaseDrop.leaseToken)

    -- A frame that ran but could vouch for nothing (the barrier refused) still owns
    -- the deposit: explicit unavailable, never the generic birth.
    world(100)
    local v3 = mowerInWorld({ uid = "refusedGate" })
    ENGINE.mowable[GRASS] = 400
    installAll()
    g_currentMission.environment.currentMonotonicDay = 101
    W.sys.materialWetness.hold = true
    ENGINE.tick(v3, 16)
    T.eq("N5 under a refused barrier the frames ran, the landed cells keep their bytes and are marked unavailable, no profile was written, and no generic birth ran",
        condition(8, 9) .. "/" .. tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 9)) .. "/" .. #births(), "0/0/true/0")

    -- A stamp is one frame's: the same mower carried in one frame and, the family
    -- having stood down, not carried in the next, gets the generic birth in the next.
    world(100)
    local v4 = mowerInWorld({ uid = "stoodDown" })
    ENGINE.mowable[GRASS] = 400
    installAll()
    ENGINE.tick(v4, 16)
    local carriedBirths = #births()
    W.sys.groundConditionCoordinator.armed = false
    ENGINE.tick(v4, 16)
    T.eq("N6 a stamp from an earlier frame does not stand the generic birth down: carried frame 0 births, uncarried next frame 1",
        carriedBirths .. "/" .. #births(), "0/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. A CUT OVER AN OLD WINDROW CANNOT RESET IT
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    world(100)
    local v = mowerInWorld({ uid = "overOld" })
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    setCell(8, 8, 5, 100)
    setCell(9, 8, 5, 100)
    installAll()
    ENGINE.tick(v, 16)
    T.eq("O1 [native] the old 400 L and the fresh 400 L landed together", num(windrowOnLine()), "800")
    T.eq("O2 the windrow keeps the old windrow's age (5) and takes the wettest band present, the fresh profile's 204", condition(8, 9) .. " " .. condition(9, 9), "5/204 5/204")

    world(100)
    local v2 = mowerInWorld({ uid = "overWetter" })
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    setCell(8, 8, 5, 230)
    setCell(9, 8, 5, 230)
    installAll()
    ENGINE.tick(v2, 16)
    T.eq("O3 an old windrow wetter than the profile keeps its own band: the profile never resets an old record", condition(8, 9) .. " " .. condition(9, 9), "5/230 5/230")

    -- An old windrow of UNKNOWN condition under the cut: unknown outranks the estimate.
    world(100)
    local v3 = mowerInWorld({ uid = "overUnknown" })
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    installAll()
    ENGINE.tick(v3, 16)
    T.eq("O4 an old windrow with no record under the cut makes the mixture unknown: the profile cannot claim what it did not make", condition(8, 9) .. " " .. condition(9, 9), "0/24 0/24")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A REFUSED BARRIER WRITES EXPLICIT UNKNOWN, NEVER THE PROFILE
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    -- The cut runs under a refused barrier with the windrow line full (nothing
    -- lands); the pending output waits in the drop area as UNKNOWN. Next day the
    -- barrier passes and the line is free: what lands is unknown, not 204.
    world(100)
    local v, _, drop = mowerInWorld({ uid = "refusedCut" })
    ENGINE.mowable[GRASS] = 400
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 400)
    installAll()
    g_currentMission.environment.currentMonotonicDay = 101
    W.sys.materialWetness.hold = true
    ENGINE.tick(v, 16)
    T.eq("B1 [native] the line was full, so 400 L wait in the drop area", num(drop.litersToDrop), "400")
    T.eq("B2 the cut under a refused barrier entered the account as explicit unknown, not as the profile", accountShape(C.accountOf(drop)), "-:-:400:-")
    W.sys.materialWetness.hold = false
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 0)
    ENGINE.mowable[GRASS] = 0
    ENGINE.tick(v, 16)
    T.eq("B3 [native] the remainder dropped once the line was free", num(windrowOnLine()) .. "/" .. num(drop.litersToDrop), "400/0")
    T.eq("B4 and it landed of unknown condition (raw 0 age, the unknown wetness sentinel), never 204", condition(8, 9) .. " " .. condition(9, 9), "0/24 0/24")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. BORN AT THE DEPOSIT, NOT WHEN THE OUTPUT ENTERED THE BUFFER (section 4's last sentence)
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    world(100)
    local v, _, drop = mowerInWorld({ uid = "held" })
    ENGINE.mowable[GRASS] = 600
    -- The line has room for 400 L: 200 L of fresh output wait in the drop area.
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 350)
    installAll()
    ENGINE.tick(v, 16)
    T.eq("D1 [native] 400 L landed on the 2800 L already there and 200 L wait", num(windrowOnLine()) .. "/" .. num(drop.litersToDrop), "3200/200")
    T.eq("D2 the account holds the waiting fresh output with its profile", accountShape(C.accountOf(drop)), "1:204:200:ESTIMATED_AT_BIRTH")
    -- Two days later the remainder lands on new ground.
    g_currentMission.environment.currentMonotonicDay = 102
    drop.start.z, drop.width.z, drop.height.z = 12, 12, 13
    ENGINE.mowable[GRASS] = 0
    ENGINE.tick(v, 16)
    T.eq("D3 the remainder is born at THIS deposit: age raw 1 on day 102, not 3, with the profile", condition(8, 11) .. " " .. condition(9, 11), "1/204 1/204")
    T.eq("D4 and the account emptied with the native remainder", num(drop.litersToDrop) .. "/" .. num(C.accountTotal(C.accountOf(drop))), "0/0")

    -- A CAPTURED component in the same buffer still ages (P-GROUND-1): the old windrow
    -- picked up under a cut on day 100 lands on day 102 two days older.
    world(100)
    local v2, _, drop2 = mowerInWorld({ uid = "heldOld" })
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    setCell(8, 8, 9, 100)
    setCell(9, 8, 9, 100)
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 400)
    installAll()
    ENGINE.tick(v2, 16)
    T.eq("D5 [native] nothing landed; 800 L wait", num(drop2.litersToDrop), "800")
    g_currentMission.environment.currentMonotonicDay = 102
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 8, 7, 0)
    ENGINE.mowable[GRASS] = 0
    ENGINE.tick(v2, 16)
    T.eq("D6 the captured old windrow aged once (9 + 2 = 11), the fresh part is born today, and the wettest band is the profile's", condition(8, 9) .. " " .. condition(9, 9), "11/204 11/204")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. NO PROFILE FOR HAY OR FOR ANY OUTPUT THAT IS NOT THE ACCEPTED BRANCH
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    -- A mower whose converter makes DRYGRASS_WINDROW directly: born today, no profile.
    world(100)
    local v = mowerInWorld({ uid = "hayMaker", outputFillType = FT.DRYGRASS_WINDROW })
    ENGINE.mowable[GRASS] = 400
    installAll()
    local seen, restore = recordCombine()
    ENGINE.tick(v, 16)
    restore()
    T.eq("H1 [native] 400 L of hay landed", num(DensityMapHeightUtil.getFillLevelAtArea(FT.DRYGRASS_WINDROW, 0, 6, 8, 6, 0, 7)), "400")
    T.eq("H2 the output is born today with UNKNOWN wetness: a fill-type name alone earns no profile", condition(8, 9) .. " " .. condition(9, 9), "1/24 1/24")
    T.eq("H3 and its contribution carries no profile and no provenance", stamps(seen), "-/-/-")

    -- The straw profile is the combine swath's: a mower converter that outputs STRAW earns nothing.
    world(100)
    local vs = mowerInWorld({ uid = "strawMaker", outputFillType = FT.STRAW })
    ENGINE.mowable[GRASS] = 400
    installAll()
    ENGINE.tick(vs, 16)
    T.eq("H3b a mower whose converter outputs STRAW is born today with UNKNOWN wetness: the straw profile belongs to the combine swath's branch", condition(8, 9) .. " " .. condition(9, 9), "1/24 1/24")

    -- Native conversion inherits: a tedder turns fresh grass (1/204) into hay that keeps 204.
    world(100)
    local tedder = ENGINE.newTedder({ uid = "tedder", x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = tedder
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 8, 2, 50)
    setCell(8, 8, 1, 204)
    setCell(9, 8, 1, 204)
    installAll()
    local seen2, restore2 = recordCombine()
    ENGINE.tick(tedder, 16)
    restore2()
    T.eq("H4 [native] the tedder turned 800 L of grass into hay on the drop line", num(HEIGHT.total(FT.DRYGRASS_WINDROW)), "800")
    T.eq("H5 the hay inherits the fresh grass's condition (1/204) as moved condition, with no profile on the contribution: nothing re-seeds",
        condition(8, 9) .. " " .. condition(9, 9) .. " " .. stamps(seen2), "1/204 1/204 -/-/-")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. PROVENANCE STAYS DISTINCT; A REDISCHARGE NEVER RE-SEEDS
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    -- A windrower rakes a fresh windrow born with the profile: what it drops is the
    -- captured condition, provenance nil, and the profile is not applied again.
    world(100)
    local wind = ENGINE.newWindrower({ uid = "rake", x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = wind
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 8, 2, 50)
    setCell(8, 8, 1, 204)
    setCell(9, 8, 1, 204)
    installAll()
    local seen, restore = recordCombine()
    ENGINE.tick(wind, 16)
    restore()
    T.eq("P1 the raked windrow lands with its captured condition and no provenance: a redischarge is a move, not a birth",
        condition(8, 9) .. " " .. condition(9, 9) .. " " .. stamps(seen), "1/204 1/204 -/-/-")

    -- In one account, an estimate never merges with a captured condition of the same
    -- bytes; two estimates of the same profile do.
    world(100)
    local v, _, drop = mowerInWorld({ uid = "twoAreas", areas = 2 })
    ENGINE.mowable[GRASS] = 300
    -- An old windrow already at 1/204 under the FIRST area only, and the line full.
    oldWindrow()
    setCell(8, 8, 1, 204)
    setCell(9, 8, 1, 204)
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 16, 7, 400)
    installAll()
    ENGINE.tick(v, 16)
    T.eq("P2 both areas' fresh output merged into one estimate; the captured 1/204 stays its own component",
        accountShape(C.accountOf(drop)), "1:204:400:- 1:204:600:ESTIMATED_AT_BIRTH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. STRAW: THE COMBINE SWATH (the entry-point bar's second half)
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    T.ok("S0 [world] the family arms in production's order", world(100) == true)
    local combine, swath = combineInWorld({ uid = "combine" })
    combine.buffer.liters = 300
    local okAll, errAll = installAll()
    T.ok("S1 [reached] production's installAll wrapped the combine's captured swath pointer", okAll and swath.processingFunction ~= Combine.processCombineSwathArea, tostring(errAll))
    local seen, restore = recordCombine()
    local frames = C.stats.frames
    ENGINE.tick(combine, 16)
    restore()
    T.eq("S2 [native] 300 L of straw landed on the swath line and the buffer released it", num(HEIGHT.total(FT.STRAW)) .. "/" .. num(combine.buffer.liters), "300/0")
    T.eq("S3 the straw lands born today with the fresh-straw profile: age raw 1, wetness raw 65 (25% wet basis)", condition(8, 9) .. " " .. condition(9, 9), "1/65 1/65")
    T.eq("S4 one STRAW frame ran, and the contribution carries FRESH_STRAW_V1, revision 1, ESTIMATED_AT_BIRTH", tostring(C.stats.frames - frames) .. " " .. stamps(seen), "1 FRESH_STRAW_V1/1/ESTIMATED_AT_BIRTH")
    T.eq("S5 the generic straw birth (noteMaterialAt) did not run on a carrier-handled frame", #births(), 0)
    T.eq("S6 the first straw pass and the first fresh straw birth each say so in the log, once",
        lines(INFO, "FIRST STRAW PASS OBSERVED") .. "/" .. lines(INFO, "FIRST FRESH STRAW BIRTH: 300.0 L born at the deposit with profile FRESH_STRAW_V1 revision 1 (25% wet basis, raw 65), provenance estimated-at-birth"), "1/1")
    T.eq("S7 every frame closed", tostring(O.isAtRest()), "true")
    combine.buffer.liters = 100
    ENGINE.tick(combine, 16)
    T.eq("S8 a second pass births again onto the occupied line: still 1/65, the lines do not repeat, no generic birth",
        condition(8, 9) .. "/" .. lines(INFO, "FIRST FRESH STRAW BIRTH") .. "/" .. lines(INFO, "FIRST STRAW PASS OBSERVED") .. "/" .. #births(), "1/65/1/1/0")

    -- Straw laid over an old straw swath: the old age stays, the wettest band wins.
    world(100)
    local c2 = combineInWorld({ uid = "overOld" })
    c2.buffer.liters = 300
    HEIGHT.fill(FT.STRAW, 0, 6, 8, 7, 25)
    setCell(8, 9, 9, 40)
    setCell(9, 9, 9, 40)
    installAll()
    ENGINE.tick(c2, 16)
    T.eq("S9 fresh straw over an old swath: the old age (9) stays, the wettest band is the profile's 65", condition(8, 9) .. " " .. condition(9, 9), "9/65 9/65")

    -- A refused barrier: the frame ran, the cells keep their bytes and go unavailable,
    -- no 65 is written, and the generic birth stands down.
    world(100)
    local c3 = combineInWorld({ uid = "refused" })
    c3.buffer.liters = 300
    installAll()
    g_currentMission.environment.currentMonotonicDay = 101
    W.sys.materialWetness.hold = true
    ENGINE.tick(c3, 16)
    T.eq("S10 under a refused barrier the straw landed natively, the cells keep their bytes and are unavailable, no profile was written, no generic birth ran",
        num(HEIGHT.total(FT.STRAW)) .. "/" .. condition(8, 9) .. "/" .. tostring(W.sys.groundConditionCoordinator:isUnavailable(8, 9)) .. "/" .. #births(), "300/0/0/true/0")

    -- The ground family unarmed: no frame, and the generic straw birth as it always was.
    world(100, { unarmed = true })
    local c4 = combineInWorld({ uid = "gateOff" })
    c4.buffer.liters = 300
    installAll()
    local f4 = C.stats.frames
    ENGINE.tick(c4, 16)
    local b = births()
    T.eq("S11 [reached] with the family unarmed the combine opens no frame and the generic birth records STRAW on field 7",
        tostring(C.stats.frames - f4) .. "/" .. #b .. "/" .. tostring(b[1] and b[1].name) .. "/" .. tostring(b[1] and b[1].fieldId), "0/1/STRAW/7")

    -- A crop whose swath is not straw: born today, unknown wetness, no profile.
    world(100)
    local c5 = combineInWorld({ uid = "cane", crop = ENGINE.FRUIT.SUGARCANE })
    c5.buffer.liters = 300
    installAll()
    local seen5, restore5 = recordCombine()
    ENGINE.tick(c5, 16)
    restore5()
    T.eq("S12 a swath of another windrow type is born today with UNKNOWN wetness and no profile: the name alone earns none",
        num(HEIGHT.total(FT.DRYGRASS_WINDROW)) .. " " .. condition(8, 9) .. " " .. stamps(seen5), "300 1/24 -/-/-")

    -- The swath switched off (chopping): no deposit, no frame.
    world(100)
    local c6 = combineInWorld({ uid = "chopper", swath = false })
    c6.buffer.liters = 300
    installAll()
    local f6 = C.stats.frames
    ENGINE.tick(c6, 16)
    T.eq("S13 with the swath off nothing is dropped and no frame opens", num(HEIGHT.total(FT.STRAW)) .. "/" .. tostring(C.stats.frames - f6), "0/0")
    -- An empty buffer with the swath on: nothing to drop, no frame either.
    world(100)
    local c7 = combineInWorld({ uid = "empty" })
    installAll()
    local f7 = C.stats.frames
    ENGINE.tick(c7, 16)
    T.eq("S14 with nothing in the buffer no frame opens", C.stats.frames - f7, 0)

    -- A client's pass opens no frame.
    world(100)
    local c8 = combineInWorld({ uid = "client" })
    c8.buffer.liters = 300
    c8.isServer = false
    installAll()
    local f8 = C.stats.frames
    ENGINE.tick(c8, 16)
    T.eq("S15 a client's pass opens no frame", C.stats.frames - f8, 0)

    -- A native error inside the swath reaches the engine unchanged; every frame closes.
    world(100)
    local c9 = combineInWorld({ uid = "boom" })
    c9.buffer.liters = 300
    installAll()
    HEIGHT.throwNext = true
    local okT, errT = pcall(ENGINE.tick, c9, 16)
    T.eq("S16 a native error inside the swath reaches the engine unchanged and every frame closes",
        tostring(okT) .. "/" .. tostring(errT ~= nil and tostring(errT):find("native tip failed", 1, true) ~= nil) .. "/" .. tostring(O.isAtRest()), "false/true/true")

    -- A combine added later through VehicleSystem.addVehicle is carried too.
    world(100)
    installAll()
    local late, lateSwath = ENGINE.newCombine({ uid = "late", x0 = 16, swathZ = 6 })
    g_currentMission.vehicleSystem:addVehicle(late)
    late.buffer.liters = 200
    ENGINE.tick(late, 16)
    T.eq("S17 a combine added later is wrapped by the same hook and births with the profile", tostring(lateSwath.processingFunction ~= Combine.processCombineSwathArea) .. "/" .. condition(12, 9), "true/1/65")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENCODER IS MATERIALWETNESS'S OWN
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    T.eq("E1 the profiles encode through MaterialWetness.pctToRaw: 80 is 204, 25 is 65",
        tostring(C.profileWetnessRaw(C.PROFILES.FRESH_GRASS)) .. "/" .. tostring(C.profileWetnessRaw(C.PROFILES.FRESH_STRAW)), "204/65")
    -- Without the encoder a birth is known in age and unknown in wetness, never a
    -- number this module invents; said once in the log.
    local real = MaterialWetness.pctToRaw
    MaterialWetness.pctToRaw = nil
    world(100)
    local v = mowerInWorld({ uid = "noEncoder" })
    ENGINE.mowable[GRASS] = 400
    installAll()
    local warnBefore = lines(WARN, "cannot be encoded")
    local seen, restore = recordCombine()
    ENGINE.tick(v, 16)
    restore()
    MaterialWetness.pctToRaw = real
    T.eq("E2 with no encoder the fresh cut is born today with unknown wetness, no profile or provenance is claimed, and the log says so once",
        condition(8, 9) .. "/" .. stamps(seen) .. "/" .. (lines(WARN, "profile FRESH_GRASS_V1 cannot be encoded") - warnBefore), "1/24/-/-/-/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE ENVIRONMENT IS THE MOD'S OWN
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    world(100)
    local v = mowerInWorld({ uid = "env" })
    installAll()
    ENGINE.tick(v, 16)
    T.eq("V1 [world] the sources run in a mod-shaped environment: _G is the mod's own table, rawget(_G, 'g_updateLoopIndex') is nil, and the plain read reaches the engine's counter through __index",
        tostring(_G ~= nil and rawget(_G, "g_updateLoopIndex") == nil) .. "/" .. type(g_updateLoopIndex) .. "/" .. tostring(getmetatable(_G) ~= nil and getmetatable(_G).__index ~= nil), "true/number/true")
    -- The model advances the counter at the END of a tick (main.lua:777), so the
    -- stamp the carrier set during the tick names the frame just processed.
    T.eq("V2 and the carrier's stamp reads the counter the way a mod can: the mower carried in the frame just processed carries that frame's index",
        tostring(rawget(v, C.HANDLED_KEY) == g_updateLoopIndex - 1), "true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. NO WARNINGS OR ERRORS LEAKED FROM ANY GROUP
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    -- installAll's own lines about engine classes this bench does not model are not
    -- the family's; the family's prefixes are the ones counted.
    local leaked = {}
    for _, w in ipairs(WARN) do
        if not w:find("cannot be encoded", 1, true)
           and (w:find("[GroundCarrier]", 1, true) or w:find("[MowerCarrier]", 1, true) or w:find("[SwathHook]", 1, true)
                or w:find("[GroundObserver]", 1, true) or w:find("[MowerHook]", 1, true) or w:find("[GroundCoord]", 1, true)
                or w:find("ERROR", 1, true)) then
            leaked[#leaked + 1] = w
        end
    end
    T.eq("X1 no ground-family warning or error was raised across the bar", #leaked == 0 and "none" or table.concat(leaked, " | "), "none")
end)

T.summary()
