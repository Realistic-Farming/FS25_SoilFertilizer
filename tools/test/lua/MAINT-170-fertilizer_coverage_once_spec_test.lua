-- MAINT-170-fertilizer_coverage_once_spec_test.lua: MAINTENANCE row 170, a fertilizer
-- pass counts its coverage once, and only when the credit succeeds (RSF-F196 V7).
--
-- The sprayer hook's pre-loop coverage track took updateFractions from
-- `(not isFertilizer) or (isFertilizer and _hasCropProt)`. For a plain fertilizer that is
-- nil, not false; for a profile-plus-protection product (SF's INSECTICIDE and FUNGICIDE)
-- it is truthy. Either way trackSprayerCoverage counted the litres there, before the
-- credit, and the post-credit litre track on a rig with no VWW sections counted them
-- again: Pass % ran double. And because that count came before the credit, a pass the V7
-- result gate refuses still gained litre coverage, against DESIGN-CHECK row 70's clause
-- "litre coverage requires result == true". The expression is now `not isFertilizer`.
--
-- ENTRY-POINT BAR: every pass runs through the real installSprayerAreaHook into the real
-- SoilFertilitySystem on the row-166 world (which hands the soil system the same
-- HookManager, as SoilFertilitySystem.new does). Expected values derive from
-- SPRAYER_RATE.BASE_RATES, the rates the code reads. One 10 L tick on 1.0 ha.
--
--   F   FERTILIZER on the litres path: 10 / 225 once
--   I   SF's INSECTICIDE (a fertilizer profile, applyFertilizer's pest branch): 10 / 100 once
--   P   PROPICONAZOLE (not a profile, the direct route): still counted, 10 / 100 (#753)
--   V   a pass the V7 gate refuses counts no coverage. The refusal is written by the real
--       registration (registerCustomSprayTypes refuses a dry product whose massPerLiter
--       is unusable), and the real onFertilizerApplied refuses it. As in the V7 bar's
--       group B, only the area hook is installed, so R2's first fence is down: the case
--       V7 exists for.
--   W   FERTILIZER on a VWW rig: cells 1/2/3 as before, and the first tick adds no litres
--
-- Targeted mutations: restore the old expression (F, I, V and W fail); make it
-- `(not isFertilizer) or (_hasCropProt ~= nil)` (only I fails: the dual-purpose half is
-- pinned on its own); make it false (P fails).
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group
local BR = SoilConstants.SPRAYER_RATE.BASE_RATES
local function near(a, b) return math.abs(a - b) < 1e-9 end

local function oneTick(product, opts)
  opts = opts or {}
  local w = PSW.new({ product = product, noVww = opts.vww ~= true, areaHa = 1.0 })
  if opts.before then opts.before(w) end
  w:tick(10, w:cells(1, 1))
  return w, w:field()
end

group("F fertilizer", function()
  local _, f = oneTick("FERTILIZER")
  T.ok("F1 NAMED: one FERTILIZER tick on the litres path counts 10 L / 225 L/ha once", near(f.sessionCoverageHa or 0, 10 / BR.FERTILIZER.value))
end)

group("I dual-purpose", function()
  local w, f = oneTick("INSECTICIDE")
  T.ok("I0 [reached: SF's INSECTICIDE took applyFertilizer's pest branch]", w.sys.insecticideDailyApplied ~= nil and w.sys.insecticideDailyApplied[7] ~= nil)
  T.ok("I1 NAMED: one SF INSECTICIDE tick counts 10 L / 100 L/ha once", near(f.sessionCoverageHa or 0, 10 / BR.INSECTICIDE.value))
end)

group("P non-profile protection", function()
  local w, f = oneTick("PROPICONAZOLE")
  T.ok("P0 [reached: PROPICONAZOLE took the direct fungicide route]", w.sys.fungicideDailyApplied ~= nil and w.sys.fungicideDailyApplied[7] ~= nil)
  T.ok("P1 NAMED: one PROPICONAZOLE tick still counts 10 L / 100 L/ha (the #753 case)", near(f.sessionCoverageHa or 0, 10 / BR.PROPICONAZOLE.value))
end)

group("V refused pass", function()
  -- A custom dry product whose declared density is unusable (0): registration refuses it.
  PSW.FT.UREA = { name = "UREA", index = 77, massPerLiter = 0 }
  local savedStm = g_sprayTypeManager
  g_sprayTypeManager = {
    added = {},
    getSprayTypeByName = function(_, n)
      if n == "LIQUIDFERTILIZER" or n == "FERTILIZER" or n == "LIME" or n == "FUNGICIDE" then
        return { litersPerSecond = 0.0081, sprayGroundType = 1 }
      end
      return nil
    end,
    getSprayTypeByFillTypeIndex = function() return nil end,
    addSprayType = function(self, name) self.added[#self.added + 1] = name end,
  }
  local w, f = oneTick("UREA", { before = function(world) world.hookMgr:registerCustomSprayTypes() end })
  T.eq("V0 [reached: the real registration refused UREA for its density]", w.hookMgr.refusedProducts[77], "density")
  T.eq("V1 [reached: the real onFertilizerApplied refused the pass before the nutrient buffer]", f.nutrientBuffer ~= nil and f.nutrientBuffer[77] or nil, nil)
  T.eq("V2 NAMED: a pass the V7 gate refuses counts no coverage", f.sessionCoverageHa or 0, 0)
  g_sprayTypeManager = savedStm
  PSW.FT.UREA = nil
end)

group("W VWW control", function()
  local w = PSW.new({ product = "FERTILIZER", areaHa = 1.0 })
  local cells, ha = {}, {}
  for i = 1, 3 do
    w:tick(10, w:cells(i, i))
    local n = 0
    for _ in pairs(w:field().sessionCoverageCells or {}) do n = n + 1 end
    cells[i], ha[i] = n, w:field().sessionCoverageHa or 0
  end
  T.eq("W1 FERTILIZER on a VWW rig still marks cells 1/2/3", cells[1] .. "/" .. cells[2] .. "/" .. cells[3], "1/2/3")
  T.ok("W2 NAMED: its first tick adds no litres, only its one cell", near(ha[1], SoilConstants.ZONE.CELL_AREA_HA))
end)

PSW.restore()
