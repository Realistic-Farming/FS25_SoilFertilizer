# MAINTENANCE row 106 mutation battery (targeted, a small logic change): the aimed-delta
# windows and pass order of src/maps/SoilValueMaps.lua (aimedWindows, applyRawDeltaToLayer,
# applyRawDeltaToPolygonBand) and the tedder's equilibrium floor (src/HayBet.lua,
# applyTedderDelta: the live sky's EMC, RAW_FLOOR with no sky).
# Rows live in MAINT-106-store_floor_before_add_spec_test.lua; every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# Not run, and why:
# - the positive side's saturateTo: no caller passes it (the four callers are
#   MaterialWetness:dryPass and :wetPass, HayBet:applyTedderDelta and PositionalPH:363, plus
#   the settings panel's debug buttons), and its windows are unchanged by row 106.
# - the order of a partial write when executeAdd raises after the edge pass: the layer stands
#   down on that raise either way (hasExecuteAdd false, nil returned), so no later pass reads
#   the difference.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_maint106_store_floor.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SVM = "src/maps/SoilValueMaps.lua"
HB = "src/HayBet.lua"

BAND_EDGE = """    if edgeLow then
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, edgeLow, edgeHigh)
        local okEdge, errEdge = pcall(function() m:executeSet(edgeValue, filter) end)
        if not okEdge then
            SoilLogger.warning("SoilValueMaps: edge pass failed on '%s' (%s)", key, tostring(errEdge))
        end
    end
"""
BAND_ADD = """    if addLow then
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, addLow, addHigh)
        local ok, err = pcall(function() m:executeAdd(rawDelta, filter) end)
        if not ok then
            self.hasExecuteAdd = false
            SoilLogger.warning("SoilValueMaps: executeAdd failed on '%s' (%s) - layer stands down",
                key, tostring(err))
            return nil
        end
    end
"""
LAYER_SAT = """    if satLow then
        coverWholeMap()
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, satLow, satHigh)
        local okSat, errSat = pcall(function() m:executeSet(RAW_MAX, filter) end)
        if not okSat then
            SoilLogger.warning("SoilValueMaps: saturating pass failed on '%s' (%s)", key, tostring(errSat))
        end
    end
"""
LAYER_ADD = """    if addLow then
        coverWholeMap()
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, addLow, addHigh)
        local ok, err = pcall(function() m:executeAdd(rawDelta, filter) end)
        if not ok then
            self.hasExecuteAdd = false
            SoilLogger.warning("SoilValueMaps: executeAdd failed on '%s' (%s) - layer stands down",
                key, tostring(err))
            return nil
        end
    end
"""
MID = "\n    -- Pass 2: the add. Its window stops short of RAW_MAX - rawDelta so no pixel can\n    -- overflow past the ceiling and wrap into the raw-0 no-data sentinel.\n"

MUTATIONS = [
 ("F1-add-ignores-the-floor", SVM,
  [("        addLow   = math.max(rawLow, floorRaw + mag)\n", "        addLow   = math.max(rawLow, RAW_MIN + mag)\n", 1)],
  "a negative add starts at RAW_MIN + step again: it takes a pixel the floor pass just parked"),
 ("F2-floor-pass-raises-the-sentinel", SVM,
  [("        edgeLow  = math.max(rawLow, floorRaw)\n", "        edgeLow  = rawLow\n", 1)],
  "the floor pass takes pixels below the floor too, raising a sentinel to a value"),
 ("F3-floor-not-passed-to-the-windows", SVM,
  [("        aimedWindows(rawDelta, rawLow, rawHigh, rawDelta < 0 and edgeValue or nil)\n",
    "        aimedWindows(rawDelta, rawLow, rawHigh, nil)\n", 1)],
  "the band's windows floor at RAW_MIN whatever floorTo says"),
 ("F4-band-edge-after-the-add", SVM,
  [(BAND_EDGE + "\n" + BAND_ADD, BAND_ADD + "\n" + BAND_EDGE, 1)],
  "the band's edge pass runs after the add and parks the pixels the add just moved"),
 ("F5-layer-saturate-after-the-add", SVM,
  [(LAYER_SAT + MID + LAYER_ADD, LAYER_ADD + MID + LAYER_SAT, 1)],
  "the whole-layer saturate runs after the add: a catch-up over-ages"),
 ("F6-tedder-passes-no-floor", HB,
  [("            MaterialWetness.RAW_FLOOR, SoilValueMaps.RAW_MAX - 1,\n            { floorTo = floorTo })",
    "            MaterialWetness.RAW_FLOOR, SoilValueMaps.RAW_MAX - 1)", 1)],
  "the tedder's step floors at RAW_MIN and walks a nearly dry pixel into the reserved band"),
 ("F7-tedder-floor-ignores-the-sky", HB,
  [("    if sky ~= nil then floorTo = math.max(MaterialWetness.emcRawFor(sky), MaterialWetness.RAW_FLOOR) end\n", "", 1)],
  "the tedder floors at RAW_FLOOR whatever the sky: it dries below the equilibrium floor"),
 ("F8-tedder-no-sky-floor-dropped", HB,
  [("    local floorTo = MaterialWetness.RAW_FLOOR\n", "    local floorTo = nil\n", 1)],
  "with no sky the tedder's step floors at RAW_MIN and walks a pixel into the reserved band"),
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
