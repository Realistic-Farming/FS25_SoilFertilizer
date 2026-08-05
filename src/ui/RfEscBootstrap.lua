-- =========================================================
-- Realistic Farming Esc â€” equal shared chrome bootstrap (NO HOST)
-- =========================================================
-- Any joiner may create menuRealisticFarming if absent.
-- No Soil privilege; no rfPdaHost. Option B equal-bootstrap path.
-- =========================================================

RfEscBootstrap = {}

local PAGE_NAME = "menuRealisticFarming"
local CLASS_NAME = "RfPdaMenuPage"

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
