-- kneel_sf37_test.lua - THE KNEEL (SF-37)
--
-- The active, precise reveal verb. Kneel down (the shipped Shift+K scout action)
-- and the exact spot you stand on enters knowledge: ONE cell written onto the
-- walked mask, server-authoritative, with the same LAW 3 entry shape a walk fills
-- passively. THE KNOWLEDGE SPLIT: only the disease-knowledge cell is written;
-- soil facts are the player's own ground and need no reveal.
--
-- The bench pins: the reveal write lands on the mask (cell grain), LAW 4 (farm
-- from the requesting player's record via the connection, never from the wire),
-- the mask does not know which verb wrote it, and the kneel path is additive to
-- the field-level scout (which is not touched here - that path is in the manager).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialScouting.lua, src/integrations/SoilScoutingBridge.lua

local S = SpatialScouting

local function newMask()
    local m = S.new()
    m:arm({ available = true, readValueAtWorld = function() return 40 end, writeValueAtWorld = function() end })
    return m
end

-- ── The reveal write lands on the walked mask ───────────────────────────────
do
    g_server = {}   -- server side
    g_fieldManager = {
        getFieldAtWorldPosition = function() return { farmland = { id = 5 } } end,
    }
    g_farmlandManager = {
        getFarmlandAtWorldPosition = function() return { id = 5 } end,
    }
    g_localPlayer = { farmId = 1 }

    local m = newMask()
    local written = m:revealCellAt(nil, 25, 35, 100)
    T.ok("the kneel writes a cell onto the walked mask", written)
    local key = S.cellKey(25, 35)
    T.ok("the cell is recorded", m:maskEntry(1, 5, key) ~= nil)
    T.ok("the cell reads as known for the farmer", m:composeShown(1, 5, key, 100, -1, false) >= 0)

    -- The mask does not know which verb wrote it: a knelt cell ages like a walked one.
    local aged = m:age(100 + S.AGE_DAYS + 1)
    T.eq("a knelt cell fades like a walked cell", aged, 1)
    g_server = nil
end

-- ── LAW 4: farm from the connection's player record, never the wire ─────────
do
    g_server = {}
    g_fieldManager = {
        getFieldAtWorldPosition = function() return { farmland = { id = 7 } } end,
    }
    g_farmlandManager = {
        getFarmlandAtWorldPosition = function() return { id = 7 } end,
    }
    -- The requesting player's record carries farm 3.
    g_currentMission.playerSystem = {
        getPlayerByConnection = function() return { farmId = 3 } end,
    }
    g_localPlayer = { farmId = 1 }   -- the host's own farm; must NOT win

    local m = newMask()
    m:revealCellAt({}, 10, 10, 100)   -- a fake connection
    T.ok("the cell landed under the REQUESTING player's farm, not the host's",
         m:maskEntry(3, 7, S.cellKey(10, 10)) ~= nil)
    T.ok("nothing landed under the host's farm",
         m:maskEntry(1, 7, S.cellKey(10, 10)) == nil)
    T.eq("a different farm's client sees nothing",
         m:composeShown(1, 7, S.cellKey(10, 10), 100, -1, false), -1)

    g_currentMission.playerSystem = nil
    g_server = nil
end

-- ── Not on a field: nothing is written ──────────────────────────────────────
do
    g_server = {}
    g_fieldManager = {
        getFieldAtWorldPosition = function() return nil end,
    }
    g_farmlandManager = {
        getFarmlandAtWorldPosition = function() return nil end,
    }
    g_localPlayer = { farmId = 1 }

    local m = newMask()
    local written = m:revealCellAt(nil, 1000, 1000, 100)
    T.ok("off-field kneel writes nothing", not written)
    T.ok("the mask stays empty", next(m.masks) == nil)
    g_server = nil
end

-- ── Client-side (no server): the kneel is a no-op locally (request only) ────
do
    g_server = nil
    g_localPlayer = { farmId = 1 }
    local m = newMask()
    local written = m:revealCellAt(nil, 25, 35, 100)
    T.ok("a client never writes locally", not written)
end

-- ── The kneel write marks the mask dirty for NetworkSync ────────────────────
do
    g_server = {}
    g_fieldManager = {
        getFieldAtWorldPosition = function() return { farmland = { id = 5 } } end,
    }
    g_farmlandManager = {
        getFarmlandAtWorldPosition = function() return { id = 5 } end,
    }
    g_localPlayer = { farmId = 1 }
    local dirty = false
    local saved = SoilScoutingBridge.markDirty
    SoilScoutingBridge.markDirty = function() dirty = true end

    local m = newMask()
    m:revealCellAt(nil, 25, 35, 100)
    T.ok("the kneel flags the NetworkSync module dirty", dirty)

    SoilScoutingBridge.markDirty = saved
    g_server = nil
end
