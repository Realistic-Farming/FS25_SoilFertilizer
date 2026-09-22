#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F196 slice 3: does the unit-rule bar catch the defects it claims to?

Each mutation puts back one thing the repair removed, or breaks one clause the
brief states, and requires RSF-F196-unit_rule_test.lua to go RED with named rows.
Then it restores every file and requires GREEN again. Every edit asserts it
LANDED by exact occurrence count first. Three shipped files are targets; all are
restored in a finally and proved by sha256.

Run from tools/test:  py mutate_f196_unit_rule.py
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
FILES = {
    "hm":  os.path.join(ROOT, "src", "hooks", "HookManager.lua"),
    "sfs": os.path.join(ROOT, "src", "SoilFertilitySystem.lua"),
    "hud": os.path.join(ROOT, "src", "ui", "SoilHUD.lua"),
}
BAR = "RSF-F196-unit_rule_test.lua"
TICK, CROSS = "✓", "✗"

# (id, file, [(old, new, count)], the clause it breaks, expectation)
MUTATIONS = [
    ("C2-kilograms-as-litres", "hm",
     [("                local customLPS  = (customRate / kgPerLiter) / 36000\n",
       "                local customLPS  = customRate / 36000\n", 1)],
     "registration treats the kg/ha rate as L/ha again: a hectare drains the wrong mass",
     "KILLED"),

    ("U2-every-product-converts", "hm",
     [("    if fillType == nil or not HookManager.isDryProductName(fillType.name) then return nil end\n",
       "    if fillType == nil then return nil end\n", 1)],
     "the twelve-product boundary is dropped: base-game FERTILIZER and liquids convert too (U4 broken)",
     "KILLED"),

    ("U2-divides-instead", "hm",
     [("    return liters * kgPerLiter\n", "    return liters / kgPerLiter\n", 1)],
     "the conversion runs the wrong way",
     "KILLED"),

    ("U5b-exclusion-never-built", "hm",
     [("                            if wapU5b and wapU5b.sprayVehicle == self then\n",
       "                            if false then\n", 1)],
     "the driving unit is never excluded: the incumbent double credit returns",
     "KILLED"),

    ("U5b-excludes-on-external-too", "hm",
     [("                            if wapU5b and wapU5b.sprayVehicle == self then\n",
       "                            if wapU5b and wapU5b.sprayVehicle ~= nil then\n", 1)],
     "a foreign fill-unit index silently skips a valid local secondary",
     "KILLED"),

    ("U5b-resolver-unit-not-excluded", "hm",
     [("                                if okOwn and type(ownFui) == \"number\" and fuSpec.fillUnits[ownFui] ~= nil then\n",
       "                                if false then\n", 1)],
     "only native's unit is excluded; the unit the resolver reads the pass product from is counted as a secondary",
     "KILLED"),

    ("U3-site1-unconverted", "sfs",
     [("        local factor = (massEquivalent(fillType, liters) / 1000) / areaInHa * rrMult\n",
       "        local factor = (liters / 1000) / areaInHa * rrMult\n", 1)],
     "the nutrient factor divides raw litres by area: a full hectare no longer credits the configured mass",
     "KILLED"),

    ("U3-site2-unconverted", "sfs",
     [("        if massEquivalent(fillType, field.nutrientBuffer[fillTypeIndex]) >= coverageThreshold and\n",
       "        if field.nutrientBuffer[fillTypeIndex] >= coverageThreshold and\n", 1)],
     "the fully-treated comparison meets the kg threshold with raw litres",
     "KILLED"),

    ("U3-site3-unconverted", "sfs",
     [("    local areaThisTick = massEquivalent(ftDesc, liters) / ratePerHa\n",
       "    local areaThisTick = liters / ratePerHa\n", 1)],
     "the litre-fallback coverage divides raw litres by the kg/ha rate",
     "KILLED"),

    ("U3-site4-hud-unconverted", "hud",
     [("                    bufferMass = HookManager.massEquivalent(fillType, currentBuffer)\n",
       "                    bufferMass = currentBuffer\n", 1)],
     "the ghost bar and the fully-treated threshold disagree by the density",
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
    originals = {k: read_bytes(p) for k, p in FILES.items()}
    digests = {k: hashlib.sha256(b).hexdigest() for k, b in originals.items()}
    texts = {k: b.decode("utf-8") for k, b in originals.items()}
    print("bar    : %s" % BAR)
    for k, p in FILES.items():
        print("target : %-40s sha256 %s" % (os.path.relpath(p, ROOT), digests[k]))
    print()
    sym, line = bar_result(run_suite())
    if sym != TICK:
        print("the bar is not green before mutating: %s" % line)
        return 2
    print("BASELINE  %s\n" % line)

    results = []
    try:
        for mid, fkey, edits, defect, expect in MUTATIONS:
            mutated, landed = texts[fkey], True
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
            with open(FILES[fkey], "w", encoding="utf-8", newline="") as fh:
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
            with open(FILES[fkey], "wb") as fh:
                fh.write(originals[fkey])
    finally:
        bad_restore = False
        for k, p in FILES.items():
            with open(p, "wb") as fh:
                fh.write(originals[k])
            after = hashlib.sha256(read_bytes(p)).hexdigest()
            ok = after == digests[k]
            bad_restore = bad_restore or not ok
            print("restore: %-40s sha256 %s" % (os.path.relpath(p, ROOT), "MATCHES" if ok else "DOES NOT MATCH, A SHIPPED FILE IS NOT AS IT WAS"))
        if bad_restore:
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
