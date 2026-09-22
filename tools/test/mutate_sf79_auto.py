#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 D pH AUTO: does the bar catch the defects it claims to?

Each mutation puts one of the three defects back, or breaks one clause of section
D, and requires SF-79-ph_auto_whole_rate_test.lua to go RED with named rows. Two
shipped files are targets; both restored in a finally and proved by sha256.

Run from tools/test:  py mutate_sf79_auto.py
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
    "pph": os.path.join(ROOT, "src", "PositionalPH.lua"),
    "hm":  os.path.join(ROOT, "src", "hooks", "HookManager.lua"),
}
BAR = "SF-79-ph_auto_whole_rate_test.lua"
TICK, CROSS = "✓", "✗"

SAMPLE = ("    local ph = PositionalPH.sampleWorkAreasPH(self, sprayerSelf, workAreas)\n"
          "    if ph == nil then return remember(1.0) end\n")

# (id, file, [(old, new, count)], the clause it breaks, expectation)
MUTATIONS = [
    ("defect1-index-read-as-descriptor", "pph",
     [("    local fillType = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(ftIdx)\n",
       "    local fillType = ftIdx\n", 1)],
     "the index is indexed for a name again: AUTO returns 1.0 (or raises) on every real path",
     "KILLED"),

    ("defect2-stale-point-restored", "pph",
     [(SAMPLE,
       "    local ph = nil\n"
       "    if self._lastSprayX ~= nil and self._lastSprayZ ~= nil then\n"
       "        ph = self.valueMaps:readValueAtWorld(PositionalPH.PH_LAYER, self._lastSprayX, self._lastSprayZ)\n"
       "    end\n"
       "    if ph == nil then return remember(1.0) end\n", 1)],
     "the coordinate comes from the previous tick's point again, the thing section D forbids",
     "KILLED"),

    ("defect3-caller-passes-nil", "hm",
     [("                local currentAreas = workAreas\n"
       "                if type(currentAreas) ~= \"table\" then\n"
       "                    currentAreas = self.spec_workArea and self.spec_workArea.workAreas\n"
       "                end\n",
       "                local currentAreas = spec.workArea and spec.workArea.workAreas\n", 1)],
     "the caller reads spec_sprayer.workArea again, a member the engine never sets: AUTO gets nil on every real vehicle",
     "KILLED"),

    ("caller-ignores-the-raised-list", "hm",
     [("                local currentAreas = workAreas\n"
       "                if type(currentAreas) ~= \"table\" then\n",
       "                local currentAreas = nil\n"
       "                if type(currentAreas) ~= \"table\" then\n", 1)],
     "the list the engine raised the event with is discarded for the vehicle's own",
     "KILLED"),

    ("sample-from-sprayers-own-list", "pph",
     [(SAMPLE,
       "    local ph = PositionalPH.sampleWorkAreasPH(self, sprayerSelf, sprayerSelf and sprayerSelf.spec_workArea and sprayerSelf.spec_workArea.workAreas)\n"
       "    if ph == nil then return remember(1.0) end\n", 1)],
     "the function reaches into the sprayer instead of using the list it was handed",
     "KILLED"),

    ("stale-point-as-fallback", "pph",
     [(SAMPLE,
       "    local ph = PositionalPH.sampleWorkAreasPH(self, sprayerSelf, workAreas)\n"
       "    if ph == nil and self._lastSprayX ~= nil and self._lastSprayZ ~= nil then\n"
       "        ph = self.valueMaps:readValueAtWorld(PositionalPH.PH_LAYER, self._lastSprayX, self._lastSprayZ)\n"
       "    end\n"
       "    if ph == nil then return remember(1.0) end\n", 1)],
     "no areas falls back to the stale point instead of retaining the selected rate",
     "KILLED"),

    ("auxiliary-not-skipped", "pph",
     [("        local usable = type(wa) == 'table' and (aux == nil or wa.type ~= aux)\n",
       "        local usable = type(wa) == 'table'\n", 1)],
     "an auxiliary work area contributes ground the applicator does not treat",
     "KILLED"),

    ("inactive-sections-counted", "pph",
     [("            if ok and active == false then usable = false end\n", "", 1)],
     "current section state is ignored: a lifted section's ground drives the rate",
     "KILLED"),

    ("cache-dropped", "pph",
     [("    if cached ~= nil and (now - cached.time) < 5000 then return cached.factor end\n", "", 1)],
     "the five-second cadence is gone: recomputed every tick",
     "KILLED"),

    ("curve-altered-above-band", "pph",
     [("            else\n                factor = 0.5\n            end\n        else\n",
       "            else\n                factor = 0.75\n            end\n        else\n", 1)],
     "the existing reduce value for a pH-up product above the band is changed",
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
    for k, p in FILES.items():
        print("target : %-32s sha256 %s" % (os.path.relpath(p, ROOT), digests[k]))
    print("bar    : %s\n" % BAR)
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
                    print("%s: EDIT DID NOT LAND, anchor found %d, wanted %d" % (mid, found, want))
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
            print("%-9s %s  [expected %s]\n    defect : %s\n    bar    : %s" % (verdict, mid, expect, defect, line or "NO RESULT ROW"))
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
            print("restore: %-32s sha256 %s" % (os.path.relpath(p, ROOT), "MATCHES" if ok else "DOES NOT MATCH, A SHIPPED FILE IS NOT AS IT WAS"))
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
