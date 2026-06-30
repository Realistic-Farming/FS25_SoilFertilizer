-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Hook Manager
-- =========================================================
-- Manages installation and cleanup of game engine hooks
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class HookManager
HookManager = {}
local HookManager_mt = Class(HookManager)

function HookManager.new()
    local self = setmetatable({}, HookManager_mt)
    self.hooks = {}
    self.installed = false
    self._sectionScratch = {}   -- reused scratch table for sprayer section loops
    return self
end

--- Helper to get field ID from world coordinates
---@param x number World X coordinate
---@param z number World Z coordinate
---@return number|nil fieldId
function HookManager:getFieldIdAtWorldPosition(x, z, skipNegativeCache)
    -- Initialize the native MapDataGrid cache on first use (requires map to be loaded)
    if not self.fieldIdCache then
        local mapSize = g_currentMission and g_currentMission.terrainSize or 2048
        -- PHASE 5: Scale block size with map size.
        -- A fixed 2m block on a 16x map (16384m) creates a 8192×8192 grid — 64M cells.
        -- Doubling block size per doubling of map keeps the cell count constant (~4M).
        --   4x  (4096m):  blockSize=2m  → 2048×2048 grid
        --   8x  (8192m):  blockSize=4m  → 2048×2048 grid
        --   16x (16384m): blockSize=8m  → 2048×2048 grid
        local BASE_MAP   = 4096
        local BASE_BLOCK = 2
        local blockSize  = math.max(BASE_BLOCK, math.floor(BASE_BLOCK * (mapSize / BASE_MAP)))
        SoilLogger.debug("[PERF-P5] MapDataGrid: map=%.0fm  blockSize=%dm", mapSize, blockSize)
        local ok, result = pcall(MapDataGrid.createFromBlockSize, mapSize, blockSize)
        if ok and result then
            self.fieldIdCache = result
        else
            SoilLogger.warning("[PERF-P5] MapDataGrid.createFromBlockSize failed (%s) — cache disabled", tostring(result))
            self.fieldIdCache = false  -- false = permanently disabled, avoids retry spam
        end
    end

    -- Fast path: Check the native C++ backed spatial grid cache
    if self.fieldIdCache then
        local cachedId = self.fieldIdCache:getValueAtWorldPos(x, z)
        if cachedId ~= nil then
            if cachedId == -1 then
                -- Known-empty at map load. Skip the fast-path return when the caller
                -- is a tillage hook (skipNegativeCache=true): player-created fields won't
                -- exist in the cache yet and need a live slow-path re-query.
                if not skipNegativeCache then return nil end
                -- Fall through to slow path below
            else
                return cachedId
            end
        end
    end

    -- Slow path: Direct field polygon lookup (computationally expensive)
    local fieldId = nil
    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
        local field = g_fieldManager:getFieldAtWorldPosition(x, z)
        if field and field.farmland and field.farmland.id then
            fieldId = field.farmland.id
        end
    end

    -- Fallback to farmland detection
    if not fieldId and g_farmlandManager and type(g_farmlandManager.getFarmlandAtWorldPosition) == "function" then
        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        if farmland and farmland.id then
            fieldId = farmland.id
        end
    end

    if not fieldId then
        SoilLogger.debug("[FieldResolve] Miss at (%.1f,%.1f) — fieldMgr=%s/%s farmMgr=%s/%s",
            x, z,
            tostring(g_fieldManager ~= nil),
            tostring(g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function"),
            tostring(g_farmlandManager ~= nil),
            tostring(g_farmlandManager and type(g_farmlandManager.getFarmlandAtWorldPosition) == "function"))
    end

    -- Cache the result (-1 marks known-empty to prevent repeated slow-path lookups)
    if self.fieldIdCache then
        self.fieldIdCache:setValueAtWorldPos(x, z, fieldId or -1)
    end

    return fieldId
end

--- Helper to get field ID from work area coordinates
---@param sx number Start X
---@param sz number Start Z
---@param wx number Width X
---@param wz number Width Z
---@param hx number Height X
---@param hz number Height Z
---@return number|nil fieldId
function HookManager:getFieldIdFromArea(sx, sz, wx, wz, hx, hz)
    -- Calculate center point of the parallelogram work area
    local centerX = (wx + hx) / 2
    local centerZ = (wz + hz) / 2
    return self:getFieldIdAtWorldPosition(centerX, centerZ)
end

--- Install all game hooks for the soil system
--- Installs hooks for harvest, fertilizer (all sprayer/spreader types), plowing, ownership, and weather
--- Stores references for proper cleanup on uninstall
---@param soilSystem SoilFertilitySystem The soil system instance to connect hooks to
function HookManager:installAll(soilSystem)
    if self.installed then
        SoilLogger.warning("Hooks already installed, skipping re-installation")
        return
    end

    local successCount = 0
    local failCount = 0

    SoilLogger.info("Installing event hooks...")

    -- Harvest hook: direct-cut combines and forage harvesters (Cutter spec)
    local harvestOk = self:installHarvestHook()
    if harvestOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Yield modifier hook: applies soil-fertility yield reduction via the combine hopper
    -- (separate from addCutterArea for RealisticHarvesting compatibility — see issue #284)
    local yieldModOk = self:installYieldModifierHook()
    if yieldModOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Mower hook: forage crops cut to windrow (grass, alfalfa, clover, mowed triticale…)
    local mowerOk = self:installMowerHook()
    if mowerOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Mower yield hook (#696): windrow output scales with soil nutrients via conversionFactor
    local mowerYieldOk = self:installMowerYieldHook()
    if mowerYieldOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Fertilizer application hook (covers ALL sprayers + spreaders via Sprayer specialization)
    local sprayerAreaOk = self:installSprayerAreaHook()
    if sprayerAreaOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Field ownership changes
    local ownershipOk = self:installOwnershipHook()
    if ownershipOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Native FIELD INFO injection: appends soil grade/yield/N-P-K/etc rows directly into
    -- the base game's own FIELD INFO panel (PlayerHUDUpdater.fieldAddFarmland), instead of
    -- a separate floating panel. Client-only; no-ops server-side / when PlayerHUDUpdater
    -- isn't available.
    local nativeFieldInfoOk = self:installNativeFieldInfoHook()
    if nativeFieldInfoOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Weather/environment effects
    local weatherOk = self:installWeatherHook()
    if weatherOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Plowing benefits (cultivators + deep-tillage via Cultivator spec)
    local plowingOk = self:installPlowingHook()
    if plowingOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Dedicated plow implements (Plow.onEndWorkAreaProcessing)
    local dedicatedPlowOk = self:installDedicatedPlowHook()
    if dedicatedPlowOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- #674: crop-biomass probe — samples the standing crop at the work position in
    -- onStartWorkAreaProcessing (BEFORE the tool clears the fruit) and stashes a 0..1
    -- biomass factor on the vehicle, which the plow/cultivator end hooks consume to award
    -- a green-manure OM boost. Installed for both Cultivator and Plow specs.
    if self:installCropBiomassProbe(Cultivator, "Cultivator") then successCount = successCount + 1 else failCount = failCount + 1 end
    if self:installCropBiomassProbe(Plow, "Plow") then successCount = successCount + 1 else failCount = failCount + 1 end

    -- #674: mulcher hook — chopping crop/stubble returns surface biomass to the soil as OM
    local mulcherOk = self:installMulcherHook()
    if mulcherOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Mechanical weed removal (Weeder.onEndWorkAreaProcessing — weeders, inter-row hoes)
    local weedControlOk = self:installWeederHook()
    if weedControlOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Strip-till / ridge tiller (RidgeTiller.processRidgeTillerArea — Orthman-style implements)
    local ridgeTillerOk = self:installRidgeTillerHook()
    if ridgeTillerOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Patch vanilla fill units to accept custom fertilizer types
    local fillUnitOk = self:installFillUnitHook()
    if fillUnitOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Allow "BUY" refill mode to work with custom fill types (issue #125)
    local purchaseRefillOk = self:installPurchaseRefillHook()
    if purchaseRefillOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Fix AI external fill: prevent empty-tank fallback to vanilla FERTILIZER for our types
    local extFillOk = self:installExternalFillHook()
    if extFillOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- CRITICAL: propagate the getExternalFill wrapper down to vehicleType.functions and
    -- live vehicle instances. SpecializationUtil.copyTypeFunctionsInto copies function
    -- refs directly onto vehicle instances at load time, so patching Sprayer.getExternalFill
    -- on the class table alone NEVER reaches already-loaded vehicles (issue #205).
    if extFillOk then
        self:propagateExternalFillHookToLiveVehicles()
    end

    -- Rate multiplier → wap.usage + wap.usagePerMin (event listener, reliable class-table dispatch).
    -- Must run before installSprayerUsageHook so the chain is: vanilla sets wap.usage → this hook
    -- scales it → onEndWorkAreaProcessing reads the already-scaled value.
    local sprayStartOk = self:installSprayerStartHook()
    if sprayStartOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Speed-based area-normalized consumption (tank-drain path).
    -- Replaces vanilla getSprayerUsage's speedLimit with actual lastSpeed so product
    -- consumption scales correctly with area covered at the vehicle's real speed.
    local sprayUsageOk = self:installSprayerUsageHook()
    if sprayUsageOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Opt custom fill types into the vanilla "external fill" skip-depletion path.
    -- This is the canonical BUY-mode fix (issue #205): by telling the base engine that
    -- our tank is externally filled when BUY mode is active, Sprayer:onStartWorkAreaProcessing
    -- clears sprayVehicle/sprayFillUnit to nil and onEndWorkAreaProcessing NEVER calls
    -- addFillUnitFillLevel — no tank drain, no race, no refill, no FillUnit hook needed.
    local buyOptInOk = self:installExternalFillOptInHook()
    if buyOptInOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Fix fill plane and fill volume texture for custom fill types
    local fillMatOk = self:installFillTypeMaterialHook()
    if fillMatOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Sowing / planting events (Fix Issue #4)
    local sowingOk = self:installSowingHook()
    if sowingOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Client connection sync (Fix Issue #2)
    local clientJoinOk = self:installClientJoinHook()
    if clientJoinOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Bulk/silo storage support (#605): ensure the onLoad hook is installed (no-op if the
    -- early install already ran) and retroactively patch any silos already in the world.
    local siloOk = self:installSiloFillTypeHook()
    if siloOk then successCount = successCount + 1 else failCount = failCount + 1 end
    self:patchExistingSilos()

    SoilLogger.info("Hook installation complete: %d/%d successful, %d failed",
        successCount, successCount + failCount, failCount)

    if failCount > 0 then
        SoilLogger.warning("Some hooks failed to install - mod functionality may be limited")
    end

    -- Register custom fill types in SprayTypeManager so they get correct tank
    -- drain rates and visual spray effects. Must run after hooks (g_sprayTypeManager
    -- is populated from map XML before loadMission00Finished fires).
    self:registerCustomSprayTypes()

    -- Remap custom fill types to vanilla visual equivalents for all effect classes
    -- (FertilizerMotionPathEffect, ShaderPlaneEffect, etc.). Two-layer approach:
    -- primary hook on g_effectManager:setEffectTypeInfo intercepts before storage;
    -- backup hook on g_motionPathEffectManager:getSharedMotionPathEffect catches any
    -- indices that bypass setEffectTypeInfo. Must run in both full and viewer-mode paths.
    self:installEffectTypeHook()

    -- Inject custom fill type names into each vehicle's sprayType.fillTypes arrays so
    -- that Sprayer:getIsSprayTypeActive returns true for our custom types, triggering
    -- the correct sprayType.effects visual. Also hooks Sprayer.onLoad so newly bought
    -- or spawned vehicles receive the same injection.
    self:installSprayTypeEffectsHook()

    -- Force-refresh sprayer/spreader effects on all vehicles already in memory.
    -- Must run AFTER installSprayTypeEffectsHook so the fill type arrays are patched
    -- before updateSprayerEffects re-evaluates getActiveSprayType.
    self:refreshAllSprayerEffects()

    -- Remap wap.sprayType to vanilla index inside processSprayerArea so that the
    -- native C++ FSDensityMapUtil.updateSprayArea receives a known spray type index
    -- and actually writes the ground density map (fertilizer/herbicide visual overlay).
    -- Must run AFTER registerCustomSprayTypes so our custom spray type indices exist.
    self:installDensityMapSprayHook()

    -- Direct client-side visual effect management for custom fill types.
    -- Bypasses the getActiveSprayType/setEffectTypeInfo chain that silently fails for
    -- FertilizerMotionPathEffect when the fill type has no registered motion path data.
    -- Hooks onUpdateTick (event listener, dynamic dispatch) so it reaches all vehicles.
    self:installSprayerVisualEffectHook()

    -- Guard PF NitrogenMap against divide-by-zero when a zero-N fill type (e.g. LIQUID_POTASH)
    -- is loaded in a sprayer. PF's getFertilizerUsageByNitrogenAmount divides by the fill type's
    -- N content, which is 0 for K-only and P-only products. Optional: no-op when PF is absent.
    self:installPFNitrogenMapHook()

    -- Smart Soil Sensor: per-section spray suppression based on SF soil data.
    -- Appended AFTER installDensityMapSprayHook so cleanup unwinds correctly.
    self:installSectionControlHook()

    -- System 2: See & Spray — per-cell spot-spray suppression (appended after Smart Sensor).
    self:installSeeAndSprayHook()

    -- System 3: Variable Rate — per-section rate pre-computation (appended after See & Spray).
    self:installVariableRateHook()

    -- System 4: Overlap Prevention — density-map SPRAY_LEVEL nozzle shutoff on already-sprayed ground.
    -- Runs after VariableRate so the rate computation still sees the original isActive states.
    self:installOverlapPreventionHook()

    -- Section state preserver: saves VWW section.isActive before suppression hooks run and
    -- restores it after work areas are processed. Installed LAST so the prepend executes FIRST,
    -- and cleanup unwinds FIRST in reverse order. Without this, SmartSensor/SeeAndSpray set
    -- section.isActive=false permanently (VWW only resets it via setSectionsActive/CTRL+Z),
    -- causing the boom to lock at minimum width until the player manually cycles the width.
    self:installSectionStatePreserver()

    self.installed = true
end

--- Uninstall all hooks and restore original functions
--- Called on mod unload to prevent hook accumulation
function HookManager:uninstallAll()
    if not self.installed then return end

    for i = #self.hooks, 1, -1 do
        local hook = self.hooks[i]
        if hook.cleanup then
            hook.cleanup()
            SoilLogger.debug("Cleaned up: %s", hook.name or "?")
        elseif hook.target and hook.key and hook.original then
            hook.target[hook.key] = hook.original
            SoilLogger.debug("Restored original: %s", hook.name or hook.key)
        end
    end

    -- Remove the addModEventListener client-join listener
    if self._clientJoinListener then
        removeModEventListener(self._clientJoinListener)
        self._clientJoinListener = nil
    end
    self.hooks = {}
    self.installed = false
    SoilLogger.info("All hooks uninstalled")
end

--- Register a hook for later cleanup.
---@param target table The object containing the function
---@param key string The function key on the target
---@param original function The original function reference before hooking
---@param name string A human-readable name for logging
function HookManager:register(target, key, original, name)
    table.insert(self.hooks, {
        target = target,
        key = key,
        original = original,
        name = name or key
    })
end

-- =========================================================
-- SPRAY TYPE REGISTRATION: custom fill types
-- =========================================================
-- FS25 determines tank drain rate and visual spray effects (terrain overlay,
-- nozzle particles) from g_sprayTypeManager entries. Base-game types
-- (FERTILIZER, LIQUIDFERTILIZER, MANURE, LIME, etc.) are registered by the
-- map XML. Our custom types are NOT in any map XML, so FS25 falls back to
-- litersPerSecond=1 — ~300-400x higher than vanilla. This empties tanks
-- instantly and suppresses all spray visuals (FSDensityMapUtil.updateSprayArea
-- is a no-op with a nil spray type).
--
-- Fix: inherit litersPerSecond and sprayGroundType from the closest vanilla
-- equivalent, then call g_sprayTypeManager:addSprayType() for each custom type.
---@return nil
function HookManager:registerCustomSprayTypes()
    if not g_sprayTypeManager then
        SoilLogger.warning("registerCustomSprayTypes: g_sprayTypeManager not available - skipping")
        return
    end
    if not g_fillTypeManager then
        SoilLogger.warning("registerCustomSprayTypes: g_fillTypeManager not available - skipping")
        return
    end

    -- Borrow sprayGroundType from the vanilla base types (purely for visual ground marking).
    -- litersPerSecond is NOT borrowed from vanilla — we compute it directly from BASE_RATES.
    local liqType  = g_sprayTypeManager:getSprayTypeByName("LIQUIDFERTILIZER")
    local dryType  = g_sprayTypeManager:getSprayTypeByName("FERTILIZER")
    local limeType = g_sprayTypeManager:getSprayTypeByName("LIME")

    if not liqType and not dryType then
        SoilLogger.warning("registerCustomSprayTypes: vanilla spray types not found - skipping")
        return
    end

    local liquidLPS         = liqType and liqType.litersPerSecond or 0.0081  -- stored for info log only
    local liquidGroundType  = liqType and liqType.sprayGroundType or 1
    local solidLPS          = dryType and dryType.litersPerSecond or 0.0060  -- stored for info log only
    local solidGroundType   = dryType and dryType.sprayGroundType or 1
    -- LIQUIDLIME must use LIME's ground type so FSDensityMapUtil.updateSprayArea writes the
    -- "limed" state to the density map. Using LIQUIDFERTILIZER's ground type marks the field
    -- as "fertilized" only, leaving it unlimed from vanilla's perspective and reducing yield.
    local limeGroundType    = limeType and limeType.sprayGroundType or solidGroundType

    -- Direct rate-to-LPS conversion:  customLPS = customRate_L_ha / 36000
    --
    -- Derivation: effective L/ha = LPS × dt_s / (spd_m_s × w_m × dt_s / 10000)
    --                             = LPS × 10000 / (spd_m_s × w_m)
    -- Converting speed to km/h gives: eff_L_ha = LPS × 36000.
    -- Invert: LPS = eff_L_ha / 36000.
    --
    -- WHY NOT the old proportional formula?
    -- Old:   customLPS = liquidLPS × (customRate / liqBase)   where liqBase = 93.5 L/ha
    -- Bug:   vanilla liquidLPS=0.0081 actually drains at 0.0081×36000 = 291.6 L/ha,
    --        NOT 93.5 L/ha (that was a UI display number, not the real drain rate).
    -- Error: 291.6 / 93.5 = 3.12× — all custom types were consuming 3.12× too fast.
    -- Fix:   bypass vanilla's ratio entirely; compute LPS straight from the target rate.
    local baseRates = SoilConstants.SPRAYER_RATE.BASE_RATES
    local liqBase   = baseRates.LIQUIDFERTILIZER.value  -- used as fallback default only

    -- Liquid nitrogen / starter types → inherit visual from LIQUIDFERTILIZER
    -- NOTE: HERBICIDE must be here so it gets a custom LPS of 100/36000 L/s, matching
    -- INSECTICIDE and FUNGICIDE. Without it, vanilla's native HERBICIDE spray type is
    -- used (~291 L/ha effective rate vs the intended 100 L/ha), causing weed pressure
    -- to drain far too fast even with the daily cap in onHerbicideAppliedDirect (the
    -- cap drains its full budget in the very first metre of a pass, then repeats on
    -- subsequent game-day passes — issue #276 follow-up bug).
    -- LIQUIDMANURE, MANURE, DIGESTATE were previously omitted from this list, causing them to fall
    -- through to whatever vanilla spray type LPS the game uses (often very low or undefined).
    -- The result: wap.usage was tiny → nutrient gain and coverage nearly zero (issue #311).
    -- Fix: register all three with customLPS = BASE_RATE / 36000 so they drain at the calibrated rate.
    local liquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME", "HERBICIDE", "INSECTICIDE", "FUNGICIDE",
                          "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH",
                          "LIQUIDMANURE", "MANURE", "DIGESTATE" }
    -- Granular/solid types → inherit visual from FERTILIZER
    local solidNames  = { "UREA", "AMS", "AN", "MAP", "DAP", "POTASH", "POLIFOSKA",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }

    local registered = 0
    local skipped    = 0

    for _, name in ipairs(liquidNames) do
        if g_fillTypeManager:getFillTypeByName(name) then
            local customRate  = baseRates[name] and baseRates[name].value or liqBase
            local customLPS   = customRate / 36000   -- exact: LPS = target_L_ha / 36000
            local displayType = (name == "LIQUIDLIME") and "LIME" or "FERTILIZER"
            -- Preserve the native sprayGroundType for types that already have a vanilla entry
            -- (e.g. HERBICIDE, INSECTICIDE, FUNGICIDE). Overriding with liquidGroundType would
            -- replace the herbicide/insecticide ground state with the fertilizer ground state,
            -- breaking vanilla field-state tracking for any system that reads ground type.
            -- New custom types (UAN32, ANHYDROUS, etc.) have no existing entry → use liquidGroundType.
            -- LIQUIDLIME always uses limeGroundType to write the correct lime density-map state.
            local groundType
            if name == "LIQUIDLIME" then
                groundType = limeGroundType
            else
                local existingST = g_sprayTypeManager:getSprayTypeByName(name)
                groundType = (existingST and existingST.sprayGroundType) or liquidGroundType
            end
            SoilLogger.debug("SprayType [LIQ] %-20s  LPS=%.6f  rate=%.1f L/ha", name, customLPS, customRate)

            -- addSprayType is idempotent: if already registered it updates the entry
            g_sprayTypeManager:addSprayType(name, customLPS, displayType, groundType, false)
            registered = registered + 1
        else
            skipped = skipped + 1
        end
    end

    for _, name in ipairs(solidNames) do
        if g_fillTypeManager:getFillTypeByName(name) then
            local customRate = baseRates[name] and baseRates[name].value or (solidLPS * 36000)
            local customLPS  = customRate / 36000   -- exact: LPS = target_kg_ha / 36000
            SoilLogger.debug("SprayType [DRY] %-20s  LPS=%.6f  rate=%.1f kg/ha", name, customLPS, customRate)

            g_sprayTypeManager:addSprayType(name, customLPS, "FERTILIZER", solidGroundType, false)
            registered = registered + 1
        else
            skipped = skipped + 1
        end
    end

    -- LIQUIDLIME: fillTypes.xml uses sprayTypeStr="LIQUIDFERTILIZER" as a safe XML-load-time fallback,
    -- but that sets fillType.sprayTypeIndex to LIQUIDFERTILIZER's index (291.6 L/ha).
    -- Override it now so the vanilla sprayer uses our calibrated LIQUIDLIME spray type (374 L/ha,
    -- LIME ground state). addSprayType already wrote fillTypeIndexToSprayType[LIQUIDLIME] = ours,
    -- but the drain uses fillType.sprayTypeIndex, so we must patch that field too.
    local llFT = g_fillTypeManager:getFillTypeByName("LIQUIDLIME")
    local llST = g_sprayTypeManager:getSprayTypeByName("LIQUIDLIME")
    if llFT and llST then
        llFT.sprayTypeIndex = llST.index
        SoilLogger.debug("LIQUIDLIME: overrode sprayTypeIndex → %d (LPS=%.5f, ~%.0f L/ha)",
            llST.index, llST.litersPerSecond or 0, (llST.litersPerSecond or 0) * 36000)
    else
        SoilLogger.warning("LIQUIDLIME spray type override failed: ft=%s st=%s", tostring(llFT), tostring(llST))
    end

    SoilLogger.info(
        "[OK] Custom spray types registered: %d types (direct LPS: vanilla ref liq=%.5f dry=%.5f, %d skipped)",
        registered, liquidLPS, solidLPS, skipped
    )
    SoilLogger.info("     Enable SoilDebug to see per-type LPS and rate values")
    -- Track whether all expected custom types registered (nil on dedi if fill types loaded late)
    self._sprayTypesComplete = (skipped == 0)
    if not self._sprayTypesComplete then
        SoilLogger.warning("[DeferredInit] %d fill types were nil — scheduling retry for dedi server timing", skipped)
    end
end

-- =========================================================
-- EFFECT TYPE REMAP: custom fill types → vanilla visuals
-- =========================================================
-- FS25 effect classes (FertilizerMotionPathEffect, ShaderPlaneEffect, etc.)
-- only have visual configurations for vanilla fill types that were present
-- when the vehicle or map XML was authored. Custom fill types (UREA, UAN32,
-- ANHYDROUS, etc.) have no such configuration, so the game logs "Could not
-- find motion path effect for settings" and shows no visual at all.
--
-- Root cause for sprayers: g_effectManager:setEffectTypeInfo stores the
-- custom fill type index on each effect object. Downstream lookups
-- (getSharedMotionPathEffect, shader parameter tables, etc.) find no entry
-- for the custom type and fail silently — effects never start.
--
-- Fix (two-layer):
--   PRIMARY: Wrap g_effectManager:setEffectTypeInfo to substitute custom
--   fill type indices with their vanilla visual equivalents before the index
--   is stored on any effect object. Every downstream system then sees only
--   vanilla types and works normally. Purely cosmetic — nutrient tracking
--   uses the real fill type index from the sprayer hook, not the effect.
--
--   BACKUP: Wrap g_motionPathEffectManager:getSharedMotionPathEffect so
--   that if a custom index somehow reaches it (e.g. set through a code path
--   that bypasses setEffectTypeInfo), we remap and retry before returning nil.
---@return boolean success
function HookManager:installEffectTypeHook()
    if not g_fillTypeManager then
        SoilLogger.warning("Effect type hook: g_fillTypeManager not available - skipping")
        return false
    end

    local fm = g_fillTypeManager
    local fertIdx = fm:getFillTypeIndexByName("FERTILIZER")
    local liqIdx  = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")

    -- Store name lists so reapplyEffectTypeRemap() can populate missing entries after dedi retry.
    self._effectSolidNames  = { "UREA", "AMS", "AN", "MAP", "DAP", "POTASH", "POLIFOSKA",
                                "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }
    self._effectLiquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                                "HERBICIDE", "INSECTICIDE", "FUNGICIDE",
                                "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }
    self._effectFertIdx = fertIdx
    self._effectLiqIdx  = liqIdx

    -- Build remap: customFillTypeIndex → vanillaFillTypeIndex
    -- Stored on self so reapplyEffectTypeRemap() can add entries to the same table
    -- that the closures below capture — no hook reinstall needed.
    local remap = {}
    self._effectTypeRemap = remap
    if fertIdx then
        for _, name in ipairs(self._effectSolidNames) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then remap[idx] = fertIdx end
        end
    end
    if liqIdx then
        for _, name in ipairs(self._effectLiquidNames) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then remap[idx] = liqIdx end
        end
    end

    if not next(remap) then
        SoilLogger.warning("Effect type hook: no custom fill types found — skipping")
        return false
    end

    local count = 0
    for _ in pairs(remap) do count = count + 1 end

    -- PRIMARY: hook g_effectManager:setEffectTypeInfo
    -- This fires before the fill type index is stored on the effect object,
    -- so all downstream lookups (FertilizerMotionPathEffect shared effect,
    -- ShaderPlaneEffect shader tables, etc.) only ever see vanilla types.
    if g_effectManager and type(g_effectManager.setEffectTypeInfo) == "function" then
        local origSetTypeInfo = g_effectManager.setEffectTypeInfo
        g_effectManager.setEffectTypeInfo = function(mgr, effects, fillType, ...)
            local mapped = (fillType ~= nil and remap[fillType]) or fillType
            return origSetTypeInfo(mgr, effects, mapped, ...)
        end
        self:registerCleanup("g_effectManager.setEffectTypeInfo", function()
            g_effectManager.setEffectTypeInfo = origSetTypeInfo
        end)
        SoilLogger.info("[OK] Effect type hook installed on g_effectManager.setEffectTypeInfo - %d custom fill types remapped", count)
    else
        SoilLogger.warning("Effect type hook: g_effectManager.setEffectTypeInfo not available - sprayer visuals may not show")
    end

    -- BACKUP: hook g_motionPathEffectManager:getSharedMotionPathEffect
    -- Handles any custom fill type index that bypasses setEffectTypeInfo and
    -- reaches the motion path lookup directly (e.g. via direct field writes).
    if g_motionPathEffectManager and
       type(g_motionPathEffectManager.getSharedMotionPathEffect) == "function" then
        local FILL_TYPE_FIELDS = { "fillTypeIndex", "fillType", "sprayTypeIndex", "currentFillType" }
        local origGetShared = g_motionPathEffectManager.getSharedMotionPathEffect
        g_motionPathEffectManager.getSharedMotionPathEffect = function(mgr, effectObj)
            local result = origGetShared(mgr, effectObj)
            if result ~= nil then return result end

            local fieldName, customIdx
            for _, fname in ipairs(FILL_TYPE_FIELDS) do
                local val = effectObj[fname]
                if val ~= nil and remap[val] then
                    fieldName = fname
                    customIdx = val
                    break
                end
            end
            if fieldName == nil then return nil end

            local vanillaIdx = remap[customIdx]
            effectObj[fieldName] = vanillaIdx
            result = origGetShared(mgr, effectObj)
            effectObj[fieldName] = customIdx
            return result
        end
        self:registerCleanup("g_motionPathEffectManager.getSharedMotionPathEffect", function()
            g_motionPathEffectManager.getSharedMotionPathEffect = origGetShared
        end)
        SoilLogger.info("[OK] Effect type hook backup installed on g_motionPathEffectManager - %d custom fill types remapped", count)
    end

    -- RUNTIME CONSTANT REMAP: wrap Sprayer.onEndWorkAreaProcessing
    -- Pattern from THPFConfigurator: temporarily swap FillType and SprayType globals
    -- so that FillType.LIQUIDFERTILIZER == our custom fill type index for the duration
    -- of the call. Every vanilla runtime check inside (getIsSprayTypeActive,
    -- if fillType == FillType.LIQUIDFERTILIZER, etc.) transparently passes for our types.
    -- Restore originals immediately after. No persistent global state change.
    --
    -- Build inverseRemap: customFillTypeIndex → vanilla constant name (e.g. "LIQUIDFERTILIZER")
    local inverseRemap = {}
    for customIdx, vanillaIdx in pairs(remap) do
        local vanillaFT = fm:getFillTypeByIndex(vanillaIdx)
        if vanillaFT and vanillaFT.name then
            inverseRemap[customIdx] = vanillaFT.name
        end
    end

    local globalEnv = getfenv(0)

    if Sprayer and type(Sprayer.onEndWorkAreaProcessing) == "function" then
        local origOnEnd = Sprayer.onEndWorkAreaProcessing
        Sprayer.onEndWorkAreaProcessing = function(self, ...)
            local spec    = self.spec_sprayer
            local wap     = spec and spec.workAreaParameters
            local sprayFT = wap and wap.sprayFillType
            local vName   = sprayFT and inverseRemap[sprayFT]

            if not vName then
                return origOnEnd(self, ...)
            end

            -- Swap FillType global: FillType.LIQUIDFERTILIZER → our custom index
            local origFT = globalEnv.FillType
            local newFT  = {}
            for k, v in pairs(origFT) do newFT[k] = v end
            newFT[vName] = sprayFT
            globalEnv.FillType = newFT

            -- Swap SprayType global: SprayType.LIQUIDFERTILIZER → our custom spray type index
            local origST    = globalEnv.SprayType
            local customSTD = g_sprayTypeManager and g_sprayTypeManager:getSprayTypeByFillTypeIndex(sprayFT)
            if customSTD then
                local newST = {}
                for k, v in pairs(origST) do newST[k] = v end
                newST[vName] = customSTD.index
                globalEnv.SprayType = newST
            end

            origOnEnd(self, ...)

            globalEnv.FillType = origFT
            if customSTD then globalEnv.SprayType = origST end
        end
        self:registerCleanup("Sprayer.onEndWorkAreaProcessing (constant remap)", function()
            Sprayer.onEndWorkAreaProcessing = origOnEnd
        end)
        SoilLogger.info("[OK] Sprayer.onEndWorkAreaProcessing wrapped with runtime constant remap")
    end

    return true
end

-- =========================================================
-- SPRAY TYPE EFFECTS INJECTION: custom fill types → sprayType.fillTypes
-- =========================================================
-- Sprayer:getIsSprayTypeActive(sprayType) checks whether the vehicle's current
-- fill type matches any name in sprayType.fillTypes (the list from the vehicle XML,
-- e.g. {"FERTILIZER"} or {"LIQUIDFERTILIZER"}). Only when it matches does FS25 call
-- g_effectManager:setEffectTypeInfo(sprayType.effects, fillType) and startEffects —
-- giving the spreading/spraying visual for that sprayType slot.
--
-- Because no vanilla or mod vehicle XML lists our custom fill type names (UREA, UAN32,
-- etc.), getIsSprayTypeActive always returns false for them → getActiveSprayType()
-- returns nil → sprayType.effects never starts → NO visual, even though the base
-- spec.effects fallback is usually empty on modern FS25 vehicles.
--
-- Fix (two-part):
--   1. Retroactively patch every loaded vehicle: for each sprayType entry whose
--      fillTypes list contains "FERTILIZER", also add our solid custom names;
--      likewise for "LIQUIDFERTILIZER" and our liquid names.
--   2. Hook Sprayer.onLoad (fires when any vehicle is loaded) to apply the same
--      injection to newly bought/spawned vehicles going forward.
---@return boolean success
function HookManager:installSprayTypeEffectsHook()
    -- Solid custom types visually match FERTILIZER spreading
    local solidNames  = { "UREA", "AMS", "AN", "MAP", "DAP", "POTASH", "POLIFOSKA",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }
    -- Liquid custom types visually match LIQUIDFERTILIZER spraying.
    -- HERBICIDE, INSECTICIDE, FUNGICIDE are included so they get injected into LIQUIDFERTILIZER
    -- slots (Pass 1), giving full-boom coverage on fertilizer sprayers. They are preserved in
    -- vanillaNames so Pass 2 does NOT strip them from their dedicated crop-protection slots.
    -- Their visual effects are managed by vanilla updateSprayerEffects (not our custom path).
    -- NOTE: LIQUIDMANURE / MANURE / DIGESTATE are intentionally absent here. They spread via
    -- the game's native slurry/manure systems, not the sprayer effect path — registerCustomSprayTypes
    -- only calibrates their drain rate (issue #311). Do not add them to this effects list.
    local liquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                          "HERBICIDE", "INSECTICIDE", "FUNGICIDE",
                          "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }

    -- Build name-lookup sets for fast membership tests
    local liquidNameSet = {}
    local solidNameSet  = {}
    for _, n in ipairs(liquidNames) do liquidNameSet[string.upper(n)] = true end
    for _, n in ipairs(solidNames)  do solidNameSet[string.upper(n)]  = true end

    -- Pass 2 must NOT strip vanilla fill type names from their native slots.
    -- HERBICIDE is a vanilla spray type; INSECTICIDE/FUNGICIDE have dedicated vehicle
    -- slots with their own effects. Stripping them empties the slot → getActiveSprayType()
    -- returns nil → vanilla starts no slot effects → no spray visual.
    local vanillaNames = { HERBICIDE = true, INSECTICIDE = true, FUNGICIDE = true }

    -- Shared helper: walk a vehicle's sprayType entries and inject our names.
    --
    -- getIsSprayTypeActive is name-based (iterates sprayType.fillTypes, compares by
    -- getFillTypeIndexByName). getActiveSprayType returns the FIRST matching slot.
    -- For vanilla fill types like HERBICIDE that have their own dedicated slot
    -- (center-nozzle-only), that slot is found before the LIQUIDFERTILIZER slot →
    -- only center nozzle sprays.
    --
    -- Fix (two passes):
    --   Pass 1 — add custom names to LIQUIDFERTILIZER / FERTILIZER slots (existing logic).
    --   Pass 2 — remove those same names from any slot that does NOT have LIQUIDFERTILIZER
    --            or FERTILIZER as its base. This leaves only the full-boom slot as a
    --            valid match, so getActiveSprayType finds the correct slot first.
    local function patchVehicleSprayTypes(vehicle)
        local spec = vehicle.spec_sprayer
        if not spec or not spec.sprayTypes then return end

        -- Pass 1: inject our custom names into the base fertilizer slots
        for _, st in ipairs(spec.sprayTypes) do
            if st.fillTypes then
                local hasFert    = false
                local hasLiqFert = false

                for _, name in ipairs(st.fillTypes) do
                    local upper = string.upper(name)
                    if upper == "FERTILIZER"        then hasFert    = true end
                    if upper == "LIQUIDFERTILIZER"  then hasLiqFert = true end
                end

                local existing = {}
                for _, name in ipairs(st.fillTypes) do
                    existing[string.upper(name)] = true
                end

                if hasFert then
                    for _, name in ipairs(solidNames) do
                        if not existing[name] then
                            table.insert(st.fillTypes, name)
                            existing[name] = true
                        end
                    end
                end

                if hasLiqFert then
                    for _, name in ipairs(liquidNames) do
                        if not existing[name] then
                            table.insert(st.fillTypes, name)
                            existing[name] = true
                        end
                    end
                end
            end
        end

        -- Pass 2: strip our names from any slot that lacks a base fertilizer type.
        -- Without this, vanilla HERBICIDE/INSECTICIDE/FUNGICIDE slots (center-only
        -- nozzle config) are found first by getActiveSprayType and override the
        -- full-boom LIQUIDFERTILIZER slot we patched in Pass 1.
        for _, st in ipairs(spec.sprayTypes) do
            if st.fillTypes then
                local hasFert    = false
                local hasLiqFert = false
                for _, name in ipairs(st.fillTypes) do
                    local upper = string.upper(name)
                    if upper == "FERTILIZER"       then hasFert    = true end
                    if upper == "LIQUIDFERTILIZER" then hasLiqFert = true end
                end
                if not hasFert and not hasLiqFert then
                    for i = #st.fillTypes, 1, -1 do
                        local upper = string.upper(st.fillTypes[i])
                        -- Don't strip vanilla fill type names — only strip our custom injected names
                        if not vanillaNames[upper] and (liquidNameSet[upper] or solidNameSet[upper]) then
                            table.remove(st.fillTypes, i)
                        end
                    end
                end
            end
        end
    end

    -- Part 1: retroactively patch all vehicles already in memory
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem
    local patched = 0
    if vehicleSystem and vehicleSystem.vehicles then
        for _, vehicle in pairs(vehicleSystem.vehicles) do
            patchVehicleSprayTypes(vehicle)
            patched = patched + 1
        end
    end

    -- Part 2: hook Sprayer.onLoad so future vehicles get the same treatment.
    -- onLoad fires after the vehicle XML is fully parsed but before the vehicle
    -- enters the world, so sprayType.fillTypes is already populated at this point.
    if not Sprayer or type(Sprayer.onLoad) ~= "function" then
        SoilLogger.warning("SprayTypeEffects hook: Sprayer.onLoad not available - new vehicles won't be patched")
    else
        local original = Sprayer.onLoad
        Sprayer.onLoad = Utils.appendedFunction(original, function(sprayerSelf, savegame)
            patchVehicleSprayTypes(sprayerSelf)
        end)
        self:register(Sprayer, "onLoad", original, "Sprayer.onLoad (sprayType effects)")
    end

    SoilLogger.info("[OK] SprayType effects hook installed - %d vehicles patched retroactively", patched)
    return true
end

-- =========================================================
-- POST-INSTALL: Force-refresh sprayer effects on loaded vehicles
-- =========================================================
-- After our deferred hooks install, vehicles that were loaded before
-- registerCustomSprayTypes ran will have workAreaParameters.sprayType = nil
-- (because getSprayTypeIndexByFillTypeIndex returned nil at vehicle-load time
-- before our custom types were registered). Their effects also have a stale
-- lastEffectsState that prevents re-evaluation.
--
-- Fix: iterate all loaded vehicles, reset lastEffectsState to nil so the
-- next updateSprayerEffects call sees a state change, then call it with
-- force=true to immediately re-resolve the sprayType and restart effects.
-- This is purely cosmetic and safe to call at any time post-load.
---@return nil
function HookManager:refreshAllSprayerEffects()
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem
    if not vehicleSystem or not vehicleSystem.vehicles then
        SoilLogger.debug("refreshAllSprayerEffects: vehicleSystem not available, skipping")
        return
    end

    local refreshed = 0
    for _, vehicle in pairs(vehicleSystem.vehicles) do
        local spec = vehicle.spec_sprayer
        if spec then
            -- Re-resolve sprayType from the current fillType now that our custom
            -- types are registered in SprayTypeManager.
            local wap = spec.workAreaParameters
            if wap and wap.sprayFillType and wap.sprayFillType > 0 then
                wap.sprayType = g_sprayTypeManager:getSprayTypeIndexByFillTypeIndex(wap.sprayFillType)
            end

            -- Reset lastEffectsState so updateSprayerEffects sees a change and
            -- re-calls setEffectTypeInfo with the now-remapped fill type.
            spec.lastEffectsState = nil

            -- Call updateSprayerEffects(force=true) if the method exists on this vehicle.
            if type(vehicle.updateSprayerEffects) == "function" then
                local ok, err = pcall(vehicle.updateSprayerEffects, vehicle, true)
                if not ok then
                    SoilLogger.debug("refreshAllSprayerEffects: updateSprayerEffects failed on vehicle %s: %s",
                        tostring(vehicle.configFileName or "?"), tostring(err))
                end
            end

            refreshed = refreshed + 1
        end
    end

    if refreshed > 0 then
        SoilLogger.info("[OK] Refreshed sprayer effects on %d loaded vehicle(s)", refreshed)
    end
end

-- =========================================================
-- DENSITY MAP SPRAY HOOK: remap custom spray type indices
-- =========================================================
-- FSDensityMapUtil.updateSprayArea is a native C++ function. It has its own
-- internal spray type table loaded at map init from maps_sprayTypes.xml and
-- only recognises the vanilla indices (FERTILIZER=1, HERBICIDE=2, LIME=3,
-- etc.). When wap.sprayType is one of our custom Lua-registered indices
-- (8, 9, 10 ...) the C++ call silently writes nothing to the density map —
-- no ground colour change after application (fertilizer/herbicide visual).
--
-- Root cause: Sprayer.processSprayerArea is registered via
-- SpecializationUtil.registerFunction, which COPIES the function reference
-- into each vehicle type at registration time. Class-level replacement of
-- Sprayer.processSprayerArea after vehicles are loaded never reaches existing
-- vehicle instances — they already have the old reference baked in.
--
-- Fix: hook Sprayer.onStartWorkAreaProcessing instead. This is registered via
-- SpecializationUtil.registerEventListener, which looks up the function on the
-- Sprayer class dynamically at each event fire. Our Utils.appendedFunction
-- replacement therefore reaches ALL vehicles (existing and newly spawned).
-- After the original sets wap.sprayType to our custom index, we remap it to
-- the vanilla equivalent. processSprayerArea then calls updateSprayArea with a
-- known C++ spray type index → ground density map writes correctly.
-- wap.sprayFillType (real fill type used by our nutrient hooks) is never touched.
---@return boolean success
function HookManager:installDensityMapSprayHook()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("DensityMap spray hook: Sprayer.onStartWorkAreaProcessing not available - skipping")
        return false
    end
    if not g_sprayTypeManager or not g_fillTypeManager then
        SoilLogger.warning("DensityMap spray hook: managers not available - skipping")
        return false
    end

    local liqST  = g_sprayTypeManager:getSprayTypeByName("LIQUIDFERTILIZER")
    local dryST  = g_sprayTypeManager:getSprayTypeByName("FERTILIZER")
    local limeST = g_sprayTypeManager:getSprayTypeByName("LIME")

    if not liqST and not dryST then
        SoilLogger.warning("DensityMap spray hook: vanilla spray types not found - skipping")
        return false
    end

    local liqIdx  = liqST  and liqST.index
    local dryIdx  = dryST  and dryST.index
    local limeIdx = limeST and limeST.index

    -- Build remap: customSprayTypeIndex → vanillaSprayTypeIndex
    -- LIQUIDLIME is excluded from liquidNames here — it must remap to LIME (not LIQUIDFERTILIZER)
    -- so FSDensityMapUtil.updateSprayArea writes the lime ground state, not the fertilizer state.
    -- HERBICIDE is excluded — it must keep its native HERBICIDE spray type for weed density map.
    local liquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER",
                          "INSECTICIDE", "FUNGICIDE",
                          "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }
    local solidNames  = { "UREA", "AMS", "AN", "MAP", "DAP", "POTASH", "POLIFOSKA",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }
    -- LIQUIDLIME must remap to LIME so FSDensityMapUtil writes the lime ground state
    local limeNames   = { "LIQUIDLIME" }

    local remap = {}
    if liqIdx then
        for _, name in ipairs(liquidNames) do
            local st = g_sprayTypeManager:getSprayTypeByName(name)
            if st then remap[st.index] = liqIdx end
        end
    end
    if dryIdx then
        for _, name in ipairs(solidNames) do
            local st = g_sprayTypeManager:getSprayTypeByName(name)
            if st then remap[st.index] = dryIdx end
        end
    end
    if limeIdx then
        for _, name in ipairs(limeNames) do
            local st = g_sprayTypeManager:getSprayTypeByName(name)
            if st then remap[st.index] = limeIdx end
        end
    end

    if not next(remap) then
        SoilLogger.warning("DensityMap spray hook: no custom spray types found after registration - skipping")
        return false
    end

    local count = 0
    for _ in pairs(remap) do count = count + 1 end

    -- MUST use appendedFunction (not prependedFunction) — fix for issue #415 (section control).
    --
    -- WHY APPEND:
    --   onStartWorkAreaProcessing (original) sets wap.sprayType = getSprayTypeIndexByFillTypeIndex(fillType).
    --   A prepended hook runs BEFORE the original, so the original's assignment overwrites the remap every
    --   frame. processSprayerArea then calls FSDensityMapUtil.updateSprayArea with our custom index, which
    --   C++ doesn't recognise → silently writes nothing → returns changedArea=0 always → PF's inside-field
    --   section control (which reads changedArea to detect already-treated areas) gets no signal → sections
    --   stay open over fertilised soil while moving.
    --
    --   With APPEND the remap runs AFTER the original sets wap.sprayType. processSprayerArea receives the
    --   vanilla index → updateSprayArea writes the density map correctly → changedArea reflects actual soil
    --   state → overlap-prevention section control works while moving (fix for Tomi89's Discord report).
    --
    -- WHY THIS IS SAFE FOR TANK DRAIN:
    --   getSprayerUsage(fillType, dt) uses the fill type (not wap.sprayType) to look up LPS from
    --   g_sprayTypeManager. Our custom fill types are registered there with their correct application
    --   rates, so tank drain is unaffected by what wap.sprayType contains.
    local original = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(sprayerSelf, dt)
            local spec = sprayerSelf.spec_sprayer
            local wap  = spec and spec.workAreaParameters
            if not wap then return end

            if wap.sprayType then
                local vanillaIdx = remap[wap.sprayType]
                if vanillaIdx then
                    wap.sprayType = vanillaIdx
                end
            end
        end
    )
    self:register(Sprayer, "onStartWorkAreaProcessing", original,
        "Sprayer.onStartWorkAreaProcessing (density map sprayType remap)")

    SoilLogger.info("[OK] DensityMap spray hook installed on onStartWorkAreaProcessing (APPEND) — %d custom spray types remapped to vanilla for C++ density map call; section control overlap fix active", count)
    return true
end

-- =========================================================
-- SMART SOIL SENSOR: per-section spray suppression
-- =========================================================
-- Appended to Sprayer.onStartWorkAreaProcessing (after the density map remap).
-- For each VWW section that VWW marked active, checks SF soil data at that
-- section's world position. If the product loaded is not needed at that spot
-- (pest=0, disease=0, K≥target, or P≥target) the section is temporarily set
-- to isActive=false. VWW resets it on the next tick — no persistent corruption.
--
function HookManager:installSectionControlHook()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[SectionSensor] Sprayer.onStartWorkAreaProcessing not found — skipping")
        return false
    end

    -- Build fill-type lookup tables from Constants at install time.
    -- These are constant for the session, so we pre-compute once.
    local pestFillTypes    = {}   -- ftName → true  (insecticides)
    local diseaseFillTypes = {}   -- ftName → true  (fungicides)
    local kOnlyFillTypes   = {}   -- ftName → true  (K dominant, P=0)
    local pDomFillTypes    = {}   -- ftName → true  (P dominant, K=0)
    local nDomFillTypes    = {}   -- ftName → true  (N only, P=0 K=0)

    local pp = SoilConstants.PEST_PRESSURE
    if pp and pp.INSECTICIDE_TYPES then
        for name, _ in pairs(pp.INSECTICIDE_TYPES) do pestFillTypes[name] = true end
    end
    local dp = SoilConstants.DISEASE_PRESSURE
    if dp and dp.FUNGICIDE_TYPES then
        for name, _ in pairs(dp.FUNGICIDE_TYPES) do diseaseFillTypes[name] = true end
    end
    local profs = SoilConstants.FERTILIZER_PROFILES
    if profs then
        for name, prof in pairs(profs) do
            local n = prof.N or 0
            local p = prof.P or 0
            local k = prof.K or 0
            if k > 0 and p == 0 then kOnlyFillTypes[name] = true end
            if p > 0 and k == 0 then pDomFillTypes[name]  = true end
            if n > 0 and p == 0 and k == 0 then nDomFillTypes[name] = true end
        end
    end

    local NUTRIENT_TARGET = SoilSensorManager and SoilSensorManager.NUTRIENT_TARGET or 70
    local hookMgrRef = self

    local origStart = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(
        Sprayer.onStartWorkAreaProcessing,
        function(sprayerSelf, dt)
            -- Gate 1: SF must be initialised
            local sfm = g_SoilFertilityManager
            if not sfm or not sfm.sensorManager or not sfm.soilSystem then return end

            -- Field Boundary Enforcement + Overlap Prevention:
            -- (1) Suppress boom sections whose outer tip extends outside the current field.
            -- (2) Suppress boom sections whose outer tip (or root for center) is in a cell
            --     already sprayed this session AND stamped more than OVERLAP_GRACE_MS ago.
            --     The grace period prevents self-suppression on the current forward pass:
            --     a cell stamped < 20 s ago is still "fresh" and won't block its own section.
            -- Independent of Smart Sensor — applies to every fill type when enabled.
            if sfm.settings and sfm.settings.fieldBoundaryControl then
                local vwwBE = sprayerSelf.spec_variableWorkWidth
                if vwwBE and vwwBE.sections and #vwwBE.sections > 0 then
                    -- Use preserver-cached root position (avoids redundant getWorldTranslation)
                    local rx = sprayerSelf._sfRootX
                    local rz = sprayerSelf._sfRootZ
                    if rx then
                        local vehicleFieldId = hookMgrRef:getFieldIdAtWorldPosition(rx, rz)
                        local tips = sprayerSelf._sfSectionTip

                        -- Pre-fetch overlap state for this field
                        local soilSysRef   = sfm.soilSystem
                        local fieldDataRef = soilSysRef and soilSysRef.fieldData
                        local fieldEntry   = (fieldDataRef and vehicleFieldId and vehicleFieldId > 0)
                                            and fieldDataRef[vehicleFieldId] or nil
                        local coveredCells = fieldEntry and fieldEntry.sessionCoverageCells or nil
                        local zoneCell     = SoilConstants.ZONE and SoilConstants.ZONE.CELL_SIZE or 10
                        local graceMs      = SoilConstants.ZONE and SoilConstants.ZONE.OVERLAP_GRACE_MS or 20000
                        local nowMs        = g_currentMission and g_currentMission.time or 0

                        for i, section in ipairs(vwwBE.sections) do
                            if section.isActive then
                                -- Determine position to check:
                                -- Non-center sections use the cached outer tip.
                                -- Center section uses the vehicle root (no tip node).
                                local sx, sz
                                if section.isCenter then
                                    sx = rx
                                    sz = rz
                                else
                                    local tip = tips and tips[i]
                                    if tip then
                                        sx = tip[1]
                                        sz = tip[2]
                                    end
                                end

                                if sx then
                                    -- (1) Boundary: non-center tip must be in the same field.
                                    --     Center section is always on the vehicle root — skip.
                                    if not section.isCenter then
                                        local fid = hookMgrRef:getFieldIdAtWorldPosition(sx, sz)
                                        if not fid or fid <= 0 or
                                           (vehicleFieldId and vehicleFieldId > 0 and fid ~= vehicleFieldId) then
                                            section.isActive = false
                                            if not sprayerSelf._sfSuppressedSections then sprayerSelf._sfSuppressedSections = {} end
                                            sprayerSelf._sfSuppressedSections[i] = true
                                        end
                                    end

                                    -- (2) Overlap: cell already visited AND older than grace period.
                                    if section.isActive and coveredCells then
                                        local cx      = math.floor(sx / zoneCell)
                                        local cz      = math.floor(sz / zoneCell)
                                        local cellKey = tostring(cx * 10000 + cz)
                                        local stampMs = coveredCells[cellKey]
                                        if stampMs and (nowMs - stampMs) > graceMs then
                                            section.isActive = false
                                            if not sprayerSelf._sfSuppressedSections then sprayerSelf._sfSuppressedSections = {} end
                                            sprayerSelf._sfSuppressedSections[i] = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- Gate 2: skip if admin has disabled Smart Sensor globally
            if sfm.settings and sfm.settings.smartSensorEnabled == false then return end

            local sensorMgr = sfm.sensorManager

            -- Gate 3: vehicle must have VWW sections
            local vww = sprayerSelf.spec_variableWorkWidth
            if not vww or not vww.sections or #vww.sections == 0 then return end

            -- Gate 4: read fill type from wap (set by the original onStartWorkAreaProcessing)
            local spec = sprayerSelf.spec_sprayer
            local wap  = spec and spec.workAreaParameters
            if not wap then return end

            local fillTypeIndex = wap.sprayFillType
            if not fillTypeIndex or fillTypeIndex == 0 then return end

            local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if not ft then return end

            local vehicleId = sprayerSelf.id

            -- Classify the fill type
            local isPest    = pestFillTypes[ft.name]    == true
            local isDisease = diseaseFillTypes[ft.name] == true
            local isKOnly   = kOnlyFillTypes[ft.name]   == true
            local isPDom    = pDomFillTypes[ft.name]    == true
            local isNDom    = nDomFillTypes[ft.name]    == true

            if not isPest and not isDisease and not isKOnly and not isPDom and not isNDom then return end

            -- Check which sensors are active for this vehicle
            local pestOn     = isPest                          and sensorMgr:isPestEnabled(vehicleId)
            local diseaseOn  = isDisease                       and sensorMgr:isDiseaseEnabled(vehicleId)
            local nutrientOn = (isKOnly or isPDom or isNDom)  and sensorMgr:isNutrientEnabled(vehicleId)

            if not pestOn and not diseaseOn and not nutrientOn then return end

            -- Use preserver-cached root position (computed once before all hooks)
            local rootX = sprayerSelf._sfRootX
            local rootZ = sprayerSelf._sfRootZ
            if not rootX then return end

            local soilSys = sfm.soilSystem
            local tips = sprayerSelf._sfSectionTip

            for i, section in ipairs(vww.sections) do
                -- Center sections CAN be suppressed: getIsWorkAreaActive() checks workArea.sectionIndex
                -- → section.isActive for all sections including center. Center has no tip node, so its
                -- position check falls back to rootX/rootZ (vehicle center = center strip position).
                -- installSectionStatePreserver() restores isActive for all sections after work areas process.
                if section.isActive then
                    -- Midpoint between root and section outer edge (from preserver cache).
                    -- Center section has no tip node → tips[i] = nil → falls back to rootX/rootZ.
                    local tip = tips and tips[i]
                    local sx = tip and ((rootX + tip[1]) * 0.5) or rootX
                    local sz = tip and ((rootZ + tip[2]) * 0.5) or rootZ

                    local fieldId = hookMgrRef:getFieldIdAtWorldPosition(sx, sz)
                    if fieldId and fieldId > 0 then
                        local fd = soilSys.fieldData[fieldId]
                        if fd then
                            local skip = false
                            if pestOn    then skip = skip or ((fd.pestPressure    or 0) <= 0) end
                            if diseaseOn then skip = skip or ((fd.diseasePressure or 0) <= 0) end
                            if nutrientOn and isNDom then
                                skip = skip or ((fd.nitrogen   or 0) >= NUTRIENT_TARGET)
                            end
                            if nutrientOn and isKOnly then
                                skip = skip or ((fd.potassium  or 0) >= NUTRIENT_TARGET)
                            end
                            if nutrientOn and isPDom then
                                skip = skip or ((fd.phosphorus or 0) >= NUTRIENT_TARGET)
                            end
                            if skip then
                                section.isActive = false
                                if not sprayerSelf._sfSuppressedSections then sprayerSelf._sfSuppressedSections = {} end
                                sprayerSelf._sfSuppressedSections[i] = true
                            end
                        end
                    end
                end
            end
        end
    )

    self:register(Sprayer, "onStartWorkAreaProcessing", origStart,
        "Sprayer.onStartWorkAreaProcessing (SF section sensor)")

    SoilLogger.info("[OK] SF Smart Sensor hook installed — pest/disease/nutrient N+K+P section control active")
    return true
end

-- =========================================================
-- SEE & SPRAY: per-cell spot-spray suppression (System 2)
-- =========================================================
-- Appended AFTER the Smart Sensor hook.  Reads field.zoneData[cellKey] for the
-- exact soil cell under each boom section.  Sections are suppressed when the
-- cell's pest/disease/weed pressure is below the configured threshold.
-- Falls back to field average when no cell entry exists (unvisited cell).
function HookManager:installSeeAndSprayHook()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[SeeAndSpray] Sprayer.onStartWorkAreaProcessing not found — skipping")
        return false
    end

    -- Fill-type lookup tables built once at install time
    local pestFTs    = {}
    local diseaseFTs = {}
    local weedFTs    = {}

    local pp = SoilConstants.PEST_PRESSURE
    if pp and pp.INSECTICIDE_TYPES then
        for name in pairs(pp.INSECTICIDE_TYPES) do pestFTs[name] = true end
    end
    local dp = SoilConstants.DISEASE_PRESSURE
    if dp and dp.FUNGICIDE_TYPES then
        for name in pairs(dp.FUNGICIDE_TYPES) do diseaseFTs[name] = true end
    end
    local wp = SoilConstants.WEED_PRESSURE
    if wp and wp.HERBICIDE_TYPES then
        for name in pairs(wp.HERBICIDE_TYPES) do weedFTs[name] = true end
    end

    local hookMgrRef = self

    -- Cache of fieldId → reusable FieldState object (or false if unavailable).
    -- Each call site calls fs:update(x, z) before reading fs.weedState.
    local weedFieldStates = {}
    local function getWeedFieldState(fieldId)
        if weedFieldStates[fieldId] == nil then
            local fsField = nil
            if g_fieldManager and g_fieldManager.fields then
                for _, f in ipairs(g_fieldManager.fields) do
                    if f and f.farmland and f.farmland.id == fieldId then
                        fsField = f
                        break
                    end
                end
            end
            if fsField and fsField.posX then
                local fok, fs = pcall(function()
                    local state = FieldState.new()
                    state:update(fsField.posX, fsField.posZ)
                    return state
                end)
                weedFieldStates[fieldId] = (fok and fs) and fs or false
            else
                weedFieldStates[fieldId] = false
            end
        end
        return weedFieldStates[fieldId] or nil
    end

    local origStart = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(
        Sprayer.onStartWorkAreaProcessing,
        function(sprayerSelf, dt)
            local sfm = g_SoilFertilityManager
            if not sfm or not sfm.soilSystem then return end

            -- See & Spray is a purchased vehicle feature — read from SFNozzleEffects spec.
            local sfSpec = SFNozzleEffects and sprayerSelf[SFNozzleEffects.SPEC_TABLE_NAME]
            if not sfSpec then return end

            local vww = sprayerSelf.spec_variableWorkWidth
            if not vww or not vww.sections or #vww.sections == 0 then return end

            local spec = sprayerSelf.spec_sprayer
            local wap  = spec and spec.workAreaParameters
            if not wap then return end

            local fillTypeIndex = wap.sprayFillType
            if not fillTypeIndex or fillTypeIndex == 0 then return end
            local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if not ft then return end

            local isPest    = pestFTs[ft.name]    == true
            local isDisease = diseaseFTs[ft.name] == true
            local isWeed    = weedFTs[ft.name]    == true
            if not isPest and not isDisease and not isWeed then return end

            local pestSS    = isPest    and sfSpec.seeSprayPest    == true
            local diseaseSS = isDisease and sfSpec.seeSprayDisease == true
            local weedSS    = isWeed    and sfSpec.seeSprayWeed    == true
            if not pestSS and not diseaseSS and not weedSS then return end

            -- Use preserver-cached root position (computed once before all hooks)
            local rootX = sprayerSelf._sfRootX
            local rootZ = sprayerSelf._sfRootZ
            if not rootX then return end

            local soilSys = sfm.soilSystem
            local ssCfg   = SoilConstants.SEE_AND_SPRAY
            local zone    = SoilConstants.ZONE
            local tips    = sprayerSelf._sfSectionTip

            -- #678: when per-vehicle Variable Rate is on, See & Spray runs graduated —
            -- each non-skipped section gets a rate from its cell's pest/disease/weed
            -- pressure instead of hard on/off. The Variable Rate hook (which runs next)
            -- is taught to leave these rates alone for See & Spray products. When Variable
            -- Rate is off, behaviour is unchanged (pure on/off section suppression).
            local sensorMgr  = sfm.sensorManager
            local vehicleId  = sprayerSelf.id
            local variableOn = sensorMgr ~= nil and vehicleId ~= nil
                and (sfm.settings == nil or sfm.settings.variableRateEnabled ~= false)
                and sensorMgr:isVariableRateEnabled(vehicleId)
            local vrCfg = SoilConstants.VARIABLE_RATE
            if variableOn then sensorMgr:clearSectionRates(vehicleId) end

            for i, section in ipairs(vww.sections) do
                if section.isActive then
                    local tip = tips and tips[i]
                    local sx = tip and ((rootX + tip[1]) * 0.5) or rootX
                    local sz = tip and ((rootZ + tip[2]) * 0.5) or rootZ

                    local fieldId = hookMgrRef:getFieldIdAtWorldPosition(sx, sz)
                    if fieldId and fieldId > 0 then
                        local fd = soilSys.fieldData[fieldId]
                        if fd then
                            local cellKey = tostring(
                                math.floor(sx / zone.CELL_SIZE) * 10000 +
                                math.floor(sz / zone.CELL_SIZE))
                            local cell = fd.zoneData and fd.zoneData[cellKey]

                            local cellPest    = (cell and cell.pestPressure)    or (fd.pestPressure    or 0)
                            local cellDisease = (cell and cell.diseasePressure) or (fd.diseasePressure or 0)
                            local cellWeed    = (cell and cell.weedPressure)    or (fd.weedPressure    or 0)

                            local skip = false
                            if pestSS    then skip = skip or (cellPest    < ssCfg.PEST_THRESHOLD)    end
                            if diseaseSS then skip = skip or (cellDisease < ssCfg.DISEASE_THRESHOLD) end
                            if weedSS    then
                                local herbicideActive = (fd.herbicideDaysLeft or 0) > 0
                                local weedsGone = herbicideActive
                                if not weedsGone then
                                    -- Ground truth: query the game's weed density map at this exact position.
                                    -- weedState 0=none, 1-6=alive, 7-9=withered/dying → suppress 0 or >=7.
                                    local fs = getWeedFieldState(fieldId)
                                    if fs then
                                        local uok = pcall(function() fs:update(sx, sz) end)
                                        if uok then
                                            local ws = fs.weedState or -1
                                            weedsGone = (ws == 0 or ws >= 7)
                                        end
                                    end
                                    -- Fallback to stale cell pressure if weed system unavailable.
                                    if not weedsGone then
                                        weedsGone = (cellWeed < ssCfg.WEED_THRESHOLD)
                                    end
                                end
                                skip = skip or weedsGone
                            end
                            if skip then
                                section.isActive = false
                                if not sprayerSelf._sfSuppressedSections then sprayerSelf._sfSuppressedSections = {} end
                                sprayerSelf._sfSuppressedSections[i] = true
                            elseif variableOn then
                                -- #678: graduated rate from the active target's pressure.
                                -- Maps [threshold .. FULL_RATE_PRESSURE] → [MIN_RATE .. MAX_RATE],
                                -- then eases toward it (same 0.6/0.4 blend the NPK hook uses).
                                local pressure, thr
                                if pestSS then
                                    pressure, thr = cellPest, ssCfg.PEST_THRESHOLD
                                elseif diseaseSS then
                                    pressure, thr = cellDisease, ssCfg.DISEASE_THRESHOLD
                                else
                                    pressure, thr = cellWeed, ssCfg.WEED_THRESHOLD
                                end
                                local full = ssCfg.FULL_RATE_PRESSURE or 50
                                local frac = (full > thr) and ((pressure - thr) / (full - thr)) or 1
                                -- Weeds pass a ground-truth check but cellWeed can be stale/0;
                                -- never under-treat a section the check said needs spraying.
                                if weedSS and (pressure or 0) <= 0 then frac = 1 end
                                if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
                                local rate = vrCfg.MIN_RATE + frac * (vrCfg.MAX_RATE - vrCfg.MIN_RATE)
                                local prev = sensorMgr:getSectionRate(vehicleId, section) or rate
                                rate = prev * 0.6 + rate * 0.4
                                sensorMgr:setSectionRate(vehicleId, section, rate)
                            end
                        end
                    end
                end
            end
        end
    )

    self:register(Sprayer, "onStartWorkAreaProcessing", origStart,
        "Sprayer.onStartWorkAreaProcessing (SF see-and-spray)")
    SoilLogger.info("[OK] SF See & Spray hook installed — per-cell pest/disease/weed section control active")
    return true
end

-- =========================================================
-- VARIABLE RATE APPLICATION: per-section rate (System 3)
-- =========================================================
-- Appended to onStartWorkAreaProcessing.  Computes a per-section rate multiplier
-- from the nutrient deficit at the cell directly under each boom section and
-- stores it in sensorMgr.sectionRates[vehicleId].
-- The existing VWW section loop in onEndWorkAreaProcessing reads these rates
-- and scales litersPerSection accordingly.
-- Only active for NPK fertilizers; no-ops for pest/disease/weed products.
function HookManager:installVariableRateHook()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[VariableRate] Sprayer.onStartWorkAreaProcessing not found — skipping")
        return false
    end

    -- Classify fill types at install time
    local nFerts   = {}   -- N-dominant (UAN, liquid urea, etc.)
    local pFerts   = {}   -- P-dominant (MAP, DAP, etc.)
    local kFerts   = {}   -- K-only (POTASH, etc.)
    local npkFerts = {}   -- multi-nutrient (all N/P/K fertilizers)
    local omFerts  = {}   -- OM-primary (compost, manure, digestate — target organic matter)

    local profs = SoilConstants.FERTILIZER_PROFILES
    local omPrimarySet = SoilConstants.SPRAYER_RATE and SoilConstants.SPRAYER_RATE.OM_PRIMARY_PRODUCTS
    if profs then
        for name, prof in pairs(profs) do
            local n = prof.N or 0
            local p = prof.P or 0
            local k = prof.K or 0
            if n > 0 or p > 0 or k > 0 then
                npkFerts[name] = true
                if n > 0 and p == 0 and k == 0 then nFerts[name] = true end
                if p > 0 and k == 0             then pFerts[name] = true end
                if k > 0 and p == 0             then kFerts[name] = true end
            end
            if omPrimarySet and omPrimarySet[name] then
                omFerts[name] = true
            end
        end
    end

    -- #678: See & Spray products (pest/disease/weed) are owned by the See & Spray hook,
    -- which runs before this one and sets per-section rates from pest/disease/weed
    -- pressure. Build the name set so this hook leaves those rates untouched.
    local ssNames = {}
    local ppC = SoilConstants.PEST_PRESSURE
    if ppC and ppC.INSECTICIDE_TYPES then for n in pairs(ppC.INSECTICIDE_TYPES) do ssNames[n] = true end end
    local dpC = SoilConstants.DISEASE_PRESSURE
    if dpC and dpC.FUNGICIDE_TYPES then for n in pairs(dpC.FUNGICIDE_TYPES) do ssNames[n] = true end end
    local wpC = SoilConstants.WEED_PRESSURE
    if wpC and wpC.HERBICIDE_TYPES then for n in pairs(wpC.HERBICIDE_TYPES) do ssNames[n] = true end end

    local hookMgrRef = self

    local origStart = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(
        Sprayer.onStartWorkAreaProcessing,
        function(sprayerSelf, dt)
            local sfm = g_SoilFertilityManager
            if not sfm or not sfm.sensorManager or not sfm.soilSystem then return end

            if sfm.settings and sfm.settings.variableRateEnabled == false then return end

            local sensorMgr = sfm.sensorManager
            local vehicleId = sprayerSelf.id

            if not sensorMgr:isVariableRateEnabled(vehicleId) then
                sensorMgr:clearSectionRates(vehicleId)
                return
            end

            local vww = sprayerSelf.spec_variableWorkWidth
            if not vww or not vww.sections or #vww.sections == 0 then return end

            local spec = sprayerSelf.spec_sprayer
            local wap  = spec and spec.workAreaParameters
            if not wap then return end

            local fillTypeIndex = wap.sprayFillType
            if not fillTypeIndex or fillTypeIndex == 0 then
                sensorMgr:clearSectionRates(vehicleId)
                return
            end
            local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            -- #678: leave See & Spray rates intact — the See & Spray hook already set them
            -- this tick from pest/disease/weed pressure. Clearing here would wipe them.
            if ft and ssNames[ft.name] then
                return
            end
            if not ft or (not npkFerts[ft.name] and not omFerts[ft.name]) then
                sensorMgr:clearSectionRates(vehicleId)
                return
            end

            local isN   = nFerts[ft.name]  == true
            local isP   = pFerts[ft.name]  == true
            local isK   = kFerts[ft.name]  == true
            local isOM  = omFerts[ft.name] == true

            -- Manual rate ceiling
            local rm = sfm.sprayerRateManager
            local manualMult = rm and rm:getMultiplier(vehicleId) or 1.0

            -- Use preserver-cached root position (computed once before all hooks)
            local rootX = sprayerSelf._sfRootX
            local rootZ = sprayerSelf._sfRootZ
            if not rootX then return end

            local soilSys = sfm.soilSystem
            local vrCfg   = SoilConstants.VARIABLE_RATE
            local target  = vrCfg.NUTRIENT_TARGET
            local zone    = SoilConstants.ZONE
            local tips    = sprayerSelf._sfSectionTip

            sensorMgr:clearSectionRates(vehicleId)

            for i, section in ipairs(vww.sections) do
                if section.isActive and not section.isCenter then
                    local tip = tips and tips[i]
                    local sx = tip and ((rootX + tip[1]) * 0.5) or rootX
                    local sz = tip and ((rootZ + tip[2]) * 0.5) or rootZ

                    local fieldId = hookMgrRef:getFieldIdAtWorldPosition(sx, sz)
                    local rate = vrCfg.MIN_RATE + (vrCfg.MAX_RATE - vrCfg.MIN_RATE) * 0.5  -- default mid
                    if fieldId and fieldId > 0 then
                        local fd = soilSys.fieldData[fieldId]
                        if fd then
                            local cellKey = tostring(
                                math.floor(sx / zone.CELL_SIZE) * 10000 +
                                math.floor(sz / zone.CELL_SIZE))
                            local cell = fd.zoneData and fd.zoneData[cellKey]

                            local nutrientVal
                            local effTarget = target
                            if isOM then
                                -- OM-primary products (compost, manure, digestate): target organic matter
                                local omTarget = SoilConstants.SPRAYER_RATE and
                                    SoilConstants.SPRAYER_RATE.AUTO_RATE_TARGETS and
                                    SoilConstants.SPRAYER_RATE.AUTO_RATE_TARGETS.OM or 5.0
                                nutrientVal = (cell and cell.OM) or fd.organicMatter or omTarget
                                effTarget   = omTarget
                            elseif isN then
                                nutrientVal = (cell and cell.N) or fd.nitrogen or target
                            elseif isP then
                                nutrientVal = (cell and cell.P) or fd.phosphorus or target
                            elseif isK then
                                nutrientVal = (cell and cell.K) or fd.potassium or target
                            else
                                -- Complex NPK: use worst (lowest) of the three
                                local n = (cell and cell.N) or fd.nitrogen   or target
                                local p = (cell and cell.P) or fd.phosphorus or target
                                local k = (cell and cell.K) or fd.potassium  or target
                                nutrientVal = math.min(n, p, k)
                            end

                            local deficit = math.max(0, effTarget - nutrientVal) / effTarget
                            rate = vrCfg.MIN_RATE + deficit * (vrCfg.MAX_RATE - vrCfg.MIN_RATE)
                        end
                    end

                    -- Smooth rate to prevent tick-to-tick flickering as the boom crosses
                    -- zone boundaries (#479). 40% blend toward target per tick gives ~0.5s lag.
                    local prevRate = sensorMgr:getSectionRate(vehicleId, section) or rate
                    rate = prevRate * 0.6 + rate * 0.4
                    -- VR rates are redistribution weights; do NOT cap at manualMult.
                    -- The manual rate budget is already applied to wap.usage by
                    -- installSprayerStartHook. Capping here caused double-reduction (#555).
                    sensorMgr:setSectionRate(vehicleId, section, rate)
                end
            end
        end
    )

    self:register(Sprayer, "onStartWorkAreaProcessing", origStart,
        "Sprayer.onStartWorkAreaProcessing (SF variable rate)")
    SoilLogger.info("[OK] SF Variable Rate hook installed — per-section NPK rate control active")
    return true
end

-- =========================================================
-- OVERLAP PREVENTION: session-cell-based nozzle shutoff
-- =========================================================
-- Prepended to onStartWorkAreaProcessing (before VWW processes work areas).
-- For each non-center VWW section, checks whether the section tip's 10×10 m cell
-- was already sprayed by this sprayer during the current session (tracked in
-- sessionCoverageCells with a timestamp).  If the cell was stamped more than
-- OVERLAP_GRACE_MS ago, the section is suppressed so the nozzle does not
-- re-apply product on overlapping headland swaths.
--
-- Uses session coverage cells rather than the SPRAY_LEVEL density map.
-- The density-map approach (EQUAL lvlMax) was unreliable because:
--   • getMaxValue() returns the maximum that CAN be stored (e.g. 2 for a 2-bit
--     field), which equals the game's "fully fertilised" state — so any field
--     that was fertilised to completion in a previous season or earlier in the
--     same game-day reads as "already done" and suppresses all wing sections
--     the moment the sprayer enters, regardless of whether the player has
--     sprayed anything this pass (#600 persisted after the EQUAL fix).
-- Session cells are reset on harvest, product change, and game load, so they
-- only ever reflect what this sprayer session has actually applied.
-- StatePreserver restores section.isActive after work areas process — no permanent lock.
-- No-ops when the overlapPrevention setting is disabled.
function HookManager:installOverlapPreventionHook()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[OverlapPrev] Sprayer.onStartWorkAreaProcessing not found — skipping")
        return false
    end

    local hookMgrRef = self

    -- Build fill-type lookup table at install time.
    -- We cannot rely on stDesc.isFertilizer for SF custom types — Lua-registered
    -- spray types via addSprayType() do not inherit the isFertilizer flag from the
    -- display type.  Use explicit name lists instead (same approach as SmartSensor).
    -- Lime is included: we track lime application via session cells the same way.
    local trackableFillTypes = {}  -- fillTypeIndex → true

    local function addFTByName(name)
        local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(name)
        if ft then trackableFillTypes[ft.index] = true end
    end

    -- Vanilla fertilizer fill types
    for _, name in ipairs({ "FERTILIZER", "LIQUIDFERTILIZER", "MANURE", "LIQUIDMANURE", "DIGESTATE" }) do
        addFTByName(name)
    end
    -- SF custom liquid fertilizers (excludes INSECTICIDE/FUNGICIDE)
    for _, name in ipairs({ "UAN32", "UAN28", "ANHYDROUS", "STARTER",
                             "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }) do
        addFTByName(name)
    end
    -- SF custom solid fertilizers
    for _, name in ipairs({ "UREA", "AMS", "AN", "MAP", "DAP", "POTASH", "POLIFOSKA",
                             "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }) do
        addFTByName(name)
    end
    -- Lime fill types
    for _, name in ipairs({ "LIME", "LIQUIDLIME" }) do
        addFTByName(name)
    end

    -- Throttle for debug diagnostic logging: log once per ~2 s per sprayer
    local dbgLogThrottle = {}

    local origStart = Sprayer.onStartWorkAreaProcessing
    -- PREPEND so sections are suppressed before VWW's original processes work areas;
    -- APPEND would let VWW activate visual effects before we can suppress them.
    Sprayer.onStartWorkAreaProcessing = Utils.prependedFunction(
        Sprayer.onStartWorkAreaProcessing,
        function(sprayerSelf, dt)
            local sfm = g_SoilFertilityManager
            if not sfm then return end
            if sfm.settings and sfm.settings.overlapPrevention == false then return end

            local vww = sprayerSelf.spec_variableWorkWidth
            if not vww or not vww.sections or #vww.sections == 0 then return end

            local spec = sprayerSelf.spec_sprayer
            local wap  = spec and spec.workAreaParameters
            if not wap then return end

            local fillTypeIndex = wap.sprayFillType
            if not fillTypeIndex or fillTypeIndex == 0 then return end

            if not trackableFillTypes[fillTypeIndex] then
                -- Clear any stale suppression left over from a prior fertilizer fill type.
                -- Without this, switching from LIQUIDFERTILIZER to FUNGICIDE/HERBICIDE leaves
                -- _sfOverlapSuppressedSections populated, which blocks section state restoration
                -- and causes wing nozzles to show no visual effects.
                if sprayerSelf._sfOverlapSuppressedSections then
                    sprayerSelf._sfOverlapSuppressedSections = {}
                end
                return
            end

            local rootX = sprayerSelf._sfRootX
            local rootZ = sprayerSelf._sfRootZ
            if not rootX then return end

            -- Get this session's coverage cells for the current field.
            -- These are stamped by markBoomCells() inside onStartWorkAreaProcessing
            -- (the frame AFTER spray), so they represent ground sprayed in prior frames.
            -- When the vehicle root is on the headland / just outside the field boundary,
            -- fall back to the last known field ID so the 99% gate still fires.
            local vehicleFieldId = hookMgrRef:getFieldIdAtWorldPosition(rootX, rootZ)
            if not vehicleFieldId or vehicleFieldId <= 0 then
                vehicleFieldId = sprayerSelf._sfLastKnownFieldId
            end
            if not vehicleFieldId or vehicleFieldId <= 0 then return end

            local soilSys   = sfm.soilSystem
            local fieldData = soilSys and soilSys.fieldData
            local fieldEntry = fieldData and fieldData[vehicleFieldId]

            -- Keep the last known field ID fresh for headland fallback.
            if fieldEntry then sprayerSelf._sfLastKnownFieldId = vehicleFieldId end
            local coveredCells = fieldEntry and fieldEntry.sessionCoverageCells
            -- If no cells have been stamped yet this session, nothing to suppress.
            -- Clear any stale suppression so sections don't stay locked.
            if not coveredCells or not next(coveredCells) then
                if sprayerSelf._sfOverlapSuppressedSections then
                    sprayerSelf._sfOverlapSuppressedSections = {}
                end
                return
            end

            local zone    = SoilConstants.ZONE
            local zoneCell = zone and zone.CELL_SIZE or 10
            local graceMs  = zone and zone.OVERLAP_GRACE_MS or 20000
            local nowMs    = g_currentMission and g_currentMission.time or 0

            local tips = sprayerSelf._sfSectionTip

            -- Debug diagnostic: throttled to once per ~2s per sprayer instance
            local debugEnabled = sfm.settings and sfm.settings.debugMode
            local vid = tostring(sprayerSelf)
            local doLog = debugEnabled and (not dbgLogThrottle[vid] or (nowMs - dbgLogThrottle[vid]) > 2000)
            if doLog then
                dbgLogThrottle[vid] = nowMs
                SoilLogger.debug("[OverlapPrev] ft=%d fieldId=%d rootX=%.1f rootZ=%.1f graceMs=%d",
                    fillTypeIndex, vehicleFieldId, rootX, rootZ, graceMs)
            end

            -- Transition-based effect management:
            -- prevSuppressed = sections suppressed last frame (persists via _sfOverlapSuppressedSections)
            -- currSuppressed = sections suppressed this frame (built below, stored at end)
            -- Stop effects when newly suppressed; start effects when transitioning back to clear.
            -- The APPEND re-stops currSuppressed after updateSprayerEffects may restart everything.
            local prevSuppressed = sprayerSelf._sfOverlapSuppressedSections or {}
            local currSuppressed = {}

            -- At >=99% field coverage every section is guaranteed to be on
            -- already-sprayed ground — suppress everything without a grace period.
            -- This handles the centre section whose coverage cells are always stamped
            -- fresh (it's under the vehicle) and never age past graceMs on the current pass.
            local coverage = fieldEntry and fieldEntry.sessionCoverageFraction or 0
            local coverageComplete = coverage >= 0.99

            local suppressCount = 0
            for i, section in ipairs(vww.sections) do
                local tip = tips and tips[i]
                local alreadySprayed = coverageComplete  -- global gate at 99%+

                if not alreadySprayed then
                    -- Tip-based cell check. Wing sections use their outer tip node;
                    -- sections with no tip node fall back to the vehicle root position.
                    --
                    -- Grace period rationale:
                    --   Wings (tip in a different cell from root): graceMs required —
                    --     the tip's cell may have been freshly stamped by an adjacent
                    --     strip only seconds ago, and skipping grace would cause false
                    --     suppression on the current forward pass.
                    --   Centre (no tip, OR tip maps to the same cell as root): the
                    --     cell under the root/tip is ALWAYS unstamped ahead of the
                    --     vehicle on the current pass (markBoomCells runs AFTER this
                    --     PREPEND), so any existing stamp means "visited in a prior
                    --     pass." No grace needed — this also fixes JD R700i/R975i
                    --     where the centre tip exists but falls in the root cell.
                    local tx = tip and tip[1] or rootX
                    local tz = tip and tip[2] or rootZ
                    local cx = math.floor(tx / zoneCell)
                    local cz = math.floor(tz / zoneCell)
                    local cellKey = tostring(cx * 10000 + cz)
                    local stampMs = coveredCells[cellKey]
                    local rootCx = math.floor(rootX / zoneCell)
                    local rootCz = math.floor(rootZ / zoneCell)
                    local isCentreCell = (cx == rootCx and cz == rootCz)
                    if tip and not isCentreCell then
                        alreadySprayed = stampMs ~= nil and (nowMs - stampMs) > graceMs
                    else
                        alreadySprayed = stampMs ~= nil  -- no grace for centre cell
                    end

                    if doLog and i <= 4 then
                        SoilLogger.debug("[OverlapPrev]   sec%d tip=%.1f,%.1f stampMs=%s graceOk=%s",
                            i, tx, tz, tostring(stampMs), tostring(alreadySprayed))
                    end
                end

                if alreadySprayed then
                    section.isActive = false
                    suppressCount = suppressCount + 1
                    currSuppressed[i] = section

                    if section.effects and #section.effects > 0 then
                        g_effectManager:stopEffects(section.effects)
                    end

                    local eseSpec = sprayerSelf.spec_extendedSprayerEffects
                    if eseSpec and eseSpec.sprayerEffectsBySection then
                        local sectionEffects = eseSpec.sprayerEffectsBySection[i]
                        if sectionEffects then
                            for _, ed in ipairs(sectionEffects) do
                                if ed.effectNode and ed.fadeCur then
                                    setShaderParameter(ed.effectNode, "fadeProgress", 1, -1, 0, 0, false)
                                end
                            end
                        end
                    end
                elseif prevSuppressed[i] then
                    local prevSection = prevSuppressed[i]
                    if section.isActive and prevSection.effects and #prevSection.effects > 0 then
                        g_effectManager:startEffects(prevSection.effects)
                    end
                end
            end

            sprayerSelf._sfOverlapSuppressedSections = currSuppressed

            if doLog and suppressCount > 0 then
                SoilLogger.debug("[OverlapPrev] suppressed %d sections", suppressCount)
            end

            -- When all sections are overlap-suppressed, also block processSprayerArea
            -- at the instance level so the non-VWW centre work area cannot drain the
            -- tank. Restored in onEndWorkAreaProcessing each frame.
            if coverageComplete then
                sprayerSelf._sfSprayAreaBlocked = true
                sprayerSelf.processSprayerArea  = function() return 0 end
            end
        end
    )

    self:register(Sprayer, "onStartWorkAreaProcessing", origStart,
        "Sprayer.onStartWorkAreaProcessing (SF overlap prevention)")
    SoilLogger.info("[OK] SF Overlap Prevention hook installed — session-cell overlap detection active")

    -- Re-suppress section effects after the original onEndWorkAreaProcessing runs.
    -- Sprayer:updateSprayerEffects() (called from onEndWorkAreaProcessing) may call
    -- g_effectManager:startEffects(spec.effects) on a state-change tick (e.g. sprayer
    -- just turned on after braking), restarting effects we suppressed in the PREPEND.
    -- This APPEND re-stops them so the boom stays visually correct.
    if type(Sprayer.onEndWorkAreaProcessing) == "function" then
        local origEnd = Sprayer.onEndWorkAreaProcessing
        Sprayer.onEndWorkAreaProcessing = Utils.appendedFunction(
            Sprayer.onEndWorkAreaProcessing,
            function(sprayerSelf, dt, hasProcessed)
                -- Restore the processSprayerArea instance override we set in the PREPEND.
                -- This runs AFTER the processing window, so any no-op blocking already took effect.
                if sprayerSelf._sfSprayAreaBlocked then
                    sprayerSelf.processSprayerArea = nil
                    sprayerSelf._sfSprayAreaBlocked = nil
                end

                local suppressed = sprayerSelf._sfOverlapSuppressedSections
                if suppressed and next(suppressed) then
                    for _, section in pairs(suppressed) do
                        if section.effects and #section.effects > 0 then
                            g_effectManager:stopEffects(section.effects)
                        end
                    end
                    -- If all VWW sections are suppressed, stop global effects too
                    local vww = sprayerSelf.spec_variableWorkWidth
                    if vww and vww.sections and #vww.sections > 0 then
                        local allSuppressed = true
                        for i = 1, #vww.sections do
                            if not suppressed[i] then allSuppressed = false; break end
                        end
                        if allSuppressed then
                            local spec = sprayerSelf.spec_sprayer
                            if spec then
                                g_effectManager:stopEffects(spec.effects)
                                for _, st in ipairs(spec.sprayTypes or {}) do
                                    g_effectManager:stopEffects(st.effects)
                                end
                            end
                        end
                    end
                end
            end
        )
        self:register(Sprayer, "onEndWorkAreaProcessing", origEnd,
            "Sprayer.onEndWorkAreaProcessing (SF overlap section.effects re-suppress)")
    end

    SoilLogger.info("[OK] SF Overlap Prevention — transition-based visual suppression active (stopEffects/startEffects on section state change)")
    return true
end

-- =========================================================
-- SECTION STATE PRESERVER: save/restore VWW section states
-- =========================================================
-- Fixes the "boom locks at minimum width" bug caused by SmartSensor
-- and SeeAndSpray hooks setting section.isActive=false without ever
-- restoring it. VWW only resets isActive via setSectionsActive()
-- (CTRL+Z), so the suppression was permanent until the player manually
-- cycled width.
--
-- This function:
--   PREPENDS to onStartWorkAreaProcessing — saves VWW section states
--     before any suppression hook runs (prependedFunction executes first
--     even though this hook is installed last).
--   APPENDS to onEndWorkAreaProcessing — restores saved states after
--     work areas are processed, so VWW width control is unaffected.
function HookManager:installSectionStatePreserver()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[SectionPreserver] Sprayer.onStartWorkAreaProcessing not found — skipping")
        return false
    end

    -- PREPEND: save section states before suppression hooks modify them.
    -- prependedFunction guarantees this runs BEFORE the existing chain
    -- (which includes the appended SmartSensor/SeeAndSpray/VariableRate hooks).
    local origStart = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.prependedFunction(
        Sprayer.onStartWorkAreaProcessing,
        function(sprayerSelf, dt)
            local vww = sprayerSelf.spec_variableWorkWidth
            if not vww or not vww.sections or #vww.sections == 0 then return end

            -- Clear suppression tracking from the previous work-area pass.
            -- Each appended hook writes to _sfSuppressedSections directly when it
            -- suppresses a section. Clearing here (before the original + our hooks run)
            -- ensures only THIS tick's suppression is visible to the visual effects hook.
            -- Do NOT infer suppression by comparing before/after states — that would
            -- falsely capture VWW's own section management as "suppressed by us".
            local sfSup = sprayerSelf._sfSuppressedSections
            if sfSup then
                for k in pairs(sfSup) do sfSup[k] = nil end
            end

            -- Reuse existing table to avoid per-tick allocation
            local saved = sprayerSelf._sfSavedSectionStates
            if not saved then
                saved = {}
                sprayerSelf._sfSavedSectionStates = saved
            end

            -- Cache root world position once; the three appended hooks read this
            -- cache instead of calling getWorldTranslation independently.
            local rx, _, rz = getWorldTranslation(sprayerSelf.rootNode)
            sprayerSelf._sfRootX = rx
            sprayerSelf._sfRootZ = rz

            -- Overlap-suppressed sections have isActive=false from the previous frame.
            -- Saving that false means the preserver would restore false when overlap clears,
            -- permanently locking the section. Treat any overlap-suppressed section as
            -- "would be active" so it can recover once its tip leaves sprayed ground.
            local prevOverlapSup = sprayerSelf._sfOverlapSuppressedSections

            -- Cache each section's tip node world position so all hooks can
            -- reuse it without redundant pcall(getWorldTranslation) calls.
            if rx then
                local tips = sprayerSelf._sfSectionTip
                if not tips then
                    tips = {}
                    sprayerSelf._sfSectionTip = tips
                end
                for i, section in ipairs(vww.sections) do
                    saved[i] = (prevOverlapSup and prevOverlapSup[i] ~= nil) and true or section.isActive
                    -- Choose the node that is FURTHEST from the vehicle root as the tip.
                    -- The outer boom edge is always further from the root than any inner node,
                    -- so distance is a reliable discriminator across all sprayer configurations:
                    --   • JD R700i/R975i: maxWidthNode marks inner transitions; workArea.width
                    --     is further and correctly reaches the outer tip.
                    --   • Vanilla / other sprayers: maxWidthNode is at the outer tip; it is
                    --     further than the workArea.width node, so it wins.
                    --   • Sprayers with no maxWidthNode (e.g. Condor): workArea.width is the
                    --     only candidate and is used directly.
                    local bestDistSq = -1
                    local bestX, bestZ = nil, nil

                    local function tryNode(node)
                        if not node then return end
                        local ok, wx, _, wz = pcall(getWorldTranslation, node)
                        if not ok or not wx then return end
                        local dx = wx - rx
                        local dz = wz - rz
                        local d2 = dx * dx + dz * dz
                        if d2 > bestDistSq then
                            bestDistSq = d2
                            bestX = wx
                            bestZ = wz
                        end
                    end

                    tryNode(section.maxWidthNode)
                    local waSpec = sprayerSelf.spec_workArea
                    if waSpec and waSpec.workAreas then
                        for _, wa in ipairs(waSpec.workAreas) do
                            if wa.sectionIndex == i then
                                tryNode(wa.width)
                            end
                        end
                    end

                    if bestX then
                        local t = tips[i]
                        if not t then t = {}; tips[i] = t end
                        t[1] = bestX; t[2] = bestZ
                    else
                        tips[i] = nil
                    end
                end
            else
                for i, section in ipairs(vww.sections) do
                    saved[i] = (prevOverlapSup and prevOverlapSup[i] ~= nil) and true or section.isActive
                end
            end
        end
    )
    self:register(Sprayer, "onStartWorkAreaProcessing", origStart,
        "Sprayer.onStartWorkAreaProcessing (SF section state saver)")

    -- APPEND to onEndWorkAreaProcessing: restore section states after
    -- work areas have been processed for this tick.
    if type(Sprayer.onEndWorkAreaProcessing) == "function" then
        local origEnd = Sprayer.onEndWorkAreaProcessing
        Sprayer.onEndWorkAreaProcessing = Utils.appendedFunction(
            Sprayer.onEndWorkAreaProcessing,
            function(sprayerSelf, dt, hasProcessed)
                local saved = sprayerSelf._sfSavedSectionStates
                if not saved then return end
                local vww = sprayerSelf.spec_variableWorkWidth
                if vww and vww.sections then
                    -- Don't restore sections suppressed by overlap prevention —
                    -- they must stay isActive=false so SFNozzleEffects fades them out.
                    local overlapSup = sprayerSelf._sfOverlapSuppressedSections
                    for i, section in ipairs(vww.sections) do
                        if saved[i] ~= nil and (not overlapSup or not overlapSup[i]) then
                            section.isActive = saved[i]
                        end
                    end
                end
                sprayerSelf._sfSavedSectionStates = nil
            end
        )
        self:register(Sprayer, "onEndWorkAreaProcessing", origEnd,
            "Sprayer.onEndWorkAreaProcessing (SF section state restorer)")
    else
        SoilLogger.warning("[SectionPreserver] Sprayer.onEndWorkAreaProcessing not found — restore hook skipped")
    end

    SoilLogger.info("[OK] SF section state preserver installed — VWW width control (CTRL+Z) protected from suppression hooks")
    return true
end

--- Register a cleanup-only hook (e.g. message center subscriptions).
---@param name string A human-readable name for logging
---@param cleanupFn function Called during uninstallAll() to undo the hook
function HookManager:registerCleanup(name, cleanupFn)
    table.insert(self.hooks, {
        name = name,
        cleanup = cleanupFn
    })
end

-- =========================================================
-- HOOK 1: Harvest events (Cutter.onEndWorkAreaProcessing)
-- =========================================================
-- Combine.addCutterArea is registered via SpecializationUtil.registerFunction,
-- then WorkArea captures it as a direct closure reference at vehicle load —
-- class-level hook is bypassed completely.
-- Cutter.onEndWorkAreaProcessing IS an event listener (dynamic dispatch).
-- It runs AFTER processCutterArea accumulates workAreaParameters this tick,
-- and AFTER calling combineVehicle:addCutterArea internally, so all harvest
-- data (area, liters, fruitType, strawRatio) is valid and accessible.
--
-- COMPATIBILITY NOTE (RealisticHarvesting / issue #284):
-- RealisticHarvesting uses SpecializationUtil.registerOverwrittenFunction for
-- addCutterArea, giving it a superFunc chain.  If SF wraps Combine.addCutterArea
-- at the class level AFTER RHM registers, SF's wrapper becomes RHM's superFunc.
-- RHM calls superFunc(self, area, realArea, inputFruitType, ...) where the 3rd
-- argument is realArea (pixel count, e.g. ~1500), NOT liters.  The old SF code
-- read arg 3 as "liters", multiplied by yieldModifier, and returned the result —
-- so RHM received a garbage retLiters value and its HUD showed 0 for yield,
-- crop loss, and engine load.
--
-- Fix: addCutterArea is now used ONLY for soil nutrient tracking (field detection
-- + onHarvest).  The yield modifier is applied in a separate per-combine
-- addFillUnitFillLevel wrapper (see installYieldModifierHook below) which always
-- receives actual liters regardless of who sits above it in the call chain.
---@return boolean success True if hook installed successfully
function HookManager:installHarvestHook()
    if not Cutter or type(Cutter.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install harvest hook - Cutter.onEndWorkAreaProcessing not available")
        return false
    end
    if not Combine or type(Combine.addCutterArea) ~= "function" then
        SoilLogger.warning("Could not install harvest hook - Combine.addCutterArea not available")
        return false
    end

    local original = Combine.addCutterArea
    -- NOTE: We CANNOT use Utils.appendedFunction here because it discards the
    -- original's return value, returning whatever the appended function returns
    -- (nil). Cutter.lua:1085 does `if appliedDelta > 0` on that return value,
    -- which causes "attempt to compare number < nil". We use a manual wrapper
    -- that captures and forwards the original's return value instead.
    --
    -- The wrapper no longer modifies the liters argument — yield reduction is
    -- handled by installYieldModifierHook (addFillUnitFillLevel on the hopper).
    -- This makes the hook argument-order-agnostic and safe regardless of what
    -- other mods pass as the 3rd positional argument.
    --
    -- COMPATIBILITY (issue #284): instance patching wraps the existing vehicle
    -- function rather than replacing it, preserving any other mod's specialization
    -- chain (e.g. RealisticHarvesting's registerOverwrittenFunction for addCutterArea).
    local function makeHarvestWrapper(chainFn)
        return function(combineSelf, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)
            SoilLogger.debug("Harvest hook entered: isServer=%s area=%.1f liters=%.0f fruit=%s",
                tostring(combineSelf.isServer), area or 0, liters or 0, tostring(inputFruitType))

            -- Detect field for nutrient depletion tracking (onHarvest).
            -- Yield modifier is NO LONGER applied here — see installYieldModifierHook.
            local detectedFieldId = nil
            local detectedX, detectedZ = nil, nil

            -- NOTE: liters=0 is normal in swath/windrow mode (isSwathActive=true on the combine).
            -- The crop is deposited on the ground rather than collected in the hopper.
            -- We still deplete nutrients (the soil grew the biomass regardless of collection method);
            -- updateFieldNutrients handles the liters=0 case via area-based estimation.
            if combineSelf.isServer
                and g_SoilFertilityManager
                and g_SoilFertilityManager.soilSystem
                and g_SoilFertilityManager.settings.enabled
                and g_SoilFertilityManager.settings.nutrientCycles
                and inputFruitType and inputFruitType > 0
                and area and area > 0
            then
                local ok, errMsg = pcall(function()
                    local x, _, z = getWorldTranslation(combineSelf.rootNode)
                    if not x then
                        SoilLogger.debug("Harvest hook: skipped (rootNode translation failed)")
                        return
                    end

                    local fieldId = nil
                    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
                        local field = g_fieldManager:getFieldAtWorldPosition(x, z)
                        if field and field.farmland then
                            fieldId = field.farmland.id
                        end
                    end
                    if not fieldId and g_farmlandManager then
                        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
                        if farmland then fieldId = farmland.id end
                    end
                    -- Fallback: combine rootNode (mid-rear body) can exit the field polygon
                    -- on large headers. Try attached cutter/header positions instead.
                    if not fieldId or fieldId <= 0 then
                        local attachedImpls = combineSelf.spec_attacherJoints and combineSelf.spec_attacherJoints.attachedImplements
                        if attachedImpls then
                            for _, impl in ipairs(attachedImpls) do
                                local obj = impl and impl.object
                                if obj then
                                    local ix, _, iz = getWorldTranslation(obj.rootNode)
                                    if ix then
                                        if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
                                            local f = g_fieldManager:getFieldAtWorldPosition(ix, iz)
                                            if f and f.farmland then fieldId = f.farmland.id end
                                        end
                                        if not fieldId and g_farmlandManager then
                                            local fl = g_farmlandManager:getFarmlandAtWorldPosition(ix, iz)
                                            if fl then fieldId = fl.id end
                                        end
                                    end
                                    if (not fieldId or fieldId <= 0) and obj.spec_workArea and obj.spec_workArea.workAreas then
                                        for _, wa in ipairs(obj.spec_workArea.workAreas) do
                                            if wa.start then
                                                local sx, _, sz = getWorldTranslation(wa.start)
                                                if sx then
                                                    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
                                                        local f = g_fieldManager:getFieldAtWorldPosition(sx, sz)
                                                        if f and f.farmland then fieldId = f.farmland.id end
                                                    end
                                                    if not fieldId and g_farmlandManager then
                                                        local fl = g_farmlandManager:getFarmlandAtWorldPosition(sx, sz)
                                                        if fl then fieldId = fl.id end
                                                    end
                                                end
                                            end
                                            if fieldId and fieldId > 0 then break end
                                        end
                                    end
                                end
                                if fieldId and fieldId > 0 then break end
                            end
                        end
                    end
                    if not fieldId or fieldId <= 0 then
                        SoilLogger.debug("Harvest hook: skipped (no field at pos x=%.1f z=%.1f)", x, z)
                        return
                    end

                    detectedFieldId = fieldId
                    detectedX, detectedZ = x, z
                    SoilLogger.debug("Harvest hook: Field %d, Crop %d, area=%.1fm2 (yield modifier applied via hopper hook)",
                        fieldId, inputFruitType, area)
                end)

                if not ok then
                    SoilLogger.error("Harvest hook (field detection) failed: %s", tostring(errMsg))
                end
            else
                SoilLogger.debug("Harvest hook: skipped (isServer=%s enabled=%s nutrientCycles=%s fruit=%s area=%s)",
                    tostring(combineSelf.isServer),
                    tostring(g_SoilFertilityManager and g_SoilFertilityManager.settings.enabled),
                    tostring(g_SoilFertilityManager and g_SoilFertilityManager.settings.nutrientCycles),
                    tostring(inputFruitType), tostring(area))
            end

            -- Pass arguments completely untouched — we no longer modify liters here.
            local r1, r2, r3, r4, r5 = chainFn(combineSelf, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)

            -- Nutrient depletion uses original (biological) liters — the soil depleted what
            -- the crop grew regardless of the yield modifier applied to the hopper.
            if detectedFieldId then
                local ok, errMsg = pcall(function()
                    g_SoilFertilityManager.soilSystem:onHarvest(detectedFieldId, inputFruitType, liters, strawRatio, area)
                end)
                if not ok then
                    SoilLogger.error("Harvest hook (nutrient update) failed: %s", tostring(errMsg))
                end
            end

            -- Harvest trail: record combine position for in-world + minimap overlay
            if detectedFieldId and detectedX then
                pcall(function()
                    g_SoilFertilityManager.soilSystem:recordHarvestTrailPoint(detectedFieldId, detectedX, detectedZ)
                end)
            end

            -- Compaction: harvesters pack soil by ground pressure, not raw mass. A combine
            -- on wide flotation tyres in dry soil adds little; a heavy one on narrow tyres
            -- in wet soil adds a lot. Same model as the driving check, incl. VTP/moisture.
            if detectedFieldId and detectedX and
               g_SoilFertilityManager.settings.compactionEnabled and
               SoilConstants.COMPACTION and SoilCompactionModel then
                local cp = SoilConstants.COMPACTION
                local rootVeh = combineSelf.rootVehicle or combineSelf
                local okM, totalMass = pcall(function()
                    return rootVeh:getTotalMass(false)
                end)
                if okM and totalMass and totalMass >= cp.HEAVY_VEHICLE_THRESHOLD_T then
                    local wet = g_SoilFertilityManager._soilWetness01 or 0
                    local points = SoilCompactionModel.pointsForVehicle(rootVeh, wet)
                    if points and points > 0 then
                        pcall(function()
                            g_SoilFertilityManager.soilSystem:onCompaction(detectedFieldId, detectedX, detectedZ, points)
                        end)
                    end
                end
            end

            -- Forward original return values so Cutter.lua gets appliedDelta intact
            return r1, r2, r3, r4, r5
        end
    end

    Combine.addCutterArea = makeHarvestWrapper(original)
    self:register(Combine, "addCutterArea", original, "Combine.addCutterArea")

    -- FS25 specialization functions are copied to vehicle instances at spawn time,
    -- so vehicles already in memory have a stale reference to the pre-hook original.
    -- Wrap the existing instance function (not replace) to preserve other mods'
    -- specialization chains (e.g. RealisticHarvesting's addCutterArea overwrite).
    local patched = 0
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem
    if vehicleSystem and vehicleSystem.vehicles then
        for _, vehicle in pairs(vehicleSystem.vehicles) do
            if vehicle.spec_combine and type(vehicle.addCutterArea) == "function" then
                vehicle.addCutterArea = makeHarvestWrapper(vehicle.addCutterArea)
                patched = patched + 1
            end
        end
    end

    -- Late-patch combines spawned AFTER hook installation.
    -- FS25's specialization system captures the Combine.addCutterArea reference at
    -- vehicle-type registration time (before our hook). New vehicles of combine types
    -- use that captured original as their instance method, bypassing the class-level
    -- replacement. Hooking VehicleSystem:addVehicle ensures every combine — including
    -- mod vehicles bought from the shop mid-session — gets the wrapper on first spawn.
    if type(VehicleSystem) == "table" and type(VehicleSystem.addVehicle) == "function" then
        local origAddVehicle = VehicleSystem.addVehicle
        VehicleSystem.addVehicle = function(vsSelf, vehicle)
            local r = origAddVehicle(vsSelf, vehicle)
            if vehicle and vehicle.spec_combine and type(vehicle.addCutterArea) == "function" then
                if vehicle.addCutterArea ~= Combine.addCutterArea then
                    vehicle.addCutterArea = makeHarvestWrapper(vehicle.addCutterArea)
                    SoilLogger.debug("[HarvestHook] Late-patched new combine: %s",
                        tostring(vehicle.configFileName or vehicle.typeName or "?"))
                end
            end
            return r
        end
        self:register(VehicleSystem, "addVehicle", origAddVehicle, "VehicleSystem.addVehicle (harvest late-patch)")
    end

    SoilLogger.info("[OK] Harvest hook installed (Combine.addCutterArea) — %d existing combines patched", patched)
    return true
end

-- =========================================================
-- HOOK 1b: Yield modifier applied via combine hopper
-- =========================================================
-- Applies the SF yield modifier by wrapping Combine.addFillUnitFillLevel.
-- This is the companion to installHarvestHook.  Separating the modifier
-- application from addCutterArea fixes the RealisticHarvesting conflict:
-- RHM uses registerOverwrittenFunction for addCutterArea and calls
--   superFunc(self, area, realArea, inputFruitType, ...)
-- where the 3rd argument is realArea (pixel count), NOT liters.  The old
-- code read arg 3 as "liters" and returned liters*yieldModifier — RHM got
-- a garbage retLiters and its HUD went blank (issue #284).
--
-- By moving modifier logic here (where the value is always actual hopper
-- liters), we are argument-order-agnostic and the conflict disappears.
-- Instance patching uses makeYieldWrapper(vehicle.addFillUnitFillLevel) to
-- preserve any other mod's chain rather than replacing it outright.
---@return boolean success True if hook installed successfully
function HookManager:installYieldModifierHook()
    -- FillUnit.addFillUnitFillLevel is the correct FS25 hook target.
    -- Combine does NOT register addFillUnitFillLevel as its own class method --
    -- it inherits it from FillUnit via the vehicle specialization system.
    -- Hooking Combine.addFillUnitFillLevel therefore always fails (nil check).
    -- Real FS25 signature: addFillUnitFillLevel(self, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
    if not FillUnit or type(FillUnit.addFillUnitFillLevel) ~= "function" then
        SoilLogger.warning("Yield modifier hook: FillUnit.addFillUnitFillLevel not available -- yield reduction skipped")
        return false
    end

    local original = FillUnit.addFillUnitFillLevel

    -- Factory so the same modifier logic wraps any chainFn
    local function makeYieldWrapper(chainFn)
        -- Correct FS25 signature includes farmId as first arg after self
        return function(combineSelf, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
            -- Only apply modifier on the server when filling the hopper (delta > 0),
            -- only for combine spec vehicles, and only when SF systems are ready.
            local modifiedDelta = fillLevelDelta
            if combineSelf.isServer
                and combineSelf.spec_combine ~= nil
                and fillLevelDelta and fillLevelDelta > 0
                and fillTypeIndex
                and g_SoilFertilityManager
                and g_SoilFertilityManager.soilSystem
                and g_SoilFertilityManager.settings.enabled
                and g_SoilFertilityManager.settings.nutrientCycles
            then
                local ok, errMsg = pcall(function()
                    local fruitType = nil
                    if g_fruitTypeManager then
                        local ft = g_fruitTypeManager:getFruitTypeByFillTypeIndex(fillTypeIndex)
                        if ft then fruitType = ft.index end
                    end
                    if not fruitType or fruitType <= 0 then return end

                    local x, _, z = getWorldTranslation(combineSelf.rootNode)
                    if not x then return end

                    local fieldId = nil
                    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
                        local field = g_fieldManager:getFieldAtWorldPosition(x, z)
                        if field and field.farmland then fieldId = field.farmland.id end
                    end
                    if not fieldId and g_farmlandManager then
                        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
                        if farmland then fieldId = farmland.id end
                    end
                    -- Fallback: rootNode may sit outside field polygon on large combines
                    if not fieldId or fieldId <= 0 then
                        local attachedImpls = combineSelf.spec_attacherJoints and combineSelf.spec_attacherJoints.attachedImplements
                        if attachedImpls then
                            for _, impl in ipairs(attachedImpls) do
                                local obj = impl and impl.object
                                if obj then
                                    local ix, _, iz = getWorldTranslation(obj.rootNode)
                                    if ix then
                                        if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
                                            local f = g_fieldManager:getFieldAtWorldPosition(ix, iz)
                                            if f and f.farmland then fieldId = f.farmland.id end
                                        end
                                        if not fieldId and g_farmlandManager then
                                            local fl = g_farmlandManager:getFarmlandAtWorldPosition(ix, iz)
                                            if fl then fieldId = fl.id end
                                        end
                                    end
                                    if (not fieldId or fieldId <= 0) and obj.spec_workArea and obj.spec_workArea.workAreas then
                                        for _, wa in ipairs(obj.spec_workArea.workAreas) do
                                            if wa.start then
                                                local sx, _, sz = getWorldTranslation(wa.start)
                                                if sx then
                                                    if g_fieldManager and type(g_fieldManager.getFieldAtWorldPosition) == "function" then
                                                        local f = g_fieldManager:getFieldAtWorldPosition(sx, sz)
                                                        if f and f.farmland then fieldId = f.farmland.id end
                                                    end
                                                    if not fieldId and g_farmlandManager then
                                                        local fl = g_farmlandManager:getFarmlandAtWorldPosition(sx, sz)
                                                        if fl then fieldId = fl.id end
                                                    end
                                                end
                                            end
                                            if fieldId and fieldId > 0 then break end
                                        end
                                    end
                                end
                                if fieldId and fieldId > 0 then break end
                            end
                        end
                    end
                    if not fieldId or fieldId <= 0 then return end

                    local yieldModifier = g_SoilFertilityManager.soilSystem:computeYieldModifier(fieldId, fruitType)
                    if yieldModifier ~= 1.0 then
                        modifiedDelta = fillLevelDelta * yieldModifier
                        SoilLogger.debug("Yield modifier hook: Field %d Fruit %d modifier=%.3f (%.1fL -- %.1fL)",
                            fieldId, fruitType, yieldModifier, fillLevelDelta, modifiedDelta)
                    end
                end)
                if not ok then
                    SoilLogger.error("Yield modifier hook failed: %s", tostring(errMsg))
                    modifiedDelta = fillLevelDelta
                end
            end
            return chainFn(combineSelf, farmId, fillUnitIndex, modifiedDelta, fillTypeIndex, toolType, fillPositionData)
        end
    end

    FillUnit.addFillUnitFillLevel = makeYieldWrapper(original)
    self:register(FillUnit, "addFillUnitFillLevel", original, "FillUnit.addFillUnitFillLevel (yield modifier)")

    -- Wrap existing combine instances to preserve other mods specialization chains.
    local patched = 0
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem
    if vehicleSystem and vehicleSystem.vehicles then
        for _, vehicle in pairs(vehicleSystem.vehicles) do
            if vehicle.spec_combine and type(vehicle.addFillUnitFillLevel) == "function" then
                vehicle.addFillUnitFillLevel = makeYieldWrapper(vehicle.addFillUnitFillLevel)
                patched = patched + 1
            end
        end
    end

    SoilLogger.info("[OK] Yield modifier hook installed (FillUnit.addFillUnitFillLevel) -- %d existing combines patched", patched)
    return true
end

-- =========================================================
-- HOOK 1c: Mower / Swather (forage crops cut to windrow)
-- =========================================================
-- Hooks Mower.onEndWorkAreaProcessing to capture nutrient depletion for crops
-- that are CUT but not direct-threshed: grass, alfalfa, clover, mowed triticale, etc.
--
-- Why not the Cutter hook?
--   Cutter.processCutterArea only reads the STANDING-CROP density map — it returns
--   0 area for windrow-pickup passes, so Cutter.onEndWorkAreaProcessing never fires
--   for mowed-crop scenarios.
--
-- Area source:
--   spec_mower.workAreaParameters.lastStatsArea  — density-map pixels cut this tick
--   MathUtil.areaToHa(pixels, g_currentMission:getFruitPixelsToSqm()) converts to hectares.
--
-- Depletion is area-based (not liter-based) via SoilFertilitySystem:onMow().
-- SoilConstants.MOWER_HA_FACTOR calibrates per-ha depletion relative to grain crops.
---@return boolean success True if hook installed successfully
function HookManager:installMowerHook()
    if not Mower or type(Mower.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[MowerHook] Mower.onEndWorkAreaProcessing not available — forage crop tracking skipped")
        return false
    end

    local hookMgrRef = self
    local original   = Mower.onEndWorkAreaProcessing
    Mower.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(mowerSelf, dt, hasProcessed)
            if not mowerSelf.isServer then return end
            if not g_SoilFertilityManager
               or not g_SoilFertilityManager.soilSystem
               or not g_SoilFertilityManager.settings.enabled
               or not g_SoilFertilityManager.settings.nutrientCycles then
                return
            end

            local spec = mowerSelf.spec_mower
            if not spec or not spec.workAreaParameters then return end

            -- lastStatsArea: density-map pixels processed this tick (same unit as Cutter's lastArea)
            local area = spec.workAreaParameters.lastStatsArea or 0
            if area <= 0 then return end

            local fruitType = spec.workAreaParameters.lastInputFruitType

            if not fruitType or fruitType <= 0 then return end

            local success, errorMsg = pcall(function()
                local x, _, z = getWorldTranslation(mowerSelf.rootNode)
                if not x then return end

                local fieldId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                if not fieldId or fieldId <= 0 then return end

                -- Convert density-map pixels → hectares.
                -- getFruitPixelsToSqm() is a method on g_currentMission, NOT a global.
                -- Mower.lua itself calls g_currentMission:getFruitPixelsToSqm() internally.
                if not g_currentMission or type(g_currentMission.getFruitPixelsToSqm) ~= "function" then return end
                local areaHa = MathUtil.areaToHa(area, g_currentMission:getFruitPixelsToSqm())
                if areaHa <= 0 then return end

                SoilLogger.debug("[MowerHook] Field %d, Crop %d, area=%.1f px (%.5f ha)",
                    fieldId, fruitType, area, areaHa)
                g_SoilFertilityManager.soilSystem:onMow(fieldId, fruitType, areaHa)
            end)

            if not success then
                SoilLogger.error("[MowerHook] failed: %s", tostring(errorMsg))
            end
        end
    )

    self:register(Mower, "onEndWorkAreaProcessing", original, "Mower.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Mower hook installed (Mower.onEndWorkAreaProcessing) — forage crop nutrient tracking active")
    return true
end

-- =========================================================
-- HOOK 1d: Mower yield scaling (#696)
-- =========================================================
-- Windrow-drop mowers (disc/drum mowers, swathers) bypass the combine hopper yield hook —
-- they never call addFillUnitFillLevel with spec_combine set. Inside processMowerArea the
-- windrow volume is:  litersToDrop = areaLiters × harvestMultiplier × converterData.conversionFactor
-- (verified against the Mower LUADOC). pickupFillScale is loaded but NEVER read on that path,
-- so the only lever that scales windrow output is conversionFactor on each fruitTypeConverter.
--
-- Approach: in onStartWorkAreaProcessing (before processMowerArea runs) multiply each
-- converter's conversionFactor by the field's forage nutrient modifier; restore it in
-- onEndWorkAreaProcessing. A pristine base (_sfBaseCF) is captured once per converter so
-- repeated passes never compound, even if an onEnd is somehow skipped. Nutrient DEPLETION
-- is untouched (area-based via the onEnd depletion hook) — only the bale output scales,
-- mirroring the combine path where the soil gives up nutrients regardless of yield.
---@return boolean success
function HookManager:installMowerYieldHook()
    if not Mower
       or type(Mower.onStartWorkAreaProcessing) ~= "function"
       or type(Mower.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("[MowerYield] Mower work-area functions not available — forage yield scaling skipped")
        return false
    end

    local hookMgrRef = self

    -- Return every converter on this mower to its pristine conversionFactor.
    local function restoreConverters(spec)
        if not spec or not spec.fruitTypeConverters then return end
        for _, converterData in pairs(spec.fruitTypeConverters) do
            if converterData._sfBaseCF ~= nil then
                converterData.conversionFactor = converterData._sfBaseCF
            end
        end
    end

    local origStart = Mower.onStartWorkAreaProcessing
    Mower.onStartWorkAreaProcessing = Utils.appendedFunction(
        origStart,
        function(mowerSelf, dt)
            if not mowerSelf.isServer then return end
            local spec = mowerSelf.spec_mower
            if not spec or not spec.fruitTypeConverters then return end
            if not g_SoilFertilityManager
               or not g_SoilFertilityManager.soilSystem
               or not g_SoilFertilityManager.settings.enabled
               or not g_SoilFertilityManager.settings.nutrientCycles then
                restoreConverters(spec)   -- never leave stale scaling when the system is off
                return
            end

            local ok, errMsg = pcall(function()
                local x, _, z = getWorldTranslation(mowerSelf.rootNode)
                if not x then return end
                local fieldId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                if not fieldId or fieldId <= 0 then
                    restoreConverters(spec)
                    return
                end

                local modifier = g_SoilFertilityManager.soilSystem:computeMowerYieldModifier(fieldId)
                for _, converterData in pairs(spec.fruitTypeConverters) do
                    -- Capture the pristine factor once; always scale from it so passes never compound.
                    if converterData._sfBaseCF == nil then
                        converterData._sfBaseCF = converterData.conversionFactor
                    end
                    converterData.conversionFactor = converterData._sfBaseCF * modifier
                end
                if modifier ~= 1.0 then
                    SoilLogger.debug("[MowerYield] Field %d forage modifier=%.3f", fieldId, modifier)
                end
            end)
            if not ok then
                SoilLogger.error("[MowerYield] start hook failed: %s", tostring(errMsg))
                restoreConverters(spec)
            end
        end
    )
    self:register(Mower, "onStartWorkAreaProcessing", origStart, "Mower.onStartWorkAreaProcessing (forage yield scale)")

    local origEnd = Mower.onEndWorkAreaProcessing
    Mower.onEndWorkAreaProcessing = Utils.appendedFunction(
        origEnd,
        function(mowerSelf, dt, hasProcessed)
            if not mowerSelf.isServer then return end
            restoreConverters(mowerSelf.spec_mower)
        end
    )
    self:register(Mower, "onEndWorkAreaProcessing", origEnd, "Mower.onEndWorkAreaProcessing (forage yield restore)")

    SoilLogger.info("[OK] Mower yield hook installed — windrow forage output now scales with soil nutrients")
    return true
end

-- =========================================================
-- HOOK 2: All fertilizer application (Sprayer + Spreader)
-- =========================================================
--- Hooks Sprayer.onEndWorkAreaProcessing, which covers ALL fertilizer vehicles:
--- liquid sprayers, manure spreaders, dry fertilizer spreaders, slurry tankers, etc.
--- All of these use the Sprayer specialization in FS25 — there is no separate Spreader class.
--- onEndWorkAreaProcessing is called via dynamic event dispatch (SpecializationUtil.registerEventListener),
--- so replacing Sprayer.onEndWorkAreaProcessing works at any time, including post-load.
---@return boolean success True if hook installed successfully
function HookManager:installSprayerAreaHook()
    if not Sprayer or type(Sprayer.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install sprayer area hook - Sprayer.onEndWorkAreaProcessing not available")
        return false
    end

    -- Capture the HookManager instance as an upvalue. g_SoilFertilityManager is the
    -- SoilFertilityManager (not HookManager) and the HookManager lives at
    -- g_SoilFertilityManager.soilSystem.hookManager — easy to get wrong, so we just
    -- capture `self` here and reference it directly in the closure.
    local hookMgrRef = self

    local original = Sprayer.onEndWorkAreaProcessing
    Sprayer.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(self, dt, hasProcessed)
            -- Server only
            if not self.isServer then return end

            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end

            local spec = self.spec_sprayer
            if not spec or not spec.workAreaParameters then return end

            -- Guard: sprayer must have a valid fill type and consumed product this frame.
            -- NOTE: We deliberately do NOT gate on spec.workAreaParameters.isActive here.
            -- isActive is only set true inside processSprayerArea when FSDensityMapUtil.updateSprayArea
            -- returns changedArea > 0 — i.e., when it actually paints terrain pixels.
            -- On fields that are already fully fertilized in the vanilla FS25 density map,
            -- updateSprayArea returns changedArea=0, isActive stays false, and our hook would
            -- silently skip every application even though the sprayer IS running and product IS
            -- being consumed. This was the root cause of "NPK never increases after field scan".
            -- Using sprayFillLevel > 0 and usage > 0 is the correct gate: if the sprayer has
            -- product and consumed some this frame, we should record the nutrient application.
            local fillTypeIndex = spec.workAreaParameters.sprayFillType
            local liters        = spec.workAreaParameters.usage
            local sprayFillLevel = spec.workAreaParameters.sprayFillLevel

            -- Issue #708: under AI/Courseplay control, vanilla onStartWorkAreaProcessing can
            -- leave wap.sprayFillType pointing at a different fill type than what is physically
            -- in the tank (multi-fill-unit machines, after a headland restart). Reading it as
            -- the product source then credits the WRONG nutrient profile to the soil and
            -- mislabels the HUD. Override at the top with the physical tank contents so the
            -- one fix corrects nutrient application, coverage label, and the custom-fill stamp
            -- together. The tank only wins when it holds a valid non-UNKNOWN type, so
            -- external-fill BUY mode (empty tank → keep wap value) is preserved.
            fillTypeIndex = SoilUtils.resolveSprayerFillTypeIndex(self, fillTypeIndex)

            -- wap.isActive is vanilla's own "I painted terrain and drained product this
            -- frame" flag: reset to false at the end of every onStartWorkAreaProcessing and
            -- set true only inside processSprayerArea, which runs only for genuinely active
            -- (lowered + on) work areas. Vanilla onEndWorkAreaProcessing removes fill ONLY
            -- when isActive is true, so isActive==true is hard proof the implement is
            -- applying to the ground right now — regardless of what getIsTurnedOn()/fold
            -- state report. Some modded spreaders (Agromet N250, JD34, T088 — issue #671)
            -- spread product while reporting getIsTurnedOn()==false and/or a fold state our
            -- guard reads as "folded", so the turnedOff/folded guards below would drop them
            -- every frame even though product is leaving the tank. We use isActive as a
            -- positive override: when the engine confirms active application, we trust it
            -- over those flags. We do NOT gate ON isActive (never skip merely because it is
            -- false) — the saturated-field path where isActive can be false still flows
            -- through via the turnedOn check and the usage/fillLevel/speed guards below.
            local wapActive = spec.workAreaParameters.isActive == true

            -- Issue #668 diagnostics: several spreaders (modded + some modhub manure
            -- spreaders, e.g. Agromet N250 / JD34) are recognized by the SprayUsage hook
            -- but never reach the nutrient apply below — a silent early-return drops them.
            -- Log which guard fired (throttled once / 3 s per vehicle, debug-mode only) so a
            -- single user log pinpoints the exact cause instead of us guessing.
            local function _sfApplySkipLog(reason)
                local _now = (g_currentMission and g_currentMission.time) or 0
                if not self._sfApplySkipLogAt or (_now - self._sfApplySkipLogAt) > 3000 then
                    self._sfApplySkipLogAt = _now
                    local ftName = "?"
                    local ft = fillTypeIndex and g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    if ft then ftName = ft.name end
                    SoilLogger.debug("SprayerHook SKIP [%s]: veh=%s type=%s usage=%s fillLevel=%s isActive=%s — nutrient apply skipped",
                        reason, tostring(self.id), ftName, tostring(liters), tostring(sprayFillLevel), tostring(wapActive))
                end
            end

            -- turnedOff guard (issue b16e5df: driving with the implement turned off must
            -- not apply). Skipped when wapActive — a working spreader that mis-reports
            -- getIsTurnedOn()==false (issue #671) still applies because the engine confirmed
            -- ground application this frame. A genuinely-off implement never processes a work
            -- area, so wapActive is false and this guard still catches it.
            if not wapActive and self.getIsTurnedOn ~= nil and not self:getIsTurnedOn() then
                _sfApplySkipLog("turnedOff")
                return
            end

            -- Guard: folded implement must not record nutrient application.
            -- Mirror vanilla Foldable line 1286: working position is dir==-1,fa==0 OR dir==1,fa==1.
            -- turnOnFoldDirection is always 1 or -1 after Foldable init; nil falls back to
            -- animation-only detection (0 < fa < 1).
            -- Skipped when wapActive: a folded implement in transport raises its work areas,
            -- so the engine never processes them and wapActive stays false — the guard still
            -- fires. But a working spreader whose foldable spec our heuristic misreads as
            -- "folded" (issue #671) has wapActive true and is correctly let through.
            if not wapActive and self.spec_foldable then
                local foldSpec = self.spec_foldable
                local fa  = foldSpec.foldAnimTime
                local dir = foldSpec.turnOnFoldDirection
                if fa ~= nil then
                    local folded = dir ~= nil and ((dir == -1 and fa ~= 0) or (dir == 1 and fa ~= 1))
                                or (dir == nil and fa > 0 and fa < 1)
                    if folded then
                        _sfApplySkipLog("folded")
                        return
                    end
                end
            end

            if not fillTypeIndex or fillTypeIndex <= 0 then return end

            -- Track the active custom fill type BEFORE the liters/sprayFillLevel guards.
            -- When AI uses external-fill BUY mode, wap.usage is always 0 (no tank depletion),
            -- so the guards below would exit early every frame and _soilLastCustomFillType
            -- would never be set. getExternalFill (Hook 9) relies on this field to identify
            -- the intended product when fillType arrives as UNKNOWN — without it, Hook 9
            -- falls through to original and no money is ever charged (issue #205).
            do
                local _hm = hookMgrRef
                if _hm and _hm.customFillTypePrices and _hm.customFillTypePrices[fillTypeIndex] then
                    self._soilLastCustomFillType = fillTypeIndex
                end
            end

            if not liters or liters <= 0 then
                -- Throttle: log at most once per 3 s per vehicle to avoid headland-turn spam
                local _now = g_currentMission and g_currentMission.time or 0
                if not self._sfZeroUsageLogAt or (_now - self._sfZeroUsageLogAt) > 3000 then
                    self._sfZeroUsageLogAt = _now
                    SoilLogger.debug("SprayerHook: usage=0 for fillType=%d fillLevel=%.1f — no product consumed (multi-boom or section-control gate?)",
                        fillTypeIndex or -1, sprayFillLevel or 0)
                end
                return
            end
            if not sprayFillLevel or sprayFillLevel <= 0 then
                _sfApplySkipLog("noFillLevel")
                return
            end

            -- Require minimum forward speed (matches WeedSpotSpray.onEndWorkAreaProcessing).
            -- A stationary sprayer drains the tank and consumes liters but covers no ground —
            -- without this guard coverage climbs to 100% without moving.
            local _spd = tonumber(self.getLastSpeed and self:getLastSpeed()) or 0
            -- Towed spreaders/sprayers have no independent physics body, so their own
            -- getLastSpeed() can report ~0 even while the tractor is moving. Borrow the
            -- rootVehicle (tractor) speed the same way installSprayerUsageHook does
            -- (issue #668) — without this a moving towed manure spreader is silently
            -- dropped here even though SprayUsage shows it consuming product.
            if _spd < 0.5 then
                local root = self.rootVehicle
                if root and root ~= self and root.getLastSpeed then
                    local rootSpd = tonumber(root:getLastSpeed()) or 0
                    if rootSpd > _spd then _spd = rootSpd end
                end
            end
            if _spd < 0.5 then
                _sfApplySkipLog(string.format("tooSlow spd=%.2f", _spd))
                return
            end

            local success, errorMsg = pcall(function()
                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                if not fillType then return end

                -- Check herbicide first (mutually exclusive with fertilizer profiles)
                local herbTypes = SoilConstants.WEED_PRESSURE and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES
                local herbEffectiveness = herbTypes and herbTypes[fillType.name]
                
                -- Check insecticide
                local pestTypes = SoilConstants.PEST_PRESSURE and SoilConstants.PEST_PRESSURE.INSECTICIDE_TYPES
                local pestEffectiveness = pestTypes and pestTypes[fillType.name]
                
                -- Check fungicide
                local diseaseTypes = SoilConstants.DISEASE_PRESSURE and SoilConstants.DISEASE_PRESSURE.FUNGICIDE_TYPES
                local diseaseEffectiveness = diseaseTypes and diseaseTypes[fillType.name]
                
                local isFertilizer = SoilConstants.FERTILIZER_PROFILES[fillType.name] ~= nil

                -- Crop protection products (INSECTICIDE, FUNGICIDE, HERBICIDE) that are also
                -- listed in FERTILIZER_PROFILES carry pestReduction/diseaseReduction markers
                -- and are routed through applyFertilizer → on*Applied internally.
                -- We must NOT also call on*Applied directly from here, or they would be
                -- double-applied. Only use the direct path for products NOT in FERTILIZER_PROFILES
                -- (e.g. vanilla HERBICIDE / PESTICIDE fill types that have no profile entry).
                local herbOnlyDirect = herbEffectiveness and not isFertilizer
                local pestOnlyDirect = pestEffectiveness and not isFertilizer
                local diseaseOnlyDirect = diseaseEffectiveness and not isFertilizer

                if not isFertilizer and not herbOnlyDirect and not pestOnlyDirect and not diseaseOnlyDirect then return end

                -- Resolve field from vehicle root position.
                -- When the tractor body straddles a field boundary (common on edge fields),
                -- rootNode may fall outside the polygon and return nil. Fall back to the
                -- work-area midpoint of each attached implement so LIQUIDLIME and other
                -- products applied by a trailed sprayer are attributed correctly.
                local x, _, z = getWorldTranslation(self.rootNode)
                if not x then return end

                -- PHASE 5: route through shared MapDataGrid-backed cache.
                -- skipNegativeCache=true: if the cache has a stale -1 for this position
                -- (queried before the field was registered, e.g. freshly-purchased land),
                -- fall through to the live g_fieldManager slow-path query rather than
                -- returning nil and silently dropping the fertilizer application.
                local fieldId = hookMgrRef:getFieldIdAtWorldPosition(x, z, true)

                -- Fallback: try the midpoints of work areas on attached implements
                if not fieldId or fieldId <= 0 then
                    local attachedImpls = self.spec_attacherJoints and self.spec_attacherJoints.attachedImplements
                    if attachedImpls then
                        for _, impl in ipairs(attachedImpls) do
                            local obj = impl and impl.object
                            if obj then
                                -- Try implement rootNode first
                                local ix, _, iz = getWorldTranslation(obj.rootNode)
                                if ix then fieldId = hookMgrRef:getFieldIdAtWorldPosition(ix, iz, true) end
                                -- Then try each work area start point
                                if (not fieldId or fieldId <= 0) and obj.spec_workArea and obj.spec_workArea.workAreas then
                                    for _, wa in ipairs(obj.spec_workArea.workAreas) do
                                        if wa.start then
                                            local sx, _, sz = getWorldTranslation(wa.start)
                                            if sx then fieldId = hookMgrRef:getFieldIdAtWorldPosition(sx, sz, true) end
                                        end
                                        if fieldId and fieldId > 0 then break end
                                    end
                                end
                            end
                            if fieldId and fieldId > 0 then break end
                        end
                    end
                end

                if not fieldId or fieldId <= 0 then
                    SoilLogger.debug("SprayerHook: no field at rootNode (%.1f,%.1f) — skipping %s apply",
                        x, z, fillType and fillType.name or "?")
                    return
                end

                -- Rate multiplier is applied to wap.usage by installSprayerStartHook before
                -- onEndWorkAreaProcessing runs. liters (= wap.usage) already reflects the
                -- multiplier; do NOT multiply again or nutrient gain would be multiplier².
                -- Keep rateMultiplier lookup for burn-threshold check only.
                local rm = g_SoilFertilityManager.sprayerRateManager
                local rateMultiplier = (rm ~= nil) and rm:getMultiplier(self.id) or 1.0
                local effectiveLiters = liters

                -- Section Control double-penalty fix (Issue #345):
                -- wap.usage already reflects section shutoff (VariableWorkWidth.getIsWorkAreaActive
                -- gates each work area on section.isActive), so 'liters' is already proportionally reduced.
                -- Do NOT multiply by coverageFraction again, otherwise we quadratically penalize the dosage.

                -- ── Coverage tracking ──────────────────────────────────────────────
                -- updateFractions=false: markBoomCells (called below) owns coverage for
                -- fertilizers via spatial cell deduplication. trackSprayerCoverage here
                -- only records the product name for the HUD label.
                -- Crop protection direct paths (herbicide/insecticide/fungicide) have no
                -- boomPoints, so coverage must be tracked via the liter-based fallback
                -- (updateFractions=true). Fertilizers use markBoomCells for spatial
                -- deduplication and must pass false to avoid double-counting.
                if g_SoilFertilityManager.soilSystem then
                    g_SoilFertilityManager.soilSystem:trackSprayerCoverage(fieldId, liters, fillType.name, not isFertilizer)
                end

                -- ── Sub-field section attribution (issue #300) ────────────────────
                -- When VariableWorkWidth is present, distribute the nutrient credit
                -- across active section nodes so that boundary passes only affect the
                -- portion of the field the boom is actually spraying.
                -- Falls back to the rootNode single-field path when VWW is absent.
                local rootX, _, rootZ = getWorldTranslation(self.rootNode)
                local vww = self.spec_variableWorkWidth
                local soilSys = g_SoilFertilityManager.soilSystem

                local function applySingle(fId, sectionLiters, spx, spz)
                    if not fId or fId <= 0 then return end
                    if soilSys then
                        soilSys._lastSprayX = spx or rootX
                        soilSys._lastSprayZ = spz or rootZ
                    end
                    SoilLogger.debug("Sprayer/Spreader hook: Field %d, %s, %.4fL (x%.2f rate)",
                        fId, fillType.name, sectionLiters, rateMultiplier)
                    if isFertilizer then
                        soilSys:onFertilizerApplied(fId, fillTypeIndex, sectionLiters)
                    end
                    if herbOnlyDirect and soilSys.onHerbicideAppliedDirect then
                        soilSys:onHerbicideAppliedDirect(fId, herbEffectiveness, sectionLiters)
                    end
                    if pestOnlyDirect and soilSys.onInsecticideAppliedDirect then
                        soilSys:onInsecticideAppliedDirect(fId, pestEffectiveness, sectionLiters)
                    end
                    if diseaseOnlyDirect and soilSys.onFungicideAppliedDirect then
                        soilSys:onFungicideAppliedDirect(fId, diseaseEffectiveness, sectionLiters)
                    end
                    local entry = SoilConstants.FERTILIZER_PROFILES[fillType.name]
                    if entry and (entry.N or entry.P or entry.K) and
                       rateMultiplier > SoilConstants.SPRAYER_RATE.BURN_RISK_THRESHOLD then
                        soilSys:applyBurnEffect(fId, rateMultiplier)
                    end
                end

                if vww and vww.sections and #vww.sections > 0 then
                    SoilLogger.debug("SprayerHook: VWW path — %d total sections for %s", #vww.sections, fillType.name)
                    -- Collect active sections into pre-allocated scratch table (avoids per-tick allocation)
                    local scratch = hookMgrRef._sectionScratch
                    local scratchN = 0
                    for _, section in ipairs(vww.sections) do
                        if section.isActive or section.isCenter then
                            scratchN = scratchN + 1
                            scratch[scratchN] = section
                        end
                    end
                    for i = scratchN + 1, #scratch do scratch[i] = nil end

                    if scratchN > 0 then
                        -- Variable Rate (System 3): look up per-section weights if active
                        local vrSectionRates = nil
                        do
                            local sfmVR = g_SoilFertilityManager
                            local smVR  = sfmVR and sfmVR.sensorManager
                            if smVR and smVR.sectionRates then
                                vrSectionRates = smVR.sectionRates[self.id]
                            end
                        end

                        -- Normalize VR weights so total nutrient credit == effectiveLiters.
                        -- VR redistribution does NOT change the total; it only shifts credit
                        -- toward deficit sections. Without normalization, applySingle would
                        -- receive (wap.usage * manualMult) * vrWeight — a double reduction
                        -- when auto rate selects a sub-unity multiplier (#555/#538).
                        local vrWeightSum = 0.0
                        for i = 1, scratchN do
                            local w = (vrSectionRates and vrSectionRates[scratch[i]]) or 1.0
                            vrWeightSum = vrWeightSum + w
                        end
                        -- vrWeightSum == 0 only if all weights are 0 (degenerate); guard.
                        if vrWeightSum <= 0 then vrWeightSum = scratchN end

                        for i = 1, scratchN do
                            local section = scratch[i]
                            local sx, sz = rootX, rootZ
                            if not section.isCenter and section.maxWidthNode ~= nil then
                                local wx, _, wz = getWorldTranslation(section.maxWidthNode)
                                if wx then
                                    -- Midpoint: accurate field lookup, better lateral density paint
                                    sx = (rootX + wx) * 0.5
                                    sz = (rootZ + wz) * 0.5
                                end
                            end
                            local sectionFieldId = hookMgrRef:getFieldIdAtWorldPosition(sx, sz)
                            -- Midpoint can fall outside field boundary when spraying edges.
                            -- Fall back: try the boom tip position directly, then sprayer center.
                            if (not sectionFieldId or sectionFieldId <= 0) and
                               not section.isCenter and section.maxWidthNode ~= nil then
                                local wx2, _, wz2 = getWorldTranslation(section.maxWidthNode)
                                if wx2 then
                                    sectionFieldId = hookMgrRef:getFieldIdAtWorldPosition(wx2, wz2)
                                end
                            end
                            if not sectionFieldId or sectionFieldId <= 0 then
                                sectionFieldId = fieldId  -- final fallback: credit the main field
                            end
                            local vrWeight = (vrSectionRates and vrSectionRates[section]) or 1.0
                            -- Proportional share: preserves total = effectiveLiters
                            local sectionLiters = effectiveLiters * (vrWeight / vrWeightSum)
                            applySingle(sectionFieldId, sectionLiters, sx, sz)
                        end
                    else
                        applySingle(fieldId, effectiveLiters, rootX, rootZ)
                    end
                else
                    -- No VWW: single-field path (rootNode already resolved above)
                    if soilSys then
                        soilSys._lastSprayX = rootX
                        soilSys._lastSprayZ = rootZ
                    end
                    applySingle(fieldId, effectiveLiters, rootX, rootZ)
                end

                -- Sweep all cells under the full boom width for display (#362).
                -- Nutrients are already attributed to the field by applySingle/section loop;
                -- markBoomCells only stamps display entries for unvisited lateral cells.
                --
                -- Pass% / session-ha accounting depends on the implement type:
                --   • VWW sprayers/spreaders: markBoomCells owns the counter — its per-section
                --     cell dedup is accurate and matches the overlap-prevention grace logic.
                --   • Broadcast / dry spreaders (no VWW): markBoomCells routes every boom cell
                --     through a per-field polygon test that credits the FIRST field on the
                --     farmland, so on multi-field farmlands (and other geometry edge cases) the
                --     cells are rejected and the counter freezes — dry spreaders "paint but the
                --     pass% / ha never move" while liquid sprayers work (#650). #626 rerouted
                --     solids onto this path; the reliable liter-based estimate (#454) has no
                --     polygon dependency, so we use it for the counter and let markBoomCells
                --     stamp the visual overlay only.
                if soilSys and fieldId and fieldId > 0 then
                    local vww = self.spec_variableWorkWidth
                    local hasVWW = vww and vww.sections and #vww.sections > 0
                    local boomPts = hookMgrRef:getBoomCellPositions(self, rootX, rootZ)
                    if hasVWW and boomPts then
                        soilSys:markBoomCells(fieldId, boomPts)
                    else
                        -- Broadcast / dry spreader (or any vehicle with no spanning boom).
                        if boomPts then
                            soilSys:markBoomCells(fieldId, boomPts, true)  -- overlay only
                        end
                        -- Fertilizers advance the counter here via the liter estimate. Crop
                        -- protection products already did so in the trackSprayerCoverage call
                        -- above (updateFractions = not isFertilizer), so don't double-count.
                        if liters > 0 and isFertilizer then
                            soilSys:trackSprayerCoverage(fieldId, liters, fillType.name, true)
                        end
                    end
                end

                -- BUY mode backup refill (issue #125).
                -- SpecializationUtil.registerFunction may cache function references before
                -- our FillUnit.addFillUnitFillLevel hook installs, so the class-level hook
                -- may be bypassed. Here we handle BUY mode reliably: the tank already depleted
                -- (original ran first), so we add the consumed liters back and charge the farm.
                --
                -- IMPORTANT (issue #205 opt-in path): when getIsSprayerExternallyFilled()
                -- returns true AND getExternalFill returns a valid type, vanilla's
                -- onStartWorkAreaProcessing sets sprayVehicle=nil AND
                -- onEndWorkAreaProcessing skips addFillUnitFillLevel entirely.
                -- The tank was NEVER drained, so adding liters here would inflate the level.
                -- Detect this by checking wap.sprayVehicle == nil after vanilla ran.
                do
                    local wap = spec.workAreaParameters
                    if wap and wap.sprayVehicle == nil then
                        -- External fill path active — tank untouched, getExternalFill already
                        -- charged the farm. Skip backup refill entirely.
                        SoilLogger.debug("BUY SKIP backup refill: external fill path active (sprayVehicle=nil) veh=%d", self.id or 0)
                        return  -- exit pcall closure, backup refill block below is skipped
                    end
                end

                local hookMgr = hookMgrRef
                local buyPrices = hookMgr and hookMgr.customFillTypePrices
                local pricePerLiter = buyPrices and buyPrices[fillTypeIndex]
                if pricePerLiter then
                    -- Courseplay-aware AI detection (mirrors isInBuyMode above).
                    -- getIsAIActive() returns false for CP-driven vehicles; we must also
                    -- check CP's own spec and legacy vehicle.cp flag.
                    local isAI = false
                    local okAI, resAI = pcall(function() return self:getIsAIActive() end)
                    if okAI and resAI then isAI = true end
                    if not isAI and self.spec_aiVehicle and self.spec_aiVehicle.isActive then
                        isAI = true
                    end
                    if not isAI and self.spec_aiJobVehicle and self.spec_aiJobVehicle.job ~= nil then
                        isAI = true
                    end
                    -- Courseplay (modern)
                    if not isAI and self.spec_cpAIWorker and self.spec_cpAIWorker.isActive then
                        isAI = true
                    end
                    -- Courseplay (legacy)
                    if not isAI and self.cp and self.cp.isActive then
                        isAI = true
                    end
                    -- Check if a human player is currently driving this vehicle (or its root vehicle).
                    -- For towed implements (spreaders, trailing sprayers), self has no cab —
                    -- getIsEntered() returns false even when the player is in the pulling tractor.
                    -- We must check the rootVehicle too.
                    local isEntered = false
                    local function checkEntered(v)
                        if not v then return false end
                        local okE, resE = pcall(function() return v:getIsEntered() end)
                        if okE and resE then return true end
                        if v.spec_enterable and v.spec_enterable.controlledPlayer ~= nil then return true end
                        return false
                    end
                    isEntered = checkEntered(self)
                    if not isEntered then
                        isEntered = checkEntered(self.rootVehicle)
                    end
                    if isAI and not isEntered and g_currentMission and g_currentMission.missionInfo then
                        local mi = g_currentMission.missionInfo
                        local ftName = fillType.name
                        local buyActive = false
                        if ftName == "LIQUIDMANURE" or ftName == "DIGESTATE" then
                            buyActive = (mi.helperSlurrySource == 2)
                        elseif ftName == "MANURE" then
                            buyActive = (mi.helperManureSource == 2)
                        else
                            buyActive = (mi.helperBuyFertilizer == true)
                        end
                        if buyActive then
                            -- Only refill if this wasn't already handled by the FillUnit hook.
                            -- We check via a per-vehicle stamp set by the FillUnit hook.
                            local alreadyHandled = self._soilBuyHandledAt and (g_currentMission.time - self._soilBuyHandledAt) < 200
                            if not alreadyHandled then
                                local fillUnitIndex = 1
                                local okFui, fuiVal = pcall(function() return self:getSprayerFillUnitIndex() end)
                                if okFui and fuiVal then fillUnitIndex = fuiVal end

                                -- Directly restore the fill level in the spec table.
                                -- self:addFillUnitFillLevel() goes through the game's network-sync
                                -- and farm-permission pipeline, which silently rejects writes on
                                -- AI-controlled vehicles (no active player session).
                                -- Writing the spec field directly is safe here — we are server-side
                                -- inside an appendedFunction that runs after the drain already happened.
                                local spec = self.spec_fillUnit
                                local fu = spec and spec.fillUnits and spec.fillUnits[fillUnitIndex]
                                if fu then
                                    -- Use the game API for capacity (spec field name varies by vehicle XML).
                                    local cap = fu.fillLevel + liters  -- safe fallback: just undo the drain
                                    local okCap, capVal = pcall(function() return self:getFillUnitCapacity(fillUnitIndex) end)
                                    if okCap and capVal and capVal > 0 then cap = capVal end
                                    fu.fillLevel = math.min(cap, fu.fillLevel + liters)
                                    -- Raise dirty flag so HUD and network layer pick up the new value.
                                    if spec.fillUnitsDirtyFlag then
                                        pcall(function() self:raiseDirtyFlags(spec.fillUnitsDirtyFlag) end)
                                    end
                                end

                                -- Resolve farmId — try every path in order of reliability for AI vehicles.
                                -- getActiveFarm() is on Sprayer spec; ownerFarmId is a plain table field
                                -- always present on every vehicle; getOwnerFarmId() returns 0 when no
                                -- player session is active (i.e. always 0 for AI-only vehicles).
                                local farmId = nil
                                pcall(function() farmId = self:getActiveFarm() end)
                                if not farmId or farmId <= 0 then
                                    farmId = self.ownerFarmId
                                end
                                if not farmId or farmId <= 0 then
                                    farmId = self.spec_enterable and self.spec_enterable.activeFarmId
                                end
                                if not farmId or farmId <= 0 then
                                    pcall(function() farmId = self:getOwnerFarmId() end)
                                end
                                local cost = liters * pricePerLiter
                                if farmId and farmId > 0 then
                                    pcall(function()
                                        -- Match Hook 9 (getExternalFill) signature — no extra bool args.
                                        g_currentMission:addMoney(-cost, farmId, MoneyType.PURCHASE_FERTILIZER)
                                    end)
                                end
                                SoilLogger.debug("BUY REFILL (sprayer hook): veh=%d, type=%s, liters=%.2f, cost=%.2f",
                                    self.id or 0, ftName, liters, cost)
                            end
                        end
                    end
                end
            end)

            if not success then
                SoilLogger.error("Sprayer area hook failed: %s", tostring(errorMsg))
            end
        end
    )
    self:register(Sprayer, "onEndWorkAreaProcessing", original, "Sprayer.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Sprayer/Spreader hook installed (Sprayer.onEndWorkAreaProcessing)")
    return true
end

-- =========================================================
-- HOOK 3: Field ownership changes (MessageType.FARMLAND_OWNER_CHANGED)
-- =========================================================
-- g_farmlandManager.fieldOwnershipChanged does not exist in FS25.
-- The correct pattern is g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, cb, target).
-- Callback receives: farmlandId, farmId, loadFromSavegame
-- loadFromSavegame=true fires for every field on game load; we skip those to avoid
-- resetting existing soil data on a fresh load.
---@return boolean success True if hook installed successfully
function HookManager:installOwnershipHook()
    if not g_messageCenter or not MessageType or not MessageType.FARMLAND_OWNER_CHANGED then
        SoilLogger.warning("Could not install ownership hook - g_messageCenter or MessageType.FARMLAND_OWNER_CHANGED not available")
        return false
    end

    local function onOwnerChanged(farmlandId, farmId, loadFromSavegame)
        if loadFromSavegame then return end  -- skip initial population on load
        if not g_SoilFertilityManager or
           not g_SoilFertilityManager.soilSystem or
           not g_SoilFertilityManager.settings.enabled then
            return
        end

        local success, errorMsg = pcall(function()
            -- farmlandId is used as the fieldId key (same value; FS25 uses farmland IDs throughout)
            g_SoilFertilityManager.soilSystem:onFieldOwnershipChanged(farmlandId, farmlandId, farmId)
        end)

        if not success then
            SoilLogger.error("Ownership hook failed: %s", tostring(errorMsg))
        end
    end

    g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, onOwnerChanged, self)

    -- Register cleanup so uninstallAll() unsubscribes correctly
    self:registerCleanup("MessageType.FARMLAND_OWNER_CHANGED", function()
        g_messageCenter:unsubscribeAll(self)
    end)

    SoilLogger.info("[OK] Field ownership hook installed (MessageType.FARMLAND_OWNER_CHANGED)")
    return true
end

-- =========================================================
-- HOOK: Native FIELD INFO injection
-- =========================================================
-- Appends our soil rows directly into the base game's own FIELD INFO box instead of
-- spawning a separate panel.
--
-- PlayerHUDUpdater.fieldAddFarmland(hudUpdater, data, box) is the base-game function that
-- populates the FIELD INFO box (owner, size, soil type…) whenever the player/vehicle is on
-- farmland. `box` is the live InfoDisplayKeyValueBox the base game is already drawing this
-- frame. Utils.appendedFunction runs our callback AFTER the base game's own logic, with the
-- same arguments, so we can call box:addLine(...) again to tack our rows onto the SAME box.
-- We never call box:clear()/box:setTitle() — that would wipe the base game's own rows.
---@return boolean success True if hook installed successfully
function HookManager:installNativeFieldInfoHook()
    if PlayerHUDUpdater == nil or PlayerHUDUpdater.fieldAddFarmland == nil then
        SoilLogger.warning("Could not install native field info hook - PlayerHUDUpdater.fieldAddFarmland not available")
        return false
    end

    local hookManagerSelf = self -- captured upvalue for getFieldIdAtWorldPosition's cache

    --- Resolves a vehicle's world (x, z). Tries rootNode first, then falls back to
    --- components[1].node — some vehicle types (notably certain implements/trailers) don't
    --- expose rootNode directly. This gap (no components[1] fallback) in an earlier version
    --- of this hook was the most likely cause of silent fieldId-resolution failures.
    local function getVehiclePositionXZ(vehicle)
        if vehicle == nil then
            return nil, nil
        end

        local node = vehicle.rootNode
        if node == nil and vehicle.components ~= nil and vehicle.components[1] ~= nil then
            node = vehicle.components[1].node
        end
        if node == nil then
            return nil, nil
        end

        local ok, x, _, z = pcall(getWorldTranslation, node)
        if ok then return x, z end
        return nil, nil
    end

    --- Resolves the world (x, z) the player is currently associated with — controlled
    --- vehicle first (covers driving/standing-in), then the on-foot player root node.
    --- Mirrors the proven SoilWorkYieldBonus:getPlayerPositionXZ() priority order exactly.
    local function getPlayerOrVehiclePositionXZ()
        if g_currentMission ~= nil and g_currentMission.controlledVehicle ~= nil then
            local x, z = getVehiclePositionXZ(g_currentMission.controlledVehicle)
            if x ~= nil then return x, z end
        end

        if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
            local ok, x, _, z = pcall(getWorldTranslation, g_localPlayer.rootNode)
            if ok then return x, z end
        end

        return nil, nil
    end

    --- Pulls a numeric fieldId out of an arbitrary "field-like" value: a raw id, an object
    --- with getId()/.fieldId/.id, or (last resort) any nested table carrying .fieldId/.id.
    --- Ported from the proven SoilWorkYieldBonus:getFieldIdFromFieldValue().
    local function getFieldIdFromFieldValue(field)
        if field == nil then return nil end
        if type(field) == "number" then return field end
        if type(field) ~= "table" then return nil end

        if field.getId ~= nil then
            local ok, fieldId = pcall(field.getId, field)
            if ok and fieldId ~= nil then return fieldId end
        end
        if field.fieldId ~= nil then return field.fieldId end
        if field.id ~= nil then return field.id end

        for _, value in pairs(field) do
            if type(value) == "table" then
                local fieldId = value.fieldId or value.id
                if fieldId ~= nil then return fieldId end
            end
        end

        return nil
    end

    --- Ported from SoilWorkYieldBonus:getFarmlandIdFromValue().
    local function getFarmlandIdFromValue(farmland)
        if farmland == nil then return nil end
        if type(farmland) == "number" then return farmland end
        if type(farmland) ~= "table" then return nil end
        return farmland.id or farmland.farmlandId
    end

    --- Resolves a fieldId from a farmlandId (or farmland object), trying the field manager's
    --- farmland→field mapping first, then the farmland's own .field, falling back to treating
    --- the farmlandId as the fieldId directly (true on most FS25 maps).
    --- Ported from SoilWorkYieldBonus:getFieldIdByFarmlandId().
    local function getFieldIdByFarmlandId(farmlandId)
        if farmlandId == nil then return nil end

        local farmland = nil
        if type(farmlandId) == "table" then
            farmland = farmlandId
            farmlandId = getFarmlandIdFromValue(farmland)
        end
        if farmlandId == nil then return nil end

        local field = nil
        if g_fieldManager ~= nil and g_fieldManager.farmlandIdFieldMapping ~= nil then
            field = g_fieldManager.farmlandIdFieldMapping[farmlandId]
        end

        local fieldId = getFieldIdFromFieldValue(field)
        if fieldId ~= nil then return fieldId end

        if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandById ~= nil then
            farmland = farmland or g_farmlandManager:getFarmlandById(farmlandId)
            if farmland ~= nil then
                fieldId = getFieldIdFromFieldValue(farmland.field)
                if fieldId ~= nil then return fieldId end
            end
        end

        return farmlandId
    end

    --- Pulls a fieldId directly out of the `data` argument fieldAddFarmland is called with —
    --- i.e. the exact subject the FIELD INFO box is about to display, regardless of what world
    --- position we could or couldn't resolve. This is the fallback that matters most: position
    --- lookups can miss (elevated cabs, odd vehicle node hierarchies, MapDataGrid cache misses),
    --- but `data` already IS the field being shown. Ported from
    --- SoilWorkYieldBonus:getFieldIdFromFieldInfoData().
    local function getFieldIdFromFieldInfoData(data)
        if data == nil then return nil end
        if data.fieldId ~= nil then return data.fieldId end

        local fieldId = getFieldIdFromFieldValue(data.field)
        if fieldId ~= nil then return fieldId end

        fieldId = getFieldIdFromFieldValue(data.fieldData)
        if fieldId ~= nil then return fieldId end

        if data.farmland ~= nil then
            fieldId = getFieldIdFromFieldValue(data.farmland.field)
            if fieldId ~= nil then return fieldId end

            fieldId = getFieldIdByFarmlandId(data.farmland)
            if fieldId ~= nil then return fieldId end

            if data.farmland.id ~= nil then
                fieldId = getFieldIdByFarmlandId(data.farmland.id)
                if fieldId ~= nil then return fieldId end
            end
        end

        if data.farmlandId ~= nil then
            fieldId = getFieldIdByFarmlandId(data.farmlandId)
            if fieldId ~= nil then return fieldId end
        end

        return nil
    end

    --- PlayerHUDUpdater.fieldAddFarmland's exact parameter order isn't guaranteed to match
    --- across FS25 builds/patches (and the (hudUpdater, data, box) order quoted in third-party
    --- examples may simply be wrong for this version). Rather than assume a position, scan the
    --- call args for whichever one actually quacks like an InfoDisplayKeyValueBox.
    local function findBoxArg(...)
        for i = 1, select("#", ...) do
            local arg = select(i, ...)
            if type(arg) == "table" and type(arg.addLine) == "function" then
                return arg
            end
        end
        return nil
    end

    --- Maps which native hook call each buildFieldInfoLines() row group is appended after --
    --- "early" rows land right after the native Farmland/Owned by rows (fieldAddFarmland),
    --- "late" rows land right after the native Crop type/Growth rows (fieldAddFruit). Must be
    --- declared before onFieldAddFarmland below, since it's captured as an upvalue there.
    local GROUP_FOR_SOURCE = {
        fieldAddFarmland = "early",
        fieldAddFruit    = "late",
    }

    local function onFieldAddFarmland(sourceFnName, hudUpdater, data, box, ...)
        if hookManagerSelf._nativeFieldInfoFired == nil then
            hookManagerSelf._nativeFieldInfoFired = {}
        end
        if hookManagerSelf._nativeFieldInfoFired[sourceFnName] ~= true then
            hookManagerSelf._nativeFieldInfoFired[sourceFnName] = true
            SoilLogger.info("Native field info hook: PlayerHUDUpdater.%s fired for the first time (argc=%d)",
                sourceFnName, select("#", hudUpdater, data, box, ...))
        end

        -- Prefer the documented (hudUpdater, data, box) order — that's what the proven
        -- SoilWorkYieldBonus mod relies on. Only fall back to scanning if it doesn't hold,
        -- as a safety net against a base-game signature change.
        if not (type(box) == "table" and type(box.addLine) == "function") then
            box = findBoxArg(hudUpdater, data, box, ...)
        end

        if box == nil then
            if hookManagerSelf._nativeFieldInfoDiagCount == nil then
                hookManagerSelf._nativeFieldInfoDiagCount = 0
            end
            if hookManagerSelf._nativeFieldInfoDiagCount < 5 then
                hookManagerSelf._nativeFieldInfoDiagCount = hookManagerSelf._nativeFieldInfoDiagCount + 1
                local argTypes = {}
                for i, arg in ipairs({hudUpdater, data, box, ...}) do
                    table.insert(argTypes, string.format("arg%d=%s", i, type(arg)))
                end
                SoilLogger.warning("Native field info hook: fieldAddFarmland fired but no addLine-capable arg found (%s) — base game signature may not match; injection skipped",
                    table.concat(argTypes, ", "))
            end
            return
        end

        if g_SoilFertilityManager == nil
            or g_SoilFertilityManager.soilSystem == nil
            or g_SoilFertilityManager.settings == nil
            or g_SoilFertilityManager.settings.enabled == false
            or g_SoilFertilityManager.settings.showFieldInfoBox == false then
            return
        end

        -- fieldId resolution: position first (matches what's actually under the player/
        -- vehicle), then fall back to pulling it straight out of `data` — the exact subject
        -- the box is already displaying. Order ported from the proven SoilWorkYieldBonus mod.
        local fieldId = nil
        local x, z = getPlayerOrVehiclePositionXZ()
        if x ~= nil then
            fieldId = hookManagerSelf:getFieldIdAtWorldPosition(x, z)
        end
        if fieldId == nil then
            fieldId = getFieldIdFromFieldInfoData(data)
        end

        if fieldId == nil then
            if hookManagerSelf._nativeFieldInfoFieldIdDiagCount == nil then
                hookManagerSelf._nativeFieldInfoFieldIdDiagCount = 0
            end
            if hookManagerSelf._nativeFieldInfoFieldIdDiagCount < 5 then
                hookManagerSelf._nativeFieldInfoFieldIdDiagCount = hookManagerSelf._nativeFieldInfoFieldIdDiagCount + 1
                SoilLogger.warning("Native field info hook: box found but fieldId could not be resolved (position=%s, data=%s)",
                    tostring(x ~= nil), tostring(data ~= nil))
            end
            return
        end

        local info = g_SoilFertilityManager.soilSystem:getFieldInfo(fieldId)
        if info == nil then
            return
        end

        -- Reuse the same line-building logic the (legacy) standalone Soil Nutrients panel
        -- used, so the two never drift out of sync. soilHUD is only created client-side
        -- (see SoilFertilityManager init), which matches where this hook actually fires.
        if g_SoilFertilityManager.soilHUD == nil or g_SoilFertilityManager.soilHUD.buildFieldInfoLines == nil then
            return
        end

        local lines = g_SoilFertilityManager.soilHUD:buildFieldInfoLines(info)
        -- Skip our own deficit-style "Yield" row here -- when the native-row override
        -- above (see installFieldInfoFn) successfully matched and replaced the vanilla
        -- "Yield bonus" row, that row already shows our number; a second appended Yield
        -- row would just be confusing duplicate information. If the override could not
        -- find a native row to replace (e.g. unmatched language string), we still show
        -- this row as a fallback so the data is not lost entirely.
        local yieldRowLabel = g_i18n:getText("sf_fieldinfo_yield") or "Yield"
        -- Only add the subset of rows that belong at this insertion point -- the native box
        -- updates an existing label in place rather than re-inserting it, so a row's on-screen
        -- position is fixed by whichever call first creates it. "early" rows go right after
        -- Farmland/Owned by (this is the fieldAddFarmland pass); "late" rows go right after
        -- Crop type/Growth (the fieldAddFruit pass). See GROUP_FOR_SOURCE below.
        local expectedGroup = GROUP_FOR_SOURCE[sourceFnName]
        for _, line in ipairs(lines) do
            if (expectedGroup == nil or line.group == expectedGroup)
                and (line.label ~= yieldRowLabel or hookManagerSelf._nativeYieldRowOverridden ~= true) then
                box:addLine(line.label, line.value)
            end
        end
    end

    --- Heuristic fragments used to spot the vanilla "Yield bonus" row by its (already
    --- localized) label text. We do not have the base game l10n keys for every language,
    --- so this is matched case-insensitively as a substring rather than an exact key.
    --- If your client language is not matching, enable debug logging: the first ~20
    --- unmatched row labels seen by the hook get logged so you can add the right
    --- fragment for your language here.
    local YIELD_LABEL_FRAGMENTS = {
        "yield",        -- en
        "ertrag",       -- de
        "rendement",    -- fr / nl
        "rendimiento",  -- es
        "resa",         -- it
        "rendimento",   -- pt / br
        "plon",         -- pl
        "vynos",        -- cz / sk (ascii fallback for "výnos")
        "hozam",        -- hu
        "urodzaj",      -- pl (alt)
        "skord",        -- sv (ascii fallback for "skörd")
        "avling",       -- no / da
    }

    local function isYieldBonusLabel(label)
        if type(label) ~= "string" then return false end
        local lower = string.lower(label)
        for _, frag in ipairs(YIELD_LABEL_FRAGMENTS) do
            if string.find(lower, frag, 1, true) then
                return true
            end
        end
        return false
    end

    --- Heuristic fragments used to spot (and suppress) the vanilla "Fertilized" row by its
    --- (already localized) label text, same approach as YIELD_LABEL_FRAGMENTS above. Per
    --- user preference this row is dropped from the FIELD INFO box entirely.
    local FERTILIZED_LABEL_FRAGMENTS = {
        "fertili",      -- en / fr (fertilisé) / es (fertilizado) / it (fertilizzato) / pt (fertilizado)
        "gedungt",      -- de (ascii fallback for "gedüngt")
        "bemest",       -- nl
        "nawoz",        -- pl (nawożenie / nawożone)
        "pohnojen",     -- cz / sk
        "tragya",       -- hu (ascii fallback for "trágyázott")
        "godsl",        -- sv (ascii fallback for "gödslad")
        "gjods",        -- no (ascii fallback for "gjødslet")
        "godet",        -- da
    }

    local function isFertilizedLabel(label)
        if type(label) ~= "string" then return false end
        local lower = string.lower(label)
        for _, frag in ipairs(FERTILIZED_LABEL_FRAGMENTS) do
            if string.find(lower, frag, 1, true) then
                return true
            end
        end
        return false
    end

    --- Wraps a single PlayerHUDUpdater function (by name) so we can intercept the box
    --- BEFORE the native call writes its own "Yield bonus" row, replace that row's
    --- displayed value with our own field-average yieldEfficiency (the same number that
    --- drives the actual harvest reduction via computeYieldModifier), then append our
    --- remaining soil rows afterward. A plain Utils.appendedFunction can only run AFTER
    --- the original and can't edit a row the original already drew, so this installs a
    --- full replacement function instead and calls `original` itself via pcall.
    local function installFieldInfoFn(functionName, appendRows)
        if appendRows == nil then appendRows = true end
        if PlayerHUDUpdater[functionName] == nil then
            SoilLogger.warning("Could not install native field info hook on PlayerHUDUpdater.%s - not available", functionName)
            return false
        end

        local original = PlayerHUDUpdater[functionName]

        PlayerHUDUpdater[functionName] = function(hudUpdater, data, box, ...)
            -- Resolve the real box arg up front (same scan onFieldAddFarmland uses) so we
            -- can wrap its addLine before calling the original.
            local realBox = box
            if not (type(realBox) == "table" and type(realBox.addLine) == "function") then
                realBox = findBoxArg(hudUpdater, data, box, ...)
            end

            hookManagerSelf._nativeYieldRowOverridden = false

            local restoreAddLine  = nil
            local replacementText = nil
            local matchedLabel    = nil

            if realBox ~= nil
                and g_SoilFertilityManager ~= nil
                and g_SoilFertilityManager.soilSystem ~= nil
                and g_SoilFertilityManager.settings ~= nil
                and g_SoilFertilityManager.settings.enabled ~= false
                and g_SoilFertilityManager.settings.showFieldInfoBox ~= false then

                local fieldId = nil
                local x, z = getPlayerOrVehiclePositionXZ()
                if x ~= nil then
                    fieldId = hookManagerSelf:getFieldIdAtWorldPosition(x, z)
                end
                if fieldId == nil then
                    fieldId = getFieldIdFromFieldInfoData(data)
                end

                if fieldId ~= nil then
                    local info = g_SoilFertilityManager.soilSystem:getFieldInfo(fieldId)
                    if info ~= nil then
                        if info.yieldEfficiency ~= nil then
                            replacementText = string.format("%d%%", math.floor(info.yieldEfficiency + 0.5))
                        end

                        local origAddLine = realBox.addLine
                        restoreAddLine = function() realBox.addLine = origAddLine end

                        realBox.addLine = function(selfBox, label, value, ...)
                            if replacementText ~= nil and matchedLabel == nil and isYieldBonusLabel(label) then
                                matchedLabel = label
                                SoilLogger.debug("Native field info hook: overriding native yield row '%s' (%s -> %s)",
                                    tostring(label), tostring(value), replacementText)
                                value = replacementText
                            elseif isFertilizedLabel(label) then
                                -- Drop the base game's own "Fertilized" row entirely (per user
                                -- preference) -- skip calling origAddLine so it never appears.
                                SoilLogger.debug("Native field info hook: suppressing native Fertilized row '%s' (%s)",
                                    tostring(label), tostring(value))
                                return
                            else
                                if hookManagerSelf._nativeFieldInfoLabelDiagCount == nil then
                                    hookManagerSelf._nativeFieldInfoLabelDiagCount = 0
                                end
                                if hookManagerSelf._nativeFieldInfoLabelDiagCount < 20 then
                                    hookManagerSelf._nativeFieldInfoLabelDiagCount = hookManagerSelf._nativeFieldInfoLabelDiagCount + 1
                                    SoilLogger.debug("Native field info hook: row seen label='%s' value='%s'", tostring(label), tostring(value))
                                end
                            end
                            return origAddLine(selfBox, label, value, ...)
                        end
                    end
                end
            end

            local ok, errorMsg = pcall(original, hudUpdater, data, box, ...)
            if not ok then
                SoilLogger.error("Native field info hook (%s) failed in original call: %s", functionName, tostring(errorMsg))
            end

            if restoreAddLine then restoreAddLine() end

            if replacementText ~= nil then
                if matchedLabel ~= nil then
                    hookManagerSelf._nativeYieldRowOverridden = true
                elseif hookManagerSelf._nativeYieldNoMatchWarned ~= true then
                    hookManagerSelf._nativeYieldNoMatchWarned = true
                    SoilLogger.warning("Native field info hook (%s): no native yield-bonus row matched our label heuristic -- it will keep showing vanilla's own number until YIELD_LABEL_FRAGMENTS is extended for your language. Enable debug logging to see the row labels actually seen.", functionName)
                end
            end

            -- Append our remaining soil rows (Soil Grade, N/P/K, pH, OM, Needs, etc.) -- only
            -- for the functions we know own a slot for them. Other discovered field* functions
            -- (see below) are wrapped purely to catch and suppress/override native rows like
            -- "Fertilized" or "Yield bonus", without injecting our own rows a second time.
            if appendRows then
                local appendOk, appendErr = pcall(onFieldAddFarmland, functionName, hudUpdater, data, box, ...)
                if not appendOk then
                    SoilLogger.error("Native field info hook (%s) failed: %s", functionName, tostring(appendErr))
                end
            end
        end

        self:register(PlayerHUDUpdater, functionName, original, "PlayerHUDUpdater." .. functionName .. " (native soil info injection)")
        SoilLogger.info("[OK] Native FIELD INFO injection hook installed (PlayerHUDUpdater.%s)", functionName)
        return true
    end

    -- fieldAddFarmland owns the ownership rows (Farmland/Owned by); fieldAddFruit owns the
    -- crop/yield-state rows (Crop type/Growth/Yield-bonus/Weed/Needs lime) — the
    -- ones our soil data is actually relevant alongside. A confirmed working reference
    -- (FS22_CropRotation, github.com/bodzio528/FS22_CropRotation) hooks fieldAddFruit
    -- specifically for this kind of row, with the identical (updater, data, box) signature.
    -- We hook both: harmless if one is a no-op for this box, and avoids re-guessing again
    -- if a future base-game patch moves things around.
    local farmlandHookOk = installFieldInfoFn("fieldAddFarmland", true)
    local fruitHookOk    = installFieldInfoFn("fieldAddFruit", true)

    -- The native "Fertilized" row isn't guaranteed to come from fieldAddFruit on every FS25
    -- build -- that assumption was ported from an FS22 mod and may not hold here. Rather than
    -- guess another exact function name, scan PlayerHUDUpdater for every other function whose
    -- name looks like it's part of building this same FIELD INFO box (starts with "field") and
    -- wrap it too, purely to catch/suppress native rows via the addLine override above (no
    -- extra rows of our own are appended through these -- see appendRows=false). This makes
    -- the Fertilized suppression resilient to whichever function actually adds that row.
    local extraHookCount = 0
    if type(PlayerHUDUpdater) == "table" then
        local extraNames = {}
        for key, value in pairs(PlayerHUDUpdater) do
            if type(key) == "string" and type(value) == "function"
                and key ~= "fieldAddFarmland" and key ~= "fieldAddFruit"
                and string.find(string.lower(key), "^field") then
                table.insert(extraNames, key)
            end
        end
        table.sort(extraNames)
        for _, name in ipairs(extraNames) do
            if installFieldInfoFn(name, false) then
                extraHookCount = extraHookCount + 1
            end
        end
        if extraHookCount > 0 then
            SoilLogger.info("Native field info hook: also wrapped %d additional PlayerHUDUpdater.field* function(s) for Fertilized-row suppression: %s",
                extraHookCount, table.concat(extraNames, ", "))
        end
    end

    return farmlandHookOk or fruitHookOk or extraHookCount > 0
end

-- =========================================================
-- HOOK 4: Weather/environment updates
-- =========================================================
---@return boolean success True if hook installed successfully
function HookManager:installWeatherHook()
    if not g_currentMission or not g_currentMission.environment then
        SoilLogger.warning("Could not install weather hook - environment not available")
        return false
    end

    local env = g_currentMission.environment
    if not env.update then
        SoilLogger.warning("Could not install weather hook - environment.update not found")
        return false
    end

    local original = env.update
    env.update = Utils.appendedFunction(
        original,
        function(envSelf, dt, ...)
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled or
               not g_SoilFertilityManager.settings.nutrientCycles then
                return
            end

            local success, errorMsg = pcall(function()
                g_SoilFertilityManager.soilSystem:onEnvironmentUpdate(envSelf, dt)
            end)

            if not success then
                SoilLogger.error("Weather hook failed: %s", tostring(errorMsg))
            end
        end
    )
    self:register(env, "update", original, "environment.update")
    SoilLogger.info("[OK] Weather hook installed successfully")
    return true
end

-- =========================================================
-- HOOK 5: Plowing operations (Cultivator.onEndWorkAreaProcessing)
-- =========================================================
-- WHY onEndWorkAreaProcessing instead of processCultivatorArea:
-- SpecializationUtil.registerFunction stores the function reference at
-- vehicleType registration time (game startup), then WorkArea.lua copies it
-- directly to workArea.processingFunction = self[funcName] at vehicle load.
-- A class-level Utils.appendedFunction hook applied at mod load (Mission00)
-- is completely bypassed — the workArea closure already holds the original.
-- onEndWorkAreaProcessing is an event: SpecializationUtil.raiseEvent does a
-- DYNAMIC table lookup (v10_[eventName](vehicle,...)) each tick, so our
-- class-level hook is visible and fires correctly.
---@return boolean success True if hook installed successfully
function HookManager:installPlowingHook()
    if not Cultivator or type(Cultivator.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install plowing hook - Cultivator.onEndWorkAreaProcessing not available")
        return false
    end

    local hookMgrRef = self
    local original = Cultivator.onEndWorkAreaProcessing
    Cultivator.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(cultivatorSelf, dt, hasProcessed)
            -- Fast exit: no work areas were active this tick
            if not hasProcessed then return end
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end
            if not cultivatorSelf.isServer then return end

            -- Confirm cultivator ACTUALLY changed terrain this tick (not just lifted/scanning).
            -- lastChangedArea = pixels that flipped to the cultivated state this tick.
            -- lastStatsArea   = pixels scanned by the work-area raycaster (non-zero even
            --                   when the plow is lifted during headland turns).
            -- Using lastStatsArea as the guard caused the daily cap to drain during turns.
            local spec = cultivatorSelf.spec_cultivator
            if not spec or not spec.workAreaParameters then return end
            local statsArea = spec.workAreaParameters.lastChangedArea
            if not statsArea or statsArea <= 0 then return end

            local isPlowSpec = cultivatorSelf.spec_plow ~= nil or cultivatorSelf.spec_subsoiler ~= nil

            -- Subsoiler area fix (#693): a subsoiler does its real work DEEP — its surface
            -- "changed" area (lastChangedArea) barely moves, so incorporation scaled by it
            -- rounds to ~nothing even though the tines worked a full strip. (Compaction relief
            -- is position-based, so it looked fine and masked the gap.) Use the total processed
            -- footprint (lastTotalArea) for the incorporation magnitude instead. lastChangedArea
            -- > 0 above already proved this is genuine work, not a lifted headland pass, so this
            -- can't reintroduce the turn-time cap drain the lastChangedArea guard was added for.
            local areaPixels = statsArea
            if spec.isSubsoiler then
                local total = spec.workAreaParameters.lastTotalArea
                if total and total > areaPixels then areaPixels = total end
            end

            -- Convert density-map pixels → hectares (same as mower hook).
            if not g_currentMission or type(g_currentMission.getFruitPixelsToSqm) ~= "function" then return end
            local areaHa = MathUtil.areaToHa(areaPixels, g_currentMission:getFruitPixelsToSqm())
            if areaHa <= 0 then return end

            SoilLogger.debug("[PlowHook] onEndWorkAreaProcessing fired — isPlow=%s subsoiler=%s area=%.1f px (%.5f ha)",
                tostring(isPlowSpec), tostring(spec.isSubsoiler), areaPixels, areaHa)

            local x, _, z = getWorldTranslation(cultivatorSelf.rootNode)
            local success, errorMsg = pcall(function()
                -- skipNegativeCache=true: player-created fields are not in the cache yet
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z, true)
                SoilLogger.debug("[PlowHook] pos=(%.1f,%.1f) farmlandId=%s isPlow=%s",
                    x, z, tostring(farmlandId), tostring(isPlowSpec))
                if farmlandId and farmlandId > 0 then
                    local isPlowingTool = isPlowSpec
                    -- Some cultivators work deep enough to act as plows
                    if not isPlowingTool and spec.workingDepth and
                       spec.workingDepth > SoilConstants.PLOWING.MIN_DEPTH_FOR_PLOWING then
                        isPlowingTool = true
                    end

                    -- Combo implements (fertilizing cultivators / seeders) spray while
                    -- tilling — they must not reset the session coverage they just laid.
                    local isAlsoSprayer = cultivatorSelf.spec_sprayer ~= nil

                    -- #674: green-manure biomass sampled (pre-clear) by the crop-biomass probe.
                    local cropBiomass = cultivatorSelf._sfCropBiomass or 0

                    if isPlowingTool then
                        g_SoilFertilityManager.soilSystem._lastTillageX = x
                        g_SoilFertilityManager.soilSystem._lastTillageZ = z
                        g_SoilFertilityManager.soilSystem:onPlowing(farmlandId, areaHa, isAlsoSprayer, cropBiomass)
                        g_SoilFertilityManager.soilSystem:recordTillageTrailPoint(farmlandId, x, z, true)
                    else
                        g_SoilFertilityManager.soilSystem._lastTillageX = x
                        g_SoilFertilityManager.soilSystem._lastTillageZ = z
                        g_SoilFertilityManager.soilSystem:onCultivation(farmlandId, areaHa, isAlsoSprayer, cropBiomass)
                        g_SoilFertilityManager.soilSystem:recordTillageTrailPoint(farmlandId, x, z, false)
                    end

                    -- Compaction: tillage LOOSENS soil — it never packs it. A subsoiler clears
                    -- the deep pan (full relief); a plow-action tool only loosens the topsoil it
                    -- inverts, so it relieves far less (PLOW_RELIEF) and the pan stays — keeping
                    -- the subsoiler the real fix (#687). Shallow cultivation is neutral. Only
                    -- harvest traffic (the combine hook) adds compaction. This still avoids the
                    -- #672-adjacent bug where a deep-tillage tool built on the Cultivator spec
                    -- (e.g. a Bourgault SPS configured as a subsoiler) ADDED compaction per pass.
                    if g_SoilFertilityManager.settings.compactionEnabled and SoilConstants.COMPACTION then
                        local isSubsoiler = (cultivatorSelf.spec_cultivator and
                                            cultivatorSelf.spec_cultivator.isSubsoiler) or false
                        if isSubsoiler or isPlowingTool then
                            -- A subsoiler clears the deep pan (FULL relief = nil → SUBSOILER_REDUCTION);
                            -- a plow-action tool only loosens topsoil (partial PLOW_RELIEF). NOTE: the
                            -- old `isSubsoiler and nil or PLOW_RELIEF` idiom always returned PLOW_RELIEF
                            -- (Lua: `true and nil` → nil → `nil or X` → X), so subsoilers were silently
                            -- getting partial relief since #687. Use an explicit branch (#680).
                            local relief = SoilConstants.COMPACTION.PLOW_RELIEF
                            if isSubsoiler then relief = nil end
                            SoilLogger.debug(
                                "Compaction: deep-tillage relief on farmland=%d veh=%d pos=(%.1f,%.1f) subsoiler=%s plow=%s relief=%s",
                                farmlandId, cultivatorSelf.id or 0, x, z,
                                tostring(isSubsoiler), tostring(isPlowingTool), tostring(relief or "full"))
                            g_SoilFertilityManager.soilSystem:onSubsoilerPass(farmlandId, x, z, relief)
                        end
                        -- shallow cultivator: neutral, no compaction change
                    end

                    -- #680: a flagged deep grassland sward-lifter (e.g. Latapia 5P1H) is built
                    -- as a cultivator, so the pass above already destroyed the grass and the
                    -- subsoiler branch already gave it full compaction relief. Restore the
                    -- snapshotted sward (debounced inside restoreGrassSward) so the player
                    -- decompacts the pasture without having to reseed it.
                    local sward = cultivatorSelf._sfGrassRestore
                    if sward and g_SoilFertilityManager.settings.compactionEnabled then
                        g_SoilFertilityManager.soilSystem:restoreGrassSward(farmlandId, sward.fruit, sward.growth)
                    end
                end
            end)

            if not success then
                SoilLogger.error("Plowing hook failed: %s", tostring(errorMsg))
            end
        end
    )
    self:register(Cultivator, "onEndWorkAreaProcessing", original, "Cultivator.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Plowing hook installed successfully (via onEndWorkAreaProcessing)")
    return true
end

-- =========================================================
-- HOOK 5b: Dedicated plow implements (Plow.onEndWorkAreaProcessing)
-- =========================================================
--- Hooks dedicated plow implements (belt plows, disc plows, etc.) which use
--- the Plow specialization. processingFunction closure bypass applies here too —
--- same fix: hook the event listener instead of the processing function.
---@return boolean success
function HookManager:installDedicatedPlowHook()
    if not Plow or type(Plow.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install dedicated plow hook - Plow.onEndWorkAreaProcessing not available")
        return false
    end

    local hookMgrRef = self
    local original = Plow.onEndWorkAreaProcessing
    Plow.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(plowSelf, dt, hasProcessed)
            -- Fast exit: no work areas were active this tick
            if not hasProcessed then return end
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end
            if not plowSelf.isServer then return end

            -- Confirm plow ACTUALLY changed terrain (lastChangedArea, not lastStatsArea).
            -- lastStatsArea is non-zero during headland turns with the plow lifted.
            local spec = plowSelf.spec_plow
            if not spec or not spec.workAreaParameters then return end
            local statsArea = spec.workAreaParameters.lastChangedArea
            if not statsArea or statsArea <= 0 then return end

            -- Convert density-map pixels → hectares.
            if not g_currentMission or type(g_currentMission.getFruitPixelsToSqm) ~= "function" then return end
            local areaHa = MathUtil.areaToHa(statsArea, g_currentMission:getFruitPixelsToSqm())
            if areaHa <= 0 then return end

            SoilLogger.debug("[DedicatedPlowHook] onEndWorkAreaProcessing fired — area=%.1f px (%.5f ha)", statsArea, areaHa)

            local x, _, z = getWorldTranslation(plowSelf.rootNode)
            local success, errorMsg = pcall(function()
                -- skipNegativeCache=true: player-created fields are not in the cache yet
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z, true)
                SoilLogger.debug("[DedicatedPlowHook] pos=(%.1f,%.1f) farmlandId=%s",
                    x, z, tostring(farmlandId))
                if farmlandId and farmlandId > 0 then
                    -- #674: green-manure biomass sampled (pre-clear) by the crop-biomass probe.
                    local cropBiomass = plowSelf._sfCropBiomass or 0
                    g_SoilFertilityManager.soilSystem._lastTillageX = x
                    g_SoilFertilityManager.soilSystem._lastTillageZ = z
                    g_SoilFertilityManager.soilSystem:onPlowing(farmlandId, areaHa, false, cropBiomass)
                    g_SoilFertilityManager.soilSystem:recordTillageTrailPoint(farmlandId, x, z, true)

                    -- Plowing inverts and loosens the topsoil, so it relieves a little
                    -- compaction (no-op if the cell isn't compacted) — but only the small
                    -- PLOW_RELIEF, not the full subsoiler amount: a plough leaves the deep
                    -- pan, so routine ploughing can't erase compaction the way a subsoiler
                    -- does (#687). It still never ADDS compaction, which keeps DeltaFive's
                    -- "one field keeps climbing" plow-spec report fixed.
                    if g_SoilFertilityManager.settings.compactionEnabled and SoilConstants.COMPACTION then
                        SoilLogger.debug("Compaction: plow relief (PLOW_RELIEF) on farmland=%d veh=%d pos=(%.1f,%.1f)",
                            farmlandId, plowSelf.id or 0, x, z)
                        g_SoilFertilityManager.soilSystem:onSubsoilerPass(farmlandId, x, z, SoilConstants.COMPACTION.PLOW_RELIEF)
                    end
                end
            end)

            if not success then
                SoilLogger.error("Dedicated plow hook failed: %s", tostring(errorMsg))
            end
        end
    )
    self:register(Plow, "onEndWorkAreaProcessing", original, "Plow.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Dedicated plow hook installed successfully (via onEndWorkAreaProcessing)")
    return true
end

-- =========================================================
-- HOOK 5b-ii: Crop-biomass probe + mulcher (Issue #674)
-- =========================================================
--- Sample how much incorporable crop biomass stands at a world position, as a 0..1
--- factor derived from the live FieldState growth state. Returns 0 for bare/plowed
--- ground or a just-emerged seedling; ~1 for a mature, withered, or cut crop (all of
--- which are full biomass to work in). Mirrors the proven FieldState query used
--- elsewhere in this mod and is fully pcall-guarded.
---@param worldX number
---@param worldZ number
---@return number biomassFactor 0..1
function HookManager:sampleCropBiomassAt(worldX, worldZ)
    if worldX == nil or worldZ == nil then return 0 end
    if FieldState == nil or FruitType == nil or g_fruitTypeManager == nil then return 0 end

    local ok, fs = pcall(function()
        local s = FieldState.new()
        s:update(worldX, worldZ)
        return s
    end)
    if not ok or not fs then return 0 end

    local idx = fs.fruitTypeIndex
    if not idx or idx == FruitType.UNKNOWN then return 0 end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(idx)
    if not fruitDesc then return 0 end

    local ci = SoilConstants.CROP_INCORPORATION
    local gs = fs.growthState or 0
    local seedling = (ci and ci.SEEDLING_GROWTH_STATE) or 1
    if gs <= seedling then return 0 end   -- negligible biomass while just emerged

    -- "Full biomass" reference = the crop's harvest-ready growth state. Anything at or
    -- beyond it (including withered / post-mow cut states, which index higher) clamps to 1.
    local ref = fruitDesc.maxHarvestingGrowthState
    if not ref or ref <= 1 then ref = fruitDesc.minHarvestingGrowthState or 6 end
    local factor = gs / ref
    if factor > 1 then factor = 1 end

    local minB = (ci and ci.MIN_BIOMASS) or 0.30
    if factor < minB then factor = minB end   -- floor for any established crop
    return factor
end

--- Is this vehicle a flagged deep grassland sward-lifter (#680)? Matched as lowercase
--- substrings of configFileName against COMPACTION.GRASSLAND_DEEP_TOOLS. Cached per vehicle.
--- These tools are Cultivator+isSubsoiler (they destroy grass), so SF preserves the sward
--- for them (snapshot pre-pass, restore post-pass) rather than letting the pass force a reseed.
---@param vehicle table
---@return boolean
function HookManager:isDeepGrasslandTool(vehicle)
    if not vehicle then return false end
    if vehicle._sfIsDeepGrasslandTool ~= nil then return vehicle._sfIsDeepGrasslandTool end
    local result = false
    local list = SoilConstants.COMPACTION and SoilConstants.COMPACTION.GRASSLAND_DEEP_TOOLS
    local name = vehicle.configFileName
    if list and name then
        name = string.lower(name)
        for _, pat in ipairs(list) do
            if string.find(name, pat, 1, true) then result = true; break end
        end
    end
    vehicle._sfIsDeepGrasslandTool = result
    return result
end

--- Sample the standing GRASS/forage sward at a world position (#680), returning
--- { fruit = index, growth = state } so a deep grassland tool's pass can be restored after
--- it tills the sward. Returns nil for bare ground or any non-forage crop, so a grassland
--- sward-lifter used on (say) a wheat field never resurrects that crop. Pcall-guarded.
---@param worldX number
---@param worldZ number
---@return table|nil
function HookManager:sampleGrassStateAt(worldX, worldZ)
    if worldX == nil or worldZ == nil then return nil end
    if FieldState == nil or FruitType == nil or g_fruitTypeManager == nil then return nil end
    local ok, fs = pcall(function()
        local s = FieldState.new()
        s:update(worldX, worldZ)
        return s
    end)
    if not ok or not fs then return nil end
    local idx = fs.fruitTypeIndex
    if not idx or idx == FruitType.UNKNOWN then return nil end
    local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(idx)
    if not fruitDesc then return nil end
    local name = string.lower(fruitDesc.name or "")
    local pf = SoilConstants.PERENNIAL_FORAGE_NAMES or {}
    if not (pf[name] or name == "grass") then return nil end  -- only preserve grass/forage swards
    return { fruit = idx, growth = fs.growthState or 0 }
end

--- Install an onStartWorkAreaProcessing probe on a tillage/mulch spec. It runs BEFORE
--- the work-area functions clear the fruit, samples the crop biomass at the implement
--- position, and stashes it on the vehicle as `_sfCropBiomass` for the matching end hook
--- to consume. Event listeners dispatch through the class spec table, so replacing the
--- function reaches already-spawned vehicles too.
---@param class table The specialization table (Cultivator, Plow, …)
---@param className string Friendly name for logging/registration
---@return boolean success
function HookManager:installCropBiomassProbe(class, className)
    if not class or type(class.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install crop-biomass probe - %s.onStartWorkAreaProcessing not available",
            tostring(className))
        return false
    end

    local hookMgrRef = self
    local original = class.onStartWorkAreaProcessing
    class.onStartWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(vehSelf, dt)
            if not vehSelf.isServer then return end
            vehSelf._sfCropBiomass  = 0
            vehSelf._sfGrassRestore = nil
            local mgr = g_SoilFertilityManager
            if not mgr or not mgr.settings or not mgr.settings.enabled then return end

            -- Two independent pre-tillage samples, each only paid for when its feature is on:
            --   residueIncorporation -> crop biomass (#674 green manure)
            --   compactionEnabled + a flagged deep grassland tool -> sward snapshot (#680)
            local residueOn     = mgr.settings.residueIncorporation
            local grassPreserve = mgr.settings.compactionEnabled and hookMgrRef:isDeepGrasslandTool(vehSelf)
            if not residueOn and not grassPreserve then return end

            local node = vehSelf.rootNode
            if not node then return end
            local ok, x, _, z = pcall(getWorldTranslation, node)
            if not ok or x == nil then return end

            if residueOn then
                vehSelf._sfCropBiomass = hookMgrRef:sampleCropBiomassAt(x, z)
            end
            -- Snapshot the sward BEFORE this deep grassland tool tills it, so the end hook
            -- can restore the grass and the player decompacts pasture without a reseed.
            if grassPreserve then
                vehSelf._sfGrassRestore = hookMgrRef:sampleGrassStateAt(x, z)
            end
        end
    )
    self:register(class, "onStartWorkAreaProcessing", original, className .. ".onStartWorkAreaProcessing")
    SoilLogger.info("[OK] Crop-biomass probe installed on %s (#674)", tostring(className))
    return true
end

--- Hooks the Mulcher specialization. When a mulcher is actively chopping crop/stubble,
--- the surface biomass is returned to the soil as organic matter. The Mulcher spec does
--- not expose a processed-area accumulator (unlike Cultivator/Mower), so the area is
--- estimated from forward speed × implement width and bounded by onMulching's per-day
--- cap. Crop biomass is read from the `_sfCropBiomass` stash set by the probe above.
---@return boolean success
function HookManager:installMulcherHook()
    if not Mulcher or type(Mulcher.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install Mulcher hook - Mulcher.onEndWorkAreaProcessing not available")
        return false
    end
    -- The biomass probe must also be installed on the Mulcher spec.
    self:installCropBiomassProbe(Mulcher, "Mulcher")

    local hookMgrRef = self
    local original = Mulcher.onEndWorkAreaProcessing
    Mulcher.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(mulcherSelf, dt)
            if not mulcherSelf.isServer then return end
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled or
               not g_SoilFertilityManager.settings.residueIncorporation then
                return
            end
            local spec = mulcherSelf.spec_mulcher
            if not spec or not spec.isWorking then return end

            local biomass = mulcherSelf._sfCropBiomass or 0
            if biomass <= 0 then return end

            local success, errorMsg = pcall(function()
                local x, _, z = getWorldTranslation(mulcherSelf.rootNode)
                if not x then return end
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z, true)
                if not farmlandId or farmlandId <= 0 then return end

                -- Estimate area covered this tick: speed (km/h → m/s) × dt(s) × width(m).
                local speedMs = (mulcherSelf.getLastSpeed and (mulcherSelf:getLastSpeed() or 0) or 0) / 3.6
                local widthM  = (mulcherSelf.size and mulcherSelf.size.width) or 3.0
                local dtSec   = (dt or 0) / 1000
                local areaHa  = (speedMs * dtSec * widthM) / 10000
                if areaHa <= 0 then return end

                g_SoilFertilityManager.soilSystem._lastTillageX = x
                g_SoilFertilityManager.soilSystem._lastTillageZ = z
                g_SoilFertilityManager.soilSystem:onMulching(farmlandId, areaHa, biomass)
            end)
            if not success then
                SoilLogger.error("Mulcher hook failed: %s", tostring(errorMsg))
            end
        end
    )
    self:register(Mulcher, "onEndWorkAreaProcessing", original, "Mulcher.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Mulcher hook installed (#674) — crop/stubble OM incorporation active")
    return true
end

-- =========================================================
-- HOOK 5c: Mechanical weed removal (Weeder.onEndWorkAreaProcessing)
-- =========================================================
--- Hooks the Weeder specialization via its onEndWorkAreaProcessing event.
--- FS25 weeders (inter-row hoes, mechanical weeders) use Weeder.processWeederArea
--- for terrain work, but processingFunction is captured as a direct closure
--- reference at vehicle load time and cannot be hooked post-load. The event
--- listener uses dynamic dispatch, so hooking onEndWorkAreaProcessing works.
---@return boolean success
function HookManager:installWeederHook()
    -- Same processingFunction closure bypass as Plow/Cultivator — hook the event instead
    if not Weeder or type(Weeder.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install Weeder hook - Weeder.onEndWorkAreaProcessing not available")
        return false
    end

    local hookMgrRef = self
    local original = Weeder.onEndWorkAreaProcessing
    Weeder.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(weederSelf, dt, hasProcessed)
            -- Fast exit: no work areas were active this tick
            if not hasProcessed then return end
            local mgr = g_SoilFertilityManager
            if not mgr or not mgr.soilSystem or not mgr.settings.enabled then return end
            if not weederSelf.isServer then return end

            local spec = weederSelf.spec_weeder
            if not spec or not spec.workAreaParameters then return end

            -- Two independent effects, each gated by its own setting:
            --   weedPressure                              -> mechanical weed removal (existing)
            --   compactionEnabled + isGrasslandWeeder     -> grassland compaction relief (#680).
            -- A grassland weeder/aerator works the sward WITHOUT destroying it, so it can ease
            -- pasture compaction without a reseed — the gap regular subsoilers can't fill (they
            -- kill the grass). Deep flagged sward-lifters get full relief; generic ones partial.
            local doWeed   = mgr.settings.weedPressure
            local doRelief = mgr.settings.compactionEnabled and SoilConstants.COMPACTION
                             and spec.isGrasslandWeeder == true
            if not doWeed and not doRelief then return end

            -- Confirm weeder ACTUALLY changed terrain (lastChangedArea).
            local statsArea = spec.workAreaParameters.lastChangedArea
            if not statsArea or statsArea <= 0 then return end

            -- Convert density-map pixels → hectares.
            if not g_currentMission or type(g_currentMission.getFruitPixelsToSqm) ~= "function" then return end
            local areaHa = MathUtil.areaToHa(statsArea, g_currentMission:getFruitPixelsToSqm())
            if areaHa <= 0 then return end

            local x, _, z = getWorldTranslation(weederSelf.rootNode)
            local success, errorMsg = pcall(function()
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                SoilLogger.debug("[WeederHook] pos=(%.1f,%.1f) farmlandId=%s grassland=%s",
                    x, z, tostring(farmlandId), tostring(spec.isGrasslandWeeder))
                if farmlandId and farmlandId > 0 then
                    mgr.soilSystem._lastTillageX = x
                    mgr.soilSystem._lastTillageZ = z
                    if doWeed then
                        mgr.soilSystem:onCultivation(farmlandId, areaHa)
                        SoilLogger.debug("[WeederHook] Field %d: mechanical weed removal applied", farmlandId)
                    end
                    if doRelief then
                        -- Full relief for a flagged deep grassland sward-lifter, partial otherwise.
                        local relief = SoilConstants.COMPACTION.GRASSLAND_RELIEF
                        if hookMgrRef:isDeepGrasslandTool(weederSelf) then relief = nil end
                        mgr.soilSystem:onSubsoilerPass(farmlandId, x, z, relief)
                        SoilLogger.debug("[WeederHook] Field %d: grassland compaction relief (%s)",
                            farmlandId, relief and "partial" or "full")
                    end
                end
            end)

            if not success then
                SoilLogger.error("Weeder hook failed: %s", tostring(errorMsg))
            end
        end
    )
    self:register(Weeder, "onEndWorkAreaProcessing", original, "Weeder.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Weeder hook (mechanical weed removal) installed successfully (via onEndWorkAreaProcessing)")
    return true
end

-- =========================================================
-- HOOK 6b: Strip-till / Ridge tiller (RidgeTiller.processRidgeTillerArea)
-- =========================================================
-- The RidgeTiller specialization (RIDGEFORMER work area type) is completely
-- separate from Cultivator.processCultivatorArea.  Implements such as the
-- Orthman Strip Till use this path and were previously invisible to SF.
--
-- Strip-till effects are a distinct middle tier between cultivation and plowing:
--   Weeds:   partial reduction (only ~30% surface coverage)
--   Pests:   higher than cultivator (deep 6-8" knife disrupts soil larvae)
--   Disease: lower than cultivator (surface residue left in untilled zones)
--   pH:      no normalization (no soil-layer inversion)
--   OM:      small boost (subsurface incorporation in tilled strips only)
---@return boolean success
function HookManager:installRidgeTillerHook()
    -- RidgeTiller is an FS22 class that does not exist in FS25.
    -- FS25 uses Cultivator for all tillage work areas including strip-till.
    -- This hook is kept as a no-op to avoid log spam; strip-till effects
    -- are captured via the Cultivator hook (installPlowingHook) instead.
    SoilLogger.info("RidgeTiller hook skipped (FS22 class, not present in FS25)")
    return true
end

-- =========================================================
-- HOOK 6: Sowing / planting (SowingMachine)
-- =========================================================
-- Clears field.lastCrop when seeds go in the ground so the HUD immediately
-- falls through to live FieldState detection instead of showing the stale
-- crop name from the previous harvest (fix for issue #123).
---@return boolean success True if hook installed successfully
function HookManager:installSowingHook()
    -- processSowingMachineArea has the same processingFunction closure bypass —
    -- hook onEndWorkAreaProcessing for dynamic dispatch instead.
    if not SowingMachine or type(SowingMachine.onEndWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("Could not install sowing hook - SowingMachine.onEndWorkAreaProcessing not available")
        return false
    end

    local hookMgrRef = self
    local original = SowingMachine.onEndWorkAreaProcessing
    SowingMachine.onEndWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(sowingSelf, dt, hasProcessed)
            -- Note: do NOT fast-exit on hasProcessed=false here.
            -- SowingMachine.onEndWorkAreaProcessing also ignores hasProcessed
            -- (it uses lastChangedArea as the real guard). On some ticks the
            -- work area activation can flicker, making hasProcessed=false while
            -- seeds are still going in the ground.
            if not sowingSelf.isServer then return end
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end

            -- Confirm seeds actually went in the ground this tick (mirrors game's own guard)
            local spec = sowingSelf.spec_sowingMachine
            if not spec or not spec.workAreaParameters then return end
            if (spec.workAreaParameters.lastChangedArea or 0) <= 0 then return end

            local ok, err = pcall(function()
                local x, _, z = getWorldTranslation(sowingSelf.rootNode)
                if not x then return end

                local fieldId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                SoilLogger.debug("[SowingHook] pos=(%.1f,%.1f) fieldId=%s crop=%s",
                    x, z, tostring(fieldId),
                    tostring(spec.workAreaParameters.seedsFruitType))
                if not fieldId or fieldId <= 0 then return end

                local statsArea = spec.workAreaParameters.lastStatsArea or spec.workAreaParameters.lastChangedArea or 0
                if statsArea <= 0 then return end
                -- Convert density-map pixels → hectares (same as plow/cultivator/mower hooks).
                -- Passing raw pixels directly caused factor = pixels/fieldAreaHa, exploding
                -- NPK to max in the first sowing tick (same bug fixed for plow in 51083e7).
                if not g_currentMission or type(g_currentMission.getFruitPixelsToSqm) ~= "function" then return end
                local areaHa = MathUtil.areaToHa(statsArea, g_currentMission:getFruitPixelsToSqm())
                if areaHa <= 0 then return end
                g_SoilFertilityManager.soilSystem._lastTillageX = x
                g_SoilFertilityManager.soilSystem._lastTillageZ = z
                g_SoilFertilityManager.soilSystem:onSowing(fieldId, areaHa, spec.workAreaParameters.seedsFruitType)
            end)

            if not ok then
                SoilLogger.error("Sowing hook failed: %s", tostring(err))
            end
        end
    )
    self:register(SowingMachine, "onEndWorkAreaProcessing", original, "SowingMachine.onEndWorkAreaProcessing")
    SoilLogger.info("[OK] Sowing hook installed (via SowingMachine.onEndWorkAreaProcessing)")
    return true
end

-- =========================================================
-- HOOK 7a: Early FillUnit.onPostLoad hook (installed before vehicles load)
-- =========================================================
-- Must run as prependedFunction so custom types are in supportedFillTypes BEFORE
-- vanilla's onPostLoad restores the saved fill level.  Called from
-- SoilFertilitySystem.new() so it is installed inside Mission00.load (prepend),
-- guaranteeing it fires for every vehicle the game loads from the savegame.
function HookManager:installFillUnitHookEarly()
    if self._fillUnitOnPostLoadHooked then return true end
    if not FillUnit or type(FillUnit.onPostLoad) ~= "function" then
        SoilLogger.warning("FillUnit early hook: FillUnit.onPostLoad not available - skipping")
        return false
    end

    local solidNames         = {"UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA",
                                 "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM", "LIME"}
    local liquidNames        = {"UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME", "INSECTICIDE", "FUNGICIDE",
                                "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH"}
    -- Organic dry types also work in manure spreaders (MANURE fill-unit base)
    local manureCompatNames  = {"COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE"}
    -- GYPSUM is physically applied the same way as lime; inject it into dedicated lime spreaders
    local limeCompatNames    = {"GYPSUM"}

    local original = FillUnit.onPostLoad
    FillUnit.onPostLoad = Utils.prependedFunction(original, function(vehicleSelf)
        local fm = g_fillTypeManager
        if not fm then return end
        local fertIdx    = fm:getFillTypeIndexByName("FERTILIZER")
        local liqFertIdx = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")
        local manureIdx  = fm:getFillTypeIndexByName("MANURE")
        local limeIdx    = fm:getFillTypeIndexByName("LIME")
        local spec = vehicleSelf.spec_fillUnit
        if not spec or not spec.fillUnits then return end
        for _, fu in pairs(spec.fillUnits) do
            if fu.supportedFillTypes then
                local addSolid  = fertIdx    and fu.supportedFillTypes[fertIdx]
                local addLiquid = liqFertIdx and fu.supportedFillTypes[liqFertIdx]
                local addManure = manureIdx  and fu.supportedFillTypes[manureIdx]
                local addLime   = limeIdx    and fu.supportedFillTypes[limeIdx]
                if addSolid then
                    for _, name in ipairs(solidNames) do
                        local idx = fm:getFillTypeIndexByName(name)
                        if idx then fu.supportedFillTypes[idx] = true end
                    end
                end
                if addLiquid then
                    for _, name in ipairs(liquidNames) do
                        local idx = fm:getFillTypeIndexByName(name)
                        if idx then fu.supportedFillTypes[idx] = true end
                    end
                end
                if addManure then
                    for _, name in ipairs(manureCompatNames) do
                        local idx = fm:getFillTypeIndexByName(name)
                        if idx then fu.supportedFillTypes[idx] = true end
                    end
                end
                if addLime then
                    for _, name in ipairs(limeCompatNames) do
                        local idx = fm:getFillTypeIndexByName(name)
                        if idx then fu.supportedFillTypes[idx] = true end
                    end
                end
                -- Category-based expansion: also accept any fill type in the fertilizer/liquid
                -- categories (safety net for fill types added to fillTypes.xml but not solidNames)
                if addSolid then
                    local ok, catTypes = pcall(function()
                        return fm:getFillTypesByCategoryNames("fertilizer")
                    end)
                    if ok and catTypes then
                        for _, ft in pairs(catTypes) do
                            if ft then fu.supportedFillTypes[ft] = true end
                        end
                    end
                end
                if addLiquid then
                    local ok, catTypes = pcall(function()
                        return fm:getFillTypesByCategoryNames("liquidFertilizer")
                    end)
                    if ok and catTypes then
                        for _, ft in pairs(catTypes) do
                            if ft then fu.supportedFillTypes[ft] = true end
                        end
                    end
                end
            end
        end
    end)

    self:register(FillUnit, "onPostLoad", original, "FillUnit.onPostLoad (early)")
    self._fillUnitOnPostLoadHooked = true
    SoilLogger.info("[OK] FillUnit early hook installed - custom fill types injected before vanilla save restore")
    return true
end

-- =========================================================
-- HOOK 7: Patch vehicle fill units to accept custom types
-- =========================================================
-- Vanilla spreaders/sprayers have fillUnit#fillTypes="FERTILIZER" or "LIQUIDFERTILIZER".
-- FS25 resolves these by NAME at parse time, yielding only the single vanilla type index.
-- Our fillTypes.xml extends those categories, but category extension only helps vehicles
-- that use fillTypeCategories="..." (category lookup), not fillTypes="..." (name lookup).
-- Therefore vanilla equipment never gets DAP/UREA/etc added to their supportedFillTypes.
--
-- Fix: hook FillUnit.onPostLoad to inject our custom fill type indices into any fill unit
-- that already accepts the corresponding vanilla base type (FERTILIZER or LIQUIDFERTILIZER).
-- This runs on every vehicle after its fill unit data is fully parsed, covering all
-- vanilla spreaders, sprayers, and any mod equipment using the standard category names.
--
-- Additionally, after the hook is installed, all vehicles already in memory are patched
-- retroactively. This covers the save/load scenario where FillUnit.onPostLoad fires during
-- Mission00.load — well before our deferred hook installation — leaving saved sprayers
-- unable to accept custom fill types until a new one is bought from the shop.
---@return boolean success
function HookManager:installFillUnitHook()
    if not FillUnit or type(FillUnit.onPostLoad) ~= "function" then
        SoilLogger.warning("Could not install FillUnit hook - FillUnit.onPostLoad not available")
        return false
    end

    -- Resolve fill type indices once at install time (used by hook closure + retroactive patch)
    local fm = g_fillTypeManager
    if not fm then
        SoilLogger.warning("FillUnit hook: g_fillTypeManager not available")
        return false
    end

    local fertIndex    = fm:getFillTypeIndexByName("FERTILIZER")
    local liqFertIndex = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")
    if not fertIndex and not liqFertIndex then
        SoilLogger.warning("FillUnit hook: base fertilizer fill types not registered")
        return false
    end

    -- Vanilla MANURE base: enables organic dry products in manure spreaders.
    -- Manure spreaders support MANURE but not FERTILIZER, so BIOSOLIDS and
    -- CHICKEN_MANURE (organic dry products) were accepted by trailers (which
    -- support both) but rejected by dedicated spreaders (MANURE-only fill unit).
    local manureIndex = fm:getFillTypeIndexByName("MANURE")
    local limeIndex   = fm:getFillTypeIndexByName("LIME")

    local solidNames  = {"UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM", "LIME"}
    local liquidNames = {"UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME", "INSECTICIDE", "FUNGICIDE",
                         "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH"}
    -- Organic dry types also work in manure spreaders (MANURE fill-unit base).
    local manureCompatNames = {"COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE"}
    -- GYPSUM is physically applied the same way as lime; inject into dedicated lime spreaders.
    local limeCompatNames   = {"GYPSUM"}
    -- Store for deferred re-patch (dedi server timing fix)
    self._fuSolidNames  = solidNames
    self._fuLiquidNames = liquidNames
    self._fuManureCompatNames = manureCompatNames
    self._fuLimeCompatNames   = limeCompatNames
    self._fuFertIndex    = fertIndex
    self._fuLiqFertIndex = liqFertIndex
    self._fuManureIndex  = manureIndex
    self._fuLimeIndex    = limeIndex
    self._fuFm           = fm

    local solidIndices        = {}
    local liquidIndices       = {}
    local manureCompatIndices = {}
    local limeCompatIndices   = {}
    for _, name in ipairs(solidNames) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(solidIndices, idx) end
    end
    for _, name in ipairs(liquidNames) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(liquidIndices, idx) end
    end
    for _, name in ipairs(manureCompatNames) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(manureCompatIndices, idx) end
    end
    for _, name in ipairs(limeCompatNames) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(limeCompatIndices, idx) end
    end

    -- Category-based indices: safety net for fill types in our fillTypes.xml not yet in solidNames
    local categoryFertIndices    = {}
    local categoryLiqFertIndices = {}
    local ok1, catFert = pcall(function() return fm:getFillTypesByCategoryNames("fertilizer") end)
    if ok1 and catFert then
        for _, ft in pairs(catFert) do
            if ft then table.insert(categoryFertIndices, type(ft) == "table" and ft.index or ft) end
        end
    end
    local ok2, catLiq = pcall(function() return fm:getFillTypesByCategoryNames("liquidFertilizer") end)
    if ok2 and catLiq then
        for _, ft in pairs(catLiq) do
            if ft then table.insert(categoryLiqFertIndices, type(ft) == "table" and ft.index or ft) end
        end
    end
    if #categoryFertIndices > 0 or #categoryLiqFertIndices > 0 then
        SoilLogger.info("FillUnit hook: detected %d solid + %d liquid category fill types (third-party support)",
            #categoryFertIndices, #categoryLiqFertIndices)
    end

    -- Shared helper: inject custom fill type indices into one vehicle's fill units
    local function patchVehicleFillUnits(vehicleSelf)
        local spec = vehicleSelf.spec_fillUnit
        if not spec or not spec.fillUnits then return end
        for _, fillUnit in pairs(spec.fillUnits) do
            if fillUnit.supportedFillTypes then
                local addSolid  = fertIndex    and fillUnit.supportedFillTypes[fertIndex]
                local addLiquid = liqFertIndex and fillUnit.supportedFillTypes[liqFertIndex]
                -- Manure spreaders support MANURE; enable organic dry types for them too
                local addManure = manureIndex  and fillUnit.supportedFillTypes[manureIndex]
                -- Dedicated lime spreaders support LIME; enable GYPSUM for them too
                local addLime   = limeIndex    and fillUnit.supportedFillTypes[limeIndex]
                if addSolid then
                    for _, idx in ipairs(solidIndices) do
                        fillUnit.supportedFillTypes[idx] = true
                    end
                end
                if addLiquid then
                    for _, idx in ipairs(liquidIndices) do
                        fillUnit.supportedFillTypes[idx] = true
                    end
                end
                if addManure then
                    for _, idx in ipairs(manureCompatIndices) do
                        fillUnit.supportedFillTypes[idx] = true
                    end
                end
                if addLime then
                    for _, idx in ipairs(limeCompatIndices) do
                        fillUnit.supportedFillTypes[idx] = true
                    end
                end
                -- Category-based expansion: safety net for our own fill types not in solidNames
                if addSolid then
                    for _, idx in ipairs(categoryFertIndices) do
                        fillUnit.supportedFillTypes[idx] = true
                    end
                end
                if addLiquid then
                    for _, idx in ipairs(categoryLiqFertIndices) do
                        fillUnit.supportedFillTypes[idx] = true
                    end
                end
            end
        end
    end

    -- Only hook FillUnit.onPostLoad if the early hook wasn't already installed.
    -- installFillUnitHookEarly() runs before vehicles load (from SoilFertilitySystem.new),
    -- which is the only way to ensure custom types are in supportedFillTypes BEFORE
    -- vanilla's onPostLoad tries to restore the saved fill level.
    if not self._fillUnitOnPostLoadHooked then
        local original = FillUnit.onPostLoad
        FillUnit.onPostLoad = Utils.prependedFunction(
            original,
            function(vehicleSelf, savegame)
                patchVehicleFillUnits(vehicleSelf)
            end
        )
        self:register(FillUnit, "onPostLoad", original, "FillUnit.onPostLoad")
        self._fillUnitOnPostLoadHooked = true
        SoilLogger.info("[OK] FillUnit hook installed - custom types injected into compatible vehicles")
    else
        SoilLogger.info("[OK] FillUnit.onPostLoad already hooked by early install - skipping duplicate")
    end

    -- Build customToBase: custom fill type index → vanilla base type index.
    -- Used by getFillUnitSupportsFillType hook below.
    local customToBase   = {}
    local customToManure = {}  -- organic dry types that also fit in MANURE-based fill units
    local customToLime   = {}  -- lime-compatible types (GYPSUM) that fit in LIME-based fill units
    if fertIndex then
        for _, idx in ipairs(solidIndices) do
            customToBase[idx] = fertIndex
        end
    end
    if liqFertIndex then
        for _, idx in ipairs(liquidIndices) do
            customToBase[idx] = liqFertIndex
        end
    end
    if manureIndex then
        for _, idx in ipairs(manureCompatIndices) do
            customToManure[idx] = manureIndex
        end
    end
    if limeIndex then
        for _, idx in ipairs(limeCompatIndices) do
            customToLime[idx] = limeIndex
        end
    end

    -- Hook getFillUnitSupportsFillType so Dischargeable:dischargeToObject (vehicle-to-vehicle
    -- auger wagon → spreader, tanker → sprayer, etc.) passes the fill type check for our
    -- custom types. Patching supportedFillTypes covers the table lookup, but some FS25
    -- versions / specializations call this method via a C++ fast-path that bypasses the Lua
    -- table. Wrapping the method directly is the belt-and-suspenders fix.
    --
    -- Logic: if the vehicle supports the corresponding vanilla base type (FERTILIZER or
    -- LIQUIDFERTILIZER or MANURE or LIME), it also supports the matching custom type.
    if FillUnit.getFillUnitSupportsFillType then
        local origGetSupports = FillUnit.getFillUnitSupportsFillType
        FillUnit.getFillUnitSupportsFillType = function(vehicleSelf, fillUnitIndex, fillType)
            -- Short-circuit: original already knows about this type (vanilla or already patched table)
            if origGetSupports(vehicleSelf, fillUnitIndex, fillType) then
                return true
            end
            -- Custom type? Check against FERTILIZER/LIQUIDFERTILIZER base type.
            local baseType = customToBase[fillType]
            if baseType and origGetSupports(vehicleSelf, fillUnitIndex, baseType) then
                return true
            end
            -- Organic dry types (BIOSOLIDS, CHICKEN_MANURE) also fit MANURE-based fill units.
            local manureBase = customToManure[fillType]
            if manureBase and origGetSupports(vehicleSelf, fillUnitIndex, manureBase) then
                return true
            end
            -- GYPSUM fits LIME-based fill units (dedicated lime spreaders).
            local limeBase = customToLime[fillType]
            if limeBase and origGetSupports(vehicleSelf, fillUnitIndex, limeBase) then
                return true
            end
            -- Category-based fallback: support any fill type in the "fertilizer" /
            -- "liquidFertilizer" category for vehicles that already accept the vanilla
            -- base type. Safety net for our own fill types not in the hardcoded lists.
            if fertIndex and origGetSupports(vehicleSelf, fillUnitIndex, fertIndex) then
                local ok, inCat = pcall(function()
                    return fm:getIsFillTypeInCategory(fillType, "fertilizer")
                end)
                if ok and inCat then return true end
            end
            if liqFertIndex and origGetSupports(vehicleSelf, fillUnitIndex, liqFertIndex) then
                local ok, inCat = pcall(function()
                    return fm:getIsFillTypeInCategory(fillType, "liquidFertilizer")
                end)
                if ok and inCat then return true end
            end
            return false
        end
        self:register(FillUnit, "getFillUnitSupportsFillType", origGetSupports, "FillUnit.getFillUnitSupportsFillType")
        SoilLogger.info("[OK] getFillUnitSupportsFillType hook installed - vehicle-to-vehicle transfer enabled")
    else
        SoilLogger.warning("FillUnit.getFillUnitSupportsFillType not available - skipping transfer hook")
    end

    -- Retroactively patch all vehicles already in memory.
    -- On save/load, FillUnit.onPostLoad fires during Mission00.load (before our deferred
    -- hook installation runs), so saved sprayers miss the injection entirely. Patching them
    -- here ensures they accept custom fill types without needing a shop purchase.
    -- NOTE: In FS25, vehicles are stored in g_currentMission.vehicleSystem.vehicles,
    --       not g_currentMission.vehicles (which does not exist).
    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem
    if vehicleSystem and vehicleSystem.vehicles then
        local patched = 0
        for _, vehicle in pairs(vehicleSystem.vehicles) do
            patchVehicleFillUnits(vehicle)
            patched = patched + 1
        end
        if patched > 0 then
            SoilLogger.info("Retroactively patched %d existing vehicles with custom fill types", patched)
        end
    end

    return true
end

-- =========================================================
-- DEFERRED FILL UNIT RE-PATCH (dedicated server timing fix)
-- =========================================================
-- On dedicated servers, fill types from fillTypes.xml may not be registered in
-- g_fillTypeManager at the time installFillUnitHook runs (inside loadMission00Finished).
-- This results in empty solidIndices/liquidIndices and a no-op retroactive patch.
-- SoilFertilityManager:update() calls this once _sprayTypesComplete is false, after
-- a small delay, to re-resolve indices and re-patch vehicles once fill types are available.
function HookManager:reapplyFillUnitPatch()
    local fm = self._fuFm or g_fillTypeManager
    if not fm then return false end

    local fertIdx    = self._fuFertIndex    or fm:getFillTypeIndexByName("FERTILIZER")
    local liqFertIdx = self._fuLiqFertIndex or fm:getFillTypeIndexByName("LIQUIDFERTILIZER")
    local manureIdx  = self._fuManureIndex  or fm:getFillTypeIndexByName("MANURE")
    local limeIdx    = self._fuLimeIndex    or fm:getFillTypeIndexByName("LIME")

    local solidIdxs, liquidIdxs, manureIdxs, limeIdxs = {}, {}, {}, {}
    local found, missing = 0, 0
    for _, name in ipairs(self._fuSolidNames or {}) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(solidIdxs, idx); found = found + 1
        else missing = missing + 1 end
    end
    for _, name in ipairs(self._fuLiquidNames or {}) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(liquidIdxs, idx) end
    end
    for _, name in ipairs(self._fuManureCompatNames or {}) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(manureIdxs, idx) end
    end
    for _, name in ipairs(self._fuLimeCompatNames or {}) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then table.insert(limeIdxs, idx) end
    end

    if found == 0 then return false end  -- still not available

    local vehicleSystem = g_currentMission and g_currentMission.vehicleSystem
    if not vehicleSystem or not vehicleSystem.vehicles then return false end

    local patched = 0
    for _, vehicle in pairs(vehicleSystem.vehicles) do
        local spec = vehicle.spec_fillUnit
        if spec and spec.fillUnits then
            for _, fillUnit in pairs(spec.fillUnits) do
                if fillUnit.supportedFillTypes then
                    local addSolid  = fertIdx    and fillUnit.supportedFillTypes[fertIdx]
                    local addLiquid = liqFertIdx and fillUnit.supportedFillTypes[liqFertIdx]
                    local addManure = manureIdx  and fillUnit.supportedFillTypes[manureIdx]
                    local addLime   = limeIdx    and fillUnit.supportedFillTypes[limeIdx]
                    if addSolid  then for _, idx in ipairs(solidIdxs)  do fillUnit.supportedFillTypes[idx] = true end end
                    if addLiquid then for _, idx in ipairs(liquidIdxs) do fillUnit.supportedFillTypes[idx] = true end end
                    if addManure then for _, idx in ipairs(manureIdxs) do fillUnit.supportedFillTypes[idx] = true end end
                    if addLime   then for _, idx in ipairs(limeIdxs)   do fillUnit.supportedFillTypes[idx] = true end end
                end
            end
        end
        patched = patched + 1
    end

    SoilLogger.info("[DeferredInit] Deferred fill unit re-patch complete: %d vehicles re-patched (%d types found)", patched, found)
    return true
end

-- =========================================================
-- HOOK: Inject custom fill types into placeable silos / storage bins  (#605)
-- =========================================================
-- Placeable silos (PlaceableSilo spec) accept fill types via three independent
-- gates, each resolved from XML as EITHER #fillTypeCategories OR #fillTypes (names):
--   * Storage.fillTypes          — the capacity holder (one per spec.storages entry)
--   * UnloadTrigger.fillTypes    — gate for discharging INTO the silo from a spreader/trailer
--   * LoadTrigger.fillTypes      — gate for loading OUT of the silo into equipment
-- Storage/triggers that list base types by NAME (e.g. fillTypes="FERTILIZER LIME")
-- never see our fillTypeCategory extension, so SF types are rejected. This hook
-- injects our custom indices into any storage/trigger that already accepts the
-- corresponding base type (FERTILIZER / LIME / MANURE / LIQUIDFERTILIZER), so bulk
-- bins from third-party mods accept SF products automatically — no manual config.
--
-- Injection runs appended to PlaceableSilo.onLoad, i.e. AFTER storages/triggers are
-- parsed but BEFORE onFinalizePlacement aggregates storages into the station's
-- supportedFillTypes. Augmenting Storage.fillTypes first means the game builds the
-- station aggregate (the discharge-allow gate) with our types included — no need to
-- poke redacted station internals on the normal path.

-- SF custom fill types grouped by the vanilla base type a bin must already accept.
HookManager.SILO_GROUPS = {
    { base = "FERTILIZER",       names = { "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA" } },
    { base = "LIME",             names = { "GYPSUM" } },
    { base = "MANURE",           names = { "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE" } },
    { base = "LIQUIDFERTILIZER", names = { "UAN32", "UAN28", "ANHYDROUS", "STARTER",
                                           "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH",
                                           "INSECTICIDE", "FUNGICIDE", "LIQUIDLIME" } },
}

-- Resolve SILO_GROUPS names → { baseIdx, idxList } once (cached; re-resolves while empty
-- to cover dedicated-server timing where fill types aren't registered yet at first call).
function HookManager:getResolvedSiloGroups()
    if self._siloGroupsResolved then return self._siloGroupsResolved end
    local fm = g_fillTypeManager
    if not fm then return nil end
    local resolved = {}
    local total = 0
    for _, group in ipairs(HookManager.SILO_GROUPS) do
        local baseIdx = fm:getFillTypeIndexByName(group.base)
        local idxList = {}
        for _, name in ipairs(group.names) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then table.insert(idxList, idx); total = total + 1 end
        end
        if baseIdx and #idxList > 0 then
            table.insert(resolved, { baseIdx = baseIdx, idxList = idxList })
        end
    end
    if total == 0 then return nil end  -- types not registered yet; try again next call
    self._siloGroupsResolved = resolved
    return resolved
end

-- Add the custom indices of every group whose base type the storage already holds.
-- Seeds fillLevels / sync / publish tables so getFreeCapacity() doesn't return 0
-- (Storage:getFreeCapacity returns 0 for any fillType missing from fillLevels).
function HookManager.injectStorage(storage, groups)
    if not storage or not storage.fillTypes then return end
    local changed = false
    for _, group in ipairs(groups) do
        if storage.fillTypes[group.baseIdx] then
            for _, idx in ipairs(group.idxList) do
                if not storage.fillTypes[idx] then
                    storage.fillTypes[idx] = true
                    if storage.fillLevels then storage.fillLevels[idx] = storage.fillLevels[idx] or 0 end
                    if storage.fillLevelsLastSynced then storage.fillLevelsLastSynced[idx] = storage.fillLevelsLastSynced[idx] or 0 end
                    if storage.fillLevelsLastPublished then storage.fillLevelsLastPublished[idx] = storage.fillLevelsLastPublished[idx] or 0 end
                    if storage.sortedFillTypes then table.insert(storage.sortedFillTypes, idx) end
                    changed = true
                end
            end
        end
    end
    if changed and storage.sortedFillTypes then table.sort(storage.sortedFillTypes) end
end

-- Add custom indices to a trigger's fillTypes set when it already holds the base type.
-- A nil fillTypes means "accepts everything" — nothing to do.
function HookManager.injectTriggerFillTypes(triggerFillTypes, groups)
    if not triggerFillTypes then return end
    for _, group in ipairs(groups) do
        if triggerFillTypes[group.baseIdx] then
            for _, idx in ipairs(group.idxList) do
                triggerFillTypes[idx] = true
            end
        end
    end
end

-- Defensive station-aggregate patch (retroactive path only — silos already finalized).
-- Copies the base type's existing value so we preserve whatever shape the table uses
-- (boolean set vs. descriptor map). Membership is what the allow-checks read.
function HookManager.injectStationAggregate(station, groups)
    if not station then return end
    for _, tableName in ipairs({ "supportedFillTypes", "acceptedFillTypes" }) do
        local tbl = station[tableName]
        if type(tbl) == "table" then
            for _, group in ipairs(groups) do
                local baseVal = tbl[group.baseIdx]
                if baseVal ~= nil then
                    for _, idx in ipairs(group.idxList) do
                        if tbl[idx] == nil then tbl[idx] = baseVal end
                    end
                end
            end
        end
    end
end

-- Inject SF types into one silo placeable's storages and triggers (idempotent).
function HookManager:injectSiloFillTypes(placeable)
    if not placeable then return end
    local spec = placeable.spec_silo
    if not spec then return end
    local groups = self:getResolvedSiloGroups()
    if not groups then return end

    if spec.storages then
        for _, storage in ipairs(spec.storages) do
            HookManager.injectStorage(storage, groups)
        end
    end

    local us = spec.unloadingStation
    if us then
        if us.unloadTriggers then
            for _, trigger in ipairs(us.unloadTriggers) do
                HookManager.injectTriggerFillTypes(trigger.fillTypes, groups)
            end
        end
        HookManager.injectStationAggregate(us, groups)
    end

    local ls = spec.loadingStation
    if ls then
        if ls.loadTriggers then
            for _, trigger in ipairs(ls.loadTriggers) do
                HookManager.injectTriggerFillTypes(trigger.fillTypes, groups)
            end
        end
        HookManager.injectStationAggregate(ls, groups)
    end
end

-- Install the appended PlaceableSilo hooks. Installed early (from SoilFertilitySystem.new)
-- so they are in place before savegame silos load. Injection runs at two points, both
-- idempotent:
--   onLoad             — storage.fillTypes + trigger.fillTypes BEFORE savegame fill-level
--                        restore and stream sync, so saved SF levels and sortedFillTypes
--                        ordering stay consistent.
--   onFinalizePlacement — re-runs after the station's supportedFillTypes aggregate is built
--                        from storages, covering the discharge-allow gate for silos placed
--                        mid-game (where no installAll sweep follows).
---@return boolean success
function HookManager:installSiloFillTypeHook()
    if self._siloHooked then return true end
    if not PlaceableSilo or type(PlaceableSilo.onLoad) ~= "function" then
        SoilLogger.warning("Silo hook: PlaceableSilo.onLoad not available - skipping")
        return false
    end

    local hm = self
    local function safeInject(placeableSelf)
        local ok, err = pcall(function() hm:injectSiloFillTypes(placeableSelf) end)
        if not ok then
            SoilLogger.warning("Silo fill type injection failed: %s", tostring(err))
        end
    end

    local origOnLoad = PlaceableSilo.onLoad
    PlaceableSilo.onLoad = Utils.appendedFunction(origOnLoad, safeInject)
    self:register(PlaceableSilo, "onLoad", origOnLoad, "PlaceableSilo.onLoad")

    if type(PlaceableSilo.onFinalizePlacement) == "function" then
        local origFinalize = PlaceableSilo.onFinalizePlacement
        PlaceableSilo.onFinalizePlacement = Utils.appendedFunction(origFinalize, safeInject)
        self:register(PlaceableSilo, "onFinalizePlacement", origFinalize, "PlaceableSilo.onFinalizePlacement")
    end

    self._siloHooked = true
    SoilLogger.info("[OK] Silo fill type hook installed - SF types injected into compatible bulk storage")
    return true
end

-- Retroactively inject SF types into silos already loaded before the hook ran.
-- Covers any timing edge where a silo's onLoad fired before installSiloFillTypeHook.
-- Idempotent: re-running on an already-patched silo is a no-op.
---@return integer patchedCount
function HookManager:patchExistingSilos()
    local placeableSystem = g_currentMission and g_currentMission.placeableSystem
    local placeables = placeableSystem and placeableSystem.placeables
    if not placeables then return 0 end
    local patched = 0
    for _, placeable in pairs(placeables) do
        if placeable.spec_silo then
            local ok = pcall(function() self:injectSiloFillTypes(placeable) end)
            if ok then patched = patched + 1 end
        end
    end
    if patched > 0 then
        SoilLogger.info("Retroactively injected SF fill types into %d existing silo(s)", patched)
    end
    return patched
end

-- =========================================================
-- DEFERRED EFFECT TYPE REMAP REBUILD (dedi server timing fix)
-- =========================================================
-- The effect type hook captures its remap table by reference in a closure.
-- If fill types weren't in g_fillTypeManager at install time (dedi server),
-- the remap table is sparsely populated. Since it's a Lua table reference,
-- we can add missing entries directly — the closures automatically see them.
-- Called by SoilFertilityManager:update() alongside reapplyFillUnitPatch().
function HookManager:reapplyEffectTypeRemap()
    local remap = self._effectTypeRemap
    if not remap then return end

    local fm = g_fillTypeManager
    if not fm then return end

    local fertIdx = self._effectFertIdx or fm:getFillTypeIndexByName("FERTILIZER")
    local liqIdx  = self._effectLiqIdx  or fm:getFillTypeIndexByName("LIQUIDFERTILIZER")

    local added = 0
    if fertIdx and self._effectSolidNames then
        for _, name in ipairs(self._effectSolidNames) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx and not remap[idx] then
                remap[idx] = fertIdx
                added = added + 1
            end
        end
    end
    if liqIdx and self._effectLiquidNames then
        for _, name in ipairs(self._effectLiquidNames) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx and not remap[idx] then
                remap[idx] = liqIdx
                added = added + 1
            end
        end
    end

    if added > 0 then
        SoilLogger.info("[DeferredInit] Effect type remap rebuilt: %d fill types added (total entries: %d)", added, (function() local n=0; for _ in pairs(remap) do n=n+1 end; return n end)())
    end
end

-- =========================================================
-- HOOK 8: "BUY" refill mode for custom fill types (issue #125)
-- =========================================================
-- In FS25, when the player sets the sprayer refill mode to "BUY", the game is
-- supposed to charge money per liter consumed instead of depleting the tank.
-- This works for vanilla fill types (FERTILIZER, LIQUIDFERTILIZER) because they
-- are registered with a purchasable economy entry that the game's FillUnit system
-- can look up via g_fillTypeManager.
--
-- Our custom fill types (UREA, UAN32, DAP, etc.) ARE defined with pricePerLiter
-- in fillTypes.xml, but FS25's internal "BUY" purchase path only fires for fill
-- types whose economy entry is recognized by FillUnit:getIsAvailableForPurchase()
-- (or equivalent internal check). Custom mod fill types are not in that list, so
-- "BUY" mode silently falls back to normal depletion for our types.
--
-- Root cause: FS25's Sprayer specialization calls
--   FillUnit:addFillUnitFillLevel(fillUnitIndex, -delta, fillTypeIndex)
-- On vanilla types, FillUnit internally intercepts the negative delta when
-- purchase mode is active and handles the money transaction instead. For our
-- types, no such interception exists — the fill level just depletes as normal.
--
-- Fix: hook FillUnit.addFillUnitFillLevel. When:
--   1. The delta is negative (consumption, not filling)
--   2. The fill type is one of our custom purchasable types
--   3. AI is active on the vehicle AND the player has opted in via helper settings
--      (helperBuyFertilizer / helperSlurrySource==2 / helperManureSource==2)
-- → Charge the player pricePerLiter * |delta| and return 0 (no depletion).
--
-- Detection: per LUADOC Sprayer:getIsSprayerExternallyFilled, BUY mode is an
-- AI-only feature controlled by g_currentMission.missionInfo.helperBuyFertilizer
-- (and the slurry/manure equivalents). There are no per-vehicle spec fields for
-- this — checking spec_sprayer or fillUnit reloadState is incorrect.
---@return boolean success
function HookManager:installPurchaseRefillHook()
    if not FillUnit or type(FillUnit.addFillUnitFillLevel) ~= "function" then
        SoilLogger.warning("Purchase refill hook: FillUnit.addFillUnitFillLevel not available - skipping")
        return false
    end

    local fm = g_fillTypeManager
    if not fm then
        SoilLogger.warning("Purchase refill hook: g_fillTypeManager not available - skipping")
        return false
    end

    -- Build a lookup table: fillTypeIndex → pricePerLiter for all our custom types.
    -- Prices come from Constants (authoritative single source) and fall back to
    -- the fillTypes.xml economy values via FillTypeManager if a type isn't in Constants.
    local ALL_CUSTOM_NAMES = {
        -- Liquid
        "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
        "INSECTICIDE", "FUNGICIDE",
        "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH",
        -- Solid
        "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA",
        "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM",
    }

    -- Prices from Constants (already defined there)
    local PRICE_OVERRIDES = {}
    if SoilConstants and SoilConstants.PURCHASABLE_SINGLE_NUTRIENT then
        for name, data in pairs(SoilConstants.PURCHASABLE_SINGLE_NUTRIENT) do
            if data.pricePerLiter then
                PRICE_OVERRIDES[string.upper(name)] = data.pricePerLiter
            end
        end
    end
    -- Fallback prices match fillTypes.xml economy entries
    local FALLBACK_PRICES = {
        UAN32 = 1.60, UAN28 = 1.50, ANHYDROUS = 1.85, STARTER = 1.70,
        LIQUIDLIME = 1.20, INSECTICIDE = 1.20, FUNGICIDE = 1.30,
        LIQUID_UREA = 1.70, LIQUID_AMS = 1.45, LIQUID_MAP = 2.00, LIQUID_DAP = 1.80, LIQUID_POTASH = 1.85,
        UREA = 1.65, AN = 1.55, AMS = 1.40, MAP = 1.95, DAP = 1.75, POTASH = 1.80, POLIFOSKA = 1.35,
        COMPOST = 0.60, BIOSOLIDS = 0.55, CHICKEN_MANURE = 0.50,
        PELLETIZED_MANURE = 0.70, GYPSUM = 0.35,  -- reduced: amendment, not plant food ($525/ha vs $1200)
    }

    -- customPrices[fillTypeIndex] = pricePerLiter
    local customPrices = {}
    for _, name in ipairs(ALL_CUSTOM_NAMES) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then
            local price = PRICE_OVERRIDES[name] or FALLBACK_PRICES[name]
            if price then
                customPrices[idx] = price
            end
        end
    end

    if not next(customPrices) then
        SoilLogger.warning("Purchase refill hook: no custom fill types with prices found - skipping")
        return false
    end

    local count = 0
    for _ in pairs(customPrices) do count = count + 1 end

    -- Helper: check if a fill unit on a vehicle is in "BUY/auto-purchase" mode.
    --
    -- Per LUADOC (Sprayer:getIsSprayerExternallyFilled), BUY mode is exclusively
    -- an AI/helper feature — it only activates when the vehicle is AI-controlled
    -- AND the player has opted in via the helper settings panel. For a human player
    -- driving manually, the tank always depletes normally (no BUY mode exists).
    --
    -- The three authoritative mission flags:
    --   helperBuyFertilizer   → "Buy Fertilizer" on in helper settings (covers all spray types)
    --   helperSlurrySource==2 → "Buy Slurry" from shop (covers liquid manure/digestate)
    --   helperManureSource==2 → "Buy Manure" from shop (covers solid manure)
    local function isInBuyMode(vehicle, fillUnitIndex, fillTypeIndex)
        if not vehicle then return false end

        -- 1. Check if AI is active (Standard Helper or Courseplay)
        --
        -- FS25 vanilla: getIsAIActive() / spec_aiVehicle.isActive / spec_aiJobVehicle.job
        -- Courseplay: drives via its own input-injection pipeline and does NOT set the
        -- vanilla AI-job system active.  CP marks itself via spec_cpAIWorker.isActive
        -- (all modern CP versions) and optionally vehicle.cp.isActive (legacy CP builds).
        -- We must check all paths so BUY mode works regardless of which AI mod is running.
        local isAI = false

        -- Vanilla Helper (primary)
        local ok, res = pcall(function() return vehicle:getIsAIActive() end)
        if ok and res then
            isAI = true
        end
        -- Vanilla Helper (spec fallbacks)
        if not isAI and vehicle.spec_aiVehicle and vehicle.spec_aiVehicle.isActive then
            isAI = true
        end
        if not isAI and vehicle.spec_aiJobVehicle and vehicle.spec_aiJobVehicle.job ~= nil then
            isAI = true
        end
        -- Courseplay (modern): spec_cpAIWorker is added by CP to every vehicle it controls
        if not isAI and vehicle.spec_cpAIWorker and vehicle.spec_cpAIWorker.isActive then
            isAI = true
        end
        -- Courseplay (legacy / fallback): CP sets vehicle.cp.isActive in older builds
        if not isAI and vehicle.cp and vehicle.cp.isActive then
            isAI = true
        end

        if not isAI then
            return false
        end

        -- 2. AI is active — check the mission settings for buy mode
        if g_currentMission and g_currentMission.missionInfo then
            local mi = g_currentMission.missionInfo
            
            -- Identify product category to check the right helper setting
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local ftName = fillType and fillType.name or "UNKNOWN"
            
            local isSlurry = (ftName == "LIQUIDMANURE" or ftName == "DIGESTATE")
            local isManure = (ftName == "MANURE")
            
            local buyActive = false
            if isSlurry then
                buyActive = (mi.helperSlurrySource == 2)
            elseif isManure then
                buyActive = (mi.helperManureSource == 2)
            else
                -- Fertilizer, Lime, Herbicide, and all our custom NPK/Crop-Protection types
                buyActive = mi.helperBuyFertilizer
            end

            -- Detailed debug logging (only when AI is active to avoid spam)
            if SoilLogger then
                SoilLogger.debug("BUY check: veh=%d, type=%s, buyActive=%s (AI=%s, SlurrySrc=%s, ManureSrc=%s, BuyFert=%s)",
                    vehicle.id or 0, ftName, tostring(buyActive), tostring(isAI),
                    tostring(mi.helperSlurrySource), tostring(mi.helperManureSource), tostring(mi.helperBuyFertilizer))
            end

            return buyActive
        end

        return false
    end

    -- FS25 real signature: FillUnit:addFillUnitFillLevel(farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
    -- When replaced as a class method, 'vehicle' is the implicit self (the vehicle with FillUnit spec).
    local original = FillUnit.addFillUnitFillLevel
    FillUnit.addFillUnitFillLevel = function(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
        -- Only intercept consumption (negative delta) of our custom types
        if fillLevelDelta >= 0 then
            return original(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
        end

        local pricePerLiter = customPrices[fillTypeIndex]
        if not pricePerLiter then
            return original(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
        end

        -- Check BUY mode
        if not isInBuyMode(vehicle, fillUnitIndex, fillTypeIndex) then
            return original(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
        end

        -- |fillLevelDelta| is the liters consumed this frame (negative value).
        local litersConsumed = -fillLevelDelta
        local cost = litersConsumed * pricePerLiter

        -- Charge the owning farm (use the farmId arg — it is the authoritative owner)
        local chargeFarmId = (farmId and farmId > 0) and farmId
            or vehicle.ownerFarmId
            or (vehicle.spec_enterable and vehicle.spec_enterable.activeFarmId)
        if chargeFarmId and chargeFarmId > 0 and g_currentMission then
            pcall(function()
                g_currentMission:addMoney(-cost, chargeFarmId, MoneyType.PURCHASE_FERTILIZER, true, true)
            end)
        end

        -- Stamp this vehicle so the sprayer-hook backup knows we already handled this frame.
        if g_currentMission then
            vehicle._soilBuyHandledAt = g_currentMission.time
        end
        -- Return the original delta so sprayer logic continues, but skip calling original
        -- so the physical fill level is never subtracted.
        SoilLogger.debug("BUY SUCCESS (FillUnit hook): veh=%d, type=%d, liters=%.2f, cost=%.2f",
            vehicle.id or 0, fillTypeIndex, litersConsumed, cost)
        return fillLevelDelta
    end

    self:registerCleanup("FillUnit.addFillUnitFillLevel (purchase refill)", function()
        FillUnit.addFillUnitFillLevel = original
    end)

    -- Share the price table with the sprayer hook (used as a reliable backup path)
    self.customFillTypePrices = customPrices

    SoilLogger.info("[OK] Purchase refill hook installed - BUY mode enabled for %d custom fill types", count)
    return true
end

-- =========================================================
-- HOOK 9: Fix AI "external fill" for custom fertilizer types
-- =========================================================
-- When getIsSprayerExternallyFilled() returns true (AI + helperBuyFertilizer) and the
-- vehicle's tank is empty (fillType == FillType.UNKNOWN), FS25's getExternalFill
-- matches the condition:
--   (fillType == UNKNOWN and (allowLiquidFertilizer or allowFertilizer or allowHerbicide))
-- Because we patched the fill unit to also accept vanilla FERTILIZER/LIQUIDFERTILIZER
-- (via installFillUnitHook), allowFertilizer == true even on a spreader loaded with UREA.
-- getExternalFill then returns vanilla FERTILIZER with buy-mode charging — silently
-- applying the wrong product to the terrain density map.
--
-- Fix: wrap getExternalFill. When fillType is one of our custom types (direct match),
-- OR fillType == UNKNOWN but the vehicle was last spraying a custom type
-- (_soilLastCustomFillType), intercept:
--   • Buy mode active → charge our price (1.5× AI premium), return our custom type.
--   • Buy mode inactive → return (UNKNOWN, 0) so the AI stops rather than falling
--     through to vanilla FERTILIZER.
---@return boolean success
function HookManager:installExternalFillHook()
    if not Sprayer or type(Sprayer.getExternalFill) ~= "function" then
        SoilLogger.warning("External fill hook: Sprayer.getExternalFill not available - skipping")
        return false
    end

    -- Capture HookManager instance (see note in installSprayerAreaHook).
    local hookMgrRef = self

    local original = Sprayer.getExternalFill

    Sprayer.getExternalFill = function(sprayerSelf, fillType, dt)
        local hookMgr = hookMgrRef
        local prices  = hookMgr and hookMgr.customFillTypePrices

        if not prices then
            return original(sprayerSelf, fillType, dt)
        end

        -- Identify the intended custom product.
        -- Priority order (issue #205 STARTER → LIQUIDFERTILIZER fix):
        --   1. fillType arg is already one of our custom types (direct match).
        --   2. Ask the tank what it actually holds (authoritative on a full/partial tank).
        --   3. Fall back to _soilLastCustomFillType (stamp set by the Sprayer-area hook;
        --      covers the empty-tank AI case where tank fill type is UNKNOWN).
        -- Step 2 is what prevents the "STARTER loaded but vanilla picks LIQUIDFERTILIZER"
        -- bug: when the caller passes fillType=UNKNOWN, the tank's real contents win over
        -- vanilla's allowLiquidFertilizer/allowFertilizer/allowHerbicide cascade.
        local customIdx = nil
        if fillType and fillType ~= FillType.UNKNOWN and prices[fillType] then
            customIdx = fillType
        else
            -- Step 2: read actual tank contents
            local okFui, sprayFui = pcall(function() return sprayerSelf:getSprayerFillUnitIndex() end)
            if okFui and sprayFui then
                local okTankFt, tankFt = pcall(function() return sprayerSelf:getFillUnitFillType(sprayFui) end)
                if okTankFt and tankFt and tankFt ~= FillType.UNKNOWN and prices[tankFt] then
                    customIdx = tankFt
                end
            end
            -- Step 3: empty-tank stamp fallback
            if not customIdx and sprayerSelf._soilLastCustomFillType and prices[sprayerSelf._soilLastCustomFillType] then
                customIdx = sprayerSelf._soilLastCustomFillType
            end
        end

        if not customIdx then
            return original(sprayerSelf, fillType, dt)
        end

        local mi = g_currentMission and g_currentMission.missionInfo
        if not mi then
            return FillType.UNKNOWN, 0
        end

        local fm = g_fillTypeManager
        local ft = fm and fm:getFillTypeByIndex(customIdx)
        local ftName = ft and ft.name or ""

        local buyActive = false
        if ftName == "LIQUIDMANURE" or ftName == "DIGESTATE" then
            buyActive = (mi.helperSlurrySource == 2)
        elseif ftName == "MANURE" then
            buyActive = (mi.helperManureSource == 2)
        else
            buyActive = (mi.helperBuyFertilizer == true)
        end

        if not buyActive then
            -- No buy mode: don't fall through to vanilla FERTILIZER; AI stops when empty.
            return FillType.UNKNOWN, 0
        end

        -- Buy mode active: charge our price and return the custom type so the
        -- correct product is written to the terrain density map.
        --
        -- Area-normalized usage (speed-based).
        -- Vanilla getSprayerUsage uses self.speedLimit (configured max speed in km/h),
        -- which over-charges when the vehicle moves slower than its speed limit.
        -- We replicate the vanilla formula but substitute lastSpeed (actual m/s → km/h)
        -- so consumption truly scales with area covered, not with the speed dial setting.
        -- Formula: scale × litersPerSecond × actualSpeed_km/h × workWidth_m × dt_ms × 0.001
        local usage
        do
            local actualSpeedKmh = math.abs(sprayerSelf.lastSpeed or 0) * 3600
            if actualSpeedKmh < 0.5 then
                -- Sprayer not moving (headland pivot, stopped).  No area covered, no charge.
                usage = 0
            else
                local spec_s   = sprayerSelf.spec_sprayer
                local usScale  = spec_s and spec_s.usageScale
                -- Prefer active spray-type's usageScale if present.
                local okAST, activeSpT = pcall(function() return sprayerSelf:getActiveSprayType() end)
                if okAST and activeSpT and activeSpT.usageScale then
                    usScale = activeSpT.usageScale
                end
                local workWidth = (usScale and usScale.workingWidth) or 12
                if usScale and usScale.workAreaIndex then
                    local okW, w = pcall(function()
                        return sprayerSelf:getWorkAreaWidth(usScale.workAreaIndex)
                    end)
                    if okW and w and w > 0 then workWidth = w end
                end
                -- fillType-specific scale (usually 1 for custom types, fallback to default).
                local fillScale = 1
                if spec_s and spec_s.usageScale then
                    local ft_scales = spec_s.usageScale.fillTypeScales
                    fillScale = (ft_scales and ft_scales[customIdx])
                        or spec_s.usageScale.default
                        or 1
                end
                -- litersPerSecond registered in g_sprayTypeManager for this fill type.
                local spT = g_sprayTypeManager and g_sprayTypeManager:getSprayTypeByFillTypeIndex(customIdx)
                local lps = spT and spT.litersPerSecond or 1
                usage = fillScale * lps * actualSpeedKmh * workWidth * dt * 0.001
            end
        end
        if sprayerSelf.isServer and usage > 0 then
            local pricePerLiter = prices[customIdx] or 1.0
            local price = usage * pricePerLiter * 1.5  -- 1.5× AI premium (matches vanilla)
            local farmId = sprayerSelf:getActiveFarm()
            local statsFarmId = farmId
            pcall(function() statsFarmId = sprayerSelf:getLastTouchedFarmlandFarmId() end)
            pcall(function()
                g_farmManager:updateFarmStats(statsFarmId, "expenses", price)
                g_currentMission:addMoney(-price, farmId, MoneyType.PURCHASE_FERTILIZER)
            end)
            -- Diagnostic: log BUY billing details every frame (debug mode only).
            -- usage = L charged this dt; price = cost this dt; eff = effective L/ha.
            -- Compare eff to BASE_RATES to validate the speed-based formula is correct.
            local spd   = math.abs(sprayerSelf.lastSpeed or 0) * 3600  -- km/h
            local spT2  = g_sprayTypeManager and g_sprayTypeManager:getSprayTypeByFillTypeIndex(customIdx)
            local lps2  = spT2 and spT2.litersPerSecond or 0
            local usagePerSec = (dt > 0) and (usage * 1000 / dt) or 0
            -- Resolve width via workAreaIndex (same path as SprayUsage hook) so eff
            -- in the log matches the actual billing width used in the usage calc above.
            local spec_s2   = sprayerSelf.spec_sprayer
            local usScale2  = spec_s2 and spec_s2.usageScale
            local okAST2, activeSpT2 = pcall(function() return sprayerSelf:getActiveSprayType() end)
            if okAST2 and activeSpT2 and activeSpT2.usageScale then
                usScale2 = activeSpT2.usageScale
            end
            local ww2 = (usScale2 and usScale2.workingWidth) or 12
            if usScale2 and usScale2.workAreaIndex then
                local okW2, w2 = pcall(function()
                    return sprayerSelf:getWorkAreaWidth(usScale2.workAreaIndex)
                end)
                if okW2 and w2 and w2 > 0 then ww2 = w2 end
            end
            local areaPerSec = spd * ww2 / 36000  -- ha/s
            local effLpha = (areaPerSec > 0) and (usagePerSec / areaPerSec) or 0
            SoilLogger.debug(
                "ExternalFill BUY veh=%d type=%-12s  spd=%.1f km/h  w=%.1fm  lps=%.6f  usage=%.4fL  cost=$%.4f  eff=%.1f L/ha",
                sprayerSelf.id or 0, ftName, spd, ww2, lps2, usage, price, effLpha)
        end

        return customIdx, usage
    end

    self:register(Sprayer, "getExternalFill", original, "Sprayer.getExternalFill")
    SoilLogger.info("[OK] External fill hook installed (Sprayer.getExternalFill)")
    return true
end

-- =========================================================
-- HOOK 9a-pre: Rate multiplier applied to wap.usage / wap.usagePerMin
-- =========================================================
-- onStartWorkAreaProcessing is registered as an EVENT LISTENER (not registerFunction),
-- so class-table patches via Utils.appendedFunction reach ALL vehicles reliably without
-- any 3-layer instance-table patching. This is the correct place to apply the rate
-- multiplier to the values that control:
--   • tank drain rate (wap.usage read in onEndWorkAreaProcessing)
--   • L/min HUD display (wap.usagePerMin read by getVariableWorkWidthUsage)
-- Applying mapMult inside getSprayerUsage (Hook 9a) was unreliable because
-- copyTypeFunctionsInto copies getSprayerUsage directly into vehicle instance tables,
-- and Layer-3 live patching missed vehicles in some FS25 versions (issue #538).
---@return boolean success
function HookManager:installSprayerStartHook()
    if not Sprayer or type(Sprayer.onStartWorkAreaProcessing) ~= "function" then
        SoilLogger.warning("SprayerStart hook: Sprayer.onStartWorkAreaProcessing not available — skipping")
        return false
    end

    local original = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(
        original,
        function(self, dt)
            if not self.isServer then return end
            local spec = self.spec_sprayer
            if not spec or not spec.workAreaParameters then return end
            if not g_SoilFertilityManager or not g_SoilFertilityManager.sprayerRateManager then return end

            local mult = g_SoilFertilityManager.sprayerRateManager:getMultiplier(self.id or 0)
            if mult == 1.0 then return end

            local wap = spec.workAreaParameters
            if wap.usage and wap.usage ~= 0 then
                wap.usage = wap.usage * mult
            end
            if wap.usagePerMin and wap.usagePerMin ~= 0 then
                wap.usagePerMin = wap.usagePerMin * mult
            end
        end
    )

    self:register(Sprayer, "onStartWorkAreaProcessing", original, "Sprayer.onStartWorkAreaProcessing (rate multiplier)")
    SoilLogger.info("[OK] SprayerStart hook installed — rate multiplier applied to wap.usage/usagePerMin")
    return true
end

-- =========================================================
-- HOOK 9a: Speed-based area-normalized sprayer consumption
-- =========================================================
-- Vanilla Sprayer:getSprayerUsage multiplies by self.speedLimit (configured max speed,
-- km/h) rather than self.lastSpeed (actual current speed, m/s). When the vehicle drives
-- slower than its speed limit (Courseplay following a planned route, turning at headlands,
-- slowing for obstacles), vanilla over-charges and under-applies per hectare.
--
-- Fix: replace speedLimit with lastSpeed × 3600 (converted to km/h for formula
-- compatibility). The rest of the vanilla formula is identical:
--   scale × litersPerSecond × actualSpeed_km/h × workWidth_m × dt_ms × 0.001
-- When the vehicle stops (headland pivot), lastSpeed ≈ 0 → usage = 0 → boom shuts off.
-- This is correct — no area is being covered.
--
-- Three-layer patch required: SpecializationUtil.registerFunction (line 91 of Sprayer.lua)
-- + copyTypeFunctionsInto means class-table patches never reach live vehicle instances.
-- Rate multiplier is no longer applied here; see installSprayerStartHook above.
---@return boolean success
function HookManager:installSprayerUsageHook()
    if not Sprayer or type(Sprayer.getSprayerUsage) ~= "function" then
        SoilLogger.warning("SprayerUsage hook: Sprayer.getSprayerUsage not available - skipping")
        return false
    end

    local originalClassFn = Sprayer.getSprayerUsage

    -- Throttle table: vehId → last log time (ms).  Shared across all replacement closures
    -- so that Layer-1/2/3 duplicates don't each log independently for the same vehicle.
    local _usageLogLastTime = {}

    local function makeUsageReplacement(originalFn)
        return function(sprayerSelf, fillType, dt)
            if fillType == FillType.UNKNOWN then return 0 end

            -- For towed implements (spreaders, trailing sprayers) lastSpeed may be nil
            -- because the implement has no independent physics body.
            -- If fillType is a custom type, we MUST NOT fall back to vanilla originalFn —
            -- vanilla getSprayerUsage only knows vanilla spray types and returns 0 for
            -- custom fill types (lps=nil), so the tank never depletes for towed spreaders.
            -- Instead, borrow speed from the rootVehicle (tractor pulling the implement).
            -- For vanilla fill types with nil lastSpeed, still fall back to originalFn as before.
            local effectiveSpeed = sprayerSelf.lastSpeed
            if effectiveSpeed == nil then
                local root = sprayerSelf.rootVehicle
                if root and root ~= sprayerSelf then
                    effectiveSpeed = root.lastSpeed
                end
            end

            local spT = g_sprayTypeManager and g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillType)
            if effectiveSpeed == nil or not spT then
                -- Vanilla fill type or no speed available: fall back to original vanilla formula
                return originalFn(sprayerSelf, fillType, dt)
            end

            -- Actual speed in km/h. effectiveSpeed is the implement's own lastSpeed,
            -- or the rootVehicle (tractor) speed for towed implements where lastSpeed=nil.
            local actualSpeedKmh = math.abs(effectiveSpeed) * 3600
            if actualSpeedKmh < 0.5 then
                -- Below 0.5 km/h (stopping, pivoting at headlands): no area covered.
                return 0
            end

            -- Mirror vanilla's full formula, substituting actualSpeed for speedLimit.
            local spec_s = sprayerSelf.spec_sprayer
            if not spec_s then
                return originalFn(sprayerSelf, fillType, dt)
            end

            -- fillType-specific scale (falls back to usageScale.default, normally 1.0)
            local fillScale = 1
            if spec_s.usageScale then
                local ft_scales = spec_s.usageScale.fillTypeScales
                fillScale = (ft_scales and ft_scales[fillType])
                    or spec_s.usageScale.default or 1
            end

            -- litersPerSecond from the spray type manager (registered for all custom types
            -- by registerCustomSprayTypes; vanilla types are always present).
            -- spT was already resolved above in the towed-implement check.
            local lps = spT and spT.litersPerSecond or 1

            -- Working width: prefer active spray-type's usageScale, then vehicle default.
            local usScale = spec_s.usageScale
            local okAST, activeSpT = pcall(function() return sprayerSelf:getActiveSprayType() end)
            if okAST and activeSpT and activeSpT.usageScale then
                usScale = activeSpT.usageScale
            end
            local workWidth = (usScale and usScale.workingWidth) or 12
            if usScale and usScale.workAreaIndex then
                local okW, w = pcall(function()
                    return sprayerSelf:getWorkAreaWidth(usScale.workAreaIndex)
                end)
                if okW and w and w > 0 then workWidth = w end
            end

            -- Rate multiplier is NOT applied here. It is applied via installSprayerStartHook
            -- (appended to Sprayer.onStartWorkAreaProcessing, an event listener with reliable
            -- class-table dispatch) which multiplies wap.usage and wap.usagePerMin after vanilla
            -- sets them. Applying it here via the 3-layer instance-table patch was unreliable:
            -- copyTypeFunctionsInto copies getSprayerUsage into vehicle instances at load time,
            -- and Layer 3 instance patching missed vehicles in some FS25 versions (issue #538).
            local usage = fillScale * lps * actualSpeedKmh * workWidth * dt * 0.001

            -- Throttled diagnostic: log once per 4 s per vehicle (debug mode only).
            -- Shows speed / width / lps / usage-per-second / effective L/ha so you can
            -- confirm the speed-based formula is working at the actual travel speed.
            local vehId = sprayerSelf.id or 0
            local now   = (g_currentMission and g_currentMission.time) or 0
            if (now - (_usageLogLastTime[vehId] or 0)) >= 4000 then
                _usageLogLastTime[vehId] = now
                local usagePerSec = (dt > 0) and (usage * 1000 / dt) or 0
                -- Effective L/ha = usage-rate / area-rate
                -- area/s = speed_kmh * 1000/3600 m/s * width_m / 10000 ha/m² = speed*width/36000
                local areaPerSec    = actualSpeedKmh * workWidth / 36000
                local effectiveLpha = (areaPerSec > 0) and (usagePerSec / areaPerSec) or 0
                local ftName = "?"
                local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
                if ft then ftName = ft.name end
                SoilLogger.debug(
                    "SprayUsage veh=%d type=%-12s  spd=%.1f km/h  w=%.1fm  lps=%.6f  scale=%.2f  usage/s=%.4f L/s  eff=%.1f L/ha",
                    vehId, ftName, actualSpeedKmh, workWidth, lps, fillScale, usagePerSec, effectiveLpha)
            end

            return usage
        end
    end

    -- Layer 1: class table
    Sprayer.getSprayerUsage = makeUsageReplacement(originalClassFn)

    -- Layer 2: vehicleType.functions for every type with Sprayer spec
    local typesPatched = 0
    if g_vehicleTypeManager and g_vehicleTypeManager.types then
        for _, typeDef in pairs(g_vehicleTypeManager.types) do
            local hasSprayer = typeDef.specializationsByName and typeDef.specializationsByName.sprayer
            if hasSprayer and typeDef.functions and typeDef.functions.getSprayerUsage then
                local origTypeFn = typeDef.functions.getSprayerUsage
                typeDef.functions.getSprayerUsage = makeUsageReplacement(origTypeFn)
                typesPatched = typesPatched + 1
            end
        end
    end

    -- Layer 3: every already-live vehicle instance
    local vehPatched = 0
    local vList = (g_currentMission and g_currentMission.vehicleSystem and
                   g_currentMission.vehicleSystem.vehicles) or
                  (g_currentMission and g_currentMission.vehicles) or {}
    for _, vehicle in pairs(vList) do
        if vehicle and rawget(vehicle, "getSprayerUsage") then
            local origInstFn = vehicle.getSprayerUsage
            vehicle.getSprayerUsage = makeUsageReplacement(origInstFn)
            vehPatched = vehPatched + 1
        end
    end

    self:register(Sprayer, "getSprayerUsage", originalClassFn, "Sprayer.getSprayerUsage (class only)")
    SoilLogger.info("[OK] SprayerUsage hook installed — actual-speed consumption (%d types, %d vehicles patched)",
        typesPatched, vehPatched)
    return true
end

-- =========================================================
-- HOOK 9b: Opt custom fill types into the vanilla "external fill" skip-depletion path
-- =========================================================
-- Root cause of issue #205 (BUY mode doesn't work with custom types / Courseplay):
-- vanilla Sprayer:getIsSprayerExternallyFilled() returns true only when
-- missionInfo.helperBuyFertilizer is true AND the sprayer is flagged as a
-- fertilizer sprayer. For SlurryTankers (helperSlurrySource==2) and
-- ManureSpreaders (helperManureSource==2) it always returns false, so vanilla
-- drains the tank normally. With custom slurry/manure fill types loaded, that
-- drain writes directly to the tank and then our getExternalFill hook refills
-- it — a race that flickers and double-charges.
--
-- Canonical fix: override getIsSprayerExternallyFilled so it ALSO returns true
-- when the tank holds one of our custom fill types AND the corresponding BUY
-- mode is active. This tells vanilla's onStartWorkAreaProcessing to clear
-- sprayVehicle/sprayVehicleFillUnitIndex to nil — which means
-- onEndWorkAreaProcessing's `if sprayVehicle ~= nil` check is false and
-- addFillUnitFillLevel is NEVER called. No tank drain. No race. No refill hook
-- needed. Money is still charged inside getExternalFill.
--
-- Covers all Sprayer-using implements:
--   - Pure Sprayer (field sprayer)
--   - SlurryTanker (uses Sprayer spec; helperSlurrySource==2 → BUY)
--   - ManureSpreader (uses Sprayer spec; helperManureSource==2 → BUY)
--   - FertilizingSowingMachine (planter+fertilizer; uses Sprayer spec)
--   - FertilizingCultivator (cultivator+fertilizer; uses Sprayer spec)
---@return boolean success
-- IMPORTANT: `SpecializationUtil.registerFunction` stores the function reference
-- in `vehicleType.functions[name]`, and at vehicle instantiation
-- `SpecializationUtil.copyTypeFunctionsInto` COPIES each reference directly onto
-- the vehicle instance (vehicle[name] = func).  Replacing only
-- `Sprayer.getIsSprayerExternallyFilled` on the class table has ZERO effect on
-- vehicles that were loaded before our hook ran — hence the fix must patch:
--   (1) the Sprayer class table (future loads)
--   (2) every vehicleType.functions["getIsSprayerExternallyFilled"] that has
--       Sprayer in its specialization list (new instances of known types)
--   (3) every already-live vehicle instance with the method copied on it
function HookManager:installExternalFillOptInHook()
    if not Sprayer or type(Sprayer.getIsSprayerExternallyFilled) ~= "function" then
        SoilLogger.warning("External fill opt-in hook: Sprayer.getIsSprayerExternallyFilled not available - skipping")
        return false
    end

    local originalClassFn = Sprayer.getIsSprayerExternallyFilled
    local hookMgr = self
    local hookMgrRef = self  -- upvalue used inside the closure below
    hookMgr._soilPatchedVehicles = hookMgr._soilPatchedVehicles or {}

    -- Build the replacement factory.  Each patched target gets its own wrapper
    -- that captures the ORIGINAL function it replaces (so we can still delegate
    -- to vanilla inside the wrapper).
    local function makeReplacement(originalFn)
        return function(sprayerSelf)
            -- Delegate to vanilla first — if vanilla already handles this vehicle
            -- (e.g. it's a recognised slurry tanker with helperSlurrySource==2),
            -- there's nothing extra to do.
            local okVanilla, vanillaRes = pcall(originalFn, sprayerSelf)
            local vanillaResult = okVanilla and vanillaRes or false
            if vanillaResult then
                return true
            end

            -- Only extend behaviour for our custom fill types.
            -- hookMgrRef is the captured HookManager upvalue (self at install time).
            local hm     = hookMgrRef
            local prices = hm and hm.customFillTypePrices
            if not prices then return vanillaResult end

            -- Require active AI field work (BUY mode is AI-only).
            local okAI, aiActive = pcall(function() return sprayerSelf:getIsAIActive() end)
            if not (okAI and aiActive) then return vanillaResult end

            local root = sprayerSelf.rootVehicle
            if not root then return vanillaResult end
            local okFW, fw = pcall(function() return root:getIsFieldWorkActive() end)
            if not (okFW and fw) then return vanillaResult end

            -- Identify tank contents (priority: arg fill type → tank fill type → last known custom type).
            local fillType = nil
            local okFui, sprayFui = pcall(function() return sprayerSelf:getSprayerFillUnitIndex() end)
            if okFui and sprayFui then
                local okFt, ft = pcall(function() return sprayerSelf:getFillUnitFillType(sprayFui) end)
                if okFt and ft and ft ~= FillType.UNKNOWN then fillType = ft end
            end
            if (not fillType or not prices[fillType]) and sprayerSelf._soilLastCustomFillType then
                fillType = sprayerSelf._soilLastCustomFillType
            end
            if not fillType or not prices[fillType] then return vanillaResult end

            local mi = g_currentMission and g_currentMission.missionInfo
            if not mi then return vanillaResult end

            local fm     = g_fillTypeManager
            local ftDef  = fm and fillType and fm:getFillTypeByIndex(fillType)
            local ftName = ftDef and ftDef.name or ""

            local buyActive = false
            if ftName == "LIQUIDMANURE" or ftName == "DIGESTATE" then
                buyActive = (mi.helperSlurrySource == 2)
            elseif ftName == "MANURE" then
                buyActive = (mi.helperManureSource == 2)
            else
                buyActive = (mi.helperBuyFertilizer == true)
            end
            if not buyActive then return vanillaResult end

            SoilLogger.debug("BUY opt-in engaged: veh=%s type=%s", tostring(sprayerSelf.id or "?"), ftName)
            return true
        end
    end

    -- -----------------------------------------------------------------
    -- Layer 1: patch the Sprayer class table (future vehicleType loads).
    -- -----------------------------------------------------------------
    Sprayer.getIsSprayerExternallyFilled = makeReplacement(originalClassFn)

    -- -----------------------------------------------------------------
    -- Layer 2: patch g_vehicleTypeManager.types[*].functions for every
    -- type that has Sprayer in its specialization list.
    -- -----------------------------------------------------------------
    local typesPatched, typesSeen, typesSkipped = 0, 0, 0
    local typeManager = g_vehicleTypeManager
    if typeManager and typeManager.types then
        for _, typeDef in pairs(typeManager.types) do
            typesSeen = typesSeen + 1
            local hasSprayer = false
            if typeDef.specializationsByName and typeDef.specializationsByName.sprayer then
                hasSprayer = true
            elseif typeDef.specializations then
                for _, spec in ipairs(typeDef.specializations) do
                    if spec == Sprayer or (spec and spec.specName == "sprayer") then
                        hasSprayer = true
                        break
                    end
                end
            end
            if hasSprayer and typeDef.functions and typeDef.functions.getIsSprayerExternallyFilled then
                local origTypeFn = typeDef.functions.getIsSprayerExternallyFilled
                typeDef.functions.getIsSprayerExternallyFilled = makeReplacement(origTypeFn)
                typesPatched = typesPatched + 1
            elseif hasSprayer then
                typesSkipped = typesSkipped + 1
            end
        end
    end
    SoilLogger.debug("BUY opt-in hook: vehicleType scan — seen=%d, sprayer-types patched=%d",
        typesSeen, typesPatched)

    -- -----------------------------------------------------------------
    -- Layer 3: patch every already-live vehicle instance.
    -- -----------------------------------------------------------------
    local vehPatched, vehSeen = 0, 0
    if g_currentMission and g_currentMission.vehicleSystem and g_currentMission.vehicleSystem.vehicles then
        for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
            vehSeen = vehSeen + 1
            if vehicle and rawget(vehicle, "getIsSprayerExternallyFilled") then
                local origInstFn = vehicle.getIsSprayerExternallyFilled
                vehicle.getIsSprayerExternallyFilled = makeReplacement(origInstFn)
                vehPatched = vehPatched + 1
            end
        end
    elseif g_currentMission and g_currentMission.vehicles then
        -- Older API path fallback
        for _, vehicle in pairs(g_currentMission.vehicles) do
            vehSeen = vehSeen + 1
            if vehicle and rawget(vehicle, "getIsSprayerExternallyFilled") then
                local origInstFn = vehicle.getIsSprayerExternallyFilled
                vehicle.getIsSprayerExternallyFilled = makeReplacement(origInstFn)
                vehPatched = vehPatched + 1
            end
        end
    end
    SoilLogger.debug("BUY opt-in hook: live vehicle scan — seen=%d, patched=%d", vehSeen, vehPatched)

    -- -----------------------------------------------------------------
    -- Cleanup: restore only the Sprayer class reference on uninstall.
    -- (Types/instances aren't restored — they'd already be stale.)
    -- -----------------------------------------------------------------
    self:register(Sprayer, "getIsSprayerExternallyFilled", originalClassFn,
        "Sprayer.getIsSprayerExternallyFilled (class only)")
    SoilLogger.info("[OK] External fill opt-in hook installed — BUY mode should now engage for custom types")
    return true
end

-- =========================================================
-- Re-apply the opt-in patch to the `getExternalFill` function too
-- (same dispatch issue — the existing installExternalFillHook patches only the
-- class table, so it never reaches live instances).  We piggy-back here to
-- patch typeDef.functions["getExternalFill"] and live instances with the
-- SAME wrapper that installExternalFillHook already built.
-- =========================================================
function HookManager:propagateExternalFillHookToLiveVehicles()
    if not Sprayer then return end
    local classFn = Sprayer.getExternalFill  -- the wrapper installed by installExternalFillHook
    if not classFn then return end

    local typesPatched = 0
    if g_vehicleTypeManager and g_vehicleTypeManager.types then
        for typeName, typeDef in pairs(g_vehicleTypeManager.types) do
            local hasSprayer = false
            if typeDef.specializationsByName and typeDef.specializationsByName.sprayer then
                hasSprayer = true
            end
            if hasSprayer and typeDef.functions and typeDef.functions.getExternalFill then
                -- Only overwrite if still pointing at the original vanilla fn.
                typeDef.functions.getExternalFill = classFn
                typesPatched = typesPatched + 1
            end
        end
    end

    local vehPatched = 0
    local vList = (g_currentMission and g_currentMission.vehicleSystem and
                   g_currentMission.vehicleSystem.vehicles) or
                  (g_currentMission and g_currentMission.vehicles) or {}
    for _, vehicle in pairs(vList) do
        if vehicle and rawget(vehicle, "getExternalFill") then
            vehicle.getExternalFill = classFn
            vehPatched = vehPatched + 1
        end
    end
    SoilLogger.debug("getExternalFill wrapper propagated — typeDefs=%d, liveVehicles=%d",
        typesPatched, vehPatched)
end

-- =========================================================
-- HOOK 10: Fix fill plane and fill volume texture for custom types
-- =========================================================
-- updateFillUnitFillPlane (FillUnit) and FillVolume:onUpdate both call:
--   g_fillTypeManager:getTextureArrayIndexByFillTypeIndex(fillType)
-- to set the "fillTypeId" shader parameter that selects which texture in the
-- terrain fill-type array is shown on the fill plane / fill volume mesh.
-- Custom fill types are not registered with texture array entries, so the
-- call returns nil and the visual never updates — the fill plane and hopper
-- mesh stay on whatever they showed before (or show nothing/wrong colour).
--
-- Fix: wrap getTextureArrayIndexByFillTypeIndex. When the index belongs to one
-- of our custom types and the original returns nil, remap to the vanilla
-- equivalent (FERTILIZER for solid types, LIQUIDFERTILIZER for liquid types)
-- and return its texture array index. Purely cosmetic — nutrient tracking is
-- unaffected.
---@return boolean success
function HookManager:installFillTypeMaterialHook()
    if not g_fillTypeManager or type(g_fillTypeManager.getTextureArrayIndexByFillTypeIndex) ~= "function" then
        SoilLogger.warning("Fill type material hook: getTextureArrayIndexByFillTypeIndex not available - skipping")
        return false
    end

    local fm = g_fillTypeManager
    local origGetTexIdx = fm.getTextureArrayIndexByFillTypeIndex

    -- Helper: resolve the first vanilla fill type from a priority list that actually
    -- has a textureArrayIndex registered on this map's terrain fill layer array.
    -- Returns the fill type INDEX (not textureArrayIndex) of the best match, or nil.
    local function bestVanilla(priorityNames)
        for _, name in ipairs(priorityNames) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then
                local texIdx = origGetTexIdx(fm, idx)
                if texIdx ~= nil then
                    return idx
                end
            end
        end
        return nil
    end

    -- Per-type visual priority lists (best match first, broad fallbacks last).
    -- Each list is ordered from closest visual match to broadest fallback.
    -- All candidates are vanilla FS25 base-game fill types guaranteed to exist
    -- on standard maps. The runtime probe above ensures we only use types that
    -- actually have a registered texture on the current map.
    --
    -- Appearance reference:
    --   LIME            → bright white powder
    --   FERTILIZER      → off-white/pale granular
    --   MANURE          → dark brown chunky organic
    --   DIGESTATE       → dark brown/grey liquid-spread organic
    --   LIQUIDMANURE    → dark brown liquid slurry
    --   LIQUIDFERTILIZER→ amber/clear liquid
    --   SEEDS           → small pale tan granules
    --   STRAW           → golden-yellow fibre
    --   CHAFF           → greenish/yellow fine fibre

    local PER_TYPE_PRIORITIES = {
        -- ── GRANULAR MINERAL FERTILIZERS ──────────────────────────────────
        -- White to off-white crystalline/granular powders
        UREA     = { "LIME", "FERTILIZER" },            -- Urea is bright white granular → LIME first
        AMS      = { "FERTILIZER", "LIME" },            -- AMS is off-white/light grey granular
        MAP      = { "FERTILIZER", "LIME" },            -- MAP is off-white/light brown granular
        DAP      = { "FERTILIZER", "LIME" },            -- DAP is off-white/grey-brown granular
        POTASH    = { "FERTILIZER", "LIME" },           -- Potassium chloride — pinkish but granular
        POLIFOSKA = { "FERTILIZER", "LIME" },           -- Compound 6-20-30 granular — off-white/pinkish
        GYPSUM    = { "LIME", "FERTILIZER" },            -- Gypsum is bright white powder → LIME first

        -- ── ORGANIC / COMPOST TYPES ────────────────────────────────────────
        -- Dark brown to black matte organic material
        COMPOST          = { "MANURE", "DIGESTATE", "FERTILIZER" },         -- Dark brown chunky compost
        BIOSOLIDS        = { "DIGESTATE", "MANURE", "FERTILIZER" },         -- Very dark, fine-grained sludge cake
        CHICKEN_MANURE   = { "MANURE", "DIGESTATE", "FERTILIZER" },         -- Dark brown granular litter
        PELLETIZED_MANURE = { "MANURE", "DIGESTATE", "FERTILIZER" },        -- Dark brown pellets
    }

    -- Liquid custom types → LIQUIDFERTILIZER (all liquid, colour difference is minor)
    local LIQUID_NAMES = {
        "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
        "INSECTICIDE", "FUNGICIDE",
        "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH"
    }
    local liqFertIdx = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")

    -- Build the final remap table: customFillTypeIndex → bestVanillaFillTypeIndex
    local remap = {}
    local logLines = {}

    for customName, priorities in pairs(PER_TYPE_PRIORITIES) do
        local customIdx = fm:getFillTypeIndexByName(customName)
        if customIdx then
            local vanillaIdx = bestVanilla(priorities)
            if vanillaIdx then
                remap[customIdx] = vanillaIdx
                local vanillaFT = fm:getFillTypeByIndex(vanillaIdx)
                table.insert(logLines, string.format("  %-20s → %s", customName, vanillaFT and vanillaFT.name or "?"))
            else
                SoilLogger.warning("Fill type material hook: no texture array entry found for %s priorities (%s) — type will show default",
                    customName, table.concat(priorities, ", "))
            end
        end
    end

    if liqFertIdx then
        -- Only add to remap if liqFertIdx actually has a textureArrayIndex
        local liqTexIdx = origGetTexIdx(fm, liqFertIdx)
        if liqTexIdx then
            for _, name in ipairs(LIQUID_NAMES) do
                local idx = fm:getFillTypeIndexByName(name)
                if idx then
                    remap[idx] = liqFertIdx
                end
            end
        end
    end

    if not next(remap) then
        SoilLogger.warning("Fill type material hook: no custom fill types could be remapped — skipping")
        return false
    end

    local count = 0
    for _ in pairs(remap) do count = count + 1 end

    fm.getTextureArrayIndexByFillTypeIndex = function(mgr, fillTypeIndex, ...)
        local result = origGetTexIdx(mgr, fillTypeIndex, ...)
        if result == nil and fillTypeIndex then
            local vanillaIdx = remap[fillTypeIndex]
            if vanillaIdx then
                result = origGetTexIdx(mgr, vanillaIdx, ...)
            end
        end
        return result
    end

    self:registerCleanup("g_fillTypeManager.getTextureArrayIndexByFillTypeIndex", function()
        fm.getTextureArrayIndexByFillTypeIndex = origGetTexIdx
    end)

    SoilLogger.info("[OK] Fill type material hook installed - %d custom types remapped:\n%s",
        count, table.concat(logLines, "\n"))
    return true
end

-- =========================================================
-- HOOK 11: Direct client-side visual effects for custom liquid fill types
-- =========================================================
-- FertilizerMotionPathEffect (used by liquid sprayer boom visuals) looks up motion
-- path data by fill type index. Vanilla types have data registered; our custom types
-- do not, so the lookup returns nil and the effect never starts — even when our
-- setEffectTypeInfo hook correctly remaps the index to LIQUIDFERTILIZER before storage.
-- The failure is inside FS25's internal C++ effect pipeline, which may execute before
-- the Lua hook fires.
--
-- Fix: hook Sprayer.onUpdateTick (registered via SpecializationUtil.registerEventListener,
-- dynamic dispatch — reaches all vehicles immediately). On the client (visual only):
--   • detect fill type change and when getAreEffectsVisible() changes state
--   • call setEffectTypeInfo + startEffects directly with the vanilla-equivalent fill type
--   • call stopEffects when the sprayer stops or fill type changes
-- This runs once per state-change (not per-frame), is purely cosmetic, and does NOT
-- interfere with nutrient tracking which uses the real fill type from wap.sprayFillType.
---@return boolean success
function HookManager:installSprayerVisualEffectHook()
    if not Sprayer or type(Sprayer.onUpdateTick) ~= "function" then
        SoilLogger.warning("Sprayer visual effect hook: Sprayer.onUpdateTick not available - skipping")
        return false
    end
    if not g_fillTypeManager then
        SoilLogger.warning("Sprayer visual effect hook: g_fillTypeManager not available - skipping")
        return false
    end

    local fm = g_fillTypeManager
    local fertIdx    = fm:getFillTypeIndexByName("FERTILIZER")
    local liqFertIdx = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")

    -- Build remap: custom fill type index → vanilla fill type index (cosmetic only).
    -- LIQUID types only — solid types are intentionally EXCLUDED.
    -- Solid types (UREA, AMS, MAP, DAP, etc.) use the vanilla path (remap returns nil →
    -- just return), which lets vanilla's onEndWorkAreaProcessing/updateSprayerEffects manage
    -- effects. This matches how AN works (AN is absent from this remap and works correctly).
    -- The custom path (Sprayer.onUpdateTick appended) fires BEFORE WorkArea.onUpdateTick,
    -- so getAreEffectsVisible() is false when our code runs — the stop-path kills effects
    -- every tick for solid types. The vanilla path fires from onEndWorkAreaProcessing, which
    -- runs AFTER processSprayerArea sets lastSprayTime → effectsVisible = true → effects start.
    local remap = {}
    if liqFertIdx then
        for _, name in ipairs({ "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                                 "HERBICIDE", "INSECTICIDE", "FUNGICIDE",
                                 "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then remap[idx] = liqFertIdx end
        end
    end

    if not next(remap) then
        SoilLogger.warning("Sprayer visual effect hook: no custom fill types found - skipping")
        return false
    end

    local function startSprayerEffects(vehicle, vanillaFillType)
        local spec = vehicle.spec_sprayer
        if not spec then return end
        if spec.effects and #spec.effects > 0 then
            g_effectManager:setEffectTypeInfo(spec.effects, vanillaFillType)
            g_effectManager:startEffects(spec.effects)
        end
        for _, st in ipairs(spec.sprayTypes or {}) do
            if st.effects and #st.effects > 0 then
                g_effectManager:setEffectTypeInfo(st.effects, vanillaFillType)
                g_effectManager:startEffects(st.effects)
                g_animationManager:startAnimations(st.animationNodes)
                g_soundManager:playSamples(st.samples and st.samples.spray or {})
            end
        end
        -- Start VWW wing-section effects for sections that are active and not suppressed.
        -- (The per-tick loop in onUpdateTick will stop suppressed sections dynamically.)
        local vww = vehicle.spec_variableWorkWidth
        if vww and vww.sections then
            local sfSuppressed      = vehicle._sfSuppressedSections       or {}
            local overlapSuppressed = vehicle._sfOverlapSuppressedSections or {}
            for i, section in ipairs(vww.sections) do
                if section.isActive and not sfSuppressed[i] and not overlapSuppressed[i] and
                   section.effects and #section.effects > 0 then
                    g_effectManager:setEffectTypeInfo(section.effects, vanillaFillType)
                    g_effectManager:startEffects(section.effects)
                end
            end
        end
    end

    local function stopSprayerEffects(vehicle)
        local spec = vehicle.spec_sprayer
        if not spec then return end
        -- Mirror vanilla Sprayer updateSprayerEffects off-path exactly:
        -- spec.effects, spec.animationNodes, spec.samples.spray, then all sprayTypes.
        g_effectManager:stopEffects(spec.effects)
        g_animationManager:stopAnimations(spec.animationNodes)
        g_soundManager:stopSamples(spec.samples and spec.samples.spray or {})
        for _, st in ipairs(spec.sprayTypes or {}) do
            g_effectManager:stopEffects(st.effects)
            g_animationManager:stopAnimations(st.animationNodes)
            g_soundManager:stopSamples(st.samples and st.samples.spray or {})
        end
        -- Stop VWW wing-section effects.
        local vww = vehicle.spec_variableWorkWidth
        if vww and vww.sections then
            for _, section in ipairs(vww.sections) do
                if section.effects and #section.effects > 0 then
                    g_effectManager:stopEffects(section.effects)
                end
            end
        end
    end

    local original = Sprayer.onUpdateTick
    Sprayer.onUpdateTick = Utils.appendedFunction(
        original,
        function(sprayerSelf, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
            if not sprayerSelf.isClient then return end

            local spec = sprayerSelf.spec_sprayer
            if not spec then return end

            local fillUnitIndex = sprayerSelf:getSprayerFillUnitIndex()
            local fillType = sprayerSelf:getFillUnitFillType(fillUnitIndex)
            local vanillaFillType = fillType and remap[fillType]

            -- If fill type changed away from custom, stop our managed effects and reset.
            -- Also reset lastEffectsState so vanilla re-evaluates its state machine next
            -- tick — without this, vanilla thinks effects are still running after our stop
            -- and won't restart them when switching to a vanilla fill type (HERBICIDE etc.).
            local lastFT = spec._soilManagedFillType
            if lastFT and lastFT ~= fillType then
                stopSprayerEffects(sprayerSelf)
                spec._soilManagedFillType = nil
                spec._soilEffectsActive   = nil
                spec.lastEffectsState     = nil
            end

            -- Fold detection — computed once, applied to both vanilla and custom paths below.
            -- Mirror vanilla Foldable line 1286: working position is dir==-1,fa==0 OR dir==1,fa==1.
            -- turnOnFoldDirection defaults to 1 or -1 (never 0 after Foldable init); if somehow
            -- nil, fall back to animation-only detection (0 < fa < 1).
            local isFolded = false
            if sprayerSelf.spec_foldable then
                local foldSpec = sprayerSelf.spec_foldable
                local fa  = foldSpec.foldAnimTime
                local dir = foldSpec.turnOnFoldDirection
                if fa ~= nil then
                    if dir ~= nil then
                        isFolded = (dir == -1 and fa ~= 0) or (dir == 1 and fa ~= 1)
                    else
                        isFolded = fa > 0 and fa < 1
                    end
                end
            end

            if not vanillaFillType then
                return
            end

            -- getAreEffectsVisible() uses a 100ms window on lastSprayTime; if processSprayerArea
            -- isn't running (vehicle stopped or empty) that window expires naturally — no speed
            -- check needed. The speed check broke trailed spreaders whose getLastSpeed() returns 0.
            local effectsVisible = sprayerSelf:getAreEffectsVisible()

            if isFolded then effectsVisible = false end

            -- Stop path: suppress every tick (no state-change guard).
            -- vanilla onUpdateTick runs before us (appendedFunction) and can
            -- restart effects each tick, so we must cancel every tick — same
            -- reason the vanilla fill type path at line ~4725 does the same.
            if not effectsVisible then
                stopSprayerEffects(sprayerSelf)
                if spec._soilEffectsActive ~= false then
                    spec._soilEffectsActive   = false
                    spec._soilManagedFillType = fillType
                    SoilLogger.debug("SprayerVisual: stopped effects (fillType=%d)", fillType)
                end
                return
            end

            -- Per-tick VWW section effect correction.
            -- startSprayerEffects handles the initial start (state change). This loop handles
            -- dynamic suppression changes: stops effects on sections suppressed by Smart Sensor,
            -- boundary enforcement, or overlap prevention; restarts them when un-suppressed.
            -- Does NOT stop sections that VWW set to isActive=false for its own reasons
            -- (overlap prevention, width control, "no width" mode) — those are VWW's concern.
            do
                local vwwS = sprayerSelf.spec_variableWorkWidth
                if vwwS and vwwS.sections then
                    local sfSuppressed      = sprayerSelf._sfSuppressedSections       or {}
                    local overlapSuppressed = sprayerSelf._sfOverlapSuppressedSections or {}
                    for i, section in ipairs(vwwS.sections) do
                        if section.effects and #section.effects > 0 then
                            if sfSuppressed[i] or overlapSuppressed[i] then
                                -- Positively suppressed by our system: stop nozzle animation
                                g_effectManager:stopEffects(section.effects)
                            elseif section.isActive then
                                -- Active and not suppressed: ensure running (handles un-suppress)
                                g_effectManager:setEffectTypeInfo(section.effects, vanillaFillType)
                                g_effectManager:startEffects(section.effects)
                            end
                            -- isActive=false + not suppressed: VWW-managed, do not interfere
                        end
                    end

                    -- When ALL VWW sections are overlap-suppressed, also stop global effects.
                    -- Self-propelled boom sprayers (e.g. Agri-Dino) have a non-VWW centre
                    -- work area whose spray comes from spec.effects / sprayTypes — the
                    -- per-section loop above never reaches those.
                    local overlapSuppressed2 = sprayerSelf._sfOverlapSuppressedSections
                    if overlapSuppressed2 and #vwwS.sections > 0 then
                        local allSuppressed = true
                        for i = 1, #vwwS.sections do
                            if not overlapSuppressed2[i] then allSuppressed = false; break end
                        end
                        if allSuppressed then
                            g_effectManager:stopEffects(spec.effects)
                            for _, st in ipairs(spec.sprayTypes or {}) do
                                g_effectManager:stopEffects(st.effects)
                            end
                            sprayerSelf._sfWasAllOverlapSuppressed = true
                            SoilLogger.debug("[OverlapPrev] allSuppressed=%d → global effects stopped", #vwwS.sections)
                            return  -- skip start path — nothing unsuppressed to start
                        elseif sprayerSelf._sfWasAllOverlapSuppressed then
                            -- Transitioning out of full suppression: force global effect restart
                            sprayerSelf._sfWasAllOverlapSuppressed = nil
                            spec._soilEffectsActive = nil
                        end
                    end
                end
            end

            -- Start path: only act on state change to avoid per-tick overhead
            if spec._soilEffectsActive then return end

            spec._soilEffectsActive   = true
            spec._soilManagedFillType = fillType
            startSprayerEffects(sprayerSelf, vanillaFillType)
            SoilLogger.debug("SprayerVisual: started effects (fillType=%d → vanilla=%d)", fillType, vanillaFillType)
        end
    )
    self:register(Sprayer, "onUpdateTick", original, "Sprayer.onUpdateTick (sprayer visual effects)")

    local count = 0
    for _ in pairs(remap) do count = count + 1 end
    SoilLogger.info("[OK] Sprayer visual effect hook installed on onUpdateTick — %d custom fill types", count)
    return true
end

-- =========================================================
-- HOOK 12: Client Joined (FSBaseMission.onConnectionFinished)
-- =========================================================
--- Hooks FSBaseMission.onConnectionFinished to send soil data to a newly joined client
---@return boolean success
function HookManager:installClientJoinHook()
    -- FSBaseMission.onConnectionFinished does not exist in FS25.
    -- The correct FS25 pattern is addModEventListener with an onClientJoined(connection)
    -- method, which the C++ engine calls on all registered mod event listeners
    -- when a new client successfully connects to the server.
    local listener = {
        onClientJoined = function(self, connection)
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end
            -- Server only - send full state to the connecting client
            if g_server ~= nil and connection then
                local success, errorMsg = pcall(function()
                    g_SoilFertilityManager.soilSystem:onClientJoined(connection)
                end)
                if not success then
                    SoilLogger.error("Client join hook failed: %s", tostring(errorMsg))
                end
            end
        end
    }
    addModEventListener(listener)
    -- Store reference so uninstallAll can remove it
    self._clientJoinListener = listener
    SoilLogger.info("[OK] Client join hook installed (addModEventListener/onClientJoined)")
    return true
end

-- =========================================================
-- HOOK 13: PF NitrogenMap zero-N guard
-- =========================================================
--- Wraps NitrogenMap.getFertilizerUsageByNitrogenAmount in a pcall so that
--- zero-N fill types (LIQUID_POTASH, POTASH) don't cause a divide-by-zero crash
--- in PrecisionFarming's sprayer HUD. No-op when PF is not installed.
---@return boolean success
function HookManager:installPFNitrogenMapHook()
    if type(NitrogenMap) ~= "table" or
       type(NitrogenMap.getFertilizerUsageByNitrogenAmount) ~= "function" then
        SoilLogger.info("[PFNitrogenGuard] NitrogenMap not found — PF absent or API changed, skipping")
        return true  -- not a failure; PF just isn't installed
    end

    local orig = NitrogenMap.getFertilizerUsageByNitrogenAmount
    NitrogenMap.getFertilizerUsageByNitrogenAmount = function(self, ...)
        local ok, result = pcall(orig, self, ...)
        if not ok then
            return 0
        end
        return result
    end
    self:register(NitrogenMap, "getFertilizerUsageByNitrogenAmount", orig,
                  "NitrogenMap.getFertilizerUsageByNitrogenAmount")
    SoilLogger.info("[OK] PF NitrogenMap zero-N guard installed")
    return true
end

-- =========================================================
-- UTILITY: Boom Cell Sweep (issue #362)
-- =========================================================
--- Collect world positions spanning the spray boom's lateral extent by reading
--- work-area start/end nodes on the vehicle and all attached implements.
--- Used to mark every 10 m cell the boom passes over — not just the rootNode cell.
---
--- Falls back to nil when no spanning node pair is found (caller marks only rootNode).
---@param vehicle table  The sprayer vehicle (self in the spray hook)
---@param rootX   number  Vehicle root-node world X
---@param rootZ   number  Vehicle root-node world Z
---@return table|nil  Array of {x=, z=} world positions, or nil if span < 2 nodes
function HookManager:getBoomCellPositions(vehicle, rootX, rootZ)
    local cellSize = SoilConstants.ZONE.CELL_SIZE
    local xs, zs = {}, {}

    local function addNode(node)
        if not node then return end
        local ok, x, _, z = pcall(getWorldTranslation, node)
        if ok and x then table.insert(xs, x); table.insert(zs, z) end
    end

    local function collectFromObj(obj)
        if not obj then return end
        -- WorkArea corner nodes. FS25 work areas are defined by start/width/height nodes
        -- (confirmed in SDK Combine/Baler/CropSensor): 'width' is the lateral boom edge,
        -- 'height' the forward edge. The old code read start and a non-existent 'end', so a
        -- broadcast spreader without VariableWorkWidth collapsed to the single start node —
        -- getBoomCellPositions then returned nil and dry fertilizer never painted boom-width
        -- coverage cells (no tracking markers, map barely changed). Issue #626.
        if obj.spec_workArea and obj.spec_workArea.workAreas then
            for _, wa in ipairs(obj.spec_workArea.workAreas) do
                addNode(wa.start)
                addNode(wa.width)
                addNode(wa.height)
            end
        end
        -- VWW section maxWidthNodes capture the outer boom edge of each section —
        -- workArea start/end nodes are often co-located at the centre, giving a
        -- near-zero span and causing the function to return nil for boom sprayers.
        local vww = obj.spec_variableWorkWidth
        if vww and vww.sections then
            for _, section in ipairs(vww.sections) do
                -- Skip inactive sections (Partial Width mode): their maxWidthNodes are still
                -- physically at the boom tip position, which would incorrectly inflate the
                -- detected boom span and credit cells that were never sprayed (#475/#476).
                if section.isActive ~= false and section.maxWidthNode then
                    local ok, x, _, z = pcall(getWorldTranslation, section.maxWidthNode)
                    if ok and x then table.insert(xs, x); table.insert(zs, z) end
                end
            end
        end
    end

    collectFromObj(vehicle)
    if vehicle.spec_attacherJoints and vehicle.spec_attacherJoints.attachedImplements then
        for _, impl in ipairs(vehicle.spec_attacherJoints.attachedImplements or {}) do
            collectFromObj(impl and impl.object)
        end
    end

    if #xs < 2 then return nil end

    local minX, maxX = xs[1], xs[1]
    local minZ, maxZ = zs[1], zs[1]
    for _, x in ipairs(xs) do minX = math.min(minX, x); maxX = math.max(maxX, x) end
    for _, z in ipairs(zs) do minZ = math.min(minZ, z); maxZ = math.max(maxZ, z) end

    local spanX = maxX - minX
    local spanZ = maxZ - minZ
    -- Only sweep if the detected span is meaningfully wider than one cell
    if math.max(spanX, spanZ) < cellSize * 0.5 then return nil end

    local halfCell = cellSize * 0.5
    local pts = {}

    if spanX >= spanZ then
        -- Boom runs primarily east-west: sweep along X
        local x = minX
        while x <= maxX + halfCell do
            table.insert(pts, {x = x, z = rootZ})
            x = x + cellSize
        end
    else
        -- Boom runs primarily north-south: sweep along Z
        local z = minZ
        while z <= maxZ + halfCell do
            table.insert(pts, {x = rootX, z = z})
            z = z + cellSize
        end
    end

    -- Always include the root cell so the center section has a stamp to check.
    -- The sweep may skip it depending on alignment with the 10 m grid.
    table.insert(pts, {x = rootX, z = rootZ})

    return (#pts > 1) and pts or nil
end