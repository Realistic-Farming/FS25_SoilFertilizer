# MAINTENANCE rows 85, 110, 111 mutation battery: the side test on the four server-to-client
# sync events and the full-sync HUD line (src/network/NetworkEvents.lua), the organic
# request's acting farm and the writer's standing test (NetworkEvents.lua,
# src/OrganicCertification.lua), the sprayer events' ownership test (NetworkEvents.lua).
# Rows live in MAINT-85-event_authorization_spec_test.lua; the other bars run with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the readStream calls of run (the delivery itself): every row delivers through
#   writeStream into readStream, so a deleted run call fails every row of the group at
#   once; it is the existing round-trip suite's subject, not this battery's.
# - the four correct client-apply events (SoilFieldSentryStatusEvent, SoilValueMapChunkEvent,
#   SoilValueMapChecksumEvent, SoilScoutingMaskSyncEvent): untouched by this PR.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root): py tools/test/mutate_maint85_event_authorization.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NE = "src/network/NetworkEvents.lua"
OC = "src/OrganicCertification.lua"

GUARD = "    if not sfAppliesOnClient(connection) then return end\n"

MUTATIONS = [
 # ── the side test, one event at a time ──────────────────────────────────────
 ("G1-setting-sync-unguarded", NE,
  [(GUARD + "\n    -- Local-only settings are never synced from server; keep each player's own value",
    "\n    -- Local-only settings are never synced from server; keep each player's own value", 1)],
  "a listen host applies a client's setting sync"),
 ("G2-full-sync-unguarded", NE,
  [("    if not sfAppliesOnClient(connection) or not g_SoilFertilityManager then return end\n",
    "    if not g_SoilFertilityManager then return end\n", 1)],
  "a listen host applies a client's full sync: every setting and the fieldData table"),
 ("G3-batch-sync-unguarded", NE,
  [(GUARD + "    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then return end\n\n    local soilSystem = g_SoilFertilityManager.soilSystem\n    for fieldId, field in pairs(self.batchFields) do",
    "    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then return end\n\n    local soilSystem = g_SoilFertilityManager.soilSystem\n    for fieldId, field in pairs(self.batchFields) do", 1)],
  "a listen host merges a client's field batch"),
 ("G4-field-update-unguarded", NE,
  [(GUARD + "\n    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then\n        local soilSys = g_SoilFertilityManager.soilSystem\n        local newField = self.field",
    "\n    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then\n        local soilSys = g_SoilFertilityManager.soilSystem\n        local newField = self.field", 1)],
  "a listen host applies a client's field update"),
 ("R1-field-update-g-client-test-restored", NE,
  [(GUARD + "\n    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then\n        local soilSys = g_SoilFertilityManager.soilSystem\n        local newField = self.field",
    "    if g_client == nil then return end\n\n    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then\n        local soilSys = g_SoilFertilityManager.soilSystem\n        local newField = self.field", 1)],
  "the old test: a listen host, being g_client too, applies the update"),
 ("I1-side-test-inverted", NE,
  [("    if g_server ~= nil then return false end\n    if connection ~= nil and type(connection.getIsServer)",
    "    if g_server == nil then return false end\n    if connection ~= nil and type(connection.getIsServer)", 1)],
  "the host applies and the pure client refuses"),
 ("K1-connection-half-dropped", NE,
  [("    if g_server ~= nil then return false end\n    if connection ~= nil and type(connection.getIsServer) == \"function\" and not connection:getIsServer() then\n        return false\n    end\n    return true",
    "    if g_server ~= nil then return false end\n    return true", 1)],
  "with no server on this side any connection is trusted"),
 ("M1-setting-sync-guard-after-the-write", NE,
  [(GUARD + "\n    -- Local-only settings are never synced from server; keep each player's own value",
    "\n    -- Local-only settings are never synced from server; keep each player's own value", 1),
   ("        g_SoilFertilityManager.settings[self.settingName] = self.settingValue\n",
    "        g_SoilFertilityManager.settings[self.settingName] = self.settingValue\n        if not sfAppliesOnClient(connection) then return end\n", 1)],
  "the guard sits below the write: the host's setting is already changed"),
 ("U1-hud-gate-dropped", NE,
  [("    if corruptionDetected and sfAppliesOnClient(connection) and g_currentMission and g_currentMission.hud then",
    "    if corruptionDetected and g_currentMission and g_currentMission.hud then", 1)],
  "a forged corrupt stream blinks the host's HUD"),
 # ── the organic request ─────────────────────────────────────────────────────
 ("O1-opt-in-standing-dropped", OC,
  [("    if not OrganicCertification.farmOwnsField(actingFarmId, fieldId) then\n        return false, string.format(\"Field %s is not owned by your farm\", tostring(fieldId))\n    end\n    local o = self:ensureState(field)\n\n    if o.state == SoilConstants.ORGANIC.STATE_CERTIFIED then",
    "    local o = self:ensureState(field)\n\n    if o.state == SoilConstants.ORGANIC.STATE_CERTIFIED then", 1)],
  "any farm opts any field in"),
 ("O2-opt-out-standing-dropped", OC,
  [("    if not OrganicCertification.farmOwnsField(actingFarmId, fieldId) then\n        return false, string.format(\"Field %s is not owned by your farm\", tostring(fieldId))\n    end\n    local o = self:ensureState(field)\n\n    if o.state == SoilConstants.ORGANIC.STATE_CONVENTIONAL then",
    "    local o = self:ensureState(field)\n\n    if o.state == SoilConstants.ORGANIC.STATE_CONVENTIONAL then", 1)],
  "any farm opts any field out: the certification wipe"),
 ("O3-event-acts-as-the-host", NE,
  [("    local actingFarmId = SoilNetworkEvents_ActingFarmId(connection)\n    if self.doOptIn then",
    "    local actingFarmId = SoilNetworkEvents_ActingFarmId(nil)\n    if self.doOptIn then", 1)],
  "the event acts for the host's own farm, whoever sent it"),
 ("O4-unowned-land-is-everyones", OC,
  [("    return ok and type(owner) == \"number\" and owner > 0 and owner == farmId\n",
    "    return ok and type(owner) == \"number\" and (owner == 0 or owner == farmId)\n", 1)],
  "unowned land can be opted by any farm"),
 ("O5-local-door-falls-back-to-farm-1", OC,
  [("    local ok, farmId = pcall(mission.getFarmId, mission, nil)\n    if not ok or type(farmId) ~= \"number\" then return nil end\n    return farmId",
    "    local ok, farmId = pcall(mission.getFarmId, mission, nil)\n    if not ok or type(farmId) ~= \"number\" then return 1 end\n    return farmId", 1)],
  "a dedicated server's console acts as farm 1"),
 ("O6-local-door-passes-no-farm", OC,
  [("    local actingFarmId = OrganicCertification.localActingFarmId()\n    if doOptIn then return self:optIn(fieldId, actingFarmId) else return self:optOut(fieldId, actingFarmId) end",
    "    if doOptIn then return self:optIn(fieldId) else return self:optOut(fieldId) end", 1)],
  "the host's own door is refused on its own field"),
 # ── the sprayer events ──────────────────────────────────────────────────────
 ("S1-rate-ownership-dropped", NE,
  [("    if g_server ~= nil and not SoilNetworkEvents_ConnectionMayControlVehicle(connection, vehicle) then return end\n\n    local steps = SoilConstants.SPRAYER_RATE.STEPS",
    "\n    local steps = SoilConstants.SPRAYER_RATE.STEPS", 1)],
  "any client sets any sprayer's rate"),
 ("S2-auto-ownership-dropped", NE,
  [("    if g_server ~= nil and not SoilNetworkEvents_ConnectionMayControlVehicle(connection, vehicle) then return end\n\n    rm:setAutoMode(vehicle.id, self.enabled)",
    "\n    rm:setAutoMode(vehicle.id, self.enabled)", 1)],
  "any client sets any sprayer's auto mode"),
 ("S3-loopback-refused", NE,
  [("    if type(connection.getIsLocal) == \"function\" and connection:getIsLocal() then return true end\n", "", 1)],
  "the host's own hand is refused: a regression of the host's sprayer controls"),
 ("S4-owner-test-inverted", NE,
  [("    return ok and type(owner) == \"number\" and owner == farmId\nend",
    "    return ok and type(owner) == \"number\" and owner ~= farmId\nend", 1)],
  "another farm's sprayer yes, your own no"),
 ("S5-no-player-is-allowed", NE,
  [("    local farmId = SoilNetworkEvents_ActingFarmId(connection)\n    if farmId == nil or farmId <= 0 then return false end\n",
    "    local farmId = SoilNetworkEvents_ActingFarmId(connection)\n    if farmId == nil then return true end\n    if farmId <= 0 then return false end\n", 1)],
  "a connection with no player record controls any vehicle"),
 ("S6-client-side-test-dropped", NE,
  [("    if g_server ~= nil and not SoilNetworkEvents_ConnectionMayControlVehicle(connection, vehicle) then return end\n\n    local steps = SoilConstants.SPRAYER_RATE.STEPS",
    "    if not SoilNetworkEvents_ConnectionMayControlVehicle(connection, vehicle) then return end\n\n    local steps = SoilConstants.SPRAYER_RATE.STEPS", 1)],
  "a pure client refuses the server's rebroadcast for another farm's vehicle"),
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
