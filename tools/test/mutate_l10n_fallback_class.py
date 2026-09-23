#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MAINTENANCE rows 59 and 60: the shared gate (src/utils/SoilL10n.lua) and the
repaired fallback sites. Rows live in l10n_fallback_class_test.lua and
l10n_fallback_panels_test.lua.

Each mutation puts a plausible defect back (the old shape at a site, or a half of
the gate removed) and requires a bar to go RED with named rows. Each edit asserts it
LANDED by exact occurrence count first (a no-op edit and an unpinned rule both look
like SURVIVED); the restore is proved by sha256.

KILLED* means killed only by a Lua error: a weak kill, treated as a failure.

NOT RUN, and why:
  - a gate on the SHAPE of the missing sentence (`text:find("^Missing")`) in place of
    hasText: under the prelude the sentence starts with "Missing" in every language,
    so the bar cannot tell it from hasText; the rule against it is PR #973's reasoning
    (the sentence carries g_languageSuffix and is reassigned at runtime), not a row;
  - the sites the bars do not reach (HookManager's field-info row, SoilMapHooks' page
    title, SoilFertilityManager's sensor message, SoilMapOverlay's layer names and
    health header, SoilTreatmentRates' helper): the same one-line rewrite as the
    reached ones, read by the reviewer; the lint rule l10n-dead-or-fallback refuses
    the old `or` shape anywhere in src, which is the mechanical check for them;
  - the twelve per-file hasText helpers repaired in PR #973: untouched here, pinned
    by mutate_l10n_gate_sites.py;
  - the gate's type checks on the i18n object (hasText and getText being functions):
    masked by the pcalls behind them, which turn a missing method into the fallback
    as well, so removing a type check changes no observable result; they are the
    reader's statement of intent, not a second defence.

run-tests.mjs has no single-file filter, so this reads the per-file result lines out
of the full run. RUN IT ALONE (a battery edits production files in place).

Usage: py tools/test/mutate_l10n_fallback_class.py [id-prefix ...]
"""
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

L10N = "src/utils/SoilL10n.lua"
HUD = "src/ui/SoilHUD.lua"
SET = "src/ui/SoilSettingsPanel.lua"
SPR = "src/ui/SoilSprayerInfoPanel.lua"
HRV = "src/ui/SoilHarvesterPanel.lua"
EST = "src/EstablishmentFailure.lua"
MAIN = "src/main.lua"
BARS = ("l10n_fallback_class_test.lua", "l10n_fallback_panels_test.lua")

MUTATIONS = [
 # ── the gate ───────────────────────────────────────────────────────────────
 ("G1-hastext-gate-removed", L10N,
  [("    local okHas, has = pcall(i18n.hasText, i18n, key)\n    if not okHas or has ~= true then return fallback end\n", "", 1)],
  "an absent key returns the engine's sentence: the whole defect class, back"),
 ("G2-truthy-hastext-accepted", L10N,
  [("    if not okHas or has ~= true then return fallback end", "    if not okHas or not has then return fallback end", 1)],
  "a non-boolean yes from a foreign i18n object is trusted"),
 ("G3-type-check-dropped", L10N,
  [('    if not ok or type(text) ~= "string" or text == "" then return fallback end', '    if not ok or text == "" then return fallback end', 1)],
  "a key holding a non-string is returned as the text"),
 ("G4-empty-check-dropped", L10N,
  [('    if not ok or type(text) ~= "string" or text == "" then return fallback end', '    if not ok or type(text) ~= "string" then return fallback end', 1)],
  "a key holding an empty string is returned as the text"),
 ("G5-gettext-not-protected", L10N,
  [("    local ok, text = pcall(i18n.getText, i18n, key)\n    if not ok or", "    local ok, text = true, i18n:getText(key)\n    if not ok or", 1)],
  "a getText that raises takes the caller down"),
 ("G6-hastext-not-protected", L10N,
  [("    local okHas, has = pcall(i18n.hasText, i18n, key)", "    local okHas, has = true, i18n:hasText(key)", 1)],
  "a hasText that raises takes the caller down"),
 # ── the sites, old shapes restored ─────────────────────────────────────────
 ("S1-state-title-or-fallback", SET,
  [('local stateTitle = SoilL10n.tr("sf_set_state_title", "SET FIELD STATE")',
    'local stateTitle = g_i18n and g_i18n:getText("sf_set_state_title") or "SET FIELD STATE"', 1)],
  "the set-state title shows the engine's sentence to every player (row 59's live case)"),
 ("S2-disease-title-or-fallback", SET,
  [('local diseaseTitle = SoilL10n.tr("sf_set_disease_title", "SET FIELD DISEASE")',
    'local diseaseTitle = g_i18n and g_i18n:getText("sf_set_disease_title") or "SET FIELD DISEASE"', 1)],
  "the set-disease title likewise"),
 ("S3-nutrient-label-or-fallback", SET,
  [('label = SoilL10n.tr("sf_map_layer_n", "Nitrogen (N)"),', 'label = g_i18n and g_i18n:getText("sf_map_layer_n") or "Nitrogen (N)",', 1)],
  "a nutrient label reads the sentence when its key is absent"),
 ("S4-rotation-na-or-fallback", HUD,
  [('value = rotStr or SoilL10n.tr("sf_report_rotation_na", "N/A")', 'value = rotStr or (g_i18n:getText("sf_report_rotation_na") or "N/A")', 1)],
  "the rotation N/A row shows the sentence (26 language files lack the key today)"),
 ("S5-grade-label-or-fallback", HUD,
  [('label = SoilL10n.tr("sf_fieldinfo_grade", "Soil Grade"), value', 'label = g_i18n:getText("sf_fieldinfo_grade") or "Soil Grade", value', 1)],
  "the grade label reads the sentence"),
 ("S6-disease-unknown-or-fallback", HUD,
  [('local unknownStr = SoilL10n.tr("sf_hud_disease_unknown", SoilL10n.tr("sf_hud_disease", "? (scout to identify)"))',
    'local unknownStr = (g_i18n:hasText("sf_hud_disease_unknown") and g_i18n:getText("sf_hud_disease_unknown"))\n            or g_i18n:getText("sf_hud_disease") or "? (scout to identify)"', 1)],
  "the unknown-disease marker falls through to an ungated second key"),
 ("S7-asleep-or-fallback", HUD,
  [('simStatusStr = SoilL10n.tr(info.simDisabledReasonKey, info.simDisabledReason or SoilL10n.tr("sf_fieldsentry_asleep", "asleep"))',
    'simStatusStr = (info.simDisabledReasonKey and g_i18n:getText(info.simDisabledReasonKey))\n            or info.simDisabledReason\n            or g_i18n:getText("sf_fieldsentry_asleep") or "asleep"', 1)],
  "an absent reason key shows the sentence instead of the plain reason"),
 ("S8-sprayer-field-prefix-find", SPR,
  [('        local fmtStr = SoilL10n.tr("sf_hud_field")\n        fieldStr = " · " .. (fmtStr and string.format(fmtStr, self._fieldId) or tostring(self._fieldId))',
    '        local ok2, fmtStr = pcall(function() return g_i18n:getText("sf_hud_field") end)\n        fieldStr = " · " .. ((ok2 and fmtStr and not fmtStr:find("^%$l10n_"))\n                   and string.format(fmtStr, self._fieldId) or tostring(self._fieldId))', 1)],
  "the sprayer title formats the sentence (row 60's fifth shape)"),
 ("S9-sprayer-no-field-prefix-find", SPR,
  [('        local txt = SoilL10n.tr("sf_sprayer_no_field", "Drive onto a field")',
    '        local ok, msg = pcall(function() return g_i18n:getText("sf_sprayer_no_field") end)\n        local txt = (ok and msg and not msg:find("^%$l10n_")) and msg or "Drive onto a field"', 1)],
  "the no-field line shows the sentence"),
 ("S10-harvester-field-prefix-find", HRV,
  [('        local fmtStr = SoilL10n.tr("sf_hud_field")\n        fieldStr = " · " .. (fmtStr and string.format(fmtStr, self._fieldId) or tostring(self._fieldId))',
    '        local ok, fmtStr = pcall(function() return g_i18n:getText("sf_hud_field") end)\n        fieldStr = " · " .. ((ok and fmtStr and not fmtStr:find("^%$l10n_"))\n                   and string.format(fmtStr, self._fieldId) or tostring(self._fieldId))', 1)],
  "the harvester title formats the sentence"),
 ("S11-harvester-tha-prefix-find", HRV,
  [('            local fmtT = SoilL10n.tr("sf_hud_tha")\n            local thaStr = fmtT and string.format(fmtT, estTha)',
    '            local okT, fmtT = pcall(function() return g_i18n:getText("sf_hud_tha") end)\n            local thaStr = (okT and fmtT and not fmtT:find("^%$l10n_"))\n                           and string.format(fmtT, estTha)', 1)],
  "the t/ha cell formats the sentence and drops the number"),
 ("S12-harvester-caption-prefix-find", HRV,
  [('        local capStr = SoilL10n.tr("sf_hud_yield_est_src")\n        if capStr then',
    '        local okCap, capStr = pcall(function() return g_i18n:getText("sf_hud_yield_est_src") end)\n        if okCap and capStr and not capStr:find("^%$l10n_") then', 1)],
  "the provenance caption draws the sentence"),
 ("S13-establishment-or-fallback", EST,
  [('        local text = SoilL10n.tr(key, "Establishment failed: " .. tostring(cause))',
    '        local text = g_i18n and g_i18n:getText(key)\n            or ("Establishment failed: " .. tostring(cause))', 1)],
  "the establishment notification shows the sentence"),
 ("M1-main-does-not-source-the-helper", MAIN,
  [('source(modDirectory .. "src/utils/SoilL10n.lua")\n', "", 1)],
  "the helper is never loaded in game (source witness)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
    lines = [strip(l) for l in out.splitlines()]
    barlines = [l for l in lines if any(b in l for b in BARS)]
    fails = [l for l in lines if l.startswith("FAIL ")]
    crashes = [l for l in lines if "Lua error while loading/running" in l and any(b in l for b in BARS)]
    barred = any(l.startswith("✗") or l.startswith("x") for l in barlines) or bool(crashes)
    return barred, fails, crashes, barlines


only = sys.argv[1:]
barred, fails, crashes, barlines = run_suite()
if barred:
    print("BASELINE: the two bars are not green; fix that before trusting any mutation result.")
    for l in barlines: print("   " + l)
    sys.exit(2)
print("baseline green:", " | ".join(barlines))

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        barred, fails, crashes, barlines = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    if barred:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not fails:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in fails[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
