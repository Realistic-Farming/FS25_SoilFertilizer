-- =========================================================
-- CD-13: Dog Early-Warning System
-- =========================================================
-- Owning a base-game dog placeable switches on a free,
-- passive, farm-wide crop disease early-warning. It tells
-- the player WHICH field is off, never the disease name or
-- severity (the paid ProStaff rungs sit above it). No false
-- positives: fires only on a named active infection
-- (activeDisease ~= nil), never on raw pressure alone.
-- =========================================================

DogEarlyWarning = DogEarlyWarning or {}

DogEarlyWarning.CADENCE_MS = 60000

-- RSF-F192: the two warning templates resolve through the mod's own locale
-- keys. The English sentences below are the exact conservative fallback when
-- the lookup is unavailable, the key is absent, the template is not a string,
-- or it does not carry exactly one string placeholder. They are not a
-- substitute for shipping the keys in every locale file.
DogEarlyWarning.FIELD_WARNING_KEY = "sf_dog_field_warning"
DogEarlyWarning.BARN_WARNING_KEY  = "sf_dog_barn_warning"
DogEarlyWarning.FIELD_WARNING_FALLBACK = "Your dog senses something wrong with Field #%s."
DogEarlyWarning.BARN_WARNING_FALLBACK  = "Your dog senses something wrong at Barn %s."

--- True when `fmt` carries exactly one unescaped %s and no other conversion.
--- "%%" is a literal percent and does not count; a trailing lone % is rejected.
local function hasOneStringPlaceholder(fmt)
    if type(fmt) ~= "string" or fmt == "" then return false end
    local stripped = fmt:gsub("%%%%", "")
    if stripped:find("%%$") then return false end
    local count, other = 0, false
    for conv in stripped:gmatch("%%[%-%+ #0]*%d*%.?%d*([%a])") do
        if conv == "s" then count = count + 1 else other = true end
    end
    return count == 1 and not other
end

--- Resolve one warning sentence with the field or barn identifier inserted.
--- Never throws: every lookup and format runs under pcall, and the English
--- fallback is used whenever the localized template cannot be trusted.
---@param key string        the locale key
---@param fallback string   the exact English sentence
---@param id any            field or barn identifier
---@return string
function DogEarlyWarning.formatWarning(key, fallback, id)
    local template = nil
    pcall(function()
        local i18n = g_i18n
        if i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
            return
        end
        if i18n:hasText(key) ~= true then return end
        local text = i18n:getText(key)
        if hasOneStringPlaceholder(text) then template = text end
    end)
    local ident = tostring(id)
    local ok, msg = pcall(string.format, template or fallback, ident)
    if ok and type(msg) == "string" then return msg end
    ok, msg = pcall(string.format, fallback, ident)
    if ok and type(msg) == "string" then return msg end
    return fallback
end

function DogEarlyWarning.new(soilSystem)
    local self = {}
    setmetatable(self, { __index = DogEarlyWarning })
    self.soilSystem = soilSystem
    self.warnings = {}
    self.lastScan = 0
    self.notifiedFields = {}
    return self
end

function DogEarlyWarning:hasDogOnFarm(farmId)
    local found = false
    pcall(function()
        local doghouses = g_currentMission and g_currentMission.doghouses
        if doghouses ~= nil then
            for doghouse, _ in pairs(doghouses) do
                if doghouse ~= nil and doghouse.getOwnerFarmId ~= nil then
                    if doghouse:getOwnerFarmId() == farmId then
                        found = true
                        return
                    end
                end
            end
            return
        end
        local ps = g_currentMission and g_currentMission.placeableSystem
        if ps == nil or ps.placeables == nil then return end
        for _, p in ipairs(ps.placeables) do
            if p ~= nil and PlaceableDoghouse ~= nil
                    and SpecializationUtil.hasSpecialization(PlaceableDoghouse, p.specializations) then
                local owner = nil
                if p.getOwnerFarmId ~= nil then owner = p:getOwnerFarmId() end
                if owner == farmId then
                    found = true
                    return
                end
            end
        end
    end)
    return found
end

function DogEarlyWarning:scan(farmId)
    if not self:hasDogOnFarm(farmId) then
        self.warnings[farmId] = nil
        return
    end

    local flagged = {}
    local fields = nil
    pcall(function()
        fields = g_currentMission.fieldManager:getFields()
    end)
    if fields == nil then return end

    local farmland = g_farmlandManager
    for _, field in ipairs(fields) do
        local fid = field.farmland and field.farmland.id
        if fid ~= nil then
            local owner = nil
            pcall(function()
                if farmland ~= nil and farmland.getFarmlandOwner ~= nil then
                    owner = farmland:getFarmlandOwner(fid)
                end
            end)
            if owner == farmId and self.soilSystem ~= nil then
                local info = nil
                pcall(function() info = self.soilSystem:getFieldInfo(fid) end)
                if info ~= nil and info.activeDisease ~= nil then
                    flagged[#flagged + 1] = {
                        fieldId = fid,
                        type = "crop",
                    }
                end
            end
        end
    end

    -- Ritter barn disease (read-only, pcall-wrapped, silent if absent).
    pcall(function()
        if g_diseaseManager == nil then return end
        if not g_modIsLoaded["FS25_RealisticLivestockRM"] then return end
        local ps = g_currentMission.placeableSystem
        if ps == nil or ps.placeables == nil then return end
        for _, p in ipairs(ps.placeables) do
            if p ~= nil and p.spec_husbandryAnimals ~= nil then
                local pOwner = nil
                if p.getOwnerFarmId ~= nil then pOwner = p:getOwnerFarmId() end
                if pOwner == farmId then
                    local cs = p.spec_husbandryAnimals.clusterSystem
                    if cs ~= nil and cs.getAnimals ~= nil then
                        local animals = cs:getAnimals() or {}
                        for _, animal in ipairs(animals) do
                            if animal.getDisease ~= nil then
                                local diseased = false
                                pcall(function()
                                    local titles = g_diseaseManager:getDiseaseTitles()
                                    for _, title in ipairs(titles or {}) do
                                        local d = animal:getDisease(title)
                                        if d ~= nil and d.active then
                                            diseased = true
                                        end
                                    end
                                end)
                                if diseased then
                                    local barnId = nil
                                    pcall(function() barnId = p:getUniqueId() end)
                                    flagged[#flagged + 1] = {
                                        fieldId = barnId or "barn",
                                        type = "livestock",
                                    }
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    self.warnings[farmId] = #flagged > 0 and flagged or nil
    self:_notify(farmId, flagged)
end

function DogEarlyWarning:_notify(farmId, flagged)
    if self.notifiedFields[farmId] == nil then
        self.notifiedFields[farmId] = {}
    end
    local notified = self.notifiedFields[farmId]

    for _, w in ipairs(flagged) do
        local key = tostring(w.fieldId) .. "_" .. w.type
        if not notified[key] then
            notified[key] = true
            local msg
            if w.type == "crop" then
                msg = DogEarlyWarning.formatWarning(DogEarlyWarning.FIELD_WARNING_KEY,
                    DogEarlyWarning.FIELD_WARNING_FALLBACK, w.fieldId)
            else
                msg = DogEarlyWarning.formatWarning(DogEarlyWarning.BARN_WARNING_KEY,
                    DogEarlyWarning.BARN_WARNING_FALLBACK, w.fieldId)
            end
            pcall(function()
                if g_currentMission ~= nil and g_currentMission.hud ~= nil
                        and g_currentMission.hud.showBlinkingWarning ~= nil then
                    g_currentMission.hud:showBlinkingWarning(msg, 5000)
                end
            end)
        end
    end

    local activeKeys = {}
    for _, w in ipairs(flagged) do
        activeKeys[tostring(w.fieldId) .. "_" .. w.type] = true
    end
    for key in pairs(notified) do
        if not activeKeys[key] then
            notified[key] = nil
        end
    end
end

function DogEarlyWarning:getWarnings(farmId)
    return self.warnings[farmId] or {}
end

function DogEarlyWarning:update(dt)
    self.lastScan = self.lastScan + dt
    if self.lastScan < DogEarlyWarning.CADENCE_MS then return end
    self.lastScan = 0

    pcall(function()
        local fm = g_farmManager
        if fm == nil or fm.getFarms == nil then return end
        for _, farm in pairs(fm:getFarms() or {}) do
            if farm ~= nil and farm.farmId ~= nil and farm.farmId > 0 then
                self:scan(farm.farmId)
            end
        end
    end)
end
