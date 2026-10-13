# #1039 mutation battery (targeted, a small logic fix): the spreading width follows the
# active spray type. Production lines in src/hooks/HookManager.lua only; the rows live in
# SF-1039-spray_type_width_spec_test.lua, and every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# One collector, not two: getBoomCellPositions now takes its nodes from _collectBoomNodes
# instead of an inline copy, so the intake's "drop the filter from each collector" is one
# mutation per filter here, and its named rows show it reaching BOTH consumers (S1 the
# boom line, S2 the cells).
#
# Not run, and why:
# - the multi-tank section credit loop's `vww ... and scratchN > 0`: left as it was. scratchN
#   is only populated on the sectioned path, so it already follows the predicate; a
#   mutation there is equivalent.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_sf1039_width.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"
RAW_VWW = "(self.spec_variableWorkWidth and self.spec_variableWorkWidth.sections and #self.spec_variableWorkWidth.sections > 0)"

MUTATIONS = [
 ("W1-collector-any-work-area", HM,
  [("                if HookManager.workAreaInPass(wa, activeSprayType) then\n",
    "                if true then\n", 1)],
  "the collector takes every work area again, whatever the spray type"),
 ("W2-collector-sections-always", HM,
  [("        if HookManager.sectionsInPass(obj, activeSprayType) then\n",
    "        if obj.spec_variableWorkWidth and obj.spec_variableWorkWidth.sections then\n", 1)],
  "the collector takes the section tips whatever the spray type"),
 ("W3-sections-predicate-ignores-spray-type", HM,
  [("    return activeSprayType == nil or activeSprayType.supportsVariableWorkWidth ~= false\n",
    "    return true\n", 1)],
  "HookManager.sectionsInPass answers yes for any machine with sections"),
 ("W4-no-active-spray-type", HM,
  [("    if obj == nil or type(obj.getActiveSprayType) ~= \"function\" then return nil end\n",
    "    if true then return nil end\n", 1)],
  "_activeSprayType never reads the vehicle"),
 ("C1-credit-path-raw-vww", HM,
  [("                if sf73Cycle == nil and sectioned then\n",
    "                if sf73Cycle == nil and " + RAW_VWW + " then\n", 1)],
  "the credit is split across the sections again on a lime pass"),
 ("C2-primary-stamp-raw-vww", HM,
  [("                    local hasVWW = sectioned   -- #1039: a lime pass on the Streumaster is not\n",
    "                    local hasVWW = " + RAW_VWW + "\n", 1)],
  "the primary stamp counts a lime pass's cells as sectioned coverage"),
 ("C3-multitank-stamp-raw-vww", HM,
  [("                                                        if sectioned then\n",
    "                                                        if " + RAW_VWW + " then\n", 1)],
  "the multi-tank replay's stamp counts a lime pass as sectioned coverage"),
 ("C4-f61-clear-raw-vww", HM,
  [("                    if not sectioned and g_SoilFertilityManager.soilSystem.fieldData\n",
    "                    if not " + RAW_VWW + " and g_SoilFertilityManager.soilSystem.fieldData\n", 1)],
  "a stale geometric owner is kept on a pass whose stamp no longer counts"),
 ("F1-fallback-machine-usage", HM,
  [("    if activeSprayType and activeSprayType.usageScale then\n        usScale = activeSprayType.usageScale\n    end\n    if not usScale then return nil end\n",
    "    if not usScale then return nil end\n", 1)],
  "the fallback width is the machine's usageScale again, not the active spray type's"),
 ("F2-fallback-no-work-area-width", HM,
  [("    if usScale.workAreaIndex ~= nil and type(obj.getWorkAreaWidth) == \"function\" then\n",
    "    if false then\n", 1)],
  "a spray type sized by its work area falls back to the workingWidth default"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

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
