-- =========================================================
-- FS25 Soil & Fertilizer - CAPACITY INTEGRATION (SG-6, Soil half)
-- =========================================================
-- The owner-side lifecycle of the ground preparation join with StockGuard's
-- capacity controller. Protocol version 2, three dot-call functions:
--
--   SoilCapacityIntegration.beginCapacityLoad(mission)      -> true | false
--   SoilCapacityIntegration.prepareGroundTypes(heightManager, fillManager, maximumGroundIndex)
--                                                           -> true | false, reasonCode, offendingName
--   SoilCapacityIntegration.endCapacityLoad(mission)        -> true
--
-- StockGuard's preflight resolves this table as
-- getfenv(0)["FS25_SoilFertilizer"].SoilCapacityIntegration (the engine
-- publishes every mod environment as a global under its mod name, mods.lua:429
-- and following) at the first action of its conditional Mission00.setMissionInfo
-- wrapper, before any map work, and calls the functions under pcall. It never
-- writes Soil's private tables.
--
-- JOINED MODE: beginCapacityLoad binds the exact mission, switches the ground
-- tip wrapper (GroundTipGate, RSF-F227) to pure delegation and returns true
-- only after doing so. While joinedMission identifies the current mission,
-- main.lua's legacy ground fallback block (late Lua insertion, the
-- constructTerrainFillLayers rebuild and the tip-hook activation) is skipped in
-- every phase; a later prepare failure, exception or failed fill load never
-- releases that fence. endCapacityLoad clears only the matching binding and
-- leaves the legacy override disabled; Soil's unload calls it, and StockGuard's
-- teardown may repeat it safely.
--
-- PREPARATION: prepareGroundTypes appends the mod's missing solid ground
-- definitions BEFORE native DensityMapHeightManager.initialize, so the engine
-- sees every row and does its usual height properties, distance texture and
-- terrain-layer association. It uses the same two templates (FERTILIZER for
-- mineral types, MANURE for organic types) and the same field values as the
-- legacy fallback, in the same fixed order, and validates everything before
-- touching the manager: on failure it returns false, reasonCode, offendingName
-- with no partial insertion. Existing sorted entries are preserved and missing
-- rows are appended at numHeightTypes + 1; the combined roster is never sorted
-- here (that would move legitimate saved indices). Idempotent per manager.
-- =========================================================

SoilCapacityIntegration = SoilCapacityIntegration or {}

SoilCapacityIntegration.protocolVersion = 2

-- The twelve required solid names, in the exact legacy fallback order.
SoilCapacityIntegration.SOLID_ORDER = {
    "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA",
    "GYPSUM", "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE",
}
-- Organic types take the MANURE template (dark pile), mineral types FERTILIZER.
SoilCapacityIntegration.ORGANIC_SET = {
    COMPOST = true, BIOSOLIDS = true, CHICKEN_MANURE = true, PELLETIZED_MANURE = true,
}

SoilCapacityIntegration.REASON_INVALID_ARGS     = "INVALID_ARGS"
SoilCapacityIntegration.REASON_MISSING_FILL     = "MISSING_NATIVE_FILL"
SoilCapacityIntegration.REASON_MISSING_TEMPLATE = "MISSING_TEMPLATE"
SoilCapacityIntegration.REASON_GROUND_CAPACITY  = "GROUND_CAPACITY"
SoilCapacityIntegration.REASON_OTHER_MISSION    = "OTHER_MISSION_ACTIVE"

local _joinedMission = nil

local function log(msg)
    if SoilLogger ~= nil and SoilLogger.info ~= nil then SoilLogger.info(msg) else print("[SoilFertilizer] " .. tostring(msg)) end
end

-- =========================================================
-- Joined mode
-- =========================================================

--- Bind the mission and disable the legacy tip override. True only after the
--- fence is established. Idempotent for the same mission; a different mission
--- that has not been ended is rejected.
function SoilCapacityIntegration.beginCapacityLoad(mission)
    if type(mission) ~= "table" then return false end
    if _joinedMission ~= nil and _joinedMission ~= mission then
        return false
    end
    _joinedMission = mission
    if GroundTipGate ~= nil and GroundTipGate.disable ~= nil then
        GroundTipGate.disable()
    end
    return true
end

--- Clear the matching binding; the legacy override stays disabled. Safe to
--- repeat, safe for a mission that was never joined.
function SoilCapacityIntegration.endCapacityLoad(mission)
    if _joinedMission ~= nil and (mission == nil or _joinedMission == mission) then
        _joinedMission = nil
    end
    if GroundTipGate ~= nil and GroundTipGate.disable ~= nil then
        GroundTipGate.disable()
    end
    return true
end

--- Is this exact mission the joined one? The legacy ground block in main.lua
--- asks this and skips itself entirely when the answer is yes.
function SoilCapacityIntegration.isJoined(mission)
    return _joinedMission ~= nil and mission ~= nil and _joinedMission == mission
end

function SoilCapacityIntegration.getJoinedMission()
    return _joinedMission
end

-- =========================================================
-- Ground preparation
-- =========================================================

local function shallowCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Append the missing solid ground definitions. See the header for the contract.
---@param heightManager table      the DensityMapHeightManager instance
---@param fillManager table        the FillTypeManager instance
---@param maximumGroundIndex number the highest index the map's type channels allow
---@return boolean ok, string|nil reasonCode, string|nil offendingName
function SoilCapacityIntegration.prepareGroundTypes(heightManager, fillManager, maximumGroundIndex)
    if type(heightManager) ~= "table" or type(fillManager) ~= "table"
        or type(fillManager.getFillTypeIndexByName) ~= "function"
        or type(heightManager.heightTypes) ~= "table"
        or type(heightManager.fillTypeIndexToHeightType) ~= "table"
        or type(heightManager.numHeightTypes) ~= "number" then
        return false, SoilCapacityIntegration.REASON_INVALID_ARGS, nil
    end
    if type(maximumGroundIndex) ~= "number" or maximumGroundIndex ~= maximumGroundIndex
        or maximumGroundIndex ~= math.floor(maximumGroundIndex) or maximumGroundIndex < 1 then
        return false, SoilCapacityIntegration.REASON_INVALID_ARGS, nil
    end

    local fertIdx = fillManager:getFillTypeIndexByName("FERTILIZER")
    local manureIdx = fillManager:getFillTypeIndexByName("MANURE")
    local tmplFert = fertIdx ~= nil and heightManager.fillTypeIndexToHeightType[fertIdx] or nil
    local tmplManure = manureIdx ~= nil and heightManager.fillTypeIndexToHeightType[manureIdx] or nil
    local tmpl = tmplFert or tmplManure

    -- Validate everything first: fill index, template, and slot for every
    -- missing name, in order. Nothing is written until all twelve pass.
    local plan = {}
    local nextSlot = heightManager.numHeightTypes + 1
    for _, typeName in ipairs(SoilCapacityIntegration.SOLID_ORDER) do
        local idx = fillManager:getFillTypeIndexByName(typeName)
        if idx == nil then
            return false, SoilCapacityIntegration.REASON_MISSING_FILL, typeName
        end
        if heightManager.fillTypeIndexToHeightType[idx] == nil then
            local srcTmpl = (SoilCapacityIntegration.ORGANIC_SET[typeName] and tmplManure) or tmplFert or tmpl
            if type(srcTmpl) ~= "table" then
                return false, SoilCapacityIntegration.REASON_MISSING_TEMPLATE, typeName
            end
            if nextSlot > maximumGroundIndex then
                return false, SoilCapacityIntegration.REASON_GROUND_CAPACITY, typeName
            end
            plan[#plan + 1] = { name = typeName, idx = idx, tmpl = srcTmpl, slot = nextSlot }
            nextSlot = nextSlot + 1
        end
    end

    -- Insert in the fixed order at the old nextSlot positions. Same fields and
    -- template values as the legacy fallback; no new angle, scale or material.
    for _, p in ipairs(plan) do
        local ht = shallowCopy(p.tmpl)
        ht.allowsSmoothing = false
        ht.canBeTipped     = true
        ht.fillTypeIndex   = p.idx
        ht.fillTypeName    = p.name
        ht.index           = p.slot
        heightManager.fillTypeIndexToHeightType[p.idx] = ht
        if type(heightManager.fillTypeNameToHeightType) == "table" then
            heightManager.fillTypeNameToHeightType[p.name] = ht
        end
        if type(heightManager.heightTypeIndexToFillTypeIndex) == "table" then
            heightManager.heightTypeIndexToFillTypeIndex[p.slot] = p.idx
        end
        heightManager.heightTypes[p.slot] = ht
        heightManager.numHeightTypes = p.slot
    end
    if #plan > 0 then
        log(string.format("[SG-6] prepared %d solid ground definition(s) for native initialization (first slot %d)", #plan, plan[1].slot))
    end
    return true, nil, nil
end

--- Test-only: forget the joined binding so one bench can play several processes.
function SoilCapacityIntegration._resetForTests()
    _joinedMission = nil
end
