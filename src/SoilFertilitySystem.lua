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
    -- Install early so the PlaceableSilo.onLoad append is in place before savegame silos
    -- load - augments Storage.fillTypes before onFinalizePlacement builds the station
    -- aggregate, so bulk fertilizer/lime bins accept SF fill types automatically (#605).
    self.hookManager:installSiloFillTypeHook()
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
--- Pure yield-modifier calculation - the SINGLE source of truth for both the
--- applied harvest reduction (computeYieldModifier) and the monitor's forecast
--- (getFieldInfo.yieldEfficiency). Reads explicit N/P/K so callers control the
--- nutrient source; BOTH call sites pass FIELD-AVERAGE values, so the number the
--- monitor shows always equals the grain the combine actually receives.
--- Read-only: never mutates field state. The amendment-burn one-shot is consumed
--- by the real harvest path (computeYieldModifier), not here, so the display can
--- evaluate it as often as it likes without clearing it.
---@param field table       Field data record
---@param cropName string   Fruit name (lowercased internally)
---@param nVal number       Nitrogen value to evaluate
---@param pVal number       Phosphorus value
---@param kVal number       Potassium value
---@param logFieldId number|nil  Field id for per-factor debug logging; nil = silent (display path)
---@return number modifier  Combined yield multiplier in [1-MAX_PENALTY, 1.0]
function SoilFertilitySystem:_yieldModifierFromNutrients(field, cropName, nVal, pVal, kVal, logFieldId)
    local modifier = 1.0
    cropName = cropName and string.lower(cropName) or ""
    local ys      = SoilConstants.YIELD_SENSITIVITY
    local isGrass = ys and ys.NON_CROP_NAMES and ys.NON_CROP_NAMES[cropName]

    local function plog(...) if logFieldId then self:log(...) end end

    -- Nutrient-based modifier (only when nutrientCycles enabled, skipped for grass/non-crop)
    if self.settings.nutrientCycles and ys and not isGrass then
        local tier     = ys.CROP_TIERS[cropName] or ys.DEFAULT_TIER
        local tierData = ys.TIERS[tier]
        local thresh   = ys.OPTIMAL_THRESHOLD

        local nDef = math.max(0, thresh - nVal) / thresh
        local pDef = math.max(0, thresh - pVal) / thresh
        local kDef = math.max(0, thresh - kVal) / thresh

        local avgDef = (nDef + pDef + kDef) / 3

        local nutrientPenalty = math.min(ys.MAX_PENALTY, avgDef * tierData.scale)
        if nutrientPenalty > 0 then
            modifier = modifier * (1.0 - nutrientPenalty)
            plog("Nutrient penalty field %d (%s/%s): N=%.0f P=%.0f K=%.0f → -%.0f%%",
                logFieldId, cropName, tier, nVal, pVal, kVal, nutrientPenalty * 100)
        end

        -- Organic matter influence (#695): rich humus gives a small yield bonus, depleted
        -- soil a penalty. Shared with the mower forage path via _omYieldModifier so hay and
        -- grain respond to soil health identically. May push the modifier slightly above 1.0
        -- (a genuine bonus on well-built soil); the hopper hook handles that fine.
        local omMod = self:_omYieldModifier(field)
        if omMod ~= 1.0 then
            modifier = modifier * omMod
            plog("OM modifier field %d: OM=%.1f → %+.0f%%", logFieldId,
                 field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter, (omMod - 1.0) * 100)
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
                plog("Weed penalty field %d: pressure=%.0f → -%.0f%%", logFieldId, pressure, penalty * 100)
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
            plog("Pest penalty field %d: pressure=%.0f → -%.0f%%", logFieldId, pressure, penalty * 100)
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
        -- Scale the tier penalty by the named disease's severity (a -60% taro blight
        -- bites far harder than a -15% mildew). 1.0 when no named disease is active.
        if penalty > 0 and field.activeDisease and SoilDiseaseSystem then
            penalty = math.min(0.85, penalty * (field.activeDiseaseSeverity or 1.0))
        end
        if penalty > 0 then
            modifier = modifier * (1.0 - penalty)
            plog("Disease penalty field %d: pressure=%.0f → -%.0f%% (%s)", logFieldId, pressure, penalty * 100,
                tostring(field.activeDisease or "generic"))
        end
    end

    -- Soil compaction yield penalty (#713): compacted soil restricts root growth, so the
    -- crop yields less even when N/P/K are fully topped up. This is its own setting
    -- (independent of nutrientCycles) and is skipped for grass/non-crop, matching the
    -- pressures. It is separate from the extra harvest depletion applied in
    -- updateFieldNutrients - that hits future fertility, this hits the current crop.
    if self.settings.compactionEnabled and SoilConstants.COMPACTION and not isGrass then
        local cp = SoilConstants.COMPACTION
        local ymax = cp.YIELD_PENALTY_MAX or 0
        local compaction = math.min(field.compaction or 0, cp.MAX_COMPACTION or 100)
        if compaction > 0 and ymax > 0 then
            local penalty = (compaction / 100) * ymax
            modifier = modifier * (1.0 - penalty)
            plog("Compaction penalty field %d: compaction=%.0f%% → -%.0f%%", logFieldId, compaction, penalty * 100)
        end
    end

    -- Amendment burn penalty: lime or OM applied to growing crop (issue #437).
    -- Evaluated read-only here; computeYieldModifier consumes the one-shot after applying it.
    if field.amendBurnPenalty and field.amendBurnPenalty > 0 then
        modifier = modifier * (1.0 - field.amendBurnPenalty)
        plog("Amendment burn penalty field %d: -%.0f%%", logFieldId, field.amendBurnPenalty * 100)
    end

    return modifier
end

--- Organic-matter yield factor (#695). Shared by the row-crop yield modifier and the
--- mower forage modifier (#696) so hay and grain respond to soil health identically.
--- Returns a multiplier that may sit slightly above 1.0 on well-built soil.
---@param field table
---@return number
function SoilFertilitySystem:_omYieldModifier(field)
    local omc = SoilConstants.YIELD_SENSITIVITY and SoilConstants.YIELD_SENSITIVITY.OM_YIELD
    if not omc then return 1.0 end
    local om = (field and field.organicMatter) or SoilConstants.FIELD_DEFAULTS.organicMatter
    if om >= omc.BONUS_THRESHOLD then
        return 1.0 + omc.BONUS_MAX
    elseif om >= omc.HEALTHY_LOW then
        return 1.0                                            -- healthy baseline band
    elseif om >= omc.PENALTY_MID then
        local f = (omc.HEALTHY_LOW - om) / (omc.HEALTHY_LOW - omc.PENALTY_MID)
        return 1.0 - f * omc.PENALTY_MID_MAX                  -- 0 → -10%
    else
        local f = math.min(1.0, (omc.PENALTY_MID - om) / omc.PENALTY_MID)
        return 1.0 - (omc.PENALTY_MID_MAX + f * (omc.PENALTY_MAX - omc.PENALTY_MID_MAX))  -- -10% → -25%
    end
end

--- Forage yield modifier for windrow-drop mowers (#696). Forage crops are gated out of
--- _yieldModifierFromNutrients via NON_CROP_NAMES (correct - no yield % score for hay), so
--- the mower path needs its own nutrient read. Uses the "tolerant" tier (matching
--- alfalfa/luzerne/clover) plus the shared OM factor. Weed/pest/disease are intentionally
--- excluded - forage quality is not tracked per field.
---@param fieldId number
---@return number modifier  Multiplier applied to windrow liters (≤ ~1.05)
function SoilFertilitySystem:computeMowerYieldModifier(fieldId)
    if not self.settings.enabled or not self.settings.nutrientCycles then return 1.0 end
    local field = self.fieldData[fieldId]
    if not field then return 1.0 end
    local ys = SoilConstants.YIELD_SENSITIVITY
    if not ys then return 1.0 end

    local modifier = 1.0
    local tierData = ys.TIERS and ys.TIERS["tolerant"]
    if tierData then
        local thresh = ys.OPTIMAL_THRESHOLD
        local nDef = math.max(0, thresh - (field.nitrogen   or 0)) / thresh
        local pDef = math.max(0, thresh - (field.phosphorus or 0)) / thresh
        local kDef = math.max(0, thresh - (field.potassium  or 0)) / thresh
        local penalty = math.min(ys.MAX_PENALTY, ((nDef + pDef + kDef) / 3) * tierData.scale)
        modifier = modifier * (1.0 - penalty)
    end

    -- Soil health affects hay tonnage the same way it affects grain.
    modifier = modifier * self:_omYieldModifier(field)
    return modifier
end

--- Computes the combined yield modifier actually applied at harvest. All yield-reducing
--- factors are multiplied together and the result is applied to liters BEFORE the combine
--- hopper receives grain in HookManager, so the engine sees fewer liters. Snapshotted
--- (frozen) on the first cut so the value does not slide as the combine crosses the field.
---@param fieldId number
---@param fruitTypeIndex number
---@return number modifier  Combined yield multiplier in [1-MAX_PENALTY, 1.0]
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

    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local cropName  = fruitDesc and (fruitDesc.name or "") or ""

    -- Single source of truth: the applied reduction is driven by FIELD-AVERAGE
    -- nutrients. getFieldInfo()'s monitor forecast calls this same helper with the
    -- same field-average values, so the displayed "Yield eff." always equals the
    -- grain the hopper actually receives.
    local modifier = self:_yieldModifierFromNutrients(
        field, cropName, field.nitrogen, field.phosphorus, field.potassium, fieldId)

    -- Amendment burn is a one-shot: consume it now that it has been applied so the
    -- next harvest is not penalised again (the display path never clears it).
    if field.amendBurnPenalty and field.amendBurnPenalty > 0 then
        field.amendBurnPenalty   = nil
        field._amendBurnNotified = nil
        field._amendBurnTickTime = nil
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

    -- Clear weed/disease chemical protection on harvest too (#639). The crop cycle ends
    -- with the harvest, so carrying the previous spray's "protected" status into the bare
    -- field left the HUD showing weed/disease protection that the player could not clear.
    -- Mirrors the insecticide reset above (counters only - pressure is re-derived live).
    do
        local field = self.fieldData[fieldId]
        if field then
            field.herbicideDaysLeft = 0
            field.fungicideDaysLeft = 0
        end
    end

    -- Nutrient depletion uses original (biological) liters - the soil gave up these
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
        harvestField.sownCrop                = nil  -- crop harvested; lastCrop now carries it (#661)
        -- frozenYieldModifier is NOT cleared here (#598): onHarvest fires per-cut, so
        -- clearing here defeats the freeze and causes yield to drop with each combine pass.
        -- The freeze is cleared once per game day in _processOneDailyField instead.
    end

    SoilLogger.debug("Harvest: Field %d, Crop %d, %.0fL (biological), area=%.1f", fieldId, fruitTypeIndex, liters, area or 0)

    -- Broadcast to clients in multiplayer, throttled to once every 5 s per field.
    -- onHarvest is driven by Combine.addCutterArea, which fires many times per second
    -- per combine. An unthrottled broadcast here floods the network the instant the
    -- cutter engages the crop and stalls every client - the dedicated-server FPS
    -- collapse in issue #631. Mirror the same 5 s throttle already used by onMow and
    -- onFertilizerApplied so the per-tick fire-rate no longer reaches the wire.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        local field = self.fieldData[fieldId]
        if field and SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._harvestBroadcastTime then self._harvestBroadcastTime = {} end
            local last = self._harvestBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._harvestBroadcastTime[fieldId] = now
                g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
            end
        end
    end
end

--- Hook delegate: called by HookManager when fertilizer applied
--- Hook delegate: called by HookManager when a mower/swather cuts forage crops.
--- Handles nutrient depletion for crops that are CUT but not direct-threshed:
--- grass, alfalfa, clover, mowed triticale, etc.
--- Uses area-based depletion (not liter-based) since no yield liters are produced
--- at mow time - the cut material is left as a windrow for later pickup.
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
    -- biomass (e.g. wheat windrow at 3.8 L/sqm) - a completely different density.
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

    SoilLogger.debug("Mow: Field %d, %s, %.5f ha - N:%.1f P:%.1f K:%.1f",
        fieldId, fruitDesc.name, areaHa, field.nitrogen, field.phosphorus, field.potassium)

    -- Broadcast field update to clients in multiplayer (throttled - mower fires every tick)
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
-- PHASE 1: Soil data is PRESERVED across ownership changes - real soil does not
-- reset when land is sold.  We only update active-set membership here.
function SoilFertilitySystem:onFieldOwnershipChanged(fieldId, farmlandId, farmId)
    if not fieldId or fieldId <= 0 then return end

    if farmId == nil or farmId == 0 then
        -- Field sold / abandoned - pull it out of the active simulation set.
        -- fieldData intentionally kept: new owner inherits the soil conditions.
        self:_removeFromActiveSet(fieldId)
        -- Clear GRLE so unmasked DMV no longer colours this unowned field.
        if self.layerSystem and self.layerSystem.available then
            self.layerSystem:clearFieldFromLayers(fieldId, nil)
        end
        SoilLogger.debug("[PERF-P1] Field %d released by farm - removed from active set (data preserved)", fieldId)
        return
    end

    -- Field acquired - ensure data entry exists, then add to active set.
    local field = self:getOrCreateField(fieldId, true)
    if field then
        self:_addToActiveSet(fieldId)
        SoilLogger.debug("[PERF-P1] Field %d acquired by farm %d - added to active set", fieldId, farmId)
    end
end

--- Clears any pending amendment-burn one-shot (lime or OM applied over the previous
--- growing crop, #437). That penalty belongs to the crop that was growing when the
--- amendment landed; sowing a NEW crop (including direct drilling over the old one) or
--- tilling the field voids it. The one-shot is otherwise only consumed at harvest, so
--- replanting without harvesting left it stuck on the field and it wrongly docked the
--- next crop's yield by up to 80% - the persistent-burn-after-replant bug reported by
--- multiple players (direct seeding over a burned field never reset it).
---@param field table        Field data record
---@param fieldId number     Field id (logging only)
---@param reason string      What cleared it ("sowing"/"cultivation"/"plowing"), for logs
---@return boolean cleared   true if a pending burn was present and removed
function SoilFertilitySystem:clearAmendmentBurn(field, fieldId, reason)
    if not field or (field.amendBurnPenalty or 0) <= 0 then return false end
    field.amendBurnPenalty   = nil
    field._amendBurnNotified = nil
    field._amendBurnTickTime = nil
    SoilLogger.debug("Amendment burn cleared on %s for field %s", tostring(reason), tostring(fieldId))
    return true
end

--- Hook delegate: called by HookManager when sowing/planting occurs on a field.
--- Called when a field is sown. Reserved for future sowing-time logic.
--- NOTE: We previously cleared lastCrop here to force live HUD detection (#123),
--- but that caused duplicate crop entries in history when the same crop is replanted
--- (especially visible with FS25_CropRotation installed - issue #204).
--- Live FieldState detection in getFieldInfo() works regardless of lastCrop, so
--- the clearing was unnecessary and harmful to rotation history accuracy.
---@param fieldId number The field being sown
---@param area number Area processed in hectares
---@param seedsFruitType number|nil  Fruit type index of the seed going in the ground
function SoilFertilitySystem:onSowing(fieldId, area, seedsFruitType)
    if not fieldId or fieldId <= 0 then return end
    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Record the crop being seeded so the HUD/map show it right away (#661). Live FieldState
    -- detection only returns the new crop once the sampled point (field centroid) has actually
    -- been seeded, so on a half-finished pass the readout fell back to lastCrop and showed the
    -- PREVIOUS crop (e.g. "beans" while drilling wheat). sownCrop is a display-only bridge:
    -- it does NOT touch the lastCrop rotation-history chain (kept intact for #204) and is
    -- cleared on harvest. getFieldInfo prefers it over lastCrop when no live crop is detected.
    if seedsFruitType and g_fruitTypeManager then
        local seedDesc = g_fruitTypeManager:getFruitTypeByIndex(seedsFruitType)
        if seedDesc and seedDesc.name and seedDesc.name ~= "" then
            field.sownCrop = seedDesc.name
        end
    end

    local areaHa = area or 0.001
    local fieldAreaHa = field.fieldArea and field.fieldArea > 0 and field.fieldArea or 1.0
    local factor = areaHa / fieldAreaHa

    local changed = false

    -- Planting a new crop voids any pending amendment burn from the previous crop.
    if self:clearAmendmentBurn(field, fieldId, "sowing") then changed = true end

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

--- #674: incorporate standing/dead crop biomass (green manure) into the soil.
--- Applied on top of residue incorporation when a tillage or mulch pass works through
--- a detected crop. Scales the profile's OM/N/P/K by the crop biomass (0..1) and the
--- field-fraction processed this tick, and mirrors the bump into the local zoneData
--- cell so the HUD/overlay reflect it. Returns true if anything changed.
---@param fieldId number
---@param field table The field data table
---@param profile table A SoilConstants.CROP_INCORPORATION.* profile (OM/N/P/K)
---@param biomass number Crop biomass factor 0..1 (from growth state)
---@param factor number Field-fraction processed this tick (clampedArea / fieldAreaHa)
---@param areaHa number Area processed this tick, in hectares (for the per-cell write)
---@return boolean changed
function SoilFertilitySystem:_applyCropIncorporation(fieldId, field, profile, biomass, factor, areaHa)
    if not profile or not biomass or biomass <= 0 or not factor or factor <= 0 then return false end
    local limits = SoilConstants.NUTRIENT_LIMITS
    local scale  = factor * biomass

    local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
    field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX, omBefore + profile.OM * scale)
    field.nitrogen   = math.min(limits.MAX, (field.nitrogen   or 0) + profile.N * scale)
    field.phosphorus = math.min(limits.MAX, (field.phosphorus or 0) + profile.P * scale)
    field.potassium  = math.min(limits.MAX, (field.potassium  or 0) + profile.K * scale)

    -- Local zoneData cell update for HUD/PDA visibility (same pattern as residue).
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
        local cellScale = ((areaHa or 0) / zone.CELL_AREA_HA) * biomass
        cell.OM = math.min(limits.ORGANIC_MATTER_MAX, (cell.OM or field.organicMatter) + profile.OM * cellScale)
        cell.N  = math.min(limits.MAX, (cell.N or 0) + profile.N * cellScale)
        cell.P  = math.min(limits.MAX, (cell.P or 0) + profile.P * cellScale)
        cell.K  = math.min(limits.MAX, (cell.K or 0) + profile.K * cellScale)
    end

    SoilLogger.debug("Crop incorporation field %d: +OM%.3f +N%.3f (biomass=%.2f factor=%.4f)",
        fieldId or -1, profile.OM * scale, profile.N * scale, biomass, factor)
    return true
end

--- Hook delegate: called by HookManager when plowing occurs
--- Increases organic matter and normalizes pH
---@param fieldId number The field being plowed
---@param area number Area processed in hectares (e.g. from lastStatsArea)
---@param isAlsoSprayer boolean|nil True if the implement also sprays (combo tools) - skip coverage reset
---@param cropBiomass number|nil Crop biomass factor 0..1 if a standing/dead crop was incorporated (#674)
function SoilFertilitySystem:onPlowing(fieldId, area, isAlsoSprayer, cropBiomass)
    if not fieldId or fieldId <= 0 then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Tillage destroys the spray application context - reset pass % so the next
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

    -- Tilling mixes the soil and ends the crop - void any pending amendment burn.
    if self:clearAmendmentBurn(field, fieldId, "plowing") then changed = true end

    -- Plowing effects 1 & 2: OM oxidation loss and pH normalization (only if plowingBonus enabled)
    if self.settings.plowingBonus then
        -- Deep inversion exposes buried humus to air, oxidising it - plowing COSTS organic
        -- matter rather than adding it (#695, reversed from the old +0.5/pass bonus). Residue
        -- incorporation below (gated separately) can offset this when straw/green matter is
        -- actually worked in, so a residue-rich plow can still net positive.
        local omDyn    = SoilConstants.OM_DYNAMICS
        local omLoss   = (omDyn and omDyn.PLOW_OXIDATION_LOSS or 0) * factor
        local omFloor  = (omDyn and omDyn.DECAY_FLOOR) or SoilConstants.NUTRIENT_LIMITS.MIN
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omAfter  = math.max(omFloor, omBefore - omLoss)
        if omAfter < omBefore then
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

    -- Plowing benefit 6: Residue incorporation - straw stubble worked in releases OM and NPK
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

    -- Plowing benefit 7 (#674): green-manure incorporation - plowing in a STANDING or
    -- dead crop (cover crop, failed/burned crop, tall stubble) returns its biomass to the
    -- soil as a large OM + N boost, far above the bare-stubble residue release above.
    if self.settings.residueIncorporation and cropBiomass and cropBiomass > 0
       and SoilConstants.CROP_INCORPORATION then
        if self:_applyCropIncorporation(fieldId, field, SoilConstants.CROP_INCORPORATION.PLOW,
                                        cropBiomass, factor, areaHa) then
            changed = true
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
---@param isAlsoSprayer boolean|nil True if the implement also sprays (combo tools) - skip coverage reset
---@param cropBiomass number|nil Crop biomass factor 0..1 if a standing/dead crop was incorporated (#674)
function SoilFertilitySystem:onCultivation(fieldId, area, isAlsoSprayer, cropBiomass)
    if not fieldId or fieldId <= 0 then return end
    if not SoilConstants.CULTIVATION then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Tillage destroys the spray application context - reset pass % (see onPlowing).
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

    -- Tilling mixes the soil and ends the crop - void any pending amendment burn.
    if self:clearAmendmentBurn(field, fieldId, "cultivation") then changed = true end

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

    -- #674: green-manure incorporation - cultivating in a standing/dead cover crop mixes
    -- its biomass into the topsoil (shallower than plowing, so a smaller boost).
    if self.settings.residueIncorporation and cropBiomass and cropBiomass > 0
       and SoilConstants.CROP_INCORPORATION then
        if self:_applyCropIncorporation(fieldId, field, SoilConstants.CROP_INCORPORATION.CULTIVATOR,
                                        cropBiomass, factor, areaHa) then
            changed = true
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

--- Hook delegate (#674): called by HookManager when a mulcher actively chops crop/stubble.
--- Mulching returns surface biomass to the soil as organic matter (no soil inversion, so
--- a smaller boost than tillage). Area is estimated from speed × width by the hook and is
--- bounded to one full-field-equivalent per day by the same per-day cap as plowing.
---@param fieldId number
---@param area number Estimated area processed this tick, in hectares
---@param cropBiomass number Crop/stubble biomass factor 0..1
function SoilFertilitySystem:onMulching(fieldId, area, cropBiomass)
    if not fieldId or fieldId <= 0 then return end
    if not self.settings.residueIncorporation then return end
    if not cropBiomass or cropBiomass <= 0 then return end
    if not SoilConstants.CROP_INCORPORATION then return end

    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    local areaHa = area or 0.001
    local fieldAreaHa = field.fieldArea and field.fieldArea > 0 and field.fieldArea or 1.0

    -- Per-day area cap (same rationale as onPlowing/onCultivation): total mulch effect
    -- cannot exceed one full-field-equivalent per day regardless of pass count.
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if not self._mulchAreaToday then self._mulchAreaToday = {} end
    local entry = self._mulchAreaToday[fieldId]
    if not entry or entry.day ~= today then
        entry = { day = today, used = 0 }
        self._mulchAreaToday[fieldId] = entry
    end
    local clampedArea = math.min(areaHa, math.max(0, fieldAreaHa - entry.used))
    if clampedArea <= 0 then return end
    entry.used = entry.used + clampedArea
    local factor = clampedArea / fieldAreaHa

    local changed = self:_applyCropIncorporation(fieldId, field, SoilConstants.CROP_INCORPORATION.MULCHER,
                                                 cropBiomass, factor, clampedArea)

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

    -- Minimal disease benefit - residue stays on surface between strips
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
    -- Duration is in in-game DAYS (the daily tick decrements it by 1 per game day), so
    -- it must equal the day count directly. Multiplying by daysPerPeriod made protection
    -- last DURATION_DAYS *months* - it never expired, so the HUD "protected" status stuck
    -- forever (#639). See HERBICIDE_DURATION_DAYS comment in Constants.lua.
    field.herbicideDaysLeft = wp.HERBICIDE_DURATION_DAYS

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
--- Uses FieldUpdateTask - same API as EasyDevControls, server-side only.
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

    -- fieldId is the farmland ID - getFieldById uses field's own internal ID (different).
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
                -- No live weeds to wither here (state 0, or already withered/dying). Painting the
                -- withered state across the whole field polygon would fabricate "burnt weed"
                -- textures on a clean field - and that fake coverage bakes into the weed density
                -- map, so it reappears on every save/reload even at 0% pressure (#698). Skip:
                -- leave the weed map untouched. There is nothing to brown.
                self:log("[WeedMap] SKIP: no live weeds to wither (state %s) on field %d - not painting",
                    tostring(currentState), fieldId)
                return
            end
        else
            -- Replacement table unavailable: we cannot tell clean ground from weedy, so do NOT
            -- blanket-paint the withered state onto a possibly-clean field (avoids the #698
            -- fake-coverage bug). Better to skip the cosmetic browning than fabricate weeds.
            self:log("[WeedMap] SKIP: herbicide replacement table unavailable - not painting")
            return
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

--- Restore a grass sward over a whole field after a grass-preserving deep tool worked it (#680).
--- Deep grassland sward-lifters (Latapia 5P1H, etc.) are built as Cultivator+isSubsoiler, so the
--- engine destroys the grass on the pass. This re-applies the snapshotted grass fruit + growth
--- state so the player decompacts pasture WITHOUT a reseed. Debounced per field because a
--- whole-field FieldUpdateTask is not free. Server-only (mirrors applyWeedMapState).
---@param farmlandId number
---@param fruitIndex number   Grass/forage fruit type to restore (sampled pre-pass)
---@param growthState number  Growth state to restore it to (sampled pre-pass)
function SoilFertilitySystem:restoreGrassSward(farmlandId, fruitIndex, growthState)
    if not g_server then return end
    if not fruitIndex or fruitIndex <= 0 then return end
    if FieldUpdateTask == nil then return end

    -- Debounce: a whole-field density write is expensive, so collapse the per-tick calls
    -- while the tool works into one restore every GRASS_RESTORE_DEBOUNCE_MS per field.
    local debounceMs = (SoilConstants.COMPACTION and SoilConstants.COMPACTION.GRASS_RESTORE_DEBOUNCE_MS) or 1000
    local nowMs = (g_currentMission and g_currentMission.time) or 0
    self._grassRestoreLast = self._grassRestoreLast or {}
    if (nowMs - (self._grassRestoreLast[farmlandId] or -math.huge)) < debounceMs then return end
    self._grassRestoreLast[farmlandId] = nowMs

    -- Find the field object by farmland id (same search applyWeedMapState uses).
    local fsField = nil
    if g_fieldManager and g_fieldManager.fields then
        fsField = g_fieldManager.fields[farmlandId]
        if not fsField or not fsField.farmland then
            for _, f in pairs(g_fieldManager.fields) do
                if f and f.farmland and f.farmland.id == farmlandId then fsField = f; break end
            end
        end
    end
    if not fsField then return end

    local ok, err = pcall(function()
        local task = FieldUpdateTask.new()
        task:setField(fsField)
        task:setArea(fsField:getDensityMapPolygon())
        task:setFruit(fruitIndex, growthState)
        task:enqueue(true)
    end)
    if ok then
        self:log("[Sward] Restored grass (fruit=%d gs=%d) on field %d after deep grassland pass",
            fruitIndex, growthState, farmlandId)
    else
        self:warning("[Sward] restore failed on field %d: %s", farmlandId, tostring(err))
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
    -- Duration is in in-game DAYS (decremented 1/game-day); see #639 / onHerbicideApplied.
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.insecticideDaysLeft = pp.INSECTICIDE_DURATION_DAYS
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
    -- Duration is in in-game DAYS (decremented 1/game-day); see #639 / onHerbicideApplied.
    -- cm.fungicideMult still scales it (shorter in wet climates).
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.fungicideDaysLeft = math.floor(dp.FUNGICIDE_DURATION_DAYS * cm.fungicideMult)
    end

    self:log("[Fungicide] Field %d: disease pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.diseasePressure, field.fungicideDaysLeft)

    -- A generic fungicide pass clears the named infection once pressure drops low.
    if (field.diseasePressure or 0) < (SoilConstants.DISEASE_PRESSURE.LOW or 20) * 0.5 then
        field.activeDisease = nil
        field.activeDiseaseSeverity = 1.0
    end

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end
end

-- ============================================================================
-- NAMED DISEASE & CHEMICAL LAYER (DiseaseSystem.lua-driven)
-- ============================================================================

--- Current in-game day (0 when the environment is not ready).
---@return number
function SoilFertilitySystem:_currentDay()
    return (g_currentMission and g_currentMission.environment
            and g_currentMission.environment.currentDay) or 0
end

--- Current season index (1=Spring 2=Summer 3=Fall 4=Winter), or nil if unavailable.
---@return number|nil
function SoilFertilitySystem:_currentSeason()
    return (g_currentMission and g_currentMission.environment
            and g_currentMission.environment.currentSeason) or nil
end

--- Locate the g_fieldManager field object for a farmland id (shared search pattern).
---@param fieldId number farmland id
---@return table|nil fsField
function SoilFertilitySystem:_findFieldObject(fieldId)
    if not (g_fieldManager and g_fieldManager.fields) then return nil end
    local fsField = g_fieldManager.fields[fieldId]
    if fsField and fsField.farmland and fsField.farmland.id == fieldId then return fsField end
    for _, f in pairs(g_fieldManager.fields) do
        if f and f.farmland and f.farmland.id == fieldId then return f end
    end
    return fsField
end

--- Best-effort live growth-stage fraction (0..1) for a field, or nil when unknown.
--- Uses an FS25 FieldState probe - wrapped so any API hiccup degrades to "unknown".
---@param fieldId number
---@return number|nil
function SoilFertilitySystem:_getFieldGrowthFraction(fieldId)
    local fsField = self:_findFieldObject(fieldId)
    if not (fsField and fsField.posX and fsField.posZ and FieldState) then return nil end
    local frac = nil
    pcall(function()
        if not self._fieldStateCache then self._fieldStateCache = {} end
        local fs = self._fieldStateCache[fieldId]
        if not fs then
            local ok, newFs = pcall(FieldState.new)
            fs = (ok and newFs) or false
            self._fieldStateCache[fieldId] = fs
        end
        if fs then
            fs:update(fsField.posX, fsField.posZ)
            if fs.isValid and fs.fruitTypeIndex and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
                local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fs.fruitTypeIndex)
                local numStates = fruitDesc and fruitDesc.numGrowthStates
                if numStates and fs.growthState then
                    frac = SoilDiseaseSystem.growthFraction(fs.growthState, numStates)
                end
            end
        end
    end)
    return frac
end

--- Resolve whether the field is currently "wet" (recent/active rain) and "cool".
---@param season number|nil
---@return boolean isWet, boolean isCool
function SoilFertilitySystem:_diseaseClimateNow(season)
    local isWet = false
    if g_currentMission and g_currentMission.environment and g_currentMission.environment.weather then
        local rs = g_currentMission.environment.weather:getRainFallScale()
        isWet = rs ~= nil and rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD
    end
    -- Cool proxy from season (summer = warm; spring/fall/winter = cool). Avoids depending
    -- on an unverified temperature API while still steering disease selection sensibly.
    local isCool = season ~= 2
    return isWet, isCool
end

--- Select / refresh / clear the named active disease over the scalar pressure.
---@param fieldId number
---@param field table
---@param season number|nil
---@param isRaining boolean
---@param currentDay number
function SoilFertilitySystem:_updateActiveDisease(fieldId, field, season, isRaining, currentDay)
    if not SoilDiseaseSystem then return end
    local onset = (SoilConstants.DISEASE_PRESSURE.LOW or 20) * 0.5
    local pressure = field.diseasePressure or 0

    if pressure < onset * 0.5 then
        -- Infection has effectively cleared - drop the name.
        field.activeDisease = nil
        field.activeDiseaseSeverity = 1.0
        return
    end

    if not field.activeDisease and pressure >= onset then
        local _, isCool = self:_diseaseClimateNow(season)
        local seed = fieldId * 1000 + (currentDay or 0)
        local picked = SoilDiseaseSystem.selectDisease(field.lastCrop, season, isRaining, isCool, seed)
        if picked then
            field.activeDisease = picked
            field.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(picked)
        end
    elseif field.activeDisease and (field.activeDiseaseSeverity == nil) then
        field.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(field.activeDisease)
    end
end

--- Scouting report for a field: named disease, severity tier, recommended chemicals.
--- Pure read - safe for UI / console / HUD callers.
---@param fieldId number
---@return table|nil report
function SoilFertilitySystem:getScoutReport(fieldId)
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return nil end
    if not self.settings.diseasePressure then
        return { fieldId = fieldId, enabled = false }
    end

    local dp = SoilConstants.DISEASE_PRESSURE
    local pressure = field.diseasePressure or 0
    local tier
    if     pressure < dp.LOW    then tier = "none"
    elseif pressure < dp.MEDIUM then tier = "mild"
    elseif pressure < dp.HIGH   then tier = "moderate"
    else                             tier = "severe"
    end

    local report = {
        fieldId = fieldId,
        enabled = true,
        pressure = pressure,
        tier = tier,
        fungicideActive = (field.fungicideDaysLeft or 0) > 0,
        fungicideDaysLeft = field.fungicideDaysLeft or 0,
        diseaseId = field.activeDisease,
        crop = field.lastCrop,
    }

    if field.activeDisease then
        local def = SoilDiseaseSystem.diseaseDef(field.activeDisease)
        if def then
            report.diseaseCategory = def.cat
            report.diseaseSci = def.sci
            report.recommend = SoilDiseaseSystem.recommend(field.activeDisease)
        end
    end
    return report
end

--- Apply a named fungicide to a field via the menu/console path (no physical fill type).
--- Computes control from the effectiveness matrix × timing × disease stage × weather ×
--- difficulty, reduces pressure, grants protection, and charges the field area cost.
---@param fieldId number
---@param chemId string  catalog id (e.g. "AZOXYSTROBIN")
---@param opts table|nil { charge=true, farmId=number }
---@return boolean ok, string messageKey, table detail
function SoilFertilitySystem:applyNamedFungicide(fieldId, chemId, opts)
    opts = opts or {}
    if not self.settings.diseasePressure then
        return false, "sf_scout_disabled", {}
    end
    local chem = SoilDiseaseSystem and SoilDiseaseSystem.chemical(chemId)
    if not chem then
        return false, "sf_treat_bad_chem", {}
    end

    local field = self:getOrCreateField(fieldId, false)
    if not field then
        return false, "sf_treat_no_field", {}
    end

    -- Clients ask the server to perform the authoritative application (MP).
    if g_currentMission and g_currentMission.missionDynamicInfo
       and g_currentMission.missionDynamicInfo.isMultiplayer and not g_server then
        if SoilTreatFieldEvent then
            g_client:getServerConnection():sendEvent(SoilTreatFieldEvent.new(fieldId, chemId))
            return true, "sf_treat_sent", {}
        end
    end

    local diseaseId = field.activeDisease
    local pressure = field.diseasePressure or 0
    local isWet = select(1, self:_diseaseClimateNow(nil))
    local growthFrac = self:_getFieldGrowthFraction(fieldId)

    -- With no named infection yet, treat as a preventative against the most likely threat.
    local effDiseaseId = diseaseId
    if not effDiseaseId then
        local season = self:_currentSeason()
        local _, isCool = self:_diseaseClimateNow(season)
        effDiseaseId = SoilDiseaseSystem.selectDisease(field.lastCrop, season, isWet, isCool,
            fieldId * 1000 + (self:_currentDay() or 0))
    end

    local control, breakdown = SoilDiseaseSystem.computeControl(chemId, effDiseaseId, {
        pressure = pressure,
        growthFrac = growthFrac,
        isRaining = isWet,
        diseaseDifficulty = self.settings.diseaseDifficulty or 2,
    })

    local t = SoilConstants.DISEASE_TREATMENT
    local before = pressure
    local reduction = control * t.MAX_PRESSURE_REDUCTION
    field.diseasePressure = math.max(0, before - reduction)

    -- Protection scales with climate (shorter in wet climates) and the control achieved.
    local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[self.settings.diseaseMoisture or 2]
        or SoilConstants.DISEASE_CLIMATE_MOISTURE[2]
    local protDays = math.floor((chem.prot or 10) * (cm.fungicideMult or 1.0) * math.max(0.25, control) + 0.5)
    field.fungicideDaysLeft = math.max(field.fungicideDaysLeft or 0, protDays)
    field.lastFungicide = chemId
    self.fungicideAppliedDay[fieldId] = self:_currentDay() or 0

    -- Clear the named infection once knocked down.
    if field.diseasePressure < (SoilConstants.DISEASE_PRESSURE.LOW or 20) * 0.5 then
        field.activeDisease = nil
        field.activeDiseaseSeverity = 1.0
    end

    -- Charge cost (server authoritative). area × $/ha, gated by fertilizerCosts.
    local cost = 0
    if opts.charge ~= false and self.settings.fertilizerCosts and g_server then
        local area = field.fieldArea or 1.0
        cost = (chem.costPerHa or 0) * area
        if cost > 0 then
            local farmId = opts.farmId
            if not farmId then
                if g_localPlayer and g_localPlayer.farmId then farmId = g_localPlayer.farmId
                elseif g_currentMission and g_currentMission.player and g_currentMission.player.farmId then
                    farmId = g_currentMission.player.farmId
                else farmId = 1 end
            end
            if g_currentMission and g_currentMission.addMoney and farmId and farmId > 0 then
                pcall(function()
                    g_currentMission:addMoney(-cost, farmId, MoneyType.PURCHASE_FERTILIZER, true, true)
                end)
            end
        end
    end

    self:log("[NamedFungicide] Field %d: %s vs %s control=%.0f%% pressure %.0f->%.0f prot=%dd cost=%.0f",
        fieldId, chemId, tostring(effDiseaseId or "none"), control * 100, before, field.diseasePressure, protDays, cost)

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end

    return true, "sf_treat_done", {
        control = control,
        reduction = reduction,
        protDays = protDays,
        cost = cost,
        disease = effDiseaseId,
        breakdown = breakdown,
    }
end

--- DEBUG/TEST: force a field's disease pressure (and optionally a specific named
--- disease) so the scout + treat loop can be exercised without waiting for the
--- weather-driven build-up. Server/SP authoritative; broadcasts the result in MP.
---@param fieldId number
---@param pressure number 0-100
---@param diseaseId string|nil  explicit DISEASE_DEFS id, else auto-selected by crop+weather
---@return boolean ok, table info
function SoilFertilitySystem:debugSetDisease(fieldId, pressure, diseaseId)
    local field = self:getOrCreateField(fieldId, false)
    if not field then return false, {} end

    field.diseasePressure = math.max(0, math.min(100, pressure or 0))
    field.fungicideDaysLeft = 0  -- lift any existing protection so the infection can show

    local onset = (SoilConstants.DISEASE_PRESSURE.LOW or 20) * 0.5
    if field.diseasePressure < onset then
        field.activeDisease = nil
        field.activeDiseaseSeverity = 1.0
    elseif diseaseId and SoilConstants.DISEASE_DEFS[diseaseId] then
        field.activeDisease = diseaseId
        field.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(diseaseId)
    else
        local season = self:_currentSeason()
        local isWet, isCool = self:_diseaseClimateNow(season)
        local picked = SoilDiseaseSystem.selectDisease(field.lastCrop, season, isWet, isCool,
            fieldId * 1000 + (self:_currentDay() or 0))
        field.activeDisease = picked
        field.activeDiseaseSeverity = picked and SoilDiseaseSystem.yieldSeverity(picked) or 1.0
    end

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
        end
    end

    self:log("[DebugDisease] Field %d: pressure=%.0f disease=%s",
        fieldId, field.diseasePressure, tostring(field.activeDisease or "none"))
    return true, { pressure = field.diseasePressure, disease = field.activeDisease, crop = field.lastCrop }
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
            -- No owned fields - batch is trivially complete
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
        self:info("Client: skipping local field scan - waiting for server sync")
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
    -- field.fieldId / field.id / field.index do NOT exist in FS25 - all return nil.
    -- The correct field identifier is field.farmland.id (confirmed in-game).
    -- g_currentMission.fieldManager does not exist; use the global g_fieldManager.fields table directly.
    if not g_fieldManager or not g_fieldManager.fields then
        self:warning("g_fieldManager.fields not available - scan deferred")
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
                -- Farmlands include roads, hedges, and uncultivable land - typically ~2× the
                -- actual sprayed area - which causes Pass% to cap at ~50% after a full field pass.
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

                -- If this is a newly created field and density layers are available, read
                -- existing layer values (pre-seeded GRLE) instead of using defaults. On a
                -- mid-save install the layers are empty (pH 0); readFieldFromLayers now keeps
                -- the rolled defaults in that case (#685) and returns false, so we paint those
                -- defaults into the layers here instead of leaving the field at 0/0/0/0.
                if isNew and self.layerSystem and self.layerSystem.available then
                    -- Pass the Field object (not field.farmland) - Field has polygonPoints for AABB
                    local seeded = self.layerSystem:readFieldFromLayers(actualFieldId, self.fieldData[actualFieldId], field)
                    if not seeded then
                        self.layerSystem:writeFieldToLayers(actualFieldId, self.fieldData[actualFieldId], field, false)
                    end
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
-- the subset of fields the player actually owns - skipping the potentially
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
-- Roll a fresh field's starting soil profile (N/P/K/pH/OM). Single source of truth
-- for both lazy field creation and the SoilRerollFields console command, so the
-- variation formula is never duplicated.
--
-- Two parts are summed:
--   • a smooth REGIONAL gradient sampled at the farmland centre, so neighbouring
--     fields cohere into believable good/poor regions across the map, and
--   • per-field NOISE that decorrelates individual fields within a region.
-- Amounts live in SoilConstants.FIELD_VARIATION.
--
-- NOTE (issue #632): the previous "deterministic hash" was an affine LCG
-- (a*n+b mod m) with no nonlinear step. Evaluated on the arithmetic input
-- fieldId*67890+slot it returned an ARITHMETIC sequence - every field stepped in
-- lockstep along one ramp and all five nutrients shared the same step, so the whole
-- map looked uniform. fract(sin(x)) supplies the nonlinearity (math.sin is the only
-- Lua 5.1 primitive that breaks the progression) so values are genuinely independent
-- per (field, nutrient), while staying stable across save/load and avoiding
-- math.randomseed (which would pollute the shared global PRNG).
function SoilFertilitySystem:_computeInitialSoil(fieldId, farmlandObj)
    if farmlandObj == nil and g_farmlandManager then
        farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
    end

    local fieldCX, fieldCZ  -- farmland centre (world XZ); nil → pseudo-position fallback
    if farmlandObj and self.bundledMaps then
        fieldCX, fieldCZ = self.bundledMaps:getFarmlandCenter(farmlandObj)
    end

    local function hash01(a, b)
        -- Nonlinear 2-input hash → [0.0, 1.0). Classic fract(sin(dot)) mix.
        local s = math.sin(a * 12.9898 + b * 78.233) * 43758.5453
        return s - math.floor(s)
    end
    local function noiseField(slot)
        -- Per-field jitter in [-1.0, 1.0]; each nutrient uses its own slot.
        return hash01(fieldId, slot) * 2.0 - 1.0
    end
    local function regionalField(slot)
        -- Smooth low-frequency gradient sampled at the farmland centre, in [-1.0, 1.0].
        -- When the centre is unknown, fall back to a hash-derived pseudo-position so
        -- fields still spread out (just without true spatial correlation).
        local cx, cz = fieldCX, fieldCZ
        if cx == nil then
            cx = hash01(fieldId, 91) * 4096.0 - 2048.0
            cz = hash01(fieldId, 92) * 4096.0 - 2048.0
        end
        local f  = SoilConstants.FIELD_VARIATION.REGION_FREQ
        local ph = slot * 1.7  -- per-nutrient phase so N-rich regions ≠ P-rich regions
        local a  = math.sin(cx * f + ph) * math.cos(cz * f * 1.3 + ph * 0.6)
        local b  = math.sin((cx + cz) * f * 0.5 + ph * 2.1)
        return math.max(-1.0, math.min(1.0, a * 0.7 + b * 0.3))
    end
    local function randomize(baseValue, regionalAmt, noiseAmt, slot)
        return baseValue + regionalField(slot) * regionalAmt + noiseField(slot) * noiseAmt
    end

    local tunN  = getTuningMult(self.settings, "tuningDefaultN",  "DEFAULT_N")
    local tunP  = getTuningMult(self.settings, "tuningDefaultP",  "DEFAULT_P")
    local tunK  = getTuningMult(self.settings, "tuningDefaultK",  "DEFAULT_K")
    local tunPH = getTuningMult(self.settings, "tuningDefaultPH", "DEFAULT_PH")
    local tunOM = getTuningMult(self.settings, "tuningDefaultOM", "DEFAULT_OM")
    local V     = SoilConstants.FIELD_VARIATION

    -- Clamp to [0,100] / range to match the load path so init and reload stay consistent.
    -- At tuning index 5 DEFAULT_N/DEFAULT_K = 100 and the spread can push above 100, so
    -- an unclamped value would read >100 until the first save/reload snapped it back.
    local soil = {
        nitrogen      = math.max(0,   math.min(100,  math.floor(randomize(tunN, tunN * V.NPK_REGIONAL, tunN * V.NPK_NOISE, 1)))),
        phosphorus    = math.max(0,   math.min(100,  math.floor(randomize(tunP, tunP * V.NPK_REGIONAL, tunP * V.NPK_NOISE, 2)))),
        potassium     = math.max(0,   math.min(100,  math.floor(randomize(tunK, tunK * V.NPK_REGIONAL, tunK * V.NPK_NOISE, 3)))),
        organicMatter = math.max(1.0, math.min(10.0, randomize(tunOM, V.OM_REGIONAL, V.OM_NOISE, 4))),
        pH            = math.max(5.0, math.min(8.5,  randomize(tunPH, V.PH_REGIONAL, V.PH_NOISE, 5))),
    }

    -- Bundled GRLE override: replace the rolled pH with a spatially-aware value from the
    -- pre-baked regional map. Only fires when terrain info layers are absent
    -- (SoilLayerSystem.available = false), so map-prepared saves are unaffected.
    if not (self.layerSystem and self.layerSystem.available) then
        if self.bundledMaps and self.bundledMaps.available and farmlandObj then
            local cx, cz = self.bundledMaps:getFarmlandCenter(farmlandObj)
            if cx ~= nil then
                local sampledPH = self.bundledMaps:sampleAtWorldPos(cx, cz)
                if sampledPH ~= nil then
                    soil.pH = sampledPH
                    SoilLogger.debug("BundledMaps: field %d pH set to %.2f from GRLE (world %.0f,%.0f)", fieldId, sampledPH, cx, cz)
                end
            end
        end
    end

    return soil
end

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

    -- Allow lazy creation (HUD-safe, server-only in multiplayer).
    -- Attempt a farmland area lookup at creation time so the correct area is used for
    -- nutrient/herbicide calculations from the very first plow or spray pass. Without
    -- this, area defaults to 1.0 ha and only corrects on first fertilizer spray.
    local confirmedArea = false
    local initialArea = area or 1.0
    local farmlandObj = g_farmlandManager and g_farmlandManager:getFarmlandById(fieldId) or nil
    if farmlandObj and not area and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
        initialArea = farmlandObj.areaInHa
        confirmedArea = true
    end
    if area and area > 0 then
        confirmedArea = true
    end

    -- Roll the starting soil profile (regional gradient + per-field noise, plus any
    -- bundled-GRLE pH override). Shared with the SoilRerollFields console command.
    local soil = self:_computeInitialSoil(fieldId, farmlandObj)

    self.fieldData[fieldId] = {
        fieldArea = initialArea,
        _farmlandAreaConfirmed = confirmedArea,
        nitrogen      = soil.nitrogen,
        phosphorus    = soil.phosphorus,
        potassium     = soil.potassium,
        organicMatter = soil.organicMatter,
        pH            = soil.pH,
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
        activeDisease = nil,        -- DISEASE_DEFS id of the current named infection (nil = none)
        activeDiseaseSeverity = 1.0,-- cached yield-severity multiplier for activeDisease
        lastFungicide = nil,        -- last chemical applied (for resistance / UI flavor)
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

    -- Pre-populate zone tiles immediately so the overlay shows at full opacity
    -- as soon as a new field is created (e.g. on farmland purchase).
    self:_prePopulateZoneData(fieldId)

    return self.fieldData[fieldId]
end

-- Re-roll the starting soil profile of EVERY known field using the current variation
-- logic (:_computeInitialSoil). Lets players on an existing save pick up the regional
-- variation introduced in 2.4.2.6 without starting a new game (issue #632). Resets
-- N/P/K/pH/OM and clears per-zone data so the soil maps repaint from the new averages;
-- crop history, pressures, money and progression are left untouched.
-- Returns the number of fields re-rolled.
function SoilFertilitySystem:rerollAllFields()
    local count = 0
    for fieldId, field in pairs(self.fieldData) do
        if type(fieldId) == "number" and type(field) == "table" then
            local soil = self:_computeInitialSoil(fieldId)
            field.nitrogen          = soil.nitrogen
            field.phosphorus        = soil.phosphorus
            field.potassium         = soil.potassium
            field.organicMatter     = soil.organicMatter
            field.pH                = soil.pH
            field.fertilizerApplied = 0
            -- Drop cached per-zone values and rebuild from the new field average so the
            -- overlay / minimap reflect the re-rolled profile immediately.
            field.zoneData = {}
            self:_prePopulateZoneData(fieldId)
            count = count + 1
        end
    end
    SoilLogger.info("rerollAllFields: re-rolled soil for %d fields", count)
    return count
end

-- Re-roll the starting soil profile of every field the local player's farm does NOT
-- own, leaving owned fields (and all the fertilisation work done on them) untouched.
-- Companion to rerollAllFields for players who want to vary the rest of the map after
-- the 2.4.2.6 spread change without wiping the soil they built up themselves (#632).
-- Ownership is read via g_farmlandManager:getFarmlandOwner, the same idiom the spray
-- hook uses. If the player's farm can't be resolved we abort rather than risk wiping
-- owned fields. Returns: rerolled count, skipped (owned) count.
function SoilFertilitySystem:rerollUnownedFields()
    local playerFarmId = g_currentMission and g_currentMission:getFarmId()
    if not playerFarmId or playerFarmId == 0 then
        SoilLogger.warning("rerollUnownedFields: no valid player farm id - aborting to protect owned fields")
        return 0, 0
    end

    local rerolled, skipped = 0, 0
    for fieldId, field in pairs(self.fieldData) do
        if type(fieldId) == "number" and type(field) == "table" then
            local owner = g_farmlandManager and g_farmlandManager:getFarmlandOwner(fieldId)
            if owner == playerFarmId then
                -- Player's own field - leave its soil and progress alone.
                skipped = skipped + 1
            else
                local soil = self:_computeInitialSoil(fieldId)
                field.nitrogen          = soil.nitrogen
                field.phosphorus        = soil.phosphorus
                field.potassium         = soil.potassium
                field.organicMatter     = soil.organicMatter
                field.pH                = soil.pH
                field.fertilizerApplied = 0
                -- Drop cached per-zone values so the overlay/minimap repaint from the
                -- new field average immediately (mirrors rerollAllFields).
                field.zoneData = {}
                self:_prePopulateZoneData(fieldId)
                rerolled = rerolled + 1
            end
        end
    end
    SoilLogger.info("rerollUnownedFields: re-rolled %d unowned field(s), kept %d owned", rerolled, skipped)
    return rerolled, skipped
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

--- Re-stamp the per-cell overlay (zoneData) to the field's CURRENT average N/P/K/pH/OM.
--- Used after an admin "set field state" so the in-game map overlay reflects the change
--- immediately. The HUD reads field-average values live, but the map overlay reads the
--- per-cell zoneData written during the last spray pass, so without this the map kept
--- showing the pre-change values until the next fertiliser pass (#661).
---@param fieldId number
function SoilFertilitySystem:refreshFieldOverlay(fieldId)
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return end
    field.zoneData = field.zoneData or {}

    -- Overlay never built this session (no spray yet) → build it from the polygon, which
    -- stamps every in-polygon cell with the current field-average values.
    if next(field.zoneData) == nil then
        self:_prePopulateZoneData(fieldId)
        return
    end

    -- Overlay already exists → overwrite every cell so the whole field shows the new
    -- uniform value (an admin override sets the field-average, so per-cell variation
    -- from earlier partial passes is intentionally flattened).
    for _, cell in pairs(field.zoneData) do
        cell.N  = field.nitrogen
        cell.P  = field.phosphorus
        cell.K  = field.potassium
        cell.pH = field.pH
        cell.OM = field.organicMatter
    end
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

-- Daily soil update - PHASE 4: converted to batch scheduler.
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
--- Meadow daily profile (FieldSentry Phase 3, #651). Grassland rules: gentle nutrient
--- regrowth toward a pasture equilibrium, a slow organic-matter creep, slow pH drift, and
--- none of the crop-rotation / seasonal-harvest penalties. Pressures shed gently so a
--- converted field settles. Opt-in per field, so normal crops are never touched. The
--- shared daily housekeeping (buffer/coverage/freeze reset, compaction decay) runs in
--- _processOneDailyField before this is called. Coefficients live in SoilConstants.MEADOW.
---@param field table
---@param timeFactor number  1 / daysPerMonth (Issue #349 month normalization)
---@param limits table       SoilConstants.NUTRIENT_LIMITS
function SoilFertilitySystem:_applyMeadowProfile(field, timeFactor, limits)
    local m = SoilConstants.MEADOW
    if not m then return end

    -- Gentle nutrient regrowth (root turnover + clover/legume fixation in the sward).
    field.nitrogen   = math.min(limits.MAX, (field.nitrogen   or 0) + m.REGROW_N * timeFactor)
    field.phosphorus = math.min(limits.MAX, (field.phosphorus or 0) + m.REGROW_P * timeFactor)
    field.potassium  = math.min(limits.MAX, (field.potassium  or 0) + m.REGROW_K * timeFactor)

    -- Stable structure: organic matter creeps up slightly, never depletes.
    field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX,
        (field.organicMatter or 0) + m.OM_GAIN * timeFactor)

    -- Slow pH drift toward neutral, at a reduced rate vs cropland.
    local phRate = (SoilConstants.PH_NORMALIZATION.RATE or 0) * m.PH_DRIFT_FACTOR * timeFactor
    if field.pH < limits.PH_NEUTRAL_LOW then
        field.pH = math.min(limits.PH_NEUTRAL_LOW, field.pH + phRate)
    elseif field.pH > limits.PH_NEUTRAL_HIGH then
        field.pH = math.max(limits.PH_NEUTRAL_HIGH, field.pH - phRate)
    end

    -- Grassland sheds accumulated weed/pest/disease pressure instead of building it.
    field.weedPressure    = math.max(0, (field.weedPressure    or 0) - m.PRESSURE_DECAY * timeFactor)
    field.pestPressure    = math.max(0, (field.pestPressure    or 0) - m.PRESSURE_DECAY * timeFactor)
    field.diseasePressure = math.max(0, (field.diseasePressure or 0) - m.PRESSURE_DECAY * timeFactor)
end

function SoilFertilitySystem:_processOneDailyField(fieldId, field)
    -- FieldSentry gate (#651): a field the player has put to sleep (manual blacklist)
    -- - or that a later phase disables (deco/NPC/farmland) - skips the daily
    -- depletion/recovery/leaching/seasonal pass entirely, so its soil values freeze
    -- at whatever they were. Single O(1) check; no equation code below is touched.
    local isMeadow = false
    if FieldSentry_API then
        -- Phase 2 (#654): re-evaluate contract status on this same daily-batch seam so
        -- masking tracks active vanilla/NPC contracts without a parallel scheduler. Then
        -- gate. refreshContract is server-authoritative and a no-op on older builds.
        if FieldSentry_API.refreshContract then
            FieldSentry_API.refreshContract(fieldId)
        end
        local disabled, _, meadow = FieldSentry_API.isFieldSimDisabled(fieldId)
        if disabled then return end
        -- Phase 3 (#651): a meadow field still simulates, but on grassland rules.
        isMeadow = meadow == true
    end

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

    -- Session spray coverage (pass %) also resets on day change - stale coverage
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
            -- Route through _applyCompactionDecay so the recovery sticks: shaving
            -- field.compaction alone was wiped by the next per-cell rewrite.
            self:_applyCompactionDecay(field, cp.NATURAL_DECAY_PER_DAY * timeFactor * tunComp)
        end
    end

    -- ── Meadow profile branch (FieldSentry Phase 3, #651) ────────────────────
    -- A field the player flagged as a meadow follows grassland rules instead of the
    -- crop-rotation logic below: gentle nutrient regrowth, slow pH drift, stable organic
    -- matter, and no rotation/seasonal-harvest penalties. FieldSentry only supplies the
    -- toggle; the profile itself lives here in S&F (locked decision, #651). The shared
    -- housekeeping above (buffer/coverage/freeze reset, compaction decay) already ran.
    if isMeadow then
        self:_applyMeadowProfile(field, timeFactor, limits)
        return
    end

    -- ── Passive organic-matter oxidation (#695) ──────────────────────────────
    -- Humus oxidizes continuously; without organic returns OM slowly declines. Fallow
    -- recovery (below) adds it back so an idle field still nets positive (+0.005/day),
    -- while a field under active cropping with no organic inputs loses ground over seasons.
    -- Floored so passive decay alone never grinds soil down to nothing. Meadows are exempt
    -- (the grassland profile above returned already, and only ever builds OM).
    local omDyn = SoilConstants.OM_DYNAMICS
    if omDyn and (omDyn.DAILY_DECAY or 0) > 0 then
        local om = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        field.organicMatter = math.max(omDyn.DECAY_FLOOR or 0, om - omDyn.DAILY_DECAY * timeFactor)
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

    -- ── Legume live nitrogen fixation while standing (#674) ──────────────────
    -- A growing legume fixes atmospheric nitrogen through its root nodules. Most of
    -- that nitrogen is consumed by the plant itself, so this live trickle is kept
    -- deliberately small; the real soil payoff still arrives as the post-crop rotation
    -- bonus above, when roots and residue break down. sownCrop is the currently-drilled
    -- crop (set on seeding, cleared on harvest) so the trickle runs only while the legume
    -- is actually in the ground, and pauses over winter dormancy. Reuses the cropRotation
    -- setting - nothing new to switch on. Meadow legumes (clover/luzerne) are handled by
    -- the meadow profile's sward fixation and returned earlier, so no double-counting.
    if self.settings.cropRotation and season ~= seasonal.WINTER_SEASON then
        local cr = SoilConstants.CROP_ROTATION
        local sown = field.sownCrop and string.lower(field.sownCrop) or nil
        if sown and cr.LEGUMES[sown] then
            field.nitrogen = math.min(limits.MAX, field.nitrogen + cr.LEGUME_GROWTH_N_PER_DAY * timeFactor)
        end
    end

    -- ── Taproot bio-drilling decompaction while standing (#687) ──────────────
    -- Deep-rooting crops (oilseed radish, and to a lesser extent canola) drive roots
    -- through compacted layers, easing compaction biologically as they grow. A slow,
    -- passive helper on top of natural decay - never a subsoiler replacement. Mirrors the
    -- daily natural-decay reduction (field-average), respects the same decay tuning, and
    -- pauses over winter dormancy. sownCrop keeps it running only while the crop stands.
    if self.settings.compactionEnabled and SoilConstants.COMPACTION
       and (field.compaction or 0) > 0 and season ~= seasonal.WINTER_SEASON then
        local cp   = SoilConstants.COMPACTION
        local sown = field.sownCrop and string.lower(field.sownCrop) or nil
        local taprootMult = sown and cp.TAPROOT_CROPS and cp.TAPROOT_CROPS[sown] or nil
        if taprootMult then
            local tunComp = getTuningMult(self.settings, "tuningCompactionDecay", "ZERO_MULT")
            -- Same persistence fix as natural decay: the bio-drilling gain must land on
            -- compactionSum/zoneData or the next subsoiler/wheel pass erases it.
            self:_applyCompactionDecay(field,
                cp.TAPROOT_DECOMPACT_PER_DAY * taprootMult * timeFactor * tunComp)
        end
    end

    -- ── pH slow drift toward neutral ─────────────────────────────────────────
    if field.pH < limits.PH_NEUTRAL_LOW then
        field.pH = math.min(limits.PH_NEUTRAL_LOW, field.pH + phNorm.RATE * timeFactor)
    elseif field.pH > limits.PH_NEUTRAL_HIGH then
        field.pH = math.max(limits.PH_NEUTRAL_HIGH, field.pH - phNorm.RATE * timeFactor)
    end

    -- ── Weed pressure - sourced from game's native weed density map ─────────
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
            -- Do NOT force WEED_STATE_CLEAR - state 7 (withered) transitions to 0
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
            -- and getHarvestScaleMultiplier semantics - higher = more yield penalty).
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
            -- 1-2 days - reading it would overwrite the pressure reduction from onHerbicideApplied.
            -- Under protection, or when herbicide was applied today (even partial coverage), only
            -- allow pressure to decrease - never let the daily weedFactor read undo a reduction.
            -- herbicideAppliedDay is set by onHerbicideApplied (FERTILIZER_PROFILES path);
            -- herbicideDailyApplied is set by the direct-application path - check both.
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

            -- Named-disease layer modifiers: difficulty, soil health, crop rotation.
            local diff = SoilConstants.DISEASE_DIFFICULTY[self.settings.diseaseDifficulty or 2]
                or SoilConstants.DISEASE_DIFFICULTY[2]
            local diffMult = diff.pressureMult or 1.0
            local soilMult = SoilDiseaseSystem.soilHealthMult(field)
            local rotMult  = self.settings.cropRotation and SoilDiseaseSystem.rotationMult(field) or 1.0

            local rainBonus = isRaining and (dp.RAIN_BONUS * cm.rainBonusMult) or 0
            local tunDis = getTuningMult(self.settings, "tuningDiseaseGrowth", "ZERO_MULT")
            field.diseasePressure = math.min(100, pressure + ((baseRate * cm.growthMult * seasonMult * cropMult * tunDis * diffMult * soilMult * rotMult) + rainBonus) * timeFactor)
        end

        -- Maintain the named active disease over the scalar pressure.
        self:_updateActiveDisease(fieldId, field, season, isRaining, currentDay)
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
    -- clamp and the MAX_DAILY_INCREASE spike cap applied above (#536) - withered
    -- weeds still count as coverage in that sampler. The FieldState.weedFactor
    -- read above is the single authoritative source.
    local layerSys = self.layerSystem

    -- Refresh the field-uniform yield value painted into the soilYield layer.
    -- getFieldInfo returns the SAME field-average yield % shown on the Soil Monitor
    -- and applied by the combine hook, so the map layer can never disagree with the
    -- grain you harvest. No managed crop (fallow/grass) → 0 (renders empty).
    do
        local yinfo = self:getFieldInfo(fieldId)
        field.yieldEfficiency = (yinfo and yinfo.yieldEfficiency) or 0
    end

    -- ── Sync all nutrient/pressure layers to density maps ───────────────────
    -- Paint non-perPixel layers (pest/disease/compaction/yield) with the daily average.
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
-- PHASE 1: Only leach owned/active fields - unowned parcels don't need
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
---@param harvestedLiters number 0/1 flag from addCutterArea (NOT actual grain volume - use area for depletion)
---@param strawRatio number 0.0-1.0 fraction of straw chopped back into the field (adds organic matter)
---@param area number Area harvested in pixels - always used for depletion; liters is unreliable
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

    -- Shift crop history ONCE per harvest event (lastCrop → lastCrop2 → lastCrop3).
    -- updateFieldNutrients fires many times during a single harvest (addCutterArea is
    -- per-cut, see Step 1), so an unguarded shift pushes the SAME crop into lastCrop2 and
    -- lastCrop3 within one harvest - faking a 3-season monoculture and a false rotation
    -- fatigue penalty (#638). A genuine new harvest event = the crop differs from the last
    -- recorded crop, OR this harvest is on a later game day than the previous record. Both
    -- conditions collapse the repeated per-cut calls (same crop, same day) into one shift,
    -- while still recording back-to-back same-crop seasons so fatigue detection works.
    local currentDay = (g_currentMission and g_currentMission.environment
                        and g_currentMission.environment.currentDay) or 0
    if field.lastCrop ~= fruitDesc.name or field.lastHarvest ~= currentDay then
        field.lastCrop3 = field.lastCrop2
        field.lastCrop2 = field.lastCrop
    end

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
            SoilLogger.debug("updateFieldNutrients: getFruitPixelsToSqm unavailable - skipping depletion for field %d", fieldId)
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

    -- Step 2b: Compaction penalty - compacted soil reduces nutrient uptake efficiency,
    -- causing crops to deplete more of what's available to achieve the same yield.
    if self.settings.compactionEnabled and SoilConstants.COMPACTION then
        local cp = SoilConstants.COMPACTION
        local compaction = field.compaction or 0
        if compaction > 0 then
            local penalty = (compaction / 100) * cp.NUTRIENT_PENALTY_MAX
            factor = factor * (1 + penalty)
        end
    end

    -- Step 3a: Crop rotation fatigue - same crop two seasons running depletes more.
    -- Perennial forages (alfalfa, grass, ryegrass…) are cut several times per season and
    -- legitimately stay on the same field for years, so they must NOT trip monoculture
    -- fatigue - a 3rd cut is peak management, not a tired field (#694).
    local isPerennialForage = SoilConstants.PERENNIAL_FORAGE_NAMES
                              and SoilConstants.PERENNIAL_FORAGE_NAMES[name]
    if self.settings.cropRotation and not isPerennialForage
       and field.lastCrop2 and field.lastCrop2 == fruitDesc.name then
        factor = factor * SoilConstants.CROP_ROTATION.FATIGUE_MULTIPLIER
        self:log("Rotation fatigue on field %d (%s harvested twice) - factor ×%.2f",
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
    field.lastHarvest = currentDay

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

--- Would applying a lime or organic amendment to this crop right now scorch it? (#437/#684)
--- True only once the crop has leaf area to burn: for perennial forage that means inside the
--- harvest window (tall sward); for annuals, past the early seedling stage (#681). Shared by
--- the actual burn gate (applyFertilizer) and the monitor's pre-emptive "burn risk" warning.
---@param fruitTypeIndex number|nil
---@param growthState number|nil
---@return boolean
function SoilFertilitySystem:isAmendmentBurnRisk(fruitTypeIndex, growthState)
    if not fruitTypeIndex then return false end
    local fruitDesc = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if not fruitDesc then return false end
    local fruitName    = fruitDesc.name and string.lower(fruitDesc.name)
    local perennialSet = SoilConstants.PERENNIAL_FORAGE_NAMES
    local gs = growthState or 0
    if fruitName and perennialSet and perennialSet[fruitName] then
        -- Perennial forage: burnable only inside the harvest window (tall sward).
        local minH = fruitDesc.minHarvestingGrowthState
        local maxH = fruitDesc.maxHarvestingGrowthState
        local cutStates = fruitDesc.cutStates
        return (minH and minH > 0 and gs >= minH
            and (not maxH or maxH <= 0 or gs <= maxH)
            and not (cutStates and cutStates[gs])) or false
    end
    -- Annual: burnable once established past the early seedling stage.
    local minH = fruitDesc.minHarvestingGrowthState or 6
    local frac = (SoilConstants.AMEND_BURN and SoilConstants.AMEND_BURN.ANNUAL_SEEDLING_FRACTION) or 0.33
    local establishedState = math.max(2, math.ceil(minH * frac))
    return gs >= establishedState
end

--- Gradually build up the amendment burn instead of jumping to the cap (#688). Metered by
--- application time exactly like the over-application burn: each tick adds a slice of the cap
--- proportional to the elapsed time since the last application tick, so a brief brush or a
--- slide onto the field costs only a small fraction and you have time to shut the sprayer off.
--- Sibling boom sections in the same tick contribute dt == 0 (no double-count). A gap longer
--- than BURN_PASS_GAP_MS (boom lifted, headland turn) opens a fresh pass. The penalty never
--- decreases (an OM application won't lower an existing lime burn), and is cleared on harvest
--- (consumed) or on sow/tillage (#681).
---@param field table   Field data record
---@param maxPen number Cap this burn type builds up to (LIME_MAX / OM_MAX)
---@return number penalty  The current accumulated amendment-burn penalty (0-1)
function SoilFertilitySystem:applyAmendmentBurnSlice(field, maxPen)
    local burnCfg = SoilConstants.SPRAYER_RATE
    local gapMs   = (burnCfg and burnCfg.BURN_PASS_GAP_MS) or 1500
    local fullMs  = (burnCfg and burnCfg.BURN_FULL_DAMAGE_MS) or 8000
    local now     = (g_currentMission and g_currentMission.time) or 0

    local last = field._amendBurnTickTime
    field._amendBurnTickTime = now
    local dt = (last and (now - last) <= gapMs) and (now - last) or 0

    if dt > 0 and fullMs > 0 then
        local inc    = maxPen * (dt / fullMs)
        local ramped = math.min(maxPen, (field.amendBurnPenalty or 0) + inc)
        field.amendBurnPenalty = math.max(field.amendBurnPenalty or 0, ramped)
    end
    return field.amendBurnPenalty or 0
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
            local cropFruitIndex, cropGrowthState = nil, nil
            if fsField and fsField.posX and fsField.posZ then
                local ok, fs = pcall(function()
                    local s = FieldState.new()
                    s:update(fsField.posX, fsField.posZ)
                    return s
                end)
                if ok and fs and fs.fruitTypeIndex ~= nil and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
                    hasCrop          = true
                    cropFruitIndex   = fs.fruitTypeIndex
                    cropGrowthState  = fs.growthState
                end
            end
            if hasCrop then
                -- Perennial forage (grass, meadow, alfalfa…) is exempt from amendment burn
                -- while the sward is short - young regrowth or freshly cut. Liming or spreading
                -- organics on a short/cut sward is standard practice (small leaf area, low burn
                -- risk), so only penalise once it has regrown into its harvest window (tall).
                -- Annual crops are never exempt. Shared by lime (#646) and organic matter
                -- (#629/#645).
                -- A short/early crop must not take the amendment burn: a seedling annual or a
                -- short/cut perennial sward has no leaf canopy to scorch (#645/#646/#681). The
                -- shared helper decides whether the crop is established enough to actually burn.
                local burnExempt = not self:isAmendmentBurnRisk(cropFruitIndex, cropGrowthState)

                local ab = SoilConstants.AMEND_BURN
                if isLimeAmendment then
                    -- #646/#681: liming cut/early perennial forage or a freshly-sown annual is
                    -- realistic, so skip the burn there. Established crops still take it, but it
                    -- now builds up over application time (#688) instead of instant -80%.
                    if not burnExempt then
                        self:applyAmendmentBurnSlice(field, (ab and ab.LIME_MAX) or 0.80)
                        if not field._amendBurnNotified then
                            field._amendBurnNotified = true
                            self:showNotification(
                                g_i18n:getText("sf_notify_lime_crop_title"),
                                string.format(g_i18n:getText("sf_notify_lime_crop_body"), fieldId))
                        end
                    end
                else
                    -- #629/#645/#681: organic fertilizer (slurry/manure/digestate) on short/cut
                    -- perennial forage or a freshly-sown annual is standard practice, so skip it.
                    -- On an established crop it builds up over application time toward OM_MAX (#688).
                    if not burnExempt then
                        self:applyAmendmentBurnSlice(field, (ab and ab.OM_MAX) or 0.20)
                        if not field._amendBurnNotified then
                            field._amendBurnNotified = true
                            self:showNotification(
                                g_i18n:getText("sf_notify_om_crop_title"),
                                string.format(g_i18n:getText("sf_notify_om_crop_body"), fieldId))
                        end
                    end
                end
            end
        end
    end

    local limits = SoilConstants.NUTRIENT_LIMITS

    -- AREA NORMALIZATION: Calculate hectares for this field.
    -- Confirm area on first spray of each session - prefer the actual crop polygon area (field.areaHa)
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
        -- N/P/K/OM are NOT bulk-synced - cells visited by the boom (markBoomCells)
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
        -- No throttle - live updates paint a continuous trail on the minimap heatmap.
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
            -- cellFactor note: must use areaInHa (not zone.CELL_AREA_HA) - see issue #205 Bug 2.
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
    -- Skip notification for crop-protection products (INSECTICIDE, FUNGICIDE, HERBICIDE) -
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
    -- Duration is in in-game DAYS (decremented 1/game-day); see #639 / onHerbicideApplied.
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.insecticideDaysLeft = pp.INSECTICIDE_DURATION_DAYS
    end

    -- Update per-cell pest pressure for existing zoneData entries only.
    -- Do NOT create new entries here - doing so would stamp N/P/K/pH/OM field-average
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
    -- Duration is in in-game DAYS (decremented 1/game-day); see #639 / onHerbicideApplied.
    local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
    if (field.sessionCoverageFraction or 0) >= protThreshold then
        field.fungicideDaysLeft = math.floor(dp.FUNGICIDE_DURATION_DAYS * (cm.fungicideMult or 1))
    end

    -- Update per-cell disease pressure for existing zoneData entries only.
    -- Do NOT create new entries here - doing so would stamp N/P/K/pH/OM field-average
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
-- still smooth per-frame (good HUD feel) but over-application is useless -
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

--- Resolve and cache the world-space crop-boundary polygon for a field.
--- Used to bound coverage + overlay stamping to the actual field polygon so that
--- wide-boom overhang past the headland and turn-row sweeps can't credit off-field
--- cells (which previously pushed pass% to 100% before the field was done).
--- Resolved once per field and cached on field._polyVerts:
---   • a verts array (>=3 points) when the polygon is available
---   • false when it is not (caller falls back to counting every cell)
--- Same resolution path as _prePopulateZoneData (g_fieldManager.fields → polygonPoints).
---@param fieldId number
---@param field   table   self.fieldData[fieldId]
---@return table|nil verts  Array of {x=, z=} world coords, or nil when unavailable
function SoilFertilitySystem:_getFieldPolyVerts(fieldId, field)
    -- Cached result: verts table = available, false = resolved-but-unavailable.
    if field._polyVerts ~= nil then
        return field._polyVerts or nil
    end

    local verts = nil
    if g_fieldManager and g_fieldManager.fields then
        for _, f in ipairs(g_fieldManager.fields) do
            if f and f.farmland and f.farmland.id == fieldId then
                local polyNodes = f.polygonPoints
                if polyNodes and #polyNodes > 0 then
                    verts = {}
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
                break
            end
        end
    end

    if verts and #verts >= 3 then
        field._polyVerts = verts
        return verts
    end

    field._polyVerts = false  -- mark unavailable so we don't retry every spray tick
    return nil
end

--- Stamp zone cells at every position in boomPoints and update cell-deduped coverage.
--- Coverage (session + daily) is incremented only for cells not previously visited,
--- eliminating overlap inflation from headland turns and second passes.
--- Cells whose centre falls outside the field polygon are rejected so coverage
--- stays consistent with the polygon-bounded overlay (see _prePopulateZoneData).
--- Also stamps visual overlay entries (zoneData) for the PDA map.
--- Called from HookManager after applySingle to fill in the full lateral sweep.
---
--- overlayOnly: when true, stamp the visual overlay (zoneData) and the spray trail
--- but DO NOT advance the session/daily coverage counters - the caller drives those
--- via the liter-based trackSprayerCoverage instead. Used for broadcast / dry
--- spreaders (no VariableWorkWidth): the per-field polygon test below rejects boom
--- cells that credit the wrong sub-field on multi-field farmlands, which froze the
--- pass% / session-ha counters for dry spreaders after #626 rerouted them off the
--- liter path (#650). The liter estimate has no such polygon dependency.
---@param fieldId   number
---@param boomPoints table  Array of {x=, z=} world positions
---@param overlayOnly boolean|nil  When true, stamp visuals only; skip coverage counters
function SoilFertilitySystem:markBoomCells(fieldId, boomPoints, overlayOnly)
    if not boomPoints or #boomPoints == 0 then return end
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return end

    local zone     = SoilConstants.ZONE
    local cellArea = zone.CELL_AREA_HA  -- 0.01 ha per 10×10 m cell
    local areaInHa = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0

    -- Field polygon (nil = unavailable → count every cell, as before).
    local polyVerts = self:_getFieldPolyVerts(fieldId, field)

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

            -- Cell centre - used both for the polygon membership test and the
            -- spray-trail point so they stay in lockstep.
            local cellCx = (cx + 0.5) * zone.CELL_SIZE
            local cellCz = (cz + 0.5) * zone.CELL_SIZE

            -- Reject boom cells whose centre falls outside the field polygon.
            -- Wide-boom overhang past the headland and turn-row sweeps would
            -- otherwise credit off-field cells, inflating pass% to 100% before
            -- the field interior is actually covered. This matches the overlay,
            -- which is already polygon-bounded in _prePopulateZoneData. When the
            -- polygon is unavailable (polyVerts == nil) fall back to counting all.
            if polyVerts == nil or _isPointInPoly(cellCx, cellCz, polyVerts) then

                -- ── Coverage deduplication ─────────────────────────────────────────
                -- Store stamp timestamp (ms) so the overlap check can apply a grace period
                -- and avoid suppressing sections that are still on their current pass.
                if not field.sessionCoverageCells[cellKey] then
                    field.sessionCoverageCells[cellKey] = (g_currentMission and g_currentMission.time) or 0
                    if not overlayOnly then
                        field.sessionCoverageHa = math.min(areaInHa, (field.sessionCoverageHa or 0) + cellArea)
                    end
                    -- ── Spray trail (in-view overlay) ──────────────────────────────
                    -- Cache world-center + terrain height for SoilHUD:drawSprayTrail().
                    if not field.sprayTrailPts then field.sprayTrailPts = {} end
                    local twy = 0.3
                    if g_terrainNode then
                        local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, cellCx, 0, cellCz)
                        if ok and h then twy = h + 0.3 end
                    end
                    table.insert(field.sprayTrailPts, {wx = cellCx, wy = twy, wz = cellCz})
                end
                if not overlayOnly and not field.dailyCoverageCells[cellKey] then
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
    end

    -- Recompute fractions after all cells are processed.
    -- In overlayOnly mode the counters are owned by trackSprayerCoverage (liter-based);
    -- leave the fractions it set untouched so the pass% / ha display stays consistent.
    if not overlayOnly then
        field.coverageFraction        = math.min(1.0, (field.coveredAreaHa  or 0) / areaInHa)
        field.sessionCoverageFraction = math.min(1.0, (field.sessionCoverageHa or 0) / areaInHa)

        -- Issue #660 / #661 diagnostics: pass% is reported wrong on some implements - the
        -- fertilizing seeder over-counts (94% at half done), a wide dry-lime spreader on a
        -- 40 ha field under-counts (35% when nearly done). Log the raw inputs (unique session
        -- cells, session ha, field ha, fraction, boom-point count, cell ha) throttled once / 2 s
        -- per field so a single user log shows whether the FIELD AREA or the CELL COUNT is off.
        local _now = (g_currentMission and g_currentMission.time) or 0
        if (_now - (field._covDiagAt or 0)) > 2000 then
            field._covDiagAt = _now
            local nCells = 0
            for _ in pairs(field.sessionCoverageCells) do nCells = nCells + 1 end
            SoilLogger.debug("CoverageDiag field=%d cells=%d sessHa=%.3f fieldHa=%.3f frac=%.0f%% boomPts=%d cellHa=%.4f",
                fieldId, nCells, field.sessionCoverageHa or 0, areaInHa,
                (field.sessionCoverageFraction or 0) * 100, #boomPoints, cellArea)
        end
    end

    -- Full pass complete - clear trail so the overlay disappears as a visual reward.
    -- Match the 0.99 threshold used by overlap prevention so dots clear when the
    -- sprayer auto-shuts off rather than requiring the last fractional percent.
    if (field.sessionCoverageFraction or 0) >= 0.99 and field.sprayTrailPts then
        field.sprayTrailPts = nil
    end
end

--- Direct-path buffering for non-profile products (Herbicide/Insecticide/Fungicide)
-- NOTE: the formula (liters/targetVol)×REDUCTION depends on targetRate (from
-- Constants, a real-world L/ha figure ~1.5) matching the actual vanilla sprayer
-- LPS (~93.5 L/ha for liquid).  It does NOT - hence the daily cap below.
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
        -- Only grant protected status once 80% of the field has been covered (issue #441)
        local protThreshold = SoilConstants.COVERAGE and SoilConstants.COVERAGE.PROTECTION_THRESHOLD or 0.80
        local wasProtected = (field.herbicideDaysLeft or 0) > 0
        if (field.sessionCoverageFraction or 0) >= protThreshold then
            -- Duration is in in-game DAYS (decremented 1/game-day); see #639.
            field.herbicideDaysLeft = SoilConstants.WEED_PRESSURE.HERBICIDE_DURATION_DAYS
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

        -- Broadcast updated weed pressure to all clients (dedicated server fix - Issue #257)
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
--- Called by HookManager every tick (and once per boom section) while fertilizer
--- is applied at rate > BURN_RISK_THRESHOLD.
---
--- The burn is *metered by how long you over-apply*, not fired per tick: each tick
--- docks a slice of pH/N proportional to the elapsed over-spray time, capped per
--- pass at the BURN_*_CERTAIN/RISK magnitudes. A brief overlap costs a small slice;
--- BURN_FULL_DAMAGE_MS of continuous over-spray reaches the full magnitude. Sibling
--- boom sections in the same tick contribute dt == 0, so a wide boom never
--- multiplies the penalty. A spray gap longer than BURN_PASS_GAP_MS (boom lifted,
--- headland turn) starts a fresh pass.
---
--- Approach #1 from issue #649: the dock still lands on the whole-field pH/N scalar
--- (soil is tracked per field, not per zone, and yield is field-average by design),
--- but metering by duration makes the *magnitude* proportional to the over-applied
--- area for a given boom, so a small/brief overlap no longer craters the field.
---@param fieldId number
---@param rateMultiplier number The actual rate multiplier used (e.g. 1.5)
function SoilFertilitySystem:applyBurnEffect(fieldId, rateMultiplier)
    local field = self.fieldData[fieldId]
    if not field then return end

    local burnCfg = SoilConstants.SPRAYER_RATE
    local limits  = SoilConstants.NUTRIENT_LIMITS
    local now     = (g_currentMission and g_currentMission.time) or 0
    local gapMs   = burnCfg.BURN_PASS_GAP_MS or 1500
    local fullMs  = burnCfg.BURN_FULL_DAMAGE_MS or 8000

    -- ── Pass continuity & elapsed-time slice ─────────────────────────────────
    -- dt is the over-spray time since the previous tick. Sibling sections in the
    -- same tick see dt == 0 (the first one already advanced _lastBurnTickTime).
    local dt
    if field._lastBurnTickTime and (now - field._lastBurnTickTime) <= gapMs then
        dt = now - field._lastBurnTickTime
    else
        -- New pass: reset the per-pass accumulators, caps and one-shot flags.
        dt = 0
        field._burnPassPh       = 0
        field._burnPassN        = 0
        field._burnPassNotified = nil
    end
    field._lastBurnTickTime = now
    if dt <= 0 then return end   -- first tick of a pass, or a sibling section this tick

    -- ── Full-pass magnitude for the current rate (the per-pass cap) ───────────
    local fullPh, fullN
    if rateMultiplier >= burnCfg.BURN_GUARANTEED_THRESHOLD then
        fullPh, fullN = burnCfg.BURN_PH_DROP_CERTAIN, burnCfg.BURN_N_DRAIN_CERTAIN
    else
        -- Risk band: magnitude scales linearly with how far past the risk threshold.
        local excess = (rateMultiplier - burnCfg.BURN_RISK_THRESHOLD) /
                       (burnCfg.BURN_GUARANTEED_THRESHOLD - burnCfg.BURN_RISK_THRESHOLD)
        excess = math.max(0.0, math.min(1.0, excess))
        fullPh, fullN = burnCfg.BURN_PH_DROP_RISK * excess, burnCfg.BURN_N_DRAIN_RISK * excess
    end

    -- ── This tick's slice, clamped to the remaining per-pass budget ───────────
    local frac   = math.min(1.0, dt / fullMs)
    local phDrop = math.min(fullPh * frac, math.max(0.0, fullPh - (field._burnPassPh or 0)))
    local nDrain = math.min(fullN  * frac, math.max(0.0, fullN  - (field._burnPassN  or 0)))
    if phDrop <= 0 and nDrain <= 0 then return end

    field.pH          = math.max(limits.PH_MIN, field.pH - phDrop)
    field.nitrogen    = math.max(limits.MIN, field.nitrogen - nDrain)
    field._burnPassPh = (field._burnPassPh or 0) + phDrop
    field._burnPassN  = (field._burnPassN  or 0) + nDrain

    local daysPerMonth = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    field.burnDaysLeft = 3 * daysPerMonth   -- show burn warning in HUD (Issue #349 scaling)

    self:log("Burn slice field %d: pH -%.3f, N -%.2f (pass pH -%.2f, rate=%.0f%%)",
        fieldId, phDrop, nDrain, field._burnPassPh, rateMultiplier * 100)

    -- One notification per pass (the per-tick slices would otherwise spam it).
    if self.settings.showNotifications and not field._burnPassNotified then
        field._burnPassNotified = true
        self:showNotification(
            g_i18n:getText("sf_notify_burn_title"),
            string.format(g_i18n:getText("sf_notify_burn_body"), fieldId, field.pH)
        )
    end

    -- Broadcast in multiplayer, throttled to ~once per gap window so the per-tick
    -- slices don't flood the network. Clients converge via the next sync anyway.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent and (not field._lastBurnBroadcast or (now - field._lastBurnBroadcast) >= gapMs) then
            field._lastBurnBroadcast = now
            g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
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
        -- than the global threshold - so reaching the crop's blue tick always shows Good.
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
    local liveFruitTypeIndex = nil  -- set when a live crop is detected; used to match the harvest freeze
    local liveGrowthState = nil     -- growth state of the live crop, for the amendment-burn-risk check (#684)
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
                    liveFruitTypeIndex = fieldState.fruitTypeIndex
                    liveGrowthState    = fieldState.growthState
                    local fruitDesc = g_fruitTypeManager and
                        g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
                    if fruitDesc and fruitDesc.name then
                        cropName = fruitDesc.name
                    end
                end
            end
        end
    end
    -- Fall back to the just-seeded crop, then lastCrop, when no live fruit is detected.
    -- sownCrop bridges the window between drilling and the centroid actually carrying the
    -- crop, so a half-finished seeding pass shows the NEW crop instead of the previous one (#661).
    if not cropName or cropName == "" then
        cropName = field.sownCrop or field.lastCrop
    end

    -- Compute crop rotation status for external consumers (e.g. FarmTablet)
    local rotationStatus = nil
    if SoilConstants.CROP_ROTATION and field.lastCrop and field.lastCrop2 then
        local cr      = SoilConstants.CROP_ROTATION
        local crop1   = string.lower(field.lastCrop)
        local crop2   = string.lower(field.lastCrop2)
        local pf      = SoilConstants.PERENNIAL_FORAGE_NAMES or {}
        if pf[crop1] then
            -- Multi-cut perennial forage: the same crop standing across several cuts is
            -- normal management, not monoculture fatigue (#694). Only flag a bonus if the
            -- player genuinely rotated INTO it from a non-legume, non-forage crop.
            if cr.LEGUMES[crop1] and not cr.LEGUMES[crop2] and not pf[crop2] then
                rotationStatus = "Bonus"
            else
                rotationStatus = "OK"
            end
        elseif cr.LEGUMES[crop1] and not cr.LEGUMES[crop2] then
            rotationStatus = "Bonus"
        elseif crop1 == crop2 then
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

    -- Yield efficiency forecast - MUST equal the grain the combine actually receives.
    -- The applied reduction (computeYieldModifier) is driven by FIELD-AVERAGE nutrients
    -- and frozen for the duration of a harvest pass, so this forecast does the same:
    --   * during an active harvest of this crop -> return the frozen applied value, so
    --     the % does NOT slide downward as the combine depletes nutrients mid-field
    --     (the "field was 100%, now it's 90%" report)
    --   * otherwise -> call the shared helper with field-average N/P/K (NOT the local
    --     zone-cell n/p/k used for the nutrient readouts above)
    -- Gated on the same conditions as the hopper hook (enabled + nutrientCycles) so the
    -- monitor reads "--" exactly when the game applies no reduction at all.
    -- nil when no managed crop is present (bare, grass, forage).
    local yieldEfficiency = nil
    if self.settings.enabled and self.settings.nutrientCycles
       and not isNonCropField and cropName and cropName ~= "" then
        local mod
        if field.frozenYieldModifier and liveFruitTypeIndex
           and field.frozenYieldFruitType == liveFruitTypeIndex then
            mod = field.frozenYieldModifier
        else
            local avgN = field.nitrogen   or SoilConstants.FIELD_DEFAULTS.nitrogen
            local avgP = field.phosphorus or SoilConstants.FIELD_DEFAULTS.phosphorus
            local avgK = field.potassium  or SoilConstants.FIELD_DEFAULTS.potassium
            mod = self:_yieldModifierFromNutrients(field, cropName, avgN, avgP, avgK, nil)
        end
        yieldEfficiency = math.floor(mod * 100 + 0.5)
    end

    -- FieldSentry (#651) status, surfaced so any readout (field detail dialog, HUD,
    -- map overlay) can show that a slept field's soil is frozen by intent, not broken.
    -- isFieldSimDisabled is allocation-free, so this stays cheap for per-frame callers.
    local fsDisabled, fsReason, fsReasonKey, fsMeadow = false, "active", nil, false
    if FieldSentry_API then
        local d, r, meadow = FieldSentry_API.isFieldSimDisabled(fieldId)
        fsDisabled = d
        fsReason   = FieldSentry_Core.reasonName(r)
        fsMeadow   = meadow == true   -- meadow fields still simulate; surfaced for the monitor (#697)
        if FieldSentry_Core.reasonL10nKey then fsReasonKey = FieldSentry_Core.reasonL10nKey(r) end
    end

    return {
        fieldId = fieldId,
        fieldArea = field.fieldArea or 1.0,
        simDisabled          = fsDisabled,
        simDisabledReason    = fsReason,
        simDisabledReasonKey = fsReasonKey,
        isMeadow             = fsMeadow,
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
        activeDisease = field.activeDisease,  -- DISEASE_DEFS id of the named infection, or nil
        lastFungicide = field.lastFungicide,
        burnDaysLeft = field.burnDaysLeft or 0,
        amendBurnPenalty = field.amendBurnPenalty or 0,  -- pending lime/OM-on-crop burn (0-1); explains a low yield
        amendBurnRisk = self:isAmendmentBurnRisk(liveFruitTypeIndex, liveGrowthState),  -- (#684) true → liming/manuring NOW would scorch the crop
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

    -- Persist the last day the daily update ran. Without this, lastUpdateDay reset to 0 on
    -- load and (currentDay ~= 0) always re-fired the daily pass on reload, which cleared the
    -- frozen yield modifier (so the expected-yield % recomputed lower from the now-depleted
    -- field-average nutrients) and applied a bonus day of fallow / nutrient drift every time
    -- you saved and reloaded (#665).
    setXMLInt(xmlFile, key .. "#lastUpdateDay", self.lastUpdateDay or 0)

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
            setXMLString(xmlFile, fieldKey .. "#sownCrop", field.sownCrop or "")
            setXMLInt(xmlFile, fieldKey .. "#rotationBonusDaysLeft", field.rotationBonusDaysLeft or 0)
            setXMLInt(xmlFile, fieldKey .. "#lastHarvest", field.lastHarvest or 0)
            setXMLFloat(xmlFile, fieldKey .. "#fertilizerApplied", field.fertilizerApplied or 0)
            setXMLFloat(xmlFile, fieldKey .. "#weedPressure", field.weedPressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#herbicideDaysLeft", field.herbicideDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#pestPressure", field.pestPressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#insecticideDaysLeft", field.insecticideDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#diseasePressure", field.diseasePressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#fungicideDaysLeft", field.fungicideDaysLeft or 0)
            setXMLString(xmlFile, fieldKey .. "#activeDisease", field.activeDisease or "")
            setXMLString(xmlFile, fieldKey .. "#lastFungicide", field.lastFungicide or "")
            setXMLInt(xmlFile, fieldKey .. "#dryDayCount", field.dryDayCount or 0)
            setXMLInt(xmlFile, fieldKey .. "#burnDaysLeft", field.burnDaysLeft or 0)
            setXMLInt(xmlFile, fieldKey .. "#lastAlertSeason", field.lastAlertSeason or 0)
            setXMLFloat(xmlFile, fieldKey .. "#coverageFraction", field.coverageFraction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#compaction", field.compaction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#amendBurnPenalty", field.amendBurnPenalty or 0)

            -- Persist the frozen yield modifier so an in-progress harvest keeps the exact
            -- same yield (and any amendment burn baked into it on the first cut) across a
            -- save/reload. Without this, reloading recomputed the modifier from the
            -- now-depleted field-average nutrients with the one-shot burn already consumed,
            -- so the yield figure silently changed after every reload and a save/reload
            -- erased an active burn penalty entirely (#656). Only written while a freeze is
            -- live; cleared on the next game-day change by _processOneDailyField as before.
            if field.frozenYieldModifier and field.frozenYieldFruitType then
                setXMLFloat(xmlFile, fieldKey .. "#frozenYieldModifier", field.frozenYieldModifier)
                setXMLInt(xmlFile, fieldKey .. "#frozenYieldFruitType", field.frozenYieldFruitType)
            end

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

    -- Restore the daily-update day (see saveToXMLFile). Default to the CURRENT day when the
    -- attribute is absent (saves written before 2.4.3.0) so loading an older save does not
    -- fire one stray daily tick on the first load after updating (#665).
    local _curDay = (g_currentMission and g_currentMission.environment
                     and g_currentMission.environment.currentDay) or 0
    self.lastUpdateDay = getXMLInt(xmlFile, key .. "#lastUpdateDay") or _curDay

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
            sownCrop = getXMLString(xmlFile, fieldKey .. "#sownCrop"),
            rotationBonusDaysLeft = getXMLInt(xmlFile, fieldKey .. "#rotationBonusDaysLeft") or 0,
            lastHarvest = getXMLInt(xmlFile, fieldKey .. "#lastHarvest") or 0,
            fertilizerApplied = getXMLFloat(xmlFile, fieldKey .. "#fertilizerApplied") or 0,
            weedPressure = getXMLFloat(xmlFile, fieldKey .. "#weedPressure") or 0,
            herbicideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#herbicideDaysLeft") or 0,
            pestPressure = getXMLFloat(xmlFile, fieldKey .. "#pestPressure") or 0,
            insecticideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#insecticideDaysLeft") or 0,
            diseasePressure = getXMLFloat(xmlFile, fieldKey .. "#diseasePressure") or 0,
            fungicideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#fungicideDaysLeft") or 0,
            activeDisease = getXMLString(xmlFile, fieldKey .. "#activeDisease"),
            activeDiseaseSeverity = 1.0,
            lastFungicide = getXMLString(xmlFile, fieldKey .. "#lastFungicide"),
            dryDayCount = getXMLInt(xmlFile, fieldKey .. "#dryDayCount") or 0,
            burnDaysLeft = getXMLInt(xmlFile, fieldKey .. "#burnDaysLeft") or 0,
            amendBurnPenalty = getXMLFloat(xmlFile, fieldKey .. "#amendBurnPenalty") or nil,
            frozenYieldModifier  = getXMLFloat(xmlFile, fieldKey .. "#frozenYieldModifier") or nil,
            frozenYieldFruitType = getXMLInt(xmlFile, fieldKey .. "#frozenYieldFruitType") or nil,
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

        -- Restore only the DAILY coverage so the daily pass% and protection thresholds
        -- carry across reloads (#608). Do NOT restore the SESSION coverage: it is
        -- session-local and a reload starts a fresh spray session.
        --
        -- Seeding sessionCoverageFraction from the save was the #640 bug: the overlap
        -- prevention gate treats sessionCoverageFraction >= 0.99 as "field fully covered",
        -- suppresses every boom section and forces processSprayerArea to return 0. So any
        -- field that had been fertilized before saving loaded back as already-covered and
        -- silently refused ALL further fertilizer on every crop (the "fields don't update
        -- after spreading" / "N not going up" reports), until a harvest/plow/cultivate/
        -- day-change happened to reset the session fraction. sessionCoverage* stay 0/empty.
        do
            local f = self.fieldData[fieldId]
            f.coveredAreaHa = f.coverageFraction * f.fieldArea
        end

        -- Load daily application throttles
        self.herbicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#herbicideAppliedDay") or 0
        self.insecticideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#insecticideAppliedDay") or 0
        self.fungicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#fungicideAppliedDay") or 0

        -- Refresh fieldArea - prefer the actual crop polygon area (field.areaHa) so that
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
        -- Empty sownCrop must be nil, not "", or getFieldInfo's `sownCrop or lastCrop`
        -- fallback would resolve to "" and hide the real crop just after a reload.
        if self.fieldData[fieldId].sownCrop == "" then
            self.fieldData[fieldId].sownCrop = nil
        end
        -- Named disease: empty → nil, and rebuild the cached yield severity.
        local fdd = self.fieldData[fieldId]
        if fdd.activeDisease == "" then fdd.activeDisease = nil end
        if fdd.lastFungicide == "" then fdd.lastFungicide = nil end
        if fdd.activeDisease and SoilDiseaseSystem then
            fdd.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(fdd.activeDisease)
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

        -- Reconstruct the compaction running sum + field-average from the per-cell
        -- zoneData just loaded. Gameplay (onCompaction / onSubsoilerPass) stores per-cell
        -- compaction in zoneData[cellKey].compaction and derives the field.compaction
        -- scalar from compactionSum / compactionTotalCells - it never populates the legacy
        -- compactionCells table. So saving wrote an empty compactionCells block and the
        -- scalar reset to 0 on every reload, even though the per-cell values round-tripped
        -- in zoneData: that was the "compaction drops to 0% after reload" half of #656.
        -- Rebuilding the sum from zoneData keeps it consistent with the per-cell deltas
        -- that onCompaction / onSubsoilerPass apply afterwards.
        local zone = SoilConstants.ZONE
        local f = self.fieldData[fieldId]
        local compSum = 0
        if f.zoneData then
            for _, cell in pairs(f.zoneData) do
                compSum = compSum + (cell.compaction or 0)
            end
        end
        if compSum > 0 then
            local areaInHa   = f.fieldArea or 1.0
            local totalCells = math.max(1, math.ceil(areaInHa / zone.CELL_AREA_HA))
            local maxC = (SoilConstants.COMPACTION and SoilConstants.COMPACTION.MAX_COMPACTION) or 100.0
            f.compactionSum        = compSum
            f.compactionTotalCells = totalCells
            f.compaction           = math.min(maxC, compSum / totalCells)
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
--- Apply compaction at a world position.
---@param farmlandId number
---@param worldX number
---@param worldZ number
---@param points number|nil Raw ground-pressure points for this pass (surface+subsoil×
---       moisture, NOT yet rate-scaled). When nil, the legacy flat per-pass amount is
---       used. Either way the tuningCompactionRate multiplier is applied here, in one place.
function SoilFertilitySystem:onCompaction(farmlandId, worldX, worldZ, points)
    if not self.settings.compactionEnabled then return end
    local cp = SoilConstants.COMPACTION
    if not cp then return end

    -- Field-ground gate (Talia, Discord): compaction is keyed on the *farmland* parcel,
    -- which also covers painted gravel / parking / decoration ground inside that parcel.
    -- Only pack soil where the engine reports real field ground at this point so a
    -- parking pad on a field no longer compacts (the #672 overlay uses the same check).
    -- y is ignored by the lookup; pass 0 like Giants' own code. If the API is missing
    -- (older build) we proceed rather than silently disabling compaction.
    if FSDensityMapUtil and FSDensityMapUtil.getFieldDataAtWorldPosition then
        local ok, isOnField = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, worldX, 0, worldZ)
        if ok and isOnField == false then return end
    end

    -- Build-up amount. The pressure model (driving + harvest hooks) passes raw points;
    -- legacy callers (none currently) get the flat per-pass amount. The user-facing
    -- tuningCompactionRate multiplier is applied here so it governs every path equally.
    -- ZERO_MULT LUT: idx 1 = 0x (no build-up), 3 = 1x, 5 = 2x.
    local rateMult = getTuningMult(self.settings, "tuningCompactionRate", "ZERO_MULT")
    local base = (points ~= nil) and points or cp.COMPACTION_PER_PASS
    local added = base * rateMult
    if added <= 0 then return end

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
    local newVal = math.min(cp.MAX_COMPACTION, prev + added)
    cell.compaction = newVal

    -- 2. Update field average
    field.compactionSum = (field.compactionSum or 0) + (newVal - prev)
    if (field.compactionTotalCells or 0) == 0 then
        local areaInHa = field.fieldArea or 1.0
        field.compactionTotalCells = math.max(1, math.ceil(areaInHa / zone.CELL_AREA_HA))
    end
    -- Clamp the field-AVERAGE to MAX_COMPACTION. Each cell is already capped at 100, but the
    -- average can creep past it when more cells get packed than `compactionTotalCells` - that
    -- denominator comes from the crop-polygon fieldArea, while cells are packed across the
    -- (larger) real field ground incl. headland/boundary cells. That was the "105% compaction"
    -- overshoot in #703.
    field.compaction = math.min(cp.MAX_COMPACTION, field.compactionSum / field.compactionTotalCells)

    -- 3. Write per-pixel to compaction density map layer
    if self.layerSystem and self.layerSystem.available then
        -- Mark the minimap heatmap dirty so it regenerates and shows the new
        -- compaction immediately. Without this the GRLE fills silently while
        -- driving and only appears on the next spray/harvest/daily refresh.
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
        self.layerSystem:updatePixelForField("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
    end

    SoilLogger.debug("Compaction: field=%d cell=%s  %.0f→%.0f%%  avg=%.1f%%",
        farmlandId, cellKey, prev, newVal, field.compaction)
end

--- Apply a deep-tillage compaction reduction at a specific world position.
---@param farmlandId number
---@param worldX number
---@param worldZ number
---@param reliefPoints number|nil  Points to remove from the cell. Defaults to the full
---                                SUBSOILER_REDUCTION; plows pass the smaller PLOW_RELIEF (#687).
function SoilFertilitySystem:onSubsoilerPass(farmlandId, worldX, worldZ, reliefPoints)
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

    local relief = reliefPoints or cp.SUBSOILER_REDUCTION
    local newVal = math.max(0, prev - relief)
    cell.compaction = newVal

    field.compactionSum = math.max(0, (field.compactionSum or 0) - (prev - newVal))
    local tc = field.compactionTotalCells or 0
    field.compaction = tc > 0 and math.min(cp.MAX_COMPACTION, field.compactionSum / tc) or 0

    -- Write per-pixel to compaction density map layer
    if self.layerSystem and self.layerSystem.available then
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
        self.layerSystem:updatePixelForField("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
    end

    SoilLogger.debug("Subsoiler: field=%d cell=%s  %.0f→%.0f%%  avg=%.1f%%",
        farmlandId, cellKey, prev, newVal, field.compaction)
end

--- Apply a field-average compaction reduction (natural decay, taproot bio-drilling) in a
--- way that PERSISTS through later per-cell rewrites. The displayed average is DERIVED as
--- compactionSum / compactionTotalCells, so shaving only field.compaction (as the daily
--- decay used to) was silently discarded the instant onCompaction / onSubsoilerPass
--- re-derived the average from the untouched compactionSum. That was the "radish
--- decompaction and natural recovery reset on the first subsoiler or wheel pass" report
--- (nemrod153, Discord). Fading compactionSum AND every zoneData cell by the same ratio
--- keeps the accounting total, the
--- per-cell store (read back as `prev` by onCompaction/onSubsoilerPass) and the average
--- mutually consistent, and preserves the existing points-per-day tuning exactly
--- (newAvg = oldAvg - reductionPoints).
---@param field table  fieldData entry
---@param reductionPoints number  points to shave off the field-average compaction
---@return boolean changed
function SoilFertilitySystem:_applyCompactionDecay(field, reductionPoints)
    if not field or not reductionPoints or reductionPoints <= 0 then return false end
    local oldAvg = field.compaction or 0
    if oldAvg <= 0 then return false end

    local newAvg = math.max(0, oldAvg - reductionPoints)
    local ratio  = newAvg / oldAvg   -- oldAvg > 0 guaranteed above

    -- Fade the authoritative accounting total so the derived average survives a later
    -- per-cell rewrite, and fade each per-cell value so relief/build-up math (which reads
    -- cell.compaction as `prev`) stays in lockstep with the faded sum.
    field.compactionSum = (field.compactionSum or 0) * ratio
    if field.zoneData then
        for _, cell in pairs(field.zoneData) do
            if cell.compaction and cell.compaction > 0 then
                cell.compaction = cell.compaction * ratio
            end
        end
    end
    field.compaction = newAvg
    return true
end

--- FieldSentry FR3 (#654): apply a one-shot, lightweight nutrient catch-up to a field's
--- average N/P/K. Used to reconcile a contract that harvested the field while FieldSentry
--- had it masked, so it does not sit frozen in stasis. Deliberately cheap - it only
--- touches the field-average scalars (no zone writes, no extraction model, no per-cell
--- work), so it never kicks off the heavy daily sim. FieldSentry computes the amounts
--- from its own static crop coefficients; this just applies and (in MP) broadcasts them.
---@param fieldId number
---@param dN number  nitrogen points to remove
---@param dP number  phosphorus points to remove
---@param dK number  potassium points to remove
---@return boolean applied
function SoilFertilitySystem:applyRetroactiveDrain(fieldId, dN, dP, dK)
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return false end

    local limits = SoilConstants.NUTRIENT_LIMITS
    local minV = (limits and limits.MIN) or 0
    field.nitrogen   = math.max(minV, (field.nitrogen   or 0) - (dN or 0))
    field.phosphorus = math.max(minV, (field.phosphorus or 0) - (dP or 0))
    field.potassium  = math.max(minV, (field.potassium  or 0) - (dK or 0))

    -- Mirror the harvest/fertilize sync path so clients see the reconciled values.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo
       and g_currentMission.missionDynamicInfo.isMultiplayer and SoilFieldUpdateEvent then
        g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
    end

    SoilLogger.debug("FieldSentry retro drain: field=%d  -N %.1f -P %.1f -K %.1f", fieldId, dN or 0, dP or 0, dK or 0)
    return true
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

    -- Reject cells outside the field polygon so headland turns / off-field driving
    -- don't inflate the cell count and auto-clear the trail before the field is done.
    local polyVerts = self:_getFieldPolyVerts(fieldId, field)
    if polyVerts and not _isPointInPoly((cx + 0.5) * zone.CELL_SIZE, (cz + 0.5) * zone.CELL_SIZE, polyVerts) then
        return
    end

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

    -- Reject cells outside the field polygon so headland turns / off-field driving
    -- don't inflate the cell count and auto-clear the trail before the field is done.
    local polyVerts = self:_getFieldPolyVerts(fieldId, field)
    if polyVerts and not _isPointInPoly((cx + 0.5) * zone.CELL_SIZE, (cz + 0.5) * zone.CELL_SIZE, polyVerts) then
        return
    end

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
