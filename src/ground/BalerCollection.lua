--
-- BalerCollection
--
-- RSF-F211 part 2a (the Baler core): collected wetness follows the material that
-- actually entered the Baler's chamber, and each bale is born with the condition of
-- exactly the material it holds.
--
-- THE PRODUCER. Each Baler pickup call runs inside a carrier frame on the captured
-- processBalerArea pointer (the ground side is GroundMovementCarrier's: a pickup
-- clears a cell on a known whole-cell zero). Before each negative primitive the
-- source cells' condition is captured (MaterialWetness:collectedSnapshot, available =
-- the cell's native litres of that type); after it, each cell's removed raw litres
-- r_bi = before - after. The call's post-additive return is P_b (Baler.lua:1908-1911).
-- A collection context is open from the Baler's onStartWorkAreaProcessing to its
-- onEndWorkAreaProcessing (Baler.lua:1954, :1960); nested operations use a stack.
--
-- ACCEPTANCE. onEnd adds W = sum(P_b) * fillScale to its receiver (Baler.lua:1983-1999).
-- FillUnit raises onFillUnitFillLevelChanged(unit, D, type, tool, data, A) with the
-- applied delta A (FillUnit.lua:1203) before returning it (:1275); the Baler's own
-- listener can finish the bale inside that event (Baler.lua:1170-1175). So the seal
-- runs in the listener wrap BEFORE the original: batch b is allocated A_b = P_b*F*A/W,
-- each source q_bi = A_b * r_bi / R_b, the raw retained equivalent r_bi * A/W, and the
-- producer's seal is read back through MaterialWetness:readCollectedCondition. The
-- coverage enters the receiving unit's account.
--
-- OVERFLOW. When the main unit is full the listener finishes the bale, then assigns
-- fillUnitOverflowFillLevel = D - A (Baler.lua:1176). That observed assignment takes
-- the unaccepted part of the same produced mixture (a second seal, target O); an old
-- overflow it overwrites is retired as the native loss it is. When there is room and
-- an overflow waits, the listener clears it and re-adds it with a nested add
-- (Baler.lua:1179-1183): the nested event's applied delta moves that share of the old
-- overflow account to main, and the remainder the listener stores stays overflow. It
-- is not another ground pickup.
--
-- THE BALE. finishBale (per instance) captures the main account into its own finish
-- context before the native clears the chamber (square) or creates first (round,
-- where the still-full chamber mirrors the mounted bale). createBale (per instance)
-- opens a creation frame; Soil's Bale.register hook defers every object registered
-- inside it; on a valid return the exact record createBale appended to spec.bales
-- gets the finish context's condition, and any other object seen inside the frame is
-- born unknown. A loadFromSavegame create has no chamber sample.
--
-- ACCOUNTS. { carrier, known, unknown, refused, weighted } litres; a uniform native
-- withdrawal splits every component by the same fraction; pct only when the whole
-- positive carrier is known. Native state owns the material: an account is reconciled
-- to its unit's native level (an unseen increase is unknown, an unseen decrease is a
-- uniform withdrawal).
--
-- THE NON-STOP BUFFER (part 2b). A non-stop baler's pickup goes into its buffer unit
-- (Baler.lua:1983-1996): the same seal enters the buffer's account. Baler:onUpdateTick
-- (:996-1060) moves buffer material into the chamber: the buffer debit takes that
-- share of the buffer account, the optional additive gain scales it (the gain carries
-- its source's condition), and the chamber's add accepts A of it; a full chamber's
-- overflow D - A is the same mixture; what the completed tick leaves unrepresented is
-- native loss.
--
-- THE PARTIAL ROUND BALE (part 2b). Baler:setIsUnloadingBale's unfinished-bale branch
-- (:1327-1349) moves the buffer's share into the bale, stores the real amount in
-- lastBaleFillLevel and pads the chamber to capacity to drive the animation. The pad
-- is representation, not material: inside that call a chamber increase changes no
-- account and no reconciliation runs, and the buffer's debited share joins the finish
-- context, so the bale carries the chamber's material plus the buffer's.
--
-- SERVER ONLY. Standalone: with a StockGuard lease owning the pickup the frame stands
-- aside (GroundMovementCarrier.begin) and nothing is sealed here: StockGuard holds the
-- material and seals it (the lease's delivery returns each source's removal with its
-- captured condition), and the collected reader resolves StockGuard's receipt
-- (MaterialWetness:resolveAllocation). Soil's own chamber account then knows nothing of
-- that pickup and says so (unknown), never a parallel record.
--

BalerCollection = BalerCollection or {}
local BC = BalerCollection

BC.STATE_KEY = "_sfBalerCollection"
BC.EPSILON = 1e-9
-- A produced amount the sources explain within this many litres is fully explained.
BC.TOLERANCE = 1e-6
BC.stats = BC.stats or { batches = 0, sealed = 0, sealRefused = 0, bound = 0, unknownBirths = 0, overflowRetired = 0 }

-- The creation frames open right now, innermost last (Soil's Bale.register hook asks).
BC.creationFrames = BC.creationFrames or {}

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- =========================================================
-- Accounts
-- =========================================================

function BC.newAccount()
    return { carrier = 0, known = 0, unknown = 0, refused = 0, weighted = 0 }
end

function BC.copyAccount(a)
    return { carrier = a.carrier, known = a.known, unknown = a.unknown, refused = a.refused, weighted = a.weighted }
end

--- Add a reader's coverage (readCollectedCondition's fields) to an account.
function BC.accountAddCoverage(acc, cov)
    acc.carrier  = acc.carrier + (cov.carrierLitres or 0)
    acc.known    = acc.known + (cov.knownCarrierLitres or 0)
    acc.unknown  = acc.unknown + (cov.unknownCarrierLitres or 0)
    acc.refused  = acc.refused + (cov.refusedCarrierLitres or 0)
    acc.weighted = acc.weighted + (cov.knownWeightedPctSum or 0)
end

function BC.accountAddUnknown(acc, litres)
    if not finite(litres) or litres <= 0 then return end
    acc.carrier = acc.carrier + litres
    acc.unknown = acc.unknown + litres
end

function BC.accountAddAccount(acc, other)
    acc.carrier = acc.carrier + other.carrier
    acc.known, acc.unknown, acc.refused = acc.known + other.known, acc.unknown + other.unknown, acc.refused + other.refused
    acc.weighted = acc.weighted + other.weighted
end

--- A uniform withdrawal: `litres` of the account's mixture leave it, as a new account.
function BC.accountTake(acc, litres)
    local out = BC.newAccount()
    if not finite(litres) or litres <= 0 or acc.carrier <= BC.EPSILON then return out end
    local f = math.min(1, litres / acc.carrier)
    out.carrier, out.known, out.unknown = acc.carrier * f, acc.known * f, acc.unknown * f
    out.refused, out.weighted = acc.refused * f, acc.weighted * f
    acc.carrier, acc.known, acc.unknown = acc.carrier - out.carrier, acc.known - out.known, acc.unknown - out.unknown
    acc.refused, acc.weighted = acc.refused - out.refused, acc.weighted - out.weighted
    if acc.carrier <= BC.EPSILON then
        acc.carrier, acc.known, acc.unknown, acc.refused, acc.weighted = 0, 0, 0, 0, 0
    end
    return out
end

--- The same mixture scaled to `litres` (every component by litres / carrier); the
--- account itself is untouched. A native gain scales a mixture; it adds no dry material.
function BC.accountScaled(acc, litres)
    local out = BC.newAccount()
    if acc == nil or not finite(litres) or litres <= 0 or acc.carrier <= BC.EPSILON then return out end
    local f = litres / acc.carrier
    out.carrier, out.known, out.unknown = acc.carrier * f, acc.known * f, acc.unknown * f
    out.refused, out.weighted = acc.refused * f, acc.weighted * f
    return out
end

--- The account's full-load percent: only when the whole positive carrier is known.
---@return number|nil pct
function BC.accountPct(acc)
    if acc == nil or acc.carrier <= BC.EPSILON then return nil end
    if acc.unknown > BC.TOLERANCE or acc.refused > BC.TOLERANCE then return nil end
    if acc.known <= BC.EPSILON then return nil end
    return acc.weighted / acc.known
end

--- Native state owns the material: an account whose carrier differs from the unit's
--- native level is brought to it. An unseen increase is unknown material; an unseen
--- decrease is a uniform withdrawal (retired).
function BC.accountReconcile(acc, nativeLevel)
    if not finite(nativeLevel) or nativeLevel < 0 then return end
    local diff = nativeLevel - acc.carrier
    if diff > BC.TOLERANCE then
        BC.accountAddUnknown(acc, diff)
    elseif diff < -BC.TOLERANCE then
        BC.accountTake(acc, -diff)
    end
end

-- =========================================================
-- Per-vehicle state
-- =========================================================

function BC.state(vehicle)
    if type(vehicle) ~= "table" then return nil end
    local st = rawget(vehicle, BC.STATE_KEY)
    if st == nil then
        st = { contexts = {}, main = BC.newAccount(), overflow = BC.newAccount(), buffer = BC.newAccount(),
               finishes = {}, transfer = nil, add = nil, tick = nil, pad = nil, seq = 0 }
        rawset(vehicle, BC.STATE_KEY, st)
    end
    return st
end

local function wetness()
    local ss = g_SoilFertilityManager ~= nil and g_SoilFertilityManager.soilSystem or nil
    local mw = ss ~= nil and ss.materialWetness or nil
    if mw == nil or type(mw.isArmed) ~= "function" or not mw:isArmed() then return nil, ss end
    return mw, ss
end

local function mainLevel(vehicle, spec)
    local ok, level = pcall(vehicle.getFillUnitFillLevel, vehicle, spec.fillUnitIndex)
    if ok and finite(level) then return level end
    return nil
end

-- =========================================================
-- The collection context (onStart .. onEnd)
-- =========================================================

function BC.openContext(vehicle)
    local st = BC.state(vehicle)
    st.seq = st.seq + 1
    local ctx = { vehicle = vehicle, seq = st.seq, batches = {} }
    st.contexts[#st.contexts + 1] = ctx
    return ctx
end

function BC.currentContext(vehicle)
    local st = rawget(vehicle, BC.STATE_KEY)
    if st == nil then return nil end
    return st.contexts[#st.contexts]
end

function BC.closeContext(vehicle, ctx)
    local st = rawget(vehicle, BC.STATE_KEY)
    if st == nil then return end
    for i = #st.contexts, 1, -1 do
        local c = table.remove(st.contexts, i)
        if c == ctx then break end
    end
end

-- =========================================================
-- The pickup frame's handler (the observer calls it around each primitive)
-- =========================================================

BC.handler = {}

function BC.handler.beforePrimitive(frame, prim)
    GroundMovementCarrier.beforePrimitive(frame, prim)
    if not prim.pickup or prim.cells == nil or prim.unobservable or not frame.barrierOk then return end
    local mw = wetness()
    if mw == nil then return end
    local ft = prim.fillTypeIndex
    local cells = {}
    for _, cell in ipairs(prim.cells) do
        local before = cell.before ~= nil and cell.before[ft] or nil
        if finite(before) and before > BC.EPSILON then
            cells[#cells + 1] = { gx = cell.gx, gz = cell.gz, litres = before }
        end
    end
    prim.collected = mw:collectedSnapshot(ft, cells)
end

function BC.handler.onPrimitive(frame, prim)
    GroundMovementCarrier.onPrimitive(frame, prim)
    if not prim.pickup then return end
    local picked = -(tonumber(prim.litres) or 0)
    if picked <= BC.EPSILON then return end
    local call = frame.collection
    if call == nil then return end
    local snap, seen = prim.collected, 0
    if snap ~= nil and prim.cells ~= nil then
        local ft = prim.fillTypeIndex
        for _, cell in ipairs(prim.cells) do
            local b, a = cell.before, cell.after
            if b ~= nil and a ~= nil then
                local removed = (b[ft] or 0) - (a[ft] or 0)
                local id = tostring(cell.gx) .. ":" .. tostring(cell.gz)
                if removed > BC.EPSILON and snap.parts[id] ~= nil then
                    call.sources[#call.sources + 1] = { snapshot = snap, id = id, raw = removed }
                    seen = seen + removed
                end
            end
        end
    end
    -- Litres the native call took that no captured cell explains carry no known source.
    if picked - seen > BC.TOLERANCE then call.unexplained = call.unexplained + (picked - seen) end
    call.raw = call.raw + picked
end

function BC.handler.onPrimitiveFailed(frame, prim)
    GroundMovementCarrier.onPrimitiveFailed(frame, prim)
end

--- Close one pickup call into its context's batch list. `produced` is the native
--- call's first return, P_b (post-additive, Baler.lua:1908-1911).
function BC.closeCall(ctx, call, produced)
    if ctx == nil or call == nil then return end
    if not finite(produced) or produced <= BC.EPSILON then return end
    BC.stats.batches = BC.stats.batches + 1
    ctx.batches[#ctx.batches + 1] = { P = produced, sources = call.sources, raw = call.raw, unexplained = call.unexplained }
end

-- =========================================================
-- The seal: a target amount of the context's produced mixture
-- =========================================================

--- The share of the context's produced carrier `W` that a target retains (`amount`
--- litres, the accepted A or the overflow O), sealed per batch and read back through
--- the collected reader. Returns an account.
function BC.sealTarget(ctx, W, amount)
    local acc = BC.newAccount()
    if ctx == nil or not finite(W) or W <= BC.EPSILON or not finite(amount) or amount <= BC.EPSILON then return acc end
    local mw = wetness()
    local ratio = amount / W
    local totalP = 0
    for _, b in ipairs(ctx.batches) do totalP = totalP + b.P end
    if totalP <= BC.EPSILON then BC.accountAddUnknown(acc, amount) return acc end
    for _, b in ipairs(ctx.batches) do
        -- This batch's retained carrier: its produced share of the target.
        local target = amount * (b.P / totalP)
        local R = 0
        for _, s in ipairs(b.sources) do R = R + s.raw end
        local explainedRaw = R
        local allRaw = R + (b.unexplained or 0)
        local knownTarget = (allRaw > BC.EPSILON) and target * (explainedRaw / allRaw) or 0
        -- Carrier the sources cannot explain is unknown produced material.
        BC.accountAddUnknown(acc, target - knownTarget)
        if mw ~= nil and knownTarget > BC.EPSILON and #b.sources > 0 then
            local cov = BC.sealBatch(mw, b, knownTarget, R, ratio)
            if cov ~= nil then
                BC.accountAddCoverage(acc, cov)
            else
                BC.accountAddUnknown(acc, knownTarget)
            end
        elseif knownTarget > BC.EPSILON then
            BC.accountAddUnknown(acc, knownTarget)
        end
    end
    return acc
end

--- Seal one batch's allocation of `A_b` carrier litres over its sources (q_i = A_b *
--- r_i / R, the raw retained equivalent r_i * ratio), in canonical id order with the
--- final remainder on the last positive part so the parts sum to A_b exactly. Every
--- source of one batch shares one snapshot (the positive primitive's). Returns the
--- reader's coverage, or nil when the seal or the read refuses.
function BC.sealBatch(mw, batch, A_b, R, ratio)
    local snap = batch.sources[1].snapshot
    local byId = {}
    for _, s in ipairs(batch.sources) do
        if s.snapshot ~= snap then return nil end   -- one snapshot per seal
        byId[s.id] = (byId[s.id] or 0) + s.raw
    end
    local ids = {}
    for id in pairs(byId) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts, sum = {}, 0
    for i, id in ipairs(ids) do
        local q = A_b * byId[id] / R
        parts[i] = { id = id, carrierLitres = q, rawLitres = byId[id] * ratio }
        if i < #ids then sum = sum + q end
    end
    -- The final remainder on the last part; the seal sums in this same order.
    local last = parts[#parts]
    last.carrierLitres = A_b - sum
    for _ = 1, 4 do
        local s = 0
        for _, p in ipairs(parts) do s = s + p.carrierLitres end
        if s == A_b then break end
        last.carrierLitres = last.carrierLitres + (A_b - s)
    end
    if last.carrierLitres < 0 then return nil end
    local receipt, why = mw:sealAllocation(snap, A_b, parts)
    if receipt == nil then
        BC.stats.sealRefused = BC.stats.sealRefused + 1
        SoilLogger.debug("[BalerCollection] seal refused (%s)", tostring(why))
        return nil
    end
    BC.stats.sealed = BC.stats.sealed + 1
    local cov = mw:readCollectedCondition(snap, receipt)
    if cov == nil or cov.status == MaterialWetness.RESULT.UNAVAILABLE then return nil end
    return cov
end

-- =========================================================
-- The Baler's listeners (class wraps; the engine looks them up at call time)
-- =========================================================

--- onStartWorkAreaProcessing: a collection context opens (server only).
function BC.onStart(vehicle)
    if g_server == nil or not vehicle.isServer then return end
    BC.openContext(vehicle)
end

--- onEndWorkAreaProcessing, around the original: W and the context are the active add.
function BC.aroundEnd(vehicle, original, ...)
    local ctx = (g_server ~= nil and vehicle.isServer) and BC.currentContext(vehicle) or nil
    local st = ctx ~= nil and BC.state(vehicle) or nil
    local spec = vehicle.spec_baler
    if st ~= nil and spec ~= nil then
        local P = 0
        for _, b in ipairs(ctx.batches) do P = P + b.P end
        st.add = { ctx = ctx, W = P * (tonumber(spec.fillScale) or 1), consumed = false }
    end
    local r = { n = select("#", ...), ... }
    local packed = { pcall(original, vehicle, unpack(r, 1, r.n)) }
    if st ~= nil then
        st.add = nil
        BC.closeContext(vehicle, ctx)
    end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

--- onFillUnitFillLevelChanged, around the original (the listener that can finish the
--- bale and assigns or re-adds the overflow).
function BC.aroundFillChange(vehicle, original, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta)
    local spec = vehicle.spec_baler
    local server = g_server ~= nil and vehicle.isServer and spec ~= nil
    if server and spec.nonStopBaling and spec.buffer ~= nil and fillUnitIndex == spec.buffer.fillUnitIndex
       and fillUnitIndex ~= spec.fillUnitIndex then
        local stB = BC.state(vehicle)
        if finite(appliedDelta) then pcall(BC.bufferChange, vehicle, stB, appliedDelta) end
        local packedB = { pcall(original, vehicle, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta) }
        if not packedB[1] then error(packedB[2], 0) end
        return unpack(packedB, 2)
    end
    local st = (server and fillUnitIndex == spec.fillUnitIndex) and BC.state(vehicle) or nil
    local branch = nil
    if st ~= nil and finite(appliedDelta) then
        if appliedDelta > BC.EPSILON then
            if st.pad ~= nil then
                -- The partial round bale's pad: representation, not material.
                st.pad.padded = (st.pad.padded or 0) + appliedDelta
            elseif st.transfer ~= nil then
                -- The overflow re-add's nested add: this share of the old overflow moves.
                BC.accountAddAccount(st.main, BC.accountTake(st.transfer.old, appliedDelta))
            elseif st.add ~= nil and not st.add.consumed then
                st.add.consumed, st.add.A, st.add.D = true, appliedDelta, fillLevelDelta
                BC.accountAddAccount(st.main, BC.sealTarget(st.add.ctx, st.add.W, appliedDelta))
            elseif st.tick ~= nil and st.tick.pending ~= nil and not st.tick.consumed then
                -- The buffer-to-chamber transfer (Baler.lua:1013-1052): the debited mixture,
                -- scaled to the accepted litres (a gain carries its source's condition).
                st.tick.consumed = true
                BC.accountAddAccount(st.main, BC.accountScaled(st.tick.pending, appliedDelta))
            else
                BC.accountAddUnknown(st.main, appliedDelta)
            end
        elseif appliedDelta < -BC.EPSILON then
            BC.accountTake(st.main, -appliedDelta)
        end
        -- The native branch this listener is about to take (Baler.lua:1169-1184).
        if (fillLevelDelta or 0) > 0 then
            local okF, free = pcall(vehicle.getFillUnitFreeCapacity, vehicle, spec.fillUnitIndex)
            if okF and finite(free) and free <= 0 then
                branch = "FULL"
            elseif (spec.fillUnitOverflowFillLevel or 0) > 0 and st.transfer == nil then
                branch = "READD"
                st.transfer = { old = st.overflow, level = spec.fillUnitOverflowFillLevel }
                st.overflow = BC.newAccount()
            end
        end
    end
    local overflowBefore = spec ~= nil and spec.fillUnitOverflowFillLevel or nil
    local packed = { pcall(original, vehicle, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta) }
    if st ~= nil then
        pcall(BC.afterFillChange, vehicle, st, spec, branch, overflowBefore)
    end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

function BC.afterFillChange(vehicle, st, spec, branch, overflowBefore)
    local overflowAfter = spec.fillUnitOverflowFillLevel or 0
    if branch == "FULL" and st.transfer == nil then
        -- The observed assignment O = D - A replaces whatever overflow was there.
        if (overflowBefore or 0) > BC.EPSILON and st.overflow.carrier > BC.EPSILON then
            BC.stats.overflowRetired = BC.stats.overflowRetired + 1
        end
        st.overflow = BC.newAccount()
        if overflowAfter > BC.EPSILON then
            if st.add ~= nil and st.add.consumed then
                BC.accountAddAccount(st.overflow, BC.sealTarget(st.add.ctx, st.add.W, overflowAfter))
            elseif st.tick ~= nil and st.tick.consumed and st.tick.pending ~= nil then
                BC.accountAddAccount(st.overflow, BC.accountScaled(st.tick.pending, overflowAfter))
            else
                BC.accountAddUnknown(st.overflow, overflowAfter)
            end
        end
    elseif branch == "READD" then
        -- What the listener stored back is the old overflow's remainder.
        local t = st.transfer
        st.transfer = nil
        st.overflow = BC.newAccount()
        if overflowAfter > BC.EPSILON then
            BC.accountAddAccount(st.overflow, BC.accountTake(t.old, overflowAfter))
        end
    end
    -- Native state owns the material (not while the chamber holds a pad).
    if st.pad == nil then
        local level = mainLevel(vehicle, spec)
        if level ~= nil then BC.accountReconcile(st.main, level) end
    end
    BC.accountReconcile(st.overflow, spec.fillUnitOverflowFillLevel or 0)
end

--- A change on the non-stop buffer unit.
function BC.bufferChange(vehicle, st, appliedDelta)
    if appliedDelta > BC.EPSILON then
        if st.add ~= nil and not st.add.consumed then
            -- The pickup's add went to the buffer (Baler.lua:1983-1996).
            st.add.consumed = true
            BC.accountAddAccount(st.buffer, BC.sealTarget(st.add.ctx, st.add.W, appliedDelta))
        else
            BC.accountAddUnknown(st.buffer, appliedDelta)
        end
    elseif appliedDelta < -BC.EPSILON then
        local taken = BC.accountTake(st.buffer, -appliedDelta)
        if st.pad ~= nil then
            st.pad.share = st.pad.share or BC.newAccount()
            BC.accountAddAccount(st.pad.share, taken)
        elseif st.tick ~= nil then
            st.tick.pending = st.tick.pending or BC.newAccount()
            BC.accountAddAccount(st.tick.pending, taken)
        end
        -- Otherwise a withdrawal the collection does not follow: retired.
    end
    local spec = vehicle.spec_baler
    local okL, level = pcall(vehicle.getFillUnitFillLevel, vehicle, spec.buffer.fillUnitIndex)
    if okL and finite(level) then BC.accountReconcile(st.buffer, level) end
end

--- Baler:onUpdateTick (class listener): the buffer-to-chamber transfer's scope.
function BC.aroundTick(vehicle, original, ...)
    local st = (g_server ~= nil and vehicle.isServer and vehicle.spec_baler ~= nil) and BC.state(vehicle) or nil
    local outer = st ~= nil and st.tick or nil
    if st ~= nil then st.tick = {} end
    local packed = { pcall(original, vehicle, ...) }
    if st ~= nil then st.tick = outer end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

--- setIsUnloadingBale (instance): the partial round bale's pad scope.
function BC.aroundUnloading(vehicle, original, ...)
    local st = (g_server ~= nil and vehicle.isServer and vehicle.spec_baler ~= nil) and BC.state(vehicle) or nil
    local outer = st ~= nil and st.pad or nil
    if st ~= nil then st.pad = {} end
    local packed = { pcall(original, vehicle, ...) }
    if st ~= nil then st.pad = outer end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

-- =========================================================
-- finishBale and createBale (instance wraps)
-- =========================================================

--- finishBale: the chamber's account is captured before the native clears it
--- (square) or creates first (round).
function BC.aroundFinish(vehicle, original, ...)
    local st = (g_server ~= nil and vehicle.isServer) and BC.state(vehicle) or nil
    local spec = vehicle.spec_baler
    if st ~= nil and spec ~= nil then
        local account
        if st.pad ~= nil then
            -- A partial round bale: the chamber's material plus the buffer's share; the
            -- pad is not material, so the chamber is not reconciled to its padded level.
            account = BC.copyAccount(st.main)
            if st.pad.share ~= nil then BC.accountAddAccount(account, st.pad.share) end
        else
            local level = mainLevel(vehicle, spec)
            if level ~= nil then BC.accountReconcile(st.main, level) end
            account = BC.copyAccount(st.main)
        end
        st.finishes[#st.finishes + 1] = { account = account }
    end
    local packed = { pcall(original, vehicle, ...) }
    if st ~= nil then table.remove(st.finishes) end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

--- createBale: a creation frame binds the exact record the call appended.
function BC.aroundCreate(vehicle, original, baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId, loadFromSavegame)
    local spec = vehicle.spec_baler
    if g_server == nil or not vehicle.isServer or spec == nil or type(spec.bales) ~= "table" then
        return original(vehicle, baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId, loadFromSavegame)
    end
    local st = BC.state(vehicle)
    local finish = st.finishes[#st.finishes]
    local frame = { vehicle = vehicle, seen = {}, count = #spec.bales,
                    account = (finish ~= nil and not loadFromSavegame) and finish.account or nil }
    BC.creationFrames[#BC.creationFrames + 1] = frame
    local packed = { pcall(original, vehicle, baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId, loadFromSavegame) }
    for i = #BC.creationFrames, 1, -1 do
        if BC.creationFrames[i] == frame then table.remove(BC.creationFrames, i) break end
    end
    local bound = nil
    if packed[1] and packed[2] and #spec.bales == frame.count + 1 then
        local rec = spec.bales[#spec.bales]
        bound = rec ~= nil and rec.baleObject or nil
    end
    for _, obj in ipairs(frame.seen) do
        if obj == bound then
            pcall(BC.bindBirth, obj, frame.account)
        else
            pcall(BC.bindBirth, obj, nil)
        end
    end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

--- Soil's Bale.register hook asks: is this registration inside a creation frame? The
--- object is then held for the frame to bind, and the generic birth is skipped.
---@return boolean deferred
function BC.deferRegistration(baleObject)
    local frame = BC.creationFrames[#BC.creationFrames]
    if frame == nil then return false end
    frame.seen[#frame.seen + 1] = baleObject
    return true
end

--- A bale born from a creation frame: its condition is the account's (nil = unknown).
function BC.bindBirth(baleObject, account)
    local pct = account ~= nil and BC.accountPct(account) or nil
    if pct == nil then BC.stats.unknownBirths = BC.stats.unknownBirths + 1 else BC.stats.bound = BC.stats.bound + 1 end
    if HookManager ~= nil and type(HookManager.baleBirth) == "function" then
        HookManager.baleBirth(baleObject, { wetnessPct = pct, collected = true, account = account })
    end
end

SoilLogger.info("BalerCollection (RSF-F211) loaded")
