# #771 mutation battery (targeted): SoilHUD.drawFitted and the width it is given at each call
# site in SoilHUD.lua (the monitor panel, the pressure rows, the rate panel). The rows are the
# groups U, E, M, H, S, P, A and R of SF-771-soilhud_text_fitting_test.lua.
#
# Each mutation removes or bends one clause of the change and must be KILLED by a named row.
# For each: assert the edit LANDED (exact occurrence count), run ONLY the one file that holds
# the change's rows (the smallest selection that can see the change, in the foreground), record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with a hash.
#
# The selection goes through a filtered copy of run-tests.mjs written beside it and deleted in
# `finally` (the runner has no per-file option). A filter can only turn a kill into a survivor,
# never fake one, so a SURVIVED result is reported as it stands and judged by reading, not by a
# larger run.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf771.py [id-prefix ...]
import atexit, hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HUD = "src/ui/SoilHUD.lua"

MUTATIONS = [
 ("M1-no-fit", HUD,
  [("        text, drawSize = UIHelper.fitText(text, size, maxWidth)\n", "        drawSize = size\n", 1)],
  "the helper draws every run at full size and whole, as the raw renderText did"),

 ("M2-width-zero", HUD,
  [("    return getTextWidth(drawSize, text) or 0\n", "    return 0\n", 1)],
  "the helper returns no width, so a neighbour is given the whole row"),

 ("M3-width-nominal", HUD,
  [("    return getTextWidth(drawSize, text) or 0\n", "    return getTextWidth(size, text) or 0\n", 1)],
  "the helper returns the width at the requested size, not the size it drew at"),

 ("M4-always-smaller", HUD,
  [("    renderText(x, y, drawSize, text)\n    if type(getTextWidth)", "    renderText(x, y, drawSize * 0.9, text)\n    if type(getTextWidth)", 1)],
  "a run that fits is drawn smaller anyway"),

 ("M5-title-ignores-badge", HUD,
  [("g_i18n:getText(\"sf_hud_title\"), innerW - badgeW)", "g_i18n:getText(\"sf_hud_title\"), innerW)", 1)],
  "the title is given the whole row, so it runs under the status badge"),

 ("M6-badge-uncapped", HUD,
  [("statusLabel:lower()), innerW * 0.45) + gap", "statusLabel:lower()), innerW) + gap", 1)],
  "the status badge may take the whole row"),

 ("M7-crop-uncapped", HUD,
  [("cropText, innerW * 0.45) + gap", "cropText, innerW) + gap", 1)],
  "the crop name may take the whole row"),

 ("M8-field-ignores-crop", HUD,
  [("fieldText or \"\", innerW - cropW)", "fieldText or \"\", innerW)", 1)],
  "the field text is given the whole row, so it runs under the crop name"),

 ("M9-asleep-unfitted", HUD,
  [("g_i18n:getText(\"sf_hud_asleep\"), innerW)", "g_i18n:getText(\"sf_hud_asleep\"), nil)", 1)],
  "the asleep line has no width again"),

 ("M10-ppm-unfitted", HUD,
  [("g_i18n:getText(\"sf_hud_unit_ppm\"), innerW * 0.3)", "g_i18n:getText(\"sf_hud_unit_ppm\"), nil)", 1)],
  "the (ppm) label has no width again"),

 ("M11-om-label-unfitted", HUD,
  [("g_i18n:getText(\"sf_hud_label_om\"), 0.030*s)", "g_i18n:getText(\"sf_hud_label_om\"), nil)", 1)],
  "the OM label has no width again, so it runs into its value"),

 ("M12-om-value-unfitted", HUD,
  [("self._fmt_omStr or \"\",\n            px + pw - pad - (omValX + 0.015*s))", "self._fmt_omStr or \"\",\n            nil)", 1)],
  "the OM value has no width again"),

 ("M13-comp-unfitted", HUD,
  [("0.010 * fontMult * s, compText, innerW)", "0.010 * fontMult * s, compText, nil)", 1)],
  "the compaction line has no width again"),

 ("M14-burn-unfitted", HUD,
  [("0.010 * fontMult * s, burnText, innerW)", "0.010 * fontMult * s, burnText, nil)", 1)],
  "the amendment-burn line has no width again"),

 ("M15-burnrisk-unfitted", HUD,
  [("0.010 * fontMult * s, burnRiskText, innerW)", "0.010 * fontMult * s, burnRiskText, nil)", 1)],
  "the burn-risk line has no width again"),

 ("M16-yield-unfitted", HUD,
  [("0.010 * fontMult * s, yieldText, innerW)", "0.010 * fontMult * s, yieldText, nil)", 1)],
  "the yield line has no width again"),

 ("M17-hint-unfitted", HUD,
  [("0.009 * fontMult * s, hintText, innerW)", "0.009 * fontMult * s, hintText, nil)", 1)],
  "the hint row has no width again"),

 ("M18-nutrient-value-ignores-status", HUD,
  [("0.010 * fontMult * s, valStr,\n        rowRoom - statusW - pad * 0.5)", "0.010 * fontMult * s, valStr,\n        rowRoom)", 1)],
  "an N/P/K value is given the whole row, so it runs under the status text"),

 ("M19-nutrient-status-uncapped", HUD,
  [("SoilHUD.statusText(displayStatus), rowRoom * 0.45)", "SoilHUD.statusText(displayStatus), rowRoom)", 1)],
  "an N/P/K status may take the whole row"),

 ("M20-nutrient-room-doubled", HUD,
  [("    local rowRoom   = rightEdge - valX\n    setTextAlignment(RenderText.ALIGN_RIGHT)\n    setTextColor(displayCol[1]",
    "    local rowRoom   = (rightEdge - valX) * 2\n    setTextAlignment(RenderText.ALIGN_RIGHT)\n    setTextColor(displayCol[1]", 1)],
  "the room right of an N/P/K value is counted twice"),

 ("M21-ph-value-ignores-status", HUD,
  [("phKnown and string.format(\"%.1f\", pH) or \"--\", rowRoom - statusW - pad * 0.5)", "phKnown and string.format(\"%.1f\", pH) or \"--\", rowRoom)", 1)],
  "the pH value is given the whole row"),

 ("M22-ph-status-uncapped", HUD,
  [("SoilHUD.statusText(phStatus), rowRoom * 0.45)", "SoilHUD.statusText(phStatus), rowRoom)", 1)],
  "the pH status may take the whole row"),

 ("M23-ph-label-unfitted", HUD,
  [("g_i18n:getText(\"sf_hud_label_ph\"), 0.013*s)", "g_i18n:getText(\"sf_hud_label_ph\"), nil)", 1)],
  "the pH label has no width again"),

 ("M24-pressure-hidden-label-unfitted", HUD,
  [("g_i18n:getText(labelKey), 0.036*s)\n        setTextAlignment(RenderText.ALIGN_LEFT)", "g_i18n:getText(labelKey), nil)\n        setTextAlignment(RenderText.ALIGN_LEFT)", 1)],
  "the label of an unscouted pressure row has no width again"),

 ("M25-pressure-hidden-text-unfitted", HUD,
  [("textSize, hiddenText, rightEdge - (tx + 0.038*s))", "textSize, hiddenText, nil)", 1)],
  "the unscouted text has no width again"),

 ("M26-pressure-label-unfitted", HUD,
  [("g_i18n:getText(labelKey), 0.036*s)\n\n    -- Bar - centred in row", "g_i18n:getText(labelKey), nil)\n\n    -- Bar - centred in row", 1)],
  "the label of a pressure row has no width again"),

 ("M27-pressure-value-unfitted", HUD,
  [("textSize, label,\n        rightEdge - (barX + barW + 0.006*s))", "textSize, label,\n        nil)", 1)],
  "the pressure value and its tag have no width again"),

 ("M28-rate-header-unfitted", HUD,
  [("0.009 * fontMult * s, headerText, pw * 0.94)", "0.009 * fontMult * s, headerText, nil)", 1)],
  "the rate panel's header has no width again"),

 ("M29-rate-target-unfitted", HUD,
  [("0.008 * fontMult * s, targetText, pw * 0.94)", "0.008 * fontMult * s, targetText, nil)", 1)],
  "the rate panel's target line has no width again"),

 ("M30-rate-burn-always-unfitted", HUD,
  [("g_i18n:getText(\"sf_sprayer_burn_guaranteed\"), pw * 0.94)", "g_i18n:getText(\"sf_sprayer_burn_guaranteed\"), nil)", 1)],
  "the always-burns warning has no width again"),

 ("M31-rate-burn-may-unfitted", HUD,
  [("g_i18n:getText(\"sf_sprayer_burn_possible\"), pw * 0.94)", "g_i18n:getText(\"sf_sprayer_burn_possible\"), nil)", 1)],
  "the may-burn warning has no width again"),
]

# Mutants that cannot be killed by any input, judged by reading and kept so the list stays honest.
# They are still run: one that stops surviving would be a finding.
EQUIVALENT = {
    "M12-om-value-unfitted":
        "the OM value is string.format('%.1f%%') of a percentage, at most six characters; its room "
        "(right inner edge minus the value's own start, about 0.135 of a 0.168 inner width) never binds",
    "M21-ph-value-ignores-status":
        "the pH value is '%.1f' of a pH or '--', at most four characters; the room left after the status "
        "is capped to 45% (about 0.026 of 0.049) never binds at any panel width the HUD allows",
}


def sha(b): return hashlib.sha256(b).hexdigest()


SELECTED = [
    "SF-771-soilhud_text_fitting_test.lua",   # groups U, E, M, H, S, P, A, R
]
TEST_DIR = os.path.join(ROOT, "tools", "test")
RUNNER = os.path.join(TEST_DIR, "run-tests.mjs")
FILTERED = os.path.join(TEST_DIR, "run-tests.sf771.mjs")
ANCHOR = "let testFiles = allTestFiles;"


def write_filtered_runner():
    with open(RUNNER, "r", encoding="utf-8") as f:
        src = f.read()
    if src.count(ANCHOR) != 1:
        print("the runner's selection line is not where this script expects it; stopping")
        sys.exit(4)
    pick = "let testFiles = allTestFiles.filter((tf) => %s.includes(tf));" % repr(SELECTED).replace("'", '"')
    with open(FILTERED, "w", encoding="utf-8") as f:
        f.write(src.replace(ANCHOR, pick))


def run_suite():
    r = subprocess.run(["node", os.path.basename(FILTERED)], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


def remove_filtered_runner():
    try:
        os.remove(FILTERED)
    except FileNotFoundError:
        pass


only = sys.argv[1:]
write_filtered_runner()
atexit.register(remove_filtered_runner)   # also runs on sys.exit, so the copy never stays behind
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN on the selected file; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green (%d selected file)" % len(SELECTED))

killed, crashkills, survived, badedit, equivalent = [], [], [], [], []

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
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    elif mid in EQUIVALENT:
        equivalent.append(mid)
        tag = "EQUIVALENT"
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:6]:
        print("        " + l[:120])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("equivalent (judged by reading, see EQUIVALENT) %d" % len(equivalent))
for mid in equivalent:
    print("   EQUIVALENT %s: %s" % (mid, EQUIVALENT[mid]))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
