# MAINTENANCE row 123 mutation battery (targeted, a small logic change): the hay settle's cost
# line (src/HayBet.lua, onSettle) and the read counters it reads (src/MaterialWetness.lua,
# nativeLitres and captureSnapshot). Rows live in group M of RSF-F211-s6-readers_spec_test.lua;
# the other bars run with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the missing-clock fallback (no getTimeSec reports 0 ms): the engine always has the clock
#   (FieldCourseField.lua:471, NitrogenMap.lua:473); the fallback only keeps a clockless
#   bench from raising, and nothing observable in the game depends on it.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_maint123_settle_cost.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HB = "src/HayBet.lua"
MW = "src/MaterialWetness.lua"

MUTATIONS = [
 ("V1-volume-reads-uncounted", MW, [("    MaterialWetness.nativeReads = MaterialWetness.nativeReads + 1\n", "", 1)],
  "the native volume reads are not counted: the line says the settle read no ground"),
 ("C1-cell-reads-uncounted", MW, [("        MaterialWetness.cellReads = MaterialWetness.cellReads + 1\n", "", 1)],
  "the cell condition reads are not counted"),
 ("T1-total-in-seconds", HB, [("    local total = t0 ~= nil and (clock() - t0) * 1000 or 0\n", "    local total = t0 ~= nil and (clock() - t0) or 0\n", 1)],
  "the settle's time is reported in seconds under a milliseconds label"),
 ("F1-field-in-seconds", HB, [("        local ms = ft ~= nil and (clock() - ft) * 1000 or 0\n", "        local ms = ft ~= nil and (clock() - ft) or 0\n", 1)],
  "the costliest field's time is reported in seconds under a milliseconds label"),
 ("R1-field-reads-volume-only", HB, [("        local reads = ((MaterialWetness.nativeReads or 0) - fv) + ((MaterialWetness.cellReads or 0) - fc)\n",
                                      "        local reads = ((MaterialWetness.nativeReads or 0) - fv)\n", 1)],
  "a field's reads leave out its cell condition reads"),
 ("W1-first-field-kept", HB, [("        if worst == nil or ms > worst.ms or (ms == worst.ms and reads > worst.reads) then\n",
                               "        if worst == nil then\n", 1)],
  "the costliest field is always the first one visited"),
 ("L1-silent-on-an-empty-day", HB, [("    SoilLogger.info(\"[HayBet] settle cost:", "    if fields > 0 then SoilLogger.info(\"[HayBet] settle cost:", 1),
                                     ("worst ~= nil and worst.reads or 0, worst ~= nil and worst.ms or 0)\nend\n",
                                      "worst ~= nil and worst.reads or 0, worst ~= nil and worst.ms or 0) end\nend\n", 1)],
  "a day with nothing on the ground logs nothing, so a quiet log cannot be told from a settle that never ran"),
 ("D1-day-not-named", HB, [("        tostring(ctx ~= nil and ctx.monotonicDay or \"?\"), fields,", "        \"?\", fields,", 1)],
  "the line does not say which day it settled"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
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
print("baseline green")

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
    for l in named[:4]:
        print("        " + l[:170])
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
