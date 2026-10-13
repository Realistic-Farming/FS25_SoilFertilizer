--!text: src/ui/SoilHUD.lua, translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml
-- MAINT-151-report_keys_test.lua
--
-- MAINTENANCE row 151 (FAST TRACK on Tyson's word, 2026-09-26): the Soil HUD's title bar
-- draws g_i18n:getText("sf_report_rec_" .. statusLabel:lower()) with no fallback
-- (src/ui/SoilHUD.lua, the header block), and the French and Czech files lacked the
-- sf_report_rec_* keys, so a French or Czech player read the engine's "Missing
-- 'sf_report_rec_good' in l10n_fr.xml" there (I18N.lua:186). The engine loads one file per
-- language with no per-key fallback (mods.lua:788-793). fr and cz now carry the four
-- sf_report_* keys the other files carry.
--
-- A TEXT BAR, READ FROM THE REAL FILES, and the HUD's lookup EXECUTED:
--   L0  the labels the HUD can draw, read from overallStatus in the real source (every
--       quoted word after `and` / `or` in its body), and the header's key expression
--   K   every one of the 27 files carries sf_report_rec_<label> for each label, and
--       sf_report_fields_tracked
--   F   fr and cz read French and Czech: not empty, not the English text
--   X   the header's own lookup, run for each label against an i18n answering from each
--       real file in the engine's shape (the "Missing" sentence for an absent key), never
--       returns the Missing sentence

local LANGS = { "br", "cs", "ct", "cz", "da", "de", "ea", "en", "es", "fc", "fi", "fr", "hu", "id", "it", "jp",
    "kr", "nl", "no", "pl", "pt", "ro", "ru", "sv", "tr", "uk", "vi" }

local function texts(lang)
    local out = {}
    for k, v in SOURCE_TEXT["translations/translation_" .. lang .. ".xml"]:gmatch('<e k="([^"]+)"%s+v="([^"]*)"') do
        out[k] = v
    end
    return out
end

-- L0: the labels, from the real source.
local HUD = SOURCE_TEXT["src/ui/SoilHUD.lua"]:gsub("\r\n", "\n")
local body = HUD:match("function SoilHUD:overallStatus%(.-\nend\n")
local seen, LABELS = {}, {}
if body ~= nil then
    for w in body:gmatch('[ao][nr]d?%s+"(%a+)"') do
        if not seen[w] then seen[w] = true; LABELS[#LABELS + 1] = w end
    end
end
table.sort(LABELS)
local keyExpr = HUD:find('g_i18n:getText("sf_report_rec_" .. statusLabel:lower())', 1, true) ~= nil
T.eq("L0 overallStatus draws Fair, Good and Poor, through the header's sf_report_rec_ .. lower() lookup",
    table.concat(LABELS, ",") .. "/" .. tostring(keyExpr), "Fair,Good,Poor/true")

local KEYS = { "sf_report_fields_tracked" }
for _, w in ipairs(LABELS) do KEYS[#KEYS + 1] = "sf_report_rec_" .. w:lower() end

local EN = texts("en")
local missing = {}
local FILES = {}
for _, lang in ipairs(LANGS) do
    FILES[lang] = texts(lang)
    for _, k in ipairs(KEYS) do
        if FILES[lang][k] == nil then missing[#missing + 1] = lang .. ":" .. k end
    end
end
T.eq("K every one of the 27 files carries sf_report_fields_tracked and the header's three sf_report_rec_* keys",
    table.concat(missing, " "), "")

local notLocal = {}
for _, lang in ipairs({ "fr", "cz" }) do
    for _, k in ipairs(KEYS) do
        local v = FILES[lang][k]
        if v == nil or v == "" or v == EN[k] then notLocal[#notLocal + 1] = lang .. ":" .. k end
    end
end
T.eq("F fr and cz read their own language for the four keys", table.concat(notLocal, " "), "")

-- X: the header's lookup, as SoilHUD draws it, against each real file.
local shown = {}
for _, lang in ipairs(LANGS) do
    local file = FILES[lang]
    local i18n = {
        getText = function(_, key)
            return file[key] or ("Missing '" .. tostring(key) .. "' in l10n_" .. lang .. ".xml")
        end,
    }
    for _, statusLabel in ipairs(LABELS) do
        local text = i18n:getText("sf_report_rec_" .. statusLabel:lower())
        if text:find("^Missing '") then shown[#shown + 1] = lang .. ":" .. statusLabel end
    end
end
T.eq("X the header's getText for each label returns the file's text in all 27 languages, never the Missing sentence",
    table.concat(shown, " "), "")
