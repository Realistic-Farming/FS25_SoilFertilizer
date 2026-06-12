-- =========================================================
-- FS25 Realistic Soil & Fertilizer
-- =========================================================
-- UIHelper - Profile-based UI element creation
-- Pattern from: FS25_UsedPlus/src/gui/UsedPlusSettingsMenuExtension.lua
-- =========================================================
-- Replaces clone-based approach that corrupted other mods'
-- settings pages on dedicated server clients (GitHub #21).
-- =========================================================
---@class UIHelper
UIHelper = {}

--- Create a section header element using FS25 profile
---@param layout table The gameSettingsLayout to add to
---@param text string The section header text
---@return table|nil The created text element
function UIHelper.createSectionHeader(layout, text)
    if not layout then
        SoilLogger.error("Invalid layout passed to createSectionHeader")
        return nil
    end

    local textElement = TextElement.new()
    local profile = g_gui:getProfile("fs25_settingsSectionHeader")
    textElement.name = "sectionHeader"
    textElement:loadProfile(profile, true)
    textElement:setText(text)
    layout:addElement(textElement)
    textElement:onGuiSetupFinished()

    return textElement
end

--- Create a binary (Yes/No) toggle option using FS25 profiles
---@param layout table The gameSettingsLayout to add to
---@param callbackTarget table The object that owns the callback method
---@param callbackName string The method name on callbackTarget to call on click
---@param title string Display text for the setting label
---@param tooltip string Tooltip text shown on hover
---@return table|nil The created BinaryOptionElement
function UIHelper.createBinaryOption(layout, callbackTarget, callbackName, title, tooltip)
    if not layout then
        SoilLogger.error("Invalid layout passed to createBinaryOption")
        return nil
    end

    local bitMap = BitmapElement.new()
    layout:addElement(bitMap)

    local binaryOption = BinaryOptionElement.new()
    binaryOption.useYesNoTexts = true
    bitMap:addElement(binaryOption)

    local titleElement = TextElement.new()
    bitMap:addElement(titleElement)

    local tooltipElement = TextElement.new()
    tooltipElement.name = "ignore"
    binaryOption:addElement(tooltipElement)

    bitMap:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    binaryOption:loadProfile(g_gui:getProfile("fs25_settingsBinaryOption"), true)
    binaryOption.target = callbackTarget
    binaryOption:setCallback("onClickCallback", callbackName)

    titleElement:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    titleElement:setText(title)

    tooltipElement:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltipElement:setText(tooltip)

    tooltipElement:onGuiSetupFinished()
    titleElement:onGuiSetupFinished()
    binaryOption:onGuiSetupFinished()
    bitMap:onGuiSetupFinished()

    return binaryOption
end

--- Create a multi-text option (dropdown) using FS25 profiles
---@param layout table The gameSettingsLayout to add to
---@param callbackTarget table The object that owns the callback method
---@param callbackName string The method name on callbackTarget to call on click
---@param texts table Array of display strings for the dropdown options
---@param title string Display text for the setting label
---@param tooltip string Tooltip text shown on hover
---@return table|nil The created MultiTextOptionElement
function UIHelper.createMultiOption(layout, callbackTarget, callbackName, texts, title, tooltip)
    if not layout then
        SoilLogger.error("Invalid layout passed to createMultiOption")
        return nil
    end

    local bitMap = BitmapElement.new()
    layout:addElement(bitMap)

    local multiTextOption = MultiTextOptionElement.new()
    bitMap:addElement(multiTextOption)

    local titleElement = TextElement.new()
    bitMap:addElement(titleElement)

    local tooltipElement = TextElement.new()
    tooltipElement.name = "ignore"
    multiTextOption:addElement(tooltipElement)

    bitMap:loadProfile(g_gui:getProfile("fs25_multiTextOptionContainer"), true)

    multiTextOption:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOption"), true)
    multiTextOption.target = callbackTarget
    multiTextOption:setCallback("onClickCallback", callbackName)
    multiTextOption:setTexts(texts)

    titleElement:loadProfile(g_gui:getProfile("fs25_settingsMultiTextOptionTitle"), true)
    titleElement:setText(title)

    tooltipElement:loadProfile(g_gui:getProfile("fs25_multiTextOptionTooltip"), true)
    tooltipElement:setText(tooltip)

    tooltipElement:onGuiSetupFinished()
    titleElement:onGuiSetupFinished()
    multiTextOption:onGuiSetupFinished()
    bitMap:onGuiSetupFinished()

    return multiTextOption
end
