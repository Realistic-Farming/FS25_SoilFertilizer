# SoilFertilizer MAINTENANCE row 207 mutation battery: at a square bale's finish, the account
# StockGuard's chamber record holds is reconciled to the chamber's native level through
# BC.accountReconcileRecord, which treats the two as equal when their native images are equal
# (src/ground/BalerCollection.lua: BC.nativeFloatImage, BC.accountReconcileRecord, the call in
# aroundFinish), and #1080's MINOR (the exactParts refusal counted and logged). Rows live in
# MAINT-207-chamber_reconcile_float32_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ground/BalerCollection.lua` (7 files), which selects the bar and
# every other bench that loads the collection. Run ONE mutant per call, in the foreground,
# memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - accountReconcileRecord's own finite/negative guard: accountReconcile, which it falls back to,
#     has the same guard, and a nil image falls back to it. Equivalent.
#   - the image's guard below float32's normal range (equivalent) and at 2^128 (unreachable), and
#     "+ 0" (-0 == 0).
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint207.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_maint207.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_maint207.py --baseline the selected benches, unmutated
#        py tools/test/mutate_maint207.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BCF = "src/ground/BalerCollection.lua"
SELECT = ["--loads", "src/ground/BalerCollection.lua"]

EQ = "    if a ~= nil and a == b then return end\n"
TIE = "        if f > 0.5 or (f == 0.5 and r % 2 == 1) then r = r + 1 end\n"

MUTATIONS = [
 ("P01-the-old-reconcile", BCF,
  [("                if level ~= nil then BC.accountReconcileRecord(fromStockGuard, level) end\n",
    "                if level ~= nil then BC.accountReconcile(fromStockGuard, level) end\n", 1)],
  "the defect itself: the record reconciled by the 1e-6 tolerance; a reloaded chamber's bale is born unknown (E1, E2)"),
 ("P02-images-ignored", BCF,
  [(EQ, "", 1)],
  "the images never consulted (E1, E2)"),
 ("P03-always-equal", BCF,
  [(EQ, "    if true then return end\n", 1)],
  "the record never reconciled: a real change is carried as known (E4, E5)"),
 ("P04-a-tolerance", BCF,
  [(EQ, "    if a ~= nil and math.abs(a - b) <= 20000 then return end\n", 1)],
  "a tolerance of 0.02 L between the images: a real 0.01 L change is carried as known (E4)"),
 ("P05-ties-up", BCF,
  [(TIE, "        if f >= 0.5 then r = r + 1 end\n", 1)],
  "a tie always rounds up (G1)"),
 ("P06-ties-down", BCF,
  [(TIE, "        if f > 0.5 then r = r + 1 end\n", 1)],
  "a tie always rounds down (G1)"),
 ("P07-no-float32-step", BCF,
  [("    local y = halfEven(m)\n", "    local y = m\n", 1)],
  "the level not rounded to float32 first: a float32 readback differs from the saved litres (E1)"),
 ("P08-float32-23-bits", BCF,
  [("    while m >= 16777216 do m, e = m / 2, e + 1 end\n    while m < 8388608 do m, e = m * 2, e - 1 end\n",
    "    while m >= 8388608 do m, e = m / 2, e + 1 end\n    while m < 4194304 do m, e = m * 2, e - 1 end\n", 1)],
  "float32 taken at 23 significant bits (G1)"),
 ("P09-five-decimals", BCF,
  [("    return sign * halfEven(y * 1000000) + 0\n", "    return sign * halfEven(y * 100000) + 0\n", 1)],
  "five decimals instead of six (G1)"),
 ("P10-sign-dropped", BCF,
  [("    if x < 0 then sign, x = -1, -x end\n", "    if x < 0 then sign, x = 1, -x end\n", 1)],
  "a negative level images as its magnitude (G3)"),
 ("P11-nonfinite-is-zero", BCF,
  [("function BC.nativeFloatImage(x)\n    if not finite(x) then return nil end\n", "function BC.nativeFloatImage(x)\n    if not finite(x) then return 0 end\n", 1)],
  "a non-number or non-finite amount images to 0 (G3)"),
 ("P12-refusal-not-counted", BCF,
  [("    if not BC.exactParts(parts, A_b) then\n        BC.stats.sealRefused = BC.stats.sealRefused + 1\n", "    if not BC.exactParts(parts, A_b) then\n", 1)],
  "an exactParts refusal is not counted (M1)"),
 ("P13-refusal-not-logged", BCF,
  [("        SoilLogger.debug(\"[BalerCollection] seal refused (%s)\", \"REMAINDER\")\n", "", 1)],
  "an exactParts refusal is not logged (M1)"),
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
