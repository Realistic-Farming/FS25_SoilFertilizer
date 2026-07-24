-- weather_source_740_test.lua - #740 weather source / synthetic climate presets.
--   getEffectiveRainScale returns the real in-game rain when weatherSource == 1 (default,
--   unchanged), or a synthetic per-day wet/dry from the chosen preset (2=Arid, 3=Normal,
--   4=Wet). The synthetic value is a seeded per-day roll against the season's rain
--   probability, so it is deterministic (MP-safe), keeps dry-day/wet-day cycling, and its
--   long-run wet-day fraction matches the preset. Guards passthrough, determinism, the
--   per-season probability, the wet-day intensity, and the Arid < Normal < Wet ordering.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local function sysWith(src)
  return setmetatable({ settings = { weatherSource = src } }, { __index = SoilFertilitySystem })
end

local function setEnv(season)
  g_currentMission.environment.currentSeason = season
end

local function setDay(d)
  g_currentMission.environment.currentMonotonicDay = d
end

local function wetFraction(src, season, days)
  local s = sysWith(src)
  setEnv(season)
  local wet = 0
  for d = 1, days do
    setDay(d)
    if s:getEffectiveRainScale() > 0 then wet = wet + 1 end
  end
  return wet / days
end

-- ── weatherSource == 1: real in-game weather passes straight through ──
do
  g_currentMission.environment.weather = { getRainFallScale = function() return 0.42 end }
  local s = sysWith(1)
  T.near("740: weatherSource=1 returns the real rain scale", s:getEffectiveRainScale(), 0.42, 1e-9)

  g_currentMission.environment.weather = nil
  T.eq("740: weatherSource=1 with no weather object -> 0", s:getEffectiveRainScale(), 0)
end

-- ── synthetic value is deterministic per day and per season ──
do
  local s = sysWith(3)   -- Normal
  setEnv(3); setDay(42)
  local a = s:getEffectiveRainScale()
  local b = s:getEffectiveRainScale()
  T.eq("740: same day + season is deterministic", a, b)
  T.ok("740: a day is either dry (0) or a positive intensity", a == 0 or a > 0)
end

-- ── a wet day returns exactly the season's INTENSITY ──
do
  local s = sysWith(4)   -- Wet
  setEnv(1)              -- spring
  local intensity = SoilConstants.CLIMATE_PRECIP[4].INTENSITY[1]
  local foundWet = false
  for d = 1, 60 do
    setDay(d)
    local rs = s:getEffectiveRainScale()
    if rs > 0 then
      T.near("740: a wet day returns the season intensity", rs, intensity, 1e-9)
      foundWet = true
      break
    end
  end
  T.ok("740: Wet spring produces at least one wet day in 60", foundWet)
end

-- ── long-run wet-day fraction tracks the preset probability ──
do
  local season = 2   -- summer
  local expect = SoilConstants.CLIMATE_PRECIP[3].PROB[season]   -- Normal summer
  local frac = wetFraction(3, season, 500)
  T.ok("740: Normal summer wet-day fraction ~ its PROB (" .. expect .. ")",
       math.abs(frac - expect) < 0.1)
end

-- ── drier climates rain on fewer days than wetter ones (same season) ──
do
  local season = 2
  local arid   = wetFraction(2, season, 500)
  local normal = wetFraction(3, season, 500)
  local wet    = wetFraction(4, season, 500)
  T.ok("740: wet-day frequency ordered Arid < Normal < Wet", arid < normal and normal < wet)
end

-- ── an unknown preset index degrades to dry (0), never errors ──
do
  local s = sysWith(9)   -- not a real preset
  setEnv(2); setDay(7)
  T.eq("740: unknown preset -> 0 (safe degrade)", s:getEffectiveRainScale(), 0)
end
