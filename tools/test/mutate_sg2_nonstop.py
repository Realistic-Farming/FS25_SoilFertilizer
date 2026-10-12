# SG-2 non-stop baler framing, PR 1 (Soil's half) mutation battery: a non-stop baler's partial round
# bale takes the buffer's share from StockGuard's buffer record, read BEFORE the pad debits the buffer
# (src/ground/BalerCollection.lua: unitAccount, preBufferAccount, aroundUnloading, bufferChange's pad
# branch), and a raise in either pre-pad read logs one warning (MAINTENANCE row 219). Rows live in
# tools/test/lua/SG2-nonstop-soil_buffer_share_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against the
# one selection that sees them, `--loads src/ground/BalerCollection.lua`. Run ONE mutant per call, in
# the foreground.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - Soil's own buffer account not debited when StockGuard's share is taken: the reconcile to the
#     buffer's native level right after (bufferChange's last line) makes the same uniform withdrawal;
#   - preBufferAccount's `acc == nil` early return: without it accountReconcileRecord indexes nil, the
#     pcall in aroundUnloading answers false, and pad.bufferAccount stays nil: rows N2 and N3's result
#     plus a warning, which row X2 already pins for a raising capture;
#   - BC.chamberAccount now calling BC.unitAccount: the SG2-5d and SG2-5e benches in this selection
#     pin it unchanged;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg2_nonstop.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg2_nonstop.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg2_nonstop.py --baseline  the selection, unmutated
#        py tools/test/mutate_sg2_nonstop.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BC = "src/ground/BalerCollection.lua"
SELECT = {BC: ["--loads", BC]}

SHARE = "            if st.pad.bufferAccount ~= nil then taken = BC.accountTake(st.pad.bufferAccount, -appliedDelta) end\n"
BUFCAPTURE = "        local okB, bufferAcc = pcall(BC.preBufferAccount, vehicle, spec)\n"
BUFSTORE = ("        if okB then\n"
            "            pad.bufferAccount = bufferAcc\n"
            "        else\n")
CHAMBERLOG = "            SoilLogger.warning(\"[BalerCollection] pre-pad chamber read failed, Soil's own account used: %s\", tostring(acc))\n"
BUFFERLOG = "            SoilLogger.warning(\"[BalerCollection] pre-pad buffer read failed, Soil's own account used: %s\", tostring(bufferAcc))\n"

MUTATIONS = [
 ("N01-share-from-own", BC,
  [(SHARE, "", 1)],
  "Bob's mutant: with StockGuard present the share is still taken from Soil's own buffer account (E1, E2, P1, R1)"),
 ("N02-no-buffer-pcall", BC,
  [(BUFCAPTURE, "        local okB, bufferAcc = true, BC.preBufferAccount(vehicle, spec)\n", 1)],
  "a raising buffer capture stops the engine's unload (X2)"),
 ("N03-failure-taken-as-account", BC,
  [(BUFSTORE, "        pad.bufferAccount = bufferAcc\n"
              "        if okB then\n"
              "        else\n", 1)],
  "a failed buffer capture's error text is taken as the account (X2)"),
 ("N04-no-chamber-log", BC,
  [(CHAMBERLOG, "", 1)],
  "row 219: a raise in the chamber capture is swallowed with no log line (X3)"),
 ("N05-no-buffer-log", BC,
  [(BUFFERLOG, "", 1)],
  "a raise in the buffer capture is swallowed with no log line (X2)"),
 ("N06-no-buffer-reconcile", BC,
  [("    if ok and finite(level) then BC.accountReconcileRecord(acc, level) end\n    return acc\nend", "    return acc\nend", 1)],
  "the buffer record's account is not reconciled to the buffer's pre-pad level (R1)"),
 ("N07-buffer-reads-the-chamber", BC,
  [("    local acc = BC.unitAccount(vehicle, index)\n", "    local acc = BC.unitAccount(vehicle, spec.fillUnitIndex)\n", 1)],
  "the buffer capture reads the chamber's stock (E1, E3)"),
 ("N08-capture-not-in-scope", BC,
  [("        st.pad = pad\n", "        st.pad = { account = pad.account }\n", 1)],
  "the captured buffer account never reaches the pad scope the debit reads (E1)"),
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
        for rel in (BC,):
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
