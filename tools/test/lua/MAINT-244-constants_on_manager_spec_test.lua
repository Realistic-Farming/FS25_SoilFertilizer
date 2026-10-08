-- MAINT-244-constants_on_manager_spec_test.lua
--
-- MAINTENANCE row 244 (Tyson's call on Bob's fleet sweep row 4): Soil publishes its constants
-- on the manager.
--
-- THE DEFECT THIS PINS (development 437ca320): SoilConstants is a global of Soil's own mod
-- environment (src/config/Constants.lua:12, sourced into the mod's env as every mod chunk is,
-- dataS mods.lua:436-442), and Soil published it on none of the three manager fields FarmTablet's
-- Soil app probes (FarmTablet src/apps/SoilNutrientApp.lua:22-35 at 29fd75c: mgr.SoilConstants,
-- mgr.soilSystem.SoilConstants, mgr.constants). The Tablet's bare and getfenv(0) reads run in the
-- Tablet's own environment, so the app found nothing and painted N, P and K at factor 1: Soil's
-- internal units labelled "ppm" (N a third of the real value, P 1.7 times it, K a quarter).
--
-- THE FIX: main.lua's load puts SoilConstants on the manager beside the mission handle
-- (sfm.SoilConstants = SoilConstants), the first field the Tablet probes.
--
-- THE ENTRY-POINT BAR IS GROUP E. No Soil bench can execute all of src/main.lua (it sources every
-- module), so, as RSF-F190's bar does, this bar executes main.lua's OWN statements, read from its
-- text (--!text) at the site where load publishes the manager (from the getfenv(0) write through
-- the RfPdaSoilMerge block), in Soil's mod environment (--!env: modenv) with the real
-- src/config/Constants.lua loaded there, getfenv(0) mapped to that environment as mods.lua maps
-- it. The manager is the only stand-in (a table: SoilFertilityManager.new sources every module).
-- The consumer is FarmTablet's own _manager and _soilConstants, verbatim from
-- src/apps/SoilNutrientApp.lua:14-35 at 29fd75c, run in a FarmTablet environment built the same
-- way, which reaches Soil only through the mission. Nothing puts a constant on the manager by
-- hand.
--
--   E0  the world: the site is present once; Constants.lua's SoilConstants lives in Soil's
--       environment only (the real global table and the Tablet's environment have none)
--   E1  main.lua's site puts Soil's own SoilConstants table on the manager
--   E2  the Tablet's _soilConstants, from its own environment, returns that table: the
--       PPM_DISPLAY scale is N 3.0, P 0.6, K 4.0 (not the factor-1 fallback). The app also reads
--       SC.PH_OPTIMAL, which Soil keeps at NUTRIENT_LIMITS.PH_OPTIMAL; its 6.5 fallback equals it,
--       so no row pins it (it would pass either way).
--   E3  the Tablet's treatment text, fed the constants it now reaches, names product rates (UREA in
--       kg/ha, UAN32 in L/ha) where development showed only the static line
--
--!env: modenv
--!load: src/utils/Logger.lua, src/config/Constants.lua
--!text: src/main.lua

local SOIL_ENV = _ENV
local REAL_G = getmetatable(SOIL_ENV).__index

local MAIN = ((SOURCE_TEXT and SOURCE_TEXT["src/main.lua"]) or ""):gsub("\r\n", "\n")

--- One production site of main.lua, from `first` through `last`, or nil when absent.
local function site(first, last)
  local i = MAIN:find(first, 1, true)
  if i == nil then return nil, 0 end
  local j = MAIN:find(last, i, true)
  if j == nil then return nil, 0 end
  local n, from = 0, 1
  while true do
    local k = MAIN:find(first, from, true)
    if k == nil then break end
    n, from = n + 1, k + 1
  end
  return MAIN:sub(i, j + #last - 1), n
end
local PUBLISH, nPublish = site('getfenv(0)["g_SoilFertilityManager"] = sfm',
  "mission.RfPdaSoilMerge = RfPdaSoilMerge\n        end")

-- FarmTablet src/apps/SoilNutrientApp.lua:14-35 and :132-176 at 29fd75c, verbatim (the reads and the
-- treatment rate text), joined in one chunk as they sit in one file.
local TABLET_READ = [==[
local function _manager()
    return (g_currentMission and g_currentMission.soilFertilityManager)
        or getfenv(0)["g_SoilFertilityManager"]
end

--- SoilConstants is owned by FS25_SoilFertilizer (often not in FT getfenv).
--- Prefer the live manager / soilSystem attachment, then globals.
local function _soilConstants()
    local mgr = _manager()
    if mgr ~= nil then
        if mgr.SoilConstants ~= nil then return mgr.SoilConstants end
        if mgr.soilSystem ~= nil and mgr.soilSystem.SoilConstants ~= nil then
            return mgr.soilSystem.SoilConstants
        end
        if mgr.constants ~= nil then return mgr.constants end
    end
    if SoilConstants ~= nil then return SoilConstants end
    local ok, sc = pcall(function() return getfenv(0)["SoilConstants"] end)
    if ok and sc ~= nil then return sc end
    return nil
end

local function _rateString(SC, profileKey, nutrientKey, deficit, rrMult, fieldArea)
    if deficit <= 0 or SC == nil then return nil end
    local profiles = SC.FERTILIZER_PROFILES
    local baseRates = SC.SPRAYER_RATE and SC.SPRAYER_RATE.BASE_RATES
    local profile = profiles and profiles[profileKey]
    local baseRate = baseRates and baseRates[profileKey]
    if not profile or not profile[nutrientKey] or profile[nutrientKey] == 0 then return nil end

    local coeff = profile[nutrientKey]
    local ratePerHa = deficit * 1000 / (coeff * rrMult)
    local total = ratePerHa * fieldArea
    local isDry = baseRate and baseRate.unit == "dry"
    local mgr = _manager()
    local useImp = mgr and mgr.settings and mgr.settings.useImperialUnits

    local displayRate, displayTotal, unit, totalUnit
    if useImp and SC.SPRAYER_RATE then
        if isDry then
            displayRate = math.ceil(ratePerHa * (SC.SPRAYER_RATE.KG_PER_HA_TO_LB_PER_AC or 0.892))
            displayTotal = math.ceil(total * 2.20462)
            unit, totalUnit = "lb/ac", "lb"
        else
            displayRate = math.ceil(ratePerHa * (SC.SPRAYER_RATE.L_PER_HA_TO_GAL_PER_AC or 0.107))
            displayTotal = math.ceil(total * 0.26417)
            unit, totalUnit = "gal/ac", "gal"
        end
    else
        displayRate = math.ceil(ratePerHa)
        displayTotal = math.ceil(total)
        unit, totalUnit = isDry and "kg/ha" or "L/ha", isDry and "kg" or "L"
    end

    return string.format("%s %d %s (%d %s)", profileKey, displayRate, unit, displayTotal, totalUnit)
end

local function _nutrientActionText(SC, currentVal, targetVal, rrMult, fieldArea, products, staticFallback)
    local deficit = math.max(0, targetVal - currentVal)
    local parts = {}
    for _, prod in ipairs(products) do
        local s = _rateString(SC, prod[1], prod[2], deficit, rrMult, fieldArea)
        if s then parts[#parts + 1] = FT.l10nAuto(s) end
    end
    if #parts == 0 then return staticFallback end
    return table.concat(parts, "  ·  ")
end
return { soilConstants = _soilConstants, actionText = _nutrientActionText }
]==]

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The mission (a shared engine object, so it lives in the real global table) and the manager
-- main.lua's load has just built.
local mission = {}
local sfm = { soilSystem = {} }
local savedMission = REAL_G.g_currentMission
REAL_G.g_currentMission = mission

-- A FarmTablet environment, built as mods.lua builds one.
local FT_ENV = setmetatable({}, { __index = REAL_G })
FT_ENV._G = FT_ENV
FT_ENV.getfenv = function() return FT_ENV end
FT_ENV.FT = { l10nAuto = function(s) return s end }   -- FarmTablet's key lookup: the text itself
local TABLET = assert(load(TABLET_READ, "=FarmTablet SoilNutrientApp.lua", "t", FT_ENV))()

group("E0", function()
  T.ok("E0: main.lua's publish site is present", PUBLISH ~= nil)
  T.eq("E0: and present once", nPublish, 1)
  T.ok("E0: Constants.lua defined SoilConstants in Soil's environment", rawget(SOIL_ENV, "SoilConstants") ~= nil)
  T.eq("E0: the real global table has no SoilConstants", rawget(REAL_G, "SoilConstants"), nil)
  T.eq("E0: the Tablet's environment sees no SoilConstants", FT_ENV.SoilConstants, nil)
end)

group("E1", function()
  -- main.lua's site, run where main.lua runs: Soil's environment, with load's locals.
  local env = setmetatable({ sfm = sfm, mission = mission }, { __index = SOIL_ENV })
  env.getfenv = function() return SOIL_ENV end
  assert(load(PUBLISH, "=src/main.lua", "t", env))()
  T.ok("E1: the mission carries Soil's manager", mission.soilFertilityManager == sfm)
  T.ok("E1: the manager carries Soil's own SoilConstants table", sfm.SoilConstants == rawget(SOIL_ENV, "SoilConstants"))
end)

group("E2", function()
  local SC = TABLET.soilConstants()
  T.ok("E2: the Tablet's read reaches Soil's constants", SC ~= nil and SC == rawget(SOIL_ENV, "SoilConstants"))
  -- SoilNutrientApp.lua:627-629: the scale the Soil app paints with.
  local ppm = (SC and SC.PPM_DISPLAY) or { N = 1, P = 1, K = 1 }
  T.eq("E2: N is shown at Soil's scale 3.0, not factor 1", ppm.N, 3.0)
  T.eq("E2: P is shown at Soil's scale 0.6", ppm.P, 0.6)
  T.eq("E2: K is shown at Soil's scale 4.0", ppm.K, 4.0)
end)

group("E3", function()
  -- The N treatment row as _buildTreatments builds it (SoilNutrientApp.lua:224-225): a field at 30 against
  -- a target of 50, 2 ha, the default replenishment multiplier.
  local products, static = { { "UREA", "N" }, { "UAN32", "N" } }, "Apply UREA or UAN32"
  local SC = TABLET.soilConstants()
  local text = TABLET.actionText(SC, 30, 50, 1.0, 2.0, products, static)
  T.ok("E3: with Soil's constants the N row names a UREA rate in kg/ha", text:find("UREA %d+ kg/ha %(%d+ kg%)") ~= nil, text)
  T.ok("E3: and a UAN32 rate in L/ha", text:find("UAN32 %d+ L/ha %(%d+ L%)") ~= nil, text)
  T.eq("E3: without them (development) the row is the static text", TABLET.actionText(nil, 30, 50, 1.0, 2.0, products, static), static)
end)

REAL_G.g_currentMission = savedMission
