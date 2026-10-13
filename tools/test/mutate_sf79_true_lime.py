#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-79 3.A isTrueLime: does the bar catch the versions that would ship it wrong?

Seven mutants, each a plausible way to get the field wrong rather than an arbitrary
edit, and each must send SF-79-is_true_lime_test.lua RED:

  M1  hardcode true            GYPSUM would claim native lime credit it never earns.
  M2  hardcode false           LIME and LIQUIDLIME would deny the credit they earn.
  M3  classify by pH sign      the burn gate's axis instead of the engine's: agrees
                               on every shipped product, so only the SYNTHETIC
                               divergence row can kill it.
  M4  the writer branches      isTrueLime becomes permission: a non-lime request
      on the field              is refused. 3.A says it is not permission.
  M5  dropped from the strip   the boom strip stops carrying it while the dot still
      request only             does, so a wide sprayer would report nothing.
  M6  dropped from the dose    the record no longer carries it, so the strip reads
      record                   false for lime.
  M7  dropped from the         the one diagnostic reader goes blind; the in-game
      milestone line           row would have nothing to look for.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_sf79_true_lime.py
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
SFS = os.path.join(ROOT, "src", "SoilFertilitySystem.lua")
PPH = os.path.join(ROOT, "src", "PositionalPH.lua")
BAR = "SF-79-is_true_lime_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

CLASSIFY = "        local isTrueLime = sprayType ~= nil and sprayType.isLime == true\n"
STRIP_FIELD = "                isTrueLime = sd.isTrueLime == true,\n"
RECORD_FIELD = (",\n                                 isTrueLime = isTrueLime }\n")
MILESTONE = ('(area=%.2fha) trueLime=%s",\n'
             "                    fieldId, fillType.name, phBuf, factor, dbgPH0, field.pH, areaInHa, tostring(isTrueLime))\n")
WRITER_ANCHOR = ("        result.reason = 'bad-request'\n"
                 "        return result\n"
                 "    end\n")

MUTATIONS = [
    ("M1 hardcode true", SFS, [(CLASSIFY, "        local isTrueLime = true\n", 1)]),
    ("M2 hardcode false", SFS, [(CLASSIFY, "        local isTrueLime = false\n", 1)]),
    ("M3 classify by pH sign", SFS,
     [(CLASSIFY, "        local isTrueLime = entry.pH ~= nil and entry.pH > 0\n", 1)]),
    ("M4 writer refuses when not true lime", PPH,
     [(WRITER_ANCHOR, WRITER_ANCHOR +
       "    if request.isTrueLime ~= true then\n"
       "        result.reason = 'not-lime'\n"
       "        return result\n"
       "    end\n", 1)]),
    ("M5 dropped from the strip request only", SFS, [(STRIP_FIELD, "", 1)]),
    ("M6 dropped from the dose record", SFS, [(RECORD_FIELD, " }\n", 1)]),
    ("M7 dropped from the milestone line", SFS,
     [(MILESTONE, '(area=%.2fha)",\n'
       "                    fieldId, fillType.name, phBuf, factor, dbgPH0, field.pH, areaInHa)\n", 1)]),
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
    """Apply each (needle, replacement, expected_count) edit; None if any count is off."""
    for needle, repl, count in edits:
        n = src.count(needle)
        if n != count:
            n2 = src.count(needle.replace("\n", "\r\n"))
            if n2 != count:
                return None, "needle found %d time(s), expected %d: %r" % (n, count, needle[:60])
            needle, repl = needle.replace("\n", "\r\n"), repl.replace("\n", "\r\n")
        src = src.replace(needle, repl, count)
    return src, ""


def main():
    bases = {p: (read(p), digest(p)) for p in (SFS, PPH)}
    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, target, edits in MUTATIONS:
        base_src = bases[target][0]
        mutated, why = apply(base_src, edits)
        if mutated is None or mutated == base_src:
            unapplied.append(name)
            print("  %-44s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(target, target + ".bak")
        try:
            write(target, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(target + ".bak", target)
            os.remove(target + ".bak")
        if mf is None:
            print("  %-44s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-44s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-44s SURVIVED" % name)

    for path, (_, d) in bases.items():
        if digest(path) != d:
            print("\nRESULT: restore FAILED, %s is not byte-identical." % os.path.basename(path))
            return 1
    p2, f2, _ = run_bar()
    print("\nafter restore   : %d passed, %d failed (sources byte-identical)" % (p2, f2))
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
