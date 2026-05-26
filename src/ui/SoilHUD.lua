-- =========================================================
-- FS25 Realistic Soil & Fertilizer
-- =========================================================
-- Soil HUD Overlay - live field soil monitor
-- Shows N/P/K/pH/OM for the field the player is standing on.
-- Toggle with J key. Shift+H to enter HUD edit mode; RMB or Shift+H again to exit.
-- =========================================================
-- Author: TisonK
-- =========================================================
---@class SoilHUD

SoilHUD = {}
local SoilHUD_mt = Class(SoilHUD)

-- ── Scale / resize ──────────────────────────────────────
SoilHUD.MIN_SCALE          = 0.60
SoilHUD.MAX_SCALE          = 1.80
SoilHUD.RESIZE_HANDLE_SIZE = 0.008

-- ── Base panel dimensions at scale 1.0 ─────────────────
SoilHUD.BASE_W = 0.190
SoilHUD.BASE_H = 0.228   -- Default fallback height

-- ── Layout constants at scale 1.0 ──────────────────────
SoilHUD.TITLE_H   = 0.024   -- title accent bar height
SoilHUD.ROW_H     = 0.022   -- nutrient row height
SoilHUD.LINE_H    = 0.018   -- text-only row height
SoilHUD.PAD       = 0.006   -- inner padding
SoilHUD.BAR_H     = 0.010   -- nutrient bar fill height
SoilHUD.BAR_W     = 0.095   -- nutrient bar width

-- ── Colors ──────────────────────────────────────────────
SoilHUD.C_BG         = {0.05, 0.05, 0.05, 0.82}   -- dark, matches native Field Info
SoilHUD.C_TITLE_BG   = {0.10, 0.10, 0.10, 0.90}   -- subtle dark header, no colored accent
SoilHUD.C_BORDER     = {0.20, 0.20, 0.20, 0.40}   -- neutral dark border
SoilHUD.C_DIVIDER    = {0.25, 0.25, 0.25, 0.45}   -- neutral divider
SoilHUD.C_SHADOW     = {0.00, 0.00, 0.00, 0.30}
SoilHUD.C_BAR_BG     = {0.18, 0.18, 0.18, 0.90}   -- neutral bar track
SoilHUD.C_GOOD       = {0.25, 0.85, 0.25, 1.00}   -- green  — data color, keep
SoilHUD.C_FAIR       = {0.90, 0.82, 0.18, 1.00}   -- yellow — data color, keep
SoilHUD.C_POOR       = {0.88, 0.25, 0.25, 1.00}   -- red    — data color, keep
-- Okabe-Ito colorblind-safe palette (orange / yellow / blue)
SoilHUD.CB_GOOD      = {0.00, 0.45, 0.70, 1.00}   -- blue
SoilHUD.CB_FAIR      = {0.94, 0.86, 0.00, 1.00}   -- yellow
SoilHUD.CB_POOR      = {0.90, 0.37, 0.00, 1.00}   -- vermillion/orange
SoilHUD.C_LABEL      = {0.72, 0.72, 0.72, 1.00}   -- neutral gray, no green tint
SoilHUD.C_VALUE      = {1.00, 1.00, 1.00, 1.00}
SoilHUD.C_DIM        = {0.52, 0.52, 0.52, 0.85}   -- neutral dim
SoilHUD.C_HINT       = {0.45, 0.45, 0.58, 0.75}
SoilHUD.C_EDIT_HDL   = {0.20, 0.60, 1.00, 0.85}

-- ── Field detection throttle ────────────────────────────
SoilHUD.FIELD_DETECT_INTERVAL = 0.5   -- seconds between position queries

function SoilHUD.new(soilSystem, settings)
    local self = setmetatable({}, SoilHUD_mt)

    self.soilSystem  = soilSystem
    self.settings    = settings
    self.initialized = false
    self.visible     = true

    -- Position (from preset, overridden by drag)
    local defaultPos = SoilConstants.HUD.POSITIONS[1]
    self.panelX          = defaultPos.x
    self.panelY          = defaultPos.y
    self.lastHudPosition = nil

    -- Scale & edit state
    self.scale            = 1.0
    self.editMode         = false
    self.dragging         = false
    self.resizing         = false
    self.dragOffsetX      = 0
    self.dragOffsetY      = 0
    self.resizeStartX     = 0
    self.resizeStartY     = 0
    self.resizeStartScale = 1.0
    self.hoverCorner      = nil
    self.animTimer        = 0

    -- Mini-Report state (persisted in settings, managed here)
    self.reportX         = 0.18   -- Initial absolute default (near minimap)
    self.reportY         = 0.015
    self.reportScale     = 1.0
    self.draggingReport  = false
    self.reportDragOffsetX = 0
    self.reportDragOffsetY = 0
    self.miniReportRect  = { x=0, y=0, w=0, h=0 }

    -- Sub-panel free positioning (independent mode)
    self.freePos        = { smartSensor = {}, seeAndSpray = {}, varRate = {} }
    self.draggingSubKey = nil   -- key into freePos while dragging a sub-panel
    self.subDragOffX    = 0
    self.subDragOffY    = 0

    -- Loaded-from-disk collapsed states applied on first panel draw
    self.savedCollapsed = { smartSensor = false, seeAndSpray = false, varRate = false }

    -- Camera freeze (NPCFavor pattern)
    self.savedCamRotX = nil
    self.savedCamRotY = nil
    self.savedCamRotZ = nil

    -- Field detection cache (throttled)
    self.cachedFieldId    = nil
    self.cachedFieldInfo  = nil
    self.fieldDetectTimer = 0

    -- Pre-formatted display strings (updated in refreshFieldData at 2 Hz, not in draw at 60 FPS)
    self._fmt_fieldText = nil
    self._fmt_cropText  = nil
    self._fmt_pHStr     = nil
    self._fmt_omStr     = nil
    self._fmt_N         = nil
    self._fmt_P         = nil
    self._fmt_K         = nil

    -- Cached sprayer state (updated in update(), consumed in draw())
    self._cachedSprayer    = nil
    self._cachedFillType   = nil
    self._cachedProfile    = nil
    self._cachedRateMult   = 1.0

    -- Height dirty flag: set by refreshFieldData, cleared after calculateHeight()
    self._heightDirty = true

    -- Single overlay handle
    self.fillOverlay = nil

    -- Native FS25 InfoDisplay box (appears alongside base game FIELD INFO panel)
    self.fieldInfoBox = nil

    return self
end

-- ── Initialize ───────────────────────────────────────────
function SoilHUD:initialize()
    if self.initialized then return true end
    self:updatePosition()
    self:loadLayout()   -- override preset with saved position/scale if available
    
    -- Sync initial report coordinates to settings if they were loaded
    self.reportX     = self.settings.miniReportX or self.reportX
    self.reportY     = self.settings.miniReportY or self.reportY
    self.reportScale = self.settings.miniReportScale or self.reportScale

    if createImageOverlay ~= nil then
        self.fillOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    else
        SoilLogger.warning("SoilHUD: createImageOverlay not available")
    end

    -- ── Native FS25 Field Info box ────────────────────────
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.infoDisplay then
        local ok, box = pcall(function()
            return g_currentMission.hud.infoDisplay:createBox(InfoDisplayKeyValueBox)
        end)
        if ok and box then
            self.fieldInfoBox = box
            SoilLogger.info("SoilHUD: FieldInfoBox registered with native HUD infoDisplay")
        else
            SoilLogger.warning("SoilHUD: infoDisplay:createBox() failed — SOIL NUTRIENTS box will not appear")
        end
    else
        SoilLogger.info("SoilHUD: infoDisplay not available (server or early init) — skipping FieldInfoBox")
    end

    self.initialized = true
    SoilLogger.info("SoilHUD initialized at (%.3f, %.3f) scale=%.2f", self.panelX, self.panelY, self.scale)
    return true
end

-- ── Delete ───────────────────────────────────────────────
function SoilHUD:delete()
    if self.editMode then self:exitEditMode() end
    if self.fillOverlay then
        delete(self.fillOverlay)
        self.fillOverlay = nil
    end
    -- Remove the native FieldInfoBox from the HUD before shutdown
    if self.fieldInfoBox then
        if g_currentMission and g_currentMission.hud and g_currentMission.hud.infoDisplay then
            pcall(function()
                g_currentMission.hud.infoDisplay:destroyBox(self.fieldInfoBox)
            end)
        end
        self.fieldInfoBox = nil
    end
    self.initialized = false
end

-- ── Position preset ──────────────────────────────────────
function SoilHUD:updatePosition()
    -- hudPosition 6 = Custom: use whatever loadLayout() restored, don't overwrite
    if (self.settings.hudPosition or 1) == 6 then return end
    local pos = SoilConstants.HUD.POSITIONS[self.settings.hudPosition or 1]
    if pos then
        self.panelX = pos.x
        self.panelY = pos.y
    end
end

-- ── Edit mode ────────────────────────────────────────────
function SoilHUD:enterEditMode()
    self.editMode = true
    self.dragging = false
    self.movedInEditMode = false
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(true, true)
    end
    if getCamera and getRotation then
        local ok, cam = pcall(getCamera)
        if ok and cam and cam ~= 0 then
            local ok2, rx, ry, rz = pcall(getRotation, cam)
            if ok2 then
                self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = rx, ry, rz
            end
        end
    end
    SoilLogger.debug("[SoilHUD] Edit mode ON")
end

function SoilHUD:exitEditMode()
    self.editMode       = false
    self.dragging       = false
    self.resizing       = false
    self.hoverCorner    = nil
    self.draggingSubKey = nil
    self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ = nil, nil, nil
    if g_inputBinding and g_inputBinding.setShowMouseCursor then
        g_inputBinding:setShowMouseCursor(false)
    end
    self:saveLayout()
    -- If the player actually moved/resized, switch setting to Custom (6)
    if self.movedInEditMode then
        self.movedInEditMode = false
        self.settings.hudPosition = 6
        self.settings:save()
        if g_SoilFertilityManager and g_SoilFertilityManager.settingsUI then
            g_SoilFertilityManager.settingsUI:refreshUI()
        end
    end
    SoilLogger.debug("[SoilHUD] Edit mode OFF — pos=(%.3f,%.3f) scale=%.2f",
        self.panelX, self.panelY, self.scale)
end

-- ── HUD layout persistence ────────────────────────────────
function SoilHUD:getLayoutPath()
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if base then
        return base .. "/HUD/hud.xml"
    end
    -- Fallback for self-hosted / singleplayer environments without a profile path.
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameDirectory then
        return g_currentMission.missionInfo.savegameDirectory .. "/FS25_SoilFertilizer_hud.xml"
    end
end

function SoilHUD:saveLayout()
    local path = self:getLayoutPath()
    if not path then return end
    local xml = XMLFile.create("sf_hud", path, "hudLayout")
    if xml then
        xml:setFloat("hudLayout.panelX",  self.panelX)
        xml:setFloat("hudLayout.panelY",  self.panelY)
        xml:setFloat("hudLayout.scale",   self.scale)
        xml:setBool("hudLayout.visible",  self.visible)

        -- Sub-panel free positions
        for _, key in ipairs({"smartSensor", "seeAndSpray", "varRate"}) do
            local fp = self.freePos[key]
            if fp and fp.x ~= nil then
                xml:setFloat("hudLayout.freePosX_" .. key, fp.x)
                xml:setFloat("hudLayout.freePosY_" .. key, fp.y)
            end
        end

        -- Sub-panel collapsed states
        local sfm = g_SoilFertilityManager
        if sfm then
            local panels = {
                smartSensor = sfm.smartSensorPanel,
                seeAndSpray = sfm.seeAndSprayPanel,
                varRate     = sfm.variableRatePanel,
            }
            for key, p in pairs(panels) do
                if p then xml:setBool("hudLayout.collapsed_" .. key, p.collapsed) end
            end
        end

        xml:save()
        xml:delete()
    end
end

function SoilHUD:loadLayout()
    local path = self:getLayoutPath()
    if not path or not fileExists(path) then return end
    local xml = XMLFile.load("sf_hud", path)
    if xml then
        self.panelX  = xml:getFloat("hudLayout.panelX",  self.panelX)
        self.panelY  = xml:getFloat("hudLayout.panelY",  self.panelY)
        self.scale   = xml:getFloat("hudLayout.scale",   self.scale)
        self.visible = xml:getBool("hudLayout.visible",  self.visible)

        -- Sub-panel free positions
        for _, key in ipairs({"smartSensor", "seeAndSpray", "varRate"}) do
            local xKey = "hudLayout.freePosX_" .. key
            local yKey = "hudLayout.freePosY_" .. key
            local x = xml:getFloat(xKey, nil)
            local y = xml:getFloat(yKey, nil)
            if x ~= nil and y ~= nil then
                self.freePos[key] = { x = x, y = y }
            end
        end

        -- Sub-panel collapsed states (applied on first draw since panels may not exist yet)
        self.savedCollapsed = {
            smartSensor = xml:getBool("hudLayout.collapsed_smartSensor", false),
            seeAndSpray = xml:getBool("hudLayout.collapsed_seeAndSpray", false),
            varRate     = xml:getBool("hudLayout.collapsed_varRate",     false),
        }

        xml:delete()
        SoilLogger.info("[SoilHUD] Layout loaded: pos=(%.3f,%.3f) scale=%.2f", self.panelX, self.panelY, self.scale)
    end
end

-- ── Geometry helpers ─────────────────────────────────────
function SoilHUD:calculateHeight()
    local h = SoilHUD.TITLE_H + SoilHUD.PAD

    local info = self.cachedFieldInfo
    local ys = SoilConstants and SoilConstants.YIELD_SENSITIVITY
    
    if info then
        h = h + SoilHUD.LINE_H
        h = h + SoilHUD.PAD * 1.6
        
        h = h + SoilHUD.ROW_H * 3
        h = h + SoilHUD.PAD * 1.3
        
        h = h + SoilHUD.LINE_H
        h = h + SoilHUD.PAD * 1.3
        
        local mgr = g_SoilFertilityManager
        if mgr and mgr.settings then
            if mgr.settings.weedPressure and (info.weedPressure or 0) > 0 then h = h + SoilHUD.LINE_H end
            if mgr.settings.pestPressure and (info.pestPressure or 0) > 0 then h = h + SoilHUD.LINE_H end
            if mgr.settings.diseasePressure and (info.diseasePressure or 0) > 0 then h = h + SoilHUD.LINE_H end
            if (info.sessionCoverageFraction or info.coverageFraction or 0) > 0 then h = h + SoilHUD.LINE_H end
            if mgr.settings.compactionEnabled and (info.compaction or 0) > 0 then h = h + SoilHUD.LINE_H end
        end
        if info.yieldEfficiency then h = h + SoilHUD.LINE_H end
        
        h = h + SoilHUD.PAD * 1.3
    else
        h = h + SoilHUD.LINE_H
        h = h + SoilHUD.LINE_H * 4
    end

    h = h + SoilHUD.LINE_H
    h = h + SoilHUD.PAD

    self.currentHeight = h
end

function SoilHUD:getHUDRect()
    local s = self.scale
    local h = self.currentHeight or SoilHUD.BASE_H
    return self.panelX, self.panelY, SoilHUD.BASE_W * s, h * s
end

function SoilHUD:isPointerOverHUD(posX, posY)
    local px, py, pw, ph = self:getHUDRect()
    return posX >= px and posX <= px + pw
       and posY >= py and posY <= py + ph
end

function SoilHUD:getResizeHandleRects()
    local px, py, pw, ph = self:getHUDRect()
    local hs = SoilHUD.RESIZE_HANDLE_SIZE
    return {
        bl = {x = px,        y = py,        w = hs, h = hs},
        br = {x = px+pw-hs,  y = py,        w = hs, h = hs},
        tl = {x = px,        y = py+ph-hs,  w = hs, h = hs},
        tr = {x = px+pw-hs,  y = py+ph-hs,  w = hs, h = hs},
    }
end

function SoilHUD:hitTestCorner(posX, posY)
    for key, r in pairs(self:getResizeHandleRects()) do
        if posX >= r.x and posX <= r.x + r.w
        and posY >= r.y and posY <= r.y + r.h then
            return key
        end
    end
    return nil
end

function SoilHUD:clampPosition()
    local s = self.scale
    local h = self.currentHeight or SoilHUD.BASE_H
    local pw, ph = SoilHUD.BASE_W * s, h * s
    self.panelX = math.max(0.01, math.min(1.0 - pw - 0.01, self.panelX))
    self.panelY = math.max(0.01, math.min(0.98 - ph, self.panelY))
end

-- ── Sub-panel helpers ────────────────────────────────────

-- Returns (x, y) for sub-panel key. Initialises to (defX, defY) on first call.
function SoilHUD:getFreePos(key, defX, defY)
    local fp = self.freePos[key]
    if not fp then self.freePos[key] = {} ; fp = self.freePos[key] end
    if fp.x == nil then
        fp.x = defX
        fp.y = defY
    end
    return fp.x, fp.y
end

-- Simple AABB hit test for a {x,y,w,h} rect.
function SoilHUD:hitRect(px, py, rect)
    if not rect then return false end
    return px >= rect.x and px <= rect.x + rect.w
       and py >= rect.y and py <= rect.y + rect.h
end

-- ── Mouse event ──────────────────────────────────────────
-- Returns true when the event is consumed so the caller can propagate eventUsed correctly.
function SoilHUD:onMouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    if not self.initialized then return false end

    -- RMB: cancel/exit edit mode only. Never enters edit mode (that's Shift+H via SF_HUD_DRAG).
    -- This ensures RMB is never consumed during normal play, so CoursePlay and AutoDrive
    -- receive their RMB events uninterrupted.
    if isDown and button == Input.MOUSE_BUTTON_RIGHT then
        if self.editMode then
            self:exitEditMode()
            return true
        end
        return false
    end

    if not self.settings.enabled then return false end
    if not self.settings.showHUD then return false end
    if not self.visible then return false end
    if not self.editMode then return false end

    -- LMB down: start drag or resize
    if isDown and button == Input.MOUSE_BUTTON_LEFT then
        -- 1. Check Main Panel
        local corner = self:hitTestCorner(posX, posY)
        if corner then
            self.resizing = true ; self.dragging = false
            self.resizeStartX = posX ; self.resizeStartY = posY
            self.resizeStartScale = self.scale
            self.movedInEditMode = true
            return true
        end
        if self:isPointerOverHUD(posX, posY) then
            self.dragging = true ; self.resizing = false
            self.dragOffsetX = posX - self.panelX
            self.dragOffsetY = posY - self.panelY
            self.movedInEditMode = true
            return true
        end

        -- 2. Check Mini-Report Panel
        if self.miniReportRect then
            local r = self.miniReportRect
            local cornerSize = 0.015
            local inCorner = posX >= (r.x + r.w - cornerSize) and posX <= (r.x + r.w) and
                             posY >= r.y and posY <= (r.y + cornerSize)

            if inCorner then
                self.resizingReport = true ; self.draggingReport = false
                self.reportResizeStartX = posX ; self.reportResizeStartY = posY
                self.reportResizeStartScale = self.settings.miniReportScale or 1.0
                self.movedInEditMode = true
                return true
            end

            if posX >= r.x and posX <= r.x + r.w and posY >= r.y and posY <= r.y + r.h then
                self.draggingReport = true ; self.resizingReport = false
                self.reportDragOffsetX = posX - (self.settings.miniReportX or 0.18)
                self.reportDragOffsetY = posY - (self.settings.miniReportY or 0.015)
                self.movedInEditMode = true
                return true
            end
        end

        -- 3. Check sub-panel collapse buttons (must be before drag so click doesn't start drag)
        local sfm = g_SoilFertilityManager
        if sfm then
            local subPanels = {
                { panel = sfm.smartSensorPanel,  key = "smartSensor" },
                { panel = sfm.seeAndSprayPanel,  key = "seeAndSpray" },
                { panel = sfm.variableRatePanel, key = "varRate"     },
            }
            for _, sp in ipairs(subPanels) do
                local p = sp.panel
                if p and self:hitRect(posX, posY, p.collapseButtonRect) then
                    p.collapsed = not p.collapsed
                    self:saveLayout()
                    return true
                end
            end
            -- 4. Sub-panel drag (independent mode only)
            if self.settings and self.settings.independentPanels then
                for _, sp in ipairs(subPanels) do
                    local p = sp.panel
                    if p and self:hitRect(posX, posY, p.lastDrawRect) then
                        self.draggingSubKey = sp.key
                        local fp = self.freePos[sp.key] or {}
                        self.subDragOffX = posX - (fp.x or posX)
                        self.subDragOffY = posY - (fp.y or posY)
                        self.movedInEditMode = true
                        return true
                    end
                end
            end
        end
        return false
    end

    -- LMB up: release drag/resize
    if isUp and button == Input.MOUSE_BUTTON_LEFT then
        if self.draggingSubKey then
            self.draggingSubKey = nil
            self:saveLayout()
            return true
        end
        if self.dragging or self.resizing or self.draggingReport or self.resizingReport then
            self.dragging = false ; self.resizing = false
            self.draggingReport = false ; self.resizingReport = false
            self:clampPosition()
            return true
        end
        return false
    end

    -- Mouse move
    if self.draggingSubKey then
        local fp = self.freePos[self.draggingSubKey]
        if not fp then self.freePos[self.draggingSubKey] = {} ; fp = self.freePos[self.draggingSubKey] end
        fp.x = posX - self.subDragOffX
        fp.y = posY - self.subDragOffY
        return true
    end

    if self.dragging then
        local pw = SoilHUD.BASE_W * self.scale
        self.panelX = math.max(0.0, math.min(1.0 - pw, posX - self.dragOffsetX))
        self.panelY = math.max(0.05, math.min(0.95, posY - self.dragOffsetY))
        return true
    end

    if self.draggingReport then
        self.settings.miniReportX = posX - self.reportDragOffsetX
        self.settings.miniReportY = posY - self.reportDragOffsetY
        return true
    end

    if self.resizingReport then
        local px, py = self.settings.miniReportX or 0.18, self.settings.miniReportY or 0.015
        local pw, ph = self.miniReportRect.w, self.miniReportRect.h
        local cx, cy = px + pw * 0.5, py + ph * 0.5
        local startDist = math.sqrt((self.reportResizeStartX-cx)^2 + (self.reportResizeStartY-cy)^2)
        local currDist  = math.sqrt((posX-cx)^2 + (posY-cy)^2)
        local delta = (currDist - startDist) * 2.5
        self.settings.miniReportScale = math.max(0.5,
            math.min(2.0, self.reportResizeStartScale + delta))
        return true
    end

    if self.resizing then
        local px, py, pw, ph = self:getHUDRect()
        local cx, cy = px + pw * 0.5, py + ph * 0.5
        local startDist = math.sqrt((self.resizeStartX-cx)^2 + (self.resizeStartY-cy)^2)
        local currDist  = math.sqrt((posX-cx)^2 + (posY-cy)^2)
        local delta = (currDist - startDist) * 2.5
        self.scale = math.max(SoilHUD.MIN_SCALE,
            math.min(SoilHUD.MAX_SCALE, self.resizeStartScale + delta))
        self:clampPosition()
        return true
    end

    self.hoverCorner = self:hitTestCorner(posX, posY)
    return false
end

-- ── Update ───────────────────────────────────────────────
function SoilHUD:update(dt)
    self.animTimer = self.animTimer + dt
    if self._heightDirty then
        self:calculateHeight()
        self._heightDirty = false
    end

    local currentPosition = self.settings.hudPosition or 1
    if not self.editMode and not self.dragging and self.lastHudPosition ~= currentPosition then
        self:updatePosition()
        self.lastHudPosition = currentPosition
    end


    if self.editMode then
        if self.savedCamRotX ~= nil and getCamera and setRotation then
            local ok, cam = pcall(getCamera)
            if ok and cam and cam ~= 0 then
                pcall(setRotation, cam, self.savedCamRotX, self.savedCamRotY, self.savedCamRotZ)
            end
        end
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then
            self:exitEditMode()
        end
        if not self.dragging and not self.resizing then
            if g_inputBinding and g_inputBinding.mousePosXLast then
                self.hoverCorner = self:hitTestCorner(
                    g_inputBinding.mousePosXLast, g_inputBinding.mousePosYLast)
            end
        end
    else
        self.hoverCorner = nil
    end

    -- Throttled field detection (every 0.5s)
    self.fieldDetectTimer = self.fieldDetectTimer + dt * 0.001
    if self.fieldDetectTimer >= SoilHUD.FIELD_DETECT_INTERVAL then
        self.fieldDetectTimer = 0
        self:refreshFieldData()
    end

    -- Cache sprayer state once per frame here so draw() never traverses vehicle tables
    local sprayer = self:getCurrentSprayer()
    self._cachedSprayer  = sprayer
    self._cachedFillType = self:getSprayerFillType(sprayer)
    self._cachedProfile  = self._cachedFillType and SoilConstants.FERTILIZER_PROFILES[self._cachedFillType.name]
    local rm             = g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager
    self._cachedRateMult = (rm and sprayer) and rm:getMultiplier(sprayer.id) or 1.0

    self:updateFieldInfoBox()
end

-- ── Native FIELD INFO box ────────────────────────────────
-- Populates an InfoDisplayKeyValueBox (same style as the base game FIELD INFO panel)
-- with a full soil summary for the current field. Called every frame so showNextFrame()
-- keeps the box visible; stops calling when off-field so it auto-hides.
function SoilHUD:updateFieldInfoBox()
    local box = self.fieldInfoBox
    if not box then return end

    if self.settings and self.settings.showFieldInfoBox == false then return end

    -- Only show the native FIELD INFO style box when actually on a field.
    -- This prevents it from showing up on roads, grass, or yards (Tier 2 farmland fallback).
    if not self.isOnField then return end

    local info = self.cachedFieldInfo
    if not info then return end

    if not g_SoilFertilityManager or not g_SoilFertilityManager.settings.enabled then return end

    local ppm = SoilConstants.PPM_DISPLAY or { N = 1, P = 1, K = 1 }
    local rc  = SoilConstants.REPORT_COLORS or {}
    local phGoodLow  = rc.PH_GOOD_LOW  or 6.0
    local phGoodHigh = rc.PH_GOOD_HIGH or 7.0
    local phFairLow  = rc.PH_FAIR_LOW  or 5.5
    local phFairHigh = rc.PH_FAIR_HIGH or 7.5
    local omGood     = rc.OM_GOOD      or 4.0
    local omFair     = rc.OM_FAIR      or 2.5

    local weedMed    = (SoilConstants.WEED_PRESSURE    and SoilConstants.WEED_PRESSURE.MEDIUM)    or 50
    local pestMed    = (SoilConstants.PEST_PRESSURE    and SoilConstants.PEST_PRESSURE.MEDIUM)    or 50
    local diseaseMed = (SoilConstants.DISEASE_PRESSURE and SoilConstants.DISEASE_PRESSURE.MEDIUM) or 50

    -- ── Overall soil grade (worst-case of all indicators) ──
    local grade = "Good"
    for _, key in ipairs({"nitrogen", "phosphorus", "potassium"}) do
        local st = info[key] and info[key].status
        if     st == "Poor"                  then grade = "Poor"
        elseif st == "Fair" and grade ~= "Poor" then grade = "Fair" end
    end
    if info.pH then
        if   info.pH < phFairLow or info.pH > phFairHigh then grade = "Poor"
        elseif (info.pH < phGoodLow or info.pH > phGoodHigh) and grade ~= "Poor" then grade = "Fair" end
    end
    if info.organicMatter then
        if   info.organicMatter < omFair and grade ~= "Poor" then grade = "Poor"
        elseif info.organicMatter < omGood  and grade ~= "Poor" then grade = "Fair" end
    end
    local weedPct    = math.floor((info.weedPressure    or 0) + 0.5)
    local pestPct    = math.floor((info.pestPressure    or 0) + 0.5)
    local diseasePct = math.floor((info.diseasePressure or 0) + 0.5)
    local compPct    = math.floor((info.compaction      or 0) + 0.5)
    if weedPct    >= weedMed    and grade ~= "Poor" then grade = "Fair" end
    if pestPct    >= pestMed                        then grade = "Poor" end
    if diseasePct >= diseaseMed                     then grade = "Poor" end

    -- ── Yield penalty (N/P/K deficit vs crop threshold) ────
    local yieldStr = g_i18n:getText("sf_hud_optimal") or "Optimal"
    local ys = SoilConstants.YIELD_SENSITIVITY
    if ys then
        local cropLower = info.lastCrop and string.lower(info.lastCrop) or nil
        local isNonCrop = cropLower and ys.NON_CROP_NAMES and ys.NON_CROP_NAMES[cropLower]
        if not isNonCrop then
            local tier     = (cropLower and ys.CROP_TIERS and ys.CROP_TIERS[cropLower]) or ys.DEFAULT_TIER
            local tierData = ys.TIERS and ys.TIERS[tier]
            local thresh   = ys.OPTIMAL_THRESHOLD or 70
            if tierData then
                local nDef    = math.max(0, thresh - info.nitrogen.value)   / thresh
                local pDef    = math.max(0, thresh - info.phosphorus.value) / thresh
                local kDef    = math.max(0, thresh - info.potassium.value)  / thresh
                local penalty = math.min(ys.MAX_PENALTY, (nDef + pDef + kDef) / 3 * tierData.scale)
                local pct     = math.floor(penalty * 100 + 0.5)
                if pct > 0 then
                    yieldStr = string.format("~-%d%%", pct)
                    if grade == "Good" then grade = "Fair" end
                end
            end
        end
    end

    -- ── Crop rotation label ─────────────────────────────────
    local rotStr
    if info.rotationStatus then
        if     info.rotationStatus == "Bonus"   then rotStr = g_i18n:getText("sf_report_rotation_bonus")   or "Bonus"
        elseif info.rotationStatus == "Fatigue" then
            rotStr = g_i18n:getText("sf_report_rotation_fatigue") or "Fatigue"
            if grade == "Good" then grade = "Fair" end
        else                                         rotStr = g_i18n:getText("sf_report_rotation_ok")      or "OK"
        end
    end

    -- ── Nutrient value formatter (current / crop-target) ───
    local ct = info.cropTargets
    local function fmtNutrient(rawValue, label, ppmMult)
        local val = math.floor(rawValue * ppmMult + 0.5)
        if ct and ct[label] then
            return string.format("%d / %d", val, math.floor(ct[label].opt * ppmMult + 0.5))
        end
        return tostring(val)
    end

    -- ── Needs summary (actionable issues list) ─────────────
    local needs = {}
    if     info.nitrogen.status   == "Poor" then table.insert(needs, "N!")
    elseif info.nitrogen.status   == "Fair" then table.insert(needs, "N")  end
    if     info.phosphorus.status == "Poor" then table.insert(needs, "P!")
    elseif info.phosphorus.status == "Fair" then table.insert(needs, "P")  end
    if     info.potassium.status  == "Poor" then table.insert(needs, "K!")
    elseif info.potassium.status  == "Fair" then table.insert(needs, "K")  end
    if info.pH and (info.pH < phGoodLow or info.pH > phGoodHigh) then table.insert(needs, "pH") end
    if weedPct    >= weedMed    then table.insert(needs, g_i18n:getText("sf_hud_weeds")   or "Weeds")   end
    if pestPct    >= pestMed    then table.insert(needs, g_i18n:getText("sf_hud_pests")   or "Pests")   end
    if diseasePct >= diseaseMed then table.insert(needs, g_i18n:getText("sf_hud_disease") or "Disease") end
    if compPct    > 10          then table.insert(needs, g_i18n:getText("sf_hud_compaction") or "Compaction") end

    local protected = g_i18n:getText("sf_hud_protected") or "protected"
    local function pressureLine(pct, active)
        if active then return string.format("%d%% (%s)", pct, protected) end
        return string.format("%d%%", pct)
    end

    -- ── Populate box ────────────────────────────────────────
    box:clear()
    box:setTitle(g_i18n:getText("sf_fieldinfo_box_title") or "Soil Nutrients")

    box:addLine(g_i18n:getText("sf_fieldinfo_grade") or "Soil Grade", grade)
    box:addLine(g_i18n:getText("sf_fieldinfo_yield") or "Yield",      yieldStr)
    if rotStr then
        box:addLine(g_i18n:getText("sf_fieldinfo_rotation") or "Rotation", rotStr)
    end
    box:addLine("N (ppm)", fmtNutrient(info.nitrogen.value,   "N", ppm.N))
    box:addLine("P (ppm)", fmtNutrient(info.phosphorus.value, "P", ppm.P))
    box:addLine("K (ppm)", fmtNutrient(info.potassium.value,  "K", ppm.K))
    box:addLine("pH",      string.format("%.1f", info.pH))
    box:addLine("OM",      string.format("%.1f%%", info.organicMatter))
    if weedPct    > 0 then box:addLine(g_i18n:getText("sf_hud_weeds")      or "Weeds",      pressureLine(weedPct,    info.herbicideActive))  end
    if pestPct    > 0 then box:addLine(g_i18n:getText("sf_hud_pests")      or "Pests",      pressureLine(pestPct,    info.insecticideActive)) end
    if diseasePct > 0 then box:addLine(g_i18n:getText("sf_hud_disease")    or "Disease",    pressureLine(diseasePct, info.fungicideActive))   end
    if compPct    > 0 then
        -- g_i18n:formatText() does not exist in FS25; use string.format with getText instead
        local label = g_i18n:hasText("sf_hud_compaction") and string.format(g_i18n:getText("sf_hud_compaction"), compPct) or string.format("Compaction: %d%%", compPct)
        box:addLine(label, "") -- Add as a single line since the label has the value
    end
    box:addLine(g_i18n:getText("sf_fieldinfo_needs") or "Needs",
        #needs > 0 and table.concat(needs, ", ") or (g_i18n:getText("sf_report_rec_optimal") or "All good"))

    box:showNextFrame()
end

-- ── Field detection ──────────────────────────────────────
function SoilHUD:refreshFieldData()
    local soilSys = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
    if not soilSys then
        self.cachedFieldId   = nil
        self.cachedFieldInfo = nil
        return
    end

    local fieldId, x, z = self:detectCurrentFieldId()
    local prevId  = self.cachedFieldId
    self.cachedFieldId = fieldId
    self.isOnField     = (fieldId ~= nil)
    self.cachedPlayerX = x
    self.cachedPlayerZ = z

    if fieldId then
        self.cachedFieldInfo = soilSys:getFieldInfo(fieldId)

        if fieldId ~= prevId and self.cachedFieldInfo then
            local info = self.cachedFieldInfo
            local ppm  = SoilConstants.PPM_DISPLAY or { N=1, P=1, K=1 }
            SoilLogger.debug("HUD field → %s | N=%d (raw) → %dppm | P=%d → %dppm | K=%d → %dppm | pH=%.1f | OM=%.1f",
                tostring(fieldId),
                math.floor(info.nitrogen.value + 0.5),
                math.floor(info.nitrogen.value   * ppm.N + 0.5),
                math.floor(info.phosphorus.value + 0.5),
                math.floor(info.phosphorus.value * ppm.P + 0.5),
                math.floor(info.potassium.value  + 0.5),
                math.floor(info.potassium.value  * ppm.K + 0.5),
                info.pH,
                info.organicMatter
            )
            SoilLogger.debug("HUD status → N:%s P:%s K:%s",
                tostring(info.nitrogen.status),
                tostring(info.phosphorus.status),
                tostring(info.potassium.status)
            )
        end
    else
        self.cachedFieldInfo = nil
        if prevId and prevId ~= fieldId then
            SoilLogger.debug("HUD field → off-field (was %s)", tostring(prevId))
        end
    end

    -- Pre-format display strings so draw() at 60 FPS never calls string.format
    local info = self.cachedFieldInfo
    if info and fieldId then
        self._fmt_fieldText = string.format(g_i18n:getText("sf_hud_field"), fieldId) .. " (Avg)"
        local crop = info.lastCrop
        if crop and crop ~= "" then
            self._fmt_cropText = crop:sub(1,1):upper() .. crop:sub(2)
        else
            self._fmt_cropText = g_i18n:getText("sf_hud_fallow")
        end
        self._fmt_pHStr = string.format("%.1f",  info.pH)
        self._fmt_omStr = string.format("%.1f%%", info.organicMatter)
        -- N/P/K value strings pre-computed here; ghost-bar delta is still live in draw()
        local ppm = SoilConstants.PPM_DISPLAY or { N=1, P=1, K=1 }
        self._fmt_N = tostring(math.floor(info.nitrogen.value   * (ppm.N or 1) + 0.5))
        self._fmt_P = tostring(math.floor(info.phosphorus.value * (ppm.P or 1) + 0.5))
        self._fmt_K = tostring(math.floor(info.potassium.value  * (ppm.K or 1) + 0.5))
    else
        self._fmt_fieldText = g_i18n:getText("sf_hud_noField")
        self._fmt_cropText  = nil
        self._fmt_pHStr     = nil
        self._fmt_omStr     = nil
        self._fmt_N         = nil
        self._fmt_P         = nil
        self._fmt_K         = nil
    end

    self._heightDirty = true
end

function SoilHUD:detectCurrentFieldId()
    local x, z

    -- Priority 1: g_localPlayer
    if g_localPlayer then
        if type(g_localPlayer.getIsInVehicle) == "function" and g_localPlayer:getIsInVehicle() then
            local v = g_localPlayer:getCurrentVehicle()
            if v and v.rootNode then
                local ok, vx, vy, vz = pcall(getWorldTranslation, v.rootNode)
                if ok then x, z = vx, vz end
            end
        end
        if not x and g_localPlayer.rootNode then
            local ok, px, py, pz = pcall(getWorldTranslation, g_localPlayer.rootNode)
            if ok then x, z = px, pz end
        end
    end

    -- Priority 2: controlled vehicle
    if not x and g_currentMission and g_currentMission.controlledVehicle then
        local v = g_currentMission.controlledVehicle
        if v and v.rootNode then
            local ok, vx, vy, vz = pcall(getWorldTranslation, v.rootNode)
            if ok then x, z = vx, vz end
        end
    end

    if not x then return nil end

    -- Tier 1: direct field lookup via position
    -- NOTE: do NOT guard with g_fieldManager.getFieldAtWorldPosition — in FS25's OOP
    -- system methods live on the metatable, not the instance, so that check returns nil
    -- even when the method is callable. Always use pcall directly.
    -- NOTE: field.fieldId / field.id / field.index all return nil in FS25.
    -- The correct identifier is field.farmland.id (confirmed in SoilFertilitySystem).
    local fieldId = nil
    if g_fieldManager then
        local ok, field = pcall(function()
            return g_fieldManager:getFieldAtWorldPosition(x, z)
        end)
        if ok and field and field.farmland and field.farmland.id then
            fieldId = field.farmland.id
        end
    end

    -- Tier 2: farmland object lookup
    -- NOTE: getFarmlandIdAtWorldPosition does not exist in FS25.
    -- getFarmlandAtWorldPosition returns a farmland object; read .id from it.
    if not fieldId and g_farmlandManager then
        local ok, farmland = pcall(function()
            return g_farmlandManager:getFarmlandAtWorldPosition(x, z)
        end)
        if ok and farmland and farmland.id and farmland.id > 0 then
            fieldId = farmland.id
        end
    end

    return fieldId, x, z
end

-- ── Toggle visibility (J key) ────────────────────────────
function SoilHUD:toggleVisibility()
    self.visible = not self.visible
    local msg = self.visible and "Soil HUD shown" or "Soil HUD hidden"
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        g_currentMission.hud:showBlinkingWarning(msg, 2000)
    end
    self:saveLayout()
end

-- ── Color helpers ────────────────────────────────────────

-- Returns poor, fair, good color tables based on colorblind setting.
function SoilHUD:palette()
    if self.settings and self.settings.colorblindMode then
        return SoilHUD.CB_POOR, SoilHUD.CB_FAIR, SoilHUD.CB_GOOD
    end
    return SoilHUD.C_POOR, SoilHUD.C_FAIR, SoilHUD.C_GOOD
end

function SoilHUD:statusColor(status)
    local poor, fair, good = self:palette()
    if status == "Good" then return good
    elseif status == "Fair" then return fair
    else return poor end
end

function SoilHUD:pHColor(pH)
    local poor, fair, good = self:palette()
    if pH >= 6.5 and pH <= 7.0 then return good            -- optimal band
    elseif pH > 7.0 and pH <= 7.5 then return poor         -- over-limed: treat as poor so players stop adding lime
    elseif pH >= 5.5 then return fair                       -- slightly acidic: fair
    else return poor end                                    -- very acidic
end

function SoilHUD:omColor(om)
    local poor, fair, good = self:palette()
    if om >= 4.0 then return good
    elseif om >= 2.5 then return fair
    else return poor end
end

function SoilHUD:overallStatus(info)
    local rank = {Good = 1, Fair = 2, Poor = 3}
    local worst = 1
    -- N / P / K
    for _, key in ipairs({"nitrogen", "phosphorus", "potassium"}) do
        local r = rank[info[key].status] or 3
        if r > worst then worst = r end
    end
    -- pH (threshold-based, palette-independent)
    if info.pH then
        local phR = math.floor((info.pH * 10) + 0.5) / 10
        local s = (phR >= 6.5 and phR <= 7.0) and "Good"
               or (phR >= 5.5 and phR <= 7.5) and "Fair"
               or "Poor"
        local r = rank[s] or 1
        if r > worst then worst = r end
    end
    -- OM (threshold-based, palette-independent)
    if info.organicMatter then
        local s = (info.organicMatter >= 4.0) and "Good"
               or (info.organicMatter >= 2.5) and "Fair"
               or "Poor"
        local r = rank[s] or 1
        if r > worst then worst = r end
    end
    -- Weed / pest / disease pressures (0-100, 3-level: <25 Good, <60 Fair, else Poor)
    for _, key in ipairs({"weedPressure", "pestPressure", "diseasePressure"}) do
        local val = info[key]
        if val and val >= 0 then
            local r = (val >= 60) and 3 or (val >= 25) and 2 or 1
            if r > worst then worst = r end
        end
    end
    local poor, fair, good = self:palette()
    if worst == 1 then return "Good", good
    elseif worst == 2 then return "Fair", fair
    else return "Poor", poor end
end

-- ── Draw helper ──────────────────────────────────────────
function SoilHUD:drawRect(x, y, w, h, c, a)
    if not self.fillOverlay then return end
    local alpha = a or c[4] or 1.0
    setOverlayColor(self.fillOverlay, c[1], c[2], c[3], alpha)
    renderOverlay(self.fillOverlay, x, y, w, h)
end

-- ── Draw ─────────────────────────────────────────────────
function SoilHUD:draw()
    if not self.initialized then return end
    if not self.settings.enabled then return end
    if not self.settings.showHUD then return end
    if not self.visible then return end
    if not g_currentMission then return end

    if not self.editMode then
        if g_gui and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()) then return end
        if g_currentMission.hud and g_currentMission.hud.ingameMap then
            if g_currentMission.hud.ingameMap.state == IngameMap.STATE_LARGE_MAP then return end
        end
    end

    self:drawPanel()

    self:drawSprayerRatePanel()

    if self.settings.showMiniReport then
        self:drawMiniReport()
    end
end

-- ── Main panel ───────────────────────────────────────────
function SoilHUD:drawPanel()
    local s   = self.scale
    local px  = self.panelX
    local py  = self.panelY
    local pw  = SoilHUD.BASE_W * s
    local ph  = (self.currentHeight or SoilHUD.BASE_H) * s

    local alpha = SoilConstants.HUD.TRANSPARENCY_LEVELS[self.settings.hudTransparency or 3]
    local fontMult = SoilConstants.HUD.FONT_SIZE_MULTIPLIERS[self.settings.hudFontSize or 2]

    -- Blend the chosen color theme into the background so transparency changes are visible.
    -- Pure black at any alpha looks identical; a slight tint from the theme accent makes
    -- the difference between Clear (0.42) and Solid (1.00) actually perceptible.
    local theme = SoilConstants.HUD.COLOR_THEMES[self.settings.hudColorTheme or 1]
    local bgR = 0.05 + theme.r * 0.04
    local bgG = 0.05 + theme.g * 0.04
    local bgB = 0.05 + theme.b * 0.04

    -- Shadow
    self:drawRect(px + 0.003*s, py - 0.003*s, pw, ph, SoilHUD.C_SHADOW)

    -- Background (tinted by color theme, alpha set by transparency level)
    self:drawRect(px, py, pw, ph, {bgR, bgG, bgB, 1}, alpha)

    -- Title bar
    local titleH = SoilHUD.TITLE_H * s
    self:drawRect(px, py + ph - titleH, pw, titleH, SoilHUD.C_TITLE_BG)

    -- Permanent border
    local bw = 0.001
    self:drawRect(px,           py,            pw, bw, SoilHUD.C_BORDER)
    self:drawRect(px,           py + ph - bw,   pw, bw, SoilHUD.C_BORDER)
    self:drawRect(px,           py,            bw, ph, SoilHUD.C_BORDER)
    self:drawRect(px + pw - bw,  py,            bw, ph, SoilHUD.C_BORDER)

    -- Edit mode chrome
    if self.editMode then
        local pulse = 0.55 + 0.45 * math.sin(self.animTimer * 0.004)
        local ebw   = 0.002
        self:drawRect(px,            py,             pw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(px,            py + ph - ebw,   pw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(px,            py,             ebw, ph, {1.0, 0.55, 0.10, pulse})
        self:drawRect(px + pw - ebw,  py,             ebw, ph, {1.0, 0.55, 0.10, pulse})
        for key, r in pairs(self:getResizeHandleRects()) do
            local isHover = (self.hoverCorner == key)
            self:drawRect(r.x, r.y, r.w, r.h, SoilHUD.C_EDIT_HDL, isHover and 1.0 or 0.65)
        end
    end

    -- ── Content ───────────────────────────────────────────
    local transparency = self.settings.hudTransparency or 3
    setTextAlignment(RenderText.ALIGN_LEFT)

    local pad  = SoilHUD.PAD * s
    local tx   = px + pad
    local ty   = py + ph - titleH * 0.5  -- vertical center of title bar

    local info = self.cachedFieldInfo

    -- Title + overall status badge
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    renderText(tx, ty - 0.006*s, 0.012 * fontMult * s, g_i18n:getText("sf_hud_title"))

    if info then
        local statusLabel, statusCol = self:overallStatus(info)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(statusCol[1], statusCol[2], statusCol[3], 1.0)
        renderText(px + pw - pad, ty - 0.006*s, 0.011 * fontMult * s, g_i18n:getText("sf_report_rec_" .. statusLabel:lower()))
    end
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Current Y cursor (below title bar)
    local cy = py + ph - titleH - pad

    -- Field / crop row (strings pre-formatted in refreshFieldData at 2 Hz)
    local fieldText = self._fmt_fieldText
    local cropText  = self._fmt_cropText

    cy = cy - SoilHUD.LINE_H * s
    setTextColor(SoilHUD.C_LABEL[1], SoilHUD.C_LABEL[2], SoilHUD.C_LABEL[3], SoilHUD.C_LABEL[4])
    renderText(tx, cy, 0.010 * fontMult * s, fieldText or "")
    if cropText then
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(SoilHUD.C_DIM[1], SoilHUD.C_DIM[2], SoilHUD.C_DIM[3], SoilHUD.C_DIM[4])
        renderText(px + pw - pad, cy, 0.010 * fontMult * s, cropText)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    -- Divider above N/P/K block; "(ppm)" unit label right-aligned on the same line
    -- so the user sees the unit context once, not repeated on every row.
    cy = cy - pad * 0.8
    self:drawRect(px + pad, cy, pw - pad*2, 0.0005, SoilHUD.C_DIVIDER)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(SoilHUD.C_DIM[1], SoilHUD.C_DIM[2], SoilHUD.C_DIM[3], 0.60)
    renderText(px + pw - pad, cy + 0.001*s, 0.007 * fontMult * s, g_i18n:getText("sf_hud_unit_ppm"))
    setTextAlignment(RenderText.ALIGN_LEFT)
    cy = cy - pad * 0.8

    if info then
        -- Use cached sprayer state (populated in update() to keep draw() free of game-object traversal)
        local sprayer        = self._cachedSprayer
        local fillType       = self._cachedFillType
        local profile        = self._cachedProfile
        local rateMultiplier = self._cachedRateMult

        -- N / P / K rows
        cy = self:drawNutrientRow("N", "N", info.nitrogen, px, cy, pw, s, fontMult, info, profile, fillType, rateMultiplier, self._fmt_N)
        cy = self:drawNutrientRow("P", "P", info.phosphorus,  px, cy, pw, s, fontMult, info, profile, fillType, rateMultiplier, self._fmt_P)
        cy = self:drawNutrientRow("K", "K", info.potassium,   px, cy, pw, s, fontMult, info, profile, fillType, rateMultiplier, self._fmt_K)

        -- Divider
        cy = cy - pad * 0.5
        self:drawRect(px + pad, cy, pw - pad*2, 0.0005, SoilHUD.C_DIVIDER)
        cy = cy - pad * 0.8

        -- pH + OM row
        local pHCol = self:pHColor(info.pH)
        local omCol = self:omColor(info.organicMatter)

        setTextColor(SoilHUD.C_LABEL[1], SoilHUD.C_LABEL[2], SoilHUD.C_LABEL[3], SoilHUD.C_LABEL[4])
        renderText(tx, cy, 0.010 * fontMult * s, g_i18n:getText("sf_hud_label_ph"))
        setTextColor(pHCol[1], pHCol[2], pHCol[3], 1.0)
        renderText(tx + 0.020*s, cy, 0.010 * fontMult * s, self._fmt_pHStr or "")

        local omX = tx + pw * 0.50
        setTextColor(SoilHUD.C_LABEL[1], SoilHUD.C_LABEL[2], SoilHUD.C_LABEL[3], SoilHUD.C_LABEL[4])
        renderText(omX, cy, 0.010 * fontMult * s, g_i18n:getText("sf_hud_label_om"))
        setTextColor(omCol[1], omCol[2], omCol[3], 1.0)
        renderText(omX + 0.020*s, cy, 0.010 * fontMult * s, self._fmt_omStr or "")

        -- Divider below pH/OM row
        cy = cy - SoilHUD.LINE_H * s
        cy = cy - pad * 0.5
        self:drawRect(px + pad, cy, pw - pad*2, 0.0005, SoilHUD.C_DIVIDER)
        cy = cy - pad * 0.8

        -- Weed / pest / disease pressure rows
        local mgr = g_SoilFertilityManager
        if mgr then
            if mgr.settings.weedPressure then
                cy = self:drawPressureRow("sf_hud_weeds", info.weedPressure or 0,
                    info.herbicideActive, px, cy, pw, s, fontMult)
            end
            if mgr.settings.pestPressure then
                cy = self:drawPressureRow("sf_hud_pests", info.pestPressure or 0,
                    info.insecticideActive, px, cy, pw, s, fontMult)
            end
            if mgr.settings.diseasePressure then
                cy = self:drawPressureRow("sf_hud_disease", info.diseasePressure or 0,
                    info.fungicideActive, px, cy, pw, s, fontMult)
            end

            -- Coverage row: session fraction (survives daily resets) with product label
            local cov = info.sessionCoverageFraction or info.coverageFraction or 0
            if cov > 0 then
                local minCov = SoilConstants.COVERAGE and SoilConstants.COVERAGE.MIN_FULL_CREDIT or 0.70
                local covPct = math.floor(cov * 100 + 0.5)
                local covText
                local lastProd = info.sessionLastProduct
                if lastProd then
                    local ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByName(lastProd)
                    local productLabel = (ft and ft.title) or lastProd
                    covText = string.format(g_i18n:getText("sf_hud_pass_coverage"), covPct, productLabel)
                else
                    local minPct = math.floor(minCov * 100 + 0.5)
                    covText = string.format(g_i18n:getText("sf_hud_coverage"), covPct, minPct)
                end
                local covPoor, _, covGood = self:palette()
                local cr, cg, cb = covPoor[1], covPoor[2], covPoor[3]
                if cov >= minCov then cr, cg, cb = covGood[1], covGood[2], covGood[3] end
                local pad = SoilHUD.PAD * s
                setTextAlignment(RenderText.ALIGN_LEFT)
                setTextColor(cr, cg, cb, 1.0)
                renderText(px + pad, cy, 0.010 * fontMult * s, covText)
                cy = cy - SoilHUD.LINE_H * s
            end

            -- Compaction row
            local comp = info.compaction or 0
            if mgr.settings.compactionEnabled and comp > 0 then
                local compPct = math.floor(comp + 0.5)
                local cr, cg, cb
                if comp > 60 then
                    cr, cg, cb = 0.88, 0.25, 0.25   -- red: severe
                elseif comp > 20 then
                    cr, cg, cb = 0.90, 0.55, 0.10   -- amber: moderate
                else
                    cr, cg, cb = 0.32, 0.88, 0.44   -- green: low
                end
                local pad = SoilHUD.PAD * s
                setTextAlignment(RenderText.ALIGN_LEFT)
                setTextColor(cr, cg, cb, 1.0)
                renderText(px + pad, cy, 0.010 * fontMult * s, string.format(g_i18n:getText("sf_hud_compaction"), compPct))
                cy = cy - SoilHUD.LINE_H * s
            end
        end

        -- Yield efficiency summary (nil when no managed crop)
        local yieldEff = info.yieldEfficiency
        if yieldEff then
            local yr, yg, yb
            if yieldEff >= 90 then
                yr, yg, yb = 0.32, 0.88, 0.44   -- green: at or near optimal
            elseif yieldEff >= 70 then
                yr, yg, yb = 0.90, 0.82, 0.18   -- yellow: noticeable penalty
            else
                yr, yg, yb = 0.88, 0.25, 0.25   -- red: significant penalty
            end
            setTextAlignment(RenderText.ALIGN_LEFT)
            setTextColor(yr, yg, yb, 1.0)
            renderText(px + pad, cy, 0.010 * fontMult * s,
                string.format(g_i18n:getText("sf_hud_yield_eff"), yieldEff))
            cy = cy - SoilHUD.LINE_H * s
        end

        -- Divider before hint
        cy = cy - pad * 0.5
        self:drawRect(px + pad, cy, pw - pad*2, 0.0005, SoilHUD.C_DIVIDER)
        cy = cy - pad * 0.8
    else
        cy = cy - SoilHUD.LINE_H * s * 4  -- skip nutrient rows space
    end

    -- Hint row
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(SoilHUD.C_HINT[1], SoilHUD.C_HINT[2], SoilHUD.C_HINT[3], SoilHUD.C_HINT[4])
    if self.editMode then
        renderText(px + pw * 0.5, cy, 0.009 * fontMult * s, g_i18n:getText("sf_hud_hint_edit"))
    else
        renderText(px + pw * 0.5, cy, 0.009 * fontMult * s, g_i18n:getText("sf_hud_hint_normal"))
    end

    -- Reset text state
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

-- ── Nutrient bar row ─────────────────────────────────────
-- Returns the new cy after drawing the row.
-- label is the display label ("N", "N*", "P", "K"). baseLabel is the clean version ("N", "P", "K").
-- cachedValStr is the pre-formatted base value string (no ghost-bar delta suffix yet).
function SoilHUD:drawNutrientRow(label, baseLabel, nutrient, px, cy, pw, s, fontMult, info, profile, fillType, rateMultiplier, cachedValStr)
    local pad   = SoilHUD.PAD * s
    local rowH  = SoilHUD.ROW_H * s
    local barH  = SoilHUD.BAR_H * s
    local barW  = SoilHUD.BAR_W * s
    local tx    = px + pad
    local col   = self:statusColor(nutrient.status)

    cy = cy - rowH

    -- Label (N / P / K)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(SoilHUD.C_LABEL[1], SoilHUD.C_LABEL[2], SoilHUD.C_LABEL[3], SoilHUD.C_LABEL[4])
    renderText(tx, cy + (rowH - 0.010*s) * 0.5, 0.010 * fontMult * s, label)

    -- Bar background + fill
    local barX = tx + 0.015*s
    local barY = cy + (rowH - barH) * 0.5
    self:drawRect(barX, barY, barW, barH, SoilHUD.C_BAR_BG)
    
    local fill = math.max(0, math.min(1, nutrient.value / 100))
    if fill > 0 then
        self:drawRect(barX, barY, barW * fill, barH, col)
    end

    -- Projected "Ghost Bar" (V1.7 Realism Update)
    -- Shows the expected nutrient gain for the remainder of the current application pass.
    local projectedDelta = 0
    if profile and profile[label] and info and info.nutrientBuffer then
        local fillTypeIndex = fillType and fillType.index
        if fillTypeIndex then
            local currentBuffer = info.nutrientBuffer[fillTypeIndex] or 0
            local br = SoilConstants.SPRAYER_RATE.BASE_RATES
            local baseRate = (fillType and br[fillType.name]) or br.DEFAULT
            
            if baseRate then
                -- Scale target volume by the current rate so the ghost bar reflects
                -- what you'll actually apply at this rate setting (issue #278).
                local targetVolume = (info.fieldArea or 1.0) * baseRate.value * (rateMultiplier or 1.0)

                -- Ghost bar shows the gain remaining to reach the 90% threshold
                local threshold = targetVolume * (SoilConstants.SPRAYER_RATE.FERTILIZER_COVERAGE_THRESHOLD or 0.90)
                local remaining = math.max(0, threshold - currentBuffer)
                
                if remaining > 0 then
                    projectedDelta = profile[label] * (remaining / 1000) / (info.fieldArea or 1.0)
                    local ghostFill = math.min(1.0 - fill, projectedDelta / 100)
                    if ghostFill > 0 then
                        self:drawRect(barX + barW * fill, barY, barW * ghostFill, barH, col, 0.35)
                    end
                end
            end
        end
    end

    -- Threshold tick marks (global poor/fair)
    local thresholdKey = baseLabel == "N" and "nitrogen"
                      or baseLabel == "P" and "phosphorus"
                      or baseLabel == "K" and "potassium"
                      or nil
    if thresholdKey then
        local th = SoilConstants.STATUS_THRESHOLDS[thresholdKey]
        if th then
            local tickW  = 0.0005 * s
            local tickH  = barH + 0.002 * s
            local tickY  = barY - 0.001 * s
            local poorX  = barX + barW * (th.poor / 100) - tickW * 0.5
            local fairX  = barX + barW * (th.fair / 100) - tickW * 0.5
            self:drawRect(poorX, tickY, tickW, tickH, {0.90, 0.35, 0.20, 0.75})  -- orange-red  = poor/fair boundary
            self:drawRect(fairX, tickY, tickW, tickH, {0.90, 0.80, 0.20, 0.75})  -- yellow      = fair/good boundary
        end
    end

    -- Per-crop target tick at optimal level (bright cyan, taller than status ticks)
    local cropTarget = info and info.cropTargets and info.cropTargets[baseLabel]
    if cropTarget then
        local tickW = 0.0008 * s
        local tickH = barH + 0.005 * s
        local tickY = barY - 0.0025 * s
        local optX  = barX + barW * (cropTarget.opt / 100) - tickW * 0.5
        self:drawRect(optX, tickY, tickW, tickH, {0.20, 0.85, 0.85, 0.90})
    end

    -- ppmMult uses baseLabel ("N"/"P"/"K") so it always resolves correctly in PPM_DISPLAY.
    local ppmMult = SoilConstants.PPM_DISPLAY and SoilConstants.PPM_DISPLAY[baseLabel] or 1.0
    local valX    = barX + barW + 0.006*s

    -- Derive color from crop target if available, otherwise keep status color
    local displayCol = col
    if cropTarget then
        if nutrient.value >= cropTarget.opt then
            displayCol = self:statusColor("Good")
        elseif nutrient.value >= cropTarget.min then
            displayCol = self:statusColor("Fair")
        else
            displayCol = self:statusColor("Poor")
        end
    end
    setTextColor(displayCol[1], displayCol[2], displayCol[3], 1.0)

    -- Base value string is pre-formatted in refreshFieldData (cachedValStr); only the
    -- optional ghost-bar delta suffix is computed live here because it depends on the
    -- current sprayer state which changes independently of the 0.5s field-detect cycle.
    local valStr = cachedValStr or tostring(math.floor(nutrient.value * ppmMult + 0.5))
    if cropTarget then
        local optPpm = math.floor(cropTarget.opt * ppmMult + 0.5)
        valStr = valStr .. "/" .. tostring(optPpm)
    end
    if projectedDelta > 0 then
        local projPpm = math.floor(projectedDelta * ppmMult + 0.5)
        if projPpm > 0 then
            valStr = valStr .. string.format(" (+%d)", projPpm)
        end
    end
    renderText(valX, cy + (rowH - 0.010*s) * 0.5, 0.010 * fontMult * s, valStr)

    -- Status label
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(displayCol[1], displayCol[2], displayCol[3], 0.80)
    renderText(px + pw - pad, cy + (rowH - 0.009*s) * 0.5, 0.009 * fontMult * s, nutrient.status)
    setTextAlignment(RenderText.ALIGN_LEFT)

    return cy
end

-- ── Pressure bar row ─────────────────────────────────────
-- Draws a single weed/pest/disease pressure row.
-- pressure is 0-100.  isProtected shows "(protected)" suffix when true.
-- Returns updated cy after the row.
function SoilHUD:drawPressureRow(labelKey, pressure, isProtected, px, cy, pw, s, fontMult)
    local pad  = SoilHUD.PAD * s
    local barH = SoilHUD.BAR_H * s
    local barW = SoilHUD.BAR_W * s
    local tx   = px + pad

    -- 3-level color (matches getPressureColor in SoilReportDialog — aligned with Constants thresholds)
    local wp = SoilConstants.WEED_PRESSURE  -- LOW=20, MEDIUM=50 (shared by weed/pest/disease)
    local col
    if pressure < wp.LOW    then col = SoilHUD.C_GOOD
    elseif pressure < wp.MEDIUM then col = SoilHUD.C_FAIR
    else                         col = SoilHUD.C_POOR end

    -- Label
    setTextColor(SoilHUD.C_LABEL[1], SoilHUD.C_LABEL[2], SoilHUD.C_LABEL[3], SoilHUD.C_LABEL[4])
    renderText(tx, cy, 0.010 * fontMult * s, g_i18n:getText(labelKey))

    -- Bar
    local barX = tx + 0.038*s
    local barY = cy + (SoilHUD.LINE_H * s - barH) * 0.5
    self:drawRect(barX, barY, barW, barH, SoilHUD.C_BAR_BG)
    local fill = math.max(0, math.min(1, pressure / 100))
    if fill > 0 then
        self:drawRect(barX, barY, barW * fill, barH, col)
    end

    -- Value + protection tag
    local label = string.format("%.0f%%", pressure)
    if isProtected then label = label .. " " .. g_i18n:getText("sf_hud_protected") end
    setTextAlignment(RenderText.ALIGN_RIGHT)
    setTextColor(col[1], col[2], col[3], 1.0)
    renderText(px + pw - pad, cy, 0.010 * fontMult * s, label)
    setTextAlignment(RenderText.ALIGN_LEFT)

    return cy - SoilHUD.LINE_H * s
end

-- ── Sprayer fill-type helpers ─────────────────────────────
--- Returns the FillType object currently loaded in the sprayer, or nil.
function SoilHUD:getSprayerFillType(sprayer)
    if not sprayer then return nil end
    local fillTypeIndex

    -- Try workAreaParameters first (populated while actively spraying)
    local spec = sprayer.spec_sprayer
    if spec and spec.workAreaParameters then
        local ft = spec.workAreaParameters.sprayFillType
        if ft and ft > 0 then fillTypeIndex = ft end
    end

    -- Fall back to fill unit query (works when parked)
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

--- Returns the BASE_RATES entry for a fill type, falling back to DEFAULT.
function SoilHUD:getRateConfig(fillType)
    local br = SoilConstants.SPRAYER_RATE.BASE_RATES
    if fillType and br[fillType.name] then
        return br[fillType.name]
    end
    return br.DEFAULT
end

--- Returns a formatted rate string with units for the given multiplier.
--- Shows gal/ac (liquid) or lb/ac (dry) when useImperialUnits is true,
--- otherwise L/ha or kg/ha.
function SoilHUD:formatRate(multiplier, rateConfig)
    local value    = rateConfig.value * multiplier
    local imperial = (self.settings.useImperialUnits ~= false)
    local conv     = SoilConstants.SPRAYER_RATE

    -- For very low base rates (Insecticide/Fungicide), show 1 decimal place
    local fmt = (rateConfig.value < 10.0) and "%.1f" or "%.0f"

    if rateConfig.unit == "liquid" then
        if imperial then
            local impVal = value * conv.L_PER_HA_TO_GAL_PER_AC
            return string.format(fmt .. " gal/ac", impVal)
        else
            return string.format(fmt .. " L/ha", value)
        end
    else
        if imperial then
            local impVal = value * conv.KG_PER_HA_TO_LB_PER_AC
            return string.format(fmt .. " lb/ac", impVal)
        else
            return string.format(fmt .. " kg/ha", value)
        end
    end
end

--- Returns just the numeric part of the rate (no unit suffix), for adjacent step labels.
function SoilHUD:formatRateNumber(multiplier, rateConfig)
    local value    = rateConfig.value * multiplier
    local imperial = (self.settings.useImperialUnits ~= false)
    local conv     = SoilConstants.SPRAYER_RATE

    -- For very low base rates, show 1 decimal place
    local fmt = (rateConfig.value < 10.0) and "%.1f" or "%.0f"

    if rateConfig.unit == "liquid" then
        if imperial then
            return string.format(fmt, value * conv.L_PER_HA_TO_GAL_PER_AC)
        else
            return string.format(fmt, value)
        end
    else
        if imperial then
            return string.format(fmt, value * conv.KG_PER_HA_TO_LB_PER_AC)
        else
            return string.format(fmt, value)
        end
    end
end

-- Computes the STEPS index corresponding to the optimal application rate for the
-- currently planted crop, using the same weighted-deficit formula as calculateAutoRateIndex
-- but substituting per-crop opt targets from cropTargets instead of AUTO_RATE_TARGETS.
-- Returns nil when: no crop planted, fill type has no N/P/K, or field already at/above
-- all relevant crop targets (no tick needed when the field is already fine).
function SoilHUD:_calcCropTargetRateIdx(fillType)
    if not fillType then return nil end
    local info = self.cachedFieldInfo
    if not info or not info.cropTargets then return nil end

    local profile = SoilConstants.FERTILIZER_PROFILES and SoilConstants.FERTILIZER_PROFILES[fillType.name]
    if not profile then return nil end

    local ct           = info.cropTargets
    local totalWeight  = 0
    local weightedDef  = 0
    local anyDeficit   = false

    if profile.N and profile.N > 0 and ct.N and ct.N.opt > 0 then
        local deficit = math.max(0, ct.N.opt - info.nitrogen.value) / ct.N.opt
        if deficit > 0 then anyDeficit = true end
        weightedDef  = weightedDef  + deficit * profile.N
        totalWeight  = totalWeight  + profile.N
    end
    if profile.P and profile.P > 0 and ct.P and ct.P.opt > 0 then
        local deficit = math.max(0, ct.P.opt - info.phosphorus.value) / ct.P.opt
        if deficit > 0 then anyDeficit = true end
        weightedDef  = weightedDef  + deficit * profile.P
        totalWeight  = totalWeight  + profile.P
    end
    if profile.K and profile.K > 0 and ct.K and ct.K.opt > 0 then
        local deficit = math.max(0, ct.K.opt - info.potassium.value) / ct.K.opt
        if deficit > 0 then anyDeficit = true end
        weightedDef  = weightedDef  + deficit * profile.K
        totalWeight  = totalWeight  + profile.K
    end

    -- No relevant nutrients in this fertilizer, or field already at/above all targets
    if totalWeight <= 0 or not anyDeficit then return nil end

    local defFraction = weightedDef / totalWeight
    local targetMult  = 0.20 + defFraction * (1.20 - 0.20)
    targetMult = math.max(0.20, math.min(1.20, targetMult))

    local steps   = SoilConstants.SPRAYER_RATE.STEPS
    local bestIdx = SoilConstants.SPRAYER_RATE.DEFAULT_INDEX
    local bestDiff = math.huge
    for i, step in ipairs(steps) do
        local diff = math.abs(step - targetMult)
        if diff < bestDiff then
            bestDiff = diff
            bestIdx  = i
        end
    end
    return bestIdx
end

-- ── Mini Report (near minimap) ────────────────────────────
function SoilHUD:drawMiniReport()
    -- ── Sizing ───────────────────────────────────────────
    local s  = self.settings.miniReportScale or 1.0
    local rx = self.settings.miniReportX     or 0.18
    local ry = self.settings.miniReportY     or 0.015

    -- Compact: ~60% of BASE_W, title + 5 slim rows
    local SLIM_H = SoilHUD.BAR_H + 0.005   -- row height for mini bars
    local rw = SoilHUD.BASE_W * s * 0.60
    local rh = (SoilHUD.TITLE_H + SoilHUD.PAD + SLIM_H * 5 + SoilHUD.PAD * 0.75) * s

    -- Update hit-test rect every frame (drag in edit mode)
    self.miniReportRect = { x = rx, y = ry, w = rw, h = rh }

    -- ── Sample internal cell data at player position ────────────
    local wx = self.cachedPlayerX
    local wz = self.cachedPlayerZ

    local samples = nil
    local cellLabel = nil

    -- 1. Try to get per-cell zoneData first; fall back to field-level averages.
    if wx and wz and self.cachedFieldId and self.cachedFieldId > 0 then
        local soilSys = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
        if soilSys then
            local field = soilSys:getOrCreateField(self.cachedFieldId, false)
            if field then
                local cell = nil
                if field.zoneData then
                    local cs = SoilConstants.ZONE.CELL_SIZE
                    local cx = math.floor(wx / cs)
                    local cz = math.floor(wz / cs)
                    local cellKey = tostring(cx * 10000 + cz)
                    cell = field.zoneData[cellKey]
                    if cell then
                        cellLabel = string.format("C %d\xC2\xB7%d", cx, cz)
                    end
                end

                -- Cell uses N/P/K/OM; field uses nitrogen/phosphorus/potassium/organicMatter
                local n, p, k, ph, om
                if cell then
                    n, p, k, ph, om = cell.N, cell.P, cell.K, cell.pH, cell.OM
                elseif field.nitrogen ~= nil then
                    n, p, k, ph, om = field.nitrogen, field.phosphorus, field.potassium, field.pH, field.organicMatter
                    cellLabel = g_i18n:hasText("sf_field_avg") and g_i18n:getText("sf_field_avg") or "Field avg"
                end
                if n ~= nil then
                    samples = {
                        { label="N",  val=n,  min=0,   max=100, unit=""  },
                        { label="P",  val=p,  min=0,   max=100, unit=""  },
                        { label="K",  val=k,  min=0,   max=100, unit=""  },
                        { label="pH", val=ph, min=5.0, max=7.5, unit=""  },
                        { label="OM", val=om, min=0,   max=10,  unit="%" },
                    }
                end
            end
        end
    end

    -- 2. If still no data, samples remains nil (player off-field or system not ready).

    -- ── Background ───────────────────────────────────────
    local alpha = SoilConstants.HUD.TRANSPARENCY_LEVELS[self.settings.hudTransparency or 3]
    self:drawRect(rx + 0.002*s, ry - 0.002*s, rw, rh, SoilHUD.C_SHADOW)
    self:drawRect(rx, ry, rw, rh, SoilHUD.C_BG, alpha)

    -- Title bar
    local titleH = SoilHUD.TITLE_H * s
    self:drawRect(rx, ry + rh - titleH, rw, titleH, SoilHUD.C_TITLE_BG)

    -- Border
    local bw = 0.001
    self:drawRect(rx,          ry,           rw, bw, SoilHUD.C_BORDER)
    self:drawRect(rx,          ry + rh - bw, rw, bw, SoilHUD.C_BORDER)
    self:drawRect(rx,          ry,           bw, rh, SoilHUD.C_BORDER)
    self:drawRect(rx + rw - bw, ry,          bw, rh, SoilHUD.C_BORDER)

    -- Edit-mode pulse
    if self.editMode then
        local pulse = 0.55 + 0.45 * math.sin(self.animTimer * 0.004)
        local ebw = 0.0015
        self:drawRect(rx,             ry,             rw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(rx,             ry + rh - ebw,  rw, ebw, {1.0, 0.55, 0.10, pulse})
        self:drawRect(rx,             ry,             ebw, rh, {1.0, 0.55, 0.10, pulse})
        self:drawRect(rx + rw - ebw,  ry,             ebw, rh, {1.0, 0.55, 0.10, pulse})

        -- Resize handle (bottom right)
        local hs = 0.015
        self:drawRect(rx + rw - hs, ry, hs, hs, SoilHUD.C_EDIT_HDL, 0.85)
    end

    -- ── Title text ───────────────────────────────────────
    local fontMult = SoilConstants.HUD.FONT_SIZE_MULTIPLIERS[self.settings.hudFontSize or 2]
    local titleY   = ry + rh - titleH + (titleH - 0.009*s) * 0.45
    local titleStr = g_i18n:getText("sf_cell_report")
    if cellLabel then titleStr = titleStr .. "  " .. cellLabel end

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(1, 1, 1, 0.90)
    renderText(rx + rw * 0.5, titleY, 0.009 * fontMult * s, titleStr)
    setTextBold(false)

    -- ── Bars ─────────────────────────────────────────────
    local pad    = SoilHUD.PAD * s
    local barH   = SoilHUD.BAR_H * s
    local slimH  = SLIM_H * s
    local lblW   = 0.018 * s        -- label column width
    local valW   = 0.022 * s        -- value column width (right side)
    local barX   = rx + pad + lblW
    local barW   = rw - pad*2 - lblW - valW
    local cy     = ry + rh - titleH - pad - slimH  -- top of first row

    if samples then
        for _, row in ipairs(samples) do
            local frac  = math.max(0, math.min(1, (row.val - row.min) / (row.max - row.min)))

            -- Status color: thresholds at 33% / 66% of range
            local col
            local barPoor, barFair, barGood = self:palette()
            if row.label == "pH" then
                -- pH sweet-spot 6.0-7.0; outside is worse
                local norm = (row.val - 5.0) / 2.5  -- 0=5.0, 1=7.5
                if norm >= 0.40 and norm <= 0.80 then col = barGood
                elseif norm >= 0.20 and norm <= 0.90 then col = barFair
                else col = barPoor end
            else
                if frac >= 0.66 then col = barGood
                elseif frac >= 0.33 then col = barFair
                else col = barPoor end
            end

            -- Bar track
            self:drawRect(barX, cy + (slimH - barH) * 0.5, barW, barH, SoilHUD.C_BAR_BG)
            -- Bar fill
            if frac > 0 then
                self:drawRect(barX, cy + (slimH - barH) * 0.5, barW * frac, barH, col)
            end

            -- Label (left)
            setTextAlignment(RenderText.ALIGN_LEFT)
            setTextColor(SoilHUD.C_LABEL[1], SoilHUD.C_LABEL[2], SoilHUD.C_LABEL[3], 1)
            renderText(rx + pad, cy + (slimH - 0.007*s) * 0.35, 0.007 * fontMult * s, row.label)

            -- Value (right)
            local valStr
            if row.label == "pH" then
                valStr = string.format("%.1f", row.val)
            elseif row.label == "OM" then
                valStr = string.format("%.1f%%", row.val)
            else
                valStr = string.format("%d", math.floor(row.val + 0.5))
            end
            setTextAlignment(RenderText.ALIGN_RIGHT)
            setTextColor(col[1], col[2], col[3], 1)
            renderText(rx + rw - pad, cy + (slimH - 0.007*s) * 0.35, 0.007 * fontMult * s, valStr)

            cy = cy - slimH
        end
    else
        -- Fallback: no cell data or off-field
        setTextAlignment(RenderText.ALIGN_CENTER)
        
        -- Title (Big Red)
        local titleText = g_i18n:hasText("sf_cell_no_data_title") and g_i18n:getText("sf_cell_no_data_title") or "No cell data found"
        setTextColor(SoilHUD.C_POOR[1], SoilHUD.C_POOR[2], SoilHUD.C_POOR[3], 1.0)
        renderText(rx + rw * 0.5, ry + (rh - titleH) * 0.55, 0.010 * fontMult * s, titleText)

        -- Description (Smaller, Dim)
        local descText = (wx and wz) and g_i18n:getText("sf_cell_no_data") or g_i18n:getText("sf_no_field")
        setTextColor(SoilHUD.C_DIM[1], SoilHUD.C_DIM[2], SoilHUD.C_DIM[3], 0.8)
        renderText(rx + rw * 0.5, ry + (rh - titleH) * 0.30, 0.0075 * fontMult * s, descText)
    end

    -- Reset
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

function SoilHUD:drawSprayerRatePanel()
    local sprayer = self:getCurrentSprayer()
    if sprayer == nil then return end

    local rm = g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager
    if rm == nil then return end

    local s          = self.scale
    local steps      = SoilConstants.SPRAYER_RATE.STEPS
    local currentIdx = rm:getIndex(sprayer.id)
    local fontMult   = SoilConstants.HUD.FONT_SIZE_MULTIPLIERS[self.settings.hudFontSize or 2]
    local fillType   = self:getSprayerFillType(sprayer)
    local rateConfig = self:getRateConfig(fillType)
    local curMult    = steps[currentIdx]

    -- Panel geometry
    local pw      = SoilHUD.BASE_W * s
    local padV    = self:py(5)  * s
    local barH    = self:py(4)  * s
    local scrollH = self:py(22) * s
    local headerH = self:py(16) * s
    local panelH  = padV + barH + padV + scrollH + padV + headerH
    local gap     = self:py(6) * s
    local panelX  = self.panelX
    local panelY  = self.panelY - gap - panelH
    local cx      = panelX + pw * 0.5

    -- Shadow + background + border (match main panel theme + transparency)
    local rTheme = SoilConstants.HUD.COLOR_THEMES[self.settings.hudColorTheme or 1]
    local rBgR = 0.05 + rTheme.r * 0.04
    local rBgG = 0.05 + rTheme.g * 0.04
    local rBgB = 0.05 + rTheme.b * 0.04
    local rAlpha = SoilConstants.HUD.TRANSPARENCY_LEVELS[self.settings.hudTransparency or 3]
    self:drawRect(panelX + 0.002*s, panelY - 0.002*s, pw, panelH, SoilHUD.C_SHADOW)
    self:drawRect(panelX, panelY, pw, panelH, {rBgR, rBgG, rBgB, 1}, rAlpha)
    local bw = 0.001
    self:drawRect(panelX,           panelY,               pw, bw, SoilHUD.C_BORDER)
    self:drawRect(panelX,           panelY + panelH - bw,  pw, bw, SoilHUD.C_BORDER)
    self:drawRect(panelX,           panelY,               bw, panelH, SoilHUD.C_BORDER)
    self:drawRect(panelX + pw - bw,  panelY,               bw, panelH, SoilHUD.C_BORDER)

    -- Header: "APP. RATE  AUTO: OFF  [Alt+Z]" or "APP. RATE  AUTO: ON"
    -- isAuto = auto rate mode active on this vehicle AND the setting is enabled
    local isAuto = rm:getAutoMode(sprayer.id) and self.settings.autoRateControl
    local autoKey = "Shift+L"   -- fallback display string (matches modDesc.xml binding)
    if g_inputDisplayManager ~= nil then
        local ok, helpElement = pcall(function()
            -- Four-argument form per FS25 API: (action1, action2, text, ignoreComboButtons)
            return g_inputDisplayManager:getControllerSymbolOverlays(InputAction.SF_TOGGLE_AUTO, "", "", false)
        end)
        if ok and helpElement ~= nil and helpElement.keys ~= nil and #helpElement.keys > 0 then
            -- keys is an array of display strings, one per key in the combo (e.g. {"Shift","L"})
            -- Join them with "+" to produce "Shift+L"
            local parts = {}
            for _, k in ipairs(helpElement.keys) do
                table.insert(parts, tostring(k))
            end
            autoKey = table.concat(parts, "+")
        end
    end
    -- Separate the mode status from the toggle hint so AUTO is never ambiguous
    local headerText
    if isAuto then
        headerText = g_i18n:getText("sf_sprayer_auto_on")
    else
        headerText = string.format(g_i18n:getText("sf_sprayer_auto_off"), autoKey)
    end

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(1, 1, 1, 0.90)
    if isAuto then
        setTextColor(0.4, 1.0, 0.4, 1.0)
    end
    renderText(cx, panelY + panelH - headerH * 0.5 - self:py(3)*s,
        0.009 * fontMult * s, headerText)
    setTextBold(false)

    -- Rate scroll row base Y
    local scrollY = panelY + padV + barH + padV

    -- Current rate color (burn-aware or auto-aware)
    local curCol
    if isAuto then
        curCol = {0.4, 1.0, 0.4, 1.0}
    elseif curMult >= SoilConstants.SPRAYER_RATE.BURN_GUARANTEED_THRESHOLD then
        curCol = {1.0, 0.20, 0.20, 1.0}
    elseif curMult > SoilConstants.SPRAYER_RATE.BURN_RISK_THRESHOLD then
        curCol = {0.95, 0.65, 0.10, 1.0}
    else
        curCol = {1.0, 1.0, 1.0, 1.0}
    end

    -- Current rate (large, centered, bold)
    local curRateStr = self:formatRate(curMult, rateConfig)
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(curCol[1], curCol[2], curCol[3], 1.0)
    renderText(cx, scrollY + self:py(7)*s, 0.013 * fontMult * s, curRateStr)
    setTextBold(false)

    -- In Auto-Mode, show what we are targeting below the rate
    if isAuto and fillType then
        local profile = SoilConstants.FERTILIZER_PROFILES[fillType.name]
        if profile then
            local targetText = g_i18n:getText("sf_sprayer_target")
            local targets = SoilConstants.SPRAYER_RATE.AUTO_RATE_TARGETS
            if not targets then return end
            if profile.N and profile.N > 0 then targetText = targetText .. targets.N .. "N " end
            if profile.P and profile.P > 0 then targetText = targetText .. targets.P .. "P " end
            if profile.K and profile.K > 0 then targetText = targetText .. targets.K .. "K " end
            if profile.pH and profile.pH > 0 then targetText = targetText .. targets.pH .. "pH " end
            setTextColor(0.7, 0.9, 0.7, 0.8)
            renderText(cx, scrollY - self:py(6)*s, 0.008 * fontMult * s, targetText)
        end
    end

    -- Adjacent steps: offsets -2, -1, +1, +2
    -- Positioned symmetrically around center, dimming by distance
    local adjPositions = { [-2] = -0.38, [-1] = -0.21, [1] = 0.21, [2] = 0.38 }
    local adjSizes     = { [-2] = 0.008, [-1] = 0.009, [1] = 0.009, [2] = 0.008 }
    local adjAlphas    = { [-2] = 0.28,  [-1] = 0.50,  [1] = 0.50,  [2] = 0.28  }

    setTextAlignment(RenderText.ALIGN_CENTER)
    for _, offset in ipairs({-2, -1, 1, 2}) do
        local adjIdx = currentIdx + offset
        if adjIdx >= 1 and adjIdx <= #steps then
            local adjStr = self:formatRateNumber(steps[adjIdx], rateConfig)
            setTextColor(1.0, 1.0, 1.0, adjAlphas[offset])
            renderText(cx + pw * adjPositions[offset], scrollY + self:py(7)*s,
                adjSizes[offset] * fontMult * s, adjStr)
        end
    end

    -- Progress bar
    local progress = (currentIdx - 1) / (#steps - 1)
    local barPad   = pw * 0.06
    local barW     = pw - barPad * 2
    local barY     = panelY + padV
    self:drawRect(panelX + barPad, barY, barW, barH, SoilHUD.C_BAR_BG)
    if progress > 0 then
        self:drawRect(panelX + barPad, barY, barW * progress, barH, curCol)
    end

    -- Crop-optimal rate marker (cyan tick on the progress bar)
    -- Only shown when a crop is planted AND the field is below that crop's optimal level
    -- for at least one nutrient covered by the current fill type.
    local cropOptIdx = self:_calcCropTargetRateIdx(fillType)
    if cropOptIdx then
        local optProgress = (cropOptIdx - 1) / (#steps - 1)
        local tickW = 0.0012 * s
        local tickH = barH + 0.006 * s
        local tickX = panelX + barPad + barW * optProgress - tickW * 0.5
        local tickY = barY - 0.003 * s
        self:drawRect(tickX, tickY, tickW, tickH, {0.20, 0.85, 0.85, 1.0})
    end

    -- Burn warning below panel
    local warnY = panelY - self:py(14) * s
    setTextAlignment(RenderText.ALIGN_CENTER)
    if curMult >= SoilConstants.SPRAYER_RATE.BURN_GUARANTEED_THRESHOLD then
        setTextColor(1.0, 0.15, 0.15, 1.0)
        renderText(cx, warnY, 0.010 * fontMult * s, g_i18n:getText("sf_sprayer_burn_guaranteed"))
    elseif curMult > SoilConstants.SPRAYER_RATE.BURN_RISK_THRESHOLD then
        setTextColor(0.95, 0.65, 0.10, 1.0)
        renderText(cx, warnY, 0.010 * fontMult * s, g_i18n:getText("sf_sprayer_burn_possible"))
    end

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

-- ── Sprayer / spreader detection ────────────────────────────────────
-- Recursively walks the attacher-joint implement tree of `vehicle` looking
-- for the first attached object that passes isFertilizerApplicator.
-- Used so that tractor+spreader combos show the rate panel even though the
-- player is seated in the tractor, not the spreader.
-- Safe: wrapped in pcall; returns nil on any API error.
local function findApplicatorImplement(vehicle)
    if not vehicle then return nil end
    local ok, spec = pcall(function() return vehicle.spec_attacherJoints end)
    if not ok or not spec then return nil end
    local ok2, implements = pcall(function() return spec.attachedImplements end)
    if not ok2 or not implements then return nil end
    for _, impl in pairs(implements) do
        local obj = impl.object
        if obj then
            if SoilFertilityManager.isFertilizerApplicator(obj) then
                return obj
            end
            -- Recurse: implements can themselves have implements (e.g. wagon train)
            local found = findApplicatorImplement(obj)
            if found then return found end
        end
    end
    return nil
end

-- Returns the fertilizer applicator the player should adjust rate for:
--   1. The directly driven vehicle (self-propelled sprayer / spreader)
--   2. First attached implement that passes isFertilizerApplicator (tractor+spreader)
-- Returns the current vehicle if it is any fertilizer applicator (liquid sprayer,
-- dry spreader, or planter with fertilizer capability).  Uses isFertilizerApplicator
-- so the rate panel appears for all equipment types, not just spec_sprayer vehicles.
function SoilHUD:getCurrentSprayer()
    local player = g_localPlayer
    if player == nil then return nil end
    if type(player.getIsInVehicle) ~= "function" then return nil end
    if not player:getIsInVehicle() then
        -- State change: was in sprayer, now not
        if self._lastSprayerDetected ~= false then
            self._lastSprayerDetected = false
            SoilLogger.debug("getCurrentSprayer: player NOT in vehicle — rate panel hidden")
        end
        return nil
    end
    local vehicle = player:getCurrentVehicle()
    if not vehicle then return nil end

    local result = nil
    if SoilFertilityManager and SoilFertilityManager.isFertilizerApplicator then
        if SoilFertilityManager.isFertilizerApplicator(vehicle) then
            -- Self-propelled: the driven vehicle is the applicator
            result = vehicle
        else
            -- Pulled implement: scan the attacher joint tree
            result = findApplicatorImplement(vehicle)
        end
    elseif vehicle.spec_sprayer then
        -- Fallback: SoilFertilityManager not yet available, accept any sprayer
        result = vehicle
    end

    -- Log only on state change to avoid log spam
    local prevId = self._lastSprayerVehicleId
    local newId  = result and result.id or nil
    if prevId ~= newId then
        self._lastSprayerVehicleId = newId
        self._lastSprayerDetected  = (result ~= nil)
        if result then
            local isImpl = (result ~= vehicle) and "IMPLEMENT" or "DIRECT"
            SoilLogger.debug("getCurrentSprayer: APPLICATOR %s id=%s cfg=%s",
                isImpl, tostring(result.id), tostring(result.configFileName))
        else
            SoilLogger.debug("getCurrentSprayer: no applicator on vehicle cfg=%s — rate panel hidden",
                tostring(vehicle.configFileName))
        end
    end
    return result
end

-- ── Pixel helpers ────────────────────────────────────────
function SoilHUD:px(pixels) return pixels / 1920 end
function SoilHUD:py(pixels) return pixels / 1080 end