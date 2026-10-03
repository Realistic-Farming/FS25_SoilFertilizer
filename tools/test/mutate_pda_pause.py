# SoilFertilizer SF-73 PDA last-pause mutation battery: the crop-condition pause the PDA names for its field
# (src/target/TargetApplication.lua: isCropPause, noteFieldPause, getLastPauseForField, their calls in setResult and
# receive, reset), its soil read (src/SoilFertilitySystem.lua: getLastTargetPauseForField) and the card
# (src/ui/RfPdaSoilPanel.lua: TARGET_PDA_PAUSE, the pause's crop filter and precedence). Rows live in
# SF-73-pda_last_pause_spec_test.lua, with W1b's in SF-73-W1b-pda_target_card_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ui/RfPdaSoilPanel.lua --loads src/target/TargetApplication.lua` (12 files): this
# bar, W1b's, W1a's, the MAINTENANCE 211 and SF-73 entry benches, every other bench that loads TargetApplication or
# the panel, and the main.lua loaders. The SoilFertilitySystem mutants use the same selection: the pause read has no
# caller but the panel. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the field record handed to fieldCropKey: only its sownCrop fallback reads it, and every bench field reports
#     from the fruit plane;
#   - the writer's copy of the result: the server stores a fresh table every cycle and nothing writes a stored one
#     (the read's copy is P17);
#   - the writer's lazy creation of the table: new and reset always make it;
#   - the card's feature detection of the soil read, and the pause filter's `rel == nil or rel.cropKey == nil`
#     guard: the stamp is never nil, so `pause.fieldCrop ~= rel.cropKey` already hides it, and a nil rel errors
#     inside the host's pcall, which draws nothing new;
#   - the soil read's own method detection: a TargetApplication without the reader is not this tree;
#   - the `or 0` defaults in the precedence: every entry carries its time;
#   - the translations (group X of the bar), comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_pda_pause.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_pda_pause.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_pda_pause.py --baseline the selected benches, unmutated
#        py tools/test/mutate_pda_pause.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

TA = "src/target/TargetApplication.lua"
SFS = "src/SoilFertilitySystem.lua"
PANEL = "src/ui/RfPdaSoilPanel.lua"
SELECT = ["--loads", "src/ui/RfPdaSoilPanel.lua", "--loads", "src/target/TargetApplication.lua"]

ENTRY_LINE = "    if TA.isCropPause(prev) and prev.fieldId == r.fieldId then return end\n"
RECV_PREV = "    local prev = (old ~= nil and old.epoch == result.epoch) and old.result or nil\n"
PRECEDENCE = "    if pause ~= nil and pass ~= nil and not ((pause.notedAt or 0) > (pass.notedAt or 0)) then pause = nil end\n"
PAUSE_COPY = "RfPdaSoilPanel.TARGET_PDA_PAUSE = { line = \"sf_tgt_pda_state_paused\", note = \"sf_tgt_pda_pause_hint\" }\n"

MUTATIONS = [
 ("P01-farm-access-not-tested", TA,
  [("        if x == C.REASON.FARM_ACCESS then return false end\n",
    "        if x == \"NO_SUCH_REASON\" then return false end\n", 1)],
  "the FARM_ACCESS exclusion rests on the display order alone (T13)"),
 ("P02-no-field-test", TA,
  [("    if type(r) ~= \"table\" or type(r.fieldId) ~= \"number\" then return false end\n",
    "    if type(r) ~= \"table\" then return false end\n", 1)],
  "a pause with no field, or a field that is not a number, counts (T2, T3)"),
 ("P03-any-refusal", TA,
  [("    return C.primaryReason(r) == C.REASON.UNSUPPORTED_CROP\n",
    "    return C.primaryReason(r) ~= nil\n", 1)],
  "every field-naming refusal is recorded (G2, G5, L3, I2, T5-T8)"),
 ("P04-every-cycle-an-entry", TA,
  [(ENTRY_LINE, "", 1)],
  "a pause going on is re-stamped every cycle (O2, O3, C7)"),
 ("P05-entry-ignores-the-field", TA,
  [(ENTRY_LINE, "    if TA.isCropPause(prev) then return end\n", 1)],
  "a pause moving to another field is not an entry (C9)"),
 ("P06-nil-stamp-stored", TA,
  [("    if stamp == nil then return end\n", "", 1)],
  "a field reporting no crop stores a pause (S7)"),
 ("P07-entry-time-zero", TA,
  [("    self.lastPauseByField[r.fieldId] = { result = C.copy(r), at = now(), fieldCrop = stamp }\n",
    "    self.lastPauseByField[r.fieldId] = { result = C.copy(r), at = 0, fieldCrop = stamp }\n", 1)],
  "the pause carries no time, so a pass always wins (N3, O3, C7)"),
 ("P08-server-prev-dropped", TA,
  [("    self:noteFieldPause(r, prev) -- remembered only on entry into a no-crop pause\n",
    "    self:noteFieldPause(r, nil) -- remembered only on entry into a no-crop pause\n", 1)],
  "the host treats every refusal cycle as an entry (O2, O3)"),
 ("P09-server-never-notes", TA,
  [("    self:noteFieldPause(r, prev) -- remembered only on entry into a no-crop pause\n", "", 1)],
  "the host never records a pause (E, N, L, O)"),
 ("P10-client-prev-across-epochs", TA,
  [(RECV_PREV, "    local prev = old ~= nil and old.result or nil\n", 1)],
  "a client keeps a pause from the previous epoch as going on (C8)"),
 ("P11-client-prev-dropped", TA,
  [(RECV_PREV, "    local prev = nil\n", 1)],
  "a client treats every received refusal as an entry (C7)"),
 ("P12-client-never-notes", TA,
  [("    self:noteFieldPause(result, prev)\n", "", 1)],
  "a client never records a pause (C4, C6)"),
 ("P13-reset-keeps-pauses", TA,
  [("    self.lastOutcomeByField = {}\n    self.lastPauseByField = {}\nend\n",
    "    self.lastOutcomeByField = {}\nend\n", 1)],
  "a reload keeps the pauses (M2)"),
 ("P14-read-drops-stamp", TA,
  [("    r.fieldCrop = rec.fieldCrop\n", "", 1)],
  "the read loses the stamp, so the card's crop filter hides every pause (E, N3, C6)"),
 ("P15-read-drops-time", TA,
  [("    r.notedAt = rec.at\n    r.fieldCrop = rec.fieldCrop\n", "    r.fieldCrop = rec.fieldCrop\n", 1)],
  "the read loses the time, so a pass always wins (N3, N9)"),
 ("P16-read-not-a-copy", TA,
  [("    local r = C.copy(rec.result)\n    r.notedAt = rec.at\n    r.fieldCrop = rec.fieldCrop\n",
    "    local r = rec.result\n    r.notedAt = rec.at\n    r.fieldCrop = rec.fieldCrop\n", 1)],
  "the read hands out the stored result (E13)"),
 ("S01-read-ignores-lock", SFS,
  [("function SoilFertilitySystem:getLastTargetPauseForField(fieldId)\n    if not self:isTargetGateOpen() then return nil end\n",
    "function SoilFertilitySystem:getLastTargetPauseForField(fieldId)\n", 1)],
  "the pause read answers while SF-73 is locked (K3)"),
 ("S02-read-answers-nil", SFS,
  [("    local ok, r = pcall(ta.getLastPauseForField, ta, fieldId)\n    if ok then return r end\n",
    "    local ok, r = pcall(ta.getLastPauseForField, ta, fieldId)\n    if ok then return nil end\n", 1)],
  "the pause read never answers (E, C6)"),
 ("U01-no-crop-filter", PANEL,
  [("    if pause ~= nil and (rel == nil or rel.cropKey == nil or pause.fieldCrop ~= rel.cropKey) then pause = nil end\n",
    "    if pause ~= nil and (rel == nil or rel.cropKey == nil) then pause = nil end\n", 1)],
  "a barley pause shows on the resown wheat (S3)"),
 ("U02-tie-to-the-pause", PANEL,
  [(PRECEDENCE, PRECEDENCE.replace(") > (", ") >= ("), 1)],
  "a tie goes to the pause (N8)"),
 ("U03-pause-always-wins", PANEL,
  [(PRECEDENCE, "", 1)],
  "an older pause hides a newer pass (N5)"),
 ("U04-pause-not-drawn", PANEL,
  [("    if pause ~= nil then\n        local p = RfPdaSoilPanel.TARGET_PDA_PAUSE\n"
    "        stateText, noteText, stateColor = tr(p.line), tr(p.note), COLOR_FAIR\n    elseif copy ~= nil then\n",
    "    if copy ~= nil then\n", 1)],
  "the card never draws the pause (E4, C6)"),
 ("U05-pause-reads-as-none", PANEL,
  [(PAUSE_COPY, PAUSE_COPY.replace("line = \"sf_tgt_pda_state_paused\"", "line = \"sf_tgt_pda_state_none\""), 1)],
  "the pause line reads as the pass line (E4, X0)"),
 ("U06-no-manual-hint", PANEL,
  [(PAUSE_COPY, PAUSE_COPY.replace("note = \"sf_tgt_pda_pause_hint\"", "note = \"sf_tgt_n_failed\""), 1)],
  "the pause's note is another reason's (E5, X0)"),
 ("U08-hud-width-hint", PANEL,
  [(PAUSE_COPY, PAUSE_COPY.replace("note = \"sf_tgt_pda_pause_hint\"", "note = \"sf_tgt_n_manual\""), 1)],
  "the note is the HUD's wider manual hint again (E5, X0)"),
 ("U07-pass-colour", PANEL,
  [("        stateText, noteText, stateColor = tr(p.line), tr(p.note), COLOR_FAIR\n",
    "        stateText, noteText, stateColor = tr(p.line), tr(p.note), COLOR_GOOD\n", 1)],
  "the pause is drawn in REACHED's colour (E7)"),
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
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:30s} {rel}  {why}")
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
        rc, _, out = run_bench()
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
        rc, fails, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertionFails = [f for f in fails if "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:3]: print("    " + f[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
