# #1154 mutation battery (targeted, a small logic fix): See & Spray's fertilizer check (pass 3
# of SFNozzleEffects:sfUpdateNozzleEffectState) reads the first value-map pixel ahead of the
# nozzle, through SFNozzleEffects.pass3ReadPoint. src/specializations/SFNozzleEffects.lua only;
# the rows are SF-1154-see_spray_pass3_lookahead_spec_test.lua.
#
# Each mutation removes or bends one clause of the fix and must be KILLED by a named row. For
# each: assert the edit LANDED (exact occurrence count), run the tests that load the file
# (--loads src/specializations/SFNozzleEffects.lua: 4 files, the smallest selection that sees
# it, per Tyson's standing rule), record KILLED/SURVIVED with the named rows, restore
# byte-for-byte and PROVE the restore with a hash.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_sf1154_pass3.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFN = "src/specializations/SFNozzleEffects.lua"

MUTATIONS = [
 ("M1-reads-the-credited-strip", SFN,
  [("                    if vm3 then return vm3:readValueAtWorld(key, readX, readZ) end\n",
    "                    if vm3 then return vm3:readValueAtWorld(key, probeX, probeZ) end\n", 1)],
  "pass 3 reads on the boom line again, where the pass has just credited (#1154 as reported)"),

 ("M2-no-margin", SFN,
  [("SFNozzleEffects.PASS3_CENTRE_MARGIN = 0.25\n", "SFNozzleEffects.PASS3_CENTRE_MARGIN = 0\n", 1)],
  "any pixel centre ahead of the nozzle is taken, even one the credited line (the work-area "
  "nodes, a little ahead of the nozzles) has already passed"),

 ("M3-the-neighbour-judges", SFN,
  [("                if aheadFarm ~= nozzleFarmId then readX = nil end\n", "", 1)],
  "at the end of a field the nozzle is judged by the neighbour's ground ahead and closes early"),

 ("M4-no-heading-reads-the-boom", SFN,
  [("    if len < 1e-6 then return nil end\n", "    if len < 1e-6 then return probeX, probeZ end\n", 1)],
  "with no heading the check falls back to the credited strip instead of making no decision"),

 ("M5-pixel-grid-ignored", SFN,
  [("    if type(grain) ~= \"number\" or grain <= 0 or type(terrain) ~= \"number\" or terrain <= 0 then\n",
    "    if true then\n", 1)],
  "a flat 1 m ahead regardless of the pixels, which can land in a pixel the credited line has passed"),

 ("M6-leads-a-pixel-more", SFN,
  [("    local d = grain * 0.5\n", "    local d = grain * 1.5\n", 1)],
  "the decision leads the boom by a pixel more than it has to, so a full patch is skipped too early"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs", "--loads", SFN], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green (--loads %s)" % SFN)

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
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
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:8]:
        print("        " + l[:140])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
