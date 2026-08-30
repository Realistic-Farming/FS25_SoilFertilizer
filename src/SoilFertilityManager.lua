-- 2026-08-22 (Wizard): with MasterHUD installed this mod's own HUD hide/move keys must not
-- merely be inert, they must not REGISTER at all - that is what removes their rows from the
-- F1 legend and the Controls list. Probed on TaxMod first: skipping registration does remove
-- the row, so the pattern is used suite-wide. Only HUD hide/move actions are gated; every
-- other action this mod registers is untouched.
local function __rfMhOwnsHudKeys()
    return ((g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD) ~= nil
end

-- =========================================================
-- FS25 Realistic Soil & Fertilizer (FarmlandManager version)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- COPYRIGHT NOTICE: All rights reserved.
-- =========================================================
---@class SoilFertilityManager
SoilFertilityManager = SoilFertilityManager or {}
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

    -- PF detector (holds detection state; initialize() runs in the deferred init phase)
    self.pfBridge = PrecisionFarmingBridge and PrecisionFarmingBridge:new() or nil
    self.hasPrecisionFarming = false

    -- Settings
    if not Settings then
        SoilLogger.error("CRITICAL: Settings not loaded - check source order in main.lua")
        return nil
    end
    if not SettingsManager then
        SoilLogger.error("CRITICAL: SettingsManager not loaded - check source order in main.lua")
        return nil
    end
    self.settingsManager = SettingsManager.new()
    self.settings = Settings.new(self.settingsManager)

    -- Soil system
    if not SoilFertilitySystem then
        SoilLogger.error("CRITICAL: SoilFertilitySystem not loaded - mod cannot initialize")
        if g_gui then
            InfoDialog.show("Soil & Fertilizer Mod failed to load.\n\nCritical module 'SoilFertilitySystem' is missing.\n\nPlease reinstall the mod or check for conflicts with other mods.", nil, nil)
        end
        return nil
    end
    self.soilSystem = SoilFertilitySystem.new(self.settings)

    -- SF-18 establishment failure (the keystone): driven by the sowing chain
    -- and the daily pass; consumes SCS positional moisture (absent = inert).
    self.establishment = EstablishmentFailure and EstablishmentFailure.new(self) or nil

    -- SF-52 v1 the viability mask: reads the soil's own data per period and
    -- publishes getCellGrowthInfo / getFieldGrowthSummary, the contract SF-53,
    -- SF-54 and SCS-020 all bind to. No engine write in v1 (that is v2, held).
    self.viability = ViabilityMask and ViabilityMask.new(self) or nil
    -- The published surface for the getters lives on this manager, not on the
    -- `viability` field: see getCellGrowthInfo / getFieldGrowthSummary below.

    -- SF-53 GROWTH CREDIT: the reward half of the SF-2M pair. A daily
    -- bookkeeper counts days of excellence; the period hand advances credit
    -- cells one step at the drained FINISHED_GROWTH_PERIOD delivery, bucketed
    -- on the engine's own fruit plane. Inert unless the growth_modulation
    -- release gate is open and the mask is enabled.
    self.growthCredit = GrowthCredit and GrowthCredit.new(self) or nil

    -- SF-78 GROWTH BLOCK: the hold half of the SF-2M pair. Capture at
    -- START_GROWTH_PERIOD, restore at the drained FINISHED delivery through
    -- the family write machine; blocked cells fall behind the field. Inert
    -- unless the growth_modulation release gate is open and the mask enabled.
    self.growthBlock = GrowthBlock and GrowthBlock.new(self) or nil

    -- SF-14 ZONE YIELD: the payout half of the SF-2M family. Per-cell
    -- yieldEfficiency capture at growth time (riding the family's shared
    -- read) and the area-weighted harvest read that supersedes the SF-16
    -- scalar freeze on the spatial path. Inert unless the growth_modulation
    -- release gate is open and the mask enabled.
    self.zoneYield = ZoneYield and ZoneYield.new(self) or nil

    -- SF-77 TOPOGRAPHY CACHE: the load-time terrain grid (height, slope, sink,
    -- distance-to-water). Built once at activation, invalidated on terrain
    -- edits, consumed by SF-76 (field genesis) and SCS-042 (runoff). Neutral
    -- until a consumer wires in.
    self.topography = TopographyCache and TopographyCache.new(self) or nil

    -- Organic certification: per-field state layer over the soil substrate.
    self.organic = OrganicCertification and OrganicCertification.new(self.soilSystem) or nil

    -- Sprayer rate manager (always active - not GUI-dependent)
    self.sprayerRateManager = SprayerRateManager.new()
    self._autoRateTimer = 0  -- throttle timer for auto-rate updates

    -- Smart Sensor manager (always active - tracks per-vehicle sensor states)
    self.sensorManager = SoilSensorManager and SoilSensorManager.new() or nil

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
    if self.organic then
        self.organic:registerConsoleCommands()
    end

    -- HUD (client only)
    if shouldInitGUI then
        if not SoilHUD then
            SoilLogger.error("CRITICAL: SoilHUD not loaded - HUD will be disabled")
            if g_gui then
                InfoDialog.show("Soil & Fertilizer Mod: HUD module failed to load.\n\nThe mod will run without the HUD display.\n\nCore features remain active.")
            end
            self.soilHUD = nil
        else
            self.soilHUD = SoilHUD.new(self.soilSystem, self.settings)
            SoilLogger.info("Soil HUD created")
        end

        -- Field Detail dialog (opened from PDA Screen fields list)
        if SoilFieldDetailDialog and g_gui then
            SoilFieldDetailDialog.register(modDirectory)
            SoilLogger.info("Soil Field Detail dialog registered")
        end

        -- Rotation Planner dialog (Wizard UI brief #739; PDA EXTRA_2)
        if RotationPlannerDialog and g_gui then
            RotationPlannerDialog.register(modDirectory)
            SoilLogger.info("Rotation Planner dialog registered")
        end

        -- Treatment Detail dialog (hotkey / underfoot; PDA Treatment tab uses inline pane)
        if SoilTreatmentDialog and g_gui then
            SoilTreatmentDialog.register(modDirectory)
            SoilLogger.info("Soil Treatment dialog registered")
        end

        -- Field Scout dialog (opened from the SF_SCOUT hotkey)
        if SoilScoutDialog and g_gui then
            SoilScoutDialog.register(modDirectory)
            SoilLogger.info("Soil Scout dialog registered")
        end

        -- [SF-39] The Handful panel (opened from the SF_HANDFUL hotkey, kneeling only)
        if SoilHandfulDialog and g_gui then
            SoilHandfulDialog.register(modDirectory)
            SoilLogger.info("Soil Handful panel registered")
        end

        -- Version/changelog dialog (shown once per version on load)
        if SoilVersionDialog and g_gui then
            SoilVersionDialog.register(modDirectory)
            SoilLogger.info("Soil Version dialog registered")
        end

        -- PDA help dialog (legacy - kept for backward compat)
        if SoilHelpDialog and g_gui then
            SoilHelpDialog.register(modDirectory)
            SoilLogger.info("Soil Help dialog registered")
        end

        -- Multi-page field guide (opened from PDA Help button)
        if SoilGuideDialog and g_gui then
            SoilGuideDialog.register(modDirectory)
            SoilLogger.info("Soil Guide dialog registered")
        end

        -- Release gate dialog (opened from the version/changelog dialog)
        if SoilReleaseDialog and g_gui then
            SoilReleaseDialog.register(modDirectory)
            SoilLogger.info("Soil Release dialog registered")
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

        -- DMV minimap heatmap layer (client only)
        if SoilMinimapLayer then
            self.soilMinimapLayer = SoilMinimapLayer.new(self.soilSystem, self.settings)
            SoilLogger.info("Soil Minimap Layer created (init deferred to onMissionStarted)")
        end


        -- Settings panel (SHIFT+O)
        if SoilSettingsPanel then
            self.settingsPanel = SoilSettingsPanel.new(self.settings)
            SoilLogger.info("Settings panel created")
        end

        -- Constants Tuning Editor (opened from admin settings page)
        if SoilTuningPanel then
            self.tuningPanel = SoilTuningPanel.new(self.settings)
            SoilLogger.info("Tuning panel created")
        end

        -- Crop Tuning Editor (per-crop N/P/K, issue #717) + its data layer
        if SoilCropTuning then
            self.cropTuning = SoilCropTuning.new(self.settings)
        end
        if SoilCropTuningPanel then
            self.cropTuningPanel = SoilCropTuningPanel.new(self.settings, self.cropTuning)
            SoilLogger.info("Crop tuning panel created")
        end

        -- Variable Rate panel (System 3)
        if SoilVariableRatePanel then
            self.variableRatePanel = SoilVariableRatePanel.new(self.soilSystem, self.settings)
            SoilLogger.info("Variable Rate panel created")
        end
        -- Smart Sensor panel (See & Spray status)
        if SoilSmartSensorPanel then
            self.smartSensorPanel = SoilSmartSensorPanel.new(self.soilSystem, self.settings)
            SoilLogger.info("Smart Sensor panel created")
        end
        -- Sprayer Info panel (gap view)
        if SoilSprayerInfoPanel then
            self.sprayerInfoPanel = SoilSprayerInfoPanel.new(self.soilSystem, self.settings)
            SoilLogger.info("Sprayer Info panel created")
        end
        -- Harvester panel (grain tank + yield info)
        if SoilHarvesterPanel then
            self.harvesterPanel = SoilHarvesterPanel.new(self.soilSystem, self.settings)
            SoilLogger.info("Harvester panel created")
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

                local hudOk, hudId = false, nil
                if not __rfMhOwnsHudKeys() then
                    local hudOk, hudId = g_inputBinding:registerActionEvent(
                        InputAction.SF_TOGGLE_HUD, g_SoilFertilityManager,
                        g_SoilFertilityManager.onToggleHUDInput,
                        false, true, false, true
                    )
                end
                if hudOk and hudId then
                    g_SoilFertilityManager.toggleHUDEventId = hudId
                    SoilLogger.info("HUD toggle (J) registered in PLAYER context")
                else
                    SoilLogger.warning("HUD toggle (J) PLAYER registration failed")
                end

                -- Map layer cycle (Shift+M) - registered in PLAYER context only
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

                -- Settings panel (Shift+O) - registered in PLAYER context
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

                -- HUD drag toggle (SF_HUD_DRAG, default Shift+H) - PLAYER context
                if g_SoilFertilityManager.soilHUD then
                    local dragOk, dragId = false, nil
                    if not __rfMhOwnsHudKeys() then
                        local dragOk, dragId = g_inputBinding:registerActionEvent(
                            InputAction.SF_HUD_DRAG, g_SoilFertilityManager,
                            g_SoilFertilityManager.onHUDDragInput,
                            false, true, false, true
                        )
                    end
                    if dragOk and dragId then
                        g_SoilFertilityManager.hudDragEventId = dragId
                        g_inputBinding:setActionEventTextVisibility(dragId, false)
                        SoilLogger.info("HUD drag (Shift+H) registered in PLAYER context")
                    end
                end

                -- Minimap zoom cycle - PLAYER context
                if g_SoilFertilityManager.soilMapOverlay then
                    local zoomOk, zoomId = g_inputBinding:registerActionEvent(
                        InputAction.SF_MINIMAP_ZOOM, g_SoilFertilityManager,
                        g_SoilFertilityManager.onMinimapZoomInput,
                        false, true, false, true
                    )
                    if zoomOk and zoomId then
                        g_SoilFertilityManager.minimapZoomEventId = zoomId
                        g_inputBinding:setActionEventTextVisibility(zoomId, false)
                        SoilLogger.info("Minimap zoom registered in PLAYER context")
                    end
                end

                -- Field scout (SF_SCOUT, default Shift+K) - PLAYER context.
                -- Opens the Scout panel for the field you're standing on.
                if InputAction.SF_SCOUT then
                    local scoutOk, scoutId = g_inputBinding:registerActionEvent(
                        InputAction.SF_SCOUT, g_SoilFertilityManager,
                        g_SoilFertilityManager.onScoutInput,
                        false, true, false, true
                    )
                    if scoutOk and scoutId then
                        g_SoilFertilityManager.scoutEventId = scoutId
                        g_inputBinding:setActionEventTextVisibility(scoutId, false)
                        SoilLogger.info("Field scout (Shift+K) registered in PLAYER context")
                    end
                end

                -- Treatment panel (SF_TREATMENT, default Shift+T) - PLAYER context.
                if InputAction.SF_TREATMENT then
                    local trOk, trId = g_inputBinding:registerActionEvent(
                        InputAction.SF_TREATMENT, g_SoilFertilityManager,
                        g_SoilFertilityManager.onTreatmentInput,
                        false, true, false, true
                    )
                    if trOk and trId then
                        g_SoilFertilityManager.treatmentEventId = trId
                        g_inputBinding:setActionEventTextVisibility(trId, false)
                        SoilLogger.info("Treatment panel (Shift+T) registered in PLAYER context")
                    end
                end

                -- [SF-39] The Handful panel (SF_HANDFUL, default Shift+G) - PLAYER
                -- context. Opens only while crouched; the ladder lives in the callback.
                if InputAction.SF_HANDFUL then
                    local hfOk, hfId = g_inputBinding:registerActionEvent(
                        InputAction.SF_HANDFUL, g_SoilFertilityManager,
                        g_SoilFertilityManager.onHandfulInput,
                        false, true, false, true
                    )
                    if hfOk and hfId then
                        g_SoilFertilityManager.handfulEventId = hfId
                        g_inputBinding:setActionEventTextVisibility(hfId, false)
                        SoilLogger.info("Handful panel (Shift+G) registered in PLAYER context")
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
            -- BUILD 21:38: put an event on the in-cab F1 strip. The engine lists an action
            -- only when it is active, has a binding, and has its text visible. modDesc supplies
            -- the bindings; this supplies the last two. GS_PRIO_HIGH is not decoration: the
            -- strip's normal tier is a handful of slots and the cab set is cut without it.
            local function sfShowOnCabStrip(binding, id)
                if binding == nil or id == nil then
                    return
                end
                if type(binding.setActionEventTextVisibility) == "function" then
                    binding:setActionEventTextVisibility(id, true)
                end
                if GS_PRIO_HIGH ~= nil and type(binding.setActionEventTextPriority) == "function" then
                    binding:setActionEventTextPriority(id, GS_PRIO_HIGH)
                end
            end
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
                -- registrations accumulate - callbacks fire 2-3× per keypress and
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
                    "vehicleHUDEventId",
                    "rateUpEventId",     "rateDownEventId",
                    "toggleAutoEventId", "vehicleSettingsPanelEventId",
                    "vehicleHudDragEventId", "vehicleMinimapZoomEventId",
                    "vehicleCycleMapLayerEventId",
                    "sensorPestEventId", "sensorDiseaseEventId", "sensorNutrientEventId",
                    "seeSprayPestEventId", "seeSprayDiseaseEventId", "seeSprayWeedEventId",
                    "variableRateEventId",
                    -- PLAYER context IDs (invalidated as a side-effect of the above removes)
                    "toggleHUDEventId",
                    "cycleMapLayerEventId", "settingsPanelEventId", "hudDragEventId",
                    "minimapZoomEventId",
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
                local vHudOk, vHudId = false, nil
                if not __rfMhOwnsHudKeys() then
                    local vHudOk, vHudId = binding:registerActionEvent(
                        InputAction.SF_TOGGLE_HUD, g_SoilFertilityManager,
                        g_SoilFertilityManager.onToggleHUDInput,
                        false, true, false, true
                    )
                end
                if vHudOk and vHudId then
                    g_SoilFertilityManager.vehicleHUDEventId = vHudId
                    sfShowOnCabStrip(binding, vHudId)
                    SoilLogger.debug("HUD toggle (J) registered in VEHICLE context")
                end

                -- Rate UP (])
                local upOk, upId = binding:registerActionEvent(
                    InputAction.SF_RATE_UP, g_SoilFertilityManager,
                    g_SoilFertilityManager.onSprayerRateUpInput,
                    false, true, false, true
                )
                if upOk and upId then
                    g_SoilFertilityManager.rateUpEventId = upId
                    sfShowOnCabStrip(binding, upId)
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
                    sfShowOnCabStrip(binding, downId)
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
                    sfShowOnCabStrip(binding, autoId)
                    SoilLogger.debug("Auto toggle (Shift+L) registered in VEHICLE context")
                end

                -- Variable Rate toggle (System 3)
                local vrOk, vrId = binding:registerActionEvent(
                    InputAction.SF_VARIABLE_RATE, g_SoilFertilityManager,
                    g_SoilFertilityManager.onVariableRateInput, false, true, false, true)
                if vrOk and vrId then
                    g_SoilFertilityManager.variableRateEventId = vrId
                    sfShowOnCabStrip(binding, vrId)
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
                        sfShowOnCabStrip(binding, vSpId)
                        SoilLogger.debug("Settings panel (Shift+O) registered in VEHICLE context")
                    end
                end

                -- HUD drag toggle (SF_HUD_DRAG, default Shift+H) - VEHICLE context
                if g_SoilFertilityManager.soilHUD then
                    local vDragOk, vDragId = false, nil
                    if not __rfMhOwnsHudKeys() then
                        local vDragOk, vDragId = binding:registerActionEvent(
                            InputAction.SF_HUD_DRAG, g_SoilFertilityManager,
                            g_SoilFertilityManager.onHUDDragInput,
                            false, true, false, true
                        )
                    end
                    if vDragOk and vDragId then
                        g_SoilFertilityManager.vehicleHudDragEventId = vDragId
                        sfShowOnCabStrip(binding, vDragId)
                        SoilLogger.debug("HUD drag (Shift+H) registered in VEHICLE context")
                    end
                end

                -- Minimap zoom cycle - VEHICLE context (minimap is visible while driving)
                if g_SoilFertilityManager.soilMapOverlay then
                    local vZoomOk, vZoomId = binding:registerActionEvent(
                        InputAction.SF_MINIMAP_ZOOM, g_SoilFertilityManager,
                        g_SoilFertilityManager.onMinimapZoomInput,
                        false, true, false, true
                    )
                    if vZoomOk and vZoomId then
                        g_SoilFertilityManager.vehicleMinimapZoomEventId = vZoomId
                        binding:setActionEventTextVisibility(vZoomId, false)
                        SoilLogger.debug("Minimap zoom registered in VEHICLE context")
                    end
                end

                -- Map layer cycle - VEHICLE context (#609: minimap layers visible while driving)
                if g_SoilFertilityManager.soilMapOverlay then
                    local vMapOk, vMapId = binding:registerActionEvent(
                        InputAction.SF_CYCLE_MAP_LAYER, g_SoilFertilityManager,
                        g_SoilFertilityManager.onCycleMapLayerInput,
                        false, true, false, true
                    )
                    if vMapOk and vMapId then
                        g_SoilFertilityManager.vehicleCycleMapLayerEventId = vMapId
                        sfShowOnCabStrip(binding, vMapId)
                        SoilLogger.debug("Map layer cycle registered in VEHICLE context")
                    end
                end

                binding:endActionEventsModification()

                -- Re-register PLAYER context events. These were invalidated above when we
                -- called removeActionEvent on the vehicle IDs for the same InputActions.
                -- PlayerInputComponent.registerActionEvents will NOT fire again on vehicle
                -- exit (the PLAYER context is reused, not recreated), so we must do this here.
                binding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

                local pHudOk, pHudId = false, nil
                if not __rfMhOwnsHudKeys() then
                    local pHudOk, pHudId = binding:registerActionEvent(
                        InputAction.SF_TOGGLE_HUD, g_SoilFertilityManager,
                        g_SoilFertilityManager.onToggleHUDInput,
                        false, true, false, true
                    )
                end
                if pHudOk and pHudId then
                    g_SoilFertilityManager.toggleHUDEventId = pHudId
                    SoilLogger.debug("HUD toggle (J) re-registered in PLAYER context after vehicle exit")
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
                    local pDragOk, pDragId = false, nil
                    if not __rfMhOwnsHudKeys() then
                        local pDragOk, pDragId = binding:registerActionEvent(
                            InputAction.SF_HUD_DRAG, g_SoilFertilityManager,
                            g_SoilFertilityManager.onHUDDragInput,
                            false, true, false, true
                        )
                    end
                    if pDragOk and pDragId then
                        g_SoilFertilityManager.hudDragEventId = pDragId
                        binding:setActionEventTextVisibility(pDragId, false)
                        SoilLogger.debug("HUD drag (Shift+H) re-registered in PLAYER context after vehicle exit")
                    end
                end

                if g_SoilFertilityManager.soilMapOverlay then
                    local pZoomOk, pZoomId = binding:registerActionEvent(
                        InputAction.SF_MINIMAP_ZOOM, g_SoilFertilityManager,
                        g_SoilFertilityManager.onMinimapZoomInput,
                        false, true, false, true
                    )
                    if pZoomOk and pZoomId then
                        g_SoilFertilityManager.minimapZoomEventId = pZoomId
                        binding:setActionEventTextVisibility(pZoomId, false)
                        SoilLogger.debug("Minimap zoom re-registered in PLAYER context after vehicle exit")
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
                SoilLogger.info("RealisticHarvesting detected - harvest hooks appended safely; soil updates fire if FruitUtil still present")
            elseif lowerName:find("croprotation") or lowerName:find("crop_rotation") then
                SoilLogger.info("CropRotation detected - no conflict; separate crop tracking data")
            elseif lowerName:find("bettercontracts") then
                SoilLogger.info("BetterContracts detected - profile-based UI creation ensures no settings page corruption")
            elseif lowerName:find("mudsystem") or lowerName:find("mud_system") or lowerName:find("mudphysic") then
                SoilLogger.info("MudSystem/terrain mod detected - no conflict with soil nutrients")
            end
        end
    end

    return self
end

--- Called after mission is loaded (loadMission00Finished).
--- Initializes HUD and settings panel - fields not yet guaranteed populated at this point.
function SoilFertilityManager:onMissionLoaded()
    if not self.settings.enabled then return end

    local success, errorMsg = pcall(function()
        if self.soilHUD then
            self.soilHUD:initialize()
        end

        if self.settingsPanel then
            self.settingsPanel:initialize()
        end

        if self.tuningPanel then
            self.tuningPanel:initialize()
        end

        if self.cropTuningPanel then
            self.cropTuningPanel:initialize()
        end

        if self.variableRatePanel then
            self.variableRatePanel:initialize()
        end
        if self.smartSensorPanel then
            self.smartSensorPanel:initialize()
        end
        if self.sprayerInfoPanel then
            self.sprayerInfoPanel:initialize()
        end
        if self.harvesterPanel then
            self.harvesterPanel:initialize()
        end
    end)

    if not success then
        SoilLogger.error("Error during mission load - %s", tostring(errorMsg))
        self.settings.enabled = false
        self.settings:save()
    end
end

--- Bring the live soil system fully online: sim core, minimap heatmap, per-crop tuning,
--- saved field data, and derived zone/GRLE state. onMissionStarted calls this once fields
--- are populated; consoleCommandSoilEnable calls it too so re-enabling mid-session restores
--- the monitor AND the minimap layer AND field data - not just the sim core. That gap is why
--- a save that loaded with the mod disabled stayed half-dead after SoilEnable (minimap layer
--- and field data never re-initialized). Each subsystem rebuilds its own state, so a repeat
--- call is safe. Guarded so a subsystem error can't propagate (notably it must NOT bubble up
--- to the load() catch that persists enabled=false).
function SoilFertilityManager:activateSoilSystem()
    if not self.soilSystem then return end

    local ok, err = pcall(function()
        self.soilSystem:initialize()

        -- SF-18 establishment failure: initialize + register the daily kill with
        -- Time Guard (simulation flow) when present; SF's own day pass is the
        -- fallback cadence. Server-only by the density write's nature.
        if self.establishment then
            self.establishment:initialize()
            if g_server ~= nil then
                self.establishment:registerDailyAccrual()
            end
        end

        -- SF-52 v1 viability mask: same shape, priority 96 so its pass runs
        -- after the moisture store has settled and after establishment has
        -- counted the dead. Server-authoritative: the pass reads server truth
        -- and the published getters are answered from it.
        if self.viability then
            self.viability:initialize()
            if g_server ~= nil then
                self.viability:registerDailyAccrual()
            end
        end

        -- SF-53 GROWTH CREDIT: initialize + register both clocks (the daily
        -- bookkeeper with Time Guard, the period bell with the message center).
        -- Server-only by the fruit-plane write's nature; the module's own live
        -- gate keeps it inert until the growth_modulation release gate opens.
        if self.growthCredit then
            self.growthCredit:initialize()
            if g_server ~= nil then
                self.growthCredit:register()
            end
        end

        -- SF-78 GROWTH BLOCK: initialize + register both message subscriptions.
        -- Server-only by the fruit-plane write's nature; the module's own live
        -- gate keeps it inert until the growth_modulation release gate opens.
        if self.growthBlock then
            self.growthBlock:initialize()
            if g_server ~= nil then
                self.growthBlock:register()
            end
        end

        -- SF-14 ZONE YIELD: initialize + register the growth-message capture.
        -- Server-only by the value-map write's nature; the module's own live
        -- gate keeps it inert until the growth_modulation release gate opens.
        -- The capture runs once per drained FINISHED_GROWTH_PERIOD delivery;
        -- Time Guard creates no second ordinary capture.
        if self.zoneYield then
            self.zoneYield:initialize()
            if g_server ~= nil then
                self.zoneYield:registerGrowthMessage()
            end
        end

        -- SF-77 TOPOGRAPHY CACHE: build once at activation (server-only by the
        -- distance-to-water's nature; clients receive the table through
        -- NetworkSync), then install the terrain-edit listener. Neutral until a
        -- consumer wires in.
        if self.topography then
            self.topography:initialize()
            if g_server ~= nil then
                if self.topography:build() then
                    self.topography:installTerrainListener()
                end
            end
        end

        -- DMV minimap heatmap - must init AFTER soilSystem so layerSystem is ready
        if self.soilMinimapLayer then
            self.soilMinimapLayer:initialize()
        end

        -- Apply the player-editable per-crop N/P/K overrides (#717) before loading field
        -- data, so the sim sees tuned rates from the first tick.
        if self.cropTuning then
            self.cropTuning:load()
        end

        self:loadSoilData()

        self.soilSystem:prePopulateAllZoneData()
        self:seedGRLEFromFieldData()

        -- REFINED: seed / migrate the per-pixel value maps once fieldData is final.
        -- No-op when the maps were restored from the savegame files.
        if self.soilSystem.seedValueMaps then
            self.soilSystem:seedValueMaps()
        end
    end)

    if not ok then
        SoilLogger.error("activateSoilSystem failed: %s", tostring(err))
    end
    return ok
end

--- Called when mission actually starts (Mission00.onStartMission).
--- At this point the loading screen is gone, the player is in the world, and
--- g_fieldManager.fields is fully populated - safe to initialize the soil system.
function SoilFertilityManager:onMissionStarted()
    if not self.soilSystem then return end

    -- Reload settings: savegameDirectory is guaranteed set by onStartMission time.
    -- The load() call in new() fires during Mission00.load before savegameDirectory
    -- is available on fresh saves, so it falls back to defaults.
    self.settings:load()

    -- Auto-detect game colorblind mode (issue #539): if the player has enabled
    -- colorblind mode in game settings, mirror that into SF's colorblind setting.
    -- Only activate - never force-disable if the user has explicitly turned it on.
    if not self.settings.colorblindMode and g_gameSettings then
        local ok, gameColorblind = pcall(function()
            return g_gameSettings:getValue("useColorblindMode")
        end)
        if ok and gameColorblind then
            self.settings.colorblindMode = true
            SoilLogger.info("Colorblind mode auto-enabled from game settings")
        end
    end

    SoilLogger.info("Mission started - checking for Precision Farming compatibility...")

    local ok, err = pcall(function()
        -- Incompatibility check: if Precision Farming is present, disable our mod immediately.
        if self.pfBridge then
            self.hasPrecisionFarming = self.pfBridge:initialize()
            if self.hasPrecisionFarming then
                SoilLogger.warning("Precision Farming is active for this savegame. Soil & Fertilizer is not compatible with it and will disable itself.")
                self.settings.enabled = false
                self._disabledByPF = true  -- track that WE disabled it, not the player

                -- Queue incompatibility dialog with a delay to ensure GUI is stable
                if not self.disableGUI then
                    SoilLogger.info("Incompatibility dialog queued (3.5s delay)")
                    self._pendingIncompatDialog = true
                    self._pendingIncompatDelay  = 3500
                end
                return
            else
                -- PF is absent. Re-enable only if we were the ones who disabled it
                -- (i.e. the player didn't manually turn the mod off themselves).
                if self._disabledByPF then
                    SoilLogger.info("Precision Farming not detected - re-enabling Soil & Fertilizer")
                    self.settings.enabled = true
                    self._disabledByPF = false
                    self.settings:save()
                end
            end
        end

        if not self.settings.enabled then
            SoilLogger.info("Mod disabled in settings - skipping soil system init")
            return
        end

        -- SF-76 FIELD GENESIS: a NEW save (no soilData.xml yet) seeds its
        -- starting soil FROM TERRAIN, deterministically from a per-save seed
        -- (the savegame directory hash, stable across two loads of one save).
        -- An existing save is untouched: genesis stays off and the fieldData
        -- that exists loads as always. Server-derived only.
        if g_server ~= nil and not self:_hasSavedSoilData() then
            self.soilSystem.genesisActive = true
            self.soilSystem.genesisSeed   = self:_genesisSeed()
            SoilLogger.info("[SF-76] Field genesis ACTIVE for this new save (seed %d)",
                self.soilSystem.genesisSeed)
        end

        SoilLogger.info("Initializing soil system (fields guaranteed populated)...")
        self:activateSoilSystem()

        -- Version "What's new" dialog - queued AFTER activateSoilSystem (which runs
        -- loadSoilData) so the comparison uses the SAVED lastSeenVersion. It used to be
        -- queued before the load, which always compared
        -- against the "" default, so the dialog reappeared on every load and the
        -- "Don't show again" button never stuck (#665).
        if SoilVersionDialog then
            local modInfo = g_modManager and g_modManager:getModByName(self.modName)
            local version = (modInfo and modInfo.version) or "?"
            SoilLogger.info("Version check: save=%s mod=%s", tostring(self.lastSeenVersion), tostring(version))
            if self.lastSeenVersion ~= version then
                SoilLogger.info("New version detected - dialog queued (3s delay)")
                self._pendingVersionDialog      = version
                self._pendingVersionDialogDelay = 3000
            end
        end
    end)

    if not ok then
        SoilLogger.error("onMissionStarted init failed: %s", tostring(err))
    end

    -- #677: schedule a one-shot re-assert of PLAYER-context input events ~2s after
    -- load. A load-order race can leave on-foot hotkeys (notably the settings panel,
    -- SF_OPEN_SETTINGS) unregistered in the active context until the player remaps the
    -- key or cycles a vehicle - which matches the intermittent "shows in Controls but
    -- won't fire until I remap" report. Re-asserting after the mission has fully loaded
    -- (saved bindings applied) registers any event the first pass missed. Idempotent.
    if self.soilHUD then
        self._pendingInputReassert      = true
        self._pendingInputReassertDelay = 2000
    end
end

--- #677: (re)register all PLAYER-context input events. Idempotent - each event is
--- only registered when its id field is nil, so this is safe to call repeatedly.
--- Driven by the deferred post-load safety net (see onMissionStarted + update).
--- Registers only in the PLAYER context and never removes anything, so it cannot
--- invalidate VEHICLE-context slots for the same actions (see the cross-context
--- note in the endActionEventsModification hook).
function SoilFertilityManager:registerPlayerContextInputEvents(binding)
    binding = binding or g_inputBinding
    if not binding then return end
    if not self.soilHUD then return end
    if not (InputAction and PlayerInputComponent) then return end

    local registered = 0
    binding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

    if not self.toggleHUDEventId then
        local ok, id = false, nil
        if not __rfMhOwnsHudKeys() then
            local ok, id = binding:registerActionEvent(
                InputAction.SF_TOGGLE_HUD, self, self.onToggleHUDInput, false, true, false, true)
        end
        if ok and id then self.toggleHUDEventId = id; registered = registered + 1 end
    end

    if self.soilMapOverlay and not self.cycleMapLayerEventId then
        local ok, id = binding:registerActionEvent(
            InputAction.SF_CYCLE_MAP_LAYER, self, self.onCycleMapLayerInput, false, true, false, true)
        if ok and id then
            self.cycleMapLayerEventId = id
            binding:setActionEventTextVisibility(id, false)
            registered = registered + 1
        end
    end

    if self.settingsPanel and not self.settingsPanelEventId then
        local ok, id = binding:registerActionEvent(
            InputAction.SF_OPEN_SETTINGS, self, self.onOpenSettingsInput, false, true, false, true)
        if ok and id then
            self.settingsPanelEventId = id
            binding:setActionEventTextVisibility(id, false)
            registered = registered + 1
        end
    end

    if self.soilHUD and not self.hudDragEventId then
        local ok, id = false, nil
        if not __rfMhOwnsHudKeys() then
            local ok, id = binding:registerActionEvent(
                InputAction.SF_HUD_DRAG, self, self.onHUDDragInput, false, true, false, true)
        end
        if ok and id then
            self.hudDragEventId = id
            binding:setActionEventTextVisibility(id, false)
            registered = registered + 1
        end
    end

    if self.soilMapOverlay and not self.minimapZoomEventId then
        local ok, id = binding:registerActionEvent(
            InputAction.SF_MINIMAP_ZOOM, self, self.onMinimapZoomInput, false, true, false, true)
        if ok and id then
            self.minimapZoomEventId = id
            binding:setActionEventTextVisibility(id, false)
            registered = registered + 1
        end
    end

    binding:endActionEventsModification()

    if registered > 0 then
        SoilLogger.info("#677 input re-assert: registered %d previously-missing PLAYER event(s)", registered)
    else
        SoilLogger.debug("#677 input re-assert: all PLAYER events already registered")
    end
end

-- NOTE: registerInputActions() removed.
-- J key is now registered inside the PlayerInputComponent.registerActionEvents hook
-- installed in SoilFertilityManager.new(). This fires at the exact moment the player's
-- input subsystem is ready, eliminating the race condition on dedicated-server clients.

-- Input callback for HUD toggle (J)
function SoilFertilityManager:onToggleHUDInput()
    -- 2026-08-22 (Wizard): MasterHUD takeover. When MasterHUD is installed it owns the
    -- suite-wide hide/move binds, so this mod's own per-mod key is deliberately inert:
    -- one surface, one way to reach it. Standalone (no MasterHUD) this runs normally.
    -- Canonical presence check, the same expression the suite's MasterHUD bridges use.
    if ((g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD) ~= nil then
        return
    end
    if not (self.settings and self.settings.enabled) then return end
    if self.soilHUD then
        self.soilHUD:toggleVisibility()
    end
end

-- Input callback for Settings Panel (Shift+O)
function SoilFertilityManager:onOpenSettingsInput()
    if not (self.settings and self.settings.enabled) then return end
    if self.settingsPanel then
        self.settingsPanel:toggle()
    end
end

-- Input callback for HUD drag toggle (SF_HUD_DRAG, default Shift+H)
function SoilFertilityManager:onHUDDragInput()
    -- 2026-08-22 (Wizard): MasterHUD takeover. When MasterHUD is installed it owns the
    -- suite-wide hide/move binds, so this mod's own per-mod key is deliberately inert:
    -- one surface, one way to reach it. Standalone (no MasterHUD) this runs normally.
    -- Canonical presence check, the same expression the suite's MasterHUD bridges use.
    if ((g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD) ~= nil then
        return
    end
    if not self.soilHUD then return end
    if not self.soilHUD.visible then return end
    if not (self.settings and self.settings.showHUD and self.settings.enabled) then return end
    if self.soilHUD.editMode then
        self.soilHUD:exitEditMode()
        if self.sprayerInfoPanel then self.sprayerInfoPanel:exitEditMode() end
        if self.harvesterPanel   then self.harvesterPanel:exitEditMode()   end
    else
        self.soilHUD:enterEditMode()
        if self.sprayerInfoPanel then self.sprayerInfoPanel:enterEditMode() end
        if self.harvesterPanel   then self.harvesterPanel:enterEditMode()   end
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
-- Shared helper: recursively scan the attacher-joint tree for a fertilizer applicator implement.
-- Used by both getApplicatorVehicle and the else-branch below.
local function scanImpls(root)
    if not root then return nil end
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

-- Returns the vehicle that owns the sprayer rate for the current player.
-- For rate adjustment, we always return the root vehicle (tractor) so the rate
-- is stored on the vehicle the player is sitting in. This ensures the rate
-- lookup in sprayer hooks (which run on individual sprayer implements and use
-- rootVehicle.id) always finds the stored rate, even for separate tanker + boom
-- setups where the tanker and boom are different vehicles with spec_sprayer.
-- For self-propelled sprayers the root vehicle IS the sprayer, so no change.
-- Uses scanImpls as a shared recursive helper (hoisted above).
local function getApplicatorVehicle()
    local v = getPlayerVehicle()
    if not v then return nil end

    -- Always return the root vehicle so rate storage and lookup are on the same ID.
    local root = v.rootVehicle
    if root and root ~= v then
        return root
    end

    -- Self-propelled: return self
    return v
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
        if SoilNetworkEvents_SendSprayerAutoMode then
            SoilNetworkEvents_SendSprayerAutoMode(vehicle, newState)
        end
    end
end

function SoilFertilityManager:onCycleMapLayerInput()
    if self.soilMapOverlay then
        self.soilMapOverlay:cycleLayer()
    end
end

function SoilFertilityManager:onMinimapZoomInput()
    if self.soilMapOverlay then
        self.soilMapOverlay:cycleMinimapZoom()
    end
end

--- [SF-39] THE HANDFUL PANEL. Input callback for SF_HANDFUL (default Shift+G).
--- Kneel, read, show. The order is load bearing: the reveal must complete before
--- the assemble so diseaseKnown reflects the just-knelt cell and never a stale
--- pre-reveal read (SF-38 rule 5).
---
--- Every refusal SPEAKS. A silent no-op teaches the player the key is broken;
--- a blinking warning teaches them the rule.
function SoilFertilityManager:onHandfulInput()
    if not (self.settings and self.settings.enabled) then return end
    if not (self.soilSystem and self.soilHUD) then return end

    local function warn(text)
        if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
            g_currentMission.hud:showBlinkingWarning(text, 3000)
        end
    end

    -- Gate 1: the family is LOCKED unless the player opted into experimental
    -- systems. Same registry the rest of Read the Dirt checks.
    if ReleaseGate and not ReleaseGate.isSystemLive("read_the_dirt") then
        local msg = ReleaseGate.lockMessage and ReleaseGate.lockMessage("read_the_dirt", ReleaseGate.liveOptIn())
        if msg then warn(msg) end
        return
    end

    -- Gate 2: you have to actually be kneeling. PlayerStateCrouch flips this flag
    -- on entry/exit (player/PlayerMover.lua setIsCrouching); crouch is a HOLD in
    -- FS25, not a toggle, so the player holds crouch and presses the key. A hand
    -- tool whose canCrouch is false blocks the crouch state outright - that is
    -- the engine's rule and we do not work around it.
    local player = g_localPlayer
    local kneeling = player ~= nil and player.mover ~= nil and player.mover.isCrouching == true
    if not kneeling then
        warn(g_i18n:getText("sf_handful_need_kneel"))
        return
    end

    -- Gate 3: a field and a resolved spot underfoot.
    local fieldId, x, z = nil, nil, nil
    if self.soilHUD.detectCurrentFieldId then
        local ok, cur, cx, cz = pcall(function() return self.soilHUD:detectCurrentFieldId() end)
        if ok then fieldId = cur; x, z = cx, cz end
    end
    if fieldId and fieldId <= 0 then fieldId = nil end
    if not fieldId or x == nil or z == nil then
        warn(g_i18n:getText("sf_scout_no_field"))
        return
    end

    local day = g_currentMission and g_currentMission.environment
        and g_currentMission.environment.currentDay

    -- THE KNEEL, first. Server-authoritative: direct on the host, a request on a
    -- client. Identical to the SF_SCOUT path, which is the shipped kneel.
    local scouting = self.soilSystem.spatialScouting
    if g_server ~= nil then
        if scouting and scouting:isArmed() and day then
            scouting:revealCellAt(nil, x, z, day)
        end
    elseif g_client ~= nil and SoilKneelEvent then
        pcall(function()
            g_client:getServerConnection():sendEvent(SoilKneelEvent.new(x, z))
        end)
    end

    -- THE READ, after. Pure assembly, zero writes. materialFillType is left nil
    -- when we cannot name what lies at the spot; the verdict then returns its
    -- honest refusal rather than a guess.
    if HandfulRead == nil or type(HandfulRead.assemble) ~= "function" then return end
    local payload = HandfulRead.assemble({
        fieldId = fieldId,
        x = x,
        z = z,
        farmId = player.farmId,
        currentDay = day,
    })
    if payload == nil then
        warn(g_i18n:getText("sf_handful_no_read"))
        return
    end

    -- THE PANEL.
    if SoilHandfulDialog and SoilHandfulDialog.show then
        SoilHandfulDialog.show(payload)
    end
end

--- Input callback for Field Scout (SF_SCOUT, default Shift+K).
--- Scouts the field underfoot and shows the named disease + recommended chemical.
function SoilFertilityManager:onScoutInput()
    if not (self.settings and self.settings.enabled) then return end
    if not (self.soilSystem and self.soilHUD) then return end

    -- Detect the field underfoot. detectCurrentFieldId() actively probes the player's
    -- world position (works even with the HUD hidden); cachedFieldId is the last frame's
    -- value as a fallback. (getCurrentFieldId never existed - that was the no-op bug.)
    -- [SF-37] It ALSO returns the spot x,z, which used to be discarded. Carry it
    -- through ADDITIVELY: the field-level scout path below is byte-identical for a
    -- caller with no spot, and the kneel (a per-cell reveal onto the walked mask)
    -- fires only when a spot is resolved.
    local fieldId, x, z = nil, nil, nil
    if self.soilHUD.detectCurrentFieldId then
        local ok, cur, cx, cz = pcall(function() return self.soilHUD:detectCurrentFieldId() end)
        if ok then fieldId = cur; x, z = cx, cz end
    end
    if (not fieldId or fieldId <= 0) and self.soilHUD.cachedFieldId then
        fieldId = self.soilHUD.cachedFieldId
    end
    if fieldId and fieldId <= 0 then fieldId = nil end
    if not fieldId then
        if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
            g_currentMission.hud:showBlinkingWarning(g_i18n:getText("sf_scout_no_field"), 3000)
        end
        return
    end

    -- [SF-37] THE KNEEL. When the player is on foot with a resolved spot, the
    -- exact spot enters knowledge: ONE cell written onto the walked mask, server
    -- authoritative. The client key press is a REQUEST (SoilKneelEvent carries
    -- only x,z); on the host/SP the write is direct. The field-level scout fee
    -- below still runs for every caller (the kneel is additive, not a
    -- replacement) - it is what buys the whole field's pattern and the name.
    if x ~= nil and z ~= nil and g_server ~= nil then
        if self.soilSystem.spatialScouting and self.soilSystem.spatialScouting:isArmed() then
            local day = g_currentMission and g_currentMission.environment
                and g_currentMission.environment.currentDay
            if day then
                self.soilSystem.spatialScouting:revealCellAt(nil, x, z, day)
            end
        end
    elseif x ~= nil and z ~= nil and g_client ~= nil and SoilKneelEvent then
        local ok = pcall(function()
            g_client:getServerConnection():sendEvent(SoilKneelEvent.new(x, z))
        end)
        if not ok then
            SoilLogger.warning("[Kneel] failed to send SoilKneelEvent: %s", tostring(ok))
        end
    end

    -- The Scout hotkey is a deliberate scout: reveal the field's disease so the flash
    -- message and the Scout dialog it opens both show the identified infection.
    local rep = self.soilSystem:scoutField(fieldId)
    if not rep or rep.enabled == false then return end

    local function disName(id)
        if not id then return g_i18n:getText("sf_scout_clean") end
        local key = "sf_dis_" .. id
        if g_i18n:hasText(key) then return g_i18n:getText(key) end
        return (id:gsub("_", " "))
    end
    local function chemName(id)
        if not id then return "?" end
        local key = "sf_chem_" .. id
        if g_i18n:hasText(key) then return g_i18n:getText(key) end
        return (id:gsub("_", " "))
    end

    local msg
    if rep.diseaseId and rep.recommend then
        msg = string.format(g_i18n:getText("sf_scout_found"),
            fieldId, disName(rep.diseaseId), math.floor(rep.pressure + 0.5), chemName(rep.recommend.best))
    elseif rep.pressure and rep.pressure >= (SoilConstants.DISEASE_PRESSURE.LOW or 20) then
        msg = string.format(g_i18n:getText("sf_scout_pressure"), fieldId, math.floor(rep.pressure + 0.5))
    else
        msg = string.format(g_i18n:getText("sf_scout_healthy"), fieldId)
    end

    -- Open the dedicated Scout panel for this field (disease readout + fungicide
    -- selector + Apply). Falls back to a quick flash if the dialog is unavailable.
    if SoilScoutDialog and SoilScoutDialog.show then
        SoilScoutDialog.show(fieldId)
    elseif g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(msg, 5000)
    end
    SoilLogger.info("[Scout] %s", msg)
end

--- Input callback for the Treatment prescription panel (SF_TREATMENT, default Shift+T).
--- Opens the soil/fertilizer treatment advice dialog for the field underfoot.
function SoilFertilityManager:onTreatmentInput()
    if not (self.settings and self.settings.enabled) then return end
    if not (self.soilSystem and self.soilHUD) then return end

    local fieldId = nil
    if self.soilHUD.detectCurrentFieldId then
        local ok, cur = pcall(function() return self.soilHUD:detectCurrentFieldId() end)
        if ok then fieldId = cur end
    end
    if (not fieldId or fieldId <= 0) and self.soilHUD.cachedFieldId then
        fieldId = self.soilHUD.cachedFieldId
    end
    if not fieldId or fieldId <= 0 then
        if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
            g_currentMission.hud:showBlinkingWarning(g_i18n:getText("sf_scout_no_field"), 3000)
        end
        return
    end

    if SoilTreatmentDialog and SoilTreatmentDialog.show then
        SoilTreatmentDialog.show(fieldId)
    end
end

-- ── Smart Sensor toggle callbacks ────────────────────────

local function getSensorVehicle()
    local player = g_localPlayer
    if not player or type(player.getIsInVehicle) ~= "function" then return nil end
    if not player:getIsInVehicle() then return nil end
    local v = player:getCurrentVehicle()
    if not v then return nil end
    if v.spec_sprayer then return v end
    local impl = v.spec_attacherJoints and v.spec_attacherJoints.attachedImplements
    if impl then
        for _, att in ipairs(impl) do
            if att.object and att.object.spec_sprayer then return att.object end
        end
    end
    return nil
end

local function showSensorMsg(name, on)
    local stateKey = on and "sf_sensor_state_on" or "sf_sensor_state_off"
    local txt = name .. ": " .. (g_i18n and g_i18n:getText(stateKey) or (on and "ON" or "OFF"))
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(txt, 2000)
    end
end

--- [PACK] Does this machine carry the precision pack (variable rate + section
--- control)? Checks the sprayer, then its root vehicle, so a trailed unit
--- answers for its own configuration. Fails CLOSED: no specialization, no pack.
function SoilFertilityManager:hasPrecisionPack(vehicle)
    if vehicle == nil then return false end
    if type(vehicle.sfHasPrecisionPack) == "function" then
        local ok, has = pcall(function() return vehicle:sfHasPrecisionPack() end)
        if ok and has then return true end
    end
    local root = vehicle.rootVehicle
    if root and root ~= vehicle and type(root.sfHasPrecisionPack) == "function" then
        local ok, has = pcall(function() return root:sfHasPrecisionPack() end)
        if ok and has then return true end
    end
    return false
end

-- ── System 3: Variable Rate input callback ─────────────────

function SoilFertilityManager:onVariableRateInput()
    local vehicle = getSensorVehicle()
    if not vehicle or not self.sensorManager then return end
    -- [PACK] Hardware gate. Refuse the toggle and say why, rather than flipping a
    -- flag that the spray path will ignore -- a switch that does nothing is worse
    -- than one that explains itself.
    if not self:hasPrecisionPack(vehicle) then
        local msg = (g_i18n and g_i18n:getText("sf_pack_required"))
            or "This sprayer does not have the add-on needed for that function. Visit the shop to upgrade your sprayer."
        if g_currentMission and g_currentMission.hud
            and g_currentMission.hud.showBlinkingWarning then
            g_currentMission.hud:showBlinkingWarning(msg, 4000)
        end
        SoilLogger.debug("[VariableRate] refused for vehicle %s - no precision pack",
            tostring(vehicle.id))
        return
    end
    local newState = self.sensorManager:toggleVariableRate(vehicle.id)
    showSensorMsg(g_i18n and g_i18n:getText("sf_var_rate_label") or "Variable Rate", newState)
    SoilLogger.debug("[VariableRate] %s for vehicle %d", newState and "ON" or "OFF", vehicle.id)
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

    -- Only cache positive results. Caching false during mission load (before
    -- specializations initialize) permanently marks implements as non-applicators
    -- for the entire session. Re-evaluate until we get a confirmed true.
    if vehicle._sfIsApplicator == true then
        return true
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
        -- FieldSentry (#651): persist the player's manual blacklist alongside soil data.
        if FieldSentry_API then FieldSentry_API.saveToXMLFile(xmlFile, "soilData.fieldSentry") end
        setXMLString(xmlFile, "soilData#lastSeenVersion", self.lastSeenVersion or "")
        saveXMLFile(xmlFile)
        delete(xmlFile)
        SoilLogger.info("Soil data saved to %s (%d fields)", xmlPath, fieldCount)
    else
        SoilLogger.error("Failed to create XML file for save: %s", xmlPath)
    end

    -- REFINED: persist the per-pixel soil value maps next to soilData.xml
    if self.soilSystem.valueMaps then
        self.soilSystem.valueMaps:saveToSavegame(savegamePath)
    end

    -- [SF-43] MATERIAL DOWN's watermark + object sidecar. The age LAYER itself
    -- persists natively as one of the .grle files just written; only the small
    -- sidecar needs a home. No-ops when StateLedger is present (the ledger owns the
    -- state then, so nothing writes it twice).
    if SoilMaterialDownBridge and self.soilSystem.materialDown then
        SoilMaterialDownBridge.saveFallback(self.soilSystem.materialDown)
    end
end

-- SF-76: does this save already carry soil data? A new save has neither a
-- soilData.xml nor a StateLedger soil block, so genesis may seed from terrain.
function SoilFertilityManager:_hasSavedSoilData()
    if SoilStateLedgerBridge ~= nil and SoilStateLedgerBridge.hasLedgerState ~= nil
        and SoilStateLedgerBridge.hasLedgerState() then
        return true
    end
    local path = g_currentMission and g_currentMission.missionInfo
        and g_currentMission.missionInfo.savegameDirectory
    if path == nil then return false end
    return fileExists(path .. "/soilData.xml")
end

-- SF-76: the deterministic per-save seed. The savegame directory path is the
-- save's stable identity across two loads of one save, so hashing it yields
-- the same seed twice (the byte-identical acceptance). Stable across reloads,
-- differs between saves.
function SoilFertilityManager:_genesisSeed()
    local path = g_currentMission and g_currentMission.missionInfo
        and g_currentMission.missionInfo.savegameDirectory or ""
    local seed = 0
    for i = 1, #path do
        local c = string.byte(path, i)
        seed = (seed * 31 + c) % 2147483647
    end
    return seed
end

--- Load soil data from XML file
--- Reads from {savegame}/soilData.xml if exists
--- Falls back to defaults if file not found
function SoilFertilityManager:loadSoilData()    if not self.soilSystem then
        SoilLogger.error("loadSoilData: soilSystem is nil")
        return
    end
    if not g_currentMission or not g_currentMission.missionInfo then
        SoilLogger.error("loadSoilData: missionInfo is nil")
        return
    end

    -- StateLedger (bedrock): when installed and it delivered an actual soil block,
    -- it is the load source of truth. On a new save, or the first load after
    -- installing the ledger onto an existing save, it delivers nothing, so we fall
    -- through and import the existing soilData.xml (which the ledger then carries
    -- forward). soilData.xml is still written every save as a safety copy.
    if SoilStateLedgerBridge and SoilStateLedgerBridge.hasLedgerState() then
        SoilStateLedgerBridge.applyState(self)
        local fieldCount = 0
        if self.soilSystem.fieldData then
            for _ in pairs(self.soilSystem.fieldData) do fieldCount = fieldCount + 1 end
        end
        SoilLogger.info("Soil data loaded from StateLedger (%d fields)", fieldCount)
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if not savegamePath then
        SoilLogger.warning("loadSoilData: savegameDirectory not set yet (new career or early load) - starting with defaults")
        return
    end

    local xmlPath = savegamePath .. "/soilData.xml"
    if fileExists(xmlPath) then
        local xmlFile = loadXMLFile("soilData", xmlPath)
        if xmlFile then
            self.soilSystem:loadFromXMLFile(xmlFile, "soilData")
            -- FieldSentry (#651): restore the manual blacklist (no-op if none saved).
            if FieldSentry_API then FieldSentry_API.loadFromXMLFile(xmlFile, "soilData.fieldSentry") end
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
        -- Fresh start: scanFields already seeded fieldData from GRLE layers (if available).
        -- Push that data to the density map layers now so the PDA DMV overlay and minimap
        -- heatmap show real values immediately rather than after the first fertilizer event.
        -- GRLE minimap heatmap fills in per-pixel from sprayer events.
        -- No bulk AABB seed here - see SoilFertilitySystem.lua loadFromXMLFile note.
    end
end

-- Seed all GRLE layers (including N/P/K/pH/OM) with the current fieldData values
-- so the DMV minimap heatmap shows a full field heatmap on session start.
-- Called once after loadSoilData() has populated fieldData.
function SoilFertilityManager:seedGRLEFromFieldData()
    local soilSys = self.soilSystem
    if not soilSys then return end
    local layerSys = soilSys.layerSystem
    if not layerSys or not layerSys.available then return end
    if g_dedicatedServer then return end

    local fieldData = soilSys.fieldData
    if not fieldData then return end

    -- Build a farmland-id → Field lookup once so the per-field loop is O(n), not O(n²).
    -- On large maps (200+ fields) the old nested ipairs scan blocked the main thread
    -- long enough to cause an apparent crash/freeze at ~40% map load (#583).
    local farmlandToField = {}
    if g_fieldManager and g_fieldManager.fields then
        for _, f in ipairs(g_fieldManager.fields) do
            if f and f.farmland then
                farmlandToField[f.farmland.id] = f
            end
        end
    end

    local count = 0
    for fieldId, field in pairs(fieldData) do
        local fsField = farmlandToField[fieldId]
        if fsField then
            layerSys:writeFieldToLayers(fieldId, field, fsField)
            count = count + 1
        end
    end

    if self.soilMinimapLayer then
        self.soilMinimapLayer:markDirty()
    end

    SoilLogger.info("GRLE startup seed complete: %d field(s) seeded to all layers", count)
end

--- Update loop called every frame
---@param dt number Delta time in milliseconds
function SoilFertilityManager:update(dt)
    -- [PACK] Tell the player once, per sprayer, that a machine they already owned
    -- now needs the add-on. Without this the feature simply vanishes on load and
    -- reads as a broken mod. Throttled to a 2 s poll and remembered per vehicle,
    -- so it cannot repeat while they sit in the seat.
    self._packNoticeTimer = (self._packNoticeTimer or 0) + dt
    if self._packNoticeTimer >= 2000 then
        self._packNoticeTimer = 0
        local v = g_localPlayer and type(g_localPlayer.getCurrentVehicle) == "function"
            and g_localPlayer:getCurrentVehicle() or nil
        if v ~= nil and type(v.sfIsLegacyNoPack) == "function" then
            self._packNoticeShown = self._packNoticeShown or {}
            local key = v.id or tostring(v)
            if not self._packNoticeShown[key] then
                local ok, legacy = pcall(function() return v:sfIsLegacyNoPack() end)
                if ok and legacy then
                    self._packNoticeShown[key] = true
                    local msg = (g_i18n and g_i18n:getText("sf_pack_legacy_notice"))
                        or "Variable rate and section control now need the Precision Pack. "
                        .. "This sprayer does not have it - visit the shop to upgrade."
                    if g_currentMission and g_currentMission.hud
                        and g_currentMission.hud.showBlinkingWarning then
                        g_currentMission.hud:showBlinkingWarning(msg, 5000)
                    end
                    SoilLogger.info("[PACK] legacy sprayer %s has no precision pack - player notified",
                        tostring(key))
                end
            end
        end
    end
    -- REFINED: periodic value-map checksum broadcast (MP drift detection).
    -- Server-only, every 5 real minutes, only when clients are connected.
    if g_server and g_currentMission and g_currentMission.missionDynamicInfo
       and g_currentMission.missionDynamicInfo.isMultiplayer then
        self._vmChecksumTimer = (self._vmChecksumTimer or 0) + dt
        if self._vmChecksumTimer >= 300000 then
            self._vmChecksumTimer = 0
            if SoilNetworkEvents_BroadcastValueMapChecksums then
                SoilNetworkEvents_BroadcastValueMapChecksums()
            end
        end
    end

    -- Deferred fill type registration retry (dedicated server timing fix: #431)
    -- Also re-patches ALL vehicles every frame until all custom types are resolvable,
    -- so modded maps that shift fill-type indices (e.g. Carpathian Countryside, #727)
    -- are handled without depending on _sprayTypesComplete.
    if self.soilSystem and self.soilSystem.hookManager then
        self._deferredRetryCount = (self._deferredRetryCount or 0) + 1
        if self._deferredRetryCount <= 120 then
            local hm = self.soilSystem.hookManager
            hm:registerCustomSprayTypes()
            hm:reapplyFillUnitPatch()
            hm:reapplyEffectTypeRemap()
            hm:patchExistingSilos()
            if hm._sprayTypesComplete then
                if self._deferredRetryCount > 1 then
                    SoilLogger.info("[DeferredInit] Fill-type re-patch complete on retry #%d", self._deferredRetryCount)
                end
                self._deferredRetryCount = 121  -- stop retrying once complete
            end
        elseif self._deferredRetryCount == 122 then
            SoilLogger.warning("[DeferredInit] Fill types still unavailable after 120 retries - dedicated server or modded map may have incomplete fill type loading")
            self.soilSystem.hookManager._sprayTypesComplete = true  -- stop retrying
        end
    end

    -- Deferred incompatibility dialog (Precision Farming)
    if self._pendingIncompatDialog then
        self._pendingIncompatDelay = (self._pendingIncompatDelay or 0) - dt
        if self._pendingIncompatDelay <= 0 then
            self._pendingIncompatDialog = nil
            self._pendingIncompatDelay  = nil
            if g_gui then
                SoilLogger.info("Showing incompatibility dialog (PF detected)")
                InfoDialog.show(g_i18n:getText("sf_incompatibility_pf_text"))
            end
        end
    end

    -- Deferred version dialog - fired 3s after mission start so the GUI is stable.
    -- Must run BEFORE the settings.enabled guard so it shows even when mod is disabled.
    if self._pendingVersionDialog then
        self._pendingVersionDialogDelay = (self._pendingVersionDialogDelay or 0) - dt
        if self._pendingVersionDialogDelay <= 0 then
            local ver = self._pendingVersionDialog
            self._pendingVersionDialog      = nil
            self._pendingVersionDialogDelay = nil
            SoilLogger.info("Showing version dialog for %s", ver)
            SoilVersionDialog.show(ver)
        end
    end

    -- #677: one-shot PLAYER-context input re-assert after load settles. Runs before
    -- the enabled guard so on-foot hotkeys are restored even while the mod is toggled
    -- off (the settings panel is how the player turns it back on).
    if self._pendingInputReassert then
        self._pendingInputReassertDelay = (self._pendingInputReassertDelay or 0) - dt
        if self._pendingInputReassertDelay <= 0 then
            self._pendingInputReassert      = nil
            self._pendingInputReassertDelay = nil
            self:registerPlayerContextInputEvents(g_inputBinding)
        end
    end

    -- ── MANDATORY GUARD: Mod must be enabled ──────────────────
    if not (self.settings and self.settings.enabled) then
        return
    end

    -- Always update soil system (server side)
    if self.soilSystem then
        self.soilSystem:update(dt)
    end

    -- DMV minimap heatmap async build cycle (client only)
    if self.soilMinimapLayer and self.soilMapOverlay then
        self.soilMinimapLayer:update(dt, self.soilMapOverlay)
    end

    -- Minimap zoom smooth interpolation
    if self.soilMapOverlay then
        self.soilMapOverlay:updateMinimapZoom(dt)
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

    -- Tuning panel camera-lock and cursor keepalive
    if self.tuningPanel then
        self.tuningPanel:update()
    end

    if self.cropTuningPanel then
        self.cropTuningPanel:update()
    end

    -- Compaction: periodic check for local player's heavy vehicle driving over fields.
    -- getIsServer() is the documented API; the .isServer field is not guaranteed on FSBaseMission.
    -- Sampled on a short interval (CHECK_INTERVAL_MS) so the wheels lay a continuous
    -- compaction trail along the driven path, not one cell every 30 seconds.
    if g_currentMission and g_currentMission:getIsServer() then
        self._compactionTimer = (self._compactionTimer or 0) + dt
        local interval = (SoilConstants.COMPACTION and SoilConstants.COMPACTION.CHECK_INTERVAL_MS) or 1000
        if self._compactionTimer >= interval then
            self._compactionTimer = 0
            self:_checkVehicleCompaction()
        end
    end

    -- Auto-rate control: adjust sprayer rate based on current field soil data
    self:updateAutoRates(dt)
end

--- Advance the decaying soil-wetness value (0..1) that feeds the compaction moisture
--- multiplier. Pinned to 1 while raining, fades to 0 over MOISTURE.DECAY_HOURS of game
--- time afterwards. Uses a monotonic game-hours clock from currentDay + dayTime.
function SoilFertilityManager:_updateSoilWetness()
    local env = g_currentMission and g_currentMission.environment
    if not env then return end

    local gameH = ((env.currentDay or 0) * 24) + ((env.dayTime or 0) / 3600000.0)
    local lastH = self._wetnessLastGameH
    local dtH = 0
    if lastH then
        dtH = gameH - lastH
        if dtH < 0 then dtH = 0 end     -- clock moved backwards (load): treat as no time
        if dtH > 24 then dtH = 24 end   -- clamp big jumps (sleep / fast-forward)
    end
    self._wetnessLastGameH = gameH

    -- #740: soil wetness (which drives compaction susceptibility) follows the same rain
    -- source as the rest of the sim - real weather by default, or the synthetic climate
    -- preset - so an Arid/Wet setting makes soil correspondingly drier/wetter to compact.
    local isRaining = false
    local soil = self.soilSystem
    local thr = (SoilConstants.RAIN and SoilConstants.RAIN.MIN_RAIN_THRESHOLD) or 0.1
    if soil and soil.getEffectiveRainScale then
        local okR, rs = pcall(function() return soil:getEffectiveRainScale() end)
        isRaining = okR and rs ~= nil and rs > thr
    elseif env.weather and env.weather.getRainFallScale then
        local okR, rs = pcall(function() return env.weather:getRainFallScale() end)
        isRaining = okR and rs ~= nil and rs > thr
    end

    self._soilWetness01 = SoilCompactionModel.advanceWetness(self._soilWetness01, dtH, isRaining)
end

--- F111 (SF-55): the compaction pass, enumerated across EVERY server-side vehicle.
--- The old path resolved the vehicle from getPlayerVehicle(), which is nil on a
--- dedicated server (compaction dead for everyone) and single-vehicle on a listen
--- server (only the host's tractor laid a trail). Enumerating the mission vehicle
--- list at the existing CHECK_INTERVAL_MS cadence closes that for every actor:
--- other farmers, AI helpers, hired workers, convoys. Server-side only, gated by
--- the caller (update() checks getIsServer()).
function SoilFertilityManager:_checkVehicleCompaction()
    if not (self.settings.compactionEnabled and SoilConstants.COMPACTION) then return end
    if not (self.soilSystem and self.soilSystem.hookManager) then return end

    -- Keep the moisture term current even when no heavy vehicle is around.
    self:_updateSoilWetness()

    -- BUILD 21:59: a zip that carried this manager without src/TrafficDrag.lua indexed nil
    -- here once per update tick. It falls back rather than returning: compaction is the older
    -- shipped feature and should keep working when the newer module is absent, and the drag
    -- write already stands down on its own guards.
    local vList
    if TrafficDrag ~= nil and type(TrafficDrag.resolveVehicleList) == "function" then
        vList = TrafficDrag.resolveVehicleList()
    else
        vList = (g_currentMission ~= nil and g_currentMission.vehicleSystem
                 and g_currentMission.vehicleSystem.vehicles)
                or (g_currentMission ~= nil and g_currentMission.vehicles) or {}
    end
    local checked = 0
    for _, vehicle in pairs(vList) do
        if self:_checkOneVehicleCompaction(vehicle) then checked = checked + 1 end
    end
    if checked > 0 then
        SoilLogger.debug("Compaction pass: %d heavy vehicles with a wheel on ground", checked)
    end
end

--- Per-vehicle compaction + traffic-drag pass (F111 body). Returns true when the
--- vehicle was relevant (heavy, wheels on ground, points laid).
function SoilFertilityManager:_checkOneVehicleCompaction(vehicle)
    local cp = SoilConstants.COMPACTION
    if not (vehicle and vehicle.rootNode) then return false end
    if not self:_vehicleHasWheelOnGround(vehicle) then return false end

    local okM, totalMass = pcall(function() return vehicle:getTotalMass(false) end)
    -- Cheap relevance gate: skip light vehicles (cars/quads) entirely. This is a perf
    -- floor only - actual compaction is decided by ground pressure, not this threshold.
    if not (okM and totalMass and totalMass >= cp.HEAVY_VEHICLE_THRESHOLD_T) then return false end
    local ok, x, _, z = pcall(getWorldTranslation, vehicle.rootNode)
    if not (ok and x) then return false end

    -- SF-55 wetness-input substitution: a real positional wetness read (SCS field-level
    -- moisture, blended with the rain-scalar fallback per confirm 2) instead of the
    -- bare global scalar. SCS absent or untracked -> the rain scalar exactly as today.
    local wet = self:_blendedWetness01(x, z)

    -- Ground-pressure points for this vehicle this pass (identical for every sub-step of
    -- the driven segment). Reads Variable Tire Pressure live when installed, else wheel
    -- geometry. Big flotation tyres / aired-down / dry soil -> ~0 -> nothing is laid.
    local points, source = SoilCompactionModel.pointsForVehicle(vehicle, wet)
    if not points or points <= 0 then
        self:_rememberCompactionPos(vehicle, x, z)  -- keep continuity, lay nothing
        return false
    end

    -- One stepped position: write the traffic drag when the gate holds (independent of
    -- the compaction write), then compact the cell if it sits on a field (onCompaction
    -- gates each cell to once/day and to real field ground, so repeated calls are cheap
    -- no-ops).
    local function stepAt(px, pz)
        self:_maybeWriteTrafficDrag(px, pz, wet)
        local fid = self.soilSystem.hookManager:getFieldIdAtWorldPosition(px, pz, false)
        if fid and fid > 0 then
            pcall(function() self.soilSystem:onCompaction(fid, px, pz, points) end)
        end
    end

    local lx, lz = self:_compactionLastPos(vehicle)
    self:_rememberCompactionPos(vehicle, x, z)

    -- First sample, or a teleport/fast-travel jump: record position but lay NOTHING.
    -- Compaction only accrues along ground actually driven over, so sitting still or
    -- spawning on a field never raises it (Talia: "equipment just sitting raises it").
    if not (lx and lz) then return false end

    local dx, dz = x - lx, z - lz
    local dist   = math.sqrt(dx * dx + dz * dz)
    if dist < (cp.MIN_MOVE_DISTANCE_M or 2.0) then return false end   -- parked / barely moved
    if dist > (cp.MAX_SEGMENT_M or 30.0) then return false end        -- discontinuity: no line across the gap

    -- Walk the driven segment in ~half-cell steps so no cell is skipped at speed.
    -- This is what keeps the trail continuous whether crawling or driving fast.
    local cellSize = (SoilConstants.ZONE and SoilConstants.ZONE.CELL_SIZE) or 10.0
    local step     = cellSize * 0.5
    local steps    = math.max(1, math.ceil(dist / step))
    for i = 1, steps do
        local t = i / steps
        stepAt(lx + dx * t, lz + dz * t)
    end

    SoilLogger.debug("Compaction: %s pass +%.2f raw pts/cell  wet=%.2f  steps=%d",
        tostring(source), points, wet, steps)
    return true
end

--- Per-vehicle last-position continuity (replaces the old single-vehicle
--- _lastCompactionX/_lastCompactionZ state).
function SoilFertilityManager:_compactionLastPos(vehicle)
    local t = self._compactionLast
    if not t or not t[vehicle.id] then return nil end
    return t[vehicle.id].x, t[vehicle.id].z
end

function SoilFertilityManager:_rememberCompactionPos(vehicle, x, z)
    local key = vehicle.id
    if key == nil then return end   -- an id-less entry degrades to "first sample" (lays nothing)
    if not self._compactionLast then self._compactionLast = {} end
    self._compactionLast[key] = { x = x, z = z }
end

--- Wheel-on-ground gate for the F111 enumeration (brief: "for each vehicle with a
--- wheel on ground"). Reads the live wheel physics contact state; a vehicle whose
--- wheels are all airborne (jump, teleport) or that has no wheels is skipped.
--- Verified: WheelPhysics:updateContact sets physics.hasGroundContact from the wheel
--- shape contact point (LUADOC WheelPhysics.md). RealisticWeather overwrites
--- WheelPhysics.updateFriction only (RW vehicles/wheels/WheelPhysics.lua:50), never
--- the contact fields, so this read is RW-safe.
function SoilFertilityManager:_vehicleHasWheelOnGround(vehicle)
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil then return false end
    for _, wheel in pairs(spec.wheels) do
        local phys = wheel.physics
        if phys and phys.hasGroundContact then return true end
    end
    return false
end

--- SF-55 wetness-input substitution: blend SCS's field-level moisture for the field
--- under (x, z) with the rain-scalar fallback (confirm 2). Neutral-when-absent: no
--- SCS, no field, or a throwing read all fall back to the rain scalar exactly as
--- before. fieldId, when given, skips the re-lookup (harvest pass already resolved it).
function SoilFertilityManager:_blendedWetness01(x, z, fieldId)
    local rainScalar = self._soilWetness01 or 0
    if TrafficDrag == nil then return rainScalar end

    local fid = fieldId
    if not (fid and fid > 0) then
        fid = self.soilSystem.hookManager:getFieldIdAtWorldPosition(x, z, false)
    end
    if not (fid and fid > 0) then return rainScalar end

    local ok, scsMoisture = pcall(function()
        local csm = g_cropStressManager
        if csm == nil or type(csm.getMoisture) ~= "function" then return nil end
        return csm:getMoisture(fid)
    end)
    return TrafficDrag.blendWetness(ok and scsMoisture or nil, rainScalar)
end

--- SF-55 crop drag: when the stepped position reads wet above the threshold AND a
--- standing crop occupies it, accrue MAGNITUDE_PER_EVENT on the trafficDrag layer,
--- once per cell per day (dedupe keyed on TimeGuard monotonicDay, never
--- environment.currentDay). The cap binds at the write; the write is
--- addValueAtWorld-shaped (read-modify-write) with the first event birthing the
--- record. The second-writer fence holds: this never touches yieldEfficiency.
--- Without TimeGuard's monotonicDay the accrual stands down (no private clock).
function SoilFertilityManager:_maybeWriteTrafficDrag(px, pz, wet)
    local td = SoilConstants and SoilConstants.COMPACTION and SoilConstants.COMPACTION.TRAFFIC_DRAG
    if not td then return end
    if TrafficDrag == nil then return end
    if not (self.soilSystem and self.soilSystem:vmAvailable()) then return end
    if wet < (td.WETNESS_THRESHOLD or 0.5) then return end

    local day = TrafficDrag.getMonotonicDay()
    if day == nil then return end

    local fruitIndex, growthState = TrafficDrag.readStandingCrop(px, pz)
    if not TrafficDrag.isStandingCrop(fruitIndex, growthState, td.MIN_STANDING_GROWTH_STATE) then return end

    local cellKey = TrafficDrag.cellKey(px, pz, SoilConstants.ZONE.CELL_SIZE)
    if TrafficDrag.dedupeFired(self._trafficDragDays, cellKey, day) then return end
    self._trafficDragDays = TrafficDrag.markDedupe(self._trafficDragDays, cellKey, day)

    local valueMaps = self.soilSystem.valueMaps
    local current = valueMaps:readValueAtWorld("trafficDrag", px, pz)
    local nextVal = TrafficDrag.accrue(current, td.MAGNITUDE_PER_EVENT, td.CAP)
    valueMaps:writeValueAtWorld("trafficDrag", px, pz, nextVal, SoilConstants.ZONE.CELL_SIZE * 0.5)
    SoilLogger.debug("TrafficDrag: +%.2f at (%.1f, %.1f) day %s",
        nextVal, px, pz, tostring(day))
end

--- Auto-rate control update - throttled, client-side only.
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
    if not self.soilHUD then
        SoilLogger.debug("Auto-rate trace: bail - soilHUD nil")
        return
    end

    -- Find the player's active applicator vehicle
    local vehicle = getApplicatorVehicle()
    if not vehicle then
        -- [SF-39] AI helper run (George CLOSED DESIGN 09:48, the 0.01x holes).
        -- getPlayerVehicle() is nil the moment the player steps out, so this
        -- function bailed every tick for the WHOLE helper run and the dial froze
        -- at whatever index it last held - including 0.01x from the player
        -- standing on done ground when they pressed H. The min-boom sampling
        -- below never even ran, which is why two rounds of sampling fixes could
        -- not cure it. Find the AI-driven applicator with auto engaged instead;
        -- getIsAIActive is already relied on in HookManager, SFNozzleEffects and
        -- SoilFertilitySystem, so nothing invented.
        if g_currentMission and g_currentMission.vehicles then
            for _, v in pairs(g_currentMission.vehicles) do
                local root = v.rootVehicle or v
                if root == v and type(v.getIsAIActive) == "function" then
                    local aOk, active = pcall(v.getIsAIActive, v)
                    -- (self.sprayerRateManager directly: `rm` is declared below)
                    if aOk and active and self.sprayerRateManager
                       and self.sprayerRateManager:getAutoMode(v.id) then
                        vehicle = v
                        break
                    end
                end
            end
        end
    end
    if not vehicle then
        SoilLogger.debug("Auto-rate trace: bail - no applicator vehicle (not in one, no AI applicator with auto ON)")
        return
    end

    self:recalcAutoRateFor(vehicle)
end

--- [SF-41] Core auto-rate recalc for ONE vehicle (George CLOSED DESIGN 11:23,
--- fix 3). Split out of updateAutoRates so it has TWO drivers: the player
--- update path above, and the boom-strip work tick in HookManager - the tick
--- that demonstrably keeps running after H + walk away. The SF-39 scan found
--- the helper's machine but something in the seated update chain still starved
--- it; wiring the recalc to the same cycle that paints means the dial updates
--- exactly as long as product is going on the ground, seated or not. Own 5 s
--- throttle per vehicle so the per-tick call from the paint path stays cheap.
---@param vehicle table  root vehicle of the applicator
function SoilFertilityManager:recalcAutoRateFor(vehicle)
    if vehicle == nil or vehicle.id == nil then return end
    local nowT = (g_currentMission and g_currentMission.time) or 0
    self._sfAutoNext = self._sfAutoNext or {}
    if (self._sfAutoNext[vehicle.id] or 0) > nowT then return end
    self._sfAutoNext[vehicle.id] = nowT + 5000

    -- Only act when auto mode is engaged for this vehicle
    local rm = self.sprayerRateManager
    if not rm then
        SoilLogger.debug("Auto-rate trace: bail - sprayerRateManager nil")
        return
    end
    if not rm:getAutoMode(vehicle.id) then
        SoilLogger.debug("Auto-rate trace: bail - auto mode OFF for vehicle %d (toggle with the AUTO key)", vehicle.id)
        return
    end

    -- Use the HUD's cached field id (updated every frame in SoilHUD:update).
    -- [SF-41] nil-safe: the paint-path driver can call this before/without a HUD.
    local fieldId = self.soilHUD and self.soilHUD.cachedFieldId
    if not fieldId or fieldId <= 0 then
        -- [SF-39] The HUD caches the PLAYER's field. During a helper run the
        -- player may be standing off-field, so resolve the field under the
        -- MACHINE instead - same lookup the VR hook uses per section.
        local pOk, vx, _, vz = pcall(getWorldTranslation, vehicle.rootNode)
        if pOk and vx and HookManager and type(HookManager.getFieldIdAtWorldPosition) == "function" then
            local fOk, fid = pcall(function() return HookManager:getFieldIdAtWorldPosition(vx, vz) end)
            if fOk then fieldId = fid end
        end
    end
    if not fieldId or fieldId <= 0 then
        SoilLogger.debug("Auto-rate trace: bail - no field under player or machine")
        return
    end

    -- Retrieve live soil data for this field
    if not self.soilSystem then
        SoilLogger.debug("Auto-rate trace: bail - soilSystem nil")
        return
    end
    local fieldData = self.soilSystem:getFieldInfo(fieldId)
    if not fieldData then
        SoilLogger.debug("Auto-rate trace: bail - getFieldInfo(%s) nil", tostring(fieldId))
        return
    end

    -- Get the fill type currently loaded in the vehicle
    local fillType = self.soilHUD and self.soilHUD:getSprayerFillType(vehicle)
    if not fillType then
        SoilLogger.debug("Auto-rate trace: bail - getSprayerFillType nil for vehicle %d (field %s)",
            vehicle.id, tostring(fieldId))
        return
    end

    -- Calculate the ideal index and send if it changed
    -- [FIX-8] Sense the ground UNDER the machine, not the field average.
    --
    -- Auto-rate read fieldData.pH, which climbs as you lime -- so the rate fell
    -- away through the pass and whatever was covered last got almost nothing.
    -- Measured over one field: 0.94x at 21:45 decaying to 0.20x by 22:02, which
    -- is exactly why the last-worked strips came out pale. The machine should
    -- answer the question "what does THIS ground need", not "how is the field
    -- doing on average".
    local localVals
    do
        local soilSys = self.soilSystem
        if soilSys and soilSys.vmAvailable and soilSys:vmAvailable() then
            local vm = soilSys.valueMaps

            -- [FIX-14] Sense the WHOLE boom, and ALL FIVE soil values.
            --
            -- One sample under the tractor starved the headland edge: the tractor
            -- sits over ground already done, the rate fell for the whole boom, and
            -- the untouched edge got nothing. Sampling every ~2 m along the boom
            -- and sizing for the NEEDIEST ground fixes that -- and it must apply
            -- to nitrogen, phosphorus, potassium and organic matter exactly as to
            -- pH, or spreading fertiliser and manure keeps the bug lime had.
            local positions = {}
            local line = nil
            if HookManager ~= nil and type(HookManager.getBoomLineEndpoints) == "function" then
                local lok, l = pcall(function() return HookManager:getBoomLineEndpoints(vehicle) end)
                if lok then line = l end
            end
            if line and line.ax and line.bx then
                local dx, dz = line.bx - line.ax, line.bz - line.az
                local boomLen = math.sqrt(dx * dx + dz * dz)
                local steps = math.max(4, math.min(24, math.ceil(boomLen / 2)))
                for i = 0, steps do
                    local f = i / steps
                    positions[#positions + 1] = { x = line.ax + dx * f, z = line.az + dz * f }
                end
            else
                -- [SF-38] The old fallback was ONE sample under the vehicle root
                -- (George CLOSED DESIGN 09:04). Whenever the boom-line hook came
                -- back nil, the tractor was usually sitting on ground it had just
                -- limed, the single reading said "at target", and the dial
                -- collapsed to 0.01x while the boom tips hung over needy ground -
                -- Brian's yellow boom holes. Reuse the last known boom line for
                -- this vehicle first; failing that, sample a lateral line through
                -- the vehicle (+-9 m, 7 points) via localToWorld, so the minimum
                -- is always taken across the working width, never one wheel track.
                self._sfLastBoomLine = self._sfLastBoomLine or {}
                local cached = self._sfLastBoomLine[vehicle.id]
                if cached then
                    local dx, dz = cached.bx - cached.ax, cached.bz - cached.az
                    local steps = math.max(4, math.min(24, math.ceil(math.sqrt(dx * dx + dz * dz) / 2)))
                    for i = 0, steps do
                        local f = i / steps
                        positions[#positions + 1] = { x = cached.ax + dx * f, z = cached.az + dz * f }
                    end
                else
                    for off = -9, 9, 3 do
                        local lOk, lx, _, lz = pcall(localToWorld, vehicle.rootNode, off, 0, 0)
                        if lOk and lx then positions[#positions + 1] = { x = lx, z = lz } end
                    end
                    if #positions == 0 then
                        local vOk, vx, _, vz = pcall(getWorldTranslation, vehicle.rootNode)
                        if vOk and vx then positions[#positions + 1] = { x = vx, z = vz } end
                    end
                end
            end
            if line and line.ax and line.bx then
                -- Remember the good line so the nil-hook ticks between work areas
                -- keep sampling the true width instead of degrading to the root.
                self._sfLastBoomLine = self._sfLastBoomLine or {}
                self._sfLastBoomLine[vehicle.id] = { ax = line.ax, az = line.az, bx = line.bx, bz = line.bz }
            end
            if #positions > 0 then
                localVals = {}
                for _, key in ipairs({ "pH", "nitrogen", "phosphorus", "potassium", "organicMatter" }) do
                    local minV = nil
                    for _, pt in ipairs(positions) do
                        local sOk, v = pcall(function() return vm:readValueAtWorld(key, pt.x, pt.z) end)
                        -- [SF-43] pH sentinel/edge clamp (George CLOSED DESIGN
                        -- 12:32): reads AT the scale floor (5.0) or ceiling (7.5)
                        -- on boom tips hanging over edges/sentinel pixels are map
                        -- artefacts, not soil. Folding a 5.0 into the minimum
                        -- inflated the dial, then a 7.5 overlap read collapsed it
                        -- - the flicker behind the yellow holes. Open interval
                        -- only; when no valid sample remains, minV stays nil and
                        -- the field average wins, exactly as for unwritten cells.
                        if key == "pH" and sOk and v ~= nil then
                            local lim  = SoilConstants.NUTRIENT_LIMITS
                            local pmin = (lim and lim.PH_MIN) or 5.0
                            local pmax = (lim and lim.PH_MAX) or 7.5
                            if v <= pmin or v >= pmax then v = nil end
                        end
                        if sOk and v ~= nil and (minV == nil or v < minV) then minV = v end
                    end
                    localVals[key] = minV   -- nil where unwritten: field average wins
                end
            end
        end
    end
    -- [FIX-16] Hold the neediest reading seen in the last 15 s, per vehicle.
    --
    -- Single-tick sampling flickered: crossing a just-painted strip or the
    -- boom clipping done ground for one tick collapsed the rate (measured
    -- 1.00x -> 0.50x -> 1.00x -> 0.01x tick to tick), and every swing painted
    -- a differently dosed band -- the striping across the worker's field. A
    -- rolling minimum keeps the rate sized to the neediest ground seen
    -- recently: transients cannot drop it, and it recovers within 15 s once
    -- the ground really is done everywhere.
    if localVals then
        self._sfSenseWin = self._sfSenseWin or {}
        local now = (g_currentMission and g_currentMission.time) or 0
        local win = self._sfSenseWin[vehicle.id]
        if not win then win = {} self._sfSenseWin[vehicle.id] = win end
        win[#win + 1] = { t = now, v = localVals }
        while #win > 0 and (now - win[1].t) > 15000 do table.remove(win, 1) end
        local held = {}
        for _, entry in ipairs(win) do
            for k, v in pairs(entry.v) do
                if held[k] == nil or v < held[k] then held[k] = v end
            end
        end
        localVals = held
    end
    local newIdx = self:calculateAutoRateIndex(fieldData, fillType, localVals)
    -- [SF-34] George constraint 3: with the Precision Pack, prescription paint
    -- already varies the dose per 2 m cell, so the auto dial must not fight it.
    -- Pin the dial at 1.0x and let the prescription do the per-cell work; the
    -- close-the-gap dial is the tool for flat-broadcast machines only.
    if self:hasPrecisionPack(vehicle) then
        newIdx = SoilConstants.SPRAYER_RATE.DEFAULT_INDEX   -- 1.0x
    end
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
    else
        SoilLogger.debug("Auto-rate: vehicle %d holds index %d (%.2fx) [%s on field %d] - no change",
            vehicle.id, currentIdx,
            SoilConstants.SPRAYER_RATE.STEPS[currentIdx] or 1.0,
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
function SoilFertilityManager:calculateAutoRateIndex(fieldData, fillType, localVals)
    -- [FIX-14] localVals: the neediest (minimum) soil values sampled along the
    -- boom, keyed pH / nitrogen / phosphorus / potassium / organicMatter. Any
    -- nil falls back to the field average. A bare number still means {pH = n}.
    if type(localVals) == "number" then localVals = { pH = localVals } end
    local lv = localVals or {}
    local steps    = SoilConstants.SPRAYER_RATE.STEPS
    local defaults = SoilConstants.SPRAYER_RATE.AUTO_RATE_TARGETS
    local ct       = fieldData.cropTargets
    local targets  = ct and {
        N  = ct.N and ct.N.opt or defaults.N,
        P  = ct.P and ct.P.opt or defaults.P,
        K  = ct.K and ct.K.opt or defaults.K,
        pH = defaults.pH,
        OM = defaults.OM,
    } or defaults
    -- [SF-34] limits/phMin gone with the proportional formula: close-the-gap
    -- works in absolute gap units, so the PH_MIN normalisation range is unused.

    -- Safe multiplier bounds - never exceed BURN_RISK_THRESHOLD
    -- Floor is 0.01, not 0.20: on ground already at target the old floor kept
    -- applying a fifth of base rate, which for lime means driving pH past optimum
    -- on a field that needed nothing. 0.01 keeps the machine visibly working
    -- without meaningfully changing the soil.
    local MULT_MIN = 0.01
    local MULT_MAX = 1.20

    local multiplier = 1.0  -- default fallback

    local profile = SoilConstants.FERTILIZER_PROFILES[fillType.name]

    if profile then
        if profile.pestReduction then
            -- Insecticide: always apply at full rate (preventive/curative - not pressure-scaled)
            multiplier = 1.0

        elseif profile.diseaseReduction then
            -- Fungicide: always apply at full rate (preventive/curative - not pressure-scaled)
            multiplier = 1.0

        else
            -- [SF-34] Close-the-gap sizing (George CLOSED DESIGN 00:13).
            --
            -- The old formula mapped deficit FRACTION linearly onto the dial:
            -- proportional control whose gain was too low to ever close a real
            -- gap. Measured live on field 82 at pH 5.9 it held ~0.50x (~+0.20
            -- pH/pass) - the yellow zebra banding. Ask the real question
            -- instead: what multiplier makes ONE pass close this gap?
            --
            --     required = gap / (coeff * BASE_RATE / 1000)
            --
            -- FERTILIZER_PROFILES are calibrated per 1,000 L (kg) applied and
            -- BASE_RATES is the calibrated 1.0x rate, so coeff*base/1000 is the
            -- per-pass effect at 1.0x. LIQUIDLIME: 1.07 * 374/1000 = +0.400 pH,
            -- which at the 1.20x cap is George's ~+0.48, under SF_PASS_MAX.pH
            -- 0.60. Nothing invented; both numbers come from Constants.lua.
            -- A compound product is sized by its BIGGEST carried need, and the
            -- clamp below keeps the result inside the STEPS table and under
            -- BURN_RISK_THRESHOLD (1.25).
            local baseRow = SoilConstants.SPRAYER_RATE.BASE_RATES
                            and SoilConstants.SPRAYER_RATE.BASE_RATES[fillType.name]
            local perThousand = (baseRow and baseRow.value and baseRow.value > 0)
                                and (baseRow.value / 1000.0) or nil

            -- [SF-35] Fraction-of-gap retune (George CLOSED DESIGN 00:46).
            -- Closing the WHOLE gap in one pass slammed the dial to 1.20x and,
            -- combined with pass overlap, over-limed (Wizard/Brian TEST 00:26
            -- FAIL). One pass now attempts HALF the remaining gap, capped at the
            -- per-pass physical maximum, so a typical 0.6 pH gap asks ~0.75x and
            -- converges over passes instead of overshooting. Keep these caps in
            -- step with SF_PASS_MAX in SoilFertilitySystem's paintBoomStrip.
            local AUTO_PASS_MAX = {
                -- [SF-48] pH synced 0.30 -> 0.40 with SF_PASS_MAX (paint side).
                pH = 0.40, nitrogen = 60, phosphorus = 60, potassium = 60,
                organicMatter = 2.0,
            }

            --- Multiplier that applies 0.50 of `gap` (capped at `passMax`) in
            --- one pass via `coeff`. [SF-42] fraction 0.75 -> 0.50 (George
            --- CLOSED DESIGN 11:23): with the ~6.6 soft ceiling, 0.75 pushed the
            --- first pass straight to the ceiling and the whole field plateaued
            --- uniformly. Half-gap leaves headroom (~5.9 -> ~6.2), so only
            --- OVERLAP climbs to the ceiling and reads brighter. nil when the
            --- product does not carry this nutrient or has no calibrated base
            --- rate; 0 when no gap to close.
            local function gapMult(gap, coeff, passMax)
                if perThousand == nil or coeff == nil or coeff <= 0 then return nil end
                if gap == nil or gap <= 0 then return 0 end
                local boost = gap * 0.50
                if passMax and boost > passMax then boost = passMax end
                return boost / (coeff * perThousand)
            end

            --- [SF-44] Effective gap with a field-average FLOOR (George TRACE,
            --- CLOSED DESIGN 13:13). The boom minimum is still the primary
            --- signal ([FIX-8]), but a local-only read taken while the boom
            --- crosses a limed overlap cell reported "at target" and zeroed the
            --- dial - Brian's 0.01x windows with applied=0.0000 while needy
            --- pixels under the same boom sat unchanged. The sizing gap is now
            --- never less than HALF the field-average gap, so a transient
            --- at-target sample cannot starve ground the field still needs:
            --- effectiveGap = max(localGap, fieldGap * 0.5).
            local function effGap(localV, fieldV, target)
                local localGap = target - (localV or fieldV or target)
                local fieldGap = target - (fieldV or target)
                return math.max(localGap, fieldGap * 0.5)
            end

            --- Largest close-the-gap multiplier across the nutrients this
            --- product carries. nil when the product carries nothing we can size.
            local function requiredMultiplier(includeOM)
                local req = nil
                local function consider(m)
                    if m ~= nil and (req == nil or m > req) then req = m end
                end
                consider(gapMult(effGap(lv.nitrogen,   fieldData.nitrogen.value,   targets.N),  profile.N,  AUTO_PASS_MAX.nitrogen))
                consider(gapMult(effGap(lv.phosphorus, fieldData.phosphorus.value, targets.P),  profile.P,  AUTO_PASS_MAX.phosphorus))
                consider(gapMult(effGap(lv.potassium,  fieldData.potassium.value,  targets.K),  profile.K,  AUTO_PASS_MAX.potassium))
                consider(gapMult(effGap(lv.pH,         fieldData.pH,               targets.pH), profile.pH, AUTO_PASS_MAX.pH))
                if includeOM then
                    consider(gapMult(effGap(lv.organicMatter, fieldData.organicMatter, targets.OM), profile.OM, AUTO_PASS_MAX.organicMatter))
                end
                return req
            end

            -- Check if this is an OM-primary product (manure, compost, digestate, etc.)
            local omPrimary = SoilConstants.SPRAYER_RATE.OM_PRIMARY_PRODUCTS
            if omPrimary and omPrimary[fillType.name] and profile.OM and profile.OM > 0 then
                -- Organic product. Size the pass by whichever need is bigger: organic
                -- matter OR the N/P/K it carries (#668 - a nutrient-rich organic on an
                -- OM-rich, N/P/K-poor field is the exact case a player reaches for it).
                local omReq  = gapMult(effGap(lv.organicMatter, fieldData.organicMatter, targets.OM), profile.OM, AUTO_PASS_MAX.organicMatter) or 0
                local npkReq = requiredMultiplier(false) or 0
                multiplier = math.max(omReq, npkReq)
                SoilLogger.debug(
                    "Auto-rate calc (organic, close-the-gap): %s | omReq=%.3f | npkReq=%.3f | target multiplier=%.3f",
                    fillType.name, omReq, npkReq, multiplier)
            else
                -- Nutrient fertilizer: close the biggest gap this product can serve.
                local req = requiredMultiplier(true)
                if req then
                    multiplier = req
                    SoilLogger.debug(
                        "Auto-rate calc (close-the-gap): %s | required=%.3f | target multiplier=%.3f",
                        fillType.name, req, multiplier)
                end
            end
        end

    else
        -- Not in FERTILIZER_PROFILES - check if it is a herbicide type
        local herbTypes = SoilConstants.WEED_PRESSURE and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES
        if herbTypes and herbTypes[fillType.name] then
            -- Herbicide: always apply at full rate (preventive/knockdown - not weed-pressure-scaled)
            multiplier = 1.0
        else
            -- Unknown product type: leave at 1.0 (no adjustment). Traced so a nil-profile
            -- fill type (e.g. a seeder resolving its seed hopper instead of the fertilizer)
            -- is visible in a debug run (#809).
            SoilLogger.debug("Auto-rate calc: %s NOT in FERTILIZER_PROFILES - holding 1.0x (pinned rate)",
                tostring(fillType.name))
        end
    end

    -- [SF-45] Hard needy floor (George TRACE DESIGN 13:32): while the FIELD
    -- AVERAGE pH is still below target, a lime product never dials under 0.60x,
    -- whatever the local sample momentarily says. The effGap field-average
    -- floor stays as the secondary, proportional defence; this is the blunt
    -- one that makes 0.01x zero-apply windows on a needy field impossible.
    if profile and profile.pH and profile.pH > 0 then
        local fieldPH = fieldData and fieldData.pH
        if fieldPH ~= nil and fieldPH < targets.pH and multiplier < 0.60 then
            multiplier = 0.60
        end
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
--- Uninstalls hooks and flushes logs. Does NOT save soil data on purpose: persistence
--- goes through the FSCareerMissionInfo:saveToXMLFile hook only, so soilData.xml stays in
--- sync with the actual savegame. Writing here would persist unsaved soil changes on a
--- quit-without-save (the #730 follow-up HStein72 reported). Console force-saves and the
--- save hook remain the only write paths for gameplay soil state.
function SoilFertilityManager:delete()
    -- Flush any buffered debug messages to file before shutdown
    SoilLogger.flushDebugLog()

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

    -- Clean up smart sensor state
    if self.sensorManager then
        self.sensorManager:delete()
        self.sensorManager = nil
    end
    if self.variableRatePanel then
        self.variableRatePanel:delete()
        self.variableRatePanel = nil
    end
    if self.smartSensorPanel then
        self.smartSensorPanel:delete()
        self.smartSensorPanel = nil
    end
    if self.sprayerInfoPanel then
        self.sprayerInfoPanel:delete()
        self.sprayerInfoPanel = nil
    end
    if self.harvesterPanel then
        self.harvesterPanel:delete()
        self.harvesterPanel = nil
    end

    -- Clean up all registered input action events (PLAYER context)
    if self.toggleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.toggleHUDEventId)
        self.toggleHUDEventId = nil
    end

    -- Clean up VEHICLE context events
    if self.vehicleHUDEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleHUDEventId)
        self.vehicleHUDEventId = nil
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

    if self.sensorPestEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.sensorPestEventId)
        self.sensorPestEventId = nil
    end
    if self.sensorDiseaseEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.sensorDiseaseEventId)
        self.sensorDiseaseEventId = nil
    end
    if self.sensorNutrientEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.sensorNutrientEventId)
        self.sensorNutrientEventId = nil
    end
    if self.seeSprayPestEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.seeSprayPestEventId)
        self.seeSprayPestEventId = nil
    end
    if self.seeSprayDiseaseEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.seeSprayDiseaseEventId)
        self.seeSprayDiseaseEventId = nil
    end
    if self.seeSprayWeedEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.seeSprayWeedEventId)
        self.seeSprayWeedEventId = nil
    end
    if self.variableRateEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.variableRateEventId)
        self.variableRateEventId = nil
    end

    if self.cycleMapLayerEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.cycleMapLayerEventId)
        self.cycleMapLayerEventId = nil
    end

    if self.vehicleCycleMapLayerEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleCycleMapLayerEventId)
        self.vehicleCycleMapLayerEventId = nil
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

    if self.minimapZoomEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.minimapZoomEventId)
        self.minimapZoomEventId = nil
    end

    if self.vehicleMinimapZoomEventId and g_inputBinding then
        g_inputBinding:removeActionEvent(self.vehicleMinimapZoomEventId)
        self.vehicleMinimapZoomEventId = nil
    end

    if self.soilMinimapLayer then
        self.soilMinimapLayer:delete()
        self.soilMinimapLayer = nil
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

    if self.tuningPanel then
        self.tuningPanel:delete()
        self.tuningPanel = nil
    end

    if self.cropTuningPanel then
        self.cropTuningPanel:delete()
        self.cropTuningPanel = nil
    end

    if self.settingsPanel then
        self.settingsPanel:delete()
        self.settingsPanel = nil
    end

    if self.soilSystem then
        self.soilSystem:delete()
    end

    -- SF-53 growth credit: drop the message-center subscription and the store.
    if self.growthCredit then
        self.growthCredit:delete()
        self.growthCredit = nil
    end

    -- SF-78 growth block: drop both message subscriptions and the capture.
    if self.growthBlock then
        self.growthBlock:delete()
        self.growthBlock = nil
    end

    -- SF-14 zone yield: drop the accrual state and the fallback marker.
    if self.zoneYield then
        self.zoneYield:delete()
        self.zoneYield = nil
    end

    -- SF-77 topography cache: drop the terrain listener and the grids.
    if self.topography then
        self.topography:delete()
        self.topography = nil
    end
    -- Do NOT flush settings on shutdown. delete() runs on every quit, including a
    -- quit-without-save, so a save here rewrote FS25_SoilFertilizer.xml out of step
    -- with the rest of the savegame (the settings twin of the soilData-on-quit bug,
    -- #730). Real persistence is already covered: every change point saves immediately
    -- and the FSCareerMissionInfo:saveToXMLFile hook writes on a genuine save/autosave.
    SoilLogger.info("Shutting down")
end
-- ============================================================
-- SF-52 THE PUBLISHED GROWTH CONTRACT (cross-mod surface)
--
-- SF-53, SF-54 and SCS-020 bind to these two, and two of them live in other
-- mods. They are delegates on the MANAGER rather than reads of the `viability`
-- field on purpose: `g_currentMission.soilFertilityManager` is the only handle
-- that crosses the mod boundary (g_SoilFertilityManager is per-mod scoped via
-- getfenv(0) and is not reachable from another mod), and a consumer reaching
-- through `.viability` would be binding to an internal field name that a
-- refactor here could rename out from under three mods at once.
--
-- Both are nil-safe in every direction: absent subsystem, absent field, mask
-- disabled, or a value map that is not carrying data all return nil rather
-- than throwing across the boundary.
--
-- Consumers should call these as:
--   local sfm = g_currentMission and g_currentMission.soilFertilityManager
--   local info = sfm and sfm:getCellGrowthInfo(fieldId, x, z)
-- ============================================================

--- Per-cell growth judgement at a world position.
--- @return table|nil { blocked, blockedBy, bands, credit, capturedEfficiency }
function SoilFertilityManager:getCellGrowthInfo(fieldId, x, z)
    local v = self.viability
    if v == nil or type(v.getCellGrowthInfo) ~= 'function' then return nil end
    local ok, info = pcall(function() return v:getCellGrowthInfo(fieldId, x, z) end)
    if not ok then return nil end
    return info
end

--- Field-level area fractions in the outer bands.
--- @return table|nil { blockedFrac, excellentFrac }
function SoilFertilityManager:getFieldGrowthSummary(fieldId)
    local v = self.viability
    if v == nil or type(v.getFieldGrowthSummary) ~= 'function' then return nil end
    local ok, summary = pcall(function() return v:getFieldGrowthSummary(fieldId) end)
    if not ok then return nil end
    return summary
end

-- ============================================================
-- SF-49 THE WATER RECORD READ (cross-mod surface)
--
-- SeasonalCropStress's caught-up-hour (SCS-037 round 2) reconstructs the rain
-- switch across a skipped day from SoilFertilizer's Water Record. The record
-- lives on the wetness subsystem, three internal field names deep, which is
-- exactly the coupling SoilFertilizer's own cross-boundary rule forbids. So it
-- is delegated here, on the manager, at the same boundary the growth contract
-- above crosses: `g_currentMission.soilFertilityManager`.
--
-- NEUTRAL, not a claim. nil means "we do not know", never "it was dry". A
-- closed ground_material gate, a missing or unarmed wetness subsystem, a
-- throwing read, and an empty record all return nil so the consumer falls back
-- to the honest approximation instead of trusting a zero it did not earn.
-- ============================================================

--- How many of the last `days` days (through `throughDay`) brought water.
---@param days number how many trailing days to ask about
---@param throughDay number|nil day cursor; nil means the record's own applied-through
---@return number|nil count number of wet days, nil when unknown
---@return number|nil known how many of the window the record covers
function SoilFertilityManager:getWaterDaysInLast(days, throughDay)
    local mw = self.soilSystem and self.soilSystem.materialWetness
    if mw == nil or type(mw.waterDaysInLast) ~= 'function' then return nil end
    if not mw:isArmed() then return nil end
    if not ReleaseGate.isSystemLive("ground_material") then return nil end
    local ok, count, known = pcall(mw.waterDaysInLast, mw, days, throughDay)
    if not ok then return nil end
    if known == nil or known <= 0 then return nil end
    return count, known
end

--- [SF-23] Positional nutrient/OM sample for cross-mod consumers (the brief's
--- reciprocal read). SeasonalCropStress reads SF's spatial state the way SF reads
--- its moisture: read-only, nil when the value maps are unavailable or the pixel
--- is unwritten. Never a write across the firewall.
---@param key string  "nitrogen" | "phosphorus" | "potassium" | "pH" | "organicMatter"
---@param x number
---@param z number
---@return number|nil
function SoilFertilityManager:getSoilValueAtWorld(key, x, z)
    if SpatialNutrients == nil or SpatialNutrients.getSoilValueAtWorld == nil then return nil end
    local ok, v = pcall(SpatialNutrients.getSoilValueAtWorld, SpatialNutrients, self.soilSystem, key, x, z)
    if not ok then return nil end
    return v
end
