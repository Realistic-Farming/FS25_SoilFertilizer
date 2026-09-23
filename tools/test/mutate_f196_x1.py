#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F196 X1 price completeness: does the bar catch the versions that would ship it wrong?

Five mutants, and each must send RSF-F196-x1_price_completeness_test.lua RED:

  M1  price completeness dropped from     completion goes true with an unpriced
      the predicate                       eligible product (group C).
  M2  blends counted as eligible          every blend resolves with no price, so
                                          every load times out (A6/A15).
  M3  rebuild only at install             registration never rebuilds the map; the
                                          late product never gets a price (A3/A8).
  M4  the map built in place              the readers can observe a partial map; the
                                          old table gains the late product (A11/A12).
  M5  a refused product priced            AN, refused by R1a, appears in the map (B2).

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_f196_x1.py
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
HM = os.path.join(ROOT, "src", "hooks", "HookManager.lua")
BAR = "RSF-F196-x1_price_completeness_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

PREDICATE = "    self._sprayTypesComplete = (skipped == 0) and priceComplete\n"
ELIGIBLE = "            if price ~= nil then\n                local ok, idx = pcall(function() return fm:getFillTypeIndexByName(name) end)\n"
REBUILD_CALL = "    local priceComplete = self:rebuildCustomPriceMap()\n"
FRESH_MAP = "    local map, complete = {}, true\n"
REFUSED_GATE = "                if ok and idx and idx > 0 and self.refusedProducts[idx] == nil then\n"

MUTATIONS = [
    ("M1 price completeness dropped from the predicate",
     [(PREDICATE, "    self._sprayTypesComplete = (skipped == 0)\n", 1)]),
    ("M2 blends counted as eligible",
     [(ELIGIBLE, "            if true then\n                local ok, idx = pcall(function() return fm:getFillTypeIndexByName(name) end)\n", 1)]),
    ("M3 rebuild only at install", [(REBUILD_CALL, "    local priceComplete = true\n", 1)]),
    ("M4 the map built in place", [(FRESH_MAP, "    local map, complete = self.customFillTypePrices or {}, true\n", 1)]),
    ("M5 a refused product priced",
     [(REFUSED_GATE, "                if ok and idx and idx > 0 then\n", 1)]),
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
    base_src, base = read(HM), digest(HM)
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
            print("  %-48s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(HM, HM + ".bak")
        try:
            write(HM, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(HM + ".bak", HM)
            os.remove(HM + ".bak")
        if mf is None:
            print("  %-48s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-48s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-48s SURVIVED" % name)

    if digest(HM) != base:
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
