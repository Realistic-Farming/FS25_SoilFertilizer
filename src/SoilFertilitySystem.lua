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
SoilFertilitySystem = SoilFertilitySystem or {}
local SoilFertilitySystem_mt = Class(SoilFertilitySystem)

local COVERAGE_MILESTONES = { 0.10, 0.25, 0.50, 0.75, 1.0 }

-- CD-9: Mode of Action → FRAC group mapping for resistance tracking.
-- Physical fungicides only (generic FUNGICIDE has no MOA).
-- SULFUR and COPPER_HYDROXIDE are natural/bio (lower max resistance).
local MODE_FOR_FILLTYPE = {
    PROPICONAZOLE      = "3",   -- FRAC 3  (triazole)
    TEBUCONAZOLE       = "3",   -- FRAC 3  (triazole)
    AZOXYSTROBIN       = "11",  -- FRAC 11 (strobilurin)
    BOSCALID           = "7",   -- FRAC 7  (SDHI)
    MANCOZEB           = "M3",  -- FRAC M3 (dithiocarbamate)
    METALAXYL          = "4",   -- FRAC 4  (phenylamide)
    SULFUR             = "M2",  -- FRAC M2 (inorganic, natural)
    COPPER_HYDROXIDE   = "M1",  -- FRAC M1 (inorganic, natural)
}

-- Set of natural/bio fungicide names (lower max resistance).
local NATURAL_FUNGICIDE_NAMES = {
    SULFUR = true,
    COPPER_HYDROXIDE = true,
}

-- Resolve a 1-5 setting index to its TUNING LUT value.
-- Falls back to the index-3 value (the baseline) if the LUT is missing.
local function getTuningMult(settings, settingId, lutKey)
    local idx = (settings and settings[settingId]) or 3
    local lut = SoilConstants.TUNING and SoilConstants.TUNING[lutKey]
    if lut then return lut[idx] or lut[3] or 1.0 end
    return 1.0
end

--- Invalidate cached polygon vertices for a field when farmland ownership or
--- geometry may have changed (F61). Forces the next coverage calculation to
--- re-resolve from the live g_fieldManager rather than using stale cached data.
---@param field table   self.fieldData[fieldId]
local function invalidatePolyVerts(field)
    if field then
        field._polyVerts = nil
    end
end

-- SF-74: the spray-path sky read, in the MaterialWetness.lua:305-323 pattern.
-- WeatherGuard's handle is published on g_currentMission by main.lua; absent
-- means we do not know, and heat scorch HOLDS rather than inventing a day.
local function weatherGuard()
    return (g_currentMission ~= nil and g_currentMission.weatherGuard) or nil
end

--- Current temperature at spray time. nil means we do not know, and scorch
--- HOLDS rather than inventing one: no WeatherGuard is not a mild day.
local function readSprayTemperature()
    local wg = weatherGuard()
    if wg == nil or wg.getCurrentSky == nil then return nil end
    local ok, sky = pcall(function() return wg:getCurrentSky() end)
    if not ok or sky == nil then return nil end
    return sky.temperature   -- number or nil; nil propagates as NO SCORCH
end

-- CD-9: Lookup the FRAC group for a fungicide fill type name.
-- Returns nil for generic FUNGICIDE (no MOA assigned).
---@param fillTypeName string
---@return string|nil
function SoilFertilitySystem.getModeForFillType(fillTypeName)
    return MODE_FOR_FILLTYPE[fillTypeName]
end

-- CD-9: True when the fill type is a natural/bio fungicide (lower max resistance).
---@param fillTypeName string
---@return boolean
function SoilFertilitySystem.isNaturalFungicide(fillTypeName)
    return NATURAL_FUNGICIDE_NAMES[fillTypeName] == true
end

-- CD-11: THE RESISTANCE READ SURFACE. The whole contract a presentation build consumes.
--
-- Returns a SoilConstants.RESISTANCE.BANDS value for a field's mode of action, resolved
-- against whatever picture this machine has: the server and single player band their own
-- raw score, a client reads only what the server sent. A raw score never leaves the server
-- and no caller ever sees one.
--
-- ALWAYS returns a band, NEVER nil. Unscouted ground, an unsynced field, and an unknown
-- field id all return BANDS.UNKNOWN, which callers must treat as distinct from every real
-- band -- rendering it as WORKING would tell a player their fungicide is fine about ground
-- nobody has looked at.
---@param fieldId number
---@param mode string   FRAC group ("3", "11", "M2", ...) from getModeForFillType
---@return number       a SoilConstants.RESISTANCE.BANDS value
function SoilFertilitySystem:getResistanceBand(fieldId, mode)
    local field = self.fieldData and self.fieldData[fieldId]
    return ResistanceBands.getBand(field, mode)
end

-- CD-11 convenience: the band for a CHEMICAL rather than a mode, since a player picks a
-- jug off a shelf and not a FRAC group. Generic FUNGICIDE has no mode and reads UNKNOWN.
---@param fieldId number
---@param fillTypeName string   e.g. "PROPICONAZOLE"
---@return number
function SoilFertilitySystem:getResistanceBandForChemical(fieldId, fillTypeName)
    local mode = SoilFertilitySystem.getModeForFillType(fillTypeName)
    if not mode then return SoilConstants.RESISTANCE.BANDS.UNKNOWN end
    return self:getResistanceBand(fieldId, mode)
end

function SoilFertilitySystem.new(settings)
    local self = setmetatable({}, SoilFertilitySystem_mt)
    self.settings = settings
    self.fieldData = {}
    self.lastUpdate = 0
    self.updateInterval = SoilConstants.TIMING.UPDATE_INTERVAL
    self.isInitialized = false
    self.lastUpdateDay = 0
    -- Monotonic day of the last processed daily pass, for skipped-day catch-up.
    -- 0 means "not yet observed" so the first day-change never spuriously catches up.
    self.lastUpdateMonotonicDay = 0
    -- SF-76 FIELD GENESIS: when active, the starting soil profile is seeded
    -- FROM TERRAIN (height-relative, slope, sink proximity) instead of the
    -- smooth regional gradient. Set by the manager on a NEW save (no soilData
    -- yet), server-derived, deterministic from the savegame directory hash.
    -- Off by default: an existing save is untouched (zero writes).
    self.genesisActive = false
    self.genesisSeed   = 0
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
    -- REFINED: engine bit-vector value maps (~2 m/px, PF-style). Replaces the
    -- 10-40 m zoneData cell grid as the per-pixel truth for N/P/K/pH/OM/compaction.
    self.valueMaps    = SoilValueMaps    and SoilValueMaps.new()    or nil
    -- [SF-43] MATERIAL DOWN. Created here beside the store it rides on; armed only
    -- after the store initializes, because arming asserts its layer keys resolved.
    self.materialDown = MaterialDown     and MaterialDown.new()     or nil
    -- [SF-49] WHAT THE SKY DID. Rides the sibling's machinery; armed after it.
    self.materialWetness = MaterialWetness and MaterialWetness.new() or nil
    -- [SF-44] THE HAY BET. The settle-pass member that reads condition and
    -- applies grass-to-hay conversion (once the bounced confirm lands).
    self.hayBet = HayBet and HayBet.new() or nil
    -- [SF-46] THE YARD LADDER. Per-bale condition tracking on the shelter
    -- ladder, ending in condemnation.
    self.yardLadder = YardLadder and YardLadder.new() or nil
    -- [SF-26] SPATIAL SCOUTING. The walked mask: per-farm, per-field walked
    -- cells that reveal the trouble's pattern where the player walked, on foot.
    -- Armed after the value maps initialize; its own bridges register in
    -- loadedMission.
    self.spatialScouting = SpatialScouting and SpatialScouting.new() or nil

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

    -- Harvest event bus (cross-mod). External mods (the ecosystem diseased-food /
    -- feed model) register a listener via g_currentMission.soilHarvestBus and receive
    -- a payload at each harvest cut carrying the harvested fill type + liters AND the
    -- field's disease severity AT harvest. Disease is a growing-crop property that a
    -- plain harvest would otherwise drop at the combine, so we expose it here before it
    -- is gone. Keyed by name so a re-registering mod replaces its own listener.
    self.harvestListeners = {}

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

    -- REFINED: per-pixel value maps. Restores persisted sfSoilMap_*.grle files
    -- from the savegame when present; otherwise creates blank maps that get
    -- seeded from fieldData/zoneData after loadSoilData (see seedValueMaps).
    if self.valueMaps then
        local savegameDir = g_currentMission and g_currentMission.missionInfo
                            and g_currentMission.missionInfo.savegameDirectory
        self.valueMaps:initialize(savegameDir)
    end

    -- [SF-43] BIND-TIME SELF-CHECK. Must run AFTER every candidate has loaded and
    -- AFTER SoilValueMaps:initialize: the community fork declares the same
    -- SoilValueMaps global with byte-identical filenames and none of our defs, and
    -- every store method returns early SILENTLY on an unknown key. Without this the
    -- system would look healthy while recording nothing at all.
    --
    -- RELEASE GATE: the ground-material family (SF-43/44/46/49) is LOCKED. When it
    -- is not released, none of the four members arm, and every isArmed() check in the
    -- hooks, bridges and readers goes inert - the family is not wired at all, exactly
    -- as the release-gate design specifies. Arming is the single door.
    if self.materialDown and ReleaseGate.isSystemLive("ground_material") then
        self.materialDown:arm(self.valueMaps)
    end
    -- [SF-49] Armed after the sibling: it depends on that system being live, not
    -- merely present, and refuses to arm if it is not.
    if self.materialWetness and ReleaseGate.isSystemLive("ground_material") then
        self.materialWetness:arm(self.valueMaps, self.materialDown, self)
    end
    -- [SF-44] Armed after the condition layer: depends on both sibling systems.
    if self.hayBet and ReleaseGate.isSystemLive("ground_material") then
        self.hayBet:arm(self.materialDown, self.materialWetness)
    end
    -- [SF-46] Armed after HayBet; depends on all three sibling systems.
    if self.yardLadder and ReleaseGate.isSystemLive("ground_material") then
        self.yardLadder:arm(self.materialDown, self.materialWetness, self.hayBet)
    end
    -- [SF-26] Armed after the value maps; reads diseasePressure for the truth
    -- sample and writes it back for the display compose.
    -- RELEASE GATE: Read the Dirt (the walked mask + the kneel + the handful read)
    -- is LOCKED; when not released, spatialScouting never arms and the kneel/mask/
    -- handful all no-op through isArmed().
    if self.spatialScouting and ReleaseGate.isSystemLive("read_the_dirt") then
        self.spatialScouting:arm(self.valueMaps)
    end

    -- Scan fields using real FieldManager (now runs with layerSystem ready)
    if g_fieldManager then
        self:scanFields()
    else
        self:warning("FieldManager not available - will try delayed initialization")
    end

    -- Populate HERBICIDE_TYPES from the engine's spray-type registry so map-added
    -- herbicides (Roundup, atrazine, etc.) are recognized without a manual table entry.
    -- Explicit entries in HERBICIDE_TYPES take precedence (custom effectiveness values).
    self:populateHerbicideTypesFromSprayCategory()

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

function SoilFertilitySystem:populateHerbicideTypesFromSprayCategory()
    if not g_sprayTypeManager then return end
    local wp = SoilConstants.WEED_PRESSURE
    if not wp then return end
    if not wp.HERBICIDE_TYPES then wp.HERBICIDE_TYPES = {} end

    local added = 0
    for _, sprayType in ipairs(g_sprayTypeManager:getSprayTypes()) do
        if sprayType.isHerbicide and sprayType.fillType then
            local name = sprayType.fillType.name
            if name and wp.HERBICIDE_TYPES[name] == nil then
                wp.HERBICIDE_TYPES[name] = 1.0
                added = added + 1
                self:info("Herbicide '%s' recognized by spray-type category", name)
            end
        end
    end
    if added > 0 then
        self:info("Added %d herbicide(s) from spray-type categories", added)
    end
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
    if self.valueMaps then
        self.valueMaps:delete()
        self.valueMaps = nil
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
--- nutrient source; BOTH call sites pass FIELD-AVERAGE values, so OUR share of the
--- reduction is identical on the applied and displayed paths. The monitor then
--- additionally folds in SeasonalCropStress's upstream cut (SCS-002) before showing
--- a number, because that cut reaches the same grain without passing through here.
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

--- SCS-002 read: SeasonalCropStress's drought-stress yield keep-factor for a field.
---
--- SCS reduces yield on its OWN hook, UPSTREAM of ours: Cutter.processCutterArea
--- scales spec.workAreaParameters.lastMultiplierArea, which the combine later turns
--- into the fill delta our hopper hook modifies. The two therefore MULTIPLY, and a
--- forecast that reports only our own modifier overstates the grain the player
--- actually receives on any stressed field whenever SCS is installed.
---
--- DISPLAY USE ONLY. computeYieldModifier must never include this: SCS applies its
--- own cut itself, and HarvestContractUnderwrite divides out exactly the value the
--- hopper hook applied. Folding it into the applied path would double-charge the
--- player and break the contract top-up in the same stroke.
---
--- Pull-only, pcall-guarded, neutral when absent - mirrors the SCS-001 moisture read
--- in _applyRainLeaching. The function-type guard also keeps us neutral against an
--- OLDER SCS that predates the getter, so the two mods version-skew safely.
---@param fieldId number
---@return number keep  Multiplier in [0,1]; 1.0 when SCS contributes no reduction
function SoilFertilitySystem:_scsYieldKeepFactor(fieldId)
    local csMgr = g_currentMission and g_currentMission.cropStressManager
    if not csMgr or type(csMgr.getYieldKeepFactor) ~= "function" then return 1.0 end
    local ok, keep = pcall(csMgr.getYieldKeepFactor, csMgr, fieldId)
    if ok and type(keep) == "number" and keep >= 0.0 and keep <= 1.0 then return keep end
    return 1.0
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

    -- Single source of truth for OUR reduction: driven by FIELD-AVERAGE nutrients.
    -- getFieldInfo()'s monitor forecast calls this same helper with the same
    -- field-average values, so SF's own share of the cut is identical on both paths.
    -- The monitor additionally multiplies in SeasonalCropStress's keep-factor
    -- (SCS-002) - deliberately NOT done here, because SCS applies that cut itself
    -- upstream and HarvestContractUnderwrite inverts exactly what we return.
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

--- Register a harvest-event listener (cross-mod). `fn` is called at each harvest cut
--- with a single payload table (see _emitHarvest). Keyed by `name` so a mod replaces
--- its own listener on re-register rather than stacking duplicates.
---@param name string  unique listener id (usually the consuming mod name)
---@param fn function  callback(payload)
function SoilFertilitySystem:subscribeHarvest(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then return false end
    self.harvestListeners[name] = fn
    SoilLogger.info("Harvest bus: listener '%s' registered", name)
    return true
end

--- Remove a previously registered harvest-event listener.
---@param name string
function SoilFertilitySystem:unsubscribeHarvest(name)
    if self.harvestListeners[name] == nil then return false end
    self.harvestListeners[name] = nil
    SoilLogger.info("Harvest bus: listener '%s' removed", name)
    return true
end

--- Fire all harvest listeners with the harvested fill type + liters and the field's
--- disease state AT harvest. Called once per harvest cut (onHarvest is driven by
--- Combine.addCutterArea and fires many times per second), so `liters`/`area` are the
--- INCREMENTAL amount for this cut - a consumer accumulates them per field itself,
--- exactly as the internal nutrient path does. Each listener is pcall-guarded: a
--- misbehaving external listener must never crash the harvest path. No-op when no one
--- is listening, so the common case costs a single table lookup.
function SoilFertilitySystem:_emitHarvest(fieldId, fruitTypeIndex, liters, area)
    if next(self.harvestListeners) == nil then return end
    local field = self.fieldData[fieldId]
    local payload = {
        fieldId              = fieldId,
        fruitTypeIndex       = fruitTypeIndex,
        liters               = liters or 0,
        area                 = area or 0,
        -- Disease severity at harvest. diseasePressure (0-100 live) + activeDisease
        -- (named pathogen id) are the meaningful inputs for a contamination/mycotoxin
        -- model; activeDiseaseSeverity is a yield-penalty tier multiplier, included for
        -- completeness. All read-only snapshots of the field's state this frame.
        diseasePressure      = field and field.diseasePressure or 0,
        activeDisease        = field and field.activeDisease or nil,
        activeDiseaseSeverity = field and field.activeDiseaseSeverity or 1.0,
    }
    for name, fn in pairs(self.harvestListeners) do
        local ok, err = pcall(fn, payload)
        if not ok then
            SoilLogger.warning("Harvest bus: listener '%s' errored: %s", tostring(name), tostring(err))
        end
    end
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

    -- Cross-mod harvest bus: emit BEFORE any harvest-time disease reset so the field's
    -- disease severity at harvest is still reachable (the ecosystem diseased-food model
    -- needs harvested liters + severity per field/fill type). No-op if nothing listens.
    self:_emitHarvest(fieldId, fruitTypeIndex, liters, area)

    -- Reset session spray coverage so the next fertilizing pass starts fresh
    local harvestField = self.fieldData[fieldId]
    if harvestField then
        harvestField.sessionCoverageHa       = 0
        harvestField.sessionCoverageFraction = 0
        harvestField.sessionCoverageCells    = {}
        harvestField.sessionLastProduct      = nil
        harvestField._geometricCoverageOwner = nil  -- #753
        harvestField._farmlandAreaConfirmed  = nil  -- re-confirm on next session's first spray (#507)

        -- #738 no-till OM: the crop is off the field. Fresh, untouched residue now covers
        -- bare ground, so reset the tillage-since-harvest tracker and end the no-till
        -- credit - fallow recovery governs OM until the next crop is sown/drilled.
        harvestField.tilledSinceHarvest = false
        harvestField.noTillActive       = false
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

    local diffMult = self.settings:getDepletionMultiplier()
    local haFactor = SoilConstants.MOWER_HA_FACTOR or 6.0
    local fieldAreaHa = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0

    -- Per-day area cap (same rationale as onPlowing/onCultivation/onMulching): total
    -- depletion from mowing cannot exceed one full-field-equivalent per day regardless of
    -- pass count. Grass on a permanent meadow extends past the registered field polygon and
    -- the header overlaps heavily, so without this clamp a single mowing session over-counts
    -- the worked area several times over and floors N/P/K in one go (#730, #706). The mower
    -- hook already feeds actually-cut area (lastChangedArea), so this cap is the backstop.
    local today = (g_currentMission and g_currentMission.environment and
                   g_currentMission.environment.currentDay) or 0
    if not self._mowAreaToday then self._mowAreaToday = {} end
    local entry = self._mowAreaToday[fieldId]
    if not entry or entry.day ~= today then
        entry = { day = today, used = 0 }
        self._mowAreaToday[fieldId] = entry
    end
    local clampedArea = math.min(areaHa, math.max(0, fieldAreaHa - entry.used))
    if clampedArea <= 0 then return end
    entry.used = entry.used + clampedArea

    local factor   = (clampedArea / fieldAreaHa) * haFactor * diffMult

    local limits = SoilConstants.NUTRIENT_LIMITS
    field.nitrogen   = math.max(limits.MIN, field.nitrogen   - rates.N * factor)
    field.phosphorus = math.max(limits.MIN, field.phosphorus - rates.P * factor)
    field.potassium  = math.max(limits.MIN, field.potassium  - rates.K * factor)

    field.lastCrop    = fruitDesc.name
    field.lastHarvest = (g_currentMission and g_currentMission.environment
                         and g_currentMission.environment.currentDay) or 0

    SoilLogger.debug("Mow: Field %d, %s, %.5f ha (cut %.5f, day-used %.3f/%.2f) - N:%.1f P:%.1f K:%.1f",
        fieldId, fruitDesc.name, clampedArea, areaHa, entry.used, fieldAreaHa,
        field.nitrogen, field.phosphorus, field.potassium)

    -- Broadcast field update to clients in multiplayer (throttled - mower fires every tick)
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo
        and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            local now = g_currentMission.time or 0
            if not self._tillBroadcastTime then self._tillBroadcastTime = {} end
            local last = self._tillBroadcastTime[fieldId] or 0
            if (now - last) >= 5000 then
                self._tillBroadcastTime[fieldId] = now
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

    -- Organic certification compliance: a synthetic (non-approved) input on a
    -- transitioning or certified field is a breach (full reset to conventional).
    if g_SoilFertilityManager and g_SoilFertilityManager.organic and fillType then
        g_SoilFertilityManager.organic:onInputApplied(fieldId, fillType.name)
    end

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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
        -- Field sold / abandoned - pull it out of the active simulation set,
        -- UNLESS it is NPC-managed ground (the designation keeps it active; the
        -- symmetric leave only fires on a designation lapse, never on a farm
        -- release while an NPC works it). fieldData intentionally kept.
        if NpcSoilBridge and NpcSoilBridge:isNPCManaged(fieldId) == true then
            SoilLogger.debug("[PERF-P1] Field %d released by farm but NPC-managed - stays active", fieldId)
            return
        end
        self:_removeFromActiveSet(fieldId)
        -- Clear GRLE so unmasked DMV no longer colours this unowned field.
        if self.layerSystem and self.layerSystem.available then
            self.layerSystem:clearFieldFromLayers(fieldId, nil)
        end
        SoilLogger.debug("[PERF-P1] Field %d released by farm - removed from active set (data preserved)", fieldId)
        return
    end

    -- F61: invalidate cached poly verts so coverage re-resolves the polygon at next use
    local field = self:getOrCreateField(fieldId, true)
    if field then
        invalidatePolyVerts(field)
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
---@param cropBiomass number|nil  Crop biomass factor 0..1 if a standing/dead cover crop was drilled in (#778)
-- SF-57: the seedbed ground-type weight captured once at the last sowing
-- position. GROUND_TYPE is read through the base game's density map util (the
-- third return of getFieldDataAtWorldPosition), banded into the SEEDBED_WEIGHT
-- table (plowed/seedbed resists, cultivated normal, stubble tillage eases).
-- A nil read or an unknown band degrades to the neutral 1.0.

-- The drilling-window advisory (the field-info line): whether the coming days
-- are a good or risky window for putting seed in this ground. It speaks from the
-- SCS sky-reading (clouds now, rain now, the season's habits) and the ground
-- moisture against the establishment kill condition. Advice never gates or
-- writes; it is silent when SCS is absent (never guessing), and the weaker
-- forecast-only form is used when the moisture read is unavailable. The verdict
-- is a stable l10n key.
function SoilFertilitySystem:_drillingAdvisory(fieldId)
    local cs = g_currentMission ~= nil and g_currentMission.cropStressManager
    if cs == nil or cs.getRainOutlook == nil then return nil end
    local d = SoilConstants.DRILLING
    local horizon = SoilDuration.seasonScaled(d.ESTABLISHMENT_HORIZON_DAYS)
    local ok, out = pcall(function() return cs:getRainOutlook(horizon) end)
    if not ok or out == nil or type(out.likelihood) ~= "number" then return nil end
    local moist, hasMoisture = 0.5, false
    if cs.getMoisture ~= nil then
        local ok2, m = pcall(function() return cs:getMoisture(fieldId) end)
        if ok2 and type(m) == "number" then moist, hasMoisture = m, true end
    end
    if out.likelihood < d.RISKY_LIKELIHOOD then
        return "sf_notify_drill_good"
    end
    if hasMoisture and moist >= d.WET_GROUND_MOISTURE then
        return "sf_notify_drill_risky"
    end
    return "sf_notify_drill_forecast_only"
end
function SoilFertilitySystem:_seedbedWeightAtLastSow()
    local x = self._lastTillageX
    local z = self._lastTillageZ
    if x == nil or z == nil then return 1.0 end
    local groundType = nil
    pcall(function()
        local _, _, gt = FSDensityMapUtil.getFieldDataAtWorldPosition(x, 0, z)
        groundType = gt
    end)
    if groundType == nil then return 1.0 end
    local w = EstablishmentFailure.SEEDBED_WEIGHT[groundType]
    if w == nil then
        -- The enum value may be a number; map back through the weight table by
        -- matching the name from the util's lookup when available.
        return 1.0
    end
    return w
end

function SoilFertilitySystem:onSowing(fieldId, area, seedsFruitType, cropBiomass)
    if not fieldId or fieldId <= 0 then return end
    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- SF-18: opening (or extending) the establishment window. Every sowing pass
    -- extends, making re-drilling and multi-day drilling the same case.
    -- SF-57: the seedbed ground-type weight is read once at the sowing position
    -- (a fact about how the seed went in, never resampled during the window).
    if g_SoilFertilityManager and g_SoilFertilityManager.establishment then
        local seedbedWeight = self:_seedbedWeightAtLastSow()
        g_SoilFertilityManager.establishment:onSowing(fieldId, seedbedWeight)
    end

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

    -- #738 no-till OM: a crop drilled into UNTILLED residue (no plough/cultivator/strip
    -- pass since the last harvest) is a no-till crop and accrues the daily OM credit while
    -- it grows. A crop sown after any tillage pass is conventional (tilledSinceHarvest set
    -- by those hooks, cleared at harvest). This is the agronomic definition of no-till -
    -- you drill instead of tilling - so it needs no implement-type detection.
    field.noTillActive = not field.tilledSinceHarvest

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

    -- CD-9: new crop planted → 50% resistance decay (partial reset).
    -- Resistance never fully resets on planting; the half-life means a resistant
    -- field stays somewhat resistant going into the new season.
    if field.resistance then
        for mode, val in pairs(field.resistance) do
            field.resistance[mode] = val * 0.5
            if field.resistance[mode] < 0.01 then field.resistance[mode] = 0 end
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

        -- REFINED: local per-pixel bump at the seeder position on the value maps
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            local cellFactor = areaHa / zone.CELL_AREA_HA
            self:vmLocalBump(tx, tz, {
                nitrogen      = ri.N  * cellFactor,
                phosphorus    = ri.P  * cellFactor,
                potassium     = ri.K  * cellFactor,
                organicMatter = ri.OM * cellFactor,
            }, zone.CELL_SIZE * 0.5)

            -- Weed reduction per zone cell (pressures stay on the coarse grid)
            if self.settings.weedPressure then
                local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
                if not field.zoneData then field.zoneData = {} end
                local cell = field.zoneData[cellKey]
                if cell and cell.weedPressure then
                    cell.weedPressure = math.max(0, cell.weedPressure - (cell.weedPressure * cellFactor))
                end
            end
        end
    end

    -- #778: green-manure incorporation by direct drill. A seeder that drills through a standing
    -- or dead cover crop (over-wintered oilseed radish, failed crop, sod) works its biomass into
    -- the opener slot - no inversion, so a smaller boost than mulching. Awarded ONLY when the
    -- crop-biomass probe actually detected a standing crop (biomass > 0).
    if self.settings.residueIncorporation and cropBiomass and cropBiomass > 0
       and SoilConstants.CROP_INCORPORATION and SoilConstants.CROP_INCORPORATION.SOWING then
        if self:_applyCropIncorporation(fieldId, field, SoilConstants.CROP_INCORPORATION.SOWING,
                                        cropBiomass, factor, areaHa) then
            changed = true
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
    field._geometricCoverageOwner = nil  -- #753: re-detect geometric path each session
    field.sprayTrailPts           = nil
    field._zoneBaseline           = nil   -- #735: re-snapshot the pre-spray baseline next session
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

    -- REFINED: local per-pixel bump at the tillage position on the value maps
    local tx, tz = self._lastTillageX, self._lastTillageZ
    if tx and tz then
        local zone = SoilConstants.ZONE
        local cellScale = ((areaHa or 0) / zone.CELL_AREA_HA) * biomass
        self:vmLocalBump(tx, tz, {
            organicMatter = profile.OM * cellScale,
            nitrogen      = profile.N  * cellScale,
            phosphorus    = profile.P  * cellScale,
            potassium     = profile.K  * cellScale,
        }, zone.CELL_SIZE * 0.5)
    end

    SoilLogger.debug("Crop incorporation field %d: +OM%.3f +N%.3f (biomass=%.2f factor=%.4f)",
        fieldId or -1, profile.OM * scale, profile.N * scale, biomass, factor)
    return true
end

--- #738 no-till OM: apply a tillage pass's organic-matter OXIDATION loss (deep
--- disturbance aerating buried humus). Shared by the plough/cultivator/strip-till
--- hooks with each type's own gradient value. Reduces the field-average OM (floored
--- at DECAY_FLOOR), and mirrors the loss positionally onto the OM value map at the
--- pass location - the same scalar-uses-`factor`, VM-uses-`cellFactor` split the
--- residue-incorporation writes use, degrading to scalar-only when no value map is
--- present. Returns true if the field OM changed.
---@param field table The field data table
---@param oxid number OM lost per full pass (OM_DYNAMICS.OXIDATION.*)
---@param factor number Field-fraction processed this tick (areaHa / fieldAreaHa)
---@param areaHa number Area processed this tick, for the per-cell VM intensity
---@return boolean changed
function SoilFertilitySystem:_applyTillageOxidation(field, oxid, factor, areaHa)
    if not oxid or oxid <= 0 or not field then return false end
    local omDyn  = SoilConstants.OM_DYNAMICS
    local floor  = (omDyn and omDyn.DECAY_FLOOR) or SoilConstants.NUTRIENT_LIMITS.MIN
    local before = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
    local after  = math.max(floor, before - oxid * factor)
    if after >= before then return false end
    field.organicMatter = after
    -- Positional loss on the OM value map (crop-incorporation precedent).
    local tx, tz = self._lastTillageX, self._lastTillageZ
    if tx and tz then
        local zone = SoilConstants.ZONE
        local cellFactor = areaHa / zone.CELL_AREA_HA
        self:vmLocalBump(tx, tz, { organicMatter = -(oxid * cellFactor) }, zone.CELL_SIZE * 0.5)
    end
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

    -- #738: this field has now been TILLED since the last harvest, so the next crop sown
    -- into it is conventional, not no-till. Any crop currently growing is destroyed by the
    -- pass, so its no-till credit ends here too.
    field.tilledSinceHarvest = true
    field.noTillActive       = false

    -- Plowing effects 1 & 2: OM oxidation loss and pH normalization (only if plowingBonus enabled)
    if self.settings.plowingBonus then
        -- Deep inversion exposes buried humus to air, oxidising it - plowing COSTS organic
        -- matter rather than adding it (#695, reversed from the old +0.5/pass bonus). Residue
        -- incorporation below (gated separately) can offset this when straw/green matter is
        -- actually worked in, so a residue-rich plow can still net positive.
        -- #738: plough oxidation via the shared per-tillage gradient (positional VM
        -- write + floored scalar). Steepest of the gradient - deep inversion burns the
        -- most buried humus, so a residue-poor plough nets slightly negative on OM.
        local omDyn = SoilConstants.OM_DYNAMICS
        if self:_applyTillageOxidation(field, omDyn and omDyn.OXIDATION and omDyn.OXIDATION.PLOW, factor, areaHa) then
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

        -- REFINED: local per-pixel bump at the plow position on the value maps;
        -- pressure reductions stay on the coarse zone grid.
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            -- Cell-factor: area processed in THIS tick relative to one cell area (usually 0.01 ha)
            local cellFactor = areaHa / zone.CELL_AREA_HA
            self:vmLocalBump(tx, tz, {
                nitrogen      = ri.N  * cellFactor,
                phosphorus    = ri.P  * cellFactor,
                potassium     = ri.K  * cellFactor,
                organicMatter = ri.OM * cellFactor,
            }, zone.CELL_SIZE * 0.5)

            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

    -- #738: a cultivator pass counts as tillage - the next sown crop is conventional,
    -- and any growing crop's no-till credit ends here.
    field.tilledSinceHarvest = true
    field.noTillActive       = false

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

        -- #738: cultivator oxidation (topsoil mixing aerates humus). Netted against the
        -- residue gain above, cultivation still adds OM but less than strip-till/no-till.
        local omDyn = SoilConstants.OM_DYNAMICS
        if self:_applyTillageOxidation(field, omDyn and omDyn.OXIDATION and omDyn.OXIDATION.CULTIVATOR, factor, areaHa) then
            changed = true
        end

        -- REFINED: local per-pixel bump at the cultivator position on the value
        -- maps; pressure reductions stay on the coarse zone grid.
        local tx, tz = self._lastTillageX, self._lastTillageZ
        if tx and tz then
            local zone = SoilConstants.ZONE
            local cellFactor = areaHa / zone.CELL_AREA_HA
            self:vmLocalBump(tx, tz, {
                nitrogen      = ri.N  * cellFactor,
                phosphorus    = ri.P  * cellFactor,
                potassium     = ri.K  * cellFactor,
                organicMatter = ri.OM * cellFactor,
            }, zone.CELL_SIZE * 0.5)

            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

    -- #738: strip-till is a (reduced) tillage pass. A crop drilled after it takes the
    -- strip-till residue profile, not the no-till daily credit, so mark the field tilled.
    field.tilledSinceHarvest = true
    field.noTillActive       = false

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

    -- Residue incorporation: strip-till knifes work only tilled strips (~30% of surface),
    -- so residue nutrient release is the smallest of all tillage types.
    if self.settings.residueIncorporation and SoilConstants.RESIDUE_INCORPORATION then
        local ri     = SoilConstants.RESIDUE_INCORPORATION.STRIP_TILL
        local limits = SoilConstants.NUTRIENT_LIMITS

        -- #738: strip-till residue OM now lands on the field average too (previously only
        -- the VM got it, while the retired OM_BOOST carried the scalar). One gain term.
        local omBefore = field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
        local omAfter  = math.min(limits.ORGANIC_MATTER_MAX, omBefore + (ri.OM * factor))
        if omAfter > omBefore then
            field.organicMatter = omAfter
            changed = true
        end

        -- #738: strip-till oxidation (lightest of the tilling types - only narrow knife
        -- bands are disturbed). Netted with the residue gain, strip-till nets clearly
        -- positive, second only to no-till on the season OM trajectory.
        local omDyn = SoilConstants.OM_DYNAMICS
        if self:_applyTillageOxidation(field, omDyn and omDyn.OXIDATION and omDyn.OXIDATION.STRIP_TILL, factor, areaHa) then
            changed = true
        end

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
            local cellFactor = areaHa / zone.CELL_AREA_HA
            -- REFINED: local per-pixel bump at the strip-till position
            self:vmLocalBump(tx, tz, {
                nitrogen      = ri.N  * cellFactor,
                phosphorus    = ri.P  * cellFactor,
                potassium     = ri.K  * cellFactor,
                organicMatter = ri.OM * cellFactor,
            }, zone.CELL_SIZE * 0.5)

            local cellKey = tostring(math.floor(tx / zone.CELL_SIZE) * 10000 + math.floor(tz / zone.CELL_SIZE))
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                field.zoneData[cellKey] = {
                    weedPressure = field.weedPressure, pestPressure = field.pestPressure,
                    diseasePressure = field.diseasePressure, compaction = field.compaction
                }
            end
            local cell = field.zoneData[cellKey]
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
            -- REFINED: mirror the tilled strip onto the per-pixel pressure maps
            if self:vmAvailable() then
                local halfCell = zone.CELL_SIZE * 0.5
                if self.settings.weedPressure then
                    self.valueMaps:writeValueAtWorld("weedPressure", tx, tz, cell.weedPressure, halfCell)
                end
                if self.settings.pestPressure then
                    self.valueMaps:writeValueAtWorld("pestPressure", tx, tz, cell.pestPressure, halfCell)
                end
                if self.settings.diseasePressure then
                    self.valueMaps:writeValueAtWorld("diseasePressure", tx, tz, cell.diseasePressure, halfCell)
                end
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
    field.herbicideDaysLeft = SoilDuration.seasonScaled(wp.HERBICIDE_DURATION_DAYS)

    self:log("[Herbicide] Field %d: weed pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.weedPressure, field.herbicideDaysLeft)

    -- Transition weeds to withered (brown) visual state in the game's density map.
    -- The game's FieldState.weedFactor stays high until the density map is updated, so
    -- we drive it ourselves: withered now so weeds turn brown, cleared on next daily tick.
    self:applyWeedMapState(fieldId, SoilConstants.WEED_PRESSURE.WEED_STATE_WITHERED)

    -- Broadcast in multiplayer
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
        field.insecticideDaysLeft = SoilDuration.seasonScaled(pp.INSECTICIDE_DURATION_DAYS)
    end

    self:log("[Insecticide] Field %d: pest pressure %.0f -> %.0f, protected for %d days",
        fieldId, before, field.pestPressure, field.insecticideDaysLeft)

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
        field.fungicideDaysLeft = math.floor(SoilDuration.seasonScaled(dp.FUNGICIDE_DURATION_DAYS) * cm.fungicideMult)
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
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

--- Monotonic day counter for ARITHMETIC (elapsed-day math). Unlike currentDay,
--- which wraps within a season and is only safe for change-detection,
--- currentMonotonicDay increases forever, so (now - last) is the true number of
--- days that passed - the value a skipped-day catch-up needs. Falls back to
--- currentDay when the field is unavailable.
function SoilFertilitySystem:_currentMonotonicDay()
    local env = g_currentMission and g_currentMission.environment
    if env then
        return env.currentMonotonicDay or env.currentDay or 0
    end
    return 0
end

--- Current season index (1=Spring 2=Summer 3=Fall 4=Winter), or nil if unavailable.
--- The shipped FS25 engine returns currentSeason 1-4 (spring=1); this is the same value
--- SeasonalCropStress reads and normalizes DOWN to its 0-based tables (WeatherIntegration
--- subtracts 1 when in [1,4]). CLIMATE_PRECIP is likewise 1-indexed, so the raw value
--- indexes it directly - NO offset (verified against SCS + SF's own shipped season use;
--- this is the #740 build-gate "season-index catch", discharged). The 0-based fallback
--- below only guards a hypothetical build that returns spring=0, so the climate can never
--- land a season off or nil-index the table.
---@return number|nil
function SoilFertilitySystem:_currentSeason()
    local raw = g_currentMission and g_currentMission.environment
                and g_currentMission.environment.currentSeason
    if raw == nil then return nil end
    if raw >= 1 and raw <= 4 then return raw end   -- shipped engine: 1-indexed (spring=1)
    if raw == 0 then return 1 end                  -- fallback: a 0-based build's spring
    return nil
end

--- #740: the rain scale SF's soil math should use. Real weather is ALWAYS primary. On a
--- short month the compressed calendar oversamples the sky as dry, which starves the
--- rain-driven modifiers (leaching, disease wet/dry, pest); the fill supplies the rain the
--- calendar skipped, at the season's climate, ONLY as the month shortens, and never on a
--- real rain day. weatherSource: 1 = opt-out (pure real weather, no fill); 2/3/4 = the
--- climate bias (Arid/Normal/Wet) the fill uses. Sets self._rainWasFilled so applyRainEffects
--- can apply the per-day precedence (a filled day is SF-supplied precipitation, so SCS's
--- rain-reflecting moisture is not double-counted). Deterministic per day => MP-consistent.
---@return number rainScale  (>= 0; > RAIN.MIN_RAIN_THRESHOLD counts as raining)
function SoilFertilitySystem:getEffectiveRainScale()
    -- Real weather (RealisticWeather-shaped when present) is primary and unchanged.
    local env = g_currentMission and g_currentMission.environment
    local real = 0
    if env and env.weather and env.weather.getRainFallScale then
        real = env.weather:getRainFallScale() or 0
    end

    local src = (self.settings and self.settings.weatherSource) or 1
    if src == 1 then
        -- Opt-out: pure real weather, no month-length fill at any calendar length.
        self._rainWasFilled = false
        return real
    end

    if real > SoilConstants.RAIN.MIN_RAIN_THRESHOLD then
        -- Real rain day: primary, never overridden. The fill only tops up dry days.
        self._rainWasFilled = false
        return real
    end

    -- Dry real day: engage the fill only as the month shortens.
    local dpm = (env and env.daysPerPeriod) or 1
    local w = self:_fillWeight(dpm)
    if w <= 0 then
        -- At/above the sampling reference the fill is off => byte-identical to real (0).
        self._rainWasFilled = false
        return 0
    end

    -- w gates ENGAGEMENT frequency (how often a dry day is filled toward the season
    -- shortfall), never intensity: a filled-wet day returns the FULL season intensity.
    local filled = self:_syntheticRainScale(src, w)
    self._rainWasFilled = (filled > SoilConstants.RAIN.MIN_RAIN_THRESHOLD)
    return filled
end

--- #740 month-length engagement weight for the short-month fill. 0 at/above the sampling
--- reference (weather samples adequately), rising to 1 as the month shortens.
--- w = clamp((REF - dpm) / (REF - 1), 0, 1) ^ EXP. See SoilConstants.SHORT_MONTH_FILL.
---@param daysPerMonth number  the calendar's days-per-period (days per in-game month)
---@return number w  engagement weight in [0, 1]
function SoilFertilitySystem:_fillWeight(daysPerMonth)
    local fill = SoilConstants.SHORT_MONTH_FILL
    local ref = (fill and fill.SAMPLING_REFERENCE) or 15
    local exp = (fill and fill.ENGAGEMENT_EXPONENT) or 2.5
    if not daysPerMonth or daysPerMonth >= ref then return 0 end
    local t = (ref - daysPerMonth) / (ref - 1)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t ^ exp
end

--- Synthetic per-day fill rain for a climate bias (#740). A seeded per-day roll against the
--- season's rain-day fraction (scaled by the engagement weight w) decides wet vs dry; a wet
--- day returns the climate's intensity, a dry day returns 0. Scaling the probability by w
--- makes the filled wet-day fraction track the season climate (shortfall-targeting: real is
--- ~0 on short months, so w*P approaches the season target as the month shrinks, and stays
--- small on longer months where w is small, so no over-fill). The roll is a fract(sin(day))
--- hash (NOT an affine LCG - see the per-field hash pitfall), keyed on the monotonic day so
--- the whole map shares a day's weather and it is stable across a save/reload on the same day.
---@param src number  climate bias (2=Arid, 3=Normal, 4=Wet)
---@param w number     engagement weight in [0, 1] (nil => 1, the full climate)
---@return number rainScale
function SoilFertilitySystem:_syntheticRainScale(src, w)
    local preset = SoilConstants.CLIMATE_PRECIP and SoilConstants.CLIMATE_PRECIP[src]
    if not preset then return 0 end
    local season = self:_currentSeason() or 2   -- default to summer if the env is unavailable
    local baseProb = (preset.PROB and preset.PROB[season]) or 0
    if baseProb <= 0 then return 0 end
    local prob = baseProb * (w or 1)
    if prob <= 0 then return 0 end
    local env = g_currentMission and g_currentMission.environment
    local day = (env and (env.currentMonotonicDay or env.currentDay)) or 0
    local s    = math.sin(day * 12.9898 + 78.233) * 43758.5453
    local roll = s - math.floor(s)   -- fractional part in [0, 1)
    if roll < prob then
        return preset.INTENSITY or 0.6   -- filled-wet day: full climate intensity
    end
    return 0   -- dry day
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
    -- #740: real in-game rain, topped up by the short-month climate fill on dry days.
    local rs = self:getEffectiveRainScale()
    local isWet = rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD
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
        -- CD-10: if what cleared was a HYBRID, arm the re-onset cooldown so the field cannot
        -- immediately breed another from the same still-burned modes.
        if HybridStrains.isHybrid(field.activeDisease) then
            local daysPerMonth = (g_currentMission and g_currentMission.environment
                                  and g_currentMission.environment.daysPerPeriod) or 1
            HybridStrains.beginCooldown(field, currentDay, daysPerMonth)
        end
        field.activeDisease = nil
        field.activeDiseaseSeverity = 1.0
        return
    end

    if not field.activeDisease and pressure >= onset then
        -- CD-10 PRE-PASS, ahead of the normal roll and short-circuiting it on a hit.
        -- Runs AFTER this day's resistance decay (both live in _processOneDailyField, decay
        -- first), so a mode that decayed below threshold today reads as ineligible today.
        -- A hybrid is never reachable through selectDisease's weighted roll -- it is not in
        -- DISEASE_REGISTRY or any per-crop candidate list -- so this is its only door.
        -- RELEASE GATE: the hybrid family (CD-10) is LOCKED; when not released, the pre-pass
        -- never runs and a normal disease is rolled instead.
        if ReleaseGate.isSystemLive("cd10_hybrids") then
            local hybridId = HybridStrains.selectOnset(field, currentDay)
            if hybridId then
                field.activeDisease = hybridId
                field.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(hybridId)
                field.diseaseDiscovered = false  -- as unknown as any fresh infection until scouted
                return
            end
        end

        local _, isCool = self:_diseaseClimateNow(season)
        local seed = fieldId * 1000 + (currentDay or 0)
        local picked = SoilDiseaseSystem.selectDisease(field.lastCrop, season, isRaining, isCool, seed)
        if picked then
            field.activeDisease = picked
            field.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(picked)
            field.diseaseDiscovered = false  -- a fresh infection is unknown until scouted
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

    -- Discovery gate: a NAMED active infection stays UNKNOWN in the report until the
    -- field has been deliberately scouted (scoutField) or revealed by a future dog /
    -- ProStaff report. This is the single source of truth for the whole disease-intel
    -- economy - every consumer (scout menu, console, FarmTablet) inherits the gate from
    -- here. Pure read: it NEVER sets discovered itself, so merely viewing can't reveal.
    -- A field with no named infection is not gated (nothing to discover).
    if field.activeDisease and not field.diseaseDiscovered then
        return {
            fieldId = fieldId,
            enabled = true,
            discovered = false,
            crop = field.lastCrop,
            fungicideActive = (field.fungicideDaysLeft or 0) > 0,
            fungicideDaysLeft = field.fungicideDaysLeft or 0,
        }
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
        discovered = true,
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

--- Deliberately scout a field: reveal its disease so getScoutReport returns the full
--- truth from here on. The free bottom rung of the disease-intel economy - the player
--- scouts each field one at a time (or buys a ProStaff report / gets a dog ping) to learn
--- what is on it. A fresh infection re-hides (onset resets diseaseDiscovered), so a new
--- outbreak must be re-scouted. Server-authoritative in MP: a client marks it locally
--- (optimistic - discovery is monotonic) and asks the server to make it authoritative and
--- sync it farm-wide via the field-update broadcast.
---@param fieldId number
---@return table|nil report  the now-revealed scout report
function SoilFertilitySystem:scoutField(fieldId)
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return self:getScoutReport(fieldId) end

    if not field.diseaseDiscovered then
        field.diseaseDiscovered = true
        if g_currentMission and g_currentMission.missionDynamicInfo
           and g_currentMission.missionDynamicInfo.isMultiplayer then
            if not g_server then
                if SoilScoutFieldEvent then
                    g_client:getServerConnection():sendEvent(SoilScoutFieldEvent.new(fieldId))
                end
            elseif SoilFieldUpdateEvent then
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
            end
        end
    end
    return self:getScoutReport(fieldId)
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
        fungicideEffMult = self.settings:getFungicideEffMultiplier(),
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
    -- [SF-27] B4 attribution: an NPC-attributed treatment never moves the player's
    -- money. Fail-closed: UNKNOWN attribution (designated or uncertain) skips the
    -- charge entirely. The explicit opts.charge=false path is the NPC-treatment
    -- build's own; this predicate is the safety net for the player-facing path.
    local cost = 0
    local npcAttributed = NpcSoilBridge and NpcSoilBridge:isNPCAttributed(fieldId) == true
    if opts.charge ~= false and not npcAttributed and self.settings.fertilizerCosts and g_server then
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
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
    -- Forced test disease starts unknown on purpose: SoilSetDisease leaves it GATED so the
    -- discovery gate is testable (the Soil Monitor shows "?"), then SoilScout reveals it.
    field.diseaseDiscovered = false

    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent then
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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
        -- Skipped-day catch-up: currentDay only proves a NEW day, not how many
        -- passed (it wraps within a season), so a sleep or time-skip across
        -- several days used to collapse into a single daily pass and silently
        -- drop the missing days' soil changes. The monotonic day gives the true
        -- gap. Clamped so a huge jump (or a pre-tracking save whose monotonic day
        -- has not been observed yet) can never stall the frame; the first
        -- observation is always treated as one day.
        local monoDay = self:_currentMonotonicDay()
        local elapsed = 1
        if self.lastUpdateMonotonicDay > 0 and monoDay > self.lastUpdateMonotonicDay then
            elapsed = monoDay - self.lastUpdateMonotonicDay
            local maxCatchup = (SoilConstants.TIMING and SoilConstants.TIMING.MAX_DAILY_CATCHUP) or 10
            if elapsed > maxCatchup then elapsed = maxCatchup end
        end
        self.lastUpdateMonotonicDay = monoDay
        self:updateDailySoil(elapsed)
        -- Advance organic transitions (uses the monotonic day internally).
        if g_SoilFertilityManager and g_SoilFertilityManager.organic then
            g_SoilFertilityManager.organic:onDayChanged()
        end
    end

    -- Rain effects (+ SCS-001 irrigation-driven leaching)
    -- #740: getEffectiveRainScale is the real weather, topped up by the short-month climate
    -- fill on dry days (and it sets self._rainWasFilled for applyRainEffects' per-day
    -- precedence); rainEffects stays the master on/off. Skipped-day catch-up replays the
    -- landing day's fill roll (per-day deterministic hash, scaled by elapsed) - no worse
    -- than the real-weather replay, and no new persisted state (CC-D, simple option).
    if self.settings.rainEffects then
        local rainScale = self:getEffectiveRainScale()
        if rainScale and rainScale > SoilConstants.RAIN.MIN_RAIN_THRESHOLD then
            -- Raining: per-frame leach (existing cadence), now moisture-aware per field.
            self:applyRainEffects(dt, rainScale)
            self._irrigLeachAccumMs = 0
        elseif g_currentMission and g_currentMission.cropStressManager then
            -- No rain, but SeasonalCropStress is loaded: irrigation can still leach a
            -- pivot-watered field. Throttled (accumulate dt, fire every interval) so this
            -- never becomes a permanent per-frame full-field loop. Zero cost when SCS absent.
            self._irrigLeachAccumMs = (self._irrigLeachAccumMs or 0) + dt
            if self._irrigLeachAccumMs >= SoilConstants.RAIN.IRRIGATION_LEACH_INTERVAL_MS then
                local accumDt = self._irrigLeachAccumMs
                self._irrigLeachAccumMs = 0
                self:applyRainEffects(accumDt, 0)  -- rainScale 0; per-field SCS moisture drives it
            end
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

    -- [SF-26] SPATIAL SCOUTING: server-side on-foot sampling. Cheap: iterates the
    -- authoritative player list and only records a NEW cell on a field. The walk
    -- only reveals for the farm the server's player record says the player owns.
    if self.spatialScouting then
        local day = g_currentMission and g_currentMission.environment
            and g_currentMission.environment.currentDay
        if day then
            self.spatialScouting:onUpdate(day)
        end
    end

    -- [SF-18] ESTABLISHMENT FAILURE: daily cadence pump. When Time Guard is
    -- present its accrual drives the sweep; this call continues a pending
    -- frame-budgeted sweep and, absent Time Guard, starts the daily sweep on a
    -- day boundary (SF's own day tracking is the brief's fallback). Server only:
    -- the kill write is server-authoritative and clients see it via base-game
    -- crop density sync.
    if g_server ~= nil and g_SoilFertilityManager and g_SoilFertilityManager.establishment
        and g_SoilFertilityManager.establishment.isInitialized
        and g_SoilFertilityManager.establishment.checkDayFallback then
        g_SoilFertilityManager.establishment:checkDayFallback()
    end

    -- [SF-14] ZONE YIELD: daily cadence pump. When Time Guard is present its
    -- accrual drives the capture; this call runs the capture on SF's own day
    -- tracking when Time Guard is absent, the brief's named neutral flow.
    -- Server only: the capture write is server-authoritative.
    if g_server ~= nil and g_SoilFertilityManager and g_SoilFertilityManager.zoneYield
        and g_SoilFertilityManager.zoneYield.isInitialized
        and g_SoilFertilityManager.zoneYield.checkDayFallback then
        g_SoilFertilityManager.zoneYield:checkDayFallback()
    end

    -- REFINED: round-robin display-layer mirror. Keeps the per-pixel
    -- weed/pest/disease/urgency/yield maps in step with the field-level
    -- simulation values (herbicide passes, burn effects, nutrient changes
    -- feeding urgency...) without touching every write site. A few fields
    -- per tick, engine-side ops only when a value actually moved.
    self:_vmMirrorDisplayTick(dt)

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
                    -- REFINED: snapshot the field averages so every daily process
                    -- (fallow recovery, seasonal shift, pressures, pH drift, OM
                    -- decay...) is mirrored onto the per-pixel value maps as one
                    -- uniform whole-field shift that preserves spatial variation.
                    local vmSnap = self:_vmSnapshotField(fd)
                    for _ = 1, (self._dailyBatchRepeat or 1) do
                        self:_processOneDailyField(fid, fd)
                    end
                    self:_vmApplySnapshotDeltas(fid, fd, vmSnap)
                    -- Display layers (pressures/urgency/yield) mirror immediately
                    -- rather than waiting for the round-robin sweep to reach us
                    if self:vmAvailable() then
                        self:_vmMirrorDisplayField(fid, fd)
                    end
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

                -- PHASE 1/2: owned farmlands AND NPC-managed farmlands enter the
                -- active simulation set. Unowned, unmanaged land still gets
                -- fieldData but is excluded from daily updates.
                if g_farmlandManager then
                    local farmlandOwner = g_farmlandManager:getFarmlandOwner(actualFieldId)
                    local isNpc = NpcSoilBridge and NpcSoilBridge:isNPCManaged(actualFieldId) == true
                    if (farmlandOwner and farmlandOwner > 0) or isNpc then
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
                local isNpc2 = NpcSoilBridge and NpcSoilBridge:isNPCManaged(farmlandId) == true
                if (farmlandOwner2 and farmlandOwner2 > 0) or isNpc2 then
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
-- SF-76 FIELD GENESIS: a terrain-derived deviation in [-1.0, 1.0] replacing the
-- smooth regional gradient on a new save. Height-relative, slope and sink
-- proximity from SF-77's TopographyCache when present; one direct terrain
-- sample when not. Deterministic from the per-save genesis seed: the same seed
-- twice yields identical soil (the acceptance's byte-identical bar). Same
-- amplitude bounds as regionalField, so every value stays inside the shipped
-- clamps.
function SoilFertilitySystem:_genesisDeviation(fieldId, slot)
    local cx, cz = nil, nil
    local farmlandObj = g_farmlandManager and g_farmlandManager:getFarmlandById(fieldId)
    if farmlandObj and self.bundledMaps then
        cx, cz = self.bundledMaps:getFarmlandCenter(farmlandObj)
    end

    -- Terrain facts: height-relative value, slope class, sink proximity.
    local heightNorm, slopeN, sink = 0, 0, false
    local topo = g_SoilFertilityManager and g_SoilFertilityManager.topography
    if topo ~= nil and type(topo.getCellInfo) == "function" and cx ~= nil then
        local ok, info = pcall(function() return topo:getCellInfo(cx, cz) end)
        if ok and info ~= nil then
            -- Height-relative: low ground deviates negative (collects), high positive.
            heightNorm = math.max(-1.0, math.min(1.0, (info.height or 0) / 50.0))
            -- Slope classes are strings; compare against known names without
            -- requiring the TopographyCache module to be present (SF-77 absent
            -- degrades to the direct sample path below).
            local slopeClass = info.slope
            if slopeClass == "gentle" then slopeN = 0.25
            elseif slopeClass == "moderate" then slopeN = 0.5
            elseif slopeClass == "steep" then slopeN = 1.0 end
            sink = info.sink == true
        end
    else
        -- One direct sample when the cache is absent.
        local gs = g_terrainNode
        if gs ~= nil then
            local ok, h = pcall(getTerrainHeightAtWorldPos, gs, cx or 0, 0, cz or 0)
            if ok then heightNorm = math.max(-1.0, math.min(1.0, (h or 0) / 50.0)) end
        end
    end

    -- Compose with the per-save seed + per-slot jitter (the same hash01 the
    -- noise field uses, so it stays deterministic and PRNG-pure).
    local seedMix = math.sin(self.genesisSeed * 1.13 + slot * 7.7) * 43758.5453
    seedMix = seedMix - math.floor(seedMix)   -- [0,1)
    local dev = heightNorm * 0.5 + slopeN * 0.3 - (sink and 0.4 or 0.0) + (seedMix * 2.0 - 1.0) * 0.2
    return math.max(-1.0, math.min(1.0, dev))
end

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
        if self.genesisActive then
            return baseValue + self:_genesisDeviation(fieldId, slot) * regionalAmt + noiseField(slot) * noiseAmt
        end
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

--- Arable crop-polygon area (ha) for a farmland parcel, or nil if it cannot be resolved yet.
--- The soil model is keyed by farmland id (getOrCreateField(farmlandId)), but one parcel can
--- bundle a farmstead / roads / hedges with the arable field (#719, Riverbend Springs farmland
--- 66). Using the mapped crop field's own areaHa scopes per-hectare math and the compaction
--- average to worked ground instead of the whole parcel, which is ~2x larger. Returns nil (not
--- the parcel area) so each caller keeps control of its own fallback.
---@param farmlandId number
---@return number|nil cropAreaHa
function SoilFertilitySystem:_resolveCropAreaHa(farmlandId)
    if not (g_fieldManager and g_fieldManager.farmlandIdFieldMapping) then return nil end
    local cropField = g_fieldManager.farmlandIdFieldMapping[farmlandId]
    if not cropField then return nil end
    -- Read the areaHa property directly, the proven pattern from the #475/#476 area fix.
    local areaHa = cropField.areaHa
    -- areaHa defaults to 1.0 until the field polygon loads; treat ~1.0 as "not ready yet" so the
    -- placeholder is never locked in (matches the existing #475/#476 crop-area guard).
    if areaHa and areaHa > 0 and math.abs(areaHa - 1.0) > 0.05 then
        return areaHa
    end
    return nil
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
    if area and area > 0 then
        confirmedArea = true
    else
        -- Prefer the arable crop-polygon area over the whole farmland parcel (#719).
        local cropArea = self:_resolveCropAreaHa(fieldId)
        if cropArea then
            initialArea = cropArea
            confirmedArea = true
        elseif farmlandObj and farmlandObj.areaInHa and farmlandObj.areaInHa > 0 then
            -- Crop polygon not loaded yet: seed a sane nonzero area from the parcel but leave it
            -- UNconfirmed so the first spray/herbicide pass swaps in the real crop area.
            initialArea = farmlandObj.areaInHa
            confirmedArea = false
        end
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
        tilledSinceHarvest = false,  -- #738: any plough/cultivator/strip pass since last harvest
        noTillActive = false,        -- #738: active crop drilled into untilled residue (daily OM credit)
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
        diseaseDiscovered = false,  -- discovery gate: an active infection stays UNKNOWN in every scout report until deliberately scouted (or revealed by a future dog / ProStaff report)
        lastFungicide = nil,        -- last chemical applied (for resistance / UI flavor)
        resistance = {},            -- CD-9: { [mode] = score 0..max } per-MOA resistance scores
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
            -- REFINED: repaint the per-pixel value maps with the re-rolled profile
            self:vmSeedField(fieldId, true)
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
            elseif NpcSoilBridge and NpcSoilBridge:isNPCManaged(fieldId) == true then
                -- B5: designated NPC ground is SKIPPED, never rerolled. This
                -- protects the disease/pest reservoir history the feature exists
                -- to create.
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
                -- REFINED: repaint the per-pixel value maps with the re-rolled profile
                self:vmSeedField(fieldId, true)
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
                gx = cx, gz = cz,   -- [SF-19] grid coords (see pre-populate)
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
                        -- [SF-19] GRID COORDS kept on the cell so the spatial
                        -- pressure pass can recover world positions WITHOUT
                        -- decoding the cell key (the key is not safely
                        -- invertible for negative coordinates). Live grid
                        -- arithmetic only.
                        gx = cx2,
                        gz = cz2,
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

    -- REFINED: an admin override sets the field-average, so repaint the field
    -- polygon uniformly on the per-pixel value maps (per-pixel variation from
    -- earlier partial passes is intentionally flattened, matching old behaviour).
    if self:vmAvailable() then
        local verts = self:_getFieldPolyVerts(fieldId, field)
        if verts then
            self.valueMaps:paintPolygon("nitrogen",      verts, field.nitrogen)
            self.valueMaps:paintPolygon("phosphorus",    verts, field.phosphorus)
            self.valueMaps:paintPolygon("potassium",     verts, field.potassium)
            self.valueMaps:paintPolygon("pH",            verts, field.pH)
            self.valueMaps:paintPolygon("organicMatter", verts, field.organicMatter)
            -- Display layers repaint to the new field state too
            local disp = self:_vmDisplayValues(field)
            for key, v in pairs(disp) do
                self.valueMaps:paintPolygon(key, verts, v)
            end
            field._vmDisp = disp
            field._vmPend = nil   -- pending drifts are baked into the repaint
            local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
            if minimapLayer then minimapLayer:markDirty() end
        end
    end

    -- Legacy zoneData path (fallback overlay + old-save compatibility)
    if next(field.zoneData) == nil then
        self:_prePopulateZoneData(fieldId)
        return
    end
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

-- =========================================================
-- REFINED: per-pixel value map integration (SoilValueMaps)
-- =========================================================

-- fieldData keys mirrored into value maps (compaction has its own write path)
local VM_NUTRIENT_KEYS = { "nitrogen", "phosphorus", "potassium", "pH", "organicMatter" }

-- REFINED: field-level display layers rendered per-pixel. Values come from
-- fieldData scalars / computed values; kept current by _vmMirrorDisplayTick.
local VM_DISPLAY_KEYS = { "weedPressure", "pestPressure", "diseasePressure", "urgency", "yieldEfficiency" }

-- Within-field seeding variation per layer (semantic units, +/-)
local VM_SEED_SPREAD = {
    nitrogen      = 6.0,
    phosphorus    = 5.0,
    potassium     = 5.0,
    pH            = 0.18,
    organicMatter = 0.5,
    compaction    = 0,
}

-- SF-20 RELIEF WEIGHT: seed one nutrient layer. Organic matter is painted from
-- the field's own terrain relief (low ground is richer); every other layer keeps
-- the cosmetic Perlin spread. Relief REPLACES the spread only where relief
-- exists - on a field flatter than the guard, seedPolygonByRelief declines and
-- this falls through to exactly today's behaviour.
--
-- Organic matter is the ONE property where a static terrain-derived deviation is
-- honest. Nitrogen here is plant-available N, a seasonal weather-driven
-- quantity, not a landscape-structural one: do NOT extend this to N/P/K/pH.
local function vmSeedNutrient(vm, key, verts, baseValue, spread)
    if key == "organicMatter" and baseValue and baseValue > 0 then
        local relief = SoilConstants.RELIEF
        -- Guarded on the method as well as the constants: seeding must degrade
        -- to the existing path on any value-maps object that predates SF-20
        -- rather than take a field's seeding down with it.
        if relief and vm.seedPolygonByRelief then
            local amplitude = baseValue * relief.AMPLITUDE_FRACTION * relief.AGRONOMY_SCALE
            if amplitude >= (relief.MIN_AMPLITUDE or 0)
               and vm:seedPolygonByRelief(key, verts, baseValue, amplitude) then
                return
            end
        end
    end
    vm:seedPolygon(key, verts, baseValue, spread)
end

--- True when the per-pixel value maps are usable.
function SoilFertilitySystem:vmAvailable()
    return self.valueMaps ~= nil and self.valueMaps.available
end

--- [SF-14] True when the captured per-cell `yieldEfficiency` layer owns the
--- value-map layer, i.e. the zone-yield capture is live. When true, the
--- field-average display mirror and seed must NOT write `yieldEfficiency`
--- (the captured per-cell truth is the layer's content; a uniform stamp or
--- whole-field delta would flatten it back to a display average). Fail-open:
--- no subsystem = not owned = the display stamp stays today's behaviour.
function SoilFertilitySystem:_zoneYieldOwnsYieldLayer()
    local zy = g_SoilFertilityManager and g_SoilFertilityManager.zoneYield
    if zy == nil or type(zy.isLive) ~= 'function' then return false end
    local ok, live = pcall(function() return zy:isLive() end)
    if not ok then return false end
    return live == true
end

-- Seed this layer? Skips layers restored from savegame files (their pixel
-- data is newer/finer than anything re-derivable from field averages).
local function vmShouldSeed(vm, key, force)
    if force then return true end
    local entry = vm:getLayerEntry(key)
    return entry ~= nil and not entry.loaded
end

--- Discovery gate for the display layers: an active infection stays invisible on
--- EVERY painted surface (the disease map, the urgency map, and via the mirror
--- the MP-synced client picture) until the field is scouted. Unscouted ground now
--- paints a uniform UNKNOWN marker (the reserved DMV state 1), not clean green, so
--- an unscouted infected field and an unscouted clean field are indistinguishable
--- yet neither pretends to be healthy (Unscouted Indicator). Returns the UNKNOWN
--- sentinel (< 0) for unscouted ground so the paint path floors it to UNKNOWN_RAW;
--- callers that need a number clamp it to 0 (it never counts as trouble). When the
--- disease system is OFF there is nothing to hide, so it falls back to clean (0).
--- This protects the scouting economy the same way the disease HUD self-gates on
--- diseaseDiscovered. Pest has no discovery concept, so it is not gated.
function SoilFertilitySystem:_vmShownDiseasePressure(field)
    if not field.diseaseDiscovered then
        if self.settings and self.settings.diseasePressure then
            return SoilValueMaps.UNKNOWN_VALUE   -- sentinel < 0 -> painted as UNKNOWN
        end
        return 0
    end
    return field.diseasePressure or 0
end

--- Cheap field-average urgency (mirrors getFieldUrgency without the full
--- getFieldInfo status computation - used for per-frame display mirroring).
function SoilFertilitySystem:_vmComputeUrgency(field)
    local thresh = (SoilConstants.YIELD_SENSITIVITY and SoilConstants.YIELD_SENSITIVITY.OPTIMAL_THRESHOLD) or 70
    local nDef = math.max(0, thresh - (field.nitrogen   or 0)) / thresh
    local pDef = math.max(0, thresh - (field.phosphorus or 0)) / thresh
    local kDef = math.max(0, thresh - (field.potassium  or 0)) / thresh
    local phOpt = 6.5
    local phMin = (SoilConstants.NUTRIENT_LIMITS and SoilConstants.NUTRIENT_LIMITS.PH_MIN) or 5.0
    local phDef = math.max(0, phOpt - (field.pH or phOpt)) / (phOpt - phMin)
    local weedDef    = (field.weedPressure    or 0) / 100
    local pestDef    = (field.pestPressure    or 0) / 100
    local diseaseDef = math.max(0, self:_vmShownDiseasePressure(field)) / 100
    return math.min(100, ((nDef + pDef + kDef + phDef + weedDef + pestDef + diseaseDef) / 7) * 100)
end

--- Current semantic values of the five display layers for a field.
function SoilFertilitySystem:_vmDisplayValues(field)
    return {
        weedPressure    = field.weedPressure    or 0,
        pestPressure    = field.pestPressure    or 0,
        diseasePressure = self:_vmShownDiseasePressure(field),
        urgency         = self:_vmComputeUrgency(field),
        yieldEfficiency = field.yieldEfficiency or 100,
    }
end

--- Seed one field's polygon into the value maps.
--- Priority: migrate the legacy per-cell zoneData when it carries nutrient
--- values (old saves keep their sub-field detail), otherwise paint the field
--- averages with Perlin within-field variation. Layers restored from the
--- savegame files are left untouched (per-layer gating), so adding new
--- layers to an existing refined save seeds only the missing ones.
---@param force boolean|nil  Repaint even when a layer was loaded from savegame
function SoilFertilitySystem:vmSeedField(fieldId, force)
    if not self:vmAvailable() then return end
    local field = self.fieldData[fieldId]
    if not field then return end

    local vm = self.valueMaps
    local verts = self:_getFieldPolyVerts(fieldId, field)
    if not verts then return end

    -- Migration path: old-save zoneData cells carry per-cell N values
    local migrated = false
    if not force and field.zoneData and next(field.zoneData) ~= nil
       and vmShouldSeed(vm, "nitrogen", force) then
        local zone = SoilConstants.ZONE
        -- Only migrate when at least one cell differs from the field average -
        -- uniform zoneData carries no information the seeded noise wouldn't.
        for _, cell in pairs(field.zoneData) do
            -- N==0 is the "pressure-only cell" placeholder, not a real reading
            if cell.N and cell.N > 0 and math.abs(cell.N - (field.nitrogen or 0)) > 0.5 then
                migrated = true
                break
            end
        end
        if migrated then
            -- Base fill first so gaps between stamped cells are covered.
            -- [SF-20] The OM base fill is relief-painted; the legacy per-cell
            -- stamp below then lands ON TOP of it, so a migrated save's real
            -- stored soil always beats the derived relief picture and only the
            -- gaps between stamped cells take the terrain-true fill.
            for _, key in ipairs(VM_NUTRIENT_KEYS) do
                if vmShouldSeed(vm, key, force) then
                    vmSeedNutrient(vm, key, verts, field[key]
                        or SoilConstants.FIELD_DEFAULTS[key], VM_SEED_SPREAD[key])
                end
            end
            -- Recover each legacy cell's world position by ENCODING grid
            -- positions to keys, never DECODING the key. The legacy key
            -- cx*10000+cz is not invertible once a coordinate is negative (cell
            -- (2,-5) encodes to 19995 and a naive decode reads it back as
            -- (1,9995)), and FS25 maps are origin-centred so roughly half of any
            -- real field's cells carry a negative component. Decoding therefore
            -- paints those cells at the wrong world position on first load of a
            -- migrated save. Walking the field polygon and encoding each position
            -- is always safe (position -> key is the same map the store used).
            local half = zone.CELL_SIZE * 0.5
            local cs   = zone.CELL_SIZE
            local minX, maxX = verts[1].x, verts[1].x
            local minZ, maxZ = verts[1].z, verts[1].z
            for i = 2, #verts do
                local vx, vz = verts[i].x, verts[i].z
                if vx < minX then minX = vx end
                if vx > maxX then maxX = vx end
                if vz < minZ then minZ = vz end
                if vz > maxZ then maxZ = vz end
            end
            local cxMin, cxMax = math.floor(minX / cs), math.floor(maxX / cs)
            local czMin, czMax = math.floor(minZ / cs), math.floor(maxZ / cs)
            local budget = 100000   -- safety valve against a degenerate bbox
            for cx = cxMin, cxMax do
                for cz = czMin, czMax do
                    budget = budget - 1
                    if budget < 0 then break end
                    local cell = field.zoneData[tostring(cx * 10000 + cz)]
                    if cell then
                        local wx = (cx + 0.5) * cs
                        local wz = (cz + 0.5) * cs
                        if _isPointInPoly(wx, wz, verts) then
                            if cell.N  and cell.N  > 0   then vm:writeValueAtWorld("nitrogen",      wx, wz, cell.N,  half) end
                            if cell.P  and cell.P  > 0   then vm:writeValueAtWorld("phosphorus",    wx, wz, cell.P,  half) end
                            if cell.K  and cell.K  > 0   then vm:writeValueAtWorld("potassium",     wx, wz, cell.K,  half) end
                            if cell.pH and cell.pH > 5.0 then vm:writeValueAtWorld("pH",            wx, wz, cell.pH, half) end
                            if cell.OM and cell.OM > 0   then vm:writeValueAtWorld("organicMatter", wx, wz, cell.OM, half) end
                            if cell.compaction and cell.compaction > 0 and vmShouldSeed(vm, "compaction", force) then
                                vm:writeValueAtWorld("compaction", wx, wz, cell.compaction, half)
                            end
                        end
                    end
                end
                if budget < 0 then break end
            end
            SoilLogger.debug("ValueMaps: field %d migrated from zoneData cells", fieldId)
        end
    end

    if not migrated then
        for _, key in ipairs(VM_NUTRIENT_KEYS) do
            if vmShouldSeed(vm, key, force) then
                vmSeedNutrient(vm, key, verts, field[key]
                    or SoilConstants.FIELD_DEFAULTS[key], VM_SEED_SPREAD[key])
            end
        end
        if (field.compaction or 0) > 0 and vmShouldSeed(vm, "compaction", force) then
            vm:paintPolygon("compaction", verts, field.compaction)
        end
    end

    -- REFINED display layers: uniform field paint (rawFloor keeps zero-pressure
    -- fields visible as the "good" colour state). The mirror keeps them current.
    -- [SF-14] The captured per-cell yieldEfficiency layer is NOT seeded from the
    -- field-average stamp: it carries captured truth only, written by the
    -- zone-yield capture pass (and restored from the savegame file).
    local disp = self:_vmDisplayValues(field)
    local yieldOwned = self:_zoneYieldOwnsYieldLayer()
    for _, key in ipairs(VM_DISPLAY_KEYS) do
        if key ~= "yieldEfficiency" or not yieldOwned then
            if vmShouldSeed(vm, key, force) then
                vm:paintPolygon(key, verts, disp[key])
            end
        end
    end
    field._vmDisp = disp   -- prime the mirror cache
end

--- Paint a field's organic certification state (0 conventional / 1 in-transition /
--- 2 certified) into the ephemeral organicStatus value-map layer. Conventional
--- encodes to a transparent DMV state, so a conventional field reads as no-data.
--- Rebuilt from field.organic, never persisted; the value-map join sync carries it
--- to clients. No-op when the value maps are unavailable.
function SoilFertilitySystem:paintOrganicStatus(fieldId, field)
    if not self:vmAvailable() then return end
    field = field or (self.fieldData and self.fieldData[fieldId])
    if not field then return end
    local stateInt = 0
    if field.organic and OrganicCertification then
        stateInt = OrganicCertification.encodeState(field.organic.state)
    end
    local verts = self:_getFieldPolyVerts(fieldId, field)
    if verts then
        self.valueMaps:paintPolygon("organicStatus", verts, stateInt)
    end
end

--- Seed ALL fields into the value maps. Called once after loadSoilData.
--- Per-layer gating: layers restored from savegame files keep their pixels;
--- only missing/new layers are painted.
function SoilFertilitySystem:seedValueMaps(force)
    if not self:vmAvailable() then return end
    -- organicStatus is ephemeral (never persisted); rebuild it from each field's
    -- organic state on every load so an already-certified field renders on first
    -- load, even when the persisted layers were all restored and seeding is skipped.
    for fieldId, field in pairs(self.fieldData) do
        self:paintOrganicStatus(fieldId, field)
    end
    if self.valueMaps.loadedFromSave and not force then
        SoilLogger.info("ValueMaps: all layers restored from savegame - seeding skipped")
        return
    end
    local count = 0
    for fieldId in pairs(self.fieldData) do
        self:vmSeedField(fieldId, force)
        count = count + 1
    end
    SoilLogger.info("ValueMaps: seeded %d field(s)%s", count, force and " (forced)" or "")
end

-- ── REFINED: display layer mirroring ─────────────────────

-- Fields checked per mirror slice, and ms between slices.
local VM_MIRROR_FIELDS_PER_TICK = 3
local VM_MIRROR_INTERVAL_MS     = 250
-- Minimum semantic change (units of 0-100) before an engine op is issued.
local VM_MIRROR_EPSILON         = 0.5

--- Mirror one field's display values onto the value maps as uniform
--- whole-field shifts (preserves any local detail e.g. strip-till lanes).
function SoilFertilitySystem:_vmMirrorDisplayField(fieldId, field)
    local prev = field._vmDisp
    if not prev then
        prev = self:_vmDisplayValues(field)
        field._vmDisp = prev
        return
    end
    local cur = self:_vmDisplayValues(field)
    local verts
    local changed = false
    local yieldOwned = self:_zoneYieldOwnsYieldLayer()
    for _, key in ipairs(VM_DISPLAY_KEYS) do
        -- [SF-14] The captured per-cell yieldEfficiency layer is NOT a display
        -- mirror surface while the zone-yield capture is live: a whole-field
        -- delta toward the field-average stamp would flatten the captured
        -- per-cell truth. The layer then carries captured truth only.
        if key == "yieldEfficiency" and yieldOwned then
            prev[key] = cur[key]
        else
        -- Unscouted<->scouted disease is a state switch (the UNKNOWN sentinel <-> a
        -- real pressure), not a smooth delta, so repaint that field's disease layer
        -- absolutely rather than applying a bogus raw delta across the reserved band.
        if key == "diseasePressure" and (cur[key] < 0) ~= (prev[key] < 0) then
            verts = verts or self:_getFieldPolyVerts(fieldId, field)
            if not verts then return end
            self.valueMaps:paintPolygon(key, verts, cur[key])
            prev[key] = cur[key]
            changed = true
        else
            local delta = cur[key] - prev[key]
            if math.abs(delta) >= VM_MIRROR_EPSILON then
                verts = verts or self:_getFieldPolyVerts(fieldId, field)
                if not verts then return end
                local applied = self.valueMaps:applyDeltaToPolygon(key, verts, delta)
                if applied ~= 0 then
                    prev[key] = prev[key] + applied
                    changed = true
                end
            end
        end
        end  -- yieldEfficiency && yieldOwned skip
    end
    if changed then
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
    end
end

--- Round-robin slice driven from update(dt).
function SoilFertilitySystem:_vmMirrorDisplayTick(dt)
    if not self:vmAvailable() then return end
    if g_server == nil then return end   -- clients receive map sync, not local sim

    self._vmMirrorTimer = (self._vmMirrorTimer or 0) + dt
    if self._vmMirrorTimer < VM_MIRROR_INTERVAL_MS then return end
    self._vmMirrorTimer = 0

    if not self._vmMirrorList or self._vmMirrorCursor == nil
       or self._vmMirrorCursor >= #self._vmMirrorList then
        -- Rebuild the field id list and restart the sweep
        local list = {}
        for fieldId in pairs(self.fieldData) do list[#list + 1] = fieldId end
        self._vmMirrorList   = list
        self._vmMirrorCursor = 0
    end

    local list = self._vmMirrorList
    local cursor = self._vmMirrorCursor
    local n = #list
    local slice = 0
    while slice < VM_MIRROR_FIELDS_PER_TICK and cursor < n do
        cursor = cursor + 1
        slice = slice + 1
        local fieldId = list[cursor]
        local field = self.fieldData[fieldId]
        if field then
            self:_vmMirrorDisplayField(fieldId, field)
        end
    end
    self._vmMirrorCursor = cursor
end

--- Snapshot the field-average nutrient values before a simulation step.
function SoilFertilitySystem:_vmSnapshotField(field)
    if not self:vmAvailable() then return nil end
    return {
        nitrogen      = field.nitrogen,
        phosphorus    = field.phosphorus,
        potassium     = field.potassium,
        pH            = field.pH,
        organicMatter = field.organicMatter,
    }
end

--- Diff the field against a snapshot and queue the per-key deltas as uniform
--- whole-field shifts on the value maps. Deltas below one raw map step
--- accumulate in field._vmPend until they are large enough to apply, so slow
--- daily drifts are never lost to quantisation.
function SoilFertilitySystem:_vmApplySnapshotDeltas(fieldId, field, snap)
    if not snap or not self:vmAvailable() then return end
    for _, key in ipairs(VM_NUTRIENT_KEYS) do
        local before = snap[key]
        local after  = field[key]
        if before ~= nil and after ~= nil and after ~= before then
            self:_vmQueueFieldDelta(field, key, after - before)
        end
    end
    self:_vmFlushFieldDeltas(fieldId, field)
end

function SoilFertilitySystem:_vmQueueFieldDelta(field, key, delta)
    if delta == 0 then return end
    if not field._vmPend then field._vmPend = {} end
    field._vmPend[key] = (field._vmPend[key] or 0) + delta
end

function SoilFertilitySystem:_vmFlushFieldDeltas(fieldId, field)
    local pend = field._vmPend
    if not pend or not self:vmAvailable() then return end
    local verts = self:_getFieldPolyVerts(fieldId, field)
    if not verts then return end
    for key, delta in pairs(pend) do
        if delta ~= 0 then
            local applied = self.valueMaps:applyDeltaToPolygon(key, verts, delta)
            if applied ~= 0 then
                pend[key] = delta - applied
            end
        end
    end
end

--- Local read-modify-write bump around a work position (residue/amendment
--- incorporation at the tillage tool). deltas = {nitrogen=dN, ...}.
function SoilFertilitySystem:vmLocalBump(worldX, worldZ, deltas, radius)
    if not worldX or not worldZ or not self:vmAvailable() then return end
    for key, d in pairs(deltas) do
        if d and d ~= 0 then
            self.valueMaps:addValueAtWorld(key, worldX, worldZ, d, radius or 4.0)
        end
    end
end

--- Paint the sprayer's real boom strip into the value maps additively as a
--- SWEPT QUAD (RSF-762). Each frame with a valid dose paints the parallelogram
--- between the last PAINTED boom line and the current boom line, then advances
--- the anchor. Consecutive frames share no overlap, so the dose never stacks;
--- a tick whose dose guard fails does not advance the anchor, so the next valid
--- tick's quad spans the gap and the orphan mechanism self-heals. First frame or
--- a teleport (anchor farther than 3x the boom length) seeds a thin strip instead.
--- Replaces the per-cell painting that used to live in markBoomCells, which now
--- only marks coverage: painting is decoupled from coverage bookkeeping.
---
--- The dose is the same mass-conserving arithmetic as before, with the strip's
--- own area as the denominator: painted delta = sd.dX * (sd.area / stripAreaHa),
--- so the total nutrient applied per tick is exactly sd.dX * sd.area. Consume-once
--- stays (the second HookManager site in the same tick cannot re-apply) and the
--- sd.time == nowMs stale-dose guard stays.
---@param fieldId    number
---@param boomPoints table   Array of {x=,z=} CELL-SWEEP positions for markBoomCells.
---   NOT a boom line: its last element is always the vehicle root (RSF-836).
---@param fillTypeName string  FERTILIZER_PROFILES key (unused; kept for the call sites)
---@param boomLine table|nil  { ax, az, bx, bz } the true boom endpoints in world,
---   derived in the vehicle's own frame (see HookManager:getBoomLineEndpoints).
---   When present the painted line runs tip to tip at any heading. The array ends
---   are only a defensive fallback for a caller that supplies no line.
function SoilFertilitySystem:paintBoomStrip(fieldId, boomPoints, _fillTypeName, boomLine)
    if not fieldId or not boomPoints or #boomPoints < 2 then return end
    local field = self.fieldData and self.fieldData[fieldId]
    if not field then return end
    if not self:vmAvailable() then return end

    local nowMs = (g_currentMission and g_currentMission.time) or 0
    local sd = field._sprayDose
    -- Stale-dose guard stays: only THIS tick's dose may paint, and only once.
    if not sd or sd.time ~= nowMs or not sd.area or sd.area <= 0 then return end

    -- Boom endpoints: the true boom line when the caller supplies it (RSF-836).
    -- The cell sweep is NOT a boom line and its last element is the vehicle root,
    -- so reading it positionally painted one tip to the middle of the machine,
    -- halved and foreshortened by the heading cosine.
    local ax, az, bx, bz
    if boomLine and boomLine.ax ~= nil and boomLine.bx ~= nil then
        ax, az, bx, bz = boomLine.ax, boomLine.az, boomLine.bx, boomLine.bz
    else
        ax, az = boomPoints[1].x, boomPoints[1].z
        bx, bz = boomPoints[#boomPoints].x, boomPoints[#boomPoints].z
    end
    local boomLen = math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
    if boomLen < 0.01 then return end

    local anchor = field._vmLastBoomLine
    local sx, sz, wx, wz, hx, hz
    local areaM2

    if anchor then
        -- Tip-swap guard (RSF-836): the endpoint derivation is unordered, so the
        -- two tips can arrive in either order between frames. Pair each tip with
        -- whichever anchor point it is nearer to (straight vs swapped) and use the
        -- closer pairing, so a swapped pair never folds the quad into a bow tie.
        local dxS = (ax - anchor.ax) + (bx - anchor.bx)
        local dzS = (az - anchor.az) + (bz - anchor.bz)
        local dxW = (ax - anchor.bx) + (bx - anchor.ax)
        local dzW = (az - anchor.bz) + (bz - anchor.az)
        local straightSq = dxS * dxS + dzS * dzS
        local swappedSq = dxW * dxW + dzW * dzW
        local travX, travZ
        if swappedSq < straightSq then
            travX = dxW * 0.5
            travZ = dzW * 0.5
        else
            travX = dxS * 0.5
            travZ = dzS * 0.5
        end
        local travel = math.sqrt(travX * travX + travZ * travZ)
        if travel < 0.05 then
            anchor = nil   -- no forward progress this frame: seed instead
        elseif travel > boomLen * 3 then
            anchor = nil   -- teleport: never span the gap, seed fresh
        else
            -- Quad between the previous boom line (base) and this one (travel edge).
            sx, sz = anchor.ax, anchor.az
            wx, wz = anchor.bx, anchor.bz
            hx, hz = ax, az
            -- Parallelogram area = |(w-s) x (h-s)| (2D cross).
            areaM2 = math.abs((wx - sx) * (hz - sz) - (wz - sz) * (hx - sx))
        end
    end

    if anchor == nil then
        -- Seed: a thin strip centred on the current boom line.
        local ux, uz = -(bz - az) / boomLen, (bx - ax) / boomLen
        local h = math.max(0.5, boomLen * 0.02)
        sx, sz = ax - ux * h, az - uz * h
        wx, wz = bx - ux * h, bz - uz * h
        hx, hz = ax + ux * h, az + uz * h
        areaM2 = boomLen * (h * 2)
    end

    local minArea = boomLen * 0.02
    if areaM2 and areaM2 > minArea then
        local areaHa = areaM2 / 10000
        local scale = sd.area / areaHa
        local vm = self.valueMaps
        if sd.dN  ~= 0 then vm:addPaintStrip("nitrogen",      sx, sz, wx, wz, hx, hz, sd.dN  * scale) end
        if sd.dP  ~= 0 then vm:addPaintStrip("phosphorus",    sx, sz, wx, wz, hx, hz, sd.dP  * scale) end
        if sd.dK  ~= 0 then vm:addPaintStrip("potassium",     sx, sz, wx, wz, hx, hz, sd.dK  * scale) end
        if sd.dPH ~= 0 then vm:addPaintStrip("pH",            sx, sz, wx, wz, hx, hz, sd.dPH * scale) end
        if sd.dOM ~= 0 then vm:addPaintStrip("organicMatter", sx, sz, wx, wz, hx, hz, sd.dOM * scale) end

        -- Advance the anchor to the line this quad actually painted.
        field._vmLastBoomLine = { ax = ax, az = az, bx = bx, bz = bz }
        -- Mark a recent boom paint so the narrow-tool dot fallback defers (see applyFertilizer).
        field._vmBoomPaintTime = nowMs
        -- Consume so the second HookManager site in the same tick can't re-apply.
        sd.dN, sd.dP, sd.dK, sd.dPH, sd.dOM = 0, 0, 0, 0, 0
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
    end
end

-- Finish the in-flight daily batch synchronously: process every field still past
-- the cursor with the batch's current repeat count, then close it out. Called when
-- a new day arrives before the async batch drained, so a field's daily pass is
-- never abandoned (the stranded-tail bug). Rare (only under rapid time advance),
-- so paying the remainder in one frame at the catch-up moment is acceptable.
function SoilFertilitySystem:_drainDailyBatchSync()
    local list = self._activeFieldList
    if not list then
        self._pendingDailyUpdate = false
        return
    end
    local n          = #list
    local cursor     = self._dailyBatchCursor or 0
    local repeatDays = self._dailyBatchRepeat or 1
    while cursor < n do
        cursor = cursor + 1
        local fid = list[cursor]
        local fd  = self.fieldData[fid]
        if fd then
            local vmSnap = self:_vmSnapshotField(fd)
            for _ = 1, repeatDays do
                self:_processOneDailyField(fid, fd)
            end
            self:_vmApplySnapshotDeltas(fid, fd, vmSnap)
            if self:vmAvailable() then
                self:_vmMirrorDisplayField(fid, fd)
            end
        end
    end
    self._dailyBatchCursor   = n
    self._pendingDailyUpdate = false
    self.lastSeason          = self._dailyBatchSeason
end

-- Daily soil update - PHASE 4: converted to batch scheduler.
-- Instead of processing every field synchronously on the day-rollover tick
-- (which can stall for hundreds of ms on large maps), we queue work and
-- drain it across multiple frames via the update(dt) batch loop.
function SoilFertilitySystem:updateDailySoil(elapsedDays)
    if not self.settings.enabled or not self.settings.nutrientCycles then return end

    local currentDay = (g_currentMission and g_currentMission.environment and
                        g_currentMission.environment.currentDay) or 0

    -- Guard: don't re-queue if already started a batch for today
    if self._pendingDailyUpdate and self._dailyBatchDay == currentDay then
        SoilLogger.debug("[PERF-P4] Day %d batch already queued, skipping duplicate trigger", currentDay)
        return
    end

    -- Stranding fix: if the PREVIOUS day's batch never finished draining before
    -- this new day arrived (rapid time advance), finish its remaining fields now
    -- instead of resetting the cursor and freezing that unprocessed tail forever.
    if self._pendingDailyUpdate then
        self:_drainDailyBatchSync()
    end

    -- Skipped-day catch-up: how many days this pass stands in for. Each active
    -- field runs its daily logic this many times so missed days are applied
    -- rather than silently dropped.
    self._dailyBatchRepeat = math.max(1, math.floor(elapsedDays or 1))

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

    -- [SF-23] SPATIAL NUTRIENTS: refresh the cached moisture bands once per day,
    -- before the per-field batch runs, so the leach path reads settled water.
    -- Server-only (the daily pass is server-authoritative). Bands that cannot be
    -- derived collapse to the one-band uniform fallback. Neutral when absent.
    if g_server ~= nil and SpatialNutrients and SpatialNutrients.ENABLED then
        SpatialNutrients:refreshAllBands(self)
    end

    -- [SF-21] NEIGHBOUR CROSSING: the crossing PRE-PASS runs once per day, before
    -- the mutation batches (the completion gate is LAW: no mutation before the
    -- snapshot). The transient snapshot lives on self for the batch's read; it is
    -- never saved or synced. Neutral when absent.
    if g_server ~= nil and NeighbourCrossing and NeighbourCrossing.ENABLED then
        local hookMgr = self.hookManager
        if hookMgr then
            self._neighbourSnapshot = NeighbourCrossing:runPrePass(hookMgr, self)
        end
    end

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

-- Weed-factor sample offsets (metres) relative to the field centre. FieldState:update
-- reads weed density at ONE point, so a single centre read misjudges a patchy field:
-- a clean centre on an otherwise weedy field reported 0% while the minimap overlay
-- (which reads the whole WeedSystem map) showed heavy weeds. Averaging
-- the centre plus two rings gives a field-representative value from the SAME source, so
-- withered-weed handling and the herbicide clamp below are unchanged.
local WEED_SAMPLE_OFFSETS = {
    { 0, 0 },
    -- inner ring ~12 m
    { 0, 12 }, { 8.5, 8.5 }, { 12, 0 }, { 8.5, -8.5 }, { 0, -12 }, { -8.5, -8.5 }, { -12, 0 }, { -8.5, 8.5 },
    -- outer ring ~30 m
    { 0, 30 }, { 21, 21 }, { 30, 0 }, { 21, -21 }, { 0, -30 }, { -21, -21 }, { -30, 0 }, { -21, 21 },
}

--- Average the game's weed factor across the field instead of reading a single centre
--- point. Returns an averaged weedFactor in [0,1], or 0 when no managed crop is present
--- at the centre (bare/grass/forage skip exactly as before). A ring point counts only if
--- it is valid, carries the SAME crop as the centre, and (when the engine reports it) sits
--- in this field's farmland, so roads and neighbouring parcels are rejected. On a small
--- field where every ring point is rejected this collapses to the old centre-only read.
---@param fsField table   g_fieldManager field (has posX/posZ, farmland)
---@param fieldId number
function SoilFertilitySystem:_sampleFieldWeedFactor(fsField, fieldId)
    if not (fsField and fsField.posX and fsField.posZ) then return 0 end
    if not self._fieldStateCache then self._fieldStateCache = {} end
    if not self._fieldStateCache[fieldId] then
        local cok, cfs = pcall(FieldState.new)
        self._fieldStateCache[fieldId] = (cok and cfs) and cfs or false
    end
    local fs = self._fieldStateCache[fieldId]
    if not fs then return 0 end

    local nonCrops = (SoilConstants.YIELD_SENSITIVITY and
        SoilConstants.YIELD_SENSITIVITY.NON_CROP_NAMES) or {}

    -- Centre read gates the whole sample: only trust weed data when a managed
    -- (non-forage) crop is actually present. Bare/UNKNOWN or grass/forage → skip.
    local ok = pcall(function() fs:update(fsField.posX, fsField.posZ) end)
    if not (ok and fs.isValid and fs.fruitTypeIndex ~= FruitType.UNKNOWN) then
        return 0
    end
    local centreFruit = fs.fruitTypeIndex
    local fruitDesc   = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(centreFruit)
    local fruitName   = (fruitDesc and fruitDesc.name and string.lower(fruitDesc.name)) or ""
    if nonCrops[fruitName] then return 0 end

    local sum   = fs.weedFactor or 0
    local count = 1

    for i = 2, #WEED_SAMPLE_OFFSETS do
        local off    = WEED_SAMPLE_OFFSETS[i]
        local px, pz = fsField.posX + off[1], fsField.posZ + off[2]
        local pok = pcall(function() fs:update(px, pz) end)
        if pok and fs.isValid and fs.fruitTypeIndex == centreFruit then
            -- farmlandId is 0 until the engine populates it; treat 0/nil as "unknown,
            -- accept" and only reject on a definite different-farmland reading.
            local farmOk = (fs.farmlandId == nil) or (fs.farmlandId == 0) or (fs.farmlandId == fieldId)
            if farmOk then
                sum   = sum + (fs.weedFactor or 0)
                count = count + 1
            end
        end
    end

    return sum / count
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

    -- SF-18 ESTABLISHMENT FAILURE: the daily kill check is NOT driven per-field
    -- here. It is a Time Guard accrual on the simulation flow class (priority
    -- after the moisture store), with SF's own day tracking as the fallback when
    -- Time Guard is absent; both are pumped from update() via checkDayFallback.
    -- This per-field seam stays out so the sweep fires exactly once per day.

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
    field._geometricCoverageOwner = nil  -- #753
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

    -- ── CD-9: Per-MOA resistance daily decay ────────────────────────────────
    -- Each unused month decays resistance scores by 15% (RESISTANCE_DECAY_MONTHLY).
    -- Calendar-normalized: the per-day multiplier is DECAY^(1/daysPerPeriod) so the
    -- monthly decay is identical on 1-day and 28-day months.
    if SoilConstants.RESISTANCE and field.resistance then
        local decayPerDay = SoilConstants.RESISTANCE.DECAY_MONTHLY ^ (1 / daysPerMonth)
        for mode, val in pairs(field.resistance) do
            if val > 0 then
                field.resistance[mode] = val * decayPerDay
                if field.resistance[mode] < 0.01 then field.resistance[mode] = 0 end
            end
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
    elseif field.noTillActive and omDyn and (omDyn.NO_TILL_DAILY_CREDIT or 0) > 0 then
        -- #738 no-till OM: an ACTIVE crop drilled into untilled residue accrues a small
        -- daily OM gain (the preserved residue mat humifying). Fenced against the fallow
        -- recovery above via this elseif, so the two can never stack; applies only while a
        -- crop grows (outside the fallow window). Smaller than the daily decay it offsets,
        -- so no-till still drifts down slightly day to day but skips the per-pass tillage
        -- oxidation entirely - the season-long reason no-till out-builds every tilled type.
        field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX,
                                       (field.organicMatter or 0) + omDyn.NO_TILL_DAILY_CREDIT * timeFactor)
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
                    field._geometricCoverageOwner = nil  -- #753
                    field.sprayTrailPts           = nil
                end
            end

            -- Sample FieldState.weedFactor from the game's weed density map.
            -- weedFactor: 0.0 = clean, 1.0 = fully weedy (matches FieldState default
            -- and getHarvestScaleMultiplier semantics - higher = more yield penalty).
            -- Sample the game's weed factor across the field (multi-point average).
            -- Grass/forage and bare fields skip inside the helper (returns 0), matching
            -- the old centre-only guard. See _sampleFieldWeedFactor.
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
                gameWeedFactor = self:_sampleFieldWeedFactor(fsField, fieldId)
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
            do
                -- #740: real rain, topped up by the short-month climate fill on dry days.
                local rs = self:getEffectiveRainScale()
                if rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD then rainBonus = pp.RAIN_BONUS end
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

        -- #740: real rain, topped up by the short-month climate fill - drives the wet/dry-day
        -- cycle (dryDayCount) the disease model needs, which barely moves on short in-game months.
        local rs = self:getEffectiveRainScale()
        local isRaining = rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD

        if isRaining then
            field.dryDayCount = 0
        else
            field.dryDayCount = (field.dryDayCount or 0) + 1
        end

        if (field.fungicideDaysLeft or 0) > 0 then
            field.fungicideDaysLeft = field.fungicideDaysLeft - 1
        end

        local pressure = field.diseasePressure or 0
        -- #737 option D: two thresholds, not one. Past dryThreshold a dry day still
        -- grows disease, only damped (DRY_GROWTH_MULT). Outright decay waits for a
        -- genuine drought at droughtThreshold. Previously the decay branch was an
        -- `elseif` on dryThreshold, so any dry spell REPLACED growth rather than
        -- slowing it and disease could never establish.
        local dryThreshold     = cm.dryThreshold * daysPerMonth
        local droughtThreshold = dryThreshold * (dp.DROUGHT_THRESHOLD_MULT or 2.0)
        local dryDays          = field.dryDayCount or 0

        if dryDays >= droughtThreshold then
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
            local diffMult = self.settings:getDiseasePressureMultiplier()
            local soilMult = SoilDiseaseSystem.soilHealthMult(field)
            local rotMult  = self.settings.cropRotation and SoilDiseaseSystem.rotationMult(field) or 1.0

            local rainBonus = isRaining and (dp.RAIN_BONUS * cm.rainBonusMult) or 0
            local tunDis = getTuningMult(self.settings, "tuningDiseaseGrowth", "ZERO_MULT")
            -- Damp growth once the dry threshold is passed but before a real drought.
            -- Applied to the base rate only: rainBonus is already zero on a dry day.
            local dryMult = (dryDays >= dryThreshold) and (dp.DRY_GROWTH_MULT or 0.40) or 1.0
            field.diseasePressure = math.min(100, pressure + ((baseRate * cm.growthMult * seasonMult * cropMult * tunDis * diffMult * soilMult * rotMult * dryMult) + rainBonus) * timeFactor)
        end

        -- Maintain the named active disease over the scalar pressure.
        self:_updateActiveDisease(fieldId, field, season, isRaining, currentDay)
    end

    -- [SF-21] NEIGHBOUR CROSSING: roll the conducive-gated disease boundary
    -- seeding before the pressure pass runs, so a fresh boundary origin gets
    -- spread the same day. Uses the day's transient snapshot (the pre-pass ran
    -- in updateDailySoil ahead of the batch). Protection fence is LAW inside.
    -- Neutral when absent / no snapshot / protected field.
    if g_server ~= nil and NeighbourCrossing and NeighbourCrossing.ENABLED
       and ReleaseGate.isSystemLive("spatial_soil")
       and self._neighbourSnapshot and self._neighbourSnapshot[fieldId] then
        local hookMgr = self.hookManager
        if hookMgr then
            NeighbourCrossing:rollDiseaseCrossing(self, fieldId, field,
                self._neighbourSnapshot[fieldId], currentDay)
        end
    end

    -- [SF-19] VARIABLE PEST AND DISEASE PRESSURE: distribute the field-level
    -- pressure onto the per-cell store with ORIGIN and SPREAD. Server-only
    -- (the daily pass is server-authoritative), after the field aggregate is
    -- settled. The field-level model is untouched; this adds only WHERE the
    -- pressure lands and how it moves. Neutral when disabled or no cells.
    -- RELEASE GATE: the spatial-soil family (SF-19 and the drop) is LOCKED; when not
    -- released the per-cell distribution never runs and pressure stays field-level.
    if g_server ~= nil and SpatialPressures and SpatialPressures.ENABLED
       and ReleaseGate.isSystemLive("spatial_soil") then
        local poly = self:_getFieldPolyVerts(fieldId, field)
        SpatialPressures:run(self, fieldId, field, currentDay, poly,
            self._neighbourSnapshot and self._neighbourSnapshot[fieldId])
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
    -- (our modifier, plus any upstream ecosystem cut it folds in - see SCS-002), so
    -- the map layer can never disagree with the monitor or with the grain you
    -- harvest. No managed crop (fallow/grass) → 0 (renders empty).
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
        SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

-- Nutrient leaching from sustained soil moisture. Driven by rain (rainScale > 0) and/or,
-- when SeasonalCropStress is present, irrigation (SCS-001): a field's SCS moisture reads
-- into the same leach factor, so watering is a trade-off rather than a free yield lever.
-- Firewall: SF is the sole writer of its N/P/K; it only READS SCS moisture, never writes it.
-- When SCS is absent (moisture nil) this is byte-identical to the original rain-only leach.
function SoilFertilitySystem:applyRainEffects(dt, rainScale)
    if not self.settings.enabled or not self.settings.rainEffects then return end
    rainScale = rainScale or 0

    local rain = SoilConstants.RAIN
    local limits = SoilConstants.NUTRIENT_LIMITS

    -- Scale leaching by active RWE event if present
    local rweMultiplier = 1.0
    local rwe = g_currentMission and g_currentMission.randomWorldEvents
    if rwe and rwe.EVENT_STATE then
        rweMultiplier = RWE_LEACH_MULTIPLIERS[rwe.EVENT_STATE.activeEvent] or 1.0
    end

    local tunRain = getTuningMult(self.settings, "tuningRainLeaching", "ZERO_MULT")
    local baseFactor = dt * rain.LEACH_BASE_FACTOR * rweMultiplier * tunRain

    -- SCS-001: bind the SCS moisture reader once. g_cropStressManager is per-mod scoped
    -- and NOT visible from here; the reliable cross-mod handle is the mission bridge
    -- g_currentMission.cropStressManager (mirrors our own mission.soilFertilityManager).
    local csMgr = g_currentMission and g_currentMission.cropStressManager
    local moistThreshold = rain.IRRIGATION_LEACH_THRESHOLD
    -- #740 per-day precedence (replaces the blanket preset guard): one precipitation
    -- authority per day. A FILLED-wet day is SF-supplied precipitation (the fill topped up
    -- a dry short-month sky), so SCS's rain-reflecting moisture LEVEL is NOT counted - part
    -- of it reflects the real weather SF is now standing in for, and counting both would
    -- double-count precipitation. Real IRRIGATION is still counted, read as the irrigation-
    -- only RATE (getIrrigationRate) so a pivot-watered field still leaches on a filled day.
    -- A REAL rain day (filledDay=false) keeps the full rain + SCS-moisture model unchanged,
    -- so this is byte-identical whenever the fill is not engaged (opt-out / long months).
    local filledDay = self._rainWasFilled == true
    local count = 0

    -- Iterate only owned fields (activeFieldIds set, Phase 1)
    for fieldId in pairs(self.activeFieldIds) do
        local field = self.fieldData[fieldId]
        if field then
            -- REAL day: per-field SCS moisture LEVEL (0-1), the blended rain+irrigation total.
            -- FILLED day: irrigation-only RATE (per-hour gain) instead, so rain moisture is
            -- not double-counted. Both pcall-wrapped, neutral when SCS absent/errors.
            local moisture = nil     -- SCS moisture level, used only on a REAL day
            local irrigRate = nil    -- SCS irrigation-only rate, used only on a FILLED day
            if csMgr then
                if filledDay then
                    local ok, r = pcall(csMgr.getIrrigationRate, csMgr, fieldId)
                    if ok and type(r) == "number" then irrigRate = r end
                else
                    local ok, m = pcall(csMgr.getMoisture, csMgr, fieldId)
                    if ok and type(m) == "number" then moisture = m end
                end
            end

            -- Effective wetness driver: rain (or the fill), plus a sustained-water term.
            -- On a REAL day that term is the SCS moisture level above the threshold (SCS-001);
            -- on a FILLED day it is real irrigation only, normalized to a 0-1 intensity so the
            -- units match. Irrigation is scaled gentler than rain (IRRIGATION_LEACH_SCALE).
            local drive = rainScale
            if not filledDay then
                if moisture and moisture > moistThreshold then
                    local irrigDrive = ((moisture - moistThreshold) / (1.0 - moistThreshold)) * rain.IRRIGATION_LEACH_SCALE
                    if irrigDrive > drive then drive = irrigDrive end
                end
            else
                if irrigRate and irrigRate > 0 then
                    local irrigIntensity = irrigRate / (rain.IRRIGATION_RATE_LEACH_REF or 0.018)
                    if irrigIntensity > 1 then irrigIntensity = 1 end
                    local irrigDrive = irrigIntensity * rain.IRRIGATION_LEACH_SCALE
                    if irrigDrive > drive then drive = irrigDrive end
                end
            end

            if drive > 0 then
                -- Sustained moisture amplifies leaching; high organic matter buffers it (OM 0-10).
                -- Only on a REAL day: on a FILLED day SF is the precipitation authority, so the
                -- rain-reflecting moisture amplification is dropped (left at 1.0).
                local scsMoistureMult = 1.0
                if moisture and not filledDay then
                    local omBuffer = 1.0 - ((field.organicMatter or 0) / 10.0) * rain.OM_LEACH_DAMPEN
                    if omBuffer < 0 then omBuffer = 0 end
                    scsMoistureMult = 1.0 + moisture * rain.MOISTURE_LEACH_GAIN * omBuffer
                end

                local leachFactor = drive * baseFactor * scsMoistureMult
                if leachFactor > 0 then
                    field.nitrogen   = math.max(limits.MIN, field.nitrogen   - (leachFactor * rain.NITROGEN_MULTIPLIER))
                    field.potassium  = math.max(limits.MIN, field.potassium  - (leachFactor * rain.POTASSIUM_MULTIPLIER))
                    field.phosphorus = math.max(limits.MIN, field.phosphorus - (leachFactor * rain.PHOSPHORUS_MULTIPLIER))
                    field.pH         = math.max(limits.PH_MIN, field.pH      - (leachFactor * rain.PH_ACIDIFICATION))
                    -- REFINED: mirror leaching onto the value maps. Per-tick amounts are
                    -- far below one raw map step, so they accumulate in field._vmPend and
                    -- flush as a uniform polygon shift once large enough.
                    if self:vmAvailable() then
                        -- [SF-23] SPATIAL NUTRIENTS: split the leach across the field's
                        -- cached moisture bands so the wet hollow loses more than the dry
                        -- knoll, normalised to the field-level loss. Phosphorus does NOT
                        -- go banded here: it binds, and the field-level 0.5 multiplier is
                        -- its only leach path (its spatial moves are application and crop
                        -- removal). One band (no SCS / no bands) is byte-identical to the
                        -- old uniform queue below.
                        if SpatialNutrients and SpatialNutrients.ENABLED
                           and field._snBands and #field._snBands > 1 then
                            SpatialNutrients:queueBandedDelta(self, fieldId, field,
                                "nitrogen",  -(leachFactor * rain.NITROGEN_MULTIPLIER))
                            SpatialNutrients:queueBandedDelta(self, fieldId, field,
                                "potassium", -(leachFactor * rain.POTASSIUM_MULTIPLIER))
                            -- pH rides the same banded distribution downward.
                            SpatialNutrients:queueBandedDelta(self, fieldId, field,
                                "pH",        -(leachFactor * rain.PH_ACIDIFICATION))
                            SpatialNutrients:flushBands(self, fieldId, field)
                            -- Phosphorus: uniform, it binds.
                            self:_vmQueueFieldDelta(field, "phosphorus", -(leachFactor * rain.PHOSPHORUS_MULTIPLIER))
                            self:_vmFlushFieldDeltas(fieldId, field)
                        else
                            self:_vmQueueFieldDelta(field, "nitrogen",   -(leachFactor * rain.NITROGEN_MULTIPLIER))
                            self:_vmQueueFieldDelta(field, "potassium",  -(leachFactor * rain.POTASSIUM_MULTIPLIER))
                            self:_vmQueueFieldDelta(field, "phosphorus", -(leachFactor * rain.PHOSPHORUS_MULTIPLIER))
                            self:_vmQueueFieldDelta(field, "pH",         -(leachFactor * rain.PH_ACIDIFICATION))
                            self:_vmFlushFieldDeltas(fieldId, field)
                        end
                    end
                    count = count + 1
                end
            end
        end
    end

    SoilLogger.debug("[PERF-P1] Leach: %d field(s), rainScale=%.3f baseFactor=%.9f%s",
        count, rainScale, baseFactor, csMgr and " (SCS moisture-aware)" or "")
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
    local diffMultiplier = self.settings:getDepletionMultiplier()
    factor = factor * diffMultiplier

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

    -- REFINED: mirror the harvest extraction onto the per-pixel value maps as a
    -- uniform whole-field shift (engine-side polygon modifier op). Sub-step
    -- amounts accumulate in field._vmPend so per-cut extraction is never lost
    -- to the map's raw quantisation.
    if self:vmAvailable() then
        local tunD = getTuningMult(self.settings, "tuningNutrientDepletion", "RATE_MULT")
        -- [SF-23] SPATIAL NUTRIENTS: split the harvest removal across the field's
        -- cached moisture bands so the ground the machine actually worked (and the
        -- wetter ground that grew heavier) loses more. Phosphorus IS banded here:
        -- crop removal is one of its two spatial pathways (application is the
        -- other). One band = the old uniform queue.
        if SpatialNutrients and SpatialNutrients.ENABLED
           and field._snBands and #field._snBands > 1 then
            SpatialNutrients:queueBandedDelta(self, fieldId, field, "nitrogen",   -rates.N * factor * tunD)
            SpatialNutrients:queueBandedDelta(self, fieldId, field, "phosphorus", -rates.P * factor * tunD)
            SpatialNutrients:queueBandedDelta(self, fieldId, field, "potassium",  -rates.K * factor * tunD)
            SpatialNutrients:flushBands(self, fieldId, field)
            -- OM is not banded: chopped straw distributes with the swath, uniform
            -- (queued in Step 4 below, unchanged).
        else
            self:_vmQueueFieldDelta(field, "nitrogen",   -rates.N * factor * tunD)
            self:_vmQueueFieldDelta(field, "phosphorus", -rates.P * factor * tunD)
            self:_vmQueueFieldDelta(field, "potassium",  -rates.K * factor * tunD)
        end
    end

    -- Step 4: Chopped straw/chaff adds organic matter.
    -- OM is a concentration, so gain scales by fraction of field harvested this call,
    -- not by absolute area. A full harvest at sr=1.0 adds exactly OM_RATE to the field.
    local sr = strawRatio or 0
    if sr > 0 and areaHa > 0 then
        local omGain = (areaHa / fieldAreaHa) * sr * SoilConstants.CHOPPED_STRAW.OM_RATE
        field.organicMatter = math.min(limits.ORGANIC_MATTER_MAX, (field.organicMatter or 0) + omGain)
        self:_vmQueueFieldDelta(field, "organicMatter", omGain)
    end

    self:_vmFlushFieldDeltas(fieldId, field)

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
    local cutStates = fruitDesc.cutStates
    if cutStates and cutStates[gs] then return false end
    if fruitDesc.witheredState and gs == fruitDesc.witheredState then return false end
    if fruitName and perennialSet and perennialSet[fruitName] then
        local minH = fruitDesc.minHarvestingGrowthState
        local maxH = fruitDesc.maxHarvestingGrowthState
        return (minH and minH > 0 and gs >= minH
            and (not maxH or maxH <= 0 or gs <= maxH)) or false
    end
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
            -- Perennial forage (grass, meadow, alfalfa…) is exempt from amendment burn
            -- while the sward is short - young regrowth or freshly cut. Liming or spreading
            -- organics on a short/cut sward is standard practice (small leaf area, low burn
            -- risk), so only penalise once it has regrown into its harvest window (tall).
            -- Annual crops are never exempt. Shared by lime (#646) and organic matter
            -- (#629/#645).
            -- A short/early crop must not take the amendment burn: a seedling annual or a
            -- short/cut perennial sward has no leaf canopy to scorch (#645/#646/#681). The
            -- shared helper decides whether the crop is established enough to actually burn.
            local burnExempt = not hasCrop or not self:isAmendmentBurnRisk(cropFruitIndex, cropGrowthState)
            if hasCrop and not burnExempt then

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
                        -- Finished compost scorches an established crop far more gently than fresh
                        -- slurry/manure - stabilized humus carries no free salt/ammonia to burn the
                        -- canopy - so it caps at the lower COMPOST_MAX (agronomic constant, Arissani
                        -- 2026-07-24). Seedling / short-cut sward stay exempt (handled above).
                        local omCap = (fillType.name == "COMPOST" and ab and ab.COMPOST_MAX)
                                   or (ab and ab.OM_MAX) or 0.20
                        self:applyAmendmentBurnSlice(field, omCap)
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
    if not field._farmlandAreaConfirmed or _isNewSession then
        -- Prefer the arable crop-polygon area, not the whole farmland parcel (#719). The parcel
        -- includes roads/hedges/yard (~2x crop area) which skewed Pass%, per-ha rates, and the
        -- compaction average. Resolve straight off the farmland->field mapping (no spray position
        -- needed) so it works from the first pass and on dedicated servers.
        local cropArea = self:_resolveCropAreaHa(fieldId)
        if cropArea then
            -- Sanity floor (#726): a re-confirmation must never drop the field area below
            -- the hectares already covered this session. A bogus small resolve (e.g. a wrong
            -- farmland->field mapping on a multi-field parcel) would otherwise collapse the
            -- denominator and pin Pass% at 100%, and skew per-ha rates + the compaction average.
            -- No-op in the healthy path (session coverage <= true crop area).
            local resolvedArea = math.max(cropArea, field.sessionCoverageHa or 0)
            if resolvedArea ~= field.fieldArea then
                field.fieldArea = resolvedArea
                field.compactionTotalCells = nil  -- recompute the average denominator on the corrected area
            end
            field._farmlandAreaConfirmed = true
        elseif g_farmlandManager and (field.fieldArea or 0) <= 1.0 then
            -- Crop polygon not loaded yet and area still at the 1.0 default: seed from the parcel
            -- so per-ha math is not stuck at 1 ha, but stay unconfirmed so a later pass corrects it.
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj and (farmlandObj.areaInHa or 0) > 0 then
                field.fieldArea = farmlandObj.areaInHa
            end
        end
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
        local rrMult = self.settings:getReplenishmentMultiplier()
        local factor = (liters / 1000) / areaInHa * rrMult

        -- Capture before-values for diagnostic logging (debug mode only).
        local dbgN0, dbgP0, dbgK0, dbgPH0 = field.nitrogen, field.phosphorus, field.potassium, field.pH

        -- #735: snapshot the field's pre-spray baseline ONCE per session, BEFORE the
        -- field-average update below mutates field.nitrogen. Lazily-created zoneData
        -- cells seed from this uniform baseline instead of the running average, so a
        -- uniform pass no longer paints a false low->high gradient across the field.
        -- Cleared on session reset (harvest/tillage/day change) so it re-snapshots.
        if field._zoneBaseline == nil then
            field._zoneBaseline = {
                N  = field.nitrogen,   P  = field.phosphorus,
                K  = field.potassium,  OM = field.organicMatter,
            }
        end

        local tunFert = getTuningMult(self.settings, "tuningFertilizerEfficiency", "RATE_MULT")
        if entry.N then field.nitrogen   = math.min(limits.MAX, field.nitrogen   + entry.N * factor * tunFert) end
        if entry.P then field.phosphorus = math.min(limits.MAX, field.phosphorus + entry.P * factor * tunFert) end
        if entry.K then field.potassium  = math.min(limits.MAX, field.potassium  + entry.K * factor * tunFert) end
        if entry.pH then field.pH        = math.max(limits.PH_MIN, math.min(limits.PH_MAX, field.pH + entry.pH * factor * tunFert)) end
        if entry.OM then field.organicMatter = math.max(0, math.min(limits.ORGANIC_MATTER_MAX, field.organicMatter + entry.OM * factor * tunFert)) end

        -- #735: stash THIS tick's field-average nutrient delta so markBoomCells can paint
        -- the boom's newly-covered cells with the correct LOCAL dose (each cell = its own
        -- pre-spray value + the local application rate) instead of the drifting field
        -- average. markBoomCells re-scales this per-field-average delta up to a per-cell
        -- delta by (fieldArea / area-covered-this-tick) - see the paint there. Deltas
        -- accumulate across VWW sections in the same tick (each calls applyFertilizer),
        -- and reset when the tick or product changes; sessionCoverageCells (the dedup) is
        -- itself reset on product change (#442) and session end, so a re-spray repaints.
        local now = (g_currentMission and g_currentMission.time) or 0
        if not field._sprayDose or field._sprayDose.time ~= now or field._sprayDose.product ~= fillType.name then
            field._sprayDose = { dN = 0, dP = 0, dK = 0, dPH = 0, dOM = 0,
                                 area = areaInHa, time = now, product = fillType.name }
        end
        local sd = field._sprayDose
        sd.area = areaInHa
        if entry.N  then sd.dN  = sd.dN  + entry.N  * factor * tunFert end
        if entry.P  then sd.dP  = sd.dP  + entry.P  * factor * tunFert end
        if entry.K  then sd.dK  = sd.dK  + entry.K  * factor * tunFert end
        if entry.pH then sd.dPH = sd.dPH + entry.pH * factor * tunFert end
        if entry.OM then sd.dOM = sd.dOM + entry.OM * factor * tunFert end

        -- REFINED: no pH bulk sync. Like PF's lime map, only ground the boom has
        -- actually passed over gets the new pH (paintBoomStrip / the dot write
        -- below); unsprayed areas keep their old value on the per-pixel map.
        -- The legacy zoneData bulk loop is gone with the zoneData nutrient path.

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

        -- REFINED: per-pixel write at the sprayer position into the runtime value
        -- maps (~2 m/px). The full boom-width strip is now painted per-cell by
        -- markBoomCells (#735, correct local dose). This dot is the NARROW-TOOL
        -- fallback only: tools whose span is under one cell yield no boom points, so
        -- markBoomCells never runs and this dot is their sole per-pixel write. It
        -- DEFERS whenever a boom paint happened in the last ~half second (a wide
        -- sprayer), so it can't restamp the field average over the correct strip.
        local sprayX = self._lastSprayX
        local sprayZ = self._lastSprayZ
        local boomRecent = field._vmBoomPaintTime ~= nil
            and (now - field._vmBoomPaintTime) >= 0 and (now - field._vmBoomPaintTime) < 500
        if sprayX and sprayZ and self:vmAvailable() and not boomRecent then
            local vm = self.valueMaps
            if entry.N  then vm:writeValueAtWorld("nitrogen",      sprayX, sprayZ, field.nitrogen,      2.5) end
            if entry.P  then vm:writeValueAtWorld("phosphorus",    sprayX, sprayZ, field.phosphorus,    2.5) end
            if entry.K  then vm:writeValueAtWorld("potassium",     sprayX, sprayZ, field.potassium,     2.5) end
            if entry.pH then vm:writeValueAtWorld("pH",            sprayX, sprayZ, field.pH,            2.5) end
            if entry.OM then vm:writeValueAtWorld("organicMatter", sprayX, sprayZ, field.organicMatter, 2.5) end
            local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
            if minimapLayer then minimapLayer:markDirty() end
        end

        -- Legacy map-shipped GRLE layers (kept for maps that declare them)
        if self.layerSystem and self.layerSystem.available then
            local x, z = self._lastSprayX, self._lastSprayZ
            if x and z then
                if entry.N then self.layerSystem:updatePixelForField("nitrogen",      x, z, field.nitrogen,      2.0) end
                if entry.P then self.layerSystem:updatePixelForField("phosphorus",    x, z, field.phosphorus,    2.0) end
                if entry.K then self.layerSystem:updatePixelForField("potassium",     x, z, field.potassium,     2.0) end
                if entry.pH then self.layerSystem:updatePixelForField("pH",           x, z, field.pH,            2.0) end
                if entry.OM then self.layerSystem:updatePixelForField("organicMatter",x, z, field.organicMatter, 2.0) end
            end
        end

        -- Per-cell pest/disease stamp (these pressures stay on the coarse zone
        -- grid - they are field-level agronomy, not per-pixel soil chemistry).
        if sprayX and sprayZ and (entry.pestReduction or entry.diseaseReduction) then
            local zone = SoilConstants.ZONE
            local cellKey = tostring(math.floor(sprayX / zone.CELL_SIZE) * 10000
                                   + math.floor(sprayZ / zone.CELL_SIZE))
            if field.fieldArea and field.fieldArea > 0 then areaInHa = field.fieldArea end
            if not field.zoneData then field.zoneData = {} end
            if not field.zoneData[cellKey] then
                local zdCount = 0
                for _ in pairs(field.zoneData) do zdCount = zdCount + 1 end
                if zdCount < MAX_ZONE_CELLS then
                    -- REFINED: this cell carries only biotic pressures + compaction now.
                    -- N/P/K/pH/OM live on the per-pixel value maps, not on zoneData, so
                    -- the #735 baseline nutrient seeding no longer applies here.
                    field.zoneData[cellKey] = {
                        weedPressure    = field.weedPressure,
                        pestPressure    = field.pestPressure,
                        diseasePressure = field.diseasePressure,
                        compaction      = field.compaction,
                    }
                end
            end
            local cell = field.zoneData[cellKey]
            if cell then
                local cellFactor = (liters / 1000.0) / areaInHa
                if entry.pestReduction    then cell.pestPressure    = math.max(0, (cell.pestPressure    or field.pestPressure    or 0) - entry.pestReduction    * cellFactor) end
                if entry.diseaseReduction then cell.diseasePressure = math.max(0, (cell.diseasePressure or field.diseasePressure or 0) - entry.diseaseReduction * cellFactor) end
                -- REFINED: mirror the local reduction onto the per-pixel display
                -- maps so the sprayed strip shows on the pest/disease overlays.
                if self:vmAvailable() then
                    local half = zone.CELL_SIZE * 0.5
                    if entry.pestReduction then
                        self.valueMaps:writeValueAtWorld("pestPressure", sprayX, sprayZ, cell.pestPressure, half)
                    end
                    if entry.diseaseReduction then
                        -- Discovery gate: a sprayed strip must not reveal
                        -- undiscovered disease; paint the UNKNOWN marker until scouted.
                        local shownDisease = SoilValueMaps.UNKNOWN_VALUE
                        if field.diseaseDiscovered then shownDisease = cell.diseasePressure or 0 end
                        self.valueMaps:writeValueAtWorld("diseasePressure", sprayX, sprayZ, shownDisease, half)
                    end
                end
            end
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
        field.insecticideDaysLeft = SoilDuration.seasonScaled(pp.INSECTICIDE_DURATION_DAYS)
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
        field.fungicideDaysLeft = math.floor(SoilDuration.seasonScaled(dp.FUNGICIDE_DURATION_DAYS) * (cm.fungicideMult or 1))
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
        field._geometricCoverageOwner = nil  -- #753: re-detect geometric path for new product
        field.sprayTrailPts           = nil
    end

    if fillTypeName then field.sessionLastProduct = fillTypeName end

    -- Fertilizer products: coverage is handled by markBoomCells (cell dedup).
    if updateFractions == false then return end

    -- Liter-based coverage is a FALLBACK for applications with no boom position.
    -- If the geometric path (markBoomCells) is actively tracking coverage for this
    -- field (overlayOnly=false), defer to it: adding the liter estimate on top
    -- double-counts and pins Pass% at 100% (#726). Use _geometricCoverageOwner
    -- instead of sessionCoverageCells, because overlayOnly mode populates cells for
    -- spray trail dedup but does NOT update coverage fractions (#753).
    if field._geometricCoverageOwner then return end

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

                -- ── Pressure zone stamp (zoneData) ─────────────────────────────────
                -- REFINED: nutrient values now live on the per-pixel value maps
                -- (paintBoomStrip / applyFertilizer); zoneData cells only carry the
                -- pressure/compaction stamps used by See&Spray and the compaction
                -- rebuild. Cell cap unchanged.
                --
                -- SEED ON CREATE, WRITE NOTHING ON UPDATE. An existing cell holds real
                -- per-cell work this stamper knows nothing about, and re-stamping the
                -- field average destroyed all of it on the next boom pass:
                --   tillage reductions  - plough :1129-1135, cultivator :1281-1287,
                --                         secondary tillage :1466-1472
                --   treatment reductions- entry map :4926-4927, insecticide :5003,
                --                         fungicide :5035, herbicide :5445
                -- The treatment cases were the worst: the base-class sprayer hook calls
                -- markBoomCells in the SAME invocation that applied the product, so a
                -- per-cell reduction was erased before the pass finished.
                -- Compaction already followed this rule; the three pressures now match it.
                --
                -- The DAILY weed propagation (:4056-4064) is deliberately untouched and
                -- still re-syncs every cell to the field value once a day. That is
                -- correct and must stay: weed's ground truth is the base-game density
                -- map, so the cell is a mirror, and refreshing a mirror to match its
                -- source is not the same operation as flattening it mid-pass.
                local canWrite = true
                if field.zoneData[cellKey] == nil then
                    if (field.zoneDataSize or 0) >= MAX_ZONE_CELLS then canWrite = false end
                end
                if canWrite then
                    if field.zoneData[cellKey] == nil then
                        field.zoneDataSize = (field.zoneDataSize or 0) + 1
                        field.zoneData[cellKey] = {}
                    end
                    local zc = field.zoneData[cellKey]
                    if zc.weedPressure    == nil then zc.weedPressure    = field.weedPressure    or 0 end
                    if zc.pestPressure    == nil then zc.pestPressure    = field.pestPressure    or 0 end
                    if zc.diseasePressure == nil then zc.diseasePressure = field.diseasePressure or 0 end
                    if zc.compaction      == nil then zc.compaction      = field.compaction      or 0 end
                end
            end
        end
    end

    -- RSF-762: value-map painting no longer lives here. markBoomCells only marks
    -- coverage (session/daily cells, pass percent, spray trail, zoneData seed-on-create).
    -- The per-cell addValueAtWorld painter was moved out: it painted before the paint,
    -- orphaned whole rows when the dose guard failed, quantised to whole 10 m cells
    -- (staircasing on angled passes), and banded per tick. paintBoomStrip now owns the
    -- painting as a swept additive quad, self-healing a failed tick by spanning the gap.
    -- Coverage bookkeeping above is unchanged by design.

    -- Recompute fractions after all cells are processed.
    -- In overlayOnly mode the counters are owned by trackSprayerCoverage (liter-based);
    -- leave the fractions it set untouched so the pass% / ha display stays consistent.
    if not overlayOnly then
        -- Mark this field as geometrically tracked so trackSprayerCoverage's guard knows
        -- the cell-dedup path is actually updating coverage fractions (#753).
        --
        -- F61 (VWW half of #650): claim ownership ONLY once at least one cell has
        -- actually been accepted. Claiming unconditionally is what freezes coverage on a
        -- multi-field farmland: _getFieldPolyVerts resolves the FIRST field polygon on the
        -- farmland, so on the OTHER field every boom-cell centre fails _isPointInPoly and
        -- nothing accrues -- yet the flag was still set, and the guard at :5226 then locked
        -- out the liter fallback for the rest of the session. Coverage and Pass% sat at 0%
        -- and the 80% PROTECTION_THRESHOLD never opened, which is the reported symptom.
        --
        -- Gating on the cell set makes the degradation correct instead: no accepted cells
        -- means the geometric path is not tracking anything, so the liter fallback stays
        -- available exactly as it does for a non-VWW implement. When the polygon IS right
        -- the first accepted cell claims ownership on the same call as before, so the
        -- healthy path is unchanged and there is still no double-count.
        --
        -- next() is O(1) and sessionCoverageCells is already cleared at every site that
        -- clears _geometricCoverageOwner, so this needs no new state to keep in sync.
        if next(field.sessionCoverageCells) ~= nil then
            field._geometricCoverageOwner = true
        end
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
    -- Also re-check at the start of every new session so field-size changes (issue #507/#726) take effect.
    local _isNewSession = not next(field.sessionCoverageCells or {})
    if not field._farmlandAreaConfirmed or _isNewSession then
        -- Prefer the arable crop-polygon area over the parcel (#719); mirrors applyFertilizer.
        local cropArea = self:_resolveCropAreaHa(fieldId)
        if cropArea then
            -- Sanity floor (#726): mirrors applyFertilizer. Never let a re-confirm drop the
            -- field area below the hectares already covered this session (a bogus small resolve
            -- would collapse the denominator and pin Pass% at 100%). No-op in the healthy path.
            local resolvedArea = math.max(cropArea, field.sessionCoverageHa or 0)
            if resolvedArea ~= field.fieldArea then
                field.fieldArea = resolvedArea
                field.compactionTotalCells = nil
            end
            field._farmlandAreaConfirmed = true
        elseif g_farmlandManager and (field.fieldArea or 0) <= 1.0 then
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj and (farmlandObj.areaInHa or 0) > 0 then
                field.fieldArea = farmlandObj.areaInHa
            end
        end
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
            field.herbicideDaysLeft = SoilDuration.seasonScaled(SoilConstants.WEED_PRESSURE.HERBICIDE_DURATION_DAYS)
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
                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
            end
        end
    end

    if not field.nutrientBuffer then field.nutrientBuffer = {} end
    field.nutrientBuffer[99991] = (field.nutrientBuffer[99991] or 0) + liters
    self:trackSprayerCoverage(fieldId, liters, "HERBICIDE", false)
end

function SoilFertilitySystem:onInsecticideAppliedDirect(fieldId, effectiveness, liters)
    if not self.settings.pestPressure then return end
    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Confirm field area on first application (mirrors onHerbicideAppliedDirect / applyFertilizer)
    local _isNewSession = not next(field.sessionCoverageCells or {})
    if not field._farmlandAreaConfirmed or _isNewSession then
        local cropArea = self:_resolveCropAreaHa(fieldId)
        if cropArea then
            -- Sanity floor (#726): mirrors applyFertilizer / onHerbicideAppliedDirect. A re-confirm
            -- must never drop the field area below the hectares already covered this session, or a
            -- bogus small resolve would collapse the denominator and pin Pass% at 100%. No-op healthy.
            local resolvedArea = math.max(cropArea, field.sessionCoverageHa or 0)
            if resolvedArea ~= field.fieldArea then
                field.fieldArea = resolvedArea
                field.compactionTotalCells = nil
            end
            field._farmlandAreaConfirmed = true
        elseif g_farmlandManager and (field.fieldArea or 0) <= 1.0 then
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj and (farmlandObj.areaInHa or 0) > 0 then
                field.fieldArea = farmlandObj.areaInHa
            end
        end
    end

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

function SoilFertilitySystem:onFungicideAppliedDirect(fieldId, effectiveness, liters, chemId)
    -- Organic certification (OM-209): a synthetic fungicide on a transitioning or
    -- certified field is a breach (full reset to conventional); the approved organic
    -- pair (SULFUR / COPPER_HYDROXIDE, in ORGANIC.APPROVED_INPUTS) passes clean. This is
    -- the fungicide analogue of the onFertilizerApplied breach check. chemId is the
    -- upper-case fill type name, exactly what onInputApplied expects. It runs before the
    -- disease-sim guard below so organic rules hold even when disease pressure is off, and
    -- on the same server-authoritative apply path as the fertilizer breach.
    if g_SoilFertilityManager and g_SoilFertilityManager.organic and chemId then
        g_SoilFertilityManager.organic:onInputApplied(fieldId, chemId)
    end

    if not self.settings.diseasePressure then return end
    local field = self:getOrCreateField(fieldId, true)
    if not field then return end

    -- Physical named fungicide (6-chemical kit): scale this generic pass by the chemical's
    -- control rate against the field's active disease (the catalog's per-disease matrix) and
    -- record which chemical was used, so a sprayed AZOXYSTROBIN behaves like its catalog entry.
    -- Generic FUNGICIDE never reaches here (it routes through the fertilizer path), so chemId
    -- is always one of the six; the guard keeps it safe regardless.
    local rateName = "FUNGICIDE"
    -- CD-12: is this a tank mix? NIL MEANS BEHAVE EXACTLY AS BEFORE -- every branch below
    -- collapses to the single-chemical path when it is.
    local blendPartners = SoilBlends.getPartners(chemId)

    -- RELEASE GATE: the tank-mix family (CD-12) is LOCKED. When not released, a blend
    -- fill type degrades to the generic fungicide path: rateName stays FUNGICIDE, no
    -- lastFungicide tag, no max-over-partners control, and its resistance partners are
    -- NOT split (a blend is not a real chemical until CD-12 releases). The fill type
    -- itself still exists (registered at load) but behaves inert, per the design doc.
    local blendsLive = ReleaseGate.isSystemLive("cd12_tank_mixes")
    if blendPartners and blendsLive then
        -- The blend carries its own calibrated rate (the mean of its partners'), so the
        -- meter denominator below is the blend's pass and not generic FUNGICIDE's.
        rateName = chemId
        field.lastFungicide = chemId
        -- CONTROL: the MAX over partners, and it stays a SEPARATE STEP from the resistance
        -- factor further down -- do not fuse them. SoilDiseaseSystem.effectiveness keys on
        -- the disease's CATEGORY and returns 0 for a nil disease, and activeDisease is nil
        -- below onset, which is exactly when a careful farmer sprays. So this only applies
        -- when a disease is actually present.
        if field.activeDisease and SoilDiseaseSystem and SoilDiseaseSystem.effectiveness then
            local best = 0
            for _, partner in ipairs(blendPartners) do
                local control = SoilDiseaseSystem.effectiveness(partner, field.activeDisease) or 0
                if control > best then best = control end
            end
            -- CD-10 ruled control factor: against a HYBRID, a blend spanning two FRESH modes
            -- earns full control while one fresh mode earns half. Without it, max-over-partners
            -- composed with the hybrid's flat 0.25 category default means a two-chemical mix
            -- answers a hybrid no better than one jug. No-op on ordinary diseases.
            if ReleaseGate.isSystemLive("cd10_hybrids") then
                best = best * HybridStrains.freshModeFactor(field, field.activeDisease, blendPartners)
            end
            effectiveness = (effectiveness or 1.0) * best
        end
    elseif chemId and SoilConstants.FUNGICIDE_CATALOG[chemId] then
        rateName = chemId
        field.lastFungicide = chemId
        if field.activeDisease and SoilDiseaseSystem and SoilDiseaseSystem.effectiveness then
            local control = SoilDiseaseSystem.effectiveness(chemId, field.activeDisease) or 1.0
            -- CD-10: one jug spans one mode, so against a two-mode hybrid it earns half
            -- control at best. This is the asymmetry that makes mixing worth doing.
            if ReleaseGate.isSystemLive("cd10_hybrids") then
                control = control * HybridStrains.freshModeFactor(field, field.activeDisease, { chemId })
            end
            effectiveness = (effectiveness or 1.0) * control
        end
    end

    -- Confirm field area on first application (mirrors onInsecticideAppliedDirect / applyFertilizer)
    local _isNewSession = not next(field.sessionCoverageCells or {})
    if not field._farmlandAreaConfirmed or _isNewSession then
        local cropArea = self:_resolveCropAreaHa(fieldId)
        if cropArea then
            -- Sanity floor (#726): mirrors the other direct spray paths. A re-confirm must never
            -- drop the field area below the hectares already covered this session, or a bogus small
            -- resolve would collapse the denominator and pin Pass% at 100%. No-op in the healthy path.
            local resolvedArea = math.max(cropArea, field.sessionCoverageHa or 0)
            if resolvedArea ~= field.fieldArea then
                field.fieldArea = resolvedArea
                field.compactionTotalCells = nil
            end
            field._farmlandAreaConfirmed = true
        elseif g_farmlandManager and (field.fieldArea or 0) <= 1.0 then
            local farmlandObj = g_farmlandManager:getFarmlandById(fieldId)
            if farmlandObj and (farmlandObj.areaInHa or 0) > 0 then
                field.fieldArea = farmlandObj.areaInHa
            end
        end
    end

    local areaInHa = field.fieldArea or 1.0
    if areaInHa <= 0 then areaInHa = 1.0 end
    local targetRate = (SoilConstants.SPRAYER_RATE.BASE_RATES[rateName] or SoilConstants.SPRAYER_RATE.BASE_RATES.FUNGICIDE).value
    local targetVol = areaInHa * targetRate
    if targetVol <= 0 then return end

    -- CD-9: Per-MOA resistance build and effectiveness reduction.
    --
    -- METERED PER PASS, NOT PER CALL (F66). This runs off an appended function on
    -- Sprayer.onEndWorkAreaProcessing and is reached once per boom section per frame --
    -- the hook's own comment measures that at "1000+ times per spray pass". A bare
    -- increment therefore saturated a mode inside the first second of the first pass, and
    -- since the penalty below is (1 - score/maxRes), a fungicide the player had just
    -- bought dropped to zero effect partway through the pass he was spraying.
    --
    -- BUILD_PER_APPLICATION is a per-FULL-RATE-PASS figure (Constants.lua:1744), so it is
    -- scaled by this call's share of a full-rate pass, exactly as every other consequence
    -- in this function scales by liters / targetVol. One boom section contributes its own
    -- slice and the slices across a whole pass sum to one application. Capped at 1.0 so a
    -- single oversized call can never count as more than one pass. This restores the
    -- dose_factor term the ratified CD-9 design specified.
    --
    -- It sits BELOW the field-area confirm deliberately: targetVol is the meter's
    -- denominator, and before that confirm fieldArea can still be the 1.0 ha default,
    -- which would collapse the denominator and re-create the saturation this fixes.
    -- CD-12: the partners this pass builds on. A single chemical is the one-element case and
    -- collapses to exactly the arithmetic that shipped before blends existed.
    -- RELEASE GATE: when CD-12 is locked, a blend is not a real chemical, so it builds
    -- no split resistance - the partner set collapses to the blend's own name (which has
    -- no mode, so the loop simply finds nothing to build).
    local resistParts = (blendPartners and blendsLive) and blendPartners or { chemId }
    local partnerCount = #resistParts

    local isOrganicField = field.organic ~= nil
        and (field.organic.state == SoilConstants.ORGANIC.STATE_TRANSITION
             or field.organic.state == SoilConstants.ORGANIC.STATE_CERTIFIED)
    local doseFactor = math.min(1.0, (liters or 0) / targetVol)
    local bestFactor = nil

    -- RELEASE GATE: the disease-resistance family (CD-9) is LOCKED. When not
    -- released, resistance never accumulates and effectiveness is never reduced by
    -- it: a sprayed fungicide behaves as the stable generic baseline. CD-10 hybrids
    -- and CD-12 blend handling ride this same family and are gated with it.
    if ReleaseGate.isSystemLive("cd9_resistance") then
        for _, partner in ipairs(resistParts) do
            local mode = self.getModeForFillType(partner)
            if mode then
                local isNatural = self.isNaturalFungicide(partner)
                local maxRes = isNatural and SoilConstants.RESISTANCE.MAX_NATURAL or SoilConstants.RESISTANCE.MAX_SYNTHETIC
                -- THE ORGANIC GUARD IS EVALUATED PER PARTNER, never on the blend name:
                -- isNaturalFungicide("BLEND_COPPER_HYDROXIDE_SULFUR") is false, which would
                -- otherwise stop the all-organic blend building any resistance on an organic
                -- field -- a free pass that the two chemicals alone do not get.
                if not (isOrganicField and not isNatural) then
                    -- F68: the durability dial, and it belongs HERE on the build term. Putting it
                    -- on the ceiling does nothing -- the ceiling multiplies the build, divides
                    -- the penalty and scales the bands, so it cancels in all three. Multisite
                    -- naturals build a quarter as fast, which is the only place that difference
                    -- can actually land.
                    local buildRate = isNatural and SoilConstants.RESISTANCE.BUILD_RATE_NATURAL
                                      or SoilConstants.RESISTANCE.BUILD_RATE_SYNTHETIC
                    -- Split across partners: two modes each carry half the selection pressure,
                    -- which IS the mechanism this system exists for. The divisor is the partner
                    -- count, so a future three-partner blend inherits the rule with no new
                    -- constant. Still metered per pass (F66) -- doseFactor is this call's share
                    -- of a full-rate pass.
                    field.resistance[mode] = math.min(maxRes, (field.resistance[mode] or 0)
                        + SoilConstants.RESISTANCE.BUILD_PER_APPLICATION * maxRes * buildRate * doseFactor / partnerCount)
                end
                -- THE RESCUE, and it stays a SEPARATE STEP from the catalog control above: the
                -- MAX over partners of each mode's remaining potency. When one mode is burned
                -- out it contributes nothing and the other partner carries the pass.
                local factor = 1 - ((field.resistance[mode] or 0) / maxRes)
                if bestFactor == nil or factor > bestFactor then bestFactor = factor end
            end
        end

        if bestFactor ~= nil and bestFactor < 1 then
            effectiveness = (effectiveness or 1.0) * bestFactor
        end
    end

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
    -- Work Trail fix: tag coverage with the REAL chemical name (chemId), not the literal
    -- "FUNGICIDE". The sprayer hook already tracked this pass under fillType.name
    -- (e.g. "SULFUR"/"PROPICONAZOLE") via trackSprayerCoverage. Tagging "FUNGICIDE" here made
    -- sessionLastProduct flip every tick, tripping the product-change reset (#442) that wipes
    -- sessionCoverageCells + sprayTrailPts, so the work-trail overlay vanished the instant it drew.
    -- Only the named physical fungicides hit this (generic FUNGICIDE's fill name IS "FUNGICIDE").
    -- updateFractions=false: name-only, so this does not double-count the area already tracked.
    self:trackSprayerCoverage(fieldId, liters, chemId or "FUNGICIDE", false)
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
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
        end
    end
end

--- Heat scorch (CD-14): the correct dose on the wrong day. Spraying a
--- heat-sensitive product (SULFUR, COPPER_HYDROXIDE) when the air is hot
--- damages the SOIL under a standing established crop: pH down, nitrogen
--- drained - exactly the currency this mod trades in. The crop is not killed
--- and the chemical still works; the farmer who checks the forecast pays
--- nothing. Composes the rate burn's band-and-accumulator engine (on a
--- temperature scale) with the amendment burn's crop gate; invents no new
--- machinery class. Server-only by inheritance (it lives under the hook's
--- isServer gate), actor-blind (no getIsAIActive anywhere - an AI pass
--- scorches like a player's), and nil-honest (nil temperature or an absent
--- HEAT_SENSITIVITY entry means NO scorch and NO state change).
--- Called UNCONDITIONALLY from both spray closures, BESIDE the burn branch,
--- never inside the FERTILIZER_PROFILES N/P/K guard (SULFUR and COPPER_HYDROXIDE
--- take the fungicide branch and never reach the guarded lines). The sensitivity
--- probe here is the whole cost of that unconditional call.
---@param fieldId number
---@param fillTypeName string
function SoilFertilitySystem:applyScorchEffect(fieldId, fillTypeName)
    local field = self.fieldData[fieldId]
    if not field then return end

    -- Absent sensitivity entry: the unconditional closure call costs one probe.
    local s = SoilConstants.HEAT_SENSITIVITY[fillTypeName]
    if s == nil then return end

    -- Nil-honest: no WeatherGuard read means no scorch, no state change.
    local tempC = readSprayTemperature()
    if tempC == nil then return end

    local scorchCfg = SoilConstants.SPRAYER_RATE
    local limits    = SoilConstants.NUTRIENT_LIMITS
    local now       = (g_currentMission and g_currentMission.time) or 0
    local gapMs     = scorchCfg.BURN_PASS_GAP_MS or 1500
    local fullMs    = scorchCfg.BURN_FULL_DAMAGE_MS or 8000

    -- Risk band on the temperature scale: below riskT nothing, at/above certainT
    -- the full band caps every application, between them magnitude scales
    -- linearly with the excess (the rate burn's exact clamp shape).
    local riskT    = (scorchCfg.HEAT_RISK_BASE or 30) - (s.shift or 0)
    local certainT = riskT + (scorchCfg.HEAT_BAND_WIDTH or 6)
    if tempC < riskT then return end

    local fullPh, fullN
    if tempC >= certainT then
        fullPh = scorchCfg.SCORCH_PH_DROP_CERTAIN or 0.30
        fullN  = scorchCfg.SCORCH_N_DRAIN_CERTAIN or 12.0
    else
        local excess = (tempC - riskT) / (certainT - riskT)
        excess = math.max(0.0, math.min(1.0, excess))
        fullPh = (scorchCfg.SCORCH_PH_DROP_RISK or 0.15) * excess
        fullN  = (scorchCfg.SCORCH_N_DRAIN_RISK or 5.0) * excess
    end
    if fullPh <= 0 and fullN <= 0 then return end

    -- Crop gate (the #532 pattern, shared shape with applyFertilizer): resolve
    -- the crop the way applyFertilizer does - _lastSprayX/_lastSprayZ plus a
    -- live FieldState query - and require an established standing crop. Bare
    -- ground and seedlings cannot scorch.
    local hasCrop = false
    local cropFruitIndex, cropGrowthState = nil, nil
    local spx, spz = self._lastSprayX, self._lastSprayZ
    if spx and spz and g_farmlandManager then
        local farmlandTmp = g_farmlandManager:getFarmlandAtWorldPosition(spx, spz)
        local fsField = farmlandTmp and g_fieldManager and
                        g_fieldManager.farmlandIdFieldMapping and
                        g_fieldManager.farmlandIdFieldMapping[farmlandTmp.id]
        if fsField and fsField.posX and fsField.posZ then
            local ok, fs = pcall(function()
                local s2 = FieldState.new()
                s2:update(fsField.posX, fsField.posZ)
                return s2
            end)
            if ok and fs and fs.fruitTypeIndex ~= nil and fs.fruitTypeIndex ~= FruitType.UNKNOWN then
                hasCrop          = true
                cropFruitIndex   = fs.fruitTypeIndex
                cropGrowthState  = fs.growthState
            end
        end
    end
    if not hasCrop or not self:isAmendmentBurnRisk(cropFruitIndex, cropGrowthState) then
        return
    end

    -- ── Scorch's OWN accumulator (mirrored on the rate burn) ──────────────────
    -- Pass continuity on the burn's gap/full clock, but with scorch's own fields
    -- so a pass tripping both scorch and the rate burn pays each cap once, and
    -- resetting one never resets the other.
    local dt
    if field._scorchTickTime and (now - field._scorchTickTime) <= gapMs then
        dt = now - field._scorchTickTime
    else
        -- New pass: reset the per-pass accumulators.
        dt = 0
        field._scorchPassPh = 0
        field._scorchPassN  = 0
    end
    field._scorchTickTime = now
    if dt <= 0 then return end   -- first tick of a pass, or a sibling section this tick

    -- ── Full-pass magnitude for the current band (the per-pass cap) ───────────
    local frac   = math.min(1.0, dt / fullMs)
    local phDrop = math.min(fullPh * frac, math.max(0.0, fullPh - (field._scorchPassPh or 0)))
    local nDrain = math.min(fullN  * frac, math.max(0.0, fullN  - (field._scorchPassN  or 0)))
    if phDrop <= 0 and nDrain <= 0 then return end

    field.pH          = math.max(limits.PH_MIN, field.pH - phDrop)
    field.nitrogen    = math.max(limits.MIN, field.nitrogen - nDrain)
    field._scorchPassPh = (field._scorchPassPh or 0) + phDrop
    field._scorchPassN  = (field._scorchPassN  or 0) + nDrain

    self:log("Scorch slice field %d: pH -%.3f, N -%.2f (%.1f C)",
        fieldId, phDrop, nDrain, tempC)

    -- Broadcast on the existing field event, throttled by scorch's OWN timestamp
    -- (never share _lastBurnBroadcast, so scorch and the rate burn each throttle
    -- independently).
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo and
       g_currentMission.missionDynamicInfo.isMultiplayer then
        if SoilFieldUpdateEvent and (not field._scorchBroadcast or (now - field._scorchBroadcast) >= gapMs) then
            field._scorchBroadcast = now
            SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
        end
    end
end

-- Crop rotation projection (shared by getFieldInfo + projectRotation)

--- Pure crop-rotation status for a (mostRecent, previous) crop pair. Shared by
--- getFieldInfo (current status) and projectRotation (hypothetical next crop) so the
--- pre-plant preview can never disagree with the status the player actually gets.
--- Returns "Bonus" / "OK" / "Fatigue", or nil when the pair is incomplete.
---@param crop1Name string|nil most-recent crop (raw FS25 fruit-type name)
---@param crop2Name string|nil the crop before it
---@return string|nil
function SoilFertilitySystem:_rotationStatusFor(crop1Name, crop2Name)
    local cr = SoilConstants.CROP_ROTATION
    if not cr or not crop1Name or not crop2Name then return nil end
    local crop1 = string.lower(crop1Name)
    local crop2 = string.lower(crop2Name)
    local pf    = SoilConstants.PERENNIAL_FORAGE_NAMES or {}
    if pf[crop1] then
        -- Multi-cut perennial forage standing across cuts is normal management, not
        -- monoculture fatigue (#694). Only a bonus when rotated INTO from a non-legume,
        -- non-forage crop.
        if cr.LEGUMES[crop1] and not cr.LEGUMES[crop2] and not pf[crop2] then
            return "Bonus"
        end
        return "OK"
    elseif cr.LEGUMES[crop1] and not cr.LEGUMES[crop2] then
        return "Bonus"
    elseif crop1 == crop2 then
        return "Fatigue"
    end
    return "OK"
end

--- Read-only rotation foresight: "if the player plants candidateCropName next on this
--- field, what rotation status and effects result?" A pure projection that writes no
--- soil state. It runs SoilFertilizer's OWN rotation + disease-rotation logic with the
--- candidate as the hypothetical most-recent crop and the field's current crop as the
--- previous, so the preview always matches the outcome the player actually gets.
---@param fieldId number
---@param candidateCropName string raw/lowercase FS25 fruit-type name of the crop to preview
---@return table|nil { candidate, follows, status, fatigue, fatigueMultiplier, nitrogen, disease } or nil
function SoilFertilitySystem:projectRotation(fieldId, candidateCropName)
    if not fieldId or fieldId <= 0 then return nil end
    if not candidateCropName or candidateCropName == "" then return nil end

    local info = self:getFieldInfo(fieldId)
    if not info then return nil end

    -- The candidate follows whatever crop is in the ground now (getFieldInfo resolves the
    -- live crop, falling back to lastCrop). After the player harvests that crop and plants
    -- the candidate, the candidate becomes lastCrop and the current crop becomes lastCrop2,
    -- so the projected status is _rotationStatusFor(candidate, currentCrop).
    local currentCrop = info.lastCrop
    if not currentCrop or currentCrop == "" then
        -- Nothing to follow yet: projection is undefined until the field has grown a crop.
        return { candidate = candidateCropName, follows = nil, status = nil }
    end

    local status = self:_rotationStatusFor(candidateCropName, currentCrop)
    local cr = SoilConstants.CROP_ROTATION

    -- Disease-pressure direction, from SoilFertilizer's own disease-rotation multiplier on
    -- the hypothetical post-plant history (candidate, currentCrop, previous). >1 raises
    -- disease, <1 lowers it, 1.0 neutral. Guarded so it degrades gracefully if the disease
    -- module is not present.
    local disease = "neutral"
    if SoilDiseaseSystem and SoilDiseaseSystem.rotationMult then
        local mult = SoilDiseaseSystem.rotationMult({
            lastCrop  = candidateCropName,
            lastCrop2 = currentCrop,
            lastCrop3 = info.lastCrop2,
        })
        if mult and mult > 1.001 then
            disease = "up"
        elseif mult and mult < 0.999 then
            disease = "down"
        end
    end

    return {
        candidate         = candidateCropName,
        follows           = currentCrop,
        status            = status,                              -- "Bonus" / "OK" / "Fatigue" / nil
        fatigue           = (status == "Fatigue"),               -- nutrients deplete faster (x FATIGUE_MULTIPLIER)
        fatigueMultiplier = (cr and cr.FATIGUE_MULTIPLIER) or 1.0,
        nitrogen          = (status == "Bonus") and "up" or "neutral", -- legume spring N bonus
        disease           = disease,
    }
end

--- Blessed crop-family lookup (#739). Public wrapper over SoilConstants.CROP_FAMILY
--- so the rotation planner (and any other reader) resolves families through a stable
--- contract instead of poking the internal table. Case-insensitive; returns the
--- family string ("grain"/"pulse"/"oilseed"/"forage"/"root"/"other") or nil for an
--- unknown crop.
---@param cropName string|nil Fruit name (any case)
---@return string|nil family
function SoilFertilitySystem:getCropFamily(cropName)
    if not cropName or cropName == "" then return nil end
    return SoilConstants.CROP_FAMILY[cropName:lower()]
end

--- Blessed rotation-planner candidate pool (#739). Returns the same curated pool
--- the field-detail dialog's Rotation Foresight uses, so the planner surface can
--- never disagree with it. Shape: { LEGUME = {..names..}, NEUTRAL = {..names..} }
--- (lowercase fruit names). The caller adds the same-crop "Fatigue" row itself.
---@return table pool
function SoilFertilitySystem:getRotationCandidatePool()
    return SoilConstants.ROTATION_CANDIDATE_POOL
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
    local posPest = nil
    local posDisease = nil
    local posCompaction = nil
    if x and z and self:vmAvailable() then
        -- REFINED: per-pixel reads from the runtime value maps (~2 m/px)
        local vm = self.valueMaps
        local vn  = vm:readValueAtWorld("nitrogen",      x, z)
        local vp  = vm:readValueAtWorld("phosphorus",    x, z)
        local vk  = vm:readValueAtWorld("potassium",     x, z)
        local vph = vm:readValueAtWorld("pH",            x, z)
        local vom = vm:readValueAtWorld("organicMatter", x, z)
        -- [SF-19 item 4] Tooltip parity: pest, disease and compaction are spatial
        -- on the display maps, so a positional read returns the per-cell truth the
        -- map paints instead of the field scalar. Disease honours the discovery
        -- gate below; here we only capture the raw positional value.
        local vpest = vm:readValueAtWorld("pestPressure",    x, z)
        local vdis  = vm:readValueAtWorld("diseasePressure", x, z)
        local vcomp = vm:readValueAtWorld("compaction",      x, z)
        if vn or vp or vk or vph or vom or vpest or vdis or vcomp then
            n  = vn  or n
            p  = vp  or p
            k  = vk  or k
            ph = vph or ph
            om = vom or om
            posPest = vpest
            posDisease = vdis
            posCompaction = vcomp
            fromZoneCell = true
        end
    elseif x and z and field.zoneData then
        local zone = SoilConstants.ZONE
        local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
        local cell = field.zoneData[cellKey]
        if cell and (cell.N or 0) > 0 then
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

    -- Compute crop rotation status for external consumers (e.g. FarmTablet).
    -- Delegates to the shared _rotationStatusFor helper so projectRotation() (the
    -- pre-plant foresight read) computes the identical status and can never disagree
    -- with what the player actually gets.
    local rotationStatus = self:_rotationStatusFor(field.lastCrop, field.lastCrop2)

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

    -- Yield efficiency forecast - MUST equal the grain the combine actually receives,
    -- which means OUR modifier AND any upstream reduction another ecosystem mod applies
    -- to the same grain (currently SeasonalCropStress; folded in below as SCS-002).
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
        -- SCS-002: fold in SeasonalCropStress's own upstream drought cut so the number
        -- the player reads is the COMBINED reduction, not just our share of it. Applies
        -- to the frozen branch too - SCS's cut runs live during the pass regardless of
        -- our freeze. Exactly 1.0 (byte-identical to before) when SCS is absent.
        mod = mod * self:_scsYieldKeepFactor(fieldId)
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
        lastCrop3 = field.lastCrop3,  -- #739: third-back crop, already stored+synced, now published for the rotation planner
        rotationStatus = rotationStatus,
        rotationBonusDaysLeft = field.rotationBonusDaysLeft or 0,  -- #739: remaining legume-bonus days, for the planner's timeline
        daysSinceHarvest = field.lastHarvest > 0 and (currentDay - field.lastHarvest) or 0,
        fertilizerApplied = field.fertilizerApplied or 0,
        yieldEfficiency = yieldEfficiency,
        weedPressure = isNonCropField and 0 or (field.weedPressure or 0),
        herbicideActive = (field.herbicideDaysLeft or 0) > 0,
        pestPressure = posPest or (field.pestPressure or 0),
        insecticideActive = (field.insecticideDaysLeft or 0) > 0,
        diseasePressure = posDisease or (field.diseasePressure or 0),
        fungicideActive = (field.fungicideDaysLeft or 0) > 0,
        activeDisease = field.activeDisease,  -- DISEASE_DEFS id of the named infection, or nil
        diseaseDiscovered = field.diseaseDiscovered or false,  -- discovery gate: false = named infection not yet scouted (HUD shows "?")
        -- Scouting-gated display value: nil = unscouted (UI shows "Unscouted"); a
        -- number once scouted. Disease-off shows the value (nothing to hide). The
        -- RAW diseasePressure above stays ungated for the NPC roll and scouting.
        -- The positional disease read, when present, is gated the same way so the
        -- tooltip never leaks an unscouted patch that the map hides.
        shownDiseasePressure = (field.diseaseDiscovered or not (self.settings and self.settings.diseasePressure))
            and (posDisease or (field.diseasePressure or 0)) or nil,
        lastFungicide = field.lastFungicide,
        burnDaysLeft = field.burnDaysLeft or 0,
        amendBurnPenalty = field.amendBurnPenalty or 0,  -- pending lime/OM-on-crop burn (0-1); explains a low yield
        amendBurnRisk = self:isAmendmentBurnRisk(liveFruitTypeIndex, liveGrowthState),  -- (#684) true → liming/manuring NOW would scorch the crop
        -- [SF50-C1] Growth state of the live crop, additive for the harvester panel's
        -- yield estimate. nil when no live fruit is detected (bare/cut field), which the
        -- consumer must read as honest absence, never as a substituted state. Already
        -- computed above for amendBurnRisk; this only stops throwing it away.
        growthState = liveGrowthState,
        nutrientBuffer          = field.nutrientBuffer or {},
        coverageFraction        = field.coverageFraction or 0,
        sessionCoverageFraction = field.sessionCoverageFraction or 0,
        sessionLastProduct      = field.sessionLastProduct,
        compaction = posCompaction or (field.compaction or 0),
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
    -- Scouting-gated: unscouted disease (shownDiseasePressure nil) must not raise
    -- urgency or it would leak what the honest disease layer hides.
    local diseaseDef = (info.shownDiseasePressure or 0) / 100

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
    -- F66 relief marker. Its presence means this save has already had the one-time
    -- resistance reset, so the migration never runs twice. See _finalizeLoadedField.
    setXMLInt(xmlFile, key .. "#f66ResistanceReset", 1)

    -- OM-213 organic premium provenance ledger (farm-level; rides this file as the
    -- safety copy, the same one StateLedger's block mirrors).
    if g_SoilFertilityManager and g_SoilFertilityManager.organic then
        g_SoilFertilityManager.organic:saveFractionsXML(xmlFile, key)
    end

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
            setXMLInt(xmlFile, fieldKey .. "#tilledSinceHarvest", field.tilledSinceHarvest and 1 or 0)  -- #738
            setXMLInt(xmlFile, fieldKey .. "#noTillActive", field.noTillActive and 1 or 0)              -- #738
            setXMLFloat(xmlFile, fieldKey .. "#fertilizerApplied", field.fertilizerApplied or 0)
            setXMLFloat(xmlFile, fieldKey .. "#weedPressure", field.weedPressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#herbicideDaysLeft", field.herbicideDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#pestPressure", field.pestPressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#insecticideDaysLeft", field.insecticideDaysLeft or 0)
            setXMLFloat(xmlFile, fieldKey .. "#diseasePressure", field.diseasePressure or 0)
            setXMLInt(xmlFile, fieldKey .. "#fungicideDaysLeft", field.fungicideDaysLeft or 0)
            setXMLString(xmlFile, fieldKey .. "#activeDisease", field.activeDisease or "")
            setXMLInt(xmlFile, fieldKey .. "#diseaseDiscovered", field.diseaseDiscovered and 1 or 0)
            setXMLString(xmlFile, fieldKey .. "#lastFungicide", field.lastFungicide or "")
            -- CD-10 re-onset cooldown. Persisted because a cooldown a save-and-reload
            -- defeats is not a cooldown -- it would silently do nothing. Server-side only;
            -- clients never compute onset, so it is deliberately not synced.
            if (field.hybridBlockedUntilDay or 0) > 0 then
                setXMLInt(xmlFile, fieldKey .. "#hybridBlockedUntilDay", field.hybridBlockedUntilDay)
            end
            -- CD-9: Serialize per-MOA resistance as comma-separated mode:score pairs
            if field.resistance then
                local parts = {}
                for mode, val in pairs(field.resistance) do
                    if val > 0 then parts[#parts + 1] = mode .. ":" .. val end
                end
                if #parts > 0 then
                    setXMLString(xmlFile, fieldKey .. "#resistance", table.concat(parts, ","))
                end
            end
            setXMLInt(xmlFile, fieldKey .. "#dryDayCount", field.dryDayCount or 0)
            setXMLInt(xmlFile, fieldKey .. "#burnDaysLeft", field.burnDaysLeft or 0)
            setXMLInt(xmlFile, fieldKey .. "#lastAlertSeason", field.lastAlertSeason or 0)
            setXMLFloat(xmlFile, fieldKey .. "#coverageFraction", field.coverageFraction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#compaction", field.compaction or 0)
            setXMLFloat(xmlFile, fieldKey .. "#amendBurnPenalty", field.amendBurnPenalty or 0)

            -- Organic certification state (state / transition clock / breaches)
            if g_SoilFertilityManager and g_SoilFertilityManager.organic then
                g_SoilFertilityManager.organic:saveFieldState(xmlFile, fieldKey, field)
            end

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
    self:_beginF66ResistanceRelief((getXMLInt(xmlFile, key .. "#f66ResistanceReset") or 0) == 1)

    -- OM-213 organic premium provenance ledger (absent on older saves = empty).
    if g_SoilFertilityManager and g_SoilFertilityManager.organic then
        g_SoilFertilityManager.organic:loadFractionsXML(xmlFile, key)
    end

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
            tilledSinceHarvest = (getXMLInt(xmlFile, fieldKey .. "#tilledSinceHarvest") or 0) == 1,  -- #738
            noTillActive = (getXMLInt(xmlFile, fieldKey .. "#noTillActive") or 0) == 1,               -- #738
            fertilizerApplied = getXMLFloat(xmlFile, fieldKey .. "#fertilizerApplied") or 0,
            weedPressure = getXMLFloat(xmlFile, fieldKey .. "#weedPressure") or 0,
            herbicideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#herbicideDaysLeft") or 0,
            pestPressure = getXMLFloat(xmlFile, fieldKey .. "#pestPressure") or 0,
            insecticideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#insecticideDaysLeft") or 0,
            diseasePressure = getXMLFloat(xmlFile, fieldKey .. "#diseasePressure") or 0,
            fungicideDaysLeft = getXMLInt(xmlFile, fieldKey .. "#fungicideDaysLeft") or 0,
            activeDisease = getXMLString(xmlFile, fieldKey .. "#activeDisease"),
            activeDiseaseSeverity = 1.0,
            diseaseDiscovered = (getXMLInt(xmlFile, fieldKey .. "#diseaseDiscovered") or 0) == 1,
            lastFungicide = getXMLString(xmlFile, fieldKey .. "#lastFungicide"),
            hybridBlockedUntilDay = getXMLInt(xmlFile, fieldKey .. "#hybridBlockedUntilDay"),
            -- CD-9: Deserialize per-MOA resistance from comma-separated mode:score pairs
            resistance = (function()
                local rt = {}
                local raw = getXMLString(xmlFile, fieldKey .. "#resistance")
                if raw then
                    for part in raw:gmatch("([^,]+)") do
                        local mode, score = part:match("^(.+):([%d.]+)$")
                        if mode and score then rt[mode] = tonumber(score) or 0 end
                    end
                end
                return rt
            end)(),
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

        -- Organic certification state (leaves the field conventional if absent)
        if g_SoilFertilityManager and g_SoilFertilityManager.organic then
            g_SoilFertilityManager.organic:loadFieldState(xmlFile, fieldKey, self.fieldData[fieldId])
        end

        -- Load daily application throttles
        self.herbicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#herbicideAppliedDay") or 0
        self.insecticideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#insecticideAppliedDay") or 0
        self.fungicideAppliedDay[fieldId] = getXMLInt(xmlFile, fieldKey .. "#fungicideAppliedDay") or 0

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

        -- Shared post-read finalization: fieldArea refresh (#475/#476), daily
        -- coverage restore (#640/#608), empty->nil, disease severity, and the
        -- compaction-sum rebuild from per-cell zoneData (#656). Same helper the
        -- StateLedger table-load path uses, so the two loaders can never drift.
        self:_finalizeLoadedField(fieldId, self.fieldData[fieldId])

        index = index + 1
    end

    self:info("Loaded data for %d fields", index)
    self:_endF66ResistanceRelief()
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

-- =========================================================
-- StateLedger table round-trip (delegate-when-present, #bedrock)
-- =========================================================
-- SoilFertilizer ships standalone, so soilData.xml stays the fallback/safety
-- copy. When FS25_StateLedger is installed it becomes the load source of truth
-- via these plain-table serializers. Both load paths (soilData.xml and the
-- ledger table) funnel through _finalizeLoadedField so their post-read fixups
-- can never diverge.

-- Shared post-read finalization for one field, format-agnostic. Runs after the
-- raw scalars + zoneData are in place. Preserves the exact ordering the XML
-- loader always used: coverage restore uses the SAVED fieldArea, THEN fieldArea
-- is refreshed from the farmland, THEN compaction is rebuilt from that area.
--- F66 RELIEF: arm (or stand down) the one-time resistance reset for this load.
---
--- CD-9 shipped 2026-07-29 with a resistance build that counted every boom section as a
--- full application, so a mode saturated inside the first second of the first pass. The
--- meter landed 2026-08-01 (b60677f8), but the damage is PERSISTED -- fields sit pegged at
--- the ceiling, and at DECAY_MONTHLY that is roughly a year of game time to clear.
---
--- RULED (Arissani, 2026-08-01): the player never made that choice, the bug did, so the
--- fields should not stay burned. Shape ruled by Tyson the same day: clear rather than
--- rescale. Rescaling sounds gentler but the inflation factor is UNKNOWABLE -- it depended
--- on boom width and framerate -- so any divisor would be invented. And only ~3 days
--- separate the two builds, in which honest accrual could reach at most a pass or two out
--- of ten. A wrong number is worse than a clean slate.
---
--- Runs from _finalizeLoadedField, which BOTH load paths funnel through, so the XML and
--- StateLedger saves cannot diverge. The marker is written on every save from here on, so
--- this can never fire twice on the same save.
---@param alreadyDone boolean   true when the save carries the marker
function SoilFertilitySystem:_beginF66ResistanceRelief(alreadyDone)
    self._f66ReliefPending = not alreadyDone
    self._f66ReliefCleared = 0
end

--- Log the outcome once, after a load has finished walking its fields.
function SoilFertilitySystem:_endF66ResistanceRelief()
    if not self._f66ReliefPending then return end
    self._f66ReliefPending = false
    if (self._f66ReliefCleared or 0) > 0 then
        self:info("F66 relief: cleared stored fungicide resistance on %d field(s). "
            .. "Those scores were inflated by the pre-2026-08-01 meter defect, not earned. "
            .. "Resistance now builds correctly at one application per full-rate pass.",
            self._f66ReliefCleared)
    end
end

function SoilFertilitySystem:_finalizeLoadedField(fieldId, f)
    if type(f) ~= "table" then return end

    -- F66 relief (see _beginF66ResistanceRelief). One-time, both load paths.
    if self._f66ReliefPending and type(f.resistance) == "table" and next(f.resistance) ~= nil then
        f.resistance = {}
        self._f66ReliefCleared = (self._f66ReliefCleared or 0) + 1
    end

    -- Restore DAILY coverage area from the saved fraction (saved fieldArea,
    -- before the farmland refresh below). Session coverage stays 0 on purpose
    -- (#640/#608).
    f.coveredAreaHa = (f.coverageFraction or 0) * (f.fieldArea or 1.0)

    -- Refresh fieldArea - prefer the crop polygon area so Pass% uses the right
    -- denominator; fall back to farmland area (#475/#476).
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
            f.fieldArea = bestArea
        end
    end

    -- Empty strings -> nil (a "" sownCrop would hide the real crop via the
    -- `sownCrop or lastCrop` fallback right after a reload).
    if f.lastCrop  == "" then f.lastCrop  = nil end
    if f.lastCrop2 == "" then f.lastCrop2 = nil end
    if f.lastCrop3 == "" then f.lastCrop3 = nil end
    if f.sownCrop  == "" then f.sownCrop  = nil end

    -- Named disease: empty -> nil, and rebuild the cached yield severity.
    if f.activeDisease == "" then f.activeDisease = nil end
    if f.lastFungicide == "" then f.lastFungicide = nil end
    if f.activeDisease and SoilDiseaseSystem then
        f.activeDiseaseSeverity = SoilDiseaseSystem.yieldSeverity(f.activeDisease)
    end

    -- Rebuild the compaction running sum + field-average from per-cell zoneData
    -- (the #656 fix: onCompaction stores per-cell in zoneData, never the legacy
    -- compactionCells table, so the scalar must be reconstructed here).
    local zone = SoilConstants.ZONE
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
end

-- Build a plain Lua table snapshot of all persisted soil state. Mirrors exactly
-- the fields saveToXMLFile writes (same defaults, same "frozen-yield-only-when-
-- live" and "organic-only-when-present" rules), so a ledger save equals an XML
-- save. StateLedger's serializer round-trips arbitrary nested tables.
function SoilFertilitySystem:getSoilStateTable()
    local defaults = SoilConstants.FIELD_DEFAULTS
    local out = { lastUpdateDay = self.lastUpdateDay or 0, f66ResistanceReset = 1, fields = {} }
    if type(self.fieldData) ~= "table" then return out end

    for fieldId, field in pairs(self.fieldData) do
        if type(field) == "table" then
            local e = {
                fieldArea             = field.fieldArea or 1.0,
                nitrogen              = field.nitrogen or defaults.nitrogen,
                phosphorus            = field.phosphorus or defaults.phosphorus,
                potassium             = field.potassium or defaults.potassium,
                organicMatter         = field.organicMatter or defaults.organicMatter,
                pH                    = field.pH or defaults.pH,
                lastCrop              = field.lastCrop or "",
                lastCrop2             = field.lastCrop2 or "",
                lastCrop3             = field.lastCrop3 or "",
                sownCrop              = field.sownCrop or "",
                rotationBonusDaysLeft = field.rotationBonusDaysLeft or 0,
                lastHarvest           = field.lastHarvest or 0,
                fertilizerApplied     = field.fertilizerApplied or 0,
                weedPressure          = field.weedPressure or 0,
                herbicideDaysLeft     = field.herbicideDaysLeft or 0,
                pestPressure          = field.pestPressure or 0,
                insecticideDaysLeft   = field.insecticideDaysLeft or 0,
                diseasePressure       = field.diseasePressure or 0,
                fungicideDaysLeft     = field.fungicideDaysLeft or 0,
                activeDisease         = field.activeDisease or "",
                diseaseDiscovered     = field.diseaseDiscovered or false,
                lastFungicide         = field.lastFungicide or "",
                hybridBlockedUntilDay = field.hybridBlockedUntilDay,   -- CD-10 re-onset cooldown
                dryDayCount           = field.dryDayCount or 0,
                burnDaysLeft          = field.burnDaysLeft or 0,
                lastAlertSeason       = field.lastAlertSeason or 0,
                coverageFraction      = field.coverageFraction or 0,
                compaction            = field.compaction or 0,
                amendBurnPenalty      = field.amendBurnPenalty or 0,
                herbicideAppliedDay   = self.herbicideAppliedDay[fieldId] or 0,
                insecticideAppliedDay = self.insecticideAppliedDay[fieldId] or 0,
                fungicideAppliedDay   = self.fungicideAppliedDay[fieldId] or 0,
            }
            -- CD-9: Per-MOA resistance scores (saved only when populated).
            if field.resistance and next(field.resistance) then
                local rt = {}
                for mode, val in pairs(field.resistance) do
                    if val > 0 then rt[mode] = val end
                end
                if next(rt) then e.resistance = rt end
            end
            -- Frozen yield only while a freeze is live (matches XML save).
            if field.frozenYieldModifier and field.frozenYieldFruitType then
                e.frozenYieldModifier  = field.frozenYieldModifier
                e.frozenYieldFruitType = field.frozenYieldFruitType
            end
            -- Organic certification sub-table (only when present).
            if field.organic then
                e.organic = {
                    state        = field.organic.state,
                    startDay     = field.organic.startDay or 0,
                    certifiedDay = field.organic.certifiedDay or 0,
                    breaches     = field.organic.breaches or 0,
                }
            end
            -- Per-area zone cells.
            if field.zoneData then
                local zt = {}
                for cellKey, cell in pairs(field.zoneData) do
                    zt[cellKey] = {
                        N = cell.N or 0, P = cell.P or 0, K = cell.K or 0,
                        pH = cell.pH or 6.0, OM = cell.OM or 0,
                        weedPressure    = cell.weedPressure or 0,
                        pestPressure    = cell.pestPressure or 0,
                        diseasePressure = cell.diseasePressure or 0,
                        compaction      = cell.compaction or 0,
                    }
                end
                e.zoneData = zt
            end
            out.fields[fieldId] = e
        end
    end

    -- OM-213 organic premium provenance ledger (rides the same block StateLedger holds).
    if g_SoilFertilityManager and g_SoilFertilityManager.organic
       and g_SoilFertilityManager.organic.getFractionsTable then
        out.organicFractions = g_SoilFertilityManager.organic:getFractionsTable()
    end
    return out
end

-- Apply a plain-table snapshot (from getSoilStateTable / StateLedger) back into
-- fieldData. Mirrors loadFromXMLFile's raw read + clamps, then routes every
-- field through the shared _finalizeLoadedField. Returns the field count.
function SoilFertilitySystem:applySoilStateTable(data)
    local defaults = SoilConstants.FIELD_DEFAULTS
    self.fieldData = {}
    local _curDay = (g_currentMission and g_currentMission.environment
                     and g_currentMission.environment.currentDay) or 0

    if type(data) ~= "table" then
        self.lastUpdateDay = _curDay
        return 0
    end
    self.lastUpdateDay = data.lastUpdateDay or _curDay
    self:_beginF66ResistanceRelief((data.f66ResistanceReset or 0) == 1)

    local count = 0
    local fields = data.fields or {}
    for fieldId, e in pairs(fields) do
        if type(e) == "table" then
            local f = {
                fieldArea             = e.fieldArea or 1.0,
                nitrogen              = math.max(0, math.min(100, e.nitrogen or defaults.nitrogen)),
                phosphorus            = math.max(0, math.min(100, e.phosphorus or defaults.phosphorus)),
                potassium             = math.max(0, math.min(100, e.potassium or defaults.potassium)),
                organicMatter         = math.max(0, math.min(10, e.organicMatter or defaults.organicMatter)),
                pH                    = math.max(5.0, math.min(8.5, e.pH or defaults.pH)),
                lastCrop              = e.lastCrop,
                lastCrop2             = e.lastCrop2,
                lastCrop3             = e.lastCrop3,
                sownCrop              = e.sownCrop,
                rotationBonusDaysLeft = e.rotationBonusDaysLeft or 0,
                lastHarvest           = e.lastHarvest or 0,
                fertilizerApplied     = e.fertilizerApplied or 0,
                weedPressure          = e.weedPressure or 0,
                herbicideDaysLeft     = e.herbicideDaysLeft or 0,
                pestPressure          = e.pestPressure or 0,
                insecticideDaysLeft   = e.insecticideDaysLeft or 0,
                diseasePressure       = e.diseasePressure or 0,
                fungicideDaysLeft     = e.fungicideDaysLeft or 0,
                activeDisease         = e.activeDisease,
                activeDiseaseSeverity = 1.0,
                diseaseDiscovered     = e.diseaseDiscovered or false,
                lastFungicide         = e.lastFungicide,
                hybridBlockedUntilDay = e.hybridBlockedUntilDay,   -- CD-10 re-onset cooldown
                resistance = (function() local rt = {}; if e.resistance and type(e.resistance) == "table" then for k, v in pairs(e.resistance) do rt[k] = v end end; return rt end)(),
                dryDayCount           = e.dryDayCount or 0,
                burnDaysLeft          = e.burnDaysLeft or 0,
                amendBurnPenalty      = e.amendBurnPenalty,
                frozenYieldModifier   = e.frozenYieldModifier,
                frozenYieldFruitType  = e.frozenYieldFruitType,
                coverageFraction      = e.coverageFraction or 0,
                lastAlertSeason       = e.lastAlertSeason,
                compaction            = 0,
                compactionCells       = {},
                compactionCellDays    = {},
                compactionSum         = 0,
                compactionTotalCells  = 0,
                initialized           = true,
                nutrientBuffer        = {},
                zoneData              = {},
                coveredAreaHa         = 0,
                dailyCoverageCells    = {},
                sessionCoverageHa     = 0,
                sessionCoverageFraction = 0,
                sessionCoverageCells  = {},
                sessionLastProduct    = nil,
            }
            -- Organic certification (leaves the field conventional if absent).
            if e.organic and e.organic.state and e.organic.state ~= "" then
                f.organic = {
                    state        = e.organic.state,
                    startDay     = e.organic.startDay or 0,
                    certifiedDay = e.organic.certifiedDay or 0,
                    breaches     = e.organic.breaches or 0,
                }
            end
            -- Daily application throttles.
            self.herbicideAppliedDay[fieldId]   = e.herbicideAppliedDay or 0
            self.insecticideAppliedDay[fieldId] = e.insecticideAppliedDay or 0
            self.fungicideAppliedDay[fieldId]   = e.fungicideAppliedDay or 0
            -- Per-area zone cells.
            if e.zoneData then
                for cellKey, cell in pairs(e.zoneData) do
                    f.zoneData[cellKey] = {
                        N = cell.N or 0, P = cell.P or 0, K = cell.K or 0,
                        pH = cell.pH or 6.0, OM = cell.OM or 0,
                        weedPressure    = cell.weedPressure or 0,
                        pestPressure    = cell.pestPressure or 0,
                        diseasePressure = cell.diseasePressure or 0,
                        compaction      = cell.compaction or 0,
                    }
                end
            end
            self.fieldData[fieldId] = f
            self:_finalizeLoadedField(fieldId, f)
            count = count + 1
        end
    end
    self:_endF66ResistanceRelief()

    -- OM-213 organic premium provenance ledger (StateLedger block mirror).
    if g_SoilFertilityManager and g_SoilFertilityManager.organic
       and g_SoilFertilityManager.organic.applyFractionsTable then
        g_SoilFertilityManager.organic:applyFractionsTable(data.organicFractions)
    end
    return count
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

    -- 3. Write per-pixel compaction
    do
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
        -- REFINED: runtime value map (~2 m/px) - crisp wheel-trail stamps
        if self:vmAvailable() then
            self.valueMaps:writeValueAtWorld("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
        end
        -- Legacy map-shipped GRLE layer (kept for maps that declare it)
        if self.layerSystem and self.layerSystem.available then
            self.layerSystem:updatePixelForField("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
        end
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

    -- Write per-pixel compaction relief
    do
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
        if self:vmAvailable() then
            self.valueMaps:writeValueAtWorld("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
        end
        if self.layerSystem and self.layerSystem.available then
            self.layerSystem:updatePixelForField("compaction", worldX, worldZ, newVal, zone.CELL_SIZE * 0.5)
        end
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

    -- REFINED: mirror the decay onto the per-pixel compaction map as a uniform
    -- shift (additive approximation of the ratio fade; accumulates via _vmPend
    -- so slow daily decay is not lost to raw quantisation).
    if self:vmAvailable() then
        self:_vmQueueFieldDelta(field, "compaction", -(oldAvg - newAvg))
    end
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
        SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
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

-- ============================================================
-- SF-20 RELIEF CHECK (acceptance instrument)
--
-- The relief weight's acceptance is three in-game checks that were, until now,
-- "look at the map and judge". That is not a test anybody can pass or fail
-- honestly, and it is not something a second person can verify the same way.
-- This runs all three and reports numbers.
--
--   DIRECTION     low ground must read HIGHER organic matter than high ground
--   CONSERVATION  the field-level figure must not move while cells vary
--   MAGNITUDE     peak-to-peak spread should be about the amplitude, no more
--
-- Read-only. Samples terrain height and the organicMatter value map on the same
-- bounded grid the painter used, so it measures the thing that shipped rather
-- than recomputing what it thinks should be there.
-- ============================================================
function SoilFertilitySystem:reliefCheck(fieldId)
    if not self:vmAvailable() then return nil, "value maps unavailable" end
    local field = self.fieldData[fieldId]
    if field == nil then return nil, string.format("field %s not tracked", tostring(fieldId)) end
    local verts = self:_getFieldPolyVerts(fieldId, field)
    if verts == nil or #verts < 3 then return nil, "field has no usable polygon" end
    if g_terrainNode == nil or getTerrainHeightAtWorldPos == nil then
        return nil, "terrain unavailable"
    end

    local relief = SoilConstants.RELIEF or {}
    local step = relief.BLOCK_SIZE or 8
    local minX, maxX, minZ, maxZ = verts[1].x, verts[1].x, verts[1].z, verts[1].z
    for i = 2, #verts do
        local v = verts[i]
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end

    local vm = self.valueMaps
    local lo, hi = nil, nil        -- lowest / highest GROUND, with their OM
    local omMin, omMax = nil, nil  -- OM extremes regardless of height
    local n, omSum = 0, 0
    local x = minX + step * 0.5
    while x <= maxX and n < 4000 do
        local z = minZ + step * 0.5
        while z <= maxZ and n < 4000 do
            if _isPointInPoly(x, z, verts) then
                local okH, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, x, 0, z)
                local om = vm:readValueAtWorld("organicMatter", x, z)
                if okH and type(h) == "number" and type(om) == "number" then
                    n = n + 1
                    omSum = omSum + om
                    if lo == nil or h < lo.h then lo = { h = h, om = om, x = x, z = z } end
                    if hi == nil or h > hi.h then hi = { h = h, om = om, x = x, z = z } end
                    if omMin == nil or om < omMin then omMin = om end
                    if omMax == nil or om > omMax then omMax = om end
                end
            end
            z = z + step
        end
        x = x + step
    end

    if n < 2 then return nil, "not enough readable samples" end

    local reliefRange = hi.h - lo.h
    local flatGuard = relief.MIN_RANGE or 0
    local amplitude = (field.organicMatter or 0)
        * (relief.AMPLITUDE_FRACTION or 0) * (relief.AGRONOMY_SCALE or 1)

    return {
        samples      = n,
        reliefRange  = reliefRange,
        flatGuard    = flatGuard,
        isFlat       = reliefRange < flatGuard,
        lowGroundOM  = lo.om,
        highGroundOM = hi.om,
        omSpread     = (omMax or 0) - (omMin or 0),
        omSampledMean= omSum / n,
        fieldOM      = field.organicMatter or 0,
        amplitude    = amplitude,
    }
end
