"""Mutation battery for MAINTENANCE row 346: one shared weed-state boundary.

Two bars only, through a filtered copy of run-tests.mjs written beside the runner and deleted in `finally`
(targeted runs only): MAINT-346-weed_state_boundary_hook_spec_test.lua (the hook side) and
MAINT-343-see_spray_herbicide_engine_weed_spec_test.lua (the nozzle side, group W8). One mutant at a time,
in the foreground. Each mutation is proved to land (the anchor occurs once and the file changed) and every
file is restored by hash after each mutant and in `finally`.
"""
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BARS = ["MAINT-346-weed_state_boundary_hook_spec_test.lua", "MAINT-343-see_spray_herbicide_engine_weed_spec_test.lua"]
RUNNER = os.path.join(HERE, "run-tests.mjs")
SEL = os.path.join(HERE, "run-mut-346.mjs")
ANCHOR = "let testFiles = allTestFiles;"

HOOK = "src/hooks/HookManager.lua"
NOZ = "src/specializations/SFNozzleEffects.lua"
CONST = "src/config/Constants.lua"

# (name, file, anchor in the file, replacement) - anchors are single-line fragments, line-ending safe
MUTANTS = [
    ("M1 the hook goes back to its own literal 7", HOOK,
     "weedsGone = (ws == 0 or ws >= ssCfg.WEED_STATE_WITHERED_FROM)",
     "weedsGone = (ws == 0 or ws >= 7)"),
    ("M2 the nozzle path goes back to a literal 7", NOZ,
     "engineState < ssCfg.WEED_STATE_WITHERED_FROM then return true, 1 end",
     "engineState < 7 then return true, 1 end"),
    ("M3 the shipped boundary moves to 6", CONST,
     "WEED_STATE_WITHERED_FROM = 7,",
     "WEED_STATE_WITHERED_FROM = 6,"),
    ("M4 the shipped boundary moves to 8", CONST,
     "WEED_STATE_WITHERED_FROM = 7,",
     "WEED_STATE_WITHERED_FROM = 8,"),
    ("M5 the hook reads the boundary but treats state 0 as a target", HOOK,
     "weedsGone = (ws == 0 or ws >= ssCfg.WEED_STATE_WITHERED_FROM)",
     "weedsGone = (ws >= ssCfg.WEED_STATE_WITHERED_FROM)"),
]


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def run_bars():
    r = subprocess.run(["node", "run-mut-346.mjs"], cwd=HERE, capture_output=True, text=True, timeout=110)
    out = (r.stdout or "") + (r.stderr or "")
    tail = [ln for ln in out.splitlines() if ln.strip()][-1:] or [""]
    return r.returncode, tail[0]


def main():
    files = {f: os.path.join(ROOT, f) for f in {HOOK, NOZ, CONST}}
    base = {f: sha(p) for f, p in files.items()}
    orig = {f: open(p, "rb").read() for f, p in files.items()}
    src_runner = open(RUNNER, encoding="utf-8").read()
    assert src_runner.count(ANCHOR) == 1, "runner anchor missing"
    open(SEL, "w", encoding="utf-8", newline="\n").write(
        src_runner.replace(ANCHOR, "let testFiles = allTestFiles.filter((f) => %s.includes(f));" % json.dumps(BARS)))
    survived = []
    try:
        rc, tail = run_bars()
        print("BASE   rc=%d  %s" % (rc, tail))
        assert rc == 0, "the bars are not green on the head; no battery"
        for name, f, old, new in MUTANTS:
            text = orig[f].decode("utf-8")
            assert text.count(old) == 1, "%s: anchor found %d times" % (name, text.count(old))
            mutated = text.replace(old, new)
            assert mutated != text
            open(files[f], "wb").write(mutated.encode("utf-8"))
            landed = sha(files[f]) != base[f]
            rc, tail = run_bars()
            open(files[f], "wb").write(orig[f])
            assert sha(files[f]) == base[f], "restore failed after %s" % name
            print("%s %s  landed=%s  %s" % ("KILLED  " if rc != 0 else "SURVIVED", name, landed, tail))
            if rc == 0:
                survived.append(name)
    finally:
        for f, p in files.items():
            open(p, "wb").write(orig[f])
        if os.path.exists(SEL):
            os.remove(SEL)
        print("all files restored to base hash: %s" % all(sha(p) == base[f] for f, p in files.items()))
    print("killed %d, survived %d of %d" % (len(MUTANTS) - len(survived), len(survived), len(MUTANTS)))
    for s in survived:
        print("  SURVIVOR:", s)
    sys.exit(1 if survived else 0)


main()
