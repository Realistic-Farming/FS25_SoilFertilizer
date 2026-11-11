-- =========================================================
-- OrganicOriginProperty
-- =========================================================
-- Build brief: organic-origin-property-BUILD-BRIEF.md (Office Tyson,
-- FS25_SoilFertilizer). SoilFertilizer registers as a StockGuard SG1
-- property producer and supplies `harvestOrganicOriginV1`: the organic
-- fraction of material at the moment it is born into StockGuard's tracked
-- stock (a combine tank filling, a mower's forage, dropped straw). MD-16
-- reads this through StockGuard to pay a per-sale organic premium; this
-- file is SoilFertilizer's producer side only, mirroring the registration
-- lifecycle of src/ground/GroundConditionProperty.lua exactly: pcall-guarded
-- against StockGuard's absence, lease-released on teardown.
--
-- A STORED property with `birth = true` (SGRegistry.lua:148-152): StockGuard
-- calls this producer's transform once per birth candidate (a new stock
-- entering a carrier from a native harvest, mow or straw-drop event),
-- through SGOperations.lua's interpretDestination/settleOperation, always
-- synchronously inside the same native call StockGuard's own capture wraps
-- (SGHarvestCapture.lua's cut/drain brackets, SGGroundObserver.lua's mower
-- brackets).
--
-- FIELD RESOLUTION, from the birth's own place. StockGuard's capture reads
-- where the cut happened inside the native call and names it in the cut's
-- outcomeEvidence as vehiclePosition { x, y, z, vehicleId }: the header's
-- root node (else the combine's) on the combine cut, the mower's on the
-- Mower cut (FS25_StockGuard PR #75, SGNativeAdapters.vehiclePositionOf).
-- SG-1 hands that evidence to this transform as
-- context.report.outcomeEvidence (SGOperations.lua _settle), so the field is
-- the one under that place, whoever drives: a player, a hired worker, or a
-- dedicated server where nobody sits in the vehicle.
--
-- No place, no field: when the evidence names no place (a StockGuard older
-- than #75, or a vehicle whose position did not read) the property is
-- honestly UNKNOWN, never a fabricated 0 or 1. There is deliberately no
-- fallback to a player's vehicle. The first build read
-- `g_currentMission.controlledVehicle`, which FS25 never assigns (no
-- assignment anywhere in the decompiled dataS/scripts; the engine reads
-- `player:getCurrentVehicle()`), and any player-vehicle stand-in would name
-- the player's field for a hired worker's harvest elsewhere.
--
-- COMBINE, for material merged while off the ground (SG-2's weighted-average
-- rule): fraction = sum(part.amount * part.fraction) / sum(part.amount),
-- matching OrganicCertification:getFarmOrganicFraction's own blend
-- arithmetic exactly (OrganicCertification.lua's `recordHarvest`/
-- `getFarmOrganicFraction`: frac = (total * oldFrac + amount * isOrganic) /
-- (total + amount), the same incremental weighted average generalized to N
-- parts here). A part whose own record is not KNOWN carries no litres into
-- the blend: there is no sensible numeric fraction to weigh in for a
-- continuous value, unlike GroundConditionProperty's categorical floor.
--
-- DISCLOSURE: nothing. No player view has been decided for this property
-- (same stance as GroundConditionProperty's own disclosure stub).
--
-- No player-facing strings: this property is internal plumbing consumed by
-- StockGuard/MD-16, not shown to the player directly, so no new l10n keys.
-- =========================================================

OrganicOriginProperty = OrganicOriginProperty or {}
local OrganicOriginProperty_mt = Class(OrganicOriginProperty)
local OOP = OrganicOriginProperty

OOP.PROPERTY_ID    = "harvestOrganicOriginV1"
OOP.SCHEMA_VERSION = 1
OOP.PRODUCER_ID    = "soil"

OOP.NO_MATERIAL = "NO_MATERIAL"

local function isFinite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function OrganicOriginProperty.new(hookManager)
    local self = setmetatable({}, OrganicOriginProperty_mt)
    self.hookManager = hookManager
    self.handle = nil
    self.lease  = nil
    return self
end

function OrganicOriginProperty:isRegistered()
    return self.lease ~= nil
end

-- =========================================================
-- The record
-- =========================================================

--- One property record. `fraction` is nil for an honestly unresolved birth
--- (UNKNOWN); otherwise a number in [0,1] (KNOWN).
function OrganicOriginProperty.record(fraction, amount, unit, revision)
    local known = isFinite(fraction)
    local clamped = known and math.max(0, math.min(1, fraction)) or 0
    local rec = {
        propertyId       = OOP.PROPERTY_ID,
        schemaVersion    = OOP.SCHEMA_VERSION,
        producerId       = OOP.PRODUCER_ID,
        propertyRevision = (type(revision) == "number" and revision >= 0) and math.floor(revision) or 0,
        knowledge        = known and "KNOWN" or "UNKNOWN",
        payload          = { fraction = clamped },
    }
    if isFinite(amount) and amount >= 0 and type(unit) == "string" and unit ~= "" then
        rec.basisAmount = amount
        rec.knownAmount = known and amount or 0
        rec.amountUnit  = unit
    end
    return rec
end

---@return boolean valid, string|nil reason
function OrganicOriginProperty.validate(rec)
    if type(rec) ~= "table" then return false, "NOT_TABLE" end
    if rec.propertyId ~= OOP.PROPERTY_ID or rec.schemaVersion ~= OOP.SCHEMA_VERSION or rec.producerId ~= OOP.PRODUCER_ID then
        return false, "IDENTITY"
    end
    if rec.knowledge ~= "KNOWN" and rec.knowledge ~= "UNKNOWN" then return false, "KNOWLEDGE" end
    local p = rec.payload
    if type(p) ~= "table" then return false, "PAYLOAD" end
    if not isFinite(p.fraction) or p.fraction < 0 or p.fraction > 1 then return false, "FRACTION" end
    return true
end

-- =========================================================
-- Combine: the weighted-average-by-litres merge
-- =========================================================

--- A record's fraction when it can be trusted into the blend: only a KNOWN
--- record of this property. An UNKNOWN or otherwise-qualified record (SG-1
--- qualifies a record it can no longer vouch for in place) carries no
--- litres into the average, same as a missing record.
local function knownFractionOf(propRec)
    if type(propRec) ~= "table" or propRec.knowledge ~= "KNOWN" then return nil end
    local p = propRec.payload
    if type(p) ~= "table" or not isFinite(p.fraction) then return nil end
    return p.fraction
end

---@return table|nil record, string|nil reason
function OrganicOriginProperty:combine(context, contributions, destinationBefore)
    local totalLitres, weighted, unit = 0, 0, nil
    local function add(litres, propRec, partUnit)
        litres = tonumber(litres) or 0
        -- Zero litres import nothing: not unknown, not a refusal.
        if not isFinite(litres) or litres <= 0 then return end
        local frac = knownFractionOf(propRec)
        if frac == nil then return end
        totalLitres = totalLitres + litres
        weighted = weighted + litres * frac
        if unit == nil and type(partUnit) == "string" then unit = partUnit end
    end
    if type(destinationBefore) == "table" then
        local props = type(destinationBefore.properties) == "table" and destinationBefore.properties or {}
        add(destinationBefore.observedAmount, props[OOP.PROPERTY_ID], destinationBefore.amountUnit)
    end
    if type(contributions) == "table" then
        for _, part in ipairs(contributions) do
            local props = type(part.properties) == "table" and part.properties or {}
            add(part.amount, props[OOP.PROPERTY_ID], part.unit)
        end
    end
    if totalLitres <= 0 then return nil, OOP.NO_MATERIAL end
    return OrganicOriginProperty.record(weighted / totalLitres, totalLitres, unit, 0)
end

-- =========================================================
-- Transform: the birth read
-- =========================================================

--- Where StockGuard's capture says this birth happened: the x and z of
--- context.report.outcomeEvidence.vehiclePosition (see the header). nil when
--- the evidence names no finite place; the caller treats that as UNKNOWN,
--- never as field 0.
---@return number|nil x, number|nil z
function OrganicOriginProperty.birthPosition(context)
    local report = type(context) == "table" and context.report or nil
    local evidence = type(report) == "table" and report.outcomeEvidence or nil
    local p = type(evidence) == "table" and evidence.vehiclePosition or nil
    if type(p) ~= "table" or not isFinite(p.x) or not isFinite(p.z) then return nil, nil end
    return p.x, p.z
end

--- The field id under the birth's own place, or nil when there is none
--- (honestly unknown, not a guess).
function OrganicOriginProperty:resolveFieldId(context)
    if self.hookManager == nil then return nil end
    local x, z = OOP.birthPosition(context)
    if x == nil then return nil end
    return self.hookManager:getFieldIdAtWorldPosition(x, z)
end

---@return table record
function OrganicOriginProperty:transform(context, contributions, destinations)
    local d = type(destinations) == "table" and destinations[1] or nil
    local amount = type(d) == "table" and d.amount or nil
    local unit = type(d) == "table" and d.unit or nil
    local fieldId = self:resolveFieldId(context)
    if fieldId == nil then
        return OrganicOriginProperty.record(nil, amount, unit, 0)
    end
    local organic = g_SoilFertilityManager and g_SoilFertilityManager.organic
    local state = organic and organic:getFieldOrganicState(fieldId)
    local fraction = (state ~= nil and state.certified == true) and 1 or 0
    return OrganicOriginProperty.record(fraction, amount, unit, 0)
end

-- =========================================================
-- Registration
-- =========================================================

--- The spec SGRegistry:registerProperty takes (SGRegistry.lua:139-163). A
--- STORED property with birth = true needs no resolveResident/
--- getResidentRevision (OWNER_RESOLVED only); every other callback is a
--- closure on this object, called by StockGuard with dots.
function OrganicOriginProperty:spec()
    return {
        schemaVersion = OOP.SCHEMA_VERSION,
        producerId    = OOP.PRODUCER_ID,
        residency     = "STORED",
        birth         = true,
        validate      = OOP.validate,
        combine       = function(context, contributions, destinationBefore)
                            return self:combine(context, contributions, destinationBefore)
                        end,
        transform     = function(context, contributions, destinations)
                            return self:transform(context, contributions, destinations)
                        end,
        disclosure    = function() return nil end,
    }
end

--- Register with StockGuard on the server. StockGuard absent is the
--- ordinary Soil-alone path: nothing is registered and nothing is a fault.
---@return boolean registered, string|nil reason
function OrganicOriginProperty:register(mission)
    if g_server == nil then return false, "NOT_SERVER" end
    if self.lease ~= nil then return true, "ALREADY_REGISTERED" end
    mission = mission or g_currentMission
    local sg = mission ~= nil and mission.stockGuard or nil
    if type(sg) ~= "table" or type(sg.registerProperty) ~= "function" or type(sg.unregisterOwner) ~= "function" then
        return false, "STOCKGUARD_ABSENT"
    end
    local ok, lease, why = pcall(sg.registerProperty, OOP.PROPERTY_ID, self:spec())
    if not ok or type(lease) ~= "table" then
        local reason = ok and tostring(why) or "REGISTER_ERROR"
        SoilLogger.warning("[OrganicOrigin] StockGuard refused %s (%s) - the organic premium cannot read harvest origin",
            OOP.PROPERTY_ID, reason)
        return false, reason
    end
    self.handle, self.lease = sg, lease
    SoilLogger.info("[OK] %s registered with StockGuard", OOP.PROPERTY_ID)
    return true, nil
end

--- Withdraw the registration: unload.
---@return boolean withdrawn
function OrganicOriginProperty:withdraw(why)
    local lease, sg = self.lease, self.handle
    if lease == nil then return false end
    self.lease, self.handle = nil, nil
    pcall(sg.unregisterOwner, lease)
    SoilLogger.info("[OrganicOrigin] %s withdrawn from StockGuard (%s)", OOP.PROPERTY_ID, tostring(why))
    return true
end
