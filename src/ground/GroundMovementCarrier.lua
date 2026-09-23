--
-- GroundMovementCarrier
--
-- RSF-F208, section 3 of GROUND-CONDITION-CONTRACT v1.5: the Soil-alone movement
-- carriers. This slice (S2a) carries the TEDDER. The Mower and Windrower follow.
--
-- WHAT A CARRIER DOES, per real processing call, in the contract's order:
--   1. If a StockGuard lease is live for this vehicle and work area, do nothing: the
--      standalone observer runs only when no lease is live for that primitive
--      (section 2, GroundConditionAdmission:hasLiveLeaseFor).
--   2. Run the settlement barrier against PRE-operation ground. Refused means native
--      work still runs and every cell the call touches is marked unavailable; no
--      projection, and nothing known enters the carrier's account.
--   3. Open a frame, so GroundNativeObserver records this vehicle's primitives.
--   4. Per primitive, in native order: a PICKUP moves the pre-removal condition of
--      each source cell into the carrier's account, by the litres that cell actually
--      lost, and clears a source cell only when its whole-cell occupancy is known to
--      be zero; a partial removal keeps its condition. A DROP projects the account's
--      mixture onto each cell by the litres that cell actually gained, combined with
--      what survived there, through the coordinator's conservative combine.
--   5. Close the frame. The account is reconciled with the native remainder at the
--      start of every call, before any primitive reads it.
--
-- THE ACCOUNT IS NOT STOCK. It tracks the native workArea.litersToDrop only to know
-- what condition the remainder carries (Tedder.lua:296-304). The native number is the
-- truth: an account larger than it is scaled down, a native remainder larger than the
-- account is carried as unknown condition. Nothing here changes a native quantity.
--
-- P-GROUND-1, PROVISIONAL (Tyson D1 2026-09-15, Arissani's ratification owed): off
-- the ground, material keeps its captured wetness, and its age is the captured raw
-- age plus the whole days since capture, saturating at the ceiling, applied ONCE when
-- it resolves. Each component keeps its stamp, so a repeated read derives from the
-- unchanged stamp and never adds the same span twice. A missing or reversed clock
-- makes the current age unknown. The account is not saved; neither is the native
-- buffer (the Tedder has no saveToXMLFile), so nothing is re-created on reload.
--

GroundMovementCarrier = GroundMovementCarrier or {}
local C = GroundMovementCarrier

C.KIND_TEDDER = "TEDDER"
C.ACCOUNT_KEY = "_sfGroundAccount"
C.EPSILON = 1e-3
-- A cell's observed litres may differ from the native return by the density map's
-- quantisation; below this the difference is treated as none.
C.TOLERANCE = 1

local AGE_BORN, AGE_CEILING = 1, 255

C.stats = C.stats or { frames = 0, skippedLease = 0, barrierRefused = 0, projected = 0, cleared = 0, unavailable = 0 }

-- =========================================================
-- The account (P-GROUND-1)
-- =========================================================

--- The age a stamped component has NOW. Known raw ages 1..254 advance by the whole
--- days since capture and saturate at the ceiling; the ceiling stays the ceiling;
--- anything else, or a missing or reversed clock, is unknown.
function C.agedRaw(ageRaw, captureAgeDay, today)
    if ageRaw == AGE_CEILING then return AGE_CEILING end
    if type(ageRaw) ~= "number" or ageRaw < AGE_BORN or ageRaw > AGE_CEILING - 1 then return nil end
    if type(today) ~= "number" or type(captureAgeDay) ~= "number" or today < captureAgeDay then return nil end
    return math.min(AGE_CEILING, ageRaw + (today - captureAgeDay))
end

function C.accountOf(workArea)
    local acc = workArea[C.ACCOUNT_KEY]
    if acc == nil then
        acc = { components = {} }
        workArea[C.ACCOUNT_KEY] = acc
    end
    return acc
end

function C.accountTotal(acc)
    local total = 0
    for _, comp in ipairs(acc.components) do total = total + comp.litres end
    return total
end

--- Add material with its stamp. Components with the same stamp merge, so a long
--- pass does not grow the account without bound.
function C.accountAdd(acc, litres, ageRaw, wetnessRaw, captureAgeDay)
    if type(litres) ~= "number" or litres <= C.EPSILON then return end
    for _, comp in ipairs(acc.components) do
        if comp.ageRaw == ageRaw and comp.wetnessRaw == wetnessRaw and comp.captureAgeDay == captureAgeDay then
            comp.litres = comp.litres + litres
            return
        end
    end
    acc.components[#acc.components + 1] = { litres = litres, ageRaw = ageRaw, wetnessRaw = wetnessRaw, captureAgeDay = captureAgeDay }
end

--- Take litres out uniformly: every component loses the same share, so what leaves
--- carries the mixture's condition and what stays keeps it.
function C.accountRemove(acc, litres)
    local total = C.accountTotal(acc)
    if total <= C.EPSILON or type(litres) ~= "number" or litres <= 0 then return end
    local keep = math.max(0, (total - litres) / total)
    local kept = {}
    for _, comp in ipairs(acc.components) do
        comp.litres = comp.litres * keep
        if comp.litres > C.EPSILON then kept[#kept + 1] = comp end
    end
    acc.components = kept
end

--- The account's components as they are NOW, aged once from their stamps.
function C.accountResolve(acc, today)
    local out = {}
    for _, comp in ipairs(acc.components) do
        out[#out + 1] = { litres = comp.litres, ageRaw = C.agedRaw(comp.ageRaw, comp.captureAgeDay, today), wetnessRaw = comp.wetnessRaw }
    end
    return out
end

--- Make the account agree with the native remainder, which is the truth.
function C.accountReconcile(acc, nativeLitres, today)
    if type(nativeLitres) ~= "number" or nativeLitres ~= nativeLitres then return end
    local total = C.accountTotal(acc)
    if total > nativeLitres + C.EPSILON then
        C.accountRemove(acc, total - math.max(0, nativeLitres))
    elseif nativeLitres > total + C.EPSILON then
        -- Material the account never saw arrive: its condition is unknown.
        C.accountAdd(acc, nativeLitres - total, nil, nil, today)
    end
end

-- =========================================================
-- Reading and projecting one cell
-- =========================================================

--- The condition record a cell holds now, or nils when it cannot be vouched for.
local function cellCondition(frame, gx, gz)
    local coord = frame.coordinator
    if coord:isUnavailable(gx, gz) then return nil, nil end
    local rec = frame.cells:readConditionCell(frame.geometry, gx, gz)
    if rec == nil or rec.refused ~= nil or not rec.ageAvailable or not rec.wetnessAvailable then return nil, nil end
    return rec.ageRaw, rec.wetnessRaw
end

local function markUnavailable(frame, cell, reason)
    frame.coordinator:markUnavailable(cell.gx, cell.gz, reason)
    C.stats.unavailable = C.stats.unavailable + 1
end

--- Handler: before the native call, capture the condition of every cell it may touch.
function C.beforePrimitive(frame, prim)
    if prim.cells == nil or not frame.barrierOk then return end
    for _, cell in ipairs(prim.cells) do
        cell.ageRaw, cell.wetnessRaw = cellCondition(frame, cell.gx, cell.gz)
    end
end

--- Handler: the native primitive returned.
function C.onPrimitive(frame, prim)
    local acc = frame.account
    local litres = tonumber(prim.litres) or 0
    local ft = prim.fillTypeIndex

    -- Unobservable envelope: native moved material we cannot place. Whatever it
    -- picked up is of unknown condition; whatever it dropped leaves the account.
    if prim.cells == nil then
        if prim.pickup and litres < 0 then C.accountAdd(acc, -litres, nil, nil, frame.today) end
        if not prim.pickup and litres > 0 then C.accountRemove(acc, litres) end
        return
    end

    if not frame.barrierOk then
        -- The barrier refused: native work ran, no projection, and every cell whose
        -- occupancy changed (or cannot be read) is marked unavailable.
        for _, cell in ipairs(prim.cells) do
            local b, a = cell.before, cell.after
            if b == nil or a == nil or math.abs((a[ft] or 0) - (b[ft] or 0)) > C.EPSILON then
                markUnavailable(frame, cell, "BARRIER:" .. tostring(frame.barrierReason))
            end
        end
        if prim.pickup and litres < 0 then C.accountAdd(acc, -litres, nil, nil, frame.today) end
        if not prim.pickup and litres > 0 then C.accountRemove(acc, litres) end
        return
    end

    if prim.pickup then
        local picked, seen = -litres, 0
        for _, cell in ipairs(prim.cells) do
            local b, a = cell.before, cell.after
            if b == nil or a == nil then
                -- Unreadable occupancy: not permission to clear, not a source we can price.
                markUnavailable(frame, cell, "OCCUPANCY_UNKNOWN")
            else
                local removed = (b[ft] or 0) - (a[ft] or 0)
                if removed > C.EPSILON then
                    seen = seen + removed
                    C.accountAdd(acc, removed, cell.ageRaw, cell.wetnessRaw, frame.today)
                    if (cell.afterWhole or 0) <= C.EPSILON then
                        local cleared = frame.coordinator:clearCellIfEmpty(frame.geometry, cell.gx, cell.gz, { known = true, positive = false })
                        if cleared then C.stats.cleared = C.stats.cleared + 1 end
                    end
                end
            end
        end
        -- Litres the native call took that no cell accounts for carry no known history.
        if picked - seen > C.TOLERANCE then C.accountAdd(acc, picked - seen, nil, nil, frame.today) end
        return
    end

    -- A drop: the account's mixture, aged once, lands where the cells gained.
    local dropped = litres
    if dropped <= C.EPSILON then return end
    local mixture = C.accountResolve(acc, frame.today)
    local total = 0
    for _, m in ipairs(mixture) do total = total + m.litres end
    -- Dropped litres the account cannot explain are of unknown condition.
    if dropped > total + C.TOLERANCE then
        mixture[#mixture + 1] = { litres = dropped - total, ageRaw = nil, wetnessRaw = nil }
        total = dropped
    end
    for _, cell in ipairs(prim.cells) do
        local b, a = cell.before, cell.after
        if b == nil or a == nil then
            markUnavailable(frame, cell, "OCCUPANCY_UNKNOWN")
        else
            local arrived = (a[ft] or 0) - (b[ft] or 0)
            if arrived > C.EPSILON then
                -- The parts must account for the native whole-cell occupancy, or the
                -- projection cannot be vouched for (reference bar: "native positive
                -- occupancy cannot be hidden by empty parts").
                local surviving = cell.beforeWhole or 0
                if math.abs(surviving + arrived - (cell.afterWhole or 0)) > C.TOLERANCE then
                    markUnavailable(frame, cell, "OCCUPANCY_MISMATCH")
                else
                    local contributions = {}
                    for _, m in ipairs(mixture) do
                        contributions[#contributions + 1] = { litres = total > 0 and m.litres * arrived / total or 0, ageRaw = m.ageRaw, wetnessRaw = m.wetnessRaw }
                    end
                    local destination = { occupied = surviving > C.EPSILON, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }
                    local combined = GroundConditionCoordinator.combine(destination, contributions)
                    if not combined.empty then
                        local ok = frame.coordinator:applyProjection(frame.geometry, cell.gx, cell.gz, combined)
                        if ok then C.stats.projected = C.stats.projected + 1 end
                    end
                end
            end
        end
    end
    C.accountRemove(acc, dropped)
end

--- Handler: the native primitive raised. Its cells may hold a partial native write,
--- so they cannot be vouched for; nothing is projected and the account is untouched.
function C.onPrimitiveFailed(frame, prim)
    for _, cell in ipairs(prim.cells or {}) do
        markUnavailable(frame, cell, "NATIVE_ERROR")
    end
end

-- =========================================================
-- Begin and finish one processing call
-- =========================================================

--- Before the native processing call. Returns the frame to close afterwards, or nil
--- when this call is not the standalone carrier's to observe.
---@param system table        the SoilFertilitySystem (its ground coordinator, cells, admission)
---@param vehicle table
---@param workArea table
---@param kind string         C.KIND_TEDDER
---@param nativeRemainder function|nil  (workArea) -> the native remainder the account tracks
---@return table|nil frame
function C.begin(system, vehicle, workArea, kind, nativeRemainder)
    if g_server == nil or type(system) ~= "table" or type(vehicle) ~= "table" or type(workArea) ~= "table" then return nil end
    if not vehicle.isServer then return nil end
    local coord, cells, admission = system.groundConditionCoordinator, system.groundConditionCells, system.groundConditionAdmission
    if coord == nil or not coord:isArmed() or cells == nil then return nil end
    if admission ~= nil and admission:hasLiveLeaseFor(vehicle, workArea) then
        C.stats.skippedLease = C.stats.skippedLease + 1
        return nil
    end
    local geometry = cells:getConditionGeometry()
    if geometry == nil then return nil end
    local today = coord:currentMonotonicDay()
    local ok, reason = coord:runSettlementBarrier()
    if not ok then C.stats.barrierRefused = C.stats.barrierRefused + 1 end
    local acc = C.accountOf(workArea)
    if nativeRemainder ~= nil then C.accountReconcile(acc, nativeRemainder(workArea), today) end
    C.stats.frames = C.stats.frames + 1
    return GroundNativeObserver.open({
        owner = vehicle, workArea = workArea, kind = kind, handler = C,
        coordinator = coord, cells = cells, geometry = geometry, today = today,
        barrierOk = ok, barrierReason = reason, account = acc,
    })
end

--- After the native processing call, whether it returned or raised. The account is
--- reconciled with the native remainder at the NEXT begin, before any primitive can
--- read it, so a change made between calls (another mod clearing the remainder) is
--- caught where it matters.
function C.finish(frame)
    if frame == nil then return end
    GroundNativeObserver.close(frame)
end

--- The Tedder's native remainder (Tedder.lua:297, :304).
function C.tedderRemainder(workArea)
    return tonumber(workArea.litersToDrop) or 0
end
