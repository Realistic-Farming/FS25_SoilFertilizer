-- SF-hud_init_keeps_sim_spec_test.lua: a HUD/panel that fails to initialize no longer turns the mod off.
--
-- THE BUG. onMissionLoaded initialized the HUD and seven panels inside ONE pcall. If any
-- of them raised (often a conflict with another mod's HUD), the catch set
-- settings.enabled = false and called settings:save(). The whole soil simulation was then
-- off in that savegame for good, with only a log line to say why, and every panel after
-- the one that raised was skipped too.
--
-- THE RULE. Each part initializes on its own; settings.enabled is not touched and nothing
-- is saved. A PANEL that raises is retired for the session: its delete runs guarded and its
-- field on the manager is cleared (every caller checks it for nil). The soilHUD that raises
-- is KEPT uninitialized: it is also the field-detection / sprayer-cache service and input
-- anchor, so only its drawing stops (draw, onMouseEvent and enterEditMode check
-- `initialized`). Two loops that walked panel fields with ipairs stopped at a retired
-- panel's nil hole; they are covered here too (H7, H8), as is the drag key (H9).
--
-- WHO POPULATES THE WORLD. The parts are recording stubs on a stub manager driven through
-- the real SoilFertilityManager:onMissionLoaded; settings is a stub whose save() counts.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/utils/SoilUtils.lua, src/SoilFertilityManager.lua, src/ui/SoilHUD.lua, src/integrations/SoilMasterHUDBridge.lua

SoilLogger.info = function() end
SoilLogger.debug = function() end
local ERRS, WARNS = {}, {}
SoilLogger.error = function(fmt, ...) ERRS[#ERRS + 1] = string.format(fmt, ...) end
SoilLogger.warning = function(fmt, ...) WARNS[#WARNS + 1] = string.format(fmt, ...) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- The eight parts onMissionLoaded has always initialized, in its order (stated here, not
-- read from the code under test, so a part dropped from the list is caught).
local ORDER = { "soilHUD", "settingsPanel", "tuningPanel", "cropTuningPanel",
                "variableRatePanel", "smartSensorPanel", "sprayerInfoPanel", "harvesterPanel" }
T.eq("H0 the code initializes exactly these parts, in this order",
     table.concat(SoilFertilityManager.GUI_INIT_ORDER or {}, ","), table.concat(ORDER, ","))

-- A manager with every GUI part; `failing` maps key -> "init" | "both" (init and delete raise).
local function newMgr(failing, enabled)
    failing = failing or {}
    local log = { init = {}, delete = {} }
    local saves = 0
    local mgr = setmetatable({
        settings = { enabled = enabled ~= false, save = function() saves = saves + 1 end },
    }, { __index = SoilFertilityManager })
    for _, key in ipairs(ORDER) do
        mgr[key] = {
            initialize = function(self)
                log.init[#log.init + 1] = key
                if failing[key] then error(key .. " exploded") end
                self.initialized = true
            end,
            delete = function()
                log.delete[#log.delete + 1] = key
                if failing[key] == "both" then error(key .. " delete exploded") end
            end,
        }
    end
    return mgr, log, function() return saves end
end

local function present(mgr)
    local out = {}
    for _, key in ipairs(ORDER) do if mgr[key] ~= nil then out[#out + 1] = key end end
    return table.concat(out, ",")
end
local function allBut(skip)
    local out = {}
    for _, key in ipairs(ORDER) do if key ~= skip then out[#out + 1] = key end end
    return table.concat(out, ",")
end

-- ── H1: the HUD (first in order) raises: it is kept, uninitialized; the rest start. ──
group("H1", function()
    ERRS = {}
    local mgr, log, saves = newMgr({ soilHUD = "init" })
    local hud = mgr.soilHUD
    local ok = pcall(mgr.onMissionLoaded, mgr)
    T.ok("H1a onMissionLoaded does not raise", ok)
    T.eq("H1b the mod stays enabled", mgr.settings.enabled, true)
    T.eq("H1c and nothing is saved", saves(), 0)
    T.ok("H1d the HUD object is kept (field detection, auto-rate, input anchor)", mgr.soilHUD == hud)
    T.eq("H1e but stays uninitialized, so it draws nothing", hud.initialized, nil)
    T.eq("H1f it is not deleted", #log.delete, 0)
    T.eq("H1g every panel after it still initialized", #log.init, #ORDER)
    T.eq("H1h every panel is present", present(mgr), allBut(nil))
    T.ok("H1i the error says the monitor is hidden and the sim runs",
         #ERRS == 1 and ERRS[1]:find("Soil Monitor", 1, true) ~= nil)
end)

-- ── H2: a panel in the middle raises: those after it still initialize. ───────────
group("H2", function()
    local mgr, log = newMgr({ smartSensorPanel = "init" })
    mgr:onMissionLoaded()
    T.eq("H2a only the smart sensor panel is retired", present(mgr), allBut("smartSensorPanel"))
    T.eq("H2b the harvester panel (last) still initialized", mgr.harvesterPanel.initialized, true)
    T.eq("H2c every part was tried once", #log.init, #ORDER)
end)

-- ── H3: init AND delete raise: still retired, still contained. ───────────────────
group("H3", function()
    WARNS = {}
    local mgr = newMgr({ variableRatePanel = "both", harvesterPanel = "init" })
    local ok = pcall(mgr.onMissionLoaded, mgr)
    T.ok("H3a a raising delete does not escape", ok)
    T.eq("H3b both failing parts are cleared", tostring(mgr.variableRatePanel) .. "/" .. tostring(mgr.harvesterPanel), "nil/nil")
    T.ok("H3c the failed cleanup is logged", #WARNS == 1 and WARNS[1]:find("variableRatePanel", 1, true) ~= nil)
    T.eq("H3d the mod stays enabled", mgr.settings.enabled, true)
end)

-- ── H4: every part fails: the sim is still on. ───────────────────────────────────
group("H4", function()
    local all = {}
    for _, key in ipairs(ORDER) do all[key] = "init" end
    local mgr, _, saves = newMgr(all)
    mgr:onMissionLoaded()
    T.eq("H4a the vehicle panels are retired; the HUD service and the three menu panels are kept", present(mgr), "soilHUD,settingsPanel,tuningPanel,cropTuningPanel")
    T.eq("H4b the mod is still enabled and nothing saved", tostring(mgr.settings.enabled) .. "/" .. saves(), "true/0")
end)

-- ── H5: the clean path is unchanged. ─────────────────────────────────────────────
group("H5", function()
    ERRS = {}
    local mgr, log = newMgr({})
    mgr:onMissionLoaded()
    T.eq("H5a all parts present", present(mgr), allBut(nil))
    T.eq("H5b each initialized once, in order", table.concat(log.init, ","), table.concat(ORDER, ","))
    T.eq("H5c nothing deleted, nothing logged", #log.delete .. "/" .. #ERRS, "0/0")
end)

-- ── H6: disabled mod initializes nothing (unchanged); absent parts are skipped. ──
group("H6", function()
    local mgr, log = newMgr({}, false)
    mgr:onMissionLoaded()
    T.eq("H6a a disabled mod initializes no GUI part", #log.init, 0)

    local m2, log2 = newMgr({})
    m2.soilHUD, m2.tuningPanel = nil, nil          -- dedicated server / module not loaded
    m2.smartSensorPanel = { delete = function() end } -- a part with no initialize
    local ok = pcall(m2.onMissionLoaded, m2)
    T.ok("H6b absent parts do not raise", ok)
    T.eq("H6c the others still initialize", #log2.init, #ORDER - 3)
    T.ok("H6d a part with no initialize is kept, not retired", m2.smartSensorPanel ~= nil)
end)

-- ── H7: MasterHUD's fullscreen check sees an open panel AFTER a retired one. ────
group("H7", function()
    local saveSfm = g_SoilFertilityManager
    local open = { isOpen = function() return true end }
    local closed = { isOpen = function() return false end }
    g_SoilFertilityManager = { settingsPanel = closed, tuningPanel = nil, cropTuningPanel = open }
    T.eq("H7a crop tuning open, tuning panel retired: fullscreen", SoilMasterHUDBridge.isFullscreen(), true)
    g_SoilFertilityManager = { settingsPanel = nil, tuningPanel = nil, cropTuningPanel = nil }
    T.eq("H7b nothing present: not fullscreen", SoilMasterHUDBridge.isFullscreen(), false)
    g_SoilFertilityManager = saveSfm
end)

-- ── H8: the monitor yields a click to the sprayer panel even with the harvester retired. ──
group("H8", function()
    local saveSfm, saveInput = g_SoilFertilityManager, Input
    Input = Input or {}
    Input.MOUSE_BUTTON_LEFT, Input.MOUSE_BUTTON_RIGHT = Input.MOUSE_BUTTON_LEFT or 1, Input.MOUSE_BUTTON_RIGHT or 3
    local sprayer = { editMode = true, _lastPanelX = 0.4, _lastPanelY = 0.4, _lastPanelW = 0.2, _lastPanelH = 0.2 }
    g_SoilFertilityManager = { harvesterPanel = nil, sprayerInfoPanel = sprayer }
    local hud = setmetatable({ initialized = true, editMode = true, visible = true, _dragDiagLogged = true,
                               settings = { enabled = true, showHUD = true } }, { __index = SoilHUD })
    local ok, used = pcall(hud.onMouseEvent, hud, 0.5, 0.5, true, false, Input.MOUSE_BUTTON_LEFT, false)
    T.ok("H8a the click inside the sprayer panel is handled without error", ok)
    T.eq("H8b and is yielded to it (not claimed by the monitor)", used, false)
    T.ok("H8c the monitor did not start a drag", not hud.dragging)
    g_SoilFertilityManager, Input = saveSfm, saveInput
end)

-- ── H9: an uninitialized monitor never enters edit mode; the drag key does nothing. ──
group("H9", function()
    local hud = setmetatable({ initialized = nil, visible = true }, { __index = SoilHUD })
    hud:enterEditMode()
    T.ok("H9a enterEditMode on an uninitialized HUD is a no-op", not hud.editMode)
    local live = setmetatable({ initialized = true, visible = true }, { __index = SoilHUD })
    live:enterEditMode()
    T.eq("H9b an initialized HUD still enters edit mode", live.editMode, true)

    local entered = 0
    local panel = { enterEditMode = function() entered = entered + 1 end, exitEditMode = function() end }
    local mgr = setmetatable({ soilHUD = hud, sprayerInfoPanel = panel, harvesterPanel = panel,
                               settings = { enabled = true, showHUD = true } }, { __index = SoilFertilityManager })
    local saveMH = g_masterHUD; g_masterHUD = nil
    local cm = g_currentMission and g_currentMission.masterHUD
    if g_currentMission then g_currentMission.masterHUD = nil end
    mgr:onHUDDragInput()
    mgr:onHUDDragInput()
    T.eq("H9c the drag key leaves the sub-panels alone when the monitor is uninitialized", entered, 0)
    g_masterHUD = saveMH
    if g_currentMission then g_currentMission.masterHUD = cm end
end)

-- ── H10: a failed menu panel (settings, tuning, crop tuning) is kept: open() retries. ──
group("H10", function()
    for _, key in ipairs({ "settingsPanel", "tuningPanel", "cropTuningPanel" }) do
        ERRS = {}
        local mgr, log = newMgr({ [key] = "init" })
        local panel = mgr[key]
        mgr:onMissionLoaded()
        T.ok("H10a " .. key .. " object is kept", mgr[key] == panel)
        T.eq("H10b " .. key .. " is not deleted", #log.delete, 0)
        T.ok("H10c " .. key .. ": the error names it and says it retries on open",
             #ERRS == 1 and ERRS[1]:find(key, 1, true) ~= nil and ERRS[1]:find("retry when opened", 1, true) ~= nil)
    end
end)

-- ── H11: hud.xml is never overwritten by an uninitialized monitor, and a retired
-- panel's collapsed state survives the save. ───────────────────────────────────────
group("H11", function()
    local saveXML, saveSfm = XMLFile, g_SoilFertilityManager
    local writes = {}
    XMLFile = { create = function()
        local data = {}
        return { setFloat = function(_, k, v) data[k] = v end, setBool = function(_, k, v) data[k] = v end,
                 save = function() writes[#writes + 1] = data end, delete = function() end }
    end }
    g_SoilFertilityManager = { variableRatePanel = nil, smartSensorPanel = { collapsed = false } }
    local function hud(init)
        return setmetatable({ initialized = init, panelX = 0.1, panelY = 0.2, scale = 1, visible = true, freePos = {},
                              savedCollapsed = { varRate = true, smartSensor = true },
                              getLayoutPath = function() return "/profile/HUD/hud.xml" end }, { __index = SoilHUD })
    end
    hud(nil):saveLayout()
    T.eq("H11a an uninitialized HUD writes no layout", #writes, 0)
    hud(true):saveLayout()
    T.eq("H11b an initialized HUD writes it", #writes, 1)
    T.eq("H11c the retired Variable Rate panel keeps its collapsed=true", writes[1] and writes[1]["hudLayout.collapsed_varRate"], true)
    T.eq("H11d a live panel writes its own state", writes[1] and writes[1]["hudLayout.collapsed_smartSensor"], false)
    XMLFile, g_SoilFertilityManager = saveXML, saveSfm
end)

-- ── H12: toggling an uninitialized monitor (J, or the Control Center action, which
-- calls SoilHUD:toggleVisibility directly) neither flips it nor toasts. ───────────
group("H12", function()
    local toasts = 0
    local saveHud = g_currentMission.hud
    g_currentMission.hud = { showBlinkingWarning = function() toasts = toasts + 1 end }
    local hud = setmetatable({ initialized = nil, visible = true, saveLayout = function() end }, { __index = SoilHUD })
    hud:toggleVisibility()
    T.eq("H12a no flip and no toast on an uninitialized monitor", tostring(hud.visible) .. "/" .. toasts, "true/0")
    hud.initialized = true
    hud:toggleVisibility()
    T.eq("H12b an initialized one still toggles and toasts", tostring(hud.visible) .. "/" .. toasts, "false/1")
    g_currentMission.hud = saveHud
end)

-- ── H13: MasterHUD hide-all does not draw the rate strip from an uninitialized HUD. ──
group("H13", function()
    local saveSfm, saveHud = g_SoilFertilityManager, SoilMasterHUDBridge._hud
    local strips = 0
    SoilMasterHUDBridge._hud = { hudsHidden = true }
    local hud = { initialized = nil, drawSprayerRatePanel = function() strips = strips + 1 end }
    g_SoilFertilityManager = { soilHUD = hud }
    SoilMasterHUDBridge.drawCabTools()
    T.eq("H13a no rate strip from an uninitialized monitor", strips, 0)
    hud.initialized = true
    SoilMasterHUDBridge.drawCabTools()
    T.eq("H13b an initialized one still draws it", strips, 1)
    g_SoilFertilityManager, SoilMasterHUDBridge._hud = saveSfm, saveHud
end)
