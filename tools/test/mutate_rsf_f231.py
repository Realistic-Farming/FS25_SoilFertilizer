# SoilFertilizer RSF-F231 mutation battery: the scout entitlement (src/SpatialScouting.lua,
# src/SoilFertilitySystem.lua, src/network/NetworkEvents.lua, src/SoilFertilityManager.lua,
# src/settings/SoilSettingsGUI.lua, src/ui/SoilScoutDialog.lua). Rows live in
# RSF-F231-scout_entitlement_test.lua, with the three older scout rows in
# resistance_bands_cd11_test.lua, resistance_f68_relief_test.lua and
# resistance_console_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the writer's `if not field then` early return: an unknown field id has no fieldData
#     and nothing to gate, and every row here names a field that exists;
#   - the client-side re-ask while the durable bit is missing: CD-11's own rows own it
#     and this repair leaves that branch as it was;
#   - the dialog's chem list on an ADMITTED scout: _buildChemList is CD-10's, untouched.
#   - the ordinary-farm test inside isFieldScoutAuthorized: a non-ordinary farm is refused
#     again by isRevealAuthorized one call down, so removing it changes no verdict;
#   - clearing the chem list on a refused dialog: a fresh panel has no list to keep, and
#     Apply already returns on a nil chemical (G3 holds either way).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_rsf_f231.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SS = "src/SpatialScouting.lua"
FS = "src/SoilFertilitySystem.lua"
NE = "src/network/NetworkEvents.lua"
FM = "src/SoilFertilityManager.lua"
GUI = "src/settings/SoilSettingsGUI.lua"
DLG = "src/ui/SoilScoutDialog.lua"

MUTATIONS = [
 # ── the standing test ──────────────────────────────────────────────────────
 ("T2-standing-always-true", SS,
  [("    return SpatialScouting._isWalkAuthorized(actingFarmId, farmlandId) == true\n", "    return true\n", 1)],
  "every ordinary farm scouts every field"),
 ("T3-contracting-ignored", SS,
  [("            if ok2 then contractingForOwner = res == true end", "            if ok2 then contractingForOwner = false end", 1)],
  "a farm contracting for the owner is refused (the walked-cell rule itself, shared)"),

 # ── the writer ─────────────────────────────────────────────────────────────
 ("W1-writer-does-not-gate", FS,
  [("    if not SoilFertilitySystem.isScoutAuthorized(actingFarmId, fieldId) then\n        return self:getScoutReport(fieldId), SoilFertilitySystem.SCOUT_REFUSED\n    end\n", "", 1)],
  "the writer trusts every caller"),
 ("W2-discovery-flipped-before-the-test", FS,
  [("    if not SoilFertilitySystem.isScoutAuthorized(actingFarmId, fieldId) then\n        return self:getScoutReport(fieldId), SoilFertilitySystem.SCOUT_REFUSED\n    end\n",
    "    if not SoilFertilitySystem.isScoutAuthorized(actingFarmId, fieldId) then\n        field.diseaseDiscovered = true\n        return self:getScoutReport(fieldId), SoilFertilitySystem.SCOUT_REFUSED\n    end\n", 1)],
  "a refusal still hands the asker the named disease"),
 ("W3-refusal-not-reported", FS,
  [("        return self:getScoutReport(fieldId), SoilFertilitySystem.SCOUT_REFUSED\n", "        return self:getScoutReport(fieldId)\n", 1)],
  "the doors cannot tell a refusal from a clean field"),
 ("W4-no-spatial-scouting-admits", FS,
  [("    if SpatialScouting == nil or type(SpatialScouting.isFieldScoutAuthorized) ~= \"function\" then\n        return false\n    end\n",
    "    if SpatialScouting == nil or type(SpatialScouting.isFieldScoutAuthorized) ~= \"function\" then\n        return true\n    end\n", 1)],
  "with the rule module absent the writer fails open (CD-11's rows load the module, so this is caught only by a row that does not)"),
 ("W5-local-farm-defaults-to-one", FS,
  [("    if type(player) ~= \"table\" then return nil end\n    return player.farmId", "    if type(player) ~= \"table\" then return 1 end\n    return player.farmId", 1)],
  "a dedicated server's console acts as farm 1"),

 # ── the event door ─────────────────────────────────────────────────────────
 ("E1-event-does-not-pass-the-farm", NE,
  [("    g_SoilFertilityManager.soilSystem:scoutField(self.fieldId, actingFarmId)", "    g_SoilFertilityManager.soilSystem:scoutField(self.fieldId)", 1)],
  "the event reaches the writer with no farm (refused for everyone, so the owner rows kill it)"),
 ("E2-event-uses-the-hosts-farm", NE,
  [("    if connection ~= nil then\n        local ps = g_currentMission and g_currentMission.playerSystem\n        if ps ~= nil and type(ps.getPlayerByConnection) == \"function\" then\n            player = ps:getPlayerByConnection(connection)\n        end\n    else\n        player = g_localPlayer\n    end",
    "    player = g_localPlayer", 1)],
  "every client scouts as the listen host's own farm"),
 ("E3-unknown-connection-admitted", NE,
  [("    local actingFarmId = SoilNetworkEvents_FarmIdOfConnection(connection)\n    if actingFarmId == nil then return end\n",
    "    local actingFarmId = SoilNetworkEvents_FarmIdOfConnection(connection) or 1\n", 1)],
  "a sender with no player record scouts as farm 1"),
 ("E4-farm-off-the-wire", NE,
  [("    if type(player) ~= \"table\" then return nil end\n    return player.farmId\nend", "    if type(player) ~= \"table\" then return nil end\n    return connection ~= nil and connection.farmId or player.farmId\nend", 1)],
  "the farm is read from the connection object rather than the player record"),

 # ── the local doors ────────────────────────────────────────────────────────
 ("H1-hotkey-passes-no-farm", FM,
  [("    local rep, refused = self.soilSystem:scoutField(fieldId, SoilFertilitySystem.localScoutFarmId())", "    local rep, refused = self.soilSystem:scoutField(fieldId)", 1)],
  "the hotkey is refused for everyone"),
 ("H2-hotkey-opens-on-refusal", FM,
  [("            g_currentMission.hud:showBlinkingWarning(g_i18n:getText(\"sf_scout_no_standing\"), 3000)\n        end\n        return\n    end",
    "            g_currentMission.hud:showBlinkingWarning(g_i18n:getText(\"sf_scout_no_standing\"), 3000)\n        end\n    end", 1)],
  "a refused hotkey still flashes and opens the dialog"),
 ("K1-console-scout-passes-no-farm", GUI,
  [("    local rep, refused = sfm.soilSystem:scoutField(fid, SoilFertilitySystem.localScoutFarmId())", "    local rep, refused = sfm.soilSystem:scoutField(fid, 1)", 1)],
  "the console scouts as farm 1 on every machine"),
 ("K2-readout-not-gated", GUI,
  [("    if not SoilFertilitySystem.isScoutAuthorized(SoilFertilitySystem.localScoutFarmId(), fid) then\n        return string.format(\"Field %d: no standing (this machine's farm neither owns nor contracts the land)\", fid)\n    end\n", "", 1)],
  "the readout prints a neighbour's learned agronomy"),
 ("G1-dialog-passes-no-farm", DLG,
  [("    local rep, refused = sfm.soilSystem:scoutField(self._fieldId, SoilFertilitySystem.localScoutFarmId())", "    local rep, refused = sfm.soilSystem:scoutField(self._fieldId, 1)", 1)],
  "the dialog scouts as farm 1"),
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
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
