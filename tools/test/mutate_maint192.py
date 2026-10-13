# SoilFertilizer MAINTENANCE row 192 mutation battery: Soil's rows in the native FIELD INFO
# box (src/hooks/HookManager.lua installNativeFieldInfoHook; src/ui/SoilHUD.lua, the Yield
# row's group). Rows live in MAINT-192-field_info_late_slot_entry_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the changed lines. Each mutant runs
# through `node run-tests.mjs --loads src/ui/SoilHUD.lua` (11 files, a few seconds), which
# selects the bar. A HookManager mutant is seen by that selection too: the bar is the only
# bench that installs the field-info hook (the installAll benches have no PlayerHUDUpdater,
# so the install returns before it wraps anything). Run ONE mutant per call, in the
# foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint192.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_maint192.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_maint192.py --baseline the selected benches, unmutated
#        py tools/test/mutate_maint192.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

HM = "src/hooks/HookManager.lua"
HUD = "src/ui/SoilHUD.lua"
SELECT = ["--loads", "src/ui/SoilHUD.lua"]

MUTATIONS = [
 ("F01-late-slot-fruit", HM,
  [("        fieldAddField    = \"late\",\n", "        fieldAddFruit    = \"late\",\n", 1)],
  "the late group bound to the FS22 name again: the crop pass has no group, so it appends every row a second time (E4b, C3b)"),
 ("F02-field-not-primary", HM,
  [("    local fieldHookOk    = installFieldInfoFn(\"fieldAddField\", true)\n",
    "    local fieldHookOk    = installFieldInfoFn(\"fieldAddField\", false)\n", 1)],
  "fieldAddField wrapped but appends nothing: no late rows (E3)"),
 ("F03-scan-wraps-field-too", HM,
  [("                and key ~= \"fieldAddFarmland\" and key ~= \"fieldAddField\"\n",
    "                and key ~= \"fieldAddFarmland\" and key ~= \"fieldAddFruit\"\n", 1)],
  "the extras scan wraps fieldAddField a second time (E0b)"),
 ("F04-yield-row-early", HUD,
  [("    table.insert(lines, { group = \"late\",  label = SoilL10n.tr(\"sf_fieldinfo_yield\", \"Yield\"),      value = yieldStr })\n",
    "    table.insert(lines, { group = \"early\", label = SoilL10n.tr(\"sf_fieldinfo_yield\", \"Yield\"),      value = yieldStr })\n", 1)],
  "Soil's Yield row appended before the override ran: two yield rows (E2), above the crop rows (C3)"),
 ("F05-yield-not-matched", HM,
  [("                            if replacementText ~= nil and matchedLabel == nil and isEngineLabel(label, YIELD_BONUS_KEY) then\n",
    "                            if replacementText ~= nil and matchedLabel == nil and false then\n", 1)],
  "the native yield row keeps the engine's number, and Soil's row shows too (E2, R1)"),
 ("F06-fertilized-not-matched", HM,
  [("                            elseif isEngineLabel(label, FERTILIZED_KEY) then\n",
    "                            elseif false then\n", 1)],
  "the native Fertilized row is drawn (E5, R2)"),
 ("F07-english-labels-only", HM,
  [("        local ok, text = pcall(g_i18n.getText, g_i18n, key)\n",
    "        local ok, text = true, ({ fieldInfo_yieldBonus = \"Yield-bonus\", ui_growthMapFertilized = \"Fertilized\" })[key]\n", 1)],
  "the labels matched in English only: the Russian rows are missed (R1, R2)"),
 ("F08-override-not-recorded", HM,
  [("                hookManagerSelf._nativeYieldRowOverridden = true\n", "", 1)],
  "the override is not recorded, so Soil's Yield row shows beside it (E2, R1)"),
 ("F09-no-match-warns", HM,
  [("            if replacementText ~= nil and matchedLabel ~= nil then\n",
    "            if replacementText ~= nil and matchedLabel == nil then SoilLogger.warning(\"Native field info hook (%s): no native yield-bonus row matched\", functionName) end\n"
    "            if replacementText ~= nil and matchedLabel ~= nil then\n", 1)],
  "a wrapper that cannot see the yield row warns again (E6, C5, R3)"),
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
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
