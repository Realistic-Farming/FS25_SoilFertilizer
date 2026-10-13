# SoilFertilizer MAINTENANCE row 195 mutation battery: the ground family's mission start runs
# at the end of activateSoilSystem, after initialize() has armed the family and outside its
# pcall (src/SoilFertilityManager.lua). Rows live in group M of
# MAINT-137-overlay_save_index_stamp_spec_test.lua, which drives production's own order: the
# real onMissionStarted, the real initialize() and the real settings console command.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs
# through `node run-tests.mjs --loads src/settings/SoilSettingsGUI.lua` (5 files, a few
# seconds), which selects the bar. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the call placed inside the pcall right after initialize(): the family is armed there, so
#     the store decides just as it does at the end; a later subsystem error can no longer skip
#     a call that has already run. Equivalent on every row.
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint195.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_maint195.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_maint195.py --baseline the selected benches, unmutated
#        py tools/test/mutate_maint195.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFM = "src/SoilFertilityManager.lua"
SELECT = ["--loads", "src/settings/SoilSettingsGUI.lua"]

CALL_AT_END = ("    self:_groundMissionStarted()\n    return ok\nend\n", "    return ok\nend\n", 1)

MUTATIONS = [
 ("G1-call-deleted", SFM,
  [CALL_AT_END],
  "no mission start after the arm: the store stays PENDING and every cell reads RESTORING (M1, M2)"),
 ("G2-inside-the-pcall", SFM,
  [("            self.soilSystem:seedValueMaps()\n        end\n    end)\n",
    "            self.soilSystem:seedValueMaps()\n        end\n        self:_groundMissionStarted()\n    end)\n", 1),
   CALL_AT_END],
  "the mission start at the end of the pcall: a subsystem that raises after the arm skips it, and the hold stands (M4)"),
 ("G3-before-the-arm", SFM,
  [("        self.soilSystem:initialize()\n",
    "        self:_groundMissionStarted()\n        self.soilSystem:initialize()\n", 1),
   CALL_AT_END],
  "the mission start before initialize(): both owners are unarmed and decide nothing (M1, M2)"),
 ("G4-the-old-order", SFM,
  [("    -- [SF-73] Register the target boundary AI message on EVERY peer, here, after the\n",
    "    self:_groundMissionStarted()\n\n    -- [SF-73] Register the target boundary AI message on EVERY peer, here, after the\n", 1),
   CALL_AT_END],
  "the defect itself: onMissionStarted runs the mission start before activateSoilSystem arms the family (M1, M2)"),
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
        for mid, rel, _, why in MUTATIONS: print(f"{mid:22s} {rel}  {why}")
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
