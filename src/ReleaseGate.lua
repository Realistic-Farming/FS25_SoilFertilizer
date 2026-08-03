-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Release Gate
-- =========================================================
-- The release gate: which systems are released (STABLE) vs experimental (LOCKED).
--
-- Orthogonal to difficulty. Difficulty answers how punishing a PROVEN system is
-- (rates, costs, tolerances). The release gate answers whether an UNPROVEN system
-- runs at all. A player who wants a hard but stable farm must not be forced to
-- take unfinished systems, and a player curious about an experimental feature must
-- not be forced into Hardcore to reach it. So the gate is its own explicit opt-in,
-- independent of difficulty, and the two locks STACK: within the stable set,
-- difficulty gates by mode exactly as today; the release gate gates the
-- experimental set by release status on top.
--
-- The lock set and the rule that generates it come from Arissani's certification
-- (2026-08-02, ledger): a system earns STABLE only when all four hold - built AND
-- observed in a real save, its player surface exists and shows what it does, its
-- known high/blocking defects are closed, and it is balance-safe. Fail any one and
-- it stays LOCKED. Releasing a system for a stable release is a deliberate act,
-- never a default.
-- =========================================================

ReleaseGate = {}

-- The certified experimental (LOCKED) set. Each entry: [systemId] = { name, status }.
-- `status` is a SHORT player-facing note on what is not working or implemented yet.
-- Internal four-test reasons live in RELEASE-GATE-DESIGN.md and the tracker, not here.
-- A system that is NOT in this table is released (the proven baseline).
ReleaseGate.EXPERIMENTAL = {
    cd9_resistance  = { name = "Disease resistance", status = "awaiting in-game verification" },
    cd10_hybrids    = { name = "Hybrid strains",     status = "ships with disease resistance" },
    cd12_tank_mixes = { name = "Tank mixes",         status = "awaiting in-game check" },
    ground_material = { name = "Ground material",    status = "awaiting bale + wetness checks" },
    spatial_soil    = { name = "Spatial soil",       status = "awaiting the rest of its family" },
    read_the_dirt   = { name = "Read the Dirt",      status = "awaiting its reading panel" },
}

-- Console command -> systemId, so command refusals route through the same registry.
ReleaseGate.COMMAND_TO_SYSTEM = {
    SoilResistance     = "cd9_resistance",
    SoilResistanceTest = "cd9_resistance",
    SoilBlendCheck     = "cd12_tank_mixes",
    SoilMaterialBench  = "ground_material",
}

--- A system is released when it is NOT experimental, or the player has explicitly
--- opted into experimental systems. Mirrors Settings:allowsBypassTools() on the
--- release axis. `optIn` is the settings.experimentalSystems boolean.
---@param systemId string
---@param optIn boolean|nil
---@return boolean
function ReleaseGate.isReleased(systemId, optIn)
    if not ReleaseGate.EXPERIMENTAL[systemId] then return true end
    return optIn == true
end

--- The LIVE opt-in: reads the player's current settings.experimentalSystems value
--- through the manager. Everything in the sim that gates a locked system calls this
--- rather than re-deriving the flag, so the policy lives in one place.
--- Returns nil when the manager/settings are not available yet (pre-init or the
--- offline test bench); callers decide what nil means.
---@return boolean|nil
function ReleaseGate.liveOptIn()
    local s = g_SoilFertilityManager and g_SoilFertilityManager.settings
    if s and s.allowsExperimentalSystems then
        return s:allowsExperimentalSystems()
    end
    return nil
end

--- A system is LIVE right now: released, or the player has opted in. This is the
--- single predicate the sim entry points check. When false, the system's hooks
--- should not run / not arm / not be wired.
--- FAIL-OPEN: when the live settings cannot be read (nil manager, nil settings, or
--- a settings object without the predicate - e.g. the offline test bench), the
--- system counts as live. The gate is an explicit opt-out of NEW systems; it must
--- never silently disable a path just because the opt-in flag is not readable at
--- that moment. In a running game the manager is always present and carries the
--- predicate before any sim entry point fires, so nil only happens pre-init/tests.
---@param systemId string
---@return boolean
function ReleaseGate.isSystemLive(systemId)
    local optIn = ReleaseGate.liveOptIn()
    if optIn == nil then return true end
    return ReleaseGate.isReleased(systemId, optIn)
end

--- Refusal message when a system is locked; nil when released. Mirrors bypassLockedMsg().
---@param systemId string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.lockMessage(systemId, optIn)
    local entry = ReleaseGate.EXPERIMENTAL[systemId]
    if not entry or optIn == true then return nil end
    return string.format(
        "Locked: %s is not released yet. Enable Experimental Systems in the settings panel to use it at your own risk.",
        entry.name)
end

--- Console command gate. Mirrors bypassLockedMsg() but on the release axis.
---@param commandName string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.commandLockMessage(commandName, optIn)
    return ReleaseGate.lockMessage(ReleaseGate.COMMAND_TO_SYSTEM[commandName], optIn)
end

--- Player-friendly gate status, for the status/help surfaces and tests. Short on
--- purpose: one line per system, what is not working or implemented yet.
---@param optIn boolean|nil
---@return string
function ReleaseGate.status(optIn)
    local lines = { "=== Release gate ===" }
    lines[#lines + 1] = string.format("  Experimental systems: %s",
        optIn == true and "ON (at your own risk)" or "OFF (stable only)")
    local on = optIn == true
    if on then
        lines[#lines + 1] = "  All experimental systems: ON"
        for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
            lines[#lines + 1] = string.format("    [ON] %s", entry.name)
        end
    else
        lines[#lines + 1] = "  Not yet released:"
        for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
            lines[#lines + 1] = string.format("    [LOCKED] %s - %s", entry.name, entry.status)
        end
    end
    return table.concat(lines, "\n")
end

SoilLogger.info("Release gate loaded")
