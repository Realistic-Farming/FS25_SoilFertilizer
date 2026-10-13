-- MAINTENANCE row 302: the RfPdaSoilMerge field-extent hook must hand back the task
-- FieldManager.cultivateField and FieldManager.plowField return.
--
-- The engine's NPC field update reads that task: FieldManager:updateField does
-- `local task = self:cultivateField(field)` and then `task:setSprayType(...)`
-- (decompile field/FieldManager.lua:412-414 and :418-420). Soil wrapped both methods
-- with Utils.appendedFunction, which returns nothing, so at the end of a sleep the
-- game logged "attempt to index nil with 'setSprayType'" (Tyson's log.txt,
-- 2026-10-13 22:25:21, runtime FieldManager.lua:553 and :557).
--
-- The hook is installed through the production entry point, RfPdaSoilMerge.buildGroups
-- (the list build that calls ensureSubscribed). The engine side is modelled here:
-- Utils.appendedFunction and Utils.overwrittenFunction are the engine's own bodies
-- (utils/Utils.lua:380-401), and updateField's opening branches are transcribed from
-- the decompile, including its two-argument setSprayType on the manure branch. This
-- bar does not run the engine's FieldUpdateTask or touch a density map.
--!load: src/ui/RfPdaSoilMerge.lua

-- =====================================================================
-- Engine stand-ins
-- =====================================================================

Utils = Utils or {}
function Utils.appendedFunction(oldFunc, newFunc)
  return oldFunc ~= nil and function(...)
    oldFunc(...)
    newFunc(...)
  end or newFunc
end
function Utils.overwrittenFunction(oldFunc, newFunc)
  return oldFunc == nil and function(self, ...)
    return newFunc(self, nil, ...)
  end or function(self, ...)
    return newFunc(self, oldFunc, ...)
  end
end

FruitType = FruitType or { UNKNOWN = 0 }
FieldGroundType = FieldGroundType or { NONE = 0, PLOWED = 1, CULTIVATED = 2 }
FieldSprayType = FieldSprayType or { NONE = 0, FERTILIZER = 1, LIME = 2, MANURE = 3, LIQUID_MANURE = 4 }

local trace = {}

local Task = {}
Task.__index = Task
local function newTask()
  return setmetatable({}, Task)
end
function Task:setField(field) self.field = field end
function Task:setFruit(index, state) self.fruitTypeIndex = index; self.fruitState = state end
function Task:setWeedState(state) self.weedState = state end
function Task:setStoneLevel(level) self.stoneLevel = level end
function Task:setGroundAngle(angle) self.groundAngle = angle end
function Task:setGroundType(groundType) self.groundType = groundType end
function Task:setSprayType(sprayType) self.sprayType = sprayType end
function Task:setSprayLevel(level) self.sprayLevel = level end
function Task:setLimeLevel(level) self.limeLevel = level end
function Task:setPlowLevel(level) self.plowLevel = level end
function Task:clearHeight() self.heightCleared = true end

FieldManager = {}
FieldManager.__index = FieldManager

local function newFieldManager()
  return setmetatable({ tasks = {}, limeLevelMaxValue = 3, plowLevelMaxValue = 1 }, FieldManager)
end

function FieldManager:addFieldUpdateTask(task)
  self.tasks[#self.tasks + 1] = task
end
function FieldManager:logNPCAction() end

-- decompile :503-517
function FieldManager:plowField(field)
  local task = newTask()
  task:setField(field)
  task:setFruit(FruitType.UNKNOWN, 0)
  task:setWeedState(0)
  task:setStoneLevel(0)
  task:setGroundAngle(field:getAngle())
  task:setGroundType(FieldGroundType.PLOWED)
  task:setSprayType(FieldGroundType.NONE)
  task:setPlowLevel(self.plowLevelMaxValue)
  task:clearHeight()
  trace[#trace + 1] = "engine:plowField"
  self:addFieldUpdateTask(task)
  return task
end

-- decompile :518-531
function FieldManager:cultivateField(field)
  local task = newTask()
  task:setField(field)
  task:setFruit(FruitType.UNKNOWN, 0)
  task:setWeedState(0)
  task:setStoneLevel(0)
  task:setGroundAngle(field:getAngle())
  task:setGroundType(FieldGroundType.CULTIVATED)
  task:setSprayType(FieldGroundType.NONE)
  task:clearHeight()
  trace[#trace + 1] = "engine:cultivateField"
  self:addFieldUpdateTask(task)
  return task
end

-- decompile :585-598
function FieldManager:limeField(field)
  local task = newTask()
  task:setField(field)
  task:setFruit(FruitType.UNKNOWN, 0)
  task:setWeedState(0)
  task:setStoneLevel(0)
  task:setGroundAngle(field:getAngle())
  task:setGroundType(FieldGroundType.CULTIVATED)
  task:setLimeLevel(self.limeLevelMaxValue)
  task:setSprayType(FieldSprayType.LIME)
  task:clearHeight()
  self:addFieldUpdateTask(task)
  return task
end

function FieldManager:generatePlannedFruitForField()
  return 7
end

-- decompile :402-421, the branches that read the task cultivateField returns.
function FieldManager:updateField(field)
  if not field:getHasOwner() and field.isMissionAllowed then
    local fieldState = field:getFieldState()
    if fieldState.fruitTypeIndex == FruitType.UNKNOWN then
      if field.plannedFruitTypeIndex == FruitType.UNKNOWN then
        field.plannedFruitTypeIndex = self:generatePlannedFruitForField(field)
        if fieldState.limeLevel == 0 and math.random() < 0.2 then
          self:limeField(field)
          local task = self:cultivateField(field)
          task:setSprayType(FieldSprayType.LIME)
          task:setLimeLevel(self.limeLevelMaxValue)
          return
        end
        if math.random() < 0.2 then
          local task = self:cultivateField(field)
          task:setSprayType(math.random() > 0.7 and FieldSprayType.LIQUID_MANURE, FieldSprayType.MANURE)
          task:setSprayLevel(1)
          return
        end
      end
    end
  end
end

local function newField(farmlandId, limeLevel)
  return {
    farmland = farmlandId ~= nil and { id = farmlandId } or nil,
    isMissionAllowed = true,
    plannedFruitTypeIndex = FruitType.UNKNOWN,
    getHasOwner = function() return false end,
    getAngle = function() return 0 end,
    getFieldState = function() return { fruitTypeIndex = FruitType.UNKNOWN, limeLevel = limeLevel or 1 } end,
  }
end

-- Scripted math.random: the branch choice is a fixture, not a roll.
local function withRandom(values, fn)
  local real = math.random
  local i = 0
  math.random = function()
    i = i + 1
    return values[i] or 0.99
  end
  local ok, err = pcall(fn)
  math.random = real
  return ok, err
end

-- markDirty spy: the hook looks RfPdaSoilMerge.markDirty up at call time.
local dirty = {}
RfPdaSoilMerge.markDirty = function(id)
  dirty[#dirty + 1] = id
  trace[#trace + 1] = "soil:markDirty:" .. tostring(id)
end
local function reset()
  dirty = {}
  trace = {}
end

-- =====================================================================
-- GROUP A: the hook installs through the list build, once
-- =====================================================================

local engineCultivate, enginePlow = FieldManager.cultivateField, FieldManager.plowField
local okBuild, errBuild = pcall(RfPdaSoilMerge.buildGroups, {})
T.ok("302 A1: buildGroups({}) runs with no soil system loaded", okBuild, tostring(errBuild))
T.ok("302 A2: buildGroups wrapped cultivateField", FieldManager.cultivateField ~= engineCultivate)
T.ok("302 A3: buildGroups wrapped plowField", FieldManager.plowField ~= enginePlow)
T.eq("302 A4: the subscriptions are recorded as installed", RfPdaSoilMerge._subscribed, true)

local wrappedCultivate = FieldManager.cultivateField
pcall(RfPdaSoilMerge.buildGroups, {})
T.ok("302 A5: a second list build does not wrap again", FieldManager.cultivateField == wrappedCultivate)

-- =====================================================================
-- GROUP B: the engine's task comes back through the hook
-- =====================================================================

reset()
local fm = newFieldManager()
local field = newField(42)
local got = fm:cultivateField(field)
T.ok("302 B1: cultivateField returns a task through the hook", got ~= nil)
T.ok("302 B2: it is the engine's own task, the one queued", got ~= nil and rawequal(got, fm.tasks[#fm.tasks]))

reset()
fm = newFieldManager()
got = fm:plowField(field)
T.ok("302 B3: plowField returns a task through the hook", got ~= nil)
T.ok("302 B4: it is the engine's own task, the one queued", got ~= nil and rawequal(got, fm.tasks[#fm.tasks]))
T.eq("302 B5: the engine queued exactly one plow task", #fm.tasks, 1)

-- =====================================================================
-- GROUP C: the hook still marks the worked farmland dirty, after the engine
-- =====================================================================

reset()
fm = newFieldManager()
fm:cultivateField(newField(42))
T.eq("302 C1: cultivate marks its farmland dirty once", #dirty, 1)
T.eq("302 C2: with the worked farmland's id", dirty[1], 42)
T.eq("302 C3: the engine runs first, then Soil marks",
  table.concat(trace, ","), "engine:cultivateField,soil:markDirty:42")

reset()
fm = newFieldManager()
fm:plowField(newField(9))
T.eq("302 C4: plow marks its farmland dirty, after the engine",
  table.concat(trace, ","), "engine:plowField,soil:markDirty:9")

reset()
fm = newFieldManager()
got = fm:cultivateField(newField(nil))
T.eq("302 C5: a field with no farmland marks nothing", #dirty, 0)
T.ok("302 C6: and still returns the engine's task", got ~= nil and rawequal(got, fm.tasks[#fm.tasks]))

-- =====================================================================
-- GROUP D: the engine's NPC field update, the path that failed after a sleep
-- =====================================================================

reset()
fm = newFieldManager()
local limeField = newField(5, 0)
local okLime, errLime = withRandom({ 0.1 }, function() fm:updateField(limeField) end)
T.ok("302 D1: the lime branch of updateField runs without an error", okLime, tostring(errLime))
local limeCultivate = fm.tasks[2]
T.eq("302 D2: it queued the lime task and the cultivate task", #fm.tasks, 2)
T.eq("302 D3: the cultivate pass carries the lime spray type",
  limeCultivate and limeCultivate.sprayType, FieldSprayType.LIME)
T.eq("302 D4: and the full lime level", limeCultivate and limeCultivate.limeLevel, fm.limeLevelMaxValue)

reset()
fm = newFieldManager()
local manureField = newField(6, 1)
local okManure, errManure = withRandom({ 0.1, 0.9 }, function() fm:updateField(manureField) end)
T.ok("302 D5: the manure branch of updateField runs without an error", okManure, tostring(errManure))
local manureCultivate = fm.tasks[1]
T.eq("302 D6: the cultivate pass carries spray level 1", manureCultivate and manureCultivate.sprayLevel, 1)
T.eq("302 D7: and the liquid manure spray type the roll chose",
  manureCultivate and manureCultivate.sprayType, FieldSprayType.LIQUID_MANURE)
T.eq("302 D8: the NPC update marked its farmland dirty once", #dirty, 1)
