-- =========================================================
-- FS25 Realistic Soil & Fertilizer (Soil Report Dialog)
-- =========================================================
-- Full-farm soil report: paginated table of all tracked fields
-- with color-coded N/P/K/pH/OM/Weed/Pest values.
-- Press K to open (SF_SOIL_REPORT action).
-- ► button on any row opens the field detail view.
-- =========================================================
-- Author: TisonK
-- =========================================================

SoilReportDialog = {}
local SoilReportDialog_mt = Class(SoilReportDialog, ScreenElement)

-- Capture mod name at load time — g_currentModName is only valid during loading.
local SF_MOD_NAME = g_currentModName

-- Resolve a translation key using the mod-scoped i18n instance.
local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

SoilReportDialog.MAX_ROWS = 10
SoilReportDialog.instance = nil
SoilReportDialog.xmlPath = nil

-- Status colors (static; only used as fallbacks — see getStatusColors() for runtime palette)
SoilReportDialog.COLOR_GOOD  = {0.25, 0.85, 0.25, 1.0}
SoilReportDialog.COLOR_FAIR  = {0.90, 0.82, 0.18, 1.0}
SoilReportDialog.COLOR_POOR  = {0.88, 0.25, 0.25, 1.0}
SoilReportDialog.COLOR_WHITE = {1.00, 1.00, 1.00, 1.0}
SoilReportDialog.COLOR_DIM   = {0.60, 0.60, 0.60, 1.0}

local function getStatusColors()
    local cb = g_SoilFertilityManager and g_SoilFertilityManager.settings and g_SoilFertilityManager.settings.colorblindMode
    if cb then
        return {0.90, 0.37, 0.00, 1.0}, {0.94, 0.86, 0.00, 1.0}, {0.00, 0.45, 0.70, 1.0}
    end
    return SoilReportDialog.COLOR_POOR, SoilReportDialog.COLOR_FAIR, SoilReportDialog.COLOR_GOOD
end

function SoilReportDialog.getInstance(modDirectory)
    if SoilReportDialog.instance == nil then
        if SoilReportDialog.xmlPath == nil then
            SoilReportDialog.xmlPath = modDirectory .. "gui/SoilReportDialog.xml"
        end

        SoilReportDialog.instance = SoilReportDialog.new()
        g_gui:loadGui(SoilReportDialog.xmlPath, "SoilReportDialog", SoilReportDialog.instance)
    end

    return SoilReportDialog.instance
end

function SoilReportDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilReportDialog_mt)

    self.fieldInfos = {}
    self.sortedFieldIds = {}
    self.currentPage = 1
    self.totalPages = 1
    self.fieldRows = {}
    self.isBackAllowed = true
    self.detailMode = false
    self.detailFieldId = nil

    return self
end

function SoilReportDialog:onCreate()
    -- Cache table row elements (now includes weed, pest, stat, and detail btn)
    for i = 0, SoilReportDialog.MAX_ROWS - 1 do
        local rowId = "fieldRow" .. i
        self.fieldRows[i] = {
            row    = self[rowId],
            bg     = self[rowId .. "Bg"],
            id     = self[rowId .. "Id"],
            n      = self[rowId .. "N"],
            p      = self[rowId .. "P"],
            k      = self[rowId .. "K"],
            ph     = self[rowId .. "pH"],
            om     = self[rowId .. "OM"],
            weed   = self[rowId .. "Weed"],
            pest   = self[rowId .. "Pest"],
            crop   = self[rowId .. "Crop"],
            stat   = self[rowId .. "Stat"],
        }
    end
end

--- Show dialog with current soil data.
function SoilReportDialog:show()
    if g_gui.currentGui ~= nil then return end

    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then
        SoilLogger.warning("[SoilReport] Soil system not available")
        return
    end

    self.currentPage = 1
    self.detailMode = false
    self.detailFieldId = nil

    local ready = self:collectFieldData()
    if not ready then
        self:showSyncingState()
        g_gui:showDialog("SoilReportDialog")
        self:startOwnershipSyncRetry()
        return
    end

    self:updateDisplay()
    g_gui:showDialog("SoilReportDialog")
end

--- Put the dialog into a "waiting for sync" visual state.
function SoilReportDialog:showSyncingState()
    self.sortedFieldIds = {}
    self.fieldInfos = {}
    self.totalPages = 1
    self:updateDisplay()

    if self.noDataText then
        self.noDataText:setText(tr("sf_ui_soilReport_syncing", "Syncing field ownership data, please wait..."))
        self.noDataText:setVisible(true)
    end
end

--- Start an AsyncRetryHandler that re-runs collectFieldData() until ownership
--- has synced, then refreshes the display. Retries every 2s for up to 30s.
function SoilReportDialog:startOwnershipSyncRetry()
    if self.ownershipRetry then
        self.ownershipRetry:reset()
    end

    local dialog = self

    self.ownershipRetry = AsyncRetryHandler.new({
        name        = "SoilReport.OwnershipSync",
        maxAttempts = 15,
        delays      = {2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000},
        condition   = function()
            local ready = dialog:collectFieldData()
            return ready
        end,
        onAttempt   = function() end,
        onSuccess   = function()
            SoilLogger.info("[SoilReport] Ownership synced, refreshing dialog")
            if g_gui.currentGui and g_gui.currentGui.name == "SoilReportDialog" then
                dialog:updateDisplay()
            end
        end,
        onFailure   = function()
            SoilLogger.warning("[SoilReport] Ownership sync timed out after retries")
            if dialog.noDataText then
                dialog.noDataText:setText(tr("sf_ui_soilReport_syncTimeout",
                    "Could not load field ownership. Please close and reopen the report."))
                dialog.noDataText:setVisible(true)
            end
        end,
    })

    self.ownershipRetry:start()
end

--- Get the local player's farm ID.
---@return number
local function getLocalFarmId()
    if g_localPlayer and g_localPlayer.farmId and g_localPlayer.farmId > 0 then
        return g_localPlayer.farmId
    end

    if g_currentMission and g_currentMission.player then
        local id = g_currentMission.player.farmId
        if id and id > 0 then return id end
    end

    if g_currentMission and g_currentMission.userManager and g_currentMission.playerUserId then
        local user = g_currentMission.userManager:getUserByUserId(g_currentMission.playerUserId)
        if user and user.farmId and user.farmId > 0 then return user.farmId end
    end

    return 1
end

---@param farmlandId number
---@param localFarmId number
---@return boolean
local function isFarmlandOwnedByFarm(farmlandId, localFarmId)
    if not g_farmlandManager then return false end
    return g_farmlandManager:getFarmlandOwner(farmlandId) == localFarmId
end

---@param localFarmId number
---@return boolean
local function isOwnershipSynced(localFarmId)
    if not g_farmlandManager then return false end

    local farmlands = g_farmlandManager:getFarmlands()
    if not farmlands or next(farmlands) == nil then return false end

    if not (g_currentMission and g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isMultiplayer) or g_currentMission:getIsServer() then
        return true
    end

    local ownedIds = g_farmlandManager:getOwnedFarmlandIdsByFarmId(localFarmId)
    if ownedIds and #ownedIds > 0 then return true end

    for id, _ in pairs(farmlands) do
        if g_farmlandManager:getFarmlandOwner(id) ~= 0 then return true end
    end

    if g_currentMission.missionDynamicInfo and g_currentMission.missionDynamicInfo.isStarted then
        return true
    end
    if g_currentMission.hud ~= nil then return true end

    return false
end

---@return boolean ready
function SoilReportDialog:collectFieldData()
    self.fieldInfos = {}
    self.sortedFieldIds = {}

    local soilSystem = g_SoilFertilityManager.soilSystem
    if not soilSystem or not soilSystem.fieldData then return true end

    local localFarmId = getLocalFarmId()

    if not isOwnershipSynced(localFarmId) then
        SoilLogger.warning("[SoilReport] Ownership data not yet synced for farmId %s - will retry", tostring(localFarmId))
        return false
    end

    local filtered = {}
    for fieldId, _ in pairs(soilSystem.fieldData) do
        if isFarmlandOwnedByFarm(fieldId, localFarmId) then
            table.insert(filtered, fieldId)
        end
    end

    self.sortedFieldIds = filtered

    table.sort(self.sortedFieldIds, function(a, b)
        local urgencyA = soilSystem:getFieldUrgency(a)
        local urgencyB = soilSystem:getFieldUrgency(b)
        if math.abs(urgencyA - urgencyB) < 0.1 then return a < b end
        return urgencyA > urgencyB
    end)

    for _, fieldId in ipairs(self.sortedFieldIds) do
        local info = soilSystem:getFieldInfo(fieldId)
        if info then
            self.fieldInfos[fieldId] = info
        else
            SoilLogger.warning("[SoilReport] getFieldInfo returned nil for field %s", tostring(fieldId))
        end
    end

    self.totalPages = math.ceil(#self.sortedFieldIds / SoilReportDialog.MAX_ROWS)
    if self.totalPages < 1 then self.totalPages = 1 end

    return true
end

-- ── Status color helpers ──────────────────────────────────────────────

local function getStatusColor(status)
    local poor, fair, good = getStatusColors()
    if status == "Good" then return good
    elseif status == "Fair" then return fair
    elseif status == "Poor" then return poor
    end
    return SoilReportDialog.COLOR_WHITE
end

local function getPHColor(ph)
    local rc = SoilConstants.REPORT_COLORS
    local poor, fair, good = getStatusColors()
    if ph >= rc.PH_GOOD_LOW and ph <= rc.PH_GOOD_HIGH then return good
    elseif ph >= rc.PH_FAIR_LOW and ph <= rc.PH_FAIR_HIGH then return fair
    end
    return poor
end

local function getOMColor(om)
    local rc = SoilConstants.REPORT_COLORS
    local poor, fair, good = getStatusColors()
    if om >= rc.OM_GOOD then return good
    elseif om >= rc.OM_FAIR then return fair
    end
    return poor
end

local function getPressureColor(pct)
    local wp = SoilConstants.WEED_PRESSURE
    local poor, fair, good = getStatusColors()
    if pct < wp.LOW    then return good
    elseif pct < wp.MEDIUM then return fair
    else return poor end
end

-- ── Overall status helpers ────────────────────────────────────────────

--- Compute the overall field status (worst of N/P/K/pH/OM/weed/pest/disease).
---@param info table
---@return string "Good"|"Fair"|"Poor"
---@return table color RGBA
local function getOverallStatus(info)
    local rc = SoilConstants.REPORT_COLORS
    local wp = SoilConstants.WEED_PRESSURE
    local worst = 1
    -- N / P / K (status strings)
    for _, key in ipairs({"nitrogen", "phosphorus", "potassium"}) do
        local s = info[key].status
        local r = (s == "Poor") and 3 or (s == "Fair") and 2 or 1
        if r > worst then worst = r end
    end
    -- pH (threshold-based)
    if info.pH then
        local ph = info.pH
        local r = (ph >= rc.PH_GOOD_LOW and ph <= rc.PH_GOOD_HIGH) and 1
               or (ph >= rc.PH_FAIR_LOW and ph <= rc.PH_FAIR_HIGH) and 2
               or 3
        if r > worst then worst = r end
    end
    -- OM (threshold-based)
    if info.organicMatter then
        local om = info.organicMatter
        local r = (om >= rc.OM_GOOD) and 1 or (om >= rc.OM_FAIR) and 2 or 3
        if r > worst then worst = r end
    end
    -- Weed / pest / disease pressures (stored as 0-100)
    for _, key in ipairs({"weedPressure", "pestPressure", "diseasePressure"}) do
        local val = info[key]
        if val and val > 0 then
            local pct = math.floor(val + 0.5)
            local r = (pct >= wp.MEDIUM) and 3 or (pct >= wp.LOW) and 2 or 1
            if r > worst then worst = r end
        end
    end
    local poor, fair, good = getStatusColors()
    if worst == 3 then return "Poor", poor
    elseif worst == 2 then return "Fair", fair
    else return "Good", good end
end

--- Compute average farm health across all owned fields.
---@return string label e.g. "Good (82%)"
---@return table color RGBA
function SoilReportDialog:computeFarmHealth()
    local total = #self.sortedFieldIds
    if total == 0 then return "--", SoilReportDialog.COLOR_DIM end

    local scoreSum = 0
    for _, fieldId in ipairs(self.sortedFieldIds) do
        local info = self.fieldInfos[fieldId]
        if info then
            local status, _ = getOverallStatus(info)
            if status == "Good" then scoreSum = scoreSum + 100
            elseif status == "Fair" then scoreSum = scoreSum + 50
            else scoreSum = scoreSum + 0 end
        end
    end

    local avg = scoreSum / total
    local label, color
    if avg >= 75 then
        label = string.format("%s (%d%%)", tr("sf_report_rec_good", "Good"), math.floor(avg + 0.5))
        color = SoilReportDialog.COLOR_GOOD
    elseif avg >= 40 then
        label = string.format("%s (%d%%)", tr("sf_report_rec_fair", "Fair"), math.floor(avg + 0.5))
        color = SoilReportDialog.COLOR_FAIR
    else
        label = string.format("%s (%d%%)", tr("sf_report_rec_poor", "Poor"), math.floor(avg + 0.5))
        color = SoilReportDialog.COLOR_POOR
    end
    return label, color
end

-- ── Display update ────────────────────────────────────────────────────

function SoilReportDialog:updateDisplay()
    local totalFields = #self.sortedFieldIds
    local needFertCount = 0
    for _, info in pairs(self.fieldInfos) do
        if info.needsFertilization then needFertCount = needFertCount + 1 end
    end

    if self.fieldCountText then
        self.fieldCountText:setText(tostring(totalFields))
    end
    if self.needFertText then
        self.needFertText:setText(tostring(needFertCount))
        if needFertCount > 0 then
            self.needFertText:setTextColor(1, 0.4, 0.4, 1)
        else
            self.needFertText:setTextColor(0.3, 1, 0.3, 1)
        end
    end
    if self.difficultyText and g_SoilFertilityManager.settings then
        self.difficultyText:setText(g_SoilFertilityManager.settings:getDifficultyName())
    end
    if self.farmHealthText then
        local healthLabel, healthColor = self:computeFarmHealth()
        self.farmHealthText:setText(healthLabel)
        self.farmHealthText:setTextColor(healthColor[1], healthColor[2], healthColor[3], healthColor[4])
    end

    local hasData = totalFields > 0
    if self.noDataText then
        self.noDataText:setVisible(not hasData and not self.detailMode)
    end

    self:setDetailMode(self.detailMode)
    if self.detailMode and self.detailFieldId then
        self:updateDetailView(self.detailFieldId)
    else
        self:updateFieldRows()
        self:updatePagination()
    end
end

--- Show/hide the correct panel and buttons based on mode.
function SoilReportDialog:setDetailMode(isDetail)
    self.detailMode = isDetail

    if self.tableView  then self.tableView:setVisible(not isDetail) end
    if self.detailView then self.detailView:setVisible(isDetail) end

    if self.prevButton then self.prevButton:setVisible(not isDetail) end
    if self.nextButton then self.nextButton:setVisible(not isDetail) end
    if self.backButton then self.backButton:setVisible(isDetail) end
    if self.backSep    then self.backSep:setVisible(isDetail) end
end

--- Set text and color on a text element
local function setColoredText(element, text, color)
    if element then
        element:setText(text)
        element:setTextColor(color[1], color[2], color[3], color[4])
    end
end

-- ── Table rows ────────────────────────────────────────────────────────

function SoilReportDialog:getFertilizationRecommendation(info)
    local recommendations = {}
    local overallStatus = "Good"

    if info.nitrogen.status == "Poor" then
        table.insert(recommendations, tr("sf_report_rec_n_poor", "N (Poor)"))
        overallStatus = "Poor"
    elseif info.nitrogen.status == "Fair" then
        table.insert(recommendations, tr("sf_report_rec_n_fair", "N (Fair)"))
        if overallStatus == "Good" then overallStatus = "Fair" end
    end

    if info.phosphorus.status == "Poor" then
        table.insert(recommendations, tr("sf_report_rec_p_poor", "P (Poor)"))
        overallStatus = "Poor"
    elseif info.phosphorus.status == "Fair" then
        table.insert(recommendations, tr("sf_report_rec_p_fair", "P (Fair)"))
        if overallStatus == "Good" then overallStatus = "Fair" end
    end

    if info.potassium.status == "Poor" then
        table.insert(recommendations, tr("sf_report_rec_k_poor", "K (Poor)"))
        overallStatus = "Poor"
    elseif info.potassium.status == "Fair" then
        table.insert(recommendations, tr("sf_report_rec_k_fair", "K (Fair)"))
        if overallStatus == "Good" then overallStatus = "Fair" end
    end

    local phColor = getPHColor(info.pH)
    if phColor == SoilReportDialog.COLOR_POOR then
        table.insert(recommendations, tr("sf_report_rec_ph_adjust", "Adjust pH"))
        overallStatus = "Poor"
    elseif phColor == SoilReportDialog.COLOR_FAIR then
        table.insert(recommendations, tr("sf_report_rec_ph_monitor", "Monitor pH"))
        if overallStatus == "Good" then overallStatus = "Fair" end
    end

    local omColor = getOMColor(info.organicMatter)
    if omColor == SoilReportDialog.COLOR_POOR then
        table.insert(recommendations, tr("sf_report_rec_om_increase", "Increase OM"))
        overallStatus = "Poor"
    elseif omColor == SoilReportDialog.COLOR_FAIR then
        table.insert(recommendations, tr("sf_report_rec_om_maintain", "Maintain OM"))
        if overallStatus == "Good" then overallStatus = "Fair" end
    end

    if info.pestPressure and info.pestPressure >= SoilConstants.PEST_PRESSURE.MEDIUM then
        table.insert(recommendations, tr("sf_report_rec_pest", "Pest Risk"))
        overallStatus = "Poor"
    end

    if info.diseasePressure and info.diseasePressure >= SoilConstants.DISEASE_PRESSURE.MEDIUM then
        table.insert(recommendations, tr("sf_report_rec_disease", "Disease Risk"))
        overallStatus = "Poor"
    end

    -- Crop rotation status
    if SoilConstants.CROP_ROTATION
       and g_SoilFertilityManager and g_SoilFertilityManager.settings
       and g_SoilFertilityManager.settings.cropRotation then
        local cr = SoilConstants.CROP_ROTATION
        local crop  = info.lastCrop  and string.lower(info.lastCrop)  or nil
        local crop2 = info.lastCrop2 and string.lower(info.lastCrop2) or nil
        if crop and crop2 then
            if cr.LEGUMES[crop] and not cr.LEGUMES[crop2] then
                table.insert(recommendations, tr("sf_report_rotation_bonus", "Rotation Bonus"))
            elseif info.lastCrop == info.lastCrop2 then
                table.insert(recommendations, tr("sf_report_rotation_fatigue", "Fatigue: Same Crop"))
                if overallStatus == "Good" then overallStatus = "Fair" end
            else
                table.insert(recommendations, tr("sf_report_rotation_ok", "Rotation: OK"))
            end
        end
    end

    -- Yield penalty entry (added directly to recommendations list)
    local ys = SoilConstants.YIELD_SENSITIVITY
    if ys then
        local cropLower = info.lastCrop and string.lower(info.lastCrop) or nil
        if not (cropLower and ys.NON_CROP_NAMES and ys.NON_CROP_NAMES[cropLower]) then
            local tier     = (cropLower and ys.CROP_TIERS and ys.CROP_TIERS[cropLower]) or ys.DEFAULT_TIER
            local tierData = ys.TIERS and ys.TIERS[tier]
            local thresh   = ys.OPTIMAL_THRESHOLD or 70
            if tierData then
                local nDef       = math.max(0, thresh - info.nitrogen.value)   / thresh
                local pDef       = math.max(0, thresh - info.phosphorus.value) / thresh
                local kDef       = math.max(0, thresh - info.potassium.value)  / thresh
                local penalty    = math.min(ys.MAX_PENALTY, (nDef + pDef + kDef) / 3 * tierData.scale)
                local penaltyPct = math.floor(penalty * 100 + 0.5)
                if penaltyPct > 0 then
                    table.insert(recommendations, string.format(tr("sf_report_yield_loss", "Yield ~-%d%%"), penaltyPct))
                    if overallStatus == "Good" then overallStatus = "Fair" end
                end
            end
        end
    end

    local recStr, recColor
    if #recommendations > 0 then
        -- Format as bulleted grid, 3 items per line
        local lines = {}
        local currentLine = {}
        for _, rec in ipairs(recommendations) do
            table.insert(currentLine, "- " .. rec)
            if #currentLine >= 3 then
                table.insert(lines, table.concat(currentLine, "   "))
                currentLine = {}
            end
        end
        if #currentLine > 0 then
            table.insert(lines, table.concat(currentLine, "   "))
        end
        recStr   = table.concat(lines, "\n")
        recColor = (overallStatus == "Poor") and SoilReportDialog.COLOR_POOR or SoilReportDialog.COLOR_FAIR
    else
        recStr   = tr("sf_report_rec_optimal", "Soil Health: Optimal")
        recColor = SoilReportDialog.COLOR_GOOD
    end

    return recStr, recColor, overallStatus
end

function SoilReportDialog:updateFieldRows()
    local startIndex = (self.currentPage - 1) * SoilReportDialog.MAX_ROWS + 1
    local ppm = SoilConstants.PPM_DISPLAY or { N = 1, P = 1, K = 1 }

    for i = 0, SoilReportDialog.MAX_ROWS - 1 do
        local dataIndex = startIndex + i
        local row = self.fieldRows[i]

        if row and row.row then
            if dataIndex <= #self.sortedFieldIds then
                local fieldId = self.sortedFieldIds[dataIndex]
                local info    = self.fieldInfos[fieldId]

                row.row:setVisible(true)

                if info then
                    -- Field ID
                    if row.id then row.id:setText(tostring(fieldId)) end

                    -- N / P / K (ppm, color-coded)
                    setColoredText(row.n, tostring(math.floor(info.nitrogen.value   * ppm.N + 0.5)), getStatusColor(info.nitrogen.status))
                    setColoredText(row.p, tostring(math.floor(info.phosphorus.value * ppm.P + 0.5)), getStatusColor(info.phosphorus.status))
                    setColoredText(row.k, tostring(math.floor(info.potassium.value  * ppm.K + 0.5)), getStatusColor(info.potassium.status))

                    -- pH
                    setColoredText(row.ph, string.format("%.1f", info.pH), getPHColor(info.pH))

                    -- Organic Matter
                    setColoredText(row.om, string.format("%.1f", info.organicMatter), getOMColor(info.organicMatter))

                    -- Weed pressure (stored as 0-100)
                    if row.weed then
                        local wp = math.floor((info.weedPressure or 0) + 0.5)
                        setColoredText(row.weed, string.format("%d%%", wp), getPressureColor(wp))
                    end

                    -- Pest pressure (stored as 0-100)
                    if row.pest then
                        local pp = math.floor((info.pestPressure or 0) + 0.5)
                        setColoredText(row.pest, string.format("%d%%", pp), getPressureColor(pp))
                    end

                    -- Last Crop
                    if row.crop then
                        local noneText = tr("sf_report_none", "None")
                        local cropName = info.lastCrop or noneText
                        if cropName ~= noneText and cropName ~= "" then
                            cropName = cropName:sub(1,1):upper() .. cropName:sub(2)
                        end
                        row.crop:setText(cropName)
                        row.crop:setTextColor(0.7, 0.7, 0.7, 1)
                    end

                    -- Overall status badge
                    if row.stat then
                        local status, statColor = getOverallStatus(info)
                        setColoredText(row.stat, tr("sf_report_rec_" .. status:lower(), status), statColor)
                    end

                    -- Row background tint
                    if row.bg then
                        if info.needsFertilization then
                            row.bg:setImageColor(nil, 0.18, 0.10, 0.10, 1)
                        elseif i % 2 == 0 then
                            row.bg:setImageColor(nil, 0.10, 0.10, 0.10, 1)
                        else
                            row.bg:setImageColor(nil, 0.12, 0.12, 0.14, 1)
                        end
                    end
                end
            else
                row.row:setVisible(false)
            end
        end
    end
end

-- ── Pagination ────────────────────────────────────────────────────────

function SoilReportDialog:updatePagination()
    local totalFields = #self.sortedFieldIds

    if totalFields > 0 then
        local startIndex = (self.currentPage - 1) * SoilReportDialog.MAX_ROWS + 1
        local endIndex   = math.min(startIndex + SoilReportDialog.MAX_ROWS - 1, totalFields)

        if self.pageInfoText then
            local pageFmt = tr("sf_report_page_info", "Fields %d-%d of %d  |  Page %d of %d")
            self.pageInfoText:setText(string.format(pageFmt,
                startIndex, endIndex, totalFields, self.currentPage, self.totalPages))
            self.pageInfoText:setVisible(true)
        end
    else
        if self.pageInfoText then self.pageInfoText:setVisible(false) end
    end

    if self.prevButton then
        self.prevButton:setDisabled(self.currentPage <= 1 or totalFields == 0)
    end
    if self.nextButton then
        self.nextButton:setDisabled(self.currentPage >= self.totalPages or totalFields == 0)
    end
end

-- ── Detail view ───────────────────────────────────────────────────────

--- Open the detail panel for a specific field (by page-row index 0–9).
function SoilReportDialog:openDetailForRow(rowIndex)
    local startIndex = (self.currentPage - 1) * SoilReportDialog.MAX_ROWS + 1
    local dataIndex  = startIndex + rowIndex
    if dataIndex > #self.sortedFieldIds then return end

    local fieldId = self.sortedFieldIds[dataIndex]
    if not fieldId then return end

    self.detailFieldId = fieldId
    self:setDetailMode(true)
    self:updateDetailView(fieldId)
end

--- Populate the detail panel with data for the given fieldId.
function SoilReportDialog:updateDetailView(fieldId)
    local info = self.fieldInfos[fieldId]
    if not info then return end

    local ppm = SoilConstants.PPM_DISPLAY or { N = 1, P = 1, K = 1 }

    -- Header
    if self.detailFieldLabel then
        self.detailFieldLabel:setText(string.format("%s %d", tr("sf_detail_field_label", "Field #"), fieldId))
    end
    if self.detailCropLabel then
        local cropName = info.lastCrop or tr("sf_report_none", "None")
        if cropName ~= "" then
            cropName = cropName:sub(1,1):upper() .. cropName:sub(2)
        end
        self.detailCropLabel:setText(cropName)
    end
    if self.detailOverallLabel then
        local status, statColor = getOverallStatus(info)
        self.detailOverallLabel:setText(tr("sf_report_rec_" .. status:lower(), status))
        self.detailOverallLabel:setTextColor(statColor[1], statColor[2], statColor[3], statColor[4])
    end

    -- Nutrients
    local function fillNutrient(valueEl, statEl, hintEl, rawVal, ppmMult, status, hintText)
        local ppmVal = math.floor(rawVal * ppmMult + 0.5)
        local color  = getStatusColor(status)
        if valueEl then
            valueEl:setText(string.format("%d ppm", ppmVal))
            valueEl:setTextColor(color[1], color[2], color[3], 1)
        end
        if statEl then
            statEl:setText(tr("sf_report_rec_" .. status:lower(), status))
            statEl:setTextColor(color[1], color[2], color[3], 1)
        end
        if hintEl then hintEl:setText(hintText or "") end
    end

    local nHint = (info.nitrogen.status == "Poor") and tr("sf_report_rec_n_poor", "Needs Nitrogen")
               or (info.nitrogen.status == "Fair") and tr("sf_report_rec_n_fair", "Low Nitrogen")
               or tr("sf_report_detail_n_ok", "Nitrogen: Optimal")
    fillNutrient(self.detailN, self.detailNStat, self.detailNHint,
        info.nitrogen.value,   ppm.N, info.nitrogen.status,   nHint)

    local pHint = (info.phosphorus.status == "Poor") and tr("sf_report_rec_p_poor", "Needs Phosphorus")
               or (info.phosphorus.status == "Fair") and tr("sf_report_rec_p_fair", "Low Phosphorus")
               or tr("sf_report_detail_p_ok", "Phosphorus: Optimal")
    fillNutrient(self.detailP, self.detailPStat, self.detailPHint,
        info.phosphorus.value, ppm.P, info.phosphorus.status, pHint)

    local kHint = (info.potassium.status == "Poor") and tr("sf_report_rec_k_poor", "Needs Potassium")
               or (info.potassium.status == "Fair") and tr("sf_report_rec_k_fair", "Low Potassium")
               or tr("sf_report_detail_k_ok", "Potassium: Optimal")
    fillNutrient(self.detailK, self.detailKStat, self.detailKHint,
        info.potassium.value,  ppm.K, info.potassium.status,  kHint)

    -- pH
    if self.detailPH then
        local phColor = getPHColor(info.pH)
        self.detailPH:setText(string.format("%.1f", info.pH))
        self.detailPH:setTextColor(phColor[1], phColor[2], phColor[3], 1)
    end
    if self.detailPHStat then
        local phColor = getPHColor(info.pH)
        local phStatus = (phColor == SoilReportDialog.COLOR_GOOD) and tr("sf_hud_optimal", "Optimal")
                      or (phColor == SoilReportDialog.COLOR_FAIR) and tr("sf_report_status_monitor", "Monitor")
                      or tr("sf_report_status_adjust", "Adjust")
        self.detailPHStat:setText(phStatus)
        self.detailPHStat:setTextColor(phColor[1], phColor[2], phColor[3], 1)
    end

    -- OM
    if self.detailOM then
        local omColor = getOMColor(info.organicMatter)
        self.detailOM:setText(string.format("%.1f%%", info.organicMatter))
        self.detailOM:setTextColor(omColor[1], omColor[2], omColor[3], 1)
    end
    if self.detailOMStat then
        local omColor = getOMColor(info.organicMatter)
        local omStatus = (omColor == SoilReportDialog.COLOR_GOOD) and tr("sf_hud_optimal", "Optimal")
                      or (omColor == SoilReportDialog.COLOR_FAIR) and tr("sf_report_status_maintain", "Maintain")
                      or tr("sf_report_status_increase", "Increase")
        self.detailOMStat:setText(omStatus)
        self.detailOMStat:setTextColor(omColor[1], omColor[2], omColor[3], 1)
    end

    -- Pressures
    local function fillPressure(valueEl, statEl, hintEl, rawVal, protectedFlag, protectedKey)
        local pct = math.floor((rawVal or 0) + 0.5)   -- stored as 0-100
        local color = getPressureColor(pct)
        local level = (pct < 25) and tr("sf_report_pressure_low", "Low")
                   or (pct < 60) and tr("sf_report_pressure_moderate", "Moderate")
                   or tr("sf_report_pressure_high", "High")
        if valueEl then
            valueEl:setText(string.format("%d%%", pct))
            valueEl:setTextColor(color[1], color[2], color[3], 1)
        end
        if statEl then
            statEl:setText(level)
            statEl:setTextColor(color[1], color[2], color[3], 1)
        end
        if hintEl then
            local hint = protectedFlag and tr("sf_hud_protected", "(protected)") or ""
            hintEl:setText(hint)
        end
    end

    fillPressure(self.detailWeed,    self.detailWeedStat,    self.detailWeedHint,
        info.weedPressure,    info.herbicideActive,  "sf_hud_protected")
    fillPressure(self.detailPest,    self.detailPestStat,    self.detailPestHint,
        info.pestPressure,    info.insecticideActive, "sf_hud_protected")
    fillPressure(self.detailDisease, self.detailDiseaseStat, self.detailDiseaseHint,
        info.diseasePressure, info.fungicideActive,   "sf_hud_protected")

    -- Yield forecast
    if self.detailYield then
        local ys = SoilConstants.YIELD_SENSITIVITY
        local cropLower = info.lastCrop and string.lower(info.lastCrop) or nil
        local yieldText = tr("sf_hud_optimal", "Optimal")
        local yieldColor = SoilReportDialog.COLOR_GOOD

        if ys and not (cropLower and ys.NON_CROP_NAMES and ys.NON_CROP_NAMES[cropLower]) then
            local tier     = (cropLower and ys.CROP_TIERS and ys.CROP_TIERS[cropLower]) or ys.DEFAULT_TIER
            local tierData = ys.TIERS and ys.TIERS[tier]
            local thresh   = ys.OPTIMAL_THRESHOLD or 70
            if tierData then
                local nDef = math.max(0, thresh - info.nitrogen.value)   / thresh
                local pDef = math.max(0, thresh - info.phosphorus.value) / thresh
                local kDef = math.max(0, thresh - info.potassium.value)  / thresh
                local penalty    = math.min(ys.MAX_PENALTY, (nDef + pDef + kDef) / 3 * tierData.scale)
                local penaltyPct = math.floor(penalty * 100 + 0.5)
                if penaltyPct > 0 then
                    yieldText  = string.format(tr("sf_report_yield_loss", "Yield ~-%d%%"), penaltyPct)
                    yieldColor = (penaltyPct >= 20) and SoilReportDialog.COLOR_POOR or SoilReportDialog.COLOR_FAIR
                end
            end
        end

        self.detailYield:setText(yieldText)
        self.detailYield:setTextColor(yieldColor[1], yieldColor[2], yieldColor[3], 1)
    end
    if self.detailYieldHint then
        self.detailYieldHint:setText(tr("sf_report_yield_hint", "Based on N/P/K vs optimal threshold"))
    end

    -- Recommendations summary
    if self.detailRecText then
        local recStr, recColor, overallStatus = self:getFertilizationRecommendation(info)
        self.detailRecText:setText(recStr)
        self.detailRecText:setTextColor(recColor[1], recColor[2], recColor[3], 1)
        
        if self.detailRecBg then
            if overallStatus == "Poor" then
                self.detailRecBg:setImageColor(nil, 0.25, 0.08, 0.08, 0.9)
            elseif overallStatus == "Fair" then
                self.detailRecBg:setImageColor(nil, 0.25, 0.20, 0.05, 0.9)
            else
                self.detailRecBg:setImageColor(nil, 0.08, 0.20, 0.08, 0.9)
            end
        end
    end
end

-- ── Per-row detail button callbacks ──────────────────────────────────
-- FS25 GUI onClick requires distinct method names per button.
function SoilReportDialog:onClickDetail0() self:openDetailForRow(0) end
function SoilReportDialog:onClickDetail1() self:openDetailForRow(1) end
function SoilReportDialog:onClickDetail2() self:openDetailForRow(2) end
function SoilReportDialog:onClickDetail3() self:openDetailForRow(3) end
function SoilReportDialog:onClickDetail4() self:openDetailForRow(4) end
function SoilReportDialog:onClickDetail5() self:openDetailForRow(5) end
function SoilReportDialog:onClickDetail6() self:openDetailForRow(6) end
function SoilReportDialog:onClickDetail7() self:openDetailForRow(7) end
function SoilReportDialog:onClickDetail8() self:openDetailForRow(8) end
function SoilReportDialog:onClickDetail9() self:openDetailForRow(9) end

-- ── Navigation buttons ────────────────────────────────────────────────

function SoilReportDialog:onBackFromDetail()
    self.detailFieldId = nil
    self:setDetailMode(false)
    self:updateFieldRows()
    self:updatePagination()
end

function SoilReportDialog:onPrevPage()
    if self.currentPage > 1 then
        self.currentPage = self.currentPage - 1
        self:updateFieldRows()
        self:updatePagination()
    end
end

function SoilReportDialog:onNextPage()
    if self.currentPage < self.totalPages then
        self.currentPage = self.currentPage + 1
        self:updateFieldRows()
        self:updatePagination()
    end
end

function SoilReportDialog:onCloseDialog()
    g_gui:closeDialogByName("SoilReportDialog")
end

function SoilReportDialog:onClickBack()
    g_gui:closeDialogByName("SoilReportDialog")
end

function SoilReportDialog:inputEvent(action, value, eventUsed)
    eventUsed = SoilReportDialog:superClass().inputEvent(self, action, value, eventUsed)

    if not eventUsed and action == InputAction.MENU_BACK and value > 0 then
        if self.detailMode then
            self:onBackFromDetail()
        else
            g_gui:closeDialogByName("SoilReportDialog")
        end
        eventUsed = true
    end

    return eventUsed
end

function SoilReportDialog:onClose()
    SoilReportDialog:superClass().onClose(self)
    self.fieldInfos = {}
    self.sortedFieldIds = {}
    self.currentPage = 1
    self.totalPages = 1
    self.detailMode = false
    self.detailFieldId = nil
    if self.ownershipRetry then
        self.ownershipRetry:reset()
        self.ownershipRetry = nil
    end
end

--- Called from SoilFertilityManager:update(dt) every frame.
---@param dt number Delta time in milliseconds
function SoilReportDialog:update(dt)
    if self.ownershipRetry and self.ownershipRetry:isPending() then
        self.ownershipRetry:update(dt)
    end
end
