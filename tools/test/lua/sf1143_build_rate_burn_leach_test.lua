-- sf1143_build_rate_burn_leach_test.lua - #1143/#1146 (antler22): the four build-rate
-- / burn / leach changes owed automated tests before merge (Bob's review at 2f7d1ca4).
--   (A/B) New "build" rate steps 21-24: SoilConstants.allowsBuildRate gates which
--   products may reach them (P/K/pH products with N <= BUILD_MAX_PRODUCT_N, never a
--   pest/disease product), and SprayerRateManager:cycleUp enforces the ceiling and
--   holds (never snaps down) a rate already above it on a disallowed product swap.
--   (C/D) The rate burn now skips bare/seedling ground (isAmendmentBurnRisk's crop
--   gate, reused via the new _burnCropEstablishedAtSpray) and scales its N drain by
--   the sprayed product's own N content, leaving pH untouched and the legacy no-gate/
--   no-scaling behaviour intact when no spray position or product name is given.
--   (E/F) Per-N-source leach: applyFertilizer blends field.nLeachMult toward each
--   product's SoilConstants.N_SOURCE_LEACH rate, weighted by the N actually added
--   AFTER the nutrient ceiling clamps it (not the nominal dose), and applyRainEffects
--   reads that multiplier back to scale nitrogen leaching only; K and P rain-leach now
--   use the halved/quartered RAIN multipliers (1 and 0.25) regardless of N source.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/SprayerRateManager.lua

local SR = SoilConstants.SPRAYER_RATE

-- =====================================================================
-- GROUP A: SoilConstants.allowsBuildRate - which products may build past 2.0x.
-- =====================================================================

T.eq("build: MAP (low N, has P) may build", SoilConstants.allowsBuildRate("MAP"), true)
T.eq("build: DAP (low N, has P) may build", SoilConstants.allowsBuildRate("DAP"), true)
T.eq("build: LIME (no N, has pH) may build", SoilConstants.allowsBuildRate("LIME"), true)
T.eq("build: PELLETIZED_MANURE (low N, has P/K) may build", SoilConstants.allowsBuildRate("PELLETIZED_MANURE"), true)

T.eq("build: UREA (N over the cap) may not build", SoilConstants.allowsBuildRate("UREA"), false)
T.eq("build: UAN28 (N over the cap) may not build", SoilConstants.allowsBuildRate("UAN28"), false)
T.eq("build: AN (N over the cap) may not build", SoilConstants.allowsBuildRate("AN"), false)
T.eq("build: ANHYDROUS (N over the cap) may not build", SoilConstants.allowsBuildRate("ANHYDROUS"), false)
T.eq("build: base-game FERTILIZER (N over the cap) may not build", SoilConstants.allowsBuildRate("FERTILIZER"), false)

T.eq("build: nil product never builds", SoilConstants.allowsBuildRate(nil), false)
T.eq("build: an unknown product name never builds", SoilConstants.allowsBuildRate("NOT_A_REAL_PRODUCT"), false)

do
  -- A synthetic low-N crop-protection product: the pest/disease gate must win even
  -- though it otherwise has a qualifying P value and N under the cap.
  SoilConstants.FERTILIZER_PROFILES.TEST_SF1143_PESTGUARD = { N = 0, P = 10, pestReduction = true }
  T.eq("build: a pest/disease product is excluded even with a qualifying P value",
       SoilConstants.allowsBuildRate("TEST_SF1143_PESTGUARD"), false)
  SoilConstants.FERTILIZER_PROFILES.TEST_SF1143_PESTGUARD = nil
end

-- =====================================================================
-- GROUP B: SprayerRateManager:cycleUp - the build-rate ceiling and its floor-hold.
-- =====================================================================

local FIRST_BUILD = SR.BUILD_FIRST_INDEX
local NSTEPS = #SR.STEPS

do
  local rm = SprayerRateManager.new()
  T.eq("rate: starts at the default index", rm:getIndex(1), SR.DEFAULT_INDEX)
  for _ = 1, 20 do rm:cycleUp(1) end   -- no clearance; far more presses than the gap to 20
  T.eq("rate: without build clearance, cycling up stops at the upstream ceiling",
       rm:getIndex(1), FIRST_BUILD - 1)
end

do
  local rm = SprayerRateManager.new()
  rm:setIndex(1, FIRST_BUILD - 1)   -- at the upstream ceiling (20)
  T.eq("rate: with clearance, the next press enters the first build step",
       rm:cycleUp(1, true), FIRST_BUILD)
  rm:cycleUp(1, true); rm:cycleUp(1, true)
  T.eq("rate: with clearance, cycling up caps at the last step", rm:cycleUp(1, true), NSTEPS)
  T.eq("rate: pressing again at the top step is a no-op", rm:cycleUp(1, true), NSTEPS)
end

do
  -- A product swap mid-build to a product that cannot build: the held rate does not
  -- snap down to the upstream ceiling just because the up key was pressed.
  local rm = SprayerRateManager.new()
  rm:setIndex(1, FIRST_BUILD + 1)   -- deep in the build range (22)
  local idx = rm:cycleUp(1, false)
  T.eq("rate: a disallowed product swap holds the rate instead of snapping it down",
       idx, FIRST_BUILD + 1)
  T.eq("rate: the held rate is actually stored, not just returned", rm:getIndex(1), FIRST_BUILD + 1)
  T.eq("rate: clearance restored resumes the climb from the held index",
       rm:cycleUp(1, true), FIRST_BUILD + 2)
end

do
  local rm = SprayerRateManager.new()
  rm:setIndex(1, FIRST_BUILD + 1)
  T.eq("rate: cycleDown is unaffected by the build-rate ceiling", rm:cycleDown(1), FIRST_BUILD)
end

-- =====================================================================
-- GROUP C/D: applyBurnEffect - the crop-state gate and the product-N-scaled drain.
-- =====================================================================

local GUARANTEED = SR.BURN_GUARANTEED_THRESHOLD
local FULL_PH     = SR.BURN_PH_DROP_CERTAIN
local FULL_N      = SR.BURN_N_DRAIN_CERTAIN
local FULL_MS     = SR.BURN_FULL_DAMAGE_MS
local SCALE_REF   = SR.BURN_N_SCALE_REF or 100

local WHEAT_IDX = 14
FieldState = FieldState or {}
FruitType  = FruitType or {}
FruitType.UNKNOWN = FruitType.UNKNOWN or 0

local function stubCrop(fruitIndex, growthState)
  FieldState.new = function()
    return { update = function() end, fruitTypeIndex = fruitIndex, growthState = growthState }
  end
end

g_fruitTypeManager = g_fruitTypeManager or {}
g_fruitTypeManager.getFruitTypeByIndex = function(_self, idx)
  if idx == WHEAT_IDX then
    return { name = "WHEAT", minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8, cutStates = nil }
  end
  return nil
end

local function newBurnSys(field, withSprayPos)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { showNotifications = false },
  }, { __index = SoilFertilitySystem })
  if withSprayPos ~= false then
    sys._lastSprayX, sys._lastSprayZ = 100, 200
  end
  return sys
end

local function at(t) g_currentMission.time = t end

-- ── crop gate: bare ground and a seedling cannot take the rate burn ──────────
do
  stubCrop(FruitType.UNKNOWN, 6)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field)
  at(0);    sys:applyBurnEffect(1, GUARANTEED, "UREA")
  at(1000); sys:applyBurnEffect(1, GUARANTEED, "UREA")
  T.eq("rate burn: bare ground takes no burn", field.pH, 7.0)
  T.eq("rate burn: the gate's early return clears the pass clock", field._lastBurnTickTime, nil)
end

do
  stubCrop(WHEAT_IDX, 1)   -- seedling: below the established-growth threshold
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field)
  at(0);    sys:applyBurnEffect(1, GUARANTEED, "UREA")
  at(1000); sys:applyBurnEffect(1, GUARANTEED, "UREA")
  T.eq("rate burn: a seedling takes no burn", field.pH, 7.0)
end

-- ── crop gate: an established crop still takes the burn ──────────────────────
do
  stubCrop(WHEAT_IDX, 6)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field)
  at(0);    sys:applyBurnEffect(1, GUARANTEED, "UREA")
  at(1000); sys:applyBurnEffect(1, GUARANTEED, "UREA")
  T.ok("rate burn: an established crop still burns", field.pH < 7.0)
end

-- ── with no spray position on record, the gate defaults to the legacy behaviour ──
-- Every caller before this PR, and HookManager's own two call sites if a spray
-- position were ever missing, must still burn - the gate only exempts a POSITIVELY
-- read bare/seedling ground, never an unresolved one.
do
  stubCrop(FruitType.UNKNOWN, 6)   -- would read as bare ground if the gate consulted it
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field, false)   -- no _lastSprayX/_lastSprayZ
  at(0);    sys:applyBurnEffect(1, GUARANTEED, "UREA")
  at(1000); sys:applyBurnEffect(1, GUARANTEED, "UREA")
  T.ok("rate burn: an unresolved spray position still burns (unchanged legacy behaviour)",
       field.pH < 7.0)
end

-- ── N drain scales with the product's own N content; pH does not ────────────
do
  stubCrop(WHEAT_IDX, 6)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field)
  at(0); sys:applyBurnEffect(1, GUARANTEED, "MAP")
  local t = 0
  while t < FULL_MS * 2 do
    t = t + 1000
    at(t); sys:applyBurnEffect(1, GUARANTEED, "MAP")
  end
  local mapN = SoilConstants.FERTILIZER_PROFILES.MAP.N
  local expectedN = FULL_N * math.min(1.0, mapN / SCALE_REF)
  T.near("rate burn: a low-N product (MAP) drains N in proportion to its own N content",
         60 - field.nitrogen, expectedN, 1e-6)
  T.near("rate burn: the pH drop is unaffected by the product's N content", 7.0 - field.pH, FULL_PH, 1e-6)
end

do
  stubCrop(WHEAT_IDX, 6)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field)
  at(0); sys:applyBurnEffect(1, GUARANTEED, "UREA")
  local t = 0
  while t < FULL_MS * 2 do
    t = t + 1000
    at(t); sys:applyBurnEffect(1, GUARANTEED, "UREA")
  end
  T.near("rate burn: a high-N product (UREA, at/above the scale reference) keeps the full drain",
         60 - field.nitrogen, FULL_N, 1e-6)
end

do
  -- Defensive: a caller that passes no product name (the pre-PR two-arg shape) keeps
  -- the full, unscaled drain rather than erroring or zeroing it out.
  stubCrop(WHEAT_IDX, 6)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newBurnSys(field)
  at(0); sys:applyBurnEffect(1, GUARANTEED)
  local t = 0
  while t < FULL_MS * 2 do
    t = t + 1000
    at(t); sys:applyBurnEffect(1, GUARANTEED)
  end
  T.near("rate burn: no product name passed keeps the full unscaled drain (back-compat)",
         60 - field.nitrogen, FULL_N, 1e-6)
end

-- =====================================================================
-- GROUP E: applyFertilizer - the per-N-source leach blend (field.nLeachMult).
-- =====================================================================

local LIMITS = SoilConstants.NUTRIENT_LIMITS
local NSL    = SoilConstants.N_SOURCE_LEACH

local function fertSys(field)
  field.fieldArea = 2   -- ha; large enough that the area-resolve path is a harmless no-op
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { enabled = true },
  }, { __index = SoilFertilitySystem })
  sys.getOrCreateField = function(_self, fid) return _self.fieldData[fid] end
  return sys
end

local savedFillMgr = g_fillTypeManager
local FILL_NAMES = { [1] = "MAP", [2] = "UREA", [3] = "ANHYDROUS", [4] = "STARTER" }
g_fillTypeManager = { getFillTypeByIndex = function(_self, idx)
  local n = FILL_NAMES[idx]
  return n and { name = n, index = idx } or nil
end }

-- Mirrors applyFertilizer's own arithmetic (default replenishment + tuning multipliers
-- are both 1.0 at settings index 3) so the expected value is derived, not transcribed.
local function expectedAdd(entryN, liters, areaHa, nBefore, maxN)
  local factor = (liters / 1000) / areaHa
  return math.min(maxN, nBefore + entryN * factor) - nBefore
end
local function blend(nBefore, oldMult, nAdded, srcMult)
  return (nBefore * oldMult + nAdded * srcMult) / (nBefore + nAdded)
end

do
  local field = { pH = 6.5, nitrogen = 10, phosphorus = 40, potassium = 30, organicMatter = 3 }
  local sys = fertSys(field)
  sys:applyFertilizer(1, 1, 1000, nil)   -- MAP
  local nAdded = expectedAdd(SoilConstants.FERTILIZER_PROFILES.MAP.N, 1000, 2, 10, LIMITS.MAX)
  local want = blend(10, 1.0, nAdded, NSL.MAP)
  T.near("fertilizer: one MAP application blends nLeachMult toward MAP's own rate",
         field.nLeachMult, want, 1e-6)
  T.ok("fertilizer: MAP's rate pulls the blend below the upstream default of 1.0",
       field.nLeachMult ~= nil and field.nLeachMult < 1.0)
end

do
  local field = { pH = 6.5, nitrogen = 10, phosphorus = 40, potassium = 30, organicMatter = 3 }
  local sys = fertSys(field)
  sys:applyFertilizer(1, 1, 1000, nil)   -- MAP
  local afterFirst = field.nLeachMult
  local nBefore2 = field.nitrogen
  sys:applyFertilizer(1, 1, 1000, nil)   -- MAP again
  local nAdded2 = expectedAdd(SoilConstants.FERTILIZER_PROFILES.MAP.N, 1000, 2, nBefore2, LIMITS.MAX)
  local want2 = blend(nBefore2, afterFirst, nAdded2, NSL.MAP)
  T.near("fertilizer: a repeat application re-blends from the running multiplier, not from 1.0 again",
         field.nLeachMult, want2, 1e-6)
end

do
  -- ANHYDROUS at this rate would nominally add far more than the headroom left to the
  -- 100-point ceiling; the blend must weight by what actually landed (10), not the dose.
  local field = { pH = 6.5, nitrogen = 90, phosphorus = 40, potassium = 30, organicMatter = 3 }
  local sys = fertSys(field)
  sys:applyFertilizer(1, 3, 1000, nil)   -- ANHYDROUS
  T.eq("fertilizer: nitrogen clamps at the ceiling", field.nitrogen, LIMITS.MAX)
  local want = blend(90, 1.0, LIMITS.MAX - 90, NSL.ANHYDROUS)
  T.near("fertilizer: the blend uses the clamped addition, not ANHYDROUS's full nominal dose",
         field.nLeachMult, want, 1e-6)
end

do
  local field = { pH = 6.5, nitrogen = 10, phosphorus = 40, potassium = 30, organicMatter = 3 }
  local sys = fertSys(field)
  sys:applyFertilizer(1, 1, 1000, nil)   -- MAP: moves the multiplier away from 1.0
  local afterMap = field.nLeachMult
  T.ok("fertilizer: sanity, the MAP application actually moved the multiplier",
       afterMap ~= nil and afterMap < 1.0)
  sys:applyFertilizer(1, 4, 1000, nil)   -- STARTER: has N, but no N_SOURCE_LEACH entry
  T.eq("fertilizer: a product with N but no listed leach rate (STARTER) leaves the multiplier as it was",
       field.nLeachMult, afterMap)
end

do
  local field = { pH = 6.5, nitrogen = 100, phosphorus = 40, potassium = 30, organicMatter = 3 }
  local sys = fertSys(field)
  sys:applyFertilizer(1, 1, 1000, nil)   -- MAP, but no headroom to add
  T.eq("fertilizer: a field already at the nitrogen ceiling takes no multiplier blend",
       field.nLeachMult, nil)
end

g_fillTypeManager = savedFillMgr

-- =====================================================================
-- GROUP F: applyRainEffects - nLeachMult scales N leaching only; K/P multipliers.
-- =====================================================================

T.eq("rain: potassium leach multiplier is halved from upstream (2 -> 1)",
     SoilConstants.RAIN.POTASSIUM_MULTIPLIER, 1)
T.eq("rain: phosphorus leach multiplier is quartered from upstream (0.5 -> 0.25)",
     SoilConstants.RAIN.PHOSPHORUS_MULTIPLIER, 0.25)

local function leachSys(nLeachMult)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true, rainEffects = true, weatherSource = 3 }
  s.vmAvailable = function() return false end
  s.activeFieldIds = { [1] = true }
  s.fieldData = { [1] = { nitrogen = 50, potassium = 50, phosphorus = 50, pH = 6.5,
                           organicMatter = 3, nLeachMult = nLeachMult } }
  s._rainWasFilled = false
  return s
end

do
  local real  = leachSys(nil)   -- no source on record: upstream default (1.0)
  local one   = leachSys(1.0)   -- explicit 1.0, same as the default
  real:applyRainEffects(1e6, 0.5)
  one:applyRainEffects(1e6, 0.5)
  T.near("rain: an absent nLeachMult leaches nitrogen exactly as an explicit 1.0 does",
         real.fieldData[1].nitrogen, one.fieldData[1].nitrogen, 1e-9)
  T.ok("rain: some nitrogen actually leached, so the comparison is not vacuous",
       real.fieldData[1].nitrogen < 50)
end

do
  local slow = leachSys(0.5)   -- anhydrous-like: held in the retention band
  local fast = leachSys(1.2)   -- AN-like: half nitrate, mobile on contact
  local base = leachSys(1.0)
  slow:applyRainEffects(1e6, 0.5)
  fast:applyRainEffects(1e6, 0.5)
  base:applyRainEffects(1e6, 0.5)
  T.ok("rain: a slow N source (0.5) leaches less nitrogen than the upstream default",
       slow.fieldData[1].nitrogen > base.fieldData[1].nitrogen)
  T.ok("rain: a fast N source (1.2) leaches more nitrogen than the upstream default",
       fast.fieldData[1].nitrogen < base.fieldData[1].nitrogen)
  T.near("rain: the slow source leaches exactly half of the base nitrogen loss",
         50 - slow.fieldData[1].nitrogen, (50 - base.fieldData[1].nitrogen) * 0.5, 1e-9)
end

do
  -- nLeachMult must scale nitrogen ONLY - potassium and phosphorus losses are identical
  -- no matter the field's recorded N source.
  local slow = leachSys(0.5)
  local fast = leachSys(1.2)
  slow:applyRainEffects(1e6, 0.5)
  fast:applyRainEffects(1e6, 0.5)
  T.near("rain: potassium leach is unaffected by nLeachMult",
         slow.fieldData[1].potassium, fast.fieldData[1].potassium, 1e-9)
  T.near("rain: phosphorus leach is unaffected by nLeachMult",
         slow.fieldData[1].phosphorus, fast.fieldData[1].phosphorus, 1e-9)
  T.ok("rain: potassium and phosphorus actually leached, so the comparison is not vacuous",
       slow.fieldData[1].potassium < 50 and slow.fieldData[1].phosphorus < 50)
end
