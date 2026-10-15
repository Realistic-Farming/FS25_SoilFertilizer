-- SF-1098-coverage_2m_world.lua
--
-- The world for SF-1098-coverage_2m_entry_test.lua (#1098 items 2 and 3): production's
-- real Sprayer.onStartWorkAreaProcessing / onEndWorkAreaProcessing appends, installed in
-- production's order (installSprayerOverlapGate, installSprayerAreaHook,
-- installOverlapPreventionHook or installSectionControlHook, installSectionStatePreserver
-- last so its prepend runs first) -- the same order MAINT-234-overlap_record_world.lua and
-- overlap_own_pass_grace_test.lua use, and the same engine-transform model (local X right
-- of travel, local Z along it; localToLocal/localToWorld/worldToLocal and
-- getWorldTranslation read a plain POS table, no i3d/physics). That world's Hardi Mega
-- 1200L fixture is fixed at a 24 m boom with its work-area corner nodes nailed to +-12 m, so
-- it cannot drive an exact 12 m boom, a broadcast spreader with no VariableWorkWidth
-- section at all, or a rig with fewer than two boom nodes but a declared implement working
-- width -- the three shapes #1098's bar needs. newRig below is the same fixture shape
-- (a sprayer with maxWidthNode tips, one work area, no i3d), generalised on the tip list,
-- the boom's forward offset, whether VariableWorkWidth exists at all, and the work area's
-- own span, so a test can choose the boom #1098's groups need instead of inheriting one
-- built for MAINTENANCE row 234.
--
-- What is modelled (same as MAINT-234's world): the geometry transforms, FillType /
-- fill-type lookups, Utils' two composition wrappers, and g_effectManager's
-- start/stopEffects as no-ops. No i3d, no physics, no terrain.

local saved = {
    Sprayer = Sprayer, Utils = Utils, g_fillTypeManager = g_fillTypeManager,
    g_currentMission = g_currentMission, g_SoilFertilityManager = g_SoilFertilityManager,
    g_effectManager = g_effectManager, g_fieldManager = g_fieldManager,
    getWorldTranslation = getWorldTranslation, getWorldRotation = getWorldRotation,
    FillType = FillType, ToolType = ToolType, VehicleSystem = VehicleSystem,
    localToLocal = localToLocal, localToWorld = localToWorld, worldToLocal = worldToLocal,
}

g_effectManager = { startEffects = function() end, stopEffects = function() end }
g_fieldManager = nil   -- no polygon: every cell counts, as MAINT-234's world

local FT_BY_NAME, FT_BY_INDEX = {}, {}
local function registerFillType(name, index)
    local d = { index = index, name = name }
    FT_BY_NAME[name] = d
    FT_BY_INDEX[index] = d
end
registerFillType("FERTILIZER", 42)
registerFillType("LIQUIDFERTILIZER", 41)
FillType = { UNKNOWN = 0, FERTILIZER = 42, LIQUIDFERTILIZER = 41 }
ToolType = ToolType or { UNDEFINED = 0 }
g_fillTypeManager = {
    getFillTypeByName  = function(_, n) return FT_BY_NAME[n] end,
    getFillTypeByIndex = function(_, i) return FT_BY_INDEX[i] end,
}

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

local POS = {}
getWorldTranslation = function(n)
    local p = POS[n]
    if p == nil then error("no such node " .. tostring(n)) end
    return p[1], 0, p[2]
end
function getWorldRotation(_n) return 0, 0, 0 end

-- The engine's frame transforms (as MAINT-234's world): local X right of travel, local Z
-- along it, read against the pose last given to place().
local POSE = { hx = 0, hz = 1 }
localToLocal = function(n, frame, _x, _y, _z)
    local p, f = POS[n], POS[frame]
    local dx, dz = p[1] - f[1], p[2] - f[2]
    return dx * POSE.hz - dz * POSE.hx, 0, dx * POSE.hx + dz * POSE.hz
end
localToWorld = function(frame, lx, _ly, lz)
    local f = POS[frame]
    return f[1] + lx * POSE.hz + lz * POSE.hx, 0, f[2] - lx * POSE.hx + lz * POSE.hz
end
worldToLocal = function(frame, wx, _wy, wz)
    local f = POS[frame]
    local dx, dz = wx - f[1], wz - f[2]
    return dx * POSE.hz - dz * POSE.hx, 0, dx * POSE.hx + dz * POSE.hz
end

local nextId = 0

--- A sprayer whose boom tip layout is given as a list of lateral offsets (false = an
--- isCenter section with no node, matching the Hardi fixture's convention). opts:
---   fwd          boom line offset behind the root along travel (default -0.4)
---   fillType     starting fill-type index (default 42, FERTILIZER)
---   sections     false omits VariableWorkWidth entirely (a broadcast spreader): the
---                tip list is used only to size the work area
---   noWorkArea   true omits spec_workArea entirely (so _collectBoomNodes sees nothing
---                but VWW tips, or nothing at all with sections=false too)
---   usageScale   sets spec_sprayer.usageScale.workingWidth (the #1098 fallback input)
---   wwLo, wwHi   override the work area's own lateral span (default: the tip extremes)
local function newRig(tips, opts)
    opts = opts or {}
    nextId = nextId + 1
    local v = {
        isServer = true, id = "rig" .. nextId, rootNode = "root" .. nextId,
        _fillType = opts.fillType or 42,
        getIsTurnedOn = function() return true end,
        getLastSpeed = function(self) return math.abs(self.lastSpeed or 0) * 3600 end,
        getSprayerFillUnitIndex = function() return 1 end,
        getFillUnitFillLevel = function() return 900 end,
        getFillUnitFillType = function(self) return self._fillType end,
        getOwnerFarmId = function() return 1 end,
        addFillUnitFillLevel = function() return 0 end,
    }
    v._fwd = opts.fwd or -0.4
    v._tips = tips or {}
    local lo, hi = nil, nil
    for _, lat in ipairs(v._tips) do
        if lat then
            if lo == nil or lat < lo then lo = lat end
            if hi == nil or lat > hi then hi = lat end
        end
    end
    if opts.sections ~= false then
        v.spec_variableWorkWidth = { sections = {} }
        v._nodePrefix = "mw" .. nextId .. "_"
        for i, lat in ipairs(v._tips) do
            v.spec_variableWorkWidth.sections[i] = {
                isActive = true, effects = {}, isCenter = (lat == false) or nil,
                maxWidthNode = lat and (v._nodePrefix .. i) or nil,
            }
        end
    end
    if not opts.noWorkArea then
        v._wwLo = opts.wwLo or lo or -1
        v._wwHi = opts.wwHi or hi or 1
        local waS, waW, waH = "waS" .. nextId, "waW" .. nextId, "waH" .. nextId
        v.spec_workArea = { workAreas = { {
            start = waS, width = waW, height = waH, functionName = "processSprayerArea",
        } } }
        v.spec_workArea.workAreas[1].processingFunction = function() return 1, 1 end
        v.processSprayerArea = v.spec_workArea.workAreas[1].processingFunction
    else
        v.spec_workArea = { workAreas = {} }
    end
    v.spec_sprayer = {
        workAreaParameters = { sprayFillType = v._fillType, usage = 1, sprayFillLevel = 900 },
        effects = {}, sprayTypes = {},
    }
    if opts.usageScale then
        v.spec_sprayer.usageScale = { workingWidth = opts.usageScale }
    end
    return v
end

-- A 12 m boom: two tip sections at +-6 m, no centre. Group A/B/C/E/G's rig.
local function boom12(opts)
    return newRig({ -6, 6 }, opts)
end
-- A 24 m broadcast spreader with NO VariableWorkWidth at all (sectionsInPass is false
-- whatever the sections table holds, so the tip list here only sizes the work area).
-- Group D's rig.
local function broadcast24(opts)
    opts = opts or {}
    opts.sections = false
    return newRig({ -12, 12 }, opts)
end
-- A VWW rig with exactly one section and NO maxWidthNode at all, and no work area
-- either: _collectBoomNodes has nothing to collect (fewer than two boom nodes), so
-- getBoomOverlapPositions must fall back to the implement's declared working width.
-- sectionsInPass is still true (one section, length > 0), so hasVWW stays true and the
-- fallback's record counts coverage area. Group F's rig.
local function fallbackRig(width, opts)
    opts = opts or {}
    opts.noWorkArea = true
    opts.usageScale = width
    local v = newRig({}, opts)
    v.spec_variableWorkWidth = { sections = { { isActive = true, effects = {}, isCenter = true } } }
    return v
end

-- Place the rig at root (rx, rz) heading (hx, hz); lateral + is right of travel.
local function place(v, rx, rz, hx, hz)
    local px, pz = hz, -hx
    POSE.hx, POSE.hz = hx, hz
    POS[v.rootNode] = { rx, rz }
    local function at(lat, fwd) return { rx + lat * px + fwd * hx, rz + lat * pz + fwd * hz } end
    if v.spec_variableWorkWidth and v._nodePrefix then
        for i, lat in ipairs(v._tips) do
            if lat then POS[v._nodePrefix .. i] = at(lat, v._fwd) end
        end
    end
    if v.spec_workArea and v.spec_workArea.workAreas[1] then
        local wa = v.spec_workArea.workAreas[1]
        POS[wa.start]  = at(v._wwHi, v._fwd)
        POS[wa.width]  = at(v._wwLo, v._fwd)
        POS[wa.height] = at(v._wwHi, v._fwd - 0.14)
    end
end

-- One tick as the game runs it: start processing (preserver prepend, overlap prepend),
-- the engine's paint through the work area's processing function when there is one, end
-- processing (the credit append stamps this tick's boom, then the restore appends).
-- Returns the set of sections switched off by either overlap check this tick.
local function tick(v, dtMs)
    g_currentMission.time = g_currentMission.time + dtMs
    Sprayer.onStartWorkAreaProcessing(v, dtMs)
    local off = {}
    for i in pairs(v._sfOverlapSuppressedSections or {}) do off[i] = true end
    for i in pairs(v._sfSuppressedSections or {}) do off[i] = true end
    if v.spec_workArea and v.spec_workArea.workAreas[1] then
        local wa = v.spec_workArea.workAreas[1]
        wa.processingFunction(v, wa, dtMs)
    end
    Sprayer.onEndWorkAreaProcessing(v, dtMs, true)
    return off
end

-- A straight lane at 12 km/h, 0.5 m per tick; the union of sections switched off on it.
local function driveLane(v, x0, z0, hx, hz, metres, acc)
    acc = acc or {}
    v.movingDirection = 1
    v.lastSpeed = 12 / 3600
    for s = 0, metres, 0.5 do
        place(v, x0 + s * hx, z0 + s * hz, hx, hz)
        for i in pairs(tick(v, 150)) do acc[i] = true end
    end
    return acc
end

local function install(kind, settings)
    Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 1, 1 end }
    VehicleSystem = { addVehicle = function(_self, _vehicle) return true end }
    g_currentMission = { time = 0, vehicleSystem = setmetatable({ vehicles = {} }, { __index = VehicleSystem }) }
    local ss = setmetatable({
        fieldData = {},
        -- diseasePressure stays OFF: its daily-growth branch in _processOneDailyField
        -- (Group AC's direct call) reaches SoilDiseaseSystem, a module unrelated to
        -- #1098 that this world does not load. weedPressure stays on for Group G's
        -- _grantCropProtection("herbicide") check.
        settings = { weedPressure = true, pestPressure = true, diseasePressure = false, diseaseMoisture = 2 },
        onFertilizerApplied = function() return true end,
        onHerbicideAppliedDirect = function() end,
        onInsecticideAppliedDirect = function() end,
        onFungicideAppliedDirect = function() end,
        paintBoomStrip = function() end,
        applyBurnEffect = function() end,
        applyScorchEffect = function() end,
        -- _processOneDailyField (called directly by Group C/AC) reads these daily-cap
        -- trackers; getOrCreateField would normally seed them per field.
        herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
        herbicideDailyApplied = {}, insecticideDailyApplied = {}, fungicideDailyApplied = {},
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
    HookManager.installSprayerOverlapGate(hookMgr)
    HookManager.installSprayerAreaHook(hookMgr)
    if kind == "boundary" then
        HookManager.installSectionControlHook(hookMgr)
    else
        HookManager.installOverlapPreventionHook(hookMgr)
    end
    HookManager.installSectionStatePreserver(hookMgr)
    return ss, hookMgr
end

local function addField(ss, fieldId, areaHa)
    ss.fieldData[fieldId] = {
        fieldArea = areaHa, sessionCoverageCells = {}, dailyCoverageCells = {},
        zoneData = {}, sessionCoverageFraction = 0,
        -- A real field's nutrient/pH state (SoilConstants.FIELD_DEFAULTS), so a direct
        -- call to a daily-batch production method (_processOneDailyField) has the
        -- fields its own arithmetic reads, the same as getOrCreateField would leave.
        nitrogen = 40, phosphorus = 30, potassium = 35, organicMatter = 3.5, pH = 6.0,
        lastHarvest = 0, compaction = 0,
    }
    return ss.fieldData[fieldId]
end

local function countKeys(t)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

C2W = {
    install = install, addField = addField, place = place, tick = tick, driveLane = driveLane,
    boom12 = boom12, broadcast24 = broadcast24, fallbackRig = fallbackRig, newRig = newRig,
    registerFillType = registerFillType, countKeys = countKeys,
    restore = function()
        Sprayer, Utils = saved.Sprayer, saved.Utils
        g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
        g_SoilFertilityManager, g_effectManager = saved.g_SoilFertilityManager, saved.g_effectManager
        g_fieldManager, getWorldTranslation = saved.g_fieldManager, saved.getWorldTranslation
        getWorldRotation = saved.getWorldRotation
        FillType, ToolType = saved.FillType, saved.ToolType
        VehicleSystem = saved.VehicleSystem
        localToLocal, localToWorld, worldToLocal = saved.localToLocal, saved.localToWorld, saved.worldToLocal
    end,
}
