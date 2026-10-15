-- SF-1098: deferred-init's four steps were called EVERY TICK until setup completed,
-- and ticks during load are not budgeted, so a healthy load that took a while to
-- complete could flood the log with the same line thousands of times (a player's
-- log held "Retroactively injected SF fill types into 5 existing silo(s)" 7,000
-- times). The fix makes each of these lines print once:
--   - patchExistingSilos: the info line logs only when the patched count differs
--     from the last one logged (_loggedSiloPatchCount), so a silo placed later
--     still reports.
--   - registerCustomSprayTypes: one-shot flags on the three early-skip warnings
--     (no g_sprayTypeManager, no g_fillTypeManager, no vanilla spray types), the
--     per-product "REFUSED: no usable density" warning (one per product NAME,
--     table _loggedRefusedDensity), the LIQUIDLIME override-failed warning, and
--     the two "[DeferredInit] ... scheduling retry" warnings (nil types; unusable
--     price).
-- Nothing else may change: return values, _sprayTypesComplete, refusedProducts,
-- the skipped/registered counters, the debug lines.
--
-- ENTRY-POINT BAR: every row drives the real SoilFertilityManager:_updateDeferredInit,
-- ticked N times, which in turn drives the REAL HookManager:registerCustomSprayTypes
-- and the REAL HookManager:patchExistingSilos (real injectSiloFillTypes too; it loads
-- cleanly over a modelled silo, a plain table holding `spec_silo = {}` - the real
-- function reads placeable.spec_silo, calls the real getResolvedSiloGroups, and
-- returns early with no error when no fill-type manager has resolved any groups,
-- which is exactly what row A's silo fixture exercises). reapplyFillUnitPatch and
-- reapplyEffectTypeRemap are STUBBED on the instance (their own one-shot behaviour
-- is covered by SF-deferred_init_reporting_test.lua and is unrelated to this change).
--
-- MODELLED: g_fillTypeManager and g_sprayTypeManager are small fixtures built the
-- same way RSF-F196-x1_price_completeness_test.lua builds them (a name->descriptor
-- table and the engine's real addSprayType membership rule), not stubs of the
-- functions under test. g_currentMission models isMissionStarted and
-- placeableSystem.placeables (each a plain table with spec_silo = {}), the two
-- fields _updateDeferredInit and patchExistingSilos actually read.
--
-- CONTROL: this bar also runs, unmodified, against development's HookManager.lua
-- (src/hooks/HookManager.lua before this fix), swapped in by the battery/control
-- script, never by a second copy of production code living in this file.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/SoilFertilityManager.lua

FillType = FillType or { UNKNOWN = 0 }

-- ── Logs captured ──────────────────────────────────────────────────────────────
local logged
local function captureLogs()
  logged = { warning = {}, info = {}, debug = {} }
  for _, lvl in ipairs({ "warning", "info", "debug" }) do
    SoilLogger[lvl] = function(msg, ...)
      local ok, s = pcall(string.format, msg, ...)
      table.insert(logged[lvl], ok and s or tostring(msg))
    end
  end
end
local function countMatching(list, needle)
  local n = 0
  for _, s in ipairs(list) do if s:find(needle, 1, true) then n = n + 1 end end
  return n
end

local FRAME = 16  -- ms, a normal frame delta
local TIMEOUT = SoilConstants.TIMING.DEFERRED_INIT_TIMEOUT

-- ── Fill-type fixture: a name->descriptor table, like RSF-F196's, not a stub of
-- the function under test. opts.missing excludes a name entirely (permanently
-- unresolved, not "arrives late"). opts.density overrides one name's massPerLiter
-- (declared but possibly unusable, per HookManager.densityOf). The returned
-- BY_NAME table is live: mutating a descriptor's massPerLiter after the fact (row
-- D's toggle) is visible on the very next call, because the manager closes over it.
local function declareTypes(opts)
  opts = opts or {}
  local missing = opts.missing or {}
  local density = opts.density or {}
  local BY_NAME, BY_INDEX = {}, {}
  local nextIndex = 100
  local function declare(name, massPerLiter)
    nextIndex = nextIndex + 1
    BY_NAME[name] = { name = name, index = nextIndex, massPerLiter = massPerLiter }
    BY_INDEX[nextIndex] = BY_NAME[name]
  end
  for _, n in ipairs({ "LIQUIDFERTILIZER", "FERTILIZER", "LIME", "FUNGICIDE", "HERBICIDE", "MANURE", "LIQUIDMANURE", "DIGESTATE" }) do
    declare(n, 0.001)
  end
  for _, n in ipairs(HookManager.buildCustomNamePopulation()) do
    if not missing[n] then
      declare(n, density[n] or 0.001)
    end
  end
  local fm = {
    getFillTypeByName      = function(_s, n) return BY_NAME[n] end,
    getFillTypeByIndex     = function(_s, i) return BY_INDEX[i] end,
    getFillTypeIndexByName = function(_s, n) return BY_NAME[n] and BY_NAME[n].index or nil end,
  }
  return fm, BY_NAME
end

-- ── Spray-type fixture: the engine's real addSprayType membership rule (only a
-- FERTILIZER/LIME/HERBICIDE-typed entry whose fill type resolves gets added),
-- built against whatever g_fillTypeManager is live at call time, same as RSF-F196.
-- opts.omitVanilla = { LIQUIDFERTILIZER = true, ... } skips adding that vanilla
-- entry, so getSprayTypeByName for it comes back nil even though the fill type
-- exists (row F3's case).
local function buildSprayTypeManager(opts)
  opts = opts or {}
  local omit = opts.omitVanilla or {}
  local STM = { sprayTypes = {}, nameToSprayType = {}, fillTypeIndexToSprayType = {}, numSprayTypes = 0 }
  function STM:addSprayType(name, lps, typeName, groundType)
    local key = string.upper(name)
    local ft = g_fillTypeManager:getFillTypeByName(key)
    if ft == nil then return nil end
    local st = self.nameToSprayType[key]
    if st == nil then
      self.numSprayTypes = self.numSprayTypes + 1
      local t = string.upper(typeName)
      st = { name = key, index = self.numSprayTypes, litersPerSecond = lps or 0,
             isFertilizer = t == "FERTILIZER", isLime = t == "LIME", isHerbicide = t == "HERBICIDE" }
      if not (st.isFertilizer or st.isLime or st.isHerbicide) then return nil end
      table.insert(self.sprayTypes, st); self.nameToSprayType[key] = st; self.fillTypeIndexToSprayType[ft.index] = st
    end
    st.litersPerSecond = lps or st.litersPerSecond; st.sprayGroundType = groundType or st.sprayGroundType or 1
    return st
  end
  function STM:getSprayTypeByName(n) if n == nil then return nil end return self.nameToSprayType[string.upper(n)] end
  function STM:getSprayTypeByFillTypeIndex(i) return self.fillTypeIndexToSprayType[i] end
  if not omit.LIQUIDFERTILIZER then STM:addSprayType("LIQUIDFERTILIZER", 0.0081, "FERTILIZER", 2) end
  if not omit.FERTILIZER then STM:addSprayType("FERTILIZER", 0.0060, "FERTILIZER", 3) end
  STM:addSprayType("LIME", 0.0040, "LIME", 4)
  STM:addSprayType("FUNGICIDE", 0.0028, "HERBICIDE", 5)
  return STM
end

-- ── The retry world: a real HookManager with the two siblings not under test
-- stubbed (see header). fillUnitResult is what reapplyFillUnitPatch returns.
local function newWorld(fillUnitResult)
  local hm = HookManager.new()
  hm.reapplyFillUnitPatch = function() return fillUnitResult end
  hm.reapplyEffectTypeRemap = function() end
  local mgr = { soilSystem = { hookManager = hm } }
  return mgr, hm
end

local function setMission(started, placeables)
  g_currentMission = { isMissionStarted = started }
  if placeables then g_currentMission.placeableSystem = { placeables = placeables } end
end

local function tick(mgr, n)
  for _ = 1, n do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end
end

-- =====================================================================
-- ROW A: 5 silos, setup incomplete, 200 ticks during load. Then a 6th silo
-- appears and 200 more ticks run.
-- =====================================================================
do
  captureLogs()
  g_fillTypeManager = nil
  g_sprayTypeManager = nil
  local placeables = {}
  for i = 1, 5 do placeables[i] = { spec_silo = {} } end
  setMission(false, placeables)   -- during load: isMissionStarted is false
  local mgr, hm = newWorld(false)

  tick(mgr, 200)
  T.eq("A1: 5 silos, 200 ticks during load: 'Retroactively injected' logs exactly once",
       countMatching(logged.info, "Retroactively injected"), 1)
  T.ok("A2: that one line reports 5",
       logged.info[1] ~= nil and logged.info[1]:find("5 existing silo", 1, true) ~= nil)

  placeables[6] = { spec_silo = {} }
  tick(mgr, 200)
  T.eq("A3: a 6th silo appears, 200 more ticks: exactly one MORE line",
       countMatching(logged.info, "Retroactively injected"), 2)
  T.ok("A4: the new line reports 6",
       logged.info[2] ~= nil and logged.info[2]:find("6 existing silo", 1, true) ~= nil)
  T.eq("A5: total across both phases is 2, not 400", countMatching(logged.info, "Retroactively injected"), 2)
end

-- =====================================================================
-- ROW B: one expected fill type permanently unresolved (skipped > 0), 200 ticks,
-- then push past DEFERRED_INIT_TIMEOUT.
-- =====================================================================
do
  captureLogs()
  local fm = declareTypes({ missing = { UREA = true } })
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({})
  local mgr, hm = newWorld(false)
  setMission(true)

  tick(mgr, 200)
  T.eq("B1: 200 ticks, one unresolved fill type: the nil-types retry warning logs exactly once",
       countMatching(logged.warning, "fill types were nil - scheduling retry"), 1)
  T.eq("B2: _sprayTypesComplete stays false after 200 ticks", hm._sprayTypesComplete, false)

  -- Push well past the ceiling; the existing give-up behaviour must be unchanged.
  local already = 200 * FRAME
  local moreTicks = math.ceil((TIMEOUT - already) / FRAME) + 2
  tick(mgr, moreTicks)
  T.eq("B3: once mission time passes DEFERRED_INIT_TIMEOUT, 'Gave up' still logs exactly once",
       countMatching(logged.warning, "Gave up"), 1)
  T.eq("B4: the nil-types retry warning is still exactly one line overall, not one per tick",
       countMatching(logged.warning, "fill types were nil - scheduling retry"), 1)
  T.eq("B5: the loop stopped (gave up)", mgr._deferredInitDone, true)
end

-- =====================================================================
-- ROW C: every fill type resolved, but a priced product carries an unusable
-- price, 200 ticks.
-- =====================================================================
do
  captureLogs()
  local fm = declareTypes({})
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({})
  local savedPCS = SoilConstants.PURCHASABLE_SINGLE_NUTRIENT
  SoilConstants.PURCHASABLE_SINGLE_NUTRIENT = { UAN32 = { pricePerLiter = -1 } }   -- SYNTHETIC unusable price
  local mgr, hm = newWorld(false)
  setMission(true)

  tick(mgr, 200)
  T.eq("C1: every type resolved, one unusable price, 200 ticks: the price-retry warning logs exactly once",
       countMatching(logged.warning, "unusable price - scheduling retry"), 1)
  T.eq("C2: and the nil-types warning never fires (nothing was actually nil)",
       countMatching(logged.warning, "fill types were nil - scheduling retry"), 0)

  SoilConstants.PURCHASABLE_SINGLE_NUTRIENT = savedPCS
end

-- =====================================================================
-- ROW D: two products with an invalid density, 200 ticks. One of them (AN)
-- resolves valid for a single tick in the middle, then relapses, to prove the
-- refusedProducts write is not gated by the same one-shot flag as its log line.
-- =====================================================================
do
  captureLogs()
  local fm, BY = declareTypes({ density = { AN = -1, AMS = -1 } })
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({})
  local mgr, hm = newWorld(false)
  setMission(true)

  tick(mgr, 100)
  T.eq("D1: two invalid-density products, 100 ticks: exactly one REFUSED line each (2 total)",
       countMatching(logged.warning, "REFUSED: no usable density"), 2)
  T.eq("D2: _sprayTypesComplete is false while the refusals stand", hm._sprayTypesComplete, false)

  BY.AN.massPerLiter = 0.001   -- AN resolves valid for one tick
  tick(mgr, 1)
  T.eq("D3: AN's refusal clears while it is valid", hm:isRefusedProduct(BY.AN.index), false)

  BY.AN.massPerLiter = -1      -- AN relapses to an invalid density
  tick(mgr, 99)                -- 100 + 1 + 99 = 200 ticks total

  T.eq("D4: 200 ticks total, still exactly one REFUSED line per product (2 total)",
       countMatching(logged.warning, "REFUSED: no usable density"), 2)
  T.eq("D5: refusedProducts[AN] == 'density' after the last tick (the relapse re-marked it)",
       hm.refusedProducts[BY.AN.index], "density")
  T.eq("D6: refusedProducts[AMS] == 'density' after the last tick", hm.refusedProducts[BY.AMS.index], "density")
  T.eq("D7: _sprayTypesComplete false (behaviour unchanged)", hm._sprayTypesComplete, false)
end

-- =====================================================================
-- ROW E: LIQUIDLIME override failure (fill type absent), 200 ticks.
-- =====================================================================
do
  captureLogs()
  local fm = declareTypes({ missing = { LIQUIDLIME = true } })
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({})
  local mgr, hm = newWorld(false)
  setMission(true)

  tick(mgr, 200)
  T.eq("E1: LIQUIDLIME missing, 200 ticks: the override-failed warning logs exactly once",
       countMatching(logged.warning, "LIQUIDLIME spray type override failed"), 1)
end

-- =====================================================================
-- ROW F: the three early-skip flags, 50 calls each.
-- =====================================================================
do
  -- F1: g_sprayTypeManager nil.
  captureLogs()
  g_fillTypeManager = declareTypes({})
  g_sprayTypeManager = nil
  local mgr, hm = newWorld(false)
  setMission(true)
  tick(mgr, 50)
  T.eq("F1: g_sprayTypeManager nil, 50 calls: its warning logs exactly once",
       countMatching(logged.warning, "g_sprayTypeManager not available"), 1)
  T.eq("F1: and nothing registered (the identity catalogue stays empty)", next(hm.customProductIndices), nil)
  T.eq("F1: _sprayTypesComplete was never set", hm._sprayTypesComplete, nil)
end

do
  -- F2: g_fillTypeManager nil (while a spray-type manager already exists).
  captureLogs()
  local fm = declareTypes({})
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({})
  g_fillTypeManager = nil
  local mgr, hm = newWorld(false)
  setMission(true)
  tick(mgr, 50)
  T.eq("F2: g_fillTypeManager nil, 50 calls: its warning logs exactly once",
       countMatching(logged.warning, "g_fillTypeManager not available"), 1)
  T.eq("F2: and nothing registered", next(hm.customProductIndices), nil)
end

do
  -- F3: vanilla LIQUIDFERTILIZER and FERTILIZER spray types both absent.
  captureLogs()
  local fm = declareTypes({})
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({ omitVanilla = { LIQUIDFERTILIZER = true, FERTILIZER = true } })
  local mgr, hm = newWorld(false)
  setMission(true)
  tick(mgr, 50)
  T.eq("F3: vanilla LIQUIDFERTILIZER and FERTILIZER both absent, 50 calls: the warning logs exactly once",
       countMatching(logged.warning, "vanilla spray types not found"), 1)
  T.eq("F3: and nothing registered", next(hm.customProductIndices), nil)
end

-- =====================================================================
-- ROW G: a healthy setup completes on the first mission tick.
-- =====================================================================
do
  captureLogs()
  local fm = declareTypes({})
  g_fillTypeManager = fm
  g_sprayTypeManager = buildSprayTypeManager({})
  local mgr, hm = newWorld(true)   -- reapplyFillUnitPatch reports complete from tick 1
  setMission(true)

  local realPatch = HookManager.patchExistingSilos
  local patchCalls = 0
  function hm:patchExistingSilos(...)
    patchCalls = patchCalls + 1
    return realPatch(self, ...)
  end

  tick(mgr, 1)
  T.eq("G1: a healthy setup completes on the first mission tick", mgr._deferredInitDone, true)
  T.eq("G2: no completion line on an immediate first-tick completion (unchanged: elapsed ms is 0)",
       countMatching(logged.info, "Fill-type re-patch complete"), 0)
  T.eq("G3: the '[OK] Custom spray types registered' summary logs once",
       countMatching(logged.info, "Custom spray types registered"), 1)
  T.eq("G4: patchExistingSilos ran exactly once, on completion", patchCalls, 1)

  tick(mgr, 50)
  T.eq("G5: after completion, 50 more ticks never call patchExistingSilos again", patchCalls, 1)
end
