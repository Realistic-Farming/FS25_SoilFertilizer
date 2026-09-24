# RSF-F208 section 3 mutation battery: the Tedder carrier (S2a), and the Windrower and
# Mower carriers (S2b). Does the bar catch the versions that would move ground condition
# wrong?
#
# Each mutation removes one clause of the carrier, the observer or a hook and must be
# KILLED by a named row of RSF-F208-s3-tedder_carrier_spec_test.lua,
# RSF-F208-s3b-windrower_carrier_spec_test.lua or RSF-F208-s3b-mower_carrier_spec_test.lua. For
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
# - The mower hook's own client and spec checks (carrierOn's isServer, wrapDrop's
#   spec_mower): each is masked by a stricter gate behind it, the carrier's begin
#   refusing a client (pinned by B3/B7b) and wrapDrop's identity test against
#   Mower.processDropArea (M10, D1-D2). Equivalent here by construction.
# - The rise in pickedUpLiters rather than its value: the engine resets it at the start
#   of every frame (Mower.lua:555) and each work area is cut once per frame, so the two
#   are equal in every native order. Kept as a rise so a second cut in one frame could
#   never be counted twice.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f208_s3.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OBS = "src/ground/GroundNativeObserver.lua"
CAR = "src/ground/GroundMovementCarrier.lua"
# SG2-4 S3 moved the per-cell projection out of the carrier into the one projector both
# observers share; B4, B5, B11 and B12 are the same mutations on their new home.
PRJ = "src/ground/GroundMovementProjector.lua"
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

 ("A8-observer-reads-over-the-cap", OBS,
  [("    if #cells > O.MAX_CELLS then", "    if false then", 1)],
  "an envelope over the read cap is read every frame instead of marked"),

 # --- the carrier ---
 ("B0-refused-envelope-marks-nothing", CAR,
  [("        for _, cell in ipairs(prim.cells) do\n            markUnavailable(frame, cell, \"ENVELOPE:\" .. tostring(prim.refused))\n        end\n",
    "", 1)],
  "Bob's MAJOR on #994: a drop through an unreadable envelope leaves old records standing"),
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
 ("B4-partial-removal-clears", PRJ,
  [("    if (cell.afterWhole or 0) <= P.EPSILON then",
    "    if true then", 1)],
  "a source cell still holding material is cleared"),
 ("B5-destination-ignores-survivors", PRJ,
  [("    end\n    local destination = { occupied = surviving > P.EPSILON, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }",
    "    end\n    local destination = { occupied = false, ageRaw = cell.ageRaw, wetnessRaw = cell.wetnessRaw }", 1)],
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
  [("            ageRaw = C.agedRaw(comp.ageRaw, comp.captureAgeDay, today)\n",
    "            comp.ageRaw = C.agedRaw(comp.ageRaw, comp.captureAgeDay, today)\n            ageRaw = comp.ageRaw\n", 1)],
  "resolving writes the aged value back without re-stamping, so the span is added again"),
 ("B9-no-reconcile-at-begin", CAR,
  [("        C.accountReconcile(acc, nativeRemainder(home), today)\n",
    "", 1)],
  "a remainder another mod cleared still carries its old condition into the next drop"),
 ("B10-drop-keeps-the-account", CAR,
  [("    C.accountRemove(acc, dropped)\n", "", 1)],
  "dropped material never leaves the account"),
 ("B11-pickup-forgets-source-condition", PRJ,
  [("                if type(sink) == \"function\" then sink(removed, cell.ageRaw, cell.wetnessRaw) end",
    "                if type(sink) == \"function\" then sink(removed, nil, nil) end", 1)],
  "picked-up material loses the condition its ground recorded"),
 ("B12-one-write-per-contributor", PRJ,
  [("    local combined = GroundConditionCoordinator.combine(destination, contributions)\n"
    "    if combined.empty then return \"EMPTY\" end\n"
    "    local ok = ctx.coordinator:applyProjection(ctx.geometry, cell.gx, cell.gz, combined)\n"
    "    if ok then bump(ctx, \"projected\") return \"PROJECTED\" end\n"
    "    return \"REFUSED\"",
    "    local last = \"EMPTY\"\n"
    "    for _, one in ipairs(contributions) do\n"
    "        local combined = GroundConditionCoordinator.combine(destination, { one })\n"
    "        if not combined.empty then\n"
    "            local ok = ctx.coordinator:applyProjection(ctx.geometry, cell.gx, cell.gz, combined)\n"
    "            last = ok and \"PROJECTED\" or \"REFUSED\"\n"
    "        end\n"
    "    end\n"
    "    return last", 1)],
  "each contributor writes the cell separately instead of one combined update"),

 ("B13-first-pass-logged-every-pass", CAR,
  [("    if not C.firstPassLogged[frame.kind] and (frame.primitives or 0) > 0 then",
    "    if (frame.primitives or 0) > 0 then", 1)],
  "the in-game proof line repeats on every tedder pass"),
 ("B14-first-pass-never-logged", CAR,
  [("    if not C.firstPassLogged[frame.kind] and (frame.primitives or 0) > 0 then",
    "    if false then", 1)],
  "nothing in log.txt shows the carrier ever ran"),

 # --- the tedder wrapper ---
 ("H0-observer-cleanup-not-registered", HM,
  [("            -- uninstall restores the native function only while ours is current.\n"
    "            self:registerCleanup(\"DensityMapHeightUtil.tipToGroundAroundLine (ground-condition observer)\", function()\n"
    "                GroundNativeObserver.uninstall()\n"
    "            end)\n",
    "            -- uninstall restores the native function only while ours is current.\n", 1)],
  "the observer's wrap outlives the hook manager's teardown"),
 ("H1-observer-never-installed", HM,
  [("        local okObs, whyObs = GroundNativeObserver.install()\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[TedderHook]",
    "        local okObs, whyObs = false, \"MUTANT\"\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[TedderHook]", 1)],
  "the hook installs the carrier but not the observer it records through"),
 ("H2-carrier-never-begins", HM,
  [("            if tedderSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n",
    "            if false and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n", 1)],
  "the tedder wrapper never opens a carrier frame"),
 ("H3-carrier-ignores-settings", HM,
  [("            if tedderSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n"
    "               and g_SoilFertilityManager.settings ~= nil and g_SoilFertilityManager.settings.enabled then",
    "            if tedderSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n"
    "               and g_SoilFertilityManager.settings ~= nil then", 1)],
  "the carrier runs with the mod switched off"),
 ("H4-frame-not-closed", HM,
  [("                local okFinish, errFinish = pcall(GroundMovementCarrier.finish, carrierFrame)\n"
    "                if not okFinish then\n"
    "                    SoilLogger.warning(\"[TedderHook] ground-condition carrier failed to finish",
    "                local okFinish, errFinish = true, nil\n"
    "                if not okFinish then\n"
    "                    SoilLogger.warning(\"[TedderHook] ground-condition carrier failed to finish", 1)],
  "the carrier frame is left on the stack"),
 ("H5-wrapper-swallows-native-error", HM,
  [("            if not packed[1] then error(packed[2], 0) end\n            local results = { unpack(packed, 2, packed.n) }",
    "            local results = { unpack(packed, 2, packed.n) }", 1)],
  "a native error inside processTedderArea disappears"),

 # --- the windrower (S2b) ---
 ("W1-windrower-keeps-an-account", CAR,
  [("    else\n        acc = { components = {} }\n    end",
    "    else\n        acc = C.accountOf(workArea)\n    end", 1)],
  "the windrower's undropped loss rides into a later drop"),
 ("W2-windrower-carrier-never-begins", HM,
  [("            if windrowerSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n",
    "            if false and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n", 1)],
  "the windrower wrapper never opens a carrier frame"),
 ("W3-windrower-ignores-settings", HM,
  [("            if windrowerSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n"
    "               and g_SoilFertilityManager.settings ~= nil and g_SoilFertilityManager.settings.enabled then",
    "            if windrowerSelf.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n"
    "               and g_SoilFertilityManager.settings ~= nil then", 1)],
  "the windrower carrier runs with the mod switched off"),
 ("W4-windrower-swallows-native-error", HM,
  [("[WindrowerHook] ground-condition carrier failed to finish (%s)\", tostring(errFinish))\n                end\n            end\n"
    "            if not packed[1] then error(packed[2], 0) end\n            return unpack(packed, 2, packed.n)",
    "[WindrowerHook] ground-condition carrier failed to finish (%s)\", tostring(errFinish))\n                end\n            end\n"
    "            return unpack(packed, 2, packed.n)", 1)],
  "a native error inside processWindrowerArea disappears"),
 ("W5-first-pass-flag-shared-across-kinds", CAR,
  [("    if not C.firstPassLogged[frame.kind] and (frame.primitives or 0) > 0 then\n        C.firstPassLogged[frame.kind] = true",
    "    if not C.firstPassLogged.any and (frame.primitives or 0) > 0 then\n        C.firstPassLogged.any = true", 1)],
  "the windrower's first pass is silent because the tedder logged first"),
 ("W6-windrower-observer-never-installed", HM,
  [("        local okObs, whyObs = GroundNativeObserver.install()\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[WindrowerHook]",
    "        local okObs, whyObs = false, \"MUTANT\"\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[WindrowerHook]", 1)],
  "the windrower hook installs the carrier but not the observer"),
 ("W7-windrower-observer-cleanup-not-registered", HM,
  [("            SoilLogger.warning(\"[WindrowerHook] ground-condition observer not installed (%s)\", tostring(whyObs))\n        elseif okObs and whyObs == nil then",
    "            SoilLogger.warning(\"[WindrowerHook] ground-condition observer not installed (%s)\", tostring(whyObs))\n        elseif false then", 1)],
  "the observer the windrower hook wrapped outlives the hook manager's teardown"),

 # --- the mower (S2b) ---
 # RSF-F212 (S4) moved the fresh add into GroundMovementCarrier.freshBirth; M1 to M3 are the
 # same mutations on their new home (M2 is now a wetness invented for an output no profile
 # covers, pinned by the F212 bar's hay row).
 ("M1-fresh-output-not-recorded", CAR,
  [("    C.accountAdd(frame.account, litres, AGE_BORN, wetnessRaw, frame.today, birth)", "    local _ = AGE_BORN", 1)],
  "the fresh cut lands as unknown instead of born today"),
 ("M2-fresh-output-given-a-wetness", CAR,
  [("    C.accountAdd(frame.account, litres, AGE_BORN, wetnessRaw, frame.today, birth)",
    "    C.accountAdd(frame.account, litres, AGE_BORN, wetnessRaw or 100, frame.today, birth)", 1)],
  "an output no profile covers is given a wetness anyway"),
 ("M3-fresh-output-a-day-old", CAR,
  [("            ageRaw = AGE_BORN\n", "            ageRaw = AGE_BORN + 1\n", 1)],
  "the fresh cut is counted as a day old"),
 ("M4-account-on-the-calling-area", CAR,
  [("        local home = type(accountArea) == \"table\" and accountArea or workArea",
    "        local home = workArea", 1)],
  "the cut's account lives on the mower work area, not the drop area it feeds"),
 ("M5-drop-area-of-any-type", CAR,
  [(" or dropArea.type ~= WorkAreaType.AUXILIARY then return nil end",
    " then return nil end", 1)],
  "a work area the native gives no drop area is carried as if it had one"),
 ("M6-cut-frame-never-opens", HM,
  [("                    frame = begin(mowerSelf, workArea, dropArea)", "                    frame = nil", 1)],
  "the cut is never observed: the old windrow's condition and the fresh birth are lost"),
 ("M7-lease-checked-on-the-drop-area", HM,
  [("                    frame = begin(mowerSelf, workArea, dropArea)", "                    frame = begin(mowerSelf, dropArea, dropArea)", 1)],
  "a lease on the cutting work area is not seen"),
 ("M8-drop-frame-never-opens", HM,
  [("                frame = begin(mowerSelf, dropArea, dropArea)\n            end", "                frame = nil\n            end", 1)],
  "the drop is never observed, so nothing is projected"),
 ("M9-drop-frame-when-nothing-pending", HM,
  [(" and (tonumber(dropArea.litersToDrop) or 0) > 0 then", " then", 1)],
  "an idle drop area runs the barrier every frame"),
 ("M10-drop-wrap-ignores-identity", HM,
  [("        if real ~= nativeDrop then return 0 end\n", "", 1)],
  "another mod's processDropArea is replaced"),
 ("M11-drop-copy-never-wrapped", HM,
  [("            dropCount = dropCount + wrapDrop(vehicle)\n", "", 1)],
  "an existing mower's drop is not carried"),
 ("M12-late-mower-drop-not-wrapped", HM,
  [("            wrapDrop(vehicle)\n            return origAdd(self, vehicle, ...)", "            return origAdd(self, vehicle, ...)", 1)],
  "a mower added later drops uncarried"),
 ("M13-cut-wrapper-swallows-native-error", HM,
  [("                finish(frame)\n            end\n            if not packed[1] then error(packed[2], 0) end",
    "                finish(frame)\n            end", 1)],
  "a native error inside the cut disappears"),
 ("M14-drop-wrapper-swallows-native-error", HM,
  [("            if frame ~= nil then finish(frame) end\n            if not packed[1] then error(packed[2], 0) end",
    "            if frame ~= nil then finish(frame) end", 1)],
  "a native error inside the drop disappears"),
 ("M15-mower-ignores-settings", HM,
  [("        return vehicle.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n"
    "            and g_SoilFertilityManager.settings ~= nil and g_SoilFertilityManager.settings.enabled",
    "        return vehicle.isServer and GroundMovementCarrier ~= nil and g_SoilFertilityManager ~= nil\n"
    "            and g_SoilFertilityManager.settings ~= nil", 1)],
  "the mower carrier runs with the mod switched off"),
 ("M16-fresh-never-passed", HM,
  [("                    local fresh = (tonumber(workArea.pickedUpLiters) or 0) - before", "                    local fresh = 0", 1)],
  "the hook never hands the cut's output to the carrier"),
 ("M17-mower-observer-never-installed", HM,
  [("        local okObs, whyObs = GroundNativeObserver.install()\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[MowerCarrier]",
    "        local okObs, whyObs = false, \"MUTANT\"\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[MowerCarrier]", 1)],
  "the mower hook installs its wrappers but not the observer they record through"),
 ("M18-mower-observer-cleanup-not-registered", HM,
  [("            SoilLogger.warning(\"[MowerCarrier] ground-condition observer not installed (%s)\", tostring(whyObs))\n        elseif okObs and whyObs == nil then",
    "            SoilLogger.warning(\"[MowerCarrier] ground-condition observer not installed (%s)\", tostring(whyObs))\n        elseif false then", 1)],
  "the observer the mower hook wrapped outlives the hook manager's teardown"),

 # --- production's installAll ---
 ("A1-installAll-omits-the-mower", HM,
  [("    local mowerCarrierOk = self:installMowerCarrierHook()\n", "    local mowerCarrierOk = true\n", 1)],
  "production never installs the mower carrier"),
 ("A2-installAll-omits-the-windrower", HM,
  [("    local windrowerOk = self:installWindrowerHook()\n", "    local windrowerOk = true\n", 1)],
  "production never installs the windrower carrier"),
 ("A3-installAll-omits-the-tedder", HM,
  [("    local tedderOk = self:installTedderHook()\n", "    local tedderOk = true\n", 1)],
  "production never installs the tedder carrier"),
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
