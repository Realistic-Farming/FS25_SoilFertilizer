#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF-73 target-accurate N/P/K (Soil host slice): do the bars catch what they claim?

Each mutation breaks one clause of SF-73 Implementation v1.1 in shipped code and
requires one of the SF-73 bars to go RED with named FAIL rows. A bar that dies on a
Lua error instead is recorded CRASH, which is not a kill (a crash is unattributable).
Every target is restored in a finally and proved by sha256.

Run from tools/test:  py -u mutate_sf73.py
"""
import hashlib
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
FILES = {
    "ta":   os.path.join(ROOT, "src", "target", "TargetApplication.lua"),
    "fp":   os.path.join(ROOT, "src", "target", "TargetFootprint.lua"),
    "core": os.path.join(ROOT, "src", "target", "TargetNutrientCore.lua"),
    "net":  os.path.join(ROOT, "src", "network", "NetworkEvents.lua"),
    "sys":  os.path.join(ROOT, "src", "SoilFertilitySystem.lua"),
}
BARS = ["SF-73-target_entry_point_test.lua", "SF-73-target_core_spec_test.lua",
        "SF-73-baseline_persistence_spec_test.lua", "SF-73-mode_and_result_events_spec_test.lua",
        "SF-73-width_witness_spec_test.lua"]
TICK, CROSS = "✓", "✗"

# (id, file, [(old, new, count)], the clause it breaks, the rows expected to go red)
MUTATIONS = [
    ("writer-order-swapped", "ta",
     [("                    ok = vm:setPolygonWhere(key, plan.verts, 255, 256 - raw, 255) == true\n"
       "                    if ok then ok = vm:applyRawDeltaToPolygonBand(key, plan.verts, raw, 1, 255 - raw) ~= nil end\n",
       "                    ok = vm:applyRawDeltaToPolygonBand(key, plan.verts, raw, 1, 255 - raw) ~= nil\n"
       "                    if ok then ok = vm:setPolygonWhere(key, plan.verts, 255, 256 - raw, 255) == true end\n", 1)],
     "section 5: the band is added BEFORE the original overflow cohort saturates", "E4.3"),

    ("requested-litres-not-applied", "ta",
     [("        applied = math.abs(cycle.applied)\n", "        applied = plan.quote\n", 1)],
     "section 4: the planned quote stands in for FillUnit's applied delta", "E3"),

    ("refusal-keeps-fill-level", "ta",
     [("    else\n        wap.usage = 0\n        wap.usagePerMin = 0\n        wap.sprayFillLevel = 0\n    end\n",
       "    else\n        wap.usage = 0\n        wap.usagePerMin = 0\n    end\n", 1)],
     "section 3: a refused cycle leaves the loaded tank's fill level, so native paints", "E1.3 / E2.3"),

    ("quantized-reported-as-binding", "ta",
     [("                flags.SHORT_QUANTIZED = true\n", "                flags.SHORT_BINDING = true\n", 1)],
     "section 6 / row 71 (a): a quantized-to-zero useful write is hidden as a binding shortfall", "E5.3"),

    ("sequence-float-compare", "core",
     [("    if #a ~= #b then return #a > #b end\n    return a > b\n",
       "    return tonumber(a) > tonumber(b)\n", 1)],
     "section 6: the decimal sequence is compared as a float, which rounds long sequences together", "core sequence rows"),

    ("presence-flag-invents-zero", "net",
     [("    local present = sf73Finite(v)\n    streamWriteBool(streamId, present)\n    if present then streamWriteFloat32(streamId, v) end\n",
       "    streamWriteBool(streamId, true)\n    streamWriteFloat32(streamId, sf73Finite(v) and v or 0)\n", 1)],
     "section 6: an absent optional number goes on the wire as an invented zero", "R5-R7"),

    ("mode-event-check-dropped", "net",
     [("    if g_server ~= nil and not SoilNetworkEvents_ConnectionMayToggleTarget(connection, vehicle) then return end\n", "", 1)],
     "section 6: the user / spectator / active-farm / deletion check on the mode request is gone", "M4, M5, M7"),

    ("marked-save-refreezes", "ta",
     [("            field._sf73BaselineUnavailable = true\n", "            TA.freezeBaseline(field)\n", 1)],
     "section 6: a marked save with no baseline re-freezes from the later report", "X7, X8, L5"),

    ("guard-ring-removed", "fp",
     [("F.GUARD_CELLS     = 1 ", "F.GUARD_CELLS     = 0 ", 1)],
     "section 3: no outer guard where native rounding is not exposed", "W5, W15"),

    ("legacy-n-dot-restored", "sys",
     [("            local dotN  = sf73 and 0 or (entry.N  or 0) * factor * tunFert\n",
       "            local dotN  = (entry.N  or 0) * factor * tunFert\n", 1)],
     "section 5: the legacy N dot writes again on a target cycle", "E1.25"),

    ("priming-skips-witness", "ta",
     [("    if not verdict.accepted then\n", "    if not verdict.accepted and not reprime then\n", 1)],
     "section 3: an ineligible priming line is observed instead of refused, so a helper never stops", "E6"),

    ("station-request-uncapped", "ta",
     [("            return level, \"STATION\"\n",
       "            return stationFor(fillTypeName):getFillLevel(fillTypeIndex, activeFarmOf(sprayer)), \"STATION\"\n", 1)],
     "section 4: the station request is capped to the whole station, not its first stocked source", "E10.2"),

    ("occupied-slot-not-refused", "ta",
     [("                 contractBroken = not self:usageSlotOwned(sprayer) }\n",
       "                 contractBroken = false }\n", 1)],
     "section 2: a later occupant of the usage slot spends before target mode suspends", "E7.9"),

    ("nozzle-partial-refusal-removed", "ta",
     [("    local suppressed = sprayer._sfOverlapSuppressedSections\n"
       "    if type(suppressed) == \"table\" and next(suppressed) ~= nil then\n"
       "        -- a partial Soil nozzle shut-off: physical deposition no longer matches one width\n"
       "        return refusedPlan(fillTypeIndex, C.STATE.INACTIVE, { C.REASON.NOZZLE_PARTIAL }, { clearAnchor = true })\n"
       "    end\n", "", 1)],
     "section 3: a boom Soil's overlap prevention part-suppressed is metered as one width", "E11.2, E11.5"),

    ("overlap-blocked-pass-ignored", "ta",
     [("    if not turnedOn or not anyWorkAreaActive(sprayer)\n"
       "       or (HookManager ~= nil and HookManager.isOverlapBlockedPass ~= nil and HookManager.isOverlapBlockedPass(sprayer)) then\n",
       "    if not turnedOn or not anyWorkAreaActive(sprayer) then\n", 1)],
     "section 3: a pass Soil's overlap prevention blocked is read as a boundary, not native inactivity", "E11.15, E11.20"),
]


def read_bytes(p):
    with open(p, "rb") as fh:
        return fh.read()


def run_suite():
    proc = subprocess.run([os.environ.get("NODE", "node"), "run-tests.mjs"], cwd=HERE,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.stdout + proc.stderr


def bar_results(out):
    res = {}
    lines = out.splitlines()
    for i, line in enumerate(lines):
        for bar in BARS:
            if bar in line and (line.startswith(TICK) or line.startswith(CROSS)):
                rows, crash = [], "Lua error" in line
                j = i + 1
                while j < len(lines) and lines[j].startswith("    "):
                    if lines[j].strip().startswith("FAIL "):
                        rows.append(lines[j].strip())
                    j += 1
                res[bar] = (line[0], rows, crash)
    return res


def pattern(old):
    return "\r?\n".join(re.escape(part) for part in old.split("\n"))


def main():
    originals = {k: read_bytes(p) for k, p in FILES.items()}
    digests = {k: hashlib.sha256(b).hexdigest() for k, b in originals.items()}
    texts = {k: b.decode("utf-8") for k, b in originals.items()}
    for k, p in FILES.items():
        print("target : %-44s sha256 %s" % (os.path.relpath(p, ROOT), digests[k]))
    base = bar_results(run_suite())
    for bar in BARS:
        sym = base.get(bar, (None,))[0]
        if sym != TICK:
            print("bar not green before mutating: %s (%s)" % (bar, sym))
            return 2
    print("BASELINE all %d SF-73 bars green\n" % len(BARS))

    results = []
    try:
        for mid, fkey, edits, clause, expect in MUTATIONS:
            mutated, landed = texts[fkey], True
            for old, new, want in edits:
                pat = pattern(old)
                found = len(re.findall(pat, mutated))
                if found != want:
                    print("%s: EDIT DID NOT LAND, anchor found %d, wanted %d" % (mid, found, want))
                    landed = False
                    break
                mutated = re.sub(pat, lambda _m, r=new: r, mutated, count=want)
            if not landed:
                results.append((mid, "NOT APPLIED"))
                continue
            if mutated == texts[fkey]:
                print("%s: the mutation is a no-op on the file" % mid)
                results.append((mid, "NOT APPLIED"))
                continue
            with open(FILES[fkey], "w", encoding="utf-8", newline="") as fh:
                fh.write(mutated)
            res = bar_results(run_suite())
            red = [(b, r) for b, r in res.items() if r[0] == CROSS]
            rows = [row for _, r in red for row in r[1]]
            crashed = any(r[2] for _, r in red)
            if rows:
                verdict = "KILLED"
            elif red and crashed:
                verdict = "CRASH"
            else:
                verdict = "SURVIVED"
            results.append((mid, verdict))
            print("%-8s %s\n    clause : %s\n    expect : %s" % (verdict, mid, clause, expect))
            for row in rows[:6]:
                print("    " + row)
            if len(rows) > 6:
                print("    ... and %d more" % (len(rows) - 6))
            print()
            with open(FILES[fkey], "wb") as fh:
                fh.write(originals[fkey])
    finally:
        bad = False
        for k, p in FILES.items():
            with open(p, "wb") as fh:
                fh.write(originals[k])
            ok = hashlib.sha256(read_bytes(p)).hexdigest() == digests[k]
            bad = bad or not ok
            print("restore: %-44s sha256 %s" % (os.path.relpath(p, ROOT), "MATCHES" if ok else "DOES NOT MATCH"))
        if bad:
            return 3
    after = bar_results(run_suite())
    green = all(after.get(b, (None,))[0] == TICK for b in BARS)
    print("after restore: %s\n" % ("all SF-73 bars green" if green else "NOT GREEN"))
    for m, v in results:
        print("  %-8s %s" % (v, m))
    killed = sum(1 for _, v in results if v == "KILLED")
    print("\n%d of %d mutations killed with named rows" % (killed, len(results)))
    return 0 if killed == len(results) and green else 1


if __name__ == "__main__":
    sys.exit(main())
