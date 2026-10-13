# SoilFertilizer SF-73 W1a mutation battery: the rate panel's target block (src/ui/SoilHUD.lua) and
# the release-lock read it asks (src/SoilFertilitySystem.lua, isTargetGateOpen). Rows live in
# SF-73-W1a-hud_target_block_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs through
# `node run-tests.mjs --loads src/ui/SoilHUD.lua` (15 files), which selects the bar and every other
# bench that loads the HUD. The one SoilFertilitySystem mutant uses the same selection: the read it
# mutates has no caller but the HUD, so a bench that loads the soil system without the HUD cannot
# reach it. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the draw-time guard that drops a view built for another sprayer: update() and draw read the
#     same g_localPlayer in the same frame, so no bench row can make them differ;
#   - the tone colours and the row font sizes: presentation, not behaviour (the in-game check);
#   - the product and crop title fallbacks (fill type title, then the stored name, then "?"):
#     R3 pins the title path; the fallbacks only answer a missing fill type;
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_w1a.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_w1a.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_w1a.py --baseline the selected benches, unmutated
#        py tools/test/mutate_w1a.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HUD = "src/ui/SoilHUD.lua"
SFS = "src/SoilFertilitySystem.lua"
SELECT = ["--loads", "src/ui/SoilHUD.lua"]

MUTATIONS = [
 # ── which reason the block names, and the manual hint ───────────────────
 ("H01-access-after-crop", HUD,
  [('    "FARM_ACCESS", "UNKNOWN_PRODUCT", "OUTSIDE_MAP", "UNKNOWN_GROUND", "MIXED_FIELD", "MIXED_CROP",\n'
    '    "UNSUPPORTED_CROP",',
    '    "UNKNOWN_PRODUCT", "OUTSIDE_MAP", "UNKNOWN_GROUND", "MIXED_FIELD", "MIXED_CROP",\n'
    '    "UNSUPPORTED_CROP", "FARM_ACCESS",', 1)],
  "denied access ranks below the crop and the boundaries (E13, M2)"),
 ("H02-hint-beside-others", HUD,
  [('        if reason == "UNSUPPORTED_CROP" and #shown.reasons == 1 and not final then\n',
    '        if reason == "UNSUPPORTED_CROP" and not final then\n', 1)],
  "the hint shows beside another reason (M7)"),
 ("H03-hint-when-final", HUD,
  [('        if reason == "UNSUPPORTED_CROP" and #shown.reasons == 1 and not final then\n',
    '        if reason == "UNSUPPORTED_CROP" and #shown.reasons == 1 then\n', 1)],
  "the hint stays after AUTO is off (M5)"),
 ("H04-unknown-ground-no-note", HUD,
  [('    UNKNOWN_GROUND              = { line = "sf_tgt_r_unavailable", note = "sf_tgt_n_unknown_ground", tone = "paused" },\n',
    '    UNKNOWN_GROUND              = { line = "sf_tgt_r_unavailable", tone = "paused" },\n', 1)],
  "unknown ground and outside the map read the same (T5, T16)"),
 ("H05-field-as-crop", HUD,
  [('    MIXED_FIELD                 = { line = "sf_tgt_r_mixed_field", tone = "paused" },\n',
    '    MIXED_FIELD                 = { line = "sf_tgt_r_mixed_crop", tone = "paused" },\n', 1)],
  "a field boundary reads as a crop boundary (T4, T16)"),
 # ── the view: outcomes, holds, idle, final ──────────────────────────────
 ("H06-quantized-not-outcome", HUD,
  [("                SHORT_QUANTIZED = true, APPLICATION_FAILED = true }\n",
    "                APPLICATION_FAILED = true }\n", 1)],
  "a quantized shortfall is not read as an outcome (T18)"),
 ("H07-binding-unnamed", HUD,
  [('        if shown.doseState == "SHORT_BINDING" then view.noteArg = shown.binding or "?" end\n', "", 1)],
  "the binding note names no nutrient (T19)"),
 ("H08-hold-blanks-outcome", HUD,
  [("    if SoilHUD.isTargetHold(r) and confirmed ~= nil and confirmed.epoch == r.epoch then shown = confirmed end\n",
    "", 1)],
  "a hold replaces the confirmed outcome (R12)"),
 ("H09-hold-any-epoch", HUD,
  [("    if SoilHUD.isTargetHold(r) and confirmed ~= nil and confirmed.epoch == r.epoch then shown = confirmed end\n",
    "    if SoilHUD.isTargetHold(r) and confirmed ~= nil then shown = confirmed end\n", 1)],
  "a hold shows another epoch's outcome (R17)"),
 ("H10-final-hold-pending", HUD,
  [('        kind = final and "unavailable" or "pending"\n', '        kind = "pending"\n', 1)],
  "an uncharged final hold reads as pending (P7)"),
 ("H11-idle-unavailable", HUD,
  [('        kind = "idle"\n', '        kind = "unavailable"\n', 1)],
  "a switched-off machine reads as an unavailable target (P9)"),
 ("H12-hold-without-field", HUD,
  [('    return type(r) == "table" and r.doseState == "INACTIVE" and #(r.reasons or {}) == 0 and r.fieldId ~= nil\n',
    '    return type(r) == "table" and r.doseState == "INACTIVE" and #(r.reasons or {}) == 0\n', 1)],
  "a native-inactive cycle reads as a hold (P9)"),
 ("H13-no-final-title", HUD,
  [('    if view.final then rows[#rows + 1] = { text = tgt.text(K.title), tone = "note" } end\n', "", 1)],
  "a final result is not marked the last pass (R14, F8)"),
 # ── the detail rows ─────────────────────────────────────────────────────
 ("H14-reading-not-after", HUD,
  [("                local value = tgt.finite(x.after) and x.after or x.reading\n",
    "                local value = x.reading\n", 1)],
  "the nutrient row shows the pre-write reading (R5)"),
 ("H15-no-ppm", HUD,
  [("                    tgt.number(tgt.finite(value) and value * ppm or nil, 1),\n",
    "                    tgt.number(tgt.finite(value) and value or nil, 1),\n", 1)],
  "the value is drawn in internal units beside a ppm window (R5)"),
 ("H16-failed-shows-npk", HUD,
  [('    if r.doseState ~= "APPLICATION_FAILED" then\n', "    if true then\n", 1)],
  "a failed write shows N/P/K as if confirmed (F4)"),
 ("H17-useful-always", HUD,
  [("    if tgt.finite(r.agronomicLitres) then\n", "    if true then\n", 1)],
  "useful litres are drawn when unknown (F5)"),
 ("H18-litres-swapped", HUD,
  [("    rows[#rows + 1] = { text = string.format(tgt.text(K.litres), tgt.litres(r.plannedLitres),\n"
    "        tgt.litres(r.physicalLitres)), tone = \"detail\" }\n",
    "    rows[#rows + 1] = { text = string.format(tgt.text(K.litres), tgt.litres(r.physicalLitres),\n"
    "        tgt.litres(r.plannedLitres)), tone = \"detail\" }\n", 1)],
  "planned and applied litres change places (F5)"),
 # ── when the block exists ───────────────────────────────────────────────
 ("H19-no-gate", HUD,
  [("    if ss:isTargetGateOpen() ~= true then return nil end\n", "", 1)],
  "the block ignores the release lock (L6, L8)"),
 ("H20-any-product", HUD,
  [("        if tgt.finite(profile[n]) and profile[n] > 0 then return true end\n",
    "        return true\n", 1)],
  "a product with a profile but no N/P/K gets a block (P14, P15)"),
 ("H21-no-ready", HUD,
  [('            kind = "ready"\n', "            return nil\n", 1)],
  "AUTO on with no pass yet falls back to the legacy line (P0)"),
 ("H22-never-expired", HUD,
  [('            kind = mem.seen and "expired" or "waiting"\n', '            kind = "waiting"\n', 1)],
  "an expired result reads as waiting (C7)"),
 ("H23-update-builds-nothing", HUD,
  [("    self._cachedTargetView = self:buildTargetView(sprayer, _ss, rm, _rateVehId, self._cachedProfile)\n",
    "    self._cachedTargetView = nil\n", 1)],
  "update() never builds the block (E4, C4)"),
 # ── the notice ──────────────────────────────────────────────────────────
 ("H24-notice-every-frame", HUD,
  [("    if mem.notified[key] then return end\n", "", 1)],
  "the notice repeats every frame (E8, C6, N2)"),
 ("H25-host-failure-twice", HUD,
  [("        if g_server ~= nil then return end\n", "", 1)],
  "the host hears a failure twice (F7)"),
 ("H26-final-refusal-notifies", HUD,
  [("    elseif r.active ~= false and view.reason ~= nil and not SoilHUD.TARGET_REASON_COPY[view.reason].notRefusal then\n",
    "    elseif view.reason ~= nil and not SoilHUD.TARGET_REASON_COPY[view.reason].notRefusal then\n", 1)],
  "a final refusal notifies after AUTO is off (N6)"),
 ("H27-priming-notifies", HUD,
  [("    elseif r.active ~= false and view.reason ~= nil and not SoilHUD.TARGET_REASON_COPY[view.reason].notRefusal then\n",
    "    elseif r.active ~= false and view.reason ~= nil then\n", 1)],
  "priming notifies as a refusal (P3)"),
 ("H28-notices-outlive-epoch", HUD,
  [("        if mem.epoch ~= r.epoch then mem.epoch, mem.confirmed, mem.notified = r.epoch, nil, {} end\n",
    "        if mem.epoch ~= r.epoch then mem.epoch, mem.confirmed = r.epoch, nil end\n", 1)],
  "a new activation stays silent on a refusal already told (N5)"),
 ("H29-no-prune", HUD,
  [("        if type(vehicle) ~= \"table\" or vehicle.isDeleted == true then self._targetMemory[vehicle] = nil end\n",
    "", 1)],
  "a deleted vehicle's memory is kept (N7)"),
 # ── the draw ────────────────────────────────────────────────────────────
 ("H30-legacy-line-kept", HUD,
  [("    if isAuto and fillType and tRows == nil then\n", "    if isAuto and fillType then\n", 1)],
  "the legacy 'Target:' line stays under target mode (E6, R10)"),
 ("H31-panel-not-grown", HUD,
  [("    local panelH  = warningH + padV + barH + padV + scrollH + padV + headerH + blockH\n",
    "    local panelH  = warningH + padV + barH + padV + scrollH + padV + headerH\n", 1)],
  "the panel does not grow: the rows overlap the rate row (E11)"),
 ("H32-no-fit", HUD,
  [("            if w ~= nil and w > maxW and w > 0 then size = size * maxW / w end\n", "", 1)],
  "a row too wide spills past the panel (W1)"),
 # ── the release-lock read ───────────────────────────────────────────────
 ("S01-gate-always-open", SFS,
  [("    return ok and open == true\nend\n", "    return true\nend\n", 1)],
  "the HUD's lock read answers open while locked (L3, L6, L8)"),
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
    # a group's error row ("ran to its end without a Lua error") is a crash, not an assertion
    assertionFails = [f for f in fails if "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertionFails else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:5]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
