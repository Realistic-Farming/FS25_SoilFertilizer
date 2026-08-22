-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Soil Map Hooks
-- =========================================================
-- Injects the Soil Nutrient layers into the native PDA map
-- as a standard category (like Growth or Soil Type).
-- =========================================================
-- Pattern: DynamicFieldFiresInGameMenuMapFrameHooks
-- FAILFIX 2026-08-05: pairs(nil) Map freeze — nil-guards, coordinated
-- mouseEvent chain with CsMapHooks, overwrite generateOverviewOverlay so
-- custom page indices do not hit vanilla MAP_HOTSPOTS <= state fruit path,
-- always call IngameMapElement.draw superFunc.
-- =========================================================

SoilMapHooks = SoilMapHooks or {}

local function logNilOnce(key, msg)
    if InGameMenuMapFrame == nil then
        SoilLogger.warning("SoilMapHooks: %s", msg)
        return
    end
    if InGameMenuMapFrame._rfMapNilLog == nil then
        InGameMenuMapFrame._rfMapNilLog = {}
    end
    if InGameMenuMapFrame._rfMapNilLog[key] then
        return
    end
    InGameMenuMapFrame._rfMapNilLog[key] = true
    SoilLogger.warning("SoilMapHooks: %s", msg)
end

local function getSoilOverlay(frame)
    if frame == nil then return nil end
    return g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
end

local function isSoilPageActive(frame)
    if frame == nil or frame.soilMapPageIndex == nil or frame.mapOverviewSelector == nil then
        return false
    end

    local isActive = frame.mapOverviewSelector:getState() == frame.soilMapPageIndex

    if isActive ~= frame._soilPageWasActive then
        frame._soilPageWasActive = isActive
        if isActive then
            SoilLogger.debug("SoilMapHooks: PDA Soil page activated")
        end
    end

    return isActive
end

--- Ensure tables vanilla MapFrame pairs()/indexes are never nil.
--- Shared with CsMapHooks via InGameMenuMapFrame._rfMapNilLog (once-per-key).
local function ensurePairsSafeTables(frame)
    if frame == nil then
        return
    end

    if frame.ingameMap ~= nil and frame.ingameMap.ingameMap ~= nil then
        if frame.ingameMap.ingameMap.hotspots == nil then
            frame.ingameMap.ingameMap.hotspots = {}
            logNilOnce("hotspots", "ingameMap.ingameMap.hotspots was nil; guarded to {}")
        end
    end

    if frame.subCategoryDotBox ~= nil and frame.subCategoryDotBox.elements == nil then
        frame.subCategoryDotBox.elements = {}
        logNilOnce("dotElements", "subCategoryDotBox.elements was nil; guarded to {}")
    end

    if frame.displayCropTypes == nil then
        logNilOnce("displayCropTypes", "displayCropTypes is nil (loadFilters / onLoadMapFinished may not have run)")
    end

    local state = nil
    if frame.mapOverviewSelector ~= nil then
        state = frame.mapOverviewSelector:getState()
    end
    if state == nil then
        return
    end

    if frame.dataTables ~= nil and frame.dataTables[state] == nil then
        if frame.soilMapPageIndex ~= nil and state == frame.soilMapPageIndex then
            local overlay = getSoilOverlay(frame)
            if overlay ~= nil then
                frame.dataTables[state] = overlay:getDisplayValues() or {}
            else
                frame.dataTables[state] = {}
            end
            logNilOnce("dataTables_soil", string.format("dataTables[%s] was nil on Soil page; filled", tostring(state)))
        else
            logNilOnce("dataTables_" .. tostring(state), string.format("dataTables[%s] is nil", tostring(state)))
        end
    end

    if frame.filterStates ~= nil and frame.filterStates[state] == nil then
        if frame.soilMapPageIndex ~= nil and state == frame.soilMapPageIndex then
            local overlay = getSoilOverlay(frame)
            if overlay ~= nil then
                frame.filterStates[state] = overlay:getDefaultFilterState() or {}
            else
                frame.filterStates[state] = {}
            end
            logNilOnce("filterStates_soil", string.format("filterStates[%s] was nil on Soil page; filled", tostring(state)))
        else
            logNilOnce("filterStates_" .. tostring(state), string.format("filterStates[%s] is nil", tostring(state)))
        end
    end
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
        if elements == nil then
            return
        end
    end

    while #elements > expectedCount do
        elements[#elements]:delete()
        elements = dotBox.elements
        if elements == nil then
            return
        end
    end

    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            return frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == index
        end
    end

    dotBox:invalidateLayout()
end

local function suppressNativeOverlay(frame)
    if frame.ingameMap ~= nil and frame.ingameMap.setOverlayVisible ~= nil then
        frame.ingameMap:setOverlayVisible(false)
    end
    if frame.ingameMapBase ~= nil and frame.ingameMapBase.setOverlayVisible ~= nil then
        frame.ingameMapBase:setOverlayVisible(false)
    end
end

function SoilMapHooks:onLoadMapFinished()
    local soilOverlay = getSoilOverlay(self)
    if soilOverlay then
        soilOverlay:requestRefresh()
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
                SoilLogger.warning("SoilMapHooks: could not capture ingameMap ref - minimap overlay will not render")
            end
        end
    end
end

function SoilMapHooks:setupMapOverview()
    if self.soilMapPageIndex ~= nil then return end

    if self.mapSelectorTexts == nil or self.mapOverviewSelector == nil then
        return
    end

    local soilOverlay = getSoilOverlay(self)
    if soilOverlay == nil then
        return
    end

    local pageText = g_i18n:getText("sf_map_page_title") or "Soil Nutrients"

    table.insert(self.mapSelectorTexts, pageText)
    self.soilMapPageIndex = #self.mapSelectorTexts
    SoilLogger.info("SoilMapHooks: Registered native page index %d", self.soilMapPageIndex)

    self.mapOverviewSelector:setTexts(self.mapSelectorTexts)

    if self.dataTables ~= nil then
        self.dataTables[self.soilMapPageIndex] = soilOverlay:getDisplayValues() or {}
    end

    if self.filterStates ~= nil then
        self.filterStates[self.soilMapPageIndex] = soilOverlay:getDefaultFilterState() or {}
    end

    if self.numSelectedFilters ~= nil then
        self.numSelectedFilters[self.soilMapPageIndex] = 0
    end

    updateSubCategoryDotBox(self)
end

function SoilMapHooks:onFrameOpen()
    ensurePairsSafeTables(self)
    if self.soilMapPageIndex == nil then
        SoilMapHooks.setupMapOverview(self)
    end
end

--- Own-page activation after vanilla selector work.
function SoilMapHooks:onSoilPageSelected(state)
    if self.soilMapPageIndex == nil or state ~= self.soilMapPageIndex then
        return
    end

    SoilLogger.debug("SoilMapHooks: Selector changed to Soil page (%d)", state)

    local soilOverlay = getSoilOverlay(self)
    if soilOverlay == nil then return end

    if self.dataTables ~= nil and self.dataTables[self.soilMapPageIndex] == nil then
        self.dataTables[self.soilMapPageIndex] = soilOverlay:getDisplayValues() or {}
    end
    if self.filterStates ~= nil and self.filterStates[self.soilMapPageIndex] == nil then
        self.filterStates[self.soilMapPageIndex] = soilOverlay:getDefaultFilterState() or {}
    end
    if self.numSelectedFilters ~= nil then
        self.numSelectedFilters[self.soilMapPageIndex] = 0
    end

    suppressNativeOverlay(self)
    soilOverlay:requestRefresh()
end

--- Overwrite: skip vanilla fruit path when Soil page active (MAP_HOTSPOTS <= state hazard).
function SoilMapHooks:generateOverviewOverlay(superFunc)
    if isSoilPageActive(self) then
        suppressNativeOverlay(self)
        local soilOverlay = getSoilOverlay(self)
        if soilOverlay ~= nil then
            soilOverlay:requestRefresh()
        end
        return
    end
    if superFunc ~= nil then
        return superFunc(self)
    end
end

function SoilMapHooks.onDrawIngameMapElement(elementSelf, ...)
    if elementSelf == nil or elementSelf.ingameMap == nil then return end

    local _soilOverlay = g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
    if _soilOverlay and not _soilOverlay.ingameMapRef and elementSelf.ingameMap.layout then
        _soilOverlay.ingameMapRef = elementSelf.ingameMap
        SoilLogger.debug("SoilMapHooks: ingameMap ref captured from PDA draw (fallback)")
    end

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

--- Sidebar / cell click only; coordinated chain calls this before vanilla (no pcall amp).
function SoilMapHooks.handleMouseEvent(frame, posX, posY, isDown, isUp, button, eventUsed)
    local pageActive = false
    local ok, result = pcall(isSoilPageActive, frame)
    if ok then pageActive = result end
    if not pageActive then
        return false
    end

    if isDown then
        frame.soilMapClickX = posX
        frame.soilMapClickY = posY
    end

    if not eventUsed and isDown and (button == Input.MOUSE_BUTTON_LEFT or button == Input.MOUSE_BUTTON_RIGHT) then
        local soilOverlay = getSoilOverlay(frame)
        if soilOverlay and soilOverlay:onSideBarClick(posX, posY) then
            return true
        end
    end

    if not eventUsed and isUp and button == Input.MOUSE_BUTTON_LEFT then
        local soilOverlay = getSoilOverlay(frame)
        if soilOverlay and frame.soilMapClickX and frame.soilMapClickY then
            local dx = math.abs(posX - frame.soilMapClickX)
            local dy = math.abs(posY - frame.soilMapClickY)
            if dx < 0.005 and dy < 0.005 then
                local ingameMap = (frame.ingameMapBase and frame.ingameMapBase.layout and frame.ingameMapBase)
                               or (frame.ingameMap     and frame.ingameMap.layout     and frame.ingameMap)
                if ingameMap then
                    local mapX, mapY, mapW, mapH = soilOverlay:getMapRenderBounds(frame, ingameMap)
                    if mapX and posX >= mapX and posX <= mapX + mapW
                           and posY >= mapY and posY <= mapY + mapH then
                        soilOverlay:onMapClick(ingameMap, posX, posY)
                    end
                end
            end
        end
    end

    if isUp then
        frame.soilMapClickX = nil
        frame.soilMapClickY = nil
    end

    return false
end

function SoilMapHooks:getHasChangeableFilterList(superFunc, ...)
    if self.soilMapPageIndex ~= nil and self.mapOverviewSelector ~= nil then
        if self.mapOverviewSelector:getState() == self.soilMapPageIndex then
            return false
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

-- ── Shared installs (idempotent with CsMapHooks) ──────────

--- Belt: if vanilla pageMapOverview:onLoadMapFinished never ran (e.g. aborted
--- loadMission00Finished), restore real filter tables from mapOverlayGenerator
--- before onFrameOpen → loadFilters. Do NOT paper with empty {} alone.
local function restoreVanillaMapFilterInitIfMissing(frame)
    if frame == nil then
        return
    end
    local fruitKey = InGameMenuMapFrame.MAP_FRUIT_TYPE
    local needsRestore = frame.displayCropTypes == nil
        or frame.dataTables == nil
        or (fruitKey ~= nil and frame.dataTables[fruitKey] == nil)
    if not needsRestore then
        return
    end

    local mission = g_currentMission
    local mapOverlayGenerator = mission ~= nil and mission.mapOverlayGenerator or nil
    frame.displaySoilStateMapping = {}
    if mapOverlayGenerator ~= nil then
        frame.displayCropTypes = mapOverlayGenerator:getDisplayCropTypes()
        frame.displayGrowthStates = mapOverlayGenerator:getDisplayGrowthStates()
        frame.displaySoilStates = mapOverlayGenerator:getDisplaySoilStates()
        if frame.displaySoilStates ~= nil then
            for index, state in pairs(frame.displaySoilStates) do
                if state.isActive then
                    state.soilStateIndex = index
                    table.insert(frame.displaySoilStateMapping, state)
                end
            end
        end
    end

    if frame.dataTables == nil then
        frame.dataTables = {}
    end
    frame.dataTables[InGameMenuMapFrame.MAP_SOIL] = frame.displaySoilStateMapping or {}
    frame.dataTables[InGameMenuMapFrame.MAP_FRUIT_TYPE] = frame.displayCropTypes or {}
    frame.dataTables[InGameMenuMapFrame.MAP_GROWTH] = frame.displayGrowthStates or {}
    frame.dataTables[InGameMenuMapFrame.MAP_HOTSPOTS] = InGameMenuMapFrame.HOTSPOT_FILTER_CATEGORIES or {}
    frame.dataTables[InGameMenuMapFrame.MAP_FARMLANDS] = frame.farmlandItems or {}

    if g_gameSettings ~= nil and GameSettings ~= nil and GameSettings.SETTING ~= nil then
        g_gameSettings:setValue(GameSettings.SETTING.INGAME_MAP_HOTSPOT_FILTER, 4294967295, true)
    end
    if g_terrainNode ~= nil and frame.filterList ~= nil and type(frame.filterList.reloadData) == "function" then
        frame.filterList:reloadData()
    end

    if InGameMenuMapFrame._rfVanillaFilterInitRestoredLogged ~= true then
        InGameMenuMapFrame._rfVanillaFilterInitRestoredLogged = true
        SoilLogger.info("SoilMapHooks: restored vanilla map filter init before onFrameOpen")
    end
end

local function installVanillaFilterInitBelt()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onFrameOpen == nil then
        return
    end
    if InGameMenuMapFrame._rfVanillaFilterInitBeltInstalled then
        return
    end
    InGameMenuMapFrame._rfVanillaFilterInitBeltInstalled = true
    InGameMenuMapFrame.onFrameOpen = Utils.prependedFunction(
        InGameMenuMapFrame.onFrameOpen,
        restoreVanillaMapFilterInitIfMissing
    )
end

local function installPairsSafeMouseChain()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.mouseEvent == nil then
        return
    end

    if InGameMenuMapFrame._rfMapMouseHandlers == nil then
        InGameMenuMapFrame._rfMapMouseHandlers = {}
    end

    local handlers = InGameMenuMapFrame._rfMapMouseHandlers
    local replaced = false
    for i = 1, #handlers do
        if handlers[i].name == "SoilMapHooks" then
            handlers[i].fn = SoilMapHooks.handleMouseEvent
            replaced = true
            break
        end
    end
    if not replaced then
        table.insert(handlers, { name = "SoilMapHooks", fn = SoilMapHooks.handleMouseEvent })
    end

    if InGameMenuMapFrame._rfMapMouseChainInstalled then
        return
    end
    InGameMenuMapFrame._rfMapMouseChainInstalled = true

    InGameMenuMapFrame.mouseEvent = Utils.overwrittenFunction(
        InGameMenuMapFrame.mouseEvent,
        function(self, superFunc, posX, posY, isDown, isUp, button, eventUsed)
            ensurePairsSafeTables(self)
            local list = InGameMenuMapFrame._rfMapMouseHandlers
            if list ~= nil then
                for i = 1, #list do
                    local h = list[i]
                    if h ~= nil and h.fn ~= nil then
                        local used = h.fn(self, posX, posY, isDown, isUp, button, eventUsed)
                        if used then
                            return true
                        end
                    end
                end
            end
            return superFunc(self, posX, posY, isDown, isUp, button, eventUsed)
        end
    )
end

local function installDeselectGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onClickDeselectAll == nil then
        return
    end
    if InGameMenuMapFrame._rfDeselectGuardInstalled then
        return
    end
    InGameMenuMapFrame._rfDeselectGuardInstalled = true

    InGameMenuMapFrame.onClickDeselectAll = Utils.overwrittenFunction(
        InGameMenuMapFrame.onClickDeselectAll,
        function(self, superFunc, exceptionSection, exceptionIndex)
            if self.getHasChangeableFilterList ~= nil and not self:getHasChangeableFilterList() then
                return
            end
            ensurePairsSafeTables(self)
            local state = self.mapOverviewSelector and self.mapOverviewSelector:getState()
            if state == nil then
                return
            end
            local dt = self.dataTables and self.dataTables[state]
            if dt == nil then
                logNilOnce("deselect_nil_table", string.format("onClickDeselectAll blocked: dataTables[%s] nil", tostring(state)))
                return
            end
            if InGameMenuMapFrame.MAP_HOTSPOTS ~= nil and state == InGameMenuMapFrame.MAP_HOTSPOTS then
                if dt[1] == nil or dt[2] == nil then
                    logNilOnce("deselect_hotspot_shape", "onClickDeselectAll blocked: hotspot filter subtables nil")
                    return
                end
            end
            return superFunc(self, exceptionSection, exceptionIndex)
        end
    )
end

local function installSelectorGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onClickMapOverviewSelector == nil then
        return
    end
    if InGameMenuMapFrame._rfSelectorGuardInstalled then
        if not InGameMenuMapFrame._rfSoilSelectorPostInstalled then
            InGameMenuMapFrame._rfSoilSelectorPostInstalled = true
            local prev = InGameMenuMapFrame.onClickMapOverviewSelector
            InGameMenuMapFrame.onClickMapOverviewSelector = function(self, state)
                prev(self, state)
                SoilMapHooks.onSoilPageSelected(self, state)
            end
        end
        return
    end
    InGameMenuMapFrame._rfSelectorGuardInstalled = true
    InGameMenuMapFrame._rfSoilSelectorPostInstalled = true

    InGameMenuMapFrame.onClickMapOverviewSelector = Utils.overwrittenFunction(
        InGameMenuMapFrame.onClickMapOverviewSelector,
        function(self, superFunc, state)
            ensurePairsSafeTables(self)
            if superFunc ~= nil then
                superFunc(self, state)
            end
            SoilMapHooks.onSoilPageSelected(self, state)
        end
    )
end

local function installFrameCloseGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.onFrameClose == nil then
        return
    end
    if InGameMenuMapFrame._rfFrameCloseHotspotGuard then
        return
    end
    InGameMenuMapFrame._rfFrameCloseHotspotGuard = true

    InGameMenuMapFrame.onFrameClose = Utils.overwrittenFunction(
        InGameMenuMapFrame.onFrameClose,
        function(self, superFunc)
            ensurePairsSafeTables(self)
            return superFunc(self)
        end
    )
end

local function installFilterListDeselectGuard()
    if InGameMenuMapFrame == nil or InGameMenuMapFrame.initialize == nil then
        return
    end
    if InGameMenuMapFrame._rfFilterListInitGuardInstalled then
        return
    end
    InGameMenuMapFrame._rfFilterListInitGuardInstalled = true

    InGameMenuMapFrame.initialize = Utils.appendedFunction(
        InGameMenuMapFrame.initialize,
        function(self)
            if self._rfFilterListDeselectGuarded then
                return
            end
            local filterList = self.filterList
            if filterList == nil or filterList.mouseEvent == nil then
                return
            end
            self._rfFilterListDeselectGuarded = true
            local prev = filterList.mouseEvent
            function filterList.mouseEvent(list, posX, posY, isDown, isUp, button, eventUsed)
                if isDown and button == Input.MOUSE_BUTTON_RIGHT then
                    if self.getHasChangeableFilterList ~= nil and not self:getHasChangeableFilterList() then
                        if SmoothListElement ~= nil and SmoothListElement.mouseEvent ~= nil then
                            return SmoothListElement.mouseEvent(list, posX, posY, isDown, isUp, button, eventUsed)
                        end
                        return eventUsed
                    end
                end
                return prev(list, posX, posY, isDown, isUp, button, eventUsed)
            end
        end
    )
end

-- ── Install Hooks ────────────────────────────────────────

if InGameMenuMapFrame ~= nil then
    if InGameMenuMapFrame.onLoadMapFinished ~= nil then
        InGameMenuMapFrame.onLoadMapFinished = Utils.appendedFunction(InGameMenuMapFrame.onLoadMapFinished, SoilMapHooks.onLoadMapFinished)
    end

    if InGameMenuMapFrame.setupMapOverview ~= nil then
        InGameMenuMapFrame.setupMapOverview = Utils.appendedFunction(InGameMenuMapFrame.setupMapOverview, SoilMapHooks.setupMapOverview)
    end

    if InGameMenuMapFrame.onFrameOpen ~= nil then
        installVanillaFilterInitBelt()
        InGameMenuMapFrame.onFrameOpen = Utils.appendedFunction(InGameMenuMapFrame.onFrameOpen, SoilMapHooks.onFrameOpen)
    end

    installSelectorGuard()

    if InGameMenuMapFrame.generateOverviewOverlay ~= nil then
        InGameMenuMapFrame.generateOverviewOverlay = Utils.overwrittenFunction(
            InGameMenuMapFrame.generateOverviewOverlay, SoilMapHooks.generateOverviewOverlay)
    end

    if InGameMenuMapFrame.draw ~= nil then
        InGameMenuMapFrame.draw = Utils.appendedFunction(InGameMenuMapFrame.draw, SoilMapHooks.onDrawOverlayHud)
    elseif InGameMenuMapFrame.onDraw ~= nil then
        InGameMenuMapFrame.onDraw = Utils.appendedFunction(InGameMenuMapFrame.onDraw, SoilMapHooks.onDrawOverlayHud)
    end

    installPairsSafeMouseChain()
    installDeselectGuard()
    installFrameCloseGuard()
    installFilterListDeselectGuard()

    if InGameMenuMapFrame.getHasChangeableFilterList ~= nil then
        InGameMenuMapFrame.getHasChangeableFilterList = Utils.overwrittenFunction(
            InGameMenuMapFrame.getHasChangeableFilterList, SoilMapHooks.getHasChangeableFilterList)
    end

    if InGameMenuMapFrame.onFrameClose ~= nil then
        InGameMenuMapFrame.onFrameClose = Utils.appendedFunction(InGameMenuMapFrame.onFrameClose, SoilMapHooks.onFrameClose)
    end

    SoilLogger.info("SoilMapHooks: installed on InGameMenuMapFrame (pairs-safe mouse chain)")
end

-- Hook IngameMapElement.draw at class level.
-- ALWAYS call superFunc when present (George FAILFIX: prior early-return skipped vanilla draw).
if IngameMapElement ~= nil then
    IngameMapElement.draw = Utils.overwrittenFunction(IngameMapElement.draw, function(self, superFunc, clipX1, clipY1, clipX2, clipY2)
        if superFunc ~= nil then
            superFunc(self, clipX1, clipY1, clipX2, clipY2)
        end
        if self.ingameMap == nil then
            return
        end
        SoilMapHooks.onDrawIngameMapElement(self)
    end)
    SoilLogger.info("SoilMapHooks: IngameMapElement.draw hook installed for overlay drawing")
else
    SoilLogger.warning("SoilMapHooks: IngameMapElement not available - map overlay dots will not draw")
end

-- Hook IngameMap.drawFields at class level for DMV minimap heatmap rendering.
if IngameMap ~= nil and IngameMap.drawFields ~= nil then
    IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, function(mapSelf)
        local sfm = g_SoilFertilityManager
        if sfm and sfm.soilMinimapLayer and sfm.settings and sfm.settings.enabled then
            sfm.soilMinimapLayer:draw(mapSelf)
        end
    end)
    SoilLogger.info("SoilMapHooks: IngameMap.drawFields hook installed for DMV minimap heatmap")
else
    SoilLogger.warning("SoilMapHooks: IngameMap.drawFields not available - DMV minimap heatmap will not render")
end

-- =========================================================
-- BUILD 09:19 (PB-12): keep the Growth-map field drawer inside the visible frame.
-- =========================================================
-- Brian opened field information at the LEFT edge of the map and the drawer masked the
-- start of every label: "...ind", "...d by", "...ed", "...ds lime". The words were not
-- truncated, the box was simply off-screen to the left and the visible fragment was its
-- right-hand tail.
--
-- The cause is vanilla and it is a missing clamp, not a missing flip. In
-- scripts/gui/InGameMenuMapUtil.lua the drawer is placed relative to the cursor, and when
-- it goes left the placement is `posX = posX - fieldInfoBox.size[1]` with nothing holding
-- posX at or above zero. getFieldInfoBoxOrientation only reconsiders the side for RIGHT and
-- TOP overflow (outRight / outTop); there is no outLeft case, so at the left edge the box
-- keeps its left placement and simply runs off the screen.
--
-- We do not reimplement the placement. Vanilla is left to choose its side and its anchor
-- exactly as before, and this appended pass only pulls the finished box back inside the
-- frame if it ended up outside it. That is the smallest correct patch: it cannot change
-- where the drawer appears in the normal case (the clamp is a no-op away from the edges),
-- it survives a vanilla change to the orientation rules, and it needs no knowledge of the
-- internals it is correcting.
--
-- setAbsolutePosition is the same call vanilla uses and it walks the children with the
-- parent (GuiElement.lua:1133-1150), so the labels move with the box rather than being
-- re-laid out.
--
-- Installed under a flag on InGameMenuMapUtil itself because CsMapHooks carries the same
-- patch: whichever of Soil / Crop Stress loads first installs it, the other stands down,
-- and the drawer is fixed for the player either way.

local function clampFieldInfoBoxInsideFrame(fieldInfoBox)
    if fieldInfoBox == nil then
        return
    end
    local ap = fieldInfoBox.absPosition
    local as = fieldInfoBox.absSize
    if type(ap) ~= "table" or type(as) ~= "table" then
        return
    end
    local px, py = ap[1], ap[2]
    local w, h = as[1], as[2]
    if type(px) ~= "number" or type(py) ~= "number"
        or type(w) ~= "number" or type(h) ~= "number" then
        return
    end

    -- GUI space is 0..1 on both axes. The safe-frame offsets are the same margins the
    -- vanilla HUD keeps off the screen edge (IngameMap:getMapPosition returns exactly
    -- g_safeFrameOffsetX, g_safeFrameOffsetY), so the drawer lands on the same guide the
    -- rest of the interface uses instead of a number invented here.
    local marginX = (type(g_safeFrameOffsetX) == "number") and g_safeFrameOffsetX or 0
    local marginY = (type(g_safeFrameOffsetY) == "number") and g_safeFrameOffsetY or 0

    -- A box wider than the space between the margins cannot satisfy both edges. Left wins,
    -- because the left edge is where the label text starts and an unreadable first character
    -- is the defect being fixed.
    local maxX = 1 - marginX - w
    local newX = px
    if newX > maxX then newX = maxX end
    if newX < marginX then newX = marginX end

    local maxY = 1 - marginY - h
    local newY = py
    if newY > maxY then newY = maxY end
    if newY < marginY then newY = marginY end

    if newX ~= px or newY ~= py then
        if type(fieldInfoBox.setAbsolutePosition) == "function" then
            fieldInfoBox:setAbsolutePosition(newX, newY)
        end
    end
end

if InGameMenuMapUtil ~= nil
    and type(InGameMenuMapUtil.updateFieldInfoBoxPosition) == "function"
    and InGameMenuMapUtil._rfFieldInfoBoxClampInstalled ~= true then

    InGameMenuMapUtil._rfFieldInfoBoxClampInstalled = true
    InGameMenuMapUtil.updateFieldInfoBoxPosition = Utils.appendedFunction(
        InGameMenuMapUtil.updateFieldInfoBoxPosition,
        function(fieldInfoBox)
            clampFieldInfoBoxInsideFrame(fieldInfoBox)
        end)
    SoilLogger.info("SoilMapHooks: field info drawer clamped inside the safe frame (PB-12)")
elseif InGameMenuMapUtil == nil then
    SoilLogger.warning("SoilMapHooks: InGameMenuMapUtil not available - field info drawer clamp not installed")
end
