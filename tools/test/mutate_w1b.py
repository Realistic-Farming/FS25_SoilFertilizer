# SoilFertilizer SF-73 W1b mutation battery: the PDA's target card (src/ui/RfPdaSoilPanel.lua), the one display
# order and classifiers W1a and W1b share (src/target/TargetNutrientCore.lua, SoilHUD's references), the per-field
# display memory (src/target/TargetApplication.lua) and its two soil reads (src/SoilFertilitySystem.lua). Rows live
# in SF-73-W1b-pda_target_card_spec_test.lua, with W1a's in SF-73-W1a-hud_target_block_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ui/RfPdaSoilPanel.lua --loads src/target/TargetNutrientCore.lua` (12 files): the
# W1b and W1a benches, every bench that loads the core (and with it TargetApplication) or the panel, and the main.lua
# loaders. The SoilFertilitySystem and SoilHUD mutants use the same selection: the two soil reads have no caller but
# the panel, and SoilHUD's references are read by the W1a and W1b benches it selects. Run ONE mutant per call, in the
# foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - noteFieldOutcome's number test on the field: every footprint outcome carries its verified field (the plan's),
#     so no outcome without one reaches it;
#   - the card's feature detection: without it the paint errors inside the pcall the host already wraps, which draws
#     the same "nothing new" group D pins;
#   - the state colours: presentation, not behaviour (the in-game check);
#   - the shown flag's reset on a paint error, and its error log: the painter is not made to throw;
#   - the host's reset of the shown flag before the call: refreshTargetCard resets it itself first, so the
#     mutant is equivalent;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_w1b.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_w1b.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_w1b.py --baseline the selected benches, unmutated
#        py tools/test/mutate_w1b.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

PDA = "src/ui/RfPdaSoilPanel.lua"
CORE = "src/target/TargetNutrientCore.lua"
TA = "src/target/TargetApplication.lua"
SFS = "src/SoilFertilitySystem.lua"
HUD = "src/ui/SoilHUD.lua"
SELECT = ["--loads", "src/ui/RfPdaSoilPanel.lua", "--loads", "src/target/TargetNutrientCore.lua"]

MUTATIONS = [
 # ── the shared display order and classifiers (the core) ─────────────────
 ("N01-access-after-crop", CORE,
  [('    "FARM_ACCESS", "UNKNOWN_PRODUCT", "OUTSIDE_MAP", "UNKNOWN_GROUND", "MIXED_FIELD", "MIXED_CROP",\n'
    '    "UNSUPPORTED_CROP",',
    '    "UNKNOWN_PRODUCT", "OUTSIDE_MAP", "UNKNOWN_GROUND", "MIXED_FIELD", "MIXED_CROP",\n'
    '    "UNSUPPORTED_CROP", "FARM_ACCESS",', 1)],
  "denied access ranks below no crop (W1b P2, W1a M2)"),
 ("N02-quantized-not-outcome", CORE,
  [("                     SHORT_QUANTIZED = true, APPLICATION_FAILED = true }\n",
    "                     APPLICATION_FAILED = true }\n", 1)],
  "a quantized shortfall is not an outcome (W1a T18)"),
 ("N03-hold-without-field", CORE,
  [('    return type(r) == "table" and r.doseState == "INACTIVE" and #(r.reasons or {}) == 0 and r.fieldId ~= nil\n',
    '    return type(r) == "table" and r.doseState == "INACTIVE" and #(r.reasons or {}) == 0\n', 1)],
  "a native-inactive cycle is a hold (W1a P9)"),
 ("N04-no-primary-reason", CORE,
  [("        if has[x] then return x end\n", "", 1)],
  "no result ever names a reason (W1a E4, W1b P2)"),
 # ── SoilHUD's references ────────────────────────────────────────────────
 ("H01-priority-a-copy", HUD,
  [("SoilHUD.TARGET_REASON_PRIORITY = TargetNutrientCore and TargetNutrientCore.REASON_DISPLAY_ORDER or nil\n",
    "SoilHUD.TARGET_REASON_PRIORITY = TargetNutrientCore and { unpack(TargetNutrientCore.REASON_DISPLAY_ORDER) } or nil\n", 1)],
  "the HUD's priority is a copy, not the core's own (W1b P1)"),
 # ── the per-field display memory (TargetApplication) ────────────────────
 ("A01-server-not-noted", TA,
  [("    self:noteFieldOutcome(r)   -- remembered only when it is a footprint outcome (the writer's own test)\n", "", 1)],
  "the server never remembers the field's outcome (W1b E7)"),
 ("A02-holds-noted", TA,
  [('    if type(r) ~= "table" or not C.isOutcome(r) or type(r.fieldId) ~= "number" then return end\n',
    '    if type(r) ~= "table" or type(r.fieldId) ~= "number" then return end\n', 1)],
  "every result is remembered, so a hold overwrites the outcome (W1b E7)"),
 ("A03-client-not-noted", TA,
  [("    self:noteFieldOutcome(result)\n", "", 1)],
  "a client never remembers a received outcome (W1b C4)"),
 ("A04-reset-keeps", TA,
  [("    self.client = {}\n    self.lastOutcomeByField = {}\nend\n", "    self.client = {}\nend\n", 1)],
  "a reload keeps the old passes (W1b K5)"),
 ("A05-read-not-a-copy", TA,
  [("    local r = C.copy(rec.result)\n", "    local r = rec.result\n", 1)],
  "the read hands out the memory itself (W1b E13)"),
 # ── the soil reads ──────────────────────────────────────────────────────
 ("S01-pass-ungated", SFS,
  [("function SoilFertilitySystem:getLastTargetPassForField(fieldId)\n    if not self:isTargetGateOpen() then return nil end\n",
    "function SoilFertilitySystem:getLastTargetPassForField(fieldId)\n", 1)],
  "the last pass is read while locked (W1b K3)"),
 ("S02-reason-ungated", SFS,
  [("function SoilFertilitySystem:getTargetPrimaryReason(result)\n    if not self:isTargetGateOpen() then return nil end\n",
    "function SoilFertilitySystem:getTargetPrimaryReason(result)\n", 1)],
  "the published reason is read while locked (W1b P3)"),
 # ── the PDA painter ─────────────────────────────────────────────────────
 ("U01-card-while-locked", PDA,
  [('    if fieldId == nil or ss == nil or type(ss.isTargetGateOpen) ~= "function" or ss:isTargetGateOpen() ~= true then\n',
    '    if fieldId == nil or ss == nil then\n', 1)],
  "the card shows while locked (W1b L2, K1)"),
 ("U02-any-crop", PDA,
  [("    if pass ~= nil and (rel == nil or rel.cropKey == nil or pass.cropKey ~= rel.cropKey) then pass = nil end\n", "", 1)],
  "another crop's pass is shown (W1b R2)"),
 ("U03-wrong-word", PDA,
  [('    BELOW = "sf_tgt_pda_rel_below", APPROACHING = "sf_tgt_pda_rel_near", IDEAL = "sf_tgt_pda_rel_ok",\n',
    '    BELOW = "sf_tgt_pda_rel_below", APPROACHING = "sf_tgt_pda_rel_near", IDEAL = "sf_tgt_pda_rel_below",\n', 1)],
  "an in-window nutrient reads low (W1b E6)"),
 ("U04-window-unlabelled", PDA,
  [("        windowText = string.format(tr(K.window), words[1], words[2], words[3])\n",
    "        windowText = words[1] .. \", \" .. words[2] .. \", \" .. words[3]\n", 1)],
  "the window loses its field-report label (W1b E6)"),
 ("U05-binding-unnamed", PDA,
  [('        if pass.doseState == "SHORT_BINDING" then noteText = string.format(noteText, tostring(pass.binding or "?")) end\n', "", 1)],
  "the blend note names no nutrient (W1b E14)"),
 ("U06-litres-swapped", PDA,
  [("        detailText = string.format(tr(K.litres), targetPdaLitres(pass.plannedLitres), targetPdaLitres(pass.physicalLitres))\n",
    "        detailText = string.format(tr(K.litres), targetPdaLitres(pass.physicalLitres), targetPdaLitres(pass.plannedLitres))\n", 1)],
  "planned and applied change places (W1b F4)"),
 ("U07-no-scope", PDA,
  [('    REACHED            = { line = "sf_tgt_pda_state_reached",   note = "sf_tgt_pda_scope",   color = "good" },\n',
    '    REACHED            = { line = "sf_tgt_pda_state_reached",   color = "good" },\n', 1)],
  "a reached pass is not scoped to one footprint (W1b E8)"),
 ("U08-heading-never", PDA,
  [("        if page._targetCardShown == true then\n", "        if false then\n", 1)],
  "the legacy heading never reads as the manual plan's (W1b E10)"),
 ("U09-heading-always", PDA,
  [("        if page._targetCardShown == true then\n", "        if true then\n", 1)],
  "the legacy heading is relabelled with no card (W1b L3, D1, K2)"),
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
    crashed = "Lua error" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:28s} {rel}  {why}")
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
    assertionFails = [f for f in fails if "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
