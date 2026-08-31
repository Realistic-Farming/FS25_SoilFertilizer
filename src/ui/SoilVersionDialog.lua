-- =========================================================
-- FS25 Soil & Fertilizer - Version / Changelog Dialog
-- =========================================================
-- Shown once per mod version on first savegame load.
-- Changelog lines are intentionally hardcoded here and will
-- NOT be translated (version notes are always in English).
--
-- Add as many lines as needed to CHANGELOG - the BoxLayout
-- in the XML stacks them automatically, no fixed slots.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilVersionDialog
SoilVersionDialog = SoilVersionDialog or {}
local SoilVersionDialog_mt = Class(SoilVersionDialog, ScreenElement)

local SF_VER_MOD_NAME = (SoilFertilizerModName or g_currentModName)
local SF_VER_MOD_DIR  = (SoilFertilizerModDirectory or g_currentModDirectory)

SoilVersionDialog.INSTANCE = nil

-- Hardcoded changelog for this release - update each version bump.
-- Max 11 lines are visible in the box; if more exist we stop on a bullet boundary and add a "full changelog on GitHub" note.
-- These are intentionally NOT translated, as they are always in English and often contain technical terms that don't translate well.
SoilVersionDialog.CHANGELOG = {
    "- Wet ground now bruises a standing crop. A loaded wheel crossing a wet",
    "    field leaves the crop standing but quietly worse at harvest, up to a",
    "    gentle 30% penalty, once per field per day (traffic on wet ground).",
    "    Compaction also reads real soil moisture when SeasonalCropStress is",
    "    installed, and now tracks every vehicle on the server, so co-op farms",
    "    and hired workers compact exactly like your own tractor.",
    "- Zone yield is now captured per cell while the crop grows, and the",
    "    harvest pays per header pass from that captured truth instead of one",
    "    field-average number. Part of Growth Modulation, so it needs",
    "    Experimental Systems turned on under Settings > Experimental.",
    "- The Soil Monitor no longer shows through the settings and tuning panels.",
    "    HUD text was rendering over the panel drawn on top of it, which made",
    "    both hard to read. The HUD now stands down while a panel is open.",
    "- READ THE DIRT can finally be read. Kneel down in a field and press the",
    "    handful key (Shift+G by default) to get everything the mod knows about",
    "    that exact spot: nutrients, pH, organic matter, compaction, moisture,",
    "    pressure, crop history and whatever cut material lies under your hand.",
    "    You have to actually be crouching, and readings are qualitative until",
    "    a soil test kit exists. Part of Read the Dirt, so it needs Experimental",
    "    Systems turned on under Settings > Experimental.",
    "- Turning Experimental Systems on or off now asks first. The gate arms",
    "    unfinished systems on a live save, so it warns you and waits for a",
    "    Confirm. Abort leaves the setting exactly as it was.",
    "- Release gate: disease resistance, hybrids, tank mixes, ground material,",
    "    spatial soil and Read the Dirt now ship LOCKED until you release them.",
    "    Turn them on under Settings > Experimental, at your own risk. A stable",
    "    playthrough never meets unfinished systems by default. Check status via",
    "    the version dialog's Release Gate button, or the SoilRelease command.",
    "- NEW SOIL ENGINE (thanks to WizardlyPayload): soil is now stored",
    "    per pixel across the map, not as one average per field. Spray half a",
    "    field and the map shows it. All 11 layers render at PF quality.",
    "- The Soil Layer Installer is NO LONGER REQUIRED. The maps are built at",
    "    startup on any map. Already patched? Nothing breaks, leave it as is.",
    "- Pest and disease can finally build up. They were capped below the level",
    "    where they cost you anything, so most players never saw them at all.",
    "- Unscouted ground no longer shows as clean green on the disease map. It",
    "    reads a neutral \"Unscouted\" state until you scout it, whatever is hiding.",
    "- Fungicide, herbicide and insecticide protection now scale with your season",
    "    length, so short 1-day months no longer give years of cover.",
    "- Six real fungicides you can buy and spray: Propiconazole, Azoxystrobin,",
    "    Boscalid, Mancozeb, Metalaxyl and Tebuconazole, each as an IBC tank.",
    "    Scout a field and it names the one that best controls its disease.",
    "- Harvesting contracts now reach 100%. When poor soil trimmed your yield",
    "    the contract's target used to move out of reach, so honest work never",
    "    finished. The target is now underwritten so the contract can complete.",
    "- Short months feel a living climate. On short calendars the game rarely",
    "    rains, so soil went stale; SoilFertilizer now tops up the rain a short",
    "    month skips, at your World Climate (Arid / Normal / Wet). Real sky only",
    "    opts out of the fill. Real weather stays in charge; normal-length saves",
    "    are unchanged.",
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
    self._statusLineEls    = {}
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
    self._elStatusBox       = self:getDescendantById("sfVer_statusBox")
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

    -- Build the live release-status panel
    self:_buildStatusLines()

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
    self:_clearStatusLines()
end

-- ── Dynamic changelog builder ─────────────────────────────

-- The changelog box (sfVer_changelogBox) is a fixed 490px-tall BoxLayout. A
-- BoxLayout stacks its children WITHOUT clipping, so more lines than fit render
-- past the box and over the footer/buttons (#666). At ~21px per line (12px text
-- + 4px spacing) about 24 lines fit; cap there. If CHANGELOG is longer we stop on
-- a bullet boundary (never mid-bullet) and add a "full changelog on GitHub" note.
-- Keep this in sync with the sfVer_changelogBox height in the XML.
SoilVersionDialog.MAX_VISIBLE_LINES = 24

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
            -- Indented continuation - strip leading spaces, re-indent.
            displayText = "    " .. lineText:match("^%s*(.+)$")
            profile = profileIndent or profileLine
        elseif lineText:match("^%- ") then
            displayText = "  >  " .. lineText:sub(3)
            profile = profileLine
        end

        -- [SF-66] Restores the BUILD 22:36 rewrite the tree overwrite dropped:
        -- the READ THE DIRT entry quotes "Shift+G by default" for SF_HANDFUL.
        if SoilLiveHint ~= nil and SoilLiveHint.rewrite ~= nil then
            displayText = SoilLiveHint.rewrite(displayText, { "SF_HANDFUL" })
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

-- ── Live release-status panel ─────────────────────────────

-- Fixed display order for the experimental systems (ReleaseGate.EXPERIMENTAL is
-- an unordered hash). Names come from ReleaseGate so they never drift.
SoilVersionDialog.STATUS_ORDER = {
    "cd9_resistance", "cd10_hybrids", "cd12_tank_mixes",
    "ground_material", "spatial_soil", "read_the_dirt", "growth_modulation",
}

function SoilVersionDialog:_buildStatusLines()
    if not self._elStatusBox then return end
    if not (ReleaseGate and ReleaseGate.EXPERIMENTAL) then return end

    local profile = g_gui:getProfile("sfVer_statusLine")
    if not profile then return end

    -- optIn == true -> every experimental system is ON (green); false/nil -> all
    -- LOCKED (amber). nil is pre-init, treated as stable/locked for display.
    local on    = (ReleaseGate.liveOptIn() == true)
    local badge = on and "[ON]  " or "[LOCKED]  "
    local col   = on and { 0.42, 0.82, 0.46, 1 } or { 0.93, 0.62, 0.28, 1 }

    local function addStatus(text, color)
        local el = TextElement.new()
        el:loadProfile(profile, true)
        el:setText(text)
        if color and el.setTextColor then
            el:setTextColor(color[1], color[2], color[3], color[4])
        end
        self._elStatusBox:addElement(el)
        el:onGuiSetupFinished()
        table.insert(self._statusLineEls, el)
    end

    addStatus(on and "Experimental Systems:  ON (at your own risk)"
                  or "Experimental Systems:  OFF (stable only)", col)

    for _, id in ipairs(SoilVersionDialog.STATUS_ORDER) do
        local entry = ReleaseGate.EXPERIMENTAL[id]
        if entry then addStatus(badge .. entry.name, col) end
    end

    self._elStatusBox:invalidateLayout()
end

function SoilVersionDialog:_clearStatusLines()
    for _, el in ipairs(self._statusLineEls or {}) do
        if self._elStatusBox then self._elStatusBox:removeElement(el) end
    end
    self._statusLineEls = {}
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

function SoilVersionDialog:onClickRelease()
    g_gui:closeDialogByName("SoilVersionDialog")
    if SoilReleaseDialog then
        SoilReleaseDialog.show()
    end
end

function SoilVersionDialog:onClickDontShowAgain()
    if g_SoilFertilityManager and self._version then
        g_SoilFertilityManager.lastSeenVersion = self._version
        g_SoilFertilityManager:saveSoilData()
    end
    g_gui:closeDialogByName("SoilVersionDialog")
end
