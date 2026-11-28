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
--   1. Once per in-game hour, sampleHour() adds WeatherGuard's current
--      temperature to the day's running average.
--   2. On each new day, closeDay() closes the day:
--        fewer than MIN_READINGS readings -> the day counts neither way
--        average <= FREEZE_TEMP_C         -> one more cold day, warm streak reset
--        average >  FREEZE_TEMP_C         -> one more warm day, cold streak reset
--      DAYS_TO_FREEZE cold days in a row freeze the ground;
--      DAYS_TO_THAW warm days in a row thaw it.
--
-- NEVER FROZEN WITHOUT A READING. isFrozen() is true only while the latest hourly
-- read returned a temperature. A frozen save loaded without WeatherGuard (or with
-- one that stops answering) therefore leaches as before straight away, instead of
-- staying frozen with no way to thaw. The saved state itself is kept, so a normal
-- reload in mid-winter is still frozen from the first frame: the first hourly read
-- happens before the first leach (see SoilFertilitySystem:onEnvironmentUpdate).
--
-- A skipped stretch (sleeping, a time jump) counts as ONE day, closed with the
-- readings taken before it: nothing leaches during skipped days anyway (the leach
-- runs per frame), and guessing their temperatures would be inventing weather.
--
-- Pure Lua apart from readTemperature() and the XML calls, so the state machine
-- tests without a game.
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
    self._lastReadOk  = false -- did the latest hourly read return a temperature?
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
--- A nil or NaN reading does not count, and leaves isFrozen() false until a
--- good reading arrives.
---@param hourKey number  any value unique to the in-game hour (day * 24 + hour)
---@param temp number|function|nil
---@return boolean added  true when the reading counted
function FrozenGround:sample(hourKey, temp)
    if hourKey == nil or hourKey == self._lastHourKey then return false end
    self._lastHourKey = hourKey
    local tempC = temp
    if type(temp) == "function" then tempC = temp() end
    if type(tempC) ~= "number" or tempC ~= tempC then
        self._lastReadOk = false
        return false
    end
    self._lastReadOk = true
    self._sum   = self._sum + tempC
    self._count = self._count + 1
    return true
end

--- The per-frame call: sample the current in-game hour from WeatherGuard.
---@param currentDay number
---@param env table|nil  the mission environment (for currentHour)
function FrozenGround:sampleHour(currentDay, env)
    local hour = (env ~= nil and env.currentHour) or 0
    self:sample((currentDay or 0) * 24 + hour, FrozenGround.readTemperature)
end

--- Close the day: fold its average into the streaks and update the state.
--- Returns the day's average, or nil when it had too few readings to count.
---@return number|nil average
function FrozenGround:onDayChanged()
    local c = cfg()
    local freezeAt    = c.FREEZE_TEMP_C  or 0.0
    local toFreeze    = c.DAYS_TO_FREEZE or 2
    local toThaw      = c.DAYS_TO_THAW   or 2
    local minReadings = c.MIN_READINGS   or 12

    local count = self._count
    local avg = nil
    if count > 0 and count >= minReadings then
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

--- The new-day call: close the day and log a freeze or a thaw.
function FrozenGround:closeDay()
    local was = self.frozen
    local avg = self:onDayChanged()
    if self.frozen ~= was and SoilLogger ~= nil then
        SoilLogger.info("Ground %s (day average %.1f C): leaching %s",
            self.frozen and "froze" or "thawed", avg or 0, self.frozen and "paused" or "resumed")
    end
end

--- True while the ground is frozen AND the latest hourly read had a temperature.
---@return boolean
function FrozenGround:isFrozen()
    return self.frozen == true and self._lastReadOk == true
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
    self._lastReadOk = false
end

--- Write the state as three attributes on the soil data root.
function FrozenGround:saveXML(xmlFile, key)
    local t = self:toTable()
    setXMLInt(xmlFile, key .. "#groundFrozen", t.frozen and 1 or 0)
    setXMLInt(xmlFile, key .. "#groundColdDays", t.coldDays)
    setXMLInt(xmlFile, key .. "#groundWarmDays", t.warmDays)
end

--- Read the state back (absent attributes = thawed, no streaks).
function FrozenGround:loadXML(xmlFile, key)
    self:fromTable({
        frozen   = (getXMLInt(xmlFile, key .. "#groundFrozen") or 0) == 1,
        coldDays = getXMLInt(xmlFile, key .. "#groundColdDays"),
        warmDays = getXMLInt(xmlFile, key .. "#groundWarmDays"),
    })
end

--- The soilStatus line.
---@param isServer boolean
---@return string
function FrozenGround:statusText(isServer)
    local c = cfg()
    local text
    if self.frozen and not self._lastReadOk then
        text = "frozen when last read, but no temperature now: leaching runs"
    elseif self.frozen then
        text = string.format("frozen, leaching paused (%d/%d warm days to thaw)", self.warmDays, c.DAYS_TO_THAW or 2)
    else
        text = string.format("thawed (%d/%d cold days to freeze)", self.coldDays, c.DAYS_TO_FREEZE or 2)
    end
    if not isServer then
        text = text .. " [this client's own reading; the server's soil values apply]"
    end
    return text
end
