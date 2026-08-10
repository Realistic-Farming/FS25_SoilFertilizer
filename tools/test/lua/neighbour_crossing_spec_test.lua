-- neighbour_crossing_spec_test.lua - NEIGHBOUR CROSSING (SF-21)
--
-- What arrives at a field's edge depends on what is across it. Pins the brief's
-- spec bar: the composition/degrade bar (a zero-pressure district reproduces
-- today's behaviour EXACTLY), the snapshot order-blindness (the completion gate),
-- the protection fence (a protected field seeds nothing), the wilderness form
-- (nothing resolved = no modifier, no crossing), and the ceiling.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SpatialPressures.lua, src/NeighbourCrossing.lua

local NC = NeighbourCrossing

-- ── 1. B2: a zero/empty neighbour reproduces today's modifier (1.0) ──────────
do
  T.eq("wilderness (nil) -> modifier 1.0", NC:neighbourPestModifier(nil), 1.0)
  T.eq("zero-pressure arc -> modifier 1.0", NC:neighbourPestModifier({ pest = 0 }), 1.0)
  local m100 = NC:neighbourPestModifier({ pest = 100 })
  T.ok("pressure 100 -> modifier bounded at MODIFIER_MAX", m100 >= 1.0 and m100 <= NC.MODIFIER_MAX)
  T.ok("modifier is monotonic in pressure", m100 > NC:neighbourPestModifier({ pest = 50 }))
end

-- ── 2. The completion gate: snapshotReady is false before, true after ────────
do
  T.ok("no snapshot -> not ready", not NC:snapshotReady(nil, 1))
  T.ok("field absent from snapshot -> not ready", not NC:snapshotReady({}, 1))
  T.ok("field present -> ready", NC:snapshotReady({ [1] = {} }, 1))
end

-- ── 3. B3: the protection fence is LAW ───────────────────────────────────────
do
  -- A protected field (fungicideDaysLeft > 0) seeds nothing even with a
  -- conductive, infected neighbour.
  local seeded = 0
  local arcs = { { pest = 90, disease = 90 } }
  g_currentMission = { cropStressManager = { getMoisture = function() return 0.9 end } }
  local field = { fungicideDaysLeft = 5, diseasePressure = 40, _snCenter = { x = 0, z = 0 } }
  -- Force the conducive roll to always succeed by stubbing the hash.
  local savedHash = SpatialPressures.hash
  SpatialPressures.hash = function() return 0.01 end
  seeded = NC:rollDiseaseCrossing({}, 1, field, arcs, 10)
  SpatialPressures.hash = savedHash
  T.eq("protected field seeds nothing", seeded, 0)

  -- An unprotected field with a conducive infected neighbour seeds.
  field.fungicideDaysLeft = 0
  -- Stub seedBoundaryOrigin so the test does not need real zoneData.
  local savedSeed = SpatialPressures.seedBoundaryOrigin
  SpatialPressures.seedBoundaryOrigin = function() return true end
  SpatialPressures.hash = function() return 0.01 end
  seeded = NC:rollDiseaseCrossing({}, 1, field, arcs, 10)
  SpatialPressures.hash = savedHash
  SpatialPressures.seedBoundaryOrigin = savedSeed
  T.ok("unprotected conducive field seeds a boundary origin", seeded >= 1)
end

-- ── 4. B3: absent SCS = no disease crossing ──────────────────────────────────
do
  g_currentMission = nil
  local field = { fungicideDaysLeft = 0, diseasePressure = 40 }
  local arcs = { { pest = 90, disease = 90 } }
  local seeded = NC:rollDiseaseCrossing({}, 1, field, arcs, 10)
  T.eq("absent SCS -> no disease crossing", seeded, 0)
end

-- ── 5. The wilderness form: no neighbour = no arcs = nothing to seed ─────────
do
  local field = { fungicideDaysLeft = 0, diseasePressure = 40 }
  local seeded = NC:rollDiseaseCrossing({}, 1, field, {}, 10)
  T.eq("empty snapshot -> nothing seeded", seeded, 0)
end

-- ── 6. Conducive gate: dry boundary blocks crossing ──────────────────────────
do
  g_currentMission = { cropStressManager = { getMoisture = function() return 0.2 end } }
  local field = { fungicideDaysLeft = 0, diseasePressure = 40, _snCenter = { x = 0, z = 0 } }
  local arcs = { { pest = 90, disease = 90 } }
  local savedSeed = SpatialPressures.seedBoundaryOrigin
  SpatialPressures.seedBoundaryOrigin = function() return true end
  SpatialPressures.hash = function() return 0.01 end
  local seeded = NC:rollDiseaseCrossing({}, 1, field, arcs, 10)
  SpatialPressures.hash = nil
  SpatialPressures.seedBoundaryOrigin = savedSeed
  T.eq("dry boundary -> no disease crossing", seeded, 0)
end
