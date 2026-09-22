#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 3.B schema key: does the bar catch the versions that would ship it wrong?

Six mutants, each a plausible way to get the freeze wrong, and each must send
SF-79-ph_schema_seed_freeze_test.lua RED:

  M1  ignore the marker (always freeze)   a marked save's scalar, possibly the later
                                          report, becomes the seed. 3.B forbids it.
  M2  drop the clamp                      a scalar the load clamped to 8.5 becomes a
                                          seed outside the carrier bounds.
  M3  drop sf79PHSchema from the ledger   the ledger restore can no longer tell a
      snapshot                            marked save from an unmarked one and freezes
                                          a dev save's scalar.
  M4  re-freeze when a seed is present    the frozen seed moves with the scalar on
                                          every load, so "frozen" means nothing.
  M5  XML loader drops the freeze call    unmarked XML saves never freeze.
  M6  ledger loader drops the freeze call unmarked ledger snapshots never freeze.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_sf79_schema_key.py
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
BAR = "SF-79-ph_schema_seed_freeze_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

GATE = "    if type(field) ~= 'table' or schemaMarked == true then return false end\n"
HAS_SEED = "    if type(field._phSeedScalar) == 'number' then return false end\n"
CLAMP = "    field._phSeedScalar = math.max(limits.PH_MIN, math.min(limits.PH_MAX, pH))\n"
LEDGER_OUT = "f66ResistanceReset = 1, sf79PHSchema = 1, fields = {} }"
XML_CALL = ("        if type(self._phFreezeSeedFromLoad) == \"function\" then\n"
            "            self:_phFreezeSeedFromLoad(self.fieldData[fieldId], sf79Marked)\n"
            "        end\n")
LEDGER_CALL = ("            if type(self._phFreezeSeedFromLoad) == \"function\" then\n"
               "                self:_phFreezeSeedFromLoad(f, sf79Marked)\n"
               "            end\n")

MUTATIONS = [
    ("M1 ignore the marker (always freeze)", PPH,
     [(GATE, "    if type(field) ~= 'table' then return false end\n", 1)]),
    ("M2 drop the clamp", PPH, [(CLAMP, "    field._phSeedScalar = pH\n", 1)]),
    ("M3 drop sf79PHSchema from the ledger snapshot", SFS,
     [(LEDGER_OUT, "f66ResistanceReset = 1, fields = {} }", 1)]),
    ("M4 re-freeze when a seed is present", PPH, [(HAS_SEED, "", 1)]),
    ("M5 XML loader drops the freeze call", SFS, [(XML_CALL, "", 1)]),
    ("M6 ledger loader drops the freeze call", SFS, [(LEDGER_CALL, "", 1)]),
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
        base_src = bases[target][0]
        mutated, why = apply(base_src, edits)
        if mutated is None or mutated == base_src:
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
