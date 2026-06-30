-- =========================================================
-- FS25 Soil & Fertilizer - Field Scout Dialog
-- =========================================================
-- Names the active crop disease on a field and lets the player
-- pick a fungicide (Cycle) and apply it (Apply). Reuses the same
-- ScreenElement + GUI-XML pattern as SoilTreatmentDialog.
-- Opened by the SF_SCOUT hotkey (default Shift+K) and SoilScout.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilScoutDialog
SoilScoutDialog = {}
local SoilScoutDialog_mt = Class(SoilScoutDialog, ScreenElement)

local SF_SCOUT_MOD_NAME = g_currentModName
local SF_SCOUT_MOD_DIR  = g_currentModDirectory

SoilScoutDialog.INSTANCE = nil
SoilScoutDialog.xmlPath  = nil

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_SCOUT_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

local function chemName(id)
    if not id then return "?" end
    if g_i18n and g_i18n:hasText("sf_chem_" .. id) then return g_i18n:getText("sf_chem_" .. id) end
    return (id:gsub("_", " "))
end

local function disName(id)
    if not id then return "" end
    if g_i18n and g_i18n:hasText("sf_dis_" .. id) then return g_i18n:getText("sf_dis_" .. id) end
    return (id:gsub("_", " "))
end

-- ── Constructor / registration ────────────────────────────

function SoilScoutDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilScoutDialog_mt)
    self._fieldId = nil
    return self
end

function SoilScoutDialog.register(modDirectory)
    if SoilScoutDialog.INSTANCE ~= nil then return end

    SF_SCOUT_MOD_DIR = modDirectory
    SoilScoutDialog.xmlPath = modDirectory .. "xml/gui/SoilScoutDialog.xml"
    SoilScoutDialog.INSTANCE = SoilScoutDialog.new()
    SoilLogger.info("SoilScoutDialog: registering from %s", SoilScoutDialog.xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(SoilScoutDialog.xmlPath, "SoilScoutDialog", SoilScoutDialog.INSTANCE)
    end)
    if not ok then
        SoilLogger.error("SoilScoutDialog: loadGui failed: %s", tostring(err))
        SoilScoutDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilScoutDialog: registered successfully")
    end
end

---@param fieldId number
function SoilScoutDialog.show(fieldId)
    if SoilScoutDialog.INSTANCE == nil then
        SoilScoutDialog.register(SF_SCOUT_MOD_DIR)
    end
    local inst = SoilScoutDialog.INSTANCE
    if inst == nil then return end
    inst._fieldId = fieldId
    -- showDialog works on-foot AND in a menu; pairs with closeDialogByName.
    g_gui:showDialog("SoilScoutDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilScoutDialog:onGuiSetupFinished()
    SoilScoutDialog:superClass().onGuiSetupFinished(self)
    self.scoutFieldId  = self:getDescendantById("scoutFieldId")
    self.scoutDisease  = self:getDescendantById("scoutDisease")
    self.scoutSci      = self:getDescendantById("scoutSci")
    self.scoutPressure = self:getDescendantById("scoutPressure")
    self.scoutReco     = self:getDescendantById("scoutReco")
    self.scoutSelChem  = self:getDescendantById("scoutSelChem")
    self.scoutHint     = self:getDescendantById("scoutHint")
end

function SoilScoutDialog:onOpen()
    SoilScoutDialog:superClass().onOpen(self)
    self:_populate()
end

function SoilScoutDialog:onClose()
    SoilScoutDialog:superClass().onClose(self)
end

function SoilScoutDialog:onClickClose()
    g_gui:closeDialogByName("SoilScoutDialog")
end

-- ── Data ──────────────────────────────────────────────────

local function setText(el, text) if el then el:setText(text or "") end end

function SoilScoutDialog:_populate()
    local sfm = g_SoilFertilityManager
    if not (sfm and sfm.soilSystem and self._fieldId) then return end

    setText(self.scoutFieldId, tr("sf_detail_field_label", "Field #") .. tostring(self._fieldId))

    local rep = sfm.soilSystem:getScoutReport(self._fieldId)
    if not rep then return end
    if rep.enabled == false then
        setText(self.scoutDisease, tr("sf_scout_disabled", "Disease system disabled"))
        setText(self.scoutSci, "")
        setText(self.scoutPressure, "")
        setText(self.scoutReco, "")
        setText(self.scoutSelChem, "")
        return
    end

    self._area     = rep.fieldArea or (sfm.soilSystem:getFieldInfo(self._fieldId) or {}).fieldArea or 1.0
    self._disease  = rep.diseaseId
    self._pressure = rep.pressure or 0

    -- Pressure + tier line
    local tierKey = "sf_scout_tier_" .. (rep.tier or "none")
    local tierTxt = tr(tierKey, rep.tier or "none")
    setText(self.scoutPressure, string.format("%s: %d%%  (%s)",
        tr("sf_scout_pressure_label", "Disease pressure"), math.floor(self._pressure + 0.5), tierTxt))

    if rep.diseaseId then
        setText(self.scoutDisease, disName(rep.diseaseId))
        setText(self.scoutSci, rep.diseaseSci or "")
        if rep.recommend then
            setText(self.scoutReco, string.format("%s: %s   ·   2nd: %s   ·   %s: %s",
                tr("sf_treat_best", "Best"), chemName(rep.recommend.best),
                chemName(rep.recommend.second),
                tr("sf_scout_budget", "Budget"), chemName(rep.recommend.budget)))
        else
            setText(self.scoutReco, "")
        end
        setText(self.scoutHint, tr("sf_scout_hint", "Cycle to a fungicide, then Apply."))
    else
        setText(self.scoutDisease, tr("sf_scout_clean_title", "No active disease"))
        setText(self.scoutSci, "")
        setText(self.scoutReco, "")
        setText(self.scoutHint, tr("sf_scout_clean_hint", "Field looks healthy. You can still apply a preventative."))
    end

    self:_buildChemList()
end

-- Ordered chemical list (best control vs the active disease first; catalog order
-- when there's no named disease, for a preventative pick).
function SoilScoutDialog:_buildChemList()
    self._chemList = {}
    self._chemIdx  = 1
    if not (SoilDiseaseSystem and SoilConstants.FUNGICIDE_ORDER) then
        setText(self.scoutSelChem, "")
        return
    end

    local ordered = {}
    for _, id in ipairs(SoilConstants.FUNGICIDE_ORDER) do
        local chem = SoilConstants.FUNGICIDE_CATALOG[id]
        if chem and not chem.seedTreatment then
            local rate = self._disease and SoilDiseaseSystem.effectiveness(id, self._disease) or 0
            ordered[#ordered + 1] = { id = id, rate = rate, cost = chem.costPerHa or 0 }
        end
    end
    if self._disease then
        table.sort(ordered, function(a, b)
            if a.rate ~= b.rate then return a.rate > b.rate end
            return a.cost < b.cost
        end)
    end
    for _, e in ipairs(ordered) do self._chemList[#self._chemList + 1] = e.id end

    self:_updateChemSelection()
end

function SoilScoutDialog:_updateChemSelection()
    local id = self._chemList and self._chemList[self._chemIdx]
    if not id then setText(self.scoutSelChem, ""); return end
    local chem = SoilConstants.FUNGICIDE_CATALOG[id]
    local total = math.ceil((chem.costPerHa or 0) * (self._area or 1.0))
    local parts = { chemName(id) }
    if self._disease then
        local pct = math.floor(SoilDiseaseSystem.effectiveness(id, self._disease) * 100 + 0.5)
        parts[#parts + 1] = string.format("%d%% %s %s", pct, tr("sf_treat_vs", "vs"), disName(self._disease))
    end
    parts[#parts + 1] = string.format("$%d/ha (~$%d)", chem.costPerHa or 0, total)
    setText(self.scoutSelChem, table.concat(parts, "  ·  ")
        .. string.format("   [%d/%d]", self._chemIdx, #self._chemList))
end

function SoilScoutDialog:onClickCycle()
    if not self._chemList or #self._chemList == 0 then return end
    self._chemIdx = (self._chemIdx % #self._chemList) + 1
    self:_updateChemSelection()
end

function SoilScoutDialog:onClickApply()
    local sfm = g_SoilFertilityManager
    local id  = self._chemList and self._chemList[self._chemIdx]
    if not (sfm and sfm.soilSystem and self._fieldId and id) then return end

    local ok, _, detail = sfm.soilSystem:applyNamedFungicide(self._fieldId, id, { charge = true })
    if not ok then return end
    detail = detail or {}
    if detail.control ~= nil then
        setText(self.scoutHint, string.format(
            tr("sf_treat_applied", "Applied %s: %d%% control, -%d pressure, %d-day protection, $%d"),
            chemName(id), math.floor((detail.control or 0) * 100 + 0.5),
            math.floor(detail.reduction or 0), detail.protDays or 0, math.floor(detail.cost or 0)))
    else
        setText(self.scoutHint, tr("sf_treat_sent_hint", "Treatment requested."))
    end
    -- Re-pull so the disease line + selector reflect the knock-down.
    self:_populate()
end
