-- =========================================================
-- FS25 Soil & Fertilizer - Soil Map Overlay Help Dialog
-- =========================================================
-- Opened from the Help button in the overlay sidebar.
-- Two-column layout: how-to-read/layers | tooltip/legend/buttons/tips
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilOverlayHelpDialog
SoilOverlayHelpDialog = {}
local SoilOverlayHelpDialog_mt = Class(SoilOverlayHelpDialog, ScreenElement)

local SF_OVHELP_MOD_NAME = g_currentModName
local SF_OVHELP_MOD_DIR  = g_currentModDirectory

SoilOverlayHelpDialog.INSTANCE = nil

-- Content table: {t="H"|"B"|"S"|"COL", v="text"}
-- H   = section header (bold, green, uppercase)
-- B   = body line (white, normal)
-- S   = spacer (blank gap)
-- COL = column break - switch from col1 to col2
SoilOverlayHelpDialog.CONTENT = {
    -- ── LEFT COLUMN ──────────────────────────────────────
    { t="H", v="HOW TO READ THE MAP" },
    { t="B", v="Each cell is colour-coded for the active layer." },
    { t="B", v="Nutrient layers: Red = Poor, Yellow = Fair," },
    { t="B", v="Green = Good (at or above the crop target)." },
    { t="B", v="Pressure and compaction layers flip the scale:" },
    { t="B", v="green means low/safe, red means high/bad." },
    { t="B", v="Dim cells are unsampled. Drive or walk the" },
    { t="B", v="field to record a soil reading there." },
    { t="S", v=" " },
    { t="H", v="THE 12 MAP LAYERS" },
    { t="B", v="1  Nitrogen (N)    Drops on every harvest." },
    { t="B", v="2  Phosphorus (P)  Slow-moving, long lasting." },
    { t="B", v="3  Potassium (K)   Key for root crops." },
    { t="B", v="4  pH              6.5 to 7.0 is the target." },
    { t="B", v="5  Organic Matter  Structure and buffering." },
    { t="B", v="6  Urgency         Overall attention score." },
    { t="B", v="7  Weed pressure   Green low, red high." },
    { t="B", v="8  Pest pressure   Insect population." },
    { t="B", v="9  Disease         Fungal load on the crop." },
    { t="B", v="10 Compaction      Heavy-traffic damage." },
    { t="B", v="11 Yield forecast  Expected harvest percent." },
    -- ── COLUMN BREAK ─────────────────────────────────────
    { t="COL", v="" },
    -- ── RIGHT COLUMN ─────────────────────────────────────
    { t="H", v="CELL DETAIL (CLICK A CELL)" },
    { t="B", v="Click any cell to pin its exact value," },
    { t="B", v="its Good / Fair / Poor status, and - when a" },
    { t="B", v="crop is planted - the crop target and the" },
    { t="B", v="gap above or below it. Click again to clear." },
    { t="S", v=" " },
    { t="H", v="COLOUR LEGEND (SIDEBAR)" },
    { t="B", v="The gradient bar shows which colour means" },
    { t="B", v="which status for the layer you are viewing." },
    { t="S", v=" " },
    { t="H", v="SIDEBAR CONTROLS" },
    { t="B", v="Layer list     Pick any of the 11 layers." },
    { t="B", v="Farm Overview  Open the PDA soil report." },
    { t="B", v="Treatment Plan Fields sorted by urgency." },
    { t="B", v="Disable Overlay Turn the overlay off." },
    { t="B", v="Help           You are reading it." },
    { t="S", v=" " },
    { t="H", v="TIPS" },
    { t="B", v="The number on a field tile is its average." },
    { t="B", v="Zoom in to see per-cell variation." },
    { t="B", v="Cycle layers on foot with Cycle Soil Map" },
    { t="B", v="Layer (bind it in Options > Controls > Mods)." },
}

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_OVHELP_MOD_NAME]
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

function SoilOverlayHelpDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilOverlayHelpDialog_mt)
    self._contentLineEls = {}
    return self
end

function SoilOverlayHelpDialog.register(modDirectory)
    if SoilOverlayHelpDialog.INSTANCE ~= nil then return end

    SF_OVHELP_MOD_DIR = modDirectory
    local xmlPath = modDirectory .. "xml/gui/SoilOverlayHelpDialog.xml"

    SoilOverlayHelpDialog.INSTANCE = SoilOverlayHelpDialog.new()
    SoilLogger.info("SoilOverlayHelpDialog: registering from %s", xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(xmlPath, "SoilOverlayHelpDialog", SoilOverlayHelpDialog.INSTANCE)
    end)

    if not ok then
        SoilLogger.error("SoilOverlayHelpDialog: loadGui failed: %s", tostring(err))
        SoilOverlayHelpDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilOverlayHelpDialog: registered successfully")
    end
end

function SoilOverlayHelpDialog.show()
    if SoilOverlayHelpDialog.INSTANCE == nil then
        SoilOverlayHelpDialog.register(SF_OVHELP_MOD_DIR)
    end
    if SoilOverlayHelpDialog.INSTANCE == nil then return end
    g_gui:showDialog("SoilOverlayHelpDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilOverlayHelpDialog:onGuiSetupFinished()
    SoilOverlayHelpDialog:superClass().onGuiSetupFinished(self)
    self._elCol1 = self:getDescendantById("sfOvHelp_col1")
    self._elCol2 = self:getDescendantById("sfOvHelp_col2")
end

function SoilOverlayHelpDialog:onOpen()
    SoilOverlayHelpDialog:superClass().onOpen(self)
    self:_buildContent()
end

function SoilOverlayHelpDialog:onClose()
    SoilOverlayHelpDialog:superClass().onClose(self)
    self:_clearContent()
end

-- ── Content Builder ───────────────────────────────────────

function SoilOverlayHelpDialog:_buildContent()
    local profileH = g_gui:getProfile("sfOvHelp_colHeader")
    local profileB = g_gui:getProfile("sfOvHelp_colBody")
    local profileS = g_gui:getProfile("sfOvHelp_colSpacer")

    if not profileH or not profileB then
        SoilLogger.warning("SoilOverlayHelpDialog: required column profiles not found")
        return
    end

    local currentBox = self._elCol1

    for _, row in ipairs(SoilOverlayHelpDialog.CONTENT) do
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

function SoilOverlayHelpDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls) do
        if entry.box then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
end

-- ── Button ────────────────────────────────────────────────

function SoilOverlayHelpDialog:onClickClose()
    g_gui:closeDialogByName("SoilOverlayHelpDialog")
end
