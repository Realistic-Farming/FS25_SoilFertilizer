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
    { t="H", k="sf_guide_p1_01", v="WHAT IS THIS MOD" },
    { t="B", k="sf_guide_p1_02", v="Tracks 5 soil nutrients per field across your" },
    { t="B", k="sf_guide_p1_03", v="farm. Crops deplete nutrients on harvest." },
    { t="B", k="sf_guide_p1_04", v="Fertilizer replenishes them. Weather and" },
    { t="B", k="sf_guide_p1_05", v="seasons add realistic pressure over time." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p1_06", v="THE 5 SOIL PARAMETERS" },
    { t="B", k="sf_guide_p1_07", v="N   Nitrogen       Fast depletion. Every harvest." },
    { t="B", k="sf_guide_p1_08", v="P   Phosphorus     Slow depletion. Root crops." },
    { t="B", k="sf_guide_p1_09", v="K   Potassium      Root crops deplete this heavily." },
    { t="B", k="sf_guide_p1_10", v="OM  Organic Matter Builds slowly over many seasons." },
    { t="B", k="sf_guide_p1_11", v="pH  Soil acidity.  Target range: 6.5 \226\128\147 7.0." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p1_12", v="STATUS LEVELS" },
    { t="B", k="sf_guide_p1_13", v="GOOD (green)   At or above crop's optimal target." },
    { t="B", k="sf_guide_p1_14", v="               No action needed this season." },
    { t="B", k="sf_guide_p1_15", v="FAIR (yellow)  Below optimal." },
    { t="B", k="sf_guide_p1_16", v="            -- Plan a top-up. Yield slightly reduced." },
    { t="B", k="sf_guide_p1_17", v="POOR (red)     Below minimum threshold." },
    { t="B", k="sf_guide_p1_18", v="               Act now — yield impact is severe." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Quick start / Tools at a glance
    { t="H", k="sf_guide_p1_19", v="QUICK START (5 STEPS)" },
    { t="B", k="sf_guide_p1_20", v="1. Open PDA (game menu) > Soil & Fertilizer." },
    { t="B", k="sf_guide_p1_21", v="2. Check Farm Overview for red-flagged fields." },
    { t="B", k="sf_guide_p1_22", v="3. Use Treatment Plan to see what's needed." },
    { t="B", k="sf_guide_p1_23", v="4. Apply the right fertilizer product." },
    { t="B", k="sf_guide_p1_24", v="5. Harvest normally — nutrients auto-deduct." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p1_25", v="TOOLS AT A GLANCE" },
    { t="B", k="sf_guide_p1_26", v="HUD Bars       Soil levels for your current field." },
    { t="B", k="sf_guide_p1_27", v="               Key: SF Toggle HUD (Controls > Mods)" },
    { t="B", k="sf_guide_p1_28", v="PDA Screen     Full farm overview + treatment plan." },
    { t="B", k="sf_guide_p1_29", v="               Open via the game's tablet menu." },
    { t="B", k="sf_guide_p1_30", v="Soil Map       Per-cell nutrient colour overlay." },
    { t="B", k="sf_guide_p1_31", v="               Key: SF Toggle Cell Map" },
    { t="B", k="sf_guide_p1_32", v="Field Report   Detailed single-field breakdown." },
    { t="B", k="sf_guide_p1_33", v="               Key: SF Soil Report" },
    { t="B", k="sf_guide_p1_34", v="Smart Sensor   Blocks sections with no active need." },
    { t="B", k="sf_guide_p1_35", v="               Toggles: Alt+1/2/3 in a VWW sprayer." },
    { t="B", k="sf_guide_p1_36", v="See & Spray    Live per-cell pressure in the vehicle." },
    { t="B", k="sf_guide_p1_37", v="               Toggles: Alt+4/5/6 in a VWW sprayer." },
    { t="B", k="sf_guide_p1_38", v="Variable Rate  Auto-adjusts boom rate from deficits." },
    { t="B", k="sf_guide_p1_39", v="               Toggle:  Alt+7.  Enable in Admin." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p1_40", v="KEYBINDINGS" },
    { t="B", k="sf_guide_p1_41", v="All keys ship UNBOUND to avoid conflicts." },
    { t="B", k="sf_guide_p1_42", v="Go to: Options > Controls > Mods" },
    { t="B", k="sf_guide_p1_43", v="Look for actions starting with SF_" },
    { t="B", k="sf_guide_p1_44", v="Assign keys that don't clash with other mods." },
}

SoilGuideDialog.PAGE2 = {
    -- LEFT COLUMN: Bars, tick marks, ghost bar
    { t="H", k="sf_guide_p2_01", v="THE NUTRIENT BARS" },
    { t="B", k="sf_guide_p2_02", v="The HUD shows one bar per nutrient: N P K OM pH." },
    { t="B", k="sf_guide_p2_03", v="Bar fills left (0) to right (100 = maximum)." },
    { t="B", k="sf_guide_p2_04", v="Bar colour tells you status at a glance." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p2_05", v="THE THREE TICK MARKS" },
    { t="B", k="sf_guide_p2_06", v="Every bar has three small vertical tick marks." },
    { t="B", k="sf_guide_p2_07", v="ORANGE tick \226\128\148 Poor/Fair boundary." },
    { t="B", k="sf_guide_p2_08", v="  Bar is RED below this line." },
    { t="B", k="sf_guide_p2_09", v="  Your soil is in POOR condition." },
    { t="B", k="sf_guide_p2_10", v="  Action: apply fertilizer immediately." },
    { t="S", v=" " },
    { t="B", k="sf_guide_p2_11", v="YELLOW tick \226\128\148 Fair/Good boundary." },
    { t="B", k="sf_guide_p2_12", v="  Bar is YELLOW between orange and yellow ticks." },
    { t="B", k="sf_guide_p2_13", v="  Your soil is FAIR \226\128\148 below the crop's optimum." },
    { t="B", k="sf_guide_p2_14", v="  Action: plan a top-up this season." },
    { t="S", v=" " },
    { t="B", k="sf_guide_p2_15", v="CYAN tick \226\128\148 Your planted crop's optimal target." },
    { t="B", k="sf_guide_p2_16", v="  Reach this point for maximum yield." },
    { t="B", k="sf_guide_p2_17", v="  Bar is GREEN when you reach it." },
    { t="B", k="sf_guide_p2_18", v="  Each crop has different N/P/K targets." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p2_19", v="THE GHOST BAR" },
    { t="B", k="sf_guide_p2_20", v="A faint extension of the bar (same colour, dimmer)." },
    { t="B", k="sf_guide_p2_21", v="Shows your projected level AFTER applying the" },
    { t="B", k="sf_guide_p2_22", v="fertilizer currently loaded in your sprayer." },
    { t="B", k="sf_guide_p2_23", v="Drive to a field with a loaded sprayer to see it." },
    { t="B", k="sf_guide_p2_24", v="Use it to avoid wasting fertilizer by over-applying." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Numbers, status colours, tips
    { t="H", k="sf_guide_p2_25", v="READING THE NUMBERS" },
    { t="B", k="sf_guide_p2_26", v="Format:  value  /  target  ( +projected )" },
    { t="B", k="sf_guide_p2_27", v="Example: 245 / 320 (+85)" },
    { t="B", k="sf_guide_p2_28", v="" },
    { t="B", k="sf_guide_p2_29", v="245  = your current nitrogen level in ppm" },
    { t="B", k="sf_guide_p2_30", v="320  = the crop's optimal nitrogen target" },
    { t="B", k="sf_guide_p2_31", v="+85  = how much your sprayer load will add" },
    { t="S", v=" " },
    { t="H", k="sf_guide_p2_32", v="STATUS COLOURS" },
    { t="B", k="sf_guide_p2_33", v="RED bar    Below the orange tick (POOR)." },
    { t="B", k="sf_guide_p2_34", v="           Yield penalty. Apply now." },
    { t="B", k="sf_guide_p2_35", v="YELLOW bar Between orange and yellow ticks (FAIR)." },
    { t="B", k="sf_guide_p2_36", v="           Slight penalty. Plan ahead." },
    { t="B", k="sf_guide_p2_37", v="GREEN bar  Above the yellow tick (GOOD)." },
    { t="B", k="sf_guide_p2_38", v="           At or above crop optimal. No action." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p2_39", v="SMART SYSTEM PANELS (VWW sprayer required)" },
    { t="B", k="sf_guide_p2_40", v="Three panels appear when in a VWW-capable sprayer:" },
    { t="B", k="sf_guide_p2_41", v="Smart Sensor / See & Spray / Variable Rate." },
    { t="B", k="sf_guide_p2_42", v="Enable each via Admin > Smart Systems in Settings." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p2_43", v="FREE PANEL LAYOUT" },
    { t="B", k="sf_guide_p2_44", v="Enable in Settings > Display. Use Shift+H to drag." },
    { t="B", k="sf_guide_p2_45", v="Press [-] in any title bar to collapse a panel." },
}

SoilGuideDialog.PAGE3 = {
    -- LEFT COLUMN: The cycle / daily and weekly habits
    { t="H", k="sf_guide_p3_01", v="THE FARMING CYCLE" },
    { t="B", k="sf_guide_p3_02", v="DEPLETE  Harvest removes N/P/K from soil." },
    { t="B", k="sf_guide_p3_03", v="         The amount depends on crop type and yield." },
    { t="B", k="sf_guide_p3_04", v="REPLENISH Apply fertilizer to restore nutrients." },
    { t="B", k="sf_guide_p3_05", v="BALANCE  pH and OM change slowly over time." },
    { t="B", k="sf_guide_p3_06", v="         Requires long-term management." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p3_07", v="DAILY HABITS" },
    { t="B", k="sf_guide_p3_08", v="1. Glance at the HUD before working a field." },
    { t="B", k="sf_guide_p3_09", v="2. Red bar = apply fertilizer before or after crop." },
    { t="B", k="sf_guide_p3_10", v="3. Yellow bar = note the field, treat this season." },
    { t="B", k="sf_guide_p3_11", v="4. Green bar = carry on, nothing needed." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p3_12", v="WEEKLY ROUTINE" },
    { t="B", k="sf_guide_p3_13", v="Open PDA > Treatment Plan tab." },
    { t="B", k="sf_guide_p3_14", v="Fields are sorted by urgency (worst first)." },
    { t="B", k="sf_guide_p3_15", v="Work top-down \226\128\148 treat highest-priority fields first." },
    { t="B", k="sf_guide_p3_16", v="Click a row to open detailed field view." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p3_17", v="READING THE TREATMENT PLAN" },
    { t="B", k="sf_guide_p3_18", v="Priority scores weigh how far below target each" },
    { t="B", k="sf_guide_p3_19", v="nutrient is. A field in the red on two nutrients" },
    { t="B", k="sf_guide_p3_20", v="ranks higher than one with a single fair level." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Pre/post harvest, seasonal notes
    { t="H", k="sf_guide_p3_21", v="PRE-PLANTING CHECKLIST" },
    { t="B", k="sf_guide_p3_22", v="1. Check N level \226\128\148 depletes every harvest." },
    { t="B", k="sf_guide_p3_23", v="   Apply nitrogen if FAIR or POOR." },
    { t="B", k="sf_guide_p3_24", v="2. Check P and K \226\128\148 change more slowly." },
    { t="B", k="sf_guide_p3_25", v="   Top up if below the fair threshold." },
    { t="B", k="sf_guide_p3_26", v="3. Check pH \226\128\148 lime if acidic, gypsum if alkaline." },
    { t="B", k="sf_guide_p3_27", v="4. Check OM \226\128\148 add manure or compost if low." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p3_28", v="POST-HARVEST ACTIONS" },
    { t="B", k="sf_guide_p3_29", v="1. Nitrogen is depleted \226\128\148 apply fertilizer soon." },
    { t="B", k="sf_guide_p3_30", v="2. Legume crops (soy, clover) add free N" },
    { t="B", k="sf_guide_p3_31", v="   bonus for the NEXT season automatically." },
    { t="B", k="sf_guide_p3_32", v="3. Add manure or compost to build OM long-term." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p3_33", v="SEASONAL NOTES" },
    { t="B", k="sf_guide_p3_34", v="SPRING  N demand peaks. Apply before planting." },
    { t="B", k="sf_guide_p3_35", v="SUMMER  Monitor pest and disease pressure." },
    { t="B", k="sf_guide_p3_36", v="AUTUMN  Avoid heavy N before forecast rain" },
    { t="B", k="sf_guide_p3_37", v="        (rain leaches N from soil)." },
    { t="B", k="sf_guide_p3_38", v="WINTER  Fallow fields slowly recover nutrients." },
    { t="B", k="sf_guide_p3_39", v="        Leave a field bare to let it rest." },
}

SoilGuideDialog.PAGE4 = {
    -- LEFT COLUMN: N, P, K products
    { t="H", k="sf_guide_p4_01", v="NITROGEN (N) PRODUCTS" },
    { t="B", k="sf_guide_p4_02", v="UAN Solution   High N, fast release liquid." },
    { t="B", k="sf_guide_p4_03", v="Urea           High N, standard solid form." },
    { t="B", k="sf_guide_p4_04", v="AMS            Nitrogen + minor sulphur benefit." },
    { t="B", k="sf_guide_p4_05", v="Manure         Moderate N + large OM boost." },
    { t="B", k="sf_guide_p4_06", v="Biosolids      N + P + large OM boost." },
    { t="B", k="sf_guide_p4_07", v="Digestate      Moderate N + light OM benefit." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p4_08", v="PHOSPHORUS (P) PRODUCTS" },
    { t="B", k="sf_guide_p4_09", v="MAP            High P, small N contribution." },
    { t="B", k="sf_guide_p4_10", v="DAP            High P + nitrogen blend." },
    { t="B", k="sf_guide_p4_11", v="Liquid MAP     High P, faster uptake." },
    { t="B", k="sf_guide_p4_12", v="Liquid DAP     High P + N, liquid form." },
    { t="B", k="sf_guide_p4_13", v="Biosolids      P + N + OM. Efficient multi-nutrient." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p4_14", v="POTASSIUM (K) PRODUCTS" },
    { t="B", k="sf_guide_p4_15", v="Potash         High K, solid form." },
    { t="B", k="sf_guide_p4_16", v="Liquid Potash  High K, liquid. Faster uptake." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: pH, OM, tips
    { t="H", k="sf_guide_p4_17", v="pH CORRECTION" },
    { t="B", k="sf_guide_p4_18", v="Target range: 6.5 \226\128\147 7.0 for most crops." },
    { t="B", k="sf_guide_p4_19", v="" },
    { t="B", k="sf_guide_p4_20", v="pH too LOW (acidic, below 6.5):" },
    { t="B", k="sf_guide_p4_21", v="  Apply LIME \226\128\148 raises pH toward neutral." },
    { t="B", k="sf_guide_p4_22", v="pH too HIGH (alkaline, above 7.5):" },
    { t="B", k="sf_guide_p4_23", v="  Apply GYPSUM \226\128\148 lowers pH toward neutral." },
    { t="B", k="sf_guide_p4_24", v="Allow 1\226\128\1472 seasons for full normalization." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p4_25", v="ORGANIC MATTER (OM)" },
    { t="B", k="sf_guide_p4_26", v="Manure         Best OM builder. Also adds N." },
    { t="B", k="sf_guide_p4_27", v="Compost        Moderate OM, well-balanced." },
    { t="B", k="sf_guide_p4_28", v="Biosolids      OM + N + P. Very efficient." },
    { t="B", k="sf_guide_p4_29", v="Digestate      Light OM benefit." },
    { t="B", k="sf_guide_p4_30", v="Fallow (bare field) slowly recovers OM over time." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p4_31", v="APPLICATION TIPS" },
    { t="B", k="sf_guide_p4_32", v="* Load fertilizer and check the ghost bar first." },
    { t="B", k="sf_guide_p4_33", v="  It shows your projected result before you apply." },
    { t="B", k="sf_guide_p4_34", v="* Liquid products generally work faster than solid." },
    { t="B", k="sf_guide_p4_35", v="* Manure improves OM AND adds N \226\128\148 very efficient." },
    { t="B", k="sf_guide_p4_36", v="* Apply liquid N before rain if possible" },
    { t="B", k="sf_guide_p4_37", v="  (rain leaches some nitrogen after application)." },
    { t="B", k="sf_guide_p4_38", v="* Check crop targets for what you're planting" },
    { t="B", k="sf_guide_p4_39", v="  \226\128\148 different crops need different NPK ratios." },
}

SoilGuideDialog.PAGE5 = {
    -- LEFT COLUMN: First 4 Q&As
    { t="H", k="sf_guide_p5_01", v="MY BARS ARE ALWAYS EMPTY — IS IT BROKEN?" },
    { t="B", k="sf_guide_p5_02", v="No. Soil starts at low base levels on a new save." },
    { t="B", k="sf_guide_p5_03", v="A field that was never fertilized shows real values." },
    { t="B", k="sf_guide_p5_04", v="Apply fertilizer to build levels over time." },
    { t="B", k="sf_guide_p5_05", v="This is intentional \226\128\148 it reflects real soil depletion." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p5_06", v="WHERE DO I ASSIGN KEYBOARD SHORTCUTS?" },
    { t="B", k="sf_guide_p5_07", v="Options > Controls > Mods" },
    { t="B", k="sf_guide_p5_08", v="All SF_ keys ship unbound to avoid conflicts" },
    { t="B", k="sf_guide_p5_09", v="with other mods. Find the SF_ actions and" },
    { t="B", k="sf_guide_p5_10", v="assign keys that work for your setup." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p5_11", v="WHY DID MY NITROGEN DROP AFTER RAIN?" },
    { t="B", k="sf_guide_p5_12", v="Heavy rain leaches nitrogen from soil." },
    { t="B", k="sf_guide_p5_13", v="This is intentional and realistic." },
    { t="B", k="sf_guide_p5_14", v="Plan N applications before dry weather," },
    { t="B", k="sf_guide_p5_15", v="not before heavy rain forecasts." },
    { t="B", k="sf_guide_p5_16", v="You can adjust rain sensitivity in Settings." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p5_17", v="WHAT IS THE GHOST BAR?" },
    { t="B", k="sf_guide_p5_18", v="The faint extension on a bar shows how much" },
    { t="B", k="sf_guide_p5_19", v="your loaded sprayer will add if applied here." },
    { t="B", k="sf_guide_p5_20", v="Load a fertilizer into a sprayer, drive to any" },
    { t="B", k="sf_guide_p5_21", v="field, and the ghost bar appears automatically." },
    -- COLUMN BREAK
    { t="COL", v="" },
    -- RIGHT COLUMN: Last 4 Q&As
    { t="H", k="sf_guide_p5_22", v="DO I NEED TO FERTILIZE EVERY SEASON?" },
    { t="B", k="sf_guide_p5_23", v="Nitrogen:    Yes, every season if possible." },
    { t="B", k="sf_guide_p5_24", v="             It depletes heavily on every harvest." },
    { t="B", k="sf_guide_p5_25", v="P and K:     Every 2\226\128\1473 seasons is usually enough." },
    { t="B", k="sf_guide_p5_26", v="Organic OM:  Long-term. Add manure once a year." },
    { t="B", k="sf_guide_p5_27", v="pH:          Only when outside the 6.5\226\128\1477.0 range." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p5_28", v="HOW DO THE SMART SENSOR SYSTEMS WORK?" },
    { t="B", k="sf_guide_p5_29", v="Smart Sensor blocks individual boom sections when" },
    { t="B", k="sf_guide_p5_30", v="no need is detected (no pest, disease, or nutrient" },
    { t="B", k="sf_guide_p5_31", v="deficit). See & Spray shows live pressure per cell." },
    { t="B", k="sf_guide_p5_32", v="Variable Rate adjusts boom output from soil data." },
    { t="B", k="sf_guide_p5_33", v="All 3 need a VWW-capable sprayer. Enable via" },
    { t="B", k="sf_guide_p5_34", v="Settings > Admin > Smart Systems." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p5_35", v="CAN I USE THIS IN MULTIPLAYER?" },
    { t="B", k="sf_guide_p5_36", v="Yes. The mod is fully multiplayer-compatible." },
    { t="B", k="sf_guide_p5_37", v="Soil data is server-authoritative." },
    { t="B", k="sf_guide_p5_38", v="Clients sync on join. Settings changes require" },
    { t="B", k="sf_guide_p5_39", v="admin permissions in multiplayer sessions." },
    { t="S", v=" " },
    { t="H", k="sf_guide_p5_40", v="HOW DOES SOIL AFFECT YIELD?" },
    { t="B", k="sf_guide_p5_41", v="GOOD soil: full yield — no penalty." },
    { t="B", k="sf_guide_p5_42", v="FAIR soil: ~5-15% yield penalty per nutrient." },
    { t="B", k="sf_guide_p5_43", v="POOR soil: up to 40% penalty. Correct it fast." },
    { t="B", k="sf_guide_p5_44", v="Penalties stack: POOR N + FAIR P = severe loss." },
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
        self._elSubtitle:setText(tr("sf_guide_sub_" .. n, SoilGuideDialog.SUBTITLES[n] or ""))
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
                el:setText(row.k and tr(row.k, row.v or "") or (row.v or ""))
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
