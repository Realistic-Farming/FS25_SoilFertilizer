-- =========================================================
-- FS25 Soil & Fertilizer — Multi-Page Field Guide Dialog
-- =========================================================
-- 5 tabs: Overview | HUD Guide | Workflow | Products | F.A.Q.
-- Content tables use {t="H"|"B"|"S"|"COL", v="text"}:
--   H   = section header (gold, bold, uppercase)
--   B   = body line (white, normal)
--   S   = spacer (blank gap)
--   COL = column break — switch from col1 to col2
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilGuideDialog
SoilGuideDialog = {}
local SoilGuideDialog_mt = Class(SoilGuideDialog, ScreenElement)

local SF_GUIDE_MOD_NAME = g_currentModName
local SF_GUIDE_MOD_DIR  = g_currentModDirectory

SoilGuideDialog.INSTANCE = nil

-- ── Page subtitles ─────────────────────────────────────────

SoilGuideDialog.SUBTITLES = {
    "Overview — What this mod tracks and why it matters",
    "HUD Guide — Reading the nutrient bars and on-screen indicators",
    "Workflow — Your daily and seasonal soil management routine",
    "Products — What each fertilizer affects and when to use it",
    "F.A.Q. — Common questions answered",
}

-- ── Page content ───────────────────────────────────────────

SoilGuideDialog.PAGE1 = {
    -- LEFT COLUMN: What is this mod / The 5 parameters
    { t="H", v="WHAT IS THIS MOD" },
    { t="B", v="Tracks 5 soil nutrients per field across your" },
    { t="B", v="farm. Crops deplete nutrients on harvest." },
    { t="B", v="Fertilizer replenishes them. Weather and" },
    { t="B", v="seasons add realistic pressure over time." },
    { t="S", v=" " },
    { t="H", v="THE 5 SOIL PARAMETERS" },
    { t="B", v="N   Nitrogen       Fast depletion. Every harvest." },
    { t="B", v="P   Phosphorus     Slow depletion. Root crops." },
    { t="B", v="K   Potassium      Root crops deplete this heavily." },
    { t="B", v="OM  Organic Matter Builds slowly over many seasons." },
    { t="B", v="pH  Soil acidity.  Target range: 6.5 \226\128\147 7.0." },
    { t="S", v=" " },
    { t="H", v="STATUS LEVELS" },
    { t="B", v="GOOD (green)   At or above crop's optimal target." },
    { t="B", v="               No action needed this season." },
    { t="B", v="FAIR (yellow)  Below optimal. Plan a top-up." },
    { t="B", v="               Yield is slightly reduced." },
    { t="B", v="POOR (red)     Below minimum threshold." },
    { t="B", v="               Act now — yield impact is severe." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Quick start / Tools at a glance
    { t="H", v="QUICK START (5 STEPS)" },
    { t="B", v="1. Open PDA (game menu) > Soil & Fertilizer." },
    { t="B", v="2. Check Farm Overview for red-flagged fields." },
    { t="B", v="3. Use Treatment Plan to see what's needed." },
    { t="B", v="4. Apply the right fertilizer product." },
    { t="B", v="5. Harvest normally — nutrients auto-deduct." },
    { t="S", v=" " },
    { t="H", v="TOOLS AT A GLANCE" },
    { t="B", v="HUD Bars       Soil levels for your current field." },
    { t="B", v="               Key: SF Toggle HUD (Controls > Mods)" },
    { t="B", v="PDA Screen     Full farm overview + treatment plan." },
    { t="B", v="               Open via the game's tablet menu." },
    { t="B", v="Soil Map       Per-cell nutrient colour overlay." },
    { t="B", v="               Key: SF Toggle Cell Map" },
    { t="B", v="Field Report   Detailed single-field breakdown." },
    { t="B", v="               Key: SF Soil Report" },
    { t="S", v=" " },
    { t="H", v="KEYBINDINGS" },
    { t="B", v="All keys ship UNBOUND to avoid conflicts." },
    { t="B", v="Go to: Options > Controls > Mods" },
    { t="B", v="Look for actions starting with SF_" },
    { t="B", v="Assign keys that don't clash with other mods." },
}

SoilGuideDialog.PAGE2 = {
    -- LEFT COLUMN: Bars, tick marks, ghost bar
    { t="H", v="THE NUTRIENT BARS" },
    { t="B", v="The HUD shows one bar per nutrient: N P K OM pH." },
    { t="B", v="Bar fills left (0) to right (100 = maximum)." },
    { t="B", v="Bar colour tells you status at a glance." },
    { t="S", v=" " },
    { t="H", v="THE THREE TICK MARKS" },
    { t="B", v="Every bar has three small vertical tick marks." },
    { t="B", v="ORANGE tick \226\128\148 Poor/Fair boundary." },
    { t="B", v="  Bar is RED below this line." },
    { t="B", v="  Your soil is in POOR condition." },
    { t="B", v="  Action: apply fertilizer immediately." },
    { t="S", v=" " },
    { t="B", v="YELLOW tick \226\128\148 Fair/Good boundary." },
    { t="B", v="  Bar is YELLOW between orange and yellow ticks." },
    { t="B", v="  Your soil is FAIR \226\128\148 below the crop's optimum." },
    { t="B", v="  Action: plan a top-up this season." },
    { t="S", v=" " },
    { t="B", v="CYAN tick \226\128\148 Your planted crop's optimal target." },
    { t="B", v="  Reach this point for maximum yield." },
    { t="B", v="  Bar turns GREEN when you reach it." },
    { t="B", v="  Each crop has different N/P/K targets." },
    { t="S", v=" " },
    { t="H", v="THE GHOST BAR" },
    { t="B", v="A faint extension of the bar (same colour, dimmer)." },
    { t="B", v="Shows your projected level AFTER applying the" },
    { t="B", v="fertilizer currently loaded in your sprayer." },
    { t="B", v="Drive to a field with a loaded sprayer to see it." },
    { t="B", v="Use it to avoid wasting fertilizer by over-applying." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Numbers, status colours, tips
    { t="H", v="READING THE NUMBERS" },
    { t="B", v="Format:  value  /  target  ( +projected )" },
    { t="B", v="Example: 245 / 320 (+85)" },
    { t="B", v="" },
    { t="B", v="245  = your current nitrogen level in ppm" },
    { t="B", v="320  = the crop's optimal nitrogen target" },
    { t="B", v="+85  = how much your sprayer load will add" },
    { t="S", v=" " },
    { t="H", v="STATUS COLOURS" },
    { t="B", v="RED bar    Below the orange tick (POOR)." },
    { t="B", v="           Yield penalty. Apply now." },
    { t="B", v="YELLOW bar Between orange and yellow ticks (FAIR)." },
    { t="B", v="           Slight penalty. Plan ahead." },
    { t="B", v="GREEN bar  Above the yellow tick (GOOD)." },
    { t="B", v="           At or above crop optimal. No action." },
    { t="S", v=" " },
    { t="H", v="TIPS FOR READING THE HUD" },
    { t="B", v="* Bars update for your current field as you move." },
    { t="B", v="* If no crop is planted, cyan tick shows a default" },
    { t="B", v="  reference — plant a crop to see its real target." },
    { t="B", v="* OM and pH bars use the same colour system" },
    { t="B", v="  but have different threshold values." },
    { t="B", v="* Drag the HUD panel to any screen position" },
    { t="B", v="  using the SF HUD Drag keybind." },
}

SoilGuideDialog.PAGE3 = {
    -- LEFT COLUMN: The cycle / daily and weekly habits
    { t="H", v="THE FARMING CYCLE" },
    { t="B", v="DEPLETE  Harvest removes N/P/K from soil." },
    { t="B", v="         The amount depends on crop type and yield." },
    { t="B", v="REPLENISH Apply fertilizer to restore nutrients." },
    { t="B", v="BALANCE  pH and OM change slowly over time." },
    { t="B", v="         Requires long-term management." },
    { t="S", v=" " },
    { t="H", v="DAILY HABITS" },
    { t="B", v="1. Glance at the HUD before working a field." },
    { t="B", v="2. Red bar = apply fertilizer before or after crop." },
    { t="B", v="3. Yellow bar = note the field, treat this season." },
    { t="B", v="4. Green bar = carry on, nothing needed." },
    { t="S", v=" " },
    { t="H", v="WEEKLY ROUTINE" },
    { t="B", v="Open PDA > Treatment Plan tab." },
    { t="B", v="Fields are sorted by urgency (worst first)." },
    { t="B", v="Work top-down \226\128\148 treat highest-priority fields first." },
    { t="B", v="Click a row to open detailed field view." },
    { t="S", v=" " },
    { t="H", v="READING THE TREATMENT PLAN" },
    { t="B", v="Priority scores weigh how far below target each" },
    { t="B", v="nutrient is. A field in the red on two nutrients" },
    { t="B", v="ranks higher than one with a single fair level." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Pre/post harvest, seasonal notes
    { t="H", v="PRE-PLANTING CHECKLIST" },
    { t="B", v="1. Check N level \226\128\148 depletes every harvest." },
    { t="B", v="   Apply nitrogen if FAIR or POOR." },
    { t="B", v="2. Check P and K \226\128\148 change more slowly." },
    { t="B", v="   Top up if below the fair threshold." },
    { t="B", v="3. Check pH \226\128\148 lime if acidic, gypsum if alkaline." },
    { t="B", v="4. Check OM \226\128\148 add manure or compost if low." },
    { t="S", v=" " },
    { t="H", v="POST-HARVEST ACTIONS" },
    { t="B", v="1. Nitrogen is depleted \226\128\148 apply fertilizer soon." },
    { t="B", v="2. Legume crops (soy, clover) add free N" },
    { t="B", v="   bonus for the NEXT season automatically." },
    { t="B", v="3. Add manure or compost to build OM long-term." },
    { t="S", v=" " },
    { t="H", v="SEASONAL NOTES" },
    { t="B", v="SPRING  N demand peaks. Apply before planting." },
    { t="B", v="SUMMER  Monitor pest and disease pressure." },
    { t="B", v="AUTUMN  Avoid heavy N before forecast rain" },
    { t="B", v="        (rain leaches N from soil)." },
    { t="B", v="WINTER  Fallow fields slowly recover nutrients." },
    { t="B", v="        Leave a field bare to let it rest." },
}

SoilGuideDialog.PAGE4 = {
    -- LEFT COLUMN: N, P, K products
    { t="H", v="NITROGEN (N) PRODUCTS" },
    { t="B", v="UAN Solution   High N, fast release liquid." },
    { t="B", v="Urea           High N, standard solid form." },
    { t="B", v="AMS            Nitrogen + minor sulphur benefit." },
    { t="B", v="Manure         Moderate N + large OM boost." },
    { t="B", v="Biosolids      N + P + large OM boost." },
    { t="B", v="Digestate      Moderate N + light OM benefit." },
    { t="S", v=" " },
    { t="H", v="PHOSPHORUS (P) PRODUCTS" },
    { t="B", v="MAP            High P, small N contribution." },
    { t="B", v="DAP            High P + nitrogen blend." },
    { t="B", v="Liquid MAP     High P, faster uptake." },
    { t="B", v="Liquid DAP     High P + N, liquid form." },
    { t="B", v="Biosolids      P + N + OM. Efficient multi-nutrient." },
    { t="S", v=" " },
    { t="H", v="POTASSIUM (K) PRODUCTS" },
    { t="B", v="Potash         High K, solid form." },
    { t="B", v="Liquid Potash  High K, liquid. Faster uptake." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: pH, OM, tips
    { t="H", v="pH CORRECTION" },
    { t="B", v="Target range: 6.5 \226\128\147 7.0 for most crops." },
    { t="B", v="" },
    { t="B", v="pH too LOW (acidic, below 6.5):" },
    { t="B", v="  Apply LIME \226\128\148 raises pH toward neutral." },
    { t="B", v="pH too HIGH (alkaline, above 7.5):" },
    { t="B", v="  Apply GYPSUM \226\128\148 lowers pH toward neutral." },
    { t="B", v="Allow 1\226\128\1472 seasons for full normalization." },
    { t="S", v=" " },
    { t="H", v="ORGANIC MATTER (OM)" },
    { t="B", v="Manure         Best OM builder. Also adds N." },
    { t="B", v="Compost        Moderate OM, well-balanced." },
    { t="B", v="Biosolids      OM + N + P. Very efficient." },
    { t="B", v="Digestate      Light OM benefit." },
    { t="B", v="Fallow (bare field) slowly recovers OM over time." },
    { t="S", v=" " },
    { t="H", v="APPLICATION TIPS" },
    { t="B", v="* Load fertilizer and check the ghost bar first." },
    { t="B", v="  It shows your projected result before you apply." },
    { t="B", v="* Liquid products generally work faster than solid." },
    { t="B", v="* Manure improves OM AND adds N \226\128\148 very efficient." },
    { t="B", v="* Apply liquid N before rain if possible" },
    { t="B", v="  (rain leaches some nitrogen after application)." },
    { t="B", v="* Check crop targets for what you're planting" },
    { t="B", v="  \226\128\148 different crops need different NPK ratios." },
}

SoilGuideDialog.PAGE5 = {
    -- LEFT COLUMN: First 4 Q&As
    { t="H", v="MY BARS ARE ALWAYS EMPTY — IS IT BROKEN?" },
    { t="B", v="No. Soil starts at low base levels on a new save." },
    { t="B", v="A field that was never fertilized shows real values." },
    { t="B", v="Apply fertilizer to build levels over time." },
    { t="B", v="This is intentional \226\128\148 it reflects real soil depletion." },
    { t="S", v=" " },
    { t="H", v="WHERE DO I ASSIGN KEYBOARD SHORTCUTS?" },
    { t="B", v="Options > Controls > Mods" },
    { t="B", v="All SF_ keys ship unbound to avoid conflicts" },
    { t="B", v="with other mods. Find the SF_ actions and" },
    { t="B", v="assign keys that work for your setup." },
    { t="S", v=" " },
    { t="H", v="WHY DID MY NITROGEN DROP AFTER RAIN?" },
    { t="B", v="Heavy rain leaches nitrogen from soil." },
    { t="B", v="This is intentional and realistic." },
    { t="B", v="Plan N applications before dry weather," },
    { t="B", v="not before heavy rain forecasts." },
    { t="B", v="You can adjust rain sensitivity in Settings." },
    { t="S", v=" " },
    { t="H", v="WHAT IS THE GHOST BAR?" },
    { t="B", v="The faint extension on a bar shows how much" },
    { t="B", v="your loaded sprayer will add if applied here." },
    { t="B", v="Load a fertilizer into a sprayer, drive to any" },
    { t="B", v="field, and the ghost bar appears automatically." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Last 4 Q&As
    { t="H", v="DO I NEED TO FERTILIZE EVERY SEASON?" },
    { t="B", v="Nitrogen:    Yes, every season if possible." },
    { t="B", v="             It depletes heavily on every harvest." },
    { t="B", v="P and K:     Every 2\226\128\1473 seasons is usually enough." },
    { t="B", v="Organic OM:  Long-term. Add manure once a year." },
    { t="B", v="pH:          Only when outside the 6.5\226\128\1477.0 range." },
    { t="S", v=" " },
    { t="H", v="THE OVERLAY MAP LOOKS WRONG / BLANK" },
    { t="B", v="Assign SF Cycle Map Layer in Controls > Mods." },
    { t="B", v="Press it to cycle: N > P > K > OM > pH views." },
    { t="B", v="Click any map cell to see exact values." },
    { t="B", v="Your current field position loads automatically." },
    { t="S", v=" " },
    { t="H", v="CAN I USE THIS IN MULTIPLAYER?" },
    { t="B", v="Yes. The mod is fully multiplayer-compatible." },
    { t="B", v="Soil data is server-authoritative." },
    { t="B", v="Clients sync on join. Settings changes require" },
    { t="B", v="admin permissions in multiplayer sessions." },
    { t="S", v=" " },
    { t="H", v="HOW DO I OPEN SETTINGS?" },
    { t="B", v="Assign SF Open Settings in Controls > Mods." },
    { t="B", v="Or open via: PDA > Soil tab > Settings button." },
    { t="B", v="Settings include difficulty, rain effects, disease" },
    { t="B", v="climate, and per-feature toggles." },
}

SoilGuideDialog.PAGE_CONTENT = {
    SoilGuideDialog.PAGE1,
    SoilGuideDialog.PAGE2,
    SoilGuideDialog.PAGE3,
    SoilGuideDialog.PAGE4,
    SoilGuideDialog.PAGE5,
}

-- ── i18n helper ───────────────────────────────────────────

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_GUIDE_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Constructor ───────────────────────────────────────────

function SoilGuideDialog.new(target, customMt)
    local self = ScreenElement.new(target, customMt or SoilGuideDialog_mt)
    self._contentLineEls = {}
    self._currentPage    = 1
    return self
end

function SoilGuideDialog.register(modDirectory)
    if SoilGuideDialog.INSTANCE ~= nil then return end

    SF_GUIDE_MOD_DIR = modDirectory
    local xmlPath = modDirectory .. "xml/gui/SoilGuideDialog.xml"

    SoilGuideDialog.INSTANCE = SoilGuideDialog.new()
    SoilLogger.info("SoilGuideDialog: registering from %s", xmlPath)

    local ok, err = pcall(function()
        g_gui:loadGui(xmlPath, "SoilGuideDialog", SoilGuideDialog.INSTANCE)
    end)

    if not ok then
        SoilLogger.error("SoilGuideDialog: loadGui failed: %s", tostring(err))
        SoilGuideDialog.INSTANCE = nil
    else
        SoilLogger.info("SoilGuideDialog: registered successfully")
    end
end

function SoilGuideDialog.show()
    if SoilGuideDialog.INSTANCE == nil then
        SoilGuideDialog.register(SF_GUIDE_MOD_DIR)
    end
    if SoilGuideDialog.INSTANCE == nil then return end
    g_gui:showDialog("SoilGuideDialog")
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilGuideDialog:onGuiSetupFinished()
    SoilGuideDialog:superClass().onGuiSetupFinished(self)
    self._elCol1     = self:getDescendantById("sfGuide_col1")
    self._elCol2     = self:getDescendantById("sfGuide_col2")
    self._elSubtitle = self:getDescendantById("sfGuide_subtitle")
end

function SoilGuideDialog:onOpen()
    SoilGuideDialog:superClass().onOpen(self)
    self._currentPage = 1
    self:_selectPage(1)
end

function SoilGuideDialog:onClose()
    SoilGuideDialog:superClass().onClose(self)
    self:_clearContent()
    self._currentPage = 1
end

-- ── Tab callbacks ─────────────────────────────────────────

function SoilGuideDialog:onClickTab1() self:_selectPage(1) end
function SoilGuideDialog:onClickTab2() self:_selectPage(2) end
function SoilGuideDialog:onClickTab3() self:_selectPage(3) end
function SoilGuideDialog:onClickTab4() self:_selectPage(4) end
function SoilGuideDialog:onClickTab5() self:_selectPage(5) end

-- ── Page switching ────────────────────────────────────────

function SoilGuideDialog:_selectPage(n)
    if self._currentPage == n and #self._contentLineEls > 0 then return end

    self:_clearContent()
    self._currentPage = n

    if self._elSubtitle then
        self._elSubtitle:setText(SoilGuideDialog.SUBTITLES[n] or "")
    end

    self:_buildContent(n)
end

-- ── Content builder ───────────────────────────────────────

function SoilGuideDialog:_buildContent(pageNum)
    local profileH = g_gui:getProfile("sfGuide_colHeader")
    local profileB = g_gui:getProfile("sfGuide_colBody")
    local profileS = g_gui:getProfile("sfGuide_colSpacer")

    if not profileH or not profileB then
        SoilLogger.warning("SoilGuideDialog: sfGuide column profiles not found")
        return
    end

    local CONTENT = SoilGuideDialog.PAGE_CONTENT[pageNum]
    if not CONTENT then return end

    local currentBox = self._elCol1

    for _, row in ipairs(CONTENT) do
        if row.t == "COL" then
            if self._elCol1 then self._elCol1:invalidateLayout() end
            currentBox = self._elCol2
        elseif currentBox then
            local profile = (row.t == "H") and profileH
                         or (row.t == "S") and profileS
                         or profileB

            if profile then
                local el = TextElement.new()
                el:loadProfile(profile, true)
                el:setText(row.v)
                currentBox:addElement(el)
                el:onGuiSetupFinished()
                table.insert(self._contentLineEls, { box = currentBox, el = el })
            end
        end
    end

    if self._elCol2 then self._elCol2:invalidateLayout() end
end

function SoilGuideDialog:_clearContent()
    for _, entry in ipairs(self._contentLineEls) do
        if entry.box then
            entry.box:removeElement(entry.el)
        end
    end
    self._contentLineEls = {}
    if self._elCol1 then self._elCol1:invalidateLayout() end
    if self._elCol2 then self._elCol2:invalidateLayout() end
end

-- ── Button ────────────────────────────────────────────────

function SoilGuideDialog:onClickClose()
    g_gui:closeDialogByName("SoilGuideDialog")
end
