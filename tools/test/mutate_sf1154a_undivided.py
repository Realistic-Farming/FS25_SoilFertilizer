# #1154 follow-up (a) mutation battery (targeted, a small logic change): with a fertilizer an
# undivided boom follows its nozzles, not the centre alone (SFNozzleEffects:getIsWorkAreaActive,
# isFertilizerFill, and the anyNozzleActive aggregate in onUpdate). Rows: group U of
# SF-1154-see_spray_pass3_lookahead_spec_test.lua.
#
# Each mutation must be KILLED by a named row. For each: assert the edit LANDED (exact count),
# run the tests that load the file (--loads src/specializations/SFNozzleEffects.lua: 4 files,
# the smallest selection that sees it), restore byte-for-byte and PROVE it with a hash.
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf1154a_undivided.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFN = "src/specializations/SFNozzleEffects.lua"

MUTATIONS = [
 ("M1-open-even-when-every-nozzle-is-closed", SFN,
  [("        if idx == nil and spec.anyNozzleActive == true and SFNozzleEffects.isFertilizerFill(self) then\n",
    "        if idx == nil and SFNozzleEffects.isFertilizerFill(self) then\n", 1)],
  "a one-piece fertilizer boom never closes, even when every nozzle reads the ground as full"),

 ("M2-chemicals-too", SFN,
  [("        if idx == nil and spec.anyNozzleActive == true and SFNozzleEffects.isFertilizerFill(self) then\n",
    "        if idx == nil and spec.anyNozzleActive == true then\n", 1)],
  "a See & Spray chemical's centre decision is overridden too"),

 ("M3-real-centre-section-too", SFN,
  [("        if idx == nil and spec.anyNozzleActive == true and SFNozzleEffects.isFertilizerFill(self) then\n",
    "        if spec.anyNozzleActive == true and SFNozzleEffects.isFertilizerFill(self) then\n", 1)],
  "a sectioned boom's real centre section stays open on the other sections' word"),

 ("M4-any-never-recorded", SFN,
  [("        if ed.isActive then anyActive = true end\n", "", 1)],
  "the aggregate never sees an open nozzle, so the change never takes effect"),

 ("M5-insecticide-counts-as-fertilizer", SFN,
  [("    if C.PEST_PRESSURE and C.PEST_PRESSURE.INSECTICIDE_TYPES and C.PEST_PRESSURE.INSECTICIDE_TYPES[ft.name] then return false end\n", "", 1)],
  "an insecticide (it carries a fertilizer profile) is treated as a fertilizer"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs", "--loads", SFN], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
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
print("baseline green (--loads %s)" % SFN)

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
    for l in named[:6]:
        print("        " + l[:140])
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
