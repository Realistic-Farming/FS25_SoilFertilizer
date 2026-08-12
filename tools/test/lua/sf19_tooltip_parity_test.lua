-- sf19_tooltip_parity_test.lua - SF-19 item 4: the tooltip (getFieldInfo) must
-- answer a POSITIONAL pest/disease/compaction question with the same per-cell
-- truth the map paints, not the field scalar. The map reads the runtime value
-- maps; so does this. The disease discovery gate applies the same way: an
-- unscouted patch never leaks through shownDiseasePressure, and the raw
-- diseasePressure stays ungated for the NPC roll and scouting.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

-- A value-maps mock: readValueAtWorld returns per-key values so the test can
-- tell whether the positional read won over the field scalar.
local function makeVm(overrides)
  local values = {
    nitrogen = 70, phosphorus = 60, potassium = 65, pH = 6.2, organicMatter = 4,
    pestPressure = 33, diseasePressure = 77, compaction = 9,
  }
  for k, v in pairs(overrides or {}) do values[k] = v end
  return {
    available = true,
    readValueAtWorld = function(_self, key, _x, _z) return values[key] end,
  }
end

local function newSys(vm, fieldOver)
  local field = {
    nitrogen = 40, phosphorus = 30, potassium = 50, pH = 6.5, organicMatter = 3,
    weedPressure = 10, pestPressure = 20, diseasePressure = 60,
    diseaseDiscovered = false, lastCrop = "wheat", lastCrop2 = nil,
    lastCrop3 = nil, lastHarvest = 0, rotationBonusDaysLeft = 0,
  }
  for k, v in pairs(fieldOver or {}) do field[k] = v end
  local s = setmetatable({
    valueMaps = vm,
    fieldData = { [1] = field },
    settings  = { enabled = false, diseasePressure = true },   -- disease enabled; keep the yield-modifier path cold
  }, { __index = SoilFertilitySystem })
  -- Bypass the real polygon path entirely; getFieldInfo uses it only for crop
  -- detection, which is not what this test measures.
  s._getFieldPolyVerts = function() return nil end
  return s, field
end

-- ── 1. Positional reads win over the field scalar ─────────────────────────
do
  local s = newSys(makeVm())
  local info = s:getFieldInfo(1, 123, -45)
  T.eq("positional pest overrides the field scalar", info.pestPressure, 33)
  T.eq("positional disease overrides the field scalar", info.diseasePressure, 77)
  T.eq("positional compaction overrides the field scalar", info.compaction, 9)
  T.ok("positional read marks fromZoneCell", info.fromZoneCell)
end

-- ── 2. The discovery gate holds on the positional disease read ─────────────
do
  -- Unscouted: shownDiseasePressure must be nil (UI shows "Unscouted"), while
  -- the raw diseasePressure stays ungated (the NPC roll still sees it).
  local s = newSys(makeVm({ diseasePressure = 77 }), { diseaseDiscovered = false })
  local info = s:getFieldInfo(1, 123, -45)
  T.eq("unscouted positional disease: raw value kept", info.diseasePressure, 77)
  T.eq("unscouted positional disease: shown is nil", info.shownDiseasePressure, nil)

  -- Scouted: shownDiseasePressure reveals the positional truth.
  local s2 = newSys(makeVm({ diseasePressure = 77 }), { diseaseDiscovered = true })
  local info2 = s2:getFieldInfo(1, 123, -45)
  T.eq("scouted positional disease: shown is the real value", info2.shownDiseasePressure, 77)
end

-- ── 3. No value maps / no position -> field scalar fallback ────────────────
do
  local s = newSys(nil)
  local info = s:getFieldInfo(1)
  T.eq("no maps, no position: field pest scalar", info.pestPressure, 20)
  T.eq("no maps, no position: field disease scalar", info.diseasePressure, 60)
  T.eq("no maps, no position: field compaction scalar", info.compaction, 0)
  T.ok("no position: fromZoneCell false", not info.fromZoneCell)
end
