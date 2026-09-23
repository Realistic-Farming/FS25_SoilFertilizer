# RSF-F208 section 3, slice S2a (the Tedder carrier) mutation battery: does the bar
# catch the versions that would move ground condition wrong?
#
# Each mutation removes one clause of the carrier, the observer or the tedder wrapper
# and must be KILLED by a named row of RSF-F208-s3-tedder_carrier_spec_test.lua. For
# each: assert the edit LANDED (exact occurrence count), run the suite, record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with
# a hash. "DID NOT APPLY" never counts as a kill.
#
# Not run, and why:
# - The envelope's outer radius (the observer's reach = inner + outer radius). At the
#   bench's 4 m grain a cell is admitted when its centre is within reach plus half its
#   diagonal (2.83 m); a pickup's material lies within inner + outer radius (2 m here)
#   of the line, so any cell holding pickable material has its centre within 4.83 m and
#   dropping the 1 m outer radius (3.83 m) still admits it. Equivalent at this grain.
# - main.lua's two source lines: the bench loads modules directly, and SoilFertilizer has
#   no load-path gate (it runs only on StockGuard). Checked by the in-game row instead.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f208_s3.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OBS = "src/ground/GroundNativeObserver.lua"
CAR = "src/ground/GroundMovementCarrier.lua"
HM = "src/hooks/HookManager.lua"

MUTATIONS = [
 # --- the observer ---
 ("A1-observer-records-any-vehicle", OBS,
  [("if frame == nil or frame.closed or frame.owner ~= vehicle or type(frame.handler) ~= \"table\" then",
    "if frame == nil or frame.closed or type(frame.handler) ~= \"table\" then", 1)],
  "another vehicle's tip inside the tedder's frame is recorded as the tedder's"),
 ("A2-observer-no-after-read", OBS,
  [("            cell.after, cell.afterWhole = readCell(cell, rec.typeIndices, rec.windrowSet)\n",
    "", 1)],
  "the occupancy after the native call is never read"),
 ("A3-observer-no-before-read", OBS,
  [("        cell.before, cell.beforeWhole = readCell(cell, typeIndices, windrowSet)\n",
    "", 1)],
  "the occupancy before the native call is never read"),
 ("A4-observer-failure-not-reported", OBS,
  [("                pcall(frame.handler.onPrimitiveFailed, frame, prim)\n",
    "", 1)],
  "a native throw leaves the touched cells looking vouched for"),
 ("A5-observer-swallows-native-error", OBS,
  [("        if not r[1] then error(r[2], 0) end\n        return unpack(r, 2, n)",
    "        return unpack(r, 2, n)", 1)],
  "a native error inside a tip disappears"),
 ("A6-observer-refuses-every-envelope", OBS,
  [("O.MAX_CELLS          = 256", "O.MAX_CELLS          = 0", 1)],
  "no primitive can be placed on cells"),
 ("A7-occupancy-ignores-straw", OBS,
  [("O.OCCUPANCY_TYPES    = { \"GRASS_WINDROW\", \"DRYGRASS_WINDROW\", \"STRAW\" }",
    "O.OCCUPANCY_TYPES    = { \"GRASS_WINDROW\", \"DRYGRASS_WINDROW\" }", 1)],
  "whole-cell occupancy misses straw: a straw cell clears, a straw destination reads empty"),

 # --- the carrier ---
 ("B1-carrier-ignores-lease", CAR,
  [("    if admission ~= nil and admission:hasLiveLeaseFor(vehicle, workArea) then",
    "    if false then", 1)],
  "the standalone carrier runs while StockGuard holds the primitive"),
 ("B2-carrier-ignores-barrier", CAR,
  [("        barrierOk = ok, barrierReason = reason, account = acc,",
    "        barrierOk = true, barrierReason = reason, account = acc,", 1)],
  "a refused settlement barrier still projects"),
 ("B3-carrier-runs-on-client", CAR,
  [("    if not vehicle.isServer then return nil end\n", "", 1)],
  "a client's tedder projects condition"),
 ("B4-partial-removal-clears", CAR,
  [("                    if (cell.afterWhole or 0) <= C.EPSILON then",
    "                    if true then", 1)],
  "a source cell still holding material is cleared"),
 ("B5-destination-ignores-survivors", CAR,
  [("                    local destination = { occupied = surviving > C.EPSILON, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }",
    "                    local destination = { occupied = false, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }", 1)],
  "material already lying in the drop cell is washed out by the incoming condition"),
 ("B6-no-transit-ageing", CAR,
  [("    return math.min(AGE_CEILING, ageRaw + (today - captureAgeDay))",
    "    return ageRaw", 1)],
  "P-GROUND-1: the carried remainder never ages"),
 ("B7-reversed-clock-allowed", CAR,
  [("or type(captureAgeDay) ~= \"number\" or today < captureAgeDay then return nil end",
    "or type(captureAgeDay) ~= \"number\" then return nil end", 1)],
  "a clock running backwards subtracts age instead of making it unknown"),
 ("B8-ageing-persisted-twice", CAR,
  [("        out[#out + 1] = { litres = comp.litres, ageRaw = C.agedRaw(comp.ageRaw, comp.captureAgeDay, today), wetnessRaw = comp.wetnessRaw }",
    "        comp.ageRaw = C.agedRaw(comp.ageRaw, comp.captureAgeDay, today)\n        out[#out + 1] = { litres = comp.litres, ageRaw = comp.ageRaw, wetnessRaw = comp.wetnessRaw }", 1)],
  "resolving writes the aged value back without re-stamping, so the span is added again"),
 ("B9-no-reconcile-at-begin", CAR,
  [("    if nativeRemainder ~= nil then C.accountReconcile(acc, nativeRemainder(workArea), today) end\n",
    "", 1)],
  "a remainder another mod cleared still carries its old condition into the next drop"),
 ("B10-drop-keeps-the-account", CAR,
  [("    C.accountRemove(acc, dropped)\n", "", 1)],
  "dropped material never leaves the account"),
 ("B11-pickup-forgets-source-condition", CAR,
  [("                    C.accountAdd(acc, removed, cell.ageRaw, cell.wetnessRaw, frame.today)",
    "                    C.accountAdd(acc, removed, nil, nil, frame.today)", 1)],
  "picked-up material loses the condition its ground recorded"),
 ("B12-one-write-per-contributor", CAR,
  [("                    local combined = GroundConditionCoordinator.combine(destination, contributions)\n"
    "                    if not combined.empty then\n"
    "                        local ok = frame.coordinator:applyProjection(frame.geometry, cell.gx, cell.gz, combined)\n"
    "                        if ok then C.stats.projected = C.stats.projected + 1 end\n"
    "                    end",
    "                    for _, one in ipairs(contributions) do\n"
    "                        local combined = GroundConditionCoordinator.combine(destination, { one })\n"
    "                        if not combined.empty then\n"
    "                            frame.coordinator:applyProjection(frame.geometry, cell.gx, cell.gz, combined)\n"
    "                        end\n"
    "                    end", 1)],
  "each contributor writes the cell separately instead of one combined update"),

 # --- the tedder wrapper ---
 ("H1-observer-never-installed", HM,
  [("        local okObs, whyObs = GroundNativeObserver.install()",
    "        local okObs, whyObs = false, \"MUTANT\"", 1)],
  "the hook installs the carrier but not the observer it records through"),
 ("H2-carrier-never-begins", HM,
  [("            if tedderSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n",
    "            if false and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n", 1)],
  "the tedder wrapper never opens a carrier frame"),
 ("H3-carrier-ignores-settings", HM,
  [("               and g_SoilFertilityManager.settings ~= nil and g_SoilFertilityManager.settings.enabled then",
    "               and g_SoilFertilityManager.settings ~= nil then", 1)],
  "the carrier runs with the mod switched off"),
 ("H4-frame-not-closed", HM,
  [("                local okFinish, errFinish = pcall(GroundMovementCarrier.finish, carrierFrame)",
    "                local okFinish, errFinish = true, nil", 1)],
  "the carrier frame is left on the stack"),
 ("H5-wrapper-swallows-native-error", HM,
  [("            if not packed[1] then error(packed[2], 0) end\n", "", 1)],
  "a native error inside processTedderArea disappears"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
