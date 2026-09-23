-- RSF-F196-r7_drain_vehicle_test.lua: clause R7, explicit recovery from remembered refused
-- intent through the Drain Vehicle console command.
--
-- WHAT R7 REPAIRS. consoleCommandDrainVehicle scanned a private 22-name list (AN and
-- POLIFOSKA missing), refunded `level * price * 0.5` computed BEFORE the drain call
-- without checking what actually left, and never touched the fill unit's remembered
-- product (lastValidFillType, FillUnit.lua:1158-1162: set on every fill, kept when the
-- unit empties, the thing the helper's next purchase is steered by). A refused product
-- (R1a) in a unit therefore stayed remembered after the drain, and the helper kept
-- being pointed at a product it may never buy.
--
-- Now: the twelve dry products join the set from HookManager.DRY_PRODUCT_NAMES (one
-- catalogue, no second list); the refund is what ACTUALLY left, read after the call; a
-- unit verified empty whose current or remembered product was refused forgets it
-- (setFillUnitLastValidFillType(fuIdx, FillType.UNKNOWN), FillUnit.lua:1277-1285); an
-- already-empty unit remembering a refused product is cleared with no drain and no
-- refund; a partial drain, a valid product's natural empty, an unrelated product and a
-- remembered VALID product are never cleared; money and the clear stay behind the
-- isServer gate.
--
-- WHO POPULATES THE WORLD. The refused table comes from production's own
-- registerCustomSprayTypes over a fill-type manager whose GYPSUM carries a nonsense
-- density (R1a, the way #974's bar populated it); nothing sets refusedProducts by hand.
-- The vehicle fixture mirrors FillUnit.lua:1135-1162 (level mutation, last-valid set on
-- a positive level and kept on empty, fillType to UNKNOWN on empty) and :1277-1285
-- (the setter raises the dirty flag). ENTRY-POINT BAR: every group drives the real
-- SoilSettingsGUI.consoleCommandDrainVehicle.
--
-- What this bar does NOT prove: the engine's own access and support checks inside
-- addFillUnitFillLevel, the dirty stream to clients, and the helper purchase reading
-- the cleared last-valid. The TESTING row.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/SoilFertilitySystem.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/hooks/HookManager.lua, src/settings/SoilSettingsGUI.lua

local saved = { FillType = FillType, ToolType = ToolType, MoneyType = MoneyType, UIHelper = UIHelper,
                g_currentMission = g_currentMission, g_fillTypeManager = g_fillTypeManager, g_sprayTypeManager = g_sprayTypeManager,
                g_SoilFertilityManager = g_SoilFertilityManager, g_localPlayer = g_localPlayer, print = print,
                info = SoilLogger.info, warning = SoilLogger.warning, debug = SoilLogger.debug, DRY = HookManager.DRY_PRODUCT_NAMES }
FillType  = { UNKNOWN = 0 }
ToolType  = { UNDEFINED = 0 }
MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1 }
UIHelper  = { formatCurrencyValue = function(v) return string.format("$%.2f", v) end }
g_localPlayer = nil
SoilLogger.info = function() end; SoilLogger.warning = function() end; SoilLogger.debug = function() end

-- ── the fill-type world: GYPSUM declares a nonsense density, so R1a refuses it ────
local declared = { UREA = 0.00077, AN = 0.0008, POLIFOSKA = 0.0009, GYPSUM = -0.001, STARTER = 0.001, FERTILIZER = 0.001, LIQUIDFERTILIZER = 0.001 }
local IDX, nextIdx = {}, 100
local function indexOf(name) if IDX[name] == nil then IDX[name] = nextIdx; nextIdx = nextIdx + 1 end return IDX[name] end
local function descOf(name) if declared[name] == nil then return nil end return { name = name, index = indexOf(name), massPerLiter = declared[name], title = name } end
g_fillTypeManager = {
  getFillTypeByName      = function(_, n) return descOf(n) end,
  getFillTypeIndexByName = function(_, n) if declared[n] == nil then return nil end return indexOf(n) end,
  getFillTypeByIndex     = function(_, i) for n in pairs(declared) do if IDX[n] == i then return descOf(n) end end return nil end,
}
g_sprayTypeManager = {
  getSprayTypeByName = function(_, n)
    if n == "FERTILIZER" then return { litersPerSecond = 0.006, sprayGroundType = 3 } end
    if n == "LIQUIDFERTILIZER" then return { litersPerSecond = 0.0081, sprayGroundType = 2 } end
    return nil
  end,
  addSprayType = function() return {} end,
  getSprayTypeByFillTypeIndex = function() return nil end,
  getSprayTypeIndexByFillTypeIndex = function() return nil end,
}
local UREA, AN, POLI, GYP, STARTER, FERT = indexOf("UREA"), indexOf("AN"), indexOf("POLIFOSKA"), indexOf("GYPSUM"), indexOf("STARTER"), indexOf("FERTILIZER")

-- ── the vehicle, as FillUnit.lua has it ──────────────────────────────────────────
local function newVehicle(units, opts)
  opts = opts or {}
  local v = { id = 1, spec_fillUnit = { fillUnits = units }, _dirty = 0, _fillCalls = 0 }
  v.getOwnerFarmId = function() return 1 end
  v.getAttachedImplements = function() return {} end
  v.getFillUnitLastValidFillType = function(self, i) local fu = self.spec_fillUnit.fillUnits[i]; if fu == nil then return nil end return fu.lastValidFillType end
  v.setFillUnitLastValidFillType = function(self, i, ft)
    local fu = self.spec_fillUnit.fillUnits[i]
    if fu ~= nil and fu.lastValidFillType ~= ft then fu.lastValidFillType = ft; fu.lastValidFillTypeSent = ft; self._dirty = self._dirty + 1 end
  end
  -- FillUnit.lua:1135-1162, the level path for a matching fill type.
  v.addFillUnitFillLevel = opts.addFillUnitFillLevel or function(self, farmId, i, delta, ft)
    self._fillCalls = self._fillCalls + 1
    local fu = self.spec_fillUnit.fillUnits[i]
    if fu == nil then return 0 end
    if fu.fillType == ft then fu.fillLevel = math.max(0, fu.fillLevel + delta)
    elseif delta > 0 then fu.fillLevel = delta; fu.fillType = ft end
    if fu.fillLevel < 0.00001 then fu.fillLevel = 0 end
    if fu.fillLevel > 0 then fu.lastValidFillType = fu.fillType else fu.fillType = FillType.UNKNOWN end
    return delta
  end
  return v
end
local function unit(ft, level, lastValid) return { fillType = ft, fillLevel = level, lastValidFillType = lastValid, capacity = 1000 } end

local money, printed
local function newWorld(vehicle, isServer)
  money, printed = {}, {}
  g_currentMission = {
    controlledVehicle = vehicle,
    getIsServer = function() return isServer ~= false end,
    addMoney = function(_, amount, farmId, kind) money[#money + 1] = { amount = amount, farmId = farmId, kind = kind } end,
  }
  local hm = HookManager.new()
  g_SoilFertilityManager = { settings = {}, soilSystem = { hookManager = hm } }
  local ok, err = pcall(HookManager.registerCustomSprayTypes, hm)   -- R1a fills the refused table
  return hm, ok, err
end
local function run()
  print = function(s) printed[#printed + 1] = tostring(s) end
  local ok, out = pcall(SoilSettingsGUI.consoleCommandDrainVehicle, SoilSettingsGUI)
  print = saved.print
  if not ok then error(out, 0) end
  return out
end
local function refundFor(idx, liters)
  local FALLBACK = { UREA = 1.65, AN = 1.55, POLIFOSKA = 1.35, GYPSUM = 0.80 }   -- the command's own table; AN and POLIFOSKA fall to 1.0 there
  return liters * 0.5 * (idx == UREA and 1.65 or idx == GYP and 0.80 or 1.0)
end

-- =====================================================================
-- GROUP W: the world is populated by production (no hand-set refusal).
-- =====================================================================
do
  local hm, ok, err = newWorld(newVehicle({}), true)
  T.ok("R7 W0: production registration ran (" .. tostring(err) .. ")", ok)
  T.eq("R7 W1: GYPSUM is REFUSED by the real R1a path (nonsense density)", hm:isRefusedProduct(GYP), true)
  T.eq("R7 W2: UREA is a valid custom product", hm:isRefusedProduct(UREA), false)
  T.eq("R7 W3: the twelve dry products are the catalogue this command unions in", #HookManager.DRY_PRODUCT_NAMES, 12)
end

-- =====================================================================
-- GROUP A: a refused product with material: drained, refund = what actually left,
-- the remembered product cleared.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(GYP, 300, GYP) })
  newWorld(v, true)
  local out = run()
  T.eq("R7 A1: the unit drained to zero", v.spec_fillUnit.fillUnits[1].fillLevel, 0)
  T.eq("R7 A2: one refund", #money, 1)
  T.near("R7 A3: for the drained amount at 50% of the price", money[1] and money[1].amount, refundFor(GYP, 300), 1e-9)
  T.eq("R7 A4: the remembered refused product is CLEARED to UNKNOWN", v.spec_fillUnit.fillUnits[1].lastValidFillType, FillType.UNKNOWN)
  T.eq("R7 A5: through the engine setter (dirty flag raised once)", v._dirty, 1)
  T.ok("R7 A6: the report names the drained amount, not the pre-level alone", out:find("300 of 300", 1, true) ~= nil and out:find("forgotten", 1, true) ~= nil)
  T.ok("R7 A7: the summary counts the forgotten product", out:find("Refused products forgotten: 1", 1, true) ~= nil)
end

-- =====================================================================
-- GROUP B: already empty, current UNKNOWN, a refused product remembered: cleared with
-- no drain call and no refund.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(FillType.UNKNOWN, 0, GYP) })
  newWorld(v, true)
  local out = run()
  T.eq("R7 B1: no drain call was made", v._fillCalls, 0)
  T.eq("R7 B2: no refund", #money, 0)
  T.eq("R7 B3: the remembered refused product is cleared", v.spec_fillUnit.fillUnits[1].lastValidFillType, FillType.UNKNOWN)
  T.eq("R7 B4: dirty flag raised once", v._dirty, 1)
  T.ok("R7 B5: the report says so", out:find("empty, remembered refused product forgotten", 1, true) ~= nil)
end

-- =====================================================================
-- GROUP C: a valid product: drained and refunded, the remembered product KEPT.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(UREA, 200, UREA) })
  newWorld(v, true)
  run()
  T.eq("R7 C1: drained", v.spec_fillUnit.fillUnits[1].fillLevel, 0)
  T.near("R7 C2: refunded for 200 at UREA's price", money[1] and money[1].amount, refundFor(UREA, 200), 1e-9)
  T.eq("R7 C3: a valid product's natural empty keeps its remembered product", v.spec_fillUnit.fillUnits[1].lastValidFillType, UREA)
  T.eq("R7 C4: no setter call", v._dirty, 0)
end

-- =====================================================================
-- GROUP D: AN and POLIFOSKA are drained now; a control on the old list shows they were not.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(AN, 100, AN), [2] = unit(POLI, 100, POLI) })
  newWorld(v, true)
  run()
  T.eq("R7 D1: AN is drained", v.spec_fillUnit.fillUnits[1].fillLevel, 0)
  T.eq("R7 D2: POLIFOSKA is drained", v.spec_fillUnit.fillUnits[2].fillLevel, 0)
  T.eq("R7 D3: both refunded (at the existing fallback rule, 1.0/L for names without a price entry)", #money, 2)
end
do
  local v = newVehicle({ [1] = unit(AN, 100, AN), [2] = unit(POLI, 100, POLI) })
  newWorld(v, true)
  HookManager.DRY_PRODUCT_NAMES = nil                        -- CONTROL: the old list alone
  local out = run()
  HookManager.DRY_PRODUCT_NAMES = saved.DRY
  T.eq("R7 D4: control, old list only: AN is NOT drained", v.spec_fillUnit.fillUnits[1].fillLevel, 100)
  T.eq("R7 D5: control: POLIFOSKA is NOT drained", v.spec_fillUnit.fillUnits[2].fillLevel, 100)
  T.ok("R7 D6: control: the command reports nothing found", out:find("No custom fertilizer found", 1, true) ~= nil)
end

-- =====================================================================
-- GROUP E: a SWALLOWED drain (the untokened BUY intercept before V13 returned without
-- calling native): refund 0, no clear.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(GYP, 300, GYP) }, { addFillUnitFillLevel = function(self) self._fillCalls = self._fillCalls + 1; return 0 end })
  newWorld(v, true)
  local out = run()
  T.eq("R7 E1: the drain call was made", v._fillCalls, 1)
  T.eq("R7 E2: nothing left the unit", v.spec_fillUnit.fillUnits[1].fillLevel, 300)
  T.eq("R7 E3: refund 0 (no money moved)", #money, 0)
  T.eq("R7 E4: no clear: the unit is not verified empty", v.spec_fillUnit.fillUnits[1].lastValidFillType, GYP)
  T.ok("R7 E5: the report says 0 of 300", out:find("0 of 300", 1, true) ~= nil)
end

-- =====================================================================
-- GROUP F: a PARTIAL drain: refund = the partial amount, no clear.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(GYP, 300, GYP) }, { addFillUnitFillLevel = function(self, farmId, i, delta, ft)
    self._fillCalls = self._fillCalls + 1
    local fu = self.spec_fillUnit.fillUnits[i]; fu.fillLevel = fu.fillLevel + delta * 0.5; return delta * 0.5 end })
  newWorld(v, true)
  run()
  T.eq("R7 F1: half left the unit", v.spec_fillUnit.fillUnits[1].fillLevel, 150)
  T.near("R7 F2: refund for the 150 that left, not the 300 that was there", money[1] and money[1].amount, refundFor(GYP, 150), 1e-9)
  T.eq("R7 F3: no clear on a partial drain", v.spec_fillUnit.fillUnits[1].lastValidFillType, GYP)
end

-- =====================================================================
-- GROUP G: an empty unit remembering a VALID custom product is untouched; an unrelated
-- non-empty product is untouched.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(FillType.UNKNOWN, 0, UREA), [2] = unit(FERT, 100, FERT) })
  newWorld(v, true)
  local out = run()
  T.eq("R7 G1: a remembered VALID product stays remembered", v.spec_fillUnit.fillUnits[1].lastValidFillType, UREA)
  T.eq("R7 G2: an unrelated product is not drained", v.spec_fillUnit.fillUnits[2].fillLevel, 100)
  T.eq("R7 G3: no drain call, no money, no setter", v._fillCalls + #money + v._dirty, 0)
  T.ok("R7 G4: the command reports nothing found", out:find("No custom fertilizer found", 1, true) ~= nil)
end

-- =====================================================================
-- GROUP H: a client (isServer false): no money, no clear, no drain, logged only.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(GYP, 300, GYP), [2] = unit(FillType.UNKNOWN, 0, GYP) })
  newWorld(v, false)
  local out = run()
  T.eq("R7 H1: client: no drain call", v._fillCalls, 0)
  T.eq("R7 H2: client: no money", #money, 0)
  T.ok("R7 H3: client: nothing cleared on either unit", v.spec_fillUnit.fillUnits[1].lastValidFillType == GYP and v.spec_fillUnit.fillUnits[2].lastValidFillType == GYP and v._dirty == 0)
  T.ok("R7 H4: client: the report says not host", out:find("not host", 1, true) ~= nil)
end

FillType, ToolType, MoneyType, UIHelper = saved.FillType, saved.ToolType, saved.MoneyType, saved.UIHelper
g_currentMission, g_fillTypeManager, g_sprayTypeManager, g_SoilFertilityManager, g_localPlayer = saved.g_currentMission, saved.g_fillTypeManager, saved.g_sprayTypeManager, saved.g_SoilFertilityManager, saved.g_localPlayer
SoilLogger.info, SoilLogger.warning, SoilLogger.debug = saved.info, saved.warning, saved.debug
HookManager.DRY_PRODUCT_NAMES = saved.DRY
