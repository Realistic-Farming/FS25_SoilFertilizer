-- RSF-741-underwrite_entry_point_test.lua - the harvest underwrite from production's own
-- entry points: the record is ARMED by the mission lifecycle, FILLED by the real cutter and
-- Combine hooks, CONSUMED by the real completion wrapper, and PERSISTED by the real save
-- owners. Nothing here writes a provenance record, a token, a binding or a readiness flag by
-- hand; every one of them is produced by the code under test.
--
-- ENTRY POINTS, each the one production enters through:
--   * install: the real HookManager installers in installAll's order, installHarvestHook,
--     installZoneYieldCutterHook, then installHarvestUnderwrite (the capture hooks and the
--     HarvestContractUnderwrite pair), over a vehicle type table and live vehicles that
--     already hold COPIED function pointers, the way FS25 has them when a mod installs;
--   * arming: AbstractMission:update, modelled from the decompiled body
--     (missions/AbstractMission.lua:222-278, the PREPARING and RUNNING blocks), dispatching
--     to HarvestMission.finishedPreparing through the class the underwrite wrapped;
--   * capture: WorkArea:onUpdateTick's order (raise onStartWorkAreaProcessing through the
--     Cutter class table, call each work area's STORED processingFunction, raise
--     onEndWorkAreaProcessing), SpecializationUtil.raiseEvent :17-26;
--   * completion: the mission's own getCompletion (the wrapper over the decompiled body);
--   * persistence: the real SoilFertilitySystem saveToXMLFile, loadFromXMLFile,
--     getSoilStateTable, applySoilStateTable and onSowing.
--
-- THE ENGINE MODEL, and nothing else, is the fixture's: the mission classes, the cutter and
-- Combine bodies (Cutter.lua:584-705, :729-840 in the parts the underwrite reads;
-- Combine:addCutterArea's linear fill and its additive branch), the mission map and the
-- farmland map, and a field model that holds standing crop and windrows. Two SoilFertilizer
-- producers outside the code under test are supplied as the world: the SF-14 pre-cut
-- context (zoneYield.preparePreCutContext) and the scalar it resolves
-- (soilSystem:computeYieldModifier), because the underwrite's job is to MEASURE what they
-- did, not to compute it.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua, src/HarvestContractUnderwrite.lua

getXMLBool = getXMLBool or function(handle, key) if handle then return handle[key] end end
setXMLBool = setXMLBool or function(handle, key, value) if handle then handle[key] = value end end
SoilLogger.info = function() end; SoilLogger.debug = function() end; SoilLogger.warning = function() end

local HCU = HarvestContractUnderwrite
local WHEAT, BARLEY = 14, 15
local WHEAT_FILL, BARLEY_FILL = 40, 41
local MISSION_FARMLAND, OWN_FARMLAND = 7, 8
local FARM = 1
local LITRES_PER_AREA = 2.0

-- =====================================================================
-- THE ENGINE MODEL
-- =====================================================================
MissionStatus = { CREATED = 1, PREPARING = 2, RUNNING = 3, FINISHED = 4 }
MissionFinishState = { SUCCESS = 1, FAILED = 2, TIMED_OUT = 3 }
AccessHandler = { EVERYONE = 0 }
FarmlandManager = { NOT_BUYABLE_FARM_ID = 255 }

-- missions/AbstractMission.lua (the parts the underwrite depends on)
AbstractMission = { SUCCESS_FACTOR = 0.98 }
function AbstractMission:getUniqueId() return self.uniqueId end
function AbstractMission:getIsRunning() return self.status == MissionStatus.RUNNING end
function AbstractMission:getIsFinished() return self.status == MissionStatus.FINISHED end
function AbstractMission:isTimedOut() return self.timedOut == true end
function AbstractMission:validate() return not self:isTimedOut() end
function AbstractMission:getIsPrepared() return self.prepared == true end
function AbstractMission:finishedPreparing() self.status = MissionStatus.RUNNING end
function AbstractMission:finish(state) self.status = MissionStatus.FINISHED; self.finishState = state end
-- :222-278, the two blocks after the vehicle-list upkeep, verbatim in order.
function AbstractMission:update(_dt)
  if self.isServer and self.status == MissionStatus.PREPARING then
    if self:getIsPrepared() then
      self:finishedPreparing()
    end
    if self.failedToLoadVehicles and #self.pendingVehicleLoadingData == 0 then
      self:finish(MissionFinishState.FAILED)
    end
  end
  if self.status == MissionStatus.RUNNING and self.isServer then
    if self:isTimedOut() then
      self:finish(MissionFinishState.TIMED_OUT)
    elseif not self:validate() then
      self:finish(MissionFinishState.FAILED)
    end
  end
end
-- :279-293, the finish line.
function AbstractMission:updateTick()
  if self.isServer and self.status == MissionStatus.RUNNING then
    self.completion = self:getCompletion()
    if self.completion >= 0.995 then self:finish(MissionFinishState.SUCCESS) end
  end
end

-- missions/field/HarvestMission.lua
HarvestMission = setmetatable({ NAME = "harvestMission", SUCCESS_FACTOR = 0.93 }, { __index = AbstractMission })
function HarvestMission:getMissionTypeName() return HarvestMission.NAME end
-- :252-268: parent first (RUNNING), expected litres, the zero-expected failure.
function HarvestMission:finishedPreparing()
  AbstractMission.finishedPreparing(self)
  self.expectedLiters = self.maxCutLiters
  if self.expectedLiters <= 0 then
    self:finish(MissionFinishState.FAILED)
  end
end
-- :469-482: parent chain, then field availability and the selling station.
function HarvestMission:validate()
  if not AbstractMission.validate(self) then return false end
  if not self:getIsFinished() then
    if not self.fieldAvailable then return false end
    if self.sellingStation ~= nil and not self.sellingStation.isRegistered then return false end
  end
  return true
end
function HarvestMission:getFieldCompletion() return WORLD.cutFraction(self.field.farmland.id) end
-- :292-300.
function HarvestMission:getCompletion()
  local sellCompletion = 1
  if self.expectedLiters > 0 then
    sellCompletion = math.min(self.depositedLiters / self.expectedLiters / HarvestMission.SUCCESS_FACTOR, 1)
  end
  local harvestCompletion = math.min(self:getFieldCompletion() / AbstractMission.SUCCESS_FACTOR, 1)
  local w = self.harvestCompletionFactor
  return math.min(1, w * harvestCompletion + (1 - w) * sellCompletion)
end
local HarvestMission_mt = { __index = HarvestMission }
HM_FINISHED_PREPARING = HarvestMission.finishedPreparing

-- The world: two fields as rectangles, standing crop and windrows per field.
WORLD = {}
local function resetWorld()
  WORLD.fields = {
    [MISSION_FARMLAND] = { x0 = 0, x1 = 100, fruit = WHEAT, total = 1000, standing = 1000, windrow = 0, windrowFill = WHEAT_FILL },
    [OWN_FARMLAND]     = { x0 = 200, x1 = 300, fruit = WHEAT, total = 1000, standing = 1000, windrow = 0, windrowFill = WHEAT_FILL },
  }
  WORLD.sfScalar = { [MISSION_FARMLAND] = 0.6, [OWN_FARMLAND] = 0.6 }
  WORLD.missions = {}
end
function WORLD.farmlandAt(x, _z)
  for id, f in pairs(WORLD.fields) do if x >= f.x0 and x <= f.x1 then return id end end
  return 0
end
function WORLD.cutFraction(id) local f = WORLD.fields[id]; return (f.total - f.standing) / f.total end

-- The mission map: a field mission writes its active id over its polygon while active
-- (MissionManager.lua:436-446), so a lookup names the mission running (or preparing) there.
g_missionManager = {
  getMissions = function(self) return WORLD.missions end,
  getMissionAtWorldPosition = function(self, x, z)
    local id = WORLD.farmlandAt(x, z)
    for _, m in ipairs(WORLD.missions) do
      if (m.activeMissionId or 0) > 0 and m.field.farmland.id == id then return m end
    end
    return nil
  end,
}
g_farmlandManager = {
  getFarmlandIdAtWorldPosition = function(self, x, z) return WORLD.farmlandAt(x, z) end,
  -- read by the real soil load path (field geometry lookups); an unknown farmland is nil
  getFarmlandById = function(self, id) return nil end,
}
g_fruitTypeManager = {
  -- FruitTypeManager.lua:256-259: 0 for an unknown fruit.
  getFruitTypeAreaLiters = function(self, fruit, area, _windrow)
    if fruit == nil or (fruit ~= WHEAT and fruit ~= BARLEY) then return 0 end
    return area * LITRES_PER_AREA
  end,
}
function getWorldTranslation(node) return node.x, 0, node.z end

local uidCounter = 0
local function newHarvestMission(opts)
  opts = opts or {}
  uidCounter = uidCounter + 1
  local m = setmetatable({
    uniqueId = "harvestMission_" .. uidCounter, isServer = opts.isServer ~= false, status = MissionStatus.CREATED,
    farmId = opts.farmId or FARM, fruitTypeIndex = opts.fruit or WHEAT, fillTypeIndex = opts.fill or WHEAT_FILL,
    field = { farmland = { id = opts.farmland or MISSION_FARMLAND } },
    harvestCompletionFactor = 0.8, expectedLiters = 0, depositedLiters = 0,
    maxCutLiters = opts.maxCutLiters or (1000 * LITRES_PER_AREA),
    fieldAvailable = true, sellingStation = { isRegistered = true },
    failedToLoadVehicles = false, pendingVehicleLoadingData = {}, prepared = false,
  }, HarvestMission_mt)
  WORLD.missions[#WORLD.missions + 1] = m
  return m
end
-- MissionManager:startMission then AbstractMission:start/prepare: PREPARING, an active id.
local activeId = 0
local function startMission(m)
  activeId = activeId + 1
  m.activeMissionId = activeId
  m.status = MissionStatus.PREPARING
end

-- ── the vehicle side: the specialization classes, a type table, live instances ──────
Cutter = {}
-- Cutter.lua:584-668, the parts the underwrite reads (server state, lastFruitType, the
-- multiplier area and the cumulative return).
function Cutter:processCutterArea(workArea, _dt)
  local spec = self.spec_cutter
  if spec.workAreaParameters.combineVehicle == nil then return 0, 0 end
  local id = WORLD.farmlandAt(workArea.start.x, workArea.start.z)
  local f = WORLD.fields[id]
  local lastArea, lastMultiplierArea = 0, 0
  if f ~= nil and f.standing > 0 and (workArea.cut or 0) > 0 then
    local area = math.min(workArea.cut, f.standing)
    f.standing = f.standing - area
    if self.isServer then
      if f.fruit ~= spec.currentInputFruitType then
        spec.currentInputFruitType = f.fruit
        spec.currentOutputFillType = (f.fruit == WHEAT) and WHEAT_FILL or BARLEY_FILL
      end
    end
    lastMultiplierArea = area * 1.0          -- getHarvestScaleMultiplier, neutral here
    spec.workAreaParameters.lastFruitType = f.fruit
    lastArea = area
  end
  spec.workAreaParameters.lastArea = spec.workAreaParameters.lastArea + lastArea
  spec.workAreaParameters.lastMultiplierArea = spec.workAreaParameters.lastMultiplierArea + lastMultiplierArea
  return spec.workAreaParameters.lastArea, 0
end
-- :669-705: a server pickup writes lastLiters (replaced), the output fill type and the
-- conversion factor, and returns 1.
function Cutter:processPickupCutterArea(workArea, _dt)
  local spec = self.spec_cutter
  if spec.workAreaParameters.combineVehicle ~= nil then
    local id = WORLD.farmlandAt(workArea.start.x, workArea.start.z)
    local f = WORLD.fields[id]
    if self.isServer and f ~= nil and f.windrow > 0 then
      local picked = math.min(workArea.pick or 0, f.windrow)
      if picked > 0 then
        f.windrow = f.windrow - picked
        spec.currentOutputFillType = f.windrowFill
        spec.currentConversionFactor = 1
        spec.workAreaParameters.lastLiters = picked
        return 1, 1
      end
    end
  end
  return 0, 0
end
-- :729-769.
function Cutter:onStartWorkAreaProcessing(_dt)
  local spec = self.spec_cutter
  spec.workAreaParameters.combineVehicle = self.combine
  spec.workAreaParameters.lastLiters = 0
  spec.workAreaParameters.lastArea = 0
  spec.workAreaParameters.lastMultiplierArea = 0
  spec.workAreaParameters.lastFruitType = nil
end
-- :770-840, the Combine call and its inputs.
function Cutter:onEndWorkAreaProcessing(_dt)
  if self.isServer then
    local spec = self.spec_cutter
    local lastArea, lastLiters = spec.workAreaParameters.lastArea, spec.workAreaParameters.lastLiters
    if lastArea > 0 or lastLiters > 0 then
      if spec.workAreaParameters.combineVehicle ~= nil then
        local inputFruitType = spec.workAreaParameters.lastFruitType
        local liters = g_fruitTypeManager:getFruitTypeAreaLiters(inputFruitType, spec.workAreaParameters.lastMultiplierArea, false) + lastLiters
        local conversionFactor = spec.currentConversionFactor or 1
        liters = liters * conversionFactor
        spec.workAreaParameters.combineVehicle:addCutterArea(lastArea, liters, inputFruitType, spec.currentOutputFillType, 1, FARM, 1)
      end
    end
  end
end
local CUTTER_START, CUTTER_END = Cutter.onStartWorkAreaProcessing, Cutter.onEndWorkAreaProcessing
Combine = {}
-- Combine:addCutterArea: the linear threshing scale, the fill (partial or none when full).
function Combine:addCutterArea(area, liters, inputFruitType, outputFillType, _straw, _farmId, _load)
  local spec = self.spec_combine
  if area <= 0 and liters <= 0 then return 0 end
  local delta = liters * spec.threshingScale
  local free = spec.capacity - spec.fill
  if free <= 0 then return 0 end
  if delta > free then delta = free end
  spec.fill = spec.fill + delta
  if spec.additives.available and (spec.additiveLevel or 0) > 0 then spec.additiveLevel = spec.additiveLevel - 1 end
  return delta
end
function Combine:getFillUnitFillLevel(_idx) return self.spec_combine.additiveLevel or 0 end

g_vehicleTypeManager = { types = {
  harvester = { specializationsByName = { cutter = true, combine = true, workArea = true },
                functions = { processCutterArea = Cutter.processCutterArea,
                              processPickupCutterArea = Cutter.processPickupCutterArea,
                              addCutterArea = Combine.addCutterArea,
                              getFillUnitFillLevel = Combine.getFillUnitFillLevel } },
} }
VehicleSystem = { addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v; return true end }

--- A harvester as FS25 has it after load: functions COPIED from the type
--- (SpecializationUtil.copyTypeFunctionsInto), each work area's processingFunction
--- captured from the instance at load (WorkArea.lua loadWorkAreaFromXML :266).
local function loadHarvester(opts)
  opts = opts or {}
  local v = { isServer = opts.isServer ~= false, typeName = "harvester" }
  for name, fn in pairs(g_vehicleTypeManager.types.harvester.functions) do rawset(v, name, fn) end
  v.spec_cutter = { workAreaParameters = { lastArea = 0, lastMultiplierArea = 0, lastLiters = 0 },
                    currentConversionFactor = nil }
  v.spec_combine = { threshingScale = 1.0, capacity = opts.capacity or 1e9, fill = 0,
                     additives = { available = opts.additives == true, fillTypes = { WHEAT_FILL }, fillUnitIndex = 2 },
                     additiveLevel = opts.additiveLevel or 0 }
  v.combine = v
  v.getActiveFarm = function() return opts.farmId or FARM end
  v.spec_workArea = { workAreas = {} }
  for i, wa in ipairs(opts.workAreas or {}) do
    wa.processingFunction = v[wa.functionName]
    v.spec_workArea.workAreas[i] = wa
  end
  -- A vehicle enters the world through VehicleSystem:addVehicle, the path the Combine
  -- wrapper's late patch rides for a vehicle loaded after the install.
  VehicleSystem.addVehicle(g_currentMission.vehicleSystem, v)
  return v
end
--- A work area whose four corners sit around (x, 50).
local function area(fn, x, amount)
  local wa = { functionName = fn, start = { x = x, z = 50 }, width = { x = x + 1, z = 50 }, height = { x = x, z = 51 } }
  if fn == "processCutterArea" then wa.cut = amount else wa.pick = amount end
  return wa
end
--- WorkArea:onUpdateTick's order.
local function tick(v, dt)
  Cutter.onStartWorkAreaProcessing(v, dt)                -- raiseEvent: spec[eventName](object, ...)
  for _, wa in ipairs(v.spec_workArea.workAreas) do wa.processingFunction(v, wa, dt) end
  Cutter.onEndWorkAreaProcessing(v, dt, true)
end

-- ── the SoilFertilizer world: the fields SF tracks, the SF-14 producers ─────────────
local function newSoil()
  local s = setmetatable({
    fieldData = { [MISSION_FARMLAND] = { pH = 6.5, nitrogen = 40, phosphorus = 35, potassium = 45, organicMatter = 3,
                                         fieldArea = 2.0, lastHarvest = 0, nutrientBuffer = {} },
                  [OWN_FARMLAND] = { pH = 6.5, nitrogen = 40, phosphorus = 35, potassium = 45, organicMatter = 3,
                                     fieldArea = 2.0, lastHarvest = 0, nutrientBuffer = {} } },
    lastUpdateDay = 0, herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
  s.computeYieldModifier = function(_self, fieldId, _fruit) return WORLD.sfScalar[fieldId] or 1.0 end
  return s
end
local function newWorld()
  resetWorld()
  g_server = {}
  g_currentMission = { vehicleSystem = { vehicles = {} }, addIngameNotification = function() end, time = 0 }
  local soil = newSoil()
  g_SoilFertilityManager = {
    settings = { enabled = true },
    soilSystem = soil,
    zoneYield = {
      preparePreCutContext = function(_self, cutterSelf, workArea)
        local id = WORLD.farmlandAt(workArea.start.x, workArea.start.z)
        local f = WORLD.fields[id]
        if f == nil or f.standing <= 0 then return nil end
        return { fieldId = id, fruitTypeIndex = f.fruit, path = "fallback" }
      end,
      onFirstCut = function() end,
    },
  }
  return soil
end

-- The real install, in installAll's order.
local function install()
  HCU._wrapper, HCU._armWrapper = nil, nil
  local hm = HookManager.new()
  local harvestOk = hm:installHarvestHook(); hm._harvestHookOk = harvestOk == true
  local zyOk = hm:installZoneYieldCutterHook(); hm._zoneYieldHookOk = zyOk == true
  local ready = hm:installHarvestUnderwrite()
  return hm, ready
end
local function uninstall(hm) hm.installed = true; hm:uninstallAll() end

local function rec(fieldId) local fd = g_SoilFertilityManager.soilSystem.fieldData[fieldId]; return fd and fd.harvestUnderwriteProvenance end
local function arm(m) startMission(m); m.prepared = true; m:update(16) end

-- =====================================================================
-- I. THE INSTALL (item 9)
-- =====================================================================
local hv
do
  newWorld()
  hv = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm, ready = install()
  T.eq("I1 installHarvestUnderwrite reports ready with every surface live", ready, true)
  T.eq("I2 readiness is what the completion reads", HCU.isReady(), true)
  T.ok("I3 the arming wrapper is on HarvestMission.finishedPreparing", HarvestMission.finishedPreparing == HCU._armWrapper)
  T.ok("I4 the completion wrapper is on HarvestMission.getCompletion", HarvestMission.getCompletion == HCU._wrapper)
  T.ok("I5 the live standing work-area pointer is wrapped", hv.spec_workArea.workAreas[1].processingFunction ~= Cutter.processCutterArea)
  T.ok("I6 Cutter start and end are wrapped on the class", Cutter.onStartWorkAreaProcessing ~= CUTTER_START and Cutter.onEndWorkAreaProcessing ~= CUTTER_END)
  local ptr = hv.spec_workArea.workAreas[1].processingFunction
  hm:installZoneYieldCutterHook(); hm:installUnderwriteCaptureHooks()
  T.ok("I7 a second install leaves the live pointer as it was (one tagged wrapper)", hv.spec_workArea.workAreas[1].processingFunction == ptr)
  -- the arming half lost (restored by some other path) while the completion half stays:
  -- a re-install puts the arming back instead of taking one half for the pair
  local armWrapper = HarvestMission.finishedPreparing
  HarvestMission.finishedPreparing = rawget(HarvestMission, "finishedPreparing") == armWrapper and HM_FINISHED_PREPARING or HarvestMission.finishedPreparing
  T.ok("I10a (the arming half is gone)", HarvestMission.finishedPreparing ~= HCU._armWrapper)
  T.eq("I10b a re-install reports the pair live", HCU.install(nil), true)
  T.ok("I10c and the arming wrapper is back on finishedPreparing", HarvestMission.finishedPreparing == HCU._armWrapper)
  HarvestMission.finishedPreparing = armWrapper
  uninstall(hm)
  T.eq("I8 teardown drops readiness", HCU.isReady(), false)
  T.ok("I9 teardown restores the class completion", HarvestMission.getCompletion ~= HCU._wrapper)
end

-- =====================================================================
-- A. ARMING THROUGH AbstractMission:update (v0.5 item 3)
-- =====================================================================
do
  newWorld(); local hm = install()
  local m = newHarvestMission()
  startMission(m)
  T.eq("A1 a started mission is PREPARING and has no record", rec(MISSION_FARMLAND), nil)
  m:update(16)
  T.eq("A2 an update before preparation completes arms nothing", rec(MISSION_FARMLAND), nil)
  m.prepared = true; m:update(16)
  T.eq("A3 the update that completes preparation runs finishedPreparing: RUNNING", m.status, MissionStatus.RUNNING)
  local r = rec(MISSION_FARMLAND)
  T.ok("A4 and arms the record on the SF field", r ~= nil and r.armed == true and r.captureFault == false)
  T.eq("A5 bound to the mission's saved uniqueId", r and r.missionUniqueId, m.uniqueId)
  T.eq("A6 and its fruit", r and r.fruitTypeIndex, WHEAT)
  T.ok("A7 with zero totals", r and r.preTotal == 0 and r.postTotal == 0 and r.cutCount == 0)
  T.eq("A8 after native computed expected litres", m.expectedLiters, 2000)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  local m = newHarvestMission({ maxCutLiters = 0 })
  arm(m)
  T.eq("A9 zero expected litres: native fails it inside finishedPreparing", m.status, MissionStatus.FINISHED)
  T.eq("A10 and nothing is armed", rec(MISSION_FARMLAND), nil)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  local m = newHarvestMission()
  m.failedToLoadVehicles = true; m.pendingVehicleLoadingData = {}
  arm(m)
  T.eq("A11 vehicles failed with the field task done: native finishes it FAILED in the same call", m.finishState, MissionFinishState.FAILED)
  T.eq("A12 and the arming refused it (the vehicle pair mirrored)", rec(MISSION_FARMLAND), nil)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  local m = newHarvestMission(); m.timedOut = true
  arm(m)
  T.eq("A13 a period crossed during preparation: native finishes it TIMED_OUT", m.finishState, MissionFinishState.TIMED_OUT)
  T.eq("A14 and nothing is armed", rec(MISSION_FARMLAND), nil)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  local m = newHarvestMission(); m.sellingStation.isRegistered = false
  arm(m)
  T.eq("A15 the selling station unregistered: native finishes it FAILED (validate)", m.finishState, MissionFinishState.FAILED)
  T.eq("A16 and the arming refused it: HarvestMission:validate was asked on the instance", rec(MISSION_FARMLAND), nil)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  local m = newHarvestMission({ isServer = false })
  startMission(m); m.prepared = true
  HarvestMission.finishedPreparing(m)
  T.eq("A17 a client-side mission never arms (the mission's own isServer)", rec(MISSION_FARMLAND), nil)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  g_SoilFertilityManager.soilSystem.fieldData[MISSION_FARMLAND] = nil
  local m = newHarvestMission()
  arm(m)
  T.eq("A18 no SF field record: the mission runs", m.status, MissionStatus.RUNNING)
  T.eq("A19 and no field record is created to hold one", g_SoilFertilityManager.soilSystem.fieldData[MISSION_FARMLAND], nil)
  uninstall(hm)
end
do
  newWorld(); local hm = install()
  local m1 = newHarvestMission(); arm(m1)
  m1:finish(MissionFinishState.SUCCESS)
  local m2 = newHarvestMission(); arm(m2)
  T.eq("A20 a later mission on the same field replaces the record at its boundary", rec(MISSION_FARMLAND).missionUniqueId, m2.uniqueId)
  uninstall(hm)
end

-- =====================================================================
-- C. CAPTURE THROUGH THE REAL HOOKS (items 4 to 8)
-- =====================================================================
local function runContract(opts)
  opts = opts or {}
  newWorld()
  local v = loadHarvester(opts.harvester or { workAreas = { area("processCutterArea", 50, 100) } })
  local hm, ready = install()
  local m = newHarvestMission(opts.mission)
  arm(m)
  for _ = 1, (opts.ticks or 1) do tick(v, 16) end
  return m, v, hm, ready
end
do
  local m, v, hm = runContract({ ticks = 3 })
  local r = rec(MISSION_FARMLAND)
  T.eq("C1 three ticks on the contract field record three cuts", r.cutCount, 3)
  T.near("C2 healthy total is the native litres (3 x 100 area x 2 L)", r.preTotal, 600, 1e-9)
  T.near("C3 applied total is what the Combine took (SF scalar 0.6)", r.postTotal, 360, 1e-9)
  T.near("C4 so the applied ratio is SF's own 0.6", r.postTotal / r.preTotal, 0.6, 1e-12)
  T.near("C5 and the tank holds exactly the applied total", v.spec_combine.fill, 360, 1e-9)
  T.eq("C6 no fault", r.captureFault, false)
  T.eq("C7 the token never outlives the cutter end", HCU._token, nil)
  uninstall(hm)
end
do
  -- two scalars in the same contract: the weighted aggregate, not the last, not an average
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  WORLD.sfScalar[MISSION_FARMLAND] = 0.5; tick(v, 16)
  WORLD.sfScalar[MISSION_FARMLAND] = 0.9; tick(v, 16); tick(v, 16); tick(v, 16)
  local r = rec(MISSION_FARMLAND)
  T.near("C8 ratio = (0.5 + 3 x 0.9) / 4 = 0.8, the post-Combine weighted aggregate", r.postTotal / r.preTotal, 0.8, 1e-12)
  T.ok("C9 not the last scalar (0.9)", math.abs(r.postTotal / r.preTotal - 0.9) > 1e-6)
  uninstall(hm)
end
do
  -- a full tank: the Combine returns 0, a normal skip
  local m, v, hm = runContract({ harvester = { workAreas = { area("processCutterArea", 50, 100) }, capacity = 60 }, ticks = 3 })
  local r = rec(MISSION_FARMLAND)
  T.eq("C10 a partial fill then a full tank: the zero returns record nothing and fault nothing", r.captureFault, false)
  T.eq("C11 only the one call that took material counts", r.cutCount, 1)
  T.near("C12 weighted by what was applied: pre 200 x 60/120 = 100, post 60", r.preTotal, 100, 1e-9)
  T.near("C13", r.postTotal, 60, 1e-9)
  uninstall(hm)
end
do
  -- pickup material joins both sides once (never divided by an SF-only ratio)
  newWorld()
  WORLD.fields[MISSION_FARMLAND].windrow = 500
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100), area("processPickupCutterArea", 60, 80) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  tick(v, 16)
  local r = rec(MISSION_FARMLAND)
  -- standing 100 area -> healthy 200 L, actual 120 L; pickup 80 L on both sides
  T.near("C14 standing plus pickup: healthy 200 + 80", r.preTotal, 280, 1e-9)
  T.near("C15 actual 120 + 80", r.postTotal, 200, 1e-9)
  T.near("C16 the pickup litres are never scaled by SF's ratio", r.postTotal / r.preTotal, 200 / 280, 1e-12)
  uninstall(hm)
end
do
  -- cutting the farm's OWN field while the contract runs: proven non-mission
  local m, v, hm = runContract({ harvester = { workAreas = { area("processCutterArea", 250, 100) } }, ticks = 2 })
  local r = rec(MISSION_FARMLAND)
  T.eq("C17 cutting the farm's own field records nothing on the contract", r.cutCount, 0)
  T.eq("C18 and faults nothing (proven non-mission: geometry and farmland name no mission)", r.captureFault, false)
  uninstall(hm)
end
do
  -- one header across the contract field and the farm's own field in the same tick
  local m, v, hm = runContract({ harvester = { workAreas = { area("processCutterArea", 50, 100), area("processCutterArea", 250, 100) } } })
  local r = rec(MISSION_FARMLAND)
  T.eq("C19 a header straddling the contract and own ground faults the record (bindings disagree)", r.captureFault, true)
  T.eq("C20 and records no totals from that material", r.cutCount, 0)
  uninstall(hm)
end
do
  -- the wrong crop on the contract field: a running mission found with the wrong identity
  newWorld()
  WORLD.fields[MISSION_FARMLAND].fruit = BARLEY
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  tick(v, 16)
  T.eq("C21 cutting another crop on the contract field faults its record, never 'non-mission'", rec(MISSION_FARMLAND).captureFault, true)
  uninstall(hm)
end
do
  -- a client's cutter tick
  newWorld()
  local server = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local client = loadHarvester({ isServer = false, workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  local before = rec(MISSION_FARMLAND)
  local snap = { before.preTotal, before.postTotal, before.cutCount, before.captureFault }
  tick(client, 16)
  local r = rec(MISSION_FARMLAND)
  T.ok("C22 a client's cutter ticks leave the record byte-for-byte unchanged",
    r.preTotal == snap[1] and r.postTotal == snap[2] and r.cutCount == snap[3] and r.captureFault == snap[4])
  uninstall(hm)
end
do
  -- an active additive on the output fill type: the non-linear branch faults
  local m, v, hm = runContract({ harvester = { workAreas = { area("processCutterArea", 50, 100) }, additives = true, additiveLevel = 10 } })
  T.eq("C23 an active supported additive faults rather than extrapolates", rec(MISSION_FARMLAND).captureFault, true)
  uninstall(hm)
end
do
  -- another mod scales the litres between Cutter and our Combine wrapper
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local ours = v.addCutterArea
  v.addCutterArea = function(self, a, liters, ...) return ours(self, a, liters * 1.1, ...) end
  local m = newHarvestMission(); arm(m)
  tick(v, 16)
  T.eq("C24 live litres that do not match the token fault the record", rec(MISSION_FARMLAND).captureFault, true)
  uninstall(hm)
end
do
  -- a Combine call that raises: the record faults and the error travels on
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local ownAdd = rawget(v, "addCutterArea")
  local hm = install()
  local m = newHarvestMission(); arm(m)
  -- the chain the wrapper calls raises
  v.spec_combine.threshingScale = nil
  local ok = pcall(tick, v, 16)
  T.eq("C25 the raised error reaches the caller", ok, false)
  T.eq("C26 and the record is faulted", rec(MISSION_FARMLAND).captureFault, true)
  T.eq("C27 and the token is cleared all the same", HCU._token, nil)
  uninstall(hm)
end
do
  -- no Combine attached: the end runs, no Combine call, the token is still cleared
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  v.combine = nil
  tick(v, 16)
  T.eq("C28 no Combine: nothing recorded", rec(MISSION_FARMLAND).cutCount, 0)
  T.eq("C29 and no token left behind", HCU._token, nil)
  uninstall(hm)
end
do
  -- a vehicle loaded AFTER the install gets the wrapped type function and one wrapper
  newWorld()
  local hm = install()
  local late = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local m = newHarvestMission(); arm(m)
  tick(late, 16)
  local r = rec(MISSION_FARMLAND)
  T.eq("C30 a late vehicle's cut is captured through the wrapped type copy", r.cutCount, 1)
  T.near("C31 once, at SF's ratio", r.postTotal / r.preTotal, 0.6, 1e-12)
  uninstall(hm)
end
do
  -- an install surface missing: readiness false, the contract stays vanilla
  newWorld()
  local saved = Cutter.processPickupCutterArea
  Cutter.processPickupCutterArea = nil
  local hm, ready = install()
  Cutter.processPickupCutterArea = saved
  T.eq("C32 a missing capture surface leaves provenance NOT ready", ready, false)
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local m = newHarvestMission(); arm(m)
  for _ = 1, 10 do tick(v, 16) end
  m.depositedLiters = v.spec_combine.fill            -- 1200 L from a fully cut field at 0.6
  -- the native blend: 0.8 * min(1 / 0.98, 1) + 0.2 * min(1200 / 2000 / 0.93, 1)
  T.near("C33 and the completion is exactly the native blend", m:getCompletion(), 0.8 + 0.2 * (1200 / 2000 / 0.93), 1e-12)
  uninstall(hm)
end

do
  -- a PICKUP-only tick on the contract field (no standing crop, a windrow): the pickup
  -- binding is the only binding, so it alone carries the material to the record
  newWorld()
  WORLD.fields[MISSION_FARMLAND].standing = 0
  WORLD.fields[MISSION_FARMLAND].windrow = 500
  local v = loadHarvester({ workAreas = { area("processPickupCutterArea", 60, 80) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  tick(v, 16)
  local r = rec(MISSION_FARMLAND)
  T.eq("C34 a pickup-only tick on the contract records one cut", r.cutCount, 1)
  T.near("C35 its litres on BOTH sides (80, 80)", r.preTotal + r.postTotal, 160, 1e-9)
  uninstall(hm)
end
do
  -- cutting the contract while picking up the farm's OWN windrow in the same tick
  newWorld()
  WORLD.fields[OWN_FARMLAND].windrow = 500
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100), area("processPickupCutterArea", 250, 80) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  tick(v, 16)
  T.eq("C36 contract standing plus own-ground pickup in one tick faults (the pickup binding disagrees)", rec(MISSION_FARMLAND).captureFault, true)
  uninstall(hm)
end
do
  -- a CLIENT straddling the contract edge: only the server may fault a record
  newWorld()
  local client = loadHarvester({ isServer = false, workAreas = { area("processCutterArea", 50, 100), area("processCutterArea", 250, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  tick(client, 16)
  T.eq("C37 a client's straddling tick faults nothing", rec(MISSION_FARMLAND).captureFault, false)
  uninstall(hm)
end
do
  -- a foreign replacement of the combine's addCutterArea that never reaches our wrapper:
  -- the token was made but not consumed, and must still die with the cutter end
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  v.addCutterArea = function() return 0 end
  tick(v, 16)
  T.eq("C38 an unconsumed token is cleared after the end all the same", HCU._token, nil)
  T.eq("C39 and nothing was recorded", rec(MISSION_FARMLAND).cutCount, 0)
  uninstall(hm)
end

-- =====================================================================
-- P. THE WHOLE CONTRACT: cut, deliver, complete (items 11 to 16 end to end)
-- =====================================================================
do
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  for _ = 1, 10 do tick(v, 16) end            -- the whole field: 1000 area
  T.near("P1 the field is fully cut", WORLD.cutFraction(MISSION_FARMLAND), 1.0, 1e-12)
  m:updateTick()
  T.near("P2 fully cut, NOTHING delivered: completion is the native 0.80", m.completion, 0.8, 1e-12)
  T.eq("P3 and the contract does not finish", m.status, MissionStatus.RUNNING)
  m.depositedLiters = v.spec_combine.fill * 0.5   -- half the degraded grain delivered
  m:updateTick()
  T.ok("P4 half the grain delivered: still below the line", m.completion < 0.995 and m.status == MissionStatus.RUNNING)
  m.depositedLiters = v.spec_combine.fill         -- all 1200 L the degraded ground gave
  m:updateTick()
  T.near("P5 everything the degraded ground gave, delivered: completion 1.0", m.completion, 1.0, 1e-9)
  T.eq("P6 and native finishes the contract SUCCESS", m.finishState, MissionFinishState.SUCCESS)
  uninstall(hm)
end

-- =====================================================================
-- S. PERSISTENCE THROUGH THE REAL SAVE OWNERS (item 10)
-- =====================================================================
local KEY = "soilData"
local function capturedSoil()
  newWorld()
  local v = loadHarvester({ workAreas = { area("processCutterArea", 50, 100) } })
  local hm = install()
  local m = newHarvestMission(); arm(m)
  tick(v, 16); tick(v, 16)
  return g_SoilFertilityManager.soilSystem, m, hm
end
do
  local soil, m, hm = capturedSoil()
  local before = rec(MISSION_FARMLAND)
  local out = {}
  local ok, err = pcall(SoilFertilitySystem.saveToXMLFile, soil, out, KEY)
  T.ok("S1 the real XML save ran (" .. tostring(err) .. ")", ok)
  local fk
  for k, val in pairs(out) do
    if type(k) == "string" and k:find("#id$") and val == MISSION_FARMLAND then fk = k:gsub("#id$", "") end
  end
  T.eq("S2 the seven attributes are on the field node", fk and out[fk .. "#underwriteMissionUniqueId"], m.uniqueId)
  local s2 = newSoil()
  local ok2, err2 = pcall(SoilFertilitySystem.loadFromXMLFile, s2, out, KEY)
  T.ok("S3 the real XML load ran (" .. tostring(err2) .. ")", ok2)
  local r2 = s2.fieldData[MISSION_FARMLAND] and s2.fieldData[MISSION_FARMLAND].harvestUnderwriteProvenance
  T.ok("S4 the record round-trips on the XML path",
    r2 ~= nil and r2.missionUniqueId == before.missionUniqueId and r2.fruitTypeIndex == before.fruitTypeIndex
    and r2.armed == true and r2.captureFault == false and r2.cutCount == before.cutCount
    and math.abs(r2.preTotal - before.preTotal) < 1e-9 and math.abs(r2.postTotal - before.postTotal) < 1e-9)

  local snap = soil:getSoilStateTable()
  local s3 = newSoil()
  local ok3, err3 = pcall(SoilFertilitySystem.applySoilStateTable, s3, snap)
  T.ok("S5 the real ledger mirror and apply ran (" .. tostring(err3) .. ")", ok3)
  local r3 = s3.fieldData[MISSION_FARMLAND] and s3.fieldData[MISSION_FARMLAND].harvestUnderwriteProvenance
  T.ok("S6 the record round-trips on the StateLedger path", r3 ~= nil and r3.missionUniqueId == before.missionUniqueId
    and r3.cutCount == before.cutCount and math.abs(r3.postTotal - before.postTotal) < 1e-9)

  -- the reloaded record still drives the same mission after the reload
  g_SoilFertilityManager.soilSystem = s2
  m.depositedLiters = 0
  T.near("S7 after a reload the record is consumed by the same mission (ratio intact)", rec(MISSION_FARMLAND).postTotal / rec(MISSION_FARMLAND).preTotal, 0.6, 1e-12)

  -- an older ledger snapshot without the seven keys: no record
  local old = soil:getSoilStateTable()
  for _, e in pairs(old.fields or old) do
    if type(e) == "table" then for _, k in ipairs(HCU.KEYS) do e[k] = nil end end
  end
  local s4 = newSoil()
  pcall(SoilFertilitySystem.applySoilStateTable, s4, old)
  T.eq("S8 an older snapshot without the keys loads NO record (vanilla)", s4.fieldData[MISSION_FARMLAND] and s4.fieldData[MISSION_FARMLAND].harvestUnderwriteProvenance, nil)

  -- an invalid combination is discarded
  local bad = {}
  for k, val in pairs(out) do bad[k] = val end
  bad[fk .. "#underwriteArmed"] = false
  local s5 = newSoil()
  pcall(SoilFertilitySystem.loadFromXMLFile, s5, bad, KEY)
  T.eq("S9 an invalid key set (unarmed) is discarded on load", s5.fieldData[MISSION_FARMLAND] and s5.fieldData[MISSION_FARMLAND].harvestUnderwriteProvenance, nil)

  -- a new sowing ends the record
  local ok6 = pcall(SoilFertilitySystem.onSowing, soil, MISSION_FARMLAND, 1, WHEAT, 0)
  T.eq("S10 sowing clears the record (the crop-cycle reset)", soil.fieldData[MISSION_FARMLAND].harvestUnderwriteProvenance, nil)
  uninstall(hm)
end

g_SoilFertilityManager = nil
HCU._wrapper, HCU._armWrapper = nil, nil
HCU.setCaptureReady(false)
