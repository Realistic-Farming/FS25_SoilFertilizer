-- =========================================================
-- FS25 Realistic Soil & Fertilizer - SF-73 target application
-- =========================================================
-- Target automatic for N/P/K (SF-73 Implementation v1.1). With AUTO on for a
-- vehicle and the product carrying N/P/K, one Soil-owned resolver answers the
-- whole cycle's quantity on the live getSprayerUsage path, so the litres quoted,
-- bought or drawn, credited and explained are the same pass:
--
--   cycle start   a prepend on Sprayer.onStartWorkAreaProcessing opens a cycle
--                 record for the vehicle (queries do not spend);
--   quote         the owned outer layer on getSprayerUsage asks planFor(), which
--                 freezes the geometry, runs the pre-spend width witness, reads the
--                 strict carrier footprint and returns ONE quantity per product;
--   enforce       the last start append zeroes a refused cycle's usage and fill
--                 level (the product stays valid, so native neither paints nor
--                 raises a false out-of-fill) and bypasses the rate multiplier;
--   actual litres the drain token records FillUnit's applied delta, the external
--                 fill records the bought litres or the station's own removal;
--   commit        the area hook enters the existing consequence path once with the
--                 actual litres, then this file's frozen polygon writer adds N/P/K.
--
-- LOCKED behind ReleaseGate "sf73_target" (fail-closed here: a money and tank
-- feature does not run when the opt-in cannot be read). With the gate closed, or
-- AUTO off, or a product without N/P/K, every hook delegates and nothing changes.
--
-- MECHANISM NOTE (declared in the PR): one carrier cell is about 2 m and one
-- cycle moves the boom a few centimetres, so a single cycle's swept quad rarely
-- holds a whole carrier pixel. The anchor is HELD until the quad closes at least
-- one pixel; the held cycles quote zero litres while native paint continues, and
-- the closing cycle doses exactly the closed pixels with the capacity the machine
-- measured over that same travel. A refusal before closure clears the held region.
-- =========================================================

TargetApplication = TargetApplication or {}
local TA = TargetApplication
local TA_mt = { __index = TargetApplication }
local C = TargetNutrientCore
local F = TargetFootprint

TA.SYSTEM_ID          = "sf73_target"
TA.RESULT_INTERVAL_MS = 500     -- presentation cadence, not an economic clock
TA.RESULT_EXPIRY_MS   = 1000    -- two missed intervals while active
TA.MIN_TRAVEL         = 0.05    -- metres of forward movement that count as a sweep
TA.WIDTH_TOLERANCE    = 0.05    -- a width change beyond 5 % re-primes
TA.REMOVAL_TOLERANCE  = 1e-4    -- litres: a removal shorter than this is short
TA.AI_MESSAGE_NAME    = "SOIL_TARGET_BOUNDARY"
TA.CELL_CACHE_LIMIT   = 20000   -- classified cells kept per vehicle across closures

-- Reasons that never count toward the helper's no-progress stop (section 3).
local NOT_COUNTED = { UNKNOWN_PRODUCT = true, FOOTPRINT_PRIMING = true }

local function now()
    return (g_currentMission and g_currentMission.time) or 0
end

local function logDebug(fmt, ...)
    if SoilLogger ~= nil then SoilLogger.debug(fmt, ...) end
end

--- The AUTO key: the root vehicle's id when a separate tractor carries the rate,
--- the same derivation the HUD, PositionalPH and the rate hooks use.
local function rateVehicleId(sprayer)
    local root = sprayer and sprayer.rootVehicle
    if root ~= nil and root ~= sprayer then return root.id or 0 end
    return sprayer and sprayer.id or 0
end
TA.rateVehicleId = rateVehicleId

function TA.new(soilSystem)
    local self = setmetatable({}, TA_mt)
    self.soilSystem   = soilSystem
    self.states       = {}      -- server: vehicle object -> state
    self.client       = {}      -- client: vehicle object -> last confirmed result
    self.epochCounter = 0
    self.aiMessageClass = nil
    return self
end

-- ── gate and mode ───────────────────────────────────────────────────────────

--- LOCKED unless the player opted into experimental systems. Fail-closed: nil
--- (settings unreadable) is locked for a feature that moves money and tanks.
function TA:isGateOpen()
    if ReleaseGate == nil then return false end
    return ReleaseGate.isReleased(TA.SYSTEM_ID, ReleaseGate.liveOptIn())
end

function TA:isTargetMode(sprayer)
    if g_server == nil or sprayer == nil or not sprayer.isServer then return false end
    local sfm = g_SoilFertilityManager
    local settings = sfm and sfm.settings
    if settings == nil or settings.enabled == false or settings.autoRateControl == false then return false end
    if not self:isGateOpen() then return false end
    local rm = sfm.sprayerRateManager
    return rm ~= nil and rm:getAutoMode(rateVehicleId(sprayer)) == true
end

function TA:newState(vehicle)
    local st = {
        vehicle = vehicle, active = false, epoch = nil, sequence = "0",
        cycleSerial = 0, cycle = nil, hold = nil,
        guard = { key = nil, blocked = false },
        result = nil, lastSentAt = nil, pendingSend = false,
    }
    self.states[vehicle] = st
    return st
end

function TA:activate(st)
    self.epochCounter = self.epochCounter + 1
    st.epoch = tostring(self.epochCounter)
    st.sequence = "0"
    st.active = true
    st.hold = nil
    st.guard = { key = nil, blocked = false }
    st.result = nil
end

function TA:deactivate(st)
    st.active = false
    st.cycle = nil
    st.hold = nil
    st.guard = { key = nil, blocked = false }
    if st.result ~= nil then
        st.result.active = false
        self:publish(st, true)
    end
end

--- Forget a vehicle entirely (deletion). A later object never inherits its result.
function TA:forget(vehicle)
    self.states[vehicle] = nil
    self.client[vehicle] = nil
end

--- A reload clears vehicle auto mode, plans, results and anchors (section 6).
function TA:reset()
    self.states = {}
    self.client = {}
end

-- ── the cycle ───────────────────────────────────────────────────────────────

--- Prepend on Sprayer.onStartWorkAreaProcessing: open this cycle's record.
function TA:onCycleStart(sprayer, dt)
    if g_server == nil or sprayer == nil or not sprayer.isServer then return end
    local st = self.states[sprayer]
    if not self:isTargetMode(sprayer) then
        if st ~= nil then
            if st.active then self:deactivate(st) end
            st.cycle = nil
        end
        return
    end
    st = st or self:newState(sprayer)
    if not st.active then self:activate(st) end
    st.cycleSerial = st.cycleSerial + 1
    st.cycle = { serial = st.cycleSerial, dt = dt, plans = {}, openedAt = now(),
                 -- a later occupant replaced the owned usage slot: its quantity is not ours
                 contractBroken = not self:usageSlotOwned(sprayer) }
end

--- The live target cycle for a sprayer, or nil.
function TA:cycleFor(sprayer)
    local st = self.states[sprayer]
    return st and st.cycle or nil
end

--- True when this cycle carries a target plan (accepted or refused) rather than a
--- delegated non-target product. The late Soil section hooks stand down for it.
function TA:isTargetCycle(sprayer)
    local cycle = self:cycleFor(sprayer)
    if cycle == nil then return false end
    for _, plan in pairs(cycle.plans) do
        if not plan.nonTarget then return true end
    end
    return false
end

-- ── product, class and source ────────────────────────────────────────────────

local function hookManager(self)
    return self.soilSystem and self.soilSystem.hookManager or nil
end

local function productProfile(fillTypeIndex)
    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    if ft == nil or ft.name == nil then return nil, nil end
    local profile = SoilConstants and SoilConstants.FERTILIZER_PROFILES and SoilConstants.FERTILIZER_PROFILES[ft.name]
    return ft, profile
end

--- The product carries N/P/K when at least one coefficient is positive.
local function carriesNPK(profile)
    if type(profile) ~= "table" then return false end
    for _, n in ipairs(C.NUTRIENTS) do
        if C.finite(profile[n]) and profile[n] > 0 then return true end
    end
    return false
end

local function refusedPlan(fillTypeIndex, state, reasons, extra)
    local plan = { fillType = fillTypeIndex, refused = true, quote = 0, state = state, reasons = reasons or {} }
    if extra then for k, v in pairs(extra) do plan[k] = v end end
    return plan
end

local function vehiclesOf(sprayer)
    local list, seen = {}, {}
    local function add(v)
        if type(v) == "table" and not seen[v] then seen[v] = true; list[#list + 1] = v end
    end
    add(sprayer)
    local root = sprayer and sprayer.rootVehicle
    add(root)
    local kids = root and root.childVehicles
    if type(kids) == "table" then for _, v in pairs(kids) do add(v) end end
    return list
end

--- The Pumps N' Hoses umbilical / buffered sprayers: their later source and usage
--- rewrites are not the one native litre contract, connected or not. Matched by
--- the last segment of the specialization name, whatever the pack's prefix.
local function hasHoseContract(sprayer)
    for _, v in ipairs(vehiclesOf(sprayer)) do
        local names = v.specializationNames
        if type(names) == "table" then
            for _, name in ipairs(names) do
                local last = string.lower(tostring(name):match("([^%.]+)$") or "")
                if last == "umbilicalsprayer" or last == "bufferedsprayer" then return true end
            end
        end
    end
    return false
end

--- True when the vehicle's usage slot holds the owned SF-73 layer.
function TA:usageSlotOwned(sprayer)
    local hm = hookManager(self)
    if hm == nil or type(hm.isOwnedLayerWrapper) ~= "function" then return false end
    return hm:isOwnedLayerWrapper(sprayer.getSprayerUsage)
end

--- A target cycle whose usage slot a later occupant took: an N/P/K product is
--- refused before spending (SOURCE_CONTRACT_UNAVAILABLE). Returns true when refused.
function TA:contractRefusal(sprayer, fillTypeIndex)
    local cycle = self:cycleFor(sprayer)
    if cycle == nil or not cycle.contractBroken then return false end
    local _, profile = productProfile(fillTypeIndex)
    if not carriesNPK(profile) then return false end
    if cycle.plans[fillTypeIndex] == nil then
        cycle.target = true
        cycle.plans[fillTypeIndex] = refusedPlan(fillTypeIndex, C.STATE.INACTIVE,
            { C.REASON.SOURCE_CONTRACT_UNAVAILABLE }, { clearAnchor = true })
    end
    return true
end

--- Refusals that follow from the actor class, before anything is read.
function TA:classRefusal(sprayer)
    if sprayer.spec_cultivator ~= nil then return C.REASON.CULTIVATION_NO_TARGET, C.STATE.INACTIVE end
    if hasHoseContract(sprayer) then return C.REASON.SOURCE_CONTRACT_UNAVAILABLE, C.STATE.INACTIVE end
    -- A fertilizing seeder may target only with a whole-area sowability witness,
    -- which this build does not construct: target fertilizer is withheld and the
    -- seeding itself carries on.
    if sprayer.spec_sowingMachine ~= nil then return C.REASON.SOWABILITY_UNKNOWN, C.STATE.UNDETERMINED end
    if not self:usageSlotOwned(sprayer) then
        -- a later occupant wraps the owned slot: its quantity semantics are unproved
        return C.REASON.SOURCE_CONTRACT_UNAVAILABLE, C.STATE.INACTIVE
    end
    return nil, nil
end

--- Native's external-source decision for a product (Sprayer.lua:383-465 and the
--- custom-product rule of HookManager's external fill layer).
local function externalMode(fillTypeName)
    local mi = g_currentMission and g_currentMission.missionInfo
    if mi == nil then return nil end
    if fillTypeName == "LIQUIDMANURE" or fillTypeName == "DIGESTATE" then
        if mi.helperSlurrySource == 2 then return "BUY" end
        if (mi.helperSlurrySource or 0) > 2 then return "STATION" end
        return nil
    end
    if fillTypeName == "MANURE" then
        if mi.helperManureSource == 2 then return "BUY" end
        if (mi.helperManureSource or 0) > 2 then return "STATION" end
        return nil
    end
    if mi.helperBuyFertilizer == true then return "BUY" end
    return nil
end
TA.externalMode = externalMode

local function stationFor(fillTypeName)
    local mission = g_currentMission
    local mi = mission and mission.missionInfo
    if mi == nil then return nil end
    if fillTypeName == "LIQUIDMANURE" or fillTypeName == "DIGESTATE" then
        local list = mission.liquidManureLoadingStations
        return list and list[(mi.helperSlurrySource or 0) - 2] or nil
    end
    if fillTypeName == "MANURE" then
        local list = mission.manureLoadingStations
        return list and list[(mi.helperManureSource or 0) - 2] or nil
    end
    return nil
end

local function activeFarmOf(sprayer)
    local farmId
    if type(sprayer.getActiveFarm) == "function" then
        local ok, f = pcall(sprayer.getActiveFarm, sprayer)
        if ok then farmId = f end
    end
    if (farmId == nil or farmId == 0) and type(sprayer.getOwnerFarmId) == "function" then
        local ok, f = pcall(sprayer.getOwnerFarmId, sprayer)
        if ok then farmId = f end
    end
    return farmId
end

--- The first accessible storage with stock, in native's own traversal
--- (LoadingStation.lua:220-234): the one removal a capped request touches.
function TA.firstStationSource(station, fillTypeIndex, farmId)
    if station == nil or type(station.sourceStorages) ~= "table" then return nil, 0 end
    for _, storage in pairs(station.sourceStorages) do
        if station:hasFarmAccessToStorage(farmId, storage) then
            local level = storage:getFillLevel(fillTypeIndex) or 0
            if level > 0 then return storage, level end
        end
    end
    return nil, 0
end

--- Where this cycle's product comes from, and how much of it there is.
---@return number|nil supply (nil = unlimited helper buy), string mode
function TA:sourceSupply(sprayer, fillTypeIndex, fillTypeName)
    local external = false
    if type(sprayer.getIsSprayerExternallyFilled) == "function" then
        local ok, e = pcall(sprayer.getIsSprayerExternallyFilled, sprayer)
        external = ok and e == true
    end
    local turnedOn = type(sprayer.getIsTurnedOn) ~= "function" or sprayer:getIsTurnedOn() == true
    if external and turnedOn then
        local mode = externalMode(fillTypeName)
        if mode == "BUY" then return nil, "BUY" end
        if mode == "STATION" then
            local _, level = TA.firstStationSource(stationFor(fillTypeName), fillTypeIndex, activeFarmOf(sprayer))
            return level, "STATION"
        end
    end
    local spec = sprayer.spec_sprayer
    local okFu, fui = pcall(sprayer.getSprayerFillUnitIndex, sprayer)
    if okFu and fui ~= nil then
        local level = sprayer:getFillUnitFillLevel(fui) or 0
        if level > 0 then
            return (sprayer:getFillUnitFillType(fui) == fillTypeIndex) and level or 0, "TANK"
        end
    end
    if spec ~= nil and type(spec.supportedSprayTypes) == "table" and type(spec.fillTypeSources) == "table" then
        for _, supported in ipairs(spec.supportedSprayTypes) do
            for _, src in ipairs(spec.fillTypeSources[supported] or {}) do
                local v = src.vehicle
                if v ~= nil and v:getIsFillUnitActive(src.fillUnitIndex) then
                    local vft = v:getFillUnitFillType(src.fillUnitIndex)
                    local vl = v:getFillUnitFillLevel(src.fillUnitIndex) or 0
                    if vl > 0 and vft == supported then
                        return (vft == fillTypeIndex) and vl or 0, "SOURCE"
                    end
                end
            end
        end
    end
    return 0, "TANK"
end

-- ── the plan ─────────────────────────────────────────────────────────────────

local function anyWorkAreaActive(sprayer)
    local waSpec = sprayer.spec_workArea
    if waSpec == nil or type(waSpec.workAreas) ~= "table" or type(sprayer.getIsWorkAreaActive) ~= "function" then
        return false
    end
    for _, wa in ipairs(waSpec.workAreas) do
        local ok, active = pcall(sprayer.getIsWorkAreaActive, sprayer, wa)
        if ok and active then return true end
    end
    return false
end

--- The carrier layer bounds for the three nutrients.
local function carrierBounds()
    local bounds = {}
    for _, def in ipairs(SoilValueMaps and SoilValueMaps.LAYER_DEFS or {}) do
        for _, n in ipairs(C.NUTRIENTS) do
            if def.key == C.LAYER_KEY[n] then bounds[n] = { min = def.minVal, max = def.maxVal } end
        end
    end
    return bounds
end
TA.carrierBounds = carrierBounds

function TA:cropKeyForDesc(desc)
    if desc == nil or desc.name == nil then return nil end
    return C.resolveCropKey(desc.name, SoilConstants.CROP_NUTRIENT_TARGETS,
        SoilConstants.PERENNIAL_FORAGE_NAMES, SoilConstants.SF73_CROP_ALIASES)
end

--- The strict carrier read over the swept quad: every pixel of all three layers
--- written, the same count on each. nil counts mean the polygon read refused.
function TA:strictRead(verts)
    local vm = self.soilSystem and self.soilSystem.valueMaps
    if vm == nil or type(vm.readPolygonStrict) ~= "function" then return nil end
    local out = {}
    for _, n in ipairs(C.NUTRIENTS) do
        local key = C.LAYER_KEY[n]
        local sum, written, total = vm:readPolygonStrict(key, verts)
        if sum == nil then return nil end
        out[n] = { rawSum = sum, written = written, total = total, key = key }
    end
    return out
end

local function readStrict(read)
    if read == nil then return false end
    local total = read.N.total
    for _, n in ipairs(C.NUTRIENTS) do
        local r = read[n]
        if r.total ~= total or r.written ~= r.total then return false end
    end
    return true
end

--- Build this cycle's plan for one product. Called once per product per cycle;
--- a repeated query returns the same table (no second purchase, no second anchor).
function TA:buildPlan(st, cycle, sprayer, fillTypeIndex, dt, predecessor)
    local ft, profile = productProfile(fillTypeIndex)
    local hm = hookManager(self)
    if ft == nil or not carriesNPK(profile)
       or (hm ~= nil and type(hm.isRefusedProduct) == "function" and hm:isRefusedProduct(fillTypeIndex)) then
        -- Not an N/P/K product (or F196 refuses it): target automatic does not apply;
        -- the existing path owns it, the rate multiplier and R2 included.
        return { fillType = fillTypeIndex, nonTarget = true }
    end
    cycle.target = true

    local reason, state = self:classRefusal(sprayer)
    if reason ~= nil then
        return refusedPlan(fillTypeIndex, state, { reason }, { clearAnchor = true })
    end

    -- Effective native doubled amount paints two steps from one quoted litre rate
    -- (Sprayer.lua:325, :656-671). A stored but inactive flag is not a refusal.
    if type(sprayer.getSprayerDoubledAmountActive) == "function" and g_sprayTypeManager ~= nil then
        local sprayTypeIndex = g_sprayTypeManager:getSprayTypeIndexByFillTypeIndex(fillTypeIndex)
        local ok, doubled = pcall(sprayer.getSprayerDoubledAmountActive, sprayer, sprayTypeIndex)
        if ok and doubled == true then
            return refusedPlan(fillTypeIndex, C.STATE.INACTIVE, { C.REASON.DOUBLED_AMOUNT_ACTIVE }, { clearAnchor = true })
        end
    end

    -- Native activity, snapped before acquisition: turned on, an active area, and
    -- not a pass Soil's overlap prevention has blocked.
    local turnedOn = type(sprayer.getIsTurnedOn) ~= "function" or sprayer:getIsTurnedOn() == true
    if not turnedOn or not anyWorkAreaActive(sprayer)
       or (HookManager ~= nil and HookManager.isOverlapBlockedPass ~= nil and HookManager.isOverlapBlockedPass(sprayer)) then
        return refusedPlan(fillTypeIndex, C.STATE.INACTIVE, {}, { clearAnchor = true, nativeInactive = true })
    end
    local suppressed = sprayer._sfOverlapSuppressedSections
    if type(suppressed) == "table" and next(suppressed) ~= nil then
        -- a partial Soil nozzle shut-off: physical deposition no longer matches one width
        return refusedPlan(fillTypeIndex, C.STATE.INACTIVE, { C.REASON.NOZZLE_PARTIAL }, { clearAnchor = true })
    end

    local geometry, geomRefusal = F.treatmentGeometry(sprayer)
    if geometry == nil then
        if geomRefusal ~= nil then
            local s = (geomRefusal == "UNKNOWN_GROUND") and C.STATE.UNDETERMINED or C.STATE.INACTIVE
            return refusedPlan(fillTypeIndex, s, { geomRefusal }, { clearAnchor = true })
        end
        return refusedPlan(fillTypeIndex, C.STATE.INACTIVE, {}, { clearAnchor = true, nativeInactive = true })
    end

    -- Priming: the first valid line is observed only. A product or width change,
    -- a teleport or no forward movement re-primes rather than bridging ground.
    local hold = st.hold
    local reprime = hold == nil or hold.fillType ~= fillTypeIndex or hold.areaKey ~= geometry.areaKey
        or math.abs(geometry.width - hold.width) > TA.WIDTH_TOLERANCE * math.max(hold.width, 0.01)
    local verts, travel, quadArea
    if not reprime then
        verts, travel, quadArea = F.sweptQuad(hold.anchor, geometry.line)
        if travel < TA.MIN_TRAVEL or travel > geometry.width * 3 then reprime = true end
    end

    -- The witness over every native paint polygon (where native would paint this
    -- cycle) and the swept quad when there is one, with the outer guard. A priming
    -- line must itself be valid: an ineligible line is a refusal, not an observation.
    local polys = {}
    if not reprime then polys[1] = verts end
    for _, p in ipairs(geometry.paintPolys) do polys[#polys + 1] = p end
    local caches = (not reprime and hold ~= nil) and hold or { cells = {}, access = {}, cropKeys = {} }
    local soilSystem = self.soilSystem
    local verdict = F.witness(polys, {
        farmId = activeFarmOf(sprayer),
        env = TA.ENGINE or F.ENGINE,
        cache = caches.cells, accessCache = caches.access, cropKeyCache = caches.cropKeys,
        soilRecordFor = function(farmlandId)
            return soilSystem.fieldData ~= nil and soilSystem.fieldData[farmlandId] ~= nil
        end,
        cropKeyFor = function(desc) return self:cropKeyForDesc(desc) end,
    })
    caches.cellCount = (caches.cellCount or 0) + (verdict.newCells or 0)
    if not verdict.accepted then
        return refusedPlan(fillTypeIndex, verdict.state, verdict.reasons, { clearAnchor = true, geometry = geometry })
    end
    if reprime then
        return refusedPlan(fillTypeIndex, C.STATE.INACTIVE, { C.REASON.FOOTPRINT_PRIMING },
            { primeLine = geometry.line, geometry = geometry, primeCaches = caches,
              fieldId = verdict.farmlandId, fruitIndex = verdict.fruitIndex, cropKey = verdict.cropKey })
    end
    local fieldId = verdict.farmlandId
    local field = soilSystem.fieldData[fieldId]

    -- The strict carrier footprint; raw-zero cells on accepted ground take the
    -- field's frozen baseline, then the read runs again. Never the block fallback.
    local read = self:strictRead(verts)
    if read ~= nil and not readStrict(read) and read.N.total > 0 then
        if self:initializeRawZero(fieldId, field, verts) then read = self:strictRead(verts) end
    end
    if read == nil or not readStrict(read) then
        return refusedPlan(fillTypeIndex, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_GROUND }, { clearAnchor = true })
    end

    local ftName = ft.name
    local supply, sourceMode = self:sourceSupply(sprayer, fillTypeIndex, ftName)
    local basePlan = {
        fillType = fillTypeIndex, fillTypeName = ftName, geometry = geometry, verts = verts,
        quadArea = quadArea, travel = travel, fieldId = fieldId, fruitIndex = verdict.fruitIndex,
        cropKey = verdict.cropKey, sourceMode = sourceMode, supply = supply, profile = profile,
    }

    local predThis = 0
    if predecessor ~= nil then
        local ok, p = pcall(predecessor, sprayer, fillTypeIndex, dt)
        if ok and C.finite(p) and p > 0 then predThis = p end
    end
    basePlan.predThis = predThis

    local total = read.N.total
    if total <= 0 then
        -- Not doseable yet: the quad holds no whole carrier pixel. Hold the anchor,
        -- spend nothing; native paint continues on ground the closing cycle pays for.
        basePlan.hold = true
        basePlan.quote = 0
        basePlan.state = nil
        return basePlan
    end

    -- Readings, windows and needs over the accepted footprint.
    local vm = soilSystem.valueMaps
    local grain = vm:getGrainMetres()
    local entry = SoilConstants.CROP_NUTRIENT_TARGETS[verdict.cropKey]
    local wins, steps = C.cropWindows(entry, carrierBounds())
    if wins == nil or grain == nil or grain <= 0 then
        return refusedPlan(fillTypeIndex, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_GROUND }, { clearAnchor = true })
    end
    local readings, needs, coefs = {}, {}, {}
    for _, n in ipairs(C.NUTRIENTS) do
        local r = read[n]
        readings[n] = vm:decodeForLayer(r.key, r.rawSum / r.written)
        needs[n] = math.max(0, wins[n].aim - readings[n])
        coefs[n] = profile[n] or 0
    end
    local acceptedHa = total * grain * grain / 10000
    local unitFactor, rr, tuning = soilSystem:sf73CreditFactors(ft)
    local target, binding, perNutrient, failure = C.bindingLitres(needs, coefs, acceptedHa, unitFactor, rr, tuning)
    if target == nil then
        return refusedPlan(fillTypeIndex, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_PRODUCT },
            { clearAnchor = true, failure = failure })
    end

    -- Capacity: the machine's measured native 1x rate over this same travel, on the
    -- footprint it will write. The predecessor is Soil's actual-speed native shape.
    local predSum = (hold.predSum or 0) + predThis
    local capacity = predThis
    if quadArea ~= nil and quadArea > 1e-6 then
        capacity = predSum * (total * grain * grain) / quadArea
    end
    -- The existing SF-79 pH factor is the modifier, resolved before the minimum. No
    -- shipped N/P/K product carries pH, so this is 1 unless one ever does.
    local modifier = 1.0
    if C.finite(profile.pH) and profile.pH ~= 0 and type(soilSystem.updatePHWorkAuto) == "function" then
        local ok, f = pcall(soilSystem.updatePHWorkAuto, soilSystem, sprayer, dt,
            sprayer.spec_workArea and sprayer.spec_workArea.workAreas)
        if ok and C.finite(f) and f >= 0 then modifier = f end
    end
    local quote, limits = C.accept(target, capacity, supply, modifier)
    if quote == nil then
        return refusedPlan(fillTypeIndex, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_PRODUCT }, { clearAnchor = true })
    end

    basePlan.quote = quote
    basePlan.target = target
    basePlan.capacity = capacity
    basePlan.modifier = modifier
    basePlan.limits = limits
    basePlan.binding = binding
    basePlan.perNutrient = perNutrient
    basePlan.readings = readings
    basePlan.windows = wins
    basePlan.steps = steps
    basePlan.needs = needs
    basePlan.coefs = coefs
    basePlan.acceptedHa = acceptedHa
    basePlan.pixels = total
    basePlan.grain = grain
    basePlan.unitFactor, basePlan.rr, basePlan.tuning = unitFactor, rr, tuning
    basePlan.dose = quote > 0
    return basePlan
end

--- The cycle's plan for a product, built once.
function TA:planFor(sprayer, fillTypeIndex, dt, predecessor)
    local st = self.states[sprayer]
    local cycle = st and st.cycle
    if cycle == nil then return nil end
    local plan = cycle.plans[fillTypeIndex]
    if plan ~= nil then return plan end
    if cycle.spent ~= nil and cycle.spent ~= fillTypeIndex then
        -- product already bought this cycle: another product cannot be quoted after it
        plan = refusedPlan(fillTypeIndex, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_PRODUCT })
    else
        local ok, built = pcall(self.buildPlan, self, st, cycle, sprayer, fillTypeIndex, dt, predecessor)
        if ok then
            plan = built
        else
            logDebug("[SF-73] plan failed: %s", tostring(built))
            plan = refusedPlan(fillTypeIndex, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_GROUND }, { clearAnchor = true })
        end
    end
    cycle.plans[fillTypeIndex] = plan
    return plan
end

--- The owned usage layer's question. nil = not a target quote (delegate).
function TA:quote(sprayer, fillTypeIndex, dt, predecessor)
    if self:cycleFor(sprayer) == nil then return nil end
    local plan = self:planFor(sprayer, fillTypeIndex, dt, predecessor)
    if plan == nil or plan.nonTarget then return nil end
    return plan.quote or 0
end

--- The quote the custom-product buy charge uses for this cycle, or nil. The custom
--- buy path can ask before native's own usage query named this product, so the
--- question goes through the vehicle's own usage slot: the owned layer answers it
--- with the cycle's one plan, built there with the right predecessor.
function TA:externalQuote(sprayer, fillTypeIndex, dt)
    local cycle = self:cycleFor(sprayer)
    if cycle == nil then return nil end
    if cycle.plans[fillTypeIndex] == nil and type(sprayer.getSprayerUsage) == "function" then
        pcall(sprayer.getSprayerUsage, sprayer, fillTypeIndex, dt)
    end
    local plan = cycle.plans[fillTypeIndex]
    if plan == nil or plan.nonTarget then return nil end
    return plan.quote or 0
end

-- ── external supply ─────────────────────────────────────────────────────────

--- Station supply for a target cycle, done here so one request touches one source:
--- the first accessible storage with stock, capped to it, the removal measured on
--- the station's own side. A fallback product gets a fresh plan and coefficients.
---@return boolean handled, number fillType, number litres
function TA:stationFill(sprayer, fillTypeIndex, dt)
    local cycle = self:cycleFor(sprayer)
    if cycle == nil then return false end
    if FillType == nil then return false end
    -- Native's branch order and its allow tests for an empty tank (Sprayer.lua:383-440).
    local function allows(ft)
        local okFu, fui = pcall(sprayer.getSprayerFillUnitIndex, sprayer)
        if not okFu or fui == nil or type(sprayer.getFillUnitAllowsFillType) ~= "function" then return false end
        local ok, a = pcall(sprayer.getFillUnitAllowsFillType, sprayer, fui, ft)
        return ok and a == true
    end
    local candidates, name
    local unknown = fillTypeIndex == FillType.UNKNOWN
    if fillTypeIndex == FillType.LIQUIDMANURE or fillTypeIndex == FillType.DIGESTATE
       or (unknown and (allows(FillType.LIQUIDMANURE) or allows(FillType.DIGESTATE))) then
        candidates, name = { FillType.LIQUIDMANURE, FillType.DIGESTATE }, "LIQUIDMANURE"
    elseif fillTypeIndex == FillType.MANURE or (unknown and allows(FillType.MANURE)) then
        candidates, name = { FillType.MANURE }, "MANURE"
    end
    if candidates == nil or externalMode(name) ~= "STATION" then return false end
    local station = stationFor(name)
    local farmId = activeFarmOf(sprayer)
    for _, cand in ipairs(candidates) do
        local _, level = TA.firstStationSource(station, cand, farmId)
        if level > 0 then
            -- a fresh plan for this product, built through the vehicle's own usage slot
            -- so the owned layer measures capacity with its captured predecessor
            if cycle.plans[cand] == nil and type(sprayer.getSprayerUsage) == "function" then
                pcall(sprayer.getSprayerUsage, sprayer, cand, dt)
            end
            local plan = cycle.plans[cand]
            if plan == nil or plan.nonTarget then return false end
            local q = plan.quote or 0
            if q <= 0 then
                -- refused, held or zero: the product stays resolved, nothing is removed
                return true, cand, 0
            end
            local before = station:getFillLevel(cand, farmId) or 0
            station:removeFillLevel(cand, q, farmId)
            local after = station:getFillLevel(cand, farmId) or 0
            local actual = math.max(0, before - after)
            cycle.spent = cand
            cycle.external = { mode = "STATION", fillType = cand, litres = actual, requested = q }
            return true, cand, actual
        end
    end
    return true, FillType.UNKNOWN, 0
end

--- The external fill's answer for a target cycle, recorded as the actual litres.
function TA:recordExternal(sprayer, fillTypeIndex, litres)
    local cycle = self:cycleFor(sprayer)
    if cycle == nil or cycle.external ~= nil then return end
    local plan = cycle.plans[fillTypeIndex]
    if plan == nil or plan.nonTarget then return end
    if C.finite(litres) and litres > 0 then
        cycle.spent = fillTypeIndex
        cycle.external = { mode = "BUY", fillType = fillTypeIndex, litres = litres, requested = plan.quote }
    end
end

-- ── start enforcement ───────────────────────────────────────────────────────

--- The last start append. Returns true when this cycle is a target cycle (and the
--- work-area parameters now say exactly what the plan says), false otherwise.
function TA:enforceStart(sprayer, dt)
    local cycle = self:cycleFor(sprayer)
    if cycle == nil then return false end
    local wap = sprayer.spec_sprayer and sprayer.spec_sprayer.workAreaParameters
    if wap == nil then return false end
    local plan = cycle.plans[wap.sprayFillType]
    if plan == nil then
        -- the usage slot's later occupant answered native without us: refuse an N/P/K
        -- product here, before native's end can draw it
        if self:contractRefusal(sprayer, wap.sprayFillType) then plan = cycle.plans[wap.sprayFillType] end
    end
    if plan == nil then
        if not cycle.target then return false end
        -- A target cycle whose settled product was never quoted: nothing is bought
        -- for a product no plan covers.
        plan = refusedPlan(wap.sprayFillType, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_PRODUCT })
        cycle.plans[wap.sprayFillType or 0] = plan
    end
    if plan.nonTarget then return false end
    cycle.committed = plan
    if plan.dose then
        local usage = (cycle.external ~= nil) and cycle.external.litres or plan.quote
        wap.usage = usage
        wap.usagePerMin = (dt ~= nil and dt > 0) and (usage / dt * 60000) or 0
        -- The tank level as native drains it, for the record: the applied delta is
        -- the measure, and this is only read if the drain token never reported one.
        local sv = wap.sprayVehicle
        if sv ~= nil and wap.sprayVehicleFillUnitIndex ~= nil and type(sv.getFillUnitFillLevel) == "function" then
            local ok, lvl = pcall(sv.getFillUnitFillLevel, sv, wap.sprayVehicleFillUnitIndex)
            if ok and C.finite(lvl) then
                cycle.levelVehicle, cycle.levelUnit, cycle.levelBefore = sv, wap.sprayVehicleFillUnitIndex, lvl
            end
        end
    elseif plan.hold then
        wap.usage = 0
        wap.usagePerMin = 0
        if plan.supply ~= nil and plan.supply <= 0 then
            wap.sprayFillLevel = 0
        elseif (wap.sprayFillLevel or 0) <= 0 then
            -- an external source quoted zero for the held cycle: keep native painting
            -- the ground the closing cycle pays for; nothing is drawn or bought
            wap.sprayFillLevel = math.max(plan.predThis or 0, 1e-3)
        end
    else
        wap.usage = 0
        wap.usagePerMin = 0
        wap.sprayFillLevel = 0
    end
    return true
end

-- ── actual litres ───────────────────────────────────────────────────────────

--- The drain token for a dose cycle carries the cycle so FillUnit's applied delta
--- (FillUnit.lua addFillUnitFillLevel returns it) lands on the record.
function TA:tokenCycle(sprayer)
    local cycle = self:cycleFor(sprayer)
    if cycle ~= nil and cycle.committed ~= nil and cycle.committed.dose then return cycle end
    return nil
end

function TA.recordApplied(cycle, delta)
    if type(cycle) ~= "table" then return end
    if type(delta) == "number" and delta == delta then
        cycle.applied = (cycle.applied or 0) + delta
        cycle.spent = cycle.spent or (cycle.committed and cycle.committed.fillType)
    end
end

--- The physical litres of this cycle: the station's removal, the bought litres or
--- the magnitude of FillUnit's applied delta. Never the planned figure.
function TA:physicalLitres(cycle, wap)
    local plan = cycle.committed
    if plan == nil or not plan.dose then return 0, false end
    if cycle.external ~= nil then
        local ext = cycle.external
        local short = ext.litres + TA.REMOVAL_TOLERANCE < (ext.requested or ext.litres)
            or ext.litres > (ext.requested or ext.litres) + TA.REMOVAL_TOLERANCE
        return ext.litres, short
    end
    if wap == nil or wap.isActive ~= true then return 0, false end
    local applied
    if cycle.applied ~= nil then
        applied = math.abs(cycle.applied)
    elseif cycle.levelVehicle ~= nil then
        -- The token never reported (a drain outside the owned layer): what left the
        -- tank is still physical product, measured on the tank, and never credited
        -- as planned volume. It fails the cycle below unless it is the whole quote.
        local ok, lvl = pcall(cycle.levelVehicle.getFillUnitFillLevel, cycle.levelVehicle, cycle.levelUnit)
        applied = (ok and C.finite(lvl)) and math.max(0, cycle.levelBefore - lvl) or 0
        cycle.measuredOnTank = true
    else
        applied = 0
    end
    return applied, applied + TA.REMOVAL_TOLERANCE < plan.quote
end

-- ── the frozen polygon writer ───────────────────────────────────────────────

--- Saturate the ORIGINAL overflow cohort first (setPolygonWhere must succeed), then
--- add only the ORIGINAL safe interior band (applyRawDeltaToPolygonBand must return
--- non-nil). Negative deltas mirror at the floor. Raw zero is never touched. The
--- useful quantized delta is reported apart from the requested one: nothing banks.
---@return table perNutrient, boolean ok, boolean partial
function TA:writeFootprint(plan, litres)
    local vm = self.soilSystem.valueMaps
    local out, anyOk, anyFail = {}, false, false
    for _, n in ipairs(C.NUTRIENTS) do
        local rec = { requested = 0, useful = 0, raw = 0, ok = true }
        local coef = plan.coefs[n] or 0
        if coef > 0 then
            local delta = C.creditFor(litres, plan.acceptedHa, coef, plan.unitFactor, plan.rr, plan.tuning) or 0
            rec.requested = delta
            local step = plan.steps[n]
            local raw = (delta >= 0) and math.floor(delta / step) or -math.floor(-delta / step)
            if raw > 253 then raw = 253 elseif raw < -253 then raw = -253 end
            rec.raw = raw
            if raw ~= 0 then
                local key = C.LAYER_KEY[n]
                local ok
                if raw > 0 then
                    ok = vm:setPolygonWhere(key, plan.verts, 255, 256 - raw, 255) == true
                    if ok then ok = vm:applyRawDeltaToPolygonBand(key, plan.verts, raw, 1, 255 - raw) ~= nil end
                else
                    local mag = -raw
                    ok = vm:setPolygonWhere(key, plan.verts, 1, 1, mag) == true
                    if ok then ok = vm:applyRawDeltaToPolygonBand(key, plan.verts, raw, 1 + mag, 255) ~= nil end
                end
                rec.ok = ok
                if ok then
                    rec.useful = raw * step
                    anyOk = true
                else
                    anyFail = true
                end
            end
        end
        out[n] = rec
    end
    return out, not anyFail, anyFail and anyOk
end

-- ── cycle end ───────────────────────────────────────────────────────────────

--- Called at the top of the area hook. Returns the target cycle record when this
--- cycle is a target cycle (the area hook then routes it), nil otherwise.
function TA:endCycle(sprayer)
    local st = self.states[sprayer]
    local cycle = st and st.cycle
    if cycle == nil or cycle.closed then return nil end
    if cycle.committed == nil then
        if cycle.target then
            cycle.committed = refusedPlan(nil, C.STATE.UNDETERMINED, { C.REASON.UNKNOWN_PRODUCT })
        else
            return nil
        end
    end
    cycle.closed = true
    local wap = sprayer.spec_sprayer and sprayer.spec_sprayer.workAreaParameters
    cycle.processed = wap ~= nil and wap.isActive == true
    local plan = cycle.committed
    if plan.dose then
        local litres, short = self:physicalLitres(cycle, wap)
        cycle.physical = litres
        cycle.short = short
    else
        cycle.physical = 0
    end
    return cycle
end

--- The helper's no-progress guard: two consecutive distinct refused cycles with
--- neither nutrient nor primary progress stop the job once.
function TA:updateGuard(st, sprayer, plan, progress)
    local key = (plan.geometry and plan.geometry.areaKey) or "ROOT"
    local g = st.guard
    if g.key ~= key then g.key = key; g.blocked = false end
    local counted = plan.refused and not plan.nativeInactive
    if counted then
        for _, r in ipairs(plan.reasons or {}) do
            if NOT_COUNTED[r] then counted = false end
        end
        if #(plan.reasons or {}) == 0 then counted = false end
    end
    if not counted or progress then
        g.blocked = false
        return false
    end
    if g.blocked then
        g.blocked = false
        return true
    end
    g.blocked = true
    return false
end

local function isAIActive(sprayer)
    local root = sprayer and sprayer.rootVehicle or sprayer
    local v = root or sprayer
    if v ~= nil and type(v.getIsAIActive) == "function" then
        local ok, a = pcall(v.getIsAIActive, v)
        if ok and a then return true end
    end
    return false
end

local function primaryProgress(sprayer)
    local sm = sprayer.spec_sowingMachine
    if sm ~= nil and sm.workAreaParameters ~= nil and (sm.workAreaParameters.lastChangedArea or 0) > 0 then return true end
    local cu = sprayer.spec_cultivator
    if cu ~= nil and cu.workAreaParameters ~= nil and (cu.workAreaParameters.lastChangedArea or 0) > 0 then return true end
    return false
end

--- Finish a cycle that put no target nutrient down: refused, priming, held, zero
--- dose, or a dose that native never processed. Anchors, guard, result.
function TA:finishWithoutCredit(sprayer, cycle)
    local st = self.states[sprayer]
    if st == nil then return end
    local plan = cycle.committed
    if plan.primeLine ~= nil and plan.geometry ~= nil then
        local pc = plan.primeCaches or {}
        st.hold = { anchor = plan.primeLine, fillType = plan.fillType, areaKey = plan.geometry.areaKey,
                    width = plan.geometry.width, predSum = 0, cellCount = pc.cellCount or 0,
                    cells = pc.cells or {}, access = pc.access or {}, cropKeys = pc.cropKeys or {} }
    elseif plan.clearAnchor then
        st.hold = nil
    elseif plan.hold then
        if cycle.processed and st.hold ~= nil then
            st.hold.predSum = (st.hold.predSum or 0) + (plan.predThis or 0)
        end
    elseif plan.dose and not cycle.processed then
        st.hold = nil
    elseif plan.dose == false and plan.quote == 0 and plan.verts ~= nil and plan.pixels ~= nil then
        -- an accepted zero dose: the footprint needed nothing this blend can give
        self:advanceAnchor(st, plan)
    end

    local stop = false
    if isAIActive(sprayer) then
        stop = self:updateGuard(st, sprayer, plan, primaryProgress(sprayer))
    else
        st.guard.blocked = false
    end

    if plan.dose == false and plan.quote == 0 and plan.pixels ~= nil then
        self:setResult(st, plan, self:classify(plan, 0, nil, true))
    else
        self:setResult(st, plan, nil)
    end
    if stop then self:stopHelper(sprayer, plan) end
end

function TA:advanceAnchor(st, plan)
    if st.hold == nil then return end
    st.hold.anchor = plan.geometry.line
    st.hold.predSum = 0
    -- ground does not change under a pass: classified cells stay cached across
    -- closures (the native paint polygon overlaps the next quad), bounded in size
    if (st.hold.cellCount or 0) > TA.CELL_CACHE_LIMIT then
        st.hold.cells = {}
        st.hold.cellCount = 0
    end
end

--- Classify an accepted footprint after its modelled write. `perNutrient` is nil
--- for a zero dose (no write).
function TA:classify(plan, litres, perNutrient, zeroDose)
    local flags, reasons, nutrients = {}, {}, {}
    local allReached = true
    local bounds = carrierBounds()
    local fullDose = (plan.quote or 0) >= (plan.target or 0) - 1e-9
    for _, n in ipairs(C.NUTRIENTS) do
        local win = plan.windows[n]
        local rec = perNutrient and perNutrient[n] or { requested = 0, useful = 0, raw = 0, ok = true }
        local cap = bounds[n] and bounds[n].max or math.huge
        local post = math.min(cap, plan.readings[n] + (rec.useful or 0))
        local postRequested = math.min(cap, plan.readings[n] + (rec.requested or 0))
        local rel, dist, width = C.relationship(post, win)
        nutrients[n] = {
            reading = plan.readings[n], after = post, lower = win.lower, upper = win.upper,
            relationship = rel, approachingDistance = dist, approachingWidth = width,
            knowledgeState = C.KNOWLEDGE.KNOWN,
            requestedDelta = rec.requested, usefulDelta = rec.useful,
        }
        if post < win.lower then
            allReached = false
            if postRequested >= win.lower then
                -- the requested delta reached the window and its quantized write did
                -- not: reported, never banked (DESIGN-CHECK row 71, option (a))
                flags.SHORT_QUANTIZED = true
            elseif fullDose then
                -- the whole binding dose went down and this nutrient is still short:
                -- the blend cannot raise it without overshooting its binding nutrient
                flags.SHORT_BINDING = true
            end
        end
    end
    if allReached then
        flags.REACHED = true
    elseif not fullDose then
        if plan.limits and plan.limits.supply then flags.SHORT_SUPPLY = true end
        if plan.limits and plan.limits.hardware then flags.SHORT_HARDWARE = true end
        if not (flags.SHORT_SUPPLY or flags.SHORT_HARDWARE or flags.SHORT_QUANTIZED) then
            flags.SHORT_HARDWARE = true
        end
    end
    local state = C.displayState(flags)
    for _, s in ipairs(C.PRECEDENCE) do
        if flags[s] and s ~= state then reasons[#reasons + 1] = s end
    end
    return { state = state, reasons = reasons, nutrients = nutrients, flags = flags }
end

--- Commit an accepted dose after the consequence path ran with the actual litres.
---@param consequenceOk boolean the existing path's result (onFertilizerApplied == true)
function TA:commit(sprayer, cycle, consequenceOk)
    if cycle == nil or cycle.commitStarted then return end
    cycle.commitStarted = true
    local st = self.states[sprayer]
    if st == nil then return end
    local ok, err = pcall(self.commitInner, self, sprayer, st, cycle, consequenceOk)
    if not ok then
        -- product was spent: a writer or classification that throws is a failure,
        -- never a silent success and never a re-dose on the next cycle
        logDebug("[SF-73] commit failed: %s", tostring(err))
        pcall(self.fail, self, sprayer, st, cycle.committed, cycle.physical or 0, nil, false)
    end
end

function TA:commitInner(sprayer, st, cycle, consequenceOk)
    local plan = cycle.committed
    local litres = cycle.physical or 0
    if isAIActive(sprayer) then st.guard.blocked = false end

    if cycle.short or not consequenceOk then
        self:fail(sprayer, st, plan, litres, nil, false)
        return
    end
    local perNutrient, ok, partial = self:writeFootprint(plan, litres)
    if not ok then
        self:fail(sprayer, st, plan, litres, perNutrient, partial)
        return
    end
    self:advanceAnchor(st, plan)
    local cls = self:classify(plan, litres, perNutrient, false)
    cls.physical = litres
    cls.agronomic = self:agronomicLitres(plan, perNutrient)
    self:setResult(st, plan, cls)
end

--- The useful credited quantity in litres, from the binding nutrient's useful write.
function TA:agronomicLitres(plan, perNutrient)
    local n = plan.binding
    if n == nil or perNutrient == nil or perNutrient[n] == nil then return nil end
    local useful = perNutrient[n].useful or 0
    if useful <= 0 then return 0 end
    return C.litresFor(useful, plan.acceptedHa, plan.coefs[n], plan.unitFactor, plan.rr, plan.tuning)
end

--- APPLICATION_FAILED: the physical consequences stay, the local N/P/K result is
--- partial or unavailable, target automatic stops and forgets its plan and anchor,
--- and the farmer is told product was spent. No retry, no refund, no repair pass.
function TA:fail(sprayer, st, plan, litres, perNutrient, partial)
    -- Stop first, so the recorded result is the inactive final one.
    self:stopTargetMode(sprayer)
    st.hold = nil
    local nutrients = {}
    for _, n in ipairs(C.NUTRIENTS) do
        local rec = perNutrient and perNutrient[n]
        local knowledge = C.KNOWLEDGE.UNAVAILABLE
        if partial and rec ~= nil and rec.ok and (rec.raw or 0) ~= 0 then knowledge = C.KNOWLEDGE.PARTIAL end
        nutrients[n] = {
            reading = plan.readings and plan.readings[n] or nil,
            lower = plan.windows and plan.windows[n] and plan.windows[n].lower or nil,
            upper = plan.windows and plan.windows[n] and plan.windows[n].upper or nil,
            relationship = C.REL.UNDETERMINED, knowledgeState = knowledge,
            requestedDelta = rec and rec.requested or nil, usefulDelta = nil,
        }
    end
    self:setResult(st, plan, {
        state = C.STATE.APPLICATION_FAILED, reasons = {}, nutrients = nutrients,
        physical = litres, agronomic = nil, flags = { APPLICATION_FAILED = true },
    })
    self:notifyFailure(plan)
end

function TA:notifyFailure(plan)
    local ss = self.soilSystem
    if ss == nil or type(ss.showNotification) ~= "function" or g_i18n == nil then return end
    pcall(function()
        ss:showNotification(g_i18n:getText("sf_target_failed_title"),
            string.format(g_i18n:getText("sf_target_failed_body"), plan.fieldId or 0))
    end)
end

--- Stop target automatic for this vehicle on every peer (the mode is AUTO).
function TA:stopTargetMode(sprayer)
    local sfm = g_SoilFertilityManager
    local rm = sfm and sfm.sprayerRateManager
    if rm == nil then return end
    local vid = rateVehicleId(sprayer)
    rm:setAutoMode(vid, false)
    local st = self.states[sprayer]
    if st ~= nil then st.active = false; st.cycle = nil end
    if g_server ~= nil and SoilSprayerAutoModeEvent ~= nil and NetworkUtil ~= nil then
        local vehicle = (sprayer.rootVehicle ~= nil and sprayer.rootVehicle ~= sprayer) and sprayer.rootVehicle or sprayer
        local ok, netId = pcall(NetworkUtil.getObjectId, vehicle)
        if ok and netId ~= nil then
            pcall(function() g_server:broadcastEvent(SoilSprayerAutoModeEvent.new(netId, false)) end)
        end
    end
end

-- ── the AI boundary stop ────────────────────────────────────────────────────

SoilTargetBoundaryAIMessage = SoilTargetBoundaryAIMessage or {}
local SoilTargetBoundaryAIMessage_mt = nil

--- The class metatable, made once AIMessage exists (the engine's own shape,
--- AIMessageErrorUnknown.lua:1-6: Class(child, AIMessage), new through AIMessage.new).
local function boundaryMessageMt()
    if SoilTargetBoundaryAIMessage_mt == nil and AIMessage ~= nil then
        SoilTargetBoundaryAIMessage_mt = Class(SoilTargetBoundaryAIMessage, AIMessage)
    end
    return SoilTargetBoundaryAIMessage_mt
end

function SoilTargetBoundaryAIMessage.new(customMt)
    local mt = customMt or boundaryMessageMt()
    if AIMessage == nil or mt == nil then return nil end
    return AIMessage.new(mt)
end

function SoilTargetBoundaryAIMessage:getI18NText()
    return g_i18n:getText("sf_target_ai_boundary")
end

--- Register the Soil boundary message class on THIS peer. Called on every peer
--- after the mission's AIMessageManager:loadMapData, in the same place each time,
--- because AIJobStopEvent sends the class index (AIMessageManager.lua:76-107).
function TA:registerAIMessage()
    self.aiMessageClass = nil
    local mgr = g_currentMission and g_currentMission.aiMessageManager
    if mgr == nil or type(mgr.registerMessage) ~= "function" or boundaryMessageMt() == nil then return false end
    if type(mgr.getMessageIndex) == "function" then
        local okIdx, idx = pcall(mgr.getMessageIndex, mgr, SoilTargetBoundaryAIMessage.new())
        if okIdx and idx ~= nil then
            self.aiMessageClass = SoilTargetBoundaryAIMessage
            return true
        end
    end
    local ok, entry = pcall(mgr.registerMessage, mgr, TA.AI_MESSAGE_NAME, SoilTargetBoundaryAIMessage)
    if ok and entry ~= nil then
        self.aiMessageClass = SoilTargetBoundaryAIMessage
        return true
    end
    return false
end

function TA:stopHelper(sprayer, plan)
    local root = sprayer.rootVehicle or sprayer
    if root == nil or type(root.stopCurrentAIJob) ~= "function" then return end
    local message
    if self.aiMessageClass ~= nil then
        message = self.aiMessageClass.new()
    elseif AIMessageErrorUnknown ~= nil then
        -- registration failed: the native registered class, and the host reason shown
        message = AIMessageErrorUnknown.new()
        local ss = self.soilSystem
        if ss ~= nil and type(ss.showNotification) == "function" then
            pcall(function()
                ss:showNotification(g_i18n:getText("sf_target_failed_title"), g_i18n:getText("sf_target_ai_boundary_host"))
            end)
        end
    end
    if message == nil then return end
    pcall(function() root:stopCurrentAIJob(message) end)
    local st = self.states[sprayer]
    if st ~= nil then st.hold = nil end
end

-- ── the result ──────────────────────────────────────────────────────────────

--- Assemble and store this cycle's result. `cls` is nil for a refusal / priming /
--- hold (no footprint outcome).
function TA:setResult(st, plan, cls)
    local grain
    local vm = self.soilSystem and self.soilSystem.valueMaps
    if vm ~= nil and type(vm.getGrainMetres) == "function" then grain = vm:getGrainMetres() end
    local r = {
        schema = C.SCHEMA, epoch = st.epoch, sequence = st.sequence, active = st.active,
        scope = C.SCOPE.FOOTPRINT, quality = C.QUALITY.ANALYSIS,
        productFillType = plan.fillType, productName = plan.fillTypeName,
        cropFruitIndex = nil, cropKey = nil, fieldId = nil,
        grainMetres = grain, knowledgeState = C.KNOWLEDGE.UNAVAILABLE,
        nutrients = {}, binding = nil,
        doseState = nil, reasons = {},
        plannedLitres = nil, physicalLitres = nil, agronomicLitres = nil, continuationLitres = nil,
    }
    if cls ~= nil then
        r.cropFruitIndex, r.cropKey, r.fieldId = plan.fruitIndex, plan.cropKey, plan.fieldId
        r.nutrients = cls.nutrients
        r.binding = plan.binding
        r.doseState = cls.state
        for _, x in ipairs(cls.reasons or {}) do r.reasons[#r.reasons + 1] = x end
        r.plannedLitres = plan.quote
        r.physicalLitres = cls.physical or 0
        r.agronomicLitres = cls.agronomic
        r.knowledgeState = C.KNOWLEDGE.KNOWN
        for _, n in ipairs(C.NUTRIENTS) do
            local ks = cls.nutrients[n] and cls.nutrients[n].knowledgeState
            if ks ~= C.KNOWLEDGE.KNOWN then r.knowledgeState = ks or C.KNOWLEDGE.UNAVAILABLE end
        end
    else
        r.doseState = plan.state or (plan.hold and C.STATE.INACTIVE) or C.STATE.UNDETERMINED
        for _, x in ipairs(plan.reasons or {}) do r.reasons[#r.reasons + 1] = x end
        r.plannedLitres = 0
        r.physicalLitres = 0
        if plan.fieldId ~= nil then
            r.cropFruitIndex, r.cropKey, r.fieldId = plan.fruitIndex, plan.cropKey, plan.fieldId
        end
    end
    -- the sequence advances once per stored result
    local nextSeq = C.seqNext(st.sequence)
    if nextSeq == nil then
        self:activate(st)
        nextSeq = "1"
    end
    st.sequence = nextSeq
    r.sequence = nextSeq
    r.epoch = st.epoch
    local failed = st.result ~= nil and st.result.doseState == C.STATE.APPLICATION_FAILED
    local changed = st.result == nil or st.result.doseState ~= r.doseState
    st.result = r
    self:publish(st, changed or failed or r.doseState == C.STATE.APPLICATION_FAILED)
end

--- Send the result to clients at the presentation cadence, or at once on a change.
function TA:publish(st, force)
    if g_server == nil or st.result == nil then return end
    local t = now()
    if not force and st.lastSentAt ~= nil and (t - st.lastSentAt) < TA.RESULT_INTERVAL_MS then
        st.pendingSend = true
        return
    end
    st.lastSentAt = t
    st.pendingSend = false
    local mission = g_currentMission
    local multiplayer = mission and mission.missionDynamicInfo and mission.missionDynamicInfo.isMultiplayer
    if not multiplayer or SoilApplicationTargetResultEvent == nil or NetworkUtil == nil then return end
    local ok, netId = pcall(NetworkUtil.getObjectId, st.vehicle)
    if not ok or netId == nil then return end
    pcall(function()
        g_server:broadcastEvent(SoilApplicationTargetResultEvent.new(netId, st.result))
    end)
end

--- Flush results held back by the cadence and drop deleted vehicles (called from
--- the soil system update). A deleted object's record never outlives it.
function TA:update()
    for vehicle in pairs(self.client) do
        if type(vehicle) ~= "table" or vehicle.isDeleted == true then self.client[vehicle] = nil end
    end
    if g_server == nil then return end
    local t = now()
    for vehicle, st in pairs(self.states) do
        if type(vehicle) ~= "table" or vehicle.isDeleted == true then
            self.states[vehicle] = nil
        elseif st.pendingSend and st.lastSentAt ~= nil and (t - st.lastSentAt) >= TA.RESULT_INTERVAL_MS then
            self:publish(st, true)
        end
    end
end

--- A client receives a confirmed server result. Drops a prior epoch and anything
--- not strictly newer; a new epoch replaces the old current result.
function TA:receive(vehicle, result)
    if vehicle == nil or type(result) ~= "table" or result.schema ~= C.SCHEMA then return false end
    local old = self.client[vehicle]
    if old ~= nil and old.epoch == result.epoch and not C.seqGreater(result.sequence, old.sequence) then
        return false
    end
    if old ~= nil and old.epoch ~= result.epoch and old.epochSerial ~= nil
       and tonumber(result.epoch) ~= nil and tonumber(result.epoch) < old.epochSerial then
        return false
    end
    self.client[vehicle] = {
        epoch = result.epoch, epochSerial = tonumber(result.epoch), sequence = result.sequence,
        receivedAt = now(), result = C.copy(result),
    }
    return true
end

-- ── the two read contracts ──────────────────────────────────────────────────

--- getApplicationTargetResult(vehicle): a copy of the machine-pass answer, or nil
--- when there is none (unavailable, never a zero success). On a client, an active
--- result older than two display intervals has expired.
function TA:getApplicationTargetResult(vehicle)
    if vehicle == nil then return nil end
    if g_server ~= nil then
        local st = self.states[vehicle]
        if st == nil or st.result == nil then return nil end
        return C.copy(st.result)
    end
    local c = self.client[vehicle]
    if c == nil or c.result == nil then return nil end
    if c.result.active ~= false and (now() - c.receivedAt) >= TA.RESULT_EXPIRY_MS then return nil end
    return C.copy(c.result)
end

--- The crop for a field report: the live fruit at the engine field's centre, else
--- the just-sown crop. Never the harvested last crop (the getFieldInfo read order,
--- SoilFertilitySystem:getFieldInfo, without its lastCrop fallback).
function TA:fieldCropKey(fieldId, field)
    local name = nil
    local fsField = g_fieldManager and g_fieldManager.farmlandIdFieldMapping
        and g_fieldManager.farmlandIdFieldMapping[fieldId] or nil
    if fsField ~= nil and fsField.posX ~= nil and FieldState ~= nil then
        local ok, fs = pcall(function()
            local s = FieldState.new()
            s:update(fsField.posX, fsField.posZ)
            return s
        end)
        if ok and fs ~= nil and fs.fruitTypeIndex ~= nil and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
            local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fs.fruitTypeIndex)
            name = desc and desc.name or nil
        end
    end
    if name == nil and field ~= nil and type(field.sownCrop) == "string" and field.sownCrop ~= "" then
        name = field.sownCrop
    end
    if name == nil then return nil end
    return C.resolveCropKey(name, SoilConstants.CROP_NUTRIENT_TARGETS,
        SoilConstants.PERENNIAL_FORAGE_NAMES, SoilConstants.SF73_CROP_ALIASES)
end

--- getCropNutrientRelationship(fieldId, x, z): FIELD_REPORT from the field
--- scalars without coordinates; strict LOCAL map truth with them.
function TA:getCropNutrientRelationship(fieldId, x, z)
    local ss = self.soilSystem
    if ss == nil or type(fieldId) ~= "number" or fieldId <= 0 then return nil end
    local field = ss.fieldData and ss.fieldData[fieldId]
    if field == nil then return nil end
    local isLocal = type(x) == "number" and type(z) == "number"
    local out = {
        schema = C.SCHEMA, fieldId = fieldId,
        scope = isLocal and C.SCOPE.LOCAL or C.SCOPE.FIELD_REPORT,
        quality = isLocal and C.QUALITY.TRUTH or C.QUALITY.ANALYSIS,
        cropKey = nil, nutrients = {},
    }
    local cropKey
    if isLocal then
        local env = TA.ENGINE or F.ENGINE
        local fruit = env.fruitAt(x, z)
        local desc = fruit and fruit ~= 0 and env.fruitDesc(fruit) or nil
        cropKey = desc and self:cropKeyForDesc(desc) or nil
    else
        cropKey = self:fieldCropKey(fieldId, field)
    end
    out.cropKey = cropKey
    local entry = cropKey and SoilConstants.CROP_NUTRIENT_TARGETS[cropKey] or nil
    local wins = entry and C.cropWindows(entry, carrierBounds()) or nil
    local vm = ss.valueMaps
    local grain = (isLocal and vm ~= nil and vm.available and type(vm.getGrainMetres) == "function")
        and vm:getGrainMetres() or nil
    for _, n in ipairs(C.NUTRIENTS) do
        local value, knowledge, g = nil, C.KNOWLEDGE.UNAVAILABLE, nil
        if isLocal then
            if vm ~= nil and type(vm.readValueAtWorld) == "function" then
                value = vm:readValueAtWorld(C.LAYER_KEY[n], x, z)
            end
            if value ~= nil and grain ~= nil and grain > 0 then
                knowledge, g = C.KNOWLEDGE.KNOWN, grain
            else
                value = nil
            end
        else
            local scalar = field[C.LAYER_KEY[n]]
            if C.finite(scalar) then value, knowledge = scalar, C.KNOWLEDGE.KNOWN end
        end
        local win = wins and wins[n] or nil
        local rel, dist, width = C.REL.UNDETERMINED, nil, nil
        if value ~= nil and win ~= nil then rel, dist, width = C.relationship(value, win) end
        out.nutrients[n] = {
            value = value, lower = win and win.lower or nil, upper = win and win.upper or nil,
            relationship = rel, approachingDistance = dist, approachingWidth = width,
            knowledgeState = knowledge, grainMetres = g,
        }
    end
    return out
end

-- ── the field baseline (sf73UnknownNPK) ─────────────────────────────────────

local function validBaseline(b)
    if type(b) ~= "table" then return false end
    for _, n in ipairs(C.NUTRIENTS) do
        local v = b[n]
        if not C.finite(v) or v < 0 or v > 100 then return false end
    end
    return true
end
TA.validBaseline = validBaseline

--- Freeze a field's baseline once, from a legitimate initial or loaded scalar
--- before SF-73 changes it. A field whose marked save had no valid baseline is
--- UNAVAILABLE and never re-freezes from a later report.
function TA.freezeBaseline(field)
    if type(field) ~= "table" or field._sf73BaselineUnavailable then return false end
    if validBaseline(field._sf73Baseline) then return false end
    local b = { N = field.nitrogen, P = field.phosphorus, K = field.potassium }
    if not validBaseline(b) then return false end
    field._sf73Baseline = b
    return true
end

--- The load rule, shared by both save paths: an unmarked save freezes from its own
--- loaded scalars; a marked save takes only a valid stored baseline.
function TA.applyLoadedBaseline(field, marked, stored)
    if type(field) ~= "table" then return end
    field._sf73Baseline = nil
    field._sf73BaselineUnavailable = nil
    if marked then
        if validBaseline(stored) then
            field._sf73Baseline = { N = stored.N, P = stored.P, K = stored.K }
        else
            field._sf73BaselineUnavailable = true
        end
        return
    end
    TA.freezeBaseline(field)
end

--- Initialize only raw-zero N/P/K cells of an accepted footprint from the field's
--- frozen baseline. Written pixels outrank it.
function TA:initializeRawZero(fieldId, field, verts)
    if field == nil then return false end
    if not validBaseline(field._sf73Baseline) then TA.freezeBaseline(field) end
    local b = field._sf73Baseline
    if not validBaseline(b) then return false end
    local vm = self.soilSystem.valueMaps
    local all = true
    for _, n in ipairs(C.NUTRIENTS) do
        local key = C.LAYER_KEY[n]
        local raw = vm:encodeForLayer(key, b[n])
        if raw == nil or not vm:setPolygonWhere(key, verts, raw, 0, 0) then all = false end
    end
    return all
end
