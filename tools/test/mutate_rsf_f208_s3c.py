# SG2-4 S3 mutation battery: the lease path's native observation (src/ground/GroundConditionAdmission.lua),
# the one projector (src/ground/GroundMovementProjector.lua) and the observer's stand-aside on an inner
# admission (src/ground/GroundNativeObserver.lua). Rows live in RSF-F208-s3c-lease_delivery_spec_test.lua
# and the section 7 rows of RSF-F208-ground_condition_cells_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: mutate_rsf_f208_s3.py is section 3's (the carriers), re-anchored where the
# projector split moved its lines; this file is S3's own.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the occupancy-mismatch guard in the projector's land() (surviving plus arrived against the whole
#     cell after): no lease scenario in the bench reaches it, because the model's height map changes
#     only the type the primitive names; a mismatch needs another type to change in the same cell
#     during the same primitive. The carrier bars' W group pins the guard on the standalone path.
#   - the pre-call stand-aside on a live lease: mutate_rsf_f208_s3.py's B1 (the carrier ignores the
#     lease), pinned by the tedder bar's B5.
#   - a delivery in a later frame, a closed lease, a non-string token: the section 7 rows of the cells
#     bar pin them and the code did not move.
#   - the parallelogram envelope's edge padding (half a cell diagonal), the same reading as the line
#     envelope's outer radius in the S2 battery: at the bench's 4 m grain every cell holding material
#     inside the area has its centre inside it, so the padding admits only neighbours the handler skips.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, THROUGH THE TEST LOCK. A battery edits production files in place.
#
# Usage: py tools/test/mutate_rsf_f208_s3c.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

ADM = "src/ground/GroundConditionAdmission.lua"
PRJ = "src/ground/GroundMovementProjector.lua"
OBS = "src/ground/GroundNativeObserver.lua"

MUTATIONS = [
 # ── the observation: native facts only, joined to the lease ────────────────
 ("A1-cells-array-accepted", ADM,
  [("    if observation.cells ~= nil then return nil end\n", "", 1)],
  "the revision 1 cells array is accepted as an observation"),
 ("A2-kind-mismatch-accepted", ADM,
  [("    if observation.primitiveKind ~= lease.primitiveKind then return nil end\n", "", 1)],
  "an observation of another primitive is joined to the lease"),
 ("A3-type-mismatch-accepted", ADM,
  [("        if observation.fillTypeIndex ~= lease.footprint.fillTypeIndex then return nil end\n", "", 1)],
  "an observation of another fill type than the footprint's is joined"),
 ("A4-ok-not-required", ADM,
  [("    if type(observation.ok) ~= \"boolean\" then return nil end\n", "    if false then return nil end\n", 1)],
  "an observation that does not say whether the primitive returned is accepted"),
 ("A5-schema-not-required", ADM,
  [("    if observation.schemaVersion ~= GroundConditionAdmission.OBSERVATION_SCHEMA then return nil end\n", "", 1)],
  "an observation of no schema is accepted"),
 ("A6-frame-index-rawget-on-G", ADM,
  [("    local n = g_updateLoopIndex\n    return type(n) == \"number\" and n or nil",
    "    local n = rawget(_G, \"g_updateLoopIndex\")\n    return type(n) == \"number\" and n or nil", 1)],
  "the frame index is read with rawget on _G, which a mod's environment never answers: the frame rule is inert (as shipped in #1002)"),
 # ── the footprint ───────────────────────────────────────────────────────────
 ("F1-footprint-schema-unchecked", ADM,
  [("    if footprint.schemaVersion ~= GroundConditionAdmission.FOOTPRINT_SCHEMA then return nil end\n", "", 1)],
  "a footprint of no schema or another schema is admitted"),
 ("F2-shape-unchecked", ADM,
  [("    if footprint.kind ~= shape then return nil end\n", "", 1)],
  "an AREA footprint is admitted for a LINE kind"),
 ("F3-fill-type-not-required", ADM,
  [("        if type(footprint.fillTypeIndex) ~= \"number\" then return nil end\n", "", 1)],
  "a LINE footprint without its fill type is admitted"),
 ("F4-negative-radius-admitted", ADM,
  [("        if outer ~= nil and not (finite(outer) and outer >= 0) then return nil end\n", "", 1)],
  "a negative outer radius is admitted"),
 ("F5-nonfinite-coordinate-admitted", ADM,
  [("        if not (finite(footprint.sx) and finite(footprint.sz) and finite(footprint.ex) and finite(footprint.ez)) then return nil end\n", "", 1)],
  "a LINE with a NaN coordinate is admitted"),
 ("F6-unknown-kind-admitted", ADM,
  [("    local fp = shape ~= nil and validFootprint(footprint, shape) or nil\n",
    "    local fp = validFootprint(footprint, shape or \"LINE\")\n", 1)],
  "a primitive kind Soil does not know is admitted as a LINE"),
 # ── the capability ──────────────────────────────────────────────────────────
 ("C1-revision-stays-1", ADM,
  [("GroundConditionAdmission.ADMISSION_REVISION  = 2\n", "GroundConditionAdmission.ADMISSION_REVISION  = 1\n", 1)],
  "the capability still announces the cell-list shape"),
 # ── capture and the reads ───────────────────────────────────────────────────
 ("R1-no-capture-at-admit", ADM,
  [("    GroundMovementProjector.captureCells(lease, cells)\n", "", 1)],
  "the pre-removal condition is never captured: moved material loses its history"),
 ("R2-before-read-skipped", ADM,
  [("        cell.before, cell.beforeWhole = O.readCell(cell, lease.typeIndices, lease.windrowSet)\n", "", 1)],
  "before-occupancy is never read: nothing can be cleared or vouched for"),
 ("R3-invalid-map-at-admit-read-as-zero", ADM,
  [("    if not lease.heightMapValid then\n"
    "        -- No height map to read: the native returns zero for every area, which is not\n"
    "        -- an observation. Keep the indices; the delivery marks them all unavailable.\n"
    "        lease.derived, lease.unobservable, lease.envelopeRefused = cells, true, \"HEIGHT_MAP_INVALID\"\n"
    "        return\n"
    "    end\n", "", 1)],
  "a height map that is not valid at admit reads as bare ground"),
 ("R4-invalid-map-at-delivery-read-as-zero", ADM,
  [("    if not GroundNativeObserver.heightMapValid() then\n"
    "        -- The height map went away between admit and delivery: an after read would be\n"
    "        -- zero, not an observation.\n"
    "        result.unavailable = P.markAll(lease, cells, \"HEIGHT_MAP_INVALID\")\n"
    "        return result\n"
    "    end\n", "", 1)],
  "a height map that went away before the after read clears cells as empty"),
 ("R5-throw-marks-nothing", ADM,
  [("        result.unavailable = P.markAll(lease, cells, \"NATIVE_ERROR\")\n", "        result.unavailable = 0\n", 1)],
  "a primitive that threw leaves its cells vouched for"),
 ("R6-unobservable-marks-nothing", ADM,
  [("        result.unavailable = P.markAll(lease, cells, \"ENVELOPE:\" .. tostring(lease.envelopeRefused))\n", "        result.unavailable = 0\n", 1)],
  "an envelope too large to read leaves old records standing"),
 ("R7-envelope-limit-ignored", ADM,
  [("    if #cells > O.MAX_CELLS then\n", "    if false then\n", 1)],
  "an envelope over the read limit is read anyway"),
 # ── the projection by kind ──────────────────────────────────────────────────
 ("P1-drop-invents-a-condition", PRJ,
  [("        contributions[1] = { litres = arrived, ageRaw = nil, wetnessRaw = nil }\n",
    "        contributions[1] = { litres = arrived, ageRaw = 1, wetnessRaw = 32 }\n", 1)],
  "carried stock Soil never captured arrives born today and dry instead of unknown"),
 ("P2-conversion-carries-condition", ADM,
  [("        counts = P.convert(lease, cells, obs.sourceTypeIndex, obs.destinationTypeIndex, false)\n",
    "        counts = P.convert(lease, cells, obs.sourceTypeIndex, obs.destinationTypeIndex, true)\n", 1)],
  "a conversion with no registered basis keeps the cell's known condition"),
 ("P3-redistribution-loses-condition", PRJ,
  [("                pool[#pool + 1] = { litres = lost, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }\n",
    "                pool[#pool + 1] = { litres = lost, ageRaw = nil, wetnessRaw = nil }\n", 1)],
  "smoothed material arrives of unknown condition instead of the losing cells' captured one"),
 ("P4-area-kinds-project-nothing", ADM,
  [("        counts = P.redistribute(lease, cells)\n", "        counts = { }\n", 1)],
  "clearArea and smoothing deliveries project nothing"),
 ("P5-pickup-clears-partial", PRJ,
  [("    if (cell.afterWhole or 0) <= P.EPSILON then\n", "    if true then\n", 1)],
  "a source cell still holding material is cleared (the lease path's reading of B4)"),
 ("P6-unknown-occupancy-cleared", PRJ,
  [("        if b == nil or a == nil then\n"
    "            -- Unreadable occupancy: not permission to clear, not a source we can price.\n"
    "            P.markUnavailable(ctx, cell, \"OCCUPANCY_UNKNOWN\")\n"
    "            counts.unavailable = counts.unavailable + 1\n"
    "        else\n",
    "        if b == nil or a == nil then\n"
    "            b, a = {}, {}\n"
    "            counts.unavailable = counts.unavailable + 0\n"
    "        end\n"
    "        do\n", 1)],
  "an unreadable occupancy on a pickup reads as bare ground and is neither marked nor refused"),
 # ── the observer stands aside for an inner admission (item 3b) ─────────────
 ("O1-post-call-stand-aside-removed", OBS,
  [("        if prim ~= nil and admittedBefore ~= nil and admission:admissionCount() ~= admittedBefore then\n",
    "        if false then\n", 1)],
  "Soil projects the movement StockGuard already delivered inside the call: a double projection"),
 ("L1-close-marks-nothing", ADM,
  [("    local marked = self:_markUndelivered(lease, \"LEASE_CLOSED_UNDELIVERED\")\n", "    local marked = 0\n", 1)],
  "a lease closed without a delivery leaves its cells vouched for"),
 ("L2-stale-frame-marks-nothing", ADM,
  [("        self:_markUndelivered(lease, \"LEASE_CROSSED_A_FRAME\")\n", "", 1)],
  "a lease that crossed a frame is closed but its cells keep records nobody vouched for"),
 ("L3-leaked-lease-stays-live", ADM,
  [("            if not self:_expireIfStale(lease) then\n                return true\n            end\n", "            return true\n", 1)],
  "a lease nobody closed keeps the standalone carrier standing aside for the mission"),
 ("L4-accepted-delivery-marks-at-close", ADM,
  [("    if (lease.accepted or 0) > 0 or lease.marked then return 0 end\n", "    if lease.marked then return 0 end\n", 1)],
  "the close marks the cells even after an accepted delivery"),
 # ── MAINTENANCE rows 100 and 101 (targeted battery of that PR: only these five run for it) ──
 ("Y1-native-error-reason-overwritten", ADM,
  [("        lease.marked = true   -- row 100: the close and the frame rule mark nothing more; this reason stands\n", "", 1)],
  "a native-error delivery is re-marked at the close as LEASE_CLOSED_UNDELIVERED"),
 ("Y2-envelope-reason-overwritten", ADM,
  [("        result.envelopeRefused = lease.envelopeRefused\n        lease.marked = true   -- row 100, as above\n",
    "        result.envelopeRefused = lease.envelopeRefused\n", 1)],
  "an unobservable envelope's delivery is re-marked at the close"),
 ("Y3-height-map-reason-overwritten", ADM,
  [("        result.unavailable = P.markAll(lease, cells, \"HEIGHT_MAP_INVALID\")\n        lease.marked = true   -- row 100, as above\n",
    "        result.unavailable = P.markAll(lease, cells, \"HEIGHT_MAP_INVALID\")\n", 1)],
  "an invalid-height-map delivery is re-marked at the close"),
 ("Y4-expired-lease-kept", ADM,
  [("        self.openLeases = self.openLeases - 1\n        self.leases[lease.token] = nil\n        return true\n",
    "        self.openLeases = self.openLeases - 1\n        return true\n", 1)],
  "an expired lease stays in the table for the mission"),
 ("Y5-no-sweep-at-admit", ADM,
  [("    self:_sweepStaleLeases()\n", "", 1)],
  "leaked leases from earlier frames accumulate until somebody asks about that owner"),
 ("O2-stand-aside-on-any-attempt", ADM,
  [("function GroundConditionAdmission:admissionCount()\n    return self.leaseSeq\nend\n",
    "function GroundConditionAdmission:admissionCount()\n    return self.leaseSeq + (self.attempts or 0)\nend\n", 1),
   ("    local shape = GroundConditionAdmission.KIND_SHAPE[primitiveKind]\n",
    "    self.attempts = (self.attempts or 0) + 1\n    local shape = GroundConditionAdmission.KIND_SHAPE[primitiveKind]\n", 1)],
  "a refused inner admission also silences Soil's own observation: nobody projects"),
]

def sha(b): return hashlib.sha256(b).hexdigest()

def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], capture_output=True, text=True, cwd=p("tools/test"), encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    strip = lambda l: l.strip()
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes

only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]: print("   " + l)
    for l in crashes[:5]: print("   " + l)
    sys.exit(2)
print("baseline green")

killed, survived, bad, weak = 0, 0, 0, 0
for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only): continue
    path = p(rel)
    original = open(path, "rb").read()
    before = sha(original)
    crlf = b"\r\n" in original
    text = original.decode("utf-8").replace("\r\n", "\n")
    ok = True
    for old, new, count in edits:
        if text.count(old) != count:
            print("  BAD EDIT %s: anchor found %d times, want %d" % (mid, text.count(old), count)); ok = False; break
        text = text.replace(old, new)
    if not ok: bad += 1; continue
    open(path, "wb").write((text.replace("\n", "\r\n") if crlf else text).encode("utf-8"))
    try:
        rc, fails, crashes = run_suite()
    finally:
        open(path, "wb").write(original)
        assert sha(open(path, "rb").read()) == before, "restore failed for " + rel
    if rc != 0:
        killed += 1
        star = "*" if (len(fails) == 0 and len(crashes) > 0) else " "
        if star == "*": weak += 1
        print("  KILLED%s  %s  [%s]" % (star, mid, rel))
        for l in fails[:4]: print("        " + l)
        for l in crashes[:2]: print("        " + l)
    else:
        survived += 1
        print("  SURVIVED %s  [%s]  (%s)" % (mid, rel, why))

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (killed, weak))
print("survived %d" % survived)
print("bad edit %d" % bad)
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(0 if survived == 0 and bad == 0 and weak == 0 else 1)
