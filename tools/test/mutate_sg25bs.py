# SG2-5 slice 5b-soil mutation battery: soil.groundCondition's transform carries combine's rule
# under the Tedder's hay basis (src/ground/GroundConditionProperty.lua: carriesThroughConversion and
# transform). Rows live in tools/test/lua/SG2-5b-soil_hay_transform_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, each mutant against
# the one selection that sees them, `node run-tests.mjs --loads src/ground/GroundConditionProperty.lua`.
# Run ONE mutant per call, in the foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence
# count) and the restore is proved by a hash. KILLED* means killed only by a Lua error (a crash,
# or a group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the `type(contributions) ~= "table"` guard: SG-1 always passes a list (SGOperations.lua:789);
#     ipairs over nil would raise inside SG-1's pcall and answer TRANSFORM_ERROR, an unknown
#     record either way (:794);
#   - the `type(d) == "table"` guards on amount, unit and destinationBefore: SG-1 always passes
#     one destination entry (:789); row H10 states the nil case;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_sg25bs.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25bs.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25bs.py --baseline  the selection, unmutated
#        py tools/test/mutate_sg25bs.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

PROP = "src/ground/GroundConditionProperty.lua"
SELECT = ["--loads", PROP]

MUTATIONS = [
 ("B01-never-carries", PROP,
  [("    if GP.carriesThroughConversion(contributions) then\n", "    if false then\n", 1)],
  "the hay conversion goes unknown, as before 5b-soil (E1, H1)"),
 ("B02-always-carries", PROP,
  [("    if GP.carriesThroughConversion(contributions) then\n", "    if true then\n", 1)],
  "every conversion carries, any basis or none (H3, H4, H5)"),
 ("B03-other-basis-allowed", PROP,
  [("        elseif basis ~= nil then\n            return false\n        end\n", "        end\n", 1)],
  "a foreign basis beside the hay basis does not spoil the candidate (H4, R1)"),
 ("B04-no-hay-needed", PROP,
  [("    return hay\nend\n", "    return true\nend\n", 1)],
  "a candidate with no hay-based contribution carries (H5, R1)"),
 ("B05-any-basis-is-hay", PROP,
  [("        if basis == GP.HAY_CONVERT_BASIS then\n", "        if basis ~= nil then\n", 1)],
  "any basis counts as the hay basis (H3, R1)"),
 ("B06-no-destination-before", PROP,
  [("        local carried = self:combine(context, contributions, type(d) == \"table\" and d.destinationBefore or nil)\n",
    "        local carried = self:combine(context, contributions, nil)\n", 1)],
  "the buffer's remainder is left out of the carried floor (H2)"),
 ("B07-not-restamped", PROP,
  [("            return GP.record(carried.payload, amount, unit, c ~= nil and c.changeCounter or 0)\n",
    "            return carried\n", 1)],
  "the carried record keeps the contributions' litres, not the destination's (H6)"),
 ("B08-malformed-part-passes", PROP,
  [("        if type(part) ~= \"table\" then return false end\n", "", 1)],
  "a malformed contribution is not refused (H9)"),
 ("B09-no-material-unguarded", PROP,
  [("        if carried ~= nil then\n            return GP.record", "        do\n            return GP.record", 1)],
  "a conversion of no material indexes nothing (H12)"),
 ("B10-basis-renamed", PROP,
  [("GP.HAY_CONVERT_BASIS = \"NATIVE_HAY_CONVERT_V1\"\n", "GP.HAY_CONVERT_BASIS = \"NATIVE_HAY_CONVERT\"\n", 1)],
  "the basis is not the profile's own name (E1, R2)"),
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
    # Assertion failures first: a kill is attributed to a row, not to a crash elsewhere.
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
