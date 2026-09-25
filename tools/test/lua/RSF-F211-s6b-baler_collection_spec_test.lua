-- RSF-F211-s6b-baler_collection_spec_test.lua
--
-- RSF-F211 part 2a (the Baler core): a bale is born with the condition of exactly the
-- material its chamber retained. Each pickup's sources are the cells it emptied, with
-- their condition captured before the removal; each source weighs by the carrier
-- litres the chamber actually accepted from it (the native gain carries its source's
-- condition; the unaccepted part of the same mixture is the overflow); the finished
-- chamber's account binds to the exact bale createBale appended.
--
-- THE ENTRY-POINT BAR IS GROUP E. Production enters through SoilFertilitySystem.new,
-- the owners armed in production's order (SoilFertilitySystem.lua:316-346),
-- HookManager:installAll (the captured pickup pointer, the Baler's class listeners, the
-- per-instance finishBale and createBale, the Bale.register birth door), a Baler built
-- as the engine builds it (registered functions copied into the instance, the work
-- area's pointer captured from it; RSF-F211-s6b-baler_model.lua) and processed as
-- WorkArea:onUpdateTick processes it (ENGINE.tick: start listeners, captured pointers,
-- end listeners). The bale's condition is read off the yard ladder's real row. The
-- world supplies the windrows (the native height map) and their ground condition
-- (condition bytes on the cells, as the weather and earlier machines would have left
-- them): the Baler collection reads that condition, it never obtains it.
--
-- MaterialDown is the real one here (its object ledger holds the yard ladder's rows).
-- Its arm checks that the store has four band methods; the engine model's value maps
-- carry refusing stand-ins for the three it lacks, and nothing on the Baler path
-- writes through them.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua

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
        vehicleSystem = { vehicles = {} },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
    }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
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
group("E", function()
    T.ok("E0 [world] MaterialDown, the wetness owner, the hay member, the yard ladder and the family arm in production's order", world())
    local v, work = baler({ capacity = 100 })
    local okI = installAll()
    local late, lateWork = baler({ capacity = 100, uid = "late" })   -- added after install
    T.eq("E1 installAll wraps the captured pickup pointer and the instance finish and create, on a baler present at install and one added later; the class listeners are the collection's",
        tostring(okI) .. "/" .. tostring(work._sfWraps ~= nil and work._sfWraps.processBalerArea ~= nil) .. "/" .. tostring(v.finishBale ~= Baler.finishBale and v.createBale ~= Baler.createBale)
        .. "/" .. tostring(lateWork._sfWraps ~= nil and lateWork._sfWraps.processBalerArea ~= nil) .. "/" .. tostring(late.finishBale ~= Baler.finishBale),
        "true/true/true/true/true")
    -- A wet swath (10 L at 79.9%) and a dry one (90 L at 20.1%) under the pickup.
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    local bale = lastBale(v)
    -- (10 x 79.9213 + 90 x 20.0787) / 100; the pixel mean of the two cells would be 50.
    T.eq("E2 the chamber filled, the square baler made one bale, and its wetness is the litres-weighted condition of the material it held",
        #bales(v) .. "/" .. num(bale ~= nil and bale:getFillLevel()) .. "/" .. num(birthOf(bale)), "1/100/26.063")
    T.eq("E3 the ground the pickup emptied was cleared: both cells' condition bytes are gone and they left the membership",
        ENGINE.layerGet(W.wet, 2, 8) .. "/" .. ENGINE.layerGet(W.wet, 3, 8) .. "/" .. tostring(W.sys.groundConditionCoordinator:isMember(2, 8)), "0/0/false")
    T.eq("E4 the chamber's account is empty after the square baler cleared it for the bale", num(BC.state(v).main.carrier), "0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RULING'S SENTENCES, ON THE REAL CHAMBER (SF-46, RULED 2026-07-31)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    world()
    local v = baler({ capacity = 100 })
    installAll()
    setCell(2, 8, 1, MaterialWetness.pctToRaw(90)) windrow(2, 2.5)     -- 5 L at 90%
    setCell(3, 8, 1, MaterialWetness.pctToRaw(10)) windrow(3, 47.5)    -- 95 L at 10%
    ENGINE.tick(v, 16)
    local p90, p10 = MaterialWetness.rawToPct(MaterialWetness.pctToRaw(90)), MaterialWetness.rawToPct(MaterialWetness.pctToRaw(10))
    T.eq("R1 one wet patch inside a big dry bale is not a wet bale", num(birthOf(lastBale(v))), num((5 * p90 + 95 * p10) / 100))
    world()
    v = baler({ capacity = 100 })
    installAll()
    setCell(2, 8, 1, MaterialWetness.pctToRaw(90)) windrow(2, 45)      -- 90 L at 90%
    setCell(3, 8, 1, MaterialWetness.pctToRaw(10)) windrow(3, 5)       -- 10 L at 10%
    ENGINE.tick(v, 16)
    T.eq("R2 a bale that is mostly wet reads wet", num(birthOf(lastBale(v))), num((90 * p90 + 10 * p10) / 100))
    -- Two balers in one field keep their own chambers.
    world()
    local a = baler({ capacity = 100, uid = "a" })
    local b = addBaler({ capacity = 100, uid = "b", x0 = 10, z0 = 1, width = 4, depth = 2 })
    installAll()
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    setCell(10, 8, 1, 52) setCell(11, 8, 1, 52)
    HEIGHT.fill(GR, 10, 2, 12, 3, 25) HEIGHT.fill(GR, 12, 2, 14, 3, 25)
    ENGINE.tick(a, 16)
    ENGINE.tick(b, 16)
    T.eq("R3 two balers keep their own chambers", num(birthOf(lastBale(a))) .. "/" .. num(birthOf(lastBale(b))), num(WET) .. "/" .. num(DRY))
    -- A second bale does not inherit the first chamber.
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(a, 16)
    T.eq("R4 a second bale does not inherit the first chamber", #bales(a) .. "/" .. num(birthOf(lastBale(a))), "2/" .. num(DRY))
    -- Unknown material keeps the bale from a confident wetness (RSF-F211 :104).
    world()
    v = baler({ capacity = 100 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 45)
    windrow(3, 5)                                                      -- no record in cell 3
    ENGINE.tick(v, 16)
    T.eq("R5 a chamber holding any material of unknown condition gives the bale no wetness (no known-only mean)",
        tostring(birthOf(lastBale(v))) .. "/" .. num(BC.stats.unknownBirths >= 1 and 1 or 0), "nil/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. ACCEPTANCE: OVERFLOW, MASS LIMIT, GAIN, EARLY REFUSAL
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    -- Overflow: 100 L produced, the chamber takes 60, the listener finishes the bale and
    -- stores 40 of the same mixture as overflow (Baler.lua:1170-1176).
    world()
    local v = baler({ capacity = 60 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    local st = BC.state(v)
    T.eq("A1 the full chamber made a 60 L bale of the mixture and the 40 L overflow keeps the same mixture, not a loss",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(v.spec_baler.fillUnitOverflowFillLevel) .. "/" .. num(st.overflow.carrier) .. "/" .. num(BC.accountPct(st.overflow)),
        "1/26.063/40/40/26.063")
    -- The next pass: 20 L at 20.1% arrive; the listener re-adds the overflow with a nested
    -- add (Baler.lua:1179-1183), the chamber reaches 60 and the second bale is made.
    setCell(2, 8, 1, 52) windrow(2, 10)
    ENGINE.tick(v, 16)
    T.eq("A2 the re-added overflow brings its own condition into the next bale, not another ground pickup",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(v.spec_baler.fillUnitOverflowFillLevel) .. "/" .. num(st.overflow.carrier),
        "2/" .. num((20 * DRY + 40 * 26.062992125984) / 60) .. "/0/0")
    -- A re-add that does not fit: 30 L arrive, the chamber takes 30 of the 40 L overflow and
    -- is full (the nested add finishes the second bale), and the listener stores 10 back.
    world()
    v = baler({ capacity = 60 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    setCell(2, 8, 1, 52) windrow(2, 15)
    ENGINE.tick(v, 16)
    st = BC.state(v)
    T.eq("A2b what the listener stores back after a re-add keeps the old overflow's condition",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(v.spec_baler.fillUnitOverflowFillLevel) .. "/" .. num(BC.accountPct(st.overflow)),
        "2/" .. num((30 * DRY + 30 * 26.062992125984) / 60) .. "/10/26.063")
    -- Mass limit: the fill unit reduces the 100 L request to 50 before the capacity clamp
    -- (FillUnit.lua:1127-1133); the chamber (capacity 50) takes 50 and is full; the
    -- listener's overflow is D - A = 0. The other 50 were discarded by that native path.
    world()
    v = baler({ capacity = 50, massLimit = 50 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    st = BC.state(v)
    T.eq("A3 a mass-limited request keeps the accepted share's mixture, stores no overflow and invents none",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(v.spec_baler.fillUnitOverflowFillLevel) .. "/" .. num(st.overflow.carrier), "1/26.063/0/0")
    -- Gain carries its source's condition (the brief's example): 100 L dry picked with the
    -- additive (x1.05 = 105 L), then 100 L wet without it.
    world()
    v = baler({ capacity = 205, additives = { level = 1000, usage = 0.001 } })
    installAll()
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    v.spec_fillUnit.fillUnits[2].fillLevel = 0                        -- the additive tank runs dry
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    T.eq("A4 the additive's gain carries its source's condition: 105 L at 20.1% and 100 L at 79.9% weigh as (105 x 20.1 + 100 x 79.9) / 205",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))), "1/" .. num((105 * DRY + 100 * WET) / 205))
    -- An early refusal (FillUnit.lua:1116-1141 returns 0 before any event): nothing is
    -- sealed, nothing overflows, and the next chamber does not inherit it.
    world()
    v = baler({ capacity = 100 })
    installAll()
    v.spec_fillUnit.fillUnits[1].refuse = true
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    st = BC.state(v)
    T.eq("A5 a refused add seals nothing and stores no overflow", num(st.main.carrier) .. "/" .. num(st.overflow.carrier) .. "/" .. #bales(v), "0/0/0")
    v.spec_fillUnit.fillUnits[1].refuse = false
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    T.eq("A6 the next chamber is only what it took", num(birthOf(lastBale(v))), num(DRY))
    -- A chamber that already held material Soil never saw (a loaded save: the fill unit's
    -- level with no account behind it) is unknown for that amount: native state owns it.
    world()
    v = baler({ capacity = 100 })
    installAll()
    v.spec_fillUnit.fillUnits[1].fillLevel, v.spec_fillUnit.fillUnits[1].fillType = 50, GR
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 12.5) windrow(3, 12.5)
    ENGINE.tick(v, 16)
    T.eq("A7 untracked material already in the chamber makes the bale unknown, never a known-only mean",
        #bales(v) .. "/" .. tostring(birthOf(lastBale(v))), "1/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE BALE: ROUND AND SQUARE, THE CREATION FRAME, OTHER DOORS
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    -- A round baler creates the bale before clearing (Baler.lua:1431-1434): one bale,
    -- and the still-full chamber is its mirror, not a second copy.
    world()
    local v = baler({ capacity = 100, round = true })
    installAll()
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    local st = BC.state(v)
    T.eq("B1 a round bale is born with the chamber's condition while the chamber stays full", #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(v:getFillUnitFillLevel(1)), "1/" .. num(WET) .. "/100")
    BALER_MODEL.clearChamber(v)                                        -- the bale leaves (:928)
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    T.eq("B2 clearing the chamber retires the mirror: the next round bale is only its own material", #bales(v) .. "/" .. num(birthOf(lastBale(v))), "2/" .. num(DRY))
    -- Another object registered inside createBale is not the bale.
    world()
    v = baler({ capacity = 100 })
    installAll()
    local other = nil
    BALER_MODEL.onRegister = function() other = Bale.new(true, false) other:register() end
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    T.eq("B3 the creation frame binds the exact bale createBale appended; an object registered inside it is born unknown",
        num(birthOf(lastBale(v))) .. "/" .. tostring(birthOf(other)), num(WET) .. "/nil")
    -- A failed create closes its frame and leaks nothing to the next registration.
    world()
    v = baler({ capacity = 100 })
    installAll()
    BALER_MODEL.failLoad = true
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    ENGINE.tick(v, 16)
    BALER_MODEL.failLoad = false
    local stray = Bale.new(true, false)
    stray:register()
    T.eq("B4 a failed create makes no bale, closes its frame, and a later registration is born unknown",
        #bales(v) .. "/" .. #BC.creationFrames .. "/" .. tostring(birthOf(stray)), "0/0/nil")
    -- A savegame create has no chamber sample, even straight after a finish.
    world()
    v = baler({ capacity = 100 })
    installAll()
    v:createBale(GR, 100, nil, nil, nil, nil, nil, true)
    T.eq("B5 a bale created from the savegame is born unknown", tostring(birthOf(lastBale(v))), "nil")
    -- A bale from any other door is born unknown and the ground under it is never read.
    local door = Bale.new(true, false)
    door:register()
    T.eq("B6 a bale registered outside every creation frame is born unknown", tostring(birthOf(door)), "nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. THE NON-STOP BUFFER AND ITS TRANSFER (part 2b)
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    world()
    local v = nonStop({ capacity = 100 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    local st = BC.state(v)
    T.eq("N1 a non-stop baler's pickup goes into its buffer (Baler.lua:1983-1996) under the same seal",
        num(v:getFillUnitFillLevel(3)) .. "/" .. num(st.buffer.carrier) .. "/" .. num(BC.accountPct(st.buffer)) .. "/" .. num(v:getFillUnitFillLevel(1)), "100/100/26.063/0")
    BALER_MODEL.updateTick(v, 1000)
    T.eq("N2 the buffer-to-chamber transfer (:1013-1052) carries the buffer's condition into the chamber and the bale",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(st.buffer.carrier), "1/26.063/0")
    -- The additive applied at overloading: 100 L leave the buffer, 105 L are produced, the
    -- chamber takes 100 and the listener stores 5 as overflow, all of the same mixture.
    world()
    v = nonStop({ capacity = 100, additives = { level = 1000, usage = 0.001 }, bufferAdditives = true })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    BALER_MODEL.updateTick(v, 1000)
    st = BC.state(v)
    T.eq("N3 the overloading gain carries its source's condition into the bale and the overflow",
        #bales(v) .. "/" .. num(birthOf(lastBale(v))) .. "/" .. num(v.spec_baler.fillUnitOverflowFillLevel) .. "/" .. num(BC.accountPct(st.overflow)), "1/26.063/5/26.063")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE UNFINISHED ROUND BALE (part 2b)
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    world()
    local v = nonStop({ capacity = 100, round = true, canUnloadUnfinishedBale = true })
    installAll()
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 15) windrow(3, 15)   -- 60 L wet
    ENGINE.tick(v, 16)
    BALER_MODEL.updateTick(v, 1000)                                               -- into the chamber
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 5) windrow(3, 5)       -- 20 L dry, in the buffer
    ENGINE.tick(v, 16)
    v:setIsUnloadingBale(true)
    local bale = lastBale(v)
    T.eq("P1 an unfinished round bale (Baler.lua:1327-1349) carries the chamber's material and the buffer's share; the pad to capacity is not material",
        #bales(v) .. "/" .. num(birthOf(bale)), "1/" .. num((60 * WET + 20 * DRY) / 80))
    BALER_MODEL.dropBale(v)
    T.eq("P2 dropped, the bale holds the real amount the chamber and buffer gave it", num(bale ~= nil and bale:getFillLevel()), "80")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. A STOCKGUARD LEASE ON THE PICKUP (part 2b)
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    world()
    local v, work = baler({ capacity = 100 })
    installAll()
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 25) windrow(3, 25)
    local sealedBefore = BC.stats.sealed
    local lease = W.sys.groundConditionAdmission.groundCondition.admitPrimitive(
        { schemaVersion = 1, kind = "LINE", sx = -21, sz = 2, ex = -19, ez = 2, fillTypeIndex = GR, innerRadius = 1, radius = 1 },
        GroundConditionAdmission.KIND_TIP_LINE, v, work)
    ENGINE.tick(v, 16)
    T.eq("L1 with a StockGuard lease live on the pickup the frame stands aside: StockGuard holds the material and seals it, Soil seals nothing and its chamber says unknown, never a parallel record",
        tostring(lease.status) .. "/" .. (BC.stats.sealed - sealedBefore) .. "/" .. #bales(v) .. "/" .. tostring(birthOf(lastBale(v))), "ADMITTED/0/1/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE FORAGE WAGON (part 2b)
-- ══════════════════════════════════════════════════════════════════════════
local function wagon(opts)
    local o = { x0 = BX.x0, z0 = BX.z0, width = BX.width, depth = BX.depth }
    for k, v in pairs(opts or {}) do o[k] = v end
    local v, work = BALER_MODEL.newWagon(o)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v, work
end
local function hay(gx, perPixel)
    local x0 = -32 + gx * 4 + (gx == 2 and 2 or 0)
    HEIGHT.fill(FT.DRYGRASS_WINDROW, x0, 2, x0 + 2, 3, perPixel)
end
group("F", function()
    world()
    local w, work = wagon({ capacity = 1000 })
    installAll()
    T.eq("F1 installAll wraps the wagon's captured pickup pointer and its instance fillForageWagon",
        tostring(work._sfWraps ~= nil and work._sfWraps.processForageWagonArea ~= nil) .. "/" .. tostring(w.fillForageWagon ~= ForageWagon.fillForageWagon), "true/true")
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(w, 16)
    local pct = FWC.condition(w)
    T.eq("F2 the wagon's load is the litres-weighted condition of what it took, and the buffer is empty after the fill",
        num(w:getFillUnitFillLevel(1)) .. "/" .. num(pct) .. "/" .. num(w.spec_forageWagon.workAreaParameters.litersToFill), "100/26.063/0")
    -- Two removals in one call (ForageWagon.lua:155-160): the forced grass and its hay twin.
    setCell(2, 8, 1, 204) windrow(2, 12.5)
    setCell(3, 8, 1, 52) hay(3, 12.5)
    ENGINE.tick(w, 16)
    T.eq("F3 a call that removes grass and hay seals each against its own capture; the load weighs both",
        num(w:getFillUnitFillLevel(1)) .. "/" .. num(FWC.condition(w)), "150/" .. num((100 * 26.062992125984 + 25 * WET + 25 * DRY) / 150))
    -- A full wagon: the fill unit takes 60 of the 100 L buffer; the rest stays in the buffer.
    world()
    w = wagon({ capacity = 60 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(w, 16)
    local st = FWC.state(w)
    T.eq("F4 the fill unit takes A of the buffer's mixture and the remainder stays in the buffer with the same condition",
        num(w:getFillUnitFillLevel(1)) .. "/" .. num(FWC.condition(w)) .. "/" .. num(w.spec_forageWagon.workAreaParameters.litersToFill) .. "/" .. num(BC.accountPct(st.buffer)),
        "60/26.063/40/26.063")
    -- The trim below 0.01 (:224-226) is a real discard.
    world()
    w = wagon({ capacity = 99.995 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(w, 16)
    st = FWC.state(w)
    T.eq("F5 a remainder under 0.01 L is trimmed by the engine and leaves the buffer's account too",
        num(w.spec_forageWagon.workAreaParameters.litersToFill) .. "/" .. num(st.buffer.carrier) .. "/" .. num(FWC.condition(w)), "0/0/26.063")
    -- The start-fill delay (:269-293): the first call's litres wait in the buffer.
    world()
    w = wagon({ capacity = 1000, fillStartDelay = 20 })
    installAll()
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(w, 16)
    local waited = num(w:getFillUnitFillLevel(1)) .. "/" .. num(w.spec_forageWagon.workAreaParameters.litersToFill)
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 12.5) windrow(3, 12.5)
    ENGINE.tick(w, 16)
    T.eq("F6 litres held back by the start-fill delay keep their condition in the buffer until the fill",
        waited .. "/" .. num(w:getFillUnitFillLevel(1)) .. "/" .. num(FWC.condition(w)), "0/100/150/" .. num((100 * 26.062992125984 + 50 * WET) / 150))
end)
