-- weather_source_740_test.lua - #740 short-month weather response (the reshaped fill).
--   Real weather is ALWAYS primary. getEffectiveRainScale passes the real sky through on a
--   real rain day and on the opt-out (weatherSource==1). On a DRY real day it fills toward
--   the season climate, but only as the month shortens: w = clamp((15-dpm)/14, 0, 1)^2.5
--   gates the wet-day FREQUENCY (0 at/above 15 days-per-month => byte-identical to real).
--   A filled-wet day returns the FULL climate intensity, sets self._rainWasFilled, and
--   applyRainEffects then applies the per-day precedence: a filled day drops SCS's rain-
--   reflecting moisture amplification but keeps real irrigation (getIrrigationRate); a real
--   day keeps the full model. weatherSource selects the climate bias (2=Arid/3=Normal/4=Wet).
--   Runs the brief's spec-first bench bar (a-f) plus determinism, ordering, season-index,
--   and safe-degrade coverage. RULED numbers: Arissani's balance pass 2026-07-25.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local MIN = SoilConstants.RAIN.MIN_RAIN_THRESHOLD

local function sysWith(src)
  return setmetatable({ settings = { weatherSource = src } }, { __index = SoilFertilitySystem })
end

-- Set season + month length, and default to a DRY sky so the fill path is exercised.
local function setEnv(season, dpm)
  local env = g_currentMission.environment
  env.currentSeason  = season
  env.daysPerPeriod  = dpm or 1
  env.weather        = nil   -- dry real day (real = 0) unless a test sets real rain
end

local function setDay(d)
  g_currentMission.environment.currentMonotonicDay = d
end

local function setRealRain(scale)
  g_currentMission.environment.weather = { getRainFallScale = function() return scale end }
end

local function wetFraction(src, season, dpm, days)
  local s = sysWith(src)
  setEnv(season, dpm)
  local wet = 0
  for d = 1, days do
    setDay(d)
    if s:getEffectiveRainScale() > MIN then wet = wet + 1 end
  end
  return wet / days
end

-- ── opt-out (weatherSource==1): pure real weather, no fill, at any month length ──
do
  local s = sysWith(1)
  setEnv(2, 1)                 -- 1-day month (fill would fully engage if it were on)
  setRealRain(0.42)
  T.near("740a: opt-out returns the real rain scale", s:getEffectiveRainScale(), 0.42, 1e-9)
  T.ok("740a: opt-out on a real rain day is not a fill", s._rainWasFilled == false)

  setEnv(2, 1)                 -- dry real day, shortest month
  T.eq("740a: opt-out on a dry day -> 0 (no fill)", s:getEffectiveRainScale(), 0)
  T.ok("740a: opt-out never flags a filled day", s._rainWasFilled == false)
end

-- ── (a) a real rain day short-circuits the fill (real is primary, never overridden) ──
do
  local s = sysWith(3)         -- Normal climate bias
  setEnv(2, 1)                 -- shortest month: fill fully engaged if it were a dry day
  setRealRain(0.5)             -- but it is a real rain day (0.5 > MIN)
  T.near("740a: a real rain day returns the real scale, not the fill", s:getEffectiveRainScale(), 0.5, 1e-9)
  T.ok("740a: a real rain day is not flagged as filled", s._rainWasFilled == false)
end

-- ── (b) w = 0 at/above the sampling reference (byte-identical), monotone as month shortens ──
do
  local s = sysWith(3)
  T.near("740b: _fillWeight is 0 at the sampling reference (15d)", s:_fillWeight(15), 0, 1e-9)
  T.near("740b: _fillWeight is 0 above the reference (30d)", s:_fillWeight(30), 0, 1e-9)
  T.near("740b: _fillWeight is 1 at a 1-day month", s:_fillWeight(1), 1, 1e-9)

  local prev = 1e9
  local mono = true
  for _, dpm in ipairs({ 1, 2, 4, 7, 10, 12, 15 }) do
    local w = s:_fillWeight(dpm)
    if w > prev + 1e-12 then mono = false end
    if w < 0 or w > 1 then mono = false end
    prev = w
  end
  T.ok("740b: _fillWeight is monotone non-increasing in dpm and stays in [0,1]", mono)

  -- Byte-identical above the reference: every dry day returns exactly 0 (== real), no fill.
  setEnv(2, 15)
  local allZero = true
  for d = 1, 120 do setDay(d); if s:getEffectiveRainScale() ~= 0 then allZero = false end end
  T.ok("740b: at 15+ dpm a dry month is byte-identical to real weather (all 0)", allZero)
end

-- ── (c) a filled-wet day returns the FULL climate intensity, regardless of w ──
do
  local s = sysWith(4)         -- Wet: INTENSITY 0.80
  local intensity = SoilConstants.CLIMATE_PRECIP[4].INTENSITY
  setEnv(1, 7)                 -- 7-day month => small w (~0.25), so wet days are sparse
  local foundWet, allFull = false, true
  for d = 1, 300 do
    setDay(d)
    local rs = s:getEffectiveRainScale()
    if rs > 0 then
      foundWet = true
      if math.abs(rs - intensity) > 1e-9 then allFull = false end
      if rs < MIN then allFull = false end
      T.ok("740c: filled day flags _rainWasFilled", s._rainWasFilled == true)
      break
    end
  end
  T.ok("740c: a short Wet month still produces a filled-wet day", foundWet)
  T.ok("740c: a filled-wet day is the full intensity and >= MIN, regardless of w", allFull)
end

-- ── (d) total wet-day fraction tracks the season climate; no over-fill on long months ──
do
  -- Short month (w=1), no real rain: filled fraction should approach the season PROB.
  local expect = SoilConstants.CLIMATE_PRECIP[3].PROB[2]   -- Normal summer = 0.20
  local frac = wetFraction(3, 2, 1, 800)
  T.ok("740d: 1-day Normal summer wet-day fraction ~ its PROB (" .. expect .. ")",
       math.abs(frac - expect) < 0.06)
  -- No over-fill: at the reference month length the fill adds nothing over pure real (0).
  local longFrac = wetFraction(3, 2, 15, 400)
  T.eq("740d: at 15 dpm the fill adds no wet days (no over-fill)", longFrac, 0)
end

-- ── (e) per-day precedence: filled day drops moisture amp, keeps irrigation; real keeps both ──
do
  -- Leach one field once; return the remaining nitrogen (lower = more leaching).
  local function leachedN(filled, moisture, irrigRate)
    local s = setmetatable({}, { __index = SoilFertilitySystem })
    s.settings       = { enabled = true, rainEffects = true, weatherSource = 3 }
    s.vmAvailable    = function() return false end
    s.activeFieldIds = { [1] = true }
    s.fieldData      = { [1] = { nitrogen = 50, potassium = 50, phosphorus = 50, pH = 6.5, organicMatter = 3 } }
    s._rainWasFilled = filled
    g_currentMission.cropStressManager = {
      getMoisture       = function(_self, _fid) return moisture end,
      getIrrigationRate = function(_self, _fid) return irrigRate end,
    }
    g_currentMission.randomWorldEvents = nil
    -- rainScale 0.3 (> MIN) is below the full-irrigation drive, so the irrigation term is
    -- visible on the filled-irrigation case while the ordering stays valid.
    s:applyRainEffects(1e6, 0.3)
    g_currentMission.cropStressManager = nil
    return s.fieldData[1].nitrogen
  end

  local nReal          = leachedN(false, 0.9, 0.0)     -- real day: moisture amplifies leach
  local nFilledDry     = leachedN(true,  0.9, 0.0)     -- filled day: moisture IGNORED, no irrig
  local nFilledIrrig   = leachedN(true,  0.9, 0.018)   -- filled day: real irrigation still leaches
  local nFilledMoist01 = leachedN(true,  0.1, 0.0)     -- filled day: different moisture, same result

  T.ok("740e: leaching happens on both a real and a filled day", nReal < 50 and nFilledDry < 50)
  T.ok("740e: a filled day drops the moisture amplification (leaches less than a real day)", nFilledDry > nReal)
  T.ok("740e: a filled day still leaches from real irrigation (getIrrigationRate honored)", nFilledIrrig < nFilledDry)
  T.near("740e: a filled day ignores the SCS moisture level entirely", nFilledDry, nFilledMoist01, 1e-9)
end

-- ── (f) establishment parity: short-month wet frequency is restored to the season climate ──
-- The disease model cycles on wet/dry days. On a 1-day month real weather barely rains, so
-- without the fill dryDayCount never resets and disease never establishes. The fill restores
-- the wet-day FREQUENCY to the season climate, the same frequency an adequately-sampled month
-- would see - so establishment is reachable across month lengths, not only on long calendars.
do
  local target = SoilConstants.CLIMATE_PRECIP[3].PROB[1]   -- Normal spring = 0.40
  local short  = wetFraction(3, 1, 1, 800)                 -- 1-day month, fill engaged
  T.ok("740f: a 1-day month's wet frequency is restored toward the climate (" .. target .. ")",
       math.abs(short - target) < 0.06)
  T.ok("740f: the fill actually restores wet days a bare short month would lack", short > 0.2)
end

-- ── determinism: same day + season is stable (MP-safe, save/reload-safe) ──
do
  local s = sysWith(3)
  setEnv(3, 1); setDay(42)
  local a = s:getEffectiveRainScale()
  local b = s:getEffectiveRainScale()
  T.eq("740: same day + season is deterministic", a, b)
  T.ok("740: a day is either dry (0) or a positive intensity", a == 0 or a > 0)
end

-- ── season index maps with NO offset: summer uses summer's PROB, spring uses spring's ──
do
  local spring = wetFraction(3, 1, 1, 800)   -- Normal spring PROB 0.40
  local summer = wetFraction(3, 2, 1, 800)   -- Normal summer PROB 0.20
  T.ok("740: season 1 lands on spring's rain-day fraction (~0.40)", math.abs(spring - 0.40) < 0.06)
  T.ok("740: season 2 lands on summer's rain-day fraction (~0.20), no index offset", math.abs(summer - 0.20) < 0.06)
end

-- ── drier climates rain on fewer days than wetter ones (same season, same month) ──
do
  local arid   = wetFraction(2, 2, 1, 800)
  local normal = wetFraction(3, 2, 1, 800)
  local wet    = wetFraction(4, 2, 1, 800)
  T.ok("740: wet-day frequency ordered Arid < Normal < Wet", arid < normal and normal < wet)
end

-- ── safe degrade: an unknown climate bias never errors ──
do
  local s = sysWith(9)   -- not a real climate
  setEnv(2, 1); setDay(7)
  T.eq("740: unknown climate bias -> 0 (safe degrade)", s:getEffectiveRainScale(), 0)
  T.ok("740: unknown climate bias never flags a filled day", s._rainWasFilled == false)
end
