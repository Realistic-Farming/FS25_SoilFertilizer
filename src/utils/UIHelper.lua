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

local function _trimCurrencyText(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("%s+", " ")
    text = text:gsub("%s+%p", "%1")
    text = text:gsub("%p%s+", "%1")
    return text
end

function UIHelper.getCurrencySymbol()
    if g_i18n then
        if g_i18n.getCurrencySymbol and type(g_i18n.getCurrencySymbol) == "function" then
            local symbol = g_i18n:getCurrencySymbol()
            if symbol and symbol ~= "" then
                return symbol
            end
        end

        if g_i18n.getCurrency and type(g_i18n.getCurrency) == "function" then
            local symbol = g_i18n:getCurrency()
            if symbol and symbol ~= "" then
                return symbol
            end
        end

        if g_i18n.formatMoney and type(g_i18n.formatMoney) == "function" then
            local formatted = g_i18n:formatMoney(1)
            if formatted and formatted ~= "" then
                local symbol = formatted:gsub("%d", ""):gsub("[%,%.]", ""):gsub("%s+", "")
                symbol = _trimCurrencyText(symbol)
                if symbol and symbol ~= "" then
                    return symbol
                end
            end
        end
    end

    return "$"
end

function UIHelper.formatCurrencyValue(value, decimals)
    local amount = tonumber(value) or 0
    local decimalPlaces = tonumber(decimals)
    if decimalPlaces == nil then
        decimalPlaces = 0
    end

    if g_i18n and g_i18n.formatMoney and type(g_i18n.formatMoney) == "function" then
        local formatted = g_i18n:formatMoney(amount)
        if formatted and formatted ~= "" then
            return formatted
        end
    end

    local symbol = UIHelper.getCurrencySymbol()
    if decimalPlaces > 0 then
        return string.format("%s%." .. tostring(decimalPlaces) .. "f", symbol, amount)
    end
    return string.format("%s%d", symbol, math.floor(amount + 0.5))
end

getfenv(0)["UIHelper"] = UIHelper
getfenv(0)["g_UIHelper"] = UIHelper

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
