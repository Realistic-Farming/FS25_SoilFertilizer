# R8 mutation battery (full: an RSF repair, R-25): the RSF-F226 permanent processor
# gate. Production lines in src/hooks/HookManager.lua only; the rows live in
# RSF-F226-R8-permanent_gate_entry_spec_test.lua (the entry-point bar), the rewritten
# RSF-F226 wrap-slot, F226d and F226e bars, overlap_own_pass_grace_test.lua and
# SF-73-target_entry_point_test.lua, and every other bar runs with them.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a group that
# raised): a weak kill, a failure.
#
# G1, G5 and G9 are the intake's three (move the class wrap to the overlap hook; key the
# nutrient skip on the flag alone; restore the swap's lifetime, a block that comes off in
# the end event). The rest bend the other changed lines.
#
# Not run, and why:
# - hasActiveSprayerGate's site check: no other Soil site wraps processSprayerArea, so
#   dropping it is equivalent today.
# - the gate's first-execution and first-refusal log lines: logging only.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_r8_f226_gate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"

GATE_CALL = ("    local overlapGateOk = self:installSprayerOverlapGate()\n"
             "    if overlapGateOk then successCount = successCount + 1 else failCount = failCount + 1 end\n")

MUTATIONS = [
 ("G1-class-wrap-at-the-overlap-hook", HM,
  [(GATE_CALL, "", 1),
   ("    self:installOverlapPreventionHook()\n",
    "    self:installOverlapPreventionHook()\n" + GATE_CALL, 1)],
  "the gate installs where the overlap hook lives, after the instance-field writers (finding 1)"),
 ("G2-no-gate-install", HM,
  [(GATE_CALL, "", 1)],
  "installAll never installs the gate"),
 ("G3-flag-without-gate", HM,
  [("            if coverageComplete and sprayerSelf.isServer\n"
    "               and HookManager.hasActiveSprayerGate(sprayerSelf) then\n",
    "            if coverageComplete and sprayerSelf.isServer then\n", 1)],
  "the prepend flags a pass no gate can refuse (finding 2)"),
 ("G4-flag-on-client", HM,
  [("            if coverageComplete and sprayerSelf.isServer\n",
    "            if coverageComplete\n", 1)],
  "a client flags its own pass"),
 ("G5-skip-on-flag-alone", HM,
  [("            if HookManager.isOverlapBlockedPass(self) then\n",
    "            if self._sfOverlapBlockedPass then\n", 1)],
  "the nutrient skip reads the flag alone, not the one predicate (Bob's intake)"),
 ("G6-predicate-flag-alone", HM,
  [("    return HookManager.hasActiveSprayerGate(sprayer)\n", "    return true\n", 1)],
  "isOverlapBlockedPass is the flag alone, for all three readers"),
 ("G7-gate-ignores-active", HM,
  [("        if record.active and vehicleSelf ~= nil and vehicleSelf._sfOverlapBlockedPass then\n",
    "        if vehicleSelf ~= nil and vehicleSelf._sfOverlapBlockedPass then\n", 1)],
  "an inactive (torn-down) gate still refuses"),
 ("G8-gate-never-refuses", HM,
  [("        if record.active and vehicleSelf ~= nil and vehicleSelf._sfOverlapBlockedPass then\n",
    "        if false then\n", 1)],
  "the gate is a pass-through always"),
 ("G9-swap-lifetime", HM,
  [("            sprayerSelf._sfOverlapBlockedPass = nil\n", "", 1),
   ("            function(sprayerSelf, dt, hasProcessed)\n"
    "                local suppressed = sprayerSelf._sfOverlapSuppressedSections\n",
    "            function(sprayerSelf, dt, hasProcessed)\n"
    "                sprayerSelf._sfOverlapBlockedPass = nil\n"
    "                local suppressed = sprayerSelf._sfOverlapSuppressedSections\n", 1)],
  "a block that comes off in the end event, the swap's lifetime (Bob's intake)"),
 ("G10-gate-calls-the-class", HM,
  [("        return predecessor(vehicleSelf, workArea, dt, ...)\n",
    "        return Sprayer.processSprayerArea(vehicleSelf, workArea, dt, ...)\n", 1)],
  "the gate delegates to the class function, not the captured predecessor (PF's chain)"),
 ("G11-release-always-restores", HM,
  [("    if workArea.processingFunction == record.wrapper and type(record.predecessor) == \"function\" then\n",
    "    if type(record.predecessor) == \"function\" then\n", 1)],
  "teardown restores under a foreign wrap and deletes it"),
 ("G12-release-drops-record", HM,
  [("    record.active = false\n    return \"left\"\n",
    "    workArea._sfWraps[functionName] = nil\n    return \"left\"\n", 1)],
  "a slot left in place forgets its record"),
 ("G13-rewrap-not-reactivate", HM,
  [("            if record ~= nil then\n                record.active = true\n",
    "            if false then\n                record.active = true\n", 1)],
  "a second sweep wraps again instead of reactivating"),
 ("G14-reactivate-leaves-inactive", HM,
  [("            if record ~= nil then\n                record.active = true\n",
    "            if record ~= nil then\n", 1)],
  "a reinstall finds the record and leaves it inactive"),
 ("G15-add-ignores-return", HM,
  [("        if addRecord.active and results[1] == true then\n",
    "        if addRecord.active then\n", 1)],
  "a failed add is wrapped"),
 ("G16-add-drops-return", HM,
  [("        return unpack(results, 1, results.n)\n", "        return nil\n", 1)],
  "the addVehicle wrap swallows its predecessor's return"),
 ("G17-no-install-sweep", HM,
  [("            gated = gated + gateVehicle(vehicle)\n", "", 1)],
  "vehicles present at install are never gated"),
 ("G18-teardown-leaves-add-active", HM,
  [("        addRecord.active = false\n", "", 1)],
  "the addVehicle wrap keeps wrapping after teardown"),
 ("G19-teardown-no-slot-release", HM,
  [("            local result = HookManager.releaseWorkAreaSlot(workArea, \"processSprayerArea\")\n",
    "            local result = nil\n", 1)],
  "teardown never releases a gate slot"),
 ("G20-class-restore-unconditional", HM,
  [("        if VehicleSystem.addVehicle == ourAdd then\n", "        if true then\n", 1)],
  "teardown overwrites a foreign class wrap above ours"),
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
