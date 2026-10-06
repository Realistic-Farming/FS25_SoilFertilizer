-- CD15-1b-save_participant_spec_test.lua
--
-- CD-15 step 1b (Bob's intake BOB-INTAKE-CD15-1B-1C-2026-10-05, Part 1): the local disease save
-- participant. The header in the selected backend (soilData.xml, or StateLedger's block), the one
-- soilDisease.xml payload frozen at the end of the career chain with every distinct fruit and haulm
-- image named for the same-call prepare, the completion in the FINAL directory, and the restore that
-- reads header, payload and marker as one attempt after the native barrier: RESTORED, the clean
-- FIRST_ACTIVATION, or QUARANTINED, never a nicer clean grid (brief v1.14 :85-101, :218).
--
-- THE ENTRY-POINT BAR IS GROUP E. main.lua's loadedMission install (GroundConditionSave's, then
-- CD15Save.installForMission, the two calls main.lua makes and nothing else), the mission's own
-- onFinishedLoading as the barrier, the real SoilFertilityManager.loadSoilData delivering the
-- header, a native save as the engine runs it (SavegameController:saveSavegame through Soil's own
-- wrappers, the career chain running the real saveSoilData), the staged files moved to the final
-- directory, the completion; then the reload through the same install, barrier and loadSoilData.
-- The engine's two fruit planes and a haulm (GC-6-savegame_model.lua) share filenames across
-- descriptors (WHEAT and BARLEY on one plane), so the dedupe is exercised and a default-plane
-- shortcut fails. The ONE hand-populated fixture is the cells and the occurrence sequence: no
-- writer allocates a cell or mints an occurrence before 1c, as the 1a bench says of its cells.
--
-- Groups:
--   E  the entry bar: a save and its reload
--   B  a blocking save: nothing prepared, the direct writes follow
--   Q  quarantine: marker missing, payload missing, orphan payload, attempt mismatch, geometry
--      mismatch, duplicate rows, a bad count, a non-finite value, an invalid header; restore mints
--      nothing; a quarantined session's save stays quarantined
--   D  day work: a save mid-settle and mid-spread finishes the day exactly once
--   L  the backends: StateLedger present, present but empty, and its header governing
--   C  a second claim on an image invalidates CD-15 and the claimant, not the native save
--   F  a failed save writes no marker; no save on mission delete
--   O  an out-of-band saveSoilData carries the header that describes the disk
--   W  a save before the restore decided keeps the evidence
--   J  joined to StockGuard (a stub boundary): CD-15 names its images there too
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/GC-6-savegame_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/DiseaseSystem.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/SoilNativeSave.lua, src/ground/GroundConditionSave.lua
--!text: src/disease/CD15Grid.lua, src/disease/CD15Day.lua, src/disease/CD15Model.lua, src/disease/CD15Save.lua, src/integrations/SoilStateLedgerBridge.lua, src/SoilFertilityManager.lua

-- The last six sources (--!text, in main.lua's order) run here as their own chunks, in this
-- bench's mod environment, as the engine runs every sourced file. Pasted into the one
-- concatenated chunk, their file-level locals with the earlier sources' passed Lua's
-- 200-local limit for a single function (216), and the bench runs inside one function for the
-- same reason.
for _, path in ipairs({ "src/disease/CD15Grid.lua", "src/disease/CD15Day.lua", "src/disease/CD15Model.lua", "src/disease/CD15Save.lua", "src/integrations/SoilStateLedgerBridge.lua", "src/SoilFertilityManager.lua" }) do
    assert(load(SOURCE_TEXT[path], "=" .. path, "t", _ENV))()
end

local function CD15_1B_BENCH()
local REAL = getmetatable(_G).__index
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local MDB = SoilMaterialDownBridge
local GS, NS, CS, M, G = GroundConditionSave, SoilNativeSave, CD15Save, CD15Model, CD15Grid
local HK = CS.HEADER_KEY

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── The disk (the controller model's ENGINE_DISK too) and the XML handle calls (GC-6's) ──
local DISK = {}
local function resetDisk()
    DISK = {}
    REAL.ENGINE_DISK = DISK
    REAL.ENGINE_PREPARE_LOG, REAL.ENGINE_DIRECT_LOG, REAL.ENGINE_PREPARED = {}, {}, {}
    ENGINE_SAVE.startError, ENGINE_SAVE.finishError, ENGINE_SAVE.finishSync, ENGINE_SAVE.errorAfterMove = nil, nil, false, false
    g_asyncTaskManager.tasks = {}
    for _, m in pairs(ENGINE_MAPS) do m.version = 1 end
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
function getXMLString(h, k) local v = h.data[k] if v == nil then return nil end return tostring(v) end
function setXMLInt(h, k, v) h.data[k] = v end
function getXMLInt(h, k) local v = h.data[k] if type(v) == "string" then return tonumber(v) end return v end
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
function saveBitVectorMapToFile(_bvm, path) DISK[path] = { saved = true } end
local EPOCHS = 0
Utils = Utils or {}
Utils.getUniqueId = function(_value, _map, prefix, _len) EPOCHS = EPOCHS + 1 return (prefix or "") .. "epoch" .. EPOCHS end
function entityExists(_node) return true end
function getWorldTranslation(_node) return 0, 0, 0 end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end
local REAL_SAVE = SoilValueMaps.saveToSavegame

-- ── The native plane CD-15's geometry reads: the world's default fruit plane and its size ──
g_fruitTypeManager.getDefaultDataPlaneId = function() return 1 end
REAL.getDensityMapSize = function(id) if ENGINE_MAPS[id] ~= nil then return 4096 end return nil end

local SETTINGS = { enabled = true, diseasePressure = true, diseaseMoisture = 2, diseaseDifficulty = 2, cropRotation = true, tuningDiseaseGrowth = 3 }
local W = { rain = 0 }
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local MODEL_START, MODEL_COMPLETE = SavegameController.onSaveStartComplete, SavegameController.onSaveComplete
local controller = SavegameController.new()
-- StateLedger, as Soil's bridge sees it: registerModule on the mission handle; the master file
-- holds what serialize returned at the save, and delivers it (or nil, a new block) at load.
local LEDGER = { present = false, spec = nil, saved = nil, deliver = nil }
LEDGER.handle = { registerModule = function(_, _id, spec) LEDGER.spec = spec return true end }

--- The previous mission's teardown (main.lua's unload closes the boundary, then each participant).
local function unload()
    if W.boundary ~= nil then W.boundary:close("UNLOAD") end
    if W.condition ~= nil then W.condition:close() end
    if CS.current ~= nil then CS.current:close() end
    W.boundary, W.condition, W.part = nil, nil, nil
end

--- A fresh mission on a career in `dir`, in production's order: the system armed, then main.lua's
--- loadedMission (the native save install, CD-15's install, the ledger registration), then the
--- store's load opened. opts: valid, index, terrain, stockGuard, day.
local function world(dir, opts)
    opts = opts or {}
    unload()
    HEIGHT.pixels = {}
    MDB.ledgerActive = false
    local settings = {}
    for k, v in pairs(SETTINGS) do settings[k] = v end
    local sys = SoilFertilitySystem.new(settings)
    local vm, age = ENGINE.newValueMaps()
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    vm.available = true
    if opts.terrain ~= nil then vm.terrainSize = opts.terrain end
    vm.layers.groundMembership.def = { file = "groundMembership.grle" }
    vm.layers.materialAge.def = { file = "materialAge.grle" }
    vm.layers.materialWetness.def = { file = "materialWetness.grle" }
    vm.saveToSavegame = REAL_SAVE
    sys.valueMaps = vm
    W.sys, W.vm, W.age, W.model = sys, vm, age, sys.cd15
    W.mgr = setmetatable({ soilSystem = sys, lastSeenVersion = "bench" }, { __index = SoilFertilityManager })
    W.barrierCalls = 0
    local mission = {
        environment = { currentMonotonicDay = opts.day or 100, currentDay = 1, currentSeason = 2, daysPerPeriod = 3,
                        weather = { getRainFallScale = function() return W.rain end } },
        vehicleSystem = { vehicles = {}, addVehicle = function() return true end },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
        missionInfo = FSCareerMissionInfo.new({ savegameDirectory = dir, isValid = opts.valid == true,
            xmlFile = newHandle(dir .. "/careerSavegame.xml"), savegameIndex = opts.index or 1, savegameName = "bench", mapId = "MapUS" }),
        terrainDetailHeightId = ENGINE_HEIGHT_ID,
        stockGuard = opts.stockGuard,
        stateLedger = LEDGER.present and LEDGER.handle or nil,
        onFinishedLoading = function(_m) W.barrierCalls = W.barrierCalls + 1 end,
    }
    g_currentMission = mission
    REAL.g_currentMission = mission
    REAL.g_server = REAL.g_server or {}
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, _x, _z) return 7 end
    sys.materialDown:arm(vm)
    sys.materialDown.ageAppliedThroughDay = 100
    sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = 100 })
    sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    sys.yardLadder:arm(sys.materialDown, sys.materialWetness, sys.hayBet)
    local a = sys.groundConditionCells:arm(vm)
    if a then sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys) end
    -- main.lua's loadedMission: the native save install, then CD-15's, then the ledger bridge.
    W.boundary, W.condition = GS.installForMission(mission)
    W.part = CS.installForMission(mission)
    LEDGER.spec = nil
    -- Every mission, as main.lua:460-461 calls it: register resets the bridge's per-load state
    -- (active, delivered, pendingState) and then finds the ledger present or absent.
    SoilStateLedgerBridge.register(W.mgr)
    MDB.beginLoad(sys.materialDown)
    MDB.loadFallback(sys.materialDown)
    return mission
end

--- The rest of the load in production's order: the ledger delivers its block (its own load), the
--- native barrier (BaseMission:finishLoadingTask calls the instance's onFinishedLoading), then
--- mission start runs loadSoilData (activateSoilSystem).
local function loadAndStart()
    if LEDGER.present and LEDGER.spec ~= nil then LEDGER.spec.deserialize(LEDGER.deliver) end
    g_currentMission:onFinishedLoading()
    SoilFertilityManager.loadSoilData(W.mgr)
end

--- main.lua's appended save hook, the call it makes (GC-6's careerHook), with StateLedger's own
--- append on the same chain when the ledger is present.
local function careerHook(mi)
    MDB.openSaveInvocation()
    mi.xmlFile = newHandle(mi.savegameDirectory .. "/careerSavegame.xml")
    SoilFertilityManager.saveSoilData(W.mgr, mi)
    if LEDGER.present and LEDGER.spec ~= nil then LEDGER.saved = LEDGER.spec.serialize() end
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

-- ── Reading what is on the disk ─────────────────────────────────────────────
local function headerIn(dir)
    local d = DISK[dir .. "/soilData.xml"]
    if d == nil or d[HK .. "#schema"] == nil then return nil end
    local files = {}
    for i = 1, (d[HK .. ".images#count"] or 0) do files[i] = tostring(d[string.format("%s.images.image(%d)#file", HK, i - 1)]) end
    return { schema = d[HK .. "#schema"], status = d[HK .. "#status"], attemptId = d[HK .. "#attemptId"], fingerprint = d[HK .. "#geometryFingerprint"],
             payloadFile = d[HK .. "#payloadFile"], reason = d[HK .. "#reason"], original = d[HK .. "#originalAttemptId"], files = table.concat(files, ",") }
end
local function headerText(dir)
    local h = headerIn(dir)
    if h == nil then return "none" end
    return table.concat({ tostring(h.schema), tostring(h.status), tostring(h.attemptId), tostring(h.payloadFile), tostring(h.reason), tostring(h.original) }, "/")
end
local function payloadOf(dir) return DISK[dir .. "/" .. CS.PAYLOAD_FILE] end
local function markerText(dir)
    local p = payloadOf(dir)
    if p == nil then return "none" end
    return tostring(p["soilDisease#attemptId"]) .. ":" .. tostring(p["soilDisease#completeAttemptId"])
end
local function decision()
    local m = W.model
    return tostring(m.restoreState) .. (m.quarantineReason and (":" .. m.quarantineReason) or "")
end

-- ── The cells (the one hand-populated fixture, as the 1a bench's) ──
local WHEAT = SoilDiseaseSystem.cropDiseases("wheat")
local X = WHEAT[1]
local function put(gx, gz, fields)
    local c = G.baselineCell(W.model.geometry.fingerprint)
    for k, v in pairs(fields or {}) do c[k] = v end
    local ok, why = W.model.store:put(gx, gz, c)
    if not ok then error("put " .. tostring(why)) end
end
--- Three cells that use every schema-1 field between them.
local function standardCells()
    put(2, 3, { cropName = "wheat", diseaseName = X, pressure = 40, resistance = { AZOLE = 0.3, STROBI = 0.1 }, protection = { AZOLE = 105 },
                discovered = true, cropOccurrence = "occ:1", lastResetOccurrence = "occ:1", cropHistory = { { occurrenceId = "occ:0", cropName = "barley" } },
                hybridCooldownExpiryDay = 90, dryDayCount = 2, sourceRevision = 5, lastSettledDay = 99,
                dailyTreatment = { day = 99, doseByMode = { AZOLE = 1.5 }, reduction = 3, operationIds = { "op:a", "op:b" } },
                nativeCropWitness = { basis = "OBSERVED_CURRENT_CROP", plane = 1, mixed = false } })
    put(3, 3, { cropName = "wheat", pressure = 12.345678901234567, sourceRevision = 1 })
    put(9, 12, { pressure = 0, sourceRevision = 0 })
    W.model.occurrenceSeq = 7
end
--- Every record, canonically: the store's order, each field and nested map sorted.
local function canon(v)
    if type(v) ~= "table" then return type(v) == "number" and string.format("%.17g", v) or tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. canon(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function dump(m)
    local out = {}
    for _, e in ipairs(m.store:orderedCells()) do out[#out + 1] = e.gx .. ":" .. e.gz .. canon(m.store:get(e.gx, e.gz)) end
    return table.concat(out, ";")
end
--- A new career, first activation, the grid bound by the day it captures, the standard cells.
local function career(dir, opts)
    world(dir, opts)
    loadAndStart()
    W.model:onDayChanged()
    standardCells()
end
local function taskCount()
    local n = 0
    for _, t in ipairs(controller.saveTasks or {}) do if t.type == SavegameController.SAVE_TASK_DENSITY_MAP then n = n + 1 end end
    return n
end
local FILES = "densityMap_fruits.gdm,densityMap_grass.gdm,densityMap_grassHaulm.gdm"

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY BAR: A SAVE AND ITS RELOAD
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetDisk()
    LEDGER.present = false
    world("e_career", { index = 2 })
    T.eq("E1 [entry point] main.lua's install: Soil's own boundary carries both participants, and the model is held RESTORING",
        tostring(W.boundary and W.boundary.mode) .. "/" .. tostring(W.boundary.participants[CS.PARTICIPANT_ID] == W.part.spec) .. "/"
            .. tostring(W.boundary.participants[GS.PARTICIPANT_ID] == W.condition.spec) .. "/" .. tostring(W.model.restoreState),
        "OWN/true/true/RESTORING")
    W.model:onDayChanged()
    T.eq("E2 a day before the restore decides does no work", tostring(W.model.lastDay) .. "/" .. #W.model.queue, "nil/0")
    loadAndStart()
    T.eq("E3 [entry point] a new career: the barrier passed, loadSoilData found no save: the clean first activation",
        W.barrierCalls .. "/" .. decision() .. "/" .. tostring(W.part.headerSource) .. "/" .. tostring(W.model.baseline), "1/FIRST_ACTIVATION/NONE/CLEAN_FIRST_ACTIVATION")
    W.model:onDayChanged()
    standardCells()
    local before = dump(W.model)
    local moved = 0
    nativeSave("e_final", false, function(frame) for _, m in pairs(ENGINE_MAPS) do m.version = 1 + frame end moved = frame end)
    local h = headerIn("e_final")
    T.eq("E4 [entry point] soilData.xml in the FINAL directory carries the SAVED header of attempt 1, the live fingerprint and the three distinct fruit and haulm files",
        tostring(h and h.schema) .. "/" .. tostring(h and h.status) .. "/" .. tostring(h and h.attemptId) .. "/" .. tostring(h and h.fingerprint == W.model.geometry.fingerprint)
            .. "/" .. tostring(h and h.payloadFile) .. "/" .. tostring(h and h.files),
        "1/SAVED/1/true/soilDisease.xml/" .. FILES)
    T.eq("E5 the payload is in the final directory with the completion of attempt 1; nothing is left in staging",
        markerText("e_final") .. "/" .. tostring(DISK["staging2/" .. CS.PAYLOAD_FILE]), "1:1/nil")
    T.eq("E6 the participant froze READY; each distinct image (its three files and the height map) was prepared once at the freeze; the controller still queued its own four density tasks",
        tostring(W.boundary.lastAttempt.results[CS.PARTICIPANT_ID].state) .. "/" .. #ENGINE_PREPARE_LOG .. "/" .. taskCount(), "READY/4/4")
    T.eq("E6b the world moved on for " .. moved .. " frames and each image in the final directory is the freeze's (version 1)",
        tostring(moved > 1) .. "/" .. tostring(DISK["e_final/densityMap_fruits.gdm"].version) .. tostring(DISK["e_final/densityMap_grass.gdm"].version) .. tostring(DISK["e_final/densityMap_grassHaulm.gdm"].version), "true/111")
    world("e_final", { valid = true, index = 2 })
    loadAndStart()
    T.eq("E7 [entry point] the reload restores attempt 1: every cell equal, the occurrence sequence back, nothing minted",
        decision() .. "/" .. tostring(dump(W.model) == before) .. "/" .. W.model.occurrenceSeq .. "/" .. W.model.store.count, "RESTORED/true/7/3")
    T.eq("E8 the header came from soilData.xml (no StateLedger); history is the restored attempt's", tostring(W.part.headerSource) .. "/" .. tostring(W.model.baseline), "XML/RESTORED_ATTEMPT")
    nativeSave("e_final2")
    T.eq("E9 the next attempt continues past the loaded one, and saves again", tostring(headerIn("e_final2") and headerIn("e_final2").attemptId) .. "/" .. markerText("e_final2"), "2/2:2")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. A BLOCKING SAVE
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    resetDisk()
    career("b_career", { index = 3 })
    local before = dump(W.model)
    nativeSave("b_final", true)
    T.eq("B1 a blocking save prepares nothing; the direct writes follow; header and completion as before",
        #ENGINE_PREPARE_LOG .. "/" .. #ENGINE_DIRECT_LOG .. "/" .. headerText("b_final") .. "/" .. markerText("b_final"), "0/4/1/SAVED/1/soilDisease.xml/nil/nil/1:1")
    world("b_final", { valid = true, index = 3 })
    loadAndStart()
    T.eq("B2 and it restores", decision() .. "/" .. tostring(dump(W.model) == before), "RESTORED/true")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- Q. QUARANTINE
-- ══════════════════════════════════════════════════════════════════════════
local function goodSave(dir, final, index)
    resetDisk()
    career(dir, { index = index })
    nativeSave(final)
end
--- Reload `final`: the decision, the cells, the occurrence sequence, and whether a day works.
local function reloadQ(final, index, opts)
    opts = opts or {}
    world(final, { valid = true, index = index, terrain = opts.terrain })
    loadAndStart()
    W.model:onDayChanged()
    return decision() .. "/" .. W.model.store.count .. "/" .. W.model.occurrenceSeq .. "/" .. tostring(W.model.lastDay)
end
group("Q", function()
    goodSave("q1", "q1f", 10)
    payloadOf("q1f")["soilDisease#completeAttemptId"] = nil
    T.eq("Q1 NAMED: the completion missing: QUARANTINED, nothing restored or minted, no day work", reloadQ("q1f", 10), "QUARANTINED:PAYLOAD:NOT_COMPLETE/0/0/nil")
    goodSave("q2", "q2f", 11)
    DISK["q2f/" .. CS.PAYLOAD_FILE] = nil
    T.eq("Q2 NAMED: the payload missing", reloadQ("q2f", 11), "QUARANTINED:PAYLOAD_MISSING/0/0/nil")
    goodSave("q3", "q3f", 12)
    for k in pairs(DISK["q3f/soilData.xml"]) do if k:sub(1, #HK) == HK then DISK["q3f/soilData.xml"][k] = nil end end
    T.eq("Q3 NAMED: a payload with no header (an orphan)", reloadQ("q3f", 12), "QUARANTINED:ORPHAN_PAYLOAD/0/0/nil")
    goodSave("q4", "q4f", 13)
    payloadOf("q4f")["soilDisease#attemptId"] = 5
    T.eq("Q4 NAMED: the payload of another attempt", reloadQ("q4f", 13), "QUARANTINED:PAYLOAD:ATTEMPT_MISMATCH/0/0/nil")
    goodSave("q5", "q5f", 14)
    T.eq("Q5 NAMED: conflicting geometry (another terrain)", reloadQ("q5f", 14, { terrain = 128 }), "QUARANTINED:GEOMETRY_MISMATCH/0/0/nil")
    goodSave("q6", "q6f", 15)
    payloadOf("q6f")["soilDisease.tiles.tile(0).cell(1)#key"] = payloadOf("q6f")["soilDisease.tiles.tile(0).cell(0)#key"]
    T.eq("Q6 NAMED: a duplicate row (two cells under one key)", reloadQ("q6f", 15), "QUARANTINED:PAYLOAD:KEY_ORDER/0/0/nil")
    goodSave("q7", "q7f", 16)
    payloadOf("q7f")["soilDisease.tiles#count"] = 2
    T.eq("Q7 NAMED: a bad count", reloadQ("q7f", 16), "QUARANTINED:PAYLOAD:COUNT:soilDisease.tiles#count/0/0/nil")
    goodSave("q8", "q8f", 17)
    payloadOf("q8f")["soilDisease.tiles.tile(0).cell(1)#pressure"] = "1e999"
    T.eq("Q8 NAMED: a non-finite value", reloadQ("q8f", 17), "QUARANTINED:PAYLOAD:NUMBER:soilDisease.tiles.tile(0).cell(1)#pressure/0/0/nil")
    goodSave("q9", "q9f", 18)
    DISK["q9f/soilData.xml"][HK .. "#status"] = "BOGUS"
    T.eq("Q9 a present but invalid header", reloadQ("q9f", 18), "QUARANTINED:HEADER_INVALID:STATUS:BOGUS/0/0/nil")
    goodSave("q10", "q10f", 19)
    DISK["q10f/soilData.xml"][HK .. "#schema"] = 2
    T.eq("Q10 a header of another schema", reloadQ("q10f", 19), "QUARANTINED:HEADER_INVALID:SCHEMA:2/0/0/nil")
    -- A quarantined session saves the quarantine, and the next load keeps it.
    goodSave("q11", "q11f", 20)
    DISK["q11f/" .. CS.PAYLOAD_FILE] = nil
    reloadQ("q11f", 20)
    nativeSave("q11g")
    T.eq("Q11 NAMED: a quarantined session writes a QUARANTINED header with its reason and the original attempt, no payload, and claims no image",
        headerText("q11g") .. "/" .. markerText("q11g") .. "/" .. tostring(W.boundary.lastAttempt.results[CS.PARTICIPANT_ID].reason),
        "1/QUARANTINED/nil/nil/PAYLOAD_MISSING/1/none/QUARANTINED")
    T.eq("Q12 NAMED: and the next load stays quarantined", reloadQ("q11g", 20), "QUARANTINED:CARRIED:PAYLOAD_MISSING/0/0/nil")
    nativeSave("q11h")
    T.eq("Q13 a carried quarantine keeps its first reason", headerText("q11h"), "1/QUARANTINED/nil/nil/PAYLOAD_MISSING/1")
    -- A session quarantined with no earlier evidence on disk (the restore decision itself raised on
    -- a new career, tryRestore's RESTORE_ERROR) still saves its quarantine: with nothing loaded, only
    -- the model's QUARANTINED state says so, and the next load must not take a clean first activation.
    resetDisk()
    world("q14", { index = 21 })
    W.model.firstActivation = function() error("bench: the restore decision raised") end
    loadAndStart()
    local decided = decision()
    W.model.firstActivation = nil
    nativeSave("q14f")
    T.eq("Q14 NAMED: a session quarantined with no earlier evidence saves a QUARANTINED header with its reason, and no payload",
        decided .. "|" .. headerText("q14f") .. "/" .. markerText("q14f"), "QUARANTINED:RESTORE_ERROR|1/QUARANTINED/nil/nil/RESTORE_ERROR/nil/none")
    T.eq("Q15 NAMED: and the next load stays quarantined, not a clean first activation", reloadQ("q14f", 21), "QUARANTINED:CARRIED:RESTORE_ERROR/0/0/nil")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. DAY WORK: A SAVE MID-SETTLE AND MID-SPREAD FINISHES THE DAY EXACTLY ONCE
-- ══════════════════════════════════════════════════════════════════════════
--- Two active sources with living wheat neighbours, on a wet day (spread admitted).
local function spreadCells()
    put(5, 5, { cropName = "wheat", diseaseName = X, pressure = 50, resistance = { AZOLE = 0.4 } })
    put(6, 5, { cropName = "wheat", pressure = 0 })
    put(5, 6, { cropName = "wheat", pressure = 0 })
    put(10, 10, { cropName = "wheat", diseaseName = X, pressure = 60, resistance = { STROBI = 0.2 } })
    put(10, 11, { cropName = "wheat", pressure = 5 })
    put(11, 10, { cropName = "wheat", pressure = 0 })
end
local function dayCareer(dir, index)
    resetDisk()
    W.rain = 1
    world(dir, { index = index })
    loadAndStart()
    W.model:onDayChanged()        -- binds the grid and captures day 100
    spreadCells()
end
local function finish() local n = 0 while #W.model.queue > 0 and n < 100 do W.model:update(16) n = n + 1 end end
group("D", function()
    dayCareer("d_ref", 30)
    finish()
    local reference = dump(W.model) .. "|" .. tostring(W.model.lastClosedDay)
    T.ok("D0 [world] the uninterrupted day settled and spread (a clean neighbour took the identity)", W.model.store:get(6, 5).diseaseName == X)
    -- Mid-settle: two cells settled, then the save.
    dayCareer("d_set", 31)
    local bound = M.WORK_BOUND
    M.WORK_BOUND = 2
    W.model:update(16)
    M.WORK_BOUND = bound
    local phase = W.model.queue[1] and W.model.queue[1].phase
    nativeSave("d_setf")
    world("d_setf", { valid = true, index = 31 })
    loadAndStart()
    T.eq("D1 a save mid-settle restores its day: the SETTLE phase and the captured input", phase .. "/" .. decision() .. "/" .. tostring(W.model.queue[1] and W.model.queue[1].phase) .. "/" .. tostring(W.model.queue[1] and W.model.queue[1].input.day), "SETTLE/RESTORED/SETTLE/100")
    finish()
    T.eq("D2 NAMED: and finishes it exactly once: equal to the uninterrupted day", tostring(dump(W.model) .. "|" .. tostring(W.model.lastClosedDay) == reference), "true")
    -- Mid-spread: every cell settled and one of the two sources spread, then the save.
    dayCareer("d_spr", 32)
    M.WORK_BOUND = W.model.store.count + 1
    W.model:update(16)
    M.WORK_BOUND = bound
    local w = W.model.queue[1]
    local mid = tostring(w and w.phase) .. "/" .. tostring(w and w.scursor) .. "/" .. tostring(w and #w.sources)
    nativeSave("d_sprf")
    world("d_sprf", { valid = true, index = 32 })
    loadAndStart()
    local r = W.model.queue[1]
    T.eq("D3 a save mid-spread restores the source snapshot and its cursor", mid .. " " .. tostring(r and r.phase) .. "/" .. tostring(r and r.scursor) .. "/" .. tostring(r and #r.sources), "SPREAD/2/2 SPREAD/2/2")
    finish()
    T.eq("D4 NAMED: and finishes the day exactly once: equal to the uninterrupted day", tostring(dump(W.model) .. "|" .. tostring(W.model.lastClosedDay) == reference), "true")
    W.rain = 0
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE BACKENDS
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    resetDisk()
    LEDGER.present, LEDGER.saved, LEDGER.deliver = true, nil, nil
    career("l_career", { index = 40 })
    local before = dump(W.model)
    nativeSave("l_final")
    local led = LEDGER.saved and LEDGER.saved.extensions and LEDGER.saved.extensions.cd15Disease or nil
    T.eq("L1 with StateLedger, its block carries the same header as soilData.xml, and no cell",
        tostring(led and led.status) .. "/" .. tostring(led and led.attemptId) .. "/" .. tostring(led and table.concat(led.images, ",")) .. "/" .. tostring(led and led.cells) .. "/" .. headerText("l_final"),
        "SAVED/1/" .. FILES .. "/nil/1/SAVED/1/soilDisease.xml/nil/nil")
    LEDGER.deliver = LEDGER.saved
    world("l_final", { valid = true, index = 40 })
    loadAndStart()
    T.eq("L2 NAMED: present, the header is read from the ledger block, and the save restores", tostring(W.part.headerSource) .. "/" .. decision() .. "/" .. tostring(dump(W.model) == before), "LEDGER/RESTORED/true")
    LEDGER.deliver = nil
    world("l_final", { valid = true, index = 40 })
    loadAndStart()
    T.eq("L3 NAMED: present but empty on its first load: soilData.xml is imported", tostring(W.part.headerSource) .. "/" .. decision(), "XML/RESTORED")
    -- The ledger's header governs when it is the load source, even against soilData.xml.
    LEDGER.deliver = { soil = LEDGER.saved.soil, extensions = { cd15Disease = { schema = 1, status = "QUARANTINED", reason = "BENCH", originalAttemptId = 1 } } }
    world("l_final", { valid = true, index = 40 })
    loadAndStart()
    T.eq("L4 the selected backend is the ledger: its QUARANTINED header governs", decision(), "QUARANTINED:CARRIED:BENCH")
    LEDGER.present, LEDGER.saved, LEDGER.deliver = false, nil, nil
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A SECOND CLAIM ON AN IMAGE
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetDisk()
    career("c_career", { index = 50 })
    local claimant = { finished = nil }
    claimant.spec = {
        beginAttempt = function() end,
        freezeAfterCareerXML = function() return { state = "READY", payloadFile = "bench.xml", images = { { mapId = 3, nativeFilename = "densityMap_grass.gdm" } } } end,
        finishAttempt = function(_ctx, errorCode) claimant.finished = errorCode end,
    }
    W.boundary:register("benchClaimant", claimant.spec)
    nativeSave("c_final")
    local res = W.boundary.lastAttempt.results
    T.eq("C1 NAMED: a second claim on one image invalidates CD-15 and the claimant (DUPLICATE_MAP_PATH); the native save completes; CD-15 writes no completion",
        tostring(res[CS.PARTICIPANT_ID].reason) .. "/" .. tostring(res.benchClaimant.reason) .. "/" .. tostring(controller.completed[#controller.completed]) .. "/" .. markerText("c_final"),
        "DUPLICATE_MAP_PATH/DUPLICATE_MAP_PATH/0/1:nil")
    T.eq("C2 and the reload is quarantined, not restored", reloadQ("c_final", 50), "QUARANTINED:PAYLOAD:NOT_COMPLETE/0/0/nil")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- F. A FAILED SAVE; NO SAVE ON MISSION DELETE
-- ══════════════════════════════════════════════════════════════════════════
group("F", function()
    resetDisk()
    career("f_career", { index = 60 })
    ENGINE_SAVE.finishError, ENGINE_SAVE.errorAfterMove = Savegame.ERROR_WRITE, true
    nativeSave("f_final")
    ENGINE_SAVE.finishError, ENGINE_SAVE.errorAfterMove = nil, false
    T.eq("F1 NAMED: a save that failed at finish (the files moved anyway) writes no completion", markerText("f_final") .. "/" .. tostring(W.part.lastFinish.reason), "1:nil/SAVE_FAILED:7")
    T.eq("F2 and its reload is quarantined", reloadQ("f_final", 60), "QUARANTINED:PAYLOAD:NOT_COMPLETE/0/0/nil")
    resetDisk()
    career("f_career3", { index = 61 })
    ENGINE_SAVE.finalDir = "f_final3"
    REAL.ENGINE_CAREER_HOOK = careerHook
    controller:saveSavegame(g_currentMission.missionInfo, false)   -- the frames never run: the mission is deleted
    REAL.ENGINE_CAREER_HOOK = nil
    local part = W.part
    unload()
    g_asyncTaskManager.tasks = {}
    T.eq("F3 NAMED: a mission deleted mid-save: the attempt finishes without a completion, and nothing reaches a final directory",
        tostring(part.lastFinish and part.lastFinish.reason) .. "/" .. markerText("f_final3") .. "/" .. tostring(DISK["staging61/" .. CS.PAYLOAD_FILE] ~= nil and DISK["staging61/" .. CS.PAYLOAD_FILE]["soilDisease#completeAttemptId"]),
        "SAVE_FAILED:UNLOAD/none/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. OUT-OF-BAND SAVES; W. A SAVE BEFORE THE RESTORE DECIDED
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    goodSave("o_career", "o_final", 70)
    world("o_final", { valid = true, index = 70 })
    loadAndStart()
    g_currentMission.missionInfo.savegameDirectory = "o_final"
    SoilFertilityManager.saveSoilData(W.mgr, g_currentMission.missionInfo)
    T.eq("O1 NAMED: an out-of-band saveSoilData rewrites soilData.xml with the header that describes the disk (attempt 1, SAVED)", headerText("o_final"), "1/SAVED/1/soilDisease.xml/nil/nil")
    T.eq("O2 so the save still restores", reloadQ("o_final", 70), "RESTORED/3/7/100")
    unload()
end)
group("W", function()
    goodSave("w_career", "w_final", 80)
    world("w_final", { valid = true, index = 80 })   -- installed; loadSoilData never runs (the mod disabled at start)
    nativeSave("w_final2")
    T.eq("W1 NAMED: a save before the restore decided keeps the evidence: a QUARANTINED header (NOT_RESTORED, the original attempt), no payload",
        headerText("w_final2") .. "/" .. markerText("w_final2"), "1/QUARANTINED/nil/nil/NOT_RESTORED/1/none")
    resetDisk()
    world("w_new", { index = 81 })
    nativeSave("w_new2")
    T.eq("W2 a new career that never decided writes no header (nothing of it is CD-15 evidence)", headerText("w_new2") .. "/" .. markerText("w_new2"), "none/none")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- J. JOINED TO STOCKGUARD (GC-6's stub boundary, which calls the participants as SG-2 :818-830 says)
-- ══════════════════════════════════════════════════════════════════════════
local function stockGuardStub()
    local sg = { registered = {}, nextAttempt = 100, sg2 = { state = "READY" } }
    sg.getCapabilities = function() return { nativeMaterialSave = 1 } end
    sg.registerNativeSaveParticipant = function(id, spec) sg.registered[id] = spec return true end
    sg.unregisterNativeSaveParticipant = function(id, spec) if sg.registered[id] == spec then sg.registered[id] = nil return true end return false, "NOT_OWNER" end
    function sg.save(final)
        sg.nextAttempt = sg.nextAttempt + 1
        -- StockGuard's attempt context carries the career save and its staging directory
        -- (SGNativeMaterialSave.lua:213-218 at development 2709bc2); the save sets the directory.
        local ctx = { attemptId = sg.nextAttempt, ownBoundary = false, mission = g_currentMission, results = {},
                      careerSave = g_currentMission.missionInfo }
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
    local sg = stockGuardStub()
    world("j_career", { index = 90, stockGuard = sg })
    T.eq("J1 StockGuard owns the boundary: CD-15 is registered there, Soil installs no wrapper",
        tostring(W.boundary.mode) .. "/" .. tostring(sg.registered[CS.PARTICIPANT_ID] == W.part.spec) .. "/" .. tostring(SavegameController.onSaveStartComplete == MODEL_START), "JOINED/true/true")
    loadAndStart()
    W.model:onDayChanged()
    standardCells()
    local ctx = sg.save("j_final")
    local r = ctx.results[CS.PARTICIPANT_ID]
    local names = {}
    for i, img in ipairs(r.images or {}) do names[i] = img.nativeFilename end
    T.eq("J2 NAMED: joined, CD-15 still names its own images (unlike ground condition), under StockGuard's attempt id",
        tostring(r.state) .. "/" .. table.concat(names, ",") .. "/" .. headerText("j_final") .. "/" .. markerText("j_final"),
        "READY/" .. FILES .. "/1/SAVED/101/soilDisease.xml/nil/nil/101:101")
    unload()
    T.eq("J3 the teardown removes CD-15 from StockGuard by identity", tostring(sg.registered[CS.PARTICIPANT_ID]), "nil")
end)
end
CD15_1B_BENCH()
