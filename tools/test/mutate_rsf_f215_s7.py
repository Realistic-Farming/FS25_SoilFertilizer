# RSF-F215 (S7) mutation battery (full, the RSF repair tier): the limited condition provider.
# The rows (src/YardLadder.lua), the store's load and save (src/MaterialDown.lua), the bridge's
# marker, own file and ledger door (src/integrations/SoilMaterialDownBridge.lua), the codec
# (src/integrations/MaterialDownCodec.lua), the storage frame and the delete door
# (src/hooks/HookManager.lua), the provider on the manager (src/SoilFertilityManager.lua).
# Rows live in RSF-F215-s7-condition_provider_spec_test.lua; yard_ladder_sf46_test.lua and the
# part-2 bench run with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED with
# the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY"
# never counts as a kill. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# Not run, and why:
# - the envelope's inner deep copy of the rows (MaterialDown:_buildEnvelope): serialize hands
#   out a second deep copy of the frozen envelope, so dropping either copy alone leaves the
#   store detached; equivalent from outside (row S2b pins the observable).
# - the listener's before-failure reason (LISTENER_BEFORE_FAILED): the same invalidate path
#   as the after-failure N8 pins; the reason string differs only.
# - RESET: nothing emits it (the unwrap policy is held).
# - the late-delivery guard in MaterialDown:deserialize (a delivery after the decision records
#   nothing): EQUIVALENT, found in the first run (35 entries, it survived, removed here).
#   finishLoad decides once and returns early on every later call, so a late delivery that
#   is recorded is never read; the guard only keeps the table tidy.
#
# Anchors are written with LF line ends; in a CRLF file they are matched as CRLF.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f215_s7.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

YL = "src/YardLadder.lua"
MD = "src/MaterialDown.lua"
BR = "src/integrations/SoilMaterialDownBridge.lua"
CO = "src/integrations/MaterialDownCodec.lua"
HM = "src/hooks/HookManager.lua"
SFM = "src/SoilFertilityManager.lua"

MUTATIONS = [
 # ── binding ────────────────────────────────────────────────────────────────
 ("B1-native-id-ignored", YL, [("    local token = (uid ~= nil and not collected) and self._byUid[uid] or nil\n", "    local token = nil\n", 1)],
  "a returning bale is never matched to its own row: every reload and storage withdrawal is a new, unknown bale"),
 ("B2-restore-is-an-event", YL, [("    if row.carrierState == YardLadder.CARRIER.PENDING then\n", "    if false then\n", 1)],
  "a bale back after a load is treated as a rebind: its coordinates move although nothing about it changed"),
 ("B3-storage-delete-retires", YL, [("    if bale ~= nil and self._storing[bale] and type(row) == \"table\" and row.schema == YardLadder.ROW_SCHEMA\n",
                                     "    if false and bale ~= nil and self._storing[bale] and type(row) == \"table\" and row.schema == YardLadder.ROW_SCHEMA\n", 1)],
  "a bale put into an object storage loses its row"),
 ("B4-duplicate-id-trusted", YL, [("            self._conflict[token] = \"DUPLICATE_NATIVE_ID\"\n", "", 1)],
  "two live bales claiming one id: the row still answers READY"),
 ("B5-legacy-rows-kept-bound", YL, [("            row.carrierState = YardLadder.CARRIER.UNBOUND\n", "", 1)],
  "a legacy row is not marked unbound"),
 ("B6-allocator-not-seeded", YL, [("        md:reserveTokenSerial(YardLadder._tokenSerial(token))\n", "", 1)],
  "the allocator is not raised above a surviving row's serial: a new row collides with an old token"),
 # ── reads ──────────────────────────────────────────────────────────────────
 ("Q0-partial-bale-litres-from-level", YL, [("    if type(account) == \"table\" and finite(account.carrier) and account.carrier > 0 then litres = account.carrier end\n", "", 1)],
  "an unfinished round bale's portion is its padded level: it reads READY while padded and UNAVAILABLE once the real amount is dropped"),
 ("Q1-quantity-not-checked", YL, [("    if math.abs(sum - (actual or 0)) > YardLadder.LITRE_EPSILON then\n", "    if false then\n", 1)],
  "a partly used bale still reads READY with its old portions"),
 ("Q2-read-not-detached", YL, [("        portions             = self:_detachedPortions(row),\n", "        portions             = row.portions,\n", 1)],
  "a read hands out the live portions: a caller can change the store"),
 # ── notifications ──────────────────────────────────────────────────────────
 ("N1-before-skipped", YL, [("        local ok, ticket = pcall(l.beforeChange, MaterialDown.deepCopy(before))\n", "        local ok, ticket = true, nil\n", 1)],
  "listeners are never told before a change, and get no ticket"),
 ("N2-failure-not-invalidated", YL, [("            pcall(l.invalidate, nativeId, t ~= nil and t.ok and \"LISTENER_AFTER_FAILED\" or \"LISTENER_BEFORE_FAILED\")\n", "", 1)],
  "a listener whose callback failed is never told its view is invalid"),
 ("N3-advance-sequence-not-consumed", YL, [("                    p.nextEventSequence = (p.nextEventSequence or 1) + 1\n", "", 1)],
  "a daily increase does not consume a condition sequence"),
 ("N4-revision-not-committed", YL, [("    row.rowRevision = (row.rowRevision or 0) + 1\n", "", 1)],
  "an event does not advance the row revision"),
 # ── validation ─────────────────────────────────────────────────────────────
 ("V1-duplicate-ids-accepted", YL, [("                    if uids[row.nativeBaleUniqueId] then return false, \"DUPLICATE_NATIVE_ID\" end\n", "", 1)],
  "a payload with two rows on one native id goes live"),
 ("V2-token-above-allocator-accepted", YL, [("            if next ~= nil and n >= next then return false, \"TOKEN_ABOVE_ALLOCATOR\" end\n", "", 1)],
  "a row token the saved allocator never issued is accepted"),
 ("V3-portions-disagree-accepted", YL, [("                if math.abs(sum - row.observedLitres) > YardLadder.LITRE_EPSILON then return false, \"PORTIONS_DISAGREE\" end\n", "", 1)],
  "portions that do not sum to the observed litres are accepted"),
 # ── the load decision ──────────────────────────────────────────────────────
 ("M1-generation-not-compared", MD, [("        elseif payload.saveGeneration ~= marker.generation then\n", "        elseif false then\n", 1)],
  "a payload of another generation than the marker expects goes live"),
 ("M2-backend-not-selected", MD, [("        local payload = delivered[marker.backend]\n", "        local payload = delivered.STATELEDGER or delivered.OWN_FILE\n", 1)],
  "an inactive backend's stale block overrides the one the marker names"),
 ("M3-unavailable-save-publishes-rows", MD, [("        saveStatus           = MaterialDown.SAVE_STATUS.UNAVAILABLE,\n",
                                              "        saveStatus           = MaterialDown.SAVE_STATUS.UNAVAILABLE,\n        objects              = self.objects,\n", 1)],
  "an unavailable session's save carries a live objects map"),
 ("M4-no-recovery-after-unavailable", MD, [("        state, reason = L.LEGACY, \"AFTER_UNAVAILABLE\"\n", "        state, reason = L.UNAVAILABLE, \"AFTER_UNAVAILABLE\"\n", 1)],
  "one unavailable session makes every later load unavailable"),
 ("M5-new-career-qualified-as-legacy", MD, [("        if self.newCareer and payload == nil then\n", "        if false then\n", 1)],
  "a new career is taken for a pre-F215 save"),
 ("M6-envelope-frozen-per-call", MD, [("    if inv ~= nil and self._frozen ~= nil and self._frozen.invocation == inv then\n", "    if false then\n", 1)],
  "every serialize inside one save builds its own envelope and generation"),
 ("M7-allocator-wraps", MD, [("    if n >= MaterialDown.TOKEN_SERIAL_MAX then return nil, \"EXHAUSTED\" end\n", "", 1)],
  "the allocator runs past the largest exact integer"),
 # ── the bridge ─────────────────────────────────────────────────────────────
 ("R1-marker-before-the-file", BR, [("    if envelope.saveStatus == MaterialDown.SAVE_STATUS.COMPLETE and reached then\n",
                                     "    if envelope.saveStatus == MaterialDown.SAVE_STATUS.COMPLETE then\n", 1)],
  "the marker says EXPECTED although the own file never saved"),
 ("R2-registration-not-checked", BR, [("    if not ok or not registered then\n", "    if not ok then\n", 1)],
  "a registration the ledger refused is taken as the backend"),
 ("R3-marker-not-read", BR, [("    if not newCareer then marker = SoilMaterialDownBridge.readCareerMarker() end\n", "", 1)],
  "the load never reads the career marker: a saved career loads as legacy"),
 ("R4-own-file-skipped-with-ledger", BR, [("    if materialDown == nil then return end\n    if g_server == nil then return end\n    local path = xmlPath()\n    if path == nil or loadXMLFile == nil",
                                          "    if materialDown == nil or SoilMaterialDownBridge.ledgerActive then return end\n    if g_server == nil then return end\n    local path = xmlPath()\n    if path == nil or loadXMLFile == nil", 1)],
  "the own file is not read when StateLedger is present, even when the marker names the own file"),
 ("R5-saved-while-off", BR, [("    if type(materialDown.isArmed) ~= \"function\" or not materialDown:isArmed() then return end\n", "", 1)],
  "a save while the family is off writes an unavailable marker and file"),
 # ── the codec ──────────────────────────────────────────────────────────────
 ("K1-repeated-key-accepted", CO, [("        if seen[typedKey] then return nil, \"REPEATED_KEY\" end\n", "", 1)],
  "a repeated typed key is decoded, the later value silently winning"),
 ("K2-non-finite-written", CO, [("            if not finite(v) then visiting[tbl] = nil return false, \"NON_FINITE_VALUE\" end\n", "", 1)],
  "NaN and infinity are written"),
 ("K3-cycle-not-detected", CO, [("    if visiting[tbl] then return false, \"CYCLE\" end\n", "", 1)],
  "a cycle is not named as one"),
 ("K4-bad-boolean-accepted", CO, [("            else return nil, \"BAD_BOOLEAN\" end\n", "            else value = false end\n", 1)],
  "a malformed boolean decodes as false"),
 # ── the hooks and the manager ──────────────────────────────────────────────
 ("H1-storage-frame-inert", HM, [("        if framed then pcall(yl.beginStoring, yl, object) end\n", "", 1)],
  "the object storage's delete is not framed: the stored bale's row retires"),
 ("H2-delete-without-the-bale", HM, [("                if baleSelf.nodeId ~= nil then yl:onBaleRemoved(baleSelf.nodeId, baleSelf) end\n",
                                      "                if baleSelf.nodeId ~= nil then yl:onBaleRemoved(baleSelf.nodeId) end\n", 1)],
  "the delete door does not say which bale: storage cannot be told from a death"),
 ("S1-manager-reads-nothing", SFM, [("    local ok, result = pcall(yl.getConditionPortions, yl, nativeBaleUniqueId)\n",
                                     "    local ok, result = pcall(yl.getConditionPortions, yl, nil)\n", 1)],
  "the manager's read never reaches the row"),
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
