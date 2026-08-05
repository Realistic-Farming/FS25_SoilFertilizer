-- =========================================================
-- FS25 Soil & Fertilizer - WHAT THE SKY DID (SF-49)
-- =========================================================
-- Six days down in a dry spell is fit to bale; six days with three showers through
-- it is ruined. The sibling (MATERIAL DOWN) answers how LONG. This one answers
-- what CONDITION.
--
-- A per-cell MATERIAL WETNESS layer (percent moisture, wet basis) written once a
-- day by a three-phase drying pass under a humidity-and-temperature ceiling, wetted
-- by rain and by irrigation, plus a small per-day WATER RECORD so a spoil rule can
-- ask "how many of the last six days brought water".
--
-- THE NAMING FENCE (hard): this mod already ships `advanceWetness` driving
-- COMPACTION from rain, and SeasonalCropStress owns SOIL moisture. Three wetness
-- quantities now exist. Every key and getter here carries MATERIAL, or a future
-- builder will conflate them. `advanceWetness` is NEVER touched from this file.
--
-- SERVER ONLY, like the sibling. Publishes bands; draws nothing.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class MaterialWetness
MaterialWetness = {}
local MaterialWetness_mt = Class(MaterialWetness)

MaterialWetness.LAYER_KEY = "materialWetness"

-- Encoding, mirroring the layer def. Asserted against the store at arm().
local PCT_MIN, PCT_MAX = 0, 100
local RAW_FLOOR        = 32   -- every real reading sits at or above this

-- Exported for the members, which have to exclude the sentinel band on their own
-- calls. It was file-local, so `MaterialWetness.RAW_FLOOR` in a member read nil and
-- the band floor silently became 0 - the sentinel band INCLUDED, which is exactly the
-- read trap SF-49's own comments warn about. One assignment closes it.
MaterialWetness.RAW_FLOOR = RAW_FLOOR
local SENTINEL_RAW     = 24   -- inside the reserved 16-31 band = REFUSAL

-- Drying phase table. RULED 2026-07-31: points of moisture lost per day, wet basis,
-- walking the published 3-to-5-day cure at day grain. Drying is MULTIPLICATIVE but
-- the engine write is ADDITIVE, which is exactly why this is a banded pass rather
-- than one call: each band gets its own subtraction.
MaterialWetness.PHASES = {
    { name = "rapid",        pctLow = 60, pctHigh = 100, dropPerDay = 25 },
    { name = "transitional", pctLow = 40, pctHigh = 60,  dropPerDay = 18 },
    { name = "bound",        pctLow = 0,  pctHigh = 40,  dropPerDay = 6  },
}

-- Soil classes from SeasonalCropStress's shipped SOIL_PARAMS (verified at source
-- 2026-07-31: sandy 1.40 / loamy 1.00 / clay 0.70). The call count is a FUNCTION of
-- the shipped class count, not a constant - a fourth class makes twelve.
MaterialWetness.SOIL_EVAP = { sandy = 1.40, loamy = 1.00, clay = 0.70 }
MaterialWetness.DEFAULT_SOIL_CLASS = "loamy"

-- Composite weather multiplier. RULED 2026-07-31: endpoints 1.3 / 1.0 / 0.45, the
-- agreed ~3x spread between sun-with-dry-soil and cloud-with-wet-soil, lerped over
-- cloud cover and standing soil moisture together. ONE multiplier, deliberately:
-- the literature does not support separate coefficients for the two inputs.
MaterialWetness.WEATHER_MULT = { high = 1.30, mid = 1.00, low = 0.45 }

-- Rain setback. RULED 2026-07-31: +15 points per FULL rain day, scaled by the day's
-- rain fraction. Labelled heuristic - no literature mapping exists for this one.
MaterialWetness.RAIN_SETBACK_PER_DAY = 15

-- How many days of water verdicts the record keeps. A spoil rule asks about the
-- last six; the ring is sized well past that so a member can widen without a
-- migration, and bounded so a long save cannot grow it without limit.
MaterialWetness.WATER_RECORD_DAYS = 30

-- =========================================================
-- EMC ceiling table
-- =========================================================
-- Material cannot dry below its equilibrium moisture content for the current
-- humidity and temperature. Bilinearly interpolated, CLAMPED at the table edges,
-- NEVER extrapolated.
--
-- *** THESE NUMBERS ARE PLACEHOLDERS AND MUST BE RECONCILED BEFORE SHIP. ***
-- The brief fixes the ceiling table as literature-derived (Purdue NRAES-5) and
-- carries it in the workspace SDS, which is not in this repo. The MECHANISM below
-- is what the brief specifies in detail and is what the tests pin; the table is one
-- swap away. These values are plausible hay EMC figures and are NOT the ruled ones.
--
-- The table is indexed in FAHRENHEIT. The engine reports CELSIUS (confirmed from
-- the LUADOC: USE_FAHRENHEIT is a display setting and the unit texts list celsius
-- first; WeatherGuard's own SEASON_TEMP of {12,22,10,2} is Celsius too). The bridge
-- is therefore a real conversion and it happens at EXACTLY ONE SITE below - a
-- Celsius value read as Fahrenheit lands in the wrong row and nothing complains.
MaterialWetness.EMC_TEMPS_F = { 40, 60, 80, 100 }
MaterialWetness.EMC_RH_PCT  = { 20, 40, 60, 80, 90 }
MaterialWetness.EMC_TABLE = {
    { 7.5, 10.8, 14.2, 19.5, 24.0 },   -- 40 F
    { 6.8, 10.0, 13.3, 18.4, 22.7 },   -- 60 F
    { 6.2,  9.3, 12.5, 17.4, 21.5 },   -- 80 F
    { 5.7,  8.7, 11.8, 16.5, 20.4 },   -- 100 F
}
MaterialWetness.EMC_TABLE_IS_PLACEHOLDER = true

-- THE UNIT BRIDGE. One site, on purpose.
function MaterialWetness.celsiusToFahrenheit(c)
    return (tonumber(c) or 0) * 9 / 5 + 32
end

-- Position of `v` within a sorted axis: index of the lower node and the 0-1
-- fraction toward the next. Clamped at both edges, so a value off the end of the
-- table pins to the edge row rather than extrapolating past published data.
local function axisPosition(axis, v)
    if v <= axis[1] then return 1, 0 end
    local n = #axis
    if v >= axis[n] then return n - 1, 1 end
    for i = 1, n - 1 do
        if v <= axis[i + 1] then
            local span = axis[i + 1] - axis[i]
            return i, (span > 0) and ((v - axis[i]) / span) or 0
        end
    end
    return n - 1, 1
end

--- EMC (percent, wet basis) for a humidity and a temperature IN CELSIUS.
--- The conversion to the table's Fahrenheit basis happens here and nowhere else.
function MaterialWetness.emcFor(humidityPct, temperatureC)
    local rh = math.max(0, math.min(100, tonumber(humidityPct) or 0))
    local tF = MaterialWetness.celsiusToFahrenheit(temperatureC)

    local ti, tfrac = axisPosition(MaterialWetness.EMC_TEMPS_F, tF)
    local hi, hfrac = axisPosition(MaterialWetness.EMC_RH_PCT,  rh)

    local t0, t1 = MaterialWetness.EMC_TABLE[ti], MaterialWetness.EMC_TABLE[ti + 1]
    local a = t0[hi] + (t0[hi + 1] - t0[hi]) * hfrac
    local b = t1[hi] + (t1[hi + 1] - t1[hi]) * hfrac
    return a + (b - a) * tfrac
end

-- =========================================================
-- Encoding helpers
-- =========================================================
-- ENCODE THE BOUNDS BEFORE THEY REACH THE FILTER. Passing percentages straight
-- through would put the phase boundaries at roughly 23 and 15 percent instead of 60
-- and 40, and every call-count test would still pass while the curve was wrong.

--- percent (wet basis) -> raw, using the layer's own linear encoding.
--- 60 pct is raw 153, 40 pct is raw 103.
function MaterialWetness.pctToRaw(pct)
    local span = SoilValueMaps.RAW_SPAN
    local clamped = math.max(PCT_MIN, math.min(PCT_MAX, tonumber(pct) or 0))
    local raw = SoilValueMaps.RAW_MIN + math.floor((clamped - PCT_MIN) / (PCT_MAX - PCT_MIN) * span + 0.5)
    if raw < RAW_FLOOR then raw = RAW_FLOOR end
    return raw
end

--- raw -> percent, or nil for the two non-values (no record, and the refusal band).
function MaterialWetness.rawToPct(raw)
    if raw == nil or raw <= 0 then return nil end
    if raw < RAW_FLOOR then return nil end   -- inside the reserved sentinel band
    local span = SoilValueMaps.RAW_SPAN
    return PCT_MIN + (raw - SoilValueMaps.RAW_MIN) / span * (PCT_MAX - PCT_MIN)
end

--- Points of moisture expressed as raw steps (a delta, so no floor applies).
function MaterialWetness.pointsToRawDelta(points)
    local span = SoilValueMaps.RAW_SPAN
    return math.floor((tonumber(points) or 0) / (PCT_MAX - PCT_MIN) * span + 0.5)
end

MaterialWetness.RESULT = {
    OK          = "ok",
    REFUSAL     = "refusal",       -- the sentinel, or a quantity we cannot trust
    NO_MATERIAL = "noMaterial",
    UNAVAILABLE = "unavailable",
}

-- Condition bands the members read. Names, not numbers, so a later balance pass
-- moves the edges without touching a consumer.
MaterialWetness.BANDS = {
    { name = "soaked", floor = 60 },
    { name = "damp",   floor = 40 },
    { name = "curing", floor = 25 },
    { name = "fit",    floor = 0  },
}

-- =========================================================
-- Spoil counts (SF-45): a READER parameter, never a layer one
-- =========================================================
-- How many separate RAIN-DAYS ruin this material. The counts live HERE, in the
-- reader, because the layer is material-blind and the collector is the thing that
-- knows what fill type it just picked up. Putting the count in a layer would make
-- every future material a store change instead of a table row - which is exactly
-- the cost the foundation was built to avoid.
--
-- RULED 2026-07-31. Straw gets one day more than hay because its value is
-- STRUCTURAL, not nutritive: a wetting that ruins feed still leaves usable bedding.
MaterialWetness.SPOIL_RAIN_DAYS = {
    GRASS_WINDROW    = 3,
    DRYGRASS_WINDROW = 3,
    STRAW            = 4,
}

---@return number|nil rainDays  nil = this material has no spoil rule
function MaterialWetness.spoilRainDaysFor(fillTypeName)
    if fillTypeName == nil then return nil end
    return MaterialWetness.SPOIL_RAIN_DAYS[tostring(fillTypeName):upper()]
end

--- THE GOING-OFF VERDICT, derived at READ time from the Water Record.
---
--- `windowDays` is how far back to look. The hay member passes the material's own
--- DAYS DOWN, so the question actually asked is "how many rain-days since this was
--- cut", not "in some fixed recent window". Defaults to the record's full span.
---
--- REFUSAL HONESTY: when the record does not reach back across the whole window we
--- report `known` short of `window` rather than answering from a partial history. A
--- confident "not spoiled" built on three remembered days out of eight is a lie.
---@return table { status, spoiled, waterDays, needed, known, window }
function MaterialWetness:goingOffVerdict(fillTypeName, windowDays, throughDay)
    local R = MaterialWetness.RESULT
    local needed = MaterialWetness.spoilRainDaysFor(fillTypeName)
    if needed == nil then return { status = R.REFUSAL } end

    local window = math.max(1, math.floor(tonumber(windowDays) or MaterialWetness.WATER_RECORD_DAYS))
    local waterDays, known = self:waterDaysInLast(window, throughDay)

    return {
        status    = (known >= window) and R.OK or R.REFUSAL,
        spoiled   = waterDays >= needed,
        waterDays = waterDays,
        needed    = needed,
        known     = known,
        window    = window,
    }
end

-- =========================================================
-- Construction
-- =========================================================

function MaterialWetness.new()
    local self = setmetatable({}, MaterialWetness_mt)
    self.armed        = false
    self.stoodDown    = false
    self.valueMaps    = nil
    self.materialDown = nil
    self.soilSystem   = nil
    self.appliedThroughDay = nil
    -- Water Record: day number -> { water = bool, source = string, derived = bool }.
    -- Verdicts are PERSISTED, never recomputed: the climate roll reads the current
    -- season and weather mode, so an unfrozen past day would change its own answer.
    self.waterRecord  = {}
    self.recordDays   = {}   -- ordered day numbers, oldest first (the ring)
    -- Shelter shape cache, invalidated on the placeable lifecycle.
    self.shelterDirty = true
    self.shelterCache = {}
    return self
end

function MaterialWetness:isArmed()
    return self.armed and not self.stoodDown
end

function MaterialWetness:_standDown(why)
    if self.stoodDown then return end
    self.stoodDown = true
    SoilLogger.warning("[MaterialWetness] STANDING DOWN for this session: %s", tostring(why))
end

--- Bind-time self-check, same shape and same reason as the sibling's.
function MaterialWetness:arm(valueMaps, materialDown, soilSystem)
    self.armed = false
    if g_server == nil then return false end
    if valueMaps == nil or not valueMaps.available then
        SoilLogger.warning("[MaterialWetness] value maps unavailable - WHAT THE SKY DID stands down")
        return false
    end
    if valueMaps.applyRawDeltaToPolygonBand == nil then
        SoilLogger.warning(
            "[MaterialWetness] the SoilValueMaps in scope lacks the SF-49 banded delta - this is the " ..
            "community-fork collision. WHAT THE SKY DID stands down.")
        return false
    end
    if valueMaps:getLayerEntry(MaterialWetness.LAYER_KEY) == nil then
        SoilLogger.warning("[MaterialWetness] layer '%s' did not resolve - stands down", MaterialWetness.LAYER_KEY)
        return false
    end
    if materialDown == nil then
        SoilLogger.warning("[MaterialWetness] the sibling (MATERIAL DOWN) is absent - stands down")
        return false
    end

    self.valueMaps    = valueMaps
    self.materialDown = materialDown
    self.soilSystem   = soilSystem
    self.armed        = true
    self.stoodDown    = false
    if MaterialWetness.EMC_TABLE_IS_PLACEHOLDER then
        SoilLogger.warning(
            "[MaterialWetness] the EMC ceiling table is PLACEHOLDER data pending the ruled NRAES-5 " ..
            "figures; the drying floor is approximate until it is swapped")
    end
    SoilLogger.info("[OK] MaterialWetness armed (server-only)")
    return true
end

-- =========================================================
-- Sky and soil reads (all pull-only, neutral when absent)
-- =========================================================

local function weatherGuard()
    return (g_currentMission ~= nil and g_currentMission.weatherGuard) or nil
end

local function cropStress()
    return (g_currentMission ~= nil and g_currentMission.cropStressManager) or nil
end

--- Current sky. nil means we do not know, and the accrual HOLDS rather than
--- inventing one: no WeatherGuard is not the same as a clear dry day.
function MaterialWetness:readSky()
    local wg = weatherGuard()
    if wg == nil or wg.getCurrentSky == nil then return nil end
    local ok, sky = pcall(function() return wg:getCurrentSky() end)
    if not ok then return nil end
    return sky
end

--- Rain for TODAY only. getEffectiveRain floors its argument at zero, so asking it
--- about yesterday silently answers about today; never ask it about the past.
function MaterialWetness:readRainToday()
    local wg = weatherGuard()
    if wg == nil or wg.getEffectiveRain == nil then return nil end
    local ok, rain = pcall(function() return wg:getEffectiveRain(0) end)
    if not ok then return nil end
    -- getEffectiveRain returns an identical zero-table on ten error paths and on two
    -- honest dry rolls, so a zero is treated as a dry day and ignorance is read from
    -- getCurrentSky's humidityDefaulted flag instead.
    return rain
end

--- Climate for a season. NORMALISED TO 1-BASED AT THE CALL SITE: getClimate rejects
--- anything outside 1-4, and SeasonalCropStress normalises the OTHER way for its own
--- tables, so feeding SCS's spring in here would give a permanently dry spring.
function MaterialWetness:readClimate(season1Based)
    local wg = weatherGuard()
    if wg == nil or wg.getClimate == nil then return nil end
    local s = tonumber(season1Based)
    if s == nil or s < 1 or s > 4 then return nil end
    local ok, climate = pcall(function() return wg:getClimate(s) end)
    if not ok then return nil end
    return climate
end

function MaterialWetness:currentSeason1Based()
    local env = g_currentMission and g_currentMission.environment
    if env == nil then return nil end
    -- Engine basis, used as-is. Season.SPRING is 1 and WeatherGuard indexes its own
    -- 1-based tables with this same value.
    return env.currentSeason
end

--- Which season a PAST day belonged to.
---
--- A sleep across a season turn must not charge every skipped day to the season the
--- player woke up in: waking in autumn after sleeping through summer would price a
--- fortnight of summer drying at autumn's rain fraction.
---
--- Period-aligned approximation: it steps back whole seasons and does not know how
--- far into the current period today sits, so a day within one period of a season
--- boundary can be attributed to the neighbouring season. That error is bounded by
--- one period and always in the right direction of magnitude; the exact form needs a
--- day-in-period accessor and is a refinement, not a correction.
---@return number|nil season1Based
function MaterialWetness:seasonForDay(dayNumber)
    local env = g_currentMission and g_currentMission.environment
    if env == nil then return nil end
    local currentSeason = env.currentSeason
    if currentSeason == nil then return nil end

    local current = tonumber(env.currentMonotonicDay) or dayNumber
    local daysPerPeriod = tonumber(env.daysPerPeriod) or 0
    if daysPerPeriod <= 0 then return currentSeason end

    local daysPerSeason = daysPerPeriod * 3   -- three periods to a season
    local back = math.max(0, current - (tonumber(dayNumber) or current))
    local seasonsBack = math.floor(back / daysPerSeason)
    -- 1-based with wraparound: stepping back from spring lands in winter.
    return ((currentSeason - 1 - seasonsBack) % 4) + 1
end

--- Standing SOIL moisture (0-1) as a drying DRAG. Read through the facade, never
--- the subsystem, and never confused with material wetness: wet ground is not wet hay.
function MaterialWetness:readSoilMoisture(fieldId)
    local cs = cropStress()
    if cs == nil or cs.getMoisture == nil then return nil end
    local ok, m = pcall(function() return cs:getMoisture(fieldId) end)
    if not ok then return nil end
    return m
end

--- Soil class for a field, from SCS. Defaults to loamy (multiplier 1.0) when absent,
--- which is the neutral choice rather than a fast or slow one.
function MaterialWetness:soilClassFor(fieldId)
    local cs = cropStress()
    if cs == nil or cs.getFieldSoilType == nil then return MaterialWetness.DEFAULT_SOIL_CLASS end
    local ok, t = pcall(function() return cs:getFieldSoilType(fieldId) end)
    if not ok or t == nil or MaterialWetness.SOIL_EVAP[t] == nil then
        return MaterialWetness.DEFAULT_SOIL_CLASS
    end
    return t
end

--- The composite weather multiplier: ONE number over cloud cover and soil moisture.
--- Clear sky over dry ground dries fastest; overcast over wet ground slowest.
function MaterialWetness.weatherMultiplier(cloudCoverage, soilMoisture)
    local W = MaterialWetness.WEATHER_MULT
    local cloud = math.max(0, math.min(1, tonumber(cloudCoverage) or 0.5))
    local wet   = math.max(0, math.min(1, tonumber(soilMoisture)  or 0.5))
    -- 0 = the drying-friendly end (clear, dry), 1 = the drying-hostile end.
    local hostility = (cloud + wet) * 0.5
    if hostility <= 0.5 then
        local f = hostility / 0.5
        return W.high + (W.mid - W.high) * f
    end
    local f = (hostility - 0.5) / 0.5
    return W.mid + (W.low - W.mid) * f
end

-- =========================================================
-- Shelter
-- =========================================================
-- The wetting call receives a shape with roofs subtracted. The engine query is a
-- POINT predicate, so it BUILDS the shape rather than filtering the write.
--
-- NEUTRAL MEANS IT WETS. Claiming shelter we cannot verify is the lie that matters:
-- a swath wrongly marked dry survives a storm that should have ruined it.

function MaterialWetness:invalidateShelterCache()
    self.shelterDirty = true
    self.shelterCache = {}
end

--- Is this position under cover? nil when the mask is unavailable, which the caller
--- must treat as "not sheltered".
function MaterialWetness.isSheltered(worldX, worldZ)
    local mission = g_currentMission
    if mission == nil or mission.indoorMask == nil
       or mission.indoorMask.getIsIndoorAtWorldPosition == nil then
        return nil
    end
    local ok, indoor = pcall(function()
        return mission.indoorMask:getIsIndoorAtWorldPosition(worldX, worldZ)
    end)
    if not ok then return nil end
    return indoor == true
end

-- =========================================================
-- The daily accrual: DRY, then WET, then RECORD
-- =========================================================

--- One Time Guard accrual, day cadence, registered at the priority the sibling
--- reserved so this settles AFTER the age tick: time exists before the day's
--- weather is applied to it.
---
--- ctx.proration is ignored (firstPeriodPolicy is "skip", so no partial first
--- period is ever settled; the scheduler's silent default would have been "prorate",
--- which would retroactively wet or dry material that predates the layer).
function MaterialWetness:onConditionAccrual(ctx)
    if not self:isArmed() then return end
    local day = ctx and tonumber(ctx.monotonicDay)
    if day == nil then return end
    if self.appliedThroughDay ~= nil and day <= self.appliedThroughDay then return end

    local boundaries = math.floor(tonumber(ctx.boundariesCrossed) or 1)
    if boundaries < 1 then boundaries = 1 end

    -- The placeable added/removed hook for the shelter cache is a bounced confirm
    -- (there is no in-house precedent - SCS ships three placeables with no lifecycle
    -- handling at all). Until it lands, invalidate once per settle so a demolished
    -- shed's footprint stays dry for at most ONE day rather than forever. That is
    -- the failure the brief names, bounded rather than left open, and the eventual
    -- hook simply makes the bound tighter.
    self:invalidateShelterCache()

    -- CATCH-UP. Skipped days are identifiable from the persisted cursor. Walk them
    -- oldest-first so each day's verdict is recorded in order.
    local firstDay = day - boundaries + 1
    for d = firstDay, day do
        local isToday = (d == day)
        self:settleOneDay(d, isToday)
    end

    self.appliedThroughDay = day
end

--- Settle a single day. `isToday` selects the live sky; a skipped day is
--- CLIMATE-DERIVED and says so, the same honesty as humidityDefaulted.
function MaterialWetness:settleOneDay(dayNumber, isToday)
    local sky, rain, derived = nil, nil, false

    if isToday then
        sky  = self:readSky()
        rain = self:readRainToday()
    end

    if sky == nil then
        -- No live sky: fall back to this day's OWN season's climate. A sleep across
        -- a season turn must not charge every skipped day to the waking season.
        derived = true
        -- EACH day to ITS OWN season, never all of them to the waking one.
        local climate = self:readClimate(self:seasonForDay(dayNumber))
        if climate == nil then
            -- No WeatherGuard at all: the accrual HOLDS. No invented sky.
            SoilLogger.debug("[MaterialWetness] day %s: no sky and no climate - holding", tostring(dayNumber))
            return
        end
        sky = {
            humidity      = 0.65,
            temperature   = climate.meanTemp,
            cloudCoverage = 0.5,
        }
        rain = { rainScale = climate.rainDayFraction or 0, isRaining = (climate.rainDayFraction or 0) > 0.5 }
    end

    self:dryPass(sky)
    local watered, source = self:wetPass(rain)
    self:recordDay(dayNumber, watered, source, derived)
end

--- DRY. Three bands by current value, each with its own subtraction, one filtered
--- call per band per field. The phase bounds are ENCODED before they reach the
--- filter, and the pass never aims below the EMC ceiling.
function MaterialWetness:dryPass(sky)
    if not self:isArmed() then return 0 end
    local md = self.materialDown
    if md == nil or md.enumerateActiveFields == nil then return 0 end

    local humidity = sky and sky.humidity or 0.65
    if humidity <= 1 then humidity = humidity * 100 end   -- accept 0-1 or 0-100
    local emcPct  = MaterialWetness.emcFor(humidity, sky and sky.temperature or 15)
    local emcRaw  = MaterialWetness.pctToRaw(emcPct)

    local calls = 0
    md:enumerateActiveFields(function(fieldId)
        local verts = self:fieldVerts(fieldId)
        if verts == nil then return end

        local soilClass = self:soilClassFor(fieldId)
        local evap      = MaterialWetness.SOIL_EVAP[soilClass] or 1.0
        local moisture  = self:readSoilMoisture(fieldId)
        local weather   = MaterialWetness.weatherMultiplier(sky and sky.cloudCoverage, moisture)

        for _, phase in ipairs(MaterialWetness.PHASES) do
            local points   = phase.dropPerDay * evap * weather
            local rawDelta = MaterialWetness.pointsToRawDelta(points)
            if rawDelta > 0 then
                -- Bounds encoded FIRST. Raw, not percent.
                local bandLow  = math.max(MaterialWetness.pctToRaw(phase.pctLow), emcRaw)
                local bandHigh = MaterialWetness.pctToRaw(phase.pctHigh)
                local applied = self.valueMaps:applyRawDeltaToPolygonBand(
                    MaterialWetness.LAYER_KEY, verts, -rawDelta, bandLow, bandHigh,
                    -- Floor at the EMC ceiling, never at the raw minimum: without
                    -- this a bound-water step walks a low pixel down into the
                    -- reserved sentinel band, where it stops being a value and
                    -- starts reading as a REFUSAL.
                    { floorTo = math.max(emcRaw, RAW_FLOOR) })
                if applied == nil then
                    self:_standDown("the banded delta was refused by the store")
                    return
                end
                calls = calls + 1
            end
        end
    end)
    return calls
end

--- WET. Rain across the area, then irrigation per running system. The shelter shape
--- is subtracted from the wetting call, never used to filter it.
---@return boolean watered, string source
function MaterialWetness:wetPass(rain)
    if not self:isArmed() then return false, "none" end

    local watered, source = false, "none"
    local fraction = 0
    if rain ~= nil then
        fraction = math.max(0, math.min(1, tonumber(rain.rainScale) or 0))
    end

    if fraction > 0 then
        local points   = MaterialWetness.RAIN_SETBACK_PER_DAY * fraction
        local rawDelta = MaterialWetness.pointsToRawDelta(points)
        if rawDelta > 0 then
            local md = self.materialDown
            if md ~= nil and md.enumerateActiveFields ~= nil then
                md:enumerateActiveFields(function(fieldId)
                    local verts = self:wettableVerts(fieldId)
                    if verts == nil then return end
                    self.valueMaps:applyRawDeltaToPolygonBand(
                        MaterialWetness.LAYER_KEY, verts, rawDelta, RAW_FLOOR, SoilValueMaps.RAW_MAX)
                end)
            end
            watered, source = true, "rain"
        end
    end

    -- IRRIGATION. Gated on the SeasonalCropStress facade extension (getIrrigationSystems
    -- gaining x/z/radius plus the arrival notice), which is on the ledger and NOT
    -- built - verified at source 2026-07-31. Until it lands there is no irrigation
    -- term at all, which is the neutral-when-absent behaviour, not a silent zero.
    --
    -- When it does land: one call per RUNNING system over the pivot's real circle at
    -- rain rate, coefficient 1.0, driven by ARRIVAL NOTICES accumulated per day and
    -- never by a sampled isActive flag (SCS activation is hourly and ephemeral, so a
    -- re-fired activation during their load is not an arrival). Irrigation has NO
    -- catch-up by ruling: skipped days receive none.
    if self:irrigationAvailable() then
        SoilLogger.debug("[MaterialWetness] irrigation facade present but the arrival contract is unbuilt")
    end

    return watered, source
end

--- True only when the SCS facade carries the geometry this system needs. Checking
--- the SHAPE rather than the mod's presence, so the term switches itself on the day
--- the extension ships instead of needing a code change here.
function MaterialWetness:irrigationAvailable()
    local cs = cropStress()
    if cs == nil or cs.getIrrigationSystems == nil then return false end
    local ok, systems = pcall(function() return cs:getIrrigationSystems() end)
    if not ok or type(systems) ~= "table" then return false end
    local first = systems[1]
    return first ~= nil and first.x ~= nil and first.z ~= nil and first.radius ~= nil
end

--- RECORD. One verdict per day: did water arrive, from any source. PERSISTED, never
--- recomputed - the climate roll reads the current season and weather mode, so an
--- unfrozen past day would quietly change its own answer.
function MaterialWetness:recordDay(dayNumber, watered, source, derived)
    if dayNumber == nil then return end
    if self.waterRecord[dayNumber] ~= nil then return end   -- frozen once written

    self.waterRecord[dayNumber] = {
        water   = watered == true,
        source  = source or "none",
        derived = derived == true,
    }
    self.recordDays[#self.recordDays + 1] = dayNumber

    while #self.recordDays > MaterialWetness.WATER_RECORD_DAYS do
        local oldest = table.remove(self.recordDays, 1)
        self.waterRecord[oldest] = nil
    end
end

--- How many of the last `days` days brought water. The question a spoil rule asks.
---@return number count, number known  known < days means the record does not reach back that far
function MaterialWetness:waterDaysInLast(days, throughDay)
    local n = math.max(1, math.floor(tonumber(days) or 6))
    local last = tonumber(throughDay) or self.appliedThroughDay
    if last == nil then return 0, 0 end
    local count, known = 0, 0
    for d = last - n + 1, last do
        local rec = self.waterRecord[d]
        if rec ~= nil then
            known = known + 1
            if rec.water then count = count + 1 end
        end
    end
    return count, known
end

-- =========================================================
-- Geometry helpers
-- =========================================================

function MaterialWetness:fieldVerts(fieldId)
    local ss = self.soilSystem
    if ss == nil or ss._getFieldPolyVerts == nil then return nil end
    local field = ss.fieldData and ss.fieldData[fieldId]
    local ok, verts = pcall(function() return ss:_getFieldPolyVerts(fieldId, field) end)
    if not ok or verts == nil or #verts < 3 then return nil end
    return verts
end

--- The wetting geometry: the field with sheltered ground subtracted.
---
--- v1 subtracts shelter at the WHOLE-FIELD grain: if the field's own sample points
--- read as indoor the field is skipped, otherwise it wets in full. That is the
--- honest half of the rule (unverifiable shelter WETS) without pretending to a
--- sub-field cut-out the point predicate cannot cheaply build. A finer shape is a
--- refinement, not a correction, and the cache below is already keyed for it.
function MaterialWetness:wettableVerts(fieldId)
    local verts = self:fieldVerts(fieldId)
    if verts == nil then return nil end

    if self.shelterDirty then
        self.shelterCache = {}
        self.shelterDirty = false
    end
    local cached = self.shelterCache[fieldId]
    if cached ~= nil then
        if cached == false then return nil end
        return verts
    end

    local sheltered = 0
    local sampled   = 0
    for _, v in ipairs(verts) do
        local indoor = MaterialWetness.isSheltered(v.x, v.z)
        if indoor ~= nil then
            sampled = sampled + 1
            if indoor then sheltered = sheltered + 1 end
        end
    end
    -- Neutral means it WETS: no samples, or a partial reading, and the rain lands.
    local allSheltered = (sampled > 0 and sheltered == sampled)
    self.shelterCache[fieldId] = not allSheltered
    if allSheltered then return nil end
    return verts
end

-- =========================================================
-- The read the members call
-- =========================================================

function MaterialWetness.bandForPct(pct)
    for _, band in ipairs(MaterialWetness.BANDS) do
        if pct >= band.floor then return band.name end
    end
    return MaterialWetness.BANDS[#MaterialWetness.BANDS].name
end

--- Banded condition over a work area, taking the COLLECTED QUANTITY IN LITRES as a
--- NON-OPTIONAL parameter (the engine hands it back from tipToGroundAroundLine and
--- every base-game consumer keeps that return).
---
--- RULES, each a refusal path rather than a number:
---   * nil, zero or negative quantity returns the REFUSAL state, never a value.
---   * any refusing cell in the set makes the WHOLE answer a refusal.
---   * NEVER built on readAverageOfPolygon. Its written-pixels filter would sum the
---     sentinel raw into a confident average - and the sentinel decodes to roughly
---     nine percent, bone-dry - pulling a mixed pickup toward FIT. The filter here
---     EXCLUDES the sentinel band using the same band parameter the new store method
---     takes, which is why that method has two uses rather than one.
---
--- The two windrow fill types are INSEPARABLE at pickup, so a mixed load is the
--- NORMAL case and a mass-weighted integral is the only honest answer.
---@return table { status, pct, band }
function MaterialWetness:readCondition(verts, litres)
    local R = MaterialWetness.RESULT
    if not self:isArmed() then return { status = R.UNAVAILABLE } end
    if verts == nil or #verts < 3 then return { status = R.UNAVAILABLE } end

    local q = tonumber(litres)
    if q == nil or q <= 0 then return { status = R.REFUSAL } end

    local vm = self.valueMaps
    -- Any pixel in the reserved sentinel band makes the whole answer a refusal:
    -- refusal propagates, it does not average away.
    local refusing = vm:hasAnyInBand(MaterialWetness.LAYER_KEY, verts, 1, RAW_FLOOR - 1)
    if refusing == nil then return { status = R.UNAVAILABLE } end
    if refusing then return { status = R.REFUSAL } end

    local present = vm:hasAnyInBand(MaterialWetness.LAYER_KEY, verts, RAW_FLOOR, SoilValueMaps.RAW_MAX)
    if present == nil then return { status = R.UNAVAILABLE } end
    if not present then return { status = R.NO_MATERIAL } end

    -- Mass-weighted mean over the cells that actually carry material. The sentinel
    -- band is excluded by the filter, so nothing bone-dry-looking can enter the sum.
    local avg = vm:readAverageRawInBand(MaterialWetness.LAYER_KEY, verts, RAW_FLOOR, SoilValueMaps.RAW_MAX)
    if avg == nil then return { status = R.UNAVAILABLE } end

    local pct = MaterialWetness.rawToPct(avg)
    if pct == nil then return { status = R.REFUSAL } end
    return { status = R.OK, pct = pct, band = MaterialWetness.bandForPct(pct) }
end

--- MOWER / TEDDER INTERACTION. A mower dropping over existing material is a
--- MOVEMENT, not a birth: the engine picks hay up and re-drops it as grass, and its
--- own source comment says so. Without this rule a second cut re-dates AND re-wets a
--- nearly-ready swath, which is the same laundering the sibling's age rule closes.
function MaterialWetness:noteMaterialMoved(srcVerts, dstVerts)
    if not self:isArmed() then return false end
    if dstVerts == nil or #dstVerts < 3 then return false end
    if srcVerts == nil or #srcVerts < 3 then return false end

    local vm = self.valueMaps
    -- Inherit the WETTEST band present in the source, walking down from soaked. The
    -- wet direction is the conservative one here: calling moved material drier than
    -- its source is what would let a rake dry a swath for free.
    for _, band in ipairs(MaterialWetness.BANDS) do
        local low = MaterialWetness.pctToRaw(band.floor)
        local present = vm:hasAnyInBand(MaterialWetness.LAYER_KEY, srcVerts, low, SoilValueMaps.RAW_MAX)
        if present == nil then return false end
        if present then
            return vm:setPolygonWhere(MaterialWetness.LAYER_KEY, dstVerts, low, 0, 0)
        end
    end
    return false
end

-- =========================================================
-- Persistence (the MaterialWaterBook sidecar; merge-never-replace)
-- =========================================================

function MaterialWetness:serialize()
    local days = {}
    for _, d in ipairs(self.recordDays) do
        local rec = self.waterRecord[d]
        if rec ~= nil then
            days[#days + 1] = { day = d, water = rec.water, source = rec.source, derived = rec.derived }
        end
    end
    return { schema = 1, appliedThroughDay = self.appliedThroughDay, days = days }
end

--- MERGE, never replace, for the same reason as the sibling: StateLedger omits a
--- block when serialize fails and cannot tell that from a brand-new save.
--- A recorded verdict is never overwritten - it was frozen for a reason.
function MaterialWetness:deserialize(data)
    if type(data) ~= "table" then return false end

    if type(data.appliedThroughDay) == "number" then
        if self.appliedThroughDay == nil or data.appliedThroughDay > self.appliedThroughDay then
            self.appliedThroughDay = data.appliedThroughDay
        end
    end

    if type(data.days) == "table" then
        for _, rec in ipairs(data.days) do
            if rec.day ~= nil and self.waterRecord[rec.day] == nil then
                self.waterRecord[rec.day] = {
                    water   = rec.water == true,
                    source  = rec.source or "none",
                    derived = rec.derived == true,
                }
                self.recordDays[#self.recordDays + 1] = rec.day
            end
        end
        table.sort(self.recordDays)
        while #self.recordDays > MaterialWetness.WATER_RECORD_DAYS do
            local oldest = table.remove(self.recordDays, 1)
            self.waterRecord[oldest] = nil
        end
    end
    return true
end

SoilLogger.info("MaterialWetness (SF-49) loaded")
