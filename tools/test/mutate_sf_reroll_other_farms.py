#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SoilRerollUnownedFields keeps every farm's soil: does the bar catch the wrong fixes?

Eight mutants, each a plausible way to get the ownership rule wrong, and each must send
SF-reroll_other_farms_spec_test.lua RED:

  M1  the old rule: keep only the caller's farm     farms 2..n are re-rolled again.
  M2  "owner > 0" in place of "owner == 0"          a nil owner fails OPEN (re-rolled).
  M3  the pcall dropped                             one raising getter aborts the run.
  M4  the missing-manager abort dropped             no manager re-rolls (or crashes).
  M5  the NPC skip dropped                          NPC reservoir ground is re-rolled.
  M6  the NPC lookup not guarded                    a raising bridge aborts the run.
  M7  the abort reported as 0, 0                    the console says "saved" and saves.
  M8  the broadcast dropped                         joined clients keep the old values.

Selection: the bar is run with --loads src/settings/SoilSettingsGUI.lua (it loads both
files), which keeps each run short. A stale .bak next to a source means an earlier run
was killed mid-mutant; the script refuses to start until it is restored by hand.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_sf_reroll_other_farms.py
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
GUI = os.path.join(ROOT, "src", "settings", "SoilSettingsGUI.lua")
BAR = "SF-reroll_other_farms_spec_test.lua"
SELECT = ["--loads", "src/settings/SoilSettingsGUI.lua"]
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

KEEP = "            if not ok or owner ~= noOwner then\n"
PCALL = "            local ok, owner = pcall(fm.getFarmlandOwner, fm, fieldId)\n"
GUARD = ("    if fm == nil or type(fm.getFarmlandOwner) ~= \"function\" then\n"
         "        SoilLogger.warning(\"rerollUnownedFields: farmland manager unavailable - aborting to protect owned fields\")\n"
         "        return nil, \"the farmland manager is not available\"\n"
         "    end\n")
NPC = "            elseif NpcSoilBridge and NpcSoilBridge:isNPCManaged(fieldId) == true then\n"

MUTATIONS = [
    ("M1 keep only the caller's farm", SFS,
     [(KEEP, "            if ok and owner == (g_currentMission and g_currentMission:getFarmId()) then\n", 1)]),
    ("M2 owner > 0 (nil fails open)", SFS,
     [(KEEP, "            if ok and type(owner) == \"number\" and owner > 0 then\n", 1)]),
    ("M3 the pcall dropped", SFS,
     [(PCALL, "            local ok, owner = true, fm:getFarmlandOwner(fieldId)\n", 1)]),
    ("M4 the missing-manager abort dropped", SFS, [(GUARD, "", 1)]),
    ("M5 the NPC skip dropped", SFS,
     [("            elseif rerollKeepsNpcGround(fieldId) then\n", "            elseif false then\n", 1)]),
    ("M6 the NPC lookup not guarded", SFS,
     [("    local ok, isNpc = pcall(NpcSoilBridge.isNPCManaged, NpcSoilBridge, fieldId)\n",
       "    local ok, isNpc = true, NpcSoilBridge:isNPCManaged(fieldId)\n", 1)]),
    ("M7 the abort reported as 0, 0", SFS,
     [("        return nil, \"the farmland manager is not available\"\n", "        return 0, 0\n", 1)]),
    ("M8 the broadcast dropped", GUI,
     [("        soilSystem:broadcastAllFieldData()\n", "", 1)]),
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
    files = [SFS, GUI]
    stale = [f + ".bak" for f in files if os.path.exists(f + ".bak")]
    if stale:
        print("ABORT: a stale backup exists (an earlier run was killed mid-mutant): %s\n"
              "Restore the source from it (or from git) and delete it first." % ", ".join(stale))
        return 1
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
