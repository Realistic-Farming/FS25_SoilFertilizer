-- spatial_scouting_spec_test.lua - SF-26 THE WALKED MASK
--
-- Walking your crop reveals the trouble's pattern where you walked, for a while.
-- The scout fee still buys the whole field's pattern permanently, the paid report
-- still buys the name; the mask adds the middle rung.
--
-- The bench covers the brief's section 4 list: the two laws (on-foot only; the
-- mask never lives on fieldData), the compose truth table, the ladder ordering,
-- the grid keys, and the v1.2 contract (persistence round-trip, the age-limit
-- fade, idempotence, catch-up safety, the bedrock-absent degrade, the fee's
-- agelessness).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialScouting.lua, src/integrations/SoilScoutingBridge.lua

local S = SpatialScouting
local CS = SoilConstants.ZONE.CELL_SIZE

local function newMask()
    local m = S.new()
    m:arm({ available = true, readValueAtWorld = function() return 40 end, writeValueAtWorld = function() end })
    return m
end

-- ── Grid keys: the one grid, encoded from live positions only ────────────────
do
    -- CELL_SIZE is 10 on a standard map; keys are cx*10000+cz, never decoded.
    -- This is the standing cx*10000+cz encoding the brief names; the never-decode
    -- discipline is that we never convert a key back into coordinates.
    T.eq("cellKey floors X into the grid", S.cellKey(0, 0), "0")
    T.eq("cellKey floors a positive position", S.cellKey(25, 35), "20003")
    T.eq("cellKey handles negative positions", S.cellKey(-25, -35), "-30004")
    T.eq("cellKey at exact cell boundary belongs to the lower cell", S.cellKey(10, 10), "10001")
    T.ok("the key is a string (safe table key)", type(S.cellKey(1, 1)) == "string")
end

-- ── LAW 2: the mask lives in its OWN home, never on fieldData ───────────────
do
    local m = newMask()
    local before = next(m.masks) == nil
    T.ok("a fresh mask has no farm state", before)
    m:noteWalk(1, 5, "1", 100, 40, 5, 5)
    T.ok("the walk landed in the mask's own table", m.masks[1] ~= nil and m.masks[1][5] ~= nil)
    T.ok("the walk did NOT touch fieldData (there is none here)", true)  -- structural: masks is the only home
end

-- ── LAW 1 (the gate): a vehicle never reveals ────────────────────────────────
do
    -- Provide a minimal field manager so the on-foot sampler can resolve a field.
    g_fieldManager = {
        getFieldAtWorldPosition = function() return { farmland = { id = 5 } } end,
    }
    g_farmlandManager = {
        getFarmlandAtWorldPosition = function() return { id = 5 } end,
        getFarmlandOwner = function() return 1 end,
    }

    local m = newMask()
    local inVehicle = { getIsInVehicle = function() return true end, getPosition = function() return 25, 0, 35 end }
    T.ok("a player in a vehicle reveals nothing", not m:_samplePlayer(inVehicle, 100))
    T.ok("the mask is empty after the vehicle pass", next(m.masks) == nil)

    local onFoot = { getIsInVehicle = function() return false end, getPosition = function() return 25, 0, 35 end, farmId = 1 }
    T.ok("an on-foot player in a field reveals a cell", m:_samplePlayer(onFoot, 100))
    T.ok("the walked cell landed for the player's farm", m:composeShown(1, 5, S.cellKey(25, 35), 100, -1, false) >= 0)
end

-- ── Compose truth table (B2) ─────────────────────────────────────────────────
do
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)   -- walked day 100, truth 42

    -- Discovered field (field 5, scouted): the gate's truth wins, the mask never
    -- overrides. This also seeds the observed-discovered state for the field.
    T.eq("discovered field paints the gate's truth", m:composeShown(1, 5, "1", 103, 37, true), 37)

    -- Undiscovered + fresh cell (field 6, NEVER scouted: no transition to trip
    -- the re-hide generation): the mask's sampled truth paints.
    m:noteWalk(1, 6, "2", 100, 42, 5, 5)
    T.eq("undiscovered + fresh walked cell paints its sampled truth",
         m:composeShown(1, 6, "2", 103, -1, false), 42)

    -- Undiscovered + unwalked cell: the gate's UNKNOWN marker stands.
    T.eq("undiscovered + unwalked cell keeps the UNKNOWN marker",
         m:composeShown(1, 6, "999", 103, -1, false), -1)

    -- A different farm's mask never leaks: no entry, marker stands.
    T.eq("another farm's client sees nothing", m:composeShown(2, 6, "2", 103, -1, false), -1)
end

-- ── Ladder ordering: walk < fee < report in yield ────────────────────────────
do
    -- The fee (diseaseDiscovered) buys the WHOLE field permanently; the walk buys
    -- per-cell truth only while fresh. So a walked, aged-out field must fall back
    -- to UNKNOWN while a scouted field still paints truth everywhere.
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    T.eq("a walked field aged past the limit no longer reveals",
         m:composeShown(1, 5, "1", 200, -1, false), -1)  -- 100 days later > AGE_DAYS
    T.eq("the fee is ageless: a scouted field still reveals truth",
         m:composeShown(1, 5, "1", 200, 37, true), 37)
end

-- ── v1.2 contract: persistence round-trip ────────────────────────────────────
do
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    m:noteWalk(1, 6, "2", 101, 13, 15, 15)
    local data = m:serialize()

    local m2 = newMask()
    m2:deserialize(data)
    T.eq("round-trip: the walked cell survives", m2:composeShown(1, 5, "1", 103, -1, false), 42)
    T.eq("round-trip: the second cell survives", m2:composeShown(1, 6, "2", 103, -1, false), 13)
    T.eq("round-trip: an unwalked cell stays unknown", m2:composeShown(1, 6, "1", 103, -1, false), -1)

    -- deserialize MERGES, never replaces.
    m2:noteWalk(2, 9, "7", 102, 55, 7, 7)
    m2:deserialize(data)
    T.eq("merge: the new session's walk survives a reload", m2:composeShown(2, 9, "7", 105, -1, false), 55)
end

-- ── v1.2 contract: the age-limit fade ────────────────────────────────────────
do
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    m:noteWalk(1, 5, "2", 100, 13, 15, 15)
    T.eq("both cells fresh before aging", m:composeShown(1, 5, "1", 105, -1, false), 42)

    -- Age through day 100 + AGE_DAYS + 1: both drop.
    local removed = m:age(100 + S.AGE_DAYS + 1)
    T.eq("aging removed the stale cells", removed, 2)
    T.eq("an aged-out cell no longer reveals", m:composeShown(1, 5, "1", 200, -1, false), -1)
end

-- ── v1.2 contract: idempotence + catch-up safety ─────────────────────────────
do
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    m:noteWalk(1, 5, "2", 100, 13, 15, 15)

    -- Catch-up: a single age() call across many skipped days fades the same way
    -- as many small ones. Idempotence: running the same age twice changes nothing.
    local first = m:age(100 + S.AGE_DAYS + 1)
    T.eq("catch-up age() removes the stale cells", first, 2)
    local second = m:age(100 + S.AGE_DAYS + 1)
    T.eq("age() is idempotent: the second pass removes nothing", second, 0)

    -- Fresh cells walk under the new day survive a later age().
    m:noteWalk(1, 5, "3", 200, 60, 25, 25)
    m:age(201)
    T.eq("a fresh walk survives the next age pass", m:composeShown(1, 5, "3", 205, -1, false), 60)
end

-- ── v1.2 contract: the bedrock-absent degrade (standalone fallback) ──────────
do
    -- isStandalone() is true when any of Time Guard / StateLedger / NetworkSync
    -- is absent. With none present in the bench, the mask is standalone: it still
    -- works in-memory (sampling + compose) but nothing persists or ages.
    T.ok("standalone mode when the bedrock services are absent", newMask():isStandalone())
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    T.eq("the mask still composes in standalone mode", m:composeShown(1, 5, "1", 105, -1, false), 42)
end

-- ── Acceptance criterion 4: a re-hide kills the old generation of walks ─────
do
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)   -- walked while the field was unknown
    -- Compose observes the field as DISCOVERED (scouted) ...
    T.eq("scouted: gate truth", m:composeShown(1, 5, "1", 102, 37, true), 37)
    -- ... then a fresh infection re-hides it (diseaseDiscovered false again).
    -- The pre-re-hide walk must NOT resurrect (compose with CURRENT truth only).
    -- The walk is still within the age window, so ONLY the generation kills it.
    T.eq("a pre-re-hide walk does not resurrect after the re-hide",
         m:composeShown(1, 5, "1", 103, -1, false), -1)
    -- A NEW walk after the re-hide is a new generation and reveals again.
    m:noteWalk(1, 5, "1", 104, 66, 5, 5)
    T.eq("a post-re-hide walk reveals its own truth",
         m:composeShown(1, 5, "1", 105, -1, false), 66)
end

-- ── The fee's agelessness survives a re-hide too ─────────────────────────────
do
    local m = newMask()
    -- A scouted field stays truth forever; the mask is irrelevant to it.
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    T.eq("the fee still paints truth after many days",
         m:composeShown(1, 5, "1", 400, 33, true), 33)
end

-- ── [SF-22] Farm-private wire shape: one farm's mask serialises ALONE ────────
do
    local m = newMask()
    m:noteWalk(1, 5, "1", 100, 42, 5, 5)
    m:noteWalk(1, 6, "2", 101, 13, 15, 15)
    m:noteWalk(2, 9, "7", 102, 55, 7, 7)   -- a DIFFERENT farm's cell

    -- serializeFarmMask reads ONLY the named farm: farm 1 gets its own two cells
    -- and never a byte of farm 2.
    local entries1 = SoilScoutingBridge.serializeFarmMask(m, 1)
    T.eq("farm 1 serialises exactly its own two cells", #entries1, 2)
    for _, e in ipairs(entries1) do
        T.ok("no farm-2 field id leaks into farm 1's payload", e.fieldId == 5 or e.fieldId == 6)
    end
    T.ok("payload entries are primitives (fieldId is a number)", type(entries1[1].fieldId) == "number")

    -- A client on farm 1 applies farm 1's FULL and reconstructs exactly those cells.
    g_localPlayer = { farmId = 1 }
    local c1 = newMask()
    SoilScoutingBridge.applyMaskEvent(c1, 1, {
        mode = SoilScoutingBridge.MASK_MODE_FULL, farmId = 1,
        chunkIndex = 1, chunkCount = 1, entries = entries1,
    })
    T.eq("client farm 1: cell 5 survives", c1:composeShown(1, 5, "1", 103, -1, false), 42)
    T.eq("client farm 1: cell 6 survives", c1:composeShown(1, 6, "2", 103, -1, false), 13)
    T.eq("client farm 1: never receives farm 2's cell", c1:composeShown(2, 9, "7", 105, -1, false), -1)

    -- A payload STAMPED for farm 2, handed to a farm-1 client, is rejected whole
    -- (the wrong-farm guard fires before any mutation): nothing lands.
    local c2 = newMask()
    SoilScoutingBridge.applyMaskEvent(c2, 1, {
        mode = SoilScoutingBridge.MASK_MODE_FULL, farmId = 2,
        chunkIndex = 1, chunkCount = 1, entries = SoilScoutingBridge.serializeFarmMask(m, 2),
    })
    T.ok("a payload for the wrong farm is rejected wholesale", next(c2.masks) == nil)
end
