-- MAINT-232-section_sample_world.lua
--
-- The world for MAINT-232-section_sample_spec_test.lua (MAINTENANCE row 232): one 36 m
-- boom sprayer standing on a lane, driven through production's own appends on the Sprayer
-- class in production's order (installSectionControlHook, installSeeAndSprayHook,
-- installVariableRateHook, then installSectionStatePreserver's prepend; HookManager.lua
-- installAll). Loaded after the src files; the bar reads it through the SSW table and
-- calls SSW.restore() at the end. Its own file so a mutation battery can select the bar
-- alone with --loads.
--
-- What the fixture supplies is what the engine and the save supply: the boom's nodes where
-- the i3d puts them, the bought See & Spray option on the vehicle, the native weed state at
-- each world point (FieldState:update, FieldState.lua, reading weedSystem
-- getWeedStateAtWorldPos), which field a point is on, and the soil store's field and cell
-- values. Nothing Soil derives (a sample point, a section's ground, a rate) is set by hand.
--
-- Geometry: the vehicle root stands at x = 25, z = 50, heading +Z, so the boom's lateral
-- axis is world X and lateral L is world x = 25 + L. The boom line is 2 m behind the root
-- (z = 48, zone row 4). Twelve 3 m sections, tips at 3 to 18 m either side.

local saved = {
    Sprayer = Sprayer, Utils = Utils, g_fillTypeManager = g_fillTypeManager,
    g_currentMission = g_currentMission, g_SoilFertilityManager = g_SoilFertilityManager,
    g_fieldManager = g_fieldManager, getWorldTranslation = getWorldTranslation,
    localToLocal = localToLocal, localToWorld = localToWorld, worldToLocal = worldToLocal,
    getWorldRotation = getWorldRotation, FieldState = FieldState,
}

Utils = {
    appendedFunction = function(orig, new)
        return function(...)
            local r = orig and { orig(...) } or {}
            new(...)
            return unpack(r)
        end
    end,
    prependedFunction = function(orig, new)
        return function(...)
            new(...)
            if orig then return orig(...) end
        end
    end,
}

local FT = { INSECTICIDE = 61, HERBICIDE = 62, UAN32 = 63 }
local FT_NAME = {}
for n, i in pairs(FT) do FT_NAME[i] = n end
g_fillTypeManager = {
    getFillTypeIndexByName = function(_, name) return FT[name and string.upper(name)] end,
    getFillTypeByName = function(_, n)
        n = n and string.upper(n)
        return FT[n] and { index = FT[n], name = n } or nil
    end,
    getFillTypeByIndex = function(_, i) return FT_NAME[i] and { index = i, name = FT_NAME[i] } or nil end,
}

-- ── The world ───────────────────────────────────────────────────────────────
local ROOT = { x = 25, z = 50 }
local LOCAL = {}                                 -- node -> { lateral, forward }
local function worldOf(lat, fwd) return ROOT.x + lat, ROOT.z + fwd end
getWorldTranslation = function(n)
    local l = LOCAL[n]
    if l == nil then error("no such node " .. tostring(n)) end
    local x, z = worldOf(l[1], l[2])
    return x, 0, z
end
localToLocal = function(n, frame, _x, _y, _z)
    local l, f = LOCAL[n], LOCAL[frame]
    return l[1] - f[1], 0, l[2] - f[2]
end
localToWorld = function(frame, lx, _ly, lz)
    local f = LOCAL[frame]
    local x, z = worldOf(f[1] + lx, f[2] + lz)
    return x, 0, z
end
worldToLocal = function(frame, wx, _wy, wz)
    local f = LOCAL[frame]
    return wx - ROOT.x - f[1], 0, wz - ROOT.z - f[2]
end
getWorldRotation = function(_n) return 0, 0, 0 end

-- The row's ground. weeds: { from, to } stretches, measured from world x = 25 (the lane's
-- centre line), where the native weed state is 3 (growing, sprayed by See & Spray);
-- elsewhere 0 (none). splitX: points at world x at or past it are on field 8, the rest on
-- field 7. endX: points at or past it are on no field. Field and cell values come from the row.
local W = { weeds = {}, splitX = math.huge, endX = math.huge }
local function weedStateAt(x, _z)
    local lat = x - 25
    for _, s in ipairs(W.weeds) do
        if lat >= s[1] and lat <= s[2] then return 3 end
    end
    return 0
end
local function fieldAt(x, _z)
    if x >= W.endX then return 0 end
    return (x >= W.splitX) and 8 or 7
end

-- FieldState (FieldState.lua): update(x, z) reads the native weed state at the point.
FieldState = {
    new = function()
        return { update = function(self, x, z) self.weedState = weedStateAt(x, z) end }
    end,
}
g_fieldManager = { fields = {
    { farmland = { id = 7 }, posX = ROOT.x, posZ = ROOT.z },
    { farmland = { id = 8 }, posX = ROOT.x + 30, posZ = ROOT.z },
} }

-- ── The machine ─────────────────────────────────────────────────────────────
local TIPS = { 18, 15, 12, 9, 6, 3, -3, -6, -9, -12, -15, -18 }
local function boom(fillName, seeAndSpray)
    local v = {
        isServer = true, id = "boom", rootNode = "boom.root", components = { { node = "boom.frame" } },
        spec_sprayer = { fillUnitIndex = 1, workAreaParameters = { sprayFillType = FT[fillName] } },
        spec_workArea = { workAreas = { { start = "boom.waS", width = "boom.waW", height = "boom.waH" } } },
        spec_variableWorkWidth = { sections = {} },
    }
    LOCAL[v.rootNode], LOCAL[v.components[1].node] = { 0, 0 }, { 0, 0 }
    LOCAL["boom.waS"], LOCAL["boom.waW"], LOCAL["boom.waH"] = { 18, -2 }, { -18, -2 }, { 18, -2.5 }
    for i, lat in ipairs(TIPS) do
        local n = "boom.tip" .. i
        LOCAL[n] = { lat, -2 }
        v.spec_variableWorkWidth.sections[i] = { isActive = true, effects = {}, lat = lat, maxWidthNode = n }
    end
    if seeAndSpray then
        -- The bought See & Spray option, as SFNozzleEffects' onPreLoad leaves it (SFNozzleEffects.lua:267-269).
        v[SFNozzleEffects.SPEC_TABLE_NAME] = { seeSprayWeed = true, seeSprayPest = true, seeSprayDisease = true }
    end
    return v
end

-- ── Harness ─────────────────────────────────────────────────────────────────
-- fields: { [7] = {...}, [8] = {...} } soil store entries (zoneData keyed as Soil keys cells).
local function install(fields, settings)
    Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
    g_currentMission = { time = 0, missionInfo = {} }
    local sensorMgr = SoilSensorManager.new()
    g_SoilFertilityManager = {
        soilSystem = { fieldData = fields },
        sensorManager = sensorMgr,
        settings = settings or { smartSensorEnabled = true, variableRateEnabled = true, fieldBoundaryControl = false },
    }
    local hookMgr = setmetatable({
        hooks = {}, register = function() end, registerCleanup = function() end,
        getFieldIdAtWorldPosition = function(_, x, z) return fieldAt(x, z) end,
        getTargetApplication = function() return nil end,
        _sectionScratch = {},
    }, { __index = HookManager })
    HookManager.installSectionControlHook(hookMgr)
    HookManager.installSeeAndSprayHook(hookMgr)
    HookManager.installVariableRateHook(hookMgr)
    HookManager.installSectionStatePreserver(hookMgr)
    return sensorMgr, hookMgr
end

-- One tick of the class's start-of-work-area processing, where the three hooks decide.
local function tick(v)
    g_currentMission.time = g_currentMission.time + 100
    Sprayer.onStartWorkAreaProcessing(v, 100)
end

-- The sections still spraying after the hooks ran, by tip, outer +X first.
local function spraying(v)
    local on = {}
    for _, s in ipairs(v.spec_variableWorkWidth.sections) do
        if s.isActive then on[#on + 1] = string.format("%g", s.lat) end
    end
    return table.concat(on, ",")
end
local function section(v, lat)
    for _, s in ipairs(v.spec_variableWorkWidth.sections) do if s.lat == lat then return s end end
end
local function cellKey(x, z) return tostring(math.floor(x / 10) * 10000 + math.floor(z / 10)) end

SSW = {
    W = W, ROOT = ROOT, FT = FT,
    boom = boom, install = install, tick = tick, spraying = spraying, section = section, cellKey = cellKey,
    restore = function()
        Sprayer, Utils = saved.Sprayer, saved.Utils
        g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
        g_SoilFertilityManager, g_fieldManager = saved.g_SoilFertilityManager, saved.g_fieldManager
        getWorldTranslation, localToLocal = saved.getWorldTranslation, saved.localToLocal
        localToWorld, worldToLocal, getWorldRotation = saved.localToWorld, saved.worldToLocal, saved.getWorldRotation
        FieldState = saved.FieldState
    end,
}
