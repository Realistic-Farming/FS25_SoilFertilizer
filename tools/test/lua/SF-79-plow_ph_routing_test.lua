-- SF-79-plow_ph_routing_test.lua: the plow's pH normalisation goes through the
-- positional writer, and the consequence that made it a player-visible loss.
--
-- THE DEFECT. SoilFertilitySystem:onPlowing computed a normalisation toward 7.0 and
-- wrote field.pH directly. The map never learned. _phRefreshScalar sets field.pH
-- from the map-derived report whenever that report is current, and it runs after
-- every application write, so the NEXT SPRAY PASS overwrote the scalar from a
-- report that never saw the plow: the plow's pH effect was discarded. SF-79 section
-- C names the plow among the farming writers and gives the magnitude, "Plow targets
-- 7.0 at existing intensity 0.1 * clampedAcceptedAreaHa / footprintAreaHa"; the
-- number was implemented and the routing was not.
--
-- Group A drives the REAL onPlowing with the writer spied: the call carries the
-- brief's operation, magnitude, equal 7.0 bounds and source token, and the scalar is
-- no longer written directly. Group B drives the REAL onPlowing with the writer
-- absent: the scalar fallback is today's arithmetic, unchanged. Group C loads the
-- REAL PositionalPH so _phApplyField and _phRefreshScalar are real, stubs only the
-- map (the footprint and the report), and shows the consequence: a direct scalar
-- write is erased by the next refresh, a routed one survives it.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua

local savedEnv = g_currentMission.environment
g_currentMission.environment = { currentDay = 5 }

local function newSys(opts)
  opts = opts or {}
  local s = setmetatable({
    settings = { enabled = true, plowingBonus = opts.plowingBonus ~= false, weedPressure = false,
                 pestPressure = false, diseasePressure = false, residueIncorporation = false },
    fieldData = { [3] = { fieldArea = 2.0, pH = opts.pH or 6.0, organicMatter = 3.0, nitrogen = 50,
                          phosphorus = 50, potassium = 50, sessionCoverageCells = {} } },
    valueMaps = nil,
  }, { __index = SoilFertilitySystem })
  s._plowAreaToday = {}
  return s
end

-- =====================================================================
-- GROUP A: the REAL onPlowing, the writer spied.
-- =====================================================================
do
  local s = newSys()
  local calls = {}
  s._phApplyField = function(_self, fieldId, op, value, low, high, source)
    calls[#calls + 1] = { fieldId = fieldId, op = op, value = value, low = low, high = high, source = source }
  end
  s:onPlowing(3, 0.5, false, 0)       -- 0.5 ha accepted on a 2.0 ha field: factor 0.25
  T.eq("PLOW A1: the writer is called once", #calls, 1)
  T.eq("PLOW A2: for the plowed field", calls[1].fieldId, 3)
  T.eq("PLOW A3: as a NORMALIZE", calls[1].op, PositionalPH.OP_NORMALIZE)
  T.near("PLOW A4: at the brief's intensity, 0.1 x accepted/field hectares", calls[1].value, 0.1 * 0.25, 1e-12)
  T.eq("PLOW A5: toward equal 7.0 bounds", calls[1].low == 7.0 and calls[1].high == 7.0, true)
  T.eq("PLOW A6: with its own source token", calls[1].source, "plow")
  T.eq("PLOW A7: and the scalar is NOT written directly any more (the spy did not refresh it)", s.fieldData[3].pH, 6.0)
end
do
  local s = newSys({ pH = 7.5 })
  local calls = {}
  s._phApplyField = function(_self, fieldId, op, value, low, high, source) calls[#calls + 1] = { value = value } end
  s:onPlowing(3, 2.0, false, 0)       -- the whole field: factor 1.0
  T.near("PLOW A8: a whole-field plow asks for the full 0.1 step", calls[1].value, 0.1, 1e-12)
  T.eq("PLOW A9: above 7.0 the same NORMALIZE serves (the writer moves toward the band from either side)", #calls, 1)
end
do
  local s = newSys()
  local calls = {}
  s._phApplyField = function() calls[#calls + 1] = true end
  s:onPlowing(3, 2.0, false, 0)       -- uses the whole daily area
  s:onPlowing(3, 0.5, false, 0)       -- beyond the daily cap: clamped to nothing
  T.eq("PLOW A10: the existing daily area cap still gates the writer (second plow over the cap asks nothing)", #calls, 1)
end
do
  local s = newSys({ plowingBonus = false })
  local calls = {}
  s._phApplyField = function() calls[#calls + 1] = true end
  s:onPlowing(3, 0.5, false, 0)
  T.eq("PLOW A11: plowingBonus off: no pH write at all, as before", #calls, 0)
  T.eq("PLOW A12: and the scalar untouched", s.fieldData[3].pH, 6.0)
end

-- =====================================================================
-- GROUP B: the REAL onPlowing with the writer absent: today's scalar fallback.
-- =====================================================================
local function plowWithout(pH, area)
  local s = newSys({ pH = pH })
  s._phApplyField = false            -- shadow the loaded method: a system without the writer
  s:onPlowing(3, area, false, 0)
  return s.fieldData[3].pH
end
T.near("PLOW B1: below 7 moves up by 0.1 x factor",  plowWithout(6.0, 0.5), 6.025, 1e-12)
T.near("PLOW B2: above 7 moves down by 0.1 x factor", plowWithout(7.5, 0.5), 7.475, 1e-12)
T.eq("PLOW B3: at 7 stays",                         plowWithout(7.0, 0.5), 7.0)
T.near("PLOW B4: within one step of 7 lands on 7",   plowWithout(6.99, 2.0), 7.0, 1e-12)

-- =====================================================================
-- GROUP C: the consequence, with the REAL _phApplyField and _phRefreshScalar and a
-- stubbed map. The report is what the map says; a direct scalar write never reaches it.
-- =====================================================================
local function newRoutedSys(pH)
  local s = newSys({ pH = pH })
  local map = { value = pH, footprints = {} }
  -- The map: a NORMALIZE footprint moves the map's value toward its band by the step.
  s._applyPHFootprint = function(_self, fieldId, req)
    map.footprints[#map.footprints + 1] = req
    if req.operation == PositionalPH.OP_NORMALIZE then
      local v, lo, hi, step = map.value, req.targetLow, req.targetHigh, req.value
      if v < lo then map.value = math.min(lo, v + step) elseif v > hi then map.value = math.max(hi, v - step) end
    elseif req.operation == PositionalPH.OP_DELTA then
      map.value = map.value + req.value
    end
    return { status = PositionalPH.STATUS_APPLIED }
  end
  -- The report: current, and it says what the map says.
  s._ensurePHReport = function() return { status = PositionalPH.REPORT_CURRENT, value = map.value } end
  s._phFieldPolygons = function() return { { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 } } } end
  return s, map
end
do
  -- THE OLD SHAPE, simulated: a direct scalar write, then the refresh an application
  -- performs. The plow's change is erased.
  local s, map = newRoutedSys(6.0)
  s.fieldData[3].pH = 6.025            -- what onPlowing used to do
  s:_phRefreshScalar(3)                -- what the next spray does
  T.eq("PLOW C1: a direct scalar write is ERASED by the next refresh (the defect)", s.fieldData[3].pH, 6.0)
  T.eq("PLOW C2: because the map never saw it", #map.footprints, 0)
end
do
  -- THE NEW SHAPE: the real onPlowing routes through the real writer; the map moves;
  -- the refresh republishes the moved value, and a second refresh keeps it.
  local s, map = newRoutedSys(6.0)
  s:onPlowing(3, 0.5, false, 0)
  T.ok("PLOW C3: the plow reached the map (a footprint was written or banked)", #map.footprints >= 1 or (s.fieldData[3]._phPending ~= nil))
  local afterPlow = s.fieldData[3].pH
  T.ok("PLOW C4: the scalar moved toward 7.0 through the report", afterPlow > 6.0 and afterPlow <= 6.025 + 1e-9)
  s:_phRefreshScalar(3)                -- the next spray's refresh
  T.eq("PLOW C5: and SURVIVES the next refresh, because the map carries it", s.fieldData[3].pH, afterPlow)
  T.eq("PLOW C6: the footprint was a NORMALIZE toward 7.0 from the plow", map.footprints[1].operation == PositionalPH.OP_NORMALIZE and map.footprints[1].targetLow == 7.0 and map.footprints[1].source == "plow", true)
end

g_currentMission.environment = savedEnv
