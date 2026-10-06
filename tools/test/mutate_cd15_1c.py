# CD-15 step 1c mutation battery: discovery and admission (src/disease/CD15Admission.lua), the model's
# wiring (src/disease/CD15Model.lua: discovery in the update behind the hold, the cell's wetness passed
# to the day, the membership callback for spread) and the day module's two MINORs
# (src/disease/CD15Day.lua). Rows live in tools/test/lua/CD15-1c-admission_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes. Each mutant runs the
# selection `--loads src/disease/CD15Admission.lua`, which is the 1c bench alone (the 1a and 1b benches
# do not load the admission module). Run ONE mutant per call, in the foreground, and check free memory
# between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the plane-set digest in place of the full fingerprint: the bench's fingerprint is short; the
#     digest exists for a map with many planes, whose fingerprint would pass the save's 256-byte cap
#     (A4's reload proves the witness fields encode);
#   - resolvePlanes' PLANE_KIND and PLANE_SIZE refusals and resolveFields' NO_FIELDS: no engine world
#     registers a plane as both kinds, an unsized plane, or no field manager;
#   - A.invalidate: step 2's writers are its only callers;
#   - the strict vertex test in cellOverlaps: touching or overlapping only chooses which cells are
#     looked at, and the witness alone decides admission;
#   - the cell box's upper bound (ceil - 1): it changes only how much of the budget a pass spends;
#   - logs, counters and comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_cd15_1c.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_cd15_1c.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_cd15_1c.py --baseline  the selection, unmutated
#        py tools/test/mutate_cd15_1c.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

ADM = "src/disease/CD15Admission.lua"
MODEL = "src/disease/CD15Model.lua"
DAY = "src/disease/CD15Day.lua"
SELECTION = ["--loads", ADM]
SELECT = {ADM: SELECTION, MODEL: SELECTION, DAY: SELECTION}

MUTATIONS = [
 # ── the profile gate and the witness ──
 ("N01-default-profile", ADM,
  [("        if type(p) == \"table\" and nonempty(p.id, 64) and isInteger(p.maxReadsPerCell) and p.maxReadsPerCell > 0 then return p end\n    end\n    return nil\nend\n",
    "        if type(p) == \"table\" and nonempty(p.id, 64) and isInteger(p.maxReadsPerCell) and p.maxReadsPerCell > 0 then return p end\n    end\n    return { id = \"default\", maxReadsPerCell = 1000000 }\nend\n", 1)],
  "production reads pixels and admits with no recorded profile (E1)"),
 ("N02-no-read-budget", ADM,
  [("    if total > profile.maxReadsPerCell then return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. \":READ_BUDGET\" } end\n", "", 1)],
  "a cell beyond the profile's budget is read anyway (R1)"),
 ("N03-haulm-as-crop", ADM,
  [("                elseif p.kind == \"HAULM\" then\n", "                elseif false then\n", 1)],
  "a haulm pixel is decoded as a crop (C1)"),
 ("N04-no-plane-association", ADM,
  [("                    if type(desc) ~= \"table\" or desc.terrainDataPlaneId ~= p.id or type(desc.getGrowthStateByDensityState) ~= \"function\" then\n",
    "                    if type(desc) ~= \"table\" or type(desc.getGrowthStateByDensityState) ~= \"function\" then\n", 1)],
  "a descriptor is decoded on a plane it does not own (C1)"),
 ("N05-growing-only", ADM,
  [("    if call(desc, \"getIsGrowing\", growth) or call(desc, \"getIsHarvestReady\", growth) or call(desc, \"getIsHarvestable\", growth)\n        or call(desc, \"getIsPreparable\", growth) or (isInteger(desc.preparedGrowthState) and desc.preparedGrowthState > 0 and growth == desc.preparedGrowthState) then\n",
    "    if call(desc, \"getIsGrowing\", growth) then\n", 1)],
  "getIsGrowing alone: harvest-ready and preparable crops omitted (C1)"),
 ("N06-cut-withered-living", ADM,
  [("    if call(desc, \"getIsCut\", growth) or call(desc, \"getIsWithered\", growth) then return \"NONLIVING\" end\n", "", 1)],
  "cut and withered states are not excluded (C1)"),
 ("N07-destroyed-living", ADM,
  [("    if isInteger(desc.disasterDestructionState) and desc.disasterDestructionState > 0 and growth == desc.disasterDestructionState then return \"NONLIVING\" end\n", "", 1)],
  "the mapped destroyed state is not excluded (C1)"),
 ("N08-unknown-state-empty", ADM,
  [("        return \"LIVING\"\n    end\n    return \"UNKNOWN\"\n", "        return \"LIVING\"\n    end\n    return \"EMPTY\"\n", 1)],
  "a state outside the vocabulary reads as empty (C1)"),
 ("N09-pixel-centres-only", ADM,
  [("    local i1 = math.ceil((hi + half) / pixel) - 1\n", "    local i1 = math.floor((hi + half) / pixel) - 1\n", 1)],
  "a boundary pixel overlapping the cell is not read (C1)"),
 ("N10-mixed-crops-admitted", ADM,
  [("    if #crops > 1 then\n        table.sort(crops)\n        return { state = A.UNKNOWN, reason = A.UNKNOWN_OCCURRENCE .. \":MIXED_CROPS\", fields = fields }\n    end\n", "", 1)],
  "a cell holding two crops is admitted as one (C1)"),
 ("N11-first-plane-only", ADM,
  [("    for i, p in ipairs(planes) do\n        local r = ranges[i]\n", "    for i, p in ipairs({ planes[1] }) do\n        local r = ranges[i]\n", 1)],
  "only the first (default) plane is read (C1)"),
 # ── admission ──
 ("N12-retained-row-reset", ADM,
  [("    local cell = row ~= nil and G.copyCell(row) or G.baselineCell(model.geometry.fingerprint)\n",
    "    local cell = G.baselineCell(model.geometry.fingerprint)\n", 1)],
  "admission drops a retained row's resistance and protection (A2)"),
 ("N13-token-not-from-sequence", ADM,
  [("    model.occurrenceSeq = model.occurrenceSeq + 1\n    local token", "    local token", 1)],
  "the token does not come from the saved sequence (A1)"),
 ("N14-cursor-not-today", ADM,
  [("    if row == nil then cell.lastSettledDay = day end\n", "", 1)],
  "an admitted cell's cursor does not start at today (A1)"),
 ("N15-readmitted", ADM,
  [("    if row ~= nil and row.cropName ~= nil then return nil, \"ALREADY_ADMITTED\" end\n", "", 1),
   ("        if row == nil or row.cropName == nil then\n", "        if true then\n", 1)],
  "a second pass admits the same cells again (A2, A3)"),
 # ── discovery ──
 ("N16-discovery-while-held", MODEL,
  [("    if g_server == nil then return end\n    if self:isHeld() then return end\n    local budget, work = M.WORK_BOUND, 0\n",
    "    if g_server == nil then return end\n    if self:isHeld() then\n        if CD15Admission ~= nil and self:ensureGeometry() then CD15Admission.discover(self, M.WORK_BOUND) end\n        return\n    end\n    local budget, work = M.WORK_BOUND, 0\n", 1)],
  "a held model discovers and admits (H1)"),
 ("N17-discovery-work-uncounted", MODEL,
  [("        work = work + CD15Admission.discover(self, budget)\n", "        CD15Admission.discover(self, budget)\n", 1)],
  "discovery's work is not counted in the update's bound (B1)"),
 ("N18-pass-runs-on", ADM,
  [("            model.discoveryCursor = 0\n            break\n", "            model.discoveryCursor = 0\n", 1)],
  "one update wraps and examines cells twice (E2)"),
 ("N19-geometry-keeps-membership", ADM,
  [("    if d == nil or d.geometry ~= model.geometry.fingerprint then\n", "    if d == nil then\n", 1)],
  "a changed geometry keeps the old membership (G1)"),
 ("N20-box-not-polygon", ADM,
  [("        if gx ~= nil and (f == nil or A.cellOverlaps(model.geometry, f.points, gx, gz)) then\n", "        if gx ~= nil then\n", 1)],
  "candidates are the polygon's rectangle (P1)"),
 ("N21-no-reason", ADM,
  [("        d.lastReason = r.reason\n", "", 1)],
  "the status names no reason (E1)"),
 ("N22-discovery-needs-a-day", MODEL,
  [("    if g_server == nil then return end\n    if self:isHeld() then return end\n    local budget, work = M.WORK_BOUND, 0\n",
    "    if g_server == nil or #self.queue == 0 then return end\n    if self:isHeld() then return end\n    local budget, work = M.WORK_BOUND, 0\n", 1)],
  "discovery runs only when a day's work is queued (E2, A1)"),
 # ── #1062's MINOR 2 and MINOR 3 ──
 ("M01-onset-reads-weather", DAY,
  [("            local wet = ci.wet\n", "            local wet = nil\n", 1)],
  "onset selects by the day's weather, not the cell (M1)"),
 ("M02-wetness-not-passed", MODEL,
  [("    ci.wet, ci.wetSource = self:wetAt(ci, input)\n", "", 1)],
  "the model never passes the cell's wetness (M1)"),
 ("M03-spread-skips-membership", DAY,
  [("        if dest == nil and member ~= nil and gx >= 0 and gz >= 0 then dest = member(gx, gz) end\n", "", 1)],
  "spread never reaches a cell with no row (M2)"),
 ("M04-spread-admits-undiscovered", MODEL,
  [("                return CD15Admission.memberRow(self, gx, gz, input.day)\n",
    "                local planes, fp = CD15Admission.resolvePlanes()\n                local r = CD15Admission.witness(self.geometry, planes, fp, gx, gz, CD15Admission.supportedProfile())\n                if r.state == \"LIVING\" then return (CD15Admission.admit(self, gx, gz, r.cropName, r.fields, input.day)) end\n                return nil\n", 1)],
  "spread admits a living cell discovery never found (M2)"),
 ("M05-member-at-no-day", MODEL,
  [("                return CD15Admission.memberRow(self, gx, gz, input.day)\n", "                return CD15Admission.memberRow(self, gx, gz, nil)\n", 1)],
  "a member is admitted with no day, so spread does not reach it (M2)"),
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
        for rel in sorted(set(SELECT)):
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
