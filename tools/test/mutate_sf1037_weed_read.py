# #1037 cause 2 mutation battery (targeted, a small logic fix): the daily weed read
# measures the whole field. Production lines in src/SoilFertilitySystem.lua only; the rows
# live in SF-1037-whole_field_weed_read_spec_test.lua, and every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# R1 and R2 are the intake's two (revert to the ring average; count withered states at
# their vanilla factor). The rest bend the other changed lines.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_sf1037_weed_read.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFS = "src/SoilFertilitySystem.lua"

MUTATIONS = [
 ("R1-ring-average", SFS,
  [("    if wholeField ~= nil then return wholeField end\n", "", 1)],
  "the daily pass reads the ring average again, whatever the whole-field read found"),
 ("R2-withered-at-vanilla-factor", SFS,
  [("factor > 0 and not withered[state] then", "factor > 0 then", 1)],
  "withered weed states count at their vanilla factor (8 = 0.5, 9 = 0.75)"),
 ("R3-whole-polygon-in-one-frame", SFS,
  [("    local okR, finished = pcall(self._readWeedFieldSlice, self, job)\n",
    "    local okR, finished = pcall(self._readWeedFieldSlice, self, job)\n"
    "    while okR and not finished do okR, finished = pcall(self._readWeedFieldSlice, self, job) end\n", 1)],
  "one frame reads every slice of the field"),
 ("R4-no-clip-region", SFS,
  [("        multi:setPolygonClipRegion(job.curZ, toZ)\n", "", 1)],
  "every slice counts the whole polygon (the ratio holds, the frame cost does not)"),
 ("R5-no-reset-between-slices", SFS,
  [("    multi:resetStats()\n", "", 1)],
  "the engine's running counts are summed again on every slice"),
 ("R6-denominator-weed-pixels", SFS,
  [("    job.touched = job.touched + (touched or 0)\n",
    "    for name in pairs(job.factorOf) do job.touched = job.touched + (counts[name] or 0) end\n", 1)],
  "the mean is taken over the weedy pixels, not over the field"),
 ("R7-no-next-read", SFS,
  [("    self:_requestWeedFieldRead(fieldId, fsField)\n"
    "    local wholeField = self._weedFieldReads and self._weedFieldReads[fieldId]\n"
    "    if wholeField ~= nil then return wholeField end\n",
    "    local wholeField = self._weedFieldReads and self._weedFieldReads[fieldId]\n"
    "    if wholeField ~= nil then return wholeField end\n"
    "    self:_requestWeedFieldRead(fieldId, fsField)\n", 1)],
  "after its first result a field is never read again"),
 ("R8-tick-on-client", SFS,
  [("function SoilFertilitySystem:_weedReadTick()\n    if g_server == nil then return end\n",
    "function SoilFertilitySystem:_weedReadTick()\n", 1)],
  "a client runs the read"),
 ("R9-queue-on-client", SFS,
  [("function SoilFertilitySystem:_requestWeedFieldRead(fieldId, fsField)\n    if g_server == nil then return end\n",
    "function SoilFertilitySystem:_requestWeedFieldRead(fieldId, fsField)\n", 1)],
  "a client queues a read"),
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
