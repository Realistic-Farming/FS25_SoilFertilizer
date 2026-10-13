-- SF-73-nozzle_effects_applying_spec_test.lua
--
-- Tyson's DAP report (2026-10-01, Bob's check BOB-CHECK-DAP-FIELD2-REFUSAL): Soil's nozzle
-- effects showed spray on a pass SF-73 had refused, with no product going down. The nozzle
-- visual turned on from turned on, speed, direction and an open section, never from whether
-- the engine painted. SF-73 truthful UI (b): the visual now also needs the engine's own
-- "is spraying" test (Sprayer:getAreEffectsVisible, Sprayer.lua:466-468: lastSprayTime +
-- 100 > g_time; lastSprayTime starts at -math.huge, :235, and is set only when
-- processSprayerArea paints, :335). On an MP client it also goes off on a received, current
-- target result that plans nothing.
--
-- THE ENTRY-POINT BAR. Every row runs the specialization's real onUpdate, the listener the
-- engine raises each frame (SpecializationUtil.raiseEvent), on a vehicle built the way the
-- engine builds one (the type's registered functions copied into the instance), which runs
-- the real sfUpdateNozzleEffectsState and sfUpdateNozzleEffectState and the real fade
-- animation. The engine is MODELED where Soil cannot supply it: Sprayer:getAreEffectsVisible
-- verbatim (:466-468), the paint as processSprayerArea's own write (:335), setShaderParameter
-- as a recorder. On the client the target result arrives through the real
-- TargetApplication:receive and is read through the soil system's real read contract.
--
-- The logic half is kept apart on purpose and pinned here (N1b): isActive, which the See &
-- Spray section gate and the usage scale read, must not wait for paint, since paint needs
-- the section open.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua, src/specializations/SFNozzleEffects.lua

SoilLogger.debug = function() end
SoilLogger.info = function() end

-- ── the engine, modeled ─────────────────────────────────────────────────────
Sprayer = Sprayer or {}
function Sprayer:getAreEffectsVisible()                       -- Sprayer.lua:466-468, verbatim
  return self.spec_sprayer.workAreaParameters.lastSprayTime + 100 > g_time
end
local function enginePaints(v)                                 -- processSprayerArea's write, :335
  v.spec_sprayer.workAreaParameters.lastSprayTime = g_time
end
local SHADER = {}
setShaderParameter = function(node, name, a, b) SHADER[node] = { name = name, a = a, b = b } end
getWorldTranslation = getWorldTranslation or function() return 0, 0, 0 end

local STATE_OFF, STATE_ON, STATE_TURNING_ON, STATE_TURNING_OFF = 0, 1, 2, 3
local SPEC = SFNozzleEffects.SPEC_TABLE_NAME

-- A sprayer the way the engine builds one: the type's registered functions copied into the
-- instance (the three SFNozzleEffects registers, registerFunctions), two boom sections, one
-- real effect node per section.
local function newSprayer()
  local v = { id = 4242, isServer = true, rootNode = 1, movingDirection = 1, turnedOn = true, speed = 8 }
  v.getIsTurnedOn = function(self) return self.turnedOn end
  v.getLastSpeed = function(self) return self.speed end
  v.sfGetNumNozzleEffectsActive = SFNozzleEffects.sfGetNumNozzleEffectsActive
  v.sfUpdateNozzleEffectsState = SFNozzleEffects.sfUpdateNozzleEffectsState
  v.sfUpdateNozzleEffectState = SFNozzleEffects.sfUpdateNozzleEffectState
  v.spec_sprayer = { workAreaParameters = { lastSprayTime = -math.huge, sprayFillType = 0 } }   -- :235
  v.spec_variableWorkWidth = { sections = { [1] = { isActive = true }, [2] = { isActive = true } } }
  local function effect(section, node)
    return { effectNode = node, probeNode = nil, fadeCur = { 1, -1 }, fadeDir = SFNozzleEffects.FADE_DIR_OFF,
             state = STATE_OFF, sectionIndex = section, isActive = false }
  end
  v[SPEC] = { hasCustomEffects = true, hasRealEffects = true, numCustomEffects = 2,
              sprayerEffects = { effect(1, 101), effect(2, 102) }, sprayerEffectsBySection = {},
              _effectsPending = false, _sfFieldTimer = 0 }
  return v
end
local function frame(v, dt)
  g_time = g_time + (dt or 16)
  SFNozzleEffects.onUpdate(v, dt or 16, false, false, false)
end
local function e(v, i) return v[SPEC].sprayerEffects[i] end
local function shown(v, i) local ed = e(v, i) return ed.state == STATE_ON or ed.state == STATE_TURNING_ON end

local function serverWorld()
  g_server = {}
  g_time = 100000
  g_currentMission = { time = 100000 }
  local ss = setmetatable({ fieldData = {}, settings = { enabled = true } }, { __index = SoilFertilitySystem })
  ss.targetApplication = TargetApplication.new(ss)
  g_SoilFertilityManager = { settings = ss.settings, soilSystem = ss }
  return ss
end

-- =====================================================================
-- N. THE HOST: the visual follows the engine's paint
-- =====================================================================
do
  serverWorld()
  local v = newSprayer()
  frame(v)
  T.eq("N1 turned on, moving forward, both sections open, nothing painted (a refused cycle): no nozzle shows spray",
       tostring(shown(v, 1)) .. "/" .. tostring(shown(v, 2)), "false/false")
  T.eq("N1b NAMED: the See & Spray decision is NOT gated on paint: both nozzles stay active, the section aggregate open, the usage scale whole",
       tostring(e(v, 1).isActive) .. "/" .. tostring(v[SPEC].sectionActive[1]) .. "/" .. select(2, v:sfGetNumNozzleEffectsActive()), "true/true/1.0")
  enginePaints(v)
  frame(v)
  T.eq("N2 the engine paints (processSprayerArea :335): both nozzles turn on", tostring(shown(v, 1)) .. "/" .. tostring(shown(v, 2)), "true/true")
  for _ = 1, 40 do enginePaints(v) frame(v) end   -- a full fade is 2 x FADE_TIME (500 ms)
  T.eq("N3 painting on: the fade completes to ON and the shader carries it", tostring(e(v, 1).state == STATE_ON) .. "/" .. tostring(SHADER[101] and SHADER[101].b), "true/1")
  frame(v, 150)
  T.eq("N4 paint stops (150 ms > the engine's 100 ms window): both nozzles turn off", tostring(e(v, 1).state) .. "/" .. tostring(e(v, 2).state), STATE_TURNING_OFF .. "/" .. STATE_TURNING_OFF)
  v.spec_variableWorkWidth.sections[2].isActive = false
  enginePaints(v)
  frame(v)
  T.eq("N5 painting, section 2 switched off: section 1 shows, section 2 does not (as today)", tostring(shown(v, 1)) .. "/" .. tostring(shown(v, 2)), "true/false")
  v.spec_variableWorkWidth.sections[2].isActive = true
  v.turnedOn = false
  enginePaints(v)
  frame(v)
  T.eq("N6 painting but turned off: nothing shows (as today)", tostring(shown(v, 1)) .. "/" .. tostring(shown(v, 2)), "false/false")
end

-- =====================================================================
-- C. AN MP CLIENT: it paints locally, the server's target result decides
-- =====================================================================
local function result(active, planned, seq)
  return { schema = TargetNutrientCore.SCHEMA, epoch = "1", sequence = seq, active = active, plannedLitres = planned,
           doseState = planned > 0 and "REACHED" or "UNDETERMINED", reasons = {} }
end
do
  local ss = serverWorld()
  g_server = nil
  local v = newSprayer()
  v.isServer = false
  enginePaints(v)
  frame(v)
  T.eq("C1 a client that paints locally with no target result: the nozzles show (as today)", tostring(shown(v, 1)), "true")
  T.eq("C2 [reached] the real receive takes the server's refused target result (active, nothing planned)", ss.targetApplication:receive(v, result(true, 0, "1")), true)
  enginePaints(v)
  frame(v)
  T.eq("C3 NAMED: a client painting locally on a pass the server refused shows no spray", tostring(shown(v, 1)) .. "/" .. tostring(shown(v, 2)), "false/false")
  ss.targetApplication:receive(v, result(true, 12, "2"))
  enginePaints(v)
  frame(v)
  T.eq("C4 the next result plans a dose: the nozzles show again", tostring(shown(v, 1)) .. "/" .. tostring(shown(v, 2)), "true/true")
  ss.targetApplication:receive(v, result(false, 0, "3"))
  enginePaints(v)
  frame(v)
  T.eq("C5 target mode left (an inactive result): the local paint decides, the nozzles show", tostring(shown(v, 1)), "true")
  ss.targetApplication:receive(v, result(true, 0, "4"))
  g_currentMission.time = g_currentMission.time + TargetApplication.RESULT_EXPIRY_MS
  enginePaints(v)
  frame(v)
  T.eq("C6 a refused result past its expiry is no answer: the local paint decides again", tostring(shown(v, 1)), "true")
end
