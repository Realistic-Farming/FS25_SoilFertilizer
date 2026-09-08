-- =========================================================
-- FS25 Soil & Fertilizer - RfPdaSoilMerge
-- =========================================================
-- BUILD 18:37 (George CLOSED DESIGN 18:25, Ash 18:37): Soil list rows follow
-- the helper / GPS field outline. Two farmlands that the map sells apart but
-- that the helper drives as one field (Montana 86 and 87, the Riverbend save 2
-- blocks) are one row on the Esc Soil panel and the tablet Soil overview,
-- with the combined hectares, area-weighted N P K pH OM and the worst
-- urgency. Nothing else changes: soilSystem.fieldData stays keyed by the
-- real farmland id, spraying paints the real farmland, value maps, the field
-- detail dialog and the rotation planner keep addressing single farmland ids.
-- Only LIST ROWS merge, and only for fields the local farm owns.
--
-- Outline source (George Q1): the same walk the helper and GPS steering use,
-- BoundaryDetectionTask.new(cx, cz) started at Field:getCenterOfFieldWorldPosition()
-- (Field.lua 91-93). It walks getDensityAtWorldPos(g_currentMission.terrainDetailId,
-- x, 0, z) ~= 0, field-ground pixels, crop-agnostic and meadow-inclusive. new()
-- returns nil when the centre is not on field ground; that farmland stays its
-- own row. update(dt, frameBudget) returns true while still walking and false
-- once finished (FieldCourseField.lua 191 drives it the same way); only then is
-- boundaryPositions read. Main boundary only, no island continuation.
--
-- Cost (George Q2): never on every Esc open. soilSystem.fieldBlocks caches one
-- record per farmland id; the walks run one field per frame from the main.lua
-- update hook (RfPdaSoilMerge.update), a few ms each, only for farmlands a list
-- build has asked for. Later opens read the cache. A farmland goes dirty on the
-- FieldManager plow / cultivate updates (appended read-only; the only updates
-- that change the field-ground extent) and the whole cache drops on a save load
-- (SoilFertilitySystem:loadFromXMLFile, appended). Never a FieldManager,
-- farmland, density-map or FieldUpdateTask write.
--
-- Member rule (BUILD 22:21, George CLOSED DESIGN 22:12): the field numbers whose
-- own CENTRE sits inside the walked outline. After a finished walk, every farmland
-- the local farm owns except the walked one is tested exactly once: its centre from
-- Field:getCenterOfFieldWorldPosition, rejected on the outline bounding box, and
-- otherwise ray cast with FieldCourseUtil.getIsPointInsideBoundary. Inside joins the
-- row; outside is decided, not retried. That is what keeps two neighbouring wheat
-- fields with two GPS outlines as two rows: their shared edge falls inside the other
-- one's box, but neither centre falls inside the other one's outline. Until BUILD
-- 22:21 this gridded the bounding box and admitted a parcel on its first field-ground
-- pixel inside the polygon, so one fence sliver glued two fields together.
-- The member set is written onto every member's record and those members leave
-- the walk queue; rows group by member-set equality, the lowest id leads.
-- Nearby-but-not-joined parcels stay separate. No crop gate. A finished loop
-- that does not enclose the field centre is an interior hole (tree, pole, pond)
-- that sat above the centre: the walk restarts just past it, the same rule
-- FieldCourseField applies to this task (FieldCourseField.lua 211-213).
-- =========================================================

RfPdaSoilMerge = RfPdaSoilMerge or {}

-- Seconds of walking handed to BoundaryDetectionTask:update per frame while a
-- walk is open. 3 ms keeps a 15000-point outline to a handful of frames.
RfPdaSoilMerge.FRAME_BUDGET_S = 0.003

local function soilSystem()
    local sfm = g_SoilFertilityManager
    if sfm == nil and type(getfenv) == "function" then
        local env0 = getfenv(0)
        if env0 ~= nil then
            sfm = env0.g_SoilFertilityManager
        end
    end
    if sfm == nil then
        return nil
    end
    return sfm.soilSystem
end

local function resolveFarmId()
    local farmId = nil
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        farmId = g_localPlayer.farmId
    end
    if (farmId == nil or farmId == 0) and g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        farmId = g_currentMission:getFarmId()
    end
    return farmId
end

local function isOwned(fieldId, farmId)
    if farmId == nil or farmId == 0 or g_farmlandManager == nil then
        return false
    end
    local ok, owner = pcall(g_farmlandManager.getFarmlandOwner, g_farmlandManager, fieldId)
    return ok and owner == farmId
end

-- The engine Field object for a farmland id (soil ids ARE farmland ids).
local function fieldObject(fieldId)
    if g_fieldManager == nil then
        return nil
    end
    if type(g_fieldManager.getFieldById) == "function" then
        local ok, f = pcall(g_fieldManager.getFieldById, g_fieldManager, fieldId)
        if ok and f ~= nil and f.farmland ~= nil and f.farmland.id == fieldId then
            return f
        end
    end
    local fields = g_fieldManager.fields
    if type(fields) == "table" then
        for _, f in pairs(fields) do
            if f ~= nil and f.farmland ~= nil and f.farmland.id == fieldId then
                return f
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------
-- Outline cache: soilSystem.fieldBlocks[farmlandId] = record
--   { members = {sorted owned farmland ids}, dirty }  a finished walk + sample
--   { none = true, dirty }                           centre not on field ground
-- The open walk lives in soilSystem._rfBlockWalk = { queue, queued, task, taskId, sample }.
-- ---------------------------------------------------------
local function fieldCenter(fieldId)
    local f = fieldObject(fieldId)
    if f == nil then
        return nil
    end
    if type(f.getCenterOfFieldWorldPosition) == "function" then
        local ok, x, z = pcall(f.getCenterOfFieldWorldPosition, f)
        if ok and x ~= nil and z ~= nil then
            return x, z
        end
    end
    if f.posX ~= nil and f.posZ ~= nil then
        return f.posX, f.posZ
    end
    return nil
end

-- Still here for the hole restart, which measures its step off the terrain detail grid. The
-- membership sample no longer touches it: BUILD 22:21 replaced the grid with a centre test.
local function terrainDetailResolution()
    local m = g_currentMission
    if m == nil or type(m.terrainSize) ~= "number" or type(m.terrainDetailMapSize) ~= "number"
        or m.terrainDetailMapSize <= 0 then
        return nil
    end
    return m.terrainSize / m.terrainDetailMapSize
end

--- Bounding box of a finished walk plus a closed copy of its positions for the
--- ray-cast point-in-polygon test (the walk stops within one pixel of its start;
--- the closing segment is added here, the task's own table is left alone).
local function outlineBounds(positions)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local closed = {}
    for i = 1, #positions do
        local p = positions[i]
        if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" then
            local x, z = p[1], p[2]
            if x < minX then minX = x end
            if x > maxX then maxX = x end
            if z < minZ then minZ = z end
            if z > maxZ then maxZ = z end
            closed[#closed + 1] = p
        end
    end
    if #closed < 3 then
        return nil
    end
    local first, last = closed[1], closed[#closed]
    if first[1] ~= last[1] or first[2] ~= last[2] then
        closed[#closed + 1] = { first[1], first[2] }
    end
    return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, boundary = closed }
end

--- Every farmland the local farm owns (the candidate set a sample can join) and its count.
local function ownedFarmlands()
    local owned, count = {}, 0
    local farmId = resolveFarmId()
    if farmId == nil or farmId == 0 or g_farmlandManager == nil then
        return owned, count
    end
    local lands = nil
    if type(g_farmlandManager.getFarmlands) == "function" then
        local ok, t = pcall(g_farmlandManager.getFarmlands, g_farmlandManager)
        if ok and type(t) == "table" then
            lands = t
        end
    end
    if lands == nil then
        lands = g_farmlandManager.farmlands
    end
    if type(lands) ~= "table" then
        return owned, count
    end
    for key, land in pairs(lands) do
        local id = tonumber(key)
        if id == nil and type(land) == "table" then
            id = tonumber(land.id)
        end
        if id ~= nil and owned[id] == nil and isOwned(id, farmId) then
            owned[id] = true
            count = count + 1
        end
    end
    return owned, count
end

--- Open the membership pass for a finished walk (BUILD 22:21, George CLOSED DESIGN 22:12).
--- The candidate set is every farmland this farm owns except the walked one, and each candidate
--- is tested exactly once at its own field centre. No grid, so no per-pixel density or farmland
--- read, and no throttle to tune: the pass is bounded by the number of parcels the farm owns.
--- The walked farmland is a member by construction and is never self-tested. Returns false only
--- when there is no outline to test against, which is the caller's "none" case.
local function startSample(w, fieldId, b)
    if b == nil then
        return false
    end
    local owned = ownedFarmlands()
    local cands = {}
    for id in pairs(owned) do
        if id ~= fieldId then
            cands[#cands + 1] = id
        end
    end
    -- Sorted so a pass over the same farm is the same pass twice, which matters when two walks
    -- are compared against each other during a rebuild.
    table.sort(cands)
    local s = {
        fieldId = fieldId,
        boundary = b.boundary,
        minX = b.minX,
        maxX = b.maxX,
        minZ = b.minZ,
        maxZ = b.maxZ,
        cands = cands,
        i = 0,
        members = {},
    }
    -- By construction, not by test: this outline was walked from this field's own centre.
    s.members[fieldId] = true
    w.sample = s
    return true
end

--- One candidate. Returns true when the pass is complete, which is when the candidate list is
--- exhausted. Each owned parcel is tested exactly once, at its own field centre: the bounding box
--- rejects most of them for the price of four comparisons, and only a centre inside the box pays
--- for the ray cast, which is O(boundary). Inside means this parcel is part of the same GPS
--- outline and joins the row. Outside is a decision, not a retry: two wheat fields side by side
--- that GPS still draws as two outlines stay two rows, however much shared fence line falls inside
--- the other one's bounding box. That is the whole point of the change.
local function sampleStep(s)
    if s.i >= #s.cands then
        return true
    end
    s.i = s.i + 1
    local fid = s.cands[s.i]
    if fid == nil or s.members[fid] then
        return false
    end
    local cx, cz = fieldCenter(fid)
    if cx == nil or cz == nil then
        -- No centre to test is not a member; it gets its own row through its own walk.
        return false
    end
    if cx < s.minX or cx > s.maxX or cz < s.minZ or cz > s.maxZ then
        return false
    end
    if FieldCourseUtil == nil or type(FieldCourseUtil.getIsPointInsideBoundary) ~= "function" then
        return true
    end
    if FieldCourseUtil.getIsPointInsideBoundary(cx, cz, s.boundary) == true then
        s.members[fid] = true
    end
    return false
end

--- Write the finished member set onto every member's record and drop those members
--- from the walk queue (a walk that found {19, 20} never walks 20 on its own).
local function finishSample(sys, w)
    local s = w.sample
    w.sample = nil
    local members = {}
    for id in pairs(s.members) do
        members[#members + 1] = id
    end
    table.sort(members)
    for _, id in ipairs(members) do
        local copy = {}
        for i = 1, #members do
            copy[i] = members[i]
        end
        sys.fieldBlocks[id] = { members = copy, dirty = false }
        if w.queued[id] then
            w.queued[id] = nil
            for i = #w.queue, 1, -1 do
                if w.queue[i] == id then
                    table.remove(w.queue, i)
                end
            end
        end
    end
    sys._rfMergeCache = nil
    sys._rfReadGroupsCache = nil
end

-- Hole restarts per field. FieldCourseField restarts without a cap; a small cap keeps
-- a pathological field from walking forever.
RfPdaSoilMerge.MAX_HOLE_RESTARTS = 8

--- True when the closed loop encloses (x, z): it is the outer boundary. False means the
--- walk looped an interior hole that sat above the centre. Unknown counts as enclosed.
local function loopEncloses(boundary, x, z)
    if FieldCourseUtil == nil or type(FieldCourseUtil.getIsPointInsideBoundary) ~= "function" then
        return true
    end
    local ok, inside = pcall(FieldCourseUtil.getIsPointInsideBoundary, x, z, boundary)
    if not ok then
        return true
    end
    return inside == true
end

--- A fresh walk just past the hole, the way FieldCourseField.lua 211-213 drives the
--- same task: start at (centre x, hole max z + one detail pixel). nil when that point is
--- not field ground or the task cannot say where the hole ends.
local function nextWalkPastHole(task, cx)
    local res = terrainDetailResolution()
    if res == nil or task == nil or type(task.getMaxZ) ~= "function"
        or BoundaryDetectionTask == nil or type(BoundaryDetectionTask.new) ~= "function" then
        return nil
    end
    local okZ, maxZ = pcall(task.getMaxZ, task)
    if not okZ or type(maxZ) ~= "number" or maxZ == -math.huge then
        return nil
    end
    local ok, t = pcall(BoundaryDetectionTask.new, cx, maxZ + res)
    if ok then
        return t
    end
    return nil
end

-- Record shape stamp. A hot reload keeps soilSystem.fieldBlocks, so records written by
-- an older build (bbox + count signatures, no members) would read as clean forever;
-- the first use after a shape change drops the whole cache instead.
-- 3 (BUILD 22:21): the member sets themselves changed meaning. Records written by the grid sample
-- can hold a neighbour admitted on one fence pixel, and they are structurally identical to a
-- centre-test record, so nothing else could tell them apart. The stamp is the only thing that can.
RfPdaSoilMerge.CACHE_SHAPE = 3

local function ensureShape(sys)
    if sys ~= nil and sys._rfBlockShape ~= RfPdaSoilMerge.CACHE_SHAPE then
        sys.fieldBlocks = nil
        sys._rfBlockWalk = nil
        sys._rfMergeCache = nil
        sys._rfReadGroupsCache = nil
        sys._rfBlockShape = RfPdaSoilMerge.CACHE_SHAPE
    end
end

--- A record that answers: a finished sample (members) or a centre off field ground (none).
local function isClean(rec)
    return rec ~= nil and not rec.dirty and (rec.none == true or type(rec.members) == "table")
end

local function walkState(sys)
    if sys._rfBlockWalk == nil then
        sys._rfBlockWalk = { queue = {}, queued = {}, task = nil, taskId = nil, sample = nil }
    end
    return sys._rfBlockWalk
end

--- The cached record for a farmland, or nil while its walk is still queued / open.
--- A dirty or missing record is queued here (lazy: only what a list build asks for).
local function requestOutline(sys, fieldId)
    if sys == nil or fieldId == nil then
        return nil
    end
    ensureShape(sys)
    if sys.fieldBlocks == nil then
        sys.fieldBlocks = {}
    end
    local rec = sys.fieldBlocks[fieldId]
    if isClean(rec) then
        return rec
    end
    local w = walkState(sys)
    if not w.queued[fieldId] and w.taskId ~= fieldId then
        w.queued[fieldId] = true
        w.queue[#w.queue + 1] = fieldId
    end
    return nil
end

--- Walk batch finished (George CLOSED DESIGN 22:55 item 7): when the Esc Realistic
--- Farming page is open on Soil, rebuild the Soil roster once so the merged rows show
--- without a re-open. No timer, no reloadData thrash; nothing when the page is closed
--- or another module is up.
function RfPdaSoilMerge.onWalksFinished()
    local menu = g_inGameMenu
    local page = menu ~= nil and menu.menuRealisticFarming or nil
    if page == nil or page.isOpen ~= true then
        return
    end
    local reg = g_currentMission ~= nil and g_currentMission.rfEscModules or nil
    local activeId = reg ~= nil and reg.activeModuleId or nil
    if activeId ~= nil and activeId ~= "soilFertilizer" then
        return
    end
    local panel = RfPdaSoilPanel
    if panel == nil or type(panel.rebuildFieldData) ~= "function" or type(panel.reloadFieldList) ~= "function" then
        return
    end
    pcall(panel.rebuildFieldData, page)
    pcall(panel.reloadFieldList, page)
end

--- Per-frame driver, called from the main.lua FSBaseMission.update hook. At most one
--- BoundaryDetectionTask is alive; a new one starts on the frame after the last one
--- finished (one field per frame), and each frame hands the open walk FRAME_BUDGET_S.
--- update(dt, frameBudget) returns true while still walking, false when finished; the
--- positions are read only then and the membership sample opens, which runs under the
--- same budget on the following frames. A nil task (centre off field ground) records
--- "none". When the queue drains (walking true -> false) the Soil roster rebuilds once.
---@param dt number
---@param sys table|nil SoilFertilitySystem (default: the live one)
function RfPdaSoilMerge.update(dt, sys)
    sys = sys or soilSystem()
    if sys == nil then
        return
    end
    ensureShape(sys)
    if sys._rfBlockWalk == nil then
        return
    end
    local w = sys._rfBlockWalk
    if sys.fieldBlocks == nil then
        sys.fieldBlocks = {}
    end
    local wasWalking = w.task ~= nil or w.sample ~= nil or #w.queue > 0
    local budget = tonumber(RfPdaSoilMerge.FRAME_BUDGET_S) or 0.003
    if w.sample ~= nil then
        local t0 = getTimeSec()
        local done = false
        repeat
            local ok, fin = pcall(sampleStep, w.sample)
            done = (not ok) or fin == true
        until done or (getTimeSec() - t0) >= budget
        if done then
            finishSample(sys, w)
        end
    elseif w.task == nil then
        local fieldId = table.remove(w.queue, 1)
        if fieldId ~= nil then
            w.queued[fieldId] = nil
            local task = nil
            local cx, cz = fieldCenter(fieldId)
            if cx ~= nil and BoundaryDetectionTask ~= nil and type(BoundaryDetectionTask.new) == "function"
                and g_currentMission ~= nil and g_currentMission.terrainDetailId ~= nil then
                local ok, t = pcall(BoundaryDetectionTask.new, cx, cz)
                if ok then
                    task = t
                end
            end
            if task == nil then
                sys.fieldBlocks[fieldId] = { none = true, dirty = false }
                sys._rfMergeCache = nil
                sys._rfReadGroupsCache = nil
            else
                w.task, w.taskId, w.taskX, w.taskZ, w.taskRestarts = task, fieldId, cx, cz, 0
            end
        end
    else
        local ok, stillWalking = pcall(w.task.update, w.task, dt, budget)
        if not (ok and stillWalking == true) then
            local b = nil
            if ok and type(w.task.boundaryPositions) == "table" then
                b = outlineBounds(w.task.boundaryPositions)
            end
            if b ~= nil and w.taskX ~= nil and not loopEncloses(b.boundary, w.taskX, w.taskZ) then
                -- The loop is an interior hole: walk again from just past it (capped).
                b = nil
                if (w.taskRestarts or 0) < (tonumber(RfPdaSoilMerge.MAX_HOLE_RESTARTS) or 8) then
                    local again = nextWalkPastHole(w.task, w.taskX)
                    if again ~= nil then
                        w.task = again
                        w.taskRestarts = (w.taskRestarts or 0) + 1
                        return
                    end
                end
            end
            local started = false
            if b ~= nil then
                started = startSample(w, w.taskId, b)
            end
            if not started then
                sys.fieldBlocks[w.taskId] = { none = true, dirty = false }
                sys._rfMergeCache = nil
                sys._rfReadGroupsCache = nil
            end
            w.task, w.taskId, w.taskX, w.taskZ, w.taskRestarts = nil, nil, nil, nil, nil
        end
    end
    local walking = w.task ~= nil or w.sample ~= nil or #w.queue > 0
    if wasWalking and not walking then
        pcall(RfPdaSoilMerge.onWalksFinished)
    end
end

--- True while any requested outline is still queued, walking or sampling (a list built
--- now may still show single rows that will merge when the walks finish).
function RfPdaSoilMerge.isWalking(sys)
    sys = sys or soilSystem()
    local w = sys ~= nil and sys._rfBlockWalk or nil
    return w ~= nil and (w.task ~= nil or w.sample ~= nil or #w.queue > 0)
end

-- ---------------------------------------------------------
-- Invalidation
-- ---------------------------------------------------------
--- One farmland's outline goes dirty (rebuilt lazily on the next list build).
function RfPdaSoilMerge.markDirty(fieldId, sys)
    sys = sys or soilSystem()
    if sys == nil or fieldId == nil then
        return
    end
    ensureShape(sys)
    if sys.fieldBlocks ~= nil then
        local rec = sys.fieldBlocks[fieldId]
        if rec ~= nil then
            rec.dirty = true
            -- Every member carried the same set: the whole block re-walks.
            if type(rec.members) == "table" then
                for _, id in ipairs(rec.members) do
                    local other = sys.fieldBlocks[id]
                    if other ~= nil then
                        other.dirty = true
                    end
                end
            end
        end
    end
    sys._rfMergeCache = nil
    sys._rfReadGroupsCache = nil
end

--- The grouping cache drops (outlines stay): ownership changed.
function RfPdaSoilMerge.invalidate()
    local sys = soilSystem()
    if sys ~= nil then
        sys._rfMergeCache = nil
        sys._rfReadGroupsCache = nil
    end
end

--- Everything drops: a save load.
function RfPdaSoilMerge.reset(sys)
    sys = sys or soilSystem()
    if sys == nil then
        return
    end
    sys.fieldBlocks = nil
    sys._rfBlockWalk = nil
    sys._rfMergeCache = nil
    sys._rfReadGroupsCache = nil
end

-- Plow and cultivate are the only field updates that can change the field-ground
-- extent the walk follows (George CLOSED DESIGN 22:55 item 8): sow repaints the ground
-- type on the same pixels, and harvest / fertilize / lime / weed / herbicide never
-- touch the extent.
local FIELD_UPDATE_METHODS = { "plowField", "cultivateField" }

--- Read-only subscriptions, once per session (the flag lives on the module table, which
--- a hot reload keeps): the FieldManager plow / cultivate updates mark the worked
--- farmland's block dirty; FARMLAND_OWNER_CHANGED drops the grouping; a save load drops
--- the whole cache. Appended functions only: nothing here writes the engine.
local function ensureSubscribed()
    if RfPdaSoilMerge._subscribed then
        return
    end
    local okAll = true
    if FieldManager ~= nil and Utils ~= nil and type(Utils.appendedFunction) == "function" then
        for _, name in ipairs(FIELD_UPDATE_METHODS) do
            if type(FieldManager[name]) == "function" then
                FieldManager[name] = Utils.appendedFunction(FieldManager[name], function(_, field)
                    local id = field ~= nil and field.farmland ~= nil and field.farmland.id or nil
                    if id ~= nil then
                        local fn = RfPdaSoilMerge.markDirty
                        if type(fn) == "function" then
                            fn(id)
                        end
                    end
                end)
            end
        end
    else
        okAll = false
    end
    if SoilFertilitySystem ~= nil and type(SoilFertilitySystem.loadFromXMLFile) == "function"
        and Utils ~= nil and type(Utils.appendedFunction) == "function" then
        SoilFertilitySystem.loadFromXMLFile = Utils.appendedFunction(SoilFertilitySystem.loadFromXMLFile, function(self)
            local fn = RfPdaSoilMerge.reset
            if type(fn) == "function" then
                fn(self)
            end
        end)
    end
    if g_messageCenter ~= nil and type(g_messageCenter.subscribe) == "function" and MessageType ~= nil
        and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        pcall(function()
            g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, function()
                local fn = RfPdaSoilMerge.invalidate
                if type(fn) == "function" then
                    fn()
                end
            end, RfPdaSoilMerge)
        end)
    end
    if okAll then
        RfPdaSoilMerge._subscribed = true
    end
end

-- ---------------------------------------------------------
-- Groups
-- ---------------------------------------------------------
-- Owned roster -> { key, lead = {id -> lead id}, members = {lead -> {ids}} }.
-- Farmlands with the same member set share a lead (the lowest candidate id, ownedIds
-- arrive sorted). A farmland whose walk is still pending or came back "none" is its
-- own row; the key names every state so a finished walk rebuilds the grouping.
--- The cached record for a farmland or nil, WITHOUT queueing a walk (the HUD path).
local function peekOutline(sys, fieldId)
    if sys == nil or fieldId == nil then
        return nil
    end
    ensureShape(sys)
    if sys.fieldBlocks == nil then
        return nil
    end
    local rec = sys.fieldBlocks[fieldId]
    if isClean(rec) then
        return rec
    end
    return nil
end

---@param lookup function requestOutline (queues walks) or peekOutline (cached only)
---@param cacheField string the field on sys that memoises this grouping
local function computeOwnedGroups(sys, ownedIds, lookup, cacheField)
    local sets, parts = {}, {}
    for _, id in ipairs(ownedIds) do
        local rec = lookup(sys, id)
        local state
        if rec == nil then
            state = "?"
        elseif rec.none or type(rec.members) ~= "table" or #rec.members == 0 then
            state = "-"
        else
            local bits = {}
            for i = 1, #rec.members do
                bits[i] = tostring(rec.members[i])
            end
            state = table.concat(bits, "+")
            sets[id] = state
        end
        parts[#parts + 1] = tostring(id) .. "=" .. state
    end
    local key = table.concat(parts, ",")
    local cache = sys ~= nil and sys[cacheField] or nil
    if cache ~= nil and cache.key == key then
        return cache
    end

    local bySet, lead, members = {}, {}, {}
    for _, id in ipairs(ownedIds) do
        local root = id
        local set = sets[id]
        if set ~= nil then
            if bySet[set] == nil then
                bySet[set] = id
            end
            root = bySet[set]
        end
        lead[id] = root
        local list = members[root]
        if list == nil then
            list = {}
            members[root] = list
        end
        list[#list + 1] = id
    end
    for _, list in pairs(members) do
        table.sort(list)
    end

    cache = { key = key, lead = lead, members = members }
    if sys ~= nil then
        sys[cacheField] = cache
    end
    return cache
end

--- Shared tail of buildGroups / readGroups: owned leads from the grouping, foreign singles.
local function groupsFrom(sys, ownedIds, foreignIds, lookup, cacheField)
    local groups = {}
    if #ownedIds > 0 and sys ~= nil then
        local cache = computeOwnedGroups(sys, ownedIds, lookup, cacheField)
        local seen = {}
        for _, id in ipairs(ownedIds) do
            local root = cache.lead[id] or id
            if not seen[root] then
                seen[root] = true
                local list = cache.members[root] or { id }
                local copy = {}
                for i = 1, #list do
                    copy[i] = list[i]
                end
                groups[#groups + 1] = { fieldId = copy[1] or root, memberIds = copy }
            end
        end
    elseif #ownedIds > 0 then
        for _, id in ipairs(ownedIds) do
            groups[#groups + 1] = { fieldId = id, memberIds = { id } }
        end
    end
    for _, id in ipairs(foreignIds) do
        groups[#groups + 1] = { fieldId = id, memberIds = { id } }
    end
    table.sort(groups, function(a, b)
        return a.fieldId < b.fieldId
    end)
    return groups
end

local function splitOwned(candidateIds)
    local farmId = resolveFarmId()
    local ownedIds, foreignIds = {}, {}
    for _, id in ipairs(candidateIds or {}) do
        if isOwned(id, farmId) then
            ownedIds[#ownedIds + 1] = id
        else
            foreignIds[#foreignIds + 1] = id
        end
    end
    table.sort(ownedIds)
    return ownedIds, foreignIds
end

--- One list row per block. Unowned candidates stay single rows (the tablet
--- can list foreign fields; they never merge). Returns rows sorted by lead id:
--- { fieldId = lowest member id, memberIds = {sorted ids} }.
---@param candidateIds number[] farmland ids that would each be a row today
---@return table[]
function RfPdaSoilMerge.buildGroups(candidateIds)
    local sys = soilSystem()
    ensureSubscribed()
    local ownedIds, foreignIds = splitOwned(candidateIds)
    return groupsFrom(sys, ownedIds, foreignIds, requestOutline, "_rfMergeCache")
end

--- BUILD 19:23 (George CLOSED DESIGN 19:12): the same grouping from the CACHED outlines only.
--- A farmland with no clean record stays its own row and is NOT queued; nothing here can
--- start a walk, so a draw-tick caller (the Crop Stress HUD) is safe. Same row shape as
--- buildGroups.
---@param candidateIds number[]
---@return table[]
function RfPdaSoilMerge.readGroups(candidateIds)
    local sys = soilSystem()
    local ownedIds, foreignIds = splitOwned(candidateIds)
    return groupsFrom(sys, ownedIds, foreignIds, peekOutline, "_rfReadGroupsCache")
end

-- ---------------------------------------------------------
-- Labels
-- ---------------------------------------------------------
local function isConsecutive(ids)
    for i = 2, #ids do
        if ids[i] ~= ids[i - 1] + 1 then
            return false
        end
    end
    return true
end

--- "Field 19" / "Field 19-21" / "Fields 19, 22, 24".
---@param memberIds number[] sorted ascending
---@param tr function|nil l10n lookup (key, fallback)
---@return string
function RfPdaSoilMerge.label(memberIds, tr)
    tr = tr or function(k, fb) return fb or k end
    local ids = memberIds or {}
    if #ids <= 1 then
        return string.format("Field %s", tostring(ids[1]))
    end
    if isConsecutive(ids) then
        local tpl = tr("sf_merge_label_range", "Field %s-%s")
        local ok, text = pcall(string.format, tpl, tostring(ids[1]), tostring(ids[#ids]))
        if ok then
            return text
        end
        return string.format("Field %s-%s", tostring(ids[1]), tostring(ids[#ids]))
    end
    local bits = {}
    for i = 1, #ids do
        bits[i] = tostring(ids[i])
    end
    local joined = table.concat(bits, ", ")
    local tpl = tr("sf_merge_label_list", "Fields %s")
    local ok, text = pcall(string.format, tpl, joined)
    if ok then
        return text
    end
    return "Fields " .. joined
end

--- "19" / "19-21" / "19, 22, 24" for narrow id cells.
---@param memberIds number[] sorted ascending
---@return string
function RfPdaSoilMerge.shortLabel(memberIds)
    local ids = memberIds or {}
    if #ids <= 1 then
        return tostring(ids[1])
    end
    if isConsecutive(ids) then
        return tostring(ids[1]) .. "-" .. tostring(ids[#ids])
    end
    local bits = {}
    for i = 1, #ids do
        bits[i] = tostring(ids[i])
    end
    return table.concat(bits, ", ")
end

-- ---------------------------------------------------------
-- Row data for a block
-- ---------------------------------------------------------
local function weighted(infos, areas, getter)
    local sum, wsum = 0, 0
    for i, info in ipairs(infos) do
        local v = getter(info)
        if type(v) == "number" then
            local w = areas[i]
            if type(w) ~= "number" or w <= 0 then
                w = 1
            end
            sum = sum + v * w
            wsum = wsum + w
        end
    end
    if wsum <= 0 then
        return nil
    end
    return sum / wsum
end

-- Mirror of the status word getFieldInfo puts beside a nutrient value
-- (SoilFertilitySystem nutrientStatus): Poor under the poor threshold, Fair
-- under min(fair threshold, crop opt target), else Good.
local function nutrientStatus(value, nutrient, ct)
    local thresholds = SoilConstants ~= nil and SoilConstants.STATUS_THRESHOLDS or nil
    local t = thresholds ~= nil and thresholds[nutrient] or nil
    if t == nil then
        return "Unknown"
    end
    if value < t.poor then
        return "Poor"
    end
    local goodAt = t.fair
    if ct ~= nil then
        local nutKey = nutrient == "nitrogen" and "N" or nutrient == "phosphorus" and "P" or "K"
        local entry = ct[nutKey]
        if entry ~= nil and entry.opt ~= nil and entry.opt < goodAt then
            goodAt = entry.opt
        end
    end
    if value < goodAt then
        return "Fair"
    end
    return "Good"
end

--- Merge the getFieldInfo tables of a block's members into one row info.
--- Area sums; N/P/K/pH/OM and the pressures area-weight (status recomputed
--- from the weighted value with the lead member's crop targets, the same
--- rule getFieldInfo uses); disease stays "Unscouted" unless every member
--- is scouted; needsFertilization and amendBurnRisk are true when any
--- member says so; the protection flags are true only when every member is
--- covered. Every key not listed here (crop, rotation, sample dates, crop
--- targets, sim flags) comes from the lead member, the lowest id.
---@param infos table[] getFieldInfo results in memberIds order (lead first)
---@return table
function RfPdaSoilMerge.aggregateInfo(infos)
    local lead = infos[1]
    if lead == nil then
        return nil
    end
    if #infos == 1 then
        return lead
    end
    local out = {}
    for k, v in pairs(lead) do
        out[k] = v
    end

    local areas, totalArea = {}, 0
    for i, info in ipairs(infos) do
        local a = tonumber(info.fieldArea) or 0
        areas[i] = a
        totalArea = totalArea + a
    end
    out.fieldArea = totalArea

    local ct = lead.cropTargets
    local function nutrient(key)
        local v = weighted(infos, areas, function(info)
            return type(info[key]) == "table" and info[key].value or nil
        end)
        if v == nil then
            return lead[key]
        end
        return { value = math.floor(v), status = nutrientStatus(v, key, ct) }
    end
    out.nitrogen = nutrient("nitrogen")
    out.phosphorus = nutrient("phosphorus")
    out.potassium = nutrient("potassium")

    local function scalar(key)
        local v = weighted(infos, areas, function(info) return info[key] end)
        if v == nil then
            return lead[key]
        end
        return v
    end
    out.pH = scalar("pH")
    out.organicMatter = scalar("organicMatter")
    out.weedPressure = scalar("weedPressure")
    out.pestPressure = scalar("pestPressure")
    out.diseasePressure = scalar("diseasePressure")
    out.compaction = scalar("compaction")
    out.coverageFraction = scalar("coverageFraction")
    out.yieldEfficiency = scalar("yieldEfficiency")

    local allScouted, allDiscovered = true, true
    local anyNeeds, anyBurn = false, false
    local allHerb, allInsect, allFung = true, true, true
    for _, info in ipairs(infos) do
        if info.shownDiseasePressure == nil then allScouted = false end
        if not info.diseaseDiscovered then allDiscovered = false end
        if info.needsFertilization then anyNeeds = true end
        if info.amendBurnRisk then anyBurn = true end
        if not info.herbicideActive then allHerb = false end
        if not info.insecticideActive then allInsect = false end
        if not info.fungicideActive then allFung = false end
    end
    if allScouted then
        out.shownDiseasePressure = scalar("shownDiseasePressure")
    else
        out.shownDiseasePressure = nil
    end
    out.diseaseDiscovered = allDiscovered
    out.needsFertilization = anyNeeds
    out.amendBurnRisk = anyBurn
    out.herbicideActive = allHerb
    out.insecticideActive = allInsect
    out.fungicideActive = allFung

    out.isMergedBlock = true
    out.memberCount = #infos
    return out
end

--- Build one list entry per block from the soil system. Shared by the Esc
--- Soil panel and the tablet overview so both agree on every number.
--- Returns entries { fieldId, memberIds, isGroup, info, urgency } sorted by
--- lead id. A block whose lead has no getFieldInfo answer is skipped, the
--- same as a single field today; a member without an answer is left out
--- of the aggregate.
---@param sys table SoilFertilitySystem
---@param candidateIds number[]
---@return table[]
function RfPdaSoilMerge.buildRows(sys, candidateIds)
    local okGroups, groups = pcall(RfPdaSoilMerge.buildGroups, candidateIds)
    if not okGroups or type(groups) ~= "table" then
        -- Geometry fault: fall back to one row per field, never an empty list.
        groups = {}
        for _, id in ipairs(candidateIds or {}) do
            groups[#groups + 1] = { fieldId = id, memberIds = { id } }
        end
        table.sort(groups, function(a, b) return a.fieldId < b.fieldId end)
    end

    local rows = {}
    for _, group in ipairs(groups) do
        local infos, members = {}, {}
        local urgency = 0
        for _, id in ipairs(group.memberIds) do
            local ok, info = pcall(function() return sys:getFieldInfo(id) end)
            if ok and info ~= nil then
                infos[#infos + 1] = info
                members[#members + 1] = id
                local urgOk, urgVal = pcall(function() return sys:getFieldUrgency(id) end)
                if urgOk and type(urgVal) == "number" and urgVal > urgency then
                    urgency = urgVal
                end
            end
        end
        if #infos > 0 then
            rows[#rows + 1] = {
                fieldId = members[1],
                memberIds = members,
                isGroup = #members > 1,
                info = RfPdaSoilMerge.aggregateInfo(infos),
                urgency = urgency,
            }
        end
    end
    table.sort(rows, function(a, b)
        return a.fieldId < b.fieldId
    end)
    return rows
end

--- Lead id of the block that contains fieldId, or fieldId when it is not in
--- any row. Keeps a selection made before a rebuild pointing at a real row.
---@param rows table[] buildRows result
---@param fieldId number|nil
---@return number|nil
function RfPdaSoilMerge.leadFor(rows, fieldId)
    if fieldId == nil then
        return nil
    end
    for _, row in ipairs(rows or {}) do
        for _, id in ipairs(row.memberIds or {}) do
            if id == fieldId then
                return row.fieldId
            end
        end
    end
    return fieldId
end

-- Cross-mod publish (same shape as RfPdaSoilPanel).
if type(getfenv) == "function" then
    local env0 = getfenv(0)
    if env0 ~= nil then
        env0["RfPdaSoilMerge"] = RfPdaSoilMerge
    end
end
