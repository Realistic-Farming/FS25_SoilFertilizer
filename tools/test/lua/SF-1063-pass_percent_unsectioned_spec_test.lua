-- SF-1063-pass_percent_unsectioned_spec_test.lua
--
-- #1063 (Sauge): on a seeder or spreader with no variable-width sections, Pass % ends
-- well short of 100% on a fully worked field at any rate but the one the BASE_RATES
-- figure assumes. The litre estimate divided the litres used, which already carry the
-- rate multiplier (and SF-79's pH factor), by the product's BASE_RATES number rather
-- than by the litres per hectare the machine actually put down.
--
-- THE ENTRY-POINT BAR. Every pass is a WorkArea tick through the mod's OWN installers,
-- in installAll's order, raising Sprayer.onStartWorkAreaProcessing (the native start,
-- then Soil's rate multiplier append), the processing function and
-- Sprayer.onEndWorkAreaProcessing (Soil's sprayer hook). The usage is Soil's own
-- actual-speed formula, so the litres follow the speed, the width and the product's
-- spray type. The fixture supplies what the engine supplies: the map's spray types
-- (litersPerSecond, never a rate per hectare), the field and its area, the pH the value
-- map holds, and the vehicle. No coverage, rate, multiplier or factor is set by hand:
-- the rate manager's own index and AUTO mode choose them, and Soil registers its own
-- crop protection spray types.
--
-- One field, 12 m x 60 m = 0.072 ha. The 12 m boom crosses it in 60 one-metre ticks, so
-- the whole field is worked once and the pass must end at 100%.
--
--   A-D  FERTILIZER at lps 0.006 (216 L/ha) and 0.005 (180 L/ha), at 1.0x and 0.5x
--   E-F  a machine whose usageScale is 1.5 for this fill type, or 0.8 by default
--   H    halfway through, the pass reads half: a divisor that overshot would hide behind
--        the 100% cap at the end
--   P    LIME with AUTO on, over acid ground: SF-79's factor is above 1 and the pass still
--        ends at 100% (the start hook's own record, not the rate manager's lookup)
--   K    PROPICONAZOLE at 0.5x: the protection window opens once the ground is covered
--        (80%), which a half dose never reached before
--   R    the rate changes from 0.5x to 1.0x mid-field: each tick divides out its own multiplier
--   S    a sectioned rig takes the cells and never the litre estimate
--   N    the nutrient credit (N, P, K), fertilizerApplied and the product's buffer
--        litres: the figures this same bar measured at development 0bb388b7, before
--        the change (there it fails A-D, P2-P4, K2 and K4, the defect, and passes N)
--
-- What this bar does NOT prove: the engine's own spray-type XML on a real map, the
-- value-map rasters' rounding on a real map, the HUD (it draws what this bar reads),
-- the "field fully treated" notification (#1063 part 3, a Design question), MP.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/maps/SoilValueMaps.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua

SoilLogger.debug = function() end
SoilLogger.info = function() end

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
FillType     = { UNKNOWN = 0, FERTILIZER = 1, LIQUIDFERTILIZER = 2, LIQUIDMANURE = 3, DIGESTATE = 4, MANURE = 5, LIME = 6 }
FruitType    = { UNKNOWN = 0 }
ToolType     = { UNDEFINED = 0 }
MoneyType    = MoneyType or { PURCHASE_FERTILIZER = 1, OTHER = 2 }
UIHelper     = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }
WorkAreaType = { DEFAULT = 1, AUXILIARY = 2, SPRAYER = 3 }
g_farmManager = { updateFarmStats = function() end }
g_effectManager = { startEffects = function() end, stopEffects = function() end }
g_i18n = { texts = {}, hasText = function() return false end, getText = function(_, k) return k end }

-- Nodes are world points; getWorldTranslation reads them (the engine's transform).
function getWorldTranslation(node)
  if type(node) == "table" then return node.x, 0, node.z end
  return 0, 0, 0
end
function getWorldRotation() return 0, 0, 0 end

-- ── fill types and the map's spray types ─────────────────────────────────────
-- massPerLiter in tonnes per litre, the descriptor's unit.
local DECL = { FERTILIZER = 0.001, LIQUIDFERTILIZER = 0.001, LIME = 0.001, PROPICONAZOLE = 0.001 }
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
local FERT, LIME, PROP = indexOf("FERTILIZER"), indexOf("LIME"), indexOf("PROPICONAZOLE")

-- The map's own spray types: litersPerSecond as a map's sprayTypes XML gives them. The
-- base map's FERTILIZER is 0.006 and a map like Homeland's is 0.005; a row picks one.
-- Soil's registration adds its own crop protection through addSprayType.
local MAP = { FERTILIZER = 0.006, LIQUIDFERTILIZER = 0.0081, LIME = 0.009 }
local function newSprayTypes()
  local STM = { registered = {} }
  function STM:getSprayTypeByName(n)
    if MAP[n] ~= nil then return { name = n, litersPerSecond = MAP[n], sprayGroundType = 3, index = indexOf(n) } end
    return self.registered[n]
  end
  function STM:addSprayType(n, lps, typeName, ground)
    self.registered[n] = { name = n, index = indexOf(n), litersPerSecond = lps, typeName = typeName }
    return self.registered[n]
  end
  function STM:getSprayTypeByFillTypeIndex(i)
    for n in pairs(MAP) do if indexOf(n) == i then return self:getSprayTypeByName(n) end end
    for n, st in pairs(self.registered) do if indexOf(n) == i then return st end end
    return nil
  end
  function STM:getSprayTypeIndexByFillTypeIndex(i) local st = self:getSprayTypeByFillTypeIndex(i); return st and st.index or nil end
  return STM
end

-- ── the map: one field on farmland 7 (farm 1), 12 m x 60 m ──────────────────
local FIELD_X0, FIELD_X1, FIELD_Z0, FIELD_Z1 = -6, 6, -30, 30
local FIELD_HA = (FIELD_X1 - FIELD_X0) * (FIELD_Z1 - FIELD_Z0) / 10000      -- 0.072
local function onFieldAt(x, z) return x >= FIELD_X0 and x < FIELD_X1 and z >= FIELD_Z0 and z < FIELD_Z1 end
FSDensityMapUtil = {
  getFruitTypeIndexAtWorldPos = function(x, z) if not onFieldAt(x, z) then return nil end return 1, 3 end,
  getFieldDataAtWorldPosition = function(x, _y, z) return onFieldAt(x, z), 0, onFieldAt(x, z) and 1 or 0 end,
}
g_fruitTypeManager = {
  getDefaultDataPlaneId = function() return 77 end,
  getFruitTypeByIndex = function(_, i) return { index = i, name = "WHEAT", getIsCut = function() return false end, getIsWithered = function() return false end } end,
}
function getDensityMapSize(id) if id == 77 then return 128 end return 0 end
g_farmlandManager = {
  getFarmlandIdAtWorldPosition = function(_, x, z) return onFieldAt(x, z) and 7 or 0 end,
  getCanAccessLandAtWorldPosition = function(self, farmId, x, z) return farmId == 1 and self:getFarmlandIdAtWorldPosition(x, z) == 7 end,
  getFarmlandAtWorldPosition = function(self, x, z) local id = self:getFarmlandIdAtWorldPosition(x, z); return id ~= 0 and { id = id, areaInHa = 3 } or nil end,
  getFarmlandById = function(_, id) return { id = id, areaInHa = 3 } end,
  getFarmlandOwner = function(_, id) return id == 7 and 1 or 0 end,
}
MapDataGrid = {
  createFromBlockSize = function(_mapSize, blockSize)
    local g = { cells = {} }
    local function key(x, z) return math.floor(x / blockSize) .. ":" .. math.floor(z / blockSize) end
    function g:getValueAtWorldPos(x, z) return self.cells[key(x, z)] end
    function g:setValueAtWorldPos(x, z, value) self.cells[key(x, z)] = value end
    return g
  end,
}

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

-- ── native Sprayer / FillUnit (Sprayer.lua:314-340, :503-525, :855-957) ──────
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
local function nativeIsExternallyFilled(self) return false end
local function nativeGetExternalFill() return FillType.UNKNOWN, 0 end
local function nativeOnStart(self, dt)                          -- Sprayer.lua:855-936
  local spec = self.spec_sprayer
  local fui = self:getSprayerFillUnitIndex()
  local sprayVehicle, sprayVehicleFillUnitIndex = nil, nil
  local fillType = self:getFillUnitFillType(fui)
  local usage = self:getSprayerUsage(fillType, dt)
  local sprayFillLevel = self:getFillUnitFillLevel(fui)
  if sprayFillLevel > 0 then sprayVehicle = self; sprayVehicleFillUnitIndex = fui end
  local wap = spec.workAreaParameters
  wap.sprayType = g_sprayTypeManager:getSprayTypeIndexByFillTypeIndex(fillType)
  wap.sprayFillType = fillType
  wap.sprayFillLevel = sprayFillLevel
  wap.usage = usage
  wap.usagePerMin = usage / dt * 1000 * 60
  wap.sprayVehicle = sprayVehicle
  wap.sprayVehicleFillUnitIndex = sprayVehicleFillUnitIndex
  wap.lastChangedArea, wap.lastTotalArea, wap.lastStatsArea = 0, 0, 0
  wap.isActive = false
end
local function nativeProcessSprayerArea(self, workArea, dt)    -- Sprayer.lua:314-340
  local spec = self.spec_sprayer
  if spec.workAreaParameters.sprayFillLevel <= 0 then return 0, 0 end
  spec.workAreaParameters.isActive = true
  return 1, 1
end
local function nativeOnEnd(self, dt)                            -- Sprayer.lua:938-957
  local spec = self.spec_sprayer
  if self.isServer and spec.workAreaParameters.isActive then
    local sv = spec.workAreaParameters.sprayVehicle
    if sv ~= nil then
      sv:addFillUnitFillLevel(self:getOwnerFarmId(), spec.workAreaParameters.sprayVehicleFillUnitIndex,
        -spec.workAreaParameters.usage, spec.workAreaParameters.sprayFillType, ToolType.UNDEFINED, nil)
    end
  end
end
local function nativeAddFillUnitFillLevel(self, farmId, fui, delta, ft)   -- FillUnit.lua, "return allowFillType"
  local fu = self.spec_fillUnit.fillUnits[fui]
  if fu == nil then return 0 end
  local old = fu.fillLevel
  if fu.fillType == ft then fu.fillLevel = math.max(0, math.min(fu.capacity, old + delta)) end
  if fu.fillLevel < 0.00001 then fu.fillLevel = 0 end
  if fu.fillLevel <= 0 then fu.fillType = FillType.UNKNOWN end
  return fu.fillLevel - old
end

local function resetEngine()
  FillUnit = { addFillUnitFillLevel = nativeAddFillUnitFillLevel, onPostLoad = function() end }
  Sprayer  = { getSprayerUsage = nativeGetSprayerUsage, getExternalFill = nativeGetExternalFill,
               getIsSprayerExternallyFilled = nativeIsExternallyFilled, onStartWorkAreaProcessing = nativeOnStart,
               onEndWorkAreaProcessing = nativeOnEnd, processSprayerArea = nativeProcessSprayerArea }
  VehicleSystem = { addVehicle = function(_self, _vehicle) return true end }
  g_vehicleTypeManager = { types = {
    sprayer = { specializationsByName = { sprayer = true, fillUnit = true, workArea = true },
                functions = { getSprayerUsage = Sprayer.getSprayerUsage, addFillUnitFillLevel = FillUnit.addFillUnitFillLevel,
                              getExternalFill = Sprayer.getExternalFill,
                              getIsSprayerExternallyFilled = Sprayer.getIsSprayerExternallyFilled,
                              processSprayerArea = Sprayer.processSprayerArea } },
  } }
end

-- ── the vehicle (Vehicle:load: raw copies of the type table) ────────────────
-- A 12 m machine across the field's width, driving +z at 10 km/h.
local BOOM_HALF = 6
local function newSprayer(opts)
  local v = { id = 4242, isServer = true, speedLimit = 12, lastSpeed = 10 / 3600,
              ownerFarmId = 1, activeFarm = 1, turnedOn = true, ai = false,
              specializationNames = { "sprayer", "fillUnit", "workArea" } }
  for name, fn in pairs(g_vehicleTypeManager.types.sprayer.functions) do v[name] = fn end
  v.rootVehicle = v
  v.spec_fillUnit = { fillUnits = { [1] = { fillLevel = 2000, fillType = opts.product, capacity = 3000 } } }
  v.spec_sprayer = { workAreaParameters = {}, usageScale = { default = opts.defaultScale or 1, workingWidth = BOOM_HALF * 2,
                                                             fillTypeScales = { [opts.product] = opts.typeScale } },
                     supportedSprayTypes = {}, fillTypeSources = {} }
  local z = FIELD_Z0 - 0.5
  local wa = { type = WorkAreaType.SPRAYER, functionName = "processSprayerArea",
               start = { x = -BOOM_HALF, z = z }, width = { x = BOOM_HALF, z = z }, height = { x = -BOOM_HALF, z = z - 1 } }
  wa.processingFunction = v.processSprayerArea
  v.spec_workArea = { workAreas = { wa } }
  v.rootNode = { x = 0, z = z }
  if opts.vww then
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
  v.getSprayerDoubledAmountActive = function() return false, true end
  v.raiseDirtyFlags = function() end
  v.stopCurrentAIJob = function() end
  return v
end
local DT = 360                                                -- 1 m per tick at 10 km/h
local function moveBoom(v, dz)
  local wa = v.spec_workArea.workAreas[1]
  wa.start.z, wa.width.z, wa.height.z = wa.start.z + dz, wa.width.z + dz, wa.height.z + dz
  v.rootNode.z = v.rootNode.z + dz
end
local function tick(v)                                         -- WorkArea.lua:124-206
  Sprayer.onStartWorkAreaProcessing(v, DT, v.spec_workArea.workAreas)
  local processed = false
  for _, wa in ipairs(v.spec_workArea.workAreas) do
    if v:getIsWorkAreaActive(wa) then wa.processingFunction(v, wa, DT); processed = true end
  end
  Sprayer.onEndWorkAreaProcessing(v, DT, processed)
end

-- ── the world ───────────────────────────────────────────────────────────────
local W
local FIELD7 = { { x = FIELD_X0, z = FIELD_Z0 }, { x = FIELD_X1, z = FIELD_Z0 }, { x = FIELD_X1, z = FIELD_Z1 }, { x = FIELD_X0, z = FIELD_Z1 } }
local function newWorld(opts)
  resetEngine()
  ENGINE.disk = {}
  MAP.FERTILIZER = opts.lps or 0.006
  g_sprayTypeManager = newSprayTypes()
  local settings = { enabled = true, autoRateControl = true, showNotifications = true, nutrientCycles = true,
                     replenishmentRate = 3, tuningFertilizerEfficiency = 3, overlapPrevention = false,
                     multiTankApplication = true, diseasePressure = true, pestPressure = true, weedPressure = true }
  settings.allowsExperimentalSystems = function() return false end
  g_currentMission = {
    time = 1000, terrainSize = ENGINE.TERRAIN,
    missionInfo = { helperBuyFertilizer = false, helperSlurrySource = 1, helperManureSource = 1 },
    missionDynamicInfo = { isMultiplayer = false },
    environment = { currentDay = 5 },
    addMoney = function() end,
    vehicleSystem = setmetatable({ vehicles = {} }, { __index = VehicleSystem }),
    aiMessageManager = aiMessageManager(),
    hud = { showBlinkingWarning = function() end },
  }
  g_server = {}
  g_fieldManager = { farmlandIdFieldMapping = { [7] = { farmland = { id = 7 }, posX = 0, posZ = 0, areaHa = FIELD_HA } }, fields = {} }
  local ss = setmetatable({
    fieldData = {}, settings = settings, isInitialized = true,
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
  ss.valueMaps = SoilValueMaps.new()
  ss.valueMaps:initialize("savegame")
  ss.paintBoomStrip = function() end                        -- display, not under test
  local hm = HookManager.new()
  hm._sectionScratch = {}
  hm.getBoomLineEndpoints = function() return nil end      -- display, not under test
  ss.hookManager = hm
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  hm._soilSystemRef = ss
  local v = newSprayer(opts)
  g_currentMission.vehicleSystem.vehicles = { v }
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
  ss:getOrCreateField(7, true)
  ss.targetApplication:registerAIMessage()
  if opts.ph ~= nil then ss.valueMaps:paintPolygon("pH", FIELD7, opts.ph) end
  if opts.rate ~= nil then
    for i, step in ipairs(SoilConstants.SPRAYER_RATE.STEPS) do
      if math.abs(step - opts.rate) < 1e-9 then rm:setIndex(v.id, i) end
    end
  end
  if opts.auto then rm:setAutoMode(v.id, true) end
  W = { ss = ss, hm = hm, rm = rm, v = v, installFailed = failed }
  return W
end
local function run(v, n)
  for _ = 1, n do
    moveBoom(v, math.abs(v.lastSpeed) * DT)
    g_currentMission.time = g_currentMission.time + DT
    tick(v)
  end
end
local function tank(v) return v.spec_fillUnit.fillUnits[1].fillLevel end
local function field() return W.ss.fieldData[7] end
local function near(a, b, tol) return type(a) == "number" and math.abs(a - b) <= (tol or 1e-9) end
local TICKS = math.floor((FIELD_Z1 - FIELD_Z0) + 0.5)          -- 60 one-metre ticks

-- One whole-field pass. Returns what the pass did: the litres drawn, the coverage at
-- halfway and at the end, and the field's credit.
local function wholeField(opts)
  newWorld(opts)
  if opts.spy ~= nil then W.ss.trackSprayerCoverage = opts.spy end
  local f0 = field()
  local before = { tank = tank(W.v), n = f0.nitrogen, p = f0.phosphorus, k = f0.potassium }
  run(W.v, TICKS / 2)
  local half = { fraction = field().sessionCoverageFraction, ha = field().coveredAreaHa, days = field().fungicideDaysLeft }
  run(W.v, TICKS / 2)
  local f = field()
  return {
    litres = before.tank - tank(W.v), half = half,
    fraction = f.sessionCoverageFraction, ha = f.coveredAreaHa, sessionHa = f.sessionCoverageHa,
    dn = f.nitrogen - before.n, dp = f.phosphorus - before.p, dk = f.potassium - before.k,
    buffer = f.nutrientBuffer and f.nutrientBuffer[opts.product], applied = f.fertilizerApplied, days = f.fungicideDaysLeft,
    rateMult = W.v.spec_sprayer.workAreaParameters.sfRateMult,
  }
end

-- =====================================================================
-- E0. The install sequence reached the production hooks
-- =====================================================================
do
  newWorld({ product = FERT })
  T.eq("E0.1 the install sequence ran end to end (" .. table.concat(W.installFailed, " | ") .. ")", #W.installFailed, 0)
  T.ok("E0.2 the start event carries Soil's rate multiplier append over the native start",
       Sprayer.onStartWorkAreaProcessing ~= nativeOnStart)
  T.eq("E0.3 the field's area is the map field's (0.072 ha), taken by the soil system itself", field().fieldArea, FIELD_HA)
  T.eq("E0.4 the rig has no variable-width sections", W.v.spec_variableWorkWidth, nil)
end

-- =====================================================================
-- A-D, H. FERTILIZER across the whole field, two map rates, two multipliers
-- =====================================================================
local CASES = {
  { id = "A", lps = 0.006, rate = 1.0 },
  { id = "B", lps = 0.006, rate = 0.5 },
  { id = "C", lps = 0.005, rate = 1.0 },
  { id = "D", lps = 0.005, rate = 0.5 },
  -- the implement's usageScale (its XML): a per-fill-type scale, and a default scale alone
  { id = "E", lps = 0.006, rate = 1.0, typeScale = 1.5 },
  { id = "F", lps = 0.006, rate = 0.5, defaultScale = 0.8 },
}
local RESULT = {}
for _, c in ipairs(CASES) do
  local r = wholeField({ product = FERT, lps = c.lps, rate = c.rate, typeScale = c.typeScale, defaultScale = c.defaultScale })
  RESULT[c.id] = r
  local scale = c.typeScale or c.defaultScale or 1
  local label = string.format("%s FERTILIZER, lps %.3f (%.0f L/ha), scale %.1f, %.1fx", c.id, c.lps, c.lps * 36000, scale, c.rate)
  T.ok(label .. ": [reached] the pass drew the dose the rate and the machine's scale ask for (" .. tostring(r.litres) .. " L)",
       near(r.litres, FIELD_HA * c.lps * 36000 * scale * c.rate, 1e-6))
  T.ok(label .. ": the whole field worked once ends the pass at 100% (" .. tostring(r.fraction) .. ")", near(r.fraction, 1.0, 1e-9))
  T.ok(label .. ": and the worked area is the field's, not capped into it (" .. tostring(r.ha) .. " ha)", near(r.ha, FIELD_HA, 1e-9))
  T.ok(label .. ": H halfway through the field the pass reads 50% (" .. tostring(r.half.fraction) .. ")", near(r.half.fraction, 0.5, 1e-9))
end

-- =====================================================================
-- P. LIME with AUTO on, over acid ground: SF-79's factor rides in the litres
-- =====================================================================
do
  local r = wholeField({ product = LIME, ph = 5.5, auto = true })
  RESULT.P = r
  local native = FIELD_HA * MAP.LIME * 36000
  T.ok("P1 [reached] AUTO's pH factor moved the dose above 1.0x on acid ground (" .. tostring(r.litres / native) .. "x)",
       r.litres / native > 1.05)
  T.ok("P2 and the start hook recorded that factor, the one it applied (" .. tostring(r.rateMult) .. ")",
       near(r.rateMult, r.litres / native, 1e-9))
  T.ok("P3 NAMED: the whole field worked once still ends the pass at 100% (" .. tostring(r.fraction) .. ")", near(r.fraction, 1.0, 1e-9))
  T.ok("P4 and the worked area is the field's (" .. tostring(r.ha) .. " ha)", near(r.ha, FIELD_HA, 1e-9))
end

-- =====================================================================
-- K. PROPICONAZOLE at 0.5x: the protection window opens once the ground is covered
-- =====================================================================
do
  newWorld({ product = PROP, rate = 0.5 })
  local st = g_sprayTypeManager:getSprayTypeByFillTypeIndex(PROP)
  T.ok("K0 [reached] Soil registered PROPICONAZOLE's spray type itself (" .. tostring(st and st.litersPerSecond) .. " L/s)",
       st ~= nil and st.litersPerSecond > 0)
  local before = tank(W.v)
  run(W.v, 47)
  local f = field()
  T.ok("K1 47 of 60 m (78%): below the 80% threshold, no window yet (" .. tostring(f.sessionCoverageFraction) .. ")",
       f.sessionCoverageFraction < 0.80 and (f.fungicideDaysLeft or 0) == 0)
  run(W.v, 2)
  T.ok("K2 NAMED: 49 of 60 m (82%) at a half dose: the fungicide window opens (" .. tostring(f.fungicideDaysLeft) .. " days)",
       near(f.sessionCoverageFraction, 49 / 60, 1e-9) and (f.fungicideDaysLeft or 0) > 0)
  run(W.v, 11)
  T.ok("K3 and the half dose is what went down (" .. tostring(before - tank(W.v)) .. " L)",
       near(before - tank(W.v), FIELD_HA * st.litersPerSecond * 36000 * 0.5, 1e-6))
  T.ok("K4 the whole field ends at 100%", near(f.sessionCoverageFraction, 1.0, 1e-9))
end

-- =====================================================================
-- R. The rate changed mid-field: each tick divides out its own multiplier
-- =====================================================================
do
  newWorld({ product = FERT, rate = 0.5 })
  run(W.v, TICKS / 2)
  for i, step in ipairs(SoilConstants.SPRAYER_RATE.STEPS) do
    if math.abs(step - 1.0) < 1e-9 then W.rm:setIndex(W.v.id, i) end
  end
  run(W.v, TICKS / 2)
  local f = field()
  T.ok("R1 half the field at 0.5x, the rest at 1.0x: the worked area is still the field's (" .. tostring(f.coveredAreaHa) .. " ha)",
       near(f.coveredAreaHa, FIELD_HA, 1e-9))
  T.eq("R2 and no coverage call went without a rate", SoilFertilitySystem.coverageRateMissing, nil)
end

-- =====================================================================
-- S. A sectioned rig takes the cells, never the litre estimate
-- =====================================================================
do
  -- An observer on the soil system's coverage track: it counts the calls that ask for
  -- the litre estimate (updateFractions true) and passes every call to the real method.
  local litreCalls = 0
  local realTrack = SoilFertilitySystem.trackSprayerCoverage
  local spy = function(self, fieldId, liters, name, updateFractions, rate)
    if updateFractions == true then litreCalls = litreCalls + 1 end
    return realTrack(self, fieldId, liters, name, updateFractions, rate)
  end
  local r = wholeField({ product = FERT, rate = 0.5, vww = true, spy = spy })
  RESULT.S = r
  T.eq("S1 the sectioned rig never asked for the litre estimate", litreCalls, 0)
  T.ok("S2 the cells own its coverage (" .. tostring(field()._geometricCoverageOwner) .. ")", field()._geometricCoverageOwner == true)
end

-- =====================================================================
-- N. The credit is the one development 0bb388b7 gave (measured by this bar there)
-- =====================================================================
-- dn/dp/dk: the field's N, P and K gain over the pass; applied: fertilizerApplied (L);
-- buffer: the product's nutrientBuffer litres, the input of the "fully treated" check.
local GOLDEN = {
  A = { dn = 8.8775999999999, dp = 35.5536, dk = 5.3352000000001, applied = 15.552, buffer = 15.552 },
  B = { dn = 4.4387999999999, dp = 17.7768, dk = 2.6676, applied = 7.776, buffer = 7.776 },
  C = { dn = 7.398, dp = 29.628, dk = 4.4460000000001, applied = 12.96, buffer = 12.96 },
  D = { dn = 3.699, dp = 14.814, dk = 2.223, applied = 6.48, buffer = 6.48 },
  P = { applied = 34.992, buffer = 34.992 },
  S = { dn = 4.4388000000004, dp = 17.7768, dk = 2.6676, applied = 7.776, buffer = 7.776, fraction = 1.0 },
}
for _, id in ipairs({ "A", "B", "C", "D", "P", "S" }) do
  local r, g = RESULT[id], GOLDEN[id]
  for _, key in ipairs({ "dn", "dp", "dk", "applied", "buffer", "fraction" }) do
    if g[key] ~= nil then
      T.ok(string.format("N %s %s: %s, as at 0bb388b7 (%s)", id, key, tostring(r[key]), tostring(g[key])), near(r[key], g[key], 1e-9))
    end
  end
end
