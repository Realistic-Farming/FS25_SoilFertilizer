-- SG2-5-0-drop_contributions_spec_test.lua
--
-- SG2-5 slice 5-0 (SG-2 v2.3 :345, Bob's G1 ruling of 2026-10-02): an admitted drop takes
-- the condition of the material StockGuard drops, as the `soil.groundCondition` records it
-- carried, through the optional `observation.contributions` of deliverMovement
-- (src/ground/GroundConditionAdmission.lua). Soil reads each record through its own
-- property (validate, componentsOf), splits a KNOWN record's litres by its coverage, ages
-- each known age once from its stamp to today, and lands the mixture through the shared
-- projector (P.drop). Without the field the drop arrives unknown, as before.
--
-- THE ENTRY-POINT BAR IS GROUP E. StockGuard's path, in production's order:
--   * the published table, read the way StockGuard reads it, through
--     SoilFertilityManager.getCapabilities (SoilFertilityManager.lua) at revision 2;
--   * the record the material carries is Soil's own: the real GroundConditionProperty,
--     registered on the armed coordinator, resolves the source cell before the pickup, as
--     StockGuard's capture does (SG-1 2-4c-0), and that record is what the drop passes;
--   * admitPrimitive, the real native line (DensityMapHeightUtil.tipToGroundAroundLine,
--     the engine model's verbatim port), deliverMovement and closePrimitive, dot calls.
-- The world supplies the native height map and the owners' cursors. Records are never
-- hand-written except where a row says it stands in for SG-1 qualifying one in place
-- (SGOperations.lua:293-299, :1327; :307-308).
--
-- NOT RUN, and why:
--   - GroundConditionProperty absent at a drop with contributions: main.lua sources it
--     before any lease can be delivered, so no game reaches that branch.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/GroundConditionProperty.lua, src/SoilFertilityManager.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function SG250_BENCH()
local INFO = {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function() end

local FT = ENGINE.FT
local A, GP = GroundConditionAdmission, GroundConditionProperty

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the world, armed as production arms it (the RSF-F208-s3c world) ─────────
local W = {}
local function world(today)
    HEIGHT.pixels = {}
    g_densityMapHeightManager.valid = true
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    W.sys, W.age, W.wet = sys, age, wet
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = { vehicles = {} } }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    local armedCells = sys.groundConditionCells:arm(vm)
    local armedCoord = armedCells and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local armedAdmit = armedCoord and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    -- The property registers on the armed coordinator as initialize registers it, through a
    -- handle that keeps the spec (StockGuard's registry would).
    W.spec = nil
    local handle = {
        registerProperty = function(_id, spec) W.spec = spec return { leaseId = "1:1" } end,
        unregisterOwner = function() return true end,
    }
    local registered = armedAdmit and sys.groundConditionProperty:register(sys.groundConditionCoordinator, { stockGuard = handle })
    return armedCells and armedCoord and armedAdmit and registered
end
local function cellAge(gx, gz) return ENGINE.layerGet(W.age, gx, gz) end
local function cellWet(gx, gz) return ENGINE.layerGet(W.wet, gx, gz) end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return cellAge(gx, gz) .. "/" .. cellWet(gx, gz) end
--- A new day, as the owners' own ticks leave it.
local function day(n)
    g_currentMission.environment.currentMonotonicDay = n
    W.sys.materialDown.ageAppliedThroughDay = n
    W.sys.materialWetness.appliedThroughDay = n
    W.sys.groundConditionCoordinator:invalidateBarrier()
end
--- Windrowed grass on the strip x 0..8, z 0..2: 16 pixels at 50 L. Cell (8,8) holds x 0..4,
--- cell (9,8) holds x 4..8 (4 m grain, origin -32).
local function grass() HEIGHT.fill(FT.GRASS_WINDROW, 0, 0, 8, 2, 50) end

--- The published table, as StockGuard binds it (SGSoilCondition.receiver at StockGuard
--- 54a423b, :72-87): the revision through the manager's getCapabilities, the calls through
--- the manager's `groundCondition` field, which activateSoilSystem sets from the armed
--- admission (SoilFertilityManager.lua:457). Nil when either fails, as there.
local function gc()
    local sfm = { soilSystem = W.sys, getCapabilities = SoilFertilityManager.getCapabilities,
                  groundCondition = W.sys.groundConditionAdmission.groundCondition }
    local caps = sfm:getCapabilities()
    if type(caps.groundCondition) ~= "table" or caps.groundCondition.admissionRevision ~= 2 then return nil end
    local published = sfm.groundCondition
    if type(published) ~= "table" or type(published.admitPrimitive) ~= "function" then return nil end
    return published
end
--- The record the material carries off a pixel: Soil's own property resolves it, as SG-1's
--- capture does before the native pickup.
local function carried(x, z, litres)
    return W.spec.resolveResident({ purpose = "CAPTURE", amount = litres, unit = "LITRE",
        footprint = { kind = "GROUND_CELL", x = x, z = z, size = 1 } })
end
local TRUCK = { isServer = true, uniqueId = "sg-truck" }
local function lineFP(sx, sz, ex, ez, ft, inner, radius)
    return { schemaVersion = 1, kind = "LINE", sx = sx, sz = sz, ex = ex, ez = ez, fillTypeIndex = ft, innerRadius = inner, radius = radius }
end
--- admit, the real primitive, deliver (with the caller's contributions), close.
local function bracketTip(ft, delta, sx, sz, ex, ez, inner, radius, contributions)
    local t = gc()
    local lease = t.admitPrimitive(lineFP(sx, sz, ex, ez, ft, inner, radius), A.KIND_TIP_LINE, TRUCK, "area1")
    if lease.status ~= "ADMITTED" then return lease, nil, nil end
    local okN, litres, off = pcall(DensityMapHeightUtil.tipToGroundAroundLine, TRUCK, delta, ft, sx, 0, sz, ex, 0, ez, inner, radius, 0, false, nil)
    local out = t.deliverMovement(lease.leaseToken, { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = okN, fillTypeIndex = ft,
        deltaRequested = delta, litresReturned = okN and litres or nil, lineOffset = okN and off or nil, contributions = contributions })
    t.closePrimitive(lease.leaseToken)
    return lease, out, okN and litres or nil
end
--- The drop of 800 L of carried stock onto z 6..7 (cell row 9), cells (8,9) and (9,9).
local function drop(contributions)
    local _, out, placed = bracketTip(FT.DRYGRASS_WINDROW, 800, 0, 6.5, 8, 6.5, 0.5, 1, contributions)
    return out, placed
end
local function landed() return condition(8, 9) .. " " .. condition(9, 9) end
--- A copy of a record, as SG-1 holds it.
local function copyRecord(r)
    local c = {}
    for k, v in pairs(r) do c[k] = v end
    c.payload = {}
    for k, v in pairs(r.payload) do c.payload[k] = v end
    return c
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    T.ok("E0 [world] the family arms in production's order and the property registers", world(100) == true)
    T.eq("E1 StockGuard binds the published table through SoilFertilityManager.getCapabilities: still revision 2", gc() ~= nil and gc().admissionRevision, 2)
    grass()
    setCell(8, 8, 3, 60)
    local rec = carried(2.5, 1.5, 800)
    T.eq("E2 [world] the material carries Soil's own record off the source cell: KNOWN 3/60 stamped day 100",
        tostring(rec and rec.knowledge) .. "/" .. tostring(rec and rec.payload.ageRaw) .. "/" .. tostring(rec and rec.payload.wetnessRaw) .. "/" .. tostring(rec and rec.payload.ageDay),
        "KNOWN/3/60/100")
    local out, placed = drop({ { litres = 800, record = rec } })
    T.eq("E3 [world] the native drop placed the 800 L and the delivery projected the cells it landed on",
        tostring(placed == 800) .. "/" .. tostring(out.status) .. "/" .. tostring(out.projected >= 2), "true/ADMITTED/true")
    T.eq("E4 [entry point] the carried condition lands on both cells", landed(), "3/60 3/60")

    world(100)
    drop(nil)
    T.eq("E5 without contributions the drop arrives UNKNOWN, as before", landed(), "0/24 0/24")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. WHAT A CONTRIBUTION SAYS
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    world(98)
    setCell(8, 8, 3, 60)
    local rec = carried(2.5, 1.5, 800)
    day(100)
    drop({ { litres = 800, record = rec } })
    T.eq("D1 a record stamped day 98, dropped on day 100, is aged once by 2 days; its wetness is kept", landed(), "5/60 5/60")

    world(100)
    local unknown = carried(2.5, 1.5, 800)
    drop({ { litres = 800, record = unknown } })
    T.eq("D2 a record of unknown history (no record on its cell) lands unknown",
        tostring(unknown.knowledge) .. " " .. landed(), "UNKNOWN 0/24 0/24")

    world(100)
    setCell(8, 8, 3, 60)
    local withdrawn = copyRecord(carried(2.5, 1.5, 800))
    withdrawn.knowledge, withdrawn.reason = "UNAVAILABLE", "BINDING_WITHDRAWN"   -- SG-1 qualifies in place, payload kept (:1327)
    drop({ { litres = 800, record = withdrawn } })
    T.eq("D3 a record SG-1 qualified UNAVAILABLE is not read by its payload: unknown", landed(), "0/24 0/24")

    world(100)
    setCell(8, 8, 3, 60)
    local foreign = copyRecord(carried(2.5, 1.5, 800))
    foreign.propertyId = "other.property"
    drop({ { litres = 800, record = foreign }, { litres = 0, record = "not a record" } })
    T.eq("D4 a record that does not validate is unknown, and a zero-litre entry imports nothing", landed(), "0/24 0/24")

    world(100)
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local a = carried(2.5, 1.5, 400)
    local b = carried(6.5, 1.5, 400)
    drop({ { litres = 400, record = a }, { litres = 400, record = b } })
    T.eq("D5 two known parts take the floor: the oldest age, the wettest band", landed(), "5/100 5/100")

    world(100)
    setCell(8, 8, 3, 60)
    local k = carried(2.5, 1.5, 600)
    drop({ { litres = 600, record = k }, { litres = 200, record = nil } })
    T.eq("D6 known material mixed with positive material of no record lands unknown (positive unknown wins)", landed(), "0/24 0/24")

    world(100)
    setCell(8, 8, 3, 60)
    local partial = copyRecord(carried(2.5, 1.5, 800))
    partial.knownAmount = 400   -- a KNOWN record covering half its basis
    drop({ { litres = 800, record = partial } })
    T.eq("D7 a KNOWN record covering half its litres splits them: the uncovered half is unknown", landed(), "0/24 0/24")

    world(100)
    setCell(8, 8, 255, 80)
    drop({ { litres = 800, record = carried(2.5, 1.5, 800) } })
    T.eq("D8 the age ceiling lands as itself", landed(), "255/80 255/80")

    world(100)
    setCell(8, 8, 3, 60)
    local nostamp = copyRecord(carried(2.5, 1.5, 800))
    nostamp.payload.ageDay = nil
    drop({ { litres = 800, record = nostamp } })
    T.eq("D9 a known age with no stamp cannot be aged: age unknown, wetness kept", landed(), "0/60 0/60")

    world(100)
    setCell(8, 8, 7, 24)
    local ageOnly = carried(2.5, 1.5, 800)
    drop({ { litres = 800, record = ageOnly } })
    T.eq("D10 an UNKNOWN record still says what it knows: its known age lands, its wetness is unknown",
        tostring(ageOnly.knowledge) .. " " .. landed(), "UNKNOWN 7/24 7/24")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. THE FIELD'S EDGES
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    world(100)
    local t = gc()
    local lease = t.admitPrimitive(lineFP(0, 6.5, 8, 6.5, FT.DRYGRASS_WINDROW, 0.5, 1), A.KIND_TIP_LINE, TRUCK, "area1")
    local base = { schemaVersion = 1, primitiveKind = A.KIND_TIP_LINE, ok = true, fillTypeIndex = FT.DRYGRASS_WINDROW, deltaRequested = 800, litresReturned = 0 }
    local function with(c) local o = {} for k, v in pairs(base) do o[k] = v end o.contributions = c return o end
    --- The published call must answer, never raise: StockGuard calls it inside its own pcall,
    --- and a raise would read as a failed delivery rather than a refused observation.
    local function answer(o) local ok, r = pcall(t.deliverMovement, lease.leaseToken, o) return ok and tostring(r.reason) or "RAISED" end
    T.eq("X1 a malformed contributions field is a bad observation, answered and never raised: not a list, an entry not a table, litres not finite, litres negative",
        table.concat({ answer(with("x")), answer(with({ 5 })), answer(with({ { litres = 0 / 0 } })), answer(with({ { litres = -1 } })) }, "/"),
        table.concat({ A.DELIVER_BAD_OBS, A.DELIVER_BAD_OBS, A.DELIVER_BAD_OBS, A.DELIVER_BAD_OBS }, "/"))
    t.closePrimitive(lease.leaseToken)

    world(100)
    grass()
    setCell(8, 8, 3, 60)
    setCell(9, 8, 5, 100)
    local junk = { { litres = 800, record = { propertyId = "soil.groundCondition" } } }
    local _, out = bracketTip(FT.GRASS_WINDROW, -math.huge, 0, 1, 8, 1, 1, nil, junk)
    local first = out.collected and out.collected[1] or {}
    T.eq("X2 a pickup ignores contributions: it projects from the cells it captured and returns their own condition",
        tostring(out.status) .. "/" .. tostring(out.cleared) .. "/" .. tostring(first.ageRaw) .. ":" .. tostring(first.wetnessRaw),
        "ADMITTED/2/3:60")

    T.eq("X3 mixtureOf, the reader alone: no list is no mixture", select(2, A.mixtureOf(nil, 100)), 0)
end)
end
SG250_BENCH()
