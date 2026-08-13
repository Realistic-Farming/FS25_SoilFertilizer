-- experimental_confirm_test.lua - the experimental gate never flips on one click.
--
-- The gate arms UNFINISHED systems on a live savegame, so the panel asks first.
-- The property that matters is not "a dialog appeared", it is that ABORT LEAVES
-- THE SETTING EXACTLY AS IT WAS. A confirmation that fails open is worse than no
-- confirmation at all, because the player now believes they declined.
--
-- Locked here:
--   ASK BEFORE ARMING   - flipping experimentalSystems routes through the dialog
--                         and does NOT reach the change path on its own.
--   ABORT IS A NO-OP    - answering no leaves the stored value untouched.
--   CONFIRM APPLIES     - answering yes performs exactly the requested change.
--   FAIL CLOSED         - if the dialog is unavailable the change is REFUSED,
--                         not silently applied. A gate that cannot ask must not
--                         open.
--   EVERY OTHER SETTING IS UNTOUCHED - the interception is surgical; no other
--                         setting gains a prompt.
--   NO PROMPT ON A NO-OP - re-selecting the value it already has must not ask.
--   RESET SKIPS THE ASK  - resetCurrentCategory runs in a loop a modal would
--                         break, and only ever restores the LOCKED default.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/ui/SoilSettingsPanel.lua

-- Force tr() down its fallback path so the assertions below read the English the
-- player sees. The prelude's stub returns the KEY, which tr() treats as a valid
-- translation; returning "" is the real "key absent" case.
g_i18n = { getText = function(_self, _key) return "" end, hasText = function() return false end }

-- ── A stand-in for the dialog, recording what it was asked ──────────────────
local shown = nil
local nextAnswer = nil          -- what the player "clicks"
local available = true

DialogElement = { TYPE_WARNING = 2, TYPE_QUESTION = 1 }

local function installDialog()
  if not available then YesNoDialog = nil return end
  YesNoDialog = {
    show = function(callback, target, text, title, yesText, noText, dialogType, _ys, _ns, args)
      shown = { text = text, title = title, yes = yesText, no = noText,
                dialogType = dialogType, args = args }
      if nextAnswer ~= nil then callback(target, nextAnswer, args) end
    end,
  }
end

-- ── A minimal panel over a fake settings store ──────────────────────────────
local function newPanel(isAdmin, startValue)
  local saved = { n = 0 }
  local settings = {
    experimentalSystems = startValue,
    difficulty = 2,
    save = function(_self) saved.n = saved.n + 1 end,
  }
  local p = {
    settings = settings,
    _saved = saved,
    isAdmin = function() return isAdmin ~= false end,
  }
  return setmetatable(p, { __index = SoilSettingsPanel })
end

local function reset(answer, dialogAvailable)
  shown, nextAnswer, available = nil, answer, dialogAvailable ~= false
  installDialog()
end

-- ── ASK BEFORE ARMING ───────────────────────────────────────────────────────
do
  reset(nil)                       -- dialog opens, player has not answered yet
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)

  T.ok("turning the gate on opens a confirmation", shown ~= nil)
  T.eq("the setting is NOT changed while the question is open", p.settings.experimentalSystems, false)
  T.eq("the dialog carries the requested value", shown.args.value, true)
  T.eq("it is presented as a warning, not a neutral question", shown.dialogType, DialogElement.TYPE_WARNING)
  T.ok("the warning says the systems are unfinished", shown.text:find("NOT finished", 1, true) ~= nil)
  T.ok("the warning tells the player to back up", shown.text:lower():find("backup", 1, true) ~= nil)
end

-- ── ABORT IS A NO-OP ────────────────────────────────────────────────────────
do
  reset(false)
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)
  T.eq("abort leaves the gate off", p.settings.experimentalSystems, false)
  T.eq("abort writes nothing to disk", p._saved.n, 0)
end

do
  -- The same guarantee in the other direction: aborting a disable must not disable.
  reset(false)
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", false)
  T.eq("abort leaves the gate on", p.settings.experimentalSystems, true)
  T.eq("abort writes nothing to disk", p._saved.n, 0)
end

-- ── CONFIRM APPLIES ─────────────────────────────────────────────────────────
do
  reset(true)
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)
  T.eq("confirm arms the gate", p.settings.experimentalSystems, true)
  T.ok("confirm persists the change", p._saved.n > 0)
end

do
  reset(true)
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", false)
  T.eq("confirm disarms the gate", p.settings.experimentalSystems, false)
  T.ok("the off warning explains what stops", shown.text:lower():find("stop running", 1, true) ~= nil)
end

-- ── FAIL CLOSED ─────────────────────────────────────────────────────────────
do
  reset(true, false)               -- YesNoDialog absent entirely
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)
  T.eq("with no dialog available the gate REFUSES rather than opening",
    p.settings.experimentalSystems, false)
  T.eq("and nothing is written", p._saved.n, 0)
end

-- ── NO PROMPT ON A NO-OP ────────────────────────────────────────────────────
do
  reset(nil)
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", true)   -- already true
  T.ok("re-selecting the current value asks nothing", shown == nil)
end

-- ── EVERY OTHER SETTING IS UNTOUCHED ────────────────────────────────────────
do
  reset(nil)
  local p = newPanel(true, false)
  p:requestChange("difficulty", 3)
  T.ok("an ordinary setting never opens the confirmation", shown == nil)
  T.eq("an ordinary setting applies immediately", p.settings.difficulty, 3)
end

-- ── A NON-ADMIN IS REFUSED BEFORE BEING WARNED ──────────────────────────────
do
  reset(nil)
  local p = newPanel(false, false)
  p:requestChange("experimentalSystems", true)
  T.ok("a non-admin is never shown a confirmation we would then reject", shown == nil)
  T.eq("and the gate stays shut", p.settings.experimentalSystems, false)
end

-- ── RESET SKIPS THE ASK ─────────────────────────────────────────────────────
do
  reset(nil)
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", false, true)
  T.ok("a reset does not open a modal inside its loop", shown == nil)
  T.eq("a reset restores the locked default directly", p.settings.experimentalSystems, false)
end
