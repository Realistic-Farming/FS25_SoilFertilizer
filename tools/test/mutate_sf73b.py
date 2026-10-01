# SoilFertilizer SF-73 (b) mutation battery: Soil's nozzle effects show spray only when the
# engine actually paints (src/specializations/SFNozzleEffects.lua: isApplying and
# sfUpdateNozzleEffectsState). Rows live in SF-73-nozzle_effects_applying_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs
# through `node run-tests.mjs --loads src/specializations/SFNozzleEffects.lua`, which
# selects the two benches that load the module. Run ONE mutant per call, in the
# foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sf73b.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_sf73b.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_sf73b.py --baseline the selected benches, unmutated
#        py tools/test/mutate_sf73b.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NZ = "src/specializations/SFNozzleEffects.lua"
SELECT = ["--loads", "src/specializations/SFNozzleEffects.lua"]

MUTATIONS = [
 ("B01-paint-not-read", NZ,
  [("        if ok and painted ~= true then return false end\n", "", 1)],
  "the engine's paint test is ignored: an unpainted pass shows spray (N1, N4)"),
 ("B02-logic-gated-on-paint", NZ,
  [("        effectData.isActive = isActive\n", "        effectData.isActive = isActive and applying\n", 1)],
  "the See & Spray decision waits for paint: the section aggregate closes on an unpainted pass (N1b)"),
 ("B03-client-not-checked", NZ,
  [("    if g_server == nil then\n        local ss = g_SoilFertilityManager", "    if false then\n        local ss = g_SoilFertilityManager", 1)],
  "a client never reads the server's target result (C3)"),
 ("B04-client-any-active", NZ,
  [("            if r ~= nil and r.active == true and (tonumber(r.plannedLitres) or 0) <= 0 then return false end\n",
    "            if r ~= nil and r.active == true then return false end\n", 1)],
  "a client goes off on any active result, a planned dose included (C4)"),
 ("B05-client-ignores-active", NZ,
  [("            if r ~= nil and r.active == true and (tonumber(r.plannedLitres) or 0) <= 0 then return false end\n",
    "            if r ~= nil and (tonumber(r.plannedLitres) or 0) <= 0 then return false end\n", 1)],
  "a client goes off on an inactive result that plans nothing (C5)"),
 ("B06-fade-on-logic", NZ,
  [("        local isShown = isActive and applying\n", "        local isShown = isActive\n", 1)],
  "the fade follows the See & Spray decision alone again (N1, N4, C3)"),
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
