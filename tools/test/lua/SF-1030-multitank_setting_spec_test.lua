-- SF-1030-multitank_setting_spec_test.lua: #1030 bug 2, the Multi-tank application
-- setting is honoured.
--
-- The sprayer hook's secondary-tank block read hookMgrRef._settings.multiTankApplication.
-- Nothing assigns _settings, so the read was always nil, `nil ~= false` passed, and every
-- secondary tank was drained and credited with the setting switched off. The fix reads
-- g_SoilFertilityManager.settings, where the same hook's entry guard reads `enabled`.
--
-- ENTRY-POINT BAR: the real HookManager.installSprayerAreaHook appends to
-- Sprayer.onEndWorkAreaProcessing and every pass runs through that append. The setting
-- lives on the REAL Settings object (Settings.new, schema defaults), written the way the
-- settings hub writes a change (SoilSettingsHubBridge applyChange: SettingsSchema.validate,
-- then assign). No fixture sets hookMgr._settings, or anything else the hook is meant to
-- find for itself.
--
--   D    a fresh Settings object has the setting ON; the secondary is drained and credited
--   OFF  the setting written false: the secondary is neither drained nor credited, and the
--        driving product is still credited once
--   ON   written back true: drained and credited again
--   NIL  an old save with no key (nil) stays ON, the `~= false` test
--
-- Targeted mutation: revert the read to hookMgrRef._settings; the OFF rows must fail.
--
-- Not proven here: native's drain of the driving tank (from the registered LPS), the
-- settings panel itself, and the MP setting-change event (the block is server-only, so
-- the server's value decides).
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua

FillType = FillType or { UNKNOWN = 0 }
ToolType = ToolType or { UNDEFINED = 0 }

-- A group that raises is reported as a named failing row, so a crash stays attributable.
local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- Fixture fill types (indices are fixtures, names are shipped profile keys), as in
-- RSF-F196-unit_rule_test.lua group G.
local FT = {
  UREA    = { name = "UREA",    index = 50, massPerLiter = 0.00077 },
  COMPOST = { name = "COMPOST", index = 51, massPerLiter = 0.0006  },
}
local BY_INDEX, BY_NAME = {}, {}
for _, ft in pairs(FT) do BY_INDEX[ft.index] = ft; BY_NAME[ft.name] = ft end

local savedFtm, savedSprayer, savedUtils, savedSfm = g_fillTypeManager, Sprayer, Utils, g_SoilFertilityManager
g_fillTypeManager = {
  getFillTypeByIndex = function(_, i) return BY_INDEX[i] end,
  getFillTypeByName  = function(_, n) return BY_NAME[n] end,
}
-- The engine's composition helpers, as RSF-F226d models them: the installer appends
-- the real hook through these.
Utils = {
  prependedFunction = function(orig, new)
    return function(...) new(...) if orig then return orig(...) end end
  end,
  appendedFunction = function(orig, new)
    return function(...)
      local r = orig and { orig(...) } or {}
      new(...)
      return unpack(r)
    end
  end,
}

--- The player's settings: the real Settings object, one change written the way the
--- settings hub writes it. `value` of "absent" removes the key, as a save from before
--- the setting existed would leave it.
local function newSettings(value)
  local s = Settings.new(nil)
  s.save = function() end   -- the fixture has no savegame; the value is the point
  -- The overlap pass skip is its own feature (RSF-F226d); keep it out of this pass.
  s.overlapPrevention = SettingsSchema.validate("overlapPrevention", false)
  if value == "absent" then
    s.multiTankApplication = nil
  elseif value ~= nil then
    s.multiTankApplication = SettingsSchema.validate("multiTankApplication", value)
  end
  return s
end

local function newWorld(settings)
  local seen = { calls = {} }
  local soilSys = {
    fieldData = { [7] = { sessionCoverageCells = {}, sessionCoverageFraction = 0.0 } },
    onFertilizerApplied = function(_s, fid, ftIdx, liters)
      seen.calls[#seen.calls + 1] = { fid = fid, ft = ftIdx, liters = liters }
      return true
    end,
    trackSprayerCoverage = function() end,
    markBoomCells = function() end, paintBoomStrip = function() end,
    applyBurnEffect = function() end, applyScorchEffect = function() end,
    onHerbicideAppliedDirect = function() end, onInsecticideAppliedDirect = function() end, onFungicideAppliedDirect = function() end,
  }
  g_SoilFertilityManager = { settings = settings, soilSystem = soilSys }
  local hookMgr = setmetatable({
    hooks = {}, register = function() end, registerCleanup = function() end,
    getFieldIdAtWorldPosition = function() return 7 end,
    getBoomCellPositions = function() return { { x = 10, z = 10 } } end,
    getBoomLineEndpoints = function() return nil end,
    _sectionScratch = {},
    customFillTypePrices = {},
    customProductIndices = { [50] = true, [51] = true },
    refusedProducts = {},
  }, { __index = HookManager })
  return seen, hookMgr
end

--- A two-tank rig drawing from its own tank 1 (UREA); tank 2 holds COMPOST.
local function newSprayer(units)
  local v = {
    isServer = true, id = "veh1",
    spec_workArea = { workAreas = {} },
    spec_variableWorkWidth = { sections = { { isActive = true } } },
    _sfRootX = 10, _sfRootZ = 10,
    getIsTurnedOn = function() return true end,
    getLastSpeed  = function() return 8.0 end,
    getSprayerFillUnitIndex = function() return 1 end,
    getFillUnitFillLevel = function(_s, i) local u = units[i]; return u and u.fillLevel or 0 end,
    getFillUnitFillType  = function(_s, i) local u = units[i]; return u and u.fillType or 0 end,
    getOwnerFarmId = function() return 1 end,
    addFillUnitFillLevel = function() return 0 end,
    raiseDirtyFlags = function() end,
  }
  v.spec_sprayer = {
    workAreaParameters = {
      sprayFillType = 50, usage = 2.0, sprayFillLevel = 900, isActive = true,
      sprayVehicle = v, sprayVehicleFillUnitIndex = 1,
    },
    effects = {}, sprayTypes = {},
  }
  v.spec_fillUnit = { fillUnits = units }
  v.processSprayerArea = function() return 250, 3 end
  local wa = { functionName = "processSprayerArea" }
  wa.processingFunction = v.processSprayerArea
  table.insert(v.spec_workArea.workAreas, wa)
  return v
end

local function runPass(settings)
  Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
  local seen, hookMgr = newWorld(settings)
  HookManager.installSprayerAreaHook(hookMgr)
  local units = { [1] = { fillLevel = 900, fillType = 50 }, [2] = { fillLevel = 500, fillType = 51 } }
  local v = newSprayer(units)
  Sprayer.onStartWorkAreaProcessing(v, 16)
  v.spec_workArea.workAreas[1].processingFunction(v, v.spec_workArea.workAreas[1], 16)
  Sprayer.onEndWorkAreaProcessing(v, 16, true)
  return seen, units
end

local function countOf(seen, ftIdx)
  local n = 0
  for _, c in ipairs(seen.calls) do if c.ft == ftIdx then n = n + 1 end end
  return n
end

group("D default", function()
  local s = newSettings(nil)
  T.eq("D1 [reached: the real Settings object carries the schema default] multiTankApplication is ON", s.multiTankApplication, true)
  local seen, units = runPass(s)
  T.eq("D2 [reached: the appended hook ran] the driving product is credited once", countOf(seen, 50), 1)
  T.eq("D3 the secondary tank is credited under its own product", countOf(seen, 51), 1)
  T.ok("D4 and drained", units[2].fillLevel < 500)
end)

group("OFF setting off", function()
  local s = newSettings(false)
  T.eq("OFF1 [reached: the change landed on the real Settings object]", s.multiTankApplication, false)
  local seen, units = runPass(s)
  T.eq("OFF2 [reached: the appended hook ran] the driving product is still credited once", countOf(seen, 50), 1)
  T.eq("OFF3 NAMED: with the setting off the secondary tank is NOT credited", countOf(seen, 51), 0)
  T.eq("OFF4 NAMED: and NOT drained", units[2].fillLevel, 500)
  T.eq("OFF5 and nothing else is credited", #seen.calls, 1)
end)

group("ON setting back on", function()
  local s = newSettings(false)
  s.multiTankApplication = SettingsSchema.validate("multiTankApplication", true)
  local seen, units = runPass(s)
  T.eq("ON1 switched back on, the secondary is credited again", countOf(seen, 51), 1)
  T.ok("ON2 and drained", units[2].fillLevel < 500)
end)

group("NIL old save", function()
  local s = newSettings("absent")
  T.eq("NIL1 [reached: the key is absent, as in a save from before the setting]", s.multiTankApplication, nil)
  local seen, units = runPass(s)
  T.eq("NIL2 an absent key keeps the default: the secondary is credited", countOf(seen, 51), 1)
  T.ok("NIL3 and drained", units[2].fillLevel < 500)
end)

Sprayer, Utils, g_SoilFertilityManager = savedSprayer, savedUtils, savedSfm
g_fillTypeManager = savedFtm
