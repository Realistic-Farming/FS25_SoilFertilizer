#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The repaired l10n gates: does the new bar catch the defect and the half-repairs?

l10n_gate_sites_test.lua drives SoilMinimapLayer.buildLayerLabel, whose only text
path is one of the fourteen repaired sites. This puts the old guard back, and then
each plausible half-repair, and requires the bar to go RED with named rows. A bar
that passes against both the fix and the defect proves nothing, and this suite was
green before the repair too.

Each mutation asserts its edit LANDED by exact occurrence count first: a no-op
edit and an unpinned rule both report SURVIVED. The restore runs in a finally and
is proved with a sha256, because an ad-hoc mutation that fails to restore leaves a
mutated SHIPPED file in the worktree, which is worse here than in the harness.

run-tests.mjs has no single-file filter, so this reads the per-file result line out
of the full run.

Run from tools/test:  py mutate_l10n_gate_sites.py
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
TARGET = os.path.join(ROOT, "src", "ui", "SoilMinimapLayer.lua")
BAR = "l10n_gate_sites_test.lua"
TICK = "✓"
CROSS = "✗"

GATE = (
    "    local i18n = g_i18n\n"
    "    if i18n == nil or type(i18n.hasText) ~= \"function\" or type(i18n.getText) ~= \"function\" then\n"
    "        return fallback\n"
    "    end\n"
    "    local okHas, has = pcall(i18n.hasText, i18n, key)\n"
    "    if not okHas or has ~= true then return fallback end\n"
    "    local ok, text = pcall(i18n.getText, i18n, key)\n"
    "    if not ok or type(text) ~= \"string\" or text == \"\" then return fallback end\n"
    "    return text\n"
)

OLD_GUARD = (
    "    if key and g_i18n then\n"
    "        local ok, text = pcall(function() return g_i18n:getText(key) end)\n"
    "        if ok and text and text ~= \"\" and text ~= (\"$l10n_\" .. key) then\n"
    "            return text\n"
    "        end\n"
    "    end\n"
    "    return fallback\n"
)

NO_HASTEXT = (
    "    local i18n = g_i18n\n"
    "    if i18n == nil or type(i18n.getText) ~= \"function\" then\n"
    "        return fallback\n"
    "    end\n"
    "    local ok, text = pcall(i18n.getText, i18n, key)\n"
    "    if not ok or type(text) ~= \"string\" or text == \"\" then return fallback end\n"
    "    return text\n"
)

# (id, [(old, new, expected_count)], the defect it reintroduces, expectation)
MUTATIONS = [
    ("S1-old-dollar-l10n-guard", [(GATE, OLD_GUARD, 2)],
     "the shipped defect: the only rejection test is a comparison against "
     "(\"$l10n_\" .. key), a string getText cannot return, so the engine's "
     "\"Missing '<key>' in l10n<suffix>.xml\" reaches the player",
     "KILLED"),

    ("S2-hastext-dropped", [(GATE, NO_HASTEXT, 2)],
     "a half-repair that keeps the type and empty checks but never asks whether the key "
     "exists, so the missing sentence is accepted as a translation",
     "KILLED"),

    ("S3-truthy-hastext-accepted",
     [("    if not okHas or has ~= true then return fallback end",
       "    if not okHas or not has then return fallback end", 2)],
     "hasText's answer is taken as truthy rather than compared to true, so an i18n shim "
     "returning 1 or a string passes where the engine's own boolean would not",
     "KILLED"),

    ("S4-type-check-dropped",
     [("    if not ok or type(text) ~= \"string\" or text == \"\" then return fallback end",
       "    if not ok or text == nil or text == \"\" then return fallback end", 2)],
     "a non-string translation is passed through to a caller that will concatenate or "
     "lower() it",
     "KILLED"),
]


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def run_suite():
    proc = subprocess.run(
        [os.environ.get("NODE", "node"), "run-tests.mjs"],
        cwd=HERE, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )
    return proc.stdout + proc.stderr


def bar_result(output):
    for line in output.splitlines():
        if BAR in line and (line.startswith(TICK) or line.startswith(CROSS)):
            return line[0], line.strip()
    return None, None


def failed_rows(output):
    return [l.strip() for l in output.splitlines() if l.strip().startswith("FAIL ")]


def anchor_pattern(old):
    return "\r?\n".join(re.escape(part) for part in old.split("\n"))


def main():
    original = read_bytes(TARGET)
    digest = hashlib.sha256(original).hexdigest()
    text = original.decode("utf-8")

    print("target : %s" % os.path.relpath(TARGET, ROOT))
    print("bar    : %s" % BAR)
    print("sha256 : %s (original)" % digest)
    print()

    print("BASELINE (unmutated)")
    sym, line = bar_result(run_suite())
    if sym != TICK:
        print("  the bar is not green before mutating: %s" % line)
        return 2
    print("  %s" % line)
    print()

    results = []
    try:
        for mid, edits, defect, expect in MUTATIONS:
            mutated = text
            landed = True
            for old, new, want in edits:
                pattern = anchor_pattern(old)
                found = len(re.findall(pattern, mutated))
                if found != want:
                    print("%s: EDIT DID NOT LAND - anchor found %d times, wanted %d"
                          % (mid, found, want))
                    landed = False
                    break
                mutated = re.sub(pattern, lambda _m, r=new: r, mutated, count=want)
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

            print("%s  %s  [expected %s]" % (verdict.ljust(9), mid, expect))
            print("    defect : %s" % defect)
            print("    bar    : %s"
                  % (line or "NO RESULT ROW - the file errored, so this kill names nothing"))
            for r in rows[:6]:
                print("    %s" % r)
            if len(rows) > 6:
                print("    ... and %d more failed rows" % (len(rows) - 6))
            print()
    finally:
        with open(TARGET, "wb") as fh:
            fh.write(original)
        after = hashlib.sha256(read_bytes(TARGET)).hexdigest()
        print("restore: sha256 %s %s" % (after, "MATCHES" if after == digest else "DOES NOT MATCH"))
        if after != digest:
            print("A SHIPPED FILE IS NOT AS IT WAS. Fix it before doing anything else.")
            return 3

    sym, line = bar_result(run_suite())
    print("after restore: %s" % (line or "no result row"))
    print()

    for mid, verdict, expect in results:
        tag = "" if verdict == expect else "   <-- NOT WHAT THIS MUTATION CLAIMS"
        print("  %s  %s%s" % (verdict.ljust(9), mid, tag))

    off = [m for m, v, e in results if v != e]
    if off:
        print("\n%d mutation(s) did not behave as declared: %s" % (len(off), ", ".join(off)))
        return 1
    print("\nall %d mutations killed by %s, with named rows" % (len(results), BAR))
    return 0 if sym == TICK else 4


if __name__ == "__main__":
    sys.exit(main())
