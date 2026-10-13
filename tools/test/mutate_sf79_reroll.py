#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 3.C reroll routing: does the bar catch the versions that would ship it wrong?

Four mutants, each a way the routing could be wrong, and each must send
SF-79-reroll_ph_routing_test.lua RED:

  M1  the call dropped from rerollAllFields only     SoilRerollFields is invisible
                                                     to the map again.
  M2  the call dropped from rerollUnownedFields only SoilRerollUnownedFields is.
  M3  OP_DELTA in place of OP_SET                    the re-roll ADDS the new pH to
                                                     the old pixels and leaves raw-zero
                                                     ground unwritten.
  M4  the refresh dropped                            the scalar keeps the unquantised
                                                     genesis value while the report
                                                     says the map's.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_sf79_reroll.py
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
BAR = "SF-79-reroll_ph_routing_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

ALL_CALL = "            self:_phRerollField(fieldId, field)\n            count = count + 1\n"
UNOWNED_CALL = "                self:_phRerollField(fieldId, field)\n                rerolled = rerolled + 1\n"
OP = "        operation = PositionalPH.OP_SET, scope = PositionalPH.SCOPE_FIELD,\n        value = field.pH, source = 'reroll',\n"
REFRESH = ("    if type(self._phRefreshScalar) == \"function\" then\n"
           "        self:_phRefreshScalar(fieldId)\n"
           "    end\n"
           "    return result\n"
           "end\n\n"
           "-- Re-roll the starting soil profile of EVERY known field")

MUTATIONS = [
    ("M1 call dropped from rerollAllFields only", [(ALL_CALL, "            count = count + 1\n", 1)]),
    ("M2 call dropped from rerollUnownedFields only", [(UNOWNED_CALL, "                rerolled = rerolled + 1\n", 1)]),
    ("M3 OP_DELTA in place of OP_SET",
     [(OP, "        operation = PositionalPH.OP_DELTA, scope = PositionalPH.SCOPE_FIELD,\n        value = field.pH, source = 'reroll',\n", 1)]),
    ("M4 the refresh dropped",
     [(REFRESH, "    return result\nend\n\n-- Re-roll the starting soil profile of EVERY known field", 1)]),
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
    base_src, base = read(SFS), digest(SFS)
    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, edits in MUTATIONS:
        mutated, why = apply(base_src, edits)
        if mutated is None or mutated == base_src:
            unapplied.append(name)
            print("  %-48s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(SFS, SFS + ".bak")
        try:
            write(SFS, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(SFS + ".bak", SFS)
            os.remove(SFS + ".bak")
        if mf is None:
            print("  %-48s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-48s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-48s SURVIVED" % name)

    if digest(SFS) != base:
        print("\nRESULT: restore FAILED, the file is not byte-identical.")
        return 1
    p2, f2, _ = run_bar()
    print("\nafter restore   : %d passed, %d failed (source byte-identical)" % (p2, f2))
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
