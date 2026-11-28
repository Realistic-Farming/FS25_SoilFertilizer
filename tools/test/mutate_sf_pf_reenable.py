#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Precision Farming turns Soil off for the session, not the save: does the bar catch the wrong fixes?

Five mutants, each a plausible way to get the session-only rule wrong, and each must send
SF-pf_reenable_spec_test.lua RED:

  M1  saveSettings writes the live value again      the forced false reaches disk (the bug).
  M2  the PF branch assigns enabled = false         the old code path, skipping the helper.
  M3  an explicit enable does not drop the force    SoilEnable during a PF session is lost.
  M4  a second force re-remembers the choice        the remembered true becomes false.
  M5  the remembered choice is always true          a player who had it off is turned on.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_sf_pf_reenable.py
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
SETTINGS = os.path.join(ROOT, "src", "settings", "Settings.lua")
MANAGER = os.path.join(ROOT, "src", "settings", "SettingsManager.lua")
SFM = os.path.join(ROOT, "src", "SoilFertilityManager.lua")
BAR = "SF-pf_reenable_spec_test.lua"
SELECT = ["--loads", "src/settings/Settings.lua"]
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

MUTATIONS = [
    ("M1 saveSettings writes the live value", MANAGER,
     [("                if hasPersisted then value = settingsObject:getPersistedValue(def.id) end\n", "", 1)]),
    ("M2 the PF branch assigns enabled = false", SFM,
     [("                self.settings:forceOffForSession(\"precisionFarming\")\n",
       "                self.settings.enabled = false\n", 1)]),
    ("M3 an explicit enable does not drop the force", SETTINGS,
     [("        if self.enabled ~= false then\n            self._forcedOffReason, self._enabledOnDisk = nil, nil\n            return self.enabled\n        end\n", "", 1)]),
    ("M4 a second force re-remembers the choice", SETTINGS,
     [("    if self._forcedOffReason == nil then\n        self._enabledOnDisk = (self.enabled == true)\n    end\n",
       "    self._enabledOnDisk = (self.enabled == true)\n", 1)]),
    ("M5 the remembered choice is always true", SETTINGS,
     [("        self._enabledOnDisk = (self.enabled == true)\n", "        self._enabledOnDisk = true\n", 1)]),
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
    proc = subprocess.run(["node", "run-tests.mjs"] + SELECT, cwd=HERE, capture_output=True, text=True)
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
    files = [SETTINGS, MANAGER, SFM]
    base = {f: digest(f) for f in files}
    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, path, edits in MUTATIONS:
        base_src = read(path)
        mutated, why = apply(base_src, edits)
        if mutated is None or mutated == base_src:
            unapplied.append(name)
            print("  %-48s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(path, path + ".bak")
        try:
            write(path, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(path + ".bak", path)
            os.remove(path + ".bak")
        if mf is None:
            print("  %-48s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-48s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-48s SURVIVED" % name)

    if any(digest(f) != base[f] for f in files):
        print("\nRESULT: restore FAILED, a file is not byte-identical.")
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
