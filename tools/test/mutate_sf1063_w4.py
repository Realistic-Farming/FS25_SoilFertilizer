# #1063 W4 mutation battery (targeted, a small logic fix): the map's own base rate for the
# HUD's rate readout and ghost bar, HookManager.getMapBaseRate and the three SoilHUD sites
# that read it. The rows are groups R, G and C of SF-1063-w4_map_base_rate_test.lua, the
# ghost rows of RSF-F196-unit_rule_test.lua and SF-73-ghost_bar_target_mode_spec_test.lua,
# and OBS 13 to 21 of RSF-F196-unit_rule_fallback_observable_test.lua.
#
# Each mutation removes or bends one clause of the change and must be KILLED by a named
# row. For each: assert the edit LANDED (exact occurrence count), run ONLY the four files
# that hold the change's rows (the smallest selection that can see the change, in the
# foreground), record KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE
# the restore with a hash.
#
# The selection goes through a filtered copy of run-tests.mjs written beside it and
# deleted in `finally` (the runner has no per-file option). A filter can only turn a kill
# into a survivor, never fake a kill, so a SURVIVED result is re-run once under --loads of
# the mutated file before it is called real.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf1063_w4.py [id-prefix ...]
import atexit, hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"
HUD = "src/ui/SoilHUD.lua"

MUTATIONS = [
 ("M1-usage-scale-ignored", HM,
  [("    local litres = HookManager.getNativeSprayRatePerHa(sprayer, fillType.index)\n",
    "    local litres = lps * 36000\n", 1)],
  "the rate leaves out the sprayer's own usage scale, so a scaled sprayer shows the unscaled rate"),

 ("M2-no-mass-conversion", HM,
  [("        value = HookManager.massEquivalent(fillType, litres),\n",
    "        value = litres,\n", 1)],
  "a dry product's litres per hectare are shown in the kilogram unit, unconverted"),

 ("M3-unit-class-always-liquid", HM,
  [("        unit  = (entry and entry.unit) or \"liquid\",\n",
    "        unit  = \"liquid\",\n", 1)],
  "every product reads in litres, so a dry product's rate loses its kg/ha"),

 ("M4-no-spray-type-gets-a-default", HM,
  [("    if type(lps) ~= \"number\" or lps ~= lps or lps <= 0 then return nil end\n",
    "    if type(lps) ~= \"number\" or lps ~= lps or lps <= 0 then lps = 93.5 / 36000 end\n", 1)],
  "a product with no spray type is given a stand-in calibration instead of being unavailable"),

 ("M5-hud-ignores-the-sprayer", HUD,
  [("    return HookManager.getMapBaseRate(sprayer, fillType)\n",
    "    return HookManager.getMapBaseRate(nil, fillType)\n", 1)],
  "the HUD reads the rate without the sprayer, so a usage scale never reaches the readout or the ghost"),

 ("M6-table-fills-the-gap", HUD,
  [("    return HookManager.getMapBaseRate(sprayer, fillType)\n",
    "    local br = SoilConstants.SPRAYER_RATE.BASE_RATES\n"
    "    return HookManager.getMapBaseRate(sprayer, fillType) or (fillType and br[fillType.name]) or br.DEFAULT\n", 1)],
  "when the map gives no rate the table's figure (or DEFAULT) is shown as if it were measured"),

 ("M7-ghost-reads-the-table", HUD,
  [("            local baseRate = self:getRateConfig(fillType, self._cachedSprayer)\n",
    "            local baseRate = (fillType and SoilConstants.SPRAYER_RATE.BASE_RATES[fillType.name])"
    " or SoilConstants.SPRAYER_RATE.BASE_RATES.DEFAULT\n", 1)],
  "the ghost bar is sized from BASE_RATES again"),

 ("M8-no-rate-shows-the-default", HUD,
  [("    if rateConfig == nil then return string.format(\"%.2fx\", multiplier) end\n",
    "    if rateConfig == nil then rateConfig = SoilConstants.SPRAYER_RATE.BASE_RATES.DEFAULT end\n", 1)],
  "the readout with no rate shows an invented amount instead of the multiplier alone"),

 ("M9-neighbour-multiplier-format", HUD,
  [("    if rateConfig == nil then return string.format(\"%.2f\", multiplier) end\n",
    "    if rateConfig == nil then return string.format(\"%.1f\", multiplier) end\n", 1)],
  "the neighbouring steps with no rate lose their second decimal"),

 ("M10-panel-passes-no-sprayer", HUD,
  [("        rateConfig = self:getRateConfig(fillType, sprayer)\n",
    "        rateConfig = self:getRateConfig(fillType, nil)\n", 1)],
  "the rate panel reads the rate without its sprayer, so a usage scale never reaches the readout"),

 ("M11-placeholder-condition-inverted", HUD,
  [("    if sprayer ~= nil then\n        rateConfig = self:getRateConfig(fillType, sprayer)\n",
    "    if sprayer == nil then\n        rateConfig = self:getRateConfig(fillType, sprayer)\n", 1)],
  "a real sprayer gets the layout placeholder and the edit-mode preview loses it"),

 ("M12-missing-rate-source-silent", HUD,
  [("        SoilHUD.mapRateFallbacks = (SoilHUD.mapRateFallbacks or 0) + 1\n", "", 1)],
  "a HUD with no rate source stops counting the miss"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


SELECTED = [
    "SF-1063-w4_map_base_rate_test.lua",               # groups R, G, C: the readout, the ghost, the resolver
    "RSF-F196-unit_rule_test.lua",                     # group F: the ghost bar and its unit rule
    "RSF-F196-unit_rule_fallback_observable_test.lua", # OBS 13 to 21: the HUD's own fallbacks
    "SF-73-ghost_bar_target_mode_spec_test.lua",       # H and C: the ghost outside target mode
]
TEST_DIR = os.path.join(ROOT, "tools", "test")
RUNNER = os.path.join(TEST_DIR, "run-tests.mjs")
FILTERED = os.path.join(TEST_DIR, "run-tests.sf1063w4.mjs")
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
    # rel None: the selected files; rel a path: --loads of it (a survivor's re-run)
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
    print("BASELINE IS NOT GREEN on the selected files; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green (%d selected files)" % len(SELECTED))

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
        if rc == 0:
            # the filter can only hide a kill: a survivor is re-run once under --loads
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
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
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
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
