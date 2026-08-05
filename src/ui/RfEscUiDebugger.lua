-- =========================================================
-- Realistic Farming Esc — UIDebugger hot-reload (DEV ONLY)
-- =========================================================
-- Ash GO 2026-08-02: temporary tooling. Not player product path.
-- Hotkey: F6 (F5 taken by EasyDevControls debug + Market Dynamics MDM).
-- Hang fence: close InGameMenu before frame delete / loadGui.
-- CRITICAL 2026-08-02: Giants createFromExistingGui pattern —
-- delete whole frame controller + root, loadGui into a NEW controller,
-- then in-place swap InGameMenu page/tab slots (never duplicate seedling).
-- Does NOT re-run RfEscBootstrap.ensureDoor / module soft-register.
-- Vera F1 alone/combine still needs full client restart.
-- Singleton: only one mod installs (prefer Soil; else first).
-- =========================================================

RfEscUiDebugger = {}

local PAGE_NAME = "menuRealisticFarming"
local CLASS_NAME = "RfPdaMenuPage"
local SOIL_MOD_NAME = "FS25_SoilFertilizer"
local COOLDOWN_MS = 1000
local _cooldownUntil = 0
local _listenerInstalled = false

local function _log(level, fmt, ...)
    local msg = string.format(fmt, ...)
    if Logging ~= nil and type(Logging[level]) == "function" then
        Logging[level]("[RfEscUiDebugger] " .. msg)
    else
        print("[RfEscUiDebugger] " .. msg)
    end
end

local function _normDir(path)
    if path == nil or path == "" then
        return nil
    end
    local p = tostring(path):gsub("\\", "/"):gsub("/+$", "")
    return (p .. "/"):lower()
end

--- True global / mission flag (getfenv(0) is per-mod sandbox — broken for singleton).
local function _isInstalledGlobally()
    if _G ~= nil and _G.g_rfEscUiDebuggerInstalled == true then
        return true
    end
    if g_currentMission ~= nil and g_currentMission.rfEscUiDebuggerInstalled == true then
        return true
    end
    return false
end

local function _markInstalledGlobally()
    if _G ~= nil then
        _G.g_rfEscUiDebuggerInstalled = true
    end
    if g_currentMission ~= nil then
        g_currentMission.rfEscUiDebuggerInstalled = true
    end
end

local function _getSoilModDirectory()
    if g_modNameToDirectory ~= nil then
        local d = g_modNameToDirectory[SOIL_MOD_NAME]
        if d ~= nil and d ~= "" then
            return d
        end
    end
    if g_currentModName == SOIL_MOD_NAME and g_currentModDirectory ~= nil then
        return g_currentModDirectory
    end
    if g_modManager ~= nil and type(g_modManager.getModByName) == "function" then
        local ok, mod = pcall(function()
            return g_modManager:getModByName(SOIL_MOD_NAME)
        end)
        if ok and mod ~= nil and (mod.modDir ~= nil or mod.modDirectory ~= nil) then
            return mod.modDir or mod.modDirectory
        end
    end
    return nil
end

local function _getMenu()
    if g_gui ~= nil and g_gui.screenControllers ~= nil and InGameMenu ~= nil then
        return g_gui.screenControllers[InGameMenu] or g_inGameMenu
    end
    return g_inGameMenu
end

local function _getPage()
    local menu = _getMenu()
    if menu == nil then
        return nil
    end
    return menu[PAGE_NAME] or menu.menuRealisticFarming
end

--- Prefer Soil shared page XML when Soil is present (one path, not three mod dirs).
local function _getXmlPath()
    local soilDir = _getSoilModDirectory()
    if soilDir ~= nil then
        return soilDir .. "xml/gui/" .. CLASS_NAME .. ".xml"
    end
    if RfPdaMenuPage ~= nil and type(RfPdaMenuPage.getXmlFilename) == "function" then
        return RfPdaMenuPage.getXmlFilename()
    end
    if g_currentModDirectory ~= nil then
        return g_currentModDirectory .. "xml/gui/" .. CLASS_NAME .. ".xml"
    end
    return nil
end

--- Greenfield SoT is rfEscProfiles.xml; legacy guiProfiles.xml only if present.
local function _profilesCandidate(dir)
    if dir == nil or dir == "" then
        return nil
    end
    local preferred = dir .. "xml/gui/rfEscProfiles.xml"
    local legacy = dir .. "xml/gui/guiProfiles.xml"
    if fileExists ~= nil then
        if fileExists(preferred) then
            return preferred
        end
        if fileExists(legacy) then
            return legacy
        end
        return nil
    end
    return preferred
end

local function _getProfilesXml()
    local fromSoil = _profilesCandidate(_getSoilModDirectory())
    if fromSoil ~= nil then
        return fromSoil
    end
    return _profilesCandidate(g_currentModDirectory)
end

local function _captureActiveModuleId()
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules.activeModuleId
    end
    local env = getfenv and getfenv(0) or nil
    if env ~= nil and env.g_rfEscModules ~= nil then
        return env.g_rfEscModules.activeModuleId
    end
    return nil
end

local function _restoreActiveModuleId(moduleId)
    if moduleId == nil or moduleId == "" then
        return
    end
    local reg = nil
    if g_currentMission ~= nil then
        reg = g_currentMission.rfEscModules
    end
    if reg == nil then
        local env = getfenv and getfenv(0) or nil
        if env ~= nil then
            reg = env.g_rfEscModules
        end
    end
    if reg == nil then
        return
    end
    if type(reg.selectModule) == "function" then
        pcall(function()
            reg:selectModule(moduleId)
        end)
    elseif type(reg.selectPanel) == "function" then
        pcall(function()
            reg:selectPanel(moduleId)
        end)
    else
        reg.activeModuleId = moduleId
    end
end

--- Find slot indices for oldPage. Prefer in-place replace (keeps Esc tab).
local function _findPageSlots(menu, oldPage)
    local slots = {
        elementsIdx = nil,
        pagesIdx = nil,
        framesIdx = nil,
        pageTitle = "",
        pageIdName = nil,
        pageDisabled = false,
    }
    if menu == nil or oldPage == nil then
        return slots
    end

    local pe = menu.pagingElement
    if pe ~= nil and type(pe.elements) == "table" then
        for i = 1, #pe.elements do
            if pe.elements[i] == oldPage then
                slots.elementsIdx = i
                break
            end
        end
    end
    if pe ~= nil and type(pe.pages) == "table" then
        for i = 1, #pe.pages do
            local page = pe.pages[i]
            if page ~= nil and page.element == oldPage then
                slots.pagesIdx = i
                slots.pageTitle = page.title or ""
                slots.pageIdName = page.idName
                slots.pageDisabled = page.disabled == true
                break
            end
        end
    end
    if type(menu.pageFrames) == "table" then
        for i = 1, #menu.pageFrames do
            if menu.pageFrames[i] == oldPage then
                slots.framesIdx = i
                break
            end
        end
    end
    return slots
end

--- Detach old controller from paging WITHOUT PagingElement:removeElement
--- (that path also removePageByElement and would drop the Esc tab slot).
local function _orphanFromPaging(menu, oldPage, slots)
    if menu == nil or oldPage == nil then
        return
    end
    local pe = menu.pagingElement
    if pe ~= nil and type(pe.elements) == "table" and slots.elementsIdx ~= nil then
        if pe.elements[slots.elementsIdx] == oldPage then
            table.remove(pe.elements, slots.elementsIdx)
        else
            for i = #pe.elements, 1, -1 do
                if pe.elements[i] == oldPage then
                    table.remove(pe.elements, i)
                    break
                end
            end
        end
    end
    -- Prevent GuiElement:delete → parent:removeElement → removePageByElement.
    oldPage.parent = nil
end

--- Resolve g_gui.frames root for the RF page (name may be CLASS_NAME after loadGui).
local function _resolveFrameRoot(oldPage)
    if g_gui == nil or type(g_gui.frames) ~= "table" then
        return nil, nil
    end
    local keys = {}
    if oldPage ~= nil and oldPage.name ~= nil then
        keys[#keys + 1] = oldPage.name
    end
    keys[#keys + 1] = CLASS_NAME
    keys[#keys + 1] = "RfPdaMenuPage"
    for i = 1, #keys do
        local root = g_gui.frames[keys[i]]
        if root ~= nil then
            return root, keys[i]
        end
    end
    return nil, nil
end

--- Giants InGameMenuAnimalsFrame.createFromExistingGui delete half (pcall-safe).
local function _deleteOldFrameGiantsWay(oldPage)
    local frameRoot, frameKey = _resolveFrameRoot(oldPage)
    local deletedTarget = false
    local deletedRoot = false

    if frameRoot ~= nil then
        if frameRoot.target ~= nil and type(frameRoot.target.delete) == "function" then
            local ok = pcall(function()
                frameRoot.target:delete()
            end)
            deletedTarget = ok
        end
        if type(frameRoot.delete) == "function" then
            local ok = pcall(function()
                frameRoot:delete()
            end)
            deletedRoot = ok
        end
        if frameKey ~= nil then
            g_gui.frames[frameKey] = nil
        end
        g_gui.frames[CLASS_NAME] = nil
        g_gui.frames["RfPdaMenuPage"] = nil
    end

    -- If frames lookup missed, still delete the old controller (orphaned).
    if not deletedTarget and oldPage ~= nil and type(oldPage.delete) == "function" then
        pcall(function()
            oldPage.parent = nil
            oldPage:delete()
        end)
        deletedTarget = true
    end

    -- Belt: any leftover children on a surviving oldPage.
    if oldPage ~= nil and type(oldPage.elements) == "table" and #oldPage.elements > 0 then
        local children = {}
        for i = 1, #oldPage.elements do
            children[#children + 1] = oldPage.elements[i]
        end
        for i = 1, #children do
            local child = children[i]
            if child ~= nil and type(child.delete) == "function" then
                pcall(function()
                    child:delete()
                end)
            end
        end
    end

    return deletedTarget or deletedRoot
end

--- Wire newPage into the same paging / pageFrames / pageTabs slots as oldPage.
local function _inplaceSwapPage(menu, oldPage, newPage, slots, savedTab, savedPredicate)
    if menu == nil or newPage == nil then
        return false
    end

    local pe = menu.pagingElement
    local elementsIdx = slots.elementsIdx
    local pagesIdx = slots.pagesIdx
    local framesIdx = slots.framesIdx

    -- Manual parent insert — do NOT pe:addElement (that appends a second page).
    if pe ~= nil and type(pe.elements) == "table" then
        local idx = elementsIdx or (#pe.elements + 1)
        if idx < 1 then
            idx = 1
        end
        if idx > #pe.elements + 1 then
            idx = #pe.elements + 1
        end
        table.insert(pe.elements, idx, newPage)
        newPage.parent = pe
        elementsIdx = idx
    end

    if pe ~= nil and type(pe.pages) == "table" and pagesIdx ~= nil and pe.pages[pagesIdx] ~= nil then
        pe.pages[pagesIdx].element = newPage
        if slots.pageTitle ~= nil then
            pe.pages[pagesIdx].title = slots.pageTitle
        end
        if slots.pageDisabled ~= nil then
            pe.pages[pagesIdx].disabled = slots.pageDisabled
        end
    elseif pe ~= nil and type(pe.pages) == "table" then
        -- Slot lost somehow: append page entry (last resort; tab already preserved).
        local page = {
            id = (pe.getNextID ~= nil and pe:getNextID()) or (#pe.pages + 1),
            mappingIndex = 0,
            idName = slots.pageIdName or tostring(newPage),
            element = newPage,
            title = slots.pageTitle or "",
            disabled = slots.pageDisabled == true,
        }
        table.insert(pe.pages, page)
        if pe.idPageHash ~= nil then
            pe.idPageHash[page.id] = page
        end
        pagesIdx = #pe.pages
    end

    if type(menu.pageFrames) == "table" then
        if framesIdx ~= nil then
            menu.pageFrames[framesIdx] = newPage
        else
            table.insert(menu.pageFrames, newPage)
            framesIdx = #menu.pageFrames
        end
    end

    -- pageTabs / roots / predicates / typeControllers are keyed by controller ref.
    if type(menu.pageTabs) == "table" then
        if oldPage ~= nil then
            menu.pageTabs[oldPage] = nil
        end
        if savedTab ~= nil then
            local tab = savedTab
            function tab.onClickCallback()
                if type(menu.onPageClicked) == "function" then
                    menu:onPageClicked(menu.activeDetailPage)
                end
                if pe ~= nil and type(pe.getPageIdByElement) == "function" and type(pe.getPageMappingIndex) == "function" then
                    local pageId = pe:getPageIdByElement(newPage)
                    if pageId ~= nil then
                        local pageMappingIndex = pe:getPageMappingIndex(pageId)
                        if menu.currentPage ~= nil and type(menu.currentPage.requestClose) == "function" then
                            if menu.currentPage:requestClose(tab.onClickCallback) then
                                if menu.pageSelector ~= nil and type(menu.pageSelector.setState) == "function" then
                                    menu.pageSelector:setState(pageMappingIndex, true)
                                end
                            end
                        elseif menu.pageSelector ~= nil and type(menu.pageSelector.setState) == "function" then
                            menu.pageSelector:setState(pageMappingIndex, true)
                        end
                    end
                end
            end
            menu.pageTabs[newPage] = tab
        end
    end

    if type(menu.pageRoots) == "table" then
        if oldPage ~= nil then
            menu.pageRoots[oldPage] = nil
        end
        menu.pageRoots[newPage] = (newPage.elements ~= nil and newPage.elements[1]) or nil
    end

    if type(menu.pageEnablingPredicates) == "table" then
        if oldPage ~= nil then
            menu.pageEnablingPredicates[oldPage] = nil
        end
        menu.pageEnablingPredicates[newPage] = savedPredicate or function()
            return true
        end
    end

    if type(menu.pageTypeControllers) == "table" and type(newPage.class) == "function" then
        menu.pageTypeControllers[newPage:class()] = newPage
    end

    if type(menu.disabledPages) == "table" and oldPage ~= nil then
        local wasDisabled = menu.disabledPages[oldPage]
        menu.disabledPages[oldPage] = nil
        if wasDisabled ~= nil then
            menu.disabledPages[newPage] = wasDisabled
        end
    end

    if menu.currentPage == oldPage then
        menu.currentPage = newPage
    end

    menu[PAGE_NAME] = newPage
    if g_inGameMenu ~= nil then
        g_inGameMenu[PAGE_NAME] = newPage
        if type(g_inGameMenu.controlIDs) == "table" then
            g_inGameMenu.controlIDs[PAGE_NAME] = nil
        end
    end

    if type(menu.exposeControlsAsFields) == "function" then
        pcall(function()
            menu:exposeControlsAsFields(PAGE_NAME)
        end)
    end
    if pe ~= nil and type(pe.updateAbsolutePosition) == "function" then
        pcall(function()
            pe:updateAbsolutePosition()
        end)
    end
    if pe ~= nil and type(pe.updatePageMapping) == "function" then
        pcall(function()
            pe:updatePageMapping()
        end)
    end

    -- enabledPages / tab list hold old controller refs — rebuild after swap only.
    if type(menu.rebuildTabList) == "function" then
        pcall(function()
            menu:rebuildTabList()
        end)
    end

    return elementsIdx ~= nil or pagesIdx ~= nil or framesIdx ~= nil
end

--- Reload RF Esc page: new controller + Giants frame delete + in-place slot swap.
--- Hang fence first when InGameMenu is open. Honesty: no ensureDoor re-run.
---@return boolean
function RfEscUiDebugger.reloadRfEscPage()
    if g_client == nil or g_gui == nil then
        _log("warning", "reload skipped: no client/gui")
        return false
    end

    local menu = _getMenu()
    local oldPage = _getPage()
    if oldPage == nil then
        _log("warning", "reload skipped: %s not registered (full restart / ensureDoor needed)", PAGE_NAME)
        return false
    end

    local xmlPath = _getXmlPath()
    if xmlPath == nil then
        _log("warning", "reload skipped: XML path unknown")
        return false
    end
    if oldPage.xmlFilename == nil then
        oldPage.xmlFilename = xmlPath
    end

    local wasInGameMenu = (g_gui.currentGuiName == "InGameMenu")
    -- Hang fence: never delete while InGameMenu/SmoothList may be drawing.
    if wasInGameMenu then
        pcall(function()
            g_gui:showGui("")
        end)
    end

    local activeModuleId = _captureActiveModuleId()
    local slots = _findPageSlots(menu, oldPage)
    local savedTab = nil
    local savedPredicate = nil
    if menu ~= nil then
        if type(menu.pageTabs) == "table" then
            savedTab = menu.pageTabs[oldPage]
        end
        if type(menu.pageEnablingPredicates) == "table" then
            savedPredicate = menu.pageEnablingPredicates[oldPage]
        end
    end

    -- Orphan before delete so PagingElement:removeElement cannot drop the page slot.
    _orphanFromPaging(menu, oldPage, slots)
    if menu ~= nil then
        if type(menu.pageTabs) == "table" then
            menu.pageTabs[oldPage] = nil
        end
        if type(menu.pageRoots) == "table" then
            menu.pageRoots[oldPage] = nil
        end
        if type(menu.pageEnablingPredicates) == "table" then
            menu.pageEnablingPredicates[oldPage] = nil
        end
    end

    local newPage = nil
    local prevReloading = g_gui.currentlyReloading
    g_gui.currentlyReloading = true

    local ok = false
    local err = nil
    local okLoad, loadErr = pcall(function()
        local profilesXml = _getProfilesXml()
        if profilesXml ~= nil then
            local okProf, errProf = pcall(function()
                g_gui:loadProfiles(profilesXml)
            end)
            if okProf then
                _log("info", "loadProfiles %s", tostring(profilesXml))
            else
                _log("warning", "loadProfiles failed (%s): %s", tostring(profilesXml), tostring(errProf))
            end
        else
            _log("warning", "loadProfiles skipped: no rfEscProfiles.xml / guiProfiles.xml")
        end

        -- Prefer class helper (Animals mirror); fallback inline Giants delete+loadGui.
        if RfPdaMenuPage ~= nil and type(RfPdaMenuPage.createFromExistingGui) == "function" then
            newPage = RfPdaMenuPage.createFromExistingGui(oldPage, CLASS_NAME)
        else
            _deleteOldFrameGiantsWay(oldPage)
            newPage = RfPdaMenuPage.new()
            -- Never leave PAGE_NAME nil during load.
            if menu ~= nil then
                menu[PAGE_NAME] = newPage
            end
            if g_inGameMenu ~= nil then
                g_inGameMenu[PAGE_NAME] = newPage
            end
            g_gui:loadGui(xmlPath, CLASS_NAME, newPage, true)
        end
    end)
    ok = okLoad
    err = loadErr

    g_gui.currentlyReloading = prevReloading == true

    if not ok or newPage == nil then
        _log("error", "frame-replace reload FAILED: %s", tostring(err or "newPage nil"))
        -- Last-ditch: keep a live controller under PAGE_NAME if possible.
        if _getPage() == nil and menu ~= nil then
            local emergency = RfPdaMenuPage ~= nil and RfPdaMenuPage.new() or nil
            if emergency ~= nil then
                menu[PAGE_NAME] = emergency
                if g_inGameMenu ~= nil then
                    g_inGameMenu[PAGE_NAME] = emergency
                end
            end
        end
        if wasInGameMenu then
            pcall(function()
                g_gui:showGui("InGameMenu")
            end)
        end
        return false
    end

    _log("info", "tore down old frame; loaded new controller")

    local swapped = _inplaceSwapPage(menu, oldPage, newPage, slots, savedTab, savedPredicate)
    if not swapped then
        _log("warning", "slot swap incomplete (elements/pages/pageFrames miss); PAGE_NAME still set")
    end

    if type(newPage.initialize) == "function" then
        pcall(function()
            newPage:initialize()
        end)
    end
    if type(newPage.updateAbsolutePosition) == "function" then
        pcall(function()
            newPage:updateAbsolutePosition()
        end)
    end

    _restoreActiveModuleId(activeModuleId)

    local function refreshAfterReload()
        if type(newPage.refreshPanelSelector) == "function" then
            pcall(function()
                newPage:refreshPanelSelector(true)
            end)
        end
        if type(newPage.refreshContent) == "function" then
            pcall(function()
                newPage:refreshContent(true)
            end)
        end
        if type(newPage._ensureSelectorArrowsVisible) == "function" then
            pcall(function()
                newPage:_ensureSelectorArrowsVisible()
            end)
        elseif type(newPage._ensureMtoArrowsVisible) == "function" then
            pcall(function()
                newPage:_ensureMtoArrowsVisible(newPage.rfPanelSelector)
            end)
        end
    end

    if wasInGameMenu then
        pcall(function()
            g_gui:showGui("InGameMenu")
        end)
        if menu ~= nil and type(menu.goToPage) == "function" then
            pcall(function()
                menu:goToPage(newPage, true)
            end)
        end
        if type(newPage.onFrameOpen) == "function" then
            pcall(function()
                newPage:onFrameOpen()
            end)
        else
            refreshAfterReload()
        end
    else
        refreshAfterReload()
    end

    _log("info", "frame-replace reload OK (%s from %s; slots e=%s p=%s f=%s; module=%s)",
        CLASS_NAME,
        tostring(xmlPath),
        tostring(slots.elementsIdx),
        tostring(slots.pagesIdx),
        tostring(slots.framesIdx),
        tostring(activeModuleId))
    return true
end

function RfEscUiDebugger.consoleReload()
    RfEscUiDebugger.reloadRfEscPage()
end

local function _onUpdate(_self, dt)
    if g_client == nil then
        return
    end
    _cooldownUntil = math.max(0, _cooldownUntil - (dt or 0))
    if _cooldownUntil > 0 then
        return
    end
    if Input == nil or Input.KEY_f6 == nil or Input.isKeyPressed == nil then
        return
    end
    if not Input.isKeyPressed(Input.KEY_f6) then
        return
    end
    -- Dev gate: only when RF Esc door already exists (not a player discovery path).
    if _getPage() == nil then
        return
    end
    _cooldownUntil = COOLDOWN_MS
    RfEscUiDebugger.reloadRfEscPage()
end

function RfEscUiDebugger.install()
    if g_client == nil then
        return
    end
    -- Cross-mod singleton via true _G / mission (not getfenv sandbox).
    if _listenerInstalled or _isInstalledGlobally() then
        return
    end

    -- Prefer Soil when present so non-Soil mods hard no-op even if they source first.
    local soilDir = _getSoilModDirectory()
    local myDir = g_currentModDirectory
    if soilDir ~= nil and myDir ~= nil and _normDir(soilDir) ~= _normDir(myDir) then
        return
    end

    local listener = { update = _onUpdate }
    addModEventListener(listener)
    if addConsoleCommand ~= nil then
        addConsoleCommand("rfEscReloadGui", "Dev: frame-replace reload menuRealisticFarming (hang-fenced; F6)", "consoleReload", RfEscUiDebugger)
    end
    _listenerInstalled = true
    _markInstalledGlobally()
    local owner = (g_currentModName ~= nil and g_currentModName) or "unknown"
    _log("info", "installed by %s (F6 / rfEscReloadGui). Dev-only; frame-replace path; not Vera F1 substitute.", tostring(owner))
end

-- Install when mission finishes (InGameMenu may not exist at source time).
if Mission00 ~= nil and Utils ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
        RfEscUiDebugger.install()
    end)
end
-- Also try immediately if already past load (late source / console).
if g_client ~= nil and g_currentMission ~= nil then
    RfEscUiDebugger.install()
end
