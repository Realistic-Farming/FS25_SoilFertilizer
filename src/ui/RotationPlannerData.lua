-- =========================================================
-- Rotation Planner - shared read helpers (Wizard UI brief #739)
-- =========================================================
-- Pure reader over SoilFertilitySystem:projectRotation / getFieldInfo.
-- Prefer K's blessed getRotationCandidatePool (#739, SF db315d5e). Local
-- mirrors remain as degrade-when-absent fallback only.
-- Stores nothing, writes nothing, plants nothing.
-- =========================================================

RotationPlannerData = {}

-- Fallback mirrors (used only when the blessed pool getter is absent).
RotationPlannerData.LEGUME_CANDIDATES  = { "soybean", "peas", "clover", "alfalfa" }
RotationPlannerData.NEUTRAL_CANDIDATES = { "wheat", "barley", "maize", "canola" }

local function _tr(key, fallback)
    if g_i18n ~= nil and key ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        local t = g_i18n:getText(key)
        if t ~= nil and t ~= "" then return t end
    end
    return fallback or tostring(key or "")
end

function RotationPlannerData.getSoilSystem()
    local mgr = (g_currentMission and g_currentMission.soilFertilityManager)
             or (g_SoilFertilityManager)
    if mgr == nil then return nil end
    return mgr.soilSystem
end

--- Resolve the curated pool: blessed getter first, local mirrors as fallback.
function RotationPlannerData.candidateLists(soil)
    if soil ~= nil and type(soil.getRotationCandidatePool) == "function" then
        local ok, pool = pcall(function() return soil:getRotationCandidatePool() end)
        if ok and type(pool) == "table" and type(pool.LEGUME) == "table" and type(pool.NEUTRAL) == "table" then
            return pool.LEGUME, pool.NEUTRAL
        end
    end
    if SoilConstants ~= nil and type(SoilConstants.ROTATION_CANDIDATE_POOL) == "table" then
        local pool = SoilConstants.ROTATION_CANDIDATE_POOL
        if type(pool.LEGUME) == "table" and type(pool.NEUTRAL) == "table" then
            return pool.LEGUME, pool.NEUTRAL
        end
    end
    return RotationPlannerData.LEGUME_CANDIDATES, RotationPlannerData.NEUTRAL_CANDIDATES
end

--- Same curated 3-crop set as field-detail foresight.
function RotationPlannerData.pickCandidates(currentCrop, soil)
    local cur = currentCrop and string.lower(currentCrop) or ""
    local legumes, neutrals = RotationPlannerData.candidateLists(soil)
    local legume
    for _, c in ipairs(legumes) do
        if c ~= cur then legume = c break end
    end
    local neutral
    for _, c in ipairs(neutrals) do
        if c ~= cur and c ~= legume then neutral = c break end
    end
    local same = (cur ~= "") and cur or nil
    return { same, legume, neutral }
end

--- Cache getFieldInfo per open (brief allowance).
function RotationPlannerData.cacheForFields(fieldIds)
    local soil = RotationPlannerData.getSoilSystem()
    local cache = { soil = soil, byId = {} }
    if soil == nil or soil.getFieldInfo == nil then return cache end
    for _, fieldId in ipairs(fieldIds or {}) do
        local ok, info = pcall(function() return soil:getFieldInfo(fieldId) end)
        if ok and info ~= nil then
            -- Honest degrade: lastCrop3 / bonus days only if K published them
            -- OR readable from internal fieldData (prefer public payload).
            if info.lastCrop3 == nil and soil.fieldData ~= nil then
                local f = soil.fieldData[fieldId]
                if f ~= nil then
                    info.lastCrop3 = f.lastCrop3
                    info.rotationBonusDaysLeft = f.rotationBonusDaysLeft
                end
            end
            cache.byId[fieldId] = info
        end
    end
    return cache
end

function RotationPlannerData.project(cache, fieldId, candidate)
    if cache == nil or cache.soil == nil or candidate == nil or candidate == "" then
        return nil
    end
    local ok, proj = pcall(function()
        return cache.soil:projectRotation(fieldId, candidate)
    end)
    if not ok then return nil end
    return proj
end

function RotationPlannerData.statusWord(status)
    if status == "Bonus" then return _tr("sf_rf_status_bonus", "Bonus"), "bonus"
    elseif status == "Fatigue" then return _tr("sf_rf_status_fatigue", "Fatigue"), "fatigue"
    elseif status == "OK" then return _tr("sf_rf_status_ok", "OK"), "ok"
    end
    return _tr("sf_rp_status_unknown", "Unknown"), "unknown"
end

function RotationPlannerData.effectText(proj)
    if proj == nil or proj.status == nil then
        return _tr("sf_rf_effect_neutral", "no change")
    end
    local parts = {}
    if proj.fatigue then
        parts[#parts + 1] = _tr("sf_rf_effect_fatigue", "x1.15 depletion")
    end
    if proj.nitrogen == "up" then
        parts[#parts + 1] = _tr("sf_rf_effect_nplus", "+N")
    end
    if proj.disease == "down" then
        parts[#parts + 1] = _tr("sf_rf_effect_disease_down", "less disease")
    elseif proj.disease == "up" then
        parts[#parts + 1] = _tr("sf_rf_effect_disease_up", "more disease")
    end
    if #parts == 0 then
        return _tr("sf_rf_effect_neutral", "no change")
    end
    return table.concat(parts, ", ")
end

function RotationPlannerData.cropLabel(name)
    if name == nil or name == "" then
        return _tr("sf_rp_no_crop", "-")
    end
    if SoilUtils ~= nil and SoilUtils.getCropDisplayName ~= nil then
        return SoilUtils.getCropDisplayName(name) or name
    end
    return name
end

--- One-line standing for farm-wide glance.
function RotationPlannerData.standingLine(info)
    if info == nil then
        return _tr("sf_rp_standing_unknown", "Unknown"), "unknown"
    end
    local status = info.rotationStatus
    local word, kind = RotationPlannerData.statusWord(status)
    local c1 = RotationPlannerData.cropLabel(info.lastCrop)
    local c2 = RotationPlannerData.cropLabel(info.lastCrop2)
    local story
    if info.lastCrop3 ~= nil and info.lastCrop3 ~= "" then
        local c3 = RotationPlannerData.cropLabel(info.lastCrop3)
        story = string.format("%s / %s / %s", c1, c2, c3)
    elseif info.lastCrop ~= nil and info.lastCrop ~= "" then
        story = string.format("%s / %s", c1, c2)
    else
        story = _tr("sf_rp_no_history", "No crop history yet")
        word = _tr("sf_rp_status_unknown", "Unknown")
        kind = "unknown"
    end
    if info.rotationBonusDaysLeft ~= nil and tonumber(info.rotationBonusDaysLeft) ~= nil
        and tonumber(info.rotationBonusDaysLeft) > 0 then
        story = story .. " · " .. string.format(
            _tr("sf_rp_bonus_days", "bonus %dd"),
            math.floor(tonumber(info.rotationBonusDaysLeft))
        )
    end
    return word .. " · " .. story, kind
end
