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
    "- Changed: Soil compaction is now based on ground pressure, not vehicle weight. A heavy",
    "  machine on wide or flotation tyres spreads its load and barely compacts, while the",
    "  same weight on narrow tyres packs the soil hard, just like real life. Very heavy",
    "  machines still cause some deep compaction on any tyre because of axle load. The old",
    "  fixed weight limit is gone",
    "- New: Variable Tire Pressure support. If you run the Variable Tire Pressure mod, airing",
    "  your tyres down to field mode genuinely reduces how much you compact the soil, and",
    "  pumping back up to road mode increases it. Nothing to set up, it just works when the",
    "  mod is installed",
    "- New: Wet soil compacts more. Driving heavy equipment over a field while it rains, or",
    "  in the hours after, packs the soil harder than working it when dry. Let a field dry",
    "  out before bringing the heavy kit on",
    "- Fixed: Parking pads, gravel and other painted ground on a field no longer build up",
    "  compaction. It is now only applied where there is real field ground, so a parking",
    "  area inside a field stops dragging the whole field's compaction up",
    "- Fixed: Equipment just sitting on a field no longer raises compaction. It only builds",
    "  up along ground you actually drive over, never from a parked or idling machine",
    "- New: Plowing, cultivating or mulching a standing or dead crop now gives a real",
    "  organic matter boost. Working in a cover crop, a failed or burned crop, or tall",
    "  stubble returns its biomass to the soil, so tilling a crop in is finally worth it",
    "  instead of just leaving it. The bigger the crop, the bigger the boost (#674)",
    "- Changed: Tillage now RELIEVES compaction instead of adding it. Plowing and",
    "  subsoiling break up compacted soil, cultivating is neutral, and only harvesting",
    "  with a heavy combine packs it down. This matches real farming and fixes the case",
    "  where a subsoiler-configured tool made one field's compaction keep climbing",
    "  instead of dropping back to zero",
    "- New: Added a 'Compaction Buildup' slider in the tuning editor so you can set how",
    "  fast compaction builds up, separately from how fast it recovers. Turn it down, or",
    "  all the way to zero, if heavy machinery is packing your fields too quickly",
    "- Fixed: Auto-rate no longer starves manure and other organic fertilizers on a field",
    "  that is already rich in organic matter. The rate now follows whichever need is",
    "  bigger, organic matter or N/P/K, so a nutrient-heavy organic like chicken or",
    "  pelletized manure still goes down when the field is short on nutrients (#668)",
    "- Fixed: Some towed manure spreaders applied product in-game but SF recorded no",
    "  nutrient or organic-matter change. SF now reads the tractor's speed for towed",
    "  spreaders so the pass is counted, with extra logging to catch any remaining",
    "  spreaders that slip through (#668)",
    "- Fixed: A field's expected yield no longer drops a few percent every time you save",
    "  and reload mid-harvest. The daily soil pass was re-running on every reload (which",
    "  also added a stray day of nutrient drift); it now only runs when a real day passes (#665)",
    "- Fixed: The 'What's new' dialog's 'Don't show again' now sticks. The version check",
    "  ran before the saved value was loaded, so the dialog reappeared every load (#665)",
    "- Fixed: Setting a field's values from the admin menu now updates the in-game map",
    "  overlay right away instead of only the HUD; the map kept showing the old values",
    "  until the next fertiliser pass (#661)",
    "- Fixed: While drilling a new crop, the field readout no longer keeps showing the",
    "  previous crop until you reach the middle of the field; it shows the crop you are",
    "  seeding as soon as the pass starts (#661)",
    "- Fixed: Texture array warnings from the fill-plane normal and displacement maps. The",
    "  mip levels did not line up with the shared pile texture array, which spams the log",
    "  and can disturb fill-plane rendering. Corrected dds files contributed by Sabo-7 (#657)",
    "- Fixed: Soil compaction no longer resets to 0% after you save and reload. The",
    "  per-cell compaction was being saved, but on load the field average was rebuilt",
    "  from the wrong table, so it always came back as zero (#656)",
    "- Fixed: A field's expected yield no longer jumps around after a save and reload",
    "  during a harvest. The frozen yield value (including any lime or organic burn) now",
    "  carries across the reload, so the figure stays put and a save/reload can no longer",
    "  wipe an active burn penalty (#656)",
    "- Fixed: Dry and broadcast spreaders (lime, granular fertilizer) now move the",
    "  Pass% and hectares counters again. Spreading painted the field but the counters",
    "  stayed at 0 while liquid sprayers worked. Spreaders now track coverage the",
    "  reliable way regardless of field layout (#650)",
    "- Fixed: Briefly over-applying fertilizer no longer wrecks the whole field. The",
    "  over-application burn used to fire every moment the boom was down and once per",
    "  boom section, so a few seconds of over-spraying stacked hundreds of penalties",
    "  and crashed the field's pH and nitrogen. The burn is now scaled to how long you",
    "  over-apply, so a brief overlap costs only a small penalty and a wide boom no",
    "  longer multiplies it",
    "- Fixed: Fertilizing a field could do nothing after reloading a save. The field was",
    "  wrongly treated as already fully covered, which switched the spreader sections off",
    "  so nothing was applied and the soil never changed. Reloading now starts a fresh",
    "  spraying session, so previously fertilized fields accept fertilizer again (#640)",
    "- Fixed: Spreading slurry, manure or digestate on freshly cut grass no longer",
    "  triggers the organic-matter burn penalty (#645)",
    "- Fixed: Removed duplicate translation entries that were spamming warnings in the",
    "  log on startup (#642)",
    "- New: Lime can now be applied to young or freshly cut grass and pasture without",
    "  the yield burn penalty, matching real pasture management. Tall forage and annual",
    "  crops still take the penalty (#646)",
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
