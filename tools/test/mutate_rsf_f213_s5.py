# RSF-F213 part 2 (S5) mutation battery: the membership index (GroundConditionCoordinator), the
# run write (GroundConditionCells), the per-cell settle and the shelter read (MaterialWetness) and
# the indoor-mask wrap (HookManager). Does RSF-F213-s5-membership_settle_spec_test.lua catch the
# versions that would weather the wrong ground, or the wrong way?
#
# Each mutation removes one clause and must be KILLED by a named row of that bar (the other
# ground bars run in the same suite and may add kills). For each: assert the edit LANDED (exact
# occurrence count), run the suite, record KILLED/SURVIVED with the named rows, restore
# byte-for-byte and PROVE the restore with a hash. "DID NOT APPLY" never counts as a kill. KILLED*
# means killed only by a Lua error: a weak kill, treated as a failure.
#
# Not run, and why:
# - the run cache's merge and split arithmetic beyond the shapes the bar drives (a run grown at
#   its left end, a run split in the middle by a clear): the bar's M and R rows drive a right-end
#   grow, a whole-run clear and single cells; the remaining branches are the same three lines
#   in mirror and are read, not mutated.
# - the store's per-layer channel plumbing (SoilValueMaps.initialize): the model store hands the
#   coordinator a one-channel entry directly; the real store's path is exercised only in a game
#   (the TESTING row's load-and-save check).
# - the row-level native occupancy split's recursion base (gx0 == gx1): removing it recurses
#   forever; a hang is not a verdict.
# - the rain add lifting a sentinel (max(RAW_FLOOR, raw) + delta): equivalent by construction,
#   settleRun hands valueFor only cells at or above RAW_FLOOR (mutation S6 pins that guard).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, THROUGH THE TEST LOCK. A battery edits production files in place.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f213_s5.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

COORD = "src/ground/GroundConditionCoordinator.lua"
CELLS = "src/ground/GroundConditionCells.lua"
MW = "src/MaterialWetness.lua"
HM = "src/hooks/HookManager.lua"

MUTATIONS = [
 # ── the index's marks ──────────────────────────────────────────────────────
 ("I1-deposit-does-not-mark", COORD,
  [("        -- Section 5: material landed here; the cell is a member from this deposit.\n        self:markMember(gx, gz)\n", "", 1)],
  "a projected deposit never joins the membership"),
 ("I2-clear-does-not-unmark", COORD,
  [("        -- Section 5: a known whole-cell zero leaves the membership.\n        self:unmarkMember(gx, gz)\n", "", 1)],
  "a cleared cell stays a member forever"),
 ("I3-unavailable-does-not-mark", COORD,
  [("    if not skipMembership then self:markMember(gx, gz) end\n", "", 1)],
  "a cell marked unavailable (positive material of unknown condition) is not a member"),
 ("I4-mark-writes-no-bit", COORD,
  [("    if not self:_writeMemberBit(gx, gz, GroundConditionCoordinator.MEMBER) then\n        m.rebuildRequired = true\n        m.ready = false\n        self:markUnavailable(gx, gz, \"MEMBERSHIP_WRITE_FAILED\", true)",
    "    if false then\n        m.rebuildRequired = true\n        m.ready = false\n        self:markUnavailable(gx, gz, \"MEMBERSHIP_WRITE_FAILED\", true)", 1)],
  "the run cache is marked without the native bit being written (and a refused write goes unnoticed)"),
 ("I5-unmark-writes-no-bit", COORD,
  [("    if not self:_writeMemberBit(gx, gz, GroundConditionCoordinator.NOT_MEMBER) then", "    if false then", 1)],
  "a clear drops the cache entry but leaves the native bit set"),
 ("I6-owner-not-bound", COORD,
  [("    if self.membership ~= nil and materialWetness.bindMembership ~= nil then\n        materialWetness:bindMembership(self)\n    end\n", "", 1)],
  "the coordinator builds the index but never binds the wetness owner: the field pass keeps running"),
 ("I7-bound-without-an-index", COORD,
  [("    if self.membership ~= nil and materialWetness.bindMembership ~= nil then", "    if materialWetness.bindMembership ~= nil then", 1)],
  "a store without the layer still binds the owner to a nil index"),
 # ── the rebuild at arm ─────────────────────────────────────────────────────
 ("R1-saved-index-ignored", COORD,
  [("        if entry.loaded then\n            self:_membershipFromIndex(geometry)", "        if false then\n            self:_membershipFromIndex(geometry)", 1)],
  "a saved index is discarded and rebuilt from the bytes (a record the index did not list becomes a member)"),
 ("R2-rebuild-skips-native-occupancy", COORD,
  [("        -- Native material with no record: a member of unknown condition.\n        splitOccupied(0, resolution - 1, gz)\n", "", 1)],
  "the rebuild ignores native material that has no record"),
 ("R3-rebuild-skips-unknown-wetness", COORD,
  [("                if (c.ageRaw ~= nil and c.ageRaw > 0) or (c.wetnessRaw ~= nil and c.wetnessRaw > 0) then",
    "                if (c.ageRaw ~= nil and c.ageRaw > 0) then", 1)],
  "a cell whose only record is a wetness byte is not rebuilt as a member"),
 ("R4-rebuild-marks-cache-only", COORD,
  [("        if not self:_writeMemberBit(gx, gz, GroundConditionCoordinator.MEMBER) then\n            m.rebuildRequired = true\n            return\n        end\n        runsInsert(m.rows, gx, gz)",
    "        runsInsert(m.rows, gx, gz)", 1)],
  "the rebuild fills the cache without writing the bits"),
 ("R5-index-rows-not-counted-first", COORD,
  [("        local n = rowCount(m.mod, m.filter, gz, resolution, GroundConditionCoordinator.MEMBER, GroundConditionCoordinator.MEMBER)\n        if n > 0 then",
    "        local n = rowCount(m.mod, m.filter, gz, resolution, GroundConditionCoordinator.MEMBER, GroundConditionCoordinator.MEMBER)\n        if n < 0 then", 1)],
  "reading a saved index skips every row: the index reads empty"),
 # ── the settle ─────────────────────────────────────────────────────────────
 ("S1-field-pass-runs-too", MW,
  [("        self:dryPassMembers(sky)\n        local wateredM, sourceM = self:wetPassMembers(rain)\n        self:recordDay(dayNumber, wateredM, sourceM, derived)\n        return true\n    end\n",
    "        self:dryPassMembers(sky)\n        local wateredM, sourceM = self:wetPassMembers(rain)\n        self:recordDay(dayNumber, wateredM, sourceM, derived)\n    end\n", 1)],
  "the field pass runs over the same ground after the membership pass (a second application)"),
 ("S2-members-not-settled", MW,
  [("        self:dryPassMembers(sky)\n", "", 1)],
  "the membership dry pass never runs"),
 ("S3-phase-order-reversed", MW,
  [("    for i = 1, #deltas do\n        local d = deltas[i]", "    for i = #deltas, 1, -1 do\n        local d = deltas[i]", 1)],
  "the phases run bound first: the cascade changes and so does the curve"),
 ("S4-no-floor", MW,
  [("            if v < floorRaw then v = floorRaw end\n", "", 1)],
  "a cell dries below the EMC ceiling, into the reserved band"),
 ("S5-band-low-not-emc", MW,
  [("        bandLows[i]  = math.max(MaterialWetness.pctToRaw(phase.pctLow), emcRaw)", "        bandLows[i]  = MaterialWetness.pctToRaw(phase.pctLow)", 1)],
  "the phase band starts below the EMC ceiling"),
 ("S6-unknown-cell-settled", MW,
  [("            if type(raw) == \"number\" and raw >= RAW_FLOOR then", "            if type(raw) == \"number\" and raw > 0 then", 1)],
  "the sentinel (unknown) is weathered as a value"),
 ("S7-unavailable-cell-settled", MW,
  [("        if not coord:isUnavailable(gx, gz) then\n            local c = coord:readCell(gx, gz)", "        if true then\n            local c = coord:readCell(gx, gz)", 1)],
  "a cell marked unavailable is weathered anyway"),
 ("S8-unchanged-cell-written", MW,
  [("                if v ~= raw then newValue = v end", "                newValue = v", 1)],
  "every read cell is written back even when unchanged (the cost record counts the writes)"),
 ("S9-runs-not-coalesced", MW,
  [("        elseif newValue ~= runValue then\n            flush(gx - 1)\n            runStart, runValue = gx, newValue\n        end",
    "        else\n            flush(gx - 1)\n            runStart, runValue = gx, newValue\n        end", 1)],
  "adjacent cells with the same result are written one by one"),
 ("S10-field-drivers-ignored", MW,
  [("    if fieldId ~= nil then\n        soilClass = self:soilClassFor(fieldId)\n        moisture  = self:readSoilMoisture(fieldId)\n    end\n", "", 1)],
  "a cell in a field dries by the neutral defaults instead of the field's soil class"),
 ("S11-drivers-not-neutral-outside", MW,
  [("    local ok, fieldId = pcall(hm.getFieldIdAtWorldPosition, hm, (x0 + x1) * 0.5, (z0 + z1) * 0.5)\n    if not ok or type(fieldId) ~= \"number\" or fieldId <= 0 then return nil end\n    return fieldId",
    "    local ok, fieldId = pcall(hm.getFieldIdAtWorldPosition, hm, (x0 + x1) * 0.5, (z0 + z1) * 0.5)\n    if not ok or type(fieldId) ~= \"number\" or fieldId <= 0 then return 7 end\n    return fieldId", 1)],
  "outside any field the settle invents a field id"),
 ("S12-hold-ignored", MW,
  [("        if not self.membership:isMembershipReady() and not self.membership:reconcileMembership() then",
    "        if false then", 1)],
  "a day settles over an index that needs a rebuild"),
 ("S13-reconcile-never-tried", MW,
  [("        if not self.membership:isMembershipReady() and not self.membership:reconcileMembership() then",
    "        if not self.membership:isMembershipReady() then", 1)],
  "an index that needs a rebuild is never reconciled: the day holds forever"),
 ("S14-reconcile-does-not-rebuild", COORD,
  [("        m.rows, m.count, m.rebuildRequired = {}, 0, false\n        self:_membershipRebuild(geometry)", "        m.rows, m.count, m.rebuildRequired = {}, 0, false", 1)],
  "reconciling empties the index and rebuilds nothing"),
 # ── rain and shelter ───────────────────────────────────────────────────────
 ("W1-rain-ignores-shelter", MW,
  [("                    local exposed = self:exposedFraction(gx, gz2)\n                    if exposed < 1 then sheltered = sheltered + 1 end\n                    local rawDelta = MaterialWetness.pointsToRawDelta(points * exposed)",
    "                    local exposed = self:exposedFraction(gx, gz2)\n                    if exposed < 1 then sheltered = sheltered + 1 end\n                    local rawDelta = MaterialWetness.pointsToRawDelta(points)", 1)],
  "rain lands in full under a roof"),
 ("W2-shelter-whole-cell-from-any-pixel", MW,
  [("    local covered = math.max(0, math.min(1, indoor / total))\n    return 1 - covered", "    if indoor > 0 then return 0 end\n    return 1", 1)],
  "one indoor pixel covers the whole cell (no fractional dose)"),
 ("W3-zero-handle-is-shelter", MW,
  [("    if mask.handle == nil or mask.handle == 0 then return 1 end\n", "    if mask.handle == nil then return 1 end\n", 1)],
  "a mask with a zero handle is queried as if it were valid"),
 ("W4-shelter-cache-never-refreshed", MW,
  [("    self.shelterCells = {}\n    self.shelterEpoch = (self.shelterEpoch or 0) + 1\nend", "end", 1)],
  "the per-cell shelter cache survives the daily invalidation and the placeable lifecycle"),
 # ── the lifecycle wrap ─────────────────────────────────────────────────────
 ("L1-paint-does-not-invalidate", HM,
  [("        if mw ~= nil and type(mw.onIndoorMaskChanged) == \"function\" then\n            local okInv, errInv = pcall(mw.onIndoorMaskChanged, mw, area, indoor, packed[1] == true)",
    "        if false then\n            local okInv, errInv = pcall(mw.onIndoorMaskChanged, mw, area, indoor, packed[1] == true)", 1)],
  "a roof painted after a read never reaches the shelter cache"),
 ("L2-paint-invalidates-all-always", MW,
  [("    if not placed then self:invalidateShelterCache() end\nend", "    self:invalidateShelterCache()\nend", 1)],
  "every paint drops the whole cache (another cell's cached fraction is lost)"),
 ("L3-raised-paint-keeps-cache", MW,
  [("    if not originalOk then self:invalidateShelterCache() return end\n", "", 1)],
  "a paint that raised leaves the cache as it was"),
 ("L4-wrapper-swallows-error", HM,
  [("        if not packed[1] then error(packed[2], 0) end\n        return unpack(packed, 2, packed.n)\n    end\n    rawset(mask, \"setStateByArea\", wrapper)",
    "        return unpack(packed, 2, packed.n)\n    end\n    rawset(mask, \"setStateByArea\", wrapper)", 1)],
  "a paint that raised is swallowed by the wrap"),
 ("L5-hook-not-installed-by-installAll", HM,
  [("    local indoorOk = self:installIndoorMaskHook()\n", "    local indoorOk = true\n", 1)],
  "installAll leaves the indoor mask unwrapped"),
 ("L6-cleanup-not-registered", HM,
  [("    self:registerCleanup(\"IndoorMask.setStateByArea (shelter invalidation)\", function()", "    local _ = (function()", 1)],
  "the wrap registers no cleanup"),
 # ── the run write ──────────────────────────────────────────────────────────
 ("C1-run-preflight-any-count", CELLS,
  [("    if type(numPixels) ~= \"number\" or numPixels ~= want then\n        result.refused = GroundConditionCells.REFUSE_PREFLIGHT\n        return result\n    end\n\n    local okSet = pcall(function()\n        aimAtRun(",
    "    local okSet = pcall(function()\n        aimAtRun(", 1)],
  "the run write skips its preflight"),
 ("C2-run-write-marks-nothing-on-refusal", COORD,
  [("    for gx = gx0, gx1 do self:markUnavailable(gx, gz, \"WEATHER:\" .. tostring(res.refused)) end\n    return false", "    return false", 1)],
  "a refused run write leaves the cells looking settled"),
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
