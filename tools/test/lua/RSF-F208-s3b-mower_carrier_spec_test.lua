-- RSF-F208-s3b-mower_carrier_spec_test.lua
--
-- RSF-F208, contract section 3, slice S2b: the Mower carrier. A mower's fresh cut and
-- any old dry windrow it picks up under the cut join ONE pending mixture on the shared
-- auxiliary drop area (Mower.lua:358-367), capped at 1000 L, and land later when the
-- end of processing drops that area (:562-566, :383-405). The ground's age and wetness
-- must follow: the old windrow's condition travels, the fresh cut is born at the
-- deposit with the fresh-grass profile (RSF-F212, raw 204; its own bar is
-- RSF-F212-fresh_birth_spec_test.lua), a cap loss discards condition uniformly and
-- never re-creates it, and a captured remainder waits in the drop area and ages once.
--
-- THE ENTRY-POINT BAR IS GROUP M. Production enters through SoilFertilitySystem.new,
-- the ground family armed in production's order (SoilFertilitySystem.lua:339-346) and
-- HookManager:installMowerCarrierHook, which installs the observer, wraps the mower's
-- CAPTURED work-area pointer and its processDropArea INSTANCE copy. A pass is the
-- engine's order (ENGINE.tick): the class's onStartWorkAreaProcessing reset, each
-- captured pointer, then the class's onEndWorkAreaProcessing calling the instance copy.
-- Nothing here opens a frame, writes an account or places a projection by hand.
--
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

local INFO = {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function() end

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
local function world(today)
    HEIGHT.pixels = {}
    ENGINE.mowable = {}
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = { vehicles = {} } }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    return a and b and c
end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return ENGINE.layerGet(W.age, gx, gz) .. "/" .. ENGINE.layerGet(W.wet, gx, gz) end
--- A mower in the mission's vehicle list: its cut strip x 0..8*areas, z 0..2, its
--- drop line at z = dropZ.
local function mowerInWorld(opts)
    opts = opts or {}
    local v, mowers, drop = ENGINE.newMower({ uid = opts.uid or "mower", x0 = opts.x0 or 0, z0 = 0, width = 8, depth = 2,
        dropZ = opts.dropZ or 6, areas = opts.areas, noDrop = opts.noDrop })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, mowers, drop
end
--- An old dry windrow under the first cut strip: 400 L over cells (8,8) and (9,8).
local function oldWindrow() HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 25) end
local function firstLines(kind)
    local n = 0
    for _, line in ipairs(INFO) do if line:find("FIRST " .. kind .. " PASS OBSERVED", 1, true) then n = n + 1 end end
    return n
end
--- An account's components as "age:wetness:litres", oldest last.
local function accountShape(acc)
    local parts = {}
    for _, comp in ipairs(acc.components) do parts[#parts + 1] = comp end
    table.sort(parts, function(a, b) return (a.ageRaw or 0) < (b.ageRaw or 0) end)
    local out = {}
    for _, comp in ipairs(parts) do
        out[#out + 1] = tostring(comp.ageRaw or "-") .. ":" .. tostring(comp.wetnessRaw or "-") .. ":" .. num(comp.litres)
    end
    return table.concat(out, " ")
end
local function observerCleanups(hm)
    local n, entry = 0, nil
    for _, h in ipairs(hm.hooks) do
        if tostring(h.name):find("ground-condition observer", 1, true) then n, entry = n + 1, h end
    end
    return n, entry
end

-- ══════════════════════════════════════════════════════════════════════════
-- I. THE MOWER HOOK INSTALLS THE OBSERVER ITSELF
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    world(100)
    T.eq("I0 [world] nothing has wrapped the primitive yet in this process", rawget(DensityMapHeightUtil, O.MARKER), nil)
    W.sys.hookManager:installMowerCarrierHook()
    local n, entry = observerCleanups(W.sys.hookManager)
    T.ok("I1 the mower hook installs the observer on its own and registers its cleanup",
        rawget(DensityMapHeightUtil, O.MARKER) ~= nil and n == 1 and entry ~= nil and type(entry.cleanup) == "function")
    W.sys.hookManager:installWindrowerHook()
    T.eq("I2 a hook installed after it finds the observer in place and registers no second cleanup", (observerCleanups(W.sys.hookManager)), 1)
    if entry ~= nil then entry.cleanup() end
    T.eq("I3 the cleanup restores the native primitive", rawget(DensityMapHeightUtil, O.MARKER), nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. THE ORDINARY PASS (the entry-point bar)
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    T.ok("M0 [world] the family arms in production's order", world(100) == true)
    local v, mowers, drop = mowerInWorld()
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    setCell(8, 8, 5, 100)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installMowerCarrierHook()
    T.ok("M1 the hook wrapped the captured cut pointer and the drop area's instance copy",
        mowers[1].processingFunction ~= Mower.processMowerArea and rawget(v, "processDropArea") ~= Mower.processDropArea)
    ENGINE.tick(v, 16)
    local under = DensityMapHeightUtil.getFillLevelAtArea(FT.DRYGRASS_WINDROW, 0, 0, 8, 0, 0, 2)
    local windrow = DensityMapHeightUtil.getFillLevelAtArea(FT.GRASS_WINDROW, 0, 6, 8, 6, 0, 7)
    T.eq("M2 [native] the cut took the old windrow up and dropped 400 fresh + 400 old on the windrow line",
        num(under) .. "/" .. num(windrow) .. "/" .. num(drop.litersToDrop), "0/800/0")
    T.eq("M3 the windrow carries the old windrow's age and the wettest band present, the fresh cut's profile (RSF-F212)", condition(8, 9) .. " " .. condition(9, 9), "5/204 5/204")
    T.eq("M4 the old windrow's cells under the cut are cleared", condition(8, 8) .. " " .. condition(9, 8), "0/0 0/0")
    T.eq("M5 every frame closed and the drop area's account emptied with the native remainder",
        tostring(O.isAtRest()) .. "/" .. num(C.accountTotal(C.accountOf(drop))), "true/0")
    T.eq("M6 the first observed mower pass says so in the log, once", firstLines("MOWER"), 1)

    -- Fresh cut alone, dropped onto new ground.
    drop.start.z, drop.width.z, drop.height.z = 12, 12, 13
    ENGINE.tick(v, 16)
    T.eq("M7 fresh cut alone lands born today (age raw 1) with the fresh-grass profile (raw 204, RSF-F212)", condition(8, 11) .. " " .. condition(9, 11), "1/204 1/204")
    T.eq("M8 the log line does not repeat", firstLines("MOWER"), 1)

    -- A mower added later through VehicleSystem.addVehicle is carried too.
    local late = ENGINE.newMower({ uid = "late", x0 = 16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem:addVehicle(late)
    ENGINE.tick(late, 16)
    T.eq("M9 a mower added later is carried by the same hook", condition(12, 9) .. "/" .. tostring(rawget(late, "processDropArea") ~= Mower.processDropArea), "1/204/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE CAP LOSS, THE SHARED DROP AREA AND THE REMAINDER
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    world(100)
    local v, mowers, drop = mowerInWorld({ uid = "wide", areas = 2 })
    ENGINE.mowable[GRASS] = 600
    -- An old dry windrow under the FIRST area only: 400 L, 9 days old, band 200.
    oldWindrow()
    setCell(8, 8, 9, 200)
    setCell(9, 8, 9, 200)
    -- The windrow line is nearly full: 16 pixels with 50 L of room each.
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 16, 7, 350)
    W.sys.hookManager:installMowerCarrierHook()
    ENGINE.tick(v, 16)
    T.eq("C1 [native] two cuts of 600 L plus the old 400 L hit the 1000 L cap; 800 L dropped, 200 L remain", num(drop.litersToDrop), "200")
    local acc = C.accountOf(drop)
    T.eq("C2 both areas fed ONE account, and the cap loss and the short drop took condition uniformly: 3 fresh to 1 old",
        accountShape(acc), "1:204:150 9:200:50")
    T.eq("C3 the account IS the native remainder: the 600 L cap loss was never re-created", num(C.accountTotal(acc)), "200")

    -- Two days later, with nothing cut, the remainder drops onto the freed line.
    g_currentMission.environment.currentMonotonicDay = 102
    HEIGHT.fill(FT.GRASS_WINDROW, 0, 6, 16, 7, 0)
    ENGINE.mowable[GRASS] = 0
    ENGINE.tick(v, 16)
    T.eq("C4 the remainder lands with its captured stamp aged ONCE: the oldest is 9 + 2 = 11; the wettest band is the fresh profile's", condition(8, 9) .. " " .. condition(11, 9), "11/204 11/204")
    T.eq("C5 and the account empties with the native remainder", num(drop.litersToDrop) .. "/" .. num(C.accountTotal(acc)), "0/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE DIRECT-TO-FILLUNIT BRANCH IS NOT A GROUND DEPOSIT
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    world(100)
    local v = mowerInWorld({ uid = "tank", noDrop = true })
    ENGINE.mowable[GRASS] = 300
    oldWindrow()
    setCell(8, 8, 5, 100)
    W.sys.hookManager:installMowerCarrierHook()
    local frames = C.stats.frames
    ENGINE.tick(v, 16)
    T.eq("F1 [native] with no drop area the cut goes straight into the mower's fill unit", num(v.fill.level) .. "/" .. v.fill.calls, "300/1")
    T.eq("F2 no frame opens, and the ground under the cut keeps its record", tostring(C.stats.frames - frames) .. "/" .. condition(8, 8), "0/5/100")

    -- A drop index naming an area that is not AUXILIARY is no drop area to the native
    -- (Mower.lua:417-421), so it is none to the carrier either.
    world(100)
    local odd, oddMowers = mowerInWorld({ uid = "odd" })
    oddMowers[1].dropAreaIndex = oddMowers[1].index
    ENGINE.mowable[GRASS] = 300
    W.sys.hookManager:installMowerCarrierHook()
    local f3 = C.stats.frames
    ENGINE.tick(odd, 16)
    T.eq("F3 a drop index naming a non-AUXILIARY area opens no frame", C.stats.frames - f3, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. THE DROP WRAP IS THE MOWER'S OWN
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    world(100)
    local v = mowerInWorld({ uid = "foreign" })
    local foreign = function(self, dropArea, dt) return Mower.processDropArea(self, dropArea, dt) end
    v.processDropArea = foreign
    local tedder = ENGINE.newTedder({ uid = "tedder", x0 = -16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = tedder
    W.sys.hookManager:installMowerCarrierHook()
    T.eq("D1 a processDropArea another mod replaced is left in place", rawget(v, "processDropArea") == foreign, true)
    T.eq("D2 a tedder's processDropArea of the same name is not the mower hook's to wrap", rawget(tedder, "processDropArea") == Tedder.processDropArea, true)
    local twin = mowerInWorld({ uid = "twin", x0 = 16 })
    W.sys.hookManager:installMowerCarrierHook()
    T.eq("D3 [twin] a native mower's copy is wrapped by the same sweep", rawget(twin, "processDropArea") ~= Mower.processDropArea, true)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. REFUSALS
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    world(100)
    local v, mowers, drop = mowerInWorld({ uid = "leased" })
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    setCell(8, 8, 5, 100)
    setCell(9, 8, 5, 100)
    W.sys.hookManager:installMowerCarrierHook()
    local lease = W.sys.groundConditionAdmission:_admitPrimitive({ schemaVersion = 1, kind = "LINE", sx = 0, sz = 1, ex = 8, ez = 1, fillTypeIndex = FT.GRASS_WINDROW, innerRadius = 1, radius = 1 }, GroundConditionAdmission.KIND_TIP_LINE, v, mowers[1])
    local frames = C.stats.frames
    ENGINE.tick(v, 16)
    T.eq("R1 with a live lease on the cut, the cut opens no frame: only the drop does, and what it drops is of unknown condition",
        tostring(C.stats.frames - frames) .. "/" .. condition(8, 9), "1/0/24")
    W.sys.groundConditionAdmission:_closePrimitive(lease.leaseToken)

    world(100)
    local v2 = mowerInWorld({ uid = "boom" })
    ENGINE.mowable[GRASS] = 400
    oldWindrow()
    W.sys.hookManager:installMowerCarrierHook()
    HEIGHT.throwNext = true
    local okT, errT = pcall(ENGINE.tick, v2, 16)
    T.eq("R2 a native error inside the cut reaches the engine unchanged and every frame closes",
        tostring(okT) .. "/" .. tostring(errT ~= nil and tostring(errT):find("native tip failed", 1, true) ~= nil) .. "/" .. tostring(O.isAtRest()), "false/true/true")

    world(100)
    local v2b, _, drop2b = mowerInWorld({ uid = "boomDrop" })
    ENGINE.mowable[GRASS] = 400
    W.sys.hookManager:installMowerCarrierHook()
    HEIGHT.throwOnDrop = true
    local okD, errD = pcall(ENGINE.tick, v2b, 16)
    T.eq("R2b one inside the drop does too, the frame closes, and the pending litres stay the native's",
        tostring(okD) .. "/" .. tostring(errD ~= nil and tostring(errD):find("native tip failed", 1, true) ~= nil) .. "/" .. tostring(O.isAtRest()) .. "/" .. num(drop2b.litersToDrop),
        "false/true/true/400")

    world(100)
    local v3 = mowerInWorld({ uid = "client" })
    ENGINE.mowable[GRASS] = 400
    v3.isServer = false
    W.sys.hookManager:installMowerCarrierHook()
    local f3 = C.stats.frames
    ENGINE.tick(v3, 16)
    T.eq("R3 a client's pass opens no frame", C.stats.frames - f3, 0)

    world(100)
    local v4 = mowerInWorld({ uid = "off" })
    ENGINE.mowable[GRASS] = 400
    W.sys.hookManager:installMowerCarrierHook()
    g_SoilFertilityManager.settings.enabled = false
    local f4 = C.stats.frames
    ENGINE.tick(v4, 16)
    T.eq("R4 with the mod switched off the mower opens no frame", C.stats.frames - f4, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. PRODUCTION'S installAll IS WHAT INSTALLS THE CARRIERS (last: it also installs
--    class-level hooks, among them the mower birth append, that the groups above
--    must not see)
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    world(100)
    local v, mowers = mowerInWorld({ uid = "all" })
    local tedder, tWork = ENGINE.newTedder({ uid = "allTedder", x0 = -16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    local wind, wWork = ENGINE.newWindrower({ uid = "allWindrower", x0 = 16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = tedder
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = wind
    local okAll, errAll = pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys)
    T.ok("A1 [reached] production's installAll ran in this world", okAll, tostring(errAll))
    T.eq("A2 and it installed all three ground carriers: the mower's cut pointer and drop copy, the tedder's and the windrower's pointers",
        tostring(mowers[1].processingFunction ~= Mower.processMowerArea) .. "/" .. tostring(rawget(v, "processDropArea") ~= Mower.processDropArea)
        .. "/" .. tostring(tWork.processingFunction ~= Tedder.processTedderArea) .. "/" .. tostring(wWork.processingFunction ~= Windrower.processWindrowerArea),
        "true/true/true/true")
end)
