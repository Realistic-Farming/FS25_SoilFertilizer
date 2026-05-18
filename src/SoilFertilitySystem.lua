-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Core Simulation
-- =========================================================
-- Per-field N/P/K/pH/OM tracking: depletion on harvest,
-- restoration on fertilizer, rain leaching, seasonal effects,
-- fallow recovery, seasonal effects.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilFertilitySystem
SoilFertilitySystem = {}
local SoilFertilitySystem_mt = Class(SoilFertilitySystem)

local COVERAGE_MILESTONES = { 0.10, 0.25, 0.50, 0.75, 1.0 }

function SoilFertilitySystem.new(settings)
    local self = setmetatable({}, SoilFertilitySystem_mt)
    self.settings = settings
    self.fieldData = {}
    self.lastUpdate = 0
    self.updateInterval = SoilConstants.TIMING.UPDATE_INTERVAL
    self.isInitialized = false
    self.lastUpdateDay = 0
    self.hookManager = HookManager.new()
    -- Install early so custom fill types are in supportedFillTypes before Mission00.load
    -- restores vehicle fill levels from the savegame (fixes fertilizer disappearing on reload).
    self.hookManager:installFillUnitHookEarly()
    self.layerSystem = SoilLayerSystem and SoilLayerSystem.new() or nil

    -- Per-day flag table for fertilizer application notifications (fieldId → game day last shown)
    -- Prevents notification spam since the sprayer hook fires every frame while active.
    -- Stores the game day, not a timestamp, so the notification fires at most once per field per in-game day.
    self.fertNotifyShown = {}

    -- Per-day throttle tables for crop protection pressure reductions (fieldId → game day last applied).
    -- The sprayer hook fires every frame while the sprayer is active. Without throttling, a single
    -- pass across a field applies the full pressure reduction 60+ times per second, instantly
    -- resetting weed/pest/disease pressure to 0 from even 1L of product applied.
    -- Fix: allow at most ONE reduction event per field per in-game day, matching real-world
    -- application logic (you spray a field once per day at most, not 3600 times per minute).
    self.herbicideAppliedDay  = {}   -- fieldId → game day herbicide last reduced pressure
    self.insecticideAppliedDay = {}  -- fieldId → game day insecticide last reduced pressure
    self.fungicideAppliedDay  = {}   -- fieldId → game day fungicide last reduced pressure

    -- =========================================================
    -- PERF: Owned-field active set + batched daily simulation
    -- =========================================================
    -- Only OWNED fields (farmId > 0) receive passive daily updates
    -- (fallow recovery, seasonal effects, pressure growth, etc.).
    -- Unowned fields still get fieldData created on first interaction
    -- but are excluded from the background simulation loop.
    -- On a typical 16x farm (25-50% ownership) this cuts update
    -- cost by 50-75% vs iterating all fieldData unconditionally.
    self.activeFieldIds   = {}    -- {[fieldId]=true}  – owned fields only
    self._activeFieldList = {}    -- ordered array for indexed batch iteration
    self._activeListDirty = false -- true when set changed, list needs rebuild

    -- Batched daily update: spread per-field work across multiple frames
    -- instead of processing every owned field in one potentially expensive call.
    self._pendingDailyUpdate = false  -- set true when game-day rolls over
    self._dailyBatchCursor   = 0     -- how many fields processed so far today
    self._dailyBatchDay      = 0     -- game day the active batch belongs to
    self._dailyBatchSeason   = nil   -- season snapshot taken at batch start
    self.DAILY_BATCH_SIZE    = 25    -- fields per update() call (~0.5 ms budget)

    return self
end

-- Initialize system with ALL real hooks
function SoilFertilitySystem:initialize()
    if self.isInitialized then
        self:info("System already initialized, skipping")
        return
    end

    self:info("Initializing Soil Fertility System...")

    -- =========================================================
    -- PHASE 3: Adaptive cell resolution based on map size
    -- =========================================================
    -- On a 16x map (16384m) the default 10m cell would create 1638×1638 = ~2.7M
    -- possible cell keys per field. Scaling the cell size with map dimensions keeps
    -- spatial resolution proportional to field sizes and bounds the total key count.
    --   4x  (4096m):  scale=1 → cellSize=10m  (0.01 ha/cell)
    --   8x  (8192m):  scale=2 → cellSize=20m  (0.04 ha/cell)
    --   16x (16384m): scale=4 → cellSize=40m  (0.16 ha/cell)
    do
        local BASE_MAP  = 4096
        local BASE_CELL = SoilConstants.ZONE.CELL_SIZE   -- 10 m on standard map
        local mapSize   = (g_currentMission and g_currentMission.terrainSize) or BASE_MAP
        local scale     = mapSize / BASE_MAP
        -- Round to nearest integer multiple of BASE_CELL for exact metre boundaries
        self.cellSize   = math.max(BASE_CELL, math.floor(scale) * BASE_CELL)
        self.cellAreaHa = (self.cellSize * self.cellSize) / 10000.0
        -- Propagate to shared constants so SoilMapOverlay reads the same resolution
        SoilConstants.ZONE.CELL_SIZE    = self.cellSize
        SoilConstants.ZONE.CELL_AREA_HA = self.cellAreaHa
        SoilLogger.debug("[PERF-P3] Map %.0fm (%.1fx) → cell %dm  %.4f ha/cell",
            mapSize, scale, self.cellSize, self.cellAreaHa)
    end

    -- Scan fields using real FieldManager
    if g_fieldManager then
        self:scanFields()
    else
        self:warning("FieldManager not available - will try delayed initialization")
    end

    -- Install hooks via HookManager
    self.hookManager:installAll(self)

    -- Initialize density map layer integration (per-pixel soil maps)
    if self.layerSystem then
        self.layerSystem:initialize()
    end

    self.isInitialized = true
    self:info("Soil Fertility System initialized successfully")
    self:info("Fertility System: %s, Nutrient Cycles: %s",
        tostring(self.settings.fertilitySystem),
        tostring(self.settings.nutrientCycles))

    -- Log multifruit compatibility status
    self:logCropProfileStatus()

end

-- Log which registered fruit types have explicit extraction profiles
-- and which will use the fallback (multifruit/custom map crops).
function SoilFertilitySystem:logCropProfileStatus()
    if not g_fruitTypeManager then return end
    local fruitTypes = g_fruitTypeManager:getFruitTypes()
    if not fruitTypes then return end

    local explicit = {}
    local fallback = {}

    for _, fruitDesc in pairs(fruitTypes) do
        local name = fruitDesc and fruitDesc.name
        if name then
            local lowerName = string.lower(name)
            if SoilConstants.CROP_EXTRACTION[lowerName] then
                table.insert(explicit, name)
            else
                table.insert(fallback, name)
            end
        end
    end

    table.sort(explicit)
    table.sort(fallback)

    local def = SoilConstants.CROP_EXTRACTION_DEFAULT
    self:info("Crop profiles: %d explicit, %d using fallback (N=%.2f P=%.2f K=%.2f)",
        #explicit, #fallback, def.N, def.P, def.K)
    if #explicit > 0 then
        self:info("  Explicit: %s", table.concat(explicit, ", "))
    end
    if #fallback > 0 then
        self:info("  Fallback (multifruit/unknown): %s", table.concat(fallback, ", "))
    end
end

-- Cleanup hooks and resources
function SoilFertilitySystem:delete()
    self.hookManager:uninstallAll()
    if self.layerSystem then
        self.layerSystem:delete()
        self.layerSystem = nil
    end
    self.fieldData = {}
    self.isInitialized = false
end

--- Hook delegate: called by HookManager when harvest occurs
--- Depletes soil nutrients based on crop type and difficulty
---@param fieldId number The field being harvested
---@param fruitTypeIndex number FS25 fruit type index
---@param liters number Amount harvested in liters
---@param strawRatio number 0.0-1.0 fraction of straw that was chopped (0 = dropped/collected, 1 = fully chopped)
--- Computes the combined yield modifier for a harvest event.
--- All yield-reducing factors (nutrients, weeds, pests, disease) are multiplied together.
--- Returns a value in [1-MAX_PENALTY, 1.0] — applied to liters BEFORE the combine hopper
--- receives grain in HookManager, so the game engine actually sees fewer liters.
---@param fieldId number
---@param fruitTypeIndex number
---@return number modifier  Combined yield multiplier
function SoilFertilitySystem:computeYieldModifier(fieldId, fruitTypeIndex)
    if not self.settings.enabled then return 1.0 end

    local field = self.fieldData[fieldId]
    if not field then return 1.0 end

    local modifier = 1.0

    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local cropName  = fruitDesc and string.lower(fruitDesc.name or "") or ""
    local ys        = SoilConstants.YIELD_SENSITIVITY
    local isGrass   = ys and ys.NON_CROP_NAMES and ys.NON_CROP_NAMES[cropName]

    -- Nutrient-based modifier (only when nutrientCycles enabled, skipped for grass/non-crop)
    if self.settings.nutrientCycles and ys and not isGrass then
        local tier     = ys.CROP_TIERS[cropName] or ys.DEFAULT_TIER
        local tierData = ys.TIERS[tier]
        local thresh   = ys.OPTIMAL_THRESHOLD

        local nDef = math.max(0, thresh - field.nitrogen)   / thresh
        local pDef = math.max(0, thresh - field.phosphorus) / thresh
        local kDef = math.max(0, thresh - field.potassium)  / thresh

        -- When Precision Farming is active its ExtendedCombine already applies an N-based
        -- yield penalty. Exclude N from SF's average to avoid stacking both penalties on
        -- the same deficiency. P and K are SF-exclusive (PF does not track them).
        local avgDef
        local pfActive = self.pfBridge and self.pfBridge.isActive and self.settings.pfCompatibilityMode
        if pfActive then
            avgDef = (pDef + kDef) / 2
        else
            avgDef = (nDef + pDef + kDef) / 3
        end

        local nutrientPenalty = math.min(ys.MAX_PENALTY, avgDef * tierData.scale)
        if nutrientPenalty > 0 then
            modifier = modifier * (1.0 - nutrientPenalty)
            if pfActive then
                self:log("Nutrient penalty field %d (%s/%s) [PF Mode - P/K only]: P=%.0f K=%.0f → -%.0f%%",
                    fieldId, cropName, tier, field.phosphorus, field.potassium, nutrientPenalty * 100)
            else
                self:log("Nutrient penalty field %d (%s/%s): N=%.0f P=%.0f K=%.0f → -%.0f%%",
                    fieldId, cropName, tier, field.nitrogen, field.phosphorus, field.potassium,
                    nutrientPenalty * 100)
            end
        end
    end

    -- Weed pressure modifier (skip for grassland)
    if self.settings.weedPressure and SoilConstants.WEED_PRESSURE and not isGrass then
        local wp       = SoilConstants.WEED_PRESSURE
        local pressure = field.weedPressure or 0
        local penalty
        if pressure < wp.LOW then         penalty = wp.YIELD_PENALTY_LOW
        elseif pressure < wp.MEDIUM then  penalty = wp.YIELD_PENALTY_MID
        elseif pressure < wp.HIGH then    penalty = wp.YIELD_PENALTY_HIGH
        else                              penalty = wp.YIELD_PENALTY_PEAK end
        if penalty > 0 then
            modifier = modifier * (1.0 - penalty)
            self:log("Weed penalty field %d: pressure=%.0f → -%.0f%%", fieldId, pressure, penalty * 100)
        end
    end

    -- Pest pressure modifier
    if self.settings.pestPressure and SoilConstants.PEST_PRESSURE then
        local pp       = SoilConstants.PEST_PRESSURE
        local pressure = field.pestPressure or 0
        local penalty
        if pressure < pp.LOW then         penalty = pp.YIELD_PENALTY_LOW
        elseif pressure < pp.MEDIUM then  penalty = pp.YIELD_PENALTY_MID
        elseif pressure < pp.HIGH then    penalty = pp.YIELD_PENALTY_HIGH
        else                              penalty = pp.YIELD_PENALTY_PEAK end
        if penalty > 0 then
            modifier = modifier * (1.0 - penalty)
            self:log("Pest penalty field %d: pressure=%.0f → -%.0f%%", fieldId, pressure, penalty * 100)
        end
    end

    -- Disease pressure modifier
    if self.settings.diseasePressure and SoilConstants.DISEASE_PRESSURE then
        local dp       = SoilConstants.DISEASE_PRESSURE
        local pressure = field.diseasePressure or 0
        local penalty
        if pressure < dp.LOW then         penalty = dp.YIELD_PENALTY_LOW
        elseif pressure < dp.MEDIUM then  penalty = dp.YIELD_PENALTY_MID
        elseif pressure < dp.HIGH then    penalty = dp.YIELD_PENALTY_HIGH
        else                              penalty = dp.YIELD_PENALTY_PEAK end
        if penalty > 0 then
            modifier = modifier * (1.0 - penalty)
            self:log("Disease penalty field %d: pressure=%.0f → -%.0f%%", fieldId, pressure, penalty * 100)
        end
    end

    return modifier
end

function SoilFertilitySystem:onHarvest(fieldId, fruitTypeIndex, liters, strawRatio, area)
    -- Harvest-time state resets: pest population disperses when crop is cleared
    if self.settings.pestPressure and SoilConstants.PEST_PRESSURE then
        local field = self.fieldData[fieldId]
        if field then
            local pp = SoilConstants.PEST_PRESSURE
            field.pestPressure    = (field.pestPressure or 0) * pp.HARVEST_RESET_FRACTION
            field.insecticideDaysLeft = 0
        end
    end

    -- Nutrient depletion uses original (biological) liters — the soil gave up these
    -- nutrients regardless of the yield modifier applied in the combine hook.
    self:updateFieldNutrients(fieldId, fruitTypeIndex, liters, strawRatio, area)

    -- Reset session spray coverage so the next fertilizing pass starts fresh
    local harvestField = self.fieldData[fieldId]
    if harvestField then
        harvestField.sessionCoverageHa       = 0
        harvestField.sessionCoverageFraction = 0
        harvestField.sessionCoverageCells    = {}
        harvestField.sessionLastProduct      = nil
    end

    SoilLogger.debug("Harvest: Field %d, Crop %d, %.0fL (biological), area=%.1f", fieldId, fruitTypeIndex, liters, area or 0)

    -- Broadcast to clients if server in multiplayer
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        local field = self.fieldData[fieldId]
        if field and SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end
end

--- Hook delegate: called by HookManager when fertilizer applied
--- Hook delegate: called by HookManager when a mower/swather cuts forage crops.
--- Handles nutrient depletion for crops that are CUT but not direct-threshed:
--- grass, alfalfa, clover, mowed triticale, etc.
--- Uses area-based depletion (not liter-based) since no yield liters are produced
--- at mow time — the cut material is left as a windrow for later pickup.
---@param fieldId    number Field/farmland ID
---@param fruitTypeIndex number FS25 fruit type index
---@param areaHa     number Area mowed this tick in hectares
function SoilFertilitySystem:onMow(fieldId, fruitTypeIndex, areaHa)
    if not self.settings.enabled or not self.settings.nutrientCycles then return end
    if not areaHa or areaHa <= 0 then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then
        self:warning("onMow: field %d not found", fieldId)
        return
    end

    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if not fruitDesc then
        self:warning("onMow: fruit type %d not found", fruitTypeIndex)
        return
    end

    -- Mowing ALWAYS uses CROP_EXTRACTION_FORAGE, never the per-crop grain rates.
    -- Reason: CROP_EXTRACTION rates are calibrated for harvested grain volume/density
    -- (threshed yield, e.g. wheat at 0.39 L/sqm). The Mower spec cuts whole-plant
    -- biomass (e.g. wheat windrow at 3.8 L/sqm) — a completely different density.
    -- Using grain rates with windrow-equivalent area would over-extract by ~10x.
    -- CROP_EXTRACTION_FORAGE is calibrated for cut green biomass at MOWER_HA_FACTOR.
    -- This also prevents "mowing wheat before harvest depletes N faster than combining"
    -- scenarios that would confuse players (TisonK's review note on PR #265).
    local rates = SoilConstants.CROP_EXTRACTION_FORAGE or SoilConstants.CROP_EXTRACTION_DEFAULT

    local diffMult = SoilConstants.DIFFICULTY.MULTIPLIERS[self.settings.difficulty] or 1.0
    local haFactor = SoilConstants.MOWER_HA_FACTOR or 6.0
    local fieldAreaHa = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0
    local factor   = (areaHa / fieldAreaHa) * haFactor * diffMult

    local limits = SoilConstants.NUTRIENT_LIMITS
    field.nitrogen   = math.max(limits.MIN, field.nitrogen   - rates.N * factor)
    field.phosphorus = math.max(limits.MIN, field.phosphorus - rates.P * factor)
    field.potassium  = math.max(limits.MIN, field.potassium  - rates.K * factor)

    field.lastCrop    = fruitDesc.name
    field.lastHarvest = (g_currentMission and g_currentMission.environment
                         and g_currentMission.environment.currentDay) or 0

    SoilLogger.debug("Mow: Field %d, %s, %.5f ha — N:%.1f P:%.1f K:%.1f",
        fieldId, fruitDesc.name, areaHa, field.nitrogen, field.phosphorus, field.potassium)

    -- Broadcast field update to clients in multiplayer (throttled — mower fires every tick)
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo
        and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._tillBroadcastTime then self._tillBroadcastTime = {} end
            local last = self._tillBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._tillBroadcastTime[fieldId] = now
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Restores soil nutrients based on fertilizer type
---@param fieldId number The field being fertilized
---@param fillTypeIndex number FS25 fill type index for fertilizer
---@param liters number Amount applied in liters
function SoilFertilitySystem:onFertilizerApplied(fieldId, fillTypeIndex, liters)
    self:applyFertilizer(fieldId, fillTypeIndex, liters)

    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

    SoilLogger.debug("Fertilizer: Field %d, %s, %.4fL", fieldId, fillType and fillType.name or "unknown", liters)

    -- Trigger overlay refresh so the map tile color updates promptly after spraying.
    -- Throttled to once every 2 seconds to avoid rebuilding samplePoints every frame.
    local now = (g_currentMission and g_currentMission.time) or 0
    if not self._fertOverlayRefreshTime then self._fertOverlayRefreshTime = 0 end
    if (now - self._fertOverlayRefreshTime) >= 2000 then
        self._fertOverlayRefreshTime = now
        local overlay = g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
        if overlay then overlay:requestRefresh() end
    end

    -- Broadcast to clients in multiplayer, throttled to once every 5 seconds per field
    -- to avoid flooding the network with 30+ events/second while a sprayer is running.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        local now = g_currentMission.time or 0
        if not self._fertBroadcastTime then self._fertBroadcastTime = {} end
        local last = self._fertBroadcastTime[fieldId] or 0
        if (now - last) >= 5000 then
            self._fertBroadcastTime[fieldId] = now
            local field = self.fieldData[fieldId]
            if field and SoilFieldUpdateEvent then
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

-- Hook delegate: called by HookManager when field ownership changes.
-- PHASE 1: Soil data is PRESERVED across ownership changes — real soil does not
-- reset when land is sold.  We only update active-set membership here.
function SoilFertilitySystem:onFieldOwnershipChanged(fieldId, farmlandId, farmId)
    if not fieldId or fieldId <= 0 then return end

    if farmId == nil or farmId == 0 then
        -- Field sold / abandoned — pull it out of the active simulation set.
        -- fieldData intentionally kept: new owner inherits the soil conditions.
        self:_removeFromActiveSet(fieldId)
        SoilLogger.debug("[PERF-P1] Field %d released by farm — removed from active set (data preserved)", fieldId)
        return
    end

    -- Field acquired — ensure data entry exists, then add to active set.
    local field = self:getOrCreateField(fieldId, true)
    if field then
        self:_addToActiveSet(fieldId)
        SoilLogger.debug("[PERF-P1] Field %d acquired by farm %d — added to active set", fieldId, farmId)
    end
end

--- Hook delegate: called by HookManager when sowing/planting occurs on a field.
--- Called when a field is sown. Reserved for future sowing-time logic.
--- NOTE: We previously cleared lastCrop here to force live HUD detection (#123),
--- but that caused duplicate crop entries in history when the same crop is replanted
--- (especially visible with FS25_CropRotation installed — issue #204).
--- Live FieldState detection in getFieldInfo() works regardless of lastCrop, so
--- the clearing was unnecessary and harmful to rotation history accuracy.
---@param fieldId number The field being sown
---@param area number Area processed in hectares
function SoilFertilitySystem:onSowing(fieldId, area)
    if not fieldId or fieldId <= 0 then return end
    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    local areaHa = area or 0.001
    local fieldAreaHa = field.fieldArea and field.fieldArea > 0 and field.fieldArea or 1.0
    local factor = areaHa / fieldAreaHa

    local changed = false

    -- Seeding disrupts weed seedlings via seed opener soil disturbance.
    -- Partially resets weed pressure based on area processed.
    if self.settings.weedPressure and SoilConstants.WEED_PRESSURE and (field.weedPressure or 0) > 0 then
        local weedReduction = field.weedPressure * factor
        field.weedPressure = math.max(0, field.weedPressure - weedReduction)
        if factor > 0.01 then
            field.herbicideDaysLeft = 0
        end
        changed = true
    end

    -- Direct-drill residue incorporation: seed openers disturb a small fraction of
    -- surface residue, releasing a minimal nutrient pulse. This models the reality
    -- that no-till/direct seeders still cause some residue breakdown at the opener slot.
    if self.settings.residueIncorporation and SoilConstants.RESIDUE_INCORPORATION then
        local ri     = SoilConstants.RESIDUE_INCORPORATION.DIRECT_DRILL
        local limits = SoilConstants.NUTRIENT_LIMITS
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omAfter  = math.min(limits.ORGANIC_MATTER_MAX, omBefore + (ri.OM * factor))
        if omAfter > omBefore then
            field.organicMatter = omAfter
            changed = true
        end

        local dN, dP, dK = ri.N * factor, ri.P * factor, ri.K * factor
        field.nitrogen   = math.min(limits.MAX, (field.nitrogen   or 0) + dN)
        field.phosphorus = math.min(limits.MAX, (field.phosphorus or 0) + dP)
        field.potassium  = math.min(limits.MAX, (field.potassium  or 0) + dK)
        changed = true
        SoilLogger.debug("Residue incorporation (sowing) field %d: +N%.4f +P%.4f +K%.4f (factor %.4f)",
            fieldId, dN, dP, dK, factor)

        -- Local zoneData update for HUD/PDA visibility
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                    pH = field.pH, OM = field.organicMatter,
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
            local cellFactor = areaHa / zone.CELL_AREA_HA
            cell.N = math.min(limits.MAX, cell.N + ri.N * cellFactor)
            cell.P = math.min(limits.MAX, cell.P + ri.P * cellFactor)
            cell.K = math.min(limits.MAX, cell.K + ri.K * cellFactor)
            cell.OM = math.min(limits.ORGANIC_MATTER_MAX, cell.OM + ri.OM * cellFactor)

            -- Weed reduction per cell for direct drill
            if self.settings.weedPressure and cell.weedPressure then
                cell.weedPressure = math.max(0, cell.weedPressure - (cell.weedPressure * cellFactor))
            end
        end
    end

    if changed and g_server and g_currentMission and g_currentMission.missionDynamicInfo
        and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._tillBroadcastTime then self._tillBroadcastTime = {} end
            local last = self._tillBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._tillBroadcastTime[fieldId] = now
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Hook delegate: called by HookManager when plowing occurs
--- Increases organic matter and normalizes pH
---@param fieldId number The field being plowed
---@param area number Area processed in hectares (e.g. from lastStatsArea)
function SoilFertilitySystem:onPlowing(fieldId, area)
    if not fieldId or fieldId <= 0 then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    local areaHa = area or 0.001
    local fieldAreaHa = field.fieldArea and field.fieldArea > 0 and field.fieldArea or 1.0

    -- Per-day area accumulation cap: total effect across all ticks cannot exceed
    -- one full-field-equivalent per day. Prevents double-counting on repeated passes.
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if not self._plowAreaToday then self._plowAreaToday = {} end
    local entry = self._plowAreaToday[fieldId]
    if not entry or entry.day ~= today then
        entry = { day = today, used = 0 }
        self._plowAreaToday[fieldId] = entry
    end
    local clampedArea = math.min(areaHa, math.max(0, fieldAreaHa - entry.used))
    if clampedArea <= 0 then return end
    entry.used = entry.used + clampedArea
    local factor = clampedArea / fieldAreaHa

    local changed = false

    -- Plowing benefits 1 & 2: OM increase and pH normalization (only if plowingBonus enabled)
    if self.settings.plowingBonus then
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omIncrease = 0.5 * factor
        local omAfter = math.min(omBefore + omIncrease, SoilConstants.NUTRIENT_LIMITS.ORGANIC_MATTER_MAX)
        if omAfter > omBefore then
            field.organicMatter = omAfter
            changed = true
        end

        local phBefore = field.pH or SoilConstants.FIELD_DEFAULTS.pH
        local phTarget = 7.0
        local phNormalization = 0.1 * factor
        local phAfter = phBefore
        if phBefore < phTarget then
            phAfter = math.min(phBefore + phNormalization, phTarget)
        elseif phBefore > phTarget then
            phAfter = math.max(phBefore - phNormalization, phTarget)
        end
        if phAfter ~= phBefore then
            field.pH = phAfter
            changed = true
        end
    end

    -- Plowing benefit 3: Reset weed pressure (independent of plowingBonus)
    -- This is a destructive mechanical action, so it instantly kills weeds in the processed area.
    -- Since we track average weed pressure, we reduce it proportionally.
    if self.settings.weedPressure and (field.weedPressure or 0) > 0 then
        local weedReduction = field.weedPressure * factor
        field.weedPressure = math.max(0, field.weedPressure - weedReduction)
        -- Only fully reset herbicide days if we did a large chunk, but for simplicity we let it be
        if factor > 0.01 then
            field.herbicideDaysLeft = 0
        end
        changed = true
    end

    -- Plowing benefit 4: Reduce pest pressure (independent of plowingBonus)
    if self.settings.pestPressure and SoilConstants.PLOWING.PEST_PRESSURE_REDUCTION and (field.pestPressure or 0) > 0 then
        local before = field.pestPressure
        local reduction = SoilConstants.PLOWING.PEST_PRESSURE_REDUCTION * factor
        field.pestPressure = math.max(0, before - reduction)
        changed = true
    end

    -- Plowing benefit 5: Reduce disease pressure (independent of plowingBonus)
    if self.settings.diseasePressure and SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION and (field.diseasePressure or 0) > 0 then
        local before = field.diseasePressure
        local reduction = SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION * factor
        field.diseasePressure = math.max(0, before - reduction)
        changed = true
    end

    -- Plowing benefit 6: Residue incorporation — straw stubble worked in releases OM and NPK
    -- Gated by residueIncorporation setting (separate from plowingBonus so OM/pH and
    -- residue nutrient release can be toggled independently).
    if self.settings.residueIncorporation and SoilConstants.RESIDUE_INCORPORATION then
        local ri     = SoilConstants.RESIDUE_INCORPORATION.PLOW
        local limits = SoilConstants.NUTRIENT_LIMITS
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omAfter  = math.min(limits.ORGANIC_MATTER_MAX, omBefore + (ri.OM * factor))
        if omAfter > omBefore then
            field.organicMatter = omAfter
            changed = true
        end

        local dN, dP, dK = ri.N * factor, ri.P * factor, ri.K * factor
        field.nitrogen   = math.min(limits.MAX, (field.nitrogen   or 0) + dN)
        field.phosphorus = math.min(limits.MAX, (field.phosphorus or 0) + dP)
        field.potassium  = math.min(limits.MAX, (field.potassium  or 0) + dK)
        changed = true
        SoilLogger.debug("Residue incorporation (plowing) field %d: +N%.4f +P%.4f +K%.4f (factor %.4f)",
            fieldId, dN, dP, dK, factor)

        -- Local zoneData update for HUD/PDA visibility
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                    pH = field.pH, OM = field.organicMatter,
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
            -- Cell-factor: area processed in THIS tick relative to one cell area (usually 0.01 ha)
            local cellFactor = areaHa / zone.CELL_AREA_HA
            cell.N = math.min(limits.MAX, cell.N + ri.N * cellFactor)
            cell.P = math.min(limits.MAX, cell.P + ri.P * cellFactor)
            cell.K = math.min(limits.MAX, cell.K + ri.K * cellFactor)
            cell.OM = math.min(limits.ORGANIC_MATTER_MAX, cell.OM + ri.OM * cellFactor)

            -- Pressure reductions per cell
            if self.settings.weedPressure then
                cell.weedPressure = math.max(0, (cell.weedPressure or field.weedPressure or 0) - (field.weedPressure or 0) * cellFactor)
            end
            if self.settings.pestPressure and SoilConstants.PLOWING.PEST_PRESSURE_REDUCTION then
                cell.pestPressure = math.max(0, (cell.pestPressure or field.pestPressure or 0) - SoilConstants.PLOWING.PEST_PRESSURE_REDUCTION * cellFactor)
            end
            if self.settings.diseasePressure and SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION then
                cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - SoilConstants.PLOWING.DISEASE_PRESSURE_REDUCTION * cellFactor)
            end
        end
    end

    if changed and g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._tillBroadcastTime then self._tillBroadcastTime = {} end
            local last = self._tillBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._tillBroadcastTime[fieldId] = now
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Called when a shallow cultivator passes over a field.
--- Partially reduces weed, pest, and disease pressure.
---@param fieldId number
---@param area number Area processed in hectares (e.g. from lastStatsArea)
function SoilFertilitySystem:onCultivation(fieldId, area)
    if not fieldId or fieldId <= 0 then return end
    if not SoilConstants.CULTIVATION then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    local areaHa = area or 0.001
    local fieldAreaHa = field.fieldArea and field.fieldArea > 0 and field.fieldArea or 1.0

    -- Per-day area accumulation cap (same rationale as onPlowing).
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if not self._cultivAreaToday then self._cultivAreaToday = {} end
    local centry = self._cultivAreaToday[fieldId]
    if not centry or centry.day ~= today then
        centry = { day = today, used = 0 }
        self._cultivAreaToday[fieldId] = centry
    end
    local cclampedArea = math.min(areaHa, math.max(0, fieldAreaHa - centry.used))
    if cclampedArea <= 0 then return end
    centry.used = centry.used + cclampedArea
    local factor = cclampedArea / fieldAreaHa

    local changed = false
    local c = SoilConstants.CULTIVATION

    if self.settings.weedPressure and c.WEED_PRESSURE_REDUCTION and (field.weedPressure or 0) > 0 then
        local before = field.weedPressure
        local reduction = c.WEED_PRESSURE_REDUCTION * factor
        field.weedPressure = math.max(0, before - reduction)
        changed = true
    end

    if self.settings.pestPressure and c.PEST_PRESSURE_REDUCTION and (field.pestPressure or 0) > 0 then
        local before = field.pestPressure
        local reduction = c.PEST_PRESSURE_REDUCTION * factor
        field.pestPressure = math.max(0, before - reduction)
        changed = true
    end

    if self.settings.diseasePressure and c.DISEASE_PRESSURE_REDUCTION and (field.diseasePressure or 0) > 0 then
        local before = field.diseasePressure
        local reduction = c.DISEASE_PRESSURE_REDUCTION * factor
        field.diseasePressure = math.max(0, before - reduction)
        changed = true
    end

    -- Residue incorporation: shallow cultivation mixes surface straw residue into topsoil.
    -- Releases smaller amounts than deep plowing (only topsoil mixing, no burial).
    if self.settings.residueIncorporation and SoilConstants.RESIDUE_INCORPORATION then
        local ri     = SoilConstants.RESIDUE_INCORPORATION.CULTIVATOR
        local limits = SoilConstants.NUTRIENT_LIMITS
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omAfter  = math.min(limits.ORGANIC_MATTER_MAX, omBefore + (ri.OM * factor))
        if omAfter > omBefore then
            field.organicMatter = omAfter
            changed = true
        end

        local dN, dP, dK = ri.N * factor, ri.P * factor, ri.K * factor
        field.nitrogen   = math.min(limits.MAX, (field.nitrogen   or 0) + dN)
        field.phosphorus = math.min(limits.MAX, (field.phosphorus or 0) + dP)
        field.potassium  = math.min(limits.MAX, (field.potassium  or 0) + dK)
        changed = true
        SoilLogger.debug("Residue incorporation (cultivation) field %d: +N%.4f +P%.4f +K%.4f (factor %.4f)",
            fieldId, dN, dP, dK, factor)

        -- Local zoneData update for HUD/PDA visibility
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                    pH = field.pH, OM = field.organicMatter,
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
            local cellFactor = areaHa / zone.CELL_AREA_HA
            cell.N = math.min(limits.MAX, cell.N + ri.N * cellFactor)
            cell.P = math.min(limits.MAX, cell.P + ri.P * cellFactor)
            cell.K = math.min(limits.MAX, cell.K + ri.K * cellFactor)
            cell.OM = math.min(limits.ORGANIC_MATTER_MAX, cell.OM + ri.OM * cellFactor)

            -- Pressure reductions per cell
            if self.settings.weedPressure and c.WEED_PRESSURE_REDUCTION then
                cell.weedPressure = math.max(0, (cell.weedPressure or field.weedPressure or 0) - c.WEED_PRESSURE_REDUCTION * cellFactor)
            end
            if self.settings.pestPressure and c.PEST_PRESSURE_REDUCTION then
                cell.pestPressure = math.max(0, (cell.pestPressure or field.pestPressure or 0) - c.PEST_PRESSURE_REDUCTION * cellFactor)
            end
            if self.settings.diseasePressure and c.DISEASE_PRESSURE_REDUCTION then
                cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - c.DISEASE_PRESSURE_REDUCTION * cellFactor)
            end
        end
    end

    if changed and g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._tillBroadcastTime then self._tillBroadcastTime = {} end
            local last = self._tillBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._tillBroadcastTime[fieldId] = now
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Called when a ridge tiller / strip-till implement passes over a field.
--- Strip-till tills narrow deep knife-bands (~30% surface coverage), so
--- weed control is partial but pest disruption is deeper than cultivation.
--- No pH normalization (no soil-layer inversion). Small OM boost.
---@param fieldId number
---@param area number Area processed in hectares
function SoilFertilitySystem:onStripTill(fieldId, area)
    if not fieldId or fieldId <= 0 then return end
    if not SoilConstants.STRIP_TILL then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    local areaHa = area or 0.001
    local fieldAreaHa = field.fieldArea and field.fieldArea > 0 and field.fieldArea or 1.0
    local factor = areaHa / fieldAreaHa

    local st = SoilConstants.STRIP_TILL
    local changed = false

    -- Partial weed suppression (only tilled strips are disrupted)
    if self.settings.weedPressure and (field.weedPressure or 0) > 0 then
        local before = field.weedPressure
        field.weedPressure = math.max(0, before - st.WEED_PRESSURE_REDUCTION * factor)
        changed = true
    end

    -- Deep knife action disrupts soil-dwelling pest larvae (better than cultivator)
    if self.settings.pestPressure and (field.pestPressure or 0) > 0 then
        local before = field.pestPressure
        field.pestPressure = math.max(0, before - st.PEST_PRESSURE_REDUCTION * factor)
        changed = true
    end

    -- Minimal disease benefit — residue stays on surface between strips
    if self.settings.diseasePressure and (field.diseasePressure or 0) > 0 then
        local before = field.diseasePressure
        field.diseasePressure = math.max(0, before - st.DISEASE_PRESSURE_REDUCTION * factor)
        changed = true
    end

    -- Small OM boost from subsurface incorporation in tilled strips
    if st.OM_BOOST and st.OM_BOOST > 0 then
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omAfter  = math.min(SoilConstants.NUTRIENT_LIMITS.ORGANIC_MATTER_MAX,
                                  omBefore + st.OM_BOOST * factor)
        if omAfter > omBefore then
            field.organicMatter = omAfter
            changed = true
        end
    end

    -- Residue incorporation: strip-till knifes work only tilled strips (~30% of surface),
    -- so residue nutrient release is the smallest of all tillage types.
    if self.settings.residueIncorporation and SoilConstants.RESIDUE_INCORPORATION then
        local ri     = SoilConstants.RESIDUE_INCORPORATION.STRIP_TILL
        local limits = SoilConstants.NUTRIENT_LIMITS

        local dN, dP, dK = ri.N * factor, ri.P * factor, ri.K * factor
        field.nitrogen   = math.min(limits.MAX, (field.nitrogen   or 0) + dN)
        field.phosphorus = math.min(limits.MAX, (field.phosphorus or 0) + dP)
        field.potassium  = math.min(limits.MAX, (field.potassium  or 0) + dK)
        changed = true
        SoilLogger.debug("Residue incorporation (strip-till) field %d: +N%.4f +P%.4f +K%.4f (factor %.4f)",
            fieldId, dN, dP, dK, factor)

        -- Local zoneData update for HUD/PDA visibility
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                    pH = field.pH, OM = field.organicMatter,
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
            local cellFactor = areaHa / zone.CELL_AREA_HA
            cell.N = math.min(limits.MAX, cell.N + ri.N * cellFactor)
            cell.P = math.min(limits.MAX, cell.P + ri.P * cellFactor)
            cell.K = math.min(limits.MAX, cell.K + ri.K * cellFactor)
            cell.OM = math.min(limits.ORGANIC_MATTER_MAX, cell.OM + ri.OM * cellFactor)

            -- Pressure reductions per cell for strip-till
            if self.settings.weedPressure then
                cell.weedPressure = math.max(0, (cell.weedPressure or field.weedPressure or 0) - st.WEED_PRESSURE_REDUCTION * cellFactor)
            end
            if self.settings.pestPressure then
                cell.pestPressure = math.max(0, (cell.pestPressure or field.pestPressure or 0) - st.PEST_PRESSURE_REDUCTION * cellFactor)
            end
            if self.settings.diseasePressure then
                cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - st.DISEASE_PRESSURE_REDUCTION * cellFactor)
            end
        end
    end

    if changed and g_server and g_currentMission
       and g_currentMission.missionDynamicInfo
       and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._tillBroadcastTime then self._tillBroadcastTime = {} end
            local last = self._tillBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._tillBroadcastTime[fieldId] = now
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Called when herbicide is applied to a field.
--- Reduces weed pressure and activates suppression window.
---@param fieldId number
---@param effectiveness number 0.0-1.0 herbicide effectiveness multiplier
function SoilFertilitySystem:onHerbicideApplied(fieldId, effectiveness)
    if not self.settings.weedPressure then return end
    if not SoilConstants.WEED_PRESSURE then return end

    local field = self:getOrCreateField(fieldId, false)
    if not field then return end

    -- Throttle: apply pressure reduction at most once per field per in-game day.
    -- The sprayer hook fires every frame (~60x/sec). Without this guard, a single
    -- pass applies the full reduction hundreds of times, instantly zeroing pressure.
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if self.herbicideAppliedDay[fieldId] == today then return end
    self.herbicideAppliedDay[fieldId] = today

    local wp = SoilConstants.WEED_PRESSURE
    local reduction = wp.HERBICIDE_PRESSURE_REDUCTION * (effectiveness or 1.0)
    local before = field.weedPressure or 0
    field.weedPressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.herbicideDaysLeft = wp.HERBICIDE_DURATION_DAYS * daysPerMonth

    self:log("[Herbicide] Field %d: weed pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.weedPressure, field.herbicideDaysLeft)

    -- Broadcast in multiplayer
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end
end

--- Called when insecticide is applied to a field.
---@param fieldId number
---@param effectiveness number 0.0-1.0 insecticide effectiveness multiplier
function SoilFertilitySystem:onInsecticideApplied(fieldId, effectiveness)
    if not self.settings.pestPressure then return end
    if not SoilConstants.PEST_PRESSURE then return end

    local field = self:getOrCreateField(fieldId, false)
    if not field then return end

    -- Throttle: once per field per in-game day (see onHerbicideApplied for rationale)
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if self.insecticideAppliedDay[fieldId] == today then return end
    self.insecticideAppliedDay[fieldId] = today

    local pp = SoilConstants.PEST_PRESSURE
    local reduction = pp.INSECTICIDE_PRESSURE_REDUCTION * (effectiveness or 1.0)
    local before = field.pestPressure or 0
    field.pestPressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.insecticideDaysLeft = pp.INSECTICIDE_DURATION_DAYS * daysPerMonth

    self:log("[Insecticide] Field %d: pest pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.pestPressure, field.insecticideDaysLeft)

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end
end

--- Called when fungicide is applied to a field.
---@param fieldId number
---@param effectiveness number 0.0-1.0 fungicide effectiveness multiplier
function SoilFertilitySystem:onFungicideApplied(fieldId, effectiveness)
    if not self.settings.diseasePressure then return end
    if not SoilConstants.DISEASE_PRESSURE then return end

    local field = self:getOrCreateField(fieldId, false)
    if not field then return end

    -- Throttle: once per field per in-game day (see onHerbicideApplied for rationale)
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if self.fungicideAppliedDay[fieldId] == today then return end
    self.fungicideAppliedDay[fieldId] = today

    local dp = SoilConstants.DISEASE_PRESSURE
    local reduction = dp.FUNGICIDE_PRESSURE_REDUCTION * (effectiveness or 1.0)
    local before = field.diseasePressure or 0
    field.diseasePressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.fungicideDaysLeft = dp.FUNGICIDE_DURATION_DAYS * daysPerMonth

    self:log("[Fungicide] Field %d: disease pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.diseasePressure, field.fungicideDaysLeft)

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end
end

-- Hook delegate: called by HookManager on environment update
function SoilFertilitySystem:onEnvironmentUpdate(env, dt)
    -- Daily soil updates
    local currentDay = env.currentDay or 0
    if currentDay ~= self.lastUpdateDay then
        self.lastUpdateDay = currentDay
        self:updateDailySoil()
    end

    -- Rain effects
    if self.settings.rainEffects and env.weather then
        local rainScale = env.weather:getRainFallScale()
        if rainScale and rainScale > SoilConstants.RAIN.MIN_RAIN_THRESHOLD then
            self:applyRainEffects(dt, rainScale)
        end
    end
end

-- Logging helpers
function SoilFertilitySystem:log(msg, ...)
    SoilLogger.debug(msg, ...)
end

function SoilFertilitySystem:info(msg, ...)
    SoilLogger.info(msg, ...)
end

function SoilFertilitySystem:warning(msg, ...)
    SoilLogger.warning(msg, ...)
end

-- Notification helper
function SoilFertilitySystem:showNotification(title, message)
    if not self.settings or not self.settings.showNotifications then return end

    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(title .. ": " .. message, 6000)
    else
        self:info("%s - %s", title, message)
    end
end

-- Update function called every frame
function SoilFertilitySystem:update(dt)
    if not self.settings.enabled then return end

    self.lastUpdate = self.lastUpdate + dt

    if self.lastUpdate >= self.updateInterval then
        self.lastUpdate = 0
        -- Periodic checks could go here
    end

    -- Handle network sync retry for multiplayer clients
    if SoilNetworkEvents_UpdateSyncRetry then
        SoilNetworkEvents_UpdateSyncRetry(dt)
    end

    -- =========================================================
    -- PHASE 4: Batched daily field processing
    -- =========================================================
    -- Drains the queue set by updateDailySoil() at DAILY_BATCH_SIZE
    -- fields per frame so no single frame pays the full update cost.
    if self._pendingDailyUpdate then
        -- Guard: clients must never run the daily simulation.
        -- Field data is authoritative on the server and pushed via SoilFieldUpdateEvent.
        if g_server == nil then
            self._pendingDailyUpdate = false
            return
        end

        -- Lazily rebuild ordered list if membership changed
        if self._activeListDirty then
            self:_rebuildActiveList()
        end

        local list = self._activeFieldList
        local n    = #list

        if n == 0 then
            -- No owned fields — batch is trivially complete
            self._pendingDailyUpdate = false
            SoilLogger.debug("[PERF-P4] Day %d daily batch: 0 active fields, nothing to process",
                self._dailyBatchDay)
        else
            local processed = 0
            local cursor    = self._dailyBatchCursor

            while processed < self.DAILY_BATCH_SIZE and cursor < n do
                cursor = cursor + 1
                local fid = list[cursor]
                local fd  = self.fieldData[fid]
                if fd then
                    self:_processOneDailyField(fid, fd)
                    processed = processed + 1
                end
            end

            self._dailyBatchCursor = cursor

            if cursor >= n then
                -- Batch complete for today
                self._pendingDailyUpdate = false
                -- Update lastSeason only after the full pass so all fields see the
                -- same spring-transition flag (captured at batch-queue time).
                self.lastSeason = self._dailyBatchSeason
                SoilLogger.debug("[PERF-P4] Day %d daily batch complete: %d field(s) in final slice, %d total",
                    self._dailyBatchDay, processed, n)
            else
                SoilLogger.debug("[PERF-P4] Day %d batch progress: cursor %d/%d (+%d this frame)",
                    self._dailyBatchDay, cursor, n, processed)
            end
        end
    end
end

-- Scan all fields from FieldManager
---@return boolean True if successfully scanned fields, false if fields not ready yet
function SoilFertilitySystem:scanFields()
    -- Guard: clients must not create local fieldData.
    -- Soil values are authoritative on the server and arrive via network sync events.
    if g_currentMission
       and g_currentMission.missionDynamicInfo
       and g_currentMission.missionDynamicInfo.isMultiplayer
       and g_server == nil then
        self:info("Client: skipping local field scan — waiting for server sync")
        self.fieldsScanPending = false
        return true   -- signal 'done' to suppress further retries
    end

    if not g_fieldManager or not g_fieldManager.fields then
        self:warning("FieldManager not available yet")
        return false
    end

    if next(g_fieldManager.fields) == nil then
        self:log("FieldManager fields table empty - not ready yet")
        return false
    end

    self:log("Scanning fields via FieldManager...")

    local fieldCount = 0
    local farmlandCount = 0

    -- Count farmlands (for logging only)
    if g_farmlandManager and g_farmlandManager.farmlands then
        for _ in pairs(g_farmlandManager.farmlands) do
            farmlandCount = farmlandCount + 1
        end
    end

    -- TRUE FS25 SOURCE OF TRUTH
    -- field.fieldId / field.id / field.index do NOT exist in FS25 — all return nil.
    -- The correct field identifier is field.farmland.id (confirmed in-game).
    -- g_currentMission.fieldManager does not exist; use the global g_fieldManager.fields table directly.
    if not g_fieldManager or not g_fieldManager.fields then
        self:warning("g_fieldManager.fields not available — scan deferred")
        return false
    end
    local fields = g_fieldManager.fields
    -- ipairs is safe on FS25's C++ backed fields table; pairs can trigger __pairs metamethods
    -- and freeze on large maps. Use ipairs for the primary scan.
    for _, field in ipairs(fields) do
        if field and type(field) == "table" then
            local actualFieldId = field.farmland and field.farmland.id

            if actualFieldId and actualFieldId > 0 then
                -- Farmland.areaInHa is loaded from XML and always populated (default 2.5 ha).
                -- Field.areaHa is computed from polygon geometry but defaults to 1.0 in Field.new()
                -- before the polygon loads — 1.0 is truthy in Lua, so using field.areaHa first
                -- means the farmland fallback would NEVER fire for un-loaded polygons, causing
                -- every field to be recorded as exactly 1 ha regardless of actual size.
                -- Use farmland.areaInHa as the primary source; field.areaHa only as fallback.
                local area = (field.farmland and field.farmland.areaInHa) or field.areaHa or 1.0

                SoilLogger.debug("Found field %d (%.2f ha)", actualFieldId, area)

                local isNew = self.fieldData[actualFieldId] == nil
                self:getOrCreateField(actualFieldId, true, area)

                -- If this is a newly created field and density layers are available,
                -- read existing layer values (pre-seeded GRLE) instead of using defaults.
                if isNew and self.layerSystem and self.layerSystem.available and field.farmland then
                    self.layerSystem:readFieldFromLayers(actualFieldId, self.fieldData[actualFieldId], field.farmland)
                end

                -- PHASE 1: only owned farmlands enter the active simulation set.
                -- Unowned land still gets fieldData but is excluded from daily updates.
                if g_farmlandManager then
                    local farmlandOwner = g_farmlandManager:getFarmlandOwner(actualFieldId)
                    if farmlandOwner and farmlandOwner > 0 then
                        self:_addToActiveSet(actualFieldId)
                    end
                end

                fieldCount = fieldCount + 1
            end
        end
    end

    -- SECONDARY SCAN: catch farmlands whose field entry was unreachable via ipairs on
    -- large/custom maps where g_fieldManager.fields has non-sequential indices (64x maps).
    if g_farmlandManager and g_farmlandManager.farmlands then
        for farmlandId, farmlandObj in pairs(g_farmlandManager.farmlands) do
            if type(farmlandId) == "number" and farmlandId > 0 and not self.fieldData[farmlandId] then
                local flArea = (farmlandObj and farmlandObj.areaInHa) or 1.0
                self:getOrCreateField(farmlandId, true, flArea)
                fieldCount = fieldCount + 1
                SoilLogger.debug("Secondary scan caught missed farmland %d (%.2f ha)", farmlandId, flArea)
            end
        end
    end

    self:info("Scanned %d farmlands and initialized %d fields", farmlandCount, fieldCount)

    if fieldCount > 0 then
        self.fieldsScanPending = false

        -- Broadcast all field data to connected clients immediately after scan.
        -- Without this, clients on a dedicated server never receive the initial state
        -- because per-field syncs only fire on harvest / fertilizer events.
        self:broadcastAllFieldData()

        return true
    end

    return false
end

--- Broadcast every tracked field to all connected clients.
--- Called once after a successful field scan and can be called again
--- at any time to force a full re-sync (e.g. after a save/load cycle).
function SoilFertilitySystem:broadcastAllFieldData()
    if not g_server then return end
    if not g_currentMission then return end
    if not (g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer) then return end
    if not SoilFieldBatchSyncEvent then return end

    local fieldIds = {}
    for fieldId in pairs(self.fieldData) do
        table.insert(fieldIds, fieldId)
    end
    local fieldCount = #fieldIds
    if fieldCount == 0 then return end

    local batchSize  = SoilConstants.NETWORK.FULL_SYNC_BATCH_SIZE
    local batchDelay = SoilConstants.NETWORK.FULL_SYNC_BATCH_DELAY
    local totalBatches = math.ceil(fieldCount / batchSize)
    local fieldData = self.fieldData

    if g_dedicatedServer then
        -- Dedicated server: send all batches synchronously (no live rendering pressure)
        self:info("Broadcasting %d fields to all clients in %d synchronous batches", fieldCount, totalBatches)
        for batchIndex = 1, totalBatches do
            local startIdx = (batchIndex - 1) * batchSize + 1
            local endIdx   = math.min(batchIndex * batchSize, fieldCount)
            local batch = {}
            for i = startIdx, endIdx do
                local id = fieldIds[i]
                batch[id] = fieldData[id]
            end
            local isLast = (batchIndex == totalBatches)
            g_server:broadcastEvent(SoilFieldBatchSyncEvent.new(batch, isLast))
        end
    else
        -- Listen server: drip-feed batches across frames to avoid a single-frame spike
        self:info("Broadcasting %d fields to all clients in %d batched frames", fieldCount, totalBatches)
        local batchDispatcher = {
            batchIndex   = 1,
            totalBatches = totalBatches,
            batchSize    = batchSize,
            batchDelay   = batchDelay,
            timer        = 0,
            fieldIds     = fieldIds,
            fieldData    = fieldData,
            update = function(self, dt)
                if self.batchIndex > self.totalBatches then
                    g_currentMission:removeUpdateable(self)
                    return
                end
                self.timer = self.timer + dt
                if self.timer < self.batchDelay then return end
                self.timer = 0
                local startIdx = (self.batchIndex - 1) * self.batchSize + 1
                local endIdx   = math.min(self.batchIndex * self.batchSize, #self.fieldIds)
                local batch = {}
                for i = startIdx, endIdx do
                    local id = self.fieldIds[i]
                    batch[id] = self.fieldData[id]
                end
                local isLast = (self.batchIndex == self.totalBatches)
                g_server:broadcastEvent(SoilFieldBatchSyncEvent.new(batch, isLast))
                self.batchIndex = self.batchIndex + 1
                if self.batchIndex > self.totalBatches then
                    g_currentMission:removeUpdateable(self)
                end
            end,
            delete = function(self)
                g_currentMission:removeUpdateable(self)
            end
        }
        g_currentMission:addUpdateable(batchDispatcher)
    end
end

--- Send all tracked field data to a single newly-joined client.
--- Called from FSBaseMission.onClientConnected via HookManager.
---@param connection table The network connection object for the joining client
function SoilFertilitySystem:onClientJoined(connection)
    if g_server == nil then return end
    if not connection then return end
    if not SoilFieldUpdateEvent then return end

    local count = 0
    for fieldId, field in pairs(self.fieldData) do
        connection:sendEvent(SoilFieldUpdateEvent.new(fieldId, field))
        count = count + 1
    end

    self:info("Sent %d fields to newly joined client", count)
end

-- =========================================================
-- PHASE 1: Active set management
-- =========================================================
-- Owned fields are tracked in activeFieldIds {[fieldId]=true} so that
-- daily simulation, rain leaching, and pressure growth only iterate
-- the subset of fields the player actually owns — skipping the potentially
-- hundreds of unowned parcels on a large map.
--
-- _activeFieldList is a sorted array derived from the set.  It is rebuilt
-- lazily whenever _activeListDirty=true (on add/remove).  The batch cursor
-- indexes into this list so field processing is deterministic.

--- Add a field to the owned simulation set.
---@param fieldId number
function SoilFertilitySystem:_addToActiveSet(fieldId)
    if not self.activeFieldIds[fieldId] then
        self.activeFieldIds[fieldId] = true
        self._activeListDirty = true
        SoilLogger.debug("[PERF-P1] Field %d → active set (owned)", fieldId)
    end
end

--- Remove a field from the owned simulation set.
---@param fieldId number
function SoilFertilitySystem:_removeFromActiveSet(fieldId)
    if self.activeFieldIds[fieldId] then
        self.activeFieldIds[fieldId] = nil
        self._activeListDirty = true
        SoilLogger.debug("[PERF-P1] Field %d ← active set (released)", fieldId)
    end
end

--- Rebuild the ordered array from the active set hash.
--- Called lazily before any indexed batch access.
function SoilFertilitySystem:_rebuildActiveList()
    local list = {}
    for fieldId in pairs(self.activeFieldIds) do
        table.insert(list, fieldId)
    end
    table.sort(list)  -- stable order for deterministic batch processing
    self._activeFieldList = list
    self._activeListDirty = false
    SoilLogger.debug("[PERF-P1] Active list rebuilt: %d owned field(s)", #list)
end

-- Get or create field data
function SoilFertilitySystem:getOrCreateField(fieldId, createIfMissing, area)
    if not fieldId or fieldId <= 0 then return nil end

    -- Return existing field
    if self.fieldData[fieldId] then
        -- Update area if provided (handles initial scan or later updates)
        if area and area > 0 then
            self.fieldData[fieldId].fieldArea = area
        end
        return self.fieldData[fieldId]
    end

    -- Don't create if not requested
    if not createIfMissing then
        return nil
    end

    -- MULTIPLAYER SAFETY: Only server should create new fields
    -- Clients must wait for sync to avoid desync issues with randomized initial values
    if g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if g_server == nil then
            -- Client in multiplayer - return nil and wait for server sync
            return nil
        end
    end

    -- Allow lazy creation (HUD-safe, server-only in multiplayer)
    -- Add natural soil variation: ±10% for nutrients, ±0.5 for pH, ±0.5% for OM
    -- This reflects real-world soil diversity across a map.
    --
    -- Use a deterministic hash instead of math.randomseed() to avoid polluting
    -- the global Lua random state (math.randomseed resets the shared PRNG, which
    -- disrupts any other code using math.random() in the same frame — e.g. during
    -- the initial bulk field scan where many fields are created simultaneously).
    local function hash(n)
        -- Lua 5.1-compatible deterministic hash (LCG-style, no bitwise ops).
        -- Produces a float in [0.0, 1.0) that is stable for the same (fieldId, slot) pair
        -- across save/load cycles. Avoids touching math.randomseed (global state).
        n = (n * 1664525 + 1013904223) % 4294967296
        n = (n * 1664525 + 1013904223) % 4294967296
        return n / 4294967296
    end
    local function randField(slot)
        -- Each nutrient gets its own deterministic slot so values are independent
        local r = hash(fieldId * 67890 + slot)
        return r * 2.0 - 1.0  -- range [-1.0, 1.0]
    end

    local function randomize(baseValue, variation, slot)
        return baseValue + randField(slot) * variation
    end

    local defaults = SoilConstants.FIELD_DEFAULTS

    -- Attempt farmland area lookup at creation time so the correct area is used
    -- for nutrient/herbicide calculations from the very first plow or spray pass.
    -- Without this, area defaults to 1.0 ha and only corrects on first fertilizer spray.
    local confirmedArea = false
    local initialArea = area or 1.0
    if not area and g_farmlandManager then
        local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
        if farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
            initialArea = farmlandObj.areaInHa
            confirmedArea = true
        end
    elseif area and area > 0 then
        confirmedArea = true
    end

    self.fieldData[fieldId] = {
        fieldArea = initialArea,
        _farmlandAreaConfirmed = confirmedArea,
        nitrogen   = math.floor(randomize(defaults.nitrogen,   defaults.nitrogen   * 0.10, 1)),
        phosphorus = math.floor(randomize(defaults.phosphorus, defaults.phosphorus * 0.10, 2)),
        potassium  = math.floor(randomize(defaults.potassium,  defaults.potassium  * 0.10, 3)),
        organicMatter = math.max(1.0, math.min(10.0, randomize(defaults.organicMatter, 0.5, 4))),
        pH            = math.max(5.0, math.min(8.5,  randomize(defaults.pH,            0.5, 5))),
        lastCrop = nil,
        lastCrop2 = nil,
        lastCrop3 = nil,
        rotationBonusDaysLeft = 0,
        lastHarvest = 0,
        fertilizerApplied = 0,
        initialized = true,
        weedPressure = 0,
        herbicideDaysLeft = 0,
        pestPressure = 0,
        insecticideDaysLeft = 0,
        diseasePressure = 0,
        fungicideDaysLeft = 0,
        dryDayCount = 0,
        nutrientBuffer = {},  -- Tracks [fillTypeIndex] = litersApplied (reset daily)
        zoneData = {},        -- Sparse {cellKey → {N,P,K,pH,OM}} for per-area overlay
        coveredCells = {},    -- Legacy: kept for daily reset compat (no longer used for coverage calc)
        coveredCellCount = 0, -- Legacy: kept for daily reset compat
        totalFieldCells = 0,  -- Legacy: kept for daily reset compat
        coveredAreaHa = 0,    -- Hectares covered today (cell-dedup, reset daily)
        coverageFraction = 0, -- Fraction of field covered today (0.0–1.0)
        dailyCoverageCells = {},     -- Unique 10×10 m cells sprayed today (reset daily)
        sessionCoverageHa = 0,       -- Hectares covered this session (cell-dedup, resets on harvest)
        sessionCoverageFraction = 0, -- Derived 0.0–1.0 fraction for HUD display
        sessionCoverageCells = {},   -- Unique 10×10 m cells sprayed this session (resets on harvest)
        sessionLastProduct = nil,    -- Fill type name of last product applied this session
        compaction = 0,            -- field-average compaction 0–100 (derived from cells)
        compactionCells = {},      -- {cellKey → 0-100} per-cell compaction (10×10 m grid)
        compactionCellDays = {},   -- {cellKey → day} per-cell once-per-day throttle (transient)
        compactionSum = 0,         -- running sum of cell values for O(1) average
        compactionTotalCells = 0,  -- total estimated field cells (set lazily from fieldArea)
        lastAlertSeason = nil, -- Season when the last critical alert fired (persisted)
    }

    self:log("Lazy-created field %d area=%.2f ha confirmed=%s",
        fieldId, self.fieldData[fieldId].fieldArea, tostring(confirmedArea))
    return self.fieldData[fieldId]
end

-- Daily soil update — PHASE 4: converted to batch scheduler.
-- Instead of processing every field synchronously on the day-rollover tick
-- (which can stall for hundreds of ms on large maps), we queue work and
-- drain it across multiple frames via the update(dt) batch loop.
function SoilFertilitySystem:updateDailySoil()
    if not self.settings.enabled or not self.settings.nutrientCycles then return end

    local currentDay = (g_currentMission and g_currentMission.environment and
                        g_currentMission.environment.currentDay) or 0

    -- Guard: don't re-queue if already started a batch for today
    if self._pendingDailyUpdate and self._dailyBatchDay == currentDay then
        SoilLogger.debug("[PERF-P4] Day %d batch already queued, skipping duplicate trigger", currentDay)
        return
    end

    -- Snapshot current state for all per-field workers in this batch
    self._dailyBatchDay    = currentDay
    self._dailyBatchSeason = (g_currentMission and g_currentMission.environment and
                              g_currentMission.environment.currentSeason) or nil
    self._batchLastSeason  = self.lastSeason  -- spring-transition check uses PREVIOUS season

    -- Rebuild ordered field list if ownership changed since last batch
    if self._activeListDirty then
        self:_rebuildActiveList()
    end

    self._pendingDailyUpdate = true
    self._dailyBatchCursor   = 0

    SoilLogger.debug("[PERF-P4] Day %d: queued daily update for %d active field(s) (batch=%d/frame)",
        currentDay, #self._activeFieldList, self.DAILY_BATCH_SIZE)
end

--- Process daily simulation for ONE field.
-- Extracted from the old synchronous updateDailySoil() loop body.
-- Called by the update(dt) batch dispatcher DAILY_BATCH_SIZE times per frame.
-- Uses snapshotted day/season values stored on self to avoid per-call lookups.
---@param fieldId number
---@param field table  fieldData entry (pre-validated non-nil by caller)
function SoilFertilitySystem:_processOneDailyField(fieldId, field)
    local limits   = SoilConstants.NUTRIENT_LIMITS
    local recovery = SoilConstants.FALLOW_RECOVERY
    local seasonal = SoilConstants.SEASONAL_EFFECTS
    local phNorm   = SoilConstants.PH_NORMALIZATION
    -- Use snapshots captured at batch-queue time for consistency across all fields
    local currentDay = self._dailyBatchDay
    local season     = self._dailyBatchSeason

    -- Time scaling (Issue #349): normalize daily changes based on month length.
    -- All 'per day' rates are scaled by 1/daysPerMonth so that the total change
    -- per month remains constant regardless of the days-per-period setting.
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local timeFactor = 1.0 / daysPerMonth

    -- ── Buffer / coverage reset ──────────────────────────────────────────────
    field.nutrientBuffer          = {}
    field.coveredCells            = {}
    field.coveredCellCount        = 0
    field.coveredAreaHa           = 0
    field.coverageFraction        = 0
    field.dailyCoverageCells      = {}
    field._covLastX               = nil
    field._covLastZ               = nil
    field._farmlandAreaConfirmed  = nil

    -- ── Compaction natural decay ─────────────────────────────────────────────
    if self.settings.compactionEnabled and SoilConstants.COMPACTION then
        local cp = SoilConstants.COMPACTION
        if (field.compaction or 0) > 0 then
            field.compaction = math.max(0, field.compaction - cp.NATURAL_DECAY_PER_DAY * timeFactor)
        end
    end

    -- ── Fallow recovery ──────────────────────────────────────────────────────
    -- Fallow threshold also scales so it represents the same 'agricultural time' (months)
    local daysSinceFallow = currentDay - (field.lastHarvest or 0)
    if daysSinceFallow > SoilConstants.TIMING.FALLOW_THRESHOLD * daysPerMonth then
        field.nitrogen      = math.min(limits.MAX, field.nitrogen      + recovery.nitrogen * timeFactor)
        field.phosphorus    = math.min(limits.MAX, field.phosphorus    + recovery.phosphorus * timeFactor)
        field.potassium     = math.min(limits.MAX, field.potassium     + recovery.potassium * timeFactor)
        field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX,
                                       field.organicMatter + recovery.organicMatter * timeFactor)
    end

    -- ── Seasonal nitrogen shift ──────────────────────────────────────────────
    if self.settings.seasonalEffects and season then
        if season == seasonal.SPRING_SEASON then
            field.nitrogen = math.min(limits.MAX, field.nitrogen + seasonal.SPRING_NITROGEN_BOOST * timeFactor)
        elseif season == seasonal.FALL_SEASON then
            field.nitrogen = math.max(limits.MIN, field.nitrogen - seasonal.FALL_NITROGEN_LOSS * timeFactor)
        end
    end

    -- ── Crop rotation spring bonus ───────────────────────────────────────────
    if self.settings.cropRotation and season then
        -- First day of spring transition: initialise bonus counter if eligible
        if season == seasonal.SPRING_SEASON and self._batchLastSeason ~= seasonal.SPRING_SEASON then
            if field.lastCrop and field.lastCrop2 then
                local cr = SoilConstants.CROP_ROTATION
                local c1 = string.lower(field.lastCrop)
                local c2 = string.lower(field.lastCrop2)
                if cr.LEGUMES[c1] and not cr.LEGUMES[c2]
                   and (field.rotationBonusDaysLeft or 0) == 0 then
                    -- Bonus duration also scales to match month length
                    field.rotationBonusDaysLeft = cr.LEGUME_BONUS_DAYS * daysPerMonth
                end
            end
        end
        -- Apply daily bonus while counter > 0 during spring
        if season == seasonal.SPRING_SEASON and (field.rotationBonusDaysLeft or 0) > 0 then
            local cr = SoilConstants.CROP_ROTATION
            field.nitrogen = math.min(limits.MAX, field.nitrogen + cr.LEGUME_BONUS_N_PER_DAY * timeFactor)
            field.rotationBonusDaysLeft = field.rotationBonusDaysLeft - 1
        end
    end

    -- ── pH slow drift toward neutral ─────────────────────────────────────────
    if field.pH < limits.PH_NEUTRAL_LOW then
        field.pH = math.min(limits.PH_NEUTRAL_LOW, field.pH + phNorm.RATE * timeFactor)
    elseif field.pH > limits.PH_NEUTRAL_HIGH then
        field.pH = math.max(limits.PH_NEUTRAL_HIGH, field.pH - phNorm.RATE * timeFactor)
    end

    -- ── Weed pressure — sourced from game's native weed density map ─────────
    -- weedPressure is now derived from FieldState.weedFactor (the game's weed
    -- density map) rather than a hand-rolled accumulation model. This means
    -- plant canopy closure, herbicide, cultivation and plowing all suppress
    -- weeds through the game's own systems; we just read the result each day.
    if self.settings.weedPressure and SoilConstants.WEED_PRESSURE then
        local cropLower = field.lastCrop and string.lower(field.lastCrop) or nil
        local isGrassland = cropLower and
            SoilConstants.YIELD_SENSITIVITY and
            SoilConstants.YIELD_SENSITIVITY.NON_CROP_NAMES and
            SoilConstants.YIELD_SENSITIVITY.NON_CROP_NAMES[cropLower]

        if not isGrassland then
            local wp = SoilConstants.WEED_PRESSURE

            -- Tick herbicideDaysLeft for HUD display only (game handles suppression)
            if (field.herbicideDaysLeft or 0) > 0 then
                field.herbicideDaysLeft = field.herbicideDaysLeft - 1
            end

            -- Sample FieldState.weedFactor from the game's weed density map.
            -- weedFactor: 1.0 = clean, <1.0 = weeds present (same scale as
            -- sprayFactor / plowFactor used in getHarvestScaleMultiplier).
            local gameWeedFactor = 1.0
            if g_fieldManager and g_fieldManager.fields then
                local fsField = g_fieldManager.fields[fieldId]
                if not fsField then
                    for _, f in ipairs(g_fieldManager.fields) do
                        if f and (f.fieldId == fieldId or f.id == fieldId) then
                            fsField = f
                            break
                        end
                    end
                end
                if fsField and fsField.posX and fsField.posZ then
                    local ok, fs = pcall(function()
                        local f = FieldState.new()
                        f:update(fsField.posX, fsField.posZ)
                        return f
                    end)
                    -- Only trust weedFactor when a crop is present.
                    -- On bare/plowed fields FS25 leaves weedFactor=0 (its default),
                    -- and (1-0)*100 = 100 even though there are genuinely no weeds.
                    -- In Lua, 0 is truthy so "or 1.0" never fires — explicit guard needed.
                    if ok and fs and fs.isValid and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
                        gameWeedFactor = fs.weedFactor
                    end
                end
            end
            field.weedPressure = math.max(0, math.min(100, (1.0 - gameWeedFactor) * 100))

            -- Weeds consume nutrients
            if field.weedPressure > 0 then
                local pRatio = field.weedPressure / 100
                field.nitrogen   = math.max(limits.MIN, field.nitrogen   - (wp.NUTRIENT_DEPLETION_N or 0) * pRatio * timeFactor)
                field.phosphorus = math.max(limits.MIN, field.phosphorus - (wp.NUTRIENT_DEPLETION_P or 0) * pRatio * timeFactor)
                field.potassium  = math.max(limits.MIN, field.potassium  - (wp.NUTRIENT_DEPLETION_K or 0) * pRatio * timeFactor)
            end
        end
    end

    -- ── Pest pressure daily growth ───────────────────────────────────────────
    if self.settings.pestPressure and SoilConstants.PEST_PRESSURE then
        local pp = SoilConstants.PEST_PRESSURE

        if (field.insecticideDaysLeft or 0) > 0 then
            field.insecticideDaysLeft = field.insecticideDaysLeft - 1
        end

        if (field.insecticideDaysLeft or 0) <= 0 then
            local pressure = field.pestPressure or 0
            local baseRate
            if     pressure < pp.LOW    then baseRate = pp.GROWTH_RATE_LOW
            elseif pressure < pp.MEDIUM then baseRate = pp.GROWTH_RATE_MID
            elseif pressure < pp.HIGH   then baseRate = pp.GROWTH_RATE_HIGH
            else                             baseRate = pp.GROWTH_RATE_PEAK
            end

            local seasonMult = 1.0
            if season then
                if     season == 1 then seasonMult = pp.SEASONAL_SPRING
                elseif season == 2 then seasonMult = pp.SEASONAL_SUMMER
                elseif season == 3 then seasonMult = pp.SEASONAL_FALL
                elseif season == 4 then seasonMult = pp.SEASONAL_WINTER
                end
            end

            local cropMult = 1.0
            if field.lastCrop then
                cropMult = pp.CROP_SUSCEPTIBILITY[string.lower(field.lastCrop)] or 1.0
            end

            local rainBonus = 0
            if g_currentMission and g_currentMission.environment and
               g_currentMission.environment.weather then
                local rs = g_currentMission.environment.weather:getRainFallScale()
                if rs and rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD then rainBonus = pp.RAIN_BONUS end
            end

            field.pestPressure = math.min(100, pressure + ((baseRate * seasonMult * cropMult) + rainBonus) * timeFactor)
        end
    end

    -- ── Disease pressure daily growth ────────────────────────────────────────
    if self.settings.diseasePressure and SoilConstants.DISEASE_PRESSURE then
        local dp = SoilConstants.DISEASE_PRESSURE
        local isRaining = false
        if g_currentMission and g_currentMission.environment and g_currentMission.environment.weather then
            local rs = g_currentMission.environment.weather:getRainFallScale()
            isRaining = rs ~= nil and rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD
        end

        if isRaining then
            field.dryDayCount = 0
        else
            field.dryDayCount = (field.dryDayCount or 0) + 1
        end

        if (field.fungicideDaysLeft or 0) > 0 then
            field.fungicideDaysLeft = field.fungicideDaysLeft - 1
        end

        local pressure = field.diseasePressure or 0

        -- Dry days threshold also scales
        if (field.dryDayCount or 0) >= dp.DRY_DAYS_THRESHOLD * daysPerMonth then
            field.diseasePressure = math.max(0, pressure - dp.DRY_DECAY_RATE * timeFactor)
        elseif (field.fungicideDaysLeft or 0) <= 0 then
            local baseRate
            if     pressure < dp.LOW    then baseRate = dp.GROWTH_RATE_LOW
            elseif pressure < dp.MEDIUM then baseRate = dp.GROWTH_RATE_MID
            elseif pressure < dp.HIGH   then baseRate = dp.GROWTH_RATE_HIGH
            else                             baseRate = dp.GROWTH_RATE_PEAK
            end

            local seasonMult = 1.0
            if season then
                if     season == 1 then seasonMult = dp.SEASONAL_SPRING
                elseif season == 2 then seasonMult = dp.SEASONAL_SUMMER
                elseif season == 3 then seasonMult = dp.SEASONAL_FALL
                elseif season == 4 then seasonMult = dp.SEASONAL_WINTER
                end
            end

            local cropMult = 1.0
            if field.lastCrop then
                cropMult = dp.CROP_SUSCEPTIBILITY[string.lower(field.lastCrop)] or 1.0
            end

            local rainBonus = isRaining and dp.RAIN_BONUS or 0
            field.diseasePressure = math.min(100, pressure + ((baseRate * seasonMult * cropMult) + rainBonus) * timeFactor)
        end
    end

    -- ── Burn warning countdown ───────────────────────────────────────────────
    if (field.burnDaysLeft or 0) > 0 then
        field.burnDaysLeft = field.burnDaysLeft - 1
    end

    -- ── Critical field alert (once per season per owned field) ───────────────
    if self.settings.showNotifications and season then
        local threshold = SoilConstants.CRITICAL_ALERT_THRESHOLD or 50
        if field.lastAlertSeason ~= season then
            local urgency = self:getFieldUrgency(fieldId)
            if urgency > threshold then
                local isOwned = false
                local farmId = g_localPlayer and g_localPlayer.farmId
                if farmId and farmId > 0 and g_farmlandManager then
                    local owner = g_farmlandManager:getFarmlandOwner(fieldId)
                    if owner == farmId then isOwned = true end
                end
                if isOwned then
                    self:showNotification(g_i18n:getText("sf_notify_critical_title"),
                        string.format(g_i18n:getText("sf_notify_critical_body"),
                            fieldId, math.floor(urgency)))
                end
                field.lastAlertSeason = season
            end
        end
    end
end


-- Apply rain effects
-- PHASE 1: Only leach owned/active fields — unowned parcels don't need
-- per-frame nutrient calculations since no player is managing them.
-- NOTE: This function is called every frame during rain. The per-frame leach is
-- intentional and correctly physics-integrated via dt scaling, unlike the daily batch.
-- RWE active event id → leaching multiplier (applied to all nutrients during rain)
local RWE_LEACH_MULTIPLIERS = {
    fertilizer_penalty = 1.35,
    crop_yield_penalty = 1.20,
    fertilizer_bonus   = 0.80,
    crop_yield_bonus   = 0.85,
}

function SoilFertilitySystem:applyRainEffects(dt, rainScale)
    if not self.settings.enabled or not self.settings.rainEffects then return end

    local rain = SoilConstants.RAIN
    local limits = SoilConstants.NUTRIENT_LIMITS

    -- Scale leaching by active RWE event if present
    local rweMultiplier = 1.0
    local rwe = g_currentMission and g_currentMission.randomWorldEvents
    if rwe and rwe.EVENT_STATE then
        rweMultiplier = RWE_LEACH_MULTIPLIERS[rwe.EVENT_STATE.activeEvent] or 1.0
    end

    local leachFactor = rainScale * dt * rain.LEACH_BASE_FACTOR * rweMultiplier
    local count = 0

    -- Iterate only owned fields (activeFieldIds set, Phase 1)
    for fieldId in pairs(self.activeFieldIds) do
        local field = self.fieldData[fieldId]
        if field then
            field.nitrogen   = math.max(limits.MIN, field.nitrogen   - (leachFactor * rain.NITROGEN_MULTIPLIER))
            field.potassium  = math.max(limits.MIN, field.potassium  - (leachFactor * rain.POTASSIUM_MULTIPLIER))
            field.phosphorus = math.max(limits.MIN, field.phosphorus - (leachFactor * rain.PHOSPHORUS_MULTIPLIER))
            field.pH         = math.max(limits.PH_MIN, field.pH      - (leachFactor * rain.PH_ACIDIFICATION))
            count = count + 1
        end
    end

    SoilLogger.debug("[PERF-P1] Rain leach: %d active field(s), leachFactor=%.6f", count, leachFactor)
end

-- Update field nutrients after harvest
---@param fieldId number The field being harvested
---@param fruitTypeIndex number FS25 fruit type index
---@param harvestedLiters number 0/1 flag from addCutterArea (NOT actual grain volume — use area for depletion)
---@param strawRatio number 0.0-1.0 fraction of straw chopped back into the field (adds organic matter)
---@param area number Area harvested in pixels — always used for depletion; liters is unreliable
function SoilFertilitySystem:updateFieldNutrients(fieldId, fruitTypeIndex, harvestedLiters, strawRatio, area)
    if not self.settings.enabled or not self.settings.nutrientCycles then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then
        self:warning("Cannot update nutrients - field %d not found", fieldId)
        return
    end

    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if not fruitDesc then
        self:warning("Cannot update nutrients - fruit type %d not found", fruitTypeIndex)
        return
    end

    -- Shift crop history before recording new crop (lastCrop → lastCrop2 → lastCrop3)
    field.lastCrop3 = field.lastCrop2
    field.lastCrop2 = field.lastCrop

    -- Look up crop-specific extraction rates (how much N/P/K this crop removes from soil)
    -- Different crops have different nutrient demands:
    -- - Wheat/Barley: High nitrogen demand (leafy growth)
    -- - Corn/Maize: Very high N/P demand (large biomass)
    -- - Soybeans: Low nitrogen (fixes own N), moderate P/K
    -- - Potatoes/Sugar beets: High potassium demand (root/tuber crops)
    local name = string.lower(fruitDesc.name or "unknown")
    local rates = SoilConstants.CROP_EXTRACTION[name] or SoilConstants.CROP_EXTRACTION_DEFAULT

    -- Step 1: Calculate depletion factor from harvested area.
    -- addCutterArea fires many times per harvest; its liters parameter is a 0/1 flag
    -- (1 = crop present), NOT actual grain volume. Area is always the reliable value.
    -- factor = areaHa / fieldAreaHa  =>  proportional slice of field depleted this call.
    local fieldAreaHa = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0
    local factor
    local areaHa = 0
    if area and area > 0 then
        if not g_currentMission or type(g_currentMission.getFruitPixelsToSqm) ~= "function" then
            SoilLogger.debug("updateFieldNutrients: getFruitPixelsToSqm unavailable — skipping depletion for field %d", fieldId)
            return
        end
        areaHa = MathUtil.areaToHa(area, g_currentMission:getFruitPixelsToSqm())
        factor = (areaHa / fieldAreaHa) * SoilConstants.HARVEST_HA_FACTOR
        SoilLogger.debug("Harvest factor: area=%.0fpx areaHa=%.6f fieldHa=%.2f factor=%.6f", area, areaHa, fieldAreaHa, factor)
    else
        return
    end

    -- Step 2: Apply difficulty multiplier
    -- Simple (0.7x): 30% less depletion, easier for new players
    -- Realistic (1.0x): Balanced depletion based on real agricultural rates
    -- Hardcore (1.5x): 50% more depletion, challenging management
    local diffMultiplier = SoilConstants.DIFFICULTY.MULTIPLIERS[self.settings.difficulty]
    if diffMultiplier then
        factor = factor * diffMultiplier
    end

    -- Step 2b: Compaction penalty — compacted soil reduces nutrient uptake efficiency,
    -- causing crops to deplete more of what's available to achieve the same yield.
    if self.settings.compactionEnabled and SoilConstants.COMPACTION then
        local cp = SoilConstants.COMPACTION
        local compaction = field.compaction or 0
        if compaction > 0 then
            local penalty = (compaction / 100) * cp.NUTRIENT_PENALTY_MAX
            factor = factor * (1 + penalty)
        end
    end

    -- Step 3a: Crop rotation fatigue — same crop two seasons running depletes more
    if self.settings.cropRotation and field.lastCrop2 and field.lastCrop2 == fruitDesc.name then
        factor = factor * SoilConstants.CROP_ROTATION.FATIGUE_MULTIPLIER
        self:log("Rotation fatigue on field %d (%s harvested twice) — factor ×%.2f",
            fieldId, fruitDesc.name, SoilConstants.CROP_ROTATION.FATIGUE_MULTIPLIER)
    end

    -- Step 3b: Deplete nutrients from field
    -- Formula: new_value = max(0, current_value - (extraction_rate × factor))
    -- Scale: 0-100 nutrient points
    -- Example: N=50, wheat extraction=0.20, factor=80
    --          → 50 - (0.20 × 80) = 50 - 16 = 34 nitrogen remaining (~32% depletion)
    -- Only N/P/K deplete from harvest; pH and organic matter change through other means
    local limits = SoilConstants.NUTRIENT_LIMITS
    field.nitrogen   = math.max(limits.MIN, field.nitrogen   - rates.N * factor)
    field.phosphorus = math.max(limits.MIN, field.phosphorus - rates.P * factor)
    field.potassium  = math.max(limits.MIN, field.potassium  - rates.K * factor)

    -- Deplete zone cells by the same absolute amount (harvest extracts uniformly across field)
    if field.zoneData then
        local dN, dP, dK = rates.N * factor, rates.P * factor, rates.K * factor
        for _, cell in pairs(field.zoneData) do
            cell.N = math.max(limits.MIN, cell.N - dN)
            cell.P = math.max(limits.MIN, cell.P - dP)
            cell.K = math.max(limits.MIN, cell.K - dK)
        end
    end

    -- Step 4: Chopped straw/chaff adds organic matter.
    -- OM is a concentration, so gain scales by fraction of field harvested this call,
    -- not by absolute area. A full harvest at sr=1.0 adds exactly OM_RATE to the field.
    local sr = strawRatio or 0
    if sr > 0 and areaHa > 0 then
        local omGain = (areaHa / fieldAreaHa) * sr * SoilConstants.CHOPPED_STRAW.OM_RATE
        field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX, (field.organicMatter or 0) + omGain)
    end

    field.lastCrop = fruitDesc.name
    field.lastHarvest = (g_currentMission and g_currentMission.environment and g_currentMission.environment.currentDay) or 0

    self:log(
        "Harvest depletion field %d (%s): -N %.5f -P %.5f -K %.5f  straw sr=%.2f +OM %.5f",
        fieldId, fruitDesc.name,
        rates.N * factor,
        rates.P * factor,
        rates.K * factor,
        sr,
        (sr > 0 and areaHa > 0) and (areaHa / fieldAreaHa) * sr * SoilConstants.CHOPPED_STRAW.OM_RATE or 0
    )
end

-- Maximum zone cells stored per field. Prevents unbounded memory growth and network
-- packet overflow on large/intensively-farmed fields (see markBoomCells, applyFertilizer).
local MAX_ZONE_CELLS = 1000

-- Apply fertilizer
function SoilFertilitySystem:applyFertilizer(fieldId, fillTypeIndex, liters)
    if not self.settings.enabled then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then
        self:warning("Cannot apply fertilizer - field %d not found", fieldId)
        return
    end

    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if not fillType then
        self:warning("Cannot apply fertilizer - fill type %d not found", fillTypeIndex)
        return
    end

    -- Look up fertilizer profile from constants (defines N/P/K/pH/OM values per type)
    local entry = SoilConstants.FERTILIZER_PROFILES[fillType.name]
    if not entry then
        self:log("Fertilizer type %s not recognized", fillType.name)
        return
    end

    local limits = SoilConstants.NUTRIENT_LIMITS

    -- AREA NORMALIZATION: Calculate hectares for this field.
    -- Confirm area from farmland on first spray — fixes dedicated-server first-frame spike
    -- where fields are lazy-created with default 1.0 ha before the farmland manager is
    -- queried.  Without this, factor = liters/1.0 instead of liters/realArea, causing
    -- nutrients to jump by (realArea)× too much on the opening spray frame (issue #290).
    if not field._farmlandAreaConfirmed and g_farmlandManager then
        local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
        if farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
            field.fieldArea = farmlandObj.areaInHa
        end
        field._farmlandAreaConfirmed = true
    end
    local areaInHa = field.fieldArea or 1.0
    if areaInHa <= 0 then areaInHa = 1.0 end

    -- FERTILIZER RESTORATION CALCULATION:
    -- V1.7 Realism Update: Incremental application.
    -- Nutrients and crop protection effects are applied every frame as you spray.
    -- This provides immediate feedback on the HUD and removes the "90% cliff" delay.
    
    if not field.nutrientBuffer then field.nutrientBuffer = {} end
    field.nutrientBuffer[fillTypeIndex] = (field.nutrientBuffer[fillTypeIndex] or 0) + liters

    -- 1. Route crop protection products (incremental reduction with daily cap)
    -- Daily cap prevents over-application from driving pressure to zero in a few
    -- frames when BASE_RATES targetRate is mismatched to real sprayer LPS.
    if entry.pestReduction then
        local targetRate = SoilConstants.SPRAYER_RATE.BASE_RATES[fillType.name] or SoilConstants.SPRAYER_RATE.BASE_RATES.INSECTICIDE
        local targetVol  = areaInHa * targetRate.value
        if targetVol > 0 then
            local baseRed = SoilConstants.PEST_PRESSURE.INSECTICIDE_PRESSURE_REDUCTION or 25
            local proposed = (liters / targetVol) * baseRed
            if not self.insecticideDailyApplied then self.insecticideDailyApplied = {} end
            local today = (g_currentMission and g_currentMission.environment and g_currentMission.environment.currentDay) or 0
            local e = self.insecticideDailyApplied[fieldId]
            if not e or e.day ~= today then e = { day = today, applied = 0 }; self.insecticideDailyApplied[fieldId] = e end
            local remaining = math.max(0, baseRed - e.applied)
            local clamped = math.min(proposed, remaining)
            e.applied = e.applied + clamped
            if clamped > 0 then self:onInsecticideAppliedIncremental(fieldId, clamped) end
        end

    elseif entry.diseaseReduction then
        local targetRate = SoilConstants.SPRAYER_RATE.BASE_RATES[fillType.name] or SoilConstants.SPRAYER_RATE.BASE_RATES.FUNGICIDE
        local targetVol  = areaInHa * targetRate.value
        if targetVol > 0 then
            local baseRed = SoilConstants.DISEASE_PRESSURE.FUNGICIDE_PRESSURE_REDUCTION or 20
            local proposed = (liters / targetVol) * baseRed
            if not self.fungicideDailyApplied then self.fungicideDailyApplied = {} end
            local today = (g_currentMission and g_currentMission.environment and g_currentMission.environment.currentDay) or 0
            local e = self.fungicideDailyApplied[fieldId]
            if not e or e.day ~= today then e = { day = today, applied = 0 }; self.fungicideDailyApplied[fieldId] = e end
            local remaining = math.max(0, baseRed - e.applied)
            local clamped = math.min(proposed, remaining)
            e.applied = e.applied + clamped
            if clamped > 0 then self:onFungicideAppliedIncremental(fieldId, clamped) end
        end

    else
        -- 2. Apply standard nutrients (scaled by the liters applied this frame)
        local rrIdx  = self.settings.replenishmentRate or 3
        local rrMult = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[rrIdx] or 1.0
        local factor = (liters / 1000) / areaInHa * rrMult

        -- Capture before-values for diagnostic logging (debug mode only).
        local dbgN0, dbgP0, dbgK0, dbgPH0 = field.nitrogen, field.phosphorus, field.potassium, field.pH

        if entry.N then field.nitrogen   = math.min(limits.MAX, field.nitrogen   + entry.N * factor) end
        if entry.P then field.phosphorus = math.min(limits.MAX, field.phosphorus + entry.P * factor) end
        if entry.K then field.potassium  = math.min(limits.MAX, field.potassium  + entry.K * factor) end
        if entry.pH then field.pH        = math.max(limits.PH_MIN, math.min(limits.PH_MAX, field.pH + entry.pH * factor)) end
        if entry.OM then field.organicMatter = math.max(0, math.min(limits.ORGANIC_MATTER_MAX, field.organicMatter + entry.OM * factor)) end

        -- Sync all existing zone cells with the same delta applied to the field average.
        -- Without this, cells created before a spray job keep their old values while the
        -- HUD average climbs, causing the cell report panel to show values wildly out of
        -- step with the field average (reported by Seb, May 2026 — K 39 vs avg 244).
        if field.zoneData then
            for _, cell in pairs(field.zoneData) do
                if entry.N  then cell.N  = math.min(limits.MAX,                     cell.N  + entry.N  * factor) end
                if entry.P  then cell.P  = math.min(limits.MAX,                     cell.P  + entry.P  * factor) end
                if entry.K  then cell.K  = math.min(limits.MAX,                     cell.K  + entry.K  * factor) end
                if entry.pH then cell.pH = math.max(limits.PH_MIN, math.min(limits.PH_MAX,  cell.pH + entry.pH * factor)) end
                if entry.OM then cell.OM = math.max(0, math.min(limits.ORGANIC_MATTER_MAX,  cell.OM + entry.OM * factor)) end
            end
        end

        -- Throttled per-field diagnostic (debug mode, lime types always logged; nutrients every 4 s).
        -- Validates that pH shift and nutrient deltas are agronomically sensible.
        -- For LIME/LIQUIDLIME: target ~0.40 pH over a full 1-ha pass at BASE_RATES volume.
        -- For nutrients: visible delta per frame should be tiny; cumulative over full pass = profile value.
        if entry.pH then
            -- pH types (LIME, LIQUIDLIME, GYPSUM): log once per ~1000 L milestone at info
            -- level so it appears in the log without requiring SoilDebug, making it easy to
            -- confirm the hook is firing and the per-frame delta is accumulating correctly.
            local phBuf = field.nutrientBuffer and field.nutrientBuffer[fillTypeIndex] or 0
            local phBufPrev = phBuf - liters
            if math.floor(phBuf / 1000) ~= math.floor(phBufPrev / 1000) then
                SoilLogger.info(
                    "FertApply pH field=%d type=%-12s buf=%.0fL factor=%.4f  pH %.3f -> %.3f (area=%.2fha)",
                    fieldId, fillType.name, phBuf, factor, dbgPH0, field.pH, areaInHa)
            end
            SoilLogger.debug(
                "FertApply pH field=%d type=%-12s liters=%.4f factor=%.6f  pH %.3f -> %.3f (delta=%.4f)",
                fieldId, fillType.name, liters, factor, dbgPH0, field.pH, field.pH - dbgPH0)
        else
            -- Nutrient types: only log once every ~4 s to avoid log spam.
            -- Uses the field buffer length as a crude frame counter (avoids a time lookup).
            local buf = field.nutrientBuffer and field.nutrientBuffer[fillTypeIndex] or 0
            -- Log when buffer crosses a 1000-L boundary (roughly once per ~large-step).
            local prevBuf = buf - liters
            if math.floor(buf / 1000) ~= math.floor(prevBuf / 1000) then
                SoilLogger.debug(
                    "FertApply NPK field=%d type=%-12s buf=%.0fL  N %.1f->%.1f  P %.1f->%.1f  K %.1f->%.1f",
                    fieldId, fillType.name, buf,
                    dbgN0, field.nitrogen, dbgP0, field.phosphorus, dbgK0, field.potassium)
            end
        end

        -- Write updated values to density map layers (per-pixel, at sprayer position)
        if self.layerSystem and self.layerSystem.available then
            local x, _, z = getWorldTranslation(0)  -- fallback; sprayer hook sets vehicle pos via soilSystem
            if self._lastSprayX and self._lastSprayZ then
                x, z = self._lastSprayX, self._lastSprayZ
            end
            if x and z then
                if entry.N then self.layerSystem:updatePixelForField("nitrogen",      x, z, field.nitrogen,      2.0) end
                if entry.P then self.layerSystem:updatePixelForField("phosphorus",    x, z, field.phosphorus,    2.0) end
                if entry.K then self.layerSystem:updatePixelForField("potassium",     x, z, field.potassium,     2.0) end
                if entry.pH then self.layerSystem:updatePixelForField("pH",           x, z, field.pH,            2.0) end
                if entry.OM then self.layerSystem:updatePixelForField("organicMatter",x, z, field.organicMatter, 2.0) end
            end
        end

        -- zoneData per-cell update for per-area PDA overlay coloring (standard maps)
        local sprayX = self._lastSprayX
        local sprayZ = self._lastSprayZ
        if sprayX and sprayZ then
            local zone = SoilConstants.ZONE
            local cx = math.floor(sprayX / zone.CELL_SIZE)
            local cz = math.floor(sprayZ / zone.CELL_SIZE)
            -- String key keeps save/load/runtime consistent: setXMLString requires a string,
            -- and the load path (getXMLString) restores keys as strings. Using a number key
            -- here caused "setXMLString: Expected String, Actual Number" errors on autosave
            -- and also caused post-load lookups to miss (number key vs stored string key).
            local cellKey = tostring(cx * 10000 + cz)

            -- Coverage is now tracked from the sprayer hook with raw liters (pre-rateMultiplier)
            -- so it is not called here. See HookManager:installSprayerAreaHook.
            if field.fieldArea and field.fieldArea > 0 then areaInHa = field.fieldArea end

            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                local zdCount = 0
                for _ in pairs(field.zoneData) do zdCount = zdCount + 1 end
                if zdCount < MAX_ZONE_CELLS then
                    field.zoneData[cellKey] = {
                        N  = field.nitrogen,
                        P  = field.phosphorus,
                        K  = field.potassium,
                        pH = field.pH,
                        OM = field.organicMatter,
                        weedPressure = field.weedPressure,
                        pestPressure = field.pestPressure,
                        diseasePressure = field.diseasePressure,
                        compaction = field.compaction,
                    }
                end
            end
            local cell = field.zoneData[cellKey]
            if not cell then return end
            -- cellFactor must use areaInHa (not zone.CELL_AREA_HA) so that each cell
            -- absorbs nutrients at exactly the same per-frame rate as the whole-field
            -- average.  Using CELL_AREA_HA (0.01 ha) as the denominator made cells
            -- gain nutrients up to 1000× faster than the field total, causing the HUD
            -- to show near-complete N saturation after less than 1% field coverage
            -- (issue #205 Bug 2).
            -- N/P/K/pH/OM for this cell are already updated by the bulk sync above.
            -- Only apply spatial crop-protection reductions here (pest/disease sprays
            -- are position-specific; the bulk sync doesn't cover them).
            local cellFactor = (liters / 1000.0) / areaInHa
            if entry.pestReduction    then cell.pestPressure    = math.max(0, (cell.pestPressure or field.pestPressure or 0) - entry.pestReduction * cellFactor) end
            if entry.diseaseReduction then cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - entry.diseaseReduction * cellFactor) end
        end
    end

    field.fertilizerApplied = (field.fertilizerApplied or 0) + liters

    -- Check for "Field fully treated" notification (once per field per day at 90% threshold)
    -- Skip notification for crop-protection products (INSECTICIDE, FUNGICIDE, HERBICIDE) —
    -- they share FERTILIZER_PROFILES entries for pest/disease reduction but are not fertilizers,
    -- so "fully treated with INSECTICIDE" would be misleading and incorrect.
    local isCropProtection = (
        (SoilConstants.PEST_PRESSURE    and SoilConstants.PEST_PRESSURE.INSECTICIDE_TYPES    and SoilConstants.PEST_PRESSURE.INSECTICIDE_TYPES[fillType.name])    or
        (SoilConstants.DISEASE_PRESSURE and SoilConstants.DISEASE_PRESSURE.FUNGICIDE_TYPES   and SoilConstants.DISEASE_PRESSURE.FUNGICIDE_TYPES[fillType.name])    or
        (SoilConstants.WEED_PRESSURE    and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES      and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES[fillType.name])
    )
    if not isCropProtection then
        local baseRateEntry = SoilConstants.SPRAYER_RATE.BASE_RATES[fillType.name] or
                             SoilConstants.SPRAYER_RATE.BASE_RATES.DEFAULT
        local targetVolume = areaInHa * baseRateEntry.value
        local coverageThreshold = targetVolume * SoilConstants.SPRAYER_RATE.FERTILIZER_COVERAGE_THRESHOLD

        local minCoverage = SoilConstants.COVERAGE and SoilConstants.COVERAGE.MIN_FULL_CREDIT or 0.70
        if field.nutrientBuffer[fillTypeIndex] >= coverageThreshold and
           (field.coverageFraction or 0) >= minCoverage then
            local today = (g_currentMission and g_currentMission.environment and
                           g_currentMission.environment.currentDay) or 0
            if not self.fertNotifyShown then self.fertNotifyShown = {} end
            if self.fertNotifyShown[fieldId] ~= today then
                self:showNotification(g_i18n:getText("sf_notify_treated_title"), string.format(g_i18n:getText("sf_notify_treated_body"), fieldId, fillType.name))
                self.fertNotifyShown[fieldId] = today
            end
        end
    end
end

--- Incremental insecticide application (called every frame while spraying)
function SoilFertilitySystem:onInsecticideAppliedIncremental(fieldId, reduction)
    if not self.settings.pestPressure then return end
    local field = self:getOrCreateField(fieldId, false)
    if not field then return end

    local pp = SoilConstants.PEST_PRESSURE
    local before = field.pestPressure or 0
    field.pestPressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.insecticideDaysLeft = pp.INSECTICIDE_DURATION_DAYS * daysPerMonth

    -- Local zoneData update
    local x, z = self._lastSprayX, self._lastSprayZ
    if x and z then
        local zone = SoilConstants.ZONE
        local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
        if not field.zoneData then field.zoneData = {} end
        if not field.zoneData[cellKey] then
            field.zoneData[cellKey] = {
                N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                pH = field.pH, OM = field.organicMatter,
                weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                diseasePressure = field.diseasePressure, compaction = field.compaction
            }
        end
        local cell = field.zoneData[cellKey]
        cell.pestPressure = math.max(0, (cell.pestPressure or field.pestPressure or 0) - reduction)
    end
end

--- Incremental fungicide application
function SoilFertilitySystem:onFungicideAppliedIncremental(fieldId, reduction)
    if not self.settings.diseasePressure then return end
    local field = self:getOrCreateField(fieldId, false)
    if not field then return end

    local dp = SoilConstants.DISEASE_PRESSURE
    local before = field.diseasePressure or 0
    field.diseasePressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.fungicideDaysLeft = dp.FUNGICIDE_DURATION_DAYS * daysPerMonth

    -- Local zoneData update
    local x, z = self._lastSprayX, self._lastSprayZ
    if x and z then
        local zone = SoilConstants.ZONE
        local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
        if not field.zoneData then field.zoneData = {} end
        if not field.zoneData[cellKey] then
            field.zoneData[cellKey] = {
                N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                pH = field.pH, OM = field.organicMatter,
                weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                diseasePressure = field.diseasePressure, compaction = field.compaction
            }
        end
        local cell = field.zoneData[cellKey]
        cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - reduction)
    end
end

-- =====================================================================
-- DAILY REDUCTION CAP HELPERS
-- =====================================================================
-- The Direct-path functions below are invoked every frame by the sprayer hook
-- (~60x/sec). Each call computes a per-frame reduction from `liters`, but the
-- base sprayer LPS (~93.5 L/ha for liquid) is ~60× the "target rate" entries
-- in Constants (1.5 L/ha for HERBICIDE, similar for INSECTICIDE/FUNGICIDE).
-- Without a cap, a 40% weed pressure field drops to 0% in < 1 second (issue
-- #205 over-effectiveness bug).
--
-- Fix: cap total daily reduction at REDUCTION × effectiveness.  Progress is
-- still smooth per-frame (good HUD feel) but over-application is useless —
-- matching realism and the once-per-day model used by onHerbicideApplied.
---@return number currentDay
local function _soilGetCurrentDay()
    return (g_currentMission and g_currentMission.environment and
            g_currentMission.environment.currentDay) or 0
end

--- Apply capped daily reduction to a pressure field.
-- @param dailyTable    self.herbicideDailyApplied[fieldId] = { day = N, applied = X }
-- @param fieldId       field id
-- @param proposedRed   unclamped per-frame reduction
-- @param maxDailyRed   cap for today (REDUCTION × effectiveness)
-- @return clamped reduction to actually apply this frame
local function _soilApplyCappedReduction(dailyTable, fieldId, proposedRed, maxDailyRed)
    local today = _soilGetCurrentDay()
    local entry = dailyTable[fieldId]
    if not entry or entry.day ~= today then
        entry = { day = today, applied = 0 }
        dailyTable[fieldId] = entry
    end
    local remaining = math.max(0, maxDailyRed - entry.applied)
    local clamped = math.min(proposedRed, remaining)
    entry.applied = entry.applied + clamped
    return clamped
end

--- Track sprayer coverage using liters consumed per tick as a proxy for area sprayed.
-- Replaces the old cell-based tracker that used only the rootNode position, which
-- severely under-reported coverage for wide-boom equipment: a 28 m sprayer covers
-- ~28 cells per pass but the rootNode only visits 1 cell, so a 95 % pass showed
-- only ~20 % coverage in the HUD.
--
-- Area-based approach: liters consumed per tick is proportional to
--   boom_width × speed × LPS_rate
-- Dividing by the product's reference rate (L/ha) converts liters → hectares covered.
-- This is field-size and boom-size independent and matches real application density.
--
-- Called from the sprayer hook with raw liters (before rateMultiplier).
-- For fertilizer products, updateFractions should be false because markBoomCells
-- handles coverage via spatial cell deduplication (eliminates overlap inflation).
-- For crop protection direct paths (herbicide/insecticide/fungicide) where no
-- boomPoints are available, updateFractions remains true (liter-based fallback).
---@param fieldId        number
---@param liters         number   Raw liters consumed this tick (pre-rateMultiplier)
---@param fillTypeName   string|nil
---@param updateFractions boolean|nil  false = skip area update, only record product name
function SoilFertilitySystem:trackSprayerCoverage(fieldId, liters, fillTypeName, updateFractions)
    if not liters or liters <= 0 then return end
    local field = self.fieldData[fieldId]
    if not field then return end

    if fillTypeName then field.sessionLastProduct = fillTypeName end

    -- Fertilizer products: coverage is handled by markBoomCells (cell dedup).
    if updateFractions == false then return end

    -- Crop protection fallback: liter-based area estimate (no boom position available).
    local areaInHa = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0

    local baseRates = SoilConstants.SPRAYER_RATE and SoilConstants.SPRAYER_RATE.BASE_RATES
    local rateEntry = fillTypeName and baseRates and (baseRates[fillTypeName] or baseRates.DEFAULT)
    local ratePerHa = (rateEntry and rateEntry.value and rateEntry.value > 0) and rateEntry.value or 93.5

    local areaThisTick = liters / ratePerHa
    field.coveredAreaHa = (field.coveredAreaHa or 0) + areaThisTick

    local prevCoverage = field.coverageFraction or 0
    field.coverageFraction = math.min(1.0, field.coveredAreaHa / areaInHa)

    field.sessionCoverageHa       = math.min(areaInHa, (field.sessionCoverageHa or 0) + areaThisTick)
    field.sessionCoverageFraction = math.min(1.0, field.sessionCoverageHa / areaInHa)

    for _, m in ipairs(COVERAGE_MILESTONES) do
        if prevCoverage < m and field.coverageFraction >= m then
            SoilLogger.debug("Coverage field=%d  %.0f%% covered (%.3f/%.3f ha)  type=%s",
                fieldId, m * 100, field.coveredAreaHa, areaInHa, fillTypeName or "?")
            break
        end
    end
end

--- Stamp zone cells at every position in boomPoints and update cell-deduped coverage.
--- Coverage (session + daily) is incremented only for cells not previously visited,
--- eliminating overlap inflation from headland turns and second passes.
--- Also stamps visual overlay entries (zoneData) for the PDA map.
--- Called from HookManager after applySingle to fill in the full lateral sweep.
---@param fieldId   number
---@param boomPoints table  Array of {x=, z=} world positions
function SoilFertilitySystem:markBoomCells(fieldId, boomPoints)
    if not boomPoints or #boomPoints == 0 then return end
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return end

    local zone     = SoilConstants.ZONE
    local cellArea = zone.CELL_AREA_HA  -- 0.01 ha per 10×10 m cell
    local areaInHa = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0

    if not field.sessionCoverageCells then field.sessionCoverageCells = {} end
    if not field.dailyCoverageCells   then field.dailyCoverageCells   = {} end
    if not field.zoneData             then field.zoneData             = {} end

    local seen = {}
    for _, pt in ipairs(boomPoints) do
        local cx = math.floor(pt.x / zone.CELL_SIZE)
        local cz = math.floor(pt.z / zone.CELL_SIZE)
        local cellKey = tostring(cx * 10000 + cz)
        if not seen[cellKey] then
            seen[cellKey] = true

            -- ── Coverage deduplication ─────────────────────────────────────────
            if not field.sessionCoverageCells[cellKey] then
                field.sessionCoverageCells[cellKey] = true
                field.sessionCoverageHa = math.min(areaInHa, (field.sessionCoverageHa or 0) + cellArea)
            end
            if not field.dailyCoverageCells[cellKey] then
                field.dailyCoverageCells[cellKey] = true
                field.coveredAreaHa = math.min(areaInHa, (field.coveredAreaHa or 0) + cellArea)
            end

            -- ── Visual overlay (zoneData) ──────────────────────────────────────
            -- Enforce cell cap: only affects sub-field visual detail, not coverage accuracy.
            local canWrite = true
            if field.zoneData[cellKey] == nil then
                local count = 0
                for _ in pairs(field.zoneData) do count = count + 1 end
                if count >= MAX_ZONE_CELLS then canWrite = false end
            end
            if canWrite then
                field.zoneData[cellKey] = {
                    N  = field.nitrogen       or SoilConstants.FIELD_DEFAULTS.nitrogen,
                    P  = field.phosphorus     or SoilConstants.FIELD_DEFAULTS.phosphorus,
                    K  = field.potassium      or SoilConstants.FIELD_DEFAULTS.potassium,
                    pH = field.pH             or SoilConstants.FIELD_DEFAULTS.pH,
                    OM = field.organicMatter  or SoilConstants.FIELD_DEFAULTS.organicMatter,
                    weedPressure    = field.weedPressure    or 0,
                    pestPressure    = field.pestPressure    or 0,
                    diseasePressure = field.diseasePressure or 0,
                    compaction      = field.compaction      or 0,
                }
            end
        end
    end

    -- Recompute fractions after all cells are processed
    field.coverageFraction        = math.min(1.0, (field.coveredAreaHa  or 0) / areaInHa)
    field.sessionCoverageFraction = math.min(1.0, (field.sessionCoverageHa or 0) / areaInHa)
end

--- Direct-path buffering for non-profile products (Herbicide/Insecticide/Fungicide)
-- NOTE: the formula (liters/targetVol)×REDUCTION depends on targetRate (from
-- Constants, a real-world L/ha figure ~1.5) matching the actual vanilla sprayer
-- LPS (~93.5 L/ha for liquid).  It does NOT — hence the daily cap below.
function SoilFertilitySystem:onHerbicideAppliedDirect(fieldId, effectiveness, liters)
    if not self.settings.weedPressure then return end
    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Confirm field area from farmland on first herbicide application (mirrors applyFertilizer).
    -- Without this, newly-created fields default to 1.0 ha, making targetVol wrong on dedi servers.
    if not field._farmlandAreaConfirmed and g_farmlandManager then
        local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
        if farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
            field.fieldArea = farmlandObj.areaInHa
        end
        field._farmlandAreaConfirmed = true
    end

    local areaInHa = field.fieldArea or 1.0
    if areaInHa <= 0 then areaInHa = 1.0 end
    local targetRate = SoilConstants.SPRAYER_RATE.BASE_RATES.HERBICIDE.value
    local targetVol = areaInHa * targetRate
    if targetVol <= 0 then return end

    local effective = effectiveness or 1.0
    local maxReduction = (SoilConstants.WEED_PRESSURE.HERBICIDE_PRESSURE_REDUCTION or 30) * effective
    local proposed = (liters / targetVol) * (SoilConstants.WEED_PRESSURE.HERBICIDE_PRESSURE_REDUCTION or 30) * effective

    if not self.herbicideDailyApplied then self.herbicideDailyApplied = {} end
    local reduction = _soilApplyCappedReduction(self.herbicideDailyApplied, fieldId, proposed, maxReduction)

    if reduction > 0 then
        local before = field.weedPressure or 0
        field.weedPressure = math.max(0, before - reduction)
        local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
        field.herbicideDaysLeft = SoilConstants.WEED_PRESSURE.HERBICIDE_DURATION_DAYS * daysPerMonth

        -- Update per-cell weed pressure so the PDA cell-report shows changes immediately.
        -- onInsecticideAppliedIncremental does this for pest pressure; herbicide was missing it.
        local x, z = self._lastSprayX, self._lastSprayZ
        if x and z then
            local zone = SoilConstants.ZONE
            local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                    pH = field.pH, OM = field.organicMatter,
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            field.zoneData[cellKey].weedPressure = math.max(0,
                (field.zoneData[cellKey].weedPressure or field.weedPressure or 0) - reduction)
        end

        -- Broadcast updated weed pressure to all clients (dedicated server fix — Issue #257)
        if g_server and g_currentMission and g_currentMission.missionDynamicInfo
            and g_currentMission.missionDynamicInfo.isMultiplayer then
            if SoilFieldUpdateEvent then
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end

    if not field.nutrientBuffer then field.nutrientBuffer = {} end
    field.nutrientBuffer[99991] = (field.nutrientBuffer[99991] or 0) + liters
    self:trackSprayerCoverage(fieldId, liters, "HERBICIDE")
end

function SoilFertilitySystem:onInsecticideAppliedDirect(fieldId, effectiveness, liters)
    if not self.settings.pestPressure then return end
    local field = self.fieldData[fieldId]
    if not field then return end

    local areaInHa = field.fieldArea or 1.0
    if areaInHa <= 0 then areaInHa = 1.0 end
    local targetRate = SoilConstants.SPRAYER_RATE.BASE_RATES.INSECTICIDE.value
    local targetVol = areaInHa * targetRate
    if targetVol <= 0 then return end

    local effective = effectiveness or 1.0
    local baseRed = SoilConstants.PEST_PRESSURE.INSECTICIDE_PRESSURE_REDUCTION or 25
    local maxReduction = baseRed * effective
    local proposed = (liters / targetVol) * baseRed * effective

    if not self.insecticideDailyApplied then self.insecticideDailyApplied = {} end
    local reduction = _soilApplyCappedReduction(self.insecticideDailyApplied, fieldId, proposed, maxReduction)

    if reduction > 0 then
        self:onInsecticideAppliedIncremental(fieldId, reduction)
    end

    if not field.nutrientBuffer then field.nutrientBuffer = {} end
    field.nutrientBuffer[99992] = (field.nutrientBuffer[99992] or 0) + liters
    self:trackSprayerCoverage(fieldId, liters, "INSECTICIDE")
end

function SoilFertilitySystem:onFungicideAppliedDirect(fieldId, effectiveness, liters)
    if not self.settings.diseasePressure then return end
    local field = self.fieldData[fieldId]
    if not field then return end

    local areaInHa = field.fieldArea or 1.0
    if areaInHa <= 0 then areaInHa = 1.0 end
    local targetRate = SoilConstants.SPRAYER_RATE.BASE_RATES.FUNGICIDE.value
    local targetVol = areaInHa * targetRate
    if targetVol <= 0 then return end

    local effective = effectiveness or 1.0
    local baseRed = SoilConstants.DISEASE_PRESSURE.FUNGICIDE_PRESSURE_REDUCTION or 20
    local maxReduction = baseRed * effective
    local proposed = (liters / targetVol) * baseRed * effective

    if not self.fungicideDailyApplied then self.fungicideDailyApplied = {} end
    local reduction = _soilApplyCappedReduction(self.fungicideDailyApplied, fieldId, proposed, maxReduction)

    if reduction > 0 then
        self:onFungicideAppliedIncremental(fieldId, reduction)
    end

    if not field.nutrientBuffer then field.nutrientBuffer = {} end
    field.nutrientBuffer[99993] = (field.nutrientBuffer[99993] or 0) + liters
    self:trackSprayerCoverage(fieldId, liters, "FUNGICIDE")
end

--- Apply over-application burn penalty to a field.
--- Called by HookManager after fertilizer is applied at rate > BURN_RISK_THRESHOLD.
--- At risk threshold: probabilistic burn (probability scales linearly with excess).
--- At guaranteed threshold: burn every application.
--- Burn reduces pH and nitrogen to simulate salt/chemical soil damage.
---@param fieldId number
---@param rateMultiplier number The actual rate multiplier used (e.g. 1.5)
function SoilFertilitySystem:applyBurnEffect(fieldId, rateMultiplier)
    local field = self.fieldData[fieldId]
    if not field then return end

    local burnCfg = SoilConstants.SPRAYER_RATE
    local limits  = SoilConstants.NUTRIENT_LIMITS
    local phDrop  = 0
    local nDrain  = 0

    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    if rateMultiplier >= burnCfg.BURN_GUARANTEED_THRESHOLD then
        phDrop = burnCfg.BURN_PH_DROP_CERTAIN
        nDrain = burnCfg.BURN_N_DRAIN_CERTAIN
        field.burnDaysLeft = 3 * daysPerMonth   -- show burn warning in HUD (Issue #349 scaling)
    else
        -- Probability scales linearly between risk threshold and guaranteed threshold
        local excess = (rateMultiplier - burnCfg.BURN_RISK_THRESHOLD) /
                       (burnCfg.BURN_GUARANTEED_THRESHOLD - burnCfg.BURN_RISK_THRESHOLD)
        if math.random() < excess then
            phDrop = burnCfg.BURN_PH_DROP_RISK
            nDrain = burnCfg.BURN_N_DRAIN_RISK
            field.burnDaysLeft = 3 * daysPerMonth
        end
    end

    if phDrop > 0 then
        field.pH       = math.max(limits.PH_MIN, field.pH - phDrop)
        field.nitrogen = math.max(limits.MIN, field.nitrogen - nDrain)

        self:log("Burn effect field %d: pH -%.2f, N -%.1f (rate=%.0f%%)",
            fieldId, phDrop, nDrain, rateMultiplier * 100)

        if self.settings.showNotifications then
            self:showNotification(
                g_i18n:getText("sf_notify_burn_title"),
                string.format(g_i18n:getText("sf_notify_burn_body"), fieldId, field.pH)
            )
        end

        -- Broadcast updated field data in multiplayer
        if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
            if SoilFieldUpdateEvent then
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Get field info for display (HUD, console, etc)
---@param fieldId number The field ID to query
---@param x number|nil Optional world X coordinate for local cell lookup
---@param z number|nil Optional world Z coordinate for local cell lookup
---@return table|nil Field info with nutrient values and status, or nil if not found
function SoilFertilitySystem:getFieldInfo(fieldId, x, z)
    if not fieldId or fieldId <= 0 then return nil end

    local field = self:getOrCreateField(fieldId, true)
    if not field then
        self:warning("Field %d not found in getFieldInfo", fieldId)
        return nil
    end

    -- Use local cell data if position is provided and cell exists
    local n  = field.nitrogen   or SoilConstants.FIELD_DEFAULTS.nitrogen
    local p  = field.phosphorus or SoilConstants.FIELD_DEFAULTS.phosphorus
    local k  = field.potassium  or SoilConstants.FIELD_DEFAULTS.potassium
    local ph = field.pH         or SoilConstants.FIELD_DEFAULTS.pH
    local om = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter

    local fromZoneCell = false
    if x and z and field.zoneData then
        local zone = SoilConstants.ZONE
        local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
        local cell = field.zoneData[cellKey]
        if cell then
            n  = cell.N  or n
            p  = cell.P  or p
            k  = cell.K  or k
            ph = cell.pH or ph
            om = cell.OM or om
            fromZoneCell = true
        end
    end

    local thresholds = SoilConstants.STATUS_THRESHOLDS
    local fertThresholds = SoilConstants.FERTILIZATION_THRESHOLDS

    local function nutrientStatus(value, nutrient)
        local t = thresholds[nutrient]
        if not t then return "Unknown" end
        if value < t.poor then return "Poor"
        elseif value < t.fair then return "Fair"
        else return "Good" end
    end

    local currentDay = (g_currentMission and g_currentMission.environment and g_currentMission.environment.currentDay) or 0

    -- Resolve current crop name: prefer the live growing fruit (what's actually in
    -- the ground right now) over lastCrop, which is only set on harvest and will be
    -- stale as soon as the next crop is sown.
    -- #99 fix: field.id / field.fieldId are nil in FS25; our fieldId is farmland.id.
    -- g_fieldManager:getFieldById() searches by field.id which is always nil, so it
    -- returns the wrong field or nil depending on list position.
    -- Correct approach: iterate g_fieldManager.fields and match farmland.id.
    local cropName = nil
    if g_fieldManager and g_fieldManager.fields then
        local fsField = nil
        for _, f in ipairs(g_fieldManager.fields) do
            if f and f.farmland and f.farmland.id == fieldId then
                fsField = f
                break
            end
        end
        if fsField then
            -- Fix #123: Field:getFieldState() does NOT exist in FS25.
            -- FieldState is a standalone class; it must be instantiated and then
            -- populated by calling :update(worldX, worldZ) with a point inside the field.
            -- fsField.posX / posZ are the polygon centroid, set by Field:load() via
            -- MathUtil.getPolygonLabel(). They are always valid after field initialization.
            local centerX = fsField.posX
            local centerZ = fsField.posZ
            if centerX and centerZ then
                local ok, fieldState = pcall(function()
                    local fs = FieldState.new()
                    fs:update(centerX, centerZ)
                    return fs
                end)
                if ok and fieldState and fieldState.fruitTypeIndex ~= FruitType.UNKNOWN then
                    local fruitDesc = g_fruitTypeManager and
                        g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
                    if fruitDesc and fruitDesc.name then
                        cropName = fruitDesc.name
                    end
                end
            end
        end
    end
    -- Fall back to lastCrop when the field is fallow (no live fruit detected)
    if not cropName or cropName == "" then
        cropName = field.lastCrop
    end

    -- Compute crop rotation status for external consumers (e.g. FarmTablet)
    local rotationStatus = nil
    if SoilConstants.CROP_ROTATION and field.lastCrop and field.lastCrop2 then
        local cr      = SoilConstants.CROP_ROTATION
        local crop1   = string.lower(field.lastCrop)
        local crop2   = string.lower(field.lastCrop2)
        if cr.LEGUMES[crop1] and not cr.LEGUMES[crop2] then
            rotationStatus = "Bonus"
        elseif field.lastCrop == field.lastCrop2 then
            rotationStatus = "Fatigue"
        else
            rotationStatus = "OK"
        end
    end

    -- Resolve per-crop nutrient targets (nil when no crop planted)
    local cropTargets = nil
    if cropName and cropName ~= "" then
        local targets = SoilConstants.CROP_NUTRIENT_TARGETS
        if targets then
            cropTargets = targets[string.lower(cropName)] or targets.default
        end
    end

    return {
        fieldId = fieldId,
        fieldArea = field.fieldArea or 1.0,
        nitrogen = { value = math.floor(n), status = nutrientStatus(n, "nitrogen") },
        phosphorus = { value = math.floor(p), status = nutrientStatus(p, "phosphorus") },
        potassium = { value = math.floor(k), status = nutrientStatus(k, "potassium") },
        cropTargets = cropTargets,
        organicMatter = om,
        pH = ph,
        lastCrop = cropName,
        lastCrop2 = field.lastCrop2,
        rotationStatus = rotationStatus,
        daysSinceHarvest = field.lastHarvest > 0 and (currentDay - field.lastHarvest) or 0,
        fertilizerApplied = field.fertilizerApplied or 0,
        weedPressure = field.weedPressure or 0,
        herbicideActive = (field.herbicideDaysLeft or 0) > 0,
        pestPressure = field.pestPressure or 0,
        insecticideActive = (field.insecticideDaysLeft or 0) > 0,
        diseasePressure = field.diseasePressure or 0,
        fungicideActive = (field.fungicideDaysLeft or 0) > 0,
        burnDaysLeft = field.burnDaysLeft or 0,
        nutrientBuffer          = field.nutrientBuffer or {},
        coverageFraction        = field.coverageFraction or 0,
        sessionCoverageFraction = field.sessionCoverageFraction or 0,
        sessionLastProduct      = field.sessionLastProduct,
        compaction = field.compaction or 0,
        fromZoneCell = fromZoneCell,
        needsFertilization = (
            field.nitrogen < fertThresholds.nitrogen or
            field.phosphorus < fertThresholds.phosphorus or
            field.potassium < fertThresholds.potassium or
            field.pH < fertThresholds.pH
        )
    }
end

--- Calculate the urgency score (0-100) for a field
---@param fieldId number
---@return number
function SoilFertilitySystem:getFieldUrgency(fieldId)
    local info = self:getFieldInfo(fieldId)
    if not info then return 0 end

    local urgency = 0
    local thresh = SoilConstants.YIELD_SENSITIVITY and SoilConstants.YIELD_SENSITIVITY.OPTIMAL_THRESHOLD or 70
    
    local nDef = math.max(0, thresh - info.nitrogen.value) / thresh
    local pDef = math.max(0, thresh - info.phosphorus.value) / thresh
    local kDef = math.max(0, thresh - info.potassium.value) / thresh

    local phOpt = 6.5  -- optimal pH target (mid-point of neutral band 6.5-7.0)
    local phMin = SoilConstants.NUTRIENT_LIMITS and SoilConstants.NUTRIENT_LIMITS.PH_MIN or 5.0
    local phDef = math.max(0, phOpt - info.pH) / (phOpt - phMin)

    local weedDef = (info.weedPressure or 0) / 100
    local pestDef = (info.pestPressure or 0) / 100
    local diseaseDef = (info.diseasePressure or 0) / 100

    urgency = math.min(100, ((nDef + pDef + kDef + phDef + weedDef + pestDef + diseaseDef) / 7) * 100)
    return urgency
end

-- Get field count
function SoilFertilitySystem:getFieldCount()
    local count = 0
    for _ in pairs(self.fieldData) do
        count = count + 1
    end
    return count
end

-- Save to XML file
function SoilFertilitySystem:saveToXMLFile(xmlFile, key)
    if not xmlFile then return end

    -- SAFETY: ensure fieldData is valid
    if not self or type(self) ~= "table" then
        SoilLogger.error("saveToXMLFile called with invalid self")
        return
    end

    if not self.fieldData or type(self.fieldData) ~= "table" then
        SoilLogger.warning("Cannot save - fieldData invalid (type: %s)", type(self.fieldData))
        return
    end

    local defaults = SoilConstants.FIELD_DEFAULTS
    local index = 0

    for fieldId, field in pairs(self.fieldData) do
        if type(field) == "table" then
            local fieldKey = string.format("%s.field(%d)", key, index)

            setXMLInt(xmlFile, fieldKey .. "#id", fieldId)
            setXMLFloat(xmlFile, fieldKey .. "#fieldArea", field.fieldArea or 1.0)
            setXMLFloat(xmlFile, fieldKey .. "#nitrogen", field.nitrogen or defaults.nitrogen)
            setXMLFloat(xmlFile, fieldKey .. "#phosphorus", field.phosphorus or defaults.phosphorus)
            setXMLFloat(xmlFile, fieldKey .. "#potassium", field.potassium or defaults.potassium)
            setXMLFloat(xmlFile, fieldKey .. "#organicMatter", field.organicMatter or defaults.organicMatter)
            setXMLFloat(xmlFile, fieldKey .. "#pH", field.pH or defaults.pH)
            setXMLString(xmlFile, fieldKey .. "#lastCrop", field.lastCrop or "")
            setXMLString(xmlFile, fieldKey .. "#lastCrop2", field.lastCrop2 or "")
            setXMLString(xmlFile, fieldKey .. "#lastCrop3", field.lastCrop3 or "")
            setXMLInt(xmlFile, fieldKey .. "#rotationBonusDaysLeft", field.rotationBonusDaysLeft or 0)
            setXMLInt(xmlFile, fieldKey .. "#lastHarvest", field.lastHarvest or 0)
            setXMLFloat(xmlFile, fieldKey .. "#fertilizerApplied", field.fertilizerApplied or 0)
            setXMLFloat(xmlFile, fieldKey .. "#weedPressure", field.weedPressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#herbicideDaysLeft", field.herbicideDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#pestPressure", field.pestPressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#insecticideDaysLeft", field.insecticideDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#diseasePressure", field.diseasePressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#fungicideDaysLeft", field.fungicideDaysLeft or 0)
            setXMLInt(xmlFile, fieldKey .. "#dryDayCount", field.dryDayCount or 0)
            setXMLInt(xmlFile, fieldKey .. "#burnDaysLeft", field.burnDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#coverageFraction", field.coverageFraction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#compaction", field.compaction or 0)

            -- Save daily application throttles
            setXMLInt(xmlFile, fieldKey .. "#herbicideAppliedDay", self.herbicideAppliedDay[fieldId] or 0)
            setXMLInt(xmlFile, fieldKey .. "#insecticideAppliedDay", self.insecticideAppliedDay[fieldId] or 0)
            setXMLInt(xmlFile, fieldKey .. "#fungicideAppliedDay", self.fungicideAppliedDay[fieldId] or 0)

            -- Save per-cell compaction data
            local compIdx = 0
            if field.compactionCells then
                for cellKey, val in pairs(field.compactionCells) do
                    local ck = string.format("%s.compactionCell(%d)", fieldKey, compIdx)
                    setXMLString(xmlFile, ck .. "#key", cellKey)
                    setXMLFloat(xmlFile, ck .. "#v", val)
                    compIdx = compIdx + 1
                end
            end

            -- Save per-area zone cells for overlay coloring
            local zoneIdx = 0
            if field.zoneData then
                for cellKey, cell in pairs(field.zoneData) do
                    local zk = string.format("%s.zone(%d)", fieldKey, zoneIdx)
                    setXMLString(xmlFile, zk .. "#key", cellKey)
                    setXMLFloat(xmlFile, zk .. "#N",  cell.N  or 0)
                    setXMLFloat(xmlFile, zk .. "#P",  cell.P  or 0)
                    setXMLFloat(xmlFile, zk .. "#K",  cell.K  or 0)
                    setXMLFloat(xmlFile, zk .. "#pH", cell.pH or 6.0)
                    setXMLFloat(xmlFile, zk .. "#OM", cell.OM or 0)
                    setXMLFloat(xmlFile, zk .. "#WP", cell.weedPressure or 0)
                    setXMLFloat(xmlFile, zk .. "#PP", cell.pestPressure or 0)
                    setXMLFloat(xmlFile, zk .. "#DP", cell.diseasePressure or 0)
                    setXMLFloat(xmlFile, zk .. "#CP", cell.compaction or 0)
                    zoneIdx = zoneIdx + 1
                end
            end

            index = index + 1
        else
            print(string.format(
                "[SoilFertilizer WARNING] Skipping corrupted field entry %s (type: %s)",
                tostring(fieldId),
                type(field)
            ))
        end
    end

    self:info("Saved data for %d fields", index)
end

-- Load from XML file
function SoilFertilitySystem:loadFromXMLFile(xmlFile, key)
    if not xmlFile then return end

    local defaults = SoilConstants.FIELD_DEFAULTS
    self.fieldData = {}
    local index = 0

    while true do
        local fieldKey = string.format("%s.field(%d)", key, index)
        local fieldId = getXMLInt(xmlFile, fieldKey .. "#id")

        if not fieldId then break end

        self.fieldData[fieldId] = {
            fieldArea = getXMLFloat(xmlFile, fieldKey .. "#fieldArea") or 1.0,
            nitrogen = math.max(0, math.min(100, getXMLFloat(xmlFile, fieldKey .. "#nitrogen") or defaults.nitrogen)),
            phosphorus = math.max(0, math.min(100, getXMLFloat(xmlFile, fieldKey .. "#phosphorus") or defaults.phosphorus)),
            potassium = math.max(0, math.min(100, getXMLFloat(xmlFile, fieldKey .. "#potassium") or defaults.potassium)),
            organicMatter = math.max(0, math.min(10, getXMLFloat(xmlFile, fieldKey .. "#organicMatter") or defaults.organicMatter)),
            pH = math.max(5.0, math.min(8.5, getXMLFloat(xmlFile, fieldKey .. "#pH") or defaults.pH)),
            lastCrop = getXMLString(xmlFile, fieldKey .. "#lastCrop"),
            lastCrop2 = getXMLString(xmlFile, fieldKey .. "#lastCrop2"),
            lastCrop3 = getXMLString(xmlFile, fieldKey .. "#lastCrop3"),
            rotationBonusDaysLeft = getXMLInt(xmlFile, fieldKey .. "#rotationBonusDaysLeft") or 0,
            lastHarvest = getXMLInt(xmlFile, fieldKey .. "#lastHarvest") or 0,
            fertilizerApplied = getXMLFloat(xmlFile, fieldKey .. "#fertilizerApplied") or 0,
            weedPressure = getXMLFloat(xmlFile, fieldKey .. "#weedPressure") or 0,
            herbicideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#herbicideDaysLeft") or 0,
            pestPressure = getXMLFloat(xmlFile, fieldKey .. "#pestPressure") or 0,
            insecticideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#insecticideDaysLeft") or 0,
            diseasePressure = getXMLFloat(xmlFile, fieldKey .. "#diseasePressure") or 0,
            fungicideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#fungicideDaysLeft") or 0,
            dryDayCount = getXMLInt(xmlFile, fieldKey .. "#dryDayCount") or 0,
            burnDaysLeft = getXMLInt(xmlFile, fieldKey .. "#burnDaysLeft") or 0,
            coverageFraction = getXMLFloat(xmlFile, fieldKey .. "#coverageFraction") or 0,
            lastAlertSeason = getXMLInt(xmlFile, fieldKey .. "#lastAlertSeason") or nil,
            compaction = 0,
            compactionCells = {},
            compactionCellDays = {},
            compactionSum = 0,
            compactionTotalCells = 0,
            initialized = true,
            nutrientBuffer = {},
            zoneData = {},
            coveredAreaHa = 0,
            dailyCoverageCells = {},
            sessionCoverageHa = 0,
            sessionCoverageFraction = 0,
            sessionCoverageCells = {},
            sessionLastProduct = nil,
        }

        -- Load daily application throttles
        self.herbicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#herbicideAppliedDay") or 0
        self.insecticideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#insecticideAppliedDay") or 0
        self.fungicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#fungicideAppliedDay") or 0

        -- Refresh fieldArea from the live farmland object — corrects stale values from saves
        -- written before the scan priority bug was fixed (where field.areaHa == 1.0 default
        -- was recorded as the real area because it's truthy and blocked the farmland fallback).
        -- g_farmlandManager.farmlands[id].areaInHa comes from map XML and is always reliable.
        if g_farmlandManager then
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
                self.fieldData[fieldId].fieldArea = farmlandObj.areaInHa
            end
        end

        -- Clear empty strings
        if self.fieldData[fieldId].lastCrop == "" then
            self.fieldData[fieldId].lastCrop = nil
        end
        if self.fieldData[fieldId].lastCrop2 == "" then
            self.fieldData[fieldId].lastCrop2 = nil
        end
        if self.fieldData[fieldId].lastCrop3 == "" then
            self.fieldData[fieldId].lastCrop3 = nil
        end

        -- Load per-area zone cells
        local zi = 0
        while true do
            local zk = string.format("%s.zone(%d)", fieldKey, zi)
            local cellKey = getXMLString(xmlFile, zk .. "#key")
            if not cellKey then break end
            self.fieldData[fieldId].zoneData[cellKey] = {
                N  = getXMLFloat(xmlFile, zk .. "#N")  or 0,
                P  = getXMLFloat(xmlFile, zk .. "#P")  or 0,
                K  = getXMLFloat(xmlFile, zk .. "#K")  or 0,
                pH = getXMLFloat(xmlFile, zk .. "#pH") or 6.0,
                OM = getXMLFloat(xmlFile, zk .. "#OM") or 0,
                weedPressure = getXMLFloat(xmlFile, zk .. "#WP") or 0,
                pestPressure = getXMLFloat(xmlFile, zk .. "#PP") or 0,
                diseasePressure = getXMLFloat(xmlFile, zk .. "#DP") or 0,
                compaction = getXMLFloat(xmlFile, zk .. "#CP") or 0,
            }
            zi = zi + 1
        end

        -- Load per-cell compaction data and reconstruct running sum + average
        local zone = SoilConstants.ZONE
        local ci = 0
        local sumLoaded = 0
        while true do
            local ck = string.format("%s.compactionCell(%d)", fieldKey, ci)
            local cellKey = getXMLString(xmlFile, ck .. "#key")
            if not cellKey then break end
            local val = getXMLFloat(xmlFile, ck .. "#v") or 0
            if val > 0 then
                self.fieldData[fieldId].compactionCells[cellKey] = val
                sumLoaded = sumLoaded + val
            end
            ci = ci + 1
        end
        if ci > 0 then
            local areaInHa = self.fieldData[fieldId].fieldArea or 1.0
            local totalCells = math.max(1, math.ceil(areaInHa / zone.CELL_AREA_HA))
            self.fieldData[fieldId].compactionSum = sumLoaded
            self.fieldData[fieldId].compactionTotalCells = totalCells
            self.fieldData[fieldId].compaction = sumLoaded / totalCells
        end

        index = index + 1
    end

    self:info("Loaded data for %d fields", index)

    -- Push loaded values to density map layers so visual heatmap reflects saved state.
    -- This runs after loadFromXMLFile, so layerSystem may not be initialized yet
    -- (it initializes in SoilFertilitySystem:initialize which fires before loadSoilData).
    -- Guard: only run if the layer system is available.
    if self.layerSystem and self.layerSystem.available and g_farmlandManager then
        local pushed = 0
        for fieldId, data in pairs(self.fieldData) do
            local farmland = g_farmlandManager:getFarmlandById(fieldId)
            if farmland then
                self.layerSystem:writeFieldToLayers(fieldId, data, farmland)
                pushed = pushed + 1
            end
        end
        if pushed > 0 then
            self:info("Pushed %d fields to density map layers after load", pushed)
        end
    end

    -- Re-broadcast after load so clients that were connected during a
    -- save/load cycle get up-to-date values immediately.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo
       and g_currentMission.missionDynamicInfo.isMultiplayer then
        self:broadcastAllFieldData()
    end
end

-- Debug: List all fields
function SoilFertilitySystem:listAllFields()
    SoilLogger.info("=== Listing all fields ===")

    SoilLogger.info("Our tracked fields:")
    for fieldId, field in pairs(self.fieldData) do
        SoilLogger.info("  Field %d: N=%.1f, P=%.1f, K=%.1f, pH=%.1f, OM=%.2f%%",
            fieldId, field.nitrogen, field.phosphorus, field.potassium, field.pH, field.organicMatter)
    end

    if g_fieldManager and g_fieldManager.fields then
        SoilLogger.info("Fields in FieldManager:")
        for _, field in ipairs(g_fieldManager.fields) do
            -- NOTE: field.fieldId / field.id / field.index are all nil in FS25.
            -- The correct identifier is field.farmland.id (farmland-based ID system).
            local fieldIdStr = tostring(field.farmland and field.farmland.id or "?")
            local nameStr    = tostring(field.name or "Unknown")
            SoilLogger.info("  Field %s: Name=%s", fieldIdStr, nameStr)
        end
    end

    SoilLogger.info("=== End field list ===")
end

-- =========================================================
-- COMPACTION API (P2-D)
-- =========================================================

--- Apply compaction from a heavy vehicle work pass at a specific world position.
--- Throttled to once per cell per in-game day. Field-average is maintained as a
--- running sum over estimated total field cells so the nutrient penalty stays correct.
---@param farmlandId number
---@param worldX number  world X of the implement's work area centre
---@param worldZ number  world Z of the implement's work area centre
function SoilFertilitySystem:onCompaction(farmlandId, worldX, worldZ)
    if not self.settings.compactionEnabled then return end
    local cp = SoilConstants.COMPACTION
    if not cp then return end
    local field = self:getOrCreateField(farmlandId, false)
    if not field then return end

    local zone = SoilConstants.ZONE
    local cx = math.floor(worldX / zone.CELL_SIZE)
    local cz = math.floor(worldZ / zone.CELL_SIZE)
    local cellKey = tostring(cx * 10000 + cz)

    local currentDay = (g_currentMission and g_currentMission.environment and
                        g_currentMission.environment.currentDay) or 0

    if not field.compactionCellDays then field.compactionCellDays = {} end
    if field.compactionCellDays[cellKey] == currentDay then return end
    field.compactionCellDays[cellKey] = currentDay

    -- 1. Update unified zoneData for HUD/Map
    if not field.zoneData then field.zoneData = {} end
    if not field.zoneData[cellKey] then
        field.zoneData[cellKey] = {
            N = field.nitrogen, P = field.phosphorus, K = field.potassium,
            pH = field.pH, OM = field.organicMatter,
            weedPressure = field.weedPressure, pestPressure = field.pestPressure,
            diseasePressure = field.diseasePressure, compaction = field.compaction
        }
    end
    local cell = field.zoneData[cellKey]
    local prev = cell.compaction or 0
    local newVal = math.min(cp.MAX_COMPACTION, prev + cp.COMPACTION_PER_PASS)
    cell.compaction = newVal

    -- 2. Update field average
    field.compactionSum = (field.compactionSum or 0) + (newVal - prev)
    if (field.compactionTotalCells or 0) == 0 then
        local areaInHa = field.fieldArea or 1.0
        field.compactionTotalCells = math.max(1, math.ceil(areaInHa / zone.CELL_AREA_HA))
    end
    field.compaction = field.compactionSum / field.compactionTotalCells

    SoilLogger.debug("Compaction: field=%d cell=%s  %.0f→%.0f%%  avg=%.1f%%",
        farmlandId, cellKey, prev, newVal, field.compaction)
end

--- Apply subsoiler compaction reduction at a specific world position.
---@param farmlandId number
---@param worldX number
---@param worldZ number
function SoilFertilitySystem:onSubsoilerPass(farmlandId, worldX, worldZ)
    if not self.settings.compactionEnabled then return end
    local cp = SoilConstants.COMPACTION
    if not cp then return end
    local field = self:getOrCreateField(farmlandId, false)
    if not field then return end

    local zone = SoilConstants.ZONE
    local cx = math.floor(worldX / zone.CELL_SIZE)
    local cz = math.floor(worldZ / zone.CELL_SIZE)
    local cellKey = tostring(cx * 10000 + cz)

    if not field.zoneData then field.zoneData = {} end
    if not field.zoneData[cellKey] then
        field.zoneData[cellKey] = {
            N = field.nitrogen, P = field.phosphorus, K = field.potassium,
            pH = field.pH, OM = field.organicMatter,
            weedPressure = field.weedPressure, pestPressure = field.pestPressure,
            diseasePressure = field.diseasePressure, compaction = field.compaction
        }
    end
    local cell = field.zoneData[cellKey]
    local prev = cell.compaction or 0
    if prev <= 0 then return end

    local newVal = math.max(0, prev - cp.SUBSOILER_REDUCTION)
    cell.compaction = newVal

    field.compactionSum = math.max(0, (field.compactionSum or 0) - (prev - newVal))
    local tc = field.compactionTotalCells or 0
    field.compaction = tc > 0 and (field.compactionSum / tc) or 0

    SoilLogger.debug("Subsoiler: field=%d cell=%s  %.0f→%.0f%%  avg=%.1f%%",
        farmlandId, cellKey, prev, newVal, field.compaction)
end
