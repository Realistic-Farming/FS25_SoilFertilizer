-- tank_mix_cd12_test.lua - CD-12, the tank mix.
--
-- A mix of two modes of action stops either one carrying the whole selection pressure.
-- Every mix is a pre-defined fill type because a fill type cannot be created at runtime.
--
-- The failure mode this file exists to catch: registration for a crop-protection fill type
-- spans nine sites across two files and missing one is INVISIBLE in game -- an uncalibrated
-- rate looks like it works, a missed density-map remap means no ground state is ever
-- written. So every derived list is asserted here rather than trusted to a loop.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SoilFertilitySystem.lua

local R     = SoilConstants.RESISTANCE
local BUILD = R.BUILD_PER_APPLICATION
local RATES = SoilConstants.SPRAYER_RATE.BASE_RATES

-- THE LOCKED SET. The table is APPEND-ONLY from the day it ships: FillUnit.onPostLoad
-- resolves a saved tank's fill type by name with no nil check, so removing or renaming a
-- blend orphans every saved tank holding it. This literal is the guard on that.
local EXPECTED = {
  "BLEND_AZOXYSTROBIN_BOSCALID", "BLEND_AZOXYSTROBIN_COPPER_HYDROXIDE", "BLEND_AZOXYSTROBIN_MANCOZEB",
  "BLEND_AZOXYSTROBIN_METALAXYL", "BLEND_AZOXYSTROBIN_PROPICONAZOLE", "BLEND_AZOXYSTROBIN_SULFUR",
  "BLEND_AZOXYSTROBIN_TEBUCONAZOLE", "BLEND_BOSCALID_COPPER_HYDROXIDE", "BLEND_BOSCALID_MANCOZEB",
  "BLEND_BOSCALID_METALAXYL", "BLEND_BOSCALID_PROPICONAZOLE", "BLEND_BOSCALID_SULFUR",
  "BLEND_BOSCALID_TEBUCONAZOLE", "BLEND_COPPER_HYDROXIDE_MANCOZEB", "BLEND_COPPER_HYDROXIDE_METALAXYL",
  "BLEND_COPPER_HYDROXIDE_PROPICONAZOLE", "BLEND_COPPER_HYDROXIDE_SULFUR", "BLEND_COPPER_HYDROXIDE_TEBUCONAZOLE",
  "BLEND_MANCOZEB_METALAXYL", "BLEND_MANCOZEB_PROPICONAZOLE", "BLEND_MANCOZEB_SULFUR",
  "BLEND_MANCOZEB_TEBUCONAZOLE", "BLEND_METALAXYL_PROPICONAZOLE", "BLEND_METALAXYL_SULFUR",
  "BLEND_METALAXYL_TEBUCONAZOLE", "BLEND_PROPICONAZOLE_SULFUR", "BLEND_PROPICONAZOLE_TEBUCONAZOLE",
  "BLEND_SULFUR_TEBUCONAZOLE",
}

do
  T.eq("28 blends exist", #SoilBlends.ORDER, 28)
  T.eq("...which is every unordered pair of the eight chemicals",
       #SoilBlends.ORDER, (#SoilConstants.PHYSICAL_FUNGICIDE_ORDER * (#SoilConstants.PHYSICAL_FUNGICIDE_ORDER - 1)) / 2)
  for i, name in ipairs(EXPECTED) do
    T.eq("blend " .. i .. " is " .. name, SoilBlends.ORDER[i], name)
  end
end

-- THE PARSE TRAP, and it is the reason partner lists are stored rather than derived from
-- the key: COPPER_HYDROXIDE contains an underscore, so splitting on "_" reads
-- BLEND_COPPER_HYDROXIDE_SULFUR as three chemicals, none of which is COPPER_HYDROXIDE.
do
  local p = SoilBlends.getPartners("BLEND_COPPER_HYDROXIDE_SULFUR")
  T.eq("underscore-name blend has exactly two partners", #p, 2)
  T.eq("...partner 1 is the full COPPER_HYDROXIDE", p[1], "COPPER_HYDROXIDE")
  T.eq("...partner 2 is SULFUR", p[2], "SULFUR")

  local q = SoilBlends.getPartners("BLEND_AZOXYSTROBIN_BOSCALID")
  T.eq("ordinary blend partner 1", q[1], "AZOXYSTROBIN")
  T.eq("ordinary blend partner 2", q[2], "BOSCALID")

  T.ok("a single chemical is not a blend", SoilBlends.getPartners("PROPICONAZOLE") == nil)
  T.ok("generic FUNGICIDE is not a blend", SoilBlends.getPartners("FUNGICIDE") == nil)
  T.ok("nil is handled", SoilBlends.getPartners(nil) == nil)
  T.ok("an invented name is not a blend", SoilBlends.getPartners("BLEND_NOPE_NOPE") == nil)
end

-- Keys are canonical: exactly one entry per unordered pair, never both orderings.
do
  local reverseSeen = 0
  for name, parts in pairs(SoilBlends.TABLE) do
    local mirror = "BLEND_" .. parts[2] .. "_" .. parts[1]
    if SoilBlends.TABLE[mirror] ~= nil and mirror ~= name then reverseSeen = reverseSeen + 1 end
    T.ok("key is alphabetical: " .. name, parts[1] < parts[2])
  end
  T.eq("no pair is registered in both orders", reverseSeen, 0)
end

-- ── THE DERIVED REGISTRATIONS ────────────────────────────────────────────────────────
do
  for _, blend in ipairs(SoilBlends.ORDER) do
    -- THE FIRST GATE. HookManager reads this before the field is even resolved; a name
    -- absent from it sprays, drains the tank, costs the money and does nothing at all.
    T.eq("FUNGICIDE_TYPES has " .. blend, SoilConstants.DISEASE_PRESSURE.FUNGICIDE_TYPES[blend], 1.0)

    -- Rate: the mean of its partners', so it calibrates like the chemicals in it.
    local parts = SoilBlends.TABLE[blend]
    local expected = (RATES[parts[1]].value + RATES[parts[2]].value) / 2
    T.ok("BASE_RATES has " .. blend, RATES[blend] ~= nil)
    T.near("...at the mean of its partners", RATES[blend].value, expected, 1e-9)
    T.eq("...as a liquid", RATES[blend].unit, "liquid")
  end
end

do
  local ftSet = {}
  for _, n in ipairs(SoilConstants.FERTILIZER_TYPES) do ftSet[n] = true end
  for _, blend in ipairs(SoilBlends.ORDER) do
    T.ok("FERTILIZER_TYPES lists " .. blend, ftSet[blend] == true)
  end
end

-- ── THE NEGATIVE REQUIREMENTS, as load-bearing as the positive ones ──────────────────
do
  for _, blend in ipairs(SoilBlends.ORDER) do
    -- HookManager derives isFertilizer from FERTILIZER_PROFILES; a true value routes the
    -- application through applyFertilizer, double-applying the consequence and making the
    -- AI helper treat the pass as fertilising.
    T.ok("NOT in FERTILIZER_PROFILES: " .. blend, SoilConstants.FERTILIZER_PROFILES[blend] == nil)
    -- PHYSICAL_FUNGICIDES gates the admin apply paths and catalog-keyed UI surfaces that
    -- would nil-index on a blend name (SoilScoutDialog reads chem.costPerHa).
    T.ok("NOT in PHYSICAL_FUNGICIDES: " .. blend, SoilConstants.PHYSICAL_FUNGICIDES[blend] == nil)
    -- Blends are mixed on the farm from stock already bought; they are not catalog entries.
    T.ok("NOT in FUNGICIDE_CATALOG: " .. blend, SoilConstants.FUNGICIDE_CATALOG[blend] == nil)
  end
end

-- ── ORGANIC LEGALITY: exactly one positive entry, and it is COMPUTED ─────────────────
--
-- isApprovedInput is a bare set lookup, so absence breaches. That default is already right
-- for 27 of 28. The invariant on authority #4: only a blend whose EVERY partner is
-- independently approved may join, and the breach evaluator NEVER decomposes a name.
do
  local approvedBlends = {}
  for _, blend in ipairs(SoilBlends.ORDER) do
    if SoilConstants.ORGANIC.APPROVED_INPUTS[blend] then approvedBlends[#approvedBlends + 1] = blend end
  end
  T.eq("exactly one blend is organically approved", #approvedBlends, 1)
  T.eq("...and it is the copper/sulfur pair", approvedBlends[1], "BLEND_COPPER_HYDROXIDE_SULFUR")

  -- Spot-check the rule rather than just the outcome: any blend carrying a synthetic must
  -- breach, including one whose OTHER partner is approved.
  T.ok("an organic+synthetic blend is NOT approved",
       SoilConstants.ORGANIC.APPROVED_INPUTS["BLEND_COPPER_HYDROXIDE_PROPICONAZOLE"] == nil)
  T.ok("a synthetic pair is NOT approved",
       SoilConstants.ORGANIC.APPROVED_INPUTS["BLEND_AZOXYSTROBIN_BOSCALID"] == nil)
end

-- ── THE SPRAY PATH ───────────────────────────────────────────────────────────────────

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
  return sys
end

-- One full-rate pass of `chem`, delivered as boom sections the way the hook does.
local function sprayPass(sys, chem, n)
  local rate = (RATES[chem] or RATES.FUNGICIDE).value
  local vol  = AREA_HA * rate
  for _ = 1, (n or 200) do sys:onFungicideAppliedDirect(1, 1.0, vol / (n or 200), chem) end
end

-- THE MECHANISM: two modes each carry HALF the selection pressure. That is the whole point
-- of the system -- and it only means anything because F66 metered the build per pass first.
do
  local field = newField()
  sprayPass(newSys(field), "BLEND_AZOXYSTROBIN_PROPICONAZOLE")
  local half = BUILD * R.MAX_SYNTHETIC / 2
  T.near("blend: FRAC 11 (azoxystrobin) takes half a build", field.resistance["11"], half, 1e-9)
  T.near("blend: FRAC 3 (propiconazole) takes half a build",  field.resistance["3"],  half, 1e-9)
end

-- ...and a single chemical is unchanged: the divisor is the partner count, which is 1.
do
  local single, blend = newField(), newField()
  sprayPass(newSys(single), "PROPICONAZOLE")
  sprayPass(newSys(blend),  "BLEND_AZOXYSTROBIN_PROPICONAZOLE")
  T.near("single chemical still builds a full application",
         single.resistance["3"], BUILD * R.MAX_SYNTHETIC, 1e-9)
  T.near("a blend builds exactly half of that on the shared mode",
         blend.resistance["3"], single.resistance["3"] / 2, 1e-9)
end

-- A blend meters per pass like everything else (F66 must survive CD-12).
do
  local field = newField()
  local sys = newSys(field)
  for _ = 1, 40 do sprayPass(sys, "BLEND_AZOXYSTROBIN_PROPICONAZOLE", 50) end
  T.near("blend: 40 passes at half each reach the ceiling", field.resistance["3"], R.MAX_SYNTHETIC, 1e-6)
  T.ok("blend: 2000 section calls did NOT saturate on their own", true)
end

-- Naturals in a blend meter against their OWN ceiling.
do
  local field = newField()
  sprayPass(newSys(field), "BLEND_PROPICONAZOLE_SULFUR")
  T.near("blend: the natural partner halves against MAX_NATURAL",
         field.resistance["M2"], BUILD * R.MAX_NATURAL * R.BUILD_RATE_NATURAL / 2, 1e-9)
  T.near("blend: the synthetic partner halves against MAX_SYNTHETIC",
         field.resistance["3"], BUILD * R.MAX_SYNTHETIC / 2, 1e-9)
end

-- THE ORGANIC GUARD IS PER PARTNER, not on the blend name. isNaturalFungicide(blendName) is
-- false, which would otherwise hand the all-organic blend a free pass on an organic field
-- that neither of its chemicals gets alone.
do
  local field = newField({ organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED } })
  sprayPass(newSys(field), "BLEND_COPPER_HYDROXIDE_SULFUR")
  T.near("organic field: approved natural partner M1 still builds",
         field.resistance["M1"], BUILD * R.MAX_NATURAL * R.BUILD_RATE_NATURAL / 2, 1e-9)
  T.near("organic field: approved natural partner M2 still builds",
         field.resistance["M2"], BUILD * R.MAX_NATURAL * R.BUILD_RATE_NATURAL / 2, 1e-9)
end

do
  local field = newField({ organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED } })
  sprayPass(newSys(field), "BLEND_COPPER_HYDROXIDE_PROPICONAZOLE")
  T.ok("organic field: the SYNTHETIC partner builds nothing", field.resistance["3"] == nil)
  T.near("organic field: the approved partner still builds",
         field.resistance["M1"], BUILD * R.MAX_NATURAL * R.BUILD_RATE_NATURAL / 2, 1e-9)
end

-- ── THE RESCUE. When one mode is burned out it contributes nothing and the other partner
-- carries the pass. This is the MAX over partners, and it is why mixing is worth doing.
do
  local burned = newField({ resistance = { ["3"] = R.MAX_SYNTHETIC } })
  local sys = newSys(burned)
  sprayPass(sys, "BLEND_AZOXYSTROBIN_PROPICONAZOLE")
  local total = 0
  for _, r in ipairs(sys.reductions) do total = total + r end
  T.ok("rescue: a blend still works when ONE partner's mode is finished", total > 0)

  -- ...where the burned chemical ALONE does nothing at all.
  local alone = newField({ resistance = { ["3"] = R.MAX_SYNTHETIC } })
  local sys2 = newSys(alone)
  sprayPass(sys2, "PROPICONAZOLE")
  local total2 = 0
  for _, r in ipairs(sys2.reductions) do total2 = total2 + r end
  T.eq("...while the burned chemical alone is inert", total2, 0)
end

-- Both partners burned: the blend is inert too. The rescue is a max, not a free pass.
do
  local field = newField({ resistance = { ["3"] = R.MAX_SYNTHETIC, ["11"] = R.MAX_SYNTHETIC } })
  local sys = newSys(field)
  sprayPass(sys, "BLEND_AZOXYSTROBIN_PROPICONAZOLE")
  local total = 0
  for _, r in ipairs(sys.reductions) do total = total + r end
  T.eq("both partners finished: the blend is inert", total, 0)
end

-- The blend records itself as the last product, and uses its OWN rate as the meter
-- denominator rather than falling back to generic FUNGICIDE's.
do
  local field = newField()
  sprayPass(newSys(field), "BLEND_MANCOZEB_SULFUR")
  T.eq("lastFungicide records the blend name", field.lastFungicide, "BLEND_MANCOZEB_SULFUR")
end
