--
-- GroundConditionCoordinator
--
-- RSF-F208, sections 2 and 6 of GROUND-CONDITION-CONTRACT v1.5.
--
-- Section 2 is the ORDER rule: before any admitted native material operation may
-- write a fresh or current ground condition, the ground it is about to touch must
-- already be settled up to today. Without that barrier a deposit made on day 105
-- against cursors still sitting on day 100 gets five days of weather and ageing
-- applied to it AFTER its birth - material born today, aged five days by a
-- catch-up that belongs to the ground it landed on, not to it.
--
-- Section 2 is also the COMBINE rule at the destination: what the cell ends up
-- holding is a function of the material that survived there plus the material that
-- actually arrived, under a conservative policy (oldest age, wettest band, unknown
-- and ceiling propagate rather than average away).
--
-- Section 6 is the BOOKKEEPING: one owner revision, and an availability overlay
-- that records the cells whose condition we know we cannot vouch for.
--
-- Section 5 (RSF-F213, P-GROUND-3) is the MEMBERSHIP INDEX: which Soil cells the
-- daily settle must consider, fields and yards alike. A one-bit companion layer at
-- the exact condition geometry (the store's groundMembership layer), marked after an
-- actual birth, deposit or removal through the writes below, kept beside it as
-- compressed row runs for enumeration. Positive tracked material with UNKNOWN
-- condition is a member too (it must not be mistaken for bare ground; weather does
-- not initialise it). The index is derived, never a truth: a bit has no quantity
-- meaning, an index write failure sets rebuild-required and condition stays
-- unavailable until the next arm reconciles it, and an absent or foreign index is
-- rebuilt at arm from the condition bytes and native tracked occupancy by bounded
-- row traversal, never assumed empty.
--
-- THE SINGLE MOST IMPORTANT RULE IN THIS FILE. Nothing here may block native work.
-- A refused barrier, an unestablished clock, a missing geometry or a failed write
-- all mean the same thing: the native game carries on exactly as it would without
-- this mod, and the ENHANCED CONDITION is unavailable. Unavailable is a normal,
-- expected, shipping state - not an error path. It is in fact the state that ships
-- today, because nothing calls into this coordinator until the movement carriers
-- of section 3 land.
--

GroundConditionCoordinator = {}
local GroundConditionCoordinator_mt = Class(GroundConditionCoordinator)

local AGE_UNKNOWN  = 0     -- no record on positive material
local AGE_CEILING  = 255   -- the ceiling refusal
local WET_ABSENT   = 0     -- uninitialised
local WET_UNKNOWN  = 24    -- the reserved-band refusal marker
local WET_FLOOR    = 32    -- lowest known encoded wetness

-- Section 5: the membership layer and its bit.
GroundConditionCoordinator.MEMBERSHIP_KEY = "groundMembership"
GroundConditionCoordinator.MEMBER         = 1
GroundConditionCoordinator.NOT_MEMBER     = 0
-- How the run cache came to be: read from the saved index, or rebuilt from the
-- condition bytes and native occupancy.
GroundConditionCoordinator.MEMBERSHIP_FROM_INDEX   = "INDEX"
GroundConditionCoordinator.MEMBERSHIP_REBUILT      = "REBUILT"

GroundConditionCoordinator.BARRIER_OK            = "OK"
GroundConditionCoordinator.BARRIER_NO_CLOCK      = "NO_TRUSTED_DAY"
GroundConditionCoordinator.BARRIER_REENTRANT     = "REENTRANT"
GroundConditionCoordinator.BARRIER_NOT_ARMED     = "NOT_ARMED"
GroundConditionCoordinator.BARRIER_SETTLE_FAILED = "SETTLE_INCOMPLETE"
GroundConditionCoordinator.BARRIER_NO_GEOMETRY   = "NO_GEOMETRY"

-- =========================================================
-- Construction and bind
-- =========================================================

function GroundConditionCoordinator.new()
    local self = setmetatable({}, GroundConditionCoordinator_mt)
    self.armed          = false
    self.cells          = nil
    self.materialDown   = nil
    self.materialWetness= nil
    self.soilSystem     = nil

    -- Section 6. The owner revision is the mission epoch plus a monotonic change
    -- counter; the two domain cursors are read from their owners, never mirrored
    -- here, because a mirror is one more thing that can disagree with the truth.
    self.epoch          = 0
    self.changeCounter  = 0

    -- Availability overlay: cells whose condition we know we cannot vouch for.
    -- Keyed "gx:gz" -> reason string. This SURVIVES SAVE and clears for a cell only
    -- on a successful complete pair write against current physical observation.
    self.unavailable    = {}
    self.unavailableCount = 0

    -- Barrier re-entrancy guard. The barrier is synchronous and non-yielding; a
    -- settlement that somehow re-entered it would recurse forever.
    self.inBarrier      = false
    -- The last day the barrier confirmed settled, so repeated primitives inside
    -- one native call do not re-walk the owners.
    self.barrierThroughDay = nil
    -- Section 5: the membership index, nil until arm resolves the layer.
    self.membership = nil
    return self
end

---@return boolean armed
function GroundConditionCoordinator:arm(cells, materialDown, materialWetness, soilSystem)
    self.armed = false
    if g_server == nil then return false end
    if cells == nil or not cells:isArmed() then
        SoilLogger.warning("[GroundCoord] condition cells are not armed - ground condition stands down")
        return false
    end
    if materialDown == nil or materialWetness == nil then
        SoilLogger.warning("[GroundCoord] condition owners did not resolve - ground condition stands down")
        return false
    end
    -- BOTH owners must be ARMED, not merely present. The ground-material family
    -- sits behind the `ground_material` release gate, so on an ordinary save the
    -- two owners exist as objects and are completely inert. Arming on top of inert
    -- owners would publish an admission interface that accepts a lease, runs a
    -- barrier against cursors nobody advances, and writes condition no owner
    -- maintains - exactly the "present Soil that cannot receive anything" the
    -- contract refuses. If they are not armed, neither are we, and consumers
    -- correctly see Soil as absent for this join.
    if not materialDown:isArmed() or not materialWetness:isArmed() then
        SoilLogger.info(
            "[GroundCoord] the ground-material family is not armed (age=%s wetness=%s) - ground condition " ..
            "is unavailable and the admission interface will not be published. This is the normal state " ..
            "while the family is gated.",
            tostring(materialDown:isArmed()), tostring(materialWetness:isArmed()))
        return false
    end

    self.cells           = cells
    self.materialDown    = materialDown
    self.materialWetness = materialWetness
    self.soilSystem      = soilSystem
    self.epoch           = self.epoch + 1
    self.changeCounter   = 0
    self.barrierThroughDay = nil
    self.inBarrier       = false
    self.armed           = true

    -- [MAINTENANCE row 137] The availability overlay rides MaterialDown's envelope (one save
    -- boundary, one generation; contract section 6) and comes back only when the store's
    -- load decides MODERN. MaterialDown decides lazily, after every door has delivered, so
    -- until then the overlay is on hold: every cell reads unavailable (section 5), never
    -- the empty overlay a fresh arm starts with.
    self.overlayPending = false
    if MaterialDown ~= nil and type(materialDown.addEnvelopeContributor) == "function" then
        materialDown:addEnvelopeContributor("groundAvailability", function() return self:serialize() end)
        if materialDown.loadState == MaterialDown.LOAD.PENDING then
            self.overlayPending = true
            materialDown:addLoadObserver("groundCoordinator", function(state, _reason, payload)
                self:_onStoreDecided(state, payload)
            end)
        end
    end

    -- Section 5: the membership index, and the wetness owner's binding to it so the
    -- daily settle walks members instead of fields (MaterialWetness:bindMembership).
    -- A store without the layer leaves the owner on its field pass.
    self:_armMembership()
    if self.membership ~= nil and materialWetness.bindMembership ~= nil then
        materialWetness:bindMembership(self)
    end

    SoilLogger.info("[OK] GroundConditionCoordinator armed (epoch %d)", self.epoch)
    return true
end

-- =========================================================
-- Section 5: the membership index (RSF-F213, P-GROUND-3)
-- =========================================================

local MEMBERSHIP_CHANNELS = 1

--- Insert cell gx into row gz's run list, merging with neighbours.
local function runsInsert(rows, gx, gz)
    local runs = rows[gz]
    if runs == nil then rows[gz] = { { gx, gx } } return true end
    for i, r in ipairs(runs) do
        if gx >= r[1] and gx <= r[2] then return false end
        if gx == r[2] + 1 then
            r[2] = gx
            local nxt = runs[i + 1]
            if nxt ~= nil and nxt[1] == gx + 1 then r[2] = nxt[2] table.remove(runs, i + 1) end
            return true
        end
        if gx == r[1] - 1 then r[1] = gx return true end
        if gx < r[1] then table.insert(runs, i, { gx, gx }) return true end
    end
    runs[#runs + 1] = { gx, gx }
    return true
end

--- Remove cell gx from row gz's run list, splitting a run when needed.
local function runsRemove(rows, gx, gz)
    local runs = rows[gz]
    if runs == nil then return false end
    for i, r in ipairs(runs) do
        if gx >= r[1] and gx <= r[2] then
            if r[1] == r[2] then table.remove(runs, i)
            elseif gx == r[1] then r[1] = gx + 1
            elseif gx == r[2] then r[2] = gx - 1
            else
                local tail = { gx + 1, r[2] }
                r[2] = gx - 1
                table.insert(runs, i + 1, tail)
            end
            if #runs == 0 then rows[gz] = nil end
            return true
        end
    end
    return false
end

local function runsContain(rows, gx, gz)
    local runs = rows[gz]
    if runs == nil then return false end
    for _, r in ipairs(runs) do
        if gx >= r[1] and gx <= r[2] then return true end
    end
    return false
end

--- Aim the membership modifier at one cell's middle half (the cells' inset rule).
local function aimMembership(mod, gx, gz, resolution)
    local u0, v0 = (gx + 0.25) / resolution, (gz + 0.25) / resolution
    local u1, v1 = (gx + 0.75) / resolution, (gz + 0.75) / resolution
    mod:setParallelogramUVCoords(u0, v0, u1, v0, u0, v1, DensityCoordType.POINT_POINT_POINT)
end

--- Aim a modifier at the middle band of a whole row (every cell's middle half).
local function aimRow(mod, gz, resolution)
    local u0, u1 = 0.25 / resolution, (resolution - 0.25) / resolution
    local v0, v1 = (gz + 0.25) / resolution, (gz + 0.75) / resolution
    mod:setParallelogramUVCoords(u0, v0, u1, v0, u0, v1, DensityCoordType.POINT_POINT_POINT)
end

--- Resolve the membership layer and build the run cache. Never refuses the arm:
--- without the layer the coordinator is armed with no index, and the wetness owner
--- keeps its field pass (said once in the log).
function GroundConditionCoordinator:_armMembership()
    self.membership = nil
    local vm = self.cells ~= nil and self.cells.valueMaps or nil
    local entry = vm ~= nil and vm.getLayerEntry ~= nil and vm:getLayerEntry(GroundConditionCoordinator.MEMBERSHIP_KEY) or nil
    if entry == nil or entry.bvm == nil then
        SoilLogger.warning("[GroundCoord] no groundMembership layer in the store - the daily settle keeps the field pass (no membership index)")
        return false
    end
    local geometry = self.cells:getConditionGeometry()
    if geometry == nil then return false end
    local channels = entry.channels or MEMBERSHIP_CHANNELS
    -- MAINTENANCE row 107 (section 5, contract :80: a foreign index is rebuilt). A
    -- layer of another width cannot index this grid, so it is re-initialised blank at
    -- the condition grid's width (loadBitVectorMapNew, as SoilValueMaps does for a
    -- layer with no file and PF's ExtendedWeedControl.lua:65 does), a fresh modifier
    -- is built over it below, and the index is rebuilt from the truth. It used to be
    -- left off, which put the daily settle back on the field pass.
    local reinitialised = false
    local okW, width = pcall(getBitVectorMapSize, entry.bvm)
    if okW and type(width) == "number" and width ~= geometry.resolution then
        local okN, errN = pcall(loadBitVectorMapNew, entry.bvm, geometry.resolution, geometry.resolution, channels, false)
        if not okN then
            SoilLogger.warning("[GroundCoord] groundMembership layer width %d does not match the condition grid %d and could not be re-initialised (%s) - no membership index",
                width, geometry.resolution, tostring(errN))
            return false
        end
        SoilLogger.warning("[GroundCoord] groundMembership layer width %d did not match the condition grid %d - re-initialised at %d, the index is rebuilt from the condition bytes and native occupancy",
            width, geometry.resolution, geometry.resolution)
        reinitialised = true
    end
    local okMods, mod, filter = pcall(function()
        local m = DensityMapModifier.new(entry.bvm, 0, channels, g_terrainNode)
        return m, DensityMapFilter.new(m)
    end)
    if not okMods then
        SoilLogger.warning("[GroundCoord] could not build the membership modifier (%s) - no membership index", tostring(mod))
        return false
    end
    self.membership = {
        entry = entry, bvm = entry.bvm, mod = mod, filter = filter, channels = channels,
        rows = {}, count = 0, ready = false, rebuildRequired = false, source = nil,
        epoch = self.epoch,
    }
    -- MAINTENANCE rows 107 and 137: the saved index is read only when it came from the
    -- SAME save as the condition bytes it indexes. The three layers loaded from that
    -- save's files (row 107), AND the index stamp in soilData.xml equals the career
    -- marker's generation (row 137, section 5's epoch). The save writes the stamp only
    -- after all three layers saved, and the marker carries its generation whether or not
    -- the store's backend succeeded. Both are on disk and read synchronously here, before
    -- the store's own load decides. Any other state rebuilds from the truth, and a loaded
    -- index that is not trusted is cleared first so none of its stale bits is saved again.
    local cellsRef = self.cells
    local stamped = false
    if SoilMaterialDownBridge ~= nil and type(SoilMaterialDownBridge.readCareerMarker) == "function"
       and type(SoilMaterialDownBridge.readIndexStamp) == "function" then
        local okM, marker = pcall(SoilMaterialDownBridge.readCareerMarker)
        local okS, stamp = pcall(SoilMaterialDownBridge.readIndexStamp)
        stamped = okM and okS and type(marker) == "table" and type(marker.generation) == "number"
            and marker.generation > 0 and stamp == marker.generation
    end
    self.membership.stamped = stamped
    local fromIndex = entry.loaded == true and not reinitialised and stamped
        and cellsRef.ageEntry ~= nil and cellsRef.ageEntry.loaded == true
        and cellsRef.wetEntry ~= nil and cellsRef.wetEntry.loaded == true
    local ok, err = pcall(function()
        if fromIndex then
            self:_membershipFromIndex(geometry)
            self.membership.source = GroundConditionCoordinator.MEMBERSHIP_FROM_INDEX
        else
            if entry.loaded == true and not reinitialised then self:_clearMembershipLayer() end
            self:_membershipRebuild(geometry)
            self.membership.source = GroundConditionCoordinator.MEMBERSHIP_REBUILT
        end
    end)
    if not ok then
        SoilLogger.warning("[GroundCoord] membership index build failed (%s) - rebuild required, condition unavailable until the next arm", tostring(err))
        self.membership.rebuildRequired = true
        self.membership.ready = false
        return false
    end
    self.membership.ready = not self.membership.rebuildRequired
    SoilLogger.info("[OK] ground membership index %s: %d member cell(s) in %d row(s)%s",
        self.membership.source == GroundConditionCoordinator.MEMBERSHIP_FROM_INDEX and "read from the saved index" or "rebuilt from the condition bytes and native occupancy",
        self.membership.count, self:membershipRowCount(),
        self.membership.ready and "" or " - REBUILD REQUIRED, condition unavailable until the next arm")
    return self.membership.ready
end

function GroundConditionCoordinator:membershipRowCount()
    local n = 0
    if self.membership ~= nil then for _ in pairs(self.membership.rows) do n = n + 1 end end
    return n
end

--- Read one membership bit exactly.
function GroundConditionCoordinator:_readMemberBit(gx, gz)
    local m = self.membership
    local ok, v = pcall(getBitVectorMapPoint, m.bvm, gx, gz, 0, m.channels)
    if not ok or type(v) ~= "number" then return nil end
    return v
end

--- Count the cells of row gz whose bit (or, for a condition layer, whose byte in
--- [lo, hi]) the engine selects: one filtered executeGet over the row.
local function rowCount(mod, filter, gz, resolution, lo, hi)
    aimRow(mod, gz, resolution)
    filter:setValueCompareParams(DensityValueCompareType.BETWEEN, lo, hi)
    local _, n = mod:executeGet(filter)
    return type(n) == "number" and n or 0
end

--- Native tracked occupancy over a world box, summed over the observer's types.
--- nil when it cannot be read (no util, no observer, a refused read): unknown, never
--- zero.
local function occupancyIn(x0, z0, x1, z1)
    if type(DensityMapHeightUtil) ~= "table" or type(DensityMapHeightUtil.getFillLevelAtArea) ~= "function" then return nil end
    if GroundNativeObserver == nil or GroundNativeObserver.occupancyTypeIndices == nil then return nil end
    local total = 0
    for _, ft in ipairs(GroundNativeObserver.occupancyTypeIndices(nil)) do
        local ok, litres = pcall(DensityMapHeightUtil.getFillLevelAtArea, ft, x0, z0, x1, z0, x0, z1)
        if not ok or type(litres) ~= "number" then return nil end
        total = total + litres
    end
    return total
end

--- The run cache from a saved index: one filtered count per row, cells read only in
--- rows that hold a member.
---
--- MAINTENANCE row 108: a cell marked unavailable is marked a member (markUnavailable,
--- section 5: positive material of unknown condition is a member), so a native
--- throw's mark-all over an envelope (GroundMovementCarrier.onPrimitiveFailed) made
--- cells holding nothing into members that were enumerated and saved from then on.
--- A member read here with NO condition record whose whole cell holds a KNOWN ZERO of
--- tracked native material leaves the index (its bit cleared). A nil occupancy (not
--- readable), an invalid height map or a refused cell read keeps it: unknown is never
--- read as empty. The
--- rebuild and reconcile already leave such cells out; this is the one path that
--- trusted a bit without asking.
function GroundConditionCoordinator:_membershipFromIndex(geometry)
    local m = self.membership
    local cells = self.cells
    local resolution = geometry.resolution
    local grain, ox, oz = geometry.grainMetres, geometry.originX, geometry.originZ
    -- The native fill read answers 0 for an invalid height map (DensityMapHeightUtil
    -- .lua:81-83), which is not an observation: then no member leaves.
    local heightOk = GroundNativeObserver ~= nil and type(GroundNativeObserver.heightMapValid) == "function"
        and GroundNativeObserver.heightMapValid() == true
    for gz = 0, resolution - 1 do
        local n = rowCount(m.mod, m.filter, gz, resolution, GroundConditionCoordinator.MEMBER, GroundConditionCoordinator.MEMBER)
        if n > 0 then
            for gx = 0, resolution - 1 do
                if self:_readMemberBit(gx, gz) == GroundConditionCoordinator.MEMBER then
                    local empty = false
                    local c = cells:readConditionCell(geometry, gx, gz)
                    if heightOk and c.refused == nil and c.ageAvailable and c.wetnessAvailable
                       and (c.ageRaw or 0) == 0 and (c.wetnessRaw or 0) == 0 then
                        local x0, z0 = ox + gx * grain, oz + gz * grain
                        local litres = occupancyIn(x0, z0, x0 + grain, z0 + grain)
                        empty = litres ~= nil and litres <= 0
                    end
                    if empty and self:_writeMemberBit(gx, gz, GroundConditionCoordinator.NOT_MEMBER) then
                        m.emptyLeft = (m.emptyLeft or 0) + 1
                    else
                        -- A refused clear keeps the cell a member in the cache, as its
                        -- bit still is, and asks for a rebuild.
                        if empty then m.rebuildRequired = true end
                        if runsInsert(m.rows, gx, gz) then m.count = m.count + 1 end
                    end
                end
            end
        end
    end
end

--- Clear the whole membership layer: one set over the layer's full extent, read back
--- nowhere (the rebuild that follows writes and reads back each bit it sets). Raises
--- on a refused set, so the caller's pcall marks the index rebuild-required.
function GroundConditionCoordinator:_clearMembershipLayer()
    local m = self.membership
    m.mod:setParallelogramUVCoords(0, 0, 1, 0, 0, 1, DensityCoordType.POINT_POINT_POINT)
    m.mod:executeSet(GroundConditionCoordinator.NOT_MEMBER)
end

--- Rebuild the index from the truth (an absent or foreign index): every cell with a
--- condition record is a member, and so is every cell with positive tracked native
--- material and no record (unknown condition). Rows are counted first and walked
--- only when they hold something; native occupancy is asked per row and split in
--- halves down to the cells that hold it, so the work is bounded by what is there.
function GroundConditionCoordinator:_membershipRebuild(geometry)
    local m = self.membership
    local cells = self.cells
    local resolution = geometry.resolution
    local grain, ox, oz = geometry.grainMetres, geometry.originX, geometry.originZ
    local function markCell(gx, gz)
        if runsContain(m.rows, gx, gz) then return end
        if not self:_writeMemberBit(gx, gz, GroundConditionCoordinator.MEMBER) then
            m.rebuildRequired = true
            return
        end
        runsInsert(m.rows, gx, gz)
        m.count = m.count + 1
    end
    local function splitOccupied(gx0, gx1, gz)
        local x0, x1 = ox + gx0 * grain, ox + (gx1 + 1) * grain
        local z0, z1 = oz + gz * grain, oz + (gz + 1) * grain
        local litres = occupancyIn(x0, z0, x1, z1)
        if litres == nil or litres <= 0 then return end
        if gx0 == gx1 then markCell(gx0, gz) return end
        local mid = math.floor((gx0 + gx1) / 2)
        splitOccupied(gx0, mid, gz)
        splitOccupied(mid + 1, gx1, gz)
    end
    for gz = 0, resolution - 1 do
        -- The condition bytes: any recorded age or any wetness byte at all.
        local recorded = rowCount(cells.ageMod, cells.ageFilter, gz, resolution, 1, 255)
                       + rowCount(cells.wetMod, cells.wetFilter, gz, resolution, 1, 255)
        if recorded > 0 then
            for gx = 0, resolution - 1 do
                local c = cells:readConditionCell(geometry, gx, gz)
                if (c.ageRaw ~= nil and c.ageRaw > 0) or (c.wetnessRaw ~= nil and c.wetnessRaw > 0) then
                    markCell(gx, gz)
                end
            end
        end
        -- Native material with no record: a member of unknown condition.
        splitOccupied(0, resolution - 1, gz)
    end
end

--- Write one membership bit: aim, set, read back. False on any refusal.
function GroundConditionCoordinator:_writeMemberBit(gx, gz, bit)
    local m = self.membership
    local geometry = self.cells:getConditionGeometry()
    if geometry == nil then return false end
    local ok = pcall(function()
        aimMembership(m.mod, gx, gz, geometry.resolution)
        m.mod:executeSet(bit)
    end)
    if not ok then return false end
    return self:_readMemberBit(gx, gz) == bit
end

--- Mark a cell as a member after an actual birth, deposit or removal that left
--- material, or a mark that positive material of unknown condition sits there. A
--- write failure sets rebuild-required: the cell's condition is unavailable and the
--- daily settle holds until the next arm reconciles the index.
function GroundConditionCoordinator:markMember(gx, gz)
    local m = self.membership
    if m == nil then return false end
    if runsContain(m.rows, gx, gz) then return true end
    if not self:_writeMemberBit(gx, gz, GroundConditionCoordinator.MEMBER) then
        m.rebuildRequired = true
        m.ready = false
        self:markUnavailable(gx, gz, "MEMBERSHIP_WRITE_FAILED", true)
        SoilLogger.warning("[GroundCoord] membership bit for cell %d,%d could not be written - rebuild required, condition unavailable until the next arm", gx, gz)
        return false
    end
    runsInsert(m.rows, gx, gz)
    m.count = m.count + 1
    return true
end

--- Unmark a cell whose whole-cell occupancy is known to be zero and whose record
--- was cleared.
function GroundConditionCoordinator:unmarkMember(gx, gz)
    local m = self.membership
    if m == nil then return false end
    if not runsContain(m.rows, gx, gz) then return true end
    if not self:_writeMemberBit(gx, gz, GroundConditionCoordinator.NOT_MEMBER) then
        m.rebuildRequired = true
        m.ready = false
        SoilLogger.warning("[GroundCoord] membership bit for cell %d,%d could not be cleared - rebuild required, condition unavailable until the next arm", gx, gz)
        return false
    end
    runsRemove(m.rows, gx, gz)
    m.count = m.count - 1
    return true
end

--- Reconcile an index that took a refused write: clear every cached member's bit
--- and rebuild from the condition bytes and native occupancy. True when the index
--- is ready again.
function GroundConditionCoordinator:reconcileMembership()
    local m = self.membership
    if m == nil then return false end
    if m.ready and not m.rebuildRequired then return true end
    local geometry = self.cells ~= nil and self.cells:getConditionGeometry() or nil
    if geometry == nil then return false end
    local ok = pcall(function()
        for gz, runs in pairs(m.rows) do
            for _, r in ipairs(runs) do
                for gx = r[1], r[2] do self:_writeMemberBit(gx, gz, GroundConditionCoordinator.NOT_MEMBER) end
            end
        end
        m.rows, m.count, m.rebuildRequired = {}, 0, false
        self:_membershipRebuild(geometry)
        m.source = GroundConditionCoordinator.MEMBERSHIP_REBUILT
    end)
    if not ok then m.rebuildRequired = true end
    m.ready = ok and not m.rebuildRequired
    self:bumpRevision("membership-reconciled")
    return m.ready
end

function GroundConditionCoordinator:isMember(gx, gz)
    return self.membership ~= nil and runsContain(self.membership.rows, gx, gz)
end

--- True when the index exists, was built and has taken every write since.
function GroundConditionCoordinator:isMembershipReady()
    return self.membership ~= nil and self.membership.ready == true and not self.membership.rebuildRequired
end

function GroundConditionCoordinator:getMembershipStats()
    local m = self.membership
    if m == nil then return nil end
    return { count = m.count, rows = self:membershipRowCount(), ready = self:isMembershipReady(), source = m.source, rebuildRequired = m.rebuildRequired }
end

--- Enumerate the member runs, row by row, run by run: fn(gz, gx0, gx1). Rows are
--- visited in ascending order so a caller's work is deterministic; the runs of a
--- row are kept sorted by the cache. The cache is a disposable enumeration aid:
--- nothing here reads the native index.
function GroundConditionCoordinator:enumerateMemberRuns(fn)
    local m = self.membership
    if m == nil or type(fn) ~= "function" then return 0 end
    local gzs = {}
    for gz in pairs(m.rows) do gzs[#gzs + 1] = gz end
    table.sort(gzs)
    local n = 0
    for _, gz in ipairs(gzs) do
        local runs = m.rows[gz]
        for _, r in ipairs(runs) do
            fn(gz, r[1], r[2])
            n = n + 1
        end
    end
    return n
end

--- The wetness owner's daily write: one value over a run of a row. The age layer is
--- untouched. A refused write marks the run's cells unavailable (the bytes they hold
--- can no longer be vouched for as settled).
---@return boolean ok
function GroundConditionCoordinator:writeWetnessRun(gx0, gx1, gz, wetnessRaw)
    if not self.armed then return false end
    local geometry = self.cells:getConditionGeometry()
    if geometry == nil then return false end
    local res = self.cells:writeWetnessRun(geometry, gx0, gx1, gz, self.cells.geometryRevision, wetnessRaw)
    if res.ok then
        self:bumpRevision("weather")
        return true
    end
    for gx = gx0, gx1 do self:markUnavailable(gx, gz, "WEATHER:" .. tostring(res.refused)) end
    return false
end

--- The wetness owner's read of one cell, and the cell's centre in the world.
function GroundConditionCoordinator:readCell(gx, gz)
    local geometry = self.cells:getConditionGeometry()
    if geometry == nil then return nil end
    return self.cells:readConditionCell(geometry, gx, gz)
end

function GroundConditionCoordinator:cellWorldBox(gx, gz)
    local geometry = self.cells:getConditionGeometry()
    if geometry == nil then return nil end
    local g = geometry.grainMetres
    local x0, z0 = geometry.originX + gx * g, geometry.originZ + gz * g
    return x0, z0, x0 + g, z0 + g
end

function GroundConditionCoordinator:isArmed()
    return self.armed
end

-- =========================================================
-- Section 6: owner revision
-- =========================================================

--- The owner revision every consumer stamps against. Movement, birth, weather,
--- clear, availability change and provider lifecycle all move it.
function GroundConditionCoordinator:getOwnerRevision()
    return {
        epoch         = self.epoch,
        changeCounter = self.changeCounter,
        ageThroughDay = self.materialDown ~= nil and self.materialDown.ageAppliedThroughDay or nil,
        wetThroughDay = self.materialWetness ~= nil and self.materialWetness.appliedThroughDay or nil,
    }
end

function GroundConditionCoordinator:bumpRevision(why)
    self.changeCounter = self.changeCounter + 1
    if why ~= nil then
        SoilLogger.debug("[GroundCoord] revision -> %d:%d (%s)", self.epoch, self.changeCounter, tostring(why))
    end
    return self.changeCounter
end

--- True when the two stamps describe the same owner state. Used to validate a
--- snapshot before AND after, so a snapshot taken across a change is refused
--- rather than published as coherent.
function GroundConditionCoordinator.revisionsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a.epoch == b.epoch
       and a.changeCounter == b.changeCounter
       and a.ageThroughDay == b.ageThroughDay
       and a.wetThroughDay == b.wetThroughDay
end

-- =========================================================
-- Section 6: availability overlay
-- =========================================================

local function cellKey(gx, gz)
    return string.format("%d:%d", gx, gz)
end

GroundConditionCoordinator.cellKey = cellKey

function GroundConditionCoordinator:markUnavailable(gx, gz, reason, skipMembership)
    local key = cellKey(gx, gz)
    if self.unavailable[key] == nil then
        self.unavailableCount = self.unavailableCount + 1
    end
    self.unavailable[key] = reason or "UNKNOWN"
    self:bumpRevision("availability")
    -- Section 5: a cell we cannot vouch for may hold material; it is a member, so
    -- the settle considers it (unknown wetness is never initialised by weather).
    if not skipMembership then self:markMember(gx, gz) end
end

function GroundConditionCoordinator:isUnavailable(gx, gz)
    if self.overlayPending then return true end
    return self.unavailable[cellKey(gx, gz)] ~= nil
end

function GroundConditionCoordinator:unavailableReason(gx, gz)
    if self.overlayPending then return "RESTORING" end
    return self.unavailable[cellKey(gx, gz)]
end

--- [MAINTENANCE row 137] The mission started: every savegame item has loaded, so the store
--- decides now if nothing did it first (MaterialDown:finishLoad is idempotent), and its
--- observer ends the hold. The coordinator triggers this itself, never through the yard
--- ladder, which it does not depend on (Bob's MAJOR on #1022): an armed coordinator with
--- no armed ladder would otherwise hold every cell unavailable for the whole session. A
--- decision that somehow did not reach the observer still ends the hold, restoring nothing.
function GroundConditionCoordinator:onMissionStarted()
    local md = self.materialDown
    if md ~= nil and type(md.finishLoad) == "function" then
        pcall(md.finishLoad, md)
    end
    if self.overlayPending and (md == nil or MaterialDown == nil or md.loadState ~= MaterialDown.LOAD.PENDING) then
        self:_onStoreDecided(md ~= nil and md.loadState or nil, nil)
    end
end

--- [MAINTENANCE row 137] The store's load decided: the hold ends, and a MODERN payload's
--- overlay is restored (merged over any cell marked while the hold lasted). Every other
--- decision restores nothing, even with a payload in hand (a legacy one is kept only as
--- data): a save that did not pair cannot vouch for its overlay. This is the one place
--- that rule lives.
function GroundConditionCoordinator:_onStoreDecided(state, payload)
    self.overlayPending = false
    local restored = false
    if MaterialDown ~= nil and state == MaterialDown.LOAD.MODERN and type(payload) == "table"
       and type(payload.groundAvailability) == "table" then
        restored = self:deserialize(payload.groundAvailability)
    end
    SoilLogger.info("[GroundCoord] availability overlay %s (%d cell(s) unavailable)",
        restored and "restored from the save" or "not restored (" .. tostring(state) .. ")", self.unavailableCount)
    self:bumpRevision("overlay-decided")
end

--- Clear the overlay for one cell. PRIVATE ON PURPOSE: the only caller is the
--- successful complete-pair write below. An overlay that could be cleared by a
--- caller who merely believes the cell is fine again would be worthless, because
--- the whole point of the flag is that we could not vouch for the bytes.
function GroundConditionCoordinator:_clearUnavailable(gx, gz)
    local key = cellKey(gx, gz)
    if self.unavailable[key] ~= nil then
        self.unavailable[key] = nil
        self.unavailableCount = self.unavailableCount - 1
        self:bumpRevision("availability-cleared")
    end
end

function GroundConditionCoordinator:getUnavailableCount()
    return self.unavailableCount
end

-- =========================================================
-- Section 2: the pre-operation owner-settlement barrier
-- =========================================================

--- The trusted monotonic day. Uses the existing basis rather than a second clock:
--- the soil system's own resolver first, then the environment's monotonic day.
---@return number|nil
function GroundConditionCoordinator:currentMonotonicDay()
    local sys = self.soilSystem
    if sys ~= nil and type(sys._currentMonotonicDay) == "function" then
        local ok, day = pcall(function() return sys:_currentMonotonicDay() end)
        if ok and type(day) == "number" then return day end
    end
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env ~= nil then
        local day = tonumber(env.currentMonotonicDay) or tonumber(env.currentDay)
        if type(day) == "number" then return day end
    end
    return nil
end

--- Run the settlement barrier against PRE-OPERATION ground.
---
--- Contract rules encoded here:
---   * Synchronous, non-yielding, guarded against recursion.
---   * Each owner is walked from ITS OWN persisted cursor, oldest-first. We never
---     reset another module's cursor and never pass it a span it did not earn.
---   * A cursor that did not reach today after its settle means the settle was
---     refused or partial. We do NOT advance anything ourselves and we report the
---     barrier as failed, which makes enhanced condition unavailable for this
---     operation. Native work still runs.
---   * First installation keeps the owners' existing skip-first-period behaviour:
---     a nil cursor is not a licence to replay history, so we let the owner set
---     its own starting cursor from its own tick.
---
---@return boolean ok, string reason
function GroundConditionCoordinator:runSettlementBarrier()
    if not self.armed then
        return false, GroundConditionCoordinator.BARRIER_NOT_ARMED
    end
    if self.inBarrier then
        -- Re-entry can only mean a settlement called back into us. Refusing is the
        -- safe answer; recursing is not.
        return false, GroundConditionCoordinator.BARRIER_REENTRANT
    end

    local today = self:currentMonotonicDay()
    if today == nil then
        return false, GroundConditionCoordinator.BARRIER_NO_CLOCK
    end

    -- Already confirmed settled for today by an earlier primitive in this same
    -- native call. The owners are idempotent anyway, but this keeps a multi-cell
    -- pass from re-walking them per cell.
    if self.barrierThroughDay == today then
        return true, GroundConditionCoordinator.BARRIER_OK
    end

    self.inBarrier = true
    local ok, result = pcall(function()
        return self:_settleOwnersThrough(today)
    end)
    self.inBarrier = false

    if not ok then
        SoilLogger.warning("[GroundCoord] settlement barrier threw (%s) - condition unavailable, native work unaffected",
            tostring(result))
        return false, GroundConditionCoordinator.BARRIER_SETTLE_FAILED
    end
    if result ~= true then
        return false, GroundConditionCoordinator.BARRIER_SETTLE_FAILED
    end

    self.barrierThroughDay = today
    return true, GroundConditionCoordinator.BARRIER_OK
end

--- Walk each owner from its own cursor up to `today`. Returns true only when BOTH
--- owners actually reached today.
function GroundConditionCoordinator:_settleOwnersThrough(today)
    local down = self.materialDown
    local wet  = self.materialWetness

    -- Age first, then weather: time exists before the day's weather is applied to
    -- it. This is the same order the Time Guard registration already uses.
    local ageCursor = down.ageAppliedThroughDay
    if ageCursor == nil then
        -- First installation. Let the owner's own tick establish the cursor under
        -- its existing skip-first-period rule rather than replaying pre-install
        -- history from a span we invented.
        return false
    end
    if ageCursor < today then
        down:onAgeTick({ monotonicDay = today, boundariesCrossed = today - ageCursor })
        if down.ageAppliedThroughDay ~= today then
            return false
        end
    end

    local wetCursor = wet.appliedThroughDay
    if wetCursor == nil then
        return false
    end
    if wetCursor < today then
        wet:onConditionAccrual({ monotonicDay = today, boundariesCrossed = today - wetCursor })
        if wet.appliedThroughDay ~= today then
            -- A held day. The owner retained its cursor, which is exactly what it
            -- should do; the consequence for us is that pre-operation ground is
            -- not settled and enhanced condition is unavailable for this operation.
            return false
        end
    end

    return true
end

--- Called when the day advances so the next operation re-runs the barrier.
function GroundConditionCoordinator:invalidateBarrier()
    self.barrierThroughDay = nil
end

-- =========================================================
-- Section 2: the destination combine policy
-- =========================================================

--- Is this a component value we actually know?
local function ageIsKnown(raw)
    return type(raw) == "number" and raw > AGE_UNKNOWN and raw < AGE_CEILING
end

local function wetnessIsKnown(raw)
    return type(raw) == "number" and raw >= WET_FLOOR
end

--- Combine everything that ends up in one destination cell.
---
--- `destination` describes what SURVIVED in the whole Soil cell after the native
--- operation: { occupied = boolean, ageRaw = n|nil, wetnessRaw = n|nil }. Occupied
--- means positive tracked native material is still there; its condition is the
--- destination's own existing record.
---
--- `contributions` is the list of material that actually ARRIVED, each
--- { litres = n, ageRaw = n|nil, wetnessRaw = n|nil }.
---
--- Policy, straight from the contract:
---   * Zero-litre contributions import NEITHER unknown NOR refusal. A contributor
---     that delivered nothing is not evidence about anything.
---   * Positive unknown makes that component unknown. This outranks the ceiling:
---     if we do not know one contributor's age, we cannot honestly claim the
---     mixture is at the ceiling either.
---   * The age ceiling propagates as a refusal and is NEVER averaged into days.
---   * Otherwise the result is the oldest age and the wettest band present, which
---     preserves a worse destination rather than letting fresh material wash an
---     old record out.
---
---@return table { ageRaw, wetnessRaw }
function GroundConditionCoordinator.combine(destination, contributions)
    local counted = {}

    if type(destination) == "table" and destination.occupied then
        counted[#counted + 1] = { ageRaw = destination.ageRaw, wetnessRaw = destination.wetnessRaw }
    end
    if type(contributions) == "table" then
        for _, c in ipairs(contributions) do
            local litres = tonumber(c.litres) or 0
            if litres > 0 then
                counted[#counted + 1] = { ageRaw = c.ageRaw, wetnessRaw = c.wetnessRaw }
            end
        end
    end

    if #counted == 0 then
        -- Nothing survived and nothing arrived. This is not "unknown material": it
        -- is no material. The caller decides whether that means clear.
        return { ageRaw = nil, wetnessRaw = nil, empty = true }
    end

    local ageUnknown, ageCeiling, oldestAge = false, false, nil
    local wetUnknown, wettest = false, nil

    for _, c in ipairs(counted) do
        local a = c.ageRaw
        if ageIsKnown(a) then
            if oldestAge == nil or a > oldestAge then oldestAge = a end
        elseif a == AGE_CEILING then
            ageCeiling = true
        else
            -- nil, 0, or anything else we cannot read as a day count.
            ageUnknown = true
        end

        local w = c.wetnessRaw
        if wetnessIsKnown(w) then
            if wettest == nil or w > wettest then wettest = w end
        else
            -- WET_ABSENT on positive material means no record, which is unknown,
            -- and WET_UNKNOWN says so outright. Both land here.
            wetUnknown = true
        end
    end

    local ageResult
    if ageUnknown then
        ageResult = AGE_UNKNOWN
    elseif ageCeiling then
        ageResult = AGE_CEILING
    else
        ageResult = oldestAge or AGE_UNKNOWN
    end

    local wetResult
    if wetUnknown then
        wetResult = WET_UNKNOWN
    else
        wetResult = wettest or WET_UNKNOWN
    end

    return { ageRaw = ageResult, wetnessRaw = wetResult, empty = false }
end

-- =========================================================
-- Section 2: applying a projection to one cell
-- =========================================================

--- Write a combined result into one cell, maintaining the availability overlay.
---
---   * A complete pair write clears the overlay for that cell.
---   * A partial or refused write marks BOTH components unavailable and bumps the
---     revision. We do not roll back a landed half: the previous value is not
---     proof of what the ground now holds, and stamping it back would be inventing
---     a record. Recovery is an explicit resample, never a silent retry.
---
---@return boolean ok, string|nil reason
function GroundConditionCoordinator:applyProjection(geometry, gx, gz, projected)
    if not self.armed then return false, "NOT_ARMED" end
    if type(projected) ~= "table" or projected.empty then
        return false, "NOTHING_TO_WRITE"
    end

    local rev = self.cells.geometryRevision
    local res = self.cells:writeConditionCell(
        geometry, gx, gz, rev, projected.ageRaw, projected.wetnessRaw)

    if res.ok then
        self:_clearUnavailable(gx, gz)
        self:bumpRevision("movement")
        -- Section 5: material landed here; the cell is a member from this deposit.
        self:markMember(gx, gz)
        return true, nil
    end

    self:markUnavailable(gx, gz, res.partial and ("PARTIAL:" .. tostring(res.refused)) or tostring(res.refused))
    if res.partial then
        SoilLogger.warning(
            "[GroundCoord] cell %d,%d took a partial condition pair (%s) - both components marked " ..
            "unavailable; the native material and the surviving bytes are untouched",
            gx, gz, tostring(res.refused))
    end
    return false, res.refused
end

--- Clear a cell's condition, but ONLY when tracked native occupancy over the whole
--- Soil cell is actually zero after the completed primitive.
---
--- `occupancy` is the caller's observation: { known = boolean, positive = boolean }.
--- An unsupported or failed occupancy check is NOT permission to clear. A partial
--- removal keeps the source condition, because the material that is still there
--- still has the history it had.
---@return boolean cleared, string reason
function GroundConditionCoordinator:clearCellIfEmpty(geometry, gx, gz, occupancy)
    if not self.armed then return false, "NOT_ARMED" end
    if type(occupancy) ~= "table" or occupancy.known ~= true then
        -- We could not establish occupancy. Preserve the bytes and say we cannot
        -- vouch for them rather than clearing a record we might still need.
        self:markUnavailable(gx, gz, "OCCUPANCY_UNKNOWN")
        return false, "OCCUPANCY_UNKNOWN"
    end
    if occupancy.positive then
        return false, "STILL_OCCUPIED"
    end

    local rev = self.cells.geometryRevision
    local res = self.cells:writeConditionCell(geometry, gx, gz, rev, AGE_UNKNOWN, WET_ABSENT)
    if res.ok then
        self:_clearUnavailable(gx, gz)
        self:bumpRevision("clear")
        -- Section 5: a known whole-cell zero leaves the membership.
        self:unmarkMember(gx, gz)
        return true, "CLEARED"
    end

    self:markUnavailable(gx, gz, res.partial and ("PARTIAL:" .. tostring(res.refused)) or tostring(res.refused))
    return false, tostring(res.refused)
end

-- =========================================================
-- Section 6: save and restore of the overlay
-- =========================================================

--- The overlay travels with the condition layers. Geometry and schema are stamped
--- so a restore against a different grid refuses instead of applying yesterday's
--- cell indices to a differently shaped map.
function GroundConditionCoordinator:serialize()
    local geometry = self.cells ~= nil and self.cells:getConditionGeometry() or nil
    local cellsOut = {}
    for key, reason in pairs(self.unavailable) do
        cellsOut[#cellsOut + 1] = { key = key, reason = reason }
    end
    table.sort(cellsOut, function(a, b) return a.key < b.key end)
    return {
        schema      = 1,
        resolution  = geometry ~= nil and geometry.resolution or nil,
        terrainSize = geometry ~= nil and geometry.terrainSize or nil,
        unavailable = cellsOut,
    }
end

---@return boolean restored
function GroundConditionCoordinator:deserialize(data)
    if type(data) ~= "table" or data.schema ~= 1 then return false end
    local geometry = self.cells ~= nil and self.cells:getConditionGeometry() or nil
    if geometry == nil then return false end
    if data.resolution ~= geometry.resolution or data.terrainSize ~= geometry.terrainSize then
        SoilLogger.warning(
            "[GroundCoord] saved condition overlay was written for a %sx%s grid, live grid is %dx%d - " ..
            "overlay dropped rather than applied to the wrong cells",
            tostring(data.resolution), tostring(data.resolution), geometry.resolution, geometry.resolution)
        return false
    end

    -- [MAINTENANCE row 137] MERGED over the live overlay, never replacing it: a cell marked
    -- unavailable while the restore was on hold stays marked.
    if type(data.unavailable) == "table" then
        for _, row in ipairs(data.unavailable) do
            if type(row) == "table" and type(row.key) == "string" then
                if self.unavailable[row.key] == nil then
                    self.unavailableCount = self.unavailableCount + 1
                end
                self.unavailable[row.key] = row.reason or "UNKNOWN"
            end
        end
    end
    self:bumpRevision("restore")
    return true
end
