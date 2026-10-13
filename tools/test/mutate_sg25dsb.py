# SG2-5 slice 5d's Soil half (5d-soil-b) mutation battery: soil.groundCondition's combine adopts the
# collected account StockGuard's settle report names (Q2), and the bale birth reads the chamber's SG-1
# record through Soil's consumer (Q4/Q5) (src/ground/GroundConditionProperty.lua,
# src/ground/BalerCollection.lua). Rows live in tools/test/lua/SG2-5d-soil-b_chamber_account_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against the
# one selection that sees them: `--loads src/ground/GroundConditionProperty.lua` for the property,
# `--loads src/ground/BalerCollection.lua` for the bale birth. Run ONE mutant per call, in the
# foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the `isInt(e.allocation) and e.allocation >= 1` guard: any other value names a ref no
#     contribution carries (SGOperations.lua:942 stamps integer indices), so it matches nothing;
#   - readChamberAccount's NO_LOOKUP and NO_CONSUMER checks: the pcall on the lookup answers a
#     missing function as LOOKUP_ERROR, and StockGuard's readMaterial refuses a missing lease
#     (SGOperations.lua:1632), so both answer the same nil; the rows F2 and F3 pin the outcome;
#   - its `acc == nil` check: accountProblem(nil) is ACCOUNT, the same nil (row F7);
#   - withdraw's `self.consumerLease = nil`: a withdrawn property reads STOCKGUARD_ABSENT first;
#   - BC.chamberAccount's property-absent guard: SoilFertilitySystem.new always builds the property
#     when its file is loaded (SoilFertilitySystem.lua:210);
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg25dsb.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25dsb.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25dsb.py --baseline  both selections, unmutated
#        py tools/test/mutate_sg25dsb.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

PROP = "src/ground/GroundConditionProperty.lua"
BC = "src/ground/BalerCollection.lua"
SELECT = {PROP: ["--loads", PROP], BC: ["--loads", BC]}

MUTATIONS = [
 # ── Q2: combine adopts the named leg's account ──
 ("Q01-evidence-ignored", PROP,
  [("    local named = GP.evidenceAccounts(context)\n", "    local named = {}\n", 1)],
  "combine never reads the settle report's accounts (C1, E2)"),
 ("Q02-no-operation-id", PROP,
  [("            local ref = context.operationId .. \":a\" .. tostring(e.allocation)\n",
    "            local ref = \":a\" .. tostring(e.allocation)\n", 1)],
  "the evidence names a ref no contribution carries (C1, E2)"),
 ("Q03-duplicates-taken", PROP,
  [("            if out[ref] == nil then out[ref] = e.account else out[ref] = false end\n",
    "            out[ref] = e.account\n", 1)],
  "a doubly named allocation takes the last account (C5)"),
 ("Q04-problem-adopted", PROP,
  [("    if acc ~= false and accountProblem(acc) == nil\n", "    if acc ~= false\n", 1)],
  "a malformed account is adopted (C3)"),
 ("Q05-carrier-unchecked", PROP,
  [("       and math.abs(acc.carrierLitres - litres) <= ACCOUNT_TOLERANCE * math.max(1, litres) then\n",
    "       and true then\n", 1)],
  "an account of other litres than the leg's is adopted (C4)"),
 ("Q06-failed-is-dropped", PROP,
  [("    return { carrierLitres = litres, knownCarrierLitres = 0, unknownCarrierLitres = litres,\n"
    "             refusedCarrierLitres = 0, knownWeightedPctSum = 0 }\n",
    "    return nil\n", 1)],
  "a named leg that fails its checks loses its litres from the account instead of entering unknown (C3, C4)"),
 ("Q07-destination-adopts", PROP,
  [("        add(destinationBefore.observedAmount, props[GP.PROPERTY_ID], destinationBefore.amountUnit)\n",
    "        add(destinationBefore.observedAmount, props[GP.PROPERTY_ID], destinationBefore.amountUnit, (function() for _, v in pairs(named) do return v end end)())\n", 1)],
  "destinationBefore adopts a named account (C2)"),
 ("Q08-part-not-looked-up", PROP,
  [("            if type(part.allocationRef) == \"string\" then evidence = named[part.allocationRef] end\n", "", 1)],
  "no contribution is matched to its evidence (C1, E2)"),
 ("Q09-false-becomes-nil", PROP,
  [("            if type(part.allocationRef) == \"string\" then evidence = named[part.allocationRef] end\n",
    "            if type(part.allocationRef) == \"string\" then evidence = named[part.allocationRef] or nil end\n", 1)],
  "a doubly named allocation falls back to the leg's own record (C5): the bug the bench found"),
 # ── Q4/Q5: the consumer and the chamber read ──
 ("Q10-no-consumer", PROP,
  [("    self:registerBaleConsumer(sg)\n", "", 1)],
  "the property registers no bale-birth consumer (E1, E2)"),
 ("Q11-consumer-schema", PROP,
  [("        requiredSchemas = { [GP.PROPERTY_ID] = GP.SCHEMA_VERSION },\n", "        requiredSchemas = { [GP.PROPERTY_ID] = 2 },\n", 1)],
  "the consumer asks for another schema (E1)"),
 ("Q12-consumer-purpose", PROP,
  [("            return { stockRefs = { query.stockRef }, purpose = \"BALE_BIRTH\" }\n",
    "            return { stockRefs = { query.stockRef }, purpose = \"READ\" }\n", 1)],
  "the consumer's read context names another purpose (E1)"),
 ("Q13-read-state-ignored", PROP,
  [("    if not okR or type(read) ~= \"table\" or read.state ~= \"READY\" or type(read.records) ~= \"table\" then return nil, \"READ\" end\n",
    "    if not okR or type(read) ~= \"table\" or type(read.records) ~= \"table\" then return nil, \"READ\" end\n", 1)],
  "a read StockGuard refuses is taken (F10)"),
 ("Q14-stale-taken", PROP,
  [("    if type(snap) ~= \"table\" or snap.state ~= \"READY\" or type(snap.properties) ~= \"table\" then return nil, \"NOT_READY\" end\n",
    "    if type(snap) ~= \"table\" or type(snap.properties) ~= \"table\" then return nil, \"NOT_READY\" end\n", 1)],
  "a stale reference is taken (F8)"),
 ("Q15-qualified-taken", PROP,
  [("    if type(rec) ~= \"table\" or (rec.knowledge ~= \"KNOWN\" and rec.knowledge ~= \"UNKNOWN\") then return nil, \"QUALIFIED\" end\n",
    "    if type(rec) ~= \"table\" then return nil, \"QUALIFIED\" end\n", 1)],
  "a record SG-1 qualified is taken (F5)"),
 ("Q16-account-unchecked", PROP,
  [("    if GP.accountProblem(acc) ~= nil then return nil, \"ACCOUNT\" end\n", "", 1)],
  "an account that fails its own checks is taken (F6)"),
 ("Q17-consumer-kept", PROP,
  [("        pcall(sg.unregisterOwner, self.consumerLease)\n", "", 1)],
  "the withdraw leaves the consumer lease registered (F11)"),
 ("Q18-lookup-args", PROP,
  [("    local okL, ref, whyL = pcall(sg.fillUnitStockRef, vehicle, fillUnitIndex)\n",
    "    local okL, ref, whyL = pcall(sg.fillUnitStockRef, vehicle)\n", 1)],
  "the lookup is not told which fill unit (E3)"),
 ("Q19-read-other-property", PROP,
  [("    local okR, read = pcall(sg.readMaterial, lease, { stockRef = ref, propertyIds = { GP.PROPERTY_ID } })\n",
    "    local okR, read = pcall(sg.readMaterial, lease, { stockRef = ref })\n", 1)],
  "the read does not name the one property it reads (E3)"),
 # ── the bale birth ──
 ("B01-not-consulted", BC,
  [("            local fromStockGuard = BC.chamberAccount(vehicle, spec)\n", "            local fromStockGuard = nil\n", 1)],
  "the bale birth never reads StockGuard's chamber record (E2)"),
 ("B02-not-reconciled", BC,
  [("                if level ~= nil then BC.accountReconcile(fromStockGuard, level) end\n", "", 1)],
  "StockGuard's account is bound without reconciling it to the chamber's level (R1)"),
 ("B03-fields-crossed", BC,
  [("             refused = acc.refusedCarrierLitres, weighted = acc.knownWeightedPctSum }\n",
    "             refused = acc.refusedCarrierLitres, weighted = acc.knownCarrierLitres }\n", 1)],
  "the weighted sum is taken from the wrong field (E2)"),
 ("B04-no-answer-guard", BC,
  [("    if not ok or type(acc) ~= \"table\" then return nil end\n", "", 1)],
  "a fallback's nil answer is read as an account (F rows)"),
 ("B05-unit-not-passed", BC,
  [("    local ok, acc = pcall(prop.readChamberAccount, prop, vehicle, spec.fillUnitIndex)\n",
    "    local ok, acc = pcall(prop.readChamberAccount, prop, vehicle, nil)\n", 1)],
  "the chamber's fill unit is not passed to the lookup (E3)"),
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
        for rel in (PROP, BC):
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
