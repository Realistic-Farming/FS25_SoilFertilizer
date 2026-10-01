# SoilFertilizer GC-6 mutation battery: Soil's standalone native save boundary
# (src/ground/SoilNativeSave.lua), the ground-condition participant
# (src/ground/GroundConditionSave.lua) and the two seams that reach it (the stamp in
# SoilFertilityManager.saveSoilData, the verdict in GroundConditionCoordinator:_onStoreDecided).
# Rows live in GC-6-native_save_boundary_spec_test.lua and GC-6-ground_condition_save_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-30): each mutant runs through `node run-tests.mjs --loads <file>`:
#   - a mutant in SoilNativeSave.lua selects both GC-6 benches, the only ones that load it;
#   - every other mutant selects GroundConditionSave.lua's one bench. The seams in
#     SoilFertilityManager.lua and GroundConditionCoordinator.lua run only when
#     GroundConditionSave is loaded (GroundConditionSave ~= nil, and .current set by its
#     install), so no other bench can see them.
# Run ONE mutant per call, in the foreground, memory-checked.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - main.lua's three lines (installNativeSave delegating to GroundConditionSave.installForMission,
#     the reconsider at mission start, the closes at unload): no bench loads main.lua's mission
#     callbacks; the bench drives the function installNativeSave calls, and J7 the reconsider.
#   - logging and logOnce text.
#   - M.resolveEngineTable's ROOT branch (no metatable on _G): FS25's mod environment always has
#     one (the boundary bench's G1 reads the engine table).
#
# EQUIVALENT, run and kept in the list so they stay visible:
#   - N27 (finish for any controller): there is one SavegameController in a game and in the bench.
#   - P04 (the attempt stamped on every soilData.xml of an attempt): saveSoilData runs once per
#     attempt, so the first file is the only one.
#   - P23 (markUnavailable adding membership): every cell applyVerdict marks is already a member.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_gc6_native_save.py <id>       one mutant (a unique prefix)
#        py tools/test/mutate_gc6_native_save.py --check    every anchor matches its count; runs nothing
#        py tools/test/mutate_gc6_native_save.py --baseline both selections, unmutated
#        py tools/test/mutate_gc6_native_save.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NS = "src/ground/SoilNativeSave.lua"
GS = "src/ground/GroundConditionSave.lua"
SFM = "src/SoilFertilityManager.lua"
GC = "src/ground/GroundConditionCoordinator.lua"
SELECT = {NS: ["--loads", NS]}
DEFAULT_SELECT = ["--loads", GS]

MUTATIONS = [
 # ── the boundary ────────────────────────────────────────────────────────────
 ("N01-register-conflict-accepted", NS,
  [("        if live == spec then return true end\n        return false, \"CONFLICT\"\n", "        return true\n", 1)],
  "a second spec under a live id is accepted"),
 ("N02-seed-ignored", NS,
  [("    if type(n) == \"number\" and n == math.floor(n) and n > self.nextAttemptId then self.nextAttemptId = n end\n", "", 1)],
  "attempt ids restart after a load (E7, participant E7)"),
 ("N03-close-keeps-registration", NS,
  [("        for id in pairs(self.joined) do pcall(sg.unregisterNativeSaveParticipant, id, self.participants[id]) end\n", "", 1)],
  "teardown leaves the participant on StockGuard (O3, J9)"),
 ("N04-close-keeps-wrappers", NS,
  [("    if M.current == self then M.current = nil end\n    M.releaseOwn()\n", "    if M.current == self then M.current = nil end\n", 1)],
  "teardown leaves Soil's wrappers live on the controller (L4)"),
 ("N05-capability-not-checked", NS,
  [("    return ok and type(caps) == \"table\" and caps.nativeMaterialSave == 1\n", "    return ok and type(caps) == \"table\"\n", 1)],
  "a StockGuard without the capability takes the boundary (O4)"),
 ("N06-capable-installs-own-too", NS,
  [("        self.mode = self:joinStockGuard() and \"JOINED\" or \"JOIN_REFUSED\"\n        M.releaseOwn()\n    else\n",
    "        self.mode = self:joinStockGuard() and \"JOINED\" or \"JOIN_REFUSED\"\n        M.installOwn(self.classes.SavegameController)\n    else\n", 1)],
  "Soil installs a second wrapper beside StockGuard's (O1, J1)"),
 ("N07-refused-join-reads-joined", NS,
  [("        self.mode = self:joinStockGuard() and \"JOINED\" or \"JOIN_REFUSED\"\n        M.releaseOwn()\n    else\n",
    "        self:joinStockGuard()\n        self.mode = \"JOINED\"\n        M.releaseOwn()\n    else\n", 1)],
  "a refused registration is reported as joined (O3b)"),
 ("N08-reconsider-never", NS,
  [("    if self.closed or self.mode ~= \"OWN\" or not self:stockGuardCapable() then return false end\n",
    "    if true then return false end\n", 1)],
  "StockGuard gaining the capability later never takes the boundary (O6, J7)"),
 ("N09-reconsider-keeps-own", NS,
  [("    self.mode = self:joinStockGuard() and \"JOINED\" or \"JOIN_REFUSED\"\n    M.releaseOwn()\n    log(\"StockGuard took",
    "    self.mode = self:joinStockGuard() and \"JOINED\" or \"JOIN_REFUSED\"\n    log(\"StockGuard took", 1)],
  "a later StockGuard and Soil's own both run (O6, J7)"),
 ("N10-attempt-on-failed-start", NS,
  [("    if ok == nil or errorCode ~= ok or savegameDirectory == nil then return nil end\n", "    if ok == nil then return nil end\n", 1)],
  "a failed start opens an attempt (F1)"),
 ("N11-not-own-boundary", NS,
  [("        ownBoundary = true,       -- Soil's own boundary: the participant names its images\n", "", 1)],
  "on Soil's own boundary the participant names no height image (E1, participant E3)"),
 ("N12-begin-failure-kills-all", NS,
  [("        local okBegin, err = pcall(spec.beginAttempt, context)\n", "        local okBegin, err = true, spec.beginAttempt(context)\n", 1)],
  "a participant throwing at begin aborts the save"),
 ("N13-freeze-before-chain", NS,
  [("        attempt.chainEntered = true\n        local n, r = packn(pcall(chain, obj, ...))\n        if r[1] then\n            local okFreeze, err = pcall(M.freeze, attempt)\n",
    "        attempt.chainEntered = true\n        local okFreeze, err = pcall(M.freeze, attempt)\n        local n, r = packn(pcall(chain, obj, ...))\n        if r[1] then\n", 1)],
  "the freeze runs before the career chain (E1, participant E2: no soilData.xml yet)"),
 ("N14-career-wrap-left", NS,
  [("    if rawget(w.object, \"saveToXMLFile\") == w.wrapper then rawset(w.object, \"saveToXMLFile\", w.ownField) end\n", "", 1)],
  "the career save keeps the temporary field (E6)"),
 ("N15-freeze-throw-kills-all", NS,
  [("            local ok, out = pcall(m.spec.freezeAfterCareerXML, context)\n", "            local ok, out = true, m.spec.freezeAfterCareerXML(context)\n", 1)],
  "a participant throwing at the freeze takes the others with it (F3)"),
 ("N16-unavailable-read-as-ready", NS,
  [("    if out.state == M.UNAVAILABLE then return { state = M.UNAVAILABLE, reason = tostring(out.reason or \"UNAVAILABLE\") } end\n", "", 1)],
  "a participant's UNAVAILABLE answer is not kept (participant U5)"),
 ("N17-image-not-checked-native", NS,
  [("                if n == nil or n.mapId ~= img.mapId or not M.SUPPORTED_IMAGES[n.kind] then\n", "                if false then\n", 1)],
  "an image the controller does not save is accepted"),
 ("N18-duplicate-keeps-first", NS,
  [("        if #ids > 1 then invalidate(ids, \"DUPLICATE_MAP_PATH\") end\n", "", 1)],
  "an image named twice is prepared for both (F4)"),
 ("N19-prepare-on-blocking", NS,
  [("    if context.isBlocking then return end\n", "", 1)],
  "a blocking save prepares (B2, participant E8)"),
 ("N20-no-association", NS,
  [("                        M.associations[#M.associations + 1] = { attemptId = context.attemptId, mapId = img.mapId, path = path, consumed = false }\n", "", 1)],
  "the controller's own prepare is not skipped: the image of a later frame is written (E2, E4)"),
 ("N21-guard-skips-everything", NS,
  [("        local a = M.matchAssociation(mapId, path)\n        if a ~= nil then\n", "        local a = M.matchAssociation(mapId, path) or {}\n        if a ~= nil then\n", 1)],
  "every prepare is skipped, not only the associated one (E3, G2)"),
 ("N22-guard-in-mod-env", NS,
  [("        if type(rawget(base, name)) == \"function\" then return base, \"ENGINE\" end\n", "        if type(rawget(base, name)) == \"function\" then return _G, \"ENGINE\" end\n", 1)],
  "the guard is written into the mod's own environment (G1)"),
 ("N23-guard-erases-later", NS,
  [("    if rawget(g.table, M.GUARDED_GLOBAL) == g.wrapper then\n", "    if true then\n", 1)],
  "removing the guard erases a later wrapper (G3)"),
 ("N24-guard-never-removed", NS,
  [("    M.clearAssociations(context.attemptId)\n    M.removeGuard()\n    local results = {}\n", "    M.clearAssociations(context.attemptId)\n    local results = {}\n", 1)],
  "the guard outlives the result (E5)"),
 ("N25-finish-skipped", NS,
  [("        local ok, err = pcall(m.spec.finishAttempt, context, errorCode, finalSavegameDirectory)\n", "        local ok, err = true, nil\n", 1)],
  "participants never see the result (E1, F2, participant E2)"),
 ("N26-start-not-reconsidered", NS,
  [("    if boundary ~= nil and boundary:reconsider() then return original(controller, errorCode, savegameDirectory, ...) end\n", "", 1)],
  "a save after StockGuard gained the capability still opens Soil's attempt (O6)"),
 ("N27-finish-any-controller", NS,
  [("    if boundary ~= nil and boundary.attempt ~= nil and boundary.attempt.controller == controller then\n",
    "    if boundary ~= nil and boundary.attempt ~= nil then\n", 1)],
  "equivalent here: one controller in the bench"),
 ("N28-inactive-wrapper-runs", NS,
  [("                if not _active then return original(self, ...) end\n", "", 1)],
  "a released wrapper under a later one still runs the boundary (O7)"),
 ("N29-release-never-unlinks", NS,
  [("        if e.linked and _wraps.class[name] == e.wrapper then\n", "        if false then\n", 1)],
  "a released wrapper on top stays in the chain (O6, L4, J7)"),
 ("N30-release-unlinks-under-later", NS,
  [("        if e.linked and _wraps.class[name] == e.wrapper then\n", "        if e.linked then\n", 1)],
  "releasing erases the later wrapper above Soil's (O7)"),
 # ── the participant ─────────────────────────────────────────────────────────
 ("P01-verdict-survives-mission", GS,
  [("    S.lastVerdict = nil     -- module state outlives a mission: never apply another load's verdict\n", "", 1)],
  "an earlier load's UNPAIRED verdict marks the next career (L3)"),
 ("P02-verdict-read-late", GS,
  [("    boundary:activate()\n    S.noteSavedVerdict(mission)\n", "    boundary:activate()\n", 1)],
  "no verdict before the store decides (E5, U2)"),
 ("P03-close-keeps-verdict", GS,
  [("    if S.current == self then S.current = nil end\n    S.lastVerdict = nil\n", "    if S.current == self then S.current = nil end\n", 1)],
  "the teardown keeps the verdict (L4)"),
 ("P04-attempt-on-every-file", GS,
  [("    if p ~= nil and not p.wrote then\n", "    if p ~= nil then\n", 1)],
  "equivalent here: one soilData.xml per attempt"),
 ("P05-no-schema", GS,
  [("    setXMLInt(xmlFile, S.KEY .. \"#schema\", S.SCHEMA)\n", "", 1)],
  "an out-of-band save reads LEGACY (U8, U9, E2)"),
 ("P06-no-attempt-stamp", GS,
  [("        setXMLInt(xmlFile, S.KEY .. \"#attemptId\", p.attemptId)\n", "", 1)],
  "no save pairs (E2, E5)"),
 ("P07-layers-ignored", GS,
  [("    if not p.layers then return { state = S.UNAVAILABLE, reason = \"LAYERS_NOT_SAVED\" } end\n", "", 1)],
  "a save whose condition layer failed pairs (U5, U6)"),
 ("P08-no-soil-data-ignored", GS,
  [("    if not p.wrote then return { state = S.UNAVAILABLE, reason = \"NO_SOIL_DATA\" } end\n", "", 1)],
  "an attempt without soilData.xml freezes READY"),
 ("P09-image-when-joined", GS,
  [("    if p.own then\n        local mission", "    if true then\n        local mission", 1)],
  "joined, the participant claims the height image a second time (J2)"),
 ("P10-no-image-own", GS,
  [("        images[1] = { mapId = id, nativeFilename = file }\n", "", 1)],
  "on Soil's own boundary the height image is not prepared (E3)"),
 ("P11-complete-on-failed-save", GS,
  [("    if Savegame == nil or errorCode ~= Savegame.ERROR_OK then reason = \"SAVE_FAILED:\" .. tostring(errorCode)\n    elseif",
    "    if Savegame == nil then reason = \"SAVE_FAILED:\" .. tostring(errorCode)\n    elseif", 1)],
  "a failed save writes its completion (U1, U2)"),
 ("P12-complete-not-ready", GS,
  [("    elseif mine == nil or mine.state ~= S.READY then reason = \"NOT_READY:\" .. tostring(mine and mine.reason)\n", "", 1)],
  "an UNAVAILABLE participant writes its completion (U5)"),
 ("P13-sg2-not-required", GS,
  [("        if g == nil or g.state ~= S.READY then reason = \"STOCKGUARD_GROUND_NOT_READY:\" .. tostring(g and (g.reason or g.state)) end\n", "", 1)],
  "joined, the completion is written without StockGuard's ground (J5, J6)"),
 ("P14-completion-attempt-unchecked", GS,
  [("    if getXMLInt(xmlFile, S.KEY .. \"#attemptId\") ~= attemptId then\n", "    if false then\n", 1)],
  "a completion is written into a soilData.xml of another attempt"),
 ("P15-completion-wrong-value", GS,
  [("    setXMLInt(xmlFile, S.KEY .. \"#completeAttemptId\", attemptId)\n", "    setXMLInt(xmlFile, S.KEY .. \"#completeAttemptId\", attemptId + 1)\n", 1)],
  "the completion names another attempt (E2, E5)"),
 ("P16-legacy-not-legacy", GS,
  [("    if schema == nil then return { state = S.LEGACY } end\n", "    if schema == nil then return { state = S.UNPAIRED, reason = \"NO_SCHEMA\" } end\n", 1)],
  "a save from before this build is marked unavailable (L1)"),
 ("P17-schema-unchecked", GS,
  [("    if schema ~= S.SCHEMA then v.state, v.reason = S.UNPAIRED, \"SCHEMA:\" .. tostring(schema)\n    elseif",
    "    if false then\n    elseif", 1)],
  "a foreign schema pairs (U10)"),
 ("P18-no-attempt-pairs", GS,
  [("    elseif attempt == nil then v.state, v.reason = S.UNPAIRED, \"NO_ATTEMPT\"\n", "", 1)],
  "an out-of-band save pairs or reads another reason (U9)"),
 ("P19-completion-unchecked", GS,
  [("    elseif complete ~= attempt then v.state, v.reason = S.UNPAIRED, \"NOT_COMPLETE\"\n", "", 1)],
  "an incomplete save pairs (U2, U11)"),
 ("P20-seed-missing", GS,
  [("        SoilNativeSave.current:seedAttempt(math.max(verdict.attemptId or 0, verdict.completeAttemptId or 0))\n", "", 1)],
  "the next save reuses the loaded attempt id (E7)"),
 ("P21-apply-never", GS,
  [("    if v == nil or v.state ~= S.UNPAIRED or coordinator == nil then return 0 end\n", "    if true then return 0 end\n", 1)],
  "an unpaired save marks nothing (U2, U9, J6)"),
 ("P22-apply-paired-too", GS,
  [("    if v == nil or v.state ~= S.UNPAIRED or coordinator == nil then return 0 end\n", "    if v == nil or coordinator == nil then return 0 end\n", 1)],
  "a paired or legacy save is marked (E6, L1)"),
 ("P23-apply-adds-members", GS,
  [("        for gx = gx0, gx1 do coordinator:markUnavailable(gx, gz, reason, true) end\n", "        for gx = gx0, gx1 do coordinator:markUnavailable(gx, gz, reason, false) end\n", 1)],
  "equivalent here: every marked cell is already a member"),
 ("P24-apply-first-cell-only", GS,
  [("        for gx = gx0, gx1 do coordinator:markUnavailable(gx, gz, reason, true) end\n", "        coordinator:markUnavailable(gx0, gz, reason, true)\n", 1)],
  "only the first cell of a run is marked (U2: (4, 4) and (5, 4) are one run)"),
 # ── the seams ───────────────────────────────────────────────────────────────
 ("S01-stamp-not-called", SFM,
  [("            GroundConditionSave.current:stampSoilData(xmlFile, layersSaved)\n", "", 1)],
  "saveSoilData writes no stamp (E2)"),
 ("S02-layers-always-saved", SFM,
  [("            GroundConditionSave.current:stampSoilData(xmlFile, layersSaved)\n", "            GroundConditionSave.current:stampSoilData(xmlFile, true)\n", 1)],
  "a failed layer save pairs (U5)"),
 ("S03-wetness-not-required", SFM,
  [("                and savedByKey.groundMembership == true and savedByKey[MaterialDown.LAYER_KEY] == true and savedByKey[MaterialWetness.LAYER_KEY] == true\n",
    "                and savedByKey.groundMembership == true and savedByKey[MaterialDown.LAYER_KEY] == true\n", 1)],
  "the wetness layer failing still pairs (U5 fails the wetness file)"),
 ("C01-verdict-not-applied", GC,
  [("        local okV, runs = pcall(GroundConditionSave.applyVerdict, self)\n", "        local okV, runs = true, 0\n", 1)],
  "the coordinator never applies the verdict (U2)"),
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
        for mid, rel, _, why in MUTATIONS: print(f"{mid:36s} {rel}  {why}")
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
        worst = 0
        for select in (SELECT[NS], DEFAULT_SELECT):
            rc, _, _, out = run_bench(select)
            print(" ".join(select) + ": " + (out.strip().splitlines()[-1] if out.strip() else "(no output)"))
            worst = max(worst, rc)
        return worst
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
        rc, fails, crashed, _ = run_bench(SELECT.get(rel, DEFAULT_SELECT))
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
