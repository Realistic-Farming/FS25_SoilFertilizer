"""Mutation battery for MAINTENANCE row 343 (#1174): the nozzle path reads the engine weed map.

One selection only: the entry-point bar MAINT-343-see_spray_herbicide_engine_weed_spec_test.lua,
through a filtered copy of run-tests.mjs written beside the runner and deleted in `finally`
(targeted runs only). One mutant at a time, in the foreground. Each mutation
is proved to have landed (the anchor occurs exactly once and the file changed) and src is
restored by hash after every mutant and in `finally`.
"""
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "src", "specializations", "SFNozzleEffects.lua")
BAR = "MAINT-343-see_spray_herbicide_engine_weed_spec_test.lua"
RUNNER = os.path.join(HERE, "run-tests.mjs")
SEL = os.path.join(HERE, "run-mut-343.mjs")
ANCHOR = "let testFiles = allTestFiles;"

# (name, anchor text in src, replacement) - anchors are single-line fragments, line-ending safe
MUTANTS = [
    ("M1 zero state counts as a target",
     "if engineState > 0 and engineState < ssCfg.WEED_STATE_WITHERED_FROM then",
     "if engineState >= 0 and engineState < ssCfg.WEED_STATE_WITHERED_FROM then"),
    ("M2 withered states count as targets (upper bound dropped)",
     "if engineState > 0 and engineState < ssCfg.WEED_STATE_WITHERED_FROM then",
     "if engineState > 0 then"),
    ("M3 boundary moved up (7 is a target)",
     "engineState < ssCfg.WEED_STATE_WITHERED_FROM then return true, 1 end",
     "engineState <= ssCfg.WEED_STATE_WITHERED_FROM then return true, 1 end"),
    ("M4 boundary moved down (6 is gone)",
     "engineState < ssCfg.WEED_STATE_WITHERED_FROM then return true, 1 end",
     "engineState < ssCfg.WEED_STATE_WITHERED_FROM - 1 then return true, 1 end"),
    ("M5 weed-layer check dropped (no layer trusted)",
     "if not okLayer or hasLayer ~= true then return nil end",
     "if not okLayer then return nil end"),
    ("M6 engine read always unavailable (the old behaviour)",
     "if weedSystem == nil or type(x) ~= \"number\" or type(z) ~= \"number\" then return nil end",
     "if true then return nil end"),
    ("M7 unreadable state accepted (-1 is a reading)",
     "if not okState or type(state) ~= \"number\" or state < 0 then return nil end",
     "if not okState or type(state) ~= \"number\" then return nil end"),
    ("M8 fallback ignores pressure (always a target)",
     "            if weedVal >= ssCfg.WEED_THRESHOLD",
     "            if true or weedVal >= ssCfg.WEED_THRESHOLD"),
    ("M9 engine branch mislabelled in the log",
     "effectData.ssWeedRead = \"engine\"",
     "effectData.ssWeedRead = \"pressure\""),
    ("M10 log drops the reading",
     "local weedRead = effects[1] and effects[1].ssWeedRead or \"n/a\"",
     "local weedRead = \"n/a\""),
    ("M11 log line removed",
     "SoilLogger.info(\"See & Spray closed every nozzle on vehicle %s: %s (weed reading: %s)\",",
     "local _ = (\"See & Spray closed every nozzle on vehicle %s: %s (weed reading: %s)\"):format("),
    ("M13 log gap dropped (a flapping boom would fill the log)",
     "if spec._ssLogAt == nil or now - spec._ssLogAt >= SFNozzleEffects.SS_MESSAGE_GAP_MS then",
     "if true then"),
    ("M12 engine weed system presence not checked",
     "if weedSystem == nil or type(x) ~= \"number\" or type(z) ~= \"number\" then return nil end",
     "if type(x) ~= \"number\" or type(z) ~= \"number\" then return nil end"),
]


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def run_bar():
    r = subprocess.run(["node", "run-mut-343.mjs"], cwd=HERE, capture_output=True, text=True, timeout=110)
    out = (r.stdout or "") + (r.stderr or "")
    tail = [ln for ln in out.splitlines() if ln.strip()][-1:] or [""]
    return r.returncode, tail[0]


def main():
    base_hash = sha(SRC)
    original = open(SRC, "rb").read()
    text = original.decode("utf-8")
    src_runner = open(RUNNER, encoding="utf-8").read()
    assert src_runner.count(ANCHOR) == 1, "runner anchor missing"
    open(SEL, "w", encoding="utf-8", newline="\n").write(
        src_runner.replace(ANCHOR, 'let testFiles = allTestFiles.filter((f) => f === "%s");' % BAR))
    killed, survived = [], []
    try:
        rc, tail = run_bar()
        print("BASE   rc=%d  %s" % (rc, tail))
        assert rc == 0, "the bar is not green on the head; no battery"
        for name, old, new in MUTANTS:
            assert text.count(old) == 1, "%s: anchor found %d times" % (name, text.count(old))
            mutated = text.replace(old, new)
            assert mutated != text, "%s: mutation did not change the file" % name
            open(SRC, "wb").write(mutated.encode("utf-8"))
            landed = sha(SRC) != base_hash
            rc, tail = run_bar()
            open(SRC, "wb").write(original)
            assert sha(SRC) == base_hash, "restore failed after %s" % name
            verdict = "KILLED  " if rc != 0 else "SURVIVED"
            (killed if rc != 0 else survived).append(name)
            print("%s %s  landed=%s  %s" % (verdict, name, landed, tail))
    finally:
        open(SRC, "wb").write(original)
        if os.path.exists(SEL):
            os.remove(SEL)
        print("restored src hash matches base: %s" % (sha(SRC) == base_hash))
    print("killed %d, survived %d of %d" % (len(killed), len(survived), len(MUTANTS)))
    for s in survived:
        print("  SURVIVOR:", s)
    sys.exit(1 if survived else 0)


main()
