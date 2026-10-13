-- SG2-5e-soil_round_pad_account_spec_test.lua
--
-- SG2-5 slice 5e's Soil half (5e-soil, Part 0 of Bob's intake BOB-INTAKE-SG2-5E-ROUND-CORE-2026-10-05,
-- section 4): with StockGuard framing a round Baler (StockGuard 5e-b), a PARTIAL round bale is born
-- with the account StockGuard's chamber record holds, read BEFORE the engine pads the chamber to
-- capacity (Baler.lua:1328-1347; the full chamber's finishBale runs inside the pad's add, :1345, so a
-- read at the finish could already see the pad). Soil's own chamber account knows nothing of a leased
-- pickup, so without this every partial round bale from a framed baler would be born unknown.
--   * BalerCollection.aroundUnloading captures BC.prePadAccount (BC.chamberAccount reconciled to the
--     chamber's native level, as the full finish reconciles it) into st.pad.account before the original;
--   * aroundFinish's pad branch starts from st.pad.account when present, else from st.main as before,
--     then adds the buffer's share as before. The pad is not material and is never reconciled to.
-- Inert until StockGuard 5e-b frames a round chamber (src/ground/BalerCollection.lua).
--
-- THE ENTRY-POINT BAR IS GROUP E: the RSF-F211-s6b world (production's SoilFertilitySystem.new, the
-- owners armed in production's order, HookManager:installAll on a plain round Baler built as the engine
-- builds it, WorkArea's tick), Soil's property registered by Soil's own call (SoilFertilitySystem.lua:365)
-- on a RECORDER of StockGuard's handle; the chamber record before the pad is Soil's own combine adopting
-- the leg's account, as StockGuard's settle hands it (5d-soil-b's group E); the partial bale is unloaded
-- through the instance's own setIsUnloadingBale, which installAll wrapped, and born on the yard ladder's
-- real row. The recorder answers by the chamber's CURRENT level, so a read after the pad gets the padded
-- record (the pad as unknown litres) and a bale born from it is unknown. StockGuard's real SG-1 is not
-- loaded here; the joined run against it is a throwaway outside the repo (the PR body names it).
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG25ES_BENCH()

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

local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
-- Class hooks persist across worlds (installAll wraps the same class tables again), so
-- every world restores the Baler's listeners and Bale.register before installing.
local PRISTINE = { register = Bale.register, start = Baler.onStartWorkAreaProcessing, finish = Baler.onEndWorkAreaProcessing,
                   fill = Baler.onFillUnitFillLevelChanged, delete = Bale.delete, tick = Baler.onUpdateTick,
                   birth = HookManager.baleBirth, prePad = BC.prePadAccount }
-- Every birth's account as BalerCollection hands it to HookManager.baleBirth (the row keeps only its pct).
local BIRTHS = {}
local function world(today)
    today = today or 100
    HEIGHT.pixels = {}
    BALER_MODEL.failLoad, BALER_MODEL.onRegister = false, nil
    Bale.register, Bale.delete = PRISTINE.register, PRISTINE.delete
    Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing = PRISTINE.start, PRISTINE.finish
    Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick = PRISTINE.fill, PRISTINE.tick
    BC.prePadAccount = PRISTINE.prePad
    BIRTHS = {}
    HookManager.baleBirth = function(obj, info)
        BIRTHS[#BIRTHS + 1] = { obj = obj, account = info and info.account }
        return PRISTINE.birth(obj, info)
    end
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet, member = ENGINE.newValueMaps()
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
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function installAll() return pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys) end
--- The yard ladder's row for a bale object: its birth wetness (nil = unknown).
local function birthOf(baleObject)
    local yl = W.sys.yardLadder
    local token = baleObject ~= nil and yl._byNode[baleObject.nodeId] or nil
    if token == nil then return "no row" end
    local row = W.sys.materialDown:getObjectRecord(token)
    if row == nil then return "no row" end
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
local function roundBaler(extra)
    local o = { x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth }
    for k, val in pairs(extra or {}) do o[k] = val end
    local v, work = BALER_MODEL.newRound(o)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v, work
end
--- A world with the standard swaths under the pickup: 100 L, Soil's own chamber account 26.063.
local function swaths()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
end
local function accText(a)
    if a == nil then return "none" end
    return table.concat({ num(a.carrier), num(a.known), num(a.unknown), num(a.refused), num(a.weighted) }, "/")
end

-- ── StockGuard's mission handle, as a recorder (5d-soil-b's, answering by the chamber's level) ──
-- StockGuard.lua:115-121 (registerProperty, registerConsumer, unregisterOwner), :128 (readMaterial,
-- SGOperations.lua:1631) and 5d's read-only fillUnitStockRef(vehicle, fillUnitIndex). readMaterial
-- answers through the consumer's OWN resolveReadContext. SG.record may be a function of the chamber's
-- current level, so the bench can tell a read before the pad from one inside it.
local GP = GroundConditionProperty
local PID = "soil.groundCondition"
local SG = {}
local REF = { stockId = "s-chamber", contentsGeneration = 1, dataRevision = "r7" }
local function stockGuard(opts)
    opts = opts or {}
    SG = { calls = {}, props = {}, consumers = {}, record = opts.record, readState = opts.readState or "READY",
           snapState = opts.snapState or "READY", vehicle = nil }
    local h = {}
    local function note(fn, n, args) SG.calls[#SG.calls + 1] = { fn = fn, n = n, args = args } end
    h.registerProperty = function(...)
        local args = { ... }
        note("registerProperty", select("#", ...), args)
        SG.props[#SG.props + 1] = args
        return { leaseId = "p" .. #SG.props, kind = "property", ownerId = args[1], spec = args[2], live = true }
    end
    h.unregisterOwner = function(lease) if type(lease) == "table" then lease.live = false end return true end
    h.registerConsumer = function(...)
        local args = { ... }
        note("registerConsumer", select("#", ...), args)
        SG.consumers[#SG.consumers + 1] = args
        return { leaseId = "c" .. #SG.consumers, kind = "consumer", ownerId = args[1], spec = args[2], live = true }
    end
    if not opts.noLookup then
        h.fillUnitStockRef = function(...)
            local v, i = ...
            note("fillUnitStockRef", select("#", ...), { v, i, level = type(v) == "table" and v:getFillUnitFillLevel(i) or nil })
            if opts.lookupRaises then error("lookup raised") end
            return REF
        end
    end
    h.readMaterial = function(...)
        local lease, query = ...
        note("readMaterial", select("#", ...), { lease, query })
        if opts.readRaises then error("read raised") end
        if type(lease) ~= "table" or not lease.live then return { state = "DENIED", reason = "LEASE", records = {} } end
        local ctx = lease.spec.resolveReadContext(query)
        if type(ctx) ~= "table" then return { state = "DENIED", records = {} } end
        local r = SG.record
        if type(r) == "function" then r = r() end
        return { state = SG.readState, records = { { stockRef = ctx.stockRefs[1], state = SG.snapState, properties = { [PID] = r } } } }
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
local function evidence(list) return { report = { outcomeEvidence = { [PID] = { collectedAccounts = list } } } } end
local function ctxOf(opId, list) local c = evidence(list) c.operationId = opId c.operationKind = "TRANSFER" return c end
local function leg(opId, i, litres, r) return { allocationRef = opId .. ":a" .. i, amount = litres, unit = "LITRE", properties = { [PID] = r } } end
--- The chamber record before the pad: Soil's own combine adopting the balerPickup-to-chamber leg's
--- account, as StockGuard's settle hands it (5d-soil-b's chamberRecord).
local function chamberRecord(account, litres)
    litres = litres or 100
    local spec = SG.props[1] and SG.props[1][2] or nil
    if spec == nil then return nil end
    return spec.combine(ctxOf("op9", { { allocation = 1, account = account } }), { leg("op9", 1, litres, rec(3, 120, litres)) }, nil)
end
--- What StockGuard's record would say once the chamber is padded: the pad as unknown litres
--- beside the material (StockGuard 5e-b credits the pad as no known litres, Bob's intake (d)).
local PADDED = nil
--- The record answered by the chamber's current level: `before` at or under the pre-pad level,
--- the padded record above it.
local function byLevel(v, prePad, before)
    PADDED = rec(3, 120, 200, "KNOWN", acct(200, 100, 100, 0, 4000))
    return function()
        if v:getFillUnitFillLevel(v.spec_baler.fillUnitIndex) > prePad then return PADDED end
        return before
    end
end
--- A world, the hooks installed on a plain round Baler (capacity 200, so the standard 100 L is a
--- partial bale), Soil's property registered by its own call (SoilFertilitySystem.lua:365).
local function boot(opts)
    world()
    local v = roundBaler({ capacity = (opts and opts.capacity) or 200 })
    installAll()
    local h = nil
    if not (opts and opts.noStockGuard) then h = stockGuard(opts) end
    local okR = W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    return v, h, okR
end
--- The partial round bale: the standard swaths picked up into a 200 L chamber, then the unload the
--- player asks for, through the instance's own (wrapped) setIsUnloadingBale.
local function partial(v, prepare)
    swaths()
    ENGINE.tick(v, 16)
    if prepare ~= nil then prepare(v) end
    local mainBefore = accText(BC.state(v).main)
    local okU, errU = pcall(v.setIsUnloadingBale, v, true)
    return okU, errU, mainBefore
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A PARTIAL ROUND BALE BORN FROM STOCKGUARD'S PRE-PAD RECORD
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local v, h, okR = boot()
    T.ok("E0 [entry point] the hooks installed on a plain round Baler (no buffer unit) and Soil's own call registered soil.groundCondition on StockGuard's handle",
        okR == true and W.sys.groundConditionProperty:isRegistered() and v.spec_baler.buffer.fillUnitIndex == nil and v.spec_baler.hasUnloadingAnimation == true)
    local okU, errU = partial(v, function(vv) SG.record = byLevel(vv, 100, chamberRecord(acct(100, 100, 0, 0, 4000))) end)
    local bale = lastBale(v)
    T.eq("E1 NAMED: the partial round bale is born with the account StockGuard's chamber record held BEFORE the pad (40), not Soil's own chamber account (26.063) and not the padded record (unknown)",
        tostring(okU) .. "/" .. #bales(v) .. "/" .. num(birthOf(bale)), "true/1/40")
    T.eq("E2 NAMED: the engine padded the chamber to capacity and kept the real amount (Baler.lua:1343-1345)",
        num(v:getFillUnitFillLevel(1)) .. "/" .. num(v.spec_baler.lastBaleFillLevel), "200/100")
    local lk, rd = callsOf("fillUnitStockRef"), callsOf("readMaterial")
    T.eq("E3 NAMED: StockGuard was read once, with the chamber at its pre-pad level, through the consumer's lease, for soil.groundCondition on that stock",
        #lk .. "/" .. #rd .. "/" .. num(lk[1] and lk[1].args.level) .. "/" .. tostring(lk[1] and lk[1].args[1] == v) .. "/" .. tostring(lk[1] and lk[1].args[2] == v.spec_baler.fillUnitIndex) .. "/"
            .. tostring(rd[1] and rd[1].args[1] and rd[1].args[1].kind) .. "/" .. tostring(rd[1] and rd[1].args[2].stockRef == REF) .. "/" .. tostring(rd[1] and rd[1].args[2].propertyIds and rd[1].args[2].propertyIds[1]),
        "1/1/100/true/true/consumer/true/soil.groundCondition")
    T.eq("E4 the birth's account is the record's, whole", accText(BIRTHS[#BIRTHS] and BIRTHS[#BIRTHS].account), "100/100/0/0/4000")
    T.eq("E5 the pad scope closed with the call", tostring(BC.state(v).pad), "nil")
    BALER_MODEL.dropBale(v)
    T.eq("E6 dropped, the bale holds the real amount", num(bale ~= nil and bale:getFillLevel()), "100")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. WITH NOTHING TO READ, TODAY'S RESULT, ACCOUNT FOR ACCOUNT (Bob's bar 2)
-- ══════════════════════════════════════════════════════════════════════════
--- The partial bale's birth with the given StockGuard setup: "<pct>|<birth account>|<Soil's own account>".
local function today(opts, setRecord)
    local v = boot(opts)
    local okU, errU, mainBefore = partial(v, setRecord)
    if not okU then return "raised: " .. tostring(errU) end
    return num(birthOf(lastBale(v))) .. "|" .. accText(BIRTHS[#BIRTHS] and BIRTHS[#BIRTHS].account) .. "|" .. mainBefore
end
group("N", function()
    local own = "26.063|100/100/0/0/2606.2992|100/100/0/0/2606.2992"
    T.eq("N1 NAMED: StockGuard absent: the bale is born from Soil's own chamber account, exactly", today({ noStockGuard = true }), own)
    T.eq("N2 NAMED: StockGuard without the lookup (before 5d): the same", today({ noLookup = true }, function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) end), own)
    T.eq("N3 NAMED: a record with no account (the round chamber StockGuard does not frame yet): the same", today({}, function() SG.record = rec(3, 120, 100, "KNOWN", nil) end), own)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. A READ THAT FAILS FALLS BACK TO SOIL'S OWN, NEVER TO AN ERROR (Bob's bar 4)
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local own = "26.063|100/100/0/0/2606.2992|100/100/0/0/2606.2992"
    local good = function() SG.record = chamberRecord(acct(100, 100, 0, 0, 4000)) end
    T.eq("X1 NAMED: StockGuard's read raises (pcall false)", today({ readRaises = true }, good), own)
    T.eq("X2 NAMED: StockGuard's lookup raises", today({ lookupRaises = true }, good), own)
    T.eq("X3 NAMED: a record SG-1 qualified (QUALIFIED)", today({}, function() SG.record = rec(3, 120, 100, "UNAVAILABLE", acct(100, 100, 0, 0, 4000)) end), own)
    T.eq("X4 NAMED: a stale reference (NOT_READY)", today({ snapState = "STALE_REFERENCE" }, good), own)
    T.eq("X5 a read StockGuard refuses", today({ readState = "DENIED" }, good), own)
    T.eq("X6 NAMED: the pre-pad capture itself raising never stops the engine's unload: the pad and the bale happen, from Soil's own",
        today({}, function() good() BC.prePadAccount = function() error("bench") end end), own)
    BC.prePadAccount = PRISTINE.prePad
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. RECONCILE TO THE PRE-PAD LEVEL, THEN BIND
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    -- StockGuard's stored record holds a well-formed account of 80 L for the 100 L chamber: the 20 L
    -- it does not cover are unknown, as the full finish reconciles (5d-soil-b R1).
    local v = boot()
    partial(v, function() SG.record = rec(3, 120, 100, "KNOWN", acct(80, 80, 0, 0, 3200)) end)
    T.eq("R1 NAMED: an account short of the chamber's pre-pad level is reconciled to it first (the gap unknown), so the bale is born unknown, never 40",
        tostring(birthOf(lastBale(v))) .. "/" .. accText(BIRTHS[#BIRTHS] and BIRTHS[#BIRTHS].account), "nil/100/80/20/0/3200")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE FULL ROUND BALE IS UNCHANGED (Bob's bar 3)
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    -- A 100 L chamber: the standard 100 L fills it, and the bale finishes inside the pickup's add.
    local v = boot({ capacity = 100 })
    SG.record = chamberRecord(acct(100, 100, 0, 0, 4000))
    swaths()
    ENGINE.tick(v, 16)
    T.eq("F1 NAMED: a full round bale still takes StockGuard's record at the finish (40), with no unload and no pre-pad read",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. #callsOf("readMaterial") .. "/" .. tostring(BC.state(v).pad), "1/40/1/nil")
    local okU = pcall(v.setIsUnloadingBale, v, true)
    T.eq("F2 opening the door on a mounted full bale pads nothing and births nothing",
        tostring(okU) .. "/" .. #bales(v) .. "/" .. #BIRTHS .. "/" .. num(v:getFillUnitFillLevel(1)), "true/1/1/100")
    v = boot({ capacity = 100, noStockGuard = true })
    swaths()
    ENGINE.tick(v, 16)
    T.eq("F3 StockGuard absent: the full round bale keeps Soil's own account", num(birthOf(lastBale(v))), "26.063")
end)
end
SG25ES_BENCH()
