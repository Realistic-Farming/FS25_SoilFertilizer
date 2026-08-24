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
                msg = string.format("Your dog senses something wrong with Field #%s.",
                    tostring(w.fieldId))
            else
                msg = string.format("Your dog senses something wrong at Barn %s.",
                    tostring(w.fieldId))
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
