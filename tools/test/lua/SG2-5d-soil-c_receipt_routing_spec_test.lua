-- SG2-5d-soil-c_receipt_routing_spec_test.lua
--
-- SG2-5 slice 5d-soil-c (Bob's R-15 on StockGuard #33, Drafts/BOB-R15-SG2-5D-A-2026-10-02.md): Soil's
-- collected reader resolves each receipt by its own producer. MaterialWetness:resolveAllocation sent
-- EVERY receipt to StockGuard once StockGuard published readCollectionReceipt (StockGuard 5d-a), so
-- Soil's own seals, for every collection Soil carries itself, went unresolved and every such bale
-- was born unknown with StockGuard installed.
--   * sealAllocation's receipt names Soil as its producer (MaterialWetness.PRODUCER_SOIL);
--   * resolveAllocation resolves a receipt that names Soil from Soil's own store, whatever else is
--     installed; any other receipt is StockGuard's when it publishes its resolver, its answer the
--     only one; without StockGuard, Soil's store as before. Never both for one receipt.
--
-- THE ENTRY-POINT BAR IS GROUP E, TWO-SIDED: the RSF-F211-s6b world (production's
-- SoilFertilitySystem.new, the owners armed in production's order, HookManager:installAll on a
-- Baler or ForageWagon built as the engine builds it, WorkArea's tick), the same swaths worked with
-- and without a StockGuard handle that publishes readCollectionReceipt (a recorder answering from
-- StockGuard's own keyspace); the bale is born on the yard ladder's real row. On 2dd42a22 the
-- StockGuard side of every E row is born unknown.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG25DSC_BENCH()

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


-- ── StockGuard's mission handle publishing its receipt resolver (StockGuard #33) ─────
-- A recorder of readCollectionReceipt that keeps every argument and answers from its OWN store,
-- keyed as StockGuard keys it ("sg.allocation#n", SGCollectionSeal): a receipt StockGuard did not
-- seal is UNAVAILABLE there, as SGCollectionSeal.read answers it.
local MW = MaterialWetness
local SG = {}
local function stockGuardOn(opts)
    opts = opts or {}
    SG = { calls = {}, store = opts.store or {} }
    g_currentMission.stockGuard = {
        readCollectionReceipt = function(...)
            local receipt = ...
            SG.calls[#SG.calls + 1] = { n = select("#", ...), receipt = receipt }
            if opts.raises then error("stockguard raised") end
            local id = type(receipt) == "table" and receipt.allocationId or nil
            local a = id ~= nil and SG.store[id] or nil
            if a == nil then return nil, "UNAVAILABLE" end
            return a
        end,
    }
end
--- A Baler of `kind` working the standard swaths, with or without StockGuard's resolver published:
--- the birth wetness of the bale it makes (nil = unknown) and how often StockGuard was asked.
local function swaths()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
end
local function baleOf(kind, withStockGuard)
    world()
    local v
    if kind == "round" then v = baler({ capacity = 100, round = true }) else v = baler({ capacity = 100 }) end
    installAll()
    if withStockGuard then stockGuardOn() end
    swaths()
    local ok = pcall(ENGINE.tick, v, 16)
    if not ok then return "raised" end
    return num(birthOf(lastBale(v))) .. "/" .. #bales(v)
end
--- The unfinished round bale of a non-stop round baler (RSF-F211 part 2b): 60 L wet into the
--- chamber, 20 L dry in the buffer, then unloaded unfinished.
local function unfinishedOf(withStockGuard)
    world()
    local v = nonStop({ capacity = 100, round = true, canUnloadUnfinishedBale = true })
    installAll()
    if withStockGuard then stockGuardOn() end
    local ok = pcall(function()
        setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 15) windrow(3, 15)
        ENGINE.tick(v, 16)
        BALER_MODEL.updateTick(v, 1000)
        setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 5) windrow(3, 5)
        ENGINE.tick(v, 16)
        v:setIsUnloadingBale(true)
    end)
    if not ok then return "raised" end
    return num(birthOf(lastBale(v)))
end
--- A forage wagon's load over the standard swaths: its condition.
local function wagonOf(withStockGuard)
    world()
    local o = { x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth, capacity = 1000 }
    local w = BALER_MODEL.newWagon(o)
    g_currentMission.vehicleSystem:addVehicle(w)
    installAll()
    if withStockGuard then stockGuardOn() end
    swaths()
    local ok = pcall(ENGINE.tick, w, 16)
    if not ok then return "raised" end
    return num(w:getFillUnitFillLevel(1)) .. "/" .. num(ForageWagonCollection.condition(w))
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR, TWO-SIDED: SOIL'S OWN COLLECTIONS WITH STOCKGUARD'S RESOLVER PUBLISHED
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    T.ok("E0 [world] the family arms in production's order", world() == true)
    local without = baleOf("square", false)
    local with = baleOf("square", true)
    T.eq("E1 NAMED [entry point]: a square bale Soil carries itself is born with its condition with StockGuard's readCollectionReceipt published, the same as without StockGuard, and StockGuard is never asked for Soil's own seal",
        without .. " | " .. with .. " | " .. #SG.calls, "26.063/1 | 26.063/1 | 0")
    T.eq("E2 NAMED: a round bale, the same", baleOf("round", false) .. " | " .. baleOf("round", true) .. " | " .. #SG.calls, "26.063/1 | 26.063/1 | 0")
    local u0, u1 = unfinishedOf(false), unfinishedOf(true)
    T.eq("E3 NAMED: a non-stop round baler's unfinished bale (the chamber's 60 L wet and the buffer's 20 L dry), the same",
        u0 .. " | " .. u1 .. " | " .. #SG.calls, num((60 * WET + 20 * DRY) / 80) .. " | " .. num((60 * WET + 20 * DRY) / 80) .. " | 0")
    T.eq("E4 NAMED: a forage wagon's load, the same", wagonOf(false) .. " | " .. wagonOf(true) .. " | " .. #SG.calls, "100/26.063 | 100/26.063 | 0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. SOIL'S RECEIPTS NAME THEIR PRODUCER, AND RESOLVE FROM SOIL'S STORE
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    world()
    local v = baler({ capacity = 100 })
    installAll()
    stockGuardOn()
    local mw = W.sys.materialWetness
    local receipts = {}
    mw.sealAllocation = function(self, ...)
        local r, why = MW.sealAllocation(self, ...)
        receipts[#receipts + 1] = r
        return r, why
    end
    swaths()
    ENGINE.tick(v, 16)
    mw.sealAllocation = nil
    local tagged = 0
    for _, r in ipairs(receipts) do if r.producer == "SOIL" then tagged = tagged + 1 end end
    T.eq("T1 NAMED: every receipt Soil's own seal returns names Soil as its producer, SOIL",
        tostring(MW.PRODUCER_SOIL) .. "/" .. tostring(#receipts > 0) .. "/" .. tagged .. "/" .. #receipts, "SOIL/true/" .. #receipts .. "/" .. #receipts)
    local r = receipts[1]
    local a, src = mw:resolveAllocation(r)
    T.eq("T2 NAMED: with StockGuard's resolver published, Soil's receipt resolves from Soil's own store, and StockGuard is not asked",
        tostring(a ~= nil and a == mw.allocations[r.allocationId]) .. "/" .. tostring(src) .. "/" .. #SG.calls, "true/SOIL/0")
    local forged = { allocationId = "sg.allocation#1", producer = MW.PRODUCER_SOIL }
    SG.store["sg.allocation#1"] = { sealed = true }
    local fa, fsrc = mw:resolveAllocation(forged)
    T.eq("T3 a receipt naming Soil as producer but an allocation Soil does not hold resolves nothing, from Soil's store only: the name cannot reach another producer's seal",
        tostring(fa) .. "/" .. tostring(fsrc) .. "/" .. #SG.calls, "nil/SOIL/0")
    g_currentMission.stockGuard = nil
    local plain = { allocationId = r.allocationId }
    local pa, psrc = mw:resolveAllocation(plain)
    T.eq("T4 with StockGuard absent, a receipt with no producer named resolves from Soil's store, as before", tostring(pa == mw.allocations[r.allocationId]) .. "/" .. tostring(psrc), "true/SOIL")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. EVERY OTHER RECEIPT IS STOCKGUARD'S, AND ITS ANSWER IS THE ONLY ONE
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    world()
    local mw = W.sys.materialWetness
    local sgAlloc = { sealed = true, snapshotId = "COLLECTED_NATIVE_VOLUME_V1#1", acceptedCarrierLitres = 10, parts = {} }
    stockGuardOn({ store = { ["sg.allocation#1"] = sgAlloc } })
    local receipt = { allocationId = "sg.allocation#1" }
    local a, src = mw:resolveAllocation(receipt)
    T.eq("S1 NAMED: a StockGuard receipt resolves through readCollectionReceipt, once, as a dot call with the receipt itself",
        tostring(a == sgAlloc) .. "/" .. tostring(src) .. "/" .. #SG.calls .. "/" .. tostring(SG.calls[1] and SG.calls[1].n) .. "/" .. tostring(SG.calls[1] and SG.calls[1].receipt == receipt),
        "true/STOCKGUARD/1/1/true")
    -- An allocation Soil does hold, named by a receipt that does not name Soil as its producer.
    mw.allocations["allocation#1"] = { sealed = true }
    local b, bsrc = mw:resolveAllocation({ allocationId = "allocation#1" })
    T.eq("S2 NAMED: a receipt that does not name Soil is StockGuard's alone: StockGuard's UNAVAILABLE stands and Soil's store is not consulted (never both)",
        tostring(b) .. "/" .. tostring(bsrc) .. "/" .. #SG.calls, "nil/STOCKGUARD/2")
    local c, csrc = mw:resolveAllocation({ allocationId = "sg.allocation#1", producer = "STOCKGUARD" })
    T.eq("S3 a receipt naming another producer goes to StockGuard", tostring(c == sgAlloc) .. "/" .. tostring(csrc), "true/STOCKGUARD")
    stockGuardOn({ raises = true })
    local d, dsrc = mw:resolveAllocation({ allocationId = "sg.allocation#1" })
    T.eq("S4 a resolver that raises answers nothing, not Soil's store", tostring(d) .. "/" .. tostring(dsrc), "nil/STOCKGUARD")
    g_currentMission.stockGuard = nil
end)
end
SG25DSC_BENCH()
