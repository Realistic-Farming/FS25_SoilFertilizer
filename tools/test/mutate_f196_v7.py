#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F196 V7 and the observable unit-rule fallbacks: do the bars catch the defects
they claim to?

Each mutation puts back one thing the repair removed, or breaks one clause the brief
states, and requires the named bar to go RED with named rows. Every edit asserts it
LANDED by exact occurrence count. Three shipped files are targets; all are restored
in a finally and proved by sha256.

Run from tools/test:  py mutate_f196_v7.py
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
    "sfs": os.path.join(ROOT, "src", "SoilFertilitySystem.lua"),
    "hm":  os.path.join(ROOT, "src", "hooks", "HookManager.lua"),
    "hud": os.path.join(ROOT, "src", "ui", "SoilHUD.lua"),
}
V7BAR  = "RSF-F196-v7_result_gate_test.lua"
OBSBAR = "RSF-F196-unit_rule_fallback_observable_test.lua"
TICK, CROSS = "✓", "✗"

REFUSE = ("    if hm ~= nil and type(hm.isRefusedProduct) == \"function\" and hm:isRefusedProduct(fillTypeIndex) then\n"
          "        return false\n"
          "    end\n")

# (id, file, bar, [(old, new, count)], the clause it breaks, expectation)
MUTATIONS = [
    ("V7-refusal-check-removed", "sfs", V7BAR,
     [(REFUSE, "", 1)],
     "onFertilizerApplied no longer validates: a refused product is applied and every side effect runs",
     "KILLED"),

    ("V7-returns-nil-on-refusal", "sfs", V7BAR,
     [("        return false\n    end\n\n    self:applyFertilizer(fieldId, fillTypeIndex, liters, boomPoints)\n",
       "        return nil\n    end\n\n    self:applyFertilizer(fieldId, fillTypeIndex, liters, boomPoints)\n", 1)],
     "the clause says exactly false; a nil is not a result a caller can distinguish from the old void return",
     "KILLED"),

    ("V7-valid-path-returns-nothing", "sfs", V7BAR,
     [("                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)\n"
       "            end\n"
       "        end\n"
       "    end\n"
       "    return true\n"
       "end\n",
       "                SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)\n"
       "            end\n"
       "        end\n"
       "    end\n"
       "end\n", 1)],
     "the valid path returns nothing, so the callers' result == true gate is inert for every valid pass",
     "KILLED"),

    ("V7-primary-caller-ignores-result", "hm", V7BAR,
     [("                        if soilSys:onFertilizerApplied(fId, fillTypeIndex, sectionLiters, burnBoomPts) ~= true then\n"
       "                            fertResult = false\n"
       "                        end\n",
       "                        soilSys:onFertilizerApplied(fId, fillTypeIndex, sectionLiters, burnBoomPts)\n", 1)],
     "the boolean is not wired at the primary call site: the gate is inert (the brief's build note)",
     "KILLED"),

    ("V7-primary-scorch-ungated", "hm", V7BAR,
     [("                    if not isFertilizer or fertResult then\n"
       "                        soilSys:applyScorchEffect(fId, fillType.name)\n"
       "                    end\n",
       "                    soilSys:applyScorchEffect(fId, fillType.name)\n", 1)],
     "a refused fertilizer product still scorches",
     "KILLED"),

    ("V7-primary-scorch-gates-herbicide-too", "hm", V7BAR,
     [("                    if not isFertilizer or fertResult then\n"
       "                        soilSys:applyScorchEffect(fId, fillType.name)\n"
       "                    end\n",
       "                    if isFertilizer and fertResult then\n"
       "                        soilSys:applyScorchEffect(fId, fillType.name)\n"
       "                    end\n", 1)],
     "the gate has become a whole-helper gate: a herbicide-only pass loses its heat scorch",
     "KILLED"),

    ("V7-primary-paint-and-coverage-ungated", "hm", V7BAR,
     [("                if soilSys and fieldId and fieldId > 0 and (not isFertilizer or fertResult) then\n"
       "                    local vww = self.spec_variableWorkWidth\n",
       "                if soilSys and fieldId and fieldId > 0 then\n"
       "                    local vww = self.spec_variableWorkWidth\n", 1)],
     "a refused product still paints its boom strip, marks its cells and advances litre coverage",
     "KILLED"),

    ("V7-secondary-caller-ignores-result", "hm", V7BAR,
     [("                                                        if soilSys:onFertilizerApplied(fId2, secFillTypeIndex, sLiters2, burnBoomPts2) ~= true then\n"
       "                                                            fertResult2 = false\n"
       "                                                        end\n",
       "                                                        soilSys:onFertilizerApplied(fId2, secFillTypeIndex, sLiters2, burnBoomPts2)\n", 1)],
     "the boolean is not wired at the secondary call site",
     "KILLED"),

    ("OBS-system-fallback-silent", "sfs", OBSBAR,
     [("    SoilFertilitySystem.unitRuleFallbacks = (SoilFertilitySystem.unitRuleFallbacks or 0) + 1\n", "", 1)],
     "the wrapper's fallback converts by 1 without a trace again",
     "KILLED"),

    ("OBS-unresolved-name-silent", "sfs", OBSBAR,
     [("        SoilFertilitySystem.unitRuleUnresolvedNames = (SoilFertilitySystem.unitRuleUnresolvedNames or 0) + 1\n", "", 1)],
     "a name that resolved to nothing converts by 1 without a trace",
     "KILLED"),

    ("OBS-hud-fallback-silent", "hud", OBSBAR,
     [("                    SoilHUD.unitRuleFallbacks = (SoilHUD.unitRuleFallbacks or 0) + 1\n", "", 1)],
     "the HUD's guard converts by 1 without a trace",
     "KILLED"),
]


def read_bytes(p):
    with open(p, "rb") as fh:
        return fh.read()


def run_suite():
    proc = subprocess.run([os.environ.get("NODE", "node"), "run-tests.mjs"], cwd=HERE,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.stdout + proc.stderr


def bar_result(out, bar):
    for line in out.splitlines():
        if bar in line and (line.startswith(TICK) or line.startswith(CROSS)):
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
        print("target : %-40s sha256 %s" % (os.path.relpath(p, ROOT), digests[k]))
    print()
    out = run_suite()
    for bar in (V7BAR, OBSBAR):
        sym, line = bar_result(out, bar)
        if sym != TICK:
            print("a bar is not green before mutating: %s" % line)
            return 2
        print("BASELINE  %s" % line)
    print()

    results = []
    try:
        for mid, fkey, bar, edits, defect, expect in MUTATIONS:
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
            sym, line = bar_result(out, bar)
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
            print("restore: %-40s sha256 %s" % (os.path.relpath(p, ROOT), "MATCHES" if ok else "DOES NOT MATCH, A SHIPPED FILE IS NOT AS IT WAS"))
        if bad_restore:
            return 3
    out = run_suite()
    allgreen = all(bar_result(out, b)[0] == TICK for b in (V7BAR, OBSBAR))
    print("after restore: %s\n" % ("both bars green" if allgreen else "NOT GREEN"))
    bad = [m for m, v, e in results if v != e]
    for m, v, e in results:
        print("  %-9s %s%s" % (v, m, "" if v == e else "   <-- NOT AS DECLARED"))
    if bad:
        print("\n%d mutation(s) not as declared: %s" % (len(bad), ", ".join(bad)))
        return 1
    print("\nall %d mutations killed with named rows" % len(results))
    return 0 if allgreen else 4


if __name__ == "__main__":
    sys.exit(main())
