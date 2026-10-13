-- SF-1039-spray_type_width_spec_test.lua
--
-- #1039: a spreader's width is the width of the pass its ACTIVE spray type makes.
--
-- THE DEFECT THIS PINS (development 79e00157): Soil built the spreading width from
-- the nodes of every work area and every variable-width section, whatever the spray
-- type. The base game decides per work area (Sprayer:getIsWorkAreaActive,
-- Sprayer.lua:726-734: a work area naming another spray type is idle) and switches
-- the sections off for a spray type that does not support them
-- (Sprayer:onSprayTypeChange, Sprayer.lua:1034-1041, which leaves every section
-- active at full width, VariableWorkWidth.lua:290-296). So lime on the Streumaster
-- FW 212 TD Profi (15 m) was tracked, painted and credited at the fertilizer
-- sections' 42 m, and the Bredal K105 at its outermost 30 m in every configuration.
--
-- THE ENTRY-POINT BAR: every machine row installs the REAL installSprayerAreaHook and
-- drives Sprayer.onEndWorkAreaProcessing as the game does, through the REAL
-- getBoomCellPositions, getBoomLineEndpoints, markBoomCells and trackSprayerCoverage.
-- The fixture supplies what the engine supplies and nothing Soil should derive: the
-- work areas with their XML #sprayType, the section nodes where the i3d puts them,
-- and getActiveSprayType resolved from the tank's fill type and the folding
-- configuration by the engine's own rule (copied below). No active spray type, node
-- list or width is ever set by hand. Asserted: the boom line paintBoomStrip is given,
-- the cells markBoomCells stamps, the positions and fields the credit takes, and who
-- owns the coverage counter.
--
-- Geometry is taken from the base-game files, not from the issue's table:
--   Streumaster fw212tdProfi.xml:193-271 and fw212tdProfi.i3d:579-599
--   Bredal k105.xml:198, :235-301, :329-361 and k105.i3d:382-401
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = {
    Sprayer = Sprayer, Utils = Utils, g_fillTypeManager = g_fillTypeManager,
    g_currentMission = g_currentMission, g_SoilFertilityManager = g_SoilFertilityManager,
    g_fieldManager = g_fieldManager, getWorldTranslation = getWorldTranslation,
    localToLocal = localToLocal, localToWorld = localToWorld, getWorldRotation = getWorldRotation,
    FillType = FillType, ToolType = ToolType,
}

g_fieldManager = nil   -- no polygon: markBoomCells counts every cell
FillType = FillType or { UNKNOWN = 0 }
ToolType = ToolType or { UNDEFINED = 0 }
Utils = {
    appendedFunction = function(orig, new)
        return function(...)
            local r = orig and { orig(...) } or {}
            new(...)
            return unpack(r)
        end
    end,
}

-- Fill types. FillTypeManager:getFillTypeIndexByName upper-cases the name
-- (FillTypeManager.lua:305-310), so the XML's lower-case "lime" resolves.
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
-- Z is along travel. Lanes run along world +Z, so lateral maps onto world X.
local LANE_X = 5                                 -- mid-cell, like a real lane
local POSE = { x = LANE_X, z = 0 }
local LOCAL = {}                                 -- node -> { lateral, forward }
local function worldOf(lat, fwd) return POSE.x + lat, POSE.z + fwd end
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
getWorldRotation = function(_n) return 0, 0, 0 end   -- heading +Z

-- ── The engine's spray-type rule, copied so the fixture never picks one ───────
-- Sprayer:loadSprayTypeFromXML (Sprayer.lua:589-625) with Foldable:loadSprayTypeFromXML
-- (Foldable.lua:1141-1163): the index is the XML position, every entry is kept, and a
-- spray type for another folding configuration is flagged, not dropped.
local function loadSprayTypes(v, xmlSprayTypes, foldingConfig)
    local spec = v.spec_sprayer
    spec.sprayTypes = {}
    for _, x in ipairs(xmlSprayTypes) do
        local st = { fillUnitIndex = x.fillUnitIndex or 1, fillTypes = x.fillTypes }
        st.supportsVariableWorkWidth = x.supportsVariableWorkWidth ~= false
        st.hasRequiredFoldingConfiguration = true
        if foldingConfig ~= nil and x.foldingConfigurationIndex ~= nil
                and foldingConfig ~= x.foldingConfigurationIndex then
            st.hasRequiredFoldingConfiguration = false
        end
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

-- Foldable:getIsSprayTypeActive (Foldable.lua:1164-1176) wrapping
-- Sprayer:getIsSprayTypeActive (Sprayer.lua:634-648), and Sprayer:getActiveSprayType
-- (Sprayer.lua:626-633). None of these machines' spray types sets a fold limit.
local function engineGetIsSprayTypeActive(self, sprayType)
    if sprayType.hasRequiredFoldingConfiguration == false then return false end
    if sprayType.fillTypes ~= nil then
        local retValue = false
        local currentFillType = self:getFillUnitFillType(sprayType.fillUnitIndex or self.spec_sprayer.fillUnitIndex)
        for _, fillType in ipairs(sprayType.fillTypes) do
            if currentFillType == g_fillTypeManager:getFillTypeIndexByName(fillType) then
                retValue = true
            end
        end
        if not retValue then return false end
    end
    return true
end
local function engineGetActiveSprayType(self)
    for _, sprayType in ipairs(self.spec_sprayer.sprayTypes) do
        if engineGetIsSprayTypeActive(self, sprayType) then return sprayType end
    end
    return nil
end

-- WorkArea:updateWorkAreaWidth / getWorkAreaWidth (WorkArea.lua:307-318).
local function engineGetWorkAreaWidth(self, workAreaIndex)
    local wa = self.spec_workArea.workAreas[workAreaIndex]
    local x1 = localToLocal(wa.start, self.components[1].node, 0, 0, 0)
    local x2 = localToLocal(wa.width, self.components[1].node, 0, 0, 0)
    local x3 = localToLocal(wa.height, self.components[1].node, 0, 0, 0)
    return math.max(x1, x2, x3) - math.min(x1, x2, x3)
end

-- VariableWorkWidth:updateSections (VariableWorkWidth.lua:329-336): each side's
-- sections sorted inner to outer, the first `state` active, and the side's section
-- nodes (the fertilizer work area's edges) moved to the outermost active tip.
-- Sprayer:onSprayTypeChange + VariableWorkWidth:setVariableWorkWidthActive: a spray
-- type without variable work width sets both sides to full width.
local function engineSetSections(v, left, right)
    local vww = v.spec_variableWorkWidth
    for _, side in ipairs({ { vww.sectionsLeft, left, vww.nodesLeft }, { vww.sectionsRight, right, vww.nodesRight } }) do
        local sections, state, nodes = side[1], side[2], side[3]
        for i, s in ipairs(sections) do s.isActive = i <= state end
        local tip = state == 0 and vww.minTrans or math.abs(LOCAL[sections[state].maxWidthNode][1])
        for _, n in ipairs(nodes) do
            local sign = LOCAL[n][1] < 0 and -1 or 1
            LOCAL[n][1] = sign * tip
        end
    end
end
local function engineSprayTypeChange(v)
    local st = v:getActiveSprayType()
    if v.spec_variableWorkWidth and st ~= nil and st.supportsVariableWorkWidth == false then
        engineSetSections(v, #v.spec_variableWorkWidth.sectionsLeft, #v.spec_variableWorkWidth.sectionsRight)
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

-- Streumaster FW 212 TD Profi. Work area 1 (fertilizer) has its width/height nodes
-- driven by the sections between 7.5 and 21 m (fw212tdProfi.xml:255-256); work area
-- 2 (lime) sits at +-7.5 m (fw212tdProfi.i3d:597-599). Twelve sections, tips at
-- 7.5 / 9 / 10.5 / 15 / 18 / 21 m either side (fw212tdProfi.i3d:584-595).
local SM_TIPS = { 21, 18, 15, 10.5, 9, 7.5, -7.5, -9, -10.5, -15, -18, -21 }
local function streumaster(fillName, partial, multiTank)
    local v = baseSprayer("sm", FT[fillName], 12)
    v.spec_workArea = { workAreas = {
        { sprayType = 1, start = node(v, "waStart", 0, -3.79176),
          width = node(v, "waWidth", -7.5, -12.507525), height = node(v, "waHeight", 7.5, -12.507525) },
        { sprayType = 2, start = node(v, "waStartLime", 0, -3.79176),
          width = node(v, "waWidthLime", -7.5, -9.4), height = node(v, "waHeightLime", 7.5, -9.4) },
    } }
    local vww = { sections = {}, sectionsLeft = {}, sectionsRight = {}, minTrans = 7.5,
                  nodesLeft = { v.id .. ".waHeight" }, nodesRight = { v.id .. ".waWidth" } }
    for i, lat in ipairs(SM_TIPS) do
        local s = { isActive = true, maxWidthNode = node(v, "section" .. i, lat, -12.508), effects = {} }
        vww.sections[i] = s
        table.insert(lat > 0 and vww.sectionsLeft or vww.sectionsRight, s)
    end
    local byWidth = function(a, b) return math.abs(LOCAL[a.maxWidthNode][1]) < math.abs(LOCAL[b.maxWidthNode][1]) end
    table.sort(vww.sectionsLeft, byWidth)
    table.sort(vww.sectionsRight, byWidth)
    v.spec_variableWorkWidth = vww
    loadSprayTypes(v, {
        { fillTypes = { "fertilizer", "unknown" }, usageScales = { workAreaIndex = 1 } },
        { fillTypes = { "lime" }, supportsVariableWorkWidth = false, usageScales = { workingWidth = 15 } },
    })
    engineSetSections(v, partial or 6, partial or 6)
    engineSprayTypeChange(v)
    if multiTank then
        -- The crane shovel's own fill unit (fw212tdProfi.xml:545), holding the same lime.
        v.spec_fillUnit.fillUnits[2] = { fillLevel = 1200, fillType = FT[fillName] }
        v.spec_sprayer.workAreaParameters.sprayVehicle = v
        v.spec_sprayer.workAreaParameters.sprayVehicleFillUnitIndex = 1
    end
    return v
end

-- Bredal K105. Four spray types keyed on the folding configuration (k105.xml:235-301),
-- four work areas with #sprayType 1-4 (k105.xml:329-344), no sections. Node
-- positions from k105.i3d:384-401.
local function bredal(fillName, foldingConfig)
    local v = baseSprayer("k105", FT[fillName], 24)
    local function wa(st, name, half, fwd)
        return { sprayType = st, start = node(v, "start" .. name, 0, -3.906359),
                 width = node(v, "width" .. name, -half, fwd), height = node(v, "height" .. name, half, fwd) }
    end
    v.spec_workArea = { workAreas = {
        wa(1, "SmallFertilizer", 12, -9), wa(2, "SmallLime", 6, -9),
        wa(3, "BigFertilizer", 15, -7.5), wa(4, "BigLime", 9, -7.5),
    } }
    loadSprayTypes(v, {
        { foldingConfigurationIndex = 1, fillTypes = { "fertilizer", "unknown" }, usageScales = { workingWidth = 24 } },
        { foldingConfigurationIndex = 1, fillTypes = { "lime" }, usageScales = { workingWidth = 12 } },
        { foldingConfigurationIndex = 2, fillTypes = { "fertilizer", "unknown" }, usageScales = { workingWidth = 30 } },
        { foldingConfigurationIndex = 2, fillTypes = { "lime" }, usageScales = { workingWidth = 18 } },
    }, foldingConfig)
    return v
end

-- A broadcast spreader with no spanning work-area nodes (the #758 fallback), sized
-- like the Bredal's discs: machine 24 m, fertilizer 24 m, lime 12 m.
local function broadcast(fillName)
    local v = baseSprayer("bc", FT[fillName], 24)
    loadSprayTypes(v, {
        { fillTypes = { "fertilizer", "unknown" }, usageScales = { workingWidth = 24 } },
        { fillTypes = { "lime" }, usageScales = { workingWidth = 12 } },
    })
    return v
end

-- A single-product section boom (the Hardi Mega 1200L layout the overlap bar uses):
-- 9 sections, tips +-3.5 / 6 / 9 / 12 m, one work area without a #sprayType.
-- sprayTypes: nil for none at all, or a list of XML entries.
local HARDI_LAT = { -12, -9, -6, -3.5, false, 3.5, 6, 9, 12 }
local function sectionBoom(fillName, xmlSprayTypes)
    local v = baseSprayer("hardi", FT[fillName], 24)
    v.spec_workArea = { workAreas = { {
        start = node(v, "waS", 12, -0.46), width = node(v, "waW", -12, -0.46), height = node(v, "waH", 12, -0.6),
    } } }
    v.spec_variableWorkWidth = { sections = {} }
    for i, lat in ipairs(HARDI_LAT) do
        v.spec_variableWorkWidth.sections[i] = {
            isActive = true, effects = {}, isCenter = (lat == false) or nil,
            maxWidthNode = lat and node(v, "mw" .. i, lat, -0.46) or nil,
        }
    end
    loadSprayTypes(v, xmlSprayTypes or {})
    return v
end

-- ── Harness: the real append on onEndWorkAreaProcessing ─────────────────────
local function newField()
    return { fieldArea = 10, sessionCoverageCells = {}, dailyCoverageCells = {}, zoneData = {},
             sessionCoverageFraction = 0 }
end

local FIELD_HALF = 9   -- field 7 is the 18 m strip under the lane, field 8 is next door

local function install(multiTank)
    Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
    g_currentMission = { time = 0, missionInfo = {} }
    local rec = { credit = {}, paint = {} }
    local ss = setmetatable({
        fieldData = { [7] = newField(), [8] = newField() },
        -- The credit's downstream is not under test; where it was sent is.
        onFertilizerApplied = function(self, fId)
            rec.credit[#rec.credit + 1] = { f = fId, x = self._lastSprayX, z = self._lastSprayZ }
            return true
        end,
        onHerbicideAppliedDirect = function(self, fId)
            rec.credit[#rec.credit + 1] = { f = fId, x = self._lastSprayX, z = self._lastSprayZ }
        end,
        paintBoomStrip = function(_, fId, pts, _name, line)
            rec.paint[#rec.paint + 1] = { f = fId, pts = pts, line = line }
        end,
        applyBurnEffect = function() end,
        applyScorchEffect = function() end,
    }, { __index = SoilFertilitySystem })
    g_SoilFertilityManager = {
        settings = { enabled = true, multiTankApplication = multiTank == true },
        soilSystem = ss,
        sensorManager = {},
    }
    local hookMgr = setmetatable({
        hooks = {}, register = function() end, registerCleanup = function() end,
        getFieldIdAtWorldPosition = function(_, x, _z)
            return (math.abs(x - LANE_X) <= FIELD_HALF) and 7 or 8
        end,
        getTargetApplication = function() return nil end,
        _sectionScratch = {},
        customFillTypePrices = {}, customProductIndices = {}, refusedProducts = {},
    }, { __index = HookManager })
    HookManager.installSprayerAreaHook(hookMgr)
    return ss, hookMgr, rec
end

-- One lane: 21 ticks along +Z at the lane's x, the credit append each tick.
local TICKS = 21
local function driveLane(v)
    for k = 0, TICKS - 1 do
        POSE.x, POSE.z = LANE_X, 2 * k
        g_currentMission.time = g_currentMission.time + 100
        Sprayer.onStartWorkAreaProcessing(v, 100)
        Sprayer.onEndWorkAreaProcessing(v, 100, true)
    end
end

local function run(v, multiTank, prep)
    local ss, hookMgr, rec = install(multiTank)
    if prep then prep(ss) end
    driveLane(v)
    return ss, hookMgr, rec
end

-- Measurements, all of production's own output.
local function lineSpan(line)
    if not line then return 0 end
    local dx, dz = line.bx - line.ax, line.bz - line.az
    return math.sqrt(dx * dx + dz * dz)
end
local function spans(rec)                 -- every boom line production painted
    local lo, hi = math.huge, 0
    for _, p in ipairs(rec.paint) do
        local s = lineSpan(p.line)
        lo, hi = math.min(lo, s), math.max(hi, s)
    end
    return lo, hi, #rec.paint
end
local function cellColumns(ss)            -- the stamped 10 m columns of field 7
    local cols, n = {}, 0
    for key in pairs(ss.fieldData[7].sessionCoverageCells) do
        local cx = math.floor((tonumber(key) + 5000) / 10000)
        if not cols[cx] then cols[cx] = true; n = n + 1 end
    end
    local list = {}
    for cx in pairs(cols) do list[#list + 1] = cx end
    table.sort(list)
    return list, n
end
local function maxCellReach(ss)           -- furthest stamped cell centre from the lane
    local list = cellColumns(ss)
    local reach = 0
    for _, cx in ipairs(list) do reach = math.max(reach, math.abs(cx * 10 + 5 - LANE_X)) end
    return reach
end
local function credits(rec)               -- count, furthest lateral offset, any on field 8
    local maxLat, onNeighbour = 0, 0
    for _, c in ipairs(rec.credit) do
        maxLat = math.max(maxLat, math.abs((c.x or LANE_X) - LANE_X))
        if c.f == 8 then onNeighbour = onNeighbour + 1 end
    end
    return #rec.credit, maxLat, onNeighbour
end

-- ══════════════════════════════════════════════════════════
-- S: STREUMASTER WITH LIME (Sauge's measured case)
-- ══════════════════════════════════════════════════════════
do
    local v = streumaster("LIME")
    T.eq("S0 the engine rule picks the lime spray type from the tank (fixture sanity)",
         v:getActiveSprayType().index, 2)
    local ss, _, rec = run(v)
    local lo, hi, n = spans(rec)
    T.ok("S1a lime: the pH strip is painted every tick", n == TICKS)
    T.near("S1 lime: the painted pH strip is the lime work area's 15 m, not the sections' 42 m", hi, 15, 1e-6)
    T.near("S1b lime: and it is 15 m on every tick", lo, 15, 1e-6)
    T.ok("S2 lime: no stamped cell lies more than half the lime width plus one cell from the lane",
         maxCellReach(ss) <= 15 / 2 + 10)
    local nCred, maxLat, onNb = credits(rec)
    T.eq("S3 lime: the credit lands once per tick, at the spreader's root", nCred, TICKS)
    T.near("S3b lime: no credit is resolved off the root (the section midpoints reached 10.5 m)", maxLat, 0, 1e-9)
    T.eq("S4 lime: nothing is credited to the neighbouring field", onNb, 0)
    T.ok("S5 lime: the cells are the overlay only; coverage comes from the litres, as on the Bredal",
         ss.fieldData[7]._geometricCoverageOwner ~= true)
    -- Only the counting stamp (markBoomCells with overlayOnly false) writes the daily cell
    -- set; the overlay never does, and nothing clears it within a pass.
    T.eq("S5b lime: no stamp counted a cell as sectioned coverage", next(ss.fieldData[7].dailyCoverageCells), nil)
end

-- The crane shovel's unit holding lime too: the multi-tank replay stamps and credits
-- by the same rule as the primary.
do
    local v = streumaster("LIME", nil, true)
    local ss, _, rec = run(v, true)
    local lo, hi, n = spans(rec)
    T.eq("M1 multi-tank lime: the primary and the replay both paint every tick", n, 2 * TICKS)
    T.ok("M2 multi-tank lime: every painted strip is 15 m",
         math.abs(lo - 15) < 1e-6 and math.abs(hi - 15) < 1e-6)
    local nCred, maxLat = credits(rec)
    T.eq("M3 multi-tank lime: primary and replay each credit once per tick", nCred, 2 * TICKS)
    T.near("M4 multi-tank lime: every credit at the root", maxLat, 0, 1e-9)
    -- The owner flag cannot show the replay's stamp: the primary's litre branch clears it
    -- after the replay every tick. The daily cell set is written only by a counting stamp.
    T.eq("M5 multi-tank lime: the replay's stamp is the overlay only too",
         next(ss.fieldData[7].dailyCoverageCells), nil)
end

-- ══════════════════════════════════════════════════════════
-- F / P: STREUMASTER WITH FERTILIZER, STILL GOVERNED BY ITS SECTIONS
-- ══════════════════════════════════════════════════════════
do
    local v = streumaster("FERTILIZER")
    T.eq("F0 the engine rule picks the fertilizer spray type (fixture sanity)", v:getActiveSprayType().index, 1)
    local ss, _, rec = run(v)
    local _, hi = spans(rec)
    T.near("F1 fertilizer, full width: the strip is the sections' 42 m", hi, 42, 1e-6)
    local nCred, maxLat = credits(rec)
    T.eq("F2 fertilizer: credited per active section, 12 per tick", nCred, 12 * TICKS)
    T.near("F2b fertilizer: the outer section's midpoint is 10.5 m out", maxLat, 10.5, 1e-6)
    T.eq("F3 fertilizer: the sectioned cell dedup owns the coverage counter",
         ss.fieldData[7]._geometricCoverageOwner, true)
    T.ok("F3b fertilizer: and its stamp counts cells (the contrast to S5b and M5)",
         next(ss.fieldData[7].dailyCoverageCells) ~= nil)
end
do
    local v = streumaster("FERTILIZER", 3)   -- Partial Width: three sections a side
    local ss, _, rec = run(v)
    local _, hi = spans(rec)
    T.near("P1 fertilizer, Partial Width 3+3: the strip narrows to the active tips, 21 m", hi, 21, 1e-6)
    local nCred, maxLat = credits(rec)
    T.eq("P2 Partial Width: the inactive sections are skipped, 6 credits per tick", nCred, 6 * TICKS)
    T.near("P2b Partial Width: the outer active midpoint is 5.25 m out", maxLat, 5.25, 1e-6)
    T.ok("P3 Partial Width: no stamped cell reaches past the active tips plus one cell",
         maxCellReach(ss) <= 21 / 2 + 10)
end

-- ══════════════════════════════════════════════════════════
-- B: BREDAL K105, EVERY CONFIGURATION AND PRODUCT
-- ══════════════════════════════════════════════════════════
for _, c in ipairs({
    { "B1", 1, "LIME", 12, "discs, lime" },
    { "B2", 1, "FERTILIZER", 24, "discs, fertilizer" },
    { "B3", 2, "LIME", 18, "6 m unit, lime" },
    { "B4", 2, "FERTILIZER", 30, "6 m unit, fertilizer" },
}) do
    local v = bredal(c[3], c[2])
    local ss, _, rec = run(v)
    local lo, hi = spans(rec)
    T.ok(c[1] .. " Bredal " .. c[5] .. ": the strip is " .. c[4] .. " m on every tick",
         math.abs(lo - c[4]) < 1e-6 and math.abs(hi - c[4]) < 1e-6)
    T.ok(c[1] .. "b Bredal " .. c[5] .. ": no stamped cell past half the width plus one cell",
         maxCellReach(ss) <= c[4] / 2 + 10)
    local nCred, maxLat = credits(rec)
    T.ok(c[1] .. "c Bredal " .. c[5] .. ": no sections, so one credit per tick at the root",
         nCred == TICKS and maxLat == 0)
end

-- ══════════════════════════════════════════════════════════
-- FB: THE WORKING-WIDTH FALLBACK FOLLOWS THE SPRAY TYPE
-- No spanning node: getBoomCellPositions and getBoomLineEndpoints both fall back.
-- ══════════════════════════════════════════════════════════
do
    local _, _, rec = run(broadcast("LIME"))
    local _, hi = spans(rec)
    T.near("FB1 fallback, lime: the boom line is the lime spray type's 12 m, not the machine's 24 m", hi, 12, 1e-6)
    local pts = rec.paint[#rec.paint] and rec.paint[#rec.paint].pts
    T.near("FB2 fallback, lime: the cell sweep starts half the lime width from the root",
         pts and (pts[1].x - LANE_X) or 0, -6, 1e-6)
    local _, _, rec2 = run(broadcast("FERTILIZER"))
    local _, hi2 = spans(rec2)
    T.near("FB3 fallback, fertilizer: 24 m", hi2, 24, 1e-6)
end
do
    -- A spray type that sizes from a work area (Sprayer.lua:517-521): the fallback
    -- takes that work area's engine width, as the usage override does.
    local v = streumaster("FERTILIZER")
    local hm = setmetatable({}, { __index = HookManager })
    T.near("FB4 a spray type sized by workAreaIndex: the fallback width is that work area's width",
         hm:_implWorkingWidth(v), 42, 1e-6)
    local vl = streumaster("LIME")
    T.near("FB5 and the lime spray type's own workingWidth on the same machine", hm:_implWorkingWidth(vl), 15, 1e-6)
end

-- ══════════════════════════════════════════════════════════
-- X: A NON-VARIABLE-WIDTH CROP PROTECTION PASS KEEPS ITS LITRE COVERAGE
-- The overlay-only stamp never claims the counter, so a stale claim from an earlier
-- sectioned pass must be cleared before the litres count (F61).
-- ══════════════════════════════════════════════════════════
do
    local v = sectionBoom("HERBICIDE", {
        { fillTypes = { "liquidfertilizer" } },
        { fillTypes = { "herbicide" }, supportsVariableWorkWidth = false },
    })
    local ss = run(v, false, function(ssPrep)
        ssPrep.fieldData[7]._geometricCoverageOwner = true
        ssPrep.fieldData[7].sessionLastProduct = "HERBICIDE"
    end)
    T.ok("X1 herbicide on a spray type without variable width: coverage still advances",
         (ss.fieldData[7].sessionCoverageHa or 0) > 0)
end

-- ══════════════════════════════════════════════════════════
-- C: CONTROLS, identical to development 79e00157
-- ══════════════════════════════════════════════════════════
local function signature(ss, rec)
    local cols = cellColumns(ss)
    local _, hi = spans(rec)
    local nCred, maxLat = credits(rec)
    return string.format("cols=%s span=%.4f credits=%d maxLat=%.4f owner=%s",
        table.concat(cols, ","), hi, nCred, maxLat, tostring(ss.fieldData[7]._geometricCoverageOwner))
end
do
    local ss, _, rec = run(sectionBoom("LIQUIDFERTILIZER", nil))
    T.eq("C1 a section boom with no spray types paints, credits and counts exactly as before",
         signature(ss, rec), "cols=-1,0,1 span=24.0000 credits=189 maxLat=6.0000 owner=true")
    local ss2, _, rec2 = run(sectionBoom("LIQUIDFERTILIZER", { { fillTypes = { "liquidfertilizer" } } }))
    T.eq("C2 a section boom with one spray type: the same",
         signature(ss2, rec2), "cols=-1,0,1 span=24.0000 credits=189 maxLat=6.0000 owner=true")
end
do
    -- A tillage implement (no getActiveSprayType): _recordTillagePoint's line is unchanged.
    local cult = { id = "cult", rootNode = "cult.root", components = { { node = "cult.frame" } } }
    LOCAL[cult.rootNode] = { 0, 0 }
    LOCAL[cult.components[1].node] = { 0, 0 }
    cult.spec_workArea = { workAreas = { {
        start = node(cult, "s", 3, -1), width = node(cult, "w", -3, -1), height = node(cult, "h", 3, -2),
    } } }
    local hm = setmetatable({}, { __index = HookManager })
    POSE.x, POSE.z = LANE_X, 0
    T.near("C3 a cultivator's work line is its work area, as before", lineSpan(hm:getBoomLineEndpoints(cult)), 6, 1e-6)
end

Sprayer, Utils = saved.Sprayer, saved.Utils
g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
g_SoilFertilityManager, g_fieldManager = saved.g_SoilFertilityManager, saved.g_fieldManager
getWorldTranslation, localToLocal = saved.getWorldTranslation, saved.localToLocal
localToWorld, getWorldRotation = saved.localToWorld, saved.getWorldRotation
FillType, ToolType = saved.FillType, saved.ToolType
