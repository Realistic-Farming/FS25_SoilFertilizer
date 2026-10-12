-- SG2-nonstop-soil_buffer_share_spec_test.lua
--
-- SG-2 non-stop baler framing, PR 1 (Soil's half; Bob's intake BOB-INTAKE-SG2-NONSTOP-BALER-FRAMING-
-- 2026-10-09): a PARTIAL round bale from a non-stop baler takes the buffer's share in the pad
-- (Baler.lua:1338-1341, the buffer debited by what the bale takes beyond the chamber). When StockGuard
-- frames the buffer, the buffer's material is the account StockGuard's SG-1 record holds, so the share
-- is taken from that account, read BEFORE the debit, not from Soil's own buffer account (which knows
-- nothing of a leased pickup and says unknown).
--   * BalerCollection.aroundUnloading also captures BC.preBufferAccount (BC.unitAccount on the buffer
--     unit, reconciled to the buffer's native level) into st.pad.bufferAccount before the original;
--   * bufferChange's pad branch takes the share from st.pad.bufferAccount when present, else from
--     Soil's own buffer account as before. Soil's own buffer account loses the litres either way.
--   * MAINTENANCE row 219: a raise in either pre-pad read logs one warning naming the error.
-- Inert until StockGuard frames a non-stop buffer (PR 2 of the same intake).
--
-- THE ENTRY-POINT BAR IS GROUP E: the RSF-F211-s6b world (production's SoilFertilitySystem.new, the
-- owners armed in production's order, HookManager:installAll on a non-stop round Baler built as the
-- engine builds it, WorkArea's tick and the buffer-to-chamber transfer of Baler.onUpdateTick), Soil's
-- property registered by Soil's own call (SoilFertilitySystem.lua:365) on a RECORDER of StockGuard's
-- handle that names one stock per fill unit and answers each stock's record; the partial bale is
-- unloaded through the instance's own setIsUnloadingBale, which installAll wrapped, and born on the
-- yard ladder's real row. StockGuard's real SG-1 is not loaded here.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG2NS_BENCH()

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
                   birth = HookManager.baleBirth, prePad = BC.prePadAccount, preBuffer = BC.preBufferAccount }
-- Every birth's account as BalerCollection hands it to HookManager.baleBirth.
local BIRTHS = {}
local function world(today)
    today = today or 100
    HEIGHT.pixels = {}
    BALER_MODEL.failLoad, BALER_MODEL.onRegister = false, nil
    Bale.register, Bale.delete = PRISTINE.register, PRISTINE.delete
    Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing = PRISTINE.start, PRISTINE.finish
    Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick = PRISTINE.fill, PRISTINE.tick
    BC.prePadAccount, BC.preBufferAccount = PRISTINE.prePad, PRISTINE.preBuffer
    BIRTHS, WARN = {}, {}
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
--- A non-stop round baler (RSF-F211 part 2b's): chamber unit 1 (capacity 100), buffer unit 3.
local function nonStop(extra)
    local o = { x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth, capacity = 100, round = true, canUnloadUnfinishedBale = true }
    for k, val in pairs(extra or {}) do o[k] = val end
    local v, work = BALER_MODEL.newNonStop(o)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v, work
end
local WET, DRY = MaterialWetness.rawToPct(204), MaterialWetness.rawToPct(52)
--- The warnings BalerCollection logged (installAll's skipped-hook notices in this bench world are not).
local function bcWarn()
    local out = {}
    for _, w in ipairs(WARN) do if w:find("[BalerCollection]", 1, true) == 1 then out[#out + 1] = w end end
    return out
end
local function accText(a)
    if a == nil then return "none" end
    return table.concat({ num(a.carrier), num(a.known), num(a.unknown), num(a.refused), num(a.weighted) }, "/")
end

-- ── StockGuard's mission handle, as a recorder that names one stock per fill unit ─────────────
-- StockGuard.lua:115-121 (registerProperty, registerConsumer, unregisterOwner), :128 (readMaterial,
-- SGOperations.lua:1631) and 5d's read-only fillUnitStockRef(vehicle, fillUnitIndex). The chamber
-- (unit 1) and the buffer (unit 3) are separate stocks; readMaterial answers through the consumer's
-- OWN resolveReadContext with that stock's record (SG.records[stockId]; nil = no stock named).
local PID = "soil.groundCondition"
local SG = {}
local REFS = { [1] = { stockId = "s-chamber", contentsGeneration = 1, dataRevision = "r7" },
               [3] = { stockId = "s-buffer", contentsGeneration = 1, dataRevision = "r3" } }
local function stockGuard(opts)
    opts = opts or {}
    SG = { calls = {}, props = {}, consumers = {}, records = opts.records or {}, readState = "READY", snapState = "READY" }
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
    h.fillUnitStockRef = function(...)
        local v, i = ...
        note("fillUnitStockRef", select("#", ...), { v, i, chamber = v:getFillUnitFillLevel(1), buffer = v:getFillUnitFillLevel(3) })
        if opts.noBufferStock and i == 3 then return nil, "NO_STOCK" end
        return REFS[i]
    end
    h.readMaterial = function(...)
        local lease, query = ...
        note("readMaterial", select("#", ...), { lease, query })
        local ctx = lease.spec.resolveReadContext(query)
        if type(ctx) ~= "table" then return { state = "DENIED", records = {} } end
        local id = ctx.stockRefs[1].stockId
        if opts.raiseOn == id then error("read raised") end
        return { state = SG.readState, records = { { stockRef = ctx.stockRefs[1], state = SG.snapState, properties = { [PID] = SG.records[id] } } } }
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
local function rec(litres, account)
    return { propertyId = PID, schemaVersion = 1, producerId = "soil", propertyRevision = 0, knowledge = "KNOWN",
             knownAmount = litres, basisAmount = litres, amountUnit = "LITRE", payload = { ageRaw = 3, wetnessRaw = 120, ageDay = 100, account = account } }
end
-- StockGuard's records: the chamber's 60 L at 40 % and the buffer's 20 L at 10 %, both all known.
-- Soil's own accounts for the same material say WET (chamber) and DRY (buffer), so each source is
-- visible in the bale's percent.
local CHAMBER = function() return rec(60, acct(60, 60, 0, 0, 2400)) end
local BUFFER = function() return rec(20, acct(20, 20, 0, 0, 200)) end

--- A world, the hooks installed on a non-stop round Baler, StockGuard's recorder (unless
--- opts.noStockGuard), Soil's property registered by its own call (SoilFertilitySystem.lua:365).
local function boot(opts)
    opts = opts or {}
    world()
    local v = nonStop(opts.baler)
    installAll()
    if not opts.noStockGuard then stockGuard(opts) end
    local okR = W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    return v, okR
end
--- RSF-F211 group P's material: 60 L wet picked into the buffer and moved into the chamber, then
--- `bufferPerPixel` (5 = 20 L) dry picked into the buffer; then the unload the player asks for,
--- through the instance's own (wrapped) setIsUnloadingBale.
local function partial(v, bufferPerPixel)
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 15) windrow(3, 15)
    ENGINE.tick(v, 16)
    BALER_MODEL.updateTick(v, 1000)
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, bufferPerPixel or 5) windrow(3, bufferPerPixel or 5)
    ENGINE.tick(v, 16)
    local before = num(v:getFillUnitFillLevel(1)) .. "+" .. num(v:getFillUnitFillLevel(3))
    local okU, errU = pcall(v.setIsUnloadingBale, v, true)
    return okU, errU, before
end
--- The partial bale's birth with the given setup: "<pct>|<birth account>".
local function birth(opts, bufferPerPixel)
    local v = boot(opts)
    local okU, errU = partial(v, bufferPerPixel)
    if not okU then return "raised: " .. tostring(errU) end
    return num(birthOf(lastBale(v))) .. "|" .. accText(BIRTHS[#BIRTHS] and BIRTHS[#BIRTHS].account)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: THE BUFFER'S SHARE FROM STOCKGUARD'S BUFFER RECORD (Bob's S-pad)
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local v, okR = boot({ records = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = BUFFER() } })
    T.ok("E0 [entry point] the hooks installed on a non-stop round Baler (buffer unit 3) and Soil's own call registered soil.groundCondition on StockGuard's handle",
        okR == true and W.sys.groundConditionProperty:isRegistered() and v.spec_baler.buffer.fillUnitIndex == 3 and v.spec_baler.nonStopBaling == true)
    local okU, errU, before = partial(v)
    local bale = lastBale(v)
    T.eq("E1 NAMED: the partial bale is born with StockGuard's chamber account plus StockGuard's buffer share (2400 + 200 over 80 L = 32.5), not Soil's own buffer share",
        tostring(okU) .. "/" .. before .. "/" .. #bales(v) .. "/" .. num(birthOf(bale)), "true/60+20/1/32.5")
    T.eq("E2 the birth's account is all known litres: 80 L carried, 2600 weighted", accText(BIRTHS[#BIRTHS] and BIRTHS[#BIRTHS].account), "80/80/0/0/2600")
    local lk = callsOf("fillUnitStockRef")
    local units = {}
    for _, c in ipairs(lk) do units[#units + 1] = tostring(c.args[2]) .. "@" .. num(c.args.chamber) .. "+" .. num(c.args.buffer) end
    T.eq("E3 NAMED: StockGuard was asked once for the chamber and once for the buffer, both before the pad and the buffer's debit (60 L + 20 L), and never during the pickup or the transfer",
        table.concat(units, ","), "1@60+20,3@60+20")
    local st = BC.state(v)
    T.eq("E4 Soil's own buffer account still gave up the share (empty), and the pad scope closed with the call",
        accText(st.buffer) .. "/" .. tostring(st.pad), "0/0/0/0/0/nil")
    BALER_MODEL.dropBale(v)
    T.eq("E5 dropped, the bale holds the real amount the chamber and buffer gave it", num(bale ~= nil and bale:getFillLevel()), "80")
    T.eq("E6 no BalerCollection warning on the good path", #bcWarn(), 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. A PART OF THE BUFFER: THE SHARE IS THAT PART OF STOCKGUARD'S BUFFER ACCOUNT
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    -- 60 L in the chamber and 60 L dry in the buffer: the bale takes 40 L of the buffer (Baler.lua:
    -- 1336-1341, min(120, 100) - 60), so the share is 40/60 of StockGuard's 60 L buffer at 10 %.
    local v = boot({ records = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = rec(60, acct(60, 60, 0, 0, 600)) } })
    local okU, _, before = partial(v, 15)
    T.eq("P1 NAMED: the share is the debited part of StockGuard's buffer account, uniformly (2400 + 400 over 100 L = 28)",
        tostring(okU) .. "/" .. before .. "/" .. num(birthOf(lastBale(v))) .. "/" .. accText(BIRTHS[#BIRTHS] and BIRTHS[#BIRTHS].account),
        "true/60+60/28/100/100/0/0/2800")
    T.eq("P2 the buffer keeps 20 L natively and Soil's own buffer account keeps the same 20 L of its own (dry)",
        num(v:getFillUnitFillLevel(3)) .. "/" .. num(BC.state(v).buffer.carrier) .. "/" .. num(BC.accountPct(BC.state(v).buffer)), "20/20/" .. num(DRY))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. WITH NO BUFFER RECORD, TODAY'S RESULT (Bob's S-alone)
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local own = num((60 * WET + 20 * DRY) / 80)
    local chamberOnly = num((2400 + 20 * DRY) / 80)
    T.eq("N1 NAMED: StockGuard absent: the bale is born from Soil's own chamber and buffer accounts, exactly (RSF-F211 group P)",
        (birth({ noStockGuard = true }):match("^[^|]*")), own)
    T.eq("N2 NAMED: an unframed buffer (its record holds no account): the share is Soil's own, the chamber StockGuard's",
        (birth({ records = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = rec(20, nil) } }):match("^[^|]*")), chamberOnly)
    T.eq("N3 NAMED: no stock named for the buffer: the same",
        (birth({ noBufferStock = true, records = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = BUFFER() } }):match("^[^|]*")), chamberOnly)
    -- A baler with no buffer unit: no buffer read at all.
    world()
    local v = BALER_MODEL.newRound({ x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth, capacity = 200 })
    g_currentMission.vehicleSystem:addVehicle(v)
    installAll()
    stockGuard({ records = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = BUFFER() } })
    W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    local okP, acc = pcall(BC.preBufferAccount, v, v.spec_baler)
    T.eq("N4 a baler with no buffer unit: preBufferAccount answers nil and StockGuard is never asked",
        tostring(okP) .. "/" .. tostring(acc) .. "/" .. #callsOf("fillUnitStockRef"), "true/nil/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. A READ THAT FAILS FALLS BACK TO SOIL'S OWN, NEVER TO AN ERROR; A RAISE IS LOGGED (row 219)
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local both = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = BUFFER() }
    local chamberOnly = num((2400 + 20 * DRY) / 80)
    T.eq("X1 NAMED: StockGuard's buffer read raises (readChamberAccount answers none): Soil's own share, no warning",
        (birth({ raiseOn = "s-buffer", records = both }):match("^[^|]*")) .. "/" .. #bcWarn(), chamberOnly .. "/0")
    world()
    local v = nonStop()
    installAll()
    stockGuard({ records = both })
    W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    BC.preBufferAccount = function() error("bench-buffer") end
    local okU = partial(v)
    BC.preBufferAccount = PRISTINE.preBuffer
    T.eq("X2 NAMED: a raise in the buffer capture: the unload completes, the share is Soil's own, and one warning names the error",
        tostring(okU) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. #bcWarn() .. "/" .. tostring(bcWarn()[1] ~= nil and bcWarn()[1]:find("pre-pad buffer read failed", 1, true) ~= nil and bcWarn()[1]:find("bench-buffer", 1, true) ~= nil),
        "true/" .. chamberOnly .. "/1/true")
    world()
    v = nonStop()
    installAll()
    stockGuard({ records = both })
    W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    BC.prePadAccount = function() error("bench-chamber") end
    okU = partial(v)
    BC.prePadAccount = PRISTINE.prePad
    T.eq("X3 NAMED [MAINTENANCE row 219]: a raise in the chamber capture: the unload completes from Soil's own chamber account (with StockGuard's buffer share), and one warning names the error",
        tostring(okU) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. #bcWarn() .. "/" .. tostring(bcWarn()[1] ~= nil and bcWarn()[1]:find("pre-pad chamber read failed", 1, true) ~= nil and bcWarn()[1]:find("bench-chamber", 1, true) ~= nil),
        "true/" .. num((60 * WET + 200) / 80) .. "/1/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. RECONCILE TO THE BUFFER'S NATIVE LEVEL, THEN TAKE
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    -- StockGuard's buffer record covers 15 L of the 20 L buffer: the 5 L it does not cover are
    -- unknown, as the chamber's pre-pad reconcile does (SG2-5e-soil R1), so the bale is unknown.
    local r = birth({ records = { ["s-chamber"] = CHAMBER(), ["s-buffer"] = rec(15, acct(15, 15, 0, 0, 150)) } })
    T.eq("R1 NAMED: a buffer account short of the buffer's native level is reconciled to it first (the gap unknown), so the bale is born unknown, never from 15 L",
        r, "nil|80/75/5/0/2550")
end)
end
SG2NS_BENCH()
