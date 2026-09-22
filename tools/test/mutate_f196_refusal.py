#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F196 slice 2: does the refusal bar catch the defects it claims to?

Each mutation puts back one thing the repair removed, or breaks one clause the
brief states, and requires RSF-F196-density_refusal_test.lua to go RED with named
rows. Then it restores the file and requires GREEN again, so a mutation that failed
to apply can never be mistaken for a kill. Every edit asserts it LANDED by exact
occurrence count first: a no-op edit and an unpinned rule both report SURVIVED.

The target is a SHIPPED file, so the restore runs in a finally and is proved by
sha256. The bar drives the real installed hooks on an engine model, so a kill here
is a kill of the code, not of a copy.

Run from tools/test:  py mutate_f196_refusal.py
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
BAR = "RSF-F196-density_refusal_test.lua"
TICK, CROSS = "✓", "✗"

# (id, [(old, new, count)], the clause it breaks, expectation)
MUTATIONS = [
    ("R2-server-only",
     [("        local spec = self.spec_sprayer\n        local wap = spec and spec.workAreaParameters\n        if not wap then return end\n        -- The direct candidate is native's FINAL sprayFillType",
       "        if not self.isServer then return end\n        local spec = self.spec_sprayer\n        local wap = spec and spec.workAreaParameters\n        if not wap then return end\n        -- The direct candidate is native's FINAL sprayFillType", 1)],
     "the refusal folded into a server-only path, the v0.5 shape: clients keep painting a product the server refused",
     "KILLED"),

    ("R2-zeroing-dropped",
     [("        wap.sprayFillLevel = 0\n        wap.usage          = 0\n        wap.usagePerMin    = 0\n",
       "        -- zeroing removed\n", 1)],
     "the refusal is detected and logged but the dose fields are left armed, so native paints and drains anyway",
     "KILLED"),

    ("R2-usage-left-armed",
     [("        wap.sprayFillLevel = 0\n        wap.usage          = 0\n        wap.usagePerMin    = 0\n",
       "        wap.sprayFillLevel = 0\n        wap.usagePerMin    = 0\n", 1)],
     "paint stops but drain does not: usage still feeds onEndWorkAreaProcessing (Sprayer.lua:942)",
     "KILLED"),

    ("R3a-refused-not-checked",
     [("        if hookMgr:isRefusedProduct(customIdx) then\n            -- a refused rate contract. No paint, no drain, no money for this frame.\n            return FillType.UNKNOWN, 0\n        end\n",
       "", 1)],
     "the external-fill charge bills a refused product at the 1.5x premium",
     "KILLED"),

    ("R3a-price-fabricated",
     [("        if prices[customIdx] == nil or prices[customIdx] <= 0 then",
       "        if false then", 1),
      ("            local pricePerLiter = prices[customIdx]\n",
       "            local pricePerLiter = prices[customIdx] or 1.0\n", 1)],
     "the `or 1.0` that used to charge an unpriced product at a made-up rate",
     "KILLED"),

    ("R3a-delegates-when-member-in-reach",
     [("        if not customIdx then\n            -- No catalogue member in reach: native owns this fill entirely.\n            return original(sprayerSelf, fillType, dt)\n        end\n",
       "        if not customIdx or prices[customIdx] == nil then\n            return original(sprayerSelf, fillType, dt)\n        end\n", 1)],
     "an unpriced member falls through to native, whose cascade sells FERTILIZER for a UREA tank (the #205 shape)",
     "KILLED"),

    ("R1b-stamp-consulted",
     [("        local customIdx = hookMgr:resolveCustomProductIntent(sprayerSelf, fillType)\n",
       "        local customIdx = hookMgr:resolveCustomProductIntent(sprayerSelf, fillType)\n        if sprayerSelf._soilLastCustomFillType and hookMgr:isCustomProduct(sprayerSelf._soilLastCustomFillType) then customIdx = sprayerSelf._soilLastCustomFillType end\n", 1)],
     "the retired private stamp is trusted over the engine's own synced lastValidFillType",
     "KILLED"),

    ("V18-notice-every-frame",
     [("    if self._refusalNotified[fillTypeIndex] then return end\n", "", 1)],
     "the farmer is told on every refused frame instead of once per product",
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
