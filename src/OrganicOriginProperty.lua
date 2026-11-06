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
-- brackets). Confirmed against FS25_StockGuard's origin/development: neither
-- `context` nor `contributions` (nor `destinations`) carry a field id, a
-- world position, or a reference to the acting vehicle anywhere in
-- StockGuard's own data shapes - grepped SGOperations.lua, SGHarvestCapture.lua,
-- SGCutState.lua and SGGroundObserver.lua, all confirmed absent. StockGuard
-- exposes no reverse lookup from a destination's carrierId back to the
-- vehicle that produced it either.
--
-- FIELD RESOLUTION, best available (see the PR body for the full writeup):
-- transform has no vehicle to read a position from, so this falls back to
-- `g_currentMission.controlledVehicle`, gated to a vehicle that is actually
-- doing fieldwork (spec_combine, spec_mower or spec_cutter present). This is
-- a single-player-biased stand-in: it is WRONG whenever the harvesting
-- vehicle is not the one a human is sitting in (a hired worker, an AI
-- contract, any dedicated server). When no such vehicle is available the
-- property is honestly UNKNOWN rather than guessed - never a fabricated 0
-- or 1. A real fix needs StockGuard to carry the vehicle or its position
-- through capture, which this file cannot do from the producer side alone.
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

--- The best-available position proxy for "the vehicle that just produced
--- this birth" - see the header. nil when no fieldwork vehicle is
--- identifiable; the caller must treat that as UNKNOWN, never as field 0.
function OrganicOriginProperty:resolveActingVehicle()
    local vehicle = g_currentMission and g_currentMission.controlledVehicle
    if type(vehicle) ~= "table" then return nil end
    if vehicle.spec_combine == nil and vehicle.spec_mower == nil and vehicle.spec_cutter == nil then
        return nil
    end
    return vehicle
end

--- The field id under the best-available vehicle/position proxy, or nil
--- when none can be resolved (honestly unknown, not a guess).
function OrganicOriginProperty:resolveFieldId()
    if self.hookManager == nil then return nil end
    local vehicle = self:resolveActingVehicle()
    if vehicle == nil or vehicle.rootNode == nil then return nil end
    local ok, x, _, z = pcall(getWorldTranslation, vehicle.rootNode)
    if not ok or not isFinite(x) or not isFinite(z) then return nil end
    return self.hookManager:getFieldIdAtWorldPosition(x, z)
end

---@return table record
function OrganicOriginProperty:transform(context, contributions, destinations)
    local d = type(destinations) == "table" and destinations[1] or nil
    local amount = type(d) == "table" and d.amount or nil
    local unit = type(d) == "table" and d.unit or nil
    local fieldId = self:resolveFieldId()
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
