-- zone_store_coherence_test.lua - per-cell store coherence: markBoomCells seeds on
--   CREATE and writes nothing on UPDATE.
--
--   markBoomCells used to re-stamp every cell under the boom with the field-level
--   pressures on every pass, which destroyed real per-cell work owned by other paths:
--     tillage reductions   - plough, cultivator, secondary tillage
--     treatment reductions - the entry map, insecticide, fungicide, herbicide
--   The treatment cases were the sharpest, because the base-class sprayer hook calls
--   markBoomCells in the SAME invocation that applied the product, so a per-cell
--   reduction was erased before the pass finished. Compaction already seeded on create
--   only; the three pressures now match it.
--
--   What this guards: a cell that already exists keeps every value it holds, a fresh
--   cell is still seeded from the field scalars, and the create path still accounts.
--   The DAILY weed propagation is a different function and is deliberately untouched,
--   so it is not exercised here.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua

local CELL = SoilConstants.ZONE.CELL_SIZE

local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.vmAvailable        = function() return false end  -- keep the #735 paint path out of this test
  s._getFieldPolyVerts = function() return nil end    -- polygon unavailable -> count all cells
  s.fieldData = {}
  return s
end

local function newField(s, fid)
  local f = {
    fieldArea = 10.0,
    sessionCoverageCells = {}, dailyCoverageCells = {}, zoneData = {},
    weedPressure = 40, pestPressure = 50, diseasePressure = 60, compaction = 70,
  }
  s.fieldData[fid] = f
  return f
end

-- one point, and the zoneData key markBoomCells will derive for it
local function onePt(x, z) return { { x = x, z = z } } end
local function keyFor(x, z)
  return tostring(math.floor(x / CELL) * 10000 + math.floor(z / CELL))
end

-- ── CREATE: a fresh cell is seeded from the field scalars ──────────────
do
  local s = newSys()
  local f = newField(s, 1)
  local k = keyFor(105, 105)

  s:markBoomCells(1, onePt(105, 105), true)

  local zc = f.zoneData[k]
  T.ok("coherence: a boom pass over virgin ground creates the cell", zc ~= nil)
  T.eq("coherence: create seeds weed from the field",     zc.weedPressure,    40)
  T.eq("coherence: create seeds pest from the field",     zc.pestPressure,    50)
  T.eq("coherence: create seeds disease from the field",  zc.diseasePressure, 60)
  T.eq("coherence: create seeds compaction from the field", zc.compaction,    70)
  T.eq("coherence: create still increments the cell accounting", f.zoneDataSize, 1)
end

-- ── UPDATE: an existing cell keeps its own values ──────────────────────
-- This is the defect. A tillage or treatment path reduced these; the stamper
-- must not put the field average back.
do
  local s = newSys()
  local f = newField(s, 1)
  local k = keyFor(105, 105)

  -- as plough / cultivator / insecticide / fungicide leave it
  f.zoneData[k] = { weedPressure = 5, pestPressure = 3, diseasePressure = 2, compaction = 11 }
  f.zoneDataSize = 1

  s:markBoomCells(1, onePt(105, 105), true)

  local zc = f.zoneData[k]
  T.eq("coherence: an existing cell keeps its reduced weed",    zc.weedPressure,    5)
  T.eq("coherence: an existing cell keeps its reduced pest",    zc.pestPressure,    3)
  T.eq("coherence: an existing cell keeps its reduced disease", zc.diseasePressure, 2)
  T.eq("coherence: an existing cell keeps its own compaction",  zc.compaction,      11)
  T.eq("coherence: update does not double-count the cell", f.zoneDataSize, 1)
end

-- ── the same-invocation case, which is how a player actually hits it ───
-- Spray insecticide (the treatment path reduces the cell), then the boom stamp
-- runs in the same hook call. The reduction has to survive it.
do
  local s = newSys()
  local f = newField(s, 1)
  local k = keyFor(105, 105)

  s:markBoomCells(1, onePt(105, 105), true)          -- cell exists, seeded at field level
  T.eq("coherence: seeded at the field pest level", f.zoneData[k].pestPressure, 50)

  -- what applyInsecticide does to the cell it just sprayed
  f.zoneData[k].pestPressure = math.max(0, f.zoneData[k].pestPressure - 20)

  s:markBoomCells(1, onePt(105, 105), true)          -- second call, same pass

  T.eq("coherence: an insecticide reduction survives the boom stamp in the same pass",
       f.zoneData[k].pestPressure, 30)
end

-- ── a partially populated cell fills only its missing keys ────────────
-- Cells reach the stamper from several paths and not all carry every key.
do
  local s = newSys()
  local f = newField(s, 1)
  local k = keyFor(105, 105)

  f.zoneData[k] = { pestPressure = 3 }   -- only pest present
  f.zoneDataSize = 1

  s:markBoomCells(1, onePt(105, 105), true)

  local zc = f.zoneData[k]
  T.eq("coherence: the present key is preserved", zc.pestPressure, 3)
  T.eq("coherence: a missing key is seeded from the field", zc.weedPressure,    40)
  T.eq("coherence: a missing key is seeded from the field", zc.diseasePressure, 60)
  T.eq("coherence: a missing key is seeded from the field", zc.compaction,      70)
end

-- ── the stamper never invents nutrients ───────────────────────────────
-- Under the value-map engine N/P/K/pH/OM live on the per-pixel maps, so a cell
-- created by a crop-protection pass must not carry a nutrient claim (#517's shape).
do
  local s = newSys()
  local f = newField(s, 1)
  local k = keyFor(105, 105)

  s:markBoomCells(1, onePt(105, 105), true)

  local zc = f.zoneData[k]
  T.ok("coherence: a created cell carries no N", zc.N  == nil)
  T.ok("coherence: a created cell carries no P", zc.P  == nil)
  T.ok("coherence: a created cell carries no K", zc.K  == nil)
  T.ok("coherence: a created cell carries no pH", zc.pH == nil)
  T.ok("coherence: a created cell carries no OM", zc.OM == nil)
end

-- ── several cells under one boom are handled independently ────────────
do
  local s = newSys()
  local f = newField(s, 1)
  local kA, kB = keyFor(105, 105), keyFor(125, 105)

  f.zoneData[kA] = { weedPressure = 1, pestPressure = 1, diseasePressure = 1, compaction = 1 }
  f.zoneDataSize = 1

  s:markBoomCells(1, { { x = 105, z = 105 }, { x = 125, z = 105 } }, true)

  T.eq("coherence: the visited cell is left alone", f.zoneData[kA].pestPressure, 1)
  T.ok("coherence: the untouched neighbour is created", f.zoneData[kB] ~= nil)
  T.eq("coherence: the new neighbour seeds from the field", f.zoneData[kB].pestPressure, 50)
  T.eq("coherence: only the new cell is counted", f.zoneDataSize, 2)
end
