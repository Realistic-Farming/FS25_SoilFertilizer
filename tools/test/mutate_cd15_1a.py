# SoilFertilizer CD-15 step 1a mutation battery: the grid (src/disease/CD15Grid.lua),
# the logical day (src/disease/CD15Day.lua), the server model (src/disease/CD15Model.lua)
# and the four seams in src/SoilFertilitySystem.lua. Rows live in
# CD15-1a-local_grid_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-30): each mutant runs through `node run-tests.mjs --loads
# src/disease/CD15Model.lua`, which selects the one bench that loads the model; every
# seam in SoilFertilitySystem.lua is guarded by self.cd15, which is nil wherever the model
# is not loaded. Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - local soil health replaced by SoilDiseaseSystem.soilHealthMult: its pH/N/OM
#     defaults (6.5, 50, 3.5) all fall on the neutral side of every threshold, so the
#     number is the same; what differs is the UNKNOWN provenance, which nothing reads
#     until step 3's player view;
#   - the dry-day damping multiplier: the drought row passes the damped band in one day;
#   - the explicit living-crop check on a spread destination (CD15Model:admits): run once,
#     it SURVIVED as an equivalent mutant, because CD15Day.cropCompatible already refuses
#     a cell with no crop; the check stays for 1c, where "living" becomes the witness.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_cd15_1a.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_cd15_1a.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_cd15_1a.py --baseline the bench, unmutated
#        py tools/test/mutate_cd15_1a.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GR = "src/disease/CD15Grid.lua"
DY = "src/disease/CD15Day.lua"
MD = "src/disease/CD15Model.lua"
SFS = "src/SoilFertilitySystem.lua"
SELECT = ["--loads", "src/disease/CD15Model.lua"]

MUTATIONS = [
 # ── the clock (:107) ───────────────────────────────────────────────────────
 ("K1-day-falls-to-currentDay", DY,
  [("        day = env ~= nil and env.currentMonotonicDay or nil", "        day = env ~= nil and (env.currentMonotonicDay or env.currentDay) or nil", 1)],
  "the wrapping currentDay becomes the fallback (K4)"),
 ("K2-timeguard-ignored", DY,
  [("    local day, source = nil, nil\n    if tg ~= nil then", "    local day, source = nil, nil\n    if false then", 1)],
  "the environment is read even with Time Guard present (K1)"),
 ("K3-timeguard-nil-falls-to-env", DY,
  [("        if ok then day = d end\n", "        if ok then day = d end\n        if day == nil then local env = g_currentMission.environment day = env and env.currentMonotonicDay end\n", 1)],
  "Time Guard's nil is replaced by the environment's day (K2)"),
 ("K4-backward-accepted", DY,
  [("    if previousDay ~= nil and day < previousDay then return nil, \"DAY_BACKWARD\", source end\n", "", 1)],
  "a backward day is settled (K5)"),
 ("K5-zero-rejected", DY,
  [("    if not isInteger(day) or day < 0 then return nil, \"DAY_UNAVAILABLE\", source end", "    if not isInteger(day) or day <= 0 then return nil, \"DAY_UNAVAILABLE\", source end", 1)],
  "a real zero day is refused (K3)"),
 ("K6-context-zero-days-per-period", DY,
  [("        if ok and type(ctx) == \"table\" and isFinite(ctx.daysPerPeriod) and ctx.daysPerPeriod > 0 then return ctx.daysPerPeriod end",
    "        if ok and type(ctx) == \"table\" and isFinite(ctx.daysPerPeriod) then return ctx.daysPerPeriod end", 1)],
  "Time Guard's missing-environment zero is taken as daysPerPeriod (K3)"),

 # ── the day's work and its gaps (:107, :127) ───────────────────────────────
 ("S1-gap-not-recorded", MD,
  [("    if self.lastDay ~= nil and day > self.lastDay + 1 then addGap(self, self.lastDay + 1, day - 1, \"NO_CAPTURED_INPUT\") end\n", "", 1)],
  "a skipped interval leaves no UNAVAILABLE record (S1)"),
 ("S2-skipped-days-replayed", MD,
  [("    if self.lastDay ~= nil and day > self.lastDay + 1 then addGap(self, self.lastDay + 1, day - 1, \"NO_CAPTURED_INPUT\") end\n",
    "    if self.lastDay ~= nil and day > self.lastDay + 1 then for d = self.lastDay + 1, day - 1 do local i = CD15Day.captureInput(self.system, d) if i then self.queue[#self.queue + 1] = { input = i, phase = \"SETTLE\" } end end end\n", 1)],
  "the missing days are settled with today's weather (S1, S2)"),
 ("S3-no-input-no-record", MD,
  [("        addGap(self, day, day, whyInput)\n        return", "        return", 1)],
  "a day without its inputs closes silently (K6)"),

 # ── one cell, one day (:127-133) ───────────────────────────────────────────
 ("F1-decay-exponent", DY,
  [("        decayPerDay = SoilConstants.RESISTANCE.DECAY_MONTHLY ^ (1 / dpm),", "        decayPerDay = SoilConstants.RESISTANCE.DECAY_MONTHLY,", 1)],
  "a whole month's decay each day (F3)"),
 ("F2-floor-removed", DY,
  [("            if nv < D.RESISTANCE_FLOOR then nv = 0 end\n", "", 1)],
  "resistance below .01 is kept (F3)"),
 ("F3-meadow-not-exempt", DY,
  [("    if ci.meadow then return finish(c, day, \"MEADOW\") end\n", "", 1)],
  "a meadow cell grows disease (F9)"),
 ("F4-disabled-field-settled", DY,
  [("    if ci.disabled then return finish(c, day, \"DISABLED_FIELD\") end\n", "", 1)],
  "a field FieldSentry disables is simulated (F10)"),
 ("F5-protection-on-expiry-day", DY,
  [("        if expiry > day then return true end", "        if expiry >= day then return true end", 1)],
  "protection still holds on its expiry day (F5b)"),
 ("F6-drought-rate-per-month", DY,
  [("        c.pressure = math.max(0, pressure - dp.DRY_DECAY_RATE * input.dryDecayMult * dt)", "        c.pressure = math.max(0, pressure - dp.DRY_DECAY_RATE * input.dryDecayMult)", 1)],
  "drought decay is not scaled to one day (F4)"),
 ("F7-soil-branch-off", DY,
  [("        local soilMult = D.localSoilHealthMult(ci.soil)", "        local soilMult = 1.0", 1)],
  "the cell's own soil health is ignored (F2)"),
 ("F8-rotation-neutral", DY,
  [("        local rotMult = input.cropRotation and D.localRotationMult(c) or 1.0", "        local rotMult = 1.0", 1)],
  "the cell's harvested history is ignored (F12)"),
 ("F9-crop-mult-dropped", DY,
  [("        local cropMult = dp.CROP_SUSCEPTIBILITY[string.lower(c.cropName)] or 1.0", "        local cropMult = 1.0", 1)],
  "the crop's susceptibility is dropped (F1)"),
 ("F10-onset-at-LOW", DY,
  [("    elseif c.diseaseName == nil and living and c.pressure >= low * 0.5 then", "    elseif c.diseaseName == nil and living and c.pressure >= low then", 1)],
  "onset waits for LOW instead of LOW*.5 (F6)"),
 ("F11-hybrid-no-cooldown", DY,
  [("            c.hybridCooldownExpiryDay = day + HybridStrains.cooldownDays(input.daysPerMonth)\n", "", 1)],
  "a cleared hybrid arms no cooldown (F7)"),
 ("F12-onset-without-crop", DY,
  [("    elseif c.diseaseName == nil and living and c.pressure >= low * 0.5 then", "    elseif c.diseaseName == nil and c.pressure >= low * 0.5 then", 1)],
  "a cell with no living crop gets an identity (F8)"),
 ("F13-setting-ignored", DY,
  [("    if not input.diseaseEnabled then return finish(c, day, \"DISABLED_SETTING\") end\n", "", 1)],
  "disease runs with the setting off (F11)"),
 ("F14-new-identity-discovered", DY,
  [("            c.diseaseName = id\n            c.discovered = false", "            c.diseaseName = id\n            c.discovered = true", 1)],
  "a fresh infection starts discovered (F6)"),

 # ── spread (:115-124) ──────────────────────────────────────────────────────
 ("P1-no-snapshot", MD,
  [("                self.stats.spreadPairs = self.stats.spreadPairs + CD15Day.spreadFrom(self.store, s, admits)\n",
    "                self.stats.spreadPairs = self.stats.spreadPairs + CD15Day.spreadFrom(self.store, s, admits)\n                w.sources = CD15Day.snapshotSources(self.store, input.day)\n", 1)],
  "the source list is re-read after each hop, so a new infection spreads the same day (P3)"),
 ("P2-competing-takes-pressure", DY,
  [("            if same then", "            if true then", 1)],
  "a competing identity receives pressure and resistance (P4)"),
 ("P3-later-overwrites-clean", DY,
  [("            if dest.diseaseName == nil then\n", "            if dest.diseaseName == nil or dest.diseaseName ~= source.diseaseName then\n", 1)],
  "a later source replaces the identity a clean cell took (P5)"),
 ("P4-merge-sum", DY,
  [("        if (into[mode] or 0) < v then into[mode] = v end", "        into[mode] = (into[mode] or 0) + v", 1)],
  "resistance is summed, not merged by max (P2)"),
 ("P5-protected-destination", MD,
  [("    if CD15Day.isProtected(dest, input.day) then return false end\n    if not CD15Day.cropCompatible", "    if not CD15Day.cropCompatible", 1)],
  "a protected destination receives disease (P7)"),
 ("P6-protected-source", DY,
  [("        if c ~= nil and c.diseaseName ~= nil and not D.isProtected(c, day) then", "        if c ~= nil and c.diseaseName ~= nil then", 1)],
  "a protected source spreads (P8)"),
 ("P7-crop-compatibility-skipped", MD,
  [("    if not CD15Day.cropCompatible(diseaseName, dest.cropName) then return false end\n", "", 1)],
  "a disease crosses to a crop it does not belong to (P7)"),
 ("P8-meadow-destination", MD,
  [("    if ci.disabled or ci.meadow then return false end\n    return (self:wetAt(ci, input))", "    return (self:wetAt(ci, input))", 1)],
  "a meadow destination receives disease (P12)"),
 ("P9-scs-grain-unchecked", MD,
  [("        if ok and CD15Grid.isFinite(m) and m >= 0 and m <= 1 and CD15Grid.isFinite(grain) and grain > 0 and grain <= self.geometry.cellSize then",
    "        if ok and CD15Grid.isFinite(m) and m >= 0 and m <= 1 then", 1)],
  "a coarse moisture read counts as a fine fact (P11)"),
 ("P10-scs-ignored", MD,
  [("    local cs = moistureSource()\n    if cs ~= nil and ci.fieldId ~= nil then", "    local cs = nil\n    if cs ~= nil and ci.fieldId ~= nil then", 1)],
  "the fine moisture fact is never read (P10)"),
 ("P11-spread-amount", DY,
  [("D.SPREAD_POINTS = 4 ", "D.SPREAD_POINTS = 5 ", 1)],
  "the spread amount is not the existing 4 points (P1)"),

 # ── the work bound (:127) ──────────────────────────────────────────────────
 ("B1-no-bound", MD,
  [("M.WORK_BOUND = 256", "M.WORK_BOUND = 100000", 1)],
  "one update settles every cell (B1)"),
 ("B2-settled-twice", MD,
  [("    if c.lastSettledDay ~= nil and c.lastSettledDay >= input.day then return false end\n", "", 1)],
  "a cell already settled through the day is settled again (B3)"),

 # ── geometry and the store (:83-85, :216) ──────────────────────────────────
 ("G1-fingerprint-without-native", GR,
  [("    geom.fingerprint = string.format(\"%s:%d;terrain=%.17g;fine=%d;native=%d;origin=%s\",\n        geom.namespace, geom.schema, terrainSize, resolution, nativeMapSize, geom.origin)",
    "    geom.fingerprint = string.format(\"%s:%d;terrain=%.17g;fine=%d;origin=%s\",\n        geom.namespace, geom.schema, terrainSize, resolution, geom.origin)", 1)],
  "the fingerprint omits the native map size (E2)"),
 ("G2-cell-size-inverted", GR,
  [("cellSize = terrainSize / resolution,", "cellSize = resolution / terrainSize,", 1)],
  "the cell size is inverted (E2)"),
 ("G3-native-size-guessed", GR,
  [("    if not isInteger(nativeMapSize) or nativeMapSize <= 0 then return nil, \"NATIVE_MAP_SIZE\" end\n", "    if not isInteger(nativeMapSize) or nativeMapSize <= 0 then nativeMapSize = 4096 end\n", 1)],
  "a missing native size is guessed (E9)"),
 ("G4-tile-key-transposed", GR,
  [("    return tx, tz, (gz - G.TILE * tz) * G.TILE + (gx - G.TILE * tx)", "    return tx, tz, (gx - G.TILE * tx) * G.TILE + (gz - G.TILE * tz)", 1)],
  "the local key is transposed (R1)"),
 ("G5-tile-order-tx-first", GR,
  [("    table.sort(tiles, function(a, b) if a.tz ~= b.tz then return a.tz < b.tz end return a.tx < b.tx end)",
    "    table.sort(tiles, function(a, b) if a.tx ~= b.tx then return a.tx < b.tx end return a.tz < b.tz end)", 1)],
  "tiles run tx first (R2)"),
 ("G6-disease-name-unchecked", GR,
  [("    if c.diseaseName ~= nil and not G.isDiseaseName(c.diseaseName) then return nil, \"DISEASE_NAME\" end\n", "", 1)],
  "an unknown disease name is stored (R3)"),
 ("G7-discovered-without-identity", GR,
  [("    if c.diseaseName == nil and c.discovered then return nil, \"DISCOVERED_WITHOUT_IDENTITY\" end\n", "", 1)],
  "a record discovered with no identity is stored (R3)"),

 # ── the seams (SoilFertilitySystem.lua) and the server gate ────────────────
 ("H1-no-day-seam", SFS,
  [("        if self.cd15 ~= nil then self.cd15:onDayChanged() end\n", "", 1)],
  "the daily settlement never reaches the model (E2)"),
 ("H2-no-update-seam", SFS,
  [("    if self.cd15 ~= nil then self.cd15:update(dt) end\n", "", 1)],
  "the cursor never runs (E5)"),
 ("H3-no-constructor", SFS,
  [("    self.cd15         = CD15Model        and CD15Model.new(self)    or nil", "    self.cd15         = nil", 1)],
  "the system never builds the model (E1)"),
 ("H4-delete-keeps-model", SFS,
  [("    if self.cd15 ~= nil then\n        self.cd15:delete()\n        self.cd15 = nil\n    end\n", "", 1)],
  "teardown keeps the model (E8)"),
 ("H5-client-works", MD,
  [("    if g_server == nil then return end\n    if not self:ensureGeometry() then return end", "    if not self:ensureGeometry() then return end", 1)],
  "a client binds a grid and queues a day (E7)"),
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
        for mid, rel, _, why in MUTATIONS: print(f"{mid:40s} {rel}  {why}")
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
        print(out.strip().splitlines()[-1] if out.strip() else "(no output)")
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
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
