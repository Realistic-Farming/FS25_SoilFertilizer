-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Soil Map Hooks
-- =========================================================
-- Injects the Soil Nutrient layers into the native PDA map
-- as a standard category (like Growth or Soil Type).
-- =========================================================
-- Pattern: DynamicFieldFiresInGameMenuMapFrameHooks
-- =========================================================

SoilMapHooks = {}

local function getSoilOverlay(frame)
    if frame == nil then return nil end
    return g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
end

local function isSoilPageActive(frame)
    if frame == nil or frame.soilMapPageIndex == nil or frame.mapOverviewSelector == nil then
        return false
    end
    
    local isActive = frame.mapOverviewSelector:getState() == frame.soilMapPageIndex
    
    -- Local tracking to log transitions
    if isActive ~= frame._soilPageWasActive then
        frame._soilPageWasActive = isActive
        if isActive then
            SoilLogger.debug("SoilMapHooks: PDA Soil page activated")
        end
    end
    
    return isActive
end

local function updateSubCategoryDotBox(frame)
    if frame == nil or frame.subCategoryDotBox == nil or frame.mapSelectorTexts == nil then
        return
    end

    local dotBox = frame.subCategoryDotBox
    local elements = dotBox.elements
    if elements == nil or #elements == 0 then
        return
    end

    local expectedCount = #frame.mapSelectorTexts
    while #elements < expectedCount do
        dotBox:addElement(elements[1]:clone(dotBox))
        elements = dotBox.elements
    end

    while #elements > expectedCount do
        elements[#elements]:delete()
        elements = dotBox.elements
    end

    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            return frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == index
        end
    end

    dotBox:invalidateLayout()
end

function SoilMapHooks:onLoadMapFinished()
    local soilOverlay = getSoilOverlay(self)
    if soilOverlay then
        soilOverlay:requestRefresh()
        -- Cache the IngameMap HUD reference for the minimap overlay.
        -- g_currentMission.ingameMap is nil in FS25; the real instance lives on the
        -- InGameMenuMapFrame as ingameMapBase (preferred) or ingameMap.
        -- onLoadMapFinished fires at map-load time so we capture it before first draw.
        if not soilOverlay.ingameMapRef then
            local ref = nil
            if self.ingameMapBase and self.ingameMapBase.layout then
                ref = self.ingameMapBase
            elseif self.ingameMap and self.ingameMap.layout then
                ref = self.ingameMap
            end
            if ref then
                soilOverlay.ingameMapRef = ref
                SoilLogger.debug("SoilMapHooks: ingameMap ref cached for minimap overlay (state=%s)", tostring(ref.state))
            else
                SoilLogger.warning("SoilMapHooks: could not capture ingameMap ref — minimap overlay will not render")
            end
        end
    end
end

function SoilMapHooks:setupMapOverview()
    if self.soilMapPageIndex ~= nil then return end
    if self.mapSelectorTexts == nil or self.mapOverviewSelector == nil then return end

    local soilOverlay = getSoilOverlay(self)
    if soilOverlay == nil then return end

    local pageText = g_i18n:getText("sf_map_page_title") or "Soil Nutrients"
    
    -- FS25 InGameMenuMapFrame.mapSelectorTexts is usually 1-indexed table of strings
    table.insert(self.mapSelectorTexts, pageText)
    self.soilMapPageIndex = #self.mapSelectorTexts
    SoilLogger.debug("SoilMapHooks: Registered native page index %d", self.soilMapPageIndex)

    self.mapOverviewSelector:setTexts(self.mapSelectorTexts)

    -- Mimic DFF: Populate native data tables so the engine handles clearing/switching correctly
    if self.dataTables ~= nil then
        self.dataTables[self.soilMapPageIndex] = soilOverlay:getDisplayValues()
    end

    if self.filterStates ~= nil then
        self.filterStates[self.soilMapPageIndex] = soilOverlay:getDefaultFilterState()
    end

    updateSubCategoryDotBox(self)
end

function SoilMapHooks:onClickMapOverviewSelector(state)
    if self.soilMapPageIndex == nil or state ~= self.soilMapPageIndex then
        return
    end

    SoilLogger.debug("SoilMapHooks: Selector changed to Soil page (%d)", state)

    local soilOverlay = getSoilOverlay(self)
    if soilOverlay == nil then return end

    -- Ensure our data tables are initialised (DFF pattern)
    if self.dataTables ~= nil and self.dataTables[self.soilMapPageIndex] == nil then
        self.dataTables[self.soilMapPageIndex] = soilOverlay:getDisplayValues()
    end
    if self.filterStates ~= nil and self.filterStates[self.soilMapPageIndex] == nil then
        self.filterStates[self.soilMapPageIndex] = soilOverlay:getDefaultFilterState()
    end
    if self.numSelectedFilters ~= nil then
        self.numSelectedFilters[self.soilMapPageIndex] = 0
    end

    -- Let generateOverviewOverlay (hooked below) handle native overlay suppression.
    -- Calling it explicitly here ensures it runs even if the appended hook order differs.
    if self.generateOverviewOverlay ~= nil then
        self:generateOverviewOverlay()
    end

    soilOverlay:requestRefresh()
end

-- Called by the engine every time it tries to rebuild the density-map overlay texture.
-- When our Soil page is active we suppress the native overlay so it doesn't overwrite
-- our manually-drawn heatmap dots.  This is the DFF-correct suppression point.
function SoilMapHooks:generateOverviewOverlay()
    if self.soilMapPageIndex == nil or self.mapOverviewSelector == nil then return end
    if self.mapOverviewSelector:getState() ~= self.soilMapPageIndex then return end

    -- Hide the native density-map overlay so it does not render on top of our dots.
    if self.ingameMap ~= nil and self.ingameMap.setOverlayVisible ~= nil then
        self.ingameMap:setOverlayVisible(false)
    end
    if self.ingameMapBase ~= nil and self.ingameMapBase.setOverlayVisible ~= nil then
        self.ingameMapBase:setOverlayVisible(false)
    end

    local soilOverlay = getSoilOverlay(self)
    if soilOverlay ~= nil then
        soilOverlay:requestRefresh()
    end
end

-- Called from IngameMapElement.draw (appended at class level).
-- `elementSelf` is the IngameMapElement instance being drawn.
-- We walk up the parent chain to find whichever InGameMenuMapFrame owns it,
-- then check if our soil page is active before drawing.
function SoilMapHooks.onDrawIngameMapElement(elementSelf, ...)
    if elementSelf == nil or elementSelf.ingameMap == nil then return end

    -- Opportunistically cache the IngameMap ref if setupMapOverview didn't get it
    local _soilOverlay = g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
    if _soilOverlay and not _soilOverlay.ingameMapRef and elementSelf.ingameMap.layout then
        _soilOverlay.ingameMapRef = elementSelf.ingameMap
        SoilLogger.debug("SoilMapHooks: ingameMap ref captured from PDA draw (fallback)")
    end

    -- Walk up (max 6 levels) to find the frame that has soilMapPageIndex
    local frame = elementSelf.parent
    local depth = 0
    while frame ~= nil and depth < 6 do
        if frame.soilMapPageIndex ~= nil then break end
        frame = frame.parent
        depth = depth + 1
    end

    if frame == nil or frame.soilMapPageIndex == nil then return end
    if frame.mapOverviewSelector == nil then return end
    if frame.mapOverviewSelector:getState() ~= frame.soilMapPageIndex then return end

    local soilOverlay = g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
    if soilOverlay == nil then return end

    soilOverlay:onDraw(frame, elementSelf, elementSelf.ingameMap, frame.soilMapPageIndex)
end

function SoilMapHooks:onDrawOverlayHud()
    if not isSoilPageActive(self) then return end

    local soilOverlay = getSoilOverlay(self)
    if soilOverlay == nil then return end

    soilOverlay:onDrawHud(self)
end

function SoilMapHooks:onMouseEvent(superFunc, posX, posY, isDown, isUp, button, eventUsed)
    -- Guard: isSoilPageActive may error if selector is in transition (first-open race condition)
    local pageActive = false
    local ok, result = pcall(isSoilPageActive, self)
    if ok then pageActive = result end

    if not pageActive then
        local ok2, ret = pcall(superFunc, self, posX, posY, isDown, isUp, button, eventUsed)
        if not ok2 then
            SoilLogger.debug("[SoilMapHooks] mouseEvent superFunc error (frame in transition): %s", tostring(ret))
        end
        return ret
    end

    -- Store down position to distinguish click from drag
    if isDown then
        self.soilMapClickX = posX
        self.soilMapClickY = posY
    end

    -- Manual click detection for our sidebar buttons (handled on Down)
    if not eventUsed and isDown and (button == Input.MOUSE_BUTTON_LEFT or button == Input.MOUSE_BUTTON_RIGHT) then
        local soilOverlay = getSoilOverlay(self)
        if soilOverlay and soilOverlay:onSideBarClick(posX, posY) then
            return true -- Consume click
        end
    end

    -- Cell inspection: left-click inside the map area
    -- We do this on Up to avoid blocking the native drag-start on Down.
    -- We also check the distance to ensure it was a click, not a drag.
    if not eventUsed and isUp and button == Input.MOUSE_BUTTON_LEFT then
        local soilOverlay = getSoilOverlay(self)
        if soilOverlay and self.soilMapClickX and self.soilMapClickY then
            local dx = math.abs(posX - self.soilMapClickX)
            local dy = math.abs(posY - self.soilMapClickY)
            -- Distance threshold (normalized screen units): 0.005 is roughly 8-10 pixels
            if dx < 0.005 and dy < 0.005 then
                local ingameMap = (self.ingameMapBase and self.ingameMapBase.layout and self.ingameMapBase)
                               or (self.ingameMap     and self.ingameMap.layout     and self.ingameMap)
                if ingameMap then
                    local mapX, mapY, mapW, mapH = soilOverlay:getMapRenderBounds(self, ingameMap)
                    if mapX and posX >= mapX and posX <= mapX + mapW
                           and posY >= mapY and posY <= mapY + mapH then
                        soilOverlay:onMapClick(ingameMap, posX, posY)
                        -- Fall through to superFunc below
                    end
                end
            end
        end
    end

    if isUp then
        self.soilMapClickX = nil
        self.soilMapClickY = nil
    end

    -- Let the native handler handle movement, zooming, and map dragging
    local ok3, ret3 = pcall(superFunc, self, posX, posY, isDown, isUp, button, eventUsed)
    if not ok3 then
        SoilLogger.debug("[SoilMapHooks] mouseEvent superFunc error: %s", tostring(ret3))
    end
    return ret3
end

function SoilMapHooks:getHasChangeableFilterList(superFunc, ...)
    if self.soilMapPageIndex ~= nil and self.mapOverviewSelector ~= nil then
        if self.mapOverviewSelector:getState() == self.soilMapPageIndex then
            return false -- We hide the native list and draw our own
        end
    end
    return superFunc(self, ...)
end

function SoilMapHooks:onFrameClose()
    local soilOverlay = getSoilOverlay(self)
    if soilOverlay ~= nil then
        soilOverlay.selectedCell = nil
        soilOverlay:requestRefresh()
    end
end

-- ── Install Hooks ────────────────────────────────────────

if InGameMenuMapFrame ~= nil then
    if InGameMenuMapFrame.onLoadMapFinished ~= nil then
        InGameMenuMapFrame.onLoadMapFinished = Utils.appendedFunction(InGameMenuMapFrame.onLoadMapFinished, SoilMapHooks.onLoadMapFinished)
    end

    if InGameMenuMapFrame.setupMapOverview ~= nil then
        InGameMenuMapFrame.setupMapOverview = Utils.appendedFunction(InGameMenuMapFrame.setupMapOverview, SoilMapHooks.setupMapOverview)
    end

    if InGameMenuMapFrame.onClickMapOverviewSelector ~= nil then
        InGameMenuMapFrame.onClickMapOverviewSelector = Utils.appendedFunction(InGameMenuMapFrame.onClickMapOverviewSelector, SoilMapHooks.onClickMapOverviewSelector)
    end

    -- Hook generateOverviewOverlay so the engine calls our suppression every time it
    -- tries to rebuild the native density-map overlay texture (DFF pattern).
    if InGameMenuMapFrame.generateOverviewOverlay ~= nil then
        InGameMenuMapFrame.generateOverviewOverlay = Utils.appendedFunction(InGameMenuMapFrame.generateOverviewOverlay, SoilMapHooks.generateOverviewOverlay)
    end

    if InGameMenuMapFrame.draw ~= nil then
        InGameMenuMapFrame.draw = Utils.appendedFunction(InGameMenuMapFrame.draw, SoilMapHooks.onDrawOverlayHud)
    elseif InGameMenuMapFrame.onDraw ~= nil then
        InGameMenuMapFrame.onDraw = Utils.appendedFunction(InGameMenuMapFrame.onDraw, SoilMapHooks.onDrawOverlayHud)
    end

    if InGameMenuMapFrame.mouseEvent ~= nil then
        InGameMenuMapFrame.mouseEvent = Utils.overwrittenFunction(InGameMenuMapFrame.mouseEvent, SoilMapHooks.onMouseEvent)
    end

    if InGameMenuMapFrame.getHasChangeableFilterList ~= nil then
        InGameMenuMapFrame.getHasChangeableFilterList = Utils.overwrittenFunction(InGameMenuMapFrame.getHasChangeableFilterList, SoilMapHooks.getHasChangeableFilterList)
    end

    if InGameMenuMapFrame.onFrameClose ~= nil then
        InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(InGameMenuMapFrame.onFrameClose, SoilMapHooks.onFrameClose)
    end

    SoilLogger.info("SoilMapHooks: installed on InGameMenuMapFrame (Manual UI Mode)")
end

-- Hook IngameMapElement.draw at class level.
-- Use overwrittenFunction so we can guard against ingameMap being nil before
-- the vanilla draw body runs (prevents "attempt to index nil with 'drawMapOnly'").
if IngameMapElement ~= nil then
    IngameMapElement.draw = Utils.overwrittenFunction(IngameMapElement.draw, function(self, superFunc, clipX1, clipY1, clipX2, clipY2)
        -- Standalone <IngameMap> XML elements inherit this draw but have self.ingameMap == nil.
        -- Vanilla line 570 crashes on that, so guard before calling superFunc.
        if self.ingameMap == nil then return end
        superFunc(self, clipX1, clipY1, clipX2, clipY2)
        SoilMapHooks.onDrawIngameMapElement(self)
    end)
    SoilLogger.info("SoilMapHooks: IngameMapElement.draw hook installed for overlay drawing")
else
    SoilLogger.warning("SoilMapHooks: IngameMapElement not available — map overlay dots will not draw")
end