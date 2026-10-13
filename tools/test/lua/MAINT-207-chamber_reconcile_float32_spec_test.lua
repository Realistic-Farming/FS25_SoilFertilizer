-- MAINT-207-chamber_reconcile_float32_spec_test.lua
--
-- MAINTENANCE row 207 (row 206's Soil half): at a square bale's finish Soil reconciles the account
-- StockGuard's chamber record holds to the chamber's native level, and books any gap over
-- BC.TOLERANCE (1e-6 L) as unknown, so the bale is born with no wetness. After a save and reload,
-- SG-1 reattaches the record with its pre-save litres (row 206) while the chamber holds the
-- engine's float readback of them: the float32 to six decimals, ties to even, measured from the
-- save files. Above about 16 L that rounding is past the tolerance, so a reloaded chamber's bale
-- was born unknown. The finish now treats the level and the record's litres as equal when their
-- native images are equal (BC.nativeFloatImage, Soil's own copy of row 206's rule) and reconciles
-- exactly as before otherwise. No wider tolerance. Only the record's reconcile changes: Soil's
-- own accounts reconcile as before.
--
-- THE ENTRY-POINT BAR IS GROUP E: the RSF-F211-s6b world as the 5d-soil-b bench builds it
-- (production's SoilFertilitySystem.new, the owners armed in production's order,
-- HookManager:installAll on a square Baler built as the engine builds it, WorkArea's tick, Soil's
-- property registered by Soil's own call on a recorder of StockGuard's handle), the chamber at the
-- engine's readback of the record's litres under each possible C reader; the bale finishes
-- through Soil's own aroundFinish and is born on the yard ladder's real row. On c56a4551 E1 and E2
-- are born unknown.
--
-- Groups:
--   G  Soil's image against the same 52 engine-written (float32, text) pairs StockGuard pins
--   E  the reloaded chamber under both readers; no reload; a real change; one float32 step;
--      110.29 L, which sits under the tolerance and is no bar for this
--   M  #1080's MINOR: an exactParts refusal is counted and logged
--
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function MAINT207_BENCH()

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


-- 52 (text, float32) pairs the engine wrote, lifted from 40 save files on 2026-10-02 (vehicles.xml
-- and placeables.xml fillLevel and amount attributes; 1646 distinct texts, every one the six-decimal
-- rendering of its float32, ties to even). 25 ties, every tie in the files.
local GOLDEN = {
    { "1989.148438", 1989.1484375, true },
    { "3321.617188", 3321.6171875, true },
    { "3376.867188", 3376.8671875, true },
    { "7234.101562", 7234.1015625, true },
    { "11664.148438", 11664.1484375, true },
    { "15726.289062", 15726.2890625, true },
    { "31485.726562", 31485.7265625, true },
    { "34181.476562", 34181.4765625, true },
    { "37057.335938", 37057.3359375, true },
    { "38893.960938", 38893.9609375, true },
    { "49787.492188", 49787.4921875, true },
    { "49981.710938", 49981.7109375, true },
    { "50639.476562", 50639.4765625, true },
    { "50787.757812", 50787.7578125, true },
    { "53012.335938", 53012.3359375, true },
    { "53502.335938", 53502.3359375, true },
    { "71037.335938", 71037.3359375, true },
    { "71514.976562", 71514.9765625, true },
    { "71914.835938", 71914.8359375, true },
    { "79660.007812", 79660.0078125, true },
    { "81836.382812", 81836.3828125, true },
    { "98836.867188", 98836.8671875, true },
    { "99998.398438", 99998.3984375, true },
    { "109467.132812", 109467.1328125, true },
    { "125419.585938", 125419.5859375, true },
    { "0.000003", 3.000000106112566e-06, false },
    { "0.001945", 0.0019450000254437327, false },
    { "0.014003", 0.014003000222146511, false },
    { "0.090361", 0.09036099910736084, false },
    { "0.250243", 0.25024300813674927, false },
    { "0.355000", 0.35499998927116394, false },
    { "0.501631", 0.5016310214996338, false },
    { "0.655395", 0.655394971370697, false },
    { "5.729167", 5.7291669845581055, false },
    { "15.650000", 15.649999618530273, false },
    { "16.551600", 16.551599502563477, false },
    { "173.998901", 173.9989013671875, false },
    { "344.992218", 344.9922180175781, false },
    { "444.990814", 444.9908142089844, false },
    { "847.307495", 847.3074951171875, false },
    { "1752.702759", 1752.7027587890625, false },
    { "2428.807373", 2428.807373046875, false },
    { "3116.525879", 3116.52587890625, false },
    { "4955.778809", 4955.77880859375, false },
    { "6902.572266", 6902.572265625, false },
    { "11988.944336", 11988.9443359375, false },
    { "21385.541016", 21385.541015625, false },
    { "51576.433594", 51576.43359375, false },
    { "108924.703125", 108924.703125, false },
    { "1.000000", 1.0, false },
    { "118.000000", 118.0, false },
    { "755.000000", 755.0, false },
}


-- ── MAINTENANCE row 207 ───────────────────────────────────────────────────────────────────
-- The bench's own float32: string.pack (fengari's 5.3; the game's 5.1 has none, so production
-- cannot use it). It shares no code with BC.nativeFloatImage.
local function f32(x) return (string.unpack("<f", string.pack("<f", x))) end
local function digits(text) return tonumber((text:gsub("%.", ""))) end
local IMAGE = BC.nativeFloatImage

-- ══════════════════════════════════════════════════════════════════════════
-- G. SOIL'S IMAGE AGAINST WHAT THE ENGINE WROTE (the pairs StockGuard's row 206 bench pins too)
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    local okV, okD, okF, tiesUp, tiesDown, firstBad = 0, 0, 0, 0, 0, nil
    for _, g in ipairs(GOLDEN) do
        local text, v, tie = g[1], g[2], g[3]
        local want = digits(text)
        if IMAGE(v) == want then okV = okV + 1 elseif firstBad == nil then firstBad = text .. ":v" end
        if IMAGE(tonumber(text)) == want then okD = okD + 1 elseif firstBad == nil then firstBad = text .. ":double" end
        if IMAGE(f32(tonumber(text))) == want then okF = okF + 1 elseif firstBad == nil then firstBad = text .. ":float32" end
        if tie then
            if want > math.floor(v * 1000000) then tiesUp = tiesUp + 1 else tiesDown = tiesDown + 1 end
        end
    end
    local n = #GOLDEN
    T.eq("G1 NAMED: Soil's image of every float32 the engine wrote, and of its text read back as a double and as a float32, is the written text's count of millionths: the same 52 pairs StockGuard's MAINT-206 bench pins",
        okV .. "/" .. okD .. "/" .. okF .. " of " .. n .. " " .. tostring(firstBad), n .. "/" .. n .. "/" .. n .. " of " .. n .. " nil")
    T.eq("G2 the pairs hold ties both ways, so a tie rule that always rounds one way fails G1", tostring(tiesUp > 0) .. "/" .. tostring(tiesDown > 0) .. "/" .. (tiesUp + tiesDown), "true/true/25")
    T.eq("G3 the edges: not a number, an infinity and NaN give nil; zero and a level far below six decimals give 0; a negative level is the negative of its image",
        tostring(IMAGE("1")) .. "/" .. tostring(IMAGE(math.huge)) .. "/" .. tostring(IMAGE(0 / 0)) .. "/" .. tostring(IMAGE(0)) .. "/" .. tostring(IMAGE(1e-40)) .. "/" .. tostring(IMAGE(-100.37) == -IMAGE(100.37)),
        "nil/nil/nil/0/0/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: A SQUARE BALE FINISHED FROM A RELOADED CHAMBER
-- ══════════════════════════════════════════════════════════════════════════
--- The chamber record SG-1 reattaches after a reload (MAINTENANCE row 206): its account at the
--- pre-save litres, known at `pct` %, adopted by Soil's own combine as StockGuard 5d's settle
--- hands it.
local function recordOf(litres, pct)
    local spec = SG.props[1] and SG.props[1][2] or nil
    if spec == nil then return nil end
    return spec.combine(ctxOf("op9", { { allocation = 1, account = acct(litres, litres, 0, 0, litres * pct) } }), { leg("op9", 1, litres, rec(3, 120, litres)) }, nil)
end
--- A square Baler whose chamber the engine reloaded at `level` while StockGuard's record holds
--- `saved` litres: the pickup (10 L wet, the rest dry, a little over the level) fills the chamber to `level` and the bale
--- finishes inside the add, reading the record. The bale's birth wetness, nil when born unknown.
local function reloadedBale(saved, level)
    world()
    local v = baler({ capacity = level })
    installAll()
    stockGuard()
    W.sys.groundConditionProperty:register(W.sys.groundConditionCoordinator, g_currentMission)
    SG.record = recordOf(saved, 40)
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, math.ceil((level - 10) / 2) + 1)
    local ok = pcall(ENGINE.tick, v, 16)
    local first = bales(v)[1]
    if not ok then return "raised" end
    return num(first and birthOf(first.baleObject))
end
group("E", function()
    -- 100.37 L is written "100.370003": read back as a float32 (100.37000274658203) it is 2.7e-6 L
    -- over the saved litres, as a double 3e-6 L; both past BC.TOLERANCE (1e-6).
    local asFloat32, asDouble = f32(100.37), tonumber("100.370003")
    T.eq("E0 [world] the readbacks of 100.37 L both differ from it by more than BC.TOLERANCE",
        tostring(asFloat32 - 100.37 > BC.TOLERANCE) .. "/" .. tostring(asDouble - 100.37 > BC.TOLERANCE), "true/true")
    T.eq("E1 NAMED [entry point]: a reloaded chamber read back as a float32 finishes a bale born with the record's 40 %, not unknown",
        reloadedBale(100.37, asFloat32), "40")
    T.eq("E2 NAMED: read back as a double, the same", reloadedBale(100.37, asDouble), "40")
    T.eq("E3 [control] no reload (the chamber at the record's own litres): 40 on either head", reloadedBale(100.37, 100.37), "40")
    T.eq("E4 [control] the chamber really changed (100.38 L against a record of 100.37): the gap is unknown and the bale is born unknown, as before",
        reloadedBale(100.37, 100.38), "nil")
    T.eq("E5 the chamber one float32 step away (the smallest change a save can carry at 100 L) is a real change: born unknown",
        reloadedBale(100.37, asFloat32 + 2 ^ -17), "nil")
    -- 110.29 L rounds by 9.2e-7 (float32) and 1e-6 (double), under BC.TOLERANCE on both: a bar at
    -- that level passes on either head and cannot see the defect (Bob's intake).
    T.eq("E6 [control] 110.29 L reloads under the tolerance on both readers, so it is 40 on either head and is no bar for this",
        reloadedBale(110.29, f32(110.29)) .. "/" .. reloadedBale(110.29, tonumber("110.290001")), "40/40")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. #1080's MINOR: AN exactParts REFUSAL IS COUNTED AND LOGGED
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    world()
    local mw = W.sys.materialWetness
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 52)
    local snap = mw:collectedSnapshot(GR, { { gx = 2, gz = 8, litres = 40 }, { gx = 3, gz = 8, litres = 100 } })
    local batch = { sources = { { snapshot = snap, id = "2:8", raw = 40 }, { snapshot = snap, id = "3:8", raw = 100 } } }
    local lines, debug = {}, SoilLogger.debug
    SoilLogger.debug = function(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
    local before = BC.stats.sealRefused
    local cov = BC.sealBatch(mw, batch, 0, 140, 1)
    SoilLogger.debug = debug
    local logged = false
    for _, l in ipairs(lines) do if l == "[BalerCollection] seal refused (REMAINDER)" then logged = true end end
    T.eq("M1 a seal exactParts refuses (here a zero total) returns nothing, counts one refused seal and logs '[BalerCollection] seal refused (REMAINDER)', as sealAllocation's refusal does",
        tostring(cov) .. "/" .. (BC.stats.sealRefused - before) .. "/" .. tostring(logged), "nil/1/true")
end)
end
MAINT207_BENCH()
