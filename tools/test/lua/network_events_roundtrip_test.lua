-- network_events_roundtrip_test.lua - writeStream <-> readStream round-trip for
-- every NetworkEvents.lua event class. This is the single-machine substitute for
-- the two-machine MP live test: it proves each event serializes and deserializes
-- losslessly and in lockstep, catching the #1 multiplayer bug class (stream desync:
-- write/read order mismatch, wrong width, field-count drift) without a second client.
--
-- How it works: _sfMockStream (prelude) is a typed FIFO. Each event's writeStream
-- fills it; a fresh instance's readStream drains it. A correct pair leaves the FIFO
-- exactly empty with zero type mismatches. run() is a no-op here (g_server/g_client
-- are nil in the prelude), so readStream's trailing self:run() does not interfere.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/maps/SoilValueMaps.lua, src/OrganicCertification.lua, src/ResistanceBands.lua, src/config/SettingsSchema.lua, src/network/NetworkEvents.lua

-- The receiver here is a pure client (g_server nil), so the connection it reads on is
-- its server connection, isServer = true (Client.lua:152): a server-to-client event's
-- readStream returns at once on any other connection (MAINTENANCE row 112).
local CONN = { getIsServer = function() return true end }

-- Serialize src, deserialize into a fresh instance of `class`, assert wire integrity,
-- and hand back the reconstructed instance for value-level assertions.
local function rt(name, src, class)
  local s = _sfMockStream()
  src:writeStream(s, CONN)
  local wrote = #s.q
  local dst = class.emptyNew()
  dst:readStream(s, CONN)
  T.eq(name .. ": no type mismatches", s.typeErrors, 0)
  T.eq(name .. ": no stream underflow", s.underflows, 0)
  -- Width and range, checked here because a counter nobody reads is instrumentation.
  -- These two were added to the mock in 2026-09-19; had they been added without
  -- extending this helper, every round trip below would have kept passing while
  -- ignoring them, which is exactly how the width claim went unchecked for so long.
  T.eq(name .. ": no UIntN width mismatches", s.widthErrors, 0)
  T.eq(name .. ": no value exceeds its declared width", s.rangeErrors, 0)
  T.eq(name .. ": stream fully drained", s.r, wrote + 1)
  return dst
end

-- A representative field with every synced attribute populated.
local function sampleField()
  return {
    fieldArea = 3.5, nitrogen = 55, phosphorus = 40, potassium = 30,
    organicMatter = 4.2, pH = 6.4,
    lastCrop = "wheat", lastCrop2 = "barley", lastCrop3 = "canola",
    rotationBonusDaysLeft = 3, lastHarvest = 12, fertilizerApplied = 220,
    weedPressure = 5, herbicideDaysLeft = 2, pestPressure = 3, insecticideDaysLeft = 1,
    diseasePressure = 17, fungicideDaysLeft = 4, dryDayCount = 6, burnDaysLeft = 2,
    coverageFraction = 0.5, compaction = 11,
    -- RSF-F905: the amendment burn rides every field delivery as a value + known pair,
    -- right after the field-level compaction.
    amendBurnPenalty = 0.42,
    nutrientBuffer = { [12] = 4.5, [3] = 1.25 },
    activeDisease = "septoria", diseaseDiscovered = true,
    -- CD-11: the durable scout bit is the band gate now (diseaseDiscovered alone no longer
    -- reveals), and it must ride every field delivery after the bands.
    fieldEverScouted = true,
    organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED, startDay = 100, certifiedDay = 220, breaches = 2 },
    -- CD-11: a saturated synthetic (10/10 -> FINISHED) and a natural at 70% of its own
    -- lower ceiling (3.5/5 -> SLIPPING). The natural is here on purpose: banded against
    -- the synthetic ceiling it would read WORKING and the wire bug would be invisible.
    resistance = { ["3"] = 10, ["M2"] = 3.5 },
  }
end

-- Shared field-value assertions for the three field-carrying events.
local function assertSampleField(name, b)
  T.ok(name .. ": field present", b ~= nil)
  if b == nil then return end
  T.near(name .. ": nitrogen", b.nitrogen, 55)
  T.near(name .. ": amendBurnPenalty (RSF-F905)", b.amendBurnPenalty, 0.42)
  T.eq(name .. ": amendBurnKnown arrives true from the owner (RSF-F905)", b.amendBurnKnown, true)
  T.near(name .. ": phosphorus", b.phosphorus, 40)
  T.near(name .. ": potassium", b.potassium, 30)
  T.near(name .. ": organicMatter", b.organicMatter, 4.2)
  T.near(name .. ": pH", b.pH, 6.4)
  T.eq(name .. ": lastCrop", b.lastCrop, "wheat")
  T.eq(name .. ": lastCrop2", b.lastCrop2, "barley")
  T.eq(name .. ": lastCrop3", b.lastCrop3, "canola")
  T.eq(name .. ": rotationBonusDaysLeft", b.rotationBonusDaysLeft, 3)
  T.eq(name .. ": lastHarvest", b.lastHarvest, 12)
  T.near(name .. ": fertilizerApplied", b.fertilizerApplied, 220)
  T.eq(name .. ": herbicideDaysLeft", b.herbicideDaysLeft, 2)
  -- CD-11: bands must survive every field-carrying event, and no raw score may cross.
  T.eq(name .. ": CD-11 saturated synthetic band survives",
       b.resistanceBands and b.resistanceBands["3"], SoilConstants.RESISTANCE.BANDS.FINISHED)
  T.eq(name .. ": CD-11 natural band survives on its OWN ceiling",
       b.resistanceBands and b.resistanceBands["M2"], SoilConstants.RESISTANCE.BANDS.SLIPPING)
  T.ok(name .. ": CD-11 no raw resistance score crossed the wire", b.resistance == nil)
  T.eq(name .. ": insecticideDaysLeft", b.insecticideDaysLeft, 1)
  T.eq(name .. ": fungicideDaysLeft", b.fungicideDaysLeft, 4)
  T.eq(name .. ": activeDisease", b.activeDisease, "septoria")
  T.ok(name .. ": diseaseDiscovered", b.diseaseDiscovered == true)
  T.ok(name .. ": CD-11 fieldEverScouted survives after the bands", b.fieldEverScouted == true)
  T.ok(name .. ": CD-11 receipt is stamped on the delivered table", b.resistanceBandsReceived == true)
  T.ok(name .. ": buffer present", b.nutrientBuffer ~= nil)
  T.near(name .. ": buffer[12]", b.nutrientBuffer[12], 4.5)
  T.near(name .. ": buffer[3]", b.nutrientBuffer[3], 1.25)
  T.ok(name .. ": organic present", b.organic ~= nil)
  if b.organic then
    T.eq(name .. ": organic state", b.organic.state, SoilConstants.ORGANIC.STATE_CERTIFIED)
    T.eq(name .. ": organic startDay", b.organic.startDay, 100)
    T.eq(name .. ": organic certifiedDay", b.organic.certifiedDay, 220)
    T.eq(name .. ": organic breaches", b.organic.breaches, 2)
  end
end

-- ── Harness self-checks: the FIFO must actually catch desync, or the whole suite
--    is theatre. Prove a wrong read order and a short read both trip a counter. ──
do
  local s = _sfMockStream()
  streamWriteInt32(s, 10)
  streamWriteString(s, "x")
  streamReadString(s)   -- expects str, next is i32
  streamReadInt32(s)    -- expects i32, next is str
  T.ok("harness: type-mismatch is detected", s.typeErrors > 0)
end
-- The two new detectors, proved the same way the older two are. A width guard that
-- cannot be shown to fire is worth nothing, and this mock spent its whole life
-- CLAIMING to catch "wrong width" in its own header comment while discarding the bit
-- count entirely.
do
  local s = _sfMockStream()
  streamWriteUIntN(s, 5, 3)
  streamReadUIntN(s, 4)   -- written as 3 bits, read as 4
  T.ok("harness: UIntN width mismatch is detected", s.widthErrors > 0)
  T.eq("harness: a width mismatch is not counted as a type mismatch", s.typeErrors, 0)
end
do
  local s = _sfMockStream()
  streamWriteUIntN(s, 5, 3)
  streamReadUIntN(s, 3)
  T.eq("harness: a matching width is clean", s.widthErrors, 0)
end
do
  -- 8 does not fit in 3 bits (max 7). The engine truncates silently, so the value
  -- that arrives is not the value that was sent and nothing reports it.
  local s = _sfMockStream()
  streamWriteUIntN(s, 8, 3)
  T.ok("harness: a value too wide for its width is detected", s.rangeErrors > 0)
  local ok = _sfMockStream()
  streamWriteUIntN(ok, 7, 3)
  T.eq("harness: the largest value that fits is clean", ok.rangeErrors, 0)
end
do
  local s = _sfMockStream()
  streamWriteInt32(s, 1)
  streamReadInt32(s)
  streamReadInt32(s)    -- nothing left
  T.ok("harness: underflow is detected", s.underflows > 0)
end
do
  local s = _sfMockStream()
  streamWriteInt32(s, 1)
  streamWriteInt32(s, 2)
  streamReadInt32(s)    -- leftover unread -> r != #q+1
  T.eq("harness: leftover leaves stream not drained", s.r, 2)
end

-- ── SoilSettingChangeEvent (client -> server): name + tagged value ──
do
  local d = rt("settingChange/bool", SoilSettingChangeEvent.new("enabled", true), SoilSettingChangeEvent)
  T.eq("settingChange/bool: name", d.settingName, "enabled")
  T.ok("settingChange/bool: value", d.settingValue == true)

  d = rt("settingChange/num", SoilSettingChangeEvent.new("difficulty", 2), SoilSettingChangeEvent)
  T.eq("settingChange/num: name", d.settingName, "difficulty")
  T.eq("settingChange/num: value", d.settingValue, 2)

  d = rt("settingChange/str", SoilSettingChangeEvent.new("someString", "hello"), SoilSettingChangeEvent)
  T.eq("settingChange/str: value", d.settingValue, "hello")
end

-- ── SoilSettingSyncEvent (server -> clients): same wire shape ──
do
  local d = rt("settingSync/bool", SoilSettingSyncEvent.new("enabled", false), SoilSettingSyncEvent)
  T.eq("settingSync/bool: name", d.settingName, "enabled")
  T.ok("settingSync/bool: value", d.settingValue == false)

  d = rt("settingSync/num", SoilSettingSyncEvent.new("difficulty", 3), SoilSettingSyncEvent)
  T.eq("settingSync/num: value", d.settingValue, 3)
end

-- ── SoilRequestFullSyncEvent: zero-payload handshake ──
do
  local d = rt("requestFullSync", SoilRequestFullSyncEvent.new(), SoilRequestFullSyncEvent)
  T.ok("requestFullSync: reconstructs", d ~= nil)
end

-- ── SoilFullSyncEvent: all non-local settings (schema order) + fields ──
do
  local settings = {}
  for _, def in ipairs(SettingsSchema.definitions) do
    if def.type == "boolean" then settings[def.id] = true
    elseif def.type == "number" then settings[def.id] = def.default or 1 end
  end
  local fieldData = { [7] = sampleField() }
  local d = rt("fullSync", SoilFullSyncEvent.new(settings, fieldData), SoilFullSyncEvent)

  -- Every synced setting must survive in the exact schema order (any drift here is
  -- precisely the desync class this harness exists to catch).
  local checked = 0
  for _, def in ipairs(SettingsSchema.definitions) do
    if not def.localOnly then
      if def.type == "boolean" then
        T.ok("fullSync setting " .. def.id, d.settings[def.id] == true); checked = checked + 1
      elseif def.type == "number" then
        T.eq("fullSync setting " .. def.id, d.settings[def.id], settings[def.id]); checked = checked + 1
      end
    end
  end
  T.ok("fullSync: at least one setting on the wire", checked > 0)
  assertSampleField("fullSync", d.fieldData[7])
end

-- ── SoilFieldBatchSyncEvent: count + isLast + fields (with zone cells) ──
do
  local f = sampleField()
  f.zoneData = { ["37"] = {
    N = 50, P = 40, K = 30, pH = 6.5, OM = 4,
    weedPressure = 1, pestPressure = 2, diseasePressure = 3, compaction = 5,
  } }
  local d = rt("batchSync", SoilFieldBatchSyncEvent.new({ [7] = f }, true), SoilFieldBatchSyncEvent)
  T.ok("batchSync: isLast", d.isLast == true)
  assertSampleField("batchSync", d.batchFields[7])
  local zd = d.batchFields[7] and d.batchFields[7].zoneData
  T.ok("batchSync: zone cell present", zd ~= nil and zd["37"] ~= nil)
  if zd and zd["37"] then
    T.near("batchSync: zone N", zd["37"].N, 50)
    T.near("batchSync: zone compaction", zd["37"].compaction, 5)
  end
end

-- ── SoilFieldUpdateEvent: single field; zone cells intentionally 0 on the wire ──
do
  local d = rt("fieldUpdate", SoilFieldUpdateEvent.new(7, sampleField()), SoilFieldUpdateEvent)
  T.eq("fieldUpdate: fieldId", d.fieldId, 7)
  assertSampleField("fieldUpdate", d.field)
  T.ok("fieldUpdate: zoneData empty (0 cells on wire)",
    d.field.zoneData ~= nil and next(d.field.zoneData) == nil)
end

-- ── SoilTreatFieldEvent (client -> server): fieldId + chemId ──
do
  local d = rt("treat", SoilTreatFieldEvent.new(7, "AZOXYSTROBIN"), SoilTreatFieldEvent)
  T.eq("treat: fieldId", d.fieldId, 7)
  T.eq("treat: chemId", d.chemId, "AZOXYSTROBIN")
end

-- ── SoilScoutFieldEvent (client -> server): fieldId ──
do
  local d = rt("scout", SoilScoutFieldEvent.new(9), SoilScoutFieldEvent)
  T.eq("scout: fieldId", d.fieldId, 9)
end

-- ── SoilOrganicOptEvent (client -> server): fieldId + doOptIn bool ──
do
  local d = rt("organicOpt/in", SoilOrganicOptEvent.new(7, true), SoilOrganicOptEvent)
  T.eq("organicOpt/in: fieldId", d.fieldId, 7)
  T.ok("organicOpt/in: doOptIn true", d.doOptIn == true)

  d = rt("organicOpt/out", SoilOrganicOptEvent.new(4, false), SoilOrganicOptEvent)
  T.eq("organicOpt/out: fieldId", d.fieldId, 4)
  T.ok("organicOpt/out: doOptIn false", d.doOptIn == false)
end

-- ── SoilSprayerRateEvent: netId (int32) + rateIndex (uint8) ──
do
  local d = rt("sprayerRate", SoilSprayerRateEvent.new(123456, 3), SoilSprayerRateEvent)
  T.eq("sprayerRate: vehicleNetId", d.vehicleNetId, 123456)
  T.eq("sprayerRate: rateIndex", d.rateIndex, 3)
end

-- ── SoilSprayerAutoModeEvent: netId + bool ──
do
  local d = rt("sprayerAuto", SoilSprayerAutoModeEvent.new(123456, true), SoilSprayerAutoModeEvent)
  T.eq("sprayerAuto: vehicleNetId", d.vehicleNetId, 123456)
  T.ok("sprayerAuto: enabled", d.enabled == true)
end

-- ── SoilFieldSentryEvent (#651): fieldId + manual bool ──
do
  local d = rt("sentry", SoilFieldSentryEvent.new(7, true), SoilFieldSentryEvent)
  T.eq("sentry: fieldId", d.fieldId, 7)
  T.ok("sentry: manual", d.manual == true)
end

-- ── SoilFieldMeadowEvent (#651 P3): fieldId + meadow bool ──
do
  local d = rt("meadow", SoilFieldMeadowEvent.new(7, true), SoilFieldMeadowEvent)
  T.eq("meadow: fieldId", d.fieldId, 7)
  T.ok("meadow: meadow", d.meadow == true)
end

-- ── SoilFieldSentryStatusEvent (#654): fieldId + reason (uintN 3 bits) + seq ──
do
  local d = rt("sentryStatus", SoilFieldSentryStatusEvent.new(7, 5, 42), SoilFieldSentryStatusEvent)
  T.eq("sentryStatus: fieldId", d.fieldId, 7)
  T.eq("sentryStatus: reason", d.reason, 5)
  T.eq("sentryStatus: seq", d.seq, 42)
end

-- ── SoilValueMapChecksumEvent (SF-43 ask 4): each entry CARRIES its layerIdx ──
-- This was a positional array whose POSITION was read back as the LAYER_DEFS index.
-- Skipping any layer (the serverOnly opt-out does exactly that) would then shift
-- every later checksum onto the wrong layer, so a client would "detect drift" on a
-- healthy layer and resync it forever. The gap below is the whole point: indices 3
-- and 5 are sent with 4 missing, exactly as a skipped serverOnly layer produces.
do
  local sent = {
    { layerIdx = 3, sum = 1200, nonZero = 340 },
    { layerIdx = 5, sum = 77,   nonZero = 9   },
  }
  local d = rt("vmChecksum", SoilValueMapChecksumEvent.new(sent), SoilValueMapChecksumEvent)
  T.eq("vmChecksum: entry count survives", #d.checksums, 2)
  T.eq("vmChecksum: first layerIdx survives the gap", d.checksums[1].layerIdx, 3)
  T.eq("vmChecksum: first sum",     d.checksums[1].sum,     1200)
  T.eq("vmChecksum: first nonZero", d.checksums[1].nonZero, 340)
  -- The assertion that matters: position 2 still says layer 5, not layer 4.
  T.eq("vmChecksum: a skipped layer does not shift the next one", d.checksums[2].layerIdx, 5)
  T.eq("vmChecksum: second sum",     d.checksums[2].sum,     77)
  T.eq("vmChecksum: second nonZero", d.checksums[2].nonZero, 9)
end

-- ══════════════════════════════════════════════════════════
-- The two events that carry UIntN and had NO wire round trip
-- ══════════════════════════════════════════════════════════
-- Found by mutation: a width drift in either of these SURVIVED the whole suite,
-- because the width guard cannot guard a path no test walks. SoilValueMapChunkEvent
-- run-length-encodes 4-bit cell states; SoilScoutingMaskSyncEvent writes the farm id
-- at FarmManager.FARM_ID_SEND_NUM_BITS on both sides, and the harness had no
-- FarmManager at all, so the event could not be exercised even in principle.

do
  -- Rows are run-length encoded as 4-bit states, so the fixture deliberately mixes
  -- runs and singletons and includes 15, the largest value 4 bits can carry.
  local rows = { { 0, 0, 0, 5, 5, 15 }, { 1, 2, 3, 3, 3, 3 } }
  local src = SoilValueMapChunkEvent.new(2, 7, rows, true,
    { mode = "PATCH", revision = 9, baseRevision = 8, transferId = 4,
      partIndex = 1, partCount = 3, sourceResolution = 256, transportStride = 2 })
  local d = rt("vmChunk", src, SoilValueMapChunkEvent)
  T.eq("vmChunk: layerIdx", d.layerIdx, 2)
  T.eq("vmChunk: gyStart", d.gyStart, 7)
  T.eq("vmChunk: isLast", d.isLast, true)
  T.eq("vmChunk: mode", d.mode, "PATCH")
  T.eq("vmChunk: revision", d.revision, 9)
  T.eq("vmChunk: partCount", d.partCount, 3)
  T.eq("vmChunk: row count", #d.rows, 2)
  T.eq("vmChunk: first row survives the run-length round trip",
    table.concat(d.rows[1], ","), "0,0,0,5,5,15")
  T.eq("vmChunk: second row survives too",
    table.concat(d.rows[2], ","), "1,2,3,3,3,3")
end

do
  local entries = {
    { fieldId = 3, cellKey = "a:1", day = 12, truth = 0.5, x = 1.5, z = -2.5, gen = 7 },
    { fieldId = 9, cellKey = "b:2", day = 13, truth = 0.25, x = 0,   z = 4.5,  gen = 8 },
  }
  -- 15 is the largest farm id 4 bits can carry, so it pins the boundary rather than
  -- a comfortable middle value.
  local src = SoilScoutingMaskSyncEvent.newFull(15, 2, 5, entries)
  local d = rt("maskSync", src, SoilScoutingMaskSyncEvent)
  T.eq("maskSync: schema", d.schema, SoilScoutingMaskSyncEvent.SCHEMA)
  T.eq("maskSync: mode is FULL", d.mode, SoilScoutingMaskSyncEvent.MODE_FULL)
  T.eq("maskSync: farmId at the 4-bit ceiling", d.farmId, 15)
  T.eq("maskSync: chunkIndex", d.chunkIndex, 2)
  T.eq("maskSync: chunkCount", d.chunkCount, 5)
  T.eq("maskSync: entry count", #d.entries, 2)
  T.eq("maskSync: first fieldId", d.entries[1].fieldId, 3)
  T.eq("maskSync: first cellKey", d.entries[1].cellKey, "a:1")
  T.near("maskSync: first truth", d.entries[1].truth, 0.5, 1e-9)
  T.eq("maskSync: second gen", d.entries[2].gen, 8)
end
