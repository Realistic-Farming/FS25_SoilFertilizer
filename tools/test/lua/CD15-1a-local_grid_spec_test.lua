-- CD15-1a-local_grid_spec_test.lua
--
-- CD-15 step 1a (brief v1.14 :67-135, :216, :222; Bob's intake
-- Drafts/BOB-INTAKE-CD15-STEP1-2026-09-30.md): the schema-1 cell record, the sparse
-- 32x32 tile store, the geometry and its fingerprint, the CD-15 day clock, the
-- ratified clean baseline, and the daily local pass with one-hop snapshotted spread
-- and a 256-cell work bound, beside the old field model.
--
-- THE ENTRY-POINT BAR IS GROUP E. Production's SoilFertilitySystem.new builds the
-- model beside its value maps; the value maps initialize on the SF-995 engine model
-- (SoilFertilitySystem:initialize :304-306 calls exactly that); the day arrives
-- through the real onEnvironmentUpdate new-day branch and the work through the real
-- update(dt). The geometry comes from those value maps and the engine's default fruit
-- plane size. Nothing sets a grid, a day or a status by hand.
--
-- The rule groups (F, S, P, B) need cells, and nothing allocates a cell before 1c's
-- admission or step 2's writers: their cells are bench-made, the one hand-populated
-- fixture in this file, put through the store's own validation.
--
-- Groups:
--   E  the entry-point bar: bind, clean baseline, one day closed with no work; a client idles
--   K  the clock: Time Guard, the environment, missing, backward, zero; never currentDay
--   F  one cell, one day: the field formula term for term, local inputs, protection,
--      identity, the meadow, the setting
--   S  a skipped interval closes UNAVAILABLE and changes nothing
--   P  spread: one hop from a snapshot, identity rules, order, admission
--   B  the 256-cell work bound, one settlement per cell per day
--   R  the record and the tile store
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/DiseaseSystem.lua, src/utils/SoilUtils.lua, src/utils/SoilContextInput.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/FieldSentry.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/disease/CD15Grid.lua, src/disease/CD15Day.lua, src/disease/CD15Model.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end

local G, D, M = CD15Grid, CD15Day, CD15Model
local dp = SoilConstants.DISEASE_PRESSURE

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 1000000 + 0.5) / 1000000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end
local function count(list, pattern) local n = 0 for _, l in ipairs(list) do if l:find(pattern, 1, true) then n = n + 1 end end return n end

-- ── the engine surface beside SF-995's model ────────────────────────────────
local NATIVE_PLANE, NATIVE_SIZE = 7, 4096
function getDensityMapSize(id) if id == NATIVE_PLANE then return NATIVE_SIZE end return nil end
g_fruitTypeManager = g_fruitTypeManager or {}
function g_fruitTypeManager:getDefaultDataPlaneId() return NATIVE_PLANE end
delete = delete or function(_id) end   -- the engine's object delete (value maps teardown)

-- ── the world ───────────────────────────────────────────────────────────────
local RAIN = { scale = 0 }
local W = { fields = {}, moisture = nil, grain = nil }
local SETTINGS = { enabled = true, diseasePressure = true, diseaseMoisture = 2, diseaseDifficulty = 2, cropRotation = true, tuningDiseaseGrowth = 3 }

--- Production's system on a fresh engine. opts: day, dpp, season, client, timeGuard, settings.
local function world(opts)
    opts = opts or {}
    INFO, WARN = {}, {}
    g_server = (not opts.client) and {} or nil
    g_timeGuard = nil
    W.env = { currentMonotonicDay = opts.day, currentDay = 1, daysPerPeriod = opts.dpp or 3, currentSeason = opts.season or 1,
              weather = { getRainFallScale = function() return RAIN.scale end } }
    W.fields, W.moisture, W.grain = {}, nil, nil
    g_currentMission = { environment = W.env, missionInfo = {}, timeGuard = opts.timeGuard,
        cropStressManager = { getMoisture = function(_, _fid, _x, _z) return W.moisture, W.grain, 1 end } }
    local settings = {}
    for k, v in pairs(SETTINGS) do settings[k] = v end
    for k, v in pairs(opts.settings or {}) do settings[k] = v end
    g_SoilFertilityManager = { settings = settings }
    local sys = SoilFertilitySystem.new(settings)
    g_SoilFertilityManager.soilSystem = sys
    sys.valueMaps:initialize(nil)
    -- The native field lookup (HookManager:getFieldIdAtWorldPosition), from the bench's field map.
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, z) return W.fieldAt ~= nil and W.fieldAt(x, z) or 1 end
    FieldSentry_Core.FieldState = {}
    W.sys = sys
    return sys, sys.cd15
end
--- The existing daily settlement: a new calendar day through onEnvironmentUpdate.
local function newDay(sys, monoDay)
    W.env.currentMonotonicDay = monoDay
    W.env.currentDay = (W.env.currentDay or 0) + 1
    sys:onEnvironmentUpdate(W.env, 16)
end
local function tick(sys, n) for _ = 1, (n or 1) do sys:update(16) end end
--- Bind the grid through a first day with nothing in it.
local function bound(opts)
    local sys, m = world(opts)
    newDay(sys, (opts and opts.day) or 100)
    tick(sys)
    return sys, m
end
--- A bench-made cell (the one hand-populated fixture: no writer exists before 1c).
local function cell(m, fields)
    local c = G.baselineCell(m.geometry.fingerprint)
    for k, v in pairs(fields or {}) do c[k] = v end
    return c
end
local function put(m, gx, gz, fields) local ok, why = m.store:put(gx, gz, cell(m, fields)) if not ok then error("put " .. tostring(why)) end return m.store:get(gx, gz) end
local function meadow(fieldId) FieldSentry_Core.FieldState[fieldId] = { evaluatedBlacklist = FieldSentry_Core.BLACKLIST.NONE, meadowToggle = true } end
local function disabled(fieldId) FieldSentry_Core.FieldState[fieldId] = { evaluatedBlacklist = FieldSentry_Core.BLACKLIST.CONTRACT or 1, meadowToggle = false } end

-- Wheat's catalogue diseases, and one wheat cannot carry.
local WHEAT = SoilDiseaseSystem.cropDiseases("wheat")
local X, Y = WHEAT[1], WHEAT[2]
local FOREIGN = nil
for id in pairs(SoilConstants.DISEASE_DEFS) do
    local inWheat = false
    for _, w in ipairs(WHEAT) do if w == id then inWheat = true end end
    if not inWheat and not HybridStrains.isHybrid(id) then FOREIGN = FOREIGN == nil and id or (id < FOREIGN and id or FOREIGN) end
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    local sys, m = world({ day = 100 })
    local fieldDataBefore = next(sys.fieldData)
    T.ok("E1 [reached] production's constructor built the model beside the value maps; before any day it is PENDING with no geometry",
        m ~= nil and getmetatable(m).__index == CD15Model and m.state == "PENDING" and m.geometry == nil)
    newDay(sys, 100)
    local s = m:getStatus()
    T.eq("E2 the first day through onEnvironmentUpdate bound the grid from the real value maps and the native plane: no hand-set grid",
        tostring(s.state) .. "|" .. tostring(s.fingerprint) .. "|" .. num(m.geometry and m.geometry.cellSize),
        "READY|cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED|0.0625")
    T.eq("E3 first activation on the ratified clean baseline, earlier history explicitly unavailable, said once",
        tostring(s.baseline) .. "/" .. tostring(s.historyAvailable) .. "/" .. count(INFO, "[CD15] local disease grid ready: cd15Disease:1"), "CLEAN_FIRST_ACTIVATION/false/1")
    T.eq("E4 the day came from environment.currentMonotonicDay and one day of work is queued", tostring(s.lastDay) .. "/" .. tostring(s.daySource) .. "/" .. s.pendingDays, "100/ENVIRONMENT/1")
    tick(sys)
    s = m:getStatus()
    T.eq("E5 the real update(dt) closed day 100 with no cells and no work: production has none before 1c", tostring(s.lastClosedDay) .. "/" .. s.cells .. "/" .. s.pendingDays .. "/" .. s.maxWork, "100/0/0/0")
    T.eq("E6 nothing outside the grid changed: the field model's data is as it was", tostring(next(sys.fieldData) == fieldDataBefore), "true")
    local csys, cm = world({ day = 100, client = true })
    newDay(csys, 100)
    tick(csys)
    T.eq("E7 a client holds an idle model: no geometry, no day, no work", tostring(cm.state) .. "/" .. tostring(cm.lastDay) .. "/" .. #cm.queue, "PENDING/nil/0")
    sys:delete()
    T.eq("E8 teardown releases the model", tostring(sys.cd15), "nil")
    local realSize = getDensityMapSize
    getDensityMapSize = function() return nil end
    local nsys, nm = world({ day = 100 })
    newDay(nsys, 100)
    tick(nsys)
    getDensityMapSize = realSize
    T.eq("E9 without the native plane size there is no grid and no day work: UNAVAILABLE with its reason, never a guessed grid",
        tostring(nm.state) .. "/" .. tostring(nm.reason) .. "/" .. tostring(nm.lastDay) .. "/" .. #nm.queue, "UNAVAILABLE/NATIVE_MAP_SIZE/nil/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- K. THE CLOCK (brief :107)
-- ══════════════════════════════════════════════════════════════════════════
group("K", function()
    local tg = { getCounter = function(_, cadence) if cadence == "day" then return 250 end return nil end,
                 getContext = function() return { daysPerPeriod = 5, monotonicDay = 999 } end }
    local sys, m = world({ day = 100, timeGuard = tg })
    newDay(sys, 100)
    T.eq("K1 with Time Guard the day is its getCounter(\"day\") only (not the environment's, not getContext's), and its context supplies daysPerPeriod",
        tostring(m.lastDay) .. "/" .. tostring(m.daySource) .. "/" .. tostring(m.queue[1] and m.queue[1].input.daysPerMonth), "250/TIMEGUARD/5")
    local tgNil = { getCounter = function() return nil end, getContext = function() return { daysPerPeriod = 0 } end }
    sys, m = world({ day = 100, timeGuard = tgNil })
    newDay(sys, 100)
    T.eq("K2 Time Guard answering nil is UNAVAILABLE, never the environment fallback", tostring(m.lastDay) .. "/" .. tostring(m.dayReason) .. "/" .. #m.queue, "nil/DAY_UNAVAILABLE/0")
    local tgZero = { getCounter = function() return 0 end, getContext = function() return { daysPerPeriod = 0 } end }
    sys, m = world({ day = 100, timeGuard = tgZero })
    newDay(sys, 100)
    T.eq("K3 a real zero from getCounter is a valid day; the context's zero daysPerPeriod falls to the environment's", tostring(m.lastDay) .. "/" .. tostring(m.queue[1] and m.queue[1].input.daysPerMonth), "0/3")
    sys, m = world({ day = nil })
    newDay(sys, nil)
    T.eq("K4 no monotonic day (currentDay alone) is UNAVAILABLE: currentDay is never the fallback", tostring(m.lastDay) .. "/" .. tostring(m.dayReason) .. "/" .. #m.queue, "nil/DAY_UNAVAILABLE/0")
    sys, m = bound({ day = 100 })
    local c = put(m, 5, 5, { cropName = "wheat", pressure = 30, cropOccurrence = "o1" })
    newDay(sys, 90)
    tick(sys)
    T.eq("K5 a backward day is UNAVAILABLE and settles nothing", tostring(m.lastDay) .. "/" .. tostring(m.dayReason) .. "/" .. num(c.pressure) .. "/" .. tostring(c.lastSettledDay), "100/DAY_BACKWARD/30/nil")
    sys, m = bound({ day = 100 })
    W.env.daysPerPeriod = nil
    newDay(sys, 101)
    T.eq("K6 no daysPerPeriod anywhere: the day closes UNAVAILABLE with its reason, no work queued",
        #m.queue .. "/" .. tostring(m.gaps[#m.gaps] and (m.gaps[#m.gaps].from .. "-" .. m.gaps[#m.gaps].to .. ":" .. m.gaps[#m.gaps].reason)), "0/101-101:DAYS_PER_PERIOD_UNAVAILABLE")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. ONE CELL, ONE DAY (brief :127-133, the field formula at SoilFertilitySystem.lua:5560-5626)
-- ══════════════════════════════════════════════════════════════════════════
local function oneDay(m, sys, day, fields, opts)
    opts = opts or {}
    local c = put(m, opts.gx or 5, opts.gz or 5, fields)
    RAIN.scale = opts.rain or 0
    newDay(sys, day)
    tick(sys, opts.ticks or 1)
    return c
end
group("F", function()
    local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[2]
    local diff = SoilConstants.DISEASE_DIFFICULTY[2]
    local tun = SoilConstants.TUNING.ZERO_MULT[3]
    local dpm = 3
    local sys, m = bound({ day = 100, season = 1 })
    local c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 10, cropOccurrence = "o1" }, { rain = 1.0 })
    local want = math.min(100, 10 + (dp.GROWTH_RATE_LOW * cm.growthMult * dp.SEASONAL_SPRING * dp.CROP_SUSCEPTIBILITY.wheat * tun * (diff.pressureMult or 1) * 1 * 1 * 1
        + dp.RAIN_BONUS * cm.rainBonusMult) / dpm)
    T.eq("F1 a wet spring day on living wheat grows by the field formula term for term, over one day", num(c.pressure) .. "/" .. c.dryDayCount .. "/" .. tostring(c.lastSettledDay), num(want) .. "/0/101")

    sys, m = bound({ day = 100, season = 1 })
    local x, z = G.cellCentre(m.geometry, 5, 5)
    sys.valueMaps:writeValueAtWorld("pH", x, z, 5.5, m.geometry.cellSize)
    local readBack = sys.valueMaps:readValueAtWorld("pH", x, z)
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 10, cropOccurrence = "o1" }, { rain = 1.0 })
    local soil = SoilConstants.DISEASE_SOIL_HEALTH.LOW_PH_MULT
    want = math.min(100, 10 + (dp.GROWTH_RATE_LOW * cm.growthMult * dp.SEASONAL_SPRING * dp.CROP_SUSCEPTIBILITY.wheat * tun * (diff.pressureMult or 1) * soil * 1 * 1
        + dp.RAIN_BONUS * cm.rainBonusMult) / dpm)
    T.eq("F2 the cell's own low pH, read from the value map at its centre, applies its branch; N and OM unknown apply none",
        tostring(readBack ~= nil and readBack < SoilConstants.DISEASE_SOIL_HEALTH.LOW_PH_THRESHOLD) .. "/" .. num(c.pressure) .. "/" .. num(D.localSoilHealthMult({ pH = 5.5 })) .. "/" .. select(2, D.localSoilHealthMult({ pH = 5.5 })),
        "true/" .. num(want) .. "/" .. num(soil) .. "/PARTIAL")

    sys, m = bound({ day = 100 })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 0, cropOccurrence = "o1", resistance = { dmi = 0.5, qoi = 0.0101 } })
    local decay = SoilConstants.RESISTANCE.DECAY_MONTHLY ^ (1 / dpm)
    T.eq("F3 resistance decays by DECAY_MONTHLY^(1/daysPerMonth); below .01 it is zero", num(c.resistance.dmi) .. "/" .. num(c.resistance.qoi), num(0.5 * decay) .. "/0")

    sys, m = bound({ day = 100 })
    local droughtDays = math.ceil(cm.dryThreshold * dpm * (dp.DROUGHT_THRESHOLD_MULT or 2))
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 40, cropOccurrence = "o1", dryDayCount = droughtDays - 1 })
    T.eq("F4 the day that reaches the drought threshold decays pressure by DRY_DECAY_RATE * dryDecayMult / daysPerMonth",
        num(c.pressure) .. "/" .. c.dryDayCount, num(40 - dp.DRY_DECAY_RATE * cm.dryDecayMult / dpm) .. "/" .. droughtDays)

    sys, m = bound({ day = 100 })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 30, cropOccurrence = "o1", protection = { dmi = 105 } }, { rain = 1.0 })
    T.eq("F5 an expiry after the day suppresses growth, and the expiry is compared, never decremented", num(c.pressure) .. "/" .. c.protection.dmi, "30/105")
    sys, m = bound({ day = 104 })
    c = oneDay(m, sys, 105, { cropName = "wheat", pressure = 30, cropOccurrence = "o1", protection = { dmi = 105 } }, { rain = 1.0 })
    T.eq("F5b on the expiry day itself protection no longer holds (expiry > day): growth resumes", tostring(c.pressure > 30), "true")

    sys, m = bound({ day = 100 })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = dp.LOW * 0.5 - 0.001, cropOccurrence = "o1" }, { rain = 1.0 })
    T.eq("F6 onset at LOW*.5 names a catalogue disease of this crop, deterministically, and it starts undiscovered",
        tostring(D.cropCompatible(c.diseaseName, "wheat")) .. "/" .. tostring(c.discovered), "true/false")
    local first = c.diseaseName
    sys, m = bound({ day = 100 })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = dp.LOW * 0.5 - 0.001, cropOccurrence = "o1" }, { rain = 1.0 })
    T.eq("F6b the same cell, day and field choose the same identity again", tostring(c.diseaseName == first), "true")
    sys, m = bound({ day = 100 })
    local hybrid = HybridStrains.strainForPair({ lastCrop = "wheat" })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = dp.LOW * 0.25 - 1, cropOccurrence = "o1", diseaseName = hybrid, discovered = true })
    T.eq("F7 below LOW*.25 the identity clears; a hybrid arms its cooldown at day + cooldownDays(daysPerMonth)",
        tostring(c.diseaseName) .. "/" .. tostring(c.discovered) .. "/" .. tostring(c.hybridCooldownExpiryDay), "nil/false/" .. tostring(101 + HybridStrains.cooldownDays(dpm)))

    sys, m = bound({ day = 100 })
    c = oneDay(m, sys, 101, { pressure = 30, resistance = { dmi = 0.5 } }, { rain = 1.0 })
    local noCrop = math.min(100, 30 + (dp.GROWTH_RATE_MID * cm.growthMult * dp.SEASONAL_SPRING * 1 * tun * (diff.pressureMult or 1) * 1 * 1 * 1
        + dp.RAIN_BONUS * cm.rainBonusMult) / dpm)
    T.eq("F8 no living crop: the formula still applies (:129), with no crop-specific modifier (:131); onset needs a crop; resistance decays",
        num(c.pressure) .. "/" .. tostring(c.diseaseName) .. "/" .. num(c.resistance.dmi), num(noCrop) .. "/nil/" .. num(0.5 * decay))

    sys, m = bound({ day = 100 })
    W.fieldAt = function() return 9 end
    meadow(9)
    -- An expired protection (it suppresses nothing) and a dry day with a running count, so
    -- only the exemption keeps the pressure and the count still.
    c = oneDay(m, sys, 101, { cropName = "grass", pressure = 30, cropOccurrence = "o1", resistance = { dmi = 0.5 }, protection = { dmi = 50 }, dryDayCount = 2 }, { rain = 0 })
    T.eq("F9 a meadow cell gets resistance decay only: history and protection kept, no growth, no dry-day count", num(c.pressure) .. "/" .. num(c.resistance.dmi) .. "/" .. c.protection.dmi .. "/" .. c.dryDayCount,
        "30/" .. num(0.5 * decay) .. "/50/2")
    sys, m = bound({ day = 100 })
    W.fieldAt = function() return 8 end
    disabled(8)
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 30, cropOccurrence = "o1", resistance = { dmi = 0.5 } }, { rain = 1.0 })
    T.eq("F10 a field FieldSentry disables is not settled at all (the field pass returns first): not even decay", num(c.pressure) .. "/" .. num(c.resistance.dmi) .. "/" .. tostring(c.lastSettledDay), "30/0.5/101")
    W.fieldAt = nil

    sys, m = bound({ day = 100, settings = { diseasePressure = false } })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 30, cropOccurrence = "o1", resistance = { dmi = 0.5 } }, { rain = 1.0 })
    T.eq("F11 with the disease setting off, resistance decays and nothing else moves", num(c.pressure) .. "/" .. num(c.resistance.dmi) .. "/" .. c.dryDayCount, "30/" .. num(0.5 * decay) .. "/0")

    sys, m = bound({ day = 100 })
    c = oneDay(m, sys, 101, { cropName = "wheat", pressure = 10, cropOccurrence = "o1",
        cropHistory = { { occurrenceId = "h1", cropName = "wheat" }, { occurrenceId = "h0", cropName = "wheat" } } }, { rain = 1.0 })
    local rot = SoilConstants.DISEASE_ROTATION.MONO_2YR_MULT
    want = math.min(100, 10 + (dp.GROWTH_RATE_LOW * cm.growthMult * dp.SEASONAL_SPRING * dp.CROP_SUSCEPTIBILITY.wheat * tun * (diff.pressureMult or 1) * 1 * rot * 1
        + dp.RAIN_BONUS * cm.rainBonusMult) / dpm)
    T.eq("F12 rotation reads the cell's own harvested history (wheat after wheat), newest first", num(c.pressure), num(want))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. A SKIPPED INTERVAL (brief :107)
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    local sys, m = bound({ day = 100 })
    local c = oneDay(m, sys, 104, { cropName = "wheat", pressure = 10, cropOccurrence = "o1" }, { rain = 1.0 })
    local g = m.gaps[#m.gaps]
    T.eq("S1 four days in one update: 101-103 had no captured input and close UNAVAILABLE, recorded; only day 104 is settled, once",
        tostring(g and (g.from .. "-" .. g.to .. ":" .. g.reason)) .. "/" .. c.sourceRevision .. "/" .. tostring(c.lastSettledDay), "101-103:NO_CAPTURED_INPUT/1/104")
    local sys2, m2 = bound({ day = 100 })
    local c2 = oneDay(m2, sys2, 101, { cropName = "wheat", pressure = 10, cropOccurrence = "o1" }, { rain = 1.0 })
    T.eq("S2 and it grew exactly one day's worth, the same as a single ordinary day", num(c.pressure), num(c2.pressure))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. SPREAD (brief :115-124)
-- ══════════════════════════════════════════════════════════════════════════
local LIVE = { cropName = "wheat", cropOccurrence = "o1" }
--- One wet spring day's own growth of a living wheat cell from pressure p (tier LOW), and
--- the day's resistance decay: every living destination is settled before the spread.
local function grow(p)
    local cm = SoilConstants.DISEASE_CLIMATE_MOISTURE[2]
    local diff = SoilConstants.DISEASE_DIFFICULTY[2]
    return p + (dp.GROWTH_RATE_LOW * cm.growthMult * dp.SEASONAL_SPRING * dp.CROP_SUSCEPTIBILITY.wheat * SoilConstants.TUNING.ZERO_MULT[3] * (diff.pressureMult or 1)
        + dp.RAIN_BONUS * cm.rainBonusMult) / 3
end
local DECAY = SoilConstants.RESISTANCE.DECAY_MONTHLY ^ (1 / 3)
local function live(extra) local t = {} for k, v in pairs(LIVE) do t[k] = v end for k, v in pairs(extra or {}) do t[k] = v end return t end
group("P", function()
    local sys, m = bound({ day = 100 })
    local src = put(m, 10, 10, live({ diseaseName = X, pressure = 50, discovered = true, resistance = { dmi = 0.6 } }))
    local e = put(m, 11, 10, live({ resistance = { dmi = 0.2, qoi = 0.3 } }))
    local wv = put(m, 9, 10, live())
    local n = put(m, 10, 11, live())
    local s = put(m, 10, 9, live())
    local far = put(m, 12, 10, live())
    RAIN.scale = 1.0
    newDay(sys, 101)
    tick(sys)
    T.eq("P1 one cardinal hop: each living neighbour adopts the identity undiscovered and gains 4 points over its own day; two cells away nothing",
        tostring(e.diseaseName == X and wv.diseaseName == X and n.diseaseName == X and s.diseaseName == X) .. "/" .. tostring(e.discovered) .. "/" .. num(e.pressure) .. "/" .. tostring(far.diseaseName),
        "true/false/" .. num(grow(0) + 4) .. "/nil")
    T.eq("P2 a clean destination merges every mode by max: receiving history is kept", num(e.resistance.dmi) .. "/" .. num(e.resistance.qoi), num(0.6 * DECAY) .. "/" .. num(0.3 * DECAY))
    T.eq("P3 a cell infected this pass is not a same-pass source: the cell beyond it has only its own day", tostring(far.diseaseName) .. "/" .. num(far.pressure), "nil/" .. num(grow(0)))

    sys, m = bound({ day = 100 })
    local a = put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    local comp = put(m, 11, 10, live({ diseaseName = Y, pressure = 15, resistance = { dmi = 0.1 } }))
    RAIN.scale = 1.0
    newDay(sys, 101)
    local compBefore = grow(15)
    tick(sys)
    T.eq("P4 a competing identity takes neither pressure nor resistance from the source: only its own day", tostring(comp.diseaseName == Y) .. "/" .. num(comp.pressure - compBefore) .. "/" .. num(comp.resistance.dmi), "true/0/" .. num(0.1 * DECAY))

    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = Y, pressure = 50 }))     -- tile (0,0) key 330: earlier
    put(m, 12, 10, live({ diseaseName = X, pressure = 50 }))     -- key 332: later
    local mid = put(m, 11, 10, live())
    RAIN.scale = 1.0
    newDay(sys, 101)
    tick(sys)
    T.eq("P5 two identities reach one clean cell: the first source in (tz, tx, localKey) order wins; the later adds nothing",
        tostring(mid.diseaseName == Y) .. "/" .. num(mid.pressure), "true/" .. num(grow(0) + 4))

    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    put(m, 12, 10, live({ diseaseName = X, pressure = 50 }))
    local both = put(m, 11, 10, live({ diseaseName = X, pressure = 98 }))
    RAIN.scale = 1.0
    newDay(sys, 101)
    local pre = both.pressure
    tick(sys)
    T.eq("P6 the same identity from two sources adds 4 each, bounded at 100", num(both.pressure), "100")

    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    local prot = put(m, 11, 10, live({ protection = { dmi = 200 } }))
    local foreign = put(m, 9, 10, { cropName = "potato", cropOccurrence = "o9" })
    local bare = put(m, 10, 11, {})
    RAIN.scale = 1.0
    newDay(sys, 101)
    tick(sys)
    local fOk = FOREIGN ~= nil and D.cropCompatible(X, "potato") == false
    T.eq("P7 a protected destination, a crop the disease does not belong to and a cell without a living crop take nothing",
        tostring(prot.diseaseName) .. "/" .. tostring(fOk and foreign.diseaseName == nil) .. "/" .. tostring(bare.diseaseName), "nil/true/nil")
    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = X, pressure = 50, protection = { dmi = 200 } }))
    local nb = put(m, 11, 10, live())
    RAIN.scale = 1.0
    newDay(sys, 101)
    tick(sys)
    T.eq("P8 a protected source does not spread", tostring(nb.diseaseName), "nil")

    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    local dry = put(m, 11, 10, live())
    RAIN.scale = 0
    newDay(sys, 101)
    tick(sys)
    T.eq("P9 a dry day with no fine moisture fact: the weather flag says not conducive, nothing spreads", tostring(dry.diseaseName), "nil")
    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    local wetCell = put(m, 11, 10, live())
    W.moisture, W.grain = 0.8, 0.05
    RAIN.scale = 0
    newDay(sys, 101)
    tick(sys)
    T.eq("P10 SCS positional moisture >= .75 at a grain no coarser than the cell is wet on a dry day: it spreads", tostring(wetCell.diseaseName == X), "true")
    sys, m = bound({ day = 100 })
    put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    local coarse = put(m, 11, 10, live())
    W.moisture, W.grain = 0.9, 2.0
    RAIN.scale = 0
    newDay(sys, 101)
    tick(sys)
    T.eq("P11 a coarser SCS grain is no fine fact: the dry weather flag decides, nothing spreads", tostring(coarse.diseaseName), "nil")
    W.moisture, W.grain = nil, nil

    sys, m = bound({ day = 100 })
    W.fieldAt = function(x, _z) if x > G.cellCentre(m.geometry, 10, 10) then return 9 end return 1 end
    meadow(9)
    put(m, 10, 10, live({ diseaseName = X, pressure = 50 }))
    local mead = put(m, 11, 10, live({ cropName = "wheat" }))
    RAIN.scale = 1.0
    newDay(sys, 101)
    tick(sys)
    T.eq("P12 a meadow destination takes no spread", tostring(mead.diseaseName), "nil")
    W.fieldAt = nil
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE WORK BOUND (brief :127)
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local sys, m = bound({ day = 100 })
    for i = 0, 599 do put(m, i % 40, math.floor(i / 40), live({ pressure = 5 })) end
    RAIN.scale = 1.0
    newDay(sys, 101)
    local per = {}
    for _ = 1, 4 do
        local before = m.stats.settled
        tick(sys)
        per[#per + 1] = m.stats.settled - before
    end
    T.eq("B1 600 cells settle 256, 256, 88 over three updates, at most 256 a call; the day then closes", table.concat(per, ",") .. "/" .. m.stats.maxWork .. "/" .. tostring(m.lastClosedDay), "256,256,88,0/256/101")
    local once = true
    for _, e in ipairs(m.store:orderedCells()) do if m.store:get(e.gx, e.gz).sourceRevision ~= 1 then once = false end end
    T.eq("B2 every cell was settled exactly once for the day", tostring(once), "true")
    newDay(sys, 102)
    m:settleEntry({ gx = 0, gz = 0 }, m.queue[1].input)
    local rev = m.store:get(0, 0).sourceRevision
    tick(sys, 3)
    T.eq("B3 a cell already settled through the day is skipped by the cursor, not settled twice", tostring(m.store:get(0, 0).sourceRevision == rev) .. "/" .. rev, "true/2")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RECORD AND THE STORE (brief :67-81, :216)
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local tx, tz, k = G.tileOf(33, 70)
    T.eq("R1 the tile key: tx = floor(gx/32), tz = floor(gz/32), localKey = (gz-32tz)*32 + (gx-32tx)", tx .. "/" .. tz .. "/" .. k .. "/" .. table.concat({ G.cellOf(tx, tz, k) }, ","), "1/2/193/33,70")
    local s = G.newStore()
    local fp = "cd15Disease:1;test"
    s:put(40, 1, G.baselineCell(fp)) s:put(3, 1, G.baselineCell(fp)) s:put(2, 40, G.baselineCell(fp)) s:put(1, 1, G.baselineCell(fp))
    local order = {}
    for _, e in ipairs(s:orderedCells()) do order[#order + 1] = e.gx .. ":" .. e.gz end
    T.eq("R2 order: tiles by tz then tx, keys ascending inside a tile", table.concat(order, ","), "1:1,3:1,40:1,2:40")
    local bad = G.baselineCell(fp)
    bad.diseaseName = "not_a_disease"
    local ok, why = s:put(5, 5, bad)
    local bad2 = G.baselineCell(fp)
    bad2.pressure = 101
    local ok2, why2 = s:put(5, 5, bad2)
    local bad3 = G.baselineCell(fp)
    bad3.discovered = true
    local ok3, why3 = s:put(5, 5, bad3)
    T.eq("R3 a record is validated before use: an unknown disease name, pressure outside 0..100, discovered without an identity", tostring(ok) .. ":" .. tostring(why) .. "/" .. tostring(ok2) .. ":" .. tostring(why2) .. "/" .. tostring(ok3) .. ":" .. tostring(why3),
        "false:DISEASE_NAME/false:PRESSURE/false:DISCOVERED_WITHOUT_IDENTITY")
    T.eq("R4 the clean baseline is exactly the ratified one", (function()
        local c = G.baselineCell(fp)
        return num(c.pressure) .. "/" .. tostring(c.diseaseName) .. "/" .. tostring(next(c.resistance)) .. "/" .. tostring(next(c.protection)) .. "/" .. #c.cropHistory .. "/" .. tostring(c.hybridCooldownExpiryDay) .. "/" .. tostring(c.dailyTreatment)
    end)(), "0/nil/nil/nil/0/nil/nil")
    s:remove(3, 1)
    T.eq("R5 remove drops the key and an empty tile", s.count .. "/" .. tostring(s:get(3, 1)), "3/nil")
end)
