-- SF-1154-see_spray_pass3_lookahead_spec_test.lua
--
-- #1154 (fzerbib56-ui): with See & Spray bought, a fertilizer pass shut its own boom. Pass 3
-- of SFNozzleEffects:sfUpdateNozzleEffectState (nutrient adequacy) read N/P/K exactly on the
-- boom line, where Soil had just credited this pass. Within a second every probe read the
-- 100 cap, every nozzle closed, and on a sprayer whose one undivided work area follows the
-- centre nozzle getIsWorkAreaActive returned false for the whole boom; the credit kept the
-- strip under it full, so it never reopened. Pass 3 now reads the first value-map pixel whose
-- centre lies ahead of the nozzle along the vehicle's heading (a pixel the pass cannot have
-- credited yet, and the nearest one), and makes no decision when that pixel is off the
-- nozzle's farmland.
--
-- THE ENTRY-POINT BAR. Every step runs the specialization's real onUpdate (the listener the
-- engine raises each frame), which runs the real sfUpdateNozzleEffectsState,
-- sfUpdateNozzleEffectState and the centre aggregation, and then asks the real
-- getIsWorkAreaActive the question the engine asks before processing the work area. The
-- value maps are Soil's own, at 2 m a pixel (the engine model's map size), read through
-- readValueAtWorld. The fixture supplies what the engine and the save supply: the boom's
-- nozzle positions, the vehicle's heading (localDirectionToWorld of the root node, the
-- engine's forward), which farmland a point is on, the bought See & Spray option, and the
-- ground values. The strip the pass has credited is written into the value maps as the
-- credit leaves it (every pixel whose centre the boom has passed, at the 100 cap).
--
-- Groups:
--   L0  [reached] 2 m pixels; the ground ahead starts below target, the strip reads 100
--   L1  NAMED: a whole pass with the credited strip under and behind the boom: the
--       undivided work area stays open on every step, and so does every nozzle
--   L2  the check still works: ground that is already full closes the boom, which reopens
--       past it, and the decision leads the boom by one pixel at most
--   L3  the end of the field: the point ahead is on the neighbour's (full) ground; the
--       nozzle is not judged by it
--   L4  a diagonal heading: the read point clears the swept pixel at 45 degrees too
--   L5  no heading to read along: no decision, the boom stays open
--   L6  the credited line 0.4 m ahead of the nozzles, driven in 0.3 m steps: the margin keeps
--       the read pixel clear of it
--   U   #1154 follow-up (a), Tyson 2026-11-18: with a fertilizer an undivided boom follows its
--       nozzles (open while any is open), not the centre alone; chemicals and a real centre
--       section keep the centre's decision
--
-- What this bar does NOT prove: the engine's processSprayerArea, paint and drain (the
-- work area being active is what lets them run), the credit's own arithmetic, the nozzle
-- visuals' fade, and a real map's i3d nozzle nodes.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/maps/SoilValueMaps.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/specializations/SFNozzleEffects.lua

SoilLogger.debug = function() end
SoilLogger.info = function() end
SoilLogger.warning = function() end

ENGINE.RESOLUTION = 32                       -- 64 m terrain at 32 px: 2 m a pixel
setShaderParameter = function() end

local SPEC = SFNozzleEffects.SPEC_TABLE_NAME
local LF = { index = 20, name = "LIQUIDFERTILIZER", title = "Liquid fertilizer" }
g_fillTypeManager = { getFillTypeByIndex = function(_, i) return i == LF.index and LF or nil end,
                      getFillTypeByName = function(_, n) return n == LF.name and LF or nil end }

-- ── the world: field 7 (farmland 7) and its neighbour, farmland 8, beyond z = 24 ─────
local function farmAt(x, z)
  if math.abs(x) <= 16 and z >= -24 and z <= 24 then return 7 end
  if math.abs(x) <= 16 and z > 24 and z <= 31 then return 8 end
  return 0
end
g_farmlandManager = {
  getFarmlandIdAtWorldPosition = function(_, x, z) return farmAt(x, z) end,
  getFarmlandAtWorldPosition = function(_, x, z) local id = farmAt(x, z) return id > 0 and { id = id } or nil end,
}
g_fieldManager = { getFieldAtWorldPosition = function(_, x, z) local id = farmAt(x, z) return id > 0 and { farmland = { id = id } } or nil end }

-- The vehicle: the boom centre B, heading H (unit), right axis R. Nozzles at lateral
-- offsets on the boom line; the root node 2 m ahead of the boom.
local VEH = { bx = 0, bz = -20, hx = 0, hz = 1, heading = true }
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
localDirectionToWorld = function(node, _, _, _)
  if node == ROOT_NODE and VEH.heading then return VEH.hx, 0, VEH.hz end
  return 0, 0, 0
end

-- ── the soil system and its value maps ───────────────────────────────────────
g_server = {}
g_time = 100000
g_currentMission = { time = 100000 }
local SS
local function newWorld()
  ENGINE.disk = {}
  SS = setmetatable({ fieldData = {}, settings = { enabled = true } }, { __index = SoilFertilitySystem })
  SS.valueMaps = SoilValueMaps.new()
  SS.valueMaps:initialize("savegame")
  SS.fieldData[7] = { nitrogen = 79, phosphorus = 35, potassium = 87, pH = 6.5, organicMatter = 3.0 }
  SS.fieldData[8] = { nitrogen = 100, phosphorus = 100, potassium = 100, pH = 6.5, organicMatter = 3.0 }
  g_SoilFertilityManager = { settings = SS.settings, soilSystem = SS }
  -- the ground, pixel by pixel: field 7 below target, the neighbour full
  for x = -31, 31, 2 do
    for z = -31, 31, 2 do
      local farm = farmAt(x, z)
      local v = farm == 7 and { 79, 35, 87 } or (farm == 8 and { 100, 100, 100 } or nil)
      if v then
        SS.valueMaps:writeValueAtWorld("nitrogen", x, z, v[1], 0.9)
        SS.valueMaps:writeValueAtWorld("phosphorus", x, z, v[2], 0.9)
        SS.valueMaps:writeValueAtWorld("potassium", x, z, v[3], 0.9)
      end
    end
  end
end
local function setFull(x, z)
  SS.valueMaps:writeValueAtWorld("nitrogen", x, z, 100, 0.9)
  SS.valueMaps:writeValueAtWorld("phosphorus", x, z, 100, 0.9)
  SS.valueMaps:writeValueAtWorld("potassium", x, z, 100, 0.9)
end
-- The credit as it leaves the ground: every field-7 pixel whose centre the boom has passed
-- (on or behind the boom line, within the boom's 14 m), at the cap.
-- CREDIT_LEAD: how far ahead of the nozzles the credited line sits (the work-area nodes the
-- credit uses and the nozzle nodes need not coincide on a real boom).
local CREDIT_LEAD = 0
local function creditUpToBoom()
  local rx, rz = rightOf()
  for x = -31, 31, 2 do
    for z = -31, 31, 2 do
      if farmAt(x, z) == 7 then
        local along = (x - VEH.bx) * VEH.hx + (z - VEH.bz) * VEH.hz
        local lat = (x - VEH.bx) * rx + (z - VEH.bz) * rz
        if along <= CREDIT_LEAD and math.abs(lat) <= 7 then setFull(x, z) end
      end
    end
  end
end

-- A sprayer with Soil's nozzle effects and See & Spray bought: three nozzles (the centre,
-- and one per boom section), one undivided work area (no sectionIndex).
local function newSprayer()
  local v = { id = 4242, isServer = true, rootNode = ROOT_NODE, movingDirection = 1, turnedOn = true, speed = 8 }
  v.getIsTurnedOn = function(self) return self.turnedOn end
  v.getLastSpeed = function(self) return self.speed end
  v.sfGetNumNozzleEffectsActive = SFNozzleEffects.sfGetNumNozzleEffectsActive
  v.sfUpdateNozzleEffectsState = SFNozzleEffects.sfUpdateNozzleEffectsState
  v.sfUpdateNozzleEffectState = SFNozzleEffects.sfUpdateNozzleEffectState
  v.spec_sprayer = { workAreaParameters = { lastSprayTime = -math.huge, sprayFillType = LF.index } }
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
local WORK_AREA = { sectionIndex = nil }                 -- the iXter's one undivided work area
local function areaActive(v)
  return SFNozzleEffects.getIsWorkAreaActive(v, function() return true end, WORK_AREA)
end
local function frame(v)
  g_time = g_time + 16
  SFNozzleEffects.onUpdate(v, 16, false, false, false)
end
local function allNozzles(v)
  for _, ed in ipairs(v[SPEC].sprayerEffects) do if not ed.isActive then return false end end
  return true
end

-- Drive the boom from fromZ to toZ in 0.5 m steps along the current heading, crediting the
-- strip it passes; count the steps on which the work area (and every nozzle) was closed.
local function drive(v, steps, step)
  step = step or 0.5
  local closedArea, closedNozzle, firstClosedAt = 0, 0, nil
  for _ = 1, steps do
    VEH.bx, VEH.bz = VEH.bx + step * VEH.hx, VEH.bz + step * VEH.hz
    creditUpToBoom()
    frame(v)
    if not areaActive(v) then
      closedArea = closedArea + 1
      firstClosedAt = firstClosedAt or string.format("%.1f,%.1f", VEH.bx, VEH.bz)
    end
    if not allNozzles(v) then closedNozzle = closedNozzle + 1 end
  end
  return closedArea, closedNozzle, firstClosedAt
end

-- =====================================================================
-- L0. What the bar stands on
-- =====================================================================
do
  newWorld()
  T.eq("L0.1 [reached] the value maps are Soil's own at 2 m a pixel", SS.valueMaps:getGrainMetres(), 2)
  local function r(key) return string.format("%.0f", SS.valueMaps:readValueAtWorld(key, 0, -16)) end
  T.eq("L0.2 [reached] the ground ahead of the start reads below target (79/35/87, the maps' own rounding)",
       r("nitrogen") .. "/" .. r("phosphorus") .. "/" .. r("potassium"), "79/35/87")
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -20, 0, 1, true
  creditUpToBoom()
  T.eq("L0.3 [reached] the strip the pass has credited reads full under the boom", SS.valueMaps:readValueAtWorld("nitrogen", 0, -21), 100)
end

-- =====================================================================
-- L1. A whole pass: the credited strip must not shut the boom
-- =====================================================================
do
  newWorld()
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -21, 0, 1, true
  local v = newSprayer()
  local area, nozzles, first = drive(v, 80)                    -- z = -20.5 to +19
  T.eq("L1.1 NAMED: across the field the undivided work area is open on every step (first closed at " .. tostring(first) .. ")", area, 0)
  T.eq("L1.2 and every nozzle stays open on every step", nozzles, 0)
end

-- =====================================================================
-- L2. The check still works: ground ahead that is already full closes the boom
-- =====================================================================
do
  newWorld()
  for x = -15, 15, 2 do for z = 1, 7, 2 do setFull(x, z) end end      -- a band fertilized earlier, z 0 to 8
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -10.5, 0, 1, true
  local v = newSprayer()
  local openAt = {}
  for _ = 1, 45 do                                               -- boom from z = -10 to +12
    drive(v, 1)
    openAt[#openAt + 1] = { z = VEH.bz, open = areaActive(v) }
  end
  local before, over, after, firstClosed, reopened = true, true, true, nil, nil
  for _, s in ipairs(openAt) do
    if s.z <= -2.0 and not s.open then before = false end
    if (s.z >= 0 and s.z <= 5.5) and s.open then over = false end
    if s.z >= 8.0 and not s.open then after = false end
    if not s.open and firstClosed == nil then firstClosed = s.z end
    if firstClosed ~= nil and s.open and reopened == nil then reopened = s.z end
  end
  T.ok("L2.1 open on the ground before the full band", before)
  T.ok("L2.2 the check still works: closed over ground that is already full", over)
  T.ok("L2.3 open again past it", after)
  T.ok("L2.4 NAMED: the decision leads the boom by one pixel at most: closes no earlier than 2 m before the band (z = "
       .. tostring(firstClosed) .. "), reopens no earlier than 2 m before its end (z = " .. tostring(reopened) .. ")",
       firstClosed ~= nil and firstClosed >= -2.0 and reopened ~= nil and reopened >= 6.0)
end

-- =====================================================================
-- L3. The end of the field: not judged by the neighbour's ground
-- =====================================================================
do
  newWorld()
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, 15, 0, 1, true
  local v = newSprayer()
  local area, _, first = drive(v, 17)                             -- boom to z = 23.5, reading past z = 24
  T.eq("L3.1 the last metres of the field, the point ahead on the full neighbour: the boom stays open (first closed at " .. tostring(first) .. ")", area, 0)
end

-- =====================================================================
-- L4. A diagonal heading: the read point clears the swept pixel at any angle
-- =====================================================================
do
  newWorld()
  local s = math.sqrt(0.5)
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = -12, -18, s, s, true
  local v = newSprayer()
  local area, nozzles, first = drive(v, 50)                      -- about 25 m along the diagonal
  T.eq("L4.1 at 45 degrees the work area is open on every step (first closed at " .. tostring(first) .. ")", area, 0)
  T.eq("L4.2 and every nozzle too", nozzles, 0)
end

-- =====================================================================
-- L5. No heading to read along: no decision, the boom stays open
-- =====================================================================
do
  newWorld()
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -10, 0, 1, false
  local v = newSprayer()
  local area = drive(v, 10)
  T.eq("L5.1 with no heading the check makes no decision rather than read the credited strip", area, 0)
  T.eq("L5.2 pass3ReadPoint says so itself", SFNozzleEffects.pass3ReadPoint(v, 0, 0, SS.valueMaps), nil)
end

-- =====================================================================
-- L6. The credited line a little ahead of the nozzles: the margin keeps clear of it
-- =====================================================================
do
  newWorld()
  CREDIT_LEAD = 0.4
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -21, 0, 1, true
  local v = newSprayer()
  local area, nozzles, first = drive(v, 120, 0.3)              -- 36 m in 0.3 m steps
  CREDIT_LEAD = 0
  T.eq("L6.1 the credit 0.4 m ahead of the nozzles: open on every step (first closed at " .. tostring(first) .. ")", area, 0)
  T.eq("L6.2 and every nozzle too", nozzles, 0)
end

-- =====================================================================
-- U. Follow-up (a): an undivided boom with a fertilizer follows its nozzles, not the centre alone
-- =====================================================================
local INS = { index = 22, name = "INSECTICIDE", title = "Insecticide" }   -- a chemical that also carries a fertilizer profile
do
  local base = g_fillTypeManager.getFillTypeByIndex
  g_fillTypeManager.getFillTypeByIndex = function(m, i) if i == INS.index then return INS end return base(m, i) end
end
do
  newWorld()
  for z = -19, 23, 2 do setFull(1, z); setFull(-1, z) end      -- full ground along the centre line only
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -21, 0, 1, true
  local v = newSprayer()
  drive(v, 4)
  T.eq("U1 [reached] the centre nozzle reads full ground ahead and closes", v[SPEC].centerActive, false)
  T.eq("U2 [reached] the outer nozzles read ground that needs the product and stay open",
       tostring(v[SPEC].sprayerEffects[2].isActive) .. "/" .. tostring(v[SPEC].sprayerEffects[3].isActive), "true/true")
  T.eq("U3 NAMED: with a fertilizer the undivided work area stays open; the centre alone does not shut the boom", areaActive(v), true)
end
do
  newWorld()
  for x = -15, 15, 2 do for z = -19, 23, 2 do setFull(x, z) end end
  VEH.bx, VEH.bz, VEH.hx, VEH.hz, VEH.heading = 0, -21, 0, 1, true
  local v = newSprayer()
  drive(v, 4)
  T.eq("U4 every nozzle reads full ground: the boom closes, as See & Spray intends", areaActive(v), false)
end
do
  local v = newSprayer()
  v[SPEC].centerActive, v[SPEC].anyNozzleActive = false, true
  v.spec_sprayer.workAreaParameters.sprayFillType = INS.index
  T.eq("U5 INSECTICIDE (a See & Spray chemical with a fertilizer profile): the centre still decides an undivided boom", areaActive(v), false)
  v.spec_sprayer.workAreaParameters.sprayFillType = LF.index
  v[SPEC].centerSectionIndex = 4
  T.eq("U6 a sectioned boom's real centre section with a fertilizer: still the centre's decision",
       SFNozzleEffects.getIsWorkAreaActive(v, function() return true end, { sectionIndex = 4 }), false)
  T.eq("U7 an undivided work area with a fertilizer while some nozzle is open: open", areaActive(v), true)
end
