# RSF-741 mutation battery: does the bar catch the versions that would ship the delivery-only
# underwrite wrong?
#
# Each mutation re-introduces the defect RSF-741 repairs, or removes one clause of the repair,
# and must be KILLED by a named row of harvest_underwrite_741_test.lua or
# RSF-741-underwrite_entry_point_test.lua. For each: assert the edit LANDED (exact
# occurrence count), run the suite, record KILLED/SURVIVED with the named rows, restore
# byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY" never counts as a kill.
#
# Usage (from the repo root): py tools/test/mutate_rsf741.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

UW = "src/HarvestContractUnderwrite.lua"
HM = "src/hooks/HookManager.lua"
SFS = "src/SoilFertilitySystem.lua"

MUTATIONS = [
 # --- the defect itself (items 11 to 15) ---
 ("M1-divide-the-whole-blend", UW,
  [("    local corrected = vanilla + (1 - hcf) * (sellCorrected - sellVanilla)\n",
    "    local corrected = vanilla / appliedRatio\n", 1)],
  "the SF-29 defect: the whole field-work plus delivery blend is divided, so cutting alone completes"),
 ("M2-delivery-weight-dropped", UW,
  [("    local corrected = vanilla + (1 - hcf) * (sellCorrected - sellVanilla)\n",
    "    local corrected = vanilla + (sellCorrected - sellVanilla)\n", 1)],
  "the correction ignores the native delivery weight"),
 ("M3-sell-uncapped", UW,
  [("    local sellCorrected = math.min(sellVanilla / appliedRatio, 1)\n",
    "    local sellCorrected = sellVanilla / appliedRatio\n", 1)],
  "the corrected delivery component can exceed 1"),
 ("M4-floor-at-vanilla-dropped", UW,
  [("    if corrected < vanilla then corrected = vanilla end\n", "", 1)],
  "nothing holds the result at or above vanilla (a ratio edge could lower completion)"),
 ("M5-yield-modifier-read-again", UW,
  [("    local appliedRatio = post / pre\n",
    "    local sfm = g_SoilFertilityManager; local ym = sfm and sfm.soilSystem and sfm.soilSystem.computeYieldModifier and sfm.soilSystem:computeYieldModifier(farmlandId, fruitTypeIndex)\n    local appliedRatio = type(ym) == \"number\" and ym or (post / pre)\n", 1)],
  "the completion reads the yield modifier (the old freeze) instead of the captured ratio"),
 # --- the record guards (items 2, 9, 11, 17) ---
 ("M6-readiness-not-required", UW,
  [("    if not HarvestContractUnderwrite.isReady() then return vanilla end\n", "", 1)],
  "partial capture is accepted: the completion corrects with provenance not ready"),
 ("M7-fault-ignored", UW,
  [("    if rec == nil or rec.captureFault ~= false then return vanilla end\n",
    "    if rec == nil then return vanilla end\n", 1)],
  "a faulted record still corrects"),
 ("M8-stale-mission-accepted", UW,
  [("    if rec.missionUniqueId == nil or rec.missionUniqueId ~= missionUid(mission) then return nil end\n",
    "    if rec.missionUniqueId == nil then return nil end\n", 1)],
  "a record from another (stale) mission is consumed"),
 # --- capture (items 4 to 8) ---
 ("M9-standing-capture-not-called", HM,
  [("                local okUw, errUw = pcall(HarvestContractUnderwrite.onStandingArea, cutterSelf, workArea, added, actual)\n",
    "                local okUw, errUw = true, nil\n", 1)],
  "the zone-yield wrapper never hands the standing pair to the underwrite"),
 ("M10-healthy-is-the-scaled-delta", HM,
  [("                local okUw, errUw = pcall(HarvestContractUnderwrite.onStandingArea, cutterSelf, workArea, added, actual)\n",
    "                local okUw, errUw = pcall(HarvestContractUnderwrite.onStandingArea, cutterSelf, workArea, actual, actual)\n", 1)],
  "healthy is taken after SF scaling, so SF's share disappears from the ratio"),
 ("M11-pickup-not-captured", HM,
  [("            if cutterSelf.isServer and type(r1) == \"number\" and r1 > 0 and HCU.onPickup ~= nil then\n",
    "            if false then\n", 1)],
  "positive pickup calls are never bound"),
 ("M12-weight-by-live-not-applied", UW,
  [("    local w = applied / prepared.liveLiters\n", "    local w = 1\n", 1)],
  "the healthy litres are not weighted by what the Combine actually applied"),
 ("M13-zero-return-faults", UW,
  [("    if applied == 0 then return end\n",
    "    if applied == 0 then faultRecord(rec, \"zero\"); return end\n", 1)],
  "a normal zero Combine return (full tank) faults a valid record"),
 ("M14-live-litres-not-checked", UW,
  [("    if not finite(actual) or not finite(liters) or math.abs(actual - liters) > 1e-9 then\n",
    "    if not finite(actual) or not finite(liters) then\n", 1)],
  "litres changed between the Cutter and the Combine are weighted as if they matched"),
 ("M15-additive-branch-not-faulted", UW,
  [("                if not ok or not finite(level) or level > 0 then\n",
    "                if false then\n", 1)],
  "an active supported additive is extrapolated instead of faulted"),
 ("M16-disagreement-not-faulted", UW,
  [("    if #missions > 1 or hasFault or hasNone then\n",
    "    if #missions > 1 or hasFault then\n", 1)],
  "a header straddling contract and own ground records the mixed material"),
 ("M17-wrong-identity-becomes-nonmission", UW,
  [("    for _, m in ipairs(wrong) do HarvestContractUnderwrite.fault(m, path .. \" identity mismatch at the work area\") end\n", "", 1),
   ("    for _, m in ipairs(matches) do HarvestContractUnderwrite.fault(m, \"ambiguous \" .. path .. \" binding\") end\n    return { kind = \"fault\" }\n",
    "    for _, m in ipairs(matches) do HarvestContractUnderwrite.fault(m, \"ambiguous \" .. path .. \" binding\") end\n    if #matches == 0 then return { kind = \"none\" } end\n    return { kind = \"fault\" }\n", 1)],
  "a running mission found with the wrong identity is treated as non-mission"),
 ("M18-client-captures", HM,
  [("            if cutterSelf.isServer and added > 0 and spec ~= nil and spec.workAreaParameters ~= nil\n",
    "            if added > 0 and spec ~= nil and spec.workAreaParameters ~= nil\n", 1),
   ("                if cutterSelf.isServer then pcall(HCU.beginTick, cutterSelf) end\n",
    "                pcall(HCU.beginTick, cutterSelf)\n", 1),
   ("                if cutterSelf.isServer then\n                    local okT, tk = pcall(HCU.makeToken, cutterSelf)\n",
    "                do\n                    local okT, tk = pcall(HCU.makeToken, cutterSelf)\n", 1)],
  "a client's cutter ticks capture and move a record"),
 ("M19-token-not-cleared", HM,
  [("                HCU._token = nil\n                local spec = cutterSelf.spec_cutter\n",
    "                local spec = cutterSelf.spec_cutter\n", 1)],
  "the cutter-end token outlives the end it belongs to"),
 ("M20-zone-yield-not-tagged", HM,
  [("            if hasCutter and typeDef.functions and typeDef.functions.processCutterArea\n                and not zyTags[typeDef.functions.processCutterArea] then\n",
    "            if hasCutter and typeDef.functions and typeDef.functions.processCutterArea then\n", 1),
   ("                    if wa.functionName == \"processCutterArea\" and type(wa.processingFunction) == \"function\"\n                        and not zyTags[wa.processingFunction] then\n",
    "                    if wa.functionName == \"processCutterArea\" and type(wa.processingFunction) == \"function\" then\n", 1)],
  "a second install stacks a second scaling and capture layer on a live pointer"),
 # --- arming (v0.5 item 3) ---
 ("M21-arm-before-native-body", UW,
  [("            local r1, r2, r3 = original(missionSelf, ...)\n            pcall(HCU.arm, missionSelf)\n",
    "            pcall(HCU.arm, missionSelf)\n            local r1, r2, r3 = original(missionSelf, ...)\n", 1)],
  "the record is armed before the native body sets RUNNING (arms nothing, or arms a mission native then kills)"),
 ("M22-vehicle-pair-not-mirrored", UW,
  [("    if mission.failedToLoadVehicles and (type(pending) ~= \"table\" or #pending == 0) then return false end\n", "", 1)],
  "a mission whose vehicles failed is armed and then finished FAILED in the same call"),
 ("M23-timeout-not-mirrored", UW,
  [("    if type(mission.isTimedOut) == \"function\" and mission:isTimedOut() then return false end\n    if type(mission.validate) ~= \"function\" or mission:validate() ~= true then return false end\n",
    "", 1)],
  "a mission that timed out or failed validate is armed and then finished in the same call"),
 ("M24-validate-inlined-parent-only", UW,
  [("    if type(mission.validate) ~= \"function\" or mission:validate() ~= true then return false end\n",
    "    if AbstractMission ~= nil and AbstractMission.validate ~= nil and AbstractMission.validate(mission) ~= true then return false end\n", 1)],
  "the parent validate is inlined instead of the instance call, so the selling-station half is missed"),
 ("M25-field-record-created", UW,
  [("    if type(fd) ~= \"table\" then return false end\n",
    "    if type(fd) ~= \"table\" then fd = {}; soil.fieldData[farmlandId] = fd end\n", 1)],
  "arming creates an SF field record to hold the underwrite"),
 ("M26-install-not-paired", UW,
  [("    if completionLive and armingLive then return true end\n",
    "    if completionLive then return true end\n", 1)],
  "a completion wrapper already live is taken as the whole pair, so the arming never installs on a retry"),
 # --- persistence (item 10) ---
 ("M27-xml-save-dropped", SFS,
  [("                HarvestContractUnderwrite.saveRecordXML(xmlFile, fieldKey, field.harvestUnderwriteProvenance)\n", "", 1)],
  "the XML save owner no longer writes the record"),
 ("M28-ledger-mirror-dropped", SFS,
  [("                HarvestContractUnderwrite.recordToFlat(field.harvestUnderwriteProvenance, e)\n", "", 1)],
  "the StateLedger projection no longer carries the record"),
 ("M29-invalid-combination-kept", UW,
  [("    if armed ~= true or type(fault) ~= \"boolean\" then return nil end\n",
    "    if type(fault) ~= \"boolean\" then return nil end\n", 1)],
  "an unarmed key set loads as a record"),
 ("M30-sowing-keeps-record", SFS,
  [("    field.harvestUnderwriteProvenance = nil\n", "", 1)],
  "a new crop cycle keeps the old contract's record"),
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
