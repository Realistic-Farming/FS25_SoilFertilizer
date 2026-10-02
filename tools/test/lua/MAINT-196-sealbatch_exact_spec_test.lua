-- MAINT-196-sealbatch_exact_spec_test.lua
--
-- MAINTENANCE row 196: Soil's BC.sealBatch seals every batch exactly. The parts of a seal, summed in
-- canonical order, must equal the producer's accepted carrier A_b exactly
-- (MaterialWetness:sealAllocation, RECEIPT_TOTAL_MISMATCH; the reader checks the same equality).
-- The old correction moved only the last part, up to four times, and cannot close the sum when the
-- parts before it sum to an odd multiple of half A_b's unit in the last place: the seal was
-- refused, its known litres were booked unknown, and the bale was born unknown. sealBatch now cuts
-- every part before the last to a multiple of the power-of-two quantum Q = 2^(e - 40), where
-- 2^e <= A_b < 2^(e + 1) (StockGuard 5d-a's exact(), SGCollectionSeal), so the closing sum is A_b
-- exactly and no material is added (RSF-F211 :134).
--
-- THE ENTRY-POINT BAR IS GROUP E: the RSF-F211-s6b world as the 5d-soil-c bench builds it
-- (production's SoilFertilitySystem.new, the owners armed in production's order,
-- HookManager:installAll on a square Baler built as the engine builds it, WorkArea's tick). Two
-- cells are picked up into one add whose seal the old correction cannot close, and the bale is
-- born on the yard ladder's real row. On 2ac3270e both E rows are born unknown.
-- Group X runs the real sealBatch against a real collected snapshot, the real sealAllocation and
-- the real reader. Each sweep also counts how many of its seals the old correction would have
-- missed, replayed beside it, so a sweep that cannot see the defect shows as one.
--
-- NOT RUN, and why:
--   - BC.exactParts' guard on a zero, negative or non-finite total: closeCall calls sealBatch only with
--     a known target above BC.EPSILON.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function MAINT196_BENCH()

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

local MW = MaterialWetness

-- The old correction (BalerCollection.lua at 2ac3270e), replayed: the remainder on the last part,
-- then up to four corrections of that part alone. true when the seal would have been refused.
local function oldMisses(A_b, raws, R)
    local ids = {}
    for id in pairs(raws) do ids[#ids + 1] = id end
    table.sort(ids)
    local q, sum = {}, 0
    for i, id in ipairs(ids) do
        q[i] = A_b * raws[id] / R
        if i < #ids then sum = sum + q[i] end
    end
    q[#q] = A_b - sum
    for _ = 1, 4 do
        local s = 0
        for _, x in ipairs(q) do s = s + x end
        if s == A_b then return false end
        q[#q] = q[#q] + (A_b - s)
    end
    local s = 0
    for _, x in ipairs(q) do s = s + x end
    return s ~= A_b
end

-- A 53-bit uniform draw from a fixed seed: two 31-bit steps of a linear congruential generator.
local seed = 196
local function step() seed = (seed * 1103515245 + 12345) % 2147483648 return seed end
local function uniform() local hi, lo = step(), step() return (hi * 4194304 + math.floor(lo / 512)) / 9007199254740992 end

-- The real collected snapshot of cells 2.. of row 8 holding `raws` litres, wet and dry alternately.
local function snapshotOver(raws)
    local cells = {}
    for i, r in ipairs(raws) do
        setCell(1 + i, 8, 1, (i % 2 == 1) and 204 or 52)
        cells[#cells + 1] = { gx = 1 + i, gz = 8, litres = r }
    end
    return W.sys.materialWetness:collectedSnapshot(GR, cells)
end
local function batchOver(snap, raws)
    local sources, byId, R = {}, {}, 0
    for i, r in ipairs(raws) do
        local id = (1 + i) .. ":8"
        sources[#sources + 1] = { snapshot = snap, id = id, raw = r }
        byId[id] = r
        R = R + r
    end
    return { sources = sources }, byId, R
end
-- The real sealBatch: true when the reader reads the whole total, with the coverage.
local function seal(snap, raws, A_b)
    local batch, byId, R = batchOver(snap, raws)
    local cov = BC.sealBatch(W.sys.materialWetness, batch, A_b, R, 1)
    local good = cov ~= nil and cov.status ~= MW.RESULT.UNAVAILABLE and cov.carrierLitres == A_b
    return good, cov, byId, R
end

group("E", function()
    -- A 110.29 L chamber fills from 40 L wet and 100 L dry (2 x 20 and 2 x 50 litres per pixel):
    -- the add's seal is 110.29 over raws 40 and 100, which the old correction cannot close.
    world()
    BC.stats.sealed, BC.stats.sealRefused = 0, 0
    local v = baler({ capacity = 110.29 })
    local okInstall = installAll()
    setCell(2, 8, 1, 204) windrow(2, 20)
    setCell(3, 8, 1, 52)  windrow(3, 50)
    local ok = pcall(ENGINE.tick, v, 16)
    local first = bales(v)[1]
    T.eq("E0 [reached] installAll wrapped the square Baler, its tick ran, a bale finished and the add's seal went through BC.sealBatch",
        tostring(okInstall) .. "/" .. tostring(ok) .. "/" .. #bales(v) .. "/" .. tostring(BC.stats.sealed >= 1), "true/true/1/true")
    T.eq("E1 NAMED [entry point]: a 110.29 L chamber filled from 40 L wet and 100 L dry seals exactly, nothing refused, and the bale is born with the cells' raw-weighted wetness (40 x wet + 100 x dry) / 140",
        num(first and birthOf(first.baleObject)) .. " refused " .. BC.stats.sealRefused, num((40 * WET + 100 * DRY) / 140) .. " refused 0")

    -- A 27.7 L chamber filled exactly by 2.56 L wet and 25.14 L dry (2 x 1.28 and 2 x 12.57): the
    -- add is the whole pickup, and the old correction still cannot close 27.7 over these raws.
    world()
    BC.stats.sealed, BC.stats.sealRefused = 0, 0
    local v2 = baler({ capacity = 27.7 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 1.28)
    setCell(3, 8, 1, 52)  windrow(3, 12.57)
    pcall(ENGINE.tick, v2, 16)
    local b2 = bales(v2)[1]
    T.eq("E2 NAMED [entry point]: a chamber filled exactly (27.7 L from 2.56 L wet and 25.14 L dry) seals exactly and the bale is born with (2.56 x wet + 25.14 x dry) / 27.7",
        #bales(v2) .. " " .. num(b2 and birthOf(b2.baleObject)) .. " refused " .. BC.stats.sealRefused, "1 " .. num((2.56 * WET + 25.14 * DRY) / 27.7) .. " refused 0")
    T.eq("E3 [control] the old correction misses both E seals (replayed on the same totals and raws)",
        tostring(oldMisses(110.29, { ["2:8"] = 40, ["3:8"] = 100 }, 140)) .. "/" .. tostring(oldMisses(27.7, { ["2:8"] = 2.56, ["3:8"] = 25.14 }, 27.7)), "true/true")
end)

group("X", function()
    world()
    -- Fred's example: 123.456 L over raws 1, 5 and 10.
    local raws = { 1, 5, 10 }
    local snap = snapshotOver(raws)
    local sealed = nil
    local realSeal = MW.sealAllocation
    W.sys.materialWetness.sealAllocation = function(self, snapshot, A, parts, ...)
        sealed = {}
        for i, p in ipairs(parts) do sealed[i] = p.carrierLitres end
        return realSeal(self, snapshot, A, parts, ...)
    end
    local good, cov = seal(snap, raws, 123.456)
    W.sys.materialWetness.sealAllocation = nil
    local A, R = 123.456, 16
    local Q = 64 * 2 ^ -40
    local within = sealed ~= nil and #sealed == 3
    if within then
        for i = 1, 2 do
            local ideal = A * raws[i] / R
            if not (sealed[i] <= ideal and ideal - sealed[i] < Q and sealed[i] / Q == math.floor(sealed[i] / Q)) then within = false end
        end
    end
    T.eq("X1 NAMED: 123.456 L over raws 1, 5 and 10 seals; the reader reads 123.456 known; the parts before the last are cut down by under one quantum (2^-34) onto it; the old correction misses this seal",
        tostring(good) .. "/" .. tostring(cov and cov.status) .. "/" .. tostring(cov and cov.knownCarrierLitres == A) .. "/" .. tostring(within) .. "/" .. tostring(oldMisses(A, { ["2:8"] = 1, ["3:8"] = 5, ["4:8"] = 10 }, R)),
        "true/" .. tostring(MW.RESULT.OK) .. "/true/true/true")

    -- Bob's sweep: 20000 totals from 100 to 120 L over two cells of 160 L and 400 L, a fixed seed.
    local snap2 = snapshotOver({ 160, 400 })
    local misses, oldN = 0, 0
    for _ = 1, 20000 do
        local total = 100 + 20 * uniform()
        if not seal(snap2, { 160, 400 }, total) then misses = misses + 1 end
        if oldMisses(total, { ["2:8"] = 160, ["3:8"] = 400 }, 560) then oldN = oldN + 1 end
    end
    T.eq("X2 NAMED: 20000 totals from 100 to 120 L over 160 L and 400 L cells all seal exactly (fixed seed); the old correction would miss some of the same seals",
        misses .. " " .. tostring(oldN > 0), "0 true")

    -- Random seals of 2 to 6 parts: raws from 0.5 to 400 L, totals from 1 to 500 L.
    local missesM, oldM, n = 0, 0, 0
    for _ = 1, 4000 do
        local k = 2 + math.floor(uniform() * 5)
        local rs, byId = {}, {}
        for i = 1, k do rs[i] = 0.5 + 399.5 * uniform() byId[(1 + i) .. ":8"] = rs[i] end
        local total = 1 + 499 * uniform()
        local s = snapshotOver(rs)
        local R2 = 0
        for _, r in ipairs(rs) do R2 = R2 + r end
        n = n + 1
        if not seal(s, rs, total) then missesM = missesM + 1 end
        if oldMisses(total, byId, R2) then oldM = oldM + 1 end
    end
    T.eq("X3 4000 random seals of 2 to 6 parts all seal exactly; the old correction would miss some of the same seals",
        n .. " " .. missesM .. " " .. tostring(oldM > 0), "4000 0 true")

    -- One part: nothing before the last, so the part is the total.
    local snap4 = snapshotOver({ 37.25 })
    local good4, cov4 = seal(snap4, { 37.25 }, 123.456)
    T.eq("X4 a one-part seal is the whole total", tostring(good4) .. "/" .. tostring(cov4 and cov4.carrierLitres), "true/123.456")
end)
end
MAINT196_BENCH()
