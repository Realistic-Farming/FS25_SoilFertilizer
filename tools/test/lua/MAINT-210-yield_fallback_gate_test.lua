-- MAINT-210-yield_fallback_gate_test.lua
--
-- MAINTENANCE row 210 (Soil #1083, Sauge's report): with Experimental Systems off, a
-- depleted field harvested at full yield. Since SF-14 (45eea573) the field-average N/P/K
-- yield penalty runs only inside ZoneYield's pre-cut context, and preparePreCutContext
-- returned nil on its first line whenever the locked growth family (growth_modulation)
-- was not live, so the cutter wrapper never scaled. The penalty is the baseline, not the
-- growth family: a closed gate is "unavailable spatial truth" (One Ground amendment :361)
-- and gets the existing field-average result, as the pre-SF-14 hopper hook gave it, with
-- that hook's nutrientCycles gate.
--
-- THE ENTRY-POINT BAR is every group: the real install (HookManager.new, then
-- installZoneYieldCutterHook) over a harvester that was live before the install, its work
-- area holding the processingFunction COPIED at load (WorkArea.lua :266), driven in
-- WorkArea:onUpdateTick's order (Cutter start, the stored processingFunction, Cutter end).
-- The pre-cut context is the REAL ZoneYield, built as production builds it
-- (ZoneYield.new(g_SoilFertilityManager)); the scalar is the REAL
-- SoilFertilitySystem:computeYieldModifier on the field's own N/P/K and OM; the release
-- gate is the REAL ReleaseGate reading the REAL Settings (Settings.new, the schema
-- defaults: Experimental Systems OFF, nutrient cycles ON). The opt-in is PRESENT and
-- false, never the fail-open nil (zone_yield_sf14_test.lua A13 covers that one).
--
-- The engine is modelled from the decompiled scripts: Cutter.lua :584-666 (the cut and
-- the multiplier area, neutral harvest multiplier), :729-768 (the start event's fruit
-- list), :770-840 (the combine's litres), FSDensityMapUtil.getFruitArea, the field and
-- farmland maps. Group G5 places a READY receipt by hand, as SF-14's own bench does: it
-- is the open-gate regression of the spatial path, not part of the closed-gate bar.
--
-- Groups:
--   G0  the gate is present and closed with the real settings
--   G1  closed gate, Sauge's depleted field: the cut is scaled by the field-average
--       scalar, 0.525 derived by hand, equal to the open-gate fallback
--   G2  closed gate: SF14_CUT path=fallback; no receipt, polygon or drag read; nothing
--       of SF-14's written
--   G3  closed gate: the field's yield freezes at the first cut and holds
--   G4  closed gate, a contract field: the contract path, scaled, and the underwrite
--       measures the scaled cut
--   G5  open gate: a READY receipt is spatial, none is the fallback (regression)
--   G6  nutrient cycles off: no scaling and no freeze on the non-spatial path, gate open
--       or closed; the spatial path as SF-14 built it
--   G7  open gate, value maps unavailable: the fallback context, scaled, never nil
--   T   the harvest hook's debug line names the cutter, not the retired hopper hook
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/maps/SoilValueMaps.lua, src/ViabilityMask.lua, src/integrations/OptionScalingResolver.lua, src/ZoneYield.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua, src/HarvestContractUnderwrite.lua
--!text: src/hooks/HookManager.lua

SoilLogger.info = function() end
SoilLogger.warning = function() end
local LOG = {}
SoilLogger.debug = function(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  LOG[#LOG + 1] = ok and s or tostring(fmt)
end

local function M210_BENCH()
local WHEAT, WHEAT_FILL = 14, 40
local LPA = 2.0
local DEPLETED, HEALTHY, CONTRACT = 22, 7, 9
local CUT = 10

-- ── the world: three fields side by side at z 50 ────────────────────────────
local WORLD = {}
local function resetWorld()
  WORLD.fields = {
    [DEPLETED] = { x0 = 0,   x1 = 100, fruit = WHEAT, standing = 1000 },
    [HEALTHY]  = { x0 = 200, x1 = 300, fruit = WHEAT, standing = 1000 },
    [CONTRACT] = { x0 = 400, x1 = 500, fruit = WHEAT, standing = 1000 },
  }
end
local function farmlandAt(x)
  for id, f in pairs(WORLD.fields) do if x >= f.x0 and x <= f.x1 then return id end end
  return 0
end
function getWorldTranslation(node) return node.x, 0, node.z end
g_fieldManager = { getFieldAtWorldPosition = function(_, x, _z)
  local id = farmlandAt(x)
  if id > 0 then return { farmland = { id = id } } end
  return nil
end }
g_farmlandManager = {
  getFarmlandAtWorldPosition = function(_, x, _z) local id = farmlandAt(x); return id > 0 and { id = id } or nil end,
  getFarmlandIdAtWorldPosition = function(_, x, _z) return farmlandAt(x) end,
  getFarmlandById = function() return nil end,
}
local function wheatDesc()
  return { index = WHEAT, name = "WHEAT", terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
           cutState = 9, numGrowthStates = 8, minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
           minForageGrowthState = 0, regrows = false, fillType = { title = "Wheat" },
           getIsCut = function() return false end, getIsWithered = function() return false end }
end
g_fruitTypeManager = {
  getFruitTypeByIndex = function(_, i) if i == WHEAT then return wheatDesc() end return nil end,
  getFruitTypeByName = function(_, n) if n == "WHEAT" then return wheatDesc() end return nil end,
  getFruitTypeAreaLiters = function(_, fruit, area, _w) if fruit ~= WHEAT then return 0 end return area * LPA end,
}
-- FSDensityMapUtil.getFruitArea: the harvestable area of a fruit under the work area.
FSDensityMapUtil = { getFruitArea = function(fruit, sx, _sz, ...)
  local f = WORLD.fields[farmlandAt(sx)]
  if f ~= nil and f.fruit == fruit and f.standing > 0 then return f.standing end
  return 0
end }

-- ── the vehicle side ────────────────────────────────────────────────────────
Cutter = {}
-- Cutter.lua:584-666: the cut over the start event's fruit list, the neutral harvest
-- multiplier, lastFruitType, the cumulative areas.
function Cutter:processCutterArea(workArea, _dt)
  local spec = self.spec_cutter
  if spec.workAreaParameters.combineVehicle == nil then return 0, 0 end
  local xs, _, _ = getWorldTranslation(workArea.start)
  local lastArea, lastMultiplierArea = 0, 0
  for _, fruitTypeIndex in ipairs(spec.workAreaParameters.fruitTypeIndicesToUse) do
    local f = WORLD.fields[farmlandAt(xs)]
    if f ~= nil and f.fruit == fruitTypeIndex and f.standing > 0 then
      local area = math.min(workArea.cut, f.standing)
      f.standing = f.standing - area
      lastArea = area
      lastMultiplierArea = area * 1.0
      spec.workAreaParameters.lastFruitType = fruitTypeIndex
      break
    end
  end
  spec.workAreaParameters.lastArea = spec.workAreaParameters.lastArea + lastArea
  spec.workAreaParameters.lastMultiplierArea = spec.workAreaParameters.lastMultiplierArea + lastMultiplierArea
  return spec.workAreaParameters.lastArea, 0
end
-- :729-768, with no required fill type.
function Cutter:onStartWorkAreaProcessing(_dt)
  local spec = self.spec_cutter
  spec.workAreaParameters.combineVehicle = self.combine
  spec.workAreaParameters.lastLiters = 0
  spec.workAreaParameters.lastArea = 0
  spec.workAreaParameters.lastMultiplierArea = 0
  if spec.workAreaParameters.lastFruitType == nil then
    spec.workAreaParameters.fruitTypeIndicesToUse = spec.fruitTypeIndices
  else
    spec.workAreaParameters.lastFruitTypeToUse = { spec.workAreaParameters.lastFruitType }
    spec.workAreaParameters.fruitTypeIndicesToUse = spec.workAreaParameters.lastFruitTypeToUse
  end
  spec.workAreaParameters.lastFruitType = nil
end
-- :770-840: the combine takes the litres of the (scaled) multiplier area.
function Cutter:onEndWorkAreaProcessing(_dt)
  if not self.isServer then return end
  local spec = self.spec_cutter
  if spec.workAreaParameters.lastArea > 0 and spec.workAreaParameters.combineVehicle ~= nil then
    local liters = g_fruitTypeManager:getFruitTypeAreaLiters(spec.workAreaParameters.lastFruitType,
      spec.workAreaParameters.lastMultiplierArea, false)
    spec.workAreaParameters.combineVehicle:addCutterArea(spec.workAreaParameters.lastArea, liters)
  end
end
Combine = {}
function Combine:addCutterArea(_area, liters) self.spec_combine.fill = self.spec_combine.fill + liters; return liters end

g_vehicleTypeManager = { types = {
  harvester = { specializationsByName = { cutter = true, combine = true, workArea = true },
                functions = { processCutterArea = Cutter.processCutterArea, addCutterArea = Combine.addCutterArea } },
} }
VehicleSystem = { addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v; return true end }

--- A harvester as FS25 holds it after load: functions copied from the type, the work
--- area's processingFunction captured from the instance (WorkArea.lua :266).
local function loadHarvester(x)
  local v = { isServer = true, typeName = "harvester", id = 1 }
  for name, fn in pairs(g_vehicleTypeManager.types.harvester.functions) do rawset(v, name, fn) end
  v.spec_cutter = { fruitTypeIndices = { WHEAT }, allowsForageGrowthState = false,
                    workAreaParameters = { lastArea = 0, lastMultiplierArea = 0, lastLiters = 0 } }
  v.spec_combine = { fill = 0 }
  v.combine = v
  local wa = { functionName = "processCutterArea", cut = CUT,
               start = { x = x, z = 50 }, width = { x = x + 1, z = 50 }, height = { x = x, z = 51 } }
  wa.processingFunction = v[wa.functionName]
  v.spec_workArea = { workAreas = { wa } }
  VehicleSystem.addVehicle(g_currentMission.vehicleSystem, v)
  return v
end
--- WorkArea:onUpdateTick's order. Returns the multiplier area this tick left standing.
local function tick(v)
  Cutter.onStartWorkAreaProcessing(v, 16)
  for _, wa in ipairs(v.spec_workArea.workAreas) do wa.processingFunction(v, wa, 16) end
  local area = v.spec_cutter.workAreaParameters.lastMultiplierArea
  Cutter.onEndWorkAreaProcessing(v, 16)
  return area
end

-- ── SoilFertilizer: the manager as production builds it ────────────────────
local W
local COUNT
local REAL_STANDING = HarvestContractUnderwrite.onStandingArea
local function counted(obj, name)
  local real = obj[name]
  obj[name] = function(...)
    COUNT[name] = (COUNT[name] or 0) + 1
    return real(...)
  end
end
local function fieldRecord(npk, om)
  return { pH = 7.0, nitrogen = npk, phosphorus = npk, potassium = npk, organicMatter = om,
           fieldArea = 2.0, lastHarvest = 0, nutrientBuffer = {} }
end
local function newWorld(opts)
  opts = opts or {}
  resetWorld()
  for k in pairs(LOG) do LOG[k] = nil end
  COUNT = {}
  g_server = {}
  g_currentMission = { vehicleSystem = { vehicles = {} }, getIsServer = function() return true end,
                       missionInfo = {}, time = 0 }
  local manager = {}
  local settings = Settings.new(manager)            -- the schema defaults
  if opts.experimental then settings.experimentalSystems = true end
  if opts.nutrientCycles == false then settings.nutrientCycles = false end
  local soil = setmetatable({
    settings = settings,
    fieldData = { [DEPLETED] = fieldRecord(5, 5), [HEALTHY] = fieldRecord(60, 4), [CONTRACT] = fieldRecord(5, 5) },
    lastUpdateDay = 0, herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
    harvestListeners = {},
  }, { __index = SoilFertilitySystem })
  -- The carrier, as SF-14 reads it on the open path: a yield efficiency of 95 everywhere.
  local vm = {
    available = true, resolution = 2048,
    getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1 } end,
    readAverageOfPolygon = function(_self, key, _verts, _filter)
      COUNT.readAverageOfPolygon = (COUNT.readAverageOfPolygon or 0) + 1
      if key == "yieldEfficiency" then return 95, 1 end
      return nil, 0
    end,
    readValueAtWorld = function(_self, key) if key == "yieldEfficiency" then return 95 end return nil end,
  }
  if opts.valueMaps ~= false then soil.valueMaps = vm end
  if opts.weeds then soil.fieldData[DEPLETED].weedPressure = opts.weeds end
  soil._getFarmlandPolygons = function() return {} end
  manager.settings = settings
  manager.soilSystem = soil
  manager.viability = { enabled = true, getCellGrowthInfo = function() return {} end }
  -- One source region per field under its work area (4 m grain: x0/4 by 50/4).
  manager.getGrowthEligibleRegionPlan = function(_self, fieldId)
    local f = WORLD.fields[fieldId]
    if f == nil then return nil end
    return { planId = "p" .. fieldId, planContentHash = "h", polygonUnionFingerprint = "g", carrierOwnershipHash = "o",
             farmlandInputRevision = 1, unscopedInputRevision = 1, settingsFingerprint = "", executionGrainMetres = 4,
             regions = { { key = math.floor(f.x0 / 4) .. ":12", sourcePolygonFingerprint = "fp" .. fieldId, blocked = false,
                           area = 16, carrierOwnerFarmlandId = fieldId, writableForFarmland = true } } }
  end
  g_SoilFertilityManager = manager
  manager.zoneYield = ZoneYield.new(manager)
  manager.zoneYield:initialize()
  for _, name in ipairs({ "_findReceipt", "_readYieldPolygon", "_readTrafficDragPolygon", "_sourcePolygonForWorkArea" }) do
    counted(manager.zoneYield, name)
  end
  if opts.contract then
    FieldSentry_API = { refreshContract = function() end,
                        isFieldSimDisabled = function(fieldId)
                          if fieldId == CONTRACT then return true, "npc", false, nil end
                          return false, nil, false, nil
                        end }
    FieldSentry_Core = { BLACKLIST = { NPC = "npc" } }
  else
    FieldSentry_API, FieldSentry_Core = nil, nil
  end
  -- The underwrite's standing pair, observed with every argument, then the real one.
  W = { manager = manager, soil = soil, settings = settings, zy = manager.zoneYield, standing = {} }
  -- always over the module's own function, so one world never records through another's spy
  HarvestContractUnderwrite.onStandingArea = function(cutterSelf, workArea, added, actual, ...)
    W.standing[#W.standing + 1] = { added = added, actual = actual, extra = select("#", ...) }
    return REAL_STANDING(cutterSelf, workArea, added, actual, ...)
  end
  W.restoreStanding = function() HarvestContractUnderwrite.onStandingArea = REAL_STANDING end
  W.v = loadHarvester(WORLD.fields[opts.field or DEPLETED].x0)
  local hm = HookManager.new()
  W.installed = hm:installZoneYieldCutterHook()
  return W
end
local function cutLines()
  local out = {}
  for _, l in ipairs(LOG) do if l:find("SF14_CUT", 1, true) then out[#out + 1] = l end end
  return out
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

-- Sauge's field by hand, independent of computeYieldModifier: N, P and K at 5 against the
-- optimum threshold 50 is a 0.9 deficit on a moderate (scale 1.0) crop, capped at the 0.50
-- maximum penalty, so 0.50; OM 5 earns the full +5 % humus bonus, so 1.05. Weed, pest and
-- disease pressures are 0 (no penalty in the low band).
local SAUGE = (1 - 0.50) * (1 + 0.05)

-- =====================================================================
-- G0. The gate is present and closed with the real settings
-- =====================================================================
group(function()
  newWorld({})
  T.eq("G0.1 [reached] the install wrapped the live work area", W.installed and HookManager._zoneYieldWrappers[W.v.spec_workArea.workAreas[1].processingFunction], true)
  T.eq("G0.2 the opt-in is PRESENT and false (the real Settings, schema defaults)", ReleaseGate.liveOptIn(), false)
  T.eq("G0.3 so the growth family is not live", ReleaseGate.isSystemLive("growth_modulation"), false)
  T.eq("G0.4 and ZoneYield says so", W.zy:isLive(), false)
  T.eq("G0.5 nutrient cycles are on by default", W.settings.nutrientCycles, true)
  local ys = SoilConstants.YIELD_SENSITIVITY
  T.ok("G0.6 the constants the hand derivation assumes (threshold 50, cap 0.50, OM bonus 0.05 at 5)",
       ys.OPTIMAL_THRESHOLD == 50 and ys.MAX_PENALTY == 0.50 and ys.OM_YIELD.BONUS_MAX == 0.05
       and ys.OM_YIELD.BONUS_THRESHOLD == 5.0 and ys.TIERS[ys.CROP_TIERS.wheat].scale == 1.0)
end)

-- =====================================================================
-- G1. Closed gate, Sauge's depleted field: scaled by the field-average scalar
-- =====================================================================
local OPEN_FALLBACK
group(function()
  newWorld({ experimental = true })
  local a = tick(W.v)
  OPEN_FALLBACK = a
  T.ok("G1.0 [reached] open gate, no receipt: the fallback scales the cut (" .. tostring(a) .. ")", near(a, CUT * SAUGE))
end)
group(function()
  newWorld({})
  local area = tick(W.v)
  T.ok("G1.1 NAMED: closed gate, the cut's multiplier area is the native 10 x 0.525 (" .. tostring(area) .. ")",
       near(area, CUT * SAUGE))
  T.ok("G1.2 NAMED: the same figure as the open-gate fallback on the same field", near(area, OPEN_FALLBACK))
  T.ok("G1.3 the combine took the scaled litres (" .. tostring(W.v.spec_combine.fill) .. ")",
       near(W.v.spec_combine.fill, CUT * SAUGE * LPA))
  W.restoreStanding()
end)

-- =====================================================================
-- G2. Closed gate: SF-14's own machinery stays inert
-- =====================================================================
group(function()
  newWorld({})
  tick(W.v)
  local lines = cutLines()
  T.ok("G2.1 NAMED: SF14_CUT reads path=fallback sf=0.525 (" .. tostring(lines[1]) .. ")",
       #lines == 1 and lines[1]:find("field=22 fruit=14 path=fallback", 1, true) ~= nil
       and lines[1]:find("sf=0.525", 1, true) ~= nil)
  T.eq("G2.2 NAMED: no receipt, source polygon, yield polygon or drag read, and no carrier read",
       (COUNT._findReceipt or 0) + (COUNT._readYieldPolygon or 0) + (COUNT._readTrafficDragPolygon or 0)
       + (COUNT._sourcePolygonForWorkArea or 0) + (COUNT.readAverageOfPolygon or 0), 0)
  T.eq("G2.3 no fallback entry and no receipt written", tostring(next(W.zy._fallbacks)) .. "/" .. tostring(next(W.zy._receipts)), "nil/nil")
  W.restoreStanding()
end)

-- =====================================================================
-- G3. Closed gate: the yield freezes at the first cut and holds through the harvest
-- =====================================================================
group(function()
  newWorld({})
  tick(W.v)
  local fd = W.soil.fieldData[DEPLETED]
  T.ok("G3.1 NAMED: the first cut froze the field's modifier at 0.525 for wheat",
       near(fd.frozenYieldModifier, SAUGE) and fd.frozenYieldFruitType == WHEAT)
  fd.nitrogen, fd.phosphorus, fd.potassium = 60, 60, 60      -- fertilised mid-harvest
  local area = tick(W.v)
  T.ok("G3.2 the next cut still takes the frozen 0.525, not the new N/P/K (" .. tostring(area) .. ")", near(area, CUT * SAUGE))
  W.restoreStanding()
end)

-- =====================================================================
-- G4. Closed gate, a contract field: scaled, and the underwrite measures it
-- =====================================================================
group(function()
  newWorld({ contract = true, field = CONTRACT })
  local area = tick(W.v)
  local lines = cutLines()
  T.ok("G4.1 [reached] the contract path (" .. tostring(lines[1]) .. ")", lines[1] ~= nil and lines[1]:find("path=contract", 1, true) ~= nil)
  T.ok("G4.2 NAMED: the contract field's cut is scaled by its frozen scalar", near(area, CUT * SAUGE))
  local s = W.standing[1]
  T.ok("G4.3 NAMED: the underwrite's standing pair is (native, scaled), so its inverse engages",
       #W.standing == 1 and near(s.added, CUT) and near(s.actual, CUT * SAUGE) and s.extra == 0)
  W.restoreStanding()
end)

-- =====================================================================
-- G5. Open gate: the spatial path and the fallback, as SF-14 built them (regression)
-- =====================================================================
group(function()
  newWorld({ experimental = true })
  W.zy._receipts[ZoneYield.receiptKey(DEPLETED, "fp" .. DEPLETED, WHEAT)] = {
    farmlandId = DEPLETED, sourcePolygonFingerprint = "fp" .. DEPLETED, fruitTypeIndex = WHEAT, status = ZoneYield.STATUS_READY,
  }
  local area = tick(W.v)
  local lines = cutLines()
  T.ok("G5.1 a READY receipt: the spatial path, the carrier's 0.95 (" .. tostring(lines[1]) .. ")",
       lines[1] ~= nil and lines[1]:find("path=spatial", 1, true) ~= nil and near(area, CUT * 0.95))
  T.ok("G5.2 [reached] it read the receipt and the yield polygon", (COUNT._findReceipt or 0) >= 1 and (COUNT.readAverageOfPolygon or 0) >= 1)
  T.ok("G5.2b the spatial path still takes the field's crop freeze, as SF-14 built it",
       near(W.soil.fieldData[DEPLETED].frozenYieldModifier, SAUGE))
  W.restoreStanding()
  newWorld({ experimental = true })
  area = tick(W.v)
  lines = cutLines()
  T.ok("G5.3 no receipt: the fallback path, the field-average 0.525", lines[1] ~= nil
       and lines[1]:find("path=fallback", 1, true) ~= nil and near(area, CUT * SAUGE))
  W.restoreStanding()
end)

-- =====================================================================
-- G6. Nutrient cycles off: the baseline applies nothing on the non-spatial path. The field
--     carries peak weed pressure, which computeYieldModifier would still charge with
--     nutrient cycles off; the pre-SF-14 hopper hook applied nothing at all then.
-- =====================================================================
group(function()
  newWorld({ nutrientCycles = false, weeds = 100 })
  local wouldCharge = W.soil:_yieldModifierFromNutrients(W.soil.fieldData[DEPLETED], "wheat", 5, 5, 5, nil)
  T.ok("G6.0 [reached] with nutrient cycles off the weeds alone would still cut the yield (" .. tostring(wouldCharge) .. ")",
       type(wouldCharge) == "number" and wouldCharge < 1)
  local area = tick(W.v)
  T.ok("G6.1 NAMED: closed gate, nutrient cycles off: the native cut, unscaled (" .. tostring(area) .. ")", near(area, CUT))
  T.eq("G6.2 and no freeze is taken", W.soil.fieldData[DEPLETED].frozenYieldModifier, nil)
  W.restoreStanding()
  newWorld({ nutrientCycles = false, experimental = true, weeds = 100 })
  area = tick(W.v)
  T.ok("G6.3 NAMED: open gate, no receipt, nutrient cycles off: unscaled (" .. tostring(area) .. ")", near(area, CUT))
  T.eq("G6.3b and no freeze is taken", W.soil.fieldData[DEPLETED].frozenYieldModifier, nil)
  W.restoreStanding()
  newWorld({ nutrientCycles = false, experimental = true, weeds = 100 })
  W.zy._receipts[ZoneYield.receiptKey(DEPLETED, "fp" .. DEPLETED, WHEAT)] = {
    farmlandId = DEPLETED, sourcePolygonFingerprint = "fp" .. DEPLETED, fruitTypeIndex = WHEAT, status = ZoneYield.STATUS_READY,
  }
  area = tick(W.v)
  T.ok("G6.4 the spatial path is SF-14's own and still scales (0.95)", near(area, CUT * 0.95))
  W.restoreStanding()
end)

-- =====================================================================
-- G7. Open gate, value maps unavailable: the fallback context, scaled, never nil
-- =====================================================================
group(function()
  newWorld({ experimental = true, valueMaps = false })
  local area = tick(W.v)
  local lines = cutLines()
  T.ok("G7.1 NAMED: no value maps: path=fallback, scaled 0.525 (" .. tostring(lines[1]) .. ")",
       lines[1] ~= nil and lines[1]:find("path=fallback", 1, true) ~= nil and near(area, CUT * SAUGE))
  W.restoreStanding()
end)

-- =====================================================================
-- T. The harvest hook's debug line
-- =====================================================================
group(function()
  local src = SOURCE_TEXT["src/hooks/HookManager.lua"] or ""
  T.ok("T1 the harvest hook's debug line names the cutter, not the retired hopper hook",
       src:find("(yield modifier applied at the cutter)", 1, true) ~= nil and src:find("via hopper hook", 1, true) == nil)
end)
end

local GROUP_N = 0
function group(fn)
  GROUP_N = GROUP_N + 1
  local ok, err = pcall(fn)
  if not ok then T.ok("group " .. GROUP_N .. " ran to its end without a Lua error", false, tostring(err)) end
end
M210_BENCH()
