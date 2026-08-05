-- =========================================================
-- Realistic Farming Esc â€” equal shared chrome bootstrap (NO HOST)
-- =========================================================
-- Any joiner may create menuRealisticFarming if absent.
-- No Soil privilege; no rfPdaHost. Option B equal-bootstrap path.
-- =========================================================

RfEscBootstrap = {}

local PAGE_NAME = "menuRealisticFarming"
local CLASS_NAME = "RfPdaMenuPage"

-- ── Preferred host ────────────────────────────────────────
-- Equal bootstrap means whichever joiner loads first builds the door, and load
-- order is not stable. On 2026-08-05 MarketDynamics won the race and the whole
-- menu was created from its copy of the chrome, which is why the door appeared
-- to live "inside MDM".
--
-- This does NOT reintroduce a host dependency. It is a PREFERENCE, not a
-- requirement: when SoilFertilizer is installed it builds the door so the
-- chrome comes from the same place every session. When it is absent, the old
-- first-come behaviour is unchanged and any joiner still builds it alone.
--
-- Yielding is safe because a failed ensureDoor is non-fatal to the caller: the
-- joiner still registers its module on rfEscModules, and the page rebuilds from
-- that registry through addChangeListener. The yield also expires, so a
-- SoilFertilizer that is installed but never manages to build the door cannot
-- leave the suite with no menu at all.
RfEscBootstrap.PREFERRED_HOST = "FS25_SoilFertilizer"

-- Attempts a non-preferred joiner will stand aside for before building it
-- itself. In practice SoilFertilizer wins within the same load pass (all four
-- joiners registered inside 250ms on 2026-08-05), so this is only a safety net.
local YIELD_LIMIT = 240
local _yieldCount = 0
local _yieldLogged = false

local function _isPreferredHost(modDir)
    return modDir ~= nil
        and string.find(modDir, RfEscBootstrap.PREFERRED_HOST, 1, true) ~= nil
end

local function _preferredHostInstalled()
    if g_modManager == nil or type(g_modManager.getModByName) ~= "function" then
        return false
    end
    local ok, mod = pcall(g_modManager.getModByName, g_modManager, RfEscBootstrap.PREFERRED_HOST)
    return ok and mod ~= nil
end

local function _log(level, fmt, ...)
    local msg = string.format(fmt, ...)
    if SoilLogger ~= nil and type(SoilLogger[level]) == "function" then
        SoilLogger[level]("%s", msg)
    elseif Logging ~= nil and type(Logging[level]) == "function" then
        Logging[level]("[RfEscBootstrap] " .. msg)
    else
        print("[RfEscBootstrap] " .. msg)
    end
end

--- Inject frame into InGameMenu (WC/Soil port of addIngameMenuPage).
local function addIngameMenuPage(frame, pageName, iconPath, uvs, position, predicateFunc, modDir)
    local targetPosition = 0
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil then
        _log("warning", "InGameMenu not found")
        return false
    end
    if inGameMenu.pagingElement == nil
            or inGameMenu.pagingElement.elements == nil
            or inGameMenu.pagingElement.pages == nil
            or inGameMenu.pageFrames == nil then
        _log("warning", "InGameMenu not fully initialized")
        return false
    end

    if g_inGameMenu ~= nil and g_inGameMenu.controlIDs ~= nil then
        g_inGameMenu.controlIDs[pageName] = nil
    end

    if type(position) == "string" then
        for i = 1, #g_inGameMenu.pagingElement.elements do
            local child = g_inGameMenu.pagingElement.elements[i]
            if child == g_inGameMenu[position] then
                targetPosition = i + 1
                break
            end
        end
    elseif type(position) == "number" then
        targetPosition = position
    else
        targetPosition = 1
    end

    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(inGameMenu[pageName])
    inGameMenu:exposeControlsAsFields(pageName)

    if position ~= nil then
        for i = #inGameMenu.pagingElement.elements, 1, -1 do
            local child = inGameMenu.pagingElement.elements[i]
            if child == inGameMenu[pageName] then
                table.remove(inGameMenu.pagingElement.elements, i)
                table.insert(inGameMenu.pagingElement.elements, targetPosition, child)
                break
            end
        end
        for i = #inGameMenu.pagingElement.pages, 1, -1 do
            local child = inGameMenu.pagingElement.pages[i]
            if child.element == inGameMenu[pageName] then
                table.remove(inGameMenu.pagingElement.pages, i)
                table.insert(inGameMenu.pagingElement.pages, targetPosition, child)
                break
            end
        end
    end

    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()
    inGameMenu:registerPage(inGameMenu[pageName], nil, predicateFunc)

    local iconFileName = Utils.getFilename(iconPath, modDir)
    inGameMenu:addPageTab(inGameMenu[pageName], iconFileName, GuiUtils.getUVs(uvs))

    if position ~= nil then
        for i = 1, #g_inGameMenu.pageFrames do
            local child = inGameMenu.pageFrames[i]
            if child == inGameMenu[pageName] then
                table.remove(inGameMenu.pageFrames, i)
                table.insert(inGameMenu.pageFrames, targetPosition, child)
                break
            end
        end
    end

    inGameMenu:rebuildTabList()
    local page = inGameMenu[pageName]
    if page ~= nil and page.setVisible ~= nil then
        pcall(page.setVisible, page, false)
    end
    return true
end

--- Ensure shared Esc door exists. Idempotent: skip create if already present.
---@param modDir string g_currentModDirectory of the calling joiner
---@param opts table|nil { profilesXml?, iconPath?, uvs? }
---@return boolean true if door exists after call
function RfEscBootstrap.ensureDoor(modDir, opts)
    if g_client == nil or g_gui == nil or g_inGameMenu == nil or modDir == nil then
        return false
    end
    opts = opts or {}

    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil
            or inGameMenu.pagingElement == nil
            or inGameMenu.pagingElement.elements == nil then
        return false
    end

    if g_inGameMenu[PAGE_NAME] ~= nil then
        return true
    end

    -- Stand aside for the preferred host while it still has a chance to build.
    if not _isPreferredHost(modDir) and _preferredHostInstalled() then
        _yieldCount = _yieldCount + 1
        if _yieldCount <= YIELD_LIMIT then
            if not _yieldLogged then
                _yieldLogged = true
                _log("info", "yielding door creation to %s (preferred host)", RfEscBootstrap.PREFERRED_HOST)
            end
            return false
        end
        if _yieldCount == YIELD_LIMIT + 1 then
            _log("warning", "%s is installed but did not create the door after %d attempts; building it here instead",
                RfEscBootstrap.PREFERRED_HOST, YIELD_LIMIT)
        end
    end

    if RfPdaMenuPage == nil then
        _log("warning", "RfPdaMenuPage class missing; cannot bootstrap Esc door")
        return false
    end

    local profilesXml = opts.profilesXml or (modDir .. "xml/gui/rfEscProfiles.xml")
    if profilesXml ~= nil then
        pcall(function()
            g_gui:loadProfiles(profilesXml)
        end)
    end

    local pageController = RfPdaMenuPage.new()
    local xmlFile = RfPdaMenuPage.getXmlFilename and RfPdaMenuPage.getXmlFilename()
        or (modDir .. "xml/gui/" .. CLASS_NAME .. ".xml")
    _log("info", "creating Esc door from %s", tostring(xmlFile))
    g_gui:loadGui(xmlFile, CLASS_NAME, pageController, true)

    local iconPath = opts.iconPath or RfPdaMenuPage.MENU_ICON_PATH or "textures/ui/menuIcon.dds"
    local uvs = opts.uvs or { 0, 0, 1024, 1024 }
    local ok = addIngameMenuPage(
        pageController,
        PAGE_NAME,
        iconPath,
        uvs,
        "pageSettings",
        function() return true end,
        modDir
    )
    if not ok then
        _log("error", "addIngameMenuPage failed for %s", PAGE_NAME)
        return false
    end
    if pageController.initialize ~= nil then
        pageController:initialize()
    end
    _log("info", "Esc door ready (%s)", PAGE_NAME)
    return g_inGameMenu[PAGE_NAME] ~= nil
end

function RfEscBootstrap.getPageName()
    return PAGE_NAME
end
