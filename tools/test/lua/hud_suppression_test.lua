-- hud_suppression_test.lua - the HUD stands down while a full-screen panel is up.
--
-- Reported in-game: the Soil Monitor's Good / Fair / Poor labels read straight
-- THROUGH the settings panel drawn over them.
--
-- The cause is the same one that made the experimental confirmation unreadable.
-- A panel background is an OVERLAY, and an overlay does not cover text that was
-- already rendered underneath it. So a HUD cannot be hidden by painting on top
-- of it. It has to not draw at all.
--
-- The rule already existed everywhere else: SoilHUD:draw stands down for a
-- base-game GUI, and the four in-vehicle panels each carry the same
-- getIsGuiVisible guard. None of them could see OUR panels, because those are
-- drawn surfaces rather than g_gui ones. This locks the closing of that gap.
--
--!load: src/utils/Logger.lua, src/integrations/SoilMasterHUDBridge.lua

local function panel(isOpen)
  local p = { drawn = 0, _open = isOpen }
  p.draw   = function(_self) p.drawn = p.drawn + 1 end
  p.isOpen = function(_self) return p._open end
  return p
end

-- A HUD element has no isOpen; it is passive and always drew before.
local function hud()
  local h = { drawn = 0 }
  h.draw = function(_self) h.drawn = h.drawn + 1 end
  return h
end

local function newManager(over)
  local m = {
    soilHUD          = hud(),
    settingsPanel    = panel(false),
    tuningPanel      = panel(false),
    cropTuningPanel  = panel(false),
    variableRatePanel = hud(),
    smartSensorPanel  = hud(),
    sprayerInfoPanel  = hud(),
    harvesterPanel    = hud(),
  }
  local mapDrawn = { n = 0 }
  m.soilMapOverlay = {
    ingameMapRef = {},
    onDrawMinimap = function(_self, _map) mapDrawn.n = mapDrawn.n + 1 end,
  }
  m._mapDrawn = mapDrawn
  for k, v in pairs(over or {}) do m[k] = v end
  return m
end

local function run(m)
  g_SoilFertilityManager = m
  SoilMasterHUDBridge.drawStack()
  return m
end

-- ── Nothing open: the whole stack draws, exactly as before ──────────────────
do
  local m = run(newManager())
  T.eq("the Soil Monitor draws when no panel is up", m.soilHUD.drawn, 1)
  T.eq("the in-vehicle panels draw", m.sprayerInfoPanel.drawn, 1)
  T.eq("the harvester panel draws", m.harvesterPanel.drawn, 1)
  T.eq("the minimap overlay draws", m._mapDrawn.n, 1)
  T.eq("the settings panel is still called", m.settingsPanel.drawn, 1)
end

-- ── Settings open: the HUD stands down ──────────────────────────────────────
do
  local m = newManager()
  m.settingsPanel._open = true
  run(m)
  T.eq("the Soil Monitor does NOT draw behind the settings panel", m.soilHUD.drawn, 0)
  T.eq("the settings panel itself still draws", m.settingsPanel.drawn, 1)
  T.eq("the variable rate panel stands down", m.variableRatePanel.drawn, 0)
  T.eq("the smart sensor panel stands down", m.smartSensorPanel.drawn, 0)
  T.eq("the sprayer info panel stands down", m.sprayerInfoPanel.drawn, 0)
  T.eq("the harvester panel stands down", m.harvesterPanel.drawn, 0)
  T.eq("the minimap overlay stands down", m._mapDrawn.n, 0)
end

-- ── The tuning editors get the same protection ──────────────────────────────
do
  local m = newManager()
  m.tuningPanel._open = true
  run(m)
  T.eq("the Soil Monitor does NOT draw behind the tuning editor", m.soilHUD.drawn, 0)
  T.eq("the tuning editor itself draws", m.tuningPanel.drawn, 1)
end

do
  local m = newManager()
  m.cropTuningPanel._open = true
  run(m)
  T.eq("the Soil Monitor does NOT draw behind the crop tuning editor", m.soilHUD.drawn, 0)
  T.eq("the crop tuning editor itself draws", m.cropTuningPanel.drawn, 1)
end

-- ── Nil safety: the stack must survive a missing element ────────────────────
do
  -- Every element is optional at runtime; a manager missing one must not take
  -- the whole draw loop down, panel open or not.
  local m = newManager({ soilHUD = nil, sprayerInfoPanel = nil, soilMapOverlay = nil })
  local ok = pcall(function() run(m) end)
  T.ok("a stack with missing elements still draws", ok)

  local m2 = newManager({ soilHUD = nil })
  m2.settingsPanel._open = true
  local ok2 = pcall(function() run(m2) end)
  T.ok("a stack with missing elements still draws with a panel open", ok2)
end

do
  -- A panel object that does not expose isOpen must not be treated as open, and
  -- must not error. This is the shape a future panel could arrive in.
  local m = newManager()
  m.settingsPanel = { drawn = 0, draw = function(s) end }
  local ok = pcall(function() run(m) end)
  T.ok("a panel without isOpen is tolerated", ok)
  T.eq("and is not treated as open, so the HUD still draws", m.soilHUD.drawn, 1)
end

-- ── No manager at all ───────────────────────────────────────────────────────
do
  g_SoilFertilityManager = nil
  local ok = pcall(function() SoilMasterHUDBridge.drawStack() end)
  T.ok("no manager is a no-op rather than an error", ok)
end
