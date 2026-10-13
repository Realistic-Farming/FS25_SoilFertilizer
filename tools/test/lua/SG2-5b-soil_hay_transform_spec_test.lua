-- SG2-5b-soil_hay_transform_spec_test.lua
--
-- SG2-5 slice 5b-soil (SG-2 v2.3 :296, :652, :684; Bob's 5b ruling, Q3, FAST TRACK): Soil's
-- `soil.groundCondition` transform carries combine's own rule when a Tedder pass converts grass
-- windrow to dry grass on the profile's basis NATIVE_HAY_CONVERT_V1, so StockGuard's tedder path
-- keeps the condition Soil's own tedder carrier already carries. Any other basis, or none, stays
-- UNKNOWN (src/ground/GroundConditionProperty.lua).
--
-- THE ENTRY-POINT BAR IS GROUP E. Production's system (SoilFertilitySystem.new) runs its own
-- initialize, which registers the property through the mission's StockGuard handle, a RECORDER of
-- StockGuard's (StockGuard.lua:115 and :121) that keeps every argument. The rows then call the
-- transform the recorder captured, with dots and in SG-1's own shape (SGOperations.lua:789:
-- the context, the portions with their allocation's conversion basis, one destination entry with
-- the candidate's litres and destinationBefore). Nothing pre-fills the registration.
--
-- StockGuard's real SG-1 is not loaded here. The joined run against it is a throwaway, outside
-- the repo (the PR body names it).
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG25BS_BENCH()
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local GP = GroundConditionProperty

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function countWarn(pattern)
    local n = 0
    for _, w in ipairs(WARN) do if w:find(pattern, 1, true) then n = n + 1 end end
    return n
end

-- The engine's mod-listener registry, which installAll and uninstallAll call, and the fruit
-- registry initialize's last line lists (FruitTypeManager:getFruitTypes).
addModEventListener = addModEventListener or function() end
removeModEventListener = removeModEventListener or function() end
g_fruitTypeManager.getFruitTypes = g_fruitTypeManager.getFruitTypes or function() return {} end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

-- ── A recorder of StockGuard's mission handle ───────────────────────────────
-- StockGuard.lua:115 (registerProperty) and :121 (unregisterOwner), dot-called closures. It
-- keeps every argument it is given and answers as the registry does: a lease, or nil and a
-- reason (SGRegistry.lua:69-79 and :264-272).
local function recorder(refuse)
    local r = { registers = {}, unregisters = {}, handle = {}, lease = nil }
    r.handle.registerProperty = function(...)
        local args = { n = select("#", ...), ... }
        r.registers[#r.registers + 1] = args
        if refuse ~= nil then return nil, refuse end
        r.lease = { leaseId = "1:" .. #r.registers, kind = "property", ownerId = args[1], live = true }
        return r.lease
    end
    r.handle.unregisterOwner = function(...)
        local args = { n = select("#", ...), ... }
        r.unregisters[#r.unregisters + 1] = args
        if type(args[1]) == "table" then args[1].live = false end
        return true
    end
    return r
end

-- ── The world: production's system, its own initialize ─────────────────────
local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local function world(opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    WARN = {}
    SoilMaterialDownBridge.ledgerActive = false
    local settings = { enabled = true }
    -- The player's Experimental Systems switch (ReleaseGate.liveOptIn), off when a row says so.
    if opts.gateClosed then settings.allowsExperimentalSystems = function() return false end end
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    -- The store is the world's, established before the arm chain runs; its own initialize and
    -- delete are not under test.
    vm.initialize = function() end
    vm.delete = function() end
    sys.valueMaps = vm
    local rec = nil
    if not opts.noStockGuard then rec = recorder(opts.refuse) end
    W.sys, W.age, W.wet, W.rec = sys, age, wet, rec
    g_currentMission = {
        environment = { currentMonotonicDay = 100, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {}, addVehicle = function() return true end },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
        missionInfo = { savegameDirectory = "c1", isValid = false },
        stockGuard = rec ~= nil and rec.handle or nil,
    }
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function() return nil end
    local ok, err = pcall(sys.initialize, sys)
    W.initOk, W.initErr = ok, err
    -- The owners' cursors, as their own first ticks leave them.
    sys.materialDown.ageAppliedThroughDay = 100
    sys.materialWetness.appliedThroughDay = 100
    return ok
end
local function coord() return W.sys.groundConditionCoordinator end
local function prop() return W.sys.groundConditionProperty end
--- Nil-safe, so a system that never built the property fails a row instead of the group.
local function registered() local p = prop() return p ~= nil and p:isRegistered() end
--- The spec the recorder was handed, and its callbacks as SG-1 calls them.
local function spec() return W.rec.registers[1][2] end
local function resolve(ctx) return spec().resolveResident(ctx) end
local function revision(ctx) return spec().getResidentRevision(ctx) end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
--- The context SG-1 builds for one ground stock (SGOperations.lua:1602-1607): the pixel's
--- footprint as SGNativeAdapters.groundState names it.
local function ctx(x, z, size, amount, purpose)
    return { stockRef = { stockId = "s1", contentsGeneration = 1, dataRevision = "r1" },
             carrierKey = { adapterId = "sg.ground", nativeOwnerKey = "map", componentKey = "ground:" .. x .. ":" .. z },
             purpose = purpose or "READ", quantityBasisKey = "LITRE", amount = amount or 8, unit = "LITRE",
             footprint = { kind = "GROUND_CELL", x = x, z = z, size = size or 1 } }
end
local function brief(rec, why)
    if rec == nil then return "nil/" .. tostring(why) end
    local p = rec.payload or {}
    return table.concat({ tostring(rec.knowledge), tostring(p.ageRaw), tostring(p.wetnessRaw),
        tostring(rec.knownAmount) .. "of" .. tostring(rec.basisAmount), tostring(rec.amountUnit) }, "/")
end
-- Engine geometry: 64 m terrain, 16 cells of 4 m from -32; pixels of 1 m. Cell 8 holds
-- x 0..4, cell 9 holds x 4..8; row 8 holds z 0..4.

-- SG-1's inputs to transform (SGOperations.lua:789): the portions (:1033-1051), each with
-- its allocation's conversion basis, and one destination entry carrying the candidate's litres
-- and its destinationBefore snapshot (:1117-1126).
local HAY = "NATIVE_HAY_CONVERT_V1"
local function rec(ageRaw, wetRaw, ageDay, litres, knowledge, account)
    return { propertyId = "soil.groundCondition", schemaVersion = 1, producerId = "soil", propertyRevision = 0,
             knowledge = knowledge or "KNOWN", knownAmount = litres, basisAmount = litres, amountUnit = "LITRE",
             payload = { ageRaw = ageRaw, wetnessRaw = wetRaw, ageDay = ageDay, account = account } }
end
local function portion(litres, r, basis)
    return { amount = litres, unit = "LITRE", conversionBasisId = basis, properties = { ["soil.groundCondition"] = r } }
end
local function dest(litres, r)
    return { observedAmount = litres, amountUnit = "LITRE", properties = { ["soil.groundCondition"] = r } }
end
local function destination(amount, before)
    return { { carrierId = "buffer", stockRef = { stockId = "s9" }, amount = amount, unit = "LITRE",
               materialRef = { kind = "FILL_TYPE", fillTypeName = "DRYGRASS_WINDROW" }, destinationBefore = before } }
end
local CONVERT = { operationId = "op1", operationKind = "CONVERT", report = { outcomeEvidence = { nativePath = "TEDDER" } } }
--- A record's payload in full, so a carried and a combined record can be compared field by field.
local function full(r)
    if r == nil then return "nil" end
    local p = r.payload or {}
    local a = p.account
    local function g(x) return type(x) == "number" and string.format("%g", x) or tostring(x) end
    local acc = a == nil and "-" or table.concat({ g(a.carrierLitres), g(a.knownCarrierLitres), g(a.unknownCarrierLitres),
        g(a.refusedCarrierLitres), g(a.knownWeightedPctSum) }, ",")
    return table.concat({ tostring(r.knowledge), tostring(p.ageRaw), tostring(p.wetnessRaw), tostring(p.ageDay), acc,
        tostring(r.knownAmount) .. "of" .. tostring(r.basisAmount), tostring(r.amountUnit) }, "/")
end
local function acct(c, k, u, rf, w) return { carrierLitres = c, knownCarrierLitres = k, unknownCarrierLitres = u, refusedCarrierLitres = rf, knownWeightedPctSum = w } end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR: production's registration, its transform as SG-1 calls it
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local ok = world()
    T.ok("E0 [entry point] with StockGuard's handle, initialize ran to its end and registered soil.groundCondition once (" .. tostring(W.initErr) .. ")",
        ok and W.sys.isInitialized == true and registered() and #W.rec.registers == 1)
    -- One tedder pass's pickup into the dry-grass buffer: grass windrow on the hay basis.
    local t = spec().transform(CONVERT, { portion(30, rec(5, 60, 100, 30), HAY) }, destination(30, nil))
    T.eq("E1 NAMED [entry point]: a grass windrow converted on the Tedder's hay basis keeps its condition (the captured transform, called as SG-1 calls it)",
        full(t), "KNOWN/5/60/100/-/30of30/LITRE")
    T.eq("E2 the carried record validates", spec().validate(t), true)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE HAY BASIS CARRIES COMBINE'S RULE; ANYTHING ELSE STAYS UNKNOWN
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    world()
    local transform, combine = spec().transform, spec().combine
    local grass = portion(30, rec(5, 60, 100, 30), HAY)
    local dry = portion(10, rec(3, 40, 98, 10))
    local remainder = dest(20, rec(7, 90, 99, 20))
    T.eq("H1 NAMED: converted grass and unchanged dry grass in one pass carry combine's own floor, aged to the newest stamp (SGOperations.lua:752 sends both here)",
        full(transform(CONVERT, { grass, dry }, destination(40, nil))), full(combine(CONVERT, { grass, dry }, nil)))
    T.eq("H1b and that floor is the conservative one, not the converted part's alone", full(transform(CONVERT, { grass, dry }, destination(40, nil))),
        "KNOWN/5/60/100/-/40of40/LITRE")
    T.eq("H2 the buffer's remainder of the target type joins as destinationBefore, as in combine",
        full(transform(CONVERT, { grass }, destination(50, remainder))), full(combine(CONVERT, { grass }, remainder)))
    T.eq("H3 another basis alone is UNKNOWN, as before", full(transform(CONVERT, { portion(30, rec(5, 60, 100, 30), "OTHER_CONVERT_V1") }, destination(30, nil))),
        "UNKNOWN/0/24/nil/-/0of30/LITRE")
    T.eq("H4 the hay basis beside any other basis is UNKNOWN: one foreign conversion spoils the candidate",
        full(transform(CONVERT, { grass, portion(10, rec(3, 40, 100, 10), "OTHER_CONVERT_V1") }, destination(40, nil))), "UNKNOWN/0/24/nil/-/0of40/LITRE")
    T.eq("H5 no contribution on the hay basis is UNKNOWN, as before (a candidate with no conversion of its own)",
        full(transform(CONVERT, { dry }, destination(10, nil))) .. " " .. full(transform(CONVERT, {}, destination(10, remainder))),
        "UNKNOWN/0/24/nil/-/0of10/LITRE UNKNOWN/0/24/nil/-/0of10/LITRE")
    T.eq("H6 the record is stated at the destination's litres", full(transform(CONVERT, { grass }, destination(25, nil))), "KNOWN/5/60/100/-/25of25/LITRE")
    local withdrawn = rec(9, 200, 100, 10, "UNAVAILABLE")
    T.eq("H7 a contribution SG-1 qualified is unknown here as in combine", full(transform(CONVERT, { grass, portion(10, withdrawn) }, destination(40, nil))),
        full(combine(CONVERT, { grass, portion(10, withdrawn) }, nil)))
    local withAcc = portion(30, rec(5, 60, 100, 30, "KNOWN", acct(30, 30, 0, 0, 1500)), HAY)
    T.eq("H8 a collected account is carried and summed by carrier litres, as in combine",
        full(transform(CONVERT, { withAcc, dry }, destination(40, nil))), "KNOWN/5/60/100/40,30,10,0,1500/40of40/LITRE")
    local okBad, bad = pcall(transform, CONVERT, { grass, "not a portion" }, destination(30, nil))
    T.eq("H9 a malformed contribution list is UNKNOWN, not raised on", tostring(okBad) .. "/" .. full(bad), "true/UNKNOWN/0/24/nil/-/0of30/LITRE")
    T.eq("H10 no destination entry: the record carries no amount", full(transform(CONVERT, { grass }, nil)), "KNOWN/5/60/100/-/nilofnil/nil")
    local okZero, zero = pcall(transform, CONVERT, { portion(0, rec(5, 60, 100, 0), HAY) }, destination(0, nil))
    T.eq("H12 a hay conversion of no material is UNKNOWN over the destination's litres, not raised on", tostring(okZero) .. "/" .. full(zero),
        "true/UNKNOWN/0/24/nil/-/0of0/LITRE")
    T.eq("H11 every carried record validates", tostring(spec().validate(transform(CONVERT, { grass, dry }, destination(40, remainder)))), "true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RULE ITSELF
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local c = GP.carriesThroughConversion
    T.eq("R1 at least one hay-based contribution and no other basis carries; none, another, or a malformed entry does not",
        table.concat({ tostring(c({ { conversionBasisId = HAY } })), tostring(c({ { conversionBasisId = HAY }, {} })), tostring(c({ {} })),
            tostring(c({})), tostring(c({ { conversionBasisId = HAY }, { conversionBasisId = "X" } })), tostring(c({ 5 })), tostring(c(nil)) }, " "),
        "true true false false false false false")
    T.eq("R2 the basis is the profile's own name (SG-2 v2.3 :652)", GP.HAY_CONVERT_BASIS, "NATIVE_HAY_CONVERT_V1")
end)
end
SG25BS_BENCH()
