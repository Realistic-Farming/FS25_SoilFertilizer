-- organic_transition_timeguard_test.lua
-- The organic transition is a multi-YEAR commitment, resolved through Time Guard's
-- days-per-period so "N years" means N in-game years on any save. A raw day count
-- turned three years into anything from months to decades depending on the
-- days-per-month setting.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/OrganicCertification.lua

-- Engine mock: a manager whose difficulty setting we can drive.
g_SoilFertilityManager = { settings = { difficulty = 2 } }
g_currentMission = { environment = { currentMonotonicDay = 10 } }

local function org()
  return setmetatable({}, { __index = OrganicCertification })
end

local function setDpm(dpm)
  if dpm == nil then
    g_currentMission.timeGuard = nil
    g_timeGuard = nil
  else
    g_currentMission.timeGuard = { getContext = function() return { daysPerPeriod = dpm } end }
    g_timeGuard = nil
  end
end

-- 1. A YEAR IS A YEAR: the threshold is YEARS * 12 * days-per-month.
setDpm(30)
local o = org()
T.eq("standard (3y) at a 30-day month = 1080 days", o:getTransitionDays(), 1080)

setDpm(15)
T.eq("standard (3y) at a 15-day month = 540 days", o:getTransitionDays(), 540)

setDpm(1)
T.eq("standard (3y) at a 1-day month = 36 days", o:getTransitionDays(), 36)

-- 2. DIFFICULTY INDEXING: easy < standard < hard, each still a year-scaled term.
g_SoilFertilityManager.settings.difficulty = 1
setDpm(30)
T.eq("easy (2y) at 30-day month = 720 days", o:getTransitionDays(), 720)

g_SoilFertilityManager.settings.difficulty = 3
T.eq("hard (5y) at 30-day month = 1800 days", o:getTransitionDays(), 1800)

-- 3. TIME GUARD ABSENT: degrades to the reference 30-day month, never a crash.
g_SoilFertilityManager.settings.difficulty = 2
setDpm(nil)
T.eq("no Time Guard -> 30-day reference (1080)", o:getTransitionDays(), 1080)

-- 4. THE THRESHOLD TRACKS A MID-SAVE CHANGE (re-normalises from the next period).
setDpm(30)
T.eq("first read at 30-day month", o:getTransitionDays(), 1080)
setDpm(7)
T.eq("same save, now a 7-day month -> 252 days", o:getTransitionDays(), 252)

-- 5. THE STATE MACHINE IS UNCHANGED: getFieldOrganicState still reports the
-- normalized threshold as transitionDaysNeeded.
do
  g_SoilFertilityManager.settings.difficulty = 2
  setDpm(30)
  local cert = setmetatable({}, { __index = OrganicCertification })
  cert.soilSystem = {
    fieldData = { [1] = { organic = { state = SoilConstants.ORGANIC.STATE_TRANSITION, startDay = 0 } } },
  }
  cert.getTransitionDays = OrganicCertification.getTransitionDays
  cert.getCurrentDay = function() return 500 end
  cert.getDifficulty = function() return 2 end
  cert.getTransitionDays = function(self)
    return OrganicCertification.getTransitionDays(self)
  end
  cert.ensureState = function() end
  local st = cert:getFieldOrganicState(1)
  T.eq("transitionDaysNeeded is the normalized threshold", st.transitionDaysNeeded, 1080)
  T.eq("daysAccrued still tracks the monotonic day", st.daysAccrued, 500)
  T.eq("state is still in_transition", st.state, SoilConstants.ORGANIC.STATE_TRANSITION)
end

T.summary()
