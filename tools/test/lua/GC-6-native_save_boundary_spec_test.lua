-- GC-6-native_save_boundary_spec_test.lua
--
-- Soil's own native save boundary (GROUND-CONDITION-CONTRACT v1.5 section 6, :96 and :112;
-- SG-2 v2.3 :818-836), the mechanism with participants the bench registers. The ground-
-- condition participant and main.lua's install path have their own rows.
--
-- Runs in the MOD'S OWN ENVIRONMENT (--!env: modenv): the engine model and the C functions
-- live in the real global table, Soil's src and this file in an environment whose _G is
-- itself; engine globals are set in the real table.
--
-- Groups:
--   E  one nonblocking save: the attempt, the freeze at the end of the chain, exactly one
--      height prepare with the freeze's image, the result with the final directory
--   B  a blocking save: the freeze before the direct writes, no prepare at all
--   G  the guard: the real table only; unmatched calls pass; removed after the result; a
--      later wrapper stays
--   O  one owner (GCC :112): StockGuard with the capability at install: Soil installs
--      nothing and its participant joins; without it, Soil's own boundary; StockGuard gaining
--      it later: Soil releases (unlinks when on top, else a pure pass-through, module state)
--   F  failures: a failed start opens nothing; a failed save reaches every participant; a
--      throwing participant is the only one unavailable; a duplicate image invalidates both
--
--!env: modenv
--!load: tools/test/lua/GC-6-savegame_model.lua, src/utils/Logger.lua, src/ground/SoilNativeSave.lua

local REAL = getmetatable(_G).__index
local M = SoilNativeSave
local C_PREPARE = REAL.prepareSaveDensityMapToFile
local HEIGHT_FILE = "densityMap_height.gdm"

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function engine(name, value) REAL[name] = value end

local function newMission(opts)
    opts = opts or {}
    return { terrainDetailHeightId = ENGINE_HEIGHT_ID, missionInfo = FSCareerMissionInfo.new({ savegameIndex = opts.index or 1, savegameName = "bench", mapId = "MapUS" }),
             stockGuard = opts.stockGuard }
end
--- A participant that records what it saw; `freeze(context)` returns its answer.
local function stub(freeze)
    local s = { seen = {} }
    s.spec = {
        beginAttempt = function(context) s.seen[#s.seen + 1] = "begin:" .. tostring(context.attemptId) s.context = context end,
        freezeAfterCareerXML = function(context)
            s.seen[#s.seen + 1] = "freeze:" .. tostring(context.attemptId)
            s.atFreeze = { career = ENGINE_CAREER_CALLS, direct = #ENGINE_DIRECT_LOG, prepares = #ENGINE_PREPARE_LOG, own = context.ownBoundary, blocking = context.isBlocking }
            return freeze(context)
        end,
        finishAttempt = function(context, errorCode, finalDir) s.seen[#s.seen + 1] = "finish:" .. tostring(errorCode) .. ":" .. tostring(finalDir) s.result = context.results end,
    }
    return s
end
local function heightImage() return { state = "READY", payloadFile = "soilData.xml", images = { { mapId = ENGINE_HEIGHT_ID, nativeFilename = HEIGHT_FILE } } } end
local function reset()
    ENGINE_DISK, ENGINE_PREPARE_LOG, ENGINE_DIRECT_LOG, ENGINE_PREPARED = {}, {}, {}, {}
    REAL.ENGINE_DISK, REAL.ENGINE_PREPARE_LOG, REAL.ENGINE_DIRECT_LOG, REAL.ENGINE_PREPARED = ENGINE_DISK, ENGINE_PREPARE_LOG, ENGINE_DIRECT_LOG, ENGINE_PREPARED
    ENGINE_SAVE.startError, ENGINE_SAVE.finishError, ENGINE_SAVE.finishSync, ENGINE_SAVE.errorAfterMove = nil, nil, false, false
    ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1
    g_asyncTaskManager.tasks = {}
    REAL.ENGINE_CAREER_HOOK = nil
end
--- A boundary for a fresh mission. Its install decision runs when the mission installs it
--- (installFor), which nativeSave does if the test has not.
local function boundaryFor(mission)
    engine("g_server", {})
    engine("g_currentMission", mission)
    local b = M.new(mission)
    b:activate()
    return b
end
local CLASSES = { SavegameController = SavegameController }
local MODEL_START, MODEL_COMPLETE = SavegameController.onSaveStartComplete, SavegameController.onSaveComplete
local function installFor(b) return b:installForMission(CLASSES) end
local controller = SavegameController.new()
local function nativeSave(mission, blocking, finalDir, between)
    if M.current ~= nil and M.current.mode == nil then installFor(M.current) end
    ENGINE_SAVE.finalDir = finalDir
    controller:saveSavegame(mission.missionInfo, blocking)
    return ENGINE_RUN_FRAMES(between)
end
local function preparesOf(id)
    local n, versions = 0, {}
    for _, p in ipairs(ENGINE_PREPARE_LOG) do if p.id == id then n = n + 1 versions[#versions + 1] = tostring(p.version) end end
    return n .. ":" .. table.concat(versions, ",")
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. ONE NONBLOCKING SAVE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    reset()
    local mission = newMission({ index = 3 })
    local b = boundaryFor(mission)
    local s = stub(heightImage)
    T.eq("E0 a participant registers on Soil's boundary", tostring(b:register("groundCondition", s.spec)), "true")
    local okDup, whyDup = b:register("groundCondition", stub(heightImage).spec)
    T.eq("E0b another spec under a live id is refused, and the live one stays", tostring(okDup) .. "/" .. tostring(whyDup) .. "/" .. tostring(b.participants.groundCondition == s.spec), "false/CONFLICT/true")
    local moved = 0
    nativeSave(mission, false, "e_final", function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1 + frame moved = frame end)
    T.eq("E1 one attempt: begin before the controller, the freeze at the END of the career chain (the career XML written, no prepare yet), the finish with the final directory",
        table.concat(s.seen, "|") .. "/" .. tostring(s.atFreeze.career > 0) .. "/" .. s.atFreeze.prepares .. "/" .. tostring(s.atFreeze.own),
        "begin:1|freeze:1|finish:0:e_final/true/0/true")
    T.eq("E2 the world moved on for " .. moved .. " frames, and the height map was prepared exactly once, with the image of the freeze (version 1)", preparesOf(ENGINE_HEIGHT_ID), "1:1")
    T.eq("E3 every other map the controller saves was prepared exactly once, by its own closure", preparesOf(1):sub(1, 2) .. preparesOf(3):sub(1, 2) .. preparesOf(4):sub(1, 2), "1:1:1:")
    T.eq("E4 the height file in the final directory is the freeze's image", tostring(ENGINE_DISK["e_final/" .. HEIGHT_FILE] and ENGINE_DISK["e_final/" .. HEIGHT_FILE].version), "1")
    T.eq("E5 the participant's result is READY, and after the result the guard is gone and the association cleared",
        tostring(s.result.groundCondition.state) .. "/" .. tostring(rawget(REAL, "prepareSaveDensityMapToFile") == C_PREPARE) .. "/" .. tostring(M.guard) .. "/" .. #M.associations, "READY/true/nil/0")
    T.eq("E6 the career save's temporary field is gone", tostring(rawget(mission.missionInfo, "saveToXMLFile")), "nil")
    b:seedAttempt(41)
    nativeSave(mission, false, "e_final2")
    T.eq("E7 attempt ids continue after the highest a load found", tostring(b.lastAttempt and b.lastAttempt.attemptId), "42")
    b:close("BENCH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A BLOCKING SAVE
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    reset()
    local mission = newMission({ index = 4 })
    local b = boundaryFor(mission)
    local s = stub(heightImage)
    b:register("groundCondition", s.spec)
    nativeSave(mission, true, "b_final")
    T.eq("B1 the freeze ran at the end of the chain, before the controller's direct writes", tostring(s.atFreeze.direct) .. "/" .. tostring(s.atFreeze.blocking), "0/true")
    T.eq("B2 a blocking save prepares nothing: every map written directly, the height at the freeze's world", #ENGINE_PREPARE_LOG .. "/" .. #ENGINE_DIRECT_LOG .. "/" .. tostring(ENGINE_DISK["b_final/" .. HEIGHT_FILE].version), "0/4/1")
    T.eq("B3 READY, finished in the final directory", tostring(s.result.groundCondition.state) .. "/" .. tostring(s.seen[#s.seen]), "READY/finish:0:b_final")
    b:close("BENCH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE GUARD
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    reset()
    local mission = newMission({ index = 5 })
    local b = boundaryFor(mission)
    local s = stub(heightImage)
    b:register("groundCondition", s.spec)
    local seenDuring = nil
    REAL.ENGINE_CAREER_HOOK = function() end
    local frames = 0
    nativeSave(mission, false, "g_final", function(frame)
        frames = frame
        if frame == 1 then seenDuring = { real = rawget(REAL, "prepareSaveDensityMapToFile") ~= C_PREPARE, mod = rawget(_G, "prepareSaveDensityMapToFile") } end
    end)
    T.eq("G1 the guard was written into the real global table behind the mod's environment, never the mod's own", tostring(seenDuring.real) .. "/" .. tostring(seenDuring.mod), "true/nil")
    reset()
    M.associations = { { attemptId = 99, mapId = ENGINE_HEIGHT_ID, path = "x/" .. HEIGHT_FILE, consumed = false } }
    M.ensureGuard()
    REAL.prepareSaveDensityMapToFile(ENGINE_HEIGHT_ID, "y/" .. HEIGHT_FILE)
    REAL.prepareSaveDensityMapToFile(ENGINE_HEIGHT_ID, "x/" .. HEIGHT_FILE)
    T.eq("G2 an unmatched call reaches the C function; only the exact associated map and path is skipped", #ENGINE_PREPARE_LOG .. "/" .. tostring(ENGINE_PREPARE_LOG[1] and ENGINE_PREPARE_LOG[1].path), "1/y/" .. HEIGHT_FILE)
    local later = function(...) return C_PREPARE(...) end
    rawset(REAL, "prepareSaveDensityMapToFile", later)
    T.eq("G3 a later wrapper above ours is never erased", tostring(M.removeGuard()) .. "/" .. tostring(rawget(REAL, "prepareSaveDensityMapToFile") == later), "false/true")
    rawset(REAL, "prepareSaveDensityMapToFile", C_PREPARE)
    M.guard = nil
    M.associations = {}
    b:close("BENCH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. ONE OWNER (GCC :112)
-- ══════════════════════════════════════════════════════════════════════════
local function stockGuardStub(capable)
    local sg = { registered = {} }
    sg.getCapabilities = function() return { nativeMaterialSave = capable and 1 or nil } end
    sg.registerNativeSaveParticipant = function(id, spec) sg.registered[id] = spec return true end
    sg.unregisterNativeSaveParticipant = function(id, spec) if sg.registered[id] == spec then sg.registered[id] = nil return true end return false, "NOT_OWNER" end
    return sg
end
group("O", function()
    reset()
    local sg = stockGuardStub(true)
    local mission = newMission({ index = 6, stockGuard = sg })
    local b = boundaryFor(mission)
    local s = stub(heightImage)
    b:register("groundCondition", s.spec)
    T.eq("O1 StockGuard with the capability at install: Soil installs NOTHING on the controller, and its participant is registered on StockGuard's boundary (the owner's own spec)",
        tostring(installFor(b)) .. "/" .. tostring(SavegameController.onSaveStartComplete == MODEL_START and SavegameController.onSaveComplete == MODEL_COMPLETE) .. "/" .. tostring(sg.registered.groundCondition == s.spec),
        "JOINED/true/true")
    nativeSave(mission, false, "o_final")
    T.eq("O2 a save then runs with no Soil attempt, no Soil prepare and no Soil guard", tostring(b.lastAttempt) .. "/" .. preparesOf(ENGINE_HEIGHT_ID) .. "/" .. #s.seen, "nil/1:1/0")
    b:close("BENCH")
    T.eq("O3 teardown removes Soil's registration from StockGuard by identity", tostring(sg.registered.groundCondition), "nil")
    reset()
    local refuser = stockGuardStub(true)
    refuser.registerNativeSaveParticipant = function() return false, "CONFLICT" end
    mission = newMission({ index = 10, stockGuard = refuser })
    b = boundaryFor(mission)
    b:register("groundCondition", stub(heightImage).spec)
    T.eq("O3b StockGuard owns the boundary and refuses the participant: still no second wrapper (:818); Soil's enhancement is unavailable",
        tostring(installFor(b)) .. "/" .. tostring(SavegameController.onSaveStartComplete == MODEL_START), "JOIN_REFUSED/true")
    b:close("BENCH")
    reset()
    local old = stockGuardStub(false)
    mission = newMission({ index = 7, stockGuard = old })
    b = boundaryFor(mission)
    s = stub(heightImage)
    b:register("groundCondition", s.spec)
    T.eq("O4 StockGuard without the capability (before SG2-4a): nothing registered there; Soil installs its own boundary on the controller",
        tostring(installFor(b)) .. "/" .. tostring(old.registered.groundCondition) .. "/" .. tostring(SavegameController.onSaveStartComplete ~= MODEL_START), "OWN/nil/true")
    nativeSave(mission, false, "o_final2")
    T.eq("O5 and Soil's own boundary runs the save", tostring(b.lastAttempt and b.lastAttempt.results.groundCondition.state), "READY")
    -- StockGuard gains the capability later in the session; Soil's wrappers are on top.
    old.getCapabilities = function() return { nativeMaterialSave = 1 } end
    local before = b.lastAttempt.attemptId
    nativeSave(mission, false, "o_final3")
    T.eq("O6 StockGuard gaining the capability later takes the boundary at the next save: Soil joins it, opens no attempt, and unlinks its wrappers (they were on top)",
        tostring(old.registered.groundCondition == s.spec) .. "/" .. tostring(b.lastAttempt.attemptId == before) .. "/" .. tostring(SavegameController.onSaveStartComplete == MODEL_START and SavegameController.onSaveComplete == MODEL_COMPLETE) .. "/" .. tostring(b.mode),
        "true/true/true/JOINED")
    b:close("BENCH")
    -- A later wrapper above Soil's: Soil cannot unlink, so it becomes a pure pass-through.
    reset()
    local late = stockGuardStub(false)
    mission = newMission({ index = 11, stockGuard = late })
    b = boundaryFor(mission)
    s = stub(heightImage)
    b:register("groundCondition", s.spec)
    installFor(b)
    local soilStart = SavegameController.onSaveStartComplete
    local laterCalls = 0
    SavegameController.onSaveStartComplete = function(self, ...) laterCalls = laterCalls + 1 return soilStart(self, ...) end
    late.getCapabilities = function() return { nativeMaterialSave = 1 } end
    b:reconsider()
    local st = M.ownState()
    nativeSave(mission, false, "o_final4")
    T.eq("O7 a later wrapper above Soil's: the release leaves Soil's start wrapper in the chain as a pure pass-through (module state, no class marker), unlinks the other, and the save runs with no Soil attempt",
        tostring(st.active) .. "/" .. st.linked .. "/" .. laterCalls .. "/" .. tostring(b.lastAttempt) .. "/" .. tostring(rawget(SavegameController, "_sfNativeSave")) .. "/" .. #s.seen .. "/" .. tostring(b.attempt),
        "false/1/1/nil/nil/0/nil")
    -- The later wrapper stays in the chain (another mod's); Soil's pass-through stays under it.
    b:close("BENCH")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. FAILURES
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    reset()
    local mission = newMission({ index = 8 })
    local b = boundaryFor(mission)
    local s = stub(heightImage)
    b:register("groundCondition", s.spec)
    ENGINE_SAVE.startError = Savegame.ERROR_WRITE
    nativeSave(mission, false, "f_final")
    T.eq("F1 a failed start opens no attempt", #s.seen .. "/" .. tostring(b.lastAttempt), "0/nil")
    reset()
    ENGINE_SAVE.finishError = Savegame.ERROR_WRITE
    nativeSave(mission, false, "f_final2")
    T.eq("F2 a failed save reaches the participant with its error and no final directory", tostring(s.seen[#s.seen]), "finish:7:nil")
    reset()
    local thrower = stub(function() error("boom") end)
    local other = stub(function() return { state = "READY", payloadFile = "other.xml", images = {} } end)
    b:register("thrower", thrower.spec)
    b:register("other", other.spec)
    nativeSave(mission, false, "f_final3")
    local r = b.lastAttempt.results
    T.eq("F3 a participant that throws at the freeze is the only one unavailable", tostring(r.thrower.state) .. ":" .. tostring(r.thrower.reason) .. "/" .. tostring(r.other.state) .. "/" .. tostring(r.groundCondition.state), "UNAVAILABLE:FREEZE_THREW/READY/READY")
    reset()
    local b2 = boundaryFor(newMission({ index = 9 }))
    local one, two = stub(heightImage), stub(function() return { state = "READY", payloadFile = "two.xml", images = { { mapId = ENGINE_HEIGHT_ID, nativeFilename = HEIGHT_FILE } } } end)
    b2:register("one", one.spec)
    b2:register("two", two.spec)
    nativeSave(g_currentMission, false, "f_final4")
    r = b2.lastAttempt.results
    T.eq("F4 an image named by two participants invalidates both, never keeping the first", tostring(r.one.reason) .. "/" .. tostring(r.two.reason), "DUPLICATE_MAP_PATH/DUPLICATE_MAP_PATH")
    b2:close("BENCH")
    reset()
    local b3 = boundaryFor(newMission({ index = 15 }))
    local good = stub(heightImage)
    local beginThrows = { beginAttempt = function() error("boom") end,
        freezeAfterCareerXML = function() return { state = "READY", payloadFile = "late.xml", images = {} } end,
        finishAttempt = function() end }
    b3:register("beginThrows", beginThrows)
    b3:register("groundCondition", good.spec)
    nativeSave(g_currentMission, false, "f_final5")
    r = b3.lastAttempt ~= nil and b3.lastAttempt.results or {}
    local rb, rg = r.beginThrows or {}, r.groundCondition or {}
    T.eq("F5 a participant that throws at begin is the only one unavailable; the others run the save",
        tostring(rb.state) .. ":" .. tostring(rb.reason) .. "/" .. tostring(rg.state) .. "/" .. tostring(good.seen[#good.seen]),
        "UNAVAILABLE:BEGIN_FAILED/READY/finish:0:f_final5")
    b3:close("BENCH")
    reset()
    local b4 = boundaryFor(newMission({ index = 16 }))
    local foreign = stub(function() return { state = "READY", payloadFile = "foreign.xml", images = { { mapId = 777, nativeFilename = "densityMap_other.gdm" } } } end)
    local crossed = stub(function() return { state = "READY", payloadFile = "crossed.xml", images = { { mapId = 1, nativeFilename = HEIGHT_FILE } } } end)
    b4:register("foreign", foreign.spec)
    b4:register("crossed", crossed.spec)
    nativeSave(g_currentMission, false, "f_final6")
    r = b4.lastAttempt.results
    T.eq("F6 an image the controller does not save, or a native file under another map id, is refused before any prepare",
        tostring(r.foreign.reason) .. "/" .. tostring(r.crossed.reason) .. "/" .. preparesOf(777) .. "/" .. preparesOf(1):sub(1, 2),
        "IMAGE_NOT_NATIVE/IMAGE_NOT_NATIVE/0:/1:")
    b4:close("BENCH")
    b:close("BENCH")
end)
