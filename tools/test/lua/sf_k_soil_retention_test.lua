-- sf_k_soil_retention_test.lua - potassium leach by soil class (K_LEACH_BY_SOIL).
--   K+ is held on clay exchange sites and washes through sand, so applyRainEffects
--   scales potassium leaching (only) by SoilConstants.RAIN.K_LEACH_BY_SOIL for the
--   field's SCS soil class, referenced to loam = 1.0. With no SCS, an unknown class,
--   or a throwing getter, the factor is 1.0 and the leach is exactly the old one.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SpatialNutrients.lua, src/SoilFertilitySystem.lua

local KT = SoilConstants.RAIN.K_LEACH_BY_SOIL

local function setSCS(classOrFn)
  if classOrFn == nil then
    g_currentMission = { }
    return
  end
  g_currentMission = { cropStressManager = {
    getFieldSoilType = function(_self, _fid)
      if type(classOrFn) == "function" then return classOrFn() end
      return classOrFn
    end,
    getMoisture = function() return nil end,
  } }
end

local function leachSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true, rainEffects = true, weatherSource = 3 }
  s.vmAvailable = function() return false end
  s.activeFieldIds = { [1] = true }
  s.fieldData = { [1] = { nitrogen = 50, potassium = 50, phosphorus = 50, pH = 6.5,
                           organicMatter = 3 } }
  s._rainWasFilled = false
  return s
end

local function lossFor(classOrFn)
  setSCS(classOrFn)
  local s = leachSys()
  s:applyRainEffects(1e6, 0.5)
  local f = s.fieldData[1]
  return { N = 50 - f.nitrogen, K = 50 - f.potassium, P = 50 - f.phosphorus }
end

-- ---------------------------------------------------------------------
-- The table itself: loam is the reference, clay holds, sand leaches.
-- ---------------------------------------------------------------------
T.eq("table: loam is the 1.0 reference", KT.loamy, 1.0)
T.ok("table: clay holds potassium (factor below loam)", KT.clay < KT.loamy)
T.ok("table: sand leaches potassium (factor above loam)", KT.sandy > KT.loamy)
T.near("table: sand:clay keeps the 1.0:0.3 ratio", KT.sandy / KT.clay, 1.0 / 0.3, 1e-9)

-- ---------------------------------------------------------------------
-- Neutral paths: byte-identical to the pre-change leach.
-- ---------------------------------------------------------------------
local none   = lossFor(nil)
local loam   = lossFor("loamy")
local bogus  = lossFor("peat")
local throws = lossFor(function() error("scs blew up") end)

T.ok("neutral: some potassium actually leached, so comparisons are not vacuous", none.K > 0)
T.near("neutral: no SCS leaches K exactly as before (leachFactor x POTASSIUM_MULTIPLIER)",
       none.K, none.P / SoilConstants.RAIN.PHOSPHORUS_MULTIPLIER * SoilConstants.RAIN.POTASSIUM_MULTIPLIER, 1e-9)
T.near("neutral: a loamy field leaches K exactly as a field with no SCS", loam.K, none.K, 1e-12)
T.near("neutral: an unknown soil class leaches K as no SCS", bogus.K, none.K, 1e-12)
T.near("neutral: a throwing SCS getter leaches K as no SCS", throws.K, none.K, 1e-12)

do
  local s = leachSys()
  setSCS(nil)
  local f, c = s:potassiumLeachSoilFactor(1)
  T.eq("helper: no SCS returns factor 1.0", f, 1.0)
  T.eq("helper: no SCS returns no class", c, nil)
  setSCS("CLAY")
  f, c = s:potassiumLeachSoilFactor(1)
  T.eq("helper: class is matched case-insensitively", c, "clay")
  T.eq("helper: clay returns the clay factor", f, KT.clay)
end

-- ---------------------------------------------------------------------
-- Clay and sand scale potassium by their factor.
-- ---------------------------------------------------------------------
local clay  = lossFor("clay")
local sandy = lossFor("sandy")

T.near("clay: K loss is the loam loss x the clay factor", clay.K, loam.K * KT.clay, 1e-12)
T.near("sand: K loss is the loam loss x the sand factor", sandy.K, loam.K * KT.sandy, 1e-12)
T.ok("order: sand loses more K than loam, loam more than clay", sandy.K > loam.K and loam.K > clay.K)

-- ---------------------------------------------------------------------
-- Potassium only: nitrogen (an anion) and phosphorus are untouched by soil class.
-- ---------------------------------------------------------------------
T.near("scope: clay does not change nitrogen leaching", clay.N, loam.N, 1e-12)
T.near("scope: sand does not change nitrogen leaching", sandy.N, loam.N, 1e-12)
T.near("scope: clay does not change phosphorus leaching", clay.P, loam.P, 1e-12)
T.near("scope: sand does not change phosphorus leaching", sandy.P, loam.P, 1e-12)

-- ---------------------------------------------------------------------
-- The value-map mirror carries the same scaled K delta as the field scalar.
-- ---------------------------------------------------------------------
do
  setSCS("clay")
  local s = leachSys()
  local queued = {}
  s.vmAvailable = function() return true end
  s._vmQueueFieldDelta = function(_self, _field, key, d) queued[key] = (queued[key] or 0) + d end
  s._vmFlushFieldDeltas = function() end
  s:applyRainEffects(1e6, 0.5)
  T.near("map: the queued K delta equals the field-scalar K loss on clay",
         -queued.potassium, 50 - s.fieldData[1].potassium, 1e-12)
end

-- ---------------------------------------------------------------------
-- Production entry point: onEnvironmentUpdate -> applyRainEffects, three fields with
-- different classes. The SCS stub looks the class up BY FIELD ID the way
-- CropStressManager:getFieldSoilType does (soilSystem.fieldData[id].soilType), so a
-- wrong or nil id reaching the helper turns the factor neutral and fails here.
-- (Review MAJOR 1 on #1172.)
-- ---------------------------------------------------------------------
do
  local CLAY_ID, SAND_ID, LOAM_ID = 10, 20, 30
  local scsFields = {
    [CLAY_ID] = { soilType = "clay" },
    [SAND_ID] = { soilType = "sandy" },
    [LOAM_ID] = { soilType = "loamy" },
  }
  local seen, nilAsked = {}, false
  g_currentMission = {
    environment = { weather = { getRainFallScale = function() return 0.5 end } },
    cropStressManager = {
      soilSystem = { fieldData = scsFields },
      getFieldSoilType = function(self, fieldId)
        if fieldId == nil then nilAsked = true else seen[#seen + 1] = fieldId end
        local rec = self.soilSystem.fieldData[fieldId]
        return rec and rec.soilType or nil
      end,
      getMoisture = function() return nil end,
    },
  }
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true, rainEffects = true, weatherSource = 1 }
  s.vmAvailable = function() return false end
  s.lastUpdateDay = 5                     -- same day: skip the daily pass
  s.activeFieldIds = { [CLAY_ID] = true, [SAND_ID] = true, [LOAM_ID] = true }
  s.fieldData = {}
  for id in pairs(s.activeFieldIds) do
    s.fieldData[id] = { nitrogen = 50, potassium = 50, phosphorus = 50, pH = 6.5, organicMatter = 3 }
  end

  s:onEnvironmentUpdate({ currentDay = 5 }, 1e6)

  local kLoss = function(id) return 50 - s.fieldData[id].potassium end
  T.ok("entry: rain reached applyRainEffects (loam field lost K)", kLoss(LOAM_ID) > 0)
  T.near("entry: the clay field gets the clay factor", kLoss(CLAY_ID), kLoss(LOAM_ID) * KT.clay, 1e-12)
  T.near("entry: the sandy field gets the sand factor", kLoss(SAND_ID), kLoss(LOAM_ID) * KT.sandy, 1e-12)
  local asked = {}
  for _, id in ipairs(seen) do asked[id] = true end
  T.ok("entry: SCS was asked about each field by its own id",
       asked[CLAY_ID] and asked[SAND_ID] and asked[LOAM_ID])
  T.eq("entry: SCS was never asked about a nil id", nilAsked, false)
end

-- ---------------------------------------------------------------------
-- Banded value-map path (SpatialNutrients, two or more bands): the K that lands on
-- the map across the bands adds up to the field-scalar K loss, which is the scaled
-- one. (Review MAJOR 2 on #1172.)
-- ---------------------------------------------------------------------
do
  T.ok("banded: SpatialNutrients loaded and enabled", SpatialNutrients ~= nil and SpatialNutrients.ENABLED)
  SpatialNutrients._resolverMult = nil

  setSCS("clay")
  local s = leachSys()
  local field = s.fieldData[1]
  field._snBands = {
    { key = 1, moisture = 0.2, points = { {x=0,z=0}, {x=10,z=0}, {x=0,z=10} } },
    { key = 2, moisture = 0.5, points = { {x=20,z=0}, {x=30,z=0}, {x=20,z=10} } },
    { key = 3, moisture = 0.9, points = { {x=40,z=0}, {x=50,z=0}, {x=40,z=10} } },
  }
  local mapK, uniformK = 0, 0
  s.vmAvailable = function() return true end
  s.valueMaps = { applyDeltaToPolygon = function(_self, key, _hull, amount)
    if key == "potassium" then mapK = mapK + amount end
    return amount
  end }
  s._vmQueueFieldDelta = function(_self, _field, key, d)
    if key == "potassium" then uniformK = uniformK + d end
  end
  s._vmFlushFieldDeltas = function() end

  s:applyRainEffects(1e6, 0.5)

  local scalarK = 50 - field.potassium
  T.ok("banded: some K went through the bands", mapK < 0)
  T.eq("banded: no K fell back to the uniform queue", uniformK, 0)
  T.near("banded: the banded K adds up to the field-scalar K loss on clay", -mapK, scalarK, 1e-12)
  T.near("banded: and that loss is the clay-scaled one", scalarK, loam.K * KT.clay, 1e-12)
  SpatialNutrients = nil
end

-- ---------------------------------------------------------------------
-- No getSoilType on the manager (SCS today): the fallback is skipped, not called
-- through pcall. (Review MINOR 4 on #1172.)
-- ---------------------------------------------------------------------
do
  local pcalls = 0
  local realPcall = pcall
  g_currentMission = { cropStressManager = { getFieldSoilType = function() return nil end } }
  local s = leachSys()
  pcall = function(f, ...) pcalls = pcalls + 1; return realPcall(f, ...) end
  local f, c = s:potassiumLeachSoilFactor(1)
  pcall = realPcall
  T.eq("fallback: unclassed field is neutral", f, 1.0)
  T.eq("fallback: unclassed field has no class", c, nil)
  T.eq("fallback: only getFieldSoilType was called, the missing getSoilType was not", pcalls, 1)
end

g_currentMission = nil
