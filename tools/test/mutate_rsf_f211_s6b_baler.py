# RSF-F211 part 2 (2a the Baler core; 2b the non-stop buffer, the unfinished round bale and the
# ForageWagon) mutation battery: the collection modules (src/ground/BalerCollection.lua,
# src/ground/ForageWagonCollection.lua), the Baler collection hook and the deferred bale birth
# (src/hooks/HookManager.lua), the collected birth in the yard ladder (src/YardLadder.lua).
# Rows live in RSF-F211-s6b-baler_collection_spec_test.lua and yard_ladder_sf46_test.lua.
#
# Each mutation restores one piece of the defect or bends one clause and must be KILLED by a
# named row. For each: assert the edit LANDED (exact occurrence count), run the suite, record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with a hash.
# "DID NOT APPLY" never counts as a kill. KILLED* means killed only by a Lua error: a weak kill,
# a failure.
#
# Not run, and why:
# - createBale's loadFromSavegame guard on the finish context: the engine calls createBale with
#   loadFromSavegame only from onLoadFinished's balesToLoad (Baler.lua:576-583), outside any
#   finishBale, so the guard and the absent finish context give the same answer (equivalent;
#   row B5 pins the observable).
# - the unexplained-litres term in the pickup handler: it is reached only when the observer
#   could not capture a source (a refused barrier or an unobservable envelope), which the
#   engine model does not produce under a Baler; the term keeps such litres unknown.
# - the class onStartWorkAreaProcessing wrap: every row that bales goes through it (no context,
#   no collection); its removal is the same observable as H1 below.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root): py tools/test/mutate_rsf_f211_s6b_baler.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BC = "src/ground/BalerCollection.lua"
HM = "src/hooks/HookManager.lua"
YL = "src/YardLadder.lua"
FW = "src/ground/ForageWagonCollection.lua"

MUTATIONS = [
 # ── the seal and the weights ────────────────────────────────────────────────
 ("W1-W-from-raw-not-produced", BC,
  [("        for _, b in ipairs(ctx.batches) do P = P + b.P end\n        st.add = {",
    "        for _, b in ipairs(ctx.batches) do P = P + b.raw end\n        st.add = {", 1)],
  "the produced carrier W is taken as the raw source litres, so the native gain is not carried"),
 ("W2-seal-weights-by-raw", BC,
  [("        local q = A_b * byId[id] / R\n", "        local q = byId[id]\n", 1)],
  "each source's carrier is its raw litres instead of its share of the accepted amount"),
 # ── overflow ────────────────────────────────────────────────────────────────
 ("O1-overflow-not-bound", BC,
  [("                BC.accountAddAccount(st.overflow, BC.sealTarget(st.add.ctx, st.add.W, overflowAfter))\n",
    "                BC.accountAddUnknown(st.overflow, overflowAfter)\n", 1)],
  "the observed overflow is unknown instead of the unaccepted part of the same mixture"),
 ("O2-readd-is-a-new-pickup", BC,
  [("                BC.accountAddAccount(st.main, BC.accountTake(st.transfer.old, appliedDelta))\n",
    "                BC.accountAddUnknown(st.main, appliedDelta)\n", 1)],
  "the re-added overflow enters the chamber as unknown material"),
 ("O3-readd-remainder-dropped", BC,
  [("            BC.accountAddAccount(st.overflow, BC.accountTake(t.old, overflowAfter))\n", "", 1)],
  "what the listener stores back after a re-add loses its condition"),
 # ── the account ─────────────────────────────────────────────────────────────
 ("C1-untracked-increase-ignored", BC,
  [("    if diff > BC.TOLERANCE then\n        BC.accountAddUnknown(acc, diff)\n    elseif",
    "    if false then\n        BC.accountAddUnknown(acc, diff)\n    elseif", 1)],
  "material in the chamber that Soil never saw is not counted as unknown"),
 ("C2-known-only-mean", BC,
  [("    if acc.unknown > BC.TOLERANCE or acc.refused > BC.TOLERANCE then return nil end\n", "", 1)],
  "a chamber with unknown content still claims its known-only mean for the whole bale"),
 ("C3-one-shared-state", BC,
  [("    local st = rawget(vehicle, BC.STATE_KEY)\n    if st == nil then\n        st = {",
    "    local st = BC._shared\n    if st == nil then\n        st = {", 1),
   ("        rawset(vehicle, BC.STATE_KEY, st)\n", "        BC._shared = st\n        rawset(vehicle, BC.STATE_KEY, st)\n", 1)],
  "every baler shares one chamber account"),
 # ── the bale ────────────────────────────────────────────────────────────────
 ("F1-finish-holds-a-live-reference", BC,
  [("            account = BC.copyAccount(st.main)\n        end\n",
    "            account = st.main\n        end\n", 1)],
  "the finish context holds the live chamber account, which the square clear empties before createBale"),
 ("F2-first-seen-object-bound", BC,
  [("        if obj == bound then\n", "        if obj == frame.seen[1] then\n", 1)],
  "the first object registered in the frame gets the chamber's condition, not the appended bale"),
 ("F3-frame-not-closed-on-failure", BC,
  [("    for i = #BC.creationFrames, 1, -1 do\n        if BC.creationFrames[i] == frame then table.remove(BC.creationFrames, i) break end\n    end\n", "", 1)],
  "a creation frame stays open after createBale returns"),
 # ── the hooks ───────────────────────────────────────────────────────────────
 ("H1-pickup-pointer-not-wrapped", HM,
  [("        local n = HookManager.wrapWorkAreaProcessing(vehicle, \"spec_baler\", \"processBalerArea\", makePickupWrapper)\n",
    "        local n = 0\n", 1)],
  "the captured pickup pointer is left native, so no pickup is observed"),
 ("H2-fill-change-not-wrapped", HM,
  [("    Baler.onFillUnitFillLevelChanged = function(balerSelf, ...)\n        return BalerCollection.aroundFillChange(balerSelf, origFill, ...)\n    end\n", "", 1)],
  "the Baler's fill-change listener is not wrapped, so nothing is accepted into the chamber"),
 ("H3-birth-not-deferred", HM,
  [("            deferred = okD and d == true\n", "            deferred = false\n", 1)],
  "Bale.register gives the bale a generic birth inside createBale, before the frame can bind it"),
 # ── the yard ladder ─────────────────────────────────────────────────────────
 ("Y1-collected-birth-re-attaches", YL,
  [("    local existing = (not collected) and self:_findUnattachedMatch(farmId, fillTypeName, capacity) or nil\n",
    "    local existing = self:_findUnattachedMatch(farmId, fillTypeName, capacity)\n", 1)],
  "a baler's new bale re-attaches to an old row with the same key"),
 ("Y2-collected-wetness-dropped", YL,
  [("    local wetnessPct = collected and birth.wetnessPct or nil\n", "    local wetnessPct = nil\n", 1)],
  "the collected wetness never reaches the bale's row"),
 # ── part 2b: the non-stop buffer and its transfer ──────────────────────────
 ("B1-buffer-pickup-not-sealed", BC,
  [("            BC.accountAddAccount(st.buffer, BC.sealTarget(st.add.ctx, st.add.W, appliedDelta))\n",
    "            BC.accountAddUnknown(st.buffer, appliedDelta)\n", 1)],
  "a non-stop baler's pickup enters its buffer as unknown"),
 ("B2-transfer-not-carried", BC,
  [("                BC.accountAddAccount(st.main, BC.accountScaled(st.tick.pending, appliedDelta))\n",
    "                BC.accountAddUnknown(st.main, appliedDelta)\n", 1)],
  "the buffer-to-chamber transfer loses the buffer's condition"),
 ("B3-gain-not-scaled", BC,
  [("                BC.accountAddAccount(st.main, BC.accountScaled(st.tick.pending, appliedDelta))\n",
    "                BC.accountAddAccount(st.main, BC.accountTake(st.tick.pending, appliedDelta))\n", 1)],
  "the overloading gain is not carried as the same mixture"),
 ("B4-transfer-overflow-unknown", BC,
  [("            elseif st.tick ~= nil and st.tick.consumed and st.tick.pending ~= nil then\n                BC.accountAddAccount(st.overflow, BC.accountScaled(st.tick.pending, overflowAfter))\n",
    "", 1)],
  "a full chamber's overflow from a transfer is unknown instead of the transfer's mixture"),
 ("B5-no-tick-scope", BC,
  [("    if st ~= nil then st.tick = {} end\n", "", 1)],
  "the buffer debit outside a tick scope is retired, so the transfer arrives unknown"),
 # ── part 2b: the unfinished round bale ─────────────────────────────────────
 ("P1-pad-is-material", BC,
  [("                st.pad.padded = (st.pad.padded or 0) + appliedDelta\n",
    "                BC.accountAddUnknown(st.main, appliedDelta)\n", 1)],
  "the pad to capacity is counted as unknown material in the bale"),
 ("P2-buffer-share-dropped", BC,
  [("            if st.pad.share ~= nil then BC.accountAddAccount(account, st.pad.share) end\n", "", 1)],
  "the buffer's share of an unfinished round bale is left out of its condition"),
 # ── part 2b: the forage wagon ──────────────────────────────────────────────
 ("W3-one-batch-for-two-captures", BC,
  [("    if #order <= 1 then\n", "    if true then\n", 1)],
  "a call that removed twice is sealed as one batch across two captures"),
 ("F1-fill-moves-the-whole-buffer", FW,
  [("        BC.accountAddAccount(st.unit, BC.accountTake(st.buffer, accepted))\n",
    "        BC.accountAddAccount(st.unit, BC.accountTake(st.buffer, st.buffer.carrier))\n", 1)],
  "the fill moves the whole buffer's account instead of the accepted share"),
 ("F2-trim-kept", FW,
  [("    if ab ~= nil then BC.accountReconcile(st.buffer, ab) end   -- a trim below 0.01 is a real discard\n", "", 1)],
  "the engine's trim below 0.01 L stays in the buffer's account"),
 ("F3-acceptance-not-observed", FW,
  [("    rawset(vehicle, \"addFillUnitFillLevel\", recorder)\n", "", 1)],
  "the admitted FillUnit call is not observed, so the wagon's load is unknown"),
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
