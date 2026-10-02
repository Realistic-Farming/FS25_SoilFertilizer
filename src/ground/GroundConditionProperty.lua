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
-- be aged and is unknown. Wetness is kept as captured.
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

---@return table|nil record, string|nil reason
function GroundConditionProperty:combine(_context, contributions, destinationBefore)
    local parts, unit = {}, nil
    local function add(litres, rec, partUnit)
        litres = tonumber(litres) or 0
        -- Zero litres import nothing: not unknown, not a refusal (section 2).
        if not isFinite(litres) or litres <= 0 then return end
        local a, w, d = componentsOf(rec)
        parts[#parts + 1] = { litres = litres, ageRaw = a, wetnessRaw = w, ageDay = d }
        if unit == nil and type(partUnit) == "string" then unit = partUnit end
    end
    if type(destinationBefore) == "table" then
        local props = type(destinationBefore.properties) == "table" and destinationBefore.properties or {}
        add(destinationBefore.observedAmount, props[GP.PROPERTY_ID], destinationBefore.amountUnit)
    end
    if type(contributions) == "table" then
        for _, part in ipairs(contributions) do
            local props = type(part.properties) == "table" and part.properties or {}
            add(part.amount, props[GP.PROPERTY_ID], part.unit)
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
    return GP.record({ ageRaw = combined.ageRaw, wetnessRaw = combined.wetnessRaw, ageDay = newest },
        total, unit, c ~= nil and c.changeCounter or 0)
end

---@return table record
function GroundConditionProperty:transform(_context, _contributions, destinations)
    local d = type(destinations) == "table" and destinations[1] or nil
    local c = self.coordinator
    return GP.record({ ageRaw = AGE_UNKNOWN, wetnessRaw = WET_UNKNOWN },
        type(d) == "table" and d.amount or nil, type(d) == "table" and d.unit or nil, c ~= nil and c.changeCounter or 0)
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
    coordinator:bumpRevision("provider-registered")
    SoilLogger.info("[OK] %s registered with StockGuard (epoch %d)", GP.PROPERTY_ID, coordinator.epoch)
    return true, nil
end

--- Withdraw the registration: unload, or a condition owner stood down.
---@return boolean withdrawn
function GroundConditionProperty:withdraw(why)
    local lease, sg = self.lease, self.handle
    if lease == nil then return false end
    self.lease, self.handle = nil, nil
    pcall(sg.unregisterOwner, lease)
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
