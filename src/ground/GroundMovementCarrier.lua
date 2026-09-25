--
-- GroundMovementCarrier
--
-- RSF-F208, section 3 of GROUND-CONDITION-CONTRACT v1.5: the Soil-alone movement
-- carriers: the TEDDER (S2a), the WINDROWER and the MOWER (S2b).
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
--      what survived there, through the coordinator's conservative combine. The
--      per-cell work is GroundMovementProjector's, the ONE projector this carrier
--      shares with the StockGuard lease path (Iris's answer 2, 2026-09-23).
--   5. Close the frame. The account is reconciled with the native remainder at the
--      start of every call, before any primitive reads it.
--
-- THE ACCOUNT IS NOT STOCK. For the Tedder it tracks the native workArea.litersToDrop
-- only to know what condition the remainder carries (Tedder.lua:296-304). The native
-- number is the truth: an account larger than it is scaled down, a native remainder
-- larger than the account is carried as unknown condition.
--
-- THE WINDROWER KEEPS NO ACCOUNT ACROSS CALLS. Its drop request is the CURRENT call's
-- pickup (lastPickupLiters, Windrower.lua:350-357); its accumulating litersToDrop
-- (:351) is never dropped again and is not a physical stock (contract section 3). So
-- its account lives for one call: only that call's pickups contribute, and whatever
-- it picked up but did not drop is native loss, discarded with the frame. Nothing here
-- changes a native quantity.
--
-- THE MOWER SPANS TWO CALLS AND ONE ACCOUNT PER DROP AREA. Each mower work area's cut
-- (processMowerArea, Mower.lua:328-382) feeds the SHARED auxiliary dropArea.litersToDrop
-- (:358): the fresh converted output, plus any old DRYGRASS_WINDROW it picks up under
-- the cut (:362-364), then the native 1000 L cap (:366-367). The drop comes later, per
-- drop area, from the end of processing (processDropArea, :383-405). So the account
-- lives on the DROP AREA, and both calls open a frame over it:
--   - the cut frame records the old windrow's pickup with its pre-removal condition,
--     adds the fresh output as a FRESH BIRTH (below), then reconciles to the native
--     remainder, so a cap loss discards condition uniformly and never re-creates it;
--   - the drop frame projects the mixture where the drop actually landed.
-- The direct-to-FillUnit branch (no drop area, :353-355) is not a ground deposit and
-- opens no frame. Each frame's lease check names the area actually calling.
--
-- THE STRAW FRAME SPANS ONE CALL (RSF-F212, contract section 4). A combine's swath
-- produces and drops in the same call (Combine.lua:733, :747): the buffer's release
-- this frame is the tip request, and the tip is the deposit. So the frame is the
-- windrower's shape, a one-call account, and the fresh straw enters it from the
-- observer's BEFORE handler, off the native request itself, before the drop is
-- handled. What does not land is the native's loss and dies with the frame.
--
-- FRESH BIRTHS (RSF-F212, contract section 4, P-GROUND-2). A GENUINE fresh birth is
-- output a native production observation proved this call: the rise in the mower's
-- pickedUpLiters, the swath's own tip request. It is born AT THE DEPOSIT: age raw 1
-- when it lands, whatever day the output entered the machine's buffer (section 4's
-- last sentence; P-GROUND-1's ageing is for material captured from the ground). Its
-- wetness is the Soil-owned starting profile when the pair (carrier kind, output
-- type) is an accepted branch, a mower's GRASS_WINDROW or a swath's STRAW, and
-- UNKNOWN for any other output: a fill-type name alone never earns a profile, so a
-- converter that makes hay gets none and an import stays unknown. A refused barrier
-- makes the output explicit unknown, never the profile and never the generic
-- no-record birth. The profile's id, revision and provenance (estimated-at-birth)
-- ride the component and the contribution; the layer holds bytes, so they end at the
-- coordinator's combine and in the log. A redischarge never re-seeds: a component
-- picked up from the ground carries its captured condition and no provenance.
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
C.KIND_WINDROWER = "WINDROWER"
C.KIND_MOWER = "MOWER"
C.KIND_STRAW = "STRAW"
-- [RSF-F211 part 2a] The Baler pickup frame (BalerCollection extends the handler).
C.KIND_BALER = "BALER"
-- [RSF-F211 part 2b] The ForageWagon pickup frame (ForageWagonCollection).
C.KIND_FORAGE_WAGON = "FORAGE_WAGON"
-- The per-vehicle frame stamp (stampHandled / handledThisFrame below).
C.HANDLED_KEY = "_sfGroundCarrierFrame"
C.ACCOUNT_KEY = "_sfGroundAccount"
C.EPSILON = GroundMovementProjector.EPSILON
-- A cell's observed litres may differ from the native return by the density map's
-- quantisation; below this the difference is treated as none (the projector's).
C.TOLERANCE = GroundMovementProjector.TOLERANCE

local AGE_BORN, AGE_CEILING = 1, 255

-- RSF-F212, contract section 4 (P-GROUND-2, ratified 2026-09-14): the Soil-owned
-- starting profiles, wet basis. A declared game starting value, not a measurement:
-- each seeds the existing drying phases and changes no curve. Versioned Soil domain
-- data: a later revision changes only what is born after it, because a component
-- keeps the stamp it was born with and the account is never saved, so nothing is
-- re-seeded on reload. `kind` and `fillType` name the one accepted branch each.
C.PROFILES = {
    FRESH_GRASS = { id = "FRESH_GRASS_V1", revision = 1, pct = 80, kind = C.KIND_MOWER, fillType = "GRASS_WINDROW" },
    FRESH_STRAW = { id = "FRESH_STRAW_V1", revision = 1, pct = 25, kind = C.KIND_STRAW, fillType = "STRAW" },
}
-- What a birth contribution says about its wetness: an estimate made at birth,
-- distinct from a condition later captured from the ground (provenance nil).
C.PROVENANCE_ESTIMATED_AT_BIRTH = "ESTIMATED_AT_BIRTH"

C.stats = C.stats or { frames = 0, skippedLease = 0, barrierRefused = 0, projected = 0, cleared = 0, unavailable = 0 }
C.stats.births = C.stats.births or 0
C.firstPassLogged = C.firstPassLogged or {}   -- kind -> true, once per session
C.firstBirthLogged = C.firstBirthLogged or {} -- profile id -> true, once per session

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
--- pass does not grow the account without bound. `birth` (RSF-F212) marks a fresh
--- birth: { profile = id|nil, revision = n|nil, provenance = string|nil }. It is part
--- of the stamp, so an estimate made at birth never merges with a condition captured
--- from the ground, even when their bytes agree.
function C.accountAdd(acc, litres, ageRaw, wetnessRaw, captureAgeDay, birth)
    if type(litres) ~= "number" or litres <= C.EPSILON then return end
    local born = birth ~= nil
    local profile = born and birth.profile or nil
    local provenance = born and birth.provenance or nil
    for _, comp in ipairs(acc.components) do
        if comp.ageRaw == ageRaw and comp.wetnessRaw == wetnessRaw and comp.captureAgeDay == captureAgeDay
           and (comp.born == true) == born and comp.profile == profile and comp.provenance == provenance then
            comp.litres = comp.litres + litres
            return
        end
    end
    acc.components[#acc.components + 1] = {
        litres = litres, ageRaw = ageRaw, wetnessRaw = wetnessRaw, captureAgeDay = captureAgeDay,
        born = born, profile = profile, revision = born and birth.revision or nil, provenance = provenance,
    }
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

--- The account's components as they are NOW: a captured component aged once from
--- its stamp (P-GROUND-1); a fresh birth born at THIS deposit (RSF-F212, contract
--- section 4: birth day and weather eligibility are the accepted deposit's, not the
--- day the output entered the machine's buffer), carrying its estimate's provenance.
function C.accountResolve(acc, today)
    local out = {}
    for _, comp in ipairs(acc.components) do
        local ageRaw
        if comp.born then
            ageRaw = AGE_BORN
        else
            ageRaw = C.agedRaw(comp.ageRaw, comp.captureAgeDay, today)
        end
        out[#out + 1] = { litres = comp.litres, ageRaw = ageRaw, wetnessRaw = comp.wetnessRaw,
            profile = comp.profile, revision = comp.revision, provenance = comp.provenance }
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
-- Reading and projecting one cell: GroundMovementProjector's, over this frame
-- =========================================================

local P = GroundMovementProjector

local function markUnavailable(frame, cell, reason)
    P.markUnavailable(frame, cell, reason)
end

--- Handler: before the native call, capture the condition of every cell it may touch.
--- For the STRAW frame the drop request IS the production observation (header: the
--- straw frame), so the fresh straw enters the one-call account here, before the
--- drop is handled.
function C.beforePrimitive(frame, prim)
    if frame.kind == C.KIND_STRAW and not prim.pickup then
        C.freshBirth(frame, prim.delta, prim.fillTypeIndex)
    end
    if prim.cells == nil or prim.unobservable or not frame.barrierOk then return end
    P.captureCells(frame, prim.cells)
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

    -- Enumerated but too large to read: every cell it covers may have changed and
    -- none can be vouched for. Mark them all, keep their bytes, project nothing
    -- (contract section 2: preserve bytes as unavailable, never clear or invent).
    if prim.unobservable then
        for _, cell in ipairs(prim.cells) do
            markUnavailable(frame, cell, "ENVELOPE:" .. tostring(prim.refused))
        end
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
        -- Each source cell's removal, with its captured condition, into the account;
        -- the projector clears a cell only on a known whole-cell zero.
        local picked = -litres
        local seen = P.pickup(frame, prim.cells, ft, function(removed, ageRaw, wetnessRaw)
            C.accountAdd(acc, removed, ageRaw, wetnessRaw, frame.today)
        end)
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
    P.drop(frame, prim.cells, ft, mixture, total)
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
---@param kind string         C.KIND_TEDDER, C.KIND_WINDROWER or C.KIND_MOWER
---@param nativeRemainder function|nil  (area) -> the native remainder the account
---       tracks across calls; nil for a carrier whose account lives for one call only
---@param accountArea table|nil  where the account lives, when not on the calling work
---       area itself: the Mower's shared drop area. The lease check still names the
---       area actually calling.
---@return table|nil frame
function C.begin(system, vehicle, workArea, kind, nativeRemainder, accountArea)
    if g_server == nil or type(system) ~= "table" or type(vehicle) ~= "table" or type(workArea) ~= "table" then return nil end
    if not vehicle.isServer then return nil end
    local coord, cells, admission = system.groundConditionCoordinator, system.groundConditionCells, system.groundConditionAdmission
    if coord == nil or not coord:isArmed() or cells == nil then return nil end
    -- The family is armed for this call: the carrier owns this machine's deposits this
    -- frame, whether the standalone frame opens below or a lease owns the primitive.
    C.stampHandled(vehicle)
    if admission ~= nil and admission:hasLiveLeaseFor(vehicle, workArea) then
        C.stats.skippedLease = C.stats.skippedLease + 1
        return nil
    end
    local geometry = cells:getConditionGeometry()
    if geometry == nil then return nil end
    local today = coord:currentMonotonicDay()
    local ok, reason = coord:runSettlementBarrier()
    if not ok then C.stats.barrierRefused = C.stats.barrierRefused + 1 end
    local acc
    if nativeRemainder ~= nil then
        local home = type(accountArea) == "table" and accountArea or workArea
        acc = C.accountOf(home)
        C.accountReconcile(acc, nativeRemainder(home), today)
    else
        acc = { components = {} }
    end
    C.stats.frames = C.stats.frames + 1
    return GroundNativeObserver.open({
        owner = vehicle, workArea = workArea, kind = kind, handler = C,
        coordinator = coord, cells = cells, geometry = geometry, today = today,
        barrierOk = ok, barrierReason = reason, account = acc,
        -- The projector's counters are this carrier's; the admission is watched for an
        -- inner admission during the native call (GroundNativeObserver, standing aside).
        stats = C.stats, admission = admission,
    })
end

--- After the native processing call, whether it returned or raised. The account is
--- reconciled with the native remainder at the NEXT begin, before any primitive can
--- read it, so a change made between calls (another mod clearing the remainder) is
--- caught where it matters.
---
--- The first pass that actually observed a primitive says so ONCE in the log, with
--- the running totals. It is the line an in-game check looks for: nothing a player
--- sees reads ground condition directly, and a count of installed wrappers is not
--- evidence that one ran.
function C.finish(frame)
    if frame == nil then return end
    GroundNativeObserver.close(frame)
    if not C.firstPassLogged[frame.kind] and (frame.primitives or 0) > 0 then
        C.firstPassLogged[frame.kind] = true
        SoilLogger.info(
            "[GroundCarrier] FIRST %s PASS OBSERVED: %d primitive(s) in this call; so far %d cell(s) projected, " ..
            "%d cleared, %d marked unavailable. Ground age and wetness now follow the material this machine moves.",
            tostring(frame.kind), frame.primitives, C.stats.projected, C.stats.cleared, C.stats.unavailable)
    end
end

--- The Tedder's native remainder (Tedder.lua:297, :304).
function C.tedderRemainder(workArea)
    return tonumber(workArea.litersToDrop) or 0
end

--- The Mower's native remainder: the shared drop area's pending litres (Mower.lua:358,
--- :367, :398).
function C.mowerRemainder(dropArea)
    return tonumber(dropArea.litersToDrop) or 0
end

--- The drop area a mower work area feeds, read as Mower:getDropArea does (:406-424)
--- but without its warnings or its repair of a bad index, which stay the native's.
--- WorkAreaType is read bare, as the engine reads it (Mower.lua:417): it cannot be
--- absent in production, and a guard would turn its absence into a silently skipped
--- carrier rather than a loud error (MAINTENANCE row 74).
function C.mowerDropArea(vehicle, workArea)
    if type(vehicle) ~= "table" or type(workArea) ~= "table" then return nil end
    if not workArea.dropWindrow or workArea.dropAreaIndex == nil then return nil end
    local spec = vehicle.spec_workArea
    local dropArea = spec ~= nil and type(spec.workAreas) == "table" and spec.workAreas[workArea.dropAreaIndex] or nil
    if type(dropArea) ~= "table" or dropArea.type ~= WorkAreaType.AUXILIARY then return nil end
    return dropArea
end

-- =========================================================
-- Fresh births (RSF-F212, contract section 4)
-- =========================================================

--- The engine's update-loop index (main.lua:777-779, wrapped at 2^30), the same
--- same-frame test the admission uses for its leases; nil when there is none.
---
--- READ THROUGH THE ENVIRONMENT, never rawget on _G. A mod runs in its own
--- environment (mods.lua:436-442): modEnv's __index is the real global table and
--- modEnv._G is modEnv itself, so rawget(_G, name) looks in the mod's table and
--- never sees an engine global. A plain read resolves through __index, which is the
--- only way an engine global reaches a mod. Bob's finding on #1003 at 043f11f1.
local function currentFrameIndex()
    local n = g_updateLoopIndex
    return type(n) == "number" and n or nil
end

--- Record that the ground-condition carrier owns `vehicle`'s deposits this frame.
--- Contract section 4: the generic no-record birth (noteMaterialAt over the work
--- area) is suppressed in every admitted context, whether the standalone frame ran or
--- a StockGuard lease owned the primitive, and whether or not condition capture then
--- succeeded; the carrier's unknown and unavailable marks are the explicit answer.
--- Stamped by begin as soon as the family is armed for the call, before its lease
--- check, so both routes stamp.
function C.stampHandled(vehicle)
    local n = currentFrameIndex()
    if n == nil or type(vehicle) ~= "table" then return end
    rawset(vehicle, C.HANDLED_KEY, n)
end

--- Whether the carrier owns `vehicle`'s deposits this frame (stampHandled). With no
--- frame index the answer is no, and the generic birth runs as it always has.
function C.handledThisFrame(vehicle)
    local n = currentFrameIndex()
    if n == nil or type(vehicle) ~= "table" then return false end
    return rawget(vehicle, C.HANDLED_KEY) == n
end

--- The profile a fresh birth from carrier `kind` earns for output of `fillTypeIndex`,
--- or nil: the pair must be an accepted branch, named by the engine's own fill type
--- name (FillTypeManager:getFillTypeNameByIndex, FillTypeManager.lua:292).
function C.profileFor(kind, fillTypeIndex)
    local ftm = g_fillTypeManager
    if type(fillTypeIndex) ~= "number" or ftm == nil or type(ftm.getFillTypeNameByIndex) ~= "function" then return nil end
    local ok, name = pcall(ftm.getFillTypeNameByIndex, ftm, fillTypeIndex)
    if not ok or type(name) ~= "string" then return nil end
    for _, profile in pairs(C.PROFILES) do
        if profile.kind == kind and profile.fillType == name then return profile end
    end
    return nil
end

--- The profile's wetness in the layer's own encoding, through MaterialWetness's
--- encoder (MaterialWetness.lua:144-150: 80 pct is raw 204, 25 pct is raw 65), or nil
--- when the encoder is not loaded: then the birth is known in age and unknown in
--- wetness, never a number invented here.
function C.profileWetnessRaw(profile)
    if type(MaterialWetness) ~= "table" or type(MaterialWetness.pctToRaw) ~= "function" then return nil end
    local ok, raw = pcall(MaterialWetness.pctToRaw, profile.pct)
    if ok and type(raw) == "number" then return raw end
    return nil
end

--- A GENUINE fresh birth into the frame's account: `litres` this call produced, proved
--- by the native production observation the caller made (header: fresh births). Born
--- at the deposit; the profile's estimate when (frame.kind, fillTypeIndex) is an
--- accepted branch, unknown wetness otherwise. Under a refused barrier the output is
--- explicit unknown, as every litre that call moved is: never the profile, never the
--- generic birth.
---@param frame table          the carrier frame
---@param litres number        the produced litres
---@param fillTypeIndex number|nil  the output's fill type
function C.freshBirth(frame, litres, fillTypeIndex)
    if frame == nil or frame.account == nil then return end
    if type(litres) ~= "number" or litres <= C.EPSILON then return end
    if not frame.barrierOk then
        C.accountAdd(frame.account, litres, nil, nil, frame.today)
        return
    end
    local profile = C.profileFor(frame.kind, fillTypeIndex)
    local wetnessRaw = nil
    if profile ~= nil then
        wetnessRaw = C.profileWetnessRaw(profile)
        if wetnessRaw == nil and not C.firstBirthLogged[profile.id .. ":unencoded"] then
            C.firstBirthLogged[profile.id .. ":unencoded"] = true
            SoilLogger.warning("[GroundCarrier] profile %s cannot be encoded (MaterialWetness.pctToRaw not available): " ..
                "fresh births carry a known age and an unknown wetness", profile.id)
        end
    end
    local birth = {}
    if profile ~= nil and wetnessRaw ~= nil then
        birth.profile, birth.revision, birth.provenance = profile.id, profile.revision, C.PROVENANCE_ESTIMATED_AT_BIRTH
    end
    C.accountAdd(frame.account, litres, AGE_BORN, wetnessRaw, frame.today, birth)
    C.stats.births = C.stats.births + 1
    if birth.profile ~= nil and not C.firstBirthLogged[profile.id] then
        C.firstBirthLogged[profile.id] = true
        SoilLogger.info(
            "[GroundCarrier] FIRST FRESH %s BIRTH: %.1f L born at the deposit with profile %s revision %d " ..
            "(%d%% wet basis, raw %d), provenance estimated-at-birth. A fill type's name alone never earns a profile.",
            tostring(profile.fillType), litres, profile.id, profile.revision, profile.pct, wetnessRaw)
    end
end

--- After the native cut returned: the fresh converted output enters the drop area's
--- account as a fresh birth (above): born at the deposit, the fresh-grass profile when
--- the converter's output is GRASS_WINDROW and unknown wetness for any other output.
--- Under a refused barrier it is of unknown condition, as every litre that call moved
--- is: explicit unknown, never the generic birth (contract section 4).
---
--- THE CAP LOSS NEEDS NOTHING HERE. The native cap (:366-367) leaves the drop area
--- holding less than the account; the next frame over that drop area (another work
--- area's cut, or the drop) reconciles to the native remainder before any primitive
--- reads the account, and a reconcile downward removes uniformly. So the loss discards
--- condition in proportion and is never re-created.
---@param frame table    the cut frame
---@param fresh number   litres the cut produced (the rise in workArea.pickedUpLiters)
---@param fillTypeIndex number|nil  the converter's output type (dropArea.fillType after the cut)
function C.mowerCut(frame, fresh, fillTypeIndex)
    C.freshBirth(frame, fresh, fillTypeIndex)
end
