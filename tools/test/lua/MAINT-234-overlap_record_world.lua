-- MAINT-234-overlap_record_world.lua
--
-- The world for MAINT-234-overlap_record_spec_test.lua (MAINTENANCE row 234): a sprayer laid
-- out like the Hardi Mega 1200L (mega1200L.xml/.i3d: 9 sections, tips at +-3.5/6/9/12 m, an
-- isCenter section with no node, boom line 0.46 m behind the root), the harness of
-- overlap_own_pass_grace_test.lua. Production's own appends on the Sprayer class are
-- installed in production's order: the sprayer overlap gate, the credit append
-- (installSprayerAreaHook, which stamps the 10 m session cells AND the overlap record), the
-- overlap check (installOverlapPreventionHook) or the field-boundary copy
-- (installSectionControlHook), then the preserver last so its prepend runs first. Every
-- stamp comes from the production append; another vehicle's pass is written by the
-- production writer markOverlapCells. Loaded after the src files; the bar reads it through
-- the ORW table and calls ORW.restore() at the end.

local saved = {
    Sprayer = Sprayer, Utils = Utils, g_fillTypeManager = g_fillTypeManager,
    g_currentMission = g_currentMission, g_SoilFertilityManager = g_SoilFertilityManager,
    g_effectManager = g_effectManager, g_fieldManager = g_fieldManager,
    getWorldTranslation = getWorldTranslation, FillType = FillType, ToolType = ToolType,
    VehicleSystem = VehicleSystem,
}

g_effectManager = { startEffects = function() end, stopEffects = function() end }
g_fieldManager = nil   -- no polygon: every cell counts
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

local POS = {}
getWorldTranslation = function(n)
    local p = POS[n]
    if p == nil then error("no such node " .. tostring(n)) end
    return p[1], 0, p[2]
end

local HARDI_LAT = { -12, -9, -6, -3.5, false, 3.5, 6, 9, 12 }   -- false = isCenter, no node
local BOOM_FWD = -0.46

local function newWorld(settings)
    local ss = setmetatable({
        fieldData = { [7] = { fieldArea = 1000, sessionCoverageCells = {}, dailyCoverageCells = {},
                              zoneData = {}, sessionCoverageFraction = 0 } },
        onFertilizerApplied = function() return true end,
        paintBoomStrip = function() end,
        applyBurnEffect = function() end,
        applyScorchEffect = function() end,
    }, { __index = SoilFertilitySystem })
    g_SoilFertilityManager = { settings = settings, soilSystem = ss, sensorManager = {} }
    local hookMgr = setmetatable({
        hooks = {}, register = function() end, registerCleanup = function() end,
        getFieldIdAtWorldPosition = function() return 7 end,
        getTargetApplication = function() return nil end,
        getBoomLineEndpoints = function() return nil end,
        _sectionScratch = {}, _settings = { multiTankApplication = false },
        customFillTypePrices = {}, customProductIndices = {}, refusedProducts = {},
    }, { __index = HookManager })
    return ss, hookMgr
end

local function newHardi()
    local v = {
        isServer = true, id = "hardi", rootNode = "root",
        spec_variableWorkWidth = { sections = {} },
        spec_workArea = { workAreas = { {
            start = "waS", width = "waW", height = "waH", functionName = "processSprayerArea",
        } } },
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
            isActive = true, effects = {}, isCenter = (lat == false) or nil,
            maxWidthNode = lat and ("mw" .. i) or nil,
        }
    end
    v.spec_sprayer = { workAreaParameters = { sprayFillType = 42, usage = 1, sprayFillLevel = 900 },
                       effects = {}, sprayTypes = {} }
    return v
end

-- The sprayer at root (rx, rz) heading (hx, hz); lateral + is right of travel.
local function place(rx, rz, hx, hz)
    local px, pz = hz, -hx
    POS.root = { rx, rz }
    local function at(lat, fwd) return { rx + lat * px + fwd * hx, rz + lat * pz + fwd * hz } end
    for i, lat in ipairs(HARDI_LAT) do
        if lat then POS["mw" .. i] = at(lat, BOOM_FWD) end
    end
    POS.waS = at(12, BOOM_FWD); POS.waW = at(-12, BOOM_FWD); POS.waH = at(12, BOOM_FWD - 0.14)
end

-- One tick as the game runs it; returns the sections either overlap check switched off.
local function tick(v, dtMs)
    g_currentMission.time = g_currentMission.time + dtMs
    Sprayer.onStartWorkAreaProcessing(v, dtMs)
    local off = {}
    for i in pairs(v._sfOverlapSuppressedSections or {}) do off[i] = true end
    for i in pairs(v._sfSuppressedSections or {}) do off[i] = true end
    local wa = v.spec_workArea.workAreas[1]
    wa.processingFunction(v, wa, dtMs)
    Sprayer.onEndWorkAreaProcessing(v, dtMs, true)
    return off
end

local function install(which, settings)
    Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 1, 1 end }
    VehicleSystem = { addVehicle = function(_self, _vehicle) return true end }
    g_currentMission = { time = 0, vehicleSystem = setmetatable({ vehicles = {} }, { __index = VehicleSystem }) }
    local ss, hookMgr = newWorld(settings)
    HookManager.installSprayerOverlapGate(hookMgr)
    HookManager.installSprayerAreaHook(hookMgr)
    if which == "boundary" then
        HookManager.installSectionControlHook(hookMgr)
    else
        HookManager.installOverlapPreventionHook(hookMgr)
    end
    HookManager.installSectionStatePreserver(hookMgr)
    local v = newHardi()
    g_currentMission.vehicleSystem:addVehicle(v)
    return ss, hookMgr, v
end

-- A straight lane at 12 km/h, 0.5 m per tick; the union of sections switched off on it.
local function driveLane(v, x0, z0, hx, hz, metres, acc)
    acc = acc or {}
    v.movingDirection = 1
    v.lastSpeed = 12 / 3600
    for s = 0, metres, 0.5 do
        place(x0 + s * hx, z0 + s * hz, hx, hz)
        for i in pairs(tick(v, 150)) do acc[i] = true end
    end
    return acc
end

-- Two CoursePlay-style rows: lane 1 north at x = 2 (boom over x -10..14), a quick 180 degree
-- headland turn of radius 11, lane 2 south at x = 24 (boom over x 12..36), 2 m of overlap.
-- On lane 2, lateral + points at -X, toward lane 1: section 9's tip at x 12, section 8's at
-- x 15, section 7's at x 18. Returns the sections switched off along lane 2.
local function twoRows(v)
    driveLane(v, 2, 0, 0, 1, 60)
    local steps = 40
    for k = 1, steps do
        local a = math.pi * k / steps
        place(13 - 11 * math.cos(a), 60 + 11 * math.sin(a), math.sin(a), math.cos(a))
        tick(v, 5000 / steps)
    end
    return driveLane(v, 24, 60, 0, -1, 44)
end

local function list(set)
    local t = {}
    for i in pairs(set) do t[#t + 1] = i end
    table.sort(t)
    return table.concat(t, ",")
end

-- The 10 m record and everything read from it: the session cells (keys), pass % inputs,
-- the daily cells and the green square's points.
local function tenMetreSignature(ss)
    local f = ss.fieldData[7]
    local keys, n = {}, 0
    for k in pairs(f.sessionCoverageCells or {}) do keys[#keys + 1] = k; n = n + 1 end
    table.sort(keys)
    local daily = 0
    for _ in pairs(f.dailyCoverageCells or {}) do daily = daily + 1 end
    return string.format("cells=%d [%s] sessionHa=%.4f sessionFrac=%.6f daily=%d coveredHa=%.4f trail=%d",
        n, table.concat(keys, " "), f.sessionCoverageHa or 0, f.sessionCoverageFraction or 0, daily,
        f.coveredAreaHa or 0, f.sprayTrailPts and #f.sprayTrailPts or 0)
end

-- Another vehicle's pass over x in [x0, x1), z in [z0, z1), through the production writer.
local function otherPass(ss, other, x0, x1, z0, z1)
    local size, pts = SoilConstants.ZONE.OVERLAP_CELL_SIZE, {}
    for x = x0 + size / 2, x1, size do
        for z = z0 + size / 2, z1, size do pts[#pts + 1] = { x = x, z = z } end
    end
    other._sfOdoM = 0
    ss:markOverlapCells(7, pts, other)
    local cells = ss.fieldData[7].sessionCoverageCells
    for cx = math.floor(x0 / 10), math.floor((x1 - 1) / 10) do
        for cz = math.floor(z0 / 10), math.floor((z1 - 1) / 10) do
            cells[tostring(cx * 10000 + cz)] = { ms = 0, odo = 0, by = other }
        end
    end
end

ORW = {
    install = install, place = place, tick = tick, driveLane = driveLane, twoRows = twoRows,
    list = list, tenMetreSignature = tenMetreSignature, otherPass = otherPass,
    restore = function()
        Sprayer, Utils = saved.Sprayer, saved.Utils
        g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
        g_SoilFertilityManager, g_effectManager = saved.g_SoilFertilityManager, saved.g_effectManager
        g_fieldManager, getWorldTranslation = saved.g_fieldManager, saved.getWorldTranslation
        FillType, ToolType = saved.FillType, saved.ToolType
        VehicleSystem = saved.VehicleSystem
    end,
}
