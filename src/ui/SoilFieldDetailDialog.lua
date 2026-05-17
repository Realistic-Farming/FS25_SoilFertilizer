-- =========================================================
-- FS25 Soil & Fertilizer — Field Detail Dialog
-- =========================================================
-- Full per-field nutrient + pressure detail popup.
-- Opened by clicking a row in the Fields or Treatment tab
-- of SoilPDAScreen.
--
-- Pattern: ScreenElement (proven pattern for popups in this mod).
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilFieldDetailDialog
SoilFieldDetailDialog = {}
local SoilFieldDetailDialog_mt = Class(SoilFieldDetailDialog, ScreenElement)

-- Capture mod name at source-time
local SF_DETAIL_MOD_NAME = g_currentModName
local SF_DETAIL_MOD_DIR  = g_currentModDirectory

-- Singleton
SoilFieldDetailDialog.INSTANCE = nil
SoilFieldDetailDialog.xmlPath  = nil

-- Status colors (static defaults; overridden per-call when colorblind mode is on)
local COLOR_WHITE = {1.00, 1.00, 1.00, 1.0}
local COLOR_GREEN = {0.35, 0.85, 0.40, 1.0}
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
    local modEnv = g_modEnvironments and g_modEnvironments[SF_DETAIL_MOD_NAME]
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

function SoilFieldDetailDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilFieldDetailDialog_mt)

    -- Current field ID being shown
    self._fieldId = nil

    return self
end

-- Capture mod directory at source-time (valid during loading only)
local SF_DETAIL_MOD_DIR = g_currentModDirectory

---@param modDirectory string  Path to mod directory (with trailing slash)
function SoilFieldDetailDialog.register(modDirectory)
    if SoilFieldDetailDialog.INSTANCE ~= nil then return end

    SF_DETAIL_MOD_DIR = modDirectory -- Global to store for later lazy-reloads
    SoilFieldDetailDialog.xmlPath = modDirectory .. "xml/gui/SoilFieldDetailDialog.xml"
    
    SoilFieldDetailDialog.INSTANCE = SoilFieldDetailDialog.new()
    SoilLogger.info("SoilFieldDetailDialog: registering from %s", SoilFieldDetailDialog.xmlPath)
    
    local ok, err = pcall(function()
        g_gui:loadGui(
            SoilFieldDetailDialog.xmlPath,
            "SoilFieldDetailDialog",
            SoilFieldDetailDialog.INSTANCE
        )
    end)
    
    if not ok then
        SoilLogger.error("SoilFieldDetailDialog: loadGui failed: %s", tostring(err))
        SoilFieldDetailDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilFieldDetailDialog: registered successfully")
    end
end

---@param fieldId number
function SoilFieldDetailDialog.show(fieldId)
    SoilLogger.debug("SoilFieldDetailDialog.show(fieldId=%s)", tostring(fieldId))
    
    -- Lazy-register if not yet loaded
    if SoilFieldDetailDialog.INSTANCE == nil then
        SoilLogger.debug("SoilFieldDetailDialog: lazy-registering from show()")
        SoilFieldDetailDialog.register(SF_DETAIL_MOD_DIR)
    end

    local inst = SoilFieldDetailDialog.INSTANCE
    if inst == nil then
        SoilLogger.warning("SoilFieldDetailDialog.show: no instance available")
        return
    end

    inst._fieldId = fieldId
    
    -- Ensure we are in a state to show a dialog
    if g_gui:getIsGuiVisible() then
        SoilLogger.debug("SoilFieldDetailDialog: showing dialog via showDialog()")
        g_gui:showDialog("SoilFieldDetailDialog")
    else
        -- PDA might be closed, but we were called somehow?
        SoilLogger.debug("SoilFieldDetailDialog: showing via showGui()")
        g_gui:showGui("SoilFieldDetailDialog")
    end
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilFieldDetailDialog:onGuiSetupFinished()
    SoilFieldDetailDialog:superClass().onGuiSetupFinished(self)
    SoilLogger.debug("SoilFieldDetailDialog: onGuiSetupFinished")

    -- Cache references
    self.detailTitle         = self:getDescendantById("detailTitle")
    self.detailFieldId       = self:getDescendantById("detailFieldId")
    self.detailUrgency       = self:getDescendantById("detailUrgency")
    self.detailN             = self:getDescendantById("detailN")
    self.detailNStatus       = self:getDescendantById("detailNStatus")
    self.detailP             = self:getDescendantById("detailP")
    self.detailPStatus       = self:getDescendantById("detailPStatus")
    self.detailK             = self:getDescendantById("detailK")
    self.detailKStatus       = self:getDescendantById("detailKStatus")
    self.detailPH            = self:getDescendantById("detailPH")
    self.detailPHStatus      = self:getDescendantById("detailPHStatus")
    self.detailOM            = self:getDescendantById("detailOM")
    self.detailOMStatus      = self:getDescendantById("detailOMStatus")
    self.detailWeed          = self:getDescendantById("detailWeed")
    self.detailWeedStatus    = self:getDescendantById("detailWeedStatus")
    self.detailPest          = self:getDescendantById("detailPest")
    self.detailPestStatus    = self:getDescendantById("detailPestStatus")
    self.detailDisease       = self:getDescendantById("detailDisease")
    self.detailDiseaseStatus = self:getDescendantById("detailDiseaseStatus")
    self.detailLastCrop      = self:getDescendantById("detailLastCrop")
    self.detailRotation      = self:getDescendantById("detailRotation")
    self.detailNoData        = self:getDescendantById("detailNoData")
end

function SoilFieldDetailDialog:onOpen()
    SoilLogger.debug("SoilFieldDetailDialog: onOpen(fieldId=%s)", tostring(self._fieldId))
    SoilFieldDetailDialog:superClass().onOpen(self)
    self:_populateData()
end

function SoilFieldDetailDialog:onClose()
    SoilLogger.debug("SoilFieldDetailDialog: onClose()")
    SoilFieldDetailDialog:superClass().onClose(self)
    self._fieldId = nil
end

-- ── Button callbacks ──────────────────────────────────────

-- ⚠ Must NOT be named onClose — that conflicts with GUI lifecycle
function SoilFieldDetailDialog:onClickClose()
    self:close()
end

-- ── Close helper ─────────────────────────────────────────

function SoilFieldDetailDialog:close()
    g_gui:closeDialogByName("SoilFieldDetailDialog")
end

-- ── Data population ───────────────────────────────────────

function SoilFieldDetailDialog:_populateData()
    local COLOR_POOR, COLOR_FAIR, COLOR_GOOD = getStatusColors()
    local fieldId = self._fieldId
    local sfm = g_SoilFertilityManager

    -- Guard: no field ID or no soil system
    if fieldId == nil or sfm == nil or sfm.soilSystem == nil then
        self:_showNoData()
        return
    end

    local ok, info = pcall(function()
        return sfm.soilSystem:getFieldInfo(fieldId)
    end)
    if not ok or info == nil then
        self:_showNoData()
        return
    end

    local urgOk, urgency = pcall(function()
        return sfm.soilSystem:getFieldUrgency(fieldId)
    end)
    if not urgOk then urgency = 0 end

    -- Hide no-data hint, show content
    if self.detailNoData then self.detailNoData:setVisible(false) end

    -- Field ID in title
    if self.detailFieldId then
        self.detailFieldId:setText(tr("sf_detail_field_label", "Field #") .. tostring(fieldId))
    end

    -- Urgency
    if self.detailUrgency then
        local urgRounded = math.floor(urgency)
        self.detailUrgency:setText(urgRounded .. "%")
        if urgRounded >= 60 then
            self.detailUrgency:setTextColor(unpack(COLOR_POOR))
        elseif urgRounded >= 25 then
            self.detailUrgency:setTextColor(unpack(COLOR_FAIR))
        else
            self.detailUrgency:setTextColor(unpack(COLOR_GOOD))
        end
    end

    -- Nutrients (pass per-crop targets when a crop is planted)
    local ct = info.cropTargets
    self:_setNutrient(self.detailN, self.detailNStatus,
        info.nitrogen.value, info.nitrogen.status, "%", ct and ct.N)
    self:_setNutrient(self.detailP, self.detailPStatus,
        info.phosphorus.value, info.phosphorus.status, "%", ct and ct.P)
    self:_setNutrient(self.detailK, self.detailKStatus,
        info.potassium.value, info.potassium.status, "%", ct and ct.K)

    -- pH (0-14 scale, not %)
    if self.detailPH then
        self.detailPH:setText(string.format("%.2f", info.pH or 7.0))
    end
    if self.detailPHStatus then
        local ph = info.pH or 7.0
        local phStatus, phColor
        if ph >= 6.5 and ph <= 7.0 then
            phStatus = tr("sf_pda_status_good",  "Good")
            phColor  = COLOR_GOOD
        elseif ph >= 6.0 and ph < 7.5 then
            phStatus = tr("sf_pda_status_fair",  "Fair")
            phColor  = COLOR_FAIR
        else
            phStatus = tr("sf_pda_status_poor",  "Poor")
            phColor  = COLOR_POOR
        end
        self.detailPHStatus:setText(phStatus)
        self.detailPHStatus:setTextColor(unpack(phColor))
    end

    -- Organic Matter
    if self.detailOM then
        self.detailOM:setText(string.format("%.1f", info.organicMatter or 3.5))
    end
    if self.detailOMStatus then
        local om = info.organicMatter or 3.5
        local omStatus, omColor
        if om >= 4.0 then
            omStatus = tr("sf_pda_status_good", "Good")
            omColor  = COLOR_GOOD
        elseif om >= 2.5 then
            omStatus = tr("sf_pda_status_fair", "Fair")
            omColor  = COLOR_FAIR
        else
            omStatus = tr("sf_pda_status_poor", "Poor")
            omColor  = COLOR_POOR
        end
        self.detailOMStatus:setText(omStatus)
        self.detailOMStatus:setTextColor(unpack(omColor))
    end

    -- Crop pressure
    self:_setPressure(self.detailWeed,    self.detailWeedStatus,    info.weedPressure    or 0, info.herbicideActive)
    self:_setPressure(self.detailPest,    self.detailPestStatus,    info.pestPressure    or 0, info.insecticideActive)
    self:_setPressure(self.detailDisease, self.detailDiseaseStatus, info.diseasePressure or 0, info.fungicideActive)

    -- History
    if self.detailLastCrop then
        local cropName = info.lastCrop
        if cropName == nil or cropName == "" then
            cropName = tr("sf_detail_no_crop", "None recorded")
        end
        self.detailLastCrop:setText(cropName)
    end

    if self.detailRotation then
        local rotStatus = info.rotationStatus
        local rotText, rotColor
        if rotStatus == "Bonus" then
            rotText  = tr("sf_detail_rotation_bonus",   "Legume Bonus (+N)")
            rotColor = COLOR_GOOD
        elseif rotStatus == "Fatigue" then
            rotText  = tr("sf_detail_rotation_fatigue", "Fatigue (×1.15 depletion)")
            rotColor = COLOR_POOR
        else
            rotText  = tr("sf_detail_rotation_ok",      "OK")
            rotColor = COLOR_DIM
        end
        self.detailRotation:setText(rotText)
        self.detailRotation:setTextColor(unpack(rotColor))
    end
end

---@param valueEl    table|nil
---@param statusEl   table|nil
---@param value      number    0-100
---@param statusStr  string    "Good"|"Fair"|"Poor"
---@param suffix     string    "%" or ""
---@param cropTarget table|nil {min=number, opt=number} per-crop target (internal scale)
function SoilFieldDetailDialog:_setNutrient(valueEl, statusEl, value, statusStr, suffix, cropTarget)
    local COLOR_POOR, COLOR_FAIR, COLOR_GOOD = getStatusColors()
    suffix = suffix or ""
    if valueEl then
        valueEl:setText(math.floor(value + 0.5) .. suffix)
    end
    if statusEl then
        local label, color
        if cropTarget then
            -- Colour by crop-specific target rather than global thresholds
            if value >= cropTarget.opt then
                label = tr("sf_pda_status_good", "Good")
                color = COLOR_GOOD
            elseif value >= cropTarget.min then
                label = tr("sf_pda_status_fair", "Fair")
                color = COLOR_FAIR
            else
                label = tr("sf_pda_status_poor", "Poor")
                color = COLOR_POOR
            end
            -- Append crop-optimal hint so the player knows the target
            label = label .. " (" .. tostring(cropTarget.opt) .. ")"
        else
            -- No crop planted: use global status from getFieldInfo
            local s = statusStr and statusStr:lower() or "poor"
            if s == "good" then
                label = tr("sf_pda_status_good", "Good")
                color = COLOR_GOOD
            elseif s == "fair" then
                label = tr("sf_pda_status_fair", "Fair")
                color = COLOR_FAIR
            else
                label = tr("sf_pda_status_poor", "Poor")
                color = COLOR_POOR
            end
        end
        statusEl:setText(label)
        statusEl:setTextColor(unpack(color))
    end
end

---@param valueEl       table|nil
---@param statusEl      table|nil
---@param pressure      number    0-100
---@param activeProduct boolean   true if protection product active
function SoilFieldDetailDialog:_setPressure(valueEl, statusEl, pressure, activeProduct)
    local COLOR_POOR, COLOR_FAIR, COLOR_GOOD = getStatusColors()
    if valueEl then
        valueEl:setText(string.format("%.0f%%", pressure))
    end
    if statusEl then
        local label, color
        if pressure < 20 then
            label = tr("sf_pda_status_good", "Good")
            color = COLOR_GOOD
        elseif pressure < 50 then
            label = tr("sf_pda_status_fair", "Fair")
            color = COLOR_FAIR
        else
            label = tr("sf_pda_status_poor", "High")
            color = COLOR_POOR
        end
        -- If a protection product is active, add a note
        if activeProduct and pressure > 0 then
            label = label .. " *"
        end
        statusEl:setText(label)
        statusEl:setTextColor(unpack(color))
    end
end

function SoilFieldDetailDialog:_showNoData()
    if self.detailNoData then self.detailNoData:setVisible(true) end
    if self.detailFieldId then
        self.detailFieldId:setText(tr("sf_detail_no_field", "No data available."))
    end
    -- Clear urgency
    if self.detailUrgency then self.detailUrgency:setText("--") end
    -- Clear all value/status cells
    local function clear(a, b)
        if a then a:setText("--") end
        if b then b:setText("") end
    end
    clear(self.detailN,       self.detailNStatus)
    clear(self.detailP,       self.detailPStatus)
    clear(self.detailK,       self.detailKStatus)
    clear(self.detailPH,      self.detailPHStatus)
    clear(self.detailOM,      self.detailOMStatus)
    clear(self.detailWeed,    self.detailWeedStatus)
    clear(self.detailPest,    self.detailPestStatus)
    clear(self.detailDisease, self.detailDiseaseStatus)
    if self.detailLastCrop then self.detailLastCrop:setText("--") end
    if self.detailRotation  then self.detailRotation:setText("--") end
end
