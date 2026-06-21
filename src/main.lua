-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Entry Point
-- =========================================================
-- Loads all modules in dependency order, hooks FS25 mission
-- lifecycle events, and registers console commands.
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE:
-- All rights reserved. Unauthorized redistribution, copying,
-- or claiming this code as your own is strictly prohibited.
-- =========================================================

local modDirectory = g_currentModDirectory
local modName = g_currentModName

-- Menu icon global (resolved by XML imageFilename="g_SFIconMenu" via GuiOverlay hook below)
g_SFIconMenu = Utils.getFilename("textures/ui/menuIcon.dds", g_currentModDirectory)

-- Resolve g_SFIconMenu in XML imageFilename attributes (EmployeeManager/MDM pattern)
local SF_ICON_GLOBALS = { g_SFIconMenu = true }
local function sfResolveFilename(self, superFunc)
    local filename = superFunc(self)
    if SF_ICON_GLOBALS[filename] then
        return _G[filename]
    end
    return filename
end
GuiOverlay.resolveFilename = Utils.overwrittenFunction(GuiOverlay.resolveFilename, sfResolveFilename)

-- Source all required files (order matters: dependencies first)
-- 1. Utilities and config (no dependencies)
source(modDirectory .. "src/utils/Logger.lua")
source(modDirectory .. "src/utils/AsyncRetryHandler.lua")
source(modDirectory .. "src/utils/SoilUtils.lua")
source(modDirectory .. "src/config/Constants.lua")
source(modDirectory .. "src/config/SettingsSchema.lua")
source(modDirectory .. "src/SoilCompactionModel.lua")

-- 2. Specializations (must load before core systems so vehicleType registration fires)
source(modDirectory .. "src/specializations/SFNozzleEffects.lua")
SFNozzleEffects.init(modDirectory)

-- 3. Core systems
source(modDirectory .. "src/hooks/HookManager.lua")
source(modDirectory .. "src/ui/SoilLayerSystem.lua")
source(modDirectory .. "src/maps/SoilBundledMaps.lua")
source(modDirectory .. "src/SprayerRateManager.lua")
source(modDirectory .. "src/SoilSensorManager.lua")
-- FieldSentry backend gate (#651): must load before SoilFertilitySystem so its
-- daily loop can consult FieldSentry_API. Backend only — no UI, no equation changes.
source(modDirectory .. "src/FieldSentry.lua")
source(modDirectory .. "src/SoilFertilitySystem.lua")

-- 3. Settings
source(modDirectory .. "src/settings/SettingsManager.lua")
source(modDirectory .. "src/settings/Settings.lua")
source(modDirectory .. "src/settings/SoilSettingsGUI.lua")

-- 4. UI + Manager (Manager must come after Settings so its new() dependencies are defined)
source(modDirectory .. "src/utils/UIHelper.lua")
source(modDirectory .. "src/settings/SoilSettingsUI.lua")
source(modDirectory .. "src/ui/SoilHUD.lua")
source(modDirectory .. "src/ui/SoilVariableRatePanel.lua")
source(modDirectory .. "src/ui/SoilSmartSensorPanel.lua")
source(modDirectory .. "src/ui/SoilSprayerInfoPanel.lua")
source(modDirectory .. "src/ui/SoilHarvesterPanel.lua")
source(modDirectory .. "src/ui/SoilMapOverlay.lua")
source(modDirectory .. "src/ui/SoilMinimapLayer.lua")
source(modDirectory .. "src/hooks/SoilMapHooks.lua")
source(modDirectory .. "src/ui/SoilPDAScreen.lua")
source(modDirectory .. "src/ui/SoilFieldDetailDialog.lua")
source(modDirectory .. "src/ui/SoilTreatmentDialog.lua")
source(modDirectory .. "src/ui/SoilVersionDialog.lua")
source(modDirectory .. "src/ui/SoilHelpDialog.lua")
source(modDirectory .. "src/ui/SoilGuideDialog.lua")
source(modDirectory .. "src/ui/SoilOverlayHelpDialog.lua")
source(modDirectory .. "src/ui/SoilTuningPanel.lua")
source(modDirectory .. "src/ui/SoilSettingsPanel.lua")
source(modDirectory .. "src/SoilFertilityManager.lua")

-- 5. Network
source(modDirectory .. "src/network/NetworkEvents.lua")

-- 6. Integrations
source(modDirectory .. "src/integrations/SectionControlIntegration.lua")
source(modDirectory .. "src/integrations/PrecisionFarmingBridge.lua")

-- Register our custom density map height types with the DMHM mod file list.
-- DensityMapHeightManager:loadMapData iterates modDensityHeightMapTypeFilenames and
-- calls loadDensityMapHeightTypes for each, which registers C++ height types.  This
-- must happen before loadMapData runs (i.e. at module load time, not in a hook).
-- When C++ handles the registration, physical pile height and tipping work correctly
-- without any Lua injection.  The Lua injection in loadedMission() remains as a
-- fallback and is a no-op if C++ already populated fillTypeIndexToHeightType.
do
    local dmhm = g_densityMapHeightManager
    if dmhm ~= nil then
        if dmhm.modDensityHeightMapTypeFilenames == nil then
            dmhm.modDensityHeightMapTypeFilenames = {}
        end
        local xmlPath = Utils.getFilename("xml/densityMapHeightTypes.xml", modDirectory)
        table.insert(dmhm.modDensityHeightMapTypeFilenames, xmlPath)
        SoilLogger.info("[HEIGHT] Registered xml/densityMapHeightTypes.xml with DMHM mod file list")
    else
        SoilLogger.warning("[HEIGHT] g_densityMapHeightManager not available at load time — height types will rely on Lua fallback")
    end
end

-- Register helpline icon atlas as early as possible (at module load time).
-- g_overlayManager exists from game startup, so this works before any mission loads.
-- The loadedMission hook below retries if the manager wasn't available yet.
local _helplineAtlasRegistered = false
if g_overlayManager then
    g_overlayManager:addTextureConfigFile(
        modDirectory .. "images/helplineSoilFertilizer.xml",
        "helplineSoilFertilizer"
    )
    _helplineAtlasRegistered = true
    SoilLogger.info("Helpline icon atlas registered (early)")
else
    SoilLogger.warning("g_overlayManager not available at load time — will retry in loadedMission")
end

-- Globals
local sfm = nil

-- Declared before unload() so it captures these as upvalues (not globals).
-- Previously these lived below unload(), so unload() resolved them as globals
-- and the InputHelpDisplay.draw restore never ran.
local _sprayerF1HookInstalled = false
local _inputHelpDisplayOrigDraw = nil
-- getCanTipToGround is hooked once per game session (see loadedMission);
-- re-wrapping on every savegame load would chain stale closures.
local _canTipHookInstalled = false

-- Helper: check if mod is initialized
local function isEnabled()
    return sfm ~= nil
end

-- Called when mission starts (player enters world, all fields populated)
local function missionStarted(mission)
    if sfm then
        sfm:onMissionStarted()
    end
end

-- Called after mission loaded
local function loadedMission(mission, node)
    if mission.cancelLoading then return end
    if sfm == nil then
        SoilLogger.error("loadedMission: sfm is nil — SoilFertilityManager.new() failed during load(), mod will not function")
        return
    end
    sfm:onMissionLoaded()

    -- TIP ON GROUND FIX: directly inject our solid fill types into the
    -- DensityMapHeightManager Lua tables so they can be tipped to the ground.
    --
    -- Root cause: loadDensityMapHeightTypes() is a C++ native that uses a C++
    -- fill type registry populated only during DensityMapHeightManager.loadMapData
    -- (before mod fill types are available). Calling it later always returns
    -- "invalid fill type 'nil'" for all our types.
    --
    -- Solution: populate the Lua tables directly at loadMission00Finished time,
    -- using the FERTILIZER entry as the structural template. Field values confirmed
    -- from debug pass 2 (2026-05-13): allowsSmoothing, canBeTipped, collisionBaseOffset,
    -- collisionScale, fillToGroundScale, fillTypeIndex, fillTypeName, index,
    -- maxCollisionOffset, maxSurfaceAngle, minCollisionOffset.
    do
        local dmhm = g_densityMapHeightManager
        local ftm  = g_fillTypeManager
        if dmhm and ftm and dmhm.heightTypes and dmhm.fillTypeIndexToHeightType then
            -- Two templates: FERTILIZER (light granular) for mineral types,
            -- MANURE (dark organic) for compost/biosolids/chicken manure/pelletized manure.
            -- Using the wrong template causes black/unlit pile rendering because the
            -- C++ material reference from the shallow copy drives the visual output.
            local tmplFert   = nil
            local tmplManure = nil
            local fertIdx    = ftm:getFillTypeIndexByName("FERTILIZER")
            local manureIdx  = ftm:getFillTypeIndexByName("MANURE")
            if fertIdx  then tmplFert   = dmhm.fillTypeIndexToHeightType[fertIdx]   end
            if manureIdx then tmplManure = dmhm.fillTypeIndexToHeightType[manureIdx] end

            -- Fall back to the other template if one is missing
            local tmpl = tmplFert or tmplManure

            -- Which types use the organic (MANURE) template
            local organicSet = {
                COMPOST = true, BIOSOLIDS = true,
                CHICKEN_MANURE = true, PELLETIZED_MANURE = true,
            }

            if tmpl then
                -- Our 11 solid fill types that need ground-tipping support.
                local solidTypes = {
                    "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA",
                    "GYPSUM", "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE",
                }
                local registered = 0
                for _, typeName in ipairs(solidTypes) do
                    local idx = ftm:getFillTypeIndexByName(typeName)
                    if idx and not dmhm.fillTypeIndexToHeightType[idx] then
                        local nextSlot = dmhm.numHeightTypes + 1
                        -- Shallow-copy the appropriate template so C++ object references
                        -- (density map channel pointer, material, physics layer handle) are
                        -- preserved. Organic types use MANURE to get the correct dark pile
                        -- visual; mineral types use FERTILIZER for the light granular look.
                        local srcTmpl = (organicSet[typeName] and tmplManure) or tmplFert or tmpl
                        local ht = {}
                        for k, v in pairs(srcTmpl) do ht[k] = v end
                        ht.allowsSmoothing  = false
                        ht.canBeTipped      = true
                        ht.fillTypeIndex    = idx
                        ht.fillTypeName     = typeName
                        ht.index            = nextSlot

                        dmhm.fillTypeIndexToHeightType[idx]           = ht
                        if dmhm.fillTypeNameToHeightType then
                            dmhm.fillTypeNameToHeightType[typeName]   = ht
                        end
                        dmhm.heightTypeIndexToFillTypeIndex[nextSlot] = idx
                        dmhm.heightTypes[nextSlot]                    = ht
                        dmhm.numHeightTypes                           = nextSlot
                        registered = registered + 1
                    end
                end
                -- Verify at least one registration worked by checking getMinValidLiterValue.
                local testIdx = ftm:getFillTypeIndexByName("UREA")
                local ok, val = pcall(function() return dmhm:getMinValidLiterValue(testIdx) end)
                SoilLogger.info(string.format(
                    "[TIP FIX] Injected %d solid fill types into DMHM (shallow-copy). " ..
                    "getMinValidLiterValue(UREA)=%s (>0 = success)",
                    registered, tostring(ok and val or "ERROR")
                ))

                -- If C++ registered our types via modDensityHeightMapTypeFilenames (the
                -- preferred path), registered == 0 here and nothing else is needed.
                -- If Lua injection ran as fallback, rebuild the GPU texture array so
                -- the newly injected types get valid textureArrayIndex slots.
                if registered > 0 and g_terrainNode then
                    local ctfl_ok, ctfl_err = pcall(function()
                        ftm:constructTerrainFillLayers(dmhm.heightTypes, g_terrainNode)
                    end)
                    if ctfl_ok then
                        SoilLogger.info("[TIP FIX] constructTerrainFillLayers rebuilt (Lua fallback path)")
                    else
                        SoilLogger.warning("[TIP FIX] constructTerrainFillLayers failed: " .. tostring(ctfl_err))
                    end
                end

                -- Belt-and-suspenders: also hook getCanTipToGround at Lua level so the
                -- discharge eligibility check passes even if C++ hasn't read our table.
                -- Installed once per game session and resolving the manager dynamically:
                -- loadedMission re-runs on every savegame load, and re-wrapping here would
                -- chain wrappers and capture the previous mission's (stale) manager.
                if registered > 0 and not _canTipHookInstalled and DensityMapHeightUtil and
                   type(DensityMapHeightUtil.getCanTipToGround) == "function" then
                    local _origGetCan = DensityMapHeightUtil.getCanTipToGround
                    DensityMapHeightUtil.getCanTipToGround = function(fillTypeIndex)
                        local mgr = g_densityMapHeightManager
                        if mgr and mgr.fillTypeIndexToHeightType and
                           mgr.fillTypeIndexToHeightType[fillTypeIndex] then
                            return true
                        end
                        return _origGetCan(fillTypeIndex)
                    end
                    _canTipHookInstalled = true
                    SoilLogger.info("[TIP FIX] DensityMapHeightUtil.getCanTipToGround hooked")
                end
            else
                SoilLogger.warning("[TIP FIX] FERTILIZER template not found in DMHM — tip injection skipped")
            end
        else
            SoilLogger.warning("[TIP FIX] g_densityMapHeightManager not available at loadedMission — tip injection skipped")
        end
    end

    -- Fallback: register atlas if it was skipped at load time (g_overlayManager was nil then).
    if not _helplineAtlasRegistered then
        if g_overlayManager then
            g_overlayManager:addTextureConfigFile(
                modDirectory .. "images/helplineSoilFertilizer.xml",
                "helplineSoilFertilizer"
            )
            _helplineAtlasRegistered = true
            SoilLogger.info("Helpline icon atlas registered (fallback at loadedMission)")
        else
            SoilLogger.warning("g_overlayManager still nil at loadedMission — helpline icons will be missing")
        end
    end

    -- $modDir is not resolved in the fillTypes.xml loading context, so we patch
    -- the HUD icon filenames AND overlay handles directly via Lua.
    --
    -- WHY BOTH FIELDS:
    --   ft.hudOverlayFilename  – the path string stored on the fill type object.
    --   ft.hudOverlay          – the pre-loaded overlay handle that FS25's native
    --                            fill-level HUD (bottom-right) actually renders from.
    --
    -- FS25 creates ft.hudOverlay at mission load from the <image hud="..."/> entry
    -- in fillTypes.xml.  All our solid types share the same fallback path
    -- ($dataS/menu/hud/fillTypes/hud_fill_fertilizer.png), so every solid type
    -- displayed the same generic icon regardless of which product was loaded.
    -- Patching only hudOverlayFilename had no visible effect on the native HUD.
    --
    -- Fix: after updating the filename, also replace the overlay handle via
    -- createImageOverlay() (the same API used by SoilHUD.lua for its own overlays).
    -- The old handle is freed with delete() to avoid GPU resource leaks.
    if g_fillTypeManager then
        local hudDir = modDirectory .. "textures/hud/fillTypes/"
        local icons = {
            -- Liquid nitrogen sources
            UAN32          = "hud_fill_UAN32.dds",
            UAN28          = "hud_fill_UAN28.dds",
            ANHYDROUS      = "hud_fill_anhydrous.dds",
            STARTER        = "hud_fill_Starter.dds",
            -- Solid granular sources
            UREA           = "hud_fill_UREA.dds",
            AN             = "hud_fill_AN.dds",
            AMS            = "hud_fill_AMS.dds",
            MAP            = "hud_fill_map.dds",
            DAP            = "hud_fill_dap.dds",
            POTASH         = "hud_fill_potash.dds",
            -- Liquid variants (reuse solid counterpart icon)
            LIQUID_UREA    = "hud_fill_UREA.dds",
            LIQUID_AMS     = "hud_fill_AMS.dds",
            LIQUID_MAP     = "hud_fill_map.dds",
            LIQUID_DAP     = "hud_fill_dap.dds",
            LIQUID_POTASH  = "hud_fill_potash.dds",
            -- Crop protection
            INSECTICIDE    = "hud_fill_insecticide.dds",
            FUNGICIDE      = "hud_fill_fungicide.dds",
            -- Organic / soil amendments
            GYPSUM         = "hud_fill_gypsum.dds",
            COMPOST        = "hud_fill_compost.dds",
            BIOSOLIDS      = "hud_fill_biosolids.dds",
            CHICKEN_MANURE = "hud_fill_chickenlitter.dds",
            PELLETIZED_MANURE = "hud_fill_pelletizedmanure.dds",
            LIQUIDLIME     = "hud_fill_liquidlime.dds",
        }
        local patched = 0
        local failed  = 0
        for name, file in pairs(icons) do
            local ft = g_fillTypeManager:getFillTypeByName(name)
            if ft then
                local path = hudDir .. file
                -- Update the filename string (read by some third-party mod integrations)
                ft.hudOverlayFilename = path
                -- Replace the overlay handle so the native FS25 fill-level HUD
                -- renders the correct icon instead of the generic fallback.
                if createImageOverlay ~= nil then
                    if ft.hudOverlay ~= nil then
                        delete(ft.hudOverlay)
                    end
                    ft.hudOverlay = createImageOverlay(path)
                    patched = patched + 1
                else
                    failed = failed + 1
                end
            end
        end
        if failed > 0 then
            SoilLogger.warning("HUD icon patch: createImageOverlay unavailable — %d icons not updated (filename only)", failed)
        else
            SoilLogger.info("Custom HUD icons patched for %d mod fill types (overlay + filename)", patched)
        end
    end

    -- Multiplayer client: request full state from server.
    -- SoilRequestFullSyncEvent asks the server for all settings + field data.
    -- The retry handler (AsyncRetryHandler) makes up to 3 attempts with delay
    -- in case the server-side soil system hasn't finished initializing yet.
    if g_client ~= nil and g_server == nil and SoilNetworkEvents_RequestFullSync then
        SoilNetworkEvents_RequestFullSync()
    end
end

-- Load handler
local function load(mission)
    local isDedicatedServer = mission:getIsServer() and not mission:getIsClient()
    local disableGUI = isDedicatedServer or not mission:getIsClient()

    if disableGUI then
        SoilLogger.info("Server/console-only mode - GUI disabled")
    end

    if sfm == nil then
        SoilLogger.info("Initializing...")

        -- Log multiplayer status
        if mission.missionDynamicInfo and mission.missionDynamicInfo.isMultiplayer then
            if mission:getIsServer() then
                SoilLogger.info("Running as MULTIPLAYER SERVER")
            else
                SoilLogger.info("Running as MULTIPLAYER CLIENT")
            end
        else
            SoilLogger.info("Running in SINGLEPLAYER mode")
        end

        sfm = SoilFertilityManager.new(mission, modDirectory, modName, disableGUI)
        if sfm == nil then
            SoilLogger.error("CRITICAL: SoilFertilityManager.new() returned nil — check that all source files loaded correctly and that Settings/SettingsManager are available")
            return
        end
        getfenv(0)["g_SoilFertilityManager"] = sfm
        -- Cross-mod bridge: g_currentMission is a shared C++ object visible to all mods.
        -- getfenv(0) is per-mod scoped in FS25. Use mission property for reliable cross-mod detection.
        mission.soilFertilityManager = sfm
        -- #83 Cross-mod bridge for the FarmTablet FieldSentry app (read status + request toggles).
        if FieldSentry_API and FieldSentry_API.attachBridge then
            FieldSentry_API.attachBridge(mission)
        end

        SoilLogger.info("Initialized in %s mode", disableGUI and "server/console" or "full")
    end
end

-- Unload handler
local function unload()
    if sfm ~= nil then
        sfm:delete()
        sfm = nil
        getfenv(0)["g_SoilFertilityManager"] = nil
        if g_currentMission then
            g_currentMission.soilFertilityManager = nil
            g_currentMission.fieldSentry = nil   -- #83 drop the cross-mod bridge
        end
    end
    -- Restore InputHelpDisplay.draw if we hooked it, so a session reload doesn't accumulate appends.
    if _inputHelpDisplayOrigDraw and InputHelpDisplay then
        InputHelpDisplay.draw = _inputHelpDisplayOrigDraw
    end
    _inputHelpDisplayOrigDraw = nil
    _sprayerF1HookInstalled = false
end


-- Hook save/load events
local function hookSaveLoadEvents()
    -- Hook mission save via FSCareerMissionInfo:saveToXMLFile().
    --
    -- FS25 1.17+ save flow:
    --   FSBaseMission:saveSavegame()
    --     → g_savegameController:saveSavegame()
    --       → saveWriteSavegameStart() (C++)
    --         → SavegameController:onSaveStartComplete(errorCode, savegameDirectory)
    --           → missionInfo:setSavegameDirectory(savegameDirectory)   ← sets tempsavegame path
    --           → missionInfo:saveToXMLFile()                           ← THIS is what we hook
    --
    -- The old Mission00.saveToXMLFile hook was a ghost — that method does not exist on
    -- Mission00 and was never called by FS25 1.17, so soilData.xml was never written.
    --
    -- At the time our appended function fires, missionInfo.savegameDirectory already
    -- points to the tempsavegame staging directory.  FS25 copies ALL files from
    -- tempsavegame to the real savegame directory after save tasks complete, so
    -- soilData.xml written here will land in the correct savegame folder on disk.
    if FSCareerMissionInfo and FSCareerMissionInfo.saveToXMLFile then
        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
            FSCareerMissionInfo.saveToXMLFile,
            function(missionInfo)
                -- In multiplayer only the server holds authoritative soil data
                if g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer then
                    if g_server == nil then return end
                end
                if g_SoilFertilityManager then
                    g_SoilFertilityManager:saveSoilData()
                    -- Persist settings here too, NOT only on-change (#637).
                    -- saveToXMLFile fires with savegameDirectory pointing at the tempsavegame
                    -- staging dir, whose contents FS25 then copies over the real savegame
                    -- folder. soilData.xml persists because it is written here; the settings
                    -- file was only ever written on-change to the live dir, so that copy step
                    -- clobbered it and difficulty/replenishment/enabled reverted to defaults
                    -- after a normal save+reload. Writing it here makes settings ride the
                    -- canonical save into tempsavegame → real dir like everything else.
                    if g_SoilFertilityManager.settings then
                        g_SoilFertilityManager.settings:save()
                    end
                    if g_SoilFertilityManager.soilHUD then
                        g_SoilFertilityManager.soilHUD:saveLayout()
                    end
                else
                    SoilLogger.warning("g_SoilFertilityManager is NIL — soil data NOT saved!")
                end
            end
        )
        SoilLogger.info("Save hook installed on FSCareerMissionInfo:saveToXMLFile")
    else
        SoilLogger.warning("FSCareerMissionInfo.saveToXMLFile not found — soil data will NOT be saved")
    end

    -- Load is handled in SoilFertilityManager:onMissionStarted() after soilSystem:initialize().
    -- This guarantees missionInfo.savegameDirectory is set (it is nil at constructor time
    -- for new careers) before we attempt to read soilData.xml.
end

-- Hook into FS25 mission events
-- appendedFunction (not prepended) ensures Mission00.load has fully run and the
-- mission object is completely set up before our load() accesses it.
Mission00.load = Utils.appendedFunction(Mission00.load, load)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, missionStarted)
-- Prepend so our cleanup runs before FS25 tears down g_inputBinding/HUD (fixes black screen with AGS)
FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, unload)

FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    if sfm then
        sfm:update(dt)
        if sfm.sprayerInfoPanel then
            sfm.sprayerInfoPanel:update(dt)
        end
        if sfm.harvesterPanel then
            sfm.harvesterPanel:update(dt)
        end
    end
    -- Cache F1 geometry whenever InputHelpDisplay draws (for auto-anchor positioning)
    if not _sprayerF1HookInstalled and InputHelpDisplay and InputHelpDisplay.draw then
        _inputHelpDisplayOrigDraw = InputHelpDisplay.draw
        InputHelpDisplay.draw = Utils.appendedFunction(InputHelpDisplay.draw, function(displaySelf)
            local m = g_SoilFertilityManager
            if m and m.sprayerInfoPanel then
                m.sprayerInfoPanel:cacheF1Geometry(displaySelf)
            end
        end)
        _sprayerF1HookInstalled = true
    end
end)

-- Hook draw for HUD, settings panel, and minimap overlay
FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
    if not mission.isRunning then return end
    if sfm and sfm.soilHUD then
        sfm.soilHUD:draw()
    end
    if sfm and sfm.settingsPanel then
        sfm.settingsPanel:draw()
    end
    if sfm and sfm.tuningPanel then
        sfm.tuningPanel:draw()
    end
    if sfm and sfm.variableRatePanel then
        sfm.variableRatePanel:draw()
    end
    if sfm and sfm.smartSensorPanel then
        sfm.smartSensorPanel:draw()
    end
    if sfm and sfm.sprayerInfoPanel then
        sfm.sprayerInfoPanel:draw()
    end
    if sfm and sfm.harvesterPanel then
        sfm.harvesterPanel:draw()
    end
    -- Soil layer overlay on the HUD minimap (bottom-left corner).
    -- Uses the ingameMap ref captured at map-load time (g_currentMission.ingameMap is nil in FS25).
    if sfm and sfm.soilMapOverlay then
        local ingameMap = sfm.soilMapOverlay.ingameMapRef
            or (g_currentMission and g_currentMission.ingameMap)
        if ingameMap then
            sfm.soilMapOverlay:onDrawMinimap(ingameMap)
        end
    end
end)

-- Install save/load hooks
hookSaveLoadEvents()

-- =========================================================
-- DEDICATED SERVER FIX: Force fillType registration
-- FS25 dedicated servers sometimes ignore <fillTypes> in modDesc.xml for script mods.
-- We must manually inject our fillTypes.xml into FillTypeManager before it loads mod filltypes.
-- =========================================================
if FillTypeManager and type(FillTypeManager.loadModFillTypes) == "function" then
    local function injectSFModFillTypes(fillTypeManager)
        if fillTypeManager.modsToLoad then
            local alreadyAdded = false
            for _, data in ipairs(fillTypeManager.modsToLoad) do
                if data[2] == modDirectory then
                    alreadyAdded = true
                    break
                end
            end
            if not alreadyAdded then
                SoilLogger.info("Dedi Server Fix: Forcing fillTypes.xml into modsToLoad queue")
                table.insert(fillTypeManager.modsToLoad, {modDirectory .. "fillTypes.xml", modDirectory, modName})
            end
        end
    end
    FillTypeManager.loadModFillTypes = Utils.prependedFunction(FillTypeManager.loadModFillTypes, injectSFModFillTypes)
end

-- TIP ON GROUND FIX: registration moved into loadedMission() below.
--
-- Root cause (documented after three failed hook attempts):
--   DensityMapHeightManager.loadMapData runs before fill types are available.
--   FillTypeManager.loadMapData appended hook also fires too early — the engine
--   processes <fillTypes> from modDesc.xml in a separate pass AFTER loadMapData
--   returns, so our fill types are nil at every earlier hook point.
--   The only guaranteed-safe window is Mission00.loadMission00Finished, where
--   g_fillTypeManager already resolves our fill type names (confirmed by HUD icon
--   patching working in the same callback).

-- Route mouse events to SoilHUD (for drag/resize edit mode).
-- Edit mode is entered via Shift+H (SF_HUD_DRAG input action) — not via RMB.
-- RMB only exits edit mode (and only when this mod is already in edit mode).
-- This guarantees RMB is never consumed during normal play, preserving
-- CoursePlay, AutoDrive, and other mods that rely on RMB.
local soilMouseHandler = {}
function soilMouseHandler:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    -- Tuning panel eats input when open (checked before settings panel — both can't be open simultaneously)
    if sfm and sfm.tuningPanel and sfm.tuningPanel:isOpen() then
        local consumed = sfm.tuningPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
        eventUsed = consumed or eventUsed
        return eventUsed
    end
    -- Settings panel eats input first when open
    if sfm and sfm.settingsPanel and sfm.settingsPanel:isOpen() then
        local consumed = sfm.settingsPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
        eventUsed = consumed or eventUsed
        return eventUsed
    end
    if sfm and sfm.soilHUD then
        local consumed = sfm.soilHUD:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
        eventUsed = consumed or eventUsed
    end
    if sfm and sfm.sprayerInfoPanel then
        local consumed = sfm.sprayerInfoPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
        eventUsed = consumed or eventUsed
    end
    if sfm and sfm.harvesterPanel then
        local consumed = sfm.harvesterPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
        eventUsed = consumed or eventUsed
    end
    return eventUsed
end
addModEventListener(soilMouseHandler)

-- Console commands
function soilfertility()
    if g_SoilFertilityManager and g_SoilFertilityManager.settingsGUI then
        return g_SoilFertilityManager.settingsGUI:consoleCommandHelp()
    else
        print("=== Soil & Fertilizer Mod Commands ===")
        print("Type these commands in console (~):")
        print("SoilShowSettings - Show current settings")
        print("soilStatus - Show current mod status")
        print("SoilEnable/Disable - Enable/disable mod")
        print("SoilSetDifficulty 1|2|3 - Set difficulty")
        print("SoilSetFertility true|false - Toggle fertility system")
        print("SoilSetNutrients true|false - Toggle nutrient cycles")
        print("SoilSetFertilizerCosts true|false - Toggle fertilizer costs")
        print("SoilSetNotifications true|false - Toggle notifications")
        print("SoilSetSeasonalEffects true|false - Toggle seasonal effects")
        print("SoilSetRainEffects true|false - Toggle rain effects")
        print("SoilSetPlowingBonus true|false - Toggle plowing bonus")
        print("SoilResetSettings - Reset to defaults")
        print("SoilFieldInfo <fieldId> - Show field soil info")
        print("SoilSaveData - Force save soil data")
        print("SoilRerollFields - Re-roll starting soil for all fields (new regional variation)")
        print("SoilRerollUnownedFields - Re-roll starting soil for fields you don't own (keeps your own)")
        print("SoilPFDump - Dump Precision Farming API (for integration diagnostics)")
        print("")
        print("NOTE: In multiplayer, only server admins can change settings")
        print("================================")
        return "Soil & Fertilizer Mod commands listed above"
    end
end

function soilStatus()
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local s = g_SoilFertilityManager.settings
        local isMultiplayer = g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer
        local isServer = g_server ~= nil
        local isClient = g_client ~= nil

        local pfBridge = g_SoilFertilityManager.pfBridge
        local pfStatus = (pfBridge and pfBridge.isActive) and "ACTIVE (N/pH deferred to PF)" or "not detected"
        print(string.format(
            "=== Soil & Fertilizer Status ===\n" ..
            "Mode: %s\n" ..
            "Role: %s\n" ..
            "Enabled: %s\n" ..
            "Precision Farming: %s\n" ..
            "Fertility System: %s\n" ..
            "Nutrient Cycles: %s\n" ..
            "Fertilizer Costs: %s\n" ..
            "Difficulty: %s\n" ..
            "Notifications: %s\n" ..
            "Seasonal Effects: %s\n" ..
            "Rain Effects: %s\n" ..
            "Plowing Bonus: %s\n" ..
            "================================",
            isMultiplayer and "Multiplayer" or "Singleplayer",
            isServer and "Server" or (isClient and "Client" or "Unknown"),
            tostring(s.enabled),
            pfStatus,
            tostring(s.fertilitySystem),
            tostring(s.nutrientCycles),
            tostring(s.fertilizerCosts),
            s:getDifficultyName(),
            tostring(s.showNotifications),
            tostring(s.seasonalEffects),
            tostring(s.rainEffects),
            tostring(s.plowingBonus)
        ))
    else
        print("Soil & Fertilizer Mod not initialized")
    end
end

-- Debug: dump current vehicle's sprayer spec to diagnose visual effect issues
function SoilSprayerDebug()
    local vehicle = g_currentMission and g_currentMission.controlledVehicle
    if not vehicle then
        print("[SoilSprayerDebug] No controlled vehicle")
        return
    end
    local spec = vehicle.spec_sprayer
    if not spec then
        print("[SoilSprayerDebug] Vehicle has no spec_sprayer")
        return
    end

    local fm = g_fillTypeManager
    local fillUnitIdx = vehicle:getSprayerFillUnitIndex()
    local fillType    = vehicle:getFillUnitFillType(fillUnitIdx)
    local fillFT      = fm and fm:getFillTypeByIndex(fillType)
    local effectsVis  = vehicle:getAreEffectsVisible()
    local wap         = spec.workAreaParameters

    print(string.format("[SoilSprayerDebug] Vehicle: %s", tostring(vehicle.configFileName or "?")))
    print(string.format("  fillUnit=%d  fillType=%s(%s)  effectsVisible=%s",
        fillUnitIdx, tostring(fillType), tostring(fillFT and fillFT.name), tostring(effectsVis)))
    print(string.format("  wap.sprayType=%s  wap.sprayFillType=%s  wap.isActive=%s  wap.lastSprayTime=%s",
        tostring(wap and wap.sprayType), tostring(wap and wap.sprayFillType),
        tostring(wap and wap.isActive), tostring(wap and wap.lastSprayTime)))

    print(string.format("  spec.effects count=%d", spec.effects and #spec.effects or 0))
    print(string.format("  spec.sprayTypes count=%d", spec.sprayTypes and #spec.sprayTypes or 0))

    for i, st in ipairs(spec.sprayTypes or {}) do
        local ftNames = st.fillTypes and table.concat(st.fillTypes, ",") or "nil"
        print(string.format("  sprayType[%d]: fillTypes=[%s]  effects=%d  animNodes=%d",
            i, ftNames,
            st.effects and #st.effects or 0,
            st.animationNodes and #st.animationNodes or 0))
    end

    local activeSprayType = vehicle:getActiveSprayType()
    print(string.format("  getActiveSprayType() = %s", activeSprayType and "FOUND" or "nil"))
    print(string.format("  _soilEffectsActive=%s  _soilManagedFillType=%s",
        tostring(spec._soilEffectsActive), tostring(spec._soilManagedFillType)))
end

-- Dump Precision Farming bridge status and API discovery to the log.
function SoilPFDump()
    if g_SoilFertilityManager and g_SoilFertilityManager.pfBridge then
        g_SoilFertilityManager.pfBridge:dumpApi()
        return "PF dump written to log (check console output)"
    end
    -- Bridge created in SoilFertilityManager.new() so this only happens before mission load.
    print("[SoilPFDump] SF bridge not yet initialised — load a savegame first, then run SoilPFDump")
    return "Bridge not ready — load savegame first"
end

-- Expose global console functions
getfenv(0)["soilfertility"] = soilfertility
getfenv(0)["soilStatus"] = soilStatus
getfenv(0)["SoilSprayerDebug"] = SoilSprayerDebug
getfenv(0)["SoilPFDump"] = SoilPFDump
getfenv(0)["soilEnable"] = function()
    if g_SoilFertilityManager and g_SoilFertilityManager.settingsGUI then
        return g_SoilFertilityManager.settingsGUI:consoleCommandSoilEnable()
    end
    return "Soil & Fertilizer Mod not initialized"
end
getfenv(0)["soilDisable"] = function()
    if g_SoilFertilityManager and g_SoilFertilityManager.settingsGUI then
        return g_SoilFertilityManager.settingsGUI:consoleCommandSoilDisable()
    end
    return "Soil & Fertilizer Mod not initialized"
end

print("========================================")
print("  FS25 Soil & Fertilizer Mod LOADED     ")
print("  Realistic soil management system      ")
print("  Type 'soilfertility' for commands     ")

print("========================================")