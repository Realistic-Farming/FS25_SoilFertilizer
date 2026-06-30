-- =========================================================
-- FS25 Soil & Fertilizer - Disease & Chemical System (pure logic)
-- =========================================================
-- Stateless helpers over the data tables in Constants.lua:
--   • DISEASE_DEFS / DISEASE_REGISTRY   - named crop-specific diseases
--   • FUNGICIDE_CATALOG                 - menu-selectable chemicals + effectiveness
--   • DISEASE_TREATMENT / DIFFICULTY    - timing, weather, stage, difficulty gates
--
-- NOTHING here touches game state. Every function takes plain arguments and returns
-- plain values, so the whole module is exercised by the fengari self-test suite.
-- Stateful application (cost, save, broadcast) lives in SoilFertilitySystem.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilDiseaseSystem
SoilDiseaseSystem = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Deterministic 0..1 hash (fract(sin) - a real per-seed hash, not an affine LCG ramp;
-- see the #632 uniform-soil pitfall). Stable for a given integer seed.
local function hash01(n)
    local x = math.sin((n + 1) * 12.9898) * 43758.5453
    return x - math.floor(x)
end

-- ── Data accessors ────────────────────────────────────────

--- Candidate disease ids for a crop (registry entry or the generic fallback).
---@param cropName string|nil internal fruit name (any case)
---@return table list of disease ids
function SoilDiseaseSystem.cropDiseases(cropName)
    if cropName and cropName ~= "" then
        local list = SoilConstants.DISEASE_REGISTRY[string.lower(cropName)]
        if list then return list end
    end
    return SoilConstants.DISEASE_REGISTRY_DEFAULT
end

---@param id string
---@return table|nil
function SoilDiseaseSystem.diseaseDef(id)
    return id and SoilConstants.DISEASE_DEFS[id] or nil
end

---@param id string
---@return table|nil
function SoilDiseaseSystem.chemical(id)
    return id and SoilConstants.FUNGICIDE_CATALOG[id] or nil
end

--- Base control rate of a chemical against a disease (0..1), before timing/stage/weather.
---@param chemId string
---@param diseaseId string
---@return number
function SoilDiseaseSystem.effectiveness(chemId, diseaseId)
    local chem = SoilConstants.FUNGICIDE_CATALOG[chemId]
    local def  = SoilConstants.DISEASE_DEFS[diseaseId]
    if not chem or not def then return 0 end
    local rate = chem.eff and chem.eff[def.cat]
    if rate == nil then return SoilConstants.DISEASE_DEFAULT_EFFECTIVENESS end
    return rate
end

--- Best / second / budget foliar chemical recommendations for a disease.
--- Seed treatments are excluded (they are pre-plant, not in-season curatives).
---@param diseaseId string
---@return table {best, second, budget} of chemical ids (or nil entries)
function SoilDiseaseSystem.recommend(diseaseId)
    local def = SoilConstants.DISEASE_DEFS[diseaseId]
    if not def then return { best=nil, second=nil, budget=nil } end

    local ranked = {}
    for _, chemId in ipairs(SoilConstants.FUNGICIDE_ORDER) do
        local chem = SoilConstants.FUNGICIDE_CATALOG[chemId]
        if chem and not chem.seedTreatment then
            local rate = (chem.eff and chem.eff[def.cat]) or SoilConstants.DISEASE_DEFAULT_EFFECTIVENESS
            ranked[#ranked + 1] = { id = chemId, rate = rate, cost = chem.costPerHa or 9999 }
        end
    end
    -- Sort by control rate desc, then cheaper first as a tie-break.
    table.sort(ranked, function(a, b)
        if a.rate ~= b.rate then return a.rate > b.rate end
        return a.cost < b.cost
    end)

    -- Budget = cheapest product that still gives a meaningful (≥ MIN_EFFECTIVE) control.
    local minEff = SoilConstants.DISEASE_TREATMENT.MIN_EFFECTIVE
    local budget = nil
    local cheapest = math.huge
    for _, r in ipairs(ranked) do
        if r.rate >= minEff and r.cost < cheapest then
            cheapest = r.cost
            budget = r.id
        end
    end

    return {
        best   = ranked[1] and ranked[1].id or nil,
        second = ranked[2] and ranked[2].id or nil,
        budget = budget,
    }
end

-- ── Disease selection ─────────────────────────────────────

--- Pick which named disease takes hold, weighted by current conditions.
--- Deterministic for a given seed so it stays stable across reloads / MP clients.
---@param cropName string|nil
---@param season number|nil   1=Spring 2=Summer 3=Fall 4=Winter
---@param isWet boolean        currently wet / recent rain
---@param isCool boolean       cool temperatures (vs warm)
---@param seed number          stable integer (e.g. fieldId*1000 + day)
---@return string|nil diseaseId
function SoilDiseaseSystem.selectDisease(cropName, season, isWet, isCool, seed)
    local candidates = SoilDiseaseSystem.cropDiseases(cropName)
    if not candidates or #candidates == 0 then return nil end

    local weights = {}
    local total = 0
    for i = 1, #candidates do
        local def = SoilConstants.DISEASE_DEFS[candidates[i]]
        local w = 1.0
        if def then
            if def.season and season and season >= 1 and season <= 3 then
                w = w * (def.season[season] or 1.0)
            elseif season == 4 then
                w = w * 0.2  -- winter: little active infection
            end
            -- Wetness preference
            if def.wet ~= nil then
                w = w * ((def.wet == isWet) and 1.5 or 0.7)
            end
            -- Temperature preference (nil = indifferent)
            if def.cool ~= nil then
                w = w * ((def.cool == isCool) and 1.4 or 0.7)
            end
        end
        weights[i] = w
        total = total + w
    end
    if total <= 0 then return candidates[1] end

    local roll = hash01(seed) * total
    local acc = 0
    for i = 1, #candidates do
        acc = acc + weights[i]
        if roll <= acc then return candidates[i] end
    end
    return candidates[#candidates]
end

-- ── Modifiers folded into daily pressure build-up ─────────

--- Soil-health multiplier on disease build-up (acidic + lush = worse, rich OM = better).
---@param field table
---@return number
function SoilDiseaseSystem.soilHealthMult(field)
    local sh = SoilConstants.DISEASE_SOIL_HEALTH
    if not sh or not field then return 1.0 end
    local mult = 1.0
    local ph = field.pH or 6.5
    local n  = field.nitrogen or 50
    local om = field.organicMatter or 3.5
    if ph < sh.LOW_PH_THRESHOLD then mult = mult * sh.LOW_PH_MULT end
    if n  > sh.HIGH_N_THRESHOLD then mult = mult * sh.HIGH_N_MULT end
    if om >= sh.OM_GOOD_THRESHOLD then mult = mult * sh.OM_GOOD_MULT end
    return mult
end

--- Crop-rotation multiplier on disease build-up from the lastCrop history chain.
---@param field table
---@return number
function SoilDiseaseSystem.rotationMult(field)
    local rot = SoilConstants.DISEASE_ROTATION
    local fam = SoilConstants.CROP_FAMILY
    if not rot or not field then return 1.0 end

    local c1 = field.lastCrop  and string.lower(field.lastCrop)  or nil
    local c2 = field.lastCrop2 and string.lower(field.lastCrop2) or nil
    local c3 = field.lastCrop3 and string.lower(field.lastCrop3) or nil
    if not c1 then return 1.0 end

    -- Monoculture: identical crop in the recent chain.
    if c2 == c1 and c3 == c1 then return rot.MONO_3YR_MULT end
    if c2 == c1 then return rot.MONO_2YR_MULT end

    if not c2 then return 1.0 end  -- only one season of history

    local f1 = fam[c1]
    local f2 = fam[c2]
    -- Same family two seasons running = shared pathogens, mild penalty.
    if f1 and f2 and f1 == f2 then return rot.SAME_FAMILY_2 end

    -- A pulse or forage break anywhere in the recent chain suppresses disease cycles.
    local function isBreak(c) local f = c and fam[c]; return f == "pulse" or f == "forage" end
    if isBreak(c2) or isBreak(c3) then return rot.LEGUME_BREAK_MULT end

    -- Three distinct families in a row.
    local f3 = c3 and fam[c3] or nil
    if f3 and f1 and f2 and f1 ~= f2 and f2 ~= f3 and f1 ~= f3 then return rot.ROTATE_3YR_MULT end

    return rot.ROTATE_MULT
end

-- ── Yield severity ────────────────────────────────────────

--- Per-disease severity multiplier applied to the base disease yield penalty tier.
--- Referenced against the engine's PEAK penalty so a -60% disease bites ~2.4× a
--- nominal -25% one, while a -15% mildew bites less. Clamped to keep it sane.
---@param diseaseId string|nil
---@return number
function SoilDiseaseSystem.yieldSeverity(diseaseId)
    local def = SoilConstants.DISEASE_DEFS[diseaseId or ""]
    if not def then return 1.0 end
    local peak = (SoilConstants.DISEASE_PRESSURE and SoilConstants.DISEASE_PRESSURE.YIELD_PENALTY_PEAK) or 0.25
    if peak <= 0 then return 1.0 end
    return clamp((def.yMax or peak) / peak, 0.5, 2.5)
end

-- ── Treatment effectiveness ───────────────────────────────

--- Live growth-stage fraction 0..1 from FS25 integer growth state.
--- FS25 has no Zadoks/BBCH scale - this maps state→fraction so the proposal's
--- "GS 30-50" windows become "mid third of growth".
---@param growthState number|nil
---@param numStates number|nil   max growth states for the fruit
---@return number 0..1
function SoilDiseaseSystem.growthFraction(growthState, numStates)
    if not growthState or not numStates or numStates <= 1 then return 0.5 end
    return clamp((growthState - 1) / (numStates - 1), 0.0, 1.0)
end

--- Timing multiplier: full inside the chemical's window, reduced outside it.
---@param chemId string
---@param growthFrac number|nil  nil = unknown stage (treated as on-window)
---@return number
function SoilDiseaseSystem.timingMult(chemId, growthFrac)
    local chem = SoilConstants.FUNGICIDE_CATALOG[chemId]
    if not chem or not chem.win or growthFrac == nil then return 1.0 end
    if growthFrac >= chem.win[1] and growthFrac <= chem.win[2] then return 1.0 end
    return SoilConstants.DISEASE_TREATMENT.OUT_OF_WINDOW_MULT
end

--- Disease-stage multiplier: early infections treat well, late ones barely.
---@param pressure number 0..100
---@return number
function SoilDiseaseSystem.stageMult(pressure)
    local t = SoilConstants.DISEASE_TREATMENT
    pressure = pressure or 0
    if pressure <= t.STAGE_EARLY_MAX then return t.STAGE_EARLY_EFF end
    if pressure >= t.STAGE_LATE_MIN then return t.STAGE_LATE_EFF end
    local f = (pressure - t.STAGE_EARLY_MAX) / (t.STAGE_LATE_MIN - t.STAGE_EARLY_MAX)
    return t.STAGE_EARLY_EFF + f * (t.STAGE_LATE_EFF - t.STAGE_EARLY_EFF)
end

--- Final control rate (0..1) of applying chemId to diseaseId under given conditions.
--- Combines base effectiveness × timing × disease-stage × difficulty × rain washoff.
---@param chemId string
---@param diseaseId string
---@param opts table {pressure, growthFrac, isRaining, diseaseDifficulty}
---@return number control, table breakdown
function SoilDiseaseSystem.computeControl(chemId, diseaseId, opts)
    opts = opts or {}
    local base = SoilDiseaseSystem.effectiveness(chemId, diseaseId)
    local timing = SoilDiseaseSystem.timingMult(chemId, opts.growthFrac)
    local stage = SoilDiseaseSystem.stageMult(opts.pressure or 0)

    local diff = SoilConstants.DISEASE_DIFFICULTY[opts.diseaseDifficulty or 2]
        or SoilConstants.DISEASE_DIFFICULTY[2]
    local diffMult = diff.fungicideEffMult or 1.0

    local rainMult = 1.0
    if opts.isRaining then rainMult = 1.0 - SoilConstants.DISEASE_TREATMENT.RAIN_PENALTY end

    local control = clamp(base * timing * stage * diffMult * rainMult, 0.0, 1.0)
    return control, { base = base, timing = timing, stage = stage, diff = diffMult, rain = rainMult }
end

SoilLogger.info("Disease & chemical system loaded (%d diseases, %d chemicals)",
    (function() local n=0 for _ in pairs(SoilConstants.DISEASE_DEFS) do n=n+1 end return n end)(),
    #SoilConstants.FUNGICIDE_ORDER)
