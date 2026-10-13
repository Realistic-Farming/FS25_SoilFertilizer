# SoilFertilizer wire-format mutation battery.
#
# Scope today: the UIntN width and range guards added to the stream mock 2026-09-19.
# The mock's header comment had always listed "wrong width" among the bugs it turned
# into an assertion, while streamWriteUIntN took the bit count as `_n` and discarded
# it. A 3-bit write read back as 4 bits round-tripped perfectly clean. The guards are
# only worth having if they DETECT, and a green suite proves nothing on its own,
# because the suite was green before them too.
#
# For each mutation: assert the edit LANDED (exact occurrence count), run the suite,
# record KILLED/SURVIVED with the NAMED rows that failed, restore the file
# byte-for-byte and PROVE the restore with a hash.
#
# THE RESTORE GUARANTEE IS THE REASON THIS FILE EXISTS, not a nicety. Ad-hoc
# mutation by shell command failed to restore a production file twice in one day
# here: once because a `||` fallback meant the backup was never written, once because
# a relative `cd` landed somewhere else. Both left a mutated production file in the
# worktree. This does the restore in a `finally` and then hashes the result.
#
# A no-op edit is indistinguishable from an unpinned rule: both report SURVIVED,
# which is why the count assert is not optional.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NE = "src/network/NetworkEvents.lua"

# (id, file, [(old, new, want), ...], the wire defect it introduces)
MUTATIONS = [
 ("M1-width-drift-read-wider", NE,
  [("    self.reason  = streamReadUIntN(streamId, 3)",
    "    self.reason  = streamReadUIntN(streamId, 4)", 1)],
  "a 3-bit field is read as 4 bits, so every following field is misaligned on the wire"),

 ("M2-width-drift-write-narrower", NE,
  [("            streamWriteUIntN(streamId, run.state, 4)",
    "            streamWriteUIntN(streamId, run.state, 3)", 1)],
  "a 4-bit field is written as 3 bits while the reader still takes 4"),

 ("M3-shared-width-constant-replaced-by-a-literal", NE,
  [("    self.farmId     = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)",
    "    self.farmId     = streamReadUIntN(streamId, 8)", 1)],
  "the reader hardcodes a width the writer takes from a shared constant, so the two "
  "drift apart the day the constant changes"),

 ("M4-value-exceeds-its-declared-width", NE,
  [("    streamWriteUIntN(streamId, self.reason or 0, 3)",
    "    streamWriteUIntN(streamId, (self.reason or 0) + 8, 3)", 1)],
  "a value too large for its declared width, which the engine truncates silently so "
  "the value that arrives is not the value that was sent"),
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
    print("  %s %s" % (tag, mid))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
