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

    SoilLogger.info("[OK] GroundConditionCoordinator armed (epoch %d)", self.epoch)
    return true
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

function GroundConditionCoordinator:markUnavailable(gx, gz, reason)
    local key = cellKey(gx, gz)
    if self.unavailable[key] == nil then
        self.unavailableCount = self.unavailableCount + 1
    end
    self.unavailable[key] = reason or "UNKNOWN"
    self:bumpRevision("availability")
end

function GroundConditionCoordinator:isUnavailable(gx, gz)
    return self.unavailable[cellKey(gx, gz)] ~= nil
end

function GroundConditionCoordinator:unavailableReason(gx, gz)
    return self.unavailable[cellKey(gx, gz)]
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

    self.unavailable = {}
    self.unavailableCount = 0
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
