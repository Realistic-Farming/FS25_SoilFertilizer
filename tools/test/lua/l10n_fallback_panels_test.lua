-- l10n_fallback_panels_test.lua - MAINTENANCE rows 59 and 60: the panel sites.
--
-- The repaired sites that live inside draw functions, driven through the shipped
-- draw entry points with the engine's render calls stubbed to capture their text:
--   SoilSettingsPanel:drawSetStatePage / drawSetDiseasePage  the two titles whose
--       keys no language file carries today (row 59's player-visible case: every
--       player saw "Missing 'sf_set_state_title' in l10n_xx.xml"), and the nutrient
--       labels
--   SoilSprayerInfoPanel:draw   the field title format and the no-field line (row 60)
--   SoilHarvesterPanel:draw     the field title format, the t/ha format and the
--       estimate caption (row 60), where the caption is drawn only when its key exists
-- The i18n is the real prelude contract: no locale, an absent key is the engine's
-- sentence, hasText false. No text is registered for a site before its fallback is
-- asserted. The render stubs are output sinks, not a world.
--
-- Groups:
--   P  the settings pages
--   S  the sprayer panel
--   V  the harvester panel
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/utils/SoilUtils.lua, src/utils/SoilL10n.lua, src/ui/SoilSettingsPanel.lua, src/ui/SoilSprayerInfoPanel.lua, src/ui/SoilHarvesterPanel.lua

unpack = unpack or table.unpack

-- Engine render calls: sinks that keep every string drawn.
local drawn = {}
RenderText = RenderText or { ALIGN_LEFT = 0, ALIGN_CENTER = 1, ALIGN_RIGHT = 2 }
function setTextColor() end
function setTextBold() end
function setTextAlignment() end
function setOverlayColor() end
function renderOverlay() end
function getTextWidth() return 0.01 end
function getTextHeight() return 0.01 end
function renderText(_x, _y, _size, text) drawn[#drawn + 1] = tostring(text) end
local function reset() drawn = {} end
local function drawnHas(s) for _, d in ipairs(drawn) do if d:find(s, 1, true) then return true end end return false end
local function drawnSentence() for _, d in ipairs(drawn) do if d:find("Missing '", 1, true) then return d end end return nil end
local function register(key, text) g_i18n:setText(key, text) end
local function unregister(key) g_i18n.texts[key] = nil end

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE SETTINGS PAGES
-- ══════════════════════════════════════════════════════════════════════════
local function newPanel()
    return setmetatable({ _clickRects = {}, mouseX = 0, mouseY = 0,
        setStateFieldId = 12, setStateData = {},
        setDiseaseFieldId = 12, setDiseaseList = { "" }, setDiseaseIdx = 1, setDiseasePressure = 0 },
        { __index = SoilSettingsPanel })
end
do
    T.ok("P0 [world] no language file carries the two title keys, and the prelude carries none either",
        g_i18n:hasText("sf_set_state_title") == false and g_i18n:hasText("sf_set_disease_title") == false)
    reset()
    local ok, err = pcall(SoilSettingsPanel.drawSetStatePage, newPanel())
    T.ok("P1 [reached] the set-state page drew through its shipped entry point (" .. tostring(err) .. ")", ok)
    T.ok("P2 the title is the author's English, with the field", drawnHas("SET FIELD STATE  -  Field #12"))
    T.ok("P3 the nutrient labels are English", drawnHas("Nitrogen (N)") and drawnHas("Phosphorus (P)") and drawnHas("Potassium (K)") and drawnHas("Organic Matter (%)"))
    T.eq("P4 nothing drawn is the engine's missing sentence", drawnSentence(), nil)

    reset()
    ok, err = pcall(SoilSettingsPanel.drawSetDiseasePage, newPanel())
    T.ok("P5 [reached] the set-disease page drew (" .. tostring(err) .. ")", ok)
    T.ok("P6 its title is the author's English", drawnHas("SET FIELD DISEASE  -  Field #12"))
    T.ok("P7 its disease label is English", drawnHas("Disease"))
    T.eq("P8 nothing drawn is the engine's missing sentence", drawnSentence(), nil)

    register("sf_set_state_title", "FELDZUSTAND SETZEN")
    register("sf_map_layer_n", "Stickstoff (N)")
    reset()
    pcall(SoilSettingsPanel.drawSetStatePage, newPanel())
    T.ok("P9 a registered title key translates the title", drawnHas("FELDZUSTAND SETZEN  -  Field #12") and not drawnHas("SET FIELD STATE"))
    T.ok("P10 a registered label key translates that label and no other", drawnHas("Stickstoff (N)") and drawnHas("Phosphorus (P)"))
    unregister("sf_set_state_title"); unregister("sf_map_layer_n")
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE SPRAYER PANEL
-- ══════════════════════════════════════════════════════════════════════════
g_currentMission = g_currentMission or {}
g_currentMission.isRunning = true
FillType = FillType or { UNKNOWN = 0 }
g_fillTypeManager = g_fillTypeManager or { getFillTypeByIndex = function(_, idx) if idx == 5 then return { name = "FERTILIZER", title = "Fertilizer" } end return nil end }

local function newSprayerPanel(fieldId, sprayer)
    local p = SoilSprayerInfoPanel.new(nil, { enabled = true })
    p.initialized = true
    p.editMode = true
    p._fieldId = fieldId
    p._cachedSprayer = sprayer
    return p
end
do
    reset()
    local ok, err = pcall(SoilSprayerInfoPanel.draw, newSprayerPanel(7, nil))
    T.ok("S1 [reached] the sprayer panel drew in edit mode with no sprayer (" .. tostring(err) .. ")", ok)
    T.ok("S2 the title carries the field id plainly when the field format key is absent", drawnHas("Sprayer Panel \194\183 7"))
    T.eq("S3 nothing drawn is the engine's missing sentence", drawnSentence(), nil)
    register("sf_hud_field", "Feld %d")
    reset()
    pcall(SoilSprayerInfoPanel.draw, newSprayerPanel(7, nil))
    T.ok("S4 with the format key registered the title formats the field through it", drawnHas("Sprayer Panel \194\183 Feld 7"))
    unregister("sf_hud_field")

    -- An active sprayer whose product has a profile, on no field yet.
    local sprayer = { spec_sprayer = { workAreaParameters = { sprayFillType = 5 } } }
    reset()
    ok, err = pcall(SoilSprayerInfoPanel.draw, newSprayerPanel(nil, sprayer))
    T.ok("S5 [reached] the sprayer panel drew for an active sprayer with no field (" .. tostring(err) .. ")", ok)
    T.ok("S6 the no-field line is the author's English", drawnHas("Drive onto a field"))
    T.eq("S7 nothing drawn is the engine's missing sentence", drawnSentence(), nil)
    register("sf_sprayer_no_field", "Auf ein Feld fahren")
    reset()
    pcall(SoilSprayerInfoPanel.draw, newSprayerPanel(nil, sprayer))
    T.ok("S8 with the key registered, its text", drawnHas("Auf ein Feld fahren") and not drawnHas("Drive onto a field"))
    unregister("sf_sprayer_no_field")
end

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE HARVESTER PANEL
-- ══════════════════════════════════════════════════════════════════════════
g_fruitTypeManager.getFruitTypeByFillTypeIndex = g_fruitTypeManager.getFruitTypeByFillTypeIndex
    or function(_, idx) if idx == 3 then return { literPerSqm = 1.5, yieldScales = { [5] = 1 } } end return nil end

local function newHarvesterPanel(fieldId, active)
    local p = SoilHarvesterPanel.new(nil, { enabled = true })
    p.initialized = true
    p.editMode = true
    p._fieldId = fieldId
    if active then
        p._cachedCombine = {}
        p._cachedTank = { ratio = 0.5, level = 500, capacity = 1000 }
        p._cachedCropFT = { title = "Wheat", name = "WHEAT", index = 3, massPerLiter = 0.0008 }
        p._fieldInfo = { fieldArea = 2, daysSinceHarvest = 0, yieldEfficiency = 90, growthState = 5 }
    end
    return p
end
do
    reset()
    local ok, err = pcall(SoilHarvesterPanel.draw, newHarvesterPanel(7, false))
    T.ok("V1 [reached] the harvester panel drew in edit mode with no combine (" .. tostring(err) .. ")", ok)
    T.ok("V2 the title carries the field id plainly when the field format key is absent", drawnHas("Harvester Panel \194\183 7"))
    T.eq("V3 nothing drawn is the engine's missing sentence", drawnSentence(), nil)

    reset()
    ok, err = pcall(SoilHarvesterPanel.draw, newHarvesterPanel(7, true))
    T.ok("V4 [reached] the harvester panel drew for an active combine on a field (" .. tostring(err) .. ")", ok)
    T.ok("V5 the estimate formats through the author's English template when the key is absent", drawnHas("10.8 t/ha"))
    T.ok("V6 the estimate's provenance caption is not drawn while its key is absent, rather than drawn as the sentence",
        drawnSentence() == nil)
    register("sf_hud_tha", "%.1f t/ha (est.)")
    register("sf_hud_yield_est_src", "geschaetzt")
    register("sf_hud_field", "Feld %d")
    reset()
    ok, err = pcall(SoilHarvesterPanel.draw, newHarvesterPanel(7, true))
    T.ok("V7 with the keys registered the estimate, the caption and the title all translate (" .. tostring(err) .. ")",
        ok and drawnHas("10.8 t/ha (est.)") and drawnHas("geschaetzt") and drawnHas("Wheat \194\183 Feld 7"))
    unregister("sf_hud_tha"); unregister("sf_hud_yield_est_src"); unregister("sf_hud_field")
end
