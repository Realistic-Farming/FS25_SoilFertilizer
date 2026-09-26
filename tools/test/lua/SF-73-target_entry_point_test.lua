-- SF-73-target_entry_point_test.lua
--
-- THE ENTRY-POINT BAR for SF-73's Soil host slice. Every row drives the real
-- production path from where the engine enters it: a WorkArea tick raising
-- Sprayer.onStartWorkAreaProcessing, the processing function, and
-- Sprayer.onEndWorkAreaProcessing, through the mod's OWN installers in installAll's
-- order (the area hook, the FillUnit purchase layer, the external fill layer, the
-- rate multiplier, the actual-speed usage replacement, the SF-73 cycle start and
-- owned usage layer, R2, the SF-73 enforcement, the overlap prevention prepend, the
-- section state preserver, the drain token). The target plan,
-- the anchor, the footprint, the field baseline, the AI message registration and
-- the result are all obtained by the code under test. Nothing in a row is a
-- hand-filled plan.
--
-- The engine is MODELLED where the mod cannot supply it, from the decompiled scripts:
-- native Sprayer start / processing / end / usage (Sprayer.lua:314-340, :503-525,
-- :855-957), FillUnit:addFillUnitFillLevel's applied-delta return (FillUnit.lua,
-- "return allowFillType"), WorkArea's per-tick order (WorkArea.lua:124-206), the
-- fruit plane reader (FSDensityMapUtil.lua:2849), the farmland map and access
-- (FarmlandManager.lua:267-293), AIMessageManager's index registry (:76-107), the
-- field-id block cache (collections/MapDataGrid.lua:11-24) and the value-map rasters
-- (SF-995-engine_model.lua: 1 m pixels, pixel-centre polygons).
--
-- What this bar does NOT prove: native pixel selection and fruit-plane rounding on
-- real maps, frame cost, MP delivery, the HUD (Wizard's), or in-game money. The
-- TESTING row names the live observations.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

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
    vehicleSystem = { vehicles = {} },
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
  hm._settings = settings
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
  -- the mod's own install sequence for these hooks, in installAll's order
  local seq = { "installSprayerAreaHook", "installPurchaseRefillHook", "installExternalFillHook",
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
-- E0. The install sequence and the gate
-- =====================================================================
do
  newWorld({ gate = false })
  T.eq("E0.1 the install sequence ran end to end (" .. table.concat(W.installFailed, " | ") .. ")", #W.installFailed, 0)
  T.ok("E0.2 the usage slot of the live sprayer is the SF-73 owned layer", W.hm:isOwnedLayerWrapper(rawget(W.v, "getSprayerUsage")))
  T.ok("E0.3 the field records exist and froze their baselines at creation",
       TargetApplication.validBaseline(W.ss.fieldData[7]._sf73Baseline))
  T.ok("E0.4 the boundary AI message registered through the manager (the index registry)",
       g_currentMission.aiMessageManager.classObjectToIndex[SoilTargetBoundaryAIMessage] ~= nil)
  paintCarrier(40, 39.8, 39.8)
  autoOn(W.v)
  local before = tank(W.v)
  run(W.v, 12)
  T.eq("E0.5 gate LOCKED: AUTO on changes nothing, no target state is opened", W.ss.targetApplication.states[W.v], nil)
  T.ok("E0.6 gate LOCKED: the tank drains by the non-target actual-speed usage, as before", tank(W.v) < before)
  T.eq("E0.7 gate LOCKED: no target result exists", W.ss:getApplicationTargetResult(W.v), nil)
end

-- =====================================================================
-- E1. Priming, hold and the closing dose (UREA, own tank, wheat)
-- =====================================================================
local E1 = {}
do
  newWorld()
  paintCarrier(40, 39.8, 39.8)
  autoOn(W.v)
  local n0 = W.ss.fieldData[7].nitrogen
  local pixN0 = px("nitrogen", 0.5, -19.5)
  local dotN0 = px("nitrogen", 0.5, 0.5)
  -- the store's additive strip primitive is what the legacy dot and boom strip write
  -- N/P/K through; on a target cycle neither may call it for N, P or K
  local legacyNPK = 0
  local realAdd = W.vm.addPaintStrip
  W.vm.addPaintStrip = function(self, key, ...)
    if key == "nitrogen" or key == "phosphorus" or key == "potassium" then legacyNPK = legacyNPK + 1 end
    return realAdd(self, key, ...)
  end
  local level0 = tank(W.v)
  run(W.v, 1)
  local r1 = W.ss:getApplicationTargetResult(W.v)
  T.eq("E1.1 the first valid line is observation only (FOOTPRINT_PRIMING)", r1 and r1.reasons[1], "FOOTPRINT_PRIMING")
  T.eq("E1.2 priming buys and draws nothing", tank(W.v), level0)
  T.eq("E1.3 priming paints no native fertilizer", NATIVE.paints, 0)
  -- the held cycles: no whole carrier pixel closed yet
  local paintsBefore = NATIVE.paints
  run(W.v, 2)
  T.eq("E1.4 a held cycle draws nothing from the tank", tank(W.v), level0)
  T.ok("E1.5 a held cycle keeps native paint going (the closing cycle pays for it)", NATIVE.paints > paintsBefore)
  local r, ticks = runToDose(W.v, 20)
  E1.r = r
  T.ok("E1.6 the swept quad closed a pixel row and dosed within the travel of one grain", ticks ~= nil and ticks <= 12)
  T.eq("E1.7 the result is a FOOTPRINT analysis", r and r.scope, "FOOTPRINT")
  T.eq("E1.8 of wheat on field 7", (r and r.cropKey or "?") .. "/" .. tostring(r and r.fieldId), "wheat/7")
  T.eq("E1.9 N is the binding nutrient (UREA carries N only)", r and r.binding, "N")
  local drawn = level0 - tank(W.v)
  T.near("E1.10 physical litres are the magnitude of FillUnit's applied delta", r and r.physicalLitres, drawn, 1e-9)
  T.near("E1.11 the physical litres are the planned quote (a full removal)", r and r.plannedLitres, drawn, 1e-9)
  T.eq("E1.12 N, P and K are all inside the wheat window after the write: REACHED", r and r.doseState, "REACHED")
  local nRaw = r and r.nutrients.N.usefulDelta / STEP
  T.near("E1.13 the useful N delta is a whole number of carrier steps", nRaw - math.floor(nRaw + 0.5), 0, 1e-6)
  local pixN1 = px("nitrogen", 0.5, -19.5)
  T.eq("E1.14 the closed row's N pixel rose by exactly the useful raw delta", pixN1 - pixN0, math.floor(nRaw + 0.5))
  T.ok("E1.15 the coarse field N scalar moved with the actual litres (kept physical consequence)", W.ss.fieldData[7].nitrogen > n0)
  T.near("E1.16 the nutrient buffer holds the actual litres, once", W.ss.fieldData[7].nutrientBuffer[UREA], drawn, 1e-9)
  T.eq("E1.17 the legacy boom strip carried no N for a target cycle",
       px("nitrogen", 0.5, -18.2), px("nitrogen", 0.5, -25.5))
  local agr = r and r.agronomicLitres
  T.ok("E1.18 agronomic litres are known and never above the physical litres", agr ~= nil and agr <= r.physicalLitres + 1e-9)
  T.eq("E1.19 no continuation litres are invented", r and r.continuationLitres, nil)
  local copy = W.ss:getApplicationTargetResult(W.v)
  copy.nutrients.N.reading = -1
  T.ok("E1.20 the getter returns a copy: mutating it leaves the host's result alone",
       W.ss:getApplicationTargetResult(W.v).nutrients.N.reading ~= -1)
  -- the next closure starts where this one ended: its pixels are written once
  local pix1 = px("nitrogen", 0.5, -19.5)
  local r2 = runToDose(W.v, 20)
  T.eq("E1.21 the next closure does not write the previous row again", px("nitrogen", 0.5, -19.5), pix1)
  T.ok("E1.22 the next closure writes the next row", px("nitrogen", 0.5, -18.5) > pixN0)
  T.ok("E1.23 the sequence advances strictly", C.seqGreater(r2.sequence, r.sequence))
  -- the spray point this bench reports (the root at the origin) is where the legacy
  -- narrow-tool dot would have added N; on a target cycle it adds none
  T.eq("E1.24 no legacy N dot on a target cycle (the spray point keeps its painted value)",
       px("nitrogen", 0.5, 0.5), dotN0)
  T.eq("E1.25 no legacy N/P/K dot or strip write was even attempted on a target cycle", legacyNPK, 0)
end

-- =====================================================================
-- E2. A refused cycle at a crop boundary spends and paints nothing
-- =====================================================================
do
  newWorld({ z = 10.03 })
  paintCarrier(40, 39.8, 39.8)
  autoOn(W.v)
  run(W.v, 1)                        -- prime
  local level0 = tank(W.v)
  local n0 = W.ss.fieldData[7].nitrogen
  local refused, paintsDuring, drawsDuring, bufferDuring = nil, 0, 0, nil
  for _ = 1, 40 do
    local p0, d0 = NATIVE.paints, nonZeroDraws()
    local buf0 = W.ss.fieldData[7].nutrientBuffer and W.ss.fieldData[7].nutrientBuffer[UREA] or 0
    run(W.v, 1)
    local r = W.ss:getApplicationTargetResult(W.v)
    if r ~= nil and r.reasons[1] == "MIXED_CROP" then
      refused = r
      paintsDuring = NATIVE.paints - p0
      drawsDuring = nonZeroDraws() - d0
      local buf1 = W.ss.fieldData[7].nutrientBuffer and W.ss.fieldData[7].nutrientBuffer[UREA] or 0
      bufferDuring = buf1 - buf0
      break
    end
  end
  T.ok("E2.1 approaching the barley strip, the witness refuses with MIXED_CROP", refused ~= nil)
  T.eq("E2.2 the refusal is INACTIVE (an honest pause, not unknown)", refused and refused.doseState, "INACTIVE")
  T.eq("E2.3 the refused cycle paints no native fertilizer", paintsDuring, 0)
  T.eq("E2.4 the refused cycle draws nothing from the tank", drawsDuring, 0)
  T.eq("E2.5 the refused cycle credits no Soil nutrient buffer", bufferDuring, 0)
  T.eq("E2.6 the refused cycle spends zero target litres", refused and refused.physicalLitres, 0)
  T.eq("E2.7 the product stays resolved on the work area (no false out-of-fill)", W.v.spec_sprayer.workAreaParameters.sprayFillType, UREA)
end

-- =====================================================================
-- E3. Actual litres are the applied delta: a short removal is APPLICATION_FAILED
-- =====================================================================
do
  newWorld()
  paintCarrier(40, 39.8, 39.8)
  autoOn(W.v)
  run(W.v, 1)
  -- the tank's owner refuses the draw this time (FillUnit returns 0 applied)
  W.v._accessDenied = true
  local r = nil
  for _ = 1, 20 do
    run(W.v, 1)
    r = W.ss:getApplicationTargetResult(W.v)
    if r and r.doseState == "APPLICATION_FAILED" then break end
  end
  T.eq("E3.1 a dose whose removal came back short is APPLICATION_FAILED", r and r.doseState, "APPLICATION_FAILED")
  T.eq("E3.2 the physical litres are what FillUnit applied (zero), never the planned quote", r and r.physicalLitres, 0)
  T.eq("E3.3 no agronomic litres are invented", r and r.agronomicLitres, nil)
  T.eq("E3.4 target automatic stopped for the vehicle", W.rm:getAutoMode(W.v.id), false)
  T.eq("E3.5 the result is the inactive final one", r and r.active, false)
  T.ok("E3.6 the farmer is told product was spent and the result is unconfirmed", #NATIVE.notices >= 1)
end
do
  -- a partial removal: another writer took stock between the quote and native's drain
  newWorld()
  paintCarrier(40, 39.8, 39.8)
  autoOn(W.v)
  run(W.v, 1)
  local r = nil
  for _ = 1, 20 do
    moveBoom(W.v, travelPerTick(W.v))
    g_currentMission.time = g_currentMission.time + DT
    Sprayer.onStartWorkAreaProcessing(W.v, DT, W.v.spec_workArea.workAreas)
    local wap = W.v.spec_sprayer.workAreaParameters
    if (wap.usage or 0) > 0 then
      W.v.spec_fillUnit.fillUnits[1].fillLevel = wap.usage * 0.4    -- the stock now covers 40 % of it
    end
    for _, wa in ipairs(W.v.spec_workArea.workAreas) do wa.processingFunction(W.v, wa, DT) end
    local bufBefore = W.ss.fieldData[7].nutrientBuffer and W.ss.fieldData[7].nutrientBuffer[UREA] or 0
    Sprayer.onEndWorkAreaProcessing(W.v, DT, true)
    r = W.ss:getApplicationTargetResult(W.v)
    if (wap.usage or 0) > 0 then
      local buf = W.ss.fieldData[7].nutrientBuffer[UREA] - bufBefore
      T.near("E3.7 the consequence path entered with the applied litres, not the request", buf, wap.usage * 0.4, 1e-9)
      break
    end
  end
  T.eq("E3.8 a partial removal is APPLICATION_FAILED", r and r.doseState, "APPLICATION_FAILED")
  T.ok("E3.9 its physical litres are the applied 40 %", r and r.physicalLitres > 0 and r.plannedLitres ~= nil and math.abs(r.physicalLitres - 0.4 * r.plannedLitres) < 1e-6)
end

-- =====================================================================
-- E4. The frozen writer: saturate the original overflow cohort, then the band
-- =====================================================================
do
  newWorld()
  -- N low enough that the useful delta exceeds 27 raw steps: only then does a pixel at
  -- raw 200 fall in the band ONE order adds to and the OTHER order then saturates
  paintCarrier(30, 39.8, 39.8)
  -- one pixel of the first closed row sits high on the N layer, one mid-high, one low,
  -- written through the engine modifier the store itself uses
  local e = W.vm:getLayerEntry("nitrogen")
  local function writeRaw(x, z, raw)
    local modifier = DensityMapModifier.new(e.bvm, 0, 8, 1)
    modifier:clearPolygonPoints()
    modifier:addPolygonPointWorldCoords(x - 0.4, z - 0.4)
    modifier:addPolygonPointWorldCoords(x + 0.4, z - 0.4)
    modifier:addPolygonPointWorldCoords(x + 0.4, z + 0.4)
    modifier:addPolygonPointWorldCoords(x - 0.4, z + 0.4)
    modifier:executeSet(raw)
  end
  writeRaw(-3.5, -19.5, 252)
  writeRaw(-2.5, -19.5, 200)
  writeRaw(-1.5, -19.5, 60)
  autoOn(W.v)
  run(W.v, 1)
  local r = runToDose(W.v, 20)
  local d = r and math.floor(r.nutrients.N.usefulDelta / STEP + 0.5) or 0
  T.ok("E4.1 a useful delta wide enough to separate the two orders was written (d >= 28)", d >= 28)
  T.eq("E4.2 a pixel in the original overflow cohort saturates at the ceiling", px("nitrogen", -3.5, -19.5), 255)
  T.eq("E4.3 a pixel below the cohort takes the whole delta once (saturate ran BEFORE the band)",
       px("nitrogen", -2.5, -19.5), math.min(255, 200 + d))
  T.eq("E4.4 an interior pixel takes the delta", px("nitrogen", -1.5, -19.5), 60 + d)
  T.eq("E4.5 raw zero outside the field stays no-data", px("nitrogen", -31.5, -31.5), 0)
end

-- =====================================================================
-- E5. SHORT_QUANTIZED is reported and never banked
-- =====================================================================
do
  newWorld()
  -- FERTILIZER (N 41.1, P 164.6, K 24.7, passthrough) on wheat. Every carrier is a
  -- whole raw value, as the store holds it:
  --   N: alternate 1 m columns at raw 139 / 140, a footprint mean 0.079 under N's aim,
  --      so N binds with a tiny need;
  --   P: raw 100, 0.236 under P's lower edge; the binding dose requests +0.316 of P,
  --      enough to reach the window, and that is less than one raw step (0.394), so
  --      its useful write is zero;
  --   K: raw 101, inside its window, so K neither binds first nor falls short.
  W.v.spec_fillUnit.fillUnits[1].fillType = FERT
  local function valueOf(raw) return (raw - 1) / 254 * 100 end
  paintCarrier(valueOf(140), valueOf(100), valueOf(101))
  local e = W.vm:getLayerEntry("nitrogen")
  for x = -30, 19, 2 do
    local m = DensityMapModifier.new(e.bvm, 0, 8, 1)
    m:clearPolygonPoints()
    m:addPolygonPointWorldCoords(x + 0.05, -30); m:addPolygonPointWorldCoords(x + 0.95, -30)
    m:addPolygonPointWorldCoords(x + 0.95, 30);  m:addPolygonPointWorldCoords(x + 0.05, 30)
    m:executeSet(139)
  end
  autoOn(W.v)
  run(W.v, 1)
  local pBefore = px("phosphorus", 0.5, -19.5)
  local r = runToDose(W.v, 20)
  T.ok("E5.0 the blend dosed, N-bound", r ~= nil and r.binding == "N" and (r.physicalLitres or 0) > 0)
  T.ok("E5.1 P's requested delta was positive and under one raw step",
       r ~= nil and (r.nutrients.P.requestedDelta or 0) > 0 and r.nutrients.P.requestedDelta < STEP)
  T.eq("E5.2 P's useful write quantized to zero", r and r.nutrients.P.usefulDelta, 0)
  T.eq("E5.3 the pass is SHORT_QUANTIZED (reported, not hidden)", r and r.doseState, "SHORT_QUANTIZED")
  T.eq("E5.4 no P pixel moved (nothing written below one step)", px("phosphorus", 0.5, -19.5), pBefore)
  run(W.v, 30)
  T.eq("E5.5 never banked: later closures never catch the lost fraction up on that row",
       px("phosphorus", 0.5, -19.5), pBefore)
  T.eq("E5.6 no remainder is kept on the field record", W.ss.fieldData[7]._sf73Pending, nil)
end

-- =====================================================================
-- E6. The helper's boundary stop: two distinct no-progress refused cycles
-- =====================================================================
do
  newWorld({ z = 10.03 })
  paintCarrier(40, 39.8, 39.8)
  W.v.ai = true
  autoOn(W.v)
  run(W.v, 1)
  for _ = 1, 60 do
    run(W.v, 1)
    if #NATIVE.stops > 0 then break end
  end
  T.eq("E6.1 the helper is stopped once at the boundary", #NATIVE.stops, 1)
  T.ok("E6.2 with the registered Soil boundary message, not an out-of-fill", NATIVE.stops[1] ~= nil
       and getmetatable(NATIVE.stops[1]) ~= nil and getmetatable(NATIVE.stops[1]).__index == SoilTargetBoundaryAIMessage)
  T.eq("E6.3 the message text is the Soil boundary key", NATIVE.stops[1] and NATIVE.stops[1]:getI18NText(), "sf_target_ai_boundary")
end
do
  -- registration failed: the native registered AIMessageErrorUnknown, never a string
  newWorld({ z = 10.03 })
  paintCarrier(40, 39.8, 39.8)
  W.ss.targetApplication.aiMessageClass = nil
  W.v.ai = true
  autoOn(W.v)
  run(W.v, 1)
  for _ = 1, 60 do run(W.v, 1); if #NATIVE.stops > 0 then break end end
  T.ok("E6.4 without a registered class the stop uses the native AIMessageErrorUnknown",
       NATIVE.stops[1] ~= nil and NATIVE.stops[1].unknown == true)
end

-- =====================================================================
-- E7. Refusals by actor and source
-- =====================================================================
local function firstRefusal(opts, setup)
  newWorld(opts)
  paintCarrier(40, 39.8, 39.8)
  if setup then setup(W.v) end
  autoOn(W.v)
  local level0 = tank(W.v)
  run(W.v, 8)
  return W.ss:getApplicationTargetResult(W.v), level0 - tank(W.v)
end
do
  local r, drawn = firstRefusal({}, function(v) v.spec_cultivator = { workAreaParameters = {} } end)
  T.eq("E7.1 a fertilizing cultivator cannot claim a target crop", r and r.reasons[1], "CULTIVATION_NO_TARGET")
  T.eq("E7.2 and spends nothing", drawn, 0)
  r, drawn = firstRefusal({ specs = { "sprayer", "fillUnit", "pdlc_pumpsAndHosesPack.umbilicalSprayer" } })
  T.eq("E7.3 an umbilical sprayer is outside the one litre contract", r and r.reasons[1], "SOURCE_CONTRACT_UNAVAILABLE")
  T.eq("E7.4 and spends nothing", drawn, 0)
  r, drawn = firstRefusal({}, function(v) v._doubled = true end)
  T.eq("E7.5 an effective doubled amount refuses the one-rate target", r and r.reasons[1], "DOUBLED_AMOUNT_ACTIVE")
  T.eq("E7.6 and spends nothing", drawn, 0)
  r, drawn = firstRefusal({}, function(v) v.spec_sowingMachine = { workAreaParameters = {} } end)
  T.eq("E7.7 a fertilizing seeder without the sowability witness withholds target fertilizer", r and r.reasons[1], "SOWABILITY_UNKNOWN")
  T.eq("E7.8 and spends nothing on target", drawn, 0)
  r, drawn = firstRefusal({}, function(v) v.getSprayerUsage = function() return 3 end end)
  T.eq("E7.9 a later occupant of the usage slot suspends target mode before spending", r and r.reasons[1], "SOURCE_CONTRACT_UNAVAILABLE")
  r, drawn = firstRefusal({ x0 = 16 })
  local hasAccess = false
  for _, x in ipairs(r and r.reasons or {}) do if x == "FARM_ACCESS" then hasAccess = true end end
  T.ok("E7.10 a boom reaching another farm's land pauses with FARM_ACCESS among its reasons", hasAccess)
  T.eq("E7.11 and spends nothing", drawn, 0)
  r, drawn = firstRefusal({}, function(v) GROUND.fruitAt = function(x, z) if x > 0 then return 3, 3 end end end)
  T.eq("E7.12 perennial forage under part of the boom is UNSUPPORTED_CROP", r and r.reasons[1], "UNSUPPORTED_CROP")
end

-- =====================================================================
-- E8. A non-N/P/K product is not a target product
-- =====================================================================
do
  newWorld()
  paintCarrier(40, 39.8, 39.8)
  W.v.spec_fillUnit.fillUnits[1].fillType = HERB
  autoOn(W.v)
  run(W.v, 6)
  T.eq("E8.1 a product without N/P/K opens no target plan (NOT_APPLICABLE stays on its own path)",
       W.ss:getApplicationTargetResult(W.v), nil)
end

-- =====================================================================
-- E9. Helper buy: the one quantity is bought once, at the product's price
-- =====================================================================
do
  newWorld({ buy = true })
  paintCarrier(40, 39.8, 39.8)
  local fu = W.v.spec_fillUnit.fillUnits[1]
  fu.fillLevel, fu.fillType, fu.lastValidFillType = 0, FillType.UNKNOWN, UREA
  W.v.getFillUnitLastValidFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].lastValidFillType end
  W.v._buyMode, W.v.ai = true, true
  autoOn(W.v)
  run(W.v, 1)
  T.eq("E9.1 priming in buy mode buys nothing", #NATIVE.money, 0)
  local r = runToDose(W.v, 20)
  local charges, total = 0, 0
  for _, m in ipairs(NATIVE.money) do if m < 0 then charges = charges + 1; total = total - m end end
  local price = W.hm.customFillTypePrices and W.hm.customFillTypePrices[UREA]
  T.ok("E9.2 the buy-mode dose closed with physical litres", r ~= nil and (r.physicalLitres or 0) > 0)
  T.eq("E9.3 one charge was made, on the closing cycle only (held cycles bought nothing)", charges, 1)
  T.near("E9.4 the charge is the target quantity at the product's 1.5x helper price",
         total, (r and r.physicalLitres or 0) * (price or 0) * 1.5, 1e-6)
  T.near("E9.5 the physical litres are the bought litres, equal to the plan", r and r.physicalLitres, r and r.plannedLitres, 1e-9)
  T.eq("E9.6 the tank was never drawn", nonZeroDraws(), 0)
  T.eq("E9.7 the bought pass is REACHED", r and r.doseState, "REACHED")
end

-- =====================================================================
-- E10. Station supply: one capped request to the first stocked storage,
--      the removal measured on the station's own side
-- =====================================================================
local function storage(level)
  local s = { level = level }
  function s:getFillLevel(ft) return (ft == FillType.LIQUIDMANURE) and self.level or 0 end
  function s:setFillLevel(v, ft) if ft == FillType.LIQUIDMANURE then self.level = math.max(0, v) end end
  return s
end
local function station(storages)
  local st = { sourceStorages = storages }
  function st:hasFarmAccessToStorage(farmId, s) return true end
  function st:getFillLevel(ft, farmId)                     -- LoadingStation.lua:168-176
    local n = 0
    for _, s in pairs(self.sourceStorages) do if self:hasFarmAccessToStorage(farmId, s) then n = n + s:getFillLevel(ft) end end
    return n
  end
  function st:removeFillLevel(ft, delta, farmId)           -- LoadingStation.lua:220-234, as decompiled
    local remaining = delta
    for _, s in pairs(self.sourceStorages) do
      if self:hasFarmAccessToStorage(farmId, s) then
        local old = s:getFillLevel(ft)
        if old > 0 then s:setFillLevel(old - delta, ft) end
        remaining = remaining - (old - s:getFillLevel(ft))
        if remaining < 0.0001 then return 0 end
      end
    end
    return remaining
  end
  return st
end
do
  newWorld()
  DECL.LIQUIDMANURE = 0.001
  -- every nutrient below its aim, so the slurry blend doses (a satisfied nutrient
  -- it supplies would bind it at zero)
  paintCarrier(30, 30, 30)
  g_currentMission.missionInfo.helperSlurrySource = 3
  -- two small storages: whichever native's own traversal reaches first is the one
  -- the capped request touches; the other must stay untouched
  local s1, s2 = storage(0.05), storage(0.07)
  g_currentMission.liquidManureLoadingStations = { station({ s1, s2 }) }
  local fu = W.v.spec_fillUnit.fillUnits[1]
  fu.fillLevel, fu.fillType = 0, FillType.UNKNOWN
  W.v._buyMode, W.v.ai = true, true
  autoOn(W.v)
  run(W.v, 1)
  local r = runToDose(W.v, 20)
  local d1, d2 = 0.05 - s1.level, 0.07 - s2.level
  local touched = (d1 > 0 and 1 or 0) + (d2 > 0 and 1 or 0)
  T.ok("E10.1 a station dose closed", r ~= nil and (r.physicalLitres or 0) > 0)
  T.eq("E10.2 exactly one storage was touched (no repeated original request across stores)", touched, 1)
  local first = (d1 > 0) and 0.05 or 0.07
  T.ok("E10.3 the request was capped to that storage's stock", r ~= nil and r.plannedLitres <= first + 1e-9)
  T.near("E10.4 physical litres are what left the station", r and r.physicalLitres, d1 + d2, 1e-9)
  T.eq("E10.5 a supply-capped pass says SHORT_SUPPLY", r and r.doseState, "SHORT_SUPPLY")
  DECL.LIQUIDMANURE = nil
  g_currentMission.liquidManureLoadingStations = nil
end

-- =====================================================================
-- E11. Soil's own overlap prevention, installed and on: a part-suppressed boom
--      refuses NOZZLE_PARTIAL, a fully blocked pass is native inactivity. Neither
--      quotes, buys, draws or paints. The earlier passes are written by the real
--      session-coverage writer (SoilFertilitySystem:markBoomCells), and the
--      suppression is the real prepend's own verdict from them.
-- =====================================================================
local function stampPriorPass(points) W.ss:markBoomCells(7, points) end
local function leftStripSprayedEarlier()
  -- an earlier pass covered the strip under the LEFT section's tip (x = -6) only;
  -- the right tip shares the root's cell, which stays unsprayed
  stampPriorPass({ { x = -5, z = -15 }, { x = -5, z = -25 } })
  g_currentMission.time = g_currentMission.time + 15000     -- older than the wing grace
end
local function bought() local n = 0 for _, m in ipairs(NATIVE.money) do if m < 0 then n = n - m end end return n end
do
  newWorld({ vww = true, overlap = true })
  paintCarrier(40, 39.8, 39.8)
  leftStripSprayedEarlier()
  autoOn(W.v)
  local level0, p0, d0 = tank(W.v), NATIVE.paints, nonZeroDraws()
  run(W.v, 3)
  local r = W.ss:getApplicationTargetResult(W.v)
  local sup = W.v._sfOverlapSuppressedSections or {}
  local buf = W.ss.fieldData[7].nutrientBuffer
  T.ok("E11.1 the real overlap prepend suppressed the left section and not the right", sup[1] ~= nil and sup[2] == nil)
  T.eq("E11.2 SF-73 refuses the part-suppressed boom with NOZZLE_PARTIAL", r and r.reasons[1], "NOZZLE_PARTIAL")
  T.eq("E11.3 as an INACTIVE pause", r and r.doseState, "INACTIVE")
  T.eq("E11.4 zero target litres", r and r.physicalLitres, 0)
  T.eq("E11.5 zero native paint on the part-blocked boom", NATIVE.paints - p0, 0)
  T.eq("E11.6 zero drain", nonZeroDraws() - d0, 0)
  T.eq("E11.7 the tank is untouched", tank(W.v), level0)
  T.eq("E11.8 no Soil nutrient credit", buf and buf[UREA] or 0, 0)
end
do
  -- the same part-blocked boom in helper-buy mode, empty tank: nothing is bought
  newWorld({ vww = true, overlap = true, buy = true })
  paintCarrier(40, 39.8, 39.8)
  local fu = W.v.spec_fillUnit.fillUnits[1]
  fu.fillLevel, fu.fillType, fu.lastValidFillType = 0, FillType.UNKNOWN, UREA
  W.v.getFillUnitLastValidFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].lastValidFillType end
  W.v._buyMode, W.v.ai = true, true
  leftStripSprayedEarlier()
  autoOn(W.v)
  local p0 = NATIVE.paints
  run(W.v, 3)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("E11.9 helper buy: the part-blocked boom refuses NOZZLE_PARTIAL", r and r.reasons[1], "NOZZLE_PARTIAL")
  T.eq("E11.10 helper buy: zero litres bought", bought(), 0)
  T.eq("E11.11 helper buy: zero native paint", NATIVE.paints - p0, 0)
end
do
  -- a fully covered field: the prepend blocks the whole pass (coverage >= 99%)
  newWorld({ vww = true, overlap = true })
  paintCarrier(40, 39.8, 39.8)
  local field = W.ss.fieldData[7]
  local area = (field.fieldArea and field.fieldArea > 0) and field.fieldArea or 1.0
  local pts = {}
  for i = 0, math.ceil(area / 0.01) do pts[#pts + 1] = { x = 1000 + (i % 100) * 10 + 5, z = 1000 + math.floor(i / 100) * 10 + 5 } end
  stampPriorPass(pts)
  T.ok("E11.12 the earlier passes covered the field (the writer's own fraction)", (field.sessionCoverageFraction or 0) >= 0.99)
  W.v.ai = true
  autoOn(W.v)
  local level0, p0, d0 = tank(W.v), NATIVE.paints, nonZeroDraws()
  run(W.v, 6)
  local r = W.ss:getApplicationTargetResult(W.v)
  local buf = field.nutrientBuffer
  T.ok("E11.13 the real prepend blocked the pass", W.v._sfOverlapBlockedPass == true)
  T.eq("E11.14 SF-73 reads it as native inactivity: INACTIVE", r and r.doseState, "INACTIVE")
  T.eq("E11.15 with no refusal reason (Soil blocked it, no boundary was met)", r and #r.reasons, 0)
  T.eq("E11.16 zero target litres", r and r.physicalLitres, 0)
  T.eq("E11.17 zero native paint", NATIVE.paints - p0, 0)
  T.eq("E11.18 zero drain, the tank untouched", (nonZeroDraws() - d0) .. "/" .. tostring(tank(W.v) == level0), "0/true")
  T.eq("E11.19 no Soil nutrient credit", buf and buf[UREA] or 0, 0)
  T.eq("E11.20 a blocked pass never counts toward the helper's boundary stop", #NATIVE.stops, 0)
end

T.summary()
