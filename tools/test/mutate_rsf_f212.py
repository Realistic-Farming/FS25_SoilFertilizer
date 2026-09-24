# RSF-F212 mutation battery: fresh material's starting condition (GROUND-CONDITION-CONTRACT
# v1.5 section 4). Does RSF-F212-fresh_birth_spec_test.lua catch the versions that would
# birth material wrong?
#
# Each mutation removes one clause of the carrier's fresh birth, the projector's
# contribution or a hook, and must be KILLED by a named row of that bar (the S3 bars run in
# the same suite and may add kills). For each: assert the edit LANDED (exact occurrence
# count), run the suite, record KILLED/SURVIVED with the named rows, restore byte-for-byte
# and PROVE the restore with a hash. "DID NOT APPLY" never counts as a kill. KILLED* means
# killed only by a Lua error: a weak kill, treated as a failure.
#
# Not run, and why:
# - The swath hook's own client and settings checks (strawCarrierOn's isServer and
#   settings.enabled): each is masked by the stricter gate behind it, the carrier's begin
#   refusing a client (row S15 reaches it through begin) and the mower's M15 sibling
#   pinning the settings clause on the mower's helper of the same shape.
# - The stamp's key string (C.HANDLED_KEY): any string is a working key.
# - The profile table's iteration order: a (kind, fill type) pair matches at most one row.
# - The per-vehicle stamp on a vehicle that is not a table: begin refuses it first.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, THROUGH THE TEST LOCK. A battery edits production files in place.
#
# Usage (from the repo root): py tools/test/mutate_rsf_f212.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

CAR = "src/ground/GroundMovementCarrier.lua"
PRJ = "src/ground/GroundMovementProjector.lua"
HM = "src/hooks/HookManager.lua"

MUTATIONS = [
 # ── the profiles ────────────────────────────────────────────────────────────
 ("P1-grass-profile-percentage", CAR,
  [("pct = 80, kind = C.KIND_MOWER", "pct = 60, kind = C.KIND_MOWER", 1)],
  "fresh grass is born at 60% instead of the ratified 80%"),
 ("P2-straw-profile-percentage", CAR,
  [("pct = 25, kind = C.KIND_STRAW", "pct = 80, kind = C.KIND_STRAW", 1)],
  "fresh straw is born at 80% instead of the ratified 25%"),
 ("P3-grass-profile-revision", CAR,
  [("id = \"FRESH_GRASS_V1\", revision = 1,", "id = \"FRESH_GRASS_V1\", revision = 2,", 1)],
  "the birth contribution names a revision the profile does not have"),
 ("P4-profile-ignores-kind", CAR,
  [("        if profile.kind == kind and profile.fillType == name then return profile end",
    "        if profile.fillType == name then return profile end", 1)],
  "a mower converter that outputs STRAW earns the combine swath's straw profile"),
 ("P5-profile-ignores-type", CAR,
  [("        if profile.kind == kind and profile.fillType == name then return profile end",
    "        if profile.kind == kind then return profile end", 1)],
  "a fill-type name alone earns the profile: a mower that makes hay is born at 80%"),
 ("P6-encoder-bypassed", CAR,
  [("    local ok, raw = pcall(MaterialWetness.pctToRaw, profile.pct)",
    "    local ok, raw = true, profile.pct", 1)],
  "the percentage is written as the raw value instead of going through MaterialWetness's encoder"),
 ("P7-profile-claimed-without-encoding", CAR,
  [("    if profile ~= nil and wetnessRaw ~= nil then\n        birth.profile, birth.revision, birth.provenance",
    "    if profile ~= nil then\n        birth.profile, birth.revision, birth.provenance", 1)],
  "with no encoder the contribution still claims the profile and its provenance"),
 # ── the birth ───────────────────────────────────────────────────────────────
 ("B1-refused-barrier-gets-profile", CAR,
  [("    if not frame.barrierOk then\n        C.accountAdd(frame.account, litres, nil, nil, frame.today)\n        return\n    end\n    local profile = C.profileFor(frame.kind, fillTypeIndex)",
    "    local profile = C.profileFor(frame.kind, fillTypeIndex)", 1)],
  "output cut under a refused barrier is born with the profile instead of explicit unknown"),
 ("B2-born-at-buffer-entry", CAR,
  [("        if comp.born then\n            ageRaw = AGE_BORN\n        else",
    "        if false then\n            ageRaw = AGE_BORN\n        else", 1)],
  "a fresh birth ages from the day it entered the machine's buffer instead of being born at the deposit"),
 ("B3-provenance-dropped-from-component", CAR,
  [("        born = born, profile = profile, revision = born and birth.revision or nil, provenance = provenance,",
    "        born = born, profile = profile, revision = born and birth.revision or nil, provenance = nil,", 1)],
  "the account component forgets the birth's provenance"),
 ("B4-profile-dropped-from-mixture", CAR,
  [("            profile = comp.profile, revision = comp.revision, provenance = comp.provenance }",
    "            profile = nil, revision = nil, provenance = nil }", 1)],
  "resolving the account drops the profile and provenance before the projector sees them"),
 ("B5-estimate-merges-with-captured", CAR,
  [("           and (comp.born == true) == born and comp.profile == profile and comp.provenance == provenance then",
    "           then", 1)],
  "an estimate made at birth merges with a captured condition of the same bytes"),
 ("B6-births-not-counted", CAR,
  [("    C.stats.births = C.stats.births + 1\n", "", 1)],
  "the birth counter never moves"),
 ("B7-first-birth-line-every-birth", CAR,
  [("    if birth.profile ~= nil and not C.firstBirthLogged[profile.id] then",
    "    if birth.profile ~= nil then", 1)],
  "the first-birth line repeats on every birth"),
 ("B8-first-birth-line-never", CAR,
  [("    if birth.profile ~= nil and not C.firstBirthLogged[profile.id] then",
    "    if false then", 1)],
  "the first fresh birth is never said in the log"),
 # ── the straw frame ─────────────────────────────────────────────────────────
 ("S1-straw-add-missing", CAR,
  [("    if frame.kind == C.KIND_STRAW and not prim.pickup then\n        C.freshBirth(frame, prim.delta, prim.fillTypeIndex)\n    end\n", "", 1)],
  "the swath's tip request never enters the account: the straw lands of unknown condition"),
 ("S2-straw-add-for-every-kind", CAR,
  [("    if frame.kind == C.KIND_STRAW and not prim.pickup then", "    if not prim.pickup then", 1)],
  "every carrier's drop request is treated as a fresh production observation"),
 # ── the stamp ───────────────────────────────────────────────────────────────
 ("T1-never-stamped", CAR,
  [("    C.stampHandled(vehicle)\n", "", 1)],
  "begin never records that the carrier owns the deposit: the generic birth runs beside the projection"),
 ("T2-stamp-after-lease-check", CAR,
  [("    C.stampHandled(vehicle)\n    if admission ~= nil and admission:hasLiveLeaseFor(vehicle, workArea) then\n        C.stats.skippedLease = C.stats.skippedLease + 1\n        return nil\n    end\n",
    "    if admission ~= nil and admission:hasLiveLeaseFor(vehicle, workArea) then\n        C.stats.skippedLease = C.stats.skippedLease + 1\n        return nil\n    end\n    C.stampHandled(vehicle)\n", 1)],
  "a deposit a StockGuard lease owns is not an admitted context: the generic birth runs under the lease"),
 ("T3-handled-always", CAR,
  [("    return rawget(vehicle, C.HANDLED_KEY) == n", "    return true", 1)],
  "the generic birth never runs, even with the ground family unarmed"),
 ("T4-handled-by-any-old-stamp", CAR,
  [("    return rawget(vehicle, C.HANDLED_KEY) == n", "    return rawget(vehicle, C.HANDLED_KEY) ~= nil", 1)],
  "a stamp from an earlier frame stands the generic birth down for the rest of the session"),
 # ── the projector ───────────────────────────────────────────────────────────
 ("J1-contribution-drops-provenance", PRJ,
  [("                profile = m.profile, revision = m.revision, provenance = m.provenance }",
    "                profile = nil, revision = nil, provenance = nil }", 1)],
  "the contribution the coordinator combines carries no profile or provenance"),
 # ── the hooks ───────────────────────────────────────────────────────────────
 ("H1-mower-birth-ignores-carrier", HM,
  [("                if md and md:isArmed() and not carried then", "                if md and md:isArmed() then", 1)],
  "the mower's generic birth runs on a carrier-handled frame"),
 ("H2-mower-cut-passes-no-type", HM,
  [("pcall(GroundMovementCarrier.mowerCut, frame, fresh, dropArea.fillType)", "pcall(GroundMovementCarrier.mowerCut, frame, fresh)", 1)],
  "the cut never says what it made: no output earns the grass profile"),
 ("H3-swath-frame-never-opens", HM,
  [("            if strawCarrierOn(combineSelf) then frame = beginStraw(combineSelf, workArea) end\n", "", 1)],
  "the swath runs with no carrier frame: no straw birth, the generic birth back"),
 ("H4-swath-frame-not-closed", HM,
  [("            if frame ~= nil then finishStraw(frame) end\n", "", 1)],
  "the straw frame is left open after the native call"),
 ("H5-swath-birth-ignores-carrier", HM,
  [("            if GroundMovementCarrier ~= nil and type(GroundMovementCarrier.handledThisFrame) == \"function\"\n               and GroundMovementCarrier.handledThisFrame(combineSelf) then\n                return unpack(results)\n            end\n", "", 1)],
  "the generic straw birth runs beside the carrier's projection"),
 ("H6-swath-frame-with-nothing-to-drop", HM,
  [("        if params == nil or not spec.isSwathActive or (tonumber(params.litersToDrop) or 0) <= 0 then return nil end",
    "        if params == nil then return nil end", 1)],
  "a chopping combine, or one with an empty buffer, opens a frame every tick"),
 ("H7-swath-begins-as-mower", HM,
  [("            GroundMovementCarrier.KIND_STRAW, nil)", "            GroundMovementCarrier.KIND_MOWER, nil)", 1)],
  "the swath frame is not the STRAW kind: the tip request is never a production observation"),
 ("H8-swath-wrapper-swallows-native-error", HM,
  [("            if frame ~= nil then finishStraw(frame) end\n            if not packed[1] then error(packed[2], 0) end\n",
    "            if frame ~= nil then finishStraw(frame) end\n            if not packed[1] then return 0, 0 end\n", 1)],
  "a native error inside the swath is swallowed"),
 ("H9-swath-observer-never-installed", HM,
  [("        local okObs, whyObs = GroundNativeObserver.install()\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[SwathHook] ground-condition observer",
    "        local okObs, whyObs = false, \"CLIENT\"\n        if not okObs and whyObs ~= \"CLIENT\" then\n            SoilLogger.warning(\"[SwathHook] ground-condition observer", 1)],
  "the swath hook relies on another hook to install the observer"),
 ("H10-swath-observer-cleanup-not-registered", HM,
  [("            SoilLogger.warning(\"[SwathHook] ground-condition observer not installed (%s)\", tostring(whyObs))\n        elseif okObs and whyObs == nil then",
    "            SoilLogger.warning(\"[SwathHook] ground-condition observer not installed (%s)\", tostring(whyObs))\n        elseif false then", 1)],
  "the swath hook installs the observer and registers no cleanup for it"),
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
