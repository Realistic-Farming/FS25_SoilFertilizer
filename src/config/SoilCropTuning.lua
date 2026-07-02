-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Crop Tuning
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Player-editable per-crop N/P/K requirements (issue #717). The mod reads
-- a plain XML the player can hand-edit, applies it over the built-in
-- CROP_EXTRACTION table, and lets custom crops be added. The in-game Crop
-- Tuning Editor (SoilCropTuningPanel) writes the same file, so hand-editing
-- and the editor stay in sync.
--
-- The simulation reads SoilConstants.CROP_EXTRACTION[lowerName] live
-- (SoilFertilitySystem), so overriding entries in that table takes effect
-- immediately with no other plumbing.
--
-- File: <savegameDirectory>/soilCropTuning.xml
--   <cropTuning>
--     <crop name="wheat"  n="2.00" p="0.80" k="1.50" />
--     <crop name="mycrop" n="2.50" p="1.00" k="1.80" custom="true" />
--   </cropTuning>
-- =========================================================

---@class SoilCropTuning
SoilCropTuning = {}
local SoilCropTuning_mt = Class(SoilCropTuning)

SoilCropTuning.SAVE_FILE = "soilCropTuning.xml"
SoilCropTuning.MIN_VALUE = 0.0
SoilCropTuning.MAX_VALUE = 20.0
SoilCropTuning.KEYS      = { "N", "P", "K" }

-- Deep copy of the crops as shipped, captured once at load, for reset.
local function snapshotDefaults()
    local out = {}
    if SoilConstants and SoilConstants.CROP_EXTRACTION then
        for name, r in pairs(SoilConstants.CROP_EXTRACTION) do
            out[name] = { N = r.N, P = r.P, K = r.K }
        end
    end
    return out
end

SoilCropTuning.DEFAULTS = snapshotDefaults()

local function clamp(v)
    if type(v) ~= "number" or v ~= v then return nil end
    if v < SoilCropTuning.MIN_VALUE then v = SoilCropTuning.MIN_VALUE end
    if v > SoilCropTuning.MAX_VALUE then v = SoilCropTuning.MAX_VALUE end
    return v
end

-- Crop names are the lowercase keys the sim looks up.
local function normalizeName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("%s+", ""):lower()
    if name == "" then return nil end
    return name
end

function SoilCropTuning.new(settings)
    local self = setmetatable({}, SoilCropTuning_mt)
    self.settings = settings
    self.custom   = {}   -- name -> true for crops not in DEFAULTS
    return self
end

function SoilCropTuning:getSavePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
        or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. SoilCropTuning.SAVE_FILE
end

-- True if a crop is not one of the shipped defaults.
function SoilCropTuning:isCustom(name)
    return SoilCropTuning.DEFAULTS[name] == nil
end

-- Sorted list of the current crop names.
function SoilCropTuning:getCropNames()
    local names = {}
    for name in pairs(SoilConstants.CROP_EXTRACTION) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

function SoilCropTuning:getRates(name)
    return SoilConstants.CROP_EXTRACTION[name]
end

-- Set one nutrient (N/P/K) for a crop, clamped, and persist.
function SoilCropTuning:setNutrient(name, key, value)
    local rates = SoilConstants.CROP_EXTRACTION[name]
    if rates == nil then return false end
    if key ~= "N" and key ~= "P" and key ~= "K" then return false end
    local v = clamp(value)
    if v == nil then return false end
    rates[key] = v
    self:save()
    return true
end

-- Add a new custom crop seeded from the generic default, and persist.
function SoilCropTuning:addCrop(name)
    local n = normalizeName(name)
    if n == nil then return false, "invalid name" end
    if SoilConstants.CROP_EXTRACTION[n] ~= nil then return false, "already exists" end
    local d = SoilConstants.CROP_EXTRACTION_DEFAULT or { N = 2.10, P = 0.90, K = 1.70 }
    SoilConstants.CROP_EXTRACTION[n] = { N = d.N, P = d.P, K = d.K }
    self.custom[n] = true
    self:save()
    return true
end

-- Remove a crop. Custom crops are dropped entirely; a built-in crop is
-- restored to its shipped default instead of being removed.
function SoilCropTuning:removeCrop(name)
    if self:isCustom(name) then
        SoilConstants.CROP_EXTRACTION[name] = nil
        self.custom[name] = nil
    else
        self:resetCrop(name)
        return true
    end
    self:save()
    return true
end

-- Reset one crop to its shipped default (custom crops have none, so they
-- are removed).
function SoilCropTuning:resetCrop(name)
    local d = SoilCropTuning.DEFAULTS[name]
    if d == nil then
        SoilConstants.CROP_EXTRACTION[name] = nil
        self.custom[name] = nil
    else
        SoilConstants.CROP_EXTRACTION[name] = { N = d.N, P = d.P, K = d.K }
    end
    self:save()
    return true
end

-- Restore every crop to the shipped set (drops all overrides + custom crops).
function SoilCropTuning:resetAll()
    local fresh = {}
    for name, r in pairs(SoilCropTuning.DEFAULTS) do
        fresh[name] = { N = r.N, P = r.P, K = r.K }
    end
    SoilConstants.CROP_EXTRACTION = fresh
    self.custom = {}
    self:save()
    return true
end

-- Read the XML (if present) and apply it over the built-in table. A crop
-- not in the defaults is tracked as custom. Missing file is a no-op.
function SoilCropTuning:load()
    local path = self:getSavePath()
    if path == nil or not fileExists(path) then
        return
    end
    local xml = XMLFile.loadIfExists("sf_cropTuning", path)
    if xml == nil then return end

    local i = 0
    while true do
        local key = string.format("cropTuning.crop(%d)", i)
        local rawName = xml:getString(key .. "#name")
        if rawName == nil then break end
        local name = normalizeName(rawName)
        if name ~= nil then
            local n = clamp(xml:getFloat(key .. "#n", nil))
            local p = clamp(xml:getFloat(key .. "#p", nil))
            local k = clamp(xml:getFloat(key .. "#k", nil))
            local base = SoilConstants.CROP_EXTRACTION[name]
                      or SoilCropTuning.DEFAULTS[name]
                      or SoilConstants.CROP_EXTRACTION_DEFAULT
                      or { N = 2.10, P = 0.90, K = 1.70 }
            SoilConstants.CROP_EXTRACTION[name] = {
                N = n or base.N, P = p or base.P, K = k or base.K,
            }
            if self:isCustom(name) then
                self.custom[name] = true
            end
        end
        i = i + 1
    end
    xml:delete()
    SoilLogger.info("Crop tuning loaded (%d crop entries from XML)", i)
end

-- Write every current crop to the XML as a complete, hand-editable snapshot.
function SoilCropTuning:save()
    local path = self:getSavePath()
    if path == nil then return end
    local xml = XMLFile.create("sf_cropTuning", path, "cropTuning")
    if xml == nil then return end

    local names = self:getCropNames()
    for idx, name in ipairs(names) do
        local r = SoilConstants.CROP_EXTRACTION[name]
        local key = string.format("cropTuning.crop(%d)", idx - 1)
        xml:setString(key .. "#name", name)
        xml:setFloat(key .. "#n", r.N or 0)
        xml:setFloat(key .. "#p", r.P or 0)
        xml:setFloat(key .. "#k", r.K or 0)
        if self:isCustom(name) then
            xml:setBool(key .. "#custom", true)
        end
    end
    xml:save()
    xml:delete()
end
