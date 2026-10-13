# SoilFertilizer MAINTENANCE row 196 mutation battery: BC.sealBatch seals every batch exactly, by
# 5d-a's exact() construction (src/ground/BalerCollection.lua, BC.exactParts and sealBatch). Rows live in
# MAINT-196-sealbatch_exact_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ground/BalerCollection.lua` (6 files), which selects the bar and
# every other bench that loads the collection. Run ONE mutant per call, in the foreground,
# memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - BC.exactParts' closing check (`s == total and last.carrierLitres >= 0` made `true`): with the
#     parts cut down to a power-of-two quantum the sum always closes and the last part is never
#     negative, so no input reaches the refusal. Equivalent on every row.
#   - the quantum one binade lower (Q = 2^(e - 41)): the running sums of its multiples stay exact
#     too. Equivalent.
#   - the cut applied to the last part as well: the last part is overwritten by the remainder
#     straight after. Equivalent.
#   - BC.exactParts' guard on a zero, negative or non-finite total: closeCall calls sealBatch only with
#     a known target above BC.EPSILON.
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint196.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_maint196.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_maint196.py --baseline the selected benches, unmutated
#        py tools/test/mutate_maint196.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BCF = "src/ground/BalerCollection.lua"
SELECT = ["--loads", "src/ground/BalerCollection.lua"]

MUTATIONS = [
 ("S1-the-old-correction", BCF,
  [("    if not BC.exactParts(parts, A_b) then return nil end\n",
    "    local sum = 0\n"
    "    for i = 1, #parts - 1 do sum = sum + parts[i].carrierLitres end\n"
    "    local last = parts[#parts]\n"
    "    last.carrierLitres = A_b - sum\n"
    "    for _ = 1, 4 do\n"
    "        local s = 0\n"
    "        for _, p in ipairs(parts) do s = s + p.carrierLitres end\n"
    "        if s == A_b then break end\n"
    "        last.carrierLitres = last.carrierLitres + (A_b - s)\n"
    "    end\n"
    "    if last.carrierLitres < 0 then return nil end\n", 1)],
  "the defect itself: the last part corrected alone, up to four times; some seals never close (E1, E2, X1, X2, X3)"),
 ("S2-no-cut", BCF,
  [("        if Q > 0 then p.carrierLitres = math.floor(p.carrierLitres / Q) * Q end\n", "", 1)],
  "the parts before the last keep their full precision: the remainder alone cannot close every sum (E1, E2, X1, X2, X3)"),
 ("S3-quantum-too-fine", BCF,
  [("    Q = Q * 2 ^ -40\n", "    Q = Q * 2 ^ -60\n", 1)],
  "a quantum below the parts' own unit cuts nothing (E1, E2, X1, X2, X3)"),
 ("S4-cut-up", BCF,
  [("        if Q > 0 then p.carrierLitres = math.floor(p.carrierLitres / Q) * Q end\n",
    "        if Q > 0 then p.carrierLitres = math.ceil(p.carrierLitres / Q) * Q end\n", 1)],
  "the parts before the last rounded up: the last part pays for material the others never held (X1)"),
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
        for mid, rel, _, why in MUTATIONS: print(f"{mid:24s} {rel}  {why}")
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
    for f in fails[:5]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
