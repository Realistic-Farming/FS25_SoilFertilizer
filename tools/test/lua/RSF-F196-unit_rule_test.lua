-- RSF-F196-unit_rule_test.lua: slice 3, the rate contract and the unit rule.
--
-- A dry product's public rate is KILOGRAMS per hectare; every stored, drained,
-- billed and transmitted quantity is engine LITRES (U1). Before this slice the
-- registration treated kilograms as litres (customLPS = rate / 36000) and every
-- interpretation site compared raw litres with a kg/ha number. This bar pins:
--   C2  registration: litersPerSecond = (rateKgHa / kgPerLiter) / 36000, so one
--       hectare at 1.0x drains exactly the configured mass;
--   U2  the one conversion (HookManager.massEquivalent), litres x density;
--   U3  the four interpretation sites, each driven through its REAL body: the
--       nutrient factor, the fully-treated comparison, the litre-fallback coverage,
--       and the HUD ghost bar, which must use the same function as the threshold;
--   U4  passthrough: liquids, base-game FERTILIZER and LIME convert by nothing;
--   U5  a secondary fill unit is credited under ITS OWN product's density;
--   U5b the driving unit is excluded from the secondary enumeration by identity,
--       using fields the engine writes; a single-tank pass is counted ONCE.
--
-- What this bar does NOT prove: engine spray-type registration, real tank drain
-- (native does that from the registered LPS), density-map execution, rendering.
-- Densities are fixtures in the engine's tonnes-per-litre unit (0.00077 = 0.77 kg/L).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ui/SoilHUD.lua

-- The engine global the catalogue rebuild reads: registration now builds the identity
-- catalogue on every attempt (the #974 wiring hotfix), and group B drives the real registration.
FillType = FillType or { UNKNOWN = 0 }

local BR  = SoilConstants.SPRAYER_RATE.BASE_RATES
local PF  = SoilConstants.FERTILIZER_PROFILES
local RR  = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[3]
local TUN = SoilConstants.TUNING.RATE_MULT[3]
local THR = SoilConstants.SPRAYER_RATE.FERTILIZER_COVERAGE_THRESHOLD or 0.90

-- Fixture fill types. Indices are fixtures; names are shipped profile keys.
local FT = {
  UREA       = { name = "UREA",       index = 50, massPerLiter = 0.00077 },  -- 0.77 kg/L
  COMPOST    = { name = "COMPOST",    index = 51, massPerLiter = 0.0006  },  -- 0.60 kg/L
  GYPSUM     = { name = "GYPSUM",     index = 52, massPerLiter = 0.0011  },  -- 1.10 kg/L
  FERTILIZER = { name = "FERTILIZER", index = 42, massPerLiter = 0.001   },  -- base game, passthrough
  INSECTICIDE= { name = "INSECTICIDE",index = 60, massPerLiter = 0.001   },  -- crop protection, passthrough
}
local BY_INDEX, BY_NAME = {}, {}
for _, ft in pairs(FT) do BY_INDEX[ft.index] = ft; BY_NAME[ft.name] = ft end

local savedFtm = g_fillTypeManager
g_fillTypeManager = {
  getFillTypeByIndex = function(_, i) return BY_INDEX[i] end,
  getFillTypeByName  = function(_, n) return BY_NAME[n] end,
}

local function factorFor(ft, liters, areaHa)
  local kg = HookManager.rateKgPerLiter(ft) or 1
  return (liters * kg / 1000) / areaHa * RR * TUN
end

-- =====================================================================
-- GROUP A: the conversion contract (U2/U4).
-- =====================================================================
T.eq("U A1: twelve dry products", #HookManager.DRY_PRODUCT_NAMES, 12)
for _, n in ipairs(HookManager.DRY_PRODUCT_NAMES) do
  T.eq("U A2: " .. n .. " is one of the twelve", HookManager.isDryProductName(n), true)
end
T.eq("U A3: FERTILIZER (base game, dry in the public table) is NOT F196's", HookManager.isDryProductName("FERTILIZER"), false)
T.eq("U A4: LIME is not",                       HookManager.isDryProductName("LIME"), false)
T.eq("U A5: a liquid is not",                   HookManager.isDryProductName("LIQUIDFERTILIZER"), false)
T.eq("U A6: nil name is not",                   HookManager.isDryProductName(nil), false)
T.near("U A7: UREA at 0.00077 t/L is 0.77 kg/L", HookManager.rateKgPerLiter(FT.UREA), 0.77, 1e-9)
T.eq("U A8: FERTILIZER is passthrough (nil)",   HookManager.rateKgPerLiter(FT.FERTILIZER), nil)
T.eq("U A9: nil fill type is passthrough",      HookManager.rateKgPerLiter(nil), nil)
T.eq("U A10: a dry name with an unusable density is passthrough here (it never reaches a site: refused at registration)",
     HookManager.rateKgPerLiter({ name = "UREA", massPerLiter = -1 }), nil)
T.near("U A11: 1000 L of UREA is 770 kg-equivalent",  HookManager.massEquivalent(FT.UREA, 1000), 770, 1e-9)
T.eq("U A12: 1000 L of FERTILIZER stays 1000",        HookManager.massEquivalent(FT.FERTILIZER, 1000), 1000)
T.eq("U A13: nil fill type is identity",              HookManager.massEquivalent(nil, 123.5), 123.5)
T.eq("U A14: zero litres is zero",                    HookManager.massEquivalent(FT.UREA, 0), 0)
T.near("U A15: GYPSUM above 1 kg/L converts UP",      HookManager.massEquivalent(FT.GYPSUM, 100), 110, 1e-9)

-- =====================================================================
-- GROUP B: C2 registration through the REAL registerCustomSprayTypes.
-- =====================================================================
do
  local savedStm = g_sprayTypeManager
  local declared = { UREA = 0.00077, COMPOST = 0.0006, GYPSUM = 0.0011 }
  local added = {}
  local regFtm = {
    getFillTypeByName = function(_s, name)
      if declared[name] == nil then return nil end
      return { name = name, index = #name, massPerLiter = declared[name] }
    end,
    getFillTypeIndexByName = function(_s, name)
      if declared[name] == nil then return nil end
      return #name
    end,
  }
  g_fillTypeManager = regFtm
  g_sprayTypeManager = {
    getSprayTypeByName = function(_s, name)
      if name == "FERTILIZER" then return { litersPerSecond = 0.006, sprayGroundType = 3 } end
      if name == "LIQUIDFERTILIZER" then return { litersPerSecond = 0.0081, sprayGroundType = 2 } end
      return nil
    end,
    addSprayType = function(_s, name, lps) added[name] = lps; return {} end,
  }
  local mgr = HookManager.new()
  local ok, err = pcall(HookManager.registerCustomSprayTypes, mgr)
  T.ok("U B0: registration ran (" .. tostring(err) .. ")", ok)
  T.near("U B1: UREA registers (rate / density) / 36000",      added.UREA,    (BR.UREA.value    / 0.77) / 36000, 1e-12)
  T.near("U B2: COMPOST at 0.60 kg/L",                         added.COMPOST, (BR.COMPOST.value / 0.60) / 36000, 1e-12)
  T.near("U B3: GYPSUM at 1.10 kg/L",                          added.GYPSUM,  (BR.GYPSUM.value  / 1.10) / 36000, 1e-12)
  T.ok("U B4: COMPOST now draws MORE litres per hectare than its kg/ha number (H2a)", added.COMPOST * 36000 > BR.COMPOST.value)
  T.ok("U B5: GYPSUM now draws FEWER",                                              added.GYPSUM  * 36000 < BR.GYPSUM.value)
  for _, n in ipairs({ "UREA", "COMPOST", "GYPSUM" }) do
    T.near("U B6: one hectare of " .. n .. " at the registered rate drains exactly the configured mass",
           added[n] * 36000 * (declared[n] * 1000), BR[n].value, 1e-9)
  end
  T.eq("U B7: nothing refused (all three densities valid)", next(mgr.refusedProducts), nil)
  g_sprayTypeManager = savedStm
  g_fillTypeManager = { getFillTypeByIndex = function(_, i) return BY_INDEX[i] end,
                        getFillTypeByName  = function(_, n) return BY_NAME[n] end }
end

-- =====================================================================
-- GROUP C: U3 site 1, the nutrient factor, through the REAL applyFertilizer.
-- =====================================================================
local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings  = { enabled = true, replenishmentRate = 3, showNotifications = true }
  s.fieldData = {}
  s._notices  = {}
  s.showNotification = function(_self, title, body) s._notices[#s._notices + 1] = { title = title, body = body } end
  return s
end
local function newField(s, fid, areaHa)
  local f = { fieldArea = areaHa, _farmlandAreaConfirmed = true,
              sessionCoverageCells = { seeded = true },
              nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.5 }
  s.fieldData[fid] = f
  return f
end
g_currentMission.time = 5000

do
  local s = newSys(); local f = newField(s, 1, 4.0)
  local n0 = f.nitrogen
  s:applyFertilizer(1, FT.UREA.index, 40, nil)
  T.near("U C1: UREA's litres become mass before the divide by area (x0.77)", f.nitrogen - n0, PF.UREA.N * factorFor(FT.UREA, 40, 4.0), 1e-9)
  T.ok("U C2: which is LESS than the same litres treated as kilograms", f.nitrogen - n0 < PF.UREA.N * (40 / 1000) / 4.0 * RR * TUN)
  T.eq("U C3: the buffer stays litres (U1)", f.nutrientBuffer[FT.UREA.index], 40)
end
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  local n0 = f.nitrogen
  s:applyFertilizer(1, FT.FERTILIZER.index, 40, nil)
  T.near("U C4: FERTILIZER (passthrough) is byte-for-byte the old arithmetic", f.nitrogen - n0, PF.FERTILIZER.N * (40 / 1000) / 4.0 * RR * TUN, 1e-9)
end
do
  -- THE INVARIANT: one hectare at 1.0x delivers the configured mass, and the
  -- agronomic consequence equals the pre-repair consequence of a full pass at the
  -- configured number. The tank drains rate/density litres per hectare (C2);
  -- converting back lands exactly `rate` at the factor.
  local s = newSys(); local f = newField(s, 1, 1.0)
  local n0 = f.nitrogen
  local litersFullHa = BR.UREA.value / 0.77
  s:applyFertilizer(1, FT.UREA.index, litersFullHa, nil)
  local preRepair = PF.UREA.N * (BR.UREA.value / 1000) / 1.0 * RR * TUN
  T.near("U C5: a full hectare of UREA at the C2 drain credits exactly the pre-repair full pass", f.nitrogen - n0, preRepair, 1e-9)
end
do
  -- U5: interpretation is by the APPLIED product's density, never a stored driving
  -- density. Two products on one field, each converted by its own.
  local s = newSys(); local f = newField(s, 1, 2.0)
  local n0 = f.nitrogen
  s:applyFertilizer(1, FT.UREA.index, 10, nil)
  local afterUrea = f.nitrogen
  s:applyFertilizer(1, FT.COMPOST.index, 10, nil)
  T.near("U C6: UREA converted at 0.77",    afterUrea - n0,        PF.UREA.N    * factorFor(FT.UREA, 10, 2.0), 1e-9)
  T.near("U C7: COMPOST converted at 0.60", f.nitrogen - afterUrea, PF.COMPOST.N * factorFor(FT.COMPOST, 10, 2.0), 1e-9)
end

-- =====================================================================
-- GROUP D: U3 site 2, the fully-treated comparison (buffer litres vs kg threshold).
-- =====================================================================
local function treatedRun(ft, liters)
  local s = newSys(); local f = newField(s, 1, 2.0)
  f.coverageFraction = 0.95
  s:applyFertilizer(1, ft.index, liters, nil)
  return s, f
end
do
  local threshold = 2.0 * BR.UREA.value * THR          -- kg-derived
  local s1 = treatedRun(FT.UREA, threshold)            -- raw litres == threshold: 0.77 x is short
  T.eq("U D1: UREA litres equal to the kg threshold are NOT fully treated (0.77 of the mass)", #s1._notices, 0)
  -- A hair above the exact boundary: (t / 0.77) * 0.77 can land one ulp under t,
  -- and the site compares with >=. The row is about the conversion, not the ulp.
  local s2 = treatedRun(FT.UREA, (threshold / 0.77) * (1 + 1e-9))
  T.eq("U D2: UREA litres whose mass meets the threshold ARE fully treated", #s2._notices, 1)
  local s3 = treatedRun(FT.FERTILIZER, 2.0 * BR.FERTILIZER.value * THR)
  T.eq("U D3: FERTILIZER at raw litres == threshold is fully treated, as before", #s3._notices, 1)
end

-- =====================================================================
-- GROUP E: U3 site 3, trackSprayerCoverage's litre fallback.
-- =====================================================================
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  s:trackSprayerCoverage(1, 100, "UREA", true)
  T.near("U E1: UREA litres convert before dividing by the kg/ha rate", f.coveredAreaHa, (100 * 0.77) / BR.UREA.value, 1e-12)
end
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  s:trackSprayerCoverage(1, 100, "INSECTICIDE", true)
  T.near("U E2: INSECTICIDE (crop protection) divides raw litres, unchanged", f.coveredAreaHa, 100 / BR.INSECTICIDE.value, 1e-12)
end
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  local saved = g_fillTypeManager
  g_fillTypeManager = nil
  local ok, err = pcall(s.trackSprayerCoverage, s, 1, 100, "UREA", true)
  g_fillTypeManager = saved
  T.ok("U E3: no fill-type manager: no error (" .. tostring(err) .. ")", ok)
  T.near("U E4: and no conversion (nothing to resolve the name against)", f.coveredAreaHa, 100 / BR.UREA.value, 1e-12)
end

-- =====================================================================
-- GROUP F: U3 site 4, the HUD ghost bar, through the REAL drawNutrientRow.
-- The same function converts here and at site 2, so bar and threshold agree.
-- =====================================================================
local function drawRow(ft, bufferLiters, areaHa, fillValue)
  local savedGlobals = { renderText = renderText, setTextAlignment = setTextAlignment, setTextColor = setTextColor,
                         RenderText = RenderText, getTextWidth = getTextWidth, setTextBold = setTextBold,
                         g_SoilFertilityManager = g_SoilFertilityManager, masterHUD = g_currentMission.masterHUD }
  renderText = function() end; setTextAlignment = function() end; setTextColor = function() end
  setTextBold = function() end; getTextWidth = function() return 0.01 end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  g_SoilFertilityManager = { settings = { replenishmentRate = 3 } }
  local bars = {}
  g_currentMission.masterHUD = { renderer = {
    renderProgressBar = function(_r, x, y, w, h, fill, col, fillPlusGhost) bars[#bars + 1] = { fill = fill, total = fillPlusGhost }; return true end,
  } }
  local hud = setmetatable({ scale = 1, fillOverlay = nil }, { __index = SoilHUD })
  local info = { nutrientBuffer = { [ft.index] = bufferLiters }, fieldArea = areaHa }
  local ok, err = pcall(hud.drawNutrientRow, hud, "N", "N", { value = fillValue, status = "Fair" },
                        0.1, 0.5, 0.3, 1, 1, info, PF[ft.name], ft, 1.0, nil)
  renderText, setTextAlignment, setTextColor = savedGlobals.renderText, savedGlobals.setTextAlignment, savedGlobals.setTextColor
  RenderText, getTextWidth, setTextBold = savedGlobals.RenderText, savedGlobals.getTextWidth, savedGlobals.setTextBold
  g_SoilFertilityManager = savedGlobals.g_SoilFertilityManager
  g_currentMission.masterHUD = savedGlobals.masterHUD
  return ok, err, bars
end
local function expectedGhost(ft, bufferLiters, areaHa, fillValue)
  local threshold = areaHa * BR[ft.name].value * THR
  local remaining = math.max(0, threshold - HookManager.massEquivalent(ft, bufferLiters))
  local projected = PF[ft.name].N * (remaining / 1000) / areaHa * RR
  return math.min(1.0 - fillValue / 100, projected / 100)
end
do
  -- 200 L on 2 ha of UREA: the kg threshold is 2 x 168 x 0.9 = 302.4, so both the
  -- raw and the converted remaining are positive and differ by 0.23 x 200.
  local ok, err, bars = drawRow(FT.UREA, 200, 2.0, 50)
  T.ok("U F0: the row drew (" .. tostring(err) .. ")", ok)
  T.eq("U F1: one native bar drawn", #bars, 1)
  T.near("U F2: the ghost is sized from the buffer's MASS (x0.77), not its litres",
         bars[1].total - bars[1].fill, expectedGhost(FT.UREA, 200, 2.0, 50), 1e-9)
  local rawGhost = math.min(0.5, PF.UREA.N * (math.max(0, 2.0 * BR.UREA.value * THR - 200) / 1000) / 2.0 * RR / 100)
  T.ok("U F3: which differs from the unconverted ghost", math.abs((bars[1].total - bars[1].fill) - rawGhost) > 1e-6)
end
do
  local ok, _, bars = drawRow(FT.FERTILIZER, 200, 2.0, 50)
  T.ok("U F4: FERTILIZER row drew", ok)
  T.near("U F5: FERTILIZER ghost is the old arithmetic", bars[1].total - bars[1].fill, expectedGhost(FT.FERTILIZER, 200, 2.0, 50), 1e-9)
end
do
  -- Bar and threshold agree: the buffer whose MASS meets the threshold (a hair
  -- above the exact boundary, see D2) shows zero ghost here and is fully treated
  -- at site 2.
  local exact = ((2.0 * BR.UREA.value * THR) / 0.77) * (1 + 1e-9)
  local ok, _, bars = drawRow(FT.UREA, exact, 2.0, 50)
  T.ok("U F6: row drew at the exact threshold", ok)
  T.near("U F7: zero ghost remaining at the mass threshold", bars[1].total - bars[1].fill, 0, 1e-9)
  local s = treatedRun(FT.UREA, exact)
  T.eq("U F8: and site 2 calls the same buffer fully treated", #s._notices, 1)
end

-- =====================================================================
-- GROUP G: U5b, the driving unit is excluded by identity, through the REAL
-- installSprayerAreaHook. Fixture shape from RSF-F226d.
-- =====================================================================
local savedSprayer, savedUtils, savedSfm = Sprayer, Utils, g_SoilFertilityManager
FillType = FillType or { UNKNOWN = 0 }
ToolType = ToolType or { UNDEFINED = 0 }
-- The engine's composition helpers, as RSF-F226d models them: the installer
-- appends the real hook through these.
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
local function newWorld()
  local seen = { calls = {}, coverage = {} }
  local soilSys = {
    fieldData = { [7] = { sessionCoverageCells = { ["1:1"] = true }, sessionCoverageFraction = 0.0 } },
    onFertilizerApplied = function(_s, fid, ftIdx, liters) seen.calls[#seen.calls + 1] = { fid = fid, ft = ftIdx, liters = liters } end,
    trackSprayerCoverage = function(_s, fid, liters, name) seen.coverage[#seen.coverage + 1] = { name = name, liters = liters } end,
    markBoomCells = function() end, paintBoomStrip = function() end,
    applyBurnEffect = function() end, applyScorchEffect = function() end,
    onHerbicideAppliedDirect = function() end, onInsecticideAppliedDirect = function() end, onFungicideAppliedDirect = function() end,
  }
  g_SoilFertilityManager = { settings = { enabled = true, overlapPrevention = false, debugMode = false }, soilSystem = soilSys }
  local hookMgr = setmetatable({
    hooks = {}, register = function() end, registerCleanup = function() end,
    getFieldIdAtWorldPosition = function() return 7 end,
    getBoomCellPositions = function() return { { x = 10, z = 10 } } end,
    getBoomLineEndpoints = function() return nil end,
    _sectionScratch = {},
    _settings = { multiTankApplication = true },
    customFillTypePrices = {},
    customProductIndices = { [50] = true, [51] = true, [52] = true },
    refusedProducts = {},
  }, { __index = HookManager })
  return seen, hookMgr
end
--- opts.units: the local fill units; opts.source: "self" | "other" | "none";
--- opts.sourceIndex: what native wrote into sprayVehicleFillUnitIndex;
--- opts.ownIndex: what getSprayerFillUnitIndex() answers.
local function newSprayer(opts)
  local v = {
    isServer = true, id = "veh1",
    spec_workArea = { workAreas = {} },
    spec_variableWorkWidth = { sections = { { isActive = true } } },
    _sfRootX = 10, _sfRootZ = 10,
    getIsTurnedOn = function() return true end,
    getLastSpeed  = function() return 8.0 end,
    getSprayerFillUnitIndex = function() return opts.ownIndex or 1 end,
    getFillUnitFillLevel = function(_s, i) local u = opts.units[i]; return u and u.fillLevel or 0 end,
    getFillUnitFillType  = function(_s, i) local u = opts.units[i]; return u and u.fillType or 0 end,
    getOwnerFarmId = function() return 1 end,
    addFillUnitFillLevel = function() return 0 end,
    raiseDirtyFlags = function() end,
  }
  local source = nil
  if opts.source == "self" then source = v elseif opts.source == "other" then source = { id = "nurse" } end
  v.spec_sprayer = {
    workAreaParameters = {
      sprayFillType = opts.drivingType or 50, usage = 2.0, sprayFillLevel = 900, isActive = true,
      sprayVehicle = source, sprayVehicleFillUnitIndex = opts.sourceIndex,
    },
    effects = {}, sprayTypes = {},
  }
  v.spec_fillUnit = { fillUnits = opts.units }
  local classTable = {}
  classTable.processSprayerArea = function() return 250, 3 end
  v.processSprayerArea = classTable.processSprayerArea
  local wa = { functionName = "processSprayerArea" }
  wa.processingFunction = v.processSprayerArea
  table.insert(v.spec_workArea.workAreas, wa)
  return v
end
local function runPass(opts)
  Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
  local seen, hookMgr = newWorld()
  HookManager.installSprayerAreaHook(hookMgr)
  local v = newSprayer(opts)
  Sprayer.onStartWorkAreaProcessing(v, 16)
  v.spec_workArea.workAreas[1].processingFunction(v, v.spec_workArea.workAreas[1], 16)
  Sprayer.onEndWorkAreaProcessing(v, 16, true)
  return seen, v
end
local function countOf(seen, ftIdx)
  local n = 0
  for _, c in ipairs(seen.calls) do if c.ft == ftIdx then n = n + 1 end end
  return n
end
do
  -- THE INCUMBENT DOUBLE CREDIT. One tank, drawing from itself: the old read of an
  -- unwritten field excluded nothing, so this pass was credited and drained twice.
  local units = { [1] = { fillLevel = 900, fillType = 50 } }
  local seen = runPass({ units = units, source = "self", sourceIndex = 1, ownIndex = 1 })
  T.eq("U G1: a single-tank pass drawing from itself credits UREA exactly ONCE", countOf(seen, 50), 1)
  T.eq("U G2: and nothing else", #seen.calls, 1)
  T.eq("U G3: the driving unit is not drained again by the secondary path", units[1].fillLevel, 900)
end
do
  -- A real second tank: credited under ITS OWN product (U5), drained once; the
  -- driving unit untouched.
  local units = { [1] = { fillLevel = 900, fillType = 50 }, [2] = { fillLevel = 500, fillType = 51 } }
  local seen = runPass({ units = units, source = "self", sourceIndex = 1, ownIndex = 1 })
  T.eq("U G4: two tanks, two credits", #seen.calls, 2)
  T.eq("U G5: the driving product once", countOf(seen, 50), 1)
  T.eq("U G6: the secondary once, under its own fill type (COMPOST, its own density at the factor)", countOf(seen, 51), 1)
  T.ok("U G7: the secondary was drained", units[2].fillLevel < 500)
  T.eq("U G8: the driving unit was not", units[1].fillLevel, 900)
end
do
  -- External source: the foreign index (2) collides numerically with a valid LOCAL
  -- secondary at 2, and the stale local getSprayerFillUnitIndex also says 2.
  -- Neither may exclude the local tank.
  local units = { [1] = { fillLevel = 0, fillType = 50 }, [2] = { fillLevel = 500, fillType = 51 } }
  local seen = runPass({ units = units, source = "other", sourceIndex = 2, ownIndex = 2 })
  T.eq("U G9: an externally fed pass still credits the local secondary at the colliding index", countOf(seen, 51), 1)
  T.ok("U G10: and drains it", units[2].fillLevel < 500)
  T.eq("U G11: the empty local spray unit is not enumerated", countOf(seen, 50), 1)
end
do
  -- Drawing from itself, but the resolver's unit differs from native's (both local):
  -- both are the driving tank's identity and both are excluded.
  local units = { [1] = { fillLevel = 900, fillType = 50 }, [2] = { fillLevel = 600, fillType = 51 } }
  local seen = runPass({ units = units, source = "self", sourceIndex = 1, ownIndex = 2 })
  T.eq("U G12: native's unit and the resolver's unit are both excluded when both are local", #seen.calls, 1)
  T.eq("U G13: unit 2 was not drained as a secondary", units[2].fillLevel, 600)
end
do
  -- No source at all (external fill, buy mode): nothing local is excluded by index,
  -- and an empty unit is not enumerated anyway.
  local units = { [1] = { fillLevel = 0, fillType = 50 }, [2] = { fillLevel = 300, fillType = 52 } }
  local seen = runPass({ units = units, source = "none", sourceIndex = nil, ownIndex = 1 })
  T.eq("U G14: with no source vehicle a local tank with product is still a secondary", countOf(seen, 52), 1)
end

Sprayer, Utils, g_SoilFertilityManager = savedSprayer, savedUtils, savedSfm
g_fillTypeManager = savedFtm
