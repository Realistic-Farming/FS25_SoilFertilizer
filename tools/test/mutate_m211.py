# SoilFertilizer MAINTENANCE row 211 mutation battery: a witness refusal names its field when the witness read
# exactly one (a farmland, no MIXED_FIELD), and the crop only for one supported crop (src/target/TargetApplication.lua,
# refusalIdentity and the witness refusal). Rows live in MAINT-211-refusal_fieldid_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/target/TargetApplication.lua` (9 files): this bar, the SF-73 entry, W1a, W1b and
# event benches, and the main.lua loaders. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - refusalIdentity's table check on its argument: the witness always returns a table;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_m211.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_m211.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_m211.py --baseline the selected benches, unmutated
#        py tools/test/mutate_m211.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

TA = "src/target/TargetApplication.lua"
SELECT = ["--loads", "src/target/TargetApplication.lua"]

MUTATIONS = [
 ("R01-refusal-names-nothing", TA,
  [("        return refusedPlan(fillTypeIndex, verdict.state, verdict.reasons, { clearAnchor = true, geometry = geometry,\n"
    "            fieldId = fieldId, fruitIndex = fruitIndex, cropKey = cropKey })\n",
    "        return refusedPlan(fillTypeIndex, verdict.state, verdict.reasons, { clearAnchor = true, geometry = geometry })\n", 1)],
  "the refusal drops what the witness resolved (G1, G4, G6)"),
 ("R02-mixed-field-named", TA,
  [('    if type(verdict.farmlandId) == "number" and verdict.farmlandId > 0 and not has.MIXED_FIELD then\n',
    '    if type(verdict.farmlandId) == "number" and verdict.farmlandId > 0 then\n', 1)],
  "a boom across two fields names the first (G2, T2)"),
 ("R03-farmland-zero-named", TA,
  [('    if type(verdict.farmlandId) == "number" and verdict.farmlandId > 0 and not has.MIXED_FIELD then\n',
    '    if type(verdict.farmlandId) == "number" and not has.MIXED_FIELD then\n', 1)],
  "farmland 0 is named as a field (T7)"),
 ("R04-unsupported-crop-named", TA,
  [("    if fieldId == nil or verdict.cropKey == nil or has.MIXED_CROP or has.UNSUPPORTED_CROP then\n",
    "    if fieldId == nil or verdict.cropKey == nil or has.MIXED_CROP then\n", 1)],
  "a cut or unsupported crop is named as the target crop (G1, T3)"),
 ("R05-mixed-crop-named", TA,
  [("    if fieldId == nil or verdict.cropKey == nil or has.MIXED_CROP or has.UNSUPPORTED_CROP then\n",
    "    if fieldId == nil or verdict.cropKey == nil or has.UNSUPPORTED_CROP then\n", 1)],
  "a crop boundary names one of its crops (G4, T4)"),
 ("R06-crop-without-field", TA,
  [("    if fieldId == nil or verdict.cropKey == nil or has.MIXED_CROP or has.UNSUPPORTED_CROP then\n",
    "    if verdict.cropKey == nil or has.MIXED_CROP or has.UNSUPPORTED_CROP then\n", 1)],
  "a crop is named with no field (T6)"),
 ("R07-crop-without-key", TA,
  [("    if fieldId == nil or verdict.cropKey == nil or has.MIXED_CROP or has.UNSUPPORTED_CROP then\n",
    "    if fieldId == nil or has.MIXED_CROP or has.UNSUPPORTED_CROP then\n", 1)],
  "a fruit with no crop key is named by index (T5)"),
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
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:28s} {rel}  {why}")
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
        rc, _, out = run_bench()
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
        rc, fails, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertionFails = [f for f in fails if "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:3]: print("    " + f[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
