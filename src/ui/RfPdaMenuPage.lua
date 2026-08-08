-- =========================================================
-- FS25 Soil & Fertilizer - RfPdaMenuPage (Esc RF shell)
-- =========================================================
-- Phase 1 + F8 + F9 + F10 layout (2026-07-29): RF_PageRoot stretch-fills paging
-- (not uiInGameMenuFrame 1400x756 mid-band); side 520/548; no page header;
-- no farm money (Q3 = B). Soil table + TREATMENT PLAN in RfPdaSoilPanel.
-- Frame debug: SoilRfPdaFrameDebug console toggle (GuiElement.debugEnabled
-- outlines + short labels; engine also has gsGuiDebug for global UI debug).
-- Keep: WC inject identity (menuSoilFertilizer), RfPdaHost cycle,
-- Map lime arrows/dots, GuiElement SmoothList parents, quiet reloads,
-- blank.png swatches #2A2D28 / #222222, no ownership legend.
-- Do not: FarmTablet, Phase B Map inject, nil-filename Bitmap bars.
-- SoilPDAScreen coexists untouched.
-- =========================================================

local MOD_DIR = g_currentModDirectory
local MOD_NAME = g_currentModName

-- Soft log when sourced from WC/CS joiners (SoilLogger may be absent).
if SoilLogger == nil then
    SoilLogger = {
        info = function(_, fmt, ...)
            if Logging and Logging.info then Logging.info("[RfEsc] " .. string.format(fmt or "", ...)) end
        end,
        warning = function(_, fmt, ...)
            if Logging and Logging.warning then Logging.warning("[RfEsc] " .. string.format(fmt or "", ...)) end
        end,
        error = function(_, fmt, ...)
            if Logging and Logging.error then Logging.error("[RfEsc] " .. string.format(fmt or "", ...)) end
        end,
    }
end

---@class RfPdaMenuPage
RfPdaMenuPage = {}
RfPdaMenuPage.CLASS_NAME = "RfPdaMenuPage"
-- NO-HOST: shared Esc door name (not Soil-owned menuSoilFertilizer).
RfPdaMenuPage.MENU_PAGE_NAME = "menuRealisticFarming"
RfPdaMenuPage.MENU_ICON_PATH = "textures/ui/menuIcon.dds"

function RfPdaMenuPage.getXmlFilename()
    return MOD_DIR .. "xml/gui/RfPdaMenuPage.xml"
end

local RfPdaMenuPage_mt = Class(RfPdaMenuPage, TabbedMenuFrameElement)

local REFRESH_INTERVAL = 2000
-- Worker Costs Dashboard/Workers: George GREEN-LIGHT 500ms text-only refreshLive.
local WC_LIVE_REFRESH_INTERVAL = 500
-- Modules dual-fire FAIL-FIX: ignore duplicate panel id selects within this window.
local MODULE_SELECT_DEBOUNCE_MS = 120

-- Module-list selection colors (Soil row colors live in RfPdaSoilPanel)
local COLOR_DIM  = {1.00, 1.00, 1.00, 0.55}
local COLOR_LIME_BRIGHT = {0.659, 0.878, 0.290, 1.0}

local PANEL_BLURBS = {
    soilFertilizer = "rf_pda_menu_blurb",
}

--- Cross-mod Soil panel resolve: bare RfPdaSoilPanel is nil when WC/CS sourced
--- RfPdaMenuPage last (their env). getfenv(0) is also per-mod; probe Soil
--- g_modEnvironments + mission soft-detect (suite pattern).
local _soilPanelResolveLogged = false

local function soilPanelHasRebuild(panel)
    return panel ~= nil and type(panel.rebuildFieldData) == "function"
end

local function soilPanelLogResolve(via)
    if _soilPanelResolveLogged then
        return
    end
    _soilPanelResolveLogged = true
    local msg = string.format("[RfEsc] RfPdaSoilPanel resolved via %s", via)
    if Logging ~= nil and type(Logging.info) == "function" then
        Logging.info("%s", msg)
    else
        print(msg)
    end
end

local function soilPanel()
    if soilPanelHasRebuild(RfPdaSoilPanel) then
        return RfPdaSoilPanel
    end

    if type(getfenv) == "function" then
        local env0 = getfenv(0)
        if soilPanelHasRebuild(env0 and env0.RfPdaSoilPanel) then
            return env0.RfPdaSoilPanel
        end
    end

    if g_modEnvironments ~= nil then
        for _, modName in ipairs({ "FS25_SoilFertilizer", "FS25_SoilFertilizer_Refined" }) do
            local modEnv = g_modEnvironments[modName]
            local panel = modEnv and modEnv.RfPdaSoilPanel
            if soilPanelHasRebuild(panel) then
                soilPanelLogResolve("g_modEnvironments[" .. modName .. "]")
                return panel
            end
        end
    end

    if g_currentMission ~= nil and soilPanelHasRebuild(g_currentMission.rfPdaSoilPanel) then
        soilPanelLogResolve("g_currentMission.rfPdaSoilPanel")
        return g_currentMission.rfPdaSoilPanel
    end

    return nil
end

--- Resolve any Soil-exposed class cross-mod. The door is created by whichever
--- mod's RfPdaMenuPage loads first, so Soil globals (dialogs, PDAScreen) are nil
--- when a non-Soil mod built the door (FS25 envs are per-mod). Soil publishes its
--- deep tools on g_currentMission at registration, so read those first, then
--- g_modEnvironments, then getfenv(0), matching soilPanel() above.
local function soilGlobal(name)
    local missionHandles = {
        SoilGuideDialog       = "rfSoilGuideDialog",
        SoilHelpDialog        = "rfSoilHelpDialog",
        SoilPDAScreen         = "rfSoilPDAScreen",
        RotationPlannerDialog = "rfRotationPlannerDialog",
        SoilFieldDetailDialog = "rfSoilFieldDetailDialog",
    }
    local key = missionHandles[name]
    if g_currentMission ~= nil and key ~= nil then
        local v = g_currentMission[key]
        if v ~= nil then
            return v
        end
    end
    local env0 = getfenv and getfenv(0)
    if env0 and env0[name] ~= nil then
        return env0[name]
    end
    if _G and _G[name] ~= nil then
        return _G[name]
    end
    if g_modEnvironments ~= nil then
        for _, modName in ipairs({ "FS25_SoilFertilizer", "FS25_SoilFertilizer_Refined" }) do
            local modEnv = g_modEnvironments[modName]
            local v = modEnv and modEnv[name]
            if v ~= nil then
                return v
            end
        end
    end
    return nil
end

--- Cross-mod Soil help dialog resolve. The door is created by whichever mod's
--- RfPdaMenuPage loads first, so a bare SoilGuideDialog/SoilHelpDialog global
--- is nil when a non-Soil mod built the door (FS25 envs are per-mod). Delegate
--- to soilGlobal, which reads the g_currentMission handoff first.
local function soilGuideDialog()
    local dlg = soilGlobal("SoilGuideDialog")
    if dlg ~= nil and type(dlg.show) == "function" then
        return dlg
    end
    local dlgHelp = soilGlobal("SoilHelpDialog")
    if dlgHelp ~= nil and type(dlgHelp.show) == "function" then
        return dlgHelp
    end
    return nil
end

--- Resolve l10n with English fallback. When CS/WC create the Esc door, MOD_NAME
--- i18n may lack Soil table keys - also probe Soil modEnv, then g_i18n.
local function tr(key, fallback)
    local function tryI18n(i18n)
        if i18n == nil then
            return nil
        end
        local ok, text = pcall(function() return i18n:getText(key) end)
        if not ok or type(text) ~= "string" or text == "" then
            return nil
        end
        local lower = text:lower()
        -- Reject unresolved keys (engine often returns "MISSING KEY_NAME").
        if lower == tostring(key):lower()
            or text == ("$l10n_" .. key)
            or lower:find("^missing%s")
            or lower:find("^missing_")
        then
            return nil
        end
        return text
    end

    local tried = {}
    local function tryMod(name)
        if name == nil or tried[name] or g_modEnvironments == nil then
            return nil
        end
        tried[name] = true
        local modEnv = g_modEnvironments[name]
        return tryI18n(modEnv and modEnv.i18n)
    end

    local text = tryMod(MOD_NAME)
        or tryMod("FS25_SoilFertilizer")
        or tryMod("FS25_SoilFertilizer_Refined")
        or tryI18n(g_i18n)
    if text ~= nil then
        return text
    end
    return fallback or key
end

--- Guest modules bake title at register; never paint engine MISSING chrome.
--- Modules MTO shows short module names (not door-tab brand watermark).
local function safePanelTitle(panel)
    if panel == nil then
        return ""
    end
    local t = panel.title
    if type(t) == "string" and t ~= "" then
        local lower = t:lower()
        if not lower:find("^missing%s") and not lower:find("^missing_") and not lower:find("^%$l10n_")
            and lower ~= "realistic farming" then
            return t
        end
    end
    local id = panel.id
    if id == "soilFertilizer" then
        return tr("rf_pda_panel_soil", "Soil Fertilizer")
    elseif id == "workerCosts" then
        return "Worker Costs"
    elseif id == "cropStress" then
        return "Crop Stress"
    end
    return id or ""
end

-- F9 frame-debug targets: id -> short label (colored outline via debugEnabled)
local FRAME_DEBUG_TARGETS = {
    { id = "rfPageRoot",          label = "pageRoot" },
    { id = "rfContentHost",       label = "contentHost" },
    { id = "rfFilterBox",         label = "sideShell" },
    { id = "rfMainCol",           label = "mainShell" },
    { id = "rfPanelContent",      label = "panelContent" },
    { id = "rfTreatmentStrip",    label = "treatment" },
    { id = "treatProductsShell",  label = "productsShell" },
    { id = "treatProdRowsClip",   label = "productsClip" },
}

function RfPdaMenuPage.new()
    local self = RfPdaMenuPage:superClass().new(nil, RfPdaMenuPage_mt)
    self.name = "RfPdaMenuPage"
    self.className = "RfPdaMenuPage"
    self.menuButtonInfo = {}
    self.fieldData = {}
    self.selectedFieldId = nil
    self._liveTimer = 0
    self._wcLiveTimer = 0
    self.wcSubPageIndex = 1
    self.wcAboutTabIndex = 1
    self.mdSubPageIndex = 1
    self.mdCommodityData = {}
    self.mdSelectedFillType = nil
    self._panelCache = {}
    self._lastPanelFingerprint = nil
    self._hostListenerBound = false
    self._refreshing = false
    self._wcWageRefreshing = false
    self._wcSubnavSeeding = false
    self._wcSubnavSeeded = false
    self._mdSubnavSeeding = false
    self._mdSubnavSeeded = false
    self._lastModuleSelectId = nil
    self._lastModuleSelectAt = 0
    self._frameDebug = false
    self._rfTr = tr
    return self
end

--- Giants InGameMenuAnimalsFrame.createFromExistingGui mirror (F6 / UIDebugger).
--- Caller must orphan this page from InGameMenu.pagingElement first so
--- GuiElement:delete does not invoke PagingElement:removeElement (slot loss).
function RfPdaMenuPage.createFromExistingGui(gui, guiName)
    local newGui = RfPdaMenuPage.new()
    local name = (gui ~= nil and gui.name) or guiName or RfPdaMenuPage.CLASS_NAME
    local xmlFilename = (gui ~= nil and gui.xmlFilename) or RfPdaMenuPage.getXmlFilename()
    local frameRoot = nil
    if g_gui ~= nil and type(g_gui.frames) == "table" then
        frameRoot = g_gui.frames[name] or g_gui.frames[RfPdaMenuPage.CLASS_NAME] or g_gui.frames["RfPdaMenuPage"]
    end
    if frameRoot ~= nil then
        if frameRoot.target ~= nil and type(frameRoot.target.delete) == "function" then
            pcall(function()
                frameRoot.target:delete()
            end)
        end
        if type(frameRoot.delete) == "function" then
            pcall(function()
                frameRoot:delete()
            end)
        end
        if g_gui ~= nil and type(g_gui.frames) == "table" then
            g_gui.frames[name] = nil
            g_gui.frames[RfPdaMenuPage.CLASS_NAME] = nil
            g_gui.frames["RfPdaMenuPage"] = nil
        end
    elseif gui ~= nil and type(gui.delete) == "function" then
        pcall(function()
            gui.parent = nil
            gui:delete()
        end)
    end
    g_gui:loadGui(xmlFilename, guiName or RfPdaMenuPage.CLASS_NAME, newGui, true)
    return newGui
end

function RfPdaMenuPage:onGuiSetupFinished()
    RfPdaMenuPage:superClass().onGuiSetupFinished(self)

    self.rfPanelSelector   = self:getDescendantById("rfPanelSelector") or self.rfPanelSelector
    self.rfPanelDotBox     = self:getDescendantById("rfPanelDotBox") or self.rfPanelDotBox
    self.rfPanelContent    = self:getDescendantById("rfPanelContent") or self.rfPanelContent
    self.rfHostPlaceholder = self:getDescendantById("rfHostPlaceholder") or self.rfHostPlaceholder
    self.rfPageTitle       = self:getDescendantById("rfPageTitle") or self.rfPageTitle
    self.rfPageBlurb       = self:getDescendantById("rfPageBlurb") or self.rfPageBlurb
    self.rfDotLegend       = self:getDescendantById("rfDotLegend") or self.rfDotLegend
    self.rfSuiteHint       = self:getDescendantById("rfSuiteHint") or self.rfSuiteHint
    self.rfHostTitle       = self:getDescendantById("rfHostTitle") or self.rfHostTitle
    self.rfHostBlurb       = self:getDescendantById("rfHostBlurb") or self.rfHostBlurb
    self.rfHostBody        = self:getDescendantById("rfHostBody") or self.rfHostBody
    self.fieldOverviewList = self:getDescendantById("fieldOverviewList") or self.fieldOverviewList
    self.csFieldOverviewList = self:getDescendantById("csFieldOverviewList") or self.csFieldOverviewList
    self.csFieldsEmptyHint = self:getDescendantById("csFieldsEmptyHint") or self.csFieldsEmptyHint
    self.rfHostTableRegion = self:getDescendantById("rfHostTableRegion") or self.rfHostTableRegion
    self.csDetailStrip = self:getDescendantById("csDetailStrip") or self.csDetailStrip
    self.mdGraphRegion = self:getDescendantById("mdGraphRegion") or self.mdGraphRegion
    self.mdGraphArea = self:getDescendantById("mdGraphArea") or self.mdGraphArea
    self.mdDetailStrip = self:getDescendantById("mdDetailStrip") or self.mdDetailStrip
    self.mdMoverSelector = self:getDescendantById("mdMoverSelector") or self.mdMoverSelector
    self.mdTableRegion = self:getDescendantById("mdTableRegion") or self.mdTableRegion
    self.mdCommodityList = self:getDescendantById("mdCommodityList") or self.mdCommodityList
    self.mdPageBand = self:getDescendantById("mdPageBand") or self.mdPageBand
    self.mdPricesBand = self:getDescendantById("mdPricesBand") or self.mdPricesBand
    self.mdEventsBand = self:getDescendantById("mdEventsBand") or self.mdEventsBand
    self.mdContractsBand = self:getDescendantById("mdContractsBand") or self.mdContractsBand
    self.mdOpenMarketBtn = self:getDescendantById("mdOpenMarketBtn") or self.mdOpenMarketBtn
    self.mdSubnavShell = self:getDescendantById("mdSubnavShell") or self.mdSubnavShell
    self.mdSubnavSelector = self:getDescendantById("mdSubnavSelector") or self.mdSubnavSelector
    self.mdSubnavDotBox = self:getDescendantById("mdSubnavDotBox") or self.mdSubnavDotBox
    self.mdSideInfoShell = self:getDescendantById("mdSideInfoShell") or self.mdSideInfoShell
    self.mdSideInfoBody = self:getDescendantById("mdSideInfoBody") or self.mdSideInfoBody
    self.wcGlanceShell = self:getDescendantById("wcGlanceShell") or self.wcGlanceShell
    self.wcSubnavShell = self:getDescendantById("wcSubnavShell") or self.wcSubnavShell
    self.wcSubnavSelector = self:getDescendantById("wcSubnavSelector") or self.wcSubnavSelector
    self.wcSubnavDotBox = self:getDescendantById("wcSubnavDotBox") or self.wcSubnavDotBox
    if self.mdCommodityList then
        self.mdCommodityList.dataSource = self
        self.mdCommodityList.delegate = self
    end
    -- Dual-arrow FAIL-FIX: live page selector = title-chrome wcTitlePageSelector (not left twin).
    self.wcTitlePageShell = self:getDescendantById("wcTitlePageShell") or self.wcTitlePageShell
    self.wcTitlePageSelector = self:getDescendantById("wcTitlePageSelector") or self.wcTitlePageSelector
    self.wcPageSelector = self:getDescendantById("wcPageSelector") or self.wcPageSelector
    self.wcSideInfoShell = self:getDescendantById("wcSideInfoShell") or self.wcSideInfoShell
    self.wcSideInfoBody = self:getDescendantById("wcSideInfoBody") or self.wcSideInfoBody
    self.wcSideVersion = self:getDescendantById("wcSideVersion") or self.wcSideVersion
    self.rfSideInfoShell = self:getDescendantById("rfSideInfoShell") or self.rfSideInfoShell
    self.rfSideInfoBody = self:getDescendantById("rfSideInfoBody") or self.rfSideInfoBody
    self.rfSideMidSeparator = self:getDescendantById("rfSideMidSeparator") or self.rfSideMidSeparator
    self.rfModuleListShell = self:getDescendantById("rfModuleListShell") or self.rfModuleListShell
    self.wcPageShell = self:getDescendantById("wcPageShell") or self.wcPageShell
    self.rfFrameworkGlanceShell = self:getDescendantById("rfFrameworkGlanceShell") or self.rfFrameworkGlanceShell
    self.rfFwStatusBlock = self:getDescendantById("rfFwStatusBlock") or self.rfFwStatusBlock
    self.rfFwTableBlock = self:getDescendantById("rfFwTableBlock") or self.rfFwTableBlock
    self.wcPageDashboard = self:getDescendantById("wcPageDashboard") or self.wcPageDashboard
    self.wcPageWages = self:getDescendantById("wcPageWages") or self.wcPageWages
    self.wcPageWorkers = self:getDescendantById("wcPageWorkers") or self.wcPageWorkers
    self.wcPageAbout = self:getDescendantById("wcPageAbout") or self.wcPageAbout
    self.moduleList        = self:getDescendantById("moduleList") or self.moduleList
    self.fieldsEmptyHint   = self:getDescendantById("fieldsEmptyHint") or self.fieldsEmptyHint
    self.soilColField = self:getDescendantById("soilColField") or self.soilColField
    self.soilColArea = self:getDescendantById("soilColArea") or self.soilColArea
    self.soilColStatus = self:getDescendantById("soilColStatus") or self.soilColStatus
    self.soilColFert = self:getDescendantById("soilColFert") or self.soilColFert
    self.soilSectionTreatment = self:getDescendantById("soilSectionTreatment") or self.soilSectionTreatment
    self.soilTreatProducts = self:getDescendantById("soilTreatProducts") or self.soilTreatProducts
    -- Read-only rotation card (2026-08-07). Nil-safe: older door XML lacks these ids.
    self.soilRotationCard   = self:getDescendantById("soilRotationCard") or self.soilRotationCard
    self.soilRotationTitle  = self:getDescendantById("soilRotationTitle") or self.soilRotationTitle
    self.soilRotationLast   = self:getDescendantById("soilRotationLast") or self.soilRotationLast
    self.soilRotationStatus = self:getDescendantById("soilRotationStatus") or self.soilRotationStatus
    self.soilRotationTip    = self:getDescendantById("soilRotationTip") or self.soilRotationTip
    self.treatSelectedLabel = self:getDescendantById("treatSelectedLabel") or self.treatSelectedLabel
    self.treatNextLabel     = self:getDescendantById("treatNextLabel") or self.treatNextLabel
    self.treatTargetsLabel  = self:getDescendantById("treatTargetsLabel") or self.treatTargetsLabel
    self.treatTargetsHeading = self:getDescendantById("treatTargetsHeading") or self.treatTargetsHeading
    self.treatTargetN       = self:getDescendantById("treatTargetN") or self.treatTargetN
    self.treatTargetP       = self:getDescendantById("treatTargetP") or self.treatTargetP
    self.treatTargetK       = self:getDescendantById("treatTargetK") or self.treatTargetK
    self.treatPlanLines     = self:getDescendantById("treatPlanLines") or self.treatPlanLines
    self.treatProdRows = {}
    for i = 1, 8 do
        self.treatProdRows[i] = {
            row = self:getDescendantById("treatProdRow" .. i),
            nut = self:getDescendantById("treatProd" .. i .. "Nut"),
            name = self:getDescendantById("treatProd" .. i .. "Name"),
            rate = self:getDescendantById("treatProd" .. i .. "Rate"),
            total = self:getDescendantById("treatProd" .. i .. "Total"),
        }
    end
    self.samplingInfoBox    = self:getDescendantById("samplingInfoBox") or self.samplingInfoBox
    self.samplingInfoText   = self:getDescendantById("samplingInfoText") or self.samplingInfoText
    self.samplingInfoFallback = self:getDescendantById("samplingInfoFallback") or self.samplingInfoFallback
    self.rfSuiteHint        = self:getDescendantById("rfSuiteHint") or self.rfSuiteHint
    self.rfPageRoot         = self:getDescendantById("rfPageRoot") or self.rfPageRoot
    self.rfContentHost      = self:getDescendantById("rfContentHost") or self.rfContentHost
    self.rfFilterBox        = self:getDescendantById("rfFilterBox") or self.rfFilterBox
    self.rfMainCol          = self:getDescendantById("rfMainCol") or self.rfMainCol
    self.rfTreatmentStrip   = self:getDescendantById("rfTreatmentStrip") or self.rfTreatmentStrip
    self.treatProductsShell = self:getDescendantById("treatProductsShell") or self.treatProductsShell
    self.treatProdRowsClip  = self:getDescendantById("treatProdRowsClip") or self.treatProdRowsClip

    if self.fieldOverviewList then
        self.fieldOverviewList.dataSource = self
        self.fieldOverviewList.delegate = self
    end
    if self.csFieldOverviewList then
        self.csFieldOverviewList.dataSource = self
        self.csFieldOverviewList.delegate = self
    end
    self.csFieldData = self.csFieldData or {}
    if self.moduleList then
        self.moduleList.dataSource = self
        self.moduleList.delegate = self
    end
end

--- Rebind Soil chrome Text that used $l10n_ at loadGui (fails when CS/WC created the door).
function RfPdaMenuPage:_applyChromeL10n()
    local function setEl(el, key, fallback)
        if el ~= nil and type(el.setText) == "function" then
            el:setText(tr(key, fallback))
        end
    end
    setEl(self.soilColField, "sf_pda_col_field", "Field")
    setEl(self.soilColArea, "rf_pda_col_area", "Area")
    setEl(self.soilColStatus, "sf_pda_col_status", "Status")
    setEl(self.soilColFert, "rf_pda_col_fert", "Fertilizer")
    setEl(self.fieldsEmptyHint, "sf_pda_no_fields", "No field data recorded yet.")
    setEl(self.soilSectionTreatment, "rf_pda_section_treatment", "Treatment")
    setEl(self.soilTreatProducts, "rf_pda_treat_products", "Products")
    setEl(self.samplingInfoFallback, "rf_pda_sample_hint", "Soil sample dates appear here when available.")
end

function RfPdaMenuPage:initialize()
    RfPdaMenuPage:superClass().initialize(self)

    self.btnBack = {
        inputAction = InputAction.MENU_BACK,
        text = g_i18n:getText("button_back")
    }
    -- Q/E = vanilla Esc left icon strip only (InGameMenu page prev/next).
    -- Do NOT bind MENU_PAGE_PREV/NEXT to cyclePanel; modules use MTO L/R arrows.
    self.btnHelp = {
        inputAction = InputAction.MENU_EXTRA_1,
        showWhenPaused = true,
        text = tr("sf_pda_btn_help", "Help"),
        callback = function()
            local dlg = soilGuideDialog()
            if dlg ~= nil then
                dlg.show()
            elseif SoilHelpDialog ~= nil and type(SoilHelpDialog.show) == "function" then
                SoilHelpDialog.show()
            end
        end
    }
    -- MENU_EXTRA_2: open the Rotation Planner from the Esc glance.
    self.btnRotationPlanner = {
        inputAction = InputAction.MENU_EXTRA_2,
        showWhenPaused = true,
        text = tr("sf_pda_btn_rotation_planner", "Rotation Planner"),
        callback = function()
            local dlg = soilGlobal("RotationPlannerDialog")
            if dlg ~= nil and type(dlg.show) == "function" then
                dlg.show(self.selectedFieldId)
            end
        end
    }
    -- MENU_ACTIVATE: open the per-field detail dialog from the Esc glance.
    self.btnFieldDetail = {
        inputAction = InputAction.MENU_ACTIVATE,
        showWhenPaused = true,
        text = tr("sf_pda_btn_field_detail", "Field Detail"),
        callback = function()
            local dlg = soilGlobal("SoilFieldDetailDialog")
            if dlg ~= nil and type(dlg.show) == "function" then
                dlg.show(self.selectedFieldId)
            end
        end
    }
    -- Open full Market when MDM module is active (bottom strip twin).
    -- MENU_EXTRA_1, NOT MENU_ACTIVATE: the commodity SmoothList consumes ACTIVATE/SPACE
    -- first, so the footer callback never fired at all - zero MarketScreen.show lines in
    -- the client log on click (Ash+George r2 2026-08-07). EXTRA_1 is free while MDM is
    -- the active module, since Help / Rotation Planner / Field Detail are Soil-only footers.
    self.btnOpenMarket = {
        inputAction = InputAction.MENU_EXTRA_1,
        showWhenPaused = true,
        text = tr("md_rf_pda_open_market", "Open full Market"),
        callback = function()
            print("[MarketDynamics] Esc footer Open full Market pressed")
            -- Cross-mod resolve (Vera F2 2026-08-07). MdRfPdaGuest / MDMMarketScreen are
            -- MarketDynamics-env globals and are nil on a Soil/WC/SCS hosted door, so the
            -- bare calls silently did nothing there. Same shape as the Worker Manager
            -- resolve below and Soil's soilGlobal: try in-env, then g_modEnvironments.
            local host = self:_getHost()
            local activeId = host ~= nil and host.activeModuleId or nil
            local mod = (host ~= nil and host.modules ~= nil and activeId ~= nil)
                and host.modules[activeId] or nil
            if mod ~= nil and type(mod.onOpenFullMarket) == "function" then
                print("[MarketDynamics] Open full Market via active module def")
                mod.onOpenFullMarket()
                return
            end
            if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onOpenFullMarket) == "function" then
                print("[MarketDynamics] Open full Market via in-env MdRfPdaGuest")
                MdRfPdaGuest.onOpenFullMarket()
                return
            end
            local mdEnv = g_modEnvironments ~= nil and g_modEnvironments["FS25_MarketDynamics"] or nil
            local guest = mdEnv ~= nil and mdEnv.MdRfPdaGuest or nil
            if guest ~= nil and type(guest.onOpenFullMarket) == "function" then
                print("[MarketDynamics] Open full Market via g_modEnvironments MdRfPdaGuest")
                guest.onOpenFullMarket()
                return
            end
            local scr = mdEnv ~= nil and mdEnv.MDMMarketScreen or nil
            if scr ~= nil and type(scr.show) == "function" then
                print("[MarketDynamics] Open full Market via g_modEnvironments MDMMarketScreen")
                scr.show()
                return
            end
            if MDMMarketScreen ~= nil and type(MDMMarketScreen.show) == "function" then
                print("[MarketDynamics] Open full Market via in-env MDMMarketScreen")
                MDMMarketScreen.show()
                return
            end
            print("[MarketDynamics] Open full Market: no handler available (all resolve paths nil)")
        end
    }
    -- SPACE / MENU_ACTIVATE: open the Worker Manager deep desk when WC is active.
    self.btnOpenWorkerManager = {
        -- MENU_EXTRA_2, not MENU_ACTIVATE: same SmoothList swallow class as Open full
        -- Market (Ash 2026-08-07). Free while WC is active, Rotation Planner is Soil-only.
        inputAction = InputAction.MENU_EXTRA_2,
        showWhenPaused = true,
        text = tr("wc_rf_pda_open_manager", "Open Worker Manager"),
        callback = function()
            local wcGui = g_currentMission ~= nil and g_currentMission.rfWcGui
            if wcGui == nil then
                local env0 = getfenv and getfenv(0)
                wcGui = env0 and env0.g_wcGui
            end
            if wcGui == nil and g_modEnvironments ~= nil then
                local wcEnv = g_modEnvironments["FS25_WorkerCosts"]
                wcGui = wcEnv and wcEnv.g_wcGui
            end
            if wcGui ~= nil then
                g_gui:showGui("WCGui")
            end
        end
    }

    -- Back only. Help is Soil-only and _syncHostGuestChrome adds it when the Soil
    -- module is the active one; seeding it here leaked Help onto every module's
    -- footer for the window before the first sync ran.
    self.menuButtonInfo = { self.btnBack }
    self:_applyChromeL10n()
    self:_bindHostListener()
end

function RfPdaMenuPage:_bindHostListener()
    if self._hostListenerBound then return end
    local host = self:_getHost()
    if host == nil or type(host.addChangeListener) ~= "function" then
        return
    end
    host:addChangeListener(function()
        if self.isOpen then
            -- Quiet: no field SmoothList rebuild on notify; module list only if set changed.
            self:refreshPanelSelector(false)
            self:refreshContent(false)
        end
    end)
    self._hostListenerBound = true
end

function RfPdaMenuPage:onFrameOpen()
    RfPdaMenuPage:superClass().onFrameOpen(self)
    self.isOpen = true
    self._liveTimer = 0
    self._rfSoilPanelMissingWarned = false
    self:_bindHostListener()
    self:_applyChromeL10n()
    -- F11: lime arrows before and after first refresh (engine may disable on open).
    self:_ensureSelectorArrowsVisible()
    self:refreshPanelSelector(true)
    self:refreshContent(true)
    self:_ensureSelectorArrowsVisible()
end

function RfPdaMenuPage:onFrameClose()
    self.isOpen = false
    RfPdaMenuPage:superClass().onFrameClose(self)
end

-- F9: temporary Esc RF PDA frame outlines (GuiElement.debugEnabled + labels).
-- Engine SoT: GuiElement:draw draws red borders when debugEnabled or g_uiDebugEnabled
-- (extract GuiElement.lua ~521). Global toggle: console gsGuiDebug.
-- Suite toggle: SoilRfPdaFrameDebug (labels only our key shells).
function RfPdaMenuPage:setFrameDebug(enabled)
    self._frameDebug = enabled == true
    for _, spec in ipairs(FRAME_DEBUG_TARGETS) do
        local el = self:getDescendantById(spec.id)
        if el ~= nil then
            el.debugEnabled = self._frameDebug
        end
    end
    -- Also outline the TabbedMenuFrameElement (page controller) itself.
    self.debugEnabled = self._frameDebug
end

function RfPdaMenuPage:toggleFrameDebug()
    self:setFrameDebug(not self._frameDebug)
    return self._frameDebug
end

function RfPdaMenuPage:draw(clipX1, clipY1, clipX2, clipY2)
    RfPdaMenuPage:superClass().draw(self, clipX1, clipY1, clipX2, clipY2)
    -- Market Dynamics Prices page graph (after chrome). Reuse MDMMarketScreenGraph.draw.
    do
        local host = self:_getHost()
        local active = host and host.getActivePanel and host:getActivePanel()
        local pageIdx = tonumber(self.mdSubPageIndex) or 1
        if active ~= nil and active.id == "marketDynamics"
                and pageIdx == 1
                and self.mdPricesBand ~= nil
                and MDMMarketScreenGraph ~= nil and type(MDMMarketScreenGraph.draw) == "function" then
            local area = self.mdGraphArea
            if area ~= nil and area.absPosition ~= nil and area.absSize ~= nil then
                local ft = self.mdSelectedFillType
                if ft == nil and MdRfPdaGuest ~= nil and type(MdRfPdaGuest.getSelectedFillType) == "function" then
                    ft = MdRfPdaGuest.getSelectedFillType()
                end
                if ft ~= nil then
                    MDMMarketScreenGraph.draw(ft, area.absPosition[1], area.absPosition[2], area.absSize[1], area.absSize[2])
                end
            end
        end
    end
    if not self._frameDebug then
        return
    end
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(true)
    local textSize = 0.012
    for _, spec in ipairs(FRAME_DEBUG_TARGETS) do
        local el = self:getDescendantById(spec.id)
        if el ~= nil and el.absPosition ~= nil and el.absSize ~= nil then
            local x = el.absPosition[1] + 0.004
            local y = el.absPosition[2] + el.absSize[2] - textSize - 0.002
            setTextColor(0.1, 1.0, 0.35, 1)
            renderText(x, y, textSize, spec.label)
        end
    end
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
end

function RfPdaMenuPage:update(dt)
    RfPdaMenuPage:superClass().update(self, dt)
    -- Light tick only: never reload SmoothList every 2s (that path + Bitmap parent
    -- correlated with GuiElement mouseEvent/update stack overflow + emergency GC).
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    local isSoil = active == nil or active.id == "soilFertilizer"
    local isWc = active ~= nil and active.id == "workerCosts"
    local isMd = active ~= nil and active.id == "marketDynamics"

    -- Market Dynamics: light text/graph refresh; never SmoothList thrash.
    if isMd then
        local pageIdx = tonumber(self.mdSubPageIndex) or 1
        if pageIdx == 1 and MDMMarketScreenGraph ~= nil and type(MDMMarketScreenGraph.update) == "function" then
            pcall(MDMMarketScreenGraph.update, dt)
        end
        self._mdLiveTimer = (self._mdLiveTimer or 0) + dt
        if self._mdLiveTimer >= REFRESH_INTERVAL then
            self._mdLiveTimer = 0
            if active ~= nil and type(active.onShow) == "function" then
                pcall(active.onShow, self.rfHostPlaceholder, true)
            end
        end
        return
    end

    -- WC Dashboard/Workers: 500ms text-only live refresh (George FULL PORT ACK).
    if isWc then
        self._wcLiveTimer = (self._wcLiveTimer or 0) + dt
        if self._wcLiveTimer >= WC_LIVE_REFRESH_INTERVAL then
            self._wcLiveTimer = 0
            if active ~= nil and type(active.onShow) == "function" then
                pcall(active.onShow, self.rfHostPlaceholder, true)
            end
        end
        return
    end

    self._liveTimer = (self._liveTimer or 0) + dt
    if self._liveTimer >= REFRESH_INTERVAL then
        self._liveTimer = 0
        -- Phase 1 Q3 = B: no farm money on this Esc page (no balance refresh).
        if isSoil then
            local panel = soilPanel()
            if panel ~= nil then
                panel.refreshTreatmentPlan(self)
            end
        elseif active ~= nil and type(active.onShow) == "function" then
            -- Light guest glance refresh (text only; no SmoothList thrash).
            pcall(active.onShow, self.rfHostPlaceholder, true)
        end
    end
end

function RfPdaMenuPage:_getHost()
    -- Shared module registry only (NO HOST). Never RfPdaHost / rfPdaHost.
    if RfEscModules ~= nil then
        return RfEscModules.getOrCreate()
    end
    return nil
end

--- Shared MTO arrow ensure: enable + normalized ~36px hit (never setSize(36,36) literals)
--- then lime tint. Re-apply every call - profile can reset circle buttons to 42.
function RfPdaMenuPage:_ensureMtoArrowsVisible(sel)
    if sel == nil then
        return
    end

    sel.disableButtonsOnSingleText = false
    sel.hideLeftRightButtons = false
    if sel.setCanChangeState then
        sel:setCanChangeState(true)
    end
    if sel.setDisabled then
        sel:setDisabled(false)
    end

    -- Extract: GuiUtils.getNormalizedScreenValues(values, default) - values = "Wpx Hpx" or array; returns table.
    -- Never pass bare numbers (GuiUtils.lua #values throws on number).
    local tw, th = nil, nil
    if GuiUtils ~= nil and type(GuiUtils.getNormalizedScreenValues) == "function" then
        local norms = GuiUtils.getNormalizedScreenValues("36px 36px")
        if type(norms) == "table" then
            tw, th = norms[1], norms[2]
        end
    end

    -- ButtonElement extends TextElement (not Bitmap); tint via GuiOverlay on .overlay.
    local r, g, b, a = 0.549, 0.776, 0.247, 1
    for _, btn in ipairs({ sel.leftButtonElement, sel.rightButtonElement }) do
        if btn ~= nil then
            if btn.setVisible then btn:setVisible(true) end
            if btn.setDisabled then btn:setDisabled(false) end
            -- Size THEN lime (George Plan A). Absolute target - do not ratio current size.
            if type(btn.setSize) == "function" and tw ~= nil and th ~= nil then
                btn:setSize(tw, th)
            end
            if btn.overlay ~= nil and GuiOverlay ~= nil and GuiOverlay.setColor then
                GuiOverlay.setColor(btn.overlay, r, g, b, a)
            end
            if type(btn.updateAbsolutePosition) == "function" then
                btn:updateAbsolutePosition()
            end
        end
    end
end

--- Keep Map circle arrows enabled + lime on first open (not near-black grey).
function RfPdaMenuPage:_ensureSelectorArrowsVisible()
    self:_ensureMtoArrowsVisible(self.rfPanelSelector)
end

--- Stable id list fingerprint for quiet SmoothList reload decisions.
function RfPdaMenuPage:_panelSetFingerprint(panels)
    local parts = {}
    for i, panel in ipairs(panels or {}) do
        parts[i] = tostring(panel.id)
    end
    return table.concat(parts, "|")
end

function RfPdaMenuPage:refreshPanelSelector(forceRebuildDots)
    if self._refreshing then return end
    local host = self:_getHost()
    if host == nil or self.rfPanelSelector == nil then return end

    self._refreshing = true
    local ok, err = pcall(function()
        local panels = host:getPanels()
        local fingerprint = self:_panelSetFingerprint(panels)
        local setChanged = fingerprint ~= self._lastPanelFingerprint
        self._lastPanelFingerprint = fingerprint
        self._panelCache = panels

        local texts = self:_panelTitles(panels)
        local activeIndex = 1
        for i, panel in ipairs(panels) do
            if host.activeModuleId == panel.id then
                activeIndex = i
                break
            end
        end

        if #texts == 0 then
            -- Last-resort single label (selector profile keeps textSize ~20px; never RF_PageTitle 74px).
            texts[1] = "No modules"
            activeIndex = 1
        end

        self:_ensureSelectorArrowsVisible()
        -- setTexts can re-apply profile single-text disable; always follow with force-enable.
        self.rfPanelSelector:setTexts(texts)
        if self.rfPanelSelector.setState then
            -- Modules dual-fire FAIL-FIX (George): forceEvent=true re-enters onClick →
            -- selectPanel → refreshPanelSelector → setState(true) loop with moduleList.
            -- Always false while _refreshing so list/MTO sync never raises click.
            self.rfPanelSelector:setState(activeIndex, false)
        end
        -- F11: force lime arrows visible again after setState (engine may disable on open).
        self:_ensureSelectorArrowsVisible()

        -- Rebuild RoundCorner dots only when count/set changes or forced (onFrameOpen).
        if forceRebuildDots or setChanged then
            self:_rebuildDots(#texts)
        end

        self:_refreshDotLegend(panels, activeIndex)
        -- Module SmoothList: only when panel set actually changes or forced open.
        if (forceRebuildDots or setChanged) and self.moduleList then
            self.moduleList:reloadData()
        end
    end)
    self._refreshing = false
    if not ok and SoilLogger then
        SoilLogger.warning("RfPdaMenuPage:refreshPanelSelector failed: %s", tostring(err))
    end
end

function RfPdaMenuPage:_refreshDotLegend(panels, activeIndex)
    if self.rfDotLegend == nil then return end
    local n = math.max(1, #(panels or {}))
    local shorts = {}
    for _, panel in ipairs(panels or {}) do
        local title = safePanelTitle(panel)
        if panel.id == "soilFertilizer" then
            title = tr("rf_pda_module_soil_short", "Soil")
        end
        table.insert(shorts, title)
    end
    local joined = table.concat(shorts, " Â· ")
    if joined == "" then
        joined = tr("rf_pda_module_soil_short", "Soil")
    end
    self.rfDotLegend:setText(string.format("%d/%d Â· %s", activeIndex or 1, n, joined))
end

--- Match SoilMapHooks / Map: grow/shrink from first seed RoundCorner in the BoxLayout.
function RfPdaMenuPage:_rebuildDots(count)
    local dotBox = self.rfPanelDotBox
    if dotBox == nil or dotBox.elements == nil or #dotBox.elements == 0 then
        return
    end

    local elements = dotBox.elements
    local expectedCount = math.max(1, count or 1)

    while #elements < expectedCount do
        local seed = elements[1]
        if seed == nil or seed.clone == nil then
            break
        end
        local ok, clone = pcall(function()
            return seed:clone(dotBox)
        end)
        if not ok or clone == nil then
            break
        end
        if FocusManager and FocusManager.loadElementFromCustomValues then
            pcall(FocusManager.loadElementFromCustomValues, FocusManager, clone)
        end
        elements = dotBox.elements
    end

    while #elements > expectedCount do
        local last = elements[#elements]
        if last ~= nil and last.delete then
            last:delete()
        end
        elements = dotBox.elements
    end

    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            if self.rfPanelSelector == nil or self.rfPanelSelector.getState == nil then
                return index == 1
            end
            return self.rfPanelSelector:getState() == index
        end
        if dot.setVisible then
            dot:setVisible(true)
        end
    end

    if dotBox.invalidateLayout then
        dotBox:invalidateLayout()
    end
end

function RfPdaMenuPage:onClickRfPanelSelector()
    self:_ensureSelectorArrowsVisible()
    self:_applySelectorState()
end

--- Debounce duplicate module id selects (MTO ↔ moduleList bounce ~200ms in logs).
--- @return boolean true when the select should proceed
function RfPdaMenuPage:_allowModuleSelect(panelId)
    if panelId == nil then
        return false
    end
    if self._refreshing then
        return false
    end
    local now = g_time or 0
    if self._lastModuleSelectId == panelId then
        local elapsed = now - (self._lastModuleSelectAt or 0)
        if elapsed >= 0 and elapsed < MODULE_SELECT_DEBOUNCE_MS then
            return false
        end
    end
    self._lastModuleSelectId = panelId
    self._lastModuleSelectAt = now
    return true
end

function RfPdaMenuPage:_restoreBrandToActivePanel()
    local host = self:_getHost()
    if host == nil or self.rfPanelSelector == nil or self.rfPanelSelector.setState == nil then
        return
    end
    local panels = self._panelCache or (host.getPanels and host:getPanels()) or {}
    local idx = 1
    for i, panel in ipairs(panels) do
        if panel.id == host.activeModuleId then
            idx = i
            break
        end
    end
    -- Click-hit FAIL-FIX: never forceEvent after page click (re-enters Brand onClick / dual-fire).
    self._refreshing = true
    pcall(function()
        self.rfPanelSelector:setState(idx, false)
    end)
    self._refreshing = false
end

function RfPdaMenuPage:_applySelectorState()
    local host = self:_getHost()
    if host == nil or self.rfPanelSelector == nil then return end
    if self._refreshing then
        return
    end

    local state = self.rfPanelSelector:getState()
    local panel = self._panelCache[state]
    if panel == nil then return end

    if host.activeModuleId ~= panel.id then
        if not self:_allowModuleSelect(panel.id) then
            return
        end
        -- Host notify refreshes selector + content (quiet lists).
        host:selectPanel(panel.id)
        SoilLogger.info("RfPdaMenuPage: selectPanel %s (arrow/selector)", tostring(panel.id))
    else
        self:refreshContent(false)
    end
end

function RfPdaMenuPage:cyclePanel(delta)
    local host = self:_getHost()
    if host == nil then return end

    local panels = host:getPanels()
    self._panelCache = panels
    local n = #panels
    if n <= 0 then return end
    if n == 1 then
        -- Stable no-op with one panel; keep arrows visible, no SmoothList rebuild.
        self:_ensureSelectorArrowsVisible()
        return
    end

    local idx = 1
    for i, panel in ipairs(panels) do
        if panel.id == host.activeModuleId then
            idx = i
            break
        end
    end

    local nextIdx = ((idx - 1 + delta) % n) + 1
    local nextPanel = panels[nextIdx]
    if nextPanel == nil then return end
    if not self:_allowModuleSelect(nextPanel.id) then
        return
    end

    -- selectPanel notifies → quiet refreshPanelSelector + refreshContent(false)
    host:selectPanel(nextPanel.id)
    SoilLogger.info("RfPdaMenuPage: cyclePanel -> %s", tostring(nextPanel.id))
end

--- Modules MTO texts: module names only (Soil Fertilizer / Worker Costs / Crop Stress).
--- Door tab owns "Realistic Farming"; never force brand watermark into selector texts.
function RfPdaMenuPage:_panelTitles(panels)
    local texts = {}
    for i, panel in ipairs(panels) do
        texts[i] = safePanelTitle(panel)
    end
    return texts
end

function RfPdaMenuPage:_refreshPageHeader(active)
    local isSoil = active == nil or active.id == "soilFertilizer"
    local isWc = active ~= nil and active.id == "workerCosts"
    local activeId = active ~= nil and active.id or nil
    local isFw = activeId == "income" or activeId == "tax" or activeId == "dairy"
            or activeId == "npcFavor" or activeId == "fertilizerDepot"
    if self.rfPageTitle then
        if isSoil then
            self.rfPageTitle:setText(tr("rf_pda_panel_soil", "Soil Fertilizer"))
        else
            self.rfPageTitle:setText(safePanelTitle(active))
        end
    end
    if self.rfPageBlurb then
        -- Framework overlap FAILFIX (George 2026-08-05): side About owns story; blank+hide blurb.
        if isFw then
            self.rfPageBlurb:setText("")
            if type(self.rfPageBlurb.setVisible) == "function" then
                self.rfPageBlurb:setVisible(false)
            end
        elseif isSoil then
            if type(self.rfPageBlurb.setVisible) == "function" then
                self.rfPageBlurb:setVisible(true)
            end
            self.rfPageBlurb:setText(tr("rf_pda_menu_blurb",
                "Monitor your fields' nutrient levels. Apply fertilizer to maintain optimal yields."))
        elseif isWc then
            -- Chrome FAIL-FIX: never leave Soil nutrient/treatment copy on Worker Costs.
            if type(self.rfPageBlurb.setVisible) == "function" then
                self.rfPageBlurb:setVisible(true)
            end
            local rawBlurb = active and active.blurb
            local wcBlurb = "Wage mode, active workers, next settlement estimate. Open Worker Manager for hire and settings."
            if type(rawBlurb) == "string" and rawBlurb ~= "" then
                local lower = rawBlurb:lower()
                if not lower:find("^missing%s") and not lower:find("^missing_") then
                    wcBlurb = rawBlurb
                end
            end
            self.rfPageBlurb:setText(wcBlurb)
        elseif active ~= nil and type(active.blurb) == "string" and active.blurb ~= "" then
            if type(self.rfPageBlurb.setVisible) == "function" then
                self.rfPageBlurb:setVisible(true)
            end
            local lower = active.blurb:lower()
            if not lower:find("^missing%s") and not lower:find("^missing_") then
                self.rfPageBlurb:setText(active.blurb)
            else
                self.rfPageBlurb:setText(tr("rf_pda_host_blurb",
                    "Quick look at this module. Open Farm Tablet for the full tools."))
            end
        else
            if type(self.rfPageBlurb.setVisible) == "function" then
                self.rfPageBlurb:setVisible(true)
            end
            self.rfPageBlurb:setText(tr("rf_pda_host_blurb",
                "Quick look at this module. Open Farm Tablet for the full tools."))
        end
    end
    -- rfSuiteHint retired: side help paints via rfSideInfoShell / wcSideInfoShell only.
    if self.rfSuiteHint and self.rfSuiteHint.setText then
        self.rfSuiteHint:setText("")
    end
end

--- Fill Soil/CS left side-info Text (WC body filled by WcRfPdaGuest).
function RfPdaMenuPage:_refreshSideInfo(activeId)
    local isSoil = activeId == nil or activeId == "soilFertilizer"
    local isCs = activeId == "seasonalCropStress"
    local isWc = activeId == "workerCosts"
    local isMd = activeId == "marketDynamics"
    local isFw = activeId == "income" or activeId == "tax" or activeId == "dairy"
            or activeId == "npcFavor" or activeId == "fertilizerDepot"
    local isFwStatus = activeId == "tax"
    local isFwTable = activeId == "income" or activeId == "dairy" or activeId == "npcFavor" or activeId == "fertilizerDepot"
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.rfSideInfoShell, isSoil or isCs or isFw)
    setVis(self.wcSideInfoShell, isWc)
    setVis(self.mdSideInfoShell, isMd)
    setVis(self.rfSuiteHint, false)
    if self.rfSideInfoBody and self.rfSideInfoBody.setText then
        if isSoil then
            self.rfSideInfoBody:setText(tr("rf_pda_side_info_soil",
                "Soil Fertilizer\n\nThis table lists every field you own. One row = one field.\n\nColumns: Field #, Area, N/P/K (% of a healthy target), pH (like the soil monitor - e.g. 6.2), Status (Good / Fair / Poor), Fertilizer need (short cue for what still looks short).\n\nClick a row. Treatment (below) is the plan for that field:\n- PRODUCT = what to buy (first is preferred; \"or ...\" is an alternate)\n- RATE = amount per area / TOTAL = amount for this field\n- Selected names the field; Next (under it) says what to do first\n\nHow to apply: dry goods (urea, MAP, potash, lime) go through a fertilizer spreader; liquids go in a sprayer tank. If pH and nutrients both show, fix lime or gypsum first so nutrients can work. Weed, pest, or disease lines mean spray (or weed mechanically) before you expect a full crop.\n\nStart with the weakest Status, open Treatment, follow Next, then the rest of the list."))
        elseif isCs then
            self.rfSideInfoBody:setText(tr("rf_pda_side_info_crop_stress",
                "Crop Stress\n\nThis table lists every field you own. One row = one field.\n\nColumns: Field # / Crop, Moisture (how wet the soil is), Stress (how hard the crop is fighting dry spells), Irrigation (water help covering this field), Status (Healthy / Warning / Critical).\n\nClick a row. The strip below names the field, then Next says what to do first:\n- Critical or Warning Moisture → water that field (turn on irrigation if covered, or spray WATER / place coverage)\n- High Stress or a sensitive growth window → protect now; stress today cuts harvest later\n- Looking fine → recheck later; worse fields first\n\nIrrigation: Yes means a system can cover this field. The strip under the table shows this field's schedule, water rate, yield keep, and air dry-pull. Edit systems on Farm Tablet / Crop Consultant when you need to change them.\n\nIf Soil Fertilizer is also loaded, check nutrients there too. Dry soil drains faster when soil health is poor.\n\nStart with Critical Status, follow Next, then work up the list."))
        else
            self.rfSideInfoBody:setText("")
        end
    end
end

--- Show/hide CS table+detail twins and WC subnav/page shells by active guest panel id.
--- Panel id for Crop Stress guest is seasonalCropStress (not "cropStress").
function RfPdaMenuPage:_syncHostGuestChrome(activeId)
    local isSoil = activeId == nil or activeId == "soilFertilizer"
    local isCs = activeId == "seasonalCropStress"
    local isWc = activeId == "workerCosts"
    local isMd = activeId == "marketDynamics"
    local isFw = activeId == "income" or activeId == "tax" or activeId == "dairy"
            or activeId == "npcFavor" or activeId == "fertilizerDepot"
    local isFwStatus = activeId == "tax"
    local isFwTable = activeId == "income" or activeId == "dairy" or activeId == "npcFavor" or activeId == "fertilizerDepot"
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.rfHostTableRegion, isCs)
    setVis(self.csFieldOverviewList, isCs)
    setVis(self.csDetailStrip, isCs)
    -- MDM three-page chrome (TOP table + BOTTOM bands + secondary subnav).
    setVis(self.mdTableRegion, isMd)
    setVis(self.mdCommodityList, isMd)
    setVis(self.mdPageBand, isMd)
    setVis(self.mdGraphRegion, false)
    setVis(self.mdDetailStrip, false)
    setVis(self.mdMoverSelector, false)
    if self.mdMoverSelector ~= nil then
        self.mdMoverSelector.hideLeftRightButtons = true
        if type(self.mdMoverSelector.setDisabled) == "function" then
            self.mdMoverSelector:setDisabled(true)
        end
    end
    if isMd then
        if self.mdTableRegion ~= nil and type(self.mdTableRegion.updateAbsolutePosition) == "function" then
            self.mdTableRegion:updateAbsolutePosition()
        end
        if self.mdPageBand ~= nil and type(self.mdPageBand.updateAbsolutePosition) == "function" then
            self.mdPageBand:updateAbsolutePosition()
        end
        if self.mdGraphArea ~= nil and type(self.mdGraphArea.updateAbsolutePosition) == "function" then
            self.mdGraphArea:updateAbsolutePosition()
        end
        if type(self._seedMdSubnavTexts) == "function" then
            self:_seedMdSubnavTexts()
        end
        if type(self._syncMdSubPageVisibility) == "function" then
            self:_syncMdSubPageVisibility()
        end
    else
        setVis(self.mdPricesBand, false)
        setVis(self.mdEventsBand, false)
        setVis(self.mdContractsBand, false)
        setVis(self.mdOpenMarketBtn, false)
        local btnE = self:getDescendantById("mdOpenMarketBtnEvents")
        local btnC = self:getDescendantById("mdOpenMarketBtnContracts")
        setVis(btnE, false)
        setVis(btnC, false)
    end
    if not isCs then
        setVis(self.csFieldsEmptyHint, false)
    end
    -- Fresh WC: page MTO lives in sibling wcSubnavShell (NOT rfFilterBox). Brand alone in filter.
    setVis(self.wcSubnavShell, isWc)
    setVis(self.wcSubnavSelector, isWc)
    setVis(self.wcSubnavDotBox, isWc)
    -- MDM subnav twin (Prices | Events | Contracts); exclusive with WC subnav.
    setVis(self.mdSubnavShell, isMd)
    setVis(self.mdSubnavSelector, isMd)
    setVis(self.mdSubnavDotBox, isMd)
    if self.mdSubnavSelector ~= nil then
        if isMd then
            self.mdSubnavSelector.disableButtonsOnSingleText = false
            self.mdSubnavSelector.hideLeftRightButtons = false
            if type(self.mdSubnavSelector.setDisabled) == "function" then
                self.mdSubnavSelector:setDisabled(false)
            end
            if type(self.mdSubnavSelector.setCanChangeState) == "function" then
                self.mdSubnavSelector:setCanChangeState(true)
            end
            if self.mdSubnavShell ~= nil and type(self.mdSubnavShell.updateAbsolutePosition) == "function" then
                self.mdSubnavShell:updateAbsolutePosition()
            end
            if type(self.mdSubnavSelector.updateAbsolutePosition) == "function" then
                self.mdSubnavSelector:updateAbsolutePosition()
            end
            if type(self._ensureMdSubnavArrowsVisible) == "function" then
                self:_ensureMdSubnavArrowsVisible()
            end
        else
            self.mdSubnavSelector.hideLeftRightButtons = true
            if type(self.mdSubnavSelector.setDisabled) == "function" then
                self.mdSubnavSelector:setDisabled(true)
            end
            if type(self.mdSubnavSelector.setCanChangeState) == "function" then
                self.mdSubnavSelector:setCanChangeState(false)
            end
            self._mdSubnavSeeded = false
        end
    end
    if self.wcSubnavSelector ~= nil then
        if isWc then
            self.wcSubnavSelector.disableButtonsOnSingleText = false
            self.wcSubnavSelector.hideLeftRightButtons = false
            if type(self.wcSubnavSelector.setDisabled) == "function" then
                self.wcSubnavSelector:setDisabled(false)
            end
            if type(self.wcSubnavSelector.setCanChangeState) == "function" then
                self.wcSubnavSelector:setCanChangeState(true)
            end
            if self.wcSubnavShell ~= nil and type(self.wcSubnavShell.updateAbsolutePosition) == "function" then
                self.wcSubnavShell:updateAbsolutePosition()
            end
            if type(self.wcSubnavSelector.updateAbsolutePosition) == "function" then
                self.wcSubnavSelector:updateAbsolutePosition()
            end
            if self.rfPanelSelector ~= nil and type(self.rfPanelSelector.updateAbsolutePosition) == "function" then
                self.rfPanelSelector:updateAbsolutePosition()
            end
            if self.wcSubnavDotBox ~= nil and type(self.wcSubnavDotBox.updateAbsolutePosition) == "function" then
                self.wcSubnavDotBox:updateAbsolutePosition()
            end
            self:_ensureWcSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
        else
            self.wcSubnavSelector.hideLeftRightButtons = true
            if type(self.wcSubnavSelector.setDisabled) == "function" then
                self.wcSubnavSelector:setDisabled(true)
            end
            if type(self.wcSubnavSelector.setCanChangeState) == "function" then
                self.wcSubnavSelector:setCanChangeState(false)
            end
        end
    end
    setVis(self.wcTitlePageShell, false)
    setVis(self.wcTitlePageSelector, false)
    if self.wcTitlePageSelector ~= nil then
        self.wcTitlePageSelector.hideLeftRightButtons = true
        if type(self.wcTitlePageSelector.setDisabled) == "function" then
            self.wcTitlePageSelector:setDisabled(true)
        end
    end
    setVis(self.wcPageSelector, false)
    setVis(self.wcSideInfoShell, isWc)
    setVis(self.wcSideVersion, false)
    setVis(self.mdSideInfoShell, isMd)
    -- Keep framework (Income/Depot/etc) side shell; dots always visible per origin/development tip.
    setVis(self.rfSideInfoShell, isSoil or isCs or isFw)
    -- Module page dots always visible (umbrella: dots = N, chrome geometry unchanged).
    setVis(self.rfPanelDotBox, true)
    setVis(self.rfDotLegend, false)
    setVis(self.rfSuiteHint, false)
    setVis(self.rfSideMidSeparator, false)
    setVis(self.wcPageShell, isWc)
    setVis(self.rfFrameworkGlanceShell, isFw)
    setVis(self.rfFwStatusBlock, isFw and isFwStatus)
    setVis(self.rfFwTableBlock, isFw and isFwTable)
    -- Duplex title kill: rfPageTitle owns module name (George 2026-08-05).
    -- Income / Depot densify: rfFwTableTitle is the summary band; do not blank/hide for those panels.
    local fwStatusTitle = self:getDescendantById("rfFwStatusTitle")
    local fwTableTitle = self:getDescendantById("rfFwTableTitle")
    setVis(fwStatusTitle, false)
    if activeId ~= "income" and activeId ~= "fertilizerDepot" then
        setVis(fwTableTitle, false)
    end
    if fwStatusTitle ~= nil and type(fwStatusTitle.setText) == "function" then
        fwStatusTitle:setText("")
    end
    if activeId ~= "income" and activeId ~= "fertilizerDepot" and fwTableTitle ~= nil and type(fwTableTitle.setText) == "function" then
        fwTableTitle:setText("")
    end
    -- Framework overlap FAILFIX: hide page blurb on fw doors (side About owns story).
    setVis(self.rfPageBlurb, not isFw)
    if isFw and self.rfPageBlurb ~= nil and type(self.rfPageBlurb.setText) == "function" then
        self.rfPageBlurb:setText("")
    end
    setVis(self.wcGlanceShell, false)
    self:_refreshSideInfo(activeId)
    -- CS: hide host body so table+detail get room (not isWc alone - body was still on for CS).
    setVis(self.rfHostBody, not isWc and not isCs and not isMd and not isFw)
    -- Keep right hero title/blurb; hide duplicate host title/blurb on WC, MDM and CS.
    setVis(self.rfHostTitle, not isWc and not isMd and not isCs and not isFw)
    setVis(self.rfHostBlurb, not isWc and not isMd and not isCs and not isFw)
    if (isWc or isCs or isMd or isFw) and self.rfHostBody and self.rfHostBody.setText then
        self.rfHostBody:setText("")
    end
    -- Bottom bar: SPACE opens full Market while MDM is active.
    if isMd and self.btnOpenMarket ~= nil then
        self.menuButtonInfo = { self.btnBack, self.btnOpenMarket }
        local trFn = self._rfTr
        if type(trFn) == "function" then
            self.btnOpenMarket.text = trFn("md_rf_pda_open_market", "Open full Market")
        end
    elseif isWc and self.btnOpenWorkerManager ~= nil then
        self.menuButtonInfo = { self.btnBack, self.btnOpenWorkerManager }
    elseif isSoil then
        self.menuButtonInfo = { self.btnBack, self.btnHelp, self.btnRotationPlanner, self.btnFieldDetail }
    else
        self.menuButtonInfo = { self.btnBack }
    end
    if type(self.setMenuButtonInfoDirty) == "function" then
        self:setMenuButtonInfoDirty()
    end
    -- NEVER shrink MODULES dock below workable height (George: >=220).
    local shell = self.rfModuleListShell
    if shell ~= nil then
        if self._rfModuleListShellSizeH == nil then
            local minW = (shell.size and shell.size[1]) or nil
            local minH = (shell.size and shell.size[2]) or nil
            if GuiUtils ~= nil and type(GuiUtils.getNormalizedScreenValues) == "function" then
                local norms = GuiUtils.getNormalizedScreenValues("504px 220px")
                if type(norms) == "table" then
                    minW = norms[1] or minW
                    minH = norms[2] or minH
                end
            end
            self._rfModuleListShellSizeW = minW or (shell.size and shell.size[1])
            self._rfModuleListShellSizeH = minH or (shell.size and shell.size[2])
            if self._rfModuleListShellSizeH == nil then
                -- Last resort: leave height alone on next setSize skip.
                self._rfModuleListShellSizeH = shell.size and shell.size[2]
            end
        end
        local targetW = self._rfModuleListShellSizeW
        local targetH = self._rfModuleListShellSizeH
        if type(shell.setSize) == "function" and targetW ~= nil and targetH ~= nil then
            shell:setSize(targetW, targetH)
        elseif shell.size ~= nil and targetH ~= nil then
            shell.size[2] = targetH
        end
        if shell.updateAbsolutePosition then
            shell:updateAbsolutePosition()
        end
        if shell.setVisible then
            shell:setVisible(true)
        end
    end
    -- Rank 1 containment (George 2026-08-06): force abs after show so shell/gray rect match Texts.
    if self.rfHostPlaceholder ~= nil and type(self.rfHostPlaceholder.updateAbsolutePosition) == "function" then
        self.rfHostPlaceholder:updateAbsolutePosition()
    end
    if isFw then
        if self.rfFrameworkGlanceShell ~= nil and type(self.rfFrameworkGlanceShell.updateAbsolutePosition) == "function" then
            self.rfFrameworkGlanceShell:updateAbsolutePosition()
        end
        if isFwStatus and self.rfFwStatusBlock ~= nil and type(self.rfFwStatusBlock.updateAbsolutePosition) == "function" then
            self.rfFwStatusBlock:updateAbsolutePosition()
        end
        if isFwTable and self.rfFwTableBlock ~= nil and type(self.rfFwTableBlock.updateAbsolutePosition) == "function" then
            self.rfFwTableBlock:updateAbsolutePosition()
        end
    end
    if isWc and self.wcPageShell ~= nil and type(self.wcPageShell.updateAbsolutePosition) == "function" then
        self.wcPageShell:updateAbsolutePosition()
        for _, pid in ipairs({"wcPageDashboard", "wcPageWages", "wcPageWorkers"}) do
            local pe = self[pid] or (self.getDescendantById and self:getDescendantById(pid))
            if pe ~= nil and type(pe.updateAbsolutePosition) == "function" and pe.visible ~= false then
                pe:updateAbsolutePosition()
            end
        end
    end
    if isCs and self.rfHostTableRegion ~= nil and type(self.rfHostTableRegion.updateAbsolutePosition) == "function" then
        self.rfHostTableRegion:updateAbsolutePosition()
    end
    if not isWc then
        self._wcSubnavSeeded = false
        self._wcLastFullPaintPage = nil
        setVis(self.wcPageDashboard, false)
        setVis(self.wcPageWages, false)
        setVis(self.wcPageWorkers, false)
        setVis(self.wcPageAbout, false)
    end
end

--- Active WC page selector = sibling left shell under Brand. Never rfFilterBox; never content-body.
function RfPdaMenuPage:_wcPageSel()
    return self.wcSubnavSelector
end

--- Host-seed WC page labels once on WC enter (never from arrow click; never forceEvent).
function RfPdaMenuPage:_seedWcSubnavTexts()
    local sel = self:_wcPageSel()
    if sel == nil then
        return
    end
    if self._wcSubnavSeeded then
        return
    end
    if sel.setVisible then
        sel:setVisible(true)
    end
    sel.disableButtonsOnSingleText = false
    sel.hideLeftRightButtons = false
    if sel.setCanChangeState then
        sel:setCanChangeState(true)
    end
    if sel.setDisabled then
        sel:setDisabled(false)
    end
    -- Subnav = Dashboard / Wages / Workers only (About retired into wcSideInfoShell).
    local texts = { "Dashboard", "Wages", "Workers" }
    self._wcWageRefreshing = true
    self._wcSubnavSeeding = true
    if sel.setTexts then
        sel:setTexts(texts)
    end
    local idx = tonumber(self.wcSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.wcSubPageIndex = idx
    -- George arrow-crash FAIL-FIX: forceEvent=false - setState(true) re-enters onClick.
    if sel.setState then
        sel:setState(idx, false)
    end
    self._wcSubnavSeeding = false
    self._wcWageRefreshing = false
    self._wcSubnavSeeded = true
    self:_ensureWcSubnavArrowsVisible()
    self:_rebuildWcSubnavDots(3)
    if self.wcSubnavShell ~= nil and self.wcSubnavShell.updateAbsolutePosition then
        self.wcSubnavShell:updateAbsolutePosition()
    end
    if self.rfHostPlaceholder ~= nil and self.rfHostPlaceholder.updateAbsolutePosition then
        self.rfHostPlaceholder:updateAbsolutePosition()
    end
    if sel.updateAbsolutePosition then
        sel:updateAbsolutePosition()
    end
end

--- Contracts page dots under wcSubnavSelector (mirror Brand _rebuildDots; bind to page MTO state).
function RfPdaMenuPage:_rebuildWcSubnavDots(count)
    local dotBox = self.wcSubnavDotBox
    if dotBox == nil or dotBox.elements == nil or #dotBox.elements == 0 then
        return
    end
    if type(dotBox.setVisible) == "function" then
        dotBox:setVisible(true)
    end

    local elements = dotBox.elements
    local expectedCount = math.max(1, count or 1)

    while #elements < expectedCount do
        local seed = elements[1]
        if seed == nil or seed.clone == nil then
            break
        end
        local ok, clone = pcall(function()
            return seed:clone(dotBox)
        end)
        if not ok or clone == nil then
            break
        end
        if FocusManager and FocusManager.loadElementFromCustomValues then
            pcall(FocusManager.loadElementFromCustomValues, FocusManager, clone)
        end
        elements = dotBox.elements
    end

    while #elements > expectedCount do
        local last = elements[#elements]
        if last ~= nil and last.delete then
            last:delete()
        end
        elements = dotBox.elements
    end

    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            local sel = self:_wcPageSel()
            if sel == nil or sel.getState == nil then
                return index == 1
            end
            return sel:getState() == index
        end
        if dot.setVisible then
            dot:setVisible(true)
        end
    end

    if dotBox.invalidateLayout then
        dotBox:invalidateLayout()
    end
    if type(dotBox.updateAbsolutePosition) == "function" then
        dotBox:updateAbsolutePosition()
    end
end

function RfPdaMenuPage:_ensureWcSubnavArrowsVisible()
    self:_ensureMtoArrowsVisible(self:_wcPageSel())
end

--- Wage row MTOs + About tab MTO share Brand/page hit laws (normalized setSize then lime).
function RfPdaMenuPage:_ensureWcWageArrowsVisible()
    local ids = {
        "wcOptEnabled", "wcOptCostMode", "wcOptWageLevel",
        "wcOptNotifications", "wcOptDebugMode", "wcOptMonthlySalary"
    }
    for _, id in ipairs(ids) do
        local sel = self:getDescendantById(id)
        if sel ~= nil then
            -- Optional: stop continuous hold from stealing neighboring rows.
            if sel.registerContinuousInput ~= nil then
                sel.registerContinuousInput = false
            end
            self:_ensureMtoArrowsVisible(sel)
        end
    end
end

function RfPdaMenuPage:_ensureWcAboutArrowsVisible()
    local sel = self:getDescendantById("wcAboutTabSelector")
    self:_ensureMtoArrowsVisible(sel)
end

--- Apply WC secondary page visibility from self.wcSubPageIndex (1..3; About retired).
function RfPdaMenuPage:_syncWcSubPageVisibility()
    local idx = tonumber(self.wcSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.wcSubPageIndex = idx
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.wcPageDashboard, idx == 1)
    setVis(self.wcPageWages, idx == 2)
    setVis(self.wcPageWorkers, idx == 3)
    setVis(self.wcPageAbout, false)
end

--- MDM page selector = sibling left shell under Brand (WC twin).
function RfPdaMenuPage:_mdPageSel()
    return self.mdSubnavSelector
end

function RfPdaMenuPage:_ensureMdSubnavArrowsVisible()
    self:_ensureMtoArrowsVisible(self:_mdPageSel())
end

--- Host-seed MDM page labels once on MDM enter (never forceEvent).
function RfPdaMenuPage:_seedMdSubnavTexts()
    local sel = self:_mdPageSel()
    if sel == nil then
        return
    end
    if self._mdSubnavSeeded then
        return
    end
    local trFn = self._rfTr
    local function t(key, fb)
        if type(trFn) == "function" then
            return trFn(key, fb)
        end
        return fb
    end
    if sel.setVisible then
        sel:setVisible(true)
    end
    sel.disableButtonsOnSingleText = false
    sel.hideLeftRightButtons = false
    if sel.setCanChangeState then
        sel:setCanChangeState(true)
    end
    if sel.setDisabled then
        sel:setDisabled(false)
    end
    local texts = {
        t("md_rf_pda_page_prices", "Prices"),
        t("md_rf_pda_page_events", "Events"),
        t("md_rf_pda_page_contracts", "Contracts"),
    }
    self._mdSubnavSeeding = true
    if sel.setTexts then
        sel:setTexts(texts)
    end
    local idx = tonumber(self.mdSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.mdSubPageIndex = idx
    if sel.setState then
        sel:setState(idx, false)
    end
    self._mdSubnavSeeding = false
    self._mdSubnavSeeded = true
    self:_ensureMdSubnavArrowsVisible()
    self:_rebuildMdSubnavDots(3)
    if self.mdSubnavShell ~= nil and self.mdSubnavShell.updateAbsolutePosition then
        self.mdSubnavShell:updateAbsolutePosition()
    end
    if sel.updateAbsolutePosition then
        sel:updateAbsolutePosition()
    end
end

function RfPdaMenuPage:_rebuildMdSubnavDots(count)
    local dotBox = self.mdSubnavDotBox
    if dotBox == nil or dotBox.elements == nil or #dotBox.elements == 0 then
        return
    end
    if type(dotBox.setVisible) == "function" then
        dotBox:setVisible(true)
    end
    local elements = dotBox.elements
    local expectedCount = math.max(1, count or 1)
    while #elements < expectedCount do
        local seed = elements[1]
        if seed == nil or seed.clone == nil then
            break
        end
        local ok, clone = pcall(function()
            return seed:clone(dotBox)
        end)
        if not ok or clone == nil then
            break
        end
        if FocusManager and FocusManager.loadElementFromCustomValues then
            pcall(FocusManager.loadElementFromCustomValues, FocusManager, clone)
        end
        elements = dotBox.elements
    end
    while #elements > expectedCount do
        local last = elements[#elements]
        if last ~= nil and last.delete then
            last:delete()
        end
        elements = dotBox.elements
    end
    for i, dot in ipairs(dotBox.elements) do
        local index = i
        function dot.getIsSelected()
            local sel = self:_mdPageSel()
            if sel == nil or sel.getState == nil then
                return index == 1
            end
            return sel:getState() == index
        end
        if dot.setVisible then
            dot:setVisible(true)
        end
    end
    if dotBox.invalidateLayout then
        dotBox:invalidateLayout()
    end
    if type(dotBox.updateAbsolutePosition) == "function" then
        dotBox:updateAbsolutePosition()
    end
end

--- Apply MDM secondary page visibility from self.mdSubPageIndex (1..3).
--- TOP mdTableRegion stays visible; only BOTTOM bands swap.
function RfPdaMenuPage:_syncMdSubPageVisibility()
    local idx = tonumber(self.mdSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.mdSubPageIndex = idx
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.mdPricesBand, idx == 1)
    setVis(self.mdEventsBand, idx == 2)
    setVis(self.mdContractsBand, idx == 3)
    setVis(self.mdOpenMarketBtn, idx == 1)
    local btnE = self:getDescendantById("mdOpenMarketBtnEvents")
    local btnC = self:getDescendantById("mdOpenMarketBtnContracts")
    setVis(btnE, idx == 2)
    setVis(btnC, idx == 3)
    if idx == 1 and self.mdGraphArea ~= nil and type(self.mdGraphArea.updateAbsolutePosition) == "function" then
        self.mdGraphArea:updateAbsolutePosition()
    end
end

--- Sibling-shell MDM page MTO. Page index only - never Brand / selectPanel.
function RfPdaMenuPage:onClickMdSubnavSelector()
    if self._mdSubnavSeeding then
        return
    end
    local sel = self:_mdPageSel()
    if sel == nil or sel.getState == nil then
        return
    end
    if sel ~= self.mdSubnavSelector then
        return
    end
    self:_ensureMdSubnavArrowsVisible()
    local idx = sel:getState() or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.mdSubPageIndex = idx
    if sel.setState and sel:getState() ~= idx then
        sel:setState(idx, false)
    end
    self:_syncMdSubPageVisibility()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and active.id == "marketDynamics" and type(active.onShow) == "function" then
        pcall(active.onShow, self.rfHostPlaceholder, true)
    end
end


--- Sibling-shell page MTO. Page index only - never Brand / selectPanel.
function RfPdaMenuPage:onClickWcSubnavSelector()
    if self._wcWageRefreshing or self._wcSubnavSeeding then
        return
    end
    local sel = self:_wcPageSel()
    if sel == nil or sel.getState == nil then
        return
    end
    if sel ~= self.wcSubnavSelector then
        return
    end
    self:_ensureWcSubnavArrowsVisible()
    local idx = sel:getState() or 1
    if idx < 1 then idx = 1 end
    if idx > 3 then idx = 3 end
    self.wcSubPageIndex = idx
    if sel.setState and sel:getState() ~= idx then
        sel:setState(idx, false)
    end
    self:_syncWcSubPageVisibility()
    if self.wcSubPageIndex == 2 then
        self:_ensureWcWageArrowsVisible()
    end
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and active.id == "workerCosts" and type(active.onShow) == "function" then
        pcall(active.onShow, self.rfHostPlaceholder, true)
    end
end

--- Retired title-chrome page MTO (RESTORE): no-op.
function RfPdaMenuPage:onClickWcTitlePageSelector()
    return
end

--- Retired content-body id: no-op.
function RfPdaMenuPage:onClickWcPageSelector()
    return
end

function RfPdaMenuPage:onClickWcAboutTabSelector()
    if self._wcWageRefreshing or self._wcSubnavSeeding then
        return
    end
    self:_ensureWcAboutArrowsVisible()
    if self.getDescendantById then
        local sel = self:getDescendantById("wcAboutTabSelector")
        if sel ~= nil and sel.getState then
            self.wcAboutTabIndex = sel:getState() or 1
        end
    end
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and active.id == "workerCosts" and type(active.onShow) == "function" then
        pcall(active.onShow, self.rfHostPlaceholder, true)
    end
end

--- Forward wage MultiTextOption clicks to Worker Costs guest (settings:save path).
function RfPdaMenuPage:onClickWcWageOption()
    if self._wcWageRefreshing then
        return
    end
    self:_ensureWcWageArrowsVisible()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and type(active.onWageOptionChanged) == "function" then
        pcall(active.onWageOptionChanged, self.rfHostPlaceholder)
    end
end

function RfPdaMenuPage:onClickWcWageReset()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and type(active.onWageReset) == "function" then
        pcall(active.onWageReset, self.rfHostPlaceholder)
    end
end

--- @param rebuildLists boolean|nil when true (default), rebuild field SmoothList data
function RfPdaMenuPage:refreshContent(rebuildLists)
    if rebuildLists == nil then
        rebuildLists = true
    end
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    local panelId = (active ~= nil and active.id) or "soilFertilizer"
    local isSoil = panelId == "soilFertilizer"
    -- Hang-fence: one SmoothList reload per panel enter (module switch uses rebuildLists=false).
    local prevId = self._lastShownPanelId
    local enteringSoil = isSoil and prevId ~= "soilFertilizer"
    local enteringCs = panelId == "seasonalCropStress" and prevId ~= "seasonalCropStress"
    local doSoilListRebuild = rebuildLists or enteringSoil
    local doCsListRebuild = rebuildLists or enteringCs

    self:_refreshPageHeader(active)
    self:_applyChromeL10n()

    if self.rfPanelContent and self.rfPanelContent.setVisible then
        self.rfPanelContent:setVisible(isSoil)
    end
    if self.rfHostPlaceholder and self.rfHostPlaceholder.setVisible then
        self.rfHostPlaceholder:setVisible(not isSoil)
    end

    if isSoil then
        self:_syncHostGuestChrome(nil)
        local panel = soilPanel()
        if panel == nil then
            if not self._rfSoilPanelMissingWarned then
                self._rfSoilPanelMissingWarned = true
                local msg = "[RfEsc] RfPdaSoilPanel missing - Soil table cannot rebuild (cross-mod env)"
                if Logging ~= nil and type(Logging.warning) == "function" then
                    Logging.warning("%s", msg)
                else
                    print(msg)
                end
            end
        else
            -- Always rebuild+reload on Soil show (including enter after non-Soil door create).
            if doSoilListRebuild then
                panel.rebuildFieldData(self)
                if self.selectedFieldId == nil and self.fieldData[1] ~= nil then
                    self.selectedFieldId = self.fieldData[1].fieldId
                end
                panel.reloadFieldList(self)
            elseif self.fieldData == nil or #self.fieldData == 0 then
                -- Safety: empty table after soft refresh - force one rebuild.
                panel.rebuildFieldData(self)
                if self.selectedFieldId == nil and self.fieldData[1] ~= nil then
                    self.selectedFieldId = self.fieldData[1].fieldId
                end
                panel.reloadFieldList(self)
            end
            panel.refreshTreatmentPlan(self)
        end
        if active ~= nil and type(active.onShow) == "function" then
            pcall(active.onShow, self.rfPanelContent)
        end
    else
        self:_syncHostGuestChrome(active and active.id or nil)
        local skipHostDuplex = active ~= nil and (active.id == "workerCosts" or active.id == "marketDynamics" or active.id == "seasonalCropStress")
        if self.rfHostTitle and not skipHostDuplex then
            self.rfHostTitle:setText(safePanelTitle(active))
        elseif self.rfHostTitle and self.rfHostTitle.setText and skipHostDuplex then
            self.rfHostTitle:setText("")
        end
        if self.rfHostBlurb and not skipHostDuplex then
            if active ~= nil and type(active.blurb) == "string" and active.blurb ~= "" then
                local lower = active.blurb:lower()
                if not lower:find("^missing%s") and not lower:find("^missing_") then
                    self.rfHostBlurb:setText(active.blurb)
                else
                    self.rfHostBlurb:setText(tr("rf_pda_host_blurb",
                        "Quick look at this module. Open Farm Tablet for the full tools."))
                end
            else
                self.rfHostBlurb:setText(tr("rf_pda_host_blurb",
                    "Quick look at this module. Open Farm Tablet for the full tools."))
            end
        elseif self.rfHostBlurb and self.rfHostBlurb.setText and skipHostDuplex then
            self.rfHostBlurb:setText("")
        end
        if self.rfHostBody and active ~= nil
            and active.id ~= "workerCosts"
            and active.id ~= "seasonalCropStress"
            and active.id ~= "marketDynamics" then
            self.rfHostBody:setText(tr("rf_pda_host_placeholder",
                "How to: when this module adds Esc detail, use it here. Until then, open Farm Tablet."))
        elseif self.rfHostBody and self.rfHostBody.setText
            and active ~= nil
            and (active.id == "workerCosts" or active.id == "seasonalCropStress") then
            self.rfHostBody:setText("")
        end
        if active ~= nil and active.id == "workerCosts" then
            self:_seedWcSubnavTexts()
            self:_syncWcSubPageVisibility()
            self:_ensureWcSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
            local pageIdx = tonumber(self.wcSubPageIndex) or 1
            if pageIdx == 2 then
                self:_ensureWcWageArrowsVisible()
            end
        end
        if active ~= nil and active.id == "marketDynamics" then
            self:_seedMdSubnavTexts()
            self:_syncMdSubPageVisibility()
            self:_ensureMdSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
        end
        if active ~= nil and type(active.onShow) == "function" then
            if active.id == "seasonalCropStress" then
                -- Full CS field list reload only on enter / rebuildLists (lightOnly otherwise).
                pcall(active.onShow, self.rfHostPlaceholder, not doCsListRebuild)
            else
                pcall(active.onShow, self.rfHostPlaceholder)
            end
        end
        -- Re-assert WC blurb + arrow hits after guest onShow.
        if active ~= nil and active.id == "workerCosts" then
            self:_refreshPageHeader(active)
            self:_ensureWcSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
            local pageIdx = tonumber(self.wcSubPageIndex) or 1
            if pageIdx == 2 then
                self:_ensureWcWageArrowsVisible()
            end
        end
    end

    self._lastShownPanelId = panelId
end

function RfPdaMenuPage:getNumberOfItemsInSection(list, section)
    if list == self.fieldOverviewList then
        return #self.fieldData
    end
    if list == self.csFieldOverviewList then
        return #(self.csFieldData or {})
    end
    if list == self.mdCommodityList then
        return #(self.mdCommodityData or {})
    end
    if list == self.moduleList then
        return #self._panelCache
    end
    return 0
end

function RfPdaMenuPage:populateCellForItemInSection(list, section, index, cell)
    cell.rowDataIndex = index
    if list == self.fieldOverviewList then
        local panel = soilPanel()
        if panel ~= nil then
            panel.populateFieldRow(self, index, cell)
        end
    elseif list == self.csFieldOverviewList then
        self:_populateCsFieldRow(index, cell)
    elseif list == self.mdCommodityList then
        self:_populateMdCommodityRow(index, cell)
    elseif list == self.moduleList then
        self:_populateModuleRow(index, cell)
    end
end

function RfPdaMenuPage:_populateMdCommodityRow(index, cell)
    local entry = (self.mdCommodityData or {})[index]
    if entry == nil then return end
    -- Deep Market twin: Bitmap cropIcon from fillType.hudOverlayFilename; hide if empty (no purple).
    local iconEl = cell:getDescendantByName("cropIcon")
    local nameEl = cell:getDescendantByName("mdCropRowName")
    local priceEl = cell:getDescendantByName("mdCropRowPrice")
    local changeEl = cell:getDescendantByName("mdCropRowChange")
    if iconEl ~= nil then
        local overlay = entry.hudOverlay
        if type(overlay) == "string" and overlay ~= "" then
            if type(iconEl.setImageFilename) == "function" then
                iconEl:setImageFilename(overlay)
            end
            if type(iconEl.setVisible) == "function" then
                iconEl:setVisible(true)
            end
        else
            if type(iconEl.setVisible) == "function" then
                iconEl:setVisible(false)
            end
        end
    end
    if nameEl then nameEl:setText(entry.title or "-") end
    local priceText = "-"
    if entry.price ~= nil then
        if g_i18n and g_i18n.formatMoney then
            priceText = g_i18n:formatMoney(entry.price, 0, true, true)
        else
            priceText = string.format("%.0f", entry.price)
        end
    end
    if priceEl then priceEl:setText(priceText) end
    local pct = tonumber(entry.changePct) or 0
    local changeText
    if pct > 0 then
        changeText = string.format("+%.1f%%", pct)
    else
        changeText = string.format("%.1f%%", pct)
    end
    if changeEl then
        changeEl:setText(changeText)
        if type(changeEl.setTextColor) == "function" then
            if pct > 0.5 then
                changeEl:setTextColor(0.30, 0.80, 0.35, 1)
            elseif pct < -0.5 then
                changeEl:setTextColor(0.90, 0.25, 0.20, 1)
            else
                changeEl:setTextColor(0.70, 0.72, 0.75, 1)
            end
        end
    end
end


function RfPdaMenuPage:_populateCsFieldRow(index, cell)
    local entry = (self.csFieldData or {})[index]
    if entry == nil then return end
    local idEl = cell:getDescendantByName("csFieldRowId")
    local cropEl = cell:getDescendantByName("csFieldRowCrop")
    local moistEl = cell:getDescendantByName("csFieldRowMoisture")
    local stressEl = cell:getDescendantByName("csFieldRowStress")
    local irrEl = cell:getDescendantByName("csFieldRowIrrigated")
    local statusEl = cell:getDescendantByName("csFieldRowStatus")
    if idEl then idEl:setText(entry.fieldLabel or tostring(entry.fieldId or "")) end
    if cropEl then cropEl:setText(entry.cropName or "-") end
    if moistEl then
        moistEl:setText(entry.moistureText or "-")
        if entry.moistureColor and moistEl.setTextColor then
            moistEl:setTextColor(unpack(entry.moistureColor))
        end
    end
    if stressEl then stressEl:setText(entry.stressText or "-") end
    if irrEl then irrEl:setText(entry.irrigatedText or "-") end
    if statusEl then
        statusEl:setText(entry.statusText or "-")
        if entry.statusColor and statusEl.setTextColor then
            statusEl:setTextColor(unpack(entry.statusColor))
        end
    end
end

function RfPdaMenuPage:reloadCsFieldList()
    if self.csFieldOverviewList then
        self.csFieldOverviewList:reloadData()
    end
    if self.csFieldsEmptyHint then
        self.csFieldsEmptyHint:setVisible(#(self.csFieldData or {}) == 0)
    end
end

function RfPdaMenuPage:_populateModuleRow(index, cell)
    local panel = self._panelCache[index]
    if panel == nil then return end
    local titleEl = cell:getDescendantByName("moduleRowTitle")
    local tagEl = cell:getDescendantByName("moduleRowTag")
    local short = safePanelTitle(panel)
    if panel.id == "soilFertilizer" then
        short = tr("rf_pda_module_soil_short", "Soil")
    end
    if titleEl then titleEl:setText(short) end
    if tagEl then
        if panel.id == "soilFertilizer" then
            tagEl:setText(tr("rf_pda_module_tag_host", "open"))
        else
            tagEl:setText(tr("rf_pda_module_tag_loaded", "ready"))
        end
    end
    local host = self:_getHost()
    local selected = host and host.activeModuleId == panel.id
    if titleEl and titleEl.setTextColor then
        titleEl:setTextColor(unpack(selected and COLOR_LIME_BRIGHT or COLOR_DIM))
    end
end

function RfPdaMenuPage:onListSelectionChanged(list, section, index)
    if list == self.fieldOverviewList and index ~= nil and index > 0 then
        local entry = self.fieldData[index]
        if entry ~= nil then
            self.selectedFieldId = entry.fieldId
            local panel = soilPanel()
            if panel ~= nil then
                panel.refreshTreatmentPlan(self)
            end
        end
    elseif list == self.csFieldOverviewList and index ~= nil and index > 0 then
        local entry = (self.csFieldData or {})[index]
        if entry ~= nil then
            self.csSelectedIndex = index
            self.csSelectedFieldId = entry.fieldId
            self:_refreshGuestDetail()
        end
    elseif list == self.mdCommodityList and index ~= nil and index > 0 then
        if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.selectCommodityIndex) == "function" then
            MdRfPdaGuest.selectCommodityIndex(index)
        end
    elseif list == self.moduleList then
        -- Highlight-only: SmoothList ↑↓ must NOT switch modules.
        -- Module switch = onClickModuleRow + Modules MTO (_applySelectorState / cyclePanel).
        return
    end
end

--- Text-only guest band refresh on selection (lightOnly contract; no SmoothList reload).
function RfPdaMenuPage:_refreshGuestDetail()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and active.id ~= "soilFertilizer" and type(active.onShow) == "function" then
        pcall(active.onShow, self.rfHostPlaceholder, true)
    end
end

local function resolveListRowIndex(element)
    local el = element
    local guard = 0
    while el ~= nil and guard < 8 do
        if el.rowDataIndex ~= nil then
            return el.rowDataIndex
        end
        el = el.parent
        guard = guard + 1
    end
    return nil
end

function RfPdaMenuPage:onClickFieldRow(element)
    local index = resolveListRowIndex(element)
    if index == nil or index < 1 then return end
    local entry = self.fieldData[index]
    if entry == nil then return end
    self.selectedFieldId = entry.fieldId
    SoilLogger.info("RfPdaMenuPage: selected field %s", tostring(entry.fieldId))
    local panel = soilPanel()
    if panel ~= nil then
        panel.refreshTreatmentPlan(self)
    end
    if self.fieldOverviewList and self.fieldOverviewList.setSelectedIndex then
        pcall(function() self.fieldOverviewList:setSelectedIndex(index) end)
    end
end

--- Mirror onClickFieldRow for the Crop Stress twin table: select row, refresh band text.
function RfPdaMenuPage:onClickCsFieldRow(element)
    local index = resolveListRowIndex(element)
    if index == nil or index < 1 then return end
    local entry = (self.csFieldData or {})[index]
    if entry == nil then return end
    self.csSelectedIndex = index
    self.csSelectedFieldId = entry.fieldId
    if self.csFieldOverviewList and self.csFieldOverviewList.setSelectedIndex then
        pcall(function() self.csFieldOverviewList:setSelectedIndex(index) end)
    end
    self:_refreshGuestDetail()
end

function RfPdaMenuPage:onClickModuleRow(element)
    local index = resolveListRowIndex(element)
    if index == nil or index < 1 then return end
    self:_selectModuleIndex(index)
end

function RfPdaMenuPage:_selectModuleIndex(index)
    local host = self:_getHost()
    local panel = self._panelCache[index]
    if host == nil or panel == nil then return end
    if self._refreshing then
        return
    end
    if host.activeModuleId ~= panel.id then
        if not self:_allowModuleSelect(panel.id) then
            return
        end
        -- Host notify → refreshPanelSelector with forceEvent=false inside _refreshing
        -- (no MTO onClick bounce back into this path).
        host:selectPanel(panel.id)
        SoilLogger.info("RfPdaMenuPage: moduleList -> %s", tostring(panel.id))
    else
        self:refreshContent(false)
    end
end

function RfPdaMenuPage:getMenuButtonInfo()
    return self.menuButtonInfo
end

function RfPdaMenuPage.show()
    local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
    if inGameMenu == nil then return end
    local page = inGameMenu[RfPdaMenuPage.MENU_PAGE_NAME]
    if page == nil then return end
    g_gui:showGui("InGameMenu")
    inGameMenu:goToPage(page)
end

function RfPdaMenuPage.toggle()
    if g_gui.currentGuiName == "InGameMenu" then
        local inGameMenu = g_gui.screenControllers[InGameMenu] or g_inGameMenu
        if inGameMenu and inGameMenu.currentPage == inGameMenu[RfPdaMenuPage.MENU_PAGE_NAME] then
            g_gui:changeScreen(nil)
            return
        end
    end
    RfPdaMenuPage.show()
end


function RfPdaMenuPage:onClickMdMoverSelector()
    -- Retired movers MTO (kept for nil-safe onClick binding).
    return
end

--- Mirror onClickCsFieldRow for MDM commodities: select row, refresh Prices bottom.
function RfPdaMenuPage:onClickMdCommodityRow(element)
    local index = resolveListRowIndex(element)
    if index == nil or index < 1 then
        return
    end
    if self.mdCommodityList and self.mdCommodityList.setSelectedIndex then
        pcall(function() self.mdCommodityList:setSelectedIndex(index) end)
    end
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.selectCommodityIndex) == "function" then
        MdRfPdaGuest.selectCommodityIndex(index)
    end
end

function RfPdaMenuPage:onClickMdOpenMarket()
    if MdRfPdaGuest ~= nil and type(MdRfPdaGuest.onOpenFullMarket) == "function" then
        MdRfPdaGuest.onOpenFullMarket()
    elseif MDMMarketScreen ~= nil and type(MDMMarketScreen.show) == "function" then
        MDMMarketScreen.show()
    end
end

