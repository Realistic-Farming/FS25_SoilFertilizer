-- CD-15-native_cell_probe_spec_test.lua - the read-only native cell probe.
--
-- Chore chore/CD-15-native-cell-probe: the geometry, classification and
-- comparison the probe logs are pure and pinned here; the engine parts
-- (modifier execute, per-pixel reads) are driven through stubs that record
-- the calls, and the four-surface hook is proved to delegate once with
-- unchanged arguments, to be a pure pass-through while off, and to restore
-- every slot on "hooks off". Nothing here measures a real map.
--
--!load: src/utils/Logger.lua, src/probe/CD15NativeCellProbe.lua

local P = CD15NativeCellProbe
SoilLogger = SoilLogger or { info = function() end }
local logged = {}
SoilLogger.info = function(msg) logged[#logged + 1] = tostring(msg) end
local function anyLog(sub) for _, l in ipairs(logged) do if l:find(sub, 1, true) then return true end end return false end

-- (A) Cell geometry, the reference bar's half-open rule.
do
    T.eq("A1 cell size", P.cellSizeMetres(4096, 2048), 2)
    local gx, gz = P.cellOfWorld(-2048, -2048, 4096, 2048)
    T.eq("A2 negative map edge is admitted", gx .. "," .. gz, "0,0")
    T.eq("A3 positive exclusive edge refuses", P.cellOfWorld(2048, 0, 4096, 2048), nil)
    T.eq("A4 off-map refuses instead of borrowing an edge", P.cellOfWorld(-2049, 0, 4096, 2048), nil)
    T.eq("A5 non-finite refuses", P.cellOfWorld(0/0, 0, 4096, 2048), nil)
    local cx, cz = P.cellOfWorld(0, 0, 4096, 2048)
    T.eq("A6 origin cell", cx .. "," .. cz, "1024,1024")
    local minX, minZ, maxX, maxZ = P.cellBounds(1024, 1024, 4096, 2048)
    T.eq("A7 origin cell bounds", (minX == 0 and minZ == 0 and maxX == 2 and maxZ == 2), true)
    local sx, sz, wx, wz, hx, hz = P.cellParallelogram(1024, 1024, 4096, 2048, 0)
    T.eq("A8 exact parallelogram start/width/height", (sx == 0 and sz == 0 and wx == 2 and wz == 0 and hx == 0 and hz == 2), true)
    local ix, iz, iwx, iwz, ihx, ihz = P.cellParallelogram(1024, 1024, 4096, 2048, 0.1)
    T.eq("A9 inset pulls every edge in", (math.abs(ix - 0.1) < 1e-9 and math.abs(iwx - 1.9) < 1e-9 and math.abs(ihz - 1.9) < 1e-9 and math.abs(iz - 0.1) < 1e-9), true)
    T.eq("A10 an inset that swallows the cell refuses", P.cellParallelogram(1024, 1024, 4096, 2048, 1), nil)
    T.eq("A11 a 16x map cell is 4 m at the resolution clamp", P.cellSizeMetres(16384, 4096), 4)
end

-- (B) State classification.
do
    local desc = { numStateChannels = 4, cutStates = { [9] = true }, witheredState = 10 }
    T.eq("B1 zero is empty", P.classifyState(desc, 0), "empty")
    T.eq("B2 cut state", P.classifyState(desc, 9), "cut")
    T.eq("B3 withered state", P.classifyState(desc, 10), "withered")
    T.eq("B4 growing state is living", P.classifyState(desc, 3), "living")
    T.eq("B5 out-of-range state is other (modded plane)", P.classifyState(desc, 16), "other")
    T.eq("B6 nil state is other", P.classifyState(desc, nil), "other")
    T.eq("B7 no descriptor is other", P.classifyState(nil, 3), "other")
    -- Decode: the engine's band(rshift(word, startStateChannel), 2^n - 1).
    local offset = { startStateChannel = 2, numStateChannels = 4, getGrowthStateByDensityState = function(self, s) return math.floor(s / 4) % 16 end }
    T.eq("B8 raw word decodes through the descriptor method", P.decodeGrowthState(offset, 36), 9)
    T.eq("B9 without the method the shift and mask are applied", P.decodeGrowthState({ startStateChannel = 2, numStateChannels = 4 }, 36 + 128), 9)
    T.eq("B10 non-finite word decodes to nil", P.decodeGrowthState(offset, 0/0), nil)
end

-- (C) Comparison rows and timing summary.
do
    local rows = P.compareCounts({ living = 10, cut = 2, any = 12, total = 16 }, { living = 11, cut = 2, any = 13, total = 16 })
    T.eq("C1 seven rows in order", #rows .. rows[1].class, "7living")
    T.eq("C2 delta is modifier minus point", rows[1].delta, 1)
    T.eq("C3 missing classes count zero", rows[3].point .. rows[3].modifier, "00")
    local s = P.summarizeTimings({ 0.000010, 0.000030, 0/0 })
    T.eq("C4 mean over finite samples in microseconds", string.format("%.1f", s.meanUs), "20.0")
    T.eq("C5 max in microseconds", string.format("%.1f", s.maxUs), "30.0")
    T.eq("C6 non-finite samples ignored", s.n, 2)
    T.eq("C7 empty summary", P.summarizeTimings({}).n, 0)
end

-- (D) Cells under a work-area quad.
do
    local cells = P.cellsUnderQuad(0, 0, 3, 0, 0, 3, 4096, 2048)
    T.eq("D1 a 3 m quad over 2 m cells touches four cells", #cells, 4)
    T.eq("D2 first cell is the origin cell", cells[1].gx .. "," .. cells[1].gz, "1024,1024")
    local edge = P.cellsUnderQuad(2046, 2046, 2050, 2046, 2046, 2050, 4096, 2048)
    T.eq("D3 a quad past the map edge stops at the last cell", #edge, 1)
end

-- (E) Engine parts through recording stubs.
do
    local executes, params = 0, nil
    DensityCoordType = { POINT_POINT_POINT = 3 }
    DensityValueCompareType = { EQUAL = 3, GREATER = 1, BETWEEN = 2 }
    DensityTypeCompareType = { EQUAL = 1, ALWAYS = 0 }
    local typedFilters, planeFormFilters = 0, 0
    DensityMapModifier = { new = function() return { setParallelogramWorldCoords = function(_, ...) params = { ... } end } end }
    DensityMapFilter = { new = function(a, b, c)
        if type(a) == "number" then planeFormFilters = planeFormFilters + 1 end
        return { setValueCompareParams = function() end, setTypeIndexCompareMode = function(_, mode) if mode == 1 then typedFilters = typedFilters + 1 end end }
    end }
    DensityMapMultiModifier = { new = function()
        return { gets = 0, addExecuteGet = function(self) self.gets = self.gets + 1 end, resetStats = function() end,
            execute = function(_, _, stats) executes = executes + 1 stats.s3 = 5 stats.s9 = 2 stats.any = 7 return 0, 0, 0, 16 end }
    end }
    getDensityMapSize = function() return 1024 end
    getTimeSec = function() return 0 end
    g_terrainNode = 1
    local function decode(self, s) return math.floor(s / 2 ^ self.startStateChannel) % 2 ^ self.numStateChannels end
    local desc = { name = "WHEAT", terrainDataPlaneId = 42, startStateChannel = 0, numStateChannels = 4, cutStates = { [9] = true }, witheredState = 10, getGrowthStateByDensityState = decode }
    local barley = { name = "BARLEY", terrainDataPlaneId = 42, startStateChannel = 0, numStateChannels = 4, cutStates = { [9] = true }, witheredState = 10, getGrowthStateByDensityState = decode }
    local ownerByType = { [1] = desc, [2] = barley }
    g_fruitTypeManager = { getFruitTypes = function() return { desc, { name = "NOPLANE" } } end,
        getFruitTypeByDensityTypeIndex = function(_, i) return ownerByType[i] end }
    g_SoilFertilityManager = { soilSystem = { valueMaps = { terrainSize = 2048, resolution = 1024 } } }
    P.state.fruits = nil
    local fruits = P.ensureFruitCache()
    T.eq("E1 one fruit with a plane is cached", #fruits, 1)
    T.eq("E2 one executeGet per raw state plus any", fruits[1].multi.gets, 16)
    T.eq("E2b typed machine has the same gets", fruits[1].multiTyped.gets, 16)
    T.eq("E2c typed filters use the plane form with type-index EQUAL", planeFormFilters .. "/" .. typedFilters, "16/16")
    T.eq("E3 fruit pixel metres from the plane size", fruits[1].pixelMetres, 2)
    T.eq("E4 a plane used by one fruit is not shared", fruits[1].planeShared, false)
    local counts = P.countCellModifier(fruits[1], 512, 512, 0)
    T.eq("E5 one execute", executes, 1)
    T.eq("E6 living from state 3", counts.living, 5)
    T.eq("E7 cut from state 9", counts.cut, 2)
    T.eq("E8 empty is touched minus classified", counts.empty, 9)
    T.eq("E9 parallelogram used POINT_POINT_POINT", params[7], 3)
    local typedCounts = P.countCellModifier(fruits[1], 512, 512, 0, true)
    T.eq("E9b typed pass executes the typed machine", executes .. "/" .. typedCounts.cut, "2/2")
    -- Point enumeration: 2 m cell, 2 m pixel: one sample; both reads called.
    local reads = {}
    getDensityTypeIndexAtWorldPos = function(plane, x, y, z) reads[#reads + 1] = "t" return 1 end
    getDensityStatesAtWorldPos = function(plane, x, y, z) reads[#reads + 1] = "s" return 9 end
    local pts = P.countCellPoints(fruits[1], 512, 512)
    T.eq("E10 one pixel centre per 2 m cell at 2 m pixels", pts.total, 1)
    T.eq("E11 classified as cut", pts.cut, 1)
    T.eq("E12 both per-pixel reads made", #reads, 2)
    T.eq("E13 type index histogram kept", pts.typeIndexHistogram["1"], 1)
    T.eq("E13b the pixel is owned by WHEAT", pts.owned .. "/" .. pts.foreign, "1/0")
    T.ok("E13c the first raw word per growth state is logged beside its decode", anyLog("raw states word 9 decodes to growth state 9"))
    -- A pixel whose type index maps to another fruit on the same plane is foreign.
    getDensityTypeIndexAtWorldPos = function() return 2 end
    local foreign = P.countCellPoints(fruits[1], 512, 512)
    T.eq("E13d foreign pixel is not classified for WHEAT", foreign.cut .. "/" .. foreign.foreign .. "/" .. foreign.any, "0/1/0")
    T.eq("E13e the histogram still counts every pixel", foreign.typeIndexHistogram["2"], 1)
    -- A raw word carrying an offset decodes before classification.
    getDensityTypeIndexAtWorldPos = function() return 1 end
    desc.startStateChannel = 2
    getDensityStatesAtWorldPos = function() return 36 end
    local shifted = P.countCellPoints(fruits[1], 512, 512)
    T.eq("E13f offset word 36 classifies as cut (state 9), not other", shifted.cut .. "/" .. shifted.other, "1/0")
    desc.startStateChannel = 0
    getDensityStatesAtWorldPos = function() return 9 end
    logged = {}
    P.reportCell(512, 512)
    T.ok("E14 cell report logs the fruit row", anyLog("WHEAT plane 42"))
    T.ok("E15 cell report logs the comparison", anyLog("cut      point"))
    T.ok("E15b cell report logs the owned/foreign split", anyLog("owned by WHEAT: 1, foreign"))
    -- Shared plane: the typed column appears.
    fruits[1].planeShared = true
    logged = {}
    P.reportCell(512, 512)
    T.ok("E15c shared plane logs the typed column", anyLog("typed     2"))
    fruits[1].planeShared = false
    -- Area cap.
    logged = {}
    P.reportArea(-1024, -1024, 1023, 1023)
    T.ok("E15d area beyond the cell cap refuses", anyLog("area refused"))
    -- Log cap: the buffer never grows past LOG_CAP.
    P.state.log = {}
    for i = 1, P.LOG_CAP + 25 do P.reportPlanes() end
    T.eq("E15e in-memory log is capped", #P.state.log, P.LOG_CAP)
end

-- (F) Hooks: pure delegate while off, four surfaces wrapped, single delegation, restore.
do
    local calls = {}
    local function native(self, workArea, dt, ...) calls[#calls + 1] = { self, workArea, dt, n = select("#", ...) + 3, ... } return 7, 8, nil, 10 end
    Cutter = { processCutterArea = native }
    Mower = nil
    SowingMachine = nil
    g_vehicleTypeManager = { getTypes = function() return { combine = { functions = { processCutterArea = native } } } end }
    local workArea = { functionName = "processCutterArea", processingFunction = native, start = 1, width = 2, height = 3 }
    getWorldTranslation = function(n) if n == 1 then return 0, 0, 0 elseif n == 2 then return 3, 0, 0 else return 0, 0, 3 end end
    local vehicle = { processCutterArea = native, spec_workArea = { workAreas = { workArea } } }
    g_currentMission = { vehicleSystem = { vehicles = { vehicle } }, time = 1000 }
    P.state.hooks = nil
    P.state.enabled = false
    -- Off: a wrapper built directly is a pure delegate.
    local w = P.makeWrapper(P.HOOK_SITES[1], native)
    local a, b, c, d = w(vehicle, workArea, 16)
    T.eq("F1 off: delegates once", #calls, 1)
    T.eq("F2 off: arguments unchanged", calls[1][3], 16)
    T.eq("F3 off: returns passed through", a .. "," .. b .. "," .. tostring(c) .. "," .. d, "7,8,nil,10")
    P.hooksOn()
    T.eq("F4 hooks on wraps class, type, instance and work-area pointer", #P.state.hooks.originals, 4)
    T.ok("F5 the stored pointer is now the wrapper", workArea.processingFunction ~= native)
    logged = {}
    calls = {}
    local r1, r2, r3, r4 = workArea.processingFunction(vehicle, workArea, 33, "extra", nil, "tail")
    T.eq("F6 on: the stored pointer delegates exactly once", #calls, 1)
    T.eq("F7 on: unchanged arguments, extra arguments included", calls[1][3] .. "/" .. calls[1].n .. "/" .. tostring(calls[1][6]), "33/6/tail")
    T.eq("F8 on: every return passed through, nil holes kept", r1 .. "," .. r2 .. "," .. tostring(r3) .. "," .. r4, "7,8,nil,10")
    T.ok("F9 on: the frame is logged with before and after", anyLog("Cutter.processCutterArea frame 1000"))
    T.ok("F10 on: a same-frame after read is logged", anyLog("after (same frame)"))
    -- Throttle: the same cell set in the same frame does not log again; a new cell set does.
    logged = {}
    workArea.processingFunction(vehicle, workArea, 33)
    T.ok("F10b same cells, same frame: no second line", not anyLog("Cutter.processCutterArea frame"))
    getWorldTranslation = function(n) if n == 1 then return 10, 0, 10 elseif n == 2 then return 13, 0, 10 else return 10, 0, 13 end end
    workArea.processingFunction(vehicle, workArea, 33)
    T.ok("F10c a changed cell set logs", anyLog("Cutter.processCutterArea frame"))
    -- A slot re-wrapped after hooks on is left alone by hooks off.
    local ours = vehicle.processCutterArea
    local later = function(...) return ours(...) end
    vehicle.processCutterArea = later
    logged = {}
    P.hooksOff()
    T.eq("F11 off restores the class slot", Cutter.processCutterArea, native)
    T.eq("F12 off leaves a slot re-wrapped after us in place", vehicle.processCutterArea, later)
    T.eq("F13 off restores the work-area pointer", workArea.processingFunction, native)
    T.eq("F14 off restores the registered type slot", g_vehicleTypeManager:getTypes().combine.functions.processCutterArea, native)
    T.eq("F15 hooks cleared", P.state.hooks, nil)
    T.ok("F15b off logs the left-in-place count", anyLog("3 slots restored, 1 left in place"))
    calls = {}
    local l1, l2 = later(vehicle, workArea, 5)
    T.eq("F15c the retired wrapper under the later one is a pure delegate", #calls .. "/" .. l1 .. "," .. l2, "1/7,8")
    vehicle.processCutterArea = native
    T.eq("F16 console off is safe when nothing is installed", P.console("hooks", "off"), "hooks off")
    T.eq("F17 console usage line", P.console("nonsense"):sub(1, 11), "sfCd15Probe")
    T.eq("F18 reset clears the log", (function() P.reset() return #P.state.log end)(), 0)
end
