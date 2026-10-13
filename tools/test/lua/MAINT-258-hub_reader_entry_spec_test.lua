-- MAINT-258-hub_reader_entry_spec_test.lua
--
-- MAINTENANCE row 258 (Soil's half): Soil passes SettingsHub a reader, so a change made in Soil's own settings
-- shows in the hub, the Tablet and the hub's broadcast.
--
-- THE DEFECT THIS PINS (development 0e7dbdf): Soil registers with SettingsHub as selfPersisted
-- (src/integrations/SoilSettingsHubBridge.lua:92-103), so the hub mirrors the values Soil registered with. Soil's
-- own settings path (SoilSettingsUI:requestSettingChange, src/settings/SoilSettingsUI.lua:74-95, into
-- SoilNetworkEvents_RequestSettingChange, src/network/NetworkEvents.lua:1654-1687, which on the host writes
-- g_SoilFertilityManager.settings and saves) never tells the hub, so the Tablet showed the stale value.
-- SettingsHub's row 258 PR lets a selfPersisted companion pass read(key); this passes one, reading the object
-- the hub's own onChange (applyChange) writes.
--
-- THE ENTRY-POINT BAR IS GROUP E. main.lua's own registration statement (its loadMission00Finished:
-- SoilSettingsHubBridge.register(sfm)) runs from main.lua's text, with the real bridge loaded. SettingsHub is
-- reachable only as the mission's handle and records the spec registerModule receives (the hub's own behaviour
-- is SettingsHub's bench). The settings are the real Settings object (Settings.new, schema defaults); its
-- manager is the file system, which counts saves. The change enters where a player makes it: Soil's own
-- settings UI, requestSettingChange, on the host, into SoilNetworkEvents_RequestSettingChange run from
-- NetworkEvents.lua's own text.
--
--   E0  the sites are present once; the registration is selfPersisted and carries a reader
--   E1  after Soil's own UI switches seasonal effects off (an admin key, through the network request), the
--       reader answers false, a boolean, while the value Soil registered is still true
--   E2  after it hides the HUD (a player-local key), the reader answers false, a boolean
--   E3  for every registered key the reader answers Soil's own value; an unknown key answers nil
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/utils/SoilUtils.lua, src/integrations/SoilSettingsHubBridge.lua
--!text: src/main.lua, src/network/NetworkEvents.lua, src/settings/SoilSettingsUI.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local function textOf(path) return ((SOURCE_TEXT and SOURCE_TEXT[path]) or ""):gsub("\r\n", "\n") end
local function countOf(text, needle)
  local n, from = 0, 1
  while true do
    local k = text:find(needle, from, true)
    if k == nil then return n end
    n, from = n + 1, k + 1
  end
end

local MAIN = textOf("src/main.lua")
local SITE = "    if SoilSettingsHubBridge then\n        SoilSettingsHubBridge.register(sfm)\n    end\n"

-- SoilNetworkEvents_RequestSettingChange, from NetworkEvents.lua's own text: the function to its closing `end`.
local NET = textOf("src/network/NetworkEvents.lua")
local FN_START = "function SoilNetworkEvents_RequestSettingChange(settingName, value)\n"
local fnText = nil
do
  local i = NET:find(FN_START, 1, true)
  if i ~= nil then
    local j = NET:find("\nend\n", i, true)
    if j ~= nil then fnText = NET:sub(i, j + 4) end
  end
end

-- The settings UI installs its menu hooks when the file loads (SoilSettingsUI.lua:224-241), so it runs from its own
-- text after the two engine tables it appends to exist: the engine's Utils.appendedFunction and the settings frame.
Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(orig, fn)
  return function(...) if orig ~= nil then orig(...) end return fn(...) end
end
InGameMenuSettingsFrame = InGameMenuSettingsFrame or {}
local UI_TEXT = textOf("src/settings/SoilSettingsUI.lua")
assert(UI_TEXT:find("function SoilSettingsUI:requestSettingChange", 1, true), "SoilSettingsUI.lua text missing")
assert(load(UI_TEXT, "=SoilSettingsUI.lua", "t", _ENV))()

-- The mission: the host, single player, with SettingsHub on it and nowhere else.
local SPEC = nil
-- The host broadcasts each change as Soil's own settings event (NetworkEvents.lua:1679-1683); the server records it.
local BROADCAST = {}
SoilSettingSyncEvent = SoilSettingSyncEvent or { new = function(id, value) return { id = id, value = value } end }
g_server, g_client = { broadcastEvent = function(_, ev) BROADCAST[#BROADCAST + 1] = ev end }, nil
g_currentMission.missionDynamicInfo = { isMultiplayer = false }
g_currentMission.settingsHub = { registerModule = function(_, modId, spec) if modId == "SoilFertilizer" then SPEC = spec end return true end }
g_settingsHub = nil

-- The settings' manager is the file system: it counts saves.
local SAVES = 0
-- Settings:save writes the server file and the player's local file (src/settings/Settings.lua:138-140).
local manager = { saveSettings = function() SAVES = SAVES + 1 end, saveLocalSettings = function() end,
                  loadSettings = function() end }
local sfm = { settings = Settings.new(manager) }
g_SoilFertilityManager = sfm

group("E", function()
  T.eq("E0 main.lua's registration site and NetworkEvents' request function are each present once",
    countOf(MAIN, SITE) .. "/" .. countOf(NET, FN_START) .. "/" .. tostring(fnText ~= nil), "1/1/true")
  assert(load(fnText, "=NetworkEvents.lua RequestSettingChange", "t", _ENV))()
  local site = load(SITE, "=main.lua site", "t", setmetatable({ sfm = sfm }, { __index = _ENV }))
  site()
  T.ok("E0 [reached] Soil registered with the mission's SettingsHub as selfPersisted, with a reader",
    SPEC ~= nil and SPEC.selfPersisted == true and type(SPEC.read) == "function")

  local registered = {}
  for _, def in ipairs(SPEC.adminSettings) do registered[def.id] = def.default end
  local ui = SoilSettingsUI.new(sfm.settings)

  local saves0 = SAVES
  -- seasonalEffects, not fertilizerCosts: the latter is simpleOnly, so Settings:save's bypass lock holds it at its
  -- default on the default difficulty (Settings.lua:73-88), and the reader rightly answers that.
  ui:requestSettingChange("seasonalEffects", false)
  T.ok("E1 [entry point] NAMED (row 258): after Soil's own UI switched seasonal effects off (through the network request, which saved and broadcast), the reader answers false, a boolean",
    SPEC.read("seasonalEffects") == false and SAVES > saves0 and #BROADCAST == 1,
    tostring(SPEC.read("seasonalEffects")) .. " (" .. type(SPEC.read("seasonalEffects")) .. "), saves " .. (SAVES - saves0) .. ", broadcasts " .. #BROADCAST)
  T.eq("E1 while the value Soil registered is still the old one (what the hub showed before)", registered.seasonalEffects, true)

  ui:requestSettingChange("showHUD", false)
  T.ok("E2 after it hides the HUD (a player-local key), the reader answers false, a boolean",
    SPEC.read("showHUD") == false, tostring(SPEC.read("showHUD")) .. " (" .. type(SPEC.read("showHUD")) .. ")")

  local all, mismatch = 0, {}
  for _, def in ipairs(SPEC.adminSettings) do
    all = all + 1
    if SPEC.read(def.id) ~= sfm.settings[def.id] then mismatch[#mismatch + 1] = def.id end
  end
  T.ok("E3 for every registered key the reader answers Soil's own value; an unknown key answers nil",
    all > 0 and #mismatch == 0 and SPEC.read("noSuchKey") == nil, all .. " keys, mismatched: " .. table.concat(mismatch, ","))
end)

g_server, g_SoilFertilityManager = nil, nil
