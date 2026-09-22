#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 C plow routing: does the bar catch the defects it claims to?

Each mutation puts back the direct scalar write, or moves one of the brief's
numbers, and requires SF-79-plow_ph_routing_test.lua to go RED with named rows.
Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.

Run from tools/test:  py mutate_sf79_plow.py
"""
import hashlib
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGET = os.path.join(ROOT, "src", "SoilFertilitySystem.lua")
BAR = "SF-79-plow_ph_routing_test.lua"
TICK, CROSS = "✓", "✗"

CALL = ("            self:_phApplyField(fieldId, PositionalPH.OP_NORMALIZE, phNormalization,\n"
        "                phTarget, phTarget, 'plow')\n")

MUTATIONS = [
    ("routing-removed-direct-write-restored",
     [("        if type(self._phApplyField) == \"function\" then\n" + CALL +
       "            if (field.pH or phBefore) ~= phBefore then changed = true end\n"
       "        else\n",
       "        if false then\n" + CALL +
       "            if (field.pH or phBefore) ~= phBefore then changed = true end\n"
       "        else\n", 1)],
     "the plow writes field.pH directly again: the map never learns and the next spray erases it",
     "KILLED"),

    ("intensity-doubled",
     [("        local phNormalization = 0.1 * factor\n", "        local phNormalization = 0.2 * factor\n", 1)],
     "the brief's intensity 0.1 x accepted/field hectares is re-derived",
     "KILLED"),

    ("target-not-seven",
     [("        local phTarget = 7.0\n", "        local phTarget = 6.5\n", 1)],
     "the plow no longer targets 7.0",
     "KILLED"),

    ("bounds-not-equal",
     [(CALL,
       "            self:_phApplyField(fieldId, PositionalPH.OP_NORMALIZE, phNormalization,\n"
       "                SoilConstants.NUTRIENT_LIMITS.PH_NEUTRAL_LOW, SoilConstants.NUTRIENT_LIMITS.PH_NEUTRAL_HIGH, 'plow')\n", 1)],
     "the plow asks for the daily neutral band instead of its equal 7.0 bounds",
     "KILLED"),

    ("source-token-borrowed",
     [(CALL,
       "            self:_phApplyField(fieldId, PositionalPH.OP_NORMALIZE, phNormalization,\n"
       "                phTarget, phTarget, 'meadow')\n", 1)],
     "the plow's write is attributed to the meadow",
     "KILLED"),

    ("delta-instead-of-normalize",
     [(CALL,
       "            self:_phApplyField(fieldId, PositionalPH.OP_DELTA, phNormalization,\n"
       "                phTarget, phTarget, 'plow')\n", 1)],
     "a DELTA pushes past 7.0 instead of normalising toward it",
     "KILLED"),

    ("fallback-removed",
     [("            if phAfter ~= phBefore then\n"
       "                field.pH = phAfter\n"
       "                changed = true\n"
       "            end\n",
       "", 1)],
     "a system without the writer no longer moves the scalar at all (today's behaviour lost)",
     "KILLED"),
]


def read_bytes(p):
    with open(p, "rb") as fh:
        return fh.read()


def run_suite():
    proc = subprocess.run([os.environ.get("NODE", "node"), "run-tests.mjs"], cwd=HERE,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.stdout + proc.stderr


def bar_result(out):
    for line in out.splitlines():
        if BAR in line and (line.startswith(TICK) or line.startswith(CROSS)):
            return line[0], line.strip()
    return None, None


def failed_rows(out):
    return [l.strip() for l in out.splitlines() if l.strip().startswith("FAIL ")]


def pattern(old):
    return "\r?\n".join(re.escape(part) for part in old.split("\n"))


def main():
    original = read_bytes(TARGET)
    digest = hashlib.sha256(original).hexdigest()
    text = original.decode("utf-8")
    print("target : %s\nbar    : %s\nsha256 : %s\n" % (os.path.relpath(TARGET, ROOT), BAR, digest))
    sym, line = bar_result(run_suite())
    if sym != TICK:
        print("the bar is not green before mutating: %s" % line)
        return 2
    print("BASELINE  %s\n" % line)

    results = []
    try:
        for mid, edits, defect, expect in MUTATIONS:
            mutated, landed = text, True
            for old, new, want in edits:
                pat = pattern(old)
                found = len(re.findall(pat, mutated))
                if found != want:
                    print("%s: EDIT DID NOT LAND, anchor found %d, wanted %d" % (mid, found, want))
                    landed = False
                    break
                mutated = re.sub(pat, lambda _m, r=new: r, mutated, count=want)
            if not landed:
                results.append((mid, "NOT APPLIED", expect))
                continue
            with open(TARGET, "w", encoding="utf-8", newline="") as fh:
                fh.write(mutated)
            out = run_suite()
            sym, line = bar_result(out)
            rows = failed_rows(out)
            verdict = "KILLED" if sym == CROSS else ("KILLED?" if sym is None else "SURVIVED")
            results.append((mid, verdict, expect))
            print("%-9s %s  [expected %s]\n    defect : %s\n    bar    : %s" % (verdict, mid, expect, defect, line or "NO RESULT ROW"))
            for r in rows[:5]:
                print("    " + r)
            if len(rows) > 5:
                print("    ... and %d more" % (len(rows) - 5))
            print()
    finally:
        with open(TARGET, "wb") as fh:
            fh.write(original)
        after = hashlib.sha256(read_bytes(TARGET)).hexdigest()
        print("restore: sha256 %s" % ("MATCHES" if after == digest else "DOES NOT MATCH, A SHIPPED FILE IS NOT AS IT WAS"))
        if after != digest:
            return 3
    sym, line = bar_result(run_suite())
    print("after restore: %s\n" % line)
    bad = [m for m, v, e in results if v != e]
    for m, v, e in results:
        print("  %-9s %s%s" % (v, m, "" if v == e else "   <-- NOT AS DECLARED"))
    if bad:
        print("\n%d mutation(s) not as declared: %s" % (len(bad), ", ".join(bad)))
        return 1
    print("\nall %d mutations killed by %s with named rows" % (len(results), BAR))
    return 0 if sym == TICK else 4


if __name__ == "__main__":
    sys.exit(main())
