# SG2-4c-3 mutation battery: Soil's `soil.groundCondition` property for StockGuard's SG-1
# (src/ground/GroundConditionProperty.lua) and its wiring in src/SoilFertilitySystem.lua (built
# in new, registered after the arm chain in initialize, withdrawn in update and delete). Rows
# live in tools/test/lua/SG2-4c3-groundcondition_property_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against
# the one selection that sees them, `node run-tests.mjs --loads src/ground/GroundConditionProperty.lua`
# (the property's own bench; no other test loads the module or src/main.lua). Run ONE mutant per
# call, in the foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence
# count) and the restore is proved by a hash. KILLED* means killed only by a Lua error (a crash,
# or a group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - register's g_server check: a client never arms the coordinator (GroundConditionCoordinator
#     :105), and a bench in the mod environment cannot clear the engine's g_server;
#   - the resolve's geometry nil and unreadable-cell refusals: the engine model's store always has
#     a geometry and reads every cell (the overlay hold, R10, covers the UNAVAILABLE outcome);
#   - logging text and comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg24c3.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg24c3.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg24c3.py --baseline  the selection, unmutated
#        py tools/test/mutate_sg24c3.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GP = "src/ground/GroundConditionProperty.lua"
SFS = "src/SoilFertilitySystem.lua"
SELECT = ["--loads", GP]

MUTATIONS = [
 ("G01-register-not-called", SFS,
  [("        self.groundConditionProperty:register(self.groundConditionCoordinator, g_currentMission)\n", "", 1)],
  "the arm chain never registers with StockGuard (E2-E6)"),
 ("G02-property-not-built", SFS,
  [("    self.groundConditionProperty = GroundConditionProperty and GroundConditionProperty.new() or nil\n",
    "    self.groundConditionProperty = nil\n", 1)],
  "the system never builds the property (E2)"),
 ("G03-update-not-wired", SFS,
  [("    if self.groundConditionProperty ~= nil then self.groundConditionProperty:update() end\n", "", 1)],
  "a stand-down never withdraws the property (L1)"),
 ("G04-unload-not-wired", SFS,
  [("        self.groundConditionProperty:withdraw(\"unload\")\n", "", 1)],
  "unload never withdraws the property (L5)"),
 ("G05-applicability-dropped", GP,
  [("        applicability       = { residentStoreKinds = { GP.STORE_KIND } },\n", "", 1)],
  "the registration declares no residency, so SG-1 would resolve every stock live (E3)"),
 ("G06-revision-a-table", GP,
  [("        getResidentRevision = function(_context) return self:revision() end,\n",
    "        getResidentRevision = function(_context) return self.coordinator:getOwnerRevision() end,\n", 1)],
  "the revision is the coordinator's table, never equal under SG-1's ~= (V1)"),
 ("G07-revision-ignores-liveness", GP,
  [("    return table.concat({ self:isLive() and \"live\" or \"down\", tostring(r.epoch), tostring(r.changeCounter),\n",
    "    return table.concat({ \"live\", tostring(r.epoch), tostring(r.changeCounter),\n", 1)],
  "an owner standing down does not move the revision (V5)"),
 ("G08-revision-ignores-cursors", GP,
  [("        tostring(r.ageThroughDay), tostring(r.wetThroughDay) }, \":\")\n", "        }, \":\")\n", 1)],
  "the age and wetness cursors moving do not move the revision (V3, V4)"),
 ("G09-unavailable-cell-read", GP,
  [("            if c:isUnavailable(gx, gz) then return nil, GP.UNAVAILABLE end\n", "", 1)],
  "a cell marked unavailable, or the overlay hold, is read as if vouched for (R3, R10)"),
 ("G10-footprint-kind-unchecked", GP,
  [("    if type(fp) ~= \"table\" or fp.kind ~= GP.GROUND_CELL or not isFinite(fp.x) or not isFinite(fp.z) then\n",
    "    if type(fp) ~= \"table\" or not isFinite(fp.x) or not isFinite(fp.z) then\n", 1)],
  "a footprint that is not a ground cell is resolved as one (R6)"),
 ("G11-straddle-not-seen", GP,
  [("    local gx1, gz1 = cells:worldToCell(geometry, fp.x + half - inset, fp.z + half - inset)\n",
    "    local gx1, gz1 = cells:worldToCell(geometry, fp.x - half, fp.z - half)\n", 1)],
  "a pixel straddling two cells reads only the first (R4, R4b)"),
 ("G12-edge-inclusive", GP,
  [("    local inset = half * 1e-6\n", "    local inset = 0\n", 1)],
  "a pixel ending on a cell edge also reads the next cell (R5)"),
 ("G13-no-floor", GP,
  [("    local combined = GroundConditionCoordinator.combine(nil, parts)\n",
    "    local combined = { ageRaw = parts[1].ageRaw, wetnessRaw = parts[1].wetnessRaw }\n", 1)],
  "the cells are not combined by the floor: the first cell's raw bytes are returned (R2, R4)"),
 ("G14-knowledge-ignores-wetness", GP,
  [("    local known = ageKnown(payload.ageRaw) and wetKnown(payload.wetnessRaw)\n",
    "    local known = ageKnown(payload.ageRaw)\n", 1)],
  "a known age over unknown wetness is called KNOWN (R9)"),
 ("G15-ceiling-not-a-record", GP,
  [("    return isInt(raw) and raw > AGE_UNKNOWN and raw <= AGE_CEILING\n",
    "    return isInt(raw) and raw > AGE_UNKNOWN and raw < AGE_CEILING\n", 1)],
  "the age ceiling reads as unknown (R8, C7)"),
 ("G16-coverage-claims-unknown", GP,
  [("        rec.knownAmount = known and amount or 0\n", "        rec.knownAmount = amount\n", 1)],
  "unknown material is counted as known coverage (R2)"),
 ("G17-no-capture-stamp", GP,
  [("        ageDay     = rev.ageThroughDay,\n", "", 1)],
  "the payload carries no age stamp for P-GROUND-1 (R1b)"),
 ("G18-no-transit-ageing", GP,
  [("            ageRaw     = GroundMovementCarrier.agedRaw(p.ageRaw, p.ageDay, newest),\n",
    "            ageRaw     = p.ageRaw,\n", 1)],
  "an older load is not aged to the newer stamp, and a stampless age stays known (C1, C6)"),
 ("G19-oldest-stamp", GP,
  [("        if isInt(p.ageDay) and (newest == nil or p.ageDay > newest) then newest = p.ageDay end\n",
    "        if isInt(p.ageDay) and (newest == nil or p.ageDay < newest) then newest = p.ageDay end\n", 1)],
  "the mixture takes the oldest stamp (C1)"),
 ("G20-destination-dropped", GP,
  [("        add(destinationBefore.observedAmount, props[GP.PROPERTY_ID], destinationBefore.amountUnit)\n", "", 1)],
  "the bucket's own load is left out of the floor (C2, C5b)"),
 ("G21-zero-litres-imported", GP,
  [("        if not isFinite(litres) or litres <= 0 then return end\n",
    "        if not isFinite(litres) or litres < 0 then return end\n", 1)],
  "a zero-litre portion imports its unknown (C4)"),
 ("G22-qualified-read-by-payload", GP,
  [("    if rec.knowledge ~= \"KNOWN\" and rec.knowledge ~= \"UNKNOWN\" then return nil, nil, nil end\n", "", 1)],
  "a record SG-1 qualified UNAVAILABLE, PARTIAL or HISTORICAL is read by its payload (C5b)"),
 ("G23-transform-claims-condition", GP,
  [("    return GP.record({ ageRaw = AGE_UNKNOWN, wetnessRaw = WET_UNKNOWN },\n",
    "    return GP.record({ ageRaw = 5, wetnessRaw = 60 },\n", 1)],
  "a conversion with no basis claims a known condition (T1)"),
 ("G24-disclosure-discloses", GP,
  [("        disclosure          = function() return nil end,\n",
    "        disclosure          = function(_, r) return r end,\n", 1)],
  "the record is disclosed to a player view (D1)"),
 ("G25-validate-knowledge-unchecked", GP,
  [("    if (rec.knowledge == \"KNOWN\") ~= (ageKnown(p.ageRaw) and wetKnown(p.wetnessRaw)) then\n",
    "    if false then\n", 1)],
  "a KNOWN claim over an unknown age validates (VAL1)"),
 ("G26-validate-wetness-unchecked", GP,
  [("    if p.wetnessRaw ~= WET_UNKNOWN and not wetKnown(p.wetnessRaw) then return false, \"WETNESS\" end\n", "", 1)],
  "a reserved wetness band validates (VAL1)"),
 ("G27-stand-down-not-seen", GP,
  [("    return md ~= nil and md:isArmed() and mw ~= nil and mw:isArmed()\n",
    "    return md ~= nil and mw ~= nil\n", 1)],
  "an owner that stood down still counts as live (V5, L1, L3)"),
 ("G28-register-unarmed", GP,
  [("    if coordinator == nil or not coordinator:isArmed() then return false, \"NOT_ARMED\" end\n",
    "    if coordinator == nil then return false, \"NOT_ARMED\" end\n", 1)],
  "an unarmed coordinator (the family gated off) registers anyway (E8)"),
 ("G29-no-register-bump", GP,
  [("    coordinator:bumpRevision(\"provider-registered\")\n", "", 1)],
  "registering does not move the owner revision (E5)"),
 ("G30-no-withdraw-bump", GP,
  [("    if self.coordinator ~= nil then self.coordinator:bumpRevision(\"provider-withdrawn\") end\n", "", 1)],
  "withdrawing does not move the owner revision (L2, L6)"),
 ("G31-unregister-skipped", GP,
  [("    pcall(sg.unregisterOwner, lease)\n", "", 1)],
  "the lease is forgotten but never returned to StockGuard (L1, L5)"),
 ("G32-refusal-taken-as-lease", GP,
  [("    if not ok or type(lease) ~= \"table\" then\n", "    if not ok then\n", 1)],
  "a registry refusal is not warned about (E7)"),
 ("G33-stockguard-absence-unchecked", GP,
  [("    if type(sg) ~= \"table\" or type(sg.registerProperty) ~= \"function\" or type(sg.unregisterOwner) ~= \"function\" then\n",
    "    if false then\n", 1)],
  "Soil alone tries to register on a missing handle (E0)"),
 ("G34-double-register", GP,
  [("    if self.lease ~= nil then return true, \"ALREADY_REGISTERED\" end\n", "", 1)],
  "a second register calls StockGuard again (E9)"),
 ("G35-withdraw-without-lease", GP,
  [("    if lease == nil then return false end\n", "", 1)],
  "Soil alone's unload withdraws a lease it never had (L7)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o = old.encode("utf-8")
        n = new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_selection():
    r = subprocess.run(["node", "run-tests.mjs"] + SELECT, cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "group raised" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:36s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, fails, out = run_selection()
        tail = [l for l in out.strip().splitlines() if l.strip()]
        print(re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, _ = run_selection()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
