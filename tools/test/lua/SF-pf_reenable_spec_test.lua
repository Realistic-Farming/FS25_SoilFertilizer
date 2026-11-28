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
-- Explicit changes go through the REAL doors: SoilSettingChangeEvent:run (what SoilEnable,
-- SoilDisable and the menus reach on SP and a listen host, via the loopback connection)
-- and SoilNetworkEvents_RequestSettingChange's direct server branch (no g_client).
--
-- WHO POPULATES THE WORLD. The settings file is an in-memory XML store behind the real
-- SettingsManager load/save (XMLFile.create/load, fileExists: the three engine calls it
-- makes). The PF check is the real SoilFertilityManager:onMissionStarted on a stub
-- manager whose pfBridge answers PF present or absent; activateSoilSystem is recorded,
-- not run (it is the whole sim). Each "load" is a NEW Settings + manager, exactly as a
-- reload builds them, so nothing in memory can carry the flag across.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/SoilFertilityManager.lua, src/utils/SoilUtils.lua, src/network/NetworkEvents.lua, src/settings/SoilSettingsGUI.lua

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
local BROADCASTS = {}
local SERVER = { broadcastEvent = function(_, ev) BROADCASTS[#BROADCASTS + 1] = ev end }
-- The loopback connection is the server's own (Connection:getIsServer() true), so the
-- admin check is not the thing under test here. On SP / a listen host, a change request
-- goes out through g_client's server connection and comes back to the event's run.
local LOOPBACK = { getIsServer = function() return true end }
local CLIENT = { getServerConnection = function()
    return { sendEvent = function(_, ev) ev:run(LOOPBACK) end }
end }
g_server, g_client = SERVER, CLIENT      -- singleplayer / listen host: both present
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
    g_SoilFertilityManager = mgr
    return mgr, settings, function() return activated end
end

-- The doors a deliberate change takes.
local function viaEvent(id, value)
    SoilSettingChangeEvent.new(id, value):run(LOOPBACK)
end
local function viaHostDirect(id, value)
    local c = g_client
    g_client = nil
    SoilNetworkEvents_RequestSettingChange(id, value)
    g_client = c
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

-- ── P4: an explicit enable during the PF session wins and is saved; so does a later
-- explicit disable. A reset to defaults does not start the mod next to PF. ───────
group("P4", function()
    DISK = {}
    local _, s0 = loadGame(false); s0.enabled = false; saveGame(s0)
    local mgr1, s1 = loadGame(true)
    mgr1.soilSystem.isInitialized = true    -- the event's re-init branch is not under test
    viaEvent("enabled", true)               -- SoilEnable on SP / a listen host
    T.eq("P4a the explicit enable is live", s1.enabled, true)
    T.eq("P4b and reaches disk", onDisk(), true)
    T.eq("P4c and the force is dropped", s1:getForcedOffReason(), nil)
    viaEvent("enabled", false)              -- ...then SoilDisable, also on purpose
    saveGame(s1)
    T.eq("P4d a later explicit disable reaches disk too", onDisk(), false)

    -- The real reset door: SoilResetSettings (the panel's admin Reset calls the same).
    DISK = {}
    local _, s2a = loadGame(false); s2a.enabled = false; s2a.difficulty = 3; saveGame(s2a)
    local mgr2, s2 = loadGame(true)
    local inits = 0
    mgr2.soilSystem.isInitialized = true
    mgr2.soilSystem.initialize = function() inits = inits + 1 end
    local gui = setmetatable({}, { __index = SoilSettingsGUI })
    gui:consoleCommandResetSettings()
    T.eq("P4e a reset during a PF session keeps the mod off live", s2.enabled, false)
    T.eq("P4f and does not start the sim", inits, 0)
    T.eq("P4g the force stays", s2:getForcedOffReason(), "precisionFarming")
    T.eq("P4h every other setting did reset", s2.difficulty, SettingsSchema.byId.difficulty.default)
    saveGame(s2)
    T.eq("P4i the player's own choice (off) is still what is on disk", onDisk(), false)

    -- The reviewer's case: SoilDisable during PF (ends the force), THEN a reset. PF is
    -- still installed, so the reset must still leave on/off alone.
    DISK = {}
    local _, s5a = loadGame(false); saveGame(s5a)
    local mgr5, s5 = loadGame(true)
    local inits5 = 0
    mgr5.soilSystem.isInitialized = true
    mgr5.soilSystem.initialize = function() inits5 = inits5 + 1 end
    viaEvent("enabled", false)
    gui:consoleCommandResetSettings()
    T.eq("P4k SoilDisable then a reset during PF: still off live, sim not started", tostring(s5.enabled) .. "/" .. inits5, "false/0")
    saveGame(s5)
    T.eq("P4l and the player's explicit off is what is on disk", onDisk(), false)

    -- A pure-client admin's reset: the server's answer is not back yet when the console
    -- decides whether to re-initialize, so it must decide from what it sent.
    DISK = {}
    local _, s6a = loadGame(false); s6a.enabled = false; saveGame(s6a)
    local mgr6, s6 = loadGame(false)
    local inits6 = 0
    mgr6.soilSystem.isInitialized = true
    mgr6.soilSystem.initialize = function() inits6 = inits6 + 1 end
    local savedClient = g_client
    g_client = { getServerConnection = function() return { sendEvent = function() end } end }  -- request in flight
    gui:consoleCommandResetSettings()
    g_client = savedClient
    T.eq("P4m a client admin's reset re-initializes though its enabled is still false", tostring(s6.enabled) .. "/" .. inits6, "false/1")

    -- Without PF, the same reset still resets enabled and re-initializes, as before.
    DISK = {}
    local _, s3a = loadGame(false); s3a.enabled = false; saveGame(s3a)
    local mgr3, s3 = loadGame(false)
    local inits3 = 0
    mgr3.soilSystem.isInitialized = true
    mgr3.soilSystem.initialize = function() inits3 = inits3 + 1 end
    gui:consoleCommandResetSettings()
    T.eq("P4j without PF a reset turns the mod on and re-initializes", tostring(s3.enabled) .. "/" .. inits3, "true/1")
end)

-- ── P7: the reviewer's case. On, PF active, the player types SoilDisable meaning to keep
-- Soil off once PF is gone. The live value was already false; the choice must still land. ──
group("P7", function()
    for _, door in ipairs({ { "event", viaEvent }, { "host direct", viaHostDirect } }) do
        DISK = {}
        local _, s0 = loadGame(false); saveGame(s0)
        T.eq("P7 [" .. door[1] .. "] precondition: on, on disk", onDisk(), true)
        local _, s1 = loadGame(true)
        door[2]("enabled", false)
        saveGame(s1)
        T.eq("P7a [" .. door[1] .. "] the explicit disable reaches disk", onDisk(), false)
        local _, s2, act = loadGame(false)
        T.eq("P7b [" .. door[1] .. "] and the mod stays off after PF is removed", tostring(s2.enabled) .. "/" .. act(), "false/0")
    end
end)

-- ── P8: an unrelated admin change during a PF session does not end the force. ───
group("P8", function()
    DISK = {}
    local _, s0 = loadGame(false); saveGame(s0)
    local _, s1 = loadGame(true)
    viaEvent("difficulty", 3)
    T.eq("P8a the other setting is saved", DISK[PATH][SettingsManager.XMLTAG .. ".difficulty"], 3)
    T.eq("P8b enabled still saves the player's true", onDisk(), true)
    T.eq("P8c and the mod is still off live", s1.enabled, false)
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
    g_server = SERVER
end)

T.eq("no onMissionStarted error was logged", table.concat(ERRS, " | "), "")

XMLFile, fileExists, g_server, g_client = saved.XMLFile, saved.fileExists, saved.g_server, saved.g_client
g_currentMission.missionInfo, getUserProfileAppPath = saved.missionInfo, saved.profile
SoilVersionDialog, g_gameSettings = saved.SoilVersionDialog, saved.g_gameSettings
createFolder = savedCreateFolder
g_SoilFertilityManager = nil
