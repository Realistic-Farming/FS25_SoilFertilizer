#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F196 R7 (Drain Vehicle recovery): does the bar catch the versions that would ship it wrong?

Six mutants, each must send RSF-F196-r7_drain_vehicle_test.lua RED:

  M1  refund the level, not what left     a swallowed or partial drain pays for material
                                          still in the tank.
  M2  clear without zero verification     a partial drain forgets a product still there.
  M3  clear on a valid last-valid         a valid product's natural empty is forgotten.
  M4  the union dropped                   AN and POLIFOSKA are not drained (the old list).
  M5  the already-empty branch skipped    an empty unit keeps remembering a refused product.
  M6  the server gate dropped on the      a client clears the remembered product.
      empty-unit clear

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.

Run from tools/test:  py mutate_f196_r7.py
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
GUI = os.path.join(ROOT, "src", "settings", "SoilSettingsGUI.lua")
BAR = "RSF-F196-r7_drain_vehicle_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

REFUND = "                        refund  = drained * priceTable[currentType] * 0.5\n"
CLEAR_GATE = "                        if post <= 0 and (isRefused(currentType) or isRefused(lastValid)) then\n"
UNION = "    if HookManager and type(HookManager.DRY_PRODUCT_NAMES) == \"table\" then\n"
EMPTY_BRANCH = "                elseif pre <= 0 and (currentType == nil or currentType == FillType.UNKNOWN) and isRefused(lastValid) then\n"
EMPTY_GATE = ("                    if isServer then\n"
              "                        pcall(function() veh:setFillUnitLastValidFillType(fuIdx, FillType.UNKNOWN) end)\n"
              "                        totalCleared = totalCleared + 1\n")

MUTATIONS = [
    ("M1 refund the level, not what left", [(REFUND, "                        refund  = pre * priceTable[currentType] * 0.5\n", 1)]),
    ("M2 clear without zero verification",
     [(CLEAR_GATE, "                        if (isRefused(currentType) or isRefused(lastValid)) then\n", 1)]),
    ("M3 clear on a valid last-valid", [(CLEAR_GATE, "                        if post <= 0 then\n", 1)]),
    ("M4 the union dropped", [(UNION, "    if false then\n", 1)]),
    ("M5 the already-empty branch skipped", [(EMPTY_BRANCH, "                elseif false then\n", 1)]),
    ("M6 the server gate dropped on the empty-unit clear",
     [(EMPTY_GATE, "                    if true then\n"
       "                        pcall(function() veh:setFillUnitLastValidFillType(fuIdx, FillType.UNKNOWN) end)\n"
       "                        totalCleared = totalCleared + 1\n", 1)]),
]


def read(path):
    with io.open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def write(path, s):
    with io.open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def digest(path):
    return hashlib.sha256(read(path).encode("utf-8")).hexdigest()[:12]


def run_bar():
    proc = subprocess.run(["node", "run-tests.mjs"], cwd=HERE, capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    m = BAR_RE.search(out)
    if not m:
        return None, None, out.strip()[-600:]
    return int(m.group(1)), int(m.group(2)), ""


def apply(src, edits):
    for needle, repl, count in edits:
        n = src.count(needle)
        if n != count:
            crlf = needle.replace("\n", "\r\n")
            if src.count(crlf) != count:
                return None, "needle found %d time(s), expected %d: %r" % (n, count, needle[:60])
            needle, repl = crlf, repl.replace("\n", "\r\n")
        src = src.replace(needle, repl, count)
    return src, ""


def main():
    base_src, base = read(GUI), digest(GUI)
    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, edits in MUTATIONS:
        mutated, why = apply(base_src, edits)
        if mutated is None or mutated == base_src:
            unapplied.append(name)
            print("  %-50s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(GUI, GUI + ".bak")
        try:
            write(GUI, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(GUI + ".bak", GUI)
            os.remove(GUI + ".bak")
        if mf is None:
            print("  %-50s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-50s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-50s SURVIVED" % name)

    if digest(GUI) != base:
        print("\nRESULT: restore FAILED, the file is not byte-identical.")
        return 1
    p2, f2, _ = run_bar()
    print("\nafter restore   : %d passed, %d failed (source byte-identical)" % (p2, f2))
    if f2 != 0 or p2 != p:
        print("RESULT: the bar is not green again after restore.")
        return 1
    if unapplied:
        print("RESULT: %d mutation(s) did not apply; a red result would be unattributable." % len(unapplied))
        return 1
    if survived:
        print("RESULT: %d SURVIVED: %s" % (len(survived), "; ".join(survived)))
        return 1
    print("RESULT: %d killed, 0 survived, 0 unapplied." % killed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
