-- map_click_guard_current_page_test.lua - the map frame must only consume mouse events
-- while the map frame is the page actually on screen.
--
-- WHY THIS EXISTS. `isSoilPageActive` tested one thing: whether the map frame's
-- `mapOverviewSelector` is parked on the Soil layer. That selector is the map frame's
-- REMEMBERED sub-page. It survives leaving the map entirely, so it answers "the Soil layer
-- is what the map will show next time", not "the map is on screen now".
--
-- FS25 has no GUI z-order, so a frame that is not displayed still receives mouse events, and
-- `SoilMapOverlay:onSideBarClick` matches its `buttonRects` on screen coordinates alone. Put
-- those together and a click anywhere on another Esc Realistic Farming page that happened to
-- land on the help rect opened the SOIL MAP OVERLAY help dialog. Wizard hit it on the
-- StockGuard Esc page and screenshotted it (SG10-051, 2026-09-27).
--
-- What this locks:
--   the map frame is the current page      -> events are handled as before
--   another page is current                -> handler declines, overlay never consulted
--   the menu cannot be resolved            -> permissive, unchanged behaviour
--   selector is off the Soil layer         -> declines, whatever the current page is
--
-- It does not prove anything about where the buttons are drawn or what they do once hit.
--
--!load: src/utils/Logger.lua, src/hooks/SoilMapHooks.lua

Input = Input or { MOUSE_BUTTON_LEFT = 1, MOUSE_BUTTON_RIGHT = 2 }
InGameMenu = InGameMenu or {}

local SOIL_PAGE = 4

--- A map frame parked on the Soil layer, which is the state that used to be enough.
local function mapFrame()
    return {
        soilMapPageIndex = SOIL_PAGE,
        mapOverviewSelector = { getState = function() return SOIL_PAGE end },
    }
end

--- Record every onSideBarClick the handler makes.
local function overlay()
    local o = { clicks = 0 }
    o.onSideBarClick = function(_, _, _)
        o.clicks = o.clicks + 1
        return true
    end
    return o
end

--- Put the engine in a state where `which` is the page on screen.
local function setCurrentPage(which)
    g_gui = { screenControllers = { [InGameMenu] = { currentPage = which } } }
    g_inGameMenu = nil
end

local function clickLeftDown(frame)
    return SoilMapHooks.handleMouseEvent(frame, 0.5, 0.5, true, false, Input.MOUSE_BUTTON_LEFT, false)
end

-- ---- 1. the map frame is the page on screen: unchanged behaviour -------------------------
do
    local frame, o = mapFrame(), overlay()
    g_SoilFertilityManager = { soilMapOverlay = o }
    setCurrentPage(frame)
    local handled = clickLeftDown(frame)
    T.ok("a click on the displayed map page is still consumed", handled == true)
    T.eq("and the overlay saw exactly one sidebar click", o.clicks, 1)
end

-- ---- 2. another page is on screen: the leak that was reported ----------------------------
do
    local frame, o = mapFrame(), overlay()
    g_SoilFertilityManager = { soilMapOverlay = o }
    setCurrentPage({ name = "some other RF PDA page" })
    local handled = clickLeftDown(frame)
    T.ok("a click made on a different page is NOT consumed by the map frame", handled == false)
    T.eq("and the overlay is never consulted, so no help dialog can open", o.clicks, 0)
end

-- ---- 3. the menu cannot be resolved: stay permissive, never break a working build --------
do
    local frame, o = mapFrame(), overlay()
    g_SoilFertilityManager = { soilMapOverlay = o }
    g_gui, g_inGameMenu = nil, nil
    T.ok("with no g_gui at all the handler behaves exactly as before", clickLeftDown(frame) == true)

    local frame2, o2 = mapFrame(), overlay()
    g_SoilFertilityManager = { soilMapOverlay = o2 }
    g_gui = { screenControllers = { [InGameMenu] = { currentPage = nil } } }
    T.ok("a menu with no current page is undeterminable, so also permissive",
        clickLeftDown(frame2) == true)
    T.eq("and that permissive path really did reach the overlay", o2.clicks, 1)
end

-- ---- 4. the selector gate still applies on top -------------------------------------------
do
    local frame, o = mapFrame(), overlay()
    frame.mapOverviewSelector = { getState = function() return SOIL_PAGE + 1 end }
    g_SoilFertilityManager = { soilMapOverlay = o }
    setCurrentPage(frame)
    T.ok("the displayed map page on a non-Soil layer is still declined",
        clickLeftDown(frame) == false)
    T.eq("with the overlay untouched", o.clicks, 0)
end

-- ---- 5. both gates failing is still a decline, not a double negative ---------------------
do
    local frame, o = mapFrame(), overlay()
    frame.mapOverviewSelector = { getState = function() return SOIL_PAGE + 1 end }
    g_SoilFertilityManager = { soilMapOverlay = o }
    setCurrentPage({ name = "another page" })
    T.ok("off-page and off-layer together decline", clickLeftDown(frame) == false)
    T.eq("overlay untouched", o.clicks, 0)
end
