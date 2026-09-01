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

local MOD_DIR = (SeasonalCropStressModDirectory or g_currentModDirectory)
local MOD_NAME = (SeasonalCropStressModName or g_currentModName)

-- Soft log when sourced from a non-Soil joiner (SoilLogger may be absent).
-- BUILD 17:08: the stub's signature must match Soil's real logger, which is DOT-called
-- with the format first (src/utils/Logger.lua: function SoilLogger.info(msg, ...)), and
-- every call in this file is dot-style. The old stub took (_, fmt, ...) as if colon-called,
-- so on every non-Soil-hosted door the message landed in the discarded first slot and the
-- log printed only the leftover arguments - or nothing at all. That is why the host's
-- [RfEsc] lines have never appeared in a Dairy-door log, and it would have eaten the
-- selector diagnostics this build ships. pcall on the format so a stray % in a runtime
-- value can never turn a log line into the only traceback on the page.
if SoilLogger == nil then
    local function stubLine(fmt, ...)
        local ok, text = pcall(string.format, fmt or "", ...)
        return "[RfEsc] " .. (ok and text or tostring(fmt))
    end
    SoilLogger = {
        info = function(fmt, ...)
            if Logging and Logging.info then Logging.info(stubLine(fmt, ...)) end
        end,
        warning = function(fmt, ...)
            if Logging and Logging.warning then Logging.warning(stubLine(fmt, ...)) end
        end,
        error = function(fmt, ...)
            if Logging and Logging.error then Logging.error(stubLine(fmt, ...)) end
        end,
    }
end

---@class RfPdaMenuPage
RfPdaMenuPage = RfPdaMenuPage or {}
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
--- BUILD 21:41 cross-mod resolve for Market Dynamics classes.
--- The RfPdaMenuPage that actually runs belongs to whichever mod won the NO-HOST door
--- race, so bare MDMMarketScreenGraph / MdRfPdaGuest are nil in every environment except
--- MarketDynamics' own - that is why the Prices graph vanished when Dairy hosted the door.
--- Same shape as the Open Market resolve below: read the bare global in the caller's env
--- first, then fall back to g_modEnvironments. Never invents a class it cannot find.
---
--- BUILD 22:04: this MUST stay above draw/update/onListSelectionChanged. It was defined
--- near resolveListRowIndex at first, which is ~1900 lines BELOW the draw call, and a Lua
--- local is nil before its definition - so draw called a nil global once per frame and
--- took the Esc rail down with it. Kept next to the other cross-mod resolvers so its
--- ordering requirement is obvious.
local function mdResolve(bare, name)
    -- 1. in-env: free when MarketDynamics itself is the host.
    if bare ~= nil then
        return bare
    end
    -- 2. the named environment. Kept first among the fallbacks because it is the cheapest
    --    and correct in the common case, but NOT trusted alone - this hardcodes a mod name
    --    the guest itself never hardcodes (it uses (SeasonalCropStressModName or g_currentModName)), so a rename or a
    --    differently-named install slips straight past it. That is what produced
    --    "GATE graph=false" on the Dairy door.
    if g_modEnvironments ~= nil then
        -- BUILD 12:59: owner per name. This belt used to hardcode MarketDynamics, so every
        -- other suite class fell straight past it to the scan. Crop Stress and the Market
        -- screen now get the same cheap first-guess Market Dynamics always had.
        local OWNER = {
            MdRfPdaGuest = "FS25_MarketDynamics",
            MDMMarketScreenGraph = "FS25_MarketDynamics",
            MDMMarketScreen = "FS25_MarketDynamics",
            MDMPriceFormat = "FS25_MarketDynamics",
            CsRfPdaGuest = "FS25_SeasonalCropStress",
            NpcRfPdaGuest = "FS25_NPCFavor",
        }
        local env = g_modEnvironments[OWNER[name] or "FS25_MarketDynamics"]
        if env ~= nil and env[name] ~= nil then
            return env[name]
        end
        -- 3. key-independent scan: ask every loaded mod environment whether it carries the
        --    class. No name guessing, so a rename cannot break this belt.
        for _, e in pairs(g_modEnvironments) do
            if type(e) == "table" and e[name] ~= nil then
                return e[name]
            end
        end
    end
    -- 4. _G. BUILD 14:04 (George TASK 10:53): Vera's live gate read via=mission, which
    --    means belts 2 and 3 miss on the live engine (g_modEnvironments carries nothing
    --    there) and getfenv(0) is the per-mod sandbox, not a shared root. _G read from mod
    --    code resolves through the sandbox chain, so when the engine backs it with the real
    --    global table this belt sees a publisher's _G write; when the sandbox loops _G onto
    --    itself it degenerates to the bare lookup and costs one table index.
    if type(_G) == "table" and _G[name] ~= nil then
        return _G[name]
    end
    -- 5. sandbox root: MarketDynamics publishes here from BUILD 11:43.
    local okEnv, root = pcall(getfenv, 0)
    if okEnv and type(root) == "table" and root[name] ~= nil then
        return root[name]
    end
    -- 6. mission handle, same publish. The one belt Vera's live gate has actually seen
    --    resolve on a non-MD door (via=mission), so it must stay last-resort-but-present.
    if g_currentMission ~= nil and g_currentMission[name] ~= nil then
        return g_currentMission[name]
    end
    return nil
end

--- BUILD 14:04 fence for _populateMdCommodityRow: 2dp currency when MDMPriceFormat cannot
--- be resolved at all. George's constraint on the failed probe is "degrades to 2dp path -
--- never formatMoney(..., 0)". This is the Vera-F2 pad rule in miniature (formatNumber and
--- formatMoney both round-then-tostring, so neither ever pads a whole number to .00): split
--- the digits by hand, let formatNumber group the integer half only, take the locale's own
--- decimal mark. No x1000, no litre suffix, no animal test - that display policy lives in
--- MDMPriceFormat and duplicating it here would put two dialects back on screen. This fence
--- should be unreachable: the Prices rows only paint under a registered MD guest, and
--- registration publishes MDMPriceFormat to the mission handle every attempt.
local function mdMoney2(value)
    local rounded = value
    if MathUtil ~= nil and type(MathUtil.round) == "function" then
        rounded = MathUtil.round(value, 2)
    end
    local negative = rounded < 0
    local magnitude = negative and -rounded or rounded
    local whole = math.floor(magnitude)
    local frac = math.floor((magnitude - whole) * 100 + 0.5)
    if frac >= 100 then
        whole = whole + 1
        frac = frac - 100
    end
    local wholeStr = tostring(whole)
    local separator = "."
    local symbol = ""
    if g_i18n ~= nil then
        if type(g_i18n.formatNumber) == "function" then
            wholeStr = g_i18n:formatNumber(whole, 0)
        end
        if type(g_i18n.decimalSeparator) == "string" and g_i18n.decimalSeparator ~= "" then
            separator = g_i18n.decimalSeparator
        end
        if type(g_i18n.getCurrencySymbol) == "function" then
            symbol = g_i18n:getCurrencySymbol(true) or ""
        end
    end
    local out = symbol .. wholeStr .. separator .. string.format("%02d", frac)
    if negative then
        out = "-" .. out
    end
    return out
end

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
    self.csSubPageIndex = 1
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
    self._csSubnavSeeding = false
    self._csSubnavSeeded = false
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
    self.csActionBar = self:getDescendantById("csActionBar") or self.csActionBar
    self.csBtnConsultant = self:getDescendantById("csBtnConsultant") or self.csBtnConsultant
    self.csBtnSchedule = self:getDescendantById("csBtnSchedule") or self.csBtnSchedule
    self.csDetailNoCoverage = self:getDescendantById("csDetailNoCoverage") or self.csDetailNoCoverage
    self.csConsultPanel = self:getDescendantById("csConsultPanel") or self.csConsultPanel
    self.csPivotCard = self:getDescendantById("csPivotCard") or self.csPivotCard
    self.csAgronomistCard = self:getDescendantById("csAgronomistCard") or self.csAgronomistCard
    self.csFieldDetailCard = self:getDescendantById("csFieldDetailCard") or self.csFieldDetailCard
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
    self.csSubnavShell = self:getDescendantById("csSubnavShell") or self.csSubnavShell
    self.csSubnavSelector = self:getDescendantById("csSubnavSelector") or self.csSubnavSelector
    self.csSubnavDotBox = self:getDescendantById("csSubnavDotBox") or self.csSubnavDotBox
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
    self.csSideInfoShell = self:getDescendantById("csSideInfoShell") or self.csSideInfoShell
    self.csSideInfoBody = self:getDescendantById("csSideInfoBody") or self.csSideInfoBody
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
    self.soilColWeed = self:getDescendantById("soilColWeed") or self.soilColWeed
    self.soilColPest = self:getDescendantById("soilColPest") or self.soilColPest
    self.soilColDisease = self:getDescendantById("soilColDisease") or self.soilColDisease
    self.soilSectionTreatment = self:getDescendantById("soilSectionTreatment") or self.soilSectionTreatment
    self.soilTreatProducts = self:getDescendantById("soilTreatProducts") or self.soilTreatProducts
    -- Read-only rotation card (2026-08-07). Nil-safe: older door XML lacks these ids.
    self.soilRotationCard   = self:getDescendantById("soilRotationCard") or self.soilRotationCard
    self.soilRotationTitle  = self:getDescendantById("soilRotationTitle") or self.soilRotationTitle
    self.soilRotationLast   = self:getDescendantById("soilRotationLast") or self.soilRotationLast
    self.soilRotationStatus = self:getDescendantById("soilRotationStatus") or self.soilRotationStatus
    self.soilRotationTip    = self:getDescendantById("soilRotationTip") or self.soilRotationTip
    -- What-if block (2026-08-08). Nil-safe: older door XML lacks these ids.
    self.soilRotationWhatIfHeader = self:getDescendantById("soilRotationWhatIfHeader") or self.soilRotationWhatIfHeader
    self.soilRotationIfColCrop    = self:getDescendantById("soilRotationIfColCrop") or self.soilRotationIfColCrop
    self.soilRotationIfColStatus  = self:getDescendantById("soilRotationIfColStatus") or self.soilRotationIfColStatus
    self.soilRotationIfColEffect  = self:getDescendantById("soilRotationIfColEffect") or self.soilRotationIfColEffect
    self.soilRotationIfRows = {}
    for i = 1, 3 do
        self.soilRotationIfRows[i] = {
            crop   = self:getDescendantById(string.format("soilRotationIf%dCrop", i)),
            status = self:getDescendantById(string.format("soilRotationIf%dStatus", i)),
            effect = self:getDescendantById(string.format("soilRotationIf%dEffect", i)),
        }
    end
    self.treatSelectedLabel = self:getDescendantById("treatSelectedLabel") or self.treatSelectedLabel
    self.treatNextLabel     = self:getDescendantById("treatNextLabel") or self.treatNextLabel
    self.treatTargetsLabel  = self:getDescendantById("treatTargetsLabel") or self.treatTargetsLabel
    self.treatTargetsHeading = self:getDescendantById("treatTargetsHeading") or self.treatTargetsHeading
    self.treatTargetN       = self:getDescendantById("treatTargetN") or self.treatTargetN
    self.treatTargetP       = self:getDescendantById("treatTargetP") or self.treatTargetP
    self.treatTargetK       = self:getDescendantById("treatTargetK") or self.treatTargetK
    self.treatTargetPH      = self:getDescendantById("treatTargetPH") or self.treatTargetPH
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
    setEl(self.soilColFert, "rf_pda_col_fert", "FERT")
    setEl(self.soilColWeed, "sf_pda_col_weeds", "Weeds")
    setEl(self.soilColPest, "sf_pda_col_pests", "Pests")
    setEl(self.soilColDisease, "sf_pda_col_disease", "Disease")
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
            -- BUILD 12:59: this had its own two-belt resolve (in-env, then the hardcoded
            -- MarketDynamics env key) and neither of the belts that actually work - the
            -- getfenv/mission publish. Routed through mdResolve so SPACE and the footer
            -- button share one implementation and one set of five belts.
            local guest = (type(mdResolve) == "function")
                    and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
            if guest ~= nil and type(guest.onOpenFullMarket) == "function" then
                print("[MarketDynamics] Open full Market via resolved MdRfPdaGuest")
                pcall(guest.onOpenFullMarket)
                return
            end
            local scr = (type(mdResolve) == "function")
                    and mdResolve(MDMMarketScreen, "MDMMarketScreen") or MDMMarketScreen
            if scr ~= nil and type(scr.show) == "function" then
                print("[MarketDynamics] Open full Market via resolved MDMMarketScreen")
                pcall(scr.show)
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
    -- Dead candidate: Crop Stress consultant footer chip. Kept constructed so stale
    -- bindings resolve; never assigned to menuButtonInfo (table-hide path VETO).
    self.btnCsConsultant = {
        inputAction = InputAction.MENU_EXTRA_1,
        showWhenPaused = true,
        text = tr("cs_rf_pda_btn_consultant", "Crop consultant"),
        callback = function()
            self:onClickCsConsultant()
        end
    }
    -- CS footer Help (MENU_EXTRA_1). Soft-detects guest onOpenHelp → CsHelpDialog.
    -- Do not reuse Soil btnHelp (wrong dialog content).
    self.btnHelpCs = {
        inputAction = InputAction.MENU_EXTRA_1,
        showWhenPaused = true,
        text = tr("cs_pda_btn_help", "Help"),
        callback = function()
            self:onClickHelpCs()
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
    self._liveTimer = 0
    self._rfSoilPanelMissingWarned = false
    self:_bindHostListener()
    self:_applyChromeL10n()
    -- Module home BEFORE isOpen so select/notify cannot dual-fire refresh + onShow.
    do
        local host = self:_getHost()
        if host ~= nil and type(host.applyHomeModuleQuiet) == "function" then
            pcall(function()
                host:applyHomeModuleQuiet()
            end)
        end
    end
    self.isOpen = true
    -- F11: lime arrows before and after first refresh (engine may disable on open).
    self:_ensureSelectorArrowsVisible()
    self:refreshPanelSelector(true)
    self:refreshContent(true)
    self:_ensureSelectorArrowsVisible()
end

function RfPdaMenuPage:onFrameClose()
    do
        local host = self:_getHost()
        if host ~= nil and host.activeModuleId ~= nil then
            if type(host.rememberClosedModule) == "function" then
                pcall(function()
                    host:rememberClosedModule(host.activeModuleId)
                end)
            else
                host._lastClosedModuleId = host.activeModuleId
                host._userHasChosenModule = true
            end
        end
    end
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
        local graph = (type(mdResolve) == "function")
                and mdResolve(MDMMarketScreenGraph, "MDMMarketScreenGraph") or MDMMarketScreenGraph
        local mdGuest = (type(mdResolve) == "function")
                and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
        -- BUILD 00:10: the outer skip log fires BEFORE any gate. The 22:27 log lived
        -- inside the abs gate, so the one case worth seeing - the gate refusing - printed
        -- nothing at all. Same failure shape as the bug it was meant to diagnose.
        local isMdPrices = active ~= nil and active.id == "marketDynamics" and pageIdx == 1
        if isMdPrices and not self._mdGraphOuterLogged then
            self._mdGraphOuterLogged = true
            local a = self.mdGraphArea
            local b = self.mdPricesBand
            local function box(el)
                if el == nil then return "nil-element" end
                if el.absSize == nil or el.absPosition == nil then return "no-abs" end
                return string.format("%.4fx%.4f at %.4f,%.4f",
                    el.absSize[1] or -1, el.absSize[2] or -1,
                    el.absPosition[1] or -1, el.absPosition[2] or -1)
            end
            local before = box(a)
            if a ~= nil and type(a.updateAbsolutePosition) == "function" then
                pcall(function() a:updateAbsolutePosition() end)
            end
            -- Name the belt that won, so a nil class is immediately attributable rather
            -- than another round of narrowing.
            local via = "nil"
            if graph ~= nil then
                if MDMMarketScreenGraph ~= nil then
                    via = "in-env"
                elseif g_modEnvironments ~= nil and g_modEnvironments["FS25_MarketDynamics"] ~= nil
                        and g_modEnvironments["FS25_MarketDynamics"].MDMMarketScreenGraph ~= nil then
                    via = "modEnv-named"
                else
                    local okE, rootE = pcall(getfenv, 0)
                    if okE and type(rootE) == "table" and rootE.MDMMarketScreenGraph ~= nil then
                        via = "getfenv0"
                    elseif g_currentMission ~= nil and g_currentMission.MDMMarketScreenGraph ~= nil then
                        via = "mission"
                    else
                        via = "modEnv-scan"
                    end
                end
            end
            print(string.format(
                "[MarketDynamics] Esc graph GATE: band=%s area=%s graph=%s via=%s trend=%s draw=%s | area before=%s after=%s | band=%s",
                tostring(b ~= nil), tostring(a ~= nil), tostring(graph ~= nil), via,
                tostring(graph ~= nil and type(graph.drawPriceTrend) == "function"),
                tostring(graph ~= nil and type(graph.draw) == "function"),
                before, box(a), box(b)))
        end

        -- BUILD 11:43: accept either entry point, prefer the shared tree. Gating on
        -- graph.draw alone would refuse a companion that has drawPriceTrend, and the
        -- shared tree is the one both surfaces are supposed to be using.
        local hasTrend = graph ~= nil and type(graph.drawPriceTrend) == "function"
        local hasDraw = graph ~= nil and type(graph.draw) == "function"
        if isMdPrices
                and self.mdPricesBand ~= nil
                and (hasTrend or hasDraw) then
            local area = self.mdGraphArea
            -- Abs-size guard: on the first frame after the band becomes visible the area
            -- can still carry a stale or zero size, which would draw into a degenerate rect.
            if area ~= nil and (area.absSize == nil or area.absPosition == nil
                    or (area.absSize[1] or 0) <= 0 or (area.absSize[2] or 0) <= 0) then
                if type(area.updateAbsolutePosition) == "function" then
                    pcall(function() area:updateAbsolutePosition() end)
                end
            end

            -- BUILD 00:10: if the area is STILL unusable, do not give up silently. Derive a
            -- rect from mdPricesBand and feed the SAME drawPriceTrend. My 21:41 guard failed
            -- closed, which turned a layout-timing problem into a permanently blank panel.
            -- A plot in a slightly generous box is a better answer than no plot, and it is
            -- still the one shared decision tree - no Esc fork, nothing invented.
            local useBand = false
            if area == nil or area.absPosition == nil or area.absSize == nil
                    or (area.absSize[1] or 0) <= 0 or (area.absSize[2] or 0) <= 0 then
                local b = self.mdPricesBand
                if b ~= nil and b.absPosition ~= nil and b.absSize ~= nil
                        and (b.absSize[1] or 0) > 0 and (b.absSize[2] or 0) > 0 then
                    useBand = true
                    if not self._mdGraphBandFallbackLogged then
                        self._mdGraphBandFallbackLogged = true
                        print(string.format(
                            "[MarketDynamics] Esc graph: mdGraphArea unusable, drawing into mdPricesBand rect %.4fx%.4f",
                            b.absSize[1], b.absSize[2]))
                    end
                end
            end

            if useBand or (area ~= nil and area.absPosition ~= nil and area.absSize ~= nil
                    and (area.absSize[1] or 0) > 0 and (area.absSize[2] or 0) > 0) then
                -- Resolve the fill type from the host first, then the guest. Both are asked
                -- because the host copy is set on full show and the guest owns the live pick.
                local ft = self.mdSelectedFillType
                if ft == nil and mdGuest ~= nil and type(mdGuest.getSelectedFillType) == "function" then
                    local okFt, v = pcall(mdGuest.getSelectedFillType)
                    ft = okFt and v or nil
                end
                -- BUILD 23:43: pre-ft skip log. Everything below needs ft, so a nil here is a
                -- silent no-draw; say so once instead of leaving a blank panel unexplained.
                if ft == nil and not self._mdGraphFtLogged then
                    self._mdGraphFtLogged = true
                    print(string.format(
                        "[MarketDynamics] Esc graph SKIP: no fill type resolved (host=%s guest=%s useBand=%s)",
                        tostring(self.mdSelectedFillType), tostring(mdGuest ~= nil), tostring(useBand)))
                end
                if ft ~= nil then
                    local src = useBand and self.mdPricesBand or area
                    local gx = src.absPosition[1]
                    local gy = src.absPosition[2]
                    local gw = src.absSize[1]
                    local gh = src.absSize[2]
                    if useBand then
                        -- Inset the band a little so the plot does not run into its edges.
                        gx = gx + gw * 0.04
                        gy = gy + gh * 0.10
                        gw = gw * 0.92
                        gh = gh * 0.62
                    end
                    local sampleCount = 0
                    if type(graph.getSampleCount) == "function" then
                        sampleCount = graph.getSampleCount(ft) or 0
                    end
                    -- BUILD 23:43: the Esc fork is gone. One shared decision tree lives in
                    -- MDMMarketScreenGraph.drawPriceTrend and the full Market screen calls the
                    -- same one, so the two surfaces cannot disagree about the same crop again.
                    -- The old fork here had no global-sample step and no aggregated-median
                    -- branch, which is why Esc could be blank while Market plotted.
                    local branch = "thin"
                    if type(graph.drawPriceTrend) == "function" then
                        local okB, b = pcall(graph.drawPriceTrend, ft, gx, gy, gw, gh)
                        branch = (okB and b) or "thin"
                    elseif sampleCount >= 2 then
                        -- Companion older than this build: keep the plot rather than blank it.
                        graph.draw(ft, gx, gy, gw, gh)
                        branch = "ring"
                    end
                    if not self._mdGraphLogged then
                        self._mdGraphLogged = true
                        print(string.format(
                            "[MarketDynamics] Esc graph: box=%.1fx%.1f at %.3f,%.3f ft=%s samples=%d branch=%s",
                            gw or -1, gh or -1, gx or -1, gy or -1, tostring(ft), sampleCount, tostring(branch)))
                    end
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
        -- BUILD 21:41: same cross-env resolve as draw. This is the sample ring tick, so
        -- leaving it bare would have kept getSampleCount at 0 under a foreign host even
        -- with the draw fixed, and the graph would have limped on engine history alone.
        local graphUpd = (type(mdResolve) == "function")
                and mdResolve(MDMMarketScreenGraph, "MDMMarketScreenGraph") or MDMMarketScreenGraph
        if pageIdx == 1 and graphUpd ~= nil and type(graphUpd.update) == "function" then
            pcall(graphUpd.update, dt)
        end
        self._mdLiveTimer = (self._mdLiveTimer or 0) + dt
        if self._mdLiveTimer >= REFRESH_INTERVAL then
            self._mdLiveTimer = 0
            -- BUILD 22:27: was a full onShow(.., true) every 2000ms, which ran three
            -- updateAbsolutePosition calls, re-seeded the subnav, re-synced visibility and
            -- re-asserted the selection. Re-laying out the table twice a second is what
            -- kept nudging the scroll. The guest light tick repaints digits only.
            local mdGuest = (type(mdResolve) == "function")
                    and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
            -- Prefer the registered handler; the direct guest is the belt if it was dropped.
            local light = (active ~= nil and type(active.onLightTick) == "function")
                    and active.onLightTick
                    or (mdGuest ~= nil and mdGuest.onLightTick or nil)
            if type(light) == "function" then
                pcall(light, self.rfHostPlaceholder)
            elseif active ~= nil and type(active.onShow) == "function" then
                -- Older MarketDynamics without onLightTick: keep the previous behaviour
                -- rather than silently stop refreshing prices.
                pcall(active.onShow, self.rfHostPlaceholder, true)
            end
        end
        return
    end

    -- One-shot graph log re-arms whenever Market Dynamics is not the active module, so
    -- each visit to Prices reports once instead of once per session.
    self._mdGraphLogged = false
    self._mdGraphFtLogged = false
    self._mdGraphOuterLogged = false
    self._mdGraphBandFallbackLogged = false
    self._mdGuestBeltLogged = false

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

    -- BUILD 17:50 (PB-06). The item count decides everything below this line.
    --
    -- Before 17:50 this helper forced the arrows enabled and full lime unconditionally,
    -- which was the fault it fixed: with a single entry the arrow cannot change state, so
    -- the player saw a bright, clickable-looking arrow that could never act.
    --
    -- 17:50 leaned on disableButtonsOnSingleText to express that. BUILD 20:39 takes it back
    -- off (see the note below the empty-list guard) and drives disabled from here alone.
    -- Line references throughout are
    -- .local/ref/FS25-lua-scripting/elements/MultiTextOptionElement.lua unless named
    -- otherwise. Nothing here is guessed.
    local texts = sel.texts or {}

    -- BUILD 20:39. An empty text list means "not seeded yet", not "one page", and the two
    -- must not be treated the same. Every caller below runs this helper both BEFORE and
    -- AFTER the texts are set, so the early call used to latch the pager disabled from a
    -- count that was about to change - and if the seeding path then failed or threw, the
    -- pager stayed disabled for the rest of the session while the arrows below still got
    -- painted. That is one of the three ways George's TASK 20:38 lime-but-dead read is
    -- reachable. With no texts there is nothing to page through, so write nothing and let
    -- the seeded call decide.
    if #texts == 0 then
        return
    end
    local multi = #texts > 1

    -- BUILD 20:39: disableButtonsOnSingleText stays FALSE (Sam feel lock DESIGN 20:00,
    -- re-stated in BUILD 20:39; the XML declares false on every MTO in this page).
    -- 17:50 read it as a free engine helper, but it is not free: with it true the engine
    -- writes setDisabled(#texts <= 1) from inside updateContentElement (:831-833), and
    -- updateContentElement runs on every setTexts, setState and arrow click. That is a
    -- second writer on the one flag that decides whether the pager takes input at all,
    -- firing on the same frame as our own write - "state reset in the same frame", the
    -- third cause George named. With it false this function is the only writer.
    -- The single-page focus guard 17:50 wanted from it is not lost: canReceiveFocus (:774)
    -- also returns false on a disabled element, and one page still sets disabled below.
    sel.disableButtonsOnSingleText = false
    sel.hideLeftRightButtons = false   -- never remove the control, only dim it
    if sel.setCanChangeState then
        sel:setCanChangeState(multi)
    end
    -- This is the gate that decides whether a click ever reaches the arrows. A disabled
    -- MTO swallows the whole mouse event before it can descend to its buttons:
    -- MultiTextOptionElement:mouseEvent wraps its entire body in getIsActive() (:434) and
    -- GuiElement:getIsActive is "not disabled and visible" (GuiElement.lua:1338-1340).
    -- The GuiOverlay.setColor tint further down does NOT go through that gate, so a
    -- disabled pager still paints lime - which is exactly the reported defect: lime arrows,
    -- dead clicks. Multi-page must therefore end this call with disabled == false.
    if sel.setDisabled then
        sel:setDisabled(not multi)
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
    --
    -- Enabled keeps George's lime. Disabled goes to Samantha's neutral 45% rather than a faded
    -- lime, so "cannot act" reads as absence of colour instead of a dimmed affordance. The
    -- brief writes the enabled state as {1,1,1,1}, which would drop the lime this file already
    -- carries; that is not what PB-06 is about, so the lime stays and the reading is flagged
    -- in the reply rather than decided silently.
    local r, g, b, a
    if multi then
        r, g, b, a = 0.549, 0.776, 0.247, 1
    else
        r, g, b, a = 1, 1, 1, 0.45
    end
    for _, btn in ipairs({ sel.leftButtonElement, sel.rightButtonElement }) do
        if btn ~= nil then
            if btn.setVisible then btn:setVisible(true) end
            if btn.setDisabled then btn:setDisabled(not multi) end
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
--- BUILD 20:39: also the wrap lock for the left-pane pager. Wrap is engine-native and on
--- by default (MultiTextOptionElement.lua:55) - onRightButtonClicked rolls #texts -> 1 and
--- onLeftButtonClicked rolls 1 -> #texts (:670-679 / :721-730) - but XML #wrap and profile
--- "wrap" can both turn it off (:111 / :141), and with it off the last page clamps and the
--- arrow reads dead at exactly one end. The ask is explicit that both ends wrap, so state
--- it rather than inherit it. Set here on the pager only: _ensureMtoArrowsVisible is shared
--- with the WC wage / About / subnav MTOs, and their wrap is not this token's business.
function RfPdaMenuPage:_ensureSelectorArrowsVisible()
    local sel = self.rfPanelSelector
    if sel ~= nil then
        sel.wrap = true
    end
    self:_ensureMtoArrowsVisible(sel)
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

        -- BUILD 20:39: the pre-setTexts ensure call that used to sit here is gone. It fed
        -- _ensureMtoArrowsVisible the PREVIOUS text count - on first open an empty one - so
        -- it decided the pager's disabled state from a number that the next line was about
        -- to replace. The post-setState call below is the one that matters and it stays.
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
    -- BUILD 17:08 diagnostic, one line per real selector input (forceEvent is false on
    -- every internal setState in this file, so this callback only fires for the player).
    -- If a live test still shows dead arrows AND this line never appears in the log, the
    -- click is being consumed ABOVE this page (menu-level), which the in-page shield in
    -- mouseEvent cannot reach - that finding goes to George, not to more host code.
    SoilLogger.info("RfPdaMenuPage: selector input received, state=%s",
        tostring(self.rfPanelSelector ~= nil and self.rfPanelSelector:getState() or "?"))
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
    if panel == nil then
        -- BUILD 20:39: this is the second half of the defect. The arrow has already moved
        -- the label and the dots by the time we get here (the engine advances state, then
        -- raises this callback), so returning empty-handed leaves the page NAME on one
        -- module and the page CONTENT on another - the "content does not move" read. A
        -- cache one module older than the MTO texts is enough to hit it. Re-read the
        -- registry once before giving up.
        local panels = (type(host.getPanels) == "function") and host:getPanels() or nil
        if panels ~= nil then
            self._panelCache = panels
            panel = panels[state]
        end
    end
    if panel == nil then
        -- Still nothing at this index: put the pager back on the page that is actually
        -- showing. An honest snap-back beats a label pointing at a page that never loaded.
        self:_restoreBrandToActivePanel()
        return
    end

    if host.activeModuleId ~= panel.id then
        if not self:_allowModuleSelect(panel.id) then
            -- Refused by the dual-fire debounce. The MTO state has still moved, so snap it
            -- back or label, dots and content stay disagreeing until the next full refresh.
            self:_restoreBrandToActivePanel()
            return
        end
        -- Host notify refreshes selector + content (quiet lists).
        local switched = host:selectPanel(panel.id)
        if switched == false then
            -- Registry refused (module gone or isAvailable false): no notify fires, so
            -- nothing downstream would ever correct the advanced label. Snap it back.
            SoilLogger.warning("RfPdaMenuPage: selectPanel %s refused, restoring pager state",
                tostring(panel.id))
            self:_restoreBrandToActivePanel()
            return
        end
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
    -- BUILD 21:06: CS is back in the Soil-class shell. The 16:44 nest existed only
    -- because the teach painted over FIELDS and the page dots; the subnav that owned
    -- those is retired, so the thing it was avoiding no longer exists. csSideInfoShell
    -- is forced hidden rather than deleted, so a stale nested copy can never surface.
    setVis(self.rfSideInfoShell, isSoil or isCs or isFw)
    setVis(self.csSideInfoShell, false)
    setVis(self.wcSideInfoShell, isWc)
    setVis(self.mdSideInfoShell, isMd)
    setVis(self.rfSuiteHint, false)
    -- BUILD 16:44 item 5: CS teach paints into the nested body under the subnav.
    -- The filter-box body is cleared for CS so a stale sentence cannot survive
    -- behind the new shell if visibility ever flips back.
    -- Nested body is cleared unconditionally now, not just for non-CS.
    if self.csSideInfoBody ~= nil and self.csSideInfoBody.setText then
        self.csSideInfoBody:setText("")
    end
    if self.rfSideInfoBody and self.rfSideInfoBody.setText then
        if isSoil then
            self.rfSideInfoBody:setText(tr("rf_pda_side_info_soil",
                "Soil Fertilizer\n\nThis screen shows the soil on your owned fields. Each line is one field. Press X HELP for the full Field Guide.\n\nThe table shows Field, Area, N, P, K, pH, Status, FERT, Weeds, Pests, and Disease. Status is Good, Fair, or Poor from the worst nutrient or pressure. Work the weakest Status first. When FERT says IN NEED, that field needs fertilizer.\n\nClick a field to open Treatment. PRODUCTS lists what to use, top first. RATE is per area. TOTAL is for the whole field. Next is the first job. Target is healthy. Fix lime or gypsum before nutrients. Dry goes in a spreader. Liquid goes in a sprayer. High Weeds, Pests, or Disease means spray first.\n\nWhat-if lets you try the next crop. Field plan and rotation are on the cards. N falls every harvest. P and K move slower. Organic matter builds over seasons. Aim for pH 6.5 to 7.0. Check worst fields, treat top-down, recheck.\n\nLime raises acid soil. Gypsum lowers alkaline soil. Use N often. Use P and K every few seasons. Press X HELP for lists, HUD tips, and FAQ."))
        elseif isCs then
            self.rfSideInfoBody:setText(tr("rf_pda_side_info_crop_stress",
                "Crop Stress\n\nThis screen is the Crop Stress desk. Each line is one field you own.\n\nThe table shows Field, Crop, Moisture, Stress, Irrigated, and Status. Moisture is how wet the soil is. Stress is how hard the crop is fighting dry spells. Irrigated says a system can reach this field. Status is Healthy, Warning, or Critical.\n\nClick a row. Field Detail on the left coaches that field and Next says the first job. AGRONOMIST on the right lists the top risk fields. PIVOT below drives the irrigation system for the selected field.\n\nOn PIVOT, grey remotes are locked until the step before them is done. Open the door, then power, then the rest. An empty seat means no pivot covers this field.\n\nStart with Critical Status, follow Next, then work up the list.\n\nIrrigator kit (shop): pump + Rainstar + pull bar. Unfold, pull the gun out, turn it on over a field."))
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
    -- BUILD 09:19 (PB-07): the shared row pager is OFF by default, every refresh, for every
    -- module. Only a guest that implements onPageStep turns it back on, from inside its own
    -- onShow, which runs after this. That ordering is what stops the pager following the
    -- player from NPC Favor onto Income or Dairy - those guests do not know the buttons
    -- exist and would never have hidden them.
    for _, id in ipairs({ "rfFwPagePrev", "rfFwPageNext" }) do
        local btn = self:getDescendantById(id)
        if btn ~= nil then
            btn.inputActionName = nil
            btn.keyDisplayText = nil
            btn.keyOverlay = nil
            btn.hideKeyboardGlyph = true
            btn.hasLoadedInputGlyph = false
            btn.isKeyboardMode = false
            btn.keyGlyphOffsetX = 0
            btn.keyGlyphSize = { 0, 0 }
            btn.iconSize = { 0, 0 }
            btn.icon = {}
            if type(btn.setVisible) == "function" then
                btn:setVisible(false)
            end
        end
    end
    -- Action bar rides the CS module only; the guest decides the two buttons.
    setVis(self.csActionBar, isCs)
    if not isCs then
        setVis(self.csBtnSchedule, false)
        setVis(self.csDetailNoCoverage, false)
        setVis(self.csConsultPanel, false)
        setVis(self.csPivotCard, false)
        setVis(self.csAgronomistCard, false)
        self._csConsultOpen = false
    else
        -- BUILD 18:48: the table-hiding consultant view is dead (George HARD VETO).
        -- csConsultPanel is never shown again; the agronomist content moved into the
        -- ROTATION-seat card, and the field table stays visible on every CS subpage.
        -- rfHostTableRegion is still gated above by module id only, which is the gate
        -- George kept; what is banned is the intra-CS swap that emptied the table slot.
        setVis(self.csConsultPanel, false)
        self._csConsultOpen = false
        -- BUILD 21:06: no subnav seeding. _syncCsSubPageVisibility stays because it is
        -- what makes AGRONOMIST and PIVOT co-visible; it never gated on the index.
        self:_syncCsSubPageVisibility()
    end
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
    -- BUILD 21:06: CS subnav RETIRED. Crop Stress is one desk - table, Field Detail,
    -- AGRONOMIST and PIVOT are co-visible - so a Fields | Pivot selector selects nothing.
    -- Never setVisible(true) for CS. WC and MDM subnavs are untouched.
    setVis(self.csSubnavShell, false)
    setVis(self.csSubnavSelector, false)
    setVis(self.csSubnavDotBox, false)
    if self.csSubnavSelector ~= nil then
        if false then
            self.csSubnavSelector.disableButtonsOnSingleText = false
            self.csSubnavSelector.hideLeftRightButtons = false
            if type(self.csSubnavSelector.setDisabled) == "function" then
                self.csSubnavSelector:setDisabled(false)
            end
            if type(self.csSubnavSelector.setCanChangeState) == "function" then
                self.csSubnavSelector:setCanChangeState(true)
            end
            if self.csSubnavShell ~= nil and type(self.csSubnavShell.updateAbsolutePosition) == "function" then
                self.csSubnavShell:updateAbsolutePosition()
            end
            if type(self.csSubnavSelector.updateAbsolutePosition) == "function" then
                self.csSubnavSelector:updateAbsolutePosition()
            end
            if type(self._ensureCsSubnavArrowsVisible) == "function" then
                self:_ensureCsSubnavArrowsVisible()
            end
        else
            self.csSubnavSelector.hideLeftRightButtons = true
            if type(self.csSubnavSelector.setDisabled) == "function" then
                self.csSubnavSelector:setDisabled(true)
            end
            if type(self.csSubnavSelector.setCanChangeState) == "function" then
                self.csSubnavSelector:setCanChangeState(false)
            end
            self._csSubnavSeeded = false
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
    -- BUILD 21:06b (Ash note): this pair used to disagree with _refreshSideInfo below, which
    -- then corrected it 30 lines later. Harmless today - I checked, there is no early return
    -- between here and that call - but two sites stating opposite truths about the same two
    -- elements is a trap waiting for the first person to add one. They agree now.
    setVis(self.rfSideInfoShell, isSoil or isCs or isFw)
    setVis(self.csSideInfoShell, false)
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
    elseif isCs then
        -- BUILD Help restore 2026-08-12: Back + Help. Consultant chip stays off footer.
        self.menuButtonInfo = { self.btnBack, self.btnHelpCs }
        local trFn = self._rfTr
        if type(trFn) == "function" and self.btnHelpCs ~= nil then
            self.btnHelpCs.text = trFn("cs_pda_btn_help", "Help")
        end
    elseif isSoil then
        -- BUILD 18:52: Rotation Planner and Field Detail come off the Soil footer.
        -- Both dialogs stay registered and still open from the PDA/joiner; only the
        -- duplicate bottom-bar buttons go, since the cards now carry that content.
        self.menuButtonInfo = { self.btnBack, self.btnHelp }
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


--- Esc Crop Stress actions. The host never speaks CsDialogLoader (SCS-env-scoped,
--- George binding); it delegates to the active guest, which routes through the
--- CropStress manager. Same shape as onClickWcWageReset.
--- Toggle the inline consultant readout against the field table. Exactly one of
--- {csConsultPanel, rfHostTableRegion} is visible; the host never unloads either,
--- it only flips setVisible, so no list rebuild and no reloadData thrash.
--- Closing consultant restores the same field-row selection (SoT) + PIVOT card.
--- BUILD 18:48: dead by design, kept callable.
--- George HARD VETO on any path that hides rfHostTableRegion to paint consultant
--- content in the main pane. This used to be that path. It is not deleted because
--- the SCS guest still calls it on show and wraps it, and a nil call there would
--- take the whole Crop Stress paint down with it. It now always leaves the field
--- table visible and the old consult panel hidden, whatever it is passed.
function RfPdaMenuPage:setCsConsultView(_open)
    self._csConsultOpen = false
    if self.csConsultPanel ~= nil and self.csConsultPanel.setVisible then
        self.csConsultPanel:setVisible(false)
    end
    if self.rfHostTableRegion ~= nil and self.rfHostTableRegion.setVisible then
        self.rfHostTableRegion:setVisible(true)
    end
    self:_syncCsSubPageVisibility()
end

--- Kept so any stale binding resolves to something inert rather than erroring.
function RfPdaMenuPage:onClickCsConsultant()
    return
end

--- Esc CS Help → guest onOpenHelp → CsHelpDialog (inside SCS env). Never bare CsDialogLoader.
function RfPdaMenuPage:onClickHelpCs()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and type(active.onOpenHelp) == "function" then
        pcall(active.onOpenHelp, self.rfHostPlaceholder)
        return
    end
    local csGuest = (type(mdResolve) == "function")
            and mdResolve(CsRfPdaGuest, "CsRfPdaGuest") or CsRfPdaGuest
    if csGuest ~= nil and type(csGuest.onOpenHelp) == "function" then
        pcall(csGuest.onOpenHelp, self.rfHostPlaceholder)
    end
end

-- ---------------------------------------------------------------------------
-- BUILD 09:19 (PB-07): shared Table-mode row pager.
--
-- rfFwTableBlock is a STATIC eight-row table (rfFwRow1..rfFwRow8) - not a SmoothList - and
-- four guests paint into it: Income, Dairy, NPC Favor and Fertilizer Depot. When a guest has
-- more rows than eight it prints "showing 8 of 11" into rfFwMore and the other three rows
-- were unreachable: no scrollbar, no page control, no route of any kind. Sam's law is that a
-- list which prints a range must be navigable to the end of that range.
--
-- This is a PAGER and deliberately not a SmoothList. George's standing hang lesson is that a
-- SmoothList nested under the Map-style Bitmap shell in this page can hang the frame, and the
-- existing csConsultPanel carries the same NO-GO ("George NO-GO on TextElement.new rebuild,
-- dialog XML nest, or SmoothList"). Two Buttons plus a window offset held by the guest costs
-- no new list machinery and cannot re-enter the layout.
--
-- The host owns only the click. It knows nothing about roster size, page count or labels -
-- it forwards a step to whichever guest is active and then repaints. A guest that does not
-- implement onPageStep is simply not pageable and the buttons stay hidden, which is why the
-- other three Table guests need no change to keep working exactly as before.
-- ---------------------------------------------------------------------------

--- Forward one page step to the active guest, then repaint the page it just moved.
---@param delta number -1 for previous page, +1 for next
---@return boolean moved true when the window moved and a repaint ran
function RfPdaMenuPage:_rfFwPageStep(delta)
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active == nil then
        return false
    end
    local step = active.onPageStep
    -- BUILD 14:04 (Brian TEST 10:29). This is why the live MORE was a painted no-op: the
    -- guest registered onPageStep exactly as BUILD 09:19 described, and
    -- RfEscModules:registerModule silently dropped it - the sixth handler that whitelist
    -- has eaten (onOpenFullMarket, onOpenConsultant/Schedule/Help, onPivotRemote,
    -- onLightTick, onMoverChanged before it). The whitelist now carries onPageStep, and
    -- this belt is the same shape as the 23:51 onLightTick belt directly below in
    -- refreshContent: if the registry instance was created by a mod still running an old
    -- RfEscModules copy, reach the guest class itself rather than shipping a dead button
    -- again. npcFavor is the only pageable guest today, so the belt names it.
    if type(step) ~= "function" and active.id == "npcFavor" then
        local npcGuest = (type(mdResolve) == "function")
                and mdResolve(NpcRfPdaGuest, "NpcRfPdaGuest") or NpcRfPdaGuest
        if npcGuest ~= nil and type(npcGuest.onPageStep) == "function" then
            step = npcGuest.onPageStep
        end
    end
    if type(step) ~= "function" then
        return false
    end
    -- The guest owns the clamp/wrap: it is the only side that knows how many rows it has.
    -- It returns true when the window actually moved, so a click at a hard end does not
    -- trigger a pointless full repaint.
    local ok, moved = pcall(step, delta)
    if not ok then
        SoilLogger.warning("RfPdaMenuPage: onPageStep failed on %s: %s",
            tostring(active.id), tostring(moved))
        return false
    end
    if moved == false then
        return false
    end
    -- Soft refresh: same path the module pager uses, so the guest repaints its rows and its
    -- own footer range without a full enter/rebuild.
    self:refreshContent(false)
    return true
end

function RfPdaMenuPage:onClickRfFwPagePrev()
    self:_rfFwPageStep(-1)
end

function RfPdaMenuPage:onClickRfFwPageNext()
    self:_rfFwPageStep(1)
end

--- 2026-08-22 (Wizard): pager keys are now . / > for next and , / < for back
--- (Space is retired - it collided with the engine's global button-activate and its
--- glyph chip was what overlapped the labels; the buttons themselves now use the
--- glyph-hidden RF_CsPivotBtn profile). keyEvent walks children first via the
--- superclass (GuiElement.lua:772-784, children in reverse order, eventUsed carried),
--- so a focused control that consumes the key wins before this fires and nothing
--- double-steps. Only an unclaimed press reaches the step, and only a step that
--- actually moved marks the event used; on every page without a pageable guest
--- _rfFwPageStep returns false immediately and the key passes through untouched.
--- unicode 46 is ".", 62 is ">", 44 is ",", 60 is "<" - taken from the event's own
--- unicode so keyboard layout does not matter.
function RfPdaMenuPage:keyEvent(unicode, sym, modifier, isDown, eventUsed)
    local used = RfPdaMenuPage:superClass().keyEvent(self, unicode, sym, modifier, isDown, eventUsed)
    if not used and isDown == true and (unicode == 46 or unicode == 62) then
        used = self:_rfFwPageStep(1) == true
    end
    if not used and isDown == true and (unicode == 44 or unicode == 60) then
        used = self:_rfFwPageStep(-1) == true
    end
    return used
end

--- BUILD 17:08 (Brian TEST 16:53, George TASK 17:03 GO): click shield for the module
--- selector. Brian measured both selector arrows hover-highlighting but never advancing,
--- with no Lua traceback. The engine split that allows exactly that: ButtonElement paints
--- its hover state regardless of eventUsed (ButtonElement.lua:450-459) but fires its click
--- only "if not eventUsed" (:469-491), and FocusManager highlight on the MTO is likewise
--- move-driven (MultiTextOptionElement.lua:465-469). So hover-alive-click-dead means the
--- CLICK half of the event is being consumed before the selector's walk position - George's
--- hit-steal read. Event order in this engine is reverse declaration order with no z-index,
--- and Sam's lock forbids moving any geometry, so the fix is delivery order, not layout:
--- the page offers every click that lands inside the selector's rect to the selector FIRST,
--- then runs the normal child walk with the event marked used, so whichever sibling was
--- eating the click can still clear its own pressed state but can no longer act on it.
--- Moves are NOT pre-offered - hover behavior is untouched, and a second visit of the MTO
--- during the normal walk with eventUsed=true only re-computes identical press flags
--- (:441-446, not eventUsed-gated), so nothing double-fires and no wrapper element is
--- introduced. Clicks outside the selector rect take the walk exactly as before, so the
--- module list, FW pager and every guest control keep their ownership.
function RfPdaMenuPage:mouseEvent(posX, posY, isDown, isUp, button, eventUsed)
    local used = eventUsed
    local sel = self.rfPanelSelector
    if not used and (isDown or isUp) and sel ~= nil
        and sel.absPosition ~= nil and sel.absSize ~= nil
        and type(sel.getIsActive) == "function" and sel:getIsActive()
        and GuiUtils ~= nil and type(GuiUtils.checkOverlayOverlap) == "function"
        and GuiUtils.checkOverlayOverlap(posX, posY,
            sel.absPosition[1], sel.absPosition[2], sel.absSize[1], sel.absSize[2], nil) then
        if sel:mouseEvent(posX, posY, isDown, isUp, button, false) then
            used = true
            if not self._selShieldLogged then
                self._selShieldLogged = true
                SoilLogger.info("RfPdaMenuPage: selector click shield delivered its first click")
            end
        end
    end
    return RfPdaMenuPage:superClass().mouseEvent(self, posX, posY, isDown, isUp, button, used) or used
end

function RfPdaMenuPage:_csPageSel()
    return self.csSubnavSelector
end

function RfPdaMenuPage:_ensureCsSubnavArrowsVisible()
    self:_ensureMtoArrowsVisible(self:_csPageSel())
end

--- RETIRED BUILD 21:06. Kept as a no-op because callers may still reference it and
--- because its body called sel:setVisible(true) itself - leaving it live would have
--- re-shown the selector from behind the visibility gate above.
function RfPdaMenuPage:_seedCsSubnavTexts()
    do return end
    local sel = self:_csPageSel()
    if sel == nil then
        return
    end
    if self._csSubnavSeeded then
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
        t("cs_rf_pda_page_fields", "Fields"),
        t("cs_rf_pda_page_pivot", "Pivot"),
    }
    self._csSubnavSeeding = true
    if sel.setTexts then
        sel:setTexts(texts)
    end
    local idx = tonumber(self.csSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 2 then idx = 2 end
    self.csSubPageIndex = idx
    if sel.setState then
        sel:setState(idx, false)
    end
    self._csSubnavSeeding = false
    self._csSubnavSeeded = true
    self:_ensureCsSubnavArrowsVisible()
    self:_rebuildCsSubnavDots(2)
    if self.csSubnavShell ~= nil and self.csSubnavShell.updateAbsolutePosition then
        self.csSubnavShell:updateAbsolutePosition()
    end
    if sel.updateAbsolutePosition then
        sel:updateAbsolutePosition()
    end
end

function RfPdaMenuPage:_rebuildCsSubnavDots(count)
    local dotBox = self.csSubnavDotBox
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
            local sel = self:_csPageSel()
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

--- Esc CS breath (2026-08-09): Agronomist (upper-right) + Pivot (lower-right) are
--- both visible on the CS bottom band. Subnav may still track Fields|Pivot focus,
--- but must not exclusive-hide either card. Table + detail strip stay up; never
--- touch rfHostTableRegion here (table-hide consult remains VETO).
function RfPdaMenuPage:_syncCsSubPageVisibility()
    local idx = tonumber(self.csSubPageIndex) or 1
    if idx < 1 then idx = 1 end
    if idx > 2 then idx = 2 end
    self.csSubPageIndex = idx
    local function setVis(el, visible)
        if el ~= nil and type(el.setVisible) == "function" then
            el:setVisible(visible)
        end
    end
    setVis(self.csAgronomistCard, true)
    setVis(self.csPivotCard, true)
end

--- Sibling-shell CS page MTO. Page index only - never Brand / selectPanel.
--- setState(idx, false): forceEvent re-entry is the WC arrow-crash shape.
function RfPdaMenuPage:onClickCsSubnavSelector()
    -- RETIRED BUILD 21:06: the selector is never visible, so this can only fire from a
    -- stale binding. No-op rather than removed, so the XML onClick target still resolves.
    do return end
    if self._csSubnavSeeding then
        return
    end
    local sel = self:_csPageSel()
    if sel == nil or sel.getState == nil then
        return
    end
    if sel ~= self.csSubnavSelector then
        return
    end
    self:_ensureCsSubnavArrowsVisible()
    local idx = sel:getState() or 1
    if idx < 1 then idx = 1 end
    if idx > 2 then idx = 2 end
    self.csSubPageIndex = idx
    if sel.setState and sel:getState() ~= idx then
        sel:setState(idx, false)
    end
    self:_syncCsSubPageVisibility()
    -- Light onShow only: a full seed here would rebuild the field SmoothList on
    -- every page flick, which is the reload thrash the hang fences ban.
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and active.id == "seasonalCropStress" and type(active.onShow) == "function" then
        pcall(active.onShow, self.rfHostPlaceholder, true)
    end
end

function RfPdaMenuPage:onClickCsSchedule()
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and type(active.onOpenSchedule) == "function" then
        pcall(active.onOpenSchedule, self.rfHostPlaceholder)
    end
end

--- Esc PIVOT remote clicks → guest → CropStressPivotRemoteEvent (server authority).
local function _csPivotRemote(self, action)
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and type(active.onPivotRemote) == "function" then
        pcall(active.onPivotRemote, self.rfHostPlaceholder, action)
    else
        -- BUILD 12:59: resolved rather than bare, so the CS pivot fallback survives a
        -- foreign door the same way the MDM paths do.
        local csGuest = (type(mdResolve) == "function")
                and mdResolve(CsRfPdaGuest, "CsRfPdaGuest") or CsRfPdaGuest
        if csGuest ~= nil and type(csGuest.onPivotRemote) == "function" then
            pcall(csGuest.onPivotRemote, self.rfHostPlaceholder, action)
        end
    end
end

-- [SCS-046] Rain-key clicks. Same host-then-resolved-guest route as the pivot
-- remotes below, but a DIFFERENT handler: these become
-- CropStressRainKeyCommandEvent, never a pivot remote action. Vendored into
-- every host copy of this page, because the Esc page that actually loads is the
-- HOST mod's copy and a button whose onClick name is missing there never paints.
local function _csRainKey(self, token)
    -- [BUILD 15:58] The pcall stays, because a UI click must never take the
    -- menu down, but the error is PRINTED now. A bare pcall here is what made
    -- Fit look like a dead chip: the send threw, the throw was swallowed, and
    -- nothing reached the log, so there was no difference between "the button
    -- is not wired" and "the button threw on every press".
    local function call(fn)
        local ok, err = pcall(fn, self.rfHostPlaceholder, token)
        if not ok then
            print(string.format("[CropStress] Esc rain key %s FAILED: %s",
                tostring(token), tostring(err)))
        end
        return ok
    end
    local host = self:_getHost()
    local active = host and host:getActivePanel()
    if active ~= nil and type(active.onRainKeyCommand) == "function" then
        call(active.onRainKeyCommand)
    else
        local csGuest = (type(mdResolve) == "function")
                and mdResolve(CsRfPdaGuest, "CsRfPdaGuest") or CsRfPdaGuest
        if csGuest ~= nil and type(csGuest.onRainKeyCommand) == "function" then
            call(csGuest.onRainKeyCommand)
        else
            print("[CropStress] Esc rain key IGNORED: no onRainKeyCommand handler resolved")
        end
    end
end

function RfPdaMenuPage:onClickCsPivotFit()       _csRainKey(self, "FIT_TOGGLE") end
function RfPdaMenuPage:onClickCsPivotTripMinus() _csRainKey(self, "TRIP_MINUS") end
function RfPdaMenuPage:onClickCsPivotTripPlus()  _csRainKey(self, "TRIP_PLUS") end

function RfPdaMenuPage:onClickCsPivotDoor()    _csPivotRemote(self, "DOOR_TOGGLE") end
function RfPdaMenuPage:onClickCsPivotPower()   _csPivotRemote(self, "POWER_TOGGLE") end
function RfPdaMenuPage:onClickCsPivotSpray()   _csPivotRemote(self, "SPRAY_TOGGLE") end
function RfPdaMenuPage:onClickCsPivotEndGun()  _csPivotRemote(self, "END_GUN_TOGGLE") end
function RfPdaMenuPage:onClickCsPivotSpeed()   _csPivotRemote(self, "SPEED_CYCLE") end
function RfPdaMenuPage:onClickCsPivotStart()   _csPivotRemote(self, "AUTO_START") end
function RfPdaMenuPage:onClickCsPivotStop()    _csPivotRemote(self, "AUTO_STOP") end
function RfPdaMenuPage:onClickCsPivotMinUp()   _csPivotRemote(self, "SWEEP_MIN_UP") end
function RfPdaMenuPage:onClickCsPivotMinDn()   _csPivotRemote(self, "SWEEP_MIN_DN") end
function RfPdaMenuPage:onClickCsPivotMaxUp()   _csPivotRemote(self, "SWEEP_MAX_UP") end
function RfPdaMenuPage:onClickCsPivotMaxDn()   _csPivotRemote(self, "SWEEP_MAX_DN") end
function RfPdaMenuPage:onClickCsPivotArmPlus() _csPivotRemote(self, "ARM_STEP_PLUS") end
function RfPdaMenuPage:onClickCsPivotArmMinus() _csPivotRemote(self, "ARM_STEP_MINUS") end

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
    local enteringMd = panelId == "marketDynamics" and prevId ~= "marketDynamics"
    local doSoilListRebuild = rebuildLists or enteringSoil
    local doCsListRebuild = rebuildLists or enteringCs
    local doMdListRebuild = rebuildLists or enteringMd

    -- Crop Stress home = field table + AGRONOMIST card (Samantha DESIGN 18:48).
    -- Entering CS always lands on subpage 1; PIVOT is never a sticky home.
    if enteringCs then
        self._csConsultOpen = false
        self.csSubPageIndex = 1
        self._csSubnavSeeded = false
    end

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
        -- BUILD 23:43: subnav seed / visibility sync are enter-and-rebuild work. Running
        -- them on every soft refresh was part of the same churn as the fat onShow.
        if active ~= nil and active.id == "marketDynamics" and doMdListRebuild then
            self:_seedMdSubnavTexts()
            self:_syncMdSubPageVisibility()
            self:_ensureMdSubnavArrowsVisible()
            self:_ensureSelectorArrowsVisible()
            -- BUILD 00:10: lay the graph box out on ENTER. draw() only ever retried it
            -- mid-frame, so a band that had not been positioned yet gave a zero-size area
            -- and the abs gate refused for as long as that lasted. Enter is a full show,
            -- so this is the right place for it and it is not on any light path.
            for _, id in ipairs({"mdPricesBand", "mdGraphArea"}) do
                local el = self:getDescendantById(id)
                if el ~= nil and type(el.updateAbsolutePosition) == "function" then
                    pcall(function() el:updateAbsolutePosition() end)
                end
            end
        end
        if active ~= nil and type(active.onShow) == "function" then
            if active.id == "seasonalCropStress" then
                -- Full CS field list reload only on enter / rebuildLists (lightOnly otherwise).
                -- Guest onShow paints consultant when entering (default-home lock).
                pcall(active.onShow, self.rfHostPlaceholder, not doCsListRebuild)
            elseif active.id == "marketDynamics" then
                -- BUILD 23:43: a soft refreshContent(false) now runs the guest LIGHT tick, not
                -- a lightOnly onShow. lightOnly still re-laid out the table, band and graph and
                -- re-asserted the selection, which is the scroll jump. Enter and explicit
                -- rebuilds keep the full onShow(false).
                if doMdListRebuild then
                    pcall(active.onShow, self.rfHostPlaceholder, false)
                else
                    -- BUILD 23:51 belt: prefer the registered handler, but fall back to the
                    -- guest directly if the registry dropped it. Vera found exactly that -
                    -- active.onLightTick was nil, so the soft path took the fat onShow and
                    -- 23:43 changed nothing where it counted. Never the fat onShow while a
                    -- light tick exists anywhere we can reach it.
                    local light = active.onLightTick
                    if type(light) ~= "function" then
                        local lg = (type(mdResolve) == "function")
                                and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
                        if lg ~= nil and type(lg.onLightTick) == "function" then
                            light = lg.onLightTick
                        end
                    end
                    if type(light) == "function" then
                        pcall(light, self.rfHostPlaceholder)
                    else
                        pcall(active.onShow, self.rfHostPlaceholder, true)
                    end
                end
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
    -- BUILD 09:19 (PB-02). This cell is the one Brian read as "£0" and "£1".
    --
    -- entry.price is the PER-LITRE engine number. formatMoney(price, 0, ...) rounded it to
    -- whole currency units and printed no unit at all, so a live 0.00037/l commodity became
    -- an actionable-looking "£0" and soybean at 0.85/l became "£1". Neither is a zero and
    -- neither says what it is a price OF.
    --
    -- MDMPriceFormat is the single place that decides how a market price is written: the
    -- x1000 display multiply for bulk goods, the forced two decimals built by hand (Vera F2:
    -- neither formatMoney nor formatNumber forcePrecision actually pads .00), the locale
    -- decimal mark, and the " / 1,000L" suffix that animal cargo does NOT get. The full
    -- Market table and the Esc selected-crop line call the same helper, so all three
    -- surfaces print one string and not three dialects of it.
    --
    -- The nil guard matters on this file specifically: this host is mirrored into all nine
    -- doors and only the Market Dynamics zip ships MdPriceFormat.lua. On the other eight
    -- doors MDMPriceFormat is nil UNLESS Market Dynamics is also loaded - and if it is not
    -- loaded there is no Market page to paint anyway. The fallback keeps the old reading
    -- instead of erroring.
    --
    -- BUILD 10:06, Vera FAIL F1. The bare global was doing less than that comment claimed.
    -- It is nil not only when Market Dynamics is absent, but whenever Market Dynamics is not
    -- the mod that WON the door race: FS25 gives every mod its own environment and this
    -- mirrored file executes inside the host's, so on a Dairy-hosted or Income-hosted suite
    -- the bare lookup misses a fully loaded MdPriceFormat.lua and the cell silently drops to
    -- the formatMoney fallback - the exact "GBP 0" reading PB-02 was supposed to have fixed.
    -- Same failure shape, same cause and same cure as MDMMarketScreenGraph on the Dairy door.
    -- Resolved through mdResolve, which is that cure: bare first (free when Market Dynamics
    -- hosts), then the named g_modEnvironments["FS25_MarketDynamics"] entry, then the
    -- name-independent scan and the getfenv(0) / mission belts.
    local priceFormat = (type(mdResolve) == "function")
            and mdResolve(MDMPriceFormat, "MDMPriceFormat") or MDMPriceFormat
    local priceText = "-"
    if entry.price ~= nil then
        if priceFormat ~= nil and type(priceFormat.price) == "function" then
            priceText = priceFormat.price(entry.fillTypeIndex, entry.price)
        else
            -- BUILD 14:04 (Vera FAIL on SUBMIT 10:16). The old branch here was
            -- formatMoney(entry.price, 0, ...), which is the exact GBP 0 / GBP 1 reading
            -- this cell has now shipped twice. George's constraint is verbatim "failed
            -- probe degrades to 2dp path - never formatMoney(..., 0)", so the raw
            -- per-litre number prints at two decimals or it does not print through
            -- an engine rounder at all.
            priceText = mdMoney2(entry.price)
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
        -- Keyboard / controller selection routes through the same real handler as a
        -- click. No highlight-only path on either.
        --
        -- BUILD 13:06 (Vera F1): `active` does not exist in this function - I copied the
        -- registry-first block out of onClickMdCommodityRow, which defines it, and left the
        -- two lines that produce it behind. Worse than a miss: `type(active.selectCommodityIndex)`
        -- INDEXES nil, so arrows and list selection threw every time instead of quietly
        -- falling through. The click path was fine, which is exactly why it read as working.
        local host = self:_getHost()
        local active = host and host.getActivePanel and host:getActivePanel()
        -- Registry first: a guest that registered the callback needs no resolving.
        if active ~= nil and type(active.selectCommodityIndex) == "function" then
            pcall(active.selectCommodityIndex, index)
        else
            local mdGuest = (type(mdResolve) == "function")
                    and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
            self:_mdLogGuestBelt(mdGuest)
            if mdGuest ~= nil and type(mdGuest.selectCommodityIndex) == "function" then
                pcall(mdGuest.selectCommodityIndex, index)
            end
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
    -- BUILD 12:32: the optimistic highlight is gone. SmoothListElement publishes no
    -- setSelectedIndex (established 21:41), so this call never did anything - but it read
    -- as if the click were handled even when the real handler was missing, which is
    -- exactly the wrong impression while the trend was not following the pick.
    local host = self:_getHost()
    local active = host and host.getActivePanel and host:getActivePanel()
    if active ~= nil and type(active.selectCommodityIndex) == "function" then
        pcall(active.selectCommodityIndex, index)
        return
    end
    local mdGuest = (type(mdResolve) == "function")
            and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
    self:_mdLogGuestBelt(mdGuest)
    if mdGuest ~= nil and type(mdGuest.selectCommodityIndex) == "function" then
        pcall(mdGuest.selectCommodityIndex, index)
    end
end

--- One-shot: name the belt the guest resolved through, or say it did not resolve.
--- Same shape as the graph GATE line, because the graph turned out to be findable only
--- once MarketDynamics published it - the guest was one build behind the same lesson.
function RfPdaMenuPage:_mdLogGuestBelt(mdGuest)
    if self._mdGuestBeltLogged then
        return
    end
    self._mdGuestBeltLogged = true
    local via = "nil"
    if mdGuest ~= nil then
        if MdRfPdaGuest ~= nil then
            via = "in-env"
        elseif g_modEnvironments ~= nil and g_modEnvironments["FS25_MarketDynamics"] ~= nil
                and g_modEnvironments["FS25_MarketDynamics"].MdRfPdaGuest ~= nil then
            via = "modEnv-named"
        else
            local okE, rootE = pcall(getfenv, 0)
            if okE and type(rootE) == "table" and rootE.MdRfPdaGuest ~= nil then
                via = "getfenv0"
            elseif g_currentMission ~= nil and g_currentMission.MdRfPdaGuest ~= nil then
                via = "mission"
            else
                via = "modEnv-scan"
            end
        end
    end
    print(string.format(
        "[MarketDynamics] Esc guest: resolved=%s via=%s selectCommodityIndex=%s",
        tostring(mdGuest ~= nil), via,
        tostring(mdGuest ~= nil and type(mdGuest.selectCommodityIndex) == "function")))
end

function RfPdaMenuPage:onClickMdOpenMarket()
    -- BUILD 12:59: was the last bare cross-mod read in this file. Under a foreign door
    -- both names were nil, so the button did nothing at all - silently, which is the
    -- worst version. Registry first, then the resolver, and it cannot throw.
    local host = self:_getHost()
    local active = host and host.getActivePanel and host:getActivePanel()
    if active ~= nil and type(active.onOpenFullMarket) == "function" then
        pcall(active.onOpenFullMarket)
        return
    end
    local guest = (type(mdResolve) == "function")
            and mdResolve(MdRfPdaGuest, "MdRfPdaGuest") or MdRfPdaGuest
    if guest ~= nil and type(guest.onOpenFullMarket) == "function" then
        pcall(guest.onOpenFullMarket)
        return
    end
    local screen = (type(mdResolve) == "function")
            and mdResolve(MDMMarketScreen, "MDMMarketScreen") or MDMMarketScreen
    if screen ~= nil and type(screen.show) == "function" then
        pcall(screen.show)
    end
    -- Companion absent: quiet no-op. "Works alone" means a missing peer is silence,
    -- not an error out of a click handler.
end

