-- SF-73-W1a-hud_target_block_spec_test.lua
--
-- SF-73 section 7, W1a: the HUD's target block, the host's own floor for target
-- automatic (Implementation v1.1 section 7, the Wizard brief sections 2 and 3, Iris's
-- answer of 2026-10-02 section 1; Bob's intake BOB-INTAKE-W1-SF73-SECTION7-SURFACE).
-- In the rate panel, under the AUTO header, the block reads the soil system's result
-- for the sprayer the player sits in and replaces the legacy "Target:" line, which is
-- built from field info and defaults and cannot stand in for a confirmed footprint.
--
-- THE ENTRY-POINT BAR is groups E (host) and C (client). E drives Tyson's case, liquid
-- DAP with AUTO on over a cut crop, through the mod's own installers in installAll's
-- order and WorkArea's tick into TargetApplication's refusal, setResult and publish;
-- the HUD's own update() and drawSprayerRatePanel then draw what production draws. C
-- takes the stream the server's real publish wrote, reads it into the real
-- SoilApplicationTargetResultEvent on a client, through TA:receive, and draws the
-- client's HUD. No group hands the block a result, except N's notice sequence and the
-- table rows T and M, which pin the pure mapping the entry groups already reach.
--
-- The engine fixture is the SF-73 entry bench's (SF-73-target_entry_point_test.lua,
-- lines 30-458, copied verbatim): native Sprayer and FillUnit from the decompiled
-- scripts, WorkArea's per-tick order, the fruit plane, the farmland map and access.
-- The language files are the shipped translations, read as text.
--
-- Groups:
--   E  host: Tyson's case, the line, the hint, one notice, the layout; denied access
--   C  client: the real stream, the line, one notice, expiry, waiting, a failure
--   P  priming and the pending hold
--   R  the confirmed outcome and its detail rows, kept through holds, the final
--      result, a new epoch
--   F  a post-spend failure on the host
--   T  every reason its own text, the four shortfalls apart
--   M  the manual hint only for no growing crop alone
--   L  the lock: nothing new on the host, after relocking, or on a client
--   N  the notice: the setting, once per reason in an activation, never per cycle
--   W  a row too wide is drawn smaller
--   X  every key in all 27 languages, translated, specifiers kept, no dashes
--
-- What this bar does NOT prove: the look of the panel on screen, fonts and real text
-- widths, controller and viewport behaviour, and real dedicated-server delivery. The
-- TESTING row names those observations.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/network/NetworkEvents.lua, src/ui/SoilHUD.lua
--!text: translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml

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

local function W1A_BENCH()
local GROUP_N = 0
local function group(fn)
  GROUP_N = GROUP_N + 1
  local ok, err = pcall(fn)
  if not ok then T.ok("group " .. GROUP_N .. " ran to its end without a Lua error", false, tostring(err)) end
end

-- =====================================================================
-- W1a: the language files, the HUD and the client
-- =====================================================================
local LANGS = { "br", "cs", "ct", "cz", "da", "de", "ea", "en", "es", "fc", "fi", "fr", "hu", "id", "it", "jp",
                "kr", "nl", "no", "pl", "pt", "ro", "ru", "sv", "tr", "uk", "vi" }
local function unescape(v)
  return (v:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end
local LANG = {}
for _, l in ipairs(LANGS) do
  local text = SOURCE_TEXT["translations/translation_" .. l .. ".xml"] or ""
  local m = {}
  for k, v, h in text:gmatch('<e k="([^"]+)" v="([^"]*)" eh="([^"]*)"') do m[k] = { v = unescape(v), eh = h } end
  LANG[l] = m
end
local EN = {}
for k, e in pairs(LANG.en) do EN[k] = e.v end
-- the engine's I18N: the loaded language file's text, and its Missing sentence for an
-- absent key (I18N.lua:186), so a key the file lacks shows up as such
g_i18n = { texts = {}, hasText = function(_, k) return EN[k] ~= nil end,
           getText = function(_, k) return EN[k] or ("Missing '" .. tostring(k) .. "'") end }

-- The fixture's crops carry their fill type titles, as the engine's fruit types do.
DESCS[1].fillType = { title = "Wheat" }
DESCS[2].fillType = { title = "Barley" }
-- Tyson's product: liquid DAP, one of Soil's custom N/P/K products.
DECL.LIQUID_DAP = 0.0013
local DAP = indexOf("LIQUID_DAP")
local CUT_BARLEY = function() return 2, 9 end     -- the fixture's cut state (getIsCut: s == 9)

-- Every key the block reads, collected from the real module's own tables.
local function hudKeys()
  local keys, seen = {}, {}
  local function add(k) if type(k) == "string" and not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  for _, c in pairs(SoilHUD.TARGET_REASON_COPY) do add(c.line); add(c.note) end
  for _, c in pairs(SoilHUD.TARGET_STATE_COPY) do add(c.line); add(c.note) end
  for _, c in pairs(SoilHUD.TARGET_VIEW_COPY) do add(c.line); add(c.note) end
  for _, k in pairs(SoilHUD.TARGET_REL_COPY) do add(k) end
  for _, k in pairs(SoilHUD.TARGET_KEYS) do add(k) end
  add(SoilHUD.TARGET_MANUAL_HINT)
  table.sort(keys)
  return keys
end

-- ── the HUD, its frame and its draw ─────────────────────────────────────────
local function hudFor(vehicle, settings, ss)
  g_localPlayer = { getIsInVehicle = function() return true end, getCurrentVehicle = function() return vehicle end }
  local hud = SoilHUD.new(ss, settings)
  hud.lastHudPosition = settings.hudPosition
  hud._heightDirty = false
  return hud
end
--- One frame of the HUD's own update(). Layout and the field-detect timer are set
--- aside (not under test) so update() reaches its sprayer cache.
local function frame(hud)
  hud.fieldDetectTimer = 0
  hud._heightDirty = false
  hud:update(16)
end
local function draw(hud, widthOf)
  local texts = {}
  local saved = { renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth }
  renderText = function(x, y, size, t) texts[#texts + 1] = { x = x, y = y, size = size, text = t } end
  setTextAlignment = function() end
  setTextColor = function() end
  setTextBold = function() end
  getTextWidth = widthOf or function(size, t) return size * 0.3 * #t end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  local ok, err = pcall(hud.drawSprayerRatePanel, hud)
  renderText, setTextAlignment, setTextColor, setTextBold, getTextWidth = saved[1], saved[2], saved[3], saved[4], saved[5]
  return { ok = ok, err = err, texts = texts, rect = hud.appRateDrawRect, view = hud._cachedTargetView }
end
local function find(d, s) for _, t in ipairs(d.texts) do if t.text == s then return t end end return nil end
local function has(d, s) return find(d, s) ~= nil end
local function hasPrefix(d, p)
  for _, t in ipairs(d.texts) do if type(t.text) == "string" and t.text:sub(1, #p) == p then return true end end
  return false
end
local function count(d, s) local n = 0 for _, t in ipairs(d.texts) do if t.text == s then n = n + 1 end end return n end
--- Any text the block could draw: a key's English text, or a detail row's shape.
local function blockText(d)
  local exact, pats = {}, {}
  for _, k in ipairs(hudKeys()) do
    local v = EN[k]
    -- the notice's join ("%s. %s") has no words and is never drawn in the panel: as a
    -- pattern it would match any sentence, so it is left out
    if v ~= nil and v:gsub("%%s", ""):find("%a") then
      if v:find("%%") then
        pats[#pats + 1] = "^" .. v:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", ".-") .. "$"
      else
        exact[v] = k
      end
    end
  end
  for _, t in ipairs(d.texts) do
    if exact[t.text] then return t.text end
    for _, p in ipairs(pats) do if type(t.text) == "string" and t.text:find(p) then return t.text end end
  end
  return nil
end
local function litres(x) return string.format(math.abs(x) < 10 and "%.2f" or "%.1f", x) end
local function f1(x) return string.format("%.1f", x) end

-- ── the worlds: the server or host, and a client ────────────────────────────
local NET_ID = 77
NetworkUtil = NetworkUtil or {}
local function serverWorld(opts)
  opts = opts or {}
  newWorld(opts)
  W.settings.hudPosition = 1
  W.settings.showNotifications = opts.notices ~= false
  if opts.ground then GROUND.fruitAt = opts.ground end
  -- the engine sends each event as it is broadcast: the stream is written there
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
  W.hud = hudFor(W.v, W.settings, W.ss)
  return W
end

local CLIENT_CONN = { getIsServer = function() return true end }   -- the client's connection to its server
local CW
local function clientWorld(opts)
  opts = opts or {}
  g_server = nil
  local settings = { enabled = true, autoRateControl = true, showNotifications = true, hudPosition = 1 }
  settings.allowsExperimentalSystems = function() return opts.gate ~= false end
  local notices = {}
  g_currentMission = { time = opts.time or 50000, missionDynamicInfo = { isMultiplayer = true },
                       hud = { showBlinkingWarning = function(_, text) notices[#notices + 1] = text end } }
  local ss = setmetatable({ fieldData = {}, settings = settings, isInitialized = true }, { __index = SoilFertilitySystem })
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  local cv = newSprayer({ product = opts.product or DAP })
  cv.isServer = false
  NetworkUtil.getObject = function(id) if id == NET_ID then return cv end return nil end
  -- AUTO is the vehicle's synced mode (SoilSprayerAutoModeEvent); the player turned it on
  if opts.auto ~= false then rm:setAutoMode(cv.id, true) end
  CW = { ss = ss, rm = rm, v = cv, settings = settings, notices = notices }
  CW.hud = hudFor(cv, settings, ss)
  return CW
end
--- The engine's delivery: the server wrote the stream as it sent the event; the client
--- reads it into a fresh instance, whose readStream runs it (Client.lua:418).
local function deliver(sentStream)
  local dst = SoilApplicationTargetResultEvent.emptyNew()
  dst:readStream(sentStream, CLIENT_CONN)
  return dst, _sfStreamFaults(sentStream), sentStream.r == #sentStream.q + 1
end

-- =====================================================================
-- E. THE ENTRY-POINT BAR, host: Tyson's case (BOB-CHECK-DAP-FIELD2-REFUSAL). Liquid
--    DAP with AUTO on over a cut crop. The mod's own installers in installAll's order,
--    WorkArea's tick through the real usage hook into TA's refusal, setResult and
--    publish; then the HUD's own update() and drawSprayerRatePanel. Nothing in the
--    block is handed a result: it reads the soil system as production does.
-- =====================================================================
group(function()
  serverWorld({ product = DAP, ground = CUT_BARLEY })
  autoOn(W.v)
  local level0 = tank(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("E0 the install sequence ran end to end (" .. table.concat(W.installFailed, " | ") .. ")", #W.installFailed, 0)
  T.eq("E1 [reached] the real hooks refused the cycle over the cut crop: UNSUPPORTED_CROP",
       r and table.concat(r.reasons, ","), "UNSUPPORTED_CROP")
  T.eq("E2 and spent nothing", tank(W.v), level0)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("E3 the rate panel drew (" .. tostring(d.err) .. ")", d.ok)
  T.ok("E4 NAMED: the state line is Iris's floor, 'AUTO paused: no growing crop'", has(d, "AUTO paused: no growing crop"))
  T.ok("E5 NAMED: with her manual hint, 'Turn AUTO off for manual application.'",
       has(d, "Turn AUTO off for manual application."))
  T.eq("E6 the legacy 'Target:' line is not drawn under target mode", hasPrefix(d, EN.sf_sprayer_target), false)
  T.eq("E7 NAMED: one notice, Iris's sentence, through the soil system's notification helper",
       table.concat(NATIVE.notices, " | "), "Target fertilizer: AUTO paused: no growing crop. Turn AUTO off for manual application.")
  for _ = 1, 30 do run(W.v, 1); frame(W.hud) end
  T.eq("E8 NAMED: thirty more refused cycles and frames, still one notice (never per cycle)", #NATIVE.notices, 1)
  -- the block sits inside the panel, under the header and above the rate row
  local header = find(d, EN.sf_sprayer_auto_on)
  local inside, below, above = true, true, true
  local rateRow = nil
  for _, t in ipairs(d.texts) do if t.text == W.hud:formatRate(SoilConstants.SPRAYER_RATE.STEPS[SoilConstants.SPRAYER_RATE.DEFAULT_INDEX] or 1, W.hud:getRateConfig(W.hud._cachedFillType)) then rateRow = t end end
  for _, row in ipairs(d.view and d.view.rows or {}) do
    local t = find(d, row.text)
    if t == nil or t.y < d.rect.y or t.y > d.rect.y + d.rect.h then inside = false end
    if t ~= nil and header ~= nil and t.y >= header.y then below = false end
    if t ~= nil and rateRow ~= nil and t.y <= rateRow.y then above = false end
  end
  T.ok("E9 [reached] the header and the rate row were drawn", header ~= nil and rateRow ~= nil)
  T.ok("E10 every block row is drawn inside the panel's rectangle (the panel grew by them)", inside and #(d.view and d.view.rows or {}) == 2)
  T.ok("E11 and between the header and the rate row (a height change, no overlap)", below and above)
end)
group(function()
  -- the boom reaching another farm's land: denied access is never pointed at manual
  serverWorld({ x0 = 16 })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  local reasons = r and table.concat(r.reasons, ",") or "?"
  T.ok("E12 [reached] the real witness refused with FARM_ACCESS among its reasons (" .. reasons .. ")",
       reasons:find("FARM_ACCESS", 1, true) ~= nil)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("E13 NAMED: the line names denied access, 'AUTO paused: no access to this land'", has(d, "AUTO paused: no access to this land"))
  T.eq("E14 NAMED: and never the manual hint", has(d, "Turn AUTO off for manual application."), false)
  T.eq("E15 its one notice carries no manual hint either", table.concat(NATIVE.notices, " | "),
       "Target fertilizer: AUTO paused: no access to this land")
end)

-- =====================================================================
-- C. THE ENTRY-POINT BAR, client: the server's real publish, the event's real stream,
--    TA:receive, then the client's HUD (a dedicated server's player)
-- =====================================================================
group(function()
  serverWorld({ product = DAP, ground = CUT_BARLEY, mp = true })
  autoOn(W.v)
  run(W.v, 1)
  local sent = W.sent[#W.sent]
  T.ok("C1 [reached] the server's real publish sent the refused result", sent ~= nil and sent.result == "INACTIVE")
  local serverTime = g_currentMission.time
  clientWorld({ product = DAP, time = serverTime })
  local dst, faults, whole = deliver(sent.stream)
  T.eq("C2 the event read back through its real stream with no fault, every field consumed",
       tostring(faults) .. "/" .. tostring(whole) .. "/" .. tostring(dst.refused), "0/true/nil")
  local cr = CW.ss:getApplicationTargetResult(CW.v)
  T.eq("C3 [reached] the client's TargetApplication holds it", cr and table.concat(cr.reasons, ","), "UNSUPPORTED_CROP")
  frame(CW.hud)
  local d = draw(CW.hud)
  T.ok("C4 NAMED: the client draws Iris's line and hint", has(d, "AUTO paused: no growing crop")
       and has(d, "Turn AUTO off for manual application."))
  T.eq("C5 NAMED: the client hears it once, from the received result's change",
       table.concat(CW.notices, " | "), "Target fertilizer: AUTO paused: no growing crop. Turn AUTO off for manual application.")
  for _ = 1, 10 do frame(CW.hud) end
  T.eq("C6 ten more frames: still one notice", #CW.notices, 1)
  g_currentMission.time = g_currentMission.time + TargetApplication.RESULT_EXPIRY_MS
  frame(CW.hud)
  d = draw(CW.hud)
  T.ok("C7 NAMED: an active result past two display intervals is unavailable, never the stale line",
       has(d, "AUTO: target unavailable") and has(d, "No current result from the server.")
       and not has(d, "AUTO paused: no growing crop"))
end)
group(function()
  clientWorld({ product = DAP })
  frame(CW.hud)
  local d = draw(CW.hud)
  T.ok("C8 NAMED: a client with no snapshot waits for the server", has(d, "AUTO: waiting for the server"))
  T.eq("C9 and predicts nothing (no legacy target line, no notice)",
       tostring(hasPrefix(d, EN.sf_sprayer_target)) .. "/" .. #CW.notices, "false/0")
end)
group(function()
  -- a post-spend failure reaches a client: product spent, local N/P/K not confirmed
  serverWorld({ mp = true })
  autoOn(W.v)
  run(W.v, 1)
  W.v._accessDenied = true
  local failed = nil
  for _ = 1, 20 do
    run(W.v, 1)
    local r = W.ss:getApplicationTargetResult(W.v)
    if r and r.doseState == "APPLICATION_FAILED" then failed = r break end
  end
  local sent = nil
  for _, s in ipairs(W.sent) do if s.result == "APPLICATION_FAILED" then sent = s end end
  T.ok("C10 [reached] the server's real drain failed and published APPLICATION_FAILED", failed ~= nil and sent ~= nil)
  clientWorld({ time = g_currentMission.time })
  deliver(sent.stream)
  frame(CW.hud)
  local d = draw(CW.hud)
  T.ok("C11 NAMED: the client says product was spent and local N/P/K is not confirmed",
       has(d, "AUTO stopped: product spent") and has(d, "Local N/P/K is not confirmed."))
  T.eq("C12 NAMED: and hears it once, in the existing failure notice with the field",
       table.concat(CW.notices, " | "), "Target fertilizer: " .. string.format(EN.sf_target_failed_body, 7))
end)

-- =====================================================================
-- P, R. Priming, the pending hold, the confirmed outcome, the final result, a new epoch
-- (UREA over wheat, own tank: the dose the entry bench's E1 closes)
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  frame(W.hud)
  local d = draw(W.hud)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("P1 [reached] the first line primes", r and r.reasons[1], "FOOTPRINT_PRIMING")
  T.ok("P2 NAMED: 'AUTO: preparing the footprint', 'First boom line, nothing charged.' (not a paid pass)",
       has(d, "AUTO: preparing the footprint") and has(d, "First boom line, nothing charged."))
  T.eq("P3 priming is not a refusal: no notice", #NATIVE.notices, 0)
  run(W.v, 1)
  r = W.ss:getApplicationTargetResult(W.v)
  frame(W.hud)
  d = draw(W.hud)
  T.ok("P4 [reached] the next cycle holds: INACTIVE, no reason, on field 7",
       r ~= nil and r.doseState == "INACTIVE" and #r.reasons == 0 and r.fieldId == 7)
  T.ok("P5 NAMED: with nothing confirmed yet, 'AUTO: dose pending', charged at the closure",
       has(d, "AUTO: dose pending") and has(d, "Charged when the boom closes a soil cell."))

  local dose = runToDose(W.v, 20)
  frame(W.hud)
  d = draw(W.hud)
  T.eq("R1 [reached] the real dose closed REACHED", dose and dose.doseState, "REACHED")
  T.ok("R2 NAMED: 'AUTO: target reached' for this footprint, not the field",
       has(d, "AUTO: target reached") and has(d, "Confirmed for this footprint, not the whole field."))
  T.ok("R3 the pass row: product on crop, field", has(d, "UREA on Wheat, field 7"))
  T.ok("R4 the footprint row carries the carrier grain", has(d, string.format(EN.sf_tgt_d_footprint, f1(dose.grainMetres))))
  local nOk, relOk = 0, true
  for _, n in ipairs({ "N", "P", "K" }) do
    local x = dose.nutrients[n]
    local ppm = SoilConstants.PPM_DISPLAY[n]
    local want = string.format(EN.sf_tgt_d_nutrient, n, f1(x.after * ppm), f1(x.lower * ppm), f1(x.upper * ppm),
      EN[SoilHUD.TARGET_REL_COPY[x.relationship]])
    if has(d, want) then nOk = nOk + 1 end
    if x.relationship ~= "IDEAL" then relOk = false end
  end
  T.eq("R5 one row per nutrient: the after-write value, its crop window and the relationship", nOk, 3)
  T.ok("R6 [reached] the three relationships are the result's own (IDEAL here)", relOk)
  T.ok("R7 the limiting nutrient", has(d, "Limiting nutrient: N"))
  T.ok("R8 NAMED: planned against physically applied litres, the result's own",
       has(d, string.format(EN.sf_tgt_d_litres, litres(dose.plannedLitres), litres(dose.physicalLitres))))
  T.ok("R9 useful litres shown because the result knows them", dose.agronomicLitres ~= nil
       and has(d, string.format(EN.sf_tgt_d_useful, litres(dose.agronomicLitres))))
  T.eq("R10 the legacy 'Target:' line is gone", hasPrefix(d, EN.sf_sprayer_target), false)

  run(W.v, 1)
  r = W.ss:getApplicationTargetResult(W.v)
  frame(W.hud)
  d = draw(W.hud)
  T.ok("R11 [reached] the next cycle is a hold again", r ~= nil and r.doseState == "INACTIVE" and #r.reasons == 0 and r.fieldId ~= nil)
  T.ok("R12 NAMED: the hold confirms nothing new, so the block keeps the confirmed outcome",
       has(d, "AUTO: target reached") and has(d, string.format(EN.sf_tgt_d_litres, litres(dose.plannedLitres), litres(dose.physicalLitres)))
       and not has(d, "AUTO: dose pending"))

  W.rm:setAutoMode(W.v.id, false)
  run(W.v, 1)
  r = W.ss:getApplicationTargetResult(W.v)
  frame(W.hud)
  d = draw(W.hud)
  T.eq("R13 [reached] AUTO off: the result is the inactive final one", r and r.active, false)
  T.ok("R14 NAMED: the final result stays inspectable as the last AUTO pass",
       has(d, "Last AUTO pass") and has(d, "AUTO: target reached"))

  autoOn(W.v)
  run(W.v, 1)
  r = W.ss:getApplicationTargetResult(W.v)
  frame(W.hud)
  d = draw(W.hud)
  T.eq("R15 [reached] AUTO on again: a new epoch primes", r and r.reasons[1], "FOOTPRINT_PRIMING")
  local stale = SoilHUD.targetViewForResult({ epoch = "2", active = true, doseState = "INACTIVE", reasons = {}, fieldId = 7 },
                                            { epoch = "1", active = true, doseState = "REACHED", reasons = {} })
  T.eq("R17 a hold never shows another epoch's outcome", stale.kind, "pending")
  T.ok("R16 NAMED: the new epoch replaces the old result (no last pass, no old outcome)",
       has(d, "AUTO: preparing the footprint") and not has(d, "Last AUTO pass") and not has(d, "AUTO: target reached"))
end)

group(function()
  serverWorld({})
  autoOn(W.v)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("P0 NAMED: AUTO on, no pass yet: 'AUTO: target dose starts when spraying', never the legacy line",
       has(d, "AUTO: target dose starts when spraying") and not hasPrefix(d, EN.sf_sprayer_target))
  run(W.v, 2)                        -- prime, then the first hold
  W.rm:setAutoMode(W.v.id, false)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  frame(W.hud)
  d = draw(W.hud)
  T.ok("P6 [reached] AUTO off in the first hold: the final result is that hold",
       r ~= nil and r.active == false and r.doseState == "INACTIVE" and #r.reasons == 0 and r.fieldId ~= nil)
  T.ok("P7 NAMED: an uncharged final hold confirms nothing: last pass, target unavailable, never 'dose pending'",
       has(d, "Last AUTO pass") and has(d, "AUTO: target unavailable") and not has(d, "AUTO: dose pending"))
end)
group(function()
  serverWorld({})
  autoOn(W.v)
  W.v.turnedOn = false
  run(W.v, 2)
  local r = W.ss:getApplicationTargetResult(W.v)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("P8 [reached] switched off with AUTO on: INACTIVE, no reason, no field",
       r ~= nil and r.doseState == "INACTIVE" and #r.reasons == 0 and r.fieldId == nil)
  T.ok("P9 NAMED: 'AUTO: not spraying', never 'dose pending'", has(d, "AUTO: not spraying") and not has(d, "AUTO: dose pending"))
end)
group(function()
  -- a product without N/P/K is not a target product: today's panel, on both peers
  serverWorld({ product = HERB })
  autoOn(W.v)
  run(W.v, 2)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("P10 [reached] AUTO on with herbicide: target mode on, no target result", W.ss:isTargetModeForDisplay(W.v)
       and W.ss:getApplicationTargetResult(W.v) == nil)
  T.eq("P11 NAMED: the host draws no block for it", blockText(d), nil)
  clientWorld({ product = HERB })
  frame(CW.hud)
  d = draw(CW.hud)
  T.eq("P12 NAMED: nor does a client wait for one", blockText(d), nil)
end)
group(function()
  -- a product with a profile but no N/P/K (gypsum: pH and organic matter only)
  DECL.GYPSUM = 0.001
  local GYP = indexOf("GYPSUM")
  serverWorld({ product = GYP })
  autoOn(W.v)
  run(W.v, 2)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("P13 [reached] gypsum has a fertilizer profile and no target result", SoilConstants.FERTILIZER_PROFILES.GYPSUM ~= nil
       and W.ss:isTargetModeForDisplay(W.v) and W.ss:getApplicationTargetResult(W.v) == nil)
  T.eq("P14 NAMED: a profile without N/P/K gets no block on the host", blockText(d), nil)
  clientWorld({ product = GYP })
  frame(CW.hud)
  d = draw(CW.hud)
  T.eq("P15 NAMED: nor a waiting line on a client", blockText(d), nil)
end)

-- =====================================================================
-- F. A post-spend failure on the host: product spent, local N/P/K not confirmed
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  frame(W.hud)
  W.v._accessDenied = true
  local r = nil
  for _ = 1, 20 do
    run(W.v, 1)
    frame(W.hud)
    r = W.ss:getApplicationTargetResult(W.v)
    if r and r.doseState == "APPLICATION_FAILED" then break end
  end
  for _ = 1, 5 do frame(W.hud) end
  local d = draw(W.hud)
  T.eq("F1 [reached] the real drain came back short: APPLICATION_FAILED", r and r.doseState, "APPLICATION_FAILED")
  T.ok("F2 NAMED: 'AUTO stopped: product spent', 'Local N/P/K is not confirmed.'",
       has(d, "AUTO stopped: product spent") and has(d, "Local N/P/K is not confirmed."))
  T.eq("F3 NAMED: never REACHED", has(d, "AUTO: target reached"), false)
  local nutrientRow = false
  for _, t in ipairs(d.texts) do
    if type(t.text) == "string" and t.text:find("^[NPK] .*, window ") then nutrientRow = true end
  end
  T.eq("F4 no N/P/K reading is shown as if confirmed", nutrientRow, false)
  T.ok("F5 the physical litres are the drain's (zero applied), and no useful litres are invented",
       has(d, string.format(EN.sf_tgt_d_litres, litres(r.plannedLitres or 0), litres(0)))
       and not hasPrefix(d, "Useful "))
  T.eq("F6 and no repair hint: no manual suggestion", has(d, "Turn AUTO off for manual application."), false)
  T.eq("F7 the host hears it once: TA:notifyFailure's notice, and the HUD adds none",
       #NATIVE.notices .. "/" .. tostring(NATIVE.notices[1] and NATIVE.notices[1]:find(EN.sf_target_failed_title, 1, true) == 1),
       "1/true")
  T.ok("F8 target automatic stopped, so it is the last AUTO pass", has(d, "Last AUTO pass"))
end)

-- =====================================================================
-- T. Every reason has its own text (table-driven: a reason falling to a generic line fails)
-- =====================================================================
local EXPECT = {
  UNKNOWN_PRODUCT             = { "sf_tgt_r_unknown_product" },
  UNSUPPORTED_CROP            = { "sf_tgt_r_unsupported_crop", "sf_tgt_n_manual" },
  MIXED_CROP                  = { "sf_tgt_r_mixed_crop" },
  MIXED_FIELD                 = { "sf_tgt_r_mixed_field" },
  UNKNOWN_GROUND              = { "sf_tgt_r_unavailable", "sf_tgt_n_unknown_ground" },
  OUTSIDE_MAP                 = { "sf_tgt_r_unavailable", "sf_tgt_n_outside_map" },
  FARM_ACCESS                 = { "sf_tgt_r_farm_access" },
  SOWABILITY_UNKNOWN          = { "sf_tgt_r_sowability" },
  NOZZLE_PARTIAL              = { "sf_tgt_r_nozzle_partial" },
  CELL_OVERLAP                = { "sf_tgt_r_cell_overlap" },
  CULTIVATION_NO_TARGET       = { "sf_tgt_r_cultivation" },
  SOURCE_CONTRACT_UNAVAILABLE = { "sf_tgt_r_source_contract" },
  DOUBLED_AMOUNT_ACTIVE       = { "sf_tgt_r_doubled" },
  FOOTPRINT_PRIMING           = { "sf_tgt_r_priming", "sf_tgt_n_priming" },
}
group(function()
  local seen, distinct, fallback = {}, true, false
  local fallbackLine = EN[SoilHUD.TARGET_VIEW_COPY.unavailable.line]
  for i, reason in ipairs(TargetNutrientCore.REASON_ORDER) do
    local state = (reason == "UNKNOWN_GROUND" or reason == "OUTSIDE_MAP" or reason == "UNKNOWN_PRODUCT"
                   or reason == "SOWABILITY_UNKNOWN") and "UNDETERMINED" or "INACTIVE"
    local v = SoilHUD.targetViewForResult({ epoch = "1", active = true, doseState = state, reasons = { reason } }, nil)
    local want = EXPECT[reason] or {}
    T.eq(string.format("T%d %s has its own line and note", i, reason),
         tostring(v.line) .. "/" .. tostring(v.note), tostring(want[1]) .. "/" .. tostring(want[2]))
    local rendered = tostring(EN[v.line]) .. " / " .. tostring(v.note and EN[v.note])
    if seen[rendered] then distinct = false end
    seen[rendered] = true
    if EN[v.line] == fallbackLine or EN[v.line] == nil then fallback = true end
  end
  T.eq("T15 [reached] the core names fourteen reasons", #TargetNutrientCore.REASON_ORDER, 14)
  T.ok("T16 NAMED: the fourteen rendered texts are pairwise distinct", distinct)
  T.eq("T17 NAMED: none falls to the generic unavailable line or a missing key", fallback, false)
  local notes, sameLine = {}, true
  for _, s in ipairs({ "SHORT_BINDING", "SHORT_HARDWARE", "SHORT_SUPPLY", "SHORT_QUANTIZED" }) do
    local v = SoilHUD.targetViewForResult({ epoch = "1", active = true, doseState = s, reasons = {}, binding = "P" }, nil)
    notes[#notes + 1] = EN[v.note] and string.format(EN[v.note], tostring(v.noteArg)) or "?"
    if v.line ~= "sf_tgt_state_short" then sameLine = false end
  end
  local dup = false
  for a = 1, 4 do for b = a + 1, 4 do if notes[a] == notes[b] then dup = true end end end
  T.ok("T18 NAMED: the four shortfalls share 'AUTO: short of target' and name their kind apart (" .. table.concat(notes, " | ") .. ")",
       sameLine and not dup)
  T.eq("T19 the binding shortfall names the nutrient it would overshoot", notes[1], "More of this blend would overshoot P.")
  local v = SoilHUD.targetViewForResult({ epoch = "1", active = true, doseState = "APPLICATION_FAILED", reasons = {} }, nil)
  T.eq("T20 APPLICATION_FAILED is its own line, never REACHED", tostring(v.line) .. "/" .. tostring(v.note),
       "sf_tgt_state_failed/sf_tgt_n_failed")
end)

-- =====================================================================
-- M. The manual hint: only when no growing crop is the cycle's one reason
-- =====================================================================
group(function()
  local function view(reasons, state, active)
    return SoilHUD.targetViewForResult({ epoch = "1", active = active ~= false, doseState = state or "INACTIVE", reasons = reasons }, nil)
  end
  T.eq("M1 no growing crop alone: the hint", view({ "UNSUPPORTED_CROP" }).note, "sf_tgt_n_manual")
  local v = view({ "UNSUPPORTED_CROP", "FARM_ACCESS" })
  T.eq("M2 NAMED: no growing crop on land the farm cannot work: denied access, no hint",
       tostring(v.line) .. "/" .. tostring(v.note), "sf_tgt_r_farm_access/nil")
  v = view({ "UNSUPPORTED_CROP", "MIXED_CROP" })
  T.eq("M3 a crop boundary: the boundary, no hint", tostring(v.line) .. "/" .. tostring(v.note), "sf_tgt_r_mixed_crop/nil")
  v = view({ "UNKNOWN_PRODUCT", "UNSUPPORTED_CROP" }, "UNDETERMINED")
  T.eq("M4 NAMED: an invalid product: no hint", tostring(v.line) .. "/" .. tostring(v.note), "sf_tgt_r_unknown_product/nil")
  T.eq("M5 the final result of a refused pass: no hint once AUTO is off", view({ "UNSUPPORTED_CROP" }, nil, false).note, nil)
  local hintOnly = true
  for _, reason in ipairs(TargetNutrientCore.REASON_ORDER) do
    if reason ~= "UNSUPPORTED_CROP" and view({ reason }).note == SoilHUD.TARGET_MANUAL_HINT then hintOnly = false end
  end
  for s in pairs(SoilHUD.TARGET_STATE_COPY) do
    if SoilHUD.TARGET_STATE_COPY[s].note == SoilHUD.TARGET_MANUAL_HINT then hintOnly = false end
  end
  T.ok("M6 NAMED: no other reason and no outcome carries the hint", hintOnly)
  v = view({ "UNSUPPORTED_CROP", "CELL_OVERLAP" })
  T.eq("M7 no growing crop beside another reason: its line, no hint (the hint needs it alone)",
       tostring(v.line) .. "/" .. tostring(v.note), "sf_tgt_r_unsupported_crop/nil")
end)

-- =====================================================================
-- L. THE LOCK: locked, the panel is today's and nothing new is drawn
-- =====================================================================
group(function()
  serverWorld({ gate = false })
  autoOn(W.v)
  run(W.v, 3)
  frame(W.hud)
  local d = draw(W.hud)
  T.eq("L1 [reached] locked: AUTO on opens no target state", W.ss.targetApplication.states[W.v], nil)
  T.ok("L2 NAMED: the panel draws today's legacy 'Target:' line", hasPrefix(d, EN.sf_sprayer_target))
  T.eq("L3 NAMED: and no text of the block, in any form", blockText(d), nil)
  T.eq("L4 and no notice", #NATIVE.notices, 0)
end)
group(function()
  -- a refused result exists, then the lock closes again: the old result is not shown
  serverWorld({ product = DAP, ground = CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  frame(W.hud)
  W.settings.allowsExperimentalSystems = function() return false end
  run(W.v, 1)
  frame(W.hud)
  local d = draw(W.hud)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("L5 [reached] the host still holds the final refused result", r ~= nil and r.active == false)
  T.eq("L6 NAMED: relocked, the block draws nothing of it", blockText(d), nil)
  T.ok("L7 and the legacy line is back", hasPrefix(d, EN.sf_sprayer_target))
end)
group(function()
  clientWorld({ gate = false })
  frame(CW.hud)
  local d = draw(CW.hud)
  T.ok("L8 NAMED: a locked client draws today's panel, never 'waiting'", hasPrefix(d, EN.sf_sprayer_target) and blockText(d) == nil)
end)

-- =====================================================================
-- N. The notice: once per reason in an activation, never per cycle; the setting holds
-- =====================================================================
group(function()
  serverWorld({ product = DAP, ground = CUT_BARLEY, notices = false })
  autoOn(W.v)
  run(W.v, 3)
  frame(W.hud)
  local d = draw(W.hud)
  T.ok("N1 NAMED: notifications off: the line still draws and no notice is shown",
       has(d, "AUTO paused: no growing crop") and #NATIVE.notices == 0)
end)
group(function()
  -- the HUD's own memory across a scripted sequence of results for one vehicle
  local shown = {}
  local CUR
  local ss = { isTargetGateOpen = function() return true end,
               getApplicationTargetResult = function() return CUR end,
               showNotification = function(_, t, b) shown[#shown + 1] = b end }
  g_server = {}
  local hud = SoilHUD.new(ss, { autoRateControl = true })
  local v = { id = 5 }
  local function step(r) CUR = r; hud:buildTargetView(v, ss, nil, 5, nil) end
  local function res(epoch, reasons, active) return { epoch = epoch, active = active ~= false, doseState = "INACTIVE", reasons = reasons } end
  step(res("1", { "UNSUPPORTED_CROP" }))
  for _ = 1, 5 do step(res("1", { "UNSUPPORTED_CROP" })) end
  T.eq("N2 a refusal held over six frames: one notice", #shown, 1)
  step(res("1", { "FOOTPRINT_PRIMING" }))
  step(res("1", { "UNSUPPORTED_CROP" }))
  T.eq("N3 NAMED: back into the same refusal in the same activation: no second notice", #shown, 1)
  step(res("1", { "MIXED_CROP" }))
  T.eq("N4 a different reason: its own notice", #shown, 2)
  step(res("2", { "UNSUPPORTED_CROP" }))
  T.eq("N5 a new activation (epoch): the refusal is news again", #shown, 3)
  step(res("3", { "MIXED_FIELD" }, false))
  T.eq("N6 a final (inactive) result never notifies", #shown, 3)
  v.isDeleted = true
  CUR = nil
  hud:buildTargetView(nil, ss, nil, 0, nil)
  T.eq("N7 a deleted vehicle's memory is dropped", hud._targetMemory[v], nil)
end)

-- =====================================================================
-- W. A row too wide for the panel is drawn smaller, never past its edge
-- =====================================================================
group(function()
  serverWorld({ product = DAP, ground = CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  frame(W.hud)
  local wide = function(size, t) return size * 2.5 * #t end
  local d = draw(W.hud, wide)
  local pw = d.rect.w
  local fits, checked = true, 0
  for _, row in ipairs(d.view and d.view.rows or {}) do
    local t = find(d, row.text)
    if t ~= nil then
      checked = checked + 1
      if wide(t.size, t.text) > pw * 0.94 + 1e-9 then fits = false end
    end
  end
  T.ok("W1 every block row fits the panel's width (" .. checked .. " rows)", fits and checked == 2)
end)

-- =====================================================================
-- X. Every key the block reads ships in all 27 Soil languages, translated
-- =====================================================================
group(function()
  local keys = hudKeys()
  T.eq("X0 the block reads 46 keys (from the module's own tables)", #keys, 46)
  for _, l in ipairs(LANGS) do
    local missing = {}
    for _, k in ipairs(keys) do if LANG[l][k] == nil then missing[#missing + 1] = k end end
    for _, k in ipairs({ "sf_target_failed_title", "sf_target_failed_body" }) do
      if LANG[l][k] == nil then missing[#missing + 1] = k end
    end
    T.eq("X " .. l .. ": every key present", table.concat(missing, ","), "")
  end
  local copies, formats, dashes, hashes = {}, {}, {}, {}
  local function specs(s) local out = {} for f in s:gmatch("%%[-+ #0-9.]*[sdif]") do out[#out + 1] = f end return table.concat(out, ",") end
  for _, l in ipairs(LANGS) do
    for _, k in ipairs(keys) do
      local e, x = LANG.en[k], LANG[l][k]
      if e ~= nil and x ~= nil then
        if l ~= "en" and x.v == e.v and k ~= "sf_tgt_notify" then copies[#copies + 1] = l .. ":" .. k end
        if specs(x.v) ~= specs(e.v) then formats[#formats + 1] = l .. ":" .. k end
        if x.v:find("\226\128\148", 1, true) or x.v:find("\226\128\147", 1, true) or x.v:find("\226\128\156", 1, true)
           or x.v:find("\226\128\157", 1, true) or x.v:find("\226\128\152", 1, true) or x.v:find("\226\128\153", 1, true) then
          dashes[#dashes + 1] = l .. ":" .. k
        end
        if x.eh ~= e.eh then hashes[#hashes + 1] = l .. ":" .. k end
      end
    end
  end
  T.eq("X28 NAMED: no translation is the English text (the join format excepted)", table.concat(copies, ","), "")
  T.eq("X29 every translation keeps the English format specifiers in order", table.concat(formats, ","), "")
  T.eq("X30 no em dash, en dash or smart quote", table.concat(dashes, ","), "")
  T.eq("X31 every entry carries the English text's hash", table.concat(hashes, ","), "")
end)

end
W1A_BENCH()
