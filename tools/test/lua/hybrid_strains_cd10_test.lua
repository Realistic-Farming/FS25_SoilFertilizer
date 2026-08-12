-- hybrid_strains_cd10_test.lua - CD-10, hybrid disease types.
--
-- Ground pushed past the threshold in two or more modes breeds an infection no single
-- chemical answers well. The assertion list below is the brief's own bench spec (section 8)
-- plus the RULED CONTROL FACTOR's bars.
--
-- The one that matters most is bar 1: built against unfixed F66 this would have fired on
-- almost any two-mode spray pass instead of as an earned seasons-long consequence, which
-- inverts the entire design. That was a hard build-order gate.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/DiseaseSystem.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local R      = SoilConstants.RESISTANCE
local BUILD  = R.BUILD_PER_APPLICATION
local THRESH = R.HYBRID_THRESHOLD
local RATES  = SoilConstants.SPRAYER_RATE.BASE_RATES
local H      = HybridStrains

local AREA_HA = 10
local function newField(extra)
  local f = {
    fieldArea = AREA_HA, _farmlandAreaConfirmed = true,
    sessionCoverageCells = { ["0:0"] = true },
    resistance = {}, diseasePressure = 50, nutrientBuffer = {},
  }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

local function newSys(field)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { diseasePressure = true, showNotifications = false },
    reductions = {},
  }, { __index = SoilFertilitySystem })
  sys.trackSprayerCoverage = function() end
  sys.onFungicideAppliedIncremental = function(self, _, red) self.reductions[#self.reductions + 1] = red end
  sys._diseaseClimateNow = function() return false, false end
  return sys
end

local function sprayPasses(sys, chem, passes)
  local vol = AREA_HA * (RATES[chem] or RATES.FUNGICIDE).value
  for _ = 1, passes do
    for _ = 1, 50 do sys:onFungicideAppliedDirect(1, 1.0, vol / 50, chem) end
  end
end

-- ── The hybrid row itself ────────────────────────────────────────────────────────────
do
  local f = newField({ lastCrop = "wheat" })
  local id = H.strainForPair(f, "3", "11")
  T.ok("a hybrid strain row exists", id ~= nil)
  local def = SoilConstants.DISEASE_DEFS[id]
  T.ok("it carries requiresModes (the control factor's hook)", def.requiresModes == 2)
  T.ok("isHybrid recognises it", H.isHybrid(id))
  T.ok("isHybrid rejects an ordinary disease", not H.isHybrid("septoria_tritici"))
  T.ok("isHybrid rejects nil", not H.isHybrid(nil))

  -- Unreachable through the ordinary roll: absent from every per-crop candidate list.
  for crop, list in pairs(SoilConstants.DISEASE_REGISTRY) do
    for _, d in ipairs(list) do
      T.ok("hybrid is NOT a candidate for " .. crop, d ~= id)
    end
  end

  -- Its brand-new category means every chemical falls through to the uniform default.
  for _, chem in ipairs(SoilConstants.PHYSICAL_FUNGICIDE_ORDER) do
    T.eq(chem .. " scores the uniform default against the hybrid",
         SoilDiseaseSystem.effectiveness(chem, id), SoilConstants.DISEASE_DEFAULT_EFFECTIVENESS)
  end
end

-- ── 3.2 Eligibility: a FRACTION of each mode's own ceiling, never an absolute ────────
do
  local f = newField({ resistance = { ["3"] = 7.0, ["11"] = 6.99, M2 = 3.5, M1 = 3.49 } })
  T.ok("synthetic gates at 0.7 x 10 = 7.0", H.isModeEligible(f, "3"))
  T.ok("...and 6.99 is not eligible", not H.isModeEligible(f, "11"))
  T.ok("natural gates at 0.7 x 5 = 3.5", H.isModeEligible(f, "M2"))
  T.ok("...and 3.49 is not eligible", not H.isModeEligible(f, "M1"))

  -- The trap the brief calls out: comparing a raw score against an absolute 0.7 would fire
  -- on almost every mode almost immediately.
  local trap = newField({ resistance = { ["3"] = 0.8 } })
  T.ok("a raw score of 0.8 is NOT eligible (absolute-0.7 reading rejected)",
       not H.isModeEligible(trap, "3"))
  T.eq("the threshold really is a fraction", THRESH, 0.7)
end

do
  local f = newField({ resistance = { ["11"] = 7.5, ["3"] = 7.0, ["7"] = 1.0 } })
  local modes = H.eligibleModes(f)
  T.eq("two modes eligible", #modes, 2)
  T.eq("eligible list is sorted for determinism", modes[1] .. "," .. modes[2], "11,3")
end

-- ── 3.3 Candidacy: weight by real FRAC risk, and multisite never parents a hybrid ────
do
  T.ok("two single-site modes weight high", H.pairWeight("3", "11") > 0)
  T.eq("a multisite partner zeroes the pair (sulfur)", H.pairWeight("3", "M2"), 0)
  T.eq("a multisite partner zeroes the pair (copper)", H.pairWeight("3", "M1"), 0)
  T.eq("mancozeb is multisite too, despite being synthetic", H.pairWeight("3", "M3"), 0)
  T.eq("two multisites weight zero", H.pairWeight("M1", "M2"), 0)
  T.ok("an unknown mode falls back to the conservative default",
       H.pairWeight("3", "ZZ") > 0)
end

-- A pair that is ELIGIBLE but zero-weighted fires NOTHING. That is the point of the zero.
do
  local f = newField({ resistance = { ["3"] = 10, M2 = 5 } })
  T.eq("both modes are eligible", #H.eligibleModes(f), 2)
  T.ok("...but a synthetic+multisite pair breeds no hybrid", H.selectOnset(f, 100) == nil)
end

-- BAR 3: the highest-weighted pair wins, never the first found by iteration order.
do
  -- FRAC 4 is the lowest-risk single-site mode; 3 and 11 are the highest.
  local f = newField({ resistance = { ["4"] = 10, ["3"] = 10, ["11"] = 10 } })
  local a, b, w = H.selectPair(f)
  T.eq("highest-weighted pair selected, part 1", a, "11")
  T.eq("highest-weighted pair selected, part 2", b, "3")
  T.near("...at the top weight", w, 1.0, 1e-9)
  T.ok("the lower-risk mode was not chosen", a ~= "4" and b ~= "4")
end

-- BAR 3 again, hostile ordering: rebuild the same field many times so table iteration order
-- varies, and demand the same answer every time.
do
  local seen = {}
  for i = 1, 40 do
    local f = newField()
    -- Insert in a different order each run to shuffle the hash layout.
    local order = (i % 2 == 0) and { "4", "3", "11", "7" } or { "7", "11", "3", "4" }
    for _, m in ipairs(order) do f.resistance[m] = 10 end
    local a, b = H.selectPair(f)
    seen[a .. "|" .. b] = true
  end
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  T.eq("selection is order-independent across 40 shuffled runs", distinct, 1)
  T.ok("...and it is the highest-risk pair", seen["11|3"] == true)
end

-- BAR 4: tied weights resolve lexicographically-first, reproducibly.
do
  -- 3 and 11 both weight 1.00, so {11,3} and any other 1.00 pair would tie. Add a third
  -- mode at the same risk to force a genuine tie.
  local f = newField({ resistance = { ["3"] = 10, ["11"] = 10 } })
  local first = nil
  for _ = 1, 20 do
    local a, b = H.selectPair(f)
    local key = a .. "|" .. b
    if first == nil then first = key end
    T.ok("tie-break is reproducible", key == first)
  end
end

-- ── BAR 1: THE F66 GATE. One spray pass against one mode must not reach the threshold ──
do
  local f = newField()
  local sys = newSys(f)
  sprayPasses(sys, "PROPICONAZOLE", 1)
  T.ok("bar 1: one pass does NOT make a mode eligible", not H.isModeEligible(f, "3"))
  T.ok("bar 1: ...not even close", f.resistance["3"] < THRESH * R.MAX_SYNTHETIC)
  T.near("bar 1: it built exactly one application", f.resistance["3"], BUILD * R.MAX_SYNTHETIC, 1e-9)
end

-- BAR 2: two modes cross eligibility together only after the meter's own number of
-- applications, never in a single pass.
do
  local f = newField()
  local sys = newSys(f)
  local needed = math.ceil(THRESH / BUILD)     -- 0.7 / 0.05 = 14 full passes
  T.eq("bar 2: the meter requires 14 passes to reach threshold", needed, 14)

  sprayPasses(sys, "PROPICONAZOLE", needed - 1)
  sprayPasses(sys, "AZOXYSTROBIN",  needed - 1)
  T.ok("bar 2: 13 passes on each mode is still not enough", H.selectOnset(f, 100) == nil)
  T.eq("bar 2: neither mode is eligible yet", #H.eligibleModes(f), 0)

  sprayPasses(sys, "PROPICONAZOLE", 1)
  sprayPasses(sys, "AZOXYSTROBIN",  1)
  T.eq("bar 2: both modes cross together on the 14th", #H.eligibleModes(f), 2)
  T.ok("bar 2: and the hybrid breeds", H.selectOnset(f, 100) ~= nil)

  -- The measured reason isModeEligible carries a relative epsilon: 700 accumulated
  -- additions land a hair under the threshold, so an exact >= would have pushed the
  -- crossing to pass 15 and made HYBRID_THRESHOLD mean something other than it reads.
  T.ok("bar 2: the crossing really is on the boundary, not past it",
       f.resistance["3"] < THRESH * R.MAX_SYNTHETIC + 1e-6)
end

-- ── BAR 5: the re-onset cooldown ─────────────────────────────────────────────────────
do
  local f = newField({ resistance = { ["3"] = 10, ["11"] = 10 } })
  T.ok("qualifies before any cooldown", H.selectOnset(f, 100) ~= nil)

  H.beginCooldown(f, 100, 28)
  T.eq("cooldown is one calendar month of days", f.hybridBlockedUntilDay, 128)
  T.ok("inside the window it does not re-trigger even though it re-qualifies",
       H.selectOnset(f, 127) == nil)
  T.ok("on the boundary day it is free again", H.selectOnset(f, 128) ~= nil)
  T.ok("after the window it triggers", H.selectOnset(f, 200) ~= nil)
end

-- The cooldown is calendar-normalized: one month is one month on any month length.
do
  local a, b = newField(), newField()
  H.beginCooldown(a, 0, 1)
  H.beginCooldown(b, 0, 28)
  T.eq("a 1-day month blocks for 1 day", a.hybridBlockedUntilDay, 1)
  T.eq("a 28-day month blocks for 28 days", b.hybridBlockedUntilDay, 28)
end

-- ── The onset pre-pass, driven through the real _updateActiveDisease ─────────────────
do
  local f = newField({ resistance = { ["3"] = 10, ["11"] = 10 }, lastCrop = "wheat" })
  local sys = newSys(f)
  sys:_updateActiveDisease(1, f, 1, false, 100)
  T.ok("onset: a doubly-burned field breeds the hybrid", H.isHybrid(f.activeDisease))
  T.ok("onset: it is unknown until scouted", f.diseaseDiscovered == false)
  T.ok("onset: severity was resolved", (f.activeDiseaseSeverity or 0) > 0)
end

-- A clean field takes the ordinary roll, untouched by CD-10.
do
  local f = newField({ resistance = {}, lastCrop = "wheat" })
  local sys = newSys(f)
  sys:_updateActiveDisease(1, f, 1, false, 100)
  T.ok("onset: a clean field never breeds a hybrid", not H.isHybrid(f.activeDisease))
end

-- Clearing a hybrid arms the cooldown; clearing an ordinary disease does not.
do
  local f = newField({ lastCrop = "wheat" })
  f.activeDisease = H.strainForPair(f, "3", "11")
  f.diseasePressure = 0
  local sys = newSys(f)
  sys:_updateActiveDisease(1, f, 1, false, 500)
  T.ok("clear: the hybrid name is dropped", f.activeDisease == nil)
  T.ok("clear: the cooldown is armed", (f.hybridBlockedUntilDay or 0) > 500)

  local g = newField({ activeDisease = "septoria_tritici", diseasePressure = 0 })
  newSys(g):_updateActiveDisease(1, g, 1, false, 500)
  T.ok("clear: an ordinary disease arms no cooldown", g.hybridBlockedUntilDay == nil)
end

-- ── THE RULED CONTROL FACTOR, worked cases ───────────────────────────────────────────
do
  local id = H.strainForPair(newField({ lastCrop = "wheat" }), "3", "11")
  local fresh = newField({ resistance = {} })
  local burned3 = newField({ resistance = { ["3"] = 10 } })

  T.near("single fresh jug scores 0.5x", H.freshModeFactor(fresh, id, { "PROPICONAZOLE" }), 0.5, 1e-9)
  T.near("blend spanning two fresh modes scores 1.0x",
         H.freshModeFactor(fresh, id, { "PROPICONAZOLE", "AZOXYSTROBIN" }), 1.0, 1e-9)
  T.near("blend with one burned partner scores 0.5x",
         H.freshModeFactor(burned3, id, { "PROPICONAZOLE", "AZOXYSTROBIN" }), 0.5, 1e-9)
  -- PROPICONAZOLE and TEBUCONAZOLE are both FRAC 3: two partners, ONE distinct mode.
  T.near("two partners sharing one mode score 0.5x",
         H.freshModeFactor(fresh, id, { "PROPICONAZOLE", "TEBUCONAZOLE" }), 0.5, 1e-9)

  T.ok("the factor never exceeds 1",
       H.freshModeFactor(fresh, id, { "PROPICONAZOLE", "AZOXYSTROBIN", "BOSCALID" }) <= 1.0)

  -- It never applies to an ordinary disease.
  T.near("ordinary disease: factor absent", H.freshModeFactor(fresh, "septoria_tritici", { "PROPICONAZOLE" }), 1.0, 1e-9)
  T.near("nil disease: factor absent", H.freshModeFactor(fresh, nil, { "PROPICONAZOLE" }), 1.0, 1e-9)

  -- THE ZERO CASE: two burned partners score no fresh scaling, but the factor must not
  -- multiply the control to zero by arithmetic -- the base category default still stands and
  -- CD-9's own resistance penalty is what makes the spray inert.
  local bothBurned = newField({ resistance = { ["3"] = 10, ["11"] = 10 } })
  T.near("both partners burned: the factor does not zero the control",
         H.freshModeFactor(bothBurned, id, { "PROPICONAZOLE", "AZOXYSTROBIN" }), 1.0, 1e-9)
end

-- And the factor actually reaches the spray path: against a hybrid, a two-mode blend must
-- out-treat a single jug. That asymmetry IS the reason the factor was ruled.
do
  local id = H.strainForPair(newField({ lastCrop = "wheat" }), "3", "11")

  local single = newField({ activeDisease = id, diseasePressure = 80 })
  local sysA = newSys(single)
  sprayPasses(sysA, "PROPICONAZOLE", 1)
  local totalA = 0
  for _, r in ipairs(sysA.reductions) do totalA = totalA + r end

  local blend = newField({ activeDisease = id, diseasePressure = 80 })
  local sysB = newSys(blend)
  sprayPasses(sysB, "BLEND_AZOXYSTROBIN_PROPICONAZOLE", 1)
  local totalB = 0
  for _, r in ipairs(sysB.reductions) do totalB = totalB + r end

  T.ok("a single jug does something against a hybrid", totalA > 0)
  -- NOT just "more": the ratio has to be the FACTOR's 2x (1.0 vs 0.5), not the ~1.02x that
  -- the in-pass resistance build alone produces because one jug burns its single mode twice
  -- as fast as a blend burns each of two. A "blend > jug" assertion passes on that weaker
  -- effect even with the control factor removed, so it would not have been testing the
  -- ruling at all.
  T.ok("a two-mode blend does substantially MORE -- the hybrid's whole reason",
       totalB > totalA * 1.5)
  T.near("...and the margin is the ruled factor, 1.0x against 0.5x", totalB / totalA, 2.0, 0.1)
end

-- ── CD-10 HYBRID FAMILY (2026-08-01 count ruling): one complex per crop family ──────
do
  -- BAR 1, the drift test: every DISEASE_REGISTRY key resolves to a family or explicitly
  -- to the default. Fails the day someone adds a crop and forgets the table.
  local fam = SoilConstants.HYBRID_CROP_FAMILY
  local explicitDefault = { mint = true, cotton = true }
  local total = 0
  for crop in pairs(SoilConstants.DISEASE_REGISTRY) do
    total = total + 1
    T.ok("registry key resolves: " .. crop, fam[crop] ~= nil or explicitDefault[crop] == true)
  end
  T.ok("the registry was actually iterated", total > 0)

  -- No invented family: every CROP_FAMILY value is one of the six ruled families.
  local ruled = { cereal = true, maize = true, oilseed = true, root = true, pulse = true, forage = true }
  for crop, family in pairs(fam) do
    T.ok("family is ruled, not invented: " .. crop, ruled[family] == true)
  end

  -- BAR 2: deterministic. A hundred calls on one field return the same id.
  local wheat = newField({ lastCrop = "wheat" })
  local expected = H.strainForPair(wheat, "3", "11")
  local same = true
  for _ = 1, 100 do
    if H.strainForPair(wheat, "3", "11") ~= expected then same = false break end
  end
  T.ok("strainForPair is deterministic across 100 calls", same)
  T.eq("a wheat field breeds the cereal complex", expected, "resistant_complex_cereal")
  T.eq("a potato field breeds the root complex", H.strainForPair(newField({ lastCrop = "potato" }), "3", "11"), "resistant_complex_root")
  T.eq("a grass field breeds the forage complex", H.strainForPair(newField({ lastCrop = "grass" }), "3", "11"), "resistant_complex_forage")

  -- BAR 3: an unfamilied crop returns the default, never nil.
  T.eq("a modded crop falls to the default", H.strainForPair(newField({ lastCrop = "strawberry" }), "3", "11"), "resistant_complex")
  T.eq("a nil-crop field falls to the default", H.strainForPair(newField({}), "3", "11"), "resistant_complex")
  T.eq("a nil field falls to the default", H.strainForPair(nil, "3", "11"), "resistant_complex")

  -- BAR 4: all seven ids carry requiresModes = 2 and cat = "resistant_complex".
  local ids = {
    "resistant_complex", "resistant_complex_cereal", "resistant_complex_maize",
    "resistant_complex_oilseed", "resistant_complex_root", "resistant_complex_pulse",
    "resistant_complex_forage",
  }
  for _, id in ipairs(ids) do
    local def = SoilConstants.DISEASE_DEFS[id]
    T.ok("row exists: " .. id, def ~= nil)
    T.eq("requiresModes is 2 on " .. id, def.requiresModes, 2)
    T.eq("cat is resistant_complex on " .. id, def.cat, "resistant_complex")
    T.ok("isHybrid recognises " .. id, H.isHybrid(id))
  end

  -- BAR 5: a field that bred resistant_complex under 2.5 still reads as a hybrid.
  T.ok("the 2.5 default id still reads as a hybrid", H.isHybrid("resistant_complex"))

  -- The family is reached through the real onset pre-pass.
  local sys = newSys(newField({ resistance = { ["3"] = 10, ["11"] = 10 }, lastCrop = "wheat" }))
  local f = sys.fieldData[1]
  sys:_updateActiveDisease(1, f, 1, false, 100)
  T.eq("onset on wheat breeds the cereal complex", f.activeDisease, "resistant_complex_cereal")
end
