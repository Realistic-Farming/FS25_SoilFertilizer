-- RSF-F196-catalogue_wiring_test.lua: the identity catalogue is built by PRODUCTION,
-- not by the fixture.
--
-- THE DEFECT THIS PINS. #974 introduced customProductIndices as the one identity
-- fact and made every consumer read it: the external-fill charge (R3a), the FillUnit
-- purchase intercept, the backup refill, and every refusal fed by the resolver (R2
-- itself, R3b, R3a's refusal, the opt-in refusal). Its only writer,
-- rebuildCustomProductCatalogue, had ONE caller in the repository: a bench. At
-- runtime the catalogue was {} and every custom product resolved as not custom, so
-- custom-product billing was OFF and the density refusal COULD NOT FIRE. Three bars
-- did not see it because each supplied the catalogue itself (one called the rebuild,
-- two set the table by hand). A bench proves the mechanism GIVEN its inputs and can
-- never ask where the inputs come from, so this bar starts from production's own
-- entry point: registerCustomSprayTypes, called at install and on every retry, and
-- populates NOTHING by hand. Then it drives the real consumers.
--
-- Fixture indices start at 100 so they never collide with the FillType sentinels.
-- Densities are the engine's tonnes per litre. GYPSUM is declared with a NONSENSE
-- density on purpose: the shipped GYPSUM is 1.10 kg/L and valid; this is the
-- synthetic refused product the refusal half of the bar needs.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = {
  Sprayer = Sprayer, Utils = Utils, FillType = FillType, ToolType = ToolType, FillUnit = FillUnit, MoneyType = MoneyType, UIHelper = UIHelper,
  g_currentMission = g_currentMission, g_fillTypeManager = g_fillTypeManager, g_sprayTypeManager = g_sprayTypeManager,
  g_SoilFertilityManager = g_SoilFertilityManager, g_farmManager = g_farmManager, g_vehicleTypeManager = g_vehicleTypeManager,
  g_i18n = g_i18n, warning = SoilLogger.warning,
}

Utils = {
  prependedFunction = function(orig, new) return function(...) new(...) if orig then return orig(...) end end end,
  appendedFunction  = function(orig, new) return function(...) local r = orig and { orig(...) } or {} new(...) return unpack(r) end end,
  overwrittenFunction = function(orig, new) return function(...) return new(orig, ...) end end,
}
FillType  = { UNKNOWN = 0, FERTILIZER = 1, LIQUIDFERTILIZER = 2 }
ToolType  = { UNDEFINED = 0 }
MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1, OTHER = 2 }
UIHelper  = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }   -- the charge log formats the cost
FillUnit  = { addFillUnitFillLevel = function() return 0 end }
g_farmManager = { updateFarmStats = function() end }
g_vehicleTypeManager = { types = {} }
g_i18n = { hasText = function() return false end, getText = function(_, k) return k end }

-- ── the fill-type world: what the loader declared, nothing else ───────────────
local declared = {}          -- name -> massPerLiter (t/L); nil = not loaded yet
local IDX, nextIdx = {}, 100
local function indexOf(name)
  if IDX[name] == nil then IDX[name] = nextIdx; nextIdx = nextIdx + 1 end
  return IDX[name]
end
local function descOf(name)
  if declared[name] == nil then return nil end
  return { name = name, index = indexOf(name), massPerLiter = declared[name], title = name }
end
g_fillTypeManager = {
  getFillTypeByName      = function(_, n) return descOf(n) end,
  getFillTypeIndexByName = function(_, n) if declared[n] == nil then return nil end return indexOf(n) end,
  getFillTypeByIndex     = function(_, i) for n in pairs(declared) do if IDX[n] == i then return descOf(n) end end return nil end,
}
local added = {}
g_sprayTypeManager = {
  getSprayTypeByName = function(_, n)
    if n == "FERTILIZER" then return { litersPerSecond = 0.006, sprayGroundType = 3 } end
    if n == "LIQUIDFERTILIZER" then return { litersPerSecond = 0.0081, sprayGroundType = 2 } end
    return nil
  end,
  addSprayType = function(_, n, lps) added[n] = lps; return {} end,
  -- The billing wrapper sizes the charge from the registered spray type; none is
  -- registered here, so it falls back to its own default, which is what a bar that
  -- proves identity and charging (not the litre figure) needs.
  getSprayTypeByFillTypeIndex      = function() return nil end,
  getSprayTypeIndexByFillTypeIndex = function() return nil end,
}
local blendNames = {}
SoilBlends.appendNames(blendNames)
local BLEND = blendNames[1]

-- ── the world the hooks reach for ────────────────────────────────────────────
local money, notices, warnings = {}, {}, {}
local function newWorld()
  money, notices, warnings = {}, {}, {}
  g_currentMission = {
    time = 1000,
    missionInfo = { helperBuyFertilizer = true, helperSlurrySource = 1, helperManureSource = 1 },
    addMoney = function(_, amount, farmId, kind) money[#money + 1] = { amount = amount, farmId = farmId, kind = kind } end,
    vehicleSystem = { vehicles = {} },
  }
  local soilSys = { showNotification = function(_, title, body) notices[#notices + 1] = { title = title, body = body } end }
  g_SoilFertilityManager = { settings = { enabled = true, showNotifications = true }, soilSystem = soilSys }
  SoilLogger.warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
  return HookManager.new()   -- NOTHING populated by hand from here on
end

-- ── the engine model (Sprayer.lua:855-931, :314-320, :938-942), as the refusal bar has it ──
local nativeCalls = 0
local function nativeGetExternalFill(self, fillType, dt)
  nativeCalls = nativeCalls + 1
  if fillType == FillType.UNKNOWN then return FillType.FERTILIZER, 10 end   -- the #205 cascade
  return fillType, 10
end
local function nativeOnStart(self, dt)
  local wap = self.spec_sprayer.workAreaParameters
  local fui = self:getSprayerFillUnitIndex()
  local sprayVehicle, sprayType, level = self, self:getFillUnitFillType(fui), self:getFillUnitFillLevel(fui)
  local externalType, externalUsage = sprayType, level
  if level <= 0 then
    externalType, externalUsage = self:getExternalFill(FillType.UNKNOWN, dt)   -- Sprayer.lua:889, R3a's point
    sprayVehicle = nil
  end
  local usage = externalUsage > 0 and 0.5 or 0
  wap.sprayFillType, wap.sprayFillLevel, wap.usage, wap.usagePerMin = externalType, externalUsage, usage, usage / dt * 1000 * 60
  wap.sprayVehicle, wap.sprayVehicleFillUnitIndex = sprayVehicle, fui
end
local function nativePaint(self)
  if self.spec_sprayer.workAreaParameters.sprayFillLevel <= 0 then return 0 end
  self._painted = (self._painted or 0) + 1
  return 1
end
local function nativeDrain(self)
  local u = self.spec_sprayer.workAreaParameters.usage
  if u and u > 0 then self._tank.level = self._tank.level - u end
end
local function newSprayer(tankType, level)
  local v = { isServer = true, id = 7, lastSpeed = 0.003, _tank = { type = tankType, level = level } }
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function(self) return self._tank.type end
  v.getFillUnitFillLevel = function(self) return self._tank.level end
  v.getFillUnitLastValidFillType = function(self) return self._tank.type end
  v.getFillUnitAllowsFillType = function() return true end
  v.getActiveFarm = function() return 1 end
  v.getLastTouchedFarmlandFarmId = function() return 1 end
  v.getActiveSprayType = function() return nil end
  v.getExternalFill = nativeGetExternalFill
  v.spec_sprayer = { usageScale = { workingWidth = 12, default = 1 },
                     workAreaParameters = { sprayFillType = FillType.UNKNOWN, sprayFillLevel = 0, usage = 0, usagePerMin = 0 } }
  g_currentMission.vehicleSystem.vehicles = { v }   -- listed BEFORE propagation (Hook 9's gap)
  return v
end
local function installHooks(hm)
  nativeCalls = 0
  Sprayer = { getExternalFill = nativeGetExternalFill, onStartWorkAreaProcessing = nativeOnStart,
              processSprayerArea = nativePaint, onEndWorkAreaProcessing = nativeDrain }
  HookManager.installExternalFillHook(hm)
  HookManager.propagateExternalFillHookToLiveVehicles(hm)
  HookManager.installDensityRefusalHook(hm)
end
local function frame(v)
  Sprayer.onStartWorkAreaProcessing(v, 16)
  Sprayer.processSprayerArea(v)
  Sprayer.onEndWorkAreaProcessing(v, 16)
end

-- =====================================================================
-- GROUP A: production's own registration builds the catalogue. No hand population.
-- =====================================================================
declared = { UREA = 0.00077, GYPSUM = -0.001, STARTER = 0.001, FERTILIZER = 0.001 }
declared[BLEND] = 0.001
local hmA = newWorld()
T.eq("WIRE A0: a fresh manager has an EMPTY catalogue", next(hmA.customProductIndices), nil)
local okReg, errReg = pcall(HookManager.registerCustomSprayTypes, hmA)
T.ok("WIRE A1: production registration ran (" .. tostring(errReg) .. ")", okReg)
T.eq("WIRE A2: UREA (dry) is a custom product after registration alone",   hmA:isCustomProduct(indexOf("UREA")), true)
T.eq("WIRE A3: STARTER (liquid) is a custom product",                      hmA:isCustomProduct(indexOf("STARTER")), true)
T.eq("WIRE A4: a tank mix (" .. tostring(BLEND) .. ") is a custom product", hmA:isCustomProduct(indexOf(BLEND)), true)
T.eq("WIRE A5: base-game FERTILIZER is NOT",                               hmA:isCustomProduct(indexOf("FERTILIZER")), false)
T.eq("WIRE A6: a dry name the loader never declared (POTASH) is NOT",      hmA:isCustomProduct(indexOf("POTASH")), false)
T.eq("WIRE A7: GYPSUM with a nonsense density is REFUSED",                 hmA:isRefusedProduct(indexOf("GYPSUM")), true)
T.eq("WIRE A8: and still a MEMBER: identity and refusal are two facts",     hmA:isCustomProduct(indexOf("GYPSUM")), true)
T.eq("WIRE A9: registration was PARTIAL (most names undeclared) and the catalogue was still built", hmA._sprayTypesComplete, false)

-- =====================================================================
-- GROUP B: V12a, the retry. A fill type that resolves late is a product the
-- moment it exists, because the rebuild runs on every registration attempt.
-- =====================================================================
declared = { STARTER = 0.001 }
local hmB = newWorld()
pcall(HookManager.registerCustomSprayTypes, hmB)
T.eq("WIRE B1: UREA not yet loaded: not a product", hmB:isCustomProduct(indexOf("UREA")), false)
declared.UREA = 0.00077
pcall(HookManager.registerCustomSprayTypes, hmB)   -- the dedi retry
T.eq("WIRE B2: UREA loaded on the retry: a product now", hmB:isCustomProduct(indexOf("UREA")), true)
T.eq("WIRE B3: STARTER survived the rebuild", hmB:isCustomProduct(indexOf("STARTER")), true)

-- =====================================================================
-- GROUP C: REAL billing on a catalogue built by production. The price map is
-- built by the real purchase hook; the empty UREA tank makes native ask
-- getExternalFill, where R3a either identifies UREA or delegates to the cascade.
-- =====================================================================
declared = { UREA = 0.00077, GYPSUM = -0.001, STARTER = 0.001, FERTILIZER = 0.001 }
local hmC = newWorld()
pcall(HookManager.registerCustomSprayTypes, hmC)
local okPrices, errPrices = pcall(HookManager.installPurchaseRefillHook, hmC)
T.ok("WIRE C0: the real purchase hook built the price map (" .. tostring(errPrices) .. ")", okPrices)
T.ok("WIRE C1: UREA has a price from production's own build", type(hmC.customFillTypePrices[indexOf("UREA")]) == "number" and hmC.customFillTypePrices[indexOf("UREA")] > 0)
-- The sprayer is built and listed BEFORE the hooks are installed: Hook 9's propagation
-- replaces the instance copy of getExternalFill only on vehicles the mission lists at
-- that moment. The first draft built it after and exercised native's copy, which is
-- the gap propagation exists to close and the same slip the refusal bar's first draft made.
local vC = newSprayer(indexOf("UREA"), 0)   -- an emptied UREA tank: buy mode
installHooks(hmC)
frame(vC)
T.eq("WIRE C2: the external fill is identified as UREA, not the cascade's FERTILIZER", vC.spec_sprayer.workAreaParameters.sprayFillType, indexOf("UREA"))
T.eq("WIRE C3: native's cascade was never consulted", nativeCalls, 0)
T.ok("WIRE C4: the helper was CHARGED for it", #money >= 1 and money[1].amount < 0)
T.ok("WIRE C5: and the dose was armed", vC.spec_sprayer.workAreaParameters.sprayFillLevel > 0)

-- =====================================================================
-- GROUP D: Bob's row. A synthetic refused product, registered for real, and R2
-- proven to zero the dose. With an empty catalogue the resolver returns nil and
-- R2 returns before it looks, so this is the half a hand-populated fixture hides.
-- =====================================================================
local hmD = newWorld()
pcall(HookManager.registerCustomSprayTypes, hmD)
local vD = newSprayer(indexOf("GYPSUM"), 100)   -- a full tank of the refused product, listed before install
installHooks(hmD)
frame(vD)
T.eq("WIRE D1: R2 zeroed the usage of the refused product", vD.spec_sprayer.workAreaParameters.usage, 0)
T.eq("WIRE D2: and the fill level, so native painted nothing", vD._painted, nil)
T.eq("WIRE D3: and native drained nothing", vD._tank.level, 100)
T.eq("WIRE D4: the farmer was told once (V18)", #notices, 1)
frame(vD)
T.eq("WIRE D5: told once only", #notices, 1)
T.eq("WIRE D6: a VALID product on the same manager is untouched by R2", (function()
  local vOk = newSprayer(indexOf("UREA"), 100); frame(vOk); return vOk.spec_sprayer.workAreaParameters.usage end)(), 0.5)

-- ── restore ──
Sprayer, Utils, FillType, ToolType, FillUnit, MoneyType, UIHelper = saved.Sprayer, saved.Utils, saved.FillType, saved.ToolType, saved.FillUnit, saved.MoneyType, saved.UIHelper
g_currentMission, g_fillTypeManager, g_sprayTypeManager = saved.g_currentMission, saved.g_fillTypeManager, saved.g_sprayTypeManager
g_SoilFertilityManager, g_farmManager, g_vehicleTypeManager, g_i18n = saved.g_SoilFertilityManager, saved.g_farmManager, saved.g_vehicleTypeManager, saved.g_i18n
SoilLogger.warning = saved.warning
