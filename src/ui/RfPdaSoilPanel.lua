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
-- getfenv(0) is Soil modEnv only - still publish for same-env callers.
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
            fertEl:setText(tr("rf_pda_fert_in_need", "IN NEED"))
            fertEl:setTextColor(unpack(COLOR_FAIR))
        else
            fertEl:setText("-")
            fertEl:setTextColor(unpack(COLOR_DIM))
        end
    end

    -- Crop pressure columns. Bands copied from SoilFieldDetailDialog:_setPressure so the
    -- overview and the deep desk can never disagree: under 20 Good, under 50 Fair, else High.
    -- HONESTY (George + Samantha veto): these read info.weedPressure / info.pestPressure /
    -- info.shownDiseasePressure ONLY. The mock shows Weeds looking like N and Pests like P,
    -- but that is placeholder art - nutrients must never be copied into these cells.
    local weedEl    = cell:getDescendantByName("fieldRowWeed")
    local pestEl    = cell:getDescendantByName("fieldRowPest")
    local diseaseEl = cell:getDescendantByName("fieldRowDisease")

    local function colorForPressure(p)
        if p < 20 then
            return COLOR_GOOD
        elseif p < 50 then
            return COLOR_FAIR
        end
        return COLOR_POOR
    end

    local function setPressureCell(el, value)
        if el == nil then return end
        local p = math.floor(tonumber(value) or 0)
        el:setText(string.format("%d%%", p))
        el:setTextColor(unpack(colorForPressure(p)))
    end

    setPressureCell(weedEl, info.weedPressure)
    setPressureCell(pestEl, info.pestPressure)

    -- Disease is scouting-gated. shownDiseasePressure is nil exactly when the field has not
    -- been scouted; that is honest absence and must read as the word, never as 0% and never
    -- as the ungated raw info.diseasePressure (which exists but is not ours to show).
    if diseaseEl then
        if info.shownDiseasePressure == nil then
            diseaseEl:setText(tr("sf_unscouted", "Unscouted"))
            diseaseEl:setTextColor(unpack(COLOR_DIM))
        else
            setPressureCell(diseaseEl, info.shownDiseasePressure)
        end
    end
end

--- Paint the three What-if rows (crop / status / effect) from RotationPlannerData.
--- Read-only projection only: pickCandidates + project + statusWord + effectText.
--- Never invents a crop - a candidate with no projection prints honest dashes.
local function paintWhatIfRows(page, entry, tr, clip)
    local rows = page.soilRotationIfRows
    local hdr  = page.soilRotationWhatIfHeader
    if rows == nil then return end

    local function setEl(el, s)
        if el ~= nil then
            if el.setVisible then el:setVisible(true) end
            if el.setText then el:setText(s or "") end
        end
    end

    setEl(hdr, tr("sf_rp_what_if", "What if (next crop)"))
    setEl(page.soilRotationIfColCrop,   tr("sf_rp_col_crop", "Crop"))
    setEl(page.soilRotationIfColStatus, tr("sf_rp_col_status", "Status"))
    setEl(page.soilRotationIfColEffect, tr("sf_rp_col_effect", "Effect"))

    local rpd = RotationPlannerData
    local info = entry ~= nil and entry.info or nil
    local fieldId = entry ~= nil and entry.fieldId or nil

    local cands, cache = nil, nil
    if rpd ~= nil and info ~= nil and fieldId ~= nil then
        if type(rpd.pickCandidates) == "function" then
            local ok, c = pcall(rpd.pickCandidates, info.lastCrop, nil)
            if ok then cands = c end
        end
        if type(rpd.cacheForFields) == "function" then
            local ok, cc = pcall(rpd.cacheForFields, { fieldId })
            if ok then cache = cc end
        end
    end

    for i = 1, 3 do
        local r = rows[i]
        if r ~= nil then
            local cand = cands and cands[i] or nil
            if cand == nil or cand == "" then
                setEl(r.crop, "-"); setEl(r.status, ""); setEl(r.effect, "")
            else
                local label = (type(rpd.cropLabel) == "function") and rpd.cropLabel(cand) or tostring(cand)
                local proj
                if cache ~= nil and type(rpd.project) == "function" then
                    local ok, pr = pcall(rpd.project, cache, fieldId, cand)
                    if ok then proj = pr end
                end
                local word = (proj ~= nil and type(rpd.statusWord) == "function")
                    and rpd.statusWord(proj.status) or tr("sf_rp_status_unknown", "Unknown")
                local eff = (type(rpd.effectText) == "function") and rpd.effectText(proj) or ""
                setEl(r.crop,   clip(label, 16))
                setEl(r.status, clip(word, 10))
                setEl(r.effect, clip(eff, 18))
            end
        end
    end
end

--- Read-only crop rotation card in the TREATMENT strip (Samantha DESIGN CLOSED +
--- George ENGINE ACK 2026-08-08; Tyson eyes-on shot 01).
--- Restored after PR #800 landed a tree where the call site survived but this
--- definition did not, so every TREATMENT refresh was calling a nil value.
--- Read-only by law: no rotation apply, no SmoothList, no invented crops.
---@param page table RfPdaMenuPage instance (may be a thin door without the card ids)
---@param entry table|nil selected field entry from page.fieldData
function RfPdaSoilPanel.refreshRotationCard(page, entry)
    if page == nil then return end
    local tr = page._rfTr or function(k, fb) return fb or k end

    -- Col 3 ownership for THIS refresh. Cleared first so a door without the card,
    -- or a painter that throws before claiming, never leaves a stale claim behind.
    page._rotationCardOwnsCol3 = false

    local cardEl   = page.soilRotationCard
    local titleEl  = page.soilRotationTitle
    local lastEl   = page.soilRotationLast
    local statusEl = page.soilRotationStatus
    local tipEl    = page.soilRotationTip

    -- Thin doors (Income / Tax / Dairy / NPC / Depot) may host without the card ids.
    -- Hide what exists, clear, and return. Never throw - PRODUCTS must still paint.
    if titleEl == nil and lastEl == nil and statusEl == nil and tipEl == nil then
        if cardEl ~= nil and cardEl.setVisible then cardEl:setVisible(false) end
        if not page._rotationCardWarned then
            page._rotationCardWarned = true
            print("[SoilFertilizer] rotation card ids absent on this door - skipping card (PRODUCTS unaffected)")
        end
        return
    end

    -- George: the sampling box sits at the SAME x=850 as this card, so while Col 3 is the
    -- rotation card the sampling chrome must stay hidden or it paints over it. This is the
    -- likely cause of the orphaned look in Tyson shot 01.
    -- Vera F1: hiding here is necessary but NOT sufficient - refreshTreatmentPlan re-shows
    -- sampling later in the same refresh whenever sample dates exist, and it runs after us.
    -- Claiming Col 3 is what actually holds; the hide below just makes the claim immediate.
    page._rotationCardOwnsCol3 = true
    local page2 = page
    for _, sid in ipairs({ "samplingInfoBox", "samplingInfoFallback" }) do
        local sEl = page2[sid] or (page2.getDescendantById and page2:getDescendantById(sid))
        if sEl ~= nil and sEl.setVisible then sEl:setVisible(false) end
    end

    --- BUILD 15:39 (PB-09). Fit the narrow What-if columns WITHOUT cutting a
    --- word in half.
    ---
    --- This used to be a flat `s:sub(1, n - 3) .. "..."`, which is how a status
    --- reached Brian as `burn t...`. Half a word plus three dots is not shorter
    --- information, it is unreadable information, and DESIGN 15:00 §4 rules it
    --- out: no mid-word clipping against a neighbour, and an ellipsis only once
    --- the source is genuinely long.
    ---
    --- The order of preference is:
    ---   1. It fits. Print it.
    ---   2. It is a comma-joined list (the effect column is). Drop whole items
    ---      from the end until what is left fits - you lose an item, not half a
    ---      word, and every item still on screen is complete.
    ---   3. Single long phrase. Cut at the last space that fits, so the last
    ---      thing shown is a whole word.
    ---   4. One unbroken token longer than the column. Only here is a hard cut
    ---      unavoidable, and only then does the ellipsis appear.
    local ELLIPSIS_FLOOR = 28   -- DESIGN 15:00 §4
    local function clip(s, n)
        s = tostring(s or "")
        if #s <= n then return s end

        if string.find(s, ", ", 1, true) ~= nil then
            local kept = nil
            for part in string.gmatch(s, "([^,]+)") do
                part = part:gsub("^%s+", ""):gsub("%s+$", "")
                local try = (kept == nil) and part or (kept .. ", " .. part)
                if #try <= n then kept = try else break end
            end
            if kept ~= nil then return kept end
        end

        local cut = string.sub(s, 1, n)
        local sp  = string.find(string.reverse(cut), " ")
        if sp ~= nil then
            local wordEnd = n - sp
            if wordEnd >= 3 then
                return string.sub(cut, 1, wordEnd)
            end
        end

        -- A single token wider than its column. Ellipsis only past the floor.
        if #s >= ELLIPSIS_FLOOR then
            return string.sub(s, 1, math.max(1, n - 3)) .. "..."
        end
        return cut
    end

    local function set(el, text)
        if el ~= nil then
            if el.setVisible then el:setVisible(true) end
            if el.setText then el:setText(text or "") end
        end
    end

    if cardEl ~= nil and cardEl.setVisible then cardEl:setVisible(true) end
    set(titleEl, tr("rf_pda_treat_rotation", "ROTATION"))

    -- Soft-detect only; never hard-require the planner module.
    local rpd = RotationPlannerData
    local info = entry ~= nil and entry.info or nil

    -- No field selected or no planner: Samantha's honest empty map.
    if info == nil or rpd == nil then
        set(lastEl, tr("sf_rp_no_history", "No crop history yet"))
        set(statusEl, tr("sf_rp_status_unknown", "Unknown"))
        set(tipEl, tr("rf_pda_rotation_tip_generic", "Rotate crops to avoid fatigue."))
        paintWhatIfRows(page, entry, tr, clip)
        return
    end

    local cropLabel = type(rpd.cropLabel) == "function" and rpd.cropLabel or nil
    local hasHistory = info.lastCrop ~= nil and info.lastCrop ~= ""

    if not hasHistory then
        set(lastEl, tr("sf_rp_no_history", "No crop history yet"))
        set(statusEl, tr("sf_rp_status_unknown", "Unknown"))
        set(tipEl, tr("rf_pda_rotation_tip_generic", "Rotate crops to avoid fatigue."))
        paintWhatIfRows(page, entry, tr, clip)
        return
    end

    local c1 = cropLabel and cropLabel(info.lastCrop) or tostring(info.lastCrop)
    local c2 = (info.lastCrop2 ~= nil and info.lastCrop2 ~= "")
        and (cropLabel and cropLabel(info.lastCrop2) or tostring(info.lastCrop2)) or nil
    local story = (c2 ~= nil) and string.format("%s / %s", c1, c2) or c1
    set(lastEl, string.format("%s %s", tr("rf_pda_rotation_last", "Last:"), story))

    local word = type(rpd.statusWord) == "function" and rpd.statusWord(info.rotationStatus) or nil
    set(statusEl, word or tr("sf_rp_status_unknown", "Unknown"))
    paintWhatIfRows(page, entry, tr, clip)

    -- One quiet tip, keyed off the same status the deep planner reports.
    local tip
    if info.rotationStatus == "Fatigue" then
        tip = tr("rf_pda_rotation_tip_fatigue", "Same family too long. Change crop next season.")
    elseif info.rotationStatus == "Bonus" then
        tip = tr("rf_pda_rotation_tip_bonus", "Rotation bonus active. Keep the sequence going.")
    else
        tip = tr("rf_pda_rotation_tip_generic", "Rotate crops to avoid fatigue.")
    end
    set(tipEl, tip)
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

    -- Cleared per refresh: if refreshRotationCard is missing entirely (the PR #800 shape)
    -- the claim must not survive from the previous paint and hide sampling forever.
    page._rotationCardOwnsCol3 = false

    -- Guarded: the card is a nice-to-have glance, PRODUCTS is the load-bearing panel.
    -- PR #800 shipped a tree where this call site survived but the definition did not,
    -- so an unguarded call took the whole TREATMENT paint down with it.
    if type(RfPdaSoilPanel.refreshRotationCard) == "function" then
        local okCard, errCard = pcall(RfPdaSoilPanel.refreshRotationCard, page, entry)
        if not okCard and not page._rotationCardErrLogged then
            page._rotationCardErrLogged = true
            print("[SoilFertilizer] rotation card paint failed (PRODUCTS continues): " .. tostring(errCard))
        end
    end

    local function clearTargets()
        if page.treatTargetsHeading then page.treatTargetsHeading:setText("") end
        if page.treatTargetN then page.treatTargetN:setText("") end
        if page.treatTargetP then page.treatTargetP:setText("") end
        if page.treatTargetK then page.treatTargetK:setText("") end
        if page.treatTargetPH then page.treatTargetPH:setText("") end
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
    -- Target pH band from constants only (never live info.pH)
    if page.treatTargetPH then
        local limits = SoilConstants and SoilConstants.NUTRIENT_LIMITS or {}
        local phLo = limits.PH_NEUTRAL_LOW or 6.5
        local phHi = limits.PH_NEUTRAL_HIGH or 7.0
        page.treatTargetPH:setText(string.format("pH %.1f-%.1f", phLo, phHi))
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

    -- F1: show sampling only when real dates exist; never show empty fallback over PRODUCTS.
    -- Vera F1 (resubmit): sampling sits at x=850, the same x as the rotation card. This block
    -- runs AFTER refreshRotationCard, so a painter-only hide loses the moment sample dates
    -- exist. Ownership decides for the whole refresh - card up means sampling stays down,
    -- dates or not. George's ruling stands: hide, never move the sampling x.
    local cardOwnsCol3 = page._rotationCardOwnsCol3 == true
    if page.samplingInfoFallback then
        page.samplingInfoFallback:setVisible(false)
    end
    if page.samplingInfoBox then
        page.samplingInfoBox:setVisible(not cardOwnsCol3 and sampleText ~= nil)
    end
    if page.samplingInfoText and sampleText ~= nil then
        page.samplingInfoText:setText(sampleText)
    end
end
