-- RSF-F213-s5-membership_settle_spec_test.lua
--
-- RSF-F213 part 2, GROUND-CONDITION-CONTRACT v1.5 section 5: material weather follows
-- occupied ground and actual shelter. The daily settle walks a derived MEMBERSHIP
-- INDEX at the Soil cell grain (P-GROUND-3: a one-bit companion layer plus row runs),
-- fields and yards alike, instead of the fields' polygons: every admitted cell once
-- per settled day, the same phase order, encoded bounds, equilibrium floor and
-- rounding as the field pass, the existing per-field soil drivers where a field
-- exists and the neutral defaults outside one; rain is the existing dose times the
-- cell's EXPOSED fraction under the indoor mask, read at the mask's own grain
-- (P-GROUND-4), a missing mask meaning exposed. Membership is marked by the real
-- deposits and clears, rebuilt at arm from the condition bytes and native occupancy
-- when the saved index is absent, reconciled after a refused bit write and held
-- otherwise; a placeable's paint invalidates the shelter read over the cells it
-- touched through a wrap on the mission's indoor mask.
--
-- THE ENTRY-POINT BAR IS GROUP S. Production enters through SoilFertilitySystem.new,
-- the wetness owner armed by its real arm, the ground family armed in production's
-- order (SoilFertilitySystem.lua:316-346: the coordinator binds the owner to its
-- index), HookManager:installAll (the carriers and the indoor mask wrap), and the day
-- settled through the accrual SoilMaterialDownBridge.registerConditionAccrual
-- registers with the Time Guard, or through the real settlement barrier. Membership is
-- never marked by hand: the real mower pass, the arm-time rebuild and the real clear
-- write it. The bar's sources run under the mod's own environment (--!env: modenv).
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/MaterialWetness.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

-- The store's raw constants MaterialWetness reads (SoilValueMaps.lua:151-159). The
-- store itself is the engine model's value maps (ENGINE.newValueMaps), handed to the
-- owners by world() as production hands its own; SoilFertilitySystem.new therefore
-- gets no store from this name.
SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

local FT = ENGINE.FT
local GRASS = ENGINE.FRUIT.GRASS
local C, O = GroundMovementCarrier, GroundNativeObserver

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
local PRISTINE = { mowerStart = Mower.onStartWorkAreaProcessing, mowerEnd = Mower.onEndWorkAreaProcessing }
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
--- The world: a fresh engine, production's system with its REAL wetness owner armed by
--- its real arm, the family armed in production's order (the coordinator binds the
--- owner to the index), a Time Guard that records the registration, a WeatherGuard
--- (opts.weather: { sky, rain, climate } or nil for none), the mission's indoor mask
--- (opts.noMask for a map without the layer), and a field lookup answering field 7
--- west of x 0 and no field east of it. opts.valueMaps shapes the store. The owner's
--- field-pass entry points are recorded (W.fieldPassEntered) so a bar can say they
--- were never entered while the membership is bound.
local function world(today, opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    ENGINE.mowable = {}
    Mower.onStartWorkAreaProcessing, Mower.onEndWorkAreaProcessing = PRISTINE.mowerStart, PRISTINE.mowerEnd
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet, member = ENGINE.newValueMaps(opts.valueMaps)
    W.sys, W.vm, W.age, W.wet, W.member = sys, vm, age, wet, member
    W.registered = {}
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {} },
        weatherGuard = ENGINE.newWeatherGuard(opts.weather == nil and { sky = SKY, rain = { rainScale = 0 } } or (opts.weather ~= false and opts.weather or nil)),
        timeGuard = { registerAccrual = function(_, id, spec) W.registered[id] = spec return true end, unregisterAccrual = function() end },
        indoorMask = (not opts.noMaskAtAll) and ENGINE.newIndoorMask({ noHandle = opts.noMask }) or nil,
        cropStressManager = opts.cropStress,
    }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    sys.materialDown.ageAppliedThroughDay = today
    W.fieldPassEntered = 0
    local realDry, realWet = MaterialWetness.dryPass, MaterialWetness.wetPass
    sys.materialWetness.dryPass = function(self, ...) W.fieldPassEntered = W.fieldPassEntered + 1 return realDry(self, ...) end
    sys.materialWetness.wetPass = function(self, ...) W.fieldPassEntered = W.fieldPassEntered + 1 return realWet(self, ...) end
    -- Production's arm of the wetness owner (SoilFertilitySystem.lua:322), then the
    -- cursor a save carried, then the family in production's order.
    local armedWet = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    if opts.beforeArm then opts.beforeArm() end
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    SoilMaterialDownBridge.registerConditionAccrual(sys.materialWetness)
    return armedWet and a and b and c
end
local function coord() return W.sys.groundConditionCoordinator end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function condition(gx, gz) return ENGINE.layerGet(W.age, gx, gz) .. "/" .. ENGINE.layerGet(W.wet, gx, gz) end
local function wet(gx, gz) return ENGINE.layerGet(W.wet, gx, gz) end
local function bit(gx, gz) return ENGINE.layerGet(W.member, gx, gz) end
local function installAll()
    local ok, err = pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys)
    return ok, err
end
--- The day boundary as the Time Guard delivers it (the registered accrual).
local function settleDay(day, span)
    g_currentMission.environment.currentMonotonicDay = day
    W.registered[SoilMaterialDownBridge.ACCRUAL_CONDITION].onSettle({ monotonicDay = day, boundariesCrossed = span or 1 })
end
local function runs()
    local out = {}
    coord():enumerateMemberRuns(function(gz, gx0, gx1) out[#out + 1] = gz .. ":" .. gx0 .. "-" .. gx1 end)
    return table.concat(out, " ")
end
local function mowerInWorld(opts)
    opts = opts or {}
    local v, mowers, drop = ENGINE.newMower({ uid = opts.uid or "mower", x0 = opts.x0 or 0, z0 = 0, width = 8, depth = 2, dropZ = opts.dropZ or 6, areas = opts.areas })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, mowers, drop
end
local function lines(list, needle)
    local n = 0
    for _, l in ipairs(list) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end
--- Paint a roof over a world box, as PlaceableIndoorAreas:onFinalizePlacement does.
local function roof(x0, z0, x1, z1, state)
    g_currentMission.indoorMask:setStateByArea(ENGINE.indoorArea(x0, z0, x1, z1), state == nil and IndoorMask.INDOOR or state)
end

-- ══════════════════════════════════════════════════════════════════════════
-- I. THE INDEX ARMS WITH THE FAMILY
-- ══════════════════════════════════════════════════════════════════════════
group("I", function()
    T.ok("I0 [world] the wetness owner and the family arm in production's order", world(100) == true)
    local st = coord():getMembershipStats()
    T.eq("I1 the coordinator resolved the store's one-bit membership layer, built an empty index from the condition bytes and bound the owner",
        tostring(st ~= nil and st.ready) .. "/" .. tostring(st and st.count) .. "/" .. tostring(st and st.source) .. "/" .. tostring(W.sys.materialWetness:membershipActive()), "true/0/REBUILT/true")
    T.eq("I2 the log says the index was rebuilt", lines(INFO, "ground membership index rebuilt from the condition bytes and native occupancy: 0 member cell(s)"), 1)

    -- A store without the layer: armed, no index, the owner keeps its field pass.
    world(100, { valueMaps = { noMembership = true } })
    T.eq("I3 a store without the layer arms the family with no index; the owner is not bound and keeps the field pass",
        tostring(coord():isArmed()) .. "/" .. tostring(coord():getMembershipStats()) .. "/" .. tostring(W.sys.materialWetness:membershipActive()), "true/nil/false")
    T.eq("I4 and says so once", lines(WARN, "no groundMembership layer in the store"), 1)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. MEMBERSHIP FOLLOWS THE REAL DEPOSITS AND CLEARS
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    world(100)
    local v = mowerInWorld()
    ENGINE.mowable[GRASS] = 400
    installAll()
    ENGINE.tick(v, 16)
    T.eq("M1 [native] the cut dropped 400 L on the windrow line", num(HEIGHT.total(FT.GRASS_WINDROW)), "400")
    T.eq("M2 the landed cells are members, marked by the deposit's own write: one run, and the bits are set", runs() .. " " .. bit(8, 9) .. bit(9, 9) .. bit(10, 9), "9:8-9 110")
    T.eq("M3 the cut strip (picked up, nothing landed there) is not a member", tostring(coord():isMember(8, 8)), "false")
    -- A windrower rakes the windrow away: the cleared cells leave the membership,
    -- the cells it lands on join.
    local wind = ENGINE.newWindrower({ uid = "rake", x0 = 0, z0 = 6, width = 8, depth = 1, dropZ = 12 })
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = wind
    W.sys.hookManager:installWindrowerHook()
    ENGINE.tick(wind, 16)
    T.eq("M4 [native] the rake moved the windrow to z 12", num(DensityMapHeightUtil.getFillLevelAtArea(FT.GRASS_WINDROW, 0, 12, 8, 12, 0, 13)), "400")
    T.eq("M5 a known whole-cell zero unmarks; the destination cells are members now", runs() .. " " .. bit(8, 9) .. bit(8, 11), "11:8-9 01")

    -- A refused barrier: the cells it could not vouch for are marked unavailable AND
    -- members (positive material of unknown condition is never bare ground).
    world(100)
    local v2 = mowerInWorld({ uid = "refused" })
    ENGINE.mowable[GRASS] = 400
    installAll()
    g_currentMission.environment.currentMonotonicDay = 101
    g_currentMission.weatherGuard = nil   -- no sky, no climate: the day holds, the barrier refuses
    ENGINE.tick(v2, 16)
    T.eq("M6 under a refused barrier the landed cells are unavailable and members", tostring(coord():isUnavailable(8, 9)) .. "/" .. tostring(coord():isMember(8, 9)) .. "/" .. bit(8, 9), "true/true/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE INDEX AT ARM: READ FROM A SAVE, OR REBUILT FROM THE TRUTH
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    -- No saved index: condition bytes and native material without a record.
    world(100, { beforeArm = function()
        setCell(4, 4, 3, 100)      -- a recorded cell
        setCell(5, 4, 3, 100)
        setCell(12, 12, 0, 24)     -- unknown wetness on a record: still a member
        HEIGHT.fill(FT.STRAW, 8, 2, 12, 3, 25)   -- native straw with no record: cells (10,8) and (11,8)... x 8..12 -> gx 10,10; z 2..3 -> gz 8
    end })
    local st = coord():getMembershipStats()
    T.eq("R1 an absent index is rebuilt from the condition bytes and native occupancy: the recorded cells, the unknown one and the bare-record straw cells are members",
        runs() .. " | " .. st.count .. "/" .. st.source, "4:4-5 8:10-10 12:12-12 | 4/REBUILT")
    T.eq("R2 and the bits were written", bit(4, 4) .. bit(5, 4) .. bit(10, 8) .. bit(12, 12) .. bit(6, 4), "11110")

    -- A saved index: the runs come from its bits, and a record it does not list is not
    -- added. Its members are real ones: two with a record, one holding native straw
    -- with no record (since MAINTENANCE row 108 a listed cell with neither a record nor
    -- material leaves the index at arm; that case is MAINT-107-108's bar).
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function()
        ENGINE.layerSet(W.member, 2, 2, 1)
        ENGINE.layerSet(W.member, 3, 2, 1)
        ENGINE.layerSet(W.member, 9, 9, 1)
        setCell(2, 2, 3, 100)
        setCell(3, 2, 3, 100)
        HEIGHT.fill(FT.STRAW, 4, 4, 8, 8, 25)   -- cell (9,9): x 4..8, z 4..8
        setCell(7, 7, 5, 100)   -- a record the saved index does not list: NOT a member
    end })
    st = coord():getMembershipStats()
    T.eq("R3 a saved index is read as it is: its runs, its count, and a record it does not list is not a member",
        runs() .. " | " .. st.count .. "/" .. st.source .. "/" .. tostring(coord():isMember(7, 7)), "2:2-3 9:9-9 | 3/INDEX/false")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SETTLE WALKS THE MEMBERS (the entry-point bar)
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    -- Members from the arm-time rebuild: two fresh windrows at 80% (204) in field 7,
    -- a damp one at 140 and a curing one at 100 east of any field, one already at the
    -- EMC floor (38), one below it (35, dry hay), an unknown one (24), an unavailable
    -- one, and a record the index would list but which is NOT a member (set after
    -- arm, so the bar can prove only members are settled).
    T.ok("S0 [world] armed", world(100, { beforeArm = function()
        setCell(4, 4, 1, 204)    -- field 7 (x = -16..-12)
        setCell(5, 4, 1, 204)
        setCell(12, 4, 3, 140)   -- gx 12 -> x 16..20: no field
        setCell(13, 4, 3, 100)
        setCell(14, 4, 3, 38)    -- at the floor already
        setCell(15, 4, 3, 35)    -- below the EMC ceiling: dry hay, outside every phase band
        setCell(6, 6, 3, 24)     -- unknown wetness
        setCell(7, 6, 3, 150)    -- will be marked unavailable below
    end }) == true)
    coord():markUnavailable(7, 6, "TEST")
    setCell(9, 9, 3, 200)        -- a record with no membership (set after the arm)
    installAll()
    T.eq("S1 [world] eight members in three runs; the late record is not one", runs() .. "/" .. tostring(coord():isMember(9, 9)), "4:4-5 4:12-15 6:6-7/false")
    settleDay(101)
    -- Drivers: sky 65% humidity at 15 C gives an EMC of 14.6% (raw 38); the neutral
    -- loamy 1.0 and the mid weather multiplier 1.0 everywhere on this dry day: rapid
    -- 25 points (raw 64), transitional 18 (46), bound 6 (15); the sequential phases
    -- cascade as the layer passes do. 204 -> 140 -> 94 -> 79. 140 -> 94 -> 79.
    -- 100 -> 85. 38 stays at the floor. 35 lies under the bound band's EMC edge and
    -- is not touched.
    T.eq("S2 the settle dried every member once through the phase table, in order, with the floor at the EMC ceiling; a member at the floor stays, one below the ceiling is outside every band",
        wet(4, 4) .. "/" .. wet(5, 4) .. "/" .. wet(12, 4) .. "/" .. wet(13, 4) .. "/" .. wet(14, 4) .. "/" .. wet(15, 4), "79/79/79/85/38/35")
    T.eq("S3 the unknown member kept its sentinel, the unavailable member its bytes, and the non-member record was not touched",
        wet(6, 6) .. "/" .. wet(7, 6) .. "/" .. wet(9, 9), "24/150/200")
    T.eq("S4 the field pass was never entered: neither its dry nor its wet function ran while the membership is bound", W.fieldPassEntered, 0)
    T.eq("S5 the cursor advanced and the day was recorded dry", tostring(W.sys.materialWetness.appliedThroughDay) .. "/" .. tostring(W.sys.materialWetness.waterRecord[101].water), "101/false")
    local ls = W.sys.materialWetness.lastSettle
    T.eq("S6 [cost] eight members: seven reads (the unavailable one is skipped unread) and three coalesced writes (79 over 4-5; 79 then 85 over 12-13; the two unchanged cells, the unknown and the unavailable take no write)",
        ls.cells .. "/" .. ls.dryReads .. "/" .. ls.dryWrites, "8/7/3")

    -- The same settle through the real barrier: a machine's pass on a new day settles
    -- the members before its primitive.
    world(100, { beforeArm = function() setCell(4, 4, 1, 204) end })
    installAll()
    g_currentMission.environment.currentMonotonicDay = 101
    local ok, reason = coord():runSettlementBarrier()
    T.eq("S7 the settlement barrier walks the same membership settle: settled, and the member dried", tostring(ok) .. "/" .. reason .. "/" .. wet(4, 4), "true/OK/79")

    -- Per-field drivers: sandy soil through the existing SCS contract dries faster
    -- under field 7 (west of x 0); east of it there is no field and the neutral
    -- defaults apply, whatever SCS would say for a field.
    world(100, { cropStress = { getFieldSoilType = function(_, id) if id == 7 then return "sandy" end return nil end, getMoisture = function() return 0.5 end },
        beforeArm = function() setCell(4, 4, 1, 204) setCell(14, 4, 1, 204) end })   -- gx 4 -> x -16..-12 (field 7); gx 14 -> x 24..28 (no field)
    installAll()
    settleDay(101)
    -- sandy 1.4: rapid 35 points (89), transitional 25.2 (64), bound 8.4 (21):
    -- 204 -> 115 -> 51 -> 30, floored at 38. Neutral: 204 -> 79.
    T.eq("S8 a member in a sandy field dries by the field's own modifiers, to the EMC floor", wet(4, 4), 38)
    T.eq("S9 a member outside any field dries by the neutral defaults, not by an invented field", wet(14, 4), 79)

    -- A held day: no sky and no climate, the cursor stays and nothing is written.
    world(100, { weather = false, beforeArm = function() setCell(4, 4, 1, 204) end })
    installAll()
    settleDay(101)
    T.eq("S10 a day with no sky and no climate holds: cursor kept, member untouched", tostring(W.sys.materialWetness.appliedThroughDay) .. "/" .. wet(4, 4), "100/204")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. RAIN, THE EXPOSED FRACTION AND THE MASK'S GRAIN (P-GROUND-4)
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    -- Three members at 100 (bound band): one in the open, one wholly under a roof,
    -- one half under a roof (the mask is 1 m pixels, the cell 4 m: a roof over half
    -- the cell covers 8 of its 16 pixels). A dry day's step takes 100 to 85 first;
    -- then rain at full scale adds 15 points (raw 38): 123 exposed, 85 covered,
    -- 85 + 19 = 104 at half exposure.
    world(100, { weather = { sky = SKY, rain = { rainScale = 1, isRaining = true } },
        beforeArm = function() setCell(4, 4, 3, 100) setCell(6, 4, 3, 100) setCell(8, 4, 3, 100) end })
    installAll()
    -- Cell (6,4) spans x -8..-4, z -16..-12; cell (8,4) spans x 0..4, z -16..-12.
    roof(-8, -16, -4, -12)
    roof(0, -16, 2, -12)
    T.eq("W0 [world] the mask reads indoor under the roofs and outdoor beside them", tostring(g_currentMission.indoorMask:getIsIndoorAtWorldPosition(-6, -14)) .. "/" .. tostring(g_currentMission.indoorMask:getIsIndoorAtWorldPosition(3, -14)) .. "/" .. tostring(g_currentMission.indoorMask:getIsIndoorAtWorldPosition(-14, -14)), "true/false/false")
    settleDay(101)
    T.eq("W1 rain lands in full on the exposed member, not at all under the roof, and half on the half-covered cell: the dose times the exposed fraction",
        wet(4, 4) .. "/" .. wet(6, 4) .. "/" .. wet(8, 4), "123/85/104")
    T.eq("W2 the day was recorded as watered by rain", tostring(W.sys.materialWetness.waterRecord[101].water) .. "/" .. W.sys.materialWetness.waterRecord[101].source, "true/rain")
    local ls = W.sys.materialWetness.lastSettle
    T.eq("W3 [cost] the rain pass counted the sheltered cells it read", ls.shelteredCells, 2)

    -- No usable mask (the map's layer missing, handle 0, but a modifier built over it
    -- that would answer "indoor" if asked): exposed everywhere, never asked.
    world(100, { noMask = true, weather = { sky = SKY, rain = { rainScale = 1 } }, beforeArm = function() setCell(6, 4, 3, 100) end })
    installAll()
    T.eq("W3b [world] the zero-handle mask carries a modifier that would call the cell indoor", (select(2, g_currentMission.indoorMask.modifierValue:executeGet(nil))), 16)
    settleDay(101)
    T.eq("W4 a mask with a zero handle is no shelter evidence: the cell wets in full, the modifier never asked", wet(6, 4), 123)

    -- Rain never initialises: an unknown member stays unknown, a record-less cell stays absent.
    world(100, { weather = { sky = SKY, rain = { rainScale = 1 } }, beforeArm = function() setCell(6, 4, 3, 24) end })
    installAll()
    settleDay(101)
    T.eq("W5 rain does not initialise an unknown member", wet(6, 4), 24)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE PLACEABLE LIFECYCLE: A PAINT INVALIDATES THE SHELTER READ
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    world(100, { weather = { sky = SKY, rain = { rainScale = 1 } }, beforeArm = function() setCell(6, 4, 3, 100) setCell(4, 4, 3, 100) end })
    local okAll = installAll()
    local mask = g_currentMission.indoorMask
    T.eq("L1 [reached] installAll wrapped the mission's indoor mask instance, leaving the class alone", tostring(okAll) .. "/" .. tostring(rawget(mask, "setStateByArea") ~= nil) .. "/" .. tostring(IndoorMask.setStateByArea == rawget(mask, "_sfShelterWrap").original), "true/true/true")
    -- Read the fraction once (cached exposed), then a roof is finalised over the cell.
    T.eq("L2 [world] the cell reads exposed before any roof", W.sys.materialWetness:exposedFraction(6, 4), 1)
    roof(-8, -16, -4, -12)
    T.eq("L3 the paint dropped the cached fraction for the cells it touched and not for others", tostring(W.sys.materialWetness.shelterCells["6:4"]) .. "/" .. tostring(W.sys.materialWetness.shelterCells["4:4"]), "nil/nil")
    W.sys.materialWetness:exposedFraction(4, 4)
    roof(-8, -16, -4, -12, IndoorMask.OUTDOOR)
    T.eq("L4 a paint over one cell leaves another cell's cached fraction alone", tostring(W.sys.materialWetness.shelterCells["4:4"]), "1")
    roof(-8, -16, -4, -12)
    settleDay(101)
    T.eq("L5 the next settle reads the roof: covered cell dry-only, open cell rained on", wet(6, 4) .. "/" .. wet(4, 4), "85/123")

    -- A paint that raises: re-raised to the engine, the whole cache dropped.
    W.sys.materialWetness:exposedFraction(4, 4)
    mask._layer.throwOnSet = true
    local okP, errP = pcall(roof, -8, -16, -4, -12)
    mask._layer.throwOnSet = nil
    T.eq("L6 a paint that raised reaches the engine unchanged and drops the whole shelter cache", tostring(okP) .. "/" .. tostring(errP ~= nil and tostring(errP):find("engine refused the set", 1, true) ~= nil) .. "/" .. tostring(next(W.sys.materialWetness.shelterCells)), "false/true/nil")

    -- Cleanup restores the instance to the class method.
    for _, h in ipairs(W.sys.hookManager.hooks) do
        if tostring(h.name):find("shelter invalidation", 1, true) then h.cleanup() end
    end
    T.eq("L7 the cleanup restores the mission's mask to its class method", tostring(rawget(mask, "setStateByArea")) .. "/" .. tostring(rawget(mask, "_sfShelterWrap")), "nil/nil")

    -- No mask instance at all: the hook stands down and says so; the settle still runs.
    world(100, { noMaskAtAll = true, beforeArm = function() setCell(4, 4, 1, 204) end })
    installAll()
    settleDay(101)
    T.eq("L8 with no indoor mask on the mission the hook stands down, and the settle wets in full as neutral", lines(WARN, "indoorMask:setStateByArea not available") .. "/" .. wet(4, 4), "1/79")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. A REFUSED BIT WRITE: REBUILD REQUIRED, RECONCILED OR HELD
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    world(100)
    local v = mowerInWorld()
    ENGINE.mowable[GRASS] = 400
    installAll()
    W.member.throwOnSet = true
    ENGINE.tick(v, 16)
    local st = coord():getMembershipStats()
    T.eq("H1 a deposit whose membership bit the engine refused leaves the index rebuild-required and the cell unavailable",
        tostring(st.ready) .. "/" .. tostring(st.rebuildRequired) .. "/" .. tostring(coord():isUnavailable(8, 9)) .. "/" .. coord():unavailableReason(8, 9), "false/true/true/MEMBERSHIP_WRITE_FAILED")
    -- Still refusing at the day boundary: the day holds.
    settleDay(101)
    T.eq("H2 while the index cannot be reconciled the day holds: cursor kept, said in the log", tostring(W.sys.materialWetness.appliedThroughDay) .. "/" .. lines(WARN, "membership index needs a rebuild that did not complete"), "100/1")
    -- The engine writes again: the settle reconciles (rebuilds from the truth) and runs.
    W.member.throwOnSet = nil
    settleDay(101)
    st = coord():getMembershipStats()
    T.eq("H3 once bits can be written the settle reconciles the index from the condition bytes and native occupancy, and the day settles",
        tostring(st.ready) .. "/" .. st.source .. "/" .. tostring(coord():isMember(9, 9)) .. "/" .. tostring(W.sys.materialWetness.appliedThroughDay), "true/REBUILT/true/101")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A RUN WRITE THE ENGINE REFUSES
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    -- The preflight: the aimed box takes in a neighbour, so the run is not the run we
    -- mean; nothing is written and the run's cells go unavailable.
    world(100, { beforeArm = function() setCell(4, 4, 1, 204) setCell(5, 4, 1, 204) end })
    installAll()
    W.wet.extraPixels = 1
    settleDay(101)
    W.wet.extraPixels = nil
    T.eq("C1 a run whose preflight selects more than the run is not written: bytes kept, both cells marked unavailable with the refusal",
        wet(4, 4) .. "/" .. wet(5, 4) .. "/" .. tostring(coord():unavailableReason(4, 4)) .. "/" .. tostring(coord():unavailableReason(5, 4)), "204/204/WEATHER:PREFLIGHT_NOT_ONE_PIXEL/WEATHER:PREFLIGHT_NOT_ONE_PIXEL")
    T.eq("C1b the day still settled and was recorded (the refusal is the cells', not the day's)", tostring(W.sys.materialWetness.appliedThroughDay), "101")

    -- The set itself raises: the same marks, the error swallowed into the refusal.
    world(100, { beforeArm = function() setCell(4, 4, 1, 204) end })
    installAll()
    W.wet.throwOnSet = true
    settleDay(101)
    W.wet.throwOnSet = nil
    T.eq("C2 a run write that raised leaves the bytes and marks the cell unavailable with WRITE_THREW", wet(4, 4) .. "/" .. tostring(coord():unavailableReason(4, 4)), "204/WEATHER:WRITE_THREW")
    settleDay(102)
    T.eq("C3 an unavailable member is skipped on the next day: unread, unwritten, still unavailable", wet(4, 4) .. "/" .. tostring(coord():isUnavailable(4, 4)) .. "/" .. W.sys.materialWetness.lastSettle.dryReads, "204/true/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE ENVIRONMENT IS THE MOD'S OWN
-- ══════════════════════════════════════════════════════════════════════════
group("V", function()
    T.eq("V1 [world] the sources run in a mod-shaped environment: rawget(_G, 'getBitVectorMapPoint') is nil and the plain read reaches the engine through __index",
        tostring(rawget(_G, "getBitVectorMapPoint") == nil) .. "/" .. type(getBitVectorMapPoint), "true/function")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- X. NO FAMILY WARNINGS LEAKED
-- ══════════════════════════════════════════════════════════════════════════
group("X", function()
    local leaked = {}
    for _, w in ipairs(WARN) do
        if (w:find("[GroundCoord]", 1, true) or w:find("[GroundCarrier]", 1, true) or w:find("[MaterialWetness]", 1, true)
            or w:find("[IndoorMask]", 1, true) or w:find("[MowerCarrier]", 1, true) or w:find("ERROR", 1, true))
           and not w:find("no groundMembership layer", 1, true)
           and not w:find("needs a rebuild that did not complete", 1, true)
           and not w:find("membership bit for cell", 1, true)
           and not w:find("indoorMask:setStateByArea not available", 1, true)
           and not w:find("EMC ceiling table is PLACEHOLDER", 1, true) then
            leaked[#leaked + 1] = w
        end
    end
    T.eq("X1 no unexpected family warning or error across the bar", #leaked == 0 and "none" or table.concat(leaked, " | "), "none")
end)

T.summary()
