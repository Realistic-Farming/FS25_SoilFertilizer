# SoilFertilizer SF-73 (c) mutation battery: a refused SF-73 cycle logs its reason, throttled
# (src/target/TargetApplication.lua: noteRefusal and its call in finishWithoutCredit). Rows
# live in SF-73-target_entry_point_test.lua, group E2b.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs
# through `node run-tests.mjs --loads src/target/TargetApplication.lua`, which selects the
# benches that load SF-73's host. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sf73c.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_sf73c.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_sf73c.py --baseline the selected benches, unmutated
#        py tools/test/mutate_sf73c.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

TA = "src/target/TargetApplication.lua"
SELECT = ["--loads", "src/target/TargetApplication.lua"]

MUTATIONS = [
 ("R01-no-throttle", TA,
  [("    if last ~= nil and last.key == key and (t - last.at) < TA.REFUSAL_LOG_MS then return false end\n", "", 1)],
  "every refused cycle logs: tens of lines a second (E2b.2)"),
 ("R02-silent", TA,
  [("    logDebug(\"[SF-73] target cycle refused: vehicle %s, field %s, product %s, state %s, reasons %s\",\n",
    "    (function() end)(\"[SF-73] target cycle refused: vehicle %s, field %s, product %s, state %s, reasons %s\",\n", 1)],
  "the refusal is noted but never logged (E2b.2, E2b.3)"),
 ("R03-no-repeat", TA,
  [("    if last ~= nil and last.key == key and (t - last.at) < TA.REFUSAL_LOG_MS then return false end\n",
    "    if last ~= nil and last.key == key then return false end\n", 1)],
  "a refusal that holds is logged once and never again (E2b.4)"),
 ("R04-refusal-not-noted", TA,
  [("    if plan.refused and not plan.nativeInactive then self:noteRefusal(st, sprayer, plan) end\n", "", 1)],
  "finishWithoutCredit never notes a refused plan (E2b.2)"),
 ("R06-native-inactive-logged", TA,
  [("    if plan.refused and not plan.nativeInactive then self:noteRefusal(st, sprayer, plan) end\n",
    "    if plan.refused then self:noteRefusal(st, sprayer, plan) end\n", 1)],
  "a switched-off machine logs \"refused ... reasons none\" every 4 s (E2b.7)"),
 ("R05-key-ignores-reason", TA,
  [("    local key = tostring(plan.state) .. \"|\" .. reasons .. \"|\" .. tostring(plan.fieldId)\n",
    "    local key = tostring(plan.state) .. \"|\" .. tostring(plan.fieldId)\n", 1)],
  "a change of reason within 4 s is not logged (E2b.5)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o, n = old.encode("utf-8"), new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_bench():
    r = subprocess.run(["node", "run-tests.mjs"] + SELECT, cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL ") or "Lua error" in l]
    crashed = "Lua error" in out or "group raised" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:30s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, _, _, out = run_bench()
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.strip().splitlines()]
        print(lines[-1] if lines else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, crashed, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertionFails = [f for f in fails if "group raised" not in f and "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
