-- RSF-F192-dog_warning_l10n_test.lua - the dog's two warnings resolve through the
-- mod's locale keys, with the exact English sentence as the only fallback.
--
-- Drives the real DogEarlyWarning:_notify with a recorded HUD and a controlled
-- g_i18n. Locale file coverage (both keys in all 27 files, one %s each) is a text
-- fact checked by grep in the PR; fengari has no file IO.
--
--!load: src/DogEarlyWarning.lua

local EN_FIELD = "Your dog senses something wrong with Field #%s."
local EN_BARN  = "Your dog senses something wrong at Barn %s."

T.eq("F192: field fallback is the exact English sentence", DogEarlyWarning.FIELD_WARNING_FALLBACK, EN_FIELD)
T.eq("F192: barn fallback is the exact English sentence", DogEarlyWarning.BARN_WARNING_FALLBACK, EN_BARN)

local shown = {}
local function newHud()
  shown = {}
  g_currentMission = { hud = { showBlinkingWarning = function(_self, msg, ms) shown[#shown + 1] = { msg = msg, ms = ms } end } }
end

local function i18nWith(texts, opts)
  opts = opts or {}
  return {
    hasText = function(_self, key)
      if opts.hasTextThrows then error("boom") end
      if opts.hasTextValue ~= nil then return opts.hasTextValue end
      return texts[key] ~= nil
    end,
    getText = function(_self, key)
      if opts.getTextThrows then error("boom") end
      local t = texts[key]
      if t == nil then return "Missing '" .. key .. "' in l10n" end   -- engine shape, never nil
      return t
    end,
  }
end

local function notify(dog, list)
  newHud()
  dog:_notify(1, list)
  return shown
end

-- ── Localized templates are used, one %s filled with the identifier ───────────
do
  g_i18n = i18nWith({ sf_dog_field_warning = "Feld #%s riecht komisch.", sf_dog_barn_warning = "Stall %s riecht komisch." })
  local dog = DogEarlyWarning.new({})
  local out = notify(dog, { { fieldId = 12, type = "crop" }, { fieldId = "B3", type = "barn" } })
  T.eq("F192: two warnings shown", #out, 2)
  T.eq("F192: localized field sentence", out[1].msg, "Feld #12 riecht komisch.")
  T.eq("F192: localized barn sentence", out[2].msg, "Stall B3 riecht komisch.")
  T.eq("F192: HUD duration unchanged (field)", out[1].ms, 5000)
  T.eq("F192: HUD duration unchanged (barn)", out[2].ms, 5000)
end

-- ── Every untrusted lookup falls back to the exact English sentence and still warns ─
local cases = {
  { name = "hasText false",            i18n = i18nWith({ sf_dog_field_warning = "x %s" }, { hasTextValue = false }) },
  { name = "hasText non-boolean",      i18n = i18nWith({ sf_dog_field_warning = "x %s" }, { hasTextValue = 1 }) },
  { name = "hasText throws",           i18n = i18nWith({ sf_dog_field_warning = "x %s" }, { hasTextThrows = true }) },
  { name = "getText throws",           i18n = i18nWith({ sf_dog_field_warning = "x %s" }, { getTextThrows = true }) },
  { name = "getText non-string",       i18n = i18nWith({ sf_dog_field_warning = 42 }) },
  { name = "empty template",           i18n = i18nWith({ sf_dog_field_warning = "" }) },
  { name = "%d instead of %s",         i18n = i18nWith({ sf_dog_field_warning = "Field %d is off." }) },
  { name = "no placeholder",           i18n = i18nWith({ sf_dog_field_warning = "Something is off." }) },
  { name = "two placeholders",         i18n = i18nWith({ sf_dog_field_warning = "%s and %s" }) },
  { name = "extra conversion",         i18n = i18nWith({ sf_dog_field_warning = "%s costs %.1f" }) },
  { name = "trailing lone percent",    i18n = i18nWith({ sf_dog_field_warning = "Field %s at 50%" }) },
  { name = "engine missing diagnostic", i18n = i18nWith({}, { hasTextValue = true }) },
  { name = "no hasText method",        i18n = { getText = function() return "x %s" end } },
  { name = "no getText method",        i18n = { hasText = function() return true end } },
  { name = "g_i18n absent",            i18n = nil },
}
for _, c in ipairs(cases) do
  g_i18n = c.i18n
  local dog = DogEarlyWarning.new({})
  local ok, out = pcall(notify, dog, { { fieldId = 7, type = "crop" } })
  T.ok("F192 fallback (" .. c.name .. "): _notify does not throw", ok)
  T.eq("F192 fallback (" .. c.name .. "): still warns once", ok and #out, 1)
  T.eq("F192 fallback (" .. c.name .. "): exact English sentence", ok and out[1].msg, "Your dog senses something wrong with Field #7.")
end

-- An escaped percent is a literal and does not disqualify a template.
do
  g_i18n = i18nWith({ sf_dog_barn_warning = "Barn %s is 100%% off." })
  local dog = DogEarlyWarning.new({})
  local out = notify(dog, { { fieldId = 4, type = "barn" } })
  T.eq("F192: escaped %% is literal", out[1].msg, "Barn 4 is 100% off.")
end

-- ── Dedupe, stale cleanup and delivery are unchanged ─────────────────────────
do
  g_i18n = i18nWith({})
  local dog = DogEarlyWarning.new({})
  local list = { { fieldId = 1, type = "crop" }, { fieldId = 2, type = "barn" } }
  local first = notify(dog, list)
  T.eq("F192: first pass warns for both", #first, 2)
  T.eq("F192: dedupe key set (field)", dog.notifiedFields[1]["1_crop"], true)
  T.eq("F192: dedupe key set (barn)", dog.notifiedFields[1]["2_barn"], true)
  local second = notify(dog, list)
  T.eq("F192: second pass repeats nothing", #second, 0)
  local third = notify(dog, { { fieldId = 2, type = "barn" } })
  T.eq("F192: still nothing new", #third, 0)
  T.eq("F192: stale field key cleaned", dog.notifiedFields[1]["1_crop"], nil)
  T.eq("F192: live barn key kept", dog.notifiedFields[1]["2_barn"], true)
  local fourth = notify(dog, { { fieldId = 1, type = "crop" }, { fieldId = 2, type = "barn" } })
  T.eq("F192: a cleaned key warns again", #fourth, 1)
  T.eq("F192: ...and it is the field one", fourth[1].msg, "Your dog senses something wrong with Field #1.")
end

-- A HUD that is missing or throws never breaks the dedupe latch or the cleanup.
do
  g_i18n = i18nWith({})
  local dog = DogEarlyWarning.new({})
  g_currentMission = { hud = { showBlinkingWarning = function() error("hud down") end } }
  local ok = pcall(dog._notify, dog, 1, { { fieldId = 9, type = "crop" } })
  T.ok("F192: a throwing HUD is contained", ok)
  T.eq("F192: the latch was set before the HUD call", dog.notifiedFields[1]["9_crop"], true)
  g_currentMission = nil
  ok = pcall(dog._notify, dog, 1, {})
  T.ok("F192: no mission at all is contained", ok)
  T.eq("F192: cleanup ran with no mission", dog.notifiedFields[1]["9_crop"], nil)
end

-- The formatter itself, on its own: identifier is tostring'd, nil included.
do
  g_i18n = nil
  T.eq("F192: formatWarning tostrings a number", DogEarlyWarning.formatWarning("k", EN_BARN, 3), "Your dog senses something wrong at Barn 3.")
  T.eq("F192: formatWarning tostrings nil", DogEarlyWarning.formatWarning("k", EN_FIELD, nil), "Your dog senses something wrong with Field #nil.")
end
