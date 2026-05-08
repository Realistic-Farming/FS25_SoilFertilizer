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
    return self
end

--- Helper to get field ID from world coordinates
---@param x number World X coordinate
---@param z number World Z coordinate
---@return number|nil fieldId
function HookManager:getFieldIdAtWorldPosition(x, z)
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
            if cachedId == -1 then return nil end  -- -1 = known empty space
            return cachedId
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

    -- Fertilizer application hook (covers ALL sprayers + spreaders via Sprayer specialization)
    local sprayerAreaOk = self:installSprayerAreaHook()
    if sprayerAreaOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Field ownership changes
    local ownershipOk = self:installOwnershipHook()
    if ownershipOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Weather/environment effects
    local weatherOk = self:installWeatherHook()
    if weatherOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Plowing benefits (cultivators + deep-tillage via Cultivator spec)
    local plowingOk = self:installPlowingHook()
    if plowingOk then successCount = successCount + 1 else failCount = failCount + 1 end

    -- Dedicated plow implements (Plow.onEndWorkAreaProcessing)
    local dedicatedPlowOk = self:installDedicatedPlowHook()
    if dedicatedPlowOk then successCount = successCount + 1 else failCount = failCount + 1 end

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
    -- NOTE: HERBICIDE must be here so it gets a custom LPS of 1.5/36000 L/s, matching
    -- INSECTICIDE and FUNGICIDE. Without it, vanilla's native HERBICIDE spray type is
    -- used (~291 L/ha effective rate vs the intended 1.5 L/ha), causing weed pressure
    -- to drain far too fast even with the daily cap in onHerbicideAppliedDirect (the
    -- cap drains its full 30-point budget in the very first metre of a pass, then
    -- repeats on subsequent game-day passes — issue #276 follow-up bug).
    -- LIQUIDMANURE, MANURE, DIGESTATE were previously omitted from this list, causing them to fall
    -- through to whatever vanilla spray type LPS the game uses (often very low or undefined).
    -- The result: wap.usage was tiny → nutrient gain and coverage nearly zero (issue #311).
    -- Fix: register all three with customLPS = BASE_RATE / 36000 so they drain at the calibrated rate.
    local liquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME", "HERBICIDE", "INSECTICIDE", "FUNGICIDE",
                          "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH",
                          "LIQUIDMANURE", "MANURE", "DIGESTATE" }
    -- Granular/solid types → inherit visual from FERTILIZER
    local solidNames  = { "UREA", "AMS", "MAP", "DAP", "POTASH",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }

    local registered = 0
    local skipped    = 0

    for _, name in ipairs(liquidNames) do
        if g_fillTypeManager:getFillTypeByName(name) then
            local customRate   = baseRates[name] and baseRates[name].value or liqBase
            local customLPS    = customRate / 36000   -- exact: LPS = target_L_ha / 36000
            local groundType   = (name == "LIQUIDLIME") and limeGroundType or liquidGroundType
            local displayType  = (name == "LIQUIDLIME") and "LIME"        or "FERTILIZER"
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

    SoilLogger.info(
        "[OK] Custom spray types registered: %d types (direct LPS: vanilla ref liq=%.5f dry=%.5f, %d skipped)",
        registered, liquidLPS, solidLPS, skipped
    )
    SoilLogger.info("     Enable SoilDebug to see per-type LPS and rate values")
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

    -- Build remap: customFillTypeIndex → vanillaFillTypeIndex
    local remap = {}
    if fertIdx then
        for _, name in ipairs({ "UREA", "AMS", "MAP", "DAP", "POTASH",
                                 "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then remap[idx] = fertIdx end
        end
    end
    if liqIdx then
        for _, name in ipairs({ "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                                 "INSECTICIDE", "FUNGICIDE",
                                 "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }) do
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
    local solidNames  = { "UREA", "AMS", "MAP", "DAP", "POTASH",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }
    -- Liquid custom types visually match LIQUIDFERTILIZER spraying
    local liquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                          "INSECTICIDE", "FUNGICIDE",
                          "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }

    -- Shared helper: walk a vehicle's sprayType entries and inject our names
    local function patchVehicleSprayTypes(vehicle)
        local spec = vehicle.spec_sprayer
        if not spec or not spec.sprayTypes then return end

        for _, st in ipairs(spec.sprayTypes) do
            if st.fillTypes then
                local hasFert    = false
                local hasLiqFert = false

                -- Check what vanilla base types this sprayType slot already covers
                for _, name in ipairs(st.fillTypes) do
                    local upper = string.upper(name)
                    if upper == "FERTILIZER"        then hasFert    = true end
                    if upper == "LIQUIDFERTILIZER"  then hasLiqFert = true end
                end

                -- Build a lookup of names already present to avoid duplicates
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

    local liqST = g_sprayTypeManager:getSprayTypeByName("LIQUIDFERTILIZER")
    local dryST = g_sprayTypeManager:getSprayTypeByName("FERTILIZER")

    if not liqST and not dryST then
        SoilLogger.warning("DensityMap spray hook: vanilla spray types not found - skipping")
        return false
    end

    local liqIdx = liqST and liqST.index
    local dryIdx = dryST and dryST.index

    -- Build remap: customSprayTypeIndex → vanillaSprayTypeIndex
    local liquidNames = { "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                          "INSECTICIDE", "FUNGICIDE",
                          "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH" }
    local solidNames  = { "UREA", "AMS", "MAP", "DAP", "POTASH",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }

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

    if not next(remap) then
        SoilLogger.warning("DensityMap spray hook: no custom spray types found after registration - skipping")
        return false
    end

    local count = 0
    for _ in pairs(remap) do count = count + 1 end

    -- Append to onStartWorkAreaProcessing (event listener — dynamic lookup, reaches all vehicles).
    -- After the original resolves wap.sprayType = getSprayTypeIndexByFillTypeIndex(fillType),
    -- remap any custom index to the vanilla equivalent so processSprayerArea passes a valid
    -- C++ index to FSDensityMapUtil.updateSprayArea.
    local original = Sprayer.onStartWorkAreaProcessing
    Sprayer.onStartWorkAreaProcessing = Utils.prependedFunction(
        original,
        function(sprayerSelf, dt)
            local spec = sprayerSelf.spec_sprayer
            local wap  = spec and spec.workAreaParameters
            if not wap then return end

            -- If sprayType is nil (vehicle loaded before our custom types were registered),
            -- try to resolve it now from sprayFillType so the remap below can fire.
            -- MUST run as prependedFunction (before vanilla + processSprayerArea) so that
            -- wap.sprayType is valid when processSprayerArea calls getSprayerUsage.
            -- A nil sprayType causes lps=nil → usage=0 → tank never depletes for solid types.
            if not wap.sprayType and wap.sprayFillType and wap.sprayFillType > 0 then
                wap.sprayType = g_sprayTypeManager:getSprayTypeIndexByFillTypeIndex(wap.sprayFillType)
            end

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

    SoilLogger.info("[OK] DensityMap spray hook installed on onStartWorkAreaProcessing — %d custom spray types remapped to vanilla for C++ density map call", count)
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

            if combineSelf.isServer
                and g_SoilFertilityManager
                and g_SoilFertilityManager.soilSystem
                and g_SoilFertilityManager.settings.enabled
                and g_SoilFertilityManager.settings.nutrientCycles
                and inputFruitType and inputFruitType > 0
                and liters and liters > 0
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
                    if not fieldId or fieldId <= 0 then
                        SoilLogger.debug("Harvest hook: skipped (no field at pos x=%.1f z=%.1f)", x, z)
                        return
                    end

                    detectedFieldId = fieldId
                    SoilLogger.debug("Harvest hook: Field %d, Crop %d, area=%.1fm2 (yield modifier applied via hopper hook)",
                        fieldId, inputFruitType, area)
                end)

                if not ok then
                    SoilLogger.error("Harvest hook (field detection) failed: %s", tostring(errMsg))
                end
            else
                SoilLogger.debug("Harvest hook: skipped (not server or manager/settings not ready or invalid args)")
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
    if not Combine or type(Combine.addFillUnitFillLevel) ~= "function" then
        SoilLogger.warning("Yield modifier hook: Combine.addFillUnitFillLevel not available — yield reduction skipped")
        return false
    end

    local original = Combine.addFillUnitFillLevel

    -- Factory so the same modifier logic wraps any chainFn — used for both the
    -- class-level hook and per-vehicle instance patching (issue #284: wrapping
    -- preserves other mods' specialization chains such as RealisticHarvesting).
    local function makeYieldWrapper(chainFn)
        return function(combineSelf, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, extraAttributes)
            -- Only apply modifier on the server when filling the hopper (delta > 0)
            -- and all SF systems are ready.
            local modifiedDelta = fillLevelDelta
            if combineSelf.isServer
                and fillLevelDelta and fillLevelDelta > 0
                and fillTypeIndex
                and g_SoilFertilityManager
                and g_SoilFertilityManager.soilSystem
                and g_SoilFertilityManager.settings.enabled
                and g_SoilFertilityManager.settings.nutrientCycles
            then
                local ok, errMsg = pcall(function()
                    -- Resolve the fruit type from the fill type so computeYieldModifier
                    -- receives the fruitType index it expects (not the fillType index).
                    local fruitType = nil
                    if g_fruitTypeManager then
                        local ft = g_fruitTypeManager:getFruitTypeByFillTypeIndex(fillTypeIndex)
                        if ft then fruitType = ft.index end
                    end

                    if not fruitType or fruitType <= 0 then return end  -- not a harvestable fruit

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
                    if not fieldId or fieldId <= 0 then return end

                    local yieldModifier = g_SoilFertilityManager.soilSystem:computeYieldModifier(fieldId, fruitType)
                    if yieldModifier ~= 1.0 then
                        modifiedDelta = fillLevelDelta * yieldModifier
                        SoilLogger.debug("Yield modifier hook: Field %d Fruit %d modifier=%.3f (%.1fL → %.1fL)",
                            fieldId, fruitType, yieldModifier, fillLevelDelta, modifiedDelta)
                    end
                end)
                if not ok then
                    SoilLogger.error("Yield modifier hook failed: %s", tostring(errMsg))
                    modifiedDelta = fillLevelDelta  -- safe fallback: no penalty
                end
            end

            return chainFn(combineSelf, fillUnitIndex, modifiedDelta, fillTypeIndex, toolType, fillPositionData, extraAttributes)
        end
    end

    Combine.addFillUnitFillLevel = makeYieldWrapper(original)
    self:register(Combine, "addFillUnitFillLevel", original, "Combine.addFillUnitFillLevel")

    -- Wrap existing combine instances (not replace) to preserve other mods'
    -- specialization chains (e.g. RealisticHarvesting's addFillUnitFillLevel overwrite).
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

    SoilLogger.info("[OK] Yield modifier hook installed (Combine.addFillUnitFillLevel) — %d existing combines patched", patched)
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

            if self.getIsTurnedOn ~= nil and not self:getIsTurnedOn() then return end

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

            if not liters or liters <= 0 then return end
            if not sprayFillLevel or sprayFillLevel <= 0 then return end
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

                -- PHASE 5: route through shared MapDataGrid-backed cache
                local fieldId = hookMgrRef:getFieldIdAtWorldPosition(x, z)

                -- Fallback: try the midpoints of work areas on attached implements
                if not fieldId or fieldId <= 0 then
                    local attachedImpls = self.spec_attacherJoints and self.spec_attacherJoints.attachedImplements
                    if attachedImpls then
                        for _, impl in ipairs(attachedImpls) do
                            local obj = impl and impl.object
                            if obj then
                                -- Try implement rootNode first
                                local ix, _, iz = getWorldTranslation(obj.rootNode)
                                if ix then fieldId = hookMgrRef:getFieldIdAtWorldPosition(ix, iz) end
                                -- Then try each work area start point
                                if (not fieldId or fieldId <= 0) and obj.spec_workArea and obj.spec_workArea.workAreas then
                                    for _, wa in ipairs(obj.spec_workArea.workAreas) do
                                        if wa.start then
                                            local sx, _, sz = getWorldTranslation(wa.start)
                                            if sx then fieldId = hookMgrRef:getFieldIdAtWorldPosition(sx, sz) end
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

                -- Apply rate multiplier
                local rm = g_SoilFertilityManager.sprayerRateManager
                local rateMultiplier = (rm ~= nil) and rm:getMultiplier(self.id) or 1.0
                local effectiveLiters = liters * rateMultiplier

                -- Section Control: scale nutrient credit when outer boom sections are off.
                -- wap.usage already reflects section shutoff (VariableWorkWidth.getIsWorkAreaActive
                -- gates each work area on section.isActive). We apply the fraction here so that
                -- effectiveLiters correctly represents the nutrient dose for the active portion
                -- of the field, especially when rateMultiplier != 1.0.
                local coverageFraction = 1.0
                if SoilUtils and SoilUtils.getSectionCoverageFraction then
                    coverageFraction = SoilUtils.getSectionCoverageFraction(self)
                    if coverageFraction < 1.0 then
                        effectiveLiters = effectiveLiters * coverageFraction
                        SoilLogger.debug("SectionControl: %.0f%% boom active → liters scaled to %.4fL",
                            coverageFraction * 100, effectiveLiters)
                    end
                end

                -- ── Coverage tracking (raw liters, before rateMultiplier) ─────────
                -- Must run for ALL product types (fertilizer AND crop protection).
                if g_SoilFertilityManager.soilSystem then
                    g_SoilFertilityManager.soilSystem:trackSprayerCoverage(fieldId, liters, fillType.name)
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
                    -- Collect active sections
                    local activeSections = {}
                    for _, section in ipairs(vww.sections) do
                        if section.isActive or section.isCenter then
                            table.insert(activeSections, section)
                        end
                    end

                    if #activeSections > 0 then
                        local litersPerSection = effectiveLiters / #activeSections
                        for _, section in ipairs(activeSections) do
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
                            applySingle(sectionFieldId, litersPerSection, sx, sz)
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
               not g_SoilFertilityManager.settings.enabled or
               not g_SoilFertilityManager.settings.plowingBonus then
                return
            end
            if not cultivatorSelf.isServer then return end

            -- Confirm cultivator work area actually changed terrain this tick
            local spec = cultivatorSelf.spec_cultivator
            if not spec or not spec.workAreaParameters then return end
            local statsArea = spec.workAreaParameters.lastStatsArea
            if not statsArea or statsArea <= 0 then return end

            local isPlowSpec = cultivatorSelf.spec_plow ~= nil or cultivatorSelf.spec_subsoiler ~= nil
            SoilLogger.debug("[PlowHook] onEndWorkAreaProcessing fired — isPlow=%s area=%.1f",
                tostring(isPlowSpec), statsArea)

            local x, _, z = getWorldTranslation(cultivatorSelf.rootNode)
            local success, errorMsg = pcall(function()
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                SoilLogger.debug("[PlowHook] pos=(%.1f,%.1f) farmlandId=%s isPlow=%s",
                    x, z, tostring(farmlandId), tostring(isPlowSpec))
                if farmlandId and farmlandId > 0 then
                    local isPlowingTool = isPlowSpec
                    -- Some cultivators work deep enough to act as plows
                    if not isPlowingTool and spec.workingDepth and
                       spec.workingDepth > SoilConstants.PLOWING.MIN_DEPTH_FOR_PLOWING then
                        isPlowingTool = true
                    end

                    if isPlowingTool then
                        g_SoilFertilityManager.soilSystem:onPlowing(farmlandId)
                    else
                        g_SoilFertilityManager.soilSystem:onCultivation(farmlandId)
                    end

                    -- Compaction: check if subsoiler or heavy vehicle
                    if g_SoilFertilityManager.settings.compactionEnabled and SoilConstants.COMPACTION then
                        local cp = SoilConstants.COMPACTION
                        local isSubsoiler = cultivatorSelf.spec_cultivator and
                                           cultivatorSelf.spec_cultivator.isSubsoiler
                        if isSubsoiler then
                            SoilLogger.debug("Compaction: subsoiler pass on farmland=%d veh=%d pos=(%.1f,%.1f)",
                                farmlandId, cultivatorSelf.id or 0, x, z)
                            g_SoilFertilityManager.soilSystem:onSubsoilerPass(farmlandId, x, z)
                        else
                            local rootVehicle = cultivatorSelf.rootVehicle or cultivatorSelf
                            local okM, totalMass = pcall(function()
                                return rootVehicle:getTotalMass(false)
                            end)
                            if okM and totalMass then
                                SoilLogger.debug(
                                    "Compaction check: farmland=%d veh=%d  pos=(%.1f,%.1f)  mass=%.1ft  threshold=%.1ft  heavy=%s",
                                    farmlandId, cultivatorSelf.id or 0, x, z,
                                    totalMass, cp.HEAVY_VEHICLE_THRESHOLD_T,
                                    tostring(totalMass >= cp.HEAVY_VEHICLE_THRESHOLD_T))
                                if totalMass >= cp.HEAVY_VEHICLE_THRESHOLD_T then
                                    g_SoilFertilityManager.soilSystem:onCompaction(farmlandId, x, z)
                                end
                            end
                        end
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
               not g_SoilFertilityManager.settings.enabled or
               not g_SoilFertilityManager.settings.plowingBonus then
                return
            end
            if not plowSelf.isServer then return end

            -- Confirm plow work area actually changed terrain this tick
            local spec = plowSelf.spec_plow
            if not spec or not spec.workAreaParameters then return end
            local statsArea = spec.workAreaParameters.lastStatsArea
            if not statsArea or statsArea <= 0 then return end

            SoilLogger.debug("[DedicatedPlowHook] onEndWorkAreaProcessing fired — area=%.1f", statsArea)

            local x, _, z = getWorldTranslation(plowSelf.rootNode)
            local success, errorMsg = pcall(function()
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                SoilLogger.debug("[DedicatedPlowHook] pos=(%.1f,%.1f) farmlandId=%s",
                    x, z, tostring(farmlandId))
                if farmlandId and farmlandId > 0 then
                    g_SoilFertilityManager.soilSystem:onPlowing(farmlandId)

                    -- Dedicated plows are always heavy equipment
                    if g_SoilFertilityManager.settings.compactionEnabled then
                        local rootVehicle = plowSelf.rootVehicle or plowSelf
                        local okM, totalMass = pcall(function()
                            return rootVehicle:getTotalMass(false)
                        end)
                        local cp = SoilConstants.COMPACTION
                        if cp and okM and totalMass then
                            SoilLogger.debug(
                                "Compaction check (plow): farmland=%d veh=%d  pos=(%.1f,%.1f)  mass=%.1ft  threshold=%.1ft  heavy=%s",
                                farmlandId, plowSelf.id or 0, x, z,
                                totalMass, cp.HEAVY_VEHICLE_THRESHOLD_T,
                                tostring(totalMass >= cp.HEAVY_VEHICLE_THRESHOLD_T))
                            if totalMass >= cp.HEAVY_VEHICLE_THRESHOLD_T then
                                g_SoilFertilityManager.soilSystem:onCompaction(farmlandId, x, z)
                            end
                        end
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
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled or
               not g_SoilFertilityManager.settings.weedPressure then
                return
            end
            if not weederSelf.isServer then return end

            -- Confirm weeder actually changed terrain this tick
            local spec = weederSelf.spec_weeder
            if not spec or not spec.workAreaParameters then return end
            local statsArea = spec.workAreaParameters.lastStatsArea
            if not statsArea or statsArea <= 0 then return end

            local x, _, z = getWorldTranslation(weederSelf.rootNode)
            local success, errorMsg = pcall(function()
                local farmlandId = hookMgrRef:getFieldIdAtWorldPosition(x, z)
                SoilLogger.debug("[WeederHook] pos=(%.1f,%.1f) farmlandId=%s", x, z, tostring(farmlandId))
                if farmlandId and farmlandId > 0 then
                    g_SoilFertilityManager.soilSystem:onCultivation(farmlandId)
                    SoilLogger.debug("[WeederHook] Field %d: mechanical weed removal applied", farmlandId)
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
    -- RidgeTiller may not be present on all maps/mods — fail gracefully
    if not RidgeTiller or type(RidgeTiller.processRidgeTillerArea) ~= "function" then
        SoilLogger.warning("[RidgeTillerHook] RidgeTiller.processRidgeTillerArea not available — strip-till integration skipped")
        return false
    end

    local original = RidgeTiller.processRidgeTillerArea
    RidgeTiller.processRidgeTillerArea = Utils.appendedFunction(
        original,
        function(ridgeSelf, workArea, dt)
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end

            if not workArea or type(workArea) ~= "table" then return end
            if not workArea.start or not workArea.width or not workArea.height then return end

            local sx, _, sz = getWorldTranslation(workArea.start)
            local wx, _, wz = getWorldTranslation(workArea.width)
            local hx, _, hz = getWorldTranslation(workArea.height)
            local centerX = (sx + wx + hx) / 3
            local centerZ = (sz + wz + hz) / 3

            local success, errorMsg = pcall(function()
                -- PHASE 5: use shared MapDataGrid-backed cache (self = HookManager upvalue)
                local fieldId = self:getFieldIdAtWorldPosition(centerX, centerZ)
                if not fieldId or fieldId <= 0 then return end

                SoilLogger.debug("[RidgeTillerHook] Field %d at (%.1f, %.1f)", fieldId, centerX, centerZ)
                g_SoilFertilityManager.soilSystem:onStripTill(fieldId)
            end)

            if not success then
                SoilLogger.error("[RidgeTillerHook] failed: %s", tostring(errorMsg))
            end
        end
    )

    self:register(RidgeTiller, "processRidgeTillerArea", original, "RidgeTiller.processRidgeTillerArea")
    SoilLogger.info("[OK] RidgeTiller hook installed — strip-till (RIDGEFORMER) events now tracked")
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

                g_SoilFertilityManager.soilSystem:onSowing(fieldId)
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

    local solidNames         = {"UREA", "AN", "AMS", "MAP", "DAP", "POTASH",
                                 "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM"}
    local liquidNames        = {"UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME", "INSECTICIDE", "FUNGICIDE",
                                "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH"}
    -- Organic dry types also work in manure spreaders (MANURE fill-unit base)
    local manureCompatNames  = {"BIOSOLIDS", "CHICKEN_MANURE"}

    local original = FillUnit.onPostLoad
    FillUnit.onPostLoad = Utils.prependedFunction(original, function(vehicleSelf)
        local fm = g_fillTypeManager
        if not fm then return end
        local fertIdx    = fm:getFillTypeIndexByName("FERTILIZER")
        local liqFertIdx = fm:getFillTypeIndexByName("LIQUIDFERTILIZER")
        local manureIdx  = fm:getFillTypeIndexByName("MANURE")
        local spec = vehicleSelf.spec_fillUnit
        if not spec or not spec.fillUnits then return end
        for _, fu in pairs(spec.fillUnits) do
            if fu.supportedFillTypes then
                local addSolid  = fertIdx    and fu.supportedFillTypes[fertIdx]
                local addLiquid = liqFertIdx and fu.supportedFillTypes[liqFertIdx]
                local addManure = manureIdx  and fu.supportedFillTypes[manureIdx]
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

    local solidNames  = {"UREA", "AN", "AMS", "MAP", "DAP", "POTASH",
                          "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM"}
    local liquidNames = {"UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME", "INSECTICIDE", "FUNGICIDE",
                         "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH"}
    -- These organic dry types also work in manure spreaders (MANURE fill-unit base).
    local manureCompatNames = {"BIOSOLIDS", "CHICKEN_MANURE"}

    local solidIndices       = {}
    local liquidIndices      = {}
    local manureCompatIndices = {}
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
    local customToBase  = {}
    local customToManure = {}  -- organic dry types that also fit in MANURE-based fill units
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

    -- Hook getFillUnitSupportsFillType so Dischargeable:dischargeToObject (vehicle-to-vehicle
    -- auger wagon → spreader, tanker → sprayer, etc.) passes the fill type check for our
    -- custom types. Patching supportedFillTypes covers the table lookup, but some FS25
    -- versions / specializations call this method via a C++ fast-path that bypasses the Lua
    -- table. Wrapping the method directly is the belt-and-suspenders fix.
    --
    -- Logic: if the vehicle supports the corresponding vanilla base type (FERTILIZER or
    -- LIQUIDFERTILIZER or MANURE), it also supports the matching custom type.
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
        "UREA", "AN", "AMS", "MAP", "DAP", "POTASH",
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
        UREA = 1.65, AN = 1.50, AMS = 1.40, MAP = 1.95, DAP = 1.75, POTASH = 1.80,
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

            local mapMult = 1.0
            if g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager then
                mapMult = g_SoilFertilityManager.sprayerRateManager:getMultiplier(sprayerSelf.id or 0)
            end

            local usage = fillScale * mapMult * lps * actualSpeedKmh * workWidth * dt * 0.001

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
        AN       = { "LIME", "FERTILIZER" },            -- AN is also white granular
        AMS      = { "FERTILIZER", "LIME" },            -- AMS is off-white/light grey granular
        MAP      = { "FERTILIZER", "LIME" },            -- MAP is off-white/light brown granular
        DAP      = { "FERTILIZER", "LIME" },            -- DAP is off-white/grey-brown granular
        POTASH   = { "FERTILIZER", "LIME" },            -- Potassium chloride — pinkish but granular
        GYPSUM   = { "LIME", "FERTILIZER" },            -- Gypsum is bright white powder → LIME first

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

    -- Build remap: custom fill type index → vanilla fill type index (cosmetic only)
    local remap = {}
    if fertIdx then
        for _, name in ipairs({ "UREA", "AMS", "MAP", "DAP", "POTASH",
                                 "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE", "GYPSUM" }) do
            local idx = fm:getFillTypeIndexByName(name)
            if idx then remap[idx] = fertIdx end
        end
    end
    if liqFertIdx then
        for _, name in ipairs({ "UAN32", "UAN28", "ANHYDROUS", "STARTER", "LIQUIDLIME",
                                 "INSECTICIDE", "FUNGICIDE",
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
    end

    local function stopSprayerEffects(vehicle)
        local spec = vehicle.spec_sprayer
        if not spec then return end
        g_effectManager:stopEffects(spec.effects)
        for _, st in ipairs(spec.sprayTypes or {}) do
            g_effectManager:stopEffects(st.effects)
            g_animationManager:stopAnimations(st.animationNodes)
            g_soundManager:stopSamples(st.samples and st.samples.spray or {})
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

            -- If fill type changed away from custom, stop our managed effects and reset
            local lastFT = spec._soilManagedFillType
            if lastFT and lastFT ~= fillType then
                stopSprayerEffects(sprayerSelf)
                spec._soilManagedFillType = nil
                spec._soilEffectsActive   = nil
            end

            if not vanillaFillType then return end  -- not our custom type, nothing to manage

            local effectsVisible = sprayerSelf:getAreEffectsVisible()

            -- Only act on state change to avoid per-tick overhead
            if effectsVisible == spec._soilEffectsActive then return end

            spec._soilEffectsActive   = effectsVisible
            spec._soilManagedFillType = fillType

            if effectsVisible then
                startSprayerEffects(sprayerSelf, vanillaFillType)
                SoilLogger.debug("SprayerVisual: started effects (fillType=%d → vanilla=%d)", fillType, vanillaFillType)
            else
                stopSprayerEffects(sprayerSelf)
                SoilLogger.debug("SprayerVisual: stopped effects (fillType=%d)", fillType)
            end
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
    if not FSBaseMission or type(FSBaseMission.onConnectionFinished) ~= "function" then
        SoilLogger.warning("Could not install client join hook - FSBaseMission.onConnectionFinished not available")
        return false
    end

    local original = FSBaseMission.onConnectionFinished
    FSBaseMission.onConnectionFinished = Utils.appendedFunction(
        original,
        function(missionSelf, connection)
            if not g_SoilFertilityManager or
               not g_SoilFertilityManager.soilSystem or
               not g_SoilFertilityManager.settings.enabled then
                return
            end

            -- Server only - send data to the connecting client
            if g_server ~= nil and connection then
                local success, errorMsg = pcall(function()
                    g_SoilFertilityManager.soilSystem:onClientJoined(connection)
                end)

                if not success then
                    SoilLogger.error("Client join hook failed: %s", tostring(errorMsg))
                end
            end
        end
    )
    self:register(FSBaseMission, "onConnectionFinished", original, "FSBaseMission.onConnectionFinished (Client Join)")
    SoilLogger.info("[OK] Client join hook installed successfully")
    return true
end