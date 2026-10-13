#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 pH-unknown readout: does the new bar actually catch the old gate?

A bar that passes against both the fix and the defect proves nothing. This puts
the tr() that shipped before this PR back into SoilTreatmentDialog.lua, reruns
the suite, and requires the new bar to go RED. Then it restores the file and
requires the bar GREEN again, so a mutation that silently failed to apply can
never be mistaken for a kill.

run-tests.mjs has no single-file filter, so this reads the per-file result line
out of the full run. The file is CRLF, so the patterns are line-ending agnostic.

Run from tools/test:  py mutate_sf79_ph.py
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGET = os.path.join(ROOT, "src", "ui", "SoilTreatmentDialog.lua")
BAR = "SF-79-treatment_ph_unknown_l10n_test.lua"
BACKUP = TARGET + ".mutbak"

# The gate exactly as it shipped: compares getText's return against the XML
# attribute prefix "$l10n_", which is not a string getText can ever produce.
OLD_TR_LINES = [
    "local function tr(key, fallback)",
    "    local modEnv = g_modEnvironments and g_modEnvironments[SF_TREAT_MOD_NAME]",
    "    local i18n = (modEnv and modEnv.i18n) or g_i18n",
    "    if i18n then",
    "        local ok, text = pcall(function() return i18n:getText(key) end)",
    '        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then',
    "            return text",
    "        end",
    "    end",
    "    return fallback or key",
    "end",
]

# tr() through its first end-of-line `end`, whatever the line ending is.
NEW_TR_RE = re.compile(
    r"local function tr\(key, fallback\)\r?\n.*?\r?\nend\r?\n", re.DOTALL)

BAR_RE = re.compile(
    re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")


def run_suite():
    """Run the suite. Returns (bar_passed, bar_failed, tail) for the new bar."""
    proc = subprocess.run(["node", "run-tests.mjs"],
                          cwd=HERE, capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    m = BAR_RE.search(out)
    if not m:
        return None, None, out.strip()[-600:]
    return int(m.group(1)), int(m.group(2)), out.strip()[-160:]


def main():
    with open(TARGET, "r", encoding="utf-8", newline="") as fh:
        src = fh.read()
    eol = "\r\n" if "\r\n" in src else "\n"

    p, f, tail = run_suite()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("before mutation : %d passed, %d failed" % (p, f))

    old_tr = eol.join(OLD_TR_LINES) + eol
    mutated, n = NEW_TR_RE.subn(lambda _m: old_tr, src, count=1)
    if n != 1 or mutated == src:
        print("ABORT: mutation did not apply, so a red result would be unattributable")
        return 1
    # The old gate reads SF_TREAT_MOD_NAME, which this PR removed with it. Put the
    # local back, or the mutant dies of a nil global rather than of the defect.
    if "SF_TREAT_MOD_NAME =" not in mutated:
        needle = "local SF_TREAT_MOD_DIR  ="
        repl = ("local SF_TREAT_MOD_NAME = (SoilFertilizerModName or g_currentModName)"
                + eol + needle)
        if needle not in mutated:
            print("ABORT: cannot restore SF_TREAT_MOD_NAME for the mutant")
            return 1
        mutated = mutated.replace(needle, repl, 1)

    shutil.copyfile(TARGET, BACKUP)
    try:
        with open(TARGET, "w", encoding="utf-8", newline="") as fh:
            fh.write(mutated)
        p2, f2, tail2 = run_suite()
        print("with old gate   : %s passed, %s failed" % (p2, f2))
    finally:
        shutil.copyfile(BACKUP, TARGET)
        os.remove(BACKUP)

    p3, f3, _ = run_suite()
    print("after restore   : %d passed, %d failed" % (p3, f3))

    if f2 is None:
        print("\nRESULT: the mutant did not run cleanly:\n" + tail2)
        return 1
    if f2 == 0:
        print("\nRESULT: SURVIVED. The bar passes against the old gate and proves nothing.")
        return 1
    if f3 != 0 or p3 != p:
        print("\nRESULT: restore failed, the file is not back to the fixed version.")
        return 1
    print("\nRESULT: KILLED. %d of the bar's %d assertions go red against the" % (f2, p))
    print("        shipped-before gate, and the bar is green again after restore.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
