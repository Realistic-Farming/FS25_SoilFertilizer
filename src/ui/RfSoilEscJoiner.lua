-- =========================================================
-- RfSoilEscJoiner — Soil module for NO-HOST RF Esc door
-- =========================================================
-- Equal Option B: may create menuRealisticFarming when peers absent.
-- Registers soilFertilizer on g_currentMission.rfEscModules.
-- Stands down legacy menuSoilFertilizer Esc tab when RF door is live.
-- =========================================================

RfSoilEscJoiner = RfSoilEscJoiner or {}

local MOD_DIR = (SoilFertilizerModDirectory or g_currentModDirectory)
local PANEL_ID = "soilFertilizer"
local PANEL_ORDER = 10

local _registered = false
local _legacyStoodDown = false

local function tr(key, fallback)
    -- Gate on hasText, never on the returned string: getText never returns nil,
    -- "" or ("$l10n_" .. key), and for an absent key I18N.lua:186 returns
    -- "Missing '<key>' in l10n<suffix>.xml", which is what the old guard let
    -- through to the player. Past hasText the return is opaque: check type and
    -- non-empty, never inspect it.
    local i18n = g_i18n
    if i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
        return fallback or key
    end
    local okHas, has = pcall(i18n.hasText, i18n, key)
    if not okHas or has ~= true then return fallback or key end
    local ok, text = pcall(i18n.getText, i18n, key)
    if not ok or type(text) ~= "string" or text == "" then return fallback or key end
    return text
end

local function getRegistry()
    if RfEscModules ~= nil then
        return RfEscModules.getOrCreate()
    end
    if g_currentMission ~= nil and g_currentMission.rfEscModules ~= nil then
        return g_currentMission.rfEscModules
    end
    return nil
end

function RfSoilEscJoiner.standDownLegacyEsc()
    if _legacyStoodDown then
        return true
    end
    if g_gui == nil then
        return false
    end

    local inGameMenu = g_gui.screenControllers and g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil then
        return false
    end

    local pageName = (SoilPDAScreen and SoilPDAScreen.MENU_PAGE_NAME) or "menuSoilFertilizer"
    local screen = inGameMenu[pageName]
    if screen == nil then
        if SoilPDAScreen ~= nil and SoilPDAScreen._retainedDeepScreen ~= nil then
            _legacyStoodDown = true
            return true
        end
        return false
    end

    -- Giants-safe remove: retain the deep page before nilling it so the map
    -- sidebar can still open it. The Esc rail tab stays stood down.
    if SoilPDAScreen ~= nil then
        SoilPDAScreen._retainedDeepScreen = screen
    end

    local ok = pcall(function()
        if inGameMenu.pagingElement ~= nil then
            local pe = inGameMenu.pagingElement
            if pe.elements ~= nil then
                for i = #pe.elements, 1, -1 do
                    if pe.elements[i] == screen then
                        table.remove(pe.elements, i)
                    end
                end
            end
            if pe.pages ~= nil then
                for i = #pe.pages, 1, -1 do
                    local pg = pe.pages[i]
                    if pg ~= nil and pg.element == screen then
                        table.remove(pe.pages, i)
                    end
                end
            end
            if type(pe.updateAbsolutePosition) == "function" then
                pe:updateAbsolutePosition()
            end
            if type(pe.updatePageMapping) == "function" then
                pe:updatePageMapping()
            end
        end

        if inGameMenu.pageFrames ~= nil then
            for i = #inGameMenu.pageFrames, 1, -1 do
                if inGameMenu.pageFrames[i] == screen then
                    table.remove(inGameMenu.pageFrames, i)
                end
            end
        end

        if g_inGameMenu ~= nil and g_inGameMenu.controlIDs ~= nil then
            g_inGameMenu.controlIDs[pageName] = nil
        end

        inGameMenu[pageName] = nil

        if type(inGameMenu.rebuildTabList) == "function" then
            inGameMenu:rebuildTabList()
        end
        if type(inGameMenu.updatePages) == "function" then
            inGameMenu:updatePages()
        end
    end)

    if ok then
        _legacyStoodDown = true
        if SoilLogger ~= nil then
            SoilLogger.info("RfSoilEscJoiner: stood down legacy Esc %s", pageName)
        end
        return true
    end
    return false
end

function RfSoilEscJoiner.tryRegister()
    if g_client == nil then
        return false
    end

    -- Suite soft-detect: publish Soil panel on mission so WC/CS shell can resolve
    -- across modEnv (bare global + getfenv(0) are Soil-scoped only).
    if g_currentMission ~= nil and RfPdaSoilPanel ~= nil then
        g_currentMission.rfPdaSoilPanel = RfPdaSoilPanel
    end
    -- Same handoff for the deep tools the Esc door buttons open. g_currentMission
    -- is the only table every mod can read, so the door host (whichever mod built
    -- RfPdaMenuPage) can open these dialogs even though they live in Soil's env.
    if g_currentMission ~= nil then
        if SoilGuideDialog ~= nil then g_currentMission.rfSoilGuideDialog = SoilGuideDialog end
        if SoilHelpDialog ~= nil then g_currentMission.rfSoilHelpDialog = SoilHelpDialog end
        if SoilPDAScreen ~= nil then g_currentMission.rfSoilPDAScreen = SoilPDAScreen end
        if RotationPlannerDialog ~= nil then g_currentMission.rfRotationPlannerDialog = RotationPlannerDialog end
        if SoilFieldDetailDialog ~= nil then g_currentMission.rfSoilFieldDetailDialog = SoilFieldDetailDialog end
    end

    -- Always ensureDoor when bootstrap class is sourced; use source-time MOD_DIR only.
    if RfEscBootstrap ~= nil then
        if MOD_DIR == nil then
            if SoilLogger ~= nil then
                SoilLogger.warning("RfSoilEscJoiner: MOD_DIR nil — cannot ensureDoor (source capture failed)")
            else
                print("[SoilFertilizer] RfSoilEscJoiner: WARNING MOD_DIR nil — cannot ensureDoor")
            end
        else
            local doorOk = RfEscBootstrap.ensureDoor(MOD_DIR, {
                profilesXml = MOD_DIR .. "xml/gui/rfEscProfiles.xml",
                iconPath = "textures/ui/menuIcon.dds",
            })
            if not doorOk then
                if SoilLogger ~= nil then
                    SoilLogger.warning("RfSoilEscJoiner: ensureDoor failed (will retry)")
                else
                    print("[SoilFertilizer] RfSoilEscJoiner: WARNING ensureDoor failed (will retry)")
                end
            end
        end
    end

    local reg = getRegistry()
    if reg == nil or type(reg.registerModule) ~= "function" then
        return false
    end

    if not _registered then
        local ok = reg:registerModule({
            id = PANEL_ID,
            title = tr("rf_pda_panel_soil", "Soil Fertilizer"),
            blurb = tr("rf_pda_menu_blurb", "Field nutrients and treatment glance."),
            order = PANEL_ORDER,
            isAvailable = function()
                return true
            end,
            onShow = function(_container)
                local page = g_inGameMenu and g_inGameMenu.menuRealisticFarming
                if page ~= nil and RfPdaSoilPanel ~= nil and type(RfPdaSoilPanel.rebuildFieldData) == "function" then
                    -- Full rebuild only when page asks via refreshContent; light path is treatment refresh.
                end
            end,
            onHide = function() end,
        })
        if ok then
            _registered = true
            if type(reg.selectModule) == "function" and reg.activeModuleId == nil then
                reg:selectModule(PANEL_ID)
            end
            if SoilLogger ~= nil then
                SoilLogger.info("RfSoilEscJoiner: registered module %s on rfEscModules", PANEL_ID)
            end
        else
            return false
        end
    end

    local doorPresent = g_inGameMenu ~= nil and g_inGameMenu.menuRealisticFarming ~= nil
    if doorPresent then
        RfSoilEscJoiner.standDownLegacyEsc()
    end
    -- Ready only when module registered AND Esc door actually exists.
    return _registered and doorPresent
end

function RfSoilEscJoiner.reset()
    _registered = false
    _legacyStoodDown = false
end

-- Lifecycle: after InGameMenu exists; retry on update until door + module land.
local _pending = true

local function _onMissionLoaded()
    _pending = true
    if RfSoilEscJoiner.tryRegister() then
        _pending = false
    end
end

local function _onUpdate(_mission, _dt)
    if not _pending then
        return
    end
    if RfSoilEscJoiner.tryRegister() then
        _pending = false
    end
end

local function _onDelete()
    RfSoilEscJoiner.reset()
    _pending = true
end

Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, _onMissionLoaded)
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, _onUpdate)
FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, _onDelete)
