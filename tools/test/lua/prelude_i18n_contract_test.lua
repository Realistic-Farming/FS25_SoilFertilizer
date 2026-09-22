-- prelude_i18n_contract_test.lua - the shared harness i18n must model the engine.
--
-- This bar exists because a harness that lies about i18n makes every l10n gate in
-- the mod untestable, and makes the WRONG file look guilty when a test goes red.
-- The prelude used to define g_i18n as { getText = function(_self, key) return key
-- end }: no hasText at all, and a getText returning a shape the engine never
-- returns. A gate written the engine's way (SoilTreatmentDialog.lua, PR #969)
-- refuses an i18n object that cannot answer hasText, so under the old prelude every
-- correctly repaired site silently took its English fallback and any test asserting
-- a translated string went red for a reason that had nothing to do with its subject.
--
-- The engine, read from D:\FS25_Decoded\dataS\scripts_decompiled:
--   I18N.lua:175 getText  - returns texts[name]; when the key is absent returns the
--                           literal "Missing '<name>' in l10n<suffix>.xml". Never
--                           nil, never "", never the "$l10n_" attribute prefix.
--   I18N.lua:194 hasText  - false when name is nil, otherwise texts[name] ~= nil,
--                           returned as a real boolean.
--
-- Locked here:
--   NO LOCALE IS LOADED     - the harness reads no l10n.xml, so by default no key
--                             exists and every gate takes its English fallback.
--                             That is the honest result, not a workaround.
--   THE MISSING SENTENCE    - an absent key comes back as the engine's sentence,
--                             which is exactly the string the old $l10n_ guards
--                             could not see and the defect class is made of.
--   A TEST CAN REGISTER     - setText makes a key exist, so a bar that needs a
--                             translated string can have one without hand-building
--                             an i18n object.
--   THE REPAIRED GATE WORKS - the canonical hasText gate resolves a registered key
--                             and falls back on an unregistered one.
--
-- Every probe below goes through call(), so a prelude missing a method reports
-- "<absent>" and fails its own assertion instead of taking the file down with a
-- nil-call. A kill that arrives as a load error names nothing; this one names a row.

local KEY     = "sf_prelude_contract_key"
local ABSENT  = "sf_prelude_contract_absent"
local ENGLISH = "English fallback"

local function call(method, ...)
    if type(g_i18n) ~= "table" then return "<no g_i18n>" end
    if type(g_i18n[method]) ~= "function" then return "<absent>" end
    local ok, v = pcall(g_i18n[method], g_i18n, ...)
    if not ok then return "<error>" end
    return v
end

-- ── shape ────────────────────────────────────────────────────────────────────
T.ok("prelude i18n: g_i18n exists", type(g_i18n) == "table")
T.eq("prelude i18n: getText is a function", type(g_i18n.getText), "function")
T.eq("prelude i18n: hasText is a function", type(g_i18n.hasText), "function")
T.eq("prelude i18n: setText is a function", type(g_i18n.setText), "function")
T.eq("prelude i18n: it starts with no keys at all", next(g_i18n.texts or {}), nil)

-- ── hasText on an absent key ─────────────────────────────────────────────────
T.eq("prelude i18n: an unregistered key does not exist", call("hasText", ABSENT), false)
T.eq("prelude i18n: a nil key does not exist (I18N.lua:195)", call("hasText", nil), false)
T.eq("prelude i18n: hasText answers with a real boolean, not a truthy value",
     type(call("hasText", ABSENT)), "boolean")

-- ── getText on an absent key: the engine's sentence, and none of the fictions ──
local missing = call("getText", ABSENT)
T.eq("prelude i18n: an absent key returns the engine's missing sentence",
     missing, "Missing '" .. ABSENT .. "' in l10n.xml")
T.eq("prelude i18n: it is a string", type(missing), "string")
T.ok("prelude i18n: it is never empty", missing ~= "")
T.ok("prelude i18n: it is never the key itself (the old prelude's fiction)", missing ~= ABSENT)
T.ok("prelude i18n: it is never the $l10n_ attribute prefix (the old guards' fiction)",
     missing ~= ("$l10n_" .. ABSENT))

-- ── setText registers a key ──────────────────────────────────────────────────
call("setText", KEY, "Eine echte Uebersetzung")
T.eq("prelude i18n: a registered key exists", call("hasText", KEY), true)
T.eq("prelude i18n: and getText hands back exactly what was registered",
     call("getText", KEY), "Eine echte Uebersetzung")
T.eq("prelude i18n: registering one key does not make a sibling exist",
     call("hasText", ABSENT), false)

-- ── the canonical repaired gate, as SoilTreatmentDialog.lua:62-66 writes it ───
-- Copied rather than loaded: the subject here is the harness i18n, not the dialog.
local function translate(key, fallback)
    local i18n = g_i18n
    if i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
        return fallback
    end
    local okHas, has = pcall(i18n.hasText, i18n, key)
    if not okHas or has ~= true then return fallback end
    local ok, text = pcall(i18n.getText, i18n, key)
    if not ok or type(text) ~= "string" or text == "" then return fallback end
    return text
end

T.eq("prelude i18n: the repaired gate resolves a registered key",
     translate(KEY, ENGLISH), "Eine echte Uebersetzung")
T.eq("prelude i18n: the repaired gate falls back on an unregistered key",
     translate(ABSENT, ENGLISH), ENGLISH)
T.ok("prelude i18n: the fallback is returned INSTEAD of the missing sentence, which is the whole point",
     translate(ABSENT, ENGLISH) ~= missing)

-- ── the shape this repair removes must still be refused ──────────────────────
do
    local saved = g_i18n
    g_i18n = { getText = function(_self, key) return key end }   -- the old prelude
    T.eq("prelude i18n: an i18n that cannot answer hasText is still refused",
         translate(KEY, ENGLISH), ENGLISH)
    g_i18n = nil
    T.eq("prelude i18n: a nil i18n is still refused", translate(KEY, ENGLISH), ENGLISH)
    g_i18n = saved
end

T.eq("prelude i18n: the shared object survived the swap", call("hasText", KEY), true)
