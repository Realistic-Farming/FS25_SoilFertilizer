-- l10n_gate_sites_test.lua - the repaired l10n gates, driven through a real
-- shipped function rather than through a copy of the gate.
--
-- The defect this bar defends against, in one line: a guard written as
-- `text ~= ("$l10n_" .. key)` compares getText's return against the XML ATTRIBUTE
-- prefix, which is not a string getText can produce. I18N.lua:186 returns
-- "Missing '<key>' in l10n<suffix>.xml" for an absent key, never nil and never
-- empty, so that guard always passed and the engine's diagnostic went to the
-- player where the author had written English.
--
-- The subject here is SoilMinimapLayer.buildLayerLabel, a shipped public function
-- whose only text path is one of the fourteen repaired sites (the sfMapLayerText
-- helper). Driving it proves the repair rather than restating it: a copy of the
-- gate in a test file would pass even if no src file had been touched.
--
-- Why this one of the fourteen: it is the only repaired site reachable without
-- building a GUI fixture. SoilMapOverlay's repaired helper is driven by
-- RSF-F219-handful_ph_grain_spec_test.lua, which loads the real overlay and
-- renders real tooltips. The other eleven are dialog constructors.
--
-- Locked here:
--   A TRANSLATION WINS        - a present key renders its translation.
--   AN ABSENT KEY FALLS BACK  - to the English the author wrote, and the player
--                               never sees the engine's Missing sentence or a
--                               raw key name.
--   AN I18N THAT CANNOT ANSWER hasText IS REFUSED - this is the shape the shared
--                               prelude itself had before PR #972, and the shape
--                               a third-party i18n shim can still have.
--   EVERY UNTRUSTED RETURN FALLS BACK - empty, non-string, throwing, and a
--                               hasText that answers with a truthy non-boolean,
--                               which the engine never does (I18N.lua:194 returns
--                               texts[name] ~= nil).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/ui/SoilMapOverlay.lua, src/ui/SoilMinimapLayer.lua

local N_LAYER  = 1
local N_KEY    = "sf_map_layer_n"
local ENGLISH  = "N"                    -- LAYER_LABEL[1], the author's fallback
local TRANSLATED = "Stickstoff"

local saved = g_i18n

local function label()
    local ok, v = pcall(SoilMinimapLayer.buildLayerLabel, N_LAYER)
    if not ok then return "<threw: " .. tostring(v) .. ">" end
    return v
end

-- ── the key the function reaches for is the one we think it is ───────────────
T.eq("sites A1: the minimap N layer reads the key this bar pins",
     SoilMapOverlay.LAYER_KEYS[N_LAYER], N_KEY)

-- ── a real translation wins ──────────────────────────────────────────────────
g_i18n = { texts = { [N_KEY] = TRANSLATED },
           hasText = function(self, key) return self.texts[key] ~= nil end,
           getText = function(self, key) return self.texts[key] or
                     ("Missing '" .. tostring(key) .. "' in l10n_en.xml") end }
T.eq("sites A2: a present key renders its translation", label(), "Stickstoff [N]")

-- ── an absent key falls back to the author's English ─────────────────────────
g_i18n.texts = {}
local out = label()
T.eq("sites A3: an absent key renders the English fallback", out, ENGLISH)
T.ok("sites A4: and NOT the engine's missing sentence, which is the whole defect",
     not tostring(out):find("Missing", 1, true))
T.ok("sites A5: and NOT the raw key name", not tostring(out):find(N_KEY, 1, true))

-- ── the shape the old harness had, and a third-party shim still can ──────────
g_i18n = { getText = function(_self, key) return key end }
T.eq("sites A6: an i18n with getText and no hasText is refused", label(), ENGLISH)

g_i18n = { getText = function(_self, key)
               return "Missing '" .. tostring(key) .. "' in l10n_en.xml" end }
T.eq("sites A7: and refused even when its getText returns the engine sentence",
     label(), ENGLISH)

-- ── every untrusted return falls back ────────────────────────────────────────
local function i18nWith(opts)
    return {
        hasText = function()
            if opts.hasTextThrows then error("boom") end
            if opts.hasTextValue ~= nil then return opts.hasTextValue end
            return true
        end,
        getText = function()
            if opts.getTextThrows then error("boom") end
            return opts.getTextValue
        end,
    }
end

g_i18n = i18nWith({ hasTextValue = false, getTextValue = TRANSLATED })
T.eq("sites A8: hasText false falls back even with a translation behind it", label(), ENGLISH)

g_i18n = i18nWith({ hasTextValue = 1, getTextValue = TRANSLATED })
T.eq("sites A9: a truthy non-boolean hasText is not a yes (I18N.lua:194 returns a boolean)",
     label(), ENGLISH)

g_i18n = i18nWith({ hasTextThrows = true, getTextValue = TRANSLATED })
T.eq("sites A10: hasText throwing falls back", label(), ENGLISH)

g_i18n = i18nWith({ getTextThrows = true })
T.eq("sites A11: getText throwing falls back", label(), ENGLISH)

g_i18n = i18nWith({ getTextValue = "" })
T.eq("sites A12: an empty translation falls back", label(), ENGLISH)

g_i18n = i18nWith({ getTextValue = 42 })
T.eq("sites A13: a non-string translation falls back", label(), ENGLISH)

g_i18n = i18nWith({ getTextValue = {} })
T.eq("sites A14: a table translation falls back", label(), ENGLISH)

g_i18n = nil
T.eq("sites A15: a nil g_i18n falls back and does not throw", label(), ENGLISH)

-- ── the shared prelude itself, which is the harness every other bar runs on ──
g_i18n = saved
T.eq("sites A16: under the shared prelude with no locale loaded, the player sees English",
     label(), ENGLISH)
g_i18n:setText(N_KEY, TRANSLATED)
T.eq("sites A17: and a bar that registers the key sees the translation",
     label(), "Stickstoff [N]")
g_i18n.texts[N_KEY] = nil
