-- RSF-F196-x1_price_completeness_test.lua: clause X1's remainder, the price half.
--
-- THE GAP. Registration completeness was `_sprayTypesComplete = (skipped == 0)`, and the
-- catalogue is rebuilt on every attempt (#977). But customFillTypePrices had exactly ONE
-- writer, installPurchaseRefillHook, which runs once from installAll and never on a
-- retry. On a dedicated server with late descriptors (#431) a product that resolved
-- after install never got a price, so helper buying refused it for the whole session
-- (V12b) while the completion flag went true and the retry loop stopped.
--
-- THE REPAIR. HookManager.customPriceFor(name) is the one price source. On every
-- registration attempt rebuildCustomPriceMap() builds a complete replacement map for
-- every resolved, non-refused population index whose name has a price and assigns it
-- in one step; completion is now `(skipped == 0) and priceComplete`. Eligibility is
-- "the name has a price entry": blends have none and never count as missing. The brief's
-- `_sprayTypesExhausted` is the mission-time timeout in _updateDeferredInit (#970).
--
-- WHO POPULATES THE WORLD. Nothing sets a price map or a catalogue by hand. The fill
-- type manager fixture holds the mod's own population (HookManager.buildCustomNamePopulation,
-- blends included) with descriptors that ARRIVE LATE: UREA is absent on attempt 1 and
-- present on attempt 2, the #431 shape; AN carries an unusable density so the real R1a
-- refusal fires. The spray-type manager applies the engine's addSprayType rule. The
-- real registerCustomSprayTypes runs through the real _updateDeferredInit loop.
--
-- ENTRY-POINT BAR: group A drives SoilFertilityManager:_updateDeferredInit, the production
-- retry loop, tick by tick, and reads hookManager.customFillTypePrices, which is the exact
-- field the two call-time readers use (billedExternalFill, HookManager.lua:7710 region;
-- the backup refill, :5284 region). The three sibling retry steps that are not under
-- test (reapplyFillUnitPatch, reapplyEffectTypeRemap, patchExistingSilos) are stubbed on
-- the instance; registration itself is real.
--
-- What this bar does NOT prove: the install-time wrapper's captured copy (V12a's wrapper
-- half, with V12c) and real engine timing. The TESTING row carries the dedicated server.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/SoilFertilityManager.lua

FillType = FillType or { UNKNOWN = 0 }
local saved = { g_fillTypeManager = g_fillTypeManager, g_sprayTypeManager = g_sprayTypeManager,
                g_currentMission = g_currentMission, warning = SoilLogger.warning, info = SoilLogger.info, debug = SoilLogger.debug,
                pcs = SoilConstants.PURCHASABLE_SINGLE_NUTRIENT }

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

-- ── The fill type manager: the mod's population, descriptors arriving late ────
local POP = HookManager.buildCustomNamePopulation()
local present = {}
local BY_NAME, BY_INDEX = {}, {}
local nextIndex = 100
local function declare(name, massPerLiter)
  nextIndex = nextIndex + 1
  BY_NAME[name] = { name = name, index = nextIndex, massPerLiter = massPerLiter }
  BY_INDEX[nextIndex] = BY_NAME[name]
end
-- The vanilla base types, plus the four vanilla products the mod re-registers at its
-- own rate without their being custom products (HERBICIDE, MANURE, LIQUIDMANURE,
-- DIGESTATE): absent, they count as skipped, which is registration's rule, not X1's.
for _, n in ipairs({ "LIQUIDFERTILIZER", "FERTILIZER", "LIME", "FUNGICIDE", "HERBICIDE", "MANURE", "LIQUIDMANURE", "DIGESTATE" }) do declare(n, 0.001) end
for _, n in ipairs(POP) do declare(n, 0.001) end
-- Group B flips AN's density to an unusable value so the real R1a refusal fires there.
local function refuseAN(on) BY_NAME.AN.massPerLiter = on and -1 or 0.001 end
local LATE = "UREA"
g_fillTypeManager = {
  getFillTypeByName      = function(_s, n) if present[n] then return BY_NAME[n] end return nil end,
  getFillTypeByIndex     = function(_s, i) local ft = BY_INDEX[i]; if ft and present[ft.name] then return ft end return nil end,
  getFillTypeIndexByName = function(_s, n) if present[n] then return BY_NAME[n].index end return nil end,
}
local function arriveAll(exceptName)
  present = {}
  for n in pairs(BY_NAME) do present[n] = true end
  if exceptName then present[exceptName] = nil end
end

-- ── The spray-type manager: the engine's addSprayType rule ─────────────────────
local STM = { sprayTypes = {}, nameToSprayType = {}, fillTypeIndexToSprayType = {}, numSprayTypes = 0 }
function STM:addSprayType(name, lps, typeName, groundType, isBaseType)
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
g_sprayTypeManager = STM
arriveAll(nil)
STM:addSprayType("LIQUIDFERTILIZER", 0.0081, "FERTILIZER", 2, true)
STM:addSprayType("FERTILIZER", 0.0060, "FERTILIZER", 3, true)
STM:addSprayType("LIME", 0.0040, "LIME", 4, true)
STM:addSprayType("FUNGICIDE", 0.0028, "HERBICIDE", 5, true)

-- ── The retry loop's world ─────────────────────────────────────────────────────
local TIMEOUT = SoilConstants.TIMING.DEFERRED_INIT_TIMEOUT
local FRAME = 16
local function newWorld()
  local hm = HookManager.new()
  hm.reapplyFillUnitPatch  = function() return true end   -- sibling steps, not under test
  hm.reapplyEffectTypeRemap = function() end
  hm.patchExistingSilos     = function() end
  local mgr = { soilSystem = { hookManager = hm } }
  g_currentMission = { isMissionStarted = true }
  return mgr, hm
end
local function tick(mgr, n)
  for _ = 1, (n or 1) do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end
end
local IDX = function(name) return BY_NAME[name].index end

-- =====================================================================
-- GROUP P: the one price source.
-- =====================================================================
do
  T.eq("X1 P1: a fallback-priced name resolves to its fillTypes.xml economy price (UREA 1.65)", HookManager.customPriceFor("UREA"), 1.65)
  T.eq("X1 P2: a Constants override wins (ANHYDROUS from PURCHASABLE_SINGLE_NUTRIENT)", HookManager.customPriceFor("ANHYDROUS"), SoilConstants.PURCHASABLE_SINGLE_NUTRIENT.ANHYDROUS.pricePerLiter)
  T.eq("X1 P3: a blend has NO price (not eligible)", HookManager.customPriceFor(SoilBlends.ORDER[1]), nil)
  T.eq("X1 P4: an unknown name has no price", HookManager.customPriceFor("NOT_A_PRODUCT"), nil)
  T.eq("X1 P5: nil is nil", HookManager.customPriceFor(nil), nil)
  T.ok("X1 P6: the population holds blends (the eligibility rule is load-bearing)", #SoilBlends.ORDER > 0 and #POP > 32)
end

-- =====================================================================
-- GROUP A: THE ENTRY-POINT BAR. Descriptors arrive late; the real retry loop.
-- =====================================================================
do
  captureLogs()
  arriveAll(LATE)                      -- attempt 1: UREA is not there yet
  local mgr, hm = newWorld()
  tick(mgr, 1)
  T.eq("X1 A1: attempt 1 with a missing descriptor: registration is not complete", hm._sprayTypesComplete, false)
  T.eq("X1 A2: the loop is still live", mgr._deferredInitDone, nil)
  T.ok("X1 A3: the price map exists after attempt 1 (rebuilt at registration, not only at install)", type(hm.customFillTypePrices) == "table")
  T.eq("X1 A4: and the late product has no price yet", hm.customFillTypePrices[IDX(LATE)], nil)
  T.eq("X1 A5: but a present product is priced already", hm.customFillTypePrices[IDX("UAN32")], 1.60)
  local mapBefore = hm.customFillTypePrices

  arriveAll(nil)                       -- attempt 2: the late descriptor is there
  tick(mgr, 1)
  T.eq("X1 A6: attempt 2 with every descriptor present: complete", hm._sprayTypesComplete, true)
  T.eq("X1 A7: the loop stops", mgr._deferredInitDone, true)
  T.eq("X1 A8: the late product now carries its price in the map the call-time readers use", hm.customFillTypePrices[IDX(LATE)], 1.65)
  T.eq("X1 A9: the re-patch completion line was logged", countMatching(logged.info, "Fill-type re-patch complete"), 1)
  T.eq("X1 A10: and no give-up", countMatching(logged.warning, "Gave up"), 0)
  -- (f) atomic replacement: the readers never observe a partial map.
  T.ok("X1 A11: the map was REPLACED, not mutated (a different table after attempt 2)", hm.customFillTypePrices ~= mapBefore)
  T.eq("X1 A12: the old table never gained the late product", mapBefore[IDX(LATE)], nil)
  -- (d) blends: present, resolved, unpriced, and completion is still true.
  local blendsResolved, blendsPriced = 0, 0
  for _, b in ipairs(SoilBlends.ORDER) do
    if hm:isCustomProduct(IDX(b)) then blendsResolved = blendsResolved + 1 end
    if hm.customFillTypePrices[IDX(b)] ~= nil then blendsPriced = blendsPriced + 1 end
  end
  T.eq("X1 A13: every blend resolved into the catalogue", blendsResolved, #SoilBlends.ORDER)
  T.eq("X1 A14: no blend is in the price map", blendsPriced, 0)
  T.eq("X1 A15: and completion is true regardless (blends are not eligible)", hm._sprayTypesComplete, true)
end

-- =====================================================================
-- GROUP B: a density-refused solid. In no price map, completion false while retries
-- remain; after the timeout, warned once, refusal kept, still false.
-- =====================================================================
do
  captureLogs()
  arriveAll(nil)                       -- everything present, but AN's density is unusable
  refuseAN(true)
  local mgr, hm = newWorld()
  tick(mgr, 1)
  T.eq("X1 B1: AN is refused by the real R1a registration path", hm:isRefusedProduct(IDX("AN")), true)
  T.eq("X1 B2: a refused product is in no price map", hm.customFillTypePrices[IDX("AN")], nil)
  T.eq("X1 B3: completion is false while retries remain", hm._sprayTypesComplete, false)
  T.eq("X1 B4: the loop is still live", mgr._deferredInitDone, nil)
  tick(mgr, math.ceil(TIMEOUT / FRAME) + 2)
  T.eq("X1 B5: after the timeout the loop stops (the brief's exhaustion is #970's timeout)", mgr._deferredInitDone, true)
  T.eq("X1 B6: warned exactly once", countMatching(logged.warning, "Gave up"), 1)
  T.eq("X1 B7: the refusal is kept", hm:isRefusedProduct(IDX("AN")), true)
  T.eq("X1 B8: and completion stays false", hm._sprayTypesComplete, false)
  T.ok("X1 B9: no _sprayTypesExhausted flag exists (a write-only flag is the pattern just fixed)", hm._sprayTypesExhausted == nil)
  refuseAN(false)
end

-- =====================================================================
-- GROUP C: the predicate is honest about PRICE on its own. SYNTHETIC: every name
-- resolves (skipped == 0) but one eligible product's configured price is unusable.
-- =====================================================================
do
  captureLogs()
  arriveAll(nil)
  SoilConstants.PURCHASABLE_SINGLE_NUTRIENT = { UAN32 = { pricePerLiter = -1 } }   -- SYNTHETIC negative price
  local mgr, hm = newWorld()
  tick(mgr, 1)
  T.eq("X1 C1: SYNTHETIC unusable price: the product is not in the map", hm.customFillTypePrices[IDX("UAN32")], nil)
  T.eq("X1 C2: SYNTHETIC unusable price: completion is false although every name resolved", hm._sprayTypesComplete, false)
  T.eq("X1 C3: and the loop stays live", mgr._deferredInitDone, nil)
  SoilConstants.PURCHASABLE_SINGLE_NUTRIENT = saved.pcs
  arriveAll(nil)
  local mgr2, hm2 = newWorld()
  tick(mgr2, 1)
  T.eq("X1 C4: with the shipped prices the same world completes on the first tick", hm2._sprayTypesComplete, true)
end

-- =====================================================================
-- GROUP D: an ordinary local load. Everything present from the start: complete on the
-- first tick, no warnings, the price map full.
-- =====================================================================
do
  captureLogs()
  arriveAll(nil)
  local mgr, hm = newWorld()
  tick(mgr, 1)
  T.eq("X1 D1: complete on the first tick", mgr._deferredInitDone, true)
  T.eq("X1 D2: no warnings", #logged.warning, 0)
  local priced = 0
  for _ in pairs(hm.customFillTypePrices) do priced = priced + 1 end
  local eligible = 0
  for _, n in ipairs(POP) do if HookManager.customPriceFor(n) ~= nil then eligible = eligible + 1 end end
  T.eq("X1 D3: every eligible product is priced and nothing else is (blends unpriced)", priced, eligible)
end

SoilConstants.PURCHASABLE_SINGLE_NUTRIENT = saved.pcs
g_fillTypeManager, g_sprayTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_sprayTypeManager, saved.g_currentMission
SoilLogger.warning, SoilLogger.info, SoilLogger.debug = saved.warning, saved.info, saved.debug
