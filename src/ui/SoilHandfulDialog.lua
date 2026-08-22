-- =========================================================
-- FS25 Soil & Fertilizer - THE HANDFUL PANEL (SF-39)
-- =========================================================
-- The reading surface for the kneel. Renders the FROZEN SF-38 payload
-- (HandfulRead.assemble) verbatim and writes nothing at all: no getter of its
-- own, no re-scout, no touch on the walked mask. The kneel already did the one
-- write in this member.
--
-- Opened by the SF_HANDFUL hotkey, and ONLY while the player is crouched -
-- the precondition ladder lives in SoilFertilityManager:onHandfulInput.
--
-- LAYOUT: stat tiles for the banded clauses, text rows for the wordy ones.
-- Every band resolves to a SEVERITY as well as a word, and the severity picks
-- the value colour, so the panel reads at a glance without reading at all.
-- Colour is a SECOND channel on top of the word, never a replacement for it:
-- the word always says the thing, so a colour-blind player loses nothing.
--
-- RENDERING RULES (inherited cert gates from the SF-38 contract, not new):
--   GRAIN HONESTY      - every section carries its grain tag; a FIELD clause is
--                        never drawn as if it were measured at the spot.
--   PER-CLAUSE NEUTRAL - one absent system blanks its own clause only. A nil
--                        clause renders a dash in NEUTRAL grey, never a zero,
--                        and never borrows a severity colour it did not earn.
--   NO PHANTOM FIELDS  - we render HandfulRead.CLAUSES and nothing else.
--   BANDS, NOT NUMBERS - exact figures sit behind the test kit, and
--                        HandfulRead readTestKit() is a hardcoded false until
--                        the kit member ships. So gated clauses render as bands
--                        ALWAYS in v1. That is the contract working, not a bug.
--   NO NEW THRESHOLDS  - every band below reuses a shipped constant or a shipped
--                        display rule; this file invents none.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilHandfulDialog
SoilHandfulDialog = SoilHandfulDialog or {}
local SoilHandfulDialog_mt = Class(SoilHandfulDialog, ScreenElement)

local SF_HANDFUL_MOD_NAME = (SoilFertilizerModName or g_currentModName)
local SF_HANDFUL_MOD_DIR  = (SoilFertilizerModDirectory or g_currentModDirectory)

SoilHandfulDialog.INSTANCE = nil
SoilHandfulDialog.xmlPath  = nil

local DASH = "--"

-- Severity -> colour. The absent case gets its own grey so a missing reading is
-- visibly not a judgement: "we did not measure this" must never look like "good".
local SEV = {
    good    = { 0.42, 0.82, 0.35, 1 },
    fair    = { 0.95, 0.78, 0.30, 1 },
    poor    = { 0.90, 0.38, 0.30, 1 },
    info    = { 0.55, 0.80, 0.95, 1 },
    neutral = { 0.55, 0.55, 0.55, 1 },
}

-- ── i18n helper (same shape as the sibling dialogs) ───────
-- Carries an English fallback for every key. A key that resolves nowhere still
-- renders readable text instead of the engine's "Missing '...'" string.
local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_HANDFUL_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            local lower = text:lower()
            if not lower:find("^missing%s") and not lower:find("^missing_") then
                return text
            end
        end
    end
    return fallback or key
end

-- ── Bands: every cut point below is a SHIPPED value ───────
-- Each returns (displayWord, severity). Severity drives colour only.

-- N/P/K arrive from the core already banded: getFieldInfo returns
-- { value, status } with status in Poor/Fair/Good/Unknown. We localise the word
-- and never re-derive it.
local function bandNutrient(clause)
    if type(clause) ~= "table" or type(clause.status) ~= "string" then return nil end
    local s = clause.status:lower()
    local sev = (s == "good" and "good") or (s == "fair" and "fair")
        or (s == "poor" and "poor") or "neutral"
    return tr("sf_handful_band_" .. s, clause.status), sev
end

-- pH: SoilConstants.REPORT_COLORS, the same cut points the report display uses.
-- Acidic and alkaline are both "off optimal", not "bad", so both read fair.
local function bandPh(ph)
    if type(ph) ~= "number" then return nil end
    local rc = SoilConstants and SoilConstants.REPORT_COLORS
    if rc == nil then return nil end
    if ph >= (rc.PH_GOOD_LOW or 6.0) and ph <= (rc.PH_GOOD_HIGH or 7.0) then
        return tr("sf_handful_band_good", "Good"), "good"
    elseif ph < (rc.PH_FAIR_LOW or 5.5) then
        return tr("sf_handful_band_acidic", "Acidic"), "poor"
    elseif ph > (rc.PH_FAIR_HIGH or 7.5) then
        return tr("sf_handful_band_alkaline", "Alkaline"), "poor"
    end
    return tr("sf_handful_band_fair", "Fair"), "fair"
end

-- Organic matter: SoilConstants.REPORT_COLORS OM_GOOD / OM_FAIR.
local function bandOm(om)
    if type(om) ~= "number" then return nil end
    local rc = SoilConstants and SoilConstants.REPORT_COLORS
    if rc == nil then return nil end
    if om >= (rc.OM_GOOD or 4.0) then return tr("sf_handful_band_good", "Good"), "good" end
    if om >= (rc.OM_FAIR or 2.5) then return tr("sf_handful_band_fair", "Fair"), "fair" end
    return tr("sf_handful_band_poor", "Poor"), "poor"
end

-- Compaction: the cut points the shipped map layer already displays against
-- (SoilMapOverlay layer 10: <25 no action, <60 subsoiling recommended, else
-- urgent). Reused rather than re-invented so the two surfaces never disagree.
-- NOTE the polarity: LOW compaction is the GOOD outcome.
local function bandCompaction(c)
    if type(c) ~= "number" then return nil end
    if c < 25 then return tr("sf_handful_band_low", "Low"), "good" end
    if c < 60 then return tr("sf_handful_band_moderate", "Moderate"), "fair" end
    return tr("sf_handful_band_high", "High"), "poor"
end

-- Pressure tiers: SoilConstants.DISEASE_PRESSURE LOW/MEDIUM/HIGH, the same
-- ladder scoutField uses for its tier word.
local function bandPressure(v)
    if type(v) ~= "number" then return nil end
    local dp = SoilConstants and SoilConstants.DISEASE_PRESSURE
    if dp == nil then return nil end
    if v < (dp.LOW or 20) then return tr("sf_scout_tier_none", "None"), "good" end
    if v < (dp.MEDIUM or 50) then return tr("sf_scout_tier_mild", "Mild"), "fair" end
    if v < (dp.HIGH or 75) then return tr("sf_scout_tier_moderate", "Moderate"), "poor" end
    return tr("sf_scout_tier_severe", "Severe"), "poor"
end

-- Material bands arrive from the layers as lowercase ids ("damp", "curing").
-- The l10n key carries the display word; the FALLBACK has to capitalise, or a
-- missing key degrades to a lowercase word sitting next to capitalised ones.
local MATERIAL_SEV = { fit = "good", curing = "fair", damp = "fair", soaked = "poor" }
local function bandMaterial(band)
    if type(band) ~= "string" or band == "" then return nil end
    local lower = band:lower()
    return tr("sf_handful_band_" .. lower, lower:sub(1, 1):upper() .. lower:sub(2)),
        MATERIAL_SEV[lower] or "info"
end

local function cropName(id)
    if type(id) ~= "string" or id == "" then return nil end
    local key = "sf_crop_" .. id:lower()
    if g_i18n and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return (id:gsub("_", " "))
end

-- ── Constructor / registration ────────────────────────────

function SoilHandfulDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilHandfulDialog_mt)
    self._payload = nil
    return self
end

function SoilHandfulDialog.register(modDirectory)
    if SoilHandfulDialog.INSTANCE ~= nil then return end

    SF_HANDFUL_MOD_DIR = modDirectory
    SoilHandfulDialog.xmlPath = modDirectory .. "xml/gui/SoilHandfulDialog.xml"
    SoilHandfulDialog.INSTANCE = SoilHandfulDialog.new()
    SoilLogger.info("SoilHandfulDialog: registering from %s", SoilHandfulDialog.xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(SoilHandfulDialog.xmlPath, "SoilHandfulDialog", SoilHandfulDialog.INSTANCE)
    end)
    if not ok then
        SoilLogger.error("SoilHandfulDialog: loadGui failed: %s", tostring(err))
        SoilHandfulDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilHandfulDialog: registered successfully")
    end
end

--- Open the panel on an assembled payload. The caller (the kneel) owns the
--- precondition ladder; by the time we are called the read has happened.
---@param payload table|nil  HandfulRead.assemble result
function SoilHandfulDialog.show(payload)
    if SoilHandfulDialog.INSTANCE == nil then
        SoilHandfulDialog.register(SF_HANDFUL_MOD_DIR)
    end
    local inst = SoilHandfulDialog.INSTANCE
    if inst == nil then return end
    inst._payload = payload
    g_gui:showDialog("SoilHandfulDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

-- Every id the controller touches. Kept as a list so onGuiSetupFinished cannot
-- drift out of step with the XML one rename at a time.
local ELEMENT_IDS = {
    "hfField", "hfGrain",
    "hfLblN", "hfValN", "hfLblP", "hfValP", "hfLblK", "hfValK",
    "hfLblPh", "hfValPh", "hfLblOm", "hfValOm",
    "hfLblComp", "hfValComp", "hfLblMoist", "hfValMoist",
    "hfLblDis", "hfValDis", "hfLblPest", "hfValPest", "hfLblWeed", "hfValWeed",
    "hfDisGrain",
    "hfCrops", "hfRotation", "hfOrganic",
    "hfSecMaterial", "hfLblWet", "hfValWet", "hfLblDown", "hfValDown",
    "hfLblVerdict", "hfValVerdict",
    "hfFooter",
}

function SoilHandfulDialog:onGuiSetupFinished()
    SoilHandfulDialog:superClass().onGuiSetupFinished(self)
    for _, id in ipairs(ELEMENT_IDS) do
        self[id] = self:getDescendantById(id)
    end
end

function SoilHandfulDialog:onOpen()
    SoilHandfulDialog:superClass().onOpen(self)
    self:_populate()
end

function SoilHandfulDialog:onClose()
    SoilHandfulDialog:superClass().onClose(self)
    self._payload = nil
end

function SoilHandfulDialog:onClickClose()
    g_gui:closeDialogByName("SoilHandfulDialog")
end

-- ── Rendering ─────────────────────────────────────────────

local function setText(el, text) if el then el:setText(text or "") end end
local function setVisible(el, v) if el and el.setVisible then el:setVisible(v) end end

local function setColor(el, sev)
    if el == nil or el.setTextColor == nil then return end
    local c = SEV[sev or "neutral"] or SEV.neutral
    el:setTextColor(c[1], c[2], c[3], c[4])
end

--- One stat tile: a dim label over a coloured value. An absent value is the
--- neutral dash in neutral grey - it must never inherit a severity colour, or a
--- clause nobody measured would read as a verdict somebody made.
local function tile(lblEl, valEl, labelText, valueText, sev)
    setText(lblEl, labelText)
    if valueText == nil then
        setText(valEl, DASH)
        setColor(valEl, "neutral")
    else
        setText(valEl, valueText)
        setColor(valEl, sev)
    end
end

--- "Label: value" for the wordy rows, with the same neutral-dash contract.
local function row(label, value)
    return string.format("%s: %s", label, value or DASH)
end

function SoilHandfulDialog:_populate()
    local p = self._payload
    if p == nil then
        setText(self.hfField, tr("sf_handful_no_read", "Nothing read"))
        setText(self.hfGrain, "")
        return
    end

    -- Header: which field, and whether the nutrient row was refined to the spot.
    -- ONE shared refinement flag for N/P/K/pH/OM, labelled once, per the contract.
    setText(self.hfField, string.format("%s%s",
        tr("sf_detail_field_label", "Field #"), tostring(p.fieldId or "?")))
    setText(self.hfGrain, p.fromZoneCell
        and tr("sf_handful_grain_spot", "spot")
        or tr("sf_handful_grain_field", "field average"))

    -- Nutrients (SPOT). Bands only: testKitActive is false until the kit ships.
    tile(self.hfLblN,  self.hfValN,  tr("sf_handful_n", "N"),   bandNutrient(p.N))
    tile(self.hfLblP,  self.hfValP,  tr("sf_handful_p", "P"),   bandNutrient(p.P))
    tile(self.hfLblK,  self.hfValK,  tr("sf_handful_k", "K"),   bandNutrient(p.K))
    tile(self.hfLblPh, self.hfValPh, tr("sf_handful_ph", "pH"), bandPh(p.pH))
    tile(self.hfLblOm, self.hfValOm, tr("sf_handful_om", "Organic matter"), bandOm(p.OM))

    -- Ground: compaction is SPOT, moisture is FIELD and UNGATED, so moisture
    -- shows its real figure rather than a band it was never gated behind.
    tile(self.hfLblComp, self.hfValComp,
        tr("sf_handful_compaction", "Compaction"), bandCompaction(p.compaction))
    local moisture = type(p.moisture) == "number"
        and string.format("%d%%", math.floor(p.moisture * 100 + 0.5)) or nil
    tile(self.hfLblMoist, self.hfValMoist,
        tr("sf_handful_moisture", "Moisture"), moisture, "info")

    -- Disease: knowledge-gated. shownDiseasePressure is nil while unscouted and
    -- that is the honest answer, not a hole. Unscouted takes the NEUTRAL colour,
    -- never the green of None: an unlooked-at field has not earned a clean bill.
    if p.diseasePressure == nil then
        tile(self.hfLblDis, self.hfValDis, tr("sf_handful_disease", "Disease"),
            tr("sf_handful_unscouted", "Unscouted"), "neutral")
    else
        tile(self.hfLblDis, self.hfValDis, tr("sf_handful_disease", "Disease"),
            bandPressure(p.diseasePressure))
    end
    -- The grain label rides its own line so the tile stays a tile.
    setText(self.hfDisGrain, (p.diseaseGrain == "cell")
        and tr("sf_handful_grain_cell", "this cell")
        or tr("sf_handful_grain_field", "field average"))

    -- Pests and weeds: FIELD grain, UNGATED at source, so no knowledge gate here.
    tile(self.hfLblPest, self.hfValPest, tr("sf_handful_pest", "Pests"), bandPressure(p.pestPressure))
    tile(self.hfLblWeed, self.hfValWeed, tr("sf_handful_weed", "Weeds"), bandPressure(p.weedPressure))

    -- History (FIELD).
    local crops = {}
    for _, id in ipairs({ p.lastCrop, p.lastCrop2, p.lastCrop3 }) do
        local n = cropName(id)
        if n then crops[#crops + 1] = n end
    end
    setText(self.hfCrops, row(tr("sf_handful_last_crops", "Last crops"),
        #crops > 0 and table.concat(crops, "  >  ") or nil))

    local rot = p.rotationStatus
        and tr("sf_handful_rot_" .. tostring(p.rotationStatus):lower(), tostring(p.rotationStatus))
        or nil
    local rotLine = row(tr("sf_handful_rotation", "Rotation"), rot)
    if (p.rotationBonusDaysLeft or 0) > 0 then
        rotLine = rotLine .. string.format("  (%s)", string.format(
            tr("sf_handful_bonus_days", "%d bonus days left"), p.rotationBonusDaysLeft))
    end
    rotLine = rotLine .. string.format("    %s", row(
        tr("sf_handful_since_harvest", "Days since harvest"),
        (p.daysSinceHarvest or 0) > 0 and tostring(p.daysSinceHarvest) or nil))
    setText(self.hfRotation, rotLine)

    local org = p.organicState
    local orgTxt
    if type(org) == "table" then
        if org.certified then
            orgTxt = tr("sf_handful_org_certified", "Certified organic")
        elseif (org.transitionDaysNeeded or 0) > 0 and (org.daysAccrued or 0) > 0 then
            orgTxt = string.format("%s %d/%d",
                tr("sf_handful_org_transition", "In transition"),
                org.daysAccrued or 0, org.transitionDaysNeeded or 0)
        else
            orgTxt = tr("sf_handful_org_conventional", "Conventional")
        end
        if (org.breaches or 0) > 0 then
            orgTxt = orgTxt .. string.format("  (%s)", string.format(
                tr("sf_handful_org_breaches", "%d breaches"), org.breaches))
        end
    end
    setText(self.hfOrganic, row(tr("sf_handful_organic", "Organic"), orgTxt))

    -- Under the hand (SPOT). The whole section hides when nothing lies there:
    -- an "unavailable" or "refusal" status is not a value to render. Hiding the
    -- container hides its children too (GuiElement:getIsVisible walks parents).
    local wet, down, verdict = p.materialWetness, p.materialDaysDown, p.materialVerdict
    local hasMaterial = type(wet) == "table" and wet.band ~= nil
    setVisible(self.hfSecMaterial, hasMaterial)
    if hasMaterial then
        tile(self.hfLblWet, self.hfValWet, tr("sf_handful_mat_wetness", "Wetness"), bandMaterial(wet.band))
        tile(self.hfLblDown, self.hfValDown, tr("sf_handful_mat_days", "Days down"),
            (type(down) == "table" and down.days) and tostring(down.days) or nil, "info")
        local vTxt, vSev
        if type(verdict) == "table" and verdict.status == "ok" then
            if verdict.spoiled then
                vTxt, vSev = tr("sf_handful_mat_spoiled", "Spoiled"), "poor"
            else
                vTxt, vSev = tr("sf_handful_mat_sound", "Sound"), "good"
            end
        end
        tile(self.hfLblVerdict, self.hfValVerdict, tr("sf_handful_mat_verdict", "Verdict"), vTxt, vSev)
    end

    -- Footer: the kit state that explains why the readings above are words.
    setText(self.hfFooter, p.testKitActive
        and tr("sf_handful_kit_yes", "Soil test kit in hand: exact figures")
        or tr("sf_handful_kit_no", "No soil test kit: readings are by hand, so they are qualitative"))
end
