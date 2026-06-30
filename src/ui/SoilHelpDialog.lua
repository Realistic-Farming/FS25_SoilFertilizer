-- =========================================================
-- FS25 Soil & Fertilizer - PDA Help Dialog
-- =========================================================
-- Opened from the PDA screen X/help button.
-- Two-column layout: nutrients/chemistry/targets | status/pressure/tips
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilHelpDialog
SoilHelpDialog = {}
local SoilHelpDialog_mt = Class(SoilHelpDialog, ScreenElement)

local SF_HELP_MOD_NAME = g_currentModName
local SF_HELP_MOD_DIR  = g_currentModDirectory

SoilHelpDialog.INSTANCE = nil

-- Content table: {t="H"|"B"|"S"|"COL", v="text"}
-- H   = section header (bold, green, uppercase)
-- B   = body line (white, normal)
-- S   = spacer (blank gap)
-- COL = column break - switch from col1 to col2
SoilHelpDialog.CONTENT = {
    -- ── LEFT COLUMN ──────────────────────────────────────
    { t="H", v="NUTRIENTS" },
    { t="B", v="N  (Nitrogen)    \226\128\148 Depletes every harvest." },
    { t="B", v="   Apply UAN, Urea, AMS, or Manure." },
    { t="B", v="P  (Phosphorus)  \226\128\148 Long-lasting." },
    { t="B", v="   Apply MAP, DAP, Liquid MAP, or Liquid DAP." },
    { t="B", v="K  (Potassium)   \226\128\148 Critical for root crops." },
    { t="B", v="   Apply Potash or Liquid Potash." },
    { t="B", v="OM (Organic Mat.) \226\128\148 Builds slowly." },
    { t="B", v="   Incorporate Manure, Compost, or Biosolids." },
    { t="S", v=" " },
    { t="H", v="SOIL CHEMISTRY" },
    { t="B", v="pH 6.5 - 7.0 = Ideal range." },
    { t="B", v="Apply Lime if below 6.5 (too acidic)." },
    { t="B", v="Apply Gypsum if above 7.5 (over-limed)." },
    { t="B", v="Allow 1-2 seasons to normalize after treatment." },
    { t="S", v=" " },
    { t="H", v="CROP TARGETS" },
    { t="B", v="Each crop has unique N / P / K requirements." },
    { t="B", v="The map tooltip shows the gap between your" },
    { t="B", v="current level and the crop's optimal target." },
    { t="B", v="Green = at or above target." },
    { t="B", v="Red = deficit. Hover a map cell to inspect." },
    -- ── COLUMN BREAK ─────────────────────────────────────
    { t="COL", v="" },
    -- ── RIGHT COLUMN ─────────────────────────────────────
    { t="H", v="STATUS LEVELS" },
    { t="B", v="Good  (green)  \226\128\148 At or above optimal." },
    { t="B", v="   No action needed." },
    { t="B", v="Fair  (yellow) \226\128\148 Below optimal." },
    { t="B", v="   Monitor or apply a preventive top-up." },
    { t="B", v="Poor  (red)    \226\128\148 Below minimum." },
    { t="B", v="   Immediate treatment required." },
    { t="S", v=" " },
    { t="H", v="CROP PRESSURE" },
    { t="B", v="Weed    > 20% \226\128\148 Apply Herbicide or use" },
    { t="B", v="   mechanical weeder / hoe." },
    { t="B", v="Pest    > 20% \226\128\148 Apply Insecticide." },
    { t="B", v="Disease > 20% \226\128\148 Apply Fungicide." },
    { t="S", v=" " },
    { t="H", v="TIPS" },
    { t="B", v="* Open Treatment Plan tab - fields sorted" },
    { t="B", v="  by urgency so you treat the worst first." },
    { t="B", v="* Soil overlay (M key, Soil Layers tab)" },
    { t="B", v="  shows per-cell colour-coded data." },
    { t="B", v="* Rain leaches N. Avoid heavy N application" },
    { t="B", v="  before forecast rain or in autumn." },
    { t="B", v="* Legume crops (soy, clover) add a free" },
    { t="B", v="  N bonus on the next season." },
}

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_HELP_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Constructor ───────────────────────────────────────────

function SoilHelpDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilHelpDialog_mt)
    self._contentLineEls = {}
    return self
end

function SoilHelpDialog.register(modDirectory)
    if SoilHelpDialog.INSTANCE ~= nil then return end

    SF_HELP_MOD_DIR = modDirectory
    local xmlPath = modDirectory .. "xml/gui/SoilHelpDialog.xml"

    SoilHelpDialog.INSTANCE = SoilHelpDialog.new()
    SoilLogger.info("SoilHelpDialog: registering from %s", xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(xmlPath, "SoilHelpDialog", SoilHelpDialog.INSTANCE)
    end)

    if not ok then
        SoilLogger.error("SoilHelpDialog: loadGui failed: %s", tostring(err))
        SoilHelpDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilHelpDialog: registered successfully")
    end
end

function SoilHelpDialog.show()
    if SoilHelpDialog.INSTANCE == nil then
        SoilHelpDialog.register(SF_HELP_MOD_DIR)
    end
    if SoilHelpDialog.INSTANCE == nil then return end
    g_gui:showDialog("SoilHelpDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilHelpDialog:onGuiSetupFinished()
    SoilHelpDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("sfHelp_col1")
    self._elCol2 = self:getDescendantById("sfHelp_col2")
end

function SoilHelpDialog:onOpen()
    SoilHelpDialog:superClass().onOpen(self)
    self:_buildContent()
end

function SoilHelpDialog:onClose()
    SoilHelpDialog:superClass().onClose(self)
    self:_clearContent()
end

-- ── Content Builder ───────────────────────────────────────

function SoilHelpDialog:_buildContent()
    local profileH = g_gui:getProfile("sfHelp_colHeader")
    local profileB = g_gui:getProfile("sfHelp_colBody")
    local profileS = g_gui:getProfile("sfHelp_colSpacer")

    if not profileH or not profileB then
        SoilLogger.warning("SoilHelpDialog: required column profiles not found")
        return
    end

    local currentBox = self._elCol1

    for _, row in ipairs(SoilHelpDialog.CONTENT) do
        if row.t == "COL" then
            if self._elCol1 then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB

            if profile then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v)
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end

    if self._elCol2 then self._elCol2:invalidateLayout() end
end

function SoilHelpDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls) do
        if entry.box then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
end

-- ── Button ────────────────────────────────────────────────

function SoilHelpDialog:onClickClose()
    g_gui:closeDialogByName("SoilHelpDialog")
end
