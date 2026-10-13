# SG2-5 slice 5e's Soil half (5e-soil, Part 0 of Bob's 5e round core intake) mutation battery: a partial
# round bale's account is StockGuard's chamber record read BEFORE the engine pads the chamber
# (src/ground/BalerCollection.lua: aroundUnloading, prePadAccount, aroundFinish's pad branch). Rows live
# in tools/test/lua/SG2-5e-soil_round_pad_account_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against the
# one selection that sees them, `--loads src/ground/BalerCollection.lua`. Run ONE mutant per call, in
# the foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - prePadAccount's `acc == nil` early return: without it BC.accountReconcileRecord indexes nil, the
#     pcall in aroundUnloading answers false, and pad.account stays nil: the same result (rows N1 to N3);
#   - prePadAccount's `level ~= nil` guard: mainLevel answers a number for every baler the bench builds,
#     and a nil level would only skip the reconcile;
#   - the server gate in aroundUnloading: rewritten to name `spec`, unchanged in meaning;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg25es.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25es.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25es.py --baseline  the selection, unmutated
#        py tools/test/mutate_sg25es.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BC = "src/ground/BalerCollection.lua"
SELECT = {BC: ["--loads", BC]}

CAPTURE = ("        local okA, acc = pcall(BC.prePadAccount, vehicle, spec)\n"
           "        if okA then pad.account = acc end\n")
PADBRANCH = "            account = BC.copyAccount(st.pad.account or st.main)\n"
ORIGINAL = ("    local packed = { pcall(original, vehicle, ...) }\n"
            "    if st ~= nil then st.pad = outer end\n")

MUTATIONS = [
 ("U01-read-at-the-finish", BC,
  [(CAPTURE, "", 1),
   (PADBRANCH, "            account = BC.copyAccount(BC.prePadAccount(vehicle, spec) or st.main)\n", 1)],
  "StockGuard is read at the finish, inside the pad's add, so it sees the padded chamber (E1, E3)"),
 ("U02-read-after-the-original", BC,
  [(CAPTURE, "", 1),
   (ORIGINAL, "    local packed = { pcall(original, vehicle, ...) }\n"
              "    if st ~= nil and st.pad ~= nil then local okA, acc = pcall(BC.prePadAccount, vehicle, spec) if okA then st.pad.account = acc end end\n"
              "    if st ~= nil then st.pad = outer end\n", 1)],
  "the capture runs after the engine's unload, too late for the finish (E1)"),
 ("U03-pad-account-ignored", BC,
  [(PADBRANCH, "            account = BC.copyAccount(st.main)\n", 1)],
  "the pad branch keeps Soil's own account whatever StockGuard holds (E1, E4)"),
 ("U04-no-reconcile", BC,
  [("    if level ~= nil then BC.accountReconcileRecord(acc, level) end\n    return acc\n", "    return acc\n", 1)],
  "the record's account is not reconciled to the chamber's pre-pad level (R1)"),
 ("U05-no-pcall", BC,
  [("        local okA, acc = pcall(BC.prePadAccount, vehicle, spec)\n", "        local okA, acc = true, BC.prePadAccount(vehicle, spec)\n", 1)],
  "a raising capture stops the engine's unload (X6)"),
 ("U06-failure-taken-as-account", BC,
  [("        if okA then pad.account = acc end\n", "        pad.account = acc\n", 1)],
  "a failed capture's error text is taken as the account (X6)"),
 ("U07-capture-not-in-scope", BC,
  [("        st.pad = pad\n", "        st.pad = {}\n", 1)],
  "the captured account never reaches the pad scope the finish reads (E1)"),
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
