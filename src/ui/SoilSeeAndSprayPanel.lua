-- =========================================================
-- FS25 Realistic Soil & Fertilizer - See & Spray Panel
-- =========================================================
-- In-vehicle overlay for System 2 (See & Spray).
-- Shows per-cell pest / disease / weed pressure at the
-- sprayer's current position and which sensors are active.
-- Positioned below the Smart Sensor panel.
-- Style matches SoilHUD and the rate panel exactly.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilSeeAndSprayPanel
SoilSeeAndSprayPanel = {}
local SoilSeeAndSprayPanel_mt = Class(SoilSeeAndSprayPanel)

SoilSeeAndSprayPanel.ROW_H   = 0.024
SoilSeeAndSprayPanel.PAD     = 0.006
SoilSeeAndSprayPanel.TITLE_H = 0.022
SoilSeeAndSprayPanel.GAP     = 0.005   -- gap between this panel and the one above

-- Shared color constants (match SoilHUD / SmartSensorPanel)
SoilSeeAndSprayPanel.C_BORDER   = {0.20, 0.20, 0.20, 0.40}
SoilSeeAndSprayPanel.C_SHADOW   = {0.00, 0.00, 0.00, 0.30}
SoilSeeAndSprayPanel.C_ON       = {0.25, 0.85, 0.25, 1.00}
SoilSeeAndSprayPanel.C_OFF      = {0.52, 0.52, 0.52, 0.85}
SoilSeeAndSprayPanel.C_WARN     = {0.90, 0.82, 0.18, 1.00}
SoilSeeAndSprayPanel.C_LABEL    = {0.72, 0.72, 0.72, 1.00}
SoilSeeAndSprayPanel.C_VALUE    = {1.00, 1.00, 1.00, 1.00}
SoilSeeAndSprayPanel.C_DIM      = {0.52, 0.52, 0.52, 0.85}
SoilSeeAndSprayPanel.C_TITLE_BG = {0.10, 0.10, 0.10, 0.90}
SoilSeeAndSprayPanel.C_DIVIDER  = {0.25, 0.25, 0.25, 0.45}

-- Threshold indicators: green dot when cell is above threshold (spraying justified)
SoilSeeAndSprayPanel.C_CELL_HIGH = {0.90, 0.35, 0.25, 1.00}  -- red: above threshold, spraying needed
SoilSeeAndSprayPanel.C_CELL_LOW  = {0.40, 0.40, 0.40, 0.85}  -- gray: below threshold, section would skip

function SoilSeeAndSprayPanel.new(soilSystem, settings)
    local self = setmetatable({}, SoilSeeAndSprayPanel_mt)
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

function SoilSeeAndSprayPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        local ov = createImageOverlay("dataS/menu/base/graph_pixel.dds")
        if ov and ov ~= 0 then
            self.fillOverlay = ov
            self.initialized = true
            SoilLogger.info("[SoilSeeAndSprayPanel] Initialized")
        else
            SoilLogger.warning("[SoilSeeAndSprayPanel] createImageOverlay returned invalid handle")
        end
    end
end

function SoilSeeAndSprayPanel:delete()
    if self.fillOverlay and self.fillOverlay ~= 0 then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Internal helpers ─────────────────────────────────────

function SoilSeeAndSprayPanel:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay or self.fillOverlay == 0 then return end
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], a or c[4] or 1.0)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

function SoilSeeAndSprayPanel:getActiveSprayer()
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

-- Returns (fieldId, fd, cell) at the vehicle root position.
function SoilSeeAndSprayPanel:getCellData(vehicle)
    if not vehicle or not vehicle.rootNode then return nil, nil, nil end
    local ok, x, _, z = pcall(getWorldTranslation, vehicle.rootNode)
    if not ok or not x then return nil, nil, nil end
    local sfm = g_SoilFertilityManager
    if not sfm or not sfm.soilSystem then return nil, nil, nil end
    local field = nil
    if g_fieldManager then
        local fok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(x, z) end)
        if fok and f then field = f end
    end
    local fieldId = field and field.fieldId
    if not fieldId or fieldId <= 0 then return nil, nil, nil end
    local fd = sfm.soilSystem.fieldData[fieldId]
    if not fd then return nil, nil, nil end
    local zone = SoilConstants.ZONE
    local cellKey = tostring(math.floor(x / zone.CELL_SIZE) * 10000 + math.floor(z / zone.CELL_SIZE))
    local cell = fd.zoneData and fd.zoneData[cellKey]
    return fieldId, fd, cell
end

local function getActionKey(actionName, fallback)
    if g_inputDisplayManager then
        local ok, el = pcall(function()
            return g_inputDisplayManager:getControllerSymbolOverlays(InputAction[actionName], "", "", false)
        end)
        if ok and el and el.keys and #el.keys > 0 then
            local parts = {}
            for _, k in ipairs(el.keys) do parts[#parts + 1] = tostring(k) end
            return table.concat(parts, "+")
        end
    end
    return fallback
end

-- ── Main draw ────────────────────────────────────────────

function SoilSeeAndSprayPanel:draw()
    -- Reset stacking state; drawPanel will set if we actually render
    self.lastPanelH  = 0
    self.lastDrawRect = nil

    if not self.initialized then return end
    if not self.settings or not self.settings.enabled then return end
    if not g_currentMission then return end

    local sfm = g_SoilFertilityManager
    if not sfm or not sfm.sensorManager then return end
    if sfm.settings and sfm.settings.seeAndSprayEnabled == false then return end

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

function SoilSeeAndSprayPanel:drawPanel(sprayer, sfm)
    local sensorMgr  = sfm.sensorManager
    local indMode    = sfm.settings and sfm.settings.independentPanels

    local hud = sfm.soilHUD
    if not hud then return end

    -- Apply saved collapsed state on first draw (loaded from hud.xml)
    if hud.savedCollapsed and hud.savedCollapsed.seeAndSpray ~= nil then
        self.collapsed = hud.savedCollapsed.seeAndSpray
        hud.savedCollapsed.seeAndSpray = nil
    end

    local s  = hud.scale or 1.0
    local pw = SoilHUD and (SoilHUD.BASE_W * s) or (0.190 * s)

    -- Rate panel geometry
    local padV    = (5  / 1080) * s
    local barH    = (4  / 1080) * s
    local scrollH = (22 / 1080) * s
    local headerH = (16 / 1080) * s
    local ratePanelH = padV + barH + padV + scrollH + padV + headerH
    local rateGap    = (6  / 1080) * s

    -- Smart Sensor panel height (use actual rendered height to handle collapse)
    local ssPanelRows  = 3
    local ssFallbackH  = 0.022*s + 0.006*s + ssPanelRows * 0.024*s + 0.006*s
    local ssActualH    = (sfm.smartSensorPanel and sfm.smartSensorPanel.lastPanelH) or ssFallbackH
    local ssGap        = 0.007 * s

    -- Stacked anchor position (below Smart Sensor panel)
    local numRows      = 3
    local rowH         = SoilSeeAndSprayPanel.ROW_H   * s
    local pad          = SoilSeeAndSprayPanel.PAD     * s
    local titleH       = SoilSeeAndSprayPanel.TITLE_H * s
    local fullPanelH   = titleH + pad + numRows * rowH + pad

    local mainPanelY = hud.panelY
    local ratePanelY = mainPanelY - rateGap - ratePanelH
    local ssPanelY   = ratePanelY - ssGap - ssActualH

    -- Effective height (title bar only when collapsed)
    local collapsed = self.collapsed
    local panelH    = collapsed and titleH or fullPanelH

    local stackedX = hud.panelX
    local stackedY = ssPanelY - SoilSeeAndSprayPanel.GAP * s - panelH

    -- Free position or stacked
    local panelX, panelY
    if indMode then
        panelX, panelY = hud:getFreePos("seeAndSpray", stackedX, stackedY)
    else
        panelX, panelY = stackedX, stackedY
    end

    self.lastPanelH   = panelH
    self.lastDrawRect = { x = panelX, y = panelY, w = pw, h = panelH }

    -- Background: color-theme tinted + transparency (match rate panel)
    local rTheme = SoilConstants.HUD and SoilConstants.HUD.COLOR_THEMES
        and SoilConstants.HUD.COLOR_THEMES[self.settings.hudColorTheme or 1]
        or { r = 0.4, g = 1.0, b = 0.4 }
    local bgR  = 0.05 + rTheme.r * 0.04
    local bgG  = 0.05 + rTheme.g * 0.04
    local bgB  = 0.05 + rTheme.b * 0.04
    local alpha = SoilConstants.HUD and SoilConstants.HUD.TRANSPARENCY_LEVELS
        and SoilConstants.HUD.TRANSPARENCY_LEVELS[self.settings.hudTransparency or 3] or 0.70

    self:drawRect(panelX + 0.002*s, panelY - 0.002*s, pw, panelH, SoilSeeAndSprayPanel.C_SHADOW)
    self:drawRect(panelX, panelY, pw, panelH, {bgR, bgG, bgB, 1}, alpha)
    self:drawRect(panelX, panelY + panelH - titleH, pw, titleH, SoilSeeAndSprayPanel.C_TITLE_BG)

    local bw = 0.001
    self:drawRect(panelX,          panelY,             pw, bw, SoilSeeAndSprayPanel.C_BORDER)
    self:drawRect(panelX,          panelY + panelH-bw, pw, bw, SoilSeeAndSprayPanel.C_BORDER)
    self:drawRect(panelX,          panelY,             bw, panelH, SoilSeeAndSprayPanel.C_BORDER)
    self:drawRect(panelX + pw-bw,  panelY,             bw, panelH, SoilSeeAndSprayPanel.C_BORDER)

    -- Edit mode pulse border
    if hud.editMode then
        local pulse = 0.55 + 0.45 * math.sin((hud.animTimer or 0) * 0.004)
        local ebw = 0.0015
        self:drawRect(panelX,            panelY,             pw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(panelX,            panelY+panelH-ebw,  pw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(panelX,            panelY,             ebw, panelH, {1.0, 0.55, 0.10, pulse})
        self:drawRect(panelX + pw - ebw, panelY,             ebw, panelH, {1.0, 0.55, 0.10, pulse})
    end

    -- Title text (shifted left in edit mode for collapse button)
    local titleFs  = 0.009 * s
    local titleCX  = hud.editMode and (panelX + pw * 0.42) or (panelX + pw * 0.5)
    local titleBarY = panelY + panelH - titleH * 0.5 - titleFs * 0.3
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(1, 1, 1, 0.90)
    renderText(titleCX, titleBarY, titleFs, g_i18n:getText("sf_see_spray_panel_title"))
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
    local _, fd, cell = self:getCellData(sprayer)
    local ssCfg = SoilConstants.SEE_AND_SPRAY

    local keyPest    = getActionKey("SF_SEE_SPRAY_PEST",    "Alt+4")
    local keyDisease = getActionKey("SF_SEE_SPRAY_DISEASE", "Alt+5")
    local keyWeed    = getActionKey("SF_SEE_SPRAY_WEED",    "Alt+6")

    local pestOn    = sensorMgr:isSeeSprayPestEnabled(vehicleId)
    local diseaseOn = sensorMgr:isSeeSprayDiseaseEnabled(vehicleId)
    local weedOn    = sensorMgr:isSeeSprayWeedEnabled(vehicleId)

    -- Per-cell values (fall back to field average)
    local cellPest, cellDisease, cellWeed = 0, 0, 0
    if fd then
        cellPest    = (cell and cell.pestPressure)    or (fd.pestPressure    or 0)
        cellDisease = (cell and cell.diseasePressure) or (fd.diseasePressure or 0)
        cellWeed    = (cell and cell.weedPressure)    or (fd.weedPressure    or 0)
    end

    local function cellVal(val, threshold, on)
        if not on or not fd then return "" end
        local pct = string.format("%.0f%%", val)
        local src = cell and "cell" or "avg"
        return string.format("%s (%s)", pct, src)
    end

    local rows = {
        { label = g_i18n:getText("sf_see_spray_pest"),    on = pestOn,    key = keyPest,
          val = cellVal(cellPest,    ssCfg.PEST_THRESHOLD,    pestOn),
          aboveThreshold = cellPest    >= ssCfg.PEST_THRESHOLD    },
        { label = g_i18n:getText("sf_see_spray_disease"), on = diseaseOn, key = keyDisease,
          val = cellVal(cellDisease, ssCfg.DISEASE_THRESHOLD, diseaseOn),
          aboveThreshold = cellDisease >= ssCfg.DISEASE_THRESHOLD },
        { label = g_i18n:getText("sf_see_spray_weed"),    on = weedOn,    key = keyWeed,
          val = cellVal(cellWeed,    ssCfg.WEED_THRESHOLD,    weedOn),
          aboveThreshold = cellWeed    >= ssCfg.WEED_THRESHOLD    },
    }

    local fs    = 0.0075 * s
    local fsDim = 0.0065 * s
    local tx    = panelX + pad
    local valX  = panelX + pw - pad
    local rowY  = panelY + pad

    setTextAlignment(RenderText.ALIGN_LEFT)

    for i = #rows, 1, -1 do
        local row  = rows[i]
        local midY = rowY + (i-1) * rowH + rowH * 0.5

        if i < #rows then
            self:drawRect(tx, rowY + (i-1) * rowH + rowH - 0.0003, pw - pad*2, 0.0003, SoilSeeAndSprayPanel.C_DIVIDER)
        end

        -- Dot: green=on, gray=off; when on: red=above threshold (would spray), dim gray=below (would skip)
        local dotC
        if not row.on then
            dotC = SoilSeeAndSprayPanel.C_OFF
        elseif row.aboveThreshold then
            dotC = SoilSeeAndSprayPanel.C_CELL_HIGH  -- spraying needed
        else
            dotC = SoilSeeAndSprayPanel.C_ON          -- cell clean, would skip
        end
        self:drawRect(tx, midY - 0.004*s, 0.007*s, 0.007*s, dotC)

        local labelC = row.on and SoilSeeAndSprayPanel.C_VALUE or SoilSeeAndSprayPanel.C_DIM
        setTextColor(labelC[1], labelC[2], labelC[3], labelC[4] or 1.0)
        renderText(tx + 0.010*s, midY - fs * 0.45, fs, row.label)

        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(SoilSeeAndSprayPanel.C_DIM[1], SoilSeeAndSprayPanel.C_DIM[2],
            SoilSeeAndSprayPanel.C_DIM[3], 0.70)
        renderText(valX, midY - fsDim * 0.45, fsDim, "[" .. row.key .. "]")
        setTextAlignment(RenderText.ALIGN_LEFT)

        if row.on and row.val ~= "" then
            setTextColor(SoilSeeAndSprayPanel.C_LABEL[1], SoilSeeAndSprayPanel.C_LABEL[2],
                SoilSeeAndSprayPanel.C_LABEL[3], 1.0)
            renderText(tx + 0.010*s, midY - fsDim * 0.45 - fsDim * 1.1, fsDim, row.val)
        end
    end

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
end
