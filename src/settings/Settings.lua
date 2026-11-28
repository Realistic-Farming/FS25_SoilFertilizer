-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Settings
-- =========================================================
-- Settings domain object - uses SettingsSchema for defaults/validation
-- =========================================================
-- Author: TisonK
-- =========================================================
---@class Settings

Settings = Settings or {}
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

--- Single gate for player-facing "bypass" tools - editors that let a player rescale
--- or override the simulation (Crop Tuning Editor, Constants Tuning Editor). These are
--- allowed on Simple difficulty ONLY. On Realistic and Hardcore the simulation is meant
--- to be lived with, not tuned around, so these tools are hidden/refused. Keep every
--- bypass feature routed through THIS one predicate so the policy lives in a single
--- place rather than being re-derived per panel.
---@return boolean
function Settings:allowsBypassTools()
    return self.difficulty == Settings.DIFFICULTY_EASY
end

--- Force every "simpleOnly" (soften) setting back to its schema default when the current
--- difficulty does not allow bypass tools. Closes the loophole where a toggle eased on
--- Simple would carry its softened value into Realistic/Hardcore: greying only DISABLES
--- the control, this makes the stored value itself honest. Deterministic (schema defaults
--- are identical on every peer) so server and clients converge with no extra broadcasts.
--- Mutates fields directly and never calls save() (avoids recursion - save() calls this).
---@return boolean changed  true if any value was corrected
function Settings:enforceBypassLock()
    if self:allowsBypassTools() then return false end
    if not (SettingsSchema and SettingsSchema.definitions) then return false end
    local changed = false
    for _, def in ipairs(SettingsSchema.definitions) do
        if def.simpleOnly and self[def.id] ~= def.default then
            self[def.id] = def.default
            changed = true
        end
    end
    if changed then
        SoilLogger.info("Bypass lock: soften settings forced to defaults on %s difficulty",
            self:getDifficultyName())
    end
    return changed
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
    -- Correct any softened values a save may carry on Realistic/Hardcore (e.g. a save
    -- that was on Simple then switched, or a hand-edited settings file).
    self:enforceBypassLock()

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

    -- Every server/SP setting change funnels through save(); enforce the bypass lock here
    -- so a difficulty change to Realistic/Hardcore forces soften toggles before persisting.
    self:enforceBypassLock()

    self.manager:saveSettings(self)
    -- Always save local-only settings (HUD appearance) regardless of server/client role.
    self.manager:saveLocalSettings(self)
end

--- Turn the mod off for THIS SESSION ONLY, for a reason the mod detected itself (today:
--- Precision Farming is active). The player's own on/off choice is what keeps reaching
--- the settings file, so the next load decides afresh: with PF gone, a mod the player had
--- on comes back on by itself. Before this, the forced `false` was written by the very
--- next save, and the "re-enable once PF is gone" check could never fire on a later load
--- because the flag that remembered WHO turned it off lived only in memory.
--- Calling it again keeps the choice remembered the first time.
---@param reason string|nil
function Settings:forceOffForSession(reason)
    if self._forcedOffReason == nil then
        self._enabledOnDisk = (self.enabled == true)
    end
    self._forcedOffReason = tostring(reason or "forced")
    self.enabled = false
end

---@return string|nil reason the mod is forced off this session, or nil
function Settings:getForcedOffReason()
    return self._forcedOffReason
end

--- The value SettingsManager:saveSettings writes for a server-shared setting. Only
--- `enabled` while forced off differs from the live value: the player's remembered
--- choice is written instead of the forced `false`. If something turned the mod back ON
--- this session (SoilEnable, the settings menu, SettingsHub, a reset to defaults), that
--- explicit choice wins: the force is dropped and the live value is written.
---@param id string
---@return any
function Settings:getPersistedValue(id)
    if id == "enabled" and self._forcedOffReason ~= nil then
        if self.enabled ~= false then
            self._forcedOffReason, self._enabledOnDisk = nil, nil
            return self.enabled
        end
        return self._enabledOnDisk
    end
    return self[id]
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
