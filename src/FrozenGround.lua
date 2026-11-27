-- =========================================================
-- FS25 Soil & Fertilizer - FROZEN GROUND (#1177)
-- =========================================================
-- Is the ground frozen right now? One answer for the whole map.
--
-- While it is, SoilFertilitySystem:applyRainEffects skips nutrient leaching and
-- rain acidification: ice in the soil blocks water from soaking in, so it runs off
-- instead of carrying nutrients down.
--
-- How the state moves:
--   1. Once per in-game hour, sample(hourKey, temperature) adds WeatherGuard's
--      current temperature to the day's running average.
--   2. On each new day, onDayChanged() closes the day:
--        average <= FREEZE_TEMP_C  -> one more cold day,  warm streak reset
--        average >  FREEZE_TEMP_C  -> one more warm day,  cold streak reset
--        no readings at all        -> the day does not count either way
--      DAYS_TO_FREEZE cold days in a row freeze the ground;
--      DAYS_TO_THAW warm days in a row thaw it.
--
-- A skipped stretch (sleeping, a time jump) counts as ONE observed day, not as
-- many: nothing leaches during skipped days anyway (the leach runs per frame), and
-- guessing their temperatures would be inventing weather.
--
-- Missing inputs never freeze the ground: no WeatherGuard, no temperature, or no
-- readings for a day all leave the state where it is, and a new save starts
-- thawed. Unknown weather is not frozen weather.
--
-- Pure Lua: the temperature read is the only engine-facing call, and it is
-- injected into sample() by the caller, so the state machine tests without a game.
-- =========================================================

FrozenGround = FrozenGround or {}
local FrozenGround_mt = { __index = FrozenGround }

local function cfg()
    return (SoilConstants and SoilConstants.FROZEN_GROUND) or {}
end

--- A new tracker: thawed, no streaks, no readings yet.
---@return table
function FrozenGround.new()
    local self = setmetatable({}, FrozenGround_mt)
    self.frozen   = false
    self.coldDays = 0       -- cold days in a row (counts towards freezing)
    self.warmDays = 0       -- warm days in a row (counts towards thawing)
    self._sum     = 0       -- today's temperature readings, summed
    self._count   = 0       -- today's temperature readings, counted
    self._lastHourKey = nil -- the hour already sampled, so each hour counts once
    return self
end

--- The current temperature from WeatherGuard, or nil when it cannot say.
--- Same route as SoilFertilitySystem's spray-scorch read (readSprayTemperature).
---@return number|nil
function FrozenGround.readTemperature()
    local wg = g_currentMission ~= nil and g_currentMission.weatherGuard or nil
    if wg == nil or type(wg.getCurrentSky) ~= "function" then return nil end
    local ok, sky = pcall(wg.getCurrentSky, wg)
    if not ok or type(sky) ~= "table" then return nil end
    local t = sky.temperature
    if type(t) ~= "number" or t ~= t then return nil end   -- t ~= t rejects NaN
    return t
end

--- Add one reading for the hour `hourKey`. A second call for the same hour is
--- ignored, so calling this every frame still gives one reading per hour.
--- `temp` is a number, or a function returning one; a function is only called
--- when the hour is new, so a per-frame caller pays for one read an hour.
--- A nil temperature is skipped (the hour is still marked as seen).
---@param hourKey number  any value unique to the in-game hour (day * 24 + hour)
---@param temp number|function|nil
---@return boolean added  true when the reading counted
function FrozenGround:sample(hourKey, temp)
    if hourKey == nil or hourKey == self._lastHourKey then return false end
    self._lastHourKey = hourKey
    local tempC = temp
    if type(temp) == "function" then tempC = temp() end
    if type(tempC) ~= "number" or tempC ~= tempC then return false end
    self._sum   = self._sum + tempC
    self._count = self._count + 1
    return true
end

--- Close the day: fold its average into the streaks and update the state.
--- Returns the day's average (nil when it had no readings).
---@return number|nil average
function FrozenGround:onDayChanged()
    local c = cfg()
    local freezeAt   = c.FREEZE_TEMP_C  or 0.0
    local toFreeze   = c.DAYS_TO_FREEZE or 2
    local toThaw     = c.DAYS_TO_THAW   or 2

    local count = self._count
    local avg = nil
    if count > 0 then
        avg = self._sum / count
        if avg <= freezeAt then
            self.coldDays = self.coldDays + 1
            self.warmDays = 0
        else
            self.warmDays = self.warmDays + 1
            self.coldDays = 0
        end
        if not self.frozen and self.coldDays >= toFreeze then
            self.frozen = true
        elseif self.frozen and self.warmDays >= toThaw then
            self.frozen = false
        end
    end
    self._sum, self._count = 0, 0
    return avg
end

---@return boolean
function FrozenGround:isFrozen()
    return self.frozen == true
end

--- Plain values for saving (XML attributes or the StateLedger table).
--- Today's partial readings are not saved: a reload starts the day's average over.
---@return table { frozen = boolean, coldDays = number, warmDays = number }
function FrozenGround:toTable()
    return { frozen = self.frozen == true, coldDays = self.coldDays, warmDays = self.warmDays }
end

--- Restore from toTable() output. Missing or bad values fall back to thawed with
--- no streaks, which is how a save from before #1177 loads.
---@param t table|nil
function FrozenGround:fromTable(t)
    if type(t) ~= "table" then t = {} end
    self.frozen   = t.frozen == true
    local cd, wd = tonumber(t.coldDays), tonumber(t.warmDays)
    self.coldDays = (cd ~= nil and cd >= 0) and math.floor(cd) or 0
    self.warmDays = (wd ~= nil and wd >= 0) and math.floor(wd) or 0
    self._sum, self._count, self._lastHourKey = 0, 0, nil
end
