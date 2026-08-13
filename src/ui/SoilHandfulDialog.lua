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
-- Same ScreenElement + GUI-XML pattern as SoilScoutDialog / SoilTreatmentDialog.
--
-- RENDERING RULES (inherited cert gates from the SF-38 contract, not new):
--   GRAIN HONESTY      - every section carries its grain tag; a FIELD clause is
--                        never drawn as if it were measured at the spot.
--   PER-CLAUSE NEUTRAL - one absent system blanks its own clause only. A nil
--                        clause renders a dash, never a zero, never an error.
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
SoilHandfulDialog = {}
local SoilHandfulDialog_mt = Class(SoilHandfulDialog, ScreenElement)

local SF_HANDFUL_MOD_NAME = g_currentModName
local SF_HANDFUL_MOD_DIR  = g_currentModDirectory

SoilHandfulDialog.INSTANCE = nil
SoilHandfulDialog.xmlPath  = nil

local DASH = "--"

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

-- ── Bands (every cut point below is a SHIPPED value) ──────

-- N/P/K arrive from the core already banded: getFieldInfo returns
-- { value, status } with status in Poor/Fair/Good/Unknown. We localise the word
-- and never re-derive it.
local function bandNutrient(clause)
    if type(clause) ~= "table" or type(clause.status) ~= "string" then return nil end
    local s = clause.status:lower()
    return tr("sf_handful_band_" .. s, clause.status)
end

-- pH: SoilConstants.REPORT_COLORS, the same cut points the report display uses.
local function bandPh(ph)
    if type(ph) ~= "number" then return nil end
    local rc = SoilConstants and SoilConstants.REPORT_COLORS
    if rc == nil then return nil end
    if ph >= (rc.PH_GOOD_LOW or 6.0) and ph <= (rc.PH_GOOD_HIGH or 7.0) then
        return tr("sf_handful_band_good", "Good")
    elseif ph < (rc.PH_FAIR_LOW or 5.5) then
        return tr("sf_handful_band_acidic", "Acidic")
    elseif ph > (rc.PH_FAIR_HIGH or 7.5) then
        return tr("sf_handful_band_alkaline", "Alkaline")
    end
    return tr("sf_handful_band_fair", "Fair")
end

-- Organic matter: SoilConstants.REPORT_COLORS OM_GOOD / OM_FAIR.
local function bandOm(om)
    if type(om) ~= "number" then return nil end
    local rc = SoilConstants and SoilConstants.REPORT_COLORS
    if rc == nil then return nil end
    if om >= (rc.OM_GOOD or 4.0) then return tr("sf_handful_band_good", "Good") end
    if om >= (rc.OM_FAIR or 2.5) then return tr("sf_handful_band_fair", "Fair") end
    return tr("sf_handful_band_poor", "Poor")
end

-- Compaction: the cut points the shipped map layer already displays against
-- (SoilMapOverlay layer 10: <25 no action, <60 subsoiling recommended, else
-- urgent). Reused rather than re-invented so the two surfaces never disagree.
local function bandCompaction(c)
    if type(c) ~= "number" then return nil end
    if c < 25 then return tr("sf_handful_band_low", "Low") end
    if c < 60 then return tr("sf_handful_band_moderate", "Moderate") end
    return tr("sf_handful_band_high", "High")
end

-- Pressure tiers: SoilConstants.DISEASE_PRESSURE LOW/MEDIUM/HIGH, the same
-- ladder scoutField uses for its tier word.
local function bandPressure(v)
    if type(v) ~= "number" then return nil end
    local dp = SoilConstants and SoilConstants.DISEASE_PRESSURE
    if dp == nil then return nil end
    if v < (dp.LOW or 20) then return tr("sf_scout_tier_none", "None") end
    if v < (dp.MEDIUM or 50) then return tr("sf_scout_tier_mild", "Mild") end
    if v < (dp.HIGH or 75) then return tr("sf_scout_tier_moderate", "Moderate") end
    return tr("sf_scout_tier_severe", "Severe")
end

-- Material bands arrive from the layers as lowercase ids ("damp", "curing").
-- The l10n key carries the display word; the FALLBACK has to capitalise, or a
-- missing key degrades to a lowercase word sitting next to capitalised ones.
local function bandMaterial(band)
    if type(band) ~= "string" or band == "" then return nil end
    local lower = band:lower()
    return tr("sf_handful_band_" .. lower, lower:sub(1, 1):upper() .. lower:sub(2))
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

function SoilHandfulDialog:onGuiSetupFinished()
    SoilHandfulDialog:superClass().onGuiSetupFinished(self)
    self.hfHeader      = self:getDescendantById("hfHeader")
    self.hfNutrients   = self:getDescendantById("hfNutrients")
    self.hfPhOm        = self:getDescendantById("hfPhOm")
    self.hfGround      = self:getDescendantById("hfGround")
    self.hfDisease     = self:getDescendantById("hfDisease")
    self.hfPestWeed    = self:getDescendantById("hfPestWeed")
    self.hfCrops       = self:getDescendantById("hfCrops")
    self.hfRotation    = self:getDescendantById("hfRotation")
    self.hfOrganic     = self:getDescendantById("hfOrganic")
    self.hfSecMaterial = self:getDescendantById("hfSecMaterial")
    self.hfMaterial    = self:getDescendantById("hfMaterial")
    self.hfFooter      = self:getDescendantById("hfFooter")
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

--- "Label: value" with the neutral dash when the clause is absent. This is the
--- per-clause neutrality rule in one function: nil never becomes 0.
local function pair(label, value)
    return string.format("%s: %s", label, value or DASH)
end

function SoilHandfulDialog:_populate()
    local p = self._payload
    if p == nil then
        setText(self.hfHeader, tr("sf_handful_no_read", "Nothing read"))
        return
    end

    -- Header: which field, and whether the nutrient row was refined to the spot.
    -- ONE shared refinement flag for N/P/K/pH/OM, labelled once, per the contract.
    local grain = p.fromZoneCell
        and tr("sf_handful_grain_spot", "spot")
        or tr("sf_handful_grain_field", "field average")
    setText(self.hfHeader, string.format("%s%s   ·   %s",
        tr("sf_detail_field_label", "Field #"), tostring(p.fieldId or "?"), grain))

    -- Nutrients (SPOT). Bands only: testKitActive is false until the kit ships.
    setText(self.hfNutrients, string.format("%s    %s    %s",
        pair(tr("sf_handful_n", "N"), bandNutrient(p.N)),
        pair(tr("sf_handful_p", "P"), bandNutrient(p.P)),
        pair(tr("sf_handful_k", "K"), bandNutrient(p.K))))
    setText(self.hfPhOm, string.format("%s    %s",
        pair(tr("sf_handful_ph", "pH"), bandPh(p.pH)),
        pair(tr("sf_handful_om", "Organic matter"), bandOm(p.OM))))

    -- Ground: compaction is SPOT, moisture is FIELD and UNGATED, so moisture
    -- shows its real figure rather than a band it was never gated behind.
    local moisture = type(p.moisture) == "number"
        and string.format("%d%%", math.floor(p.moisture * 100 + 0.5)) or nil
    setText(self.hfGround, string.format("%s    %s",
        pair(tr("sf_handful_compaction", "Compaction"), bandCompaction(p.compaction)),
        pair(tr("sf_handful_moisture", "Moisture"), moisture)))

    -- Disease: knowledge-gated. shownDiseasePressure is nil while unscouted and
    -- that is the honest answer, not a hole. The grain label says whether this
    -- is the knelt cell or the whole field.
    local disTxt
    if p.diseasePressure == nil then
        disTxt = tr("sf_handful_unscouted", "Unscouted")
    else
        disTxt = bandPressure(p.diseasePressure) or DASH
    end
    local disGrain = (p.diseaseGrain == "cell")
        and tr("sf_handful_grain_cell", "this cell")
        or tr("sf_handful_grain_field", "field average")
    setText(self.hfDisease, string.format("%s   (%s)",
        pair(tr("sf_handful_disease", "Disease pressure"), disTxt), disGrain))

    -- Pests and weeds: FIELD grain, UNGATED at source, so no knowledge gate here.
    setText(self.hfPestWeed, string.format("%s    %s",
        pair(tr("sf_handful_pest", "Pests"), bandPressure(p.pestPressure)),
        pair(tr("sf_handful_weed", "Weeds"), bandPressure(p.weedPressure))))

    -- History (FIELD).
    local crops = {}
    for _, id in ipairs({ p.lastCrop, p.lastCrop2, p.lastCrop3 }) do
        local n = cropName(id)
        if n then crops[#crops + 1] = n end
    end
    setText(self.hfCrops, pair(tr("sf_handful_last_crops", "Last crops"),
        #crops > 0 and table.concat(crops, "  >  ") or nil))

    local rot = p.rotationStatus
        and tr("sf_handful_rot_" .. tostring(p.rotationStatus):lower(), tostring(p.rotationStatus))
        or nil
    local rotLine = pair(tr("sf_handful_rotation", "Rotation"), rot)
    if (p.rotationBonusDaysLeft or 0) > 0 then
        rotLine = rotLine .. string.format("  (%s)", string.format(
            tr("sf_handful_bonus_days", "%d bonus days left"), p.rotationBonusDaysLeft))
    end
    rotLine = rotLine .. string.format("    %s", pair(
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
    setText(self.hfOrganic, pair(tr("sf_handful_organic", "Organic"), orgTxt))

    -- Under the hand (SPOT). The whole section hides when nothing lies there:
    -- an "unavailable" or "refusal" status is not a value to render.
    local wet, down, verdict = p.materialWetness, p.materialDaysDown, p.materialVerdict
    local hasMaterial = type(wet) == "table" and wet.band ~= nil
    setVisible(self.hfSecMaterial, hasMaterial)
    setVisible(self.hfMaterial, hasMaterial)
    if hasMaterial then
        local parts = {
            pair(tr("sf_handful_mat_wetness", "Wetness"), bandMaterial(wet.band)),
            pair(tr("sf_handful_mat_days", "Days down"),
                (type(down) == "table" and down.days) and tostring(down.days) or nil),
        }
        if type(verdict) == "table" and verdict.status == "ok" then
            parts[#parts + 1] = pair(tr("sf_handful_mat_verdict", "Verdict"),
                verdict.spoiled and tr("sf_handful_mat_spoiled", "Spoiled")
                or tr("sf_handful_mat_sound", "Sound"))
        end
        setText(self.hfMaterial, table.concat(parts, "    "))
    end

    -- Footer: the grain legend, and the kit state that explains why the numbers
    -- above are words.
    local kit = p.testKitActive
        and tr("sf_handful_kit_yes", "Soil test kit in hand: exact figures")
        or tr("sf_handful_kit_no", "No soil test kit: readings are by hand, so they are qualitative")
    setText(self.hfFooter, kit)
end
