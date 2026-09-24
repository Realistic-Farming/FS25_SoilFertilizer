-- RSF-F208-s3b-windrower_carrier_spec_test.lua
--
-- RSF-F208, contract section 3, slice S2b: the Windrower carrier. A windrower rakes
-- material into a windrow; the ground's age and wetness must follow it to the windrow.
-- It differs from the tedder in one way that matters: its drop request is only the
-- CURRENT pickup (Windrower.lua:350-357), and its accumulating litersToDrop is never
-- dropped again. So nothing it fails to drop is a remainder: it is native loss, and
-- its condition must never ride into a later drop.
--
-- THE ENTRY-POINT BAR IS GROUP W. Production enters through SoilFertilitySystem.new,
-- the ground family armed in production's order (SoilFertilitySystem.lua:339-346) and
-- HookManager:installWindrowerHook, which installs the observer and wraps the
-- windrower's CAPTURED work-area pointer. A pass is the engine's order: the class's
-- onStartWorkAreaProcessing reset (Windrower.lua:285-292), the captured pointer, the
-- native processWindrowerArea and processDropArea bodies. Nothing here opens a frame
-- or places a projection by hand.
--
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

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
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    return a and b and c
end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return ENGINE.layerGet(W.age, gx, gz) .. "/" .. ENGINE.layerGet(W.wet, gx, gz) end
local function windrowerInWorld(uid, dropZ)
    local v, work, drop = ENGINE.newWindrower({ uid = uid or "windrower", x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = dropZ or 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, work, drop
end
--- Tedded dry grass lying on the raking strip: 800 L over cells (8,8) and (9,8).
local function hay() HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 50) end
local function firstLines(kind)
    local n = 0
    for _, line in ipairs(INFO) do if line:find("FIRST " .. kind .. " PASS OBSERVED", 1, true) then n = n + 1 end end
    return n
end

-- ══════════════════════════════════════════════════════════════════════════
-- I. THE WINDROWER HOOK INSTALLS THE OBSERVER ITSELF
-- ══════════════════════════════════════════════════════════════════════════
-- First in this process, before any tedder hook: the windrower must not depend on
-- another installer having wrapped the primitive for it.
group("I", function()
    world(100)
    T.eq("I0 [world] nothing has wrapped the primitive yet in this process", rawget(DensityMapHeightUtil, O.MARKER), nil)
    W.sys.hookManager:installWindrowerHook()
    T.ok("I1 the windrower hook installs the observer on its own", rawget(DensityMapHeightUtil, O.MARKER) ~= nil)
    local function observerCleanups(hm)
        local n, entry = 0, nil
        for _, h in ipairs(hm.hooks) do
            if tostring(h.name):find("ground-condition observer", 1, true) then n, entry = n + 1, h end
        end
        return n, entry
    end
    local n, entry = observerCleanups(W.sys.hookManager)
    T.ok("I2 and registers a cleanup for the observer it installed", n == 1 and entry ~= nil and type(entry.cleanup) == "function")
    W.sys.hookManager:installTedderHook()
    T.eq("I3 a tedder hook installed after it finds the observer in place and registers no second cleanup", (observerCleanups(W.sys.hookManager)), 1)
    if entry ~= nil then entry.cleanup() end
    T.eq("I4 the cleanup restores the native primitive", rawget(DensityMapHeightUtil, O.MARKER), nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE ORDINARY PASS
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    T.ok("W0 [world] the family arms in production's order", world(100) == true)
    local v, work = windrowerInWorld()
    hay()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    -- A tedder works elsewhere first, so the windrower's own first-pass line has to
    -- be its own and not the tedder's.
    local tedder = ENGINE.newTedder({ uid = "tedder", x0 = -16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = tedder
    HEIGHT.fill(FT.GRASS_WINDROW, -16, 0, -8, 2, 50)
    W.sys.hookManager:installTedderHook()
    ENGINE.tick(tedder, 16)
    T.eq("W0b [reached] the tedder's pass logged its own first-pass line", firstLines("TEDDER"), 1)
    W.sys.hookManager:installWindrowerHook()
    T.ok("W1 the hook installed the observer and wrapped the captured pointer",
        rawget(DensityMapHeightUtil, O.MARKER) ~= nil and work.processingFunction ~= Windrower.processWindrowerArea)
    ENGINE.tick(v, 16)
    local strip = DensityMapHeightUtil.getFillLevelAtArea(FT.DRYGRASS_WINDROW, 0, 0, 8, 0, 0, 2)
    T.eq("W2 [native] the pass raked the 800 L off the strip into the windrow", tostring(strip) .. "/" .. tostring(work.lastDroppedLiters), "0/800.0")
    T.eq("W3 the windrow cells carry the oldest age and wettest band of what was raked", condition(8, 9) .. " " .. condition(9, 9), "5/100 5/100")
    T.eq("W4 the raked-clean source cells are cleared", condition(8, 8) .. " " .. condition(9, 8), "0/0 0/0")
    T.eq("W5 the frame closed", O.isAtRest(), true)
    T.eq("W6 the first observed windrower pass says so in the log, once", firstLines("WINDROWER"), 1)
    ENGINE.tick(v, 16)
    T.eq("W7 and does not repeat it", firstLines("WINDROWER"), 1)

    -- A windrower added later through VehicleSystem.addVehicle is carried too.
    local late, lateWork = ENGINE.newWindrower({ uid = "late", x0 = 16, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem:addVehicle(late)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 16, 0, 24, 2, 50)
    setCell(12, 8, 7, 80)
    setCell(13, 8, 7, 80)
    ENGINE.tick(late, 16)
    T.eq("W8 a windrower added later is carried by the same wrapper", condition(12, 9) .. "/" .. tostring(lateWork.processingFunction ~= Windrower.processWindrowerArea), "7/80/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. WHAT IT DOES NOT DROP IS LOSS, NOT A REMAINDER
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    world(100)
    local v, work, drop = windrowerInWorld()
    hay()
    setCell(8, 8, 9, 200)
    setCell(9, 8, 9, 200)
    -- The windrow strip is nearly full: 8 pixels with 50 L of room each.
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 6, 8, 7, 350)
    W.sys.hookManager:installWindrowerHook()
    ENGINE.tick(v, 16)
    T.eq("L1 [native] the drop fell short: 400 of 800 placed, and the native total keeps growing", tostring(work.lastDroppedLiters) .. "/" .. tostring(work.litersToDrop), "400/400")
    -- Later: new material with a younger record is raked onto an empty strip.
    drop.start.z, drop.width.z, drop.height.z = 12, 12, 13
    HEIGHT.fill(FT.DRYGRASS_WINDROW, 0, 0, 8, 2, 50)
    setCell(8, 8, 2, 40)
    setCell(9, 8, 2, 40)
    ENGINE.tick(v, 16)
    T.eq("L2 [native] the native accumulator still carries the loss it will never drop", work.litersToDrop, 400)
    T.eq("L3 only the current pickup's condition lands: the lost 9-day material does not ride on", condition(8, 11), "2/40")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. REFUSALS (the shared carrier; one row each for the windrower's wrapper)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    world(100)
    local v, work = windrowerInWorld()
    hay()
    setCell(8, 8, 3, 60)
    W.sys.hookManager:installWindrowerHook()
    local lease = W.sys.groundConditionAdmission:_admitPrimitive({ schemaVersion = 1, kind = "LINE", sx = 0, sz = 1, ex = 8, ez = 1, fillTypeIndex = FT.GRASS_WINDROW, innerRadius = 1, radius = 1 }, GroundConditionAdmission.KIND_TIP_LINE, v, work)
    local frames = C.stats.frames
    ENGINE.tick(v, 16)
    T.eq("R1 with a live StockGuard lease the windrower opens no frame and projects nothing", tostring(C.stats.frames - frames) .. "/" .. condition(8, 9), "0/0/0")
    W.sys.groundConditionAdmission:_closePrimitive(lease.leaseToken)

    world(100)
    local v2 = windrowerInWorld("v2")
    hay()
    setCell(8, 8, 3, 60)
    W.sys.hookManager:installWindrowerHook()
    HEIGHT.throwNext = true
    local okT, errT = pcall(ENGINE.tick, v2, 16)
    T.eq("R2 a native error reaches the engine unchanged and the frame closes", tostring(okT) .. "/" .. tostring(errT ~= nil and tostring(errT):find("native tip failed", 1, true) ~= nil) .. "/" .. tostring(O.isAtRest()), "false/true/true")

    world(100)
    local v3 = windrowerInWorld("v3")
    hay()
    setCell(8, 8, 3, 60)
    v3.isServer = false
    W.sys.hookManager:installWindrowerHook()
    local f3 = C.stats.frames
    ENGINE.tick(v3, 16)
    T.eq("R3 a client's pass opens no frame", C.stats.frames - f3, 0)

    world(100)
    local v4 = windrowerInWorld("v4")
    hay()
    W.sys.hookManager:installWindrowerHook()
    g_SoilFertilityManager.settings.enabled = false
    local f4 = C.stats.frames
    ENGINE.tick(v4, 16)
    T.eq("R4 with the mod switched off the windrower opens no frame", C.stats.frames - f4, 0)
end)
