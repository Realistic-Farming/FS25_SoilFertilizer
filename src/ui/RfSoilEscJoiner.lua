-- =========================================================
-- RfSoilEscJoiner — Soil module for NO-HOST RF Esc door
-- =========================================================
-- Equal Option B: may create menuRealisticFarming when peers absent.
-- Registers soilFertilizer on g_currentMission.rfEscModules.
-- Stands down legacy menuSoilFertilizer Esc tab when RF door is live.
-- =========================================================

RfSoilEscJoiner = {}

local MOD_DIR = g_currentModDirectory
local MOD_NAME = g_currentModName
local PANEL_ID = "soilFertilizer"
local PANEL_ORDER = 10

local _registered = false
local _legacyStoodDown = false
local _pfHopDone = false

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
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

--- Soil already stands its SIMULATION down when Precision Farming is in the save
--- (SoilFertilityManager sets hasPrecisionFarming, settings.enabled = false and
--- _disabledByPF), but the Esc row kept answering true, so the Modules list still offered
--- a page for a mod that had switched itself off. This closes that leak.
---
--- LIVE, not a value captured at register: PF is detected during mission start, which
--- happens AFTER this joiner registers, so anything sampled at registration would read
--- false forever. Returns a real boolean because RfEscModules._moduleAvailable requires
--- == true, not merely truthy.
---
--- Same detect as the bridge and as Dairy. Four reads because they fail at different
--- moments: g_modIsLoaded is the engine's own answer, hasPrecisionFarming and pfBridge are
--- the manager's, and the settings pair catches the case where we disabled ourselves.
local function soilEscAvailable()
    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] then
        return false
    end
    local mgr = g_SoilFertilityManager
    if mgr == nil and type(getfenv) == "function" then
        local env0 = getfenv(0)
        if env0 ~= nil then mgr = env0.g_SoilFertilityManager end
    end
    if mgr ~= nil then
        if mgr.hasPrecisionFarming == true then
            return false
        end
        local bridge = mgr.pfBridge
        if bridge ~= nil and bridge.isActive == true then
            return false
        end
        if mgr._disabledByPF == true and mgr.settings ~= nil and mgr.settings.enabled == false then
            return false
        end
    end
    return true
end

--- The sticky-active hole. getModules() filters an unavailable module out of the row, but
--- getActiveModule() reads self.modules[activeModuleId] WITHOUT re-checking, so a Soil
--- that was active when PF initialised keeps painting into a row that has gone. Hop off it
--- once, then one _notify so the module list reloads exactly once: that is the existing
--- quiet path, not a timer thrash.
---
--- MUST live below getRegistry. A local function is only in scope from its own line
--- onward, so declaring this above it would bind getRegistry as a nil global and throw on
--- the first PF save.
local function pfStandDownHop()
    if _pfHopDone then
        return
    end
    if soilEscAvailable() then
        return
    end
    local reg = getRegistry()
    if reg == nil then
        return
    end
    _pfHopDone = true
    if reg.activeModuleId ~= PANEL_ID then
        return   -- nothing stuck on Soil; dropping the row is the whole stand-down
    end
    local moved = false
    if type(reg.applyHomeModuleQuiet) == "function" then
        moved = reg:applyHomeModuleQuiet() == true
    end
    if not moved and type(reg.getModules) == "function" and type(reg.selectModule) == "function" then
        local list = reg:getModules()
        if list ~= nil and list[1] ~= nil then
            moved = reg:selectModule(list[1].id) == true
        end
    end
    if not moved then
        -- Soil was the only module. nil is the honest active id; the selector draws its own
        -- "No modules" label rather than us inventing chrome for an empty door.
        reg.activeModuleId = nil
    end
    if type(reg._notify) == "function" then
        reg:_notify()
    end
    if SoilLogger ~= nil then
        SoilLogger.info("RfSoilEscJoiner: Precision Farming active - Soil Esc row stood down")
    end
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
            isAvailable = soilEscAvailable,
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
    _pfHopDone = false
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
    -- Runs before the _pending gate: PF lands after registration, so the hop stays
    -- reachable once this joiner has stopped retrying.
    pfStandDownHop()
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
