-- RSF-F345-wave1_status_text_test.lua - the HUD status tokens are translated at the
-- render call and nowhere else (RSF-F345 wave 1, F346).
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/utils/SoilUtils.lua, src/ui/SoilHUD.lua
--
-- Contract under test (brief v0.4, part B1):
--   * "Good" / "Fair" / "Poor" / "Unknown" stay bare internal tokens; only the drawn
--     text goes through sf_hud_status_<token>.
--   * hasText gates getText. A missing key, an empty result, a "$l10n_<key>"
--     placeholder or a throwing lookup all render exactly today's English token and
--     never a key name.
--   * Tokens outside the family pass through untouched.

local function i18n(entries, opts)
  opts = opts or {}
  return {
    hasText = function(_, key)
      if opts.hasTextThrows then error("boom") end
      if opts.hasTextTruthyNonBool then return 1 end
      return entries[key] ~= nil
    end,
    getText = function(_, key)
      if opts.getTextThrows then error("boom") end
      local v = entries[key]
      if v == nil then return "$l10n_" .. key end
      return v
    end,
  }
end

local TOKENS = { "Good", "Fair", "Poor", "Unknown" }
local KEYS = {
  Good = "sf_hud_status_good", Fair = "sf_hud_status_fair",
  Poor = "sf_hud_status_poor", Unknown = "sf_hud_status_unknown",
}

-- ── key table is exactly the four keys the locale files carry ──
for token, key in pairs(KEYS) do
  T.eq("key map: " .. token, SoilHUD.STATUS_TEXT_KEYS[token], key)
end
do
  local n = 0
  for _ in pairs(SoilHUD.STATUS_TEXT_KEYS) do n = n + 1 end
  T.eq("key map: exactly four entries", n, 4)
end

-- ── no i18n at all: today's token ──
_G.g_i18n = nil
for _, tok in ipairs(TOKENS) do
  T.eq("no g_i18n: " .. tok, SoilHUD.statusText(tok), tok)
end

-- ── translated: the locale value is drawn ──
_G.g_i18n = i18n({
  sf_hud_status_good = "Gut", sf_hud_status_fair = "Mittel",
  sf_hud_status_poor = "Schlecht", sf_hud_status_unknown = "Unbekannt",
})
T.eq("de: Good", SoilHUD.statusText("Good"), "Gut")
T.eq("de: Fair", SoilHUD.statusText("Fair"), "Mittel")
T.eq("de: Poor", SoilHUD.statusText("Poor"), "Schlecht")
T.eq("de: Unknown", SoilHUD.statusText("Unknown"), "Unbekannt")

-- ── unmarked English shipped in every locale today: identical to pre-wave text ──
_G.g_i18n = i18n({
  sf_hud_status_good = "Good", sf_hud_status_fair = "Fair",
  sf_hud_status_poor = "Poor", sf_hud_status_unknown = "Unknown",
})
for _, tok in ipairs(TOKENS) do
  T.eq("unmarked en: " .. tok, SoilHUD.statusText(tok), tok)
end

-- ── each key deleted in turn: that token falls back, the others still translate ──
for _, missing in ipairs(TOKENS) do
  local entries = {
    sf_hud_status_good = "Gut", sf_hud_status_fair = "Mittel",
    sf_hud_status_poor = "Schlecht", sf_hud_status_unknown = "Unbekannt",
  }
  entries[KEYS[missing]] = nil
  _G.g_i18n = i18n(entries)
  T.eq("missing " .. missing .. ": renders the bare token", SoilHUD.statusText(missing), missing)
  T.ok("missing " .. missing .. ": never the key name", (SoilHUD.statusText(missing)) ~= (KEYS[missing]))
  T.ok("missing " .. missing .. ": never the placeholder", (SoilHUD.statusText(missing)) ~= ("$l10n_" .. KEYS[missing]))
  for _, other in ipairs(TOKENS) do
    if other ~= missing then
      T.ok("missing " .. missing .. ": " .. other .. " still translated", (SoilHUD.statusText(other)) ~= (other))
    end
  end
end

-- ── the unsafe idiom's failure shape: hasText true but getText hands back the placeholder ──
_G.g_i18n = {
  hasText = function() return true end,
  getText = function(_, key) return "$l10n_" .. key end,
}
for _, tok in ipairs(TOKENS) do
  T.eq("placeholder from getText: " .. tok, SoilHUD.statusText(tok), tok)
end

-- ── empty string from getText ──
_G.g_i18n = { hasText = function() return true end, getText = function() return "" end }
T.eq("empty getText falls back", SoilHUD.statusText("Good"), "Good")

-- ── non-string from getText ──
_G.g_i18n = { hasText = function() return true end, getText = function() return 42 end }
T.eq("non-string getText falls back", SoilHUD.statusText("Poor"), "Poor")

-- ── hasText truthy but not boolean true is not trusted ──
_G.g_i18n = i18n({ sf_hud_status_good = "Gut" }, { hasTextTruthyNonBool = true })
T.eq("hasText returning 1 is not a yes", SoilHUD.statusText("Good"), "Good")

-- ── throwing lookups never escape the render call ──
_G.g_i18n = i18n({ sf_hud_status_good = "Gut" }, { hasTextThrows = true })
T.eq("hasText throws: bare token", SoilHUD.statusText("Good"), "Good")
_G.g_i18n = i18n({ sf_hud_status_good = "Gut" }, { getTextThrows = true })
T.eq("getText throws: bare token", SoilHUD.statusText("Good"), "Good")

-- ── i18n without the hasText method (old engine shape) ──
_G.g_i18n = { getText = function() return "Gut" end }
T.eq("no hasText method: bare token", SoilHUD.statusText("Good"), "Good")

-- ── tokens outside the family pass straight through ──
_G.g_i18n = i18n({ sf_hud_status_good = "Gut" })
T.eq("foreign token untouched", SoilHUD.statusText("Weird"), "Weird")
T.eq("nil token passes through", SoilHUD.statusText(nil), nil)
T.eq("empty token passes through", SoilHUD.statusText(""), "")

-- ── the internal token is still the colour key: translating the text never moves it ──
_G.g_i18n = i18n({ sf_hud_status_good = "Gut", sf_hud_status_fair = "Mittel" })
do
  local hud = setmetatable({ settings = {} }, { __index = SoilHUD })
  local okG, good = pcall(hud.statusColor, hud, "Good")
  local okP, poor = pcall(hud.statusColor, hud, "Poor")
  local okT, viaText = pcall(hud.statusColor, hud, SoilHUD.statusText("Good"))
  T.ok("statusColor callable with the bare tokens and the drawn text", okG and okP and okT)
  T.ok("statusColor keys on the bare token, not the drawn text", viaText ~= good)
  T.eq("a translated token would fall to the poor colour", viaText, poor)
end

_G.g_i18n = nil
