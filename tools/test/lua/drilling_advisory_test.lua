-- drilling_advisory_test.lua
-- The drilling-window advisory: a hedged line on whether the coming days are a
-- good or risky window for putting seed in this ground. Speaks from the SCS
-- sky-reading and the ground moisture against the establishment kill condition.
-- Advice never gates or writes; silent when SCS is absent (never guessing); the
-- weaker forecast-only form when the moisture read is unavailable.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/DurationScaling.lua, src/SoilFertilitySystem.lua

g_currentMission = { _isServer = true, environment = { currentMonotonicDay = 10 } }
function g_currentMission:getIsServer() return self._isServer end

local function soilSys(cs)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  g_currentMission.cropStressManager = cs
  return s
end

-- 1. SILENT WHEN SCS IS ABSENT (never guessing).
do
  local s = soilSys(nil)
  T.eq('silent.noSCS', s:_drillingAdvisory(1), nil)
end

-- 2. GOOD WHEN THE OUTLOOK IS CLEAR.
do
  local cs = {
    getRainOutlook = function() return { likelihood = 0.2, approximate = true } end,
    getMoisture = function() return 0.3 end,
  }
  local s = soilSys(cs)
  T.eq('good.clearAhead', s:_drillingAdvisory(1), "sf_notify_drill_good")
end

-- 3. RISKY WHEN RAIN IS LIKELY AND THE GROUND IS WET.
do
  local cs = {
    getRainOutlook = function() return { likelihood = 0.7, approximate = true } end,
    getMoisture = function() return 0.7 end,
  }
  local s = soilSys(cs)
  T.eq('risky.wetAndLikely', s:_drillingAdvisory(1), "sf_notify_drill_risky")
end

-- 4. THE WEAKER FORM WHEN RAIN IS LIKELY BUT MOISTURE IS UNREADABLE.
do
  local cs = {
    getRainOutlook = function() return { likelihood = 0.7, approximate = true } end,
    getMoisture = function() return nil end,
  }
  local s = soilSys(cs)
  T.eq('weaker.forecastOnly', s:_drillingAdvisory(1), "sf_notify_drill_forecast_only")
end

-- 5. THE OUTLOOK GETTER FAILING IS ALSO SILENT.
do
  local cs = {
    getRainOutlook = function() error("no sky") end,
    getMoisture = function() return 0.5 end,
  }
  local s = soilSys(cs)
  T.eq('silent.outlookError', s:_drillingAdvisory(1), nil)
end

T.summary()
