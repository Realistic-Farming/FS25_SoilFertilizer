-- MAINT-211-refusal_fieldid_spec_test.lua
--
-- MAINTENANCE row 211: SF-73's witness refusal named no field, so a refused pass (Tyson's no-crop
-- pause on field 2) named no field to any surface. The Wizard brief :38 says the result carries
-- "one supported crop and field when known"; Tyson ruled (via Desk, 2026-10-02) that a resolved
-- field is carried. The refusal now names the field when the witness read exactly one (a farmland,
-- no MIXED_FIELD), and the crop only for one supported crop (a crop key, neither MIXED_CROP nor
-- UNSUPPORTED_CROP). Native-inactive refusals and the hold are unchanged.
--
-- THE ENTRY-POINT BAR is groups G1 to G6: the mod's own installers in installAll's order, WorkArea's
-- tick through the real sprayer usage hook into TargetApplication's witness refusal and setResult,
-- read back through the soil system's getApplicationTargetResult; G6 takes the stream the server's
-- real publish wrote into the real SoilApplicationTargetResultEvent on a client. The engine fixture
-- is the SF-73 entry bench's (SF-73-target_entry_point_test.lua, lines 30-458, verbatim). Group T
-- pins the rule itself, row by row, through TargetApplication.refusalIdentity.
--
--   G1  Tyson's case: one owned field, a cut crop: the field, no crop
--   G2  two fields under the boom: none
--   G3  the field's edge names the field; no farmland names none
--   G4  a crop boundary inside one field: the field, no crop
--   G5  a native-inactive cycle names no field; a hold is still a hold
--   G6  a client receives the field
--   T   the rule
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/network/NetworkEvents.lua

local GROUP_N = 0
function group(fn)
  GROUP_N = GROUP_N + 1
  local ok, err = pcall(fn)
  if not ok then T.ok("group " .. GROUP_N .. " ran to its end without a Lua error", false, tostring(err)) end
end
local function M211_BENCH()
SoilLogger.debug = function() end
local WARN = {}
SoilLogger.warning = function(fmt, ...) local ok, s = pcall(string.format, fmt, ...); WARN[#WARN + 1] = ok and s or tostring(fmt) end
SoilLogger.info = function() end

local C = TargetNutrientCore
local STEP = 100 / 254

-- ── the engine's composition helpers (Utils.lua:380-400) ─────────────────────
Utils = {
  appendedFunction = function(oldFunc, newFunc)
    return oldFunc ~= nil and function(...) oldFunc(...) newFunc(...) end or newFunc
  end,
  prependedFunction = function(oldFunc, newFunc)
    return oldFunc ~= nil and function(...) newFunc(...) oldFunc(...) end or newFunc
  end,
  overwrittenFunction = function(oldFunc, newFunc)
    return oldFunc == nil and function(self, ...) return newFunc(self, nil, ...) end
      or function(self, ...) return newFunc(self, oldFunc, ...) end
  end,
}
FillType     = { UNKNOWN = 0, FERTILIZER = 1, LIQUIDFERTILIZER = 2, LIQUIDMANURE = 3, DIGESTATE = 4, MANURE = 5 }
FruitType    = { UNKNOWN = 0 }
ToolType     = { UNDEFINED = 0 }
MoneyType    = MoneyType or { PURCHASE_FERTILIZER = 1, OTHER = 2 }
UIHelper     = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }
WorkAreaType = { DEFAULT = 1, AUXILIARY = 2, SPRAYER = 3 }
g_farmManager = { updateFarmStats = function() end }
-- the effect manager the overlap hook stops and restarts nozzle effects through
g_effectManager = { startEffects = function() end, stopEffects = function() end }
g_i18n = { texts = {}, hasText = function() return false end,
           getText = function(_, k) return k end }

-- Nodes are world points; getWorldTranslation reads them (the engine's transform).
function getWorldTranslation(node)
  if type(node) == "table" then return node.x, 0, node.z end
  return 0, 0, 0
end

-- ── fill types and spray types ───────────────────────────────────────────────
-- massPerLiter in tonnes per litre, the descriptor's unit (densityOf reads it x1000).
local DECL = { UREA = 0.00077, FERTILIZER = 0.001, LIQUIDFERTILIZER = 0.001, HERBICIDE = 0.001 }
local IDX, nextIdx = {}, 100
local function indexOf(name)
  if FillType[name] ~= nil then return FillType[name] end
  if IDX[name] == nil then IDX[name] = nextIdx; nextIdx = nextIdx + 1 end
  return IDX[name]
end
local function descOf(name)
  if DECL[name] == nil then return nil end
  return { name = name, index = indexOf(name), massPerLiter = DECL[name], title = name }
end
g_fillTypeManager = {
  getFillTypeByName      = function(_, n) return descOf(n) end,
  getFillTypeIndexByName = function(_, n) if DECL[n] == nil then return nil end return indexOf(n) end,
  getFillTypeByIndex     = function(_, i) for n in pairs(DECL) do if indexOf(n) == i then return descOf(n) end end return nil end,
}
local UREA, FERT, HERB = indexOf("UREA"), indexOf("FERTILIZER"), indexOf("HERBICIDE")
local STM = { registered = {} }
function STM:getSprayTypeByName(n)
  if n == "FERTILIZER" then return { litersPerSecond = 0.02, sprayGroundType = 3, index = 1 } end
  if n == "LIQUIDFERTILIZER" then return { litersPerSecond = 0.02, sprayGroundType = 2, index = 2 } end
  return self.registered[n]
end
function STM:addSprayType(n, lps, typeName, ground)
  local count = 0
  for _ in pairs(self.registered) do count = count + 1 end
  self.registered[n] = { name = n, index = 10 + count, litersPerSecond = lps, typeName = typeName }
  return self.registered[n]
end
function STM:getSprayTypeByFillTypeIndex(i)
  if i == FERT then return self:getSprayTypeByName("FERTILIZER") end
  for n, st in pairs(self.registered) do if indexOf(n) == i then return st end end
  return nil
end
function STM:getSprayTypeIndexByFillTypeIndex(i) local st = self:getSprayTypeByFillTypeIndex(i); return st and st.index or nil end
g_sprayTypeManager = STM

-- ── the ground: fruit plane, field ground, farmland ─────────────────────────
-- Fruit plane 128 px over the 64 m terrain (0.5 m cells). Wheat everywhere on the
-- field, a barley strip at z in [12, 13). Field ground and farmland 7 (farm 1) cover
-- x, z in [-30, 30); farmland 9 (farm 2) is x >= 20.
local GROUND = {}
local function fruitDesc(index, name)
  return { index = index, name = name,
           getIsCut = function(self, s) return s == 9 end,
           getIsWithered = function(self, s) return s == 10 end }
end
local DESCS = { [1] = fruitDesc(1, "WHEAT"), [2] = fruitDesc(2, "BARLEY"), [3] = fruitDesc(3, "GRASS") }
g_fruitTypeManager = {
  getDefaultDataPlaneId = function() return 77 end,
  getFruitTypeByIndex = function(_, i) return DESCS[i] end,
}
function getDensityMapSize(id) if id == 77 then return 128 end return 0 end
local function onFieldAt(x, z) return x >= -30 and x < 30 and z >= -30 and z < 30 end
FSDensityMapUtil = {
  getFruitTypeIndexAtWorldPos = function(x, z)
    if not onFieldAt(x, z) then return nil end
    if GROUND.fruitAt then local f, s = GROUND.fruitAt(x, z); if f ~= nil then return f, s end end
    if z >= 12 and z < 13 then return 2, 3 end
    return 1, 3
  end,
  getFieldDataAtWorldPosition = function(x, _y, z) return onFieldAt(x, z), 0, onFieldAt(x, z) and 1 or 0 end,
}
local FARMLAND_OWNER = { [7] = 1, [9] = 2 }
g_farmlandManager = {
  getFarmlandIdAtWorldPosition = function(_, x, z)
    if not onFieldAt(x, z) then return 0 end
    if x >= 20 then return 9 end
    return 7
  end,
  getCanAccessLandAtWorldPosition = function(self, farmId, x, z)   -- FarmlandManager.lua:267-273
    if farmId == 0 or farmId == nil then return false end
    local owner = FARMLAND_OWNER[self:getFarmlandIdAtWorldPosition(x, z)]
    return owner == farmId
  end,
  getFarmlandAtWorldPosition = function(self, x, z)             -- FarmlandManager.lua:289-292
    local id = self:getFarmlandIdAtWorldPosition(x, z)
    return id ~= 0 and { id = id, areaInHa = 30 } or nil
  end,
  getFarmlandById = function(_, id) return { id = id, areaInHa = 30 } end,
  getFarmlandOwner = function(_, id) return FARMLAND_OWNER[id] or 0 end,
}
-- The engine's field-id block cache (collections/MapDataGrid.lua:11-24): one value per
-- blockSize-metre block, read and written by world position.
MapDataGrid = {
  createFromBlockSize = function(_mapSize, blockSize)
    local g = { cells = {} }
    local function key(x, z) return math.floor(x / blockSize) .. ":" .. math.floor(z / blockSize) end
    function g:getValueAtWorldPos(x, z) return self.cells[key(x, z)] end
    function g:setValueAtWorldPos(x, z, value) self.cells[key(x, z)] = value end
    return g
  end,
}
g_fieldManager = { farmlandIdFieldMapping = { [7] = { farmland = { id = 7 }, posX = 0, posZ = 0 },
                                              [9] = { farmland = { id = 9 }, posX = 25, posZ = 0 } },
                   fields = {} }

-- ── the AI message registry (AIMessageManager.lua:76-107) ───────────────────
AIMessage = {}
local AIMessage_mt = Class(AIMessage)
function AIMessage.new(mt) return setmetatable({}, mt or AIMessage_mt) end
AIMessageErrorUnknown = {}
local AIMessageErrorUnknown_mt = Class(AIMessageErrorUnknown)
function AIMessageErrorUnknown.new() return setmetatable({ unknown = true }, AIMessageErrorUnknown_mt) end
AIMessageErrorOutOfFill = { new = function() return { outOfFill = true } end }
local function aiMessageManager()
  local m = { messages = {}, classObjectToIndex = {} }
  function m:registerMessage(name, classObject)
    for _, e in ipairs(self.messages) do if e.name == name then return nil end end
    local e = { name = name, classObject = classObject }
    table.insert(self.messages, e)
    self.classObjectToIndex[classObject] = #self.messages
    return e
  end
  function m:getMessageIndex(object)
    local mt = getmetatable(object)
    local cls = mt and mt.__index
    return cls and self.classObjectToIndex[cls] or nil
  end
  return m
end

-- ── native Sprayer / FillUnit ───────────────────────────────────────────────
local NATIVE = {}
local function nativeGetSprayerUsage(self, fillType, dt)   -- Sprayer.lua:503-525
  if fillType == FillType.UNKNOWN then return 0 end
  local spec = self.spec_sprayer
  local scale = spec.usageScale.fillTypeScales[fillType] or spec.usageScale.default
  local lps = 1
  local st = g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillType)
  if st ~= nil then lps = st.litersPerSecond end
  local us = spec.usageScale
  local workWidth = (us.workAreaIndex == nil) and us.workingWidth or self:getWorkAreaWidth(us.workAreaIndex)
  return scale * lps * self.speedLimit * workWidth * dt * 0.001
end
local function nativeIsExternallyFilled(self)                 -- Sprayer.lua:341 (the buy flag, reduced)
  return self._buyMode == true
end
local function nativeGetExternalFill(self, fillType, dt)       -- Sprayer.lua:452-465, the fertilizer branch
  if g_currentMission.missionInfo.helperBuyFertilizer then
    local usage = self:getSprayerUsage(fillType, dt)
    NATIVE.money[#NATIVE.money + 1] = -usage
    return fillType, usage
  end
  return FillType.UNKNOWN, 0
end
local function nativeOnStart(self, dt)                          -- Sprayer.lua:855-936
  local spec = self.spec_sprayer
  local fui = self:getSprayerFillUnitIndex()
  local sprayVehicle, sprayVehicleFillUnitIndex = nil, nil
  local fillType = self:getFillUnitFillType(fui)
  local usage = self:getSprayerUsage(fillType, dt)
  local sprayFillLevel = self:getFillUnitFillLevel(fui)
  if sprayFillLevel > 0 then sprayVehicle = self; sprayVehicleFillUnitIndex = fui end
  local isExternallyFilled = self:getIsSprayerExternallyFilled()
  local externalFillType, externalUsage
  if isExternallyFilled and self:getIsTurnedOn() then
    externalFillType, externalUsage = self:getExternalFill(fillType, dt)
    if externalFillType == FillType.UNKNOWN then
      externalUsage = sprayFillLevel; externalFillType = fillType
    else
      sprayVehicle = nil; sprayVehicleFillUnitIndex = nil; usage = externalUsage
    end
  else
    externalUsage = sprayFillLevel; externalFillType = fillType
  end
  local wap = spec.workAreaParameters
  wap.sprayType = g_sprayTypeManager:getSprayTypeIndexByFillTypeIndex(externalFillType)
  wap.sprayFillType = externalFillType
  wap.sprayFillLevel = externalUsage
  wap.usage = usage
  wap.usagePerMin = usage / dt * 1000 * 60
  wap.sprayVehicle = sprayVehicle
  wap.sprayVehicleFillUnitIndex = sprayVehicleFillUnitIndex
  wap.lastChangedArea, wap.lastTotalArea, wap.lastStatsArea = 0, 0, 0
  wap.isActive = false
end
local function nativeProcessSprayerArea(self, workArea, dt)    -- Sprayer.lua:314-340
  local spec = self.spec_sprayer
  if self:getIsAIActive() and (spec.workAreaParameters.sprayFillType == nil or spec.workAreaParameters.sprayFillType == FillType.UNKNOWN) then
    self.rootVehicle:stopCurrentAIJob(AIMessageErrorOutOfFill.new())
    return 0, 0
  end
  if spec.workAreaParameters.sprayFillLevel <= 0 then return 0, 0 end
  NATIVE.paints = NATIVE.paints + 1
  spec.workAreaParameters.isActive = true
  return 1, 1
end
local function nativeOnEnd(self, dt)                            -- Sprayer.lua:938-957
  local spec = self.spec_sprayer
  if self.isServer and spec.workAreaParameters.isActive then
    local sv = spec.workAreaParameters.sprayVehicle
    local usage = spec.workAreaParameters.usage
    if sv ~= nil then
      sv:addFillUnitFillLevel(self:getOwnerFarmId(), spec.workAreaParameters.sprayVehicleFillUnitIndex, -usage,
        spec.workAreaParameters.sprayFillType, ToolType.UNDEFINED, nil)
    end
  end
end
local function nativeAddFillUnitFillLevel(self, farmId, fui, delta, ft, toolType, fpd)   -- FillUnit.lua
  NATIVE.fuCalls[#NATIVE.fuCalls + 1] = { delta = delta, ft = ft }
  if delta < 0 and self._accessDenied then return 0 end          -- the canFarmAccess refusal: 0 applied
  local fu = self.spec_fillUnit.fillUnits[fui]
  if fu == nil then return 0 end
  local old = fu.fillLevel
  if fu.fillType == ft then fu.fillLevel = math.max(0, math.min(fu.capacity, old + delta)) end
  if fu.fillLevel < 0.00001 then fu.fillLevel = 0 end
  if fu.fillLevel <= 0 then fu.fillType = FillType.UNKNOWN end
  return fu.fillLevel - old                                       -- "return allowFillType"
end

local function resetEngine()
  NATIVE.paints, NATIVE.fuCalls, NATIVE.money, NATIVE.stops = 0, {}, {}, {}
  FillUnit = { addFillUnitFillLevel = nativeAddFillUnitFillLevel, onPostLoad = function() end }
  Sprayer  = { getSprayerUsage = nativeGetSprayerUsage, getExternalFill = nativeGetExternalFill,
               getIsSprayerExternallyFilled = nativeIsExternallyFilled, onStartWorkAreaProcessing = nativeOnStart,
               onEndWorkAreaProcessing = nativeOnEnd, processSprayerArea = nativeProcessSprayerArea }
  -- VehicleSystem is a Class (VehicleSystem.lua:3, :6); the mission's instance reaches
  -- addVehicle through __index (the sprayer overlap gate wraps the class method)
  VehicleSystem = { addVehicle = function(_self, _vehicle) return true end }
  -- finalizeTypes: the type table reads the CLASS functions at boot
  g_vehicleTypeManager = { types = {
    sprayer = { specializationsByName = { sprayer = true, fillUnit = true, workArea = true },
                functions = { getSprayerUsage = Sprayer.getSprayerUsage, addFillUnitFillLevel = FillUnit.addFillUnitFillLevel,
                              getExternalFill = Sprayer.getExternalFill,
                              getIsSprayerExternallyFilled = Sprayer.getIsSprayerExternallyFilled,
                              processSprayerArea = Sprayer.processSprayerArea } },
  } }
end

-- ── the vehicle (Vehicle:load: raw copies of the type table) ────────────────
local BOOM_HALF = 6
local function newSprayer(opts)
  opts = opts or {}
  local v = { id = 4242, isServer = true, speedLimit = 12, lastSpeed = (opts.speedKmh or 10) / 3600,
              ownerFarmId = 1, activeFarm = opts.farm or 1, turnedOn = true, ai = false,
              specializationNames = opts.specs or { "sprayer", "fillUnit", "workArea" } }
  for name, fn in pairs(g_vehicleTypeManager.types.sprayer.functions) do v[name] = fn end
  v.rootVehicle = v
  v.spec_fillUnit = { fillUnits = { [1] = { fillLevel = opts.level or 500, fillType = opts.product or UREA, capacity = 3000 } } }
  v.spec_sprayer = { workAreaParameters = {}, usageScale = { default = 1, workingWidth = BOOM_HALF * 2, fillTypeScales = {} },
                     supportedSprayTypes = {}, fillTypeSources = {} }
  local z = opts.z or -20.03
  local x0 = opts.x0 or 0
  local wa = { type = WorkAreaType.SPRAYER, functionName = "processSprayerArea",
               start = { x = x0 - BOOM_HALF, z = z }, width = { x = x0 + BOOM_HALF, z = z }, height = { x = x0 - BOOM_HALF, z = z - 1 } }
  wa.processingFunction = v.processSprayerArea          -- WorkArea:onLoad captured the instance copy
  v.spec_workArea = { workAreas = { wa } }
  v.rootNode = { x = x0, z = z }
  if opts.vww then
    -- VariableWorkWidth: the left section tips at the work area's start corner, the
    -- right section at its width corner (the preserver's furthest-node rule)
    v.spec_variableWorkWidth = { sections = { { isActive = true, maxWidthNode = wa.start },
                                              { isActive = true, maxWidthNode = wa.width } } }
  end
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
  v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
  v.getFillUnitLastValidFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
  v.getFillUnitAllowsFillType = function() return true end
  v.getOwnerFarmId = function(self) return self.ownerFarmId end
  v.getActiveFarm = function(self) return self.activeFarm end
  v.getIsTurnedOn = function(self) return self.turnedOn end
  v.getIsAIActive = function(self) return self.ai end
  v.getIsFieldWorkActive = function() return true end
  v.getIsWorkAreaActive = function(self, a) return self.turnedOn end
  v.getWorkAreaWidth = function() return BOOM_HALF * 2 end
  v.getLastSpeed = function(self) return self.lastSpeed * 3600 end
  v.getActiveSprayType = function() return nil end
  v.getSprayerDoubledAmountActive = function(self) return self._doubled == true, true end
  v.raiseDirtyFlags = function() end
  v.stopCurrentAIJob = function(self, message) NATIVE.stops[#NATIVE.stops + 1] = message end
  return v
end
local function moveBoom(v, dz)
  local wa = v.spec_workArea.workAreas[1]
  wa.start.z, wa.width.z, wa.height.z = wa.start.z + dz, wa.width.z + dz, wa.height.z + dz
  v.rootNode.z = v.rootNode.z + dz
end
local DT = 36
local function tick(v)                                         -- WorkArea.lua:124-206
  Sprayer.onStartWorkAreaProcessing(v, DT, v.spec_workArea.workAreas)
  local processed = false
  for _, wa in ipairs(v.spec_workArea.workAreas) do
    if v:getIsWorkAreaActive(wa) then wa.processingFunction(v, wa, DT); processed = true end
  end
  Sprayer.onEndWorkAreaProcessing(v, DT, processed)
end
local function travelPerTick(v) return math.abs(v.lastSpeed) * DT end   -- m/ms x ms

-- ── the world ───────────────────────────────────────────────────────────────
local W
local function newWorld(opts)
  opts = opts or {}
  resetEngine()
  GROUND.fruitAt = nil
  ENGINE.disk = {}
  local settings = { enabled = true, autoRateControl = true, showNotifications = true, nutrientCycles = true,
                     replenishmentRate = 3, tuningFertilizerEfficiency = 3, overlapPrevention = opts.overlap == true,
                     multiTankApplication = true }
  settings.allowsExperimentalSystems = function() return opts.gate ~= false end
  g_currentMission = {
    time = 1000, terrainSize = ENGINE.TERRAIN,
    missionInfo = { helperBuyFertilizer = opts.buy == true, helperSlurrySource = 1, helperManureSource = 1 },
    missionDynamicInfo = { isMultiplayer = false },
    environment = { currentDay = 5 },
    addMoney = function(_, amount) NATIVE.money[#NATIVE.money + 1] = amount end,
    vehicleSystem = setmetatable({ vehicles = {} }, { __index = VehicleSystem }),
    aiMessageManager = aiMessageManager(),
    hud = { showBlinkingWarning = function(_, text) NATIVE.notices[#NATIVE.notices + 1] = text end },
  }
  NATIVE.notices = {}
  g_server = {}
  local ss = setmetatable({
    fieldData = {}, settings = settings, isInitialized = true,
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
  ss.valueMaps = SoilValueMaps.new()
  ss.valueMaps:initialize("savegame")
  local hm = HookManager.new()
  hm._sectionScratch = {}
  hm.getBoomCellPositions = function() return nil end   -- display sweep, not under test
  hm.getBoomLineEndpoints = function() return nil end
  ss.hookManager = hm
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  hm._soilSystemRef = ss
  local v = newSprayer(opts)
  g_currentMission.vehicleSystem.vehicles = { v }
  -- the mod's own install sequence for these hooks, in installAll's order (the sprayer
  -- overlap gate sits right after harvest, ahead of all of them; RSF-F226 item 3)
  local seq = { "installSprayerOverlapGate", "installSprayerAreaHook", "installPurchaseRefillHook", "installExternalFillHook",
                "installSprayerStartHook", "installSprayerUsageHook", "installTargetApplicationHooks",
                "installExternalFillOptInHook", "registerCustomSprayTypes", "installDensityRefusalHook",
                "installTargetStartEnforcement", "installOverlapPreventionHook", "installSectionStatePreserver",
                "installDrainTokenHook" }
  local failed = {}
  for _, name in ipairs(seq) do
    local ok, err = pcall(HookManager[name], hm)
    if not ok then failed[#failed + 1] = name .. ": " .. tostring(err) end
  end
  -- the fields exist as the soil system creates them (getOrCreateField)
  ss:getOrCreateField(7, true)
  ss:getOrCreateField(9, true)
  ss.targetApplication:registerAIMessage()
  W = { ss = ss, hm = hm, rm = rm, v = v, vm = ss.valueMaps, settings = settings, installFailed = failed }
  return W
end

-- paint the field's carrier the way the soil store holds it (the real writer)
local FIELD7 = { { x = -30, z = -30 }, { x = 20, z = -30 }, { x = 20, z = 30 }, { x = -30, z = 30 } }
local function paintCarrier(n, p, k, verts)
  verts = verts or FIELD7
  W.vm:paintPolygon("nitrogen", verts, n)
  W.vm:paintPolygon("phosphorus", verts, p)
  W.vm:paintPolygon("potassium", verts, k)
end
local function layer(key) return W.vm:getLayerEntry(key).bvm end
local function px(key, x, z)
  local size = ENGINE.RESOLUTION
  local ix = math.floor((x + 32) / 64 * size)
  local iz = math.floor((z + 32) / 64 * size)
  return ENGINE.pixel(layer(key), ix, iz)
end
local function autoOn(v) W.rm:setAutoMode(v.id, true) end
local function run(v, n)
  for _ = 1, n do
    moveBoom(v, travelPerTick(v))
    g_currentMission.time = g_currentMission.time + DT
    tick(v)
  end
end
--- Run until a dose closes (the result shows litres spent), at most `limit` ticks.
local function runToDose(v, limit)
  for i = 1, limit or 40 do
    run(v, 1)
    local r = W.ss:getApplicationTargetResult(v)
    if r ~= nil and (r.physicalLitres or 0) > 0 then return r, i end
  end
  return W.ss:getApplicationTargetResult(v), nil
end
local function tank(v) return v.spec_fillUnit.fillUnits[1].fillLevel end
local function nonZeroDraws()
  local n = 0
  for _, c in ipairs(NATIVE.fuCalls) do if c.delta ~= 0 then n = n + 1 end end
  return n
end


-- =====================================================================
-- MAINTENANCE row 211: the worlds
-- =====================================================================
local NET_ID = 77
NetworkUtil = NetworkUtil or {}
local function serverWorld(opts)
  opts = opts or {}
  newWorld(opts)
  W.sent = {}
  g_server = { broadcastEvent = function(_, ev)
    if getmetatable(ev) == SoilApplicationTargetResultEvent_mt then
      local s = _sfMockStream()
      ev:writeStream(s, nil)
      W.sent[#W.sent + 1] = { stream = s, result = ev.result and ev.result.doseState }
    end
  end }
  g_currentMission.missionDynamicInfo.isMultiplayer = opts.mp == true
  NetworkUtil.getObjectId = function(v) if v == W.v then return NET_ID end return nil end
  paintCarrier(40, 39.8, 39.8)
  if opts.ground then GROUND.fruitAt = opts.ground end
  return W
end
local CUT_BARLEY = function() return 2, 9 end       -- the fixture's cut state (getIsCut: s == 9)
local function reasonsOf(r) return r and table.concat(r.reasons or {}, ",") or "?" end
local function has(r, reason)
  for _, x in ipairs(r and r.reasons or {}) do if x == reason then return true end end
  return false
end
--- Run until the stored result carries a given reason, at most `limit` ticks.
local function runUntil(reason, limit)
  for _ = 1, limit or 40 do
    run(W.v, 1)
    local r = W.ss:getApplicationTargetResult(W.v)
    if has(r, reason) then return r end
  end
  return W.ss:getApplicationTargetResult(W.v)
end

-- =====================================================================
-- G1. Tyson's case: one owned field, a cut crop. The refusal names the field, no crop.
-- =====================================================================
group(function()
  serverWorld({ ground = CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("G1.1 [reached] the real hooks refused the cut crop: UNSUPPORTED_CROP alone", reasonsOf(r), "UNSUPPORTED_CROP")
  T.eq("G1.2 NAMED: the refusal names the field the boom stands on", r and r.fieldId, 7)
  T.eq("G1.3 NAMED: and no crop: the cut barley is not a supported target crop",
       tostring(r and r.cropKey) .. "/" .. tostring(r and r.cropFruitIndex), "nil/nil")
  T.eq("G1.4 it is still a refusal, never a hold (it carries a reason)", TargetNutrientCore.isHold(r), false)
end)

-- =====================================================================
-- G2. A boom across two fields (and another farm's land): MIXED_FIELD names none
-- =====================================================================
group(function()
  serverWorld({ x0 = 16 })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("G2.1 [reached] the witness refused with MIXED_FIELD (" .. reasonsOf(r) .. ")", has(r, "MIXED_FIELD"))
  T.eq("G2.2 NAMED: two fields under the boom: no field is named", r and r.fieldId, nil)
  T.eq("G2.3 and no crop", r and r.cropKey, nil)
end)

-- =====================================================================
-- G3. The field's edge names the field; ground with no farmland at all names none
-- =====================================================================
group(function()
  serverWorld({ z = 30.5 })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("G3.1 [reached] a boom half over the field's edge: unread ground beside field 7 (" .. reasonsOf(r) .. ")",
       has(r, "UNKNOWN_GROUND") and not has(r, "MIXED_FIELD"))
  T.eq("G3.2 NAMED: one farmland read: the field is named", r and r.fieldId, 7)
end)
group(function()
  serverWorld({ z = 31.6 })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("G3.3 [reached] a boom wholly off the field: refused (" .. reasonsOf(r) .. ")",
       has(r, "UNKNOWN_GROUND") or has(r, "OUTSIDE_MAP"))
  T.eq("G3.4 NAMED: no farmland read: no field is named", r and r.fieldId, nil)
end)

-- =====================================================================
-- G4. A crop boundary inside one field: the field is named, the crop is not
-- =====================================================================
group(function()
  serverWorld({ z = 10.03 })
  autoOn(W.v)
  run(W.v, 1)
  local r = runUntil("MIXED_CROP", 40)
  T.ok("G4.1 [reached] the boom crossed the barley strip in field 7: MIXED_CROP (" .. reasonsOf(r) .. ")", has(r, "MIXED_CROP"))
  T.eq("G4.2 NAMED: one field: it is named", r and r.fieldId, 7)
  T.eq("G4.3 NAMED: two crops: none is named as the target crop",
       tostring(r and r.cropKey) .. "/" .. tostring(r and r.cropFruitIndex), "nil/nil")
end)

-- =====================================================================
-- G5. Unchanged: a native-inactive cycle names no field; a hold is still a hold
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  W.v.turnedOn = false
  run(W.v, 2)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("G5.1 [reached] switched off with AUTO on: INACTIVE, no reason", r ~= nil and r.doseState == "INACTIVE" and #r.reasons == 0)
  T.eq("G5.2 NAMED: a native-inactive cycle still names no field", r and r.fieldId, nil)
  T.eq("G5.3 so it is still not a hold (W1a and W1b's test)", TargetNutrientCore.isHold(r), false)
  W.v.turnedOn = true
  run(W.v, 2)                                   -- prime, then the first hold
  r = W.ss:getApplicationTargetResult(W.v)
  T.ok("G5.4 NAMED: the hold after priming is still a hold (INACTIVE, no reason, field 7)",
       TargetNutrientCore.isHold(r) and r.fieldId == 7)
end)

-- =====================================================================
-- G6. A client receives the named field through the event's real stream
-- =====================================================================
group(function()
  serverWorld({ ground = CUT_BARLEY, mp = true })
  autoOn(W.v)
  run(W.v, 1)
  local sent = W.sent[#W.sent]
  T.ok("G6.1 [reached] the server published the refusal", sent ~= nil and sent.result == "INACTIVE")
  local serverFields = W.ss.fieldData
  g_server = nil
  local settings = { enabled = true, autoRateControl = true }
  settings.allowsExperimentalSystems = function() return true end
  g_currentMission = { time = 50000, missionDynamicInfo = { isMultiplayer = true }, terrainSize = ENGINE.TERRAIN }
  local ss = setmetatable({ fieldData = serverFields, settings = settings }, { __index = SoilFertilitySystem })
  ss.targetApplication = TargetApplication.new(ss)
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = SprayerRateManager.new() }
  local cv = newSprayer({})
  cv.isServer = false
  NetworkUtil.getObject = function(id) if id == NET_ID then return cv end return nil end
  local dst = SoilApplicationTargetResultEvent.emptyNew()
  dst:readStream(sent.stream, { getIsServer = function() return true end })
  local r = ss:getApplicationTargetResult(cv)
  T.eq("G6.2 the stream read back with no fault, every field consumed",
       tostring(_sfStreamFaults(sent.stream)) .. "/" .. tostring(sent.stream.r == #sent.stream.q + 1), "0/true")
  T.eq("G6.3 NAMED: the client's result names field 7 and no crop",
       tostring(r and r.fieldId) .. "/" .. tostring(r and r.cropKey) .. "/" .. reasonsOf(r), "7/nil/UNSUPPORTED_CROP")
end)

-- =====================================================================
-- T. The rule itself, row by row (the pure function the refusal calls)
-- =====================================================================
group(function()
  local function id(v) local f, x, c = TargetApplication.refusalIdentity(v) return tostring(f) .. "/" .. tostring(x) .. "/" .. tostring(c) end
  T.eq("T1 one field, a supported crop, a boundary reason elsewhere: both named",
       id({ farmlandId = 7, fruitIndex = 1, cropKey = "wheat", reasons = { "NOZZLE_PARTIAL" } }), "7/1/wheat")
  T.eq("T2 MIXED_FIELD: nothing", id({ farmlandId = 7, fruitIndex = 1, cropKey = "wheat", reasons = { "MIXED_FIELD" } }), "nil/nil/nil")
  T.eq("T3 UNSUPPORTED_CROP: the field only", id({ farmlandId = 7, fruitIndex = 2, cropKey = "barley", reasons = { "UNSUPPORTED_CROP" } }), "7/nil/nil")
  T.eq("T4 MIXED_CROP: the field only", id({ farmlandId = 7, fruitIndex = 1, cropKey = "wheat", reasons = { "MIXED_CROP" } }), "7/nil/nil")
  T.eq("T5 no crop key: the field only", id({ farmlandId = 7, fruitIndex = 3, cropKey = nil, reasons = { "UNKNOWN_GROUND" } }), "7/nil/nil")
  T.eq("T6 no farmland: nothing", id({ farmlandId = nil, fruitIndex = 1, cropKey = "wheat", reasons = { "UNKNOWN_GROUND" } }), "nil/nil/nil")
  T.eq("T7 farmland 0: nothing", id({ farmlandId = 0, reasons = { "UNKNOWN_GROUND" } }), "nil/nil/nil")
  -- the row's rule names one field whatever the reason; a boom wholly on another farm's one field
  -- (FARM_ACCESS alone) names that field and its supported crop. (The fixture's farmland 9 is
  -- narrower than the boom, so the real path cannot stand wholly on it here.)
  T.eq("T8 FARM_ACCESS over one other farm's field: that field and its supported crop",
       id({ farmlandId = 9, fruitIndex = 1, cropKey = "wheat", reasons = { "FARM_ACCESS" } }), "9/1/wheat")
end)

end
M211_BENCH()
