-- burn_test.lua — over-application burn metering (#649 / 0bc748c).
-- Verifies applyBurnEffect docks a slice proportional to elapsed over-spray time,
-- caps the total per pass, ignores sibling sections (dt==0), and does nothing on the
-- first tick of a pass.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local SR = SoilConstants.SPRAYER_RATE
local GUARANTEED = SR.BURN_GUARANTEED_THRESHOLD       -- deterministic band (no math.random)
local FULL_PH    = SR.BURN_PH_DROP_CERTAIN
local FULL_MS    = SR.BURN_FULL_DAMAGE_MS
local GAP_MS     = SR.BURN_PASS_GAP_MS

local function newSys(field)
  return setmetatable({
    fieldData = { [1] = field },
    settings  = { showNotifications = false },
  }, { __index = SoilFertilitySystem })
end

local function at(t) g_currentMission.time = t end

-- First tick of a pass establishes the pass but docks nothing (dt == 0).
do
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0); sys:applyBurnEffect(1, GUARANTEED)
  T.eq("burn: first tick of a pass does nothing", field.pH, 7.0)
end

-- A brief overlap (one short slice) costs only a small proportional fraction.
do
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyBurnEffect(1, GUARANTEED)   -- open the pass
  at(1000); sys:applyBurnEffect(1, GUARANTEED)   -- 1000 ms slice
  local expectedSlice = FULL_PH * (1000 / FULL_MS)
  T.near("burn: 1000ms overlap docks one proportional slice", 7.0 - field.pH, expectedSlice, 1e-6)
end

-- A sibling boom section in the same tick (same timestamp) docks nothing extra.
do
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyBurnEffect(1, GUARANTEED)
  at(1000); sys:applyBurnEffect(1, GUARANTEED)   -- section 1 of this tick
  local afterFirst = field.pH
  sys:applyBurnEffect(1, GUARANTEED)             -- section 2, same time=1000 → dt==0
  T.eq("burn: sibling section (dt==0) adds no extra dock", field.pH, afterFirst)
end

-- Sustained over-spray ramps to — and caps at — the full per-pass magnitude.
do
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0); sys:applyBurnEffect(1, GUARANTEED)      -- open pass
  -- Advance in <=GAP_MS steps so it stays one continuous pass, well past FULL_MS.
  local t = 0
  while t < FULL_MS * 2 do
    t = t + 1000
    at(t); sys:applyBurnEffect(1, GUARANTEED)
  end
  T.near("burn: total pH drop caps at BURN_PH_DROP_CERTAIN", 7.0 - field.pH, FULL_PH, 1e-6)
  T.ok("burn: capped drop never exceeds the per-pass magnitude", (7.0 - field.pH) <= FULL_PH + 1e-9)
end

-- A gap longer than BURN_PASS_GAP_MS starts a fresh pass (its first tick docks nothing).
do
  local field = { pH = 7.0, nitrogen = 60 }
  local sys = newSys(field)
  at(0);    sys:applyBurnEffect(1, GUARANTEED)
  at(1000); sys:applyBurnEffect(1, GUARANTEED)        -- one slice
  local afterPass1 = field.pH
  at(1000 + GAP_MS + 1); sys:applyBurnEffect(1, GUARANTEED)  -- gap → fresh pass, dt resets
  T.eq("burn: a gap > BURN_PASS_GAP_MS opens a fresh pass (no dock that tick)",
       field.pH, afterPass1)
end
