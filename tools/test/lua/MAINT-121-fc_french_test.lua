--!text: translations/translation_fc.xml, translations/translation_fr.xml, translations/translation_en.xml
--!load: src/utils/SoilL10n.lua
-- MAINT-121-fc_french_test.lua
--
-- MAINTENANCE row 121: the French Canadian file carried Chinese in 420 of its values at
-- 96661bda (413 when the row was counted), so a French Canadian player read Chinese across
-- the Soil menus. They now read French: 416 from the fr file's own French for the same key
-- (21 of them the same word as English, e.g. "OK", "pH", "Bonus"), and 4 by hand where the
-- fr file lacks the key (the sf_report_* rows).
--
-- A TEXT BAR, READ FROM THE REAL FILES, and the lookup EXECUTED:
--   C1  no fc value carries a Han, kana or Hangul character
--   F1  every fc value keeps en's %d/%s sequence, in order
--   H1  the four hand-written keys read French: not empty, not English, not Chinese
--   X1  the mod's own gate, SoilL10n.tr, run against an i18n answering from the real fc
--       file, returns that file's text for every key, and none of it is Chinese; X0 is the
--       same gate on a key the file lacks, returning the fallback

local function unxml(v)
    return (v:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&#10;", "\n"):gsub("&amp;", "&"))
end
local function texts(lang)
    local out, n = {}, 0
    for k, v in SOURCE_TEXT["translations/translation_" .. lang .. ".xml"]:gmatch('<e k="([^"]+)"%s+v="([^"]*)"') do
        out[k] = unxml(v); n = n + 1
    end
    return out, n
end
local FC, NFC = texts("fc")
local EN = texts("en")
local FR = texts("fr")

local function codepoints(s)
    local out, i = {}, 1
    while i <= #s do
        local c = s:byte(i)
        local n, cp = 1, c
        if c >= 0xF0 then n, cp = 4, c - 0xF0 elseif c >= 0xE0 then n, cp = 3, c - 0xE0 elseif c >= 0xC0 then n, cp = 2, c - 0xC0 end
        for j = 1, n - 1 do cp = cp * 64 + ((s:byte(i + j) or 0x80) - 0x80) end
        out[#out + 1] = cp
        i = i + n
    end
    return out
end
local function cjk(s)
    for _, cp in ipairs(codepoints(s)) do
        if (cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7A3) then return true end
    end
    return false
end
local function ph(s)
    local out = {}
    for p in s:gmatch("%%[%-0-9%.]*%a") do out[#out + 1] = p end
    return table.concat(out, " ")
end

T.ok("C0 [reached] the fc file parsed into its entries (" .. NFC .. ")", NFC > 1300)
local han, fmt = {}, {}
for k, v in pairs(FC) do
    if cjk(v) then han[#han + 1] = k end
    if EN[k] ~= nil and ph(v) ~= ph(EN[k]) then fmt[#fmt + 1] = k end
end
table.sort(han); table.sort(fmt)
T.eq("C1 no fc value carries a Han, kana or Hangul character", #han .. ":" .. table.concat(han, " ", 1, math.min(#han, 5)), "0:")
T.eq("F1 every fc value keeps en's placeholders in order", table.concat(fmt, " "), "")

local HAND = { "sf_report_fields_tracked", "sf_report_rec_good", "sf_report_rec_fair", "sf_report_rec_poor" }
local handBad = {}
for _, k in ipairs(HAND) do
    local v = FC[k]
    if v == nil or v == "" or v == EN[k] or cjk(v) or FR[k] ~= nil then handBad[#handBad + 1] = k end
end
T.eq("H1 the four keys the fr file lacks read French in fc (not empty, English or Chinese)", table.concat(handBad, " "), "")

local savedI18n = g_i18n
g_i18n = {
    hasText = function(_, key) return FC[key] ~= nil end,
    getText = function(_, key) return FC[key] or ("Missing '" .. tostring(key) .. "' in l10n_fc.xml") end,
}
-- An empty value (the guide's blank lines, empty in en too) takes the gate's fallback by
-- design (SoilL10n: "a key that exists but holds an empty ... value takes the fallback").
local fell, blank = {}, 0
for k, v in pairs(FC) do
    local got = SoilL10n.tr(k, "<fallback>")
    local want = (v == "") and "<fallback>" or v
    if v == "" then blank = blank + 1 end
    if got ~= want or cjk(got) then fell[#fell + 1] = k end
end
table.sort(fell)
T.eq("X1 SoilL10n.tr over the real fc file returns each key's text (a blank line its fallback), none of it Chinese",
    table.concat(fell, " ", 1, math.min(#fell, 5)) .. "/" .. blank, "/2")
T.eq("X0 the same gate on a key the file lacks returns the fallback", SoilL10n.tr("sf_no_such_key_row121", "<fallback>"), "<fallback>")
g_i18n = savedI18n
