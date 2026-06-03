-- =========================================================
-- FS25 Soil & Fertilizer — Version / Changelog Dialog
-- =========================================================
-- Shown once per mod version on first savegame load.
-- Changelog lines are intentionally hardcoded here and will
-- NOT be translated (version notes are always in English).
--
-- Add as many lines as needed to CHANGELOG — the BoxLayout
-- in the XML stacks them automatically, no fixed slots.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilVersionDialog
SoilVersionDialog = {}
local SoilVersionDialog_mt = Class(SoilVersionDialog, ScreenElement)

local SF_VER_MOD_NAME = g_currentModName
local SF_VER_MOD_DIR  = g_currentModDirectory

SoilVersionDialog.INSTANCE = nil

-- Hardcoded changelog for this release — update each version bump.
-- Any number of lines.
-- These are intentionally NOT translated, as they are always in English and often contain technical terms that don't translate well.
SoilVersionDialog.CHANGELOG = {
    "v2.3.6.0",
    "- New: harvester panel stats bar — 4 cells showing estimated t/ha,",
    "  field coverage %, session area harvested, and total field area",
    "- Fixed: weed pressure no longer spikes on reload or time-skip;",
    "  increases are now capped at 20 pts/day so pressure rises gradually",
    "- Fixed: SF application rate multiplier now shown in sprayer panel",
    "  title bar so you always know the active rate at a glance",
    "- Fixed: colorblind mode now auto-enables when the game's own",
    "  colorblind setting is turned on",
    "v2.3.5.0",
    "- Fixed: minimap heatmap spray trail — daily updates no longer wipe",
    "  per-pixel nutrient data, so sprayed areas now visually differ from",
    "  unsprayed areas on the soil layer overlay",
}

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_VER_MOD_NAME]
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

function SoilVersionDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilVersionDialog_mt)
    self._changelogLineEls = {}
    return self
end

function SoilVersionDialog.register(modDirectory)
    if SoilVersionDialog.INSTANCE ~= nil then return end

    SF_VER_MOD_DIR = modDirectory
    local xmlPath = modDirectory .. "xml/gui/SoilVersionDialog.xml"

    SoilVersionDialog.INSTANCE = SoilVersionDialog.new()
    SoilLogger.info("SoilVersionDialog: registering from %s", xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(xmlPath, "SoilVersionDialog", SoilVersionDialog.INSTANCE)
    end)

    if not ok then
        SoilLogger.error("SoilVersionDialog: loadGui failed: %s", tostring(err))
        SoilVersionDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilVersionDialog: registered successfully")
    end
end

---@param version string  e.g. "2.1.5.6"
function SoilVersionDialog.show(version)
    if SoilVersionDialog.INSTANCE == nil then
        SoilVersionDialog.register(SF_VER_MOD_DIR)
    end

    local inst = SoilVersionDialog.INSTANCE
    if inst == nil then return end

    inst._version = version

    g_gui:showDialog("SoilVersionDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilVersionDialog:onGuiSetupFinished()
    SoilVersionDialog:superClass().onGuiSetupFinished(self)

    self._elTitle           = self:getDescendantById("sfVer_title")
    self._elChangelogHeader = self:getDescendantById("sfVer_changelogHeader")
    self._elChangelogBox    = self:getDescendantById("sfVer_changelogBox")
    self._elFooter1         = self:getDescendantById("sfVer_footer1")
    self._elFooter2         = self:getDescendantById("sfVer_footer2")
    self._elFooter3         = self:getDescendantById("sfVer_footer3")
    self._elFooter4         = self:getDescendantById("sfVer_footer4")
end

function SoilVersionDialog:onOpen()
    SoilVersionDialog:superClass().onOpen(self)

    -- Title
    if self._elTitle then
        self._elTitle:setText("FS25_SoilFertilizer  |  v" .. (self._version or "?"))
    end

    -- "What's new" header
    if self._elChangelogHeader then
        self._elChangelogHeader:setText(tr("sf_startup_dialog_version", "What's new in this version:"))
    end

    -- Build changelog lines dynamically
    self:_buildChangelogLines()

    -- Footer
    if self._elFooter1 then
        self._elFooter1:setText(tr("sf_startup_dialog_footer",  "Thank you for using my mod, it means a lot to me <3"))
    end
    if self._elFooter2 then
        self._elFooter2:setText(tr("sf_startup_dialog_footer2", "Found a bug? Please report it on github!"))
    end
    if self._elFooter3 then
        self._elFooter3:setText(tr("sf_startup_dialog_footer3", "Happy farming and don't forget:"))
    end
    if self._elFooter4 then
        self._elFooter4:setText(tr("sf_startup_dialog_footer4", "Your soil remembers everything..."))
    end
end

function SoilVersionDialog:onClose()
    SoilVersionDialog:superClass().onClose(self)
    self._version = nil
    -- Remove dynamically created lines so they don't stack on re-open
    self:_clearChangelogLines()
end

-- ── Dynamic changelog builder ─────────────────────────────

function SoilVersionDialog:_buildChangelogLines()
    if not self._elChangelogBox then return end

    local profileLine    = g_gui:getProfile("sfVer_changelogLine")
    local profileVersion = g_gui:getProfile("sfVer_changelogVersion")
    local profileIndent  = g_gui:getProfile("sfVer_changelogIndent")
    if not profileLine then
        SoilLogger.warning("SoilVersionDialog: profile 'sfVer_changelogLine' not found")
        return
    end

    for _, lineText in ipairs(SoilVersionDialog.CHANGELOG) do
        -- Detect line type: version header, bullet, or indented continuation
        local profile
        local displayText = lineText
        if lineText:match("^v%d") then
            profile = profileVersion or profileLine
        elseif lineText:match("^%s%s") then
            -- Indented continuation — strip leading spaces, add em-dash indent
            displayText = "    " .. lineText:match("^%s*(.+)$")
            profile = profileIndent or profileLine
        elseif lineText:match("^%- ") then
            displayText = "  >  " .. lineText:sub(3)
            profile = profileLine
        else
            profile = profileLine
        end

        local el = TextElement.new()
        el:loadProfile(profile, true)
        el:setText(displayText)
        self._elChangelogBox:addElement(el)
        el:onGuiSetupFinished()
        table.insert(self._changelogLineEls, el)
    end

    self._elChangelogBox:invalidateLayout()
end

function SoilVersionDialog:_clearChangelogLines()
    for _, el in ipairs(self._changelogLineEls) do
        if self._elChangelogBox then
            self._elChangelogBox:removeElement(el)
        end
    end
    self._changelogLineEls = {}
end

-- ── Button ────────────────────────────────────────────────

function SoilVersionDialog:onClickOk()
    g_gui:closeDialogByName("SoilVersionDialog")
end

function SoilVersionDialog:onClickGuide()
    g_gui:closeDialogByName("SoilVersionDialog")
    if SoilGuideDialog then
        SoilGuideDialog.show()
    end
end

function SoilVersionDialog:onClickDontShowAgain()
    if g_SoilFertilityManager and self._version then
        g_SoilFertilityManager.lastSeenVersion = self._version
        g_SoilFertilityManager:saveSoilData()
    end
    g_gui:closeDialogByName("SoilVersionDialog")
end
