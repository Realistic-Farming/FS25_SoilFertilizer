#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fill type width floor: does the bar catch the versions that would ship a bug?

The entire risk of this change lives in one comparison. Four mutants, each a
plausible way to write it wrong rather than an arbitrary edit:

  M1  the guard is dropped entirely, leaving an unconditional assignment. This is
      the version that LOWERS a higher width another mod set and desyncs someone
      else's server. It is the single most important thing this bar must catch.
  M2  `>=` becomes `>`, so a width already exactly at the floor is rewritten and
      reported as a raise. A second call stops being a no-op.
  M3  the floor drops to FTE's 9, which caps at 511 and would not load the
      measured 513-fill-type setup. This is the version Tyson rejected.
  M4  the width is captured on first call instead of read live, so a later call
      decides against a number that no longer exists.
  M5  the "already satisfied" line is deleted, so a floor another mod satisfied
      is silent again. Tyson's ruling of 2026-09-22 exists because that silence
      read as a possible miss for an evening.
  M6  the already line prints the floor where the width in force belongs, so a
      log at 11 would say 10.
  M7  the raised and already lines swap.

Each must apply, must send the bar red, and the file must come back byte-identical.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_width_floor.py
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGET = os.path.join(ROOT, "src", "utils", "SoilFillTypeWidth.lua")
BAR = "SF-filltype_width_floor_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

GUARD = ("    if current >= SoilFillTypeWidth.FLOOR_BITS then\n"
         "        return false, current\n"
         "    end\n")


def read():
    with io.open(TARGET, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def write(s):
    with io.open(TARGET, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def digest():
    return hashlib.sha256(read().encode("utf-8")).hexdigest()[:12]


def run_bar():
    proc = subprocess.run(["node", "run-tests.mjs"], cwd=HERE,
                          capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    m = BAR_RE.search(out)
    if not m:
        return None, None, out.strip()[-600:]
    return int(m.group(1)), int(m.group(2)), ""


def guard_re(src):
    return re.search(
        r"    if current >= SoilFillTypeWidth\.FLOOR_BITS then\r?\n"
        r"        return false, current\r?\n"
        r"    end\r?\n", src)


def m1(src):
    """Drop the guard: unconditional assignment, lowers any higher width."""
    m = guard_re(src)
    return src.replace(m.group(0), "", 1) if m else None


def m2(src):
    """Off by one at the floor: >= becomes >."""
    needle = "if current >= SoilFillTypeWidth.FLOOR_BITS then"
    if needle not in src:
        return None
    return src.replace(needle, "if current > SoilFillTypeWidth.FLOOR_BITS then", 1)


def m3(src):
    """The floor drops to FTE's 9: caps at 511, below the measured 513."""
    needle = "SoilFillTypeWidth.FLOOR_BITS = 10"
    if needle not in src:
        return None
    return src.replace(needle, "SoilFillTypeWidth.FLOOR_BITS = 9", 1)


def m4(src):
    """Capture the width on first call instead of reading it live."""
    needle = "    local current = manager.SEND_NUM_BITS\n"
    if needle not in src:
        needle = "    local current = manager.SEND_NUM_BITS\r\n"
        if needle not in src:
            return None
    eol = "\r\n" if "\r\n" in src else "\n"
    replacement = (
        "    if SoilFillTypeWidth._capturedWidth == nil then" + eol +
        "        SoilFillTypeWidth._capturedWidth = manager.SEND_NUM_BITS" + eol +
        "    end" + eol +
        "    local current = SoilFillTypeWidth._capturedWidth" + eol)
    return src.replace(needle, replacement, 1)


def _sub(src, needle, replacement):
    """Replace exactly one occurrence, in either line ending; None if absent."""
    for n, r in ((needle, replacement),
                 (needle.replace("\n", "\r\n"), replacement.replace("\n", "\r\n"))):
        if src.count(n) == 1:
            return src.replace(n, r, 1)
    return None


ALREADY = ("    return string.format(\n"
           "        \"[SoilFertilizer] Fill type index width already %d (%d fill types) at SoilFertilizer load, floor %d satisfied. FillType Extender is not required.\",\n"
           "        width, SoilFillTypeWidth.maxFillTypes(width), SoilFillTypeWidth.FLOOR_BITS)\n")


def m5(src):
    """The already branch is deleted: a satisfied floor is silent again (the defect Tyson ruled on)."""
    return _sub(src, ALREADY, "    return nil\n")


def m6(src):
    """The already line prints the floor where the width in force belongs."""
    return _sub(src, "        width, SoilFillTypeWidth.maxFillTypes(width), SoilFillTypeWidth.FLOOR_BITS)\n",
                "        SoilFillTypeWidth.FLOOR_BITS, SoilFillTypeWidth.maxFillTypes(width), SoilFillTypeWidth.FLOOR_BITS)\n")


def m7(src):
    """The two lines swap: a raise reports 'already' and a satisfied floor reports 'raised'."""
    return _sub(src, "    if raised then\n        return string.format(\n            \"[SoilFertilizer] Fill type index width raised to",
                "    if not raised then\n        return string.format(\n            \"[SoilFertilizer] Fill type index width raised to")


MUTANTS = [
    ("M1 guard dropped: unconditional assignment lowers a higher width", m1),
    ("M2 `>=` becomes `>`: a width at the floor is rewritten", m2),
    ("M3 floor drops to 9: caps below the measured 513", m3),
    ("M4 width captured on first call instead of read live", m4),
    ("M5 the already branch is deleted: a satisfied floor is silent again", m5),
    ("M6 the already line prints the floor, not the width in force", m6),
    ("M7 the raised and already lines swap", m7),
]


def main():
    base_src = read()
    base = digest()

    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, fn in MUTANTS:
        mutated = fn(base_src)
        if mutated is None or mutated == base_src:
            unapplied.append(name)
            print("  %-56s MUTATION DID NOT APPLY" % name)
            continue
        shutil.copyfile(TARGET, TARGET + ".bak")
        try:
            write(mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(TARGET + ".bak", TARGET)
            os.remove(TARGET + ".bak")

        if mf is None:
            print("  %-56s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-56s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-56s SURVIVED" % name)

    if digest() != base:
        print("\nRESULT: restore FAILED, the file is not byte-identical.")
        return 1

    p2, f2, _ = run_bar()
    print("\nafter restore   : %d passed, %d failed (source byte-identical)" % (p2, f2))
    if f2 != 0 or p2 != p:
        print("RESULT: the bar is not green again after restore.")
        return 1
    if unapplied:
        print("RESULT: %d mutation(s) did not apply; a red result would be unattributable."
              % len(unapplied))
        return 1
    if survived:
        print("RESULT: %d SURVIVED: %s" % (len(survived), "; ".join(survived)))
        return 1
    print("RESULT: %d killed, 0 survived, 0 unapplied." % killed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
