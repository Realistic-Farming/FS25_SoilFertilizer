-- SF-995-value_map_sync_cost_spec_test.lua
--
-- #995, the dedicated-server stutter: the value-map sync's cost per tick, measured.
-- Bob's intake (BOB-INTAKE-SF-995-DEDI-STUTTER-2026-09-23.md): the 5-minute checksum
-- broadcast walked every synced layer's sync grid in ONE tick (getBitVectorMapPoint
-- once per grid point) on the server and on every client, and re-sent whole layers
-- because nothing carried a write to the clients. Now SoilValueMaps keeps per-row
-- totals and marks the rows each write touched, the server's timer round patches
-- the dirty rows before its checksum, and either side refreshes at most
-- SF_SYNC_ROWS_PER_TICK rows per tick.
--
-- THE ENTRY-POINT BAR IS THE WHOLE FILE: the server's timer is the real
-- SoilFertilityManager:update accumulating past 300000 ms in a multiplayer mission
-- model; the round is the real SoilNetworkEvents_BroadcastValueMapChecksums through
-- the mission's addUpdateable; every event crosses the wire through its own
-- writeStream and readStream (the mock stream) and runs on the other side as the
-- engine runs it; the join is the real SoilNetworkEvents_SendValueMaps dispatcher;
-- the maps are two SoilValueMaps instances through their own initialize; the drift
-- comes from production's writers. Nothing writes a row, a checksum, a dirty set or
-- a chunk by hand. The grid is the engine model's (64 x 64, one metre per pixel,
-- stride 1), so the numbers below are that grid's; the formula is the same at 512.
--
-- Groups:
--   J  a client that has no FULL yet ignores a PATCH, is judged, and gets ONE FULL
--      reply for the drifted layer only
--   W  the join: FULL layers drip-fed, the checksum read back over bounded ticks,
--      no request; the old walk's cost for comparison
--   P  a field write between timers: a PATCH of that field's rows only, the client
--      then matches without a request; a quiet round costs nothing
--   L  a lost PATCH chunk: exactly one FULL resend of that layer
--   E  the running checksum equals a fresh full walk after any write sequence
--   D  a dedicated server still drip-feeds
--   R  a timer firing during a round is skipped; the audit round refreshes every row
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/SoilContextInput.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/SoilFertilityManager.lua, src/network/NetworkEvents.lua

local FRAME = 16
local ROWS, COLS = ENGINE.RESOLUTION, ENGINE.RESOLUTION   -- the sync grid at this resolution
local ROWS_PER_TICK = 64                                   -- SF_SYNC_ROWS_PER_TICK, restated
local ROWS_PER_EVENT = 16                                  -- SF_SYNC_ROWS_PER_EVENT, restated
local TIMER = 300000

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the synced layers, as production lists them ──────────────────────────────
local SYNCED = {}
for idx, def in ipairs(SoilValueMaps.LAYER_DEFS) do
    if def.serverOnly ~= true then SYNCED[#SYNCED + 1] = { idx = idx, key = def.key } end
end
local NITROGEN
for _, l in ipairs(SYNCED) do if l.key == "nitrogen" then NITROGEN = l.idx end end

-- ── the wire ─────────────────────────────────────────────────────────────────
local WIRE = { toClient = {}, toServer = {}, dropPatch = false, dropped = 0, faults = 0, other = 0,
               client = {}, server = {} }   -- client/server: the events delivered to that side
local CONN = { isConnected = true, sendEvent = function(_, ev) WIRE.toClient[#WIRE.toClient + 1] = ev end }
local SERVER = { broadcastEvent = function(_, ev) WIRE.toClient[#WIRE.toClient + 1] = ev end }
local SERVER_CONN = { sendEvent = function(_, ev) WIRE.toServer[#WIRE.toServer + 1] = ev end }
local CLIENT = { getServerConnection = function() return SERVER_CONN end }
local DELIVERABLE = { SoilValueMapChunkEvent = true, SoilValueMapChecksumEvent = true, SoilRequestValueMapEvent = true }

local function newMission(isServer)
    local m = { missionDynamicInfo = { isMultiplayer = true }, missionInfo = {}, updateables = {},
                environment = { currentDay = 1, daysPerPeriod = 1 }, time = 0, isMissionStarted = true }
    m.addUpdateable = function(self, u) self.updateables[#self.updateables + 1] = u end
    m.removeUpdateable = function(self, u)
        for i, x in ipairs(self.updateables) do if x == u then table.remove(self.updateables, i) return end end
    end
    m.getIsServer = function() return isServer end
    return m
end
local serverMission, clientMission = newMission(true), newMission(false)

local serverVm, clientVm, SMGR, CMGR
local function asServer(fn)
    g_server, g_client, g_currentMission, g_SoilFertilityManager = SERVER, nil, serverMission, SMGR
    return fn()
end
local function asClient(fn)
    g_server, g_client, g_currentMission, g_SoilFertilityManager = nil, CLIENT, clientMission, CMGR
    return fn()
end

-- The maps, through their own initialize: the model's files "exist", so the maps
-- adopt the persisted 64 px resolution (SoilValueMaps :270-300).
asServer(function() serverVm = SoilValueMaps.new(); serverVm:initialize("/save") end)
asClient(function() clientVm = SoilValueMaps.new(); clientVm:initialize("/save") end)
SMGR = setmetatable({ settings = { enabled = false }, soilSystem = { valueMaps = serverVm }, _vmChecksumTimer = 0 },
                    { __index = SoilFertilityManager })
CMGR = { soilSystem = { valueMaps = clientVm } }

-- ── ticks ────────────────────────────────────────────────────────────────────
local MAX = { server = 0, client = 0 }       -- engine reads in the largest tick of a window
local TOTAL = { server = 0, client = 0 }     -- engine reads over a window
local function resetWindow() MAX.server, MAX.client, TOTAL.server, TOTAL.client = 0, 0, 0, 0 end
local function account(side)
    local closed = ENGINE.tickBoundary()
    local reads = closed.getBitVectorMapPoint
    if reads > MAX[side] then MAX[side] = reads end
    TOTAL[side] = TOTAL[side] + reads
end

local function deliver(ev, fromSide)
    local s = _sfMockStream()
    ev:writeStream(s, CONN)
    local class = _G[ev.className]
    class.emptyNew():readStream(s, fromSide == "server" and SERVER_CONN or CONN)
    WIRE.faults = WIRE.faults + _sfStreamFaults(s)
end
local function copy(t) local c = {} for i, v in ipairs(t) do c[i] = v end return c end

local TICKS = 0
local function serverTick(dt)
    asServer(function()
        local q = WIRE.toServer
        WIRE.toServer = {}
        for _, ev in ipairs(q) do
            if DELIVERABLE[ev.className] then
                deliver(ev, "client")
                WIRE.server[#WIRE.server + 1] = ev
            else
                WIRE.other = WIRE.other + 1
            end
        end
        SoilFertilityManager.update(SMGR, dt)          -- the real timer
        for _, u in ipairs(copy(serverMission.updateables)) do u:update(dt) end
    end)
    account("server")
end
local function clientTick(dt)
    asClient(function()
        local q = WIRE.toClient
        WIRE.toClient = {}
        for _, ev in ipairs(q) do
            if not DELIVERABLE[ev.className] then
                WIRE.other = WIRE.other + 1
            elseif WIRE.dropPatch and ev.className == "SoilValueMapChunkEvent" and ev.mode == "PATCH" then
                WIRE.dropped = WIRE.dropped + 1
            else
                deliver(ev, "server")
                ev._tick = TICKS
                WIRE.client[#WIRE.client + 1] = ev
            end
        end
        for _, u in ipairs(copy(clientMission.updateables)) do u:update(dt) end
    end)
    account("client")
end
local function idle()
    return #serverMission.updateables == 0 and #clientMission.updateables == 0
       and #WIRE.toClient == 0 and #WIRE.toServer == 0
end
local function tick(dt) TICKS = TICKS + 1 serverTick(dt) clientTick(dt) end
--- Advance `ms` of wall time: 16 ms frames while anything is in flight, up to one
--- second per frame while both sides are idle (the timer only accumulates dt).
local function advance(ms)
    local left = ms
    while left > 0 do
        local dt = idle() and math.min(1000, left) or FRAME
        tick(dt)
        left = left - dt
    end
end
--- Frames until both sides are idle (bounded).
local function settle(maxTicks)
    for _ = 1, maxTicks or 3000 do
        if idle() then return true end
        tick(FRAME)
    end
    return idle()
end
local function untilTrue(pred, maxTicks)
    for _ = 1, maxTicks or 3000 do
        if pred() then return true end
        tick(FRAME)
    end
    return false
end
--- A timer period: the real firing at 300000 ms, then everything it starts, settled.
local function period()
    advance(TIMER)
    settle()
end

-- ── readers ──────────────────────────────────────────────────────────────────
local function since(log, from)
    local out = {}
    for i = from + 1, #log do out[#out + 1] = log[i] end
    return out
end
local function chunks(events, mode)
    local out = {}
    for _, ev in ipairs(events) do
        if ev.className == "SoilValueMapChunkEvent" and (mode == nil or ev.mode == mode) then out[#out + 1] = ev end
    end
    return out
end
local function checksums(events)
    local out = {}
    for _, ev in ipairs(events) do if ev.className == "SoilValueMapChecksumEvent" then out[#out + 1] = ev end end
    return out
end
local function requests(events)
    local out = {}
    for _, ev in ipairs(events) do if ev.className == "SoilRequestValueMapEvent" then out[#out + 1] = ev end end
    return out
end
--- "layerIdx:gyStart+rows" per chunk, joined.
local function describe(chunkList)
    local out = {}
    for _, ch in ipairs(chunkList) do out[#out + 1] = ch.layerIdx .. ":" .. ch.gyStart .. "+" .. #ch.rows end
    return table.concat(out, ",")
end
--- Sync-grid states that differ between the two maps on `key`, on rows gy0..gy1.
local function mismatches(key, gy0, gy1)
    local s, c = serverVm.layers[key], clientVm.layers[key]
    local n = 0
    for gy = gy0 or 0, gy1 or ROWS - 1 do
        for gx = 0, COLS - 1 do
            local a = math.floor(ENGINE.pixel(s.bvm, gx, gy) / 16)
            local b = math.floor(ENGINE.pixel(c.bvm, gx, gy) / 16)
            if a ~= b then n = n + 1 end
        end
    end
    return n
end
local function allMatch()
    local bad = {}
    for _, l in ipairs(SYNCED) do if mismatches(l.key) > 0 then bad[#bad + 1] = l.key end end
    return table.concat(bad, ",")
end
local function clientStatesZero(key, gy0, gy1)
    local c = clientVm.layers[key]
    for gy = gy0, gy1 do
        for gx = 0, COLS - 1 do
            if ENGINE.pixel(c.bvm, gx, gy) ~= 0 then return false end
        end
    end
    return true
end
local function field(x0, z0, x1, z1)
    return { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } }
end
local LOG = {}
local realPrint = print
print = function(s) LOG[#LOG + 1] = tostring(s) realPrint(s) end
local function logHas(fragment, from)
    for i = (from or 0) + 1, #LOG do if LOG[i]:find(fragment, 1, true) then return true end end
    return false
end

-- ══════════════════════════════════════════════════════════════════════════
-- J. A CLIENT WITH NO FULL YET
-- ══════════════════════════════════════════════════════════════════════════
group("J", function()
    -- Rows 12..28 of nitrogen written on the server (a 16 m field, z -20..-4).
    asServer(function() serverVm:paintPolygon("nitrogen", field(-24, -20, -8, -4), 80) end)
    local c0, s0 = #WIRE.client, #WIRE.server
    resetWindow()
    advance(TIMER)
    -- The PATCH chunks arrive before the checksum; the client holds no FULL of any layer.
    T.ok("J1 [world] the round's PATCH chunks reached the client", untilTrue(function() return #chunks(since(WIRE.client, c0), "PATCH") >= 2 end))
    T.eq("J2 the patch is nitrogen's rows 12 to 28, two chunks", describe(chunks(since(WIRE.client, c0), "PATCH")), NITROGEN .. ":12+16," .. NITROGEN .. ":28+1")
    T.ok("J3 a PATCH before the layer's FULL is ignored: those rows stay empty here", clientStatesZero("nitrogen", 12, 28))
    settle()
    local mine = since(WIRE.client, c0)
    local req = requests(since(WIRE.server, s0))
    T.eq("J4 the checksum judged the drift and the client asked for that one layer, once", #req .. "/" .. tostring(req[1] and req[1].layerIdx), "1/" .. NITROGEN)
    T.eq("J5 the reply is FULL, four chunks of that layer", describe(chunks(mine, "FULL")), NITROGEN .. ":0+16," .. NITROGEN .. ":16+16," .. NITROGEN .. ":32+16," .. NITROGEN .. ":48+16")
    local cs = checksums(mine)
    T.eq("J6 the round's checksum carried every synced layer; the reply's carried that layer alone", #cs[1].checksums .. "/" .. #cs[2].checksums .. "/" .. tostring(cs[2].checksums[1].layerIdx), #SYNCED .. "/1/" .. NITROGEN)
    T.eq("J7 after the reply the client matches the server on every synced layer", allMatch(), "")
    T.eq("J8 and no second request followed", #requests(since(WIRE.server, s0)), 1)
    T.ok("J9 the largest tick on either side read at most one budget of rows (" .. ROWS_PER_TICK * COLS .. ")", MAX.server <= ROWS_PER_TICK * COLS and MAX.client <= ROWS_PER_TICK * COLS)
    T.eq("J10 every event crossed the wire without a stream fault", WIRE.faults, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE JOIN
-- ══════════════════════════════════════════════════════════════════════════
group("W", function()
    asServer(function()
        serverVm:paintPolygon("phosphorus", field(-30, -30, 30, 30), 40)
        serverVm:paintPolygon("potassium", field(0, 0, 30, 30), 120)
    end)
    -- The old walk's cost for comparison: every synced layer's grid in one call.
    ENGINE.tickBoundary()
    asServer(function() for _, l in ipairs(SYNCED) do serverVm:computeSyncChecksumFullWalk(l.key) end end)
    local walk = ENGINE.tickBoundary().getBitVectorMapPoint
    T.eq("W1 the old broadcast tick: every synced layer walked, " .. #SYNCED .. " x " .. ROWS * COLS .. " reads in one tick", walk, #SYNCED * ROWS * COLS)

    local c0, s0 = #WIRE.client, #WIRE.server
    resetWindow()
    asServer(function() SoilNetworkEvents_SendValueMaps(CONN) end)
    T.ok("W2 [world] the dispatcher registered rather than sending synchronously", #serverMission.updateables == 1 and #WIRE.toClient == 0)
    settle()
    local mine = since(WIRE.client, c0)
    local full = chunks(mine, "FULL")
    T.eq("W3 the join streamed every synced layer FULL, four chunks each", #full, #SYNCED * 4)
    T.ok("W4 drip-fed: the first and last chunk arrived on different ticks", full[1]._tick < full[#full]._tick)
    T.ok("W4b at the 40 ms delay: consecutive chunks at least two frames apart", full[2]._tick - full[1]._tick >= 2 and full[3]._tick - full[2]._tick >= 2)
    T.eq("W5 the client then matches the server on every synced layer", allMatch(), "")
    T.eq("W6 the trailing checksum carried every synced layer and the client requested nothing", #checksums(mine)[1].checksums .. "/" .. #requests(since(WIRE.server, s0)), #SYNCED .. "/0")
    T.ok("W7 the server read at most one chunk's rows per tick (" .. ROWS_PER_EVENT * COLS .. ")", MAX.server <= ROWS_PER_EVENT * COLS)
    T.ok("W8 the client read back at most one budget of rows per tick (" .. ROWS_PER_TICK * COLS .. "), against " .. walk .. " in one tick before", MAX.client <= ROWS_PER_TICK * COLS and MAX.client * 4 <= walk)
    -- The rows written before the join are still in the server's dirty set: the
    -- next round patches them (redundant for this client, harmless, once).
    c0, s0 = #WIRE.client, #WIRE.server
    period()
    T.ok("W9 the first round after the join patched the rows written before it, and the client asked for nothing", #chunks(since(WIRE.client, c0), "PATCH") > 0 and #requests(since(WIRE.server, s0)) == 0)
    T.eq("W10 wire faults", WIRE.faults, 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. A FIELD WRITE BETWEEN TIMERS
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    local c0, s0, l0 = #WIRE.client, #WIRE.server, #LOG
    asServer(function() serverVm:paintPolygon("nitrogen", field(8, 4, 24, 20), 150) end)   -- rows 36..52
    resetWindow()
    period()
    local mine = since(WIRE.client, c0)
    T.eq("P1 the round patched nitrogen's rows 36 to 52 and nothing else", describe(chunks(mine)), NITROGEN .. ":36+16," .. NITROGEN .. ":52+1")
    T.eq("P2 no FULL chunk in the round", #chunks(mine, "FULL"), 0)
    local pc = chunks(mine, "PATCH")
    T.ok("P2b the patch is drip-fed too: its two chunks at least two frames apart", pc[2]._tick - pc[1]._tick >= 2)
    T.eq("P3 the client's checksum matched: no request", #requests(since(WIRE.server, s0)), 0)
    T.eq("P4 and the client matches the server on those rows", mismatches("nitrogen", 36, 52), 0)
    T.eq("P5 the server read exactly the 17 written rows in the whole round (17 x " .. COLS .. ")", TOTAL.server, 17 * COLS)
    T.eq("P6 the client read back exactly the 17 patched rows", TOTAL.client, 17 * COLS)
    T.ok("P7 the in-game evidence: the round's own log line", logHas("value map round", l0) and logHas("2 patch chunk(s), checksums from the row cache", l0))
    T.ok("P7b and the client's: the patch complete, its overlays refreshed", logHas("Client: value map patch complete (1 layers)", l0))
    -- A quiet period.
    c0, s0 = #WIRE.client, #WIRE.server
    resetWindow()
    period()
    mine = since(WIRE.client, c0)
    T.eq("P8 a round with no writes sends no chunk and one checksum", #chunks(mine) .. "/" .. #checksums(mine), "0/1")
    T.eq("P9 and costs no engine read on either side", TOTAL.server .. "/" .. TOTAL.client, "0/0")
    T.eq("P10 no request", #requests(since(WIRE.server, s0)), 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. A LOST PATCH CHUNK
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    local c0, s0 = #WIRE.client, #WIRE.server
    asServer(function() serverVm:paintPolygon("nitrogen", field(8, 4, 24, 20), 20) end)
    WIRE.dropPatch, WIRE.dropped = true, 0
    advance(TIMER)
    untilTrue(function() return #checksums(since(WIRE.client, c0)) >= 1 end)
    WIRE.dropPatch = false
    settle()
    local mine = since(WIRE.client, c0)
    T.eq("L1 the patch's two chunks were lost on the wire", WIRE.dropped, 2)
    T.eq("L2 the checksum found the drift: exactly one request, for nitrogen", #requests(since(WIRE.server, s0)) .. "/" .. tostring(requests(since(WIRE.server, s0))[1] and requests(since(WIRE.server, s0))[1].layerIdx), "1/" .. NITROGEN)
    T.eq("L3 the reply was that layer FULL, then its own checksum", describe(chunks(mine, "FULL")) .. "/" .. #checksums(mine)[2].checksums, NITROGEN .. ":0+16," .. NITROGEN .. ":16+16," .. NITROGEN .. ":32+16," .. NITROGEN .. ":48+16/1")
    T.eq("L4 after it the client matches the server", allMatch(), "")
    c0, s0 = #WIRE.client, #WIRE.server
    period()
    T.eq("L5 the next quiet round: no request (the attempt counter reset on the match)", #requests(since(WIRE.server, s0)) .. "/" .. #chunks(since(WIRE.client, c0)), "0/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE RUNNING CHECKSUM AGAINST A FRESH WALK
-- ══════════════════════════════════════════════════════════════════════════
local function refreshAll(vm, key)
    for _, gy in ipairs(vm:getSyncStaleRows(key)) do vm:refreshSyncRow(key, gy) end
end
local function agree(vm, key)
    refreshAll(vm, key)
    local sum, nonZero, stale = vm:getSyncChecksum(key)
    local wsum, wnon = vm:computeSyncChecksumFullWalk(key)
    return sum .. "/" .. nonZero .. "/" .. stale .. " vs " .. wsum .. "/" .. wnon, sum == wsum and nonZero == wnon and stale == 0
end
group("E", function()
    local s0 = #WIRE.server
    asServer(function()
        T.eq("E0 [world] nothing of nitrogen is dirty after the last round", #serverVm:getSyncDirtyRows("nitrogen"), 0)
        serverVm:writeValueAtWorld("nitrogen", 5, 5, 60, 1.5)
        T.eq("E1 a point write of radius 1.5 at z 5 dirties the rows its pixel lines cover, 35 to 38", table.concat(serverVm:getSyncDirtyRows("nitrogen"), ","), "35,36,37,38")
        serverVm:paintStrip("phosphorus", -20, 10, 20, 12, 1.5, 70)
        serverVm:applyDeltaToPolygon("potassium", field(0, 0, 30, 30), 8)
        serverVm:applyRawDeltaToLayer("nitrogen", 1, 1, 254)
        -- The aimed writes land on rows whose totals are cached already (refreshed here
        -- first), so a write that fails to mark them is a wrong cache, not a late read.
        refreshAll(serverVm, "phosphorus"); refreshAll(serverVm, "potassium")
        local dirtyP0, dirtyK0 = #serverVm:getSyncDirtyRows("phosphorus"), #serverVm:getSyncDirtyRows("potassium")
        local okSet = serverVm:setPolygonWhere("phosphorus", field(-10, -10, 10, 10), 100, 0, 255)
        local okClear = serverVm:clearPolygonWhere("potassium", field(5, 5, 15, 15), 1, 255)
        local dP, dK = #serverVm:getSyncDirtyRows("phosphorus"), #serverVm:getSyncDirtyRows("potassium")
        local sP, sK = #serverVm:getSyncStaleRows("phosphorus"), #serverVm:getSyncStaleRows("potassium")
        -- The clear lands inside rows the delta above already dirtied, so its dirty count
        -- cannot grow; the stale marks after a full refresh are the proof for both.
        T.ok("E1b an aimed set and an aimed clear on rows already cached mark them stale again (and the set's new rows dirty), so the cache and the clients both learn of them (" ..
            tostring(okSet) .. "/" .. tostring(okClear) .. " dirty " .. dirtyP0 .. ">" .. dP .. "," .. dirtyK0 .. ">=" .. dK .. " stale " .. sP .. "," .. sK .. ")",
            okSet == true and okClear == true and dP > dirtyP0 and dK >= dirtyK0 and sP > 0 and sK > 0)
        for _, key in ipairs({ "nitrogen", "phosphorus", "potassium" }) do
            local shown, ok = agree(serverVm, key)
            T.ok("E2 after the write sequence the cached checksum equals a fresh full walk on " .. key .. " (" .. shown .. ")", ok)
        end
        -- A map loaded with content (a savegame) has rows no one has read yet: every one
        -- is stale until refreshed, never trusted as zero.
        serverVm:saveToSavegame("/save-e5")
        local loaded = SoilValueMaps.new(); loaded:initialize("/save-e5")
        local sum0, _, stale0 = loaded:getSyncChecksum("nitrogen")
        local shown5, ok5 = agree(loaded, "nitrogen")
        T.ok("E5 a freshly loaded map starts with every row stale and no total (" .. tostring(sum0) .. "/" .. tostring(stale0) .. " before the first refresh), and its refreshed checksum equals the walk of the content it loaded (" .. shown5 .. ")",
            sum0 == 0 and stale0 == ROWS and ok5 and (select(1, loaded:getSyncChecksum("nitrogen"))) > 0)
        -- Every dirty row of nitrogen (the whole-layer delta marked them all).
        T.eq("E3 a whole-layer delta dirties every row", #serverVm:getSyncDirtyRows("nitrogen"), ROWS)
    end)
    -- Bring the client back in step so the later groups start matched.
    period()
    T.eq("E4 the round carried the sequence to the client without a request", allMatch() .. "/" .. #requests(since(WIRE.server, s0)), "/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A DEDICATED SERVER
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
    local c0, l0 = #WIRE.client, #LOG
    g_dedicatedServer = {}
    asServer(function() SoilNetworkEvents_SendValueMaps(CONN, NITROGEN) end)
    local registered = #serverMission.updateables == 1
    settle()
    g_dedicatedServer = nil
    local full = chunks(since(WIRE.client, c0), "FULL")
    T.ok("D1 with g_dedicatedServer set the send still goes through the dispatcher (52311815), never synchronously", registered and logHas("value map dispatcher registered", l0) and not logHas("sent synchronously", l0))
    T.ok("D2 its four chunks arrived over separate ticks", #full == 4 and full[1]._tick < full[4]._tick)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE TIMER DURING A ROUND; THE AUDIT ROUND
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    local c0 = #WIRE.client
    asServer(function() serverVm:paintPolygon("nitrogen", field(-24, -20, -8, -4), 200) end)
    -- Idle to the firing: the round registers on the tick the timer crosses 300000 ms.
    local guard = 0
    while #serverMission.updateables == 0 and guard < 400 do tick(1000) guard = guard + 1 end
    T.ok("R0 [world] the round is registered and still running after its first step", #serverMission.updateables == 1)
    -- The timer fires again while the round is still running.
    SMGR._vmChecksumTimer = TIMER
    tick(FRAME)
    settle()
    T.eq("R1 a firing during a running round is skipped: one checksum event, not two", #checksums(since(WIRE.client, c0)), 1)
    -- Rounds so far: J, W9, P, P8, L, L5, E4, R1 = 8; the audit round is every sixth
    -- (round 6 was L5). Run quiet rounds until the next audit, round 12.
    local found, l0
    for _ = 1, 6 do
        l0 = #LOG
        resetWindow()
        period()
        if logHas("audit round, every row refreshed", l0) then found = true break end
    end
    T.ok("R2 an audit round refreshes every row of every synced layer", found and TOTAL.server == #SYNCED * ROWS * COLS)
    T.ok("R3 spread at the row budget: the largest tick read " .. MAX.server .. " (at most " .. ROWS_PER_TICK * COLS .. ")", MAX.server <= ROWS_PER_TICK * COLS and MAX.server > 0)
    T.eq("R4 stream faults over the whole file", WIRE.faults, 0)
end)

print = realPrint
