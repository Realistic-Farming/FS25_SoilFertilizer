# #1063 part 3 (W3) mutation battery (targeted, a small logic fix): the pass-coverage
# notice in SoilFertilitySystem.checkPassCoverageNotice and the rate the sprayer hook
# hands it (_passRateMult in HookManager). The rows are group D of
# RSF-F196-unit_rule_test.lua and group W3 of SF-1063-pass_percent_unsectioned_spec_test.lua.
#
# Each mutation removes or bends one clause of the change and must be KILLED by a named
# row. For each: assert the edit LANDED (exact occurrence count), run ONLY the three files
# that hold the change's rows (Tyson's standing rule, 2026-09-30 and 2026-11-04: the
# smallest selection that can see the change, in the foreground), record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash.
#
# The selection goes through a filtered copy of run-tests.mjs written beside it and
# deleted in `finally` (the runner has no per-file option; --loads src/SoilFertilitySystem.lua
# would run about 130 files per mutant). A filter can only turn a kill into a survivor,
# never fake a kill, so a SURVIVED result is re-run once under --loads of the mutated file
# before it is called real.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf1063_w3.py [id-prefix ...]
import atexit, hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFS = "src/SoilFertilitySystem.lua"
HM = "src/hooks/HookManager.lua"

MUTATIONS = [
 ("M1-another-products-coverage", SFS,
  [("    if field.sessionLastProduct ~= fillType.name then return end\n", "", 1)],
  "the notice reads the session coverage whatever product it belongs to, so a field "
  "another product covered says this product reached its target"),

 ("M2-no-rate-claims-x1", SFS,
  [("    local rate = self._passRateMult\n", "    local rate = self._passRateMult or 1.0\n", 1)],
  "with no rate handed over the notice claims x1.00 instead of staying silent"),

 ("M3-target-boundary", SFS,
  [("    if coverage < target then return end\n", "    if coverage <= target then return end\n", 1)],
  "exactly 90% pass coverage no longer reaches the target"),

 ("M4-estimated-inverted", SFS,
  [("    local estimated = not field._geometricCoverageOwner\n",
    "    local estimated = field._geometricCoverageOwner\n", 1)],
  "counted boom cells read as estimated and the litre estimate reads as measured"),

 ("M5-once-per-field-not-per-product", SFS,
  [("    if shown[fillType.name] then return end\n    shown[fillType.name] = true\n",
    "    if shown.any then return end\n    shown.any = true\n", 1)],
  "a second product on the same field the same day never gets its own notice"),

 ("M6-day-never-turns", SFS,
  [("    if type(shown) ~= \"table\" or shown.day ~= today then\n",
    "    if type(shown) ~= \"table\" then\n", 1)],
  "the once-a-day record never resets, so the next day the same product says nothing"),

 ("M7-coverage-not-reported", SFS,
  [("    local pct = math.floor(math.min(1.0, coverage) * 100 + 0.5)\n",
    "    local pct = 100\n", 1)],
  "the notice says 100% whatever the pass coverage was"),

 ("M8-rate-outlives-its-tick", HM,
  [("                ssClear._passRateMult = nil   -- #1063 W3: a rate never outlives its tick\n", "", 1)],
  "the selected rate stays on the soil system after the hook's tick, for any later "
  "credit path to show as if it were that pass's"),

 ("M9-hook-hands-no-rate", HM,
  [("                if _ssRate then _ssRate._passRateMult = (sf73Cycle == nil) and rateMultiplier or nil end\n", "", 1)],
  "the hook never hands the rate over, so no pass ever gets the notice"),

 ("M10-rate-shown-is-not-the-selected-one", HM,
  [("(sf73Cycle == nil) and rateMultiplier or nil", "(sf73Cycle == nil) and 1.0 or nil", 1)],
  "the notice always says x1.00, whatever rate the player selected"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


SELECTED = [
    "RSF-F196-unit_rule_test.lua",                     # group D: the notice's rules, unit level
    "RSF-F196-unit_rule_fallback_observable_test.lua", # OBS 9 and 11: the retired site 2
    "SF-1063-pass_percent_unsectioned_spec_test.lua",  # group W3: from the hook to the English
]
TEST_DIR = os.path.join(ROOT, "tools", "test")
RUNNER = os.path.join(TEST_DIR, "run-tests.mjs")
FILTERED = os.path.join(TEST_DIR, "run-tests.sf1063w3.mjs")
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
    # rel None: the three selected files; rel a path: --loads of it (a survivor's re-run)
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
