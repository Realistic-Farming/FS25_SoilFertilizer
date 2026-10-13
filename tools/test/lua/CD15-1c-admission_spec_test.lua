-- CD15-1c-admission_spec_test.lua
--
-- CD-15 step 1c (Bob's intakes BOB-INTAKE-CD15-1B-1C-2026-10-05 Part 2 and BOB-INTAKE-CD15-1C-2026-10-06):
-- candidate discovery and admission, behind the profile gate (brief v1.14 :99-103, :220-222, :239-243),
-- and #1062's MINOR 2 (onset reads the cell's wetness) and MINOR 3 (spread through membership).
--
-- THE ENTRY-POINT BAR IS GROUP E: the 1b bench's production order (main.lua's loadedMission install,
-- GroundConditionSave's then CD15Save.installForMission; the mission's own onFinishedLoading as the
-- barrier; the real SoilFertilityManager.loadSoilData; a native save as the engine runs it and its
-- reload through the same install), with NO supported native profile, as production has: discovery runs
-- from the saved cursor over a real field polygon, every witness answers UNKNOWN_OCCURRENCE before any
-- pixel read (zero counted), nothing is admitted, the status names the reason, and the cursor survives a
-- 1b save and reload.
--
-- The rest runs under a bench-only profile, the procedure whole: FruitTypeDesc's state vocabulary
-- transcribed onto the GC-6 world's descriptors (WHEAT and BARLEY share plane 1, the default; GRASS and a
-- POTATO are on plane 3 with a haulm on plane 4); per-pixel planes sized so a fine cell's edge cuts
-- through a native pixel (plane 3 is 40 px over the 64 m terrain); fields as FieldManager hands them
-- out, polygon nodes read with getWorldTranslation. The hand-populated fixtures are a retained history
-- row (A), the MINOR rows' cells (M) and the reach of the read budget (R): no writer allocates them
-- before step 2.
--
-- Groups:
--   E  the entry bar: production, no profile
--   H  the hold: RESTORING, QUARANTINED, a seam that threw
--   C  classification: the vocabulary, every plane, every overlapping pixel
--   R  the profile's read budget
--   A  admission: the token, the basis, today, nothing more; a second pass; a 1b save and reload
--   B  at most 256 cells per update
--   G  a changed geometry invalidates membership
--   M  MINOR 2 and MINOR 3
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/GC-6-savegame_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/DiseaseSystem.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/SoilNativeSave.lua, src/ground/GroundConditionSave.lua
--!text: src/disease/CD15Grid.lua, src/disease/CD15Day.lua, src/disease/CD15Model.lua, src/disease/CD15Save.lua, src/disease/CD15Admission.lua, src/integrations/SoilStateLedgerBridge.lua, src/SoilFertilityManager.lua

-- The last six sources (--!text, in main.lua's order) run here as their own chunks, in this
-- bench's mod environment, as the engine runs every sourced file. Pasted into the one
-- concatenated chunk, their file-level locals with the earlier sources' passed Lua's
-- 200-local limit for a single function (216), and the bench runs inside one function for the
-- same reason.
for _, path in ipairs({ "src/disease/CD15Grid.lua", "src/disease/CD15Day.lua", "src/disease/CD15Model.lua", "src/disease/CD15Save.lua", "src/disease/CD15Admission.lua", "src/integrations/SoilStateLedgerBridge.lua", "src/SoilFertilityManager.lua" }) do
    assert(load(SOURCE_TEXT[path], "=" .. path, "t", _ENV))()
end

local function CD15_1C_BENCH()
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
-- 1c's engine: the fruit descriptors and their states, the planes' pixels, the fields
-- ══════════════════════════════════════════════════════════════════════════
local A = CD15Admission
-- FruitTypeDesc.lua:685-713 and :794-799 VERBATIM, the vocabulary 1c classifies by; the fields they
-- read as loadFromFoliageXMLFile leaves them (:150-155 the preparing defaults, :228-240 the cut and
-- withered flags). bit32's band and rshift are written as their arithmetic for a non-negative word.
local FTD = {}
FTD.__index = FTD
function FTD:getIsHarvestable(growthState) return self.harvestTransitions[growthState] ~= nil end
function FTD:getIsHarvestReady(growthState) return self.harvestReadyTransitions[growthState] ~= nil end
function FTD:getIsCut(growthState) return self.cutStates[growthState] ~= nil end
function FTD:getIsGrowing(growthState)
    local maxGrowingState = self.minHarvestingGrowthState - 1
    if self.minPreparingGrowthState >= 0 then
        maxGrowingState = math.min(maxGrowingState, self.minPreparingGrowthState - 1)
    end
    return growthState > 0 and growthState <= maxGrowingState
end
function FTD:getIsPreparable(growthState) return self.minPreparingGrowthState <= growthState and growthState <= self.maxPreparingGrowthState end
function FTD:getIsWithered(growthState) return self.witheredState ~= nil and self.witheredState == growthState end
function FTD:getGrowthStateByDensityState(state)
    if state == nil then return nil end
    return math.floor(state / 2 ^ self.startStateChannel) % 2 ^ self.numStateChannels
end
--- One descriptor: growing below minHarvest; harvest-ready (and harvestable) at `ready`; cut at
--- `cut`; withered at `withered`; preparable in [prepMin, prepMax]; prepared at `prepared`; the
--- disaster's destroyed state at `destroyed`.
local function vocab(desc, v)
    desc.startStateChannel, desc.numStateChannels = 0, 4
    desc.minHarvestingGrowthState = v.minHarvest
    desc.harvestTransitions, desc.harvestReadyTransitions = {}, {}
    if v.ready ~= nil then desc.harvestTransitions[v.ready], desc.harvestReadyTransitions[v.ready] = v.cut, v.cut end
    desc.cutStates = {}
    if v.cut ~= nil then desc.cutStates[v.cut] = true end
    desc.witheredState = v.withered
    desc.minPreparingGrowthState, desc.maxPreparingGrowthState = v.prepMin or -1, v.prepMax or -1
    desc.preparedGrowthState = v.prepared or -1
    desc.disasterDestructionState = v.destroyed or 0
    return setmetatable(desc, FTD)
end
local DESC = {}
for _, d in ipairs(ENGINE_FRUIT_DESCS) do DESC[d.name] = d end
-- WHEAT and BARLEY share plane 1 (the default plane); GRASS is on plane 3 with its haulm on 4; a
-- POTATO joins plane 3 (a preparable crop on a non-default plane).
vocab(DESC.WHEAT, { minHarvest = 5, ready = 5, cut = 6, withered = 7, destroyed = 8 })
vocab(DESC.BARLEY, { minHarvest = 5, ready = 5, cut = 6, withered = 7, destroyed = 8 })
vocab(DESC.GRASS, { minHarvest = 4, ready = 4, cut = 5 })
DESC.POTATO = vocab({ index = 30, name = "POTATO", terrainDataPlaneId = 3, terrainDataPlaneIdHaulm = 4 },
    { minHarvest = 6, ready = 6, cut = 7, prepMin = 4, prepMax = 4, prepared = 5 })
ENGINE_FRUIT_DESCS[#ENGINE_FRUIT_DESCS + 1] = DESC.POTATO
-- FruitTypeManager.lua:488-491: the density type index to its descriptor.
local TYPE = { [1] = DESC.WHEAT, [2] = DESC.BARLEY, [20] = DESC.GRASS, [30] = DESC.POTATO }
g_fruitTypeManager.getFruitTypeByDensityTypeIndex = function(_, i) return TYPE[i] end

-- The planes' sizes: plane 1 (the default) is 64 px over the 64 m terrain (1 m pixels, aligned with
-- the 4 m cells); planes 3 and 4 are 40 px (1.6 m), so a cell's edge cuts through a pixel.
local SIZES = { [1] = 64, [3] = 40, [4] = 40 }
REAL.getDensityMapSize = function(id) return SIZES[id] end
-- The per-pixel reads (used live at FieldState.lua:97, :101): the pixel holding the world position,
-- its type index and its states word; an unpainted pixel is 0 and 0. Every read is counted.
local PIX, READS = {}, { n = 0 }
local function pixelOf(plane, x, z)
    local size = SIZES[plane]
    local px = ENGINE.TERRAIN / size
    return math.floor((x + ENGINE.TERRAIN / 2) / px), math.floor((z + ENGINE.TERRAIN / 2) / px)
end
REAL.getDensityTypeIndexAtWorldPos = function(plane, x, _y, z)
    READS.n = READS.n + 1
    local ix, iz = pixelOf(plane, x, z)
    local p = PIX[plane] and PIX[plane][ix .. ":" .. iz]
    return p and p.t or 0
end
REAL.getDensityStatesAtWorldPos = function(plane, x, _y, z)
    READS.n = READS.n + 1
    local ix, iz = pixelOf(plane, x, z)
    local p = PIX[plane] and PIX[plane][ix .. ":" .. iz]
    return p and p.s or 0
end
--- Paint every pixel of `plane` whose CENTRE lies in [x0, x1) x [z0, z1): a type index and a states word.
local function paint(plane, x0, z0, x1, z1, t, s)
    PIX[plane] = PIX[plane] or {}
    local size = SIZES[plane]
    local px = ENGINE.TERRAIN / size
    local half = ENGINE.TERRAIN / 2
    for ix = 0, size - 1 do
        local cx = -half + (ix + 0.5) * px
        if cx >= x0 and cx < x1 then
            for iz = 0, size - 1 do
                local cz = -half + (iz + 0.5) * px
                if cz >= z0 and cz < z1 then PIX[plane][ix .. ":" .. iz] = { t = t, s = s } end
            end
        end
    end
end
--- The world square of a fine cell (4 m).
local function cellRect(gx, gz)
    local half, size = ENGINE.TERRAIN / 2, ENGINE.TERRAIN / ENGINE.RESOLUTION
    return -half + gx * size, -half + gz * size, -half + (gx + 1) * size, -half + (gz + 1) * size
end
local function paintCell(plane, gx, gz, t, s)
    local x0, z0, x1, z1 = cellRect(gx, gz)
    paint(plane, x0, z0, x1, z1, t, s)
end

-- The fields: FieldManager:getFields (FieldManager.lua:394), Field:getId (:117) and
-- getPolygonPoints (Field.lua:167), whose points are scene nodes read with getWorldTranslation.
local FIELDS = {}
local function field(id, cells)
    local x0, z0 = cellRect(cells[1], cells[2])
    local _, _, x1, z1 = cellRect(cells[3], cells[4])
    local f = { id = id, nodes = { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } } }
    function f:getId() return self.id end
    function f:getPolygonPoints() return self.nodes end
    FIELDS[#FIELDS + 1] = f
    return f
end
--- A field whose polygon is the given world points.
local function fieldPoly(id, points)
    local f = { id = id, nodes = {} }
    for i, p in ipairs(points) do f.nodes[i] = { x = p[1], z = p[2] } end
    function f:getId() return self.id end
    function f:getPolygonPoints() return self.nodes end
    FIELDS[#FIELDS + 1] = f
    return f
end
REAL.g_fieldManager = { getFields = function() return FIELDS end }
function getWorldTranslation(node)
    if type(node) == "table" and node.x ~= nil then return node.x, 0, node.z end
    return 0, 0, 0
end
local BENCH_PROFILE = { id = "bench", maxReadsPerCell = 64 }
local function resetWorld1c(withProfile)
    PIX, READS.n, FIELDS = {}, 0, {}
    for i = #A.PROFILES, 1, -1 do A.PROFILES[i] = nil end
    if withProfile then A.PROFILES[1] = BENCH_PROFILE end
    A.stats.reads = 0
end
-- The states words (startStateChannel 0): the growth state itself.
local GROWING, READY, CUT, WITHERED, DESTROYED = 3, 5, 6, 7, 8
local P_PREPARABLE = 4
--- Run the model's server update `n` times (discovery takes what the day work leaves of 256).
local function updates(n) for _ = 1, n or 1 do W.model:update(16) end end
local function rowAt(gx, gz) return W.model.store:get(gx, gz) end
local function rowText(r)
    if r == nil then return "none" end
    local w = r.nativeCropWitness or {}
    return table.concat({ tostring(r.cropName), tostring(r.cropOccurrence), tostring(w.basis), tostring(r.lastSettledDay), tostring(r.lastResetOccurrence),
        tostring(#r.cropHistory), tostring(next(r.resistance) == nil) }, "|")
end
local function status() return W.model:getStatus().admission end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE ENTRY BAR: PRODUCTION, NO SUPPORTED PROFILE
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    resetDisk()
    resetWorld1c(false)
    LEDGER.present = false
    -- A field over the whole map and a second over a corner, growing wheat on every pixel of the
    -- default plane: a world discovery WOULD admit, had it a profile.
    field(7, { 0, 0, 15, 15 })
    field(8, { 0, 0, 3, 3 })
    paint(1, -32, -32, 32, 32, 1, GROWING)
    world("c1e_career", { index = 2 })
    updates(2)
    local held = W.model.discoveryCursor .. "/" .. status().examined
    loadAndStart()
    W.model:onDayChanged()
    updates(3)
    local s = status()
    T.eq("E1 NAMED [entry point]: main.lua's install, the barrier and the first activation; with no supported native profile, as production has, discovery returns before its walk: no candidate examined, no pixel read, nothing admitted, the cursor where it was, and the status names UNKNOWN_OCCURRENCE:NO_SUPPORTED_PROFILE",
        held .. "|" .. tostring(s.profile) .. "|" .. s.examined .. "/" .. s.reads .. "/" .. READS.n .. "/" .. s.admitted .. "/" .. W.model.store.count .. "|" .. tostring(s.reason) .. "|" .. W.model.discoveryCursor,
        "0/0|nil|0/0/0/0/0|UNKNOWN_OCCURRENCE:NO_SUPPORTED_PROFILE|0")
    nativeSave("c1e_final")
    world("c1e_final", { valid = true, index = 2 })
    loadAndStart()
    updates(2)
    T.eq("E2 NAMED [entry point]: through a real 1b save and reload (RESTORED) the cursor is unchanged, and still nothing is examined, read or admitted",
        decision() .. "|" .. W.model.discoveryCursor .. "|" .. status().examined .. "/" .. READS.n .. "/" .. W.model.store.count .. "|" .. tostring(status().reason),
        "RESTORED|0|0/0/0|UNKNOWN_OCCURRENCE:NO_SUPPORTED_PROFILE")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE HOLD: A HELD MODEL DISCOVERS AND ADMITS NOTHING, AND ITS CURSOR STAYS
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
    resetDisk()
    resetWorld1c(true)
    LEDGER.present = false
    field(7, { 0, 0, 3, 3 })
    paint(1, -32, -32, 32, 32, 1, GROWING)
    world("c1h", { index = 3 })
    W.model:ensureGeometry()
    updates(1)
    local restoring = W.model.discoveryCursor .. "/" .. W.model.store.count .. "/" .. READS.n
    loadAndStart()
    W.model:quarantine("BENCH")
    updates(1)
    local quarantined = W.model.discoveryCursor .. "/" .. W.model.store.count .. "/" .. READS.n
    world("c1h2", { index = 4 })
    loadAndStart()
    W.model:fail("bench", "threw")
    updates(1)
    local failed = W.model.discoveryCursor .. "/" .. W.model.store.count .. "/" .. READS.n
    T.eq("H1 NAMED: held RESTORING, QUARANTINED, or after a seam threw, the model discovers nothing, reads nothing and admits nothing, and its cursor does not move (with a profile and living crop present)",
        restoring .. "|" .. quarantined .. "|" .. failed, "0/0/0|0/0/0|0/0/0")
    world("c1h3", { index = 5 })
    loadAndStart()
    updates(1)
    T.eq("H2 [control] the same world unheld admits", tostring(W.model.store.count > 0), "true")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. CLASSIFICATION BY THE DESCRIPTOR'S VOCABULARY, EVERY PLANE, EVERY OVERLAPPING PIXEL
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    resetDisk()
    resetWorld1c(true)
    LEDGER.present = false
    field(7, { 1, 1, 12, 1 })
    paintCell(1, 1, 1, 1, GROWING)        -- wheat growing
    paintCell(1, 2, 1, 1, READY)          -- wheat harvest-ready: living, not getIsGrowing
    paintCell(1, 3, 1, 1, CUT)            -- cut
    -- Potato preparable, on plane 3 (not the default), at cell 4: its left edge (x = -16) is a plane-3
    -- pixel boundary, so none of its pixels overlaps cell 3 (a potato pixel there would make cell 3
    -- mixed, as the witness must).
    paintCell(3, 4, 1, 30, P_PREPARABLE)
    paintCell(1, 5, 1, 1, WITHERED)       -- withered
    paintCell(1, 6, 1, 1, DESTROYED)      -- the mapped destroyed state
    paintCell(1, 7, 1, 99, GROWING)       -- a type index no descriptor owns
    paintCell(1, 8, 1, 20, GROWING)       -- GRASS's type on plane 1: the plane association fails
    paintCell(4, 9, 1, 20, 2)             -- haulm only (plane 4): residue, not a crop
    local x0, z0, x1, z1 = cellRect(10, 1)
    paint(1, x0, z0, x0 + 2, z1, 1, GROWING)   -- wheat and barley in one cell
    paint(1, x0 + 2, z0, x1, z1, 2, GROWING)
    paintCell(1, 11, 1, 1, 9)             -- a wheat state outside its vocabulary (not growing, ready, cut, withered or destroyed)
    -- (12, 1): potato growing on plane 3, and one column of plane-3 pixels whose
    -- centres lie OUTSIDE the cell (x = 20.0, the cell is [16, 20)) but which overlap it, of a type no
    -- descriptor owns: a witness that reads only pixel centres inside the cell misses it.
    paintCell(3, 12, 1, 30, GROWING)
    local _, cz0, _, cz1 = cellRect(12, 1)
    paint(3, 20, cz0, 21, cz1, 99, GROWING)
    world("c1c", { index = 6 })
    loadAndStart()
    W.model:onDayChanged()
    updates(1)
    local out = {}
    for gx = 1, 12 do local r = rowAt(gx, 1) out[#out + 1] = r and r.cropName or "-" end
    local s = W.model.discovery.counts
    T.eq("C1 NAMED: growing and harvest-ready wheat, and preparable potato on the non-default plane, are living and admitted; cut, withered, destroyed and haulm-only are not; an unowned type, a plane mismatch, mixed crops, a state outside the vocabulary and a partial boundary pixel are UNKNOWN",
        table.concat(out, " ") .. "|" .. s.examined .. "/" .. s.living .. "/" .. s.notLiving .. "/" .. s.unknown,
        "wheat wheat - potato - - - - - - - -|12/3/4/5")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE CULTIVATED POLYGON, NOT ITS RECTANGLE
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    resetDisk()
    resetWorld1c(true)
    LEDGER.present = false
    -- A right triangle over cells 8..11 x 8..11 (its legs on the cells' low edges, its hypotenuse from
    -- (x 16, z 0) to (x 0, z 16)), with growing wheat on every pixel of its box.
    fieldPoly(7, { { 0, 0 }, { 16, 0 }, { 0, 16 } })
    paint(1, 0, 0, 16, 16, 1, GROWING)
    world("c1p", { index = 14 })
    loadAndStart()
    updates(1)
    local inside, outside = 0, 0
    for gx = 8, 11 do for gz = 8, 11 do
        if rowAt(gx, gz) ~= nil then
            if (gx - 8) + (gz - 8) <= 3 then inside = inside + 1 else outside = outside + 1 end
        end
    end end
    T.eq("P1 NAMED: candidates come from the polygon: of the triangle's 16-cell box, the 10 cells it covers are admitted and the 6 beyond its hypotenuse are not, though the same crop stands there",
        inside .. "/" .. outside .. "/" .. W.model.discovery.counts.examined, "10/0/10")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE PROFILE'S READ BUDGET IS A GATE, NOT A TARGET
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
    resetDisk()
    resetWorld1c(false)
    A.PROFILES[1] = { id = "tight", maxReadsPerCell = 10 }
    LEDGER.present = false
    field(7, { 1, 1, 1, 1 })
    paintCell(1, 1, 1, 1, GROWING)
    world("c1r", { index = 7 })
    loadAndStart()
    W.model:onDayChanged()
    updates(1)
    T.eq("R1 a cell whose pixels exceed the profile's recorded read budget is UNKNOWN before any read: nothing read, nothing admitted",
        READS.n .. "/" .. W.model.store.count .. "|" .. tostring(status().reason), "0/0|UNKNOWN_OCCURRENCE:READ_BUDGET")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. ADMISSION (:99-103)
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    resetDisk()
    resetWorld1c(true)
    LEDGER.present = false
    field(7, { 1, 1, 3, 1 })
    paintCell(1, 1, 1, 1, GROWING)
    paintCell(1, 2, 1, 1, GROWING)
    paintCell(1, 3, 1, 1, GROWING)
    world("c1a", { index = 8 })
    loadAndStart()
    W.model:ensureGeometry()
    -- A retained row (resistance and protection, no crop) where cell 3's wheat stands: the one hand-
    -- populated fixture here, as 1b's cells (no writer allocates a history row before step 2).
    put(3, 1, { resistance = { AZOLE = 0.4 }, protection = { AZOLE = 130 }, lastSettledDay = 95, sourceRevision = 2 })
    -- No day is queued: admission takes today from the clock (readDay), and the retained row is not
    -- settled first, so what admission keeps is visible.
    updates(1)
    local seq1 = W.model.occurrenceSeq
    T.eq("A1 NAMED: an admitted standing crop: its crop, a token from the sequence, basis OBSERVED_CURRENT_CROP, its cursor at today (100), no reset stamp, no history, resistance unchanged (none)",
        rowText(rowAt(1, 1)) .. " ; " .. rowText(rowAt(2, 1)), "wheat|occ:1|OBSERVED_CURRENT_CROP|100|nil|0|true ; wheat|occ:2|OBSERVED_CURRENT_CROP|100|nil|0|true")
    local r3 = rowAt(3, 1)
    T.eq("A2 a retained row is admitted in place: its resistance, protection and settle cursor kept, the crop and the next token added",
        tostring(r3.cropName) .. "|" .. tostring(r3.cropOccurrence) .. "|" .. tostring(r3.resistance.AZOLE) .. "/" .. tostring(r3.protection.AZOLE) .. "|" .. tostring(r3.lastSettledDay),
        "wheat|occ:3|0.4/130|95")
    updates(3)
    T.eq("A3 another pass over the same cells admits nothing new", seq1 .. "/" .. W.model.occurrenceSeq .. "/" .. W.model.store.count, "3/3/3")
    local before = dump(W.model)
    nativeSave("c1a_final")
    world("c1a_final", { valid = true, index = 8 })
    loadAndStart()
    local back = decision() .. "|" .. tostring(dump(W.model) == before) .. "|" .. W.model.occurrenceSeq
    paintCell(1, 4, 1, 1, GROWING)
    field(9, { 4, 1, 4, 1 })
    W.model:onDayChanged()
    updates(2)
    T.eq("A4 NAMED: every admitted row and its witness survive a 1b save and reload (every witness field encodes), the sequence comes back and nothing is minted at restore; a crop found after the reload takes the next token",
        back .. "|" .. rowText(rowAt(4, 1)), "RESTORED|true|3|wheat|occ:4|OBSERVED_CURRENT_CROP|100|nil|0|true")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. AT MOST 256 CELLS PER UPDATE, SHARED WITH THE DAY WORK
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    resetDisk()
    resetWorld1c(true)
    LEDGER.present = false
    field(7, { 0, 0, 15, 15 })
    field(8, { 0, 0, 3, 3 })
    world("c1b", { index = 9 })
    loadAndStart()
    W.model:onDayChanged()
    updates(1)
    local first = W.model.discoveryCursor .. "/" .. W.model.stats.maxWork
    nativeSave("c1b_final")
    world("c1b_final", { valid = true, index = 9 })
    loadAndStart()
    local back = decision() .. "/" .. W.model.discoveryCursor
    updates(1)
    T.eq("B1 NAMED: one update does at most 256 cells of work (the day's empty settle and discovery together); the cursor (256) survives a real 1b save and reload, and the next update resumes from it and ends the pass (the corner field's 16)",
        first .. "|" .. back .. "|" .. status().examined .. "/" .. W.model.discoveryCursor .. "/" .. W.model.stats.maxWork, "256/256|RESTORED/256|16/0/16")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. A CHANGED GEOMETRY INVALIDATES MEMBERSHIP
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    resetDisk()
    resetWorld1c(true)
    LEDGER.present = false
    field(7, { 1, 1, 2, 1 })
    paintCell(1, 1, 1, 1, GROWING)
    world("c1g", { index = 10 })
    loadAndStart()
    g_currentMission.environment.currentMonotonicDay = nil   -- no day: membership only, no admission
    W.model:ensureGeometry()
    updates(1)
    local d0 = W.model.discovery
    local had = d0 ~= nil and d0.member["1:1"] ~= nil
    W.vm.resolution = 32
    W.model.geometry = nil
    updates(1)
    local d1 = W.model.discovery
    T.eq("G1 a changed geometry rebuilds discovery: the old membership is gone, the new state is the new fingerprint's",
        tostring(had) .. "|" .. tostring(d1 ~= d0) .. "|" .. tostring(d1 ~= nil and d1.member["1:1"] == nil) .. "|" .. tostring(d1 ~= nil and d1.geometry == W.model.geometry.fingerprint),
        "true|true|true|true")
    unload()
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. #1062's MINOR 2 (ONSET READS THE CELL'S WETNESS) AND MINOR 3 (SPREAD THROUGH MEMBERSHIP)
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    resetDisk()
    resetWorld1c(false)
    LEDGER.present = false
    local seen = {}
    local realSelect = SoilDiseaseSystem.selectDisease
    SoilDiseaseSystem.selectDisease = function(cropName, season, isWet, isCool, seed)
        seen[#seen + 1] = tostring(isWet)
        return realSelect(cropName, season, isWet, isCool, seed)
    end
    local function onsetDay(dir, index, rain, moisture)
        world(dir, { index = index })
        loadAndStart()
        W.model:ensureGeometry()
        put(2, 2, { cropName = "wheat", pressure = 15, cropOccurrence = "occ:1", sourceRevision = 1 })
        W.rain = rain
        g_currentMission.cropStressManager = { getMoisture = function(_, _fid, _x, _z) return moisture, 1, 1 end }
        W.model:onDayChanged()
        updates(1)
        g_currentMission.cropStressManager = nil
    end
    onsetDay("c1m2a", 11, 0, 0.9)
    onsetDay("c1m2b", 12, 1, 0.1)
    SoilDiseaseSystem.selectDisease = realSelect
    W.rain = 0
    T.eq("M1 NAMED: onset on a dry-weather day with SCS moisture wet at the cell's grain selects as wet; on a wet day with SCS dry at the cell, as dry (the rain bonus and dry-day count stay on the weather)",
        table.concat(seen, ","), "true,false")

    -- MINOR 3. Two wheat cells (5,5) and (6,5) discovered while no day is readable: members, no rows.
    -- A diseased wheat source at (7,5). (8,5) stands in wheat but is in no field: never discovered.
    resetDisk()
    resetWorld1c(true)
    field(7, { 5, 5, 6, 5 })
    paintCell(1, 5, 5, 1, GROWING)
    paintCell(1, 6, 5, 1, GROWING)
    paintCell(1, 8, 5, 1, GROWING)
    world("c1m3", { index = 13 })
    loadAndStart()
    W.model:ensureGeometry()
    put(7, 5, { cropName = "wheat", diseaseName = X, pressure = 60, cropOccurrence = "occ:1", sourceRevision = 1, lastSettledDay = 99 })
    W.model.occurrenceSeq = 1
    g_currentMission.environment.currentMonotonicDay = nil
    updates(1)
    local members = tostring(W.model.discovery.member["6:5"] ~= nil) .. "/" .. tostring(rowAt(6, 5) == nil)
    g_currentMission.environment.currentMonotonicDay = 100
    W.rain = 1
    W.model:onDayChanged()
    W.model:update(16)
    W.rain = 0
    local d6, d8 = rowAt(6, 5), rowAt(8, 5)
    T.eq("M2 NAMED: spread reaches a discovered, unallocated living destination through membership (admitted at the day, the source's disease and 4 points), never an undiscovered one",
        members .. "|" .. tostring(d6 and d6.diseaseName == X) .. "/" .. tostring(d6 and d6.pressure) .. "/" .. tostring(d6 and d6.cropOccurrence) .. "/" .. tostring(d6 and d6.lastSettledDay)
            .. "|" .. tostring(d8),
        "true/true|true/4/occ:2/100|nil")
    unload()
end)
end
CD15_1C_BENCH()
