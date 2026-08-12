-- networksync_roundtrip_test.lua - NetworkSync whole-field-map serializer round-trip.
-- Proves serializeFields() <-> deserializeFields() is lossless for the per-field
-- payload SF syncs over NetworkSync, so a client rebuilds exactly what the server
-- flattened. SoilDiseaseSystem is absent here, so disease severity defaults to 1.0
-- (nil-guarded). Zone cells are intentionally NOT on the wire (overflow safety) and
-- are reconstructed from the aggregate at apply time, so they are not asserted here.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, src/ResistanceBands.lua, src/integrations/SoilNetworkSyncBridge.lua

local B = SoilNetworkSyncBridge

-- Full round-trip across every synced field (scalars, throttles, buffer, strings).
do
  local src = {
    [7] = {
      fieldArea = 3.5, nitrogen = 55.0, phosphorus = 40.0, potassium = 30.0,
      organicMatter = 4.2, pH = 6.4,
      lastCrop = "wheat", lastCrop2 = "barley", lastCrop3 = "canola",
      rotationBonusDaysLeft = 3, lastHarvest = 12, fertilizerApplied = 220.0,
      weedPressure = 5.0, herbicideDaysLeft = 2, pestPressure = 3.0, insecticideDaysLeft = 1,
      diseasePressure = 17.0, fungicideDaysLeft = 4, activeDisease = "septoria",
      dryDayCount = 6, burnDaysLeft = 2, coverageFraction = 0.5, compaction = 11.0,
      nutrientBuffer = { [12] = 4.5, [3] = 1.25 },
      organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED, startDay = 100, certifiedDay = 220, breaches = 2 },
      -- CD-11: the discovery flag (previously dropped by this bridge) and the bands whose
      -- gate reads it. M2 is natural, so 3.5 of ITS ceiling (5) is SLIPPING, not WORKING.
      diseaseDiscovered = true,
      resistance = { ["3"] = 10, ["M2"] = 3.5 },
      -- zoneData present on the server but deliberately not serialized:
      zoneData = { ["3_4"] = { N = 50 } },
    },
  }

  local arr = B.serializeFields(src)
  T.eq("wire: array starts with field count", arr[1], 1)

  local dst = B.deserializeFields(arr)
  local b = dst[7]
  T.ok("roundtrip: field 7 present", b ~= nil)

  T.near("roundtrip: fieldArea", b.fieldArea, 3.5)
  T.near("roundtrip: nitrogen", b.nitrogen, 55.0)
  T.near("roundtrip: phosphorus", b.phosphorus, 40.0)
  T.near("roundtrip: potassium", b.potassium, 30.0)
  T.near("roundtrip: organicMatter", b.organicMatter, 4.2)
  T.near("roundtrip: pH", b.pH, 6.4)
  T.eq("roundtrip: lastCrop", b.lastCrop, "wheat")
  T.eq("roundtrip: lastCrop2", b.lastCrop2, "barley")
  T.eq("roundtrip: lastCrop3", b.lastCrop3, "canola")
  T.eq("roundtrip: rotationBonusDaysLeft", b.rotationBonusDaysLeft, 3)
  T.eq("roundtrip: lastHarvest", b.lastHarvest, 12)
  T.near("roundtrip: fertilizerApplied", b.fertilizerApplied, 220.0)
  T.near("roundtrip: weedPressure", b.weedPressure, 5.0)
  T.eq("roundtrip: herbicideDaysLeft", b.herbicideDaysLeft, 2)
  T.near("roundtrip: pestPressure", b.pestPressure, 3.0)
  T.eq("roundtrip: insecticideDaysLeft", b.insecticideDaysLeft, 1)
  T.near("roundtrip: diseasePressure", b.diseasePressure, 17.0)
  T.eq("roundtrip: fungicideDaysLeft", b.fungicideDaysLeft, 4)
  -- CD-11: the discovery flag must survive this bridge's wholesale replace, or a scouted
  -- field reverts to unscouted on the client and every band below reads UNKNOWN.
  T.eq("roundtrip: diseaseDiscovered survives the bridge", b.diseaseDiscovered, true)
  T.eq("roundtrip: CD-11 saturated synthetic band survives the bridge",
       b.resistanceBands and b.resistanceBands["3"], SoilConstants.RESISTANCE.BANDS.FINISHED)
  T.eq("roundtrip: CD-11 natural band survives on its OWN ceiling",
       b.resistanceBands and b.resistanceBands["M2"], SoilConstants.RESISTANCE.BANDS.SLIPPING)
  T.ok("roundtrip: no raw resistance score crossed the bridge", b.resistance == nil)
  T.eq("roundtrip: dryDayCount", b.dryDayCount, 6)
  T.eq("roundtrip: burnDaysLeft", b.burnDaysLeft, 2)
  T.near("roundtrip: coverageFraction", b.coverageFraction, 0.5)
  T.near("roundtrip: compaction", b.compaction, 11.0)

  T.eq("roundtrip: activeDisease", b.activeDisease, "septoria")
  T.near("roundtrip: activeDiseaseSeverity default", b.activeDiseaseSeverity, 1.0)

  T.ok("roundtrip: buffer present", b.nutrientBuffer ~= nil)
  T.near("roundtrip: buffer[12]", b.nutrientBuffer[12], 4.5)
  T.near("roundtrip: buffer[3]", b.nutrientBuffer[3], 1.25)

  T.ok("roundtrip: organic present", b.organic ~= nil)
  T.eq("roundtrip: organic state", b.organic.state, SoilConstants.ORGANIC.STATE_CERTIFIED)
  T.eq("roundtrip: organic startDay", b.organic.startDay, 100)
  T.eq("roundtrip: organic certifiedDay", b.organic.certifiedDay, 220)
  T.eq("roundtrip: organic breaches", b.organic.breaches, 2)

  -- Client-side scaffolding the rebuild always sets.
  T.ok("roundtrip: initialized", b.initialized == true)
  T.eq("roundtrip: coveredCellCount reset", b.coveredCellCount, 0)

  -- Zone cells are not on the wire: the rebuilt field starts with an empty map,
  -- the client re-derives cells from the aggregate at apply time.
  T.ok("roundtrip: zoneData empty (not synced)", b.zoneData ~= nil and next(b.zoneData) == nil)
end

-- Multiple fields survive the flatten in one array.
do
  local src = {
    [1] = { fieldArea = 1.0, nitrogen = 20, phosphorus = 20, potassium = 20, organicMatter = 3.0, pH = 6.0 },
    [2] = { fieldArea = 2.0, nitrogen = 60, phosphorus = 45, potassium = 50, organicMatter = 5.0, pH = 6.8 },
  }
  local dst = B.deserializeFields(B.serializeFields(src))
  T.ok("multi: field 1 present", dst[1] ~= nil)
  T.ok("multi: field 2 present", dst[2] ~= nil)
  T.near("multi: field 2 nitrogen", dst[2].nitrogen, 60)
  T.near("multi: field 1 pH", dst[1].pH, 6.0)
end

-- Organic certification: the enum survives, a plain conventional field never
-- resurrects an organic sub-table (mirrors loadFieldState), and a breach-scarred
-- conventional field keeps its lifetime breach count.
do
  local O = SoilConstants.ORGANIC
  local src = {
    [1] = { fieldArea = 1, nitrogen = 30, phosphorus = 30, potassium = 30, organicMatter = 3, pH = 6.2 },
    [2] = { fieldArea = 1, nitrogen = 30, phosphorus = 30, potassium = 30, organicMatter = 3, pH = 6.2,
            organic = { state = O.STATE_TRANSITION, startDay = 50, certifiedDay = 0, breaches = 0 } },
    [3] = { fieldArea = 1, nitrogen = 30, phosphorus = 30, potassium = 30, organicMatter = 3, pH = 6.2,
            organic = { state = O.STATE_CONVENTIONAL, startDay = 0, certifiedDay = 0, breaches = 3 } },
  }
  local dst = B.deserializeFields(B.serializeFields(src))
  T.ok("organic: conventional field keeps no sub-table", dst[1].organic == nil)
  T.ok("organic: transition field present", dst[2].organic ~= nil)
  T.eq("organic: transition state", dst[2].organic.state, O.STATE_TRANSITION)
  T.eq("organic: transition startDay", dst[2].organic.startDay, 50)
  T.ok("organic: breached-conventional keeps sub-table (breaches>0)", dst[3].organic ~= nil)
  T.eq("organic: breach count preserved", dst[3].organic.breaches, 3)
  T.eq("organic: breached field stays conventional", dst[3].organic.state, O.STATE_CONVENTIONAL)
end

-- Empty strings deserialize back to nil (no phantom crop / disease).
do
  local src = { [5] = { fieldArea = 1.0, nitrogen = 30, phosphorus = 30, potassium = 30, organicMatter = 3.0, pH = 6.2 } }
  local b = B.deserializeFields(B.serializeFields(src))[5]
  T.ok("empty: lastCrop stays nil", b.lastCrop == nil)
  T.ok("empty: activeDisease stays nil", b.activeDisease == nil)
end

-- Clamping: out-of-range aggregate values are pulled back into their domain on read.
do
  local src = { [2] = { fieldArea = 1.0, nitrogen = 150, phosphorus = -10, potassium = 30,
                        organicMatter = 99, pH = 3.0, weedPressure = 250, coverageFraction = 2.0 } }
  local b = B.deserializeFields(B.serializeFields(src))[2]
  T.near("clamp: nitrogen capped at 100", b.nitrogen, 100)
  T.near("clamp: phosphorus floored at 0", b.phosphorus, 0)
  T.near("clamp: organicMatter capped at 10", b.organicMatter, 10)
  T.near("clamp: pH floored at 5.0", b.pH, 5.0)
  T.near("clamp: weedPressure capped at 100", b.weedPressure, 100)
  T.near("clamp: coverageFraction capped at 1", b.coverageFraction, 1)
end

-- Defensive: non-table / nil input degrades to zero fields, never crashes.
do
  T.eq("guard: nil input = 0 fields", next(B.deserializeFields(nil)) == nil and 0 or 1, 0)
  T.eq("guard: empty array = 0 fields", next(B.deserializeFields({ 0 })) == nil and 0 or 1, 0)
end
