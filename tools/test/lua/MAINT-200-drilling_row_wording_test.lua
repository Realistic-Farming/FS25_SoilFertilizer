-- MAINT-200-drilling_row_wording_test.lua
--
-- MAINTENANCE row 200: the field info's Drilling row repeated its own label. The row is a
-- label ("Drilling") and a value, and every English verdict began with "Drilling: " as well, so
-- it read "Drilling   Drilling: good window ahead". The three verdict strings are used by that
-- one row only, so the repeated word is dropped from the strings, in every language file.
--
-- WHERE THE BAR STARTS. The real SoilHUD:buildFieldInfoLines() builds the row from the real
-- SoilFertilitySystem:_drillingAdvisory(), which reads a SeasonalCropStress stand-in (the
-- rain outlook and the field's moisture) for each of its three verdicts, and the real SoilL10n
-- reads the shipped language files. The fixture supplies only the world: the crop stress reader
-- and the texts of each file, which are parsed from the files themselves.
--
-- Groups:
--   R  for each of the 27 languages and each of the three verdicts: the row is there, its value
--      is not empty, it is that verdict's own text, and it does not begin with the row's own label
--   E  the English values, pinned
--   F  each file carries each of the three keys and the label key exactly once
--
-- What this bar does NOT prove: how the row looks in the game's field info panel. The TESTING row
-- names that.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/DurationScaling.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/ui/SoilHUD.lua
--!text: translations/translation_br.xml, translations/translation_cs.xml, translations/translation_ct.xml, translations/translation_cz.xml, translations/translation_da.xml, translations/translation_de.xml, translations/translation_ea.xml, translations/translation_en.xml, translations/translation_es.xml, translations/translation_fc.xml, translations/translation_fi.xml, translations/translation_fr.xml, translations/translation_hu.xml, translations/translation_id.xml, translations/translation_it.xml, translations/translation_jp.xml, translations/translation_kr.xml, translations/translation_nl.xml, translations/translation_no.xml, translations/translation_pl.xml, translations/translation_pt.xml, translations/translation_ro.xml, translations/translation_ru.xml, translations/translation_sv.xml, translations/translation_tr.xml, translations/translation_uk.xml, translations/translation_vi.xml

SoilLogger.debug = function() end
SoilLogger.info = function() end
SoilLogger.warning = function() end

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " ran to its end without a Lua error (" .. tostring(err) .. ")", false) end
end

local LANGS = { "br", "cs", "ct", "cz", "da", "de", "ea", "en", "es", "fc", "fi", "fr", "hu", "id", "it", "jp", "kr", "nl", "no", "pl", "pt", "ro", "ru", "sv", "tr", "uk", "vi" }
local function unescape(v)
  return (v:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end
local LANG, COUNT = {}, {}
for _, l in ipairs(LANGS) do
  local text = SOURCE_TEXT["translations/translation_" .. l .. ".xml"] or ""
  local m, n = {}, {}
  for k, v in text:gmatch('<e k="([^"]+)" v="([^"]*)"') do
    m[k] = unescape(v)
    n[k] = (n[k] or 0) + 1
  end
  LANG[l], COUNT[l] = m, n
end

local KEYS = { good = "sf_notify_drill_good", risky = "sf_notify_drill_risky", forecast = "sf_notify_drill_forecast_only" }
local LABEL_KEY = "sf_fieldinfo_drilling"

--- The crop stress reader behind each verdict (the conditions the advisory's own test uses).
local WORLD = {
  good     = { likelihood = 0.2, moisture = 0.3 },
  risky    = { likelihood = 0.7, moisture = 0.7 },
  forecast = { likelihood = 0.7, moisture = nil },
}

--- The row the real builder makes for one verdict in one language: label and value, or nil.
local function drillingRow(lang, verdict)
  local texts = LANG[lang]
  g_i18n = { texts = {}, hasText = function(_, k) return texts[k] ~= nil end,
             getText = function(_, k) return texts[k] or ("Missing '" .. tostring(k) .. "'") end }
  local w = WORLD[verdict]
  g_currentMission = { environment = { currentMonotonicDay = 10 }, getIsServer = function() return true end,
    cropStressManager = {
      getRainOutlook = function() return { likelihood = w.likelihood, approximate = true } end,
      getMoisture = function() return w.moisture end,
    } }
  local ss = setmetatable({}, { __index = SoilFertilitySystem })
  g_SoilFertilityManager = { soilSystem = ss, settings = {} }
  local hud = setmetatable({}, { __index = SoilHUD })
  local info = { fieldId = 7, pH = 6.5, organicMatter = 3.0, yieldEfficiency = 88,
                nitrogen = { value = 50, status = "Good" }, phosphorus = { value = 50, status = "Good" },
                potassium = { value = 50, status = "Good" } }
  local ok, lines = pcall(hud.buildFieldInfoLines, hud, info)
  if not ok then return nil, nil, tostring(lines) end
  local want = texts[LABEL_KEY]
  for _, line in ipairs(lines) do
    if line.label == want then return line.label, line.value end
  end
  return nil, nil, "no row with the label " .. tostring(want)
end

group("R", function()
  for _, l in ipairs(LANGS) do
    for _, verdict in ipairs({ "good", "risky", "forecast" }) do
      local label, value, err = drillingRow(l, verdict)
      local tag = "R " .. l .. " " .. verdict
      T.ok(tag .. ": the Drilling row is built (" .. tostring(err) .. ")", label ~= nil)
      if label ~= nil then
        T.ok(tag .. ": the value is not empty", type(value) == "string" and value ~= "")
        -- Each of the three worlds reaches its own verdict: a threshold change that sent them all to
        -- one verdict would leave the other two verdicts' strings unchecked.
        T.eq(tag .. ": the row shows that verdict's own text", value, LANG[l][KEYS[verdict]])
        local repeats = type(value) == "string" and value:sub(1, #label):lower() == label:lower()
        T.ok(tag .. ": the value does not begin with the row's own label (" .. tostring(value) .. ")", not repeats)
      end
    end
  end
end)

group("E", function()
  T.eq("E1 good", LANG.en[KEYS.good], "Good window ahead")
  T.eq("E2 risky", LANG.en[KEYS.risky], "Risky, rain likely before emergence")
  T.eq("E3 forecast only", LANG.en[KEYS.forecast], "Forecast only, soil moisture unknown")
  T.eq("E4 the label stays", LANG.en[LABEL_KEY], "Drilling")
end)

group("F", function()
  local bad = {}
  for _, l in ipairs(LANGS) do
    for _, k in ipairs({ KEYS.good, KEYS.risky, KEYS.forecast, LABEL_KEY }) do
      if COUNT[l][k] ~= 1 then bad[#bad + 1] = l .. ":" .. k .. "=" .. tostring(COUNT[l][k]) end
    end
  end
  T.eq("F1 every one of the 27 files carries each key exactly once", table.concat(bad, ", "), "")
  T.eq("F2 and the list has all twenty-seven", #LANGS, 27)
end)
