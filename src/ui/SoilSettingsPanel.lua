-- =========================================================
-- FS25 Soil & Fertilizer - Settings Panel
-- =========================================================
-- Fully custom-drawn settings panel. No XML - pure overlay.
-- Open/close: SHIFT+O
-- Landing page → category tile → settings list.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilSettingsPanel
SoilSettingsPanel = {}
local SoilSettingsPanel_mt = Class(SoilSettingsPanel)

local SF_MOD_NAME = g_currentModName

-- ── i18n helper ───────────────────────────────────────────
local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_MOD_NAME]
    local i18n   = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- Word-wrap a string into lines that fit maxWidth at the given size. Uses the
-- engine's getTextWidth so measurement matches renderText exactly. Same helper
-- shape as SoilMapOverlay's, so the two surfaces wrap identically.
local function wrapText(text, size, maxWidth)
    if type(text) ~= "string" or text == "" then return { "" } end
    if getTextWidth == nil or maxWidth <= 0 then return { text } end
    local words = {}
    for w in text:gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then return { "" } end
    local lines, cur = {}, ""
    for _, w in ipairs(words) do
        local probe = cur == "" and w or (cur .. " " .. w)
        if cur ~= "" and getTextWidth(size, probe) > maxWidth then
            lines[#lines + 1] = cur
            cur = w
        else
            cur = probe
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

-- ── Panel geometry (normalized, Y=0 at bottom) ────────────
local PW    = 0.60
local PH    = 0.74
local PX    = (1 - PW) / 2
local PY    = (1 - PH) / 2

local TB_H  = 0.052          -- title bar height
local IB_H  = 0.046          -- info/bottom bar height
local PAD   = 0.018          -- inner horizontal padding

local CX    = PX + PAD
local CW    = PW - PAD * 2
local CY_BOT = PY + IB_H + 0.010
local CY_TOP = PY + PH - TB_H - 0.008
local CH    = CY_TOP - CY_BOT

-- Landing: 3 category cards
local CARD_GAP  = 0.012
local CARD_W    = (CW - CARD_GAP * 2) / 3
local CARD_H    = 0.32
local CARD_Y    = CY_BOT + (CH - CARD_H) / 2

-- Category page rows
local ROW_H        = 0.036
-- Taller row for the #740 world-climate picker (chips + wetness + blurb).
local CLIMATE_ROW_H = 0.112
local SEC_H     = 0.026
local TOGGLE_W  = 0.048   -- single pill width
local TOGGLE_H  = 0.026
local TOGGLE_GAP = 0.004  -- gap between ON / OFF pills
local MULTI_W   = 0.175   -- multi-select total width

-- Text sizes
local TS_TITLE  = 0.018
local TS_BODY   = 0.015
local TS_SMALL  = 0.013
local TS_TINY   = 0.011

-- ── Colors ────────────────────────────────────────────────
local C = {
    bg          = {0.05, 0.06, 0.09, 0.97},
    title_bg    = {0.07, 0.09, 0.13, 1.0},
    info_bg     = {0.04, 0.05, 0.08, 1.0},
    border      = {0.30, 0.72, 0.40, 0.45},
    shadow      = {0.00, 0.00, 0.00, 0.45},
    divider     = {0.20, 0.22, 0.28, 0.55},
    row_alt     = {1.00, 1.00, 1.00, 0.025},
    row_hover   = {0.28, 0.70, 0.38, 0.10},
    green       = {0.32, 0.88, 0.44, 1.0},
    green_dim   = {0.20, 0.55, 0.28, 1.0},
    white       = {1.00, 1.00, 1.00, 1.0},
    dim         = {0.55, 0.55, 0.60, 1.0},
    hint        = {0.38, 0.38, 0.46, 1.0},
    on_bg       = {0.22, 0.75, 0.33, 1.0},
    off_bg      = {0.15, 0.16, 0.20, 1.0},
    on_text     = {0.00, 0.00, 0.00, 1.0},
    off_text    = {0.45, 0.46, 0.52, 1.0},
    lock_bg     = {0.22, 0.14, 0.05, 0.70},
    lock_text   = {0.88, 0.60, 0.18, 1.0},
    card_hover  = {1.00, 1.00, 1.00, 0.04},
    sim_accent  = {0.30, 0.85, 0.42, 1.0},
    disp_accent = {0.35, 0.60, 0.95, 1.0},
    map_accent  = {0.90, 0.62, 0.18, 1.0},
    close_hover = {0.88, 0.25, 0.25, 0.80},
    back_hover  = {0.28, 0.70, 0.38, 0.20},
    info_admin  = {0.28, 0.80, 0.38, 1.0},
    info_no_adm = {0.88, 0.60, 0.18, 1.0},
    info_mode   = {0.55, 0.55, 0.62, 1.0},
}

-- ── Category definitions ───────────────────────────────────
local CATEGORIES = {
    {
        id       = "simulation",
        labelKey = "sf_panel_cat_sim",
        descKey  = "sf_panel_cat_sim_desc",
        accent   = C.sim_accent,
        sections = {
            {
                headerKey = "sf_panel_hdr_core",
                items     = { "fertilitySystem", "nutrientCycles", "fertilizerCosts",
                              "cropRotation", "autoRateControl" }
            },
            {
                headerKey = "sf_panel_hdr_difficulty",
                items     = { "difficulty", "replenishmentRate" }
            },
            {
                headerKey = "sf_panel_hdr_environment",
                items     = { "seasonalEffects", "rainEffects", "weatherSource", "plowingBonus", "residueIncorporation" }
            },
            {
                headerKey = "sf_panel_hdr_crop_stress",
                items     = { "weedPressure", "pestPressure", "diseasePressure", "diseaseMoisture", "diseaseDifficulty", "compactionEnabled" }
            },
            {
                headerKey = "sf_panel_hdr_experimental",
                items     = { "experimentalSystems" }
            },
        }
    },
    {
        id       = "display",
        labelKey = "sf_panel_cat_display",
        descKey  = "sf_panel_cat_display_desc",
        accent   = C.disp_accent,
        sections = {
            {
                headerKey = "sf_panel_hdr_visibility",
                items     = { "showHUD", "showWorkTrail", "showSprayerInfoPanel", "showHarvesterPanel", "showFieldInfoBox", "useImperialUnits", "colorblindMode" }
            },
            {
                headerKey = "sf_panel_hdr_hud_style",
                items     = { "hudColorTheme", "hudFontSize", "hudTransparency" }
            },
            {
                headerKey = "sf_panel_hdr_position",
                items     = { "hudPosition", "independentPanels" }
            },
        }
    },
    {
        id       = "map",
        labelKey = "sf_panel_cat_overlay",
        descKey  = "sf_panel_cat_overlay_desc",
        accent   = C.map_accent,
        sections = {
            {
                headerKey = "sf_panel_hdr_layer",
                items     = { "activeMapLayer" }
            },
            {
                headerKey = "sf_panel_hdr_performance",
                items     = { "overlayDensity" }
            },
        }
    },
}

-- ── Multi-option labels (i18n key names resolved at draw time via tr())
local MULTI_OPTS = {
    difficulty        = {"sf_diff_1", "sf_diff_2", "sf_diff_3"},
    replenishmentRate = {"sf_rr_1", "sf_rr_2", "sf_rr_3", "sf_rr_4", "sf_rr_5"},
    diseaseMoisture   = {"sf_dm_1", "sf_dm_2", "sf_dm_3", "sf_dm_4"},
    weatherSource     = {"sf_ws_1", "sf_ws_2", "sf_ws_3", "sf_ws_4"},
    diseaseDifficulty = {"sf_disease_difficulty_1", "sf_disease_difficulty_2", "sf_disease_difficulty_3"},
    hudPosition       = {"sf_hud_pos_1", "sf_hud_pos_2", "sf_hud_pos_3",
                         "sf_hud_pos_4", "sf_hud_pos_5", "sf_hud_pos_6"},
    hudColorTheme     = {"sf_hud_color_1", "sf_hud_color_2", "sf_hud_color_3", "sf_hud_color_4"},
    hudFontSize       = {"sf_hud_font_1", "sf_hud_font_2", "sf_hud_font_3"},
    hudTransparency   = {"sf_hud_trans_1", "sf_hud_trans_2", "sf_hud_trans_3",
                         "sf_hud_trans_4", "sf_hud_trans_5"},
    activeMapLayer    = {"sf_layer_1", "sf_layer_2", "sf_layer_3", "sf_layer_4",
                         "sf_layer_5", "sf_layer_6", "sf_layer_7", "sf_layer_8",
                         "sf_layer_9", "sf_layer_10", "sf_layer_11", "sf_layer_12"},
    overlayDensity    = {"sf_density_1", "sf_density_2", "sf_density_3"},
}

-- Short descriptions for each setting (i18n key names resolved at draw time via tr())
local SETTING_DESCS = {
    fertilitySystem   = "sf_desc_fertilitySystem",
    nutrientCycles    = "sf_desc_nutrientCycles",
    fertilizerCosts   = "sf_desc_fertilizerCosts",
    cropRotation      = "sf_desc_cropRotation",
    autoRateControl   = "sf_desc_autoRateControl",
    difficulty        = "sf_desc_difficulty",
    replenishmentRate = "sf_desc_replenishmentRate",
    seasonalEffects   = "sf_desc_seasonalEffects",
    rainEffects       = "sf_desc_rainEffects",
    weatherSource     = "sf_desc_weatherSource",
    plowingBonus      = "sf_desc_plowingBonus",
    residueIncorporation = "sf_desc_residueIncorporation",
    weedPressure      = "sf_desc_weedPressure",
    pestPressure      = "sf_desc_pestPressure",
    diseasePressure   = "sf_desc_diseasePressure",
    diseaseMoisture   = "sf_desc_diseaseMoisture",
    diseaseDifficulty = "sf_desc_diseaseDifficulty",
    compactionEnabled = "sf_desc_compactionEnabled",
    showHUD                = "sf_desc_showHUD",
    showWorkTrail          = "sf_desc_showWorkTrail",
    showSprayerInfoPanel   = "sf_desc_showSprayerInfoPanel",
    showHarvesterPanel     = "sf_desc_showHarvesterPanel",
    useImperialUnits  = "sf_desc_useImperialUnits",
    hudColorTheme     = "sf_desc_hudColorTheme",
    hudFontSize       = "sf_desc_hudFontSize",
    hudTransparency   = "sf_desc_hudTransparency",
    hudPosition       = "sf_desc_hudPosition",
    activeMapLayer    = "sf_desc_activeMapLayer",
    overlayDensity    = "sf_desc_overlayDensity",
    colorblindMode    = "sf_desc_colorblindMode",
    showFieldInfoBox      = "sf_desc_showFieldInfoBox",
    enabled               = "sf_desc_enabled",
    debugMode             = "sf_desc_debugMode",
    showNotifications     = "sf_desc_showNotifications",
    smartSensorEnabled    = "sf_desc_smartSensorEnabled",
    variableRateEnabled   = "sf_desc_variableRateEnabled",
    fieldBoundaryControl  = "sf_desc_fieldBoundaryControl",
    overlapPrevention     = "sf_desc_overlapPrevention",
    independentPanels     = "sf_desc_independentPanels",
    experimentalSystems   = "sf_desc_experimentalSystems",
}

-- Page states
local PAGE_LANDING  = "landing"
local PAGE_CATEGORY = "category"
local PAGE_ADMIN    = "admin"
local PAGE_SET_STATE = "set_state"
local PAGE_SET_DISEASE = "set_disease"
local PAGE_FIELD_TOOLS = "field_tools"
local PAGE_VEHICLE_TOOLS = "vehicle_tools"
local PAGE_SMART_SYSTEMS = "smart_systems"

-- ── Admin page layout ─────────────────────────────────────
local ADMIN_ROW_H = 0.033   -- setting rows (toggle/multi)
local ADMIN_ACT_H = 0.028   -- action button rows
local ADMIN_ACCENT = {0.88, 0.25, 0.25}   -- red accent for admin

local ADMIN_SECTIONS = {
    {
        headerKey = "sf_panel_hdr_actions",
        items     = {
            { stype = "action", id = "admin_save" },
            { stype = "danger", id = "admin_reset" },
            { stype = "action", id = "nav_field_tools" },
            { stype = "action", id = "nav_vehicle_tools" },
            { stype = "action", id = "nav_smart_systems" },
            { stype = "action", id = "nav_tuning" },
            { stype = "action", id = "nav_crop_tuning" },
        },
    },
    {
        headerKey = "sf_panel_hdr_mod_ctrl",
        items     = {
            { stype = "setting", id = "enabled" },
            { stype = "setting", id = "debugMode" },
            { stype = "setting", id = "difficulty" },
            { stype = "setting", id = "replenishmentRate" },
        },
    },
    {
        headerKey = "sf_panel_hdr_systems",
        items     = {
            { stype = "setting", id = "fertilitySystem" },
            { stype = "setting", id = "nutrientCycles" },
            { stype = "setting", id = "fertilizerCosts" },
            { stype = "setting", id = "showNotifications" },
            { stype = "setting", id = "seasonalEffects" },
            { stype = "setting", id = "rainEffects" },
            { stype = "setting", id = "plowingBonus" },
            { stype = "setting", id = "diseaseMoisture" },
            { stype = "setting", id = "diseaseDifficulty" },
            { stype = "setting", id = "compactionEnabled" },
        },
    },
}

local FIELD_TOOLS_SECTIONS = {
    {
        headerKey = "sf_panel_hdr_field_tools",
        items     = {
            { stype = "action", id = "admin_field_info" },
            { stype = "action", id = "admin_field_forecast" },
            { stype = "action", id = "admin_list_fields" },
            { stype = "action", id = "admin_field_set_state" },
            { stype = "action", id = "admin_field_set_disease" },
            { stype = "danger", id = "admin_field_recover" },
        },
    },
}

local VEHICLE_TOOLS_SECTIONS = {
    {
        headerKey = "sf_panel_hdr_vehicle_tools",
        items     = {
            { stype = "action", id = "admin_drain" },
        },
    },
}

local SMART_SYSTEMS_SECTIONS = {
    {
        headerKey = "sf_panel_hdr_smart_sensor_sys",
        items     = {
            { stype = "setting", id = "smartSensorEnabled" },
        },
    },
    {
        headerKey = "sf_panel_hdr_var_rate_sys",
        items     = {
            { stype = "setting", id = "variableRateEnabled" },
        },
    },
    {
        headerKey = "sf_panel_hdr_field_boundary",
        items     = {
            { stype = "setting", id = "fieldBoundaryControl" },
        },
    },
    {
        headerKey = "sf_panel_hdr_overlap_prev",
        items     = {
            { stype = "setting", id = "overlapPrevention" },
        },
    },
}

-- Rows that are player "bypass" tools: greyed with a "Locked - <difficulty>" note and
-- inert on any difficulty above Simple (see Settings:allowsBypassTools). The draw loop,
-- the click handler, and the control widgets all read SIMPLE_ONLY_IDS.
--   * ACTION rows (editors + field cheats) are listed explicitly below - they are not
--     schema settings, so this is their only home.
--   * SETTING rows come from the schema's `simpleOnly` flag, the single source of truth
--     that Settings:enforceBypassLock() also uses, so the soften-toggle list is never
--     duplicated or allowed to drift between the schema and the panel.
-- Intentionally NOT locked: the Difficulty selector itself, master Enable, Debug,
-- Notifications, Save/Reset, the read-only Field Info/Forecast/List actions, and the
-- Smart Systems (precision-ag QoL, not a way to soften the soil sim).
local SIMPLE_ONLY_ACTION_IDS = {
    nav_tuning              = true,  -- Constants Tuning Editor
    nav_crop_tuning         = true,  -- Crop Tuning Editor (#717)
    admin_field_set_state   = true,
    admin_field_set_disease = true,
    admin_field_recover     = true,
    admin_drain             = true,
}
local SIMPLE_ONLY_IDS = {}
for id in pairs(SIMPLE_ONLY_ACTION_IDS) do SIMPLE_ONLY_IDS[id] = true end
for _, def in ipairs(SettingsSchema.definitions) do
    if def.simpleOnly then SIMPLE_ONLY_IDS[def.id] = true end
end

-- ── Constructor ───────────────────────────────────────────
function SoilSettingsPanel.new(settings)
    local self = setmetatable({}, SoilSettingsPanel_mt)
    self.settings     = settings
    self.fillOverlay  = nil
    self.isVisible    = false
    local mod = g_modManager and g_modManager:getModByName(SF_MOD_NAME)
    self.modVersion   = (mod and mod.version) and ("v" .. tostring(mod.version)) or ""
    self.page         = PAGE_LANDING
    self.activeCatIdx = nil
    self.adminMsg     = nil   -- last action result shown in admin page
    self.popupVisible = false -- whether the output popup dialog is shown
    self.popupMsg     = nil   -- full output text shown in the popup
    self.popupLines   = nil   -- split lines of popupMsg
    self.popupScroll  = 0     -- first visible line index (0-based)
    self.pageScrollPx = 0    -- index for scrolling settings lists
    self.setStateFieldId = nil
    self.setStateData = {N=50, P=50, K=50, pH=6.5, OM=5.0}
    self.setDiseaseFieldId = nil
    self.setDiseasePressure = 0
    self.setDiseaseList = { "" }  -- index 1 = "" (auto-pick by weather), then crop candidates
    self.setDiseaseIdx = 1
    self.mouseX       = 0
    self.mouseY       = 0
    self.initialized  = false
    self._clickRects  = {}  -- populated each draw frame
    return self
end

function SoilSettingsPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    self.initialized = true
end

function SoilSettingsPanel:delete()
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Visibility ────────────────────────────────────────────
function SoilSettingsPanel:open()
    if not self.initialized then self:initialize() end
    self.isVisible    = true
    self.page         = PAGE_LANDING
    self.activeCatIdx = nil
    self.adminMsg     = nil
    self.popupVisible = false
    self.popupMsg     = nil
    self.popupLines   = nil
    self.popupScroll  = 0
    self.pageScrollPx = 0
    -- Save camera rotation so update() can freeze it every frame (SoilHUD edit-mode pattern)
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if getCamera and getRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            local ok2, rx, ry, rz = pcall(getRotation, cam)
            if ok2 then
                self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = rx, ry, rz
            end
        end
    end
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    SoilLogger.debug("SoilSettingsPanel: opened")
end

function SoilSettingsPanel:close()
    -- Closing the panel ABORTS any pending confirmation. Escape, the [X], the
    -- hotkey and the auto-close in update() all land here, and none of them is
    -- an answer to the question. A pending value must never outlive the panel.
    self:_dismissConfirm()
    self.isVisible = false
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
    SoilLogger.debug("SoilSettingsPanel: closed")
end

-- Called every frame by SoilFertilityManager:update(). Keeps cursor shown and camera frozen.
function SoilSettingsPanel:update()
    if not self.isVisible then return end
    -- Keep cursor shown every frame (game may try to hide it)
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    -- Force camera back to saved rotation every frame (prevents mouse-look while panel is open)
    if self.savedCamRotX ~= nil and getCamera and setRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            pcall(setRotation, cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
        end
    end
    -- Auto-close if a GUI (dialog/menu) opens on top
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        self:close()
    end
end

function SoilSettingsPanel:toggle()
    if self.isVisible then self:close() else self:open() end
end

function SoilSettingsPanel:isOpen()
    return self.isVisible
end

-- ── Admin / settings helpers ──────────────────────────────
function SoilSettingsPanel:isAdmin()
    return SoilUtils.isPlayerAdmin()
end

--- Every setting change from this panel funnels through here, which is why the
--- experimental gate is intercepted at this one point rather than at each of the
--- five call sites that can flip a boolean.
---
--- @param skipConfirm boolean|nil  bypass the experimental confirmation. Used by
---   resetCurrentCategory, which is already an explicit deliberate action and
---   only ever restores the LOCKED default, so it never needs to ask.
function SoilSettingsPanel:requestChange(id, value, skipConfirm)
    local def = SettingsSchema.byId[id]
    if not def then return end

    -- THE EXPERIMENTAL GATE NEVER FLIPS ON ONE CLICK. It arms unfinished systems
    -- on a live save, so it asks first and a refusal leaves the toggle untouched.
    if id == "experimentalSystems" and skipConfirm ~= true and value ~= self.settings[id] then
        -- Refuse BEFORE we warn: putting a scary confirmation in front of someone
        -- whose change we are about to reject anyway is worse than refusing now.
        if not def.localOnly and not self:isAdmin() then
            self:_warnNotAdmin()
            return
        end
        self:_confirmExperimental(value)
        return
    end

    self:_applyChange(id, value)
end

function SoilSettingsPanel:_warnNotAdmin()
    if g_currentMission and g_currentMission.hud and
       g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(
            "Only server admins can change this setting", 4000)
    end
end

--- Ask before arming or disarming the experimental systems. Abort leaves the
--- setting exactly as it was; only Confirm reaches _applyChange.
---
--- THIS IS A DRAWN CONFIRMATION, NOT A BASE-GAME YesNoDialog, for two reasons.
--- The style one: this panel is immediate-mode with its own frame, palette and
--- hit-tested click ids, and it already owns a modal idiom in drawPopupDialog,
--- so a GUI dialog would open in a different visual language on top of it.
--- The functional one, which settles it: SoilSettingsPanel:update() closes the
--- panel whenever g_gui reports a dialog visible, so showing a YesNoDialog
--- would dismiss the very panel the player is answering for.
function SoilSettingsPanel:_confirmExperimental(value)
    self.confirmVisible = true
    self.confirmValue   = value
    self.confirmText    = value == true
        and tr("sf_exp_confirm_on",
            "This turns on systems that are NOT finished. They can behave oddly, " ..
            "change without warning, or affect this savegame in ways that cannot be " ..
            "undone. Keep a backup save.")
        or tr("sf_exp_confirm_off",
            "Experimental systems will stop running on this savegame. Anything they " ..
            "already wrote stays where it is, but it will no longer be updated.")
    self.confirmQuestion = value == true
        and tr("sf_exp_confirm_q_on", "Turn experimental systems ON?")
        or tr("sf_exp_confirm_q_off", "Turn experimental systems OFF?")
end

--- Dismiss without acting. EVERY exit that is not the Confirm button lands here,
--- so a pending answer can never survive to be applied later.
function SoilSettingsPanel:_dismissConfirm()
    self.confirmVisible  = false
    self.confirmValue    = nil
    self.confirmText     = nil
    self.confirmQuestion = nil
end

--- The Confirm button, and the only path that reaches the change. The pending
--- value is cleared BEFORE applying, so a failure inside _applyChange cannot
--- leave a live confirmation behind.
function SoilSettingsPanel:_acceptConfirm()
    local value = self.confirmValue
    self:_dismissConfirm()
    if value == nil then return end
    self:_applyChange("experimentalSystems", value)
end

--- The original change path, unchanged. Reached directly for every setting
--- except the experimental gate, and via the confirmation for that one.
function SoilSettingsPanel:_applyChange(id, value)
    local def = SettingsSchema.byId[id]
    if not def then return end
    if def.localOnly then
        self.settings[id] = value
        self.settings:save()
        if id == "hudPosition" and g_SoilFertilityManager and g_SoilFertilityManager.soilHUD then
            g_SoilFertilityManager.soilHUD:updatePosition()
        end
        return
    end
    -- Re-checked here rather than trusted from the caller: the confirmation
    -- dialog is modal but not instant, and admin status can change under it.
    if not self:isAdmin() then
        self:_warnNotAdmin()
        return
    end
    if SoilNetworkEvents_RequestSettingChange then
        SoilNetworkEvents_RequestSettingChange(id, value)
    else
        self.settings[id] = value
        self.settings:save()
    end
end

function SoilSettingsPanel:getValue(id)
    return self.settings[id]
end

-- ── Drawing helper ────────────────────────────────────────
function SoilSettingsPanel:drawRect(x, y, w, h, col, alpha)
    if not self.fillOverlay then return end
    local a = alpha or col[4] or 1.0
    setOverlayColor(self.fillOverlay, col[1], col[2], col[3], a)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

---Every text draw in this panel goes through here, so it is the one place that
---has to know about long translations (issue #771). maxWidth is optional and
---backwards compatible: without it this behaves exactly as it always did.
---Bold is set before measuring because getTextWidth reads the current bold state.
function SoilSettingsPanel:drawText(x, y, size, text, col, align, bold, maxWidth)
    setTextColor(col[1], col[2], col[3], col[4] or 1.0)
    setTextBold(bold == true)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    if maxWidth ~= nil and UIHelper ~= nil and UIHelper.fitText ~= nil then
        local fitted, fittedSize = UIHelper.fitText(text, size, maxWidth)
        renderText(x, y, fittedSize, fitted)
    else
        renderText(x, y, size, text)
    end
end

function SoilSettingsPanel:registerClick(id, x, y, w, h, data)
    table.insert(self._clickRects, { id = id, x = x, y = y, w = w, h = h, data = data })
end

function SoilSettingsPanel:hitTest(rx, ry, rw, rh, mx, my)
    return mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh
end

-- ── Main draw entry ───────────────────────────────────────
function SoilSettingsPanel:draw()
    if not self.isVisible then return end
    if not self.initialized then return end
    if not g_currentMission then return end

    self._clickRects = {}

    -- Dark screen fade
    self:drawRect(0, 0, 1, 1, C.shadow, 0.40)

    -- Panel shadow
    self:drawRect(PX + 0.004, PY - 0.004, PW, PH, C.shadow, 0.55)

    -- Panel background
    self:drawRect(PX, PY, PW, PH, C.bg)

    -- Border
    local bw = 0.0015
    self:drawRect(PX,          PY,          PW, bw, C.border)
    self:drawRect(PX,          PY + PH - bw, PW, bw, C.border)
    self:drawRect(PX,          PY,          bw, PH, C.border)
    self:drawRect(PX + PW - bw, PY,         bw, PH, C.border)

    -- Page content, skipped while a modal is up. Both modals draw their own dim
    -- overlay, but that overlay only covers what was drawn as an OVERLAY: text
    -- from the page underneath still reads straight through a box painted on top
    -- of it, which is why the popup has always skipped the page rather than
    -- covering it. The confirmation has to do the same or the settings rows show
    -- through its body copy.
    if not self.popupVisible and not self.confirmVisible then
        if self.page == PAGE_LANDING then
            self:drawLandingPage()
        elseif self.page == PAGE_CATEGORY then
            self:drawCategoryPage()
        elseif self.page == PAGE_ADMIN or self.page == PAGE_FIELD_TOOLS
            or self.page == PAGE_VEHICLE_TOOLS or self.page == PAGE_SMART_SYSTEMS then
            self:drawAdminPage()
        elseif self.page == PAGE_SET_STATE then
            if self.drawSetStatePage then self:drawSetStatePage() end
        elseif self.page == PAGE_SET_DISEASE then
            if self.drawSetDiseasePage then self:drawSetDiseasePage() end
        end
    end

    -- Draw header/footer ON TOP of page content to cover scrolled items
    self:drawTitleBar()
    self:drawInfoBar()

    -- Popup dialog always drawn on top.
    -- Reset click zones first so page buttons can't be clicked through the popup.
    if self.popupVisible then
        self._clickRects = {}
    end
    self:drawPopupDialog()

    -- The experimental confirmation sits above everything, including the popup.
    -- Click zones are cleared first for the same reason: nothing behind a modal
    -- may be clicked through it, so its two buttons are the only live targets.
    if self.confirmVisible then
        self._clickRects = {}
        self:drawConfirmDialog()
    end
end

-- ── Title bar ─────────────────────────────────────────────
function SoilSettingsPanel:drawTitleBar()
    local ty = PY + PH - TB_H
    self:drawRect(PX, ty, PW, TB_H, C.title_bg)

    -- Left accent line
    local accColor = (self.page == PAGE_ADMIN) and ADMIN_ACCENT
                  or (self.activeCatIdx and CATEGORIES[self.activeCatIdx].accent)
                  or C.green
    self:drawRect(PX, ty, 0.004, TB_H, accColor)

    -- Title text
    local title = "SOIL & FERTILIZER SETTINGS"
    if self.page == PAGE_SMART_SYSTEMS then
        title = title .. "  /  ADMIN PANEL  /  SMART SYSTEMS"
    elseif self.page == PAGE_SET_DISEASE then
        title = title .. "  /  ADMIN PANEL  /  SET DISEASE"
    elseif self.page == PAGE_FIELD_TOOLS then
        title = title .. "  /  ADMIN PANEL  /  FIELD TOOLS"
    elseif self.page == PAGE_VEHICLE_TOOLS then
        title = title .. "  /  ADMIN PANEL  /  VEHICLE TOOLS"
    elseif self.page == PAGE_ADMIN then
        title = title .. "  /  ADMIN PANEL"
    elseif self.activeCatIdx then
        local cat = CATEGORIES[self.activeCatIdx]
        local catLabel = (cat.label) or tr(cat.labelKey) or cat.id or ""
        title = title .. "  /  " .. string.upper(catLabel)
    end
    self:drawText(PX + 0.018, ty + TB_H * 0.32, TS_TITLE, title, C.white, RenderText.ALIGN_LEFT, true)

    -- Version tag
    self:drawText(PX + PW - 0.020, ty + TB_H * 0.32, TS_TINY, self.modVersion, C.hint, RenderText.ALIGN_RIGHT, false)

    -- [X] close button - right side
    local cbW = 0.038
    local cbH = TB_H * 0.60
    local cbX = PX + PW - cbW - 0.010
    local cbY = ty + (TB_H - cbH) / 2
    local closeHover = self:hitTest(cbX, cbY, cbW, cbH, self.mouseX, self.mouseY)
    self:drawRect(cbX, cbY, cbW, cbH, closeHover and C.close_hover or C.off_bg)
    self:drawText(cbX + cbW * 0.5, cbY + cbH * 0.18, TS_SMALL, "X", C.white, RenderText.ALIGN_CENTER, true)
    self:registerClick("close", cbX, cbY, cbW, cbH)
end

-- ── Info bar ──────────────────────────────────────────────
function SoilSettingsPanel:drawInfoBar()
    local iy = PY
    self:drawRect(PX, iy, PW, IB_H, C.info_bg)

    -- Thin top border
    self:drawRect(PX, iy + IB_H - 0.001, PW, 0.001, C.divider)

    local isAdmin = self:isAdmin()
    local isMP    = g_currentMission and g_currentMission.missionDynamicInfo and
                    g_currentMission.missionDynamicInfo.isMultiplayer

    local adminText  = isAdmin and tr("sf_panel_admin_yes") or tr("sf_panel_admin_no")
    local adminColor = isAdmin and C.info_admin or C.info_no_adm
    local modeText   = isMP and tr("sf_panel_multiplayer") or tr("sf_panel_singleplayer")

    local textY = iy + IB_H * 0.25
    self:drawText(PX + PAD, textY, TS_SMALL, adminText, adminColor, RenderText.ALIGN_LEFT, true)
    self:drawText(PX + PAD + 0.10, textY, TS_SMALL, "·  " .. modeText, C.info_mode, RenderText.ALIGN_LEFT, false)

    if self.page == PAGE_CATEGORY or self.page == PAGE_ADMIN or self.page == PAGE_SET_STATE
       or self.page == PAGE_SET_DISEASE
       or self.page == PAGE_FIELD_TOOLS or self.page == PAGE_VEHICLE_TOOLS
       or self.page == PAGE_SMART_SYSTEMS then
        -- Back button
        local bbW = 0.085
        local bbH = IB_H * 0.62
        local bbX = PX + PW - bbW * 2 - 0.030
        local bbY = iy + (IB_H - bbH) / 2
        local backHover = self:hitTest(bbX, bbY, bbW, bbH, self.mouseX, self.mouseY)
        self:drawRect(bbX, bbY, bbW, bbH, backHover and C.back_hover or C.off_bg)
        self:drawRect(bbX, bbY, 0.002, bbH, C.green_dim)
        self:drawText(bbX + bbW * 0.5, bbY + bbH * 0.18, TS_SMALL, tr("sf_panel_btn_back"), C.white, RenderText.ALIGN_CENTER, false)
        self:registerClick("back", bbX, bbY, bbW, bbH)

        if self.page == PAGE_CATEGORY then
            -- Reset button (category only)
            local rbW = 0.095
            local rbX = bbX + bbW + 0.010
            local rbY = bbY
            local resetHover = self:hitTest(rbX, rbY, rbW, bbH, self.mouseX, self.mouseY)
            self:drawRect(rbX, rbY, rbW, bbH, resetHover and {0.50, 0.20, 0.10, 0.70} or C.off_bg)
            self:drawText(rbX + rbW * 0.5, rbY + bbH * 0.18, TS_SMALL, tr("sf_panel_btn_reset_cat"), C.dim, RenderText.ALIGN_CENTER, false)
            self:registerClick("reset_cat", rbX, rbY, rbW, bbH)
        end
    else
        -- Close hint on landing
        self:drawText(PX + PW - PAD, textY, TS_SMALL, tr("sf_panel_btn_close_hint"), C.hint, RenderText.ALIGN_RIGHT, false)
    end
end

-- ── Landing page ──────────────────────────────────────────
function SoilSettingsPanel:drawLandingPage()
    -- Header above cards
    local headerY = CY_BOT + CH - 0.042
    self:drawText(PX + PW * 0.5, headerY, TS_SMALL,
        tr("sf_panel_select_category"), C.hint, RenderText.ALIGN_CENTER, false)

    for i, cat in ipairs(CATEGORIES) do
        local cardX = CX + (i - 1) * (CARD_W + CARD_GAP)
        self:drawCategoryCard(cardX, CARD_Y, CARD_W, CARD_H, cat, i)
    end

    -- ADMIN button - bottom-right corner
    local btnW = 0.090
    local btnH = 0.032
    local btnX = CX + CW - btnW
    local btnY = CY_BOT + 0.005
    local btnHov = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(btnX, btnY, btnW, btnH,
        btnHov and {0.55, 0.08, 0.08, 0.95} or {0.22, 0.05, 0.05, 0.88})
    self:drawRect(btnX, btnY, 0.003, btnH, ADMIN_ACCENT)
    self:drawRect(btnX, btnY + btnH - 0.001, btnW, 0.001, ADMIN_ACCENT, 0.40)
    self:drawText(btnX + btnW * 0.5 + 0.002, btnY + btnH * 0.22, TS_SMALL,
        "⚙ ADMIN",
        btnHov and {1.0, 0.55, 0.55, 1.0} or {0.85, 0.35, 0.35, 1.0},
        RenderText.ALIGN_CENTER, true)
    self:registerClick("open_admin", btnX, btnY, btnW, btnH)
end

function SoilSettingsPanel:drawCategoryCard(x, y, w, h, cat, idx)
    local hovered = self:hitTest(x, y, w, h, self.mouseX, self.mouseY)

    -- Card background
    self:drawRect(x, y, w, h, C.bg)
    if hovered then
        self:drawRect(x, y, w, h, C.card_hover)
    end

    -- Card border
    local bw = 0.0012
    self:drawRect(x,         y,         w, bw, cat.accent, 0.30)
    self:drawRect(x,         y + h - bw, w, bw, cat.accent, 0.30)
    self:drawRect(x,         y,         bw, h,  cat.accent, 0.30)
    self:drawRect(x + w - bw, y,         bw, h,  cat.accent, 0.30)

    -- Top color accent bar
    self:drawRect(x, y + h - 0.018, w, 0.018, cat.accent, hovered and 0.85 or 0.65)

    -- Category title
    local titleY = y + h - 0.018 - 0.044
    self:drawText(x + w * 0.5, titleY, TS_BODY,
        string.upper(tr(cat.labelKey) or cat.id), C.white, RenderText.ALIGN_CENTER, true)

    -- Divider under title
    self:drawRect(x + 0.010, titleY - 0.006, w - 0.020, 0.001, C.divider)

    -- Count settings
    local count = 0
    for _, sec in ipairs(cat.sections) do count = count + #sec.items end

    -- Description (supports \n for manual line breaks; single line is fine too)
    local descY = titleY - 0.038
    local descStr = tr(cat.descKey) or ""
    local lines = {}
    for line in (descStr .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    for j, line in ipairs(lines) do
        self:drawText(x + w * 0.5, descY - (j - 1) * 0.022, TS_SMALL,
            line, C.dim, RenderText.ALIGN_CENTER, false)
    end

    -- Settings count badge
    local badgeY = y + 0.040
    self:drawText(x + w * 0.5, badgeY, TS_SMALL,
        count .. " settings", cat.accent, RenderText.ALIGN_CENTER, false)

    -- "Configure →" button at bottom
    local btnW = w - 0.024
    local btnH = 0.028
    local btnX = x + 0.012
    local btnY = y + 0.008
    self:drawRect(btnX, btnY, btnW, btnH,
        hovered and cat.accent or C.off_bg,
        hovered and 0.20 or 1.0)
    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.18, TS_SMALL,
        hovered and tr("sf_panel_btn_open") or tr("sf_panel_btn_configure"),
        hovered and cat.accent or C.hint,
        RenderText.ALIGN_CENTER, false)

    self:registerClick("cat_" .. idx, x, y, w, h)
end

-- ── Scroll helpers ────────────────────────────────────────

local function settingRowHeight(settingId)
    if settingId == "weatherSource" then
        return CLIMATE_ROW_H
    end
    return ROW_H
end

--- Total rendered height of all sections + items in a category (for scrollbar).
function SoilSettingsPanel:_catContentHeight(cat)
    local h = 0
    for _, sec in ipairs(cat.sections) do
        h = h + SEC_H + 0.005
        for _, item in ipairs(sec.items) do
            if type(item) == "string" then
                h = h + settingRowHeight(item)
            elseif type(item) == "table" then
                h = h + ADMIN_ACT_H
            end
        end
    end
    return h
end

--- Total rendered height of the active admin sub-page (for scrollbar).
function SoilSettingsPanel:_adminContentHeight()
    local sections = ADMIN_SECTIONS
    if self.page == PAGE_FIELD_TOOLS     then sections = FIELD_TOOLS_SECTIONS
    elseif self.page == PAGE_VEHICLE_TOOLS then sections = VEHICLE_TOOLS_SECTIONS
    elseif self.page == PAGE_SMART_SYSTEMS then sections = SMART_SYSTEMS_SECTIONS
    end
    local h = 0
    for _, sec in ipairs(sections) do
        h = h + SEC_H + 0.005
        for _, item in ipairs(sec.items) do
            h = h + ((item.stype == "action" or item.stype == "danger") and ADMIN_ACT_H or ADMIN_ROW_H)
        end
    end
    return h
end

--- Draw a scrollbar track + thumb + up/down arrow buttons in the right gutter.
---@param sbX number  left X of the strip (placed in the right padding area)
---@param sbY number  bottom Y (= CY_BOT)
---@param sbW number  strip width
---@param sbH number  strip height (= CH)
---@param scrollPx number  current scroll offset (0 = top)
---@param maxScroll number  maximum scroll offset (> 0)
---@param accent table  {r,g,b} accent colour for thumb and arrows
function SoilSettingsPanel:_drawPageScrollBar(sbX, sbY, sbW, sbH, scrollPx, maxScroll, accent)
    local ac = accent or C.green

    -- Track background
    self:drawRect(sbX, sbY, sbW, sbH, {0.07, 0.08, 0.12, 0.92})
    self:drawRect(sbX, sbY, 0.001, sbH, {ac[1]*0.22, ac[2]*0.22, ac[3]*0.22, 0.70})

    -- Arrow buttons (top = scroll up, bottom = scroll down)
    local arrowH = 0.026
    local upY    = sbY + sbH - arrowH
    local dnY    = sbY

    local upHov  = self:hitTest(sbX, upY, sbW, arrowH, self.mouseX, self.mouseY)
    local dnHov  = self:hitTest(sbX, dnY, sbW, arrowH, self.mouseX, self.mouseY)
    local canUp  = scrollPx > 0
    local canDn  = scrollPx < maxScroll

    self:drawRect(sbX, upY, sbW, arrowH,
        upHov and {ac[1]*0.55, ac[2]*0.55, ac[3]*0.55, 0.95} or {0.10, 0.12, 0.18, 0.90})
    self:drawText(sbX + sbW * 0.5, upY + arrowH * 0.22, TS_TINY, "^",
        canUp and (upHov and {1,1,1,1} or {ac[1], ac[2], ac[3], 0.80}) or C.hint,
        RenderText.ALIGN_CENTER, true)

    self:drawRect(sbX, dnY, sbW, arrowH,
        dnHov and {ac[1]*0.55, ac[2]*0.55, ac[3]*0.55, 0.95} or {0.10, 0.12, 0.18, 0.90})
    self:drawText(sbX + sbW * 0.5, dnY + arrowH * 0.22, TS_TINY, "v",
        canDn and (dnHov and {1,1,1,1} or {ac[1], ac[2], ac[3], 0.80}) or C.hint,
        RenderText.ALIGN_CENTER, true)

    self:registerClick("page_scroll_up", sbX, upY, sbW, arrowH)
    self:registerClick("page_scroll_dn", sbX, dnY, sbW, arrowH)

    -- Thumb (in track between arrows)
    local trackY = sbY + arrowH
    local trackH = sbH - arrowH * 2
    if trackH > 0.010 then
        local ratio  = scrollPx / maxScroll
        local visRatio = math.min(1, CH / (CH + maxScroll))
        local thumbH = math.max(0.030, trackH * visRatio)
        local thumbY = trackY + (trackH - thumbH) * (1 - ratio)
        self:drawRect(sbX, thumbY, sbW, thumbH,
            {ac[1]*0.42, ac[2]*0.42, ac[3]*0.42, 0.92})
        -- Top highlight line on thumb
        self:drawRect(sbX, thumbY + thumbH - 0.0012, sbW, 0.0012,
            {ac[1]*0.80, ac[2]*0.80, ac[3]*0.80, 0.85})
    end
end

-- ── Category page ─────────────────────────────────────────
function SoilSettingsPanel:drawCategoryPage()
    if not self.activeCatIdx then return end
    local cat = CATEGORIES[self.activeCatIdx]
    if not cat then return end

    -- Scrolling: clamp offset to valid range
    local totalH    = self:_catContentHeight(cat)
    local maxScroll = math.max(0, totalH - CH)
    if self.pageScrollPx > maxScroll then self.pageScrollPx = maxScroll end
    local scrollPx = self.pageScrollPx

    local curY    = CY_TOP + scrollPx
    local isAdmin = self:isAdmin()
    local rowIdx  = 0

    for _, sec in ipairs(cat.sections) do
        -- Section header
        curY = curY - SEC_H
        if curY < CY_BOT then break end

        if curY <= CY_TOP then
            self:drawRect(CX, curY, CW, SEC_H, C.title_bg, 0.60)
            self:drawRect(CX, curY, 0.003, SEC_H, cat.accent)
            self:drawText(CX + 0.012, curY + SEC_H * 0.25, TS_SMALL,
                string.upper(tr(sec.headerKey) or ""), cat.accent, RenderText.ALIGN_LEFT, true)
        end

        for _, item in ipairs(sec.items) do
            local settingId = type(item) == "string" and item or nil
            local itemDef   = type(item) == "table"  and item or nil

            if settingId then
                local rh = settingRowHeight(settingId)
                curY = curY - rh
                if curY < CY_BOT then break end
                rowIdx = rowIdx + 1
                if curY <= CY_TOP then
                    self:drawSettingRow(CX, curY, CW, settingId, rowIdx, isAdmin)
                end
            elseif itemDef and (itemDef.stype == "action" or itemDef.stype == "danger") then
                local rh = ADMIN_ACT_H
                curY = curY - rh
                if curY < CY_BOT then break end
                rowIdx = rowIdx + 1
                if curY <= CY_TOP then
                    if rowIdx % 2 == 0 then self:drawRect(CX, curY, CW, rh, C.row_alt) end
                    local isDanger = (itemDef.stype == "danger")
                    local btnW = 0.130
                    local btnH = rh * 0.72
                    local btnX = CX + CW - btnW - 0.012
                    local btnY = curY + (rh - btnH) * 0.5
                    local hov  = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)
                    local aLabel = tr("sf_" .. itemDef.id .. "_label", itemDef.id)
                    local aDesc  = tr("sf_" .. itemDef.id .. "_desc",  "")
                    self:drawText(CX + 0.008, curY + rh * 0.55, TS_BODY, aLabel, C.white, RenderText.ALIGN_LEFT, true)
                    self:drawText(CX + 0.008, curY + rh * 0.15, TS_TINY, aDesc,  C.dim,   RenderText.ALIGN_LEFT, false)
                    local acCol = isDanger and ADMIN_ACCENT or cat.accent
                    local bgCol = isDanger
                        and (hov and {0.65, 0.10, 0.10, 0.95} or {0.30, 0.06, 0.06, 0.85})
                        or  (hov and {acCol[1]*0.4, acCol[2]*0.4, acCol[3]*0.4, 0.95}
                                  or {acCol[1]*0.15, acCol[2]*0.15, acCol[3]*0.15, 0.85})
                    self:drawRect(btnX, btnY, btnW, btnH, bgCol)
                    self:drawRect(btnX, btnY, 0.002, btnH, acCol)
                    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.20, TS_TINY,
                        ">  " .. aLabel,
                        hov and {1,1,1,1} or {0.75,0.75,0.75,1},
                        RenderText.ALIGN_CENTER, false)
                    self:registerClick("cat_action_" .. itemDef.id, btnX, btnY, btnW, btnH,
                        { actionId = itemDef.id })
                    self:drawRect(CX, curY, CW, 0.0005, C.divider, 0.35)
                end
            end
        end

        curY = curY - 0.005
    end

    -- Scrollbar in right gutter (only when content overflows)
    if maxScroll > 0 then
        self:_drawPageScrollBar(CX + CW + 0.004, CY_BOT, 0.009, CH, scrollPx, maxScroll, cat.accent)
    end

    -- Thin top divider under title bar
    self:drawRect(CX, CY_TOP, CW, 0.001, C.divider)
end

-- ── Set State page ────────────────────────────────────────
function SoilSettingsPanel:drawSetStatePage()
    local fid = self.setStateFieldId
    local sd  = self.setStateData

    -- Title
    local titleY = CY_TOP - 0.040
    local stateTitle = g_i18n and g_i18n:getText("sf_set_state_title") or "SET FIELD STATE"
    self:drawText(CX + CW * 0.5, titleY, TS_BODY,
        string.format("%s  -  Field #%s", stateTitle, tostring(fid or "?")),
        C.white, RenderText.ALIGN_CENTER, true)
    self:drawRect(CX, titleY - 0.006, CW, 0.001, C.divider)

    -- Each nutrient row
    local params = {
        { k = "N",  label = g_i18n and g_i18n:getText("sf_map_layer_n") or "Nitrogen (N)",      min = 0,   max = 100, step = 1,   fmt = "%.0f" },
        { k = "P",  label = g_i18n and g_i18n:getText("sf_map_layer_p") or "Phosphorus (P)",    min = 0,   max = 100, step = 1,   fmt = "%.0f" },
        { k = "K",  label = g_i18n and g_i18n:getText("sf_map_layer_k") or "Potassium (K)",     min = 0,   max = 100, step = 1,   fmt = "%.0f" },
        { k = "pH", label = "pH",                                                            min = 4.0, max = 9.0, step = 0.1, fmt = "%.1f" },
        { k = "OM", label = g_i18n and g_i18n:getText("sf_map_layer_om") or "Organic Matter (%)", min = 0.5, max = 15,  step = 0.5, fmt = "%.1f" },
    }

    local rowH   = 0.040
    local ctrlW  = 0.030
    local valW   = 0.065
    local curY   = titleY - 0.016

    for _, p in ipairs(params) do
        curY = curY - rowH
        if curY < CY_BOT then break end

        local val = sd[p.k] or p.min

        -- Row bg
        self:drawRect(CX, curY, CW, rowH - 0.003, C.row_alt)
        self:drawRect(CX, curY, 0.003, rowH - 0.003, C.green_dim)

        -- Label
        self:drawText(CX + 0.012, curY + (rowH - 0.003) * 0.52, TS_BODY,
            p.label, C.white, RenderText.ALIGN_LEFT, false)

        -- [ - ] value [ + ] controls on the right
        local rightEdge = CX + CW - 0.012
        local plusX  = rightEdge - ctrlW
        local labelX = plusX - valW
        local minusX = labelX - ctrlW

        -- [–] button
        local mHov = self:hitTest(minusX, curY + 0.005, ctrlW, rowH - 0.012, self.mouseX, self.mouseY)
        self:drawRect(minusX, curY + 0.005, ctrlW, rowH - 0.012,
            mHov and C.back_hover or C.off_bg)
        self:drawText(minusX + ctrlW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            "-", C.white, RenderText.ALIGN_CENTER, true)

        -- Value label
        self:drawRect(labelX, curY + 0.005, valW, rowH - 0.012, {0.10, 0.11, 0.15, 0.90})
        self:drawText(labelX + valW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            string.format(p.fmt, val), C.green, RenderText.ALIGN_CENTER, true)

        -- [+] button
        local pHov = self:hitTest(plusX, curY + 0.005, ctrlW, rowH - 0.012, self.mouseX, self.mouseY)
        self:drawRect(plusX, curY + 0.005, ctrlW, rowH - 0.012,
            pHov and C.back_hover or C.off_bg)
        self:drawText(plusX + ctrlW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            "+", C.white, RenderText.ALIGN_CENTER, true)

        self:registerClick("set_state_-" .. p.k, minusX, curY + 0.005, ctrlW, rowH - 0.012,
            { k = p.k, step = -p.step, min = p.min, max = p.max })
        self:registerClick("set_state_+" .. p.k, plusX, curY + 0.005, ctrlW, rowH - 0.012,
            { k = p.k, step = p.step, min = p.min, max = p.max })
    end

    -- Save button
    local saveBtnW = 0.120
    local saveBtnH = 0.032
    local saveBtnX = CX + (CW - saveBtnW) * 0.5
    local saveBtnY = CY_BOT + 0.014
    local saveHov  = self:hitTest(saveBtnX, saveBtnY, saveBtnW, saveBtnH, self.mouseX, self.mouseY)
    self:drawRect(saveBtnX, saveBtnY, saveBtnW, saveBtnH,
        saveHov and {0.10, 0.45, 0.18, 0.95} or {0.07, 0.25, 0.12, 0.90})
    self:drawRect(saveBtnX, saveBtnY, 0.003, saveBtnH, C.green)
    self:drawText(saveBtnX + saveBtnW * 0.5, saveBtnY + saveBtnH * 0.22, TS_SMALL,
        ">  APPLY TO FIELD",
        saveHov and C.white or C.green, RenderText.ALIGN_CENTER, true)
    self:registerClick("set_state_save", saveBtnX, saveBtnY, saveBtnW, saveBtnH)

    self:drawRect(CX, CY_TOP, CW, 0.001, C.divider)
end

-- ── Set Disease page ──────────────────────────────────────
function SoilSettingsPanel:drawSetDiseasePage()
    local fid = self.setDiseaseFieldId

    -- Title
    local titleY = CY_TOP - 0.040
    local diseaseTitle = g_i18n and g_i18n:getText("sf_set_disease_title") or "SET FIELD DISEASE"
    self:drawText(CX + CW * 0.5, titleY, TS_BODY,
        string.format("%s  -  Field #%s", diseaseTitle, tostring(fid or "?")),
        C.white, RenderText.ALIGN_CENTER, true)
    self:drawRect(CX, titleY - 0.006, CW, 0.001, C.divider)

    local rowH  = 0.040
    local ctrlW = 0.030
    local curY  = titleY - 0.016

    -- Row 1: Disease selector (Auto + crop candidates) ───────────────────────
    curY = curY - rowH
    do
        self:drawRect(CX, curY, CW, rowH - 0.003, C.row_alt)
        self:drawRect(CX, curY, 0.003, rowH - 0.003, C.green_dim)
        self:drawText(CX + 0.012, curY + (rowH - 0.003) * 0.52, TS_BODY,
            (g_i18n and g_i18n:getText("sf_map_disease_pressure") or "Disease"), C.white, RenderText.ALIGN_LEFT, false)

        local list = self.setDiseaseList or { "" }
        local id   = list[self.setDiseaseIdx or 1] or ""
        local disp
        if id == "" then
            disp = "Auto (by weather)"
        elseif g_i18n and g_i18n:hasText("sf_dis_" .. id) then
            disp = g_i18n:getText("sf_dis_" .. id)
        else
            disp = (id:gsub("_", " "))
        end

        local valW   = 0.150
        local rightEdge = CX + CW - 0.012
        local plusX  = rightEdge - ctrlW
        local labelX = plusX - valW
        local minusX = labelX - ctrlW

        local mHov = self:hitTest(minusX, curY + 0.005, ctrlW, rowH - 0.012, self.mouseX, self.mouseY)
        self:drawRect(minusX, curY + 0.005, ctrlW, rowH - 0.012, mHov and C.back_hover or C.off_bg)
        self:drawText(minusX + ctrlW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            "<", C.white, RenderText.ALIGN_CENTER, true)

        self:drawRect(labelX, curY + 0.005, valW, rowH - 0.012, {0.10, 0.11, 0.15, 0.90})
        self:drawText(labelX + valW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_SMALL,
            disp, C.green, RenderText.ALIGN_CENTER, true)

        local pHov = self:hitTest(plusX, curY + 0.005, ctrlW, rowH - 0.012, self.mouseX, self.mouseY)
        self:drawRect(plusX, curY + 0.005, ctrlW, rowH - 0.012, pHov and C.back_hover or C.off_bg)
        self:drawText(plusX + ctrlW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            ">", C.white, RenderText.ALIGN_CENTER, true)

        self:registerClick("set_disease_dis-1", minusX, curY + 0.005, ctrlW, rowH - 0.012, { step = -1 })
        self:registerClick("set_disease_dis+1", plusX,  curY + 0.005, ctrlW, rowH - 0.012, { step = 1 })
    end

    -- Row 2: Disease pressure (0-100, step 5) ────────────────────────────────
    curY = curY - rowH
    do
        local val = self.setDiseasePressure or 0
        self:drawRect(CX, curY, CW, rowH - 0.003, C.row_alt)
        self:drawRect(CX, curY, 0.003, rowH - 0.003, C.green_dim)
        self:drawText(CX + 0.012, curY + (rowH - 0.003) * 0.52, TS_BODY,
            "Disease pressure (%)", C.white, RenderText.ALIGN_LEFT, false)

        local valW   = 0.065
        local rightEdge = CX + CW - 0.012
        local plusX  = rightEdge - ctrlW
        local labelX = plusX - valW
        local minusX = labelX - ctrlW

        local mHov = self:hitTest(minusX, curY + 0.005, ctrlW, rowH - 0.012, self.mouseX, self.mouseY)
        self:drawRect(minusX, curY + 0.005, ctrlW, rowH - 0.012, mHov and C.back_hover or C.off_bg)
        self:drawText(minusX + ctrlW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            "-", C.white, RenderText.ALIGN_CENTER, true)

        self:drawRect(labelX, curY + 0.005, valW, rowH - 0.012, {0.10, 0.11, 0.15, 0.90})
        self:drawText(labelX + valW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            string.format("%.0f", val), C.green, RenderText.ALIGN_CENTER, true)

        local pHov = self:hitTest(plusX, curY + 0.005, ctrlW, rowH - 0.012, self.mouseX, self.mouseY)
        self:drawRect(plusX, curY + 0.005, ctrlW, rowH - 0.012, pHov and C.back_hover or C.off_bg)
        self:drawText(plusX + ctrlW * 0.5, curY + (rowH - 0.012) * 0.5 - 0.006, TS_BODY,
            "+", C.white, RenderText.ALIGN_CENTER, true)

        self:registerClick("set_disease_p-5", minusX, curY + 0.005, ctrlW, rowH - 0.012, { step = -5 })
        self:registerClick("set_disease_p+5", plusX,  curY + 0.005, ctrlW, rowH - 0.012, { step = 5 })
    end

    -- Hint
    curY = curY - rowH
    self:drawText(CX + 0.012, curY + (rowH - 0.003) * 0.52, TS_SMALL,
        "Auto picks a crop-appropriate disease once pressure is high enough.",
        C.label_dim or {0.65, 0.65, 0.65, 1}, RenderText.ALIGN_LEFT, false)

    -- Apply button
    local saveBtnW = 0.120
    local saveBtnH = 0.032
    local saveBtnX = CX + (CW - saveBtnW) * 0.5
    local saveBtnY = CY_BOT + 0.014
    local saveHov  = self:hitTest(saveBtnX, saveBtnY, saveBtnW, saveBtnH, self.mouseX, self.mouseY)
    self:drawRect(saveBtnX, saveBtnY, saveBtnW, saveBtnH,
        saveHov and {0.10, 0.45, 0.18, 0.95} or {0.07, 0.25, 0.12, 0.90})
    self:drawRect(saveBtnX, saveBtnY, 0.003, saveBtnH, C.green)
    self:drawText(saveBtnX + saveBtnW * 0.5, saveBtnY + saveBtnH * 0.22, TS_SMALL,
        ">  APPLY TO FIELD",
        saveHov and C.white or C.green, RenderText.ALIGN_CENTER, true)
    self:registerClick("set_disease_save", saveBtnX, saveBtnY, saveBtnW, saveBtnH)

    self:drawRect(CX, CY_TOP, CW, 0.001, C.divider)
end

-- ── Admin page ────────────────────────────────────────────
local function getPlayerFieldId()
    local x, z = nil, nil

    if g_localPlayer and g_localPlayer.rootNode then
        local ok, wx, _, wz = pcall(getWorldTranslation, g_localPlayer.rootNode)
        if ok and wx then x, z = wx, wz end
    end
    if x == nil and g_currentMission and g_currentMission.controlledVehicle then
        local v = g_currentMission.controlledVehicle
        if v and v.rootNode then
            local ok, wx, _, wz = pcall(getWorldTranslation, v.rootNode)
            if ok and wx then x, z = wx, wz end
        end
    end

    -- No valid position found - don't pass 0,0 to the field lookup
    if x == nil then return nil end

    if g_fieldManager then
        local ok, field = pcall(function()
            return g_fieldManager:getFieldAtWorldPosition(x, z)
        end)
        if ok and field and field.farmland and field.farmland.id then
            return field.farmland.id
        end
    end

    if g_farmlandManager then
        local ok, farmland = pcall(function()
            return g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        end)
        if ok and farmland and farmland.id and farmland.id > 0 then
            return farmland.id
        end
    end

    return nil
end

local function adminShowMsg(self, msg)
    self.adminMsg = msg
    -- Show full output in the popup dialog
    self.popupMsg  = msg or ""
    -- Split into lines for rendering
    local lines = {}
    for line in (self.popupMsg .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
    end
    self.popupLines  = lines
    self.popupScroll = 0
    self.popupVisible = true
    -- Also show a short blinking warning as before
    if g_currentMission and g_currentMission.hud and
       g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(msg, 5000)
    end
end

function SoilSettingsPanel:drawAdminPage()
    local gui = g_SoilFertilityManager and g_SoilFertilityManager.settingsGUI
    local isAdmin = self:isAdmin()

    local totalH    = self:_adminContentHeight()
    local maxScroll = math.max(0, totalH - CH)
    if self.pageScrollPx > maxScroll then self.pageScrollPx = maxScroll end

    local curY = CY_TOP + self.pageScrollPx
    local rowIdx = 0

    local sections = ADMIN_SECTIONS
    if self.page == PAGE_FIELD_TOOLS then
        sections = FIELD_TOOLS_SECTIONS
    elseif self.page == PAGE_VEHICLE_TOOLS then
        sections = VEHICLE_TOOLS_SECTIONS
    elseif self.page == PAGE_SMART_SYSTEMS then
        sections = SMART_SYSTEMS_SECTIONS
    end

    for _, sec in ipairs(sections) do
        -- Section header (red accent)
        local secY = curY - SEC_H
        curY = secY
        if secY < CY_BOT then break end

        if secY <= CY_TOP then
            self:drawRect(CX, secY, CW, SEC_H, C.title_bg, 0.60)
            self:drawRect(CX, secY, 0.003, SEC_H, ADMIN_ACCENT)
            self:drawText(CX + 0.012, secY + SEC_H * 0.25, TS_SMALL,
                string.upper(tr(sec.headerKey) or ""), {ADMIN_ACCENT[1], ADMIN_ACCENT[2], ADMIN_ACCENT[3], 1.0},
                RenderText.ALIGN_LEFT, true)
        end

        for _, item in ipairs(sec.items) do
            local isAction = (item.stype == "action" or item.stype == "danger")
            local rh = isAction and ADMIN_ACT_H or ADMIN_ROW_H
            
            local itemY = curY - rh
            curY = itemY
            if itemY < CY_BOT then break end

            rowIdx = rowIdx + 1
            if itemY <= CY_TOP then
                if rowIdx % 2 == 0 then self:drawRect(CX, itemY, CW, rh, C.row_alt) end

                if item.stype == "setting" then
                    -- Reuse existing setting row drawing
                    local def = SettingsSchema.byId[item.id]
                    local diffLocked = SIMPLE_ONLY_IDS[item.id] and self.settings and not self.settings:allowsBypassTools()
                    local locked = (not def.localOnly and not isAdmin) or diffLocked
                    local lc = locked and C.lock_text or C.white
                    local dc = locked and {C.lock_text[1]*0.7, C.lock_text[2]*0.7, C.lock_text[3]*0.7, 1} or C.dim
                    if locked then self:drawRect(CX, itemY, 0.003, rh, {0.88, 0.60, 0.18, 0.45}) end
                    local iLabel = tr(def.uiId .. "_short") or item.id
                    local iDescKey = SETTING_DESCS[item.id]
                    local iDesc = (iDescKey and tr(iDescKey)) or ""
                    -- Difficulty lock replaces the description line with the reason.
                    if diffLocked then
                        iDesc = string.format("Locked - %s difficulty", self.settings:getDifficultyName())
                    end
                    self:drawText(CX + (locked and 0.010 or 0.008), itemY + rh * 0.55, TS_BODY, iLabel, lc, RenderText.ALIGN_LEFT, not locked)
                    self:drawText(CX + (locked and 0.010 or 0.008), itemY + rh * 0.15, TS_TINY, iDesc, dc, RenderText.ALIGN_LEFT, false)
                    local ctrlX = CX + CW - 0.012
                    local ctrlY = itemY + (rh - TOGGLE_H) * 0.5
                    if def.type == "boolean" then
                        self:drawToggleControl(ctrlX, ctrlY, item.id, locked)
                    elseif def.type == "number" then
                        self:drawMultiControl(ctrlX, ctrlY, item.id, locked)
                    end
                else
                    -- Action / danger button row
                    local isDanger = (item.stype == "danger")
                    local diffLocked = SIMPLE_ONLY_IDS[item.id] and self.settings and not self.settings:allowsBypassTools()
                    local btnW = 0.130
                    local btnH = rh * 0.72
                    local btnX = CX + CW - btnW - 0.012
                    local btnY = itemY + (rh - btnH) * 0.5
                    local hov  = (not diffLocked) and self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)

                    local aLabel = tr("sf_" .. item.id .. "_label") or item.id
                    local aDesc  = tr("sf_" .. item.id .. "_desc") or ""
                    if diffLocked then
                        aDesc = string.format("Locked - %s difficulty", self.settings:getDifficultyName())
                    end
                    local labelCol = diffLocked and C.lock_text or C.white
                    local descCol  = diffLocked
                        and {C.lock_text[1]*0.7, C.lock_text[2]*0.7, C.lock_text[3]*0.7, 1} or C.dim
                    if diffLocked then self:drawRect(CX, itemY, 0.003, rh, {0.88, 0.60, 0.18, 0.45}) end
                    self:drawText(CX + (diffLocked and 0.010 or 0.008), itemY + rh * 0.55, TS_BODY, aLabel, labelCol, RenderText.ALIGN_LEFT, not diffLocked)
                    self:drawText(CX + (diffLocked and 0.010 or 0.008), itemY + rh * 0.15, TS_TINY, aDesc, descCol, RenderText.ALIGN_LEFT, false)

                    local bgCol, acCol, btnTxtCol, btnTxt
                    if diffLocked then
                        -- Greyed, non-interactive "LOCKED" pill with the orange lock accent.
                        bgCol     = {0.14, 0.14, 0.16, 0.80}
                        acCol     = {0.88, 0.60, 0.18, 0.45}
                        btnTxtCol = C.lock_text
                        btnTxt    = "LOCKED"
                    else
                        bgCol = isDanger
                            and (hov and {0.65, 0.10, 0.10, 0.95} or {0.30, 0.06, 0.06, 0.85})
                            or  (hov and {0.10, 0.35, 0.15, 0.95} or {0.08, 0.18, 0.10, 0.85})
                        acCol     = isDanger and ADMIN_ACCENT or C.green
                        btnTxtCol = hov and {1,1,1,1} or {0.75,0.75,0.75,1}
                        btnTxt    = isDanger and "!! " .. aLabel or ">  " .. aLabel
                    end
                    self:drawRect(btnX, btnY, btnW, btnH, bgCol)
                    self:drawRect(btnX, btnY, 0.002, btnH, acCol)
                    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.20, TS_TINY,
                        btnTxt, btnTxtCol, RenderText.ALIGN_CENTER, isDanger and not diffLocked)
                    -- No click registration when locked - the button is inert, mirroring
                    -- how drawToggleControl/drawMultiControl skip clicks when locked.
                    if not diffLocked then
                        self:registerClick("admin_action_" .. item.id, btnX, btnY, btnW, btnH,
                            { actionId = item.id, gui = gui })
                    end
                end

                self:drawRect(CX, itemY, CW, 0.0005, C.divider, 0.35)
            end
        end

        curY = curY - 0.005
    end

    -- Last result message at bottom
    if self.adminMsg then
        local msgY = CY_BOT + 0.004
        if msgY <= CY_TOP then
            self:drawText(CX + 0.006, msgY, TS_TINY,
                "Last: " .. self.adminMsg:sub(1, 90),
                {0.55, 0.80, 0.55, 0.85}, RenderText.ALIGN_LEFT, false)
        end
    end

    -- Scrollbar in right gutter (only when content overflows)
    if maxScroll > 0 then
        self:_drawPageScrollBar(CX + CW + 0.004, CY_BOT, 0.009, CH,
            self.pageScrollPx, maxScroll, ADMIN_ACCENT)
    end

    -- Thin top divider
    self:drawRect(CX, CY_TOP, CW, 0.001, C.divider)
end

-- ── Admin Output Popup Dialog ──────────────────────────────
function SoilSettingsPanel:drawPopupDialog()
    if not self.popupVisible then return end

    -- Popup dimensions
    local DW  = 0.54
    local DH  = 0.52
    local DX  = (1 - DW) / 2
    local DY  = (1 - DH) / 2
    local DPAD = 0.016

    -- Line rendering config
    local LINE_H   = TS_TINY + 0.004
    local MAX_LINES = math.floor((DH - 0.095) / LINE_H)

    local lines = self.popupLines or {}
    local total = #lines
    -- Clamp scroll
    local maxScroll = math.max(0, total - MAX_LINES)
    if self.popupScroll > maxScroll then self.popupScroll = maxScroll end

    -- Dimmed overlay behind popup
    self:drawRect(0, 0, 1, 1, {0, 0, 0, 0.55})

    -- Shadow
    self:drawRect(DX + 0.005, DY - 0.005, DW, DH, C.shadow, 0.65)

    -- Background
    self:drawRect(DX, DY, DW, DH, {0.06, 0.07, 0.11, 0.98})

    -- Border
    local bw = 0.0015
    self:drawRect(DX,           DY,          DW, bw, ADMIN_ACCENT, 0.80)
    self:drawRect(DX,           DY + DH - bw, DW, bw, ADMIN_ACCENT, 0.80)
    self:drawRect(DX,           DY,          bw, DH, ADMIN_ACCENT, 0.80)
    self:drawRect(DX + DW - bw, DY,          bw, DH, ADMIN_ACCENT, 0.80)

    -- Title bar
    local TH = 0.036
    local TY = DY + DH - TH
    self:drawRect(DX, TY, DW, TH, {0.08, 0.09, 0.14, 1.0})
    self:drawRect(DX, TY, 0.004, TH, ADMIN_ACCENT)
    self:drawText(DX + DPAD, TY + TH * 0.28, TS_SMALL,
        "ADMIN COMMAND OUTPUT", {ADMIN_ACCENT[1], ADMIN_ACCENT[2], ADMIN_ACCENT[3], 1.0},
        RenderText.ALIGN_LEFT, true)

    -- Close [X] button in title bar
    local cbW = 0.034
    local cbH = TH * 0.62
    local cbX = DX + DW - cbW - 0.010
    local cbY = TY + (TH - cbH) * 0.5
    local cbHov = self:hitTest(cbX, cbY, cbW, cbH, self.mouseX, self.mouseY)
    self:drawRect(cbX, cbY, cbW, cbH, cbHov and C.close_hover or {0.18, 0.10, 0.10, 0.80})
    self:drawText(cbX + cbW * 0.5, cbY + cbH * 0.18, TS_SMALL, "[X]",
        cbHov and {1,1,1,1} or {0.70,0.35,0.35,1}, RenderText.ALIGN_CENTER, true)
    self:registerClick("popup_close", cbX, cbY, cbW, cbH)

    -- Content area
    local contentY_top = TY - 0.006
    local contentY_bot = DY + 0.044   -- room for close button at bottom
    local textX = DX + DPAD
    local curY  = contentY_top

    for i = self.popupScroll + 1, math.min(self.popupScroll + MAX_LINES, total) do
        local line = lines[i]
        curY = curY - LINE_H
        if curY < contentY_bot then break end

        -- Colour-code header/separator lines
        local col = C.white
        if line:match("^===") or line:match("^---") then
            col = {ADMIN_ACCENT[1], ADMIN_ACCENT[2], ADMIN_ACCENT[3], 0.90}
        elseif line:match("^  ") then
            col = {0.75, 0.85, 0.75, 1.0}
        end
        self:drawText(textX, curY + LINE_H * 0.15, TS_TINY, line, col, RenderText.ALIGN_LEFT, false)
    end

    -- Scroll buttons (right side, only when content overflows)
    if total > MAX_LINES then
        local sbW = 0.032
        local sbH = 0.034
        local sbX = DX + DW - sbW - 0.006
        local upY  = contentY_top - sbH - 0.004
        local dnY  = upY - sbH - 0.004

        local upHov = self:hitTest(sbX, upY, sbW, sbH, self.mouseX, self.mouseY)
        local dnHov = self:hitTest(sbX, dnY, sbW, sbH, self.mouseX, self.mouseY)
        local canUp = self.popupScroll > 0
        local canDn = self.popupScroll < maxScroll

        self:drawRect(sbX, upY, sbW, sbH,
            upHov and canUp and {0.25, 0.50, 0.30, 0.95} or {0.10, 0.15, 0.12, 0.80})
        self:drawText(sbX + sbW * 0.5, upY + sbH * 0.18, TS_SMALL,
            "^", canUp and {1,1,1,1} or {0.35,0.35,0.35,1}, RenderText.ALIGN_CENTER, true)

        self:drawRect(sbX, dnY, sbW, sbH,
            dnHov and canDn and {0.25, 0.50, 0.30, 0.95} or {0.10, 0.15, 0.12, 0.80})
        self:drawText(sbX + sbW * 0.5, dnY + sbH * 0.18, TS_SMALL,
            "v", canDn and {1,1,1,1} or {0.35,0.35,0.35,1}, RenderText.ALIGN_CENTER, true)

        self:registerClick("popup_scroll_up", sbX, upY, sbW, sbH)
        self:registerClick("popup_scroll_dn", sbX, dnY, sbW, sbH)

        local scrollInfo = string.format("Lines %d-%d of %d",
            self.popupScroll + 1,
            math.min(self.popupScroll + MAX_LINES, total),
            total)
        self:drawText(DX + DPAD, DY + 0.028, TS_TINY, scrollInfo,
            {0.45, 0.55, 0.45, 0.80}, RenderText.ALIGN_LEFT, false)
    end

    -- Bottom "Close" button
    local btnW = 0.100
    local btnH = 0.028
    local btnX = DX + (DW - btnW) * 0.5
    local btnY = DY + 0.008
    local btnHov = self:hitTest(btnX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(btnX, btnY, btnW, btnH,
        btnHov and {0.65, 0.10, 0.10, 0.95} or {0.20, 0.06, 0.06, 0.90})
    self:drawRect(btnX, btnY, 0.002, btnH, ADMIN_ACCENT)
    self:drawText(btnX + btnW * 0.5, btnY + btnH * 0.20, TS_SMALL,
        "[X] Close",
        btnHov and {1,1,1,1} or {0.80,0.75,0.75,1},
        RenderText.ALIGN_CENTER, true)
    self:registerClick("popup_close", btnX, btnY, btnW, btnH)
end

-- ── Experimental confirmation (drawn, in this panel's frame) ──────────────
-- Same construction as drawPopupDialog: dim overlay, shadow, bordered box,
-- accent title bar, hit-tested buttons registered by click id. The accent is
-- the panel's own warning amber (C.lock_text), the colour this panel already
-- uses to mark a locked system, so the prompt reads as part of that language.
function SoilSettingsPanel:drawConfirmDialog()
    if not self.confirmVisible then return end

    local WARN = {C.lock_text[1], C.lock_text[2], C.lock_text[3]}

    local DW, DH = 0.44, 0.26
    local DX, DY = (1 - DW) / 2, (1 - DH) / 2
    local DPAD   = 0.016

    -- Dim everything behind, including the panel itself.
    self:drawRect(0, 0, 1, 1, {0, 0, 0, 0.60})
    self:drawRect(DX + 0.004, DY - 0.004, DW, DH, C.shadow, 0.65)
    self:drawRect(DX, DY, DW, DH, {0.06, 0.07, 0.11, 0.99})

    local bw = 0.0015
    self:drawRect(DX,            DY,             DW, bw, WARN, 0.85)
    self:drawRect(DX,            DY + DH - bw,   DW, bw, WARN, 0.85)
    self:drawRect(DX,            DY,             bw, DH, WARN, 0.85)
    self:drawRect(DX + DW - bw,  DY,             bw, DH, WARN, 0.85)

    -- Title bar
    local TH = 0.036
    local TY = DY + DH - TH
    self:drawRect(DX, TY, DW, TH, {0.10, 0.08, 0.04, 1.0})
    self:drawRect(DX, TY, 0.004, TH, WARN)
    self:drawText(DX + DPAD, TY + TH * 0.28, TS_SMALL,
        tr("sf_exp_confirm_title", "Experimental Systems"),
        {WARN[1], WARN[2], WARN[3], 1.0}, RenderText.ALIGN_LEFT, true)

    -- Body: wrapped so a long translation cannot run past the box.
    local textW = DW - DPAD * 2
    local LINE_H = TS_SMALL + 0.006
    local curY = TY - 0.014
    for _, line in ipairs(wrapText(self.confirmText or "", TS_SMALL, textW)) do
        curY = curY - LINE_H
        self:drawText(DX + DPAD, curY, TS_SMALL, line, C.white, RenderText.ALIGN_LEFT, false)
    end

    -- The question, set apart from the warning body.
    curY = curY - LINE_H * 1.2
    self:drawText(DX + DW * 0.5, curY, TS_BODY, self.confirmQuestion or "",
        {WARN[1], WARN[2], WARN[3], 1.0}, RenderText.ALIGN_CENTER, true)

    -- Buttons. Abort sits left and is styled as the safe, ordinary choice;
    -- Confirm sits right in warning amber, because it is the one with teeth.
    local btnW, btnH = 0.130, 0.030
    local gap = 0.014
    local btnY = DY + 0.020
    local abortX = DX + (DW - (btnW * 2 + gap)) * 0.5
    local okX    = abortX + btnW + gap

    local abortHov = self:hitTest(abortX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(abortX, btnY, btnW, btnH,
        abortHov and {0.22, 0.50, 0.28, 0.95} or {0.12, 0.16, 0.13, 0.92})
    self:drawRect(abortX, btnY, 0.002, btnH, C.green_dim)
    self:drawText(abortX + btnW * 0.5, btnY + btnH * 0.22, TS_SMALL,
        tr("sf_exp_confirm_no", "Abort"),
        abortHov and C.white or {0.80, 0.85, 0.80, 1}, RenderText.ALIGN_CENTER, true)
    self:registerClick("exp_confirm_no", abortX, btnY, btnW, btnH)

    local okHov = self:hitTest(okX, btnY, btnW, btnH, self.mouseX, self.mouseY)
    self:drawRect(okX, btnY, btnW, btnH,
        okHov and {0.70, 0.45, 0.10, 0.95} or {0.22, 0.15, 0.05, 0.92})
    self:drawRect(okX, btnY, 0.002, btnH, WARN)
    self:drawText(okX + btnW * 0.5, btnY + btnH * 0.22, TS_SMALL,
        tr("sf_exp_confirm_yes", "Confirm"),
        okHov and C.white or {0.90, 0.80, 0.65, 1}, RenderText.ALIGN_CENTER, true)
    self:registerClick("exp_confirm_yes", okX, btnY, btnW, btnH)
end

-- ── Setting row ────────────────────────────────────────────
function SoilSettingsPanel:drawSettingRow(x, y, w, settingId, rowIdx, isAdmin)
    local def = SettingsSchema.byId[settingId]
    if not def then return end

    -- #740: world climate gets a dedicated chip picker (farm-terms wetness preview).
    if settingId == "weatherSource" then
        self:drawClimateSettingRow(x, y, w, rowIdx, isAdmin)
        return
    end

    local rh = ROW_H

    -- Alternating row background
    if rowIdx % 2 == 0 then
        self:drawRect(x, y, w, rh, C.row_alt)
    end

    -- Hover highlight (only on the left/label portion)
    if self:hitTest(x, y, w, rh, self.mouseX, self.mouseY) then
        self:drawRect(x, y, w, rh, C.row_hover)
    end

    local locked = not def.localOnly and not isAdmin
    local labelColor = locked and C.lock_text or C.white
    local descColor  = locked and {C.lock_text[1]*0.7, C.lock_text[2]*0.7, C.lock_text[3]*0.7, 1} or C.dim

    -- Lock indicator
    if locked then
        self:drawRect(x, y, 0.003, rh, {0.88, 0.60, 0.18, 0.45})
    end

    -- Setting label
    local labelX = x + (locked and 0.010 or 0.008)
    local labelY = y + rh * 0.52
    local labelText = tr(def.uiId .. "_short", settingId)
    self:drawText(labelX, labelY, TS_BODY, labelText, labelColor, RenderText.ALIGN_LEFT, not locked)

    -- Description
    local descKey = SETTING_DESCS[settingId]
    local desc = (descKey and tr(descKey)) or ""
    self:drawText(labelX, y + rh * 0.15, TS_TINY, desc, descColor, RenderText.ALIGN_LEFT, false)

    -- Control (toggle or multi-select) on the right
    local ctrlX = x + w - 0.012
    local ctrlY = y + (rh - TOGGLE_H) / 2

    if def.type == "boolean" then
        self:drawToggleControl(ctrlX, ctrlY, settingId, locked)
    elseif def.type == "number" then
        self:drawMultiControl(ctrlX, ctrlY, settingId, locked)
    end

    -- Row bottom divider
    self:drawRect(x, y, w, 0.0005, C.divider, 0.35)
end

-- Wetness bars for climate chips (visual only; 1=real/opt-out flat, 2-4 = arid..wet).
local CLIMATE_WETNESS = { 0, 1, 2, 3 }
local CLIMATE_CHIP_COLORS = {
    {0.55, 0.58, 0.62, 1.0}, -- real sky (neutral)
    {0.78, 0.62, 0.28, 1.0}, -- arid
    {0.35, 0.72, 0.48, 1.0}, -- normal
    {0.28, 0.55, 0.88, 1.0}, -- wet
}

--- #740 creative climate picker: four chips with wetness preview + selected farm-terms blurb.
function SoilSettingsPanel:drawClimateSettingRow(x, y, w, rowIdx, isAdmin)
    local def = SettingsSchema.byId.weatherSource
    if not def then return end
    local rh = CLIMATE_ROW_H
    local locked = not def.localOnly and not isAdmin

    if rowIdx % 2 == 0 then
        self:drawRect(x, y, w, rh, C.row_alt)
    end
    if locked then
        self:drawRect(x, y, 0.003, rh, {0.88, 0.60, 0.18, 0.45})
    end

    local labelX = x + (locked and 0.010 or 0.008)
    local labelColor = locked and C.lock_text or C.white
    local descColor  = locked and {C.lock_text[1]*0.7, C.lock_text[2]*0.7, C.lock_text[3]*0.7, 1} or C.dim

    self:drawText(labelX, y + rh - 0.018, TS_BODY,
        tr("sf_ws_short", "World Climate"), labelColor, RenderText.ALIGN_LEFT, not locked)
    self:drawText(labelX, y + rh - 0.032, TS_TINY,
        tr("sf_desc_weatherSource", ""), descColor, RenderText.ALIGN_LEFT, false)
    self:drawText(labelX, y + rh - 0.044, TS_TINY,
        tr("sf_ws_world_note", "World setting - admin only in multiplayer; changes soil for everyone."),
        locked and descColor or {0.88, 0.72, 0.35, 1.0}, RenderText.ALIGN_LEFT, false)

    local val = self:getValue("weatherSource")
    if val == nil then val = def.default or 3 end

    local chipPad = 0.006
    local chipW = (w - 0.016 - chipPad * 3) / 4
    local chipH = 0.038
    local chipY = y + 0.028
    local chipX0 = x + 0.008

    for i = 1, 4 do
        local cx = chipX0 + (i - 1) * (chipW + chipPad)
        local selected = (val == i)
        local hover = not locked and self:hitTest(cx, chipY, chipW, chipH, self.mouseX, self.mouseY)
        local accent = CLIMATE_CHIP_COLORS[i]
        local bg = selected and {accent[1] * 0.35, accent[2] * 0.35, accent[3] * 0.35, 0.95}
            or (hover and C.back_hover or {0.10, 0.11, 0.15, 0.92})
        self:drawRect(cx, chipY, chipW, chipH, bg)
        if selected then
            self:drawRect(cx, chipY, chipW, 0.0022, accent)
            self:drawRect(cx, chipY + chipH - 0.0022, chipW, 0.0022, accent)
        end

        -- Wetness preview bars (real sky = dashed flat line feel via zero fill + dim track)
        local bars = CLIMATE_WETNESS[i] or 0
        local barW = 0.008
        local barGap = 0.003
        local barMaxH = 0.014
        local barsX = cx + chipW * 0.5 - (4 * barW + 3 * barGap) * 0.5
        local barsY = chipY + chipH - 0.018
        for b = 1, 4 do
            local bx = barsX + (b - 1) * (barW + barGap)
            local filled = (b <= bars)
            local bh = barMaxH * (0.35 + 0.22 * b)
            self:drawRect(bx, barsY, barW, bh, filled and accent or {0.22, 0.24, 0.28, 0.90})
        end

        local optKey = "sf_ws_" .. i
        local optLabel = tr(optKey, tostring(i))
        self:drawText(cx + chipW * 0.5, chipY + 0.004, TS_TINY,
            optLabel, selected and C.white or C.dim, RenderText.ALIGN_CENTER, selected)

        if not locked then
            self:registerClick("climate_" .. i, cx, chipY, chipW, chipH,
                { id = "weatherSource", value = i })
        end
    end

    local blurb = tr("sf_ws_blurb_" .. tostring(val), "")
    self:drawText(labelX, y + 0.008, TS_TINY, blurb, descColor, RenderText.ALIGN_LEFT, false)
    self:drawRect(x, y, w, 0.0005, C.divider, 0.35)
end

-- ── Toggle control [ON] [OFF] ─────────────────────────────
function SoilSettingsPanel:drawToggleControl(rightX, y, settingId, locked)
    local val = self:getValue(settingId)
    local isOn = val == true

    -- Pill: [OFF] on left, [ON] on right
    local offX = rightX - TOGGLE_W * 2 - TOGGLE_GAP
    local onX  = rightX - TOGGLE_W

    -- OFF pill
    local offHover = not locked and self:hitTest(offX, y, TOGGLE_W, TOGGLE_H, self.mouseX, self.mouseY)
    local offBg    = (not isOn) and C.dim or C.off_bg
    self:drawRect(offX, y, TOGGLE_W, TOGGLE_H, offBg, (not isOn) and 0.90 or 0.60)
    self:drawText(offX + TOGGLE_W * 0.5, y + TOGGLE_H * 0.20, TS_TINY,
        "OFF", (not isOn) and C.white or C.off_text, RenderText.ALIGN_CENTER, not isOn)

    -- ON pill
    local onHover  = not locked and self:hitTest(onX, y, TOGGLE_W, TOGGLE_H, self.mouseX, self.mouseY)
    local onBg     = isOn and C.on_bg or C.off_bg
    self:drawRect(onX, y, TOGGLE_W, TOGGLE_H, onBg, isOn and 1.0 or 0.60)
    self:drawText(onX + TOGGLE_W * 0.5, y + TOGGLE_H * 0.20, TS_TINY,
        "ON", isOn and C.on_text or C.off_text, RenderText.ALIGN_CENTER, isOn)

    if not locked then
        self:registerClick("toggle_off_" .. settingId, offX, y, TOGGLE_W, TOGGLE_H,
            { id = settingId, value = false })
        self:registerClick("toggle_on_" .. settingId, onX, y, TOGGLE_W, TOGGLE_H,
            { id = settingId, value = true })
    end
end

-- ── Multi-select control [◄ Option ►] ────────────────────
function SoilSettingsPanel:drawMultiControl(rightX, y, settingId, locked)
    local opts    = MULTI_OPTS[settingId]
    if not opts then return end
    -- Map the setting value to its option label via def.min, not a fixed base of 1.
    -- activeMapLayer ranges 0-10 (0=Off → sf_layer_1); all other number settings
    -- start at 1, where val - min + 1 == val and behaviour is unchanged.
    local def        = SettingsSchema.byId[settingId]
    local minVal     = (def and def.min) or 1
    local val        = self:getValue(settingId)
    if val == nil then val = (def and def.default) or minVal end
    local currentKey = opts[val - minVal + 1] or opts[1] or ""
    local current    = (currentKey ~= "" and tr(currentKey)) or currentKey or "?"

    local arrowW = 0.022
    local labelW = MULTI_W - arrowW * 2
    local totalX = rightX - MULTI_W
    local leftX  = totalX
    local midX   = totalX + arrowW
    local rightBX = totalX + arrowW + labelW

    -- Left arrow [◄]
    local lHover = not locked and self:hitTest(leftX, y, arrowW, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(leftX, y, arrowW, TOGGLE_H, lHover and C.back_hover or C.off_bg)
    self:drawText(leftX + arrowW * 0.5, y + TOGGLE_H * 0.18, TS_TINY,
        "<", lHover and C.green or C.dim, RenderText.ALIGN_CENTER, true)

    -- Middle label
    self:drawRect(midX, y, labelW, TOGGLE_H, {0.10, 0.11, 0.15, 0.90})
    self:drawText(midX + labelW * 0.5, y + TOGGLE_H * 0.18, TS_TINY,
        current, C.white, RenderText.ALIGN_CENTER, false)

    -- Right arrow [►]
    local rHover = not locked and self:hitTest(rightBX, y, arrowW, TOGGLE_H, self.mouseX, self.mouseY)
    self:drawRect(rightBX, y, arrowW, TOGGLE_H, rHover and C.back_hover or C.off_bg)
    self:drawText(rightBX + arrowW * 0.5, y + TOGGLE_H * 0.18, TS_TINY,
        ">", rHover and C.green or C.dim, RenderText.ALIGN_CENTER, true)

    if not locked then
        self:registerClick("multi_prev_" .. settingId, leftX, y, arrowW, TOGGLE_H,
            { id = settingId, dir = -1, opts = opts })
        self:registerClick("multi_next_" .. settingId, rightBX, y, arrowW, TOGGLE_H,
            { id = settingId, dir = 1, opts = opts })
    end
end

-- ── Mouse event ───────────────────────────────────────────
function SoilSettingsPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.isVisible then return false end

    -- Always update hover state
    self.mouseX = posX
    self.mouseY = posY

    if not isDown then return true end  -- consume all events when open
    if button ~= Input.MOUSE_BUTTON_LEFT then return true end

    -- Check registered click rects
    for _, r in ipairs(self._clickRects) do
        if self:hitTest(r.x, r.y, r.w, r.h, posX, posY) then
            self:handleClick(r.id, r.data)
            return true
        end
    end

    -- Click outside panel = close (but not while a modal is asking something).
    -- The confirmation must be answered or aborted on its own buttons; closing
    -- the panel out from under it would leave the question unanswered.
    if not self.popupVisible and not self.confirmVisible
       and not self:hitTest(PX, PY, PW, PH, posX, posY) then
        self:close()
        return true
    end

    return true
end

function SoilSettingsPanel:handleClick(id, data)
    if id == "exp_confirm_yes" then
        self:_acceptConfirm()

    elseif id == "exp_confirm_no" then
        self:_dismissConfirm()

    elseif id == "close" then
        self:close()

    elseif id == "back" then
        if self.page == PAGE_FIELD_TOOLS or self.page == PAGE_VEHICLE_TOOLS
           or self.page == PAGE_SET_STATE or self.page == PAGE_SET_DISEASE
           or self.page == PAGE_SMART_SYSTEMS then
            self.page = PAGE_ADMIN
        else
            self.page = PAGE_LANDING
            self.activeCatIdx = nil
        end
        self.pageScrollPx = 0

    elseif id == "reset_cat" then
        self:resetCurrentCategory()

    elseif id:sub(1, 4) == "cat_" then
        local idx = tonumber(id:sub(5))
        if idx and CATEGORIES[idx] then
            self.activeCatIdx = idx
            self.page = PAGE_CATEGORY
            self.pageScrollPx = 0
        end

    elseif id:sub(1, 11) == "toggle_off_" then
        if data then self:requestChange(data.id, false) end

    elseif id:sub(1, 10) == "toggle_on_" then
        if data then self:requestChange(data.id, true) end

    elseif id:sub(1, 8) == "climate_" then
        if data and data.id and data.value then
            self:requestChange(data.id, data.value)
        end

    elseif id:sub(1, 10) == "multi_prev" then
        if data then
            -- Wrap within the schema's [min, max] range (activeMapLayer starts at 0)
            local def  = SettingsSchema.byId[data.id]
            local minV = (def and def.min) or 1
            local maxV = (def and def.max) or #data.opts
            local cur  = self:getValue(data.id) or minV
            local nxt  = cur - 1
            if nxt < minV then nxt = maxV end
            self:requestChange(data.id, nxt)
        end

    elseif id:sub(1, 10) == "multi_next" then
        if data then
            local def  = SettingsSchema.byId[data.id]
            local minV = (def and def.min) or 1
            local maxV = (def and def.max) or #data.opts
            local cur  = self:getValue(data.id) or minV
            local nxt  = cur + 1
            if nxt > maxV then nxt = minV end
            self:requestChange(data.id, nxt)
        end

    elseif id == "page_scroll_up" then
        self.pageScrollPx = math.max(0, self.pageScrollPx - ROW_H)

    elseif id == "page_scroll_dn" then
        self.pageScrollPx = self.pageScrollPx + ROW_H
        -- Upper clamp happens in draw functions on next frame

    elseif id == "popup_close" then
        self.popupVisible = false
        self.popupMsg     = nil
        self.popupLines   = nil
        self.popupScroll  = 0

    elseif id == "popup_scroll_up" then
        if self.popupScroll > 0 then
            self.popupScroll = self.popupScroll - 1
        end

    elseif id == "popup_scroll_dn" then
        local total = self.popupLines and #self.popupLines or 0
        local DH = 0.52
        local LINE_H = TS_TINY + 0.004
        local MAX_LINES = math.floor((DH - 0.095) / LINE_H)
        local maxScroll = math.max(0, total - MAX_LINES)
        if self.popupScroll < maxScroll then
            self.popupScroll = self.popupScroll + 1
        end

    elseif id == "open_admin" then
        self.page = PAGE_ADMIN
        self.adminMsg = nil
        self.pageScrollPx = 0

    elseif id:sub(1, 10) == "set_state_" then
        if id == "set_state_save" then
            if not self:isAdmin() then
                adminShowMsg(self, "Admin only: field state can only be changed by server admins.")
                return
            end
            if g_SoilFertilityManager and g_SoilFertilityManager.settingsGUI then
                local sd = self.setStateData
                local msg = g_SoilFertilityManager.settingsGUI:consoleCommandSetState(
                    tostring(self.setStateFieldId), tostring(sd.N), tostring(sd.P), tostring(sd.K), tostring(sd.pH), tostring(sd.OM)
                )
                self.page = PAGE_ADMIN
                adminShowMsg(self, msg)
            end
        else
            if data then
                local nVal = (self.setStateData[data.k] or 0) + data.step
                if nVal < data.min then nVal = data.min end
                if nVal > data.max then nVal = data.max end
                self.setStateData[data.k] = nVal
            end
        end

    elseif id:sub(1, 12) == "set_disease_" then
        if id == "set_disease_save" then
            if not self:isAdmin() then
                adminShowMsg(self, "Admin only: field state can only be changed by server admins.")
                return
            end
            local sfm = g_SoilFertilityManager
            if sfm and sfm.soilSystem and sfm.soilSystem.debugSetDisease and self.setDiseaseFieldId then
                local list = self.setDiseaseList or { "" }
                local did  = list[self.setDiseaseIdx or 1]
                if did == "" then did = nil end
                local ok, infoD = sfm.soilSystem:debugSetDisease(
                    self.setDiseaseFieldId, self.setDiseasePressure or 0, did)
                self.page = PAGE_ADMIN
                if ok then
                    adminShowMsg(self, string.format("Field %d: disease pressure set to %d%% (%s).",
                        self.setDiseaseFieldId, math.floor((self.setDiseasePressure or 0) + 0.5),
                        (infoD and infoD.disease) or "auto"))
                else
                    adminShowMsg(self, "Could not set disease on this field.")
                end
            end
        elseif data then
            if id:sub(1, 15) == "set_disease_dis" then
                local n = #(self.setDiseaseList or { "" })
                self.setDiseaseIdx = ((self.setDiseaseIdx or 1) - 1 + data.step) % n + 1
            else
                local v = (self.setDiseasePressure or 0) + data.step
                if v < 0 then v = 0 end
                if v > 100 then v = 100 end
                self.setDiseasePressure = v
            end
        end

    elseif id:sub(1, 13) == "admin_action_" then
        local gui = g_SoilFertilityManager and g_SoilFertilityManager.settingsGUI
        local actionId = data and data.actionId
        local msg = "Action failed."

        -- Bypass tools (sim-rescaling editors + field cheat/test utilities) are Simple
        -- difficulty only. One gate for every such action - the set lives in
        -- SIMPLE_ONLY_IDS, the difficulty predicate in Settings:allowsBypassTools().
        if SIMPLE_ONLY_IDS[actionId] and self.settings and not self.settings:allowsBypassTools() then
            adminShowMsg(self, string.format("Locked on %s difficulty. Available on Simple only.",
                self.settings:getDifficultyName()))
            return
        end

        -- Handle navigation actions first
        if actionId == "nav_field_tools" then
            self.page = PAGE_FIELD_TOOLS
            self.pageScrollPx = 0
            return
        elseif actionId == "nav_vehicle_tools" then
            self.page = PAGE_VEHICLE_TOOLS
            self.pageScrollPx = 0
            return
        elseif actionId == "nav_smart_systems" then
            self.page = PAGE_SMART_SYSTEMS
            self.pageScrollPx = 0
            return
        elseif actionId == "nav_tuning" then
            -- Open Constants Tuning Editor (separate panel). Bypass tool - the
            -- SIMPLE_ONLY_IDS gate above already blocked this on Realistic/Hardcore.
            if g_SoilFertilityManager and g_SoilFertilityManager.tuningPanel then
                self:close()
                g_SoilFertilityManager.tuningPanel:open()
            end
            return
        elseif actionId == "nav_crop_tuning" then
            -- Open Crop Tuning Editor (per-crop N/P/K, #717). Bypass tool - gated above.
            if g_SoilFertilityManager and g_SoilFertilityManager.cropTuningPanel then
                self:close()
                g_SoilFertilityManager.cropTuningPanel:open()
            end
            return
        end

        -- Mutating actions are admin-only. Setting ROWS are already locked for
        -- non-admins, but these buttons were not - a non-admin clicking Reset
        -- mutated local state and desynced the client until the next full sync.
        -- Read-only actions (field info / forecast / list) stay open to everyone.
        local mutatingActions = {
            admin_save = true, admin_reset = true, admin_drain = true,
            admin_field_set_state = true, admin_field_set_disease = true, admin_field_recover = true,
        }
        if mutatingActions[actionId] and not self:isAdmin() then
            adminShowMsg(self, "Admin only: this action is restricted to server admins.")
            return
        end

        if gui and actionId then
            if actionId == "admin_save" then
                msg = gui:consoleCommandSaveData()
            elseif actionId == "admin_reset" then
                msg = gui:consoleCommandResetSettings()
            elseif actionId == "admin_drain" then
                msg = gui:consoleCommandDrainVehicle()
            elseif actionId == "admin_field_info" then
                local fid = getPlayerFieldId()
                if fid then
                    msg = gui:consoleCommandFieldInfo(tostring(fid))
                else
                    msg = "No field at your current position."
                end
            elseif actionId == "admin_field_forecast" then
                local fid = getPlayerFieldId()
                if fid then
                    msg = gui:consoleCommandFieldForecast(tostring(fid))
                else
                    msg = "No field at your current position."
                end
            elseif actionId == "admin_list_fields" then
                msg = gui:consoleCommandListFields()
            elseif actionId == "admin_field_set_state" then
                local fid = getPlayerFieldId()
                if fid then
                    self.page = PAGE_SET_STATE
                    self.setStateFieldId = fid
                    if g_SoilFertilityManager.soilSystem then
                        local info = g_SoilFertilityManager.soilSystem.fieldData[fid]
                        if info then
                            self.setStateData = {
                                N = info.nitrogen or 50,
                                P = info.phosphorus or 50,
                                K = info.potassium or 50,
                                pH = math.floor((info.pH or 6.5)*10)/10,
                                OM = math.floor((info.organicMatter or 5.0)*10)/10
                            }
                        else
                            self.setStateData = {N=50, P=50, K=50, pH=6.5, OM=5.0}
                        end
                    end
                    return -- Do not show msg
                else
                    msg = "No field at your current position."
                end
            elseif actionId == "admin_field_set_disease" then
                local fid = getPlayerFieldId()
                if fid then
                    self.page = PAGE_SET_DISEASE
                    self.setDiseaseFieldId = fid
                    self.setDiseasePressure = 0
                    self.setDiseaseList = { "" }  -- index 1 = auto-pick by weather
                    self.setDiseaseIdx = 1
                    if g_SoilFertilityManager.soilSystem then
                        local info = g_SoilFertilityManager.soilSystem.fieldData[fid]
                        if info then
                            self.setDiseasePressure = math.floor((info.diseasePressure or 0) + 0.5)
                            if SoilDiseaseSystem then
                                local cands = SoilDiseaseSystem.cropDiseases(info.lastCrop)
                                if cands then
                                    for _, cid in ipairs(cands) do
                                        self.setDiseaseList[#self.setDiseaseList + 1] = cid
                                    end
                                end
                            end
                        end
                    end
                    return -- Do not show msg
                else
                    msg = "No field at your current position."
                end
            elseif actionId == "admin_field_recover" then
                local fid = getPlayerFieldId()
                if fid then
                    msg = gui:consoleCommandRecoverField(tostring(fid))
                else
                    msg = "No field at your current position."
                end
            end
        end
        adminShowMsg(self, msg or "Done.")
    end
end

function SoilSettingsPanel:resetCurrentCategory()
    if not self.activeCatIdx then return end
    local cat = CATEGORIES[self.activeCatIdx]
    if not cat then return end

    for _, sec in ipairs(cat.sections) do
        for _, settingId in ipairs(sec.items) do
            local def = SettingsSchema.byId[settingId]
            if def and def.default ~= nil then
                -- skipConfirm: a reset is already a deliberate act, it runs in a
                -- loop that a modal would break, and for the experimental gate it
                -- only ever restores the LOCKED default. Nothing to warn about.
                self:requestChange(settingId, def.default, true)
            end
        end
    end
    SoilLogger.info("SoilSettingsPanel: reset category '%s' to defaults", cat.id)
end