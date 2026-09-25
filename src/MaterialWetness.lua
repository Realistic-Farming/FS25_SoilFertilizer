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
MaterialWetness = MaterialWetness or {}
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

-- [RSF-F211] Every condition read says what it measured, and a caller demands the basis
-- it needs. A PROBE samples the layer over an area (a pixel mean, no quantity): it can
-- tell a machine what is under it, never what a pile of material is. A STANDING read
-- weights each Soil cell by the native volume of the requested type lying in it, clipped
-- to the field. A COLLECTED read weights each source portion by the carrier litres the
-- producer sealed for it. A probe's OK never authorises a material output.
MaterialWetness.BASIS = {
    AREA_SAMPLE = "AREA_SAMPLE_V1",
    STANDING    = "STANDING_NATIVE_VOLUME_V1",
    COLLECTED   = "COLLECTED_NATIVE_VOLUME_V1",
}
-- A source cell's condition as the standing and collected readers classify it. Missing
-- data is not dry: no record, and a read that cannot be vouched for, are UNKNOWN.
MaterialWetness.SOURCE = { KNOWN = "KNOWN", UNKNOWN = "UNKNOWN", REFUSAL = "REFUSAL" }
-- The candidate cells one standing snapshot may visit (the polygons' box at the condition
-- grain), and the sealed allocations kept for their receipts (a transient causal binding,
-- not a journal: the oldest leaves first).
MaterialWetness.STANDING_MAX_CELLS = 65536
MaterialWetness.MAX_ALLOCATIONS    = 256

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
    -- RSF-F213 (contract section 5): the membership index the daily settle walks
    -- once the ground family is armed (GroundConditionCoordinator binds itself), and
    -- the per-cell exposed fraction cache the shelter read fills (P-GROUND-4).
    self.membership   = nil
    self.shelterCells = {}
    self.shelterEpoch = 0
    self.lastSettle   = nil
    -- [RSF-F211] The producer-owned sealed allocations the collected reader resolves a
    -- receipt against, and the sequence snapshots and allocations are numbered from.
    self.allocations     = {}
    self.allocationOrder = {}
    self.allocationSeq   = 0
    self.snapshotSeq     = 0
    return self
end

-- =========================================================
-- RSF-F213 part 2: the membership settle (contract section 5)
-- =========================================================
-- With the ground family armed the daily weather walks the derived membership
-- index at the Soil cell grain, fields and yards alike, instead of the fields'
-- polygons: every admitted cell exactly once per settled day, the same phase order,
-- encoded bounds, equilibrium floor and rounding as the field pass, and a rain dose
-- scaled by the cell's EXPOSED fraction under the indoor mask, read at the mask's own
-- grain. The field pass below stays as the path for a store without the index (the
-- coordinator never binds then), never as a second pass over the same ground.

--- The coordinator binds itself here at arm when its membership index exists.
function MaterialWetness:bindMembership(coordinator)
    self.membership   = coordinator
    self.shelterCells = {}
    self.shelterEpoch = self.shelterEpoch + 1
end

function MaterialWetness:membershipActive()
    return self.membership ~= nil
end

--- The cell's exposed (uncovered) fraction under the indoor mask: 1 when there is
--- no usable mask (neutral means it WETS, the existing conservative rule), else one
--- minus the indoor pixel share of the cell's world box, read through the mask's
--- own modifier at the mask's own grain. Cached until invalidation.
function MaterialWetness:exposedFraction(gx, gz)
    local key = gx .. ":" .. gz
    local cached = self.shelterCells[key]
    if cached ~= nil then return cached end
    local frac = self:_readExposedFraction(gx, gz)
    self.shelterCells[key] = frac
    return frac
end

function MaterialWetness:_readExposedFraction(gx, gz)
    local mission = g_currentMission
    local mask = mission ~= nil and mission.indoorMask or nil
    if mask == nil then return 1 end
    -- Reject a nil or zero handle and an unusable mask geometry before asking:
    -- hasMask alone is not enough (contract section 5).
    if mask.handle == nil or mask.handle == 0 then return 1 end
    if type(mask.maskSize) ~= "number" or mask.maskSize <= 0 then return 1 end
    if type(mask.terrainSize) ~= "number" or mask.terrainSize <= 0 then return 1 end
    if mask.modifierValue == nil or type(mask.getFilter) ~= "function" or type(mask.setParallelogramUVCoords) ~= "function" then return 1 end
    if type(IndoorMask) ~= "table" or IndoorMask.INDOOR == nil then return 1 end
    if self.membership == nil then return 1 end
    local x0, z0, x1, z1 = self.membership:cellWorldBox(gx, gz)
    if x0 == nil then return 1 end
    local ok, indoor, total = pcall(function()
        local filter = mask:getFilter(IndoorMask.INDOOR)
        if filter == nil then return nil, nil end
        mask:setParallelogramUVCoords(mask.modifierValue, x0, z0, x1, z0, x0, z1)
        local _, n, tot = mask.modifierValue:executeGet(filter)
        return n, tot
    end)
    if not ok or type(indoor) ~= "number" or type(total) ~= "number" or total <= 0 then return 1 end
    local covered = math.max(0, math.min(1, indoor / total))
    return 1 - covered
end

--- The placeable lifecycle wrap (HookManager:installIndoorMaskHook) reports a mask
--- paint AFTER the original ran: the cells the painted area touches lose their
--- cached fraction; a paint that raised, or an area we cannot place, drops the
--- whole cache, conservatively.
function MaterialWetness:onIndoorMaskChanged(area, _indoor, originalOk)
    if not originalOk then self:invalidateShelterCache() return end
    local placed = false
    if self.membership ~= nil and type(area) == "table" and GroundNativeObserver ~= nil
       and GroundNativeObserver.parallelogramCells ~= nil and self.membership.cells ~= nil then
        local ok = pcall(function()
            local x0, _, z0 = getWorldTranslation(area.start)
            local x1, _, z1 = getWorldTranslation(area.width)
            local x2, _, z2 = getWorldTranslation(area.height)
            local geometry = self.membership.cells:getConditionGeometry()
            local cells = GroundNativeObserver.parallelogramCells(geometry, x0, z0, x1, z1, x2, z2)
            if cells == nil then return end
            for _, c in ipairs(cells) do self.shelterCells[c.gx .. ":" .. c.gz] = nil end
            placed = true
        end)
        if not ok then placed = false end
    end
    if not placed then self:invalidateShelterCache() end
end

--- The soil-class and soil-moisture modifiers for the field under a cell's centre,
--- through the existing per-field contracts, neutral outside any field; cached per
--- field for one pass.
local function fieldOfCell(self, gx, gz)
    local ss = self.soilSystem
    local hm = ss ~= nil and ss.hookManager or nil
    if hm == nil or type(hm.getFieldIdAtWorldPosition) ~= "function" then return nil end
    local x0, z0, x1, z1 = self.membership:cellWorldBox(gx, gz)
    if x0 == nil then return nil end
    local ok, fieldId = pcall(hm.getFieldIdAtWorldPosition, hm, (x0 + x1) * 0.5, (z0 + z1) * 0.5)
    if not ok or type(fieldId) ~= "number" or fieldId <= 0 then return nil end
    return fieldId
end

--- [RSF-F211] The fields that hold at least one ground-membership cell (the index the
--- daily weather walks, RSF-F213), ascending and once each. The hay settle adds these to
--- MaterialDown's active set, which only the combine's straw birth and a save load mark:
--- a mown grass field never entered it, so the settle never reached one. Empty while the
--- index is not bound or not ready.
---@return table fieldIds
function MaterialWetness:memberFieldIds()
    local out, seen = {}, {}
    local m = self.membership
    if m == nil or type(m.isMembershipReady) ~= "function" or not m:isMembershipReady() then return out end
    m:enumerateMemberRuns(function(gz, gx0, gx1)
        for gx = gx0, gx1 do
            local fieldId = fieldOfCell(self, gx, gz)
            if fieldId ~= nil and not seen[fieldId] then
                seen[fieldId] = true
                out[#out + 1] = fieldId
            end
        end
    end)
    table.sort(out)
    return out
end

local function driversFor(self, cache, fieldId, sky)
    local key = fieldId or 0
    local d = cache[key]
    if d ~= nil then return d end
    local soilClass, moisture = MaterialWetness.DEFAULT_SOIL_CLASS, nil
    if fieldId ~= nil then
        soilClass = self:soilClassFor(fieldId)
        moisture  = self:readSoilMoisture(fieldId)
    end
    local evap    = MaterialWetness.SOIL_EVAP[soilClass] or 1.0
    local weather = MaterialWetness.weatherMultiplier(sky and sky.cloudCoverage, moisture)
    d = { evap = evap, weather = weather, deltas = {} }
    for i, phase in ipairs(MaterialWetness.PHASES) do
        d.deltas[i] = MaterialWetness.pointsToRawDelta(phase.dropPerDay * evap * weather)
    end
    cache[key] = d
    return d
end

--- One cell's dried value under the phase table, the SAME sequence the field pass
--- runs: each phase in order, a cell inside the phase's encoded band steps down by
--- that phase's raw delta, never below the equilibrium floor (the EMC ceiling, and
--- never into the reserved band). A cell that crosses into the next band is then
--- eligible for that band's step, as the sequential layer passes make it.
local function dryOneCell(raw, deltas, bandLows, bandHighs, floorRaw)
    local v = raw
    for i = 1, #deltas do
        local d = deltas[i]
        if d > 0 and v >= bandLows[i] and v <= bandHighs[i] then
            v = v - d
            if v < floorRaw then v = floorRaw end
        end
    end
    return v
end

--- Walk a run: read each cell, compute its new value, write coalesced runs of an
--- identical new value; unknown, absent and unavailable cells are skipped (an
--- unavailable one unread) and break a run. Returns the engine reads and writes
--- made, for the cost record.
local function settleRun(self, gz, gx0, gx1, valueFor)
    local coord = self.membership
    local reads, writes = 0, 0
    local runStart, runValue = nil, nil
    local function flush(gxEnd)
        if runStart ~= nil then
            coord:writeWetnessRun(runStart, gxEnd, gz, runValue)
            writes = writes + 1
            runStart, runValue = nil, nil
        end
    end
    for gx = gx0, gx1 do
        local newValue = nil
        if not coord:isUnavailable(gx, gz) then
            local c = coord:readCell(gx, gz)
            reads = reads + 1
            local raw = c ~= nil and c.wetnessRaw or nil
            if type(raw) == "number" and raw >= RAW_FLOOR then
                local v = valueFor(gx, gz, raw)
                if v ~= raw then newValue = v end
            end
        end
        if newValue == nil then
            flush(gx - 1)
        elseif runStart == nil then
            runStart, runValue = gx, newValue
        elseif newValue ~= runValue then
            flush(gx - 1)
            runStart, runValue = gx, newValue
        end
    end
    flush(gx1)
    return reads, writes
end

--- DRY over the membership: the phase table per cell, the floor at the EMC ceiling.
function MaterialWetness:dryPassMembers(sky)
    local humidity = sky and sky.humidity or 0.65
    if humidity <= 1 then humidity = humidity * 100 end
    local emcPct  = MaterialWetness.emcFor(humidity, sky and sky.temperature or 15)
    local emcRaw  = MaterialWetness.pctToRaw(emcPct)
    local floorRaw = math.max(emcRaw, RAW_FLOOR)
    local bandLows, bandHighs = {}, {}
    for i, phase in ipairs(MaterialWetness.PHASES) do
        bandLows[i]  = math.max(MaterialWetness.pctToRaw(phase.pctLow), emcRaw)
        bandHighs[i] = MaterialWetness.pctToRaw(phase.pctHigh)
    end
    local drivers = {}
    local reads, writes, cells = 0, 0, 0
    self.membership:enumerateMemberRuns(function(gz, gx0, gx1)
        cells = cells + (gx1 - gx0 + 1)
        local r, w = settleRun(self, gz, gx0, gx1, function(gx, gz2, raw)
            local d = driversFor(self, drivers, fieldOfCell(self, gx, gz2), sky)
            return dryOneCell(raw, d.deltas, bandLows, bandHighs, floorRaw)
        end)
        reads, writes = reads + r, writes + w
    end)
    self.lastSettle = self.lastSettle or {}
    self.lastSettle.cells, self.lastSettle.dryReads, self.lastSettle.dryWrites = cells, reads, writes
    return reads + writes
end

--- WET over the membership: the rain dose times the cell's exposed fraction, only on
--- cells that hold a known value (rain never initialises raw 0 or the sentinel).
---@return boolean watered, string source
function MaterialWetness:wetPassMembers(rain)
    local watered, source = false, "none"
    local fraction = 0
    if rain ~= nil then
        fraction = math.max(0, math.min(1, tonumber(rain.rainScale) or 0))
    end
    local reads, writes, sheltered = 0, 0, 0
    if fraction > 0 then
        local points = MaterialWetness.RAIN_SETBACK_PER_DAY * fraction
        if MaterialWetness.pointsToRawDelta(points) > 0 then
            self.membership:enumerateMemberRuns(function(gz, gx0, gx1)
                local r, w = settleRun(self, gz, gx0, gx1, function(gx, gz2, raw)
                    local exposed = self:exposedFraction(gx, gz2)
                    if exposed < 1 then sheltered = sheltered + 1 end
                    local rawDelta = MaterialWetness.pointsToRawDelta(points * exposed)
                    if rawDelta <= 0 then return raw end
                    return math.min(SoilValueMaps.RAW_MAX, raw + rawDelta)
                end)
                reads, writes = reads + r, writes + w
            end)
            watered, source = true, "rain"
        end
    end
    self.lastSettle = self.lastSettle or {}
    self.lastSettle.wetReads, self.lastSettle.wetWrites, self.lastSettle.shelteredCells = reads, writes, sheltered
    if self:irrigationAvailable() then
        SoilLogger.debug("[MaterialWetness] irrigation facade present but the arrival contract is unbuilt")
    end
    return watered, source
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
    self.allocations, self.allocationOrder = {}, {}   -- a fresh mission seals afresh
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
    self.shelterCells = {}
    self.shelterEpoch = (self.shelterEpoch or 0) + 1
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
    -- RSF-F213 part 1: the walk starts where the cursor ACTUALLY stands. A day held
    -- earlier (no sky and no climate) left the cursor behind it, and the caller's span
    -- does not know that (Time Guard counts its own boundaries), so the held day is
    -- replayed here rather than stepped over.
    if self.appliedThroughDay ~= nil and self.appliedThroughDay + 1 < firstDay then
        firstDay = self.appliedThroughDay + 1
    end
    for d = firstDay, day do
        local isToday = (d == day)
        if not self:settleOneDay(d, isToday) then
            -- A HELD day. The cursor stays on the last day actually settled: the
            -- ground-condition contract (section 2) forbids advancing a domain
            -- cursor past an unsettled day, and the settlement barrier reads exactly
            -- this cursor to know whether pre-operation ground is settled. The later
            -- days are not walked either, so each day is still applied in order.
            return
        end
        self.appliedThroughDay = d
    end
end

--- Settle a single day. `isToday` selects the live sky; a skipped day is
--- CLIMATE-DERIVED and says so, the same honesty as humidityDefaulted.
---@return boolean settled false when the day HOLDS (no live sky and no climate)
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
            return false
        end
        sky = {
            humidity      = 0.65,
            temperature   = climate.meanTemp,
            cloudCoverage = 0.5,
        }
        rain = { rainScale = climate.rainDayFraction or 0, isRaining = (climate.rainDayFraction or 0) > 0.5 }
    end

    -- RSF-F213: with the membership index bound, the settle walks members. An index
    -- that is not ready (a bit write refused since the last build) is reconciled
    -- first; if it cannot be, the day HOLDS: condition stays unavailable rather than
    -- weathered over an index we cannot vouch for (contract section 5).
    if self:membershipActive() then
        if not self.membership:isMembershipReady() and not self.membership:reconcileMembership() then
            SoilLogger.warning("[MaterialWetness] day %s: the membership index needs a rebuild that did not complete - holding", tostring(dayNumber))
            return false
        end
        self:dryPassMembers(sky)
        local wateredM, sourceM = self:wetPassMembers(rain)
        self:recordDay(dayNumber, wateredM, sourceM, derived)
        return true
    end

    self:dryPass(sky)
    local watered, source = self:wetPass(rain)
    self:recordDay(dayNumber, watered, source, derived)
    return true
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

--- [RSF-F211] THE PROBE (AREA_SAMPLE_V1): the banded condition the layer reads over an
--- area, for a machine asking what is under it (the tedder's delta and correction, the
--- handful read). A pixel mean over the cells that carry material: an AREA sample with
--- no quantity in it, so its OK never authorises a material output.
---
--- RULES, each a refusal path rather than a number:
---   * any refusing cell in the set makes the WHOLE answer a refusal.
---   * NEVER built on readAverageOfPolygon. Its written-pixels filter would sum the
---     sentinel raw into a confident average - and the sentinel decodes to roughly
---     nine percent, bone-dry - pulling a mixed read toward FIT. The filter here
---     EXCLUDES the sentinel band using the same band parameter the new store method
---     takes, which is why that method has two uses rather than one.
---@return table { status, pct, band, basis }
function MaterialWetness:probeCondition(verts)
    local R, AREA = MaterialWetness.RESULT, MaterialWetness.BASIS.AREA_SAMPLE
    if not self:isArmed() then return { status = R.UNAVAILABLE, basis = AREA } end
    if verts == nil or #verts < 3 then return { status = R.UNAVAILABLE, basis = AREA } end

    local vm = self.valueMaps
    -- Any pixel in the reserved sentinel band makes the whole answer a refusal:
    -- refusal propagates, it does not average away.
    local refusing = vm:hasAnyInBand(MaterialWetness.LAYER_KEY, verts, 1, RAW_FLOOR - 1)
    if refusing == nil then return { status = R.UNAVAILABLE, basis = AREA } end
    if refusing then return { status = R.REFUSAL, basis = AREA } end

    local present = vm:hasAnyInBand(MaterialWetness.LAYER_KEY, verts, RAW_FLOOR, SoilValueMaps.RAW_MAX)
    if present == nil then return { status = R.UNAVAILABLE, basis = AREA } end
    if not present then return { status = R.NO_MATERIAL, basis = AREA } end

    -- The mean over the cells that carry material. The sentinel band is excluded by the
    -- filter, so nothing bone-dry-looking can enter the sum.
    local avg = vm:readAverageRawInBand(MaterialWetness.LAYER_KEY, verts, RAW_FLOOR, SoilValueMaps.RAW_MAX)
    if avg == nil then return { status = R.UNAVAILABLE, basis = AREA } end

    local pct = MaterialWetness.rawToPct(avg)
    if pct == nil then return { status = R.REFUSAL, basis = AREA } end
    return { status = R.OK, pct = pct, band = MaterialWetness.bandForPct(pct), basis = AREA }
end

--- DEPRECATED (RSF-F211): the old read, kept as an alias that serves AREA_SAMPLE_V1 only.
--- A nil, zero or negative quantity still refuses, as it always did; a positive one
--- weights nothing (it never did: the percent was the probe's pixel mean). The two
--- collection callers still on it (YardLadder's bale birth, the baler's pickup sample)
--- move to the collected reader with the machines (RSF-F211 part 2).
function MaterialWetness:readCondition(verts, litres)
    local R, AREA = MaterialWetness.RESULT, MaterialWetness.BASIS.AREA_SAMPLE
    if not self:isArmed() then return { status = R.UNAVAILABLE, basis = AREA } end
    if verts == nil or #verts < 3 then return { status = R.UNAVAILABLE, basis = AREA } end
    local q = tonumber(litres)
    if q == nil or q <= 0 then return { status = R.REFUSAL, basis = AREA } end
    return self:probeCondition(verts)
end

-- =========================================================
-- [RSF-F211] Standing and collected condition
-- =========================================================

local function finiteNumber(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

--- The litres of `fillTypeIndex` lying in the world box [x0,x1] x [z0,z1], through the
--- engine's own read: DensityMapHeightUtil.getFillLevelAtArea(fillType, start, width
--- point, height point) returns the litres first (DensityMapHeightUtil.lua:80-109).
--- nil when the read fails.
-- [MAINTENANCE row 123] Engine reads made by the standing and collected readers, counted
-- so the hay settle can say what one day cost (HayBet:onSettle). Counters only; nothing
-- reads them to decide anything.
MaterialWetness.nativeReads = MaterialWetness.nativeReads or 0
MaterialWetness.cellReads   = MaterialWetness.cellReads or 0

local function nativeLitres(fillTypeIndex, x0, z0, x1, z1)
    MaterialWetness.nativeReads = MaterialWetness.nativeReads + 1
    local ok, litres = pcall(DensityMapHeightUtil.getFillLevelAtArea, fillTypeIndex, x0, z0, x1, z0, x0, z1)
    if not ok or not finiteNumber(litres) or litres < 0 then return nil end
    return litres
end

--- A fill type the height map can hold: a number that is not UNKNOWN, a valid height
--- map (DensityMapHeightManager:getIsValid :492) and a height type mapped to it
--- (:280). Anything else is unavailable, never an arbitrary crop.
---@return boolean usable, string|nil reason
function MaterialWetness.nativeTypeUsable(fillTypeIndex)
    if type(fillTypeIndex) ~= "number" then return false, "NO_FILL_TYPE" end
    if FillType ~= nil and fillTypeIndex == FillType.UNKNOWN then return false, "NO_FILL_TYPE" end
    local hm = g_densityMapHeightManager
    if hm == nil or type(hm.getIsValid) ~= "function"
       or type(hm.getDensityMapHeightTypeByFillTypeIndex) ~= "function" then
        return false, "HEIGHT_MAP_UNAVAILABLE"
    end
    local okV, valid = pcall(hm.getIsValid, hm)
    if not okV or not valid then return false, "HEIGHT_MAP_UNAVAILABLE" end
    local okH, heightType = pcall(hm.getDensityMapHeightTypeByFillTypeIndex, hm, fillTypeIndex)
    if not okH or heightType == nil then return false, "NO_FILL_TYPE" end
    return true
end

--- The ground family's coordinator, owner of the condition cells; nil unless armed.
function MaterialWetness:groundCoordinator()
    local ss = self.soilSystem
    local coord = ss ~= nil and ss.groundConditionCoordinator or nil
    if coord == nil or type(coord.isArmed) ~= "function" or not coord:isArmed() then return nil end
    return coord
end

--- One cell's condition as a source: KNOWN with its percent, REFUSAL for the reserved
--- sentinel band, UNKNOWN for no record, a cell the availability overlay cannot vouch
--- for, or a read the cells refused. Also returns the cell's age byte.
---@return string status, number|nil pct, number|nil ageRaw
function MaterialWetness:sourceCondition(coord, gx, gz)
    local S = MaterialWetness.SOURCE
    if type(coord.isUnavailable) == "function" and coord:isUnavailable(gx, gz) then return S.UNKNOWN end
    local cell = coord:readCell(gx, gz)
    if cell == nil or cell.refused ~= nil or not cell.wetnessAvailable then return S.UNKNOWN end
    local ageRaw = cell.ageAvailable and cell.ageRaw or nil
    local raw = cell.wetnessRaw
    if type(raw) ~= "number" or raw <= 0 then return S.UNKNOWN, nil, ageRaw end
    if raw < RAW_FLOOR then return S.REFUSAL, nil, ageRaw end
    local pct = MaterialWetness.rawToPct(raw)
    if pct == nil then return S.REFUSAL, nil, ageRaw end
    return S.KNOWN, pct, ageRaw
end

--- An immutable snapshot of source portions, each a Soil cell with the litres of the
--- type it holds and its condition at capture, stamped with the owner revision.
--- `cells` is { { gx, gz, litres, fraction }, ... }, one entry per cell.
---@return table|nil snapshot, string|nil reason
function MaterialWetness:captureSnapshot(basis, fillTypeIndex, coord, cells)
    local parts, order, total = {}, {}, 0
    for _, c in ipairs(cells) do
        local id = tostring(c.gx) .. ":" .. tostring(c.gz)
        if parts[id] ~= nil then return nil, "DUPLICATE_CELL" end
        if not finiteNumber(c.litres) or c.litres < 0 then return nil, "SOURCE_VALUE" end
        MaterialWetness.cellReads = MaterialWetness.cellReads + 1
        local status, pct, ageRaw = self:sourceCondition(coord, c.gx, c.gz)
        parts[id] = { available = c.litres, status = status, pct = pct, ageRaw = ageRaw,
                      gx = c.gx, gz = c.gz, fraction = c.fraction }
        order[#order + 1] = id
        total = total + c.litres
    end
    self.snapshotSeq = (self.snapshotSeq or 0) + 1
    return { id = basis .. "#" .. self.snapshotSeq, basis = basis, revision = coord:getOwnerRevision(),
             fillTypeIndex = fillTypeIndex, parts = parts, order = order, availableLitres = total }
end

--- THE STANDING SNAPSHOT (STANDING_NATIVE_VOLUME_V1): the requested type lying inside
--- the field, cell by cell. `polygons` is one polygon ({ {x=,z=}, ... }) or a list of
--- them (every field on a farmland, SF-52). Each is triangulated (a concave field too);
--- the candidate Soil cells come from the polygons' box only for lookup; each cell's
--- native volume (the engine's own read over the cell's box) is allocated by the cell's
--- actual overlap with the field, so a boundary cell counts only its inside share and a
--- cell outside counts nothing. The native volume inside a Soil cell is taken as uniform
--- there: the engine exposes no finer native grid to Lua.
--- Refuses (nil, reason): NOT_ARMED, NO_FILL_TYPE, HEIGHT_MAP_UNAVAILABLE,
--- NO_GROUND_FAMILY, NO_GEOMETRY, INVALID_POLYGON, TOO_MANY_CELLS (the box over
--- STANDING_MAX_CELLS: about 512 m square at the 2 m grain the store picks for maps up to
--- 8x). COST: one engine read per row of the box, one more per cell in a row that holds
--- the type, and a clip only for a cell that holds some, against the triangles whose box
--- meets it.
---@return table|nil snapshot, string|nil reason
function MaterialWetness:standingSnapshot(fillTypeIndex, polygons)
    if not self:isArmed() then return nil, "NOT_ARMED" end
    local usable, why = MaterialWetness.nativeTypeUsable(fillTypeIndex)
    if not usable then return nil, why end
    local coord = self:groundCoordinator()
    if coord == nil then return nil, "NO_GROUND_FAMILY" end
    local geometry = coord.cells ~= nil and coord.cells:getConditionGeometry() or nil
    if geometry == nil then return nil, "NO_GEOMETRY" end
    if PolygonClip == nil or type(polygons) ~= "table" or #polygons == 0 then return nil, "INVALID_POLYGON" end
    if type(polygons[1]) == "table" and polygons[1].x ~= nil then polygons = { polygons } end

    local triangles = {}
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, poly in ipairs(polygons) do
        local tris = PolygonClip.triangulate(poly)
        if tris == nil then return nil, "INVALID_POLYGON" end
        for _, tri in ipairs(tris) do triangles[#triangles + 1] = tri end
        local a, b, c, d = PolygonClip.bounds(poly)
        minX, minZ = math.min(minX, a), math.min(minZ, b)
        maxX, maxZ = math.max(maxX, c), math.max(maxZ, d)
    end

    local g, ox, oz, res = geometry.grainMetres, geometry.originX, geometry.originZ, geometry.resolution
    local gx0 = math.max(0, math.floor((minX - ox) / g))
    local gx1 = math.min(res - 1, math.floor((maxX - ox) / g))
    local gz0 = math.max(0, math.floor((minZ - oz) / g))
    local gz1 = math.min(res - 1, math.floor((maxZ - oz) / g))
    local cells = {}
    if gx1 >= gx0 and gz1 >= gz0 then
        if (gx1 - gx0 + 1) * (gz1 - gz0 + 1) > MaterialWetness.STANDING_MAX_CELLS then return nil, "TOO_MANY_CELLS" end
        for gz = gz0, gz1 do
            local z0 = oz + gz * g
            local z1 = z0 + g
            -- One read for the row's strip first: a row with none of the type is skipped.
            local rowLitres = nativeLitres(fillTypeIndex, ox + gx0 * g, z0, ox + (gx1 + 1) * g, z1)
            if rowLitres == nil then return nil, "HEIGHT_MAP_UNAVAILABLE" end
            if rowLitres > 0 then
                for gx = gx0, gx1 do
                    local x0 = ox + gx * g
                    local x1 = x0 + g
                    -- The engine's read first: only a cell that holds some of the type is
                    -- clipped against the field.
                    local litres = nativeLitres(fillTypeIndex, x0, z0, x1, z1)
                    if litres == nil then return nil, "HEIGHT_MAP_UNAVAILABLE" end
                    if litres > 0 then
                        local fraction = PolygonClip.overlapFraction(x0, z0, x1, z1, triangles)
                        local q = litres * fraction
                        if q > 0 then cells[#cells + 1] = { gx = gx, gz = gz, litres = q, fraction = fraction } end
                    end
                end
            end
        end
    end
    return self:captureSnapshot(MaterialWetness.BASIS.STANDING, fillTypeIndex, coord, cells)
end

local function coverageResult(basis, status, reason)
    return { status = status, reason = reason, basis = basis,
             carrierLitres = 0, knownCarrierLitres = 0, unknownCarrierLitres = 0,
             refusedCarrierLitres = 0, knownWeightedPctSum = 0 }
end

--- THE STANDING READ: the snapshot's cells weighted by their native volume. Always
--- returns the coverage (carrier, known, unknown, refused litres; the known weighted
--- percent sum), mutually exclusive and summing to the carrier litres. OK only when
--- every positive portion is known: pct = knownWeightedPctSum / carrierLitres, banded
--- afterwards. Positive unknown or refused content is REFUSAL, no material is
--- NO_MATERIAL, and a snapshot of another basis, or taken before the owner last moved,
--- is UNAVAILABLE.
function MaterialWetness:readStandingCondition(snapshot)
    local R, B, S = MaterialWetness.RESULT, MaterialWetness.BASIS, MaterialWetness.SOURCE
    if not self:isArmed() then return coverageResult(B.STANDING, R.UNAVAILABLE, "NOT_ARMED") end
    if type(snapshot) ~= "table" or type(snapshot.parts) ~= "table" or type(snapshot.order) ~= "table" then
        return coverageResult(B.STANDING, R.UNAVAILABLE, "MALFORMED")
    end
    if snapshot.basis ~= B.STANDING then return coverageResult(B.STANDING, R.UNAVAILABLE, "BASIS_MISMATCH") end
    local coord = self:groundCoordinator()
    if coord == nil or GroundConditionCoordinator == nil
       or not GroundConditionCoordinator.revisionsEqual(snapshot.revision, coord:getOwnerRevision()) then
        return coverageResult(B.STANDING, R.UNAVAILABLE, "REVISION_MISMATCH")
    end
    local out = coverageResult(B.STANDING, nil, nil)
    local seen = {}
    for _, id in ipairs(snapshot.order) do
        local p = snapshot.parts[id]
        if seen[id] or type(p) ~= "table" or not finiteNumber(p.available) or p.available < 0 then
            return coverageResult(B.STANDING, R.UNAVAILABLE, "SOURCE_VALUE")
        end
        seen[id] = true
        local q = p.available
        if q > 0 then
            out.carrierLitres = out.carrierLitres + q
            if p.status == S.KNOWN then
                if not finiteNumber(p.pct) or p.pct < 0 or p.pct > 100 then
                    return coverageResult(B.STANDING, R.UNAVAILABLE, "SOURCE_VALUE")
                end
                out.knownCarrierLitres = out.knownCarrierLitres + q
                out.knownWeightedPctSum = out.knownWeightedPctSum + q * p.pct
            elseif p.status == S.REFUSAL then
                out.refusedCarrierLitres = out.refusedCarrierLitres + q
            else
                out.unknownCarrierLitres = out.unknownCarrierLitres + q
            end
        end
    end
    if out.carrierLitres <= 0 then
        out.status, out.reason = R.NO_MATERIAL, "NO_MATERIAL"
    elseif out.unknownCarrierLitres > 0 or out.refusedCarrierLitres > 0 then
        out.status, out.reason = R.REFUSAL, "POSITIVE_UNKNOWN_OR_REFUSAL"
    else
        out.status, out.reason = R.OK, "COMPLETE_KNOWN_COVERAGE"
        out.pct = out.knownWeightedPctSum / out.carrierLitres
        out.band = MaterialWetness.bandForPct(out.pct)
    end
    return out
end

--- THE COLLECTED SNAPSHOT (COLLECTED_NATIVE_VOLUME_V1): the source cells a pickup is
--- about to remove, captured immediately before the mutation. `cells` is
--- { { gx, gz, litres }, ... } in RAW SOURCE litres, one entry per cell. The pickup
--- bracket that calls this arrives with the machines (RSF-F211 part 2).
---@return table|nil snapshot, string|nil reason
function MaterialWetness:collectedSnapshot(fillTypeIndex, cells)
    if not self:isArmed() then return nil, "NOT_ARMED" end
    local usable, why = MaterialWetness.nativeTypeUsable(fillTypeIndex)
    if not usable then return nil, why end
    local coord = self:groundCoordinator()
    if coord == nil then return nil, "NO_GROUND_FAMILY" end
    if type(cells) ~= "table" then return nil, "SOURCE_VALUE" end
    return self:captureSnapshot(MaterialWetness.BASIS.COLLECTED, fillTypeIndex, coord, cells)
end

--- THE PRODUCER'S SEAL. The producer hands the independently observed native accepted
--- carrier amount A and the ENTIRE allocation, every unknown or refused portion
--- included: { { id, carrierLitres, rawLitres }, ... }. Raw source litres are checked
--- against the snapshot's availability in raw units; carrier litres are never compared
--- with raw. Parts are put in canonical order (by id) before summing, and the sum must
--- equal A exactly (the producer assigns the final remainder to the final positive
--- canonical part). A zero A makes no material result. Returns the receipt, a
--- reference to this sealed allocation; the facts stay here, not with the caller.
---@return table|nil receipt, string|nil reason
function MaterialWetness:sealAllocation(snapshot, acceptedCarrierLitres, parts)
    local B = MaterialWetness.BASIS
    if not self:isArmed() then return nil, "NOT_ARMED" end
    if type(snapshot) ~= "table" or snapshot.basis ~= B.COLLECTED or type(snapshot.id) ~= "string"
       or type(snapshot.parts) ~= "table" then
        return nil, "BASIS_MISMATCH"
    end
    if not finiteNumber(acceptedCarrierLitres) or acceptedCarrierLitres <= 0 then return nil, "INVALID_PRODUCER_ACCEPTANCE" end
    if type(parts) ~= "table" or #parts == 0 then return nil, "PARTS_MISSING" end
    local sealed, seen = {}, {}
    for _, part in ipairs(parts) do
        if type(part) ~= "table" or type(part.id) ~= "string" or seen[part.id] then
            return nil, "DUPLICATE_OR_MALFORMED_PRODUCER_PORTION"
        end
        seen[part.id] = true
        if not finiteNumber(part.carrierLitres) or part.carrierLitres < 0 then return nil, "INVALID_PRODUCER_CARRIER_QUANTITY" end
        if not finiteNumber(part.rawLitres) or part.rawLitres < 0 then return nil, "INVALID_RAW_SOURCE_QUANTITY" end
        local source = snapshot.parts[part.id]
        if type(source) ~= "table" or not finiteNumber(source.available) or part.rawLitres > source.available then
            return nil, "SOURCE_AVAILABILITY"
        end
        sealed[#sealed + 1] = { id = part.id, carrierLitres = part.carrierLitres, rawLitres = part.rawLitres }
    end
    table.sort(sealed, function(a, b) return a.id < b.id end)
    local sum = 0
    for _, p in ipairs(sealed) do sum = sum + p.carrierLitres end
    if sum ~= acceptedCarrierLitres then return nil, "RECEIPT_TOTAL_MISMATCH" end

    self.allocationSeq = (self.allocationSeq or 0) + 1
    local allocationId = "allocation#" .. self.allocationSeq
    self.allocations[allocationId] = { sealed = true, snapshotId = snapshot.id,
                                       acceptedCarrierLitres = acceptedCarrierLitres, parts = sealed }
    self.allocationOrder[#self.allocationOrder + 1] = allocationId
    while #self.allocationOrder > MaterialWetness.MAX_ALLOCATIONS do
        self.allocations[table.remove(self.allocationOrder, 1)] = nil
    end
    local receiptParts = {}
    for i, p in ipairs(sealed) do receiptParts[i] = { id = p.id, q = p.carrierLitres } end
    return { allocationId = allocationId, snapshotId = snapshot.id, basis = B.COLLECTED,
             revision = snapshot.revision, total = acceptedCarrierLitres, parts = receiptParts }
end

--- The producer's sealed allocation behind a receipt. With StockGuard present and
--- publishing its receipt resolver (SG-2 build brief :60 and :358:
--- g_currentMission.stockGuard.readCollectionReceipt(receiptRef) -> sealed allocation or
--- UNAVAILABLE; its handle's functions are plain closures, StockGuard.lua:100-147),
--- StockGuard is the producer and its answer is the only one. Without it, Soil's own
--- seal. Never both: a second authority would be a parallel record.
---@return table|nil allocation, string source  "STOCKGUARD" or "SOIL"
function MaterialWetness:resolveAllocation(receipt)
    local mission = g_currentMission
    local sg = mission ~= nil and mission.stockGuard or nil
    if sg ~= nil and type(sg.readCollectionReceipt) == "function" then
        local ok, allocation = pcall(sg.readCollectionReceipt, receipt)
        if ok and type(allocation) == "table" then return allocation, "STOCKGUARD" end
        return nil, "STOCKGUARD"
    end
    if type(receipt) ~= "table" or type(receipt.allocationId) ~= "string" then return nil, "SOIL" end
    return self.allocations[receipt.allocationId], "SOIL"
end

--- THE COLLECTED READ: the receipt resolved against the producer's sealed allocation
--- (never the caller's own figures), each portion weighted by its sealed carrier litres
--- and classified by its source's condition at capture. Always returns the coverage for
--- a valid physical receipt. A malformed or unmatchable receipt is UNAVAILABLE: its
--- caller accounts the independently observed accepted amount as unknown rather than
--- dropping those litres. A caller cannot lower the total or delete a portion to hide
--- material. RSF-F211's reference model, with the RESULT constants.
function MaterialWetness:readCollectedCondition(snapshot, receipt)
    local R, B, S = MaterialWetness.RESULT, MaterialWetness.BASIS, MaterialWetness.SOURCE
    local function unavailable(reason) return coverageResult(B.COLLECTED, R.UNAVAILABLE, reason) end
    local function refusal(reason) return coverageResult(B.COLLECTED, R.REFUSAL, reason) end
    if not self:isArmed() then return unavailable("NOT_ARMED") end
    if type(snapshot) ~= "table" or type(receipt) ~= "table" then return unavailable("MALFORMED") end
    if type(snapshot.id) ~= "string" or snapshot.id == "" or type(receipt.snapshotId) ~= "string" or receipt.snapshotId == "" then
        return unavailable("INVALID_SNAPSHOT_ID")
    end
    if snapshot.basis ~= B.COLLECTED or receipt.basis ~= B.COLLECTED then return unavailable("BASIS_MISMATCH") end
    if snapshot.revision == nil or receipt.revision == nil then return unavailable("REVISION_MISMATCH") end
    if snapshot.id ~= receipt.snapshotId then return unavailable("SNAPSHOT_MISMATCH") end
    if GroundConditionCoordinator == nil or not GroundConditionCoordinator.revisionsEqual(snapshot.revision, receipt.revision) then
        return unavailable("REVISION_MISMATCH")
    end
    if type(snapshot.parts) ~= "table" or type(receipt.parts) ~= "table" then return unavailable("PARTS_MISSING") end

    local producer = self:resolveAllocation(receipt)
    if type(producer) ~= "table" or producer.sealed ~= true then return unavailable("PRODUCER_SEAL_MISSING") end
    if producer.snapshotId ~= nil and producer.snapshotId ~= snapshot.id then return unavailable("SNAPSHOT_MISMATCH") end
    local accepted = producer.acceptedCarrierLitres
    if not finiteNumber(accepted) or accepted <= 0 or type(producer.parts) ~= "table" then
        return unavailable("INVALID_PRODUCER_ACCEPTANCE")
    end
    local total = receipt.total
    if not finiteNumber(total) or total <= 0 then return refusal("INVALID_TOTAL") end
    if total ~= accepted then return unavailable("CALLER_ACCEPTANCE_MISMATCH") end

    local seen, claimed = {}, {}
    for _, portion in ipairs(receipt.parts) do
        if type(portion) ~= "table" or type(portion.id) ~= "string" or seen[portion.id] then
            return unavailable("DUPLICATE_OR_MALFORMED_PORTION")
        end
        seen[portion.id] = true
        if not finiteNumber(portion.q) or portion.q < 0 then return refusal("INVALID_PORTION_QUANTITY") end
        claimed[portion.id] = portion.q
    end

    local out = coverageResult(B.COLLECTED, nil, nil)
    local sealedSeen, rawTotal = {}, 0
    for _, portion in ipairs(producer.parts) do
        if type(portion) ~= "table" or type(portion.id) ~= "string" or sealedSeen[portion.id] then
            return unavailable("DUPLICATE_OR_MALFORMED_PRODUCER_PORTION")
        end
        sealedSeen[portion.id] = true
        local q, raw = portion.carrierLitres, portion.rawLitres
        if not finiteNumber(q) or q < 0 then return unavailable("INVALID_PRODUCER_CARRIER_QUANTITY") end
        if not finiteNumber(raw) or raw < 0 then return unavailable("INVALID_RAW_SOURCE_QUANTITY") end
        local source = snapshot.parts[portion.id]
        if type(source) ~= "table" or not finiteNumber(source.available) or source.available < 0 or raw > source.available then
            return unavailable("SOURCE_AVAILABILITY")
        end
        if claimed[portion.id] == nil or claimed[portion.id] ~= q then return unavailable("CALLER_ALLOCATION_MISMATCH") end
        if q > 0 then
            out.carrierLitres = out.carrierLitres + q
            rawTotal = rawTotal + raw
            -- A positive carrier with no raw source is explicitly unknown produced material.
            if raw == 0 or source.status == S.UNKNOWN then
                out.unknownCarrierLitres = out.unknownCarrierLitres + q
            elseif source.status == S.REFUSAL then
                out.refusedCarrierLitres = out.refusedCarrierLitres + q
            elseif source.status == S.KNOWN then
                if not finiteNumber(source.pct) or source.pct < 0 or source.pct > 100 then return unavailable("SOURCE_VALUE") end
                out.knownCarrierLitres = out.knownCarrierLitres + q
                out.knownWeightedPctSum = out.knownWeightedPctSum + q * source.pct
            else
                out.unknownCarrierLitres = out.unknownCarrierLitres + q
            end
        end
    end
    for id in pairs(claimed) do
        if not sealedSeen[id] then return unavailable("CALLER_ALLOCATION_MISMATCH") end
    end
    if out.carrierLitres ~= accepted or out.carrierLitres ~= total then return unavailable("RECEIPT_TOTAL_MISMATCH") end
    out.rawSourceLitres = rawTotal
    if out.unknownCarrierLitres > 0 or out.refusedCarrierLitres > 0 then
        out.status, out.reason = R.REFUSAL, "POSITIVE_UNKNOWN_OR_REFUSAL"
    else
        out.status, out.reason = R.OK, "COMPLETE_KNOWN_COVERAGE"
        out.pct = out.knownWeightedPctSum / out.carrierLitres
        out.band = MaterialWetness.bandForPct(out.pct)
    end
    return out
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
