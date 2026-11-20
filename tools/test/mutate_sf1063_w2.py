# #1063 W2 mutation battery (targeted, a small logic change): an SF-73 target pass counts the
# ground it dosed (the litre track over the plan's accepted footprint, src/hooks/HookManager.lua)
# and takes the pass-coverage notice in the AUTO target sentence (src/SoilFertilitySystem.lua).
# Rows: group E14 of SF-73-target_entry_point_test.lua.
#
# Each mutation must be KILLED by a named row. For each: assert the edit LANDED (exact count),
# run ONLY the bench that holds the rows (a filtered copy of run-tests.mjs, removed on exit),
# restore byte-for-byte and PROVE it with a hash.
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf1063_w2.py [id-prefix ...]
import atexit, hashlib, os, re, subprocess, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)
HM = "src/hooks/HookManager.lua"
SFS = "src/SoilFertilitySystem.lua"
BENCH = "SF-73-target_entry_point_test.lua"
MUTATIONS = [
 ("M1-dose-again", HM,
  [("                if sf73Cycle ~= nil then\n                    local acceptedHa = sf73Plan.acceptedHa\n",
    "                if false then\n                    local acceptedHa = sf73Plan.acceptedHa\n", 1)],
  "a target pass counts its dose against the 1x native rate, as on development"),
 ("M2-half-footprint", HM,
  [("                        and (liters / acceptedHa) or nil\n",
    "                        and (liters / (acceptedHa * 0.5)) or nil\n", 1)],
  "a target pass counts half the ground it dosed"),
 ("M3-no-rate", HM,
  [("                        and (liters / acceptedHa) or nil\n", "                        and nil or nil\n", 1)],
  "a target pass counts no ground at all"),
 ("M4-no-marker", HM,
  [("                    _ssRate._passRateTarget = (sf73Cycle ~= nil) or nil\n", "", 1)],
  "the notice never knows a target pass, so it shows nothing"),
 ("M5-marker-kept", HM,
  [("                ssClear._passRateTarget = nil -- nor W2's AUTO target marker\n", "", 1)],
  "the AUTO target marker outlives its tick"),
 ("M6-gate-back", SFS,
  [("    if not isCropProtection then\n        self:checkPassCoverageNotice(fieldId, field, fillType)\n",
    "    if not isCropProtection and not sf73 then\n        self:checkPassCoverageNotice(fieldId, field, fillType)\n", 1)],
  "target passes skip the notice again"),
 ("M7-rate-sentence", SFS,
  [("    if autoTarget then\n        local bodyKey = estimated and \"sf_notify_pass_body_target_est\"",
    "    if false then\n        local bodyKey = estimated and \"sf_notify_pass_body_target_est\"", 1)],
  "a target pass is told a selected rate it never had"),
 ("M8-never-estimated", SFS,
  [("        local bodyKey = estimated and \"sf_notify_pass_body_target_est\" or \"sf_notify_pass_body_target\"\n",
    "        local bodyKey = \"sf_notify_pass_body_target\"\n", 1)],
  "a litre-counted target pass claims counted coverage, not estimated"),
]
def sha(b): return hashlib.sha256(b).hexdigest()
RUNNER = os.path.join(ROOT, "tools", "test", "run-tests.w2.mjs")
def make_runner():
    with open(os.path.join(ROOT, "tools", "test", "run-tests.mjs"), encoding="utf-8", newline="") as f:
        src = f.read()
    anchor = "let testFiles = allTestFiles;"
    if src.count(anchor) != 1:
        print("runner anchor not found")
        sys.exit(4)
    with open(RUNNER, "w", encoding="utf-8", newline="") as f:
        f.write(src.replace(anchor, 'let testFiles = ["%s"];' % BENCH))
def drop_runner():
    if os.path.exists(RUNNER):
        os.remove(RUNNER)
make_runner()
atexit.register(drop_runner)
def run_suite():
    r = subprocess.run(["node", "run-tests.w2.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
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
print("baseline green (%s)" % BENCH)
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
