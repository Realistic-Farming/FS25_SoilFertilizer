-- RSF-F226-R8-permanent_gate_entry_spec_test.lua
--
-- R8: the RSF-F226 permanent processor gate, from production's entry point.
--
-- THE ENTRY-POINT BAR IS GROUP E. Production enters through HookManager:installAll,
-- run here for real and in full, on a vehicle system that is a Class instance of
-- VehicleSystem (VehicleSystem.lua:3, :6). installAll's own order puts the tedder,
-- windrower, mower carrier and swath hooks after the gate, and each of them writes
-- the live instance field vehicleSystem.addVehicle, which shadows the class method
-- (class.lua:13-16). A sprayer is then BOUGHT: built the way the engine builds one
-- (the type's functions copied into the instance, Vehicle.lua:486; the work area's
-- pointer captured from the instance, WorkArea.lua:257-266) and registered with the
-- colon call Vehicle.lua:1044 makes. Nothing in this file wraps a slot by hand, and
-- nothing pre-fills a record: the gate on a bought sprayer is there only if the
-- class wrap was installed where the instance chain bottoms out on it.
--
-- Every pass is dispatched as WorkArea does it (WorkArea.lua:124-206): the start
-- event, raised unconditionally; each captured pointer, a dot call whose first
-- return is compared with a number; the end event, skipped when a processor throws.
-- The engine side is a MODEL written against the decompile (cited per function);
-- updateSprayArea is a C function, so the paint is a count.
--
-- Groups:
--   E  the gate reaches a bought sprayer through installAll and addVehicle
--   B  a blocked pass: every effect checked in the same pass (Iris's same-pass rule)
--   X  the discriminating case: a processor error, then fresh ground
--   F  finding 2: a sprayer drained through another processor is never refused
--   I  identity: failed adds, repeated adds, a foreign wrap, teardown, reinstall
--   U  unchanged: a client, overlap prevention off, an untracked product, no sections
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

SoilLogger.debug = function() end
SoilLogger.info = function() end
SoilLogger.warning = function() end

local function group(tag, fn)
    local ok, err = pcall(fn)
    T.eq(tag .. "x the group ran to its end without a Lua error", ok and "clean" or tostring(err), "clean")
end

-- ── The engine model ────────────────────────────────────────────────────────

FillType = { UNKNOWN = 0, LIQUIDFERTILIZER = 41, FERTILIZER = 42, HERBICIDE = 43 }
ToolType = { UNDEFINED = 0 }
MoneyType = { PURCHASE_FERTILIZER = "PURCHASE_FERTILIZER" }
SprayType = {}   -- the spray-type effects hook copies it on a remapped pass
local NAMES = {}
for name, index in pairs(FillType) do NAMES[index] = name end
addModEventListener = function() end
removeModEventListener = function() end

local NATIVE

--- Sprayer:processSprayerArea, Sprayer.lua:314-340.
local function nativeProcessSprayerArea(self, _workArea, _dt)
    NATIVE.calls = NATIVE.calls + 1
    local wap = self.spec_sprayer.workAreaParameters
    if self:getIsAIActive() and self.isServer
       and (wap.sprayFillType == nil or wap.sprayFillType == FillType.UNKNOWN) then
        NATIVE.stops = NATIVE.stops + 1                                         -- :317
        return 0, 0
    end
    if wap.sprayFillLevel <= 0 then return 0, 0 end                            -- :320-322
    NATIVE.paints = NATIVE.paints + 1                                          -- :330, MODELED
    wap.isActive = true                                                        -- :331
    return 250, 3                                                              -- :339
end

--- Sprayer:getExternalFill, Sprayer.lua:383-465, the fertilizer branch (it charges).
local function nativeGetExternalFill(self, fillType, dt)
    if (fillType == FillType.FERTILIZER or fillType == FillType.LIQUIDFERTILIZER or fillType == FillType.UNKNOWN)
       and g_currentMission.missionInfo.helperBuyFertilizer then
        if fillType == FillType.UNKNOWN then fillType = FillType.FERTILIZER end
        local usage = self:getSprayerUsage(fillType, dt)
        if self.isServer then
            g_currentMission:addMoney(-usage * 1.5, self:getActiveFarm(), MoneyType.PURCHASE_FERTILIZER)
        end
        return fillType, usage
    end
    return FillType.UNKNOWN, 0
end

--- Sprayer:onStartWorkAreaProcessing, Sprayer.lua:855-937 (no fill-type sources, no
--- animations: this bar's sprayers carry their own tank or buy externally).
local function nativeOnStart(self, dt)
    local spec = self.spec_sprayer
    local fui = self:getSprayerFillUnitIndex()
    local sprayVehicle, sprayVehicleFillUnitIndex = nil, nil
    local fillType = self:getFillUnitFillType(fui)
    local usage = self:getSprayerUsage(fillType, dt)
    local sprayFillLevel = self:getFillUnitFillLevel(fui)
    if sprayFillLevel > 0 then
        sprayVehicle, sprayVehicleFillUnitIndex = self, fui
    end
    local isExternallyFilled = self:getIsSprayerExternallyFilled()
    local externalFillType, externalUsage
    if isExternallyFilled and self:getIsTurnedOn() then
        externalFillType, externalUsage = self:getExternalFill(fillType, dt)      -- :889
        if externalFillType == FillType.UNKNOWN then
            externalUsage = sprayFillLevel
            externalFillType = fillType
        else
            sprayVehicle, sprayVehicleFillUnitIndex = nil, nil
            usage = externalUsage
        end
    else
        externalUsage = sprayFillLevel
        externalFillType = fillType
    end
    local wap = spec.workAreaParameters                                         -- :925-935
    wap.sprayType = externalFillType
    wap.sprayFillType = externalFillType
    wap.sprayFillLevel = externalUsage
    wap.usage = usage
    wap.sprayVehicle = sprayVehicle
    wap.sprayVehicleFillUnitIndex = sprayVehicleFillUnitIndex
    wap.isActive = false
end

--- Sprayer:onEndWorkAreaProcessing, Sprayer.lua:938-958: the drain is server only and
--- only for a pass whose processor set isActive.
local function nativeOnEnd(self, _dt)
    local wap = self.spec_sprayer.workAreaParameters
    if self.isServer and wap.isActive then
        if wap.sprayVehicle ~= nil then
            wap.sprayVehicle:addFillUnitFillLevel(self:getOwnerFarmId(), wap.sprayVehicleFillUnitIndex,
                -wap.usage, wap.sprayFillType, ToolType.UNDEFINED, nil)          -- :950
        end
    end
end

--- FertilizingSowingMachine:processSowingMachineArea, the part that matters here
--- (FertilizingSowingMachine.lua:105): it sets the SPRAYER's isActive from its own
--- processor, so the tank drains through Sprayer.lua:940-950 with no
--- processSprayerArea area anywhere on the vehicle.
local function nativeProcessSowingMachineArea(self, _workArea, _dt)
    NATIVE.seederCalls = NATIVE.seederCalls + 1
    local wap = self.spec_sprayer.workAreaParameters
    if wap.sprayFillLevel > 0 then wap.isActive = true end
    return 250, 3
end

--- A processor on the same vehicle that throws once when told to: the engine's
--- loop has no pcall (WorkArea.lua:183), so the end event (:206) is skipped.
local function extraProcessor(self, _workArea, _dt)
    if self._throwOnce then
        self._throwOnce = nil
        error("a processor error", 0)
    end
    return 0, 0
end

--- One frame of WorkArea:onUpdateTick (WorkArea.lua:124-206). Returns every
--- processor's (first, second) return and whether the loop completed.
local function tick(v, dt)
    dt = dt or 16
    g_currentMission.time = g_currentMission.time + dt
    Sprayer.onStartWorkAreaProcessing(v, dt)                                    -- :126
    local results = {}
    local ok = pcall(function()
        for i, wa in ipairs(v.spec_workArea.workAreas) do
            local xs, second = wa.processingFunction(v, wa, dt)                 -- :182-183
            results[i] = { xs, second }
            if xs > 0 then results[i].positive = true end                       -- :184
        end
    end)
    if ok then Sprayer.onEndWorkAreaProcessing(v, dt, true) end                 -- :206
    return results, ok
end

-- ── The world ───────────────────────────────────────────────────────────────

local W

--- Soil's own manager, as SoilFertilitySystem makes it, with the field lookup and
--- the display sweep answered (neither is under test).
local function newManager()
    local hm = HookManager.new()
    hm.getFieldIdAtWorldPosition = function() return 7 end
    hm.getBoomCellPositions = function() return { { x = 10, z = 10 } } end
    hm.getBoomLineEndpoints = function() return nil end
    return hm
end

--- A fresh world and a full installAll. Engine classes are rebuilt every time,
--- because installAll wraps the class tables it finds.
--- `beforeInstall`: runs once the world exists, before installAll (a savegame's
--- vehicles are loaded and registered by then).
local function world(opts)
    opts = opts or {}
    NATIVE = { calls = 0, paints = 0, stops = 0, seederCalls = 0, money = 0, charges = 0 }

    Utils = {   -- utils/Utils.lua:380-402, as they are
        appendedFunction = function(oldFunc, newFunc)
            return oldFunc ~= nil and function(...) oldFunc(...) newFunc(...) end or newFunc
        end,
        prependedFunction = function(oldFunc, newFunc)
            return oldFunc ~= nil and function(...) newFunc(...) oldFunc(...) end or newFunc
        end,
        overwrittenFunction = function(oldFunc, newFunc)
            return function(self, ...) return newFunc(self, oldFunc, ...) end
        end,
    }
    g_effectManager = { startEffects = function() end, stopEffects = function() end }
    g_fillTypeManager = {
        getFillTypeByName = function(_, n) local i = FillType[n] if i then return { index = i, name = n } end return nil end,
        getFillTypeByIndex = function(_, i) local n = NAMES[i] if n then return { index = i, name = n } end return nil end,
        getFillTypeIndexByName = function(_, n) return FillType[n] end,
        getFillTypeNameByIndex = function(_, i) return NAMES[i] end,
    }
    g_sprayTypeManager = {
        getSprayTypeByFillTypeIndex      = function() return { litersPerSecond = 1 } end,
        getSprayTypeIndexByFillTypeIndex = function(_, ft) return ft end,
        -- no base spray types by name: registerCustomSprayTypes returns early, not under test
        getSprayTypeByName = function() return nil end,
    }
    g_farmManager = { updateFarmStats = function() end }

    -- VehicleSystem.lua:1-6 and :160-179. The method lives on the class; the
    -- mission's instance reaches it through __index.
    VehicleSystem = {}
    local VehicleSystem_mt = Class(VehicleSystem)
    function VehicleSystem.new()
        local self = setmetatable({}, VehicleSystem_mt)
        self.vehicles = {}
        self.vehicleByUniqueId = {}
        return self
    end
    function VehicleSystem:addVehicle(vehicle)
        if vehicle == nil or vehicle.isVehicle ~= true then return false end                -- :161-164
        if self.vehicleByUniqueId[vehicle.uniqueId] ~= nil then return false end            -- :165-168
        table.insert(self.vehicles, vehicle)
        self.vehicleByUniqueId[vehicle.uniqueId] = vehicle
        return true                                                                          -- :178
    end

    -- The processor-route hooks installAll installs around the gate.
    Cutter = { onEndWorkAreaProcessing = function() end }
    Combine = { addCutterArea = function() return 0 end, processCombineSwathArea = function() return 0, 0 end }
    Tedder = { processTedderArea = function() return 0, 0 end }
    Windrower = { processWindrowerArea = function() return 0, 0 end }
    Mower = { processMowerArea = function() return 0, 0 end, processDropArea = function() return 0, 0 end }
    Sprayer = {
        onStartWorkAreaProcessing = nativeOnStart,
        onEndWorkAreaProcessing = nativeOnEnd,
        processSprayerArea = nativeProcessSprayerArea,
        getExternalFill = nativeGetExternalFill,
    }
    -- finalizeTypes: the type tables read the CLASS functions at boot, before any hook.
    g_vehicleTypeManager = { types = {
        sprayer = { specializationsByName = { sprayer = true, workArea = true },
                    functions = { processSprayerArea = Sprayer.processSprayerArea,
                                  getExternalFill = Sprayer.getExternalFill,
                                  processExtraArea = extraProcessor } },
        seeder  = { specializationsByName = { sprayer = true, sowingMachine = true, workArea = true },
                    functions = { processSowingMachineArea = nativeProcessSowingMachineArea,
                                  getExternalFill = Sprayer.getExternalFill } },
    } }

    local seen = { fertilizer = 0, coverage = 0 }
    local soilSys = {
        fieldData = { [7] = { sessionCoverageCells = { ["1:1"] = true }, sessionCoverageFraction = 0.5 } },
        onFertilizerApplied = function() seen.fertilizer = seen.fertilizer + 1 return true end,
        trackSprayerCoverage = function() seen.coverage = seen.coverage + 1 end,
        markBoomCells = function() end, paintBoomStrip = function() end,
        applyBurnEffect = function() end, applyScorchEffect = function() end,
        onHerbicideAppliedDirect = function() end, onInsecticideAppliedDirect = function() end,
        onFungicideAppliedDirect = function() end,
    }
    g_currentMission = {
        time = 100000,
        vehicleSystem = VehicleSystem.new(),
        missionInfo = { helperBuyFertilizer = opts.buy == true, helperSlurrySource = 1, helperManureSource = 1 },
        addMoney = function(_, amount) NATIVE.money = NATIVE.money + amount NATIVE.charges = NATIVE.charges + 1 end,
    }
    g_SoilFertilityManager = {
        settings = { enabled = true, overlapPrevention = opts.overlap ~= false, debugMode = false,
                     multiTankApplication = false },
        soilSystem = soilSys,
    }

    W = { seen = seen, soilSys = soilSys, nativeAdd = VehicleSystem.addVehicle }
    if opts.beforeInstall then opts.beforeInstall() end

    local hm = newManager()
    local ok, err = pcall(hm.installAll, hm, soilSys)
    W.hm, W.installOk, W.installErr = hm, ok and hm.installed == true, err
    return W
end

--- A sprayer the way the engine builds one. `kind` picks the vehicle type;
--- `areas` the work areas' registered function names, captured in order.
local function build(opts)
    opts = opts or {}
    local tank = { level = opts.level or 900, fillType = opts.fillType or FillType.FERTILIZER }
    if tank.level <= 0 then tank.fillType = FillType.UNKNOWN end
    local v = { isVehicle = true, uniqueId = opts.uid or "sprayer", id = opts.uid or "sprayer",
                isServer = opts.client ~= true, _sfRootX = 10, _sfRootZ = 10, tank = tank }
    -- Vehicle.lua:486: the type's functions, raw copies, before any onLoad
    for name, fn in pairs(g_vehicleTypeManager.types[opts.kind or "sprayer"].functions) do v[name] = fn end
    v.getSprayerFillUnitIndex = function() return 1 end
    v.getFillUnitFillType = function(self) return self.tank.fillType end
    v.getFillUnitLastValidFillType = function(self) return self.tank.fillType end
    v.getFillUnitFillLevel = function(self) return self.tank.level end
    v.getFillUnitAllowsFillType = function() return true end
    v.addFillUnitFillLevel = function(self, _farmId, _fui, delta)
        self.tank.level = self.tank.level + delta
        return delta
    end
    v.getSprayerUsage = function() return 12 end
    v.getIsSprayerExternallyFilled = function() return opts.buy == true end
    v.getIsTurnedOn = function() return true end
    v.getIsAIActive = function() return opts.buy == true end
    v.getActiveFarm = function() return 1 end
    v.getOwnerFarmId = function() return 1 end
    v.getLastTouchedFarmlandFarmId = function() return 1 end
    v.getActiveSprayType = function() return nil end
    v.getLastSpeed = function() return 8 end
    v.setSprayerAITerrainDetailProhibitedRange = function() end
    v.rootVehicle = v
    v.spec_sprayer = { workAreaParameters = { sprayFillType = FillType.UNKNOWN, sprayFillLevel = 0, usage = 0,
                                             isActive = false },
                       effects = {}, sprayTypes = {} }
    if opts.sections ~= false then
        v.spec_variableWorkWidth = { sections = { { isActive = true } } }
    end
    -- WorkArea.lua:257-266: each area's pointer is captured from the instance
    v.spec_workArea = { workAreas = {} }
    for _, name in ipairs(opts.areas or { "processSprayerArea" }) do
        local wa = { functionName = name }
        wa.processingFunction = v[name]
        table.insert(v.spec_workArea.workAreas, wa)
    end
    return v
end

--- Buy a sprayer: build it, then Vehicle.lua:1044's colon call.
local function buy(opts)
    local v = build(opts)
    local added = g_currentMission.vehicleSystem:addVehicle(v)
    return v, added
end

local function setCoverage(fraction) W.soilSys.fieldData[7].sessionCoverageFraction = fraction end
local function gateRecord(v, i)
    local wa = v.spec_workArea.workAreas[i or 1]
    return wa._sfWraps and wa._sfWraps.processSprayerArea or nil, wa
end
--- What one pass did, read from the engine and from Soil's two downstream credits.
local function snapshot(v)
    return { tank = v.tank.level, calls = NATIVE.calls, paints = NATIVE.paints, money = NATIVE.money,
             charges = NATIVE.charges, fert = W.seen.fertilizer, cov = W.seen.coverage }
end
local function delta(a, b) local d = {} for k, x in pairs(b) do d[k] = x - a[k] end return d end

-- ══════════════════════════════════════════════════════════════════════════
-- E. FROM PRODUCTION'S ENTRY POINT: A BOUGHT SPRAYER CARRIES THE GATE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local before
    world({ beforeInstall = function()
        -- in the savegame: loaded and registered before the hooks install
        before = build({ uid = "loaded" })
        g_currentMission.vehicleSystem:addVehicle(before)
    end })
    T.eq("E0 installAll ran to its end (" .. tostring(W.installErr) .. ")", W.installOk, true)
    local vs = g_currentMission.vehicleSystem
    T.ok("E1 the later hooks wrote the live instance field, so the class method is shadowed",
         rawget(vs, "addVehicle") ~= nil and getmetatable(vs).__index == VehicleSystem)

    local v, added = buy({ uid = "bought", areas = { "processSprayerArea", "processExtraArea" } })
    T.eq("E2 the colon call registered the bought sprayer, its return forwarded", added, true)
    T.ok("E2b and the vehicle system holds it", vs.vehicleByUniqueId.bought == v)
    local rec, wa = gateRecord(v)
    T.ok("E3 THE BOUGHT SPRAYER'S CAPTURED SLOT CARRIES THE GATE",
         rec ~= nil and rec.active == true and wa.processingFunction == rec.wrapper
         and rec.site == HookManager.SPRAYER_GATE_SITE)
    T.ok("E4 over the pointer the engine captured, not a class or type function",
         rec ~= nil and rec.predecessor == g_vehicleTypeManager.types.sprayer.functions.processSprayerArea)
    T.eq("E5 an area of another name on the same sprayer carries none", v.spec_workArea.workAreas[2]._sfWraps, nil)
    local rec0, wa0 = gateRecord(before)
    T.ok("E6 the sprayer present at install got it through the install sweep",
         rec0 ~= nil and rec0.active == true and wa0.processingFunction == rec0.wrapper)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A BLOCKED PASS, EVERY EFFECT IN THE SAME PASS
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    world()
    local v = buy({ uid = "tank" })
    setCoverage(0.5)
    local s0 = snapshot(v)
    local r1 = tick(v)
    local d1 = delta(s0, snapshot(v))
    T.eq("B1 an unblocked pass reaches native once, paints, and drains the tank by its usage",
         d1.calls .. "/" .. d1.paints .. "/" .. d1.tank .. "/" .. r1[1][1], "1/1/-12/250")
    T.ok("B1b and Soil credits nutrients and coverage, so this fixture reaches both", d1.fert > 0 and d1.cov > 0)

    setCoverage(1.0)
    local s1 = snapshot(v)
    local r2 = tick(v)
    local d2 = delta(s1, snapshot(v))
    T.eq("B2 BLOCKED: native is never called", d2.calls, 0)
    T.eq("B3 the captured pointer returned native's own refusal pair", r2[1][1] .. "/" .. r2[1][2], "0/0")
    T.eq("B4 the tank did not move", d2.tank, 0)
    T.eq("B5 nothing was painted", d2.paints, 0)
    T.eq("B6 no nutrients were credited", d2.fert, 0)
    T.eq("B7 no coverage was credited", d2.cov, 0)
    T.eq("B8 nothing was charged", d2.charges, 0)
    T.eq("B9 and the pass reads as refused through the one predicate", HookManager.isOverlapBlockedPass(v), true)
end)

group("B-buy", function()
    -- The same pass in buy mode: the helper buys from an empty tank, billed at :889.
    world({ buy = true })
    local v = buy({ uid = "helper", level = 0, buy = true })
    setCoverage(0.5)
    local s0 = snapshot(v)
    tick(v)
    local d1 = delta(s0, snapshot(v))
    T.ok("B10 an unblocked buy-mode pass is charged and paints", d1.charges > 0 and d1.paints == 1)
    setCoverage(1.0)
    local s1 = snapshot(v)
    local r = tick(v)
    local d2 = delta(s1, snapshot(v))
    T.eq("B11 BLOCKED in buy mode: no call, the refusal pair, no paint, no charge, no nutrients, no coverage",
         d2.calls .. "/" .. r[1][1] .. "," .. r[1][2] .. "/" .. d2.paints .. "/" .. d2.charges .. "/" .. d2.fert .. "/" .. d2.cov,
         "0/0,0/0/0/0/0")
    T.eq("B12 and the helper was never stopped for out of fill", NATIVE.stops, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. THE DISCRIMINATING CASE: A PROCESSOR ERROR, THEN FRESH GROUND
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    -- A block that came off in the end event would survive tick N's error into
    -- tick N+1. The gate reads a flag cleared at every start, so it cannot.
    world()
    local v = buy({ uid = "throws", areas = { "processSprayerArea", "processExtraArea" } })
    setCoverage(0.5)
    tick(v)   -- the prepend reads the previous pass's product, so one pass first
    setCoverage(1.0)
    v._throwOnce = true
    local rN, okN = tick(v)
    T.eq("X1 tick N: blocked, then a processor error, and the end event never ran",
         tostring(okN) .. "/" .. rN[1][1], "false/0")

    setCoverage(0.5)   -- tick N+1 is on fresh ground
    local s = snapshot(v)
    local rM, okM = tick(v)
    local d = delta(s, snapshot(v))
    T.eq("X2 tick N+1 completed", okM, true)
    T.eq("X3 NATIVE RAN AND PAINTED on fresh ground", d.calls .. "/" .. d.paints .. "/" .. rM[1][1], "1/1/250")
    T.eq("X4 the tank drained by the pass's usage", d.tank, -12)
    T.ok("X5 and Soil credited the ground that was painted", d.fert > 0 and d.cov > 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. FINDING 2: NO GATE, NO REFUSAL
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    -- A fertilizing seed drill: Sprayer-spec, sectioned, draining through its own
    -- processor. At 99 percent nothing can refuse its pass, so none is refused.
    world()
    local v = buy({ uid = "seeder", kind = "seeder", areas = { "processSowingMachineArea" } })
    T.eq("F1 the seeder carries no sprayer gate", HookManager.hasActiveSprayerGate(v), false)
    setCoverage(0.5)
    tick(v)   -- the prepend reads the previous pass's product, so one pass first
    setCoverage(1.0)
    local seederBefore = NATIVE.seederCalls
    local s = snapshot(v)
    tick(v)
    local d = delta(s, snapshot(v))
    T.eq("F2 the prepend did not flag a pass no gate can refuse", v._sfOverlapBlockedPass, nil)
    T.eq("F3 the seeder's processor ran and the tank drained", (NATIVE.seederCalls - seederBefore) .. "/" .. d.tank, "1/-12")
    T.ok("F4 SO THE FERTILISER THAT LEFT THE TANK IS CREDITED", d.fert > 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- I. IDENTITY
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    world()
    local v = buy({ uid = "one" })
    local rec, wa = gateRecord(v)
    local gate = wa.processingFunction

    local again = g_currentMission.vehicleSystem:addVehicle(v)
    T.eq("I1 adding the same sprayer again fails", again, false)
    T.ok("I2 and wraps nothing more: the same record, the same gate", gateRecord(v) == rec and wa.processingFunction == gate)

    local twin = build({ uid = "one" })   -- a second vehicle under an id already taken
    T.eq("I3 a failed add (VehicleSystem.lua:165-168) returns false", g_currentMission.vehicleSystem:addVehicle(twin), false)
    T.eq("I4 and wraps nothing", twin.spec_workArea.workAreas[1]._sfWraps, nil)

    -- A foreign mod wraps over the gate after it was installed.
    local foreign = 0
    wa.processingFunction = function(self, area, dt) foreign = foreign + 1 return gate(self, area, dt) end
    local foreignWrap = wa.processingFunction
    setCoverage(0.5)
    tick(v)   -- the prepend reads the previous pass's product, so one pass first
    foreign = 0
    setCoverage(1.0)
    local s = snapshot(v)
    tick(v)
    local d = delta(s, snapshot(v))
    T.eq("I5 a blocked window: the foreign wrap ran, native did not, the tank held", foreign .. "/" .. d.calls .. "/" .. d.tank, "1/0/0")
    T.eq("I6 THE FOREIGN WRAP SURVIVED THE WINDOW", wa.processingFunction == foreignWrap, true)

    -- Teardown: something sits above the gate, so it is left in place, inactive.
    W.hm:uninstallAll()
    T.eq("I7 teardown left the slot to the foreign wrap", wa.processingFunction == foreignWrap, true)
    T.eq("I8 and kept the record, inactive", rec.active, false)
    v._sfOverlapBlockedPass = true   -- a stale flag: an inactive gate must not read it
    local callsBefore = NATIVE.calls
    wa.processingFunction(v, wa, 16)
    T.eq("I9 an inactive gate is a pure pass-through", NATIVE.calls - callsBefore, 1)
    v._sfOverlapBlockedPass = nil

    -- Reinstall on the same world: the sweep reactivates, it never stacks.
    local hm2 = newManager()
    local okRe = pcall(hm2.installAll, hm2, W.soilSys)
    T.eq("I10 reinstall ran", okRe and hm2.installed, true)
    T.eq("I11 THE SAME RECORD WAS REACTIVATED, not a second gate", gateRecord(v) == rec and rec.active, true)
    T.eq("I12 and the slot is still the foreign wrap over our one gate", wa.processingFunction == foreignWrap, true)
    setCoverage(1.0)
    local s2 = snapshot(v)
    tick(v)
    local d2 = delta(s2, snapshot(v))
    T.eq("I13 blocked again, through one gate", d2.calls .. "/" .. d2.tank, "0/0")
    setCoverage(0.5)
    local s3 = snapshot(v)
    tick(v)
    local d3 = delta(s3, snapshot(v))
    T.eq("I14 and on fresh ground native runs exactly once", d3.calls .. "/" .. d3.tank, "1/-12")
end)

group("I-restore", function()
    -- Nothing above the gate at teardown: the exact captured pointer goes back.
    world()
    local v = buy({ uid = "plain" })
    local rec, wa = gateRecord(v)
    local captured = rec.predecessor
    W.hm:uninstallAll()
    T.eq("I15 teardown restored the exact captured pointer", wa.processingFunction == captured, true)
    T.eq("I16 and dropped the record", wa._sfWraps.processSprayerArea, nil)
    T.eq("I17 and the class method is the engine's own again", VehicleSystem.addVehicle == W.nativeAdd, true)
    -- The instance writers are never torn down (MAINTENANCE, out of R8), so the live
    -- instance chain still reaches the gate's addVehicle wrap. It went inactive.
    local later, addedLater = buy({ uid = "after-teardown" })
    T.eq("I18 a sprayer bought after teardown is still registered", addedLater, true)
    T.eq("I19 and carries no gate: the addVehicle wrap went inactive at teardown", gateRecord(later), nil)
end)

group("I-class", function()
    -- The class wrap's own teardown row: still-ours restore, otherwise left in place.
    -- Driven through the gate's rows alone, because installAll's older harvest row
    -- restores VehicleSystem.addVehicle unconditionally (pre-existing, not R8's).
    world()
    VehicleSystem.addVehicle = W.nativeAdd
    local rows = {}
    local mgr = { registerCleanup = function(_, _name, fn) rows[#rows + 1] = fn end }
    T.eq("I20 the gate installs on its own", HookManager.installSprayerOverlapGate(mgr), true)
    local ours = VehicleSystem.addVehicle
    local foreignAdd = function(self, vehicle) return ours(self, vehicle) end
    VehicleSystem.addVehicle = foreignAdd
    for i = #rows, 1, -1 do rows[i]() end
    T.eq("I21 A FOREIGN CLASS WRAP ABOVE OURS SURVIVES THE TEARDOWN", VehicleSystem.addVehicle == foreignAdd, true)
    -- Through the CLASS chain on purpose: the world's own installAll gate still sits
    -- on the instance chain, and this row is about the rows driven above.
    local v = build({ uid = "through-foreign" })
    T.eq("I22 and ours, still under it, wraps nothing any more",
         tostring(VehicleSystem.addVehicle(g_currentMission.vehicleSystem, v)) .. "/" .. tostring(gateRecord(v)), "true/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNCHANGED
-- ══════════════════════════════════════════════════════════════════════════
local function neverBlocked(tag, worldOpts, buyOpts)
    world(worldOpts)
    local v = buy(buyOpts)
    -- The prepend reads the previous pass's product: without one pass first, the
    -- 99 percent pass below would be unblocked for that reason, not this one.
    setCoverage(0.5)
    tick(v)
    setCoverage(1.0)
    local s = snapshot(v)
    local r = tick(v)
    local d = delta(s, snapshot(v))
    T.eq(tag .. " at 99 percent: never flagged, native ran", tostring(v._sfOverlapBlockedPass) .. "/" .. d.calls .. "/" .. r[1][1], "nil/1/250")
    return v, d
end

group("U1", function()
    local v, d = neverBlocked("U1 a pure client", {}, { uid = "client", client = true })
    T.ok("U1b the client still carries the gate, as a pass-through", HookManager.hasActiveSprayerGate(v))
    T.eq("U1c and the drain stays the server's (Sprayer.lua:940)", d.tank, 0)
end)
group("U2", function()
    local _, d = neverBlocked("U2 overlap prevention off", { overlap = false }, { uid = "off" })
    T.ok("U2b the tank drains and Soil credits", d.tank == -12 and d.fert > 0)
end)
group("U3", function()
    local _, d = neverBlocked("U3 an untracked product (herbicide)", {}, { uid = "herb", fillType = FillType.HERBICIDE })
    T.eq("U3b the tank drains", d.tank, -12)
end)
group("U4", function()
    local _, d = neverBlocked("U4 a sprayer with no sections", {}, { uid = "nosec", sections = false })
    T.eq("U4b the tank drains", d.tank, -12)
end)
