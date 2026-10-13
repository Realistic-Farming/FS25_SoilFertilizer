-- MAINT-79-door_l10n_gate_test.lua
--
-- MAINTENANCE row 79: the shared Esc door page's tr (RfPdaMenuPage.lua, byte-identical in all
-- ten door mods) gates on hasText and asks a named mod through the engine's customEnv. The old
-- probe read g_modEnvironments[name].i18n, a field the engine never sets (a mod's i18n is
-- modEnv.g_i18n, mods.lua:453), so on any non-Soil host only the host's own table resolved
-- and Soil's door chrome showed English in every language.
--
-- THE ENTRY POINT IS THE REAL PAGE: the whole of src/ui/RfPdaMenuPage.lua is loaded, with its
-- file-level MOD_NAME resolving to a DairyCore host (MAINT-79-door_host_env.lua sets
-- g_currentModName first, as the engine does while it sources a mod), and the page's own
-- RfPdaMenuPage:_applyChromeL10n paints a bare page's chrome elements, the method the page
-- runs from initialize and onFrameOpen. The i18n is the engine's, modelled line for line on
-- I18N.lua (addModI18N :149-172, getText :175-191, hasText :194-209, modEnvironments :20,
-- :159) and mods.lua:453 (the host's g_i18n is its own addModI18N table). Soil's texts are the
-- SHIPPED translations/translation_de.xml, read through --!text; nothing is hand-populated
-- but the host's own texts where a row needs one.
--
-- Groups:
--   C  a DairyCore host with Soil loaded: Soil's German chrome, the fallback for a key no mod
--      ships, the host's own real text that begins "Missing" unchanged, and no Soil loaded at
--      all (English, never the engine's Missing sentence)
--
--!load: src/utils/Logger.lua, tools/test/lua/MAINT-79-door_host_env.lua, src/ui/RfPdaMenuPage.lua
--!text: translations/translation_de.xml

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

--- The engine's I18N and the mods' tables (I18N.lua:149-209, mods.lua:453).
local function newEngineI18N(languageSuffix)
    local I18N = { texts = {}, modEnvironments = {} }
    function I18N:getText(name, customEnv)
        local ret = nil
        if customEnv ~= nil then
            local modEnv = self.modEnvironments[customEnv]
            if modEnv ~= nil then ret = modEnv.texts[name] end
        end
        if ret == nil then
            ret = self.texts[name]
            if ret == nil then ret = string.format("Missing '%s' in l10n%s.xml", name, languageSuffix) end
        end
        return ret
    end
    function I18N:hasText(name, customEnv)
        if name == nil then return false end
        local ret = nil
        if customEnv ~= nil then
            local modEnv = self.modEnvironments[customEnv]
            if modEnv ~= nil then ret = modEnv.texts[name] end
        end
        if ret == nil then ret = self.texts[name] end
        return ret ~= nil
    end
    function I18N:addModI18N(modName)
        local modi18n = { texts = {} }
        setmetatable(modi18n, { __index = self })
        setmetatable(modi18n.texts, { __index = self.texts })
        self.modEnvironments[modName] = modi18n
        return modi18n
    end
    return I18N
end

--- The shipped German Soil texts, <e k="" v=""/> entries, XML entities decoded.
local function soilGermanTexts()
    local out = {}
    local xml = SOURCE_TEXT["translations/translation_de.xml"]
    for k, v in xml:gmatch('<e k="([^"]+)"%s+v="([^"]*)"') do
        v = v:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
        out[k] = v
    end
    return out
end

--- A bare page with the chrome elements _applyChromeL10n paints.
local IDS = { "soilColField", "soilColArea", "soilColStatus", "soilColFert", "soilColWeed", "soilColPest",
    "soilColDisease", "fieldsEmptyHint", "soilSectionTreatment", "soilTreatProducts", "samplingInfoFallback" }
local function barePage()
    local page = {}
    for _, id in ipairs(IDS) do
        page[id] = { text = nil, setText = function(self, s) self.text = s end }
    end
    return page
end

group("C", function()
    local savedI18n = g_i18n
    local de = soilGermanTexts()
    T.ok("C0 [reached] the shipped German Soil file was read (the three chrome keys with real German are in it)",
        de.sf_pda_col_pests == "Schädling" and de.sf_pda_col_disease == "Krankheiten"
            and de.sf_pda_no_fields == "Noch keine Felddaten aufgezeichnet.")

    -- A DairyCore host with Soil loaded: two mod tables, the host's g_i18n its own (mods.lua:453).
    local I18N = newEngineI18N("_de")
    local soil = I18N:addModI18N("FS25_SoilFertilizer")
    for k, v in pairs(de) do soil.texts[k] = v end
    soil.texts.rf_pda_sample_hint = nil          -- a key no mod ships in this world
    local dairy = I18N:addModI18N("FS25_DairyCore")
    dairy.texts.sf_pda_col_field = "Missing fields"   -- the host's own REAL text beginning "Missing"
    g_i18n = dairy
    local page = barePage()
    RfPdaMenuPage._applyChromeL10n(page)
    T.eq("C1 on a DairyCore host Soil's German chrome is shown (the old probe read a .i18n field the engine never sets and showed English)",
        page.soilColPest.text .. "/" .. page.soilColDisease.text .. "/" .. page.fieldsEmptyHint.text,
        "Schädling/Krankheiten/Noch keine Felddaten aufgezeichnet.")
    T.eq("C2 a key no mod ships shows the English fallback, never the engine's Missing sentence",
        page.samplingInfoFallback.text, "Soil sample dates appear here when available.")
    T.eq("C3 the host's own real text that begins 'Missing' is shown unchanged (hasText gates; the text is never sniffed)",
        page.soilColField.text, "Missing fields")

    -- The same host with no Soil loaded: nothing to ask but the host, which ships none of these.
    local I18N2 = newEngineI18N("_de")
    g_i18n = I18N2:addModI18N("FS25_DairyCore")
    local page2 = barePage()
    RfPdaMenuPage._applyChromeL10n(page2)
    T.eq("C4 with no Soil loaded every chrome element shows its English fallback, and none the Missing sentence",
        page2.soilColPest.text .. "/" .. page2.fieldsEmptyHint.text .. "/" .. page2.soilColField.text,
        "Pests/No field data recorded yet./Field")

    -- An i18n whose hasText raises: the fallback, no error out of the page.
    g_i18n = setmetatable({ hasText = function() error("hasText refused") end }, { __index = dairy })
    local page3 = barePage()
    local okR = pcall(RfPdaMenuPage._applyChromeL10n, page3)
    T.eq("C5 an i18n whose hasText raises paints the fallback and raises nothing", tostring(okR) .. "/" .. tostring(page3.soilColPest.text), "true/Pests")
    g_i18n = savedI18n
end)
