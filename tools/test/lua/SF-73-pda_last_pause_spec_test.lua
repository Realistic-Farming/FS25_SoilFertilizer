-- SF-73-pda_last_pause_spec_test.lua
--
-- SF-73 section 7, the PDA last-pause follow-on: the TREATMENT card's target card names a
-- field's last no-crop pause beside W1b's last pass, built on Bob's pre-build ruling
-- (BOB-RULING-PDA-LAST-PAUSE-2026-10-03). Only a crop-condition pause enters (the reason a
-- surface names is UNSUPPORTED_CROP, a field is named, FARM_ACCESS is absent, tested on its
-- own); it is stamped on entry with the field report's crop (TA:fieldCropKey) on the peer
-- that writes it, never in the result; the card shows it only while that stamp is the field
-- report's crop, and only when it is newer than the last pass (a tie goes to the pass); it
-- reads "Last pause: no growing crop" with W1a's manual hint and no litres.
--
-- THE ENTRY-POINT BAR is group E: Tyson's field-2 case. A sprayer with a target product and
-- AUTO on over a cut supported crop on an owned field, with no earlier pass, through the real
-- install, the real sprayer hooks, buildPlan, the real F.witness and refusalIdentity, and the
-- real TargetApplication:setResult; then the PDA opened the way the page opens it (the real
-- rebuildFieldData, then the real refreshTreatmentPlan). No group hands the card a pause, and
-- no group sets a stamp: the fixture's FieldState reads the fruit plane at the field centre
-- the way FieldState:update does (field/FieldState.lua:89-97: the fruit type from the density
-- type at any growth state, cut included), so the cut field's report names its crop while the
-- refusal names none, the very mismatch this PR handles.
--
-- The engine fixture is W1b's (SF-73-W1b-pda_target_card_spec_test.lua, lines 40-617,
-- verbatim), which is the SF-73 entry bench's engine plus FieldState:update's fruit-plane part,
-- with two additions: serverWorld takes opts.ground, as the MAINTENANCE 211 bench's does, and
-- newSprayer takes opts.half (the boom's half width, default BOOM_HALF), so group A can stand a
-- narrower boom wholly on farm 2's farmland 9.
--
-- Groups:
--   E  the entry bar: Tyson's case, the pause on the host's PDA
--   N  newer wins: a pass, the crop cut, the pause; a later pass on a living strip; a tie
--   G  the edge after a pass, and a crop boundary: nothing written, the pass stands
--   L  a pause, then the boom leaves over the edge: the stored pause stays the no-crop one
--   A  FARM_ACCESS on farm B's cut field: nothing written; B's PDA on the host and a client
--   S  a resown field hides the pause; a field reporting no crop stores nothing
--   I  priming and holds write nothing
--   K  locked, and relocked: nothing new
--   C  a client: the real event stream, its own stamp; the epoch rule
--   O  one stamp per entry over a long pause; a re-entry stamps again
--   M  the memory: reset clears it, only its own functions name it, never saved, no wire field
--   T  the writer's rule, row by row (FARM_ACCESS under a reordered display order)
--   X  the new key in all 27 Soil languages, translated, read as a pause
--
-- What this bar does NOT prove: the card on screen (fonts, the 180px clip, the colour),
-- dedicated-server delivery, or a door race between installed mods. The TESTING row names
-- those observations.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/FieldSentry.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/network/NetworkEvents.lua, src/ui/SoilHUD.lua, src/ui/RfPdaSoilPanel.lua
--!text: src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/network/NetworkEvents.lua, translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml

local GROUP_N = 0
function group(fn)
  GROUP_N = GROUP_N + 1
  local ok, err = pcall(fn)
  if not ok then T.ok("group " .. GROUP_N .. " ran to its end without a Lua error", false, tostring(err)) end
end
local function PAUSE_BENCH()
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
  local half = opts.half or BOOM_HALF
  local v = { id = 4242, isServer = true, speedLimit = 12, lastSpeed = (opts.speedKmh or 10) / 3600,
              ownerFarmId = 1, activeFarm = opts.farm or 1, turnedOn = true, ai = false,
              specializationNames = opts.specs or { "sprayer", "fillUnit", "workArea" } }
  for name, fn in pairs(g_vehicleTypeManager.types.sprayer.functions) do v[name] = fn end
  v.rootVehicle = v
  v.spec_fillUnit = { fillUnits = { [1] = { fillLevel = opts.level or 500, fillType = opts.product or UREA, capacity = 3000 } } }
  v.spec_sprayer = { workAreaParameters = {}, usageScale = { default = 1, workingWidth = half * 2, fillTypeScales = {} },
                     supportedSprayTypes = {}, fillTypeSources = {} }
  local z = opts.z or -20.03
  local x0 = opts.x0 or 0
  local wa = { type = WorkAreaType.SPRAYER, functionName = "processSprayerArea",
               start = { x = x0 - half, z = z }, width = { x = x0 + half, z = z }, height = { x = x0 - half, z = z - 1 } }
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
  v.getWorkAreaWidth = function() return half * 2 end
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
  if opts.ground then GROUND.fruitAt = opts.ground end
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
-- The pause: helpers (one table; the bench keeps its count of locals)
-- =====================================================================
local H = {}
H.CUT_BARLEY = function() return 2, 9 end          -- the fixture's cut state (getIsCut: s == 9)
H.CUT_WHEAT  = function() return 1, 9 end
H.FAIR = { 0.878, 0.627, 0.125, 1.0 }              -- RfPdaSoilPanel's COLOR_FAIR (the card's fair colour)
H.GOOD = { 0.549, 0.776, 0.247, 1.0 }              -- COLOR_GOOD, REACHED's
H.POOR = { 0.788, 0.290, 0.227, 1.0 }              -- COLOR_POOR, a failed write's
H.isCropPause = TargetApplication.isCropPause or function() return nil end
function H.reasons(r) return r and table.concat(r.reasons or {}, ",") or "?" end
function H.has(r, reason)
  for _, x in ipairs(r and r.reasons or {}) do if x == reason then return true end end
  return false
end
--- Run until the stored result carries a given reason, at most `limit` ticks.
function H.runUntil(v, reason, limit)
  for _ = 1, limit or 40 do
    run(v, 1)
    local r = W.ss:getApplicationTargetResult(v)
    if H.has(r, reason) then return r end
  end
  return W.ss:getApplicationTargetResult(v)
end
--- The soil system's pause read, guarded so a tree without it fails by assertion.
function H.pause(ss, id)
  if type(ss.getLastTargetPauseForField) ~= "function" then return nil end
  return ss:getLastTargetPauseForField(id)
end
function H.count(ss)
  local n = 0
  for _ in pairs(ss.targetApplication.lastPauseByField or {}) do n = n + 1 end
  return n
end
function H.sameColor(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for i = 1, 4 do if math.abs((a[i] or -1) - (b[i] or -2)) > 1e-6 then return false end end
  return true
end
--- Teleport the boom so its front edge sits at z (the field's edge is z = 30).
function H.boomTo(v, z) moveBoom(v, z - v.spec_workArea.workAreas[1].start.z) end
--- The card's three lines, joined.
function H.lines(page)
  return tostring(cardText(page, "soilTargetState")) .. " | " .. tostring(cardText(page, "soilTargetReason"))
    .. " | " .. tostring(cardText(page, "soilTargetDetail"))
end
H.PAUSE_LINES = tostring(EN.sf_tgt_pda_state_paused) .. " | " .. tostring(EN.sf_tgt_n_manual) .. " | "

-- =====================================================================
-- E. THE ENTRY-POINT BAR: Tyson's field-2 case. AUTO on over a cut supported crop on an
--    owned field, no earlier pass, through the real hooks and setResult; then the real PDA.
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("E1 [reached] the real hooks refused the cut crop on field 7, naming no crop",
       tostring(r and r.fieldId) .. "/" .. tostring(r and r.cropKey) .. "/" .. H.reasons(r), "7/nil/UNSUPPORTED_CROP")
  local want, rel = expectedWindow(7)
  T.eq("E2 [reached] while the field report names the cut crop (the filter mismatch this PR handles)", rel and rel.cropKey, "barley")
  local page = openPda(newPage(true), 7)
  T.eq("E3 the card shows", cardVisible(page), true)
  T.eq("E4 NAMED: the state line reads the pause", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_paused)
  T.eq("E5 NAMED: the note gives W1a's manual hint", cardText(page, "soilTargetReason"), EN.sf_tgt_n_manual)
  T.eq("E6 NAMED: and the detail line is empty (nothing was spent)", cardText(page, "soilTargetDetail"), "")
  local col = page.ids.soilTargetState.color
  T.ok("E7 NAMED: a pause colour, the card's fair: neither REACHED's nor a failure's",
       H.sameColor(col, H.FAIR) and not H.sameColor(col, H.GOOD) and not H.sameColor(col, H.POOR))
  T.eq("E8 the window is still the field report", cardText(page, "soilTargetWindow"), want)
  T.eq("E9 while the card shows, the legacy heading reads as the manual plan's targets",
       page.treatTargetsHeading.text, EN.sf_tgt_pda_manual_targets)
  local p = H.pause(W.ss, 7)
  T.eq("E10 NAMED: the pause was stamped on this peer with the field report's crop", p and p.fieldCrop, "barley")
  T.eq("E11 the stamp is never in the result", W.ss:getApplicationTargetResult(W.v).fieldCrop, nil)
  T.eq("E12 the pass read keeps its contract: outcomes only, so still nil", W.ss:getLastTargetPassForField(7), nil)
  local c = H.pause(W.ss, 7)
  if c ~= nil then c.reasons[1] = "FARM_ACCESS"; c.fieldCrop = "wheat" end
  local again = H.pause(W.ss, 7)
  T.eq("E13 the soil read returns a copy: changing it leaves the memory alone",
       tostring(again and H.reasons(again)) .. "/" .. tostring(again and again.fieldCrop), "UNSUPPORTED_CROP/barley")
end)

-- =====================================================================
-- N. The newer of the pass and the pause, both on the current crop
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  local dose = runToDose(W.v, 20)
  T.eq("N1 [reached] a real REACHED on wheat, field 7", dose and (dose.doseState .. "/" .. dose.cropKey), "REACHED/wheat")
  GROUND.fruitAt = H.CUT_WHEAT                         -- the field is cut after the pass
  local r = H.runUntil(W.v, "UNSUPPORTED_CROP", 40)
  T.eq("N2 [reached] then AUTO on the stubble: the no-crop pause on field 7",
       tostring(r and r.fieldId) .. "/" .. H.reasons(r), "7/UNSUPPORTED_CROP")
  local page = openPda(newPage(true), 7)
  T.eq("N3 NAMED: the pause is newer than the pass: the card reads the pause", H.lines(page), H.PAUSE_LINES)
  -- a living strip ahead of the boom: the sprayer leaves the stubble and doses again
  local front = W.v.spec_workArea.workAreas[1].start.z
  GROUND.fruitAt = function(_x, z) if z >= front + 0.5 then return 1, 3 end return 1, 9 end
  local again = runToDose(W.v, 60)
  T.eq("N4 [reached] a later REACHED on the living strip", again and again.doseState, "REACHED")
  local page2 = openPda(newPage(true), 7)
  T.eq("N5 NAMED: the pass is newer again: the card reads it", cardText(page2, "soilTargetState"), EN.sf_tgt_pda_state_reached)
  T.eq("N6 with its litres", cardText(page2, "soilTargetDetail"),
       string.format(EN.sf_tgt_d_litres, litres(again.plannedLitres), litres(again.physicalLitres)))
  -- the tie: the two entries noted at the same mission time (set on the stored entries)
  local ta = W.ss.targetApplication
  local pe, oe = ta.lastPauseByField and ta.lastPauseByField[7], ta.lastOutcomeByField[7]
  T.ok("N7 [reached] the field holds both a pause and a pass", pe ~= nil and oe ~= nil)
  if pe ~= nil and oe ~= nil then
    pe.at = oe.at
    T.eq("N8 NAMED: a tie goes to the pass", cardText(openPda(newPage(true), 7), "soilTargetState"), EN.sf_tgt_pda_state_reached)
    pe.at = oe.at + 1
    T.eq("N9 one millisecond newer, the pause", cardText(openPda(newPage(true), 7), "soilTargetState"), EN.sf_tgt_pda_state_paused)
  end
end)

-- =====================================================================
-- G. Positional refusals write nothing: the edge after a pass, a crop boundary
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  runToDose(W.v, 20)
  H.boomTo(W.v, 30.5)                                  -- the pass ends over the field's edge
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("G1 [reached] the edge refusal names field 7 (" .. H.reasons(r) .. ")",
       r ~= nil and r.fieldId == 7 and H.has(r, "UNKNOWN_GROUND"))
  T.eq("G2 NAMED: an edge refusal writes no pause", H.count(W.ss), 0)
  T.eq("G3 NAMED: the field's pass still shows", cardText(openPda(newPage(true), 7), "soilTargetState"), EN.sf_tgt_pda_state_reached)
end)
group(function()
  serverWorld({ z = 10.03 })
  autoOn(W.v)
  run(W.v, 1)
  local r = H.runUntil(W.v, "MIXED_CROP", 40)
  T.ok("G4 [reached] the barley strip in field 7: MIXED_CROP naming the field (" .. H.reasons(r) .. ")",
       r ~= nil and r.fieldId == 7 and H.has(r, "MIXED_CROP"))
  T.eq("G5 NAMED: a crop boundary writes no pause", H.count(W.ss), 0)
end)

-- =====================================================================
-- L. A no-crop pause, then the same vehicle leaves over the edge
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  local first = H.pause(W.ss, 7)
  T.ok("L1 [reached] the pause is stored", first ~= nil and first.notedAt ~= nil)
  H.boomTo(W.v, 30.5)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.ok("L2 [reached] over the edge: unread ground leads, naming field 7 (" .. H.reasons(r) .. ")",
       r ~= nil and r.fieldId == 7 and H.has(r, "UNKNOWN_GROUND"))
  local kept = H.pause(W.ss, 7)
  T.eq("L3 NAMED: the stored pause stays the no-crop one, as noted",
       tostring(kept and H.reasons(kept)) .. "@" .. tostring(kept and kept.notedAt),
       "UNSUPPORTED_CROP@" .. tostring(first and first.notedAt))
  T.eq("L4 and the card still reads it", cardText(openPda(newPage(true), 7), "soilTargetState"), EN.sf_tgt_pda_state_paused)
end)

-- =====================================================================
-- A. FARM_ACCESS: farm 1's boom wholly over farm 2's cut field 9
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY, x0 = 25, half = 4, mp = true })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("A1 [reached] farm 1 over farm 2's cut field: FARM_ACCESS beside no crop, naming field 9",
       tostring(r and r.fieldId) .. "/" .. H.reasons(r), "9/UNSUPPORTED_CROP,FARM_ACCESS")
  T.eq("A2 NAMED: nothing is written", H.count(W.ss), 0)
  local sent = W.sent[#W.sent]
  g_localPlayer = { farmId = 2 }                       -- farm 2's player on the host
  local page = openPda(newPage(true), 9)
  local _, rel = expectedWindow(9)
  T.ok("A3 [reached] farm 2's PDA lists field 9 and its report names the cut crop",
       cardVisible(page) == true and rel ~= nil and rel.cropKey == "barley")
  T.eq("A4 NAMED: farm 2's PDA on the host: no pause of farm 1's as its own", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_none)
  clientWorld({ time = g_currentMission.time })
  g_localPlayer = { farmId = 2 }
  local _, faults, whole = deliver(sent.stream)
  T.eq("A5 [reached] the refusal reached a client whole", tostring(faults) .. "/" .. tostring(whole), "0/true")
  T.eq("A6 NAMED: and the client writes nothing either", H.count(CW.ss), 0)
  T.eq("A7 NAMED: farm 2's PDA on a client reads no pause", cardText(openPda(newPage(true), 9), "soilTargetState"), EN.sf_tgt_pda_state_none)
end)

-- =====================================================================
-- S. The crop moved on: a resown field hides the pause; no reported crop stores nothing
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  T.ok("S1 [reached] the pause on the barley stubble is stored", H.pause(W.ss, 7) ~= nil)
  GROUND.fruitAt = function() return 1, 3 end          -- resown: wheat growing everywhere
  local _, rel = expectedWindow(7)
  T.eq("S2 [reached] the field report now names wheat", rel and rel.cropKey, "wheat")
  local page = openPda(newPage(true), 7)
  T.eq("S3 NAMED: the barley pause is not this crop's", cardText(page, "soilTargetState"), EN.sf_tgt_pda_state_none)
  T.eq("S4 and no note", cardText(page, "soilTargetReason"), "")
end)
group(function()
  -- the boom over cut barley, the field centre bare: the report names no crop
  serverWorld({ ground = function(x, z) if x * x + z * z < 4 then return 0, 0 end return 2, 9 end })
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("S5 [reached] the no-crop refusal on field 7", tostring(r and r.fieldId) .. "/" .. H.reasons(r), "7/UNSUPPORTED_CROP")
  T.eq("S6 [reached] the field report names no crop", W.ss:getCropNutrientRelationship(7).cropKey, nil)
  T.eq("S7 NAMED: so nothing is stored (a nil stamp could never show)", H.count(W.ss), 0)
end)

-- =====================================================================
-- I. Priming and holds write nothing
-- =====================================================================
group(function()
  serverWorld({})
  autoOn(W.v)
  run(W.v, 1)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("I1 [reached] the first line primes on field 7", tostring(r and r.fieldId) .. "/" .. H.reasons(r), "7/FOOTPRINT_PRIMING")
  T.eq("I2 NAMED: priming writes no pause", H.count(W.ss), 0)
  run(W.v, 1)
  T.ok("I3 [reached] then a hold", TargetNutrientCore.isHold(W.ss:getApplicationTargetResult(W.v)))
  T.eq("I4 a hold writes no pause", H.count(W.ss), 0)
end)

-- =====================================================================
-- K. Locked, and relocked: nothing new
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY, gate = false })
  autoOn(W.v)
  run(W.v, 2)
  local page = openPda(newPage(true), 7)
  T.eq("K1 locked: no pause is written", H.count(W.ss), 0)
  T.eq("K2 NAMED: the card stays hidden and the heading is today's",
       tostring(cardVisible(page)) .. "/" .. tostring(page.treatTargetsHeading.text),
       "false/" .. tostring(EN.rf_pda_treatment_targets_heading or "Target levels"))
end)
group(function()
  serverWorld({ ground = H.CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  W.settings.allowsExperimentalSystems = function() return false end
  T.eq("K3 NAMED: relocked with a stored pause: the read answers nil", H.pause(W.ss, 7), nil)
  T.eq("K4 and the card hides", cardVisible(openPda(newPage(true), 7)), false)
  W.settings.allowsExperimentalSystems = function() return true end
  T.ok("K5 [reached] unlocked again, the pause is still there", H.pause(W.ss, 7) ~= nil)
end)

-- =====================================================================
-- C. A client: the server's real publish, the event's real stream, TA:receive, the
--    client's own stamp, the client's PDA. The event carries no new field.
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY, mp = true })
  autoOn(W.v)
  run(W.v, 1)
  local sent = W.sent[#W.sent]
  T.ok("C1 [reached] the server published the refusal", sent ~= nil and sent.result == "INACTIVE")
  clientWorld({ time = g_currentMission.time })
  T.eq("C2 a client that has received nothing shows no pause", cardText(openPda(newPage(true), 7), "soilTargetState"), EN.sf_tgt_pda_state_none)
  local _, faults, whole = deliver(sent.stream)
  T.eq("C3 the event read back whole through its real stream", tostring(faults) .. "/" .. tostring(whole), "0/true")
  local rec = CW.ss.targetApplication.lastPauseByField and CW.ss.targetApplication.lastPauseByField[7]
  T.eq("C4 NAMED: the client stamped the pause itself, from its own field report", rec and rec.fieldCrop, "barley")
  T.eq("C5 the received result carries no stamp (the wire is unchanged)", CW.ss:getApplicationTargetResult(CW.v).fieldCrop, nil)
  local page = openPda(newPage(true), 7)
  T.eq("C6 NAMED: the client's PDA reads the pause", H.lines(page), H.PAUSE_LINES)
end)
group(function()
  -- the epoch rule on a client (results as the event delivers them, into the real receive)
  serverWorld({})
  clientWorld({ time = 1000 })
  local ta = CW.ss.targetApplication
  local function refusal(epoch, seq, fieldId)
    return { schema = TargetNutrientCore.SCHEMA, epoch = epoch, sequence = seq, active = true, doseState = "INACTIVE",
             reasons = { "UNSUPPORTED_CROP" }, fieldId = fieldId or 7, nutrients = {} }
  end
  ta:receive(CW.v, refusal("1", "1"))
  local t1 = H.pause(CW.ss, 7)
  g_currentMission.time = 1600
  ta:receive(CW.v, refusal("1", "2"))
  local t2 = H.pause(CW.ss, 7)
  T.eq("C7 NAMED: the same pause going on in one epoch is not a new entry",
       tostring(t1 and t1.notedAt) .. "/" .. tostring(t2 and t2.notedAt), "1000/1000")
  g_currentMission.time = 2200
  ta:receive(CW.v, refusal("2", "1"))
  local t3 = H.pause(CW.ss, 7)
  T.eq("C8 NAMED: a new epoch's pause is an entry, as on the server (activate clears the result)", t3 and t3.notedAt, 2200)
  g_currentMission.time = 2800
  ta:receive(CW.v, refusal("2", "2", 9))
  local f9 = H.pause(CW.ss, 9)
  T.eq("C9 NAMED: the same vehicle's pause moving to another field is an entry there", f9 and f9.notedAt, 2800)
  g_currentMission.time = 3400
  ta:receive(CW.v, refusal("2", "3", 7))
  local back = H.pause(CW.ss, 7)
  T.eq("C10 and back on the first field, an entry again", back and back.notedAt, 3400)
end)

-- =====================================================================
-- O. One stamp per entry: a long pause reads the field crop once
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY })
  local ta = W.ss.targetApplication
  local calls, real = 0, ta.fieldCropKey
  ta.fieldCropKey = function(self, ...) calls = calls + 1; return real(self, ...) end
  autoOn(W.v)
  local startT = g_currentMission.time + DT
  run(W.v, 12)
  local r = W.ss:getApplicationTargetResult(W.v)
  T.eq("O1 [reached] twelve cycles, still the no-crop pause", H.reasons(r), "UNSUPPORTED_CROP")
  T.eq("O2 NAMED: the field crop was read once, on entry", calls, 1)
  T.eq("O3 and the entry keeps its first time", H.pause(W.ss, 7) and H.pause(W.ss, 7).notedAt, startT)
  H.boomTo(W.v, 30.5)
  run(W.v, 1)
  H.boomTo(W.v, -10)
  run(W.v, 1)
  T.eq("O4 [reached] back on the stubble after the edge", H.reasons(W.ss:getApplicationTargetResult(W.v)), "UNSUPPORTED_CROP")
  T.eq("O5 NAMED: a re-entry reads it again", calls, 2)
  T.eq("O6 and stamps the re-entry's time", H.pause(W.ss, 7) and H.pause(W.ss, 7).notedAt, g_currentMission.time)
end)

-- =====================================================================
-- M. The memory: reset clears it; only its own functions name it; never saved; no wire field
-- =====================================================================
group(function()
  serverWorld({ ground = H.CUT_BARLEY })
  autoOn(W.v)
  run(W.v, 1)
  T.ok("M1 [reached] a pause is stored", H.pause(W.ss, 7) ~= nil)
  W.ss.targetApplication:reset()
  T.eq("M2 NAMED: a reload (reset) clears it", H.pause(W.ss, 7), nil)
  local ta = SOURCE_TEXT["src/target/TargetApplication.lua"] or ""
  local sys = SOURCE_TEXT["src/SoilFertilitySystem.lua"] or ""
  local net = SOURCE_TEXT["src/network/NetworkEvents.lua"] or ""
  local where, current = {}, "(top)"
  local NL = string.char(10)
  for line in (ta .. NL):gmatch("([^" .. NL .. "]*)" .. NL) do
    local fn = line:match("^function TA[:.]([%w_]+)")
    if fn ~= nil then current = fn end
    if line:find("lastPauseByField", 1, true) then where[current] = true end
  end
  local names = {}
  for k in pairs(where) do names[#names + 1] = k end
  table.sort(names)
  T.eq("M3 NAMED: only new, reset and the pause's own writer and reader name it (nothing in the sim reads it)",
       table.concat(names, ","), "getLastPauseForField,new,noteFieldPause,reset")
  T.eq("M4 NAMED: the soil system never saves it", sys:find("lastPauseByField", 1, true), nil)
  T.ok("M5 [reached] the event source was read", net:find("SoilApplicationTargetResultEvent", 1, true) ~= nil)
  T.eq("M6 the result event names no stamp", net:find("fieldCrop", 1, true), nil)
end)

-- =====================================================================
-- T. The writer's rule, row by row
-- =====================================================================
group(function()
  local function cp(reasons, fieldId, state)
    return tostring(H.isCropPause({ doseState = state or "INACTIVE", reasons = reasons, fieldId = fieldId }))
  end
  T.eq("T1 no growing crop on a named field: a pause", cp({ "UNSUPPORTED_CROP" }, 7), "true")
  T.eq("T2 no field named: not one", cp({ "UNSUPPORTED_CROP" }, nil), "false")
  T.eq("T3 a field id that is not a number: not one", cp({ "UNSUPPORTED_CROP" }, "7"), "false")
  T.eq("T4 FARM_ACCESS beside it: not one", cp({ "UNSUPPORTED_CROP", "FARM_ACCESS" }, 9), "false")
  T.eq("T5 unread ground leads: not one", cp({ "UNSUPPORTED_CROP", "UNKNOWN_GROUND" }, 7), "false")
  T.eq("T6 the map edge leads: not one", cp({ "UNSUPPORTED_CROP", "OUTSIDE_MAP" }, 7), "false")
  T.eq("T7 a crop boundary leads: not one", cp({ "UNSUPPORTED_CROP", "MIXED_CROP" }, 7), "false")
  T.eq("T8 priming: not one", cp({ "FOOTPRINT_PRIMING" }, 7), "false")
  T.eq("T9 a hold (no reason): not one", cp({}, 7), "false")
  T.eq("T10 an outcome: not one", cp({}, 7, "REACHED"), "false")
  T.eq("T11 a lower reason beside it leaves it a pause", cp({ "UNSUPPORTED_CROP", "NOZZLE_PARTIAL" }, 7), "true")
  -- the exclusion of FARM_ACCESS must not rest on the display order: reorder it in place
  local order = TargetNutrientCore.REASON_DISPLAY_ORDER
  local saved = {}
  for i, x in ipairs(order) do saved[i] = x end
  local ok = pcall(function()
    for i = #order, 1, -1 do table.remove(order, i) end
    order[1] = "UNSUPPORTED_CROP"
    for _, x in ipairs(saved) do if x ~= "UNSUPPORTED_CROP" then order[#order + 1] = x end end
    T.eq("T12 [reached] reordered, the surface reason is no crop", TargetNutrientCore.primaryReason({ doseState = "INACTIVE",
         reasons = { "UNSUPPORTED_CROP", "FARM_ACCESS" } }), "UNSUPPORTED_CROP")
    T.eq("T13 NAMED: FARM_ACCESS is still excluded on its own test", cp({ "UNSUPPORTED_CROP", "FARM_ACCESS" }, 9), "false")
  end)
  for i = #order, 1, -1 do table.remove(order, i) end
  for i, x in ipairs(saved) do order[i] = x end
  T.ok("T14 the display order is restored", ok and table.concat(order, ",") == table.concat(saved, ","))
end)

-- =====================================================================
-- X. The pause's keys in all 27 Soil languages, translated, read as a pause
-- =====================================================================
group(function()
  local PAUSE = RfPdaSoilPanel.TARGET_PDA_PAUSE or {}
  T.eq("X0 the pause draws the new key with W1a's manual hint",
       tostring(PAUSE.line) .. "/" .. tostring(PAUSE.note), "sf_tgt_pda_state_paused/sf_tgt_n_manual")
  local EN_FB = RfPdaSoilPanel.TARGET_PDA_EN or {}
  T.eq("X1 the panel's English fallbacks are the en file's text",
       tostring(EN_FB.sf_tgt_pda_state_paused == EN.sf_tgt_pda_state_paused and EN.sf_tgt_pda_state_paused ~= nil)
       .. "/" .. tostring(EN_FB.sf_tgt_n_manual == EN.sf_tgt_n_manual and EN.sf_tgt_n_manual ~= nil), "true/true")
  local missing, copies, dashes, hashes, asPass, specs = {}, {}, {}, {}, {}, {}
  local PASS_KEYS = { "sf_tgt_pda_state_reached", "sf_tgt_pda_state_binding", "sf_tgt_pda_state_hardware",
                      "sf_tgt_pda_state_supply", "sf_tgt_pda_state_quantized", "sf_tgt_pda_state_failed",
                      "sf_tgt_pda_state_none" }
  local e = LANG.en.sf_tgt_pda_state_paused
  for _, l in ipairs(LANGS) do
    for _, k in ipairs({ "sf_tgt_pda_state_paused", "sf_tgt_n_manual" }) do
      if LANG[l][k] == nil then missing[#missing + 1] = l .. ":" .. k end
    end
    local x = LANG[l].sf_tgt_pda_state_paused
    if x ~= nil and e ~= nil then
      if l ~= "en" and x.v == e.v then copies[#copies + 1] = l end
      if x.eh ~= e.eh then hashes[#hashes + 1] = l end
      if x.v:find("%", 1, true) then specs[#specs + 1] = l end
      for _, bad in ipairs({ "\226\128\148", "\226\128\147", "\226\128\156", "\226\128\157", "\226\128\152", "\226\128\153" }) do
        if x.v:find(bad, 1, true) then dashes[#dashes + 1] = l end
      end
      for _, pk in ipairs(PASS_KEYS) do
        if LANG[l][pk] ~= nil and LANG[l][pk].v == x.v then asPass[#asPass + 1] = l .. ":" .. pk end
      end
    end
  end
  T.eq("X2 NAMED: both keys in all 27 languages", table.concat(missing, ","), "")
  T.eq("X3 NAMED: no translation is the English text", table.concat(copies, ","), "")
  T.eq("X4 no format specifier (the line takes none)", table.concat(specs, ","), "")
  T.eq("X5 no em dash, en dash or smart quote", table.concat(dashes, ","), "")
  T.eq("X6 every entry carries the English text's hash", table.concat(hashes, ","), "")
  T.eq("X7 NAMED: in no language does the pause read as any pass line", table.concat(asPass, ","), "")
  T.ok("X8 the English line is a pause in the card's 'Last ...' form", e ~= nil and e.v:find("^Last pause:") ~= nil)
end)

end
PAUSE_BENCH()
