-- weed_withered_1030_test.lua - #1030
--
-- The daily weed read must treat herbicide-withered weed states as 0. Vanilla
-- maps_weed.xml gives withered states 8/9 a factor of 0.5/0.75 and they persist until
-- tillage/harvest, so reading weedFactor raw turned a sprayed field's dead weeds into
-- 50-75% weed pressure that climbed back +20/day after every herbicide pass.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local function newSys()
  return setmetatable({ fieldData = {} }, { __index = SoilFertilitySystem })
end

FruitType = FruitType or { UNKNOWN = 0 }
local savedFruitMgr = g_fruitTypeManager
g_fruitTypeManager = { getFruitTypeByIndex = function() return { name = "WHEAT" } end }

-- Fake FieldState: every sample point returns the same weed state + factor.
local function fakeFieldState(state, factor)
  return { update = function(self) self.isValid = true; self.fruitTypeIndex = 3
                                  self.weedState = state; self.weedFactor = factor end }
end

local function sample(state, factor)
  local sys = newSys()
  sys._fieldStateCache = { [1] = fakeFieldState(state, factor) }
  return sys:_sampleFieldWeedFactor({ posX = 0, posZ = 0 }, 1)
end

-- No weedSystem in the harness -> fallback WITHERED_STATES {7,8,9}.
T.near("should read 0 when weeds are withered state 8 (vanilla factor 0.5)", sample(8, 0.5), 0)
T.near("should read 0 when weeds are withered state 9 (vanilla factor 0.75)", sample(9, 0.75), 0)
T.near("should keep the factor when weeds are live state 5", sample(5, 1.0), 1.0)
T.near("should keep the factor when weeds are live state 3", sample(3, 0.5), 0.5)
T.near("should keep the factor when weeds are weeder-damaged state 6", sample(6, 0.5), 0.5)

-- The map's own herbicide replacement table (source -> target) wins over the fallback.
do
  g_currentMission.weedSystem = { getHerbicideReplacements = function()
    return { weed = { replacements = { [1] = 0, [3] = 7, [4] = 8 } } } end }
  local set = newSys():_getWitheredWeedStates()
  T.ok("should take withered states 7 and 8 from the map table", set[7] and set[8])
  T.ok("should exclude 0 (preventative clear) from withered states", not set[0])
  T.ok("should not add 9 when the map does not target it", not set[9])
  g_currentMission.weedSystem = nil
end

-- A custom map whose table targets a state that is itself a source (a living state other
-- states turn into) must not have that state counted as withered.
do
  g_currentMission.weedSystem = { getHerbicideReplacements = function()
    return { weed = { replacements = { [3] = 4, [4] = 8 } } } end }
  local set = newSys():_getWitheredWeedStates()
  T.ok("should not count a target that is also a source as withered", not set[4])
  T.ok("should still count a pure target as withered", set[8])
  g_currentMission.weedSystem = nil
end

-- ── Through the daily pass itself (_processOneDailyField) ─────────────────────
-- Drives the real daily update, not the sampler, so skipping or reverting the withered
-- handling anywhere on that path fails here. Uses vanilla maps_weed.xml's full herbicide
-- table: 1->0, 2->0 (preventative), 3->7, 4->8, 5->9, 6->7.
local VANILLA_HERBICIDE = { [1] = 0, [2] = 0, [3] = 7, [4] = 8, [5] = 9, [6] = 7 }

local savedFieldMgr = g_fieldManager

local function dailySys(weedState, weedFactor, field)
  g_currentMission.weedSystem = { getHerbicideReplacements = function()
    return { weed = { replacements = VANILLA_HERBICIDE } } end }
  g_fieldManager = { fields = { [1] = { posX = 0, posZ = 0, farmland = { id = 1 } } } }
  local sys = setmetatable({
    fieldData           = { [1] = field },
    settings            = { enabled = true, weedPressure = true },
    herbicideAppliedDay = {},
    _dailyBatchDay      = 100,
    _dailyBatchSeason   = 1,
    _fieldStateCache    = { [1] = fakeFieldState(weedState, weedFactor) },
  }, { __index = SoilFertilitySystem })
  return sys
end

local function newField(weedPressure, herbicideDaysLeft)
  return { nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.5,
           lastHarvest = 99, lastCrop = "wheat", weedPressure = weedPressure,
           herbicideDaysLeft = herbicideDaysLeft }
end

do  -- state 9 (vanilla factor 0.75): stays 0 while protection runs out and after it has expired
  local field = newField(0, 2)
  local sys = dailySys(9, 0.75, field)
  local readings = {}
  for day = 1, 4 do
    sys._dailyBatchDay = 100 + day
    sys:_processOneDailyField(1, field)
    readings[day] = field.weedPressure
  end
  T.eq("daily pass: protection has run out by day 2", field.herbicideDaysLeft, 0)
  T.eq("daily pass: withered state 9 reads 0 on day 1 (protected)", readings[1], 0)
  T.eq("daily pass: withered state 9 reads 0 on day 2 (protection expires)", readings[2], 0)
  T.eq("daily pass: withered state 9 reads 0 on day 3 (protection expired)", readings[3], 0)
  T.eq("daily pass: withered state 9 still 0 on day 4", readings[4], 0)
end

do  -- live state 5 control (factor 1.0): climbs +20/day (MAX_DAILY_INCREASE)
  local field = newField(0, 0)
  local sys = dailySys(5, 1.0, field)
  local readings = {}
  for day = 1, 3 do
    sys._dailyBatchDay = 100 + day
    sys:_processOneDailyField(1, field)
    readings[day] = field.weedPressure
  end
  T.eq("daily pass: live state 5 reads 20 after day 1", readings[1], 20)
  T.eq("daily pass: live state 5 reads 40 after day 2", readings[2], 40)
  T.eq("daily pass: live state 5 reads 60 after day 3", readings[3], 60)
end

do  -- the same daily pass derives exactly {7, 8, 9} from the full vanilla table
  local sys = dailySys(9, 0.75, newField(0, 0))
  local set = sys:_getWitheredWeedStates()
  T.ok("vanilla table: 7, 8, 9 are withered", set[7] and set[8] and set[9])
  T.ok("vanilla table: 0 (preventative clear) is not withered", not set[0])
  T.ok("vanilla table: live and weeder-damaged states 1-6 are not withered",
       not (set[1] or set[2] or set[3] or set[4] or set[5] or set[6]))
end

g_currentMission.weedSystem = nil
g_fieldManager = savedFieldMgr
g_fruitTypeManager = savedFruitMgr
