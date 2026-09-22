#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F196 V12c + V13: does the bar catch the versions that would ship it wrong?

Seven mutants, each must send RSF-F196-owned_layer_test.lua RED:

  M1  the isActive guard removed              a token is minted for work that is not
                                              active, and an idle drain gets billed.
  M2  the exact-delta match dropped           any negative delta while a token is live
                                              is billed, a snap or a partial included.
  M3  the class wrapped only                  the shape that never fired: no type, no
                                              instance, native's drain reaches nothing.
  M4  the type-predecessor reuse skipped      one wrapper per vehicle instead of per
                                              type; the record count and identity change.
  M5  cleanup restores unconditionally        a later owner's replacement is clobbered.
  M6  the append clear dropped                an unused token outlives the frame.
  M7  the class slot wrapped from FillUnit    the wrapper is built around the class
      instead of the slot's own function      function for every reference, bypassing
                                              a type's composed chain (SowingMachine).

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.

Run from tools/test:  py mutate_f196_owned_layer.py
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
BAR = "RSF-F196-owned_layer_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

ACTIVE = "        if wap == nil or not sprayerSelf.isServer or wap.isActive ~= true then return nil, nil end\n"
MATCH = "    return token.fuIdx == fillUnitIndex and token.delta == fillLevelDelta and token.fillType == fillTypeIndex\n"
TYPES = "    if type(types) == \"table\" then\n        for _, typeDef in pairs(types) do\n"
INSTANCES = "    for _, vehicle in pairs(vList) do\n        if type(vehicle) == \"table\" and rawget(vehicle, funcName) ~= nil then\n            wrapSlot(vehicle, rawget(vehicle, funcName), true)\n"
REUSE = "        local wrapper = reuse and layer.typeWrappers[predecessor] or nil\n"
RESTORE = "            if ref.slot[funcName] == ref.wrapper then\n"
CLEAR = ("    Sprayer.onEndWorkAreaProcessing = Utils.appendedFunction(withPrepend, function(sprayerSelf)\n"
         "        local spec = sprayerSelf and sprayerSelf.spec_sprayer\n"
         "        local target = spec and spec.workAreaParameters and spec.workAreaParameters.sprayVehicle\n"
         "        if type(target) == \"table\" and target._sfF196DrainToken ~= nil then\n"
         "            target._sfF196DrainToken = nil\n"
         "        end\n"
         "    end)\n")
FROM_SLOT = "            wrapper = makeWrapper(predecessor)\n"

MUTATIONS = [
    ("M1 the isActive guard removed",
     [(ACTIVE, "        if wap == nil or not sprayerSelf.isServer then return nil, nil end\n", 1)]),
    ("M2 the exact-delta match dropped",
     [(MATCH, "    return token.fuIdx == fillUnitIndex and token.fillType == fillTypeIndex\n", 1)]),
    ("M3 the class wrapped only",
     [(TYPES, "    if false then\n        for _, typeDef in pairs(types) do\n", 1),
      (INSTANCES, "    for _, vehicle in pairs({}) do\n        if type(vehicle) == \"table\" and rawget(vehicle, funcName) ~= nil then\n            wrapSlot(vehicle, rawget(vehicle, funcName), true)\n", 1)]),
    ("M4 the type-predecessor reuse skipped", [(REUSE, "        local wrapper = nil\n", 1)]),
    ("M5 cleanup restores unconditionally", [(RESTORE, "            if true then\n", 1)]),
    ("M6 the append clear dropped", [(CLEAR, "    Sprayer.onEndWorkAreaProcessing = withPrepend\n", 1)]),
    ("M7 wrapped around the class function, not the slot's own",
     [(FROM_SLOT, "            wrapper = makeWrapper(rawget(class, funcName) or predecessor)\n", 1)]),
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
            print("  %-52s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(HM, HM + ".bak")
        try:
            write(HM, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(HM + ".bak", HM)
            os.remove(HM + ".bak")
        if mf is None:
            print("  %-52s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-52s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-52s SURVIVED" % name)

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
