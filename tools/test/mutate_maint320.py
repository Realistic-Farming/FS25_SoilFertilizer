# MAINTENANCE row 320 mutation battery (targeted): the BUY-mode backup refill's AI test in
# installSprayerAreaHook (src/hooks/HookManager.lua). The rows are groups A, B and C of
# MAINT-320-backup_refill_ai_term_spec_test.lua.
#
# Each mutation removes or bends one clause of the refill and must be KILLED by a named row.
# For each: assert the edit LANDED (exact occurrence count), run ONLY the one file that holds the
# rows (the smallest selection that can see the change, in the foreground), record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with a hash.
#
# The selection goes through a filtered copy of run-tests.mjs written beside it and deleted in
# `finally` (the runner has no per-file option). A filter can only turn a kill into a survivor,
# never fake one, so a SURVIVED result is reported as it stands and judged by reading, not by a
# larger run.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py -u tools/test/mutate_maint320.py [id-prefix ...]
import atexit, hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"

MUTATIONS = [
 ("M1-term-restored", HM,
  [("                    if not isAI and self.spec_aiJobVehicle and self.spec_aiJobVehicle.job ~= nil then\n"
    "                        isAI = true\n"
    "                    end\n",
    "                    if not isAI and self.spec_aiVehicle and self.spec_aiVehicle.isActive then isAI = true end\n"
    "                    if not isAI and self.spec_aiJobVehicle and self.spec_aiJobVehicle.job ~= nil then\n"
    "                        isAI = true\n"
    "                    end\n", 1)],
  "the removed spec_aiVehicle.isActive term is back at the backup refill, so an unoccupied implement is charged"),

 ("M2-every-vehicle-is-ai", HM,
  [("                    local isAI = false\n"
    "                    local okAI, resAI = pcall(function() return self:getIsAIActive() end)\n",
    "                    local isAI = true\n"
    "                    local okAI, resAI = pcall(function() return self:getIsAIActive() end)\n", 1)],
  "every vehicle is treated as a hired worker at the backup refill"),

 ("M3-refill-never-happens", HM,
  [("                            if not alreadyHandled then\n", "                            if false then\n", 1)],
  "the backup refill puts nothing back and charges nothing"),

 ("M4-setting-ignored", HM,
  [("                            buyActive = (mi.helperBuyFertilizer == true)\n", "                            buyActive = true\n", 1)],
  "the helper-buy setting is ignored at the backup refill"),
]

# Mutants that cannot be killed by any input, judged by reading. None here.
EQUIVALENT = {}


def sha(b): return hashlib.sha256(b).hexdigest()


SELECTED = [
    "MAINT-320-backup_refill_ai_term_spec_test.lua",   # groups A, B, C
]
TEST_DIR = os.path.join(ROOT, "tools", "test")
RUNNER = os.path.join(TEST_DIR, "run-tests.mjs")
FILTERED = os.path.join(TEST_DIR, "run-tests.maint320.mjs")
ANCHOR = "let testFiles = allTestFiles;"


def write_filtered_runner():
    with open(RUNNER, "r", encoding="utf-8") as f:
        src = f.read()
    if src.count(ANCHOR) != 1:
        print("the runner's selection line is not where this script expects it; stopping")
        sys.exit(4)
    pick = "let testFiles = allTestFiles.filter((tf) => %s.includes(tf));" % repr(SELECTED).replace("'", '"')
    with open(FILTERED, "w", encoding="utf-8") as f:
        f.write(src.replace(ANCHOR, pick))


def run_suite():
    r = subprocess.run(["node", os.path.basename(FILTERED)], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


def remove_filtered_runner():
    try:
        os.remove(FILTERED)
    except FileNotFoundError:
        pass


only = sys.argv[1:]
write_filtered_runner()
atexit.register(remove_filtered_runner)   # also runs on sys.exit, so the copy never stays behind
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN on the selected file; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green (%d selected file)" % len(SELECTED))

killed, crashkills, survived, badedit, equivalent = [], [], [], [], []

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
    elif mid in EQUIVALENT:
        equivalent.append(mid)
        tag = "EQUIVALENT"
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:6]:
        print("        " + l[:120])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
for mid, why in survived:
    print("   SURVIVED %s: %s" % (mid, why))
print("equivalent (judged by reading, see EQUIVALENT) %d" % len(equivalent))
print("bad edit %d" % len(badedit))
for mid, why in badedit:
    print("   BAD EDIT %s: %s" % (mid, why))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
