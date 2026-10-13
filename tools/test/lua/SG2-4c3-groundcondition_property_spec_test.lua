-- SG2-4c3-groundcondition_property_spec_test.lua
--
-- SG2-4c-3: Soil registers `soil.groundCondition` with StockGuard's SG-1 as an OWNER_RESOLVED
-- property (src/ground/GroundConditionProperty.lua; SG-2 v2.3 :324-332 and :343, the SG-1 brief
-- :232, GROUND-CONDITION-CONTRACT v1.5 sections 2 and 6).
--
-- THE ENTRY-POINT BAR IS GROUP E. Production's system (SoilFertilitySystem.new) runs its own
-- initialize: the real arm chain arms MaterialDown, MaterialWetness, HayBet, the yard ladder,
-- the condition cells, the coordinator and the admission interface, and then registers the
-- property through the mission's StockGuard handle. Nothing pre-fills the registration: the
-- handle is a RECORDER of StockGuard's (StockGuard.lua:115 and :121), which takes every
-- argument and returns a lease, and the rows pin the literal spec it was handed. Every later
-- group calls the callbacks the recorder captured, with dots, as SG-1 calls them
-- (SGOperations.lua:1616-1618 and :652-658 for the resolve, :789-791 for transform and
-- combine). The world supplies the store (the engine model's value maps), the owners'
-- cursors (day 100, as their own ticks would leave them) and the cells' bytes.
--
-- StockGuard's real registry and operations are not loaded here. The joined run against
-- them is a throwaway, outside the repo (the PR body names it).
--
-- The rows after R10 end the overlay hold by running the coordinator's mission start AFTER
-- the arm, the order its hook assumes. Production runs that order since MAINTENANCE row 195:
-- _groundMissionStarted is called at the end of activateSoilSystem, after initialize() arms
-- the family. MAINT-137's group M drives that order through the real manager.
--
-- NOT RUN, and why:
--   - a client: the coordinator refuses to arm without g_server (GroundConditionCoordinator
--     :105), and a bench in the mod environment cannot clear the engine's g_server, which
--     the engine model sets in the real global table;
--   - a cell the store refuses to read (readConditionCell's refused): the engine model's
--     store reads every cell; the overlay hold (R10) covers the UNAVAILABLE outcome.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/GroundConditionProperty.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG24C3_BENCH()
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

group("E", function()
    local alone = world({ noStockGuard = true })
    local aloneCounter = coord().changeCounter
    T.ok("E0 [world] Soil alone: initialize ran to its end, the coordinator armed and nothing registered (" .. tostring(W.initErr) .. ")",
        alone and W.sys.isInitialized == true and coord():isArmed() and not registered() and countWarn("[GroundProperty]") == 0)

    local ok = world()
    T.ok("E1 [entry point] with StockGuard's handle, initialize ran to its end and the coordinator and admission armed (" .. tostring(W.initErr) .. ")",
        ok and W.sys.isInitialized == true and coord():isArmed() and W.sys.groundConditionAdmission.groundCondition ~= nil)
    local r = W.rec.registers
    T.eq("E2 [entry point] one registerProperty call, with exactly two arguments, for soil.groundCondition",
        #r .. "/" .. tostring(r[1] and r[1].n) .. "/" .. tostring(r[1] and r[1][1]), "1/2/soil.groundCondition")
    local s = spec()
    local kinds = s.applicability and s.applicability.residentStoreKinds or {}
    T.eq("E3 the spec's literal fields: schema 1, producer soil, OWNER_RESOLVED, resident on ground only",
        table.concat({ tostring(s.schemaVersion), tostring(s.producerId), tostring(s.residency), #kinds .. ":" .. tostring(kinds[1]) }, "/"),
        "1/soil/OWNER_RESOLVED/1:ground")
    local fns = {}
    for _, k in ipairs({ "validate", "combine", "transform", "disclosure", "resolveResident", "getResidentRevision" }) do
        fns[#fns + 1] = k .. "=" .. type(s[k])
    end
    T.eq("E4 every callback SGRegistry:registerProperty requires is a function",
        table.concat(fns, " "),
        "validate=function combine=function transform=function disclosure=function resolveResident=function getResidentRevision=function")
    T.eq("E5 the registration moved the owner revision once (provider lifecycle), against the same arm with StockGuard absent",
        coord().changeCounter - aloneCounter, 1)
    T.ok("E6 the lease kept is the one the handle returned", registered() and prop().lease == W.rec.lease and prop().handle == W.rec.handle)
    local again, why = prop():register(coord(), g_currentMission)
    T.eq("E9 a second register is a no-op: no second call to StockGuard, no warning",
        tostring(again) .. "/" .. tostring(why) .. "/" .. #W.rec.registers .. "/" .. countWarn("[GroundProperty]"), "true/ALREADY_REGISTERED/1/0")

    world({ refuse = "DUPLICATE_OWNER" })
    T.eq("E7 a refused registration: not registered, the arm stands, one warning names the reason",
        tostring(registered()) .. "/" .. tostring(coord():isArmed()) .. "/" .. countWarn("DUPLICATE_OWNER"), "false/true/1")

    world({ gateClosed = true })
    T.eq("E8 the ground-material family gated off: the coordinator does not arm and nothing is registered with StockGuard",
        tostring(W.sys.isInitialized) .. "/" .. tostring(coord():isArmed()) .. "/" .. #W.rec.registers, "true/false/0")
end)

group("R", function()
    world()
    setCell(8, 8, 7, 120)
    local r0, why0 = resolve(ctx(0.5, 0.5))
    T.eq("R10 until the store decides its load (the overlay hold) a resolve is UNAVAILABLE, never a guess",
        brief(r0, why0), "nil/UNAVAILABLE")
    coord():onMissionStarted()

    local rec = resolve(ctx(0.5, 0.5, 1, 8))
    local p = rec and rec.payload or {}
    local g = p.geometry or {}
    T.eq("R1 a recorded cell: KNOWN, Soil's own encodings, all 8 L known", brief(rec), "KNOWN/7/120/8of8/LITRE")
    T.eq("R1b the payload's stamps are the owners' cursors and it names one cell and the geometry",
        table.concat({ tostring(p.ageDay), tostring(p.wetDay), tostring(p.cells), tostring(g.resolution), tostring(g.terrainSize), tostring(g.epoch ~= nil) }, "/"),
        "100/100/1/16/64/true")
    T.eq("R1c the record names the property, its producer and the coordinator's counter as its revision",
        table.concat({ tostring(rec.propertyId), tostring(rec.producerId), tostring(rec.schemaVersion), tostring(rec.propertyRevision == coord().changeCounter) }, "/"),
        "soil.groundCondition/soil/1/true")

    T.eq("R2 positive material on a cell with no record: UNKNOWN history (age 0, wetness 24), none of it known",
        brief(resolve(ctx(-0.5, 0.5))), "UNKNOWN/0/24/0of8/LITRE")

    setCell(9, 8, 4, 90)
    coord():markUnavailable(9, 8, "NATIVE_ERROR")
    T.eq("R3 a cell marked unavailable: nil, UNAVAILABLE", brief(resolve(ctx(4.5, 0.5))), "nil/UNAVAILABLE")

    setCell(10, 8, 5, 40)
    setCell(11, 8, 9, 60)
    local st = resolve(ctx(12.0, 2.0, 2, 6))
    T.eq("R4 a pixel straddling two cells (5/40 and 9/60) takes the floor: oldest age, wettest band",
        brief(st) .. "/" .. tostring(st and st.payload.cells), "KNOWN/9/60/6of6/LITRE/2")
    setCell(12, 8, 0, 0)
    T.eq("R4b a straddle onto a cell with no record is unknown in both components",
        brief(resolve(ctx(16.0, 2.0, 2, 6))), "UNKNOWN/0/24/0of6/LITRE")

    local edge = resolve(ctx(3.5, 0.5, 1, 8))
    T.eq("R5 a pixel ending on a cell edge reads its own cell only", brief(edge) .. "/" .. tostring(edge and edge.payload.cells), "KNOWN/7/120/8of8/LITRE/1")

    local noFp = ctx(0.5, 0.5)
    noFp.footprint = nil
    local unit = ctx(0.5, 0.5)
    unit.footprint.kind = "FILL_UNIT"
    T.eq("R6 a context naming no ground cell is NOT_RESIDENT, with or without a footprint",
        brief(resolve(noFp)) .. " " .. brief(resolve(unit)), "nil/NOT_RESIDENT nil/NOT_RESIDENT")
    T.eq("R7 off the grid, and a footprint no pixel has, are refused",
        brief(resolve(ctx(40, 0.5))) .. " " .. brief(resolve(ctx(0.5, 0.5, 20))), "nil/OFF_GRID nil/FOOTPRINT_TOO_LARGE")

    setCell(8, 9, 255, 80)
    T.eq("R8 the age ceiling is a record: KNOWN at 255", brief(resolve(ctx(0.5, 4.5))), "KNOWN/255/80/8of8/LITRE")
    setCell(8, 10, 7, 24)
    T.eq("R9 a known age over unknown wetness is UNKNOWN, the age kept in the payload",
        brief(resolve(ctx(0.5, 8.5))), "UNKNOWN/7/24/0of8/LITRE")
    T.eq("R11 a capture's resolve is the same read", brief(resolve(ctx(0.5, 0.5, 1, 8, "CAPTURE"))), "KNOWN/7/120/8of8/LITRE")
end)

group("V", function()
    world()
    coord():onMissionStarted()
    local a, b = revision(ctx(0.5, 0.5)), revision({ purpose = "CAPTURE", operationKind = "TRANSFER", participants = 3 })
    T.eq("V1 the revision is one string, equal across two reads with no change (a read's context and a capture's stamp)",
        type(a) .. "/" .. tostring(a == b), "string/true")
    coord():bumpRevision("movement")
    local c = revision(ctx(0.5, 0.5))
    T.ok("V2 a movement moves it", c ~= b)
    W.sys.materialDown.ageAppliedThroughDay = 101
    local d = revision(ctx(0.5, 0.5))
    T.ok("V3 the age cursor moving moves it", d ~= c)
    W.sys.materialWetness.appliedThroughDay = 101
    local e = revision(ctx(0.5, 0.5))
    T.ok("V4 the wetness cursor moving moves it", e ~= d)
    W.sys.materialWetness:_standDown("bench")
    local f = revision(ctx(0.5, 0.5))
    T.ok("V5 an owner standing down moves it before any update runs", f ~= e)
end)

-- SG-1's inputs to combine: a portion (SGOperations.lua:1033-1051) and a destination snapshot
-- (:1117-1126), each carrying the record by property id.
local function rec(ageRaw, wetRaw, ageDay, litres, knowledge)
    return { propertyId = "soil.groundCondition", schemaVersion = 1, producerId = "soil", propertyRevision = 0,
             knowledge = knowledge or "KNOWN", knownAmount = litres, basisAmount = litres, amountUnit = "LITRE",
             payload = { ageRaw = ageRaw, wetnessRaw = wetRaw, ageDay = ageDay } }
end
local function portion(litres, r)
    return { amount = litres, unit = "LITRE", properties = { ["soil.groundCondition"] = r } }
end
local function dest(litres, r)
    return { observedAmount = litres, amountUnit = "LITRE", properties = { ["soil.groundCondition"] = r } }
end
local OPCTX = { operationId = "op1", operationKind = "TRANSFER" }

group("C", function()
    world()
    local combine = spec().combine
    local c1 = combine(OPCTX, { portion(30, rec(5, 60, 100, 30)), portion(10, rec(3, 40, 102, 10)) }, nil)
    T.eq("C1 two scoops two days apart: the older is aged to the newer stamp once (5 + 2), the wettest band kept",
        brief(c1) .. "/" .. tostring(c1 and c1.payload.ageDay), "KNOWN/7/60/40of40/LITRE/102")
    local c2 = combine(OPCTX, { portion(10, rec(9, 50, 102, 10)) }, dest(20, rec(4, 90, 102, 20)))
    T.eq("C2 the bucket's own load joins the floor", brief(c2), "KNOWN/9/90/30of30/LITRE")
    T.eq("C3 a portion with no record is unknown history: the mixture is unknown, none known",
        brief(combine(OPCTX, { portion(30, rec(5, 60, 100, 30)), { amount = 10, unit = "LITRE", properties = {} } }, nil)),
        "UNKNOWN/0/24/0of40/LITRE")
    T.eq("C4 a zero-litre portion imports nothing",
        brief(combine(OPCTX, { portion(30, rec(5, 60, 100, 30)), { amount = 0, unit = "LITRE", properties = {} } }, nil)),
        "KNOWN/5/60/30of30/LITRE")
    local unstable = { propertyId = "soil.groundCondition", schemaVersion = 1, producerId = "soil", propertyRevision = 0,
                       knowledge = "UNAVAILABLE", reason = "RESIDENT_UNSTABLE" }
    T.eq("C5 an UNAVAILABLE portion cannot be vouched for: unknown",
        brief(combine(OPCTX, { portion(30, rec(5, 60, 100, 30)), portion(10, unstable) }, nil)), "UNKNOWN/0/24/0of40/LITRE")
    -- Records SG-1 qualified in place, payload kept (SGOperations.lua:1327, :307-308, :780).
    local withdrawn = rec(9, 200, 102, 10, "UNAVAILABLE")
    local grown = rec(9, 200, 102, 10, "PARTIAL")
    grown.knownAmount = 6
    local historical = rec(9, 200, 102, 10, "HISTORICAL")
    T.eq("C5b a record SG-1 qualified UNAVAILABLE, PARTIAL or HISTORICAL is unknown, its payload not read",
        brief(combine(OPCTX, { portion(30, rec(5, 60, 102, 30)), portion(10, withdrawn) }, nil)) .. " "
        .. brief(combine(OPCTX, { portion(30, rec(5, 60, 102, 30)), portion(10, grown) }, nil)) .. " "
        .. brief(combine(OPCTX, { portion(30, rec(5, 60, 102, 30)) }, dest(10, historical))),
        "UNKNOWN/0/24/0of40/LITRE UNKNOWN/0/24/0of40/LITRE UNKNOWN/0/24/0of40/LITRE")
    T.eq("C6 a known age with no stamp cannot be aged: age unknown, wetness kept",
        brief(combine(OPCTX, { portion(30, rec(5, 60, 100, 30)), portion(10, rec(3, 40, nil, 10)) }, nil)), "UNKNOWN/0/60/0of40/LITRE")
    T.eq("C7 the age ceiling propagates as itself", brief(combine(OPCTX, { portion(30, rec(255, 60, 100, 30)), portion(10, rec(3, 40, 100, 10)) }, nil)),
        "KNOWN/255/60/40of40/LITRE")
    local none, why = combine(OPCTX, { { amount = 0, unit = "LITRE", properties = {} } }, nil)
    T.eq("C8 no material at all: nil, NO_MATERIAL", brief(none, why), "nil/NO_MATERIAL")
    T.eq("C9 every result above validates", tostring(spec().validate(c1)) .. "/" .. tostring(spec().validate(c2)), "true/true")
end)

group("T", function()
    world()
    local t = spec().transform(OPCTX, { portion(30, rec(5, 60, 100, 30)) },
        { { carrierId = "c9", stockRef = { stockId = "s9" }, amount = 25, unit = "LITRE" } })
    T.eq("T1 a conversion with no registered basis is unknown over the destination's litres", brief(t), "UNKNOWN/0/24/0of25/LITRE")
    T.eq("T2 it validates", spec().validate(t), true)
    T.eq("D1 disclosure gives a player view nothing", spec().disclosure({ purpose = "PLAYER_VIEW" }, rec(5, 60, 100, 30)), nil)
end)

group("VAL", function()
    world()
    local v = spec().validate
    local good = rec(5, 60, 100, 30)
    local other = rec(5, 60, 100, 30)
    other.propertyId = "soil.other"
    local band = rec(5, 10, 100, 30)
    local lie = rec(0, 60, 100, 30)
    local big = rec(300, 60, 100, 30)
    --- Both returns, whatever validate gives back.
    local function verdict(fn, r) local ok, why = fn(r) return tostring(ok) .. ":" .. tostring(why) end
    T.eq("VAL1 a record of this property validates; another id, a reserved band, a KNOWN claim over unknown age and an age past 255 do not",
        table.concat({ verdict(v, good), verdict(v, other), verdict(v, band), verdict(v, lie), verdict(v, big) }, "/"),
        "true:nil/false:IDENTITY/false:WETNESS/false:KNOWLEDGE_PAYLOAD/false:AGE")
end)

group("L", function()
    world()
    coord():onMissionStarted()
    setCell(8, 8, 7, 120)
    local lease = W.rec.lease
    local before = coord().changeCounter
    W.sys:update(16)
    T.eq("L0 an update with both owners armed withdraws nothing", #W.rec.unregisters, 0)
    W.sys.materialDown:_standDown("bench")
    W.sys:update(16)
    local u = W.rec.unregisters
    T.eq("L1 the first update after a stand-down withdraws: one unregisterOwner call, with the lease and nothing else",
        #u .. "/" .. tostring(u[1] and u[1].n) .. "/" .. tostring(u[1] and u[1][1] == lease) .. "/" .. tostring(registered()),
        "1/1/true/false")
    T.ok("L2 the withdrawal moved the owner revision", coord().changeCounter > before)
    T.eq("L3 a resolve after a stand-down is PROVIDER_UNARMED", brief(resolve(ctx(0.5, 0.5))), "nil/PROVIDER_UNARMED")
    W.sys:update(16)
    T.eq("L4 a second update withdraws nothing more", #W.rec.unregisters, 1)

    world()
    local lease2 = W.rec.lease
    local before2 = coord().changeCounter
    W.sys:delete()
    local u2 = W.rec.unregisters
    T.eq("L5 unload withdraws once, with the lease", #u2 .. "/" .. tostring(u2[1] and u2[1][1] == lease2), "1/true")
    T.ok("L6 and moves the owner revision", coord().changeCounter > before2)

    world({ noStockGuard = true })
    local okDel, errDel = pcall(W.sys.delete, W.sys)
    T.ok("L7 Soil alone unloads with nothing to withdraw (" .. tostring(errDel) .. ")", okDel)
end)
end
SG24C3_BENCH()
