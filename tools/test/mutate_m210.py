# SoilFertilizer MAINTENANCE row 210 mutation battery (#1083): the field-average yield penalty with the
# growth family locked. ZoneYield:preparePreCutContext returns the fallback context on a closed gate and
# on unavailable value maps (src/ZoneYield.lua); the cutter wrapper applies the field-average scalar on a
# non-spatial path only with nutrient cycles on, and keeps SF-14's spatial path and its freeze
# (src/hooks/HookManager.lua). Rows live in MAINT-210-yield_fallback_gate_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ZoneYield.lua --loads src/HarvestContractUnderwrite.lua` (5 files): every
# bench that loads ZoneYield, both RSF-741 underwrite benches (the cutter wrapper's other installers) and
# the main.lua loaders. The HookManager mutants use the same selection: the wrapper is reached only by a
# bench that installs the zone yield cutter hook and ticks a cutter, and those are the ones selected; a
# bench that loads HookManager for another hook cannot reach these lines. Run ONE mutant per call, in the
# foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the order of the gate and the value-map check: both return the same fallback context, so
#     swapping them is an equivalent mutant no row can tell apart;
#   - the comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_m210.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_m210.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_m210.py --baseline the selected benches, unmutated
#        py tools/test/mutate_m210.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

ZY = "src/ZoneYield.lua"
HM = "src/hooks/HookManager.lua"
SELECT = ["--loads", "src/ZoneYield.lua", "--loads", "src/HarvestContractUnderwrite.lua"]

GATE_FALLBACK = ("    if not self:isLive() then\n"
                 "        return { path = \"fallback\", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = nil, drag = nil }\n"
                 "    end\n")
MAPS_FALLBACK = ("    local vm = self:_valueMaps()\n"
                 "    if vm == nil then\n"
                 "        return { path = \"fallback\", fieldId = fieldId, fruitTypeIndex = fruitTypeIndex, scalar = nil, drag = nil }\n"
                 "    end\n")

MUTATIONS = [
 ("Z01-early-nil-gate", ZY,
  [("function ZoneYield:preparePreCutContext(cutterSelf, workArea)\n",
    "function ZoneYield:preparePreCutContext(cutterSelf, workArea)\n    if not self:isLive() then return nil end\n", 1)],
  "the old first line restored: a closed gate drops the penalty (G1, G2, G3, G4)"),
 ("Z02-gate-nil-not-fallback", ZY,
  [(GATE_FALLBACK, "    if not self:isLive() then\n        return nil\n    end\n", 1)],
  "the closed gate answers nil instead of the fallback context (G1, G2, G3)"),
 ("Z03-no-gate", ZY,
  [(GATE_FALLBACK, "", 1)],
  "the closed gate falls through into SF-14's own reads (G2)"),
 ("Z04-maps-nil", ZY,
  [(MAPS_FALLBACK, "    local vm = self:_valueMaps()\n    if vm == nil then return nil end\n", 1)],
  "unavailable value maps answer nil (G7)"),
 ("H01-no-nutrient-cycles-gate", HM,
  [("                        elseif g_SoilFertilityManager.settings.nutrientCycles then\n",
    "                        else\n", 1)],
  "the field-average scalar applies with nutrient cycles off (G6)"),
 ("H02-default-not-neutral", HM,
  [("                        local scalar = 1.0\n", "                        local scalar = 0.9\n", 1)],
  "a path with no scalar is scaled anyway (G6)"),
 ("H03-spatial-no-freeze", HM,
  [("                            soilSystem:computeYieldModifier(context.fieldId, context.fruitTypeIndex)\n"
    "                            scalar = context.scalar\n",
    "                            scalar = context.scalar\n", 1)],
  "the spatial path no longer takes the crop freeze SF-14 gave it (G5)"),
 ("H04-spatial-gated", HM,
  [("                        if context.path == \"spatial\" and type(context.scalar) == \"number\" then\n",
    "                        if context.path == \"spatial\" and type(context.scalar) == \"number\" and g_SoilFertilityManager.settings.nutrientCycles then\n", 1)],
  "nutrient cycles off also drops SF-14's spatial scalar (G6)"),
 ("H05-debug-text", HM,
  [("(yield modifier applied at the cutter)", "(yield modifier applied via hopper hook)", 1)],
  "the retired hopper hook is named again (T1)"),
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
    crashed = "Lua error" in out
    return r.returncode, fails, crashed, out


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
    # a group's error row ("ran to its end without a Lua error") is a crash, not an assertion
    assertionFails = [f for f in fails if "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:5]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
