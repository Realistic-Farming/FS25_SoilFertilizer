-- =========================================================
-- FS25 Realistic Soil & Fertilizer - FieldSentry (backend gate)
-- =========================================================
-- A lightweight backend that answers one binary question per field:
-- "should this area run soil simulation right now?" It never touches the
-- soil equations; the sim just consults it and skips disabled fields.
--
-- Proposal: @arissani (issue #651). This is the Phase 1 cut:
--   - encapsulated registry (FieldSentry_Core) + status/reason API (FieldSentry_API)
--   - manual blacklist (player chooses to "sleep" a field; its soil values freeze)
-- Meadow profile, deco/fake-field detection and NPC-contract masking are later
-- phases and only need new BLACKLIST reasons + classification rules layered on top.
--
-- Design constraints honoured here:
--   - Backend only: no UI, no changes to soil equations.
--   - Namespace safety: everything hangs off FieldSentry_Core / FieldSentry_API.
--   - No hot-path allocations: isFieldSimDisabled returns a shared EMPTY_HINTS table
--     and never builds garbage.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class FieldSentry_Core
FieldSentry_Core = {}

-- Blacklist reason enum. Phase 1 uses NONE and MANUAL; the rest are reserved so the
-- API shape is stable as later phases add structural/classification rules.
FieldSentry_Core.BLACKLIST = {
    NONE      = 0,
    MANUAL    = 1,  -- player-set persistent intent (Phase 1)
    FARMLAND  = 2,  -- reserved: whole-farmland manual block
    OWNERSHIP = 3,  -- reserved: unowned land (already sleeps via active-set today)
    NPC       = 4,  -- reserved: field under an AI/NPC contract
    DECO      = 5,  -- reserved: decorative / fake field
    INACTIVE  = 6,  -- reserved: long-idle sleep
}

local BL = FieldSentry_Core.BLACKLIST

local REASON_NAMES = {
    [BL.NONE]      = "active",
    [BL.MANUAL]    = "manual",
    [BL.FARMLAND]  = "farmland block",
    [BL.OWNERSHIP] = "unowned",
    [BL.NPC]       = "npc contract",
    [BL.DECO]      = "decorative",
    [BL.INACTIVE]  = "inactive",
}

--- Human-readable name for a reason enum (map tab / console).
---@param reason number
---@return string
function FieldSentry_Core.reasonName(reason)
    return REASON_NAMES[reason] or "unknown"
end

-- Self-contained logger so FieldSentry never hard-depends on Logger load order and the
-- offline test harness (no SoilLogger) stays clean. No-ops if SoilLogger is absent.
local function fsLog(level, fmt, ...)
    if SoilLogger and SoilLogger[level] then SoilLogger[level](fmt, ...) end
end

-- =========================================================
-- Phase 2 — contract provider registry (#654)
-- =========================================================
-- External mods (e.g. NPCFavor) register a callback reporting whether a field is under
-- one of their contracts. The soil sim stays fully decoupled: it never references
-- NPCFavor, it only asks "is this field under any contract right now?". Registration is
-- a plain table write; the rules that consume it run server-side only (see isSimAuthority).
FieldSentry_Core.contractProviders = {}

-- FR2: at or above this favor tier, a provider can request that S&F keep running on its
-- contract field (allowSAndF) instead of masking it. Tunable single source of truth.
FieldSentry_Core.FAVOR_TIER_THRESHOLD = 4

-- Persisted state schema version (FR4). Bump when the fieldsentry save shape changes so
-- migrateLegacy can upgrade older saves in place.
FieldSentry_Core.SCHEMA_VERSION = 2

-- Per-field state, created lazily on first toggle.
--   manualBlacklist    : boolean  persistent player intent
--   meadowToggle       : boolean  persistent player intent (Phase 1 stores it; the
--                                  meadow sim profile is a later phase, in S&F)
--   evaluatedBlacklist : enum     dynamic status mask (recomputed from intents)
--   lastSeq            : integer  reserved for the MP sequence token (later phase)
---@class FieldSentry_FieldState
FieldSentry_Core.FieldState = {}

-- Shared immutable table so the hot path never allocates (Phase 1 has no live hints).
local EMPTY_HINTS = {}

local function getOrCreate(fieldId)
    local f = FieldSentry_Core.FieldState[fieldId]
    if not f then
        f = {
            manualBlacklist    = false,
            meadowToggle       = false,
            evaluatedBlacklist = BL.NONE,
            lastSeq            = 0,
        }
        FieldSentry_Core.FieldState[fieldId] = f
    end
    return f
end

-- Recompute the dynamic mask from persistent intents. Structural rules run first and
-- short-circuit; Phase 1 has exactly one (manual blacklist). Later phases insert
-- farmland/ownership/NPC/deco checks here in priority order.
local function evaluate(f)
    if f.manualBlacklist then
        f.evaluatedBlacklist = BL.MANUAL
    else
        f.evaluatedBlacklist = BL.NONE
    end
    return f.evaluatedBlacklist
end
FieldSentry_Core.evaluate = evaluate

-- =========================================================
-- Public API
-- =========================================================
---@class FieldSentry_API
FieldSentry_API = {}

--- Hot path (O(1)): is this field's simulation currently disabled?
---@param fieldId number
---@return boolean disabled
---@return number reason   FieldSentry_Core.BLACKLIST enum
---@return boolean meadow  meadow toggle (the sim consumes this in a later phase)
---@return table hints     diagnostic hints (shared empty table in Phase 1)
function FieldSentry_API.isFieldSimDisabled(fieldId)
    local f = FieldSentry_Core.FieldState[fieldId]
    if not f then
        return false, BL.NONE, false, EMPTY_HINTS
    end
    return (f.evaluatedBlacklist ~= BL.NONE), f.evaluatedBlacklist, f.meadowToggle, (f.hints or EMPTY_HINTS)
end

--- Data consumer for the map tab / FarmTablet.
---@param fieldId number
---@return table status
function FieldSentry_API.getUIStatus(fieldId)
    local disabled, reason, meadow, hints = FieldSentry_API.isFieldSimDisabled(fieldId)
    return {
        isSimulationDisabled = disabled,
        reason               = reason,
        reasonName           = FieldSentry_Core.reasonName(reason),
        isMeadow             = meadow,
        diagnosticHints      = hints,
    }
end

--- Set the manual blacklist for a field.
---@param fieldId number
---@param enabled boolean
---@return boolean newValue
function FieldSentry_API.setFieldManual(fieldId, enabled)
    local f = getOrCreate(fieldId)
    f.manualBlacklist = enabled and true or false
    evaluate(f)
    return f.manualBlacklist
end

--- Toggle the manual blacklist for a field. Returns the new value.
---@param fieldId number
---@return boolean newValue
function FieldSentry_API.toggleFieldManual(fieldId)
    local f = getOrCreate(fieldId)
    return FieldSentry_API.setFieldManual(fieldId, not f.manualBlacklist)
end

--- Is this field currently manually blacklisted? (read-only, no state created)
---@param fieldId number
---@return boolean
function FieldSentry_API.isFieldManual(fieldId)
    local f = FieldSentry_Core.FieldState[fieldId]
    return (f ~= nil) and f.manualBlacklist == true
end

--- Sorted list of field ids the player has manually blacklisted (console / persistence).
---@return number[]
function FieldSentry_API.getManualBlacklist()
    local out = {}
    for id, f in pairs(FieldSentry_Core.FieldState) do
        if f.manualBlacklist then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

--- Drop all state (map swap / new game). Persistence layer calls this before restoring.
function FieldSentry_API.reset()
    FieldSentry_Core.FieldState = {}
end

-- =========================================================
-- Contract providers (FR1 / FR5) — server-authoritative
-- =========================================================

-- One-shot error de-dupe so a crashing provider cannot spam the log every refresh.
local providerErrorLogged = {}

-- Fail-closed default: when a provider errors or returns garbage we treat the field as
-- contract-active and not S&F-exempt, so a broken provider can never silently un-mask an
-- NPC field. allowSAndF=false keeps it masked.
local FAILSAFE_CONTRACT = { active = true, favorTier = 0, allowSAndF = false }

--- Are we the simulation authority (server / host / single player)? Providers are only
--- consulted here; pure clients mirror the resulting mask through the existing sync path,
--- so contract masking can never be driven client-side (FR5 authority gate).
---@return boolean
local function isSimAuthority()
    return g_server ~= nil
end
FieldSentry_Core.isSimAuthority = isSimAuthority

--- Register an external contract provider. Decoupled by design: FieldSentry has no
--- compile-time knowledge of the caller. The callback takes a fieldId and must return a
--- normalized table { active=boolean, favorTier=number, allowSAndF=boolean }.
--- Server/host only — a pure client never evaluates providers (FR1/FR5).
---@param name string     unique provider id, e.g. "NPCFavor"
---@param fn function      function(fieldId) -> { active, favorTier, allowSAndF }
---@return boolean registered
function FieldSentry_API.registerContractProvider(name, fn)
    if type(name) ~= "string" or name == "" or type(fn) ~= "function" then
        fsLog("warning", "FieldSentry: registerContractProvider needs (name:string, fn:function)")
        return false
    end
    -- Pure client: reject so masking stays server-authoritative.
    if g_client ~= nil and g_server == nil then
        fsLog("info", "FieldSentry: ignoring provider '%s' registration on a client", name)
        return false
    end
    FieldSentry_Core.contractProviders[name] = fn
    providerErrorLogged[name] = nil
    fsLog("info", "FieldSentry: contract provider '%s' registered", name)
    return true
end

--- Remove a previously registered provider (mod unload / teardown).
---@param name string
function FieldSentry_API.unregisterContractProvider(name)
    FieldSentry_Core.contractProviders[name] = nil
    providerErrorLogged[name] = nil
end

--- Validate + normalize a provider return into a safe table. Never returns nil.
--- Handles the malformed-return edge case (FR6): nil, non-table, or missing .active all
--- fail closed.
---@param name string
---@param ok boolean    pcall success flag
---@param res any       pcall result
---@return table        { active, favorTier, allowSAndF }
local function normalizeProviderResult(name, ok, res)
    if not ok then
        if not providerErrorLogged[name] then
            providerErrorLogged[name] = true
            fsLog("error", "FieldSentry: provider '%s' errored, failing closed (field stays masked): %s",
                name, tostring(res))
        end
        return FAILSAFE_CONTRACT
    end
    if type(res) ~= "table" or type(res.active) ~= "boolean" then
        if not providerErrorLogged[name] then
            providerErrorLogged[name] = true
            fsLog("error", "FieldSentry: provider '%s' returned a malformed result, failing closed", name)
        end
        return FAILSAFE_CONTRACT
    end
    return {
        active     = res.active,
        favorTier  = tonumber(res.favorTier) or 0,
        allowSAndF = res.allowSAndF == true,
    }
end

--- Unified O(1)-per-provider contract gate. Checks vanilla base-game field missions
--- first, then each registered provider; the first active source wins and its metadata
--- is returned so the rule engine (FR2) can read favorTier / allowSAndF.
--- Pure clients short-circuit to "not under contract" — they receive the mask via sync.
---@param fieldId number
---@return boolean underContract
---@return table info   { active, favorTier, allowSAndF, source }
function FieldSentry_API.isFieldUnderAnyContract(fieldId)
    if not isSimAuthority() then
        return false, { active = false, favorTier = 0, allowSAndF = false, source = "client" }
    end

    -- Vanilla field missions (plow/sow/harvest contracts) run per farmland; fieldId is the
    -- farmland id in this codebase. getIsMissionRunningOnFarmland is the SDK-confirmed API.
    if g_missionManager and g_farmlandManager and g_missionManager.getIsMissionRunningOnFarmland then
        local farmland = g_farmlandManager:getFarmlandById(fieldId)
        if farmland and g_missionManager:getIsMissionRunningOnFarmland(farmland) then
            return true, { active = true, favorTier = 0, allowSAndF = false, source = "vanilla" }
        end
    end

    -- Registered external providers (NPCFavor, …). First active contract wins.
    for name, fn in pairs(FieldSentry_Core.contractProviders) do
        local ok, res = pcall(fn, fieldId)
        local info = normalizeProviderResult(name, ok, res)
        if info.active then
            return true, {
                active = true, favorTier = info.favorTier, allowSAndF = info.allowSAndF, source = name,
            }
        end
    end

    return false, { active = false, favorTier = 0, allowSAndF = false, source = "none" }
end

-- =========================================================
-- Persistence (Phase 1: manual blacklist only)
-- =========================================================
-- Only the player's persistent intent is saved; the dynamic mask is recomputed on
-- load. SoilFertilityManager folds these into soilData.xml, which is already
-- savegame/map-scoped, so a map swap drops stale config naturally. Uses only
-- setXMLInt/getXMLInt (the XML API this codebase already relies on) — a stored
-- entry implies manualBlacklist=true, so no boolean attribute is needed.

--- Write the manual blacklist into the given XML node.
---@param xmlFile any  XML file handle
---@param key string   base node, e.g. "soilData.fieldSentry"
function FieldSentry_API.saveToXMLFile(xmlFile, key)
    local list = FieldSentry_API.getManualBlacklist()
    setXMLInt(xmlFile, key .. "#count", #list)
    for i = 1, #list do
        local entryKey = string.format("%s.field(%d)", key, i - 1)
        setXMLInt(xmlFile, entryKey .. "#id", list[i])
    end
end

--- Restore the manual blacklist from the given XML node (replaces current state).
---@param xmlFile any
---@param key string
function FieldSentry_API.loadFromXMLFile(xmlFile, key)
    FieldSentry_API.reset()
    local count = getXMLInt(xmlFile, key .. "#count") or 0
    for i = 0, count - 1 do
        local entryKey = string.format("%s.field(%d)", key, i)
        local id = getXMLInt(xmlFile, entryKey .. "#id")
        if id then FieldSentry_API.setFieldManual(id, true) end
    end
end
