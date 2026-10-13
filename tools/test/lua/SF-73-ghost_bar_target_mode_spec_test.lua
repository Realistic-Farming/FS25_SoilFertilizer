-- SF-73-ghost_bar_target_mode_spec_test.lua
--
-- Tyson's DAP report (2026-10-01, Bob's check BOB-CHECK-DAP-FIELD2-REFUSAL): the Soil HUD's
-- N/P/K ghost bar projected a P gain that SF-73's target plan had refused. The ghost bar
-- projects field area x BASE_RATES x the rate multiplier, less the buffer; it knows nothing
-- of the plan. SF-73 Implementation brief v1.1 section 7 (:89): "its old display cannot
-- stand in for a confirmed footprint result". So under target mode the ghost (and its
-- "(+N)" suffix) draws nothing; outside target mode it is unchanged. The honest footprint
-- surface is Wizard's slice (DESIGN-CHECK row 138, WITHHELD).
--
-- THE ENTRY-POINT BAR. The real SoilHUD (SoilHUD.new) runs its real update(), which reads
-- the sprayer the player sits in and caches the decision through the soil system's real
-- read: on the server and host TargetApplication:isTargetMode (the release gate through
-- ReleaseGate and the live settings, auto rate control, and the real SprayerRateManager's
-- AUTO mode); on a client the result received through the real TargetApplication:receive.
-- The row is then drawn by the real drawNutrientRow with the HUD's cached state, as draw()
-- does (SoilHUD.lua, the N/P/K rows). The fixture supplies the world only: the player in a
-- sprayer holding UREA, the field record, the settings switches. Layout (calculateHeight,
-- the field-detect timer) is set aside so update() reaches its cache block; it is not
-- under test.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SprayerRateManager.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ui/SoilHUD.lua

SoilLogger.debug = function() end
SoilLogger.info = function() end

local BR  = SoilConstants.SPRAYER_RATE.BASE_RATES
local PF  = SoilConstants.FERTILIZER_PROFILES
local RR  = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[3]
local THR = SoilConstants.SPRAYER_RATE.FERTILIZER_COVERAGE_THRESHOLD or 0.90

local UREA = { name = "UREA", index = 50, massPerLiter = 0.00077 }
FillType = FillType or { UNKNOWN = 0 }
g_fillTypeManager = { getFillTypeByIndex = function(_, i) if i == 50 then return UREA end end,
                      getFillTypeByName  = function(_, n) if n == "UREA" then return UREA end end }

-- The world: one field record, the player in a sprayer with UREA in its tank.
local FIELD = { fieldArea = 2.0, nutrientBuffer = { [50] = 200 } }
local function newSprayer(isServer)
  local v = { id = 4242, isServer = isServer, spec_sprayer = { workAreaParameters = { sprayFillType = 50 } } }
  v.rootVehicle = v
  v.getSprayerFillUnitIndex = function() return 1 end
  v.getFillUnitFillType = function() return 50 end
  v.getFillUnitLastValidFillType = function() return 50 end
  v.getFillUnitFillLevel = function() return 500 end
  return v
end

local W
local function world(opts)
  g_server = opts.server and {} or nil
  g_currentMission = { time = 10000 }
  local settings = { enabled = true, autoRateControl = true, replenishmentRate = 3, hudPosition = 1 }
  settings.allowsExperimentalSystems = function() return opts.experimental == true end
  local ss = setmetatable({ fieldData = {}, settings = settings }, { __index = SoilFertilitySystem })
  ss.targetApplication = TargetApplication.new(ss)
  local rm = SprayerRateManager.new()
  g_SoilFertilityManager = { settings = settings, soilSystem = ss, sprayerRateManager = rm }
  local sprayer = newSprayer(opts.server == true)
  if opts.auto then rm:setAutoMode(sprayer.id, true) end
  g_localPlayer = { getIsInVehicle = function() return true end, getCurrentVehicle = function() return sprayer end }
  local hud = SoilHUD.new(ss, settings)
  -- Layout, not under test: no field detect this frame, the height already sized, the
  -- position already applied, so update() runs straight to its cache block.
  hud.fieldDetectTimer = 0
  hud._heightDirty = false
  hud.lastHudPosition = settings.hudPosition
  W = { hud = hud, ss = ss, rm = rm, sprayer = sprayer, ta = ss.targetApplication }
  return W
end

-- Draw the N row as draw() does, with the HUD's cached state; capture the bar and the text.
local function drawN()
  local hud = W.hud
  local saved = { renderText = renderText, setTextAlignment = setTextAlignment, setTextColor = setTextColor,
                  getTextWidth = getTextWidth, setTextBold = setTextBold, hud = g_currentMission.masterHUD }
  local bars, texts = {}, {}
  renderText = function(_x, _y, _sz, t) texts[#texts + 1] = t end
  setTextAlignment = function() end; setTextColor = function() end
  setTextBold = function() end; getTextWidth = function() return 0.01 end
  RenderText = RenderText or { ALIGN_LEFT = 1, ALIGN_RIGHT = 2, ALIGN_CENTER = 3 }
  g_currentMission.masterHUD = { renderer = { renderProgressBar = function(_r, _x, _y, _w, _h, fill, _c, total)
    bars[#bars + 1] = { fill = fill, total = total } return true end } }
  local ok, err = pcall(hud.drawNutrientRow, hud, "N", "N", { value = 50, status = "Fair" }, 0.1, 0.5, 0.3, 1, 1,
    FIELD, hud._cachedProfile, hud._cachedFillType, hud._cachedRateMult, nil)
  renderText, setTextAlignment, setTextColor = saved.renderText, saved.setTextAlignment, saved.setTextColor
  getTextWidth, setTextBold, g_currentMission.masterHUD = saved.getTextWidth, saved.setTextBold, saved.hud
  local ghost = bars[1] and (bars[1].total - bars[1].fill) or nil
  local suffix = false
  for _, t in ipairs(texts) do if type(t) == "string" and t:find("%(%+%d+%)") then suffix = true end end
  return ok, err, ghost, suffix
end

-- Today's ghost for this field and product, from the formula (independent of the HUD).
local function expectedGhost(rateMult)
  local threshold = FIELD.fieldArea * BR.UREA.value * rateMult * THR
  local remaining = math.max(0, threshold - FIELD.nutrientBuffer[50] * 0.77)
  return math.min(1.0 - 0.5, PF.UREA.N * (remaining / 1000) / FIELD.fieldArea * RR / 100)
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-12 end

-- =====================================================================
-- HOST: target mode decided by the real gates
-- =====================================================================
do
  world({ server = true, experimental = false, auto = true })
  W.hud:update(16)
  T.ok("H0 [reached] update() cached the player's sprayer and its UREA", W.hud._cachedSprayer == W.sprayer and W.hud._cachedFillType == UREA)
  T.eq("H1 experimental systems off (SF-73 locked), AUTO on: not target mode", W.hud._cachedTargetMode, false)
  local ok, err, ghost, suffix = drawN()
  T.ok("H2 the row drew (" .. tostring(err) .. ")", ok)
  T.ok("H3 so the ghost is today's, to the width (" .. tostring(ghost) .. ")", near(ghost, expectedGhost(1.0)) and ghost > 0)
  T.eq("H4 and the (+N) suffix is shown", suffix, true)
end
do
  world({ server = true, experimental = true, auto = false })
  W.hud:update(16)
  T.eq("H5 SF-73 unlocked, AUTO off: not target mode", W.hud._cachedTargetMode, false)
  local _, _, ghost, suffix = drawN()
  T.ok("H6 the ghost is today's, to the width (" .. tostring(ghost) .. ")", near(ghost, expectedGhost(1.0)) and suffix)
end
do
  world({ server = true, experimental = true, auto = true })
  W.hud:update(16)
  T.eq("H7 [reached] SF-73 unlocked and AUTO on: the real isTargetMode says target mode", W.ta:isTargetMode(W.sprayer), true)
  T.eq("H8 and update() cached it", W.hud._cachedTargetMode, true)
  local ok, err, ghost, suffix = drawN()
  T.ok("H9 the row still draws its value bar (" .. tostring(err) .. ")", ok and ghost ~= nil)
  T.eq("H10 NAMED: under target mode the ghost draws nothing", ghost, 0)
  T.eq("H11 and no (+N) is projected", suffix, false)
  W.rm:setAutoMode(W.sprayer.id, false)
  W.hud:update(16)
  local _, _, ghost2 = drawN()
  T.ok("H12 AUTO off again: the next frame's ghost is today's", near(ghost2, expectedGhost(1.0)))
end

-- =====================================================================
-- CLIENT: the received result decides, through the real receive
-- =====================================================================
local function clientResult(active, seq)
  return { schema = TargetNutrientCore.SCHEMA, epoch = "1", sequence = seq, active = active, doseState = "INACTIVE", reasons = {} }
end
do
  world({ server = false, experimental = true, auto = true })
  W.hud:update(16)
  T.eq("C1 a client with no result yet: not target mode (the client never asks isTargetMode)", W.hud._cachedTargetMode, false)
  T.eq("C2 [reached] the real receive accepts the server's active result", W.ta:receive(W.sprayer, clientResult(true, "1")), true)
  W.hud:update(16)
  T.eq("C3 NAMED: an active received result is target mode on the client", W.hud._cachedTargetMode, true)
  local _, _, ghost, suffix = drawN()
  T.ok("C4 and the ghost draws nothing (" .. tostring(ghost) .. ")", ghost == 0 and suffix == false)
  g_currentMission.time = g_currentMission.time + TargetApplication.RESULT_EXPIRY_MS
  W.hud:update(16)
  T.eq("C5 an active result past its expiry is no answer: not target mode", W.hud._cachedTargetMode, false)
  W.ta:receive(W.sprayer, clientResult(false, "2"))
  W.hud:update(16)
  T.eq("C6 an inactive result: not target mode", W.hud._cachedTargetMode, false)
  local _, _, ghost2 = drawN()
  T.ok("C7 and the ghost is today's", near(ghost2, expectedGhost(1.0)))
end
