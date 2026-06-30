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
-- Max 11 lines are visible in the box; if more exist we stop on a bullet boundary and add a "full changelog on GitHub" note.
-- These are intentionally NOT translated, as they are always in English and often contain technical terms that don't translate well.
SoilVersionDialog.CHANGELOG = {
    "- Fields now catch named, crop-specific fungal diseases",
    "- Scout a field (Shift+K) to identify the disease and the best fungicide to use",
    "- 23 real fungicides, each with per-disease effectiveness, timing & weather rules",
    "- Match the right chemical to the disease, the wrong one only half works",
    "- Crop rotation and soil health now raise or lower disease pressure",
    "- New Disease Difficulty setting: Easy / Normal / Hard",
    "- Console: SoilScout, SoilTreat, SoilFungicides, SoilSetDiseaseDifficulty",
    "- Field compaction can no longer read above 100%, the average is now capped",
    "- Precision Farming is now detected only when it is actually enabled for your save, not just installed in the mods folder",
    "- Soil Monitor and applied nutrients now follow the product physically in the tank, even when AI or Courseplay is driving",
    "- Field Info box refactored (removed redundant info and added new info lines)"
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

-- The changelog box (sfVer_changelogBox) is a fixed 260px-tall BoxLayout. A
-- BoxLayout stacks its children WITHOUT clipping, so more lines than fit render
-- past the box and over the footer/buttons (#666). At ~23px per line (18px text +
-- 5px spacing) about 11 lines fit; cap there. If CHANGELOG is longer we stop on a
-- bullet boundary (never mid-bullet) and add a "full changelog on GitHub" note.
-- Keep this in sync with the sfVer_changelogBox height in the XML.
SoilVersionDialog.MAX_VISIBLE_LINES = 11

function SoilVersionDialog:_buildChangelogLines()
    if not self._elChangelogBox then return end

    local profileLine    = g_gui:getProfile("sfVer_changelogLine")
    local profileVersion = g_gui:getProfile("sfVer_changelogVersion")
    local profileIndent  = g_gui:getProfile("sfVer_changelogIndent")
    if not profileLine then
        SoilLogger.warning("SoilVersionDialog: profile 'sfVer_changelogLine' not found")
        return
    end

    -- Render one CHANGELOG entry as a styled TextElement (version / bullet / indent).
    local function addLine(lineText)
        local profile = profileLine
        local displayText = lineText
        if lineText:match("^v%d") then
            profile = profileVersion or profileLine
        elseif lineText:match("^%s%s") then
            -- Indented continuation — strip leading spaces, re-indent.
            displayText = "    " .. lineText:match("^%s*(.+)$")
            profile = profileIndent or profileLine
        elseif lineText:match("^%- ") then
            displayText = "  >  " .. lineText:sub(3)
            profile = profileLine
        end

        local el = TextElement.new()
        el:loadProfile(profile, true)
        el:setText(displayText)
        self._elChangelogBox:addElement(el)
        el:onGuiSetupFinished()
        table.insert(self._changelogLineEls, el)
    end

    -- Group lines into bullets (a "- "/version line plus its indented continuations)
    -- so truncation never cuts a bullet in half.
    local lines  = SoilVersionDialog.CHANGELOG
    local groups = {}
    local i = 1
    while i <= #lines do
        local group = { lines[i] }
        local j = i + 1
        while j <= #lines and lines[j]:match("^%s%s") do
            group[#group + 1] = lines[j]
            j = j + 1
        end
        groups[#groups + 1] = group
        i = j
    end

    local maxLines = SoilVersionDialog.MAX_VISIBLE_LINES
    local rendered = 0
    for idx, group in ipairs(groups) do
        -- Reserve one line for the "...and more" note while groups still remain.
        local budget = maxLines - ((idx < #groups) and 1 or 0)
        if rendered + #group > budget then
            addLine("- ...and more. Full changelog on GitHub.")
            break
        end
        for _, gl in ipairs(group) do
            addLine(gl)
            rendered = rendered + 1
        end
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
