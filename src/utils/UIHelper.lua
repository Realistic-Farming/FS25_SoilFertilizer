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
UIHelper = UIHelper or {}

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

-- =========================================================
-- Text fitting for the raw renderText surfaces (issue #771)
-- =========================================================
-- Ten files under src/ui/ draw with raw renderText, and raw renderText gets NO
-- fitting behaviour from the engine: nothing measures, nothing shrinks, nothing
-- truncates, the glyphs just draw past the box. That is why a longer translation
-- overlaps the next column. GUI TextElement surfaces get this for free from their
-- profile; these do not, and no profile can reach them.
--
-- This is a straight port of the base game's own answer, TextElement RESIZE
-- (gui/elements/TextElement.lua:479-490): shrink the text by 5 percent of its
-- default size per step until it fits, floor at a minimum size, and only then
-- fall back to truncation with an ellipsis. Shrinking first is what keeps a label
-- readable instead of cutting a word in half.
--
-- Not a German problem. Finnish, Hungarian and Russian sit in the same length
-- band, and English gets there the day a label grows. Verify layout against the
-- longest language, never against English.

UIHelper.TEXT_MIN_SIZE_FACTOR = 0.7   -- floor, as a fraction of the requested size
UIHelper.TEXT_SHRINK_STEP     = 0.05  -- per step, as a fraction of the requested size
UIHelper.TEXT_ELLIPSIS        = "..."

---Fit text into maxWidth by shrinking, then truncating as a last resort.
---Measurement uses the CURRENT bold state, so call setTextBold before this.
---@param text string
---@param textSize number the size you would have passed to renderText
---@param maxWidth number available width in screen space; nil or <= 0 disables fitting
---@param minSizeFactor number|nil floor as a fraction of textSize (default 0.7)
---@param ellipsis string|nil trailing marker when truncation is reached (default "...")
---@return string fittedText, number fittedSize
function UIHelper.fitText(text, textSize, maxWidth, minSizeFactor, ellipsis)
    if type(text) ~= "string" or text == "" then return text or "", textSize end
    if type(maxWidth) ~= "number" or maxWidth <= 0 then return text, textSize end
    if type(textSize) ~= "number" or textSize <= 0 then return text, textSize end
    if getTextWidth == nil then return text, textSize end

    local size    = textSize
    local minSize = textSize * (minSizeFactor or UIHelper.TEXT_MIN_SIZE_FACTOR)
    local step    = textSize * UIHelper.TEXT_SHRINK_STEP
    local mark    = ellipsis or UIHelper.TEXT_ELLIPSIS

    while maxWidth < getTextWidth(size, text) do
        size = size - step
        if size <= minSize then
            -- Step back to the last size at or above the floor, then truncate.
            size = size + step
            if Utils ~= nil and Utils.limitTextToWidth ~= nil then
                text = Utils.limitTextToWidth(text, size, maxWidth, false, mark)
            end
            break
        end
    end

    return text, size
end

---renderText that fits first. Drop-in for a raw renderText call that has a known
---column width. Same argument order as renderText, with the width appended.
---@param x number
---@param y number
---@param textSize number
---@param text string
---@param maxWidth number|nil nil renders exactly like renderText
---@param minSizeFactor number|nil
---@param ellipsis string|nil
---@return number renderedSize the size actually used, after any shrink
function UIHelper.renderTextFitted(x, y, textSize, text, maxWidth, minSizeFactor, ellipsis)
    local fitted, size = UIHelper.fitText(text, textSize, maxWidth, minSizeFactor, ellipsis)
    renderText(x, y, size, fitted)
    return size
end
