# CD-15 step 1b mutation battery: the local disease save participant (src/disease/CD15Save.lua), the
# model's restore hold and import (src/disease/CD15Model.lua), the header seams
# (src/SoilFertilityManager.lua, src/integrations/SoilStateLedgerBridge.lua) and #1062's MINOR 1, the
# two pcall seams (src/SoilFertilitySystem.lua). Rows live in
# tools/test/lua/CD15-1b-save_participant_spec_test.lua and, for the seams, group M of
# tools/test/lua/CD15-1a-local_grid_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30; Bob's intake, "against the files that load CD15Save.lua,
# GroundConditionSave.lua and SoilNativeSave.lua"): only the lines this PR changes. Each mutant runs
# the selection `--loads src/disease/CD15Model.lua`, which reaches both CD-15 benches whatever file
# the mutant edits (both load CD15Model.lua and every file mutated here). Run ONE mutant per call, in
# the foreground, and check free memory between calls.
#
# Each mutation must be KILLED by a named row. The edit is proved to LAND (exact occurrence count) and
# the restore is proved by a hash. KILLED* means killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the decoder's per-field string length caps: a longer name is refused by CD15Grid.validCell's
#     own caps for the same fields;
#   - writeCompletion's NO_XML and LOAD branches: the engine always has loadXMLFile, and a payload the
#     freeze wrote is in the final directory whenever the save completed;
#   - the barrier observer's removal at close: the next install replaces CD15Save.current, so a
#     stale observer finds S.current ~= host and does nothing;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage (from the repo root):
#        py tools/test/mutate_cd15_1b.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_cd15_1b.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_cd15_1b.py --baseline  the selection, unmutated
#        py tools/test/mutate_cd15_1b.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SAVE = "src/disease/CD15Save.lua"
MODEL = "src/disease/CD15Model.lua"
MGR = "src/SoilFertilityManager.lua"
LEDGER = "src/integrations/SoilStateLedgerBridge.lua"
SYS = "src/SoilFertilitySystem.lua"
SELECTION = ["--loads", MODEL]
SELECT = {SAVE: SELECTION, MODEL: SELECTION, MGR: SELECTION, LEDGER: SELECTION, SYS: SELECTION}

MUTATIONS = [
 # ── the header ──
 ("H01-header-not-written", SAVE,
  [("    if h ~= nil then S.writeHeaderXMLAt(xmlFile, S.HEADER_KEY, h) end\n", "", 1)],
  "soilData.xml carries no header (E4, and the reload finds an orphan payload, E7)"),
 ("H02-ledger-header-not-built", LEDGER,
  [("        if okCd and header ~= nil then out.extensions = { cd15Disease = CD15Save.copyHeader(header) } end\n", "", 1)],
  "the StateLedger block carries no header (L1, L2)"),
 ("H03-ledger-header-not-read", LEDGER,
  [("        CD15Save.noteLoadedHeader(CD15Save.headerFromTable(ext ~= nil and ext.cd15Disease or nil), \"LEDGER\")\n", "", 1)],
  "the ledger path never delivers its header (L2, L4)"),
 ("H04-xml-header-not-read", MGR,
  [("            if CD15Save ~= nil then CD15Save.noteLoadedXML(xmlFile) end\n", "", 1)],
  "the XML path never delivers its header, so the restore never decides (E7)"),
 ("H05-out-of-band-drops-header", SAVE,
  [("    if self.decided then return self.diskHeader end\n    return self.installHeader\n", "    return nil\n", 1)],
  "an out-of-band save drops the header (O1, O2)"),
 # ── the restore decision ──
 ("R01-orphan-is-first-activation", SAVE,
  [("        if payloadExists then return self:enterQuarantine(\"ORPHAN_PAYLOAD\", nil) end\n", "", 1)],
  "a payload with no header reads as a clean first activation (Q3)"),
 ("R02-carried-quarantine-dropped", SAVE,
  [("    if h.status == S.QUARANTINED then return self:enterQuarantine(\"CARRIED:\" .. tostring(h.reason), h.originalAttemptId) end\n", "", 1)],
  "a QUARANTINED header is read as a saved attempt (Q12, L4)"),
 ("R03-geometry-unchecked", SAVE,
  [("    if h.geometryFingerprint ~= model.geometry.fingerprint then return self:enterQuarantine(\"GEOMETRY_MISMATCH\", h.attemptId) end\n", "", 1)],
  "conflicting geometry is left to the payload check (Q5 names the header's reason)"),
 ("R04-marker-unchecked", SAVE,
  [("    if getXMLInt(x, R .. \"#completeAttemptId\") ~= h.attemptId then d.fail(\"NOT_COMPLETE\") end\n", "", 1)],
  "a payload without its completion restores (Q1, C2, F2)"),
 ("R05-attempt-unchecked", SAVE,
  [("    if getXMLInt(x, R .. \"#attemptId\") ~= h.attemptId then d.fail(\"ATTEMPT_MISMATCH\") end\n", "", 1)],
  "another attempt's payload restores (Q4)"),
 ("R06-key-order-unchecked", SAVE,
  [("            if lastKey ~= nil and k <= lastKey then d.fail(\"KEY_ORDER\") end\n", "", 1)],
  "two cells under one key restore (Q6)"),
 ("R07-count-unbounded", SAVE,
  [("        if not CD15Grid.isInteger(n) or n < 0 or n > max then d.fail(\"COUNT:\" .. path) end\n",
    "        if not CD15Grid.isInteger(n) or n < 0 then d.fail(\"COUNT:\" .. path) end\n", 1)],
  "a count beyond its bound is read on (Q7)"),
 ("R08-non-finite-read", SAVE,
  [("        if not CD15Grid.isFinite(v) then d.fail(\"NUMBER:\" .. path) end\n", "        if v == nil then d.fail(\"NUMBER:\" .. path) end\n", 1)],
  "a non-finite number is read as a value (Q8)"),
 ("R09-restore-mints-sequence", MODEL,
  [("    self.occurrenceSeq, self.discoveryCursor = d.occurrenceSeq, d.discoveryCursor\n", "    self.discoveryCursor = d.discoveryCursor\n", 1)],
  "the occurrence sequence is not restored (E7)"),
 ("R10-settle-cursor-saved-not-restarted", MODEL,
  [("        self.queue[i] = { phase = w.phase, input = w.input, sources = w.sources, scursor = w.scursor }\n",
    "        self.queue[i] = { phase = w.phase, input = w.input, sources = w.sources, scursor = w.scursor, cells = {}, cursor = 1 }\n", 1)],
  "a restored SETTLE day settles nothing more (D2)"),
 # ── the hold ──
 ("W01-no-hold", MODEL,
  [("    return rs ~= nil and rs ~= M.RESTORED and rs ~= M.FIRST_ACTIVATION\n", "    return false\n", 1)],
  "day work runs before the restore decides, and in quarantine (E2, Q1)"),
 ("W02-quarantine-saves-cells", SAVE,
  [("    if rs == CD15Model.QUARANTINED then return self:quarantineHeader(nil) end\n", "", 1)],
  "a session quarantined with no earlier evidence saves no header, so its next load first-activates (Q14, Q15)"),
 ("W03-undecided-saves-nothing", SAVE,
  [("    if self.evidenceAtInstall or self.loadedHeader ~= nil then return self:quarantineHeader(\"NOT_RESTORED\") end\n", "", 1)],
  "a save before the restore decided drops the evidence (W1)"),
 # ── the save ──
 ("S01-images-include-height", SAVE,
  [("        if n.kind == \"FRUIT\" or n.kind == \"HAULM\" then out[#out + 1] = { mapId = n.mapId, nativeFilename = filename } end\n",
    "        out[#out + 1] = { mapId = n.mapId, nativeFilename = filename }\n", 1)],
  "CD-15 claims the height image too (E4, E6)"),
 ("S02-marker-on-failed-save", SAVE,
  [("    if not ok then reason = \"SAVE_FAILED:\" .. tostring(errorCode)\n    elseif type(finalDir)", "    if type(finalDir)", 1)],
  "a failed save still writes the completion (F1)"),
 ("S03-marker-when-not-ready", SAVE,
  [("    elseif mine == nil or mine.state ~= S.READY then reason = \"NOT_READY:\" .. tostring(mine and mine.reason)\n", "", 1)],
  "an invalidated participant still writes the completion (C1)"),
 ("S04-marker-in-staging", SAVE,
  [("        local okM, why = S.writeCompletion(finalDir .. \"/\" .. S.PAYLOAD_FILE, p.attemptId)\n",
    "        local okM, why = S.writeCompletion(((context.careerSave and context.careerSave.savegameDirectory ~= finalDir and context.stagingDirectory) or finalDir) .. \"/\" .. S.PAYLOAD_FILE, p.attemptId)\n", 1)],
  "the completion goes to the staging directory, not the final one (E5)"),
 # ── #1062's MINOR 1, the seams ──
 ("M01-day-seam-unguarded", SYS,
  [("            local okCd, errCd = pcall(self.cd15.onDayChanged, self.cd15)\n            if not okCd then self.cd15:fail(\"onDayChanged\", errCd) end\n",
    "            self.cd15:onDayChanged()\n", 1)],
  "a raising onDayChanged breaks the daily pass (M1, M2)"),
 ("M02-update-seam-unguarded", SYS,
  [("        local okCd, errCd = pcall(self.cd15.update, self.cd15, dt)\n        if not okCd then self.cd15:fail(\"update\", errCd) end\n",
    "        self.cd15:update(dt)\n", 1)],
  "a raising update breaks the update (M4, M5)"),
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
