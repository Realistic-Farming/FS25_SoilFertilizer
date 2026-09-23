-- =========================================================
-- SoilL10n - the one translation gate with a fallback
-- =========================================================
-- MAINTENANCE rows 59 and 60 (2026-09-22): the l10n gate defect class.
--
-- THE ENGINE, read from D:\FS25_Decoded\dataS\scripts_decompiled\I18N.lua:
--   :175 getText(name)  returns texts[name]; for an absent key it returns the literal
--                       "Missing '<name>' in l10n<suffix>.xml" (:186). Never nil, never
--                       "", never the "$l10n_" XML attribute prefix.
--   :194 hasText(name)  false for a nil name, otherwise texts[name] ~= nil.
--
-- So every one of these shapes reads as a guarded lookup and guards nothing:
--   g_i18n:getText(key) or "English"              the `or` can never fire (row 59)
--   not text:find("^%$l10n_")                      tests a prefix getText cannot return (row 60)
--   text ~= ("$l10n_" .. key)                      the same test spelled as a compare (PR #973)
-- and the player is shown the engine's diagnostic where the author wrote English.
--
-- THE RULE (PR #973's, kept here): hasText is the gate. The missing sentence is never
-- compared: it carries g_languageSuffix, which differs per language (main.lua:1187) and
-- is reassigned at runtime (NPCManager.lua:358), and a comparison against it fails
-- OPEN. A key that exists but holds an empty or non-string value takes the fallback too.
--
-- Every site that carries an English fallback goes through tr(); a site that renders a
-- key the mod ships, with no fallback written, is not this defect and is left alone.
SoilL10n = SoilL10n or {}

--- The translation for key, or fallback (which may be nil) when the key is absent,
--- when the i18n object cannot answer, or when the text is not a non-empty string.
---@param key string|nil
---@param fallback any
---@return any
function SoilL10n.tr(key, fallback)
    local i18n = g_i18n
    if key == nil or i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
        return fallback
    end
    local okHas, has = pcall(i18n.hasText, i18n, key)
    if not okHas or has ~= true then return fallback end
    local ok, text = pcall(i18n.getText, i18n, key)
    if not ok or type(text) ~= "string" or text == "" then return fallback end
    return text
end
