-- MAINT-112-readstream_bounds_spec_test.lua
--
-- MAINTENANCE row 112: a forged stream cannot make a readStream loop for long, on any
-- host. Two rules. The eight server-to-client events read NOTHING on the wrong side
-- (a server, or a connection that is not this client's server connection). Every
-- count a reader loops on is held to what its writer could have written; a count
-- above that, or a short stream, refuses the event: it reads no further, marks itself
-- (refused) and never runs.
--
-- Every stream here is produced by the REAL writeStream, and delivered as the engine
-- delivers it, into readStream (Server.lua:436, Client.lua:418). A forged count is
-- the attacker's one edit on that real stream: one entry of the typed mock queue set
-- to the forged value, the way a modified client would patch its own packet. No row
-- calls run, and nothing a row asserts on is hand-populated.
--
--!env: modenv
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/maps/SoilValueMaps.lua, src/OrganicCertification.lua, src/ResistanceBands.lua, src/config/SettingsSchema.lua, src/network/NetworkEvents.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── connections (Connection.lua:24-27, :146-151) ────────────────────────────
local function conn(isServer, streamId)
    return { isServer = isServer, streamId = streamId,
        getIsServer = function(self) return self.isServer end,
        getIsLocal = function(self) return self.streamId == 0 end }
end
local AT_HOST_FROM_CLIENT = conn(false, 7)   -- the host's connection to a client (Server.lua:454)
local AT_CLIENT_FROM_SERVER = conn(true, 1)  -- a pure client's server connection (Client.lua:152)

--- Write with the real writer; hand back the stream for the attacker's one edit.
local function written(event)
    local s = _sfMockStream()
    event:writeStream(s, AT_CLIENT_FROM_SERVER)
    return s
end
--- Deliver a stream into a fresh instance's readStream, as the engine does.
local function read(s, class, connection)
    local dst = class.emptyNew()
    local ok, err = pcall(dst.readStream, dst, s, connection)
    return dst, ok, err
end
--- One row for a refusal: the reason, that nothing was read past the count (the
--- cursor), no Lua error, and no underflow.
local function refusal(dst, ok, s, cursorAt)
    return tostring(dst.refused) .. "/" .. tostring(ok) .. "/" .. tostring(s.r == cursorAt) .. "/" .. s.underflows
end

-- ── the world ───────────────────────────────────────────────────────────────
local W = {}
local function field(opts)
    opts = opts or {}
    local f = {
        fieldArea = 3.5, nitrogen = 55, phosphorus = 40, potassium = 30, organicMatter = 4.2, pH = 6.4,
        lastCrop = "wheat", lastCrop2 = "", lastCrop3 = "", rotationBonusDaysLeft = 3, lastHarvest = 12,
        fertilizerApplied = 220, weedPressure = 5, herbicideDaysLeft = 2, pestPressure = 3, insecticideDaysLeft = 1,
        diseasePressure = 17, fungicideDaysLeft = 4, dryDayCount = 6, burnDaysLeft = 2, coverageFraction = 0.5,
        compaction = 11, amendBurnPenalty = 0.42, nutrientBuffer = opts.buffer or {}, zoneData = opts.zones or {},
        activeDisease = "septoria", diseaseDiscovered = true, fieldEverScouted = true,
        organic = { state = SoilConstants.ORGANIC.STATE_CONVENTIONAL, startDay = 0, certifiedDay = 0, breaches = 0 },
        resistance = { ["3"] = 10 },
    }
    return f
end
local function buffer(n)
    local b = {}
    for i = 1, n do b[i] = i * 0.5 end
    return b
end
local function zones(n)
    local z = {}
    for i = 1, n do z[tostring(i)] = { N = 50, P = 40, K = 30, pH = 6.5, OM = 4, weedPressure = 1, pestPressure = 2, diseasePressure = 3, compaction = 5 } end
    return z
end
local function fields(n, opts)
    local t = {}
    for i = 1, n do t[i] = field(opts) end
    return t
end
local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
local function side(kind)
    if kind == "host" then g_server, g_client = { broadcastEvent = function() end }, {}
    else g_server, g_client = nil, {} end
    g_localPlayer = { farmId = 1 }
    g_currentMission = { environment = { currentDay = 12, daysPerPeriod = 1 }, missionDynamicInfo = { isMultiplayer = true },
        hud = { showBlinkingWarning = function() end } }
    g_farmlandManager = { getFarmlandOwner = function() return 1 end }
    local settings = { enabled = true, difficulty = 2 }
    for _, def in ipairs(SettingsSchema.definitions) do if settings[def.id] == nil then settings[def.id] = def.default end end
    W.soilSystem = { fieldData = { [7] = field() }, activeFieldIds = {}, _addToActiveSet = function(self, id) self.activeFieldIds[id] = true end }
    W.settings = settings
    g_SoilFertilityManager = { settings = settings, soilSystem = W.soilSystem,
        settingsUI = { refreshUI = function() end }, soilMapOverlay = { requestRefresh = function() end } }
    SoilNetworkEvents_OnFullSyncReceived = function() end
end
local function settingsTable()
    local s = {}
    for _, def in ipairs(SettingsSchema.definitions) do
        if def.type == "boolean" then s[def.id] = true elseif def.type == "number" then s[def.id] = def.default or 1 end
    end
    return s
end
--- The index of the first queue entry matching pred (type and value).
local function indexOf(s, pred, from)
    for i = from or 1, #s.q do if pred(s.q[i], i) then return i end end
    return nil
end
-- The eight server-to-client events, each with a real stream.
local function eightEvents()
    return {
        { "SettingSync", SoilSettingSyncEvent.new("difficulty", 3), SoilSettingSyncEvent },
        { "FullSync", SoilFullSyncEvent.new(settingsTable(), { [7] = field() }), SoilFullSyncEvent },
        { "FieldBatchSync", SoilFieldBatchSyncEvent.new({ [7] = field() }, true), SoilFieldBatchSyncEvent },
        { "FieldUpdate", SoilFieldUpdateEvent.new(7, field()), SoilFieldUpdateEvent },
        { "FieldSentryStatus", SoilFieldSentryStatusEvent.new(7, 5, 42), SoilFieldSentryStatusEvent },
        { "ValueMapChunk", SoilValueMapChunkEvent.new(2, 7, { { 0, 0, 5, 5 } }, true, { mode = "FULL", revision = 1, baseRevision = 0, transferId = 1, partIndex = 0, partCount = 1, sourceResolution = 256, transportStride = 1 }), SoilValueMapChunkEvent },
        { "ValueMapChecksum", SoilValueMapChecksumEvent.new({ { layerIdx = 1, sum = 10, nonZero = 3 } }), SoilValueMapChecksumEvent },
        { "ScoutingMaskSync", SoilScoutingMaskSyncEvent.newFull(1, 1, 1, { { fieldId = 7, cellKey = "1:2", day = 3, truth = 0.5, x = 1, z = 2, gen = 1 } }), SoilScoutingMaskSyncEvent },
    }
end

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE WRONG SIDE READS NOTHING
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    side("host")
    local out = {}
    for _, e in ipairs(eightEvents()) do
        local s = written(e[2])
        local dst, ok = read(s, e[3], AT_HOST_FROM_CLIENT)
        out[#out + 1] = e[1] .. ":" .. tostring(dst.refused) .. ":" .. tostring(s.r == 1 and ok)
    end
    T.eq("W1 on a listen host each of the eight server-to-client events refuses a client's stream at once, reading nothing",
        table.concat(out, " "),
        "SettingSync:WRONG_SIDE:true FullSync:WRONG_SIDE:true FieldBatchSync:WRONG_SIDE:true FieldUpdate:WRONG_SIDE:true FieldSentryStatus:WRONG_SIDE:true ValueMapChunk:WRONG_SIDE:true ValueMapChecksum:WRONG_SIDE:true ScoutingMaskSync:WRONG_SIDE:true")
    T.eq("W2 and the host's state is untouched", tostring(W.settings.difficulty) .. "/" .. W.soilSystem.fieldData[7].nitrogen, "2/55")

    -- The connection half alone: no server here, a connection that is not the
    -- server's, still nothing read.
    side("client")
    local s = written(SoilFieldUpdateEvent.new(7, field()))
    local dst, ok = read(s, SoilFieldUpdateEvent, AT_HOST_FROM_CLIENT)
    T.eq("W3 with no server on this side, a stream on a connection that is not the server's is still refused unread", refusal(dst, ok, s, 1), "WRONG_SIDE/true/true/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE RIGHT SIDE READS EVERYTHING
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    side("client")
    local out, drained = {}, 0
    for _, e in ipairs(eightEvents()) do
        local s = written(e[2])
        local wrote = #s.q
        local dst, ok = read(s, e[3], AT_CLIENT_FROM_SERVER)
        if ok and dst.refused == nil and s.r == wrote + 1 and _sfStreamFaults(s) == 0 then drained = drained + 1 else out[#out + 1] = e[1] .. ":" .. tostring(dst.refused) .. ":" .. tostring(ok) end
    end
    T.eq("R1 a pure client reads each of the eight whole, no refusal, no fault", drained .. "/8 " .. table.concat(out, " "), "8/8 ")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. EVERY COUNT IS HELD TO ITS WRITER'S BOUND
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    side("client")
    local BATCH = SoilConstants.NETWORK.FULL_SYNC_BATCH_SIZE

    -- The field batch: its writer sends at most FULL_SYNC_BATCH_SIZE fields.
    local s = written(SoilFieldBatchSyncEvent.new(fields(BATCH + 1), true))
    local dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B1 a batch of one field more than the batch size is refused after its count and flag, nothing read further, nothing kept",
        refusal(dst, ok, s, 3) .. "/" .. count(dst.batchFields), "FIELD_COUNT/true/true/0/0")
    s = written(SoilFieldBatchSyncEvent.new(fields(BATCH), true))
    dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B1b a batch of exactly the batch size is read whole", tostring(dst.refused) .. "/" .. tostring(ok) .. "/" .. count(dst.batchFields) .. "/" .. s.underflows, "nil/true/" .. BATCH .. "/0")

    -- The nutrient buffer: keyed by fill type index, at most 2^8 entries.
    s = written(SoilFieldBatchSyncEvent.new({ [7] = field({ buffer = buffer(257) }) }, true))
    local bCountAt = indexOf(s, function(e) return e.t == "i32" and e.v == 257 end)
    dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B2 a batch field with 257 buffer entries is refused at that count", refusal(dst, ok, s, bCountAt + 1), "BUFFER_COUNT/true/true/0")
    s = written(SoilFieldBatchSyncEvent.new({ [7] = field({ buffer = buffer(256) }) }, true))
    dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B2b 256 buffer entries are read", tostring(dst.refused) .. "/" .. count(dst.batchFields[7].nutrientBuffer), "nil/256")

    -- The zone cells: the writer caps at 500, so the attacker edits the count.
    s = written(SoilFieldBatchSyncEvent.new({ [7] = field({ zones = zones(500) }) }, true))
    local zdAt = indexOf(s, function(e) return e.t == "i32" and e.v == 500 end)
    s.q[zdAt].v = 501
    dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B3 a batch field whose zone count is forged to 501 over a 500-cell payload is refused at the count", refusal(dst, ok, s, zdAt + 1), "ZONE_COUNT/true/true/0")
    s = written(SoilFieldBatchSyncEvent.new({ [7] = field({ zones = zones(500) }) }, true))
    dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B3b the writer's own 500 cells are read", tostring(dst.refused) .. "/" .. count(dst.batchFields[7].zoneData), "nil/500")

    -- The field update: buffer and zones (its writer sends 0 zones).
    s = written(SoilFieldUpdateEvent.new(7, field({ buffer = buffer(257) })))
    bCountAt = indexOf(s, function(e) return e.t == "i32" and e.v == 257 end)
    dst, ok = read(s, SoilFieldUpdateEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B4 a field update with 257 buffer entries is refused at that count", refusal(dst, ok, s, bCountAt + 1), "BUFFER_COUNT/true/true/0")
    s = written(SoilFieldUpdateEvent.new(7, field()))
    local zeroZones = indexOf(s, function(e, i) return e.t == "i32" and e.v == 0 and s.q[i + 1] and s.q[i + 1].t == "str" end)
    s.q[zeroZones].v = 501
    dst, ok = read(s, SoilFieldUpdateEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B4b a field update whose zone count is forged to 501 is refused at the count", refusal(dst, ok, s, zeroZones + 1), "ZONE_COUNT/true/true/0")

    -- The full-sync header: the legacy inline fields and their buffers.
    local nSettings = 0
    for _, def in ipairs(SettingsSchema.definitions) do if not def.localOnly then nSettings = nSettings + 1 end end
    s = written(SoilFullSyncEvent.new(settingsTable(), { [7] = field() }))
    s.q[nSettings + 1].v = 4097
    dst, ok = read(s, SoilFullSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B5 a full sync whose inline field count is forged to 4097 is refused at the count", refusal(dst, ok, s, nSettings + 2), "FIELD_COUNT/true/true/0")
    s = written(SoilFullSyncEvent.new(settingsTable(), { [7] = field({ buffer = buffer(257) }) }))
    bCountAt = indexOf(s, function(e) return e.t == "i32" and e.v == 257 end)
    dst, ok = read(s, SoilFullSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B5b a full sync field with 257 buffer entries is refused at that count", refusal(dst, ok, s, bCountAt + 1), "BUFFER_COUNT/true/true/0")
    local big = {}
    for i = 1, 4096 do big[i] = field() end
    s = written(SoilFullSyncEvent.new(settingsTable(), big))
    dst, ok = read(s, SoilFullSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B5c 4096 inline fields, the bound itself, are read whole", tostring(dst.refused) .. "/" .. tostring(ok) .. "/" .. count(dst.fieldData) .. "/" .. s.underflows, "nil/true/4096/0")

    -- The value-map chunk: rows per event, row width, runs per row, a run's length.
    local meta = { mode = "FULL", revision = 1, baseRevision = 0, transferId = 1, partIndex = 0, partCount = 1, sourceResolution = 256, transportStride = 1 }
    local function rowsOf(n, width)
        local rows = {}
        for r = 1, n do
            rows[r] = {}
            for i = 1, width or 8 do rows[r][i] = 3 end
        end
        return rows
    end
    s = written(SoilValueMapChunkEvent.new(2, 0, rowsOf(17), true, meta))
    dst, ok = read(s, SoilValueMapChunkEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B6 a chunk of 17 rows, one over the dispatcher's 16, is refused after its header", refusal(dst, ok, s, 13) .. "/" .. #dst.rows, "ROW_COUNT/true/true/0/0")
    s = written(SoilValueMapChunkEvent.new(2, 0, rowsOf(16), true, meta))
    dst, ok = read(s, SoilValueMapChunkEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B6b 16 rows are read whole", tostring(dst.refused) .. "/" .. #dst.rows .. "/" .. s.underflows, "nil/16/0")
    s = written(SoilValueMapChunkEvent.new(2, 0, rowsOf(1, SoilValueMaps.SYNC_GRID + 1), true, meta))
    dst, ok = read(s, SoilValueMapChunkEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B6c a row one pixel wider than the synced grid is refused at its shape", refusal(dst, ok, s, 15) .. "/" .. #dst.rows, "ROW_SHAPE/true/true/0/0")
    s = written(SoilValueMapChunkEvent.new(2, 0, rowsOf(1, SoilValueMaps.SYNC_GRID), true, meta))
    dst, ok = read(s, SoilValueMapChunkEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B6d a row exactly the grid's width is read", tostring(dst.refused) .. "/" .. #dst.rows[1], "nil/" .. SoilValueMaps.SYNC_GRID)
    s = written(SoilValueMapChunkEvent.new(2, 0, rowsOf(1), true, meta))
    local stateAt = indexOf(s, function(e) return e.t == "uN" end)   -- rowLen, numRuns, state, len
    s.q[stateAt - 1].v = 9                                             -- nine runs over an eight-pixel row
    dst, ok = read(s, SoilValueMapChunkEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B6e more runs than pixels is refused at the row's shape", refusal(dst, ok, s, stateAt), "ROW_SHAPE/true/true/0")
    s = written(SoilValueMapChunkEvent.new(2, 0, rowsOf(1), true, meta))
    stateAt = indexOf(s, function(e) return e.t == "uN" end)
    s.q[stateAt + 1].v = 9                                             -- a nine-pixel run over an eight-pixel row
    dst, ok = read(s, SoilValueMapChunkEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B6f a run longer than the row's remainder is refused at that run", refusal(dst, ok, s, stateAt + 2), "RUN_LENGTH/true/true/0")

    -- The scouting mask: the writer caps at MAX_ENTRIES, so the attacker edits the count.
    local entries = {}
    for i = 1, SoilScoutingMaskSyncEvent.MAX_ENTRIES do entries[i] = { fieldId = 7, cellKey = "1:" .. i, day = 3, truth = 0.5, x = i, z = 2, gen = 1 } end
    s = written(SoilScoutingMaskSyncEvent.newFull(1, 1, 1, entries))
    s.q[6].v = SoilScoutingMaskSyncEvent.MAX_ENTRIES + 1
    dst, ok = read(s, SoilScoutingMaskSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B7 a mask chunk whose entry count is forged one over MAX_ENTRIES is refused at the count", refusal(dst, ok, s, 7) .. "/" .. #dst.entries, "ENTRY_COUNT/true/true/0/0")
    s = written(SoilScoutingMaskSyncEvent.newFull(1, 1, 1, entries))
    dst, ok = read(s, SoilScoutingMaskSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B7b MAX_ENTRIES entries are read", tostring(dst.refused) .. "/" .. #dst.entries, "nil/" .. SoilScoutingMaskSyncEvent.MAX_ENTRIES)

    -- A short stream: the count itself is missing. Refused, not looped, not raised.
    s = _sfMockStream()
    dst, ok = read(s, SoilFieldBatchSyncEvent, AT_CLIENT_FROM_SERVER)
    T.eq("B8 a stream cut before its count refuses instead of looping or raising", tostring(dst.refused) .. "/" .. tostring(ok), "FIELD_COUNT/true")
end)

T.summary()
