-- MAINT-145-swath_landed_litres_spec_test.lua
--
-- MAINTENANCE row 145 (Bob's intake: Desk Office/Drafts/BOB-INTAKE-ROW145-SWATH-LANDED-
-- LITRES-2026-09-25.md). The generic straw birth (noteMaterialAt, when no ground-condition
-- carrier owns the combine's deposit) gated on processCombineSwathArea's first return, which
-- is the engine's 1/0 REQUEST flag (Combine.lua:757), so a pass whose tip landed 0 L still
-- recorded material. It now reads the litres the tip actually dropped, through a
-- litres-only GroundNativeObserver frame opened around the native call: no litres, no
-- record; and no observer, no record.
--
-- THE ENTRY-POINT BAR IS GROUP L. Production's installAll wraps a combine's captured swath
-- pointer; the swath hook installs the real observer itself; the combine's
-- processCombineSwathArea is the verbatim port (RSF-F208-s3-engine_model.lua, Combine.lua
-- :731-758) and the util's tip returns the litres its modeled height plane actually took
-- (full pixels take nothing). MaterialDown is armed and the ground family unarmed, so no
-- carrier frame owns the deposit, as on a save without the family. Nothing here writes a
-- birth, a frame or a litre.
--
-- Groups:
--   L  the entry point: a landed pass births and says how much landed; a pass whose tip
--      lands 0 L births nothing though it asked; a throw closes the light frame and
--      re-raises; no observer, no birth, and the first-run line says why; a carrier frame
--      open means no light frame; the light branch reads no cells
--   O  the observer's litres-only frame itself: two tips add up, a pickup adds nothing
--
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua

local INFO, DEBUG, WARN = {}, {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function(fmt, ...) DEBUG[#DEBUG + 1] = string.format(fmt, ...) end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local FT = ENGINE.FT
local O, C = GroundNativeObserver, GroundMovementCarrier

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

-- ── the world (RSF-F212's, trimmed to the combine) ──────────────────────────
local W = {}
local PRISTINE = { combineStart = Combine.onStartWorkAreaProcessing, combineEnd = Combine.onEndWorkAreaProcessing }
--- A fresh engine and production's system; the ground family armed only with opts.armed.
local function world(today, opts)
    opts = opts or {}
    HEIGHT.pixels = {}
    HEIGHT.throwNext, HEIGHT.throwOnDrop = false, false
    Combine.onStartWorkAreaProcessing, Combine.onEndWorkAreaProcessing = PRISTINE.combineStart, PRISTINE.combineEnd
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm = ENGINE.newValueMaps()
    W.sys = sys
    g_currentMission = { environment = { currentMonotonicDay = today }, vehicleSystem = { vehicles = {} } }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.materialDown.ageAppliedThroughDay = today
    sys.materialWetness.appliedThroughDay = today
    sys.hookManager.getFieldIdAtWorldPosition = function() return 7 end
    if not opts.armed then return true end
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    return a and b and c
end
--- A combine in the mission's vehicle list, its swath line x 0..8 at z = 6, wheat in the
--- straw buffer, `liters` of it waiting to drop.
local function combineInWorld(uid, liters)
    local v, swath = ENGINE.newCombine({ uid = uid, swathZ = 6 })
    v.buffer.liters = liters
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    return v, swath
end
local function installAll() return pcall(W.sys.hookManager.installAll, W.sys.hookManager, W.sys) end
local function births() return W.sys.materialDown.births end
local function last(list, needle)
    local found = nil
    for _, line in ipairs(list) do if line:find(needle, 1, true) then found = line end end
    return found
end

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE ENTRY POINT
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    -- A pass that lands its straw.
    world(100)
    local v, swath = combineInWorld("landed", 300)
    local okAll, errAll = installAll()
    T.ok("L1 [reached] installAll wrapped the combine's captured swath pointer and the swath hook installed the observer",
        okAll and swath.processingFunction ~= Combine.processCombineSwathArea and O.isInstalled(), tostring(errAll))
    local lightBefore, cellsBefore, framesBefore = O.stats.litresOnly, O.stats.cellsRead, C.stats.frames
    ENGINE.tick(v, 16)
    local b = births()
    T.eq("L2 [world] 300 L of straw landed natively, and the generic birth recorded STRAW on field 7, once",
        num(HEIGHT.total(FT.STRAW)) .. "/" .. #b .. "/" .. tostring(b[1] and b[1].name) .. "/" .. tostring(b[1] and b[1].fieldId), "300/1/STRAW/7")
    T.eq("L3 its debug line reads the litres that landed", tostring(last(DEBUG, "[SwathHook] straw birth")), "[SwathHook] straw birth: field 7, STRAW, 300.0L landed")
    T.eq("L4 one litres-only tip, no carrier frame, no cell read, and the observer at rest",
        tostring(O.stats.litresOnly - lightBefore) .. "/" .. tostring(C.stats.frames - framesBefore) .. "/" .. tostring(O.stats.cellsRead - cellsBefore) .. "/" .. tostring(O.isAtRest()),
        "1/0/0/true")

    -- A pass that asked but landed nothing: the swath line's pixels are already full.
    world(100)
    local v0 = combineInWorld("full", 300)
    installAll()
    HEIGHT.fill(FT.STRAW, -2, 3, 11, 10, ENGINE.PIXEL_CAP)
    local before = HEIGHT.total(FT.STRAW)
    local requested = v0.buffer.liters
    ENGINE.tick(v0, 16)
    T.eq("L5 a pass that asked for 300 L but whose tip landed 0 L records no birth",
        num(requested) .. "/" .. num(HEIGHT.total(FT.STRAW) - before) .. "/" .. #births(), "300/0/0")

    -- A throw inside the native tip.
    world(100)
    local vt = combineInWorld("throw", 300)
    installAll()
    HEIGHT.throwOnDrop = true
    local okT, errT = pcall(ENGINE.tick, vt, 16)
    T.eq("L6 a throw inside the tip reaches the caller unchanged, the light frame is closed and nothing is born",
        tostring(okT) .. "/" .. tostring(tostring(errT):find("native tip failed", 1, true) ~= nil) .. "/" .. tostring(O.isAtRest()) .. "/" .. #births(),
        "false/true/true/0")

    -- No observer: the litres cannot be read, so nothing is born, and the first-run line says why.
    world(100)
    local vn = combineInWorld("unobserved", 300)
    installAll()
    O.uninstall()
    ENGINE.tick(vn, 16)
    T.eq("L7 with no observer installed the landed pass records no birth (an unknown amount is no record)",
        num(HEIGHT.total(FT.STRAW)) .. "/" .. #births(), "300/0")
    T.ok("L8 the first-run line says the observer is not installed", (last(INFO, "[SwathHook] FIRST EXECUTION") or ""):find("the ground observer is not installed", 1, true) ~= nil,
        tostring(last(INFO, "[SwathHook] FIRST EXECUTION")))

    -- The ground family armed: the carrier owns the deposit, and no light frame opens.
    T.ok("L9a [world] the family arms in production's order", world(100, { armed = true }) == true)
    local vc = combineInWorld("carried", 300)
    installAll()
    local lightC, framesC = O.stats.litresOnly, C.stats.frames
    ENGINE.tick(vc, 16)
    T.eq("L9 with a STRAW carrier frame open no litres-only frame opens, the carrier ran and the generic birth stood down",
        tostring(O.stats.litresOnly - lightC) .. "/" .. tostring(C.stats.frames - framesC) .. "/" .. #births() .. "/" .. tostring(O.isAtRest()), "0/1/0/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- O. THE OBSERVER'S LITRES-ONLY FRAME
-- ══════════════════════════════════════════════════════════════════════════
group("O", function()
    world(100)
    local v = combineInWorld("frame", 0)
    installAll()
    local cellsBefore = O.stats.cellsRead
    local light = O.open({ owner = v, litresOnly = true, litres = 0 })
    DensityMapHeightUtil.tipToGroundAroundLine(v, 120, FT.STRAW, 0, 0, 20, 8, 0, 20, 0, nil, 0, false, nil, false)
    DensityMapHeightUtil.tipToGroundAroundLine(v, 80, FT.STRAW, 0, 0, 30, 8, 0, 30, 0, nil, 0, false, nil, false)
    local afterTwo = light.litres
    DensityMapHeightUtil.tipToGroundAroundLine(v, -math.huge, FT.STRAW, 0, 0, 20, 8, 0, 20, 0, nil, 0, false, nil, false)
    O.close(light)
    T.eq("O1 two tips in one frame add up to the litres both landed; a pickup (a negative return) adds nothing",
        num(afterTwo) .. "/" .. num(light.litres), "200/200")
    T.eq("O2 the litres-only frame read no cell and left the observer at rest", tostring(O.stats.cellsRead - cellsBefore) .. "/" .. tostring(O.isAtRest()), "0/true")
    -- Another vehicle's tip under this frame is not counted.
    local other = combineInWorld("other", 0)
    local light2 = O.open({ owner = v, litresOnly = true, litres = 0 })
    DensityMapHeightUtil.tipToGroundAroundLine(other, 50, FT.STRAW, 0, 0, 40, 8, 0, 40, 0, nil, 0, false, nil, false)
    O.close(light2)
    T.eq("O3 a tip by another vehicle is not counted in this frame", num(light2.litres), "0")
end)
