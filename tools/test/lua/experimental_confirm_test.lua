-- experimental_confirm_test.lua - the experimental gate never flips on one click.
--
-- The gate arms UNFINISHED systems on a live savegame, so the panel asks first.
-- The property that matters is not "a prompt appeared", it is that ABORT LEAVES
-- THE SETTING EXACTLY AS IT WAS. A confirmation that fails open is worse than no
-- confirmation at all, because the player now believes they declined.
--
-- The prompt is DRAWN inside the settings panel rather than shown as a base-game
-- YesNoDialog, and that is not only a style choice: SoilSettingsPanel:update()
-- closes the panel whenever g_gui reports a dialog visible, so a GUI dialog would
-- dismiss the very panel the player is answering for.
--
-- Locked here:
--   ASK BEFORE ARMING   - flipping experimentalSystems raises the prompt and does
--                         NOT reach the change path on its own.
--   ABORT IS A NO-OP    - answering no leaves the stored value untouched.
--   CONFIRM APPLIES     - answering yes performs exactly the requested change.
--   NO PENDING STATE SURVIVES - closing the panel aborts the question; a pending
--                         value must never outlive the surface that asked.
--   EVERY OTHER SETTING IS UNTOUCHED - the interception is surgical.
--   NO PROMPT ON A NO-OP - re-selecting the value it already has must not ask.
--   RESET SKIPS THE ASK  - resetCurrentCategory runs in a loop a modal would
--                         break, and only ever restores the LOCKED default.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SettingsSchema.lua, src/ui/SoilSettingsPanel.lua

-- Force tr() down its fallback path so the assertions below read the English the
-- player sees. The prelude's stub returns the KEY, which tr() treats as a valid
-- translation; returning "" is the real "key absent" case.
g_i18n = { getText = function(_self, _key) return "" end, hasText = function() return false end }

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
    isVisible = true,
    isAdmin = function() return isAdmin ~= false end,
  }
  return setmetatable(p, { __index = SoilSettingsPanel })
end

-- ── ASK BEFORE ARMING ───────────────────────────────────────────────────────
do
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)

  T.ok("turning the gate on raises the prompt", p.confirmVisible == true)
  T.eq("the setting is NOT changed while the question is open", p.settings.experimentalSystems, false)
  T.eq("the pending value is the requested one", p.confirmValue, true)
  T.eq("nothing is written while the question is open", p._saved.n, 0)
  T.ok("the warning says the systems are unfinished",
    p.confirmText:find("NOT finished", 1, true) ~= nil)
  T.ok("the warning tells the player to keep a backup",
    p.confirmText:lower():find("backup", 1, true) ~= nil)
  T.ok("the question is asked as its own line, not buried in the body",
    p.confirmQuestion:find("ON?", 1, true) ~= nil)
  T.ok("the body does not repeat the question",
    p.confirmText:find("Turn experimental", 1, true) == nil)
end

-- ── ABORT IS A NO-OP, IN BOTH DIRECTIONS ────────────────────────────────────
do
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)
  p:handleClick("exp_confirm_no")
  T.eq("abort leaves the gate off", p.settings.experimentalSystems, false)
  T.eq("abort writes nothing to disk", p._saved.n, 0)
  T.ok("abort clears the prompt", p.confirmVisible == false)
  T.eq("abort clears the pending value", p.confirmValue, nil)
end

do
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", false)
  T.ok("the off warning explains what stops",
    p.confirmText:lower():find("stop running", 1, true) ~= nil)
  p:handleClick("exp_confirm_no")
  T.eq("abort leaves the gate on", p.settings.experimentalSystems, true)
  T.eq("abort writes nothing to disk", p._saved.n, 0)
end

-- ── CONFIRM APPLIES ─────────────────────────────────────────────────────────
do
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)
  p:handleClick("exp_confirm_yes")
  T.eq("confirm arms the gate", p.settings.experimentalSystems, true)
  T.ok("confirm persists the change", p._saved.n > 0)
  T.ok("confirm clears the prompt", p.confirmVisible == false)
end

do
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", false)
  p:handleClick("exp_confirm_yes")
  T.eq("confirm disarms the gate", p.settings.experimentalSystems, false)
end

-- ── NO PENDING STATE SURVIVES THE SURFACE THAT ASKED ────────────────────────
do
  -- Escape, the [X], the hotkey and the auto-close in update() all route through
  -- close(). None of them is an answer, so none may leave a live pending value
  -- that a later Confirm could pick up.
  local p = newPanel(true, false)
  p:requestChange("experimentalSystems", true)
  p:close()
  T.ok("closing the panel clears the prompt", p.confirmVisible == false)
  T.eq("closing the panel clears the pending value", p.confirmValue, nil)
  T.eq("closing the panel changes nothing", p.settings.experimentalSystems, false)

  -- And a Confirm arriving after the close must be inert rather than replaying.
  p:handleClick("exp_confirm_yes")
  T.eq("a stale confirm after close applies nothing", p.settings.experimentalSystems, false)
  T.eq("and still writes nothing", p._saved.n, 0)
end

-- ── NO PROMPT ON A NO-OP ────────────────────────────────────────────────────
do
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", true)   -- already true
  T.ok("re-selecting the current value asks nothing", p.confirmVisible ~= true)
end

-- ── EVERY OTHER SETTING IS UNTOUCHED ────────────────────────────────────────
do
  local p = newPanel(true, false)
  p:requestChange("difficulty", 3)
  T.ok("an ordinary setting never raises the prompt", p.confirmVisible ~= true)
  T.eq("an ordinary setting applies immediately", p.settings.difficulty, 3)
end

-- ── A NON-ADMIN IS REFUSED BEFORE BEING WARNED ──────────────────────────────
do
  local p = newPanel(false, false)
  p:requestChange("experimentalSystems", true)
  T.ok("a non-admin is never shown a prompt we would then reject", p.confirmVisible ~= true)
  T.eq("and the gate stays shut", p.settings.experimentalSystems, false)
end

-- ── RESET SKIPS THE ASK ─────────────────────────────────────────────────────
do
  local p = newPanel(true, true)
  p:requestChange("experimentalSystems", false, true)
  T.ok("a reset does not raise a modal inside its loop", p.confirmVisible ~= true)
  T.eq("a reset restores the locked default directly", p.settings.experimentalSystems, false)
end
