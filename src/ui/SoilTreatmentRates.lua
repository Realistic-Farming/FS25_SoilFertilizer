-- =========================================================
-- FS25 Soil & Fertilizer - Shared treatment rate helpers
-- =========================================================
-- Used by SoilTreatmentDialog and the RF PDA under-row expand.
-- Esc RF PRODUCTS table: preferred product first, ops-ladder sort,
-- dry/liquid method class from BASE_RATES.unit, l10n (no hardcoded EN).
-- Hang fence: callers keep <=8 fixed Text rows (no SmoothList).
-- =========================================================

SoilTreatmentRates = SoilTreatmentRates or {}

local function tr(key, fallback)
    if g_i18n ~= nil then
        local ok, text = pcall(function() return g_i18n:getText(key) end)
        if ok and type(text) == "string" and text ~= "" then
            local lower = text:lower()
            if lower ~= tostring(key):lower()
                and text ~= ("$l10n_" .. key)
                and not lower:find("^missing%s")
                and not lower:find("^missing_")
            then
                return text
            end
        end
    end
    return fallback or key
end

local function fmt(key, fallback, ...)
    local tpl = tr(key, fallback)
    local ok, text = pcall(string.format, tpl, ...)
    if ok then
        return text
    end
    return tpl
end

--- Application class hint from BASE_RATES.unit only (not a store tool).
---@param profileKey string
---@return string|nil "spreader" | "sprayer/tank" | nil
function SoilTreatmentRates.methodClassHint(profileKey)
    if profileKey == nil or SoilConstants == nil then
        return nil
    end
    local baseRate = SoilConstants.SPRAYER_RATE and SoilConstants.SPRAYER_RATE.BASE_RATES
        and SoilConstants.SPRAYER_RATE.BASE_RATES[profileKey]
    if baseRate == nil then
        return nil
    end
    if baseRate.unit == "dry" then
        return tr("rf_pda_treat_method_dry", "spreader")
    end
    return tr("rf_pda_treat_method_liquid", "sprayer/tank")
end

local function productWithHow(profileKey, howHint)
    local how = howHint or SoilTreatmentRates.methodClassHint(profileKey)
    if how == nil or how == "" then
        return profileKey
    end
    return fmt("rf_pda_treat_prod_with_how", "%s · %s", profileKey, how)
end

--- Returns "PRODUCTNAME 220 kg/ha (1056 kg)" or nil if profile missing / no deficit.
---@param profileKey string
---@param nutrientKey string
---@param deficit number
---@param rrMult number
---@param fieldArea number
---@return string|nil
function SoilTreatmentRates.rateString(profileKey, nutrientKey, deficit, rrMult, fieldArea)
    if deficit == nil or deficit <= 0 then return nil end
    if SoilConstants == nil then return nil end
    local profile  = SoilConstants.FERTILIZER_PROFILES and SoilConstants.FERTILIZER_PROFILES[profileKey]
    local baseRate = SoilConstants.SPRAYER_RATE and SoilConstants.SPRAYER_RATE.BASE_RATES
        and SoilConstants.SPRAYER_RATE.BASE_RATES[profileKey]
    if not profile or not profile[nutrientKey] or profile[nutrientKey] == 0 then return nil end

    local coeff     = profile[nutrientKey]
    local ratePerHa = deficit * 1000 / (coeff * (rrMult or 1.0))
    local total     = ratePerHa * (fieldArea or 1.0)
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

--- Structured rate parts for RF PDA PRODUCTS table (F7).
---@return table|nil { product, rate, total, method }
function SoilTreatmentRates.rateParts(profileKey, nutrientKey, deficit, rrMult, fieldArea)
    if deficit == nil or deficit <= 0 then return nil end
    if SoilConstants == nil then return nil end
    local profile  = SoilConstants.FERTILIZER_PROFILES and SoilConstants.FERTILIZER_PROFILES[profileKey]
    local baseRate = SoilConstants.SPRAYER_RATE and SoilConstants.SPRAYER_RATE.BASE_RATES
        and SoilConstants.SPRAYER_RATE.BASE_RATES[profileKey]
    if not profile or not profile[nutrientKey] or profile[nutrientKey] == 0 then return nil end

    local coeff     = profile[nutrientKey]
    local ratePerHa = deficit * 1000 / (coeff * (rrMult or 1.0))
    local total     = ratePerHa * (fieldArea or 1.0)
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

    return {
        product = profileKey,
        rate = string.format("%d %s", displayRate, unit),
        total = string.format("%d %s", displayTotal, totalUnit),
        method = SoilTreatmentRates.methodClassHint(profileKey),
    }
end

--- Builds a two-product action string for a nutrient.
---@return string
function SoilTreatmentRates.nutrientActionText(currentVal, targetVal, rrMult, fieldArea, products, staticFallback)
    local deficit = math.max(0, (targetVal or 0) - (currentVal or 0))
    local parts = {}
    for _, prod in ipairs(products or {}) do
        local s = SoilTreatmentRates.rateString(prod[1], prod[2], deficit, rrMult, fieldArea)
        if s then parts[#parts + 1] = s end
    end
    if #parts == 0 then return staticFallback or "" end
    return table.concat(parts, "  ·  ")
end

local NUT_ORDER = { N = 1, P = 2, K = 3, pH = 1, Weed = 1, Pest = 2, Disease = 3, OM = 1 }

local function sortRank(row)
    -- Ops ladder: protection → pH → NPK (poor before fair; N→P→K) → OM.
    local group = row.sortGroup or 9
    local sev = row.sortSev or 9
    local nut = NUT_ORDER[row.nutrient] or 9
    local prefer = row.isAlternate and 1 or 0
    return group * 1000 + sev * 100 + nut * 10 + prefer
end

local function sortPlanRows(rows)
    table.sort(rows, function(a, b)
        return sortRank(a) < sortRank(b)
    end)
    return rows
end

--- Append structured product rows for one nutrient (F7 table).
--- First product in pair = preferred; second = alternate ("or …").
local function appendNutrientRows(rows, nutrient, currentVal, targetVal, rrMult, fieldArea, products, staticFallback, colorKey, sortGroup, sortSev)
    local deficit = math.max(0, (targetVal or 0) - (currentVal or 0))
    local added = 0
    for idx, prod in ipairs(products or {}) do
        local parts = SoilTreatmentRates.rateParts(prod[1], prod[2], deficit, rrMult, fieldArea)
        if parts then
            local isAlt = idx > 1
            local name = parts.product
            if isAlt then
                name = fmt("rf_pda_treat_or", "or %s", parts.product)
            end
            if parts.method and parts.method ~= "" then
                name = fmt("rf_pda_treat_prod_with_how", "%s · %s", name, parts.method)
            end
            local baseRate = SoilConstants.SPRAYER_RATE and SoilConstants.SPRAYER_RATE.BASE_RATES
                and SoilConstants.SPRAYER_RATE.BASE_RATES[parts.product]
            local isDry = baseRate and baseRate.unit == "dry"
            rows[#rows + 1] = {
                nutrient = nutrient,
                product = name,
                rate = parts.rate,
                total = parts.total,
                method = parts.method,
                colorKey = colorKey or "fair",
                profileKey = parts.product,
                isAlternate = isAlt,
                sortGroup = sortGroup or 3,
                sortSev = sortSev or 1,
                nextHow = isDry
                    and tr("rf_pda_treat_next_how_dry", "buy in shop Products, load a dry spreader, cover the field")
                    or tr("rf_pda_treat_next_how_liquid", "buy in shop Products, fill a sprayer/tank, cover the field"),
            }
            added = added + 1
        end
    end
    if added == 0 and staticFallback ~= nil and staticFallback ~= "" then
        rows[#rows + 1] = {
            nutrient = nutrient,
            product = staticFallback,
            rate = "",
            total = "",
            colorKey = colorKey or "fair",
            isAlternate = false,
            sortGroup = sortGroup or 3,
            sortSev = sortSev or 1,
        }
    end
end

local function addStaticRow(rows, nutrient, productText, colorKey, sortGroup, sortSev, nextHow, profileKey, isAlt)
    rows[#rows + 1] = {
        nutrient = nutrient,
        product = productText,
        rate = "",
        total = "",
        colorKey = colorKey or "fair",
        profileKey = profileKey,
        isAlternate = isAlt == true,
        sortGroup = sortGroup or 9,
        sortSev = sortSev or 0,
        nextHow = nextHow,
    }
end

--- Collect unsorted plan rows for a field (shared by lines / table / next tip).
local function collectPlanRows(fieldId)
    local rows = {}
    local sfm = g_SoilFertilityManager
    if fieldId == nil or sfm == nil or sfm.soilSystem == nil or SoilConstants == nil then
        return rows, nil
    end

    local ok, info = pcall(function() return sfm.soilSystem:getFieldInfo(fieldId) end)
    if not ok or info == nil then
        return rows, nil
    end

    local thresh  = SoilConstants.STATUS_THRESHOLDS or {}
    local fieldArea = info.fieldArea or 1.0
    local rrIdx = (sfm.settings and sfm.settings.replenishmentRate) or 3
    local rrMult = (SoilConstants.DIFFICULTY and SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS
        and SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[rrIdx]) or 1.0

    local ct = info.cropTargets
    local targetN = (ct and ct.N and ct.N.opt) or (thresh.nitrogen and thresh.nitrogen.fair) or 50
    local targetP = (ct and ct.P and ct.P.opt) or (thresh.phosphorus and thresh.phosphorus.fair) or 45
    local targetK = (ct and ct.K and ct.K.opt) or (thresh.potassium and thresh.potassium.fair) or 40

    local nPoor = (thresh.nitrogen and thresh.nitrogen.poor) or 30
    local nFair = (thresh.nitrogen and thresh.nitrogen.fair) or 50
    local pPoor = (thresh.phosphorus and thresh.phosphorus.poor) or 25
    local pFair = (thresh.phosphorus and thresh.phosphorus.fair) or 45
    local kPoor = (thresh.potassium and thresh.potassium.poor) or 20
    local kFair = (thresh.potassium and thresh.potassium.fair) or 40

    local nVal = info.nitrogen and info.nitrogen.value or 0
    if nVal < nPoor then
        appendNutrientRows(rows, "N", nVal, targetN, rrMult, fieldArea,
            { {"UREA","N"}, {"UAN32","N"} },
            tr("sf_treat_action_n_poor", "Apply UAN32, UREA, or ANHYDROUS."), "poor", 3, 0)
    elseif nVal < nFair then
        appendNutrientRows(rows, "N", nVal, targetN, rrMult, fieldArea,
            { {"AMS","N"}, {"AN","N"} },
            tr("sf_treat_action_n_fair", "Apply AMS or STARTER fertilizer."), "fair", 3, 1)
    end

    local pVal = info.phosphorus and info.phosphorus.value or 0
    if pVal < pPoor then
        appendNutrientRows(rows, "P", pVal, targetP, rrMult, fieldArea,
            { {"MAP","P"}, {"DAP","P"} },
            tr("sf_treat_action_p_poor", "Apply MAP or DAP (Phosphorus)."), "poor", 3, 0)
    elseif pVal < pFair then
        appendNutrientRows(rows, "P", pVal, targetP, rrMult, fieldArea,
            { {"LIQUID_MAP","P"}, {"LIQUID_DAP","P"} },
            tr("sf_treat_action_p_fair", "Top-up with Liquid MAP, Liquid DAP, or DAP (P)."), "fair", 3, 1)
    end

    local kVal = info.potassium and info.potassium.value or 0
    if kVal < kPoor then
        appendNutrientRows(rows, "K", kVal, targetK, rrMult, fieldArea,
            { {"POTASH","K"}, {"LIQUID_POTASH","K"} },
            tr("sf_treat_action_k_poor", "Apply POTASH (Potassium)."), "poor", 3, 0)
    elseif kVal < kFair then
        appendNutrientRows(rows, "K", kVal, targetK, rrMult, fieldArea,
            { {"POTASH","K"}, {"LIQUID_POTASH","K"} },
            tr("sf_treat_action_k_fair", "Top-up with Liquid Potash or Potash (K)."), "fair", 3, 1)
    end

    local ph = math.floor(((info.pH or 7.0) * 10) + 0.5) / 10
    if ph < 6.5 then
        addStaticRow(rows, "pH",
            productWithHow("LIME", tr("rf_pda_treat_method_dry", "spreader")),
            "poor", 2, 0,
            tr("rf_pda_treat_next_how_lime", "spread with a dry fertilizer spreader"),
            "LIME", false)
        addStaticRow(rows, "pH",
            fmt("rf_pda_treat_or", "or %s", productWithHow("LIQUIDLIME", tr("rf_pda_treat_method_liquid", "sprayer/tank"))),
            "poor", 2, 0,
            tr("rf_pda_treat_next_how_liq_lime", "apply with a sprayer/tank"),
            "LIQUIDLIME", true)
    elseif ph > 7.5 then
        addStaticRow(rows, "pH",
            productWithHow("GYPSUM", tr("rf_pda_treat_method_dry", "spreader")),
            "fair", 2, 1,
            tr("rf_pda_treat_next_how_gypsum", "spread with a dry fertilizer spreader"),
            "GYPSUM", false)
    end

    local om = info.organicMatter or 3.5
    if om < 3.0 then
        addStaticRow(rows, "OM",
            tr("rf_pda_treat_om_low", "MANURE / COMPOST / chop straw · spread or leave residue"),
            "poor", 4, 0,
            tr("rf_pda_treat_next_how_om", "spread manure/compost or leave chopped straw"),
            nil, false)
    elseif om < 4.0 then
        addStaticRow(rows, "OM",
            tr("rf_pda_treat_om_fair", "Maintain organic inputs (manure / compost / straw)"),
            "fair", 4, 1,
            tr("rf_pda_treat_next_how_om", "spread manure/compost or leave chopped straw"),
            nil, false)
    end

    local pThresh = 20
    if (info.weedPressure or 0) >= pThresh then
        local weedText = info.herbicideActive
            and tr("rf_pda_treat_weed_active", "Herbicide still active - recheck later")
            or tr("rf_pda_treat_weed", "HERBICIDE · sprayer (or mechanical weeder)")
        addStaticRow(rows, "Weed", weedText, "poor", 1, 0,
            tr("rf_pda_treat_next_how_weed", "spray (or use a weeder)"),
            "HERBICIDE", false)
    end
    if (info.pestPressure or 0) >= pThresh then
        local pestText = info.insecticideActive
            and tr("rf_pda_treat_pest_active", "Insecticide still active - recheck later")
            or tr("rf_pda_treat_pest", "INSECTICIDE · sprayer")
        addStaticRow(rows, "Pest", pestText, "poor", 1, 0,
            tr("rf_pda_treat_next_how_pest", "spray the field"),
            "INSECTICIDE", false)
    end
    -- Scout-gated only (George veto: do not leak raw diseasePressure).
    if info.shownDiseasePressure ~= nil and (info.shownDiseasePressure or 0) >= pThresh then
        local disText = info.fungicideActive
            and tr("rf_pda_treat_disease_active", "Fungicide still active - recheck later")
            or tr("rf_pda_treat_disease", "FUNGICIDE · sprayer")
        addStaticRow(rows, "Disease", disText, "poor", 1, 0,
            tr("rf_pda_treat_next_how_disease", "spray the field"),
            "FUNGICIDE", false)
    end

    return rows, info
end

--- Build ordered treatment plan lines for a field (for PDA expand / tablet).
---@param fieldId number
---@return table[] list of { label, text, colorKey } colorKey = "poor"|"fair"|"good"
function SoilTreatmentRates.buildPlanLines(fieldId)
    local lines = {}
    local rows = collectPlanRows(fieldId)
    sortPlanRows(rows)

    -- Collapse preferred+alternate into one line per nutrient for the legacy string view.
    local seen = {}
    for _, row in ipairs(rows) do
        local key = row.nutrient
        if not seen[key] then
            seen[key] = true
            local bits = { row.product }
            for _, other in ipairs(rows) do
                if other.nutrient == key and other ~= row then
                    bits[#bits + 1] = other.product
                end
            end
            lines[#lines + 1] = {
                label = row.nutrient,
                text = table.concat(bits, "  ·  "),
                colorKey = row.colorKey or "fair",
            }
        end
    end
    return lines
end

--- Structured PRODUCTS table rows for Esc RF PDA (F7). One row per product.
--- Sorted: protection → pH → NPK poor→fair (N→P→K) → OM. Cap at 8 at fill site.
---@param fieldId number
---@return table[] { nutrient, product, rate, total, colorKey, ... }
function SoilTreatmentRates.buildPlanTableRows(fieldId)
    local rows = collectPlanRows(fieldId)
    return sortPlanRows(rows)
end

--- Short "Do this next" tip for Selected-field line (preferred first product after sort).
---@param fieldId number
---@return string|nil
function SoilTreatmentRates.buildNextStepLine(fieldId)
    local rows, info = collectPlanRows(fieldId)
    if rows == nil or #rows == 0 then
        return nil
    end
    sortPlanRows(rows)

    local tip = nil
    for _, row in ipairs(rows) do
        if not row.isAlternate then
            tip = row
            break
        end
    end
    if tip == nil then
        tip = rows[1]
    end

    local productLabel = tip.profileKey or tip.product or ""
    -- Strip "or " / how suffix for clean Next product name when profileKey present.
    if tip.profileKey then
        productLabel = tip.profileKey
    end

    local how = tip.nextHow or tip.method or ""
    local body
    if tip.rate and tip.rate ~= "" and tip.total and tip.total ~= "" then
        -- Compact: amount + short method class (Selected line is one 22px Text).
        local methodShort = tip.method or how
        body = fmt("rf_pda_treat_next_with_amount", "%s %s (%s total) · %s",
            productLabel, tip.rate, tip.total, methodShort)
    elseif how ~= "" then
        body = fmt("rf_pda_treat_next_no_amount", "%s - %s", productLabel, how)
    else
        body = tostring(productLabel)
    end

    local why = nil
    if tip.sortGroup == 2 then
        why = tr("rf_pda_treat_next_why_ph", "Fix pH before nutrients.")
    elseif tip.sortGroup == 1 then
        why = tr("rf_pda_treat_next_why_protect", "Crop pressure first, then soil.")
    end
    if why and why ~= "" then
        body = body .. " " .. why
    end

    -- Amendment burn: do not lime/manure now when crop would scorch.
    if info and info.amendBurnRisk and (tip.nutrient == "pH" or tip.nutrient == "OM") then
        body = body .. " " .. tr("rf_pda_treat_burn_amend", "Wait: amending now can burn the crop.")
    end

    return body
end
