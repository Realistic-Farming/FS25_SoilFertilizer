# SoilFertilizer SG2-5c-soil mutation battery: the mower's fresh output under StockGuard. Pending
# fresh litres a settle report names are left out of the combine's floor and coverage
# (src/ground/GroundConditionProperty.lua); the birth contribution, the MOWER_CUT admission and its
# per-work-area record (src/ground/GroundConditionAdmission.lua); Soil's cut frame standing aside
# for a MOWER_CUT admitted inside it (src/ground/GroundMovementCarrier.lua). Rows live in
# SG2-5c-soil_mower_birth_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ground/GroundConditionProperty.lua` (9 files), which selects the
# bar and every other bench that loads the property. Run ONE mutant per call, in the foreground,
# memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the FIRST FRESH line's text and its once-per-profile guard's table: logging (B2 and B3 pin
#     that it prints once; its wording is not behaviour);
#   - the KIND_MOWER_CUT footprint entry ("AREA"): K7 reaches the footprint refusal through the
#     argument check, which runs first;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25cs.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_sg25cs.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25cs.py --baseline the selected benches, unmutated
#        py tools/test/mutate_sg25cs.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GP = "src/ground/GroundConditionProperty.lua"
GA = "src/ground/GroundConditionAdmission.lua"
GC = "src/ground/GroundMovementCarrier.lua"
SELECT = ["--loads", "src/ground/GroundConditionProperty.lua"]

MUTATIONS = [
 # ── the combine: pending fresh litres ────────────────────────────────────
 ("Q01-pending-ignored", GP,
  [("        litres = GP.lessPending(tonumber(litres) or 0, pending)\n", "        litres = tonumber(litres) or 0\n", 1)],
  "no part's pending litres are left out: the buffer reads unknown (E4, E5, P1, P2)"),
 ("Q02-before-pending-ignored", GP,
  [("destinationBefore.amountUnit, nil, pendingBefore)\n", "destinationBefore.amountUnit, nil, nil)\n", 1)],
  "the destination's own pending remainder is read as record-less litres (P1, P3)"),
 ("Q03-allocation-pending-ignored", GP,
  [("                evidence, pending = named[part.allocationRef], pendingByRef[part.allocationRef]\n",
    "                evidence, pending = named[part.allocationRef], nil\n", 1)],
  "a contribution's named pending litres are read as record-less litres (P2, P3)"),
 ("Q04-twice-named-taken", GP,
  [("                if out[ref] == nil then out[ref] = e.litres else out[ref] = false end\n", "                out[ref] = e.litres\n", 1)],
  "an allocation named twice names its last figure (P5)"),
 ("Q05-negative-taken", GP,
  [("and isFinite(e.litres) and e.litres >= 0 then\n", "and isFinite(e.litres) then\n", 1)],
  "a negative figure is read, so beside a readable one it counts as a second name (P5b)"),
 ("Q06-excess-is-everything", GP,
  [("    if pending > litres + slack then return litres end\n", "    if pending > litres + slack then return 0 end\n", 1)],
  "a figure above the part names the whole part (P5)"),
 ("Q07-no-residue-rule", GP,
  [("    if left <= slack then return 0 end\n", "", 1)],
  "a residue within the tolerance imports litres (P6)"),
 # ── the admission: births and the MOWER_CUT kind ─────────────────────────
 ("Q08-birth-beside-record", GA,
  [("if c.record ~= nil or type(b) ~= \"table\" or", "if type(b) ~= \"table\" or", 1)],
  "a birth beside a record is accepted (B10)"),
 ("Q09-birth-as-unknown", GA,
  [("            if c.birth ~= nil then\n                mixture[#mixture + 1] = GroundConditionAdmission.birthPart(litres, c.birth)\n            elseif",
    "            if false then\n            elseif", 1)],
  "a birth lands as record-less litres, unknown (B1, E4, E5)"),
 ("Q10-born-older", GA,
  [("GroundConditionAdmission.AGE_BORN = 1\n", "GroundConditionAdmission.AGE_BORN = 2\n", 1)],
  "a birth is born a day old (B1, E9)"),
 ("Q11-any-kind-born", GA,
  [("    if not GroundConditionAdmission.BIRTH_KINDS[birth.kind] then return { litres = litres } end\n", "", 1)],
  "a birth of a kind Soil makes no birth for is born (B6)"),
 ("Q12-no-profile-known", GA,
  [("    local profile = C.profileFor(birth.kind, birth.fillTypeIndex)\n",
    "    local profile = C.profileFor(birth.kind, birth.fillTypeIndex) or C.PROFILES.FRESH_GRASS\n", 1)],
  "a non-profile output (hay from a converter) is born with the fresh-grass profile (B5)"),
 ("Q13-cut-args-unchecked", GA,
  [("    if mowerCut and (type(vehicleOrObject) ~= \"table\" or vehicleOrObject.spec_mower == nil or type(workAreaIdentity) ~= \"table\") then\n",
    "    if false then\n", 1)],
  "a MOWER_CUT from something that is not a mower, or with no work area, is admitted (K7)"),
 ("Q14-cut-prepares-cells", GA,
  [("        self.mowerCuts[workAreaIdentity] = { owner = vehicleOrObject, seq = self.leaseSeq }\n    else\n        self:_prepareLease(lease)\n    end\n",
    "        self.mowerCuts[workAreaIdentity] = { owner = vehicleOrObject, seq = self.leaseSeq }\n    end\n    self:_prepareLease(lease)\n", 1)],
  "a cut prepares cells, so its undelivered close marks them (K4, K5)"),
 ("Q15-any-owner", GA,
  [("    return cut ~= nil and cut.owner == vehicleOrObject and cut.seq > count\n", "    return cut ~= nil and cut.seq > count\n", 1)],
  "another mower's cut on this work area counts (Z2)"),
 ("Q16-any-time", GA,
  [("    return cut ~= nil and cut.owner == vehicleOrObject and cut.seq > count\n", "    return cut ~= nil and cut.owner == vehicleOrObject\n", 1)],
  "a cut admitted before the frame opened counts (Z4)"),
 # ── the carrier: standing aside ──────────────────────────────────────────
 ("Q17-never-stands-aside", GC,
  [("    if admission ~= nil and admission:mowerCutAdmittedSince(frame.owner, frame.workArea, frame.admittedAtBegin) then\n",
    "    if false then\n", 1)],
  "Soil's cut frame makes its own birth under StockGuard's inner bracket (E5, E6)"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o, n = old.encode("utf-8"), new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_bench():
    r = subprocess.run(["node", "run-tests.mjs"] + SELECT, cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL ") or "Lua error" in l]
    crashed = "Lua error" in out or "group raised" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:24s} {rel}  {why}")
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
        rc, _, _, out = run_bench()
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.strip().splitlines()]
        print(lines[-1] if lines else "(no output)")
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
        rc, fails, crashed, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertionFails = [f for f in fails if "group raised" not in f and "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:5]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
