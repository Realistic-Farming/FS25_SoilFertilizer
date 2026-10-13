-- RSF-F213-wetness_cursor_hold_test.lua - F213 part 1: a HELD wetness day keeps the cursor.
--
-- MaterialWetness:settleOneDay holds a day it cannot settle (no live sky and no climate,
-- because WeatherGuard is absent) and returns early. onConditionAccrual then set
-- appliedThroughDay = day regardless, so the held day was recorded as settled and never
-- replayed, and the ground-condition settlement barrier, which reads exactly that cursor
-- to know whether pre-operation ground is settled, passed over it. The F208 bench only
-- ever met a STUB wetness owner that retained its cursor on a hold; the real owner did not.
-- The ground-condition contract, section 2: never advance a domain cursor past an
-- unsettled day.
--
-- ENTRY POINTS: the real MaterialWetness armed by its real arm(), its cursor restored by
-- its real deserialize (the load path), and driven by BOTH production callers: the Time
-- Guard accrual that SoilMaterialDownBridge.registerConditionAccrual registers, and the
-- real GroundConditionCoordinator:runSettlementBarrier. The fixture supplies the world
-- only: a Time Guard that records the registration, a WeatherGuard that is present or
-- absent, value maps and an age owner with no active fields (the dry and wet passes are
-- then no-ops; the cursor is what is under test), and the environment.
--
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialWetness.lua, src/ground/GroundConditionCoordinator.lua, src/integrations/SoilMaterialDownBridge.lua

SoilLogger.info = function() end; SoilLogger.debug = function() end; SoilLogger.warning = function() end
g_server = {}

local WG
local function weather(opts)
  if opts == nil then return nil end
  return {
    getCurrentSky    = function() return opts.sky end,
    getEffectiveRain = function() return opts.rain or { rainScale = 0 } end,
    getClimate       = function(_, season) if opts.climate then return { meanTemp = 12, rainDayFraction = 0.2 } end return nil end,
  }
end
local registered
local function newWorld(today, wg)
  registered = {}
  g_currentMission = {
    environment = { currentSeason = 2, currentMonotonicDay = today, daysPerPeriod = 3 },
    weatherGuard = wg,
    timeGuard = { registerAccrual = function(_, id, spec) registered[id] = spec; return true end,
                  unregisterAccrual = function() end },
  }
end
local function armedWetness(cursor)
  local mw = MaterialWetness.new()
  local vm = { available = true, applyRawDeltaToPolygonBand = function() return 0 end,
               getLayerEntry = function() return {} end }
  local down = { isArmed = function() return true end, enumerateActiveFields = function() end,
                 ageAppliedThroughDay = nil, onAgeTick = function(self, ctx) self.ageAppliedThroughDay = ctx.monotonicDay end }
  T.ok("world: the real arm() arms the owner", mw:arm(vm, down, {}) == true)
  mw:deserialize({ appliedThroughDay = cursor })   -- the cursor a save carried
  return mw, down
end
local function settle(day, span)
  registered[SoilMaterialDownBridge.ACCRUAL_CONDITION].onSettle({ monotonicDay = day, boundariesCrossed = span })
end

-- =====================================================================
-- T. THE TIME GUARD PATH
-- =====================================================================
do
  newWorld(101, nil)                                   -- WeatherGuard absent
  local mw = armedWetness(100)
  T.eq("T0 the bridge registers the condition accrual", SoilMaterialDownBridge.registerConditionAccrual(mw), true)
  settle(101, 1)
  T.eq("T1 a HELD day leaves the cursor where it was (100), not 101", mw.appliedThroughDay, 100)
  T.eq("T2 and records no verdict for the held day", mw.waterRecord[101], nil)

  -- WeatherGuard arrives; Time Guard's next callback spans only its own one day
  g_currentMission.weatherGuard = weather({ sky = { humidity = 0.6, temperature = 15, cloudCoverage = 0.3 }, climate = true })
  g_currentMission.environment.currentMonotonicDay = 102
  settle(102, 1)
  T.eq("T3 the next accrual REPLAYS the held day from the cursor: 101 now settled", mw.waterRecord[101] ~= nil, true)
  T.eq("T4 as climate-derived (it was not today)", mw.waterRecord[101] and mw.waterRecord[101].derived, true)
  T.eq("T5 and today settles on the live sky", mw.waterRecord[102] and mw.waterRecord[102].derived, false)
  T.eq("T6 the cursor reaches today", mw.appliedThroughDay, 102)
end
do
  -- a hold in the MIDDLE of a catch-up: live sky today, no climate for the skipped days
  newWorld(105, weather({ sky = { humidity = 0.6, temperature = 15, cloudCoverage = 0.3 }, climate = false }))
  local mw = armedWetness(102)
  SoilMaterialDownBridge.registerConditionAccrual(mw)
  settle(105, 3)
  T.eq("T7 the first skipped day holds, so the cursor stays at 102", mw.appliedThroughDay, 102)
  T.eq("T8 the days after it are NOT walked out of order (104)", mw.waterRecord[104], nil)
  T.eq("T9 not even today, whose sky was live (105)", mw.waterRecord[105], nil)
end
do
  -- nothing held: the ordinary multi-day catch-up is unchanged
  newWorld(105, weather({ sky = { humidity = 0.6, temperature = 15, cloudCoverage = 0.3 }, climate = true }))
  local mw = armedWetness(102)
  SoilMaterialDownBridge.registerConditionAccrual(mw)
  settle(105, 3)
  T.eq("T10 an ordinary catch-up still reaches today", mw.appliedThroughDay, 105)
  T.ok("T11 and settles every day in between", mw.waterRecord[103] ~= nil and mw.waterRecord[104] ~= nil and mw.waterRecord[105] ~= nil)
  settle(105, 1)
  T.eq("T12 a repeat for a settled day changes nothing", mw.appliedThroughDay, 105)
end

-- =====================================================================
-- B. THE SETTLEMENT BARRIER PATH (GroundConditionCoordinator, contract section 2)
-- =====================================================================
do
  newWorld(101, nil)
  local mw, down = armedWetness(100)
  down.ageAppliedThroughDay = 101                      -- age already settled today
  local coord = GroundConditionCoordinator.new()
  local cells = { isArmed = function() return true end }
  T.ok("B0 the real coordinator arms over the real wetness owner",
    coord:arm(cells, down, mw, { _currentMonotonicDay = function() return g_currentMission.environment.currentMonotonicDay end }) == true)
  local ok, reason = coord:runSettlementBarrier()
  T.eq("B1 a held wetness day REFUSES the barrier (pre-operation ground is not settled)", ok, false)
  T.eq("B2 with SETTLE_INCOMPLETE", reason, GroundConditionCoordinator.BARRIER_SETTLE_FAILED)
  T.eq("B3 and the owner's cursor stayed at 100", mw.appliedThroughDay, 100)
  g_currentMission.weatherGuard = weather({ sky = { humidity = 0.6, temperature = 15, cloudCoverage = 0.3 }, climate = true })
  coord:invalidateBarrier()
  local ok2, reason2 = coord:runSettlementBarrier()
  T.eq("B4 once the weather is readable the barrier settles and passes", ok2, true)
  T.eq("B5 reason OK", reason2, GroundConditionCoordinator.BARRIER_OK)
  T.eq("B6 the cursor is today", mw.appliedThroughDay, 101)
end
