# #1063 HUD Pass line "estimated" mutation battery (targeted, a small logic fix): the flag
# getFieldInfo hands over, the label SoilHUD:update appends to the Pass line, the rows as
# SoilHUD:drawCoverageLines draws them, and the "~" the sprayer info panel puts on its PASS
# and session-ha cells. The rows are groups E, P, D and Q of
# SF-1063-hud_pass_estimated_test.lua (group L reads the language files and no mutation of
# source reaches it).
#
# Each mutation removes or bends one clause of the change and must be KILLED by a named
# row. For each: assert the edit LANDED (exact occurrence count), run ONLY the one file that
# holds the change's rows (the smallest selection that can see the change, in the foreground),
# record KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with
# a hash.
#
# The selection goes through a filtered copy of run-tests.mjs written beside it and deleted
# in `finally` (the runner has no per-file option; --loads src/SoilFertilitySystem.lua would
# run about 130 files per mutant). A filter can only turn a kill into a survivor, never fake
# one, so a SURVIVED result in SoilHUD.lua is re-run once under --loads of that file (17 files)
# before it is called real. A SURVIVED result in SoilFertilitySystem.lua is reported as it
# stands: no other file reads the new field.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf1063_hud_est.py [id-prefix ...]
import atexit, hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFS = "src/SoilFertilitySystem.lua"
HUD = "src/ui/SoilHUD.lua"
PNL = "src/ui/SoilSprayerInfoPanel.lua"

MUTATIONS = [
 ("M1-flag-inverted", SFS,
  [("        sessionCoverageEstimated = not field._geometricCoverageOwner,\n",
    "        sessionCoverageEstimated = field._geometricCoverageOwner == true,\n", 1)],
  "boom-cell coverage reads as estimated and litre-derived coverage reads as measured"),

 ("M2-flag-always-true", SFS,
  [("        sessionCoverageEstimated = not field._geometricCoverageOwner,\n",
    "        sessionCoverageEstimated = true,\n", 1)],
  "every coverage reads as estimated, boom cells included"),

 ("M3-label-never-added", HUD,
  [("                if info.sessionCoverageEstimated == true then\n",
    "                if false then\n", 1)],
  "the Pass line never says estimated"),

 ("M4-label-always-added", HUD,
  [("                if info.sessionCoverageEstimated == true then\n",
    "                if info.sessionCoverageFraction ~= nil then\n", 1)],
  "the Pass line says estimated even for coverage counted from boom cells"),

 ("M5-label-before-the-line", HUD,
  [("                    passLine = passLine .. \" \" .. g_i18n:getText(\"sf_hud_pass_estimated\")\n",
    "                    passLine = g_i18n:getText(\"sf_hud_pass_estimated\") .. \" \" .. passLine\n", 1)],
  "the label leads the line instead of following it"),

 ("M6-label-on-the-daily-line", HUD,
  [("                table.insert(parts, string.format(g_i18n:getText(\"sf_hud_coverage\"), dayPct, minPct))\n",
    "                table.insert(parts, string.format(g_i18n:getText(\"sf_hud_coverage\"), dayPct, minPct)"
    " .. (info.sessionCoverageEstimated == true and (\" \" .. g_i18n:getText(\"sf_hud_pass_estimated\")) or \"\"))\n", 1)],
  "the daily coverage line, which is not a pass estimate, carries the label too"),

 ("M7-no-label-without-a-product", HUD,
  [("                if info.sessionCoverageEstimated == true then\n",
    "                if info.sessionCoverageEstimated == true and lastProd then\n", 1)],
  "a pass with no product recorded loses the label"),

 ("M8-no-fit", HUD,
  [("        local w = type(getTextWidth) == \"function\" and getTextWidth(size, line) or nil\n"
    "        if w ~= nil and w > maxW and w > 0 then size = size * maxW / w end\n",
    "        local w = type(getTextWidth) == \"function\" and getTextWidth(size, line) or nil\n", 1)],
  "a row wider than the panel is drawn at full size and spills past its edge"),

 ("M9-fit-to-the-whole-width", HUD,
  [("    local maxW = pw - 2 * pad\n", "    local maxW = pw\n", 1)],
  "a wide row is fitted to the whole panel width, ignoring the padding on both sides"),

 ("M10-rows-share-a-slot", HUD,
  [("    for _, line in ipairs(covLines) do\n        cy = cy - SoilHUD.LINE_H * s\n",
    "    for _, line in ipairs(covLines) do\n", 1)],
  "every coverage row is drawn in the same place"),

 ("M11-wrong-y-returned", HUD,
  [("        renderText(px + pad, cy + (SoilHUD.LINE_H - 0.010) * 0.5 * s, size, line)\n    end\n    return cy\nend\n",
    "        renderText(px + pad, cy + (SoilHUD.LINE_H - 0.010) * 0.5 * s, size, line)\n    end\n    return cy + SoilHUD.LINE_H * s\nend\n", 1)],
  "the helper hands back a y one slot too high, so the row after it overlaps"),

 ("M12-panel-drops-the-returned-y", HUD,
  [("                cy = self:drawCoverageLines(covLines, px, cy, pw, s, fontMult)\n",
    "                self:drawCoverageLines(covLines, px, cy, pw, s, fontMult)\n", 1)],
  "the panel ignores where the coverage rows ended, so the compaction row draws over them"),

 ("M13-panel-never-tilde", PNL,
  [("        local approx = (sessCov > 0 and info and info.sessionCoverageEstimated == true) and \"~\" or \"\"\n",
    "        local approx = \"\"\n", 1)],
  "the sprayer info panel shows litre-derived coverage as if it were counted"),

 ("M14-panel-always-tilde", PNL,
  [("        local approx = (sessCov > 0 and info and info.sessionCoverageEstimated == true) and \"~\" or \"\"\n",
    "        local approx = \"~\"\n", 1)],
  "the sprayer info panel marks even boom-cell coverage as an estimate"),

 ("M15-panel-pass-cell-bare", PNL,
  [("        local covStr = string.format(\"%s%d%%\", approx, covPct)\n",
    "        local covStr = string.format(\"%d%%\", covPct)\n", 1)],
  "the PASS cell loses the tilde and the session area keeps it"),

 ("M16-panel-ha-cell-bare", PNL,
  [("        local sessHaStr = string.format(\"%s%.2f ha\", approx, sessHa)\n",
    "        local sessHaStr = string.format(\"%.2f ha\", sessHa)\n", 1)],
  "the session area, worked out from the same litres, loses the tilde and the PASS cell keeps it"),

 ("M18-panel-tilde-without-a-pass", PNL,
  [("        local approx = (sessCov > 0 and info and info.sessionCoverageEstimated == true) and \"~\" or \"\"\n",
    "        local approx = (info and info.sessionCoverageEstimated == true) and \"~\" or \"\"\n", 1)],
  "an idle rig, a reload, a product switch and every client show ~0% and ~0.00 ha"),

 ("M17-padding-ignores-scale", HUD,
  [("    local pad  = SoilHUD.PAD * s\n    local maxW = pw - 2 * pad\n",
    "    local pad  = SoilHUD.PAD\n    local maxW = pw - 2 * pad\n", 1)],
  "the fit's padding stays at scale 1 on a scaled HUD, so a wide row is fitted to the wrong width"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


SELECTED = [
    "SF-1063-hud_pass_estimated_test.lua",   # groups E, P, D, Q, L: the flag, the label, the panel, the rows, the sprayer panel, the languages
]
TEST_DIR = os.path.join(ROOT, "tools", "test")
RUNNER = os.path.join(TEST_DIR, "run-tests.mjs")
FILTERED = os.path.join(TEST_DIR, "run-tests.sf1063est.mjs")
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


def run_suite(rel):
    # rel None: the selected file; rel a path: --loads of it (a survivor's re-run)
    args = ["node", "run-tests.mjs", "--loads", rel] if rel else ["node", os.path.basename(FILTERED)]
    r = subprocess.run(args, cwd=TEST_DIR,
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
rc, fails, crashes = run_suite(None)
if rc != 0:
    print("BASELINE IS NOT GREEN on the selected file; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green (%d selected file)" % len(SELECTED))

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
        rc, fails, crashes = run_suite(None)
        if rc == 0 and rel in (HUD, PNL):
            # the filter can only hide a kill: a survivor in the HUD file is re-run under --loads
            rc, fails, crashes = run_suite(rel)
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
        # every group of this bench runs inside group(), which turns a raised Lua error into a
        # named FAIL row, so a kill by a bare crash cannot happen here and is not classified
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:12]:
        print("        " + l[:120])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d" % len(killed))
print("survived %d" % len(survived))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
