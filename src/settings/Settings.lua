-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Settings
-- =========================================================
-- Settings domain object - uses SettingsSchema for defaults/validation
-- =========================================================
-- Author: TisonK
-- =========================================================
---@class Settings

Settings = {}
local Settings_mt = Class(Settings)

Settings.DIFFICULTY_EASY = SoilConstants.DIFFICULTY.EASY
Settings.DIFFICULTY_NORMAL = SoilConstants.DIFFICULTY.NORMAL
Settings.DIFFICULTY_HARD = SoilConstants.DIFFICULTY.HARD

function Settings.new(manager)
    local self = setmetatable({}, Settings_mt)
    self.manager = manager

    self:resetToDefaults(false)

    SoilLogger.info("Initialized")

    return self
end

---@param difficulty number
function Settings:setDifficulty(difficulty)
    if difficulty >= Settings.DIFFICULTY_EASY and difficulty <= Settings.DIFFICULTY_HARD then
        self.difficulty = difficulty

        local difficultyName = "Normal"
        if difficulty == Settings.DIFFICULTY_EASY then
            difficultyName = "Simple"
        elseif difficulty == Settings.DIFFICULTY_HARD then
            difficultyName = "Hardcore"
        end

        SoilLogger.debug("Difficulty set to: %s", difficultyName)
    end
end

---@return string
function Settings:getDifficultyName()
    if self.difficulty == Settings.DIFFICULTY_EASY then
        return "Simple"
    elseif self.difficulty == Settings.DIFFICULTY_HARD then
        return "Hardcore"
    else
        return "Realistic"
    end
end

function Settings:load()
    if type(self.difficulty) ~= "number" then
        SoilLogger.warning("Difficulty is not a number! Type: %s, Value: %s",
            type(self.difficulty), tostring(self.difficulty))
        self.difficulty = Settings.DIFFICULTY_NORMAL
    end

    self.manager:loadSettings(self)
    -- Local-only settings (HUD position, transparency, etc.) are stored per-player
    -- in the user profile dir and loaded on top of server settings so they always win.
    self.manager:loadLocalSettings(self)

    self:validateSettings()

    SoilLogger.info("Settings loaded. Enabled: %s, Difficulty: %s",
        tostring(self.enabled), self:getDifficultyName())
end

function Settings:validateSettings()
    -- Validate all settings against schema
    for _, def in ipairs(SettingsSchema.definitions) do
        self[def.id] = SettingsSchema.validate(def.id, self[def.id])
    end
end

function Settings:save()
    if type(self.difficulty) ~= "number" then
        SoilLogger.warning("Difficulty is not a number! Type: %s, Value: %s",
            type(self.difficulty), tostring(self.difficulty))
        self.difficulty = Settings.DIFFICULTY_NORMAL
    end

    self.manager:saveSettings(self)
    -- Always save local-only settings (HUD appearance) regardless of server/client role.
    self.manager:saveLocalSettings(self)
end

---@param saveImmediately boolean
function Settings:resetToDefaults(saveImmediately)
    saveImmediately = saveImmediately ~= false

    -- Reset all settings from schema defaults
    for _, def in ipairs(SettingsSchema.definitions) do
        self[def.id] = def.default
    end

    if saveImmediately then
        self:save()
        SoilLogger.info("Settings reset to defaults")
    end
end
