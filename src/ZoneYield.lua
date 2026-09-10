-- ============================================================
-- ZoneYield.lua  (SF-14, One Ground conformance)
--
-- THE PAYOUT HALF OF THE SF-2M MODULATION FAMILY. Yield varies per
-- cell because conditions during growth varied, and that variation
-- is captured at the moment the conditions were real (growth time),
-- never recomputed live at harvest. A healthy strip fills the
-- combine faster and a weak strip slower, and the captured result
-- follows the exact field polygon and fruit that grew it.
--
-- WHAT CHANGED IN THE ONE GROUND CONFORMANCE (SF-14-FIX amendment):
--   The retired first-field 8 m / 600-point adaptive lattice and the
--   farmland-wide crop identity are gone. Capture now consumes one
--   immutable complete SF-52 eligible-region plan per farmland and
--   enumerates the ACTUAL standing fruit in each provider-owned
--   region; receipts are keyed by
--   (farmlandId, sourcePolygonFingerprint, fruitTypeIndex) with the
--   PENDING / READY / FROZEN_SPATIAL / FROZEN_FALLBACK statuses and
--   persist as bounded metadata in the existing soilData block. The
--   dense truth is still the `yieldEfficiency` value-map layer.
--   Jobs advance under a positive measured budget from the manager
--   update path; a zero budget leaves them PENDING. The harvest read
--   keeps the native fruit-filtered parallelogram read and a rotated,
--   bounded drag lattice. The four Cutter wrapper surfaces stay; the
--   SowingMachine work-area door clears only matching receipts. No
--   new grid, map, transport or control. Native fruit-plane writes,
--   polygon clipping, engine sync, real save bytes and frame time
--   remain in-game proof (release LOCKED).
-- ============================================================

ZoneYield = ZoneYield or {}
local ZoneYield_mt = Class(ZoneYield)

-- ── THE EFFICIENCY BAND (absolute captured-efficiency rail) ──
-- AWAITING-SPINE: a tunable magnitude with no dial today; the
-- Option-Scaling deviation resolver changes contrast AROUND the
-- farmland baseline, never the band itself.
ZoneYield.BAND_FLOOR   = 0.7
ZoneYield.BAND_CEILING = 1.15

-- Engine fruit index limit: six bits of the receipt roster.
ZoneYield.FRUIT_MAX = 63

-- Drag lattice: a deterministic subdivision of the true rotated
-- parallelogram under a 256-candidate ceiling. Each candidate
-- performs one native fruit-area weight query, one yield read and at
-- most one traffic-drag read.
ZoneYield.DRAG_MAX_CANDIDATES = 256

-- Capture write radius as a fraction of the plan execution grain.
ZoneYield.WRITE_RADIUS_FACTOR = 0.5
-- Post-read tolerance for the retained written proof (semantic percent).
ZoneYield.WRITE_TOLERANCE = 0.5

-- Job pump: bounded region operations advanced per manager update.
ZoneYield.JOB_OPS_PER_UPDATE = 96

-- Receipt statuses (brief 3.2).
ZoneYield.STATUS_PENDING         = 'PENDING'
ZoneYield.STATUS_READY           = 'READY'
ZoneYield.STATUS_FROZEN_SPATIAL  = 'FROZEN_SPATIAL'
ZoneYield.STATUS_FROZEN_FALLBACK = 'FROZEN_FALLBACK'

-- Capability routes (brief 3.4). Admission is descriptor and route
-- based, never crop-name based.
ZoneYield.ROUTE_STANDARD  = 'CUTTER_STANDARD'
ZoneYield.ROUTE_FORAGE    = 'CUTTER_FORAGE'
ZoneYield.ROUTE_REGROWING = 'CUTTER_REGROWING'
ZoneYield.ROUTE_SCALAR    = 'SCALAR_ONLY'

-- Capture-layer availability (brief 3.5).
ZoneYield.LAYER_READY       = 'READY'
ZoneYield.LAYER_UNAVAILABLE = 'UNAVAILABLE'

-- The Agronomy deviation declaration (dial = agronomy, base 1,
-- neutral 1, clamp 0.5..1.5, curve at0=0.5, at1=1, at2=1.5, ease 1).
-- Read through the vendored OptionScalingResolver contract; the curve
-- is data for the resolver, never read here.
ZoneYield.VARIATION_DECLARATION = {
    dial     = "agronomy",
    base     = 1,
    neutral  = 1,
    clampMin = 0.5,
    clampMax = 1.5,
    curve    = { at0 = 0.5, at1 = 1, at2 = 1.5, ease = 1 },
}

function ZoneYield.new(manager)
    local self = setmetatable({}, ZoneYield_mt)
    self.manager = manager
    self.isInitialized = false
    -- (fruitTypeIndex, allowsForageGrowthState) -> DensityMapFilter
    self._fruitFilterCache = {}
    -- farmlandId -> fruitTypeIndex last contract-refreshed for
    self._contractRefreshed = {}
    -- (farmlandId|polygonFingerprint|fruit) -> durable receipt
    self._receipts = {}
    -- (farmlandId|fruit) -> contract fallback scalar
    self._fallbacks = {}
    -- Ordered pending farmland capture jobs (never persisted).
    self._queue = {}
    -- farmlandId -> true while a loaded receipt awaits current-session
    -- validation (fruit roster + polygon geometry).
    self._pendingValidation = {}
    self._captureGeneration = 0
    self._layerState = ZoneYield.LAYER_READY
    return self
end

function ZoneYield:initialize()
    self.isInitialized = true
    self:_classifyLayer()
end

function ZoneYield:delete()
    self.isInitialized = false
    -- ZoneYield owns no independent growth subscription; the manager owns the
    -- single family callback pair and unsubscribes it. Perform no density write.
    self._fruitFilterCache = {}
    self._contractRefreshed = {}
    self._receipts = {}
    self._fallbacks = {}
    self._queue = {}
    self._pendingValidation = {}
    self._captureGeneration = 0
    self._layerState = ZoneYield.LAYER_READY
end

-- ============================================================
-- PURE KERNEL (the fixed contract; driven directly by the bar).
-- These statics mirror the SF-14 SDS reference models exactly so the
-- offline bar guards the shipped arithmetic, not a private copy.
-- ============================================================

--- The captured scalar (brief 3.7):
---   captured = clamp(baseline + (localRaw - baseline) * variationScale, 0.70, 1.15)
--- A neutral variationScale (1) returns localRaw exactly, so a uniform
--- field, where localRaw == baseline, reconciles with the existing
--- result by construction. Missing inputs fall back to the neutral.
--- @return number
function ZoneYield.capturedScalar(farmlandBaseline, localRaw, variationScale)
    local base = (type(farmlandBaseline) == 'number') and farmlandBaseline or 1.0
    local raw  = (type(localRaw) == 'number') and localRaw or base
    local s    = (type(variationScale) == 'number') and variationScale or 1.0
    local captured = base + (raw - base) * s
    if captured < ZoneYield.BAND_FLOOR then captured = ZoneYield.BAND_FLOOR end
    if captured > ZoneYield.BAND_CEILING then captured = ZoneYield.BAND_CEILING end
    return captured
end

--- The resolved Agronomy deviation scale (brief 3.7). Absent, switched-off or
--- invalid Option Scaling is the declared neutral 1.
--- @return number
function ZoneYield.effectiveVariationScale(profile)
    local declaration = ZoneYield.VARIATION_DECLARATION
    local scale = declaration.neutral
    if OptionScalingResolver ~= nil and type(OptionScalingResolver.resolve) == 'function' then
        local ok, resolved = pcall(OptionScalingResolver.resolve, declaration, profile)
        if ok and type(resolved) == 'number' then scale = resolved end
    end
    if scale < declaration.clampMin then scale = declaration.clampMin end
    if scale > declaration.clampMax then scale = declaration.clampMax end
    return scale
end

--- Descriptor/route admission (brief 3.4). Requires valid terrain data plane,
--- start channel and state-channel count, a positive cutState, a positive
--- growth-state count, and an ordered positive harvest range. A regrowing crop
--- with a valid firstRegrowthState joins as CUTTER_REGROWING; a crop whose
--- standard range is invalid but whose forage range is valid joins as
--- CUTTER_FORAGE. Everything else is SCALAR_ONLY.
--- @param desc table|nil FruitTypeDesc
--- @return string route
function ZoneYield.classifyCapability(desc)
    if type(desc) ~= 'table' then return ZoneYield.ROUTE_SCALAR end
    if type(desc.terrainDataPlaneId) ~= 'number' then return ZoneYield.ROUTE_SCALAR end
    if type(desc.startStateChannel) ~= 'number' then return ZoneYield.ROUTE_SCALAR end
    if type(desc.numStateChannels) ~= 'number' or desc.numStateChannels <= 0 then
        return ZoneYield.ROUTE_SCALAR
    end
    if type(desc.cutState) ~= 'number' or desc.cutState <= 0 then return ZoneYield.ROUTE_SCALAR end
    if type(desc.numGrowthStates) ~= 'number' or desc.numGrowthStates <= 0 then
        return ZoneYield.ROUTE_SCALAR
    end

    local minH, maxH = desc.minHarvestingGrowthState, desc.maxHarvestingGrowthState
    local standardOk = type(minH) == 'number' and type(maxH) == 'number'
        and minH > 0 and maxH > minH
    local minF = desc.minForageGrowthState
    local forageOk = type(minF) == 'number' and minF > 0

    if desc.regrows == true then
        if type(desc.firstRegrowthState) ~= 'number' or desc.firstRegrowthState <= 0 then
            return ZoneYield.ROUTE_SCALAR
        end
        if standardOk or forageOk then return ZoneYield.ROUTE_REGROWING end
        return ZoneYield.ROUTE_SCALAR
    end
    if standardOk then return ZoneYield.ROUTE_STANDARD end
    if forageOk then return ZoneYield.ROUTE_FORAGE end
    return ZoneYield.ROUTE_SCALAR
end

--- True when a spatial route uses the forage lower bound rather than the
--- standard one. A regrowing crop still carries its own route.
--- @return boolean
function ZoneYield.isForageRoute(desc, route)
    if route == ZoneYield.ROUTE_FORAGE then return true end
    if route ~= ZoneYield.ROUTE_REGROWING then return false end
    local minH = desc and desc.minHarvestingGrowthState
    local standardOk = type(minH) == 'number' and minH > 0
    return not standardOk and type(desc.minForageGrowthState) == 'number'
        and desc.minForageGrowthState > 0
end

--- True when a descriptor is a valid regrowing crop (brief 3.4).
--- @return boolean
function ZoneYield.isRegrowing(desc)
    return type(desc) == 'table' and desc.regrows == true
        and type(desc.firstRegrowthState) == 'number' and desc.firstRegrowthState > 0
end

--- The two-part regrowth thaw test (brief 3.4): a frozen regrowing receipt
--- thaws only when the old harvestable area over its stored route is zero AND
--- the same polygon reports positive area at firstRegrowthState. Either fact
--- alone is insufficient; partial harvest stays frozen.
--- @return boolean
function ZoneYield.regrowthThawed(oldHarvestableArea, regrowthArea)
    if type(oldHarvestableArea) ~= 'number' or type(regrowthArea) ~= 'number' then return false end
    return oldHarvestableArea <= 0 and regrowthArea > 0
end

--- The deterministic drag subdivision of the rotated parallelogram (brief 3.8):
--- positive integer counts whose product is at most the candidate ceiling,
--- roughly proportional to the edge lengths. Never zero on either axis.
--- @return number nx
--- @return number ny
function ZoneYield.dragSubdivisions(lenU, lenV, maxCandidates)
    local cap = (type(maxCandidates) == 'number' and maxCandidates > 0)
        and math.floor(maxCandidates) or ZoneYield.DRAG_MAX_CANDIDATES
    if type(lenU) ~= 'number' or type(lenV) ~= 'number' or lenU <= 0 or lenV <= 0 then
        return 1, 1
    end
    local ratio = lenU / lenV
    local ny = math.max(1, math.floor(math.sqrt(cap / ratio)))
    local nx = math.max(1, math.floor(cap / ny))
    while nx * ny > cap and ny > 1 do
        ny = ny - 1
        nx = math.max(1, math.floor(cap / ny))
    end
    if nx * ny > cap then nx = math.max(1, math.floor(cap / ny)) end
    return nx, ny
end

--- SF-55 composition line, applied per candidate. A nil drag reads as zero,
--- leaving the captured efficiency unchanged. The drag is bounded to [0,1] and
--- may legitimately push the effective below SF-14's band floor (SF-55's own
--- domain); the captured side is guarded at the band ceiling. Pure.
--- @return number
function ZoneYield.composeDrag(captured, drag)
    if type(captured) ~= 'number' then return 1.0 end
    local d = type(drag) == 'number' and math.max(0, math.min(1, drag)) or 0
    local eff = captured * (1 - d)
    return math.max(0, math.min(ZoneYield.BAND_CEILING, eff))
end

--- SF-25's ratified area-weighted positional integral. samples is a list of
--- { value = number, area = number }. Unwritten candidates contribute no area.
--- Empty input returns nil (fall back to the field-average path), never 0.
--- @return number|nil
function ZoneYield.aggregateAreaWeighted(samples)
    local sum, area = 0.0, 0.0
    for _, s in ipairs(samples or {}) do
        if type(s) == 'table' and type(s.value) == 'number' then
            local a = type(s.area) == 'number' and s.area or 1.0
            sum = sum + s.value * a
            area = area + a
        end
    end
    if area <= 0 then return nil end
    return sum / area
end

--- The durable receipt key (brief 3.2): (farmlandId, sourcePolygonFingerprint,
--- fruitTypeIndex). Persist only observed pairs.
--- @return string
function ZoneYield.receiptKey(farmlandId, sourcePolygonFingerprint, fruitTypeIndex)
    return tostring(farmlandId) .. '|' .. tostring(sourcePolygonFingerprint)
        .. '|' .. tostring(fruitTypeIndex)
end

-- ============================================================
-- INPUTS (read-only access to the family's own data)
-- ============================================================

function ZoneYield:_soilSystem()
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and type(ss._getFarmlandPolygons) == 'function' then return ss end
    return nil
end

function ZoneYield:_valueMaps()
    local soilSystem = self.manager and self.manager.soilSystem
    local vm = soilSystem and soilSystem.valueMaps
    if vm ~= nil and vm.available then return vm end
    return nil
end

function ZoneYield:_viability()
    local v = self.manager and self.manager.viability
    if v ~= nil and type(v.getCellGrowthInfo) == 'function' then return v end
    return nil
end

--- The SF-52 provider's immutable complete plan for a farmland, or nil.
function ZoneYield:_plan(farmlandId)
    local m = self.manager
    if m == nil or type(m.getGrowthEligibleRegionPlan) ~= 'function' then return nil end
    local ok, plan = pcall(function() return m:getGrowthEligibleRegionPlan(farmlandId) end)
    if not ok then return nil end
    return plan
end

--- The current farmland+unscoped observation token, or nil.
function ZoneYield:_token(farmlandId)
    local vm = self:_valueMaps()
    if vm == nil or type(vm.getGrowthInputToken) ~= 'function' then return nil end
    local ok, token = pcall(function() return vm:getGrowthInputToken(farmlandId) end)
    if not ok then return nil end
    return token
end

--- The farmlands currently tracked by the soil system, ascending numeric order.
function ZoneYield:_currentFarmlandIds()
    local ss = self:_soilSystem()
    local ids = {}
    if ss ~= nil and ss.fieldData ~= nil then
        for farmlandId in pairs(ss.fieldData) do ids[#ids + 1] = farmlandId end
    end
    table.sort(ids)
    return ids
end

--- Server test that tolerates a bench mission without getIsServer (nil-safe).
function ZoneYield:_isServer()
    local mission = g_currentMission
    if mission ~= nil and type(mission.getIsServer) == 'function' then
        local ok, isServer = pcall(function() return mission:getIsServer() end)
        if ok then return isServer == true end
        return false
    end
    return false
end

--- The current Option-Scaling profile through the vendored readProfile contract.
function ZoneYield:_readProfile()
    if OptionScalingResolver == nil or type(OptionScalingResolver.readProfile) ~= 'function' then
        return nil
    end
    local sh = (g_currentMission ~= nil and g_currentMission.settingsHub) or nil
    if sh == nil then return nil end
    local ok, profile = pcall(OptionScalingResolver.readProfile, OptionScalingResolver, sh)
    if not ok then return nil end
    return profile
end

--- A deterministic roster fingerprint for the current fruit-type set, so a loaded
--- receipt whose numeric fruit identity may have moved is cleared (brief 3.5).
function ZoneYield:_fruitRosterFingerprint()
    local ftm = g_fruitTypeManager
    if ftm == nil or type(ftm.getFruitTypes) ~= 'function' then return '' end
    local ok, names = pcall(function()
        local out = {}
        local fruits = ftm:getFruitTypes()
        for _, ft in ipairs(fruits or {}) do
            if type(ft) == 'table' and ft.name then out[#out + 1] = ft.name end
        end
        table.sort(out)
        return out
    end)
    if not ok then return '' end
    return table.concat(names or {}, '|')
end

--- Execution grain for a plan, or nil.
function ZoneYield:_grain(plan)
    local g = plan and (plan.executionGrainMetres or plan.truthGrainMetres)
    if type(g) ~= 'number' or g <= 0 then return nil end
    return g
end

function ZoneYield:_decodeKey(key)
    if type(key) ~= 'string' then return nil end
    local gx, gz = key:match("^(-?%d+):(-?%d+)$")
    if not gx then return nil end
    return tonumber(gx), tonumber(gz)
end

--- The engine's per-cell get: FSDensityMapUtil.getFruitTypeIndexAtWorldPos
--- returns (fruitTypeIndex, growthState) in one call.
function ZoneYield:_readCellState(x, z)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= 'function' then
        return nil, nil
    end
    local ok, fruitIndex, state = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok or fruitIndex == nil or state == nil then return nil, nil end
    return state, fruitIndex
end

--- The current farmland-average raw result (the SF-52 baseline), computed through
--- the same nutrient helper, WITHOUT the legacy scalar freeze side effect.
--- @return number
function ZoneYield:_baselineRaw(fieldId, fruitTypeIndex)
    local ss = self:_soilSystem()
    if ss == nil then return 1.0 end
    local field = ss.fieldData and ss.fieldData[fieldId]
    if field == nil then return 1.0 end
    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local cropName = desc and desc.name or ""
    local ok, mod = pcall(function()
        return ss:_yieldModifierFromNutrients(field, cropName,
            field.nitrogen, field.phosphorus, field.potassium, nil)
    end)
    if ok and type(mod) == 'number' then return mod end
    return 1.0
end

--- Capture-layer availability (brief 3.5): a missing or wrong-resolution
--- `yieldEfficiency` layer makes spatial state unavailable.
function ZoneYield:_classifyLayer()
    local vm = self:_valueMaps()
    if vm == nil then
        self._layerState = ZoneYield.LAYER_UNAVAILABLE
        return self._layerState
    end
    if type(vm.resolution) == 'number' and vm.resolution <= 0 then
        self._layerState = ZoneYield.LAYER_UNAVAILABLE
        return self._layerState
    end
    self._layerState = ZoneYield.LAYER_READY
    return self._layerState
end

function ZoneYield:_layerAvailable()
    return self:_classifyLayer() == ZoneYield.LAYER_READY
end

-- ============================================================
-- THE CAPTURE JOB PUMP (brief 3.3)
-- ============================================================

--- FINISHED delivery from the manager's single growth dispatch. Runs after the
--- SF-53 spend and the SF-78 restore/cleanup. On a drained delivery it queues one
--- ordered capture job per current farmland; the manager update advances them.
function ZoneYield:onFinishedGrowthPeriod(finishedPeriod, hasPendingGrowth)
    if not self:_isServer() then return end
    if not self.isInitialized then return end
    if not self:isLive() then return end
    if hasPendingGrowth ~= false then return end
    local mission = g_currentMission
    local growthMode = mission and mission.missionInfo and mission.missionInfo.growthMode
    if growthMode == GrowthMode.DISABLED then return end
    if not self:_layerAvailable() then return end

    local vm = self:_valueMaps()
    if vm == nil then return end
    local variationScale = ZoneYield.effectiveVariationScale(self:_readProfile())

    for _, farmlandId in ipairs(self:_currentFarmlandIds()) do
        self:_queueFarmland(farmlandId, vm, variationScale)
    end
end

--- Build one farmland capture job: validate the complete current plan and token,
--- enumerate actual standing fruit per provider-owned region, thaw regrowing
--- frozen receipts, mark affected non-frozen observed receipts PENDING before any
--- write, then queue one ordered job.
function ZoneYield:_queueFarmland(farmlandId, vm, variationScale)
    local plan = self:_plan(farmlandId)
    if plan == nil or type(plan.regions) ~= 'table' or #plan.regions == 0 then return false end
    local token = self:_token(farmlandId)
    if token == nil then return false end
    if plan.farmlandInputRevision ~= token.farmlandRevision
        or plan.unscopedInputRevision ~= token.unscopedRevision then return false end
    local grain = self:_grain(plan)
    if grain == nil then return false end
    local radius = grain * ZoneYield.WRITE_RADIUS_FACTOR

    local regions = {}
    local observed = {}        -- fp -> { fruit -> true }
    local observedForage = {}  -- fp -> { fruit -> boolean }
    for _, region in ipairs(plan.regions) do
        if region.writableForFarmland == true and region.blocked ~= true then
            local gx, gz = self:_decodeKey(region.key)
            if gx ~= nil then
                local cx = gx * grain + grain * 0.5
                local cz = gz * grain + grain * 0.5
                local state, fruitIndex = self:_readCellState(cx, cz)
                if fruitIndex ~= nil and fruitIndex >= 1 and fruitIndex <= ZoneYield.FRUIT_MAX then
                    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIndex)
                    local route = ZoneYield.classifyCapability(desc)
                    if route ~= ZoneYield.ROUTE_SCALAR and state ~= nil
                        and not desc:getIsCut(state) and not desc:getIsWithered(state) then
                        local fp = region.sourcePolygonFingerprint
                        regions[#regions + 1] = {
                            key = region.key, gx = gx, gz = gz, cx = cx, cz = cz,
                            sourcePolygonFingerprint = fp,
                            fruitTypeIndex = fruitIndex,
                            route = route,
                            forageRoute = ZoneYield.isForageRoute(desc, route),
                        }
                        observed[fp] = observed[fp] or {}
                        observed[fp][fruitIndex] = true
                        observedForage[fp] = observedForage[fp] or {}
                        observedForage[fp][fruitIndex] = ZoneYield.isForageRoute(desc, route)
                    end
                end
            end
        end
    end
    if #regions == 0 then return false end

    -- Regrowth thaw test on frozen regrowing receipts (brief 3.4).
    self:_thawRegrowing(farmlandId, plan, grain)

    -- Mark every affected non-frozen observed receipt PENDING before any write.
    for fp, fruits in pairs(observed) do
        for fruit in pairs(fruits) do
            local r = self._receipts[ZoneYield.receiptKey(farmlandId, fp, fruit)]
            if r ~= nil and r.status ~= ZoneYield.STATUS_FROZEN_SPATIAL
                and r.status ~= ZoneYield.STATUS_FROZEN_FALLBACK then
                r.status = ZoneYield.STATUS_PENDING
            end
        end
    end

    -- A newer drained delivery replaces unfinished non-frozen work for this
    -- farmland; an older queued job for the same farmland is dropped.
    for i = #self._queue, 1, -1 do
        if self._queue[i].farmlandId == farmlandId then table.remove(self._queue, i) end
    end

    self._queue[#self._queue + 1] = {
        farmlandId = farmlandId,
        planContentHash = plan.planContentHash,
        carrierOwnershipHash = plan.carrierOwnershipHash,
        polygonUnionFingerprint = plan.polygonUnionFingerprint,
        farmlandInputRevision = plan.farmlandInputRevision,
        unscopedInputRevision = plan.unscopedInputRevision,
        settingsFingerprint = plan.settingsFingerprint or '',
        generation = self._captureGeneration,
        variationScale = variationScale,
        radius = radius,
        regions = regions,
        observed = observed,
        observedForage = observedForage,
        baselines = {},
        cursor = 0,
        done = false,
        failed = false,
    }
    return true
end

--- Two-part regrowth thaw over the frozen receipts of one farmland (brief 3.4).
--- A frozen regrowing receipt thaws only when the old harvestable area over its
--- stored route is zero AND the same source polygon reports positive area at
--- firstRegrowthState. A thaw drops the receipt so fresh capture can re-mint it.
function ZoneYield:_thawRegrowing(farmlandId, plan, grain)
    for key, r in pairs(self._receipts) do
        if r.farmlandId == farmlandId and r.status == ZoneYield.STATUS_FROZEN_SPATIAL then
            local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(r.fruitTypeIndex)
            if ZoneYield.isRegrowing(desc) then
                local oldArea = self:_sourceArea(plan, r.sourcePolygonFingerprint, r.fruitTypeIndex,
                    r.forageRoute == true, false)
                local regrowArea = self:_sourceArea(plan, r.sourcePolygonFingerprint, r.fruitTypeIndex,
                    false, desc.firstRegrowthState)
                if oldArea ~= nil and regrowArea ~= nil
                    and ZoneYield.regrowthThawed(oldArea, regrowArea) then
                    self._receipts[key] = nil
                end
            end
        end
    end
end

--- Sum the native fruit area over the plan regions of one source polygon, either
--- for the stored harvest route (firstState nil) or at an explicit state.
--- Returns nil when the geometry or engine read is unavailable.
function ZoneYield:_sourceArea(plan, sourcePolygonFingerprint, fruitTypeIndex, forage, firstState)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitArea) ~= 'function' then return nil end
    local grain = self:_grain(plan)
    if grain == nil then return nil end
    local total = 0
    local seen = false
    for _, region in ipairs(plan.regions) do
        if region.sourcePolygonFingerprint == sourcePolygonFingerprint then
            local gx, gz = self:_decodeKey(region.key)
            if gx ~= nil then
                local cx = gx * grain + grain * 0.5
                local cz = gz * grain + grain * 0.5
                local half = grain * 0.5
                local ok, area = pcall(function()
                    return FSDensityMapUtil.getFruitArea(fruitTypeIndex,
                        cx - half, cz - half, cx + half, cz - half, cx - half, cz + half,
                        false, forage)
                end)
                if not ok or type(area) ~= 'number' then return nil end
                total = total + area
                seen = true
            end
        end
    end
    if not seen then return nil end
    return total
end

--- Advance pending jobs under a positive measured operation budget from the
--- manager update path (brief 3.3). A zero or unavailable budget leaves the
--- queue untouched. Visits every ordered region or fails the farmland job.
--- @return number operations used
function ZoneYield:advanceJobs(budget)
    if not self.isInitialized then return 0 end
    if type(budget) ~= 'number' or budget <= 0 then return 0 end
    if not self:isLive() then return 0 end
    if not self:_isServer() then return 0 end
    local vm = self:_valueMaps()
    if vm == nil then return 0 end
    if not self:_layerAvailable() then return 0 end

    local used = 0
    while #self._queue > 0 and used < budget do
        local job = self._queue[1]
        local spent = self:_advanceJob(job, vm, budget - used)
        used = used + spent
        if job.done then table.remove(self._queue, 1) end
        if spent <= 0 then break end
    end
    return used
end

function ZoneYield:_advanceJob(job, vm, budget)
    -- Before any commit, recheck plan content, polygon union, provider revisions,
    -- settings and release state. Drift cancels the unfinished job and leaves
    -- receipts PENDING.
    if self:_jobDrifted(job) then
        job.done = true
        job.failed = true
        return 0
    end
    local spent = 0
    while job.cursor < #job.regions and spent < budget do
        job.cursor = job.cursor + 1
        spent = spent + 1
        local region = job.regions[job.cursor]
        if not self:_writeRegion(job, region, vm) then
            -- One missing N/P/K input, failed write or failed post-read fails the
            -- whole farmland job. Partial layer bytes remain unavailable.
            job.failed = true
            job.done = true
            return spent
        end
    end
    if job.cursor >= #job.regions then
        job.done = true
        if not job.failed then self:_commitJob(job) end
    end
    return spent
end

--- Recheck the job's plan identity and live state against current truth.
function ZoneYield:_jobDrifted(job)
    if not self:isLive() then return true end
    local plan = self:_plan(job.farmlandId)
    if plan == nil then return true end
    local token = self:_token(job.farmlandId)
    if token == nil then return true end
    if plan.planContentHash ~= job.planContentHash then return true end
    if plan.polygonUnionFingerprint ~= job.polygonUnionFingerprint then return true end
    if plan.farmlandInputRevision ~= job.farmlandInputRevision
        or plan.unscopedInputRevision ~= job.unscopedInputRevision then return true end
    if (plan.settingsFingerprint or '') ~= job.settingsFingerprint then return true end
    return false
end

--- Write one region: read N/P/K exactly once each, compute localRaw through the
--- same nutrient helper as the farmland baseline, resolve the captured scalar,
--- write semantic percent 70..115 to the provider footprint, and post-read it.
--- @return boolean
function ZoneYield:_writeRegion(job, region, vm)
    local ss = self:_soilSystem()
    if ss == nil then return false end
    local field = ss.fieldData and ss.fieldData[job.farmlandId]
    if field == nil then return false end
    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(region.fruitTypeIndex)
    if desc == nil then return false end
    local cropName = desc.name or ""

    local n = vm:readValueAtWorld('nitrogen', region.cx, region.cz)
    local p = vm:readValueAtWorld('phosphorus', region.cx, region.cz)
    local k = vm:readValueAtWorld('potassium', region.cx, region.cz)
    if type(n) ~= 'number' or type(p) ~= 'number' or type(k) ~= 'number' then return false end

    local ok, localRaw = pcall(function()
        return ss:_yieldModifierFromNutrients(field, cropName, n, p, k, nil)
    end)
    if not ok or type(localRaw) ~= 'number' then return false end

    local baseline = job.baselines[region.fruitTypeIndex]
    if baseline == nil then
        baseline = self:_baselineRaw(job.farmlandId, region.fruitTypeIndex)
        job.baselines[region.fruitTypeIndex] = baseline
    end
    local captured = ZoneYield.capturedScalar(baseline, localRaw, job.variationScale)
    local percent = captured * 100

    local wrote = pcall(function()
        vm:writeValueAtWorld('yieldEfficiency', region.cx, region.cz, percent, job.radius)
    end)
    if not wrote then return false end
    local back = vm:readValueAtWorld('yieldEfficiency', region.cx, region.cz)
    if type(back) ~= 'number' or math.abs(back - percent) > ZoneYield.WRITE_TOLERANCE then
        return false
    end
    return true
end

--- Publish one complete generation: every observed (polygon, fruit) pair becomes
--- READY with the plan identity the job observed (brief 3.3/3.5).
function ZoneYield:_commitJob(job)
    for fp, fruits in pairs(job.observed or {}) do
        for fruit in pairs(fruits) do
            local key = ZoneYield.receiptKey(job.farmlandId, fp, fruit)
            local r = self._receipts[key]
            if r == nil then
                r = { farmlandId = job.farmlandId, sourcePolygonFingerprint = fp, fruitTypeIndex = fruit }
                self._receipts[key] = r
            end
            r.status = ZoneYield.STATUS_READY
            r.captureGeneration = job.generation
            r.planContentHash = job.planContentHash
            r.carrierOwnershipHash = job.carrierOwnershipHash
            r.polygonUnionFingerprint = job.polygonUnionFingerprint
            r.settingsFingerprint = job.settingsFingerprint
            r.forageRoute = (job.observedForage[fp] and job.observedForage[fp][fruit]) or false
            r.fallbackScalar = nil
        end
    end
    self._captureGeneration = self._captureGeneration + 1
end

-- ============================================================
-- THE FRUIT FILTER CACHE (harvest-state DensityMapFilter)
-- ============================================================

--- Build (and cache) one harvest-state DensityMapFilter per
--- (fruitTypeIndex, allowsForageGrowthState) pair. The accepted range is
--- minForageGrowthState when forage is allowed, else minHarvestingGrowthState,
--- up to maxHarvestingGrowthState.
function ZoneYield:_getFruitFilter(fruitTypeIndex, allowsForageGrowthState)
    local key = fruitTypeIndex .. ":" .. (allowsForageGrowthState and "1" or "0")
    local cached = self._fruitFilterCache[key]
    if cached ~= nil then return cached end

    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil or desc.terrainDataPlaneId == nil then return nil end

    local minState = desc.minHarvestingGrowthState
    if allowsForageGrowthState then minState = desc.minForageGrowthState end
    local maxState = desc.maxHarvestingGrowthState

    local ok, filter = pcall(function()
        local f = DensityMapFilter.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
        if DensityFilterSupersamplingMode ~= nil and DensityFilterSupersamplingMode.ALL ~= nil
           and type(f.setSupersamplingMode) == 'function' then
            f:setSupersamplingMode(DensityFilterSupersamplingMode.ALL)
        end
        f:setValueCompareParams(DensityValueCompareType.BETWEEN, minState, maxState)
        return f
    end)
    if not ok or filter == nil then return nil end

    self._fruitFilterCache[key] = filter
    return filter
end

-- ============================================================
-- THE HARVEST READ (pre-cut spatial context; brief 3.6/3.8)
-- ============================================================

--- The true parallelogram of one work area, preserved as the three corner
--- points (start, width, height) the engine uses.
function ZoneYield:_workAreaParallelogram(workArea)
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then
        return nil
    end
    local ok, sx, _, sz = pcall(getWorldTranslation, workArea.start)
    if not ok or not sx then return nil end
    local ok2, xw, _, zw = pcall(getWorldTranslation, workArea.width)
    if not ok2 or not xw then return nil end
    local ok3, xh, _, zh = pcall(getWorldTranslation, workArea.height)
    if not ok3 or not xh then return nil end
    return {
        start  = { x = sx, z = sz },
        width  = { x = xw, z = zw },
        height = { x = xh, z = zh },
    }
end

--- Resolve the farmland id from a work-area parallelogram at the start corner.
--- The retired malformed attached-root fallback is gone (brief 3.6): a machine
--- root position is not crop-cycle identity.
function ZoneYield:_resolveFieldId(_cutterSelf, para)
    local function atWorld(x, z)
        if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
            local field = g_fieldManager:getFieldAtWorldPosition(x, z)
            if field and field.farmland then return field.farmland.id end
        end
        if g_farmlandManager then
            local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
            if farmland then return farmland.id end
        end
        return nil
    end
    local fieldId = atWorld(para.start.x, para.start.z)
    if fieldId and fieldId > 0 then return fieldId end
    return nil
end

--- The single source polygon and carrier-owner proof for a work-area
--- parallelogram (brief 3.6). Every covered region must belong to one positive
--- farmland and one provider polygon, with the same carrier owner recorded by
--- capture. A non-owner boundary key or an unavailable owner proof fails.
--- @return string|nil sourcePolygonFingerprint
--- @return boolean proved
function ZoneYield:_sourcePolygonForWorkArea(fieldId, para)
    local plan = self:_plan(fieldId)
    if plan == nil or type(plan.regions) ~= 'table' then return nil, false end
    local grain = self:_grain(plan)
    if grain == nil then return nil, false end

    local lookup = {}
    for _, region in ipairs(plan.regions) do lookup[region.key] = region end

    local minGX = math.floor(math.min(para.start.x, para.width.x, para.height.x) / grain)
    local maxGX = math.floor(math.max(para.start.x, para.width.x, para.height.x) / grain)
    local minGZ = math.floor(math.min(para.start.z, para.width.z, para.height.z) / grain)
    local maxGZ = math.floor(math.max(para.start.z, para.width.z, para.height.z) / grain)

    local covered = {}
    local count = 0
    for gx = minGX, maxGX do
        for gz = minGZ, maxGZ do
            count = count + 1
            if count > 4096 then return nil, false end
            local region = lookup[gx .. ':' .. gz]
            if region ~= nil then
                if region.carrierOwnerFarmlandId ~= nil and region.carrierOwnerFarmlandId ~= fieldId then
                    return nil, false
                end
                covered[region.sourcePolygonFingerprint] = true
            end
        end
    end

    local fp, n = nil, 0
    for k in pairs(covered) do fp = k; n = n + 1 end
    if n ~= 1 then return nil, false end
    return fp, true
end

--- The matching receipt for (farmland, polygon, fruit), or nil.
function ZoneYield:_findReceipt(fieldId, sourcePolygonFingerprint, fruitTypeIndex)
    if sourcePolygonFingerprint == nil then return nil end
    return self._receipts[ZoneYield.receiptKey(fieldId, sourcePolygonFingerprint, fruitTypeIndex)]
end

--- The fruit-filtered traffic drag over a polygon. Reads the SF-55 trafficDrag
--- layer masked by the fruit filter; nil or zero is identity (drag = 0).
function ZoneYield:_readTrafficDragPolygon(vm, verts, fruitFilter)
    local drag, _ = vm:readAverageOfPolygon('trafficDrag', verts, fruitFilter)
    if type(drag) ~= 'number' or drag <= 0 then return nil end
    return math.max(0, math.min(1, drag))
end

--- The fruit-filtered yieldEfficiency polygon mean, divided by 100 exactly once.
function ZoneYield:_readYieldPolygon(vm, verts, fruitFilter)
    local mean, _ = vm:readAverageOfPolygon('yieldEfficiency', verts, fruitFilter)
    if type(mean) ~= 'number' then return nil end
    return mean / 100
end

--- The drag path: a deterministic rotated subdivision of the true parallelogram
--- under the candidate ceiling (brief 3.8). Every candidate centre across the full
--- rotated parallelogram is visited; each performs one native fruit-area weight
--- query, one yield read and at most one traffic-drag read. Accepted values are
--- aggregated by native fruit area.
function ZoneYield:_readDragPath(vm, para, fruitTypeIndex, allowsForageGrowthState, _drag)
    local ux, uz = para.width.x - para.start.x, para.width.z - para.start.z
    local vx, vz = para.height.x - para.start.x, para.height.z - para.start.z
    local lenU = math.sqrt(ux * ux + uz * uz)
    local lenV = math.sqrt(vx * vx + vz * vz)
    local nx, ny = ZoneYield.dragSubdivisions(lenU, lenV, ZoneYield.DRAG_MAX_CANDIDATES)

    local stepUx, stepUz = ux / nx, uz / nx
    local stepVx, stepVz = vx / ny, vz / ny

    local samples = {}
    for i = 0, nx - 1 do
        for j = 0, ny - 1 do
            local tx = (i + 0.5) / nx
            local tz = (j + 0.5) / ny
            local cx = para.start.x + ux * tx + vx * tz
            local cz = para.start.z + uz * tx + vz * tz
            -- One native fruit-area weight query per candidate.
            local x0 = cx - stepUx * 0.5 - stepVx * 0.5
            local z0 = cz - stepUz * 0.5 - stepVz * 0.5
            local ok, area = pcall(function()
                return FSDensityMapUtil.getFruitArea(fruitTypeIndex,
                    x0, z0, x0 + stepUx, z0 + stepUz, x0 + stepVx, z0 + stepVz,
                    false, allowsForageGrowthState)
            end)
            if ok and type(area) == 'number' and area > 0 then
                local captured = vm:readValueAtWorld('yieldEfficiency', cx, cz)
                if type(captured) == 'number' then
                    local pointDrag = vm:readValueAtWorld('trafficDrag', cx, cz)
                    local d = type(pointDrag) == 'number' and math.max(0, math.min(1, pointDrag)) or 0
                    samples[#samples + 1] = {
                        value = ZoneYield.composeDrag(captured / 100, d),
                        area  = area,
                    }
                end
            end
        end
    end
    if #samples == 0 then return nil end
    return ZoneYield.aggregateAreaWeighted(samples)
end

--- Prepare the pre-cut spatial context for one active work area, BEFORE the
--- destructive base Cutter call. Paths: "spatial" (READY/FROZEN_SPATIAL receipt
--- plus a native read), "fallback" (no receipt or no spatial answer; the caller
--- uses the existing frozen scalar), "contract" (NPC-disabled or contract-exempt).
function ZoneYield:preparePreCutContext(cutterSelf, workArea)
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local spec = cutterSelf.spec_cutter
    if spec == nil or spec.workAreaParameters == nil then return nil end
    local para = self:_workAreaParallelogram(workArea)
    if para == nil then return nil end

    -- Select the first harvestable fruit in engine order under the actual route.
    local allowsForageGrowthState = spec.allowsForageGrowthState or false
    local fruitTypeIndex = nil
    local candidates = spec.workAreaParameters.fruitTypeIndicesToUse
    if candidates ~= nil then
        for _, candidate in ipairs(candidates) do
            local ok, area = pcall(function()
                return FSDensityMapUtil.getFruitArea(candidate, para.start.x, para.start.z,
                    para.width.x, para.width.z, para.height.x, para.height.z, false, allowsForageGrowthState)
            end)
            if ok and type(area) == 'number' and area > 0 then
                fruitTypeIndex = candidate
                break
            end
        end
    end
    if fruitTypeIndex == nil then return nil end

    local fieldId = self:_resolveFieldId(cutterSelf, para)
    if fieldId == nil or fieldId <= 0 then return nil end

    -- Contract fallback: NPC-disabled or contract-exempt fields never consume a
    -- polygon receipt (brief 3.2).
    if self._contractRefreshed[fieldId] ~= fruitTypeIndex then
        if FieldSentry_API ~= nil and type(FieldSentry_API.refreshContract) == 'function' then
            pcall(FieldSentry_API.refreshContract, fieldId)
        end
        self._contractRefreshed[fieldId] = fruitTypeIndex
    end
    local disabled, reason, _, hints = false, nil, false, nil
    if FieldSentry_API ~= nil and type(FieldSentry_API.isFieldSimDisabled) == 'function' then
        local ok, d, r, _, h = pcall(FieldSentry_API.isFieldSimDisabled, fieldId)
        if ok then disabled, reason, hints = d, r, h end
    end
    local contractExempt = hints ~= nil and hints.contractExempt == true
    local npcReason = FieldSentry_Core ~= nil and FieldSentry_Core.BLACKLIST ~= nil
        and FieldSentry_Core.BLACKLIST.NPC or nil
    if disabled and ((npcReason ~= nil and reason == npcReason) or contractExempt) then
        return { path = "contract", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = nil, drag = nil }
    end

    local desc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local route = ZoneYield.classifyCapability(desc)
    local forageRoute = ZoneYield.isForageRoute(desc, route)
    if route == ZoneYield.ROUTE_SCALAR then
        return { path = "fallback", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex,
                 scalar = nil, drag = nil, forageRoute = forageRoute }
    end

    local sourceFp, proved = self:_sourcePolygonForWorkArea(fieldId, para)
    if not proved then
        return { path = "fallback", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex,
                 scalar = nil, drag = nil, forageRoute = forageRoute }
    end

    local receipt = self:_findReceipt(fieldId, sourceFp, fruitTypeIndex)
    if receipt == nil or (receipt.status ~= ZoneYield.STATUS_READY
        and receipt.status ~= ZoneYield.STATUS_FROZEN_SPATIAL) then
        return { path = "fallback", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex,
                 scalar = nil, drag = nil, sourcePolygonFingerprint = sourceFp,
                 forageRoute = forageRoute }
    end

    local verts = {
        { x = para.start.x,  z = para.start.z },
        { x = para.width.x,  z = para.width.z },
        { x = para.height.x, z = para.height.z },
        { x = para.width.x + para.height.x - para.start.x, z = para.width.z + para.height.z - para.start.z },
    }
    local fruitFilter = self:_getFruitFilter(fruitTypeIndex, allowsForageGrowthState)
    local drag = self:_readTrafficDragPolygon(vm, verts, fruitFilter)

    local scalar
    if drag ~= nil and drag > 0 then
        scalar = self:_readDragPath(vm, para, fruitTypeIndex, allowsForageGrowthState, drag)
    else
        scalar = self:_readYieldPolygon(vm, verts, fruitFilter)
    end
    if scalar == nil then
        return { path = "fallback", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex,
                 scalar = nil, drag = drag, sourcePolygonFingerprint = sourceFp,
                 forageRoute = forageRoute }
    end
    return { path = "spatial", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex,
             scalar = scalar, drag = drag, sourcePolygonFingerprint = sourceFp,
             route = route, forageRoute = forageRoute }
end

--- After one positive matching Cutter delta, store the fallback scalar and freeze
--- the exact spatial or fallback receipt (brief 3.6). Called by the Cutter wrapper.
function ZoneYield:onFirstCut(context)
    if context == nil then return false end
    if not self.isInitialized then return false end
    if not self:isLive() then return false end
    if not self:_isServer() then return false end
    local fieldId, fruitTypeIndex = context.fieldId, context.fruitTypeIndex
    if fieldId == nil or fruitTypeIndex == nil then return false end

    local fallbackScalar = context.fallbackScalar
    if type(fallbackScalar) ~= 'number' then
        fallbackScalar = self:_baselineRaw(fieldId, fruitTypeIndex)
    end
    self._fallbacks[tostring(fieldId) .. '|' .. tostring(fruitTypeIndex)] = {
        scalar = fallbackScalar,
        forageRoute = context.forageRoute == true,
        generation = self._captureGeneration,
    }

    if context.path == 'spatial' and context.sourcePolygonFingerprint ~= nil then
        local receipt = self:_findReceipt(fieldId, context.sourcePolygonFingerprint, fruitTypeIndex)
        if receipt ~= nil and (receipt.status == ZoneYield.STATUS_READY
            or receipt.status == ZoneYield.STATUS_FROZEN_SPATIAL) then
            receipt.status = ZoneYield.STATUS_FROZEN_SPATIAL
            receipt.fallbackScalar = fallbackScalar
            receipt.forageRoute = context.forageRoute == true
            receipt.captureGeneration = self._captureGeneration
            return true
        end
    end
    return false
end

--- The SowingMachine work-area door (brief 3.6): for every positive changed area,
--- clear only the matching receipts at the exact work-area coordinates. Machine
--- root position is not crop-cycle identity. If exact polygon identity cannot be
--- proved, protect unrelated frozen receipts and leave the new crop on PENDING.
function ZoneYield:onSowingWorkArea(workArea)
    if not self.isInitialized then return 0 end
    if not self:isLive() then return 0 end
    if not self:_isServer() then return 0 end
    local para = self:_workAreaParallelogram(workArea)
    if para == nil then return 0 end
    local vm = self:_valueMaps()
    if vm == nil then return 0 end

    -- Distinct farmlands carrying receipts; resolve each farmland's single source
    -- polygon at the exact work area and clear only the matching receipts.
    local farmlands = {}
    for _, r in pairs(self._receipts) do
        if r.farmlandId ~= nil then farmlands[r.farmlandId] = true end
    end

    local cleared = 0
    for fieldId in pairs(farmlands) do
        local fp, proved = self:_sourcePolygonForWorkArea(fieldId, para)
        if proved and fp ~= nil then
            local toClear = {}
            for k, r in pairs(self._receipts) do
                if r.farmlandId == fieldId and r.sourcePolygonFingerprint == fp then
                    toClear[#toClear + 1] = k
                end
            end
            for _, k in ipairs(toClear) do
                local r = self._receipts[k]
                self._fallbacks[tostring(r.farmlandId) .. '|' .. tostring(r.fruitTypeIndex)] = nil
                self._receipts[k] = nil
                cleared = cleared + 1
            end
        end
    end
    return cleared
end

--- Published per-cell captured efficiency, the socket ViabilityMask's
--- getCellGrowthInfo contract carries. Percent stored on the layer / 100.
function ZoneYield:readCapturedEfficiency(_fieldId, x, z)
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local value = vm:readValueAtWorld('yieldEfficiency', x, z)
    if type(value) ~= 'number' then return nil end
    return value / 100
end

--- Read-only witness for the in-mod SF-54 assembler (brief 4): matching receipt
--- identity, status, path, grain, generation and captured percent, or nil.
function ZoneYield:getGrowthSurfaceWitness(fieldId, x, z)
    if not self.isInitialized then return nil end
    if not self:_isServer() then return nil end
    if not self:isLive() then return nil end
    local vm = self:_valueMaps()
    if vm == nil then return nil end
    local plan = self:_plan(fieldId)
    if plan == nil then return nil end
    local grain = self:_grain(plan)
    if grain == nil then return nil end

    local key = math.floor(x / grain) .. ':' .. math.floor(z / grain)
    local region = nil
    for _, r in ipairs(plan.regions) do
        if r.key == key then region = r; break end
    end
    if region == nil then return nil end
    if region.carrierOwnerFarmlandId ~= nil and region.carrierOwnerFarmlandId ~= fieldId then return nil end

    local _, fruitIndex = self:_readCellState(x, z)
    if fruitIndex == nil then return nil end
    local pct = vm:readValueAtWorld('yieldEfficiency', x, z)
    local receipt = self:_findReceipt(fieldId, region.sourcePolygonFingerprint, fruitIndex)
    return {
        farmlandId = fieldId,
        coversPoint = true,
        sourcePolygonFingerprint = region.sourcePolygonFingerprint,
        fruitTypeIndex = fruitIndex,
        grainMetres = grain,
        generation = receipt and receipt.captureGeneration or self._captureGeneration,
        status = receipt and receipt.status or ZoneYield.STATUS_PENDING,
        capturedPercent = pct,
    }
end

-- ============================================================
-- SAVE / RELOAD / TEARDOWN (brief 3.5/3.10)
-- ============================================================

--- Persist bounded receipt and fallback metadata under soilData.zoneYield. The
--- dense cell truth is the `yieldEfficiency` GRLE file written by SoilValueMaps.
--- Session jobs, cursors and provider revisions never enter XML.
function ZoneYield:saveToXMLFile(xmlFile, key)
    if xmlFile == nil or key == nil then return end
    setXMLInt(xmlFile, key .. "#schema", 1)
    setXMLInt(xmlFile, key .. "#captureGeneration", self._captureGeneration or 0)
    setXMLString(xmlFile, key .. "#layerState", self._layerState or ZoneYield.LAYER_READY)

    -- Contract fallback map, ordered for determinism.
    local fkeys = {}
    for k in pairs(self._fallbacks or {}) do fkeys[#fkeys + 1] = k end
    table.sort(fkeys)
    local fi = 0
    for _, k in ipairs(fkeys) do
        local fb = self._fallbacks[k]
        local entryKey = string.format("%s.fallback(%d)", key, fi)
        setXMLString(xmlFile, entryKey .. "#key", k)
        setXMLFloat(xmlFile, entryKey .. "#scalar", fb.scalar or 1.0)
        setXMLInt(xmlFile, entryKey .. "#forage", fb.forageRoute and 1 or 0)
        setXMLInt(xmlFile, entryKey .. "#generation", fb.generation or 0)
        fi = fi + 1
    end
    setXMLInt(xmlFile, key .. "#fallbackCount", fi)

    -- Receipts, ordered by polygon fingerprint then numeric fruit index.
    local ordered = {}
    for _, r in pairs(self._receipts or {}) do ordered[#ordered + 1] = r end
    table.sort(ordered, function(a, b)
        if tostring(a.sourcePolygonFingerprint) ~= tostring(b.sourcePolygonFingerprint) then
            return tostring(a.sourcePolygonFingerprint) < tostring(b.sourcePolygonFingerprint)
        end
        return (a.fruitTypeIndex or 0) < (b.fruitTypeIndex or 0)
    end)
    local ri = 0
    for _, r in ipairs(ordered) do
        local entryKey = string.format("%s.receipt(%d)", key, ri)
        setXMLInt(xmlFile, entryKey .. "#farmlandId", r.farmlandId or 0)
        setXMLString(xmlFile, entryKey .. "#polygon", r.sourcePolygonFingerprint or '')
        setXMLInt(xmlFile, entryKey .. "#fruit", r.fruitTypeIndex or 0)
        setXMLString(xmlFile, entryKey .. "#status", r.status or ZoneYield.STATUS_PENDING)
        setXMLInt(xmlFile, entryKey .. "#generation", r.captureGeneration or 0)
        setXMLString(xmlFile, entryKey .. "#planHash", r.planContentHash or '')
        setXMLString(xmlFile, entryKey .. "#ownerHash", r.carrierOwnershipHash or '')
        setXMLString(xmlFile, entryKey .. "#geometry", r.polygonUnionFingerprint or '')
        setXMLString(xmlFile, entryKey .. "#settings", r.settingsFingerprint or '')
        setXMLFloat(xmlFile, entryKey .. "#fallbackScalar", r.fallbackScalar or 0)
        setXMLInt(xmlFile, entryKey .. "#forage", r.forageRoute and 1 or 0)
        ri = ri + 1
    end
    setXMLInt(xmlFile, key .. "#receiptCount", ri)
end

--- Restore bounded metadata. A schema or roster mismatch clears the durable
--- spatial state; polygon geometry mismatch clears only affected spatial receipts;
--- PENDING queues fresh complete work once a current plan arrives.
function ZoneYield:loadFromXMLFile(xmlFile, key)
    self._receipts = {}
    self._fallbacks = {}
    self._queue = {}
    self._pendingValidation = {}
    if xmlFile == nil or key == nil then self:_classifyLayer(); return end

    local schema = getXMLInt(xmlFile, key .. "#schema") or 0
    self._captureGeneration = getXMLInt(xmlFile, key .. "#captureGeneration") or 0
    self._layerState = getXMLString(xmlFile, key .. "#layerState") or ZoneYield.LAYER_READY
    if schema ~= 1 then self:_classifyLayer(); return end

    local fcount = getXMLInt(xmlFile, key .. "#fallbackCount") or 0
    for i = 0, fcount - 1 do
        local entryKey = string.format("%s.fallback(%d)", key, i)
        local k = getXMLString(xmlFile, entryKey .. "#key")
        if k ~= nil then
            self._fallbacks[k] = {
                scalar = getXMLFloat(xmlFile, entryKey .. "#scalar") or 1.0,
                forageRoute = (getXMLInt(xmlFile, entryKey .. "#forage") or 0) == 1,
                generation = getXMLInt(xmlFile, entryKey .. "#generation") or 0,
            }
        end
    end

    local rcount = getXMLInt(xmlFile, key .. "#receiptCount") or 0
    for i = 0, rcount - 1 do
        local entryKey = string.format("%s.receipt(%d)", key, i)
        local farmlandId = getXMLInt(xmlFile, entryKey .. "#farmlandId")
        local fruit = getXMLInt(xmlFile, entryKey .. "#fruit")
        local polygon = getXMLString(xmlFile, entryKey .. "#polygon")
        if farmlandId ~= nil and fruit ~= nil and polygon ~= nil then
            local rk = ZoneYield.receiptKey(farmlandId, polygon, fruit)
            self._receipts[rk] = {
                farmlandId = farmlandId,
                sourcePolygonFingerprint = polygon,
                fruitTypeIndex = fruit,
                status = getXMLString(xmlFile, entryKey .. "#status") or ZoneYield.STATUS_PENDING,
                captureGeneration = getXMLInt(xmlFile, entryKey .. "#generation") or 0,
                planContentHash = getXMLString(xmlFile, entryKey .. "#planHash") or '',
                carrierOwnershipHash = getXMLString(xmlFile, entryKey .. "#ownerHash") or '',
                polygonUnionFingerprint = getXMLString(xmlFile, entryKey .. "#geometry") or '',
                settingsFingerprint = getXMLString(xmlFile, entryKey .. "#settings") or '',
                fallbackScalar = getXMLFloat(xmlFile, entryKey .. "#fallbackScalar"),
                forageRoute = (getXMLInt(xmlFile, entryKey .. "#forage") or 0) == 1,
            }
            self._pendingValidation[farmlandId] = true
        end
    end
    self:_classifyLayer()
end

--- StateLedger mirror table (the same normalized durable metadata).
function ZoneYield:getStateTable()
    return {
        schema = 1,
        captureGeneration = self._captureGeneration,
        layerState = self._layerState,
        farmlands = self._receipts,
        fallbacks = self._fallbacks,
    }
end

--- Apply a StateLedger metadata block.
function ZoneYield:applyStateTable(data)
    self._receipts = {}
    self._fallbacks = {}
    self._queue = {}
    self._pendingValidation = {}
    if type(data) ~= 'table' then self:_classifyLayer(); return end
    if type(data.farmlands) == 'table' then
        for k, r in pairs(data.farmlands) do
            if type(r) == 'table' then
                self._receipts[k] = r
                if r.farmlandId ~= nil then self._pendingValidation[r.farmlandId] = true end
            end
        end
    end
    if type(data.fallbacks) == 'table' then
        for k, fb in pairs(data.fallbacks) do
            if type(fb) == 'table' then self._fallbacks[k] = fb end
        end
    end
    self._captureGeneration = (type(data.captureGeneration) == 'number' and data.captureGeneration) or 0
    self._layerState = data.layerState or ZoneYield.LAYER_READY
    self:_classifyLayer()
end

-- ============================================================
-- CADENCE + LIFECYCLE
-- ZoneYield owns no independent growth subscription: the manager's one
-- server family dispatch delivers FINISHED (brief 3.10). register() is a
-- no-op retained for the manager's uniform member API.
-- ============================================================

function ZoneYield:register()
    return true
end

--- Retained so a manager that still calls it installs no independent
--- subscription. Slice 2 migrates the call onto the family dispatch.
function ZoneYield:registerGrowthMessage()
    return true
end

--- The family's live gate: the release gate must be open AND the mask enabled.
--- FAIL-OPEN on the release gate (nil settings on the bench means live); the
--- mask switch is a real toggle and gates hard.
function ZoneYield:isLive()
    local vm = self:_viability()
    if vm ~= nil and vm.enabled == false then return false end
    if ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == 'function' then
        return ReleaseGate.isSystemLive("growth_modulation")
    end
    return true
end
