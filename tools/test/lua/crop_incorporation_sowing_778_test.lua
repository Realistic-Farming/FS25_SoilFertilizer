-- crop_incorporation_sowing_778_test.lua - #778 green-manure incorporation by direct drill.
--   A seeder that drills through a standing/dead cover crop (over-wintered oilseed radish,
--   failed crop, sod) works its biomass into the opener slot. The crop-biomass probe now
--   runs on SowingMachine and threads `cropBiomass` into onSowing, which awards the new
--   CROP_INCORPORATION.SOWING profile on top of the flat DIRECT_DRILL residue - exactly like
--   the tillage path stacks residue + incorporation. Awarded ONLY when the probe detected a
--   standing crop (biomass > 0) and the residueIncorporation setting is on.
--   The contract this bench locks: the SOWING profile calibration, the stacked-release total,
--   the bare-ground / stubble no-op, and the residue-only path when biomass is absent.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local CI   = SoilConstants.CROP_INCORPORATION
local RI   = SoilConstants.RESIDUE_INCORPORATION
local LIM  = SoilConstants.NUTRIENT_LIMITS

-- ── Constants contract: the SOWING profile sits between mulching and the flat residue ──
do
  T.ok("778: CROP_INCORPORATION.SOWING profile present", type(CI.SOWING) == "table")
  T.near("778: SOWING OM = 0.4", CI.SOWING.OM, 0.4)
  T.near("778: SOWING N = 2.0",  CI.SOWING.N,  2.0)
  T.near("778: SOWING P = 0.4",  CI.SOWING.P,  0.4)
  T.near("778: SOWING K = 1.2",  CI.SOWING.K,  1.2)
  T.ok("778: SOWING is smaller than mulching (no soil inversion)",
       CI.SOWING.N < CI.MULCHER.N and CI.SOWING.OM < CI.MULCHER.OM)
  T.ok("778: SOWING is larger than the flat DIRECT_DRILL residue (standing biomass)",
       CI.SOWING.N > RI.DIRECT_DRILL.N and CI.SOWING.OM > RI.DIRECT_DRILL.OM)
end

-- A soil system whose field already exists (no lazy-create / farmland lookup).
local function newSys(field)
  return setmetatable({
    fieldData   = { [1] = field },
    settings    = { residueIncorporation = true, weedPressure = false },
    vmAvailable = function() return false end,
  }, { __index = SoilFertilitySystem })
end

-- Full-field pass: factor = areaHa / fieldAreaHa = 1.0.
local function newField()
  return { organicMatter = 5.0, nitrogen = 50, phosphorus = 50, potassium = 50,
           pH = 6.8, fieldArea = 10.0 }
end

-- ── The fix: drilling a mature cover crop (biomass ~1) stacks residue + SOWING ──
do
  local field = newField()
  local sys = newSys(field)
  sys:onSowing(1, 10.0, nil, 1.0)   -- 10 ha of 10 ha, full biomass

  -- residue OM cap applies first, then incorporation adds on top
  local expOM = 5.0 + RI.DIRECT_DRILL.OM * 1.0 + CI.SOWING.OM * (1.0 * 1.0)
  T.near("778: OM = residue + SOWING incorporation", field.organicMatter, expOM, 1e-6)
  T.near("778: N = residue + SOWING incorporation", field.nitrogen,
         50 + RI.DIRECT_DRILL.N + CI.SOWING.N, 1e-6)
  T.near("778: P = residue + SOWING incorporation", field.phosphorus,
         50 + RI.DIRECT_DRILL.P + CI.SOWING.P, 1e-6)
  T.near("778: K = residue + SOWING incorporation", field.potassium,
         50 + RI.DIRECT_DRILL.K + CI.SOWING.K, 1e-6)
  -- calibration rationale: total N ≈ 2.6 per full field -> +8 ppm on the integer HUD (ppm.N=3)
  T.ok("778: total N release is clearly visible vs the bare-residue +2 ppm",
       (RI.DIRECT_DRILL.N + CI.SOWING.N) >= 2.5)
end

-- ── Biomass scales the incorporation (a sparse crop releases less) ──
do
  local field = newField()
  local sys = newSys(field)
  sys:onSowing(1, 10.0, nil, 0.5)
  T.near("778: incorporation scales by biomass (0.5)", field.nitrogen,
         50 + RI.DIRECT_DRILL.N + CI.SOWING.N * 0.5, 1e-6)
end

-- ── No standing biomass (bare ground / post-harvest stubble): residue only, no incorporation ──
do
  local field = newField()
  local sys = newSys(field)
  sys:onSowing(1, 10.0, nil, 0)     -- probe sampled UNKNOWN -> 0
  T.near("778: bare-ground drill stays residue-only (OM)", field.organicMatter,
         5.0 + RI.DIRECT_DRILL.OM, 1e-6)
  T.near("778: bare-ground drill stays residue-only (N)", field.nitrogen,
         50 + RI.DIRECT_DRILL.N, 1e-6)
end

-- ── No cropBiomass argument (legacy callers): identical to pre-#778 behaviour ──
do
  local field = newField()
  local sys = newSys(field)
  sys:onSowing(1, 10.0, nil)        -- old signature, biomass nil
  T.near("778: nil cropBiomass keeps the old residue-only path (OM)", field.organicMatter,
         5.0 + RI.DIRECT_DRILL.OM, 1e-6)
  T.near("778: nil cropBiomass keeps the old residue-only path (N)", field.nitrogen,
         50 + RI.DIRECT_DRILL.N, 1e-6)
end

-- ── residueIncorporation OFF disables both residue and incorporation ──
do
  local field = newField()
  local sys = newSys(field)
  sys.settings.residueIncorporation = false
  sys:onSowing(1, 10.0, nil, 1.0)
  T.near("778: residueIncorporation off applies nothing", field.nitrogen, 50, 1e-6)
  T.near("778: residueIncorporation off leaves OM untouched", field.organicMatter, 5.0, 1e-6)
end

-- ── Cap: a field already near NUTRIENT_LIMITS.MAX clamps, never overflows ──
do
  local field = newField(); field.nitrogen = LIM.MAX - 0.5
  local sys = newSys(field)
  sys:onSowing(1, 10.0, nil, 1.0)
  T.ok("778: N clamps at NUTRIENT_LIMITS.MAX", field.nitrogen <= LIM.MAX + 1e-9)
end
