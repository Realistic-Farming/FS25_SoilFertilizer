-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Sprayer Info Panel
-- =========================================================
-- Renders a compact overlay showing soil nutrient levels for
-- the nutrients the loaded fertilizer covers, whenever the
-- player is driving a sprayer.
--
-- Position: free-floating, draggable via Shift+H edit mode.
-- Default: left side of screen below the typical F1 area.
-- Saved to sprayerPanel.xml (same dir as hud.xml).
--
-- Rendering: FSBaseMission.draw (always fires, not tied to F1).
-- F1 geometry cached from InputHelpDisplay.draw for auto-anchor.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilSprayerInfoPanel
SoilSprayerInfoPanel = {}
local SoilSprayerInfoPanel_mt = Class(SoilSprayerInfoPanel)

-- ── Layout constants ──────────────────────────────────────
SoilSprayerInfoPanel.GAP      = 0.003
SoilSprayerInfoPanel.PAD      = 0.006
SoilSprayerInfoPanel.TITLE_H  = 0.022
SoilSprayerInfoPanel.ROW_H    = 0.022
SoilSprayerInfoPanel.BAR_H    = 0.009
SoilSprayerInfoPanel.FLAG_W   = 0.0018
SoilSprayerInfoPanel.FLAG_CAP = 0.0030

-- Default position (bottom-left corner, used when no saved position exists)
SoilSprayerInfoPanel.DEFAULT_X = 0.015625
SoilSprayerInfoPanel.DEFAULT_Y = 0.520

-- ── Colors ───────────────────────────────────────────────
SoilSprayerInfoPanel.C_BG       = {0.05, 0.05, 0.05, 0.82}
SoilSprayerInfoPanel.C_TITLE_BG = {0.10, 0.10, 0.10, 0.90}
SoilSprayerInfoPanel.C_BORDER   = {0.20, 0.20, 0.20, 0.40}
SoilSprayerInfoPanel.C_BAR_BG   = {0.18, 0.18, 0.18, 0.90}
SoilSprayerInfoPanel.C_GOOD     = {0.25, 0.85, 0.25, 1.00}
SoilSprayerInfoPanel.C_FAIR     = {0.90, 0.82, 0.18, 1.00}
SoilSprayerInfoPanel.C_POOR     = {0.88, 0.25, 0.25, 1.00}
SoilSprayerInfoPanel.C_LABEL    = {0.72, 0.72, 0.72, 1.00}
SoilSprayerInfoPanel.C_VALUE    = {1.00, 1.00, 1.00, 1.00}
SoilSprayerInfoPanel.C_DIM      = {0.52, 0.52, 0.52, 0.85}
SoilSprayerInfoPanel.C_FLAG     = {1.00, 1.00, 0.70, 0.92}
SoilSprayerInfoPanel.C_EDIT_HDL = {0.20, 0.60, 1.00, 0.85}

-- ── Nutrient row definitions ──────────────────────────────
local NUTRIENT_ROWS = {
    { profileKey = "N",  fieldKey = "nitrogen",      maxVal = 100, label = "N"  },
    { profileKey = "P",  fieldKey = "phosphorus",    maxVal = 100, label = "P"  },
    { profileKey = "K",  fieldKey = "potassium",     maxVal = 100, label = "K"  },
    { profileKey = "OM", fieldKey = "organicMatter", maxVal = 10,  label = "OM" },
    { profileKey = "pH", fieldKey = "pH",            maxVal = 14,  label = "pH" },
}

-- ── Constructor ───────────────────────────────────────────

function SoilSprayerInfoPanel.new(soilSystem, settings)
    local self = setmetatable({}, SoilSprayerInfoPanel_mt)
    self.soilSystem  = soilSystem
    self.settings    = settings
    self.fillOverlay = nil
    self.initialized = false

    -- Position state: nil = use default auto-anchor, non-nil = custom (saved) position
    -- panelX/panelY = bottom-left corner (matches renderOverlay convention)
    self.panelX = nil
    self.panelY = nil

    -- Edit mode / drag state
    self.editMode        = false
    self.dragging        = false
    self.dragOffsetX     = 0
    self.dragOffsetY     = 0
    self.movedInEditMode = false
    self._animTimer      = 0

    -- Last rendered rect (for hit testing in edit mode)
    self._lastPanelX = SoilSprayerInfoPanel.DEFAULT_X
    self._lastPanelY = SoilSprayerInfoPanel.DEFAULT_Y
    self._lastPanelW = 0.190
    self._lastPanelH = 0.100

    -- Cached F1 geometry (populated by cacheF1Geometry from InputHelpDisplay.draw hook)
    self._f1Cache = nil

    -- Field detection cache (populated by update, throttled)
    self._detectTimer = 0
    self._fieldId     = nil
    self._fieldInfo   = nil

    return self
end

function SoilSprayerInfoPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        local ov = createImageOverlay("dataS/menu/base/graph_pixel.dds")
        if ov and ov ~= 0 then
            self.fillOverlay = ov
            self.initialized = true
            self:loadLayout()
            SoilLogger.info("[SoilSprayerInfoPanel] Initialized")
        else
            SoilLogger.warning("[SoilSprayerInfoPanel] createImageOverlay failed — panel will not render")
        end
    end
end

function SoilSprayerInfoPanel:delete()
    if self.fillOverlay and self.fillOverlay ~= 0 then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Edit mode ─────────────────────────────────────────────

function SoilSprayerInfoPanel:enterEditMode()
    self.editMode        = true
    self.dragging        = false
    self.movedInEditMode = false
end

function SoilSprayerInfoPanel:exitEditMode()
    self.editMode = false
    self.dragging = false
    if self.movedInEditMode then
        self.movedInEditMode = false
        self:saveLayout()
    end
end

-- ── Layout persistence ────────────────────────────────────

function SoilSprayerInfoPanel:getLayoutPath()
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if base then return base .. "/HUD/sprayerPanel.xml" end
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        return g_currentMission.missionInfo.savegameDirectory .. "/FS25_SoilFertilizer_sprayerPanel.xml"
    end
end

function SoilSprayerInfoPanel:saveLayout()
    local path = self:getLayoutPath()
    if not path then return end
    local xml = XMLFile.create("sf_sprayerPanel", path, "sprayerPanelLayout")
    if xml then
        xml:setFloat("sprayerPanelLayout.panelX", self.panelX or SoilSprayerInfoPanel.DEFAULT_X)
        xml:setFloat("sprayerPanelLayout.panelY", self.panelY or SoilSprayerInfoPanel.DEFAULT_Y)
        xml:save()
        xml:delete()
        SoilLogger.debug("[SoilSprayerInfoPanel] Layout saved: (%.3f, %.3f)", self.panelX or 0, self.panelY or 0)
    end
end

function SoilSprayerInfoPanel:loadLayout()
    local path = self:getLayoutPath()
    if not path or not fileExists(path) then return end
    local xml = XMLFile.load("sf_sprayerPanel", path)
    if xml then
        local x = xml:getFloat("sprayerPanelLayout.panelX", nil)
        local y = xml:getFloat("sprayerPanelLayout.panelY", nil)
        if x ~= nil and y ~= nil then
            self.panelX = x
            self.panelY = y
            SoilLogger.info("[SoilSprayerInfoPanel] Layout loaded: (%.3f, %.3f)", x, y)
        end
        xml:delete()
    end
end

-- ── Mouse event handler ───────────────────────────────────

function SoilSprayerInfoPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.editMode then return false end

    -- LMB up: release drag (must check before the move block)
    if isUp and button == Input.MOUSE_BUTTON_LEFT then
        if self.dragging then
            self.dragging = false
            return true
        end
        return false
    end

    -- Mouse move: update position while dragging
    if self.dragging then
        self.panelX = math.max(0, math.min(0.85, posX - self.dragOffsetX))
        self.panelY = math.max(0.02, math.min(0.95, posY - self.dragOffsetY))
        return true
    end

    -- LMB down: start drag if clicking inside panel
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        local px, py, pw, ph = self._lastPanelX, self._lastPanelY, self._lastPanelW, self._lastPanelH
        if posX >= px and posX <= px + pw and posY >= py and posY <= py + ph then
            self.dragging        = true
            self.dragOffsetX     = posX - px
            self.dragOffsetY     = posY - py
            self.movedInEditMode = true
            return true
        end
        return false
    end

    return false
end

-- ── F1 geometry cache (called from InputHelpDisplay.draw hook) ────

function SoilSprayerInfoPanel:cacheF1Geometry(displaySelf)
    if not displaySelf then return end
    self._f1Cache = {
        x        = (type(displaySelf.x) == "number") and displaySelf.x or 0.015625,
        y        = (type(displaySelf.y) == "number") and displaySelf.y or 0.9722,
        lineBgW  = (displaySelf.lineBg and displaySelf.lineBg.width)  or 0.190,
        lineBgH  = (displaySelf.lineBg and displaySelf.lineBg.height) or 0.023148,
        comboBgH = (displaySelf.comboBg and type(displaySelf.comboBg.height) == "number"
                    and displaySelf.comboBg.height > 0)
                   and displaySelf.comboBg.height or 0.023148,
    }
end

-- ── Sprayer helpers ───────────────────────────────────────

function SoilSprayerInfoPanel:getActiveSprayer()
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

function SoilSprayerInfoPanel:getSprayerFillType(sprayer)
    if not sprayer then return nil end
    local fillTypeIndex
    local spec = sprayer.spec_sprayer
    if spec and spec.workAreaParameters then
        local ft = spec.workAreaParameters.sprayFillType
        if ft and ft > 0 then fillTypeIndex = ft end
    end
    if not fillTypeIndex then
        local ok, units = pcall(function() return sprayer:getFillUnits() end)
        if ok and units then
            for i = 1, #units do
                local ft = sprayer:getFillUnitFillType(i)
                if ft and ft > 0 and ft ~= FillType.UNKNOWN then
                    fillTypeIndex = ft
                    break
                end
            end
        end
    end
    if not fillTypeIndex then return nil end
    return g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
end

-- ── Field detection (throttled, called from update) ───────

function SoilSprayerInfoPanel:update(dt)
    self._animTimer   = self._animTimer + dt
    self._detectTimer = self._detectTimer - dt * 0.001
    if self._detectTimer > 0 then return end
    self._detectTimer = 0.5

    local sprayer = self:getActiveSprayer()
    if not sprayer then
        self._fieldId   = nil
        self._fieldInfo = nil
        return
    end

    local x, z
    local vehicle = g_localPlayer and
                    type(g_localPlayer.getIsInVehicle) == "function" and
                    g_localPlayer:getIsInVehicle() and
                    g_localPlayer:getCurrentVehicle()
    local posNode = (vehicle and vehicle.rootNode) or sprayer.rootNode
    if posNode then
        local ok, px, _, pz = pcall(getWorldTranslation, posNode)
        if ok then x, z = px, pz end
    end
    if not x then
        self._fieldId   = nil
        self._fieldInfo = nil
        return
    end

    local fieldId = nil
    if g_fieldManager then
        local ok, field = pcall(function()
            return g_fieldManager:getFieldAtWorldPosition(x, z)
        end)
        if ok and field and field.farmland and field.farmland.id then
            fieldId = field.farmland.id
        end
    end
    if not fieldId and g_farmlandManager then
        local ok, farmland = pcall(function()
            return g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        end)
        if ok and farmland and farmland.id and farmland.id > 0 then
            fieldId = farmland.id
        end
    end

    self._fieldId = fieldId
    if fieldId and self.soilSystem then
        self._fieldInfo = self.soilSystem:getFieldInfo(fieldId, x, z)
    else
        self._fieldInfo = nil
    end
end

-- ── Draw helpers ──────────────────────────────────────────

function SoilSprayerInfoPanel:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay or self.fillOverlay == 0 then return end
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], a or c[4] or 1.0)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

local function statusColor(profileKey, value)
    local P = SoilSprayerInfoPanel
    if profileKey == "pH" then
        local d = math.abs(value - 6.75)
        if d < 0.5 then return P.C_GOOD elseif d < 1.0 then return P.C_FAIR end
        return P.C_POOR
    end
    if profileKey == "OM" then
        if value >= 3.0 then return P.C_GOOD elseif value >= 1.5 then return P.C_FAIR end
        return P.C_POOR
    end
    local nameMap = { N = "nitrogen", P = "phosphorus", K = "potassium" }
    local th = SoilConstants.STATUS_THRESHOLDS and SoilConstants.STATUS_THRESHOLDS[nameMap[profileKey]]
    if th then
        if value >= th.fair then return P.C_GOOD
        elseif value >= th.poor then return P.C_FAIR end
        return P.C_POOR
    end
    return P.C_FAIR
end

local function targetFraction(profileKey, maxVal)
    if profileKey == "N" then
        local th = SoilConstants.STATUS_THRESHOLDS and SoilConstants.STATUS_THRESHOLDS.nitrogen
        return th and (th.fair / maxVal) or (50 / maxVal)
    elseif profileKey == "P" then
        local th = SoilConstants.STATUS_THRESHOLDS and SoilConstants.STATUS_THRESHOLDS.phosphorus
        return th and (th.fair / maxVal) or (40 / maxVal)
    elseif profileKey == "K" then
        local th = SoilConstants.STATUS_THRESHOLDS and SoilConstants.STATUS_THRESHOLDS.potassium
        return th and (th.fair / maxVal) or (40 / maxVal)
    elseif profileKey == "OM" then
        return 3.0 / maxVal
    elseif profileKey == "pH" then
        return 6.75 / maxVal
    end
    return 0.6
end

-- ── Main draw (called from FSBaseMission.draw) ────────────

function SoilSprayerInfoPanel:draw()
    if not self.initialized then return end
    if not self.settings or not self.settings.enabled then return end
    if not g_currentMission or not g_currentMission.isRunning then return end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        if not self.editMode then return end
    end

    -- Determine what to show
    local sprayer  = self:getActiveSprayer()
    local fillType = sprayer and self:getSprayerFillType(sprayer)
    local profile  = fillType and SoilConstants.FERTILIZER_PROFILES and SoilConstants.FERTILIZER_PROFILES[fillType.name]

    local activeRows = {}
    if profile then
        for _, nd in ipairs(NUTRIENT_ROWS) do
            if (profile[nd.profileKey] or 0) ~= 0 then
                table.insert(activeRows, nd)
            end
        end
    end

    local isActive = sprayer ~= nil and profile ~= nil and #activeRows > 0

    -- Only draw when in a sprayer (or in edit mode for positioning)
    if not self.editMode and not isActive then return end

    -- Panel dimensions
    local pad    = SoilSprayerInfoPanel.PAD
    local titleH = SoilSprayerInfoPanel.TITLE_H
    local rowH   = SoilSprayerInfoPanel.ROW_H
    local barH   = SoilSprayerInfoPanel.BAR_H
    local flagW  = SoilSprayerInfoPanel.FLAG_W
    local flagCap = SoilSprayerInfoPanel.FLAG_CAP

    local hasField  = self._fieldInfo ~= nil
    local numContent = isActive and (#activeRows + (hasField and 0 or 1)) or 1
    local panelH    = titleH + pad + numContent * rowH + pad
    local panelW    = 0.190

    -- Determine panel bottom-left corner
    local panelX, panelBot
    if self.panelX ~= nil then
        -- Custom (saved/dragged) position
        panelX  = self.panelX
        panelBot = self.panelY
    else
        -- Auto-anchor: below F1 using cached geometry or defaults
        local cache  = self._f1Cache
        local f1X    = cache and cache.x    or SoilSprayerInfoPanel.DEFAULT_X
        local f1Y    = cache and cache.y    or 0.9722
        panelW       = cache and cache.lineBgW or panelW
        local lbH    = cache and cache.lineBgH or 0.023148
        local cbH    = cache and cache.comboBgH or lbH

        local maxLines = (InputHelpDisplay and InputHelpDisplay.MAX_NUM_ELEMENTS) or 12
        local numLines = maxLines
        if g_inputDisplayManager then
            local mask = g_inputBinding and g_inputBinding:getComboCommandPressedMask() or 0
            local ok, list = pcall(function()
                return g_inputDisplayManager:getEventHelpElements(mask, false)
            end)
            if ok and list and #list > 0 then
                numLines = math.min(#list, maxLines)
            end
        end

        local f1Bottom = f1Y - cbH - numLines * lbH
        panelX  = f1X
        panelBot = f1Bottom - SoilSprayerInfoPanel.GAP - panelH
    end

    local panelTop = panelBot + panelH

    -- Cache for hit testing in edit mode
    self._lastPanelX = panelX
    self._lastPanelY = panelBot
    self._lastPanelW = panelW
    self._lastPanelH = panelH

    -- ── Render ──────────────────────────────────────────────

    -- Shadow
    self:drawRect(panelX + 0.002, panelBot - 0.002, panelW, panelH, {0, 0, 0, 1}, 0.22)
    -- Background
    self:drawRect(panelX, panelBot, panelW, panelH, SoilSprayerInfoPanel.C_BG)
    -- Border
    self:drawRect(panelX, panelBot, panelW, panelH, SoilSprayerInfoPanel.C_BORDER, 0.55)
    -- Title bar
    self:drawRect(panelX, panelTop - titleH, panelW, titleH, SoilSprayerInfoPanel.C_TITLE_BG)

    -- Edit mode chrome: pulsing blue border + "DRAG" hint
    if self.editMode then
        local pulse = 0.55 + 0.45 * math.sin(self._animTimer * 0.004)
        local ebw = 0.002
        setOverlayColor(self.fillOverlay, SoilSprayerInfoPanel.C_EDIT_HDL[1], SoilSprayerInfoPanel.C_EDIT_HDL[2],
                        SoilSprayerInfoPanel.C_EDIT_HDL[3], SoilSprayerInfoPanel.C_EDIT_HDL[4] * pulse)
        renderOverlay(self.fillOverlay, panelX,               panelBot, ebw,    panelH)
        renderOverlay(self.fillOverlay, panelX + panelW - ebw, panelBot, ebw,    panelH)
        renderOverlay(self.fillOverlay, panelX,               panelBot, panelW, ebw)
        renderOverlay(self.fillOverlay, panelX,               panelTop - ebw, panelW, ebw)
    end

    -- Title text
    local titleFontSize = 0.0095
    local fertTitle = (fillType and (fillType.title or fillType.name)) or "Sprayer Panel"
    local fieldStr  = ""
    if self._fieldId then
        local ok2, fmtStr = pcall(function() return g_i18n:getText("sf_hud_field") end)
        fieldStr = " · " .. ((ok2 and fmtStr and not fmtStr:find("^%$l10n_"))
                   and string.format(fmtStr, self._fieldId) or tostring(self._fieldId))
    end

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    renderText(panelX + pad, panelTop - titleH * 0.5 - titleFontSize * 0.5, titleFontSize,
               fertTitle .. fieldStr)
    setTextBold(false)

    -- SF rate multiplier badge (top-right of title bar)
    if sprayer and g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager then
        local mult = g_SoilFertilityManager.sprayerRateManager:getMultiplier(sprayer.id or 0)
        local rateTxt = string.format("%.1fx", mult)
        local rateColor = (math.abs(mult - 1.0) < 0.01)
            and SoilSprayerInfoPanel.C_DIM
            or  { 1.00, 0.88, 0.30, 1.00 }
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(unpack(rateColor))
        renderText(panelX + panelW - pad, panelTop - titleH * 0.5 - titleFontSize * 0.5,
                   titleFontSize, rateTxt)
    end

    -- Content rows
    local labelW = 0.020
    local valW   = 0.032
    local barX   = panelX + pad + labelW
    local barW   = panelW - pad - labelW - pad * 0.5 - valW
    local lblSz  = 0.0085
    local valSz  = 0.0085
    local cy     = panelTop - titleH - pad

    if not isActive then
        -- Edit mode placeholder when not in a sprayer
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(SoilSprayerInfoPanel.C_DIM))
        renderText(panelX + pad, cy - rowH + (rowH - lblSz) * 0.45, lblSz, "Active in sprayer")

    elseif not hasField then
        -- On field with sprayer but not yet detecting a field
        local ok, msg = pcall(function() return g_i18n:getText("sf_sprayer_no_field") end)
        local txt = (ok and msg and not msg:find("^%$l10n_")) and msg or "Drive onto a field"
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(SoilSprayerInfoPanel.C_DIM))
        renderText(panelX + pad, cy - rowH + (rowH - lblSz) * 0.45, lblSz, txt)

    else
        -- Nutrient rows
        local info = self._fieldInfo
        for _, nd in ipairs(activeRows) do
            local pKey    = nd.profileKey
            local rawVal  = info[nd.fieldKey] or 0
            local maxVal  = nd.maxVal
            local rowBot  = cy - rowH
            local barMidY = rowBot + (rowH - barH) * 0.5

            setTextAlignment(RenderText.ALIGN_LEFT)
            setTextColor(unpack(SoilSprayerInfoPanel.C_LABEL))
            renderText(panelX + pad, rowBot + (rowH - lblSz) * 0.42, lblSz, nd.label)

            -- Bar track
            self:drawRect(barX, barMidY, barW, barH, SoilSprayerInfoPanel.C_BAR_BG)
            -- Bar fill
            local fillRatio = math.max(0, math.min(rawVal / maxVal, 1))
            local barColor  = statusColor(pKey, rawVal)
            if barW * fillRatio > 0 then
                self:drawRect(barX, barMidY, barW * fillRatio, barH, barColor)
            end
            -- Finish flag at target threshold
            local tFrac = targetFraction(pKey, maxVal)
            local fX    = barX + barW * tFrac - flagW * 0.5
            self:drawRect(fX, barMidY - 0.0012, flagW, barH + 0.0024, SoilSprayerInfoPanel.C_FLAG)
            self:drawRect(fX + flagW, barMidY + barH * 0.35, flagCap, barH * 0.55, SoilSprayerInfoPanel.C_FLAG, 0.80)

            -- Value
            local valStr
            if pKey == "pH" then
                valStr = string.format("%.1f", rawVal)
            elseif pKey == "OM" then
                valStr = string.format("%.1f%%", rawVal)
            else
                valStr = string.format("%d", math.floor(rawVal + 0.5))
            end
            setTextAlignment(RenderText.ALIGN_RIGHT)
            setTextColor(barColor[1], barColor[2], barColor[3], 1)
            renderText(panelX + panelW - pad * 0.5, rowBot + (rowH - valSz) * 0.42, valSz, valStr)

            cy = cy - rowH
        end
    end

    -- Reset text state
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end
