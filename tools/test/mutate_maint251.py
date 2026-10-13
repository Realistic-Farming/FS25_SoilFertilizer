# MAINTENANCE row 251 mutation battery: Soil's Time Guard version-skew guard reads the class list through the
# instance (tg.scheduler.FLOW_CLASSES) at all three sites: src/EstablishmentFailure.lua, src/GrowthCredit.lua,
# src/ViabilityMask.lua (registerDailyAccrual). Rows live in
# tools/test/lua/MAINT-251-timeguard_skew_guard_entry_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes. Each mutant runs only the
# tests that can reach the mutated file (run-tests.mjs --loads <that file>). Run ONE mutant per call, in the
# foreground, and check free memory first.
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why: comments; SF-53's fixture change (a bench file, not code under test).
#
# Usage (from the repo root):
#        py tools/test/mutate_maint251.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint251.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint251.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint251.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

EF = "src/EstablishmentFailure.lua"
GC = "src/GrowthCredit.lua"
VM = "src/ViabilityMask.lua"
READ_D = '    local fc = type(tg.scheduler) == "table" and tg.scheduler.FLOW_CLASSES or nil\n'
READ_S = "    local fc = type(tg.scheduler) == 'table' and tg.scheduler.FLOW_CLASSES or nil\n"
TEST_D = '    if type(fc) == "table" and fc.simulation ~= true then\n'
TEST_S = "    if type(fc) == 'table' and fc.simulation ~= true then\n"

MUTATIONS = [
 ("M01-ef-bare-global", EF,
  [(READ_D, "    local fc = TimeGuardScheduler ~= nil and TimeGuardScheduler.FLOW_CLASSES or nil\n", 1)],
  "establishment reads the bare global again, which Soil's environment never has: v1.0.0.0 registers (E2)"),
 ("M02-ef-inverted", EF,
  [(TEST_D, '    if type(fc) == "table" and fc.simulation == true then\n', 1)],
  "establishment refuses a current Time Guard and accepts v1.0.0.0 (E1, E2)"),
 ("M03-ef-not-nil-safe", EF,
  [(READ_D, "    local fc = tg.scheduler.FLOW_CLASSES\n", 1)],
  "establishment indexes a missing scheduler: activation raises (E3)"),
 ("M04-gc-old-field", GC,
  [(READ_S, "    local fc = tg.flowClasses\n", 1)],
  "growth credit reads the field Time Guard never publishes, as before: v1.0.0.0 registers (E2)"),
 ("M05-gc-inverted", GC,
  [(TEST_S, "    if type(fc) == 'table' and fc.simulation == true then\n", 1)],
  "growth credit refuses a current Time Guard and accepts v1.0.0.0 (E1, E2)"),
 ("M06-gc-not-nil-safe", GC,
  [(READ_S, "    local fc = tg.scheduler.FLOW_CLASSES\n", 1)],
  "growth credit indexes a missing scheduler: activation raises (E3)"),
 ("M07-vm-old-field", VM,
  [(READ_S, "    local fc = tg.flowClasses\n", 1)],
  "the viability mask reads the field Time Guard never publishes, as before: v1.0.0.0 registers (E2)"),
 ("M08-vm-inverted", VM,
  [(TEST_S, "    if type(fc) == 'table' and fc.simulation == true then\n", 1)],
  "the viability mask refuses a current Time Guard and accepts v1.0.0.0 (E1, E2)"),
 ("M09-vm-not-nil-safe", VM,
  [(READ_S, "    local fc = tg.scheduler.FLOW_CLASSES\n", 1)],
  "the viability mask indexes a missing scheduler: activation raises (E3)"),
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


def run_suite(rel=EF):
    r = subprocess.run(["node", "run-tests.mjs", "--loads", rel], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
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
        rc, fails, _ = run_suite(rel)
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
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
