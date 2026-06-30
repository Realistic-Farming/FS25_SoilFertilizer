-- =========================================================
-- FS25 Soil & Fertilizer - Treatment Prescription Dialog
-- =========================================================
-- Provides actionable advice on which products to apply
-- to a field based on its current nutrient and pressure status.
-- Opened from the Treatment tab of SoilPDAScreen.
--
-- Pattern: ScreenElement (proven pattern for popups).
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilTreatmentDialog
SoilTreatmentDialog = {}
local SoilTreatmentDialog_mt = Class(SoilTreatmentDialog, ScreenElement)

-- Capture mod name at source-time
local SF_TREAT_MOD_NAME = g_currentModName
local SF_TREAT_MOD_DIR  = g_currentModDirectory

-- Singleton
SoilTreatmentDialog.INSTANCE = nil
SoilTreatmentDialog.xmlPath  = nil

-- Colors
local COLOR_WHITE = {1.00, 1.00, 1.00, 1.0}
local COLOR_DIM   = {0.60, 0.60, 0.60, 1.0}

local function getStatusColors()
    local cb = g_SoilFertilityManager and g_SoilFertilityManager.settings and g_SoilFertilityManager.settings.colorblindMode
    if cb then
        return {0.90, 0.37, 0.00, 1.0}, {0.94, 0.86, 0.00, 1.0}, {0.00, 0.45, 0.70, 1.0}
    end
    return {0.88, 0.25, 0.25, 1.0}, {0.90, 0.82, 0.18, 1.0}, {0.25, 0.85, 0.25, 1.0}
end

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_TREAT_MOD_NAME]
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

function SoilTreatmentDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilTreatmentDialog_mt)
    self._fieldId = nil
    return self
end

---@param modDirectory string
function SoilTreatmentDialog.register(modDirectory)
    if SoilTreatmentDialog.INSTANCE ~= nil then return end

    SF_TREAT_MOD_DIR = modDirectory
    SoilTreatmentDialog.xmlPath = modDirectory .. "xml/gui/SoilTreatmentDialog.xml"
    
    SoilTreatmentDialog.INSTANCE = SoilTreatmentDialog.new()
    SoilLogger.info("SoilTreatmentDialog: registering from %s", SoilTreatmentDialog.xmlPath)
    
    local ok, err = pcall(function()
        g_gui:loadGui(
            SoilTreatmentDialog.xmlPath,
            "SoilTreatmentDialog",
            SoilTreatmentDialog.INSTANCE
        )
    end)
    
    if not ok then
        SoilLogger.error("SoilTreatmentDialog: loadGui failed: %s", tostring(err))
        SoilTreatmentDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilTreatmentDialog: registered successfully")
    end
end

---@param fieldId number
function SoilTreatmentDialog.show(fieldId)
    SoilLogger.debug("SoilTreatmentDialog.show(fieldId=%s)", tostring(fieldId))
    
    if SoilTreatmentDialog.INSTANCE == nil then
        SoilTreatmentDialog.register(SF_TREAT_MOD_DIR)
    end

    local inst = SoilTreatmentDialog.INSTANCE
    if inst == nil then return end

    inst._fieldId = fieldId

    -- Always use showDialog so the panel opens AND closes (via closeDialogByName)
    -- whether or not a menu is already up. showGui replaced the active screen and
    -- left the Close button unable to dismiss it on foot (the orphaned-panel bug).
    g_gui:showDialog("SoilTreatmentDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilTreatmentDialog:onGuiSetupFinished()
    SoilTreatmentDialog:superClass().onGuiSetupFinished(self)

    self.treatTitle         = self:getDescendantById("treatTitle")
    self.treatFieldId       = self:getDescendantById("treatFieldId")
    self.treatPHAction      = self:getDescendantById("treatPHAction")
    self.treatOMAction      = self:getDescendantById("treatOMAction")
    self.treatNAction       = self:getDescendantById("treatNAction")
    self.treatPAction       = self:getDescendantById("treatPAction")
    self.treatKAction       = self:getDescendantById("treatKAction")
    self.treatWeedAction    = self:getDescendantById("treatWeedAction")
    self.treatPestAction    = self:getDescendantById("treatPestAction")
    self.treatDiseaseAction = self:getDescendantById("treatDiseaseAction")
    self.treatHint          = self:getDescendantById("treatHint")
end

function SoilTreatmentDialog:onOpen()
    SoilTreatmentDialog:superClass().onOpen(self)
    self:_populateData()
end

function SoilTreatmentDialog:onClose()
    SoilTreatmentDialog:superClass().onClose(self)
    self._fieldId = nil
end

function SoilTreatmentDialog:onClickClose()
    g_gui:closeDialogByName("SoilTreatmentDialog")
end

-- ── Rate Calculation ──────────────────────────────────────

-- Returns "PRODUCTNAME 220 kg/ha (1056 kg)" or nil if profile missing / no deficit.
local function _rateString(profileKey, nutrientKey, deficit, rrMult, fieldArea)
    if deficit <= 0 then return nil end
    local profile  = SoilConstants.FERTILIZER_PROFILES[profileKey]
    local baseRate = SoilConstants.SPRAYER_RATE.BASE_RATES[profileKey]
    if not profile or not profile[nutrientKey] or profile[nutrientKey] == 0 then return nil end

    local coeff     = profile[nutrientKey]
    local ratePerHa = deficit * 1000 / (coeff * rrMult)
    local total     = ratePerHa * fieldArea
    local isDry     = baseRate and baseRate.unit == "dry"
    local useImp    = g_SoilFertilityManager and g_SoilFertilityManager.settings
                        and g_SoilFertilityManager.settings.useImperialUnits

    local displayRate, displayTotal, unit, totalUnit
    if useImp then
        if isDry then
            displayRate  = math.ceil(ratePerHa * SoilConstants.SPRAYER_RATE.KG_PER_HA_TO_LB_PER_AC)
            displayTotal = math.ceil(total * 2.20462)
            unit, totalUnit = "lb/ac", "lb"
        else
            displayRate  = math.ceil(ratePerHa * SoilConstants.SPRAYER_RATE.L_PER_HA_TO_GAL_PER_AC)
            displayTotal = math.ceil(total * 0.26417)
            unit, totalUnit = "gal/ac", "gal"
        end
    else
        displayRate  = math.ceil(ratePerHa)
        displayTotal = math.ceil(total)
        unit, totalUnit = isDry and "kg/ha" or "L/ha", isDry and "kg" or "L"
    end

    return string.format("%s %d %s (%d %s)", profileKey, displayRate, unit, displayTotal, totalUnit)
end

-- Builds a two-product action string for a nutrient, e.g.:
--   "UREA 220 kg/ha (1056 kg)  ·  UAN32 139 L/ha (667 L)"
-- Falls back to a static hint when rates cannot be computed.
local function _nutrientActionText(currentVal, targetVal, rrMult, fieldArea, products, staticFallback)
    local deficit = math.max(0, targetVal - currentVal)
    local parts = {}
    for _, prod in ipairs(products) do
        local s = _rateString(prod[1], prod[2], deficit, rrMult, fieldArea)
        if s then parts[#parts + 1] = s end
    end
    if #parts == 0 then return staticFallback end
    return table.concat(parts, "  ·  ")
end

-- ── Data Population ───────────────────────────────────────

function SoilTreatmentDialog:_populateData()
    local COLOR_POOR, COLOR_FAIR, COLOR_GOOD = getStatusColors()
    local fieldId = self._fieldId
    local sfm = g_SoilFertilityManager

    if fieldId == nil or sfm == nil or sfm.soilSystem == nil then
        self:_setAllNoAction()
        return
    end

    local info = sfm.soilSystem:getFieldInfo(fieldId)
    if info == nil then
        self:_setAllNoAction()
        return
    end

    if self.treatFieldId then
        self.treatFieldId:setText(tr("sf_detail_field_label", "Field #") .. tostring(fieldId))
    end

    -- 1. pH Action
    local ph = math.floor(((info.pH or 7.0) * 10) + 0.5) / 10
    if ph < 6.5 then
        self:_setAction(self.treatPHAction, tr("sf_treat_action_lime", "Apply LIME or LIQUID LIME to raise pH."), COLOR_POOR)
    elseif ph > 7.5 then
        self:_setAction(self.treatPHAction, tr("sf_treat_action_gypsum", "Apply GYPSUM to lower pH / improve structure."), COLOR_FAIR)
    else
        self:_setAction(self.treatPHAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- 2. OM Action
    local om = info.organicMatter or 3.5
    if om < 3.0 then
        self:_setAction(self.treatOMAction, tr("sf_treat_action_om_low", "Plow in MANURE, COMPOST, or chop straw."), COLOR_POOR)
    elseif om < 4.0 then
        self:_setAction(self.treatOMAction, tr("sf_treat_action_om_fair", "Monitor. Maintain organic inputs."), COLOR_FAIR)
    else
        self:_setAction(self.treatOMAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- 3. Nutrient Actions (N, P, K) with per-product application rates
    local thresh  = SoilConstants.STATUS_THRESHOLDS
    local targets = SoilConstants.CROP_NUTRIENT_TARGETS
    local fieldArea = info.fieldArea or 1.0

    -- Replenishment multiplier from settings (index 1-5, default Normal = 3 = 1.00×)
    local rrIdx = (sfm.settings and sfm.settings.replenishmentRate) or 3
    local rrMult = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[rrIdx] or 1.0

    -- Crop-specific targets or status-threshold fallbacks
    local ct = info.cropTargets
    local targetN = (ct and ct.N and ct.N.opt) or (thresh.nitrogen.fair or 50)
    local targetP = (ct and ct.P and ct.P.opt) or (thresh.phosphorus.fair or 45)
    local targetK = (ct and ct.K and ct.K.opt) or (thresh.potassium.fair or 40)

    -- N
    if info.nitrogen.value < (thresh.nitrogen.poor or 30) then
        local text = _nutrientActionText(info.nitrogen.value, targetN, rrMult, fieldArea,
            { {"UREA","N"}, {"UAN32","N"} },
            "Apply UREA or UAN32")
        self:_setAction(self.treatNAction, text, COLOR_POOR)
    elseif info.nitrogen.value < (thresh.nitrogen.fair or 50) then
        local text = _nutrientActionText(info.nitrogen.value, targetN, rrMult, fieldArea,
            { {"AMS","N"}, {"AN","N"} },
            "Apply AMS or AN")
        self:_setAction(self.treatNAction, text, COLOR_FAIR)
    else
        self:_setAction(self.treatNAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- P
    if info.phosphorus.value < (thresh.phosphorus.poor or 25) then
        local text = _nutrientActionText(info.phosphorus.value, targetP, rrMult, fieldArea,
            { {"MAP","P"}, {"DAP","P"} },
            "Apply MAP or DAP")
        self:_setAction(self.treatPAction, text, COLOR_POOR)
    elseif info.phosphorus.value < (thresh.phosphorus.fair or 45) then
        local text = _nutrientActionText(info.phosphorus.value, targetP, rrMult, fieldArea,
            { {"LIQUID_MAP","P"}, {"LIQUID_DAP","P"} },
            "Top-up with Liquid MAP or Liquid DAP")
        self:_setAction(self.treatPAction, text, COLOR_FAIR)
    else
        self:_setAction(self.treatPAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- K
    if info.potassium.value < (thresh.potassium.poor or 20) then
        local text = _nutrientActionText(info.potassium.value, targetK, rrMult, fieldArea,
            { {"POTASH","K"}, {"LIQUID_POTASH","K"} },
            "Apply POTASH")
        self:_setAction(self.treatKAction, text, COLOR_POOR)
    elseif info.potassium.value < (thresh.potassium.fair or 40) then
        local text = _nutrientActionText(info.potassium.value, targetK, rrMult, fieldArea,
            { {"POTASH","K"}, {"LIQUID_POTASH","K"} },
            "Top-up with POTASH or Liquid POTASH")
        self:_setAction(self.treatKAction, text, COLOR_FAIR)
    else
        self:_setAction(self.treatKAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- 4. Protection Actions
    local pThresh = 20

    -- Weed
    if (info.weedPressure or 0) >= pThresh then
        self:_setAction(self.treatWeedAction, tr("sf_treat_action_weed", "Apply HERBICIDE or use mechanical WEEDER/HOE."), COLOR_POOR)
    else
        self:_setAction(self.treatWeedAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- Pest
    if (info.pestPressure or 0) >= pThresh then
        self:_setAction(self.treatPestAction, tr("sf_treat_action_pest", "Apply INSECTICIDE immediately."), COLOR_POOR)
    else
        self:_setAction(self.treatPestAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end

    -- Disease
    if (info.diseasePressure or 0) >= pThresh then
        self:_setAction(self.treatDiseaseAction, tr("sf_treat_action_disease", "Apply FUNGICIDE immediately."), COLOR_POOR)
    else
        self:_setAction(self.treatDiseaseAction, tr("sf_treat_action_ok", "OK"), COLOR_GOOD)
    end
end

function SoilTreatmentDialog:_setAction(el, text, color)
    if el then
        el:setText(text)
        el:setTextColor(unpack(color))
    end
end

function SoilTreatmentDialog:_setAllNoAction()
    local els = {
        self.treatPHAction, self.treatOMAction,
        self.treatNAction, self.treatPAction, self.treatKAction,
        self.treatWeedAction, self.treatPestAction, self.treatDiseaseAction
    }
    for _, el in ipairs(els) do
        self:_setAction(el, "--", COLOR_DIM)
    end
end
