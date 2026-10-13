-- sf22_private_mask_spec_test.lua - SF-22 FARM-PRIVATE PER-SQUARE VISIBILITY
--
-- The walked mask must stay private: one farm shares only the cells its own
-- players legally learned, another farm receives ZERO of those bytes, and a
-- client only ever holds its own farm's slice. This bench pins the pure pieces
-- the two-machine live test cannot reach offline:
--   1. the ordinary-farm predicate and the reveal gate,
--   2. the sampler authorisation matrix (own land / contracted land / neighbour),
--   3. the one-farm serialiser and the every-user remote selector,
--   4. the client apply: DELTA immediacy, FULL atomicity + chunk assembly, the
--      wrong-farm / non-ordinary / bad-chunk rejections, generation + freshness,
--   5. the farm-switch transition classifier,
--   6. the SoilScoutingMaskSyncEvent write/read wire round-trip (FULL + DELTA).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialScouting.lua, src/integrations/SoilScoutingBridge.lua, src/OrganicCertification.lua, src/ResistanceBands.lua, src/config/SettingsSchema.lua, src/network/NetworkEvents.lua

-- The event's farm id rides FarmManager.FARM_ID_SEND_NUM_BITS; stub the constant
-- the base game supplies (verified 4 bits, MAX_NUM_FARMS 8).
FarmManager = FarmManager or { FARM_ID_SEND_NUM_BITS = 4, MAX_NUM_FARMS = 8 }

local S = SpatialScouting
local B = SoilScoutingBridge

local function newMask()
    local m = S.new()
    m:arm({ available = true, readValueAtWorld = function() return 40 end, writeValueAtWorld = function() end })
    return m
end

-- ── 1. isOrdinaryFarmId: only the eight playable farms ──────────────────────
do
    for id = 1, 8 do T.ok("ordinary farm " .. id .. " accepted", S.isOrdinaryFarmId(id)) end
    T.ok("spectator 0 rejected",       not S.isOrdinaryFarmId(0))
    T.ok("above max (9) rejected",     not S.isOrdinaryFarmId(9))
    T.ok("guided-tour 14 rejected",    not S.isOrdinaryFarmId(14))
    T.ok("invalid 15 rejected",        not S.isOrdinaryFarmId(15))
    T.ok("nil rejected",               not S.isOrdinaryFarmId(nil))
    T.ok("non-integer rejected",       not S.isOrdinaryFarmId(1.5))
    T.ok("string rejected",            not S.isOrdinaryFarmId("1"))
end

-- ── 2. isRevealAuthorized: same farm OR contracting, both ordinary ──────────
do
    T.ok("same farm authorised",        S.isRevealAuthorized(2, 2, false))
    T.ok("contracting farm authorised", S.isRevealAuthorized(2, 3, true))
    T.ok("neighbour NOT authorised",    not S.isRevealAuthorized(2, 3, false))
    T.ok("non-ordinary owner rejected", not S.isRevealAuthorized(2, 0, true))
    T.ok("non-ordinary player rejected",not S.isRevealAuthorized(0, 2, true))
end

-- ── 3. Sampler authorisation matrix (via _samplePlayer) ─────────────────────
local function walkerAt(farmId)
    return { getIsInVehicle = function() return false end,
             getPosition = function() return 5, 0, 5 end, farmId = farmId }
end
local function setWorld(ownerFarmId, contractMap)
    g_fieldManager = { getFieldAtWorldPosition = function() return { farmland = { id = 5 } } end }
    g_farmlandManager = {
        getFarmlandAtWorldPosition = function() return { id = 5 } end,
        getFarmlandOwner = function() return ownerFarmId end,
    }
    g_farmManager = { getFarmById = function(_self, farmId)
        return { getIsContractingFor = function(_f, ownerId) return contractMap and contractMap[ownerId] == true end }
    end }
end

do
    g_server = {}
    -- Own land: farm 2 on farm-2 ground writes.
    setWorld(2, nil)
    local m = newMask()
    local changed, farm, field = m:_samplePlayer(walkerAt(2), 100)
    T.ok("own-land walk writes", changed)
    T.eq("write lands under the walking farm", farm, 2)
    T.eq("write keys on the resolved farmland", field, 5)

    -- Contracted land: farm 2 on farm-3 ground while contracting for 3 writes.
    setWorld(3, { [3] = true })
    local m2 = newMask()
    T.ok("contracted-land walk writes", (m2:_samplePlayer(walkerAt(2), 100)))
    T.ok("the contracted cell lands under the contractor's farm", m2:maskEntry(2, 5, S.cellKey(5, 5)) ~= nil)

    -- Neighbour: farm 2 on farm-3 ground with no contract writes NOTHING.
    setWorld(3, nil)
    local m3 = newMask()
    T.ok("neighbour walk writes nothing", not (m3:_samplePlayer(walkerAt(2), 100)))
    T.ok("the neighbour mask stays empty", next(m3.masks) == nil)

    -- Non-ordinary walking farm (spectator) writes nothing even on owned-looking land.
    setWorld(0, nil)
    local m4 = newMask()
    T.ok("a spectator walker writes nothing", not (m4:_samplePlayer(walkerAt(0), 100)))
    g_server = nil
end

-- ── 4a. serializeFarmMask: one farm only, deterministic order ───────────────
do
    local m = newMask()
    m:noteWalk(1, 6, "20", 100, 11, 0, 0)
    m:noteWalk(1, 6, "10", 100, 12, 0, 0)
    m:noteWalk(1, 5, "99", 100, 13, 0, 0)
    m:noteWalk(2, 9, "7", 100, 55, 0, 0)   -- another farm

    local e = B.serializeFarmMask(m, 1)
    T.eq("only farm 1's three cells serialise", #e, 3)
    T.eq("ordered by numeric field id first", e[1].fieldId, 5)
    T.eq("then by string cell key (10 before 20)", e[2].cellKey, "10")
    T.eq("and 20 after 10", e[3].cellKey, "20")
    T.eq("empty farm serialises to nothing", #B.serializeFarmMask(m, 4), 0)
end

-- ── 4b. selectRemoteConnections: same-farm remotes only ─────────────────────
do
    local function conn(opts) return {
        isConnected = opts.connected ~= false,
        isReadyForEvents = opts.ready ~= false,
        getIsLocal = function() return opts.localStream == true end,
    } end
    local users = {
        { id = 11, connection = conn({}) },                       -- farm 1 remote  (keep)
        { id = 12, connection = conn({ localStream = true }) },   -- farm 1 LOOPBACK (drop)
        { id = 13, connection = conn({ connected = false }) },    -- farm 1 dropped  (drop)
        { id = 14, connection = conn({ ready = false }) },        -- farm 1 loading  (drop)
        { id = 21, connection = conn({}) },                       -- farm 2 remote   (drop: wrong farm)
    }
    local farmOf = { [11] = 1, [12] = 1, [13] = 1, [14] = 1, [21] = 2 }
    local farmManager = { getFarmByUserId = function(_self, uid) return { farmId = farmOf[uid] } end }

    local conns = B.selectRemoteConnections(users, farmManager, 1)
    T.eq("exactly one farm-1 remote is selected", #conns, 1)
    T.ok("the loopback host connection is never selected", conns[1] == users[1].connection)
    T.eq("a non-ordinary target farm selects nobody", #B.selectRemoteConnections(users, farmManager, 0), 0)
end

-- ── 4c. applyMaskEvent: DELTA immediacy + guards ────────────────────────────
do
    local c = newMask()
    -- DELTA applies at once and never clears.
    B.applyMaskEvent(c, 1, { mode = B.MASK_MODE_DELTA, farmId = 1, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42, x = 0, z = 0, gen = 0 } } })
    T.eq("DELTA cell composes for its own farm", c:composeShown(1, 5, "1", 103, -1, false), 42)

    -- A second DELTA adds without wiping the first.
    B.applyMaskEvent(c, 1, { mode = B.MASK_MODE_DELTA, farmId = 1, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 6, cellKey = "2", day = 101, truth = 13, x = 0, z = 0, gen = 0 } } })
    T.eq("DELTA never clears the prior cell", c:composeShown(1, 5, "1", 103, -1, false), 42)
    T.eq("the second DELTA cell is present too", c:composeShown(1, 6, "2", 103, -1, false), 13)

    -- Wrong-farm payload is rejected before mutation.
    local w = newMask()
    B.applyMaskEvent(w, 1, { mode = B.MASK_MODE_DELTA, farmId = 2, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42 } } })
    T.ok("a wrong-farm payload lands nothing", next(w.masks) == nil)

    -- Non-ordinary local farm is rejected.
    local n = newMask()
    B.applyMaskEvent(n, 0, { mode = B.MASK_MODE_DELTA, farmId = 0, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42 } } })
    T.ok("a non-ordinary local farm lands nothing", next(n.masks) == nil)
end

-- ── 4d. FULL is atomic across chunks; a dropped chunk never applies ─────────
do
    -- Two-chunk FULL: nothing composes until BOTH chunks arrive.
    local c = newMask()
    B.applyMaskEvent(c, 1, { mode = B.MASK_MODE_FULL, farmId = 1, chunkIndex = 1, chunkCount = 2,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42, gen = 0 } } })
    T.eq("FULL does not apply on the first of two chunks", c:composeShown(1, 5, "1", 103, -1, false), -1)
    B.applyMaskEvent(c, 1, { mode = B.MASK_MODE_FULL, farmId = 1, chunkIndex = 2, chunkCount = 2,
        entries = { { fieldId = 6, cellKey = "2", day = 101, truth = 13, gen = 0 } } })
    T.eq("FULL applies both cells once the set is complete (cell 5)", c:composeShown(1, 5, "1", 103, -1, false), 42)
    T.eq("FULL applies both cells once the set is complete (cell 6)", c:composeShown(1, 6, "2", 103, -1, false), 13)

    -- A dropped final chunk means the FULL never applies (no torn state).
    local d = newMask()
    B.applyMaskEvent(d, 1, { mode = B.MASK_MODE_FULL, farmId = 1, chunkIndex = 1, chunkCount = 2,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42, gen = 0 } } })
    -- chunk 2 never arrives
    T.ok("a partial FULL never mutates the live mask", next(d.masks) == nil)

    -- FULL replaces atomically: an old cell absent from the new set is gone.
    local r = newMask()
    r:noteWalk(1, 5, "OLD", 90, 99, 0, 0)
    B.applyMaskEvent(r, 1, { mode = B.MASK_MODE_FULL, farmId = 1, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 5, cellKey = "NEW", day = 100, truth = 42, gen = 0 } } })
    T.eq("FULL clears the stale cell", r:composeShown(1, 5, "OLD", 103, -1, false), -1)
    T.eq("FULL installs the fresh cell", r:composeShown(1, 5, "NEW", 103, -1, false), 42)

    -- An out-of-range chunk index is rejected without touching live tables.
    local o = newMask()
    B.applyMaskEvent(o, 1, { mode = B.MASK_MODE_FULL, farmId = 1, chunkIndex = 3, chunkCount = 2,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42 } } })
    T.ok("an out-of-range chunk lands nothing", next(o.masks) == nil)
end

-- ── 4e. generation is raised before freshness; freshest day wins ────────────
do
    -- An entry stamped with a newer generation raises the field generation so a
    -- stale-generation compose is gated out.
    local c = newMask()
    B.applyMaskEvent(c, 1, { mode = B.MASK_MODE_DELTA, farmId = 1, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 5, cellKey = "1", day = 100, truth = 42, gen = 2 } } })
    T.eq("generation-2 cell composes under generation 2", c:composeShown(1, 5, "1", 103, -1, false), 42)
    T.eq("the field generation was raised to 2", c.generations[1][5], 2)

    -- Freshest day wins on a same-cell re-apply.
    B.applyMaskEvent(c, 1, { mode = B.MASK_MODE_DELTA, farmId = 1, chunkIndex = 1, chunkCount = 1,
        entries = { { fieldId = 5, cellKey = "1", day = 105, truth = 77, gen = 2 } } })
    T.eq("a newer day overwrites the cell truth", c:composeShown(1, 5, "1", 106, -1, false), 77)
end

-- ── 5. classifyLocalFarmTransition ──────────────────────────────────────────
do
    T.eq("the first observation is a no-op", B.classifyLocalFarmTransition(false, nil, 1), nil)
    T.eq("an unchanged farm is a no-op", B.classifyLocalFarmTransition(true, 1, 1), nil)
    local d = B.classifyLocalFarmTransition(true, 1, 2)
    T.ok("a switch to an ordinary farm clears and requests", d ~= nil and d.clear == true and d.request == true)
    local d2 = B.classifyLocalFarmTransition(true, 1, 0)
    T.ok("a switch to a non-ordinary farm clears but does NOT request",
         d2 ~= nil and d2.clear == true and d2.request == false)
end

-- ── 6. SoilScoutingMaskSyncEvent wire round-trip (FULL + DELTA) ──────────────
do
    g_server = nil   -- keep readStream's trailing run() a safe no-op (no manager present)
    local CONN = {}
    local function rt(name, ev)
        local s = _sfMockStream()
        ev:writeStream(s, CONN)
        local wrote = #s.q
        local dst = SoilScoutingMaskSyncEvent.emptyNew()
        dst:readStream(s, CONN)
        T.eq(name .. ": no type mismatches", s.typeErrors, 0)
        T.eq(name .. ": no stream underflow", s.underflows, 0)
        T.eq(name .. ": stream fully drained", s.r, wrote + 1)
        return dst
    end

    local entries = {
        { fieldId = 5, cellKey = "20003", day = 100, truth = 42, x = 25, z = 35, gen = 1 },
        { fieldId = 6, cellKey = "-30004", day = 101, truth = 13, x = -25, z = -35, gen = 0 },
    }
    local full = rt("FULL", SoilScoutingMaskSyncEvent.newFull(3, 1, 2, entries))
    T.eq("FULL: mode preserved", full.mode, SoilScoutingMaskSyncEvent.MODE_FULL)
    T.eq("FULL: farm id preserved", full.farmId, 3)
    T.eq("FULL: chunk index preserved", full.chunkIndex, 1)
    T.eq("FULL: chunk count preserved", full.chunkCount, 2)
    T.eq("FULL: entry count preserved", #full.entries, 2)
    T.eq("FULL: field id preserved", full.entries[1].fieldId, 5)
    T.eq("FULL: cell key preserved", full.entries[2].cellKey, "-30004")
    T.near("FULL: truth preserved", full.entries[1].truth, 42)
    T.eq("FULL: generation preserved", full.entries[1].gen, 1)

    local delta = rt("DELTA", SoilScoutingMaskSyncEvent.newDelta(2, { entries[1] }))
    T.eq("DELTA: mode preserved", delta.mode, SoilScoutingMaskSyncEvent.MODE_DELTA)
    T.eq("DELTA: farm id preserved", delta.farmId, 2)
    T.eq("DELTA: is chunk 1 of 1", delta.chunkCount, 1)
    T.eq("DELTA: single entry preserved", #delta.entries, 1)
end
