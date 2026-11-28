#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""A HUD/panel that fails to initialize no longer turns the mod off: does the bar catch the wrong fixes?

Sixteen mutants, each a plausible way to get the rule wrong, and each must send
SF-hud_init_keeps_sim_spec_test.lua RED:

  M1  the failure branch disables and saves again   the old behaviour (the bug).
  M2  the failed part's field is not cleared        a half-built panel keeps drawing.
  M3  the cleanup delete is not guarded             a raising delete escapes the load.
  M4  the loop stops at the first failure           later panels never initialize.
  M5  a part dropped from the init order            that panel is never initialized.
  M6  a failed HUD is retired like a panel          auto-rate, scout, handful and the
                                                    on-foot key re-assert go with it.
  M7  enterEditMode ignores `initialized`           an invisible HUD locks the camera.
  M8  the drag key ignores `initialized`            sub-panels can enter, never leave.
  M9  the monitor's click-yield loop uses ipairs    stops at a retired harvester panel.
  M10 the fullscreen check uses ipairs              misses an open panel after a hole.
  M11 a failed menu panel is retired                Shift+O / Tuning buttons gone for good.
  M11b the tuning panel left out of the retry set   its Settings button does nothing.
  M12 saveLayout ignores `initialized`              hud.xml reset to defaults for every save.
  M13 a retired panel's collapsed state dropped     it comes back expanded next session.
  M14 toggleVisibility ignores `initialized`        J / Control Center: "shown" over nothing.
  M15 the cab strip ignores `initialized`           MasterHUD hide-all draws a bare strip.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.
A mutation that fails to apply aborts rather than reporting a survivor.

Run from tools/test:  py mutate_sf_hud_init_keeps_sim.py
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
SFM = os.path.join(ROOT, "src", "SoilFertilityManager.lua")
HUD = os.path.join(ROOT, "src", "ui", "SoilHUD.lua")
BRIDGE = os.path.join(ROOT, "src", "integrations", "SoilMasterHUDBridge.lua")
BAR = "SF-hud_init_keeps_sim_spec_test.lua"
SELECT = ["--loads", "src/SoilFertilityManager.lua"]
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

RETIRE_CALL = "                self:_retireGuiPart(key)\n"
MUTATIONS = [
    ("M1 the failure branch disables and saves", SFM,
     [(RETIRE_CALL, RETIRE_CALL + "                self.settings.enabled = false\n                self.settings:save()\n", 1)]),
    ("M2 the failed part's field is not cleared", SFM,
     [("    self[key] = nil\nend\n", "end\n", 1)]),
    ("M3 the cleanup delete is not guarded", SFM,
     [("        local ok, err = pcall(part.delete, part)\n", "        local ok, err = true, part:delete()\n", 1)]),
    ("M4 the loop stops at the first failure", SFM,
     [(RETIRE_CALL, RETIRE_CALL + "                return\n", 1)]),
    ("M5 a part dropped from the init order", SFM,
     [('    "variableRatePanel", "smartSensorPanel", "sprayerInfoPanel", "harvesterPanel",\n',
       '    "variableRatePanel", "smartSensorPanel", "sprayerInfoPanel",\n', 1)]),
    ("M6 a failed HUD is retired like a panel", SFM,
     [('            if not ok and key == "soilHUD" then\n', '            if false then\n', 1)]),
    ("M7 enterEditMode ignores initialized", HUD,
     [("    if not self.initialized then return end\n    self.editMode = true\n", "    self.editMode = true\n", 1)]),
    ("M8 the drag key ignores initialized", SFM,
     [("    if not self.soilHUD.initialized then return end\n", "", 1)]),
    ("M9 the monitor's yield loop back to ipairs", HUD,
     [("            for i = 1, 2 do\n                local panel = directPanels[i]\n",
       "            for _, panel in ipairs(directPanels) do\n", 1)]),
    ("M10 the fullscreen loop back to ipairs", BRIDGE,
     [("    for i = 1, 3 do\n        local p = panels[i]\n", "    for _, p in ipairs(panels) do\n", 1)]),
    ("M11 a failed menu panel is retired", SFM,
     [('            elseif not ok and SoilFertilityManager.GUI_RETRY_ON_OPEN[key] then\n', '            elseif false then\n', 1)]),
    ("M11b the tuning panel dropped from the retry set", SFM,
     [("{ settingsPanel = true, tuningPanel = true, cropTuningPanel = true }", "{ settingsPanel = true, cropTuningPanel = true }", 1)]),
    ("M12 saveLayout ignores initialized", HUD,
     [("    if not self.initialized then return end\n    local path = self:getLayoutPath()\n",
       "    local path = self:getLayoutPath()\n", 1)]),
    ("M13 a retired panel's collapsed state dropped", HUD,
     [('        elseif kept.varRate ~= nil then\n            xml:setBool("hudLayout.collapsed_varRate", kept.varRate)\n', "", 1)]),
    ("M14 toggleVisibility ignores initialized", HUD,
     [("    if not self.initialized then return end\n    self.visible = not self.visible\n",
       "    self.visible = not self.visible\n", 1)]),
    ("M15 the cab strip ignores initialized", BRIDGE,
     [("    if sfm.soilHUD and sfm.soilHUD.initialized and sfm.soilHUD.drawSprayerRatePanel then\n",
       "    if sfm.soilHUD and sfm.soilHUD.drawSprayerRatePanel then\n", 1)]),
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
    files = [SFM, HUD, BRIDGE]
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
