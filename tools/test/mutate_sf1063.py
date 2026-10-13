# SoilFertilizer #1063 mutation battery: pass % on unsectioned seeders and spreaders.
# The lines the change touches: the rate multiplier append's record (src/hooks/HookManager.lua,
# installSprayerStartHook), the shared usage terms and native rate (getSprayUsageTerms,
# getNativeSprayRatePerHa), the sprayer hook's coverage divisor and its two live call sites,
# and trackSprayerCoverage's litre estimate (src/SoilFertilitySystem.lua). Rows live in
# SF-1063-pass_percent_unsectioned_spec_test.lua, RSF-F196-unit_rule_test.lua and the
# MAINT-166 world's bars.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs
# through `node run-tests.mjs --loads ...`, selecting the benches that can see it:
#   HookManager mutants: src/target/TargetApplication.lua (the #1063 bar and the SF-73 bars)
#     and tools/test/lua/MAINT-166-protection_sprayer_world.lua (the protection world's bars);
#   trackSprayerCoverage mutants: src/target/TargetApplication.lua and src/ui/SoilHUD.lua
#     (the RSF-F196 unit-rule bars).
# Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the record's placement inside the non-zero usage branch (versus after it): the two
#     differ only for a usage that is 0 at the start and filled in later, AI-1's buy-mode
#     injection. No bench world reaches it: in buy mode Soil's own external fill hook
#     returns the custom product's usage (installExternalFillHook), so the start sees a
#     non-zero usage.
#   - the multi-tank call's rate argument (the MAINTENANCE 169 replay): that call always
#     runs under the coverage hold, and trackSprayerCoverage returns at the hold before it
#     reads the rate, so the argument is never used. It is passed for the signature.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sf1063.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_sf1063.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_sf1063.py --baseline the selected benches, unmutated (both selections)
#        py tools/test/mutate_sf1063.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"
SFS = "src/SoilFertilitySystem.lua"
SEL_HOOK = ["--loads", "src/target/TargetApplication.lua", "--loads", "tools/test/lua/MAINT-166-protection_sprayer_world.lua"]
SEL_COV = ["--loads", "src/target/TargetApplication.lua", "--loads", "src/ui/SoilHUD.lua"]

MUTATIONS = [
 # ── the start hook's record ───────────────────────────────────────────────
 ("H01-record-never-set", HM, SEL_HOOK,
  [("                wap.usage = wap.usage * totalMult\n                wap.sfRateMult = totalMult\n",
    "                wap.usage = wap.usage * totalMult\n", 1)],
  "the multiplier is applied but not recorded: a 0.5x pass reads 50% (B, D, F, K, P, R)"),
 ("H02-record-not-reset", HM, SEL_HOOK,
  [("            local wap = spec.workAreaParameters\n            wap.sfRateMult = 1.0\n",
    "            local wap = spec.workAreaParameters\n", 1)],
  "a 1.0x tick keeps the last 0.5x record (R1)"),

 # ── the shared terms and the native rate ──────────────────────────────────
 ("H03-native-rate-units", HM, SEL_HOOK,
  [("    return fillScale * lps * 36000\n", "    return fillScale * lps * 3600\n", 1)],
  "the native rate is a tenth of the formula's (A-F)"),
 ("H04-lps-ignored", HM, SEL_HOOK,
  [("    local lps = spT and spT.litersPerSecond or 1\n    return fillScale, lps\n",
    "    local lps = 1\n    return fillScale, lps\n", 1)],
  "the spray type's litersPerSecond is dropped from the terms (the dose rows, A-F)"),
 ("H05-type-scale-ignored", HM, SEL_HOOK,
  [("        fillScale = (scales and fillTypeIndex and scales[fillTypeIndex])\n            or spec.usageScale.default or 1\n",
    "        fillScale = spec.usageScale.default or 1\n", 1)],
  "the per-fill-type usage scale is dropped (E)"),
 ("H06-default-scale-ignored", HM, SEL_HOOK,
  [("        fillScale = (scales and fillTypeIndex and scales[fillTypeIndex])\n            or spec.usageScale.default or 1\n",
    "        fillScale = (scales and fillTypeIndex and scales[fillTypeIndex]) or 1\n", 1)],
  "the default usage scale is dropped (F)"),
 ("H07-usage-own-terms", HM, SEL_HOOK,
  [("            local fillScale, lps = HookManager.getSprayUsageTerms(sprayerSelf, fillType)\n",
    "            local fillScale, lps = 1, spT and spT.litersPerSecond or 1\n", 1)],
  "the usage formula stops sharing the coverage's terms and drops the scale (E, F)"),

 # ── the sprayer hook's divisor and its call sites ─────────────────────────
 ("H08-divisor-ignores-record", HM, SEL_HOOK,
  [("                    * ((_wapCov and _wapCov.sfRateMult) or 1.0)\n", "                    * 1.0\n", 1)],
  "the coverage divides by the native rate alone (B, D, F, K, P)"),
 ("H09-divisor-uses-rate-lookup", HM, SEL_HOOK,
  [("                    * ((_wapCov and _wapCov.sfRateMult) or 1.0)\n", "                    * rateMultiplier\n", 1)],
  "the hook's own rate lookup, without SF-79's pH factor (P)"),
 ("H10-unsectioned-call-no-rate", HM, SEL_HOOK,
  [("soilSys:trackSprayerCoverage(fieldId, liters, fillType.name, true, coverageLitersPerHa)",
    "soilSys:trackSprayerCoverage(fieldId, liters, fillType.name, true)", 1)],
  "the unsectioned fertilizer track passes no rate (A-F, P)"),
 ("H11-protection-call-no-rate", HM, SEL_HOOK,
  [("trackSprayerCoverage(fieldId, liters, fillType.name, _useLitCov, coverageLitersPerHa)",
    "trackSprayerCoverage(fieldId, liters, fillType.name, _useLitCov)", 1)],
  "the crop-protection track passes no rate (K)"),

 # ── trackSprayerCoverage's litre estimate ─────────────────────────────────
 ("T01-base-rates-divisor", SFS, SEL_COV,
  [("    local areaThisTick = liters / litersPerHa\n",
    "    local baseRates = SoilConstants.SPRAYER_RATE.BASE_RATES\n    local areaThisTick = liters / (baseRates[fillTypeName] or baseRates.DEFAULT).value\n", 1)],
  "the old divisor, BASE_RATES (A-F, P, U E1)"),
 ("T02-mass-conversion-kept", SFS, SEL_COV,
  [("    local areaThisTick = liters / litersPerHa\n",
    "    local areaThisTick = massEquivalent(g_fillTypeManager and g_fillTypeManager:getFillTypeByName(fillTypeName), liters) / litersPerHa\n", 1)],
  "site 3's density conversion kept on litres over litres (U E1)"),
 ("T03-missing-rate-falls-back", SFS, SEL_COV,
  [("        SoilFertilitySystem.coverageRateMissing = (SoilFertilitySystem.coverageRateMissing or 0) + 1\n        return\n",
    "        SoilFertilitySystem.coverageRateMissing = (SoilFertilitySystem.coverageRateMissing or 0) + 1\n        litersPerHa = 93.5\n", 1)],
  "a call with no rate counts area at a guessed rate (U E5)"),
 ("T04-missing-rate-silent", SFS, SEL_COV,
  [("        SoilFertilitySystem.coverageRateMissing = (SoilFertilitySystem.coverageRateMissing or 0) + 1\n", "", 1)],
  "a call with no rate is not counted (U E6)"),
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


def run_bench(select):
    r = subprocess.run(["node", "run-tests.mjs"] + select, cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL ") or "Lua error" in l]
    crashed = "Lua error" in out or "group raised" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, _, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        worst = 0
        for name, select in (("hook", SEL_HOOK), ("coverage", SEL_COV)):
            rc, _, _, out = run_bench(select)
            lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.strip().splitlines()]
            print(f"{name}: " + (lines[-1] if lines else "(no output)"))
            worst = max(worst, rc)
        return worst
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, select, edits, why = picked[0]
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
        rc, fails, crashed, _ = run_bench(select)
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
