-- MAINT-89-l10n_call_site_keys_test.lua
--
-- MAINTENANCE row 89: every key the mod reads at a translation call site ships in
-- every language file. The engine loads ONE file per language (mods.lua:788-793) and
-- has no per-key English fallback, so an ungated getText on a key a language lacks
-- shows the engine's "Missing '...'" sentence (I18N.lua:186), and a gated tr() shows
-- the code's English. Row 89 found 14 keys missing from some files (two from every
-- file, English included), 12 more the mod owns in no file at all, and 40 map and
-- report keys Czech lacks. The PR adds them, translated by hand per language (never
-- by translations/lang_sync.py, which stamps English over every translation).
--
-- A TEXT BAR, READ FROM THE REAL CALL SITES. The key list is not written here: it is
-- scanned out of the shipped sources (--!text below), every literal key passed to
-- getText, hasText, tr, SoilL10n.tr, _tr, t or _text, the same call forms the row's
-- measurement grepped. The language files are the shipped translations/*.xml. A key
-- added at a call site tomorrow without its translations fails group C. fengari has
-- no file IO, so the runner hands both over as text; nothing is parsed by hand.
--
-- Left out, and why:
--   * src/ui/RfPdaMenuPage.lua, the Esc door page every door mod ships byte-for-byte;
--     its l10n (cs_rf_pda_page_fields, cs_rf_pda_page_pivot and the three shared menu
--     keys) is MAINTENANCE row 79's coordinated repair across the ten door mods.
--   * A key built by concatenation ("sf_chem_" .. id): not a literal, not a key.
--   * The engine's own keys (button_back and the like): only sf_, rf_ and cs_ keys
--     are the mod's.
--
-- Groups:
--   C  every call-site key, in each of the 27 files (one row per language)
--   N  the row's named sets: the 14 no-file keys in all 27, the rotation N/A in all
--      27, the Czech 40, the French 9, the Chinese (Simplified, "cs") 5
--   F  every added value carries its English format specifiers in the same order
--   S  the added sentences are translations: none is the English text, none is an
--      "[EN]" stamp
--
--!text: src/HarvestContractUnderwrite.lua, src/SoilFertilityManager.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/hooks/SoilMapHooks.lua, src/network/NetworkEvents.lua, src/settings/SoilSettingsUI.lua, src/specializations/SFNozzleEffects.lua, src/ui/RfPdaSoilMerge.lua, src/ui/RfPdaSoilPanel.lua, src/ui/RfSoilEscJoiner.lua, src/ui/RotationPlannerData.lua, src/ui/RotationPlannerDialog.lua, src/ui/SoilFieldDetailDialog.lua, src/ui/SoilGuideDialog.lua, src/ui/SoilHUD.lua, src/ui/SoilHandfulDialog.lua, src/ui/SoilHarvesterPanel.lua, src/ui/SoilMapOverlay.lua, src/ui/SoilPDAScreen.lua, src/ui/SoilReleaseDialog.lua, src/ui/SoilScoutDialog.lua, src/ui/SoilSettingsPanel.lua, src/ui/SoilSmartSensorPanel.lua, src/ui/SoilSprayerInfoPanel.lua, src/ui/SoilTreatmentDialog.lua, src/ui/SoilTreatmentRates.lua, src/ui/SoilVariableRatePanel.lua, src/ui/SoilVersionDialog.lua, translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml

local SOURCES = {}
local LANGS = {}
for path in pairs(SOURCE_TEXT) do
    local lang = path:match("^translations/translation_(%a%a)%.xml$")
    if lang then LANGS[#LANGS + 1] = lang
    elseif path:find("^src/") then SOURCES[#SOURCES + 1] = path end
end
table.sort(LANGS)
table.sort(SOURCES)

-- The call forms the row measured: getText, hasText, tr, SoilL10n.tr, _tr, t, _text.
local function isTranslationCall(name)
    return name == "tr" or name == "t"
        or name:sub(-3) == "_tr" or name:sub(-5) == "_text"
        or name:sub(-7) == "getText" or name:sub(-7) == "hasText"
end

--- Every literal mod key read at a call site (key -> the first file that reads it),
--- and each file's own set.
local function callSiteKeys()
    local keys, count, byFile = {}, 0, {}
    for _, path in ipairs(SOURCES) do
        byFile[path] = {}
        local text = SOURCE_TEXT[path]
        for chain, key, after in string.gmatch(text, "([%w_%.:]+)%(%s*\"([%w_]+)\"(%s*%.?%.?)") do
            local name = chain:match("([%w_]+)$")
            local ours = key:find("^sf_") or key:find("^rf_") or key:find("^cs_")
            if name and isTranslationCall(name) and ours and not after:find("%.%.") then
                byFile[path][key] = true
                if keys[key] == nil then
                    keys[key] = path
                    count = count + 1
                end
            end
        end
    end
    return keys, count, byFile
end

--- A language file's entries: key -> the raw v= attribute.
local function entries(lang)
    local out = {}
    local text = SOURCE_TEXT["translations/translation_" .. lang .. ".xml"]
    for k, v in string.gmatch(text, "<e k=\"([^\"]+)\"%s+v=\"([^\"]*)\"") do out[k] = v end
    return out
end

local FILES = {}
for _, lang in ipairs(LANGS) do FILES[lang] = entries(lang) end

local function sortedKeys(set)
    local list = {}
    for k in pairs(set) do list[#list + 1] = k end
    table.sort(list)
    return list
end

local KEYS, NKEYS, BYFILE = callSiteKeys()

-- ── the scan read something ─────────────────────────────────────────────
-- Not acceptance evidence: a guard against a vacuous pass (a scan that found no call
-- site would make every C row green).
T.eq("C0 the bar read 29 sources and 27 language files", #SOURCES .. "/" .. #LANGS, "29/27")
T.ok("C0b the scan found the call sites (" .. NKEYS .. " literal keys), including the row's ungated getText sites",
    NKEYS > 300 and BYFILE["src/ui/SoilSmartSensorPanel.lua"]["sf_sensor_pest"] == true
        and BYFILE["src/ui/SoilVariableRatePanel.lua"]["sf_var_rate_label"] == true
        and KEYS["sf_set_state_title"] ~= nil and KEYS["rf_pda_rotation_tip_generic"] ~= nil)

-- ── C. every call-site key in every file ───────────────────────────────────
local ORDERED_KEYS = sortedKeys(KEYS)
for _, lang in ipairs(LANGS) do
    local missing = {}
    for _, k in ipairs(ORDERED_KEYS) do
        if FILES[lang][k] == nil then missing[#missing + 1] = k end
    end
    T.eq("C " .. lang .. " carries every key read at a call site", table.concat(missing, " "), "")
end

-- ── N. the row's named sets ────────────────────────────────────────────────
local NO_FILE = { "sf_set_state_title", "sf_set_disease_title", "rf_pda_rotation_last",
    "rf_pda_rotation_tip_bonus", "rf_pda_rotation_tip_fatigue", "rf_pda_rotation_tip_generic",
    "rf_pda_treat_rotation", "sf_merge_label_list", "sf_merge_label_range", "sf_pda_status_unknown",
    "sf_rp_col_crop", "sf_rp_col_effect", "sf_rp_col_status", "sf_rp_field_header_block" }
local CZ = { "sf_map_active", "sf_map_balanced", "sf_map_compaction_ok", "sf_map_compaction_recommended",
    "sf_map_compaction_urgent", "sf_map_condition", "sf_map_crop", "sf_map_disease_pressure",
    "sf_map_fungicide", "sf_map_gap", "sf_map_herbicide", "sf_map_insecticide", "sf_map_limiting",
    "sf_map_not_applied", "sf_map_not_needed", "sf_map_om_fair", "sf_map_om_healthy", "sf_map_om_low",
    "sf_map_pest_pressure", "sf_map_ph_apply_lime", "sf_map_ph_apply_lime_urgent", "sf_map_ph_apply_sulfur",
    "sf_map_ph_none_needed", "sf_map_ph_normalize", "sf_map_ph_optimal", "sf_map_ph_over_limed",
    "sf_map_ph_severely_over_limed", "sf_map_ph_slightly_acidic", "sf_map_ph_very_acidic", "sf_map_target",
    "sf_map_target_no_data", "sf_map_target_none", "sf_map_tip", "sf_map_treatment", "sf_map_weed_pressure",
    "sf_release_dialog_title", "sf_report_rec_optimal", "sf_report_rotation_bonus",
    "sf_report_rotation_fatigue", "sf_report_rotation_ok" }
local FR = { "sf_config_seeSpray", "sf_report_rec_optimal", "sf_report_rotation_bonus", "sf_report_rotation_ok",
    "sf_sensor_disease", "sf_sensor_pest", "sf_sensor_state_off", "sf_sensor_state_on", "sf_var_rate_label" }
local CS = { "sf_config_seeSpray", "sf_sensor_disease", "sf_sensor_pest", "sf_sensor_state_off", "sf_sensor_state_on" }

local function missingIn(langs, keys)
    local out = {}
    for _, lang in ipairs(langs) do
        for _, k in ipairs(keys) do
            if FILES[lang] == nil or FILES[lang][k] == nil then out[#out + 1] = lang .. ":" .. k end
        end
    end
    return table.concat(out, " ")
end
T.eq("N1 the 14 keys the row found in no file (the two page titles among them) are in all 27", missingIn(LANGS, NO_FILE), "")
T.eq("N2 the rotation N/A key is in all 27 (26 lacked it)", missingIn(LANGS, { "sf_report_rotation_na" }), "")
T.eq("N3 Czech carries its 40 map, release and report keys", missingIn({ "cz" }, CZ), "")
T.eq("N4 French carries its 9 sensor, report and variable-rate keys", missingIn({ "fr" }, FR), "")
T.eq("N5 Chinese (Simplified) carries its 5 sensor keys", missingIn({ "cs" }, CS), "")
T.eq("N6 the page titles' English is today's code fallback, so English players see no change",
    tostring(FILES.en.sf_set_state_title) .. "/" .. tostring(FILES.en.sf_set_disease_title), "SET FIELD STATE/SET FIELD DISEASE")

-- ── F. format specifiers survive translation ───────────────────────────────
local function specs(s)
    local out = {}
    for spec in s:gmatch("%%[sd]") do out[#out + 1] = spec end
    return table.concat(out)
end
local ADDED = {}
for _, k in ipairs(NO_FILE) do ADDED[#ADDED + 1] = k end
ADDED[#ADDED + 1] = "sf_report_rotation_na"
local bad = {}
for _, lang in ipairs(LANGS) do
    for _, k in ipairs(ADDED) do
        local v = FILES[lang][k]
        local e = FILES.en[k]
        if v ~= nil and (e == nil or specs(v) ~= specs(e)) then bad[#bad + 1] = lang .. ":" .. k end
    end
end
T.eq("F1 every language keeps the English %s and %d, in order, in the added keys", table.concat(bad, " "), "")

-- ── S. translations, not stamps ────────────────────────────────────────────
local SENTENCES = { "sf_set_state_title", "sf_set_disease_title", "rf_pda_rotation_tip_bonus",
    "rf_pda_rotation_tip_fatigue", "rf_pda_rotation_tip_generic" }
local copies, stamps = {}, {}
for _, lang in ipairs(LANGS) do
    if lang ~= "en" then
        for _, k in ipairs(SENTENCES) do
            if FILES[lang][k] ~= nil and FILES[lang][k] == FILES.en[k] then copies[#copies + 1] = lang .. ":" .. k end
        end
        local named = {}
        for _, k in ipairs(ADDED) do named[#named + 1] = k end
        for _, k in ipairs(lang == "cz" and CZ or lang == "fr" and FR or lang == "cs" and CS or {}) do named[#named + 1] = k end
        for _, k in ipairs(named) do
            local v = FILES[lang][k]
            if v ~= nil and v:find("^%[EN%]") then stamps[#stamps + 1] = lang .. ":" .. k end
        end
    end
end
T.eq("S1 the two page titles and the three rotation tips read in each language, never as the English sentence", table.concat(copies, " "), "")
T.eq("S2 no key this row adds carries the [EN] stamp", table.concat(stamps, " "), "")
