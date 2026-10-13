# SG2-5 slice 5-0 mutation battery: an admitted drop takes the carried condition of the material
# StockGuard drops (src/ground/GroundConditionAdmission.lua: validObservation's contributions,
# mixtureOf, the drop branch). Rows live in tools/test/lua/SG2-5-0-drop_contributions_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against
# the one selection that sees them, `node run-tests.mjs --loads src/ground/GroundConditionAdmission.lua`
# (15 files, about 18 s). Run ONE mutant per call, in the foreground, and check free memory between
# calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence
# count) and the restore is proved by a hash. KILLED* means killed only by a Lua error (a crash,
# or a group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - mixtureOf's `litres > 0` guard: a zero-litre part is inert in the projector's combine
#     (GroundConditionCoordinator.combine counts only positive litres), so dropping the guard is
#     an equivalent mutant; it stays as the reader's own statement of the rule;
#   - GroundConditionProperty.componentsOf's export line: removing it makes the drop raise, which
#     no row can tell from any other crash;
#   - the `GroundConditionProperty == nil` branch: main.lua sources the property before any lease
#     can be delivered;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg250.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg250.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg250.py --baseline  the selection, unmutated
#        py tools/test/mutate_sg250.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

ADM = "src/ground/GroundConditionAdmission.lua"
SELECT = ["--loads", ADM]

MUTATIONS = [
 ("C01-contributions-not-copied", ADM,
  [("            obs.contributions = list\n", "", 1)],
  "the observation drops the caller's contributions: every drop lands unknown (E4, D1, D5)"),
 ("C02-list-shape-unchecked", ADM,
  [("            if type(observation.contributions) ~= \"table\" then return nil end\n", "", 1)],
  "a contributions field that is not a list is not refused (X1)"),
 ("C03-entry-unchecked", ADM,
  [("                if type(c) ~= \"table\" or not finite(c.litres) or c.litres < 0 then return nil end\n", "", 1)],
  "an entry that is not a table, or whose litres are not finite or negative, is not refused (X1)"),
 ("C04-drop-ignores-mixture", ADM,
  [("            counts = P.drop(lease, cells, obs.fillTypeIndex, mixture, total)\n",
    "            counts = P.drop(lease, cells, obs.fillTypeIndex, {}, 0)\n", 1)],
  "the drop projects no mixture, as before 5-0 (E4, D1, D5, D8)"),
 ("C05-no-ageing", ADM,
  [("                        ageRaw = GroundMovementCarrier.agedRaw(ageRaw, ageDay, today), wetnessRaw = wetnessRaw }\n",
    "                        ageRaw = ageRaw, wetnessRaw = wetnessRaw }\n", 1)],
  "a carried age is not aged on re-entry, and a stampless age stays known (D1, D9)"),
 ("C06-no-today", ADM,
  [("            local today = self.coordinator ~= nil and self.coordinator:currentMonotonicDay() or nil\n",
    "            local today = nil\n", 1)],
  "the drop does not read today: every known age is lost (E4, D1)"),
 ("C07-unvalidated-record-read", ADM,
  [("            if GP ~= nil and GP.validate(rec) == true then\n",
    "            if GP ~= nil then\n", 1)],
  "a record that does not validate is read by its payload (D4)"),
 ("C08-coverage-ignored", ADM,
  [("                    known = litres * math.max(0, math.min(1, rec.knownAmount / rec.basisAmount))\n", "", 1)],
  "a KNOWN record's uncovered litres are taken as known (D7)"),
 ("C09-split-on-unknown-records", ADM,
  [("                if rec.knowledge == \"KNOWN\" and finite(rec.knownAmount) and finite(rec.basisAmount) and rec.basisAmount > 0 then\n",
    "                if finite(rec.knownAmount) and finite(rec.basisAmount) and rec.basisAmount > 0 then\n", 1)],
  "an UNKNOWN record's zero coverage erases the component it does know (D10)"),
 ("C10-unknown-remainder-dropped", ADM,
  [("                if litres - known > 0 then mixture[#mixture + 1] = { litres = litres - known } end\n", "", 1)],
  "the uncovered litres of a KNOWN record vanish instead of arriving unknown (D7)"),
 ("C11-unreadable-part-dropped", ADM,
  [("                mixture[#mixture + 1] = { litres = litres }\n", "", 1)],
  "litres with no readable record vanish instead of arriving unknown (D6, D3)"),
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
