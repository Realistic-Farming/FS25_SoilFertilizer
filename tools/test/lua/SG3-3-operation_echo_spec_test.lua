-- SG3-3-operation_echo_spec_test.lua
--
-- SG-3 Part 3, Soil's half (RSF-F215 v1.1, discharging DESIGN-CHECK row 126's WITHHELD echo; Bob's R-15,
-- Desk Office/Drafts/BOB-R15-SG3-PART3-SOIL-BALE-CONDITION-2026-10-08.md): YardLadder echoes the StockGuard
-- operation open around a BIRTH, a REBIND and a RETIRE in the listeners' events (YardLadder._openOperationId,
-- read from g_currentMission.stockGuard.readOpenOperation, delegate-when-present). ADVANCE never carries one.
--
-- THE ENTRY-POINT BAR IS GROUP E. RSF-F215 S7's world, VERBATIM in its parts (production's system, the
-- owners armed in production's order, HookManager:installAll with the Baler collection and the Bale.register
-- birth door, a Baler built and processed as the engine does making a bale through the real createBale), so
-- the BIRTH arrives through BC.aroundCreate, the production door, not a hand call. StockGuard is the other
-- mod: its handle on the mission and its bracket on the Baler's finishBale instance copy are stand-ins of
-- the shape StockGuard ships (SGGroundObserver aroundFinish: push the open operation immediately before the
-- original, pop immediately after it; readOpenOperation answers the innermost, a colon call refuses).
--
--   E1  a square baler's finish under an open StockGuard operation: the BIRTH carries that operation in its
--       before and its after
--   E2  no StockGuard handle on the mission: the BIRTH carries none (today's behaviour), the bale still born
--   E3  a handle but no open bracket (a bale through another door): none
--   R1  into object storage, out of it, and a RETIRE, each while an operation is open: each carries it
--   A1  a ladder ADVANCE while an operation is open: carries none
--   G1  a read that throws, answers a non-table or an empty id, or refuses a colon: none, the change done
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, tools/test/lua/RSF-F211-s6b-baler_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/PolygonClip.lua, src/utils/SoilUtils.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/HayBet.lua, src/YardLadder.lua, src/integrations/MaterialDownCodec.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua, src/ground/BalerCollection.lua, src/ground/ForageWagonCollection.lua, src/SoilFertilityManager.lua

-- The whole bench runs inside one function: the sources it loads are concatenated into one chunk, and their
-- file-level locals with this file's would pass Lua's 200-local limit for a single function.
local function ECHO_BENCH()
local WARN = {}
SoilLogger.info = function() end
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

-- ── RSF-F215 S7's disk and world, verbatim in their parts ───────────────────
local DISK = {}
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
function hasXMLProperty(h, p)
    for k in pairs(h.data) do
        if k == p or k:sub(1, #p + 1) == p .. "#" or k:sub(1, #p + 1) == p .. "." then return true end
    end
    return false
end
local EPOCHS = 0
Utils = Utils or {}
Utils.getUniqueId = function(_value, _map, prefix, _len) EPOCHS = EPOCHS + 1 return (prefix or "") .. "epoch" .. EPOCHS end
function entityExists(_node) return true end
function getWorldTranslation(_node) return 0, 0, 0 end
SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end
local W = {}
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
local STORE_CLASS = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"]
local PRISTINE = { register = Bale.register, start = Baler.onStartWorkAreaProcessing, finish = Baler.onEndWorkAreaProcessing,
                   fill = Baler.onFillUnitFillLevelChanged, delete = Bale.delete, tick = Baler.onUpdateTick,
                   store = STORE_CLASS.addToStorage }
local function world(dir)
    HEIGHT.pixels = {}
    BALER_MODEL.failLoad, BALER_MODEL.onRegister = false, nil
    Bale.register, Bale.delete = PRISTINE.register, PRISTINE.delete
    Baler.onStartWorkAreaProcessing, Baler.onEndWorkAreaProcessing = PRISTINE.start, PRISTINE.finish
    Baler.onFillUnitFillLevelChanged, Baler.onUpdateTick = PRISTINE.fill, PRISTINE.tick
    STORE_CLASS.addToStorage = PRISTINE.store
    MDB.ledgerActive = false
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet = ENGINE.newValueMaps()
    vm.applyRawDeltaToLayer = function() return nil end
    vm.setPolygonWhere = function() return false end
    vm.hasAnyInBand = function() return nil end
    W.sys, W.vm, W.age, W.wet, W.mgr = sys, vm, age, wet, { soilSystem = sys }
    local today = 100
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = ENGINE.newVehicleSystem(),
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function() return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
        missionInfo = { savegameDirectory = dir, isValid = false, xmlFile = newHandle(dir .. "/careerSavegame.xml") },
    }
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    local okMd = sys.materialDown:arm(vm)
    sys.materialDown.ageAppliedThroughDay = today
    local okMw = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    local okHb = sys.hayBet:arm(sys.materialDown, sys.materialWetness)
    local okYl = sys.yardLadder:arm(sys.materialDown, sys.materialWetness, sys.hayBet)
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    MDB.beginLoad(sys.materialDown)
    MDB.loadFallback(sys.materialDown)
    return (okMd and okMw and okHb and okYl and a and b and c) == true
end
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
local function spawnBale(uid, litres, farmId)
    local b = Bale.new(true, false)
    b:loadFromConfigXML("bale.xml", 0, 0, 0, 0, 0, 0, uid)
    b:setFillType(FT.STRAW or GR)
    b:setFillLevel(litres or 100)
    b:setOwnerFarmId(farmId or 1)
    b:register()
    return b
end
local function read(uid) return SFM.getBaleConditionPortions(W.mgr, uid) end
--- An SG-3 stand-in listener: records every before and after.
local function recorder()
    local rec = { events = {} }
    rec.callbacks = {
        beforeChange = function(ev) rec.events[#rec.events + 1] = { phase = "before", ev = ev } return { n = #rec.events } end,
        afterChange = function(ev, ticket) rec.events[#rec.events + 1] = { phase = "after", ev = ev, ticket = ticket } end,
        invalidate = function() end,
    }
    return rec
end

-- ── StockGuard, the other mod: its handle and its finish bracket (stand-ins of the shipped shape) ────────
local OPEN = {}
local function stockGuardHandle(read)
    local h = {}
    h.readOpenOperation = read or function(...)
        if select("#", ...) > 0 and select(1, ...) == h then return nil, "CALLED_WITH_COLON" end
        local top = OPEN[#OPEN]
        return top ~= nil and { operationId = top } or nil
    end
    return h
end
--- StockGuard's aroundFinish on the Baler's finishBale instance copy: the operation pushed immediately
--- before the original, popped immediately after it, whatever the original did.
local function bracketFinish(v, operationId)
    local original = v.finishBale
    v.finishBale = function(self, ...)
        OPEN[#OPEN + 1] = operationId
        local r = table.pack(pcall(original, self, ...))
        table.remove(OPEN)
        if not r[1] then error(r[2], 0) end
        return table.unpack(r, 2, r.n)
    end
end
local function within(operationId, fn)
    OPEN[#OPEN + 1] = operationId
    local r = table.pack(pcall(fn))
    table.remove(OPEN)
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
end
--- The operation ids the recorded events carry, "kind:before/after", from event `from` on.
local function echoes(rec, from, to)
    local out = {}
    for i = (from or 0) + 1, to or #rec.events do
        local e = rec.events[i]
        out[#out + 1] = e.phase .. " " .. tostring(e.ev.kind) .. "=" .. tostring(e.ev.operationId)
    end
    return table.concat(out, ", ")
end
--- A square bale made by a baler: the windrow cells, the tick that fills its chamber to capacity and
--- finishes the bale through the real createBale.
local function baleOne(v)
    setCell(2, 8, 1, 204) windrow(2, 5)
    setCell(3, 8, 1, 52)  windrow(3, 45)
    ENGINE.tick(v, 16)
    return lastBale(v)
end

group("E", function()
    DISK, OPEN = {}, {}
    T.ok("E0 [world] RSF-F215 S7's world: the owners arm in production's order", world("echo1"))
    g_currentMission.stockGuard = stockGuardHandle()
    local okI = installAll()
    yl():onMissionStarted()
    local rec = recorder()
    SFM.registerBaleConditionListener(W.mgr, "sg3", rec.callbacks)
    local v = baler({ capacity = 100 })
    bracketFinish(v, "op:1:7")
    local bale = baleOne(v)
    local uid = bale ~= nil and bale:getUniqueId() or nil
    T.eq("E1 [entry point] NAMED (SG-3 Part 3): a square baler's finish under an open StockGuard operation; the BIRTH, through BC.aroundCreate and the real createBale, carries that operation in its before and its after",
        tostring(okI) .. " " .. echoes(rec) .. " " .. tostring(read(uid).state) .. " " .. #OPEN, "true before BIRTH=op:1:7, after BIRTH=op:1:7 READY 0")

    DISK, OPEN = {}, {}
    world("echo2")
    installAll()
    yl():onMissionStarted()
    local rec2 = recorder()
    SFM.registerBaleConditionListener(W.mgr, "sg3", rec2.callbacks)
    local v2 = baler({ capacity = 100 })
    bracketFinish(v2, "op:1:8")
    local bale2 = baleOne(v2)
    T.eq("E2 no StockGuard handle on the mission: the same BIRTH carries no operation (today's behaviour), and the bale is born READY",
        echoes(rec2) .. " " .. tostring(read(bale2 and bale2:getUniqueId()).state), "before BIRTH=nil, after BIRTH=nil READY")

    g_currentMission.stockGuard = stockGuardHandle()
    local mark = #rec2.events
    spawnBale("door", 100)
    T.eq("E3 a handle but no open bracket (a bale through another door): its BIRTH carries no operation", echoes(rec2, mark),
        "before BIRTH=nil, after BIRTH=nil")
end)

group("R", function()
    DISK, OPEN = {}, {}
    world("echo3")
    g_currentMission.stockGuard = stockGuardHandle()
    installAll()
    yl():onMissionStarted()
    local rec = recorder()
    SFM.registerBaleConditionListener(W.mgr, "sg3", rec.callbacks)
    local b = spawnBale("r1", 100)
    local mark = #rec.events
    local held = within("op:2:1", function() return BALER_MODEL.storeBale({ isServer = true, isClient = false }, b) end)
    local mark2 = #rec.events
    local out = within("op:2:2", function() return held:removeFromStorage({ isServer = true, isClient = false }, 0, 0, 0, 0, 0, 0) end)
    local mark3 = #rec.events
    within("op:2:3", function() out:delete() end)
    T.eq("R1 into object storage, out of it, and a RETIRE, each while an operation is open: each REBIND and the RETIRE carry it",
        echoes(rec, mark, mark2) .. " | " .. echoes(rec, mark2, mark3) .. " | " .. echoes(rec, mark3),
        "before REBIND=op:2:1, after REBIND=op:2:1 | before REBIND=op:2:2, after REBIND=op:2:2 | before RETIRE=op:2:3, after RETIRE=op:2:3")
end)

group("A", function()
    DISK, OPEN = {}, {}
    world("echo4")
    g_currentMission.stockGuard = stockGuardHandle()
    installAll()
    yl():onMissionStarted()
    local rec = recorder()
    SFM.registerBaleConditionListener(W.mgr, "sg3", rec.callbacks)
    spawnBale("a1", 100)
    local mark = #rec.events
    within("op:3:1", function() yl():onLadderPass({ monotonicDay = 101, boundariesCrossed = 1 }) end)
    T.eq("A1 a ladder ADVANCE while an operation is open carries none: ADVANCE is SG-3's route 2", echoes(rec, mark),
        "before ADVANCE=nil, after ADVANCE=nil")
end)

group("G", function()
    local cases = {
        { "throws", function() error("sg boom") end },
        { "a non-table", function() return "op:9:9" end },
        { "an empty id", function() return { operationId = "" } end },
        { "a number id", function() return { operationId = 7 } end },
    }
    local got = {}
    for _, c in ipairs(cases) do
        DISK, OPEN = {}, {}
        world("echo-g")
        g_currentMission.stockGuard = stockGuardHandle(c[2])
        installAll()
        yl():onMissionStarted()
        local rec = recorder()
        SFM.registerBaleConditionListener(W.mgr, "sg3", rec.callbacks)
        -- Each case's birth in its own pcall, so a read that escapes is this row's failure, not the group's.
        local okB, bornB = pcall(spawnBale, "g", 100)
        local state = okB and tostring(read(bornB:getUniqueId()).state) or "RAISED"
        got[#got + 1] = c[1] .. ":" .. tostring(rec.events[2] and rec.events[2].ev.operationId) .. "/" .. state
    end
    T.eq("G1 a read that throws, or answers a non-table, an empty id or a number: no operation, and the BIRTH is done",
        table.concat(got, " "), "throws:nil/READY a non-table:nil/READY an empty id:nil/READY a number id:nil/READY")
    local h = stockGuardHandle()
    OPEN = { "op:4:1" }
    local viaColon = { h:readOpenOperation() }
    local viaDot = h.readOpenOperation()
    OPEN = {}
    T.eq("G2 (the stand-in's shape, as StockGuard's handle answers: a dot call reads the innermost, a colon call refuses)",
        tostring(viaColon[1]) .. "/" .. tostring(viaColon[2]) .. " " .. tostring(viaDot and viaDot.operationId), "nil/CALLED_WITH_COLON op:4:1")
end)
end
ECHO_BENCH()
