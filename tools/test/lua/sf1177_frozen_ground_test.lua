-- sf1177_frozen_ground_test.lua - #1177: pause nutrient leaching while the ground is frozen.
--   FrozenGround keeps an hourly average of WeatherGuard's temperature. A day whose
--   average is at or below FREEZE_TEMP_C is cold; DAYS_TO_FREEZE cold days in a row
--   freeze the ground, DAYS_TO_THAW warmer days in a row thaw it. A day with no
--   readings counts neither way. While frozen, applyRainEffects returns before any
--   leach or acidification, on both its callers. No WeatherGuard = never frozen.
--   The state saves on the XML root and in the StateLedger table.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/FrozenGround.lua, src/SoilFertilitySystem.lua

SoilLogger.info = function() end
SoilLogger.debug = function() end

local FG = SoilConstants.FROZEN_GROUND
local FREEZE, TO_FREEZE, TO_THAW = FG.FREEZE_TEMP_C, FG.DAYS_TO_FREEZE, FG.DAYS_TO_THAW

-- One full day of hourly readings at `temp` (a number, or a function of the hour).
local hourBase = 0
local function day(fg, temp)
  for h = 0, 23 do
    hourBase = hourBase + 1
    local t = temp
    if type(temp) == "function" then t = temp(h) end
    fg:sample(hourBase, t)
  end
  return fg:onDayChanged()
end

-- =====================================================================
-- GROUP A: the constants the issue proposed.
-- =====================================================================
T.eq("const: a day at or below 0 C counts as cold", FREEZE, 0.0)
T.eq("const: 2 cold days in a row freeze the ground", TO_FREEZE, 2)
T.eq("const: 2 warm days in a row thaw it", TO_THAW, 2)

-- =====================================================================
-- GROUP B: sampling.
-- =====================================================================
do
  local fg = FrozenGround.new()
  T.eq("new: a new tracker is thawed", fg:isFrozen(), false)
  T.eq("new: no cold streak", fg.coldDays, 0)
  T.eq("new: no warm streak", fg.warmDays, 0)

  T.eq("sample: the first reading of an hour counts", fg:sample(1, -4), true)
  T.eq("sample: a second reading in the same hour is ignored", fg:sample(1, 50), false)
  T.eq("sample: a nil reading does not count", fg:sample(2, nil), false)
  T.eq("sample: a NaN reading does not count", fg:sample(3, 0/0), false)
  T.eq("sample: a nil hour key is ignored", fg:sample(nil, -4), false)
  T.near("sample: the day's average is the one valid reading", fg:onDayChanged(), -4, 1e-12)

  local calls = 0
  local reader = function() calls = calls + 1; return 2 end
  for _ = 1, 50 do fg:sample(10, reader) end        -- 50 frames in one hour
  fg:sample(11, reader)
  T.eq("sample: a reader function is called once per hour, not per frame", calls, 2)
end

-- =====================================================================
-- GROUP C: the state machine.
-- =====================================================================
do
  local fg = FrozenGround.new()
  day(fg, -5)
  T.eq("freeze: one cold day does not freeze the ground", fg:isFrozen(), false)
  T.eq("freeze: the cold streak is 1", fg.coldDays, 1)
  day(fg, -5)
  T.eq("freeze: the second cold day in a row freezes it", fg:isFrozen(), true)

  day(fg, 6)
  T.eq("thaw: one warm day does not thaw frozen ground", fg:isFrozen(), true)
  day(fg, -1)
  T.eq("thaw: a cold day breaks the warm streak", fg.warmDays, 0)
  day(fg, 6); day(fg, 6)
  T.eq("thaw: two warm days in a row thaw it", fg:isFrozen(), false)
end

do
  local fg = FrozenGround.new()
  day(fg, -5); day(fg, 4); day(fg, -5)
  T.eq("streak: cold, warm, cold does not freeze (the warm day reset the streak)", fg:isFrozen(), false)
  T.eq("streak: the cold streak restarted at 1", fg.coldDays, 1)
end

do
  local fg = FrozenGround.new()
  day(fg, -5)
  T.eq("no data: a day with no readings returns no average", fg:onDayChanged(), nil)
  T.eq("no data: it does not reset the cold streak", fg.coldDays, 1)
  day(fg, -5)
  T.eq("no data: the next cold day still completes the streak", fg:isFrozen(), true)
end

do
  local fg = FrozenGround.new()
  for _ = 1, 10 do day(fg, nil) end
  T.eq("no data: ten days without a temperature never freeze the ground", fg:isFrozen(), false)
end

do
  -- A frosty night and a mild afternoon: the average, not the low, decides.
  local fg = FrozenGround.new()
  local nightFrost = function(h) if h < 8 then return -5 else return 6 end end
  local avg = day(fg, nightFrost)
  T.ok("average: a frosty night with a mild day averages above zero", avg > 0)
  day(fg, nightFrost)
  T.eq("average: two such days do not freeze the ground", fg:isFrozen(), false)
end

do
  local fg = FrozenGround.new()
  day(fg, 0.0); day(fg, 0.0)
  T.eq("edge: an average of exactly 0 C counts as cold", fg:isFrozen(), true)
end

-- =====================================================================
-- GROUP D: save values.
-- =====================================================================
do
  local fg = FrozenGround.new()
  day(fg, -5); day(fg, -5); day(fg, 3)
  local t = fg:toTable()
  T.eq("table: frozen is saved", t.frozen, true)
  T.eq("table: the warm streak is saved", t.warmDays, 1)
  local back = FrozenGround.new(); back:fromTable(t)
  T.eq("table: frozen round-trips", back:isFrozen(), true)
  T.eq("table: the warm streak round-trips", back.warmDays, 1)
  day(back, 3)
  T.eq("table: a restored streak carries on (thaws on the next warm day)", back:isFrozen(), false)

  local old = FrozenGround.new(); old:fromTable(nil)
  T.eq("table: nothing saved loads thawed", old:isFrozen(), false)
  local bad = FrozenGround.new(); bad:fromTable({ frozen = "yes", coldDays = -3, warmDays = "x" })
  T.eq("table: bad values load thawed", bad:isFrozen(), false)
  T.eq("table: a negative streak loads as 0", bad.coldDays, 0)
  T.eq("table: a non-number streak loads as 0", bad.warmDays, 0)
end

-- =====================================================================
-- GROUP E: the WeatherGuard read.
-- =====================================================================
do
  g_currentMission = nil
  T.eq("read: no mission gives nil", FrozenGround.readTemperature(), nil)
  g_currentMission = {}
  T.eq("read: no WeatherGuard gives nil", FrozenGround.readTemperature(), nil)
  g_currentMission = { weatherGuard = { getCurrentSky = function() return { temperature = -3.5 } end } }
  T.eq("read: the sky's temperature is returned", FrozenGround.readTemperature(), -3.5)
  g_currentMission = { weatherGuard = { getCurrentSky = function() error("boom") end } }
  T.eq("read: a throwing WeatherGuard gives nil", FrozenGround.readTemperature(), nil)
  g_currentMission = { weatherGuard = { getCurrentSky = function() return nil end } }
  T.eq("read: no sky gives nil", FrozenGround.readTemperature(), nil)
  g_currentMission = { weatherGuard = { getCurrentSky = function() return { temperature = 0/0 } end } }
  T.eq("read: a NaN temperature gives nil", FrozenGround.readTemperature(), nil)
  g_currentMission = nil
end

-- =====================================================================
-- GROUP F: the system wiring.
-- =====================================================================
do
  -- The constructor builds a HookManager; the prelude's stub has no methods, so
  -- swap in one that accepts any call for the duration of this check.
  local realHM = HookManager
  HookManager = { new = function()
    return setmetatable({}, { __index = function() return function() return true end end })
  end }
  local ok, sys = pcall(SoilFertilitySystem.new, { enabled = true, rainEffects = true })
  HookManager = realHM
  if not ok then T.ok("system: constructor error: " .. tostring(sys), false) end
  T.ok("system: SoilFertilitySystem.new builds", ok)
  T.ok("system: the new system has a frozen-ground tracker",
       ok and type(sys.frozenGround) == "table" and sys.frozenGround.isFrozen ~= nil)
  T.eq("system: and it starts thawed", ok and sys.frozenGround:isFrozen(), false)
end

local function leachSys(frozen, withTracker)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true, rainEffects = true, weatherSource = 1 }
  s.vmAvailable = function() return false end
  s.activeFieldIds = { [1] = true }
  s.fieldData = { [1] = { nitrogen = 50, potassium = 50, phosphorus = 50, pH = 6.5, organicMatter = 3 } }
  s._rainWasFilled = false
  if withTracker ~= false then
    s.frozenGround = FrozenGround.new()
    if frozen then s.frozenGround:fromTable({ frozen = true }) end
  end
  return s
end

local function snapshot(s)
  local f = s.fieldData[1]
  return string.format("%.12f/%.12f/%.12f/%.12f", f.nitrogen, f.phosphorus, f.potassium, f.pH)
end

do
  g_currentMission = { cropStressManager = { getMoisture = function() return 0.9 end } }
  local frozen, thawed = leachSys(true), leachSys(false)
  frozen:applyRainEffects(1e6, 0.5); thawed:applyRainEffects(1e6, 0.5)
  T.eq("gate: frozen ground loses nothing in rain (N/P/K/pH unchanged)",
       snapshot(frozen), "50.000000000000/50.000000000000/50.000000000000/6.500000000000")
  T.ok("gate: thawed ground does leach in the same rain", thawed.fieldData[1].nitrogen < 50)

  local frozenDry, thawedDry = leachSys(true), leachSys(false)
  frozenDry:applyRainEffects(1e6, 0); thawedDry:applyRainEffects(1e6, 0)
  T.eq("gate: frozen ground loses nothing to the no-rain SCS moisture pass",
       snapshot(frozenDry), "50.000000000000/50.000000000000/50.000000000000/6.500000000000")
  T.ok("gate: thawed ground does leach on that pass (moisture 0.9)", thawedDry.fieldData[1].nitrogen < 50)

  local none = leachSys(false, false)
  none:applyRainEffects(1e6, 0.5)
  T.eq("gate: a thawed tracker leaches exactly as no tracker at all", snapshot(thawed), snapshot(none))
  g_currentMission = nil
end

-- =====================================================================
-- GROUP G: the production entry point, day by day.
-- onEnvironmentUpdate samples the hour, closes the day, and gates the leach.
-- =====================================================================
local function worldSys(tempFn)
  local s = leachSys(false)
  s.lastUpdateDay = 0
  s.lastUpdateMonotonicDay = 0
  s.updateDailySoil = function() end          -- the daily soil pass is not under test
  s._currentMonotonicDay = function() return 0 end
  local env = { currentDay = 1, currentHour = 0,
                weather = { getRainFallScale = function() return 0.5 end } }
  g_currentMission = { environment = env }
  if tempFn ~= nil then
    g_currentMission.weatherGuard = { getCurrentSky = function() return { temperature = tempFn(env) } end }
  end
  return s, env
end

-- Run one in-game day of hourly updates; returns the nitrogen lost that day.
local function runDay(s, env, d)
  local before = s.fieldData[1].nitrogen
  env.currentDay = d
  for h = 0, 23 do
    env.currentHour = h
    s:onEnvironmentUpdate(env, 1e5)
  end
  return before - s.fieldData[1].nitrogen
end

do
  local temps = { [1] = -6, [2] = -6, [3] = -6, [4] = 5, [5] = 5, [6] = 5 }
  local s, env = worldSys(function(e) return temps[e.currentDay] end)
  local loss = {}
  for d = 1, 6 do loss[d] = runDay(s, env, d) end
  T.ok("entry: day 1 (first cold day) still leaches", loss[1] > 0)
  T.ok("entry: day 2 (second cold day) still leaches; the ground freezes when it closes", loss[2] > 0)
  T.eq("entry: day 3 is frozen: no leaching all day", loss[3], 0)
  T.eq("entry: day 4 (first warm day) is still frozen: no leaching", loss[4], 0)
  T.eq("entry: day 5 still frozen until it closes as the second warm day", loss[5], 0)
  T.ok("entry: day 6 after the thaw leaches again", loss[6] > 0)
  T.near("entry: a thawed day leaches the same as before the freeze", loss[6], loss[1], 1e-9)
  T.eq("entry: the ground is thawed at the end", s.frozenGround:isFrozen(), false)
end

do
  -- Frosty nights, mild days, read through the real hourly path: the ground must
  -- see every hour, not just the first one of the day (which is the frost).
  local s, env = worldSys(function(e) if e.currentHour < 8 then return -8 else return 8 end end)
  local loss = {}
  for d = 1, 4 do loss[d] = runDay(s, env, d) end
  T.eq("entry: frosty nights with mild days never freeze the ground", s.frozenGround:isFrozen(), false)
  T.ok("entry: so day 4 still leaches", loss[4] > 0)
end

do
  -- No WeatherGuard: weeks of 'winter' never freeze, and every day leaches the same.
  local s, env = worldSys(nil)
  local first = runDay(s, env, 1)
  local last
  for d = 2, 20 do last = runDay(s, env, d) end
  T.ok("no WeatherGuard: day 1 leaches", first > 0)
  T.near("no WeatherGuard: day 20 leaches exactly like day 1", last, first, 1e-9)
  T.eq("no WeatherGuard: the ground never froze", s.frozenGround:isFrozen(), false)
end

-- =====================================================================
-- GROUP H: saving and loading through the system.
-- =====================================================================
-- The prelude's XML mock has no booleans; the load reads some.
setXMLBool = setXMLBool or function(h, k, v) if h then h[k] = v end end
getXMLBool = getXMLBool or function(h, k) if h then return h[k] end end

-- Save/load with no fields: the root attributes are what #1177 adds, and the
-- per-field rows need tables (herbicideAppliedDay, ...) this fixture does not build.
local function saveSys(frozen)
  local s = leachSys(frozen)
  s.fieldData = {}
  s.activeFieldIds = {}
  return s
end

do
  g_currentMission = { environment = { currentDay = 7 } }
  local s = saveSys(false)
  s.frozenGround:fromTable({ frozen = true, coldDays = 0, warmDays = 1 })

  local xml = {}
  local okSave, errSave = pcall(s.saveToXMLFile, s, xml, "soilData")
  T.ok("xml: saveToXMLFile runs [" .. tostring(errSave) .. "]", okSave)
  T.eq("xml: frozen is written on the root", xml["soilData#groundFrozen"], 1)
  T.eq("xml: the warm streak is written", xml["soilData#groundWarmDays"], 1)
  T.eq("xml: the cold streak is written", xml["soilData#groundColdDays"], 0)

  local r = saveSys(false)
  local okLoad, errLoad = pcall(r.loadFromXMLFile, r, xml, "soilData")
  T.ok("xml: loadFromXMLFile runs [" .. tostring(errLoad) .. "]", okLoad)
  T.eq("xml: frozen loads back", r.frozenGround:isFrozen(), true)
  T.eq("xml: the warm streak loads back", r.frozenGround.warmDays, 1)

  local o = saveSys(true)
  local okOld, errOld = pcall(o.loadFromXMLFile, o, {}, "soilData")
  T.ok("xml: an old save loads [" .. tostring(errOld) .. "]", okOld)
  T.eq("xml: a save from before #1177 loads thawed", o.frozenGround:isFrozen(), false)

  local tbl = s:getSoilStateTable()
  T.eq("ledger: the snapshot carries the frozen state", type(tbl.frozenGround) == "table" and tbl.frozenGround.frozen, true)
  local l = saveSys(false)
  local okL, errL = pcall(l.applySoilStateTable, l, tbl)
  T.ok("ledger: applySoilStateTable runs [" .. tostring(errL) .. "]", okL)
  T.eq("ledger: applying the snapshot restores frozen", l.frozenGround:isFrozen(), true)
  local e = saveSys(true)
  pcall(e.applySoilStateTable, e, nil)
  T.eq("ledger: an empty snapshot resets to thawed", e.frozenGround:isFrozen(), false)
  local older = saveSys(true)
  local okO, errO = pcall(older.applySoilStateTable, older, { lastUpdateDay = 7, fields = {} })
  T.ok("ledger: an old snapshot applies [" .. tostring(errO) .. "]", okO)
  T.eq("ledger: a snapshot from before #1177 loads thawed", older.frozenGround:isFrozen(), false)
  g_currentMission = nil
end
