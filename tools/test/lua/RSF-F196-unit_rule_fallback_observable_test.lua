-- RSF-F196-unit_rule_fallback_observable_test.lua: the unit rule's degradation paths
-- are observable, never silent (Bob, #976 cold review).
--
-- Every fallback in the unit rule converts by 1, and converting by 1 is the defect
-- #976 repaired. Production is safe by load order (HookManager before
-- SoilFertilitySystem and SoilHUD), but a future bar written without HookManager
-- that asserted a dry conversion through the wrapper would pass at factor 1 and
-- prove nothing. So each fallback records that it was taken, and this bar proves
-- three things: with HookManager present the counters never move; with it absent
-- they move exactly when the unconverted value is used; and a name the manager
-- cannot resolve is counted separately from passthrough by design.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ui/SoilHUD.lua

local BR  = SoilConstants.SPRAYER_RATE.BASE_RATES
local PF  = SoilConstants.FERTILIZER_PROFILES
local RR  = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[3]
local TUN = SoilConstants.TUNING.RATE_MULT[3]
local THR = SoilConstants.SPRAYER_RATE.FERTILIZER_COVERAGE_THRESHOLD or 0.90

local UREA = { name = "UREA", index = 50, massPerLiter = 0.00077 }
local savedFtm = g_fillTypeManager
g_fillTypeManager = { getFillTypeByIndex = function(_, i) if i == 50 then return UREA end end,
                      getFillTypeByName  = function(_, n) if n == "UREA" then return UREA end end }

local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings  = { enabled = true, replenishmentRate = 3, showNotifications = false }
  s.fieldData = { [1] = { fieldArea = 4.0, _farmlandAreaConfirmed = true, sessionCoverageCells = { seeded = true },
                          nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.5 } }
  return s
end
g_currentMission.time = 5000

-- ── the counters start untouched ──
T.eq("OBS 1: no system fallback has been recorded before anything ran", SoilFertilitySystem.unitRuleFallbacks, nil)
T.eq("OBS 2: no HUD fallback either", SoilHUD.unitRuleFallbacks, nil)
T.eq("OBS 3: no unresolved name either", SoilFertilitySystem.unitRuleUnresolvedNames, nil)

-- ── with HookManager present: a dry conversion, and the counters stay untouched ──
do
  local s = newSys(); local f = s.fieldData[1]
  local n0 = f.nitrogen
  s:applyFertilizer(1, 50, 40, nil)
  T.near("OBS 4: UREA converts by its density with HookManager present", f.nitrogen - n0, PF.UREA.N * (40 * 0.77 / 1000) / 4.0 * RR * TUN, 1e-9)
  T.eq("OBS 5: and the fallback counter did not move", SoilFertilitySystem.unitRuleFallbacks, nil)
  s:trackSprayerCoverage(1, 100, "UREA", true)
  T.eq("OBS 6: a name the manager resolves is not counted as unresolved", SoilFertilitySystem.unitRuleUnresolvedNames, nil)
end

-- ── with HookManager ABSENT: the value is unconverted AND the counter says so ──
do
  local savedHM = HookManager
  HookManager = nil
  local s = newSys(); local f = s.fieldData[1]
  local n0 = f.nitrogen
  local ok, err = pcall(s.applyFertilizer, s, 1, 50, 40, nil)
  HookManager = savedHM
  T.ok("OBS 7: applyFertilizer still runs without HookManager (" .. tostring(err) .. ")", ok)
  T.near("OBS 8: but converts by 1, the shape a silent fallback would hide", f.nitrogen - n0, PF.UREA.N * (40 / 1000) / 4.0 * RR * TUN, 1e-9)
  -- One applyFertilizer call reaches the wrapper TWICE: the nutrient factor and the
  -- fully-treated comparison. Both fallbacks are counted, so a bar cannot mistake
  -- "one site converted" for "both did".
  T.eq("OBS 9: and the fallback is RECORDED, once per site reached (the factor and the fully-treated comparison)", SoilFertilitySystem.unitRuleFallbacks, 2)
end

-- ── an unresolved name is counted, separately ──
do
  local s = newSys()
  local saved = g_fillTypeManager
  g_fillTypeManager = nil
  s:trackSprayerCoverage(1, 100, "UREA", true)
  g_fillTypeManager = saved
  T.eq("OBS 10: no manager to resolve the name: counted as unresolved", SoilFertilitySystem.unitRuleUnresolvedNames, 1)
  T.eq("OBS 11: and NOT as a system fallback (HookManager was present; the count is still the two from OBS 9)", SoilFertilitySystem.unitRuleFallbacks, 2)
  s:trackSprayerCoverage(1, 100, "NOT_A_FILL_TYPE", true)
  T.eq("OBS 12: a name the manager does not know: counted again", SoilFertilitySystem.unitRuleUnresolvedNames, 2)
end

-- ── the HUD guard ──
local function drawRow()
  local sg = { renderText = renderText, setTextAlignment = setTextAlignment, setTextColor = setTextColor, RenderText = RenderText,
               getTextWidth = getTextWidth, setTextBold = setTextBold, sfm = g_SoilFertilityManager, hud = g_currentMission.masterHUD }
  renderText = function() end; setTextAlignment = function() end; setTextColor = function() end
  setTextBold = function() end; getTextWidth = function() return 0.01 end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  g_SoilFertilityManager = { settings = { replenishmentRate = 3 } }
  local bars = {}
  g_currentMission.masterHUD = { renderer = { renderProgressBar = function(_r, x, y, w, h, fill, col, total) bars[#bars + 1] = { fill = fill, total = total }; return true end } }
  local hud = setmetatable({ scale = 1, fillOverlay = nil }, { __index = SoilHUD })
  local info = { nutrientBuffer = { [50] = 200 }, fieldArea = 2.0 }
  local ok, err = pcall(hud.drawNutrientRow, hud, "N", "N", { value = 50, status = "Fair" }, 0.1, 0.5, 0.3, 1, 1, info, PF.UREA, UREA, 1.0, nil)
  renderText, setTextAlignment, setTextColor, RenderText = sg.renderText, sg.setTextAlignment, sg.setTextColor, sg.RenderText
  getTextWidth, setTextBold, g_SoilFertilityManager, g_currentMission.masterHUD = sg.getTextWidth, sg.setTextBold, sg.sfm, sg.hud
  return ok, err, bars
end
local function ghostOf(bars) return bars[1].total - bars[1].fill end
do
  local ok, err, bars = drawRow()
  T.ok("OBS 13: the HUD row drew with HookManager present (" .. tostring(err) .. ")", ok)
  local remaining = math.max(0, 2.0 * BR.UREA.value * THR - 200 * 0.77)
  T.near("OBS 14: converted ghost", ghostOf(bars), math.min(0.5, PF.UREA.N * (remaining / 1000) / 2.0 * RR / 100), 1e-9)
  T.eq("OBS 15: and the HUD fallback counter did not move", SoilHUD.unitRuleFallbacks, nil)
end
do
  local savedHM = HookManager
  HookManager = nil
  local ok, err, bars = drawRow()
  HookManager = savedHM
  T.ok("OBS 16: the HUD row drew without HookManager (" .. tostring(err) .. ")", ok)
  local remaining = math.max(0, 2.0 * BR.UREA.value * THR - 200)
  T.near("OBS 17: unconverted ghost", ghostOf(bars), math.min(0.5, PF.UREA.N * (remaining / 1000) / 2.0 * RR / 100), 1e-9)
  T.eq("OBS 18: and the HUD fallback is RECORDED, once", SoilHUD.unitRuleFallbacks, 1)
end

g_fillTypeManager = savedFtm
