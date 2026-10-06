-- MAINT-229-section_boom_world.lua
--
-- The world for MAINT-229-section_stamp_spec_test.lua (MAINTENANCE row 229): three sprayers
-- driven through production's own two appends on the Sprayer class, in production's order
-- (installSprayerAreaHook, then installSectionStatePreserver). Loaded after the src files; the
-- bar reads it through the SBW table and calls SBW.restore() at the end. Its own file so a
-- mutation battery can select the bar alone with --loads (the MAINT-166 and MAINT-172 shape).
--
-- What the fixture supplies is what the engine supplies: node positions, section states as the
-- player, the engine's partial width or a section-control mod leaves them before the tick, and
-- the work areas with their #sectionIndex. Nothing Soil derives is set by hand.

local saved = {
    Sprayer = Sprayer, Utils = Utils, g_fillTypeManager = g_fillTypeManager,
    g_currentMission = g_currentMission, g_SoilFertilityManager = g_SoilFertilityManager,
    g_fieldManager = g_fieldManager, getWorldTranslation = getWorldTranslation,
    localToLocal = localToLocal, localToWorld = localToWorld, worldToLocal = worldToLocal,
    getWorldRotation = getWorldRotation, FillType = FillType, ToolType = ToolType,
}

g_fieldManager = nil   -- no polygon: markBoomCells counts every cell
FillType = FillType or { UNKNOWN = 0 }
ToolType = ToolType or { UNDEFINED = 0 }
-- Utils.appendedFunction / prependedFunction (Utils.lua): call order only.
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

local FT = { UNKNOWN = FillType.UNKNOWN, FERTILIZER = 42, LIME = 43, HERBICIDE = 44, LIQUIDFERTILIZER = 45 }
local FT_NAME = {}
for n, i in pairs(FT) do FT_NAME[i] = n end
g_fillTypeManager = {
    getFillTypeIndexByName = function(_, name)
        if name then name = string.upper(name) end
        return FT[name]
    end,
    getFillTypeByName = function(_, n)
        n = n and string.upper(n)
        return FT[n] and { index = FT[n], name = n } or nil
    end,
    getFillTypeByIndex = function(_, i)
        return FT_NAME[i] and { index = i, name = FT_NAME[i] } or nil
    end,
}

-- ── The world: one vehicle pose, every node given in the vehicle's own frame ──
-- Local X is lateral (the engine's working-width axis, WorkArea.lua:307-314), local
-- Z is along travel. The heading is one of three: "+Z" (local X onto world +X, the
-- default), "+X" (local Z onto world +X, local X onto world -Z) and "-X" (local Z onto
-- world -X, local X onto world +Z). The lane's centre line is 25 across the travel.
local LANE_X = 25
local POSE = { x = LANE_X, z = 0, heading = "+Z" }
local LOCAL = {}                                 -- node -> { lateral, forward }
local function worldOf(lat, fwd)
    if POSE.heading == "+X" then return POSE.x + fwd, POSE.z - lat end
    if POSE.heading == "-X" then return POSE.x - fwd, POSE.z + lat end
    return POSE.x + lat, POSE.z + fwd
end
local function localOf(wx, wz)                   -- the inverse of worldOf
    local dx, dz = wx - POSE.x, wz - POSE.z
    if POSE.heading == "+X" then return -dz, dx end
    if POSE.heading == "-X" then return dz, -dx end
    return dx, dz
end
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
    local lat, fwd = localOf(wx, wz)
    return lat - f[1], 0, fwd - f[2]
end
getWorldRotation = function(_n)
    if POSE.heading == "+X" then return 0, math.pi / 2, 0 end
    if POSE.heading == "-X" then return 0, -math.pi / 2, 0 end
    return 0, 0, 0
end

-- ── The engine's spray-type rule (Sprayer.lua:589-648, Foldable.lua:1141-1176) ──
local function loadSprayTypes(v, xmlSprayTypes)
    local spec = v.spec_sprayer
    spec.sprayTypes = {}
    for _, x in ipairs(xmlSprayTypes) do
        local st = { fillUnitIndex = x.fillUnitIndex or 1, fillTypes = x.fillTypes }
        st.supportsVariableWorkWidth = x.supportsVariableWorkWidth ~= false
        st.hasRequiredFoldingConfiguration = true
        st.usageScale = {}
        if x.usageScales then
            st.usageScale.workingWidth = x.usageScales.workingWidth or 12
            st.usageScale.workAreaIndex = x.usageScales.workAreaIndex
        else
            st.usageScale.workingWidth = spec.usageScale.workingWidth
            st.usageScale.workAreaIndex = spec.usageScale.workAreaIndex
        end
        table.insert(spec.sprayTypes, st)
        st.index = #spec.sprayTypes
    end
end
local function engineGetActiveSprayType(self)
    for _, sprayType in ipairs(self.spec_sprayer.sprayTypes) do
        local ok = sprayType.hasRequiredFoldingConfiguration ~= false
        if ok and sprayType.fillTypes ~= nil then
            ok = false
            local current = self:getFillUnitFillType(sprayType.fillUnitIndex or self.spec_sprayer.fillUnitIndex)
            for _, fillType in ipairs(sprayType.fillTypes) do
                if current == g_fillTypeManager:getFillTypeIndexByName(fillType) then ok = true end
            end
        end
        if ok then return sprayType end
    end
    return nil
end
local function engineGetWorkAreaWidth(self, workAreaIndex)
    local wa = self.spec_workArea.workAreas[workAreaIndex]
    local x1 = localToLocal(wa.start, self.components[1].node, 0, 0, 0)
    local x2 = localToLocal(wa.width, self.components[1].node, 0, 0, 0)
    local x3 = localToLocal(wa.height, self.components[1].node, 0, 0, 0)
    return math.max(x1, x2, x3) - math.min(x1, x2, x3)
end

-- VariableWorkWidth.updateSectionStates (VariableWorkWidth.lua:338-351): each side's
-- sections sorted inner to outer, the first `state` active; a side's section nodes
-- (the work area's edges, where the XML has them) move to the outermost active tip
-- (setSectionNodePercentage, :309-328).
local function engineSetSections(v, left, right)
    local vww = v.spec_variableWorkWidth
    for _, side in ipairs({ { vww.sectionsLeft, left, vww.nodesLeft }, { vww.sectionsRight, right, vww.nodesRight } }) do
        local sections, state, nodes = side[1], side[2], side[3] or {}
        for i, s in ipairs(sections) do s.isActive = i <= state end
        if #nodes > 0 then
            local tip = state == 0 and vww.minTrans or math.abs(LOCAL[sections[state].maxWidthNode][1])
            for _, n in ipairs(nodes) do
                local sign = LOCAL[n][1] < 0 and -1 or 1
                LOCAL[n][1] = sign * tip
            end
        end
    end
end

-- ── Machines ────────────────────────────────────────────────────────────────
local function baseSprayer(id, fillTypeIndex, vehicleUsage)
    local v = {
        isServer = true, id = id, rootNode = id .. ".root",
        components = { { node = id .. ".frame" } },
        lastSpeed = 12 / 3600,
        getIsTurnedOn = function() return true end,
        getLastSpeed = function(self) return math.abs(self.lastSpeed or 0) * 3600 end,
        getSprayerFillUnitIndex = function() return 1 end,
        getFillUnitFillLevel = function(self, i) return self.spec_fillUnit.fillUnits[i].fillLevel end,
        getFillUnitFillType = function(self, i) return self.spec_fillUnit.fillUnits[i].fillType end,
        getOwnerFarmId = function() return 1 end,
        addFillUnitFillLevel = function() return 0 end,
        getActiveSprayType = engineGetActiveSprayType,
        getWorkAreaWidth = engineGetWorkAreaWidth,
        spec_fillUnit = { fillUnits = { { fillLevel = 5000, fillType = fillTypeIndex } } },
        spec_sprayer = {
            fillUnitIndex = 1,
            usageScale = { workingWidth = vehicleUsage or 12, default = 1, fillTypeScales = {} },
            workAreaParameters = { sprayFillType = fillTypeIndex, usage = 1, sprayFillLevel = 5000 },
            effects = {},
        },
    }
    LOCAL[v.rootNode] = { 0, 0 }
    LOCAL[v.components[1].node] = { 0, 0 }
    return v
end
local function node(v, name, lat, fwd)
    local n = v.id .. "." .. name
    LOCAL[n] = { lat, fwd }
    return n
end
local function sideLists(v)
    local vww = v.spec_variableWorkWidth
    vww.sectionsLeft, vww.sectionsRight = {}, {}
    for _, s in ipairs(vww.sections) do
        local lat = s.lat
        table.insert(lat > 0 and vww.sectionsLeft or vww.sectionsRight, s)
    end
    local byWidth = function(a, b) return math.abs(a.lat) < math.abs(b.lat) end
    table.sort(vww.sectionsLeft, byWidth)
    table.sort(vww.sectionsRight, byWidth)
end

-- A 36 m liquid boom: twelve 3 m sections (tips at 3 to 18 m either side) and ONE work
-- area across the whole boom, so its corners always reach both tips.
local CP_TIPS = { 18, 15, 12, 9, 6, 3, -3, -6, -9, -12, -15, -18 }
local function cpBoom()
    local v = baseSprayer("cp", FT.LIQUIDFERTILIZER, 36)
    v.spec_workArea = { workAreas = { {
        start = node(v, "waS", 18, -1.0), width = node(v, "waW", -18, -1.0), height = node(v, "waH", 18, -1.5),
    } } }
    v.spec_variableWorkWidth = { sections = {} }
    for i, lat in ipairs(CP_TIPS) do
        v.spec_variableWorkWidth.sections[i] = {
            isActive = true, effects = {}, lat = lat, maxWidthNode = node(v, "tip" .. i, lat, -1.0),
        }
    end
    sideLists(v)
    loadSprayTypes(v, { { fillTypes = { "liquidfertilizer" } } })
    return v
end
-- A 33 m boom with a 3 m CENTRE section (#isCenter, tip 1.5 m out) and five 3 m sections a
-- side (tips 4.5 to 16.5 m), one work area across the whole boom.
local CB_TIPS = { 16.5, 13.5, 10.5, 7.5, 4.5, 1.5, -4.5, -7.5, -10.5, -13.5, -16.5 }
local function centreBoom()
    local v = baseSprayer("cb", FT.LIQUIDFERTILIZER, 33)
    v.spec_workArea = { workAreas = { {
        start = node(v, "waS", 16.5, -1.0), width = node(v, "waW", -16.5, -1.0), height = node(v, "waH", 16.5, -1.5),
    } } }
    v.spec_variableWorkWidth = { sections = {} }
    for i, lat in ipairs(CB_TIPS) do
        v.spec_variableWorkWidth.sections[i] = {
            isActive = true, effects = {}, lat = lat, isCenter = (lat == 1.5) or nil,
            maxWidthNode = node(v, "tip" .. i, lat, -1.0),
        }
    end
    loadSprayTypes(v, { { fillTypes = { "liquidfertilizer" } } })
    return v
end

-- Switched off before the tick, as a section-control mod or the player leaves them.
local function switchOff(v, tips)
    for _, s in ipairs(v.spec_variableWorkWidth.sections) do
        for _, t in ipairs(tips) do
            if s.lat == t then s.isActive = false end
        end
    end
end

-- A 24 m boom with one work area PER SECTION (#sectionIndex, VariableWorkWidth.lua:373-376),
-- eight 3 m sections, and no maxWidthNode: the work areas are the only geometry. With
-- overlap, each work area reaches that far past both of its section's edges.
local PS_TIPS = { 12, 9, 6, 3, -3, -6, -9, -12 }
local function perSectionBoom(overlap)
    overlap = overlap or 0
    local v = baseSprayer("ps", FT.LIQUIDFERTILIZER, 24)
    v.spec_workArea = { workAreas = {} }
    v.spec_variableWorkWidth = { sections = {} }
    for i, lat in ipairs(PS_TIPS) do
        local sign = lat > 0 and 1 or -1
        local inner = sign * (math.abs(lat) - 3 - overlap)
        local outer = sign * (math.abs(lat) + overlap)
        v.spec_variableWorkWidth.sections[i] = { isActive = true, effects = {}, lat = lat }
        v.spec_workArea.workAreas[i] = {
            sectionIndex = i,
            start = node(v, "s" .. i, inner, -1.0), width = node(v, "w" .. i, outer, -1.0), height = node(v, "h" .. i, inner, -1.5),
        }
    end
    sideLists(v)
    loadSprayTypes(v, { { fillTypes = { "liquidfertilizer" } } })
    return v
end

-- Streumaster FW 212 TD Profi (fw212tdProfi.xml:193-271, fw212tdProfi.i3d:579-599), as the
-- #1039 bench builds it: fertilizer work area 1's edges are the section nodes.
local SM_TIPS = { 21, 18, 15, 10.5, 9, 7.5, -7.5, -9, -10.5, -15, -18, -21 }
local function streumaster(multiTank, fillName)
    local v = baseSprayer("sm", FT[fillName or "FERTILIZER"], 12)
    v.spec_workArea = { workAreas = {
        { sprayType = 1, start = node(v, "waStart", 0, -3.79176),
          width = node(v, "waWidth", -7.5, -12.507525), height = node(v, "waHeight", 7.5, -12.507525) },
        { sprayType = 2, start = node(v, "waStartLime", 0, -3.79176),
          width = node(v, "waWidthLime", -7.5, -9.4), height = node(v, "waHeightLime", 7.5, -9.4) },
    } }
    v.spec_variableWorkWidth = { sections = {}, minTrans = 7.5,
                                 nodesLeft = { v.id .. ".waHeight" }, nodesRight = { v.id .. ".waWidth" } }
    for i, lat in ipairs(SM_TIPS) do
        v.spec_variableWorkWidth.sections[i] = {
            isActive = true, effects = {}, lat = lat, maxWidthNode = node(v, "section" .. i, lat, -12.508),
        }
    end
    sideLists(v)
    loadSprayTypes(v, {
        { fillTypes = { "fertilizer", "unknown" }, usageScales = { workAreaIndex = 1 } },
        { fillTypes = { "lime" }, supportsVariableWorkWidth = false, usageScales = { workingWidth = 15 } },
    })
    engineSetSections(v, 6, 6)
    if multiTank then
        v.spec_fillUnit.fillUnits[2] = { fillLevel = 1200, fillType = FT[fillName or "FERTILIZER"] }
        v.spec_sprayer.workAreaParameters.sprayVehicle = v
        v.spec_sprayer.workAreaParameters.sprayVehicleFillUnitIndex = 1
    end
    return v
end

-- ── Harness: production's two appends, in production's order ───────────────
local function newField()
    return { fieldArea = 10, sessionCoverageCells = {}, dailyCoverageCells = {}, zoneData = {},
             sessionCoverageFraction = 0 }
end

-- suppress: when given, an append on onStartWorkAreaProcessing installed after both
-- production hooks, so it runs after the preserver's save, as every Soil suppression
-- hook does (they are appended, the preserver prepends, HookManager.lua:771-808).
local function install(multiTank, suppress)
    Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
    g_currentMission = { time = 0, missionInfo = {} }
    local rec = { paint = {}, stamp = {} }
    local ss = setmetatable({
        fieldData = { [7] = newField(), [8] = newField() },
        onFertilizerApplied = function() return true end,
        onHerbicideAppliedDirect = function() end,
        paintBoomStrip = function(_, fId, pts, _name, line)
            rec.paint[#rec.paint + 1] = { f = fId, pts = pts, line = line }
        end,
        applyBurnEffect = function() end,
        applyScorchEffect = function() end,
    }, { __index = SoilFertilitySystem })
    -- A spy on the REAL stamper: records the array it was given, then stamps.
    ss.markBoomCells = function(self, fId, pts, overlayOnly, veh)
        rec.stamp[#rec.stamp + 1] = pts
        return SoilFertilitySystem.markBoomCells(self, fId, pts, overlayOnly, veh)
    end
    g_SoilFertilityManager = {
        settings = { enabled = true, multiTankApplication = multiTank == true },
        soilSystem = ss,
        sensorManager = {},
    }
    local hookMgr = setmetatable({
        hooks = {}, register = function() end, registerCleanup = function() end,
        getFieldIdAtWorldPosition = function() return 7 end,
        getTargetApplication = function() return nil end,
        _sectionScratch = {},
        customFillTypePrices = {}, customProductIndices = {}, refusedProducts = {},
    }, { __index = HookManager })
    HookManager.installSprayerAreaHook(hookMgr)
    HookManager.installSectionStatePreserver(hookMgr)
    if suppress then
        Sprayer.onStartWorkAreaProcessing = Utils.appendedFunction(Sprayer.onStartWorkAreaProcessing, suppress)
    end
    return ss, hookMgr, rec
end

-- One lane: 21 ticks of 2 m along the heading, the lane's centre line at 25 across it.
local TICKS = 21
local function driveLane(v)
    for k = 0, TICKS - 1 do
        if POSE.heading == "+X" then POSE.x, POSE.z = 2 * k, LANE_X
        elseif POSE.heading == "-X" then POSE.x, POSE.z = 40 - 2 * k, LANE_X
        else POSE.x, POSE.z = LANE_X, 2 * k end
        g_currentMission.time = g_currentMission.time + 100
        Sprayer.onStartWorkAreaProcessing(v, 100)
        Sprayer.onEndWorkAreaProcessing(v, 100, true)
    end
end
local function run(v, multiTank, suppress, heading)
    local ss, hookMgr, rec = install(multiTank, suppress)
    POSE.heading = heading or "+Z"
    driveLane(v)
    POSE.heading = "+Z"
    return ss, hookMgr, rec
end

-- Measurements, all of production's own output.
local function decode(key)
    local k = tonumber(key)
    local cx = math.floor((k + 5000) / 10000)
    return cx, k - cx * 10000
end
-- The stamped 10 m indices ACROSS the travel, per index along it, and whether all agree.
-- Driving along Z the across index is the column (cx); driving along X it is the row (cz).
local function columnsByRow(ss, alongX)
    local rows = {}
    for key in pairs(ss.fieldData[7].sessionCoverageCells) do
        local cx, cz = decode(key)
        if alongX then cx, cz = cz, cx end
        rows[cz] = rows[cz] or {}
        rows[cz][#rows[cz] + 1] = cx
    end
    local sig, nRows, same = nil, 0, true
    for _, cols in pairs(rows) do
        table.sort(cols)
        local s = table.concat(cols, ",")
        nRows = nRows + 1
        if sig == nil then sig = s elseif sig ~= s then same = false end
    end
    return sig or "", nRows, same
end
local function paintShape(rec)
    local nPts, span = nil, nil
    local same = true
    for _, p in ipairs(rec.paint) do
        local dx, dz = p.line.bx - p.line.ax, p.line.bz - p.line.az
        local s = math.sqrt(dx * dx + dz * dz)
        if nPts == nil then nPts, span = #p.pts, s
        elseif nPts ~= #p.pts or math.abs(span - s) > 1e-9 then same = false end
    end
    return nPts, span, same, #rec.paint
end

SBW = {
    LANE_X = LANE_X, TICKS = TICKS,
    cpBoom = cpBoom, perSectionBoom = perSectionBoom, streumaster = streumaster, centreBoom = centreBoom,
    switchOff = switchOff, engineSetSections = engineSetSections, run = run,
    columnsByRow = columnsByRow, paintShape = paintShape,
    restore = function()
        Sprayer, Utils = saved.Sprayer, saved.Utils
        g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
        g_SoilFertilityManager, g_fieldManager = saved.g_SoilFertilityManager, saved.g_fieldManager
        getWorldTranslation, localToLocal = saved.getWorldTranslation, saved.localToLocal
        localToWorld, worldToLocal, getWorldRotation = saved.localToWorld, saved.worldToLocal, saved.getWorldRotation
        FillType, ToolType = saved.FillType, saved.ToolType
    end,
}
