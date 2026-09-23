# SoilFertilizer #995 mutation battery: the value-map sync bookkeeping
# (src/maps/SoilValueMaps.lua), the patch round, the client evaluator and the join
# send (src/network/NetworkEvents.lua), and the timer (src/SoilFertilityManager.lua).
# Rows live in SF-995-value_map_sync_cost_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - clearLayer's whole-layer mark on the client: every FULL stream re-applies every
#     row and applySyncRow marks each one, so the clear's own mark is masked;
#   - the in-flight flag left alone by a PATCH round's last chunk: no row lands a
#     patch round while a repair is in flight (the repair reply precedes the next
#     timer by minutes), so the guard has no bar to fail;
#   - the checksum event superseding an evaluation in progress: a client receives
#     one checksum per round and one per reply, never two within one evaluation
#     in these rows;
#   - the synchronous fallbacks (no addUpdateable): never taken on a mission
#     (BaseMission.lua:534), and the dedi row D1 pins the dispatcher path.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_sf995.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

VM = "src/maps/SoilValueMaps.lua"
NE = "src/network/NetworkEvents.lua"
MGR = "src/SoilFertilityManager.lua"

MUTATIONS = [
 # ── the writers' marks ──────────────────────────────────────────────────────
 ("V1-point-write-does-not-mark", VM,
  [("    self:_markSyncDirtyZ(key, worldZ - r, worldZ + r)\n", "", 1)],
  "a point write leaves no dirty row: never patched, never re-read"),
 ("V2-polygon-paint-does-not-mark", VM,
  [("            m:executeSet(raw)\n        end)\n    end\n    self:_markSyncDirtyVerts(key, verts)\n",
    "            m:executeSet(raw)\n        end)\n    end\n", 1)],
  "a field paint leaves no dirty row: the client drifts and asks for the layer"),
 ("V3-layer-delta-does-not-mark", VM,
  [("    self:markSyncLayerDirty(key)\n    self:_observeGrowthWrite(key, SoilValueMaps.GROWTH_WRITE_EXECUTED, growthDomain)\n    return rawDelta\nend\n\n--- [SF-49",
    "    self:_observeGrowthWrite(key, SoilValueMaps.GROWTH_WRITE_EXECUTED, growthDomain)\n    return rawDelta\nend\n\n--- [SF-49", 1)],
  "a whole-layer delta leaves no dirty row"),
 ("V4-aimed-write-does-not-mark", VM,
  [("    self:_markSyncDirtyVerts(key, verts)\n    self:_observeGrowthWrite(key, SoilValueMaps.GROWTH_WRITE_EXECUTED, growthDomain)\n    return true\nend\n\n--- [SF-43] Highest",
    "    self:_observeGrowthWrite(key, SoilValueMaps.GROWTH_WRITE_EXECUTED, growthDomain)\n    return true\nend\n\n--- [SF-43] Highest", 1)],
  "setPolygonWhere and clearPolygonWhere leave no dirty row"),
 ("V5-z-range-marks-one-row", VM,
  [("    self:markSyncRowsDirty(key, math.floor(pz0 / stride), math.floor(pz1 / stride))",
    "    self:markSyncRowsDirty(key, math.floor(pz0 / stride), math.floor(pz0 / stride))", 1)],
  "a write's z extent marks only its first row"),

 # ── the row cache ───────────────────────────────────────────────────────────
 ("C1-unread-rows-trusted", VM,
  [("               stale = {}, staleCount = n, dirty = {}, dirtyCount = 0 }\n        for gy = 0, n - 1 do st.stale[gy] = true end\n",
    "               stale = {}, staleCount = 0, dirty = {}, dirtyCount = 0 }\n", 1)],
  "a row never read counts as zero in the checksum"),
 ("C2-refresh-keeps-old-row-total", VM,
  [("    if st.rowSum[gy] ~= nil then\n        st.sum     = st.sum - st.rowSum[gy]\n        st.nonZero = st.nonZero - st.rowNonZero[gy]\n    end\n", "", 1)],
  "a re-read row is added on top of its old total"),
 ("C3-refresh-does-not-clear-stale", VM,
  [("    if st.stale[gy] then st.stale[gy] = nil; st.staleCount = st.staleCount - 1 end\n", "", 1)],
  "every row stays stale forever: every round re-reads everything"),
 ("C4-zero-state-counted-non-zero", VM,
  [("        sum = sum + state\n        if state > 0 then nonZero = nonZero + 1 end\n    end\n    if st.rowSum[gy] ~= nil then",
    "        sum = sum + state\n        nonZero = nonZero + 1\n    end\n    if st.rowSum[gy] ~= nil then", 1)],
  "the cached non-zero count is the column count"),
 ("C5-take-does-not-clear-dirty", VM,
  [("    table.sort(out)\n    st.dirty, st.dirtyCount = {}, 0\n    return out", "    table.sort(out)\n    return out", 1)],
  "every round re-patches everything ever written"),
 ("C6-client-apply-does-not-mark", VM,
  [("    -- The receiving side's cache no longer describes this row.\n    self:markSyncRowsDirty(key, gy, gy)\n", "", 1)],
  "the client's cache never follows a patched row: false drift, a request every round"),

 # ── the chunk apply ─────────────────────────────────────────────────────────
 ("A1-patch-before-full-applied", NE,
  [("    if self.mode == \"PATCH\" and not sfValueMapFullLanded[self.layerIdx] then return end\n", "", 1)],
  "a patch paints over a map that never got its FULL"),
 ("A2-full-never-lands", NE,
  [("    if self.mode ~= \"PATCH\" then\n        local numRows = vm.getSyncRowCount and vm:getSyncRowCount() or 0\n        for _, part in ipairs(parts) do\n            if part.gyStart + #part.rows >= numRows then sfValueMapFullLanded[self.layerIdx] = true end\n        end\n    end\n", "", 1)],
  "no layer ever admits a patch"),
 ("A3-last-patch-chunk-unflagged", NE,
  [("            chunk.isLast = (round.index == #round.chunks)", "            chunk.isLast = false", 1)],
  "a patch round never says it is complete on the client"),

 # ── the client evaluator ────────────────────────────────────────────────────
 ("E1-evaluator-unbounded", NE,
  [("            if vmNow == nil or sfEvaluateStep(vmNow, SF_SYNC_ROWS_PER_TICK) then",
    "            if vmNow == nil or sfEvaluateStep(vmNow, math.huge) then", 1)],
  "the client reads every stale row in one tick: the join's twelve layers at once"),
 ("E2-judged-without-refresh", NE,
  [("            local stale = vm:getSyncStaleRows(def.key)\n            local i = 1\n            while i <= #stale and budget > 0 do\n                vm:refreshSyncRow(def.key, stale[i])\n                i = i + 1\n                budget = budget - 1\n            end\n            if i <= #stale then return false end   -- the budget is spent; next tick\n", "", 1)],
  "a layer is judged on a cache that was never read"),

 # ── the join send ───────────────────────────────────────────────────────────
 ("S1-join-reads-without-caching", NE,
  [("            rows[#rows + 1] = vm:refreshSyncRow(item.key, gy) or {}", "            rows[#rows + 1] = vm:readSyncRow(item.key, gy) or {}", 1)],
  "the trailing checksum describes an unread cache, not what was sent"),
 ("S2-reply-checksum-carries-every-layer", NE,
  [("        return SoilValueMapChecksumEvent.new(sfChecksumsFromCache(vm, onlyLayerIdx))",
    "        return SoilValueMapChecksumEvent.new(sfChecksumsFromCache(vm))", 1)],
  "a single-layer repair is judged by every layer's checksum"),
 ("S3-join-not-drip-fed", NE,
  [("                dsp.timer = dsp.timer + dt\n                if dsp.timer < dsp.delay then return end\n                dsp.timer = 0\n\n                local isLast = (dsp.index == #dsp.work)",
    "                local isLast = (dsp.index == #dsp.work)", 1)],
  "the join's chunks go out every tick, not every 40 ms"),

 # ── the round ───────────────────────────────────────────────────────────────
 ("R1-round-patches-nothing", NE,
  [("            round.layers[#round.layers + 1] = { layerIdx = layerIdx, key = def.key, dirty = vm:takeSyncDirtyRows(def.key) }",
    "            round.layers[#round.layers + 1] = { layerIdx = layerIdx, key = def.key, dirty = {} }", 1)],
  "the round never takes the dirty rows: no patch, every drift a FULL resend"),
 ("R2-round-sends-full-chunks", NE,
  [("        round.chunks[#round.chunks + 1] = SoilValueMapChunkEvent.new(layerIdx, gyStart, rows, false, { mode = \"PATCH\" })",
    "        round.chunks[#round.chunks + 1] = SoilValueMapChunkEvent.new(layerIdx, gyStart, rows, false, { mode = \"FULL\" })", 1)],
  "the round's chunks apply before a layer's FULL, and read as a FULL stream"),
 ("R3-refresh-unbounded", NE,
  [("        local budget = SF_SYNC_ROWS_PER_TICK\n        while budget > 0 and round.cursor <= #round.layers do",
    "        local budget = math.huge\n        while budget > 0 and round.cursor <= #round.layers do", 1)],
  "the server refreshes every stale row in one tick: the audit round is the old walk"),
 ("R4-round-not-drip-fed", NE,
  [("            round.timer = round.timer + dt\n            if round.timer < SF_SYNC_CHUNK_DELAY then return false end\n            round.timer = 0\n", "", 1)],
  "the round's chunks go out every tick, not every 40 ms"),
 ("R5-second-firing-starts-second-round", NE,
  [("    if sfSyncRound ~= nil then return end\n    sfSyncRoundCount = sfSyncRoundCount + 1", "    sfSyncRoundCount = sfSyncRoundCount + 1", 1)],
  "a timer firing during a round starts another"),
 ("R6-no-audit-round", NE,
  [("audit = (sfSyncRoundCount % SF_SYNC_AUDIT_EVERY == 0),", "audit = false,", 1)],
  "an unmarked write would hide forever"),

 # ── the timer ───────────────────────────────────────────────────────────────
 ("T1-timer-never-fires", MGR,
  [("            if SoilNetworkEvents_BroadcastValueMapChecksums then\n                SoilNetworkEvents_BroadcastValueMapChecksums()\n            end\n", "", 1)],
  "no round ever runs"),
 ("T2-timer-ten-times-faster", MGR,
  [("        if self._vmChecksumTimer >= 300000 then", "        if self._vmChecksumTimer >= 30000 then", 1)],
  "a round every 30 seconds"),
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
