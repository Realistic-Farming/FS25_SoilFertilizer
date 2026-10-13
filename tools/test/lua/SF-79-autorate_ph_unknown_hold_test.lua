-- SF-79-autorate_ph_unknown_hold_test.lua: AUTO rate on a field with no current pH report.
--
-- THE DEFECT (a player's freeze on the development build, 2026-09-28). SF-79 slice 4
-- (7f1f0c75) made getFieldInfo's pH nil when a field has no current pH report ("No
-- unknown-to-7.0"). The client AUTO rate path was not adapted: calculateAutoRateIndex
-- computed `targets.pH - fieldData.pH` for any product with a pH profile (LIME,
-- LIQUIDLIME), threw "attempt to perform arithmetic (sub) on number and nil", and the
-- throw aborted the frame's remaining update listeners every 5 s while the player limed.
--
-- THE CONTRACT, SF-79 section D:
--   :82 "All affected numeric consumers must be adapted with this contract": the pH
--       term enters only for a known pH, weight and deficit both; nothing stands in.
--   :78 "An unavailable required sample retains the selected rate": a product sized by
--       pH alone, on a field whose pH is unknown, keeps the rate the player had. It is
--       not reset to 1.0x, and nothing is sent.
--
-- THE ENTRY-POINT BAR IS THIS WHOLE FILE. Every row drives SoilFertilityManager:update,
-- the listener production calls every frame, past the real 5 s throttle. The system is
-- SoilFertilitySystem.new; the pH comes from the real getFieldInfo -> _ensurePHReport
-- path, over farmland polygons the real _getFarmlandPolygons resolves from the field
-- manager's polygon nodes. No row sets fieldData.pH, a report, or a polygon by hand.
-- What the fixture supplies is the world: the engine's value-map read
-- (readAverageRawInBand, which here reports written pixels only under field 134), the
-- field manager's polygon nodes, the player in a vehicle, the vehicle's fill units,
-- the HUD's detected field id, and the network send (recorded, not performed).
--
-- The world:
--   field 133: polygon present, no pH pixel written  -> report EMPTY       -> pH nil
--   field 135: no field polygon on the farmland      -> report UNAVAILABLE -> pH nil
--   field 134: polygon present, pH written at 5.6    -> report CURRENT     -> pH 5.6
--
-- Row expectations are literals from the formula at SoilFertilityManager.lua (the map
-- [0, 1] deficit -> 0.20x + deficit * 1.00x, clamped to [0.20, 1.20], nearest STEPS index):
--   LIME / LIQUIDLIME on pH 5.6: deficit (6.5 - 5.6) / (6.5 - 5.0) = 0.6 -> 0.80x -> index 8.
--   UREA with N 40, no crop:     deficit (80 - 40) / 80 = 0.5         -> 0.70x -> index 7.
-- Targets: AUTO_RATE_TARGETS pH 6.5, N 80 (Constants.lua); PH_MIN 5.0 (NUTRIENT_LIMITS).
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/SoilContextInput.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua, src/SprayerRateManager.lua, src/ui/SoilHUD.lua, src/SoilFertilityManager.lua

FillType = FillType or { UNKNOWN = 0 }

-- ── the engine boundary: polygon nodes to coordinates ──
local NODES = {}
getWorldTranslation = function(n)
  local p = NODES[n]
  if p == nil then return 0, 0, 0 end
  return p.x, 0, p.z
end
local nextNode = 1000
local function square(x0, z0, size)
  local ids = {}
  for _, c in ipairs({ { x0, z0 }, { x0 + size, z0 }, { x0 + size, z0 + size }, { x0, z0 + size } }) do
    nextNode = nextNode + 1
    NODES[nextNode] = { x = c[1], z = c[2] }
    ids[#ids + 1] = nextNode
  end
  return ids
end

-- Field manager: farmlands 133 and 134 carry a field polygon; 135 carries none.
g_fieldManager = { fields = {
  { farmland = { id = 133 }, polygonPoints = square(0, 0, 100) },
  { farmland = { id = 134 }, polygonPoints = square(200, 0, 100) },
} }

-- ── the value map: written pH pixels only under field 134's polygon (x >= 200) ──
local PH_WRITTEN = 5.6
local VM_READS = 0
local function newValueMaps()
  return {
    available = true,
    readAverageRawInBand = function(_, key, verts, lo, hi)
      VM_READS = VM_READS + 1
      if key ~= PositionalPH.PH_LAYER then return nil, 0 end
      if verts[1].x >= 200 then
        local raw = PositionalPH.phRaw(PH_WRITTEN, PositionalPH.phDef())
        if raw >= lo and raw <= hi then return raw, 400 end
      end
      return nil, 0
    end,
    readValueAtWorld = function() return nil end,
  }
end

-- ── fill types, and a self-propelled applicator carrying one product ──
local FT = { DIESEL = 11, LIME = 21, LIQUIDLIME = 22, UREA = 23 }
local byIndex = {}
for name, idx in pairs(FT) do byIndex[idx] = { name = name, index = idx } end
g_fillTypeManager = { getFillTypeByIndex = function(_, idx) return byIndex[idx] end }

local function applicator(id, product)
  local v = { id = id, spec_fillUnit = { fillUnits = {
                { fillType = FT.DIESEL, fillLevel = 100 },
                { fillType = FT[product], fillLevel = 1000 } } },
              spec_attacherJoints = { attachedImplements = {} } }
  v.rootVehicle = v
  v.getFillUnits = function(self) return self.spec_fillUnit.fillUnits end
  v.getFillUnitFillType = function(self, i) local u = self.spec_fillUnit.fillUnits[i]; return u and u.fillType or nil end
  v.getFillUnitFillLevel = function(self, i) local u = self.spec_fillUnit.fillUnits[i]; return u and u.fillLevel or 0 end
  v.getAttachedImplements = function(self) return self.spec_attacherJoints.attachedImplements end
  return v
end

-- ── the network send: recorded, not performed ──
local SENDS = {}
SoilNetworkEvents_SendSprayerRate = function(vehicle, idx) SENDS[#SENDS + 1] = { id = vehicle.id, idx = idx } end

-- ── the debug trace, read as the player's log would carry it ──
local DBG = {}
local origDebug = SoilLogger.debug
SoilLogger.debug = function(msg, ...)
  local ok, line = pcall(string.format, msg, ...)
  DBG[#DBG + 1] = ok and line or msg
  return origDebug(msg, ...)
end
local function tracedSince(mark, needle)
  for i = mark + 1, #DBG do
    if string.find(DBG[i], needle, 1, true) then return DBG[i] end
  end
  return nil
end

-- ── the world: one client (a single-player host), the mod running, AUTO on ──
local W = {}
local function world(opts)
  opts = opts or {}
  local settings = { enabled = true, autoRateControl = true, debugMode = true }
  local sys = SoilFertilitySystem.new(settings)
  sys.valueMaps = newValueMaps()
  local hud = setmetatable({ settings = settings, cachedFieldId = nil,
                             -- The HUD's own per-frame refresh is not under test; its
                             -- output, cachedFieldId, is what updateAutoRates reads.
                             update = function() end }, { __index = SoilHUD })
  local mgr = setmetatable({
    settings = settings, soilSystem = sys, soilHUD = hud,
    sprayerRateManager = SprayerRateManager.new(), _autoRateTimer = 0,
    _deferredInitDone = true,
  }, { __index = SoilFertilityManager })
  g_SoilFertilityManager = mgr
  g_currentMission = {
    time = 1000, isMissionStarted = true,
    environment = { currentDay = 1, daysPerPeriod = 1 },
    missionInfo = {}, missionDynamicInfo = { isMultiplayer = false },
    getIsClient = function() return true end,
    getIsServer = function() return opts.server == true end,
  }
  local vehicle = applicator(7, opts.product or "LIQUIDLIME")
  g_localPlayer = { getIsInVehicle = function() return true end, getCurrentVehicle = function() return vehicle end }
  mgr.sprayerRateManager:setAutoMode(vehicle.id, true)
  W.sys, W.mgr, W.hud, W.vehicle = sys, mgr, hud, vehicle
  return mgr
end
local function onField(fieldId) W.hud.cachedFieldId = fieldId end
local function setRate(idx) W.mgr.sprayerRateManager.vehicleRates[W.vehicle.id] = idx end
local function rate() return W.mgr.sprayerRateManager:getIndex(W.vehicle.id) end
local function load(product) W.vehicle.spec_fillUnit.fillUnits[2].fillType = FT[product] end
--- One throttle period of production's per-frame listener. Returns ok, err.
local function tick() return pcall(W.mgr.update, W.mgr, 5000) end

-- =====================================================================
-- GROUP P: the world is what it says. The nil comes from the report path.
-- =====================================================================
world()
do
  local i133 = W.sys:getFieldInfo(133)
  local i135 = W.sys:getFieldInfo(135)
  local i134 = W.sys:getFieldInfo(134)
  T.eq("P1: field 133 (polygon, nothing written) reads pH nil through getFieldInfo", i133 and i133.pH, nil)
  T.eq("P2: ... with the report EMPTY", W.sys.fieldData[133]._phReport and W.sys.fieldData[133]._phReport.status, PositionalPH.REPORT_EMPTY)
  T.eq("P3: field 135 (no field polygon) reads pH nil", i135 and i135.pH, nil)
  T.eq("P4: ... with the report UNAVAILABLE", W.sys.fieldData[135]._phReport and W.sys.fieldData[135]._phReport.status, PositionalPH.REPORT_UNAVAILABLE)
  T.near("P5: field 134 (written) reads its pH through the same path", i134 and i134.pH, PH_WRITTEN, 0.02)
  T.ok("P6: the value map was actually read (the report was derived, not assumed)", VM_READS > 0, "reads " .. VM_READS)
end

-- =====================================================================
-- GROUP A1: LIQUIDLIME on a field whose pH is unknown. No throw, rate held.
-- =====================================================================
world({ product = "LIQUIDLIME" })
onField(133)
setRate(6)   -- 0.60x: a player's own choice, not the default 1.0x
do
  local mark, sends = #DBG, #SENDS
  local ok, err = tick()
  T.ok("A1a: update runs without error on a field with no current pH report (EMPTY)", ok, tostring(err))
  T.eq("A1b: the selected rate is held at 0.60x (index 6), not reset to 1.0x (index 10)", rate(), 6)
  T.eq("A1c: nothing is sent to the server", #SENDS - sends, 0)
  local line = tracedSince(mark, "pH unknown, rate held")
  T.ok("A1d: the debug trace says the pH is unknown and the rate is held", line ~= nil, "no such line")
  T.ok("A1e: ... and names field 133", line ~= nil and string.find(line, "field 133", 1, true) ~= nil, tostring(line))
end
do
  local ok, err = tick()
  T.ok("A1f: the next throttle period is just as quiet (no throw)", ok, tostring(err))
  T.eq("A1g: ... and still holds index 6", rate(), 6)
end
onField(135)
do
  local sends = #SENDS
  local ok, err = tick()
  T.ok("A1h: a farmland with no field polygon (UNAVAILABLE): no throw", ok, tostring(err))
  T.eq("A1i: ... rate held at index 6", rate(), 6)
  T.eq("A1j: ... nothing sent", #SENDS - sends, 0)
end

-- =====================================================================
-- GROUP A2: the control. The pH term still works where the pH is known.
-- =====================================================================
onField(134)
do
  local sends = #SENDS
  local ok, err = tick()
  T.ok("A2a: LIQUIDLIME on field 134 (pH 5.6 CURRENT): no throw", ok, tostring(err))
  T.eq("A2b: AUTO moves the rate to 0.80x (index 8) from the pH deficit", rate(), 8)
  T.eq("A2c: ... and sends it once", #SENDS - sends, 1)
  T.eq("A2d: ... with index 8", SENDS[#SENDS] and SENDS[#SENDS].idx, 8)
end
-- Back onto the unknown field: the rate AUTO just chose is the one held.
onField(133)
do
  local sends = #SENDS
  local ok, err = tick()
  T.ok("A2e: back on field 133: no throw", ok, tostring(err))
  T.eq("A2f: ... the rate AUTO chose on 134 (index 8) is held, not reset", rate(), 8)
  T.eq("A2g: ... nothing sent", #SENDS - sends, 0)
end

-- =====================================================================
-- GROUP A3: a nitrogen product on the unknown-pH field sizes by nitrogen as before.
-- =====================================================================
world({ product = "UREA" })
W.sys:getOrCreateField(133, true).nitrogen = 40
onField(133)
setRate(6)
do
  local sends = #SENDS
  local ok, err = tick()
  T.ok("A3a: UREA on field 133 (pH unknown): no throw", ok, tostring(err))
  T.eq("A3b: AUTO sizes it by nitrogen: 0.70x (index 7)", rate(), 7)
  T.eq("A3c: ... and sends it", #SENDS - sends, 1)
end

-- =====================================================================
-- GROUP A4: LIME behaves as LIQUIDLIME.
-- =====================================================================
world({ product = "LIME" })
onField(133)
setRate(13)   -- 1.30x
do
  local sends = #SENDS
  local ok, err = tick()
  T.ok("A4a: LIME on field 133 (pH unknown): no throw", ok, tostring(err))
  T.eq("A4b: ... rate held at 1.30x (index 13)", rate(), 13)
  T.eq("A4c: ... nothing sent", #SENDS - sends, 0)
end
onField(134)
do
  local ok, err = tick()
  T.ok("A4d: LIME on field 134 (pH 5.6): no throw", ok, tostring(err))
  T.eq("A4e: ... AUTO moves it to 0.80x (index 8)", rate(), 8)
end

-- =====================================================================
-- GROUP A5: the same product switch in one vehicle. Loading UREA after a held
-- LIQUIDLIME pass sizes by nitrogen; loading LIQUIDLIME again holds.
-- =====================================================================
world({ product = "LIQUIDLIME" })
W.sys:getOrCreateField(133, true).nitrogen = 40
onField(133)
setRate(4)
do
  local ok = tick()
  T.eq("A5a: LIQUIDLIME on 133 holds index 4", ok and rate(), 4)
  load("UREA")
  ok = tick()
  T.eq("A5b: UREA loaded in the same vehicle: sized by nitrogen, index 7", ok and rate(), 7)
  load("LIQUIDLIME")
  ok = tick()
  T.eq("A5c: LIQUIDLIME again: the rate is held at index 7", ok and rate(), 7)
end
