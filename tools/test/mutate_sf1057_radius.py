# #1057 mutation battery (targeted: a small logic fix, R-25): the geometry fallback's
# tyre size in src/SoilCompactionModel.lua. The rows live in
# SF-1057-compaction_radius_original_test.lua, driven from pointsForVehicle.
#
# Each mutation removes or bends the one changed line and must be KILLED by a named row.
# For each: assert the edit LANDED (exact occurrence count), run the tests, record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with a
# hash. "DID NOT APPLY" never counts as a kill. KILLED* means killed only by a Lua error
# (a crash, or a group that raised): a weak kill, a failure.
#
# The three are Bob's intake's: back to the live radius, the fallback dropped, and the
# smaller of the two.
#
# Runs under --loads (Tyson's battery ruling, 2026-09-30): only the test files that can
# reach the mutated file run for each mutant. A survivor is re-run under the whole suite
# before it counts as one (--full-on-survivor, on by default).
#
# Usage (from the repo root): py tools/test/mutate_sf1057_radius.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SCM = "src/SoilCompactionModel.lua"
LINE = "            local radius = phys.radiusOriginal or phys.radius\n"

MUTATIONS = [
 ("R1-live-radius", SCM, [(LINE, "            local radius = phys.radius\n", 1)],
  "back to the live radius: a shrunk tyre raises the pressure again"),
 ("R2-no-fallback", SCM, [(LINE, "            local radius = phys.radiusOriginal\n", 1)],
  "the fallback dropped: a wheel without radiusOriginal loses its patch"),
 ("R3-min-of-both", SCM, [(LINE, "            local radius = math.min(phys.radius, phys.radiusOriginal)\n", 1)],
  "the smaller of the two: a shrunk tyre still raises the pressure"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite(full=False):
    args = ["node", "run-tests.mjs"] + ([] if full else ["--loads", SCM])
    r = subprocess.run(args, cwd=os.path.join(ROOT, "tools", "test"),
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
print("baseline green (--loads %s)" % SCM)

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
        if rc == 0:
            # A filter can only turn a kill into a survivor: re-run the whole suite.
            rc, fails, crashes = run_suite(full=True)
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
