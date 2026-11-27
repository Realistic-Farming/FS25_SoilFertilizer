-- MAINT-343-see_spray_herbicide_engine_weed_spec_test.lua
--
-- #1174 (cjdblair): with See & Spray bought, HERBICIDE kills no weeds, draws nothing and leaves
-- the game's spray map unchanged, while Soil's own pressure figure and pass record update.
--
-- Soil had two See & Spray decisions that could disagree. The credit hook
-- (HookManager.installSeeAndSprayHook) reads the ENGINE weed map first (a weed state of 0, or 7
-- and up, is "no target"; anything else is a target). The per-nozzle path
-- (SFNozzleEffects:sfUpdateNozzleEffectState) decided HERBICIDE from Soil's SIMULATED
-- weedPressure alone, against SEE_AND_SPRAY.WEED_THRESHOLD, and closed the nozzle as "notarget"
-- otherwise. Those decisions feed getIsWorkAreaActive and getSprayerUsage, which is what lets
-- the engine run processSprayerArea at all. A new field's weedPressure starts at 0
-- (SoilFertilitySystem.lua:3621), and the engine map is read into it only by the daily batch,
-- so on a fresh field with real weeds the nozzle path closed every boom area. The nozzle path
-- now reads the engine map the way the hook does, with Soil's pressure only as the fallback
-- when the map cannot be read, and logs once per closing which reason closed the boom.
--
-- THE ENTRY-POINT BAR. Every step runs the specialization's real onUpdate (the listener the
-- engine raises each frame), which runs the real sfUpdateNozzleEffectsState,
-- sfUpdateNozzleEffectState and sfCheckWholeBoomClosed, and then asks the real
-- getIsWorkAreaActive and getSprayerUsage what the engine asks before it processes a work area
-- and drains the tank. The fixture supplies what the engine and the save supply: the boom's
-- nozzle positions, which farmland a point is on, the bought See & Spray option, the engine's
-- weed system (getMapHasWeed, getWeedStateAtWorldPos, the call FieldState:update makes at
-- FieldState.lua:107) and the field's stored values. It sets NO decision by hand: nothing here
-- writes ssClosed, sectionActive, centerActive or an effect's isActive.
--
-- What the fixture sets by hand, disclosed: fieldData[7].weedPressure = 0 is the value a new
-- field starts with in production (SoilFertilitySystem.lua:3621), not a path the bar drives.
--
-- Groups:
--   W0  [reached] what the bar stands on: weeds are really there, the field starts at pressure 0
--   W1  NAMED: a fresh field with real weeds under the boom: every nozzle opens, the undivided
--       work area is open and the usage is not scaled to zero (RED on development, 7ff90d27)
--   W2  control: no weeds anywhere (native 0, pressure 0): the boom is closed, "notarget"
--   W3  control: the engine map unavailable and Soil's own pressure high: the boom opens on
--       Soil's reading (the fallback; green on development, must stay green)
--   W4  control: W1's world with ONE variable changed, Soil's pressure 40: opens (pressure is
--       what closed W1 on development)
--   W5  the engine is the ground truth both ways: native "no weeds" with Soil's pressure 40
--       closes the boom; a withered state (7 to 9) closes it; states 1 and 6 open it; a
--       recent herbicide record does not close it over weeds the engine still shows
--   W6  a map with no weed layer (getWeedStateAtWorldPos answers 0 there): the engine read is
--       not trusted, Soil's pressure decides, so the boom is not closed for good
--   W7  the log: one line per closing with the reason and where the weed reading came from,
--       none while the boom stays closed, none for a closing inside the 30 s gap, one after it
--
-- What this bar does NOT prove: the engine's processSprayerArea, paint and drain, that a real
-- map's weed layer returns the state this fixture returns, or anything on the installed 1.25.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/maps/SoilValueMaps.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/specializations/SFNozzleEffects.lua

local LOG = {}
SoilLogger.debug = function() end
SoilLogger.warning = function() end
SoilLogger.info = function(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  LOG[#LOG + 1] = ok and line or tostring(fmt)
end

ENGINE.RESOLUTION = 32                       -- 64 m terrain at 32 px: 2 m a pixel
setShaderParameter = function() end

local SPEC = SFNozzleEffects.SPEC_TABLE_NAME
local HERB = { index = 21, name = "HERBICIDE", title = "Herbicide" }
g_fillTypeManager = { getFillTypeByIndex = function(_, i) return i == HERB.index and HERB or nil end,
                      getFillTypeByName = function(_, n) return n == HERB.name and HERB or nil end }

-- ── the world: field 7 (farmland 7), a 32 x 48 m rectangle ────────────────────
local function farmAt(x, z)
  if math.abs(x) <= 16 and z >= -24 and z <= 24 then return 7 end
  return 0
end
g_farmlandManager = {
  getFarmlandIdAtWorldPosition = function(_, x, z) return farmAt(x, z) end,
  getFarmlandAtWorldPosition = function(_, x, z) local id = farmAt(x, z) return id > 0 and { id = id } or nil end,
}
g_fieldManager = { getFieldAtWorldPosition = function(_, x, z) local id = farmAt(x, z) return id > 0 and { farmland = { id = id } } or nil end }

-- The engine's weed system. WEED.state is the native weed state over field 7. WEED.layer is
-- whether the map has a weed layer at all; without one the engine answers 0 everywhere
-- (WeedSystem.lua:317-319), which is exactly why that answer cannot be trusted.
local WEED = { state = 4, outside = 0, layer = true }
local function weedStateAt(x, z)
  if not WEED.layer then return 0 end
  if farmAt(x, z) == 7 then return WEED.state end
  return WEED.outside
end
g_server = {}
g_time = 100000
g_currentMission = { time = 100000 }
local function engineMapAvailable(on)
  if on then
    g_currentMission.weedSystem = {
      getMapHasWeed = function() return WEED.layer end,
      getWeedStateAtWorldPos = function(_, x, z) return weedStateAt(x, z) end,
    }
  else
    g_currentMission.weedSystem = nil
  end
end

-- The vehicle: boom centre at (0, -10), heading +Z. Nozzles on the boom line.
local VEH = { bx = 0, bz = -10, hx = 0, hz = 1 }
local ROOT_NODE = 1
local NOZZLE = { [201] = 0, [202] = -6, [203] = 6 }      -- node -> lateral metres
local function rightOf() return VEH.hz, -VEH.hx end
getWorldTranslation = function(node)
  if node == ROOT_NODE then return VEH.bx + 2 * VEH.hx, 0, VEH.bz + 2 * VEH.hz end
  local lat = NOZZLE[node]
  if lat == nil then return 0, 0, 0 end
  local rx, rz = rightOf()
  return VEH.bx + lat * rx, 0, VEH.bz + lat * rz
end
localToWorld = function(node, lx, _, lz)
  local x, _, z = getWorldTranslation(node)
  local rx, rz = rightOf()
  return x + lx * rx + lz * VEH.hx, 0, z + lx * rz + lz * VEH.hz
end
localDirectionToWorld = function(node, _, _, _)
  if node == ROOT_NODE then return VEH.hx, 0, VEH.hz end
  return 0, 0, 0
end

-- ── the soil system: a fresh field, as a new save leaves it ──────────────────
local SS
local function newWorld(weedPressure, herbicideDaysLeft)
  ENGINE.disk = {}
  LOG = {}
  WEED.state, WEED.layer = 4, true
  SS = setmetatable({ fieldData = {}, settings = { enabled = true } }, { __index = SoilFertilitySystem })
  SS.valueMaps = SoilValueMaps.new()
  SS.valueMaps:initialize("savegame")
  SS.fieldData[7] = { nitrogen = 79, phosphorus = 35, potassium = 87, pH = 6.5, organicMatter = 3.0,
                      weedPressure = weedPressure, pestPressure = 0, diseasePressure = 0,
                      herbicideDaysLeft = herbicideDaysLeft }
  g_SoilFertilityManager = { settings = SS.settings, soilSystem = SS }
end

-- A sprayer with Soil's nozzle effects and See & Spray (weed) bought: three nozzles (the
-- centre, and one per boom section), one undivided work area (no sectionIndex).
local function newSprayer()
  local v = { id = 4343, isServer = true, rootNode = ROOT_NODE, movingDirection = 1, turnedOn = true, speed = 8 }
  v.getIsTurnedOn = function(self) return self.turnedOn end
  v.getLastSpeed = function(self) return self.speed end
  v.sfGetNumNozzleEffectsActive = SFNozzleEffects.sfGetNumNozzleEffectsActive
  v.sfUpdateNozzleEffectsState = SFNozzleEffects.sfUpdateNozzleEffectsState
  v.sfUpdateNozzleEffectState = SFNozzleEffects.sfUpdateNozzleEffectState
  v.spec_sprayer = { workAreaParameters = { lastSprayTime = -math.huge, sprayFillType = HERB.index } }
  v.spec_variableWorkWidth = { sections = { [1] = { isActive = true }, [2] = { isActive = true } } }
  local function effect(section, node, eff)
    return { effectNode = eff, probeNode = node, fadeCur = { 1, -1 }, fadeDir = SFNozzleEffects.FADE_DIR_OFF,
             state = 0, sectionIndex = section, isActive = false }
  end
  v[SPEC] = { hasCustomEffects = true, hasRealEffects = false, numCustomEffects = 3,
              sprayerEffects = { effect(0, 201, 301), effect(1, 202, 302), effect(2, 203, 303) },
              sprayerEffectsBySection = {}, _effectsPending = false, _sfFieldTimer = 0,
              seeSprayWeed = true, _sfFieldId = 7 }
  return v
end
local WORK_AREA = { sectionIndex = nil }                 -- one undivided work area
local function areaActive(v)
  return SFNozzleEffects.getIsWorkAreaActive(v, function() return true end, WORK_AREA)
end
local function usage(v)                                  -- the engine's own usage, scaled by Soil
  return SFNozzleEffects.getSprayerUsage(v, function() return 1 end, HERB.index, 16)
end
local function frame(v)
  g_time = g_time + 16
  SFNozzleEffects.onUpdate(v, 16, false, false, false)
end
local function settle(v, n) for _ = 1, n or 6 do frame(v) end end
local function openCount(v)
  local n = 0
  for _, ed in ipairs(v[SPEC].sprayerEffects) do if ed.isActive then n = n + 1 end end
  return n
end
local function reasons(v)
  local out = {}
  for _, ed in ipairs(v[SPEC].sprayerEffects) do out[#out + 1] = tostring(ed.ssClosed) end
  return table.concat(out, "/")
end
-- One world, one settled sprayer: a state, a pressure, a record; how many nozzles opened.
local function opened(state, pressure, daysLeft, layer)
  newWorld(pressure, daysLeft)
  WEED.state = state
  if layer ~= nil then WEED.layer = layer end
  engineMapAvailable(true)
  VEH.bx, VEH.bz = 0, -10
  local v = newSprayer()
  settle(v, 8)
  return openCount(v), v
end

-- =====================================================================
-- W0. What the bar stands on
-- =====================================================================
do
  newWorld(0)
  engineMapAvailable(true)
  WEED.state = 4
  T.eq("W0.1 [reached] the engine reads weed state 4 (a target) at the boom",
       g_currentMission.weedSystem:getWeedStateAtWorldPos(0, -10), 4)
  T.eq("W0.2 [reached] the field starts at pressure 0, as a new save leaves it", SS.fieldData[7].weedPressure, 0)
  T.ok("W0.3 [reached] 0 is below the See & Spray weed threshold, so Soil's own reading sees no target",
       0 < SoilConstants.SEE_AND_SPRAY.WEED_THRESHOLD)
  local v = newSprayer()
  T.ok("W0.4 [reached] the sprayer carries HERBICIDE and the bought weed option",
       v[SPEC].seeSprayWeed == true and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES[HERB.name] ~= nil)
end

-- =====================================================================
-- W1. NAMED: real weeds under the boom, a fresh field
-- =====================================================================
do
  local n, v = opened(4, 0)                            -- medium weeds over the whole field, pressure 0
  T.eq("W1.1 NAMED: with real weeds under the boom every nozzle opens (closed as: " .. reasons(v) .. ")", n, 3)
  T.ok("W1.2 and the undivided work area is open, so the engine can process it", areaActive(v) == true)
  T.ok("W1.3 and the usage is not scaled to zero, so the tank can drain (usage " .. string.format("%.3f", usage(v)) .. ")", usage(v) > 0)
end

-- =====================================================================
-- W2. Control: no weeds anywhere. A fix must not simply open everything.
-- =====================================================================
do
  local n, v = opened(0, 0)
  T.eq("W2.1 control: no weeds and pressure 0, every nozzle is closed", n, 0)
  T.ok("W2.2 control: the undivided work area is closed", areaActive(v) == false)
  T.eq("W2.3 control: the reason is the no-target one on every nozzle", reasons(v), "notarget/notarget/notarget")
  T.eq("W2.4 control: the usage is scaled to zero", usage(v), 0)
end

-- =====================================================================
-- W3. Control: the engine map unavailable, Soil's own pressure high
-- =====================================================================
do
  newWorld(40)                                         -- a field Soil's own daily batch has seen weeds on
  engineMapAvailable(false)                            -- no weed system: Soil's reading is all there is
  VEH.bx, VEH.bz = 0, -10
  local v = newSprayer()
  settle(v, 8)
  T.eq("W3.1 control: Soil's own pressure 40 opens every nozzle when the engine map is unavailable (closed as: " .. reasons(v) .. ")", openCount(v), 3)
  T.ok("W3.2 control: the undivided work area is open", areaActive(v) == true)
  T.ok("W3.3 control: the usage is not scaled to zero", usage(v) > 0)
end

-- =====================================================================
-- W4. Control: W1's world with ONE variable changed, Soil's own pressure
-- =====================================================================
do
  local n, v = opened(4, 40)                           -- the same real weeds and engine map as W1
  T.eq("W4.1 control: W1's weeds and engine map with Soil's pressure 40 open every nozzle (closed as: " .. reasons(v) .. ")", n, 3)
  T.ok("W4.2 control: and the undivided work area is open", areaActive(v) == true)
end

-- =====================================================================
-- W5. The engine map is the ground truth, both ways
-- =====================================================================
do
  local n = opened(0, 40)
  T.eq("W5.1 native 'no weeds' with a stale Soil pressure of 40: the boom is closed, as the hook skips it", n, 0)
  T.eq("W5.2 a withered state (7) is no target", (opened(7, 40)), 0)
  T.eq("W5.3 a withered state (8) is no target", (opened(8, 40)), 0)
  T.eq("W5.4 a withered state (9) is no target", (opened(9, 40)), 0)
  T.eq("W5.5 state 1, the first weed state, is a target", (opened(1, 0)), 3)
  T.eq("W5.6 state 6, the last weed state before withering, is a target", (opened(6, 0)), 3)
  local nd = opened(4, 0, 5)                           -- Soil credited a herbicide 5 days ago, weeds still there
  T.eq("W5.7 a recent herbicide record does not close the boom over weeds the engine still shows", nd, 3)
end

-- =====================================================================
-- W6. A map with no weed layer: the engine's 0 is "no layer", not "no weeds"
-- =====================================================================
do
  local n0 = opened(0, 0, nil, false)
  T.eq("W6.1 no weed layer and pressure 0: closed, on Soil's reading", n0, 0)
  local n40, v = opened(0, 40, nil, false)
  T.eq("W6.2 no weed layer and Soil's pressure 40: open, the engine's 0 is not trusted (closed as: " .. reasons(v) .. ")", n40, 3)
  T.ok("W6.3 and the undivided work area is open", areaActive(v) == true)
  T.eq("W6.4 a state the engine cannot answer (-1) is no reading either: Soil's pressure 40 decides, open", (opened(-1, 40)), 3)
end

-- =====================================================================
-- W7. The log: once per closing, with the reason and where the reading came from
-- =====================================================================
do
  newWorld(0)
  engineMapAvailable(true)
  WEED.state = 0                                       -- no weeds: the whole boom closes
  VEH.bx, VEH.bz = 0, -10
  local v = newSprayer()
  settle(v, 12)
  local closing = {}
  for _, l in ipairs(LOG) do if l:find("See & Spray", 1, true) and l:find("closed", 1, true) then closing[#closing + 1] = l end end
  T.eq("W7.1 one log line for the closing, however many frames it lasts", #closing, 1)
  T.ok("W7.2 it names the reason (" .. tostring(closing[1]) .. ")", closing[1] ~= nil and closing[1]:find("notarget", 1, true) ~= nil)
  T.ok("W7.3 and that the weed reading was the engine's", closing[1] ~= nil and closing[1]:find("engine", 1, true) ~= nil)
  WEED.state = 4                                       -- weeds appear: the boom reopens
  settle(v, 4)
  T.eq("W7.4 [reached] the boom reopened", openCount(v), 3)
  local before = #LOG
  WEED.state = 0                                       -- and closes again, inside the gap
  settle(v, 4)
  T.eq("W7.5 a second closing inside the 30 s gap is not logged (a flapping boom cannot fill the log)", #LOG, before)
  WEED.state = 4                                       -- reopens
  settle(v, 4)
  g_time = g_time + SFNozzleEffects.SS_MESSAGE_GAP_MS  -- the gap passes
  before = #LOG
  WEED.state = 0
  settle(v, 4)
  local again = 0
  for i = before + 1, #LOG do if LOG[i]:find("closed", 1, true) then again = again + 1 end end
  T.eq("W7.6 a closing after the gap logs once more", again, 1)
end

-- =====================================================================
-- W8. One boundary for the hook and the nozzle path (MAINTENANCE row 346)
-- =====================================================================
do
  local SS = SoilConstants.SEE_AND_SPRAY
  local saved = SS.WEED_STATE_WITHERED_FROM
  SS.WEED_STATE_WITHERED_FROM = 3
  T.eq("W8.1 with the shared boundary moved to 3, native state 3 is 'weeds gone' for the nozzle path", (opened(3, 40)), 0)
  SS.WEED_STATE_WITHERED_FROM = 5
  T.eq("W8.2 moved to 5, state 3 is a target again", (opened(3, 0)), 3)
  SS.WEED_STATE_WITHERED_FROM = saved
end
