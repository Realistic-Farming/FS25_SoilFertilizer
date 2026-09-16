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
--       -> { groundCondition = { admissionRevision = 1 } }
--   g_currentMission.soilFertilityManager.groundCondition.admitPrimitive(
--       footprint, primitiveKind, vehicleOrObject, workAreaIdentity)
--       -> { status = "ADMITTED"|"REFUSED", reason, leaseToken }
--   g_currentMission.soilFertilityManager.groundCondition.deliverMovement(
--       leaseToken, observation)
--
-- WHY THE CAPABILITY MATTERS MORE THAN THE TABLE. A consumer must decide whether
-- Soil can actually receive a delivery. The contract is explicit that a registered
-- `soil.groundCondition` property is NOT proof of that, and neither is StockGuard's
-- own capability list. Only this getter, returning admissionRevision 1, means the
-- interface is present. So we publish the capability ONLY when the coordinator is
-- genuinely armed: if the condition cells stood down, getCapabilities reports no
-- groundCondition at all and every consumer correctly treats Soil as absent.
--
-- ABSENT IS THE NORMAL PATH. On the consumer side, absent means: suppress nothing,
-- deliver nothing, keep observing quantities, report live ground condition
-- unavailable. That is the state that ships today for every player who does not
-- run StockGuard, and it is the state that ships even with StockGuard until the
-- section 3 movement carriers land. Nothing here is a hard dependency in either
-- direction.
--
-- DOT CALLS, NOT COLON CALLS. The contract names these as plain functions on the
-- groundCondition table, so they are closures, not methods. A caller who writes
-- `groundCondition:admitPrimitive(...)` would silently shift every argument by one
-- and hand us the table as the footprint. We detect that and refuse loudly rather
-- than quietly treating a table as ground.
--

GroundConditionAdmission = {}
local GroundConditionAdmission_mt = Class(GroundConditionAdmission)

GroundConditionAdmission.ADMISSION_REVISION = 1

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
-- Leases
-- =========================================================

local function currentFrameIndex()
    -- Real engine global, incremented once per update loop and wrapped at 2^30
    -- (engine main.lua:777-779). Equality is therefore a sound same-frame test for
    -- a lease that by contract cannot outlive one primitive.
    local n = rawget(_G, "g_updateLoopIndex")
    return type(n) == "number" and n or nil
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
    self.leases[token] = {
        token         = token,
        primitiveKind = primitiveKind,
        owner         = vehicleOrObject,
        workArea      = workAreaIdentity,
        geometry      = geometry,
        frameIndex    = currentFrameIndex(),
        open          = true,
        deliveries    = 0,
    }
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
    local now = currentFrameIndex()
    if lease.frameIndex ~= nil and now ~= nil and now ~= lease.frameIndex then
        lease.open = false
        self.openLeases = self.openLeases - 1
        return nil, GroundConditionAdmission.DELIVER_STALE_FRAME
    end
    return lease, nil
end

--- Deliver one completed elementary movement.
---
--- Soil projects movement ONLY in this call, immediately after the primitive and
--- before the caller returns to the running native processing delegate. The
--- existing HayBet post-delegate drying effect is NOT run here: it runs once at the
--- enclosing processing end, after every elementary delivery, which is what keeps a
--- legitimate tedding effect from being overwritten by a late projection.
---
--- `observation` is the caller's record of what actually happened:
---   { cells = { { gx, gz,
---                 destination = { occupied, ageRaw, wetnessRaw },
---                 contributions = { { litres, ageRaw, wetnessRaw }, ... },
---                 occupancy = { known, positive } }, ... } }
---@return table { status, reason, projected, refusedCells }
function GroundConditionAdmission:_deliverMovement(leaseToken, observation)
    if not self.armed then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.REFUSE_NOT_ARMED }
    end

    local lease, refusal = self:_resolveLease(leaseToken)
    if lease == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED, reason = refusal }
    end
    if type(observation) ~= "table" or type(observation.cells) ~= "table" then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.DELIVER_BAD_OBS }
    end

    local projected, refusedCells = 0, 0
    for _, cell in ipairs(observation.cells) do
        local gx, gz = cell.gx, cell.gz
        if type(gx) == "number" and type(gz) == "number" then
            local combined = GroundConditionCoordinator.combine(cell.destination, cell.contributions)
            if combined.empty then
                -- Nothing survived and nothing arrived. Clearing is allowed only on
                -- a KNOWN zero occupancy; the coordinator enforces that.
                local cleared = self.coordinator:clearCellIfEmpty(lease.geometry, gx, gz, cell.occupancy)
                if cleared then projected = projected + 1 else refusedCells = refusedCells + 1 end
            else
                local ok = self.coordinator:applyProjection(lease.geometry, gx, gz, combined)
                if ok then projected = projected + 1 else refusedCells = refusedCells + 1 end
            end
        else
            refusedCells = refusedCells + 1
        end
    end

    lease.deliveries = lease.deliveries + 1
    return {
        status       = GroundConditionAdmission.STATUS_ADMITTED,
        reason       = GroundConditionAdmission.DELIVER_OK,
        projected    = projected,
        refusedCells = refusedCells,
    }
end

--- Close the lease. The contract says the lease closes with the primitive; this is
--- how the caller says the primitive is done.
function GroundConditionAdmission:_closePrimitive(leaseToken)
    local lease = type(leaseToken) == "string" and self.leases[leaseToken] or nil
    if lease == nil then
        return { status = GroundConditionAdmission.STATUS_REFUSED,
                 reason = GroundConditionAdmission.DELIVER_NO_LEASE }
    end
    if lease.open then
        lease.open = false
        self.openLeases = self.openLeases - 1
    end
    self.leases[leaseToken] = nil
    return { status = GroundConditionAdmission.STATUS_ADMITTED, deliveries = lease.deliveries }
end

--- True while any lease is live for this primitive identity. Section 7 says Soil
--- must not install, fire or post-delegate its STANDALONE observer for a primitive
--- while a lease is live for it. Section 3's carriers are the caller; this is the
--- question they will ask.
function GroundConditionAdmission:hasLiveLeaseFor(vehicleOrObject, workAreaIdentity)
    for _, lease in pairs(self.leases) do
        if lease.open and lease.owner == vehicleOrObject and lease.workArea == workAreaIdentity then
            return true
        end
    end
    return false
end

function GroundConditionAdmission:getOpenLeaseCount()
    return self.openLeases
end
