-- RSF-F211-s6-readers_spec_test.lua
--
-- RSF-F211 part 1 (S6, the readers): collected wetness follows the material that
-- actually entered its carrier. MaterialWetness owns three purpose readers: a PROBE
-- (AREA_SAMPLE_V1, a machine asking what is under it, never a material output), a
-- STANDING read (STANDING_NATIVE_VOLUME_V1: the requested type lying inside a field,
-- each Soil cell weighted by its native volume and clipped to the field polygon) and a
-- COLLECTED read (COLLECTED_NATIVE_VOLUME_V1: each source portion weighted by the
-- carrier litres a producer sealed for it, resolved against the producer's own seal).
-- The hay settle decides on the standing read; the tedder's delta and the handful read
-- use the probe; the tedder hands the hay member its real work-area parallelogram.
--
-- THE ENTRY-POINT BAR IS GROUP E. Production enters through SoilFertilitySystem.new,
-- the wetness owner, the hay member and the ground family armed in production's order
-- (SoilFertilitySystem.lua:316-346), both day accruals registered through the bridge
-- as main.lua:433-442 registers them, the machines' hooks installed by
-- HookManager:installAll, a real mower pass putting the grass down (its carrier writes
-- the fresh-cut condition and the membership), the weather's own accrual drying it,
-- and the day delivered to the hay member through the accrual the bridge registered.
-- Nothing on the path is hand-populated: no condition byte, no membership bit, no
-- field id and no polygon the code resolves for itself. The world supplies the map's
-- field as the engine's field manager holds it (g_fieldManager.fields with farmland 7
-- and its polygon nodes, Field.lua:18 and :57) and the grass the mower cuts.
--
-- MaterialDown is the engine model's stand-in, as in S3 and S5. Its active set is the
-- real one's after a mower pass: EMPTY, because nothing in production marks a mown
-- grass field (HookManager's only noteMaterialAt caller is the combine's swath hook at
-- :4942, and noteMaterialMoved has no caller). The stand-in walks it as
-- MaterialDown.lua:529-537 does. Row E3 is the reach this PR repairs.
--
-- Groups G, C and K are the readers' contracts on the same engine model. G supplies
-- the ground (the native height map) and reads the geometry; C and K set condition
-- bytes on cells to pin the arithmetic (as S5's group S does), never the settle's reach.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/MaterialWetness.lua, src/HayBet.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

-- The store's raw constants MaterialWetness reads (SoilValueMaps.lua:151-159); the store
-- itself is the engine model's value maps, handed to the owners by world().
SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

local FT = ENGINE.FT
local GR = FT.GRASS_WINDROW
local GRASS = ENGINE.FRUIT.GRASS
local B = MaterialWetness.BASIS

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

-- Field 7: a concave L on farmland 7, west of x 0 (where the hooks' field lookup answers
-- 7). Its notch is x -12..-4, z 12..20. Every vertex sits on the 4 m condition grid.
local FIELD7 = { { x = -24, z = 0 }, { x = -4, z = 0 }, { x = -4, z = 12 }, { x = -12, z = 12 }, { x = -12, z = 20 }, { x = -24, z = 20 } }
local function nodes(poly)
    local out = {}
    for i, p in ipairs(poly) do out[i] = { x = p.x, y = 0, z = p.z } end
    return out
end

local W = {}
local PRISTINE = { mowerStart = Mower.onStartWorkAreaProcessing, mowerEnd = Mower.onEndWorkAreaProcessing }
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
--- The world: a fresh engine; production's system; the wetness owner, the hay member and
--- the family armed in production's order; both day accruals registered through the
--- bridge; a dry sky; the map's field 7 in the engine's field manager.
local function world(today, opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    ENGINE.mowable = {}
    Mower.onStartWorkAreaProcessing, Mower.onEndWorkAreaProcessing = PRISTINE.mowerStart, PRISTINE.mowerEnd
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet, member = ENGINE.newValueMaps()
    W.sys, W.vm, W.age, W.wet, W.member = sys, vm, age, wet, member
    W.registered = {}
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {} },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function(_, id, spec) W.registered[id] = spec return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
    }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    -- The map's fields as the engine's field manager holds them (FieldManager.lua:387-396).
    g_fieldManager = { fields = { { farmland = { id = 7 }, polygonPoints = nodes(FIELD7) } } }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialDown.activeFields = {}
    sys.materialDown.enumerateActiveFields = function(self, fn)
        local n = 0
        for fieldId in pairs(self.activeFields) do fn(fieldId) n = n + 1 end
        return n
    end
    local armedWet = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    local armedHay = sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    if opts.beforeArm then opts.beforeArm() end
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    SoilMaterialDownBridge.registerConditionAccrual(sys.materialWetness)
    local regHay = SoilMaterialDownBridge.registerHayMember(sys.hayBet)
    return (armedWet and armedHay and a and b and c and regHay) == true
end
local function coord() return W.sys.groundConditionCoordinator end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function wet(gx, gz) return ENGINE.layerGet(W.wet, gx, gz) end
local function installAll() return pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys) end
local function runs()
    local out = {}
    coord():enumerateMemberRuns(function(gz, gx0, gx1) out[#out + 1] = gz .. ":" .. gx0 .. "-" .. gx1 end)
    return table.concat(out, " ")
end
local function mowerInWorld(x0, uid)
    local v = ENGINE.newMower({ uid = uid or "mower", x0 = x0, z0 = 0, width = 8, depth = 2, dropZ = 6 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v
end
--- The day as the Time Guard delivers it: the age tick, the weather's condition accrual.
local function weatherDay(day)
    g_currentMission.environment.currentMonotonicDay = day
    W.sys.materialDown:onAgeTick({ monotonicDay = day })
    W.registered[SoilMaterialDownBridge.ACCRUAL_CONDITION].onSettle({ monotonicDay = day, boundariesCrossed = 1 })
end
--- The hay member's day settle, through the accrual the bridge registered.
local function hayDay(day)
    g_currentMission.environment.currentMonotonicDay = day
    W.registered[SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER].onSettle({ monotonicDay = day, boundariesCrossed = 1 })
end
--- Record every standing read the hay member makes, through the real reader.
local function recordStanding()
    local rec = {}
    local mw = W.sys.materialWetness
    mw.readStandingCondition = function(self, snapshot)
        local out = MaterialWetness.readStandingCondition(self, snapshot)
        rec[#rec + 1] = { snapshot = snapshot, out = out }
        return out
    end
    return rec
end
local function carrierOf(polys)
    local mw = W.sys.materialWetness
    local s, why = mw:standingSnapshot(GR, polys)
    if s == nil then return "nil:" .. tostring(why) end
    return num(mw:readStandingCondition(s).carrierLitres)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE HAY SETTLE, FROM PRODUCTION'S ENTRY POINT
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    T.ok("E0 [world] the wetness owner, the hay member and the family arm in production's order, and both accruals register through the bridge", world(100))
    local spec = W.registered[SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER]
    T.eq("E1 the hay member's day settle is registered at the member-resolution priority",
        tostring(spec ~= nil) .. "/" .. tostring(spec ~= nil and spec.priority == SoilMaterialDownBridge.PRIORITY.MEMBER_RESOLUTION), "true/true")
    -- Two mowers: one inside field 7 (800 L), one east of x 0 where there is no field (400 L).
    local inField, outside = mowerInWorld(-16, "field"), mowerInWorld(0, "verge")
    ENGINE.mowable[GRASS] = 800
    installAll()
    ENGINE.tick(inField, 16)
    ENGINE.mowable[GRASS] = 400
    ENGINE.tick(outside, 16)
    T.eq("E2 [native] each cut laid its windrow, and the landed cells are members (field 7 at gx 4-5, the verge at gx 8-9)",
        num(HEIGHT.total(GR)) .. " " .. runs(), "1200 9:4-5 9:8-9")
    local rec = recordStanding()
    hayDay(101)
    local r1 = rec[1] and rec[1].out or {}
    T.eq("E3 the settle reached field 7 through the membership (MaterialDown's active set is empty) and read only it, on the standing basis",
        #rec .. "/" .. W.sys.materialDown:enumerateActiveFields(function() end) .. "/" .. tostring(r1.basis), "1/0/" .. B.STANDING)
    T.eq("E4 the read weighs the grass lying inside the field, every litre of its windrow, all known at the fresh-cut 80% (the verge's windrow is not in it)",
        tostring(r1.status) .. "/" .. num(r1.carrierLitres) .. "/" .. num(r1.knownCarrierLitres) .. "/" .. num(r1.pct), "ok/800/800/79.9213")
    T.eq("E5 wet grass is not converted", num(HEIGHT.total(FT.DRYGRASS_WINDROW)), "0")
    -- The weather dries the windrows over five days, to the EMC floor.
    for day = 101, 105 do weatherDay(day) end
    hayDay(106)
    local r2 = rec[#rec].out
    T.eq("E6 dried to the floor, the field reads fit (14.6%, at or under the 20% line); with conversion gated off the ground is untouched",
        wet(4, 9) .. "/" .. r2.status .. "/" .. num(r2.pct) .. "/" .. num(HEIGHT.total(GR)) .. "/" .. num(HEIGHT.total(FT.DRYGRASS_WINDROW)), "38/ok/14.5669/1200/0")
    HayBet.ENABLE_CONVERSION = true
    local okc = pcall(hayDay, 107)
    HayBet.ENABLE_CONVERSION = false
    T.eq("E7 with conversion on, the field's grass becomes hay over the cells the reading covered; the verge's windrow stays grass",
        tostring(okc) .. "/" .. num(HEIGHT.total(FT.DRYGRASS_WINDROW)) .. "/" .. num(HEIGHT.total(GR)), "true/800/400")

    -- Grass in the field whose condition nobody recorded keeps the field from reading fit.
    world(100)
    local m = mowerInWorld(-16, "field")
    ENGINE.mowable[GRASS] = 800
    installAll()
    ENGINE.tick(m, 16)
    HEIGHT.fill(GR, -24, 0, -20, 4, 1)   -- 16 L lying in cell (2, 8), inside the field, with no Soil record
    for day = 101, 105 do weatherDay(day) end
    rec = recordStanding()
    HayBet.ENABLE_CONVERSION = true
    pcall(hayDay, 106)
    HayBet.ENABLE_CONVERSION = false
    local r3 = rec[1] and rec[1].out or {}
    T.eq("E8 unknown grass in the field refuses the whole field, with the coverage said: nothing converted",
        tostring(r3.status) .. "/" .. num(r3.knownCarrierLitres) .. "/" .. num(r3.unknownCarrierLitres) .. "/" .. tostring(r3.pct) .. "/" .. num(HEIGHT.total(FT.DRYGRASS_WINDROW)),
        "refusal/800/16/nil/0")

    -- Grass nobody tracks: lying in the field when the index was rebuilt at arm (native
    -- occupancy makes its cells members), with no age record in any of them. The settle
    -- reaches the field and reads nothing.
    world(100, { beforeArm = function() HEIGHT.fill(GR, -24, 0, -16, 4, 5) end })
    rec = recordStanding()
    hayDay(101)
    T.eq("E9 grass with no age record anywhere in its cells is not tracked material: the settle reaches its field and does not read it",
        runs() .. "/" .. #rec, "8:2-3/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE STANDING SNAPSHOT'S GEOMETRY
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    world(100)
    HEIGHT.fill(GR, -24, 0, -4, 12, 10)    -- the L's foot: 240 px, 2400 L
    HEIGHT.fill(GR, -24, 12, -12, 20, 10)  -- its upright: 96 px, 960 L
    HEIGHT.fill(GR, -12, 12, -4, 20, 10)   -- the notch, outside the field: 64 px, 640 L
    T.eq("G1 a concave field counts the grass inside it and none in its notch (its box would count 4000)", carrierOf(FIELD7), "3360")
    world(100)
    HEIGHT.fill(GR, -16, 0, -12, 4, 10)    -- cell (4, 8): 160 L
    T.eq("G2 a cell the field's edge halves counts half its grass (the field given clockwise)", carrierOf({ { x = -24, z = 0 }, { x = -24, z = 4 }, { x = -14, z = 4 }, { x = -14, z = 0 } }), "80")
    world(100)
    HEIGHT.fill(GR, -24, 0, -16, 4, 10)    -- cells (2, 8) and (3, 8)
    HEIGHT.fill(GR, -24, 4, -20, 8, 10)    -- cell (2, 9)
    T.eq("G3 a triangular field across the grid: one cell whole, two cut on its diagonal count half", carrierOf({ { x = -24, z = 0 }, { x = -16, z = 0 }, { x = -24, z = 8 } }), "320")
    world(100)
    HEIGHT.fill(GR, -24, 0, -20, 4, 10)
    HEIGHT.fill(GR, -8, 0, -4, 4, 10)
    HEIGHT.fill(GR, -16, 0, -12, 4, 10)    -- between the two fields
    T.eq("G4 two fields on one farmland are both counted, the ground between them is not",
        carrierOf({ { { x = -24, z = 0 }, { x = -20, z = 0 }, { x = -20, z = 4 }, { x = -24, z = 4 } }, { { x = -8, z = 0 }, { x = -4, z = 0 }, { x = -4, z = 4 }, { x = -8, z = 4 } } }), "320")
    T.eq("G5 a self-crossing field (with a nonzero signed area) refuses the standing decision", carrierOf({ { x = -24, z = 0 }, { x = -4, z = 12 }, { x = -4, z = 0 }, { x = -20, z = 16 } }), "nil:INVALID_POLYGON")
    T.eq("G6 two points are no field", carrierOf({ { x = -24, z = 0 }, { x = -4, z = 0 } }), "nil:INVALID_POLYGON")
    local mw = W.sys.materialWetness
    local _, w1 = mw:standingSnapshot(FillType.UNKNOWN, FIELD7)
    local _, w2 = mw:standingSnapshot(99, FIELD7)
    g_densityMapHeightManager.valid = false
    local _, w3 = mw:standingSnapshot(GR, FIELD7)
    g_densityMapHeightManager.valid = true
    T.eq("G7 an unknown type, a type the height map cannot hold and an invalid height map each refuse", tostring(w1) .. "/" .. tostring(w2) .. "/" .. tostring(w3), "NO_FILL_TYPE/NO_FILL_TYPE/HEIGHT_MAP_UNAVAILABLE")
    local hb = W.sys.hayBet
    T.eq("G8 the hay member resolves its grass through the fill type manager; an unknown name is unavailable",
        tostring(hb:_fillTypeIndex("GRASS_WINDROW")) .. "/" .. tostring(hb:_fillTypeIndex("NOT_A_FILL_TYPE")), tostring(GR) .. "/nil")
    -- Cost: the field's box is 25 cells; grass lies in three of them.
    world(100)
    HEIGHT.fill(GR, -24, 0, -16, 4, 10)    -- cells (2, 8) and (3, 8)
    HEIGHT.fill(GR, -24, 16, -20, 20, 10)  -- cell (2, 12), in the L's upright
    local fracCalls, clipCalls = 0, 0
    local realFrac, realClip = PolygonClip.overlapFraction, PolygonClip.clipConvex
    PolygonClip.overlapFraction = function(...) fracCalls = fracCalls + 1 return realFrac(...) end
    PolygonClip.clipConvex = function(...) clipCalls = clipCalls + 1 return realClip(...) end
    local okCost, costCarrier = pcall(carrierOf, FIELD7)
    PolygonClip.overlapFraction, PolygonClip.clipConvex = realFrac, realClip
    T.eq("G10 [cost] only the cells holding grass are clipped: three of the box's 25", tostring(okCost) .. "/" .. tostring(costCarrier) .. "/" .. fracCalls, "true/480/3")
    T.eq("G11 [cost] each clipped cell is tested against only the triangles whose box meets it (the L has four)", clipCalls, 7)
    local polys = hb:_getFieldPolygons(7)
    T.eq("G9 the hay member's field is the engine's: farmland 7's polygon from its nodes, through the system's farmland resolution",
        tostring(polys ~= nil and #polys) .. "/" .. tostring(polys ~= nil and #polys[1]) .. "/" .. tostring(polys ~= nil and polys[1][4].x .. "," .. polys[1][4].z), "1/6/-12,12")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE STANDING READ'S COVERAGE
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    world(100, { beforeArm = function()
        setCell(2, 8, 1, 204)   -- 79.92%
        setCell(3, 8, 1, 52)    -- 20.08%
        setCell(4, 8, 1, 24)    -- the reserved sentinel: a refusal
    end })
    local mw = W.sys.materialWetness
    HEIGHT.fill(GR, -24, 0, -20, 4, 10)    -- (2, 8): 160 L
    HEIGHT.fill(GR, -20, 0, -16, 4, 1)     -- (3, 8): 16 L
    HEIGHT.fill(GR, -16, 0, -12, 4, 2)     -- (4, 8): 32 L
    HEIGHT.fill(GR, -12, 0, -8, 4, 0.25)   -- (5, 8): 4 L, no record
    local function readOver(x1)
        local s = mw:standingSnapshot(GR, { { x = -24, z = 0 }, { x = x1, z = 0 }, { x = x1, z = 4 }, { x = -24, z = 4 } })
        return mw:readStandingCondition(s), s
    end
    local r = readOver(-16)
    -- (160 x 79.9213 + 16 x 20.0787) / 176; the pixel mean of the two cells would be 50.
    T.eq("C1 each cell weighs by the grass lying in it: a heavy wet swath outweighs a thin dry strip",
        r.status .. "/" .. num(r.carrierLitres) .. "/" .. num(r.pct) .. "/" .. r.band .. "/" .. r.reason, "ok/176/74.481/soaked/COMPLETE_KNOWN_COVERAGE")
    r = readOver(-12)
    T.eq("C2 a refusing cell refuses the whole field, and its litres are counted as refused, not averaged",
        r.status .. "/" .. num(r.carrierLitres) .. "/" .. num(r.knownCarrierLitres) .. "/" .. num(r.refusedCarrierLitres) .. "/" .. num(r.unknownCarrierLitres) .. "/" .. tostring(r.pct),
        "refusal/208/176/32/0/nil")
    r = readOver(-8)
    T.eq("C3 grass with no record is unknown, never dry; the three parts sum to the carrier litres",
        r.reason .. "/" .. num(r.unknownCarrierLitres) .. "/" .. num(r.knownCarrierLitres + r.refusedCarrierLitres + r.unknownCarrierLitres) .. "/" .. num(r.carrierLitres),
        "POSITIVE_UNKNOWN_OR_REFUSAL/4/212/212")
    coord():markUnavailable(2, 8, "TEST")
    r = readOver(-16)
    T.eq("C4 a cell the availability overlay cannot vouch for is unknown", r.status .. "/" .. num(r.unknownCarrierLitres) .. "/" .. num(r.knownCarrierLitres), "refusal/160/16")
    local _, s = readOver(-16)
    coord():bumpRevision("TEST")
    r = mw:readStandingCondition(s)
    T.eq("C5 a snapshot taken before the owner last moved is unavailable", r.status .. "/" .. r.reason, "unavailable/REVISION_MISMATCH")
    local empty = mw:standingSnapshot(GR, { { x = 16, z = 0 }, { x = 24, z = 0 }, { x = 24, z = 4 }, { x = 16, z = 4 } })
    r = mw:readStandingCondition(empty)
    T.eq("C6 a field with no grass in it is no material, with a zero coverage", r.status .. "/" .. num(r.carrierLitres), "noMaterial/0")
    local collected = mw:collectedSnapshot(GR, { { gx = 3, gz = 8, litres = 16 } })
    r = mw:readStandingCondition(collected)
    T.eq("C7 a collected snapshot is not a standing one", r.status .. "/" .. r.reason, "unavailable/BASIS_MISMATCH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE COLLECTED READ AND THE PRODUCER'S SEAL
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    world(100, { beforeArm = function() setCell(2, 8, 1, 204) setCell(3, 8, 1, 52) end })
    local mw = W.sys.materialWetness
    HEIGHT.fill(GR, -24, 0, -20, 4, 6.25)   -- (2, 8): 100 L raw
    HEIGHT.fill(GR, -20, 0, -16, 4, 6.25)   -- (3, 8): 100 L raw
    HEIGHT.fill(GR, -16, 0, -12, 4, 6.25)   -- (4, 8): 100 L raw, no record
    local function cell(gx, gz)
        local x0, z0, x1, z1 = coord():cellWorldBox(gx, gz)
        return { gx = gx, gz = gz, litres = DensityMapHeightUtil.getFillLevelAtArea(GR, x0, z0, x1, z0, x0, z1) }
    end
    local snap = mw:collectedSnapshot(GR, { cell(2, 8), cell(3, 8), cell(4, 8) })
    -- The producer: 200 raw litres became 210 carrier litres; the chamber accepted 105,
    -- 10 attributed to the wet cell and 95 to the dry one.
    local receipt = mw:sealAllocation(snap, 105, { { id = "2:8", carrierLitres = 10, rawLitres = 100 }, { id = "3:8", carrierLitres = 95, rawLitres = 100 } })
    local r = mw:readCollectedCondition(snap, receipt)
    -- (10 x 79.9213 + 95 x 20.0787) / 105; a pixel mean would say 50.
    T.eq("K1 each portion weighs by the carrier litres sealed for it, not by its ground area",
        r.status .. "/" .. r.basis .. "/" .. num(r.carrierLitres) .. "/" .. num(r.rawSourceLitres) .. "/" .. num(r.pct) .. "/" .. r.band, "ok/" .. B.COLLECTED .. "/105/200/25.778/curing")
    local function copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
    local short = copy(receipt)
    short.parts = { receipt.parts[2] }
    T.eq("K2 a receipt with a portion deleted is unmatchable", mw:readCollectedCondition(snap, short).reason, "CALLER_ALLOCATION_MISMATCH")
    short.total = 95
    T.eq("K3 nor can the caller lower the total to match", mw:readCollectedCondition(snap, short).reason, "CALLER_ACCEPTANCE_MISMATCH")
    local r4 = mw:readCollectedCondition(snap, mw:sealAllocation(snap, 105, { { id = "2:8", carrierLitres = 10, rawLitres = 100 }, { id = "4:8", carrierLitres = 95, rawLitres = 100 } }))
    T.eq("K4 a portion from a cell with no record is unknown: the read refuses and says its coverage",
        r4.status .. "/" .. num(r4.knownCarrierLitres) .. "/" .. num(r4.unknownCarrierLitres) .. "/" .. tostring(r4.pct), "refusal/10/95/nil")
    local r5 = mw:readCollectedCondition(snap, mw:sealAllocation(snap, 105, { { id = "2:8", carrierLitres = 10, rawLitres = 100 }, { id = "3:8", carrierLitres = 95, rawLitres = 0 } }))
    T.eq("K5 carrier litres with no raw source are unknown produced material", r5.status .. "/" .. num(r5.unknownCarrierLitres), "refusal/95")
    local _, why6 = mw:sealAllocation(snap, 105, { { id = "2:8", carrierLitres = 10, rawLitres = 101 }, { id = "3:8", carrierLitres = 95, rawLitres = 100 } })
    local _, why7 = mw:sealAllocation(snap, 100, { { id = "2:8", carrierLitres = 10, rawLitres = 100 }, { id = "3:8", carrierLitres = 95, rawLitres = 100 } })
    local _, why8 = mw:sealAllocation(snap, 0, { { id = "2:8", carrierLitres = 0, rawLitres = 0 } })
    T.eq("K6 the seal refuses raw litres beyond the source, parts that do not sum to the accepted amount, and a zero acceptance",
        tostring(why6) .. "/" .. tostring(why7) .. "/" .. tostring(why8), "SOURCE_AVAILABILITY/RECEIPT_TOTAL_MISMATCH/INVALID_PRODUCER_ACCEPTANCE")
    local forged = copy(receipt)
    forged.allocationId = "allocation#999"
    T.eq("K7 a receipt no producer sealed is unavailable", mw:readCollectedCondition(snap, forged).reason, "PRODUCER_SEAL_MISSING")
    local standing = mw:standingSnapshot(GR, { { x = -24, z = 0 }, { x = -16, z = 0 }, { x = -16, z = 4 }, { x = -24, z = 4 } })
    local _, why9 = mw:sealAllocation(standing, 105, { { id = "2:8", carrierLitres = 105, rawLitres = 100 } })
    T.eq("K8 a standing snapshot can neither be sealed against nor read as collected",
        tostring(why9) .. "/" .. mw:readCollectedCondition(standing, receipt).reason, "BASIS_MISMATCH/BASIS_MISMATCH")
    local first = mw:sealAllocation(snap, 10, { { id = "2:8", carrierLitres = 10, rawLitres = 100 } })
    for _ = 1, MaterialWetness.MAX_ALLOCATIONS do mw:sealAllocation(snap, 10, { { id = "2:8", carrierLitres = 10, rawLitres = 100 } }) end
    T.eq("K9 the seals are bounded: the oldest leaves first, and its receipt no longer resolves",
        #mw.allocationOrder .. "/" .. mw:readCollectedCondition(snap, first).reason, MaterialWetness.MAX_ALLOCATIONS .. "/PRODUCER_SEAL_MISSING")

    -- A fresh local seal (K9 evicted the earlier ones), so K11 and K12 test the route, not an eviction.
    local localReceipt = mw:sealAllocation(snap, 105, { { id = "2:8", carrierLitres = 10, rawLitres = 100 }, { id = "3:8", carrierLitres = 95, rawLitres = 100 } })
    T.eq("K9b [world] Soil's own seal reads without StockGuard", mw:readCollectedCondition(snap, localReceipt).status, "ok")
    -- StockGuard present: its receipt resolver (SG-2 :358) is the producer, and the only one.
    -- The stand-in answers one receipt it sealed, exactly as sealed, and nothing else.
    local sgReceipt = { allocationId = "sg:pickup:1", snapshotId = snap.id, basis = B.COLLECTED, revision = snap.revision,
                        total = 50, parts = { { id = "2:8", q = 50 } } }
    local asked = {}
    g_currentMission.stockGuard = { readCollectionReceipt = function(ref)
        asked[#asked + 1] = ref
        if ref == sgReceipt then
            return { sealed = true, snapshotId = snap.id, acceptedCarrierLitres = 50, parts = { { id = "2:8", carrierLitres = 50, rawLitres = 60 } } }
        end
        return nil, "UNAVAILABLE"
    end }
    local r10 = mw:readCollectedCondition(snap, sgReceipt)
    T.eq("K10 with StockGuard present its resolver answers for a receipt Soil never sealed, and the read uses its seal",
        r10.status .. "/" .. num(r10.carrierLitres) .. "/" .. num(r10.rawSourceLitres) .. "/" .. num(r10.pct) .. "/" .. #asked, "ok/50/60/79.9213/1")
    T.eq("K11 with StockGuard present a receipt only Soil sealed is unavailable: one authority, never both",
        mw:readCollectedCondition(snap, localReceipt).reason, "PRODUCER_SEAL_MISSING")
    g_currentMission.stockGuard = { getCapabilities = function() return {} end }   -- a StockGuard without the resolver
    T.eq("K12 a StockGuard without the resolver leaves Soil's own seal the producer", mw:readCollectedCondition(snap, localReceipt).status, "ok")
    g_currentMission.stockGuard = nil
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. THE TEDDER HANDS THE HAY MEMBER ITS OWN WORK AREA
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    world(100)
    local v, work = ENGINE.newTedder({ uid = "tedder", x0 = -20, z0 = 0, width = 6, depth = 2, dropZ = 6 })
    -- The tedder turned 30 degrees: its work area's nodes where a turned tedder's are.
    local c, s = math.cos(math.rad(30)), math.sin(math.rad(30))
    work.start = { x = -20, z = 0 }
    work.width = { x = -20 + 6 * c, z = 6 * s }
    work.height = { x = -20 - 2 * s, z = 2 * c }
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    installAll()
    local seen = {}
    local hb = W.sys.hayBet
    local real = hb.applyTedderDelta
    hb.applyTedderDelta = function(self, poly) seen[#seen + 1] = poly return real(self, poly) end
    ENGINE.tick(v, 16)
    local p = seen[1]
    local function pt(q) return num(q.x) .. "," .. num(q.z) end
    T.eq("T1 the tedder hands the hay member its turned work area: start, width, width + height - start, height (not the square around it)",
        p ~= nil and (pt(p[1]) .. " " .. pt(p[2]) .. " " .. pt(p[3]) .. " " .. pt(p[4])) or "none", "-20,0 -14.8038,3 -15.8038,4.7321 -21,1.7321")
end)
