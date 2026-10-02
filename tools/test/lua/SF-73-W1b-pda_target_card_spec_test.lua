-- SF-73-W1b-pda_target_card_spec_test.lua
--
-- SF-73 section 7, W1b: the PDA's TREATMENT card shows the door's soilTargetCard (the W1
-- door set, placement B) for the selected field, built on Bob's W1 intake and his W1b
-- pre-build ruling (BOB-RULING-W1B-PREBUILD-2026-10-02): the AUTO crop window as a field
-- report, the field's last confirmed target pass for its current crop as one footprint's
-- result, the legacy target lines kept and their heading read as the manual plan's targets
-- while the card shows, nothing new when locked or when the winning door lacks the card.
--
-- THE ENTRY-POINT BAR is groups E (host) and C (client). E: a dose closed on field 7 by the
-- real install, the real hooks and the real TargetApplication:setResult, then held cycles
-- (which overwrite the vehicle's own result), then the PDA opened the way the page opens it:
-- the real RfPdaSoilPanel.rebuildFieldData over the real soil system, then the real
-- refreshTreatmentPlan. C: the stream the server's real publish wrote, read into the real
-- SoilApplicationTargetResultEvent on a client, through TargetApplication:receive, then the
-- client's PDA. No group hands the card a result.
--
-- The engine fixture is the SF-73 entry bench's (SF-73-target_entry_point_test.lua, lines
-- 30-458, verbatim), plus FieldState:update's fruit-plane part (FieldState.lua:86-101) on
-- the fixture's own fruit plane. The page fixture holds the widgets the panel paints and
-- records what it painted; its translator reads the shipped en file.
--
-- Groups:
--   L  locked: the card hidden, today's heading, no card text
--   E  host: the field's last pass survives the holds; the window is the FIELD_REPORT; the
--      heading reads as the manual plan's targets; the legacy lines are today's
--   C  client: nothing before the first result; the received REACHED after it
--   F  a post-spend failure
--   R  another crop's pass is not shown
--   D  a door without the card: nothing new
--   K  relocked with a remembered pass; a reload clears it
--   P  one source with W1a (identity), the published reason read, state parity
--   M  the memory: outcomes only, never saved
--   X  every key in all 27 languages, translated
--
-- What this bar does NOT prove: the card on screen (fonts, the 180px width, the clip),
-- dedicated-server delivery, or a door race between installed mods. The TESTING row names
-- those observations.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/FieldSentry.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/network/NetworkEvents.lua, src/ui/SoilHUD.lua, src/ui/RfPdaSoilPanel.lua
--!text: src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml

local GROUP_N = 0
function group(fn)
  GROUP_N = GROUP_N + 1
  local ok, err = pcall(fn)
  if not ok then T.ok("group " .. GROUP_N .. " ran to its end without a Lua error", false, tostring(err)) end
end
local function W1B_BENCH()
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
-- W1b: the language files, the PDA page, the worlds
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
g_i18n = { texts = {}, hasText = function(_, k) return EN[k] ~= nil end,
           getText = function(_, k) return EN[k] or ("Missing '" .. tostring(k) .. "'") end }

DESCS[1].fillType = { title = "Wheat" }
DESCS[2].fillType = { title = "Barley" }
-- FieldState.lua:86-101, the fruit-plane part: the fruit at the position, UNKNOWN when none.
FieldState = {}
FieldState.new = function()
  local s = { fruitTypeIndex = FruitType.UNKNOWN, growthState = 0 }
  function s:update(x, z)
    self.fruitTypeIndex = FruitType.UNKNOWN
    local f, st = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)
    if f ~= nil then self.fruitTypeIndex, self.growthState = f, st end
  end
  return s
end

-- ── the PDA page: the widgets the panel paints, recording what it painted ──
local function widget(name)
  local w = { name = name, text = nil, color = nil, visible = nil, writes = 0 }
  function w:setText(t) self.text = t; self.writes = self.writes + 1 end
  function w:setTextColor(r, g, b, a) self.color = { r, g, b, a } end
  function w:setVisible(v) self.visible = v end
  return w
end
local CARD_IDS = { "soilTargetCard", "soilTargetTitle", "soilTargetWindow", "soilTargetState", "soilTargetReason", "soilTargetDetail" }
--- A door page. withCard=false is a door built from a copy older than the W1 door set.
local function newPage(withCard)
  local page = { fieldData = {}, selectedFieldId = nil, ids = {} }
  page._rfTr = function(k, fb) return EN[k] or fb or k end      -- the page translator, over the en file
  for _, n in ipairs({ "treatTargetsHeading", "treatTargetN", "treatTargetP", "treatTargetK", "treatTargetPH",
                       "treatTargetsLabel", "treatSelectedLabel", "treatNextLabel", "treatPlanLines",
                       "samplingInfoBox", "samplingInfoFallback", "samplingInfoText" }) do
    page[n] = widget(n)
  end
  page.treatProdRows = {}
  for i = 1, 8 do page.treatProdRows[i] = { row = widget("row" .. i), nut = widget("nut" .. i), name = widget("name" .. i),
                                            rate = widget("rate" .. i), total = widget("total" .. i) } end
  if withCard ~= false then
    for _, id in ipairs(CARD_IDS) do page.ids[id] = widget(id) end
  end
  function page:getDescendantById(id) return self.ids[id] end
  return page
end
--- Open the PDA's Soil page on a field: the real roster, then the real TREATMENT paint.
local function openPda(page, fieldId)
  RfPdaSoilPanel.rebuildFieldData(page)
  page.selectedFieldId = fieldId
  RfPdaSoilPanel.refreshTreatmentPlan(page)
  return page
end
local function cardText(page, id) local w = page.ids[id]; return w and w.text end
local function cardVisible(page) local w = page.ids.soilTargetCard; return w and w.visible end
local function legacyLines(page)
  return table.concat({ tostring(page.treatTargetN.text), tostring(page.treatTargetP.text),
                        tostring(page.treatTargetK.text), tostring(page.treatTargetPH.text) }, "|")
end
local function litres(x) return string.format(math.abs(x) < 10 and "%.2f" or "%.1f", x) end
-- the relationship words by literal key, independent of the panel's own table
local REL_KEY = { BELOW = "sf_tgt_pda_rel_below", APPROACHING = "sf_tgt_pda_rel_near", IDEAL = "sf_tgt_pda_rel_ok",
                  ABOVE = "sf_tgt_pda_rel_high", UNDETERMINED = "sf_tgt_pda_rel_unknown" }
local function relWord(rel) return EN[REL_KEY[rel] or REL_KEY.UNDETERMINED] end
--- The window line the PDA should draw, from the soil system's own FIELD_REPORT for the field.
local function expectedWindow(fieldId)
  local rel = W.ss:getCropNutrientRelationship(fieldId)
  if rel == nil or rel.cropKey == nil then return EN.sf_tgt_pda_window_none, rel end
  return string.format(EN.sf_tgt_pda_window, relWord(rel.nutrients.N.relationship),
    relWord(rel.nutrients.P.relationship), relWord(rel.nutrients.K.relationship)), rel
end

-- ── the worlds ────────────────────────────────────────────────────────────
local NET_ID = 77
NetworkUtil = NetworkUtil or {}
local function serverWorld(opts)
  opts = opts or {}
  newWorld(opts)
  g_localPlayer = { farmId = 1 }
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
  return W
end
local CLIENT_CONN = { getIsServer = function() return true end }
local CW
--- A client of the same game: the fields as the server's sync delivers them, its own
--- target engine, nothing received yet.
local function clientWorld(opts)
  opts = opts or {}
  local serverFields = W.ss.fieldData
  g_server = nil
  local settings = { enabled = true, autoRateControl = true, showNotifications = true }
  settings.allowsExperimentalSystems = function() return opts.gate ~= false end
  g_currentMission = { time = opts.time or 50000, missionDynamicInfo = { isMultiplayer = true }, terrainSize = ENGINE.TERRAIN }
  local ss = setmetatable({ fieldData = {}, settings = settings, isInitialized = true,
                            herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {} },
                          { __index = SoilFertilitySystem })
  for id, f in pairs(serverFields) do ss.fieldData[id] = f end
  ss.valueMaps = W.ss.valueMaps
  ss.targetApplication = TargetApplication.new(ss)
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = SprayerRateManager.new() }
  g_localPlayer = { farmId = 1 }
  local cv = newSprayer({})
  cv.isServer = false
  NetworkUtil.getObject = function(id) if id == NET_ID then return cv end return nil end
  CW = { ss = ss, v = cv }
  return CW
end
local function deliver(sentStream)
  local dst = SoilApplicationTargetResultEvent.emptyNew()
  dst:readStream(sentStream, CLIENT_CONN)
  return dst, _sfStreamFaults(sentStream), sentStream.r == #sentStream.q + 1
end

-- =====================================================================
-- E. THE ENTRY-POINT BAR, host: a real dose on field 7 through the real hooks and the
--    real setResult, then the PDA opened on field 7 (rebuildFieldData, refreshTreatmentPlan)
-- =====================================================================
local LOCKED_LINES
group(function()
  serverWorld({ gate = false })
  autoOn(W.v)
  run(W.v, 3)
  local page = openPda(newPage(true), 7)
  LOCKED_LINES = legacyLines(page)
  T.ok("L1 [reached] locked: the roster holds field 7 and the legacy lines painted (" .. LOCKED_LINES .. ")",
       #page.fieldData >= 1 and page.treatTargetN.text ~= nil and page.treatTargetN.text ~= "")
  T.eq("L2 NAMED: locked, the card stays hidden", cardVisible(page), false)
  T.eq("L3 NAMED: and the heading is today's 'Target levels'", page.treatTargetsHeading.text, EN.rf_pda_treatment_targets_heading or "Target levels")
  local wrote = 0
  for _, id in ipairs(CARD_IDS) do if id ~= "soilTargetCard" and page.ids[id].writes > 0 then wrote = wrote + 1 end end
  T.eq("L4 and no card text is written", wrote, 0)
end)

local HOST_PASS
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  local dose = runToDose(W.v, 20)
  HOST_PASS = dose
  T.eq("E1 [reached] the real dose closed REACHED on wheat, field 7", dose and (dose.doseState .. "/" .. dose.cropKey .. "/" .. dose.fieldId), "REACHED/wheat/7")
  run(W.v, 3)
  local now = W.ss:getApplicationTargetResult(W.v)
  T.ok("E2 [reached] three more cycles: the vehicle's own result is a hold again (the outcome is gone from it)",
       now ~= nil and now.doseState == "INACTIVE" and #now.reasons == 0)
  local page = openPda(newPage(true), 7)
  local want, rel = expectedWindow(7)
  T.eq("E3 NAMED: the card shows", cardVisible(page), true)
  T.eq("E4 its title", cardText(page, "soilTargetTitle"), EN.sf_tgt_pda_title)
  T.ok("E5 [reached] the field report names a crop and its relationships (" .. tostring(rel and rel.cropKey) .. ")", rel ~= nil and rel.cropKey == "wheat")
  T.eq("E6 NAMED: the window is the soil system's FIELD_REPORT, labelled a field report", cardText(page, "soilTargetWindow"), want)
  T.eq("E7 NAMED: the last pass survives the holds: the field's REACHED", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_reached)
  T.eq("E8 NAMED: scoped to one footprint, never the field", cardText(page, "soilTargetReason"), EN.sf_tgt_pda_scope)
  T.eq("E9 NAMED: planned against applied litres, the result's own",
       cardText(page, "soilTargetDetail"), string.format(EN.sf_tgt_d_litres, litres(dose.plannedLitres), litres(dose.physicalLitres)))
  T.eq("E10 NAMED: while the card shows, the legacy heading reads as the manual plan's targets",
       page.treatTargetsHeading.text, EN.sf_tgt_pda_manual_targets)
  T.eq("E11 NAMED: and the legacy N, P, K and pH lines are exactly today's", legacyLines(page), LOCKED_LINES)
  local page2 = openPda(newPage(true), nil)
  T.eq("E12 no field selected: the card hides", cardVisible(page2), false)
  local copy = W.ss:getLastTargetPassForField(7)
  copy.doseState = "APPLICATION_FAILED"
  T.eq("E13 the soil read returns a copy: changing it leaves the memory alone",
       W.ss:getLastTargetPassForField(7).doseState, "REACHED")
  -- a binding shortfall noted through the real writer (the real REACHED, re-stated as SHORT_BINDING)
  local binding = W.ss:getLastTargetPassForField(7)
  binding.doseState, binding.binding = "SHORT_BINDING", "N"
  W.ss.targetApplication:noteFieldOutcome(binding)
  local page3 = openPda(newPage(true), 7)
  T.eq("E14 a blend-limited pass names its state and the nutrient it would overshoot",
       tostring(cardText(page3, "soilTargetState")) .. " / " .. tostring(cardText(page3, "soilTargetReason")),
       EN.sf_tgt_pda_state_binding .. " / " .. string.format(EN.sf_tgt_pda_binding, "N"))
end)

-- =====================================================================
-- C. THE ENTRY-POINT BAR, client: the server's real publish, the event's real stream,
--    TA:receive, the client's own memory, the client's PDA
-- =====================================================================
group(function()
  serverWorld({ mp = true })
  autoOn(W.v)
  run(W.v, 1)
  local dose = runToDose(W.v, 20)
  local sent = nil
  for _, s in ipairs(W.sent) do if s.result == "REACHED" then sent = s end end
  T.ok("C1 [reached] the server published the REACHED", dose ~= nil and dose.doseState == "REACHED" and sent ~= nil)
  local serverTime = g_currentMission.time
  clientWorld({ time = serverTime })
  local fresh = openPda(newPage(true), 7)
  T.eq("C2 NAMED: a client that has received nothing shows no last pass (its memory starts at join)",
       cardText(fresh, "soilTargetState"), EN.sf_tgt_pda_state_none)
  local _, faults, whole = deliver(sent.stream)
  T.eq("C3 the event read back whole through its real stream", tostring(faults) .. "/" .. tostring(whole), "0/true")
  local page = openPda(newPage(true), 7)
  T.eq("C4 NAMED: the client's PDA shows the received REACHED", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_reached)
  T.eq("C5 with the server's own litres", cardText(page, "soilTargetDetail"),
       string.format(EN.sf_tgt_d_litres, litres(dose.plannedLitres), litres(dose.physicalLitres)))
end)

-- =====================================================================
-- F. A post-spend failure: product spent, local N/P/K not confirmed
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  W.v._accessDenied = true
  local r
  for _ = 1, 20 do
    run(W.v, 1)
    r = W.ss:getApplicationTargetResult(W.v)
    if r and r.doseState == "APPLICATION_FAILED" then break end
  end
  T.eq("F1 [reached] the real drain failed: APPLICATION_FAILED", r and r.doseState, "APPLICATION_FAILED")
  local page = openPda(newPage(true), 7)
  T.eq("F2 NAMED: 'Last pass: product spent'", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_failed)
  T.eq("F3 NAMED: 'Local N/P/K is not confirmed.'", cardText(page, "soilTargetReason"), EN.sf_tgt_n_failed)
  T.eq("F4 applied is the drain's zero", cardText(page, "soilTargetDetail"),
       string.format(EN.sf_tgt_d_litres, litres(r.plannedLitres or 0), litres(0)))
end)

-- =====================================================================
-- R. Another crop's pass is not this crop's
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  runToDose(W.v, 20)
  GROUND.fruitAt = function() return 2, 3 end        -- the field is now barley
  local page = openPda(newPage(true), 7)
  local _, rel = expectedWindow(7)
  T.ok("R1 [reached] the field's current crop is barley now", rel ~= nil and rel.cropKey == "barley")
  T.eq("R2 NAMED: the wheat pass is not shown for the barley", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_none)
  T.eq("R3 and no litres", cardText(page, "soilTargetDetail"), "")
  GROUND.fruitAt = nil
end)

-- =====================================================================
-- D. A door without the card (an older copy won the race): nothing new
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  runToDose(W.v, 20)
  local page = openPda(newPage(false), 7)
  T.eq("D1 NAMED: no card in the door: the heading stays today's", page.treatTargetsHeading.text, EN.rf_pda_treatment_targets_heading or "Target levels")
  T.eq("D2 and the legacy lines are today's", legacyLines(page), LOCKED_LINES)
end)

-- =====================================================================
-- K. Relocked with a remembered pass: nothing new
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  runToDose(W.v, 20)
  W.settings.allowsExperimentalSystems = function() return false end
  local page = openPda(newPage(true), 7)
  T.eq("K1 NAMED: relocked, the card hides", cardVisible(page), false)
  T.eq("K2 the heading is today's", page.treatTargetsHeading.text, EN.rf_pda_treatment_targets_heading or "Target levels")
  T.eq("K3 the soil read answers nil while locked", W.ss:getLastTargetPassForField(7), nil)
  W.settings.allowsExperimentalSystems = function() return true end
  T.ok("K4 [reached] unlocked again, the memory is still there", W.ss:getLastTargetPassForField(7) ~= nil)
  W.ss.targetApplication:reset()
  T.eq("K5 a reload (reset) clears it", W.ss:getLastTargetPassForField(7), nil)
end)

-- =====================================================================
-- P. One source with W1a, and the PDA's copy parity
-- =====================================================================
group(function()
  local C = TargetNutrientCore
  T.ok("P1 NAMED: the HUD's priority, outcome, hold and reason are the core's own objects",
       SoilHUD.TARGET_REASON_PRIORITY == C.REASON_DISPLAY_ORDER and SoilHUD.isTargetOutcome == C.isOutcome
       and SoilHUD.isTargetHold == C.isHold and SoilHUD.targetPrimaryReason == C.primaryReason)
  serverWorld({})
  T.eq("P2 the published read names the display reason (denied access over no crop)",
       W.ss:getTargetPrimaryReason({ doseState = "INACTIVE", reasons = { "UNSUPPORTED_CROP", "FARM_ACCESS" } }), "FARM_ACCESS")
  W.settings.allowsExperimentalSystems = function() return false end
  T.eq("P3 and nil while locked", W.ss:getTargetPrimaryReason({ doseState = "INACTIVE", reasons = { "UNSUPPORTED_CROP" } }), nil)
  local pdaStates, hudStates, sameSet = {}, {}, true
  for s in pairs(RfPdaSoilPanel.TARGET_PDA_STATE) do pdaStates[#pdaStates + 1] = s end
  for s in pairs(SoilHUD.TARGET_STATE_COPY) do hudStates[#hudStates + 1] = s end
  table.sort(pdaStates); table.sort(hudStates)
  T.eq("P4 NAMED: the PDA has a state line for exactly the HUD's outcome states", table.concat(pdaStates, ","), table.concat(hudStates, ","))
  local seen, distinct = {}, true
  for _, s in ipairs(pdaStates) do
    local text = EN[RfPdaSoilPanel.TARGET_PDA_STATE[s].line]
    if text == nil or seen[text] then distinct = false end
    seen[text or "?"] = true
  end
  T.ok("P5 NAMED: each state has its own line (the four shortfalls name their kind)", distinct)
  local hint = false
  for _, c in pairs(RfPdaSoilPanel.TARGET_PDA_STATE) do if c.note == "sf_tgt_n_manual" or c.line == "sf_tgt_n_manual" then hint = true end end
  T.eq("P6 no PDA line carries the manual hint", hint, false)
end)

-- =====================================================================
-- M. The display memory: written for outcomes only, never saved, never read by the sim
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 2)
  T.eq("M1 priming and holds write nothing", next(W.ss.targetApplication.lastOutcomeByField), nil)
  local ta = SOURCE_TEXT["src/target/TargetApplication.lua"] or ""
  local sys = SOURCE_TEXT["src/SoilFertilitySystem.lua"] or ""
  -- every line that names the memory, by the TargetApplication function it sits in
  local where, current = {}, "(top)"
  local NL = string.char(10)
  for line in (ta .. NL):gmatch("([^" .. NL .. "]*)" .. NL) do
    local fn = line:match("^function TA[:.]([%w_]+)")
    if fn ~= nil then current = fn end
    if line:find("lastOutcomeByField", 1, true) then where[current] = true end
  end
  local names = {}
  for k in pairs(where) do names[#names + 1] = k end
  table.sort(names)
  T.eq("M2 NAMED: only new, reset and the memory's own writer and reader name it (nothing in the sim reads it)",
       table.concat(names, ","), "getLastOutcomeForField,new,noteFieldOutcome,reset")
  T.eq("M3 NAMED: the soil system never saves it", sys:find("lastOutcomeByField", 1, true), nil)
end)

-- =====================================================================
-- X. The PDA's keys in all 27 Soil languages, translated
-- =====================================================================
group(function()
  local keys, seen = {}, {}
  local function add(k) if type(k) == "string" and not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  for _, c in pairs(RfPdaSoilPanel.TARGET_PDA_STATE) do add(c.line); add(c.note) end
  for _, k in pairs(RfPdaSoilPanel.TARGET_PDA_REL) do add(k) end
  for _, k in pairs(RfPdaSoilPanel.TARGET_PDA_KEYS) do add(k) end
  table.sort(keys)
  T.eq("X0 the card reads 20 keys (18 new, 2 of W1a's)", #keys, 20)
  local enMismatch = {}
  for k, v in pairs(RfPdaSoilPanel.TARGET_PDA_EN) do if EN[k] ~= v then enMismatch[#enMismatch + 1] = k end end
  table.sort(enMismatch)
  T.eq("X1 the panel's English fallbacks are the en file's text", table.concat(enMismatch, ","), "")
  for _, l in ipairs(LANGS) do
    local missing = {}
    for _, k in ipairs(keys) do if LANG[l][k] == nil then missing[#missing + 1] = k end end
    T.eq("X " .. l .. ": every key present", table.concat(missing, ","), "")
  end
  local copies, formats, dashes, hashes = {}, {}, {}, {}
  local function specs(s) local out = {} for f in s:gmatch("%%[-+ #0-9.]*[sdif]") do out[#out + 1] = f end return table.concat(out, ",") end
  for _, l in ipairs(LANGS) do
    for _, k in ipairs(keys) do
      local e, x = LANG.en[k], LANG[l][k]
      if e ~= nil and x ~= nil then
        if l ~= "en" and x.v == e.v and k ~= "sf_tgt_pda_rel_unknown" then copies[#copies + 1] = l .. ":" .. k end
        if specs(x.v) ~= specs(e.v) then formats[#formats + 1] = l .. ":" .. k end
        for _, bad in ipairs({ "\226\128\148", "\226\128\147", "\226\128\156", "\226\128\157", "\226\128\152", "\226\128\153" }) do
          if x.v:find(bad, 1, true) then dashes[#dashes + 1] = l .. ":" .. k end
        end
        if x.eh ~= e.eh then hashes[#hashes + 1] = l .. ":" .. k end
      end
    end
  end
  T.eq("X28 NAMED: no translation is the English text (the '?' symbol excepted)", table.concat(copies, ","), "")
  T.eq("X29 every translation keeps the English format specifiers in order", table.concat(formats, ","), "")
  T.eq("X30 no em dash, en dash or smart quote", table.concat(dashes, ","), "")
  T.eq("X31 every entry carries the English text's hash", table.concat(hashes, ","), "")
end)

end
W1B_BENCH()
