-- SF-2m-compaction_entry_test.lua - compaction moves from 10 m zone cells to the 2 m
-- value-map pixel grid (step 2), plus the same-session anchor fix: a vehicle moving
-- under MIN_MOVE_DISTANCE_M (2 m) a sample now keeps its stored position instead of
-- sliding it every sample, so it still lays its strip once real travel accumulates.
--
-- WHAT IS MODELLED (the engine is not available to this harness):
--   * The 2 m value-map pixel raster (self.valueMaps) is OUR OWN table, not the real
--     SoilValueMaps.lua (which drives native createBitVectorMap/DensityMapModifier
--     calls this harness cannot run). It honours the same documented contract:
--       - readValueAtWorld decodes the pixel under the point (raw 0 = nil, else the
--         linear 8-bit decode SoilValueMaps.lua's header documents: raw 1..255 over
--         [minVal,maxVal], here 0..100 for compaction).
--       - writeValueAtWorld sets every pixel whose CENTRE lies in the square of
--         half-size `radius` around the point (one write = one SET, matching
--         SoilValueMaps:writeValueAtWorld's setParallelogramWorldCoords+executeSet).
--       - applyRawDeltaToPolygonBand adds `rawDelta` to every pixel whose centre lies
--         in the polygon AND whose CURRENT raw lies in [lo,hi], with the floor/
--         saturate edge pass run first on the sub-band the add would overshoot
--         (SoilValueMaps.lua:1358-1419's aimedWindows two-pass shape, transcribed by
--         hand here, not called).
--     Pixel-membership (point-in-polygon) is this file's own ray-casting copy, never
--     PositionalPH's, so it cannot agree with production by sharing a helper. The real
--     PositionalPH.centresInQuad (loaded, unmodified) still DRIVES which pixels
--     compactStrip/relieveCompactionInQuad touch - this file predicts that set by hand
--     from the geometry and compares against the raster's observed state.
--   * HookManager:getFieldIdAtWorldPosition is overridden per-instance (a fixed field
--     id, or nil outside a bound) instead of running the real MapDataGrid/native path -
--     a field-id LOOKUP is not what this change touches.
--   * Utils.appendedFunction/overwrittenFunction are the engine's own bodies, transcribed
--     from utils/Utils.lua:380-401 (the same transcription MAINT-302's bench uses).
--   * TrafficDrag is left unloaded (nil): SoilFertilityManager's traffic-drag paint
--     short-circuits to a no-op when the module is absent, which this change does not
--     touch, so modelling it here would only add noise.
--   * SoilCompactionModel.pointsForVehicle is stubbed per vehicle (a fixed points value)
--     so the strip width/anchor/day-gate math is tested on a known input, not re-proving
--     the ground-pressure formula compaction_test.lua already guards.
--
-- ENTRY POINTS (production's real functions):
--   T*  SoilFertilityManager:_checkOneVehicleCompaction (sampled vehicle positions, the
--       1 s cadence CHECK_INTERVAL_MS names) -> SoilFertilitySystem:compactStrip.
--   R*  The REAL Cultivator/Plow/Weeder.onEndWorkAreaProcessing wrappers installed by
--       HookManager:installPlowingHook / installDedicatedPlowHook / installWeederHook,
--       invoked exactly as the engine invokes them -> relieveCompactionInQuad.
--   D*  SoilFertilitySystem:_applyCompactionDecay (D1, the full daily entry incl. the
--       held-ratio gate) and :_compactionMapFade (D2-D4, the banded-pass primitive
--       _applyCompactionDecay calls once the held ratio crosses MAP_DECAY_STEP - called
--       directly so the banding edge cases are reachable without depending on
--       NATURAL_DECAY_PER_DAY's real cadence landing on an edge by chance).
--   L*  SoilFertilitySystem:loadFromXMLFile (L1-L3, with a minimal hand-built XML
--       fake answering only the keys read) and :applySoilStateTable (L4), both funnelled
--       through the real :_finalizeLoadedField.
--   P*  SpatialPressures:run and EstablishmentFailure:_checkEstablishingField.
--
-- Groups: T traffic strip laying, R tool relief, D decay/map-fade, L load, P readers.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/maps/SoilValueMaps.lua, src/SoilCompactionModel.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/SoilFertilityManager.lua, src/hooks/HookManager.lua, src/SpatialPressures.lua, src/EstablishmentFailure.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group crashed: " .. tostring(err) .. "]", false) end
end

-- =====================================================================
-- Engine stand-ins (transcribed, never called from production)
-- =====================================================================
Utils = Utils or {}
function Utils.appendedFunction(oldFunc, newFunc)
  return oldFunc ~= nil and function(...)
    oldFunc(...)
    return newFunc(...)
  end or newFunc
end

WorkAreaType = WorkAreaType or { AUXILIARY = 2, CUTTER = 1, CULTIVATOR = 3 }
MathUtil = MathUtil or {}
function MathUtil.areaToHa(pixels, sqmPerPixel) return (pixels or 0) * (sqmPerPixel or 1) / 10000 end

-- One global world-translation reader: every "node" in this file is a plain
-- { x=, y=, z= } table (vehicle roots, work-area start/width/height points).
_G.getWorldTranslation = function(node)
  if type(node) == "table" then return node.x, node.y or 0, node.z end
  return nil
end

g_currentMission = { environment = { currentDay = 1 } }
function g_currentMission:getIsServer() return true end
g_currentMission.getFruitPixelsToSqm = function() return 1 end

-- Default: every point is real field ground. T6 narrows this per-row.
FSDensityMapUtil = { getFieldDataAtWorldPosition = function(x, y, z) return true end }

-- =====================================================================
-- The modelled 2 m pixel raster (see header: what is modelled, and why)
-- =====================================================================
local GRAIN, TERRAIN = 2, 2048
local HALF = TERRAIN / 2
local N = TERRAIN / GRAIN
local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX   -- 1, 255
local RAW_SPAN = RMAX - RMIN
local MINV, MAXV = 0, 100   -- the compaction layer's own def (Constants/SoilValueMaps)

local function encodeC(v)
  local clamped = math.max(MINV, math.min(MAXV, v))
  local fraction = (clamped - MINV) / (MAXV - MINV)
  return RMIN + math.floor(fraction * RAW_SPAN + 0.5)
end
local function decodeC(raw)
  if raw == nil or raw <= 0 then return nil end
  return MINV + (raw - RMIN) / RAW_SPAN * (MAXV - MINV)
end

-- Pixel column/row for a world coordinate (matches centresInQuad's own centre
-- formula: cx = -half + (i+0.5)*grain, so pixel i spans [-half+i*g, -half+(i+1)*g)).
local function pixCol(x) return math.floor((x + HALF) / GRAIN) end
local function pixelCentre(i) return -HALF + (i + 0.5) * GRAIN end

local function pointInPoly(poly, x, z)
  local inside = false
  local n = #poly
  local j = n
  for i = 1, n do
    local pi, pj = poly[i], poly[j]
    if (pi.z > z) ~= (pj.z > z)
        and x < (pj.x - pi.x) * (z - pi.z) / (pj.z - pi.z) + pi.x then
      inside = not inside
    end
    j = i
  end
  return inside
end

local function newVM()
  local vm = { available = true, terrainSize = TERRAIN, raw = {} }
  function vm:getGrainMetres() return GRAIN end
  function vm:readValueAtWorld(key, x, z)
    local i, j = pixCol(x), pixCol(z)
    if i < 0 or i >= N or j < 0 or j >= N then return nil end
    return decodeC(self.raw[j * N + i])
  end
  function vm:writeValueAtWorld(key, x, z, value, radius)
    local r = radius or 1.5
    local rawV = encodeC(value)
    local i0, i1 = pixCol(x - r), pixCol(x + r)
    local j0, j1 = pixCol(z - r), pixCol(z + r)
    for j = math.max(0, j0), math.min(N - 1, j1) do
      for i = math.max(0, i0), math.min(N - 1, i1) do
        -- Only pixels whose CENTRE actually falls in the square (a quarter-pixel
        -- radius must not spill onto a neighbour).
        local cx, cz = pixelCentre(i), pixelCentre(j)
        if cx >= x - r and cx <= x + r and cz >= z - r and cz <= z + r then
          self.raw[j * N + i] = rawV
        end
      end
    end
  end
  function vm:_pixelsInPolygon(verts)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, v in ipairs(verts) do
      minX = math.min(minX, v.x); maxX = math.max(maxX, v.x)
      minZ = math.min(minZ, v.z); maxZ = math.max(maxZ, v.z)
    end
    local i0, i1 = math.max(0, pixCol(minX)), math.min(N - 1, pixCol(maxX))
    local j0, j1 = math.max(0, pixCol(minZ)), math.min(N - 1, pixCol(maxZ))
    local out = {}
    for j = j0, j1 do
      local cz = pixelCentre(j)
      for i = i0, i1 do
        local cx = pixelCentre(i)
        if pointInPoly(verts, cx, cz) then out[#out + 1] = { i = i, j = j } end
      end
    end
    return out
  end
  -- Mirrors SoilValueMaps:applyRawDeltaToPolygonBand's aimedWindows shape
  -- (SoilValueMaps.lua:1239-1256, 1358-1419): transcribed by hand, never called.
  function vm:applyRawDeltaToPolygonBand(key, verts, rawDelta, rawLow, rawHigh, opts)
    if not verts or #verts < 3 then return nil end
    rawDelta = math.floor(tonumber(rawDelta) or 0)
    if rawDelta == 0 then return 0 end
    rawLow = math.max(RMIN, math.floor(tonumber(rawLow) or RMIN))
    rawHigh = math.min(RMAX, math.floor(tonumber(rawHigh) or RMAX))
    if rawLow > rawHigh then return 0 end
    opts = opts or {}
    local addLow, addHigh, edgeLow, edgeHigh, edgeValue
    if rawDelta > 0 then
      edgeValue = math.min(RMAX, math.floor(tonumber(opts.saturateTo) or RMAX))
      addLow = rawLow
      addHigh = math.min(rawHigh, RMAX - rawDelta)
      edgeLow = math.max(rawLow, RMAX - rawDelta + 1)
      edgeHigh = rawHigh
    else
      local mag = -rawDelta
      local floorRaw = math.max(RMIN, math.floor(tonumber(opts.floorTo) or RMIN))
      edgeValue = floorRaw
      addLow = math.max(rawLow, floorRaw + mag)
      addHigh = rawHigh
      edgeLow = math.max(rawLow, floorRaw)
      edgeHigh = math.min(rawHigh, floorRaw + mag - 1)
    end
    if addLow and addLow > addHigh then addLow, addHigh = nil, nil end
    if edgeLow and edgeLow > edgeHigh then edgeLow, edgeHigh = nil, nil end
    if addLow == nil and edgeLow == nil then return 0 end
    local count = 0
    for _, p in ipairs(self:_pixelsInPolygon(verts)) do
      local idx = p.j * N + p.i
      local cur = self.raw[idx]
      if cur ~= nil then
        if edgeLow and cur >= edgeLow and cur <= edgeHigh then
          self.raw[idx] = edgeValue; count = count + 1
        elseif addLow and cur >= addLow and cur <= addHigh then
          self.raw[idx] = cur + rawDelta; count = count + 1
        end
      end
    end
    return count
  end
  return vm
end

-- =====================================================================
-- System / manager / vehicle builders
-- =====================================================================
local FID = 5

local function newField(areaHa)
  return {
    fieldArea = areaHa or 1.0,
    compaction = 0, compactionSum = 0, compactionTotalCells = 0,
  }
end

local function newHookManager(fieldIdFn)
  local hm = HookManager.new()
  hm.getFieldIdAtWorldPosition = function(_self, x, z, _skip) return fieldIdFn(x, z) end
  hm._recordTillagePoint = function() end
  return hm
end

local function newSys(vm, hm, field)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { compactionEnabled = true }
  s.fieldData = { [FID] = field or newField(1.0) }
  s.valueMaps = vm
  s.hookManager = hm
  s.layerSystem = nil
  -- Ancillary tillage/harvest accounting is not under test here.
  s.onPlowing = function() end
  s.onCultivation = function() end
  s.onHarvest = function() end
  s.recordTillageTrailPoint = function() end
  s.recordHarvestTrailPoint = function() end
  return s
end

local function newMgr(sys)
  local m = setmetatable({}, { __index = SoilFertilityManager })
  m.settings = { compactionEnabled = true }
  m.soilSystem = sys
  m._soilWetness01 = 0
  return m
end

local function newVehicle(opts)
  opts = opts or {}
  local v = {
    id = opts.id or 1,
    rootNode = { x = opts.x or 0, y = 0, z = opts.z or 0 },
    spec_wheels = { wheels = { { physics = { hasGroundContact = true } } } },
  }
  if opts.width then v.size = { width = opts.width } end
  v._mass = opts.mass or 20
  v._points = opts.points or 1
  v._source = opts.source or "bench"
  v.getTotalMass = function(self) return self._mass end
  return v
end

SoilCompactionModel.pointsForVehicle = function(v, _wet) return v._points, v._source end

-- Drive the vehicle along `positions` ({x=,z=} list, [1] is the starting spot,
-- which only arms the anchor and lays nothing). Returns the list of per-step
-- return values from _checkOneVehicleCompaction.
local function drivePath(mgr, vehicle, positions)
  vehicle.rootNode.x, vehicle.rootNode.z = positions[1].x, positions[1].z
  local results = { mgr:_checkOneVehicleCompaction(vehicle) }
  for k = 2, #positions do
    vehicle.rootNode.x, vehicle.rootNode.z = positions[k].x, positions[k].z
    results[#results + 1] = mgr:_checkOneVehicleCompaction(vehicle)
  end
  return results
end

-- Hand-computed expected per-pixel value after N applications of `perPixel`
-- raw-quantised gains (what compactStrip's own write/read round-trip must show).
local function quantize(v) return decodeC(encodeC(v)) end

-- =====================================================================
-- T: traffic strip laying (SoilFertilityManager:_checkOneVehicleCompaction)
-- =====================================================================

-- T1: an isolated straight pass, W=3, 100 m along the x axis (z path = 0). points=1,
-- rate=1 (default settings idx 3) -> perPixel = 1*1*(10/3) = 3.3333.
group("T1 isolated pass", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local v = newVehicle({ x = 0, z = 0, width = 3, points = 1, mass = 20 })

  local pts = {}
  for x = 0, 100, 10 do pts[#pts + 1] = { x = x, z = 0 } end
  drivePath(m, v, pts)

  local wantRaw = encodeC(1 * 1 * (10 / 3))
  local wantVal = decodeC(wantRaw)

  -- Hand geometry: strip rectangle x in (0,100), z in (-1.5,1.5). Pixel centres
  -- are at odd integers (TERRAIN=2048, GRAIN=2 -> centre = -1023 + 2*i). z = -1,1
  -- are inside; x = 1,3,...,99 are inside (50 columns).
  local good, bad, insideCount = 0, 0, 0
  for x = 1, 99, 2 do
    for _, z in ipairs({ -1, 1 }) do
      insideCount = insideCount + 1
      local got = vm:readValueAtWorld("compaction", x, z)
      if got ~= nil and math.abs(got - wantVal) < 1e-9 then good = good + 1 else bad = bad + 1 end
    end
  end
  T.eq("T1 NAMED: every inside pixel gained exactly points*rate*(10/W) (quantised)", bad, 0)
  T.eq("T1 [reached: pixels checked]", insideCount, 100)

  -- Outside the strip: nothing touched, scanning a margin round the strip.
  local outsideTouched = 0
  for x = -11, 111, 2 do
    for _, z in ipairs({ -3, 3 }) do
      if vm:readValueAtWorld("compaction", x, z) ~= nil then outsideTouched = outsideTouched + 1 end
    end
  end
  for _, x in ipairs({ -11, -9, 101, 103 }) do
    if vm:readValueAtWorld("compaction", x, 1) ~= nil then outsideTouched = outsideTouched + 1 end
  end
  T.eq("T1 NAMED: none outside the strip changed", outsideTouched, 0)

  -- Field average = hand sum / pixel total (fieldArea 1.0 ha -> 2500 pixels).
  -- compactionSum/compaction are the UNQUANTISED scalar bookkeeping (newVal-prev on
  -- the exact float), separate from the raster's own 8-bit quantisation above.
  local total = field.compactionTotalCells
  T.eq("T1 [reached: pixel total]", total, 2500)
  local handSum = 100 * (1 * 1 * (10 / 3))
  T.near("T1 NAMED: field average equals the hand sum / pixel total", field.compaction, handSum / total, 1e-9)
end)

-- T2: the same pass again the same day adds nothing; the next day it adds again.
group("T2 once per pixel per day", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local v = newVehicle({ x = 0, z = 0, width = 3, points = 1 })

  drivePath(m, v, { { x = 0, z = 0 }, { x = 20, z = 0 } })
  local once = vm:readValueAtWorld("compaction", 11, 1)
  T.ok("T2 [reached: first pass laid something]", once ~= nil and once > 0)

  -- Same day, same ground again: nothing added.
  v.id = 2   -- a fresh vehicle id so its own anchor starts clean at the same spot
  drivePath(m, v, { { x = 0, z = 0 }, { x = 20, z = 0 } })
  local sameDay = vm:readValueAtWorld("compaction", 11, 1)
  T.eq("T2 NAMED: the same pass again the same day adds nothing", sameDay, once)

  -- Next game day: adds again.
  g_currentMission.environment.currentDay = 2
  v.id = 3
  drivePath(m, v, { { x = 0, z = 0 }, { x = 20, z = 0 } })
  local nextDay = vm:readValueAtWorld("compaction", 11, 1)
  T.ok("T2 NAMED: the next game day it adds again", nextDay > sameDay)
end)

-- T3: a heavy vehicle at 5 km/h (1.3889 m/s * 1 s sample = 1.3889 m/sample).
group("T3 slow vehicle lays a continuous strip", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local v = newVehicle({ x = 0, z = 0, width = 3, points = 1 })

  local stepM = 5 * 1000 / 3600   -- 1.3889 m per 1 s sample
  local pts = { { x = 0, z = 0 } }
  local x = 0
  for _ = 1, 72 do x = x + stepM; pts[#pts + 1] = { x = x, z = 0 } end
  drivePath(m, v, pts)

  -- Continuity: every odd x in (0, final) at z=1 got compacted (no gaps between
  -- segments, because each successful call's quad starts exactly where the last
  -- successful one ended).
  local finalX = x
  local gaps = 0
  for px = 3, math.floor(finalX) - 2, 2 do
    if vm:readValueAtWorld("compaction", px, 1) == nil then gaps = gaps + 1 end
  end
  T.eq("T3 NAMED: over 100 m the strip is continuous (no gaps between segments)", gaps, 0)
  T.ok("T3 [reached: travelled >= 90 m]", finalX > 90)
end)

-- T3 control note: same drive, run through development's src (see the report).

-- T4: parked jitter (0.3 m a sample for 60 samples, net < 2 m): nothing laid.
group("T4 parked jitter", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local v = newVehicle({ x = 1000, z = 1000, width = 3, points = 1 })

  local pts = { { x = 1000, z = 1000 } }
  -- Jitters back and forth by 0.3 m; net displacement stays under 2 m the whole time.
  for k = 1, 60 do
    local dx = (k % 2 == 0) and 0.3 or -0.3
    pts[#pts + 1] = { x = 1000 + dx, z = 1000 }
  end
  drivePath(m, v, pts)

  local touched = 0
  for px = 995, 1005, 2 do
    for pz = -5, 5, 2 do
      if vm:readValueAtWorld("compaction", px, pz + 1000) ~= nil then touched = touched + 1 end
    end
  end
  T.eq("T4 NAMED: parked jitter under 2 m net lays nothing", touched, 0)
end)

-- T5: a jump > 30 m lays nothing and re-anchors.
group("T5 teleport jump", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local v = newVehicle({ x = 0, z = 0, width = 3, points = 1 })

  -- Arm the anchor at x=0, then jump 50 m (> MAX_SEGMENT_M).
  drivePath(m, v, { { x = 0, z = 0 } })
  v.rootNode.x, v.rootNode.z = 50, 0
  local laid = m:_checkOneVehicleCompaction(v)
  T.eq("T5 NAMED: a jump > 30 m lays nothing", laid, false)
  local between = 0
  for px = 3, 47, 2 do
    if vm:readValueAtWorld("compaction", px, 1) ~= nil then between = between + 1 end
  end
  T.eq("T5 [confirm]: nothing in the jumped gap", between, 0)

  -- Re-anchored at 50: the NEXT normal move from there lays a strip starting at 50.
  v.rootNode.x, v.rootNode.z = 60, 0
  local laid2 = m:_checkOneVehicleCompaction(v)
  T.eq("T5 NAMED: the vehicle re-anchors (the next ordinary move lays its strip)", laid2, true)
  T.ok("T5 [confirm]: the new strip starts at the jump target",
    vm:readValueAtWorld("compaction", 55, 1) ~= nil)
end)

-- T6: pixels off real field ground are skipped.
group("T6 off-field-ground gate", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local v = newVehicle({ x = 0, z = 0, width = 3, points = 1 })

  -- Gravel/parking patch: x in [40,60] is NOT real field ground.
  local savedFSDMU = FSDensityMapUtil.getFieldDataAtWorldPosition
  FSDensityMapUtil.getFieldDataAtWorldPosition = function(x, _y, _z)
    if x >= 40 and x <= 60 then return false end
    return true
  end

  local pts = {}
  for x = 0, 100, 10 do pts[#pts + 1] = { x = x, z = 0 } end
  drivePath(m, v, pts)

  local skipped = 0
  for x = 41, 59, 2 do
    if vm:readValueAtWorld("compaction", x, 1) ~= nil then skipped = skipped + 1 end
  end
  local laidOutside = 0
  for _, x in ipairs({ 11, 21, 71, 81 }) do
    if vm:readValueAtWorld("compaction", x, 1) ~= nil then laidOutside = laidOutside + 1 end
  end
  T.eq("T6 NAMED: pixels off real field ground are skipped", skipped, 0)
  T.eq("T6 [confirm]: pixels on real ground either side still laid", laidOutside, 4)

  FSDensityMapUtil.getFieldDataAtWorldPosition = savedFSDMU
end)

-- T7: a pixel caps at 100.
group("T7 pixel caps at MAX_COMPACTION", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)

  -- A segment 2 m long (z 0->2) so a pixel centre (odd z) falls strictly inside;
  -- width 10 keeps perPixel = points (the 10/W factor cancels at W=10).
  g_currentMission.environment.currentDay = 1
  s:compactStrip(0, 0, 0, 2, 10, 60)   -- width 10 -> perPixel = min(100, 60) = 60
  g_currentMission.environment.currentDay = 2
  s:compactStrip(0, 0, 0, 2, 10, 60)   -- 60 + 60 -> capped at 100, not 120

  local got = vm:readValueAtWorld("compaction", 1, 1)
  T.eq("T7 NAMED: a pixel caps at exactly 100", got, 100)
end)

-- T8: a combine harvesting at 5 km/h compacts through the traffic check only.
group("T8 harvest adds nothing, traffic alone compacts", function()
  g_currentMission.environment.currentDay = 1
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local m = newMgr(s)
  local combine = newVehicle({ x = 0, z = 0, width = 3, points = 1 })

  local stepM = 5 * 1000 / 3600
  local pts = { { x = 0, z = 0 } }
  local x = 0
  for _ = 1, 30 do x = x + stepM; pts[#pts + 1] = { x = x, z = 0 } end
  drivePath(m, combine, pts)
  local touchedByTraffic = vm:readValueAtWorld("compaction", 5, 1) ~= nil
     or vm:readValueAtWorld("compaction", 15, 1) ~= nil
     or vm:readValueAtWorld("compaction", 25, 1) ~= nil
  T.ok("T8a NAMED: the traffic check alone compacts a slow combine", touchedByTraffic)

  -- The harvest hook: install it for real and confirm it adds no compaction call.
  Cutter = Cutter or {}
  Cutter.onEndWorkAreaProcessing = function() end
  local originalAddCutterArea = function(_self, _area, _liters, _ift, _oft, _sr, _farmId, _cutterLoad)
    return "ORIGINAL_RETURN"
  end
  Combine = { addCutterArea = originalAddCutterArea }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true } }

  local installed = hm:installHarvestHook()
  T.ok("T8b [reached: harvest hook installed]", installed == true)

  local calls = 0
  local realCompactStrip = s.compactStrip
  s.compactStrip = function(...) calls = calls + 1; return realCompactStrip(...) end

  local combineSelf = { isServer = true, rootNode = { x = 0, y = 0, z = 0 } }
  local r1 = Combine.addCutterArea(combineSelf, 100, 50, 1, 1, 0.5, 1, nil)
  T.eq("T8b [reached: the wrapper ran to completion]", r1, "ORIGINAL_RETURN")
  T.eq("T8b NAMED: the harvest hook calls compactStrip zero times (the call was removed)", calls, 0)
  s.compactStrip = realCompactStrip
  g_SoilFertilityManager = nil
end)

-- =====================================================================
-- R: tool relief, through the REAL installed hooks
-- =====================================================================

local function wa(sx, sz, wx, wz, hx, hz, waType, active)
  return {
    type = waType,
    start = { x = sx, y = 0, z = sz },
    width = { x = wx, y = 0, z = wz },
    height = { x = hx, y = 0, z = hz },
    _active = active,
  }
end

-- Seed a region with a uniform compaction value directly on the raster (not
-- through compactStrip - this is test setup, not the thing under test), and give
-- the field a matching compactionSum/compaction so relief's bookkeeping has a
-- known starting point.
-- The value actually stored is quantised to the 8-bit raw step and back (e.g. 40
-- round-trips to ~40.1575, not exactly 40); every comparison against "the seeded
-- value" in the R group uses this round-tripped number, not the raw literal.
local function quantizeRoundTrip(v) return decodeC(encodeC(v)) end

local function seedRegion(vm, field, x0, x1, z0, z1, value)
  local raw = encodeC(value)
  local stored = decodeC(raw)
  local n = 0
  for x = x0 + 1, x1 - 1, 2 do
    for z = z0 + 1, z1 - 1, 2 do
      local i, j = pixCol(x), pixCol(z)
      vm.raw[j * N + i] = raw
      n = n + 1
    end
  end
  field.compaction = stored
  field.compactionTotalCells = 2500
  field.compactionSum = stored * n   -- only the seeded pixels carry a value
  return n
end

-- R1: a plow (Plow spec, installDedicatedPlowHook), one work area 3 m x 50 m
-- (one accumulated pass footprint), lowered/active, lastChangedArea > 0.
group("R1 plow relieves its work area", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  local seededN = seedRegion(vm, field, -10, 110, -10, 60, 40)

  Plow = { onEndWorkAreaProcessing = function() end }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true, compactionEnabled = true } }
  T.ok("R1 [reached: hook installed]", hm:installDedicatedPlowHook() == true)

  local plowSelf = {
    isServer = true, id = 1, rootNode = { x = 1, y = 0, z = 0 },
    spec_plow = { workAreaParameters = { lastChangedArea = 100 } },
    spec_workArea = { workAreas = { wa(0, 0, 3, 0, 0, 50, nil, true) } },
  }
  Plow.onEndWorkAreaProcessing(plowSelf, 16, true)

  local sumBefore = seededN * quantizeRoundTrip(40)
  local insideGood, insideBad, insideCount = 0, 0, 0
  for x = 1, 2, 2 do
    for z = 1, 49, 2 do
      insideCount = insideCount + 1
      local got = vm:readValueAtWorld("compaction", x, z)
      if got == 0 then insideGood = insideGood + 1 else insideBad = insideBad + 1 end
    end
  end
  T.eq("R1 NAMED: every pixel centre swept by the work area goes to 0", insideBad, 0)
  T.ok("R1 [reached: pixels swept]", insideCount > 0)

  -- Beside it (x=5, outside the 3 m width): unchanged.
  local besideUnchanged = true
  for z = 1, 49, 2 do
    if vm:readValueAtWorld("compaction", 5, z) ~= quantizeRoundTrip(40) then besideUnchanged = false end
  end
  T.ok("R1 NAMED: pixels beside the work area are unchanged", besideUnchanged)

  local removed = insideGood * quantizeRoundTrip(40)
  T.near("R1 NAMED: field sum falls by exactly the removed values", field.compactionSum, sumBefore - removed, 1e-6)
  g_SoilFertilityManager = nil
end)

-- R2: a subsoiler through the Cultivator hook (isSubsoiler), same relief.
group("R2 subsoiler relieves its work area", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  seedRegion(vm, field, -10, 110, -10, 60, 40)

  Cultivator = { onEndWorkAreaProcessing = function() end }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true, compactionEnabled = true } }
  T.ok("R2 [reached: hook installed]", hm:installPlowingHook() == true)

  local cultSelf = {
    isServer = true, id = 2, rootNode = { x = 1, y = 0, z = 0 },
    spec_cultivator = { workAreaParameters = { lastChangedArea = 100 }, isSubsoiler = true },
    spec_workArea = { workAreas = { wa(0, 0, 3, 0, 0, 50, nil, true) } },
  }
  Cultivator.onEndWorkAreaProcessing(cultSelf, 16, true)

  local bad = 0
  for x = 1, 2, 2 do
    for z = 1, 49, 2 do
      if vm:readValueAtWorld("compaction", x, z) ~= 0 then bad = bad + 1 end
    end
  end
  T.eq("R2 NAMED: a subsoiler (isSubsoiler) through the Cultivator hook relieves its area to 0", bad, 0)
  g_SoilFertilityManager = nil
end)

-- R3: a shallow cultivator (no spec_plow/spec_subsoiler, no deep workingDepth)
-- relieves nothing.
group("R3 shallow cultivator relieves nothing", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  seedRegion(vm, field, -10, 110, -10, 60, 40)

  Cultivator = { onEndWorkAreaProcessing = function() end }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true, compactionEnabled = true } }
  hm:installPlowingHook()

  local cultSelf = {
    isServer = true, id = 3, rootNode = { x = 1, y = 0, z = 0 },
    spec_cultivator = { workAreaParameters = { lastChangedArea = 100 }, isSubsoiler = false },
    spec_workArea = { workAreas = { wa(0, 0, 3, 0, 0, 50, nil, true) } },
  }
  Cultivator.onEndWorkAreaProcessing(cultSelf, 16, true)

  local unchanged = true
  for x = 1, 2, 2 do
    for z = 1, 49, 2 do
      if vm:readValueAtWorld("compaction", x, z) ~= quantizeRoundTrip(40) then unchanged = false end
    end
  end
  T.ok("R3 NAMED: a shallow cultivator relieves nothing", unchanged)
  g_SoilFertilityManager = nil
end)

-- R4: a grassland weeder relieves only with isGrasslandWeeder.
group("R4 grassland weeder relief gated on isGrasslandWeeder", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  seedRegion(vm, field, -10, 110, -10, 60, 40)

  Weeder = { onEndWorkAreaProcessing = function() end }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true, compactionEnabled = true, weedPressure = false } }
  T.ok("R4 [reached: hook installed]", hm:installWeederHook() == true)

  -- Not a grassland weeder: relieves nothing.
  local weederSelf1 = {
    isServer = true, id = 4, rootNode = { x = 1, y = 0, z = 0 },
    spec_weeder = { workAreaParameters = { lastChangedArea = 100 }, isGrasslandWeeder = false },
    spec_workArea = { workAreas = { wa(0, 0, 3, 0, 0, 50, nil, true) } },
  }
  Weeder.onEndWorkAreaProcessing(weederSelf1, 16, true)
  local stillFull = true
  for z = 1, 49, 2 do
    if vm:readValueAtWorld("compaction", 1, z) ~= quantizeRoundTrip(40) then stillFull = false end
  end
  T.ok("R4a NAMED: a non-grassland weeder relieves nothing", stillFull)

  -- A grassland weeder (isGrasslandWeeder=true): relieves.
  local weederSelf2 = {
    isServer = true, id = 5, rootNode = { x = 1, y = 0, z = 0 },
    spec_weeder = { workAreaParameters = { lastChangedArea = 100 }, isGrasslandWeeder = true },
    spec_workArea = { workAreas = { wa(0, 0, 3, 0, 0, 50, nil, true) } },
  }
  Weeder.onEndWorkAreaProcessing(weederSelf2, 16, true)
  local relieved = true
  for z = 1, 49, 2 do
    if vm:readValueAtWorld("compaction", 1, z) ~= 0 then relieved = false end
  end
  T.ok("R4b NAMED: a grassland weeder (isGrasslandWeeder) relieves its area", relieved)
  g_SoilFertilityManager = nil
end)

-- R5: an AUXILIARY area and an inactive area relieve nothing.
group("R5 AUXILIARY and inactive areas excluded", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  seedRegion(vm, field, -10, 110, -10, 60, 40)

  Cultivator = { onEndWorkAreaProcessing = function() end }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true, compactionEnabled = true } }
  hm:installPlowingHook()

  -- Area 1: AUXILIARY (x in [0,3]). Area 2: ACTIVE normal (x in [10,13]).
  -- Area 3: normal type but getIsWorkAreaActive reports false (x in [20,23]).
  local auxArea = wa(0, 0, 3, 0, 0, 50, WorkAreaType.AUXILIARY, true)
  local activeArea = wa(10, 0, 13, 0, 10, 50, nil, true)
  local inactiveArea = wa(20, 0, 23, 0, 20, 50, nil, false)

  local cultSelf = {
    isServer = true, id = 6, rootNode = { x = 1, y = 0, z = 0 },
    spec_cultivator = { workAreaParameters = { lastChangedArea = 100 }, isSubsoiler = true },
    spec_workArea = { workAreas = { auxArea, activeArea, inactiveArea } },
    getIsWorkAreaActive = function(_self, w) return w._active end,
  }
  Cultivator.onEndWorkAreaProcessing(cultSelf, 16, true)

  local auxUntouched = true
  for z = 1, 49, 2 do if vm:readValueAtWorld("compaction", 1, z) ~= quantizeRoundTrip(40) then auxUntouched = false end end
  T.ok("R5a NAMED: the AUXILIARY area relieves nothing", auxUntouched)

  local inactiveUntouched = true
  for z = 1, 49, 2 do if vm:readValueAtWorld("compaction", 21, z) ~= quantizeRoundTrip(40) then inactiveUntouched = false end end
  T.ok("R5b NAMED: the inactive area relieves nothing", inactiveUntouched)

  local activeRelieved = true
  for z = 1, 49, 2 do if vm:readValueAtWorld("compaction", 11, z) ~= 0 then activeRelieved = false end end
  T.ok("R5 [confirm]: the ACTIVE non-AUXILIARY area still relieves", activeRelieved)
  g_SoilFertilityManager = nil
end)

-- R6: lastChangedArea 0 relieves nothing (the hook's own gate, before relief runs).
group("R6 lastChangedArea 0 is a no-op", function()
  local field = newField(1.0)
  local vm = newVM()
  local hm = newHookManager(function() return FID end)
  local s = newSys(vm, hm, field)
  seedRegion(vm, field, -10, 110, -10, 60, 40)

  Cultivator = { onEndWorkAreaProcessing = function() end }
  g_SoilFertilityManager = { soilSystem = s, settings = { enabled = true, compactionEnabled = true } }
  hm:installPlowingHook()

  local cultSelf = {
    isServer = true, id = 7, rootNode = { x = 1, y = 0, z = 0 },
    spec_cultivator = { workAreaParameters = { lastChangedArea = 0 }, isSubsoiler = true },
    spec_workArea = { workAreas = { wa(0, 0, 3, 0, 0, 50, nil, true) } },
  }
  Cultivator.onEndWorkAreaProcessing(cultSelf, 16, true)

  local unchanged = true
  for z = 1, 49, 2 do if vm:readValueAtWorld("compaction", 1, z) ~= quantizeRoundTrip(40) then unchanged = false end end
  T.ok("R6 NAMED: lastChangedArea 0 relieves nothing", unchanged)
  g_SoilFertilityManager = nil
end)

-- =====================================================================
-- D: decay and the per-pixel map fade
-- =====================================================================

-- D1: full entry (_applyCompactionDecay), held-ratio gate included. A fixed field of
-- 10 m x 10 m polygon, pixels seeded at raw(100) (MAX_COMPACTION). R=0.1 point/day (a
-- realistic NATURAL_DECAY_PER_DAY-sized nibble against a near-100 average) keeps each
-- SINGLE day's ratio within a hair of 1 (f ~ 0.001), which collapses the whole raw range
-- into ONE band whose drop floors to 0 (math.floor(.. * 0.001 + 0.5) = 0 for anything
-- short of the far end of the scale) - exactly the rounding failure the held step exists
-- to prevent. 51 days telescopes oldAvg 100 -> 94.9, crossing <= MAP_DECAY_STEP (0.95)
-- on day 51 (held ratio 0.949), which is when the one real map fade runs.
group("D1 decay entry, held ratio, map fade", function()
  local field = newField(1.0)
  local vm = newVM()
  local s = newSys(vm, nil, field)
  local verts = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
  field._polyVerts = verts
  local n = seedRegion(vm, field, 0, 10, 0, 10, 100)
  field.compaction = quantizeRoundTrip(100)
  field.compactionSum = field.compaction * n
  field.compactionTotalCells = n

  for _ = 1, 51 do
    s:_applyCompactionDecay(field, 0.1, FID)
  end

  T.near("D1 NAMED: the scalar follows exactly (100 -> 94.9 after 51 days of 0.1/day)", field.compaction, 94.9, 1e-6)
  local worstDiff, checked = 0, 0
  for x = 1, 9, 2 do
    for z = 1, 9, 2 do
      checked = checked + 1
      local got = vm:readValueAtWorld("compaction", x, z)
      local diff = math.abs((got or 0) - 94.9)
      if diff > worstDiff then worstDiff = diff end
    end
  end
  T.eq("D1 [reached: pixels checked]", checked, 25)
  T.ok("D1 NAMED: once the held ratio crosses 0.95, every pixel lies within one raw step of value*ratio (worst "
    .. tostring(worstDiff) .. ")", worstDiff <= (100 / 254) + 1e-6)
end)

-- D2: a low-value pixel (raw 11) still fades on a held 0.95 pass.
group("D2 low-value pixel still fades", function()
  local field = newField(1.0)
  local vm = newVM()
  local s = newSys(vm, nil, field)
  local verts = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
  field._polyVerts = verts
  vm.raw[pixCol(1) * N + pixCol(1)] = 11   -- the low pixel: decode ~3.94
  vm.raw[pixCol(5) * N + pixCol(5)] = 200  -- a higher pixel in a different band

  local before = decodeC(11)
  s:_compactionMapFade(FID, field, 0.95)
  local after = vm:readValueAtWorld("compaction", 1, 1)

  -- Hand geometry of the banding pass: span=254, f=0.05, width=max(ceil(254/32),
  -- floor(1/0.05))=max(8,20)=20. Band 1: lo=2,hi=21. mid=(2+21)/2=11.5.
  -- drop=floor((11.5-1)*0.05+0.5)=floor(1.025)=1. addLow=max(2,1+1)=2,addHigh=21.
  -- Raw 11 is in [2,21] (add window): new raw = 11-1 = 10.
  T.ok("D2 NAMED: a low-value pixel (raw 11) still fades on a held 0.95 pass (before "
    .. tostring(before) .. " after " .. tostring(after) .. ")", after ~= nil and after < before)
  T.near("D2 [confirm]: matches the hand-derived band drop (raw 11 -> 10)", after, decodeC(10), 1e-9)
end)

-- D3: an average reaching 0 sets every pixel to 0.
group("D3 ratio 0 clears every pixel", function()
  local field = newField(1.0)
  local vm = newVM()
  local s = newSys(vm, nil, field)
  local verts = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
  field._polyVerts = verts
  seedRegion(vm, field, 0, 10, 0, 10, 60)
  vm.raw[pixCol(1) * N + pixCol(1)] = 2   -- near-floor pixel too

  s:_compactionMapFade(FID, field, 0)

  local bad = 0
  for x = 1, 9, 2 do
    for z = 1, 9, 2 do
      if vm:readValueAtWorld("compaction", x, z) ~= 0 then bad = bad + 1 end
    end
  end
  T.eq("D3 NAMED: an average reaching 0 sets every pixel to 0", bad, 0)
end)

-- D4: no pixel is faded twice in one pass (a pixel just above a band edge).
-- Band boundaries depend on floating-point division (1/f is not always a round
-- number: 1-0.95 is 0.050000000000000044 in double precision, not exactly 0.05),
-- so the bands are computed here by hand with the SAME documented formula
-- (_compactionMapFade's own doc comment: band width, floor((mid-RMIN)*f+0.5)),
-- never by calling production, so the test picks real band edges instead of
-- assumed round numbers.
local function computeBands(ratio)
  local f = 1 - math.max(0, ratio)
  local width = math.max(math.ceil(RAW_SPAN / 32), math.floor(1 / f))
  local bands = {}
  local lo = RMIN + 1
  while lo <= RMAX do
    local hi = math.min(RMAX, lo + width - 1)
    local drop = math.floor(((lo + hi) * 0.5 - RMIN) * f + 0.5)
    bands[#bands + 1] = { lo = lo, hi = hi, drop = drop }
    lo = hi + 1
  end
  return bands
end

group("D4 no double fade across a band edge", function()
  local field = newField(1.0)
  local vm = newVM()
  local s = newSys(vm, nil, field)
  local verts = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
  field._polyVerts = verts

  local bands = computeBands(0.95)
  local bA, bB
  for i = 1, #bands - 1 do
    if bands[i].drop ~= bands[i + 1].drop then bA, bB = bands[i], bands[i + 1]; break end
  end
  T.ok("D4 [reached: found two adjacent bands with different drops]", bA ~= nil and bB ~= nil)

  -- Storage convention is idx = z-row*N + x-col (matches readValueAtWorld/
  -- writeValueAtWorld/seedRegion above): row from z, column from x.
  vm.raw[pixCol(1) * N + pixCol(1)] = bA.hi   -- (x=1,z=1): top of the lower band
  vm.raw[pixCol(1) * N + pixCol(3)] = bB.lo   -- (x=3,z=1): bottom of the upper band

  s:_compactionMapFade(FID, field, 0.95)

  local b1 = vm.raw[pixCol(1) * N + pixCol(1)]
  local b2 = vm.raw[pixCol(1) * N + pixCol(3)]
  T.eq("D4 NAMED: the lower band's edge pixel drops exactly its own band's amount ("
    .. bA.hi .. " -> " .. (bA.hi - bA.drop) .. ")", b1, bA.hi - bA.drop)
  T.eq("D4 NAMED: the upper band's edge pixel drops exactly its own band's amount ("
    .. bB.lo .. " -> " .. (bB.lo - bB.drop) .. "), not the lower band's drop too", b2, bB.lo - bB.drop)
end)

-- =====================================================================
-- L: load (XML and the StateLedger table)
-- =====================================================================

-- A minimal hand-built XML fake: only the keys loadFromXMLFile actually reads
-- answer; everything else is nil (defaults apply).
local function newFakeXML()
  local store = {}
  local xmlFile = {}
  _G.getXMLFloat = function(f, path) if f == xmlFile then return store[path] end return nil end
  _G.getXMLInt = function(f, path)
    if f ~= xmlFile then return nil end
    local v = store[path]
    if v == nil then return nil end
    return math.floor(v)
  end
  _G.getXMLString = function(f, path) if f == xmlFile then return store[path] end return nil end
  _G.getXMLBool = function(f, path) if f == xmlFile then return store[path] end return nil end
  return xmlFile, store
end

local function newLoadSys()
  return setmetatable({
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
end

-- L1: an XML save with #compaction restores it and sum = avg * pixel total.
group("L1 XML load restores #compaction", function()
  local xmlFile, store = newFakeXML()
  store["soilData#lastUpdateDay"] = 10
  store["soilData.field(0)#id"] = FID
  store["soilData.field(0)#fieldArea"] = 2.0
  store["soilData.field(0)#compaction"] = 40
  local s = newLoadSys()
  s:loadFromXMLFile(xmlFile, "soilData")
  local f = s.fieldData[FID]
  T.ok("L1 [reached: field loaded]", f ~= nil)
  T.near("L1 NAMED: the saved average restores exactly", f.compaction, 40, 1e-9)
  T.eq("L1 [confirm]: pixel total from the 2 m grid (2 ha -> 5000 px)", f.compactionTotalCells, 5000)
  T.near("L1 NAMED: compactionSum = avg * pixel total", f.compactionSum, 40 * 5000, 1e-6)
end)

-- L2: without the attribute, falls back to the 10 m zone-cell average.
group("L2 XML load without #compaction falls back to zone cells", function()
  local xmlFile, store = newFakeXML()
  store["soilData.field(0)#id"] = FID
  store["soilData.field(0)#fieldArea"] = 0.02   -- 2 zone cells (0.01 ha each)
  -- no #compaction attribute at all
  store["soilData.field(0).zone(0)#key"] = "a"
  store["soilData.field(0).zone(0)#CP"] = 30
  store["soilData.field(0).zone(1)#key"] = "b"
  store["soilData.field(0).zone(1)#CP"] = 50
  local s = newLoadSys()
  s:loadFromXMLFile(xmlFile, "soilData")
  local f = s.fieldData[FID]
  T.near("L2 NAMED: falls back to the 10 m zone-cell average ((30+50)/2 = 40)", f.compaction, 40, 1e-9)
end)

-- L3: a saved 0 beside stale non-zero cells stays 0.
group("L3 saved 0 overrides stale zone cells", function()
  local xmlFile, store = newFakeXML()
  store["soilData.field(0)#id"] = FID
  store["soilData.field(0)#fieldArea"] = 0.02
  store["soilData.field(0)#compaction"] = 0
  store["soilData.field(0).zone(0)#key"] = "a"
  store["soilData.field(0).zone(0)#CP"] = 50
  store["soilData.field(0).zone(1)#key"] = "b"
  store["soilData.field(0).zone(1)#CP"] = 60
  local s = newLoadSys()
  s:loadFromXMLFile(xmlFile, "soilData")
  local f = s.fieldData[FID]
  T.eq("L3 NAMED: a saved 0 beside stale non-zero zone cells stays 0", f.compaction, 0)
  T.eq("L3 [confirm]: compactionSum is 0 too", f.compactionSum, 0)
end)

-- L4: the StateLedger table path matches L1-L3.
group("L4 StateLedger table path matches the XML path", function()
  -- L4a mirrors L1.
  do
    local s = newLoadSys()
    s:applySoilStateTable({ lastUpdateDay = 10, fields = {
      [FID] = { fieldArea = 2.0, compaction = 40 },
    } })
    T.near("L4a NAMED: matches L1 (saved average restores exactly)", s.fieldData[FID].compaction, 40, 1e-9)
    T.near("L4a [confirm]: matches L1 (sum = avg * pixel total)", s.fieldData[FID].compactionSum, 40 * 5000, 1e-6)
  end
  -- L4b mirrors L2 (no e.compaction key at all).
  do
    local s = newLoadSys()
    s:applySoilStateTable({ fields = {
      [FID] = { fieldArea = 0.02, zoneData = {
        a = { compaction = 30 }, b = { compaction = 50 },
      } },
    } })
    T.near("L4b NAMED: matches L2 (falls back to the zone-cell average)", s.fieldData[FID].compaction, 40, 1e-9)
  end
  -- L4c mirrors L3 (e.compaction = 0 beside stale zone cells).
  do
    local s = newLoadSys()
    s:applySoilStateTable({ fields = {
      [FID] = { fieldArea = 0.02, compaction = 0, zoneData = {
        a = { compaction = 50 }, b = { compaction = 60 },
      } },
    } })
    T.eq("L4c NAMED: matches L3 (a saved 0 beside stale cells stays 0)", s.fieldData[FID].compaction, 0)
  end
end)

-- =====================================================================
-- P: readers (SpatialPressures, EstablishmentFailure)
-- =====================================================================

-- P1: SpatialPressures weights a cell by the map mean of its pixels.
group("P1 SpatialPressures reads the map mean, not cell.compaction", function()
  local P = SpatialPressures
  local field = {
    zoneData = { ["0,0"] = { gx = 0, gz = 0, pH = 6.5, N = 50, OM = 3.5, compaction = 0 } },
    pestPressure = 0, diseasePressure = 40, _prevPest = 0, _prevDisease = 0,
  }
  local capturedComp, capturedW
  local realMult = P.cellSoilMult
  P.cellSoilMult = function(self, cell, comp)
    capturedComp = comp
    capturedW = realMult(self, cell, comp)
    return capturedW
  end
  local selfSoilSystem = {
    compactionMeanInSquare = function(_self, x, z, half)
      T.eq("P1 [reached: called with the cell's own position/half]", x == 5 and z == 5 and half == 5, true)
      return 60
    end,
  }
  P:run(selfSoilSystem, 1, field, 100, nil)
  P.cellSoilMult = realMult

  T.eq("P1 NAMED: cellSoilMult receives the 2 m map mean (60), not cell.compaction (0)", capturedComp, 60)
  -- Hand-derived (pH 6.5 >= LOW_PH_THRESHOLD, N 50 < HIGH_N, OM 3.5 < OM_GOOD: base 1.0):
  -- mult = 1.0 * (1 + min(0.5, 60/100)) = 1.5.
  T.near("P1 NAMED: that comp value gives a weight > 1 (hand: 1.5)", capturedW, 1.5, 1e-9)
end)

-- P2: EstablishmentFailure's threshold uses the map mean.
group("P2 EstablishmentFailure threshold reads the map mean", function()
  local ss = { compactionMeanInSquare = function(_self, _x, _z, _half) return 80 end }
  local m = setmetatable({ manager = { soilSystem = ss } }, { __index = EstablishmentFailure })
  g_currentMission = g_currentMission or {}
  g_currentMission.cropStressManager = { getMoisture = function(_self, _fid, _x, _z) return 0.75 end }
  g_currentMission.weatherGuard = nil

  local killed = 0
  m.killRegion = function() killed = killed + 1 end
  m._groupRegions = function(_self, cells) return { cells } end
  m._regionPolygon = function() return { { { x = 0, z = 0 } } } end

  local field = {
    establishing = true, sownCrop = nil, zoneData = {
      ["0,0"] = { gx = 0, gz = 0, compaction = 0 },
    },
  }
  m:_checkEstablishingField(99, field)

  -- Hand-derived thresholds: moisture*severity = 0.75.
  --   using cell.compaction (0):  threshold = 0.85 - 0.20*(0/100)  = 0.85  (0.75 < 0.85, no kill)
  --   using the map mean (80):    threshold = 0.85 - 0.20*(80/100) = 0.69  (0.75 >= 0.69, kill)
  T.eq("P2 NAMED: the map mean (80), not the stale cell.compaction (0), decides the kill", killed, 1)
end)

T.summary()
