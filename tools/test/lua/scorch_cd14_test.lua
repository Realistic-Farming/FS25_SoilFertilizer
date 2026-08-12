-- scorch_cd14_test.lua - heat scorch (CD-14): the correct dose on the wrong day.
-- Verifies applyScorchEffect damages the SOIL under an established standing crop
-- when a heat-sensitive product (SULFUR, COPPER_HYDROXIDE) is sprayed hot, pays
-- nothing on a mild day, ignores bare ground / seedlings, meters on its OWN
-- accumulator (never the rate burn's), and stays nil-honest (no WeatherGuard =
-- no scorch).
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local SFS = SoilConstants.SPRAYER_RATE
local HEAT = SoilConstants.HEAT_SENSITIVITY
local CERTAIN_PH = SFS.SCORCH_PH_DROP_CERTAIN
local CERTAIN_N  = SFS.SCORCH_N_DRAIN_CERTAIN
local FULL_MS    = SFS.BURN_FULL_DAMAGE_MS
local GAP_MS     = SFS.BURN_PASS_GAP_MS

-- SULFUR shift=4 → riskT=26, certainT=32 (HEAT_RISK_BASE 30 - 4, band 6).
local SULFUR_RISK    = SFS.HEAT_RISK_BASE - HEAT.SULFUR.shift
local SULFUR_CERTAIN = SULFUR_RISK + SFS.HEAT_BAND_WIDTH

-- ── world stubs (crop gate + sky read) ─────────────────────
local WHEAT = { fruitTypeIndex = 14, growthState = 6 }
local function stubWorld(tempC, state)
  state = state or WHEAT
  g_currentMission = {
    time = 1000,
    environment = { currentDay = 1, daysPerPeriod = 1 },
    missionInfo = {},
    weatherGuard = tempC ~= nil and {
      getCurrentSky = function() return { temperature = tempC } end,
    } or nil,
  }
  g_server = nil
  g_farmlandManager = { getFarmlandAtWorldPosition = function() return { id = 5 } end }
  g_fieldManager = {
    farmlandIdFieldMapping = { [5] = { posX = 100, posZ = 200 } },
  }
  FieldState = FieldState or {}
  FieldState.new = function()
    return {
      update = function(_self, _x, _z) end,
      fruitTypeIndex = state and state.fruitTypeIndex,
      growthState     = state and state.growthState,
    }
  end
  FruitType = FruitType or {}
  FruitType.UNKNOWN = 0
  g_fruitTypeManager = {
    getFruitTypeByIndex = function(_self, idx)
      if idx == WHEAT.fruitTypeIndex then
        return { name = "WHEAT", minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8, cutStates = nil }
      end
      return nil
    end,
  }
end

local function newSys(field)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { showNotifications = false },
  }, { __index = SoilFertilitySystem })
  sys._lastSprayX = 100
  sys._lastSprayZ = 200
  return sys
end

local function at(t) g_currentMission.time = t end

-- ── insensitive product: the unconditional closure call costs one probe ──────
do
  stubWorld(SULFUR_CERTAIN + 1)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  sys:applyScorchEffect(1, "FUNGICIDE")
  T.eq("scorch: an insensitive product changes nothing", field.pH, 7.0)
  T.eq("scorch: insensitive product drains no N", field.nitrogen, 60)
end

-- ── nil-honest: no WeatherGuard means no scorch, no state change ─────────────
do
  stubWorld(nil)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.eq("scorch: absent WeatherGuard holds (no pH change)", field.pH, 7.0)
  T.eq("scorch: absent WeatherGuard holds (no N change)", field.nitrogen, 60)
end

-- ── below the risk temperature: nothing ─────────────────────────────────────
do
  stubWorld(SULFUR_RISK - 1)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.eq("scorch: a mild day below riskT pays nothing", field.pH, 7.0)
  T.eq("scorch: mild day drains no N", field.nitrogen, 60)
end

-- ── first tick of a pass establishes it but docks nothing (dt == 0) ─────────
do
  stubWorld(SULFUR_CERTAIN)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0); sys:applyScorchEffect(1, "SULFUR")
  T.eq("scorch: first tick of a pass does nothing", field.pH, 7.0)
end

-- ── a 1000ms slice docks one proportional slice at certain temperature ───────
do
  stubWorld(SULFUR_CERTAIN)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  local expectedPh = CERTAIN_PH * (1000 / FULL_MS)
  local expectedN  = CERTAIN_N  * (1000 / FULL_MS)
  T.near("scorch: 1000ms slice docks one proportional pH slice", 7.0 - field.pH, expectedPh, 1e-6)
  T.near("scorch: 1000ms slice drains one proportional N slice", 60 - field.nitrogen, expectedN, 1e-6)
end

-- ── sibling boom section in the same tick (dt == 0) docks nothing extra ──────
do
  stubWorld(SULFUR_CERTAIN)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  local afterFirstPh = field.pH
  local afterFirstN  = field.nitrogen
  sys:applyScorchEffect(1, "SULFUR")   -- sibling, same time=1000 → dt==0
  T.eq("scorch: sibling section (dt==0) adds no extra pH dock", field.pH, afterFirstPh)
  T.eq("scorch: sibling section (dt==0) adds no extra N drain", field.nitrogen, afterFirstN)
end

-- ── sustained heat ramps to - and caps at - the certain per-pass magnitude ───
do
  stubWorld(SULFUR_CERTAIN)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0); sys:applyScorchEffect(1, "SULFUR")
  local t = 0
  while t < FULL_MS * 2 do
    t = t + 1000
    at(t); sys:applyScorchEffect(1, "SULFUR")
  end
  T.near("scorch: sustained heat caps pH drop at the certain magnitude", 7.0 - field.pH, CERTAIN_PH, 1e-6)
  T.near("scorch: sustained heat caps N drain at the certain magnitude", 60 - field.nitrogen, CERTAIN_N, 1e-6)
end

-- ── risk band: magnitude scales linearly with excess ─────────────────────────
-- At the band midpoint the excess is 0.5, so the per-pass caps halve.
do
  stubWorld(SULFUR_RISK + SFS.HEAT_BAND_WIDTH * 0.5)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  local excess = 0.5
  local expectedPh = (SFS.SCORCH_PH_DROP_RISK * excess) * (1000 / FULL_MS)
  local expectedN  = (SFS.SCORCH_N_DRAIN_RISK  * excess) * (1000 / FULL_MS)
  T.near("scorch: mid-band slice scales pH by excess", 7.0 - field.pH, expectedPh, 1e-6)
  T.near("scorch: mid-band slice scales N by excess", 60 - field.nitrogen, expectedN, 1e-6)
end

-- ── crop gate: bare ground and seedlings cannot scorch ───────────────────────
do
  stubWorld(SULFUR_CERTAIN, { fruitTypeIndex = FruitType.UNKNOWN, growthState = 6 })
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.eq("scorch: bare ground cannot scorch", field.pH, 7.0)
end

do
  stubWorld(SULFUR_CERTAIN, { fruitTypeIndex = WHEAT.fruitTypeIndex, growthState = 1 })
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.eq("scorch: a seedling cannot scorch", field.pH, 7.0)
end

-- ── an established crop DOES scorch ──────────────────────────────────────────
do
  stubWorld(SULFUR_CERTAIN, WHEAT)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.ok("scorch: an established crop takes a proportional slice", field.pH < 7.0)
  T.ok("scorch: established crop loses N too", field.nitrogen < 60)
end

-- ── own accumulator: a gap opens a fresh pass (its first tick docks nothing) ─
do
  stubWorld(SULFUR_CERTAIN, WHEAT)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")   -- one slice
  local afterPass1 = field.pH
  at(1000 + GAP_MS + 1); sys:applyScorchEffect(1, "SULFUR")  -- gap → fresh pass
  T.eq("scorch: a gap > BURN_PASS_GAP_MS opens a fresh pass (no dock that tick)",
       field.pH, afterPass1)
end

-- ── scorch's accumulator is independent of the rate burn's ───────────────────
-- A pass that trips scorch writes _scorchTickTime/_scorchPassPh, never the
-- burn's _lastBurnTickTime/_burnPassPh: resetting one must not reset the other.
do
  stubWorld(SULFUR_CERTAIN, WHEAT)
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.ok("scorch: uses its own tick timestamp", field._scorchTickTime ~= nil)
  T.ok("scorch: does not write the burn's tick timestamp", field._lastBurnTickTime == nil)
  T.ok("scorch: own pass accumulator exists", field._scorchPassPh ~= nil and field._scorchPassPh > 0)
end

-- ── the pH floor still applies under the nutrient limits ─────────────────────
do
  stubWorld(SULFUR_CERTAIN, WHEAT)
  local low = { pH = SoilConstants.NUTRIENT_LIMITS.PH_MIN + 0.01, nitrogen = 0.5 }
  local sys = newSys(low)
  at(0);    sys:applyScorchEffect(1, "SULFUR")
  at(1000); sys:applyScorchEffect(1, "SULFUR")
  T.ok("scorch: pH docks toward but never below the floor",
       low.pH >= SoilConstants.NUTRIENT_LIMITS.PH_MIN)
  T.ok("scorch: N docks toward but never below the floor",
       low.nitrogen >= SoilConstants.NUTRIENT_LIMITS.MIN)
end
