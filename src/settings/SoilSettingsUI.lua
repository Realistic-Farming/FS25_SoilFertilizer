-- =========================================================
-- FS25 Realistic Soil & Fertilizer
-- =========================================================
-- Settings UI - profile-based element creation
-- Pattern from: FS25_UsedPlus/src/gui/UsedPlusSettingsMenuExtension.lua
-- =========================================================
-- Hooks InGameMenuSettingsFrame at file-load time (runs once).
-- Elements are created via FS25 profiles, not clone().
-- This eliminates the white settings page bug on dedicated
-- server clients (GitHub #21).
-- =========================================================
---@class SoilSettingsUI

SoilSettingsUI = {}
local SoilSettingsUI_mt = Class(SoilSettingsUI)

-- Capture mod name at load time — g_currentModName is only valid during loading.
local SF_MOD_NAME = g_currentModName

-- The 3 settings injected into the vanilla settings page (Shift+Esc).
-- Everything else lives in the custom SoilSettingsPanel (Shift+O).
local VANILLA_SETTINGS = { "enabled", "showNotifications", "debugMode" }

-- Resolve a translation key using the mod-scoped i18n instance.
-- g_i18n is the base-game global and does not know about mod keys.
local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

function SoilSettingsUI.new(settings)
    local self = setmetatable({}, SoilSettingsUI_mt)
    self.settings = settings
    self._resetButton = nil
    return self
end

-- Check if current player is admin
function SoilSettingsUI:isPlayerAdmin()
    return SoilUtils.isPlayerAdmin()
end

-- Show admin-only warning
function SoilSettingsUI:showAdminOnlyWarning()
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(
            "Only server admins can change Soil & Fertilizer settings",
            5000
        )
    end

    if g_gui and g_gui.showInfoDialog then
        g_gui:showInfoDialog({
            text = "Only the server admin can change Soil & Fertilizer Mod settings.\n\nIf you are the server owner, make sure you are logged in as admin.",
            callback = nil
        })
    end
end

-- Request setting change via network (or apply directly if server/singleplayer)
function SoilSettingsUI:requestSettingChange(settingName, value)
    -- Local-only settings (HUD display prefs) bypass admin check and network sync entirely
    local def = SettingsSchema.byId[settingName]
    if def and def.localOnly then
        self.settings[settingName] = value
        self.settings:save()
        return
    end

    if not self:isPlayerAdmin() then
        self:showAdminOnlyWarning()
        self:refreshUI()
        return
    end

    if SoilNetworkEvents_RequestSettingChange then
        SoilNetworkEvents_RequestSettingChange(settingName, value)
    else
        self.settings[settingName] = value
        self.settings:save()
        SoilLogger.info("Setting '%s' changed to %s", settingName, tostring(value))
    end
end

-- Refresh UI elements to match current settings values
function SoilSettingsUI:refreshUI()
    -- Find the current settings frame
    if not g_gui or not g_gui.screenControllers then return end
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if not inGameMenu or not inGameMenu.pageSettings then return end
    local frame = inGameMenu.pageSettings
    if not frame.soilFertilizer_initDone then return end

    for _, id in ipairs(VANILLA_SETTINGS) do
        local def = SettingsSchema.byId[id]
        if def then
            local element = frame["soilFertilizer_" .. def.uiId]
            if element and element.setIsChecked then
                element:setIsChecked(self.settings[def.id] == true, false, false)
            end
        end
    end
end

--- Re-enable/disable all settings elements based on current admin status.
--- Called on every frame open so that players who gain admin after first open are handled.
function SoilSettingsUI:updateAdminState(frame)
    if not frame.soilFertilizer_initDone then return end
    local isAdmin = self:isPlayerAdmin()

    for _, id in ipairs(VANILLA_SETTINGS) do
        local def = SettingsSchema.byId[id]
        if def then
            local element = frame["soilFertilizer_" .. def.uiId]
            if element and element.setIsEnabled then
                element:setIsEnabled(isAdmin)
                if element.setToolTipText then
                    element:setToolTipText(isAdmin and "" or "Admin only")
                end
            end
        end
    end
end

--- Called when InGameMenuSettingsFrame opens.
--- Only injects the 3 core settings kept in the vanilla page.
function SoilSettingsUI:onFrameOpen(frame)
    if frame.soilFertilizer_initDone then
        self:updateAdminState(frame)
        self:updateGameSettings(frame)
        return
    end

    local layout = frame.gameSettingsLayout
    if not layout then
        SoilLogger.warning("gameSettingsLayout not found on frame")
        return
    end

    local isAdmin = self:isPlayerAdmin()

    -- Section header with hint to open full settings panel
    local ok, err = pcall(UIHelper.createSectionHeader, layout,
        (tr("sf_section") or "Soil & Fertilizer") .. "  (SHIFT+O for full settings)")
    if not ok then
        SoilLogger.warning("Failed to create section header: %s", tostring(err))
    end

    -- Only inject: enabled, showNotifications, debugMode
    for _, id in ipairs(VANILLA_SETTINGS) do
        local def = SettingsSchema.byId[id]
        if def and def.type == "boolean" then
            local callbackName = "on_" .. def.id .. "_Changed"
            local title   = tr(def.uiId .. "_short") or def.id
            local tooltip = tr(def.uiId .. "_long")  or ""
            local ok3, element = pcall(UIHelper.createBinaryOption, layout,
                SoilSettingsUI, callbackName, title, tooltip)
            if ok3 and element then
                local shouldDisable = not def.localOnly and not isAdmin
                if shouldDisable and element.setIsEnabled then
                    element:setIsEnabled(false)
                    if element.setToolTipText then element:setToolTipText("Admin only") end
                end
                frame["soilFertilizer_" .. def.uiId] = element
            else
                SoilLogger.warning("Failed to create toggle for %s: %s", id, tostring(element))
            end
        end
    end

    layout:invalidateLayout()
    if frame.updateAlternatingElements then frame:updateAlternatingElements(layout) end
    if frame.updateGeneralSettings     then frame:updateGeneralSettings(layout)     end

    frame.soilFertilizer_initDone = true
    self:updateGameSettings(frame)
    SoilLogger.info("Vanilla settings UI injected (3 core settings, Admin: %s)", tostring(isAdmin))
end

--- Sync the 3 vanilla settings elements with current values.
function SoilSettingsUI:updateGameSettings(frame)
    if not frame.soilFertilizer_initDone then return end

    for _, id in ipairs(VANILLA_SETTINGS) do
        local def = SettingsSchema.byId[id]
        if def then
            local element = frame["soilFertilizer_" .. def.uiId]
            if element then
                local val = self.settings[def.id]
                if def.type == "boolean" and element.setIsChecked then
                    element:setIsChecked(val == true, false, false)
                end
            end
        end
    end
end

-- Callbacks for the vanilla settings only
for _, id in ipairs(VANILLA_SETTINGS) do
    local def = SettingsSchema.byId[id]
    if def then
        SoilSettingsUI["on_" .. def.id .. "_Changed"] = function(self, state)
            if not g_SoilFertilityManager or not g_SoilFertilityManager.settingsUI then return end
            local isChecked = (state == BinaryOptionElement.STATE_RIGHT)
            g_SoilFertilityManager.settingsUI:requestSettingChange(def.id, isChecked)
        end
    end
end

-- Install hooks at file-load time (runs once, never accumulates on level reload)
local function init()
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuSettingsFrame.onFrameOpen,
        function(frame)
            if g_SoilFertilityManager and g_SoilFertilityManager.settingsUI then
                g_SoilFertilityManager.settingsUI:onFrameOpen(frame)
            end
        end
    )

    InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(
        InGameMenuSettingsFrame.updateGameSettings,
        function(frame)
            if g_SoilFertilityManager and g_SoilFertilityManager.settingsUI then
                g_SoilFertilityManager.settingsUI:updateGameSettings(frame)
            end
        end
    )

    SoilLogger.info("Settings UI hooks installed (file-load time)")
end

init()
