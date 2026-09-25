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
YardLadder = YardLadder or {}
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
-- [RSF-F215] Rows, portions, carrier states and events
-- =========================================================
-- A row is one bale's condition record in MaterialDown's object ledger, schema 2:
--
--   { schema = 2, token, nativeBaleUniqueId, nativeFillType, observedLitres, farmId,
--     carrierState, rowRevision, nextCarrierEventSequence, portions,
--     capacity, bornDay, fillTypeName }            -- the last three: compatibility only
--
-- and every portion (one per bale in this build; a pack of several is the held wider
-- work) carries
--
--   { historyId, sourceStreamId, nextEventSequence, portionRevision, litres, profileId,
--     profileVersion, historyKnowledge, condition, birthWetnessKnown, birthWetnessPct,
--     observedFromDay, lastSettledDay, conditionGeneration }
--
-- BINDING IS THE NATIVE UNIQUE ID, never a similarity. A bale has its persistent id when
-- it registers (Bale:loadFromConfigXML sets a loaded one, Bale.lua:269-270, and the item
-- system assigns one otherwise, ItemSystem.lua:209-213); it keeps it through object
-- storage (PlaceableObjectStorage.lua:947, :965, :1161) and a savegame. The old
-- farm + fill type + capacity match is gone: a row nothing can prove is UNBOUND and
-- stays unknown.
--
-- CARRIER STATES. WORLD: the bale is registered in the world. STORED: it is in an object
-- storage (its native object may not exist). PENDING: loaded from a save, waiting for its
-- bale to register. UNBOUND: no native id can be proved (a legacy row, or a row from a
-- store the career did not vouch for).
--
-- EVENTS. BIRTH (a new row), ADVANCE (the daily condition increase), REBIND (into or out
-- of storage), RETIRE (the bale left, condemnation included). RESET belongs to a proved
-- unwrap, a physical policy that is held; nothing emits it in this build. Each event:
-- every listener's beforeChange, the change once, the row and portion coordinates
-- committed, then every listener's afterChange (or invalidate, when its before failed or
-- its after throws). A listener error never blocks the change.

YardLadder.ROW_SCHEMA = 2
YardLadder.PROFILE_ID = "SOIL_BALE_CONDITION_V1"
YardLadder.PROFILE_VERSION = 1
YardLadder.CARRIER = { WORLD = "WORLD", STORED = "STORED", PENDING = "PENDING", UNBOUND = "UNBOUND" }
YardLadder.KNOWLEDGE = { KNOWN = "KNOWN", UNKNOWN = "UNKNOWN" }
YardLadder.EVENT = { BIRTH = "BIRTH", ADVANCE = "ADVANCE", RESET = "RESET", REBIND = "REBIND", RETIRE = "RETIRE" }
YardLadder.RESULT = { APPLIED = "APPLIED", PARTIAL = "PARTIAL", FAILED = "FAILED", UNAVAILABLE = "UNAVAILABLE" }
YardLadder.STATE = { READY = "READY", RESTORING = "RESTORING", UNAVAILABLE = "UNAVAILABLE" }
YardLadder.CAPABILITY_SCHEMA = "SG_SOIL_CONDITION_1"
-- Native fill levels are floats; a portion sum within this of the observed amount agrees.
YardLadder.LITRE_EPSILON = 0.01

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function counter(n) return finite(n) and n >= 0 and n == math.floor(n) end

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
    -- MaterialDown:serialize copies records wholesale, so a live Bale reference parked on
    -- a record would be handed to the serializer. The record carries data; everything
    -- that cannot survive a save lives in these tables.
    self._live    = {}   -- token -> { nodeId, bale, lastPosX, lastPosZ, lastCheckDay }
    self._byNode  = {}   -- nodeId -> token
    self._byUid   = {}   -- nativeBaleUniqueId -> token (rebuilt, never saved)
    self._conflict = {}  -- token -> reason, when a second live bale claimed its id
    self._storing = {}   -- bale object -> true inside an object storage's addToStorage
    self._listeners = {} -- ordered { id, lease, callbacks }
    self._loaded = false
    self._discoveryComplete = false
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

    -- [RSF-F215] The row owner validates rows before they go live and before a save, and
    -- qualifies them once the store's load is decided. The decision itself waits: this
    -- member arms inside the mission's load (SoilFertilityManager:onMissionLoaded), before
    -- StateLedger and the own file have delivered, so the first use after every delivery
    -- makes it (see _ensureLoaded).
    materialDown.rowValidator = YardLadder.validateRows
    materialDown:addLoadObserver("yardLadder", function(state) self:_onLoadDecided(state) end)

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

--- Decide the store's load if nobody has yet. Every door that reads or writes rows calls
--- it first; bales register only after the mission's load has delivered everything
--- (savegame items load in asynchronous steps after loadMission00Finished), so the first
--- birth is late enough.
function YardLadder:_ensureLoaded()
    if self._loaded then return end
    local md = self.materialDown
    if md == nil then return end
    md:finishLoad()
    if not self._loaded then self:_onLoadDecided(md.loadState) end
end

--- Qualify the rows once the store's load is decided, and seed the allocator above every
--- serial a surviving row holds.
function YardLadder:_onLoadDecided(state)
    if self._loaded then return end
    self._loaded = true
    local md = self.materialDown
    local L = MaterialDown.LOAD
    self._byUid = {}
    md:enumerateObjects(function(token, row)
        if not YardLadder._isOurToken(token) or type(row) ~= "table" then return end
        if state == L.MODERN and row.schema == YardLadder.ROW_SCHEMA then
            -- Loaded rows wait for their bale; a stored bale stays stored.
            if row.carrierState == YardLadder.CARRIER.WORLD then row.carrierState = YardLadder.CARRIER.PENDING end
            if row.carrierState ~= YardLadder.CARRIER.UNBOUND and type(row.nativeBaleUniqueId) == "string" then
                self._byUid[row.nativeBaleUniqueId] = token
            end
        else
            -- Legacy, or a store nobody vouched for: kept as data, never trusted.
            row.carrierState = YardLadder.CARRIER.UNBOUND
        end
        md:reserveTokenSerial(YardLadder._tokenSerial(token))
        if type(row.portions) == "table" then
            for _, p in ipairs(row.portions) do
                md:reserveTokenSerial(YardLadder._tokenSerial(p.historyId))
                md:reserveTokenSerial(YardLadder._tokenSerial(p.sourceStreamId))
            end
        end
    end)
end

--- The mission has started: every savegame item has loaded, so a row still PENDING has
--- no bale that registered, and the provider stops saying RESTORING for it.
function YardLadder:onMissionStarted()
    if not self:isArmed() then return end
    self:_ensureLoaded()
    self._discoveryComplete = true
end

-- =========================================================
-- Tokens
-- =========================================================
-- OPAQUE and MINTED, never derived from the bale. The row, history and stream tokens all
-- come from the one Soil token allocator (MaterialDown:allocateTokenSerial), which is
-- persisted with the store and seeded above every surviving serial.

local HISTORY_PREFIX, STREAM_PREFIX = "yh_", "ys_"

function YardLadder._tokenSerial(token)
    if type(token) ~= "string" then return nil end
    for _, prefix in ipairs({ TOKEN_PREFIX, HISTORY_PREFIX, STREAM_PREFIX }) do
        if token:sub(1, #prefix) == prefix then
            local n = tonumber(token:sub(#prefix + 1))
            if counter(n) and n >= 1 then return n end
            return nil
        end
    end
    return nil
end

function YardLadder._isOurToken(token)
    return type(token) == "string" and token:sub(1, #TOKEN_PREFIX) == TOKEN_PREFIX and YardLadder._tokenSerial(token) ~= nil
end

function YardLadder:_mint(prefix)
    local n, why = self.materialDown:allocateTokenSerial()
    if n == nil then return nil, why end
    return prefix .. string.format("%d", n)
end

-- =========================================================
-- Portions: read, detached
-- =========================================================

--- The bale's condition across its portions, weighted by litres (one portion: its own).
function YardLadder.rowCondition(row)
    if type(row) ~= "table" then return nil end
    if row.schema ~= YardLadder.ROW_SCHEMA then return tonumber(row.condition) or 0 end
    local sum, litres = 0, 0
    for _, p in ipairs(row.portions or {}) do
        local q = tonumber(p.litres) or 0
        sum, litres = sum + q * (tonumber(p.condition) or 0), litres + q
    end
    if litres > 0 then return sum / litres end
    local p = row.portions and row.portions[1] or nil
    return p ~= nil and (tonumber(p.condition) or 0) or 0
end

local function portionCoordinates(p, sourceEpoch)
    return {
        historyId           = p.historyId,
        conditionGeneration = p.conditionGeneration,
        profileId           = p.profileId,
        profileVersion      = p.profileVersion,
        historyKnowledge    = p.historyKnowledge,
        condition           = p.condition,
        condemned           = (tonumber(p.condition) or 0) >= YardLadder.RATES.CONDEMN_AT,
        sourceStreamId      = p.sourceStreamId,
        sourceEpoch         = sourceEpoch,
        eventSequence       = (p.nextEventSequence or 1) - 1,
        portionRevision     = p.portionRevision,
        lastSettledDay      = p.lastSettledDay,
        litres              = p.litres,
    }
end

function YardLadder:_detachedPortions(row)
    local out = {}
    if type(row) ~= "table" or type(row.portions) ~= "table" then return out end
    local meta = self.materialDown ~= nil and self.materialDown:getBaleConditionMeta() or nil
    local epoch = meta ~= nil and meta.sourceEpoch or nil
    for i, p in ipairs(row.portions) do out[i] = portionCoordinates(p, epoch) end
    return out
end

-- =========================================================
-- Listeners (trusted server initialization only; never saved)
-- =========================================================

---@return table|nil lease, string|nil reason
function YardLadder:registerListener(listenerId, callbacks)
    if g_server == nil then return nil, "NOT_SERVER" end
    if type(listenerId) ~= "string" or listenerId == "" then return nil, "BAD_ID" end
    if type(callbacks) ~= "table" or type(callbacks.beforeChange) ~= "function"
       or type(callbacks.afterChange) ~= "function" or type(callbacks.invalidate) ~= "function" then
        return nil, "BAD_CALLBACKS"
    end
    for _, l in ipairs(self._listeners) do
        if l.id == listenerId then return nil, "DUPLICATE_LISTENER" end
    end
    local lease = setmetatable({}, { __tostring = function() return "BaleConditionListenerLease" end })
    self._listeners[#self._listeners + 1] = {
        id = listenerId, lease = lease,
        beforeChange = callbacks.beforeChange, afterChange = callbacks.afterChange, invalidate = callbacks.invalidate,
    }
    return lease
end

function YardLadder:unregisterListener(lease)
    for i, l in ipairs(self._listeners) do
        if l.lease == lease then
            table.remove(self._listeners, i)
            return true
        end
    end
    return false
end

--- One change, notified: every listener's before, the change once, the coordinates
--- committed, every listener's after. `change(row)` performs the change on the live row
--- and returns (resultRow, result): the row after (nil when retired) and the result.
function YardLadder:_notifyChange(kind, row, change, operationId)
    local before = {
        schemaVersion        = 1,
        kind                 = kind,
        carrierEventSequence = row ~= nil and row.nextCarrierEventSequence or 1,
        beforeCarrierRevision = row ~= nil and row.rowRevision or 0,
        nativeIds            = { row ~= nil and row.nativeBaleUniqueId or nil },
        portionsBefore       = self:_detachedPortions(row),
        operationId          = operationId,
    }
    local tickets = {}
    for i, l in ipairs(self._listeners) do
        local ok, ticket = pcall(l.beforeChange, MaterialDown.deepCopy(before))
        tickets[i] = { ok = ok, ticket = ticket }
    end

    local okChange, after, result = pcall(change, row)
    if not okChange then
        SoilLogger.warning("[YardLadder] %s failed: %s", kind, tostring(after))
        after, result = row, YardLadder.RESULT.FAILED
    end

    local event = MaterialDown.deepCopy(before)
    event.result = result or YardLadder.RESULT.APPLIED
    if after ~= nil then
        event.nativeIds = { after.nativeBaleUniqueId }
        event.afterCarrierRevision = after.rowRevision
        event.portionsAfter = self:_detachedPortions(after)
    else
        event.afterCarrierRevision = (before.beforeCarrierRevision or 0) + 1
        event.portionsAfter = {}
    end
    local nativeId = before.nativeIds[1] or (after ~= nil and after.nativeBaleUniqueId) or nil
    for i, l in ipairs(self._listeners) do
        local t = tickets[i]
        local delivered = false
        if t ~= nil and t.ok then
            delivered = pcall(l.afterChange, MaterialDown.deepCopy(event), t.ticket)
        end
        if not delivered then
            pcall(l.invalidate, nativeId, t ~= nil and t.ok and "LISTENER_AFTER_FAILED" or "LISTENER_BEFORE_FAILED")
        end
    end
    return after, event.result
end

--- Commit a row's coordinates after an actual change: the row revision and the carrier
--- event sequence advance once per notified event.
local function commitRow(row)
    row.rowRevision = (row.rowRevision or 0) + 1
    row.nextCarrierEventSequence = (row.nextCarrierEventSequence or 1) + 1
end

-- =========================================================
-- Birth, and the rebind that shares its door
-- =========================================================

local function nativeUniqueId(bale)
    if type(bale) ~= "table" or type(bale.getUniqueId) ~= "function" then return nil end
    local ok, uid = pcall(bale.getUniqueId, bale)
    if ok and type(uid) == "string" and uid ~= "" then return uid end
    return nil
end

--- A bale entered the world: registered by a baler, unpacked, bought, spawned from the
--- console, handed out by an object storage, or loaded with a savegame. Its native unique
--- id finds its row if it has one; otherwise it is born.
---@param nodeId       number   bale scenegraph node
---@param bale         table    live bale object
---@param fillTypeName string
---@param fillLevel    number   litres, the bale's own
---@param farmId       number
---@param capacity     number
---@param birth        table|nil  [RSF-F211] a baler's collected birth from its creation
---       frame (BalerCollection): { wetnessPct = number|nil, collected = true }. A bale a
---       baler just made is new: it never rebinds to an old row. Without a birth the bale
---       came through another door: its own row if its id has one, else born unknown.
function YardLadder:onBaleCreated(nodeId, bale, fillTypeName, fillLevel, farmId, capacity, birth)
    if not self:isArmed() then return end
    if g_server == nil then return end
    if nodeId == nil then return end
    local md = self.materialDown
    if md == nil then return end
    self:_ensureLoaded()

    -- Same node twice (a double register, or our own hook re-entered) is a no-op.
    if self._byNode[nodeId] ~= nil then return end

    local uid = nativeUniqueId(bale)
    local collected = type(birth) == "table" and birth.collected == true
    local token = (uid ~= nil and not collected) and self._byUid[uid] or nil
    if token ~= nil then
        local row = md:getObjectRecord(token)
        if type(row) == "table" and self._live[token] == nil then
            self:_rebindArriving(token, row, nodeId, bale, fillLevel)
            return
        end
        if self._live[token] ~= nil then
            -- A second live bale with the same native id (the item system keeps a duplicate
            -- id and warns, ItemSystem.lua:209-216): neither can be proved; the row stops
            -- answering, and the newcomer gets no row.
            self._conflict[token] = "DUPLICATE_NATIVE_ID"
            SoilLogger.warning("[YardLadder] two live bales claim native id %s; its row %s is unavailable", tostring(uid), token)
            return
        end
    end
    if collected and uid ~= nil and self._byUid[uid] ~= nil then
        -- A baler's new bale whose id an old row already holds: the old row cannot be this
        -- bale's history; it is unbound, and the new bale is born.
        local old = self._byUid[uid]
        local oldRow = md:getObjectRecord(old)
        if type(oldRow) == "table" then oldRow.carrierState = YardLadder.CARRIER.UNBOUND end
        self._byUid[uid] = nil
    end
    self:_birth(nodeId, bale, uid, fillTypeName, fillLevel, farmId, capacity, collected and birth or nil)
end

--- An arriving bale whose id a row holds: out of storage (REBIND), or back after a
--- savegame load (restored, not an event: nothing about the bale changed).
function YardLadder:_rebindArriving(token, row, nodeId, bale, fillLevel)
    if row.carrierState == YardLadder.CARRIER.PENDING then
        row.carrierState = YardLadder.CARRIER.WORLD
        self:_attach(token, nodeId, bale)
        SoilLogger.debug("[YardLadder] restored %s to node %s", token, tostring(nodeId))
        return
    end
    self:_notifyChange(YardLadder.EVENT.REBIND, row, function(r)
        r.carrierState = YardLadder.CARRIER.WORLD
        for _, p in ipairs(r.portions or {}) do p.portionRevision = (p.portionRevision or 0) + 1 end
        commitRow(r)
        self:_attach(token, nodeId, bale)
        return r, YardLadder.RESULT.APPLIED
    end)
    SoilLogger.debug("[YardLadder] rebound %s out of storage to node %s", token, tostring(nodeId))
end

function YardLadder:_birth(nodeId, bale, uid, fillTypeName, fillLevel, farmId, capacity, birth)
    local md = self.materialDown
    local wetnessPct = birth ~= nil and tonumber(birth.wetnessPct) or nil
    local today = self:_today()
    local token, whyT = self:_mint(TOKEN_PREFIX)
    local historyId = token ~= nil and self:_mint(HISTORY_PREFIX) or nil
    local streamId = historyId ~= nil and self:_mint(STREAM_PREFIX) or nil
    if streamId == nil then
        SoilLogger.debug("[YardLadder] no row for node %s: the token allocator refused (%s)", tostring(nodeId), tostring(whyT))
        return
    end
    local litres = finite(tonumber(fillLevel)) and tonumber(fillLevel) or 0
    -- A collected bale's portion is the litres its chamber actually gave it (RSF-F211 :112).
    -- An unfinished round bale registers padded to the chamber's capacity and dropBale
    -- applies the real amount afterwards (Baler.lua:1590-1593), so the account's litres,
    -- not the padded level, are this bale's; the provider reads UNAVAILABLE until the drop
    -- confirms them, and for good if it does not. A finished bale's account was reconciled
    -- to the chamber's level before the finish, so for it the two agree.
    local account = birth ~= nil and birth.account or nil
    if type(account) == "table" and finite(account.carrier) and account.carrier > 0 then litres = account.carrier end

    -- DATA ONLY. Nothing here may be a live reference or a scenegraph handle.
    local row = {
        schema                   = YardLadder.ROW_SCHEMA,
        token                    = token,
        nativeBaleUniqueId       = uid,
        nativeFillType           = fillTypeName or "UNKNOWN",
        observedLitres           = litres,
        farmId                   = farmId or 0,
        carrierState             = uid ~= nil and YardLadder.CARRIER.WORLD or YardLadder.CARRIER.UNBOUND,
        rowRevision              = 0,
        nextCarrierEventSequence = 1,
        portions                 = {},
        -- compatibility only; never overrides the portions
        capacity                 = capacity or 0,
        bornDay                  = today,
        fillTypeName             = fillTypeName or "UNKNOWN",
    }

    local created = nil
    self:_notifyChange(YardLadder.EVENT.BIRTH, nil, function()
        row.portions[1] = {
            historyId           = historyId,
            sourceStreamId      = streamId,
            nextEventSequence   = 2,   -- BIRTH consumed sequence 1
            portionRevision     = 1,
            litres              = litres,
            profileId           = YardLadder.PROFILE_ID,
            profileVersion      = YardLadder.PROFILE_VERSION,
            historyKnowledge    = wetnessPct ~= nil and YardLadder.KNOWLEDGE.KNOWN or YardLadder.KNOWLEDGE.UNKNOWN,
            condition           = YardLadder.birthCondition(wetnessPct),
            birthWetnessKnown   = wetnessPct ~= nil,
            birthWetnessPct     = wetnessPct,
            observedFromDay     = today,
            lastSettledDay      = today,
            conditionGeneration = 1,
        }
        commitRow(row)
        if not md:createObjectRecord(token, row) then error("token taken: " .. token) end
        created = row
        self:_attach(token, nodeId, bale)
        if uid ~= nil then self._byUid[uid] = token end
        return row, YardLadder.RESULT.APPLIED
    end)
    if created == nil then return end

    SoilLogger.debug("[YardLadder] birth %s node=%s farm=%s fill=%s cap=%s wetness=%s condition=%.1f",
        token, tostring(nodeId), tostring(farmId), tostring(fillTypeName), tostring(capacity),
        wetnessPct ~= nil and string.format("%.1f", wetnessPct) or "unknown", created.portions[1].condition)

    self:publishWetnessAtBaling(token, fillTypeName, wetnessPct)
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
-- THE BIRTH: what the chamber actually held
-- =========================================================
-- RULED 2026-07-31: a bale is what the pickup ate, weighted by litres. RSF-F211 makes
-- that exact: the Baler's collection (BalerCollection) weights each source by the
-- carrier litres the chamber actually retained from it, and binds the result to the
-- exact bale createBale appended, through its creation frame. Its birth reaches
-- onBaleCreated as `birth`. A chamber holding any material of unknown or refused
-- condition gives no confident wetness (no known-only mean becomes a whole-bale
-- claim), so that bale opens at zero condition, per the ruling, and its history is
-- UNKNOWN. Every other door (unpacking, console, a purchase) is born unknown: the ground
-- under a bale is never read as its collected history.

--- Today, for stamping a birth. The accrual's ctx.monotonicDay is the authority on
--- the pass itself; this is only for rows born between passes, so it reads the same
--- basis the engine exposes as a FIELD (currentMonotonicDay). There is no documented
--- getDay() method and this member does not invent one.
function YardLadder:_today()
    local env = g_currentMission and g_currentMission.environment
    local day = env and env.currentMonotonicDay
    return tonumber(day) or 0
end

-- =========================================================
-- Storage, and death
-- =========================================================

--- An object storage is taking this bale in (the wrapper on the storage's bale class,
--- HookManager). The bale's delete inside it is a move into storage, not a death.
function YardLadder:beginStoring(bale)
    if bale ~= nil then self._storing[bale] = true end
end

function YardLadder:endStoring(bale)
    if bale ~= nil then self._storing[bale] = nil end
end

--- A bale left the world: sold, fed out, mixed, condemned by us, condemned by
--- RealisticWeather, taken by the engine's bale cap, or deleted into an object storage.
--- One door for all of them.
function YardLadder:onBaleRemoved(nodeId, bale)
    if not self:isArmed() then return end
    if g_server == nil then return end
    if nodeId == nil then return end
    local token = self._byNode[nodeId]
    if token == nil then return end
    local md = self.materialDown
    local row = md ~= nil and md:getObjectRecord(token) or nil
    if bale ~= nil and self._storing[bale] and type(row) == "table" and row.schema == YardLadder.ROW_SCHEMA
       and row.carrierState == YardLadder.CARRIER.WORLD then
        self:_notifyChange(YardLadder.EVENT.REBIND, row, function(r)
            r.carrierState = YardLadder.CARRIER.STORED
            for _, p in ipairs(r.portions or {}) do p.portionRevision = (p.portionRevision or 0) + 1 end
            commitRow(r)
            self:_detach(token)
            return r, YardLadder.RESULT.APPLIED
        end)
        return
    end
    self:_retire(token, row)
end

--- The row ends with its bale.
function YardLadder:_retire(token, row)
    local md = self.materialDown
    local notify = type(row) == "table" and row.schema == YardLadder.ROW_SCHEMA
    local function remove()
        self:_detach(token)
        if type(row) == "table" and row.nativeBaleUniqueId ~= nil and self._byUid[row.nativeBaleUniqueId] == token then
            self._byUid[row.nativeBaleUniqueId] = nil
        end
        self._conflict[token] = nil
        if md ~= nil then md:removeObjectRecord(token) end
    end
    if notify then
        self:_notifyChange(YardLadder.EVENT.RETIRE, row, function()
            remove()
            return nil, YardLadder.RESULT.APPLIED
        end)
    else
        remove()
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
    self:_ensureLoaded()

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
    table.sort(due, function(a, b) return (YardLadder._tokenSerial(a.token) or 0) < (YardLadder._tokenSerial(b.token) or 0) end)

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

    -- Unattached: stored, waiting for its bale after a load, or unbound. It cannot be
    -- located, so it cannot accrue. It is NOT deleted either: a stored bale is handed out
    -- again, and an unbound row is kept as data.
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
    local delta = rate * shelter
    local before = YardLadder.rowCondition(row)

    if row.schema == YardLadder.ROW_SCHEMA then
        if delta > 0 then
            -- The daily increase is notified before any consequent condemnation.
            self:_notifyChange(YardLadder.EVENT.ADVANCE, row, function(r)
                for _, p in ipairs(r.portions) do
                    p.condition = (tonumber(p.condition) or 0) + delta
                    p.lastSettledDay = day
                    p.nextEventSequence = (p.nextEventSequence or 1) + 1
                    p.portionRevision = (p.portionRevision or 0) + 1
                end
                commitRow(r)
                return r, YardLadder.RESULT.APPLIED
            end)
        end
    else
        row.condition = before + delta
    end

    local after = YardLadder.rowCondition(row)
    SoilLogger.debug("[YardLadder] %s: %.1f -> %.1f (+%.1f, shelter x%.2f)",
        token, before, after, delta, shelter)

    if after >= R.CONDEMN_AT then
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
        token, tostring(row.farmId), tostring(row.fillTypeName), tostring(row.capacity), YardLadder.rowCondition(row) or 0)

    local bale = live and live.bale

    -- The row dies first (RETIRE) so the delete hook cannot re-enter and act on a live row.
    self:_retire(token, row)

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
    local c = YardLadder.rowCondition(row) or 0
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
-- [RSF-F215] The limited condition provider
-- =========================================================

function YardLadder:getCapabilities()
    if not self:isArmed() or self.materialDown == nil then return nil end
    self:_ensureLoaded()
    return {
        schema        = YardLadder.CAPABILITY_SCHEMA,
        version       = 1,
        ready         = self.materialDown:isConditionStoreValid() and self._discoveryComplete,
        portions      = true,
        notifications = true,
    }
end

local function unavailable(uid, reason)
    return { state = YardLadder.STATE.UNAVAILABLE, reason = reason, nativeBaleUniqueId = uid, portions = {} }
end

--- The exact bale's condition portions, detached. READY only for a row bound to that
--- native id whose portions agree with the bale's actual litres.
function YardLadder:getConditionPortions(nativeBaleUniqueId)
    if not self:isArmed() or self.materialDown == nil then return unavailable(nativeBaleUniqueId, "NOT_ARMED") end
    self:_ensureLoaded()
    local md = self.materialDown
    if not md:isConditionStoreValid() then return unavailable(nativeBaleUniqueId, "STORE_UNAVAILABLE") end
    if type(nativeBaleUniqueId) ~= "string" then return unavailable(nativeBaleUniqueId, "BAD_ID") end
    local token = self._byUid[nativeBaleUniqueId]
    local row = token ~= nil and md:getObjectRecord(token) or nil
    if type(row) ~= "table" or row.schema ~= YardLadder.ROW_SCHEMA then return unavailable(nativeBaleUniqueId, "NO_ROW") end
    if self._conflict[token] ~= nil then return unavailable(nativeBaleUniqueId, self._conflict[token]) end
    local C = YardLadder.CARRIER
    if row.carrierState == C.UNBOUND then return unavailable(nativeBaleUniqueId, "UNBOUND") end
    if row.carrierState == C.PENDING then
        if self._discoveryComplete then return unavailable(nativeBaleUniqueId, "NOT_DISCOVERED") end
        return { state = YardLadder.STATE.RESTORING, reason = "AWAITING_BALE", nativeBaleUniqueId = nativeBaleUniqueId, portions = {} }
    end

    local actual = row.observedLitres
    if row.carrierState == C.WORLD then
        local live = self._live[token]
        local bale = live ~= nil and live.bale or nil
        if bale == nil or type(bale.getFillLevel) ~= "function" then return unavailable(nativeBaleUniqueId, "NO_LIVE_BALE") end
        local ok, level = pcall(bale.getFillLevel, bale)
        if not ok or not finite(level) then return unavailable(nativeBaleUniqueId, "UNREADABLE_LEVEL") end
        actual = level
    end
    local sum = 0
    for _, p in ipairs(row.portions) do sum = sum + (tonumber(p.litres) or 0) end
    if math.abs(sum - (actual or 0)) > YardLadder.LITRE_EPSILON then
        -- A bale partly used since its row was written: the portions no longer describe
        -- it, and are never rescaled into agreement.
        return unavailable(nativeBaleUniqueId, "QUANTITY_MISMATCH")
    end
    return {
        state                = YardLadder.STATE.READY,
        reason               = nil,
        carrierRevision      = row.rowRevision,
        carrierEventSequence = (row.nextCarrierEventSequence or 1) - 1,
        nativeBaleUniqueId   = nativeBaleUniqueId,
        nativeFillType       = row.nativeFillType,
        actualLitres         = actual,
        portions             = self:_detachedPortions(row),
    }
end

--- The same-owner compatibility delegate: a node resolves to its exact unique id, and the
--- one store answers. Visual clones never resolve (no row holds their node).
function YardLadder:getConditionPortionsForNode(nodeId)
    local token = self._byNode[nodeId]
    local row = token ~= nil and self.materialDown ~= nil and self.materialDown:getObjectRecord(token) or nil
    if type(row) ~= "table" or type(row.nativeBaleUniqueId) ~= "string" then return unavailable(nil, "NO_ROW") end
    return self:getConditionPortions(row.nativeBaleUniqueId)
end

-- =========================================================
-- [RSF-F215] Row validation (before a row goes live, and before a save)
-- =========================================================

local VALID_CARRIER = { WORLD = true, STORED = true, PENDING = true, UNBOUND = true }
local VALID_KNOWLEDGE = { KNOWN = true, UNKNOWN = true }

local function validPortion(p, meta)
    if type(p) ~= "table" then return false, "PORTION" end
    for _, k in ipairs({ "historyId", "sourceStreamId", "profileId" }) do
        if type(p[k]) ~= "string" or p[k] == "" then return false, "PORTION_" .. k end
    end
    for _, k in ipairs({ "nextEventSequence", "portionRevision", "profileVersion", "conditionGeneration" }) do
        if not counter(p[k]) then return false, "PORTION_" .. k end
    end
    if not finite(p.litres) or p.litres < 0 then return false, "PORTION_litres" end
    if not finite(p.condition) or p.condition < 0 then return false, "PORTION_condition" end
    if not VALID_KNOWLEDGE[p.historyKnowledge] then return false, "PORTION_knowledge" end
    if type(p.birthWetnessKnown) ~= "boolean" then return false, "PORTION_birthWetnessKnown" end
    if p.birthWetnessKnown and not finite(p.birthWetnessPct) then return false, "PORTION_birthWetnessPct" end
    if not finite(p.observedFromDay) or not finite(p.lastSettledDay) then return false, "PORTION_day" end
    local next = meta ~= nil and meta.nextTokenSerial or nil
    for _, t in ipairs({ p.historyId, p.sourceStreamId }) do
        local n = YardLadder._tokenSerial(t)
        if n == nil then return false, "PORTION_TOKEN" end
        if next ~= nil and n >= next then return false, "PORTION_TOKEN_ABOVE_ALLOCATOR" end
    end
    return true
end

--- MaterialDown's row validator: every schema-2 row complete and consistent, native ids
--- and stream tokens unique, every token below the saved allocator; a legacy row only as
--- UNBOUND data. Other members' records pass untouched.
---@return boolean ok, string|nil reason
function YardLadder.validateRows(objects, meta)
    if type(objects) ~= "table" then return false, "NO_OBJECTS" end
    local uids, streams = {}, {}
    local next = type(meta) == "table" and meta.nextTokenSerial or nil
    for token, row in pairs(objects) do
        if YardLadder._isOurToken(token) then
            if type(row) ~= "table" then return false, "ROW_NOT_TABLE" end
            local n = YardLadder._tokenSerial(token)
            if next ~= nil and n >= next then return false, "TOKEN_ABOVE_ALLOCATOR" end
            if row.schema == YardLadder.ROW_SCHEMA then
                if row.token ~= token then return false, "TOKEN_MISMATCH" end
                if not VALID_CARRIER[row.carrierState] then return false, "CARRIER" end
                if row.carrierState ~= "UNBOUND" then
                    if type(row.nativeBaleUniqueId) ~= "string" or row.nativeBaleUniqueId == "" then return false, "NO_NATIVE_ID" end
                    if uids[row.nativeBaleUniqueId] then return false, "DUPLICATE_NATIVE_ID" end
                    uids[row.nativeBaleUniqueId] = true
                end
                if not counter(row.rowRevision) or not counter(row.nextCarrierEventSequence) or row.nextCarrierEventSequence < 1 then
                    return false, "ROW_COUNTERS"
                end
                if not finite(row.observedLitres) or row.observedLitres < 0 then return false, "OBSERVED_LITRES" end
                if type(row.nativeFillType) ~= "string" then return false, "FILL_TYPE" end
                if type(row.portions) ~= "table" or #row.portions < 1 then return false, "NO_PORTIONS" end
                local sum = 0
                for _, p in ipairs(row.portions) do
                    local ok, why = validPortion(p, meta)
                    if not ok then return false, why end
                    if streams[p.sourceStreamId] then return false, "DUPLICATE_STREAM" end
                    streams[p.sourceStreamId] = true
                    sum = sum + p.litres
                end
                if math.abs(sum - row.observedLitres) > YardLadder.LITRE_EPSILON then return false, "PORTIONS_DISAGREE" end
            elseif row.carrierState ~= "UNBOUND" then
                return false, "LEGACY_ROW_BOUND"
            end
        end
    end
    return true
end

-- =========================================================
-- Publications
-- =========================================================
-- PUBLISH ONLY. DairyCore is the sole writer of Feed Provenance and this member never
-- writes it. The input-spec rider on this brief carries both of these onto the Feed
-- Provenance brief; until that lands there is no consumer, so the publication is a
-- message-centre emit plus a line, and the shape is what the rider will bind to.
-- [RSF-F215] publishConditionAtFeed is the scalar clone the limited provider replaces as
-- a contract; it stays for its existing consumer.

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
