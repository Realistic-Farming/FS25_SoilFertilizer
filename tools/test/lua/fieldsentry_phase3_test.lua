-- fieldsentry_phase3_test.lua - FieldSentry Phase 3 meadow profile (#651).
-- Covers the meadow toggle API + persistence (FieldSentry) and the grassland daily
-- profile + daily-loop routing (SoilFertilitySystem). Pure Lua mocks only.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/FieldSentry.lua, src/SoilFertilitySystem.lua

-- ── meadow toggle API ──────────────────────────────────────
do
  FieldSentry_API.reset()
  T.ok("isFieldMeadow false for unknown field", FieldSentry_API.isFieldMeadow(1) == false)
  T.ok("setFieldMeadow(true) returns true", FieldSentry_API.setFieldMeadow(1, true) == true)
  T.ok("isFieldMeadow true after set", FieldSentry_API.isFieldMeadow(1) == true)
  -- A meadow is NOT sim-disabled: it still runs, just on grassland rules.
  T.ok("meadow does not disable the sim", FieldSentry_API.isFieldSimDisabled(1) == false)
  -- isFieldSimDisabled returns the meadow flag as its third value.
  local _, _, meadow = FieldSentry_API.isFieldSimDisabled(1)
  T.ok("hot path reports the meadow flag", meadow == true)
  T.ok("toggleFieldMeadow flips it off", FieldSentry_API.toggleFieldMeadow(1) == false)
end

do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldMeadow(7, true)
  FieldSentry_API.setFieldMeadow(2, true)
  local list = FieldSentry_API.getMeadowList()
  T.eq("getMeadowList count", #list, 2)
  T.ok("getMeadowList sorted", list[1] == 2 and list[2] == 7)
end

-- ── persistence: meadow flag survives a save/load ──────────
do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldMeadow(5, true)
  local xml = {}
  FieldSentry_API.saveToXMLFile(xml, "soilData.fieldSentry")
  FieldSentry_API.reset()
  T.ok("meadow cleared before load", FieldSentry_API.isFieldMeadow(5) == false)
  FieldSentry_API.loadFromXMLFile(xml, "soilData.fieldSentry")
  T.ok("meadow flag round-trips through save/load", FieldSentry_API.isFieldMeadow(5) == true)
end

-- a field that is BOTH blacklisted and meadow keeps both flags across save/load
do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(8, true)
  FieldSentry_API.setFieldMeadow(8, true)
  local xml = {}
  FieldSentry_API.saveToXMLFile(xml, "soilData.fieldSentry")
  FieldSentry_API.reset()
  FieldSentry_API.loadFromXMLFile(xml, "soilData.fieldSentry")
  T.ok("manual flag restored", FieldSentry_API.isFieldManual(8) == true)
  T.ok("meadow flag restored alongside manual", FieldSentry_API.isFieldMeadow(8) == true)
end

-- ── meadow daily profile math ──────────────────────────────
do
  local sys = setmetatable({}, { __index = SoilFertilitySystem })
  local m = SoilConstants.MEADOW
  local limits = SoilConstants.NUTRIENT_LIMITS
  local field = {
    nitrogen = 20, phosphorus = 20, potassium = 20, organicMatter = 3.0, pH = 5.5,
    weedPressure = 30, pestPressure = 20, diseasePressure = 10,
  }
  sys:_applyMeadowProfile(field, 1.0, limits)
  T.near("meadow regrows N", field.nitrogen, 20 + m.REGROW_N)
  T.near("meadow regrows P", field.phosphorus, 20 + m.REGROW_P)
  T.near("meadow regrows K", field.potassium, 20 + m.REGROW_K)
  T.ok("meadow OM creeps upward", field.organicMatter > 3.0)
  T.ok("meadow pH drifts up toward neutral", field.pH > 5.5)
  T.near("meadow sheds weed pressure", field.weedPressure, 30 - m.PRESSURE_DECAY)
  T.near("meadow sheds pest pressure", field.pestPressure, 20 - m.PRESSURE_DECAY)
end

-- pressure never goes negative
do
  local sys = setmetatable({}, { __index = SoilFertilitySystem })
  local field = { nitrogen = 20, phosphorus = 20, potassium = 20, organicMatter = 3.0,
                  pH = 6.5, weedPressure = 0.5, pestPressure = 0, diseasePressure = 0 }
  sys:_applyMeadowProfile(field, 1.0, SoilConstants.NUTRIENT_LIMITS)
  T.ok("weed pressure clamps at 0", field.weedPressure == 0)
end

-- ── daily loop routes a meadow field to the grassland profile ──
do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldMeadow(7, true)
  local sys = setmetatable({
    fieldData = {},
    settings  = { enabled = true, nutrientCycles = true, compactionEnabled = false,
                  seasonalEffects = true, cropRotation = true,
                  weedPressure = false, pestPressure = false, diseasePressure = false },
    _dailyBatchDay = 100, _dailyBatchSeason = 2,  -- fall: the crop path would LOSE N here
  }, { __index = SoilFertilitySystem })
  local field = {
    nitrogen = 20, phosphorus = 20, potassium = 20, organicMatter = 3.0, pH = 5.5,
    weedPressure = 30, pestPressure = 0, diseasePressure = 0,
    lastHarvest = 100, nutrientBuffer = {},
  }
  sys.fieldData[7] = field
  sys:_processOneDailyField(7, field)
  -- Grassland profile regrows N; the normal fall path would have reduced it instead.
  T.ok("meadow field gains N via the grassland profile, not fall loss", field.nitrogen > 20)
  T.ok("meadow field sheds weed pressure on the daily pass", field.weedPressure < 30)
end
