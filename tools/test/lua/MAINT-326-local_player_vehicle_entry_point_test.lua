-- MAINT-326-local_player_vehicle_entry_point_test.lua: MAINTENANCE row 326, the reads of
-- g_currentMission.controlledVehicle.
--
-- THE DEFECT. FS25 never assigns g_currentMission.controlledVehicle (nothing in the 1.24 scripts
-- writes it; the engine asks the player, player:getCurrentVehicle(), as in
-- DensityMapHeightManager.lua:633). Four Soil sites read it, so each always saw "no vehicle":
--   * SoilHUD:enterEditMode and SoilHUD:update, the vehicle camera freeze of the HUD's edit mode,
--     so a player in a tractor who dragged the HUD still orbited the camera;
--   * main.lua's SoilSprayerDebug console command, which could never find a vehicle;
--   * the native FIELD INFO hook's position helper, which fell through to the player's root node,
--     not where the vehicle is while driving.
-- All four now ask SoilUtils.getLocalPlayerVehicle().
--
-- ENTRY-POINT BAR. Each group enters where production does. H: SoilHUD:enterEditMode and
-- SoilHUD:update on a real SoilHUD.new. D: SoilSprayerDebug, taken from main.lua's own text and
-- run as the console runs it. F: the real HookManager:installNativeFieldInfoHook wraps
-- PlayerHUDUpdater.fieldAddFarmland, and the engine's call of it reaches the hook's position
-- helper; the hook's own next step, HookManager:getFieldIdAtWorldPosition, is the one recording
-- seam (it records the world position it is asked about and answers nil, so the hook ends there).
-- The local player is an object answering getCurrentVehicle, as the engine's Player does.
--
-- Modelled, not real: the engine's camera, scene-graph setRotation and getWorldTranslation, the
-- sprayer specialization's methods, and the field lookup behind getFieldIdAtWorldPosition (that
-- lookup has its own benches). Not covered: the engine's real Player object in a running game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/utils/SoilUtils.lua, src/ui/SoilHUD.lua, src/hooks/HookManager.lua
--!text: src/main.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function textOf(path) return ((SOURCE_TEXT and SOURCE_TEXT[path]) or ""):gsub("\r\n", "\n") end

-- ── what the bar changes, saved and put back at the end ──
local GLOBALS = { "g_localPlayer", "getCamera", "getRotation", "setRotation", "getWorldTranslation",
                  "PlayerHUDUpdater", "g_SoilFertilityManager", "g_fillTypeManager", "SoilSprayerDebug" }
local SAVED = {}
for _, k in ipairs(GLOBALS) do SAVED[k] = _G[k] end

-- ── engine models ──
local NODES = {}                       -- world positions by node id
getWorldTranslation = function(node)
  local p = NODES[node]
  if p == nil then return 0, 0, 0 end
  return p.x, p.y, p.z
end
local ROTATIONS = {}                   -- every setRotation(node, x, y, z) the code made
setRotation = function(node, x, y, z) ROTATIONS[#ROTATIONS + 1] = { node = node, x = x, y = y, z = z } end
getCamera = function() return 1 end
getRotation = function() return 0.1, 0.2, 0 end

-- The engine's Player answers getCurrentVehicle through its state machine: the vehicle while
-- driving (PlayerStateDriving.lua:83), nil on foot (PlayerOnFootStateMachine.lua:67).
local function playerIn(vehicle, rootNode)
  return { rootNode = rootNode,
           getCurrentVehicle = function() return vehicle end,
           getIsInVehicle = function() return vehicle ~= nil end }
end

local function rotationsOn(node)
  local n = 0
  for _, r in ipairs(ROTATIONS) do if r.node == node then n = n + 1 end end
  return n
end

-- =========================================================
-- H: the HUD's edit mode freezes the vehicle camera of the vehicle the player is in
-- =========================================================
group("H", function()
  local vehicle = { spec_cameraSystem = { activeCamera = { rotX = 0.4, rotY = 1.2, rotateNode = 77 } } }
  g_localPlayer = playerIn(vehicle)
  local hud = SoilHUD.new({}, { hudPosition = 1 })
  hud:enterEditMode()
  T.eq("H1 [reached] a player in a vehicle enters the HUD's edit mode: the active camera's rotation is saved",
    tostring(hud.savedVehicleCamRotX) .. "/" .. tostring(hud.savedVehicleCamRotY), "0.4/1.2")

  -- The player orbits the camera with the mouse; the next HUD update must put it back.
  local ac = vehicle.spec_cameraSystem.activeCamera
  ac.rotX, ac.rotY = 0.9, 2.5
  ROTATIONS = {}
  hud:update(16)
  T.eq("H2 NAMED [entry point]: the update restores the camera's rotation and pushes it to the camera's node",
    ac.rotX .. "/" .. ac.rotY .. "/" .. rotationsOn(77), "0.4/1.2/1")
  T.eq("H3 and what it pushed is the saved pair with no roll",
    (function() for _, r in ipairs(ROTATIONS) do if r.node == 77 then return r.x .. "/" .. r.y .. "/" .. r.z end end return "none" end)(),
    "0.4/1.2/0")

  g_localPlayer = playerIn(nil)
  local hudFoot = SoilHUD.new({}, { hudPosition = 1 })
  hudFoot:enterEditMode()
  ROTATIONS = {}
  hudFoot:update(16)
  T.eq("H4 on foot nothing is saved for a vehicle camera and the node is never touched",
    tostring(hudFoot.savedVehicleCamRotX) .. "/" .. rotationsOn(77), "nil/0")

  g_localPlayer = nil
  local hudNone = SoilHUD.new({}, { hudPosition = 1 })
  local ok = pcall(function() hudNone:enterEditMode() hudNone:update(16) end)
  T.eq("H5 with no local player (a dedicated server) entering and updating the edit mode raises nothing, saves nothing",
    tostring(ok) .. "/" .. tostring(hudNone.savedVehicleCamRotX), "true/nil")

  g_localPlayer = playerIn({})
  local hudBare = SoilHUD.new({}, { hudPosition = 1 })
  hudBare:enterEditMode()
  T.eq("H6 a vehicle with no camera system saves nothing", tostring(hudBare.savedVehicleCamRotX), "nil")

  -- A player whose state getter raises, or that has none, reads as no vehicle and never raises.
  g_localPlayer = { getCurrentVehicle = function() error("state machine") end }
  local hudRaise = SoilHUD.new({}, { hudPosition = 1 })
  local okRaise = pcall(function() hudRaise:enterEditMode() end)
  g_localPlayer = { rootNode = 5 }
  local hudNoGetter = SoilHUD.new({}, { hudPosition = 1 })
  local okNoGetter = pcall(function() hudNoGetter:enterEditMode() end)
  T.eq("H7 a getter that raises, and a player with no getter, read as no vehicle without raising",
    tostring(okRaise) .. "/" .. tostring(hudRaise.savedVehicleCamRotX) .. "/" .. tostring(okNoGetter) .. "/" .. tostring(hudNoGetter.savedVehicleCamRotX),
    "true/nil/true/nil")
end)

-- =========================================================
-- D: the SoilSprayerDebug console command finds the vehicle the player is in
-- =========================================================
group("D", function()
  local MAIN = textOf("src/main.lua")
  local FN_START = "function SoilSprayerDebug()\n"
  local fnText = nil
  local i = MAIN:find(FN_START, 1, true)
  if i ~= nil then
    local j = MAIN:find("\nend\n", i, true)
    if j ~= nil then fnText = MAIN:sub(i, j + 4) end
  end
  T.ok("D0 main.lua holds SoilSprayerDebug once", fnText ~= nil and select(2, MAIN:gsub("function SoilSprayerDebug%(%)", "")) == 1)
  assert(load(fnText, "=main.lua SoilSprayerDebug", "t", _ENV))()

  g_fillTypeManager = { getFillTypeByIndex = function(_, idx) return { name = "FILL" .. tostring(idx) } end }
  local function capture(fn)
    local lines, real = {}, print
    print = function(...) local t = {} for k = 1, select("#", ...) do t[k] = tostring((select(k, ...))) end lines[#lines + 1] = table.concat(t, " ") end
    local ok, err = pcall(fn)
    print = real
    return table.concat(lines, "\n"), ok, err
  end

  local sprayer = {
    configFileName = "data/vehicles/sprayer.xml",
    spec_sprayer = { workAreaParameters = { sprayType = 1, isActive = true }, effects = { {}, {} }, sprayTypes = {} },
    getSprayerFillUnitIndex = function() return 1 end,
    getFillUnitFillType = function() return 12 end,
    getAreEffectsVisible = function() return true end,
    getActiveSprayType = function() return {} end,
  }
  g_localPlayer = playerIn(sprayer)
  local out, ok, err = capture(SoilSprayerDebug)
  T.eq("D1 NAMED [entry point]: a player in a sprayer gets the sprayer's dump, not 'No controlled vehicle'",
    tostring(ok) .. "/" .. tostring(out:find("Vehicle: data/vehicles/sprayer.xml", 1, true) ~= nil) .. "/"
      .. tostring(out:find("No controlled vehicle", 1, true) ~= nil), "true/true/false")
  T.ok("D2 and the dump carries the fill unit, the fill type's name and the active spray type",
    out:find("fillUnit=1  fillType=12(FILL12)", 1, true) ~= nil and out:find("getActiveSprayType() = FOUND", 1, true) ~= nil)

  g_localPlayer = playerIn(nil)
  out = capture(SoilSprayerDebug)
  T.eq("D3 on foot it says there is no vehicle", tostring(out:find("No controlled vehicle", 1, true) ~= nil), "true")

  g_localPlayer = nil
  out, ok = capture(SoilSprayerDebug)
  T.eq("D4 with no local player (a dedicated server) it says so and raises nothing",
    tostring(ok) .. "/" .. tostring(out:find("No controlled vehicle", 1, true) ~= nil), "true/true")

  g_localPlayer = playerIn({})
  out = capture(SoilSprayerDebug)
  T.eq("D5 in a vehicle that is not a sprayer it says so", tostring(out:find("Vehicle has no spec_sprayer", 1, true) ~= nil), "true")
end)

-- =========================================================
-- F: the native FIELD INFO hook resolves the position of the vehicle the player is in
-- =========================================================
group("F", function()
  PlayerHUDUpdater = { fieldAddFarmland = function() end, fieldAddField = function() end }
  g_SoilFertilityManager = { soilSystem = { getFieldInfo = function() return nil end },
                             settings = { enabled = true, showFieldInfoBox = true } }
  local hm = HookManager.new()
  local ASKED = {}
  -- The one recording seam: the hook's next step after the position helper.
  hm.getFieldIdAtWorldPosition = function(_, x, z) ASKED[#ASKED + 1] = x .. "," .. z return nil end
  T.ok("F0 [reached] the real hook installed on the engine's PlayerHUDUpdater", hm:installNativeFieldInfoHook() == true)

  -- The hook resolves the position at two call sites per engine call (the yield-row override in the
  -- wrapper and the row append after it), so it asks twice; the positions it asks about must agree,
  -- and the row reports the distinct ones.
  local function showFieldInfo()
    ASKED = {}
    local box = { addLine = function() end }
    PlayerHUDUpdater.fieldAddFarmland({}, {}, box)
    local seen, distinct = {}, {}
    for _, a in ipairs(ASKED) do
      if not seen[a] then seen[a] = true distinct[#distinct + 1] = a end
    end
    return table.concat(distinct, "|")
  end

  NODES[5] = { x = 999, y = 0, z = 999 }         -- the player's root node: where it entered the tractor
  g_localPlayer = playerIn(nil, 5)
  NODES[5] = { x = 10, y = 0, z = 20 }
  T.eq("F1 on foot the hook asks about the player's own position", showFieldInfo(), "10,20")

  NODES[5] = { x = 999, y = 0, z = 999 }
  NODES[7] = { x = 30, y = 0, z = 40 }
  g_localPlayer = playerIn({ rootNode = 7 }, 5)
  T.eq("F2 NAMED [entry point]: driving, the hook asks about the vehicle's position, not the stale player node",
    showFieldInfo(), "30,40")

  NODES[8] = { x = 31, y = 0, z = 41 }
  g_localPlayer = playerIn({ components = { { node = 8 } } }, 5)
  T.eq("F3 a vehicle with no root node is found through its first component", showFieldInfo(), "31,41")

  g_localPlayer = nil
  local ok, asked = pcall(showFieldInfo)
  T.eq("F4 with no local player (a dedicated server) the hook asks nothing and raises nothing",
    tostring(ok) .. "/" .. tostring(asked), "true/")
end)

-- ── put back what the bar changed ──
for _, k in ipairs(GLOBALS) do _G[k] = SAVED[k] end
