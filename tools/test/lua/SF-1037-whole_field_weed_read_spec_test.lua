-- SF-1037-whole_field_weed_read_spec_test.lua
--
-- #1037 cause 2: the daily weed read measures the WHOLE field.
--
-- THE DEFECT THIS PINS (development 79e00157): _sampleFieldWeedFactor averaged 17
-- points within 30 m of the field's reference point, about 4% of a 6.6 ha field. On
-- Sauge's field, herbicide over about 80% of it (centre included) left a live strip the
-- read never reached, so weed risk read 0% for good after protection ran out.
--
-- THE ENTRY-POINT BAR: every row drives production's own per-frame entry,
-- SoilFertilitySystem:update(dt). A day's weed read happens through update()'s daily
-- batch (the real _processOneDailyField), and the whole-field read advances through
-- the same update() one slice a frame. Nothing sets weedPressure, a factor or a read
-- result by hand. The fixture supplies what the engine supplies:
--   * a weed density map keyed by pixel (2 m pixels) with the vanilla factors from
--     data/maps/maps_weed.xml (3 = 0.5, 4 = 0.75, 5 = 1.0, 6 = 0.5, 8 = 0.5, 9 = 0.75)
--     and vanilla's herbicide replacements (8 and 9 are withered);
--   * the density-map objects the engine's own whole-field reads use
--     (HerbicideMission.lua:36-55, FieldGetInfoTask.lua:38-85, DensityMapPolygon.lua:58-66),
--     modelled as a counter over that pixel map: the polygon's points bound the pixels,
--     the clip region bounds a slice, and the stats report the running count per get
--     since resetStats, with the touched pixels as execute's fourth return;
--   * FieldState reading the same pixel map at a point, for the centre gate and the
--     ring fallback.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local saved = {
  g_server = g_server, g_fieldManager = g_fieldManager, g_fruitTypeManager = g_fruitTypeManager,
  g_terrainNode = g_terrainNode, FieldState = FieldState, FruitType = FruitType,
  weedSystem = g_currentMission.weedSystem, g_SoilFertilityManager = g_SoilFertilityManager,
  DensityMapModifier = DensityMapModifier, DensityMapFilter = DensityMapFilter,
  DensityMapMultiModifier = DensityMapMultiModifier, DensityValueCompareType = DensityValueCompareType,
}

FruitType = FruitType or { UNKNOWN = 0 }
g_fruitTypeManager = { getFruitTypeByIndex = function() return { name = "WHEAT" } end }
g_SoilFertilityManager = nil
g_terrainNode = 1

-- ── The weed map ─────────────────────────────────────────────────────────────
local PX = 2                                  -- metres per pixel
local W, H = 250, 260                         -- the field, metres (6.5 ha)
local CX, CZ = 125, 130                       -- its reference point
local MAP = {}                                -- MAP[i][j] = weed state of pixel (i, j)
local FACTORS = { [3] = 0.5, [4] = 0.75, [5] = 1.0, [6] = 0.5, [8] = 0.5, [9] = 0.75 }
local VANILLA_HERBICIDE = { [1] = 0, [2] = 0, [3] = 7, [4] = 8, [5] = 9, [6] = 7 }

local function paint(stateAt)                 -- stateAt(x, z) -> state at a pixel centre
  for i = 0, W / PX - 1 do
    MAP[i] = MAP[i] or {}
    for j = 0, H / PX - 1 do MAP[i][j] = stateAt(i * PX + PX / 2, j * PX + PX / 2) end
  end
end
local function stateAtWorld(x, z)
  local col = MAP[math.floor(x / PX)]
  return col and col[math.floor(z / PX)] or 0
end

g_currentMission.weedSystem = {
  getDensityMapData = function() return 77, 0, 4 end,
  getFactors = function() return FACTORS end,
  getHerbicideReplacements = function() return { weed = { replacements = VANILLA_HERBICIDE } } end,
}

-- ── The engine's density-map objects, as a counter over MAP ──────────────────
local EXECUTES = 0
local PIXELS_SEEN = 0                         -- pixels counted by every execute so far
DensityValueCompareType = { EQUAL = 1, GREATER = 2 }
DensityMapModifier = { new = function(mapId) return { mapId = mapId } end }
DensityMapFilter = {
  new = function(modifier)
    return { modifier = modifier,
             setValueCompareParams = function(self, cmp, value) self.cmp, self.value = cmp, value end }
  end,
}
DensityMapMultiModifier = {
  new = function()
    local m = { gets = {}, xs = {}, zs = {}, running = {} }
    function m:addExecuteGet(name, modifier, filter)
      assert(modifier.mapId == 77, "a get on the weed map")
      -- the engine snapshots the filter's compare at add time (HerbicideMission reuses one)
      self.gets[#self.gets + 1] = { name = name, cmp = filter.cmp, value = filter.value }
    end
    function m:clearPolygonPoints() self.xs, self.zs = {}, {} end
    function m:addPolygonPointWorldCoords(x, z) self.xs[#self.xs + 1] = x; self.zs[#self.zs + 1] = z end
    function m:getPolygonMinMaxZ()
      if #self.zs == 0 then return nil, nil end
      return math.min(unpack(self.zs)), math.max(unpack(self.zs))
    end
    function m:setPolygonClipRegion(lo, hi) self.clipLo, self.clipHi = lo, hi end
    function m:resetStats() self.running = {} end
    function m:execute(_, stats)
      EXECUTES = EXECUTES + 1
      local x0, x1 = math.min(unpack(self.xs)), math.max(unpack(self.xs))
      local z0, z1 = math.min(unpack(self.zs)), math.max(unpack(self.zs))
      local lo, hi = self.clipLo or z0, self.clipHi or z1
      local touched = 0
      for i, col in pairs(MAP) do
        local x = i * PX + PX / 2
        if x >= x0 and x < x1 then
          for j, state in pairs(col) do
            local z = j * PX + PX / 2
            if z >= z0 and z < z1 and z >= lo and z < hi then
              touched = touched + 1
              for _, g in ipairs(self.gets) do
                if g.cmp == DensityValueCompareType.EQUAL and state == g.value then
                  self.running[g.name] = (self.running[g.name] or 0) + 1
                end
              end
            end
          end
        end
      end
      for name, n in pairs(self.running) do stats[name] = n end
      PIXELS_SEEN = PIXELS_SEEN + touched
      return nil, nil, nil, touched
    end
    return m
  end,
}

-- The field's polygon, applied the way DensityMapPolygon:applyToModifier does it.
local POLYGON = {
  applyToModifier = function(_, modifier)
    modifier:clearPolygonPoints()
    for _, p in ipairs({ { 0, 0 }, { W, 0 }, { W, H }, { 0, H } }) do
      modifier:addPolygonPointWorldCoords(p[1], p[2])
    end
  end,
}

-- FieldState at a point reads the same pixel map (the centre gate and the ring fallback).
local CROP_AT_CENTRE = 3
FieldState = {
  new = function()
    return { update = function(self, x, z)
      self.isValid = true
      self.fruitTypeIndex = CROP_AT_CENTRE
      self.weedState = stateAtWorld(x, z)
      self.weedFactor = FACTORS[self.weedState] or 0
      self.farmlandId = nil
    end }
  end,
}

-- ── The system, driven through update() ──────────────────────────────────────
local function newField(weedPressure)
  return { nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.5,
           lastHarvest = 99, lastCrop = "wheat", weedPressure = weedPressure, herbicideDaysLeft = 0 }
end

local function newSystem(field)
  g_server = {}
  g_fieldManager = { fields = { [1] = { posX = CX, posZ = CZ, farmland = { id = 1 },
                                        getDensityMapPolygon = function() return POLYGON end } } }
  return setmetatable({
    fieldData = { [1] = field }, activeFieldIds = { [1] = true }, _activeListDirty = true,
    settings = { enabled = true, weedPressure = true },
    herbicideAppliedDay = {}, lastUpdate = 0, updateInterval = 1e9,
    _dailyBatchDay = 100, _dailyBatchSeason = 1,
    DAILY_BATCH_SIZE = 25,                    -- the constructor's value, SoilFertilitySystem.lua:252
  }, { __index = SoilFertilitySystem })
end

-- One in-game day's daily batch, as updateDailySoil queues it, drained by update().
local function runDay(sys, day)
  sys._dailyBatchDay, sys._dailyBatchCursor, sys._dailyBatchRepeat = day, 0, 1
  sys._pendingDailyUpdate = true
  sys:update(16)
  assert(not sys._pendingDailyUpdate, "the daily batch drained")
end

-- Frames until the running whole-field read is done (and executes per frame).
local function runFrames(sys, maxFrames)
  local frames, worst, worstPixels = 0, 0, 0
  while (sys._weedReadActive ~= nil or (sys._weedReadQueue and #sys._weedReadQueue > 0))
        and frames < maxFrames do
    local before, beforePixels = EXECUTES, PIXELS_SEEN
    sys:update(16)
    frames = frames + 1
    worst = math.max(worst, EXECUTES - before)
    worstPixels = math.max(worstPixels, PIXELS_SEEN - beforePixels)
  end
  return frames, worst, worstPixels
end

local SLICES = math.ceil(H / 30)              -- 30 m of Z a frame, DensityMapUpdateTask.lua:23

-- ══════════════════════════════════════════════════════════
-- W: SAUGE'S FIELD. Herbicide over the first 80% (centre inside), a live strip left.
-- ══════════════════════════════════════════════════════════
do
  -- 80% withered (state 8, vanilla factor 0.5, read as 0), 20% live state 3 (0.5).
  paint(function(x) return (x < 0.8 * W) and 8 or 3 end)
  local field = newField(0)                   -- protection has run out, risk reads 0
  local sys = newSystem(field)

  runDay(sys, 101)
  T.eq("W1 day 1: the first whole-field read has not finished, the ring reads 0 (all withered)",
       field.weedPressure, 0)
  T.ok("W1b and the daily pass asked for a whole-field read", sys._weedReadActive ~= nil
       or (sys._weedReadQueue and #sys._weedReadQueue == 1))

  local frames, worst, worstPixels = runFrames(sys, 100)
  T.eq("W2 the read is sliced: one 30 m slice a frame, " .. SLICES .. " frames for 260 m", frames, SLICES)
  T.eq("W3 no frame runs more than one slice", worst, 1)
  T.ok("W3b and no frame counts more than one 30 m band of the field's pixels",
       worstPixels <= (30 / PX) * (W / PX))

  runDay(sys, 102)
  -- 20% of the field at factor 0.5 -> 10 points; the withered 80% counts 0, not 0.5.
  T.near("W4 day 2: weed risk shows the unsprayed share, 20% x 0.5 = 10, not 0", field.weedPressure, 10, 1e-6)

  -- The strip grows on: day 2's pass asked for the next read, which follows the map.
  paint(function(x) return (x < 0.8 * W) and 8 or 5 end)
  runFrames(sys, 100)
  runDay(sys, 103)
  T.near("W5 day 3: the next read follows the map (20% x 1.0 = 20)", field.weedPressure, 20, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- C: CONTROLS
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)              -- uniformly weedy, 0.75 everywhere
  local field = newField(75)
  local sys = newSystem(field)
  runDay(sys, 101)
  local ringDay = field.weedPressure
  runFrames(sys, 100)
  runDay(sys, 102)
  T.near("C1 a uniformly weedy field reads 75 from the rings (day 1)", ringDay, 75, 1e-6)
  T.near("C1b and 75 from the whole-field read (day 2), the same as before", field.weedPressure, 75, 1e-6)
end
do
  paint(function() return 0 end)              -- clean
  local field = newField(0)
  local sys = newSystem(field)
  runDay(sys, 101)
  runFrames(sys, 100)
  runDay(sys, 102)
  T.eq("C2 a clean field reads 0", field.weedPressure, 0)
end
do
  paint(function() return 4 end)
  CROP_AT_CENTRE = FruitType.UNKNOWN          -- no managed crop at the centre
  local field = newField(0)
  local sys = newSystem(field)
  local before = EXECUTES
  runDay(sys, 101)
  runFrames(sys, 100)
  runDay(sys, 102)
  T.eq("C3 no managed crop at the centre reads 0", field.weedPressure, 0)
  T.eq("C3b and no whole-field read is made for it", EXECUTES - before, 0)
  CROP_AT_CENTRE = 3
end

-- ══════════════════════════════════════════════════════════
-- MP: the read never runs on a client
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)
  local field = newField(0)
  local sys = newSystem(field)
  runDay(sys, 101)                            -- queued on the server
  g_server = nil                              -- the same state seen on a client
  local before = EXECUTES
  for _ = 1, 20 do sys:update(16) end
  T.eq("MP1 a client's update() executes no slice of a queued read", EXECUTES - before, 0)
  sys._weedReadQueue, sys._weedReadQueued, sys._weedReadActive = nil, nil, nil
  sys:_requestWeedFieldRead(1, g_fieldManager.fields[1])
  T.eq("MP2 and a client never queues one", sys._weedReadQueue, nil)
end

g_server, g_fieldManager, g_fruitTypeManager = saved.g_server, saved.g_fieldManager, saved.g_fruitTypeManager
g_terrainNode, FieldState, FruitType = saved.g_terrainNode, saved.FieldState, saved.FruitType
g_currentMission.weedSystem, g_SoilFertilityManager = saved.weedSystem, saved.g_SoilFertilityManager
DensityMapModifier, DensityMapFilter = saved.DensityMapModifier, saved.DensityMapFilter
DensityMapMultiModifier, DensityValueCompareType = saved.DensityMapMultiModifier, saved.DensityValueCompareType
