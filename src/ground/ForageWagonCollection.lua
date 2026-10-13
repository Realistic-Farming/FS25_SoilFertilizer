--
-- ForageWagonCollection
--
-- RSF-F211 part 2b (the ForageWagon): the condition of what a forage wagon holds is the
-- condition of the material it actually took in, weighted by the litres it retained.
--
-- ONE REAL BUFFER. The wagon's pickup (ForageWagon:processForageWagonArea, :138-203)
-- adds each call's produced litres (post-additive) to workAreaParameters.litersToFill,
-- its one buffer; the call can remove twice (the forced type, then grass's hay twin or
-- the reverse, :155-160). Each call runs in a carrier frame on the captured pointer (the
-- ground side is GroundMovementCarrier's, as for the Baler); its sources are sealed at
-- once against the litres the call added to the buffer, whose account takes them. The
-- call's return is worked area, never litres.
--
-- ACCEPTANCE. fillForageWagon (:216-228) adds the whole buffer to the fill unit and
-- subtracts only what the FillUnit call returned; a remainder below 0.01 is trimmed.
-- That admitted call's return is A: A / buffer of the buffer's account moves to the
-- fill unit's account, the rest stays with the buffer, and a trim is a real discard.
-- The wagon's own fill-change listener is not an observer (the engine removes it at load
-- when there is no start-fill effect, ForageWagon:onLoad :84-86), so A is read off the FillUnit call made
-- inside fillForageWagon.
--
-- SERVER ONLY, and standalone as the Baler's: a StockGuard lease on the pickup stands
-- the frame aside and the account says unknown.
--

ForageWagonCollection = ForageWagonCollection or {}
local FC = ForageWagonCollection
local BC = BalerCollection

FC.STATE_KEY = "_sfForageWagonCollection"

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

function FC.state(vehicle)
    if type(vehicle) ~= "table" then return nil end
    local st = rawget(vehicle, FC.STATE_KEY)
    if st == nil then
        st = { buffer = BC.newAccount(), unit = BC.newAccount() }
        rawset(vehicle, FC.STATE_KEY, st)
    end
    return st
end

local function bufferLevel(vehicle)
    local spec = vehicle.spec_forageWagon
    local wap = spec ~= nil and spec.workAreaParameters or nil
    local level = wap ~= nil and wap.litersToFill or nil
    if finite(level) then return level end
    return nil
end

local function unitLevel(vehicle)
    local spec = vehicle.spec_forageWagon
    local ok, level = pcall(vehicle.getFillUnitFillLevel, vehicle, spec.fillUnitIndex)
    if ok and finite(level) then return level end
    return nil
end

--- The captured pickup pointer's wrapper: a carrier frame per call, the call's sources
--- sealed into the buffer account against the litres the call added to the buffer.
function FC.makePickupWrapper(original)
    return function(vehicle, workArea, ...)
        local server = g_server ~= nil and vehicle.isServer and vehicle.spec_forageWagon ~= nil
        local frame, before = nil, nil
        if server then
            before = bufferLevel(vehicle)
            if GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil and g_SoilFertilityManager.settings ~= nil
               and g_SoilFertilityManager.settings.enabled then
                local okBegin, f = pcall(GroundMovementCarrier.begin, g_SoilFertilityManager.soilSystem, vehicle, workArea,
                    GroundMovementCarrier.KIND_FORAGE_WAGON)
                if okBegin and f ~= nil then
                    f.handler = BC.handler
                    f.collection = { sources = {}, unexplained = 0, raw = 0 }
                    frame = f
                end
            end
        end
        local packed = { n = select("#", ...) + 2, pcall(original, vehicle, workArea, ...) }
        if frame ~= nil then pcall(GroundMovementCarrier.finish, frame) end
        if not packed[1] then error(packed[2], 0) end
        if server then pcall(FC.afterPickup, vehicle, frame, before) end
        return unpack(packed, 2)
    end
end

function FC.afterPickup(vehicle, frame, before)
    local st = FC.state(vehicle)
    local after = bufferLevel(vehicle)
    local produced = (after ~= nil and before ~= nil) and (after - before) or 0
    if produced > BC.EPSILON then
        local ctx = { batches = {} }
        BC.closeCall(ctx, frame ~= nil and frame.collection or { sources = {}, unexplained = 0, raw = 0 }, produced)
        BC.accountAddAccount(st.buffer, BC.sealTarget(ctx, produced, produced))
    end
    if after ~= nil then BC.accountReconcile(st.buffer, after) end
end

--- fillForageWagon (instance): A is the admitted FillUnit call's return.
function FC.aroundFill(vehicle, original, ...)
    local spec = vehicle.spec_forageWagon
    if g_server == nil or not vehicle.isServer or spec == nil then return original(vehicle, ...) end
    local st = FC.state(vehicle)
    local lb, lu = bufferLevel(vehicle), unitLevel(vehicle)
    if lb ~= nil then BC.accountReconcile(st.buffer, lb) end
    if lu ~= nil then BC.accountReconcile(st.unit, lu) end
    local own = vehicle.addFillUnitFillLevel
    local accepted = 0
    local recorder = function(v, farmId, fillUnitIndex, delta, ...)
        local r = own(v, farmId, fillUnitIndex, delta, ...)
        if v == vehicle and fillUnitIndex == spec.fillUnitIndex and finite(r) and r > 0 then accepted = accepted + r end
        return r
    end
    rawset(vehicle, "addFillUnitFillLevel", recorder)
    local packed = { pcall(original, vehicle, ...) }
    if rawget(vehicle, "addFillUnitFillLevel") == recorder then rawset(vehicle, "addFillUnitFillLevel", own) end
    if accepted > BC.EPSILON then
        BC.accountAddAccount(st.unit, BC.accountTake(st.buffer, accepted))
    end
    local ab, au = bufferLevel(vehicle), unitLevel(vehicle)
    if ab ~= nil then BC.accountReconcile(st.buffer, ab) end   -- a trim below 0.01 is a real discard
    if au ~= nil then BC.accountReconcile(st.unit, au) end
    if not packed[1] then error(packed[2], 0) end
    return unpack(packed, 2)
end

--- The wagon's load: its percent only when the whole load is known, and its coverage.
---@return number|nil pct, table|nil account
function FC.condition(vehicle)
    local st = type(vehicle) == "table" and rawget(vehicle, FC.STATE_KEY) or nil
    if st == nil then return nil, nil end
    return BC.accountPct(st.unit), BC.copyAccount(st.unit)
end

SoilLogger.info("ForageWagonCollection (RSF-F211) loaded")
