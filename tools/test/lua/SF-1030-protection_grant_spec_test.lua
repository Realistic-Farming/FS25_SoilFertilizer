-- SF-1030-protection_grant_spec_test.lua: #1030 bug 3, crop protection is granted
-- once coverage passes 80%, whatever the day's reduction cap has left.
--
-- The >= 80% grant (COVERAGE.PROTECTION_THRESHOLD, #441) sat inside each route's
-- `reduction > 0` block: the herbicide direct path, and the insecticide and fungicide
-- incrementals, which the other four routes call only when their capped reduction is
-- positive. Once a field's daily cap was spent, crossing 80% later that day never
-- protected it. The grant is now one helper, _grantCropProtection, called on every
-- tick at all five routes; a newly granted window sends one field update.
--
-- ENTRY-POINT BAR: every group drives passes through the real sprayer hook into the
-- real soil system (MAINT-166-protection_sprayer_world.lua), one group per route:
--   H  HERBICIDE      herbicide direct         (onHerbicideAppliedDirect)
--   P  PESTICIDE      insecticide direct       (onInsecticideAppliedDirect)
--   Z  PROPICONAZOLE  fungicide direct         (onFungicideAppliedDirect)
--   I  INSECTICIDE    applyFertilizer, pest branch
--   F  FUNGICIDE      applyFertilizer, disease branch
-- The field record comes from scanFields, the settings from a real Settings object,
-- coverage from the passes' own markBoomCells, the cap from the routes' own capped
-- reduction, and the field update from the real SoilFieldUpdateEvent through the real
-- broadcaster (NetworkEvents.lua) on a multiplayer host. Nothing sets a fraction, a
-- cap entry or a days count by hand.
--
-- Each route group: pass 1 opens the session (one cell, a trickle), pass 2 sprays the
-- field's full reference dose on one cell (the day's cap is spent at 10% coverage, no
-- protection), passes 3-16 add one cell each at a trickle (coverage reaches 80%, the
-- cap stays spent, nothing is sent), pass 17 grants (every route reads the fraction
-- the previous pass left, because the hook's markBoomCells runs after the route) and
-- sends exactly one field update carrying the window, and pass 18 sends nothing more.
-- (P ran as its own group until MAINTENANCE row 168 stopped its coverage resetting.)
--   S  a route whose pressure setting is off grants nothing (the helper's gate)
--
-- Targeted mutations: re-nest each route's grant inside its reduction gate (five, each
-- must fail its own route only); drop the helper's setting gate (S must fail); report
-- every grant as new (the pass 18 rows must fail).
--
-- Not proven here: the daily decrement of the window, the HUD, and anything in game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/maps/SoilValueMaps.lua, src/OrganicCertification.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/network/NetworkEvents.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group

--- Field updates for field 7 among world.events[from + 1 ..].
local function sendsSince(w, from)
  local n, last = 0, nil
  for i = from + 1, #w.events do
    local ev = w.events[i]
    if ev and ev.fieldId == 7 then n = n + 1; last = ev end
  end
  return n, last
end

local ROUTES = {
  { key = "H", product = "HERBICIDE",     daily = "herbicideDailyApplied",   days = "herbicideDaysLeft",   what = "herbicide direct" },
  { key = "P", product = "PESTICIDE",     daily = "insecticideDailyApplied", days = "insecticideDaysLeft", what = "insecticide direct" },
  { key = "Z", product = "PROPICONAZOLE", daily = "fungicideDailyApplied",   days = "fungicideDaysLeft",   what = "fungicide direct" },
  { key = "I", product = "INSECTICIDE",   daily = "insecticideDailyApplied", days = "insecticideDaysLeft", what = "applyFertilizer insecticide" },
  { key = "F", product = "FUNGICIDE",     daily = "fungicideDailyApplied",   days = "fungicideDaysLeft",   what = "applyFertilizer fungicide" },
}

for _, r in ipairs(ROUTES) do
  local K = r.key
  group(K .. " " .. r.what, function()
    -- 0.195 ha, so sixteen 0.01 ha cells are 82%. On a field of exactly twenty cells the
    -- sixteenth sits on 0.80 to the last floating-point bit; until MAINTENANCE row 170 the
    -- fertilizer-profile routes (I, F) were carried over it by a first-tick litre count
    -- they should never have had. 20 L on pass 2 still spends the day's cap (19.5 L).
    local w = PSW.new({ product = r.product, multiplayer = true, areaHa = 0.195 })
    local sys = w.sys
    w:tick(0.01, w:cells(1, 1))
    local f = w:field()
    T.eq(K .. "1 [reached: the " .. r.what .. " route ran through the hook]", sys[r.daily] ~= nil and sys[r.daily][7] ~= nil, true)
    w:tick(20, w:cells(2, 2))
    local spent = sys[r.daily][7].applied
    w:tick(0.2, w:cells(3, 3))
    T.eq(K .. "2 [reached: the day's cap is spent on pass 2: pass 3 adds no reduction]", sys[r.daily][7].applied, spent)
    T.ok(K .. "3 [reached: at about 15% coverage]", (f.sessionCoverageFraction or 0) < 0.80)
    T.eq(K .. "4 below 80% there is no protection", f[r.days] or 0, 0)
    local e3 = #w.events
    for i = 4, 16 do w:tick(0.2, w:cells(i, i)) end
    T.ok(K .. "5 [reached: the passes' own coverage is past 80%]", (f.sessionCoverageFraction or 0) >= 0.80)
    T.eq(K .. "6 [reached: the cap is still spent]", sys[r.daily][7].applied, spent)
    T.eq(K .. "7 passes 4-16 send nothing (no reduction, no grant)", (sendsSince(w, e3)), 0)
    local e16 = #w.events
    w:tick(0.2, w:cells(17, 17))
    T.ok(K .. "8 NAMED: past 80% with the day's cap spent, the " .. r.what .. " route grants protection", (f[r.days] or 0) > 0)
    local n, ev = sendsSince(w, e16)
    T.eq(K .. "9 MP: the grant sends exactly one field update", n, 1)
    T.ok(K .. "10 and that update carries the window", ev ~= nil and ev.field ~= nil and (ev.field[r.days] or 0) > 0)
    local e17 = #w.events
    w:tick(0.2, w:cells(18, 18))
    T.eq(K .. "11 an already protected field sends nothing more", (sendsSince(w, e17)), 0)
    T.ok(K .. "12 and stays protected", (f[r.days] or 0) > 0)
    T.eq(K .. "13 no weed-map task at any point (MAINTENANCE row 166)", #w.tasks, 0)
  end)
end

-- ── S: a route whose pressure setting is off grants nothing ─────────────────────
group("S setting off", function()
  local w = PSW.new({ product = "INSECTICIDE", multiplayer = true })
  w.sys.settings.pestPressure = SettingsSchema.validate("pestPressure", false)
  w:tick(0.01, w:cells(1, 1))
  for i = 2, 18 do w:tick(0.2, w:cells(i, i)) end
  local f = w:field()
  T.ok("S1 [reached: the passes' own coverage is past 80%]", (f.sessionCoverageFraction or 0) >= 0.80)
  T.eq("S2 NAMED: with pest pressure off, the applyFertilizer insecticide route grants nothing", f.insecticideDaysLeft or 0, 0)
end)

PSW.restore()
