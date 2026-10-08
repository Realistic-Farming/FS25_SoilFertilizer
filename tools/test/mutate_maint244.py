# MAINTENANCE row 244 mutation battery: Soil publishes its constants on the manager (src/main.lua, load:
# sfm.SoilConstants = SoilConstants beside the mission handle). Rows live in
# tools/test/lua/MAINT-244-constants_on_manager_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the line this PR changes. Each mutant runs only the
# tests that can reach the mutated file (run-tests.mjs --loads src/main.lua: every bench that reaches
# main.lua). Run ONE mutant per call, in the foreground, and check free memory first.
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why: comments.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint244.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint244.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint244.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint244.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MAIN = "src/main.lua"
PUBLISH = "        sfm.SoilConstants = SoilConstants\n"

MUTATIONS = [
 ("M01-not-published", MAIN, [(PUBLISH, "", 1)],
  "the constants are not published, as on development: the Tablet paints at factor 1 (E1, E2)"),
 ("M02-published-in-own-env", MAIN,
  [(PUBLISH, '        getfenv(0)["SoilConstants"] = SoilConstants\n', 1)],
  "the constants are published into Soil's own environment, which no other mod sees (E1, E2)"),
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


def run_suite(rel="src/main.lua"):
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
