-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Variable Rate Panel
-- =========================================================
-- In-vehicle overlay for System 3 (Variable Rate Application).
-- Shows a row of colored bars — one per active boom section —
-- visualising the computed rate multiplier for each section.
--   Red   bar = deep deficit, high rate (>1.0x)
--   Yellow bar = moderate deficit, near-normal rate (~1.0x)
--   Green  bar = well stocked, low rate (<1.0x)
-- Positioned below the See & Spray panel (or Smart Sensor
-- panel if See & Spray is disabled).
-- Style matches SoilHUD / rate panel exactly.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilVariableRatePanel
SoilVariableRatePanel = {}
local SoilVariableRatePanel_mt = Class(SoilVariableRatePanel)

SoilVariableRatePanel.BAR_H   = 0.030   -- height of the bar chart area
SoilVariableRatePanel.PAD     = 0.006
SoilVariableRatePanel.TITLE_H = 0.022
SoilVariableRatePanel.GAP     = 0.005
SoilVariableRatePanel.INFO_H  = 0.018   -- single info row below bars

SoilVariableRatePanel.C_BORDER   = {0.20, 0.20, 0.20, 0.40}
SoilVariableRatePanel.C_SHADOW   = {0.00, 0.00, 0.00, 0.30}
SoilVariableRatePanel.C_TITLE_BG = {0.10, 0.10, 0.10, 0.90}
SoilVariableRatePanel.C_DIVIDER  = {0.25, 0.25, 0.25, 0.45}
SoilVariableRatePanel.C_WARN     = {0.90, 0.82, 0.18, 1.00}
SoilVariableRatePanel.C_DIM      = {0.52, 0.52, 0.52, 0.85}
SoilVariableRatePanel.C_BAR_BG   = {0.18, 0.18, 0.18, 0.90}
SoilVariableRatePanel.C_OFF      = {0.52, 0.52, 0.52, 0.85}

function SoilVariableRatePanel.new(soilSystem, settings)
    local self = setmetatable({}, SoilVariableRatePanel_mt)
    self.soilSystem          = soilSystem
    self.settings            = settings
    self.fillOverlay         = nil
    self.initialized         = false
    self.collapsed           = false
    self.lastPanelH          = nil   -- actual rendered height; read by panels below for stacking
    self.lastDrawRect        = nil   -- {x,y,w,h} for hit-testing in independent drag mode
    self.collapseButtonRect  = nil   -- {x,y,w,h} for collapse toggle in edit mode
    return self
end

function SoilVariableRatePanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        local ov = createImageOverlay("dataS/menu/base/graph_pixel.dds")
        if ov and ov ~= 0 then
            self.fillOverlay = ov
            self.initialized = true
            SoilLogger.info("[SoilVariableRatePanel] Initialized")
        else
            SoilLogger.warning("[SoilVariableRatePanel] createImageOverlay returned invalid handle")
        end
    end
end

function SoilVariableRatePanel:delete()
    if self.fillOverlay and self.fillOverlay ~= 0 then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

function SoilVariableRatePanel:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay or self.fillOverlay == 0 then return end
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], a or c[4] or 1.0)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

-- Returns a color for a rate multiplier:
--   rate <= 0.6 → green (well stocked, reduced application)
--   rate ~1.0   → yellow (normal)
--   rate >= 1.3 → red (deep deficit, boosted)
local function rateColor(rate)
    if rate <= 0.60 then return {0.25, 0.85, 0.25, 1.0} end
    if rate >= 1.30 then return {0.90, 0.28, 0.22, 1.0} end
    if rate <= 1.00 then
        local t = (rate - 0.60) / 0.40
        return { 0.25 + t * 0.65, 0.85 - t * 0.03, 0.25 - t * 0.25, 1.0 }
    end
    local t = (rate - 1.00) / 0.30
    return { 0.90, 0.82 - t * 0.54, 0.18 + t * 0.04, 1.0 }
end

function SoilVariableRatePanel:getActiveSprayer()
    local player = g_localPlayer
    if not player or type(player.getIsInVehicle) ~= "function" then return nil end
    if not player:getIsInVehicle() then return nil end
    local vehicle = player:getCurrentVehicle()
    if not vehicle then return nil end
    if vehicle.spec_sprayer then return vehicle end
    local impl = vehicle.spec_attacherJoints and vehicle.spec_attacherJoints.attachedImplements
    if impl then
        for _, att in ipairs(impl) do
            if att.object and att.object.spec_sprayer then return att.object end
        end
    end
    return nil
end

-- ── Main draw ────────────────────────────────────────────

function SoilVariableRatePanel:draw()
    -- Reset stacking state; drawPanel will set if we actually render
    self.lastPanelH  = 0
    self.lastDrawRect = nil

    if not self.initialized then return end
    if not self.settings or not self.settings.enabled then return end
    if not g_currentMission then return end

    local sfm = g_SoilFertilityManager
    if not sfm or not sfm.sensorManager then return end
    if sfm.settings and sfm.settings.variableRateEnabled == false then return end

    -- SF custom settings panel open → hide system panels
    if sfm.settingsPanel and sfm.settingsPanel.isVisible then return end

    local hud = sfm.soilHUD
    if hud and not hud.visible then return end
    local inEditMode = hud and hud.editMode
    local indMode    = sfm.settings and sfm.settings.independentPanels

    if not inEditMode then
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then return end
        if g_currentMission.hud and g_currentMission.hud.ingameMap then
            if g_currentMission.hud.ingameMap.state == IngameMap.STATE_LARGE_MAP then return end
        end
    end

    local sprayer = self:getActiveSprayer()

    -- In edit+independent mode, draw frame for hit-testing even without a sprayer
    if inEditMode and indMode then
        self:drawPanel(sprayer, sfm)
        return
    end

    if not sprayer then return end
    local vww = sprayer.spec_variableWorkWidth
    if not vww or not vww.sections or #vww.sections == 0 then return end

    self:drawPanel(sprayer, sfm)
end

function SoilVariableRatePanel:drawPanel(sprayer, sfm)
    local sensorMgr = sfm.sensorManager
    local indMode   = sfm.settings and sfm.settings.independentPanels

    local hud = sfm.soilHUD
    if not hud then return end

    -- Apply saved collapsed state on first draw (loaded from hud.xml)
    if hud.savedCollapsed and hud.savedCollapsed.varRate ~= nil then
        self.collapsed = hud.savedCollapsed.varRate
        hud.savedCollapsed.varRate = nil
    end

    local s  = hud.scale or 1.0
    local pw = SoilHUD and (SoilHUD.BASE_W * s) or (0.190 * s)

    -- Rate panel geometry
    local padV    = (5  / 1080) * s
    local barH_rp = (4  / 1080) * s
    local scrollH = (22 / 1080) * s
    local headerH = (16 / 1080) * s
    local ratePanelH = padV + barH_rp + padV + scrollH + padV + headerH
    local rateGap    = (6  / 1080) * s

    -- Smart Sensor panel height (use actual rendered height to handle collapse)
    local ssPanelRows = 3
    local ssFallbackH = 0.022*s + 0.006*s + ssPanelRows * 0.024*s + 0.006*s
    local ssActualH   = (sfm.smartSensorPanel and sfm.smartSensorPanel.lastPanelH) or ssFallbackH
    local ssGap       = 0.007 * s

    -- See & Spray panel height (use actual rendered height to handle collapse)
    local sasFallbackRows = 3
    local sasFallbackH    = 0.022*s + 0.006*s + sasFallbackRows * 0.024*s + 0.006*s
    local sasActualH      = (sfm.seeAndSprayPanel and sfm.seeAndSprayPanel.lastPanelH) or sasFallbackH
    local sasGap          = 0.005 * s

    local seeAndSprayActive = sfm.settings and sfm.settings.seeAndSprayEnabled ~= false

    -- Stacked anchor
    local mainPanelY = hud.panelY
    local ratePanelY = mainPanelY - rateGap - ratePanelH
    local ssPanelY   = ratePanelY - ssGap - ssActualH
    local baseY      = ssPanelY
    if seeAndSprayActive then
        baseY = ssPanelY - sasGap - sasActualH
    end

    local titleH     = SoilVariableRatePanel.TITLE_H * s
    local pad        = SoilVariableRatePanel.PAD     * s
    local barsH      = SoilVariableRatePanel.BAR_H   * s
    local infoH      = SoilVariableRatePanel.INFO_H  * s
    local fullPanelH = titleH + pad + barsH + pad + infoH + pad

    -- Effective height (title bar only when collapsed)
    local collapsed = self.collapsed
    local panelH    = collapsed and titleH or fullPanelH

    local stackedX = hud.panelX
    local stackedY = baseY - SoilVariableRatePanel.GAP * s - panelH

    -- Free position or stacked
    local panelX, panelY
    if indMode then
        panelX, panelY = hud:getFreePos("varRate", stackedX, stackedY)
    else
        panelX, panelY = stackedX, stackedY
    end

    self.lastPanelH   = panelH
    self.lastDrawRect = { x = panelX, y = panelY, w = pw, h = panelH }

    -- Background
    local rTheme = SoilConstants.HUD and SoilConstants.HUD.COLOR_THEMES
        and SoilConstants.HUD.COLOR_THEMES[self.settings.hudColorTheme or 1]
        or { r = 0.4, g = 1.0, b = 0.4 }
    local bgR  = 0.05 + rTheme.r * 0.04
    local bgG  = 0.05 + rTheme.g * 0.04
    local bgB  = 0.05 + rTheme.b * 0.04
    local alpha = SoilConstants.HUD and SoilConstants.HUD.TRANSPARENCY_LEVELS
        and SoilConstants.HUD.TRANSPARENCY_LEVELS[self.settings.hudTransparency or 3] or 0.70

    self:drawRect(panelX + 0.002*s, panelY - 0.002*s, pw, panelH, SoilVariableRatePanel.C_SHADOW)
    self:drawRect(panelX, panelY, pw, panelH, {bgR, bgG, bgB, 1}, alpha)
    self:drawRect(panelX, panelY + panelH - titleH, pw, titleH, SoilVariableRatePanel.C_TITLE_BG)

    local bw = 0.001
    self:drawRect(panelX,         panelY,            pw, bw, SoilVariableRatePanel.C_BORDER)
    self:drawRect(panelX,         panelY+panelH-bw,  pw, bw, SoilVariableRatePanel.C_BORDER)
    self:drawRect(panelX,         panelY,            bw, panelH, SoilVariableRatePanel.C_BORDER)
    self:drawRect(panelX+pw-bw,   panelY,            bw, panelH, SoilVariableRatePanel.C_BORDER)

    -- Edit mode pulse
    if hud.editMode then
        local pulse = 0.55 + 0.45 * math.sin((hud.animTimer or 0) * 0.004)
        local ebw = 0.0015
        self:drawRect(panelX,         panelY,            pw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(panelX,         panelY+panelH-ebw, pw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(panelX,         panelY,            ebw, panelH, {1.0, 0.55, 0.10, pulse})
        self:drawRect(panelX+pw-ebw,  panelY,            ebw, panelH, {1.0, 0.55, 0.10, pulse})
    end

    -- Title text (shifted left in edit mode for collapse button)
    local titleFs  = 0.009 * s
    local titleCX  = hud.editMode and (panelX + pw * 0.42) or (panelX + pw * 0.5)
    local titleBarY = panelY + panelH - titleH * 0.5 - titleFs * 0.3
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(1, 1, 1, 0.90)
    renderText(titleCX, titleBarY, titleFs, g_i18n:getText("sf_var_rate_panel_title"))
    setTextBold(false)

    -- Collapse / expand button (edit mode only)
    self.collapseButtonRect = nil
    if hud.editMode then
        local cbSz = titleH * 0.72
        local cbX  = panelX + pw - cbSz - 0.003*s
        local cbY  = panelY + panelH - titleH + (titleH - cbSz) * 0.5
        self:drawRect(cbX, cbY, cbSz, cbSz, {0.18, 0.28, 0.38, 0.85})
        setTextBold(true)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(1, 1, 1, 0.90)
        renderText(cbX + cbSz * 0.5, cbY + cbSz * 0.18, titleFs, collapsed and "+" or "-")
        setTextBold(false)
        self.collapseButtonRect = { x = cbX, y = cbY, w = cbSz, h = cbSz }
    end

    -- When collapsed, skip body content
    if collapsed then
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        return
    end

    -- No sprayer: frame drawn for hit-testing only (edit+independent mode without vehicle)
    if not sprayer then
        setTextColor(1, 1, 1, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        return
    end

    local cx = panelX + pw * 0.5

    local vehicleId = sprayer.id
    local isVROn    = sensorMgr:isVariableRateEnabled(vehicleId)

    -- Info row: status + key
    local keyVR = "Alt+7"
    if g_inputDisplayManager then
        local ok, el = pcall(function()
            return g_inputDisplayManager:getControllerSymbolOverlays(InputAction.SF_VARIABLE_RATE, "", "", false)
        end)
        if ok and el and el.keys and #el.keys > 0 then
            local parts = {}
            for _, k in ipairs(el.keys) do parts[#parts+1] = tostring(k) end
            keyVR = table.concat(parts, "+")
        end
    end

    local fs    = 0.0075 * s
    local fsDim = 0.0065 * s
    local tx    = panelX + pad
    local valX  = panelX + pw - pad

    -- Info row
    local infoY = panelY + pad
    local statusStr = isVROn and g_i18n:getText("sf_sensor_state_on") or g_i18n:getText("sf_sensor_state_off")
    local statusC   = isVROn and {0.25, 0.85, 0.25, 1.0} or SoilVariableRatePanel.C_OFF
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(statusC[1], statusC[2], statusC[3], 1.0)
    renderText(tx, infoY + infoH * 0.25, fsDim, g_i18n:getText("sf_var_rate_label") .. "  " .. statusStr)

    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(SoilVariableRatePanel.C_DIM[1], SoilVariableRatePanel.C_DIM[2],
        SoilVariableRatePanel.C_DIM[3], 0.70)
    renderText(valX, infoY + infoH * 0.25, fsDim, "[" .. keyVR .. "]")
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Bar chart
    local barAreaY = infoY + infoH + pad * 0.5
    local vww    = sprayer.spec_variableWorkWidth
    local sectionRates = sensorMgr.sectionRates and sensorMgr.sectionRates[vehicleId]

    -- Collect active non-center sections (same order as the VWW loop)
    local activeSections = {}
    for _, sec in ipairs(vww.sections) do
        if sec.isActive or sec.isCenter then
            activeSections[#activeSections + 1] = sec
        end
    end

    local n = #activeSections
    if n == 0 then n = 1 end  -- avoid divide-by-zero

    local totalBarW = pw - pad * 2
    local barGap    = math.max(0, math.min(0.002, totalBarW / n * 0.06))
    local singleW   = (totalBarW - barGap * (n - 1)) / n

    -- Bar background track
    self:drawRect(tx, barAreaY, totalBarW, barsH, SoilVariableRatePanel.C_BAR_BG)

    local vrCfg   = SoilConstants.VARIABLE_RATE
    local minRate = vrCfg and vrCfg.MIN_RATE or 0.30
    local maxRate = vrCfg and vrCfg.MAX_RATE or 1.50

    for i, section in ipairs(activeSections) do
        local bx = tx + (i - 1) * (singleW + barGap)
        local rate = (sectionRates and sectionRates[section]) or 1.0
        -- Bar fill height proportional to rate (min→0%, max→100%)
        local fillFrac = math.max(0, math.min(1, (rate - minRate) / (maxRate - minRate)))
        local fillH = barsH * fillFrac

        local col = isVROn and rateColor(rate) or SoilVariableRatePanel.C_OFF
        if fillH > 0.0005 then
            self:drawRect(bx, barAreaY, singleW, fillH, col)
        end

        -- Rate label (tiny, above bar)
        if isVROn and n <= 12 then
            setTextAlignment(RenderText.ALIGN_CENTER)
            setTextColor(1, 1, 1, 0.80)
            local lfs = 0.006 * s
            renderText(bx + singleW * 0.5, barAreaY + barsH + 0.001*s, lfs,
                string.format("%.2f", rate))
        end
    end

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
end
