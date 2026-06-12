-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Core Simulation
-- =========================================================
-- Per-field N/P/K/pH/OM tracking: depletion on harvest,
-- restoration on fertilizer, rain leaching, seasonal effects,
-- and fallow recovery.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilFertilitySystem
SoilFertilitySystem = {}
local SoilFertilitySystem_mt = Class(SoilFertilitySystem)

local COVERAGE_MILESTONES = { 0.10, 0.25, 0.50, 0.75, 1.0 }

-- Resolve a 1-5 setting index to its TUNING LUT value.
-- Falls back to the index-3 value (the baseline) if the LUT is missing.
local function getTuningMult(settings, settingId, lutKey)
    local idx = (settings and settings[settingId]) or 3
    local lut = SoilConstants.TUNING and SoilConstants.TUNING[lutKey]
    if lut then return lut[idx] or lut[3] or 1.0 end
    return 1.0
end

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
    self.layerSystem  = SoilLayerSystem  and SoilLayerSystem.new()  or nil
    self.bundledMaps  = SoilBundledMaps  and SoilBundledMaps.new()  or nil

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

    -- Initialize density map layer integration FIRST so scanFields can read from GRLE.
    -- layerSystem.available must be true before scanFields runs or the GRLE seed is skipped.
    if self.layerSystem then
        self.layerSystem:initialize()
    end

    -- Initialize bundled GRLE maps (spatially-aware defaults for vanilla maps)
    if self.bundledMaps then
        self.bundledMaps:initialize()
    end

    -- Scan fields using real FieldManager (now runs with layerSystem ready)
    if g_fieldManager then
        self:scanFields()
    else
        self:warning("FieldManager not available - will try delayed initialization")
    end

    -- Install hooks via HookManager
    self.hookManager:installAll(self)

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
    if self.bundledMaps then
        self.bundledMaps:delete()
        self.bundledMaps = nil
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

    -- Return the frozen modifier if this crop's harvest is already in progress (#556).
    -- Without this, nutrient depletion from earlier passes drops the modifier for later
    -- passes of the same harvest run, causing yield to fall as the combine crosses the field.
    if field.frozenYieldModifier and field.frozenYieldFruitType == fruitTypeIndex then
        return field.frozenYieldModifier
    end

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

        local avgDef = (nDef + pDef + kDef) / 3

        local nutrientPenalty = math.min(ys.MAX_PENALTY, avgDef * tierData.scale)
        if nutrientPenalty > 0 then
            modifier = modifier * (1.0 - nutrientPenalty)
            self:log("Nutrient penalty field %d (%s/%s): N=%.0f P=%.0f K=%.0f → -%.0f%%",
                fieldId, cropName, tier, field.nitrogen, field.phosphorus, field.potassium, nutrientPenalty * 100)
        end
    end

    -- Weed pressure modifier (skip for grassland; skip when herbicide is active)
    if self.settings.weedPressure and SoilConstants.WEED_PRESSURE and not isGrass then
        local isProtected = (field.herbicideDaysLeft or 0) > 0
        if not isProtected then
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
    end

    -- Pest pressure modifier (skip for grassland / non-crop fields, same as weed pressure)
    if self.settings.pestPressure and SoilConstants.PEST_PRESSURE and not isGrass then
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

    -- Amendment burn penalty: lime or OM applied to growing crop (issue #437)
    if field.amendBurnPenalty and field.amendBurnPenalty > 0 then
        local burnPct = field.amendBurnPenalty
        modifier = modifier * (1.0 - burnPct)
        self:log("Amendment burn penalty field %d: -%.0f%%", fieldId, burnPct * 100)
        field.amendBurnPenalty   = nil
        field._amendBurnNotified = nil
    end

    -- Freeze for the duration of this harvest cycle. All subsequent modifier
    -- calls for this field+fruitType will return this snapshot value.
    field.frozenYieldModifier  = modifier
    field.frozenYieldFruitType = fruitTypeIndex

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
        harvestField._farmlandAreaConfirmed  = nil  -- re-confirm on next session's first spray (#507)
        harvestField.sprayTrailPts           = nil
        -- frozenYieldModifier is NOT cleared here (#598): onHarvest fires per-cut, so
        -- clearing here defeats the freeze and causes yield to drop with each combine pass.
        -- The freeze is cleared once per game day in _processOneDailyField instead.
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

    -- Broadcast to clients in multiplayer, throttled to once every 5 seconds per
    -- field+product combination. Keying on fillTypeIndex means switching fertilizer
    -- types (e.g. N → K) triggers an immediate first broadcast for the new product,
    -- rather than inheriting the cooldown from the previous product's last broadcast.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        local now = g_currentMission.time or 0
        if not self._fertBroadcastTime then self._fertBroadcastTime = {} end
        local bKey = fieldId .. "_" .. tostring(fillTypeIndex)
        local last = self._fertBroadcastTime[bKey] or 0
        if (now - last) >= 5000 then
            self._fertBroadcastTime[bKey] = now
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
        -- Clear GRLE so unmasked DMV no longer colours this unowned field.
        if self.layerSystem and self.layerSystem.available then
            self.layerSystem:clearFieldFromLayers(fieldId, nil)
        end
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

--- Resets session spray coverage (pass %) for a field.
--- Called on harvest, tillage (plow/cultivate/weed) and game-day change so that
--- stale coverage does not suppress the next legitimate spraying pass.
---@param fieldId number
---@param reason string|nil Debug label for the log line
function SoilFertilitySystem:resetSessionCoverage(fieldId, reason)
    local field = self.fieldData[fieldId]
    if not field then return end
    local hasCells = field.sessionCoverageCells and next(field.sessionCoverageCells) ~= nil
    if not hasCells and (field.sessionCoverageHa or 0) == 0 then return end
    field.sessionCoverageHa       = 0
    field.sessionCoverageFraction = 0
    field.sessionCoverageCells    = {}
    field.sessionLastProduct      = nil
    field._farmlandAreaConfirmed  = nil
    field.sprayTrailPts           = nil
    SoilLogger.debug("Session coverage reset: field %d (%s)", fieldId, reason or "?")
end

--- Hook delegate: called by HookManager when plowing occurs
--- Increases organic matter and normalizes pH
---@param fieldId number The field being plowed
---@param area number Area processed in hectares (e.g. from lastStatsArea)
---@param isAlsoSprayer boolean|nil True if the implement also sprays (combo tools) — skip coverage reset
function SoilFertilitySystem:onPlowing(fieldId, area, isAlsoSprayer)
    if not fieldId or fieldId <= 0 then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Tillage destroys the spray application context — reset pass % so the next
    -- spraying run is not overlap-suppressed by stale coverage. Combo implements
    -- that spray while tilling would wipe their own coverage every tick, so skip.
    if not isAlsoSprayer then
        self:resetSessionCoverage(fieldId, "plowing")
    end

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
---@param isAlsoSprayer boolean|nil True if the implement also sprays (combo tools) — skip coverage reset
function SoilFertilitySystem:onCultivation(fieldId, area, isAlsoSprayer)
    if not fieldId or fieldId <= 0 then return end
    if not SoilConstants.CULTIVATION then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Tillage destroys the spray application context — reset pass % (see onPlowing).
    if not isAlsoSprayer then
        self:resetSessionCoverage(fieldId, "cultivation")
    end

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
    self:log("[Herbicide] onHerbicideApplied called: fieldId=%s effectiveness=%s weedPressureSetting=%s",
        tostring(fieldId), tostring(effectiveness), tostring(self.settings.weedPressure))
    if not self.settings.weedPressure then return end
    if not SoilConstants.WEED_PRESSURE then return end

    local field = self:getOrCreateField(fieldId, false)
    if not field then
        self:log("[Herbicide] SKIP: no field data for fieldId=%s", tostring(fieldId))
        return
    end

    -- Throttle: apply pressure reduction at most once per field per in-game day.
    -- The sprayer hook fires every frame (~60x/sec). Without this guard, a single
    -- pass applies the full reduction hundreds of times, instantly zeroing pressure.
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if self.herbicideAppliedDay[fieldId] == today then
        self:log("[Herbicide] SKIP: already applied today (day=%s) for fieldId=%s", tostring(today), tostring(fieldId))
        return
    end
    self.herbicideAppliedDay[fieldId] = today

    local wp = SoilConstants.WEED_PRESSURE
    local reduction = wp.HERBICIDE_PRESSURE_REDUCTION * (effectiveness or 1.0)
    local before = field.weedPressure or 0
    field.weedPressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.herbicideDaysLeft = wp.HERBICIDE_DURATION_DAYS * daysPerMonth

    self:log("[Herbicide] Field %d: weed pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.weedPressure, field.herbicideDaysLeft)

    -- Transition weeds to withered (brown) visual state in the game's density map.
    -- The game's FieldState.weedFactor stays high until the density map is updated, so
    -- we drive it ourselves: withered now so weeds turn brown, cleared on next daily tick.
    self:applyWeedMapState(fieldId, SoilConstants.WEED_PRESSURE.WEED_STATE_WITHERED)

    -- Broadcast in multiplayer
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end
end

--- Writes a weed state to the game's density map for the given field.
--- When targetState is WEED_STATE_WITHERED, reads the field's current weed state and
--- looks up its herbicide replacement via weedSystem:getHerbicideReplacements() so we
--- transition to the correct withered equivalent rather than hardcoding state 7.
--- When targetState is WEED_STATE_CLEAR (0), unconditionally clears all weeds.
--- Uses FieldUpdateTask — same API as EasyDevControls, server-side only.
---@param fieldId number
---@param targetState number  WEED_STATE_WITHERED or WEED_STATE_CLEAR
function SoilFertilitySystem:applyWeedMapState(fieldId, targetState)
    self:log("[WeedMap] applyWeedMapState called: fieldId=%s targetState=%s isServer=%s",
        tostring(fieldId), tostring(targetState), tostring(g_server ~= nil))

    if not g_server then
        self:log("[WeedMap] SKIP: not server")
        return
    end

    local weedSystem = g_currentMission and g_currentMission.weedSystem
    if not weedSystem then
        self:log("[WeedMap] SKIP: no weedSystem")
        return
    end
    local mapHasWeed = false
    local hwOk, hwResult = pcall(function() return weedSystem:getMapHasWeed() end)
    if hwOk then mapHasWeed = hwResult end
    self:log("[WeedMap] weedSystem:getMapHasWeed() = %s (pcallOk=%s)", tostring(mapHasWeed), tostring(hwOk))
    if not mapHasWeed then
        self:log("[WeedMap] SKIP: map has no weed system")
        return
    end

    -- fieldId is the farmland ID — getFieldById uses field's own internal ID (different).
    -- Search by farmland.id instead, matching the pattern used in the daily update.
    local fsField = nil
    if g_fieldManager and g_fieldManager.fields then
        fsField = g_fieldManager.fields[fieldId]
        if not fsField or not fsField.farmland then
            for _, f in pairs(g_fieldManager.fields) do
                if f and f.farmland and f.farmland.id == fieldId then
                    fsField = f
                    break
                end
            end
        end
    end
    if not fsField then
        self:log("[WeedMap] SKIP: could not find field object for farmlandId=%s (fields count=%s)",
            tostring(fieldId), tostring(g_fieldManager and g_fieldManager.fields and #g_fieldManager.fields or "nil"))
        return
    end
    self:log("[WeedMap] Found field: farmlandId=%s fieldId=%s name=%s",
        tostring(fieldId), tostring(fsField.fieldId or fsField.id or "?"), tostring(fsField.fieldName or "?"))

    local weedState = targetState

    -- For withered transitions: look up the correct target state from the game's
    -- own herbicide replacement table instead of hardcoding state 7.
    if targetState == SoilConstants.WEED_PRESSURE.WEED_STATE_WITHERED then
        local repOk, repData = pcall(function() return weedSystem:getHerbicideReplacements() end)
        self:log("[WeedMap] getHerbicideReplacements: ok=%s hasWeed=%s hasReplacements=%s",
            tostring(repOk),
            tostring(repOk and repData and repData.weed ~= nil),
            tostring(repOk and repData and repData.weed and repData.weed.replacements ~= nil))

        if repOk and repData and repData.weed and repData.weed.replacements then
            local posX, posZ = fsField.posX, fsField.posZ
            local fieldState = FieldState.new()
            fieldState:update(posX, posZ)
            local currentState = fieldState.weedState or 0
            local replacement = repData.weed.replacements[currentState]
            self:log("[WeedMap] Field %d: indicatorPos=(%.1f,%.1f) currentWeedState=%s replacement=%s",
                fieldId, posX or 0, posZ or 0, tostring(currentState), tostring(replacement))
            if replacement and replacement ~= 0 then
                weedState = replacement
                self:log("[WeedMap] Using replacement state %d", weedState)
            else
                self:log("[WeedMap] No replacement for state %d — using fallback state %d", currentState, weedState)
            end
        end
    end

    self:log("[WeedMap] Enqueuing FieldUpdateTask: fieldId=%s weedState=%s", tostring(fieldId), tostring(weedState))
    local ok, err = pcall(function()
        local task = FieldUpdateTask.new()
        task:setField(fsField)
        task:setArea(fsField:getDensityMapPolygon())
        task:setWeedState(weedState)
        task:enqueue(true)
    end)
    self:log("[WeedMap] FieldUpdateTask result: ok=%s err=%s", tostring(ok), tostring(err))
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
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.insecticideDaysLeft = pp.INSECTICIDE_DURATION_DAYS * daysPerMonth
    end

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
    local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[self.settings.diseaseMoisture or 2]
        or SoilConstants.DISEASE_CLIMATE_MOISTURE[2]

    local reduction = dp.FUNGICIDE_PRESSURE_REDUCTION * (effectiveness or 1.0)
    local before = field.diseasePressure or 0
    field.diseasePressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.fungicideDaysLeft = math.floor(dp.FUNGICIDE_DURATION_DAYS * cm.fungicideMult * daysPerMonth)
    end

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
                -- Prefer the actual crop polygon area (field.areaHa) over farmland.areaInHa.
                -- Farmlands include roads, hedges, and uncultivable land — typically ~2× the
                -- actual sprayed area — which causes Pass% to cap at ~50% after a full field pass.
                -- field.areaHa defaults to 1.0 before the polygon loads; skip it when it is
                -- suspiciously close to that sentinel value so we don't record tiny false areas.
                -- initialize() runs after loadMission00Finished so polygons are loaded by now.
                local farmlandArea = (field.farmland and field.farmland.areaInHa) or 1.0
                local cropArea     = field.areaHa
                local area
                if cropArea and math.abs(cropArea - 1.0) > 0.05 and cropArea <= farmlandArea + 0.1 then
                    area = cropArea
                else
                    area = farmlandArea
                end

                SoilLogger.debug("Found field %d (%.2f ha)", actualFieldId, area)

                local isNew = self.fieldData[actualFieldId] == nil
                self:getOrCreateField(actualFieldId, true, area)

                -- If this is a newly created field and density layers are available,
                -- read existing layer values (pre-seeded GRLE) instead of using defaults.
                if isNew and self.layerSystem and self.layerSystem.available then
                    -- Pass the Field object (not field.farmland) — Field has polygonPoints for AABB
                    self.layerSystem:readFieldFromLayers(actualFieldId, self.fieldData[actualFieldId], field)
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
                if self.layerSystem and self.layerSystem.available and farmlandObj then
                    self.layerSystem:readFieldFromLayers(farmlandId, self.fieldData[farmlandId], farmlandObj)
                end
                local farmlandOwner2 = g_farmlandManager:getFarmlandOwner(farmlandId)
                if farmlandOwner2 and farmlandOwner2 > 0 then
                    self:_addToActiveSet(farmlandId)
                end
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
        -- 1664525 / 1013904223 are the standard Numerical Recipes LCG constants;
        -- 4294967296 = 2^32 is the modulus (the LCG period).
        n = (n * 1664525 + 1013904223) % 4294967296
        n = (n * 1664525 + 1013904223) % 4294967296
        return n / 4294967296
    end
    local function randField(slot)
        -- Each nutrient gets its own deterministic slot so values are independent.
        -- 67890 is an arbitrary large stride that spreads adjacent fieldIds far apart
        -- in the hash input, so neighbouring fields don't get correlated variation.
        local r = hash(fieldId * 67890 + slot)
        return r * 2.0 - 1.0  -- range [-1.0, 1.0]
    end

    local function randomize(baseValue, variation, slot)
        return baseValue + randField(slot) * variation
    end

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

    local tunN  = getTuningMult(self.settings, "tuningDefaultN",  "DEFAULT_N")
    local tunP  = getTuningMult(self.settings, "tuningDefaultP",  "DEFAULT_P")
    local tunK  = getTuningMult(self.settings, "tuningDefaultK",  "DEFAULT_K")
    local tunPH = getTuningMult(self.settings, "tuningDefaultPH", "DEFAULT_PH")
    local tunOM = getTuningMult(self.settings, "tuningDefaultOM", "DEFAULT_OM")

    self.fieldData[fieldId] = {
        fieldArea = initialArea,
        _farmlandAreaConfirmed = confirmedArea,
        -- Clamp to [0,100] to match the load path (:3518-3520). At tuning index 5
        -- DEFAULT_N/DEFAULT_K = 100, and the ±10% variation can floor to ~110, so an
        -- unclamped fresh field would read N>100 until the first save/reload snapped
        -- it back down. Clamping here keeps init and reload values consistent.
        nitrogen   = math.max(0, math.min(100, math.floor(randomize(tunN,  tunN  * 0.10, 1)))),
        phosphorus = math.max(0, math.min(100, math.floor(randomize(tunP,  tunP  * 0.10, 2)))),
        potassium  = math.max(0, math.min(100, math.floor(randomize(tunK,  tunK  * 0.10, 3)))),
        organicMatter = math.max(1.0, math.min(10.0, randomize(tunOM, 0.5, 4))),
        pH            = math.max(5.0, math.min(8.5,  randomize(tunPH, 0.5, 5))),
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

    -- Bundled GRLE override: replace randomized pH with spatially-aware value
    -- from the pre-baked regional map. Only fires when terrain info layers are
    -- absent (SoilLayerSystem.available = false), so prepared maps are unaffected.
    if not (self.layerSystem and self.layerSystem.available) then
        if self.bundledMaps and self.bundledMaps.available and g_farmlandManager then
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj then
                local cx, cz = self.bundledMaps:getFarmlandCenter(farmlandObj)
                if cx ~= nil then
                    local sampledPH = self.bundledMaps:sampleAtWorldPos(cx, cz)
                    if sampledPH ~= nil then
                        self.fieldData[fieldId].pH = sampledPH
                        SoilLogger.debug("BundledMaps: field %d pH set to %.2f from GRLE (world %.0f,%.0f)", fieldId, sampledPH, cx, cz)
                    end
                end
            end
        end
    end

    self:log("Lazy-created field %d area=%.2f ha confirmed=%s",
        fieldId, self.fieldData[fieldId].fieldArea, tostring(confirmedArea))

    -- Pre-populate zone tiles immediately so the overlay shows at full opacity
    -- as soon as a new field is created (e.g. on farmland purchase).
    self:_prePopulateZoneData(fieldId)

    return self.fieldData[fieldId]
end

-- ── Zone Data Pre-Population ──────────────────────────────────────────────────

-- Maximum zone cells stored per field. Prevents unbounded memory growth and network
-- packet overflow on large/intensively-farmed fields (see markBoomCells, applyFertilizer).
local MAX_ZONE_CELLS = 1000

-- Ray-casting point-in-polygon (XZ plane). verts: array of {x, z}.
local function _isPointInPoly(px, pz, verts)
    local n = #verts
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local xi, zi = verts[i].x, verts[i].z
        local xj, zj = verts[j].x, verts[j].z
        if ((zi > pz) ~= (zj > pz)) and
           (px < (xj - xi) * (pz - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Pre-populate zoneData for a single field so overlay tiles show at full opacity on load.
-- Samples the field polygon at CELL_SIZE step, clamps total cells to MAX_ZONE_CELLS.
function SoilFertilitySystem:_prePopulateZoneData(fieldId)
    local field = self.fieldData[fieldId]
    if not field then return end
    -- Skip if already populated (sprayer has already been active this session)
    if next(field.zoneData) ~= nil then return end

    -- Find the FS25 field object (farmland-keyed) from g_fieldManager
    local fsField = nil
    if g_fieldManager and g_fieldManager.fields then
        for _, f in ipairs(g_fieldManager.fields) do
            if f and f.farmland and f.farmland.id == fieldId then
                fsField = f
                break
            end
        end
    end
    if not fsField then return end

    -- Collect polygon vertices
    local polyNodes = fsField.polygonPoints
    local verts = {}
    if polyNodes and #polyNodes > 0 then
        for i = 1, #polyNodes do
            local nodeId = polyNodes[i]
            if nodeId and nodeId ~= 0 then
                local ok, wx, _, wz = pcall(getWorldTranslation, nodeId)
                if ok and wx then
                    table.insert(verts, {x = wx, z = wz})
                end
            end
        end
    end

    -- Fallback to centroid only if polygon unavailable
    if #verts < 3 then
        if fsField.posX and fsField.posZ then
            local zone = SoilConstants.ZONE
            local cx = math.floor(fsField.posX / zone.CELL_SIZE)
            local cz = math.floor(fsField.posZ / zone.CELL_SIZE)
            local cellKey = tostring(cx * 10000 + cz)
            field.zoneData[cellKey] = {
                N = field.nitrogen, P = field.phosphorus, K = field.potassium,
                pH = field.pH, OM = field.organicMatter,
                weedPressure = field.weedPressure or 0,
                pestPressure = field.pestPressure or 0,
                diseasePressure = field.diseasePressure or 0,
                compaction = field.compaction or 0,
            }
        end
        return
    end

    -- Bounding box
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        if verts[i].x < minX then minX = verts[i].x end
        if verts[i].x > maxX then maxX = verts[i].x end
        if verts[i].z < minZ then minZ = verts[i].z end
        if verts[i].z > maxZ then maxZ = verts[i].z end
    end

    local zone = SoilConstants.ZONE
    local step = zone.CELL_SIZE  -- 10 m baseline

    -- Adaptive coarsening: if estimated cell count exceeds MAX_ZONE_CELLS, widen step
    local bboxW = maxX - minX
    local bboxH = maxZ - minZ
    local estCells = math.ceil(bboxW / step) * math.ceil(bboxH / step)
    if estCells > MAX_ZONE_CELLS then
        -- Scale step up so total fits, with a generous multiplier
        step = step * math.ceil(math.sqrt(estCells / MAX_ZONE_CELLS))
    end

    -- Snapshot current field-average values once (avoids repeated table lookups)
    local fN  = field.nitrogen
    local fP  = field.phosphorus
    local fK  = field.potassium
    local fPH = field.pH
    local fOM = field.organicMatter
    local fW  = field.weedPressure or 0
    local fPe = field.pestPressure or 0
    local fD  = field.diseasePressure or 0
    local fC  = field.compaction or 0

    local count = 0
    local startX = minX + step * 0.5
    local startZ = minZ + step * 0.5
    local x = startX
    while x <= maxX and count < MAX_ZONE_CELLS do
        local z = startZ
        while z <= maxZ and count < MAX_ZONE_CELLS do
            if _isPointInPoly(x, z, verts) then
                local cx2 = math.floor(x / zone.CELL_SIZE)
                local cz2 = math.floor(z / zone.CELL_SIZE)
                local cellKey = tostring(cx2 * 10000 + cz2)
                if not field.zoneData[cellKey] then
                    field.zoneData[cellKey] = {
                        N = fN, P = fP, K = fK,
                        pH = fPH, OM = fOM,
                        weedPressure = fW,
                        pestPressure = fPe,
                        diseasePressure = fD,
                        compaction = fC,
                    }
                    count = count + 1
                end
            end
            z = z + step
        end
        x = x + step
    end

    SoilLogger.debug("Pre-populated zone data: field %d, %d cells (step=%.0fm)", fieldId, count, step)
end

-- Pre-populate zone data for ALL loaded fields that have empty zoneData.
-- Called once after loadSoilData() so overlay tiles are visible from session start.
function SoilFertilitySystem:prePopulateAllZoneData()
    if not (g_fieldManager and g_fieldManager.fields) then return end
    local count = 0
    for fieldId in pairs(self.fieldData) do
        self:_prePopulateZoneData(fieldId)
        count = count + 1
    end
    SoilLogger.info("Zone data pre-population complete: %d field(s) processed", count)
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

    -- Session spray coverage (pass %) also resets on day change — stale coverage
    -- from a previous day must not suppress the next legitimate spraying run.
    field.sessionCoverageHa       = 0
    field.sessionCoverageFraction = 0
    field.sessionCoverageCells    = {}
    field.sessionLastProduct      = nil
    field.sprayTrailPts           = nil

    -- Clear the yield-modifier freeze from the previous harvest session (#598).
    -- Frozen on the first cut of a harvest pass and held until the next game day so
    -- that per-cut nutrient depletion does not cause yield to drop mid-harvest (#556).
    field.frozenYieldModifier  = nil
    field.frozenYieldFruitType = nil

    -- ── Compaction natural decay ─────────────────────────────────────────────
    if self.settings.compactionEnabled and SoilConstants.COMPACTION then
        local cp = SoilConstants.COMPACTION
        if (field.compaction or 0) > 0 then
            local tunComp = getTuningMult(self.settings, "tuningCompactionDecay", "ZERO_MULT")
            field.compaction = math.max(0, field.compaction - cp.NATURAL_DECAY_PER_DAY * timeFactor * tunComp)
        end
    end

    -- ── Fallow recovery ──────────────────────────────────────────────────────
    -- Fallow threshold also scales so it represents the same 'agricultural time' (months)
    local daysSinceFallow = currentDay - (field.lastHarvest or 0)
    if daysSinceFallow > SoilConstants.TIMING.FALLOW_THRESHOLD * daysPerMonth then
        local tunFallow = getTuningMult(self.settings, "tuningFallowRecovery", "ZERO_MULT")
        field.nitrogen      = math.min(limits.MAX, field.nitrogen      + recovery.nitrogen * timeFactor * tunFallow)
        field.phosphorus    = math.min(limits.MAX, field.phosphorus    + recovery.phosphorus * timeFactor * tunFallow)
        field.potassium     = math.min(limits.MAX, field.potassium     + recovery.potassium * timeFactor * tunFallow)
        field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX,
                                       field.organicMatter + recovery.organicMatter * timeFactor * tunFallow)
    end

    -- ── Seasonal nitrogen shift ──────────────────────────────────────────────
    if self.settings.seasonalEffects and season then
        local tunSeas = getTuningMult(self.settings, "tuningSeasonalStrength", "ZERO_MULT")
        if season == seasonal.SPRING_SEASON then
            field.nitrogen = math.min(limits.MAX, field.nitrogen + seasonal.SPRING_NITROGEN_BOOST * timeFactor * tunSeas)
        elseif season == seasonal.FALL_SEASON then
            field.nitrogen = math.max(limits.MIN, field.nitrogen - seasonal.FALL_NITROGEN_LOSS * timeFactor * tunSeas)
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

            -- Tick herbicideDaysLeft counter.
            -- When protection expires: reset session coverage so the next application
            -- requires a full field pass again rather than triggering on the first tick.
            -- Do NOT force WEED_STATE_CLEAR — state 7 (withered) transitions to 0
            -- naturally via the vanilla WeedSystem; forcing it here causes an abrupt
            -- "weeds vanish instantly" when time is fast-forwarded.
            if (field.herbicideDaysLeft or 0) > 0 then
                field.herbicideDaysLeft = field.herbicideDaysLeft - 1
                if field.herbicideDaysLeft == 0 then
                    field.sessionCoverageHa       = 0
                    field.sessionCoverageFraction = 0
                    field.sessionCoverageCells    = {}
                    field.sessionLastProduct      = nil
                    field.sprayTrailPts           = nil
                end
            end

            -- Sample FieldState.weedFactor from the game's weed density map.
            -- weedFactor: 0.0 = clean, 1.0 = fully weedy (matches FieldState default
            -- and getHarvestScaleMultiplier semantics — higher = more yield penalty).
            local gameWeedFactor = 0.0
            if g_fieldManager and g_fieldManager.fields then
                local fsField = g_fieldManager.fields[fieldId]
                if not fsField or not fsField.farmland or fsField.farmland.id ~= fieldId then
                    fsField = nil
                    for _, f in ipairs(g_fieldManager.fields) do
                        if f and f.farmland and f.farmland.id == fieldId then
                            fsField = f
                            break
                        end
                    end
                end
                if fsField and fsField.posX and fsField.posZ then
                    if not self._fieldStateCache then self._fieldStateCache = {} end
                    if not self._fieldStateCache[fieldId] then
                        local cok, cfs = pcall(FieldState.new)
                        self._fieldStateCache[fieldId] = (cok and cfs) and cfs or false
                    end
                    local cachedFs = self._fieldStateCache[fieldId]
                    local ok = cachedFs and pcall(function() cachedFs:update(fsField.posX, fsField.posZ) end)
                    local fs = cachedFs
                    -- Only trust weedFactor when a managed (non-forage) crop is present.
                    -- Bare/plowed fields: fruitTypeIndex=UNKNOWN, weedFactor=0 → skip.
                    -- Grass/forage crops: FS25 returns weedFactor=0 regardless of actual
                    -- weed state (grass coverage is indistinguishable from weeds in the
                    -- density map) → skip for NON_CROP_NAMES to avoid false 100%.
                    if ok and fs and fs.isValid and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
                        local fruitDesc = g_fruitTypeManager and
                            g_fruitTypeManager:getFruitTypeByIndex(fs.fruitTypeIndex)
                        local fruitName = fruitDesc and fruitDesc.name and
                            string.lower(fruitDesc.name) or ""
                        local nonCrops = (SoilConstants.YIELD_SENSITIVITY and
                            SoilConstants.YIELD_SENSITIVITY.NON_CROP_NAMES) or {}
                        if not nonCrops[fruitName] then
                            gameWeedFactor = fs.weedFactor
                        end
                    end
                end
            end
            -- When herbicide is active the game's density map still shows dying weeds for
            -- 1-2 days — reading it would overwrite the pressure reduction from onHerbicideApplied.
            -- Under protection, or when herbicide was applied today (even partial coverage), only
            -- allow pressure to decrease — never let the daily weedFactor read undo a reduction.
            -- herbicideAppliedDay is set by onHerbicideApplied (FERTILIZER_PROFILES path);
            -- herbicideDailyApplied is set by the direct-application path — check both.
            local herbicideAppliedToday =
                (self.herbicideDailyApplied and
                 self.herbicideDailyApplied[fieldId] and
                 self.herbicideDailyApplied[fieldId].day == currentDay)
                or (self.herbicideAppliedDay[fieldId] == currentDay)
            local target = math.max(0, math.min(100, gameWeedFactor * 100))
            if (field.herbicideDaysLeft or 0) > 0 or herbicideAppliedToday then
                -- Under herbicide protection: only allow pressure to decrease
                field.weedPressure = math.min(field.weedPressure or 0, target)
            else
                local current = field.weedPressure or 0
                if target > current then
                    -- Cap the daily increase to prevent reload/time-skip spikes (#536)
                    local maxIncrease = SoilConstants.WEED_PRESSURE.MAX_DAILY_INCREASE or 20
                    field.weedPressure = math.min(target, current + maxIncrease)
                else
                    field.weedPressure = target
                end
            end

            -- Sync zone cells so overlay map matches field-level weed pressure.
            -- Zone WP is only written during event-driven paths (spray/plow/cultivate),
            -- so without this propagation the overlay always shows stale 0 while the
            -- HUD shows the live FieldState-derived value.
            if field.zoneData then
                for _, cell in pairs(field.zoneData) do
                    cell.weedPressure = field.weedPressure
                end
            end

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
    -- Skip pest growth for grassland / non-crop fields (grass, drygrass, clover, etc.)
    local _ys           = SoilConstants.YIELD_SENSITIVITY
    local _isGrassField = _ys and _ys.NON_CROP_NAMES and
        _ys.NON_CROP_NAMES[string.lower(field.lastCrop or "")]
    if self.settings.pestPressure and SoilConstants.PEST_PRESSURE and not _isGrassField then
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

            local tunPest = getTuningMult(self.settings, "tuningPestGrowth", "ZERO_MULT")
            field.pestPressure = math.min(100, pressure + ((baseRate * seasonMult * cropMult * tunPest) + rainBonus) * timeFactor)
        end
    end

    -- ── Disease pressure daily growth ────────────────────────────────────────
    if self.settings.diseasePressure and SoilConstants.DISEASE_PRESSURE then
        local dp = SoilConstants.DISEASE_PRESSURE
        local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[self.settings.diseaseMoisture or 2]
            or SoilConstants.DISEASE_CLIMATE_MOISTURE[2]

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
        local dryThreshold = cm.dryThreshold * daysPerMonth

        if (field.dryDayCount or 0) >= dryThreshold then
            field.diseasePressure = math.max(0, pressure - dp.DRY_DECAY_RATE * cm.dryDecayMult * timeFactor)
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

            local rainBonus = isRaining and (dp.RAIN_BONUS * cm.rainBonusMult) or 0
            local tunDis = getTuningMult(self.settings, "tuningDiseaseGrowth", "ZERO_MULT")
            field.diseasePressure = math.min(100, pressure + ((baseRate * cm.growthMult * seasonMult * cropMult * tunDis) + rainBonus) * timeFactor)
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
                    field.lastAlertSeason = season
                end
            end
        end
    end

    -- NOTE: weed pressure is NOT re-read from the weed density map here.
    -- An older AABB-based sync (readWeedCoverageForFarmland) used to overwrite
    -- field.weedPressure at this point, silently undoing the herbicide-protection
    -- clamp and the MAX_DAILY_INCREASE spike cap applied above (#536) — withered
    -- weeds still count as coverage in that sampler. The FieldState.weedFactor
    -- read above is the single authoritative source.
    local layerSys = self.layerSystem

    -- ── Sync all nutrient/pressure layers to density maps ───────────────────
    -- Paint non-perPixel layers (pest/disease/compaction) with the daily average.
    -- N/P/K/pH/OM are skipped (skipPerPixel=true) so per-pixel spray history is
    -- preserved between daily updates.
    if layerSys and layerSys.available then
        local fsField = g_fieldManager and g_fieldManager.fields and g_fieldManager.fields[fieldId]
        if not fsField or not fsField.farmland or fsField.farmland.id ~= fieldId then
            fsField = nil
            if g_fieldManager and g_fieldManager.fields then
                for _, f in ipairs(g_fieldManager.fields) do
                    if f and f.farmland and f.farmland.id == fieldId then
                        fsField = f
                        break
                    end
                end
            end
        end
        if fsField then
            layerSys:writeFieldToLayers(fieldId, field, fsField, true)
        end
    end

    -- ── Broadcast to MP clients ──────────────────────────────────────────────
    if g_server and SoilFieldUpdateEvent then
        g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
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

    local tunRain = getTuningMult(self.settings, "tuningRainLeaching", "ZERO_MULT")
    local leachFactor = rainScale * dt * rain.LEACH_BASE_FACTOR * rweMultiplier * tunRain
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
    local tunDepl = getTuningMult(self.settings, "tuningNutrientDepletion", "RATE_MULT")
    field.nitrogen   = math.max(limits.MIN, field.nitrogen   - rates.N * factor * tunDepl)
    field.phosphorus = math.max(limits.MIN, field.phosphorus - rates.P * factor * tunDepl)
    field.potassium  = math.max(limits.MIN, field.potassium  - rates.K * factor * tunDepl)

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

    -- Issue #437: pH/OM amendment burn on growing crops.
    -- LIME/LIQUIDLIME on growing crop → -80% yield. OM amendments → -20%.
    -- Throttled to one warning per field per crop cycle via _amendBurnNotified flag.
    local isLimeAmendment = entry.pH and entry.pH > 0  -- raises pH (LIME, LIQUIDLIME)
    local isOMAmendment   = entry.OM and not (entry.pH and entry.pH > 0)
    if (isLimeAmendment or isOMAmendment) and not field._amendBurnNotified then
        local spx, spz = self._lastSprayX, self._lastSprayZ
        if spx and spz and g_farmlandManager then
            local farmlandTmp = g_farmlandManager:getFarmlandAtWorldPosition(spx, spz)
            local fsField = farmlandTmp and g_fieldManager and g_fieldManager.farmlandIdFieldMapping and g_fieldManager.farmlandIdFieldMapping[farmlandTmp.id]
            -- Issue #532: use live FieldState query (fsField.fieldState is stale on freshly-plowed/fallow fields)
            local hasCrop = false
            if fsField and fsField.posX and fsField.posZ then
                local ok, fs = pcall(function()
                    local s = FieldState.new()
                    s:update(fsField.posX, fsField.posZ)
                    return s
                end)
                hasCrop = ok and fs and fs.fruitTypeIndex ~= nil and fs.fruitTypeIndex ~= FruitType.UNKNOWN
            end
            if hasCrop then
                if isLimeAmendment then
                    field.amendBurnPenalty = 0.80
                    field._amendBurnNotified = true
                    self:showNotification(
                        g_i18n:getText("sf_notify_lime_crop_title"),
                        string.format(g_i18n:getText("sf_notify_lime_crop_body"), fieldId))
                else
                    field.amendBurnPenalty = math.max(field.amendBurnPenalty or 0, 0.20)
                    field._amendBurnNotified = true
                    self:showNotification(
                        g_i18n:getText("sf_notify_om_crop_title"),
                        string.format(g_i18n:getText("sf_notify_om_crop_body"), fieldId))
                end
            end
        end
    end

    local limits = SoilConstants.NUTRIENT_LIMITS

    -- AREA NORMALIZATION: Calculate hectares for this field.
    -- Confirm area on first spray of each session — prefer the actual crop polygon area (field.areaHa)
    -- because farmland.areaInHa includes roads/hedges (~2× crop area), which causes
    -- Pass% to cap at ~50% after a full field pass (issue #475/#476).
    -- Also re-confirm at the start of every new session so field-size changes (issue #507) take effect.
    local _isNewSession = not next(field.sessionCoverageCells or {})
    if (not field._farmlandAreaConfirmed or _isNewSession) and g_farmlandManager then
        local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
        if farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
            -- Try crop polygon area via farmland mapping (g_fieldManager has no getFieldAtWorldPosition)
            local cropField = nil
            if g_farmlandManager and self._lastSprayX and self._lastSprayZ then
                local _fl = g_farmlandManager:getFarmlandAtWorldPosition(self._lastSprayX, self._lastSprayZ)
                if _fl and g_fieldManager and g_fieldManager.farmlandIdFieldMapping then
                    cropField = g_fieldManager.farmlandIdFieldMapping[_fl.id]
                end
            end
            local cropArea  = cropField and cropField.areaHa
            if cropArea and math.abs(cropArea - 1.0) > 0.05 then
                field.fieldArea = cropArea
            else
                field.fieldArea = farmlandObj.areaInHa
            end
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

        local tunFert = getTuningMult(self.settings, "tuningFertilizerEfficiency", "RATE_MULT")
        if entry.N then field.nitrogen   = math.min(limits.MAX, field.nitrogen   + entry.N * factor * tunFert) end
        if entry.P then field.phosphorus = math.min(limits.MAX, field.phosphorus + entry.P * factor * tunFert) end
        if entry.K then field.potassium  = math.min(limits.MAX, field.potassium  + entry.K * factor * tunFert) end
        if entry.pH then field.pH        = math.max(limits.PH_MIN, math.min(limits.PH_MAX, field.pH + entry.pH * factor * tunFert)) end
        if entry.OM then field.organicMatter = math.max(0, math.min(limits.ORGANIC_MATTER_MAX, field.organicMatter + entry.OM * factor * tunFert)) end

        -- pH bulk sync: lime raises pH field-wide so all cells track it uniformly.
        -- N/P/K/OM are NOT bulk-synced — cells visited by the boom (markBoomCells)
        -- get the updated field average written there, while unvisited pre-populated
        -- cells keep their initial value. This creates spatial differentiation on the
        -- overlay map: freshly-sprayed areas show higher nutrient values than areas
        -- the boom hasn't reached yet.
        if entry.pH and field.zoneData then
            for _, cell in pairs(field.zoneData) do
                cell.pH = math.max(limits.PH_MIN, math.min(limits.PH_MAX, cell.pH + entry.pH * factor))
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

        -- Write updated values to density map layers (per-pixel, at sprayer position).
        -- No throttle — live updates paint a continuous trail on the minimap heatmap.
        if self.layerSystem and self.layerSystem.available then
            local x, z = self._lastSprayX, self._lastSprayZ
            if x and z then
                local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
                if minimapLayer then minimapLayer:markDirty() end
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

            -- Per-frame N/P/K/OM deltas (same formula as the field-average update above).
            -- Captured here so new cells can be initialised with PRE-update field values and
            -- then receive the delta once, preventing double-counting on first spray while
            -- keeping existing cells live on every subsequent pass.
            local dN  = entry.N  and (entry.N  * factor * tunFert) or 0
            local dP  = entry.P  and (entry.P  * factor * tunFert) or 0
            local dK  = entry.K  and (entry.K  * factor * tunFert) or 0
            local dOM = entry.OM and (entry.OM * factor * tunFert) or 0

            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                local zdCount = 0
                for _ in pairs(field.zoneData) do zdCount = zdCount + 1 end
                if zdCount < MAX_ZONE_CELLS then
                    field.zoneData[cellKey] = {
                        -- Pre-update values: the delta block below brings this cell to the
                        -- same level as the field average without double-counting the delta.
                        N  = math.max(limits.MIN, field.nitrogen      - dN),
                        P  = math.max(limits.MIN, field.phosphorus    - dP),
                        K  = math.max(limits.MIN, field.potassium     - dK),
                        pH = field.pH,   -- pH already post-update via bulk sync above
                        OM = math.max(0, field.organicMatter          - dOM),
                        weedPressure    = field.weedPressure,
                        pestPressure    = field.pestPressure,
                        diseasePressure = field.diseasePressure,
                        compaction      = field.compaction,
                    }
                end
            end
            local cell = field.zoneData[cellKey]
            if not cell then return end

            -- Apply N/P/K/OM delta to this specific cell so it tracks live nutrient levels
            -- rather than a stale snapshot of the field average at first-application time.
            -- pH is handled by the bulk sync above (applied to all cells uniformly).
            -- Pest/disease are position-specific and handled separately below.
            -- cellFactor note: must use areaInHa (not zone.CELL_AREA_HA) — see issue #205 Bug 2.
            if dN  > 0 then cell.N  = math.min(limits.MAX,                cell.N  + dN)  end
            if dP  > 0 then cell.P  = math.min(limits.MAX,                cell.P  + dP)  end
            if dK  > 0 then cell.K  = math.min(limits.MAX,                cell.K  + dK)  end
            if dOM > 0 then cell.OM = math.min(limits.ORGANIC_MATTER_MAX, cell.OM + dOM) end

            local cellFactor = (liters / 1000.0) / areaInHa
            if entry.pestReduction    then cell.pestPressure    = math.max(0, (cell.pestPressure    or field.pestPressure    or 0) - entry.pestReduction    * cellFactor) end
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
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.insecticideDaysLeft = pp.INSECTICIDE_DURATION_DAYS * daysPerMonth
    end

    -- Update per-cell pest pressure for existing zoneData entries only.
    -- Do NOT create new entries here — doing so would stamp N/P/K/pH/OM field-average
    -- values onto cells the insecticide boom passes over, making those cells appear
    -- "treated with nutrients" on the soil map overlay (issue #517 root cause).
    local x, z = self._lastSprayX, self._lastSprayZ
    if x and z and field.zoneData then
        local zone = SoilConstants.ZONE
        local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
        local cell = field.zoneData[cellKey]
        if cell then
            cell.pestPressure = math.max(0, (cell.pestPressure or field.pestPressure or 0) - reduction)
        end
    end
end

--- Incremental fungicide application
function SoilFertilitySystem:onFungicideAppliedIncremental(fieldId, reduction)
    if not self.settings.diseasePressure then return end
    local field = self:getOrCreateField(fieldId, false)
    if not field then return end

    local dp = SoilConstants.DISEASE_PRESSURE
    local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[self.settings.diseaseMoisture or 2]
        or SoilConstants.DISEASE_CLIMATE_MOISTURE[2]
    local before = field.diseasePressure or 0
    field.diseasePressure = math.max(0, before - reduction)
    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.fungicideDaysLeft = math.floor(dp.FUNGICIDE_DURATION_DAYS * (cm.fungicideMult or 1) * daysPerMonth)
    end

    -- Update per-cell disease pressure for existing zoneData entries only.
    -- Do NOT create new entries here — doing so would stamp N/P/K/pH/OM field-average
    -- values onto cells the fungicide boom passes over, making those cells appear
    -- "treated with nutrients" on the soil map overlay (issue #517 root cause).
    local x, z = self._lastSprayX, self._lastSprayZ
    if x and z and field.zoneData then
        local zone = SoilConstants.ZONE
        local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
        local cell = field.zoneData[cellKey]
        if cell then
            cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - reduction)
        end
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

    -- Reset session coverage when the product changes (issue #442)
    if fillTypeName and field.sessionLastProduct and fillTypeName ~= field.sessionLastProduct then
        field.sessionCoverageHa       = 0
        field.sessionCoverageFraction = 0
        field.sessionCoverageCells    = {}
        field.sprayTrailPts           = nil
    end

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
            -- Store stamp timestamp (ms) so the overlap check can apply a grace period
            -- and avoid suppressing sections that are still on their current pass.
            if not field.sessionCoverageCells[cellKey] then
                field.sessionCoverageCells[cellKey] = (g_currentMission and g_currentMission.time) or 0
                field.sessionCoverageHa = math.min(areaInHa, (field.sessionCoverageHa or 0) + cellArea)
                -- ── Spray trail (in-view overlay) ──────────────────────────────
                -- Cache world-center + terrain height for SoilHUD:drawSprayTrail().
                if not field.sprayTrailPts then field.sprayTrailPts = {} end
                local twx = (cx + 0.5) * zone.CELL_SIZE
                local twz = (cz + 0.5) * zone.CELL_SIZE
                local twy = 0.3
                if g_terrainNode then
                    local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, twx, 0, twz)
                    if ok and h then twy = h + 0.3 end
                end
                table.insert(field.sprayTrailPts, {wx = twx, wy = twy, wz = twz})
            end
            if not field.dailyCoverageCells[cellKey] then
                field.dailyCoverageCells[cellKey] = true
                field.coveredAreaHa = math.min(areaInHa, (field.coveredAreaHa or 0) + cellArea)
            end

            -- ── Visual overlay (zoneData) ──────────────────────────────────────
            -- Enforce cell cap: only affects sub-field visual detail, not coverage accuracy.
            -- Use a tracked counter (field.zoneDataSize) instead of iterating pairs every tick.
            local canWrite = true
            if field.zoneData[cellKey] == nil then
                if (field.zoneDataSize or 0) >= MAX_ZONE_CELLS then canWrite = false end
            end
            if canWrite then
                if field.zoneData[cellKey] == nil then
                    field.zoneDataSize = (field.zoneDataSize or 0) + 1
                end
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

    -- Full pass complete — clear trail so the overlay disappears as a visual reward.
    -- Match the 0.99 threshold used by overlap prevention so dots clear when the
    -- sprayer auto-shuts off rather than requiring the last fractional percent.
    if (field.sessionCoverageFraction or 0) >= 0.99 and field.sprayTrailPts then
        field.sprayTrailPts = nil
    end
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
        -- Only grant protected status once 80% of the field has been covered (issue #441)
        local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
        local wasProtected = (field.herbicideDaysLeft or 0) > 0
        if (field.sessionCoverageFraction or 0) >= protThreshold then
            field.herbicideDaysLeft = SoilConstants.WEED_PRESSURE.HERBICIDE_DURATION_DAYS * daysPerMonth
            -- Apply weed map state (visual browning) exactly once when protection is first granted.
            -- applyWeedMapState is server-only; guards inside it handle the nil-field case.
            if not wasProtected and g_server then
                self:applyWeedMapState(fieldId, SoilConstants.WEED_PRESSURE.WEED_STATE_WITHERED)
            end
        end

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
    self:trackSprayerCoverage(fieldId, liters, "HERBICIDE", false)
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

    local function nutrientStatus(value, nutrient, ct)
        local t = thresholds[nutrient]
        if not t then return "Unknown" end
        if value < t.poor then return "Poor" end
        -- When a crop is growing, treat its opt target as the Good threshold if lower
        -- than the global threshold — so reaching the crop's blue tick always shows Good.
        local goodAt = t.fair
        if ct then
            local nutKey = nutrient == "nitrogen" and "N"
                        or nutrient == "phosphorus" and "P"
                        or "K"
            local entry = ct[nutKey]
            if entry and entry.opt and entry.opt < goodAt then goodAt = entry.opt end
        end
        if value < goodAt then return "Fair"
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

    -- Grass/forage crops return weedFactor=0 from FS25's density map regardless
    -- of actual weed state, producing a false 100% reading. Zero out weedPressure
    -- immediately in the info table so all displays are correct without waiting
    -- for the next daily update to rewrite the stored value.
    local nonCrops = SoilConstants.YIELD_SENSITIVITY and
        SoilConstants.YIELD_SENSITIVITY.NON_CROP_NAMES or {}
    local cropLowerInfo = cropName and string.lower(cropName) or ""
    local isNonCropField = nonCrops[cropLowerInfo]

    -- Yield efficiency estimate: combines nutrient deficit + weed/pest/disease penalties.
    -- nil when no managed crop is present (bare, grass, forage).
    -- Mirrors computeYieldModifier but reads from local variables already resolved above.
    local yieldEfficiency = nil
    if not isNonCropField and cropName and cropName ~= "" then
        local ys = SoilConstants.YIELD_SENSITIVITY
        if ys and ys.TIERS and ys.OPTIMAL_THRESHOLD then
            local thresh = ys.OPTIMAL_THRESHOLD
            local nDef = math.max(0, thresh - n) / thresh
            local pDef = math.max(0, thresh - p) / thresh
            local kDef = math.max(0, thresh - k) / thresh

            local avgDef = (nDef + pDef + kDef) / 3

            local tier     = ys.CROP_TIERS[cropLowerInfo] or ys.DEFAULT_TIER
            local tierData = ys.TIERS[tier]
            local mod = 1.0 - math.min(ys.MAX_PENALTY, avgDef * tierData.scale)

            local function applyPressurePenalty(settingKey, pressureTable, pressureValue)
                if not (self.settings[settingKey] and pressureTable) then return mod end
                local pv = pressureValue or 0
                local penalty = pv < pressureTable.LOW    and pressureTable.YIELD_PENALTY_LOW  or
                                pv < pressureTable.MEDIUM and pressureTable.YIELD_PENALTY_MID  or
                                pv < pressureTable.HIGH   and pressureTable.YIELD_PENALTY_HIGH or
                                pressureTable.YIELD_PENALTY_PEAK
                return mod * (1.0 - penalty)
            end

            mod = applyPressurePenalty("weedPressure",    SoilConstants.WEED_PRESSURE,    field.weedPressure)
            mod = applyPressurePenalty("pestPressure",    SoilConstants.PEST_PRESSURE,    field.pestPressure)
            mod = applyPressurePenalty("diseasePressure", SoilConstants.DISEASE_PRESSURE, field.diseasePressure)

            yieldEfficiency = math.floor(mod * 100 + 0.5)
        end
    end

    return {
        fieldId = fieldId,
        fieldArea = field.fieldArea or 1.0,
        nitrogen = { value = math.floor(n), status = nutrientStatus(n, "nitrogen", cropTargets) },
        phosphorus = { value = math.floor(p), status = nutrientStatus(p, "phosphorus", cropTargets) },
        potassium = { value = math.floor(k), status = nutrientStatus(k, "potassium", cropTargets) },
        cropTargets = cropTargets,
        organicMatter = om,
        pH = ph,
        lastCrop = cropName,
        lastCrop2 = field.lastCrop2,
        rotationStatus = rotationStatus,
        daysSinceHarvest = field.lastHarvest > 0 and (currentDay - field.lastHarvest) or 0,
        fertilizerApplied = field.fertilizerApplied or 0,
        yieldEfficiency = yieldEfficiency,
        weedPressure = isNonCropField and 0 or (field.weedPressure or 0),
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
            setXMLInt(xmlFile, fieldKey .. "#lastAlertSeason", field.lastAlertSeason or 0)
            setXMLFloat(xmlFile, fieldKey .. "#coverageFraction", field.coverageFraction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#compaction", field.compaction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#amendBurnPenalty", field.amendBurnPenalty or 0)

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
            SoilLogger.warning("Skipping corrupted field entry %s (type: %s)", tostring(fieldId), type(field))
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
            amendBurnPenalty = getXMLFloat(xmlFile, fieldKey .. "#amendBurnPenalty") or nil,
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
            coveredAreaHa = 0,        -- restored below from coverageFraction × fieldArea
            dailyCoverageCells = {},
            sessionCoverageHa = 0,    -- restored below
            sessionCoverageFraction = 0,
            sessionCoverageCells = {},
            sessionLastProduct = nil,
        }

        -- Restore coverage tracking so pass% persists across reloads (#608).
        -- sessionCoverageCells is intentionally left empty (timestamps are session-local),
        -- but the ha/fraction values are seeded from the saved cumulative coverage so the
        -- sprayer panel displays the correct % immediately on reload and markBoomCells
        -- continues accumulating from the right baseline instead of resetting to 0.
        do
            local f    = self.fieldData[fieldId]
            local ha   = f.coverageFraction * f.fieldArea
            f.coveredAreaHa           = ha
            f.sessionCoverageHa       = ha
            f.sessionCoverageFraction = f.coverageFraction
        end

        -- Load daily application throttles
        self.herbicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#herbicideAppliedDay") or 0
        self.insecticideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#insecticideAppliedDay") or 0
        self.fungicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#fungicideAppliedDay") or 0

        -- Refresh fieldArea — prefer the actual crop polygon area (field.areaHa) so that
        -- Pass% uses the correct denominator. Farmland.areaInHa includes roads/hedges
        -- (~2× crop area), causing Pass% to cap at ~50% on a full-field spray (#475/#476).
        -- Use farmland area as fallback when crop polygon area is the unloaded default (1.0).
        if g_farmlandManager then
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
                local bestArea = farmlandObj.areaInHa
                if g_fieldManager and g_fieldManager.fields then
                    for _, fld in ipairs(g_fieldManager.fields) do
                        if fld and fld.farmland and fld.farmland.id == fieldId then
                            local ca = fld.areaHa
                            if ca and math.abs(ca - 1.0) > 0.05 and ca <= farmlandObj.areaInHa + 0.1 then
                                bestArea = ca
                                break
                            end
                        end
                    end
                end
                self.fieldData[fieldId].fieldArea = bestArea
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
    -- GRLE minimap heatmap is populated per-pixel by sprayer events (updatePixelForField).
    -- Bulk AABB seeding at load would paint field bounding boxes onto the terrain texture,
    -- creating rectangular blobs that ignore field polygon shapes.  The SoilLayerInstaller
    -- creates blank (all-zero) GRLE files; zero pixels are transparent in the DMV overlay,
    -- so the minimap correctly starts blank and fills in as the player actually sprays.

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

    -- 3. Write per-pixel to compaction density map layer
    if self.layerSystem and self.layerSystem.available then
        self.layerSystem:updatePixelForField("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
    end

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

    -- Write per-pixel to compaction density map layer
    if self.layerSystem and self.layerSystem.available then
        self.layerSystem:updatePixelForField("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
    end

    SoilLogger.debug("Subsoiler: field=%d cell=%s  %.0f→%.0f%%  avg=%.1f%%",
        farmlandId, cellKey, prev, newVal, field.compaction)
end

--- Records one combine-pass cell for the harvest trail overlay.
--- Deduplicates by 10×10 m cell. Resets on a new game day (new harvest session).
--- Auto-clears when estimated full-field coverage is reached.
---@param fieldId number
---@param wx      number  World X (combine rootNode)
---@param wz      number  World Z (combine rootNode)
function SoilFertilitySystem:recordHarvestTrailPoint(fieldId, wx, wz)
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return end

    local zone = SoilConstants.ZONE
    if not zone then return end

    local currentDay = (g_currentMission and g_currentMission.environment and
                        g_currentMission.environment.currentDay) or 0

    -- New game day = new harvest session; wipe the previous trail
    if field.harvestSessionDay ~= currentDay then
        field.harvestSessionDay = currentDay
        field.harvestTrailPts   = nil
        field.harvestCells      = nil
    end

    -- Deduplicate by cell
    local cx = math.floor(wx / zone.CELL_SIZE)
    local cz = math.floor(wz / zone.CELL_SIZE)
    local cellKey = tostring(cx * 10000 + cz)

    if not field.harvestCells then field.harvestCells = {} end
    if field.harvestCells[cellKey] then return end
    field.harvestCells[cellKey] = true

    -- Record world-centre of cell with terrain height for 3-D projection
    if not field.harvestTrailPts then field.harvestTrailPts = {} end
    local twx = (cx + 0.5) * zone.CELL_SIZE
    local twz = (cz + 0.5) * zone.CELL_SIZE
    local twy = 0.3
    if g_terrainNode then
        local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, twx, 0, twz)
        if ok and h then twy = h + 0.3 end
    end
    table.insert(field.harvestTrailPts, {wx = twx, wy = twy, wz = twz})

    -- Auto-clear once the full field area has been covered (visual reward)
    local cellArea = zone.CELL_AREA_HA
    local areaHa   = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0
    local count    = 0
    for _ in pairs(field.harvestCells) do count = count + 1 end
    if count * cellArea >= areaHa then
        field.harvestTrailPts   = nil
        field.harvestCells      = nil
        field.harvestSessionDay = nil
    end
end

---@param fieldId number
---@param wx      number  World X (implement rootNode)
---@param wz      number  World Z (implement rootNode)
---@param isPlow  boolean true = plow (dark brown), false = cultivate (tan)
function SoilFertilitySystem:recordTillageTrailPoint(fieldId, wx, wz, isPlow)
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return end

    local zone = SoilConstants.ZONE
    if not zone then return end

    local currentDay = (g_currentMission and g_currentMission.environment and
                        g_currentMission.environment.currentDay) or 0

    if field.tillageSessionDay ~= currentDay then
        field.tillageSessionDay = currentDay
        field.tillageTrailPts   = nil
        field.tillageCells      = nil
    end

    local cx = math.floor(wx / zone.CELL_SIZE)
    local cz = math.floor(wz / zone.CELL_SIZE)
    local cellKey = tostring(cx * 10000 + cz)

    if not field.tillageCells then field.tillageCells = {} end
    if field.tillageCells[cellKey] then return end
    field.tillageCells[cellKey] = true

    if not field.tillageTrailPts then field.tillageTrailPts = {} end
    local twx = (cx + 0.5) * zone.CELL_SIZE
    local twz = (cz + 0.5) * zone.CELL_SIZE
    local twy = 0.3
    if g_terrainNode then
        local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, twx, 0, twz)
        if ok and h then twy = h + 0.3 end
    end
    table.insert(field.tillageTrailPts, {wx = twx, wy = twy, wz = twz, isPlow = isPlow})

    local cellArea = zone.CELL_AREA_HA
    local areaHa   = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0
    local count    = 0
    for _ in pairs(field.tillageCells) do count = count + 1 end
    if count * cellArea >= areaHa then
        field.tillageTrailPts   = nil
        field.tillageCells      = nil
        field.tillageSessionDay = nil
    end
end
