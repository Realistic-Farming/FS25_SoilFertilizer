-- SF-pf_reenable_spec_test.lua: Precision Farming turns Soil off for the SESSION, not the save.
--
-- THE BUG. With PF active, onMissionStarted set settings.enabled = false and
-- _disabledByPF = true. Every save then wrote enabled=false to FS25_SoilFertilizer.xml
-- (the save hook in main.lua writes settings on every game save). _disabledByPF lived
-- only on that manager instance, so after the player removed PF the next load's fresh
-- manager read enabled=false from disk, found _disabledByPF nil, and never re-enabled:
-- the mod stayed off in that save for good, with no message.
--
-- THE RULE. Settings:forceOffForSession turns the mod off live but keeps the player's own
-- choice on disk; SettingsManager:saveSettings writes Settings:getPersistedValue. If
-- anything turns the mod back ON in the session, that explicit choice wins and is saved.
--
-- WHO POPULATES THE WORLD. The settings file is an in-memory XML store behind the real
-- SettingsManager load/save (XMLFile.create/load, fileExists: the three engine calls it
-- makes). The PF check is the real SoilFertilityManager:onMissionStarted on a stub
-- manager whose pfBridge answers PF present or absent; activateSoilSystem is recorded,
-- not run (it is the whole sim). Each "load" is a NEW Settings + manager, exactly as a
-- reload builds them, so nothing in memory can carry the flag across.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/SoilFertilityManager.lua

SoilLogger.info = function() end
SoilLogger.debug = function() end
local ERRS = {}
SoilLogger.error = function(fmt, ...) ERRS[#ERRS + 1] = string.format(fmt, ...) end
SoilLogger.warning = function() end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── the engine's XML file API, in memory ────────────────────────────────────
local DISK = {}
local saved = { XMLFile = XMLFile, fileExists = fileExists, g_server = g_server, g_client = g_client,
                missionInfo = g_currentMission.missionInfo, profile = getUserProfileAppPath,
                SoilVersionDialog = SoilVersionDialog, g_gameSettings = g_gameSettings }
local function xmlHandle(path, existing)
    local data = existing or {}
    return {
        getBool = function(_, k, d) local v = data[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = data[k]; if v == nil then return d end return v end,
        getFloat = function(_, k, d) local v = data[k]; if v == nil then return d end return v end,
        setBool = function(_, k, v) data[k] = v end,
        setInt = function(_, k, v) data[k] = v end,
        setFloat = function(_, k, v) data[k] = v end,
        save = function() DISK[path] = data end,
        delete = function() end,
    }
end
XMLFile = {
    create = function(_, path) return xmlHandle(path, {}) end,
    load = function(_, path)
        if DISK[path] == nil then return nil end
        local copy = {}
        for k, v in pairs(DISK[path]) do copy[k] = v end
        return xmlHandle(path, copy)
    end,
}
fileExists = function(path) return DISK[path] ~= nil end
getUserProfileAppPath = function() return "/profile/" end
local savedCreateFolder = createFolder
createFolder = function() end
g_currentMission.missionInfo = { savegameDirectory = "/saves/savegame1" }
g_server, g_client = true, true          -- singleplayer / listen host: both present
SoilVersionDialog, g_gameSettings = nil, nil

local PATH = "/saves/savegame1/" .. SettingsManager.MOD_NAME .. ".xml"
local KEY = SettingsManager.XMLTAG .. ".enabled"
local function onDisk() return DISK[PATH] and DISK[PATH][KEY] end

-- One game load: a NEW Settings and manager, onMissionStarted with PF present or not.
local function loadGame(pfPresent)
    local settings = Settings.new(SettingsManager.new())
    settings:load()
    local activated = 0
    local mgr = setmetatable({
        settings = settings, disableGUI = true,
        soilSystem = {},
        pfBridge = { initialize = function() return pfPresent end },
    }, { __index = SoilFertilityManager })
    mgr.activateSoilSystem = function() activated = activated + 1 end
    mgr:onMissionStarted()
    return mgr, settings, function() return activated end
end
-- The game's save: main.lua's FSCareerMissionInfo.saveToXMLFile hook calls settings:save().
local function saveGame(settings) settings:save() end

-- ── P1: the reported case. On -> PF installed, play, save -> PF removed -> on again. ──
group("P1", function()
    DISK = {}
    local _, s0 = loadGame(false)
    saveGame(s0)
    T.eq("P1a a normal save stores enabled=true", onDisk(), true)

    local mgr, s1, act1 = loadGame(true)
    T.eq("P1b with PF the mod is off live", s1.enabled, false)
    T.eq("P1c and the sim is not started", act1(), 0)
    T.eq("P1d the PF flag is still set for the UI", mgr._disabledByPF, true)
    saveGame(s1)
    saveGame(s1)
    T.eq("P1e saving while PF forces it off keeps the player's true on disk", onDisk(), true)

    local _, s2, act2 = loadGame(false)
    T.eq("P1f after PF is removed the next load is on", s2.enabled, true)
    T.eq("P1g and the sim starts", act2(), 1)
end)

-- ── P2: a player who had the mod OFF keeps it off after PF goes. ─────────────────
group("P2", function()
    DISK = {}
    local _, s0 = loadGame(false)
    s0.enabled = false
    saveGame(s0)
    local _, s1 = loadGame(true)
    saveGame(s1)
    T.eq("P2a PF session keeps the player's false", onDisk(), false)
    local _, s2, act = loadGame(false)
    T.eq("P2b without PF it is still off (the player's choice)", tostring(s2.enabled) .. "/" .. act(), "false/0")
end)

-- ── P3: PF stays installed across several loads: off every time, true stays on disk. ──
group("P3", function()
    DISK = {}
    local _, s0 = loadGame(false); saveGame(s0)
    for i = 1, 3 do
        local _, s = loadGame(true)
        T.eq("P3 load " .. i .. " with PF: off live", s.enabled, false)
        saveGame(s)
        T.eq("P3 load " .. i .. " with PF: true on disk", onDisk(), true)
    end
end)

-- ── P4: an explicit enable during the PF session wins and is saved. ────────────
-- (SoilEnable, the settings menu, SettingsHub and a reset all assign enabled = true and
-- then call save(); a reset to defaults does exactly that through resetToDefaults.)
group("P4", function()
    DISK = {}
    local _, s0 = loadGame(false); s0.enabled = false; saveGame(s0)
    local _, s1 = loadGame(true)
    s1.enabled = true            -- the player turned it on on purpose
    saveGame(s1)
    T.eq("P4a the explicit enable reaches disk", onDisk(), true)
    T.eq("P4b and the force is dropped", s1:getForcedOffReason(), nil)
    s1.enabled = false           -- ...and then off again, also on purpose
    saveGame(s1)
    T.eq("P4c a later explicit disable reaches disk too", onDisk(), false)

    local _, s2 = loadGame(true)
    s2:resetToDefaults(true)
    T.eq("P4d a reset to defaults during a PF session saves the default", onDisk(), true)
end)

-- ── P5: forcing twice remembers the FIRST choice, and other settings save live. ──
group("P5", function()
    DISK = {}
    local s = Settings.new(SettingsManager.new())
    s.enabled = true
    s:forceOffForSession("precisionFarming")
    s:forceOffForSession("again")
    T.eq("P5a a second force does not overwrite the remembered true", s:getPersistedValue("enabled"), true)
    T.eq("P5b the reason is readable", s:getForcedOffReason(), "again")
    s.difficulty = 3
    s:save()
    T.eq("P5c other settings save their live value", DISK[PATH][SettingsManager.XMLTAG .. ".difficulty"], 3)
    T.eq("P5d enabled saves the remembered choice", onDisk(), true)
    T.eq("P5e an unforced Settings persists its live value",
         Settings.new(SettingsManager.new()):getPersistedValue("enabled"), true)
end)

-- ── P6: a pure MP client never writes the server's settings file. ──────────────
group("P6", function()
    DISK = {}
    g_server = nil
    local s = Settings.new(SettingsManager.new())
    s:forceOffForSession("precisionFarming")
    s:save()
    T.eq("P6 a client's save writes nothing", onDisk(), nil)
    g_server = true
end)

T.eq("no onMissionStarted error was logged", table.concat(ERRS, " | "), "")

XMLFile, fileExists, g_server, g_client = saved.XMLFile, saved.fileExists, saved.g_server, saved.g_client
g_currentMission.missionInfo, getUserProfileAppPath = saved.missionInfo, saved.profile
SoilVersionDialog, g_gameSettings = saved.SoilVersionDialog, saved.g_gameSettings
createFolder = savedCreateFolder
