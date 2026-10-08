# SG-3 Part 3 (Soil's half) mutation battery: YardLadder echoes the StockGuard operation open around a BIRTH,
# a REBIND and a RETIRE (src/YardLadder.lua: _openOperationId and its four call sites); ADVANCE never does.
# Rows live in tools/test/lua/SG3-3-operation_echo_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes, one mutant per defense. Targeted
# runs only (Tyson, 2026-09-30): each mutant runs SELECTED, this PR's bench, through a filtered copy of
# run-tests.mjs written beside it for the run and deleted after (the runner's own --loads selection would take in
# every bench that loads YardLadder.lua, among them RSF-F211-s6b, which does not load at development: a load error
# would read as a kill). The other YardLadder benches ran once, unmutated, as the PR's selection baseline. Run ONE
# mutant per call, in the foreground, and check free memory by hand right before each.
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error or a raised group: a weak kill.
#
# Usage (from the repo root):
#        py tools/test/mutate_sg3_3_echo.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg3_3_echo.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg3_3_echo.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_sg3_3_echo.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

YL = "src/YardLadder.lua"

SELECTED = [
    "SG3-3-operation_echo_spec_test.lua",
]
FILTER_FROM = 'const allTestFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();'
FILTER_TO = ('const allTestFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua") && '
             'process.env.MUTATE_SELECTED.split(",").includes(f)).sort();')

MUTATIONS = [
 ("M01-birth-not-echoed", YL,
  [("        if uid ~= nil then self._byUid[uid] = token end\n        return row, YardLadder.RESULT.APPLIED\n    end, YardLadder._openOperationId())\n",
    "        if uid ~= nil then self._byUid[uid] = token end\n        return row, YardLadder.RESULT.APPLIED\n    end)\n", 1)],
  "a BIRTH under an open StockGuard operation carries none, as before (E1)"),
 ("M02-rebind-out-not-echoed", YL,
  [("        self:_attach(token, nodeId, bale)\n        return r, YardLadder.RESULT.APPLIED\n    end, YardLadder._openOperationId())\n",
    "        self:_attach(token, nodeId, bale)\n        return r, YardLadder.RESULT.APPLIED\n    end)\n", 1)],
  "the REBIND out of storage carries none (R1)"),
 ("M03-rebind-in-not-echoed", YL,
  [("            self:_detach(token)\n            return r, YardLadder.RESULT.APPLIED\n        end, YardLadder._openOperationId())\n",
    "            self:_detach(token)\n            return r, YardLadder.RESULT.APPLIED\n        end)\n", 1)],
  "the REBIND into storage carries none (R1)"),
 ("M04-retire-not-echoed", YL,
  [("            remove()\n            return nil, YardLadder.RESULT.APPLIED\n        end, YardLadder._openOperationId())\n",
    "            remove()\n            return nil, YardLadder.RESULT.APPLIED\n        end)\n", 1)],
  "a RETIRE carries none (R1)"),
 ("M05-advance-echoed", YL,
  [("                commitRow(r)\n                return r, YardLadder.RESULT.APPLIED\n            end)\n",
    "                commitRow(r)\n                return r, YardLadder.RESULT.APPLIED\n            end, YardLadder._openOperationId())\n", 1)],
  "an ADVANCE carries the open operation, so SG-3 would read it as joined, not route 2 (A1)"),
 ("M06-read-unguarded", YL,
  [("    local ok, open = pcall(sg.readOpenOperation)\n",
    "    local ok, open = true, sg.readOpenOperation()\n", 1)],
  "a read that throws escapes into the change and the BIRTH is lost (G1)"),
 ("M07-any-id-accepted", YL,
  [("    if not ok or type(open) ~= \"table\" or type(open.operationId) ~= \"string\" or open.operationId == \"\" then return nil end\n",
    "    if not ok or type(open) ~= \"table\" or open.operationId == nil then return nil end\n", 1)],
  "an empty or non-string id is echoed (G1)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o = old.encode("utf-8")
        n = new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_suite():
    here = os.path.join(ROOT, "tools", "test")
    runner = open(os.path.join(here, "run-tests.mjs"), encoding="utf-8").read()
    if runner.count(FILTER_FROM) != 1:
        raise SystemExit("run-tests.mjs changed: the selection anchor is not found once")
    sel = os.path.join(here, "_mutate_selected_runner.mjs")
    with open(sel, "w", encoding="utf-8", newline="\n") as f:
        f.write(runner.replace(FILTER_FROM, FILTER_TO))
    try:
        env = dict(os.environ, MUTATE_SELECTED=",".join(SELECTED))
        r = subprocess.run(["node", "_mutate_selected_runner.mjs"], cwd=here, env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        os.remove(sel)
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "crashed" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
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
        rc, fails, out = run_suite()
        tail = [l for l in out.strip().splitlines() if l.strip()]
        print(re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)")
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
        rc, fails, _ = run_suite()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "crashed" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:12]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
