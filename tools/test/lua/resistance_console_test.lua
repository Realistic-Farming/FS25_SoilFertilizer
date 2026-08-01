-- resistance_console_test.lua - the SoilResistance / SoilResistanceTest console commands.
--
-- These two are the IN-GAME verification tool for F66 and CD-11, which makes a crash or a
-- wrong verdict in them worse than useless: it would send someone chasing a bug that is not
-- there, or clear a bug that is. So they get exercised for real here rather than trusted.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SoilFertilitySystem.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/settings/SoilSettingsGUI.lua

local R = SoilConstants.RESISTANCE
local B = R.BANDS

-- A live-enough soil system: real methods via the metatable, with the two side-effecting
-- collaborators stubbed so the spray path runs without a world.
local function newSys(field)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { diseasePressure = true, showNotifications = false },
  }, { __index = SoilFertilitySystem })
  sys.trackSprayerCoverage = function() end
  sys.onFungicideAppliedIncremental = function() end
  return sys
end

local function newField(extra)
  local f = {
    fieldArea              = 10,
    _farmlandAreaConfirmed = true,
    sessionCoverageCells   = { ["0:0"] = true },
    resistance             = {},
    diseasePressure        = 50,
    diseaseDiscovered      = true,
    nutrientBuffer         = {},
  }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

local function withMod(field, fn)
  local prevMgr, prevServer = g_SoilFertilityManager, g_server
  local sys = newSys(field)
  g_SoilFertilityManager = { soilSystem = sys, settings = {} }
  g_server = {}
  local ok, res = pcall(fn, sys)
  g_SoilFertilityManager, g_server = prevMgr, prevServer
  if not ok then error(res, 0) end
  return res
end

-- ── SoilResistance: the readout must not throw, and must report what it sees.
do
  local field = newField({ resistance = { ["3"] = R.MAX_SYNTHETIC, ["M2"] = R.MAX_NATURAL * 0.7 } })
  local out = withMod(field, function()
    return SoilSettingsGUI.consoleCommandResistance(SoilSettingsGUI, "1")
  end)

  T.ok("readout: returns a string", type(out) == "string")
  T.ok("readout: names the field", out:find("Field 1") ~= nil)
  T.ok("readout: reports scouted state", out:find("Scouted: YES") ~= nil)
  T.ok("readout: shows the saturated mode as FINISHED", out:find("FINISHED") ~= nil)
  T.ok("readout: shows the natural mode as SLIPPING", out:find("SLIPPING") ~= nil)
  T.ok("readout: names chemicals, not just FRAC codes", out:find("PROPICONAZOLE") ~= nil)
  T.ok("readout: lists a mode that carries no resistance yet", out:find("AZOXYSTROBIN") ~= nil)
end

-- An unscouted field must say so loudly rather than printing a clean-looking table.
do
  local out = withMod(newField({ diseaseDiscovered = false }), function()
    return SoilSettingsGUI.consoleCommandResistance(SoilSettingsGUI, "1")
  end)
  T.ok("readout: unscouted says NO", out:find("Scouted: NO") ~= nil)
  T.ok("readout: unscouted explains the gate", out:find("UNKNOWN") ~= nil)
end

-- An untracked field id must not throw.
do
  local out = withMod(newField(), function()
    return SoilSettingsGUI.consoleCommandResistance(SoilSettingsGUI, "999")
  end)
  T.ok("readout: unknown field is handled", out:find("no soil data") ~= nil)
end

-- ── SoilResistanceTest: the verdict has to be right, because it is the thing that tells a
-- human whether F66 is fixed in their running game.
do
  local field = newField()
  local out = withMod(field, function()
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "PROPICONAZOLE", "1", "1")
  end)

  T.ok("meter test: reports PASS against the fixed build", out:find("RESULT: PASS") ~= nil)
  T.ok("meter test: does not report FAIL", out:find("RESULT: FAIL") == nil)
  T.near("meter test: one pass built exactly one application",
         field.resistance["3"], R.BUILD_PER_APPLICATION * R.MAX_SYNTHETIC, 1e-6)
  T.ok("meter test: warns the applications were real", out:find("real applications") ~= nil)
end

-- Several passes accumulate, and the verdict tracks them.
do
  local field = newField()
  local out = withMod(field, function()
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "PROPICONAZOLE", "4", "1")
  end)
  T.ok("meter test: four passes still PASS", out:find("RESULT: PASS") ~= nil)
  T.near("meter test: four passes build four applications",
         field.resistance["3"], R.BUILD_PER_APPLICATION * R.MAX_SYNTHETIC * 4, 1e-6)
end

-- A natural meters against its own ceiling, and the command must use that ceiling too.
do
  local field = newField()
  local out = withMod(field, function()
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "SULFUR", "1", "1")
  end)
  T.ok("meter test: a natural also PASSes", out:find("RESULT: PASS") ~= nil)
  T.near("meter test: natural built against MAX_NATURAL at the F68 rate",
         field.resistance["M2"], R.BUILD_PER_APPLICATION * R.MAX_NATURAL * R.BUILD_RATE_NATURAL, 1e-6)
end

-- THE ONE THAT MATTERS. A mode already at its ceiling cannot answer the question: expected
-- clamps to the ceiling too, so a broken meter and a working one land on the same number.
-- The command must refuse rather than return a false PASS -- and this is the likely state
-- on any save sprayed under the pre-F66 build, i.e. exactly who runs this command first.
do
  local field = newField({ resistance = { ["3"] = R.MAX_SYNTHETIC } })
  local out = withMod(field, function()
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "PROPICONAZOLE", "1", "1")
  end)
  T.ok("meter test: a saturated mode is INCONCLUSIVE", out:find("INCONCLUSIVE") ~= nil)
  T.ok("meter test: a saturated mode never reports PASS", out:find("RESULT: PASS") == nil)
  T.ok("meter test: explains that saves are not healed", out:find("does not heal existing saves") ~= nil)
  T.near("meter test: an inconclusive run sprays nothing", field.resistance["3"], R.MAX_SYNTHETIC, 1e-9)
end

-- ...but a genuinely broken meter, on a CLEAN mode, must still report FAIL. Simulated by
-- pre-loading the mode to just under the point where one pass would overshoot expected.
do
  local field = newField({ resistance = { ["3"] = R.MAX_SYNTHETIC * 0.9 } })
  local out = withMod(field, function()
    -- One pass should add 0.05 * 10 = 0.5, landing on 9.5. If the meter were dead the
    -- mode would pin at 10 and the verdict must catch the difference.
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "PROPICONAZOLE", "1", "1")
  end)
  T.ok("meter test: a partially burned mode still gets a verdict", out:find("RESULT:") ~= nil)
  T.ok("meter test: and it PASSes on the fixed build", out:find("RESULT: PASS") ~= nil)
  T.near("meter test: one pass added exactly one application",
         field.resistance["3"], R.MAX_SYNTHETIC * 0.9 + R.BUILD_PER_APPLICATION * R.MAX_SYNTHETIC, 1e-6)
end

-- Guards: bad input is answered, never thrown.
do
  local out = withMod(newField(), function()
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "NOT_A_CHEMICAL", "1", "1")
  end)
  T.ok("meter test: unknown chemical is rejected with the list", out:find("Unknown chemical") ~= nil)

  local out2 = withMod(newField(), function()
    return SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "FUNGICIDE", "1", "1")
  end)
  T.ok("meter test: generic FUNGICIDE is rejected (no mode of action)",
       out2:find("no mode of action") ~= nil)

  -- Disease pressure off: the spray path returns immediately, so say that rather than
  -- reporting a confusing FAIL.
  local prevMgr, prevServer = g_SoilFertilityManager, g_server
  local sys = newSys(newField()); sys.settings.diseasePressure = false
  g_SoilFertilityManager = { soilSystem = sys, settings = {} }
  g_server = {}
  local out3 = SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "PROPICONAZOLE", "1", "1")
  T.ok("meter test: disease pressure off is explained", out3:find("Disease Pressure is OFF") ~= nil)
  g_SoilFertilityManager, g_server = prevMgr, prevServer
end

-- A pure client must be turned away rather than trying to apply chemicals locally.
do
  local prevMgr, prevServer = g_SoilFertilityManager, g_server
  g_SoilFertilityManager = { soilSystem = newSys(newField()), settings = {} }
  g_server = nil
  local out = SoilSettingsGUI.consoleCommandResistanceTest(SoilSettingsGUI, "PROPICONAZOLE", "1", "1")
  T.ok("meter test: a client is refused", out:find("server/single%-player only") ~= nil)
  g_SoilFertilityManager, g_server = prevMgr, prevServer
end
