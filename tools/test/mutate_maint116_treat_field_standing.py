# MAINTENANCE row 116 mutation battery: the treatment writer's standing test and its charge
# (src/SoilFertilitySystem.lua), the network door's sender resolution (src/network/NetworkEvents.lua),
# the two local doors' farm (src/settings/SoilSettingsGUI.lua, src/ui/SoilScoutDialog.lua). Rows live
# in MAINT-116-treat_field_standing_spec_test.lua; the other bars run with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the old charge fallback (the host's farm, then farm 1) restored: it sat behind the
#   standing test, which already refuses a treatment with no farm before any write, so a
#   restored fallback is unreachable; the standing test's own mutation (W1) covers the
#   host-pays case, and N1 pins the refusal.
# - the physical-fungicide turn-away on each door: untouched by this PR.
# - two EQUIVALENT mutants found in the first run (12 entries, both survived, removed here):
#   the writer's own 'farm 0' refusal dropped (farm 0 never equals a positive owner and the
#   engine names no farm 0 to contract, so the owner test refuses it the same way; N2 pins
#   the observable), and the network door's nil-farm refusal dropped (the writer's standing
#   test refuses a nil farm before any write; the door's refusal is a shortcut, E5 pins the
#   observable). Neither can be seen from outside, so neither is a bar gap.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root): py tools/test/mutate_maint116_treat_field_standing.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SFS = "src/SoilFertilitySystem.lua"
NE = "src/network/NetworkEvents.lua"
GUI = "src/settings/SoilSettingsGUI.lua"
DLG = "src/ui/SoilScoutDialog.lua"

STANDING = "    if not SoilFertilitySystem.isTreatAuthorized(opts.farmId, fieldId) then\n        return false, \"sf_treat_no_standing\", {}\n    end\n"

MUTATIONS = [
 # ── the writer ──────────────────────────────────────────────────────────────
 ("W1-standing-dropped", SFS, [(STANDING, "", 1)],
  "any farm treats any field, and a treatment with no farm charges nobody or the host"),
 ("W2-unowned-land-is-everyones", SFS,
  [("    if not ok or type(owner) ~= \"number\" or owner <= 0 then return false end\n    if owner == actingFarmId then return true end",
    "    if not ok or type(owner) ~= \"number\" then return false end\n    if owner <= 0 or owner == actingFarmId then return true end", 1)],
  "unowned land can be treated by any farm"),
 ("W3-contracting-ignored", SFS,
  [("    local ok2, allowed = pcall(handler.canFarmAccessOtherId, handler, actingFarmId, owner)\n    return ok2 and allowed == true\n",
    "    return false\n", 1)],
  "a contractor is refused on the land it works"),
 ("W4-owner-equality-inverted", SFS,
  [("    if owner == actingFarmId then return true end\n    local handler", "    if owner ~= actingFarmId then return true end\n    local handler", 1)],
  "the owner is refused and every other farm admitted"),
 ("W6-charge-goes-to-the-host", SFS,
  [("            local farmId = opts.farmId\n            if g_currentMission and g_currentMission.addMoney and farmId and farmId > 0 then",
    "            local farmId = (g_localPlayer and g_localPlayer.farmId) or opts.farmId\n            if g_currentMission and g_currentMission.addMoney and farmId and farmId > 0 then", 1)],
  "the host's farm pays for a client's treatment"),
 # ── the network door ────────────────────────────────────────────────────────
 ("D1-event-passes-the-hosts-farm", NE,
  [("    local farmId = SoilNetworkEvents_ActingFarmId(connection)\n    if farmId == nil or farmId <= 0 then return end\n\n    g_SoilFertilityManager.soilSystem:applyNamedFungicide(",
    "    local farmId = SoilNetworkEvents_ActingFarmId(nil)\n    if farmId == nil or farmId <= 0 then return end\n\n    g_SoilFertilityManager.soilSystem:applyNamedFungicide(", 1)],
  "the event acts for the host's own farm, whoever sent it"),
 # ── the local doors ─────────────────────────────────────────────────────────
 ("L1-console-passes-no-farm", GUI,
  [("sfm.soilSystem:applyNamedFungicide(fid, chemId, { charge = true, farmId = SoilFertilitySystem.localScoutFarmId() })",
    "sfm.soilSystem:applyNamedFungicide(fid, chemId, { charge = true })", 1)],
  "the host's own console is refused on its own field"),
 ("L2-console-acts-as-farm-1", GUI,
  [("sfm.soilSystem:applyNamedFungicide(fid, chemId, { charge = true, farmId = SoilFertilitySystem.localScoutFarmId() })",
    "sfm.soilSystem:applyNamedFungicide(fid, chemId, { charge = true, farmId = 1 })", 1)],
  "a dedicated server's console treats and bills farm 1"),
 ("L3-dialog-passes-no-farm", DLG,
  [("sfm.soilSystem:applyNamedFungicide(self._fieldId, id, { charge = true, farmId = SoilFertilitySystem.localScoutFarmId() })",
    "sfm.soilSystem:applyNamedFungicide(self._fieldId, id, { charge = true })", 1)],
  "the host's own dialog is refused on its own field"),
 ("L4-dialog-acts-as-farm-1", DLG,
  [("sfm.soilSystem:applyNamedFungicide(self._fieldId, id, { charge = true, farmId = SoilFertilitySystem.localScoutFarmId() })",
    "sfm.soilSystem:applyNamedFungicide(self._fieldId, id, { charge = true, farmId = 1 })", 1)],
  "a client of farm 2 is refused on its own field and admitted on farm 1's"),
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
