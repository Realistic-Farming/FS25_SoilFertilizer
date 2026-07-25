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
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/network/NetworkEvents.lua

local CONN = { getIsServer = function() return false end }

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
    nutrientBuffer = { [12] = 4.5, [3] = 1.25 },
    activeDisease = "septoria", diseaseDiscovered = true,
    organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED, startDay = 100, certifiedDay = 220, breaches = 2 },
  }
end

-- Shared field-value assertions for the three field-carrying events.
local function assertSampleField(name, b)
  T.ok(name .. ": field present", b ~= nil)
  if b == nil then return end
  T.near(name .. ": nitrogen", b.nitrogen, 55)
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
  T.eq(name .. ": insecticideDaysLeft", b.insecticideDaysLeft, 1)
  T.eq(name .. ": fungicideDaysLeft", b.fungicideDaysLeft, 4)
  T.eq(name .. ": activeDisease", b.activeDisease, "septoria")
  T.ok(name .. ": diseaseDiscovered", b.diseaseDiscovered == true)
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
