# MAINTENANCE row 229 battery (targeted, a small logic fix): a switched-off section does not
# stamp. Production lines in src/hooks/HookManager.lua only (cellsToStamp,
# _switchedOffGround, sectionLateralGround and the two counted stamp call sites). The bar is
# MAINT-229-section_stamp_spec_test.lua.
#
# TARGETED ONLY (Tyson's ruling, 2026-09-30): each mutant runs against the test files that
# load the bar's world, --loads tools/test/lua/MAINT-229-section_boom_world.lua, which is the
# bar alone. The other benches that reach the stamp ran green once with the fix and are not
# rerun per mutant.
#
# A mutant counts as KILLED only when the run reached its summary, failed, and every row it
# targets is among the FAIL lines. KILLED* means it failed only by a Lua error (a weak kill,
# a failure). Anything else is SURVIVED. Each run asserts the edit LANDED (exact occurrence
# count), restores byte-for-byte and PROVES the restore with a hash.
#
# Not run, and why:
# - The two overlay-only stamp sites (the `true` calls). They run only on a pass whose own
#   sections do not govern it, where cellsToStamp returns its input unchanged; reverting
#   the wrap there is equivalent unless an attached implement's sections govern while the
#   vehicle's do not, which no bar world builds.
# - fromObj's `if g == nil then return false end`. It differs only on a rig with two
#   sectioned objects, one fully on; no bar world builds one.
# - `if not anyOff then return nil end`. Equivalent: a boom with every section on yields
#   no off piece and returns nil a few lines below.
# - The centre half as a side section's inner edge. Equivalent wherever the centre section
#   is on (its own ground is subtracted) and wherever both are off (merged into one piece).
# - workAreaInPass inside the per-section ground, and `math.abs(a.t) > 0`: no bar world has
#   a per-section work area for another spray type, or a centre tip on the centre line.
# - The defensive guards (frame fallback, pcall results): no engine state reaches them.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits a production file in place.
#
# Usage (from the repo root): py tools/test/mutate_maint229_section_stamp.py [id-prefix ...] [--check]
#   --check only counts every anchor and runs nothing.
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
SELECT = "tools/test/lua/MAINT-229-section_boom_world.lua"
HM = "src/hooks/HookManager.lua"

DEFECT = ["A1", "A2", "A3", "A6b", "W1", "W2"]

MUTATIONS = [
 ("S1-primary-stamp-unfiltered",
  [("                    if hasVWW and boomPts then\n                        soilSys:markBoomCells(fieldId, hookMgrRef:cellsToStamp(self, boomPts), false, self)\n",
    "                    if hasVWW and boomPts then\n                        soilSys:markBoomCells(fieldId, boomPts, false, self)\n", 1)],
  DEFECT, "the primary counted stamp walks the whole sweep again"),
 ("S2-replay-stamp-unfiltered",
  [("                                                            soilSys:markBoomCells(fieldId, hookMgrRef:cellsToStamp(self, boomPts), false, self)\n",
    "                                                            soilSys:markBoomCells(fieldId, boomPts, false, self)\n", 1)],
  ["M1"], "the multi-tank replay's counted stamp walks the whole sweep again"),
 ("G1-saved-state-ignored",
  [("        local s = saved and saved[i]\n", "        local s = nil\n", 1)],
  ["B1"], "a section Soil switched off this tick counts as off (Option A, not B)"),
 ("G2-no-subtraction",
  [("    for _, on in ipairs(ons) do\n", "    for _, on in ipairs({}) do\n", 1)],
  ["W2"], "ground a sprayed section also covers is left out"),
 ("G3-no-merge",
  [("        if piece[1] <= last[2] then\n", "        if false then\n", 1)],
  ["A1", "A3", "W1"], "neighbouring switched-off sections stay separate pieces"),
 ("L1-work-area-ground-ignored",
  [("            if i ~= nil and sections[i] ~= nil and HookManager.workAreaInPass(wa, activeSprayType) then\n",
    "            if false then\n", 1)],
  ["W1", "W2"], "a work area tied to a section (#sectionIndex) gives it no ground"),
 ("L2-inner-edge-centre-line",
  [("                    if r < reach and r > inner then inner = r end\n",
    "                    if false then inner = r end\n", 1)],
  ["A1", "A3"], "every side section reaches from the centre line"),
 ("L3-no-outer-extension",
  [("    if outer[1] then ground[outer[1].i][2] = math.huge end\n",
    "    if false then ground[outer[1].i][2] = math.huge end\n", 1)],
  ["A2", "A3"], "nothing past the outermost tip belongs to the outermost section"),
 ("L4-one-sided",
  [("            local sign = (a.t > 0) and 1 or -1\n", "            local sign = 1\n", 1)],
  ["A1"], "every side section's ground is on the +X side"),
 ("L5-centre-ignored",
  [("        if a.centre and math.abs(a.t) > 0 then\n", "        if false then\n", 1)],
  ["A6c"], "a centre section has no ground of its own"),
 ("C1-axis-fixed",
  [("    local alongX = pts[1].z == pts[2].z\n", "    local alongX = false\n", 1)],
  ["A2"], "the sweep's axis is not read from the sweep"),
 ("C2-either-end",
  [("            if lo >= piece[1] and hi <= piece[2] then return true end\n",
    "            if lo >= piece[1] or hi <= piece[2] then return true end\n", 1)],
  ["A1"], "a stretch that only touches switched-off ground is left out"),
 ("C3-point-not-stretch",
  [("            bx, az, bz = ax + cellSize, pt.z, pt.z\n", "            bx, az, bz = ax, pt.z, pt.z\n", 1)],
  ["A1"], "a cell is judged at one point instead of its stretch of the sweep"),
 ("C4-sections-in-pass-ignored",
  [("        if not HookManager.sectionsInPass(obj, activeSprayType) then return true end\n",
    "        if not obj.spec_variableWorkWidth then return true end\n", 1)],
  ["S1"], "a pass whose spray type does not use sections is filtered by them"),
 ("C5-never-leave-out",
  [("        local leaveOut = true\n", "        local leaveOut = false\n", 1)],
  DEFECT, "nothing is ever left out"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run():
    r = subprocess.run(["node", "run-tests.mjs", "--loads", SELECT], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") and "assertions passed" not in l]
    crashes = [l for l in lines if "Lua error" in l or "group raised" in l]
    summary = any("assertions passed" in l for l in lines)
    return r.returncode, summary, fails, crashes


def main(argv):
    check = "--check" in argv
    only = [a for a in argv if not a.startswith("--")]
    path = os.path.join(ROOT, HM)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    if check:
        bad = 0
        for mid, edits, _rows, _why in MUTATIONS:
            for old, _new, want in edits:
                n = original.count(enc(old))
                print("  %-32s %s" % (mid, "ok" if n == want else "ANCHOR %dx, want %d" % (n, want)))
                bad += n != want
        return 1 if bad else 0

    rc, summary, fails, crashes = run()
    if rc != 0 or not summary:
        print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
        for l in (fails + crashes)[:10]:
            print("   " + l)
        return 2
    print("baseline green")

    killed, weak, survived, badedit = [], [], [], []
    for mid, edits, rows, why in MUTATIONS:
        if only and not any(mid.startswith(o) for o in only):
            continue
        mutated = original
        ok = True
        for old, new, want in edits:
            n = mutated.count(enc(old))
            if n != want:
                badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
                print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
                ok = False
                break
            mutated = mutated.replace(enc(old), enc(new), want)
        if not ok:
            continue
        with open(path, "wb") as f:
            f.write(mutated)
        with open(path, "rb") as f:
            landed = f.read()
        if landed == original or landed != mutated:
            with open(path, "wb") as f:
                f.write(original)
            badedit.append((mid, "edit did not land"))
            print("  !! %s: EDIT DID NOT LAND" % mid)
            continue
        try:
            rc, summary, fails, crashes = run()
        finally:
            with open(path, "wb") as f:
                f.write(original)
        with open(path, "rb") as f:
            if sha(f.read()) != sha(original):
                print("  !! %s: RESTORE FAILED, stopping" % mid)
                return 3
        hit = [r for r in rows if any(l.startswith("FAIL " + r + " ") for l in fails)]
        if rc != 0 and summary and len(hit) == len(rows):
            killed.append(mid)
            tag = "KILLED  "
        elif rc != 0 and crashes and not fails:
            weak.append(mid)
            tag = "KILLED* "
        else:
            survived.append((mid, why))
            tag = "SURVIVED"
        print("  %s %s  (%s)" % (tag, mid, why))
        print("        targets %s; failed %s" % (",".join(rows), ",".join(l.split(" ")[1] for l in fails) or "none"))
        for l in crashes[:2]:
            print("        CRASH " + l[:170])

    print("\n==== MUTATION RESULT ====")
    print("killed %d, killed* %d, survived %d, bad edit %d" % (len(killed), len(weak), len(survived), len(badedit)))
    for mid, why in survived:
        print("   SURVIVED %s: %s" % (mid, why))
    for mid, why in badedit:
        print("   BAD EDIT %s: %s" % (mid, why))
    print("HookManager.lua restored byte-identical (hash-checked per mutation)")
    return 1 if (survived or badedit or weak) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
