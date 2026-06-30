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
    { t="B", v="Each cell is colour-coded for the active layer:" },
    { t="B", v="  Red    \226\128\148 Poor  (below minimum)" },
    { t="B", v="  Yellow \226\128\148 Fair  (below optimal)" },
    { t="B", v="  Green  \226\128\148 Good  (at or above optimal)" },
    { t="B", v="Dim cells = unsampled. Walk onto the field" },
    { t="B", v="to collect a soil reading for that area." },
    { t="S", v=" " },
    { t="H", v="MAP LAYERS" },
    { t="B", v="Layer 1 \226\128\148 Nitrogen (N)" },
    { t="B", v="   Most volatile. Depletes on every harvest." },
    { t="B", v="Layer 2 \226\128\148 Phosphorus (P)" },
    { t="B", v="   Slow-moving. Long-lasting from MAP / DAP." },
    { t="B", v="Layer 3 \226\128\148 Potassium (K)" },
    { t="B", v="   Apply Potash. Critical for root crops." },
    { t="B", v="Layer 4 \226\128\148 pH" },
    { t="B", v="   6.5 - 7.0 ideal. Green = in optimal range." },
    { t="B", v="Layer 5 \226\128\148 Organic Matter" },
    { t="B", v="   Higher = better structure and water retention." },
    -- ── COLUMN BREAK ─────────────────────────────────────
    { t="COL", v="" },
    -- ── RIGHT COLUMN ─────────────────────────────────────
    { t="H", v="CELL TOOLTIP (HOVER A CELL)" },
    { t="B", v="Shows the exact nutrient value (ppm)," },
    { t="B", v="its Good / Fair / Poor status, and -" },
    { t="B", v="when a crop is planted - the crop's target" },
    { t="B", v="and the gap above or below it." },
    { t="S", v=" " },
    { t="H", v="COLOUR LEGEND (SIDEBAR)" },
    { t="B", v="The gradient bar shows what colour = what" },
    { t="B", v="status for the active layer." },
    { t="B", v="All layers: Red (poor) \226\128\148 Yellow \226\128\148 Green (good)." },
    { t="S", v=" " },
    { t="H", v="SIDEBAR BUTTONS" },
    { t="B", v="Farm Overview  \226\128\148 PDA soil report." },
    { t="B", v="Treatment Plan \226\128\148 Fields by urgency." },
    { t="B", v="Disable Overlay \226\128\148 Turn off the overlay." },
    { t="B", v="Help           \226\128\148 You are reading it." },
    { t="S", v=" " },
    { t="H", v="TIPS" },
    { t="B", v="* Click a cell to inspect it in detail." },
    { t="B", v="* Number on field tile = field average." },
    { t="B", v="* Zoom in to see per-cell variability." },
    { t="B", v="* Layer buttons at top of sidebar switch" },
    { t="B", v="  between N / P / K / pH / OM views." },
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
