# MAINTENANCE row 232 battery (targeted, a small logic fix): each section reads the ground
# under itself. Production lines in src/hooks/HookManager.lua only (sectionSamplePoints, the
# forward offset sectionLateralExtents now returns, and the three hooks' reads). The bar is
# MAINT-232-section_sample_spec_test.lua.
#
# TARGETED ONLY (Tyson's ruling, 2026-09-30): each mutant runs against the test files that
# load the bar's world, --loads tools/test/lua/MAINT-232-section_sample_world.lua, which is
# the bar alone.
#
# A mutant counts as KILLED only when the run reached its summary, failed, and every row it
# targets is among the FAIL lines. KILLED* means it failed only by a Lua error (a weak kill,
# a failure). Anything else is SURVIVED. Each run asserts the edit LANDED (exact occurrence
# count), restores byte-for-byte and PROVES the restore with a hash.
#
# Not run, and why:
# - The fallback point for a section whose ground is unknown (the boom-line centre, else the
#   root): no bar world has such a section, and before this fix that section read the root.
# - The middle-first ordering of a section's points: Smart Sensor and Variable Rate read the
#   first point, and in these worlds a section's outer points fall on the same field as its
#   centre.
# - sectionLateralGround's split into sectionLateralExtents: MAINT-229's bar and battery
#   cover it, and its lines are unchanged.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits a production file in place.
#
# Usage (from the repo root): py tools/test/mutate_maint232_section_sample.py [id-prefix ...] [--check]
#   --check only counts every anchor and runs nothing.
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
SELECT = "tools/test/lua/MAINT-232-section_sample_world.lua"
HM = "src/hooks/HookManager.lua"
OLD_SX = "(sprayerSelf._sfRootX + sprayerSelf._sfSectionTip[i][1]) * 0.5, (sprayerSelf._sfRootZ + sprayerSelf._sfSectionTip[i][2]) * 0.5"

MUTATIONS = [
 ("A1-see-spray-centre-only",
  [("                    for _, pt in ipairs(samples[i]) do\n",
    "                    for _, pt in ipairs({ samples[i][1] }) do\n", 1)],
  ["W2"], "See & Spray reads only the section's centre"),
 ("A2-see-spray-need-ignored",
  [("                            if not skipHere then\n", "                            if false then\n", 1)],
  ["W1"], "a point that needs the product no longer keeps its section spraying"),
 ("A3-see-spray-unreadable-skips",
  [("                    if readable > 0 and allSkip then\n", "                    if allSkip then\n", 1)],
  ["W3"], "a section with no readable point is switched off"),
 ("A4-see-spray-first-share",
  [("                                if fracHere ~= nil and (frac == nil or fracHere > frac) then frac = fracHere end\n",
    "                                if fracHere ~= nil and frac == nil then frac = fracHere end\n", 1)],
  ["P1"], "the graduated rate takes the first point's share, not the highest"),
 ("B1-sampler-edge-aligned",
  [("                local lat = e[1] + (k - 0.5) / n * (e[2] - e[1])\n",
    "                local lat = e[1] + (k - 1) / n * (e[2] - e[1])\n", 1)],
  ["W2"], "the points start at the section's edge instead of being centred in its parts"),
 ("B2-sampler-no-forward",
  [("                local ok, wx, _, wz = pcall(localToWorld, frame, lat, 0, f)\n",
    "                local ok, wx, _, wz = pcall(localToWorld, frame, lat, 0, 0)\n", 1)],
  ["P1"], "the points sit on the frame's origin line, not the boom line"),
 ("B3-sampler-stale-cache",
  [("    if cache and cache.t == now and cache.rx == rx and cache.rz == rz then return cache.points end\n",
    "    if cache then return cache.points end\n", 1)],
  ["C1"], "the points never follow the sprayer after the first tick"),
 ("C1-smart-sensor-halfway",
  [("                    -- line (the boom-line centre for a section with no known ground).\n                    local here = samples[i][1]\n                    local sx, sz = here.x, here.z\n",
    "                    -- line (the boom-line centre for a section with no known ground).\n                    local here = samples[i][1]\n                    local sx, sz = " + OLD_SX + "\n", 1)],
  ["S1"], "Smart Sensor reads halfway to the tip again"),
 ("C2-variable-rate-halfway",
  [("                    -- section's own centre on the boom line, not halfway to its tip.\n                    local here = samples[i][1]\n                    local sx, sz = here.x, here.z\n",
    "                    -- section's own centre on the boom line, not halfway to its tip.\n                    local here = samples[i][1]\n                    local sx, sz = " + OLD_SX + "\n", 1)],
  ["V1"], "Variable Rate reads halfway to the tip again"),
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
