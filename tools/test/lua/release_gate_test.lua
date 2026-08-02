-- release_gate_test.lua - the release gate (STABLE vs experimental-LOCKED).
--
-- The gate is orthogonal to difficulty and mirrors the bypass lock, but on the
-- release axis. Arissani's certification (2026-08-02): a system is LOCKED until
-- built+observed, its surface exists, high defects are closed, and it is
-- balance-safe. Releasing is a deliberate act, never a default.
--!load: src/utils/Logger.lua, src/ReleaseGate.lua

-- Sanity: every registered system id exists in the EXPERIMENTAL table, and every
-- command in COMMAND_TO_SYSTEM maps to a known system.
T.ok("cd9_resistance registered", ReleaseGate.EXPERIMENTAL.cd9_resistance ~= nil)
T.ok("cd10_hybrids registered", ReleaseGate.EXPERIMENTAL.cd10_hybrids ~= nil)
T.ok("cd12_tank_mixes registered", ReleaseGate.EXPERIMENTAL.cd12_tank_mixes ~= nil)
T.ok("ground_material registered", ReleaseGate.EXPERIMENTAL.ground_material ~= nil)
T.ok("spatial_soil registered", ReleaseGate.EXPERIMENTAL.spatial_soil ~= nil)
T.ok("read_the_dirt registered", ReleaseGate.EXPERIMENTAL.read_the_dirt ~= nil)

local known = 0
for _, sys in pairs(ReleaseGate.COMMAND_TO_SYSTEM) do
    if ReleaseGate.EXPERIMENTAL[sys] ~= nil then known = known + 1 end
end
T.eq("every command maps to a known system", known, 4)

-- isReleased: a non-experimental system is always released regardless of opt-in.
T.ok("stable system released with no opt-in", ReleaseGate.isReleased("fertilitySystem", nil) == true)
T.ok("stable system released with opt-in on", ReleaseGate.isReleased("fertilitySystem", true) == true)
T.ok("stable system released with opt-in off", ReleaseGate.isReleased("fertilitySystem", false) == true)

-- isReleased: an experimental system is LOCKED until the explicit opt-in.
T.ok("cd9 LOCKED by default", ReleaseGate.isReleased("cd9_resistance", nil) == false)
T.ok("cd9 LOCKED with opt-in off", ReleaseGate.isReleased("cd9_resistance", false) == false)
T.ok("cd9 released when opt-in on", ReleaseGate.isReleased("cd9_resistance", true) == true)

-- Every experimental system behaves the same way.
for sys in pairs(ReleaseGate.EXPERIMENTAL) do
    T.ok(sys .. " LOCKED when opt-in off", ReleaseGate.isReleased(sys, false) == false)
    T.ok(sys .. " released when opt-in on", ReleaseGate.isReleased(sys, true) == true)
end

-- lockMessage: nil when released, a refusal string when locked.
T.eq("no lock message for a stable system", ReleaseGate.lockMessage("fertilitySystem", nil), nil)
T.eq("no lock message when opted in", ReleaseGate.lockMessage("cd9_resistance", true), nil)
local msg = ReleaseGate.lockMessage("cd9_resistance", false)
T.ok("lock message when locked", msg ~= nil)
T.ok("message names the released-gate state", string.find(msg, "not released", 1, true) ~= nil)
T.ok("message points at the settings opt-in", string.find(msg, "settings panel", 1, true) ~= nil)

-- commandLockMessage routes through the same registry.
T.ok("SoilResistance gated when locked", ReleaseGate.commandLockMessage("SoilResistance", false) ~= nil)
T.eq("SoilResistance ungated when opted in", ReleaseGate.commandLockMessage("SoilResistance", true), nil)
T.ok("SoilBlendCheck gated when locked", ReleaseGate.commandLockMessage("SoilBlendCheck", false) ~= nil)
T.ok("SoilMaterialBench gated when locked", ReleaseGate.commandLockMessage("SoilMaterialBench", false) ~= nil)
T.ok("SoilResistanceTest gated when locked", ReleaseGate.commandLockMessage("SoilResistanceTest", false) ~= nil)
T.eq("an ungated command has no lock message", ReleaseGate.commandLockMessage("SoilSetDisease", false), nil)

-- status: player-friendly, short, one line per system.
local st = ReleaseGate.status(false)
T.ok("status says OFF when not opted in", string.find(st, "OFF", 1, true) ~= nil)
T.ok("status lists LOCKED systems", string.find(st, "LOCKED", 1, true) ~= nil)
T.ok("status uses the player-facing status note", string.find(st, "awaiting", 1, true) ~= nil)
T.ok("status does not leak the internal reason", string.find(st, "F66", 1, true) == nil)
local stOn = ReleaseGate.status(true)
T.ok("status says ON when opted in", string.find(stOn, "ON", 1, true) ~= nil)
T.ok("status shows ON per system when opted in", string.find(stOn, "[ON]", 1, true) ~= nil)
T.ok("status omits the awaiting notes when opted in", string.find(stOn, "awaiting", 1, true) == nil)
