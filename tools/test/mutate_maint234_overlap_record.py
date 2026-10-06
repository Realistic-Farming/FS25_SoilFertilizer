# MAINTENANCE row 234 battery (targeted, a small logic fix): overlap prevention reads its own
# finer record. Production lines only: the overlap record's key, sweep and writer call
# (src/hooks/HookManager.lua), both readers, and the record's clear beside the session cells
# (src/SoilFertilitySystem.lua). The bar is MAINT-234-overlap_record_spec_test.lua.
#
# TARGETED ONLY (Tyson's ruling, 2026-09-30): each mutant runs against the test files that
# load the bar's world, --loads tools/test/lua/MAINT-234-overlap_record_world.lua, which is
# the bar alone.
#
# A mutant counts as KILLED only when the run reached its summary, failed, and every row it
# targets is among the FAIL lines. KILLED* means it failed only by a Lua error (a weak kill,
# a failure). Anything else is SURVIVED. Each run asserts the edit LANDED (exact occurrence
# count), restores byte-for-byte and PROVES the restore with a hash.
#
# Not run, and why:
# - The writer calls at the overlay-only stamp (a pass its sections do not govern) and in the
#   multi-tank replay: no bar row drives a non-sectioned machine or a second tank. Each is the
#   same one-line call beside its markBoomCells call.
# - The record's line across the travel (the boom's own line, not the root's): the bar's
#   sprayer has its boom 0.46 m behind the root, less than one record cell.
# - The `false` distance or vehicle of a stamp with neither: no row stamps without both.
# - The clears in onHarvest and _processOneDailyField (the day change and the herbicide
#   expiry): the same one-line clear beside the session cells' reset; their entry points
#   need the harvest and daily worlds. R1 and R2 kill the other two.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits production files in place.
#
# Usage (from the repo root): py tools/test/mutate_maint234_overlap_record.py [id-prefix ...] [--check]
#   --check only counts every anchor and runs nothing.
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
SELECT = "tools/test/lua/MAINT-234-overlap_record_world.lua"
HM = "src/hooks/HookManager.lua"
SFS = "src/SoilFertilitySystem.lua"
OLD_LOOKUP = "HookManager.isCellSprayedEarlier((fieldEntry.sessionCoverageCells or {})[tostring(math.floor(%s / 10) * 10000 + math.floor(%s / 10))], sprayerSelf, graceM)"

MUTATIONS = [
 ("K1-overlap-reads-10m", HM,
  [("                    alreadySprayed = HookManager.isOverlapCellSprayedEarlier(fieldEntry, tx, tz, sprayerSelf, graceM)\n",
    "                    alreadySprayed = " + (OLD_LOOKUP % ("tx", "tz")) + "\n", 1)],
  ["N1"], "overlap prevention reads the 10 m cells again"),
 ("K2-boundary-reads-10m", HM,
  [("                                        if HookManager.isOverlapCellSprayedEarlier(fieldEntry, sx, sz, sprayerSelf, graceM) then\n",
    "                                        if " + (OLD_LOOKUP % ("sx", "sz")) + " then\n", 1)],
  ["N3"], "field-boundary control's overlap copy reads the 10 m cells again"),
 ("K3-key-10m", HM,
  [("    local size = SoilConstants.ZONE.OVERLAP_CELL_SIZE\n    return math.floor(x / size) * 100000 + math.floor(z / size)\n",
    "    local size = SoilConstants.ZONE.CELL_SIZE\n    return math.floor(x / size) * 100000 + math.floor(z / size)\n", 1)],
  ["N1"], "the record's cells are 10 m"),
 ("W1-primary-not-written", HM,
  [("                        soilSys:markBoomCells(fieldId, hookMgrRef:cellsToStamp(self, boomPts), false, self)\n                        hookMgrRef:markOverlapRecord(soilSys, fieldId, self)  -- MAINTENANCE row 234\n",
    "                        soilSys:markBoomCells(fieldId, hookMgrRef:cellsToStamp(self, boomPts), false, self)\n", 1)],
  ["N1", "N1b"], "the sectioned pass does not write the record"),
 ("C1-cells-past-the-boom", HM,
  [("        if centre >= lo and centre <= hi then\n", "        if true then\n", 1)],
  ["N1"], "a cell the boom only grazes past its last node is stamped"),
 ("R1-reset-keeps-record", SFS,
  [("    if not hasCells and (field.sessionCoverageHa or 0) == 0 then return end\n    field.sessionCoverageHa       = 0\n    field.sessionCoverageFraction = 0\n    field.sessionCoverageCells    = {}\n    field.sessionOverlapOdo, field.sessionOverlapBy = nil, nil   -- MAINTENANCE row 234\n",
    "    if not hasCells and (field.sessionCoverageHa or 0) == 0 then return end\n    field.sessionCoverageHa       = 0\n    field.sessionCoverageFraction = 0\n    field.sessionCoverageCells    = {}\n", 1)],
  ["R1"], "resetSessionCoverage leaves the record"),
 ("R2-product-change-keeps-record", SFS,
  [("        field.sessionCoverageCells    = {}\n        field.sessionOverlapOdo, field.sessionOverlapBy = nil, nil   -- MAINTENANCE row 234\n",
    "        field.sessionCoverageCells    = {}\n", 1)],
  ["R2"], "a product change leaves the record"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run():
    r = subprocess.run(["node", "run-tests.mjs", "--loads", SELECT], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") and "assertions passed" not in l]
    crashes = [l for l in lines if "Lua error" in l or "group raised" in l]
    summary = any("assertions passed" in l for l in lines)
    return r.returncode, summary, fails, crashes


def main(argv):
    check = "--check" in argv
    only = [a for a in argv if not a.startswith("--")]
    originals = {}
    for rel in (HM, SFS):
        with open(os.path.join(ROOT, rel), "rb") as f:
            originals[rel] = f.read()

    def enc(rel, s):
        return (s.replace("\n", "\r\n") if b"\r\n" in originals[rel] else s).encode("utf-8")

    if check:
        bad = 0
        for mid, rel, edits, _rows, _why in MUTATIONS:
            for old, _new, want in edits:
                n = originals[rel].count(enc(rel, old))
                print("  %-32s %s" % (mid, "ok" if n == want else "ANCHOR %dx, want %d" % (n, want)))
                bad += n != want
        return 1 if bad else 0

    rc, summary, fails, crashes = run()
    if rc != 0 or not summary:
        print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
        for l in (fails + crashes)[:10]:
            print("   " + l)
        return 2
    print("baseline green")

    killed, weak, survived, badedit = [], [], [], []
    for mid, rel, edits, rows, why in MUTATIONS:
        if only and not any(mid.startswith(o) for o in only):
            continue
        path = os.path.join(ROOT, rel)
        original = originals[rel]
        mutated = original
        ok = True
        for old, new, want in edits:
            n = mutated.count(enc(rel, old))
            if n != want:
                badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
                print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
                ok = False
                break
            mutated = mutated.replace(enc(rel, old), enc(rel, new), want)
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
            rc, summary, fails, crashes = run()
        finally:
            with open(path, "wb") as f:
                f.write(original)
        with open(path, "rb") as f:
            if sha(f.read()) != sha(original):
                print("  !! %s: RESTORE FAILED, stopping" % mid)
                return 3
        hit = [r for r in rows if any(l.startswith("FAIL " + r + " ") for l in fails)]
        if rc != 0 and summary and len(hit) == len(rows):
            killed.append(mid)
            tag = "KILLED  "
        elif rc != 0 and crashes and not fails:
            weak.append(mid)
            tag = "KILLED* "
        else:
            survived.append((mid, why))
            tag = "SURVIVED"
        print("  %s %s  (%s)" % (tag, mid, why))
        print("        targets %s; failed %s" % (",".join(rows), ",".join(l.split(" ")[1] for l in fails) or "none"))
        for l in crashes[:2]:
            print("        CRASH " + l[:170])

    print("\n==== MUTATION RESULT ====")
    print("killed %d, killed* %d, survived %d, bad edit %d" % (len(killed), len(weak), len(survived), len(badedit)))
    for mid, why in survived:
        print("   SURVIVED %s: %s" % (mid, why))
    for mid, why in badedit:
        print("   BAD EDIT %s: %s" % (mid, why))
    print("production files restored byte-identical (hash-checked per mutation)")
    return 1 if (survived or badedit or weak) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
