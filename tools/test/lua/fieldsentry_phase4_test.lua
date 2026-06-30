-- fieldsentry_phase4_test.lua - FieldSentry Phase 4 deco / fake-field detection (#651).
-- Covers the author/player deco hint, the injected detector hook, the classification rule
-- order (structural before classification), persistence, and FR5 sync reuse. Pure mocks.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/FieldSentry.lua

local BL = FieldSentry_Core.BLACKLIST
local function asHost()  g_server = {}; g_client = nil end
local function asClient() g_server = nil; g_client = {} end
asHost()

-- ── author/player deco hint masks the field ────────────────
do
  FieldSentry_API.reset()
  FieldSentry_Core.decoDetector = nil
  T.ok("isFieldDeco false for unknown", FieldSentry_API.isFieldDeco(1) == false)
  T.ok("markDecoField(true) returns true", FieldSentry_API.markDecoField(1, true) == true)
  T.ok("isFieldDeco true after mark", FieldSentry_API.isFieldDeco(1) == true)
  local disabled, reason = FieldSentry_API.isFieldSimDisabled(1)
  T.ok("deco field is sim-disabled", disabled == true)
  T.eq("deco reason is DECO", reason, BL.DECO)
  T.ok("markDecoField(false) clears it", FieldSentry_API.markDecoField(1, false) == false)
  T.ok("cleared field is active again", FieldSentry_API.isFieldSimDisabled(1) == false)
end

do
  FieldSentry_API.reset()
  FieldSentry_API.markDecoField(5, true)
  FieldSentry_API.markDecoField(2, true)
  local l = FieldSentry_API.getDecoList()
  T.eq("getDecoList count", #l, 2)
  T.ok("getDecoList sorted", l[1] == 2 and l[2] == 5)
end

-- ── injected detector flags deco via refreshContract ───────
do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  FieldSentry_Core.decoDetector = function(id) return id == 9 end
  FieldSentry_API.refreshContract(9)
  T.eq("detector flags the field as DECO",
       select(2, FieldSentry_API.isFieldSimDisabled(9)), BL.DECO)
  FieldSentry_API.refreshContract(10)
  T.ok("non-matching field stays active", FieldSentry_API.isFieldSimDisabled(10) == false)
  T.ok("no state allocated for a non-deco free field",
       FieldSentry_Core.FieldState[10] == nil)
  FieldSentry_Core.decoDetector = nil
end

-- a detector that throws fails safe (treated as not deco, no error escapes)
do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.markDecoField(11, false)        -- create state, not deco
  FieldSentry_Core.decoDetector = function() error("boom") end
  FieldSentry_API.refreshContract(11)
  T.ok("crashing detector leaves the field active",
       FieldSentry_API.isFieldSimDisabled(11) == false)
  FieldSentry_Core.decoDetector = nil
end

-- ── rule order: structural before classification ───────────
do
  FieldSentry_API.reset()
  FieldSentry_API.markDecoField(20, true)
  FieldSentry_API.setFieldManual(20, true)
  T.eq("manual blacklist outranks deco",
       select(2, FieldSentry_API.isFieldSimDisabled(20)), BL.MANUAL)
end

do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("C", function(id)
    return { active = id == 21, favorTier = 1, allowSAndF = false }
  end)
  FieldSentry_API.markDecoField(21, true)
  FieldSentry_API.refreshContract(21)
  T.eq("an active contract outranks deco",
       select(2, FieldSentry_API.isFieldSimDisabled(21)), BL.NPC)
end

do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("C", function(id)
    return { active = id == 22, favorTier = 9, allowSAndF = true }
  end)
  FieldSentry_API.markDecoField(22, true)
  FieldSentry_API.refreshContract(22)
  T.eq("an exempt contract falls through to DECO classification",
       select(2, FieldSentry_API.isFieldSimDisabled(22)), BL.DECO)
end

-- ── persistence of the deco hint ───────────────────────────
do
  FieldSentry_API.reset()
  FieldSentry_API.markDecoField(30, true)
  local xml = {}
  FieldSentry_API.saveToXMLFile(xml, "soilData.fieldSentry")
  FieldSentry_API.reset()
  FieldSentry_API.loadFromXMLFile(xml, "soilData.fieldSentry")
  T.ok("deco hint round-trips through save/load", FieldSentry_API.isFieldDeco(30) == true)
  T.eq("restored deco field masks",
       select(2, FieldSentry_API.isFieldSimDisabled(30)), BL.DECO)
end

-- ── deco mark reuses the FR5 mask broadcast ────────────────
do
  asHost()
  FieldSentry_API.reset()
  local sent = {}
  FieldSentry_Core.maskBroadcaster = function(_fieldId, reason, seq)
    sent[#sent + 1] = { reason = reason, seq = seq }
  end
  FieldSentry_API.markDecoField(40, true)
  T.eq("marking deco broadcasts the mask", #sent, 1)
  T.eq("deco broadcast carries the DECO reason", sent[1].reason, BL.DECO)
  FieldSentry_Core.maskBroadcaster = nil
end
