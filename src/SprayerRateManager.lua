-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Sprayer Rate Manager
-- =========================================================
-- Tracks per-vehicle application rate multiplier.
-- Rate persists for the lifetime of the vehicle object and is
-- cleared only on mod unload. Players who hop out and back in
-- keep their last-set rate between sessions.
-- =========================================================

---@class SprayerRateManager
SprayerRateManager = SprayerRateManager or {}
SprayerRateManager.__index = SprayerRateManager

function SprayerRateManager.new()
    local self = setmetatable({}, SprayerRateManager)
    -- vehicleId (number) → rateIndex (1..#STEPS)
    self.vehicleRates = {}
    -- vehicleId (number) → autoMode (boolean)
    self.vehicleAutoModes = {}
    return self
end

--- Returns the current rate index for a vehicle (defaults to DEFAULT_INDEX).
---@param vehicleId number
---@return number index
function SprayerRateManager:getIndex(vehicleId)
    return self.vehicleRates[vehicleId] or SoilConstants.SPRAYER_RATE.DEFAULT_INDEX
end

--- Returns the rate multiplier (e.g. 1.0, 1.5) for a vehicle.
---@param vehicleId number
---@return number multiplier
function SprayerRateManager:getMultiplier(vehicleId)
    local idx = self:getIndex(vehicleId)
    return SoilConstants.SPRAYER_RATE.STEPS[idx] or 1.0
end

--- Returns whether Auto-Mode is enabled for a vehicle.
--- [SF-46] autoForce is the playtest override (rfAutoRateSet console command):
--- when non-nil it wins for EVERY vehicle, which is what makes it deterministic
--- as a harness - it survives vehicle changes, helper hand-off and the HUD
--- toggle alike. nil = no override, normal per-vehicle behaviour.
---@param vehicleId number
---@return boolean enabled
function SprayerRateManager:getAutoMode(vehicleId)
    if self.autoForce ~= nil then return self.autoForce end
    return self.vehicleAutoModes[vehicleId] == true
end

--- Sets the Auto-Mode state for a vehicle.
---@param vehicleId number
---@param enabled boolean
function SprayerRateManager:setAutoMode(vehicleId, enabled)
    self.vehicleAutoModes[vehicleId] = (enabled == true)
end

--- Toggles Auto-Mode for a vehicle and returns the new state.
---@param vehicleId number
---@return boolean newState
function SprayerRateManager:toggleAutoMode(vehicleId)
    local newState = not self:getAutoMode(vehicleId)
    self:setAutoMode(vehicleId, newState)
    return newState
end

--- Explicitly sets the rate index for a vehicle.
---@param vehicleId number
---@param index number 1-based index into SPRAYER_RATE.STEPS
function SprayerRateManager:setIndex(vehicleId, index)
    local steps = SoilConstants.SPRAYER_RATE.STEPS
    if index >= 1 and index <= #steps then
        self.vehicleRates[vehicleId] = index
    end
end

--- Cycle rate up by one step. Returns the new index.
---@param vehicleId number
---@return number newIndex
function SprayerRateManager:cycleUp(vehicleId)
    local steps = SoilConstants.SPRAYER_RATE.STEPS
    local newIdx = math.min(self:getIndex(vehicleId) + 1, #steps)
    self.vehicleRates[vehicleId] = newIdx
    return newIdx
end

--- Cycle rate down by one step. Returns the new index.
---@param vehicleId number
---@return number newIndex
function SprayerRateManager:cycleDown(vehicleId)
    local newIdx = math.max(self:getIndex(vehicleId) - 1, 1)
    self.vehicleRates[vehicleId] = newIdx
    return newIdx
end

--- Called on mod unload to release all state.
function SprayerRateManager:delete()
    self.vehicleRates = {}
    self.vehicleAutoModes = {}
end
