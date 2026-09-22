#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared-prelude i18n: does the new contract bar actually catch a regression?

The prelude's g_i18n was repaired to model I18N.lua (texts table, setText,
hasText answering with a real boolean, getText returning the engine's
"Missing '<key>' in l10n<suffix>.xml" sentence). A bar that passes against both
the model and the fiction proves nothing, and the suite was green BEFORE the
repair too, so green is not evidence on its own.

Each mutation below puts one piece of the old fiction back, or a plausible
half-repair, and requires prelude_i18n_contract_test.lua to go RED with named
rows. Then it restores the file and requires GREEN again, so a mutation that
silently failed to apply can never be mistaken for a kill.

Every mutation asserts its edit LANDED by exact occurrence count before the run:
a no-op edit is indistinguishable from an unpinned rule, since both report
SURVIVED. The restore runs in a finally and is proved with a sha256 of the
original bytes, because an ad-hoc mutation that fails to restore leaves a
mutated harness file in the worktree.

One mutation (P5) is declared EQUIVALENT and is expected to survive. It is listed
rather than deleted: a battery that only carries winnable mutations overstates
what the bar proves.

The bar probes g_i18n through a call() helper, so a mutation that REMOVES a
method still fails named rows instead of taking the file down with a nil-call.
A kill that arrives as a load error names nothing.

run-tests.mjs has no single-file filter, so this reads the per-file result line
out of the full run.

Run from tools/test:  py mutate_prelude_i18n.py
"""
import hashlib
import os
import re
import subprocess
import sys

try:
    # The result rows carry U+2713 / U+2717; a cp1252 console would raise on print.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGET = os.path.join(ROOT, "tools", "test", "lua", "prelude.lua")
BAR = "prelude_i18n_contract_test.lua"
TICK = "✓"
CROSS = "✗"

HAS_TEXT_BODY = "    if key == nil then return false end\n    return self.texts[key] ~= nil"

# (id, [(old, new, expected_count), ...], the defect it reintroduces, expectation)
#
# expectation is "KILLED" for a real defect the bar must catch, or "EQUIVALENT" for a
# mutant that cannot be caught because it does not change behaviour.
MUTATIONS = [
    ("P1-hastext-always-true",
     [(HAS_TEXT_BODY, "    if key == nil then return false end\n    return true", 1)],
     "hasText claims every key exists, so a repaired gate accepts a key with no translation "
     "and shows whatever getText hands back",
     "KILLED"),

    ("P2-getext-returns-the-key",
     [("      return string.format(\"Missing '%s' in l10n.xml\", tostring(key))",
       "      return tostring(key)", 1)],
     "an absent key comes back as the key itself, the old prelude's fiction, a shape the engine "
     "never returns and the one every $l10n_ guard mistook for a translation",
     "KILLED"),

    ("P3-hastext-returns-truthy-not-boolean",
     [(HAS_TEXT_BODY, "    if key == nil then return false end\n    return self.texts[key]", 1)],
     "hasText returns the text rather than a boolean, so a gate written as `if i18n:hasText(k)` "
     "passes where the engine's own `~= true` comparison would not",
     "KILLED"),

    ("P4-hastext-removed",
     [("  hasText = function(self, key)", "  hasTextRemoved = function(self, key)", 1)],
     "the exact regression this commit repairs: an i18n object that cannot answer hasText, "
     "which a correctly repaired gate must refuse",
     "KILLED"),

    ("P5-nil-key-guard-dropped",
     [("    if key == nil then return false end\n", "", 1)],
     "hasText(nil) reaches the table lookup instead of returning early. EQUIVALENT: reading a "
     "table at a nil key is legal in Lua and yields nil, so `self.texts[nil] ~= nil` is false, "
     "the same answer the guard gives. The guard is kept for fidelity to I18N.lua:195, not "
     "because it is observable, and no test can distinguish it.",
     "EQUIVALENT"),
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
    """Return (symbol, line) for the bar's own result row, or (None, None)."""
    for line in output.splitlines():
        if BAR in line and (line.startswith(TICK) or line.startswith(CROSS)):
            return line[0], line.strip()
    return None, None


def failed_rows(output):
    return [l.strip() for l in output.splitlines() if l.strip().startswith("FAIL ")]


def anchor_pattern(old):
    """Anchors are written with LF; match a CRLF file too."""
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
                    print("    anchor: %s" % old.splitlines()[0][:78])
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
            if sym == CROSS:
                verdict = "KILLED"
            elif sym is None:
                verdict = "KILLED?"   # no result row at all: a load error, not a named kill
            else:
                verdict = "SURVIVED"
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
            print("THE HARNESS FILE IS NOT AS IT WAS. Fix it before doing anything else.")
            return 3

    sym, line = bar_result(run_suite())
    print("after restore: %s" % (line or "no result row"))
    print()

    def as_expected(verdict, expect):
        if expect == "KILLED":
            return verdict == "KILLED"
        return verdict == "SURVIVED"

    for mid, verdict, expect in results:
        tag = "" if as_expected(verdict, expect) else "   <-- NOT WHAT THIS MUTATION CLAIMS"
        print("  %s  %s%s" % (verdict.ljust(9), mid, tag))

    off = [m for m, v, e in results if not as_expected(v, e)]
    if off:
        print("\n%d mutation(s) did not behave as declared: %s" % (len(off), ", ".join(off)))
        return 1

    killed = len([1 for _m, v, e in results if e == "KILLED"])
    equiv = len([1 for _m, _v, e in results if e == "EQUIVALENT"])
    print("\n%d defect mutation(s) killed by %s with named rows; %d equivalent mutant(s) survived as declared"
          % (killed, BAR, equiv))
    return 0 if sym == TICK else 4


if __name__ == "__main__":
    sys.exit(main())
