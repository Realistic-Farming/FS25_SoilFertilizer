# SG2-5 slice 5d-soil mutation battery: Soil's half of the leased collection read
# (src/ground/GroundConditionAdmission.lua: the collected snapshot at admit, the delivery's
# collection, the published readCollectedCondition; src/ground/GroundConditionProperty.lua: the
# optional collected account in soil.groundCondition; src/MaterialWetness.lua: the coverage
# shape's export). Rows live in tools/test/lua/SG2-5d-soil_collected_read_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against
# the one selection that sees them: `--loads src/ground/GroundConditionAdmission.lua` for the
# admission and the export, `--loads src/ground/GroundConditionProperty.lua` for the property.
# Run ONE mutant per call, in the foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence
# count) and the restore is proved by a hash. KILLED* means killed only by a Lua error (a crash,
# or a group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - new()'s `self.collected, self.collectedOrder = {}, {}`: arm() sets both before the table is
#     published, so no read or capture can reach new()'s pair; an equivalent mutant;
#   - _readCollectedCondition's NO_GROUND_FAMILY branch and _captureCollected's matching `mw == nil`
#     return: an armed admission's coordinator always holds the armed MaterialWetness
#     (GroundConditionCoordinator:arm), so both are unreachable while armed, and unarmed is refused
#     one line earlier (E11);
#   - _captureCollected's `if snap == nil then return end`: with a source cell holding the type,
#     the type has a height type and the family is armed, so collectedSnapshot does not refuse
#     (MaterialWetness.nativeTypeUsable); a defensive guard whose removal only crashes on an input
#     none produces;
#   - its `type(snapshotRef) == "string"` guard: indexing the store with any other value finds
#     nothing either, so SNAPSHOT_UNKNOWN answers the same; an equivalent mutant;
#   - collectionOf's `snap.parts[id] ~= nil`: a cell the pickup lowered had material at admit, so
#     the snapshot holds it; a defensive guard with no reachable input;
#   - a mutant that removes the bound's trimming line: the loop would never end (a hang, not a
#     verdict); the bound is pinned by D09 and D10 instead;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg25ds.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25ds.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25ds.py --baseline  both selections, unmutated
#        py tools/test/mutate_sg25ds.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

ADM = "src/ground/GroundConditionAdmission.lua"
PROP = "src/ground/GroundConditionProperty.lua"
MW = "src/MaterialWetness.lua"
SELECT = {ADM: ["--loads", ADM], PROP: ["--loads", PROP], MW: ["--loads", ADM]}

MUTATIONS = [
 # ── the snapshot, captured on a collector's pickup ──
 ("D01-no-capture", ADM,
  [("                self:_captureCollected(lease, cells)   -- [SG2-5d] before the projection clears them\n", "", 1)],
  "a collection pickup captures no snapshot: it names no collection (E1)"),
 ("D02-capture-at-admit", ADM,
  [("    lease.derived = cells\nend\n",
    "    lease.derived = cells\n"
    "    if lease.primitiveKind == GroundConditionAdmission.KIND_TIP_LINE and GroundConditionAdmission.isCollector(lease.owner) then\n"
    "        self:_captureCollected(lease, cells)\n"
    "    end\nend\n", 1)],
  "the capture runs at admit for every collector line, a drop included (B5)"),
 ("D02b-any-vehicle-pickup", ADM,
  [("            if GroundConditionAdmission.isCollector(lease.owner) then\n                self:_captureCollected",
    "            if true then\n                self:_captureCollected", 1)],
  "every vehicle's pickup captures a snapshot and names a collection (E9)"),
 ("D02c-bare-ground-captured", ADM,
  [("    if #src == 0 then return end\n", "", 1)],
  "a pickup over bare ground stores an empty snapshot (B6)"),
 ("D03-baler-not-collector", ADM,
  [("(owner.spec_baler ~= nil or owner.spec_forageWagon ~= nil)", "(owner.spec_forageWagon ~= nil)", 1)],
  "a Baler is not a collection machine (E1)"),
 ("D04-wagon-not-collector", ADM,
  [("(owner.spec_baler ~= nil or owner.spec_forageWagon ~= nil)", "(owner.spec_baler ~= nil)", 1)],
  "a ForageWagon is not a collection machine (E9b)"),
 ("D05-every-vehicle-collects", ADM,
  [("    return type(owner) == \"table\" and (owner.spec_baler ~= nil or owner.spec_forageWagon ~= nil)\n",
    "    return type(owner) == \"table\"\n", 1)],
  "a shovel's pickup names a collection (E9)"),
 ("D06-empty-cells-captured", ADM,
  [("        if finite(before) and before > GroundMovementProjector.EPSILON then\n",
    "        if finite(before) then\n", 1)],
  "cells holding none of the type enter the snapshot (P1b)"),
 ("D07-snapshot-not-on-lease", ADM,
  [("    lease.collected = snap\n", "", 1)],
  "the lease does not hold its snapshot: the pickup names no collection (E1)"),
 ("D08-snapshot-not-stored", ADM,
  [("    self.collected[snap.id] = snap\n", "", 1)],
  "the snapshot is not kept for the read: SNAPSHOT_UNKNOWN (E3)"),
 ("D09-bound-off-by-one", ADM,
  [("    while #self.collectedOrder > GroundConditionAdmission.MAX_COLLECTED do\n",
    "    while #self.collectedOrder >= GroundConditionAdmission.MAX_COLLECTED do\n", 1)],
  "the store keeps one fewer than its bound (B1)"),
 ("D10-unbounded", ADM,
  [("    while #self.collectedOrder > GroundConditionAdmission.MAX_COLLECTED do\n",
    "    while false do\n", 1)],
  "the store is never trimmed (B1)"),
 # ── the delivery's collection ──
 ("D11-unlowered-parts", ADM,
  [("            if removed > GroundMovementProjector.EPSILON then parts[#parts + 1] = { id = id, raw = removed } end\n",
    "            parts[#parts + 1] = { id = id, raw = removed }\n", 1)],
  "a captured cell the pickup did not lower becomes a zero part (P1)"),
 ("D12-raw-is-before", ADM,
  [("            local removed = (b[ft] or 0) - (a[ft] or 0)\n",
    "            local removed = (b[ft] or 0)\n", 1)],
  "a part's raw is the cell's litres at admit, not what the pickup took (P1)"),
 ("D13-unsorted", ADM,
  [("    table.sort(parts, function(p, q) return p.id < q.id end)\n", "", 1)],
  "the parts arrive in envelope order, not the seal's canonical order (P2)"),
 ("D14-revision-shared", ADM,
  [("             revision = { epoch = r.epoch, changeCounter = r.changeCounter, ageThroughDay = r.ageThroughDay, wetThroughDay = r.wetThroughDay } }\n",
    "             revision = r }\n", 1)],
  "the caller holds Soil's own revision table and can move the capture's stamp (E5b)"),
 ("D15-no-collection-in-result", ADM,
  [("                result.collection = GroundConditionAdmission.collectionOf(lease, cells, obs.fillTypeIndex)\n", "", 1)],
  "the pickup's result does not name its collection (E1)"),
 ("D16-collection-without-snapshot", ADM,
  [("            if lease.collected ~= nil then\n                result.collection",
    "            if true then\n                result.collection", 1)],
  "a pickup without a snapshot builds a collection from nothing (E9)"),
 # ── the published read ──
 ("D17-not-published", ADM,
  [("        readCollectedCondition = readCollected,\n", "", 1)],
  "the table does not carry the read (E0b)"),
 ("D18-colon-read", ADM,
  [("    if snapshotRef ~= nil and snapshotRef == self.groundCondition then\n",
    "    if false then\n", 1)],
  "a colon call reads the table as a snapshot reference (E8)"),
 ("D19-unarmed-read", ADM,
  [("    if not self.armed then return unavailable(GroundConditionAdmission.REFUSE_NOT_ARMED) end\n", "", 1)],
  "a reference kept past a stand-down is read (E11)"),
 ("D20-unknown-snapshot-passed", ADM,
  [("    if snap == nil then return unavailable(GroundConditionAdmission.READ_SNAPSHOT_UNKNOWN) end\n", "", 1)],
  "an unknown reference reaches the reader as a nil snapshot (E6)"),
 ("D21-standdown-keeps", ADM,
  [("    self.openLeases = 0\n    self.collected, self.collectedOrder = {}, {}\nend\n",
    "    self.openLeases = 0\nend\n", 1)],
  "a stand-down keeps its snapshots (B2)"),
 ("D22-rearm-keeps", ADM,
  [("    self.openLeases = 0\n    self.collected, self.collectedOrder = {}, {}\n\n    if g_server == nil then\n",
    "    self.openLeases = 0\n\n    if g_server == nil then\n", 1)],
  "a re-arm keeps the snapshots of the arm before (B3)"),
 ("M01-shape-not-exported", MW,
  [("MaterialWetness.coverageResult = coverageResult\n", "", 1)],
  "the published read's own refusals have no coverage shape (E6, E8, E11)"),
 # ── the collected account (G3) ──
 ("G01-account-not-validated", PROP,
  [("    if p.account ~= nil then\n        local why = GP.accountProblem(p.account)\n        if why ~= nil then return false, why end\n    end\n", "", 1)],
  "a malformed account validates (C1, C1b)"),
 ("G02-no-sum-check", PROP,
  [("    if math.abs(parts - acc.carrierLitres) > ACCOUNT_TOLERANCE * math.max(1, acc.carrierLitres) then return \"ACCOUNT_SUM\" end\n", "", 1)],
  "an account whose parts do not sum to its carrier validates (C1)"),
 ("G03-no-pct-check", PROP,
  [("    if acc.knownWeightedPctSum > 100 * acc.knownCarrierLitres + ACCOUNT_TOLERANCE * math.max(1, acc.knownCarrierLitres) then return \"ACCOUNT_PCT\" end\n", "", 1)],
  "a pct sum past 100 per known litre validates (C1)"),
 ("G04-sum-no-tolerance", PROP,
  [("    if math.abs(parts - acc.carrierLitres) > ACCOUNT_TOLERANCE * math.max(1, acc.carrierLitres) then",
    "    if math.abs(parts - acc.carrierLitres) > 0 then", 1)],
  "float error in a scaled account's sum is refused (C1c)"),
 ("G05-pct-no-tolerance", PROP,
  [("    if acc.knownWeightedPctSum > 100 * acc.knownCarrierLitres + ACCOUNT_TOLERANCE * math.max(1, acc.knownCarrierLitres) then",
    "    if acc.knownWeightedPctSum > 100 * acc.knownCarrierLitres then", 1)],
  "float error at the pct bound is refused (C1c)"),
 ("G06-no-finite-check", PROP,
  [("        if not isFinite(acc[f]) or acc[f] < 0 then return \"ACCOUNT\" end\n",
    "        if acc[f] < 0 then return \"ACCOUNT\" end\n", 1)],
  "a missing, NaN or infinite field is not refused (C1b)"),
 ("G07-negative-allowed", PROP,
  [("        if not isFinite(acc[f]) or acc[f] < 0 then return \"ACCOUNT\" end\n",
    "        if not isFinite(acc[f]) then return \"ACCOUNT\" end\n", 1)],
  "a negative field validates (C1)"),
 ("G08-not-table-allowed", PROP,
  [("    if type(acc) ~= \"table\" then return \"ACCOUNT\" end\n", "", 1)],
  "an account that is not a table is indexed (C1b)"),
 ("G09-qualified-account-read", PROP,
  [("type(rec.payload) ~= \"table\" or (rec.knowledge ~= \"KNOWN\" and rec.knowledge ~= \"UNKNOWN\") then return nil end\n",
    "type(rec.payload) ~= \"table\" then return nil end\n", 1)],
  "a record SG-1 qualified is read for its account (C5)"),
 ("G10-unknown-record-skipped", PROP,
  [("(rec.knowledge ~= \"KNOWN\" and rec.knowledge ~= \"UNKNOWN\") then return nil end\n",
    "rec.knowledge ~= \"KNOWN\" then return nil end\n", 1)],
  "an UNKNOWN record's account is ignored (C11)"),
 ("G11-malformed-account-read", PROP,
  [("    if acc == nil or accountProblem(acc) ~= nil or acc.carrierLitres <= 0 then return nil end\n",
    "    if acc == nil or acc.carrierLitres <= 0 then return nil end\n", 1)],
  "a malformed account's figures are summed (C10)"),
 ("G12-zero-carrier-divided", PROP,
  [("    if acc == nil or accountProblem(acc) ~= nil or acc.carrierLitres <= 0 then return nil end\n",
    "    if acc == nil or accountProblem(acc) ~= nil then return nil end\n", 1)],
  "a zero-litre account is divided by zero (C9)"),
 ("G13-not-scaled", PROP,
  [("    local f = litres / acc.carrierLitres\n", "    local f = 1\n", 1)],
  "a part's account is not scaled to its litres (C2)"),
 ("G14-parts-carry-none", PROP,
  [("ageDay = d, account = accountFor(rec, litres) }\n", "ageDay = d, account = nil }\n", 1)],
  "combine reads no part's account (C2)"),
 ("G15-no-unknown-fill", PROP,
  [("                acc.unknownCarrierLitres = acc.unknownCarrierLitres + p.litres\n", "", 1)],
  "an account-less part's litres are not unknown (C3)"),
 ("G16-no-carrier-fill", PROP,
  [("                acc.carrierLitres = acc.carrierLitres + p.litres\n", "", 1)],
  "an account-less part's litres are not carrier (C3)"),
 ("G17-account-always", PROP,
  [("    if anyAccount then\n", "    if true then\n", 1)],
  "a combination of account-less parts carries an all-unknown account (C4)"),
 ("G18-account-dropped", PROP,
  [("        payload.account = acc\n", "", 1)],
  "the summed account is not carried (C2)"),
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


def run_selection(select):
    r = subprocess.run(["node", "run-tests.mjs"] + select, cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "group raised" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
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
        worst = 0
        for rel in (ADM, PROP):
            rc, fails, out = run_selection(SELECT[rel])
            tail = [l for l in out.strip().splitlines() if l.strip()]
            print(rel + ": " + (re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)"))
            worst = max(worst, rc)
        return worst
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
        rc, fails, _ = run_selection(SELECT[rel])
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    # Assertion failures first: a kill is attributed to a row, not to a crash elsewhere.
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
