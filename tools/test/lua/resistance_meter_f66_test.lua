-- resistance_meter_f66_test.lua - per-MOA resistance build metering (CD-9 / F66).
--
-- F66: the resistance build in onFungicideAppliedDirect had no per-pass meter while both
-- sibling consequences in the same function did. The hook is an appended function on
-- Sprayer.onEndWorkAreaProcessing and lands once per boom SECTION per FRAME ("1000+ times
-- per spray pass"), so a bare increment of BUILD_PER_APPLICATION * maxRes saturated a mode
-- inside the first second of the first pass; since the penalty is (1 - score/maxRes), the
-- fungicide dropped to zero effect partway through the pass the player was spraying.
--
-- The fix restores the dose_factor term the ratified CD-9 design specified: the increment
-- scales by liters / targetVol, exactly as every other consequence in that function does.
--
-- These assertions are load-bearing for CD-12, which changes this same expression to
-- BUILD_PER_APPLICATION * maxRes(partner) / #partners. Halving a saturated build is not a
-- feature, so the meter has to still be here when the tank mix lands.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SoilFertilitySystem.lua

local R          = SoilConstants.RESISTANCE
local BUILD      = R.BUILD_PER_APPLICATION
local MAX_SYN    = R.MAX_SYNTHETIC
local MAX_NAT    = R.MAX_NATURAL
local RATE_SYN   = SoilConstants.SPRAYER_RATE.BASE_RATES.PROPICONAZOLE.value  -- L/ha
local RATE_NAT   = SoilConstants.SPRAYER_RATE.BASE_RATES.SULFUR.value

local AREA_HA    = 10
local FULL_PASS  = AREA_HA * RATE_SYN        -- liters in one full-rate pass over the field
local PER_PASS   = BUILD * MAX_SYN           -- resistance one full synthetic pass must add

-- A field the spray path can act on without touching the game: area already confirmed and
-- the session non-empty, so the farmland-resolve block is skipped entirely.
local function newField(extra)
  local f = {
    fieldArea              = AREA_HA,
    _farmlandAreaConfirmed = true,
    sessionCoverageCells   = { ["0:0"] = true },
    resistance             = {},
    diseasePressure        = 50,
    nutrientBuffer         = {},
  }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

-- trackSprayerCoverage and onFungicideAppliedIncremental are stubbed: this test is about
-- the meter, and the incremental stub doubles as the probe for the effectiveness penalty.
local function newSys(field)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { diseasePressure = true, showNotifications = false },
    reductions = {},
  }, { __index = SoilFertilitySystem })
  sys.trackSprayerCoverage = function() end
  sys.onFungicideAppliedIncremental = function(self, _, reduction)
    self.reductions[#self.reductions + 1] = reduction
  end
  return sys
end

-- Deliver `liters` total as `n` equal section calls, the way a boom actually arrives.
local function spray(sys, chem, liters, n)
  local slice = liters / n
  for _ = 1, n do sys:onFungicideAppliedDirect(1, 1.0, slice, chem) end
end

-- ── THE REGRESSION. One full-rate pass arriving as 1000 section calls builds exactly one
-- application's worth. Under the unmetered build this reached the ceiling on call 20.
do
  local field = newField()
  local sys   = newSys(field)
  spray(sys, "PROPICONAZOLE", FULL_PASS, 1000)
  T.near("F66: 1000 section calls over one full pass build ONE application", field.resistance["3"], PER_PASS, 1e-9)
  T.ok("F66: one pass does NOT saturate the mode", field.resistance["3"] < MAX_SYN)
end

-- The meter is dose-based, not call-count based: the same liters in one call or a thousand
-- must land on the same number.
do
  local a, b = newField(), newField()
  spray(newSys(a), "PROPICONAZOLE", FULL_PASS, 1)
  spray(newSys(b), "PROPICONAZOLE", FULL_PASS, 500)
  T.near("F66: call count does not change the build", a.resistance["3"], b.resistance["3"], 1e-9)
end

-- A partial pass builds partial resistance - the property that makes the meter honest.
do
  local field = newField()
  spray(newSys(field), "PROPICONAZOLE", FULL_PASS * 0.25, 100)
  T.near("F66: a quarter pass builds a quarter application", field.resistance["3"], PER_PASS * 0.25, 1e-9)
end

-- CD-9's ratified intent: 0.05 per full-rate pass, so twenty passes reach the ceiling.
do
  local field = newField()
  local sys   = newSys(field)
  for _ = 1, 20 do spray(sys, "PROPICONAZOLE", FULL_PASS, 50) end
  T.near("F66: twenty full passes reach the synthetic ceiling", field.resistance["3"], MAX_SYN, 1e-6)
end

-- The dose factor is capped at 1.0, so one oversized call can never count as more than one
-- pass no matter what liters a sprayer hands us.
do
  local field = newField()
  spray(newSys(field), "PROPICONAZOLE", FULL_PASS * 10, 1)
  T.near("F66: an oversized single call is capped at one pass", field.resistance["3"], PER_PASS, 1e-9)
end

-- The ceiling is never exceeded.
do
  local field = newField()
  local sys   = newSys(field)
  for _ = 1, 60 do spray(sys, "PROPICONAZOLE", FULL_PASS, 10) end
  T.eq("F66: resistance never exceeds the ceiling", field.resistance["3"], MAX_SYN)
end

-- Naturals meter against their own (lower) ceiling. F68 - that this makes no behavioural
-- difference to the penalty - is a separate, open finding and is deliberately NOT fixed here.
do
  local field = newField()
  local sys   = newSys(field)
  spray(sys, "SULFUR", AREA_HA * RATE_NAT, 200)
  T.near("F66: a natural full pass meters against MAX_NATURAL", field.resistance["M2"], BUILD * MAX_NAT * R.BUILD_RATE_NATURAL, 1e-9)
end

-- Each mode of action meters independently - PROPICONAZOLE and TEBUCONAZOLE share FRAC 3,
-- AZOXYSTROBIN is FRAC 11.
do
  local field = newField()
  local sys   = newSys(field)
  spray(sys, "PROPICONAZOLE", FULL_PASS, 100)
  spray(sys, "TEBUCONAZOLE",  FULL_PASS, 100)
  spray(sys, "AZOXYSTROBIN",  FULL_PASS, 100)
  T.near("F66: same-FRAC chemicals accumulate on one mode", field.resistance["3"], PER_PASS * 2, 1e-9)
  T.near("F66: a different FRAC group builds separately", field.resistance["11"], PER_PASS, 1e-9)
end

-- Generic FUNGICIDE has no MOA, so it builds nothing.
do
  local field = newField()
  spray(newSys(field), "FUNGICIDE", FULL_PASS, 100)
  T.ok("F66: generic FUNGICIDE builds no resistance (no MOA)", next(field.resistance) == nil)
end

-- The organic guard survives the move: a synthetic on a certified field builds no
-- resistance, an approved natural still does.
do
  local field = newField({ organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED } })
  local sys   = newSys(field)
  spray(sys, "PROPICONAZOLE", FULL_PASS, 100)
  T.ok("F66: synthetic on a certified field builds no resistance", field.resistance["3"] == nil)
  spray(sys, "SULFUR", AREA_HA * RATE_NAT, 100)
  T.near("F66: approved natural still builds on a certified field", field.resistance["M2"], BUILD * MAX_NAT * R.BUILD_RATE_NATURAL, 1e-9)
end

-- The penalty still bites: at the ceiling, effectiveness is zero and the pass reduces no
-- disease pressure. This is the consequence that made F66 player-visible.
do
  local field = newField({ resistance = { ["3"] = MAX_SYN } })
  local sys   = newSys(field)
  spray(sys, "PROPICONAZOLE", FULL_PASS, 10)
  local total = 0
  for _, r in ipairs(sys.reductions) do total = total + r end
  T.eq("F66: a saturated mode still zeroes the fungicide", total, 0)
end

-- ...and a clean mode does reduce pressure, so the test above is measuring the penalty
-- rather than a broken harness.
do
  local field = newField()
  local sys   = newSys(field)
  spray(sys, "PROPICONAZOLE", FULL_PASS, 10)
  local total = 0
  for _, r in ipairs(sys.reductions) do total = total + r end
  T.ok("F66: a clean mode still reduces disease pressure", total > 0)
end

-- The meter's denominator is the CONFIRMED field area. An unconfirmed field would sit at
-- the 1.0 ha default, which is exactly what would collapse targetVol and re-create the
-- saturation, so the build must stay below the area-confirm block.
do
  local small, large = newField({ fieldArea = 1 }), newField({ fieldArea = 100 })
  spray(newSys(small), "PROPICONAZOLE", 1 * RATE_SYN, 50)
  spray(newSys(large), "PROPICONAZOLE", 100 * RATE_SYN, 50)
  T.near("F66: a full pass is a full pass on any field size", small.resistance["3"], large.resistance["3"], 1e-9)
  T.near("F66: full-pass build is area-independent", small.resistance["3"], PER_PASS, 1e-9)
end
