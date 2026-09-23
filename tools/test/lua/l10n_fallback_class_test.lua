-- l10n_fallback_class_test.lua - MAINTENANCE rows 59 and 60: the fallback shapes.
--
-- The defect class: a translation lookup that carries an English fallback the
-- author meant to be reachable, behind a gate that cannot fire.
--   g_i18n:getText(key) or "English"          I18N.lua:186 never returns nil (row 59)
--   not text:find("^%$l10n_")                  a prefix getText cannot return (row 60)
-- Every such site now goes through SoilL10n.tr(key, fallback), the one gate, which
-- asks hasText (I18N.lua:194) and never compares the missing sentence.
--
-- THE ENTRY POINT IS THE REAL PRELUDE CONTRACT AND THE REAL SITES. The harness i18n
-- models the engine (prelude_i18n_contract_test.lua): no locale is loaded, an absent
-- key returns the engine's "Missing '<key>' in l10n<suffix>.xml" sentence, hasText is
-- false. Nothing here registers a text for a site under test before asserting the
-- fallback; a text is registered only to show the translated path, then removed.
-- The sites are driven through shipped functions: SoilHUD:buildFieldInfoLines (the
-- native FIELD INFO rows, 20 of the repaired sites) and EstablishmentFailure:_notify.
--
-- Groups:
--   H  the helper's contract against the prelude i18n
--   F  the FIELD INFO rows: English fallbacks with no locale, never the sentence;
--      a registered key translates its row; the rotation N/A row (a key 26 language
--      files lack today) and the sim-asleep and disease-unknown rows
--   E  the establishment notification
--   M  source witness: main.lua sources the helper before its first consumer
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/SoilL10n.lua, src/ui/SoilHUD.lua, src/EstablishmentFailure.lua
--!text: src/main.lua

local SENTENCE = "Missing '"

local function isSentence(s) return type(s) == "string" and s:find(SENTENCE, 1, true) ~= nil end

local function register(key, text) g_i18n:setText(key, text) end
local function unregister(key) g_i18n.texts[key] = nil end

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE HELPER AGAINST THE PRELUDE
-- ══════════════════════════════════════════════════════════════════════════
do
    local KEY = "sf_l10n_class_probe"
    T.ok("H0 [world] the prelude i18n is the engine's shape: no locale, absent key answers the sentence and hasText false",
        g_i18n:hasText(KEY) == false and isSentence(g_i18n:getText(KEY)))
    T.eq("H1 an absent key returns the fallback, never the sentence", SoilL10n.tr(KEY, "English"), "English")
    T.eq("H2 an absent key with no fallback returns nil", SoilL10n.tr(KEY), nil)
    T.eq("H3 a nil key returns the fallback", SoilL10n.tr(nil, "English"), "English")
    register(KEY, "Deutsch")
    T.eq("H4 a registered key returns its text", SoilL10n.tr(KEY, "English"), "Deutsch")
    register(KEY, "")
    T.eq("H5 a key that exists with an empty value takes the fallback", SoilL10n.tr(KEY, "English"), "English")
    register(KEY, 42)
    T.eq("H6 a key that exists with a non-string value takes the fallback", SoilL10n.tr(KEY, "English"), "English")
    unregister(KEY)
    local saved = g_i18n
    g_i18n = nil
    T.eq("H7 with no i18n object at all, the fallback", SoilL10n.tr(KEY, "English"), "English")
    g_i18n = { getText = function() return "text" end }
    T.eq("H8 an i18n object that cannot answer hasText is not trusted: the fallback", SoilL10n.tr(KEY, "English"), "English")
    g_i18n = saved
    local realHas, realGet = g_i18n.hasText, g_i18n.getText
    g_i18n.hasText = function() return 1 end
    T.eq("H9 a truthy non-boolean hasText is not a yes: the fallback", SoilL10n.tr(KEY, "English"), "English")
    g_i18n.hasText = function() error("boom") end
    T.eq("H10 a hasText that raises: the fallback, not an error", SoilL10n.tr(KEY, "English"), "English")
    g_i18n.hasText = realHas
    register(KEY, "Deutsch")
    g_i18n.getText = function() error("boom") end
    T.eq("H11 a getText that raises: the fallback, not an error", SoilL10n.tr(KEY, "English"), "English")
    g_i18n.getText = realGet
    unregister(KEY)
end

-- ══════════════════════════════════════════════════════════════════════════
-- F. THE FIELD INFO ROWS
-- ══════════════════════════════════════════════════════════════════════════
local function fieldInfo(extra)
    local info = {
        fieldId = 3,
        nitrogen = { status = "Good" }, phosphorus = { status = "Good" }, potassium = { status = "Good" },
        pH = 6.5, organicMatter = 3.0, yieldEfficiency = 91,
        weedPressure = 0, pestPressure = 0, diseasePressure = 0,
    }
    for k, v in pairs(extra or {}) do info[k] = v end
    return info
end
local function rows(info)
    local hud = setmetatable({}, { __index = SoilHUD })
    local lines = hud:buildFieldInfoLines(info)
    local byLabel, labels = {}, {}
    for _, l in ipairs(lines) do
        byLabel[tostring(l.label)] = tostring(l.value)
        labels[#labels + 1] = tostring(l.label)
    end
    return lines, byLabel, table.concat(labels, "|")
end
local function noSentence(lines)
    for _, l in ipairs(lines) do
        if isSentence(l.label) or isSentence(l.value) then return false end
    end
    return true
end

do
    local lines, by, labels = rows(fieldInfo())
    T.ok("F1 [reached] the FIELD INFO rows were built through the shipped builder", #lines >= 5)
    T.ok("F2 with no locale, every label is the author's English and never the engine's sentence",
        noSentence(lines) and by["Soil Grade"] ~= nil and by["Yield"] ~= nil and by["Needs"] ~= nil and by["Rotation"] ~= nil)
    T.eq("F3 the rotation row with no rotation data reads the English N/A (a key 26 language files lack today)", by["Rotation"], "N/A")
    T.eq("F4 the needs row with nothing needed reads the English optimum", by["Needs"], "All good")
    T.eq("F5 the yield row formats the efficiency", by["Yield"], "91%")

    register("sf_fieldinfo_grade", "Bodenklasse")
    register("sf_report_rotation_na", "k.A.")
    register("sf_fieldinfo_needs", "Bedarf")
    local _, by2 = rows(fieldInfo())
    T.ok("F6 a registered key translates its label, the others keep their English",
        by2["Bodenklasse"] ~= nil and by2["Soil Grade"] == nil and by2["Yield"] ~= nil)
    T.eq("F7 a registered value key translates the value", by2["Rotation"], "k.A.")
    T.eq("F8 the needs label follows its key while its value keeps the English optimum", by2["Bedarf"], "All good")
    unregister("sf_fieldinfo_grade"); unregister("sf_report_rotation_na"); unregister("sf_fieldinfo_needs")

    local _, by3 = rows(fieldInfo({ rotationStatus = "Fatigue" }))
    T.eq("F9 a rotation status reads its English word", by3["Rotation"], "Fatigue")
    register("sf_report_rotation_fatigue", "Ermuedung")
    local _, by4 = rows(fieldInfo({ rotationStatus = "Fatigue" }))
    T.eq("F10 and its translation when the key exists", by4["Rotation"], "Ermuedung")
    unregister("sf_report_rotation_fatigue")

    local _, by5 = rows(fieldInfo({ simDisabled = true, simDisabledReasonKey = "sf_reason_far", simDisabledReason = "far away" }))
    T.eq("F11 the sim-asleep row: the reason key is absent, so the plain reason, inside the English asleep label",
        by5["Sim Status"], "sim asleep (far away)")
    register("sf_reason_far", "weit weg")
    register("sf_fieldsentry_asleep", "schlaeft")
    local _, by6 = rows(fieldInfo({ simDisabled = true, simDisabledReasonKey = "sf_reason_far", simDisabledReason = "far away" }))
    T.eq("F12 with both keys registered the row translates both parts", by6["Sim Status"], "schlaeft (weit weg)")
    unregister("sf_reason_far"); unregister("sf_fieldsentry_asleep")

    -- An active disease the player has not scouted: SoilHUD.lua:1031 hides it.
    local hidden = { activeDisease = "late_blight", diseaseDiscovered = false, shownDiseasePressure = 60 }
    local _, by7 = rows(fieldInfo(hidden))
    T.eq("F13 the hidden-disease row reads the English unknown marker under the English label",
        by7["Disease"], "? (scout to identify)")
    register("sf_hud_disease_unknown", "? unbekannt")
    local _, by8 = rows(fieldInfo(hidden))
    T.eq("F14 and the registered marker when the key exists", by8["Disease"], "? unbekannt")
    unregister("sf_hud_disease_unknown")

    local _, by9 = rows(fieldInfo({ weedPressure = 80, pestPressure = 80 }))
    T.ok("F15 pressure rows carry English labels and the needs list names them in English",
        by9["Weed Risk"] ~= nil and by9["Pests"] ~= nil and by9["Needs"]:find("Weed Risk", 1, true) ~= nil and by9["Needs"]:find("Pests", 1, true) ~= nil)
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ESTABLISHMENT NOTIFICATION
-- ══════════════════════════════════════════════════════════════════════════
do
    local shown = {}
    local ef = setmetatable({ manager = { soilSystem = { showNotification = function(_, text) shown[#shown + 1] = text end } } },
        { __index = EstablishmentFailure })
    ef:_notify("sf_notify_establishment_drought", 3, "drought")
    T.eq("E1 with no locale the notification is the author's English, never the sentence", shown[1], "Establishment failed: drought")
    register("sf_notify_establishment_drought", "Auflaufen fehlgeschlagen")
    ef:_notify("sf_notify_establishment_drought", 3, "drought")
    T.eq("E2 with the key registered, its text", shown[2], "Auflaufen fehlgeschlagen")
    unregister("sf_notify_establishment_drought")
end

-- ══════════════════════════════════════════════════════════════════════════
-- M. SOURCE WITNESS: main.lua loads the helper before its first consumer
-- ══════════════════════════════════════════════════════════════════════════
do
    local main = SOURCE_TEXT and SOURCE_TEXT["src/main.lua"] or ""
    local helperAt = main:find('source(modDirectory .. "src/utils/SoilL10n.lua")', 1, true)
    local firstConsumer = main:find('source(modDirectory .. "src/hooks/HookManager.lua")', 1, true)
    T.ok("M1 main.lua sources src/utils/SoilL10n.lua", helperAt ~= nil)
    T.ok("M2 and before the first file that calls it", helperAt ~= nil and firstConsumer ~= nil and helperAt < firstConsumer)
end
