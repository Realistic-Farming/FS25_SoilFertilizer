-- =========================================================
-- FS25 Realistic Soil & Fertilizer (FarmlandManager version)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE: All rights reserved.
-- =========================================================
---@class SoilFertilityManager
SoilFertilityManager = {}
local SoilFertilityManager_mt = Class(SoilFertilityManager)


--- Create new SoilFertilityManager instance
---@param mission table The mission object
---@param modDirectory string Path to mod directory
---@param modName string Name of the mod
---@param disableGUI boolean Whether to disable GUI elements
---@return SoilFertilityManager
function SoilFertilityManager.new(mission, modDirectory, modName, disableGUI)
    local self = setmetatable({}, SoilFertilityManager_mt)

    self.mission = mission
    self.modDirectory = modDirectory
    self.modName = modName
    self.disableGUI = disableGUI or false
    self.lastSeenVersion = ""

    -- PF bridge (created early so SoilPFDump works before deferred init fires)
    self.pfBridge = PrecisionFarmingBridge and PrecisionFarmingBridge:new() or nil
    self.hasPrecisionFarming = false

    -- Settings
    if not Settings then
        SoilLogger.error("CRITICAL: Settings not loaded — check source order in main.lua")
        return nil
    end
    if not SettingsManager then
        SoilLogger.error("CRITICAL: SettingsManager not loaded — check source order in main.lua")
        return nil
    end
    self.settingsManager = SettingsManager.new()
    self.settings = Settings.new(self.settingsManager)

    -- Soil system
    if not SoilFertilitySystem then
        SoilLogger.error("CRITICAL: SoilFertilitySystem not loaded - mod cannot initialize")
        if g_gui then
            g_gui:showInfoDialog({
                text = "Soil & Fertilizer Mod failed to load.\n\nCritical module 'SoilFertilitySystem' is missing.\n\nPlease reinstall the mod or check for conflicts with other mods.",
                title = "Mod Load Error"
            })
        end
        return nil
    end
    self.soilSystem = SoilFertilitySystem.new(self.settings)

    -- Sprayer rate manager (always active — not GUI-dependent)
    self.sprayerRateManager = SprayerRateManager.new()
    self._autoRateTimer = 0  -- throttle timer for auto-rate updates

    -- GUI initialization (client only)
    -- Hooks are installed at file-load time in SoilSettingsUI.lua (runs once).
    -- We just create the instance here; the hooks reference g_SoilFertilityManager.settingsUI.
    local shouldInitGUI = not self.disableGUI and mission:getIsClient() and g_gui and not g_safeMode
    if shouldInitGUI then
        SoilLogger.info("Initializing GUI elements...")
        self.settingsUI = SoilSettingsUI.new(self.settings)
    else
        SoilLogger.info("GUI initialization skipped (Server/Console mode)")
        self.settingsUI = nil
    end

    -- Console commands
    self.settingsGUI = SoilSettingsGUI.new()
    self.settingsGUI:registerConsoleCommands()

    -- HUD (client only)
    if shouldInitGUI then
        if not SoilHUD then
            SoilLogger.error("CRITICAL: SoilHUD not loaded - HUD will be disabled")
            if g_gui then
                g_gui:showInfoDialog({
                    text = "Soil & Fertilizer Mod: HUD module failed to load.\n\nThe mod will run without the HUD display.\n\nCore features remain active.",
                    title = "HUD Load Warning"
                })
            end
            self.soilHUD = nil
        else
            self.soilHUD = SoilHUD.new(self.soilSystem, self.settings)
            SoilLogger.info("Soil HUD created")
        end

        -- Soil Report dialog (K key)
        if SoilReportDialog and g_gui then
            self.soilReportDialog = SoilReportDialog.getInstance(modDirectory)
            SoilLogger.info("Soil Report dialog created")
        end

        -- Field Detail dialog (opened from PDA Screen fields list)
        if SoilFieldDetailDialog and g_gui then
            SoilFieldDetailDialog.register(modDirectory)
            SoilLogger.info("Soil Field Detail dialog registered")
        end

        -- Treatment Detail dialog (opened from PDA Screen treatment list)
        if SoilTreatmentDialog and g_gui then
            SoilTreatmentDialog.register(modDirectory)
            SoilLogger.info("Soil Treatment dialog registered")
        end

        -- Version/changelog dialog (shown once per version on load)
        if SoilVersionDialog and g_gui then
            SoilVersionDialog.register(modDirectory)
            SoilLogger.info("Soil Version dialog registered")
        end

        -- PDA help dialog (X button in PDA footer)
        if SoilHelpDialog and g_gui then
            SoilHelpDialog.register(modDirectory)
            SoilLogger.info("Soil Help dialog registered")
        end

        -- Overlay help dialog (4th sidebar button on soil map)
        if SoilOverlayHelpDialog and g_gui then
            SoilOverlayHelpDialog.register(modDirectory)
            SoilLogger.info("Soil Overlay Help dialog registered")
        end

        -- Map overlay (client only)
        if SoilMapOverlay then
            self.soilMapOverlay = SoilMapOverlay.new(self.soilSystem, self.settings)
            self.soilMapOverlay:initialize()
            SoilLogger.info("Soil Map Overlay created")
        end

        -- Settings panel (SHIFT+O)
        if SoilSettingsPanel then
            self.settingsPanel = SoilSettingsPanel.new(self.settings)
            SoilLogger.info("Settings panel created")
        end

        -- Soil Map Cell dialog (Shift+S)
        if SoilMapCellDialog and g_gui then
            local dialog = SoilMapCellDialog.new()
            g_gui:loadGui(modDirectory .. "xml/gui/SoilMapCellDialog.xml", "SoilMapCellDialog", dialog)
            self.soilMapCellDialog = dialog  -- must be stored so the Shift+S input guard passes
            SoilLogger.info("Soil Map Cell dialog registered")
        end

        -- Hook PlayerInputComponent.registerActionEvents to register J/K in the PLAYER context.
        -- PLAYER context is reused (not recreated) when the player returns on foot, so these
        -- events persist across vehicle entry/exit cycles.
        if self.soilHUD and PlayerInputComponent and PlayerInputComponent.registerActionEvents then
            local originalRegisterActionEvents = PlayerInputComponent.registerActionEvents
            self._inputHookOriginal = originalRegisterActionEvents  -- saved for cleanup in delete()
            PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
                originalRegisterActionEvents(inputComponent, ...)

                -- Only register for the local (owning) player, not for every networked player
                if not (inputComponent.player and inputComponent.player.isOwner) then return end
                -- Guard against double-registration across level reloads
                if g_SoilFertilityManager and g_SoilFertilityManager.toggleHUDEventId then return end
                if not g_SoilFertilityManager or not g_SoilFertilityManager.soilHUD then return end

                -- Register J and K in PLAYER context (on-foot use).
                -- PlayerStateDriving calls setContext("PLAYER") WITHOUT createNew=true,
                -- so the PLAYER context is reused and our events survive vehicle transitions.
                g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                local hudOk, hudId = g_inputBinding:registerActionEvent(
                    InputAction.SF_TOGGLE_HUD, g_SoilFertilityManager,
                    g_SoilFertilityManager.onToggleHUDInput,
                    false, true, false, true
                )
                if hudOk and hudId then
                    g_SoilFertilityManager.toggleHUDEventId = hudId
                    SoilLogger.info("HUD toggle (J) registered in PLAYER context")
                else
                    SoilLogger.warning("HUD toggle (J) PLAYER registration failed")
                end

                if g_SoilFertilityManager.soilReportDialog then
                    local repOk, repId = g_inputBinding:registerActionEvent(
                        InputAction.SF_SOIL_REPORT, g_SoilFertilityManager,
                        g_SoilFertilityManager.onSoilReportInput,
                        false, true, false, true
                    )
                    if repOk and repId then
                        g_SoilFertilityManager.soilReportEventId = repId
                        SoilLogger.info("Soil Report (K) registered in PLAYER context")
                    end
                end

                -- Cell Map Inspection (Shift+S)
                if g_SoilFertilityManager.soilMapCellDialog then
                    local cellOk, cellId = g_inputBinding:registerActionEvent(
                        InputAction.SF_TOGGLE_CELL_MAP, g_SoilFertilityManager,
                        g_SoilFertilityManager.onToggleCellMapInput,
                        false, true, false, true
                    )
                    if cellOk and cellId then
                        g_SoilFertilityManager.toggleCellMapEventId = cellId
                        g_inputBinding:setActionEventTextVisibility(cellId, true)
                        g_inputBinding:setActionEventText(cellId, g_i18n:getText("input_SF_TOGGLE_CELL_MAP"))
                        SoilLogger.info("Soil Cell Map (Shift+S) registered in PLAYER context")
                    end
                end

                -- Map layer cycle (Shift+M) — registered in PLAYER context only
                -- (pause-menu map is accessible regardless of context, but the key
                --  is intended for on-foot use; Shift+M avoids VEHICLE conflicts)
                if g_SoilFertilityManager.soilMapOverlay then
                    local mapOk, mapId = g_inputBinding:registerActionEvent(
                        InputAction.SF_CYCLE_MAP_LAYER, g_SoilFertilityManager,
                        g_SoilFertilityManager.onCycleMapLayerInput,
                        false, true, false, true
                    )
                    if mapOk and mapId then
                        g_SoilFertilityManager.cycleMapLayerEventId = mapId
                        g_inputBinding:setActionEventTextVisibility(mapId, false)
                        SoilLogger.info("Map layer cycle (Shift+M) registered in PLAYER context")
                    end
                end

                -- Settings panel (Shift+O) — registered in PLAYER context
                if g_SoilFertilityManager.settingsPanel then
                    local spOk, spId = g_inputBinding:registerActionEvent(
                        InputAction.SF_OPEN_SETTINGS, g_SoilFertilityManager,
                        g_SoilFertilityManager.onOpenSettingsInput,
                        false, true, false, true
                    )
                    if spOk and spId then
                        g_SoilFertilityManager.settingsPanelEventId = spId
                        g_inputBinding:setActionEventTextVisibility(spId, false)
                        SoilLogger.info("Settings panel (Shift+O) registered in PLAYER context")
                    end
                end

                -- HUD drag toggle (SF_HUD_DRAG, default Shift+H) — PLAYER context
                if g_SoilFertilityManager.soilHUD then
                    local dragOk, dragId = g_inputBinding:registerActionEvent(
                        InputAction.SF_HUD_DRAG, g_SoilFertilityManager,
                        g_SoilFertilityManager.onHUDDragInput,
                        false, true, false, true
                    )
                    if dragOk and dragId then
                        g_SoilFertilityManager.hudDragEventId = dragId
                        g_inputBinding:setActionEventTextVisibility(dragId, false)
                        SoilLogger.info("HUD drag (Shift+H) registered in PLAYER context")
                    end
                end

                g_inputBinding:endActionEventsModification()
                SoilLogger.info("PLAYER context input registration complete")
            end
            SoilLogger.info("PlayerInputComponent hook installed for J/K (PLAYER context)")
        end

        -- Hook InputBinding.endActionEventsModification to register our keys in VEHICLE context.
        --
        -- WHY this approach instead of hooking Vehicle.registerActionEvents directly:
        -- SpecializationUtil.copyTypeFunctionsInto() copies functions to each vehicle INSTANCE
        -- table at spawn time. After that, vehicle:registerActionEvents() resolves from the
        -- instance table, never looking up Vehicle.registerActionEvents on the class. Any
        -- override of Vehicle.registerActionEvents after vehicles exist is silently ignored.
        --
        -- Instead, we hook InputBinding.endActionEventsModification (a class method on the
        -- InputBinding class). Every call to endActionEventsModification routes through it,
        -- including every VEHICLE context close. We detect VEHICLE context and inject our events.
        -- registerActionEvent's built-in dedup handles multiple calls per session gracefully.
        if self.soilHUD and InputBinding and InputBinding.endActionEventsModification then
            local _soilVehicleHookActive = false
            local originalEndMod = InputBinding.endActionEventsModification
            self._vehicleInputHookOriginal = originalEndMod
            InputBinding.endActionEventsModification = function(binding, ignoreCheck)
                -- Capture context name BEFORE the original resets it to NO_REGISTRATION_CONTEXT
                local contextName = ""
                if binding.registrationContext and
                   binding.registrationContext ~= InputBinding.NO_REGISTRATION_CONTEXT then
                    contextName = binding.registrationContext.name or ""
                end

                originalEndMod(binding, ignoreCheck)

                -- Only act on VEHICLE context closures, and avoid re-entrancy
                if contextName ~= Vehicle.INPUT_CONTEXT_NAME then return end
                if _soilVehicleHookActive then return end
                if not g_SoilFertilityManager or not g_SoilFertilityManager.soilHUD then return end

                _soilVehicleHookActive = true

                -- Purge any stale event IDs from a previous registration pass.
                -- endActionEventsModification fires on every vehicle mount/seat change
                -- (including Courseplay seat cycling). Without cleanup, duplicate
                -- registrations accumulate — callbacks fire 2-3× per keypress and
                -- SF_HUD_DRAG (Shift+H) toggles edit mode.
                --
                -- IMPORTANT: Also purge PLAYER context event IDs here. FS25's
                -- removeActionEvent works by action slot, not strictly by context.
                -- Removing vehicleSettingsPanelEventId / vehicleHUDEventId can
                -- silently invalidate the PLAYER-registered slots for the same
                -- InputActions. We nil them so the PLAYER re-registration below
                -- can issue fresh registerActionEvent calls.
                local mgr = g_SoilFertilityManager
                local staleIds = {
                    -- VEHICLE context IDs
                    "vehicleHUDEventId", "vehicleReportEventId",
                    "rateUpEventId",     "rateDownEventId",
                    "toggleAutoEventId", "vehicleSettingsPanelEventId",
                    "vehicleHudDragEventId", "vehicleCellMapEventId",
                    -- PLAYER context IDs (invalidated as a side-effect of the above removes)
                    "toggleHUDEventId", "soilReportEventId",
                    "cycleMapLayerEventId", "settingsPanelEventId", "hudDragEventId",
                    "toggleCellMapEventId",
                }
                for _, field in ipairs(staleIds) do
                    local oldId = mgr[field]
                    if oldId then
                        pcall(function() binding:removeActionEvent(oldId) end)
                        mgr[field] = nil
                    end
                end

                binding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)

                -- HUD toggle (J) in vehicle
                local vHudOk, vHudId = binding:registerActionEvent(
                    InputAction.SF_TOGGLE_HUD, g_SoilFertilityManager,
                    g_SoilFertilityManager.onToggleHUDInput,
                    false, true, false, true
                )
                if vHudOk and vHudId then
                    g_SoilFertilityManager.vehicleHUDEventId = vHudId
                    SoilLogger.debug("HUD toggle (J) registered in VEHICLE context")
                end

                -- Soil Report (K) in vehicle
                if g_SoilFertilityManager.soilReportDialog then
                    local vRepOk, vRepId = binding:registerActionEvent(
                        InputAction.SF_SOIL_REPORT, g_SoilFertilityManager,
                        g_SoilFertilityManager.onSoilReportInput,
                        false, true, false, true
                    )
                    if vRepOk and vRepId then
                        g_SoilFertilityManager.vehicleReportEventId = vRepId
                        SoilLogger.debug("Soil Report (K) registered in VEHICLE context")
                    end
                end

                -- Cell Map (Shift+S) in vehicle
                if g_SoilFertilityManager.soilMapCellDialog then
                    local vCellOk, vCellId = binding:registerActionEvent(
                        InputAction.SF_TOGGLE_CELL_MAP, g_SoilFertilityManager,
                        g_SoilFertilityManager.onToggleCellMapInput,
                        false, true, false, true
                    )
                    if vCellOk and vCellId then
                        g_SoilFertilityManager.vehicleCellMapEventId = vCellId
                        binding:setActionEventTextVisibility(vCellId, true)
                        binding:setActionEventText(vCellId, g_i18n:getText("input_SF_TOGGLE_CELL_MAP"))
                        SoilLogger.debug("Soil Cell Map (Shift+S) registered in VEHICLE context")
                    end
                end

                -- Rate UP (])
                local upOk, upId = binding:registerActionEvent(
                    InputAction.SF_RATE_UP, g_SoilFertilityManager,
                    g_SoilFertilityManager.onSprayerRateUpInput,
                    false, true, false, true
                )
                if upOk and upId then
                    g_SoilFertilityManager.rateUpEventId = upId
                    SoilLogger.debug("Rate UP (]) registered in VEHICLE context")
                end

                -- Rate DOWN ([)
                local downOk, downId = binding:registerActionEvent(
                    InputAction.SF_RATE_DOWN, g_SoilFertilityManager,
                    g_SoilFertilityManager.onSprayerRateDownInput,
                    false, true, false, true
                )
                if downOk and downId then
                    g_SoilFertilityManager.rateDownEventId = downId
                    SoilLogger.debug("Rate DOWN ([) registered in VEHICLE context")
                end

                -- Auto toggle (Shift+L)
                local autoOk, autoId = binding:registerActionEvent(
                    InputAction.SF_TOGGLE_AUTO, g_SoilFertilityManager,
                    g_SoilFertilityManager.onToggleAutoInput,
                    false, true, false, true
                )
                if autoOk and autoId then
                    g_SoilFertilityManager.toggleAutoEventId = autoId
                    SoilLogger.debug("Auto toggle (Shift+L) registered in VEHICLE context")
                end

                -- Settings panel (Shift+O) in VEHICLE context
                if g_SoilFertilityManager.settingsPanel then
                    local vSpOk, vSpId = binding:registerActionEvent(
                        InputAction.SF_OPEN_SETTINGS, g_SoilFertilityManager,
                        g_SoilFertilityManager.onOpenSettingsInput,
                        false, true, false, true
                    )
                    if vSpOk and vSpId then
                        g_SoilFertilityManager.vehicleSettingsPanelEventId = vSpId
                        binding:setActionEventTextVisibility(vSpId, false)
                        SoilLogger.debug("Settings panel (Shift+O) registered in VEHICLE context")
                    end
                end

                -- HUD drag toggle (SF_HUD_DRAG, default Shift+H) — VEHICLE context
                if g_SoilFertilityManager.soilHUD then
                    local vDragOk, vDragId = binding:registerActionEvent(
                        InputAction.SF_HUD_DRAG, g_SoilFertilityManager,
                        g_SoilFertilityManager.onHUDDragInput,
                        false, true, false, true
                    )
                    if vDragOk and vDragId then
                        g_SoilFertilityManager.vehicleHudDragEventId = vDragId
                        binding:setActionEventTextVisibility(vDragId, false)
                        SoilLogger.debug("HUD drag (Shift+H) registered in VEHICLE context")
                    end
                end

                binding:endActionEventsModification()

                -- Re-register PLAYER context events. These were invalidated above when we
                -- called removeActionEvent on the vehicle IDs for the same InputActions.
                -- PlayerInputComponent.registerActionEvents will NOT fire again on vehicle
                -- exit (the PLAYER context is reused, not recreated), so we must do this here.
                binding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                local pHudOk, pHudId = binding:registerActionEvent(
                    InputAction.SF_TOGGLE_HUD, g_SoilFertilityManager,
                    g_SoilFertilityManager.onToggleHUDInput,
                    false, true, false, true
                )
                if pHudOk and pHudId then
                    g_SoilFertilityManager.toggleHUDEventId = pHudId
                    SoilLogger.debug("HUD toggle (J) re-registered in PLAYER context after vehicle exit")
                end

                if g_SoilFertilityManager.soilReportDialog then
                    local pRepOk, pRepId = binding:registerActionEvent(
                        InputAction.SF_SOIL_REPORT, g_SoilFertilityManager,
                        g_SoilFertilityManager.onSoilReportInput,
                        false, true, false, true
                    )
                    if pRepOk and pRepId then
                        g_SoilFertilityManager.soilReportEventId = pRepId
                        SoilLogger.debug("Soil Report (K) re-registered in PLAYER context after vehicle exit")
                    end
                end

                if g_SoilFertilityManager.soilMapOverlay then
                    local pMapOk, pMapId = binding:registerActionEvent(
                        InputAction.SF_CYCLE_MAP_LAYER, g_SoilFertilityManager,
                        g_SoilFertilityManager.onCycleMapLayerInput,
                        false, true, false, true
                    )
                    if pMapOk and pMapId then
                        g_SoilFertilityManager.cycleMapLayerEventId = pMapId
                        binding:setActionEventTextVisibility(pMapId, false)
                        SoilLogger.debug("Map layer cycle (Shift+M) re-registered in PLAYER context after vehicle exit")
                    end
                end

                if g_SoilFertilityManager.settingsPanel then
                    local pSpOk, pSpId = binding:registerActionEvent(
                        InputAction.SF_OPEN_SETTINGS, g_SoilFertilityManager,
                        g_SoilFertilityManager.onOpenSettingsInput,
                        false, true, false, true
                    )
                    if pSpOk and pSpId then
                        g_SoilFertilityManager.settingsPanelEventId = pSpId
                        binding:setActionEventTextVisibility(pSpId, false)
                        SoilLogger.debug("Settings panel (Shift+O) re-registered in PLAYER context after vehicle exit")
                    end
                end

                if g_SoilFertilityManager.soilHUD then
                    local pDragOk, pDragId = binding:registerActionEvent(
                        InputAction.SF_HUD_DRAG, g_SoilFertilityManager,
                        g_SoilFertilityManager.onHUDDragInput,
                        false, true, false, true
                    )
                    if pDragOk and pDragId then
                        g_SoilFertilityManager.hudDragEventId = pDragId
                        binding:setActionEventTextVisibility(pDragId, false)
                        SoilLogger.debug("HUD drag (Shift+H) re-registered in PLAYER context after vehicle exit")
                    end
                end

                -- Cell Map (Shift+S) re-registration in PLAYER context
                if g_SoilFertilityManager.soilMapCellDialog then
                    local pCellOk, pCellId = binding:registerActionEvent(
                        InputAction.SF_TOGGLE_CELL_MAP, g_SoilFertilityManager,
                        g_SoilFertilityManager.onToggleCellMapInput,
                        false, true, false, true
                    )
                    if pCellOk and pCellId then
                        g_SoilFertilityManager.toggleCellMapEventId = pCellId
                        binding:setActionEventTextVisibility(pCellId, true)
                        binding:setActionEventText(pCellId, g_i18n:getText("input_SF_TOGGLE_CELL_MAP"))
                        SoilLogger.debug("Cell Map (Shift+S) re-registered in PLAYER context after vehicle exit")
                    end
                end

                binding:endActionEventsModification()
                SoilLogger.debug("PLAYER context inputs restored after vehicle exit")

                _soilVehicleHookActive = false
            end
            SoilLogger.info("InputBinding.endActionEventsModification hooked for VEHICLE context keys")
        end
    else
        self.soilHUD = nil
    end

    -- Load settings
    self.settings:load()

    -- NOTE: Soil data is loaded in deferredSoilSystemInit() AFTER initialize(),
    -- so savegameDirectory is guaranteed to be set (it's nil at constructor time on new careers).

    -- Informational detection for known mod categories
    if g_modIsLoaded then
        for modName, _ in pairs(g_modIsLoaded) do
            local lowerName = string.lower(tostring(modName))
            if lowerName:find("realisticharvesting") or lowerName:find("realistic_harvesting") then
                SoilLogger.info("RealisticHarvesting detected — harvest hooks appended safely; soil updates fire if FruitUtil still present")
            elseif lowerName:find("croprotation") or lowerName:find("crop_rotation") then
                SoilLogger.info("CropRotation detected — no conflict; separate crop tracking data")
            elseif lowerName:find("bettercontracts") then
                SoilLogger.info("BetterContracts detected — profile-based UI creation ensures no settings page corruption")
            elseif lowerName:find("mudsystem") or lowerName:find("mud_system") or lowerName:find("mudphysic") then
                SoilLogger.info("MudSystem/terrain mod detected — no conflict with soil nutrients")
            end
        end
    end

    return self
end

--- Called after mission is loaded (loadMission00Finished).
--- Initializes HUD and settings panel — fields not yet guaranteed populated at this point.
function SoilFertilityManager:onMissionLoaded()
    if not self.settings.enabled then return end

    local success, errorMsg = pcall(function()
        if self.soilHUD then
            self.soilHUD:initialize()
        end

        if self.settingsPanel then
            self.settingsPanel:initialize()
        end
    end)

    if not success then
        SoilLogger.error("Error during mission load - %s", tostring(errorMsg))
        self.settings.enabled = false
        self.settings:save()
    end
end

--- Called when mission actually starts (Mission00.onStartMission).
--- At this point the loading screen is gone, the player is in the world, and
--- g_fieldManager.fields is fully populated — safe to initialize the soil system.
function SoilFertilityManager:onMissionStarted()
    if not self.soilSystem then return end

    -- Reload settings: savegameDirectory is guaranteed set by onStartMission time.
    -- The load() call in new() fires during Mission00.load before savegameDirectory
    -- is available on fresh saves, so it falls back to defaults.
    self.settings:load()

    if not self.settings.enabled then
        SoilLogger.info("Mod disabled in settings — skipping soil system init")
        return
    end

    SoilLogger.info("Mission started — initializing soil system (fields guaranteed populated)...")

    local ok, err = pcall(function()
        self.soilSystem:initialize()

        if self.pfBridge then
            self.pfBridge:initialize()
            if not self.settings.pfCompatibilityMode then
                self.pfBridge.isActive = false
            end
            self.hasPrecisionFarming = self.pfBridge.isActive
            self.soilSystem.pfBridge = self.pfBridge
        end

        self:loadSoilData()

        if self.settings.showNotifications and SoilVersionDialog and SoilVersionDialog.INSTANCE ~= nil then
            local modInfo = g_modManager and g_modManager:getModByName(self.modName)
            local version = (modInfo and modInfo.version) or "?"
            if self.lastSeenVersion ~= version then
                SoilVersionDialog.show(version)
            end
        end
    end)

    if not ok then
        SoilLogger.error("onMissionStarted init failed: %s", tostring(err))
    end
end

-- NOTE: registerInputActions() removed.
-- J key is now registered inside the PlayerInputComponent.registerActionEvents hook
-- installed in SoilFertilityManager.new(). This fires at the exact moment the player's
-- input subsystem is ready, eliminating the race condition on dedicated-server clients.

-- Input callback for HUD toggle (J)
function SoilFertilityManager:onToggleHUDInput()
    if self.soilHUD then
        self.soilHUD:toggleVisibility()
    end
end

-- Input callback for Settings Panel (Shift+O)
function SoilFertilityManager:onOpenSettingsInput()
    if self.settingsPanel then
        self.settingsPanel:toggle()
    end
end

-- Input callback for HUD drag toggle (SF_HUD_DRAG, default Shift+H)
function SoilFertilityManager:onHUDDragInput()
    if not self.soilHUD then return end
    -- Don't steal RMB when HUD is hidden or mod is disabled — prevents mouse cursor
    -- appearing on RMB vehicle actions (e.g. direction change) after implement cycling.
    if not self.soilHUD.visible then return end
    if not (self.settings and self.settings.showHUD and self.settings.enabled) then return end
    if self.soilHUD.editMode then
        self.soilHUD:exitEditMode()
    else
        self.soilHUD:enterEditMode()
    end
end

-- Input callback for Soil Report dialog (K)
function SoilFertilityManager:onSoilReportInput()
    if self.soilReportDialog then
        self.soilReportDialog:show()
    end
end

-- Input callbacks for sprayer rate up/down ([ / ] keys in VEHICLE context)
-- Note: `self` here is the sprayer vehicle (the action event target), not SoilFertilityManager.
-- Player-context rate callbacks (registered in PlayerInputComponent hook).
-- `self` here is g_SoilFertilityManager.  Current vehicle is fetched via g_localPlayer.
local function getPlayerVehicle()
    if not g_localPlayer then return nil end
    if type(g_localPlayer.getIsInVehicle) ~= "function" then return nil end
    if not g_localPlayer:getIsInVehicle() then return nil end
    return g_localPlayer:getCurrentVehicle()
end

-- Returns the fertilizer applicator relevant for rate adjustment.
-- Checks the directly driven vehicle first; if that is not an applicator (e.g. a
-- tractor towing a spreader), scans the attacher-joint implement tree.
-- Mirrors the same logic in SoilHUD:getCurrentSprayer so both the HUD panel
-- and the key callbacks always agree on which vehicle the rate belongs to.
local function getApplicatorVehicle()
    local v = getPlayerVehicle()
    if not v then return nil end

    -- Direct (self-propelled): liquid sprayer, air seeder, etc.
    if SoilFertilityManager.isFertilizerApplicator(v) then
        return v
    end

    -- Pulled implement: walk the attacher-joint tree
    local function scanImpls(root)
        local ok, spec = pcall(function() return root.spec_attacherJoints end)
        if not ok or not spec then return nil end
        local ok2, impls = pcall(function() return spec.attachedImplements end)
        if not ok2 or not impls then return nil end
        for _, impl in pairs(impls) do
            local obj = impl.object
            if obj then
                if SoilFertilityManager.isFertilizerApplicator(obj) then
                    return obj
                end
                local found = scanImpls(obj)
                if found then return found end
            end
        end
        return nil
    end
    return scanImpls(v)
end

function SoilFertilityManager:onSprayerRateUpInput()
    local vehicle = getApplicatorVehicle()
    if not vehicle then return end
    local rm = self.sprayerRateManager
    if rm then
        local newIdx = rm:cycleUp(vehicle.id)
        SoilLogger.debug("Rate UP input: vehicle %d, new index %d (multiplier %.2f)",
            vehicle.id, newIdx, rm:getMultiplier(vehicle.id))
        if SoilNetworkEvents_SendSprayerRate then
            SoilNetworkEvents_SendSprayerRate(vehicle, newIdx)
        end
    end
end

function SoilFertilityManager:onSprayerRateDownInput()
    local vehicle = getApplicatorVehicle()
    if not vehicle then return end
    local rm = self.sprayerRateManager
    if rm then
        local newIdx = rm:cycleDown(vehicle.id)
        SoilLogger.debug("Rate DOWN input: vehicle %d, new index %d (multiplier %.2f)",
            vehicle.id, newIdx, rm:getMultiplier(vehicle.id))
        if SoilNetworkEvents_SendSprayerRate then
            SoilNetworkEvents_SendSprayerRate(vehicle, newIdx)
        end
    end
end

function SoilFertilityManager:onToggleAutoInput()
    local vehicle = getApplicatorVehicle()
    if not vehicle then return end
    if not self.settings.autoRateControl then return end
    local rm = self.sprayerRateManager
    if rm then
        local newState = rm:toggleAutoMode(vehicle.id)
        SoilNetworkEvents_SendSprayerAutoMode(vehicle, newState)
    end
end

function SoilFertilityManager:onCycleMapLayerInput()
    if self.soilMapOverlay then
        self.soilMapOverlay:cycleLayer()
    end
end

-- Input callback for Soil Cell Map dialog (Shift+S)
function SoilFertilityManager:onToggleCellMapInput()
    if self.soilMapCellDialog and g_gui then
        if g_gui.currentGui ~= nil then
            if g_gui.currentGui.name == "SoilMapCellDialog" then
                g_gui:closeDialogByName("SoilMapCellDialog")
            end
        else
            g_gui:showDialog("SoilMapCellDialog")
        end
    end
end

--- Helper function to determine if a vehicle is a fertilizer applicator (sprayer, spreader, planter)
--- This includes vehicles with spec_sprayer or vehicles with fill units whose SUPPORTED fill types
--- include any type belonging to the mod's SPREADER or SPRAYER categories.
---
--- FIX (Issue #1 / Issue #2):
---   Previously this checked fillUnit.fillTypeIndex (the *currently loaded* fill type) and
---   workArea:getIsActive() (only true while physically working a field). Both are always wrong
---   at vehicle-enter time:
---     - fillTypeIndex is 0/FT_UNKNOWN when the spreader is empty → category check fails → no rate UI
---     - getIsActive() is always false at enter time → entire spreader branch was dead code
---   The fix iterates fillUnit.supportedFillTypes (the static set of types the fill unit can hold,
---   registered at mission load time) and removes the isWorkAreaActive gate entirely.
---   This correctly identifies spreaders as fertilizer applicators regardless of their current
---   fill level, which also resolves the fill-acceptance detection used downstream.
---@param vehicle table The vehicle object to check
---@return boolean True if the vehicle is a fertilizer applicator, false otherwise.
function SoilFertilityManager.isFertilizerApplicator(vehicle)
    if not vehicle then
        return false
    end

    -- Return cached result if we've already checked this vehicle
    if vehicle._sfIsApplicator ~= nil then
        return vehicle._sfIsApplicator
    end

    local isApplicator = false

    -- Fast path: check for dedicated applicator specializations.
    -- All of these are set at vehicle load time and are always reliable even when empty.
    --   spec_sprayer              → liquid sprayers (Patriot 50, anhydrous applicators, etc.)
    --   spec_manureSpreader       → solid/liquid manure spreaders, lime spreaders
    --   spec_slurryTanker         → slurry / liquid manure tankers
    --   spec_limeSpreader         → dedicated lime spreader spec (some mods)
    --   spec_fertilizingCultivator  → cultivators that also apply fertilizer/herbicide
    --   spec_fertilizingSowingMachine → seeders that apply starter fertilizer in-furrow
    --   spec_manureBarrel         → backpack/small barrel sprayers
    if vehicle.spec_sprayer
    or vehicle.spec_manureSpreader
    or vehicle.spec_slurryTanker
    or vehicle.spec_limeSpreader
    or vehicle.spec_fertilizingCultivator
    or vehicle.spec_fertilizingSowingMachine
    or vehicle.spec_manureBarrel then
        isApplicator = true
    else
        -- Slow path: applicators whose specialization we don't directly recognize.
        -- Checks whether any supported fill type is one our system tracks in FERTILIZER_PROFILES.
        --
        -- IMPORTANT guard: also require spec_workArea.
        -- All implements that ACTIVELY apply material to the ground have spec_workArea
        -- (sprayers, spreaders, cultivators, seeders). Transport wagons, grain trailers,
        -- overload belts, and auger wagons do NOT have spec_workArea even when they
        -- support fill types like LIME or POTASH (e.g., via category mods like
        -- FS25_0_THDefaultTypes adding LIME to the BULK fill type category).
        -- This guard eliminates false positives from transport equipment.
        if vehicle.spec_workArea and vehicle.spec_fillUnit and g_fillTypeManager then
            local fillUnits = vehicle.spec_fillUnit.fillUnits
            if fillUnits then
                for _, fillUnit in ipairs(fillUnits) do
                    if fillUnit.supportedFillTypes then
                        for fillTypeIndex, supported in pairs(fillUnit.supportedFillTypes) do
                            if supported then
                                local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                                if ft and ft.name and SoilConstants.FERTILIZER_PROFILES[ft.name] then
                                    isApplicator = true
                                    break
                                end
                            end
                        end
                    end
                    if isApplicator then break end
                end
            end
        end
    end

    vehicle._sfIsApplicator = isApplicator
    return isApplicator
end

--- Save soil data to XML file
--- Only runs on server in multiplayer, always in singleplayer
--- Saves to {savegame}/soilData.xml
function SoilFertilityManager:saveSoilData()
    if not self.soilSystem then
        SoilLogger.error("saveSoilData: soilSystem is nil")
        return
    end
    if not g_currentMission or not g_currentMission.missionInfo then
        SoilLogger.error("saveSoilData: missionInfo is nil")
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if not savegamePath then
        SoilLogger.error("saveSoilData: savegameDirectory is nil")
        return
    end

    -- Count fields with data
    local fieldCount = 0
    if self.soilSystem.fieldData then
        for _ in pairs(self.soilSystem.fieldData) do fieldCount = fieldCount + 1 end
    end

    local xmlPath = savegamePath .. "/soilData.xml"
    local xmlFile = createXMLFile("soilData", xmlPath, "soilData")

    if xmlFile then
        self.soilSystem:saveToXMLFile(xmlFile, "soilData")
        setXMLString(xmlFile, "soilData#lastSeenVersion", self.lastSeenVersion or "")
        saveXMLFile(xmlFile)
        delete(xmlFile)
        SoilLogger.info("Soil data saved to %s (%d fields)", xmlPath, fieldCount)
    else
        SoilLogger.error("Failed to create XML file for save: %s", xmlPath)
    end
end

--- Load soil data from XML file
--- Reads from {savegame}/soilData.xml if exists
--- Falls back to defaults if file not found
function SoilFertilityManager:loadSoilData()
    if not self.soilSystem then
        SoilLogger.error("loadSoilData: soilSystem is nil")
        return
    end
    if not g_currentMission or not g_currentMission.missionInfo then
        SoilLogger.error("loadSoilData: missionInfo is nil")
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if not savegamePath then
        SoilLogger.warning("loadSoilData: savegameDirectory not set yet (new career or early load) — starting with defaults")
        return
    end

    local xmlPath = savegamePath .. "/soilData.xml"
    if fileExists(xmlPath) then
        local xmlFile = loadXMLFile("soilData", xmlPath)
        if xmlFile then
            self.soilSystem:loadFromXMLFile(xmlFile, "soilData")
            self.lastSeenVersion = getXMLString(xmlFile, "soilData#lastSeenVersion") or ""
            delete(xmlFile)
            local fieldCount = 0
            if self.soilSystem.fieldData then
                for _ in pairs(self.soilSystem.fieldData) do fieldCount = fieldCount + 1 end
            end
            SoilLogger.info("Soil data loaded from %s (%d fields)", xmlPath, fieldCount)
        else
            SoilLogger.error("loadSoilData: loadXMLFile returned nil for: %s", xmlPath)
        end
    else
        SoilLogger.info("No saved soil data found at %s, using defaults", xmlPath)
    end
end

--- Update loop called every frame
---@param dt number Delta time in milliseconds
function SoilFertilityManager:update(dt)
    -- Always update soil system (server side)
    if self.soilSystem then
        self.soilSystem:update(dt)
    end

    if self.soilReportDialog then
        self.soilReportDialog:update(dt)
    end

    -- FIX: Only update HUD if it exists (client side only)
    if self.soilHUD then
        -- Add pcall to prevent crashes if HUD has issues
        local success, err = pcall(function()
            self.soilHUD:update(dt)
        end)
        if not success then
            SoilLogger.warning("HUD update error: %s", tostring(err))
        end
    end

    -- Settings panel camera-lock and cursor keepalive
    if self.settingsPanel then
        self.settingsPanel:update()
    end

    -- Auto-rate control: adjust sprayer rate based on current field soil data
    self:updateAutoRates(dt)
end

--- Auto-rate control update — throttled, client-side only.
--- Reads the current field soil data and the loaded fill type, then computes the
--- optimal sprayer rate index via calculateAutoRateIndex.  Sends a network rate
--- event only when the index actually changes to avoid unnecessary traffic.
---@param dt number Delta time in milliseconds
function SoilFertilityManager:updateAutoRates(dt)
    -- Only meaningful on clients with the setting enabled
    if not self.settings or not self.settings.autoRateControl then return end
    if not g_currentMission or not g_currentMission:getIsClient() then return end

    -- Throttle to 5-second intervals (5000 ms)
    self._autoRateTimer = self._autoRateTimer + dt
    if self._autoRateTimer < 5000 then return end
    self._autoRateTimer = 0

    -- Need HUD for fill-type and field-id access (client-only objects)
    if not self.soilHUD then return end

    -- Find the player's active applicator vehicle
    local vehicle = getApplicatorVehicle()
    if not vehicle then return end

    -- Only act when auto mode is engaged for this vehicle
    local rm = self.sprayerRateManager
    if not rm or not rm:getAutoMode(vehicle.id) then return end

    -- Use the HUD's cached field id (updated every frame in SoilHUD:update)
    local fieldId = self.soilHUD.cachedFieldId
    if not fieldId or fieldId <= 0 then return end

    -- Retrieve live soil data for this field
    if not self.soilSystem then return end
    local fieldData = self.soilSystem:getFieldInfo(fieldId)
    if not fieldData then return end

    -- Get the fill type currently loaded in the vehicle
    local fillType = self.soilHUD:getSprayerFillType(vehicle)
    if not fillType then return end

    -- Calculate the ideal index and send if it changed
    local newIdx = self:calculateAutoRateIndex(fieldData, fillType)
    local currentIdx = rm:getIndex(vehicle.id)
    if newIdx ~= currentIdx then
        rm:setIndex(vehicle.id, newIdx)
        if SoilNetworkEvents_SendSprayerRate then
            SoilNetworkEvents_SendSprayerRate(vehicle, newIdx)
        end
        SoilLogger.debug(
            "Auto-rate: vehicle %d → index %d (%.2fx) [%s on field %d]",
            vehicle.id, newIdx,
            SoilConstants.SPRAYER_RATE.STEPS[newIdx],
            fillType.name, fieldId)
    end
end

--- Calculate the optimal sprayer rate index for a given field state and fill type.
--- Uses the fertilizer profile's per-nutrient contribution values as weights,
--- computing a weighted average of nutrient deficit fractions, then maps that
--- fraction linearly to the safe rate range 0.20x–1.20x (indices 2–12).
---
--- Crop-protection products (INSECTICIDE, FUNGICIDE, HERBICIDE/PESTICIDE) use
--- the relevant pressure value instead of nutrient deficits.
---
--- Shape Contract: `fieldData` must be the output of `SoilFertilitySystem:getFieldInfo()`.
--- Expected fields: `nitrogen.value`, `phosphorus.value`, `potassium.value`, `pH`, `organicMatter`,
--- `pestPressure` (number), `diseasePressure` (number), `weedPressure` (number).
---
--- The cap of 1.20x keeps the rate below BURN_RISK_THRESHOLD (1.25x) even when
--- the field is completely depleted, protecting the player from accidental burns.
---
---@param fieldData table  Return value of SoilFertilitySystem:getFieldInfo()
---@param fillType  table  FillType object (has .name string)
---@return number          1-based index into SoilConstants.SPRAYER_RATE.STEPS
function SoilFertilityManager:calculateAutoRateIndex(fieldData, fillType)
    local steps   = SoilConstants.SPRAYER_RATE.STEPS
    local targets = SoilConstants.SPRAYER_RATE.AUTO_RATE_TARGETS
    local limits  = SoilConstants.NUTRIENT_LIMITS
    local phMin   = limits and limits.PH_MIN or 5.0

    -- Safe multiplier bounds — never exceed BURN_RISK_THRESHOLD
    local MULT_MIN = 0.20
    local MULT_MAX = 1.20

    local multiplier = 1.0  -- default fallback

    local profile = SoilConstants.FERTILIZER_PROFILES[fillType.name]

    if profile then
        if profile.pestReduction then
            -- Insecticide: scale with pest pressure (full pressure → 1.0x, no pressure → 0.20x)
            local pressure = fieldData.pestPressure or 0
            multiplier = math.max(MULT_MIN, math.min(1.0, pressure / 100))

        elseif profile.diseaseReduction then
            -- Fungicide: scale with disease pressure
            local pressure = fieldData.diseasePressure or 0
            multiplier = math.max(MULT_MIN, math.min(1.0, pressure / 100))

        else
            -- Nutrient fertilizer: weighted deficit across profile nutrients
            local totalWeight     = 0
            local weightedDeficit = 0

            if profile.N and profile.N > 0 then
                local deficit = math.max(0, targets.N - fieldData.nitrogen.value) / targets.N
                weightedDeficit = weightedDeficit + deficit * profile.N
                totalWeight     = totalWeight     + profile.N
            end
            if profile.P and profile.P > 0 then
                local deficit = math.max(0, targets.P - fieldData.phosphorus.value) / targets.P
                weightedDeficit = weightedDeficit + deficit * profile.P
                totalWeight     = totalWeight     + profile.P
            end
            if profile.K and profile.K > 0 then
                local deficit = math.max(0, targets.K - fieldData.potassium.value) / targets.K
                weightedDeficit = weightedDeficit + deficit * profile.K
                totalWeight     = totalWeight     + profile.K
            end
            if profile.pH and profile.pH > 0 then
                -- pH: how far below target (7.0) normalised to the possible range [5.0, 7.0]
                local phRange = targets.pH - phMin
                if phRange > 0 then
                    local deficit = math.max(0, targets.pH - fieldData.pH) / phRange
                    weightedDeficit = weightedDeficit + deficit * profile.pH
                    totalWeight     = totalWeight     + profile.pH
                end
            end
            if profile.OM and profile.OM > 0 then
                local deficit = math.max(0, targets.OM - fieldData.organicMatter) / targets.OM
                weightedDeficit = weightedDeficit + deficit * profile.OM
                totalWeight     = totalWeight     + profile.OM
            end

            if totalWeight > 0 then
                -- Map [0, 1] deficit fraction → [0.20, 1.20] multiplier
                local deficitFraction = weightedDeficit / totalWeight
                multiplier = MULT_MIN + deficitFraction * (MULT_MAX - MULT_MIN)
                SoilLogger.debug(
                    "Auto-rate calc: %s | deficit=%.3f | target multiplier=%.3f",
                    fillType.name, deficitFraction, multiplier)
            end
        end

    else
        -- Not in FERTILIZER_PROFILES — check if it is a herbicide type
        local herbTypes = SoilConstants.WEED_PRESSURE and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES
        if herbTypes and herbTypes[fillType.name] then
            local pressure = fieldData.weedPressure or 0
            multiplier = math.max(MULT_MIN, math.min(1.0, pressure / 100))
        end
        -- Unknown product type: leave at 1.0 (no adjustment)
    end

    -- Clamp to safe range before finding closest step
    multiplier = math.max(MULT_MIN, math.min(MULT_MAX, multiplier))

    -- Find the closest STEPS index to the desired multiplier
    local bestIdx  = SoilConstants.SPRAYER_RATE.DEFAULT_INDEX
    local bestDiff = math.huge
    for i, step in ipairs(steps) do
        local diff = math.abs(step - multiplier)
        if diff < bestDiff then
            bestDiff = diff
            bestIdx  = i
        end
    end
    return bestIdx
end

--- Cleanup on mod unload
--- Saves soil data and uninstalls hooks
function SoilFertilityManager:delete()
    -- Flush any buffered debug messages to file before shutdown
    SoilLogger.flushDebugLog()
    -- Save soil data before shutdown
    self:saveSoilData()

    -- Restore PlayerInputComponent hook if we installed one
    if self._inputHookOriginal and PlayerInputComponent then
        PlayerInputComponent.registerActionEvents = self._inputHookOriginal
        self._inputHookOriginal = nil
        SoilLogger.debug("PlayerInputComponent hook restored")
    end

    -- Restore InputBinding.endActionEventsModification hook if we installed one
    if self._vehicleInputHookOriginal and InputBinding then
        InputBinding.endActionEventsModification = self._vehicleInputHookOriginal
        self._vehicleInputHookOriginal = nil
        SoilLogger.debug("InputBinding.endActionEventsModification hook restored")
    end

    -- Clean up sprayer rate state
    if self.sprayerRateManager then
        self.sprayerRateManager:delete()
        self.sprayerRateManager = nil
    end

    -- Clean up all registered input action events (PLAYER context)
    if self.toggleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleHUDEventId)
        self.toggleHUDEventId = nil
    end

    if self.soilReportEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.soilReportEventId)
        self.soilReportEventId = nil
    end

    -- Clean up VEHICLE context events
    if self.vehicleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleHUDEventId)
        self.vehicleHUDEventId = nil
    end

    if self.vehicleReportEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleReportEventId)
        self.vehicleReportEventId = nil
    end

    if self.rateUpEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.rateUpEventId)
        self.rateUpEventId = nil
    end

    if self.rateDownEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.rateDownEventId)
        self.rateDownEventId = nil
    end

    if self.toggleAutoEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleAutoEventId)
        self.toggleAutoEventId = nil
    end

    if self.cycleMapLayerEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.cycleMapLayerEventId)
        self.cycleMapLayerEventId = nil
    end

    if self.hudDragEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.hudDragEventId)
        self.hudDragEventId = nil
    end

    if self.vehicleHudDragEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleHudDragEventId)
        self.vehicleHudDragEventId = nil
    end

    if self.settingsPanelEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.settingsPanelEventId)
        self.settingsPanelEventId = nil
    end

    if self.vehicleSettingsPanelEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleSettingsPanelEventId)
        self.vehicleSettingsPanelEventId = nil
    end

    if self.toggleCellMapEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleCellMapEventId)
        self.toggleCellMapEventId = nil
    end

    if self.vehicleCellMapEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleCellMapEventId)
        self.vehicleCellMapEventId = nil
    end

    if self.soilReportDialog then
        if g_gui then g_gui:closeDialogByName("SoilReportDialog") end
        self.soilReportDialog = nil
        SoilReportDialog.instance = nil
    end

    if self.soilMapOverlay then
        self.soilMapOverlay:delete()
        self.soilMapOverlay = nil
    end

    if self.soilHUD then
        self.soilHUD:saveLayout()
        self.soilHUD:delete()
        self.soilHUD = nil
    end

    if self.settingsPanel then
        self.settingsPanel:delete()
        self.settingsPanel = nil
    end

    if self.soilSystem then
        self.soilSystem:delete()
    end
    if self.settings then
        self.settings:save()
    end
    SoilLogger.info("Shutting down")
end