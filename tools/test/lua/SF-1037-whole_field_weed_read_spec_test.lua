-- SF-1037-whole_field_weed_read_spec_test.lua
--
-- #1037 cause 2: the daily weed read measures the WHOLE field, from a read taken for
-- that day's pass.
--
-- THE DEFECTS THIS PINS:
--   * development 79e00157: _sampleFieldWeedFactor averaged 17 points within 30 m of the
--     field's reference point, about 4% of a 6.6 ha field. On Sauge's field, herbicide
--     over about 80% of it (centre included) left a live strip the read never reached,
--     so weed risk read 0% for good after protection ran out.
--   * #1049's first head ed7e54d6 (Bob's FAIL, issuecomment-5891383272): a finished read
--     was kept and returned on later days, so a read taken before a cultivation came back
--     after the sowing and reported weeds the field no longer had.
--
-- THE ENTRY-POINT BAR: every row drives production's own entries. A day is
-- updateDailySoil (which queues the day's reads) followed by SoilFertilitySystem:update(dt)
-- frames until the batch drains (the whole-field read advances one slice a frame, the
-- batch waits on a field while its read runs, then the real _processOneDailyField runs).
-- Nothing sets weedPressure, a factor or a read result by hand. The fixture supplies what
-- the engine supplies:
--   * a weed density map keyed by pixel (2 m pixels, 4 channels, so values 0-15) with the
--     vanilla factors from data/maps/maps_weed.xml (3 = 0.5, 4 = 0.75, 5 = 1.0, 6 = 0.5,
--     8 = 0.5, 9 = 0.75) and vanilla's herbicide replacements (8 and 9 are withered);
--   * the density-map objects the engine's own whole-field reads use
--     (HerbicideMission.lua:36-55, FieldGetInfoTask.lua:38-85, DensityMapPolygon.lua:58-66),
--     modelled as a counter over that pixel map: the polygon's points bound the pixels,
--     the clip region bounds a slice, and each get reports its running count since
--     resetStats. execute returns NOTHING, so no count can come from its return values;
--   * FieldState reading the same pixel map at a point, for the centre gate and the
--     ring fallback;
--   * FieldSentry (src/FieldSentry.lua, loaded as the mod loads it). Groups M and Z set a
--     field's meadow toggle and sleep flag only through FieldSentry's own setters.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/FieldSentry.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local saved = {
  g_server = g_server, g_fieldManager = g_fieldManager, g_fruitTypeManager = g_fruitTypeManager,
  g_terrainNode = g_terrainNode, FieldState = FieldState, FruitType = FruitType,
  weedSystem = g_currentMission.weedSystem, environment = g_currentMission.environment,
  g_SoilFertilityManager = g_SoilFertilityManager,
  DensityMapModifier = DensityMapModifier, DensityMapFilter = DensityMapFilter,
  DensityMapMultiModifier = DensityMapMultiModifier, DensityValueCompareType = DensityValueCompareType,
}

FruitType = FruitType or { UNKNOWN = 0 }
g_fruitTypeManager = { getFruitTypeByIndex = function() return { name = "WHEAT" } end }
g_SoilFertilityManager = nil
g_terrainNode = 1
g_currentMission.environment = { currentDay = 100, currentSeason = 1, daysPerPeriod = 1 }

-- ── The weed map ─────────────────────────────────────────────────────────────
local PX = 2                                  -- metres per pixel
local W, H = 250, 260                         -- the field, metres (6.5 ha)
local CX, CZ = 125, 130                       -- its reference point
local FIELD_PIXELS = (W / PX) * (H / PX)      -- 16,250
local MAP = {}                                -- MAP[i][j] = weed value of pixel (i, j)
local FACTORS = { [3] = 0.5, [4] = 0.75, [5] = 1.0, [6] = 0.5, [8] = 0.5, [9] = 0.75 }
local VANILLA_HERBICIDE = { [1] = 0, [2] = 0, [3] = 7, [4] = 8, [5] = 9, [6] = 7 }

local function paint(stateAt)                 -- stateAt(x, z) -> value at a pixel centre
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
local EXECUTES, PIXELS_SEEN, GETS_LAST = 0, 0, 0
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
      GETS_LAST = #self.gets
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
      for i, col in pairs(MAP) do
        local x = i * PX + PX / 2
        if x >= x0 and x < x1 then
          for j, state in pairs(col) do
            local z = j * PX + PX / 2
            if z >= z0 and z < z1 and z >= lo and z < hi then
              PIXELS_SEEN = PIXELS_SEEN + 1
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
      -- deliberately no return values: production must count its own denominator
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

-- ── The system, driven through updateDailySoil and update() ──────────────────
local function newField(weedPressure)
  return { nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.5,
           lastHarvest = 99, lastCrop = "wheat", weedPressure = weedPressure, herbicideDaysLeft = 0 }
end

local function newSystem(field, polygon)
  g_server = {}
  local getPolygon = function() return POLYGON end
  if polygon == false then getPolygon = function() return nil end end
  g_fieldManager = { fields = { [1] = { posX = CX, posZ = CZ, farmland = { id = 1 },
                                        getDensityMapPolygon = getPolygon } } }
  return setmetatable({
    fieldData = { [1] = field }, activeFieldIds = { [1] = true }, _activeListDirty = true,
    settings = { enabled = true, weedPressure = true, nutrientCycles = true },
    herbicideAppliedDay = {}, lastUpdate = 0, updateInterval = 1e9,
    DAILY_BATCH_SIZE = 25,                    -- the constructor's value, SoilFertilitySystem.lua:252
  }, { __index = SoilFertilitySystem })
end

-- One in-game day: the real queue step, then frames until the batch drains, then the
-- rest of the day's frames until no read is queued or running (the game keeps ticking
-- after the batch, so a read asked for during the pass also finishes that day).
-- Returns the frames the batch took, and the most slices and pixels in any one frame.
local function runDay(sys, day)
  g_currentMission.environment.currentDay = day
  sys:updateDailySoil(1)
  local frames, total, worst, worstPixels = 0, 0, 0, 0
  local function frame()
    local e, p = EXECUTES, PIXELS_SEEN
    sys:update(16)
    total = total + 1
    worst = math.max(worst, EXECUTES - e)
    worstPixels = math.max(worstPixels, PIXELS_SEEN - p)
  end
  while sys._pendingDailyUpdate and total < 200 do frame(); frames = total end
  -- a batch that never drains is left to fail its rows by value (frames reads 200)
  while (sys._weedReadActive ~= nil or (sys._weedReadQueue ~= nil and #sys._weedReadQueue > 0))
        and total < 400 do
    frame()
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

  local frames, worst, worstPixels = runDay(sys, 101)
  -- 20% of the field at factor 0.5 -> 10 points; the withered 80% counts 0, not 0.5.
  T.near("W1 day 1: weed risk shows the unsprayed share, 20% x 0.5 = 10, not 0", field.weedPressure, 10, 1e-6)
  T.eq("W2 the day's pass waited for its read: one 30 m slice a frame, " .. SLICES .. " frames for 260 m",
       frames, SLICES)
  T.eq("W3 no frame runs more than one slice", worst, 1)
  T.ok("W3b and no frame counts more than one 30 m band of the field's pixels",
       worstPixels <= (30 / PX) * (W / PX))
  local read = sys._weedFieldReads and sys._weedFieldReads[1]
  T.eq("W4 the read counted every value the map can hold (4 channels, 16 gets)", GETS_LAST, 16)
  T.eq("W4b its pixel total is the field's, counted from those gets (execute returns nothing)",
       type(read) == "table" and read.pixels or nil, FIELD_PIXELS)

  -- The strip grows on: the next day's pass reads the map as it is then.
  paint(function(x) return (x < 0.8 * W) and 8 or 5 end)
  runDay(sys, 102)
  T.near("W5 day 2: the next day's read follows the map (20% x 1.0 = 20)", field.weedPressure, 20, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- S: A READ NEVER OUTLIVES ITS DAY (Bob's BLOCKER on ed7e54d6)
-- ══════════════════════════════════════════════════════════
do
  -- Weedy, then cultivated (clean map, no crop at the centre), then sown (crop back).
  paint(function() return 5 end)
  local field = newField(0)
  local sys = newSystem(field)
  runDay(sys, 101)
  T.near("S1a a weedy field reads up to its cap on day 1 (0 + 20)", field.weedPressure, 20, 1e-6)
  paint(function() return 0 end)
  CROP_AT_CENTRE = FruitType.UNKNOWN
  runDay(sys, 102)
  T.eq("S1b cultivated, bare: day 2 reads 0", field.weedPressure, 0)
  CROP_AT_CENTRE = 3
  runDay(sys, 103)
  T.eq("S1 sown on the clean ground: day 3 reads 0, not the weedy read from before cultivation",
       field.weedPressure, 0)
end
do
  -- Cultivated and sown on the same day: the centre gate never sees bare ground.
  paint(function() return 5 end)
  local field = newField(0)
  local sys = newSystem(field)
  runDay(sys, 101)
  paint(function() return 0 end)
  runDay(sys, 102)
  T.eq("S2 cultivated and sown the same day: the next day reads 0, not yesterday's weeds",
       field.weedPressure, 0)
end

-- ══════════════════════════════════════════════════════════
-- Q: A QUEUED READ SERVES THE DAY IT RUNS FOR
-- ══════════════════════════════════════════════════════════
do
  -- A read asked for on day 101 has not started when day 102's batch is queued: it is
  -- taken during day 102's wait, so it is day 102's read.
  paint(function(x) return (x < 0.8 * W) and 8 or 3 end)
  local field = newField(0)
  local sys = newSystem(field)
  sys:_requestWeedFieldRead(1, g_fieldManager.fields[1], 101)
  runDay(sys, 102)
  T.near("Q1 a read queued for an earlier day and not yet started serves the day it runs for", field.weedPressure, 10, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- F: A READ THAT CANNOT RUN NEVER HOLDS THE BATCH
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)
  local field = newField(75)
  local sys = newSystem(field, false)         -- the field reports no density-map polygon
  local frames = runDay(sys, 101)
  T.eq("F1 a read that cannot start does not hold the day's batch", frames, 1)
  T.near("F1b and the pass keeps the ring average (75)", field.weedPressure, 75, 1e-6)
end
do
  -- Day 1 reads a weedy field. On day 2 the field is clean and its read cannot start: the
  -- pass must fall back to the ring, never reuse day 1's read.
  paint(function() return 5 end)
  local field = newField(0)
  local sys = newSystem(field)
  runDay(sys, 101)
  paint(function() return 0 end)
  g_fieldManager.fields[1].getDensityMapPolygon = function() return nil end
  runDay(sys, 102)
  T.eq("F2 a day whose read cannot start reads the ring (0), not an earlier day's read", field.weedPressure, 0)
end

-- ══════════════════════════════════════════════════════════
-- C: CONTROLS
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)              -- uniformly weedy, 0.75 everywhere
  local field = newField(75)
  local sys = newSystem(field)
  runDay(sys, 101)
  T.near("C1 a uniformly weedy field reads 75, the same as the rings read it", field.weedPressure, 75, 1e-6)
end
do
  paint(function() return 0 end)              -- clean
  local field = newField(0)
  local sys = newSystem(field)
  runDay(sys, 101)
  T.eq("C2 a clean field reads 0", field.weedPressure, 0)
end
do
  paint(function() return 4 end)
  CROP_AT_CENTRE = FruitType.UNKNOWN          -- no managed crop at the centre
  local field = newField(0)
  local sys = newSystem(field)
  local before = EXECUTES
  local frames = runDay(sys, 101)
  T.eq("C3 no managed crop at the centre reads 0", field.weedPressure, 0)
  T.eq("C3b no whole-field read is made for it", EXECUTES - before, 0)
  T.eq("C3c and its day is not held up", frames, 1)
  CROP_AT_CENTRE = 3
end

-- ══════════════════════════════════════════════════════════
-- M: A MEADOW QUEUES NO READ (MAINTENANCE row 177). The daily pass returns before its
-- weed block for a meadow (_processOneDailyField), so a read queued for one was never
-- used, and the batch still waited for it.
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)              -- uniformly weedy, a crop field reads 75
  FieldSentry_API.reset()
  local field = newField(40)
  local sys = newSystem(field)
  FieldSentry_API.setFieldMeadow(1, true)     -- the player's meadow toggle
  local before = EXECUTES
  local frames = runDay(sys, 101)
  T.eq("M1 a meadow with a crop at its centre gets no whole-field read", EXECUTES - before, 0)
  T.eq("M2 and its day is not held up", frames, 1)
  -- Meadow rules shed MEADOW.PRESSURE_DECAY (2.0, Constants.lua) a day; crop rules would
  -- have risen toward the map's 75.
  T.near("M3 the pass keeps it on meadow rules: weed risk sheds 2 a day (40 to 38)", field.weedPressure, 38, 1e-6)
  FieldSentry_API.setFieldMeadow(1, false)    -- the toggle off: an ordinary crop field again
  before = EXECUTES
  frames = runDay(sys, 102)
  T.ok("M4 the same field with the toggle off gets its read the next day", EXECUTES - before > 0)
  T.eq("M4b and the pass waits for it, one slice a frame", frames, SLICES)
  T.near("M4c and moves toward the map's 75 by the day's cap (38 + 20 = 58)", field.weedPressure, 58, 1e-6)
  FieldSentry_API.reset()
end

-- ══════════════════════════════════════════════════════════
-- Z: A FIELD PUT TO SLEEP QUEUES NO READ (the #1049 gate this change rewrites)
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)
  FieldSentry_API.reset()
  local field = newField(40)
  local sys = newSystem(field)
  FieldSentry_API.setFieldManual(1, true)     -- the player puts the field to sleep
  local before = EXECUTES
  local frames = runDay(sys, 101)
  T.eq("Z1 a field put to sleep gets no whole-field read", EXECUTES - before, 0)
  T.eq("Z2 and its day is not held up", frames, 1)
  T.eq("Z3 and its values stay frozen (40)", field.weedPressure, 40)
  FieldSentry_API.reset()
end

-- ══════════════════════════════════════════════════════════
-- MP: the read never runs on a client
-- ══════════════════════════════════════════════════════════
do
  paint(function() return 4 end)
  local field = newField(0)
  local sys = newSystem(field)
  sys:_requestWeedFieldRead(1, g_fieldManager.fields[1], 101)   -- queued on the server
  g_server = nil                              -- the same state seen on a client
  local before = EXECUTES
  for _ = 1, 20 do sys:update(16) end
  T.eq("MP1 a client's update() executes no slice of a queued read", EXECUTES - before, 0)
  sys._weedReadQueue, sys._weedReadQueued, sys._weedReadActive = nil, nil, nil
  sys:_requestWeedFieldRead(1, g_fieldManager.fields[1], 101)
  T.eq("MP2 and a client never queues one", sys._weedReadQueue, nil)
end

g_server, g_fieldManager, g_fruitTypeManager = saved.g_server, saved.g_fieldManager, saved.g_fruitTypeManager
g_terrainNode, FieldState, FruitType = saved.g_terrainNode, saved.FieldState, saved.FruitType
g_currentMission.weedSystem, g_currentMission.environment = saved.weedSystem, saved.environment
g_SoilFertilityManager = saved.g_SoilFertilityManager
DensityMapModifier, DensityMapFilter = saved.DensityMapModifier, saved.DensityMapFilter
DensityMapMultiModifier, DensityValueCompareType = saved.DensityMapMultiModifier, saved.DensityValueCompareType
