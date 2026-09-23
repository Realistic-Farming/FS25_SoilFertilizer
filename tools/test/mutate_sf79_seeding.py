#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 3.B seeding wiring (and MAINTENANCE row 74): does the bar catch the versions
that would ship it wrong?

Seven mutants, each must send SF-79-ph_seeding_wiring_test.lua RED:

  M1  migration moved after the early return   a restored save never fills its holes.
  M2  fallback reverted to field.pH            a marked-no-seed save seeds from the
                                               later report, which 3.B forbids.
  M3  the freeze dropped                       the genesis value is never frozen, so a
                                               tuning change moves the seed.
  M4  the revision bump dropped (migration)    getFieldInfo's pHRevision does not move.
  M5  invalidate+bump dropped (birth seed)     a new field's revision never moves.
  M6  row 74 nil-guard restored                a missing WorkAreaType admits auxiliary
                                               areas silently instead of raising.
  M7  getOrCreateField drops the birth seed    a lazily created field stays raw zero.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.

Run from tools/test:  py mutate_sf79_seeding.py
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SFS = os.path.join(ROOT, "src", "SoilFertilitySystem.lua")
PPH = os.path.join(ROOT, "src", "PositionalPH.lua")
BAR = "SF-79-ph_seeding_wiring_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

MIGRATE_BLOCK_START = "    if type(self._migratePH) == \"function\" then\n        local phEntry = self.valueMaps.getLayerEntry"
GENESIS = ("        local genesis = self:_computeInitialSoil(fieldId)\n"
           "        seed = genesis and genesis.pH or SoilConstants.FIELD_DEFAULTS.pH\n")
FREEZE = "    seed = math.max(limits.PH_MIN, math.min(limits.PH_MAX, seed))\n    field._phSeedScalar = seed\n"
MIG_BUMP = ("        self:_phInvalidateReport(fieldId)\n"
            "        self._phMapRevision = (self._phMapRevision or 0) + 1\n"
            "        return writes, source\n")
SEED_BUMP = ("    if seeded > 0 then\n"
             "        self:_phInvalidateReport(fieldId)\n"
             "        self._phMapRevision = (self._phMapRevision or 0) + 1\n"
             "    end\n")
AUX = "    local aux = WorkAreaType.AUXILIARY\n"
BIRTH = "        self.fieldData[fieldId]._phSeedScalar = seed\n        self:_seedPHFootprint(fieldId, seed)\n"

MUTATIONS = [
    ("M1 migration moved after the early return", SFS,
     [(MIGRATE_BLOCK_START,
       "    if self.valueMaps.loadedFromSave and not force then return end\n" + MIGRATE_BLOCK_START, 1)]),
    ("M2 fallback reverted to field.pH", PPH,
     [(GENESIS, "        seed = field.pH or SoilConstants.FIELD_DEFAULTS.pH\n", 1)]),
    ("M3 the freeze dropped", PPH,
     [(FREEZE, "    seed = math.max(limits.PH_MIN, math.min(limits.PH_MAX, seed))\n", 1)]),
    ("M4 the revision bump dropped (migration)", PPH,
     [(MIG_BUMP, "        self:_phInvalidateReport(fieldId)\n        return writes, source\n", 1)]),
    ("M5 invalidate and bump dropped (birth seed)", PPH, [(SEED_BUMP, "", 1)]),
    ("M6 row 74 nil-guard restored", PPH,
     [(AUX, "    local aux = (WorkAreaType ~= nil) and WorkAreaType.AUXILIARY or nil\n", 1)]),
    ("M7 getOrCreateField drops the birth seed", SFS,
     [(BIRTH, "        self.fieldData[fieldId]._phSeedScalar = seed\n", 1)]),
]


def read(path):
    with io.open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def write(path, s):
    with io.open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def digest(path):
    return hashlib.sha256(read(path).encode("utf-8")).hexdigest()[:12]


def run_bar():
    proc = subprocess.run(["node", "run-tests.mjs"], cwd=HERE, capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    m = BAR_RE.search(out)
    if not m:
        return None, None, out.strip()[-600:]
    return int(m.group(1)), int(m.group(2)), ""


def apply(src, edits):
    for needle, repl, count in edits:
        n = src.count(needle)
        if n != count:
            crlf = needle.replace("\n", "\r\n")
            if src.count(crlf) != count:
                return None, "needle found %d time(s), expected %d: %r" % (n, count, needle[:60])
            needle, repl = crlf, repl.replace("\n", "\r\n")
        src = src.replace(needle, repl, count)
    return src, ""


def main():
    bases = {p: (read(p), digest(p)) for p in (SFS, PPH)}
    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, target, edits in MUTATIONS:
        mutated, why = apply(bases[target][0], edits)
        if mutated is None or mutated == bases[target][0]:
            unapplied.append(name)
            print("  %-48s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(target, target + ".bak")
        try:
            write(target, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(target + ".bak", target)
            os.remove(target + ".bak")
        if mf is None:
            print("  %-48s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-48s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-48s SURVIVED" % name)

    for path, (_, d) in bases.items():
        if digest(path) != d:
            print("\nRESULT: restore FAILED, %s is not byte-identical." % os.path.basename(path))
            return 1
    p2, f2, _ = run_bar()
    print("\nafter restore   : %d passed, %d failed (sources byte-identical)" % (p2, f2))
    if f2 != 0 or p2 != p:
        print("RESULT: the bar is not green again after restore.")
        return 1
    if unapplied:
        print("RESULT: %d mutation(s) did not apply; a red result would be unattributable." % len(unapplied))
        return 1
    if survived:
        print("RESULT: %d SURVIVED: %s" % (len(survived), "; ".join(survived)))
        return 1
    print("RESULT: %d killed, 0 survived, 0 unapplied." % killed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
