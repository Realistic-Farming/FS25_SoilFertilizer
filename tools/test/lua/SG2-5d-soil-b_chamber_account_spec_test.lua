-- SG2-5d-soil-b_chamber_account_spec_test.lua
--
-- SG2-5 slice 5d's Soil half (Bob's 5d shape ruling, Q2 and Q4 with its Q5 addendum): with StockGuard
-- framing a square Baler, the chamber's material is StockGuard's carrier and its condition is the
-- soil.groundCondition record StockGuard's settle stored there.
--   * Q2: Soil's combine adopts the collected account the settle report names for the leg it
--     settles (context.report.outcomeEvidence, SGOperations.lua:1084; the contribution's
--     allocationRef, :942), only on that leg, only when well formed and of the leg's litres; a named
--     leg that fails enters as unknown litres;
--   * Q4/Q5: the bale's birth reads that record through an SG-1 consumer Soil registers beside its
--     property, on the stock StockGuard's read-only fillUnitStockRef names, and takes its account,
--     reconciled to the chamber's native level, as the finish account; with no lookup, no lease, a
--     qualified record or no account it keeps Soil's own chamber account.
-- Inert until StockGuard 5d calls it (src/ground/GroundConditionProperty.lua, src/ground/BalerCollection.lua).
--
-- THE ENTRY-POINT BAR IS GROUP E: the RSF-F211-s6b world (production's SoilFertilitySystem.new, the
-- owners armed in production's order, HookManager:installAll on a Baler built as the engine builds
-- it, WorkArea's tick), Soil's property registered by Soil's own call (SoilFertilitySystem.lua:365)
-- on a RECORDER of StockGuard's handle that keeps every argument; the chamber record is Soil's own
-- combine adopting the leg's account, as StockGuard 5d's settle hands it; the square bale finishes
-- through Soil's own aroundFinish and is born on the yard ladder's real row. StockGuard's real SG-1
-- is not loaded here; the joined run against it is a throwaway outside the repo (the PR body names it).
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG25DSB_BENCH()

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

local FT = ENGINE.FT
local GR = FT.GRASS_WINDROW
local BC = BalerCollection

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
-- The layer's own decode (MaterialWetness.lua:153-158): raw 204 is 79.9213%, raw 52 20.0787%.
local WET, DRY = MaterialWetness.rawToPct(204), MaterialWetness.rawToPct(52)

local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
-- Class hooks persist across worlds (installAll wraps the same class tables again), so
-- every world restores the Baler's listeners and Bale.register before installing.
local PRISTINE = { register = Bale.register, start = Baler.onStartWorkAreaProcessing, finish = Baler.onEndWorkAreaProcessing,
                   fill = Baler.onFillUnitFillLevelChanged, delete = Bale.delete, tick = Baler.onUpdateTick }
local FWC = ForageWagonCollection
local function world(today)
    today = today or 100
    HEIGHT.pixels = {}
    BALER_MODEL.failLoad, BALER_MODEL.onRegister = false, nil
    Bale.register, Bale.delete = PRISTINE.register, PRISTINE.delete
    Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing = PRISTINE.start, PRISTINE.finish
    Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick = PRISTINE.fill, PRISTINE.tick
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet, member = ENGINE.newValueMaps()
    -- The band methods MaterialDown's arm checks for, refusing: nothing here writes the
    -- age layer through the store.
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    W.sys, W.vm, W.age, W.wet, W.member = sys, vm, age, wet, member
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = ENGINE.newVehicleSystem(),
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
    }
    -- The engine's vehicle system: a Class instance, addVehicle on the class (MAINTENANCE row 172).
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
    -- The mission starts before any machine works (SoilFertilityManager:onMissionStarted):
    -- the store's load is decided and the availability overlay's hold ends (row 137).
    sys.yardLadder:onMissionStarted()
    return (okMd and okMw and okHb and okYl and a and b and c) == true
end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function installAll() return pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys) end
local function addBaler(opts)
    local v, work = BALER_MODEL.new(opts)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v, work
end
--- The yard ladder's row for a bale object: its birth wetness (nil = unknown).
local function birthOf(baleObject)
    local yl = W.sys.yardLadder
    local token = baleObject ~= nil and yl._byNode[baleObject.nodeId] or nil
    if token == nil then return "no row" end
    local row = W.sys.materialDown:getObjectRecord(token)
    if row == nil then return "no row" end
    -- [RSF-F215] the birth wetness lives in the row's portion
    return row.portions ~= nil and row.portions[1] ~= nil and row.portions[1].birthWetnessPct or nil
end
local function bales(v) return v.spec_baler.bales end
local function lastBale(v) local b = bales(v)[#bales(v)] return b and b.baleObject end
--- A windrow of `perPixel` litres on the two pixels of one cell's strip the pickup
--- reaches (cell gx 2: x -22..-20; cell gx 3: x -20..-18; z 2..3, gz 8).
local function windrow(gx, perPixel)
    local x0 = -32 + gx * 4 + (gx == 2 and 2 or 0)
    HEIGHT.fill(GR, x0, 2, x0 + 2, 3, perPixel)
end
-- The Baler whose pickup reaches cells 2 and 3 of row 8.
local BX = { x0 = -22, z0 = 1, width = 4, depth = 2 }
local function baler(extra)
    local o = { x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth }
    for k, v in pairs(extra or {}) do o[k] = v end
    return addBaler(o)
end
local function nonStop(extra)
    local o = { x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth }
    for k, v in pairs(extra or {}) do o[k] = v end
    local v, work = BALER_MODEL.newNonStop(o)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v, work
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. FROM PRODUCTION'S ENTRY POINT: THE BALE CARRIES WHAT ITS CHAMBER HELD
-- ══════════════════════════════════════════════════════════════════════════

-- ── StockGuard's mission handle, as a recorder ──────────────────────────────
-- StockGuard.lua:115-121 (registerProperty, registerConsumer, unregisterOwner), :128 (readMaterial,
-- SGOperations.lua:1631) and 5d's read-only fillUnitStockRef(vehicle, fillUnitIndex) (Bob's Q5). Every
-- function keeps its arguments and their count; readMaterial answers through the consumer's OWN
-- resolveReadContext, with the record StockGuard's store holds for the chamber's stock.
local GP = GroundConditionProperty
local PID = "soil.groundCondition"
local SG = {}
local REF = { stockId = "s-chamber", contentsGeneration = 1, dataRevision = "r7" }
local function stockGuard(opts)
    opts = opts or {}
    SG = { calls = {}, props = {}, consumers = {}, unregisters = {}, record = opts.record, readState = opts.readState or "READY",
           snapState = opts.snapState or "READY" }
    local h = {}
    local function note(fn, n, args) SG.calls[#SG.calls + 1] = { fn = fn, n = n, args = args } end
    h.registerProperty = function(...)
        local args = { ... }
        note("registerProperty", select("#", ...), args)
        SG.props[#SG.props + 1] = args
        return { leaseId = "p" .. #SG.props, kind = "property", ownerId = args[1], spec = args[2], live = true }
    end
    h.unregisterOwner = function(...)
        local lease = ...
        note("unregisterOwner", select("#", ...), { lease })
        SG.unregisters[#SG.unregisters + 1] = lease
        if type(lease) == "table" then lease.live = false end
        return true
    end
    if not opts.noConsumer then
        h.registerConsumer = function(...)
            local args = { ... }
            note("registerConsumer", select("#", ...), args)
            SG.consumers[#SG.consumers + 1] = args
            return { leaseId = "c" .. #SG.consumers, kind = "consumer", ownerId = args[1], spec = args[2], live = true }
        end
    end
    if not opts.noLookup then
        h.fillUnitStockRef = function(...)
            note("fillUnitStockRef", select("#", ...), { ... })
            if opts.noStock then return nil, "NO_STOCK" end
            return REF
        end
    end
    h.readMaterial = function(...)
        local lease, query = ...
        note("readMaterial", select("#", ...), { lease, query })
        if type(lease) ~= "table" or not lease.live then return { state = "DENIED", reason = "LEASE", records = {} } end
        local ctx = lease.spec.resolveReadContext(query)
        if type(ctx) ~= "table" then return { state = "DENIED", records = {} } end
        return { state = SG.readState, records = { { stockRef = ctx.stockRefs[1], state = SG.snapState, properties = { [PID] = SG.record } } } }
    end
    g_currentMission.stockGuard = h
    return h
end
local function callsOf(fn)
    local out = {}
    for _, c in ipairs(SG.calls) do if c.fn == fn then out[#out + 1] = c end end
    return out
end
local function acct(c, k, u, r, w) return { carrierLitres = c, knownCarrierLitres = k, unknownCarrierLitres = u, refusedCarrierLitres = r, knownWeightedPctSum = w } end
local function rec(ageRaw, wetRaw, litres, knowledge, account)
    return { propertyId = PID, schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = knowledge or "KNOWN",
             knownAmount = litres, basisAmount = litres, amountUnit = "LITRE", payload = { ageRaw = ageRaw, wetnessRaw = wetRaw, ageDay = 100, account = account } }
end
--- The settle report's evidence, as StockGuard 5d puts it (Bob's Q2): the named leg's account.
local function evidence(list) return { report = { outcomeEvidence = { [PID] = { collectedAccounts = list } } } } end
local function ctxOf(opId, list) local c = evidence(list) c.operationId = opId c.operationKind = "TRANSFER" return c end
local function leg(opId, i, litres, r) return { allocationRef = opId .. ":a" .. i, amount = litres, unit = "LITRE", properties = { [PID] = r } } end
local function accText(a)
    if a == nil then return "none" end
    return table.concat({ num(a.carrierLitres), num(a.knownCarrierLitres), num(a.unknownCarrierLitres), num(a.refusedCarrierLitres), num(a.knownWeightedPctSum) }, "/")
end
--- The world's StockGuard chamber record: Soil's own combine adopting the balerPickup-to-chamber leg's
--- account, as StockGuard 5d's settle hands it (Q2), over the leg's record from the pickup carrier.
local function chamberRecord(account)
    local spec = SG.props[1] and SG.props[1][2] or nil
    if spec == nil then return nil end
    return spec.combine(ctxOf("op9", { { allocation = 1, account = account } }), { leg("op9", 1, 100, rec(3, 120, 100)) }, nil)
end
--- A world with the standard swaths under the pickup: Soil's own chamber account makes the bale 26.063.
local function swaths()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
end
--- A world, the hooks installed, Soil's property registered by its own call (SoilFertilitySystem.lua:365).
local function boot(opts)
    world()
    local v = baler({ capacity = 100 })
    installAll()
    local h = nil
    if not (opts and opts.noStockGuard) then h = stockGuard(opts) end
    local okR = W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    return v, h, okR
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A SQUARE BALE BORN FROM STOCKGUARD'S CHAMBER RECORD
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local v, h, okR = boot()
    T.ok("E0 [entry point] the hooks installed and Soil's own call registered soil.groundCondition on StockGuard's handle", okR == true and W.sys.groundConditionProperty:isRegistered())
    local c = SG.consumers[1]
    local spec = c and c[2] or {}
    local resolved = type(spec.resolveReadContext) == "function" and spec.resolveReadContext({ stockRef = REF }) or nil
    T.eq("E1 NAMED: the same call registered the bale birth's SG-1 consumer: its id, version, schema, material kind, and a read context of the one stock it is asked for",
        #SG.consumers .. "/" .. tostring(c and c[1]) .. "/" .. tostring(spec.version) .. "/" .. tostring(spec.requiredSchemas and spec.requiredSchemas[PID]) .. "/"
            .. tostring(spec.materialKinds and spec.materialKinds[1]) .. "/" .. tostring(resolved and resolved.stockRefs[1] == REF) .. "/" .. tostring(resolved and resolved.purpose),
        "1/soil.baleBirth/1/1/FILL_TYPE/true/BALE_BIRTH")
    SG.record = chamberRecord(acct(100, 100, 0, 0, 4000))
    swaths()
    ENGINE.tick(v, 16)
    local bale = lastBale(v)
    T.eq("E2 NAMED: the square bale is born with the account StockGuard's chamber record holds (40), not Soil's own chamber account (26.063)",
        #bales(v) .. "/" .. num(birthOf(bale)), "1/40")
    local lk, rd = callsOf("fillUnitStockRef")[1], callsOf("readMaterial")[1]
    T.eq("E3 NAMED: the lookup is a dot call with the vehicle and the chamber's fill unit, and the read uses the consumer's lease and asks for soil.groundCondition on that stock only",
        tostring(lk and lk.n) .. "/" .. tostring(lk and lk.args[1] == v) .. "/" .. tostring(lk and lk.args[2] == v.spec_baler.fillUnitIndex) .. "/"
            .. tostring(rd and rd.args[1] and rd.args[1].kind) .. "/" .. tostring(rd and rd.args[2].stockRef == REF) .. "/" .. tostring(rd and rd.args[2].propertyIds and rd.args[2].propertyIds[1]),
        "2/true/true/consumer/true/soil.groundCondition")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. EVERY FALLBACK KEEPS SOIL'S OWN CHAMBER ACCOUNT (Bob's Q5)
-- ══════════════════════════════════════════════════════════════════════════
local function fallback(opts, prepare)
    local v = boot(opts)
    if prepare ~= nil then prepare(v) end
    swaths()
    -- A raise inside the finish is the row's answer, not a crash of the group.
    local ok = pcall(ENGINE.tick, v, 16)
    if not ok then return "raised" end
    return num(birthOf(lastBale(v)))
end
group("F", function()
    T.eq("F1 NAMED: StockGuard absent: nothing to read, the bale keeps Soil's own account", fallback({ noStockGuard = true }), "26.063")
    T.eq("F2 NAMED: StockGuard without the lookup (before 5d): inert", fallback({ noLookup = true }, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) end), "26.063")
    T.eq("F3 NAMED: StockGuard without the consumer registration: inert", fallback({ noConsumer = true }, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) end), "26.063")
    T.eq("F4 NAMED: the property withdrawn (its consumer lease with it): inert",
        fallback({}, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) W.sys.groundConditionProperty:withdraw("bench") end), "26.063")
    T.eq("F5 NAMED: a record SG-1 qualified (UNAVAILABLE) is not read", fallback({}, function() SG.record = rec(3, 120, 100, "UNAVAILABLE", acct(100, 100, 0, 0, 4000)) end), "26.063")
    T.eq("F6 NAMED: a record whose account fails its own checks is not read", fallback({}, function() SG.record = rec(3, 120, 100, "KNOWN", acct(100, 90, 0, 0, 4000)) end), "26.063")
    T.eq("F7 NAMED: a record with no account (an unframed round or non-stop chamber, Bob's C4) is not read", fallback({}, function() SG.record = rec(3, 120, 100, "KNOWN", nil) end), "26.063")
    T.eq("F8 a stale reference is not read", fallback({}, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) SG.snapState = "STALE_REFERENCE" end), "26.063")
    T.eq("F9 a lookup that finds no stock is not read", fallback({ noStock = true }, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) end), "26.063")
    T.eq("F10 a read StockGuard refuses is not read", fallback({}, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) SG.readState = "DENIED" end), "26.063")
    local v = boot()
    W.sys.groundConditionProperty:withdraw("bench")
    T.eq("F11 the withdraw unregistered both leases, the property's and the consumer's", #SG.unregisters .. "/" .. tostring(SG.unregisters[1] and SG.unregisters[1].kind) .. "/" .. tostring(SG.unregisters[2] and SG.unregisters[2].kind),
        "2/property/consumer")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. RECONCILE, THEN BIND (Bob's Q5 condition 3)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local v = boot()
    -- StockGuard's stored record holds a well-formed account of 80 L for the 100 L chamber (the store's
    -- record as it stands, not one of combine's legs): the 20 L it does not cover are unknown.
    SG.record = rec(3, 120, 100, "KNOWN", acct(80, 80, 0, 0, 3200))
    swaths()
    ENGINE.tick(v, 16)
    T.eq("R1 NAMED: an account short of the chamber's native level is reconciled to it first (the gap unknown), so the bale is born unknown, never 40", tostring(birthOf(lastBale(v))), "nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. COMBINE ADOPTS THE NAMED LEG'S ACCOUNT, AND ONLY ON ITS FOUR CHECKS (Bob's Q2)
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    boot()
    local combine = SG.props[1][2].combine
    local good = acct(100, 80, 20, 0, 3200)
    T.eq("C1 NAMED: the leg the evidence names takes its account", accText(combine(ctxOf("op1", { { allocation = 1, account = good } }), { leg("op1", 1, 100, rec(3, 120, 100)) }, nil).payload.account),
        "100/80/20/0/3200")
    -- The chamber already holds 100 L, the very litres of the named account: only the leg may adopt it.
    local before = { observedAmount = 100, amountUnit = "LITRE", properties = { [PID] = rec(5, 60, 100) } }
    T.eq("C2 NAMED: never on destinationBefore: the chamber's earlier 100 L join as unknown carrier beside the adopted leg, even at the account's own litres",
        accText(combine(ctxOf("op1", { { allocation = 1, account = good } }), { leg("op1", 1, 100, rec(3, 120, 100)) }, before).payload.account), "200/80/120/0/3200")
    T.eq("C3 NAMED: a named leg whose account fails accountProblem enters as unknown carrier litres",
        accText(combine(ctxOf("op1", { { allocation = 1, account = acct(100, 80, 10, 0, 3200) } }), { leg("op1", 1, 100, rec(3, 120, 100)) }, nil).payload.account), "100/0/100/0/0")
    T.eq("C4 NAMED: a named leg whose account's carrier is not the leg's litres enters as unknown carrier litres",
        accText(combine(ctxOf("op1", { { allocation = 1, account = acct(90, 90, 0, 0, 3600) } }), { leg("op1", 1, 100, rec(3, 120, 100)) }, nil).payload.account), "100/0/100/0/0")
    T.eq("C5 a doubly named allocation cannot be told apart: unknown",
        accText(combine(ctxOf("op1", { { allocation = 1, account = good }, { allocation = 1, account = good } }), { leg("op1", 1, 100, rec(3, 120, 100)) }, nil).payload.account), "100/0/100/0/0")
    T.eq("C6 a leg the evidence does not name keeps its own record's account, scaled (an overflow re-add's stock carries its own)",
        accText(combine(ctxOf("op1", { { allocation = 2, account = good } }), { leg("op1", 1, 40, rec(3, 120, 100, "KNOWN", acct(100, 100, 0, 0, 5000))) }, nil).payload.account), "40/40/0/0/2000")
    T.eq("C7 evidence from another operation names nothing here", accText(combine(ctxOf("op2", {}), { leg("op1", 1, 100, rec(3, 120, 100)) }, nil).payload.account
        ), "none")
    T.eq("C8 with no evidence at all, combine is as before", accText(combine({ operationId = "op1" }, { leg("op1", 1, 100, rec(3, 120, 100)) }, nil).payload.account), "none")
    local okBad, bad = pcall(combine, ctxOf("op1", "not a list"), { leg("op1", 1, 100, rec(3, 120, 100)) }, nil)
    T.eq("C9 malformed evidence is ignored, not raised on", tostring(okBad) .. "/" .. accText(bad and bad.payload.account), "true/none")
    T.eq("C10 every adopted record validates", tostring(GP.validate(combine(ctxOf("op1", { { allocation = 1, account = good } }), { leg("op1", 1, 100, rec(3, 120, 100)) }, before))), "true")
end)
end
SG25DSB_BENCH()
