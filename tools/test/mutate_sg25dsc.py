# SG2-5 slice 5d-soil-c mutation battery: Soil's collected reader resolves each receipt by its own
# producer (src/MaterialWetness.lua: sealAllocation's producer tag, resolveAllocation's routing).
# Rows live in tools/test/lua/SG2-5d-soil-c_receipt_routing_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against the
# smallest committed selection that sees them, `--loads src/ground/BalerCollection.lua` (five files:
# this PR's bench and the four that drive Soil's own seal path). `--loads src/MaterialWetness.lua`
# would run 20. Run ONE mutant per call, in the foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the Soil branch's own lines after the routing (unchanged by this PR);
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg25dsc.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25dsc.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25dsc.py --baseline  the selection, unmutated
#        py tools/test/mutate_sg25dsc.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MW = "src/MaterialWetness.lua"
SELECT = {MW: ["--loads", "src/ground/BalerCollection.lua"]}

MUTATIONS = [
 ("R01-receipt-untagged", MW,
  [("             revision = snapshot.revision, total = acceptedCarrierLitres, parts = receiptParts,\n             producer = MaterialWetness.PRODUCER_SOIL }\n",
    "             revision = snapshot.revision, total = acceptedCarrierLitres, parts = receiptParts }\n", 1)],
  "Soil's receipt names no producer, so StockGuard is asked for it and every Soil bale goes unknown (E1-E4, T1)"),
 ("R02-tag-ignored", MW,
  [("    if not soilSealed and sg ~= nil and type(sg.readCollectionReceipt) == \"function\" then\n",
    "    if sg ~= nil and type(sg.readCollectionReceipt) == \"function\" then\n", 1)],
  "the routing ignores the producer: the 2dd42a22 defect (E1-E4, T2, T3)"),
 ("R03-every-receipt-soil", MW,
  [("    local soilSealed = type(receipt) == \"table\" and receipt.producer == MaterialWetness.PRODUCER_SOIL\n",
    "    local soilSealed = type(receipt) == \"table\"\n", 1)],
  "every receipt resolves from Soil's store, StockGuard's included (S1)"),
 ("R04-any-producer-soil", MW,
  [("    local soilSealed = type(receipt) == \"table\" and receipt.producer == MaterialWetness.PRODUCER_SOIL\n",
    "    local soilSealed = type(receipt) == \"table\" and receipt.producer ~= nil\n", 1)],
  "a receipt naming another producer resolves from Soil's store (S3)"),
 ("R05-tag-value", MW,
  [("MaterialWetness.PRODUCER_SOIL = \"SOIL\"\n", "MaterialWetness.PRODUCER_SOIL = \"STOCKGUARD\"\n", 1)],
  "Soil names itself with another producer's name (T1, S3)"),
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
        for rel in (MW,):
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
