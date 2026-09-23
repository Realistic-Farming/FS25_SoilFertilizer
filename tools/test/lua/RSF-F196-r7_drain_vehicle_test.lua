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
--!text: src/settings/SoilSettingsGUI.lua, fillTypes.xml

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
local declared = { UREA = 0.00077, AN = 0.0008, POLIFOSKA = 0.0009, GYPSUM = -0.001, STARTER = 0.001, LIQUID_UREA = 0.0011, FERTILIZER = 0.001, LIQUIDFERTILIZER = 0.001 }
-- The fillTypes.xml economy price each fill type carries (FillTypeDesc.pricePerLiter,
-- FillTypeDesc.lua:75). The fixture WITHHOLDS STARTER's price (the real fillTypes.xml has
-- 0.90) so it can stand for a fill type that declares no economy and holds the engine
-- default 0; every other price here must equal the real XML (group J pins that).
local prices = { UREA = 0.55, AN = 0.50, POLIFOSKA = 0.60, GYPSUM = 0.10, STARTER = 0, LIQUID_UREA = 0.60, FERTILIZER = 0.30, LIQUIDFERTILIZER = 0.30 }
local IDX, nextIdx = {}, 100
local function indexOf(name) if IDX[name] == nil then IDX[name] = nextIdx; nextIdx = nextIdx + 1 end return IDX[name] end
local function nameOf(idx) for n, i in pairs(IDX) do if i == idx then return n end end return nil end
local function descOf(name) if declared[name] == nil then return nil end return { name = name, index = indexOf(name), massPerLiter = declared[name], title = name, pricePerLiter = prices[name] } end
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
local LUREA = indexOf("LIQUID_UREA")

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
--- Tyson's ruling 2026-09-23: refund = drained x the fill type's SHOP price x 0.5.
local function refundFor(idx, liters)
  return liters * 0.5 * (prices[nameOf(idx)] or 0)
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
  T.eq("R7 D3: both refunded", #money, 2)
  T.near("R7 D3b: AN at its shop price (100 x 0.50 x 0.5), no fallback rule", money[1] and money[1].amount, refundFor(AN, 100), 1e-9)
  T.near("R7 D3c: POLIFOSKA at its shop price (100 x 0.60 x 0.5)", money[2] and money[2].amount, refundFor(POLI, 100), 1e-9)
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

-- =====================================================================
-- GROUP I (Tyson's ruling 2026-09-23, a plain fix): the refund basis is the fillTypes.xml
-- SHOP price read through the manager at call time, at the existing 50%; an unpriced
-- product refunds 0 and says so; a redefined price is the one used; no price table of
-- the command's own remains. Entry point: the real consoleCommandDrainVehicle, prices
-- from the fill-type manager the way FillTypeDesc carries them.
-- =====================================================================
do
  local v = newVehicle({ [1] = unit(UREA, 400, UREA), [2] = unit(LUREA, 250, LUREA) })
  newWorld(v, true)
  local out = run()
  T.eq("DRAIN I1: a dry and a liquid product both drained", v.spec_fillUnit.fillUnits[1].fillLevel + v.spec_fillUnit.fillUnits[2].fillLevel, 0)
  T.eq("DRAIN I2: two refunds", #money, 2)
  T.near("DRAIN I3: the dry refund is drained x shop price x 0.5 (400 x 0.55 x 0.5)", money[1] and money[1].amount, 400 * 0.55 * 0.5, 1e-9)
  T.near("DRAIN I4: the liquid refund likewise (250 x 0.60 x 0.5)", money[2] and money[2].amount, 250 * 0.60 * 0.5, 1e-9)
  T.ok("DRAIN I5: the old table's UREA price (1.65) is gone from the sum", math.abs((money[1] and money[1].amount or 0) - 400 * 1.65 * 0.5) > 1)
  T.ok("DRAIN I6: the summary names the basis", out:find("50% of shop price", 1, true) ~= nil)
end
do
  local v = newVehicle({ [1] = unit(STARTER, 120, STARTER) })   -- price withheld by the fixture: stands for no economy, engine default 0
  newWorld(v, true)
  local out = run()
  T.eq("DRAIN I7: an unpriced product is still drained", v.spec_fillUnit.fillUnits[1].fillLevel, 0)
  T.eq("DRAIN I8: it refunds nothing (no money moved, not 1.0/L)", #money, 0)
  T.ok("DRAIN I9: and the report says so", out:find("no shop price, refund 0", 1, true) ~= nil)
end
do
  local v = newVehicle({ [1] = unit(GYP, 300, GYP) })
  newWorld(v, true)
  run()
  local first = money[1] and money[1].amount
  prices.GYPSUM = 0.40                                       -- a map or mod redefines the product
  local v2 = newVehicle({ [1] = unit(GYP, 300, GYP) })
  newWorld(v2, true)
  run()
  prices.GYPSUM = 0.10
  T.near("DRAIN I10: the first drain refunded at 0.10 (300 x 0.10 x 0.5)", first, 15, 1e-9)
  T.near("DRAIN I11: after the redefinition the refund follows the manager, not a captured copy (300 x 0.40 x 0.5)", money[1] and money[1].amount, 60, 1e-9)
end
do
  local src = SOURCE_TEXT and SOURCE_TEXT["src/settings/SoilSettingsGUI.lua"] or ""
  local fnStart = src:find("function SoilSettingsGUI:consoleCommandDrainVehicle", 1, true) or 0
  local body = src:sub(fnStart)
  local fnEnd = body:find("\nend\n", 1, true) or #body
  body = body:sub(1, fnEnd)
  T.ok("DRAIN I12: source witness: the file was handed to the bar", #src > 1000 and fnStart > 0)
  T.ok("DRAIN I13: source witness: the command has no price table of its own", src:find("fallbackPrices", 1, true) == nil and src:find("FALLBACK_PRICES in installPurchaseRefillHook", 1, true) == nil)
  T.ok("DRAIN I14: source witness: the command reads pricePerLiter through the manager", body:find("getFillTypeByIndex", 1, true) ~= nil and body:find("pricePerLiter", 1, true) ~= nil)
end

-- =====================================================================
-- GROUP J (Bob's review of #990): the production world. Every name the command drains
-- (its legacy list, read from the source, plus HookManager.DRY_PRODUCT_NAMES) must have a
-- POSITIVE economy pricePerLiter in the real fillTypes.xml, or the ruling refunds 0 for
-- it; and every price this fixture gives a drained product must equal the real XML, so a
-- fixture price can never drift from the file it stands for. STARTER's is the one the
-- fixture withholds on purpose.
-- =====================================================================
do
  local xml = SOURCE_TEXT and SOURCE_TEXT["fillTypes.xml"] or ""
  local gui = SOURCE_TEXT and SOURCE_TEXT["src/settings/SoilSettingsGUI.lua"] or ""
  T.ok("DRAIN J1: the real fillTypes.xml was handed to the bar", #xml > 1000 and xml:find("<fillType ", 1, true) ~= nil)

  local function xmlPrice(name)
    local s = xml:find('<fillType name="' .. name .. '"', 1, true)
    if s == nil then return nil end
    local e = xml:find("</fillType>", s, true) or #xml
    local block = xml:sub(s, e)
    return tonumber(block:match('<economy%s+pricePerLiter="([%d%.]+)"'))
  end

  -- the command's legacy list, from its source, plus the dry catalogue it unions in
  local fnStart = gui:find("function SoilSettingsGUI:consoleCommandDrainVehicle", 1, true) or 1
  local listStart = gui:find("local customNames = {", fnStart, true)
  local listEnd = listStart and gui:find("}", listStart, true)
  local names, seen = {}, {}
  if listStart and listEnd then
    for n in gui:sub(listStart, listEnd):gmatch('"([%u%d_]+)"') do
      if not seen[n] then names[#names + 1] = n; seen[n] = true end
    end
  end
  for _, n in ipairs(saved.DRY or {}) do
    if not seen[n] then names[#names + 1] = n; seen[n] = true end
  end
  T.eq("DRAIN J2: the drain population is the 22 legacy names plus AN and POLIFOSKA", #names, 24)

  local missing = {}
  for _, n in ipairs(names) do
    local pr = xmlPrice(n)
    if pr == nil or pr <= 0 then missing[#missing + 1] = n end
  end
  T.eq("DRAIN J3: every drained product has a positive shop price in the real fillTypes.xml (missing: " .. table.concat(missing, ",") .. ")", #missing, 0)

  local drift = {}
  for name, pr in pairs(prices) do
    if seen[name] and name ~= "STARTER" then
      local real = xmlPrice(name)
      if real == nil or math.abs(real - pr) > 1e-9 then drift[#drift + 1] = name end
    end
  end
  table.sort(drift)
  T.eq("DRAIN J4: every fixture price for a drained product equals the real XML (drifted: " .. table.concat(drift, ",") .. ")", #drift, 0)
  T.near("DRAIN J5: STARTER's real price is what the fixture withholds (0.90), not an absent economy", xmlPrice("STARTER"), 0.90, 1e-9)
end

FillType, ToolType, MoneyType, UIHelper = saved.FillType, saved.ToolType, saved.MoneyType, saved.UIHelper
g_currentMission, g_fillTypeManager, g_sprayTypeManager, g_SoilFertilityManager, g_localPlayer = saved.g_currentMission, saved.g_fillTypeManager, saved.g_sprayTypeManager, saved.g_SoilFertilityManager, saved.g_localPlayer
SoilLogger.info, SoilLogger.warning, SoilLogger.debug = saved.info, saved.warning, saved.debug
HookManager.DRY_PRODUCT_NAMES = saved.DRY
