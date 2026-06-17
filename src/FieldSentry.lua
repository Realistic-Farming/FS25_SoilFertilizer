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

-- l10n keys for the reasons that can actually surface in the UI (the sim-asleep states).
-- Console output and logs keep using reasonName (English); the field-detail dialog
-- localizes through these keys, with the English reasonName as the fallback.
local REASON_L10N = {
    [BL.MANUAL] = "sf_fs_reason_manual",
    [BL.NPC]    = "sf_fs_reason_npc",
    [BL.DECO]   = "sf_fs_reason_deco",
}

--- l10n key for a reason enum, or nil if it has no localized string (caller falls back).
---@param reason number
---@return string|nil
function FieldSentry_Core.reasonL10nKey(reason)
    return REASON_L10N[reason]
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

-- FR5: optional mask broadcaster, injected by the network layer (NetworkEvents) so this
-- module never references the networking API directly. Signature:
--   function(fieldId, reason, seq)   -- called server-side when a field's mask changes.
-- nil in single player and in the offline test harness.
FieldSentry_Core.maskBroadcaster = nil

-- Phase 4 (#651): optional deco / fake-field detector, injected by a map or integration
-- mod. Signature: function(fieldId) -> boolean (true = decorative / no valid fruit). Kept
-- deterministic by the caller (foliage layer + author hints only). nil = no auto-detection,
-- which is the safe default; the author/player decoHint still works without it.
FieldSentry_Core.decoDetector = nil

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
            -- Phase 2 (#654): contract masking + retroactive reconciliation
            contractActive     = false,
            contractInfo       = nil,   -- transient { active, favorTier, allowSAndF, source }
            lastContractSeq    = 0,     -- FR3 idempotency token (last reconciled contract)
            pendingRetro       = nil,   -- FR3 catch-up queued when the sim API is unavailable
            hints              = nil,   -- transient UI diagnostics, allocated on demand
            -- Phase 4 (#651): deco / fake-field classification
            decoHint           = false, -- persistent author/player mark
            decoDetected       = false, -- transient result from the injected detector
        }
        FieldSentry_Core.FieldState[fieldId] = f
    end
    return f
end

-- Recompute the dynamic mask from cached intents + cached contract status. Pure and
-- cheap: it never calls providers (refreshContract does that out of band and stores the
-- result on f). Rule order: structural (manual) → contract exemption → contract mask,
-- exactly as FR2 requires (exemption after structural, before classification).
local function evaluate(f)
    -- Structural constraints run first and short-circuit (Manual, then Contract). Only if
    -- none masked do the classification rules (Deco) run. Matches the proposal's order.

    -- Structural: an explicit manual blacklist wins outright.
    if f.manualBlacklist then
        if f.hints then f.hints.contractExempt = nil; f.hints.favorTier = nil end
        f.evaluatedBlacklist = BL.MANUAL
        return f.evaluatedBlacklist
    end

    -- Structural: an active contract masks (NPC) unless a trusted high-favor provider opts
    -- out (FR2, allowSAndF + favorTier >= threshold). An exemption lets structural return
    -- NONE so classification still gets a look.
    if f.contractActive then
        local info   = f.contractInfo
        local exempt = info and info.allowSAndF
                       and (info.favorTier or 0) >= FieldSentry_Core.FAVOR_TIER_THRESHOLD
        if exempt then
            -- Record a transient hint only; never auto-flip a persistent player setting.
            f.hints = f.hints or {}
            f.hints.contractExempt = true
            f.hints.favorTier      = info.favorTier
            -- fall through to classification (structural returned NONE)
        else
            if f.hints then f.hints.contractExempt = nil; f.hints.favorTier = nil end
            f.evaluatedBlacklist = BL.NPC
            return f.evaluatedBlacklist
        end
    else
        if f.hints then f.hints.contractExempt = nil; f.hints.favorTier = nil end
    end

    -- Classification: deco / fake field (Phase 4, #651). Deterministic signals only — an
    -- author/player hint (decoHint) or an injected foliage/no-fruit detector result
    -- (decoDetected). Field size and crop history are deliberately ignored.
    if f.decoHint or f.decoDetected then
        f.evaluatedBlacklist = BL.DECO
        return f.evaluatedBlacklist
    end

    f.evaluatedBlacklist = BL.NONE
    return f.evaluatedBlacklist
end
FieldSentry_Core.evaluate = evaluate

-- FR5 helper: bump the per-field sequence and broadcast when the mask actually changed.
-- Shared by refreshContract and markDecoField so any server-side mask change syncs.
local function broadcastMaskIfChanged(fieldId, f, prevReason)
    if f.evaluatedBlacklist ~= prevReason then
        f.lastSeq = (f.lastSeq or 0) + 1
        if FieldSentry_Core.maskBroadcaster then
            FieldSentry_Core.maskBroadcaster(fieldId, f.evaluatedBlacklist, f.lastSeq)
        end
    end
end

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

-- =========================================================
-- Meadow toggle (Phase 3, #651)
-- =========================================================
-- Persistent player intent that a field is permanent grassland. FieldSentry only stores
-- the toggle (and exposes it on the hot path); the meadow simulation profile itself lives
-- in S&F (locked decision). A meadow field is NOT sim-disabled — it still runs, just on
-- grassland rules — so meadowToggle is independent of the blacklist mask.

--- Set the meadow toggle for a field.
---@param fieldId number
---@param enabled boolean
---@return boolean newValue
function FieldSentry_API.setFieldMeadow(fieldId, enabled)
    local f = getOrCreate(fieldId)
    f.meadowToggle = enabled and true or false
    return f.meadowToggle
end

--- Toggle the meadow flag for a field. Returns the new value.
---@param fieldId number
---@return boolean newValue
function FieldSentry_API.toggleFieldMeadow(fieldId)
    local f = getOrCreate(fieldId)
    return FieldSentry_API.setFieldMeadow(fieldId, not f.meadowToggle)
end

--- Is this field flagged as a meadow? (read-only, no state created)
---@param fieldId number
---@return boolean
function FieldSentry_API.isFieldMeadow(fieldId)
    local f = FieldSentry_Core.FieldState[fieldId]
    return (f ~= nil) and f.meadowToggle == true
end

--- Sorted list of field ids flagged as meadow (console / persistence).
---@return number[]
function FieldSentry_API.getMeadowList()
    local out = {}
    for id, f in pairs(FieldSentry_Core.FieldState) do
        if f.meadowToggle then out[#out + 1] = id end
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

--- Re-evaluate a field's contract status against the live providers and refresh its cached
--- mask. Server-authoritative; on a client it just reports the synced cache. Designed to
--- be called from the soil sim's daily field pass (the existing DAILY_BATCH_SIZE loop), so
--- the work is amortized over that loop rather than a parallel scheduler (#654 maintainer
--- note). Keeps state lean by not allocating for an ordinary field that has no contract,
--- no manual flag and no existing state.
---@param fieldId number
---@return boolean disabled
---@return number reason
function FieldSentry_API.refreshContract(fieldId)
    local f = FieldSentry_Core.FieldState[fieldId]

    if not isSimAuthority() then
        if not f then return false, BL.NONE end
        return (f.evaluatedBlacklist ~= BL.NONE), f.evaluatedBlacklist
    end

    local underContract, info = FieldSentry_API.isFieldUnderAnyContract(fieldId)

    -- Phase 4: run the injected deco detector (deterministic, caller-owned). pcall so a bad
    -- detector can never break the daily pass; a thrown error just means "not deco".
    local decoDetected = false
    if FieldSentry_Core.decoDetector then
        local ok, res = pcall(FieldSentry_Core.decoDetector, fieldId)
        decoDetected = ok and res == true
    end

    -- Keep state lean: nothing to track for an ordinary field with no contract, no deco
    -- detection and no existing state.
    if not underContract and not decoDetected and not f then
        return false, BL.NONE
    end

    f = getOrCreate(fieldId)
    local prevReason = f.evaluatedBlacklist
    f.contractActive = underContract
    f.contractInfo   = underContract and info or nil
    f.decoDetected   = decoDetected
    evaluate(f)
    broadcastMaskIfChanged(fieldId, f, prevReason)  -- FR5 sync, only on actual change

    return (f.evaluatedBlacklist ~= BL.NONE), f.evaluatedBlacklist
end

--- Mark (or clear) a field as a decorative / fake field (Phase 4, #651). Persistent
--- author/player intent. A deco field is masked (BLACKLIST.DECO) and its soil freezes.
--- Re-evaluates and, server-side, broadcasts the mask change through the FR5 sync path.
---@param fieldId number
---@param isDeco boolean
---@return boolean newValue
function FieldSentry_API.markDecoField(fieldId, isDeco)
    local f = getOrCreate(fieldId)
    local prevReason = f.evaluatedBlacklist
    f.decoHint = isDeco and true or false
    evaluate(f)
    broadcastMaskIfChanged(fieldId, f, prevReason)
    return f.decoHint
end

--- Is this field decorative / fake? True if the author/player hinted it OR the injected
--- detector flagged it. Read-only, no state created.
---@param fieldId number
---@return boolean
function FieldSentry_API.isFieldDeco(fieldId)
    local f = FieldSentry_Core.FieldState[fieldId]
    return (f ~= nil) and (f.decoHint == true or f.decoDetected == true)
end

--- Sorted list of field ids the author/player has hinted as deco (console / persistence).
--- Detector-only matches are transient and not listed here.
---@return number[]
function FieldSentry_API.getDecoList()
    local out = {}
    for id, f in pairs(FieldSentry_Core.FieldState) do
        if f.decoHint then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

--- Client-side FIFO apply of a server mask broadcast (FR5). Drops stale or duplicate
--- packets so out-of-order delivery can never corrupt field state.
---@param fieldId number
---@param reason number  FieldSentry_Core.BLACKLIST enum from the server
---@param seq number     server's monotonic per-field sequence token
---@return boolean applied
function FieldSentry_API.applyMaskSync(fieldId, reason, seq)
    seq = seq or 0
    local f = getOrCreate(fieldId)
    if seq <= (f.lastSeq or 0) then
        return false  -- stale or duplicate
    end
    f.lastSeq            = seq
    f.evaluatedBlacklist = reason
    return true
end

-- =========================================================
-- Retroactive nutrient reconciliation (FR3)
-- =========================================================
-- When a contract harvests a field that FieldSentry had masked, the field would otherwise
-- sit frozen forever. On contract completion a provider calls applyRetroactiveHarvest with
-- the delivered yield, and FieldSentry estimates the nutrient catch-up from fixed crop
-- coefficients (NOT the full S&F sim) and applies it in one cheap step.
--
-- Static, deterministic drain in nutrient points per 1000 L of delivered yield. Coarse on
-- purpose; the exact balance is tuned during NPCFavor integration. Unknown crops -> DEFAULT.
FieldSentry_Core.RETRO_DRAIN_PER_1000L = {
    DEFAULT   = { N = 2.0, P = 1.0, K = 1.5 },
    wheat     = { N = 2.0, P = 1.0, K = 1.5 },
    barley    = { N = 1.8, P = 0.9, K = 1.4 },
    oat       = { N = 1.8, P = 0.9, K = 1.4 },
    canola    = { N = 3.0, P = 1.2, K = 2.0 },
    maize     = { N = 2.6, P = 1.1, K = 2.2 },
    potato    = { N = 2.8, P = 1.4, K = 3.5 },
    sugarbeet = { N = 2.4, P = 1.2, K = 3.8 },
    sunflower = { N = 2.6, P = 1.1, K = 2.2 },
    soybean   = { N = 1.2, P = 1.0, K = 1.6 },  -- legume: partial fixation, lighter N
}

--- The live soil system, if the mission is up. nil before the mission loads.
local function getSoilSystem()
    local mgr = g_SoilFertilityManager
    return mgr and mgr.soilSystem or nil
end

--- Reconcile a masked field after a contract harvested it. Idempotent per contractSeq:
--- a given (or older) contract sequence is never applied twice. If the soil sim is not
--- ready yet (e.g. called during load before fieldData exists), the catch-up is queued on
--- f.pendingRetro and a pendingRetroRemoval hint is set for the next flush.
---@param fieldId number
---@param deliveredLiters number  yield delivered by the contract
---@param fruitType string|nil    crop name (lower/any case); nil -> DEFAULT coefficients
---@param contractSeq number       monotonic per-field contract id (idempotency token)
---@return boolean applied
---@return string status   "applied" | "queued" | "duplicate"
function FieldSentry_API.applyRetroactiveHarvest(fieldId, deliveredLiters, fruitType, contractSeq)
    contractSeq = tonumber(contractSeq) or 0
    local f = getOrCreate(fieldId)

    -- Idempotency (FR3): never replay the same or an older contract's catch-up.
    if contractSeq <= (f.lastContractSeq or 0) then
        return false, "duplicate"
    end

    local liters = math.max(0, tonumber(deliveredLiters) or 0)
    local key    = fruitType and string.lower(fruitType) or nil
    local coeff  = (key and FieldSentry_Core.RETRO_DRAIN_PER_1000L[key])
                   or FieldSentry_Core.RETRO_DRAIN_PER_1000L.DEFAULT
    local scale  = liters / 1000
    local dN, dP, dK = coeff.N * scale, coeff.P * scale, coeff.K * scale

    local soil = getSoilSystem()
    if soil and soil.applyRetroactiveDrain and soil.fieldData and soil.fieldData[fieldId] then
        soil:applyRetroactiveDrain(fieldId, dN, dP, dK)
        f.lastContractSeq = contractSeq
        f.pendingRetro = nil
        if f.hints then f.hints.pendingRetroRemoval = nil end
        return true, "applied"
    end

    -- Sim not ready: queue and flag for the next flush (on load / next tick).
    f.pendingRetro = { seq = contractSeq, liters = liters, fruitType = fruitType }
    f.hints = f.hints or {}
    f.hints.pendingRetroRemoval = true
    return false, "queued"
end

--- Apply every queued retroactive catch-up now that the sim is available. Called on load
--- (FR4 consistency) and safe to call again from the daily seam; idempotency guards it.
function FieldSentry_API.flushPendingRetro()
    if not getSoilSystem() then return end
    for id, f in pairs(FieldSentry_Core.FieldState) do
        local p = f.pendingRetro
        if p then
            FieldSentry_API.applyRetroactiveHarvest(id, p.liters, p.fruitType, p.seq)
        end
    end
end

-- =========================================================
-- Persistence + schema versioning (FR4)
-- =========================================================
-- Saved: the player's persistent intent (manual blacklist) and the FR3 reconciliation
-- tokens (lastContractSeq, any pendingRetro). NOT saved: the live contract mask, which is
-- recomputed from providers on the next refresh. SoilFertilityManager folds this into
-- soilData.xml, which is already savegame/map-scoped, so a map swap drops stale config
-- naturally (that is the proposal's map-signature requirement, satisfied by scoping).
--
-- Schema: v1 = Phase 1 (no #version attr; every stored entry implied manualBlacklist).
--         v2 = Phase 2 (#version=2; explicit #manual plus the contract tokens).
-- Forward-compatible: all v2 attributes are optional on read, and a v1 save migrates in
-- place via migrateLegacyEntry.

--- v1 -> v2 migration for a single field entry: a bare id meant "manually blacklisted".
---@param id number
local function migrateLegacyEntry(id)
    FieldSentry_API.setFieldManual(id, true)
end

--- Write the manual blacklist + contract tokens into the given XML node.
---@param xmlFile any  XML file handle
---@param key string   base node, e.g. "soilData.fieldSentry"
function FieldSentry_API.saveToXMLFile(xmlFile, key)
    setXMLInt(xmlFile, key .. "#version", FieldSentry_Core.SCHEMA_VERSION)

    local idx = 0
    for id, f in pairs(FieldSentry_Core.FieldState) do
        local hasPending = f.pendingRetro ~= nil
        -- Only persist a field that carries durable state worth restoring.
        if f.manualBlacklist or f.meadowToggle or f.decoHint
           or (f.lastContractSeq or 0) > 0 or hasPending then
            local entryKey = string.format("%s.field(%d)", key, idx)
            setXMLInt(xmlFile, entryKey .. "#id", id)
            setXMLInt(xmlFile, entryKey .. "#manual", f.manualBlacklist and 1 or 0)
            setXMLInt(xmlFile, entryKey .. "#meadow", f.meadowToggle and 1 or 0)
            setXMLInt(xmlFile, entryKey .. "#deco", f.decoHint and 1 or 0)
            setXMLInt(xmlFile, entryKey .. "#lastContractSeq", f.lastContractSeq or 0)
            if hasPending then
                local p = f.pendingRetro
                setXMLInt(xmlFile, entryKey .. "#retroSeq", p.seq or 0)
                setXMLFloat(xmlFile, entryKey .. "#retroLiters", p.liters or 0)
                setXMLString(xmlFile, entryKey .. "#retroFruit", p.fruitType or "")
            end
            idx = idx + 1
        end
    end
    setXMLInt(xmlFile, key .. "#count", idx)
end

--- Restore the manual blacklist + contract tokens (replaces current state). Applies any
--- pending retroactive catch-up immediately on load (FR4 consistency constraint) once the
--- FR3 helper is present.
---@param xmlFile any
---@param key string
function FieldSentry_API.loadFromXMLFile(xmlFile, key)
    FieldSentry_API.reset()
    local version = getXMLInt(xmlFile, key .. "#version") or 1
    local count   = getXMLInt(xmlFile, key .. "#count") or 0

    for i = 0, count - 1 do
        local entryKey = string.format("%s.field(%d)", key, i)
        local id = getXMLInt(xmlFile, entryKey .. "#id")
        if id then
            if version < 2 then
                migrateLegacyEntry(id)
            else
                local manual   = (getXMLInt(xmlFile, entryKey .. "#manual") or 0) == 1
                local meadow   = (getXMLInt(xmlFile, entryKey .. "#meadow") or 0) == 1
                local deco     = (getXMLInt(xmlFile, entryKey .. "#deco") or 0) == 1
                local lastSeq  = getXMLInt(xmlFile, entryKey .. "#lastContractSeq") or 0
                local retroSeq = getXMLInt(xmlFile, entryKey .. "#retroSeq")
                if manual or meadow or deco or lastSeq > 0 or retroSeq then
                    local f = getOrCreate(id)
                    f.manualBlacklist = manual
                    f.meadowToggle    = meadow
                    f.decoHint        = deco
                    f.lastContractSeq = lastSeq
                    if retroSeq then
                        local fruit = getXMLString(xmlFile, entryKey .. "#retroFruit")
                        if fruit == "" then fruit = nil end
                        f.pendingRetro = {
                            seq       = retroSeq,
                            liters    = getXMLFloat(xmlFile, entryKey .. "#retroLiters") or 0,
                            fruitType = fruit,
                        }
                    end
                    evaluate(f)
                end
            end
        end
    end

    -- Pending catch-up is applied as soon as the sim API is available (FR3 owns the flush).
    if FieldSentry_API.flushPendingRetro then
        FieldSentry_API.flushPendingRetro()
    end
end
