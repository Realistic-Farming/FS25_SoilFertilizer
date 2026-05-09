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

-- 2. Core systems
source(modDirectory .. "src/hooks/HookManager.lua")
source(modDirectory .. "src/ui/SoilLayerSystem.lua")
source(modDirectory .. "src/SprayerRateManager.lua")
source(modDirectory .. "src/SoilFertilitySystem.lua")

-- 3. Settings
source(modDirectory .. "src/settings/SettingsManager.lua")
source(modDirectory .. "src/settings/Settings.lua")
source(modDirectory .. "src/settings/SoilSettingsGUI.lua")

-- 4. UI + Manager (Manager must come after Settings so its new() dependencies are defined)
source(modDirectory .. "src/utils/UIHelper.lua")
source(modDirectory .. "src/settings/SoilSettingsUI.lua")
source(modDirectory .. "src/ui/SoilHUD.lua")
source(modDirectory .. "src/ui/SoilReportDialog.lua")
source(modDirectory .. "src/ui/SoilMapOverlay.lua")
source(modDirectory .. "src/hooks/SoilMapHooks.lua")
source(modDirectory .. "src/ui/SoilPDAScreen.lua")
source(modDirectory .. "src/ui/SoilFieldDetailDialog.lua")
source(modDirectory .. "src/ui/SoilTreatmentDialog.lua")
source(modDirectory .. "src/ui/SoilVersionDialog.lua")
source(modDirectory .. "src/ui/SoilSettingsPanel.lua")
source(modDirectory .. "src/SoilFertilityManager.lua")

-- 5. Network
source(modDirectory .. "src/network/NetworkEvents.lua")

-- 6. Integrations
source(modDirectory .. "src/integrations/SectionControlIntegration.lua")

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

-- Helper: check if mod is initialized
local function isEnabled()
    return sfm ~= nil
end

-- Called after mission loaded
local function loadedMission(mission, node)
    if mission.cancelLoading then return end
    if sfm == nil then
        SoilLogger.error("loadedMission: sfm is nil — SoilFertilityManager.new() failed during load(), mod will not function")
        return
    end
    sfm:onMissionLoaded()

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

        SoilLogger.info("Initialized in %s mode", disableGUI and "server/console" or "full")
    end
end

-- Unload handler
local function unload()
    if sfm ~= nil then
        sfm:delete()
        sfm = nil
        getfenv(0)["g_SoilFertilityManager"] = nil
        if g_currentMission then g_currentMission.soilFertilityManager = nil end
    end
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

    -- Load is handled in SoilFertilityManager:deferredSoilSystemInit() after soilSystem:initialize().
    -- This guarantees missionInfo.savegameDirectory is set (it is nil at constructor time
    -- for new careers) before we attempt to read soilData.xml.
end

-- Hook into FS25 mission events
-- appendedFunction (not prepended) ensures Mission00.load has fully run and the
-- mission object is completely set up before our load() accesses it.
Mission00.load = Utils.appendedFunction(Mission00.load, load)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
-- Prepend so our cleanup runs before FS25 tears down g_inputBinding/HUD (fixes black screen with AGS)
FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, unload)

FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    if sfm then
        sfm:update(dt)
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

-- Route mouse events to SoilHUD (for drag/resize edit mode).
-- Edit mode is entered via Shift+H (SF_HUD_DRAG input action) — not via RMB.
-- RMB only exits edit mode (and only when this mod is already in edit mode).
-- This guarantees RMB is never consumed during normal play, preserving
-- CoursePlay, AutoDrive, and other mods that rely on RMB.
local soilMouseHandler = {}
function soilMouseHandler:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
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

        print(string.format(
            "=== Soil & Fertilizer Status ===\n" ..
            "Mode: %s\n" ..
            "Role: %s\n" ..
            "Enabled: %s\n" ..
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

-- Expose global console functions
getfenv(0)["soilfertility"] = soilfertility
getfenv(0)["soilStatus"] = soilStatus
getfenv(0)["SoilSprayerDebug"] = SoilSprayerDebug
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