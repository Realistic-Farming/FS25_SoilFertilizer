#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Narrow-tool application dot: does the bar catch the defects it claims to?

Each mutation puts back one thing the repair removed, or breaks one clause the
repair states, and requires sf_application_dot_delta_test.lua to go RED with named
rows. Then it restores the file and requires GREEN again, so a mutation that failed
to apply can never be mistaken for a kill. Every edit asserts it LANDED by exact
occurrence count first: a no-op edit and an unpinned rule both report SURVIVED.

The target is a SHIPPED file, so the restore runs in a finally and is proved by
sha256. The bar drives the real applyFertilizer, so a kill here is a kill of the
code, not of a copy.

Run from tools/test:  py mutate_sf_dot_delta.py
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
BAR = "sf_application_dot_delta_test.lua"
TICK, CROSS = "✓", "✗"

N_LINE  = '            if dotN ~= 0 then vm:addPaintStrip("nitrogen",   sx, sz, wx, wz, hx, hz, dotN) end\n'
N_DELTA = "            local dotN  = (entry.N  or 0) * factor * tunFert\n"
GATE    = "        if sprayX and sprayZ and self:vmAvailable() and not boomRecent then\n"
WINDOW  = "            and (now - field._vmBoomPaintTime) >= 0 and (now - field._vmBoomPaintTime) < 500\n"
PH_ELSE = ('            elseif dotPH ~= 0 then\n'
           '                vm:addPaintStrip("pH", sx, sz, wx, wz, hx, hz, dotPH)\n')
OM_LINE = '            if dotOM ~= 0 then vm:addPaintStrip("organicMatter", sx, sz, wx, wz, hx, hz, dotOM) end\n'
P_LINE  = '            if dotP ~= 0 then vm:addPaintStrip("phosphorus", sx, sz, wx, wz, hx, hz, dotP) end\n'

# (id, [(old, new, count)], the clause it breaks, expectation)
MUTATIONS = [
    ("N-stamp-restored",
     [(N_LINE, '            if entry.N then vm:writeValueAtWorld("nitrogen", sprayX, sprayZ, field.nitrogen, 2.5) end\n', 1)],
     "the nitrogen dot goes back to SETTING the field scalar over the square, the defect itself",
     "KILLED"),

    ("delta-is-the-scalar",
     [(N_DELTA, "            local dotN  = field.nitrogen\n", 1)],
     "the additive primitive is fed the field scalar instead of this tick's delta (the stamp's value through the add path)",
     "KILLED"),

    ("dot-reads-the-tick-stash",
     [(N_DELTA, "            local dotN  = sd.dN\n", 1)],
     "the dot paints the tick's accumulated stash, so the second VWW section of a tick re-applies the first",
     "KILLED"),

    ("zero-guard-dropped",
     [(N_LINE, '            if entry.N then vm:addPaintStrip("nitrogen",   sx, sz, wx, wz, hx, hz, dotN) end\n', 1)],
     "a zero-litre tick (every pass's first) reaches the primitive with a zero delta",
     "KILLED"),

    ("radius-shrunk",
     [("            local r = 2.5\n", "            local r = 1.5\n", 1)],
     "the square is no longer the 5 m square the stamp covered",
     "KILLED"),

    ("defer-gate-dropped",
     [(GATE, "        if sprayX and sprayZ and self:vmAvailable() then\n", 1)],
     "a wide sprayer's dot no longer defers to the boom strip that painted half a second ago",
     "KILLED"),

    ("defer-window-doubled",
     [(WINDOW, "            and (now - field._vmBoomPaintTime) >= 0 and (now - field._vmBoomPaintTime) < 1000\n", 1)],
     "the deferral window moves from the ~half second the comment states",
     "KILLED"),

    ("pH-fallback-stamp-restored",
     [(PH_ELSE, '            elseif entry.pH then\n                vm:writeValueAtWorld("pH", sprayX, sprayZ, field.pH, 2.5)\n', 1)],
     "the pH fallback (no positional writer) goes back to stamping the field pH",
     "KILLED"),

    ("OM-write-dropped",
     [(OM_LINE, "", 1)],
     "organic matter is no longer painted by the dot at all",
     "KILLED"),

    ("P-fed-N-delta",
     [(P_LINE, '            if dotP ~= 0 then vm:addPaintStrip("phosphorus", sx, sz, wx, wz, hx, hz, dotN) end\n', 1)],
     "a copy-paste slip paints the nitrogen delta into the phosphorus layer",
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
                    print("%s: EDIT DID NOT LAND, anchor found %d, wanted %d\n    %s" % (mid, found, want, old.splitlines()[0][:76]))
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
            print("%-9s %s  [expected %s]\n    defect : %s\n    bar    : %s" % (verdict, mid, expect, defect, line or "NO RESULT ROW, the file errored"))
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
