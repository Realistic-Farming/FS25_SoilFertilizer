# RSF-F211 part 1 (S6, the readers) mutation battery: MaterialWetness's standing and collected
# readers and the producer's seal (src/MaterialWetness.lua), the hay settle's reach, fill type,
# field polygons and probe (src/HayBet.lua), the tedder's parallelogram (src/hooks/HookManager.lua)
# and the polygon clip (src/utils/PolygonClip.lua). Rows live in RSF-F211-s6-readers_spec_test.lua,
# material_wetness_sf49_test.lua (13b) and hay_bet_sf44_test.lua (10); the other bars run with them.
#
# Each mutation restores one piece of the defect or bends one clause and must be KILLED by a
# named row. For each: assert the edit LANDED (exact occurrence count), run the suite, record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with a hash.
# "DID NOT APPLY" never counts as a kill. KILLED* means killed only by a Lua error: a weak kill,
# a failure.
#
# Not run, and why:
# - HandfulRead's call moved from the alias to the probe: a rename whose fake (handful_read_sf38)
#   exposes only the probe, so the old call could only die by a crash (a weak kill).
# - the fill type check against FillType.UNKNOWN: the model's (and the engine's) height manager
#   maps no height type to UNKNOWN, so the next check refuses it the same way; equivalent.
# - the row pre-read in standingSnapshot (a row with none of the type is skipped): a cost
#   shortcut; skipping it reads the same cells.
# - the tedder's degenerate-area refusal: a turned tedder never has a zero-area work area in
#   the engine, and no row can build one through the real hook.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root): py tools/test/mutate_rsf_f211_s6_readers.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MW = "src/MaterialWetness.lua"
HB = "src/HayBet.lua"
HM = "src/hooks/HookManager.lua"
PC = "src/utils/PolygonClip.lua"

MUTATIONS = [
 # ── the standing snapshot ───────────────────────────────────────────────────
 ("S1-no-clip-the-box-counts", MW,
  [("                        local fraction = PolygonClip.overlapFraction(x0, z0, x1, z1, triangles)\n",
    "                        local fraction = 1\n", 1)],
  "every cell in the polygon's box counts whole: the notch and the far side of an edge are read"),
 ("S2-first-field-only", MW,
  [("    for _, poly in ipairs(polygons) do\n        local tris = PolygonClip.triangulate(poly)\n",
    "    for _, poly in ipairs({ polygons[1] }) do\n        local tris = PolygonClip.triangulate(poly)\n", 1)],
  "a farmland's second field is not read"),
 ("S3-invalid-polygon-read-as-empty", MW,
  [("        if tris == nil then return nil, \"INVALID_POLYGON\" end\n", "        if tris == nil then tris = {} end\n", 1)],
  "a self-crossing or degenerate field reads as empty ground instead of refusing"),
 ("S4-invalid-height-map-read-as-empty", MW,
  [("    local okV, valid = pcall(hm.getIsValid, hm)\n    if not okV or not valid then return false, \"HEIGHT_MAP_UNAVAILABLE\" end\n",
    "", 1)],
  "an invalid height map reads as bare ground"),
 ("S5-clip-before-read", MW,
  [("                    if litres == nil then return nil, \"HEIGHT_MAP_UNAVAILABLE\" end\n                    if litres > 0 then\n",
    "                    if litres == nil then return nil, \"HEIGHT_MAP_UNAVAILABLE\" end\n                    PolygonClip.overlapFraction(x0, z0, x1, z1, triangles)\n                    if litres > 0 then\n", 1)],
  "every candidate cell is clipped, grass or none"),
 # ── the source condition ────────────────────────────────────────────────────
 ("C1-overlay-ignored", MW,
  [("    if type(coord.isUnavailable) == \"function\" and coord:isUnavailable(gx, gz) then return S.UNKNOWN end\n", "", 1)],
  "a cell the availability overlay cannot vouch for reads as known"),
 ("C2-sentinel-read-as-unknown", MW,
  [("    if raw < RAW_FLOOR then return S.REFUSAL, nil, ageRaw end\n", "    if raw < RAW_FLOOR then return S.UNKNOWN, nil, ageRaw end\n", 1)],
  "the reserved sentinel is counted as unknown, not refused"),
 ("C3-no-record-read-as-refused", MW,
  [("    if type(raw) ~= \"number\" or raw <= 0 then return S.UNKNOWN, nil, ageRaw end\n",
    "    if type(raw) ~= \"number\" then return S.UNKNOWN, nil, ageRaw end\n", 1)],
  "grass with no record falls into the sentinel test and is counted as refused"),
 # ── the standing read ───────────────────────────────────────────────────────
 ("R1-unweighted-mean", MW,
  [("                out.knownWeightedPctSum = out.knownWeightedPctSum + q * p.pct\n",
    "                out.knownWeightedPctSum = out.knownWeightedPctSum + p.pct\n", 1)],
  "the percent is no longer weighted by each cell's litres"),
 ("R2-unknown-dropped", MW,
  [("            else\n                out.unknownCarrierLitres = out.unknownCarrierLitres + q\n            end\n        end\n    end\n    if out.carrierLitres <= 0 then\n",
    "            else\n                out.carrierLitres = out.carrierLitres - q\n            end\n        end\n    end\n    if out.carrierLitres <= 0 then\n", 1)],
  "unknown grass drops out of the reading and the rest can read fit"),
 ("R3-refused-dropped", MW,
  [("            elseif p.status == S.REFUSAL then\n                out.refusedCarrierLitres = out.refusedCarrierLitres + q\n",
    "            elseif p.status == S.REFUSAL then\n                out.carrierLitres = out.carrierLitres - q\n", 1)],
  "a refused cell drops out of the reading"),
 ("R4-ok-despite-unknown", MW,
  [("    elseif out.unknownCarrierLitres > 0 or out.refusedCarrierLitres > 0 then\n        out.status, out.reason = R.REFUSAL, \"POSITIVE_UNKNOWN_OR_REFUSAL\"\n    else\n        out.status, out.reason = R.OK, \"COMPLETE_KNOWN_COVERAGE\"\n        out.pct = out.knownWeightedPctSum / out.carrierLitres\n",
    "    else\n        out.status, out.reason = R.OK, \"COMPLETE_KNOWN_COVERAGE\"\n        out.pct = out.knownWeightedPctSum / out.carrierLitres\n", 1)],
  "positive unknown or refused content still reads OK"),
 ("R5-stale-snapshot-read", MW,
  [("    if coord == nil or GroundConditionCoordinator == nil\n       or not GroundConditionCoordinator.revisionsEqual(snapshot.revision, coord:getOwnerRevision()) then\n        return coverageResult(B.STANDING, R.UNAVAILABLE, \"REVISION_MISMATCH\")\n",
    "    if coord == nil then\n        return coverageResult(B.STANDING, R.UNAVAILABLE, \"REVISION_MISMATCH\")\n", 1)],
  "a snapshot taken before the owner moved is read as current"),
 ("R6-any-basis-read-as-standing", MW,
  [("    if snapshot.basis ~= B.STANDING then return coverageResult(B.STANDING, R.UNAVAILABLE, \"BASIS_MISMATCH\") end\n", "", 1)],
  "a collected snapshot is read as a standing one"),
 # ── the collected read and the seal ─────────────────────────────────────────
 ("K1-caller-parts-trusted", MW,
  [("        if claimed[portion.id] == nil or claimed[portion.id] ~= q then return unavailable(\"CALLER_ALLOCATION_MISMATCH\") end\n", "", 1),
   ("    for id in pairs(claimed) do\n        if not sealedSeen[id] then return unavailable(\"CALLER_ALLOCATION_MISMATCH\") end\n    end\n", "", 1)],
  "a receipt with a portion deleted is read from the seal as if complete"),
 ("K2-caller-total-trusted", MW,
  [("    if total ~= accepted then return unavailable(\"CALLER_ACCEPTANCE_MISMATCH\") end\n", "", 1),
   ("    if out.carrierLitres ~= accepted or out.carrierLitres ~= total then return unavailable(\"RECEIPT_TOTAL_MISMATCH\") end\n",
    "    if out.carrierLitres ~= accepted then return unavailable(\"RECEIPT_TOTAL_MISMATCH\") end\n", 1)],
  "the caller's lowered total is not checked against the producer's acceptance"),
 ("K3-raw-zero-counted-known", MW,
  [("            if raw == 0 or source.status == S.UNKNOWN then\n", "            if source.status == S.UNKNOWN then\n", 1)],
  "carrier litres with no raw source take their cell's condition"),
 ("K4-weighted-by-raw", MW,
  [("                out.knownWeightedPctSum = out.knownWeightedPctSum + q * source.pct\n",
    "                out.knownWeightedPctSum = out.knownWeightedPctSum + raw * source.pct\n", 1)],
  "the collected percent is weighted by raw source litres instead of retained carrier litres"),
 ("K5-seal-skips-availability", MW,
  [("        if type(source) ~= \"table\" or not finiteNumber(source.available) or part.rawLitres > source.available then\n            return nil, \"SOURCE_AVAILABILITY\"\n",
    "        if type(source) ~= \"table\" then\n            return nil, \"SOURCE_AVAILABILITY\"\n", 1)],
  "the seal accepts raw litres beyond what the source held"),
 ("K6-seal-skips-the-sum", MW,
  [("    if sum ~= acceptedCarrierLitres then return nil, \"RECEIPT_TOTAL_MISMATCH\" end\n", "", 1)],
  "the seal accepts parts that do not sum to the accepted amount"),
 ("K7-no-seal-needed", MW,
  [("    local producer = self:resolveAllocation(receipt)\n",
    "    local producer = self:resolveAllocation(receipt)\n"
    "    if producer == nil then\n        local ps = {}\n        for i, q in ipairs(receipt.parts) do ps[i] = { id = q.id, carrierLitres = q.q, rawLitres = q.q } end\n"
    "        producer = { sealed = true, snapshotId = snapshot.id, acceptedCarrierLitres = receipt.total, parts = ps }\n    end\n", 1)],
  "a receipt no producer sealed is read from the caller's own figures"),
 ("K9-stockguard-resolver-ignored", MW,
  [("    if sg ~= nil and type(sg.readCollectionReceipt) == \"function\" then\n", "    if false then\n", 1)],
  "with StockGuard present, Soil reads only its own seals"),
 ("K10-two-authorities", MW,
  [("        if ok and type(allocation) == \"table\" then return allocation, \"STOCKGUARD\" end\n        return nil, \"STOCKGUARD\"\n",
    "        if ok and type(allocation) == \"table\" then return allocation, \"STOCKGUARD\" end\n", 1)],
  "a receipt StockGuard does not know falls back to Soil's seal: two authorities"),
 ("K8-seals-unbounded", MW,
  [("    while #self.allocationOrder > MaterialWetness.MAX_ALLOCATIONS do\n", "    while false do\n", 1)],
  "sealed allocations accumulate for the mission"),
 # ── the hay member ──────────────────────────────────────────────────────────
 ("H1-no-membership-reach", HB,
  [("        for _, fieldId in ipairs(mw:memberFieldIds()) do add(fieldId) end\n", "", 1)],
  "the settle walks only MaterialDown's active set, which no mower marks"),
 ("H2-fruit-manager-lookup", HB,
  [("    local ftm = g_fillTypeManager\n", "    local ftm = g_fruitTypeManager\n", 1)],
  "the fill type is looked up on the fruit type manager, the old dead call"),
 ("H3-no-field-polygons", HB,
  [("    if ss == nil or type(ss._getFarmlandPolygons) ~= \"function\" then return nil end\n    local ok, polygons = pcall(ss._getFarmlandPolygons, ss, fieldId)\n",
    "    if ss == nil or type(ss._getFarmlandPolygons) ~= \"function\" then return nil end\n    local ok, polygons = pcall(function() return g_fieldManager:getFieldByFarmlandId(fieldId) end)\n", 1)],
  "the field is looked up through getFieldByFarmlandId, which the engine does not have"),
 ("H4-untracked-grass-read", HB,
  [("    if not tracked then return end\n", "", 1)],
  "grass with no age record anywhere is settled"),
 ("H5-tedder-uses-the-alias", HB,
  [("    local condition = mw:probeCondition(verts)\n    if condition.status ~= \"ok\" then return false end\n",
    "    local condition = mw:readCondition(verts, 1)\n    if condition.status ~= \"ok\" then return false end\n", 1)],
  "the tedder delta reads through the deprecated litres alias"),
 # ── the tedder's parallelogram ──────────────────────────────────────────────
 ("T1-tedder-box-restored", HM,
  [("        return {\n            { x = xs,           z = zs },\n            { x = xw,           z = zw },\n            { x = xw + xh - xs, z = zw + zh - zs },\n            { x = xh,           z = zh },\n        }\n",
    "        local x4, z4 = xw + xh - xs, zw + zh - zs\n"
    "        local minX, maxX = math.min(xs, xw, xh, x4), math.max(xs, xw, xh, x4)\n"
    "        local minZ, maxZ = math.min(zs, zw, zh, z4), math.max(zs, zw, zh, z4)\n"
    "        return { { x = minX, z = minZ }, { x = maxX, z = minZ }, { x = maxX, z = maxZ }, { x = minX, z = maxZ } }\n", 1)],
  "the tedder hands over the axis-aligned box around its corners"),
 # ── the polygon clip ────────────────────────────────────────────────────────
 ("P1-clockwise-not-reversed", PC,
  [("    if signedArea2(pts) < 0 then\n", "    if false then\n", 1)],
  "a clockwise field is not re-oriented before ear clipping"),
 ("P2-crossing-not-refused", PC,
  [("                if segmentsCross(a, b, c, d) then return false end\n", "", 1)],
  "a self-crossing field with a nonzero signed area is clipped as if simple"),
 ("P3-first-ear-only", PC,
  [("    if #pts == 3 then tris[#tris + 1] = triangle(pts[1], pts[2], pts[3]) end\n", "", 1)],
  "the last triangle of every field is dropped"),
 ("P4-every-triangle-clipped", PC,
  [("        if tri.minX == nil or (tri.maxX > x0 and tri.minX < x1 and tri.maxZ > z0 and tri.minZ < z1) then\n",
    "        if true then\n", 1)],
  "each cell is clipped against every triangle of the field"),
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
