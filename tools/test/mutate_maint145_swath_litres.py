# MAINTENANCE row 145 mutation battery (targeted, a small logic change): the generic straw
# birth's landed-litres gate (src/hooks/HookManager.lua, installCombineSwathHook) and the
# observer's litres-only frame (src/ground/GroundNativeObserver.lua). Rows live in
# MAINT-145-swath_landed_litres_spec_test.lua; every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# Not run, and why:
# - the light frame on a client: the wrapper returns before the gate on a client
#   (combineSelf.isServer), and the observer refuses to install on one (:332).
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_maint145_swath_litres.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"
GO = "src/ground/GroundNativeObserver.lua"

MUTATIONS = [
 ("M1-gate-on-the-request", HM,
  [("            local droppedLiters = light ~= nil and light.litres or 0\n", "            local droppedLiters = results[1]\n", 1)],
  "the birth gates on the engine's 1/0 request flag again: a pass that landed 0 L is born"),
 ("M2-light-frame-left-open", HM,
  [("            if light ~= nil then GroundNativeObserver.close(light) end\n", "", 1)],
  "the light frame stays on the observer's stack after the call"),
 ("M3-light-branch-takes-the-full-path", GO,
  [("        if frame ~= nil and not frame.closed and frame.litresOnly and frame.owner == vehicle then\n",
    "        if false then\n", 1)],
  "a litres-only frame is served like a carrier frame (or passed through): no litres counted"),
 ("M4-negative-return-added", GO,
  [("            if lr[1] and finite(lr[2]) and lr[2] > 0 then frame.litres = (frame.litres or 0) + lr[2] end\n",
    "            if lr[1] and finite(lr[2]) then frame.litres = (frame.litres or 0) + lr[2] end\n", 1)],
  "a pickup's negative return is added to the landed litres"),
 ("M5-no-observer-falls-back-to-the-request", HM,
  [("            local droppedLiters = light ~= nil and light.litres or 0\n",
    "            local droppedLiters = light ~= nil and light.litres or results[1]\n", 1)],
  "with no observer the birth falls back to the request instead of recording nothing"),
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
