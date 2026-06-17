-- fieldsentry_phase2_test.lua — FieldSentry Phase 2 contract integration (#654).
-- Covers the provider registry, the unified contract gate, and fail-closed behaviour.
-- Pure Lua mocks only; no engine beyond the prelude stubs.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/FieldSentry.lua

local BL = FieldSentry_Core.BLACKLIST

-- Phase 2 rules evaluate server-side only, so the suite plays the host.
local function asHost()  g_server = {}; g_client = nil end
local function asClient() g_server = nil; g_client = {} end
asHost()

-- Faithful stand-in for the soil system's FR3 apply method (clamped subtraction).
local function mockSoil()
  return {
    fieldData = {},
    applyRetroactiveDrain = function(self, id, dN, dP, dK)
      local fd = self.fieldData[id]
      if not fd then return false end
      fd.nitrogen   = math.max(0, (fd.nitrogen   or 0) - dN)
      fd.phosphorus = math.max(0, (fd.phosphorus or 0) - dP)
      fd.potassium  = math.max(0, (fd.potassium  or 0) - dK)
      return true
    end,
  }
end

-- ── FR1: provider registry ─────────────────────────────────
do
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  local ok = FieldSentry_API.registerContractProvider("Test", function(_id)
    return { active = false, favorTier = 0, allowSAndF = false }
  end)
  T.ok("registerContractProvider: valid provider registers", ok == true)
  T.ok("registerContractProvider: stored under its name",
       type(FieldSentry_Core.contractProviders["Test"]) == "function")

  FieldSentry_API.unregisterContractProvider("Test")
  T.ok("unregisterContractProvider removes it",
       FieldSentry_Core.contractProviders["Test"] == nil)
end

do
  FieldSentry_Core.contractProviders = {}
  T.ok("registerContractProvider: rejects non-function",
       FieldSentry_API.registerContractProvider("Bad", 42) == false)
  T.ok("registerContractProvider: rejects empty name",
       FieldSentry_API.registerContractProvider("", function() end) == false)
end

-- ── FR1: unified contract gate (providers) ─────────────────
do
  FieldSentry_Core.contractProviders = {}
  local under, info = FieldSentry_API.isFieldUnderAnyContract(10)
  T.ok("no providers -> field not under contract", under == false)
  T.eq("no providers -> source 'none'", info.source, "none")
end

do
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("NPCFavor", function(id)
    if id == 20 then return { active = true, favorTier = 5, allowSAndF = true } end
    return { active = false }
  end)
  local under, info = FieldSentry_API.isFieldUnderAnyContract(20)
  T.ok("active provider field is under contract", under == true)
  T.eq("provider source reported", info.source, "NPCFavor")
  T.eq("favorTier passes through", info.favorTier, 5)
  T.ok("allowSAndF passes through", info.allowSAndF == true)
  T.ok("non-contract field via same provider is free",
       FieldSentry_API.isFieldUnderAnyContract(21) == false)
end

-- ── FR1: vanilla base-game field missions ──────────────────
do
  FieldSentry_Core.contractProviders = {}
  g_farmlandManager = { getFarmlandById = function(_, id) return { id = id } end }
  g_missionManager  = {
    getIsMissionRunningOnFarmland = function(_, farmland) return farmland.id == 77 end,
  }
  local under, info = FieldSentry_API.isFieldUnderAnyContract(77)
  T.ok("vanilla mission on farmland -> under contract", under == true)
  T.eq("vanilla source reported", info.source, "vanilla")
  T.ok("farmland without a mission is free",
       FieldSentry_API.isFieldUnderAnyContract(78) == false)
  g_missionManager  = nil
  g_farmlandManager = nil
end

-- ── FR6 edge case: malformed / crashing providers fail closed ──
do
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("NilReturn", function() return nil end)
  local under, info = FieldSentry_API.isFieldUnderAnyContract(30)
  T.ok("provider returning nil fails closed (masked)", under == true)
  T.ok("failed-closed field is not S&F-exempt", info.allowSAndF == false)
end

do
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("Crash", function() error("boom") end)
  T.ok("crashing provider fails closed (masked)",
       FieldSentry_API.isFieldUnderAnyContract(31) == true)
end

do
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("BadShape", function() return { active = "yes" } end)
  T.ok("non-boolean .active fails closed (masked)",
       FieldSentry_API.isFieldUnderAnyContract(32) == true)
end

-- ── FR5 authority: a pure client never evaluates providers ─
do
  FieldSentry_Core.contractProviders = {}
  asClient()
  T.ok("client registration is rejected",
       FieldSentry_API.registerContractProvider("X", function() end) == false)
  local under, info = FieldSentry_API.isFieldUnderAnyContract(40)
  T.ok("client never reports a contract (mirrors via sync)", under == false)
  T.eq("client gate source", info.source, "client")
  asHost()
end

-- ── FR2: exemption + hinting engine (via refreshContract) ──
-- Provider keyed by fieldId so one provider drives every scenario.
local function installFavorProvider(map)
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("Favor", function(id)
    local e = map[id]
    if e then return e end
    return { active = false }
  end)
end

do
  asHost()
  FieldSentry_API.reset()
  installFavorProvider({
    [1] = { active = true, favorTier = 1, allowSAndF = false }, -- hostile: mask
    [2] = { active = true, favorTier = 5, allowSAndF = true  }, -- best friend + opt-in: exempt
    [3] = { active = true, favorTier = 5, allowSAndF = false }, -- high favor but no opt-in: mask
    [4] = { active = true, favorTier = 2, allowSAndF = true  }, -- opt-in but low favor: mask
  })

  T.ok("low-favor contract field is masked",
       select(1, FieldSentry_API.refreshContract(1)) == true)
  T.eq("masked contract reason is NPC",
       select(2, FieldSentry_API.refreshContract(1)), BL.NPC)

  T.ok("high-favor opt-in contract field runs S&F (exempt)",
       select(1, FieldSentry_API.refreshContract(2)) == false)
  local s2 = FieldSentry_API.getUIStatus(2)
  T.ok("exempt field surfaces contractExempt hint", s2.diagnosticHints.contractExempt == true)
  T.eq("exempt field surfaces favorTier hint", s2.diagnosticHints.favorTier, 5)

  T.ok("high favor without opt-in stays masked",
       select(1, FieldSentry_API.refreshContract(3)) == true)
  T.ok("opt-in below the tier threshold stays masked",
       select(1, FieldSentry_API.refreshContract(4)) == true)
end

-- manual blacklist outranks an exemptible contract
do
  asHost()
  FieldSentry_API.reset()
  installFavorProvider({ [9] = { active = true, favorTier = 9, allowSAndF = true } })
  FieldSentry_API.setFieldManual(9, true)
  FieldSentry_API.refreshContract(9)
  T.eq("manual blacklist wins over an exemptible contract",
       select(2, FieldSentry_API.isFieldSimDisabled(9)), BL.MANUAL)
end

-- contract ending un-masks the field, and the hint clears
do
  asHost()
  FieldSentry_API.reset()
  local active = true
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("Toggle", function(_id)
    return { active = active, favorTier = 1, allowSAndF = false }
  end)
  FieldSentry_API.refreshContract(15)
  T.ok("field masked while contract active",
       FieldSentry_API.isFieldSimDisabled(15) == true)
  active = false
  FieldSentry_API.refreshContract(15)
  T.ok("field un-masked once the contract ends",
       FieldSentry_API.isFieldSimDisabled(15) == false)
end

-- refreshContract stays lean: no state for an ordinary, contract-free field
do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.refreshContract(500)
  T.ok("no FieldState allocated for a free field",
       FieldSentry_Core.FieldState[500] == nil)
end

-- ── FR4: persistence + schema versioning ───────────────────
do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.setFieldManual(4, true)
  FieldSentry_API.setFieldManual(11, true)
  local f11 = FieldSentry_Core.FieldState[11]
  f11.lastContractSeq = 7
  f11.pendingRetro = { seq = 8, liters = 1500, fruitType = "wheat" }

  local xml = {}
  FieldSentry_API.saveToXMLFile(xml, "soilData.fieldSentry")
  T.eq("save writes schema version",
       xml["soilData.fieldSentry#version"], FieldSentry_Core.SCHEMA_VERSION)

  FieldSentry_API.reset()
  FieldSentry_API.loadFromXMLFile(xml, "soilData.fieldSentry")
  local list = FieldSentry_API.getManualBlacklist()
  T.eq("v2 round-trip restores manual count", #list, 2)
  T.ok("v2 round-trip restores ids", list[1] == 4 and list[2] == 11)
  local r = FieldSentry_Core.FieldState[11]
  T.eq("v2 restores lastContractSeq", r.lastContractSeq, 7)
  T.ok("v2 restores pendingRetro", r.pendingRetro ~= nil)
  T.eq("v2 restores pendingRetro.liters", r.pendingRetro.liters, 1500)
  T.eq("v2 restores pendingRetro.fruitType", r.pendingRetro.fruitType, "wheat")
end

-- legacy v1 save (bare ids imply manual) migrates in place
do
  asHost()
  FieldSentry_API.reset()
  local xml = {
    ["soilData.fieldSentry#count"]       = 2,
    ["soilData.fieldSentry.field(0)#id"] = 3,
    ["soilData.fieldSentry.field(1)#id"] = 9,
    -- no #version attribute -> treated as v1
  }
  FieldSentry_API.loadFromXMLFile(xml, "soilData.fieldSentry")
  local list = FieldSentry_API.getManualBlacklist()
  T.eq("v1 legacy save migrates manual count", #list, 2)
  T.ok("v1 legacy fields are blacklisted",
       FieldSentry_API.isFieldManual(3) and FieldSentry_API.isFieldManual(9))
end

-- ── FR3: retroactive reconciliation ────────────────────────
do
  asHost()
  FieldSentry_API.reset()
  FieldSentry_Core.contractProviders = {}
  local soil = mockSoil()
  soil.fieldData[60] = { nitrogen = 50, phosphorus = 40, potassium = 45 }
  g_SoilFertilityManager = { soilSystem = soil }

  -- 2000 L wheat (N2/P1/K1.5 per 1000 L) -> remove N4 P2 K3
  local ok, status = FieldSentry_API.applyRetroactiveHarvest(60, 2000, "wheat", 1)
  T.ok("retro: first apply succeeds", ok == true)
  T.eq("retro: status applied", status, "applied")
  T.near("retro: nitrogen drained", soil.fieldData[60].nitrogen, 46)
  T.near("retro: potassium drained", soil.fieldData[60].potassium, 42)
  T.eq("retro: lastContractSeq advanced", FieldSentry_Core.FieldState[60].lastContractSeq, 1)

  local ok2, status2 = FieldSentry_API.applyRetroactiveHarvest(60, 2000, "wheat", 1)
  T.ok("retro: replaying the same seq is rejected", ok2 == false)
  T.eq("retro: replay status duplicate", status2, "duplicate")
  T.near("retro: nitrogen unchanged on replay", soil.fieldData[60].nitrogen, 46)

  T.ok("retro: a newer contract seq applies again",
       FieldSentry_API.applyRetroactiveHarvest(60, 1000, "wheat", 2) == true)
  T.near("retro: nitrogen drained again", soil.fieldData[60].nitrogen, 44)
  g_SoilFertilityManager = nil
end

do
  asHost()
  FieldSentry_API.reset()
  local soil = mockSoil()
  soil.fieldData[61] = { nitrogen = 50, phosphorus = 50, potassium = 50 }
  g_SoilFertilityManager = { soilSystem = soil }
  FieldSentry_API.applyRetroactiveHarvest(61, 1000, "moonberry", 1)  -- unknown -> DEFAULT N2
  T.near("retro: unknown crop uses DEFAULT coefficients", soil.fieldData[61].nitrogen, 48)
  g_SoilFertilityManager = nil
end

do
  asHost()
  FieldSentry_API.reset()
  g_SoilFertilityManager = nil  -- sim not ready
  local ok, status = FieldSentry_API.applyRetroactiveHarvest(62, 1000, "wheat", 5)
  T.ok("retro: queues when sim unavailable", ok == false)
  T.eq("retro: queued status", status, "queued")
  local f = FieldSentry_Core.FieldState[62]
  T.ok("retro: pendingRetro stored", f.pendingRetro ~= nil)
  T.ok("retro: pendingRetroRemoval hint set", f.hints.pendingRetroRemoval == true)

  local soil = mockSoil()
  soil.fieldData[62] = { nitrogen = 30, phosphorus = 30, potassium = 30 }
  g_SoilFertilityManager = { soilSystem = soil }
  FieldSentry_API.flushPendingRetro()
  T.near("retro: flush applies the queued drain", soil.fieldData[62].nitrogen, 28)
  T.ok("retro: pendingRetro cleared after flush",
       FieldSentry_Core.FieldState[62].pendingRetro == nil)
  T.eq("retro: lastContractSeq set after flush",
       FieldSentry_Core.FieldState[62].lastContractSeq, 5)
  g_SoilFertilityManager = nil
end

-- ── FR5: MP authority + FIFO mask sync ─────────────────────
do
  asClient()  -- a client applying the server's authoritative broadcasts
  FieldSentry_API.reset()
  T.ok("mask sync: first packet applies",
       FieldSentry_API.applyMaskSync(70, BL.NPC, 1) == true)
  T.eq("mask sync: reason applied",
       select(2, FieldSentry_API.isFieldSimDisabled(70)), BL.NPC)
  T.ok("mask sync: duplicate seq dropped",
       FieldSentry_API.applyMaskSync(70, BL.NONE, 1) == false)
  T.ok("mask sync: out-of-order (lower seq) dropped",
       FieldSentry_API.applyMaskSync(70, BL.NONE, 0) == false)
  T.eq("mask sync: state survives stale packets",
       select(2, FieldSentry_API.isFieldSimDisabled(70)), BL.NPC)
  T.ok("mask sync: newer seq applies",
       FieldSentry_API.applyMaskSync(70, BL.NONE, 2) == true)
  T.ok("mask sync: field cleared by the newer packet",
       FieldSentry_API.isFieldSimDisabled(70) == false)
  asHost()
end

do
  asHost()
  FieldSentry_API.reset()
  local sent = {}
  FieldSentry_Core.maskBroadcaster = function(fieldId, reason, seq)
    sent[#sent + 1] = { fieldId = fieldId, reason = reason, seq = seq }
  end
  local active = true
  FieldSentry_Core.contractProviders = {}
  FieldSentry_API.registerContractProvider("Toggle", function()
    return { active = active, favorTier = 1, allowSAndF = false }
  end)

  FieldSentry_API.refreshContract(80)            -- NONE -> NPC
  T.eq("broadcast fires on mask change", #sent, 1)
  T.eq("broadcast carries the new reason", sent[1].reason, BL.NPC)
  T.eq("broadcast seq starts at 1", sent[1].seq, 1)

  FieldSentry_API.refreshContract(80)            -- NPC -> NPC (no change)
  T.eq("no broadcast when the mask is unchanged", #sent, 1)

  active = false
  FieldSentry_API.refreshContract(80)            -- NPC -> NONE
  T.eq("broadcast fires again on un-mask", #sent, 2)
  T.eq("broadcast seq increments", sent[2].seq, 2)

  FieldSentry_Core.maskBroadcaster = nil
end
