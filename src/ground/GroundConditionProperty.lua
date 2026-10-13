--
-- GroundConditionProperty
--
-- SG2-4c-3: Soil's half of SG-2 v2.3 :324-332 and :343, with the SG-1 brief :232 and
-- GROUND-CONDITION-CONTRACT v1.5 sections 2 and 6. Soil registers `soil.groundCondition`
-- with StockGuard's SG-1 as an OWNER_RESOLVED property. While material lies on the ground,
-- its age and wetness live in Soil's two condition layers, and StockGuard asks Soil for them
-- through resolveResident and getResidentRevision instead of keeping a copy. When material
-- leaves the ground, SG-1 carries the record it captured (StockGuard 2-4c-0) and asks this
-- property's combine for the mixture it lands in.
--
-- A RESOLVE, for one ground stock: a native height-map pixel, named by the footprint SG-1
-- passes (GROUND_CELL, the pixel's world centre and its size).
--   * The Soil cells under the pixel are read exactly (readConditionCell). A pixel that
--     straddles cells is combined by section 2's floor: the coordinator's own combine, so
--     the oldest age and the wettest band win, and unknown and the ceiling propagate.
--   * KNOWN when both components are known: age 1..254 or the ceiling 255, wetness 32 and
--     up. Otherwise UNKNOWN: positive material with no record is unknown history (:332).
--   * nil, UNAVAILABLE when any cell under the pixel is marked unavailable or unreadable.
--   * nil, NOT_RESIDENT for a context that names no ground cell.
--   * nil, PROVIDER_UNARMED when the coordinator or either condition owner is not armed.
-- The payload holds Soil's own encodings, never a new unit: MaterialDown's raw age,
-- MaterialWetness's raw band, the day each owner's cursor has settled through, and the
-- geometry identity. The age cursor's day is the stamp P-GROUND-1's off-ground ageing
-- counts from: the bytes are true through that day, whatever day it is now.
--
-- THE OWNER REVISION (section 6) is the mission epoch, the change counter and the two
-- cursors, plus whether the provider is live, as ONE string. SG-1 compares a before and an
-- after with ~= (SGOperations.lua:1620, and :659 for a capture), so a table would never
-- compare equal and every read would be unstable. Availability moves it: an owner that
-- stands down flips the live part, and the counter moves on every movement, clear and
-- overlay change, and on register and withdraw (provider lifecycle).
--
-- COMBINE, for material SG-1 carries off the ground: the section 2 floor over every part
-- with positive litres (the destination's own record and each arriving portion). A part
-- with no record, or one SG-1 has qualified (PARTIAL, HISTORICAL, UNAVAILABLE), is
-- unknown. P-GROUND-1: off the ground a
-- known age advances by the whole days since its stamp. The mixture takes the newest stamp
-- and each older part is aged to it once (GroundMovementCarrier.agedRaw), so a later read
-- derives from one stamp and never counts a span twice. A known age with no stamp cannot
-- be aged and is unknown. Wetness is kept as captured. Fresh litres a settle report names as
-- pending (SG2-5c, a mower's buffer) are left out of the floor and the coverage (below).
-- TRANSFORM: a conversion with no registered basis is unknown (SG-2 :280). Soil registers
-- none.
-- DISCLOSURE: nothing. No player view has ruled what a player sees (SG-5, Wizard).
--
-- LIFECYCLE. Registered at the end of the arm chain (SoilFertilitySystem:initialize), on the
-- server, when the coordinator armed and StockGuard published its mission handle. Withdrawn
-- at unload, and on the first update after a condition owner stood down (a stand-down sets
-- a flag and tells no one). Nothing is saved; there is no event and no client path. This is
-- a separate registration from the admission interface: it does not bump
-- admissionRevision, and a registered property is not proof that Soil can receive a
-- delivery (SoilFertilityManager:getCapabilities is).
--

GroundConditionProperty = GroundConditionProperty or {}
local GroundConditionProperty_mt = Class(GroundConditionProperty)
local GP = GroundConditionProperty

GP.PROPERTY_ID      = "soil.groundCondition"
GP.SCHEMA_VERSION   = 1
GP.PRODUCER_ID      = "soil"
GP.GROUND_CELL      = "GROUND_CELL"
GP.STORE_KIND       = "ground"
-- A pixel no larger than a Soil cell touches at most 4 cells. Beyond this the footprint is
-- not a pixel, and is refused rather than read cell by cell.
GP.MAX_CELLS        = 16

GP.NOT_RESIDENT     = "NOT_RESIDENT"
GP.UNAVAILABLE      = "UNAVAILABLE"
GP.PROVIDER_UNARMED = "PROVIDER_UNARMED"
GP.OFF_GRID         = "OFF_GRID"
GP.TOO_LARGE        = "FOOTPRINT_TOO_LARGE"
GP.NO_MATERIAL      = "NO_MATERIAL"

-- The two layers' encodings (GroundConditionCoordinator.lua:45-49).
local AGE_UNKNOWN = 0
local AGE_CEILING = 255
local WET_UNKNOWN = 24
local WET_FLOOR   = 32
local RAW_MAX     = 255

local function isFinite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isInt(n)
    return isFinite(n) and math.floor(n) == n
end

--- The ceiling is a record (older than the layer counts), so it is known here; the floor
--- keeps it from being averaged into days.
local function ageKnown(raw)
    return isInt(raw) and raw > AGE_UNKNOWN and raw <= AGE_CEILING
end

local function wetKnown(raw)
    return isInt(raw) and raw >= WET_FLOOR and raw <= RAW_MAX
end

function GroundConditionProperty.new()
    local self = setmetatable({}, GroundConditionProperty_mt)
    self.coordinator = nil
    self.handle      = nil   -- the StockGuard mission handle the lease came from
    self.lease       = nil
    self.consumerLease = nil -- [SG2-5d] the bale birth's SG-1 consumer (below)
    return self
end

--- Live: the coordinator armed and both condition owners still armed. An owner that stood
--- down for the session keeps its object, and its isArmed reads the stand-down.
function GroundConditionProperty:isLive()
    local c = self.coordinator
    if c == nil or not c:isArmed() then return false end
    local md, mw = c.materialDown, c.materialWetness
    return md ~= nil and md:isArmed() and mw ~= nil and mw:isArmed()
end

function GroundConditionProperty:isRegistered()
    return self.lease ~= nil
end

-- =========================================================
-- The record
-- =========================================================

--- One property record over `payload`. Coverage is in the stock's own unit: all of it known
--- when both components are, none of it otherwise.
function GroundConditionProperty.record(payload, amount, unit, revision)
    local known = ageKnown(payload.ageRaw) and wetKnown(payload.wetnessRaw)
    local rec = {
        propertyId       = GP.PROPERTY_ID,
        schemaVersion    = GP.SCHEMA_VERSION,
        producerId       = GP.PRODUCER_ID,
        propertyRevision = isInt(revision) and revision >= 0 and revision or 0,
        knowledge        = known and "KNOWN" or "UNKNOWN",
        payload          = payload,
    }
    if isFinite(amount) and amount >= 0 and type(unit) == "string" and unit ~= "" then
        rec.basisAmount = amount
        rec.knownAmount = known and amount or 0
        rec.amountUnit  = unit
    end
    return rec
end

---@return boolean valid, string|nil reason
function GroundConditionProperty.validate(rec)
    if type(rec) ~= "table" then return false, "NOT_TABLE" end
    if rec.propertyId ~= GP.PROPERTY_ID or rec.schemaVersion ~= GP.SCHEMA_VERSION or rec.producerId ~= GP.PRODUCER_ID then
        return false, "IDENTITY"
    end
    if rec.knowledge ~= "KNOWN" and rec.knowledge ~= "UNKNOWN" then return false, "KNOWLEDGE" end
    local p = rec.payload
    if type(p) ~= "table" then return false, "PAYLOAD" end
    if not isInt(p.ageRaw) or p.ageRaw < 0 or p.ageRaw > RAW_MAX then return false, "AGE" end
    if p.wetnessRaw ~= WET_UNKNOWN and not wetKnown(p.wetnessRaw) then return false, "WETNESS" end
    if p.ageDay ~= nil and not isInt(p.ageDay) then return false, "AGE_DAY" end
    if p.wetDay ~= nil and not isInt(p.wetDay) then return false, "WET_DAY" end
    if p.account ~= nil then
        local why = GP.accountProblem(p.account)
        if why ~= nil then return false, why end
    end
    if (rec.knowledge == "KNOWN") ~= (ageKnown(p.ageRaw) and wetKnown(p.wetnessRaw)) then
        return false, "KNOWLEDGE_PAYLOAD"
    end
    return true
end

-- =========================================================
-- The owner revision and the resolve
-- =========================================================

--- One scalar: SG-1 compares two of these with ~=.
function GroundConditionProperty:revision()
    local c = self.coordinator
    if c == nil then return "none" end
    local r = c:getOwnerRevision()
    return table.concat({ self:isLive() and "live" or "down", tostring(r.epoch), tostring(r.changeCounter),
        tostring(r.ageThroughDay), tostring(r.wetThroughDay) }, ":")
end

--- The live condition of one ground stock. See the header for every outcome.
---@return table|nil record, string|nil reason
function GroundConditionProperty:resolve(context)
    if not self:isLive() then return nil, GP.PROVIDER_UNARMED end
    local fp = type(context) == "table" and context.footprint or nil
    if type(fp) ~= "table" or fp.kind ~= GP.GROUND_CELL or not isFinite(fp.x) or not isFinite(fp.z) then
        return nil, GP.NOT_RESIDENT
    end
    local c = self.coordinator
    local cells = c.cells
    local geometry = cells:getConditionGeometry()
    if geometry == nil then return nil, GP.UNAVAILABLE end

    -- The pixel's box, its positive edges exclusive: a pixel that ends on a cell edge does
    -- not reach the next cell. A footprint with no size is a point.
    local half = (isFinite(fp.size) and fp.size > 0) and fp.size * 0.5 or 0
    local inset = half * 1e-6
    local gx0, gz0 = cells:worldToCell(geometry, fp.x - half, fp.z - half)
    local gx1, gz1 = cells:worldToCell(geometry, fp.x + half - inset, fp.z + half - inset)
    if gx0 == nil or gx1 == nil then return nil, GP.OFF_GRID end
    local n = (gx1 - gx0 + 1) * (gz1 - gz0 + 1)
    if n > GP.MAX_CELLS then return nil, GP.TOO_LARGE end

    local parts = {}
    for gz = gz0, gz1 do
        for gx = gx0, gx1 do
            if c:isUnavailable(gx, gz) then return nil, GP.UNAVAILABLE end
            local cell = cells:readConditionCell(geometry, gx, gz)
            if cell == nil or cell.refused ~= nil or not cell.ageAvailable or not cell.wetnessAvailable then
                return nil, GP.UNAVAILABLE
            end
            parts[#parts + 1] = { litres = 1, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }
        end
    end
    local combined = GroundConditionCoordinator.combine(nil, parts)
    local rev = c:getOwnerRevision()
    local payload = {
        ageRaw     = combined.ageRaw,
        wetnessRaw = combined.wetnessRaw,
        ageDay     = rev.ageThroughDay,
        wetDay     = rev.wetThroughDay,
        cells      = n,
        geometry   = { epoch = geometry.epoch, geometryRevision = geometry.geometryRevision,
                       resolution = geometry.resolution, terrainSize = geometry.terrainSize },
    }
    return GP.record(payload, context.amount, context.unit, c.changeCounter)
end

-- =========================================================
-- Combine and transform, for material off the ground
-- =========================================================

--- A record's components for the floor; nils when it cannot be read, which the floor takes
--- as unknown. Only this property's own two states are read by their payload. SG-1
--- qualifies a record it can no longer vouch for in place, payload kept: PARTIAL when the
--- material grew past what the record covers (SGOperations.lua:307-308), UNAVAILABLE on a
--- withdrawn binding (:1327), HISTORICAL when the producer was absent (:780). Each is
--- unknown here.
local function componentsOf(rec)
    if type(rec) ~= "table" or type(rec.payload) ~= "table" then return nil, nil, nil end
    if rec.knowledge ~= "KNOWN" and rec.knowledge ~= "UNKNOWN" then return nil, nil, nil end
    local p = rec.payload
    return p.ageRaw, p.wetnessRaw, p.ageDay
end
-- The one reader of these records: the admission's drop (SG2-5 5-0) reads them through it too.
GroundConditionProperty.componentsOf = componentsOf

-- [SG2-5d] THE COLLECTED ACCOUNT (Bob's G3 ruling; SG-2 :344, RSF-F211 :46). On the F211
-- collection paths StockGuard stores the account Soil's collected reader returned as an optional
-- `account` in this payload: carrier litres split into known, unknown and refused, with the known
-- weighted percent sum kept for later uniform combinations. It travels beside the floor fields.
GP.ACCOUNT_FIELDS = { "carrierLitres", "knownCarrierLitres", "unknownCarrierLitres", "refusedCarrierLitres", "knownWeightedPctSum" }
local ACCOUNT_TOLERANCE = 1e-6

--- nil when the account is well formed, else the reason.
local function accountProblem(acc)
    if type(acc) ~= "table" then return "ACCOUNT" end
    for _, f in ipairs(GP.ACCOUNT_FIELDS) do
        if not isFinite(acc[f]) or acc[f] < 0 then return "ACCOUNT" end
    end
    local parts = acc.knownCarrierLitres + acc.unknownCarrierLitres + acc.refusedCarrierLitres
    if math.abs(parts - acc.carrierLitres) > ACCOUNT_TOLERANCE * math.max(1, acc.carrierLitres) then return "ACCOUNT_SUM" end
    if acc.knownWeightedPctSum > 100 * acc.knownCarrierLitres + ACCOUNT_TOLERANCE * math.max(1, acc.knownCarrierLitres) then return "ACCOUNT_PCT" end
    return nil
end
GP.accountProblem = accountProblem

--- A record's account as `litres` of it: each component scaled to the part (SG-1 scales a
--- portion's coverage, never its payload), or nil when the record carries none that can be read.
local function accountFor(rec, litres)
    -- Read only as componentsOf reads: this property's own two states (a qualified record is unknown).
    if type(rec) ~= "table" or type(rec.payload) ~= "table" or (rec.knowledge ~= "KNOWN" and rec.knowledge ~= "UNKNOWN") then return nil end
    local acc = rec.payload.account
    if acc == nil or accountProblem(acc) ~= nil or acc.carrierLitres <= 0 then return nil end
    local f = litres / acc.carrierLitres
    local out = {}
    for _, k in ipairs(GP.ACCOUNT_FIELDS) do out[k] = acc[k] * f end
    return out
end

-- [SG2-5d] THE ACCOUNT FROM THE OPERATION (Bob's 5d ruling, Q2; SG-2 :344, R1). StockGuard
-- seals a Baler's collection, calls the published readCollectedCondition and stores what it
-- returns on the receiving stock. SG-1 lets only the owner write this property, so the account
-- travels in the settle report and this combine adopts it: SG-1 hands every combine
-- context.report.outcomeEvidence (SGOperations.lua:1084) and stamps each contribution with its
-- allocation's ref, operationId .. ":a" .. index (:942). The evidence names the leg:
--   outcomeEvidence["soil.groundCondition"].collectedAccounts = { { allocation = index, account }, ... }
-- The account is adopted only
--   1. on the contribution whose allocation it names, never on destinationBefore or another part;
--   2. when it is well formed (accountProblem);
--   3. when its carrier litres are that contribution's litres, within the account tolerance.
-- A named leg whose account fails a check, or whose allocation is named twice, enters as unknown
-- carrier litres: never dropped, never its own record's older account. StockGuard builds an
-- UNAVAILABLE read into the account it passes as unknown litres (the reader's own contract), so
-- an adopted account always covers its whole leg. With no evidence, combine is unchanged.
GP.EVIDENCE_ACCOUNTS = "collectedAccounts"

--- The accounts a settle report names, by allocation ref. A doubly named allocation maps to
--- false: it cannot be told which account is meant. (Module functions, not file locals: the benches
--- that load this file with many others sit near Lua's 200-local limit for one chunk.)
function GP.evidenceAccounts(context)
    local out = {}
    if type(context) ~= "table" or type(context.operationId) ~= "string" then return out end
    local report = context.report
    local evidence = type(report) == "table" and report.outcomeEvidence or nil
    local mine = type(evidence) == "table" and evidence[GP.PROPERTY_ID] or nil
    local list = type(mine) == "table" and mine[GP.EVIDENCE_ACCOUNTS] or nil
    if type(list) ~= "table" then return out end
    for _, e in ipairs(list) do
        if type(e) == "table" and isInt(e.allocation) and e.allocation >= 1 then
            local ref = context.operationId .. ":a" .. tostring(e.allocation)
            if out[ref] == nil then out[ref] = e.account else out[ref] = false end
        end
    end
    return out
end

--- The named leg's account: the evidence's own when it passes the checks, else all unknown.
function GP.adoptedAccount(acc, litres)
    if acc ~= false and accountProblem(acc) == nil
       and math.abs(acc.carrierLitres - litres) <= ACCOUNT_TOLERANCE * math.max(1, litres) then
        local out = {}
        for _, k in ipairs(GP.ACCOUNT_FIELDS) do out[k] = acc[k] end
        return out
    end
    return { carrierLitres = litres, knownCarrierLitres = 0, unknownCarrierLitres = litres,
             refusedCarrierLitres = 0, knownWeightedPctSum = 0 }
end

-- [SG2-5c] PENDING FRESH LITRES (Bob's 5c ruling, Q1; GCC section 4, SG-2 :351). A mower's
-- fresh output waits in StockGuard's drop-area buffer until it lands, and Soil makes its birth
-- at that deposit (GroundConditionAdmission, the birth contribution). Until then those litres
-- are neither known nor unknown: they are a birth that has not happened. In the buffer they
-- arrive as a BIRTH slot portion, which carries no record (SGOperations.lua:1058-1065), and
-- sit in the buffer's own remainder; read as parts, either would turn the whole buffer UNKNOWN
-- by section 2's floor, and a grass cut that also picks up old dry grass would deposit unknown
-- where Soil alone deposits the dry grass's condition with the fresh profile. So the settle
-- report names them:
--   outcomeEvidence["soil.groundCondition"].pendingFresh =
--       { destinationBefore = litres, allocations = { { allocation = index, litres }, ... } }
-- and this combine leaves the named litres out of its floor and its coverage. A part left with
-- nothing (within the account tolerance) imports nothing. Every figure is checked, and one
-- that cannot be read names nothing, so those litres stay in as their own record says:
--   * litres finite and not negative, an allocation a positive integer named once;
--   * no more than the part holds, within the tolerance (then the whole part).
-- With no evidence, combine is unchanged.
GP.EVIDENCE_PENDING_FRESH = "pendingFresh"

--- The pending fresh litres a settle report names: per allocation ref, and for the
--- destination's own remainder. A doubly named allocation names nothing.
function GP.evidencePendingFresh(context)
    local out, before = {}, nil
    if type(context) ~= "table" or type(context.operationId) ~= "string" then return out, before end
    local report = context.report
    local evidence = type(report) == "table" and report.outcomeEvidence or nil
    local mine = type(evidence) == "table" and evidence[GP.PROPERTY_ID] or nil
    local pending = type(mine) == "table" and mine[GP.EVIDENCE_PENDING_FRESH] or nil
    if type(pending) ~= "table" then return out, before end
    if isFinite(pending.destinationBefore) then before = pending.destinationBefore end
    if type(pending.allocations) == "table" then
        for _, e in ipairs(pending.allocations) do
            if type(e) == "table" and isInt(e.allocation) and e.allocation >= 1 and isFinite(e.litres) and e.litres >= 0 then
                local ref = context.operationId .. ":a" .. tostring(e.allocation)
                if out[ref] == nil then out[ref] = e.litres else out[ref] = false end
            end
        end
    end
    return out, before
end

--- A part's litres less the pending fresh litres named on it: unchanged when nothing
--- readable is named (no figure, or one not above zero) or the figure exceeds the part,
--- zero when nothing is left.
function GP.lessPending(litres, pending)
    if type(pending) ~= "number" or pending <= 0 then return litres end
    local slack = ACCOUNT_TOLERANCE * math.max(1, litres)
    if pending > litres + slack then return litres end
    local left = litres - pending
    if left <= slack then return 0 end
    return left
end

---@return table|nil record, string|nil reason
function GroundConditionProperty:combine(context, contributions, destinationBefore)
    local parts, unit = {}, nil
    local named = GP.evidenceAccounts(context)
    local pendingByRef, pendingBefore = GP.evidencePendingFresh(context)
    local function add(litres, rec, partUnit, evidence, pending)
        litres = GP.lessPending(tonumber(litres) or 0, pending)
        -- Zero litres import nothing: not unknown, not a refusal (section 2).
        if not isFinite(litres) or litres <= 0 then return end
        local a, w, d = componentsOf(rec)
        local account
        if evidence ~= nil then account = GP.adoptedAccount(evidence, litres) else account = accountFor(rec, litres) end
        parts[#parts + 1] = { litres = litres, ageRaw = a, wetnessRaw = w, ageDay = d, account = account }
        if unit == nil and type(partUnit) == "string" then unit = partUnit end
    end
    if type(destinationBefore) == "table" then
        local props = type(destinationBefore.properties) == "table" and destinationBefore.properties or {}
        add(destinationBefore.observedAmount, props[GP.PROPERTY_ID], destinationBefore.amountUnit, nil, pendingBefore)
    end
    if type(contributions) == "table" then
        for _, part in ipairs(contributions) do
            local props = type(part.properties) == "table" and part.properties or {}
            -- A doubly named allocation maps to false, which must reach adoptedAccount as such.
            local evidence, pending = nil, nil
            if type(part.allocationRef) == "string" then
                evidence, pending = named[part.allocationRef], pendingByRef[part.allocationRef]
            end
            add(part.amount, props[GP.PROPERTY_ID], part.unit, evidence, pending)
        end
    end
    if #parts == 0 then return nil, GP.NO_MATERIAL end

    local newest = nil
    for _, p in ipairs(parts) do
        if isInt(p.ageDay) and (newest == nil or p.ageDay > newest) then newest = p.ageDay end
    end
    local total, floorParts = 0, {}
    for _, p in ipairs(parts) do
        total = total + p.litres
        floorParts[#floorParts + 1] = {
            litres     = p.litres,
            ageRaw     = GroundMovementCarrier.agedRaw(p.ageRaw, p.ageDay, newest),
            wetnessRaw = p.wetnessRaw,
        }
    end
    local combined = GroundConditionCoordinator.combine(nil, floorParts)
    local c = self.coordinator
    local payload = { ageRaw = combined.ageRaw, wetnessRaw = combined.wetnessRaw, ageDay = newest }
    -- [SG2-5d] Accounts add by carrier litres; a part without one adds its litres as unknown.
    -- With no account among the parts there is none to carry.
    local anyAccount = false
    for _, p in ipairs(parts) do if p.account ~= nil then anyAccount = true end end
    if anyAccount then
        local acc = {}
        for _, k in ipairs(GP.ACCOUNT_FIELDS) do acc[k] = 0 end
        for _, p in ipairs(parts) do
            if p.account ~= nil then
                for _, k in ipairs(GP.ACCOUNT_FIELDS) do acc[k] = acc[k] + p.account[k] end
            else
                acc.carrierLitres = acc.carrierLitres + p.litres
                acc.unknownCarrierLitres = acc.unknownCarrierLitres + p.litres
            end
        end
        payload.account = acc
    end
    return GP.record(payload, total, unit, c ~= nil and c.changeCounter or 0)
end

-- [SG2-5b] THE TEDDER'S HAY CONVERSION (SG-2 v2.3 :296, :652, :684; Bob's 5b ruling, Q3). A Tedder
-- pass picks grass windrow up and drops it as dry grass windrow, litre for litre
-- (Tedder.lua:289-300), and StockGuard settles that pickup as a CONVERT on the profile's basis
-- NATIVE_HAY_CONVERT_V1. Soil's rule at the tedder is already to carry the pickup's condition
-- through to the drop (GroundMovementCarrier's tedder account, type-blind), so this transform
-- writes that rule down for StockGuard's path: when at least one contribution is on the hay basis
-- and every other carries no basis (dry grass already of the target type joins the same pass
-- unchanged, and any based contribution sends the whole candidate here, SGOperations.lua:752),
-- the result is combine's own: the floor with P-GROUND-1 ageing and the accounts by carrier
-- litres, at the destination's litres. The condition is carried as it is: drying stays HayBet's
-- own effect after the deliveries (:345). Any other basis, or none at all, is UNKNOWN as before.
GP.HAY_CONVERT_BASIS = "NATIVE_HAY_CONVERT_V1"

--- Whether a conversion carries the condition: at least one contribution on the hay basis, and
--- no contribution on any other basis.
function GroundConditionProperty.carriesThroughConversion(contributions)
    if type(contributions) ~= "table" then return false end
    local hay = false
    for _, part in ipairs(contributions) do
        if type(part) ~= "table" then return false end
        local basis = part.conversionBasisId
        if basis == GP.HAY_CONVERT_BASIS then
            hay = true
        elseif basis ~= nil then
            return false
        end
    end
    return hay
end

---@return table record
function GroundConditionProperty:transform(context, contributions, destinations)
    local d = type(destinations) == "table" and destinations[1] or nil
    local c = self.coordinator
    local amount = type(d) == "table" and d.amount or nil
    local unit = type(d) == "table" and d.unit or nil
    if GP.carriesThroughConversion(contributions) then
        local carried = self:combine(context, contributions, type(d) == "table" and d.destinationBefore or nil)
        if carried ~= nil then
            return GP.record(carried.payload, amount, unit, c ~= nil and c.changeCounter or 0)
        end
    end
    return GP.record({ ageRaw = AGE_UNKNOWN, wetnessRaw = WET_UNKNOWN }, amount, unit, c ~= nil and c.changeCounter or 0)
end

-- =========================================================
-- Registration
-- =========================================================

--- The spec SGRegistry:registerProperty takes (SGRegistry.lua:136-144). Every callback is a
--- closure on this object; StockGuard calls them with dots.
function GroundConditionProperty:spec()
    return {
        schemaVersion       = GP.SCHEMA_VERSION,
        producerId          = GP.PRODUCER_ID,
        residency           = "OWNER_RESOLVED",
        applicability       = { residentStoreKinds = { GP.STORE_KIND } },
        validate            = GP.validate,
        combine             = function(context, contributions, destinationBefore)
                                  return self:combine(context, contributions, destinationBefore)
                              end,
        transform           = function(context, contributions, destinations)
                                  return self:transform(context, contributions, destinations)
                              end,
        disclosure          = function() return nil end,
        resolveResident     = function(context) return self:resolve(context) end,
        getResidentRevision = function(_context) return self:revision() end,
    }
end

--- Register with StockGuard on the server once the coordinator armed. StockGuard absent is
--- the ordinary Soil-alone path: nothing is registered and nothing is a fault.
---@return boolean registered, string|nil reason
function GroundConditionProperty:register(coordinator, mission)
    if g_server == nil then return false, "NOT_SERVER" end
    if self.lease ~= nil then return true, "ALREADY_REGISTERED" end
    if coordinator == nil or not coordinator:isArmed() then return false, "NOT_ARMED" end
    mission = mission or g_currentMission
    local sg = mission ~= nil and mission.stockGuard or nil
    if type(sg) ~= "table" or type(sg.registerProperty) ~= "function" or type(sg.unregisterOwner) ~= "function" then
        return false, "STOCKGUARD_ABSENT"
    end
    self.coordinator = coordinator
    local ok, lease, why = pcall(sg.registerProperty, GP.PROPERTY_ID, self:spec())
    if not ok or type(lease) ~= "table" then
        local reason = ok and tostring(why) or "REGISTER_ERROR"
        SoilLogger.warning("[GroundProperty] StockGuard refused %s (%s) - live ground condition is unavailable to it",
            GP.PROPERTY_ID, reason)
        return false, reason
    end
    self.handle, self.lease = sg, lease
    self:registerBaleConsumer(sg)
    coordinator:bumpRevision("provider-registered")
    SoilLogger.info("[OK] %s registered with StockGuard (epoch %d)", GP.PROPERTY_ID, coordinator.epoch)
    return true, nil
end

-- [SG2-5d] THE BALE BIRTH'S READ OF THE CHAMBER (Bob's 5d ruling, Q4 and Q5). With StockGuard
-- framing a square Baler, the chamber's material is StockGuard's carrier and its condition is the
-- soil.groundCondition record StockGuard's settle stored there, with the collected account Soil's
-- own combine adopted (above); Soil's own chamber account is unknown by construction under a
-- lease. SG-2 :477 keeps one record in SG-1, not a second Soil accumulator, so the bale's birth reads
-- that record: through SG-1's consumer path (a consumer lease is SG-1's gate for schema and material
-- kind, SGOperations.lua:1631-1640) on the stock StockGuard's read-only lookup names,
-- fillUnitStockRef(vehicle, fillUnitIndex). With no lookup, no lease, or no usable account it
-- answers nil and the reason, and the caller keeps its own account.
GP.BALE_CONSUMER_ID = "soil.baleBirth"

--- Register the bale birth's consumer on StockGuard's handle, when the handle offers it.
function GroundConditionProperty:registerBaleConsumer(sg)
    if type(sg) ~= "table" or type(sg.registerConsumer) ~= "function" then return false end
    local spec = {
        version = 1,
        requiredSchemas = { [GP.PROPERTY_ID] = GP.SCHEMA_VERSION },
        materialKinds = { "FILL_TYPE" },
        resolveReadContext = function(query)
            if type(query) ~= "table" or type(query.stockRef) ~= "table" then return nil, "QUERY" end
            return { stockRefs = { query.stockRef }, purpose = "BALE_BIRTH" }
        end,
    }
    local ok, lease = pcall(sg.registerConsumer, GP.BALE_CONSUMER_ID, spec)
    if ok and type(lease) == "table" then self.consumerLease = lease return true end
    return false
end

--- The account StockGuard's record holds for a vehicle's fill unit: the G3 account, or nil and
--- the reason. Taken only from a READY read of a KNOWN or UNKNOWN record whose account is well
--- formed; a record SG-1 qualified, or one with no account (an unframed chamber), is none.
---@return table|nil account, string|nil reason
function GroundConditionProperty:readChamberAccount(vehicle, fillUnitIndex)
    local sg, lease = self.handle, self.consumerLease
    if self.lease == nil or type(sg) ~= "table" then return nil, "STOCKGUARD_ABSENT" end
    if type(sg.fillUnitStockRef) ~= "function" or type(sg.readMaterial) ~= "function" then return nil, "NO_LOOKUP" end
    if lease == nil then return nil, "NO_CONSUMER" end
    local okL, ref, whyL = pcall(sg.fillUnitStockRef, vehicle, fillUnitIndex)
    if not okL then return nil, "LOOKUP_ERROR" end
    if type(ref) ~= "table" then return nil, tostring(whyL or "NO_STOCK") end
    local okR, read = pcall(sg.readMaterial, lease, { stockRef = ref, propertyIds = { GP.PROPERTY_ID } })
    if not okR or type(read) ~= "table" or read.state ~= "READY" or type(read.records) ~= "table" then return nil, "READ" end
    local snap = read.records[1]
    if type(snap) ~= "table" or snap.state ~= "READY" or type(snap.properties) ~= "table" then return nil, "NOT_READY" end
    local rec = snap.properties[GP.PROPERTY_ID]
    if type(rec) ~= "table" or (rec.knowledge ~= "KNOWN" and rec.knowledge ~= "UNKNOWN") then return nil, "QUALIFIED" end
    local acc = type(rec.payload) == "table" and rec.payload.account or nil
    if acc == nil then return nil, "NO_ACCOUNT" end
    if GP.accountProblem(acc) ~= nil then return nil, "ACCOUNT" end
    local out = {}
    for _, k in ipairs(GP.ACCOUNT_FIELDS) do out[k] = acc[k] end
    return out, nil
end

--- Withdraw the registration: unload, or a condition owner stood down.
---@return boolean withdrawn
function GroundConditionProperty:withdraw(why)
    local lease, sg = self.lease, self.handle
    if lease == nil then return false end
    self.lease, self.handle = nil, nil
    pcall(sg.unregisterOwner, lease)
    if self.consumerLease ~= nil then
        pcall(sg.unregisterOwner, self.consumerLease)
        self.consumerLease = nil
    end
    if self.coordinator ~= nil then self.coordinator:bumpRevision("provider-withdrawn") end
    SoilLogger.info("[GroundProperty] %s withdrawn from StockGuard (%s)", GP.PROPERTY_ID, tostring(why))
    return true
end

--- Per update: a stand-down withdraws the property.
function GroundConditionProperty:update()
    if self.lease ~= nil and not self:isLive() then
        self:withdraw("a condition owner stood down")
    end
end
