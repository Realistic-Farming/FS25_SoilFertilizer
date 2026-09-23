-- RSF-F196-owned_layer_test.lua: clauses V12c (the owned registered-function layer)
-- and V13 (the native-drain token), one PR.
--
-- FINDING 1, the reason this bar looks the way it does: a registered specialization
-- function is COPIED. finalizeTypes reads the class function into every vehicle type's
-- functions table at game boot (TypeManager.lua:185-199), and Vehicle:load copies the
-- type table onto each instance (SpecializationUtil.copyTypeFunctionsInto :141-145,
-- from Vehicle.lua:486). This mod installs at mission load, after both copies, so the
-- purchase-refill class hook reached NO loaded vehicle: "BUY SUCCESS (FillUnit hook)"
-- could not fire in production. A bar that calls the CLASS proves nothing. Every row
-- here calls vehicle:addFillUnitFillLevel on an INSTANCE whose slot was copied from a
-- type table BEFORE the installer ran.
--
-- THE WORLD, built the way finalizeTypes and Vehicle:load build it: FillUnit and Sprayer
-- class tables with the engine functions; one type whose addFillUnitFillLevel is
-- Utils.overwrittenFunction(FillUnitOrig, SowingMachineFn) (the SowingMachine.lua:84
-- overwriter, one of the engine's six), one type with the bare FillUnitOrig, one type
-- without the fillUnit spec; instances copied from the type tables. Then the mod's own
-- install sequence for these hooks, in installAll's order, with NOTHING populated by
-- hand: identity comes from registerCustomSprayTypes (#977's wiring), the price map
-- from installPurchaseRefillHook, the layers from the installers themselves.
--
-- Native is modelled where the mod cannot supply it: Sprayer:onEndWorkAreaProcessing
-- as at Sprayer.lua:938-957 (the drain call at :950, six arguments, receiver the SPRAY
-- VEHICLE, which here is a DIFFERENT vehicle from the sprayer), Utils.prepended /
-- appended / overwrittenFunction verbatim from Utils.lua:380-400, and FillUnit's
-- addFillUnitFillLevel as a level mutator that records every call.
--
-- What this bar does NOT prove: engine dispatch of the event, the real backup refill
-- (installSprayerAreaHook needs the whole sprayer world; A3 is pinned by the stamp and
-- the 200 ms window the backup refill reads), the real SoilDrainVehicle command (A4 is
-- driven as the call shape it makes on a BUY vehicle), and the constant-remap wrapper
-- (group R models its swap around native). The TESTING row carries the rest.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = {
  Sprayer = Sprayer, Utils = Utils, FillType = FillType, ToolType = ToolType, FillUnit = FillUnit, MoneyType = MoneyType,
  UIHelper = UIHelper, SprayType = SprayType, g_currentMission = g_currentMission, g_fillTypeManager = g_fillTypeManager,
  g_sprayTypeManager = g_sprayTypeManager, g_SoilFertilityManager = g_SoilFertilityManager, g_farmManager = g_farmManager,
  g_vehicleTypeManager = g_vehicleTypeManager, g_i18n = g_i18n, warning = SoilLogger.warning, debug = SoilLogger.debug,
}

-- The engine's own composition helpers, verbatim in behaviour (Utils.lua:380-400).
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
FillType  = { UNKNOWN = 0, FERTILIZER = 1, LIQUIDFERTILIZER = 2 }
SprayType = { FERTILIZER = 1, LIQUIDFERTILIZER = 2 }
ToolType  = { UNDEFINED = 0 }
MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1, OTHER = 2 }
UIHelper  = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }
g_farmManager = { updateFarmStats = function() end }
g_i18n = { hasText = function() return false end, getText = function(_, k) return k end }
local warnings = {}
SoilLogger.warning = function(fmt, ...) local ok, s = pcall(string.format, fmt, ...); warnings[#warnings + 1] = ok and s or tostring(fmt) end
SoilLogger.debug = function() end

-- ── the fill-type world ───────────────────────────────────────────────────────
local declared = { UREA = 0.00077, STARTER = 0.001, FERTILIZER = 0.001, LIQUIDFERTILIZER = 0.001 }
local IDX, nextIdx = {}, 100
local function indexOf(name) if IDX[name] == nil then IDX[name] = nextIdx; nextIdx = nextIdx + 1 end return IDX[name] end
local function descOf(name) if declared[name] == nil then return nil end return { name = name, index = indexOf(name), massPerLiter = declared[name], title = name } end
g_fillTypeManager = {
  getFillTypeByName      = function(_, n) return descOf(n) end,
  getFillTypeIndexByName = function(_, n) if declared[n] == nil then return nil end return indexOf(n) end,
  getFillTypeByIndex     = function(_, i) for n in pairs(declared) do if IDX[n] == i then return descOf(n) end end return nil end,
}
local STM = { registered = {} }
function STM:getSprayTypeByName(n)
  if n == "FERTILIZER" then return { litersPerSecond = 0.006, sprayGroundType = 3, index = 1 } end
  if n == "LIQUIDFERTILIZER" then return { litersPerSecond = 0.0081, sprayGroundType = 2, index = 2 } end
  return self.registered[n]
end
function STM:addSprayType(n, lps, typeName, ground) self.registered[n] = { name = n, index = 10 + #self.registered, litersPerSecond = lps, typeName = typeName }; return self.registered[n] end
function STM:getSprayTypeByFillTypeIndex(i) for n, st in pairs(self.registered) do if IDX[n] == i then return st end end return nil end
function STM:getSprayTypeIndexByFillTypeIndex(i) local st = self:getSprayTypeByFillTypeIndex(i); return st and st.index or nil end
g_sprayTypeManager = STM
local UREA, STARTER, FERT = indexOf("UREA"), indexOf("STARTER"), indexOf("FERTILIZER")

-- ── the engine: FillUnit, one overwriter, Sprayer's native end ───────────────
local fuCalls, order = {}, {}
local function FillUnitOrig(vehicle, farmId, fuIdx, delta, ft, toolType, fillPositionData)
  fuCalls[#fuCalls + 1] = { veh = vehicle.id, fuIdx = fuIdx, delta = delta, ft = ft, unload = fillPositionData }
  order[#order + 1] = "fillunit"
  local fu = vehicle.spec_fillUnit.fillUnits[fuIdx]
  if delta == -math.huge then fu.fillLevel = 0 else fu.fillLevel = math.max(0, fu.fillLevel + delta) end
  return delta
end
local function SowingMachineFn(vehicle, superFunc, farmId, fuIdx, delta, ft, toolType, fpd)
  order[#order + 1] = "sowing"
  return superFunc(vehicle, farmId, fuIdx, delta, ft, toolType, fpd)
end
local function nativeGetExternalFill(self, fillType, dt) if fillType == FillType.UNKNOWN then return FillType.FERTILIZER, 10 end return fillType, 10 end
local function nativeIsExternallyFilled() return false end
-- Sprayer.lua:938-957: the drain at :950, six arguments, on the SPRAY VEHICLE.
local function nativeOnEnd(self, dt)
  local spec = self.spec_sprayer
  if self.isServer and spec.workAreaParameters.isActive then
    local sprayVehicle = spec.workAreaParameters.sprayVehicle
    local usage = spec.workAreaParameters.usage
    if sprayVehicle ~= nil then
      sprayVehicle:addFillUnitFillLevel(self:getOwnerFarmId(), spec.workAreaParameters.sprayVehicleFillUnitIndex, -usage,
        spec.workAreaParameters.sprayFillType, ToolType.UNDEFINED, "unloadInfo")
    end
  end
end
local function resetEngine()
  fuCalls, order = {}, {}
  FillUnit = { addFillUnitFillLevel = FillUnitOrig, onPostLoad = function() end }
  Sprayer  = { getExternalFill = nativeGetExternalFill, getIsSprayerExternallyFilled = nativeIsExternallyFilled, onEndWorkAreaProcessing = nativeOnEnd }
  -- finalizeTypes: the types read the CLASS functions at boot (FillUnit.lua:197, Sprayer.lua:81-82)
  g_vehicleTypeManager = { types = {
    sowingSprayer = { specializationsByName = { sprayer = true, fillUnit = true, sowingMachine = true },
                      functions = { addFillUnitFillLevel = Utils.overwrittenFunction(FillUnit.addFillUnitFillLevel, SowingMachineFn),
                                    getExternalFill = Sprayer.getExternalFill, getIsSprayerExternallyFilled = Sprayer.getIsSprayerExternallyFilled } },
    tank          = { specializationsByName = { fillUnit = true },
                      functions = { addFillUnitFillLevel = FillUnit.addFillUnitFillLevel } },
    plow          = { specializationsByName = { plow = true }, functions = { onLoad = function() end } },
  } }
end
-- Vehicle:load, SpecializationUtil.copyTypeFunctionsInto: the instance gets raw copies.
local money
local function newVehicle(id, typeName, tankType, level, opts)
  opts = opts or {}
  local v = { id = id, isServer = opts.isServer ~= false, ownerFarmId = 1,
              spec_fillUnit = { fillUnits = { [1] = { fillLevel = level, fillType = tankType } } },
              spec_aiVehicle = { isActive = opts.ai == true }, typeName = typeName }
  for name, fn in pairs(g_vehicleTypeManager.types[typeName].functions) do v[name] = fn end
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
  v.getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end
  v.getFillUnitLastValidFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end
  v.getOwnerFarmId = function() return 1 end
  v.getIsAIActive = function(self) return self.spec_aiVehicle.isActive end
  v.getIsFieldWorkActive = function() return true end
  v.rootVehicle = v
  return v
end
local function newSprayer(id, target, usage, fillType, opts)
  opts = opts or {}
  local s = newVehicle(id, "sowingSprayer", FillType.UNKNOWN, 0, opts)
  s.spec_sprayer = { workAreaParameters = { isActive = opts.active ~= false, sprayVehicle = target, usage = usage,
                                            sprayVehicleFillUnitIndex = 1, sprayFillType = fillType } }
  return s
end
local function newWorld()
  resetEngine()
  money, warnings = {}, {}
  g_currentMission = {
    time = 1000,
    missionInfo = { helperBuyFertilizer = true, helperSlurrySource = 1, helperManureSource = 1 },
    addMoney = function(_, amount, farmId, kind) money[#money + 1] = { amount = amount, farmId = farmId, kind = kind } end,
    vehicleSystem = { vehicles = {} },
  }
  g_SoilFertilityManager = { settings = { enabled = true, showNotifications = true }, soilSystem = {} }
  return HookManager.new()
end
-- The mod's own install sequence for these hooks, in installAll's order.
local function installSequence(hm)
  local ok1, e1 = pcall(HookManager.installPurchaseRefillHook, hm)
  local ok2, e2 = pcall(HookManager.installExternalFillHook, hm)
  local ok3, e3 = pcall(HookManager.installExternalFillOptInHook, hm)
  local ok4, e4 = pcall(HookManager.registerCustomSprayTypes, hm)
  local ok5, e5 = pcall(HookManager.installDrainTokenHook, hm)
  return ok1 and ok2 and ok3 and ok4 and ok5, tostring(e1) .. "|" .. tostring(e2) .. "|" .. tostring(e3) .. "|" .. tostring(e4) .. "|" .. tostring(e5)
end
local function price(name) return HookManager.customPriceFor and HookManager.customPriceFor(name) or nil end

-- =====================================================================
-- GROUP A: the world is what finalizeTypes and Vehicle:load make (finding 1).
-- =====================================================================
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500)
  local sower = newVehicle(2, "sowingSprayer", UREA, 500)
  T.ok("OL A1: an instance's slot is a RAW copy of its type's function, not the class function", rawget(tank, "addFillUnitFillLevel") == g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel)
  T.ok("OL A2: the sowing type's slot is the composed chain, not FillUnit's bare function", rawget(sower, "addFillUnitFillLevel") ~= FillUnitOrig)
  -- The old shape, simulated: a CLASS-only patch reaches neither instance.
  local reached = 0
  FillUnit.addFillUnitFillLevel = function(...) reached = reached + 1 return FillUnitOrig(...) end
  tank:addFillUnitFillLevel(1, 1, -1, UREA, 0, nil); sower:addFillUnitFillLevel(1, 1, -1, UREA, 0, nil)
  T.eq("OL A3: a class-level patch after the copies reaches NO loaded vehicle (why the old hook never fired)", reached, 0)
end

-- =====================================================================
-- GROUP B: the owned layer, installed from the mod's own installers.
-- =====================================================================
local B = {}
do
  local hm = newWorld()
  local tank  = newVehicle(1, "tank", UREA, 500)
  local sower = newVehicle(2, "sowingSprayer", UREA, 500)
  local plow  = newVehicle(3, "plow", FillType.UNKNOWN, 0)
  g_currentMission.vehicleSystem.vehicles = { tank, sower, plow }
  local typeTankPred = g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel
  local typeSowPred  = g_vehicleTypeManager.types.sowingSprayer.functions.addFillUnitFillLevel
  local ok, err = installSequence(hm)
  T.ok("OL B0: the install sequence ran (" .. err .. ")", ok)
  local layer = hm._f196Layers and hm._f196Layers.addFillUnitFillLevel
  T.ok("OL B1: the FillUnit layer exists with an owner record", layer ~= nil and layer.owner == "F196")
  T.ok("OL B2: the CLASS slot is wrapped", hm:isOwnedLayerWrapper(FillUnit.addFillUnitFillLevel))
  T.ok("OL B3: every fillUnit TYPE's slot is wrapped, around the function that was there",
       hm:isOwnedLayerWrapper(g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel)
       and hm:isOwnedLayerWrapper(g_vehicleTypeManager.types.sowingSprayer.functions.addFillUnitFillLevel))
  T.ok("OL B4: the plow type (no fillUnit spec) is untouched", g_vehicleTypeManager.types.plow.functions.addFillUnitFillLevel == nil)
  T.ok("OL B5: every live instance's raw slot is wrapped", hm:isOwnedLayerWrapper(rawget(tank, "addFillUnitFillLevel")) and hm:isOwnedLayerWrapper(rawget(sower, "addFillUnitFillLevel")))
  T.ok("OL B6: an instance whose raw pointer equalled its type's predecessor REUSES the type wrapper (one wrapper per type, not per vehicle)",
       rawget(tank, "addFillUnitFillLevel") == g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel
       and rawget(sower, "addFillUnitFillLevel") == g_vehicleTypeManager.types.sowingSprayer.functions.addFillUnitFillLevel)
  T.ok("OL B7: the records hold the predecessors (the composed chain for the sowing type)",
       (function() for _, r in ipairs(layer.refs) do if r.slot == g_vehicleTypeManager.types.sowingSprayer.functions and r.predecessor == typeSowPred then return true end end return false end)())
  T.eq("OL B8: references: class, two types, two instances reusing the type wrappers = 5 records", #layer.refs, 5)
  T.ok("OL B9: getExternalFill and getIsSprayerExternallyFilled got their own layers on the sprayer type and instance",
       hm:isOwnedLayerWrapper(rawget(sower, "getExternalFill")) and hm:isOwnedLayerWrapper(rawget(sower, "getIsSprayerExternallyFilled"))
       and hm:isOwnedLayerWrapper(g_vehicleTypeManager.types.sowingSprayer.functions.getExternalFill))
  T.ok("OL B10: the tank type (no sprayer spec) got no sprayer layers", g_vehicleTypeManager.types.tank.functions.getExternalFill == nil)
  T.ok("OL B11: the drain token hook is the outermost wrapper on Sprayer.onEndWorkAreaProcessing", Sprayer.onEndWorkAreaProcessing ~= nativeOnEnd)
  B.hm, B.tank, B.sower, B.typeTankPred, B.typeSowPred = hm, tank, sower, typeTankPred, typeSowPred
end

-- =====================================================================
-- GROUP C: THE ENTRY-POINT BAR. Native's own drain, from onEndWorkAreaProcessing on a
-- sprayer whose spray vehicle is a DIFFERENT vehicle, reaches that vehicle's INSTANCE
-- slot; in BUY mode the layer charges and the tank is untouched (V13).
-- =====================================================================
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })      -- the AI helper's spray vehicle, BUY
  local sprayer = newSprayer(2, tank, 2.5, UREA)                       -- the sprayer, target = tank
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  installSequence(hm)
  T.ok("OL C0: UREA has a price from production's own build", type(hm.customFillTypePrices[UREA]) == "number")
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL C1: BUY: the farm was charged exactly once", #money, 1)
  T.near("OL C2: for usage x price on farm 1", money[1] and -money[1].amount, 2.5 * hm.customFillTypePrices[UREA], 1e-9)
  T.eq("OL C3: on the spray vehicle's farm", money[1] and money[1].farmId, 1)
  T.eq("OL C4: the TANK is untouched (native's drain became a purchase)", tank.spec_fillUnit.fillUnits[1].fillLevel, 500)
  T.eq("OL C5: the predecessor chain was NOT called for that delta", #fuCalls, 0)
  T.eq("OL C6: the CHARGE SITE is the layer (A3)", hm._f196LayerCharges, 1)
  T.eq("OL C7: and the layer stamped the vehicle so the backup refill's 200 ms window reads handled (A3)", tank._soilBuyHandledAt, g_currentMission.time)
  T.ok("OL C8: the backup refill's own test, (time - stamp) < 200, is true right now and false 200 ms later",
       (g_currentMission.time - tank._soilBuyHandledAt) < 200 and not ((g_currentMission.time + 200 - tank._soilBuyHandledAt) < 200))
  T.eq("OL C9: the token was consumed", tank._sfF196DrainToken, nil)
  -- Registration in this partial world warns about undeclared names and the LIQUIDLIME
  -- override, as it does on a real partial load; the layer itself must add none.
  T.eq("OL C10: the layer raised no warning of its own", (function() local n = 0 for _, w in ipairs(warnings) do if w:find("F196", 1, true) or w:find("layer", 1, true) then n = n + 1 end end return n end)(), 0)
end
do
  -- NOT BUY: native's drain delegates to the predecessor and the tank drains.
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = false })
  local sprayer = newSprayer(2, tank, 2.5, UREA)
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  installSequence(hm)
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL C11: not BUY: no money moved", #money, 0)
  T.near("OL C12: not BUY: the predecessor drained the tank by the usage", tank.spec_fillUnit.fillUnits[1].fillLevel, 497.5, 1e-9)
  T.ok("OL C13: not BUY: the predecessor saw the six-argument call with unloadInfo passed through", #fuCalls == 1 and fuCalls[1].unload == "unloadInfo" and fuCalls[1].ft == UREA)
  T.eq("OL C14: the token was consumed even though nothing was billed", tank._sfF196DrainToken, nil)
end
do
  -- THE CHAIN IS PRESERVED: on the sowing type, SowingMachine runs with its superFunc and
  -- F196 sits outside it. Not BUY so the delta reaches the chain.
  local hm = newWorld()
  local sower = newVehicle(2, "sowingSprayer", UREA, 500, { ai = false })
  local sprayer = newSprayer(3, sower, 1.0, UREA)
  g_currentMission.vehicleSystem.vehicles = { sower, sprayer }
  installSequence(hm)
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL C15: the call order is SowingMachine then FillUnit (F196 outside the chain, never bypassing it)", table.concat(order, ","), "sowing,fillunit")
  T.near("OL C16: and the sower drained", sower.spec_fillUnit.fillUnits[1].fillLevel, 499.0, 1e-9)
end

-- =====================================================================
-- GROUP D: every UNTOKENED delta delegates, even on a BUY vehicle.
-- =====================================================================
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
  g_currentMission.vehicleSystem.vehicles = { tank }
  installSequence(hm)
  tank:addFillUnitFillLevel(1, 1, -math.huge, UREA, ToolType.UNDEFINED, nil)          -- emptyAllFillUnits / a settings drain
  T.eq("OL D1: -math.huge on a BUY vehicle delegates: no money", #money, 0)
  T.eq("OL D2: and the tank emptied through the predecessor", tank.spec_fillUnit.fillUnits[1].fillLevel, 0)
  tank.spec_fillUnit.fillUnits[1].fillLevel = 0.0005
  tank:addFillUnitFillLevel(1, 1, -0.0005, UREA, ToolType.UNDEFINED, nil)             -- the residual snap's shape (:4427-4446)
  T.eq("OL D3: a snap-sized delta delegates: no money", #money, 0)
  T.eq("OL D4: and the snap drained", tank.spec_fillUnit.fillUnits[1].fillLevel, 0)
  tank.spec_fillUnit.fillUnits[1].fillLevel = 300
  tank:addFillUnitFillLevel(1, 1, -300, UREA, ToolType.UNDEFINED)                     -- SoilDrainVehicle's call shape (A4)
  T.eq("OL D5: A4: SoilDrainVehicle's call on a BUY vehicle really drains", tank.spec_fillUnit.fillUnits[1].fillLevel, 0)
  T.eq("OL D6: A4: and charges nothing", #money, 0)
  tank:addFillUnitFillLevel(1, 1, 200, UREA, ToolType.UNDEFINED, nil)                 -- a fill
  T.eq("OL D7: a positive delta delegates and fills", tank.spec_fillUnit.fillUnits[1].fillLevel, 200)
  T.eq("OL D8: every one of those reached the predecessor", #fuCalls, 4)
end
do
  -- A live token with a NON-matching delta does not bill: the match is exact. The token is
  -- set by hand here, modelling what the prepend stores, because native never sends a
  -- mismatched delta on its own.
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
  g_currentMission.vehicleSystem.vehicles = { tank }
  installSequence(hm)
  tank._sfF196DrainToken = { fuIdx = 1, delta = -2.5, fillType = UREA }   -- hand-set: models the prepend's output
  tank:addFillUnitFillLevel(1, 1, -1.0, UREA, ToolType.UNDEFINED, nil)
  T.eq("OL D9: a delta that does not match the token exactly delegates: no money", #money, 0)
  T.near("OL D10: and drains", tank.spec_fillUnit.fillUnits[1].fillLevel, 499.0, 1e-9)
  T.ok("OL D11: the token is still live (not consumed by a non-match)", tank._sfF196DrainToken ~= nil)
  tank:addFillUnitFillLevel(1, 1, -2.5, STARTER, ToolType.UNDEFINED, nil)
  T.eq("OL D12: same delta, different fill type: no money", #money, 0)
  tank:addFillUnitFillLevel(1, 1, -2.5, UREA, ToolType.UNDEFINED, nil)
  T.eq("OL D13: the exact match bills", #money, 1)
  T.eq("OL D14: and consumes the token", tank._sfF196DrainToken, nil)
end

-- =====================================================================
-- GROUP E: the token exists only under isServer, isActive and a spray vehicle.
-- =====================================================================
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
  local sprayer = newSprayer(2, tank, 2.5, UREA, { isServer = false })     -- a pure client
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  installSequence(hm)
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL E1: a client creates no token and bills nothing", #money, 0)
  T.eq("OL E2: and native (gated on isServer too) drains nothing", tank.spec_fillUnit.fillUnits[1].fillLevel, 500)
end
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
  local sprayer = newSprayer(2, tank, 2.5, UREA, { active = false })       -- work not active
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  installSequence(hm)
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL E3: isActive false: no token, no money", #money, 0)
  T.eq("OL E4: and no token left on the vehicle", tank._sfF196DrainToken, nil)
end
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
  local sprayer = newSprayer(2, nil, 2.5, UREA)                            -- external fill: sprayVehicle nil
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  installSequence(hm)
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL E5: sprayVehicle nil (external fill never drains): no token, no money", #money, 0)
end
do
  -- WHAT NATIVE SEES. The gates above are also native's own gates, so a token minted in
  -- a client, inactive or vehicle-less frame would be cleared by the append before any
  -- row could see it. These rows put a spy where native runs (inside the token hook's
  -- prepend and append) and record the token as native would find it.
  local function spyWorld(opts)
    local hm = newWorld()
    local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
    local target = tank
    if opts.target == false then target = nil end
    local sprayer = newSprayer(2, target, 2.5, UREA, opts)
    g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
    local seen = { present = "unset" }
    local inner = Sprayer.onEndWorkAreaProcessing
    Sprayer.onEndWorkAreaProcessing = function(self, dt)
      seen.present = tank._sfF196DrainToken
      inner(self, dt)
    end
    installSequence(hm)
    Sprayer.onEndWorkAreaProcessing(sprayer, 16)
    return seen.present
  end
  local active = spyWorld({})
  T.ok("OL E8: an active server frame with a spray vehicle: native sees the token, holding exactly its own call (fuIdx 1, -usage, fill type)",
       type(active) == "table" and active.fuIdx == 1 and active.delta == -2.5 and active.fillType == UREA)
  T.eq("OL E9: isActive false: native sees NO token (the guard, not the append, kept it out)", spyWorld({ active = false }), nil)
  T.eq("OL E10: a client frame: native sees NO token", spyWorld({ isServer = false }), nil)
  T.eq("OL E11: no spray vehicle: nothing to token", spyWorld({ target = false }), nil)
end
do
  -- A propagation miss: the spray vehicle's slot is NOT the layer (a later owner replaced
  -- it with something that swallows the call). Native's call reaches no wrapper, so the
  -- append clears the unused token.
  local hm = newWorld()
  local tank = newVehicle(1, "tank", UREA, 500, { ai = true })
  local sprayer = newSprayer(2, tank, 2.5, UREA)
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  installSequence(hm)
  tank.addFillUnitFillLevel = function() end                               -- swallowed
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL E6: a swallowed drain bills nothing", #money, 0)
  T.eq("OL E7: and the append cleared the unused token (the guard for a propagation miss)", tank._sfF196DrainToken, nil)
end

-- =====================================================================
-- GROUP F: one layer per slot across a registration retry; a late vehicle gets exactly
-- one wrapper through onPostLoad; an already-wrapped vehicle gets none.
-- =====================================================================
do
  -- Its own world: the groups above reset the engine tables for theirs.
  local hm = newWorld()
  local tank  = newVehicle(1, "tank", UREA, 500)
  local sower = newVehicle(2, "sowingSprayer", UREA, 500)
  g_currentMission.vehicleSystem.vehicles = { tank, sower }
  installSequence(hm)
  local before = { rawget(tank, "addFillUnitFillLevel"), rawget(sower, "addFillUnitFillLevel"),
                   g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel, FillUnit.addFillUnitFillLevel }
  local refsBefore = #hm._f196Layers.addFillUnitFillLevel.refs
  local catalogueBefore = hm.customProductIndices
  HookManager.registerCustomSprayTypes(hm)                                -- the dedi retry
  HookManager.registerCustomSprayTypes(hm)
  T.ok("OL F1: after two more registration attempts every wrapper is the SAME function (one layer per slot)",
       rawget(tank, "addFillUnitFillLevel") == before[1] and rawget(sower, "addFillUnitFillLevel") == before[2]
       and g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel == before[3] and FillUnit.addFillUnitFillLevel == before[4])
  T.eq("OL F2: and the record count did not grow", #hm._f196Layers.addFillUnitFillLevel.refs, refsBefore)
  T.ok("OL F3: while the identity table was swapped beneath (the rebuild ran)", hm.customProductIndices ~= catalogueBefore)
  T.ok("OL F4: a second installer call returns the existing layer and wraps nothing more",
       hm:installOwnedRegisteredFunctionLayer(FillUnit, "addFillUnitFillLevel", function(p) return p end, "fillUnit") == hm._f196Layers.addFillUnitFillLevel
       and #hm._f196Layers.addFillUnitFillLevel.refs == refsBefore)
  -- A LATE vehicle: copied from the already-wrapped type table (Vehicle.lua:486), then onPostLoad (:905).
  HookManager.installFillUnitHookEarly(hm)
  local late = newVehicle(4, "tank", UREA, 100)
  T.ok("OL F5: a late vehicle's raw copy IS the type wrapper already", hm:isOwnedLayerWrapper(rawget(late, "addFillUnitFillLevel")))
  FillUnit.onPostLoad(late)
  T.ok("OL F6: onPostLoad gives it nothing more (already wrapped): same function, no new record",
       rawget(late, "addFillUnitFillLevel") == before[3] and #hm._f196Layers.addFillUnitFillLevel.refs == refsBefore)
  -- A late vehicle carrying an UNWRAPPED raw copy (its type was never patched: no fillUnit spec
  -- in specializationsByName, but the function is there anyway).
  local odd = newVehicle(5, "tank", UREA, 100)
  rawset(odd, "addFillUnitFillLevel", FillUnitOrig)
  FillUnit.onPostLoad(odd)
  T.ok("OL F7: onPostLoad gives an unwrapped late vehicle exactly one wrapper", hm:isOwnedLayerWrapper(rawget(odd, "addFillUnitFillLevel")))
  T.eq("OL F8: one new record", #hm._f196Layers.addFillUnitFillLevel.refs, refsBefore + 1)
  local w = rawget(odd, "addFillUnitFillLevel")
  FillUnit.onPostLoad(odd)
  T.ok("OL F9: a second onPostLoad wraps nothing (same function, same count)", rawget(odd, "addFillUnitFillLevel") == w and #hm._f196Layers.addFillUnitFillLevel.refs == refsBefore + 1)
  T.ok("OL F10: the compatibility re-sweep (the old propagate name) wraps nothing more on a settled world", hm:propagateExternalFillHookToLiveVehicles() == 0)
end

-- =====================================================================
-- GROUP G: cleanup restores a slot still holding the wrapper and leaves one a later
-- owner replaced.
-- =====================================================================
do
  local hm = newWorld()
  local tank  = newVehicle(1, "tank", UREA, 500)
  local sower = newVehicle(2, "sowingSprayer", UREA, 500)
  g_currentMission.vehicleSystem.vehicles = { tank, sower }
  local typeTankPred = g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel
  local typeSowPred  = g_vehicleTypeManager.types.sowingSprayer.functions.addFillUnitFillLevel
  installSequence(hm)
  local later = function() end
  sower.addFillUnitFillLevel = later                                        -- a later owner took the sower's slot
  hm.installed = true
  hm:uninstallAll()
  T.ok("OL G1: the class slot is restored to the engine function", FillUnit.addFillUnitFillLevel == FillUnitOrig)
  T.ok("OL G2: the tank type's slot is restored to its predecessor", g_vehicleTypeManager.types.tank.functions.addFillUnitFillLevel == typeTankPred)
  T.ok("OL G3: the sowing type's slot is restored to the composed chain it held", g_vehicleTypeManager.types.sowingSprayer.functions.addFillUnitFillLevel == typeSowPred)
  T.ok("OL G4: the tank instance is restored to its raw predecessor", rawget(tank, "addFillUnitFillLevel") == typeTankPred)
  T.ok("OL G5: the slot a later owner replaced is LEFT to that owner", rawget(sower, "addFillUnitFillLevel") == later)
  T.ok("OL G6: Sprayer.onEndWorkAreaProcessing is native again", Sprayer.onEndWorkAreaProcessing == nativeOnEnd)
  T.ok("OL G7: the sprayer layers are gone from the type", g_vehicleTypeManager.types.sowingSprayer.functions.getExternalFill == nativeGetExternalFill)
  T.eq("OL G8: the layer records are released", hm._f196Layers and hm._f196Layers.addFillUnitFillLevel, nil)
end

-- =====================================================================
-- GROUP R: the constant-remap wrapper (HookManager.lua:1208-1245) swaps the GLOBAL
-- FillType/SprayType tables around native for a custom liquid and never touches wap.
-- Modelled here as that swap around native, with the token prepend outermost: the token
-- still matches native's call exactly.
-- =====================================================================
do
  local hm = newWorld()
  local tank = newVehicle(1, "tank", STARTER, 500, { ai = true })
  local sprayer = newSprayer(2, tank, 3.0, STARTER)
  g_currentMission.vehicleSystem.vehicles = { tank, sprayer }
  -- the remap wrapper's shape, installed BEFORE the token hook (as installAll orders them)
  local origOnEnd = Sprayer.onEndWorkAreaProcessing
  Sprayer.onEndWorkAreaProcessing = function(self, ...)
    local origFT = FillType
    local newFT = {}; for k, v in pairs(origFT) do newFT[k] = v end; newFT.LIQUIDFERTILIZER = STARTER
    FillType = newFT
    origOnEnd(self, ...)
    FillType = origFT
  end
  installSequence(hm)
  Sprayer.onEndWorkAreaProcessing(sprayer, 16)
  T.eq("OL R1: through the remap swap, native's drain for a custom liquid still matched the token: charged once", #money, 1)
  T.near("OL R2: for usage x STARTER's price", money[1] and -money[1].amount, 3.0 * hm.customFillTypePrices[STARTER], 1e-9)
  T.eq("OL R3: the tank untouched", tank.spec_fillUnit.fillUnits[1].fillLevel, 500)
  T.ok("OL R4: the global FillType table is back to the original after the frame", FillType.LIQUIDFERTILIZER == 2)
end

Sprayer, Utils, FillType, ToolType, FillUnit, MoneyType, UIHelper, SprayType = saved.Sprayer, saved.Utils, saved.FillType, saved.ToolType, saved.FillUnit, saved.MoneyType, saved.UIHelper, saved.SprayType
g_currentMission, g_fillTypeManager, g_sprayTypeManager = saved.g_currentMission, saved.g_fillTypeManager, saved.g_sprayTypeManager
g_SoilFertilityManager, g_farmManager, g_vehicleTypeManager, g_i18n = saved.g_SoilFertilityManager, saved.g_farmManager, saved.g_vehicleTypeManager, saved.g_i18n
SoilLogger.warning, SoilLogger.debug = saved.warning, saved.debug
