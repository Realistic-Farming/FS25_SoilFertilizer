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

g_fruitTypeManager = savedFruitMgr
