# #1141 mutation battery (targeted, a small logic fix): the AI fruit requirement
# guard's measure() must cache a REJECTED mapId (false), not just a successful one,
# so a mapId the engine refuses is probed through getDensityMapSize at most once,
# ever, instead of once per AI update tick. src/hooks/HookManager.lua only; the
# row is SF1141-aiguard_density_negative_cache_test.lua.
#
# Each mutation removes or bends one clause of the fix and must be KILLED by a named
# row. For each: assert the edit LANDED (exact occurrence count), run the suite,
# record KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the
# restore with a hash. The suite run is scoped with --loads to the files that reach
# HookManager.lua, so this stays fast; a SURVIVED result would still be real since
# the one row that exercises this code is inside that selection.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_sf1141_aiguard.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"

MUTATIONS = [
 ("M1-failure-not-cached", HM,
  [("        if not ok or size == nil then\n"
    "            sizeCache[mapId] = false\n"
    "            return nil\n"
    "        end\n",
    "        if not ok or size == nil then\n"
    "            return nil\n"
    "        end\n", 1)],
  "a rejected mapId is never cached, so it is probed through getDensityMapSize again "
  "on every following tick (issue #1141 as reported)"),

 ("M2-cached-false-returned-as-a-size", HM,
  [("        if cached ~= nil then\n"
    "            if cached == false then return nil end\n"
    "            return cached\n"
    "        end\n",
    "        if cached ~= nil then\n"
    "            return cached\n"
    "        end\n", 1)],
  "a cached rejection (false) is returned as if it were a measured size, so "
  "stripMismatched reads it as a real mismatch against the ground map and drops the "
  "requirement entry it was told to leave alone"),

 ("M3-cached-false-read-as-size-zero", HM,
  [("            if cached == false then return nil end\n", "            if cached == false then return 0 end\n", 1)],
  "a cached rejection is read back as a measured size of 0, so the next tick sees a "
  "mismatch against the ground map and drops the entry it must leave alone"),

 ("M4-rejection-cached-as-size-zero", HM,
  [("            sizeCache[mapId] = false\n", "            sizeCache[mapId] = 0\n", 1)],
  "a rejection is stored as a measured size of 0 instead of false, with the same result"),

 ("M5-nil-answer-not-a-failure", HM,
  [("        if not ok or size == nil then\n", "        if not ok then\n", 1)],
  "an engine answer of nil (no error) is not treated as a failed measurement, so it "
  "is probed again on every tick"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs", "--loads", HM], cwd=os.path.join(ROOT, "tools", "test"),
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
