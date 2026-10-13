-- MAINT-172-vehicle_routes_entry_spec_test.lua
--
-- MAINTENANCE row 172, the R8 residual: every hook reaches a vehicle bought later
-- through ONE VehicleSystem.addVehicle class wrap (RSF-F226 v0.3 item 2), and each tears
-- down what it installed, only where it is still ours (GROUND-CONDITION-CONTRACT v1.5
-- section 3 / RSF-F208 for the windrower and the mower carrier; RSF-F211 :58, :106 for
-- the baler and the forage wagon).
--
-- THE ENTRY-POINT BAR IS GROUP E. Production enters through HookManager:installAll, run
-- here for real and in full, on a vehicle system that is a Class instance of VehicleSystem
-- (ENGINE.newVehicleSystem: VehicleSystem.lua:3, :6, :160-179). One of each vehicle is
-- then BOUGHT: built the way the engine builds it (the type's functions copied into the
-- instance, each work area's pointer captured: the F208 and F211 models) and registered
-- with the colon call Vehicle.lua:1044 makes. Nothing here wraps a slot, fills a record or
-- registers a route by hand, except group T's one probe route, which says so.
--
-- This world has no Sprayer class, so the sprayer gate does not install. The six routes
-- reaching the bought vehicles anyway is Bob's condition 1: the shared wrap needs no
-- specialization. The gate as one route among them is R8's group E.
--
-- Groups:
--   E  one of each bought: its slot carries its own site's wrapper and record
--   R  a refused add (a unique id already registered) wraps nothing, for all six sites
--   T  a route that throws: the others still apply and the add's true is forwarded
--   K  one site's teardown row alone: its route stops, the wrap keeps serving the others
--   C  the wrap's own teardown row alone: left inactive under a foreign class wrap, the
--      engine's method put back when nothing sits above it
--   D  teardown through SoilFertilitySystem:delete(): restored where still ours, left and
--      passed through under a foreign wrap, the copied instance functions the same, a
--      reinstall with no second layer, and nothing for a vehicle bought after
--   L  the Baler's four class listeners (MAINTENANCE row 189): restored only where still
--      ours, a later mod's wrap over them kept, ours a pass-through inside it
--
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua

local WARN = {}
SoilLogger.info = function() end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

-- The engine's mod-listener registry, which installAll and uninstallAll call.
addModEventListener = addModEventListener or function() end
removeModEventListener = removeModEventListener or function() end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- Class hooks persist across worlds (installAll wraps the same class tables again), so
-- every world restores the Baler's listeners and Bale.register before installing, as the
-- F211 bar does. Each group also tears its install down before the next world.
local PRISTINE = { register = Bale.register, start = Baler.onStartWorkAreaProcessing, finish = Baler.onEndWorkAreaProcessing,
                   fill = Baler.onFillUnitFillLevelChanged, delete = Bale.delete, tick = Baler.onUpdateTick }
local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local function world(today)
    today = today or 100
    HEIGHT.pixels = {}
    BALER_MODEL.failLoad, BALER_MODEL.onRegister = false, nil
    Bale.register, Bale.delete = PRISTINE.register, PRISTINE.delete
    Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing = PRISTINE.start, PRISTINE.finish
    Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick = PRISTINE.fill, PRISTINE.tick
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    W.sys = sys
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = ENGINE.newVehicleSystem(),
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
    }
    W.nativeAdd = VehicleSystem.addVehicle
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    local okMd = sys.materialDown:arm(vm)
    sys.materialDown.ageAppliedThroughDay = today
    local okMw = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    local okHb = sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    local okYl = sys.yardLadder:arm(sys.materialDown, sys.materialWetness, sys.hayBet)
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    sys.yardLadder:onMissionStarted()
    return (okMd and okMw and okHb and okYl and a and b and c) == true
end
local function installAll() return pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys) end

-- The six kinds, each built the way the engine builds it, and the slot its site wraps.
local KINDS = {
    { site = "tedder", fn = "processTedderArea", native = function() return Tedder.processTedderArea end,
      build = function(uid) local v, work = ENGINE.newTedder({ uid = uid, x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = 6 }) return v, work end },
    { site = "windrower", fn = "processWindrowerArea", native = function() return Windrower.processWindrowerArea end,
      build = function(uid) local v, work = ENGINE.newWindrower({ uid = uid, x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = 6 }) return v, work end },
    { site = "mower carrier", fn = "processMowerArea", native = function() return Mower.processMowerArea end,
      build = function(uid) local v, mowers = ENGINE.newMower({ uid = uid, x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = 6 }) return v, mowers[1] end },
    { site = "combine swath", fn = "processCombineSwathArea", native = function() return Combine.processCombineSwathArea end,
      build = function(uid) local v, swath = ENGINE.newCombine({ uid = uid, x0 = 0, swathZ = 6 }) return v, swath end },
    { site = "baler collection", fn = "processBalerArea", native = function() return Baler.processBalerArea end,
      build = function(uid) local v, work = BALER_MODEL.new({ uid = uid, x0 = -22, z0 = 1, width = 4, depth = 2 }) return v, work end },
    { site = "forage wagon collection", fn = "processForageWagonArea", native = function() return ForageWagon.processForageWagonArea end,
      build = function(uid) local v, work = BALER_MODEL.newWagon({ uid = uid, x0 = -22, z0 = 1, width = 4, depth = 2 }) return v, work end },
}
local function kind(site) for _, k in ipairs(KINDS) do if k.site == site then return k end end end

--- Buy one: build it, then Vehicle.lua:1044's colon call.
local function buy(k, uid)
    local v, work = k.build(uid)
    local added = g_currentMission.vehicleSystem:addVehicle(v)
    return v, work, added
end
local function recordOf(k, work) return HookManager.workAreaRecord(work, k.fn) end
--- Does this slot carry exactly its own site's one wrapper, over the captured pointer?
local function carries(k, work)
    local rec = recordOf(k, work)
    return rec ~= nil and rec.active == true and work.processingFunction == rec.wrapper
        and rec.site == k.site and rec.predecessor == k.native()
end
local function wrapOf(v, marker, name)
    local wraps = rawget(v, marker)
    return wraps ~= nil and wraps[name] or nil
end

-- Carrier frames opened, counted at GroundMovementCarrier.begin (the slot wrappers call
-- it through the module table, so the count sees every frame).
local FRAMES = 0
local realBegin = GroundMovementCarrier.begin
GroundMovementCarrier.begin = function(...) FRAMES = FRAMES + 1 return realBegin(...) end

-- ══════════════════════════════════════════════════════════════════════════
-- E. FROM PRODUCTION'S ENTRY POINT: ONE OF EACH, BOUGHT
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    T.ok("E0 [world] the family arms in production's order", world())
    local ok, err = installAll()
    T.eq("E1 installAll ran to its end (" .. tostring(err) .. ")", ok and W.sys.hookManager.installed, true)
    local vs = g_currentMission.vehicleSystem
    T.ok("E2 no hook wrote the live instance field; the class method is wrapped",
         rawget(vs, "addVehicle") == nil and VehicleSystem.addVehicle ~= W.nativeAdd)
    local names = {}
    for _, r in ipairs(W.sys.hookManager._vehicleRoutes or {}) do names[#names + 1] = r.name end
    T.eq("E3 six routes on the one wrap, in installAll's order, and no Sprayer spec in this world",
         table.concat(names, ",") .. "/" .. tostring(Sprayer),
         "tedder,windrower,mower carrier,combine swath,baler collection,forage wagon collection/nil")
    local bought = {}
    for _, k in ipairs(KINDS) do
        local v, work, added = buy(k, "bought " .. k.site)
        bought[k.site] = { v = v, work = work }
        T.ok("E4 a bought " .. k.site .. ": the colon call registered it, true forwarded, and its captured slot carries its site's one wrapper over the engine's pointer",
             added == true and carries(k, work))
    end
    local mower = bought["mower carrier"].v
    local drop = wrapOf(mower, "_sfMowerDropWrap", "processDropArea")
    T.ok("E5 the bought mower's copied processDropArea is wrapped, the wrapper recorded beside the original",
         drop ~= nil and rawget(mower, "processDropArea") == drop.wrapper and drop.original == Mower.processDropArea)
    local baler = bought["baler collection"].v
    local fin, cre = wrapOf(baler, "_sfBalerWraps", "finishBale"), wrapOf(baler, "_sfBalerWraps", "createBale")
    T.ok("E6 the bought baler's copied finishBale and createBale are wrapped and recorded",
         fin ~= nil and cre ~= nil and rawget(baler, "finishBale") == fin.wrapper and rawget(baler, "createBale") == cre.wrapper
         and fin.original == Baler.finishBale and cre.original == Baler.createBale)
    local wagon = bought["forage wagon collection"].v
    local fill = wrapOf(wagon, "_sfForageWagonWraps", "fillForageWagon")
    T.ok("E7 the bought wagon's copied fillForageWagon is wrapped and recorded",
         fill ~= nil and rawget(wagon, "fillForageWagon") == fill.wrapper and fill.original == ForageWagon.fillForageWagon)
    local before = FRAMES
    ENGINE.tick(bought.tedder.v, 16)
    T.eq("E8 and it RUNS: one pass of the bought tedder opens one carrier frame", FRAMES - before, 1)
    W.sys:delete()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. A REFUSED ADD WRAPS NOTHING
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    world()
    installAll()
    for _, k in ipairs(KINDS) do
        local _, _, first = buy(k, "taken " .. k.site)
        local twin, twinWork, again = buy(k, "taken " .. k.site)   -- VehicleSystem.lua:165-168
        local instanceWrapped = rawget(twin, "_sfMowerDropWrap") ~= nil or rawget(twin, "_sfBalerWraps") ~= nil
            or rawget(twin, "_sfForageWagonWraps") ~= nil
        T.ok("R1 a refused " .. k.site .. " (a unique id already registered): false forwarded, and neither its slot nor a copied function wrapped",
             first == true and again == false and recordOf(k, twinWork) == nil
             and twinWork.processingFunction == k.native() and not instanceWrapped)
    end
    W.sys:delete()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. A ROUTE THAT THROWS
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    world()
    installAll()
    -- The one hand-made route in this file: a probe that always throws, put first so
    -- every real route runs after it.
    local routes = W.sys.hookManager._vehicleRoutes
    table.insert(routes, 1, { name = "probe", active = true, fn = function() error("the probe route fails", 0) end })
    WARN = {}
    local tedderK, wagonK = kind("tedder"), kind("forage wagon collection")
    -- Protected, so an add that raised reads as a failed row, not a crashed group.
    local okT, _, tWork, tAdded = pcall(buy, tedderK, "after probe tedder")
    local okW, _, wWork, wAdded = pcall(buy, wagonK, "after probe wagon")
    T.ok("T1 the add neither raises nor loses its true past a throwing route",
         okT and okW and tAdded == true and wAdded == true)
    T.ok("T2 and the routes after it still wrapped the first and the last site",
         okT and okW and carries(tedderK, tWork) and carries(wagonK, wWork))
    local probeLines = 0
    for _, l in ipairs(WARN) do if l:find("probe", 1, true) then probeLines = probeLines + 1 end end
    T.eq("T3 the failing route is logged once, not once per vehicle", probeLines, 1)
    W.sys:delete()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. ONE SITE'S TEARDOWN ROW, ALONE
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    -- Each site's row switches its own route off; the wrap's row switches only the wrap
    -- off. Run alone, the tedder's row must stop the tedder's route while the wrap keeps
    -- serving the windrower.
    world()
    local mgr = setmetatable({ hooks = {} }, { __index = HookManager })
    local okR = mgr:installVehicleRoutes()
    local okT, okW = mgr:installTedderHook(), mgr:installWindrowerHook()
    T.ok("K0 the wrap, the tedder and the windrower install on their own", okR and okT and okW)
    local tedderRow = nil
    for _, row in ipairs(mgr.hooks) do
        if row.name == "processTedderArea work-area slots (tedder)" then tedderRow = row end
    end
    T.ok("K1 the tedder registered its teardown row", tedderRow ~= nil and type(tedderRow.cleanup) == "function")
    if tedderRow ~= nil then tedderRow.cleanup() end
    local tK, wK = kind("tedder"), kind("windrower")
    local _, tWork, tAdded = buy(tK, "after row tedder")
    local _, wWork = buy(wK, "after row windrower")
    T.ok("K2 after the tedder's row alone, a bought tedder is registered and not wrapped",
         tAdded == true and recordOf(tK, tWork) == nil and tWork.processingFunction == tK.native())
    T.ok("K3 and the wrap still serves the windrower", carries(wK, wWork))
    for i = #mgr.hooks, 1, -1 do if mgr.hooks[i].cleanup then mgr.hooks[i].cleanup() end end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE WRAP'S OWN TEARDOWN ROW, ALONE
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    -- Driven through the wrap's row alone, because installAll's older harvest row
    -- restores VehicleSystem.addVehicle unconditionally (pre-existing, out of scope,
    -- RSF-F226 item 5), and the site rows would switch their routes off anyway.
    world()
    local mgr = setmetatable({ hooks = {} }, { __index = HookManager })
    mgr:installVehicleRoutes()
    mgr:installTedderHook()
    local wrapRow = nil
    for _, row in ipairs(mgr.hooks) do
        if row.name == "VehicleSystem.addVehicle (later-vehicle routes)" then wrapRow = row end
    end
    local ours = VehicleSystem.addVehicle
    local foreignAdd = function(self, vehicle, ...) return ours(self, vehicle, ...) end
    VehicleSystem.addVehicle = foreignAdd
    T.ok("C0 the wrap registered its teardown row", wrapRow ~= nil)
    if wrapRow ~= nil then wrapRow.cleanup() end
    T.ok("C1 a foreign class wrap above ours survives the wrap's teardown", VehicleSystem.addVehicle == foreignAdd)
    local tK = kind("tedder")
    local v, work = tK.build("through foreign")
    -- The class chain, as Vehicle.lua:1044's colon call resolves it.
    local added = g_currentMission.vehicleSystem:addVehicle(v)
    T.ok("C2 and ours, still under it and gone inactive, passes the add through and runs no route",
         added == true and recordOf(tK, work) == nil)

    world()
    local mgr2 = setmetatable({ hooks = {} }, { __index = HookManager })
    mgr2:installVehicleRoutes()
    for i = #mgr2.hooks, 1, -1 do mgr2.hooks[i].cleanup() end
    T.ok("C3 with nothing above it, the wrap's row puts the engine's class method back", VehicleSystem.addVehicle == W.nativeAdd)
    for i = #mgr.hooks, 1, -1 do if mgr.hooks[i] ~= wrapRow then mgr.hooks[i].cleanup() end end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. TEARDOWN THROUGH SoilFertilitySystem:delete()
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    -- The windrower's native pointer, counted where the engine copies it from: its
    -- builder copies the class function into the instance (Vehicle.lua:486).
    local nativeWindrower = Windrower.processWindrowerArea
    local windrowerCalls = 0
    Windrower.processWindrowerArea = function(...) windrowerCalls = windrowerCalls + 1 return nativeWindrower(...) end
    local wK = kind("windrower")
    wK.native = function() return Windrower.processWindrowerArea end

    world()
    installAll()
    local v, work = {}, {}
    for _, k in ipairs(KINDS) do
        v[k.site], work[k.site] = buy(k, "kept " .. k.site)
    end
    -- A foreign mod wraps over two of ours after they were installed.
    local ourWindrower = work.windrower.processingFunction
    local foreignCalls = 0
    local foreignSlot = function(...) foreignCalls = foreignCalls + 1 return ourWindrower(...) end
    work.windrower.processingFunction = foreignSlot
    local baler = v["baler collection"]
    local ourFinish = rawget(baler, "finishBale")
    local foreignFinish = function(...) return ourFinish(...) end
    rawset(baler, "finishBale", foreignFinish)
    local windrowerRecord = recordOf(wK, work.windrower)

    W.sys:delete()

    local restoredSlots = true
    for _, k in ipairs(KINDS) do
        if k.site ~= "windrower" then
            restoredSlots = restoredSlots and work[k.site].processingFunction == k.native() and recordOf(k, work[k.site]) == nil
        end
    end
    T.ok("D1 teardown restored every slot still ours to the exact captured pointer and dropped its record (tedder, mower, combine, baler, wagon)", restoredSlots)
    T.ok("D2 it left the windrower's slot to the foreign wrap and kept its record, inactive",
         work.windrower.processingFunction == foreignSlot and recordOf(wK, work.windrower) == windrowerRecord
         and windrowerRecord.active == false)
    local frames, calls = FRAMES, windrowerCalls
    foreignCalls = 0
    work.windrower.processingFunction(v.windrower, work.windrower, 16)
    T.eq("D3 a pass through the left slot: the foreign wrap once, the captured pointer once, no Soil carrier frame",
         foreignCalls .. "/" .. (windrowerCalls - calls) .. "/" .. (FRAMES - frames), "1/1/0")
    local mower = v["mower carrier"]
    T.ok("D4 the mower's copied processDropArea is the engine's again and its record is gone",
         rawget(mower, "processDropArea") == Mower.processDropArea and rawget(mower, "_sfMowerDropWrap") == nil)
    local wagon = v["forage wagon collection"]
    T.ok("D5 the wagon's copied fillForageWagon is the engine's again and its record is gone",
         rawget(wagon, "fillForageWagon") == ForageWagon.fillForageWagon and rawget(wagon, "_sfForageWagonWraps") == nil)
    T.ok("D6 the baler's createBale, still ours, is the engine's again; its finishBale, wrapped over by a foreign mod, is left and stays recorded",
         rawget(baler, "createBale") == Baler.createBale and wrapOf(baler, "_sfBalerWraps", "createBale") == nil
         and rawget(baler, "finishBale") == foreignFinish and wrapOf(baler, "_sfBalerWraps", "finishBale") ~= nil)
    T.ok("D7 the class method is the engine's own again", VehicleSystem.addVehicle == W.nativeAdd)
    local tK = kind("tedder")
    local _, lateWork, lateAdded = buy(tK, "after teardown")
    T.ok("D8 a tedder bought after teardown is registered and carries nothing",
         lateAdded == true and recordOf(tK, lateWork) == nil and lateWork.processingFunction == tK.native())

    -- The next savegame in the same process installs again over the same vehicles.
    local hm2 = HookManager.new()
    local okRe, errRe = pcall(hm2.installAll, hm2, W.sys)
    T.eq("D9 a reinstall ran (" .. tostring(errRe) .. ")", okRe and hm2.installed, true)
    T.ok("D10 the restored tedder is wrapped again, once: its record's predecessor is the engine's pointer",
         carries(tK, work.tedder))
    T.ok("D11 the left windrower's SAME record is reactivated, under the same foreign wrap: one Soil layer",
         recordOf(wK, work.windrower) == windrowerRecord and windrowerRecord.active == true
         and work.windrower.processingFunction == foreignSlot)
    frames, calls = FRAMES, windrowerCalls
    work.windrower.processingFunction(v.windrower, work.windrower, 16)
    T.eq("D12 so one pass opens one carrier frame and reaches the captured pointer once", (FRAMES - frames) .. "/" .. (windrowerCalls - calls), "1/1")
    local fin, cre = wrapOf(baler, "_sfBalerWraps", "finishBale"), wrapOf(baler, "_sfBalerWraps", "createBale")
    T.ok("D13 the baler's createBale is wrapped again; its finishBale is not wrapped a second time under the foreign one",
         cre ~= nil and rawget(baler, "createBale") == cre.wrapper and cre.original == Baler.createBale
         and rawget(baler, "finishBale") == foreignFinish and fin ~= nil and fin.wrapper == ourFinish)
    hm2:uninstallAll()

    Windrower.processWindrowerArea = nativeWindrower
    wK.native = function() return Windrower.processWindrowerArea end
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE BALER'S CLASS LISTENERS: RESTORED ONLY WHERE STILL OURS (MAINTENANCE row 189)
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    world()
    -- The engine's end listener (the model's Baler:onEndWorkAreaProcessing), counted.
    local nativeEnd, endCalls = PRISTINE.finish, 0
    Baler.onEndWorkAreaProcessing = function(...) endCalls = endCalls + 1 return nativeEnd(...) end
    local countedEnd = Baler.onEndWorkAreaProcessing
    installAll()
    local ourStart, ourEnd = Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing
    local ourFill, ourTick = Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick
    T.ok("L0 [reached] installAll put Soil's four class listeners on Baler",
         ourStart ~= PRISTINE.start and ourEnd ~= countedEnd and ourFill ~= PRISTINE.fill and ourTick ~= PRISTINE.tick)
    local baler = buy(kind("baler collection"), "L baler")
    -- A later mod (SG2-5's StockGuard Baler wraps) wraps over two of ours.
    local foreignCalls = 0
    local foreignEnd = function(...) foreignCalls = foreignCalls + 1 return ourEnd(...) end
    local foreignTick = function(...) return ourTick(...) end
    Baler.onEndWorkAreaProcessing, Baler.onUpdateTick = foreignEnd, foreignTick
    -- Soil's collection work, counted at the module functions the listeners call.
    local aroundCalls, realAround = 0, BalerCollection.aroundEnd
    BalerCollection.aroundEnd = function(...) aroundCalls = aroundCalls + 1 return realAround(...) end
    local soil = { start = 0, fill = 0, tick = 0 }
    local realOnStart, realFill, realTick = BalerCollection.onStart, BalerCollection.aroundFillChange, BalerCollection.aroundTick
    BalerCollection.onStart = function(...) soil.start = soil.start + 1 return realOnStart(...) end
    BalerCollection.aroundFillChange = function(...) soil.fill = soil.fill + 1 return realFill(...) end
    BalerCollection.aroundTick = function(...) soil.tick = soil.tick + 1 return realTick(...) end
    Baler.onEndWorkAreaProcessing(baler, 16, true)
    T.eq("L1 [reached] before teardown one end event runs the foreign wrap, Soil's collection and the engine's listener once each",
         foreignCalls .. "/" .. aroundCalls .. "/" .. endCalls, "1/1/1")

    W.sys:delete()

    T.ok("L2 teardown put the engine's own back where the listener was still ours (start, fill change)",
         Baler.onStartWorkAreaProcessing == PRISTINE.start and Baler.onFillUnitFillLevelChanged == PRISTINE.fill)
    T.ok("L3 THE WRAPS A LATER MOD INSTALLED OVER OURS SURVIVE THE TEARDOWN (end, tick)",
         Baler.onEndWorkAreaProcessing == foreignEnd and Baler.onUpdateTick == foreignTick)
    foreignCalls, aroundCalls, endCalls = 0, 0, 0
    Baler.onEndWorkAreaProcessing(baler, 16, true)
    T.eq("L4 an end event through the left chain: the foreign wrap once, the engine's listener once, Soil's collection not at all",
         foreignCalls .. "/" .. aroundCalls .. "/" .. endCalls, "1/0/1")
    Baler.onUpdateTick(baler, 16)
    T.eq("L4b an update tick through the left chain does no Soil transfer", soil.tick, 0)

    -- The next savegame in the same process installs again over the same chain.
    local hm2 = HookManager.new()
    local okRe, errRe = pcall(hm2.installAll, hm2, W.sys)
    T.eq("L5 a reinstall ran (" .. tostring(errRe) .. ")", okRe and hm2.installed, true)
    foreignCalls, aroundCalls, endCalls = 0, 0, 0
    Baler.onEndWorkAreaProcessing(baler, 16, true)
    T.eq("L6 one active Soil layer above the foreign wrap: Soil's collection, the foreign wrap and the engine's listener once each",
         foreignCalls .. "/" .. aroundCalls .. "/" .. endCalls, "1/1/1")
    -- This time the later mod wraps the other two, over the reinstall's listeners.
    local ourStart2, ourFill2 = Baler.onStartWorkAreaProcessing, Baler.onFillUnitFillLevelChanged
    local foreignStart = function(...) return ourStart2(...) end
    local foreignFill = function(...) return ourFill2(...) end
    Baler.onStartWorkAreaProcessing, Baler.onFillUnitFillLevelChanged = foreignStart, foreignFill
    hm2:uninstallAll()
    T.ok("L7 the reinstall's teardown kept the start and fill-change wraps above it, and gave end and tick back to the first foreign wraps",
         Baler.onStartWorkAreaProcessing == foreignStart and Baler.onFillUnitFillLevelChanged == foreignFill
         and Baler.onEndWorkAreaProcessing == foreignEnd and Baler.onUpdateTick == foreignTick)
    soil.start, soil.fill = 0, 0
    Baler.onStartWorkAreaProcessing(baler, 16)
    Baler.onFillUnitFillLevelChanged(baler, 1, 0, FillType.UNKNOWN, ToolType.UNDEFINED, nil, 0)
    T.eq("L8 a start and a fill change through the left chains do no Soil work", soil.start .. "/" .. soil.fill, "0/0")
    BalerCollection.aroundEnd = realAround
    BalerCollection.onStart, BalerCollection.aroundFillChange, BalerCollection.aroundTick = realOnStart, realFill, realTick
end)

GroundMovementCarrier.begin = realBegin
