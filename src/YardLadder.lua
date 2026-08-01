-- =========================================================
-- FS25 Soil & Fertilizer - THE YARD LADDER (SF-46)
-- =========================================================
-- An unwrapped bale left out goes off. Condition, never a fill
-- bleed: this member holds a per-bale CONDITION record in the
-- delivered object ledger, accrues it on a shelter ladder once
-- per day, pauses it under wrap, reads it as bands into the feed
-- chain, and ends it in ONE server-authoritative condemnation
-- event.
--
-- The condemnation write (fillLevel 0 then delete) is the ONLY
-- write this member makes to a bale's fill state.
--
-- SERVER ONLY. Rows ride MaterialDown's object-ledger mechanism
-- (StateLedger table, OPAQUE OWNER TOKEN, enumerate-not-list).
--
-- TWO THINGS THE BRIEF ASSUMED AND THE ENGINE DOES NOT PROVIDE,
-- both honoured in their honest half rather than faked:
--
--   1. THE ENCLOSED TIER. The ruled ladder has three rungs
--      (outdoors 1.0, roof 0.15x, enclosed 0). The engine's
--      shelter predicate is BINARY: indoorMask has INDOOR and
--      OUTDOOR and nothing between (verified against the LUADOC;
--      no three-state predicate exists anywhere in the reference).
--      So v1 ships TWO rungs and an unverifiable enclosure is
--      charged the ROOF rate, never zero. That is the same
--      direction the sibling's rule takes when shelter cannot be
--      proven: unverifiable cover does not earn the benefit. A
--      free rung would stop a yard's condition dead on evidence
--      the engine never gave us.
--
--   2. THE BIRTH AXIS. The birth read returns a WETNESS PERCENT.
--      The ladder accrues CONDITION UNITS. The brief never states
--      the mapping between them, and they cannot be the same
--      number: the ruled horizons (going-off about a wet week at
--      40 units, condemned about 2.5 wet weeks at 100) only hold
--      if condition starts at zero, whereas the seasonal stub
--      would open a winter bale at 75, already past going-off and
--      four wet days from condemnation. So birth wetness is
--      RECORDED and PUBLISHED as its own quantity and does not
--      seed the ladder. Picking the curve that joins them is a
--      design call, not an implementation one; it is on the
--      ledger for Arissani.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class YardLadder
YardLadder = {}
local YardLadder_mt = Class(YardLadder)

-- Ruled numbers (SF-46 brief, NUMBERS ADDENDUM 2026-07-31).
YardLadder.RATES = {
    WET_OUTDOOR     = 6,     -- condition units per wet outdoor day
    DRY_OUTDOOR     = 1,     -- condition units per dry outdoor day
    ROOF_MULTIPLIER = 0.15,  -- open roof, corrected from the 0.4 placeholder
    GOING_OFF_AT    = 40,    -- units: the going-off band opens
    CONDEMN_AT      = 100,   -- units: terminal
    DWELL_EPSILON   = 0.5,   -- metres, the stationary test
}

-- THE BIRTH AXIS, RULED BY ARISSANI 2026-07-30. This is the mapping the first cut
-- guessed at and this member refused to invent.
--
-- A bale made from FIT material is born at ZERO. The penalty is for how far ABOVE the
-- safe-baling line the material was WHEN IT WAS BALED, which is the actual mistake a
-- real farmer makes and the entire reason a fit line exists.
--
--   condition = max(0, wetnessPct - FIT_PCT) x PER_POINT_ABOVE_FIT
--
-- ONE POINT ABOVE THE LINE COSTS ONE WET-DAY EQUIVALENT, so the handicap is expressed
-- in terms of the wet rate rather than as a second free-standing number: if the ladder
-- is ever retuned the handicap follows it, which is what "wet-day equivalent" means.
--
-- Walking it against the ruled ladder, which is how the dial was set:
--   baled at 20 -> 0    a full wet week to going off
--   baled at 25 -> 30   going off inside two wet days
--   baled at 27 -> 42   born already going off
--   baled at 30 -> 60   condemned inside a week
--
-- Deliberately unforgiving: hay baled at 27 percent moulds within a week in a real
-- yard, and a gentler curve would say baling wet costs almost nothing, which is false.
-- Flagged as a DIAL rather than a derivation. If it plays too harsh it is one number.
--
-- The fit line itself is agronomy-fixed rather than taste: the published safe-baling
-- line is 18 to 20 and 20 is the generous edge of safe. Read from the hay member so
-- there is one fit line in the mod, not two.
YardLadder.FIT_PCT_FALLBACK = 20

function YardLadder.fitPct()
    if HayBet ~= nil and type(HayBet.FIT_PCT) == "number" then return HayBet.FIT_PCT end
    return YardLadder.FIT_PCT_FALLBACK
end

--- The ruled birth mapping. Wetness percent in, ladder units out.
---
--- A NIL WETNESS IS NOT A ZERO WETNESS, BUT IT IS A ZERO CONDITION. A bale we have no
--- record for (bought, pre-existing on an upgraded save, or otherwise never watched)
--- opens at zero, because a bale we cannot vouch for is not pre-condemned on a guess.
--- That is this family's refusal-honesty rule pointed at its own birth event, and it
--- is why the old seasonal table is gone: those four numbers were a WETNESS estimate
--- and were never a condition.
---@param wetnessPct number|nil
---@return number condition
function YardLadder.birthCondition(wetnessPct)
    local pct = tonumber(wetnessPct)
    if pct == nil then return 0 end
    local over = pct - YardLadder.fitPct()
    if over <= 0 then return 0 end
    return over * YardLadder.RATES.WET_OUTDOOR
end

-- Condition bands. Names, not numbers, so a balance pass moves the edges without
-- touching a consumer. Mirrors the sibling's BANDS convention.
YardLadder.BAND = {
    FRESH     = "fresh",
    GOING_OFF = "goingOff",
    CONDEMNED = "condemned",
}

local TOKEN_PREFIX = "yl_"

-- =========================================================
-- Construction
-- =========================================================

function YardLadder.new()
    local self = setmetatable({}, YardLadder_mt)
    self.materialDown    = nil
    self.materialWetness = nil
    self.hayBet          = nil
    self.armed           = false

    -- TRANSIENT STATE, owned here and NEVER placed in a ledger record.
    -- MaterialDown:serialize copies records wholesale into the StateLedger table, so
    -- a live Bale reference parked on a record would be handed to the serializer. The
    -- record carries data; everything that cannot survive a save lives in this table.
    self._live    = {}   -- token -> { nodeId, bale, lastPosX, lastPosZ, lastCheckDay }
    self._byNode  = {}   -- nodeId -> token
    self._nextId  = 1
    self._orphanReported = false

    -- THE BIRTH SAMPLE (RULED 2026-07-31). Per-baler pickup accumulators, keyed by
    -- the vehicle table itself under a WEAK key so a sold or deleted baler cannot
    -- pin state here. Never serialized: this is transient by the same rule as _live.
    self._balerAcc = setmetatable({}, { __mode = "k" })
    self._pendingBirth = nil   -- set by createBale, consumed by the next Bale.register
    return self
end

---@param materialDown    MaterialDown
---@param materialWetness MaterialWetness|nil
---@param hayBet          HayBet|nil
function YardLadder:arm(materialDown, materialWetness, hayBet)
    self.armed = false
    if materialDown == nil or not materialDown:isArmed() then
        SoilLogger.info("[YardLadder] MaterialDown not armed - standing down")
        return false
    end
    self.materialDown    = materialDown
    self.materialWetness = materialWetness  -- may be nil (SF-49 absent)
    self.hayBet          = hayBet           -- may be nil (SF-44 absent)
    self.armed           = true

    -- The token counter must clear every token already in the ledger, or a reload
    -- would mint a token that collides with a surviving row.
    self:_seedTokenCounter()

    local R = YardLadder.RATES
    SoilLogger.info("[OK] YardLadder armed (wet=%d/d dry=%d/d roof=x%.2f goingOff=%d condemn=%d)",
        R.WET_OUTDOOR, R.DRY_OUTDOOR, R.ROOF_MULTIPLIER, R.GOING_OFF_AT, R.CONDEMN_AT)

    -- The optional boot-time RealisticWeather presence line (Arissani's, TAKEN in the
    -- brief's status line). RW rots bales too; when a player reports a vanished bale
    -- this line plus our one condemnation line is how the two are told apart.
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_RealisticWeather"] then
        SoilLogger.info("[YardLadder] RealisticWeather present: it deletes bales too, so read the CONDEMN line before attributing one to us")
    end
    return true
end

function YardLadder:isArmed()
    return self.armed
end

--- Walk the surviving rows so a fresh token can never collide with a loaded one.
function YardLadder:_seedTokenCounter()
    local highest = 0
    self.materialDown:enumerateObjects(function(token)
        local n = YardLadder._tokenSerial(token)
        if n ~= nil and n > highest then highest = n end
    end)
    self._nextId = highest + 1
end

-- =========================================================
-- Tokens
-- =========================================================
-- OPAQUE and MINTED, never derived from the bale.
--
-- The obvious key is the bale's nodeId, and it is wrong: scenegraph node ids are not
-- stable across a save and reload. A nodeId token would orphan every row the moment
-- the game restarted, hand each reloaded bale a fresh condition, and leave the dead
-- rows in the savegame forever. The token is minted here and the nodeId lives in the
-- transient index instead.

function YardLadder._tokenSerial(token)
    if type(token) ~= "string" then return nil end
    if token:sub(1, #TOKEN_PREFIX) ~= TOKEN_PREFIX then return nil end
    return tonumber(token:sub(#TOKEN_PREFIX + 1))
end

function YardLadder._isOurToken(token)
    return YardLadder._tokenSerial(token) ~= nil
end

function YardLadder:_mintToken()
    local token = TOKEN_PREFIX .. tostring(self._nextId)
    self._nextId = self._nextId + 1
    return token
end

-- =========================================================
-- Birth, and the re-attach that shares its door
-- =========================================================

--- A bale entered the world. Either it is one of ours coming back (reload, or
--- PlaceableObjectStorage handing it out again) or it is new.
---
--- THE RE-ATTACH IS NOT STORAGE-SPECIFIC ON PURPOSE. The brief scopes the heuristic to
--- PlaceableObjectStorage, but storage is only one of the two doors a known bale comes
--- back through; a savegame reload is the other, and it is the common one. Both arrive
--- here as "a bale appeared and may already have a row", so both take the same path.
---@param nodeId       number   bale scenegraph node
---@param bale         table    live bale object
---@param fillTypeName string
---@param fillLevel    number   litres, the newborn bale's own
---@param farmId       number
---@param capacity     number
function YardLadder:onBaleCreated(nodeId, bale, fillTypeName, fillLevel, farmId, capacity)
    if not self:isArmed() then return end
    if g_server == nil then return end
    if nodeId == nil then return end
    local md = self.materialDown
    if md == nil then return end

    -- Same node twice (a double register, or our own hook re-entered) is a no-op.
    if self._byNode[nodeId] ~= nil then return end

    local existing = self:_findUnattachedMatch(farmId, fillTypeName, capacity)
    if existing ~= nil then
        self:_attach(existing, nodeId, bale)
        local row = md:getObjectRecord(existing)
        SoilLogger.debug("[YardLadder] re-attached %s to node %s (condition %.1f)",
            existing, tostring(nodeId), (row and row.condition) or 0)
        return
    end

    -- No candidate. ACCEPT AND LOG, never silently fresh: if there were unattached
    -- rows and none matched, the bale keeps its fresh row but the mismatch is said out
    -- loud, because that is the line that tells us the heuristic key is too narrow.
    local stranded = self:_countUnattached()
    if stranded > 0 and not self._orphanReported then
        self._orphanReported = true
        SoilLogger.info("[YardLadder] no row matched an arriving bale (farm=%s fill=%s cap=%s); %d row(s) still unattached, accepting as new",
            tostring(farmId), tostring(fillTypeName), tostring(capacity), stranded)
    end

    local wetnessPct = self:_birthWetness(nodeId, fillLevel)
    local token = self:_mintToken()

    -- DATA ONLY. Nothing here may be a live reference or a scenegraph handle.
    local row = {
        condition       = YardLadder.birthCondition(wetnessPct),
        birthWetnessPct = wetnessPct,   -- published in its own right, never the ladder
        farmId          = farmId or 0,
        fillTypeName    = fillTypeName or "UNKNOWN",
        capacity        = capacity or 0,
        bornDay         = self:_today(),
    }

    if not md:createObjectRecord(token, row) then return end
    self:_attach(token, nodeId, bale)

    SoilLogger.debug("[YardLadder] birth %s node=%s farm=%s fill=%s cap=%s wetness=%s condition=%.1f",
        token, tostring(nodeId), tostring(farmId), tostring(fillTypeName), tostring(capacity),
        wetnessPct ~= nil and string.format("%.1f", wetnessPct) or "unknown", row.condition)

    self:publishWetnessAtBaling(token, fillTypeName, wetnessPct)
end

--- Heuristic key: farm + fill type + capacity, oldest row first so the choice is
--- deterministic. Rows sharing all three are interchangeable except for condition, so
--- picking among them cannot be wrong in any way a player could observe.
function YardLadder:_findUnattachedMatch(farmId, fillTypeName, capacity)
    local best, bestBorn = nil, nil
    self.materialDown:enumerateObjects(function(token, row)
        if not YardLadder._isOurToken(token) then return end
        if self._live[token] ~= nil then return end
        if type(row) ~= "table" then return end
        if row.farmId ~= (farmId or 0) then return end
        if row.fillTypeName ~= (fillTypeName or "UNKNOWN") then return end
        if math.abs((row.capacity or 0) - (capacity or 0)) > 1 then return end
        local born = row.bornDay or 0
        if bestBorn == nil or born < bestBorn then
            best, bestBorn = token, born
        end
    end)
    return best
end

function YardLadder:_countUnattached()
    local n = 0
    self.materialDown:enumerateObjects(function(token)
        if YardLadder._isOurToken(token) and self._live[token] == nil then n = n + 1 end
    end)
    return n
end

function YardLadder:_attach(token, nodeId, bale)
    self._live[token] = {
        nodeId       = nodeId,
        bale         = bale,
        lastPosX     = nil,
        lastPosZ     = nil,
        lastCheckDay = nil,
    }
    self._byNode[nodeId] = token
end

function YardLadder:_detach(token)
    local live = self._live[token]
    if live ~= nil and live.nodeId ~= nil then
        self._byNode[live.nodeId] = nil
    end
    self._live[token] = nil
end

-- =========================================================
-- THE BIRTH SAMPLE: sample at the pickup, weight by litres, stamp at birth
-- =========================================================
-- RULED 2026-07-31. A bale is what the pickup ate, so its birth wetness is the
-- LITRES-WEIGHTED AVERAGE of everything that fed the chamber. A round bale fills
-- over a long run and a field is not one wetness: the headland sits shaded and damp
-- while the middle is baked. One wet patch inside a big dry bale is not a wet bale;
-- a bale that is mostly wet is.
--
-- This is NOT a new aggregation rule. SF-25's ratified positional integral is
-- area-weighted and this family already sharpened it to MASS-weighted, because
-- material lies in windrows and does not cover the ground. Litres picked up IS the
-- mass term, so the clause inherits rather than invents.
--
-- WHY WE KEEP OUR OWN ACCUMULATOR instead of riding the engine's, which is what the
-- clause originally proposed. Certified against dataS: Baler:finishBale FORKS.
-- A baler WITH an unloading animation calls createBale immediately (Baler.lua:1432)
-- and never touches spec.pickupFillTypes there; its reset happens later, at drop
-- (:930-932). A baler WITHOUT one zeroes the accumulator (:1440-1442) and THEN calls
-- createBale (:1443), so the engine's accumulator is ALREADY ZERO at the moment that
-- kind of bale is born. Riding it would silently produce no-wetness bales for half
-- the balers in the game, and by the refusal law that is indistinguishable from an
-- honest unknown. The RULE is untouched; only the site is ours.

--- One pickup pass. Called from the Baler hook, server side, with the wetness read
--- taken BEFORE the pass ate the material and the litres it actually took.
---@param baler table   the baler vehicle, used only as an identity key
---@param pct   number|nil  wetness percent over the pickup area, nil when unknown
---@param litres number     litres this pass took
function YardLadder:noteBalerPickup(baler, pct, litres)
    if not self:isArmed() then return end
    if baler == nil then return end
    local q = tonumber(litres)
    if q == nil or q <= 0 then return end

    local acc = self._balerAcc[baler]
    if acc == nil then
        acc = { weighted = 0, knownLitres = 0, unknownLitres = 0 }
        self._balerAcc[baler] = acc
    end

    if pct == nil then
        -- The pass took material we could not read. It is counted, so the bale can
        -- say how much of itself it cannot vouch for, but it never enters the mean.
        acc.unknownLitres = acc.unknownLitres + q
        return
    end
    acc.weighted    = acc.weighted + pct * q
    acc.knownLitres = acc.knownLitres + q
end

--- Close the chamber. Called from the Baler hook the moment a bale is created, which
--- is where the engine's own accumulator lifecycle is unreliable and ours is not.
---@param baler table
function YardLadder:closeBalerChamber(baler)
    if baler == nil then return end
    local acc = self._balerAcc[baler]
    self._balerAcc[baler] = nil
    if acc == nil then return end

    -- REFUSAL HONESTY, unchanged by this clause: an accumulator that saw no readable
    -- material hands over nothing at all. The bale is then born at zero and records
    -- no wetness, exactly as before. It is NOT a wetness of zero.
    if acc.knownLitres <= 0 then
        self._pendingBirth = nil
        return
    end
    self._pendingBirth = {
        pct           = acc.weighted / acc.knownLitres,
        knownLitres   = acc.knownLitres,
        unknownLitres = acc.unknownLitres,
    }
end

--- Consume the pending sample. Single use: a bale entering the world through any
--- other door (unpacking, console, storage retrieval, savegame load) finds nothing
--- here and falls through to the ground read, which is the correct answer for it.
function YardLadder:_takePendingBirth()
    local p = self._pendingBirth
    self._pendingBirth = nil
    return p
end

--- The birth read. The pickup sample when a baler just made this bale, otherwise the
--- ground band when the hay member and the sky member are both live.
---@return number|nil wetnessPct  nil means NO RECORD, which is not a wetness of zero
function YardLadder:_birthWetness(nodeId, fillLevel)
    -- THE PICKUP SAMPLE WINS when there is one, because it measured the material
    -- while it still existed. The ground read below cannot: by the time a bale is
    -- registered, the swath it was made from has already been eaten, which is why
    -- every baled bale recorded an unknown wetness before this clause.
    local pending = self:_takePendingBirth()
    if pending ~= nil then
        local total = pending.knownLitres + pending.unknownLitres
        if pending.unknownLitres > 0 then
            SoilLogger.debug("[YardLadder] birth sample: %.1f%% over %.0f of %.0f L (%.0f L unreadable)",
                pending.pct, pending.knownLitres, total, pending.unknownLitres)
        end
        return pending.pct
    end

    local mw = self.materialWetness
    if mw ~= nil and mw:isArmed()
       and self.hayBet ~= nil and self.hayBet:isArmed()
       and entityExists ~= nil and entityExists(nodeId) then
        local ok, x, _, z = pcall(getWorldTranslation, nodeId)
        if ok and x ~= nil then
            -- A one-metre square under the bale. LITRES IS NON-OPTIONAL and the
            -- newborn bale's own fill level is the quantity the brief names; a nil or
            -- zero here is a caller bug and readCondition correctly refuses it.
            local verts = {
                { x = x - 0.5, z = z - 0.5 },
                { x = x + 0.5, z = z - 0.5 },
                { x = x + 0.5, z = z + 0.5 },
                { x = x - 0.5, z = z + 0.5 },
            }
            local c = mw:readCondition(verts, fillLevel)
            if c ~= nil and c.status == MaterialWetness.RESULT.OK then
                return c.pct
            end
            -- REFUSAL PROPAGATES, and now it propagates all the way out as NIL.
        end
    end
    -- NO RECORD. Not a wetness of zero, not a seasonal guess: unknown. The caller
    -- opens such a bale at zero condition, per the ruling, because a bale we cannot
    -- vouch for must not be pre-condemned on an estimate.
    return nil
end

--- Today, for stamping a birth. The accrual's ctx.monotonicDay is the authority on
--- the pass itself; this is only for rows born between passes, so it reads the same
--- basis the engine exposes as a FIELD (currentMonotonicDay). There is no documented
--- getDay() method and this member does not invent one.
function YardLadder:_today()
    local env = g_currentMission and g_currentMission.environment
    local day = env and env.currentMonotonicDay
    return tonumber(day) or 0
end

-- The seasonal birth stub (spring 65 / summer 55 / autumn 70 / winter 75) is DELETED,
-- not disabled. Its brief said "deleted when the hay member lands", the hay member has
-- landed, and the birth-axis ruling settled what it was standing in for: those four
-- numbers were a WETNESS estimate and were never a condition. A bale with no record
-- opens at zero.

-- =========================================================
-- Death
-- =========================================================

--- A bale left the world: sold, fed out, mixed, condemned by us, condemned by
--- RealisticWeather, or taken by the engine's bale cap. One door for all of them.
function YardLadder:onBaleRemoved(nodeId)
    if not self:isArmed() then return end
    if g_server == nil then return end
    if nodeId == nil then return end
    local token = self._byNode[nodeId]
    if token == nil then return end
    self:_detach(token)
    if self.materialDown ~= nil then
        self.materialDown:removeObjectRecord(token)
    end
end

-- =========================================================
-- The daily ladder pass
-- =========================================================

--- One Time Guard accrual, day cadence, on the everything-else slot (never the age
--- tick). Enumerates OUR rows and only ours. Cost is linear in ledger rows and makes
--- no engine pass at all, so it does not move the family's measured millisecond bill.
function YardLadder:onLadderPass(ctx)
    if not self:isArmed() then return end
    if g_server == nil then return end
    local md = self.materialDown
    if md == nil then return end

    local day = ctx and tonumber(ctx.monotonicDay)
    if day == nil then return end

    -- HOW MANY DAYS ACTUALLY PASSED, not how many settles fired.
    --
    -- A tablet time-skip crosses months in one settle. Both siblings already read
    -- this: MaterialDown ages the layer by the full span and MaterialWetness applies
    -- the whole weather window. This member did not, so it charged ONE day per skip
    -- no matter how long the skip was, and a bale left in a yard survived a simulated
    -- year at a cost of one dry day. Observed in game 2026-07-31: two bales outdoors
    -- across roughly a year, still there, untouched.
    local boundaries = math.floor(tonumber(ctx.boundariesCrossed) or 1)
    if boundaries < 1 then boundaries = 1 end

    -- Collected first: condemnation mutates the ledger, and mutating a table while
    -- pairs() walks it is undefined in Lua 5.1.
    local due = {}
    md:enumerateObjects(function(token, row)
        if YardLadder._isOurToken(token) and type(row) == "table" then
            due[#due + 1] = { token = token, row = row }
        end
    end)

    -- Split the crossed span into wet and dry days ONCE, from the Water Record, rather
    -- than asking per bale. `waterDaysInLast` returns how many of the last N days
    -- brought water and how many of those N it actually has a record for; days it
    -- cannot reach count as DRY, which is the neutral-when-absent direction and is the
    -- one that cannot condemn a yard on evidence we do not have.
    local wetDays, dryDays = self:_splitSpan(boundaries, day)

    -- THE PASS SAYS IT RAN, and it has to. Every day pass in this family was silent:
    -- the age tick, the condition accrual and this one all did their work and printed
    -- nothing. So when two bales survived a skipped year there was no way to tell
    -- "the pass never fired" from "it fired and the span was wrong" from "the days
    -- never advanced". One line ends that ambiguity for good.
    SoilLogger.debug("[YardLadder] pass: day=%d boundaries=%d wet=%d dry=%d rows=%d",
        day, boundaries, wetDays, dryDays, #due)

    for _, item in ipairs(due) do
        local ok, err = pcall(function()
            self:_processRow(item.token, item.row, day, wetDays, dryDays)
        end)
        if not ok then
            SoilLogger.warning("[YardLadder] row %s failed its pass: %s", item.token, tostring(err))
        end
    end
end

--- How many of the `span` days ending at `throughDay` were wet, and how many dry.
---@return number wetDays, number dryDays
function YardLadder:_splitSpan(span, throughDay)
    local mw = self.materialWetness
    if mw == nil or not mw:isArmed() then return 0, span end
    local ok, count = pcall(mw.waterDaysInLast, mw, span, throughDay)
    if not ok or type(count) ~= "number" then return 0, span end
    if count > span then count = span end
    return count, span - count
end

function YardLadder:_processRow(token, row, day, wetDays, dryDays)
    local live = self._live[token]

    -- Unattached: the row survived a save but no bale has claimed it back yet. It
    -- cannot be located, so it cannot accrue. It is NOT deleted either, because the
    -- bale may still be inside a PlaceableObjectStorage waiting to be handed out.
    if live == nil then return end

    -- The node may have gone without our delete hook seeing it. entityExists is the
    -- documented guard; getWorldTranslation on a dead node is not safe to call.
    if entityExists == nil or not entityExists(live.nodeId) then
        self:onBaleRemoved(live.nodeId)
        return
    end

    -- WRAP IS ABSOLUTE ARMOUR IN V1 (ratification call b, resolved 2026-07-31). While
    -- the engine's own fermentation clock runs, ours does not: one clock per bale.
    if self:_isFermenting(live.bale) then return end

    local ok, x, _, z = pcall(getWorldTranslation, live.nodeId)
    if not ok or x == nil then return end

    -- DWELL AT DAY GRAIN. A bale that moved since yesterday's sample was in transit
    -- and accrues nothing, so a hauled load is never charged for the trip. A parked
    -- trailer is stationary and does accrue, which is the case the rule is for.
    local moved = false
    if live.lastPosX ~= nil and live.lastCheckDay ~= nil and live.lastCheckDay ~= day then
        local dx, dz = x - live.lastPosX, z - live.lastPosZ
        local eps = YardLadder.RATES.DWELL_EPSILON
        moved = (dx * dx + dz * dz) > (eps * eps)
    end

    live.lastPosX, live.lastPosZ, live.lastCheckDay = x, z, day
    if moved then return end

    local R = YardLadder.RATES
    -- The whole crossed span at once. SHELTER IS SAMPLED ONCE, HERE, and applied to
    -- the span: we know where the bale is now and have no record of where it stood on
    -- each skipped day. That is the same assumption the dwell check above already
    -- makes, and the honest one, since a bale that had moved would have failed dwell.
    local rate = (wetDays or 0) * R.WET_OUTDOOR + (dryDays or 0) * R.DRY_OUTDOOR
    local shelter = self:_shelterMultiplier(x, z)
    local before = row.condition or 0
    row.condition = before + rate * shelter

    SoilLogger.debug("[YardLadder] %s: %.1f -> %.1f (+%.1f, shelter x%.2f)",
        token, before, row.condition, rate * shelter, shelter)

    if row.condition >= R.CONDEMN_AT then
        self:_condemn(token, row, live)
    end
end

--- Outdoors full rate, under cover the roof rate. See the enclosed-tier note at the
--- top of the file: the engine's predicate is binary, so there is no third rung to
--- read, and cover we cannot verify is charged rather than exempted.
function YardLadder:_shelterMultiplier(x, z)
    if MaterialWetness == nil or MaterialWetness.isSheltered == nil then return 1.0 end
    local sheltered = MaterialWetness.isSheltered(x, z)
    -- nil means the mask is unavailable, and the invariant is neutral-when-absent:
    -- no mask reads as outdoors.
    if sheltered == true then return YardLadder.RATES.ROOF_MULTIPLIER end
    return 1.0
end

function YardLadder:_isFermenting(bale)
    if bale == nil then return false end
    local bm = g_currentMission and g_currentMission.baleManager
    if bm == nil or bm.getFermentationTime == nil then return false end
    local ok, t = pcall(bm.getFermentationTime, bm, bale)
    return ok and t ~= nil
end

-- =========================================================
-- Condemnation
-- =========================================================

--- ONE server-authoritative event, ONE attributable log line. RealisticWeather deletes
--- bales as well, so this line is the only way a player report naming a vanished bale
--- can be told apart from theirs. It stays at info level for that reason.
function YardLadder:_condemn(token, row, live)
    SoilLogger.info("[YardLadder] CONDEMN %s: farm=%s fill=%s cap=%s condition=%.1f (SoilFertilizer removed this bale)",
        token, tostring(row.farmId), tostring(row.fillTypeName), tostring(row.capacity), row.condition or 0)

    local bale = live and live.bale

    -- The row dies first so the delete hook cannot re-enter and act on a live row.
    self:_detach(token)
    self.materialDown:removeObjectRecord(token)

    if bale == nil or bale.delete == nil then
        -- Reached terminal condition with no object to act on. Say so rather than
        -- leaving a silently immortal bale behind: the row is gone, the bale is not.
        SoilLogger.warning("[YardLadder] %s hit terminal condition with no live bale reference - row dropped, bale left in world", token)
        return
    end

    -- MixerWagon.md:896/:898 idiom: empty it, then delete it.
    pcall(function()
        if bale.setFillLevel ~= nil then bale:setFillLevel(0) end
        bale:delete()
    end)
end

-- =========================================================
-- The read: bands, never a raw number
-- =========================================================

--- The feed chain's read. Bands are the contract; the unit count behind them is ours.
---@return string|nil band, number|nil condition
function YardLadder:getConditionBand(token)
    if not self:isArmed() or self.materialDown == nil then return nil end
    local row = self.materialDown:getObjectRecord(token)
    if type(row) ~= "table" then return nil end
    local c = row.condition or 0
    local R = YardLadder.RATES
    if c >= R.CONDEMN_AT then return YardLadder.BAND.CONDEMNED, c end
    if c >= R.GOING_OFF_AT then return YardLadder.BAND.GOING_OFF, c end
    return YardLadder.BAND.FRESH, c
end

--- The same read addressed by the thing a caller actually holds: a bale node.
function YardLadder:getConditionBandForNode(nodeId)
    local token = self._byNode[nodeId]
    if token == nil then return nil end
    return self:getConditionBand(token)
end

-- =========================================================
-- Publications
-- =========================================================
-- PUBLISH ONLY. DairyCore is the sole writer of Feed Provenance and this member never
-- writes it. The input-spec rider on this brief carries both of these onto the Feed
-- Provenance brief; until that lands there is no consumer, so the publication is a
-- message-centre emit plus a line, and the shape is what the rider will bind to.

YardLadder.MESSAGE_WETNESS_AT_BALING = "SoilFertilizer_YardLadder_wetnessAtBaling"
YardLadder.MESSAGE_CONDITION_AT_FEED = "SoilFertilizer_YardLadder_conditionAtFeed"

function YardLadder:publishWetnessAtBaling(token, fillTypeName, wetnessPct)
    if wetnessPct == nil then return end
    SoilLogger.debug("[YardLadder] publish wetness-at-baling: %s fill=%s wetness=%.1f",
        tostring(token), tostring(fillTypeName), wetnessPct)
    if g_messageCenter ~= nil and g_messageCenter.publish ~= nil then
        pcall(function()
            g_messageCenter:publish(YardLadder.MESSAGE_WETNESS_AT_BALING, token, fillTypeName, wetnessPct)
        end)
    end
end

--- Called at feeding by the feed chain. Publishes the BAND, not the unit count.
function YardLadder:publishConditionAtFeed(nodeId)
    local band, condition = self:getConditionBandForNode(nodeId)
    if band == nil then return nil end
    SoilLogger.debug("[YardLadder] publish condition-at-feed: node=%s band=%s condition=%.1f",
        tostring(nodeId), band, condition or 0)
    if g_messageCenter ~= nil and g_messageCenter.publish ~= nil then
        pcall(function()
            g_messageCenter:publish(YardLadder.MESSAGE_CONDITION_AT_FEED, nodeId, band, condition)
        end)
    end
    return band
end

---- End of file
SoilLogger.info("YardLadder (SF-46) loaded")
