-- =========================================================
-- FS25 Soil & Fertilizer - CD-15 local disease: one logical day (step 1a)
-- =========================================================
-- CD-15 implementation brief v1.14:
--   :107      ONE elapsed-day clock. With compatible Time Guard, the day is its guarded
--             getCounter("day") only; getContext supplies daysPerPeriod, never a day.
--             Standalone reads environment.currentMonotonicDay and daysPerPeriod.
--             Missing, non-finite or backward time is UNAVAILABLE and commits no
--             elapsed-day effect. currentDay is NEVER the fallback (it wraps), so this
--             does not use SoilFertilitySystem:_currentMonotonicDay (:2216-2220), and
--             nothing here copies Soil's wrapping _dailyBatchDay.
--   :107      Day input captured for d stays d's input; a skipped interval with no
--             captured input is closed UNAVAILABLE by the caller, never replayed with
--             today's weather.
--   :109-111  Local inputs: rotation from the cell's own harvested history; soil health
--             per component only when that component is known (a missing one multiplies
--             by 1 and stays UNKNOWN). SoilDiseaseSystem.soilHealthMult is NOT called,
--             because its pH/N/OM defaults are not the local semantics.
--   :113-135  The daily calculation, exactly the field formula of
--             SoilFertilitySystem.lua:5560-5626 at 80f2b03b, per cell:
--             resistance decay DECAY_MONTHLY^(1/daysPerMonth), below .01 to zero; the
--             dry-day count; drought decay; protection (expiry > day) suppresses growth;
--             growth (base * growthMult * season * crop * tuning * difficulty * soil *
--             rotation * dryMult + rainBonus) * dt, bounded at 100; clear below LOW*.25
--             (a hybrid arms its cooldown); onset at LOW*.5 (the hybrid pre-pass first
--             when its release is live, else the catalogue) with a new identity
--             undiscovered.
--   :115-124  Spread: one cardinal hop per active unprotected source from a snapshot, 4
--             points per admitted pair (the existing amount, SpatialPressures.lua:365),
--             into living, unprotected, wet or conducive, crop-compatible destinations;
--             a clean destination adopts the identity undiscovered and merges each mode
--             by max; the same identity adds pressure and merges by max; a competing
--             identity takes nothing; the first source in (tz, tx, localKey) order wins a
--             clean cell; a newly infected cell is never a same-pass source.
--   :222      The meadow exemption, FieldSentry's meadow flag as the field pass reads it
--             (SoilFertilitySystem.lua:5207-5210, FieldSentry.lua:216-222): resistance
--             decays, history and protection are kept, growth, onset and spread skip.
--             A field whose simulation FieldSentry disables is not settled at all, as the
--             field pass returns first.
-- =========================================================

CD15Day = CD15Day or {}
local D = CD15Day
local G = CD15Grid

D.SPREAD_POINTS = 4        -- SpatialPressures.lua:365, the existing disease spread per pair
D.WET_MOISTURE = 0.75      -- brief :124: wet means >= .75
D.RESISTANCE_FLOOR = 0.01

local isFinite, isInteger = G.isFinite, G.isInteger

-- ---------------------------------------------------------
-- The clock
-- ---------------------------------------------------------
local function timeGuard()
    local m = g_currentMission
    local tg = (m ~= nil and m.timeGuard) or g_timeGuard
    if type(tg) == "table" and type(tg.getCounter) == "function" then return tg end
    return nil
end

--- The current CD-15 day. Returns (day, nil, source) or (nil, reason, source).
---@param previousDay number|nil the last day this model accepted
function D.readDay(previousDay)
    local tg = timeGuard()
    local day, source = nil, nil
    if tg ~= nil then
        source = "TIMEGUARD"
        local ok, d = pcall(tg.getCounter, tg, "day")
        if ok then day = d end
    else
        source = "ENVIRONMENT"
        local env = g_currentMission ~= nil and g_currentMission.environment or nil
        day = env ~= nil and env.currentMonotonicDay or nil
    end
    if not isInteger(day) or day < 0 then return nil, "DAY_UNAVAILABLE", source end
    if previousDay ~= nil and day < previousDay then return nil, "DAY_BACKWARD", source end
    return day, nil, source
end

--- daysPerPeriod: Time Guard's context when it carries a real value, else the
--- environment's. Nil when neither does.
function D.readDaysPerMonth()
    local tg = timeGuard()
    if tg ~= nil and type(tg.getContext) == "function" then
        local ok, ctx = pcall(tg.getContext, tg)
        if ok and type(ctx) == "table" and isFinite(ctx.daysPerPeriod) and ctx.daysPerPeriod > 0 then return ctx.daysPerPeriod end
    end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local d = env ~= nil and env.daysPerPeriod or nil
    if isFinite(d) and d > 0 then return d end
    return nil
end

-- SoilFertilitySystem.lua:39-44 (a file-local there), the same resolution.
local function tuningMult(settings, settingId, lutKey)
    local idx = (settings and settings[settingId]) or 3
    local lut = SoilConstants.TUNING and SoilConstants.TUNING[lutKey]
    if lut then return lut[idx] or lut[3] or 1.0 end
    return 1.0
end

--- Capture logical day d's inputs once, at the server daily settlement. Returns the
--- input, or nil and a reason (the day then closes UNAVAILABLE).
function D.captureInput(system, day)
    local dpm = D.readDaysPerMonth()
    if dpm == nil then return nil, "DAYS_PER_PERIOD_UNAVAILABLE" end
    if type(system) ~= "table" or type(system.getEffectiveRainScale) ~= "function" then return nil, "NO_RAIN_SOURCE" end
    local okR, rs = pcall(system.getEffectiveRainScale, system)
    if not okR or not isFinite(rs) then return nil, "RAIN_UNAVAILABLE" end
    local settings = system.settings or {}
    local dp = SoilConstants.DISEASE_PRESSURE
    local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[settings.diseaseMoisture or 2] or SoilConstants.DISEASE_CLIMATE_MOISTURE[2]
    local diff = SoilConstants.DISEASE_DIFFICULTY[settings.diseaseDifficulty or 2] or SoilConstants.DISEASE_DIFFICULTY[2]
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local season = env ~= nil and env.currentSeason or nil
    return {
        day = day, daysPerMonth = dpm, rainScale = rs,
        isWet = rs > SoilConstants.RAIN.MIN_RAIN_THRESHOLD,
        season = season, isCool = season ~= 2,   -- the existing cool proxy (SoilFertilitySystem.lua:2378-2386)
        diseaseEnabled = settings.diseasePressure == true,
        cropRotation = settings.cropRotation == true,
        growthMult = cm.growthMult, dryThreshold = cm.dryThreshold, dryDecayMult = cm.dryDecayMult, rainBonusMult = cm.rainBonusMult,
        pressureMult = (diff and diff.pressureMult) or 1.0,
        tuningDiseaseGrowth = tuningMult(settings, "tuningDiseaseGrowth", "ZERO_MULT"),
        hybridLive = ReleaseGate ~= nil and type(ReleaseGate.isSystemLive) == "function" and ReleaseGate.isSystemLive("cd10_hybrids") == true,
        decayPerDay = SoilConstants.RESISTANCE.DECAY_MONTHLY ^ (1 / dpm),
        low = dp.LOW or 20,
    }
end

-- ---------------------------------------------------------
-- Local inputs (:109-111, :131)
-- ---------------------------------------------------------
--- Soil health from each component only when it is known. Returns (mult, coverage)
--- with coverage KNOWN, PARTIAL or UNKNOWN.
function D.localSoilHealthMult(soil)
    local sh = SoilConstants.DISEASE_SOIL_HEALTH
    if sh == nil or type(soil) ~= "table" then return 1.0, "UNKNOWN" end
    local mult, known = 1.0, 0
    if isFinite(soil.pH) then
        known = known + 1
        if soil.pH < sh.LOW_PH_THRESHOLD then mult = mult * sh.LOW_PH_MULT end
    end
    if isFinite(soil.nitrogen) then
        known = known + 1
        if soil.nitrogen > sh.HIGH_N_THRESHOLD then mult = mult * sh.HIGH_N_MULT end
    end
    if isFinite(soil.organicMatter) then
        known = known + 1
        if soil.organicMatter >= sh.OM_GOOD_THRESHOLD then mult = mult * sh.OM_GOOD_MULT end
    end
    return mult, (known == 3 and "KNOWN") or (known == 0 and "UNKNOWN") or "PARTIAL"
end

--- Rotation from the cell's own harvested history, newest first (:109). Missing
--- history is neutral 1.
function D.localRotationMult(cell)
    local h = cell.cropHistory
    if h == nil or h[1] == nil then return 1.0 end
    return SoilDiseaseSystem.rotationMult({
        lastCrop = h[1].cropName,
        lastCrop2 = h[2] ~= nil and h[2].cropName or nil,
        lastCrop3 = h[3] ~= nil and h[3].cropName or nil,
    })
end

--- A deterministic onset seed with the field id, the fine cell and the day (:120).
--- Float arithmetic, so a large map never overflows an integer.
function D.seed(fieldId, gx, gz, day)
    return (isFinite(fieldId) and fieldId or 0) * 1000.0 + day + gx * 0.6180339887 + gz * 0.4142135623
end

--- Protection suppresses growth and spread while a mode's expiry lies after the day
--- (compared, never decremented, :122). PLACEHOLDER: :122 and :129 say a QUALIFIED mode,
--- and which modes qualify is the treatment's to define (step 3). Nothing writes
--- protection before then, so any mode counts until step 3 narrows it.
function D.isProtected(cell, day)
    for _, expiry in pairs(cell.protection) do
        if expiry > day then return true end
    end
    return false
end

-- ---------------------------------------------------------
-- One cell, one logical day (:127-133)
-- ---------------------------------------------------------
local function finish(c, day, outcome)
    c.lastSettledDay = day
    c.sourceRevision = c.sourceRevision + 1
    return outcome
end

--- Settle one cell through logical day input.day, in place. ci carries the cell's own
--- local facts: { soil = {pH, nitrogen, organicMatter}, meadow, disabled, fieldId }.
--- Returns the outcome: DISABLED_FIELD, MEADOW, DISABLED_SETTING or SETTLED.
function D.settleCell(c, gx, gz, input, ci)
    ci = ci or {}
    local day = input.day
    -- A field whose simulation is disabled is not settled at all (the field pass returns
    -- before its resistance decay).
    if ci.disabled then return finish(c, day, "DISABLED_FIELD") end
    for mode, v in pairs(c.resistance) do
        if v > 0 then
            local nv = v * input.decayPerDay
            if nv < D.RESISTANCE_FLOOR then nv = 0 end
            c.resistance[mode] = nv
        end
    end
    if ci.meadow then return finish(c, day, "MEADOW") end
    if not input.diseaseEnabled then return finish(c, day, "DISABLED_SETTING") end

    local dp = SoilConstants.DISEASE_PRESSURE
    if input.isWet then c.dryDayCount = 0 else c.dryDayCount = c.dryDayCount + 1 end
    local living = c.cropName ~= nil
    local pressure = c.pressure
    local dt = 1 / input.daysPerMonth
    local dry = input.dryThreshold * input.daysPerMonth
    local drought = dry * (dp.DROUGHT_THRESHOLD_MULT or 2.0)
    if c.dryDayCount >= drought then
        c.pressure = math.max(0, pressure - dp.DRY_DECAY_RATE * input.dryDecayMult * dt)
    elseif D.isProtected(c, day) then
        -- Qualified protection suppresses growth; pressure does not clear without control.
    else
        -- :129's formula applies to every evaluated cell, a living crop or not; an unknown
        -- crop gets no crop-specific modifier (:131), which is neutral, as the field model
        -- grows on any active field whatever its crop (SoilFertilitySystem.lua:5594-5597).
        local base
        if     pressure < dp.LOW    then base = dp.GROWTH_RATE_LOW
        elseif pressure < dp.MEDIUM then base = dp.GROWTH_RATE_MID
        elseif pressure < dp.HIGH   then base = dp.GROWTH_RATE_HIGH
        else                             base = dp.GROWTH_RATE_PEAK
        end
        local seasonMult = 1.0
        if     input.season == 1 then seasonMult = dp.SEASONAL_SPRING
        elseif input.season == 2 then seasonMult = dp.SEASONAL_SUMMER
        elseif input.season == 3 then seasonMult = dp.SEASONAL_FALL
        elseif input.season == 4 then seasonMult = dp.SEASONAL_WINTER
        end
        local cropMult = living and (dp.CROP_SUSCEPTIBILITY[string.lower(c.cropName)] or 1.0) or 1.0
        local soilMult = D.localSoilHealthMult(ci.soil)
        local rotMult = input.cropRotation and D.localRotationMult(c) or 1.0
        local rainBonus = input.isWet and (dp.RAIN_BONUS * input.rainBonusMult) or 0
        local dryMult = (c.dryDayCount >= dry) and (dp.DRY_GROWTH_MULT or 0.40) or 1.0
        c.pressure = math.min(100, pressure + ((base * input.growthMult * seasonMult * cropMult * input.tuningDiseaseGrowth
            * input.pressureMult * soilMult * rotMult * dryMult) + rainBonus) * dt)
    end

    -- The identity over the settled pressure.
    local low = input.low
    if c.diseaseName ~= nil and c.pressure < low * 0.25 then
        if HybridStrains ~= nil and HybridStrains.isHybrid(c.diseaseName) then
            c.hybridCooldownExpiryDay = day + HybridStrains.cooldownDays(input.daysPerMonth)
        end
        c.diseaseName = nil
        c.discovered = false
    elseif c.diseaseName == nil and living and c.pressure >= low * 0.5 then
        local id = nil
        if input.hybridLive and HybridStrains ~= nil then
            id = HybridStrains.selectOnset({ resistance = c.resistance, lastCrop = c.cropName, hybridBlockedUntilDay = c.hybridCooldownExpiryDay }, day)
        end
        if id == nil then
            id = SoilDiseaseSystem.selectDisease(c.cropName, input.season, input.isWet, input.isCool, D.seed(ci.fieldId, gx, gz, day))
        end
        if id ~= nil and G.isDiseaseName(id) then
            c.diseaseName = id
            c.discovered = false
        end
    end
    return finish(c, day, "SETTLED")
end

-- ---------------------------------------------------------
-- Spread (:115-124)
-- ---------------------------------------------------------
--- Does this catalogue disease belong to this crop? A hybrid belongs to the crop's
--- family complex (HybridStrains.strainForPair's rule).
function D.cropCompatible(diseaseName, cropName)
    if diseaseName == nil or cropName == nil then return false end
    if HybridStrains ~= nil and HybridStrains.isHybrid(diseaseName) then
        return HybridStrains.strainForPair({ lastCrop = cropName }) == diseaseName
    end
    for _, id in ipairs(SoilDiseaseSystem.cropDiseases(cropName) or {}) do
        if id == diseaseName then return true end
    end
    return false
end

--- The day's source snapshot: every active, unprotected cell, in (tz, tx, localKey)
--- order, with a detached copy of its identity and resistance.
function D.snapshotSources(store, day)
    local out = {}
    for _, e in ipairs(store:orderedCells()) do
        local c = store:get(e.gx, e.gz)
        if c ~= nil and c.diseaseName ~= nil and not D.isProtected(c, day) then
            local res = {}
            for k, v in pairs(c.resistance) do res[k] = v end
            out[#out + 1] = { gx = e.gx, gz = e.gz, tx = e.tx, tz = e.tz, localKey = e.localKey, diseaseName = c.diseaseName, resistance = res }
        end
    end
    return out
end

D.HOPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }   -- SpatialPressures.lua:345's order

local function mergeMax(into, from)
    for mode, v in pairs(from) do
        if (into[mode] or 0) < v then into[mode] = v end
    end
end

--- Apply one source's hops. admits(dest, gx, gz, diseaseName) says whether a
--- destination may receive this source's disease. Sources run in (tz, tx, localKey)
--- order, and a clean destination takes the identity in place on the first admitted
--- hop, so a later source of another identity finds it competing and does nothing.
--- Returns the pairs applied.
function D.spreadFrom(store, source, admits)
    local applied = 0
    for _, h in ipairs(D.HOPS) do
        local gx, gz = source.gx + h[1], source.gz + h[2]
        local dest = (gx >= 0 and gz >= 0) and store:get(gx, gz) or nil
        if dest ~= nil and admits(dest, gx, gz, source.diseaseName) then
            local same = dest.diseaseName == source.diseaseName
            if dest.diseaseName == nil then
                dest.diseaseName = source.diseaseName
                dest.discovered = false
                same = true
            end
            if same then
                dest.pressure = math.min(100, dest.pressure + D.SPREAD_POINTS)
                mergeMax(dest.resistance, source.resistance)
                dest.sourceRevision = dest.sourceRevision + 1
                applied = applied + 1
            end
        end
    end
    return applied
end
