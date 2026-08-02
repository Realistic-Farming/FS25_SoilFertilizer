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

-- The certified experimental (LOCKED) set. Each entry: [systemId] = { name, reason }.
-- `reason` is the four-test clause that fails, from Arissani's first lock set.
-- A system that is NOT in this table is released (the proven baseline).
ReleaseGate.EXPERIMENTAL = {
    cd9_resistance  = { name = "Disease resistance",    reason = "F66/F67 open, unobserved" },
    cd10_hybrids    = { name = "Hybrid strains",        reason = "rides CD-9, readout unshipped, unobserved" },
    cd12_tank_mixes = { name = "Tank mixes",            reason = "in-game acceptance owed, readout gap" },
    ground_material = { name = "Ground material",       reason = "bale/wetness/conversion unobserved, surface blocked" },
    spatial_soil    = { name = "Spatial soil",          reason = "4/14 built, no per-cell UI" },
    read_the_dirt   = { name = "Read the Dirt",         reason = "panel SF-39 (Wizard) unbuilt" },
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

--- Refusal message when a system is locked; nil when released. Mirrors bypassLockedMsg().
---@param systemId string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.lockMessage(systemId, optIn)
    local entry = ReleaseGate.EXPERIMENTAL[systemId]
    if not entry or optIn == true then return nil end
    return string.format(
        "Locked: %s is experimental and not released (%s). Enable experimental systems in the settings panel to use it at your own risk.",
        entry.name, entry.reason)
end

--- Console command gate. Mirrors bypassLockedMsg() but on the release axis.
---@param commandName string
---@param optIn boolean|nil
---@return string|nil
function ReleaseGate.commandLockMessage(commandName, optIn)
    return ReleaseGate.lockMessage(ReleaseGate.COMMAND_TO_SYSTEM[commandName], optIn)
end

--- Human-readable gate status table, for the status/help surfaces and tests.
---@param optIn boolean|nil
---@return string
function ReleaseGate.status(optIn)
    local lines = { "=== Release gate ===" }
    lines[#lines + 1] = string.format("  Experimental systems: %s",
        optIn == true and "ON (opt-in, at your own risk)" or "OFF (stable only)")
    local released, locked = 0, 0
    for id in pairs(ReleaseGate.EXPERIMENTAL) do
        if ReleaseGate.isReleased(id, optIn) then released = released + 1 else locked = locked + 1 end
    end
    lines[#lines + 1] = string.format("  Systems: %d stable, %d experimental-locked", released, locked)
    for id, entry in pairs(ReleaseGate.EXPERIMENTAL) do
        lines[#lines + 1] = string.format("    [%s] %s - %s", ReleaseGate.isReleased(id, optIn) and "STABLE" or "LOCKED", entry.name, entry.reason)
    end
    return table.concat(lines, "\n")
end

SoilLogger.info("Release gate loaded")
