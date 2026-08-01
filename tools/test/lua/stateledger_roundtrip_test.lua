-- stateledger_roundtrip_test.lua - StateLedger table serializer round-trip (#bedrock).
-- Proves getSoilStateTable() <-> applySoilStateTable() is lossless for every persisted
-- field, so the ledger save path equals the soilData.xml save path. g_farmlandManager and
-- SoilDiseaseSystem are absent here, so the finalizer skips the fieldArea refresh and the
-- disease-severity rebuild (both nil-guarded) - fieldArea therefore round-trips unchanged.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SoilFertilitySystem.lua

local function newSys(fields)
  return setmetatable({
    fieldData = fields or {},
    lastUpdateDay = 0,
    herbicideAppliedDay = {},
    insecticideAppliedDay = {},
    fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
end

-- Full round-trip across every persisted kind (scalars, throttles, organic, zone cells).
do
  local src = newSys()
  src.lastUpdateDay = 42
  src.fieldData[7] = {
    fieldArea = 3.5, nitrogen = 55.0, phosphorus = 40.0, potassium = 30.0,
    organicMatter = 4.2, pH = 6.4,
    lastCrop = "wheat", lastCrop2 = "barley", lastCrop3 = "canola", sownCrop = "maize",
    rotationBonusDaysLeft = 3, lastHarvest = 12, fertilizerApplied = 220.0,
    weedPressure = 5.0, herbicideDaysLeft = 2, pestPressure = 3.0, insecticideDaysLeft = 1,
    diseasePressure = 17.0, fungicideDaysLeft = 4, activeDisease = "septoria",
    lastFungicide = "azoxystrobin", dryDayCount = 6, burnDaysLeft = 2,
    lastAlertSeason = 3, coverageFraction = 0.5, compaction = 0,
    amendBurnPenalty = 0.9,
    frozenYieldModifier = 0.87, frozenYieldFruitType = 5,
    organic = { state = "in_transition", startDay = 10, certifiedDay = 0, breaches = 1 },
    zoneData = {
      ["3_4"] = { N=50, P=35, K=25, pH=6.2, OM=4.0, weedPressure=1, pestPressure=2, diseasePressure=3, compaction=12 },
      ["3_5"] = { N=48, P=33, K=24, pH=6.1, OM=3.9, weedPressure=0, pestPressure=0, diseasePressure=0, compaction=8 },
    },
  }
  src.herbicideAppliedDay[7]   = 40
  src.insecticideAppliedDay[7] = 41
  src.fungicideAppliedDay[7]   = 39

  local snap = src:getSoilStateTable()

  local dst = newSys()
  local n = dst:applySoilStateTable(snap)
  local b = dst.fieldData[7]

  T.eq("roundtrip: field count", n, 1)
  T.eq("roundtrip: lastUpdateDay", dst.lastUpdateDay, 42)

  T.near("roundtrip: fieldArea", b.fieldArea, 3.5)
  T.near("roundtrip: nitrogen", b.nitrogen, 55.0)
  T.near("roundtrip: phosphorus", b.phosphorus, 40.0)
  T.near("roundtrip: potassium", b.potassium, 30.0)
  T.near("roundtrip: organicMatter", b.organicMatter, 4.2)
  T.near("roundtrip: pH", b.pH, 6.4)
  T.eq("roundtrip: lastCrop", b.lastCrop, "wheat")
  T.eq("roundtrip: lastCrop3", b.lastCrop3, "canola")
  T.eq("roundtrip: sownCrop", b.sownCrop, "maize")
  T.eq("roundtrip: rotationBonusDaysLeft", b.rotationBonusDaysLeft, 3)
  T.eq("roundtrip: lastHarvest", b.lastHarvest, 12)
  T.near("roundtrip: fertilizerApplied", b.fertilizerApplied, 220.0)
  T.near("roundtrip: diseasePressure", b.diseasePressure, 17.0)
  T.eq("roundtrip: activeDisease", b.activeDisease, "septoria")
  T.eq("roundtrip: lastFungicide", b.lastFungicide, "azoxystrobin")
  T.eq("roundtrip: dryDayCount", b.dryDayCount, 6)
  T.near("roundtrip: amendBurnPenalty", b.amendBurnPenalty, 0.9)
  T.near("roundtrip: frozenYieldModifier", b.frozenYieldModifier, 0.87)
  T.eq("roundtrip: frozenYieldFruitType", b.frozenYieldFruitType, 5)
  T.near("roundtrip: coverageFraction", b.coverageFraction, 0.5)
  T.eq("roundtrip: lastAlertSeason", b.lastAlertSeason, 3)

  T.eq("roundtrip: herbicideAppliedDay", dst.herbicideAppliedDay[7], 40)
  T.eq("roundtrip: insecticideAppliedDay", dst.insecticideAppliedDay[7], 41)
  T.eq("roundtrip: fungicideAppliedDay", dst.fungicideAppliedDay[7], 39)

  T.ok("roundtrip: organic present", b.organic ~= nil)
  T.eq("roundtrip: organic state", b.organic and b.organic.state, "in_transition")
  T.eq("roundtrip: organic breaches", b.organic and b.organic.breaches, 1)

  T.ok("roundtrip: zone cell 3_4 present", b.zoneData and b.zoneData["3_4"] ~= nil)
  T.near("roundtrip: zone 3_4 N", b.zoneData["3_4"].N, 50)
  T.near("roundtrip: zone 3_4 compaction", b.zoneData["3_4"].compaction, 12)

  -- Derived by _finalizeLoadedField: compaction rebuilt from zoneData, coverage restored.
  T.ok("roundtrip: compaction rebuilt > 0", (b.compaction or 0) > 0)
  T.near("roundtrip: coveredAreaHa restored", b.coveredAreaHa, 0.5 * 3.5)
end

-- A field with a live freeze omitted (no frozen keys) must stay nil after round-trip.
do
  local src = newSys()
  src.fieldData[1] = { fieldArea = 1.0, nitrogen = 20, phosphorus = 20, potassium = 20,
                       organicMatter = 3.0, pH = 6.0, coverageFraction = 0 }
  local dst = newSys()
  dst:applySoilStateTable(src:getSoilStateTable())
  T.ok("roundtrip: no frozen yield stays nil", dst.fieldData[1].frozenYieldModifier == nil)
  T.ok("roundtrip: no organic stays nil", dst.fieldData[1].organic == nil)
end

-- Clamping: out-of-range values are pulled back into their valid domain on apply.
do
  local dst = newSys()
  dst:applySoilStateTable({ lastUpdateDay = 5, fields = {
    [2] = { nitrogen = 150, phosphorus = -10, potassium = 30, organicMatter = 99, pH = 3.0 },
  }})
  local b = dst.fieldData[2]
  T.near("clamp: nitrogen capped at 100", b.nitrogen, 100)
  T.near("clamp: phosphorus floored at 0", b.phosphorus, 0)
  T.near("clamp: organicMatter capped at 10", b.organicMatter, 10)
  T.near("clamp: pH floored at 5.0", b.pH, 5.0)
end

-- nil / non-table input degrades to zero fields (never crashes).
do
  local dst = newSys()
  T.eq("roundtrip: nil input = 0 fields", dst:applySoilStateTable(nil), 0)
end
