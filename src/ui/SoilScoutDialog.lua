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
SoilScoutDialog = SoilScoutDialog or {}
local SoilScoutDialog_mt = Class(SoilScoutDialog, ScreenElement)

local SF_SCOUT_MOD_DIR  = (SoilFertilizerModDirectory or g_currentModDirectory)

SoilScoutDialog.INSTANCE = nil
SoilScoutDialog.xmlPath  = nil

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    -- Gate on hasText, never on the returned string: getText never returns nil,
    -- "" or ("$l10n_" .. key), and for an absent key I18N.lua:186 returns
    -- "Missing '<key>' in l10n<suffix>.xml", which is what the old guard let
    -- through to the player. Past hasText the return is opaque: check type and
    -- non-empty, never inspect it.
    local i18n = g_i18n
    if i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
        return fallback or key
    end
    local okHas, has = pcall(i18n.hasText, i18n, key)
    if not okHas or has ~= true then return fallback or key end
    local ok, text = pcall(i18n.getText, i18n, key)
    if not ok or type(text) ~= "string" or text == "" then return fallback or key end
    return text
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

    -- Opening the Scout dialog on a field IS the act of scouting it: reveal the disease
    -- (flips the discovery gate) so the report shows the name + recommendation. Every
    -- other surface stays gated until it too is scouted / reported / dog-flagged.
    -- [RSF-F231] For the local player's own farm. Refused: the panel says so and
    -- offers no chemical, so Apply has nothing to send.
    local rep, refused = sfm.soilSystem:scoutField(self._fieldId, SoilFertilitySystem.localScoutFarmId())
    if not rep then return end
    if refused ~= nil then
        setText(self.scoutDisease, tr("sf_scout_no_standing", "Your farm neither owns nor contracts this land. Nothing was scouted."))
        setText(self.scoutSci, "")
        setText(self.scoutPressure, "")
        setText(self.scoutReco, "")
        setText(self.scoutSelChem, "")
        setText(self.scoutHint, "")
        self._chemList, self._chemIdx = {}, 1
        return
    end
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
    parts[#parts + 1] = string.format("%s/ha (~%s)", UIHelper.formatCurrencyValue(chem.costPerHa or 0), UIHelper.formatCurrencyValue(total))
    if SoilConstants.PHYSICAL_FUNGICIDES and SoilConstants.PHYSICAL_FUNGICIDES[id] then
        parts[#parts + 1] = tr("sf_treat_tank_tag", "tank - spray")
    end
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

    -- Physical fungicides are sprayed from a tank, not instant-applied from the menu.
    if SoilConstants.PHYSICAL_FUNGICIDES and SoilConstants.PHYSICAL_FUNGICIDES[id] then
        setText(self.scoutHint, string.format(
            tr("sf_treat_physical", "%s is a sprayable product - buy the tank and spray the field"),
            chemName(id)))
        return
    end

    local ok, _, detail = sfm.soilSystem:applyNamedFungicide(self._fieldId, id, { charge = true })
    if not ok then return end
    detail = detail or {}
    if detail.control ~= nil then
        setText(self.scoutHint, string.format(
            tr("sf_treat_applied", "Applied %s: %d%% control, -%d pressure, %d-day protection, %s"),
            chemName(id), math.floor((detail.control or 0) * 100 + 0.5),
            math.floor(detail.reduction or 0), detail.protDays or 0, UIHelper.formatCurrencyValue(math.floor(detail.cost or 0))))
    else
        setText(self.scoutHint, tr("sf_treat_sent_hint", "Treatment requested."))
    end
    -- Re-pull so the disease line + selector reflect the knock-down.
    self:_populate()
end
