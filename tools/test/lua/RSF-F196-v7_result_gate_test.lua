-- RSF-F196-v7_result_gate_test.lua: V7, the resolved result enters the application path.
--
-- onFertilizerApplied returns exactly false for a refused product BEFORE the nutrient
-- buffer, agronomy, organic input, overlay refresh or multiplayer broadcast, and
-- exactly true after a valid pass completes its side effects. Both callers in the
-- area hook gate the fertilizer-specific burn, scorch, boom paint and litre coverage
-- on result == true; herbicide-, insecticide- and fungicide-only passes are outside
-- that gate and keep their direct effects, paint, coverage and heat scorch.
--
-- V7 is the SECOND fence. In production R2 zeroes a refused product's dose before the
-- area hook runs and R3d skips a refused secondary before it is applied, so the gate
-- is reached only if a first fence fails. This bar models exactly that, and says so:
-- group B installs the area hook WITHOUT the R2 append, and group C hands the soil
-- system a refused table the enumeration's manager does not share, so a refused
-- secondary reaches applyMulti. Both fences down is the case V7 exists for.
--
-- Group A drives the REAL onFertilizerApplied with spies on every side effect it
-- orders. Groups B and C drive the REAL installSprayerAreaHook with a soil system
-- whose onFertilizerApplied is the real one and whose effects are spies.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = { Sprayer = Sprayer, Utils = Utils, FillType = FillType, ToolType = ToolType,
                g_currentMission = g_currentMission, g_fillTypeManager = g_fillTypeManager,
                g_SoilFertilityManager = g_SoilFertilityManager, g_server = g_server,
                SoilFieldUpdateEvent = SoilFieldUpdateEvent, Broadcast = SoilNetworkEvents_BroadcastFieldUpdate }

local REFUSED, VALID, SECOND, HERB = 9, 50, 51, 60
local BY_INDEX = {
  [REFUSED] = { name = "UREA",      index = REFUSED },   -- a dry product refused for this bar
  [VALID]   = { name = "UREA",      index = VALID },     -- the same product, valid
  [SECOND]  = { name = "COMPOST",   index = SECOND },
  [HERB]    = { name = "HERBICIDE", index = HERB },
}
g_fillTypeManager = { getFillTypeByIndex = function(_, i) return BY_INDEX[i] end,
                      getFillTypeByName  = function(_, n) for _, d in pairs(BY_INDEX) do if d.name == n then return d end end return nil end }

local function counter()
  local c = { n = 0, args = {} }
  c.fn = function(_, ...) c.n = c.n + 1; c.args[#c.args + 1] = { ... } end
  return c
end

-- =====================================================================
-- GROUP A: the REAL onFertilizerApplied, side effects spied.
-- =====================================================================
local function newSys(opts)
  opts = opts or {}
  local spies = { apply = counter(), organic = counter(), overlay = counter(), broadcast = counter() }
  local s = setmetatable({
    fieldData = { [1] = { nitrogen = 50 } },
    settings  = { enabled = true },
    hookManager = opts.hookManager,
    applyFertilizer = spies.apply.fn,
  }, { __index = SoilFertilitySystem })
  g_currentMission = { time = 10000, missionDynamicInfo = { isMultiplayer = true } }
  g_SoilFertilityManager = { organic = { onInputApplied = spies.organic.fn },
                             soilMapOverlay = { requestRefresh = spies.overlay.fn } }
  g_server = true
  SoilFieldUpdateEvent = {}
  SoilNetworkEvents_BroadcastFieldUpdate = function(...) spies.broadcast.fn(nil, ...) end
  return s, spies
end
local refusing = { isRefusedProduct = function(_, idx) return idx == REFUSED end }

do
  local s, sp = newSys({ hookManager = refusing })
  local r = s:onFertilizerApplied(1, REFUSED, 5.0, nil)
  T.eq("V7 A1: a refused product returns exactly false", r, false)
  T.eq("V7 A2: before applyFertilizer (no nutrient buffer, no agronomy)", sp.apply.n, 0)
  T.eq("V7 A3: before the organic input",   sp.organic.n, 0)
  T.eq("V7 A4: before the overlay refresh", sp.overlay.n, 0)
  T.eq("V7 A5: before the broadcast",       sp.broadcast.n, 0)
end
do
  local s, sp = newSys({ hookManager = refusing })
  local r = s:onFertilizerApplied(1, VALID, 5.0, nil)
  T.eq("V7 A6: a valid product returns exactly true", r, true)
  T.eq("V7 A7: after applyFertilizer ran once", sp.apply.n, 1)
  T.eq("V7 A8: with the litres and boom points it was given", sp.apply.args[1][3] == 5.0 and sp.apply.args[1][2] == VALID, true)
  T.eq("V7 A9: the organic input ran",   sp.organic.n, 1)
  T.eq("V7 A10: the overlay refreshed",  sp.overlay.n, 1)
  T.eq("V7 A11: the broadcast went out", sp.broadcast.n, 1)
end
do
  local s, sp = newSys({ hookManager = nil })
  T.eq("V7 A12: no manager in reach refuses nothing (today's behaviour): true", s:onFertilizerApplied(1, REFUSED, 5.0, nil), true)
  T.eq("V7 A13: and applied", sp.apply.n, 1)
end
do
  local s = newSys({ hookManager = { customProductIndices = {} } })   -- no isRefusedProduct method
  T.eq("V7 A14: a manager without the refused table refuses nothing: true", s:onFertilizerApplied(1, REFUSED, 5.0, nil), true)
end
do
  local s = newSys({ hookManager = refusing })
  T.eq("V7 A15: the result is a boolean, never nil, on the valid path", type(s:onFertilizerApplied(1, VALID, 1.0, nil)), "boolean")
  T.eq("V7 A16: and on the refused path", type(s:onFertilizerApplied(1, REFUSED, 1.0, nil)), "boolean")
end

-- =====================================================================
-- GROUPS B and C: the REAL area hook, both fences down.
-- =====================================================================
FillType = FillType or { UNKNOWN = 0 }
ToolType = ToolType or { UNDEFINED = 0 }
Utils = {
  prependedFunction = function(orig, new) return function(...) new(...) if orig then return orig(...) end end end,
  appendedFunction  = function(orig, new) return function(...) local r = orig and { orig(...) } or {} new(...) return unpack(r) end end,
}

--- The soil system the hook reaches: the REAL onFertilizerApplied over spied effects.
--- opts.secondFence: the manager the soil system consults (V7's fence); the
--- enumeration's manager (hookMgr) is R3d's fence and is handed separately.
local function newWorld(opts)
  opts = opts or {}
  local sp = { apply = counter(), burn = counter(), scorch = counter(), boomCells = counter(),
               strip = counter(), coverage = counter(), herb = counter() }
  local soilSys = setmetatable({
    fieldData = { [7] = { sessionCoverageCells = { ["1:1"] = true }, sessionCoverageFraction = 0.0, nitrogen = 50 } },
    settings  = { enabled = true },
    applyFertilizer = sp.apply.fn,
    applyBurnEffect = sp.burn.fn, applyScorchEffect = sp.scorch.fn,
    markBoomCells = sp.boomCells.fn, paintBoomStrip = sp.strip.fn,
    trackSprayerCoverage = sp.coverage.fn,
    onHerbicideAppliedDirect = sp.herb.fn, onInsecticideAppliedDirect = function() end, onFungicideAppliedDirect = function() end,
  }, { __index = SoilFertilitySystem })
  g_currentMission = { time = 10000 }
  g_server = nil
  g_SoilFertilityManager = {
    settings = { enabled = true, overlapPrevention = false, debugMode = false },
    soilSystem = soilSys,
    sprayerRateManager = { getMultiplier = function() return 2.0 end },   -- above BURN_RISK_THRESHOLD
  }
  local hookMgr = setmetatable({
    hooks = {}, register = function() end, registerCleanup = function() end,
    getFieldIdAtWorldPosition = function() return 7 end,
    getBoomCellPositions = function() return { { x = 10, z = 10 } } end,
    getBoomLineEndpoints = function() return nil end,
    _sectionScratch = {},
    _settings = { multiTankApplication = opts.multiTank == true },
    customFillTypePrices = {},
    customProductIndices = { [REFUSED] = true, [VALID] = true, [SECOND] = true },
    refusedProducts = opts.firstFence or {},
  }, { __index = HookManager })
  soilSys.hookManager = opts.secondFence or hookMgr
  return sp, hookMgr, soilSys
end
local function newSprayer(opts)
  local v = {
    isServer = true, id = "veh1",
    spec_workArea = { workAreas = {} },
    spec_variableWorkWidth = opts.vww and { sections = { { isActive = true } } } or nil,
    _sfRootX = 10, _sfRootZ = 10,
    getIsTurnedOn = function() return true end,
    getLastSpeed  = function() return 8.0 end,
    getSprayerFillUnitIndex = function() return 1 end,
    getFillUnitFillLevel = function(_s, i) local u = opts.units[i]; return u and u.fillLevel or 0 end,
    getFillUnitFillType  = function(_s, i) local u = opts.units[i]; return u and u.fillType or 0 end,
    getOwnerFarmId = function() return 1 end,
    addFillUnitFillLevel = function() return 0 end,
    raiseDirtyFlags = function() end,
  }
  v.spec_sprayer = {
    workAreaParameters = { sprayFillType = opts.driving, usage = 2.0, sprayFillLevel = 900, isActive = true,
                           sprayVehicle = v, sprayVehicleFillUnitIndex = 1 },
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
--- Installs ONLY the area hook: no R2 append, so a refused driving product keeps its
--- dose and reaches applySingle. That is the first fence down, by construction.
local function runPass(world, sprayerOpts)
  Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
  local sp, hookMgr = newWorld(world)
  HookManager.installSprayerAreaHook(hookMgr)
  local v = newSprayer(sprayerOpts)
  Sprayer.onStartWorkAreaProcessing(v, 16)
  v.spec_workArea.workAreas[1].processingFunction(v, v.spec_workArea.workAreas[1], 16)
  Sprayer.onEndWorkAreaProcessing(v, 16, true)
  return sp
end
local function litreCoverageCalls(sp)
  local n = 0
  for _, a in ipairs(sp.coverage.args) do if a[4] == true then n = n + 1 end end
  return n
end

-- ── B: the primary caller ──
do
  -- Refused driving product, first fence down: the gate must hold every effect.
  local sp = runPass({ firstFence = { [REFUSED] = "density" } }, { driving = REFUSED, units = { [1] = { fillLevel = 900, fillType = REFUSED } } })
  T.eq("V7 B1: the refused product was not applied (V7 returned false before applyFertilizer)", sp.apply.n, 0)
  T.eq("V7 B2: no burn (rate 2.0 is above the risk threshold, so only the gate stops it)", sp.burn.n, 0)
  T.eq("V7 B3: no scorch for the refused fertilizer product", sp.scorch.n, 0)
  T.eq("V7 B4: no boom strip painted", sp.strip.n, 0)
  T.eq("V7 B5: no boom cells marked", sp.boomCells.n, 0)
  T.eq("V7 B6: no litre coverage advanced", litreCoverageCalls(sp), 0)
end
do
  -- The same pass with a valid product: every effect runs, exactly as before V7.
  local sp = runPass({ firstFence = {} }, { driving = VALID, units = { [1] = { fillLevel = 900, fillType = VALID } } })
  T.eq("V7 B7: a valid product is applied", sp.apply.n, 1)
  T.eq("V7 B8: burns at rate 2.0", sp.burn.n, 1)
  T.eq("V7 B9: scorch runs", sp.scorch.n, 1)
  T.eq("V7 B10: the boom strip paints", sp.strip.n, 1)
  T.eq("V7 B11: boom cells are marked", sp.boomCells.n, 1)
  T.eq("V7 B12: litre coverage advances (no VWW, dry-spreader branch)", litreCoverageCalls(sp), 1)
end
do
  -- A herbicide-only pass never comes through onFertilizerApplied and is not gated:
  -- direct effect, scorch and overlay-only boom cells all run. Even with a refused
  -- table naming it, because refusal is a fertilizer-path fact.
  local sp = runPass({ firstFence = { [HERB] = "density" } }, { driving = HERB, units = { [1] = { fillLevel = 900, fillType = HERB } } })
  T.eq("V7 B13: herbicide-only: no fertilizer application at all", sp.apply.n, 0)
  T.eq("V7 B14: its direct herbicide effect runs", sp.herb.n, 1)
  T.eq("V7 B15: its heat scorch runs (not gated)", sp.scorch.n, 1)
  T.eq("V7 B16: its overlay-only boom cells are marked (not gated)", sp.boomCells.n, 1)
end
do
  -- VWW: several sections, one product, every section agrees, the gate holds after the loop.
  local sp = runPass({ firstFence = { [REFUSED] = "density" } }, { driving = REFUSED, vww = true, units = { [1] = { fillLevel = 900, fillType = REFUSED } } })
  T.eq("V7 B17: VWW refused pass: no application", sp.apply.n, 0)
  T.eq("V7 B18: VWW refused pass: no strip after the section loop", sp.strip.n, 0)
  T.eq("V7 B19: VWW refused pass: no boom cells after the section loop", sp.boomCells.n, 0)
end

-- ── C: the secondary caller. R3d (the enumeration's fence) is handed an EMPTY
-- refused table so the secondary reaches applyMulti; the soil system's fence is
-- the one that refuses. Both fences down, the case V7 exists for.
do
  local secondFence = { isRefusedProduct = function(_, idx) return idx == SECOND end }
  local sp = runPass({ multiTank = true, firstFence = {}, secondFence = secondFence },
                     { driving = VALID, units = { [1] = { fillLevel = 900, fillType = VALID }, [2] = { fillLevel = 500, fillType = SECOND } } })
  T.eq("V7 C1: the driving product applied once, the refused secondary not at all", sp.apply.n, 1)
  T.eq("V7 C2: one scorch (the primary's), none for the refused secondary", sp.scorch.n, 1)
  T.eq("V7 C3: one burn (the primary's)", sp.burn.n, 1)
  T.eq("V7 C4: one boom strip (the primary's), none for the refused secondary", sp.strip.n, 1)
  T.eq("V7 C5: one litre coverage (the primary's)", litreCoverageCalls(sp), 1)
end
do
  local sp = runPass({ multiTank = true, firstFence = {} },
                     { driving = VALID, units = { [1] = { fillLevel = 900, fillType = VALID }, [2] = { fillLevel = 500, fillType = SECOND } } })
  T.eq("V7 C6: two valid tanks: both applied", sp.apply.n, 2)
  T.eq("V7 C7: both scorched", sp.scorch.n, 2)
  T.eq("V7 C8: both strips painted", sp.strip.n, 2)
  T.eq("V7 C9: both litre coverages", litreCoverageCalls(sp), 2)
end

-- ── restore ──
Sprayer, Utils, FillType, ToolType = saved.Sprayer, saved.Utils, saved.FillType, saved.ToolType
g_currentMission, g_fillTypeManager, g_SoilFertilityManager, g_server = saved.g_currentMission, saved.g_fillTypeManager, saved.g_SoilFertilityManager, saved.g_server
SoilFieldUpdateEvent, SoilNetworkEvents_BroadcastFieldUpdate = saved.SoilFieldUpdateEvent, saved.Broadcast
