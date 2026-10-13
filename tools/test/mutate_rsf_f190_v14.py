# RSF-F190 v1.4.0.0 delta mutation battery (full: an RSF repair, R-25): every clause of
# src/LivestockWarningReader.lua, the one file the delta changes. The rows live in
# RSF-F190-livestock_warning_reader_test.lua (the record table, the provider's own 1.4
# gate, the entry-point bar through dog:update, the legacy rows and the no-throw group),
# and every other bar runs with them.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# R1 and R2 are the intake's two: isActiveRecord reverted to the v0.8 rule (must fail the
# entry-point bar), and a state-bearing record falling through to the legacy flags (must
# fail the state-wins rows).
#
# Not run, equivalent by construction, and why:
# - dropping type(state) == "string" before state == "INFECTIOUS": only a string can equal
#   a string, so the answer never changes.
# - dropping type(records) ~= "table" in the walk: ipairs on a non-table raises inside the
#   walk's own pcall, which already answers nil.
# - sick == true to a bare sick, in the walk: the walk returns only true or false.
# - dropping cs == nil or type(cs.getAnimals) ~= "function": the index or call then raises
#   inside the list read's own pcall, which already answers nil.
# - sick == true to a bare sick, in the barn loop: isAnimalActivelySick returns only true
#   or nil.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f190_v14.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

LWR = "src/LivestockWarningReader.lua"

STATE_BRANCH = ("    local state = record.state\n"
                "    if state ~= nil then\n"
                "        return type(state) == \"string\" and state == \"INFECTIOUS\"\n"
                "    end\n")
LEGACY = "    return record.cured == false and record.isCarrier == false\n"
INFECTIOUS_TEST = "        return type(state) == \"string\" and state == \"INFECTIOUS\"\n"

MUTATIONS = [
 ("R1-v08-rule", LWR,
  [(STATE_BRANCH, "", 1)],
  "isActiveRecord reverted to the v0.8 cured rule: the dog goes quiet on 1.4 (intake mutant 1)"),
 ("R2-state-falls-through", LWR,
  [(INFECTIOUS_TEST, "        if type(state) == \"string\" and state == \"INFECTIOUS\" then return true end\n", 1)],
  "a state-bearing record that is not INFECTIOUS falls through to the legacy flags (intake mutant 2)"),
 ("R3-any-string-state", LWR,
  [(INFECTIOUS_TEST, "        return type(state) == \"string\"\n", 1)],
  "any string state is sickness: EXPOSED, RECOVERED and DEAD bark"),
 ("R4-case-folded", LWR,
  [(INFECTIOUS_TEST, "        return type(state) == \"string\" and state:upper() == \"INFECTIOUS\"\n", 1)],
  "the state compare ignores case"),
 ("R5-exposed-counts", LWR,
  [(INFECTIOUS_TEST, "        return type(state) == \"string\" and (state == \"INFECTIOUS\" or state == \"EXPOSED\")\n", 1)],
  "the hidden phase warns"),
 ("R6-state-present-by-truth", LWR,
  [("    if state ~= nil then\n", "    if state then\n", 1)],
  "a present but false state is treated as absent and falls to the flags"),
 ("R7-legacy-cured-ignored", LWR,
  [(LEGACY, "    return record.isCarrier == false\n", 1)],
  "the legacy rule ignores cured"),
 ("R8-legacy-carrier-ignored", LWR,
  [(LEGACY, "    return record.cured == false\n", 1)],
  "the legacy rule ignores isCarrier"),
 ("R9-legacy-truthiness", LWR,
  [(LEGACY, "    return not record.cured and not record.isCarrier\n", 1)],
  "missing legacy flags read as false"),
 ("R10-record-not-checked", LWR,
  [("    if type(record) ~= \"table\" then return false end\n    local state = record.state\n",
    "    local state = record.state\n", 1)],
  "a non-table record is indexed"),
 ("A1-animal-not-checked", LWR,
  [("    if type(animal) ~= \"table\" or type(animal.getHasAnyDisease) ~= \"function\" then\n        return nil\n    end\n", "", 1)],
  "a missing animal or getter is indexed or called"),
 ("A2-gate-truthy", LWR,
  [("    if not okGate or gate ~= true then return nil end\n", "    if not okGate or not gate then return nil end\n", 1)],
  "a truthy non-boolean gate passes"),
 ("A3-gate-ignored", LWR,
  [("    if not okGate or gate ~= true then return nil end\n", "    if not okGate then return nil end\n", 1)],
  "the provider gate is not a gate"),
 ("A4-gate-unprotected", LWR,
  [("    local okGate, gate = pcall(animal.getHasAnyDisease, animal)\n",
    "    local okGate, gate = true, animal:getHasAnyDisease()\n", 1)],
  "a throwing gate escapes the reader"),
 ("A5-walk-unprotected", LWR,
  [("    local okWalk, sick = pcall(function()\n", "    local okWalk, sick = true, (function()\n", 1),
   ("        return false\n    end)\n    if okWalk and sick == true then return true end\n",
    "        return false\n    end)()\n    if okWalk and sick == true then return true end\n", 1)],
  "a throwing record walk escapes the reader"),
 ("A6-first-record-only", LWR,
  [("            if LivestockWarningReader.isActiveRecord(record) then return true end\n",
    "            return LivestockWarningReader.isActiveRecord(record)\n", 1)],
  "only the first record is read: a carrier or EXPOSED record silences an active sibling"),
 ("B1-list-unprotected", LWR,
  [("    local okList, animals = pcall(function()\n", "    local okList, animals = true, (function()\n", 1),
   ("        return cs:getAnimals()\n    end)\n", "        return cs:getAnimals()\n    end)()\n", 1)],
  "a throwing list read escapes the reader"),
 ("B2-list-not-checked", LWR,
  [("    if not okList or type(animals) ~= \"table\" then return nil end\n", "    if not okList then return nil end\n", 1)],
  "a non-table animal list is walked"),
 ("B3-animal-unprotected", LWR,
  [("        local okAnimal, sick = pcall(LivestockWarningReader.isAnimalActivelySick, animal)\n",
    "        local okAnimal, sick = true, LivestockWarningReader.isAnimalActivelySick(animal)\n", 1)],
  "one throwing animal escapes the barn read and hides its siblings"),
 ("B4-first-animal-only", LWR,
  [("        if okAnimal and sick == true then return true end\n",
    "        do return (okAnimal and sick == true) or nil end\n", 1)],
  "only the first animal is read"),
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
    for l in named[:12]:
        print("        " + l[:120])
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
