--
-- GroundConditionAdmission
--
-- RSF-F208, section 7 of GROUND-CONDITION-CONTRACT v1.5: the interface StockGuard
-- SG-2 calls, and the capability that tells it the interface is really here.
--
-- THE SHAPE, fixed by the contract and by Iris' D2 answer of 2026-09-16, in these
-- exact words and on this exact handle:
--
--   g_currentMission.soilFertilityManager:getCapabilities()
--       -> { groundCondition = { admissionRevision = 2 } }
--   g_currentMission.soilFertilityManager.groundCondition.admitPrimitive(
--       footprint, primitiveKind, vehicleOrObject, workAreaIdentity)
--       -> { status = "ADMITTED"|"REFUSED", reason, leaseToken }
--   g_currentMission.soilFertilityManager.groundCondition.deliverMovement(
--       leaseToken, observation)
--
-- ADMISSION REVISION 2 (SG2-4 S3, Iris's answer 2 of 2026-09-23, Bob's intake of
-- 2026-09-23): the public input of deliverMovement is StockGuard's admitted NATIVE
-- observation, not caller-chosen Soil cells with a precomputed mixture. Soil derives
-- the Soil cells itself, from the FOOTPRINT the caller gives admitPrimitive, reads
-- each cell's whole-cell occupancy BEFORE the primitive (the one call Soil receives
-- before it) and again at delivery, captures each cell's pre-removal condition at
-- admit, and projects through the one projector it shares with its standalone
-- carriers (GroundMovementProjector). A revision 1 caller sending a cells array is
-- refused; StockGuard gates on 2 and treats an older Soil as absent (D2 rule).
--
--   footprint v1 (the caller's resolved primitive geometry, world coordinates):
--     { schemaVersion = 1, kind = "LINE", sx, sz, ex, ez, fillTypeIndex,
--       innerRadius, radius }                  for TIP_TO_GROUND_AROUND_LINE and
--                                              SMOOTH_AROUND_LINE; radius nil means
--                                              the native default for that type
--     { schemaVersion = 1, kind = "AREA", x0, z0, x1, z1, x2, z2 }
--                                              for CLEAR_AREA and
--                                              CHANGE_FILL_TYPE_AT_AREA
--   observation v1 (native facts StockGuard observed on that call, nothing
--   Soil-grid-shaped):
--     { schemaVersion = 1, primitiveKind, ok, fillTypeIndex, deltaRequested,
--       litresReturned, lineOffset, sourceTypeIndex, destinationTypeIndex,
--       conversionBasis }
--   `ok = false` means the primitive threw: every lease cell goes unavailable.
--
-- WHY THE CAPABILITY MATTERS MORE THAN THE TABLE. A consumer must decide whether
-- Soil can actually receive a delivery. The contract is explicit that a registered
-- `soil.groundCondition` property is NOT proof of that, and neither is StockGuard's
-- own capability list. Only this getter, returning the admission revision, means the
-- interface is present. So we publish the capability ONLY when the coordinator is
-- genuinely armed: if the condition cells stood down, getCapabilities reports no
-- groundCondition at all and every consumer correctly treats Soil as absent.
--
-- ABSENT IS THE NORMAL PATH. On the consumer side, absent means: suppress nothing,
-- deliver nothing, keep observing quantities, report live ground condition
-- unavailable. Nothing here is a hard dependency in either direction.
--
-- DOT CALLS, NOT COLON CALLS. The contract names these as plain functions on the
-- groundCondition table, so they are closures, not methods. A caller who writes
-- `groundCondition:admitPrimitive(...)` would silently shift every argument by one
-- and hand us the table as the footprint. We detect that and refuse loudly rather
-- than quietly treating a table as ground.
--
-- THE ADMISSION COUNT. StockGuard admits at the engine global inside the Lua util
-- Soil's own observer wraps (DensityMapHeightUtil.lua:290), so the observer cannot
-- see that lease before or after its native call. The count of admitted leases is
-- what the observer compares across its native call: the util's call is synchronous,
-- so a lease admitted during it can only be the inner slot's lease for that very
-- primitive, whatever identity the inner caller names; the observer stands aside when
-- the count moved (Bob's intake item 3b). A refused inner admission mints no lease,
-- so Soil's own observation then stands, projecting or marking as it would alone.
--

GroundConditionAdmission = {}
local GroundConditionAdmission_mt = Class(GroundConditionAdmission)

GroundConditionAdmission.ADMISSION_REVISION  = 2
GroundConditionAdmission.FOOTPRINT_SCHEMA    = 1
GroundConditionAdmission.OBSERVATION_SCHEMA  = 1

GroundConditionAdmission.STATUS_ADMITTED = "ADMITTED"
GroundConditionAdmission.STATUS_REFUSED  = "REFUSED"

GroundConditionAdmission.REFUSE_NOT_ARMED   = "SOIL_NOT_ARMED"
GroundConditionAdmission.REFUSE_BARRIER     = "SETTLEMENT_BARRIER_REFUSED"
GroundConditionAdmission.REFUSE_ARGS        = "BAD_ARGUMENTS"
GroundConditionAdmission.REFUSE_COLON_CALL  = "CALLED_WITH_COLON"
GroundConditionAdmission.REFUSE_NO_GEOMETRY = "NO_GEOMETRY"

GroundConditionAdmission.DELIVER_OK            = "OK"
GroundConditionAdmission.DELIVER_NO_LEASE      = "NO_SUCH_LEASE"
GroundConditionAdmission.DELIVER_LEASE_CLOSED  = "LEASE_CLOSED"
GroundConditionAdmission.DELIVER_STALE_FRAME   = "LEASE_CROSSED_A_FRAME"
GroundConditionAdmission.DELIVER_BAD_OBS       = "BAD_OBSERVATION"

-- The primitive kinds a lease can name (Bob's SG2 chain intake: the four
-- DensityMapHeightUtil primitives SG2-4 brackets) and the footprint shape each takes.
GroundConditionAdmission.KIND_TIP_LINE    = "TIP_TO_GROUND_AROUND_LINE"
GroundConditionAdmission.KIND_SMOOTH_LINE = "SMOOTH_AROUND_LINE"
GroundConditionAdmission.KIND_CLEAR_AREA  = "CLEAR_AREA"
GroundConditionAdmission.KIND_CHANGE_TYPE = "CHANGE_FILL_TYPE_AT_AREA"
GroundConditionAdmission.KIND_SHAPE = {
    [GroundConditionAdmission.KIND_TIP_LINE]    = "LINE",
    [GroundConditionAdmission.KIND_SMOOTH_LINE] = "LINE",
    [GroundConditionAdmission.KIND_CLEAR_AREA]  = "AREA",
    [GroundConditionAdmission.KIND_CHANGE_TYPE] = "AREA",
}

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- =========================================================
-- Construction and bind
-- =========================================================

function GroundConditionAdmission.new()
    local self = setmetatable({}, GroundConditionAdmission_mt)
    self.armed       = false
    self.coordinator = nil
    self.cells       = nil
    self.leases      = {}    -- token -> lease
    self.leaseSeq    = 0
    self.openLeases  = 0
    -- Published table. Built once at arm() so the consumer's captured reference
    -- stays valid; torn down on stand-down so a stale reference cannot be used to
    -- deliver into a Soil that is no longer listening.
    self.groundCondition = nil
    return self
end

---@return boolean armed
function GroundConditionAdmission:arm(coordinator, cells)
    self.armed = false
    self.groundCondition = nil
    self.leases = {}
    self.openLeases = 0

    if g_server == nil then
        -- Server-local by contract. A client never admits a primitive.
        return false
    end
    if coordinator == nil or not coordinator:isArmed() or cells == nil or not cells:isArmed() then
        SoilLogger.info("[GroundAdmit] ground condition is unavailable - the admission interface is NOT published " ..
            "(consumers will correctly treat Soil as absent for this join)")
        return false
    end

    self.coordinator = coordinator
    self.cells       = cells

    local admit = function(footprint, primitiveKind, vehicleOrObject, workAreaIdentity)
        return self:_admitPrimitive(footprint, primitiveKind, vehicleOrObject, workAreaIdentity)
    end
    local deliver = function(leaseToken, observation)
        return self:_deliverMovement(leaseToken, observation)
    end
    local close = function(leaseToken)
        return self:_closePrimitive(leaseToken)
    end

    self.groundCondition = {
        admissionRevision = GroundConditionAdmission.ADMISSION_REVISION,
        admitPrimitive    = admit,
        deliverMovement   = deliver,
        closePrimitive    = close,
    }
    self.armed = true
    SoilLogger.info("[OK] GroundConditionAdmission published (admissionRevision %d)",
        GroundConditionAdmission.ADMISSION_REVISION)
    return true
end

function GroundConditionAdmission:isArmed()
    return self.armed
end

function GroundConditionAdmission:standDown(why)
    if self.armed then
        SoilLogger.warning("[GroundAdmit] withdrawing the admission interface: %s", tostring(why))
    end
    self.armed = false
    self.groundCondition = nil
    self.leases = {}
    self.openLeases = 0
end

--- The capability table. Publishing `groundCondition` here is the ONLY promise a
--- consumer may act on. When we are not armed the key is absent entirely, which is
--- what makes "Soil is absent for this join" the honest default.
function GroundConditionAdmission:getCapabilities()
    if not self.armed then
        return {}
    end
    return {
        groundCondition = {
            admissionRevision = GroundConditionAdmission.ADMISSION_REVISION,
        },
    }
end

-- =========================================================
-- The footprint and the observation
-- =========================================================

--- Validate a v1 footprint against the kind's shape. Returns a detached copy of the
--- fields Soil uses, or nil.
local function validFootprint(footprint, shape)
    if footprint.schemaVersion ~= GroundConditionAdmission.FOOTPRINT_SCHEMA then return nil end
    if footprint.kind ~= shape then return nil end
    if shape == "LINE" then
        if not (finite(footprint.sx) and finite(footprint.sz) and finite(footprint.ex) and finite(footprint.ez)) then return nil end
        if type(footprint.fillTypeIndex) ~= "number" then return nil end
        local inner, outer = footprint.innerRadius, footprint.radius
        if inner ~= nil and not (finite(inner) and inner >= 0) then return nil end
        if outer ~= nil and not (finite(outer) and outer >= 0) then return nil end
        return { kind = "LINE", sx = footprint.sx, sz = footprint.sz, ex = footprint.ex, ez = footprint.ez,
                 fillTypeIndex = footprint.fillTypeIndex, innerRadius = inner or 0, radius = outer }
    end
    if not (finite(footprint.x0) and finite(footprint.z0) and finite(footprint.x1) and finite(footprint.z1)
            and finite(footprint.x2) and finite(footprint.z2)) then return nil end
    return { kind = "AREA", x0 = footprint.x0, z0 = footprint.z0, x1 = footprint.x1, z1 = footprint.z1,
             x2 = footprint.x2, z2 = footprint.z2 }
end

--- Validate a v1 observation against its lease: the same primitive, native facts
--- only, the types consistent with the kind, finite quantities. Returns nil when it
--- cannot be joined.
local function validObservation(observation, lease)
    if type(observation) ~= "table" then return nil end
    -- A caller-supplied cells array is the revision 1 shape and never an input now:
    -- Soil derives its own cells (Iris's answer 2).
    if observation.cells ~= nil then return nil end
    if observation.schemaVersion ~= GroundConditionAdmission.OBSERVATION_SCHEMA then return nil end
    if observation.primitiveKind ~= lease.primitiveKind then return nil end
    if type(observation.ok) ~= "boolean" then return nil end
    local obs = { ok = observation.ok, conversionBasis = observation.conversionBasis }
    if not observation.ok then return obs end
    local kind = lease.primitiveKind
    if kind == GroundConditionAdmission.KIND_TIP_LINE then
        if observation.fillTypeIndex ~= lease.footprint.fillTypeIndex then return nil end
        if not (finite(observation.deltaRequested) or observation.deltaRequested == -math.huge) then return nil end
        if not finite(observation.litresReturned) then return nil end
        obs.fillTypeIndex, obs.deltaRequested, obs.litresReturned = observation.fillTypeIndex, observation.deltaRequested, observation.litresReturned
        obs.lineOffset = observation.lineOffset
    elseif kind == GroundConditionAdmission.KIND_CHANGE_TYPE then
        if type(observation.sourceTypeIndex) ~= "number" or type(observation.destinationTypeIndex) ~= "number" then return nil end
        if observation.litresReturned ~= nil and not finite(observation.litresReturned) then return nil end
        obs.sourceTypeIndex, obs.destinationTypeIndex, obs.litresReturned = observation.sourceTypeIndex, observation.destinationTypeIndex, observation.litresReturned
    else
        -- SMOOTH_AROUND_LINE and CLEAR_AREA return nothing the join needs.
        if observation.litresReturned ~= nil and not finite(observation.litresReturned) then return nil end
        obs.litresReturned = observation.litresReturned
    end
    return obs
end

-- =========================================================
-- Leases
-- =========================================================

local function currentFrameIndex()
    -- Real engine global, incremented once per update loop and wrapped at 2^30
    -- (engine main.lua:777-779). Equality is therefore a sound same-frame test for
    -- a lease that by contract cannot outlive one primitive.
    local n = rawget(_G, "g_updateLoopIndex")
    return type(n) == "number" and n or nil
end

--- How many leases have been admitted since arming. The standalone observer compares
--- it across its native call (header, the admission count).
function GroundConditionAdmission:admissionCount()
    return self.leaseSeq
end

--- Derive the lease's cells from the footprint, read their whole-cell occupancy
--- before the primitive and capture their pre-removal condition.
function GroundConditionAdmission:_prepareLease(lease)
    local O = GroundNativeObserver
    local fp = lease.footprint
    local cells, why
    lease.heightMapValid = O.heightMapValid()
    if fp.kind == "LINE" then
        local outer = fp.radius
        if outer == nil then outer = O.defaultRadius(fp.fillTypeIndex) end
        lease.reach = fp.innerRadius + outer
        cells, why = O.envelopeCells(lease.geometry, fp.sx, fp.sz, fp.ex, fp.ez, lease.reach)
    else
        cells, why = O.parallelogramCells(lease.geometry, fp.x0, fp.z0, fp.x1, fp.z1, fp.x2, fp.z2)
    end
    if cells == nil then
        lease.derived, lease.envelopeRefused = nil, why
        O.stats.refusedEnvelopes = O.stats.refusedEnvelopes + 1
        return
    end
    if #cells > O.MAX_CELLS then
        -- Too many cells to read. Keep the indices, read nothing: the delivery marks
        -- them all unavailable rather than let old records stand.
        lease.derived, lease.unobservable, lease.envelopeRefused = cells, true, "ENVELOPE_TOO_LARGE"
        O.stats.refusedEnvelopes = O.stats.refusedEnvelopes + 1
        return
    end
    if not lease.heightMapValid then
        -- No height map to read: the native returns zero for every area, which is not
        -- an observation. Keep the indices; the delivery marks them all unavailable.
        lease.derived, lease.unobservable, lease.envelopeRefused = cells, true, "HEIGHT_MAP_INVALID"
        return
    end
    lease.typeIndices, lease.windrowSet = O.occupancySets(fp.fillTypeIndex)
    for _, cell in ipairs(cells) do
        cell.before, cell.beforeWhole = O.readCell(cell, lease.typeIndices, lease.windrowSet)
    end
    O.stats.cellsRead = O.stats.cellsRead + #cells
    GroundMovementProjector.captureCells(lease, cells)
    lease.derived = cells
end

--- A lease is bound to the primitive, the vehicle or object, and the work area.
--- Anything else delivering against it is a different operation and is refused.
function GroundConditionAdmission:_admitPrimitive(footprint, primitiveKind, vehicleOrObject, workAreaIdentity)
    if not self.armed then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_NOT_ARMED }
    end

    -- A colon call would land the published table itself in `footprint`.
    if footprint == self.groundCondition then
        SoilLogger.warning("[GroundAdmit] admitPrimitive was called with a colon; it is a plain function on " ..
            "the groundCondition table. Refusing rather than reading the table as a footprint.")
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_COLON_CALL }
    end
    if type(footprint) ~= "table" or type(primitiveKind) ~= "string" then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_ARGS }
    end
    local shape = GroundConditionAdmission.KIND_SHAPE[primitiveKind]
    local fp = shape ~= nil and validFootprint(footprint, shape) or nil
    if fp == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_ARGS }
    end

    local geometry = self.cells:getConditionGeometry()
    if geometry == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_NO_GEOMETRY }
    end

    -- THE BARRIER RUNS HERE, against PRE-OPERATION ground, and this call returns
    -- before the caller performs any native pickup, deposit, brush or conversion.
    -- The caller never runs or advances a Soil cursor; that is the whole point of
    -- making them ask us first.
    local ok, reason = self.coordinator:runSettlementBarrier()
    if not ok then
        -- Refused: no lease. Native work runs, the caller observes quantities, and
        -- incoming condition is unknown. This is not an error.
        return { status = GroundConditionAdmission.STATUS_REFUSED, reason = reason }
    end

    self.leaseSeq = self.leaseSeq + 1
    local token = string.format("SFGC-%d-%d", self.coordinator.epoch, self.leaseSeq)
    local lease = {
        token         = token,
        primitiveKind = primitiveKind,
        owner         = vehicleOrObject,
        workArea      = workAreaIdentity,
        geometry      = geometry,
        footprint     = fp,
        frameIndex    = currentFrameIndex(),
        open          = true,
        deliveries    = 0,
        -- The projector's context: this lease's coordinator, the condition cells
        -- surface and the geometry; the derived Soil cells go to lease.derived.
        coordinator   = self.coordinator,
        cells         = self.cells,
        stats         = { projected = 0, cleared = 0, unavailable = 0 },
    }
    self:_prepareLease(lease)
    self.leases[token] = lease
    self.openLeases = self.openLeases + 1

    return { status = GroundConditionAdmission.STATUS_ADMITTED, leaseToken = token }
end

--- Resolve a lease for use, applying the lifetime rules.
---@return table|nil lease, string|nil refusal
function GroundConditionAdmission:_resolveLease(leaseToken)
    if type(leaseToken) ~= "string" then
        return nil, GroundConditionAdmission.DELIVER_NO_LEASE
    end
    local lease = self.leases[leaseToken]
    if lease == nil then
        return nil, GroundConditionAdmission.DELIVER_NO_LEASE
    end
    if not lease.open then
        return nil, GroundConditionAdmission.DELIVER_LEASE_CLOSED
    end
    -- A lease closes with its primitive and is never held across frames. A delivery
    -- arriving in a later frame is a different operation against ground that may
    -- have moved on, so it is refused rather than projected onto stale cells.
    if self:_expireIfStale(lease) then
        return nil, GroundConditionAdmission.DELIVER_STALE_FRAME
    end
    return lease, nil
end

--- The frame rule: a lease from an earlier update frame is closed and its cells, if
--- nothing was accepted for them, marked; it is then neither deliverable nor live.
---@return boolean expired
function GroundConditionAdmission:_expireIfStale(lease)
    if not lease.open then return false end
    local now = currentFrameIndex()
    if lease.frameIndex ~= nil and now ~= nil and now ~= lease.frameIndex then
        self:_markUndelivered(lease, "LEASE_CROSSED_A_FRAME")
        lease.open = false
        self.openLeases = self.openLeases - 1
        return true
    end
    return false
end

--- Deliver one completed elementary movement.
---
--- Soil projects movement ONLY in this call, immediately after the primitive and
--- before the caller returns to the running native processing delegate. The
--- existing HayBet post-delegate drying effect is NOT run here: it runs once at the
--- enclosing processing end, after every elementary delivery, which is what keeps a
--- legitimate tedding effect from being overwritten by a late projection.
---
--- `observation` is the v1 native observation (header). Soil reads the lease cells'
--- occupancy again, works out per cell what was lost or gained, and projects through
--- GroundMovementProjector: a pickup's source cells cleared only on a known whole-cell
--- zero, a drop's arrivals of unknown condition (Soil captured nothing of the carried
--- stock), a smoothing's or clearing's losses fed onto its gains litre-weighted, a
--- conversion unknown for want of a registered basis.
---@return table { status, reason, projected, refusedCells, cleared, unavailable }
function GroundConditionAdmission:_deliverMovement(leaseToken, observation)
    if not self.armed then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_NOT_ARMED }
    end

    local lease, refusal = self:_resolveLease(leaseToken)
    if lease == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED, reason = refusal }
    end
    local obs = validObservation(observation, lease)
    if obs == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.DELIVER_BAD_OBS }
    end
    lease.deliveries = lease.deliveries + 1

    local P = GroundMovementProjector
    local cells = lease.derived
    local result = { status = GroundConditionAdmission.STATUS_ADMITTED, reason = GroundConditionAdmission.DELIVER_OK,
                     projected = 0, refusedCells = 0, cleared = 0, unavailable = 0 }

    if cells == nil then
        -- The envelope could not be placed on cells (off the map, nonfinite, unbounded):
        -- nothing to project, and nothing to mark.
        result.envelopeRefused = lease.envelopeRefused
        return result
    end
    if not obs.ok then
        -- The primitive threw: its cells may hold a partial native write, so they
        -- cannot be vouched for; nothing is projected.
        result.unavailable = P.markAll(lease, cells, "NATIVE_ERROR")
        return result
    end
    if lease.unobservable then
        -- Enumerated but not read (too large, or no height map): every cell it covers
        -- may have changed and none can be vouched for. Mark them all, keep their
        -- bytes, project nothing.
        result.unavailable = P.markAll(lease, cells, "ENVELOPE:" .. tostring(lease.envelopeRefused))
        result.envelopeRefused = lease.envelopeRefused
        return result
    end
    if not GroundNativeObserver.heightMapValid() then
        -- The height map went away between admit and delivery: an after read would be
        -- zero, not an observation.
        result.unavailable = P.markAll(lease, cells, "HEIGHT_MAP_INVALID")
        return result
    end

    -- The whole-cell occupancy after the primitive, read by Soil itself.
    for _, cell in ipairs(cells) do
        cell.after, cell.afterWhole = GroundNativeObserver.readCell(cell, lease.typeIndices, lease.windrowSet)
    end

    local kind, counts = lease.primitiveKind, nil
    if kind == GroundConditionAdmission.KIND_TIP_LINE then
        if obs.deltaRequested < 0 then
            -- A pickup: the source condition leaves with the material. StockGuard holds
            -- the material and Soil registers no condition on it, so the removals go
            -- back to the caller in this result (result.collected: litres with the
            -- captured age and wetness per source cell), the evidence F211's reader
            -- will take; the lease itself closes with the primitive and keeps nothing.
            local collected = {}
            local _, c = P.pickup(lease, cells, obs.fillTypeIndex, function(litres, ageRaw, wetnessRaw)
                collected[#collected + 1] = { litres = litres, ageRaw = ageRaw, wetnessRaw = wetnessRaw }
            end)
            result.collected = collected
            counts = c
        else
            -- A drop from carried stock: Soil captured nothing of it, so it arrives of
            -- unknown condition and the conservative combine propagates that.
            counts = P.drop(lease, cells, obs.fillTypeIndex, {}, 0)
        end
    elseif kind == GroundConditionAdmission.KIND_CHANGE_TYPE then
        counts = P.convert(lease, cells, obs.sourceTypeIndex, obs.destinationTypeIndex, false)
    else
        counts = P.redistribute(lease, cells)
    end
    result.projected   = counts.projected or 0
    result.cleared     = counts.cleared or 0
    result.unavailable = counts.unavailable or 0
    result.refusedCells = (counts.unavailable or 0) + (counts.refused or 0)
    lease.accepted = (lease.accepted or 0) + 1
    return result
end

--- A lease that ends with no accepted delivery leaves cells the native primitive may
--- have changed with records nobody vouched for: the standalone observer stood aside
--- for the admission (the count moved), so the only witness delivered nothing, or a
--- refused observation, or one in a later frame. Every cell the lease named goes
--- unavailable (Bob's verdict on #1002): bytes kept, never cleared or invented.
function GroundConditionAdmission:_markUndelivered(lease, reason)
    if (lease.accepted or 0) > 0 or lease.marked then return 0 end
    lease.marked = true
    if lease.derived == nil then return 0 end
    return GroundMovementProjector.markAll(lease, lease.derived, reason)
end

--- Close the lease. The contract says the lease closes with the primitive; this is
--- how the caller says the primitive is done.
function GroundConditionAdmission:_closePrimitive(leaseToken)
    local lease = type(leaseToken) == "string" and self.leases[leaseToken] or nil
    if lease == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.DELIVER_NO_LEASE }
    end
    local marked = self:_markUndelivered(lease, "LEASE_CLOSED_UNDELIVERED")
    if lease.open then
        lease.open = false
        self.openLeases = self.openLeases - 1
    end
    self.leases[leaseToken] = nil
    return { status = GroundConditionAdmission.STATUS_ADMITTED, deliveries = lease.deliveries, unavailable = marked }
end

--- True while any lease is live for this primitive identity. Section 7 says Soil
--- must not install, fire or post-delegate its STANDALONE observer for a primitive
--- while a lease is live for it. Section 3's carriers are the caller; this is the
--- question they will ask before the call. During the call they watch the count.
--- Live means open AND of this frame: a lease a caller never closed expires by the
--- frame rule here, so it cannot keep the standalone carrier standing aside for the
--- rest of the mission (Bob's verdict on #1002).
function GroundConditionAdmission:hasLiveLeaseFor(vehicleOrObject, workAreaIdentity)
    for _, lease in pairs(self.leases) do
        if lease.open and lease.owner == vehicleOrObject and lease.workArea == workAreaIdentity then
            if not self:_expireIfStale(lease) then
                return true
            end
        end
    end
    return false
end

function GroundConditionAdmission:getOpenLeaseCount()
    return self.openLeases
end
