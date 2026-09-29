-- overlap_own_pass_grace_test.lua
--
-- Overlap prevention must never switch off a section over ground its OWN current
-- pass sprayed, and must still switch it off over ground sprayed on an earlier pass.
--
-- THE DEFECTS THIS PINS (upstream development e04ae9e8):
--   1. The "centre cell" rule. A section with no tip node, or whose tip fell in the
--      same 10 m cell as the vehicle root, was suppressed on ANY stamp, with no
--      grace, on the premise that the root cell is always unstamped ahead of the
--      boom. It is not: the boom sits 0.46 m (Hardi Mega 1200L) to 4.8 m (Agrio
--      Dino II) behind the root, and markBoomCells stamps the root cell every tick.
--      On the first lane of a never-sprayed field the centre and inner sections
--      were off for all but ~0.5 m of every 10 m.
--   2. The grace was TIME (10 s). Standing still or crawling aged the pass's own
--      stamps and switched sections off one after another.
-- The rule is now distance driven (HookManager.isCellSprayedEarlier): a stamp by
-- another vehicle counts at once, a stamp by this vehicle counts once it has driven
-- 15 m + boom half-width + boom offset past it (HookManager.computeOverlapBoomGeometry).
--
-- The integration cases drive the REAL preserver + overlap hook (and the real
-- fieldBoundaryControl copy in installSectionControlHook), and stamp through the
-- REAL production writer: installSprayerAreaHook's append on onEndWorkAreaProcessing,
-- which calls the REAL getBoomCellPositions sweep and the REAL markBoomCells with the
-- stamping vehicle. The stamp's `by` and `odo` are what the rule reads, so a fixture
-- that stamped by hand would supply the very vehicle production is meant to supply
-- (P1-P4 pin that). The sprayer is laid out like the Hardi Mega 1200L
-- (mega1200L.xml/.i3d): 9 sections, tips at +-3.5/6/9/12 m, an isCenter section with
-- no node, boom line 0.46 m behind root.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = {
    Sprayer = Sprayer, Utils = Utils, g_fillTypeManager = g_fillTypeManager,
    g_currentMission = g_currentMission, g_SoilFertilityManager = g_SoilFertilityManager,
    g_effectManager = g_effectManager, g_fieldManager = g_fieldManager,
    getWorldTranslation = getWorldTranslation, FillType = FillType, ToolType = ToolType,
    VehicleSystem = VehicleSystem,
}

g_effectManager = { startEffects = function() end, stopEffects = function() end }
g_fieldManager = nil   -- no polygon: markBoomCells counts every cell
FillType = FillType or { UNKNOWN = 0, FERTILIZER = 42 }
ToolType = ToolType or { UNDEFINED = 0 }
Utils = {
    prependedFunction = function(orig, new)
        return function(...) new(...) if orig then return orig(...) end end
    end,
    appendedFunction = function(orig, new)
        return function(...)
            local r = orig and { orig(...) } or {}
            new(...)
            return unpack(r)
        end
    end,
}
g_fillTypeManager = {
    getFillTypeByName = function(_, n)
        if n == "FERTILIZER" then return { index = 42, name = "FERTILIZER" } end
        return nil
    end,
    getFillTypeByIndex = function(_, i)
        if i == 42 then return { index = 42, name = "FERTILIZER" } end
        return nil
    end,
}

-- World positions of every node the hooks read, rebuilt by place().
local POS = {}
getWorldTranslation = function(n)
    local p = POS[n]
    if p == nil then error("no such node " .. tostring(n)) end
    return p[1], 0, p[2]
end

local GRACE_BASE = SoilConstants.ZONE.OVERLAP_GRACE_M
local HARDI_LAT = { -12, -9, -6, -3.5, false, 3.5, 6, 9, 12 }   -- false = isCenter, no node
local BOOM_FWD = -0.46

-- ── Pure rule: HookManager.isCellSprayedEarlier ────────────────────────────
do
    local me, other = { _sfOdoM = 100 }, {}
    T.eq("R1 no stamp is not sprayed", HookManager.isCellSprayedEarlier(nil, me, 27), false)
    T.eq("R2 own stamp 10 m ago (inside the grace) is this pass, not sprayed earlier",
         HookManager.isCellSprayedEarlier({ odo = 90, by = me }, me, 27), false)
    T.eq("R3 own stamp 30 m ago (past the grace) is an earlier pass",
         HookManager.isCellSprayedEarlier({ odo = 70, by = me }, me, 27), true)
    T.eq("R4 another vehicle's stamp counts at once, however recent",
         HookManager.isCellSprayedEarlier({ odo = 100, by = other }, me, 27), true)
    T.eq("R5 a stamp with no distance (legacy / foreign value) counts at once",
         HookManager.isCellSprayedEarlier(123, me, 27), true)
end

-- ── Pure geometry: HookManager.computeOverlapBoomGeometry ─────────────────
local function hardiTips(rx, rz, hx, hz)
    local px, pz = hz, -hx          -- lateral unit (right of travel)
    local tips = {}
    for i, lat in ipairs(HARDI_LAT) do
        if lat then
            tips[i] = { rx + lat * px + BOOM_FWD * hx, rz + lat * pz + BOOM_FWD * hz }
        end
    end
    return tips
end
do
    local cx, cz, g = HookManager.computeOverlapBoomGeometry(hardiTips(100, 100, 0, 1), 100, 100, GRACE_BASE)
    T.near("G1 Hardi: grace = 15 + half-width 12 + offset 0.46", g, GRACE_BASE + 12 + 0.46, 1e-6)
    T.near("G2 Hardi: boom-line centre sits 0.46 m behind the root (x)", cx, 100, 1e-6)
    T.near("G3 Hardi: boom-line centre sits 0.46 m behind the root (z)", cz, 100 - 0.46, 1e-6)
    local s = math.sqrt(0.5)
    local _, _, g45 = HookManager.computeOverlapBoomGeometry(hardiTips(100, 100, s, s), 100, 100, GRACE_BASE)
    T.near("G4 the grace does not depend on heading", g45, GRACE_BASE + 12 + 0.46, 1e-6)
    local nx, nz, g0 = HookManager.computeOverlapBoomGeometry({}, 100, 100, GRACE_BASE)
    T.ok("G5 no tips: no centre, base grace", nx == nil and nz == nil and g0 == GRACE_BASE)
end

-- ── Integration harness ────────────────────────────────────────────────────
local function newWorld(settings, multiTank)
    -- markBoomCells and trackSprayerCoverage are the REAL ones (through __index):
    -- trackSprayerCoverage's product-change reset (#442) decides whose stamps survive.
    -- The credit append's other downstream calls never touch the session cells and
    -- are stubbed. The append stamps only after an application it credited, so
    -- onFertilizerApplied says yes.
    local ss = setmetatable({
        fieldData = { [7] = { fieldArea = 1000, sessionCoverageCells = {}, dailyCoverageCells = {},
                              zoneData = {}, sessionCoverageFraction = 0 } },
        onFertilizerApplied = function() return true end,
        paintBoomStrip = function() end,
        applyBurnEffect = function() end,
        applyScorchEffect = function() end,
    }, { __index = SoilFertilitySystem })
    g_SoilFertilityManager = {
        settings = settings,
        soilSystem = ss,
        sensorManager = {},
    }
    local hookMgr = setmetatable({
        hooks = {}, register = function() end, registerCleanup = function() end,
        getFieldIdAtWorldPosition = function() return 7 end,
        getTargetApplication = function() return nil end,
        getBoomLineEndpoints = function() return nil end,   -- engine localToLocal; paint is stubbed
        _sectionScratch = {}, _settings = { multiTankApplication = multiTank == true },
        customFillTypePrices = {}, customProductIndices = {}, refusedProducts = {},
    }, { __index = HookManager })
    return ss, hookMgr
end

local function newHardi(multiTank)
    local v = {
        isServer = true, id = "hardi", rootNode = "root",
        spec_variableWorkWidth = { sections = {} },
        spec_workArea = { workAreas = { {
            start = "waS", width = "waW", height = "waH",
            functionName = "processSprayerArea",
        } } },
        -- What the credit append reads to decide the pass put product down.
        getIsTurnedOn = function() return true end,
        getLastSpeed = function(self) return math.abs(self.lastSpeed or 0) * 3600 end,
        getSprayerFillUnitIndex = function() return 1 end,
        getFillUnitFillLevel = function() return 900 end,
        getFillUnitFillType = function() return 42 end,
        getOwnerFarmId = function() return 1 end,
        addFillUnitFillLevel = function() return 0 end,
    }
    v.spec_workArea.workAreas[1].processingFunction = function() return 1, 1 end
    v.processSprayerArea = v.spec_workArea.workAreas[1].processingFunction
    for i, lat in ipairs(HARDI_LAT) do
        v.spec_variableWorkWidth.sections[i] = {
            isActive = true, effects = {},
            isCenter = (lat == false) or nil,
            maxWidthNode = lat and ("mw" .. i) or nil,
        }
    end
    v.spec_sprayer = { workAreaParameters = { sprayFillType = 42, usage = 1, sprayFillLevel = 900 },
                       effects = {}, sprayTypes = {} }
    if multiTank then
        -- A second tank of the same fertilizer: the append credits and stamps it in its
        -- multi-tank block (the driving unit is excluded by identity), BEFORE the
        -- driving tank's own stamp, so the first stamp of each cell comes from the
        -- multi-tank markBoomCells call. The same product on purpose, so the case does
        -- not depend on how trackSprayerCoverage handles a product change within a tick
        -- (the #442 reset, which MAINT-169's _multiTankCoverageHold now holds off
        -- during the multi-tank replay).
        local wap = v.spec_sprayer.workAreaParameters
        wap.sprayVehicle, wap.sprayVehicleFillUnitIndex = v, 1
        v.spec_fillUnit = { fillUnits = { { fillLevel = 900, fillType = 42 },
                                          { fillLevel = 900, fillType = 42 } } }
    end
    return v
end

-- Put the sprayer at root (rx, rz) heading (hx, hz) (unit vector).
-- boomFwd: boom line relative to the root along travel (Hardi -0.46, Dino II -4.6).
local boomFwd = BOOM_FWD
local function place(rx, rz, hx, hz)
    local px, pz = hz, -hx
    POS.root = { rx, rz }
    local function at(lat, fwd) return { rx + lat * px + fwd * hx, rz + lat * pz + fwd * hz } end
    for i, lat in ipairs(HARDI_LAT) do
        if lat then POS["mw" .. i] = at(lat, boomFwd) end
    end
    POS.waS = at(12, boomFwd); POS.waW = at(-12, boomFwd); POS.waH = at(12, boomFwd - 0.14)
end

-- One tick as the game runs it: start processing (preserver prepend, overlap prepend),
-- the engine's paint through the work area's processing function, end processing
-- (the credit append stamps this tick's boom, then the restore appends).
-- Returns the set of sections switched off by either overlap check this tick, and
-- whether the pass was blocked: the flag, or the permanent gate on the work area
-- refusing the call (the fixture's processor returns 1, the gate's refusal 0).
local function tick(v, ss, hookMgr, dtMs)
    g_currentMission.time = g_currentMission.time + dtMs
    Sprayer.onStartWorkAreaProcessing(v, dtMs)
    local off = {}
    for i in pairs(v._sfOverlapSuppressedSections or {}) do off[i] = true end
    for i in pairs(v._sfSuppressedSections or {}) do off[i] = true end
    local wa = v.spec_workArea.workAreas[1]
    local xs = wa.processingFunction(v, wa, dtMs)
    local blocked = v._sfOverlapBlockedPass == true or xs == 0
    Sprayer.onEndWorkAreaProcessing(v, dtMs, true)
    return off, blocked
end

-- Install order as the mod does it: the sprayer overlap gate (right after harvest),
-- the credit append, then the overlap check, then the preserver last so its prepend
-- runs first. The Hardi is registered through the gate's production route, the
-- colon call Vehicle.lua:1044 makes on a Class-instance vehicle system.
local function install(which, settings, multiTank)
    Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 1, 1 end }
    VehicleSystem = { addVehicle = function(_self, _vehicle) return true end }
    g_currentMission = { time = 0, vehicleSystem = setmetatable({ vehicles = {} }, { __index = VehicleSystem }) }
    local ss, hookMgr = newWorld(settings, multiTank)
    HookManager.installSprayerOverlapGate(hookMgr)
    HookManager.installSprayerAreaHook(hookMgr)
    if which == "overlap" then
        HookManager.installOverlapPreventionHook(hookMgr)
    else
        HookManager.installSectionControlHook(hookMgr)
    end
    HookManager.installSectionStatePreserver(hookMgr)
    local v = newHardi(multiTank)
    g_currentMission.vehicleSystem:addVehicle(v)
    return ss, hookMgr, v
end

-- Every stamp in the field: count, and how many carry this sprayer and a distance.
local function stampCensus(ss, v)
    local n, byMe, withOdo = 0, 0, 0
    for _, st in pairs(ss.fieldData[7].sessionCoverageCells) do
        n = n + 1
        if type(st) == "table" and st.by == v then byMe = byMe + 1 end
        if type(st) == "table" and type(st.odo) == "number" then withOdo = withOdo + 1 end
    end
    return n, byMe, withOdo
end

local function list(set)
    local t = {}
    for i in pairs(set) do t[#t + 1] = i end
    table.sort(t)
    return table.concat(t, ",")
end

-- Drive a straight lane at 12 km/h (3.33 m/s), 0.5 m per tick. Returns the union of
-- sections switched off anywhere on the lane, and the sprayer/world for follow-ups.
local function driveLane(v, ss, hookMgr, x0, z0, hx, hz, metres, acc)
    acc = acc or {}
    local step, dt = 0.5, 150
    v.movingDirection = 1
    v.lastSpeed = 12 / 3600
    for s = 0, metres, step do
        place(x0 + s * hx, z0 + s * hz, hx, hz)
        for i in pairs(tick(v, ss, hookMgr, dt)) do acc[i] = true end
    end
    return acc
end

local OVERLAP_ON = { enabled = true, overlapPrevention = true, fieldBoundaryControl = false,
                     debugMode = false }

-- ── L: the first lane of a never-sprayed field ─────────────────────────────
do
    -- Start the lane mid-cell (x = 4) so the root cell holds inner-section tips,
    -- the layout that switched the centre and inner sections off before.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    local off = driveLane(v, ss, hookMgr, 4, 3, 0, 1, 60)
    T.eq("L1 first lane, north: no section is ever switched off", list(off), "")
    local n, byMe, withOdo = stampCensus(ss, v)
    T.ok("L1b and the lane really was stamped (the check had cells to look at)", n > 0)
    -- P1/P2: the stamps came from the production credit append (the bar never stamps
    -- by hand). If that append stopped passing its vehicle, every stamp would read
    -- as another vehicle's and every section would switch off on this first lane.
    T.eq("P1 every stamp was written by the production append with this sprayer (by == v)", byMe, n)
    T.eq("P2 and every stamp carries the sprayer's driven distance (numeric odo)", withOdo, n)

    local ss2, hookMgr2, v2 = install("overlap", OVERLAP_ON)
    local s = math.sqrt(0.5)
    local off2 = driveLane(v2, ss2, hookMgr2, 4, 3, s, s, 60)
    T.eq("L2 first lane on a 45 degree heading: no section is ever switched off", list(off2), "")
end

-- ── P: the multi-tank credit path stamps with the vehicle too ──────────────
do
    -- A second tank (same product, see newHardi) is credited and stamped in the
    -- append's multi-tank block, before the driving tank's stamp, so the first stamp
    -- of every cell comes from that block's markBoomCells call.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON, true)
    local off = driveLane(v, ss, hookMgr, 4, 3, 0, 1, 60)
    local n, byMe, withOdo = stampCensus(ss, v)
    T.ok("P3 multi-tank: the lane was stamped", n > 0)
    T.eq("P4 multi-tank: every stamp carries this sprayer and its distance",
         (byMe == n and withOdo == n) and "all" or (byMe .. "/" .. withOdo .. " of " .. n), "all")
    T.eq("P5 multi-tank first lane: no section is ever switched off", list(off), "")
end

-- ── S: standing still, then driving off ────────────────────────────────────
do
    -- Standing still must not age the pass's own stamps (the old 10 s grace did),
    -- so no section switches off while stopped, and driving on sprays at once.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    driveLane(v, ss, hookMgr, 4, 3, 0, 1, 30)
    local off, blockedTicks = {}, 0
    v.lastSpeed = 0
    for _ = 1, 400 do   -- 60 s stopped, same position
        local o, blocked = tick(v, ss, hookMgr, 150)
        for i in pairs(o) do off[i] = true end
        if blocked then blockedTicks = blockedTicks + 1 end
    end
    T.eq("S1 60 s standing still mid-lane: no section switched off", list(off), "")
    -- Only the 99% coverage block may block a pass (RSF-F226). Blocking a stopped
    -- pass is a separate decision; if it is ever made, this row flips on purpose.
    -- Either signal counts (tick): the flag, or the gate refusing processSprayerArea.
    T.eq("S3 stopped: the pass is not blocked (RSF-F226's block predicate unchanged)", blockedTicks, 0)
    local off2 = {}
    v.movingDirection = 1
    v.lastSpeed = 12 / 3600
    for s = 0, 20, 0.5 do
        place(4, 33 + s, 0, 1)
        for i in pairs(tick(v, ss, hookMgr, 150)) do off2[i] = true end
    end
    T.eq("S2 and driving on afterwards: no section off", list(off2), "")
end

-- ── T: back along the lane just sprayed, after a headland turn ─────────────
do
    -- Lane 1 north at x = 2 (boom covers x -10..14), a 180 degree turn of radius 11
    -- taking only 5 s, lane 2 south at x = 24: a 22 m shift for a 24 m boom, so
    -- section 9 (lat 9..12, x 12..15 on lane 2) overlaps lane 1 by 2 m. The quick
    -- turn is the case the old no-grace centre rule was added for (b6a961f0): under
    -- a 10 s grace the previous lane's stamps were still "fresh" on the way back.
    -- Checks are per 10 m cell at the section tip (#562), so sections 7 and 8 (tips
    -- at x = 18 and 15, same [10, 20) cell) may go off too without overlapping: that
    -- is the existing cell coarseness, not asserted either way here.
    -- x = 2 is chosen so the world-axis stamp sweep (getBoomCellPositions, minX = -10)
    -- covers the x in [10, 20) column; from some offsets it skips the outer column,
    -- a separate known defect this test must not depend on.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    driveLane(v, ss, hookMgr, 2, 0, 0, 1, 60)
    local steps = 40
    for k = 1, steps do
        local a = math.pi * k / steps
        place(13 - 11 * math.cos(a), 60 + 11 * math.sin(a), math.sin(a), math.cos(a))
        tick(v, ss, hookMgr, 5000 / steps)
    end
    -- Lane 2, heading south: lateral + now points at -X, i.e. at lane 1.
    local offFirst = driveLane(v, ss, hookMgr, 24, 60, 0, -1, 4)
    T.ok("T1 coming back after a quick turn: section 9, overlapping lane 1, switches off at once",
         offFirst[9] == true)
    local off = driveLane(v, ss, hookMgr, 24, 56, 0, -1, 40, offFirst)   -- T3/T4 cover the whole lane
    T.ok("T2 and is still off at the end of the lane",
         (v._sfOverlapSuppressedSections or {})[9] ~= nil)
    T.eq("T3 the centre never switches off on lane 2", off[5], nil)
    T.ok("T4 nor any section on the far side from lane 1",
         not off[1] and not off[2] and not off[3] and not off[4])
end

-- ── V: reversing ───────────────────────────────────────────────────────────
do
    -- Base-game sprayers keep spraying in reverse (disableBackwards="false"), and a
    -- reverse over fresh ground must keep spraying. In reverse the boom leads and the
    -- root trails, so the root stamps each cell just after the boom enters it: a
    -- rule treating the sprayer's own stamps as "sprayed earlier" whenever it
    -- reverses (tried and removed after the 2026-09-28 in-game test) switched these
    -- sections off. The distance grace covers reversing like driving forward.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    v.movingDirection = -1
    v.lastSpeed = 12 / 3600
    local off = {}
    for s = 0, 40, 0.5 do                                  -- reverse 40 m, heading still north
        place(4, 60 - s, 0, 1)
        for i in pairs(tick(v, ss, hookMgr, 150)) do off[i] = true end
    end
    T.eq("V1 reversing over fresh ground: no section switched off", list(off), "")
end

do
    -- In game (2026-09-28 test log, 02:23:35) every section flashed off when pulling
    -- away after a stop: the vehicle rocks back a few cm, and movingDirection is -1
    -- on anything above 1 mm/s. That is not reversing.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    driveLane(v, ss, hookMgr, 4, 3, 0, 1, 40)
    local off = {}
    v.movingDirection = -1                                 -- braking: rocks back 3 x 2 cm
    for k = 1, 3 do
        place(4, 43 - 0.02 * k, 0, 1)
        for i in pairs(tick(v, ss, hookMgr, 150)) do off[i] = true end
    end
    v.movingDirection = 0
    for _ = 1, 100 do
        for i in pairs(tick(v, ss, hookMgr, 150)) do off[i] = true end
    end
    v.movingDirection = -1                                 -- pulling away: rocks back 3 cm
    place(4, 42.91, 0, 1)
    for i in pairs(tick(v, ss, hookMgr, 150)) do off[i] = true end
    for i in pairs(driveLane(v, ss, hookMgr, 4, 43, 0, 1, 10)) do off[i] = true end
    T.eq("V2 rocking back a few cm when stopping or pulling away switches nothing off",
         list(off), "")
end

-- ── K: a gentle curve on a first pass ──────────────────────────────────────
do
    -- A 90 degree right-hand arc of radius 50 m (> 1.75 x the 12 m half-width) on a
    -- never-sprayed field. Tight corners are a documented limit (see the comment
    -- above HookManager.isCellSprayedEarlier); gentle ones must stay clean.
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    v.movingDirection = 1
    v.lastSpeed = 12 / 3600
    local off = {}
    local steps = 160
    for k = 0, steps do
        local a = (math.pi / 2) * k / steps
        place(54 - 50 * math.cos(a), 3 + 50 * math.sin(a), math.sin(a), math.cos(a))
        for i in pairs(tick(v, ss, hookMgr, 150)) do off[i] = true end
    end
    T.eq("K1 first pass round a 50 m radius curve: no section switched off", list(off), "")
end

-- ── O: ground another vehicle sprayed counts immediately ───────────────────
do
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    -- Another sprayer covered x in [10, 20) for z in [0, 60) moments ago.
    local cells = ss.fieldData[7].sessionCoverageCells
    local other = {}
    for cz = 0, 5 do cells[tostring(1 * 10000 + cz)] = { ms = 0, odo = 0, by = other } end
    local off = driveLane(v, ss, hookMgr, 4, 3, 0, 1, 20)
    T.ok("O1 a section over another vehicle's fresh stamps switches off at once", off[8] or off[9])
    T.eq("O2 the centre (over this pass's own ground) stays on", off[5], nil)
end

-- ── C: the centre is checked where the boom sprays, not at the root ────────
do
    -- A self-propelled layout: boom line 4.6 m behind the root (Agrio Dino II). A
    -- strip z in [50, 60) was sprayed by another vehicle. Checked at the root, the
    -- centre would switch off 4.6 m before the boom reaches the strip, leaving that
    -- much unsprayed on a sprayer with per-section work areas.
    boomFwd = -4.6
    local ss, hookMgr, v = install("overlap", OVERLAP_ON)
    local cells = ss.fieldData[7].sessionCoverageCells
    local other = {}
    for cx = -3, 3 do cells[tostring(cx * 10000 + 5)] = { ms = 0, odo = 0, by = other } end
    driveLane(v, ss, hookMgr, 4, 30, 0, 1, 21)          -- ends with root z = 51, boom z = 46.4
    T.eq("C1 root over the sprayed strip but boom not yet: centre still on",
         (v._sfOverlapSuppressedSections or {})[5], nil)
    driveLane(v, ss, hookMgr, 4, 51.5, 0, 1, 4)         -- ends with root z = 55.5, boom z = 50.9
    T.ok("C2 boom over the strip: centre off",
         (v._sfOverlapSuppressedSections or {})[5] ~= nil)
    boomFwd = BOOM_FWD
end

-- ── B: the fieldBoundaryControl overlap copy follows the same rule ─────────
do
    local settings = { enabled = true, overlapPrevention = false, fieldBoundaryControl = true,
                       smartSensorEnabled = false, debugMode = false }
    local ss, hookMgr, v = install("boundary", settings)
    local off = driveLane(v, ss, hookMgr, 4, 3, 0, 1, 30)
    for _ = 1, 400 do
        for i in pairs(tick(v, ss, hookMgr, 150)) do off[i] = true end
    end
    T.eq("B1 boundary control: first lane plus 60 s standing still, no section off", list(off), "")
end

Sprayer, Utils = saved.Sprayer, saved.Utils
g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
g_SoilFertilityManager, g_effectManager = saved.g_SoilFertilityManager, saved.g_effectManager
g_fieldManager, getWorldTranslation = saved.g_fieldManager, saved.getWorldTranslation
FillType, ToolType = saved.FillType, saved.ToolType
VehicleSystem = saved.VehicleSystem
