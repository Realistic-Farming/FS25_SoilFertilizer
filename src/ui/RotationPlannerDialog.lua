-- =========================================================
-- Rotation Planner Dialog (in-game menu surface, Wizard #739)
-- =========================================================
-- Farm-wide summary + per-field what-if compare. Same engine as
-- FarmTablet Rotation Planner and field-detail foresight.
-- Opened from Soil PDA footer (MENU_EXTRA_2).
-- =========================================================

---@class RotationPlannerDialog
RotationPlannerDialog = {}
local RotationPlannerDialog_mt = Class(RotationPlannerDialog, ScreenElement)

local SF_RP_MOD_DIR = g_currentModDirectory
RotationPlannerDialog.INSTANCE = nil
RotationPlannerDialog.xmlPath = nil

local function tr(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        local t = g_i18n:getText(key)
        if t ~= nil and t ~= "" then return t end
    end
    return fallback or key
end

function RotationPlannerDialog.new()
    local self = setmetatable({}, RotationPlannerDialog_mt)
    self._fieldIds = {}
    self._index = 1
    return self
end

function RotationPlannerDialog.register(modDirectory)
    if RotationPlannerDialog.INSTANCE ~= nil then return end
    SF_RP_MOD_DIR = modDirectory
    RotationPlannerDialog.xmlPath = modDirectory .. "xml/gui/RotationPlannerDialog.xml"
    RotationPlannerDialog.INSTANCE = RotationPlannerDialog.new()
    local ok, err = pcall(function()
        g_gui:loadGui(
            RotationPlannerDialog.xmlPath,
            "RotationPlannerDialog",
            RotationPlannerDialog.INSTANCE
        )
    end)
    if not ok then
        SoilLogger.error("RotationPlannerDialog: loadGui failed: %s", tostring(err))
        RotationPlannerDialog.INSTANCE = nil
    else
        SoilLogger.info("RotationPlannerDialog: registered")
    end
end

function RotationPlannerDialog.show(startFieldId)
    if RotationPlannerDialog.INSTANCE == nil then
        RotationPlannerDialog.register(SF_RP_MOD_DIR)
    end
    local inst = RotationPlannerDialog.INSTANCE
    if inst == nil then return end
    inst._startFieldId = startFieldId
    if g_gui:getIsGuiVisible() then
        g_gui:showDialog("RotationPlannerDialog")
    else
        g_gui:showGui("RotationPlannerDialog")
    end
end

function RotationPlannerDialog:onGuiSetupFinished()
    RotationPlannerDialog:superClass().onGuiSetupFinished(self)
    self.rpTitle = self:getDescendantById("rpTitle")
    self.rpFarmSummary = self:getDescendantById("rpFarmSummary")
    self.rpFieldHeader = self:getDescendantById("rpFieldHeader")
    self.rpStanding = self:getDescendantById("rpStanding")
    self.rpHint = self:getDescendantById("rpHint")
    self.rpCandCrop = {
        self:getDescendantById("rpCand1Crop"),
        self:getDescendantById("rpCand2Crop"),
        self:getDescendantById("rpCand3Crop"),
    }
    self.rpCandStatus = {
        self:getDescendantById("rpCand1Status"),
        self:getDescendantById("rpCand2Status"),
        self:getDescendantById("rpCand3Status"),
    }
    self.rpCandEffect = {
        self:getDescendantById("rpCand1Effect"),
        self:getDescendantById("rpCand2Effect"),
        self:getDescendantById("rpCand3Effect"),
    }
end

function RotationPlannerDialog:onOpen()
    RotationPlannerDialog:superClass().onOpen(self)
    self:_rebuildFieldList()
    if self._startFieldId ~= nil then
        for i, id in ipairs(self._fieldIds) do
            if id == self._startFieldId then self._index = i break end
        end
    end
    self.menuButtonInfo = {
        { inputAction = "MENU_BACK", callback = function() self:onClickBack() end },
        { inputAction = "MENU_PAGE_PREV", text = tr("sf_rp_prev", "Prev field"),
          callback = function() self:_step(-1) end },
        { inputAction = "MENU_PAGE_NEXT", text = tr("sf_rp_next", "Next field"),
          callback = function() self:_step(1) end },
    }
    self:setMenuButtonInfo(self.menuButtonInfo)
    self:_refresh()
end

function RotationPlannerDialog:onClickBack()
    g_gui:closeDialogByName("RotationPlannerDialog")
end

function RotationPlannerDialog:_step(delta)
    if #self._fieldIds == 0 then return end
    self._index = self._index + delta
    if self._index < 1 then self._index = #self._fieldIds end
    if self._index > #self._fieldIds then self._index = 1 end
    self:_refresh()
end

function RotationPlannerDialog:_rebuildFieldList()
    self._fieldIds = {}
    local sfm = g_SoilFertilityManager or (g_currentMission and g_currentMission.soilFertilityManager)
    local soil = sfm and sfm.soilSystem
    if soil == nil or soil.fieldData == nil then return end
    for fieldId, _ in pairs(soil.fieldData) do
        if type(fieldId) == "number" and fieldId > 0 then
            self._fieldIds[#self._fieldIds + 1] = fieldId
        end
    end
    table.sort(self._fieldIds)
    if self._index < 1 or self._index > #self._fieldIds then self._index = 1 end
end

function RotationPlannerDialog:_refresh()
    if RotationPlannerData == nil then return end
    local ids = self._fieldIds
    local cache = RotationPlannerData.cacheForFields(ids)

    local bonusN, fatigueN, okN, unknownN = 0, 0, 0, 0
    for _, id in ipairs(ids) do
        local info = cache.byId[id]
        local _, kind = RotationPlannerData.standingLine(info)
        if kind == "bonus" then bonusN = bonusN + 1
        elseif kind == "fatigue" then fatigueN = fatigueN + 1
        elseif kind == "ok" then okN = okN + 1
        else unknownN = unknownN + 1 end
    end
    if self.rpFarmSummary then
        self.rpFarmSummary:setText(string.format(
            tr("sf_rp_farm_summary", "%d fields · Bonus %d · OK %d · Fatigue %d · Unknown %d"),
            #ids, bonusN, okN, fatigueN, unknownN
        ))
    end

    local fieldId = ids[self._index]
    if fieldId == nil then
        if self.rpFieldHeader then self.rpFieldHeader:setText(tr("sf_rp_no_fields", "No fields")) end
        if self.rpStanding then self.rpStanding:setText("") end
        for i = 1, 3 do
            if self.rpCandCrop[i] then self.rpCandCrop[i]:setText("") end
            if self.rpCandStatus[i] then self.rpCandStatus[i]:setText("") end
            if self.rpCandEffect[i] then self.rpCandEffect[i]:setText("") end
        end
        return
    end

    if self.rpFieldHeader then
        self.rpFieldHeader:setText(string.format(
            tr("sf_rp_field_header", "Field #%d  (%d / %d)"),
            fieldId, self._index, #ids
        ))
    end

    local info = cache.byId[fieldId]
    local line = RotationPlannerData.standingLine(info)
    if self.rpStanding then self.rpStanding:setText(line) end

    local current = info and info.lastCrop
    if current == nil or current == "" then
        for i = 1, 3 do
            if self.rpCandCrop[i] then self.rpCandCrop[i]:setText("") end
            if self.rpCandStatus[i] then self.rpCandStatus[i]:setText("") end
            if self.rpCandEffect[i] then self.rpCandEffect[i]:setText("") end
        end
        if self.rpHint then
            self.rpHint:setText(tr("sf_rp_hint_no_history",
                "No crop history yet on this field. Grow a crop before comparing."))
        end
        return
    end

    if self.rpHint then
        self.rpHint:setText(tr("sf_rp_hint",
            "Same candidates as the field-detail foresight. Read-only; nothing is planted."))
    end

    local candidates = RotationPlannerData.pickCandidates(current, cache and cache.soil)
    for i = 1, 3 do
        local cand = candidates[i]
        if cand == nil then
            if self.rpCandCrop[i] then self.rpCandCrop[i]:setText("") end
            if self.rpCandStatus[i] then self.rpCandStatus[i]:setText("") end
            if self.rpCandEffect[i] then self.rpCandEffect[i]:setText("") end
        else
            local proj = RotationPlannerData.project(cache, fieldId, cand)
            local word = RotationPlannerData.statusWord(proj and proj.status)
            if self.rpCandCrop[i] then
                self.rpCandCrop[i]:setText(RotationPlannerData.cropLabel(cand))
            end
            if self.rpCandStatus[i] then self.rpCandStatus[i]:setText(word) end
            if self.rpCandEffect[i] then
                self.rpCandEffect[i]:setText(RotationPlannerData.effectText(proj))
            end
        end
    end
end
