-- MAINT-137-overlay_save_index_stamp_spec_test.lua
--
-- MAINTENANCE row 137: the two RSF-F213 items that waited on F215's save hook.
--   1. The ground coordinator's availability overlay rides MaterialDown's envelope (one save
--      boundary, one generation, contract section 6). It comes back only when the store's
--      load decides MODERN; until the store decides, every cell reads unavailable (the
--      hold), and a restore merges over cells marked meanwhile.
--   2. The membership index is trusted at arm only when soilData.xml's stamp equals the
--      career marker's generation (section 5's epoch). The save writes the stamp only after
--      the membership, age and wetness layers all saved, and the marker carries its
--      generation whatever the store's backend did.
--
-- THE ENTRY-POINT BAR IS GROUP E. Production's system with the owners armed in production's
-- order and main.lua's bridges opening the load; the native save as it runs: the invocation
-- opened in front of FSCareerMissionInfo.saveToXMLFile, then Soil's hook
-- (SoilFertilityManager.saveSoilData: the real per-layer value-map save, the stamp, the
-- marker, the own file), then the career XML written to disk; the reload into a fresh system
-- whose coordinator reads the marker and the stamp off the disk at arm. The world supplies
-- the disk (a file table the XML calls read and write), the store's three layer files (a
-- store whose layers save through saveBitVectorMapToFile, which a row can make throw), and
-- one cell a native error marked unavailable.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/SoilFertilityManager.lua

-- The bench runs inside one function: the concatenated sources' file-level locals with this
-- file's would pass Lua's 200-local limit for a single function.
local function MAINT137_BENCH()
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local MDB = SoilMaterialDownBridge
local GCC = GroundConditionCoordinator

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── The disk and the engine's XML handle calls ──────────────────────────────
local DISK = {}
local FAIL_SAVE = {}            -- path -> true: saveXMLFile answers false for it
local FAIL_LAYER = {}           -- layer file -> true: saveBitVectorMapToFile throws for it
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
    if type(h) ~= "table" or FAIL_SAVE[h.path] then return false end
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
function setXMLFloat(h, k, v) h.data[k] = v end
function hasXMLProperty(h, p)
    for k in pairs(h.data) do
        if k == p or k:sub(1, #p + 1) == p .. "#" or k:sub(1, #p + 1) == p .. "." then return true end
    end
    return false
end
-- saveBitVectorMapToFile returns nothing a caller reads (DensityMapHeightManager.lua:527);
-- a layer save either completes or throws.
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
-- The store's own save (SoilValueMaps.lua saveToSavegame), over a store whose three layers
-- carry their files: the real method, given this store.
local REAL_SAVE = nil

local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }

--- A fresh system on a career in `dir`. opts.valid: saved before; opts.loaded: the three
--- layer files loaded from the save (the store's `loaded` flags); opts.ledger: a StateLedger.
local function world(dir, opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    MDB.ledgerActive = false
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vmOpts = opts.loaded and { membershipLoaded = true, conditionLoaded = true } or nil
    local vm, age, wet, member = ENGINE.newValueMaps(vmOpts)
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    -- The store's three saved layers and its own save method.
    vm.available = true
    vm.layers = vm.layers or {}
    vm.layers.groundMembership = vm.layers.groundMembership or { bvm = member.id, channels = 1 }
    vm.layers.materialAge = vm.layers.materialAge or { bvm = age.id, channels = 8 }
    vm.layers.materialWetness = vm.layers.materialWetness or { bvm = wet.id, channels = 8 }
    vm.layers.groundMembership.def = { file = "groundMembership.grle" }
    vm.layers.materialAge.def = { file = "materialAge.grle" }
    vm.layers.materialWetness.def = { file = "materialWetness.grle" }
    vm.saveToSavegame = REAL_SAVE
    sys.valueMaps = vm
    W.sys, W.vm, W.mgr = sys, vm, { soilSystem = sys, lastSeenVersion = "bench" }
    g_currentMission = {
        environment = { currentMonotonicDay = 100, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {}, addVehicle = function() return true end },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
        missionInfo = { savegameDirectory = dir, isValid = opts.valid == true, xmlFile = newHandle(dir .. "/careerSavegame.xml") },
        stateLedger = opts.ledger,
    }
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
    MDB.beginLoad(sys.materialDown)
    if opts.ledger ~= nil then MDB.registerLedger(sys.materialDown) end
    MDB.loadFallback(sys.materialDown)
    return (okMd and okMw and okHb and okYl and a and b) == true
end
local function md() return W.sys.materialDown end
local function coord() return W.sys.groundConditionCoordinator end
--- The native save, in its order: the invocation, the career XML built, Soil's hook
--- (saveSoilData), the career XML written to disk.
local function save()
    MDB.openSaveInvocation()
    local mi = g_currentMission.missionInfo
    mi.xmlFile = newHandle(mi.savegameDirectory .. "/careerSavegame.xml")
    SoilFertilityManager.saveSoilData(W.mgr, mi)
    saveXMLFile(mi.xmlFile)
end
local function stamp(dir) local d = DISK[dir .. "/soilData.xml"] return d ~= nil and d[MDB.INDEX_STAMP_KEY] or nil end
local function markerGen(dir) local d = DISK[dir .. "/careerSavegame.xml"] return d ~= nil and d[MDB.MARKER_KEY .. "#generation"] or nil end
local function markerState(dir) local d = DISK[dir .. "/careerSavegame.xml"] return d ~= nil and d[MDB.MARKER_KEY .. "#state"] or nil end
local function source() local m = coord().membership return m ~= nil and tostring(m.source) or "none" end
local function unav(gx, gz) return tostring(coord():isUnavailable(gx, gz)) .. ":" .. tostring(coord():unavailableReason(gx, gz)) end

--- A career saved once (a new career: the store decides NEW when its mission starts), with
--- cell (3, 3) marked unavailable by a native error before the save.
local function savedCareer(dir, opts)
    opts = opts or {}
    DISK[dir .. "/careerSavegame.xml"] = nil
    world(dir, { valid = false })
    W.sys.yardLadder:onMissionStarted()
    coord():markUnavailable(3, 3, "NATIVE_ERROR")
    if opts.failLayer then FAIL_LAYER[opts.failLayer] = true end
    if opts.failOwnFile then FAIL_SAVE[dir .. "/sfMaterialDown.xml"] = true end
    save()
    FAIL_LAYER, FAIL_SAVE = {}, {}
end

group("E", function()
    REAL_SAVE = SoilValueMaps.saveToSavegame
    T.ok("E0 [world] the store's save is the real method", type(REAL_SAVE) == "function")
    DISK = {}
    savedCareer("c1")
    T.eq("E1 [entry point] the save stamps soilData.xml with the generation the career marker carries, after all three layers saved",
        tostring(stamp("c1")) .. "/" .. tostring(markerGen("c1")) .. "/" .. tostring(markerState("c1")) .. "/" .. tostring(DISK["c1/groundMembership.grle"] ~= nil and DISK["c1/materialAge.grle"] ~= nil and DISK["c1/materialWetness.grle"] ~= nil),
        "1/1/EXPECTED/true")
    world("c1", { valid = true, loaded = true })
    T.eq("E2 the reload trusts the saved index: its three files loaded and its stamp equal to the marker's generation",
        source() .. "/" .. tostring(coord().membership.stamped), GCC.MEMBERSHIP_FROM_INDEX .. "/true")
    T.eq("E3 until the store decides its load, every cell reads unavailable (the hold), never the empty overlay",
        unav(3, 3) .. " " .. unav(8, 8), "true:RESTORING true:RESTORING")
    coord():markUnavailable(5, 5, "DURING_HOLD")
    W.sys.yardLadder:onMissionStarted()
    T.eq("E4 decided MODERN, the saved overlay comes back (3, 3), merged over a cell marked during the hold (5, 5); an untouched cell is available",
        tostring(md().loadState) .. " " .. unav(3, 3) .. " " .. unav(5, 5) .. " " .. unav(8, 8),
        "MODERN true:NATIVE_ERROR true:DURING_HOLD false:nil")
end)

group("S", function()
    DISK = {}
    savedCareer("s1", { failLayer = "groundMembership.grle" })
    world("s1", { valid = true, loaded = true })
    T.eq("S1 a layer save that failed leaves soilData.xml unstamped, so the reload rebuilds the index",
        tostring(stamp("s1")) .. "/" .. source(), "nil/" .. GCC.MEMBERSHIP_REBUILT)

    DISK = {}
    savedCareer("s2")
    DISK["s2/soilData.xml"][MDB.INDEX_STAMP_KEY] = "0"     -- soilData.xml from another save
    world("s2", { valid = true, loaded = true })
    T.eq("S2 a stamp of another generation than the marker's is not trusted: rebuilt", source(), GCC.MEMBERSHIP_REBUILT)

    DISK = {}
    savedCareer("s3", { failOwnFile = true })
    world("s3", { valid = true, loaded = true })
    T.eq("S3 the store's own file failed (marker UNAVAILABLE): the marker still carries the generation, and the index it stamps is trusted",
        tostring(markerState("s3")) .. "/" .. tostring(markerGen("s3")) .. "/" .. tostring(stamp("s3")) .. "/" .. source(),
        "UNAVAILABLE/1/1/" .. GCC.MEMBERSHIP_FROM_INDEX)

    DISK = {}
    savedCareer("s4")
    DISK["s4/careerSavegame.xml"] = nil                   -- a save from before the marker
    world("s4", { valid = true, loaded = true })
    T.eq("S4 no marker, no trust: rebuilt", source(), GCC.MEMBERSHIP_REBUILT)
end)

group("O", function()
    -- A save whose marker expects a generation its own file does not carry.
    DISK = {}
    savedCareer("o1")
    DISK["o1/careerSavegame.xml"][MDB.MARKER_KEY .. "#generation"] = "9"
    world("o1", { valid = true, loaded = true })
    W.sys.yardLadder:onMissionStarted()
    T.eq("O1 an UNAVAILABLE load restores no overlay; the hold still ends",
        tostring(md().loadState) .. " " .. unav(3, 3) .. " " .. unav(8, 8), "UNAVAILABLE false:nil false:nil")

    -- A save with no marker at all: legacy, qualified once.
    DISK = {}
    savedCareer("o2")
    DISK["o2/careerSavegame.xml"] = nil
    world("o2", { valid = true, loaded = true })
    W.sys.yardLadder:onMissionStarted()
    T.eq("O2 a LEGACY load restores no overlay either; the hold ends",
        tostring(md().loadState) .. " " .. unav(3, 3), "LEGACY false:nil")

    -- The overlay rides the envelope: the frozen save carries it under its own name.
    DISK = {}
    world("o3", { valid = false })
    W.sys.yardLadder:onMissionStarted()
    coord():markUnavailable(2, 2, "NATIVE_ERROR")
    local env = md():serialize()
    local cells = env.groundAvailability and env.groundAvailability.unavailable or {}
    T.eq("O3 the envelope carries the overlay, detached, with its grid stamped",
        tostring(env.saveStatus) .. "/" .. #cells .. "/" .. tostring(cells[1] and cells[1].key) .. "/" .. tostring(env.groundAvailability and env.groundAvailability.resolution ~= nil),
        "COMPLETE/1/2:2/true")
end)
end
MAINT137_BENCH()
