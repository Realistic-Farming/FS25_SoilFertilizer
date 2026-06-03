-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Harvester Panel
-- =========================================================
-- Shows harvest info when the player is in a combine:
--   • Crop type + field ID in a gold title bar
--   • Grain tank: 10-segment battery bar, fill level, %
--   • Yield efficiency from soil data (how soil affects yield)
--   • Warning flash when tank is almost full (> 85 %)
--   • Stats bar: est. t/ha | coverage % | session ha | total ha
--
-- Position: free-floating, draggable via Shift+H edit mode.
-- Saved to harvesterPanel.xml alongside the other HUD layouts.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilHarvesterPanel
SoilHarvesterPanel = {}
local SoilHarvesterPanel_mt = Class(SoilHarvesterPanel)

-- ── Layout ────────────────────────────────────────────────
SoilHarvesterPanel.PAD     = 0.006
SoilHarvesterPanel.TITLE_H = 0.022
SoilHarvesterPanel.ROW_H   = 0.022
SoilHarvesterPanel.SEG_H   = 0.014   -- tank bar height
SoilHarvesterPanel.SEG_N   = 10      -- number of segments
SoilHarvesterPanel.SEG_GAP = 0.0018  -- gap between segments
SoilHarvesterPanel.PANEL_W = 0.210
SoilHarvesterPanel.STAT_H  = 0.040   -- stats bar (icons + values) at bottom

SoilHarvesterPanel.DEFAULT_X = 0.015625
SoilHarvesterPanel.DEFAULT_Y = 0.340

SoilHarvesterPanel.WARN_THRESHOLD = 0.85  -- flash warning above this fill ratio

-- Base crop yields (t/ha) for the yield estimate cell
SoilHarvesterPanel.BASE_YIELD = {
    wheat=8, barley=7, oat=6, rye=6, triticale=7,
    corn=12, maize=12, sorghum=10,
    canola=4, rapeseed=4, sunflower=4,
    soybean=4, beans=4,
    potato=45, sugarbeet=65, sugarcane=80,
    cotton=3, tobacco=3,
    default=8,
}

-- ── Colors ───────────────────────────────────────────────
SoilHarvesterPanel.C_BG       = {0.05, 0.05, 0.05, 0.82}
SoilHarvesterPanel.C_TITLE_BG = {0.18, 0.13, 0.02, 0.92}  -- warm gold tint
SoilHarvesterPanel.C_TITLE_FG = {1.00, 0.88, 0.30, 1.00}  -- gold text
SoilHarvesterPanel.C_BORDER   = {0.20, 0.20, 0.20, 0.40}
SoilHarvesterPanel.C_SEG_BG   = {0.18, 0.18, 0.18, 0.90}
SoilHarvesterPanel.C_SEG_FILL = {0.95, 0.78, 0.10, 1.00}  -- gold fill
SoilHarvesterPanel.C_SEG_WARN = {0.88, 0.25, 0.25, 1.00}  -- red when almost full
SoilHarvesterPanel.C_LABEL    = {0.72, 0.72, 0.72, 1.00}
SoilHarvesterPanel.C_VALUE    = {1.00, 1.00, 1.00, 1.00}
SoilHarvesterPanel.C_DIM      = {0.52, 0.52, 0.52, 0.85}
SoilHarvesterPanel.C_DIVIDER  = {0.30, 0.25, 0.05, 0.50}  -- gold-tinted divider
SoilHarvesterPanel.C_GOOD     = {0.25, 0.85, 0.25, 1.00}
SoilHarvesterPanel.C_FAIR     = {0.90, 0.82, 0.18, 1.00}
SoilHarvesterPanel.C_POOR     = {0.88, 0.25, 0.25, 1.00}
SoilHarvesterPanel.C_EDIT_HDL = {0.20, 0.60, 1.00, 0.85}

-- ── Constructor ───────────────────────────────────────────

function SoilHarvesterPanel.new(soilSystem, settings)
    local self = setmetatable({}, SoilHarvesterPanel_mt)
    self.soilSystem  = soilSystem
    self.settings    = settings
    self.fillOverlay = nil
    self.initialized = false

    self.panelX = nil
    self.panelY = nil

    self.editMode        = false
    self.dragging        = false
    self.dragOffsetX     = 0
    self.dragOffsetY     = 0
    self.movedInEditMode = false
    self._animTimer      = 0

    self._lastPanelX = SoilHarvesterPanel.DEFAULT_X
    self._lastPanelY = SoilHarvesterPanel.DEFAULT_Y
    self._lastPanelW = SoilHarvesterPanel.PANEL_W
    self._lastPanelH = 0.120

    -- Field detection cache
    self._detectTimer = 0
    self._fieldId     = nil
    self._fieldInfo   = nil

    -- Session grain tracking for t/ha estimate
    self._sessGrainL   = 0
    self._lastTankLvl  = nil
    self._lastHarvFId  = nil

    return self
end

function SoilHarvesterPanel:initialize()
    if self.initialized then return end
    if createImageOverlay then
        local ov = createImageOverlay("dataS/menu/base/graph_pixel.dds")
        if ov and ov ~= 0 then
            self.fillOverlay = ov
            self.initialized = true
            self:loadLayout()
            SoilLogger.info("[SoilHarvesterPanel] Initialized")
        else
            SoilLogger.warning("[SoilHarvesterPanel] createImageOverlay failed")
        end
    end
end

function SoilHarvesterPanel:delete()
    if self.fillOverlay and self.fillOverlay ~= 0 then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    self.initialized = false
end

-- ── Edit mode ─────────────────────────────────────────────

function SoilHarvesterPanel:enterEditMode()
    self.editMode        = true
    self.dragging        = false
    self.movedInEditMode = false
end

function SoilHarvesterPanel:exitEditMode()
    self.editMode = false
    self.dragging = false
    if self.movedInEditMode then
        self.movedInEditMode = false
        self:saveLayout()
    end
end

-- ── Layout persistence ────────────────────────────────────

function SoilHarvesterPanel:getLayoutPath()
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if base then return base .. "/HUD/harvesterPanel.xml" end
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        return g_currentMission.missionInfo.savegameDirectory .. "/FS25_SoilFertilizer_harvesterPanel.xml"
    end
end

function SoilHarvesterPanel:saveLayout()
    local path = self:getLayoutPath()
    if not path then return end
    local xml = XMLFile.create("sf_harvPanel", path, "harvesterPanelLayout")
    if xml then
        xml:setFloat("harvesterPanelLayout.panelX", self.panelX or SoilHarvesterPanel.DEFAULT_X)
        xml:setFloat("harvesterPanelLayout.panelY", self.panelY or SoilHarvesterPanel.DEFAULT_Y)
        xml:save()
        xml:delete()
    end
end

function SoilHarvesterPanel:loadLayout()
    local path = self:getLayoutPath()
    if not path or not fileExists(path) then return end
    local xml = XMLFile.load("sf_harvPanel", path)
    if xml then
        local x = xml:getFloat("harvesterPanelLayout.panelX", nil)
        local y = xml:getFloat("harvesterPanelLayout.panelY", nil)
        if x ~= nil and y ~= nil then
            self.panelX = x
            self.panelY = y
        end
        xml:delete()
    end
end

-- ── Mouse event ───────────────────────────────────────────

function SoilHarvesterPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.editMode then return false end

    if isUp and button == Input.MOUSE_BUTTON_LEFT then
        if self.dragging then
            self.dragging = false
            return true
        end
        return false
    end

    if self.dragging then
        self.panelX = math.max(0, math.min(0.85, posX - self.dragOffsetX))
        self.panelY = math.max(0.02, math.min(0.95, posY - self.dragOffsetY))
        return true
    end

    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        local px, py, pw, ph = self._lastPanelX, self._lastPanelY, self._lastPanelW, self._lastPanelH
        if posX >= px and posX <= px + pw and posY >= py and posY <= py + ph then
            self.dragging        = true
            self.dragOffsetX     = posX - px
            self.dragOffsetY     = posY - py
            self.movedInEditMode = true
            return true
        end
    end

    return false
end

-- ── Combine / grain tank helpers ──────────────────────────

-- Fill type names that are never grain tanks
local NON_CROP_TYPES = {
    diesel=true, electriccharge=true, methane=true, water=true,
    dea=true, exhaustfluid=true, pigfood=true, manure=true,
    slurry=true, digestate=true, liquidfertilizer=true,
    fertilizer=true, lime=true, herbicide=true, oil=true,
}

function SoilHarvesterPanel:getActiveCombine()
    local player = g_localPlayer
    if not player or type(player.getIsInVehicle) ~= "function" then return nil end
    if not player:getIsInVehicle() then return nil end
    local vehicle = player:getCurrentVehicle()
    if not vehicle then return nil end
    if vehicle.spec_combine then return vehicle end
    local impl = vehicle.spec_attacherJoints and vehicle.spec_attacherJoints.attachedImplements
    if impl then
        for _, att in ipairs(impl) do
            if att.object and att.object.spec_combine then return att.object end
        end
    end
    return nil
end

-- Returns grain tank { level, capacity, ratio, fillType } for the combine.
-- Works even when tank is empty (fill type UNKNOWN) — detects by largest capacity.
function SoilHarvesterPanel:getGrainTank(combine)
    if not combine then return nil end
    -- Use getFillUnits() — the correct FS25 API (getNumFillUnits does not exist)
    local ok, units = pcall(function() return combine:getFillUnits() end)
    if not ok or not units or #units == 0 then return nil end

    local bestUnit = nil
    local bestCap  = 0

    for i = 1, #units do
        local cap = combine:getFillUnitCapacity(i)
        if cap and cap > bestCap then
            local ft   = combine:getFillUnitFillType(i)
            local skip = false
            if ft and ft ~= FillType.UNKNOWN then
                local ftObj = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(ft)
                if ftObj and ftObj.name and NON_CROP_TYPES[ftObj.name:lower()] then
                    skip = true
                end
            end
            if not skip then
                bestUnit = i
                bestCap  = cap
            end
        end
    end

    if not bestUnit then return nil end

    local lvl   = combine:getFillUnitFillLevel(bestUnit) or 0
    local ft    = combine:getFillUnitFillType(bestUnit)
    local ftObj = (ft and ft ~= FillType.UNKNOWN)
                  and g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(ft)
                  or nil

    return {
        fillType = ftObj,
        level    = lvl,
        capacity = bestCap,
        ratio    = lvl / bestCap,
    }
end

-- Returns a fill type object for the crop being harvested.
-- Falls back from tank fill type → cutter header → field lastCrop.
function SoilHarvesterPanel:getCropFillType(combine, tank)
    -- 1. Tank fill type when tank has content
    if tank and tank.fillType then return tank.fillType end

    -- 2. Cutter/header fruit type (works even when tank is empty)
    local sources = { combine }
    local impl = combine.spec_attacherJoints and combine.spec_attacherJoints.attachedImplements
    if impl then
        for _, att in ipairs(impl) do
            if att.object then table.insert(sources, att.object) end
        end
    end
    for _, src in ipairs(sources) do
        -- spec_cutter stores the fruit type index being cut
        local spec = src.spec_cutter
        if spec then
            local fruitIdx = (spec.workAreaParameters and spec.workAreaParameters.lastFruitTypeIndex)
                          or spec.currentFruitTypeIndex
                          or (spec.lastCutFruitType)
            if fruitIdx and fruitIdx > 0 then
                local fruitType = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx)
                if fruitType then
                    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(fruitType.name)
                    if ft then return ft end
                end
            end
        end
        -- spec_combine may store the last input fruit type
        local cs = src.spec_combine
        if cs then
            local fruitIdx = cs.currentInputFruitTypeIndex or cs.lastFruitTypeIndex
            if fruitIdx and fruitIdx > 0 then
                local fruitType = g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByIndex(fruitIdx)
                if fruitType then
                    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(fruitType.name)
                    if ft then return ft end
                end
            end
        end
    end

    -- 3. Field lastCrop (stored by our soil system)
    if self._fieldInfo and self._fieldInfo.lastCrop then
        local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(self._fieldInfo.lastCrop)
        if ft then return ft end
    end

    return nil
end

-- ── Field detection (throttled) ───────────────────────────

function SoilHarvesterPanel:update(dt)
    self._animTimer   = self._animTimer + dt
    self._detectTimer = self._detectTimer - dt * 0.001
    if self._detectTimer > 0 then return end
    self._detectTimer = 0.5

    local combine = self:getActiveCombine()
    if not combine then
        self._fieldId   = nil
        self._fieldInfo = nil
        return
    end

    local x, z
    local posNode = combine.rootNode
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

    -- Track grain accumulated this harvest session for t/ha estimate
    local tank = self:getGrainTank(combine)
    if tank then
        if self._lastHarvFId ~= fieldId then
            -- Switched to a new field — reset session counter
            self._sessGrainL  = 0
            self._lastTankLvl = tank.level
            self._lastHarvFId = fieldId
        elseif self._lastTankLvl ~= nil then
            local delta = tank.level - self._lastTankLvl
            if delta > 0 then
                self._sessGrainL = self._sessGrainL + delta
            end
            -- delta < 0 means tank was emptied (pipe-out); keep the running total
            self._lastTankLvl = tank.level
        else
            self._lastTankLvl = tank.level
        end
    else
        self._lastTankLvl = nil
    end
end

-- ── Draw helpers ──────────────────────────────────────────

function SoilHarvesterPanel:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay or self.fillOverlay == 0 then return end
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], a or c[4] or 1.0)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

-- Draws the 10-segment battery-style bar
function SoilHarvesterPanel:drawTankBar(x, y, w, h, ratio, isWarning, pulse)
    local N      = SoilHarvesterPanel.SEG_N
    local gap    = SoilHarvesterPanel.SEG_GAP
    local segW   = (w - (N - 1) * gap) / N
    local filled = ratio * N

    for i = 0, N - 1 do
        local sx   = x + i * (segW + gap)
        local frac = math.max(0, math.min(1, filled - i))
        -- Background
        self:drawRect(sx, y, segW, h, SoilHarvesterPanel.C_SEG_BG)
        -- Fill
        if frac > 0 then
            local col = isWarning and SoilHarvesterPanel.C_SEG_WARN or SoilHarvesterPanel.C_SEG_FILL
            local alpha = isWarning and (0.6 + 0.4 * pulse) or 1.0
            self:drawRect(sx, y, segW * frac, h, col, alpha)
        end
    end
end

-- ── Main draw (called from FSBaseMission.draw) ────────────

function SoilHarvesterPanel:draw()
    if not self.initialized then return end
    if not self.settings or not self.settings.enabled then return end
    if not g_currentMission or not g_currentMission.isRunning then return end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        if not self.editMode then return end
    end

    local combine  = self:getActiveCombine()
    local tank     = combine and self:getGrainTank(combine)
    local cropFT   = combine and self:getCropFillType(combine, tank)
    local isActive = combine ~= nil

    if not self.editMode and not isActive then return end

    -- Layout
    local pad    = SoilHarvesterPanel.PAD
    local titleH = SoilHarvesterPanel.TITLE_H
    local rowH   = SoilHarvesterPanel.ROW_H
    local segH   = SoilHarvesterPanel.SEG_H
    local panelW = SoilHarvesterPanel.PANEL_W

    -- Rows: tank bar + fill text + divider + yield  (+stats bar when active)
    local numContentRows = isActive and 4 or 1
    local statH  = isActive and SoilHarvesterPanel.STAT_H or 0
    local panelH = titleH + pad + numContentRows * rowH + statH + pad

    -- Position
    local panelX, panelBot
    if self.panelX ~= nil then
        panelX  = self.panelX
        panelBot = self.panelY
    else
        panelX  = SoilHarvesterPanel.DEFAULT_X
        panelBot = SoilHarvesterPanel.DEFAULT_Y
    end
    local panelTop = panelBot + panelH

    -- Cache
    self._lastPanelX = panelX
    self._lastPanelY = panelBot
    self._lastPanelW = panelW
    self._lastPanelH = panelH

    local pulse = 0.5 + 0.5 * math.sin(self._animTimer * 0.004)

    -- ── Render ──────────────────────────────────────────────

    -- Shadow
    self:drawRect(panelX + 0.002, panelBot - 0.002, panelW, panelH, {0,0,0,1}, 0.22)
    -- Background
    self:drawRect(panelX, panelBot, panelW, panelH, SoilHarvesterPanel.C_BG)
    -- Border
    self:drawRect(panelX, panelBot, panelW, panelH, SoilHarvesterPanel.C_BORDER, 0.55)
    -- Title bar
    self:drawRect(panelX, panelTop - titleH, panelW, titleH, SoilHarvesterPanel.C_TITLE_BG)

    -- Edit mode chrome
    if self.editMode then
        local ebw = 0.002
        local C = SoilHarvesterPanel.C_EDIT_HDL
        setOverlayColor(self.fillOverlay, C[1], C[2], C[3], C[4] * (0.55 + 0.45 * pulse))
        renderOverlay(self.fillOverlay, panelX,               panelBot, ebw,    panelH)
        renderOverlay(self.fillOverlay, panelX + panelW - ebw, panelBot, ebw,    panelH)
        renderOverlay(self.fillOverlay, panelX,               panelBot, panelW, ebw)
        renderOverlay(self.fillOverlay, panelX,               panelTop - ebw, panelW, ebw)
    end

    -- Title text
    local titleFontSz = 0.0095
    local cropName    = (cropFT and (cropFT.title or cropFT.name))
                        or (self.editMode and "Harvester Panel" or "")
    local fieldStr    = ""
    if self._fieldId then
        local ok, fmtStr = pcall(function() return g_i18n:getText("sf_hud_field") end)
        fieldStr = " · " .. ((ok and fmtStr and not fmtStr:find("^%$l10n_"))
                   and string.format(fmtStr, self._fieldId) or tostring(self._fieldId))
    end

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(unpack(SoilHarvesterPanel.C_TITLE_FG))
    renderText(panelX + pad, panelTop - titleH * 0.5 - titleFontSz * 0.5, titleFontSz,
               cropName .. fieldStr)
    setTextBold(false)

    -- ── Content ─────────────────────────────────────────────

    local lblSz = 0.0085
    local valSz = 0.0085
    local cy    = panelTop - titleH - pad  -- top of first content row

    if not isActive then
        -- Edit mode placeholder
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(SoilHarvesterPanel.C_DIM))
        renderText(panelX + pad, cy - rowH + (rowH - lblSz) * 0.45, lblSz, "Active in harvester")
    else
        -- ── Row 1: Grain tank bar ──────────────────────────
        local ratio     = (tank and tank.ratio) or 0
        local isWarning = ratio >= SoilHarvesterPanel.WARN_THRESHOLD
        local barX      = panelX + pad
        local barW      = panelW - pad * 2
        local barMidY   = (cy - rowH) + (rowH - segH) * 0.5

        self:drawTankBar(barX, barMidY, barW, segH, ratio, isWarning, pulse)
        cy = cy - rowH

        -- ── Row 2: Fill text ──────────────────────────────
        local rowBot  = cy - rowH
        local textY   = rowBot + (rowH - lblSz) * 0.42

        if tank then
            -- Left: fill level in L
            local lvlStr = string.format("%s L", math.floor(tank.level + 0.5))
            setTextAlignment(RenderText.ALIGN_LEFT)
            if isWarning then
                setTextColor(SoilHarvesterPanel.C_SEG_WARN[1], SoilHarvesterPanel.C_SEG_WARN[2],
                             SoilHarvesterPanel.C_SEG_WARN[3], 0.7 + 0.3 * pulse)
            else
                setTextColor(unpack(SoilHarvesterPanel.C_VALUE))
            end
            renderText(panelX + pad, textY, lblSz, lvlStr)

            -- Centre: capacity
            local capStr = string.format("/ %s L", math.floor(tank.capacity + 0.5))
            setTextAlignment(RenderText.ALIGN_CENTER)
            setTextColor(unpack(SoilHarvesterPanel.C_DIM))
            renderText(panelX + panelW * 0.5, textY, lblSz, capStr)

            -- Right: percentage
            local pctStr = string.format("%d%%", math.floor(ratio * 100 + 0.5))
            setTextAlignment(RenderText.ALIGN_RIGHT)
            if isWarning then
                setTextColor(SoilHarvesterPanel.C_SEG_WARN[1], SoilHarvesterPanel.C_SEG_WARN[2],
                             SoilHarvesterPanel.C_SEG_WARN[3], 0.7 + 0.3 * pulse)
            else
                setTextColor(unpack(SoilHarvesterPanel.C_TITLE_FG))
            end
            renderText(panelX + panelW - pad, textY, valSz, pctStr)
        end
        cy = cy - rowH

        -- ── Dashed divider ─────────────────────────────────
        local divY = cy - rowH * 0.5
        local dashW = 0.010
        local dashH = 0.0012
        local dashGap = 0.006
        local numDash = math.floor((panelW - pad * 2) / (dashW + dashGap))
        for i = 0, numDash - 1 do
            self:drawRect(panelX + pad + i * (dashW + dashGap), divY, dashW, dashH,
                          SoilHarvesterPanel.C_DIVIDER, 0.70)
        end
        cy = cy - rowH

        -- ── Row 4: Yield efficiency ────────────────────────
        local yieldRowBot = cy - rowH
        local yieldTextY  = yieldRowBot + (rowH - lblSz) * 0.42

        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(SoilHarvesterPanel.C_LABEL))
        renderText(panelX + pad, yieldTextY, lblSz, "Yield eff.")

        local info = self._fieldInfo
        if info and info.yieldEfficiency then
            local pct    = math.floor(info.yieldEfficiency * 100 + 0.5)
            local effCol = (info.yieldEfficiency >= 0.80) and SoilHarvesterPanel.C_GOOD
                        or (info.yieldEfficiency >= 0.55) and SoilHarvesterPanel.C_FAIR
                        or  SoilHarvesterPanel.C_POOR
            local effStr = string.format("%d%%", pct)
            setTextAlignment(RenderText.ALIGN_RIGHT)
            setTextColor(unpack(effCol))
            renderText(panelX + panelW - pad, yieldTextY, valSz, effStr)
        else
            setTextAlignment(RenderText.ALIGN_RIGHT)
            setTextColor(unpack(SoilHarvesterPanel.C_DIM))
            renderText(panelX + panelW - pad, yieldTextY, valSz, "--")
        end

        -- ── Stats bar ──────────────────────────────────────────
        -- 4 cells: [wheat t/ha] [coverage %] [session ha] [total ha]
        local sbY = panelBot
        local sbH = SoilHarvesterPanel.STAT_H
        local sbW = panelW

        -- Dark separator line above stats bar
        self:drawRect(panelX, sbY + sbH - 0.0015, panelW, 0.0015,
                      SoilHarvesterPanel.C_DIVIDER, 0.80)

        -- Faint cell dividers
        local cellW = sbW / 4
        for i = 1, 3 do
            self:drawRect(panelX + cellW * i - 0.0008, sbY + pad,
                          0.0008, sbH - pad * 2,
                          SoilHarvesterPanel.C_BORDER, 0.60)
        end

        -- Gather values
        local fieldArea = (info and info.fieldArea) or 0
        local sessCov   = (info and info.sessionCoverageFraction) or 0
        local totCov    = (info and info.coverageFraction) or 0
        local sessHa    = sessCov * fieldArea
        local totHa     = fieldArea

        -- Yield estimate: yieldEfficiency * base crop yield (t/ha)
        local cropName  = info and info.lastCrop
        local cropKey   = cropName and string.lower(cropName) or "default"
        local baseYield = SoilHarvesterPanel.BASE_YIELD[cropKey]
                       or SoilHarvesterPanel.BASE_YIELD.default
        local yieldEff  = (info and info.yieldEfficiency) or 100
        local estTha    = baseYield * (yieldEff / 100)

        -- ── Cell 1: Wheat icon + estimated t/ha ───────────────
        local cell1X = panelX
        local C = SoilHarvesterPanel

        -- Icon
        local ic1 = cell1X + cellW * 0.5
        local ic1by = sbY + sbH * 0.45
        local isz = sbH * 0.38
        -- Stalk
        self:drawRect(ic1 - isz*0.065, ic1by, isz*0.13, isz*0.78, C.C_TITLE_FG, 0.90)
        -- Centre grain head
        self:drawRect(ic1 - isz*0.11, ic1by + isz*0.74, isz*0.22, isz*0.28, C.C_TITLE_FG)
        -- Left grain
        self:drawRect(ic1 - isz*0.29, ic1by + isz*0.60, isz*0.20, isz*0.24, C.C_TITLE_FG, 0.85)
        -- Right grain
        self:drawRect(ic1 + isz*0.07, ic1by + isz*0.60, isz*0.20, isz*0.24, C.C_TITLE_FG, 0.85)
        -- Leaf nubs
        self:drawRect(ic1 - isz*0.28, ic1by + isz*0.44, isz*0.22, isz*0.10, C.C_TITLE_FG, 0.60)
        self:drawRect(ic1 + isz*0.06, ic1by + isz*0.28, isz*0.22, isz*0.10, C.C_TITLE_FG, 0.60)

        local thaStr = string.format("%.1f t/ha", estTha)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(unpack(C.C_VALUE))
        renderText(cell1X + cellW * 0.5, sbY + (sbH * 0.35 - 0.0075) * 0.5, 0.0075, thaStr)

        -- ── Cell 2: Coverage % + mini progress bar ─────────────
        local cell2X = panelX + cellW
        local covPct  = math.floor(sessCov * 100 + 0.5)
        local covStr  = string.format("%d%%", covPct)
        local covCol  = (sessCov >= 0.80) and C.C_GOOD
                     or (sessCov >= 0.40) and C.C_FAIR
                     or C.C_LABEL

        -- Small mini-bar (3 segments) showing coverage
        local mbW  = cellW * 0.72
        local mbH  = 0.0045
        local mbX  = cell2X + (cellW - mbW) * 0.5
        local mbY  = sbY + sbH * 0.60
        local mSeg = 4
        local mGap = 0.0015
        local mSW  = (mbW - (mSeg-1)*mGap) / mSeg
        local mFill = sessCov * mSeg
        for mi = 0, mSeg - 1 do
            local msx = mbX + mi * (mSW + mGap)
            self:drawRect(msx, mbY, mSW, mbH, C.C_SEG_BG)
            local mfrac = math.max(0, math.min(1, mFill - mi))
            if mfrac > 0 then
                self:drawRect(msx, mbY, mSW * mfrac, mbH, covCol)
            end
        end

        -- Coverage % text
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(covCol[1], covCol[2], covCol[3], covCol[4] or 1)
        renderText(cell2X + cellW * 0.5, sbY + (sbH * 0.30 - 0.0075) * 0.5 + mbH + 0.003, 0.0080, covStr)

        -- ── Cell 3: Field icon + session area (ha) ─────────────
        local cell3X = panelX + cellW * 2
        local ic3sz  = isz
        local ic3lx  = cell3X + (cellW - ic3sz) * 0.5
        local ic3by  = sbY + sbH * 0.45
        local ib     = ic3sz * 0.11
        -- Outer square outline
        self:drawRect(ic3lx,               ic3by,               ic3sz, ib,     C.C_LABEL, 0.80)
        self:drawRect(ic3lx,               ic3by + ic3sz - ib,  ic3sz, ib,     C.C_LABEL, 0.80)
        self:drawRect(ic3lx,               ic3by,               ib,    ic3sz,  C.C_LABEL, 0.80)
        self:drawRect(ic3lx + ic3sz - ib,  ic3by,               ib,    ic3sz,  C.C_LABEL, 0.80)
        -- Centre cross
        local icm = ib * 0.70
        self:drawRect(ic3lx + ib, ic3by + ic3sz*0.5 - icm*0.5, ic3sz-ib*2, icm, C.C_LABEL, 0.40)
        self:drawRect(ic3lx + ic3sz*0.5 - icm*0.5, ic3by + ib, icm, ic3sz-ib*2, C.C_LABEL, 0.40)

        local sessHaStr = string.format("%.1f ha", sessHa)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(unpack(C.C_VALUE))
        renderText(cell3X + cellW * 0.5, sbY + (sbH * 0.35 - 0.0075) * 0.5, 0.0075, sessHaStr)

        -- ── Cell 4: Sigma field icon + total field area (ha) ───
        local cell4X = panelX + cellW * 3
        local ic4sz  = isz
        local ic4lx  = cell4X + (cellW - ic4sz) * 0.5 + ic4sz * 0.15
        local ic4by  = sbY + sbH * 0.45
        -- Same field icon (slightly right to leave room for Σ)
        self:drawRect(ic4lx,               ic4by,               ic4sz * 0.85, ib,              C.C_DIM, 0.80)
        self:drawRect(ic4lx,               ic4by + ic4sz - ib,  ic4sz * 0.85, ib,              C.C_DIM, 0.80)
        self:drawRect(ic4lx,               ic4by,               ib,           ic4sz,            C.C_DIM, 0.80)
        self:drawRect(ic4lx + ic4sz*0.85 - ib, ic4by,           ib,           ic4sz,            C.C_DIM, 0.80)
        -- Σ prefix (tiny, left of icon)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(C.C_DIM[1], C.C_DIM[2], C.C_DIM[3], 0.90)
        renderText(ic4lx - 0.001, ic4by + ic4sz * 0.25, ic4sz * 0.55, "S")

        local totHaStr = string.format("%.1f ha", totHa)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(C.C_DIM[1], C.C_DIM[2], C.C_DIM[3], 0.90)
        renderText(cell4X + cellW * 0.5, sbY + (sbH * 0.35 - 0.0075) * 0.5, 0.0075, totHaStr)
    end

    -- Reset text state
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end
