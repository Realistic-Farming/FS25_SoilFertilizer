-- RSF-F215-s7-condition_provider_spec_test.lua
--
-- RSF-F215 (S7), the limited condition provider SG-3 grades bales through: exact native
-- unique id binding (no farm/fill/capacity similarity), schema-2 rows with ordered
-- portions and their persisted coordinates, READY/RESTORING/UNAVAILABLE reads, paired
-- BIRTH/ADVANCE/REBIND/RETIRE notifications, and the store's persistence: one frozen
-- envelope per native save, the own file through a tagged codec, and a career marker
-- the load checks the payload against.
--
-- THE ENTRY-POINT BAR IS GROUP E. Production's system (SoilFertilitySystem.new, the
-- owners armed in production's order), HookManager:installAll (the Baler collection,
-- the Bale.register birth door, the Bale.delete door, the object storage frame), a
-- Baler built and processed as the engine does (RSF-F211-s6b-baler_model.lua) making a
-- bale through the real createBale; the provider read through SoilFertilityManager; the
-- save through the bridge's own save (the marker into the career XML, the own file
-- through the codec) and the load through the bridge's own load (the marker read from
-- the career file on disk, the own file decoded) into a fresh system; the bale coming
-- back through the engine's savegame path (Bale:loadFromConfigXML with its saved unique
-- id, then register). Nothing on the path is hand-populated: no row, no token, no
-- marker, no epoch. The world supplies the windrows and their ground condition, the
-- disk (a file table the XML calls read and write) and the engine's clock-free globals.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/utils/SoilUtils.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/SoilFertilityManager.lua

-- The whole bench runs inside one function: the sources it loads are concatenated into
-- one chunk, and their file-level locals with this file's would pass Lua's 200-local
-- limit for a single function.
local function F215_BENCH()
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local FT = ENGINE.FT
local GR = FT.GRASS_WINDROW
local MDB = SoilMaterialDownBridge
local SFM = SoilFertilityManager

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function num(x)
    if type(x) ~= "number" then return tostring(x) end
    local r = math.floor(x * 10000 + 0.5) / 10000
    if r == math.floor(r) then return string.format("%d", math.floor(r)) end
    return tostring(r)
end

-- ── The disk and the engine's XML handle calls ──────────────────────────────
-- A file is a flat table of "path#attribute" -> string. createXMLFile makes an empty
-- handle; saveXMLFile writes it to the disk and returns true; loadXMLFile reads a copy;
-- hasXMLProperty answers for an element when any attribute sits at or under it.
local DISK = {}
local SAVE_OK = true
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
    if type(h) ~= "table" or not SAVE_OK then return false end
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
function hasXMLProperty(h, p)
    for k in pairs(h.data) do
        if k == p or k:sub(1, #p + 1) == p .. "#" or k:sub(1, #p + 1) == p .. "." then return true end
    end
    return false
end
-- The engine's id helper (Utils.lua:98): an md5 of the value, the time and a counter.
local EPOCHS = 0
Utils = Utils or {}
Utils.getUniqueId = function(_value, _map, prefix, _len) EPOCHS = EPOCHS + 1 return (prefix or "") .. "epoch" .. EPOCHS end
function entityExists(_node) return true end
function getWorldTranslation(_node) return 0, 0, 0 end

-- The store's raw constants MaterialWetness reads (SoilValueMaps.lua:151-159); the store
-- itself is the engine model's value maps, handed to the owners by world().
SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end
local WET, DRY = MaterialWetness.rawToPct(204), MaterialWetness.rawToPct(52)
local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local STORE_CLASS = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"]
-- Class hooks persist across worlds (installAll wraps the same class tables again), so
-- every world restores them before installing.
local PRISTINE = { register = Bale.register, start = Baler.onStartWorkAreaProcessing, finish = Baler.onEndWorkAreaProcessing,
                   fill = Baler.onFillUnitFillLevelChanged, delete = Bale.delete, tick = Baler.onUpdateTick,
                   store = STORE_CLASS.addToStorage }

--- A fresh system on a mission whose career lives in `dir`. opts.valid: the career was
--- saved before (FSCareerMissionInfo.isValid); opts.ledger: a StateLedger stand-in.
local function world(dir, opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    BALER_MODEL.failLoad, BALER_MODEL.onRegister = false, nil
    Bale.register, Bale.delete = PRISTINE.register, PRISTINE.delete
    Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing = PRISTINE.start, PRISTINE.finish
    Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick = PRISTINE.fill, PRISTINE.tick
    STORE_CLASS.addToStorage = PRISTINE.store
    MDB.ledgerActive = false
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet, member = ENGINE.newValueMaps()
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    W.sys, W.vm, W.age, W.wet, W.mgr = sys, vm, age, wet, { soilSystem = sys }
    local today = opts.today or 100
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {} },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
        missionInfo = { savegameDirectory = dir, isValid = opts.valid == true, xmlFile = newHandle(dir .. "/careerSavegame.xml") },
        stateLedger = opts.ledger,
    }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    -- Production's order: the owners arm inside the mission's load (onMissionLoaded) ...
    local okMd = sys.materialDown:arm(vm)
    sys.materialDown.ageAppliedThroughDay = today
    local okMw = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    local okHb = sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    local okYl = sys.yardLadder:arm(sys.materialDown, sys.materialWetness, sys.hayBet)
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    -- ... then main.lua's bridges: the marker and the new-career flag, the ledger, the own file.
    MDB.beginLoad(sys.materialDown)
    if opts.ledger ~= nil then MDB.registerLedger(sys.materialDown) end
    MDB.loadFallback(sys.materialDown)
    return (okMd and okMw and okHb and okYl and a and b and c) == true
end
local function md() return W.sys.materialDown end
local function yl() return W.sys.yardLadder end
local function installAll() return pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys) end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function windrow(gx, perPixel)
    local x0 = -32 + gx * 4 + (gx == 2 and 2 or 0)
    HEIGHT.fill(GR, x0, 2, x0 + 2, 3, perPixel)
end
local function baler(extra)
    local o = { x0 = -22, z0 = 1, width = 4, depth = 2 }
    for k, v in pairs(extra or {}) do o[k] = v end
    local v, work = BALER_MODEL.new(o)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v, work
end
local function lastBale(v) local b = v.spec_baler.bales[#v.spec_baler.bales] return b and b.baleObject end
--- A bale coming through another door, as the engine makes one: Bale.new, its config
--- (with a loaded unique id when `uid` is given, Bale.lua:269-270), its fill, register().
local function spawnBale(uid, litres, farmId)
    local b = Bale.new(true, false)
    b:loadFromConfigXML("bale.xml", 0, 0, 0, 0, 0, 0, uid)
    b:setFillType(FT.STRAW or GR)
    b:setFillLevel(litres or 100)
    b:setOwnerFarmId(farmId or 1)
    b:register()
    return b
end
--- The native save: the invocation opens, the career XML is built (the marker lands in
--- it) and the own file is written by Soil's save hook; the engine then writes the career
--- XML to the save directory.
local function save()
    MDB.openSaveInvocation()
    local mi = g_currentMission.missionInfo
    mi.xmlFile = newHandle(mi.savegameDirectory .. "/careerSavegame.xml")
    MDB.saveStore(md(), mi)
    saveXMLFile(mi.xmlFile)
end
local function marker(dir)
    local d = DISK[dir .. "/careerSavegame.xml"] or {}
    local k = MDB.MARKER_KEY
    return tostring(d[k .. "#state"]) .. "/" .. tostring(d[k .. "#backend"]) .. "/" .. tostring(d[k .. "#generation"])
end
local function portionsKey(r)
    local p = r.portions and r.portions[1] or {}
    return table.concat({ tostring(r.state), tostring(#(r.portions or {})), tostring(p.historyId), tostring(p.sourceStreamId),
        tostring(p.sourceEpoch), num(p.eventSequence), num(p.portionRevision), num(p.condition), num(p.litres),
        tostring(p.historyKnowledge), num(r.carrierRevision), num(r.carrierEventSequence) }, "|")
end
local function read(uid) return SFM.getBaleConditionPortions(W.mgr, uid) end
local function countRows()
    local n = 0
    md():enumerateObjects(function(token) if YardLadder._isOurToken(token) then n = n + 1 end end)
    return n
end
--- An SG-3 stand-in listener: records every before and after, hands back a ticket.
local function recorder(opts)
    opts = opts or {}
    local rec = { events = {}, invalid = {} }
    rec.callbacks = {
        beforeChange = function(ev)
            if opts.throwBefore then error("before boom") end
            rec.events[#rec.events + 1] = { phase = "before", ev = ev }
            return { n = #rec.events }
        end,
        afterChange = function(ev, ticket)
            if opts.throwAfter then error("after boom") end
            rec.events[#rec.events + 1] = { phase = "after", ev = ev, ticket = ticket }
        end,
        invalidate = function(uid, reason) rec.invalid[#rec.invalid + 1] = tostring(uid) .. ":" .. tostring(reason) end,
    }
    return rec
end
local function kinds(rec, from)
    local out = {}
    for i = (from or 0) + 1, #rec.events do out[#out + 1] = rec.events[i].phase .. " " .. tostring(rec.events[i].ev.kind) end
    return table.concat(out, ", ")
end
--- Every before is followed by its after: the same kind and carrier sequence, the ticket
--- handed back, the revision moving by one.
local function paired(rec)
    if #rec.events % 2 ~= 0 then return false end
    for i = 1, #rec.events, 2 do
        local b, a = rec.events[i], rec.events[i + 1]
        if b.phase ~= "before" or a.phase ~= "after" then return false end
        if b.ev.kind ~= a.ev.kind or b.ev.carrierEventSequence ~= a.ev.carrierEventSequence then return false end
        if a.ticket == nil or a.ticket.n ~= i then return false end
        if a.ev.afterCarrierRevision ~= (b.ev.beforeCarrierRevision or 0) + 1 then return false end
    end
    return true
end

-- The ruled birth for this bench's swath: (26.063 - 20) x 6.
local SWATH_PCT = (10 * WET + 90 * DRY) / 100
local SWATH_CONDITION = (SWATH_PCT - YardLadder.fitPct()) * YardLadder.RATES.WET_OUTDOOR

-- ══════════════════════════════════════════════════════════════════════════
-- E. FROM PRODUCTION'S ENTRY POINT: A BALED BALE, READ, SAVED AND RELOADED
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    DISK = {}
    T.ok("E0 [world] a new career: the owners arm in production's order and the bridges open the load", world("career1", { valid = false }))
    local okI = installAll()
    local v = baler({ capacity = 100 })
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    local bale = lastBale(v)
    local uid = bale ~= nil and bale:getUniqueId() or nil
    local r = read(uid)
    local p = r.portions and r.portions[1] or {}
    T.eq("E1 the real createBale's bale is born READY through the manager, one portion, known, with the chamber's wetness and the ruled condition",
        tostring(okI) .. "/" .. tostring(r.state) .. "/" .. #(r.portions or {}) .. "/" .. tostring(p.historyKnowledge) .. "/" .. num(p.condition) .. "/" .. num(r.actualLitres),
        "true/READY/1/KNOWN/" .. num(SWATH_CONDITION) .. "/100")
    T.eq("E2 its coordinates come from the one allocator and the new store's epoch: row, history and stream tokens, sequence 1, revision 1",
        tostring(yl()._byUid[uid]) .. "/" .. tostring(p.historyId) .. "/" .. tostring(p.sourceStreamId) .. "/" .. num(p.eventSequence) .. "/" .. num(p.portionRevision) .. "/" .. tostring(p.sourceEpoch == md():getBaleConditionMeta().sourceEpoch),
        "yl_1/yh_2/ys_3/1/1/true")
    local before = portionsKey(r)
    yl():onMissionStarted()
    T.eq("E3 the load was decided NEW (a new career, nothing delivered), and the capabilities read ready once the mission started",
        tostring(md().loadState) .. "/" .. tostring((SFM.getBaleConditionCapabilities(W.mgr) or {}).ready) .. "/" .. tostring((SFM.getBaleConditionCapabilities(W.mgr) or {}).schema),
        "NEW/true/SG_SOIL_CONDITION_1")
    save()
    T.eq("E4 the save marks the career EXPECTED on the own-file backend at generation 1, and the own file carries the row",
        marker("career1") .. "/" .. tostring(DISK["career1/sfMaterialDown.xml"] ~= nil and DISK["career1/sfMaterialDown.xml"]["materialDown#format"]),
        "EXPECTED/OWN_FILE/1/tagged1")

    -- The reload: a fresh system, the marker read off the disk, the own file decoded.
    world("career1", { valid = true })
    installAll()
    local restoring = read(uid)
    T.eq("E5 before its bale registers, the loaded row reads RESTORING", tostring(restoring.state) .. "/" .. tostring(restoring.reason), "RESTORING/AWAITING_BALE")
    local back = spawnBale(uid, 100)   -- the savegame path: the saved unique id, then register
    local r2 = read(uid)
    T.eq("E6 the bale comes back through the engine's savegame path to its own row: READY with every coordinate as saved, and no event",
        tostring(md().loadState) .. "/" .. portionsKey(r2) .. "/" .. tostring(yl()._byNode[back.nodeId]), "MODERN/" .. before .. "/yl_1")
    local nextBale = spawnBale(nil, 100)
    local r3 = read(nextBale:getUniqueId())
    T.eq("E7 the allocator was restored with the store: the next bale's tokens continue above every saved serial",
        tostring(r3.portions[1] and r3.portions[1].historyId) .. "/" .. tostring(yl()._byUid[nextBale:getUniqueId()]), "yh_5/yl_4")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE LOAD DECISION
-- ══════════════════════════════════════════════════════════════════════════
local function legacyLedger(payload)
    local L = { hooks = nil, registered = true }
    L.registerModule = function(_, _name, hooks)
        L.hooks = hooks
        if payload ~= nil then hooks.deserialize(payload) end
        return L.registered
    end
    return L
end
group("L", function()
    -- A pre-F215 save: StateLedger delivers the old envelope (schema 1, rows without a
    -- native id), and the career has no marker.
    DISK = {}
    local legacy = { schema = 1, ageAppliedThroughDay = 90, activeFields = {},
                     objects = { yl_1 = { condition = 55, farmId = 1, fillTypeName = "STRAW", capacity = 100, bornDay = 80 } } }
    world("old", { valid = true, ledger = legacyLedger(legacy) })
    installAll()
    local lookalike = spawnBale("looks", 100, 1)
    local r = read("looks")
    T.eq("L1 a pre-F215 save is qualified once (LEGACY): its row is kept as data and UNBOUND, and a lookalike bale is born as its own row, never matched by farm, fill or capacity",
        tostring(md().loadState) .. "/" .. tostring(md():getObjectRecord("yl_1").carrierState) .. "/" .. countRows() .. "/" .. tostring(yl()._byNode[lookalike.nodeId]) .. "/" .. tostring(r.state) .. "/" .. tostring(r.portions[1] and r.portions[1].historyKnowledge),
        "LEGACY/UNBOUND/2/yl_2/READY/UNKNOWN")
    T.eq("L1b the old row's condition does not reach the new bale (the D4 line: existing bales lose their built-up condition once)",
        num(r.portions[1] and r.portions[1].condition), "0")

    -- A career that EXPECTS generation 2 on its own file, holding generation 1.
    DISK = {}
    world("gen", { valid = false })
    installAll()
    spawnBale("g1", 100)
    save()
    DISK["gen/careerSavegame.xml"][MDB.MARKER_KEY .. "#generation"] = "2"
    world("gen", { valid = true })
    installAll()
    local g = spawnBale("g1", 100)
    local rg = read("g1")
    T.eq("L2 a payload of another generation than the marker expects is UNAVAILABLE: nothing goes live, the provider says so, and the ladder still keeps a session row",
        tostring(md().loadState) .. "/" .. tostring(md().loadReason) .. "/" .. tostring(rg.state) .. "/" .. tostring(rg.reason) .. "/" .. tostring(yl()._byNode[g.nodeId] ~= nil),
        "UNAVAILABLE/GENERATION_MISMATCH/UNAVAILABLE/STORE_UNAVAILABLE/true")
    save()
    local file = DISK["gen/sfMaterialDown.xml"] or {}
    local hasObjects, hasRetained = false, false
    for k in pairs(file) do
        if k:find("materialDown.envelope.entries.entry%(%d+%)#k") and file[k] == "objects" then hasObjects = true end
        if k:find("materialDown.envelope.entries.entry%(%d+%)#k") and file[k] == "retained" then hasRetained = true end
    end
    T.eq("L3 an UNAVAILABLE session's save carries no objects map, only the raw rows it could not restore, and marks the career UNAVAILABLE",
        tostring(hasObjects) .. "/" .. tostring(hasRetained) .. "/" .. marker("gen"):match("^(%a+)"), "false/true/UNAVAILABLE")
    world("gen", { valid = true })
    installAll()
    spawnBale("g1", 100)
    T.eq("L4 the next load after an UNAVAILABLE session is qualified once (LEGACY, AFTER_UNAVAILABLE): the retained row comes back UNBOUND and the bale is born fresh",
        tostring(md().loadState) .. "/" .. tostring(md().loadReason) .. "/" .. tostring(md():getObjectRecord("yl_1") and md():getObjectRecord("yl_1").carrierState) .. "/" .. tostring(read("g1").state),
        "LEGACY/AFTER_UNAVAILABLE/UNBOUND/READY")

    -- A modern payload no marker vouches for (the career saved while the family was off).
    DISK = {}
    world("nomark", { valid = false })
    installAll()
    spawnBale("n1", 100)
    save()
    DISK["nomark/careerSavegame.xml"] = nil
    world("nomark", { valid = true })
    installAll()
    spawnBale("n1", 100)
    T.eq("L5 a modern payload with no marker is not trusted: LEGACY (PAYLOAD_WITHOUT_MARKER), its row UNBOUND",
        tostring(md().loadState) .. "/" .. tostring(md().loadReason) .. "/" .. tostring(md():getObjectRecord("yl_1").carrierState),
        "LEGACY/PAYLOAD_WITHOUT_MARKER/UNBOUND")

    -- The marker names the own file; a stale StateLedger block never overrides it.
    DISK = {}
    world("both", { valid = false })
    installAll()
    spawnBale("b1", 100)
    save()
    local stale = { schema = 1, saveGeneration = 7, saveStatus = "COMPLETE", ageAppliedThroughDay = 1, activeFields = {}, objects = {},
                    baleConditionMeta = { nextTokenSerial = 1, sourceEpoch = "other" } }
    world("both", { valid = true, ledger = legacyLedger(stale) })
    installAll()
    spawnBale("b1", 100)
    T.eq("L6 the backend the marker names is the only one read: the own file's rows load and the stale ledger block's epoch is not taken",
        tostring(md().loadState) .. "/" .. tostring(read("b1").state) .. "/" .. tostring(md():getBaleConditionMeta().sourceEpoch ~= "other"),
        "MODERN/READY/true")

    -- A payload whose rows cannot be trusted: two rows claim one native id.
    DISK = {}
    world("dup", { valid = false })
    installAll()
    spawnBale("d1", 100)
    local env = md():serialize()
    local copy = MaterialDown.deepCopy(env.objects.yl_1)
    copy.token = "yl_9"
    env.objects.yl_9 = copy
    env.saveGeneration = 3
    env.baleConditionMeta.nextTokenSerial = 20
    DISK["dup/careerSavegame.xml"] = { [MDB.MARKER_KEY .. "#schema"] = "1", [MDB.MARKER_KEY .. "#backend"] = "STATELEDGER",
                                       [MDB.MARKER_KEY .. "#generation"] = "3", [MDB.MARKER_KEY .. "#state"] = "EXPECTED" }
    world("dup", { valid = true, ledger = legacyLedger(env) })
    installAll()
    spawnBale("d1", 100)
    T.eq("L7 duplicate native ids in a modern payload prevent the live restore: UNAVAILABLE, the rows kept as raw data",
        tostring(md().loadState) .. "/" .. tostring(md().loadReason) .. "/" .. tostring(md()._retainedRaw ~= nil and md()._retainedRaw.yl_9 ~= nil),
        "UNAVAILABLE/INVALID_DUPLICATE_NATIVE_ID/true")

    -- StateLedger's registerModule answers false: the ledger is not the backend.
    DISK = {}
    local refusing = legacyLedger(nil)
    refusing.registered = false
    world("refuse", { valid = false, ledger = refusing })
    T.eq("L8 a registration the ledger refused is not a registration: the backend stays the own file", tostring(MDB.ledgerActive), "false")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- S. ONE FROZEN ENVELOPE PER NATIVE SAVE
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    DISK = {}
    local ledger = legacyLedger(nil)
    world("inv", { valid = false, ledger = ledger })
    installAll()
    spawnBale("s1", 100)
    MDB.openSaveInvocation()
    local viaLedger = ledger.hooks.serialize()          -- StateLedger's callback, first this time
    local mi = g_currentMission.missionInfo
    mi.xmlFile = newHandle("inv/careerSavegame.xml")
    MDB.saveStore(md(), mi)                             -- Soil's hook, second
    saveXMLFile(mi.xmlFile)
    T.eq("S1 inside one save the ledger's serialize and Soil's hook share one envelope: the marker names the ledger and the generation it was handed",
        tostring(viaLedger.saveGeneration) .. "/" .. marker("inv") .. "/" .. tostring(ledger.hooks.serialize().saveGeneration), "1/EXPECTED/STATELEDGER/1/1")
    MDB.openSaveInvocation()
    T.eq("S2 the next save is the next generation", tostring(ledger.hooks.serialize().saveGeneration), "2")
    viaLedger.objects.yl_1.carrierState = "MUTATED"
    T.eq("S2b what a serializer is handed is detached: mutating it never reaches the store", tostring(md():getObjectRecord("yl_1").carrierState), "WORLD")

    DISK = {}
    world("fail", { valid = false })
    installAll()
    spawnBale("f1", 100)
    SAVE_OK = false
    local okSave = pcall(save)
    SAVE_OK = true
    T.eq("S3 an own file that did not save leaves the marker UNAVAILABLE and says the save failed; the store in memory stays valid and READY",
        tostring(okSave) .. "/" .. tostring(md().lastSaveFailed) .. "/" .. tostring(md():isConditionStoreValid()) .. "/" .. tostring(read("f1").state) .. "/" .. tostring(DISK["fail/careerSavegame.xml"]),
        "true/true/true/READY/nil")
    save()
    T.eq("S4 the next save retries and succeeds: EXPECTED at the next generation", marker("fail") .. "/" .. tostring(md().lastSaveFailed), "EXPECTED/OWN_FILE/2/false")

    -- The load is decided first (a bale's birth decides it), so only the armed check can
    -- keep this save from writing: a save before any decision stops on the PENDING guard.
    DISK = {}
    world("off", { valid = false })
    installAll()
    spawnBale("o1", 100)
    local decided = tostring(md().loadState)
    md().armed = false
    save()
    T.eq("S5 a save while the family is off writes nothing, with the load already decided: no marker, no file", decided .. "/" .. tostring(DISK["off/careerSavegame.xml"] and DISK["off/careerSavegame.xml"][MDB.MARKER_KEY .. "#state"]) .. "/" .. tostring(DISK["off/sfMaterialDown.xml"]), "NEW/nil/nil")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. PAIRED NOTIFICATIONS
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    DISK = {}
    world("notes", { valid = false })
    installAll()
    local rec = recorder()
    local lease = SFM.registerBaleConditionListener(W.mgr, "sg3", rec.callbacks)
    local b = spawnBale("n1", 100)
    local birth = rec.events[2] and rec.events[2].ev or {}
    T.eq("N1 a birth is one paired BIRTH: before with no portions, after with the new portion at sequence 1, revisions 0 to 1",
        kinds(rec) .. "/" .. #(rec.events[1] and rec.events[1].ev.portionsBefore or {1}) .. "/" .. num(birth.carrierEventSequence) .. "/" .. num(birth.afterCarrierRevision) .. "/" .. num(birth.portionsAfter and birth.portionsAfter[1] and birth.portionsAfter[1].eventSequence) .. "/" .. tostring(paired(rec)),
        "before BIRTH, after BIRTH/0/1/1/1/true")
    yl():onLadderPass({ monotonicDay = 101, boundariesCrossed = 1 })
    local adv = rec.events[4] and rec.events[4].ev or {}
    T.eq("N2 a day on the ladder is one paired ADVANCE: the condition rises by the dry day's 1, the condition sequence and the portion revision advance",
        kinds(rec, 2) .. "/" .. num(adv.portionsBefore and adv.portionsBefore[1].condition) .. "/" .. num(adv.portionsAfter and adv.portionsAfter[1].condition) .. "/" .. num(adv.portionsAfter and adv.portionsAfter[1].eventSequence) .. "/" .. num(adv.portionsAfter and adv.portionsAfter[1].portionRevision),
        "before ADVANCE, after ADVANCE/0/1/2/2")
    local held = BALER_MODEL.storeBale({ isServer = true, isClient = false }, b)
    local stored = md():getObjectRecord("yl_1")
    T.eq("N3 into an object storage through the storage's own class: a paired REBIND to STORED, not a RETIRE; the row keeps its native id",
        kinds(rec, 4) .. "/" .. tostring(stored and stored.carrierState) .. "/" .. tostring(stored and stored.nativeBaleUniqueId) .. "/" .. tostring(read("n1").state),
        "before REBIND, after REBIND/STORED/n1/READY")
    local out = held:removeFromStorage({ isServer = true, isClient = false }, 0, 0, 0, 0, 0, 0)
    T.eq("N4 out of storage with the same native id: a paired REBIND back to WORLD, on the new bale object's node",
        kinds(rec, 6) .. "/" .. tostring(md():getObjectRecord("yl_1").carrierState) .. "/" .. tostring(yl()._byNode[out.nodeId]) .. "/" .. tostring(paired(rec)),
        "before REBIND, after REBIND/WORLD/yl_1/true")
    md():getObjectRecord("yl_1").portions[1].condition = 99.5
    yl():onLadderPass({ monotonicDay = 102, boundariesCrossed = 1 })
    T.eq("N5 a condemning day: the increase is notified first, then the removal RETIRE; the bale is emptied and deleted, the row is gone",
        kinds(rec, 8) .. "/" .. tostring(out.deleted) .. "/" .. tostring(md():getObjectRecord("yl_1")) .. "/" .. tostring(paired(rec)),
        "before ADVANCE, after ADVANCE, before RETIRE, after RETIRE/true/nil/true")
    local sold = spawnBale("n2", 100)
    local mark = #rec.events
    sold:delete()
    T.eq("N6 a bale that leaves (sold, fed) is a paired RETIRE with its native id", kinds(rec, mark) .. "/" .. tostring(rec.events[mark + 2] and rec.events[mark + 2].ev.nativeIds[1]), "before RETIRE, after RETIRE/n2")
    T.eq("N7 the same listener id cannot register twice; unregistering its lease stops delivery",
        tostring(select(2, SFM.registerBaleConditionListener(W.mgr, "sg3", rec.callbacks))) .. "/" .. tostring(SFM.unregisterBaleConditionListener(W.mgr, lease)),
        "DUPLICATE_LISTENER/true")
    mark = #rec.events
    spawnBale("n3", 100)
    T.eq("N7b after unregistering, a birth notifies nothing", #rec.events - mark, 0)
    local bad = recorder({ throwAfter = true })
    SFM.registerBaleConditionListener(W.mgr, "broken", bad.callbacks)
    spawnBale("n4", 100)
    T.eq("N8 a listener that throws never blocks the change: the bale is READY, and that listener is told its view is invalid",
        tostring(read("n4").state) .. "/" .. table.concat(bad.invalid, ","), "READY/n4:LISTENER_AFTER_FAILED")
    -- A client has no g_server. In the mod's environment a nil assignment falls through
    -- to the real global table, so the real one is cleared for the call.
    local realG = getmetatable(_ENV).__index
    local gs, gsEnv = realG.g_server, rawget(_ENV, "g_server")
    realG.g_server = nil
    rawset(_ENV, "g_server", nil)
    local okC, whyC = yl():registerListener("client", recorder().callbacks)
    realG.g_server = gs
    rawset(_ENV, "g_server", gsEnv)
    T.eq("N9 a listener registers only on the server", tostring(okC) .. "/" .. tostring(whyC), "nil/NOT_SERVER")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. THE PROVIDER'S READS
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
    DISK = {}
    world("reads", { valid = false })
    installAll()
    local b = spawnBale("p1", 100)
    b:setFillLevel(60)
    T.eq("P1 a bale partly used since its row was written reads UNAVAILABLE: its portions are never rescaled into agreement",
        tostring(read("p1").state) .. "/" .. tostring(read("p1").reason), "UNAVAILABLE/QUANTITY_MISMATCH")
    spawnBale("p2", 100)
    spawnBale("p2", 100)
    T.eq("P2 two live bales with one native id: neither is proved, the row reads UNAVAILABLE and the second gets no row",
        tostring(read("p2").state) .. "/" .. tostring(read("p2").reason) .. "/" .. countRows(), "UNAVAILABLE/DUPLICATE_NATIVE_ID/2")
    local c = spawnBale("p3", 100)
    local viaNode = SFM.getConditionPortionsForNode(W.mgr, c.nodeId)
    T.eq("P3 the node delegate resolves the exact unique id and the one store answers",
        tostring(viaNode.state) .. "/" .. tostring(viaNode.nativeBaleUniqueId), "READY/p3")
    local r = read("p3")
    r.portions[1].condition = 999
    T.eq("P4 a read is detached: changing it never reaches the store", num(read("p3").portions[1].condition), "0")
    T.eq("P5 an id no row holds reads UNAVAILABLE", tostring(read("nobody").state) .. "/" .. tostring(read("nobody").reason), "UNAVAILABLE/NO_ROW")
    -- An unfinished round bale (RSF-F211 :112): it registers padded to the chamber's
    -- capacity, and dropBale applies the real amount (Baler.lua:1590-1593).
    local ns = BALER_MODEL.newNonStop({ x0 = -22, z0 = 1, width = 4, depth = 2, capacity = 100, round = true, canUnloadUnfinishedBale = true })
    g_currentMission.vehicleSystem:addVehicle(ns)
    installAll()
    setCell(2, 8, 1, 204) setCell(3, 8, 1, 204) windrow(2, 15) windrow(3, 15)   -- 60 L wet
    ENGINE.tick(ns, 16)
    BALER_MODEL.updateTick(ns, 1000)                                              -- into the chamber
    setCell(2, 8, 1, 52) setCell(3, 8, 1, 52) windrow(2, 5) windrow(3, 5)        -- 20 L dry, in the buffer
    ENGINE.tick(ns, 16)
    ns:setIsUnloadingBale(true)
    local half = lastBale(ns)
    local huid = half ~= nil and half:getUniqueId() or nil
    local padded = read(huid)
    BALER_MODEL.dropBale(ns)
    local dropped = read(huid)
    T.eq("P6 an unfinished round bale's portion is the 80 L its chamber and buffer gave it: UNAVAILABLE while it sits padded in the baler, READY once the drop applies the real amount",
        tostring(padded.state) .. "/" .. tostring(padded.reason) .. "/" .. tostring(dropped.state) .. "/" .. num(dropped.actualLitres) .. "/" .. num(dropped.portions[1] and dropped.portions[1].litres),
        "UNAVAILABLE/QUANTITY_MISMATCH/READY/80/80")
    W.sys.yardLadder.armed = false
    T.eq("P7 with the family off the capabilities are nil and a read is UNAVAILABLE",
        tostring(SFM.getBaleConditionCapabilities(W.mgr)) .. "/" .. tostring(read("p3").state), "nil/UNAVAILABLE")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE OWN FILE'S CODEC
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local C = MaterialDownCodec
    local src = { a = 0.1 + 0.2, big = 9007199254740991, neg = -3, yes = true, no = false, s = "x y", [5] = "five", ["5"] = "string five",
                  nested = { list = { 1, 2, { deep = "z" } }, empty = {} } }
    local h = newHandle("codec.xml")
    local okE = C.encode(h, "root", src)
    local back, why = C.decode(h, "root")
    T.eq("C1 a table round-trips exactly: %.17g numbers, the largest exact integer, booleans, strings, nested lists, and a number key apart from its string twin",
        tostring(okE) .. "/" .. tostring(why) .. "/" .. tostring(back ~= nil and back.a == src.a) .. "/" .. tostring(back ~= nil and back.big == src.big) .. "/" .. tostring(back ~= nil and back.yes == true and back.no == false)
        .. "/" .. tostring(back ~= nil and back[5]) .. "/" .. tostring(back ~= nil and back["5"]) .. "/" .. tostring(back ~= nil and back.nested.list[3].deep) .. "/" .. tostring(back ~= nil and next(back.nested.empty) == nil),
        "true/nil/true/true/true/five/string five/z/true")
    local cyc = {}
    cyc.self = cyc
    local results = {}
    for _, bad in ipairs({ cyc, { n = 0 / 0 }, { n = math.huge }, { f = function() end }, { [{}] = 1 } }) do
        local h2 = newHandle("bad.xml")
        local ok, why2 = C.encode(h2, "root", bad)
        results[#results + 1] = tostring(ok) .. ":" .. tostring(why2) .. ":" .. tostring(next(h2.data) == nil)
    end
    T.eq("C2 encoding refuses a cycle, NaN, infinity, a function and a table key, and writes nothing for any of them",
        table.concat(results, " "), "false:CYCLE:true false:NON_FINITE_VALUE:true false:NON_FINITE_VALUE:true false:UNSUPPORTED_VALUE:true false:UNSUPPORTED_KEY:true")
    local function decodeOf(data) local hh = newHandle("d.xml") hh.data = data return C.decode(hh, "r") end
    local e0 = "r.entries.entry(0)"
    local e1 = "r.entries.entry(1)"
    local cases = {
        { [e0 .. "#kt"] = "s", [e0 .. "#k"] = "a", [e0 .. "#vt"] = "s", [e0 .. "#v"] = "1", [e1 .. "#kt"] = "s", [e1 .. "#k"] = "a", [e1 .. "#vt"] = "s", [e1 .. "#v"] = "2" },
        { [e0 .. "#kt"] = "x", [e0 .. "#k"] = "a", [e0 .. "#vt"] = "s", [e0 .. "#v"] = "1" },
        { [e0 .. "#kt"] = "s", [e0 .. "#k"] = "a", [e0 .. "#vt"] = "q", [e0 .. "#v"] = "1" },
        { [e0 .. "#kt"] = "s", [e0 .. "#k"] = "a", [e0 .. "#vt"] = "b", [e0 .. "#v"] = "yes" },
        { [e0 .. "#kt"] = "s", [e0 .. "#k"] = "a", [e0 .. "#vt"] = "n", [e0 .. "#v"] = "inf" },
    }
    local reasons = {}
    for _, d in ipairs(cases) do local t, why3 = decodeOf(d) reasons[#reasons + 1] = tostring(t) .. ":" .. tostring(why3) end
    T.eq("C3 decoding refuses a repeated typed key, an unknown key tag, an unknown value tag, a malformed boolean and a non-finite number",
        table.concat(reasons, " "), "nil:REPEATED_KEY nil:UNKNOWN_KEY_TAG nil:UNKNOWN_VALUE_TAG nil:BAD_BOOLEAN nil:BAD_NUMBER_VALUE")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE ALLOCATOR AND THE ROW VALIDATOR
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    DISK = {}
    world("alloc", { valid = false })
    installAll()
    spawnBale("a1", 100)
    md().baleConditionMeta.nextTokenSerial = MaterialDown.TOKEN_SERIAL_MAX
    local n, why = md():allocateTokenSerial()
    local rows = countRows()
    spawnBale("a2", 100)
    T.eq("A1 the allocator refuses at the largest exact integer rather than wrapping, and a bale then gets no row",
        tostring(n) .. "/" .. tostring(why) .. "/" .. rows .. "/" .. countRows(), "nil/EXHAUSTED/1/1")
    md().baleConditionMeta.nextTokenSerial = 4
    local env = md():serialize()
    T.eq("A2 the validator passes the store's own rows", tostring(YardLadder.validateRows(env.objects, env.baleConditionMeta)), "true")
    local checks = {}
    local function variant(fn)
        local objs = MaterialDown.deepCopy(env.objects)
        local meta = MaterialDown.deepCopy(env.baleConditionMeta)
        fn(objs, meta)
        local ok, why2 = YardLadder.validateRows(objs, meta)
        checks[#checks + 1] = tostring(ok) .. ":" .. tostring(why2)
    end
    variant(function(_, meta) meta.nextTokenSerial = 1 end)
    variant(function(objs) objs.yl_1.portions[1].litres = 50 end)
    variant(function(objs) objs.yl_1.nativeBaleUniqueId = nil end)
    variant(function(objs) objs.yl_1.rowRevision = 1.5 end)
    variant(function(objs) objs.yl_1.portions[1].historyKnowledge = "MAYBE" end)
    variant(function(objs) objs.yl_1.carrierState = nil objs.yl_1.schema = nil end)
    T.eq("A3 the validator refuses a token above the allocator, portions that disagree with the observed litres, a bound row with no native id, a fractional counter, an unknown knowledge and a legacy row claiming a binding",
        table.concat(checks, " "),
        "false:TOKEN_ABOVE_ALLOCATOR false:PORTIONS_DISAGREE false:NO_NATIVE_ID false:ROW_COUNTERS false:PORTION_knowledge false:LEGACY_ROW_BOUND")
end)
end
F215_BENCH()
