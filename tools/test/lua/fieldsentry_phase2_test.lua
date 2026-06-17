-- fieldsentry_phase2_test.lua — FieldSentry Phase 2 contract integration (#654).
-- Covers the provider registry, the unified contract gate, and fail-closed behaviour.
-- Pure Lua mocks only; no engine beyond the prelude stubs.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/FieldSentry.lua

local BL = FieldSentry_Core.BLACKLIST

-- Phase 2 rules evaluate server-side only, so the suite plays the host.
local function asHost()  g_server = {}; g_client = nil end
local function asClient() g_server = nil; g_client = {} end
asHost()

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
