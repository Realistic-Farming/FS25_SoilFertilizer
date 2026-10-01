-- GC-6-ground_condition_save_spec_test.lua
--
-- The ground-condition participant of Soil's native save boundary (GROUND-CONDITION-CONTRACT
-- v1.5 section 6, :96 and :112; SG-2 v2.3 :818-830): the stamp saveSoilData writes, the
-- freeze, the completion in the final directory, the verdict a reload reads, and the
-- coordinator marking the condition of an unpaired save unavailable.
--
-- THE ENTRY-POINT BAR IS GROUP E. The install main.lua's loadedMission runs
-- (GroundConditionSave.installForMission, which main.lua's installNativeSave calls and
-- nothing else), then a native save as the engine runs it: SavegameController:saveSavegame
-- through Soil's own wrappers, the career chain where Soil's appended hook runs the real
-- SoilFertilityManager.saveSoilData (the real per-layer save, the stamp), the staged files
-- moved to the final directory, the completion. Then the reload: a fresh system, the install
-- reading the verdict off the disk, the store deciding at mission start through the
-- manager's own mission-start step. Nothing hand-writes the stamp, the attempt or the
-- verdict; the world supplies the disk, the controller's C side (GC-6-savegame_model.lua)
-- and the member cells the reloaded index holds (the engine model does not round-trip
-- layer bytes, so the reload's member layer is set before the coordinator reads it).
-- main.lua's appended save hook is represented by the call it makes (saveSoilData, with the
-- RSF-F215 invocation opened in front, as MAINT-137's bench does).
--
-- Groups:
--   E  the entry bar: a paired save and its reload
--   U  unpaired: a failed save, a layer that did not save, an out-of-band saveSoilData, a
--      foreign schema, a completion for another attempt; member cells NATIVE_SAVE_UNPAIRED
--   L  legacy and new careers mark nothing; a verdict never outlives its mission
--   J  joined to StockGuard (a stub boundary; the real SGNativeMaterialSave bench follows
--      #24): no Soil wrapper, no image named, the completion needs sg2Ground READY
--   V  the version dialog's "don't show again" (SoilVersionDialog:onClickDontShowAgain, the
--      real method): lastSeenVersion alone, edited in place, so a paired save stays paired
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/GC-6-savegame_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/SoilNativeSave.lua, src/ground/GroundConditionSave.lua, src/SoilFertilityManager.lua, src/ui/SoilVersionDialog.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function GC6_PARTICIPANT_BENCH()
local REAL = getmetatable(_G).__index
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local MDB = SoilMaterialDownBridge
local GCC = GroundConditionCoordinator
local GS = GroundConditionSave
local NS = SoilNativeSave
local KEY = GS.KEY

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── The disk (the controller model's ENGINE_DISK too) and the XML handle calls ──
local DISK = {}
local FAIL_LAYER = {}
local function resetDisk()
    DISK = {}
    REAL.ENGINE_DISK = DISK
    REAL.ENGINE_PREPARE_LOG, REAL.ENGINE_DIRECT_LOG, REAL.ENGINE_PREPARED = {}, {}, {}
    ENGINE_SAVE.startError, ENGINE_SAVE.finishError, ENGINE_SAVE.finishSync, ENGINE_SAVE.errorAfterMove = nil, nil, false, false
    g_asyncTaskManager.tasks = {}
    ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1
    FAIL_LAYER = {}
end
local function newHandle(path) return { path = path, data = {} } end
function createXMLFile(_name, path, _root) return newHandle(path) end
function loadXMLFile(_name, path)
    local d = DISK[path]
    if d == nil then return 0 end
    local h = newHandle(path)
    for k, v in pairs(d) do h.data[k] = v end
    return h
end
function saveXMLFile(h)
    if type(h) ~= "table" then return false end
    local copy = {}
    for k, v in pairs(h.data) do copy[k] = v end
    DISK[h.path] = copy
    return true
end
function delete(_h) end
function fileExists(path) return DISK[path] ~= nil end
function setXMLString(h, k, v) h.data[k] = v end
function getXMLString(h, k) return h.data[k] end
function setXMLInt(h, k, v) h.data[k] = v end
function getXMLInt(h, k) return h.data[k] end
function setXMLBool(h, k, v) h.data[k] = v end
function getXMLBool(h, k) return h.data[k] end
function setXMLFloat(h, k, v) h.data[k] = v end
function getXMLFloat(h, k) return h.data[k] end
function hasXMLProperty(h, p)
    for k in pairs(h.data) do
        if k == p or k:sub(1, #p + 1) == p .. "#" or k:sub(1, #p + 1) == p .. "." then return true end
    end
    return false
end
function saveBitVectorMapToFile(_bvm, path)
    local file = path:match("[^/]+$")
    if FAIL_LAYER[file] then error("disk full: " .. file) end
    DISK[path] = { saved = true }
end
local EPOCHS = 0
Utils = Utils or {}
Utils.getUniqueId = function(_value, _map, prefix, _len) EPOCHS = EPOCHS + 1 return (prefix or "") .. "epoch" .. EPOCHS end
function entityExists(_node) return true end
function getWorldTranslation(_node) return 0, 0, 0 end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end
local REAL_SAVE = SoilValueMaps.saveToSavegame

local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local MODEL_START, MODEL_COMPLETE = SavegameController.onSaveStartComplete, SavegameController.onSaveComplete
local controller = SavegameController.new()
local MEMBERS = { { 4, 4 }, { 5, 4 }, { 6, 9 } }

--- The previous mission's teardown (main.lua's unload closes both).
local function unload()
    if W.boundary ~= nil then W.boundary:close("UNLOAD") end
    if W.condition ~= nil then W.condition:close() end
    W.boundary, W.condition = nil, nil
end

--- A fresh mission on a career in `dir`, in production's order: the system armed, the
--- native save installed (main.lua's loadedMission), then the store's load opened.
--- opts.valid: saved before; opts.loaded: the three layer files loaded from the save;
--- opts.members: the reloaded index's member cells; opts.stockGuard: the mission handle;
--- opts.index: the savegame slot.
local function world(dir, opts)
    opts = opts or {}
    unload()
    HEIGHT.pixels = {}
    MDB.ledgerActive = false
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vmOpts = opts.loaded and { membershipLoaded = true, conditionLoaded = true } or nil
    local vm, age, wet, member = ENGINE.newValueMaps(vmOpts)
    for _, c in ipairs(opts.members or {}) do
        ENGINE.layerSet(member, c[1], c[2], GCC.MEMBER)
        ENGINE.layerSet(age, c[1], c[2], 40)
    end
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    vm.available = true
    vm.layers.groundMembership.def = { file = "groundMembership.grle" }
    vm.layers.materialAge.def = { file = "materialAge.grle" }
    vm.layers.materialWetness.def = { file = "materialWetness.grle" }
    vm.saveToSavegame = REAL_SAVE
    sys.valueMaps = vm
    W.sys, W.vm, W.age = sys, vm, age
    W.mgr = setmetatable({ soilSystem = sys, lastSeenVersion = "bench" }, { __index = SoilFertilityManager })
    local mission = {
        environment = { currentMonotonicDay = 100, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {}, addVehicle = function() return true end },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
        missionInfo = FSCareerMissionInfo.new({ savegameDirectory = dir, isValid = opts.valid == true,
            xmlFile = newHandle(dir .. "/careerSavegame.xml"), savegameIndex = opts.index or 1, savegameName = "bench", mapId = "MapUS" }),
        terrainDetailHeightId = ENGINE_HEIGHT_ID,
        stockGuard = opts.stockGuard,
    }
    g_currentMission = mission
    REAL.g_currentMission = mission
    REAL.g_server = REAL.g_server or {}
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    local okMd = sys.materialDown:arm(vm)
    sys.materialDown.ageAppliedThroughDay = 100
    local okMw = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = 100 })
    local okHb = sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    local okYl = sys.yardLadder:arm(sys.materialDown, sys.materialWetness, sys.hayBet)
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    -- main.lua's loadedMission: the native save install, before the store's load opens.
    W.boundary, W.condition = GS.installForMission(mission)
    MDB.beginLoad(sys.materialDown)
    MDB.loadFallback(sys.materialDown)
    return (okMd and okMw and okHb and okYl and a and b) == true
end
local function coord() return W.sys.groundConditionCoordinator end
local function md() return W.sys.materialDown end
local function missionStart() SoilFertilityManager._groundMissionStarted(W.mgr) end

--- main.lua's appended save hook, the call it makes: the RSF-F215 invocation opened in
--- front, saveSoilData, the career XML written.
local function careerHook(mi)
    MDB.openSaveInvocation()
    mi.xmlFile = newHandle(mi.savegameDirectory .. "/careerSavegame.xml")
    SoilFertilityManager.saveSoilData(W.mgr, mi)
    saveXMLFile(mi.xmlFile)
end
--- A native save as the engine runs it, the staged files landing in `final`.
local function nativeSave(final, blocking, between)
    ENGINE_SAVE.finalDir = final
    REAL.ENGINE_CAREER_HOOK = careerHook
    controller:saveSavegame(g_currentMission.missionInfo, blocking == true)
    local frames = ENGINE_RUN_FRAMES(between)
    REAL.ENGINE_CAREER_HOOK = nil
    return frames
end
local function stampOf(dir)
    local d = DISK[dir .. "/soilData.xml"]
    if d == nil then return "none" end
    return tostring(d[KEY .. "#schema"]) .. ":" .. tostring(d[KEY .. "#attemptId"]) .. ":" .. tostring(d[KEY .. "#completeAttemptId"])
end
local function verdict() local v = GS.lastVerdict return v == nil and "nil" or (tostring(v.state) .. (v.reason and (":" .. v.reason) or "")) end
local function unav(gx, gz) return tostring(coord():isUnavailable(gx, gz)) .. ":" .. tostring(coord():unavailableReason(gx, gz)) end
local function membersUnav()
    local out = {}
    for _, c in ipairs(MEMBERS) do out[#out + 1] = unav(c[1], c[2]) end
    return table.concat(out, " ")
end

--- A new career in `dir` saved once into `final`; cell (3, 3) a native error marked before.
local function savedCareer(dir, final, opts)
    opts = opts or {}
    world(dir, { valid = false, index = opts.index, stockGuard = opts.stockGuard })
    W.sys.yardLadder:onMissionStarted()
    coord():markUnavailable(3, 3, "NATIVE_ERROR")
    if opts.failLayer then FAIL_LAYER[opts.failLayer] = true end
    if opts.finishError then ENGINE_SAVE.finishError, ENGINE_SAVE.errorAfterMove = opts.finishError, true end
    nativeSave(final, opts.blocking)
    FAIL_LAYER = {}
    ENGINE_SAVE.finishError, ENGINE_SAVE.errorAfterMove = nil, false
end
--- Reload `final` and start the mission (the store decides).
local function reload(final, opts)
    opts = opts or {}
    world(final, { valid = true, loaded = true, members = MEMBERS, index = opts.index, stockGuard = opts.stockGuard })
    local before = verdict()
    missionStart()
    return before
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY BAR: A PAIRED SAVE AND ITS RELOAD
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetDisk()
    T.ok("E0 [world] the store's save is the real method", type(REAL_SAVE) == "function")
    world("e_career", { valid = false, index = 2 })
    T.eq("E1 [entry point] the install main.lua runs: Soil's own boundary (no StockGuard), its wrappers on the controller, the participant registered, no verdict on a new career",
        tostring(W.boundary and W.boundary.mode) .. "/" .. tostring(SavegameController.onSaveStartComplete ~= MODEL_START and SavegameController.onSaveComplete ~= MODEL_COMPLETE)
            .. "/" .. tostring(W.boundary and W.boundary.participants[GS.PARTICIPANT_ID] == W.condition.spec) .. "/" .. verdict(),
        "OWN/true/true/nil")
    W.sys.yardLadder:onMissionStarted()
    coord():markUnavailable(3, 3, "NATIVE_ERROR")
    local moved = 0
    nativeSave("e_final", false, function(frame) ENGINE_MAPS[ENGINE_HEIGHT_ID].version = 1 + frame moved = frame end)
    T.eq("E2 [entry point] one native save: soilData.xml in the FINAL directory carries the schema, the attempt and its completion; nothing is left in staging",
        stampOf("e_final") .. "/" .. tostring(DISK["staging2/soilData.xml"]), "1:1:1/nil")
    T.eq("E3 the participant froze READY with the height image, which the boundary prepared exactly once, and the layers it pairs are in the final directory",
        tostring(W.boundary.lastAttempt.results[GS.PARTICIPANT_ID].state) .. "/" .. #ENGINE_PREPARE_LOG .. "/"
            .. tostring(DISK["e_final/densityMap_height.gdm"] ~= nil and DISK["e_final/groundMembership.grle"] ~= nil and DISK["e_final/materialAge.grle"] ~= nil and DISK["e_final/materialWetness.grle"] ~= nil),
        "READY/4/true")
    T.eq("E3b the world moved on for " .. moved .. " frames, and the height file in the final directory is the image of the freeze (version 1), the moment soilData.xml describes",
        tostring(moved > 1) .. "/" .. tostring(DISK["e_final/densityMap_height.gdm"].version), "true/1")
    T.eq("E4 the completion is the participant's own record: written, no reason", tostring(W.condition.lastFinish.written) .. "/" .. tostring(W.condition.lastFinish.reason), "true/nil")
    local before = reload("e_final", { index = 2 })
    T.eq("E5 [entry point] the reload's install reads PAIRED off the disk, before the store decides", before, "PAIRED")
    T.eq("E6 at mission start the store decides MODERN; the saved overlay comes back and no member cell is marked",
        tostring(md().loadState) .. " " .. unav(3, 3) .. " " .. membersUnav(), "MODERN true:NATIVE_ERROR false:nil false:nil false:nil")
    nativeSave("e_final2")
    T.eq("E7 the next save's attempt continues past the loaded one (seeded at install)", stampOf("e_final2"), "1:2:2")
    -- A blocking save (the exit save) pairs the same way.
    local preparesBefore = #ENGINE_PREPARE_LOG
    savedCareer("e_career3", "e_final3", { index = 3, blocking = true })
    T.eq("E8 a blocking save pairs too: completion written, no prepare at all", stampOf("e_final3") .. "/" .. (#ENGINE_PREPARE_LOG - preparesBefore), "1:1:1/0")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNPAIRED
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
    resetDisk()
    savedCareer("u_career", "u_final", { index = 4, finishError = Savegame.ERROR_WRITE })
    T.eq("U1 a save that failed at finish (the files moved anyway): soilData.xml carries the attempt and no completion", stampOf("u_final"), "1:1:nil")
    local before = reload("u_final", { index = 4 })
    T.eq("U2 the reload reads UNPAIRED (NOT_COMPLETE); at mission start every member cell is unavailable for that reason, and the overlay is not restored",
        before .. " " .. tostring(md().loadState) .. " " .. membersUnav(),
        "UNPAIRED:NOT_COMPLETE MODERN true:NATIVE_SAVE_UNPAIRED:NOT_COMPLETE true:NATIVE_SAVE_UNPAIRED:NOT_COMPLETE true:NATIVE_SAVE_UNPAIRED:NOT_COMPLETE")
    T.eq("U3 marking is the availability overlay only: the condition bytes are kept and the cells stay members",
        tostring(ENGINE.layerGet(W.age, 4, 4)) .. "/" .. tostring(coord():isMember(4, 4)), "40/true")
    T.eq("U4 a cell outside the index is not marked", unav(8, 8), "false:nil")

    resetDisk()
    savedCareer("u_career5", "u_final5", { index = 5, failLayer = "materialWetness.grle" })
    T.eq("U5 a condition layer that did not save: the participant froze UNAVAILABLE (LAYERS_NOT_SAVED), so no completion",
        tostring(W.boundary.lastAttempt.results[GS.PARTICIPANT_ID].reason) .. "/" .. stampOf("u_final5"), "LAYERS_NOT_SAVED/1:1:nil")
    T.eq("U6 and its reload is UNPAIRED", reload("u_final5", { index = 5 }), "UNPAIRED:NOT_COMPLETE")

    -- An out-of-band saveSoilData (the version dialog, a settings action, the console command)
    -- into the live directory of a save that had paired.
    resetDisk()
    savedCareer("u_career7", "u_final7", { index = 7 })
    T.eq("U7 [precondition] the save paired", stampOf("u_final7"), "1:1:1")
    g_currentMission.missionInfo.savegameDirectory = "u_final7"
    SoilFertilityManager.saveSoilData(W.mgr, g_currentMission.missionInfo)
    T.eq("U8 an out-of-band saveSoilData rewrites soilData.xml with the stamp and no attempt", stampOf("u_final7"), "1:nil:nil")
    T.eq("U9 and the reload is UNPAIRED (NO_ATTEMPT): those layers describe a moment no height image does",
        reload("u_final7", { index = 7 }) .. " " .. unav(4, 4), "UNPAIRED:NO_ATTEMPT true:NATIVE_SAVE_UNPAIRED:NO_ATTEMPT")

    resetDisk()
    savedCareer("u_career10", "u_final10", { index = 10 })
    DISK["u_final10/soilData.xml"][KEY .. "#schema"] = 2
    T.eq("U10 a stamp of another schema is UNPAIRED", reload("u_final10", { index = 10 }), "UNPAIRED:SCHEMA:2")
    resetDisk()
    savedCareer("u_career11", "u_final11", { index = 11 })
    DISK["u_final11/soilData.xml"][KEY .. "#completeAttemptId"] = 9
    T.eq("U11 a completion for another attempt is UNPAIRED", reload("u_final11", { index = 11 }), "UNPAIRED:NOT_COMPLETE")

    resetDisk()
    world("u_career12", { valid = false, index = 12 })
    W.sys.yardLadder:onMissionStarted()
    local mgrSystem = W.mgr.soilSystem
    W.mgr.soilSystem = nil          -- saveSoilData returns before writing anything
    nativeSave("u_final12")
    W.mgr.soilSystem = mgrSystem
    T.eq("U12 a save in which saveSoilData wrote no soilData.xml: UNAVAILABLE (NO_SOIL_DATA), no completion",
        tostring(W.boundary.lastAttempt.results[GS.PARTICIPANT_ID].reason) .. "/" .. stampOf("u_final12"), "NO_SOIL_DATA/none")
    DISK["u_final13/soilData.xml"] = { [KEY .. "#schema"] = 1, [KEY .. "#attemptId"] = 5 }
    local okW, whyW = GS.writeCompletion("u_final13/soilData.xml", 6)
    T.eq("U13 the completion is never written into a soilData.xml of another attempt", tostring(okW) .. "/" .. tostring(whyW) .. "/" .. stampOf("u_final13"), "false/ATTEMPT_MISMATCH/1:5:nil")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. LEGACY, NEW CAREERS, AND A VERDICT THAT MUST NOT OUTLIVE ITS MISSION
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    resetDisk()
    savedCareer("l_career", "l_final", { index = 12 })
    local d = DISK["l_final/soilData.xml"]
    d[KEY .. "#schema"], d[KEY .. "#attemptId"], d[KEY .. "#completeAttemptId"] = nil, nil, nil
    T.eq("L1 a soilData.xml from before this build (no stamp) loads LEGACY, and nothing is marked",
        reload("l_final", { index = 12 }) .. " " .. membersUnav(), "LEGACY false:nil false:nil false:nil")
    -- An unpaired save loaded, then a new career in the same process.
    resetDisk()
    savedCareer("l_career2", "l_final2", { index = 13, finishError = Savegame.ERROR_WRITE })
    T.eq("L2 [precondition] the first mission loaded UNPAIRED", reload("l_final2", { index = 13 }), "UNPAIRED:NOT_COMPLETE")
    unload()
    T.eq("L2b the mission's teardown clears the verdict", verdict(), "nil")
    reload("l_final2", { index = 13 })
    -- A mission whose teardown never ran (its unload hook did not reach the closes).
    W.boundary, W.condition = nil, nil
    world("l_new", { valid = false, members = MEMBERS, index = 14 })
    local before = verdict()
    missionStart()
    T.eq("L3 the next mission is a new career, after a mission whose teardown never ran: the install drops the old verdict, and nothing is marked",
        before .. " " .. membersUnav(), "nil false:nil false:nil false:nil")
    unload()
    T.eq("L4 the mission's teardown releases Soil's wrappers and clears the verdict",
        tostring(SavegameController.onSaveStartComplete == MODEL_START and SavegameController.onSaveComplete == MODEL_COMPLETE) .. "/" .. verdict() .. "/" .. tostring(GS.current) .. "/" .. tostring(NS.current),
        "true/nil/nil/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- J. JOINED TO STOCKGUARD (a stub boundary that calls the participant as SG-2 :818-830
--    describes; the bench against the real SGNativeMaterialSave follows #24)
-- ══════════════════════════════════════════════════════════════════════════
local function stockGuardStub(capable)
    local sg = { registered = {}, nextAttempt = 100, sg2 = { state = "READY" } }
    sg.getCapabilities = function() return { nativeMaterialSave = sg.capable and 1 or nil } end
    sg.capable = capable
    sg.registerNativeSaveParticipant = function(id, spec) sg.registered[id] = spec return true end
    sg.unregisterNativeSaveParticipant = function(id, spec) if sg.registered[id] == spec then sg.registered[id] = nil return true end return false, "NOT_OWNER" end
    --- One StockGuard attempt around a native save: begin, the freeze at the end of the
    --- career chain, the result with the final directory.
    function sg.save(final)
        sg.nextAttempt = sg.nextAttempt + 1
        local ctx = { attemptId = sg.nextAttempt, ownBoundary = false, mission = g_currentMission, results = {} }
        for _, spec in pairs(sg.registered) do spec.beginAttempt(ctx) end
        ENGINE_SAVE.finalDir = final
        REAL.ENGINE_CAREER_HOOK = function(mi)
            careerHook(mi)
            for id, spec in pairs(sg.registered) do ctx.results[id] = spec.freezeAfterCareerXML(ctx) end
            ctx.results[GS.SG2_GROUND] = sg.sg2
        end
        local n = #controller.completed
        controller:saveSavegame(g_currentMission.missionInfo, false)
        ENGINE_RUN_FRAMES()
        REAL.ENGINE_CAREER_HOOK = nil
        local errorCode = controller.completed[n + 1]
        for _, spec in pairs(sg.registered) do spec.finishAttempt(ctx, errorCode, final) end
        return ctx
    end
    return sg
end
group("J", function()
    resetDisk()
    local sg = stockGuardStub(true)
    world("j_career", { valid = false, index = 20, stockGuard = sg })
    T.eq("J1 StockGuard with the capability at install: Soil installs NO wrapper, and its participant is registered on StockGuard's boundary (its own spec)",
        tostring(W.boundary.mode) .. "/" .. tostring(SavegameController.onSaveStartComplete == MODEL_START and SavegameController.onSaveComplete == MODEL_COMPLETE)
            .. "/" .. tostring(sg.registered[GS.PARTICIPANT_ID] == W.condition.spec),
        "JOINED/true/true")
    W.sys.yardLadder:onMissionStarted()
    local ctx = sg.save("j_final")
    local r = ctx.results[GS.PARTICIPANT_ID]
    T.eq("J2 joined, the freeze names NO image (SG2's height association is shared, SG-2 :824) and Soil opens no attempt of its own",
        tostring(r.state) .. "/" .. tostring(r.payloadFile) .. "/" .. #r.images .. "/" .. tostring(W.boundary.lastAttempt), "READY/soilData.xml/0/nil")
    T.eq("J3 with sg2Ground READY the completion is written under StockGuard's attempt id", stampOf("j_final"), "1:101:101")
    T.eq("J4 and the reload pairs", reload("j_final", { index = 20, stockGuard = sg }), "PAIRED")

    resetDisk()
    sg = stockGuardStub(true)
    sg.sg2 = { state = "UNAVAILABLE", reason = "BINDING_FAULT" }
    world("j_career5", { valid = false, index = 21, stockGuard = sg })
    W.sys.yardLadder:onMissionStarted()
    sg.save("j_final5")
    T.eq("J5 sg2Ground UNAVAILABLE: nothing paired the height image with this attempt, so no completion",
        stampOf("j_final5") .. "/" .. tostring(W.condition.lastFinish.reason), "1:101:nil/STOCKGUARD_GROUND_NOT_READY:BINDING_FAULT")
    T.eq("J6 and the reload is UNPAIRED with every member cell unavailable",
        reload("j_final5", { index = 21, stockGuard = sg }) .. " " .. unav(4, 4), "UNPAIRED:NOT_COMPLETE true:NATIVE_SAVE_UNPAIRED:NOT_COMPLETE")

    -- StockGuard gains the capability after Soil installed its own (mission start reconsiders).
    resetDisk()
    sg = stockGuardStub(false)
    world("j_career7", { valid = false, index = 22, stockGuard = sg })
    local own = tostring(W.boundary.mode) .. "/" .. tostring(SavegameController.onSaveStartComplete ~= MODEL_START)
    sg.capable = true
    NS.current:reconsider()
    T.eq("J7 StockGuard without the capability at install: Soil's own; gaining it later: Soil joins, registers its participant there and unlinks its wrappers",
        own .. " " .. tostring(W.boundary.mode) .. "/" .. tostring(sg.registered[GS.PARTICIPANT_ID] == W.condition.spec) .. "/"
            .. tostring(SavegameController.onSaveStartComplete == MODEL_START and SavegameController.onSaveComplete == MODEL_COMPLETE),
        "OWN/true JOINED/true/true")
    W.sys.yardLadder:onMissionStarted()
    sg.save("j_final7")
    T.eq("J8 the next save runs under StockGuard's attempt, never one of Soil's", stampOf("j_final7") .. "/" .. tostring(W.boundary.lastAttempt), "1:101:101/nil")
    unload()
    T.eq("J9 the teardown removes the participant from StockGuard by identity", tostring(sg.registered[GS.PARTICIPANT_ID]), "nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- V. THE VERSION DIALOG'S "DON'T SHOW AGAIN"
-- ══════════════════════════════════════════════════════════════════════════
local CLOSED = {}
g_gui = { closeDialogByName = function(_, name) CLOSED[#CLOSED + 1] = name end }
local function dontShowAgain(version)
    g_SoilFertilityManager = W.mgr
    SoilVersionDialog.onClickDontShowAgain({ _version = version })
end
group("V", function()
    resetDisk()
    savedCareer("v_career", "v_final", { index = 30 })
    reload("v_final", { index = 30 })
    local layer = DISK["v_final/materialAge.grle"]
    dontShowAgain("9.9.9")
    local d = DISK["v_final/soilData.xml"]
    T.eq("V1 [entry point] \"don't show again\" on a loaded save: the version lands in soilData.xml, edited in place; the native save stamp is untouched and no condition layer is rewritten",
        tostring(d["soilData#lastSeenVersion"]) .. "/" .. stampOf("v_final") .. "/" .. tostring(DISK["v_final/materialAge.grle"] == layer) .. "/" .. tostring(CLOSED[#CLOSED]),
        "9.9.9/1:1:1/true/SoilVersionDialog")
    T.eq("V2 quit without saving and reload: still PAIRED, nothing marked", reload("v_final", { index = 30 }) .. " " .. membersUnav(), "PAIRED false:nil false:nil false:nil")

    -- A career never saved: no soilData.xml exists, and none is created (SF-76 genesis reads it).
    resetDisk()
    world("v_new", { valid = false, index = 31 })
    dontShowAgain("9.9.9")
    T.eq("V3 a career never saved: no soilData.xml is created; the version waits in memory for the first save",
        tostring(DISK["v_new/soilData.xml"]) .. "/" .. tostring(W.mgr.lastSeenVersion), "nil/9.9.9")
    W.sys.yardLadder:onMissionStarted()
    nativeSave("v_final3")
    T.eq("V4 and the first save carries it, paired", tostring(DISK["v_final3/soilData.xml"]["soilData#lastSeenVersion"]) .. "/" .. stampOf("v_final3"), "9.9.9/1:1:1")

    -- A click while a native save attempt is open (the async frames after the career chain).
    resetDisk()
    savedCareer("v_career5", "v_final5", { index = 32 })
    reload("v_final5", { index = 32 })
    local seenOpen = false
    nativeSave("v_final6", false, function(frame)
        if frame == 1 then
            seenOpen = GS.current ~= nil and GS.current.pending ~= nil
            dontShowAgain("8.8.8")
        end
    end)
    T.eq("V5 a click during an open attempt writes nothing to disk; the save it interrupted still pairs, and the version waits for the next save",
        tostring(seenOpen) .. "/" .. tostring(DISK["v_final6/soilData.xml"]["soilData#lastSeenVersion"]) .. "/" .. stampOf("v_final6") .. "/" .. tostring(W.mgr.lastSeenVersion),
        "true/bench/1:2:2/8.8.8")
    unload()
end)
end
GC6_PARTICIPANT_BENCH()
