# SF-79 AUTO rate, pH unknown: mutation battery (targeted, a small logic fix). The code under
# test is the AUTO rate path in src/SoilFertilityManager.lua: the pH term's type guard in
# calculateAutoRateIndex, its nil return for a pH-only product on an unknown pH, and the hold
# in updateAutoRates. Rows live in SF-79-autorate_ph_unknown_hold_test.lua; every other bar
# runs with it. Every mutation sits on a line this change adds or edits.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# Not run, and why:
# - dropping "type(fieldData.pH) ~= 'number'" from the nil return's condition: EQUIVALENT under
#   the shipped constants. With a known pH the pH term is only skipped when the target does not
#   exceed PH_MIN (AUTO_RATE_TARGETS.pH 6.5 against PH_MIN 5.0), so no reachable input tells the
#   two apart.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_sf79_autorate_ph_hold.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFM = "src/SoilFertilityManager.lua"

MUTATIONS = [
 ("M1-type-guard-reverted", SFM,
  [("                if profile.pH and profile.pH > 0 and type(fieldData.pH) == 'number' then\n",
    "                if profile.pH and profile.pH > 0 then\n", 1)],
  "the pH term runs on an unknown pH again: the :2062 arithmetic on nil"),
 ("M2-fallback-restored", SFM,
  [("                    -- and let the caller hold it.\n                    return nil\n",
    "                    -- and let the caller hold it.\n", 1)],
  "the 1.0 fallback returns in place of nil: an unknown pH resets the rate to 1.0x"),
 ("M3-ph-term-skipped", SFM,
  [("                if profile.pH and profile.pH > 0 and type(fieldData.pH) == 'number' then\n",
    "                if profile.pH and profile.pH > 0 and false then\n", 1)],
  "the pH term never enters: a known pH no longer sizes lime"),
 ("M4-hold-dropped", SFM,
  [("    local currentIdx = rm:getIndex(vehicle.id)\n    if newIdx == nil then\n",
    "    local currentIdx = rm:getIndex(vehicle.id)\n    if false then\n", 1)],
  "the caller no longer holds on nil: the nil index reaches setIndex and the send"),
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
    for l in named[:6]:
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
