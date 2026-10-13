# MAINTENANCE row 149 mutation battery (targeted, a small logic change): the pass order of
# SoilValueMaps:addPaintStrip (src/maps/SoilValueMaps.lua). Rows live in
# MAINT-149-paint_strip_clamp_order_spec_test.lua (and SF-79's F3 witness); every other bar
# runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# Not run, and why:
# - the positive clamp window's "+ 1" and the negative one's "- 1" (Bob's intake names both):
#   EQUIVALENT once the clamp runs first. Dropping the "+ 1" adds RAW_MAX - d to the clamp
#   window, and that pixel reaches RAW_MAX by the add anyway (RAW_MAX - d + d); dropping the
#   "- 1" adds rawLow + |d|, which the add takes to rawLow. No row can tell them apart.
# - the sub-step quantisation at :779: out of scope (rows 66 and 71, Tyson's Design hold).
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_maint149_paint_strip.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SVM = "src/maps/SoilValueMaps.lua"

CLAMP = """    if type(m.executeSet) == "function" then
        local sok, serr = pcall(function()
            if rawDelta > 0 then
                -- Everything from the add's ceiling upward saturates to RAW_MAX.
                filter:setValueCompareParams(DensityValueCompareType.BETWEEN,
                    math.max(rawLow, RAW_MAX - rawDelta + 1), RAW_MAX)
                m:executeSet(RAW_MAX, filter)
            else
                -- Mirror at the bottom, never below the layer's own floor.
                filter:setValueCompareParams(DensityValueCompareType.BETWEEN,
                    rawLow, math.min(RAW_MAX, rawLow - rawDelta - 1))
                m:executeSet(rawLow, filter)
            end
        end)
        if not sok then
            -- Non-fatal: the add below still lands; only the band's top-up is lost.
            SoilLogger.debug("SoilValueMaps: addPaintStrip saturation clamp failed (%s)", tostring(serr))
        end
    end
"""
ADD = """    if rawDelta > 0 then
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, rawLow, RAW_MAX - rawDelta)
    else
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, rawLow - rawDelta, RAW_MAX)
    end
    local ok, err = pcall(function()
        m:executeAdd(rawDelta, filter)
    end)
    if not ok then
        SoilLogger.debug("SoilValueMaps: addPaintStrip executeAdd failed (%s) - disabling add path", tostring(err))
        self.hasExecuteAdd = false
        return 0
    end
"""

MUTATIONS = [
 ("C1-clamp-after-the-add", SVM,
  [(CLAMP + "\n" + ADD, ADD + "\n" + CLAMP, 1)],
  "the clamp runs after the add again and parks the pixels the add just moved"),
 ("C2-floor-ignored", SVM,
  [("    local rawLow = def.rawFloor or RAW_MIN\n    local filter = entry.filter\n\n    -- Saturation band (commit c776536b",
    "    local rawLow = RAW_MIN\n    local filter = entry.filter\n\n    -- Saturation band (commit c776536b", 1)],
  "a layer's own rawFloor is ignored: the strip floors at RAW_MIN"),
 ("C3-clamp-dropped", SVM,
  [("    if type(m.executeSet) == \"function\" then\n        local sok, serr = pcall(function()\n            if rawDelta > 0 then\n",
    "    if false then\n        local sok, serr = pcall(function()\n            if rawDelta > 0 then\n", 1)],
  "no clamp: a pixel that cannot take the whole dose is left where it was"),
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
    for l in named[:4]:
        print("        " + l[:170])
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
