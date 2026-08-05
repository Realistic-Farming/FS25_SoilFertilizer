-- =========================================================
-- FS25 Soil & Fertilizer - RfPdaSoilPanel
-- =========================================================
-- Phase 0 from-scratch Esc RF rebuild: Soil main-pane logic
-- extracted from RfPdaMenuPage (table rows + TREATMENT PLAN).
-- Shell keeps Map chrome / host cycle; this module owns Soil data.
-- Hang rules: no SmoothList thrash here; shell decides reload timing.
-- N/P/K/status/fert = colored text only (no nil-filename Bitmaps).
-- =========================================================

RfPdaSoilPanel = {}
-- Cross-mod: WC/CS may source RfPdaMenuPage last (their env has no RfPdaSoilPanel).
-- getfenv(0) is Soil modEnv only — still publish for same-env callers.
-- Mission soft-detect is the reliable cross-mod bridge (also set in RfSoilEscJoiner).
if type(getfenv) == "function" then
    local env0 = getfenv(0)
    if env0 ~= nil then
        env0["RfPdaSoilPanel"] = RfPdaSoilPanel
    end
end
if g_currentMission ~= nil then
    g_currentMission.rfPdaSoilPanel = RfPdaSoilPanel
end

local COLOR_GOOD = {0.549, 0.776, 0.247, 1.0}
local COLOR_FAIR = {0.878, 0.627, 0.125, 1.0}
local COLOR_POOR = {0.788, 0.290, 0.227, 1.0}
local COLOR_DIM  = {1.00, 1.00, 1.00, 0.55}
local COLOR_LIME_BRIGHT = {0.659, 0.878, 0.290, 1.0}

local function colorForStatus(status)
    if status == "Good" or status == "Excellent" then
        return COLOR_GOOD
    elseif status == "Fair" or status == "OK" then
        return COLOR_FAIR
    end
    return COLOR_POOR
end

local function colorForKey(colorKey)
    if colorKey == "good" or colorKey == "ok" then
        return COLOR_GOOD
    elseif colorKey == "fair" or colorKey == "warn" then
        return COLOR_FAIR
    elseif colorKey == "poor" or colorKey == "urgent" then
        return COLOR_POOR
    end
    return COLOR_DIM
end

local function resolveFarmId()
    local farmId = nil
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        farmId = g_localPlayer.farmId
    end
    if (farmId == nil or farmId == 0) and g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    return farmId
end

local function appendFieldEntry(page, sfm, fieldId)
    local ok, info = pcall(function()
        return sfm.soilSystem:getFieldInfo(fieldId)
    end)
    if not ok or info == nil then
        return
    end
    local urgency = 0
    local urgOk, urgVal = pcall(function()
        return sfm.soilSystem:getFieldUrgency(fieldId)
    end)
    if urgOk and urgVal ~= nil then
        urgency = urgVal
    end
    table.insert(page.fieldData, {
        fieldId = fieldId,
        info = info,
        urgency = urgency or 0,
    })
end

local function countFieldDataKeys(fieldData)
    local n = 0
    for _ in pairs(fieldData) do
        n = n + 1
    end
    return n
end

--- Rebuild page.fieldData from SoilFertilitySystem (sorted by fieldId).
--- Prefer owned fields (Wizard ruling): fieldData keys are farmland ids, so
--- ownership is g_farmlandManager:getFarmlandOwner(fieldId), same as RfSoilFrame.
--- If owned filter yields 0 but soilSystem.fieldData has entries, fall back to
--- all fields with data (farmId mismatch / MP join edge).
---@param page table RfPdaMenuPage instance
function RfPdaSoilPanel.rebuildFieldData(page)
    page.fieldData = {}
    local sfm = g_SoilFertilityManager
    if sfm == nil and type(getfenv) == "function" then
        local env0 = getfenv(0)
        if env0 ~= nil then
            sfm = env0.g_SoilFertilityManager
        end
    end
    if sfm == nil or sfm.soilSystem == nil or sfm.soilSystem.fieldData == nil then
        return
    end

    local rawCount = countFieldDataKeys(sfm.soilSystem.fieldData)
    if rawCount == 0 then
        return
    end

    local farmId = resolveFarmId()
    local usedOwnedFilter = false
    if farmId ~= nil and farmId ~= 0 and g_farmlandManager ~= nil then
        usedOwnedFilter = true
        for fieldId, _ in pairs(sfm.soilSystem.fieldData) do
            local owner = g_farmlandManager:getFarmlandOwner(fieldId)
            if owner == farmId then
                appendFieldEntry(page, sfm, fieldId)
            end
        end
    end

    if #page.fieldData == 0 then
        for fieldId, _ in pairs(sfm.soilSystem.fieldData) do
            appendFieldEntry(page, sfm, fieldId)
        end
        if usedOwnedFilter and #page.fieldData > 0 then
            local msg = string.format(
                "RfPdaSoilPanel: owned filter empty; falling back to all fields with soil data (%d)",
                #page.fieldData
            )
            if SoilLogger ~= nil and type(SoilLogger.info) == "function" then
                SoilLogger.info("%s", msg)
            elseif Logging ~= nil and type(Logging.info) == "function" then
                Logging.info("[RfEsc] %s", msg)
            end
        end
    end

    table.sort(page.fieldData, function(a, b)
        return a.fieldId < b.fieldId
    end)
end

function RfPdaSoilPanel.reloadFieldList(page)
    if page.fieldOverviewList then
        page.fieldOverviewList:reloadData()
    end
    if page.fieldsEmptyHint then
        local tr = page._rfTr or function(k, fb) return fb or k end
        if type(page.fieldsEmptyHint.setText) == "function" then
            page.fieldsEmptyHint:setText(tr("sf_pda_no_fields", "No field data recorded yet."))
        end
        page.fieldsEmptyHint:setVisible(#page.fieldData == 0)
    end
end

function RfPdaSoilPanel.populateFieldRow(page, index, cell)
    local entry = page.fieldData[index]
    if entry == nil or entry.info == nil then return end
    local info = entry.info
    local tr = page._rfTr or function(k, fb) return fb or k end

    local idEl     = cell:getDescendantByName("fieldRowId")
    local areaEl   = cell:getDescendantByName("fieldRowArea")
    local nEl      = cell:getDescendantByName("fieldRowN")
    local pEl      = cell:getDescendantByName("fieldRowP")
    local kEl      = cell:getDescendantByName("fieldRowK")
    local phEl     = cell:getDescendantByName("fieldRowPH")
    local statusEl = cell:getDescendantByName("fieldRowStatus")
    local fertEl   = cell:getDescendantByName("fieldRowFert")

    if idEl then
        idEl:setText(string.format("Field %s", tostring(entry.fieldId)))
    end

    if areaEl then
        local area = info.fieldArea or 0
        if area > 0 then
            areaEl:setText(string.format("%.1f", area))
        else
            areaEl:setText("-")
        end
    end

    local function setNutrientText(el, nutrient)
        local value = nutrient and nutrient.value or 0
        local status = nutrient and nutrient.status or "Poor"
        if el then
            el:setText(string.format("%d%%", math.floor(value)))
            el:setTextColor(unpack(colorForStatus(status)))
        end
    end

    setNutrientText(nEl, info.nitrogen)
    setNutrientText(pEl, info.phosphorus)
    setNutrientText(kEl, info.potassium)

    -- pH: scalar from getFieldInfo (not %); SoilPDAScreen band colors; nil -> "-"
    if phEl then
        local phNum = tonumber(info.pH)
        if phNum == nil then
            phEl:setText("-")
            phEl:setTextColor(unpack(COLOR_DIM))
        else
            local ph = math.floor((phNum * 10) + 0.5) / 10
            phEl:setText(string.format("%.1f", ph))
            -- SoilPDAScreen bands: good 6.5-7.0; fair 6.0-<7.5; else poor
            if ph >= 6.5 and ph <= 7.0 then
                phEl:setTextColor(unpack(COLOR_GOOD))
            elseif ph >= 6.0 and ph < 7.5 then
                phEl:setTextColor(unpack(COLOR_FAIR))
            else
                phEl:setTextColor(unpack(COLOR_POOR))
            end
        end
    end

    local urgent = (entry.urgency or 0) >= 60
    local okStatus = (entry.urgency or 0) < 25 and not info.needsFertilization
    if statusEl then
        if urgent then
            statusEl:setText(tr("rf_pda_status_urgent", "URGENT"))
            statusEl:setTextColor(unpack(COLOR_POOR))
        elseif okStatus then
            statusEl:setText(tr("rf_pda_status_ok", "OK"))
            statusEl:setTextColor(unpack(COLOR_GOOD))
        else
            statusEl:setText(tr("sf_pda_status_fair", "Fair"))
            statusEl:setTextColor(unpack(COLOR_FAIR))
        end
    end

    if fertEl then
        if info.needsFertilization then
            fertEl:setText(tr("rf_pda_fert_chip", "FERT"))
            fertEl:setTextColor(unpack(COLOR_FAIR))
        else
            fertEl:setText("—")
            fertEl:setTextColor(unpack(COLOR_DIM))
        end
    end
end

function RfPdaSoilPanel.refreshTreatmentPlan(page)
    local tr = page._rfTr or function(k, fb) return fb or k end
    local fieldId = page.selectedFieldId
    local entry = nil
    for _, e in ipairs(page.fieldData or {}) do
        if e.fieldId == fieldId then
            entry = e
            break
        end
    end

    local function clearTargets()
        if page.treatTargetsHeading then page.treatTargetsHeading:setText("") end
        if page.treatTargetN then page.treatTargetN:setText("") end
        if page.treatTargetP then page.treatTargetP:setText("") end
        if page.treatTargetK then page.treatTargetK:setText("") end
        if page.treatTargetsLabel then
            page.treatTargetsLabel:setText("")
            if page.treatTargetsLabel.setVisible then
                page.treatTargetsLabel:setVisible(false)
            end
        end
    end

    local function clearProductRows()
        for i = 1, 8 do
            local slot = page.treatProdRows and page.treatProdRows[i]
            if slot and slot.row and slot.row.setVisible then
                slot.row:setVisible(false)
            end
        end
    end

    local function setProductOk(text, color)
        clearProductRows()
        if page.treatPlanLines then
            page.treatPlanLines:setText(text or "")
            if page.treatPlanLines.setVisible then
                page.treatPlanLines:setVisible(text ~= nil and text ~= "")
            end
            if color and page.treatPlanLines.setTextColor then
                page.treatPlanLines:setTextColor(unpack(color))
            end
        end
    end

    local function fillProductRows(rows)
        clearProductRows()
        if page.treatPlanLines and page.treatPlanLines.setVisible then
            page.treatPlanLines:setVisible(false)
        end
        local n = math.min(8, #(rows or {}))
        for i = 1, n do
            local row = rows[i]
            local slot = page.treatProdRows and page.treatProdRows[i]
            if slot and slot.row then
                if slot.row.setVisible then slot.row:setVisible(true) end
                if slot.nut then slot.nut:setText(tostring(row.nutrient or "")) end
                if slot.name then slot.name:setText(tostring(row.product or "")) end
                if slot.rate then slot.rate:setText(tostring(row.rate or "")) end
                if slot.total then slot.total:setText(tostring(row.total or "")) end
                local col = colorForKey(row.colorKey)
                for _, el in ipairs({ slot.nut, slot.name, slot.rate, slot.total }) do
                    if el and el.setTextColor then
                        el:setTextColor(unpack(col))
                    end
                end
            end
        end
    end

    local function setSelectedLabel(nextTip)
        if not page.treatSelectedLabel and not page.treatNextLabel then
            return
        end
        if fieldId == nil then
            if page.treatSelectedLabel then
                page.treatSelectedLabel:setText(tr("rf_pda_treatment_none_selected", "Select a field"))
                if page.treatSelectedLabel.setTextColor then
                    page.treatSelectedLabel:setTextColor(unpack(COLOR_LIME_BRIGHT))
                end
            end
            if page.treatNextLabel then
                page.treatNextLabel:setText("")
                if page.treatNextLabel.setVisible then
                    page.treatNextLabel:setVisible(false)
                end
            end
            return
        end

        -- Line 1: Field only
        if page.treatSelectedLabel then
            local tpl = tr("rf_pda_treatment_selected", "Selected field: Field %s")
            local okFmt, formatted = pcall(string.format, tpl, tostring(fieldId))
            local text = okFmt and formatted or ("Field " .. tostring(fieldId))
            page.treatSelectedLabel:setText(text)
            if page.treatSelectedLabel.setTextColor then
                page.treatSelectedLabel:setTextColor(unpack(COLOR_LIME_BRIGHT))
            end
        end

        -- Line 2: Next tip (own Text; wrap via profile textMaxNumLines)
        if page.treatNextLabel then
            if nextTip ~= nil and nextTip ~= "" then
                local tpl = tr("rf_pda_treatment_next", "Next: %s")
                local okFmt, formatted = pcall(string.format, tpl, nextTip)
                local text = okFmt and formatted or ("Next: " .. tostring(nextTip))
                page.treatNextLabel:setText(text)
                if page.treatNextLabel.setVisible then
                    page.treatNextLabel:setVisible(true)
                end
                if page.treatNextLabel.setTextColor then
                    page.treatNextLabel:setTextColor(unpack(COLOR_LIME_BRIGHT))
                end
            else
                page.treatNextLabel:setText("")
                if page.treatNextLabel.setVisible then
                    page.treatNextLabel:setVisible(false)
                end
            end
        end
    end

    if entry == nil or entry.info == nil then
        setSelectedLabel(nil)
        clearTargets()
        setProductOk(tr("sf_pda_no_fields", "No field data"), COLOR_DIM)
        -- F1: never draw empty sampling hint (it overlapped PRODUCTS). Hide both.
        if page.samplingInfoBox then page.samplingInfoBox:setVisible(false) end
        if page.samplingInfoFallback then page.samplingInfoFallback:setVisible(false) end
        return
    end

    local info = entry.info
    local thresh = SoilConstants and SoilConstants.STATUS_THRESHOLDS or {}
    local ct = info.cropTargets
    local nLo = (ct and ct.N and ct.N.opt) or (thresh.nitrogen and thresh.nitrogen.fair) or 50
    local nHi = (ct and ct.N and ct.N.opt and math.min(100, ct.N.opt + 20)) or 80
    local pLo = (ct and ct.P and ct.P.opt) or (thresh.phosphorus and thresh.phosphorus.fair) or 45
    local pHi = (ct and ct.P and ct.P.opt and math.min(100, ct.P.opt + 20)) or 75
    local kLo = (ct and ct.K and ct.K.opt) or (thresh.potassium and thresh.potassium.fair) or 40
    local kHi = (ct and ct.K and ct.K.opt and math.min(100, ct.K.opt + 20)) or 70

    -- F5: separate Text lines (Giants Text often shows literal \n / broken l10n backticks)
    if page.treatTargetsHeading then
        page.treatTargetsHeading:setText(tr("rf_pda_treatment_targets_heading", "Target levels"))
    end
    if page.treatTargetN then
        page.treatTargetN:setText(string.format("N %d-%d%%", nLo, nHi))
    end
    if page.treatTargetP then
        page.treatTargetP:setText(string.format("P %d-%d%%", pLo, pHi))
    end
    if page.treatTargetK then
        page.treatTargetK:setText(string.format("K %d-%d%%", kLo, kHi))
    end
    if page.treatTargetsLabel and page.treatTargetsLabel.setVisible then
        page.treatTargetsLabel:setVisible(false)
    end

    local rows = {}
    if SoilTreatmentRates and SoilTreatmentRates.buildPlanTableRows then
        rows = SoilTreatmentRates.buildPlanTableRows(fieldId) or {}
    end

    local nextTip = nil
    if #rows > 0 and SoilTreatmentRates and SoilTreatmentRates.buildNextStepLine then
        nextTip = SoilTreatmentRates.buildNextStepLine(fieldId)
    end
    setSelectedLabel(nextTip)

    if #rows == 0 then
        setProductOk(tr("sf_treat_action_ok", "OK - no treatment needed"), COLOR_GOOD)
    else
        fillProductRows(rows)
    end

    local sampleText = nil
    if info.lastSampleDate ~= nil or info.nextSampleSuggested ~= nil then
        local bits = { tr("rf_pda_sample_heading", "Soil sampling") }
        if info.lastSampleDate then
            table.insert(bits, tr("rf_pda_sample_dated", "Last sample") .. ": " .. tostring(info.lastSampleDate))
        end
        if info.nextSampleSuggested then
            table.insert(bits, tr("rf_pda_sample_next", "Next suggested") .. ": " .. tostring(info.nextSampleSuggested))
        end
        sampleText = table.concat(bits, "\n")
    end

    -- F1: show sampling only when real dates exist; never show empty fallback over PRODUCTS
    if page.samplingInfoFallback then
        page.samplingInfoFallback:setVisible(false)
    end
    if page.samplingInfoBox then
        page.samplingInfoBox:setVisible(sampleText ~= nil)
    end
    if page.samplingInfoText and sampleText ~= nil then
        page.samplingInfoText:setText(sampleText)
    end
end
