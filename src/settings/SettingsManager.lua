-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Settings Manager
-- =========================================================
-- Saves/loads mod settings from the server savegame XML.
-- Auto-generated from SettingsSchema - add settings there.
-- =========================================================
-- Author: TisonK
-- =========================================================
---@class SettingsManager
SettingsManager = {}
local SettingsManager_mt = Class(SettingsManager)

SettingsManager.MOD_NAME = g_currentModName or "FS25_SoilFertilizer"
SettingsManager.XMLTAG = "SoilFertilityManager"

-- Default config is now derived from schema
SettingsManager.defaultConfig = SettingsSchema.getAllDefaults()

function SettingsManager.new()
    return setmetatable({}, SettingsManager_mt)
end

-- Settings are saved to the server savegame directory so all players share the same config.
function SettingsManager:getSavegameXmlFilePath()
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        local path = string.format("%s/%s.xml",
            g_currentMission.missionInfo.savegameDirectory,
            SettingsManager.MOD_NAME)
        return path
    end

    SoilLogger.debug("Savegame directory not available yet (new career or early load)")
    return nil
end

function SettingsManager:loadSettings(settingsObject)
    local xmlPath = self:getSavegameXmlFilePath()

    if not xmlPath then
        SoilLogger.info("Cannot load settings - savegame path not available, using defaults")
        self:applyDefaults(settingsObject)
        return
    end

    if fileExists(xmlPath) then
        local xml = XMLFile.load("sf_Config", xmlPath)
        if xml then
            -- Auto-load all server-shared settings from schema (skip per-player localOnly settings)
            for _, def in ipairs(SettingsSchema.definitions) do
                if not def.localOnly then
                    local xmlKey = self.XMLTAG .. "." .. def.id
                    if def.type == "boolean" then
                        settingsObject[def.id] = xml:getBool(xmlKey, def.default)
                    elseif def.type == "number" then
                        settingsObject[def.id] = xml:getInt(xmlKey, def.default)
                    end
                end
            end

            xml:delete()
            SoilLogger.info("Settings loaded from server savegame: %s", xmlPath)
            return
        end
    end

    SoilLogger.debug("No saved settings found, using defaults")
    self:applyDefaults(settingsObject)
end

function SettingsManager:applyDefaults(settingsObject)
    for _, def in ipairs(SettingsSchema.definitions) do
        settingsObject[def.id] = def.default
    end
end

-- ── Local-only settings (per-player, not server-shared) ──────
-- Saved to the user profile directory so they survive reconnects on dedi servers.
-- Folder layout: modSettings/FS25_SoilFertilizer/{Settings,HUD,Debug}/

function SettingsManager.getModProfileDir()
    local ok, profilePath = pcall(getUserProfileAppPath)
    if ok and profilePath and profilePath ~= "" then
        if profilePath:sub(-1) ~= "/" and profilePath:sub(-1) ~= "\\" then
            profilePath = profilePath .. "/"
        end
        local base = profilePath .. "modSettings/" .. SettingsManager.MOD_NAME
        createFolder(profilePath .. "modSettings")
        createFolder(base)
        createFolder(base .. "/Settings")
        createFolder(base .. "/HUD")
        createFolder(base .. "/Debug")
        return base
    end
    return nil
end

function SettingsManager:getLocalSettingsPath()
    local base = SettingsManager.getModProfileDir()
    if base then
        return base .. "/Settings/local.xml"
    end
    -- Fallback: savegame dir with _local suffix (singleplayer / self-hosted)
    local xmlPath = self:getSavegameXmlFilePath()
    return xmlPath and xmlPath:gsub("%.xml$", "_local.xml") or nil
end

function SettingsManager:saveLocalSettings(settingsObject)
    local path = self:getLocalSettingsPath()
    if not path then
        SoilLogger.warning("saveLocalSettings: path unavailable (dedi server first boot, no savegame written yet)")
        return false
    end

    local xml = XMLFile.create("sf_LocalConfig", path, self.XMLTAG)
    if not xml then return false end

    for _, def in ipairs(SettingsSchema.definitions) do
        if def.localOnly then
            local xmlKey = self.XMLTAG .. "." .. def.id
            if def.type == "boolean" then
                xml:setBool(xmlKey, settingsObject[def.id])
            elseif def.type == "number" then
                -- Use setFloat for settings that carry fractional values (position, scale).
                -- A setting is treated as float when its default or bounds are non-integer.
                local isFloat = (def.default ~= math.floor(def.default))
                    or (def.min  and def.min  ~= math.floor(def.min))
                    or (def.max  and def.max  ~= math.floor(def.max))
                if isFloat then
                    xml:setFloat(xmlKey, settingsObject[def.id])
                else
                    xml:setInt(xmlKey, settingsObject[def.id])
                end
            end
        end
    end

    xml:save()
    xml:delete()
    SoilLogger.debug("Local settings saved: %s", path)
    return true
end

function SettingsManager:loadLocalSettings(settingsObject)
    local path = self:getLocalSettingsPath()
    if not path or not fileExists(path) then return end

    local xml = XMLFile.load("sf_LocalConfig", path)
    if not xml then return end

    for _, def in ipairs(SettingsSchema.definitions) do
        if def.localOnly then
            local xmlKey = self.XMLTAG .. "." .. def.id
            if def.type == "boolean" then
                settingsObject[def.id] = xml:getBool(xmlKey, settingsObject[def.id])
            elseif def.type == "number" then
                local isFloat = (def.default ~= math.floor(def.default))
                    or (def.min  and def.min  ~= math.floor(def.min))
                    or (def.max  and def.max  ~= math.floor(def.max))
                if isFloat then
                    settingsObject[def.id] = xml:getFloat(xmlKey, settingsObject[def.id])
                else
                    settingsObject[def.id] = xml:getInt(xmlKey, settingsObject[def.id])
                end
            end
        end
    end

    xml:delete()
    SoilLogger.info("Local settings loaded from: %s", path)
end

function SettingsManager:saveSettings(settingsObject)
    local xmlPath = self:getSavegameXmlFilePath()

    if not xmlPath then
        SoilLogger.error("Cannot save settings - savegame path not available")
        return false
    end

    -- Only server should save (or singleplayer)
    if g_client ~= nil and g_server == nil then
        SoilLogger.debug("Client skipping save (settings saved on server)")
        return false
    end

    local xml = XMLFile.create("sf_Config", xmlPath, self.XMLTAG)
    if xml then
        -- Auto-save server-shared settings from schema (skip per-player localOnly settings)
        for _, def in ipairs(SettingsSchema.definitions) do
            if not def.localOnly then
                local xmlKey = self.XMLTAG .. "." .. def.id
                if def.type == "boolean" then
                    xml:setBool(xmlKey, settingsObject[def.id])
                elseif def.type == "number" then
                    xml:setInt(xmlKey, settingsObject[def.id])
                end
            end
        end

        xml:save()
        xml:delete()

        SoilLogger.info("Settings saved to server savegame: %s", xmlPath)
        return true
    else
        SoilLogger.error("Failed to create settings XML file")
    end

    return false
end
