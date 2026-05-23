-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Smart Sensor Manager
-- =========================================================
-- Tracks per-vehicle state for the three Smart Sensor modes:
--   pest     (insecticide section control)
--   disease  (fungicide section control)
--   nutrient (K/P fertilizer section control)
--
-- Vehicle state is keyed by vehicle.id and persists for
-- the lifetime of the vehicle object (cleared on mod unload).
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilSensorManager
SoilSensorManager = {}
SoilSensorManager.__index = SoilSensorManager

-- Nutrient level (0-100) above which the nutrient sensor skips spraying.
-- Separate from YIELD_SENSITIVITY.OPTIMAL_THRESHOLD (50 = yield penalty floor).
-- 70 = "well stocked" / green zone on the SF HUD bar.
SoilSensorManager.NUTRIENT_TARGET = 70

function SoilSensorManager.new()
    local self = setmetatable({}, SoilSensorManager)
    -- System 1: Smart Sensor — vehicleId → { pest=bool, disease=bool, nutrient=bool }
    self.vehicleSensors = {}
    -- System 2: See & Spray — vehicleId → { pest=bool, disease=bool, weed=bool }
    self.seeAndSpray = {}
    -- System 3: Variable Rate — vehicleId → bool
    self.variableRate = {}
    -- System 3: per-section rate cache — vehicleId → { [sectionRef] = multiplier }
    self.sectionRates = {}
    return self
end

--- Returns (creating if needed) the sensor state table for a vehicle.
---@param vehicleId number
---@return table { pest=bool, disease=bool, nutrient=bool }
function SoilSensorManager:getSensors(vehicleId)
    if not self.vehicleSensors[vehicleId] then
        self.vehicleSensors[vehicleId] = { pest = false, disease = false, nutrient = false }
    end
    return self.vehicleSensors[vehicleId]
end

---@param vehicleId number
---@return boolean
function SoilSensorManager:isPestEnabled(vehicleId)
    local s = self.vehicleSensors[vehicleId]
    return s ~= nil and s.pest == true
end

---@param vehicleId number
---@return boolean
function SoilSensorManager:isDiseaseEnabled(vehicleId)
    local s = self.vehicleSensors[vehicleId]
    return s ~= nil and s.disease == true
end

---@param vehicleId number
---@return boolean
function SoilSensorManager:isNutrientEnabled(vehicleId)
    local s = self.vehicleSensors[vehicleId]
    return s ~= nil and s.nutrient == true
end

--- Toggles pest sensor. Returns new state.
---@param vehicleId number
---@return boolean newState
function SoilSensorManager:togglePest(vehicleId)
    local s = self:getSensors(vehicleId)
    s.pest = not s.pest
    return s.pest
end

--- Toggles disease sensor. Returns new state.
---@param vehicleId number
---@return boolean newState
function SoilSensorManager:toggleDisease(vehicleId)
    local s = self:getSensors(vehicleId)
    s.disease = not s.disease
    return s.disease
end

--- Toggles nutrient sensor. Returns new state.
---@param vehicleId number
---@return boolean newState
function SoilSensorManager:toggleNutrient(vehicleId)
    local s = self:getSensors(vehicleId)
    s.nutrient = not s.nutrient
    return s.nutrient
end

--- Returns true if ANY sensor is enabled for the vehicle.
---@param vehicleId number
---@return boolean
function SoilSensorManager:hasAnySensorEnabled(vehicleId)
    local s = self.vehicleSensors[vehicleId]
    if not s then return false end
    return s.pest or s.disease or s.nutrient
end

-- ── System 2: See & Spray ─────────────────────────────────

---@param vehicleId number
---@return table { pest=bool, disease=bool, weed=bool }
function SoilSensorManager:getSeeAndSpray(vehicleId)
    if not self.seeAndSpray[vehicleId] then
        self.seeAndSpray[vehicleId] = { pest = false, disease = false, weed = false }
    end
    return self.seeAndSpray[vehicleId]
end

function SoilSensorManager:isSeeSprayPestEnabled(vehicleId)
    local s = self.seeAndSpray[vehicleId]; return s ~= nil and s.pest == true
end
function SoilSensorManager:isSeeSprayDiseaseEnabled(vehicleId)
    local s = self.seeAndSpray[vehicleId]; return s ~= nil and s.disease == true
end
function SoilSensorManager:isSeeSprayWeedEnabled(vehicleId)
    local s = self.seeAndSpray[vehicleId]; return s ~= nil and s.weed == true
end

function SoilSensorManager:toggleSeeSprayPest(vehicleId)
    local s = self:getSeeAndSpray(vehicleId); s.pest = not s.pest; return s.pest
end
function SoilSensorManager:toggleSeeSprayDisease(vehicleId)
    local s = self:getSeeAndSpray(vehicleId); s.disease = not s.disease; return s.disease
end
function SoilSensorManager:toggleSeeSprayWeed(vehicleId)
    local s = self:getSeeAndSpray(vehicleId); s.weed = not s.weed; return s.weed
end

function SoilSensorManager:hasAnySeeSprayEnabled(vehicleId)
    local s = self.seeAndSpray[vehicleId]
    return s ~= nil and (s.pest or s.disease or s.weed)
end

-- ── System 3: Variable Rate ───────────────────────────────

function SoilSensorManager:isVariableRateEnabled(vehicleId)
    return self.variableRate[vehicleId] == true
end

function SoilSensorManager:toggleVariableRate(vehicleId)
    self.variableRate[vehicleId] = not self.variableRate[vehicleId]
    return self.variableRate[vehicleId]
end

--- Stores the computed rate for a section this tick.
function SoilSensorManager:setSectionRate(vehicleId, section, rate)
    if not self.sectionRates[vehicleId] then self.sectionRates[vehicleId] = {} end
    self.sectionRates[vehicleId][section] = rate
end

--- Returns stored rate, or 1.0 if none computed.
function SoilSensorManager:getSectionRate(vehicleId, section)
    local vr = self.sectionRates[vehicleId]
    return (vr and vr[section]) or 1.0
end

--- Clears per-section rates for a vehicle (call at start of each tick).
function SoilSensorManager:clearSectionRates(vehicleId)
    self.sectionRates[vehicleId] = nil
end

-- ── Lifecycle ─────────────────────────────────────────────

--- Called on mod unload.
function SoilSensorManager:delete()
    self.vehicleSensors = {}
    self.seeAndSpray    = {}
    self.variableRate   = {}
    self.sectionRates   = {}
end
