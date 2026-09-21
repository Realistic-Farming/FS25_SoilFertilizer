-- SF-79 pH-UNKNOWN READOUT: the Treatment Prescription pH row shows a sentence a
-- farmer can read, never the engine's own missing-key error text.
--
-- Wizard hit this on his first sprayer pass of a River Bend year: the pH row
-- rendered "Missing 'sf_treat_action_ph_unknown' in l10n_en.xml". Two defects,
-- both covered here.
--
-- 1. The key was never written. SF-79 shipped the call on 2026-09-10 and no
--    locale entry with it. That is a TEXT fact about translations/*.xml; fengari
--    has no file IO, so it is proved in the PR by parsing all 27 files rather
--    than here. What this bar pins is the code side: the exact English sentence
--    below must stay identical to the v= now shipped in translation_en.xml.
--
-- 2. The fallback could never fire, which is the defect that outlives the key.
--    SoilTreatmentDialog's tr() gated on `text ~= ("$l10n_" .. key)`. That is the
--    XML attribute prefix, not anything getText returns. I18N.lua:186 returns
--    string.format("Missing '%s' in l10n%s.xml", name, g_languageSuffix), so the
--    comparison never matched, the guard passed the error string through as if it
--    were a translation, and EVERY fallback in this dialog was unreachable.
--
-- GROUP A is the regression bar for defect 2 and fails against the old gate.
-- GROUP B proves a real translation is still preferred over the fallback.
-- GROUP C walks the untrusted i18n shapes, including the one the shared prelude
-- itself has (getText but no hasText), and requires a readable sentence from each.
-- GROUP D holds the three sibling pH branches, which run through the same helper.
--
-- Models the dialog's callers, not the GUI: buildPrescription is the real shipped
-- function and is what both the dialog and the PDA inline pane call. No rendering,
-- no font metrics and no locale file IO are proved here.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/ui/SoilTreatmentDialog.lua

local KEY = "sf_treat_action_ph_unknown"
local EN_PH_UNKNOWN = "pH unknown - no lime advice until a current reading exists."
local EN_LIME   = "Apply LIME or LIQUID LIME to raise pH."
local EN_GYPSUM = "Apply GYPSUM to lower pH / improve structure."
local EN_OK     = "OK"

-- The exact shape I18N.lua:186 builds for a key with no entry. The suffix is
-- g_languageSuffix, "_en" from main.lua:33 on an English client.
local function engineMissing(key)
    return "Missing '" .. key .. "' in l10n_en.xml"
end

-- opts.noHasText     - omit hasText entirely (this is the shared prelude's shape)
-- opts.hasTextValue  - force hasText's return, including non-boolean values
-- opts.hasTextThrows - hasText raises
-- opts.getTextValue  - force getText's return
-- opts.getTextThrows - getText raises
local function i18nWith(texts, opts)
    opts = opts or {}
    local obj = {
        getText = function(_self, key)
            if opts.getTextThrows then error("boom") end
            if opts.getTextValue ~= nil then return opts.getTextValue end
            local t = texts[key]
            if t == nil then return engineMissing(key) end   -- engine shape, never nil
            return t
        end,
    }
    if not opts.noHasText then
        obj.hasText = function(_self, key)
            if opts.hasTextThrows then error("boom") end
            if opts.hasTextValue ~= nil then return opts.hasTextValue end
            return texts[key] ~= nil
        end
    end
    return obj
end

-- A field whose every other reading is deliberately unremarkable, so the only
-- interesting row is pH. nil pH is the unknown case.
local function withField(ph)
    g_SoilFertilityManager = {
        settings = { colorblindMode = false, replenishmentRate = 3 },
        soilSystem = {
            getFieldInfo = function(_self, _fieldId)
                return {
                    pH = ph,
                    organicMatter = 4.2,
                    fieldArea = 1.0,
                    nitrogen   = { value = 99 },
                    phosphorus = { value = 99 },
                    potassium  = { value = 99 },
                    weedPressure = 0, pestPressure = 0, diseasePressure = 0,
                }
            end,
        },
    }
end

local function phText(ph)
    withField(ph)
    local rx = SoilTreatmentDialog.buildPrescription(1)
    if rx == nil or rx.ph == nil then return nil end
    return rx.ph.text
end

-- ── GROUP A: the engine's missing-key text never reaches the player ───────────
do
    g_i18n = i18nWith({})   -- nothing translated: every key is missing

    -- Prove the fixture is the real failure before asserting anything about it.
    -- A fixture whose getText quietly returned nil or "" would make the old gate
    -- pass too, and this bar would prove nothing.
    T.eq("SF-79 A0: the fixture's getText really returns the engine sentinel",
        g_i18n:getText(KEY), engineMissing(KEY))
    T.eq("SF-79 A0: and the sentinel is not empty or nil",
        type(g_i18n:getText(KEY)), "string")

    local text = phText(nil)
    T.eq("SF-79 A1: unknown pH renders the English sentence", text, EN_PH_UNKNOWN)
    T.ok("SF-79 A2: the row never carries the engine's missing-key text",
        text ~= nil and text:find("Missing '", 1, true) == nil)
    T.ok("SF-79 A3: the row never carries a raw l10n key",
        text ~= nil and text:find(KEY, 1, true) == nil)
end

-- ── GROUP B: a real translation is still preferred ────────────────────────────
do
    g_i18n = i18nWith({ [KEY] = "pH unbekannt, keine Kalkempfehlung." })
    T.eq("SF-79 B1: a present key is used, not the fallback",
        phText(nil), "pH unbekannt, keine Kalkempfehlung.")

    -- A translated sentence that happens to contain the word Missing is still text.
    g_i18n = i18nWith({ [KEY] = "Missing reading: no lime advice." })
    T.eq("SF-79 B2: a real translation is not rejected for its wording",
        phText(nil), "Missing reading: no lime advice.")
end

-- ── GROUP C: every untrusted i18n shape yields a readable sentence ────────────
do
    local cases = {
        { name = "C1 hasText absent (the shared prelude's own shape)",
          i18n = i18nWith({ [KEY] = "never reached" }, { noHasText = true }) },
        { name = "C2 hasText false",
          i18n = i18nWith({ [KEY] = "never reached" }, { hasTextValue = false }) },
        { name = "C3 hasText non-boolean truthy",
          i18n = i18nWith({ [KEY] = "never reached" }, { hasTextValue = 1 }) },
        { name = "C4 hasText throws",
          i18n = i18nWith({ [KEY] = "never reached" }, { hasTextThrows = true }) },
        { name = "C5 getText throws",
          i18n = i18nWith({ [KEY] = "x" }, { getTextThrows = true }) },
        { name = "C6 getText returns empty string",
          i18n = i18nWith({ [KEY] = "x" }, { getTextValue = "" }) },
        { name = "C7 getText returns a non-string",
          i18n = i18nWith({ [KEY] = "x" }, { getTextValue = 42 }) },
        { name = "C8 getText returns a table",
          i18n = i18nWith({ [KEY] = "x" }, { getTextValue = {} }) },
    }
    for _, case in ipairs(cases) do
        g_i18n = case.i18n
        local ok, text = pcall(phText, nil)
        T.ok("SF-79 " .. case.name .. ": the read does not throw", ok)
        T.eq("SF-79 " .. case.name .. ": falls back to the English sentence",
            ok and text or nil, EN_PH_UNKNOWN)
    end

    g_i18n = nil
    local ok, text = pcall(phText, nil)
    T.ok("SF-79 C9: a nil g_i18n does not throw", ok)
    T.eq("SF-79 C9: a nil g_i18n falls back to the English sentence",
        ok and text or nil, EN_PH_UNKNOWN)
end

-- ── GROUP D: the sibling pH branches run through the same repaired helper ─────
do
    g_i18n = i18nWith({})   -- all keys missing, so each branch must show its own sentence
    T.eq("SF-79 D1: low pH falls back to the lime sentence",    phText(6.0), EN_LIME)
    T.eq("SF-79 D2: high pH falls back to the gypsum sentence", phText(8.0), EN_GYPSUM)
    T.eq("SF-79 D3: in-range pH falls back to OK",              phText(7.0), EN_OK)

    g_i18n = i18nWith({
        sf_treat_action_lime   = "Kalk ausbringen.",
        sf_treat_action_gypsum = "Gips ausbringen.",
        sf_treat_action_ok     = "In Ordnung",
    })
    T.eq("SF-79 D4: low pH uses its translation",    phText(6.0), "Kalk ausbringen.")
    T.eq("SF-79 D5: high pH uses its translation",   phText(8.0), "Gips ausbringen.")
    T.eq("SF-79 D6: in-range pH uses its translation", phText(7.0), "In Ordnung")

    -- The rounding boundary is unchanged by this repair: 6.45 rounds to 6.5, which
    -- is in range, and 6.44 rounds to 6.4, which is not.
    T.eq("SF-79 D7: 6.45 rounds into the in-range branch", phText(6.45), "In Ordnung")
    T.eq("SF-79 D8: 6.44 rounds into the lime branch",     phText(6.44), "Kalk ausbringen.")
end
