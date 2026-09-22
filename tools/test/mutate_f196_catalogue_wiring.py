#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catalogue wiring hotfix: does the bar catch the defect it exists for?

The bar starts from production's own entry point (registerCustomSprayTypes) and
populates nothing by hand, so a mutation that removes the production caller must
turn it RED with named rows. Restore is proved by sha256.

Run from tools/test:  py mutate_f196_catalogue_wiring.py
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
TARGET = os.path.join(ROOT, "src", "hooks", "HookManager.lua")
BAR = "RSF-F196-catalogue_wiring_test.lua"
TICK, CROSS = "✓", "✗"

CALL = "    local catalogued = self:rebuildCustomProductCatalogue()\n"

MUTATIONS = [
    ("rebuild-not-wired",
     [(CALL, "    local catalogued = 0\n", 1)],
     "the production caller is removed: the regression #974 shipped, catalogue {} at runtime",
     "KILLED"),

    ("rebuild-only-when-complete",
     [(CALL, "    local catalogued = 0\n    if skipped == 0 then catalogued = self:rebuildCustomProductCatalogue() end\n", 1)],
     "the catalogue is built only once every fill type has loaded: on a dedi the first attempts leave it empty",
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
            for r in rows[:6]:
                print("    " + r)
            if len(rows) > 6:
                print("    ... and %d more" % (len(rows) - 6))
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
