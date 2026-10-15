-- SF-1128-cd15_store_walk_entry_test.lua
--
-- #1128: CD-15's Store:orderedCells() allocated a NEW table for every cell in the store.
-- Three production paths called it: CD15Admission.discover on EVERY update, CD15Model:update's
-- SETTLE once a day, and CD15Day.snapshotSources (SPREAD) once a day. Discovery admits a row
-- per 2 m cell of living crop, so the store reaches hundreds of thousands of rows within a
-- minute; each of those calls then allocated hundreds of megabytes (a player's log: Lua memory
-- 443 MB to 1855 MB in one frame). The fix adds CD15Grid.newWalk/walkNext/walkDone, a walker
-- that visits the store in orderedCells' order without allocating per cell (the tile list fixed
-- at walk start, a tile's keys copied on entry); SETTLE and snapshotSources walk; discover walks
-- the rows (d.rowWalk, made when the cursor first reaches them in a pass, reset at pass end and
-- in stateOf's passStart; skips ahead to the saved discoveryCursor after a load).
-- Store:orderedCells() itself stays (this bar and CD15-1a/1b/1c use it as an independent,
-- change-free oracle for ORDER); production stops calling it.
--
-- THE ENTRY-POINT BAR is SoilFertilitySystem:update (calls cd15:update every frame, under
-- pcall) and SoilFertilitySystem:onEnvironmentUpdate's new-day branch (calls cd15:onDayChanged,
-- under pcall). The CD-15 modules load the way CD15-1a's bench loads them (SF-995's engine
-- model, the real value maps, the real daily settlement and update), with CD15Admission.lua
-- added so discovery runs through the same entry. No cell is allocated by a production writer
-- before step 2, so (exactly as CD15-1a/1b/1c do) the bench puts cells into the store directly;
-- a put/remove between ticks stands in for a future writer, never for the walk itself.
--
-- MODELLED (the engine is not available here): getDensityTypeIndexAtWorldPos and
-- getDensityStatesAtWorldPos read a bench CROP table keyed by the fine cell, inverting the same
-- cell-centre arithmetic CD15Grid.cellCentre uses; one fruit type (wheat) on a plane sized so
-- one native pixel is exactly one CD-15 cell (no sub- or super-pixel cases); g_fieldManager
-- returns hand-built rectangular fields whose corners, read with getWorldTranslation, sit
-- exactly on the chosen cell box's edges. A.PROFILES carries one bench profile where a row
-- needs discovery to actually examine cells (production ships none: CD15-1c's bar covers the
-- UNKNOWN_OCCURRENCE:NO_SUPPORTED_PROFILE gate; this bar turns discovery on to exercise the row
-- walk the fix added).
--
-- THE DEV CONTROL (E1). Running the whole file once with the worktree's fixed
-- src/disease/*.lua, and once with development's four blobs (git show 1d4b7139:<path>) swapped
-- in over them (restored byte for byte afterward, hash-checked), is how the control in this
-- bar's report was produced. E1's expected value is the literal development printed when run
-- that way, embedded below once captured, so a single file run checks fix-against-development
-- without a second copy of production code living in this file. N1, W1 and R1 do not need that:
-- N1 counts calls (any implementation), and W1/R1 check the walk's order against
-- Store:orderedCells(), an independent oracle the change does not touch.
--
-- Groups:
--   N  Store:orderedCells call counts: the defect (N1) and the settle-per-update bound (N2)
--   W  the walk's order (against a hand-built order and against orderedCells) and its contract
--      under mutation (a put/remove in the walked tile, a tile created after the walk started,
--      calling past the end)
--   E  equivalence over days against development's golden (E1), and SETTLE-to-SPREAD framing,
--      hand-derived from the work bound (E2)
--   R  restore part-way through the rows, checked against orderedCells (R1); a row removed
--      during the rows phase ends the pass cleanly (R2)
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/DiseaseSystem.lua, src/utils/SoilUtils.lua, src/utils/SoilContextInput.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/FieldSentry.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/disease/CD15Grid.lua, src/disease/CD15Day.lua, src/disease/CD15Model.lua, src/disease/CD15Admission.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end

local G, D, M, A = CD15Grid, CD15Day, CD15Model, CD15Admission

--- Runs fn; a raise fails the named row instead of killing the rest of the file.
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [raised: " .. tostring(err) .. "]", false) end
end

-- ── the engine surface beside SF-995's model (CD15-1a's bench pattern) ──────
local NATIVE_PLANE, NATIVE_SIZE = 7, 4096
local CROP_PLANE, CROP_SIZE = 9, 1024   -- 1024 so one native pixel == one CD-15 cell exactly
function getDensityMapSize(id)
    if id == NATIVE_PLANE then return NATIVE_SIZE end
    if id == CROP_PLANE then return CROP_SIZE end
    return nil
end
g_fruitTypeManager = g_fruitTypeManager or {}
function g_fruitTypeManager:getDefaultDataPlaneId() return NATIVE_PLANE end
delete = delete or function(_id) end   -- the engine's object delete (value maps teardown)

-- The bench's one crop: wheat, growing (state 1) or empty (state 0), on CROP_PLANE.
local WHEAT_DESC = {
    name = "wheat", terrainDataPlaneId = CROP_PLANE,
    getIsCut = function() return false end, getIsWithered = function() return false end,
    getIsGrowing = function(_self, growth) return growth == 1 end,
    getIsHarvestReady = function() return false end, getIsHarvestable = function() return false end,
    getIsPreparable = function() return false end,
    getGrowthStateByDensityState = function(_self, states) return states end,
}
function g_fruitTypeManager:getFruitTypes() return { WHEAT_DESC } end
function g_fruitTypeManager:getFruitTypeByDensityTypeIndex(_idx) return WHEAT_DESC end

local CROP = {}             -- "gx:gz" -> 1 (growing); absent/0 means empty
local GEOM = nil            -- the resolved geometry (set once per world())
local function cellKey(gx, gz) return gx .. ":" .. gz end
function getDensityTypeIndexAtWorldPos(_planeId, _x, _y, _z) return 1 end
function getDensityStatesAtWorldPos(planeId, x, _y, z)
    if planeId ~= CROP_PLANE or GEOM == nil then return 0 end
    local half = GEOM.terrainSize / 2
    local gx = math.floor((x + half) / GEOM.cellSize)
    local gz = math.floor((z + half) / GEOM.cellSize)
    return CROP[cellKey(gx, gz)] or 0
end

-- A hand-built rectangular field, read the way the engine reads one: polygon nodes resolved
-- with getWorldTranslation. Its corners sit exactly on the chosen cell box's edges.
local NODE_XZ, nodeSeq = {}, 0
function getWorldTranslation(node) local p = NODE_XZ[node] return p[1], 0, p[2] end
local function newNode(x, z) nodeSeq = nodeSeq + 1 NODE_XZ[nodeSeq] = { x, z } return nodeSeq end
local function fieldBox(id, gx0, gz0, w, h)
    local half = GEOM.terrainSize / 2
    local x0, z0 = -half + gx0 * GEOM.cellSize, -half + gz0 * GEOM.cellSize
    local x1, z1 = x0 + w * GEOM.cellSize, z0 + h * GEOM.cellSize
    local nodes = { newNode(x0, z0), newNode(x1, z0), newNode(x1, z1), newNode(x0, z1) }
    return { getId = function() return id end, getPolygonPoints = function() return nodes end }
end

local FIELDS = {}
g_fieldManager = g_fieldManager or {}
function g_fieldManager:getFields() return FIELDS end

-- ── the world (CD15-1a's bench pattern, extended for discovery) ────────────
local RAIN = { scale = 0 }
local W = { fields = {}, moisture = nil, grain = nil }
local SETTINGS = { enabled = true, diseasePressure = true, diseaseMoisture = 2, diseaseDifficulty = 2, cropRotation = true, tuningDiseaseGrowth = 3 }

--- Production's system on a fresh engine. opts: day, dpp, season, client, timeGuard, settings,
--- profile ({ id, maxReadsPerCell }, nil leaves discovery answering UNKNOWN_OCCURRENCE as
--- production ships it).
local function world(opts)
    opts = opts or {}
    INFO, WARN = {}, {}
    g_server = (not opts.client) and {} or nil
    g_timeGuard = nil
    W.env = { currentMonotonicDay = opts.day, currentDay = 1, daysPerPeriod = opts.dpp or 3, currentSeason = opts.season or 1,
              weather = { getRainFallScale = function() return RAIN.scale end } }
    g_currentMission = { environment = W.env, missionInfo = {}, timeGuard = opts.timeGuard,
        cropStressManager = { getMoisture = function(_, _fid, _x, _z) return W.moisture, W.grain, 1 end } }
    local settings = {}
    for k, v in pairs(SETTINGS) do settings[k] = v end
    for k, v in pairs(opts.settings or {}) do settings[k] = v end
    g_SoilFertilityManager = { settings = settings }
    local sys = SoilFertilitySystem.new(settings)
    g_SoilFertilityManager.soilSystem = sys
    sys.valueMaps:initialize(nil)
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, z) return W.fieldAt ~= nil and W.fieldAt(x, z) or 1 end
    FieldSentry_Core.FieldState = {}
    CROP, FIELDS, NODE_XZ, nodeSeq = {}, {}, {}, 0
    A.PROFILES = opts.profile and { opts.profile } or {}
    A.stats.reads = 0
    GEOM = CD15Grid.resolveGeometry(sys.valueMaps, NATIVE_SIZE)
    W.sys = sys
    return sys, sys.cd15
end
local function newDay(sys, monoDay)
    W.env.currentMonotonicDay = monoDay
    W.env.currentDay = (W.env.currentDay or 0) + 1
    sys:onEnvironmentUpdate(W.env, 16)
end
local function tick(sys, n) for _ = 1, (n or 1) do sys:update(16) end end
--- Bind the grid through a first (empty) day, as CD15-1a's bound() does.
local function bound(opts)
    local sys, m = world(opts)
    newDay(sys, (opts and opts.day) or 100)
    tick(sys)
    return sys, m
end
local function cell(m, fields)
    local c = G.baselineCell(m.geometry.fingerprint)
    for k, v in pairs(fields or {}) do c[k] = v end
    return c
end
local function put(m, gx, gz, fields)
    local ok, why = m.store:put(gx, gz, cell(m, fields))
    if not ok then error("put " .. tostring(why)) end
    return m.store:get(gx, gz)
end

local WHEAT = SoilDiseaseSystem.cropDiseases("wheat")
local X, Y = WHEAT[1], WHEAT[2]

--- Tick sys until pred(m) holds or the guard trips (a stuck test fails loudly, never hangs).
local function tickUntil(sys, m, pred, maxTicks)
    local n = 0
    while not pred(m) and n < maxTicks do
        tick(sys)
        n = n + 1
    end
    return n < maxTicks
end

-- ══════════════════════════════════════════════════════════════════════════
-- N. Store:orderedCells CALL COUNTS
-- ══════════════════════════════════════════════════════════════════════════
check("N1/N2", function()
    local sys, m = bound({ day = 300, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    FIELDS = {}   -- no field candidates: every discovery candidate is a store row

    local ROWS = 5200
    for i = 0, ROWS - 1 do
        local gx, gz = i % 100, math.floor(i / 100)
        put(m, gx, gz, { cropName = (i % 7 == 0) and "wheat" or nil })
    end
    T.ok("N1 [setup] the store really holds >= 5,000 rows before the run", m.store.count >= 5000, tostring(m.store.count))

    local storeMeta = getmetatable(m.store).__index
    local realOrdered = storeMeta.orderedCells
    local calls = 0
    storeMeta.orderedCells = function(self) calls = calls + 1 return realOrdered(self) end

    local realSettle = CD15Model.settleEntry
    local settleCalls, maxSettlePerUpdate = 0, 0
    CD15Model.settleEntry = function(self, e, input)
        settleCalls = settleCalls + 1
        return realSettle(self, e, input)
    end

    newDay(sys, 301)
    for _ = 1, 150 do
        settleCalls = 0
        sys:update(16)
        if settleCalls > maxSettlePerUpdate then maxSettlePerUpdate = settleCalls end
    end
    newDay(sys, 302)
    for _ = 1, 150 do
        settleCalls = 0
        sys:update(16)
        if settleCalls > maxSettlePerUpdate then maxSettlePerUpdate = settleCalls end
    end

    storeMeta.orderedCells = realOrdered
    CD15Model.settleEntry = realSettle

    local s = m:getStatus()
    T.eq("N1 production never copies the store: Store:orderedCells is called 0 times across 300 updates and two day changes, with discovery running and both days' SETTLE+SPREAD complete",
        calls .. "|" .. s.pendingDays, "0|0")
    T.ok("N2 SETTLE never settles more than 256 cells in one update", maxSettlePerUpdate <= 256,
        "max settleEntry calls seen in one update was " .. maxSettlePerUpdate)
end)

check("N1 control note", function()
    -- Documents, for the report, how many times development's own discover() calls
    -- orderedCells() under the SAME 300-update/2-day scenario (same store size, same profile).
    -- This block always runs (on fix or on dev); on fix it is informational only (N1 above is
    -- the real row); on dev it shows the defect's call count directly.
    local sys, m = bound({ day = 300, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    FIELDS = {}
    for i = 0, 5199 do
        local gx, gz = i % 100, math.floor(i / 100)
        put(m, gx, gz, {})
    end
    local storeMeta = getmetatable(m.store).__index
    local realOrdered = storeMeta.orderedCells
    local calls = 0
    storeMeta.orderedCells = function(self) calls = calls + 1 return realOrdered(self) end
    newDay(sys, 301)
    tick(sys, 150)
    newDay(sys, 302)
    tick(sys, 150)
    storeMeta.orderedCells = realOrdered
    print("##CD15_ORDEREDCELLS_CALLS " .. calls)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- W. THE WALK'S ORDER AND ITS CONTRACT
-- ══════════════════════════════════════════════════════════════════════════
check("W1", function()
    local sys, m = bound({ day = 400 })
    FIELDS = {}
    -- A small store spanning three tiles (tile = 32 cells), inserted out of order.
    local cells = {
        { gx = 31, gz = 31 }, { gx = 40, gz = 0 }, { gx = 1, gz = 0 },
        { gx = 0, gz = 40 }, { gx = 33, gz = 5 }, { gx = 5, gz = 2 }, { gx = 10, gz = 32 },
    }
    for _, c in ipairs(cells) do put(m, c.gx, c.gz, {}) end

    local order = {}
    local realSettle = CD15Model.settleEntry
    CD15Model.settleEntry = function(self, e, input)
        order[#order + 1] = e.gx .. ":" .. e.gz
        return realSettle(self, e, input)
    end
    newDay(sys, 401)
    tick(sys)
    CD15Model.settleEntry = realSettle

    local expect = { "1:0", "5:2", "31:31", "40:0", "33:5", "10:32", "0:40" }
    T.eq("W1 a hand-built small store spanning three tiles settles in orderedCells' order (tz then tx, keys ascending)",
        table.concat(order, ","), table.concat(expect, ","))
end)

check("W1 random", function()
    local sys, m = bound({ day = 410 })
    FIELDS = {}
    math.randomseed(112800)
    local N = 3200
    local idx = {}
    for i = 0, N - 1 do idx[i + 1] = i end
    for i = N, 2, -1 do
        local j = math.random(i)
        idx[i], idx[j] = idx[j], idx[i]
    end
    for _, i in ipairs(idx) do
        local gx, gz = i % 300, math.floor(i / 300)
        put(m, gx, gz, {})
    end
    T.ok("W1 random [setup] >= 3,000 cells across many tiles", m.store.count >= 3000, tostring(m.store.count))

    local order = {}
    local realSettle = CD15Model.settleEntry
    CD15Model.settleEntry = function(self, e, input)
        order[#order + 1] = e.gx .. ":" .. e.gz
        return realSettle(self, e, input)
    end
    newDay(sys, 411)
    tick(sys, 20)
    CD15Model.settleEntry = realSettle

    local oc = m.store:orderedCells()
    local expect = {}
    for i, e in ipairs(oc) do expect[i] = e.gx .. ":" .. e.gz end
    T.eq("W1 a random store of >= 3,000 cells across many tiles settles in exactly Store:orderedCells' order (count and sequence)",
        #order .. "|" .. table.concat(order, ","), #expect .. "|" .. table.concat(expect, ","))
end)

check("W2", function()
    local sys, m = bound({ day = 420 })
    FIELDS = {}
    -- Tile A (tx=0,tz=0): 500 of its 1024 keys. Tile B (tx=1,tz=0): 2 keys.
    for key = 0, 499 do
        local gx, gz = key % 32, math.floor(key / 32)
        put(m, gx, gz, {})
    end
    put(m, 32, 0, {})   -- tile B key 0
    put(m, 33, 0, {})   -- tile B key 1
    T.eq("W2 [setup] 502 cells across two tiles before the walk starts", m.store.count, 502)

    newDay(sys, 421)
    tick(sys)   -- first 256 of tile A's frozen keys (0..255) settle this update

    -- A put in the tile being walked, at a key the tile never had before (1000, outside both
    -- the walked 0..255 range and the frozen 0..499 snapshot): must not be visited this pass.
    local gxNew, gzNew = 1000 % 32, math.floor(1000 / 32)
    local newCell = put(m, gxNew, gzNew, {})
    -- A removed cell still pending in the walk's copied keys (key 310, unwalked: >= 256).
    local removedGx, removedGz = 310 % 32, math.floor(310 / 32)
    local removedOk = m.store:remove(removedGx, removedGz)
    -- A cell in a brand-new tile (tx=5,tz=0), created after the walk started.
    local newTileGx, newTileGz = 160, 0
    put(m, newTileGx, newTileGz, {})

    tick(sys, 4)   -- enough updates to finish tile A (minus the removal) and tile B

    local s = m:getStatus()
    T.ok("W2 [setup] the removal landed", removedOk == true, tostring(removedOk))
    T.eq("W2 the SETTLE phase for this day finished (no error from the removed slot)", s.pendingDays, 0)
    T.eq("W2 a put into the walked tile at an unwalked key is not visited this pass (lastSettledDay unset)",
        tostring(newCell.lastSettledDay), "nil")
    T.eq("W2 a cell put into a tile created after the walk started is not visited (lastSettledDay unset)",
        tostring(m.store:get(newTileGx, newTileGz).lastSettledDay), "nil")
end)

check("W2 walk contract", function()
    -- A direct check of newWalk/walkDone/walkNext's own post-end contract: production relies
    -- on walkDone's idempotency (CD15Model:update calls it once to stop the inner loop and once
    -- more right after to decide the phase change), so this models that same guarantee directly.
    local store = G.newStore()
    local ok1 = store:put(0, 0, G.baselineCell("fp"))
    local ok2 = store:put(1, 0, G.baselineCell("fp"))
    T.ok("W2 [setup] two cells", ok1 and ok2, tostring(ok1) .. "/" .. tostring(ok2))
    local walk = G.newWalk(store)
    local seen = {}
    while true do
        local gx, gz = G.walkNext(walk)
        if gx == nil then break end
        seen[#seen + 1] = gx .. ":" .. gz
    end
    T.eq("W2 the walk visited both cells", table.concat(seen, ","), "0:0,1:0")
    T.ok("W2 walkDone keeps returning true past the end", G.walkDone(walk) and G.walkDone(walk), "false")
    T.ok("W2 walkNext keeps returning nil past the end", G.walkNext(walk) == nil and G.walkNext(walk) == nil, "false")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. EQUIVALENCE AND FRAMING
-- ══════════════════════════════════════════════════════════════════════════
-- E1's golden: development's own printed "##CD15_E1_GOLDEN_BEGIN/END" block, captured by
-- running this file once with development's four blobs swapped in (restored byte for byte,
-- hash-checked afterward) and pasted in literally. See the file header's "THE DEV CONTROL".
local GOLDEN_E1 = [=[
D1|settled=36|spreadPairs=4|examined=48|living=12|unknown=0|admitted=12|cursor=0||5:4{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=4.723333333,protection={},resistance={AZOLE=0.1894536474},sourceRevision=2};4:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=4.723333333,protection={},resistance={AZOLE=0.1894536474},sourceRevision=2};5:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=50.85333333,protection={},resistance={AZOLE=0.1894536474},sourceRevision=1};6:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=4.723333333,protection={},resistance={AZOLE=0.1894536474},sourceRevision=2};5:6{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=4.723333333,protection={},resistance={AZOLE=0.1894536474},sourceRevision=2};10:10{cropHistory={},cropName=wheat,cropOccurrence=occ:1,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};11:10{cropHistory={},cropName=wheat,cropOccurrence=occ:2,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};12:10{cropHistory={},cropName=wheat,cropOccurrence=occ:3,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};13:10{cropHistory={},cropName=wheat,cropOccurrence=occ:4,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};10:11{cropHistory={},cropName=wheat,cropOccurrence=occ:5,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};11:11{cropHistory={},cropName=wheat,cropOccurrence=occ:6,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};12:11{cropHistory={},cropName=wheat,cropOccurrence=occ:7,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};13:11{cropHistory={},cropName=wheat,cropOccurrence=occ:8,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};10:12{cropHistory={},cropName=wheat,cropOccurrence=occ:9,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};11:12{cropHistory={},cropName=wheat,cropOccurrence=occ:10,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};12:12{cropHistory={},cropName=wheat,cropOccurrence=occ:11,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};13:12{cropHistory={},cropName=wheat,cropOccurrence=occ:12,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0,protection={},resistance={},sourceRevision=0};20:20{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};50:2{cropHistory={},cropName=wheat,discovered=false,diseaseName=fhb,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=30,protection={fhb=99999},resistance={},sourceRevision=1};25:35{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};31:39{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};23:57{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};29:61{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};44:36{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};63:37{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};50:40{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};37:43{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};42:58{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};61:59{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};48:62{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};76:34{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};82:38{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};69:41{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};88:42{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};80:60{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};67:63{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};27:83{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};35:65{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};54:66{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};59:81{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};46:84{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};33:87{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};52:88{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};86:64{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};78:82{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};65:85{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1};84:86{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.7233333333,protection={},resistance={},sourceRevision=1};71:89{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=801,pressure=0.6333333333,protection={},resistance={},sourceRevision=1}
--DAY--
D2|settled=84|spreadPairs=12|examined=108|living=36|unknown=0|admitted=12|cursor=0||5:4{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=9.446666667,protection={},resistance={AZOLE=0.1794634226},sourceRevision=4};4:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=9.446666667,protection={},resistance={AZOLE=0.1794634226},sourceRevision=4};5:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=67.70666667,protection={},resistance={AZOLE=0.1794634226},sourceRevision=6};6:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=9.446666667,protection={},resistance={AZOLE=0.1794634226},sourceRevision=4};5:6{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=9.446666667,protection={},resistance={AZOLE=0.1794634226},sourceRevision=4};10:10{cropHistory={},cropName=wheat,cropOccurrence=occ:1,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};11:10{cropHistory={},cropName=wheat,cropOccurrence=occ:2,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};12:10{cropHistory={},cropName=wheat,cropOccurrence=occ:3,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};13:10{cropHistory={},cropName=wheat,cropOccurrence=occ:4,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};10:11{cropHistory={},cropName=wheat,cropOccurrence=occ:5,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};11:11{cropHistory={},cropName=wheat,cropOccurrence=occ:6,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};12:11{cropHistory={},cropName=wheat,cropOccurrence=occ:7,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};13:11{cropHistory={},cropName=wheat,cropOccurrence=occ:8,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};10:12{cropHistory={},cropName=wheat,cropOccurrence=occ:9,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};11:12{cropHistory={},cropName=wheat,cropOccurrence=occ:10,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};12:12{cropHistory={},cropName=wheat,cropOccurrence=occ:11,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};13:12{cropHistory={},cropName=wheat,cropOccurrence=occ:12,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=0.7233333333,protection={},resistance={},sourceRevision=1};20:20{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};50:2{cropHistory={},cropName=wheat,discovered=false,diseaseName=fhb,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=30,protection={fhb=99999},resistance={},sourceRevision=2};25:35{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};31:39{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};23:57{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};29:61{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};44:36{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};63:37{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};50:40{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};37:43{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};42:58{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};61:59{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};48:62{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};76:34{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};82:38{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};69:41{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};88:42{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};80:60{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};67:63{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};27:83{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};35:65{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};54:66{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};59:81{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};46:84{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};33:87{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};52:88{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};86:64{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};78:82{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};65:85{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2};84:86{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.446666667,protection={},resistance={},sourceRevision=2};71:89{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=802,pressure=1.266666667,protection={},resistance={},sourceRevision=2}
--DAY--
D3|settled=132|spreadPairs=20|examined=168|living=60|unknown=0|admitted=12|cursor=0||5:4{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=14.17,protection={},resistance={AZOLE=0.17},sourceRevision=6};4:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=14.17,protection={},resistance={AZOLE=0.17},sourceRevision=6};5:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=84.56,protection={},resistance={AZOLE=0.17},sourceRevision=11};6:5{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=14.17,protection={},resistance={AZOLE=0.17},sourceRevision=6};5:6{cropHistory={},cropName=wheat,discovered=false,diseaseName=septoria_tritici,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=14.17,protection={},resistance={AZOLE=0.17},sourceRevision=6};10:10{cropHistory={},cropName=wheat,cropOccurrence=occ:1,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};11:10{cropHistory={},cropName=wheat,cropOccurrence=occ:2,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};12:10{cropHistory={},cropName=wheat,cropOccurrence=occ:3,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};13:10{cropHistory={},cropName=wheat,cropOccurrence=occ:4,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};10:11{cropHistory={},cropName=wheat,cropOccurrence=occ:5,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};11:11{cropHistory={},cropName=wheat,cropOccurrence=occ:6,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};12:11{cropHistory={},cropName=wheat,cropOccurrence=occ:7,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};13:11{cropHistory={},cropName=wheat,cropOccurrence=occ:8,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};10:12{cropHistory={},cropName=wheat,cropOccurrence=occ:9,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};11:12{cropHistory={},cropName=wheat,cropOccurrence=occ:10,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};12:12{cropHistory={},cropName=wheat,cropOccurrence=occ:11,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};13:12{cropHistory={},cropName=wheat,cropOccurrence=occ:12,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,nativeCropWitness={basis=OBSERVED_CURRENT_CROP,day=801,empty=0,haulm=0,living=1,nonliving=0,pixels=1,planeSet=6cbd97,planes=1,profile=BENCH},pressure=1.446666667,protection={},resistance={},sourceRevision=2};20:20{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};50:2{cropHistory={},cropName=wheat,discovered=false,diseaseName=fhb,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=30,protection={fhb=99999},resistance={},sourceRevision=3};25:35{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};31:39{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};23:57{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};29:61{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};44:36{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};63:37{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};50:40{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};37:43{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};42:58{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};61:59{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};48:62{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};76:34{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};82:38{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};69:41{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};88:42{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};80:60{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};67:63{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};27:83{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};35:65{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};54:66{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};59:81{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};46:84{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};33:87{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};52:88{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};86:64{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};78:82{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};65:85{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3};84:86{cropHistory={},cropName=wheat,discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=2.17,protection={},resistance={},sourceRevision=3};71:89{cropHistory={},discovered=false,dryDayCount=0,geometryFingerprint=cd15Disease:1;terrain=64;fine=1024;native=4096;origin=CENTRED,lastSettledDay=803,pressure=1.9,protection={},resistance={},sourceRevision=3}
--SOURCES--
day801[5:5:septoria_tritici]
day802[5:4:septoria_tritici,4:5:septoria_tritici,5:5:septoria_tritici,6:5:septoria_tritici,5:6:septoria_tritici]
day803[5:4:septoria_tritici,4:5:septoria_tritici,5:5:septoria_tritici,6:5:septoria_tritici,5:6:septoria_tritici]]=]

check("E1", function()
    local sys, m = bound({ day = 800, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    RAIN.scale = 1
    FIELDS = { fieldBox(1, 10, 10, 4, 3) }
    for gz = 10, 12 do
        for gx = 10, 13 do
            CROP[cellKey(gx, gz)] = 1
        end
    end
    -- 30 baseline rows across three tiles (gx,gz both >= 20, clear of the field box and the
    -- hand-placed cells below).
    for i = 0, 29 do
        local gx, gz = 20 + (i * 17) % 70, 20 + (i * 23) % 70
        put(m, gx, gz, { cropName = (i % 2 == 0) and "wheat" or nil })
    end
    -- A disease source with living, compatible, unprotected neighbours (one hop, every
    -- direction).
    put(m, 5, 5, { cropName = "wheat", diseaseName = X, pressure = 50, resistance = { AZOLE = 0.2 } })
    put(m, 6, 5, { cropName = "wheat" })
    put(m, 4, 5, { cropName = "wheat" })
    put(m, 5, 6, { cropName = "wheat" })
    put(m, 5, 4, { cropName = "wheat" })
    -- A protected diseased cell: excluded from the sources list every day.
    put(m, 50, 2, { cropName = "wheat", diseaseName = Y, pressure = 30, protection = { [Y] = 99999 } })

    local sourcesLog = {}
    local realSnapshot = CD15Day.snapshotSources
    CD15Day.snapshotSources = function(store, day)
        local out = realSnapshot(store, day)
        local parts = {}
        for _, s in ipairs(out) do parts[#parts + 1] = s.gx .. ":" .. s.gz .. ":" .. s.diseaseName end
        sourcesLog[#sourcesLog + 1] = "day" .. day .. "[" .. table.concat(parts, ",") .. "]"
        return out
    end

    --- Every record, canonically (CD15-1b/1c's own pattern): each field and nested map sorted.
    local function canon(v)
        if type(v) ~= "table" then return type(v) == "number" and string.format("%.10g", v) or tostring(v) end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. canon(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local function dump()
        local out = {}
        for _, e in ipairs(m.store:orderedCells()) do out[#out + 1] = e.gx .. ":" .. e.gz .. canon(m.store:get(e.gx, e.gz)) end
        return table.concat(out, ";")
    end

    local snapshots = {}
    local day = 800
    for k = 1, 3 do
        day = day + 1
        newDay(sys, day)
        tickUntil(sys, m, function(mm) return mm.lastClosedDay == day end, 10)
        local s = m:getStatus()
        local adm = s.admission or {}
        snapshots[#snapshots + 1] = string.format(
            "D%d|settled=%d|spreadPairs=%d|examined=%s|living=%s|unknown=%s|admitted=%s|cursor=%s||%s",
            k, s.settled, s.spreadPairs, tostring(adm.examined), tostring(adm.living), tostring(adm.unknown),
            tostring(adm.admitted), tostring(adm.cursor), dump())
    end
    CD15Day.snapshotSources = realSnapshot

    local golden = table.concat(snapshots, "\n--DAY--\n") .. "\n--SOURCES--\n" .. table.concat(sourcesLog, "\n")
    print("##CD15_E1_GOLDEN_BEGIN")
    print(golden)
    print("##CD15_E1_GOLDEN_END")

    T.eq("E1 equivalence over 3 days: the same final store, the same stats, the same sources list order each day, and the same discovery counts and discoveryCursor, as development's own run",
        golden, GOLDEN_E1)
end)

check("E2 exact boundary", function()
    local sys, m = bound({ day = 700 })
    FIELDS = {}
    local ROWS = 512   -- exactly 2 * CD15Model.WORK_BOUND (256)
    for i = 0, ROWS - 1 do
        local gx, gz = i % 32, math.floor(i / 32)
        put(m, gx, gz, {})
    end
    newDay(sys, 701)
    tick(sys)
    T.eq("E2 tick 1 of 512 cells (budget 256): SETTLE has not finished",
        m.queue[1] and m.queue[1].phase, "SETTLE")
    tick(sys)
    T.eq("E2 tick 2: the budget hits 0 exactly on the 512th cell; SETTLE finishes and SPREAD starts (its sources snapshotted) in this SAME frame, but today (701) has not closed yet (SPREAD's own hop budget is 0 this frame; lastClosedDay is still the bind's own 700)",
        (m.queue[1] and m.queue[1].phase) .. "|" .. tostring(m.lastClosedDay), "SPREAD|700")
    tick(sys)
    T.eq("E2 tick 3: the day closes (0 sources, nothing to spread)", tostring(m.lastClosedDay), "701")
end)

check("E2 empty store", function()
    local sys, m = bound({ day = 710 })
    FIELDS = {}
    newDay(sys, 711)
    tick(sys)
    T.eq("E2 the empty-store case: SETTLE and SPREAD both finish within the SAME single update (0 cells leave the full budget free for SPREAD's own check in the same frame)",
        tostring(m.lastClosedDay) .. "|" .. #m.queue, "711|0")
end)

check("E3 pre-existing row in a field box", function()
    local sys, m = bound({ day = 900, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    FIELDS = { fieldBox(1, 10, 10, 4, 3) }   -- 4 wide by 3 high: gx 10..13, gz 10..12 (12 cells)
    for gz = 10, 12 do
        for gx = 10, 13 do
            CROP[cellKey(gx, gz)] = 1   -- all 12 cells living in CROP
        end
    end
    -- One pre-existing row INSIDE the box, with no cropName.
    put(m, 11, 11, {})
    -- K = 5 further rows outside the box, clear of it, and clear of CROP (so they are
    -- NOT_LIVING and are never admitted when re-examined as rows).
    local K = 5
    for i = 0, K - 1 do
        put(m, 30 + i, 30, {})
    end
    T.eq("E3 [setup] the store holds exactly K + 1 rows before the day", m.store.count, K + 1)

    newDay(sys, 901)
    tick(sys)   -- one update: SETTLE (K + 1 rows) + SPREAD (0 sources, no diseaseName set) +
                -- one whole discovery pass, all within the one 256 work bound.

    local s = m:getStatus()
    local adm = s.admission or {}
    -- Hand-derived from development's rule: the rows are the K + 1 that exist when the call
    -- starts, so a cell admitted as a new row in this call's field part is not a row in it.
    --   examined = 12 field candidates + (K + 1) rows = 12 + 6 = 18. (11, 11) is examined
    --   twice: once as a field candidate, once as a pre-existing row.
    --   The field part admits 11 new rows and admits (11, 11) onto its pre-existing crop-less
    --   row: 12 admissions. Only the 11 new rows go into `admitted`.
    --   The row walk, made after the field part, holds 17 rows (6 pre-existing + 11 new) and
    --   skips the 11 in `admitted`, leaving the 6 row slots this pass has (18 - 12 = 6): the
    --   cursor reaches 18 = total and resets to 0 in this same call.
    --   (11, 11)'s row-part examination finds its row already has a cropName, so admitted
    --   stays at 12.
    -- The three numbers below were derived by hand before the row was first run.
    T.eq("E3 one whole pass examines 12 field candidates plus the K + 1 = 6 pre-existing rows (18 total), with (11, 11) counted once in each part",
        tostring(adm.examined), "18")
    T.eq("E3 admitted = 12: the 11 brand-new rows plus (11, 11) admitted onto its pre-existing crop-less row, and no 13th admission for (11, 11)'s second, row-part examination",
        tostring(adm.admitted), "12")
    T.eq("E3 the pass completed inside this one discover call, so the cursor is back at 0",
        tostring(adm.cursor), "0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. RESTORE AND REMOVAL DURING THE ROWS PHASE
-- ══════════════════════════════════════════════════════════════════════════
check("R1", function()
    local sys, m = bound({ day = 600, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    FIELDS = {}
    local ROWS = 700
    for i = 0, ROWS - 1 do
        local gx, gz = i % 60, math.floor(i / 60)
        put(m, gx, gz, {})
    end
    newDay(sys, 601)
    local reached = tickUntil(sys, m, function(mm) return mm.discoveryCursor > 0 and mm.discoveryCursor < ROWS - 50 end, 50)
    T.ok("R1 [setup] reached a mid-pass discovery cursor to export from", reached, tostring(m.discoveryCursor))
    local cursorAtExport = m.discoveryCursor

    -- The expected rest-of-pass sequence: Store:orderedCells() is an independent, change-free
    -- oracle for order (development's own discover() indexed straight into it); fieldCells is 0
    -- here, so the ordinal is the array index directly.
    local ordered = m.store:orderedCells()
    local expected = {}
    for i = cursorAtExport + 1, #ordered do expected[#expected + 1] = ordered[i].gx .. ":" .. ordered[i].gz end

    -- Export a fresh store holding a copy of every row, the day work and the saved cursor;
    -- import into a brand-new model exactly the way CD15Save's decode restores one
    -- (M:importSaved), as CD15-1b's bench does.
    local freshStore = G.newStore()
    for _, e in ipairs(ordered) do
        local okP = freshStore:put(e.gx, e.gz, G.copyCell(m.store:get(e.gx, e.gz)))
        if not okP then error("export put failed") end
    end
    local payload = {
        store = freshStore, lastDay = m.lastDay, lastClosedDay = m.lastClosedDay,
        gaps = m.gaps, queue = m.queue, occurrenceSeq = m.occurrenceSeq, discoveryCursor = m.discoveryCursor,
    }

    local sys2, m2 = world({ day = 601, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    m2:importSaved(payload)
    T.eq("R1 [setup] the fresh model imported RESTORED with the saved cursor",
        tostring(m2.restoreState) .. "/" .. tostring(m2.discoveryCursor), "RESTORED/" .. cursorAtExport)

    local seen = {}
    local realWitness = A.witness
    A.witness = function(geom, planes, planeFingerprint, gx, gz, profile)
        seen[#seen + 1] = gx .. ":" .. gz
        return realWitness(geom, planes, planeFingerprint, gx, gz, profile)
    end
    tickUntil(sys2, m2, function(mm) return mm.discoveryCursor == 0 end, 50)
    A.witness = realWitness

    T.eq("R1 restored part-way through the rows, the cells examined in the rest of that pass equal Store:orderedCells' tail from the saved cursor",
        #seen .. "|" .. table.concat(seen, ","), #expected .. "|" .. table.concat(expected, ","))
end)

check("R2", function()
    local sys, m = bound({ day = 650, profile = { id = "BENCH", maxReadsPerCell = 4 } })
    FIELDS = {}
    local ROWS = 700
    for i = 0, ROWS - 1 do
        local gx, gz = i % 60, math.floor(i / 60)
        put(m, gx, gz, {})
    end
    newDay(sys, 651)
    local reached = tickUntil(sys, m, function(mm) return mm.discoveryCursor > 0 and mm.discoveryCursor < ROWS - 20 end, 50)
    T.ok("R2 [setup] reached a mid-pass discovery cursor before the removal", reached, tostring(m.discoveryCursor))

    -- A row not yet walked (the tail of the current order): remove it mid-pass.
    local ordered = m.store:orderedCells()
    local victim = ordered[#ordered]
    local removedOk = m.store:remove(victim.gx, victim.gz)
    T.ok("R2 [setup] the removal landed", removedOk, tostring(removedOk))

    local finished = tickUntil(sys, m, function(mm) return mm.discoveryCursor == 0 end, 50)
    T.ok("R2 [setup] the pass finished within the guard", finished, tostring(m.discoveryCursor))
    T.eq("R2 a row removed during the rows phase ends the pass cleanly: the cursor returns to 0 without error",
        m.discoveryCursor, 0)
    T.eq("R2 the pass's row walk is cleared, not left stale", tostring(m.discovery and m.discovery.rowWalk), "nil")
end)

T.summary()
