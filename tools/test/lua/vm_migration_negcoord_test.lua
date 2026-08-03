-- vm_migration_negcoord_test.lua - the old-save zoneData -> value-map migration
-- must place each legacy cell at its TRUE world position, including cells on
-- negative coordinates. The legacy key cx*10000+cz is not invertible once a
-- coordinate is negative (cell (2,-3) encodes to 19997 and a naive decode reads
-- it back as (1,9997)), so vmSeedField walks the field polygon and ENCODES each
-- position instead. This proves the negative-coord cell lands right, and NOT at
-- the buggy decoded position.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local CS = SoilConstants.ZONE.CELL_SIZE

-- Capture every value-map write.
local writes = {}
local vm = {
  available = true,
  getLayerEntry = function(_self, _key) return { loaded = false } end,   -- always seed
  seedPolygon = function() end,
  paintPolygon = function() end,
  writeValueAtWorld = function(_self, key, wx, wz, val, _half)
    writes[#writes + 1] = { key = key, wx = wx, wz = wz, val = val }
  end,
}

-- A field square spanning negative and positive coords, cells at a negative-cz
-- position and a positive one, both differing from the field average so the
-- migration path fires.
local field = {
  nitrogen = 40, phosphorus = 40, potassium = 40, pH = 6.5, organicMatter = 3,
  zoneData = {
    [tostring(2 * 10000 + (-3))] = { N = 90 },   -- (cx=2, cz=-3): the hard case
    [tostring(1 * 10000 + 1)]    = { N = 70 },   -- (cx=1, cz=1): sanity
  },
}
local verts = {
  { x = -5 * CS, z = -5 * CS }, { x = 5 * CS, z = -5 * CS },
  { x =  5 * CS, z =  5 * CS }, { x = -5 * CS, z = 5 * CS },
}

local sys = setmetatable({ valueMaps = vm, fieldData = { [1] = field } },
                         { __index = SoilFertilitySystem })
sys._getFieldPolyVerts = function() return verts end   -- bypass g_fieldManager

sys:vmSeedField(1, false)

local function findN(wx, wz)
  for _, w in ipairs(writes) do
    if w.key == "nitrogen" and math.abs(w.wx - wx) < 1e-6 and math.abs(w.wz - wz) < 1e-6 then
      return w.val
    end
  end
  return nil
end

-- Correct: (cx=2, cz=-3) -> centre (2.5*CS, -2.5*CS)
T.near("neg-coord cell at CORRECT world pos", findN(2.5 * CS, -2.5 * CS) or -1, 90, 1e-6)
-- The old decode of key 19997 was (1, 9997) -> (1.5*CS, 9997.5*CS). Must be absent.
T.eq("neg-coord cell NOT at buggy decode pos", findN(1.5 * CS, 9997.5 * CS), nil)
-- Sanity: the positive cell still lands right.
T.near("pos-coord cell at correct world pos", findN(1.5 * CS, 1.5 * CS) or -1, 70, 1e-6)
-- And nothing was painted off in the 9997-row at all.
do
  local strayFarRow = false
  for _, w in ipairs(writes) do
    if math.abs(w.wz) > 100 * CS then strayFarRow = true end
  end
  T.ok("no writes stranded far off-field", not strayFarRow)
end
