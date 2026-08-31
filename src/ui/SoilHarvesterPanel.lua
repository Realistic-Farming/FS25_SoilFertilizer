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
SoilHarvesterPanel = SoilHarvesterPanel or {}
local SoilHarvesterPanel_mt = Class(SoilHarvesterPanel)

-- ── Layout ────────────────────────────────────────────────
SoilHarvesterPanel.PAD     = 0.006
SoilHarvesterPanel.TITLE_H = 0.022
SoilHarvesterPanel.ROW_H   = 0.022
SoilHarvesterPanel.SEG_H   = 0.005556 -- 6 px at 1080p, base fill-level height
SoilHarvesterPanel.SEG_N   = 10      -- number of segments
SoilHarvesterPanel.SEG_GAP = 0.0018  -- gap between segments
SoilHarvesterPanel.PANEL_W = 0.210
SoilHarvesterPanel.STAT_H  = 0.040   -- stats bar (icons + values) at bottom
SoilHarvesterPanel.EST_H   = 0.012   -- provenance caption above the stats bar

-- Default position / scale: the suite layout Wizard arranged in-game (2026-08-22).
SoilHarvesterPanel.DEFAULT_X     = 0.328646
SoilHarvesterPanel.DEFAULT_Y     = 0.051111
SoilHarvesterPanel.DEFAULT_SCALE = 1.171455

SoilHarvesterPanel.WARN_THRESHOLD = 0.85  -- flash warning above this fill ratio

-- [SF-50] The hardcoded BASE_YIELD table was deleted here, deliberately WITHOUT a
-- fallback. The estimate is now computed from the map's own crop truth (see
-- computeYieldEstimate below). A stale fallback would be the same defect in disguise:
-- the table failed silently for its whole life because nothing audited it, whereas a
-- live read fails as a visible empty cell, which is a bug report within a day.

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

    self.editMode         = false
    self.dragging         = false
    self.dragOffsetX      = 0
    self.dragOffsetY      = 0
    self.resizing         = false
    self.resizeStartX     = 0
    self.resizeStartY     = 0
    self.resizeStartScale = 1.0
    self.userScale        = SoilHarvesterPanel.DEFAULT_SCALE
    self.movedInEditMode  = false
    self._animTimer       = 0

    self._lastPanelX = SoilHarvesterPanel.DEFAULT_X
    self._lastPanelY = SoilHarvesterPanel.DEFAULT_Y
    self._lastPanelW = SoilHarvesterPanel.PANEL_W
    self._lastPanelH = 0.120

    -- Field detection cache
    self._detectTimer = 0
    self._fieldId     = nil
    self._fieldInfo   = nil

    -- Per-frame draw cache (set by update, consumed by draw to avoid per-frame API calls)
    self._cachedCombine = nil
    self._cachedTank    = nil
    self._cachedCropFT  = nil

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
    if self.editMode then self:exitEditMode() end
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
    self.resizing = false
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
        xml:setFloat("harvesterPanelLayout.scale",  self.userScale or 1.0)
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
        self.userScale = xml:getFloat("harvesterPanelLayout.scale", SoilHarvesterPanel.DEFAULT_SCALE)
        xml:delete()
    end
end

-- ── Mouse event ───────────────────────────────────────────

function SoilHarvesterPanel:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.editMode then return false end

    if isDown and button == Input.MOUSE_BUTTON_LEFT and eventUsed then
        return false
    end

    local px = self._lastPanelX
    local py = self._lastPanelY
    local pw = self._lastPanelW
    local ph = self._lastPanelH
    local hs = 0.015 * (self.userScale or 1.0)

    -- LMB up: release drag or resize
    if isUp and button == Input.MOUSE_BUTTON_LEFT then
        if self.dragging or self.resizing then
            self.dragging = false
            self.resizing = false
            return true
        end
        return false
    end

    -- Mouse move: update position while dragging
    if self.dragging then
        self.panelX = math.max(0, math.min(1 - pw, posX - self.dragOffsetX))
        self.panelY = math.max(0, math.min(1 - ph, posY - self.dragOffsetY))
        return true
    end

    -- Mouse move: update scale while resizing (distance-from-center approach)
    if self.resizing then
        local cx = px + pw * 0.5
        local cy = py + ph * 0.5
        local startDist = math.sqrt((self.resizeStartX - cx)^2 + (self.resizeStartY - cy)^2)
        local currDist  = math.sqrt((posX - cx)^2 + (posY - cy)^2)
        local delta = (currDist - startDist) * 2.5
        local oldScale = self.userScale or 1.0
        local newScale = math.max(0.5, math.min(2.5, self.resizeStartScale + delta))
        local ratio = oldScale > 0 and newScale / oldScale or 1
        self.userScale = newScale
        self.panelX = math.max(0, math.min(1 - pw * ratio, self.panelX or px))
        self.panelY = math.max(0, math.min(1 - ph * ratio, self.panelY or py))
        return true
    end

    -- LMB down: resize corner (bottom-right) takes priority over drag
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        if posX >= (px + pw - hs) and posX <= (px + pw) and
           posY >= py and posY <= (py + hs) then
            self.panelX            = px
            self.panelY            = py
            self.resizing         = true
            self.dragging         = false
            self.resizeStartX     = posX
            self.resizeStartY     = posY
            self.resizeStartScale = self.userScale or 1.0
            self.movedInEditMode  = true
            return true
        end
        if posX >= px and posX <= px + pw and posY >= py and posY <= py + ph then
            self.panelX         = px
            self.panelY         = py
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
-- Works even when tank is empty (fill type UNKNOWN) - detects by largest capacity.
function SoilHarvesterPanel:getGrainTank(combine)
    if not combine then return nil end
    -- Use getFillUnits() - the correct FS25 API (getNumFillUnits does not exist)
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

-- ── Yield estimate [SF-50] ────────────────────────────────
-- Estimated t/ha read from the map's own crop truth instead of a hardcoded table:
--
--   literPerSqm x yieldScales[growthState] x 10000 m²/ha x massPerLiter x (yieldEff/100)
--
-- Every term is an engine descriptor read, so a map that retunes its fruit types retunes
-- this panel for free and there is nothing left to go stale.
--
-- Returns nil when ANY term is missing (unknown fill type, no live growth state, no yield
-- scale for that state, no mass conversion). The caller then renders the panel's no-data
-- marker - never a substituted constant.
--
-- Units: FillTypeDesc loads `physics#massPerLiter` as `value * 0.001`, so the stored
-- figure is TONNES per litre (wheat at 0.77 kg/L stores as 0.00077) and the product lands
-- directly in t/ha with no further scaling.
SoilHarvesterPanel._estUnitLogged = false

function SoilHarvesterPanel:computeYieldEstimate(cropFT, info)
    if not cropFT or not info then return nil end

    -- The state of the crop actually standing in the field, never the max-yield state:
    -- a max read systematically over-promises. nil = no live fruit (bare or fully cut).
    local growthState = info.growthState
    if growthState == nil then return nil end

    local fillIdx = cropFT.index
    if fillIdx == nil then return nil end

    local ok, fruitDesc = pcall(function()
        return g_fruitTypeManager and g_fruitTypeManager:getFruitTypeByFillTypeIndex(fillIdx)
    end)
    if not ok or fruitDesc == nil then return nil end

    local literPerSqm  = fruitDesc.literPerSqm
    -- yieldScales carries an entry ONLY for harvest-ready growth states, so a standing
    -- but unripe crop legitimately has no scale. Honest absence, not an error.
    local scale        = fruitDesc.yieldScales and fruitDesc.yieldScales[growthState]
    local massPerLiter = cropFT.massPerLiter

    if literPerSqm  == nil or literPerSqm  <= 0 then return nil end
    if scale        == nil or scale        <= 0 then return nil end
    if massPerLiter == nil or massPerLiter <= 0 then return nil end

    local yieldEff = info.yieldEfficiency or 100
    local estTha   = literPerSqm * scale * 10000 * massPerLiter * (yieldEff / 100)

    -- [SF50-C2] Print the raw term set once per session so massPerLiter's unit can be
    -- confirmed in-game against a known crop. Gated on debugMode so toggling SoilDebug
    -- on mid-session still produces the line.
    if not SoilHarvesterPanel._estUnitLogged
       and g_SoilFertilityManager and g_SoilFertilityManager.settings
       and g_SoilFertilityManager.settings.debugMode then
        SoilHarvesterPanel._estUnitLogged = true
        SoilLogger.debug(
            "[SoilHarvesterPanel][SF50-C2] fillType=%s literPerSqm=%s growthState=%s " ..
            "yieldScale=%s massPerLiter=%s yieldEff=%s -> %.2f t/ha",
            tostring(cropFT.name), tostring(literPerSqm), tostring(growthState),
            tostring(scale), tostring(massPerLiter), tostring(yieldEff), estTha)
    end

    return estTha
end

-- ── Field detection (throttled) ───────────────────────────

function SoilHarvesterPanel:update(dt)
    self._animTimer   = self._animTimer + dt
    self._detectTimer = self._detectTimer - dt * 0.001
    if self._detectTimer > 0 then return end
    self._detectTimer = 0.5

    local combine = self:getActiveCombine()
    if not combine then
        self._fieldId      = nil
        self._fieldInfo    = nil
        self._cachedCombine = nil
        self._cachedTank    = nil
        self._cachedCropFT  = nil
        return
    end

    local x, z
    local posNode = combine.rootNode
    if posNode then
        local ok, px, _, pz = pcall(getWorldTranslation, posNode)
        if ok then x, z = px, pz end
    end
    if not x then
        self._fieldId      = nil
        self._fieldInfo    = nil
        self._cachedCombine = nil
        self._cachedTank    = nil
        self._cachedCropFT  = nil
        return
    end

    local fieldId = nil
    if g_farmlandManager then
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
            -- Switched to a new field - reset session counter
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

    -- Cache for draw() so it doesn't repeat these API calls every rendered frame
    self._cachedCombine = combine
    self._cachedTank    = tank
    self._cachedCropFT  = combine and self:getCropFillType(combine, tank) or nil
end

-- ── Draw helpers ──────────────────────────────────────────

function SoilHarvesterPanel:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay or self.fillOverlay == 0 then return end
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], a or c[4] or 1.0)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

-- Draws the 10-segment battery-style bar
function SoilHarvesterPanel:drawTankBar(x, y, w, h, ratio, isWarning, pulse, gap)
    local N   = SoilHarvesterPanel.SEG_N
    gap = gap or SoilHarvesterPanel.SEG_GAP
    local segW   = (w - (N - 1) * gap) / N
    local filled = ratio * N
    local renderer = SoilHUD and SoilHUD.getBaseGameRenderer and SoilHUD.getBaseGameRenderer() or nil

    for i = 0, N - 1 do
        local sx   = x + i * (segW + gap)
        local frac = math.max(0, math.min(1, filled - i))
        local col = isWarning and SoilHarvesterPanel.C_SEG_WARN or SoilHarvesterPanel.C_SEG_FILL
        local alpha = isWarning and (0.6 + 0.4 * pulse) or 1.0
        local nativeColor = { col[1], col[2], col[3], alpha }
        local usedNativeSegment = renderer ~= nil and renderer.renderProgressBar ~= nil
            and renderer:renderProgressBar(sx, y, segW, h, frac, nativeColor)
        if not usedNativeSegment then
            -- Background
            self:drawRect(sx, y, segW, h, SoilHarvesterPanel.C_SEG_BG)
            -- Fill
            if frac > 0 then
                self:drawRect(sx, y, segW * frac, h, col, alpha)
            end
        end
    end
end

-- ── Main draw (called from FSBaseMission.draw) ────────────

function SoilHarvesterPanel:draw()
    if not self.initialized then return end
    if not self.settings or not self.settings.enabled then return end
    if not g_currentMission or not g_currentMission.isRunning then return end
    local _sfm = g_SoilFertilityManager
    -- Cab tool readouts follow the base-game HUD only. Suite hide-all and the
    -- Soil monitor toggle must not hide a working tool panel. Vanilla HUD-hide does.
    if not self.editMode and g_currentMission.hud
        and type(g_currentMission.hud.getIsVisible) == "function"
        and not g_currentMission.hud:getIsVisible() then return end
    -- Edit mode always exposes a placement placeholder, even when the runtime
    -- display preference is off or no combine is currently controlled.
    if not self.editMode and _sfm and _sfm.settings
        and _sfm.settings.showHarvesterPanel == false then return end
    if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
        if not self.editMode then return end
    end

    local combine  = self._cachedCombine
    local tank     = self._cachedTank
    local cropFT   = self._cachedCropFT
    local isActive = combine ~= nil

    if not self.editMode and not isActive then return end

    -- Layout (scaled by userScale)
    local sc     = self.userScale or 1.0
    local pad    = SoilHarvesterPanel.PAD    * sc
    local titleH = SoilHarvesterPanel.TITLE_H * sc
    local rowH   = SoilHarvesterPanel.ROW_H   * sc
    local segH   = SoilHarvesterPanel.SEG_H   * sc
    local panelW = SoilHarvesterPanel.PANEL_W  * sc

    -- Rows: tank bar + fill text + yield (+ stats bar when active). The separator
    -- sits on the fill/yield boundary instead of consuming an empty row.
    local numContentRows = isActive and 3 or 1
    local statH  = isActive and (SoilHarvesterPanel.STAT_H * sc) or 0
    -- [SF-50] Reserve a thin band above the stats bar for the estimate's provenance
    -- caption. The panel is anchored bottom-left, so this grows it upward and leaves
    -- the saved position untouched.
    local estH   = isActive and (SoilHarvesterPanel.EST_H * sc) or 0
    local panelH = titleH + pad + numContentRows * rowH + statH + estH + pad

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

    local renderer = SoilHUD and SoilHUD.getBaseGameRenderer and SoilHUD.getBaseGameRenderer() or nil
    local usedNativePanel = renderer ~= nil and renderer.renderPanel ~= nil
        and renderer:renderPanel(panelX, panelBot, panelW, panelH,
            SoilHarvesterPanel.C_BG[4] or 0.82)
    if not usedNativePanel then
        -- Shadow
        self:drawRect(panelX + 0.002*sc, panelBot - 0.002*sc, panelW, panelH, {0,0,0,1}, 0.22)
        -- Background
        self:drawRect(panelX, panelBot, panelW, panelH, SoilHarvesterPanel.C_BG)
        -- Border
        self:drawRect(panelX, panelBot, panelW, panelH, SoilHarvesterPanel.C_BORDER, 0.55)
        -- Title bar
        self:drawRect(panelX, panelTop - titleH, panelW, titleH, SoilHarvesterPanel.C_TITLE_BG)
    end

    -- Edit mode chrome: pulsing border + resize handle
    if self.editMode then
        local ebw = 0.002 * sc
        local C = SoilHarvesterPanel.C_EDIT_HDL
        setOverlayColor(self.fillOverlay, C[1], C[2], C[3], C[4] * (0.55 + 0.45 * pulse))
        renderOverlay(self.fillOverlay, panelX,                panelBot,          ebw,    panelH)
        renderOverlay(self.fillOverlay, panelX + panelW - ebw,  panelBot,          ebw,    panelH)
        renderOverlay(self.fillOverlay, panelX,                panelBot,          panelW, ebw)
        renderOverlay(self.fillOverlay, panelX,                panelTop - ebw,    panelW, ebw)
        -- Resize handle (bottom-right corner)
        local hs = 0.015 * sc
        self:drawRect(panelX + panelW - hs, panelBot, hs, hs, SoilHarvesterPanel.C_EDIT_HDL)
    end

    -- Title text
    local titleFontSz = 0.0095 * sc
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

    local lblSz = 0.0085 * sc
    local valSz = 0.0085 * sc
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

        self:drawTankBar(barX, barMidY, barW, segH, ratio, isWarning, pulse, SoilHarvesterPanel.SEG_GAP * sc)
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

        -- Native-style one-pixel divider on the row boundary.
        local dividerH = SoilHUD and SoilHUD.getSeparatorHeight
            and SoilHUD.getSeparatorHeight() or (g_pixelSizeY or (1 / 1080))
        self:drawRect(panelX + pad, cy - dividerH * 0.5,
            panelW - pad * 2, dividerH, SoilHarvesterPanel.C_DIVIDER, 0.70)

        -- ── Row 4: Yield efficiency ────────────────────────
        local yieldRowBot = cy - rowH
        local yieldTextY  = yieldRowBot + (rowH - lblSz) * 0.42

        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextColor(unpack(SoilHarvesterPanel.C_LABEL))
        renderText(panelX + pad, yieldTextY, lblSz, "Yield eff.")

        local info = self._fieldInfo
        if info and info.yieldEfficiency then
            local pct    = info.yieldEfficiency  -- already 0-100 integer from getFieldInfo()
            local effCol = (info.yieldEfficiency >= 80) and SoilHarvesterPanel.C_GOOD
                        or (info.yieldEfficiency >= 55) and SoilHarvesterPanel.C_FAIR
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
        local sbH = statH
        local sbW = panelW

        local dividerW = g_pixelSizeX or (1 / 1920)
        -- Dark separator line above stats bar
        self:drawRect(panelX, sbY + sbH - dividerH, panelW, dividerH,
                      SoilHarvesterPanel.C_DIVIDER, 0.80)

        -- Faint cell dividers
        local cellW = sbW / 4
        for i = 1, 3 do
            self:drawRect(panelX + cellW * i - dividerW * 0.5, sbY + pad,
                          dividerW, sbH - pad * 2,
                          SoilHarvesterPanel.C_BORDER, 0.60)
        end

        -- Gather values
        local fieldArea     = (info and info.fieldArea) or 0
        local daysSinceHarv = (info and info.daysSinceHarvest) or 0

        -- [SF-50] Yield estimate computed from the map's own crop truth.
        -- nil means a term was missing; the cell says so rather than inventing a number.
        local estTha = self:computeYieldEstimate(cropFT, info)

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

        -- [SF-50] Honest absence: when a term is missing the cell shows the panel's own
        -- no-data marker (the same "--" the yield-efficiency row uses), never a
        -- substituted yield number.
        local thaSz  = 0.0075 * sc
        local thaY   = sbY + (sbH * 0.35 - thaSz) * 0.5
        setTextAlignment(RenderText.ALIGN_CENTER)
        if estTha then
            local okT, fmtT = pcall(function() return g_i18n:getText("sf_hud_tha") end)
            local thaStr = (okT and fmtT and not fmtT:find("^%$l10n_"))
                           and string.format(fmtT, estTha)
                           or  string.format("%.1f t/ha", estTha)
            setTextColor(unpack(C.C_VALUE))
            renderText(cell1X + cellW * 0.5, thaY, thaSz, thaStr)
        else
            setTextColor(unpack(C.C_DIM))
            renderText(cell1X + cellW * 0.5, thaY, thaSz, "--")
        end

        -- ── [SF-50] Provenance caption ────────────────────────
        -- The t/ha figure is estimated from the map's crop data, not measured from what
        -- the player actually took off the field. Say so plainly, in their language.
        local capSz = 0.0062 * sc
        local okCap, capStr = pcall(function() return g_i18n:getText("sf_hud_yield_est_src") end)
        if okCap and capStr and not capStr:find("^%$l10n_") then
            setTextAlignment(RenderText.ALIGN_LEFT)
            setTextColor(unpack(C.C_DIM))
            renderText(panelX + pad,
                       sbY + sbH + (estH - capSz) * 0.5,
                       capSz, capStr)
        end

        -- ── Cell 2: Grain bag icon + session grain (L) ──────────
        local cell2X  = panelX + cellW
        local sessL   = self._sessGrainL or 0
        local grainStr
        if sessL >= 1000 then
            grainStr = string.format("%.1f kL", sessL / 1000)
        else
            grainStr = string.format("%d L", math.floor(sessL + 0.5))
        end
        -- Grain bag icon (bag body + neck + tie knot)
        local gb_sz = isz
        local gb_x  = cell2X + (cellW - gb_sz * 0.75) * 0.5
        local gb_y  = sbY + sbH * 0.42
        self:drawRect(gb_x,               gb_y,              gb_sz * 0.75, gb_sz * 0.58, C.C_TITLE_FG, 0.85)
        self:drawRect(gb_x + gb_sz*0.20,  gb_y + gb_sz*0.58, gb_sz * 0.35, gb_sz * 0.20, C.C_TITLE_FG, 0.72)
        self:drawRect(gb_x + gb_sz*0.27,  gb_y + gb_sz*0.76, gb_sz * 0.21, gb_sz * 0.12, C.C_TITLE_FG, 0.60)

        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(unpack(C.C_VALUE))
        renderText(cell2X + cellW * 0.5, sbY + (sbH * 0.35 - 0.0075*sc) * 0.5, 0.0075*sc, grainStr)

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

        local areaStr = string.format("%.1f ha", fieldArea)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(unpack(C.C_VALUE))
        renderText(cell3X + cellW * 0.5, sbY + (sbH * 0.35 - 0.0075*sc) * 0.5, 0.0075*sc, areaStr)

        -- ── Cell 4: Calendar icon + days since last harvest ────
        local cell4X = panelX + cellW * 3
        local ic4sz  = isz
        local ic4lx  = cell4X + (cellW - ic4sz) * 0.5
        local ic4by  = sbY + sbH * 0.45
        -- Calendar icon: box body + header bar + two ring notches
        self:drawRect(ic4lx,               ic4by,               ic4sz, ic4sz * 0.85, C.C_DIM, 0.40)
        self:drawRect(ic4lx,               ic4by + ic4sz * 0.72, ic4sz, ic4sz * 0.13, C.C_DIM, 0.90)
        self:drawRect(ic4lx + ic4sz*0.22,  ic4by + ic4sz * 0.79, ic4sz * 0.16, ic4sz * 0.22, C.C_TITLE_BG, 1.0)
        self:drawRect(ic4lx + ic4sz*0.62,  ic4by + ic4sz * 0.79, ic4sz * 0.16, ic4sz * 0.22, C.C_TITLE_BG, 1.0)

        local dayStr = (daysSinceHarv > 0) and string.format("%dd", math.floor(daysSinceHarv)) or "--"
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextColor(C.C_DIM[1], C.C_DIM[2], C.C_DIM[3], 0.90)
        renderText(cell4X + cellW * 0.5, sbY + (sbH * 0.35 - 0.0075*sc) * 0.5, 0.0075*sc, dayStr)
    end

    -- Reset text state
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(false)
end

-- Hot-reload: preserve the class table and patch the already-constructed panel.
local sfm = g_SoilFertilityManager
if sfm == nil and g_currentMission ~= nil then sfm = g_currentMission.soilFertilityManager end
if sfm ~= nil and sfm.harvesterPanel ~= nil then
    for k, v in pairs(SoilHarvesterPanel) do
        if type(v) == "function" then sfm.harvesterPanel[k] = v end
    end
end
