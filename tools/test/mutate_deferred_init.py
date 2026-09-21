#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Deferred fill-type init: does the new bar actually catch the old behaviour?

Four mutants, each restoring ONE real property of the code that shipped before this
PR rather than an arbitrary edit:

  M1  reapplyFillUnitPatch iterates `self._fuSolidNames or {}` again, with the nil
      guard removed. Restores "zero names CHECKED reported as zero names FOUND".
  M2  the isMissionStarted gate is removed, so the budget is spent during load
      again. Restores the give-up that fired 89 seconds before gameplay began.
  M3  the warning text goes back to volunteering "dedicated server or modded map
      may have incomplete fill type loading". Restores the invented diagnosis.
  M4  completion keys only on _sprayTypesComplete and ignores the re-patch result,
      which is exactly what the old loop tested.

Each mutant must be applied (asserted by a changed file), must send the bar red,
and the file must come back byte-identical afterwards. A mutation that fails to
apply aborts rather than reporting a survivor, because a no-op edit and an
unpinned rule look identical from the outside.

Run from tools/test:  py mutate_deferred_init.py
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
MGR = os.path.join(ROOT, "src", "SoilFertilityManager.lua")
HOOK = os.path.join(ROOT, "src", "hooks", "HookManager.lua")
BAR = "SF-deferred_init_reporting_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

OLD_WARNING = ('"[DeferredInit] Fill types still unavailable after 120 retries - '
               'dedicated server or modded map may have incomplete fill type loading"')


def read(p):
    with io.open(p, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def write(p, s):
    with io.open(p, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def digest(p):
    return hashlib.sha256(read(p).encode("utf-8")).hexdigest()[:12]


def run_bar():
    proc = subprocess.run(["node", "run-tests.mjs"], cwd=HERE,
                          capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    m = BAR_RE.search(out)
    if not m:
        return None, None, out.strip()[-600:]
    return int(m.group(1)), int(m.group(2)), ""


def m1(mgr, hook):
    """Restore `or {}` and drop the nil guard."""
    guard = re.search(
        r"    if self\._fuSolidNames == nil then\r?\n.*?\r?\n    end\r?\n\r?\n",
        hook, re.DOTALL)
    if not guard:
        return None, None
    hook2 = hook.replace(guard.group(0), "", 1)
    hook2 = hook2.replace("for _, name in ipairs(self._fuSolidNames) do",
                          "for _, name in ipairs(self._fuSolidNames or {}) do", 1)
    return mgr, hook2


def m2(mgr, hook):
    """Remove the mission-started gate."""
    needle = "    if g_currentMission == nil or g_currentMission.isMissionStarted ~= true then return end"
    if needle not in mgr:
        return None, None
    return mgr.replace(needle, "", 1), hook


def m3(mgr, hook):
    """Put the invented diagnosis back."""
    m = re.search(r'SoilLogger\.warning\(\r?\n\s+"\[DeferredInit\] Gave up[^"]*",', mgr)
    if not m:
        return None, None
    return mgr.replace(m.group(0), "SoilLogger.warning(" + OLD_WARNING + ",", 1), hook


def m4(mgr, hook):
    """Completion ignores the re-patch result, as the old loop did."""
    needle = "if hm._sprayTypesComplete and fillUnitsPatched then"
    if needle not in mgr:
        return None, None
    return mgr.replace(needle, "if hm._sprayTypesComplete then", 1), hook


def m5(mgr, hook):
    """One-shot log guards never latch, so warnings repeat every tick.

    Models the state this PR would have shipped without Bob's MAJOR: the retry now
    runs every frame instead of once per load, so an unlatched guard is thousands
    of identical lines burying the give-up diagnostics.
    """
    flags = ["_loggedFuNoFillTypeManager", "_loggedFuAllMissing",
             "_loggedFuNoVehicles", "_loggedFuHookPending"]
    out, changed = hook, 0
    for f in flags:
        needle = "self.%s = true" % f
        if needle in out:
            out = out.replace(needle, "self.%s = false" % f, 1)
            changed += 1
    if changed != len(flags):
        return None, None
    return mgr, out


MUTANTS = [
    ("M1 reapplyFillUnitPatch iterates `_fuSolidNames or {}` again", m1),
    ("M2 budget is spent during load (no isMissionStarted gate)", m2),
    ("M3 warning invents 'dedicated server or modded map'", m3),
    ("M4 completion ignores the fill unit re-patch result", m4),
    ("M5 one-shot log guards never latch, warnings repeat per tick", m5),
]


def main():
    base_mgr, base_hook = read(MGR), read(HOOK)
    base = (digest(MGR), digest(HOOK))

    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, fn in MUTANTS:
        new_mgr, new_hook = fn(base_mgr, base_hook)
        if new_mgr is None:
            unapplied.append(name)
            print("  %-58s MUTATION DID NOT APPLY" % name)
            continue
        if (new_mgr == base_mgr) and (new_hook == base_hook):
            unapplied.append(name)
            print("  %-58s NO-OP EDIT" % name)
            continue

        shutil.copyfile(MGR, MGR + ".bak")
        shutil.copyfile(HOOK, HOOK + ".bak")
        try:
            write(MGR, new_mgr)
            write(HOOK, new_hook)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(MGR + ".bak", MGR)
            shutil.copyfile(HOOK + ".bak", HOOK)
            os.remove(MGR + ".bak")
            os.remove(HOOK + ".bak")

        if mf is None:
            print("  %-58s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-58s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-58s SURVIVED" % name)

    if base != (digest(MGR), digest(HOOK)):
        print("\nRESULT: restore FAILED, the tree is not byte-identical. Fix before trusting anything above.")
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
