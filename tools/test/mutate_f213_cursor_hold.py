# RSF-F213 part 1 (the wetness cursor hold) mutation battery. Each mutant must send
# RSF-F213-wetness_cursor_hold_test.lua RED by a named row. Every edit asserts it LANDED
# by exact occurrence count; restore is proved by sha256. "DID NOT APPLY" never counts.
#
# Usage (from the repo root): py tools/test/mutate_f213_cursor_hold.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MW = "src/MaterialWetness.lua"

MUTATIONS = [
 ("M1-cursor-set-to-day-unconditionally", MW,
  [("        if not self:settleOneDay(d, isToday) then\n",
    "        if not self:settleOneDay(d, isToday) and false then\n", 1),
   ("        self.appliedThroughDay = d\n    end\nend\n",
    "        self.appliedThroughDay = d\n    end\n    self.appliedThroughDay = day\nend\n", 1)],
  "the pre-fix shape: the cursor reaches the accrual day whatever was held"),
 ("M2-no-replay-from-the-cursor", MW,
  [("    if self.appliedThroughDay ~= nil and self.appliedThroughDay + 1 < firstDay then\n        firstDay = self.appliedThroughDay + 1\n    end\n", "", 1)],
  "a held day is stepped over by the next accrual's own span"),
 ("M3-hold-reports-settled", MW,
  [("            return false\n        end\n        sky = {", "            return true\n        end\n        sky = {", 1)],
  "settleOneDay reports a held day as settled"),
 ("M4-walk-continues-past-a-hold", MW,
  [("            return\n        end\n        self.appliedThroughDay = d\n",
    "        else\n        self.appliedThroughDay = d\n        end\n        if false then\n        end\n", 1)],
  "the walk skips the held day and settles later days out of order"),
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
    for l in named[:3]:
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
