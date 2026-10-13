-- MAINT-107-108-membership_validation_spec_test.lua
--
-- MAINTENANCE rows 107 and 108, the RSF-F213 membership index at arm (GROUND-CONDITION-
-- CONTRACT v1.5 section 5; Bob's two MINORs on #1005; batch intake item 11).
--
-- Row 107: a saved index is trusted only when it came from the same save as the
-- condition bytes it indexes. The membership, age and wetness layers must all have
-- loaded from the save's files (the store's file set read as the epoch; no stamp is
-- written beside the index today, a reading the PR declares); otherwise the layer is
-- cleared and the index rebuilt from the truth. A layer of another width is
-- re-initialised at the grid's width and rebuilt, where it used to be left off. The
-- save reconciles a rebuild-required index before the layer files are written.
--
-- Row 108: a cell marked unavailable becomes a member (section 5), so a native throw
-- over an envelope made empty cells members for good. A member read from the saved
-- index with no record whose whole cell holds a KNOWN zero of native material leaves;
-- a cell holding material, a recorded cell, and any cell read while the height map is
-- invalid (the native read answers 0 then, DensityMapHeightUtil.lua:81-83) stay.
--
-- THE ENTRY POINT IS THE ARM, as S5's group I: SoilFertilitySystem.new, the wetness
-- owner armed by its real arm, the family armed in production's order (the coordinator
-- resolves the store's layer and builds its index). A saved index is the store's layer
-- as the save left it: E3 carries the bits the REAL carrier wrote after a real native
-- throw into the next world as its loaded file; V and E1-E2 lay down a save's bits by
-- hand, which is what a file on disk is. The save hook is a text witness (W1): the
-- save function writes XML and is not driven here.
--
--!env: modenv
--!load: tools/test/lua/RSF-F208-s3-engine_model.lua, src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/MaterialWetness.lua, src/integrations/SoilMaterialDownBridge.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua, src/ground/GroundNativeObserver.lua, src/ground/GroundMovementProjector.lua, src/ground/GroundMovementCarrier.lua
--!text: src/SoilFertilityManager.lua

local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

SoilValueMaps = SoilValueMaps or {}
SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX, SoilValueMaps.RAW_SPAN = 1, 255, 254
SoilValueMaps.new = function() return nil end

local FT = ENGINE.FT
local GRASS = ENGINE.FRUIT.GRASS

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local W = {}
local PRISTINE = { mowerStart = Mower.onStartWorkAreaProcessing, mowerEnd = Mower.onEndWorkAreaProcessing }
local SKY = { humidity = 0.65, temperature = 15, cloudCoverage = 0.5 }
--- The world, as S5's: a fresh engine, production's system with its real wetness owner
--- armed, the family armed in production's order. opts.valueMaps shapes the store
--- (membershipLoaded, conditionLoaded, membershipRes); opts.beforeArm lays down what a
--- save's files hold before the arm reads them.
-- [MAINTENANCE row 137] A saved index is trusted only with its save's stamp: the career
-- marker's generation equal to the stamp soilData.xml carries. This bench has no disk,
-- so a world that loads a saved index supplies that save's two files through the two
-- readers the coordinator asks (their own reads of real files are row 137's bench).
local REAL_READERS = { marker = SoilMaterialDownBridge.readCareerMarker, stamp = SoilMaterialDownBridge.readIndexStamp }
local function savedStamp(on)
    if on then
        SoilMaterialDownBridge.readCareerMarker = function() return { schema = 1, backend = "OWN_FILE", generation = 7, state = "EXPECTED" } end
        SoilMaterialDownBridge.readIndexStamp = function() return 7 end
    else
        SoilMaterialDownBridge.readCareerMarker, SoilMaterialDownBridge.readIndexStamp = REAL_READERS.marker, REAL_READERS.stamp
    end
end
local function world(today, opts)
    opts = opts or {}
    savedStamp(opts.valueMaps ~= nil and opts.valueMaps.membershipLoaded == true)
    HEIGHT.pixels = {}
    ENGINE.mowable = {}
    Mower.onStartWorkAreaProcessing, Mower.onEndWorkAreaProcessing = PRISTINE.mowerStart, PRISTINE.mowerEnd
    local settings = { enabled = true }
    local sys = SoilFertilitySystem.new(settings)
    local vm, age, wet, member = ENGINE.newValueMaps(opts.valueMaps)
    W.sys, W.vm, W.age, W.wet, W.member = sys, vm, age, wet, member
    W.registered = {}
    g_currentMission = {
        environment = { currentMonotonicDay = today, currentSeason = 2, daysPerPeriod = 3 },
        vehicleSystem = { vehicles = {} },
        weatherGuard = ENGINE.newWeatherGuard({ sky = SKY, rain = { rainScale = 0 } }),
        timeGuard = { registerAccrual = function(_, id, spec) W.registered[id] = spec return true end, unregisterAccrual = function() end },
        indoorMask = ENGINE.newIndoorMask({}),
    }
    g_currentMission.vehicleSystem.addVehicle = function(self, v) self.vehicles[#self.vehicles + 1] = v return true end
    g_SoilFertilityManager = { settings = settings, soilSystem = sys }
    sys.hookManager.getFieldIdAtWorldPosition = function(_, x, _z) if x < 0 then return 7 end return nil end
    sys.materialDown.ageAppliedThroughDay = today
    local armedWet = sys.materialWetness:arm(vm, sys.materialDown, sys)
    sys.materialWetness:deserialize({ appliedThroughDay = today })
    if opts.beforeArm then opts.beforeArm() end
    local a = sys.groundConditionCells:arm(vm)
    local b = a and sys.groundConditionCoordinator:arm(sys.groundConditionCells, sys.materialDown, sys.materialWetness, sys)
    local c = b and sys.groundConditionAdmission:arm(sys.groundConditionCoordinator, sys.groundConditionCells)
    SoilMaterialDownBridge.registerConditionAccrual(sys.materialWetness)
    return armedWet and a and b and c
end
local function coord() return W.sys.groundConditionCoordinator end
local function setCell(gx, gz, ageRaw, wetRaw) ENGINE.layerSet(W.age, gx, gz, ageRaw) ENGINE.layerSet(W.wet, gx, gz, wetRaw) end
local function bit(gx, gz) return ENGINE.layerGet(W.member, gx, gz) end
local function runs()
    local out = {}
    coord():enumerateMemberRuns(function(gz, gx0, gx1) out[#out + 1] = gz .. ":" .. gx0 .. "-" .. gx1 end)
    return table.concat(out, " ")
end
local function stats()
    local st = coord():getMembershipStats()
    return tostring(st and st.count) .. "/" .. tostring(st and st.source) .. "/" .. tostring(st and st.ready)
end
local function lines(list, needle)
    local n = 0
    for _, l in ipairs(list) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end
--- Everything a save carries of the three layers and the ground: the member bits, the
--- condition bytes and the native heights, keyed as the model keys them.
local function snapshotSave()
    local s = { member = {}, age = {}, wet = {}, pixels = {} }
    for k, v in pairs(W.member.cells) do s.member[k] = v end
    for k, v in pairs(W.age.cells) do s.age[k] = v end
    for k, v in pairs(W.wet.cells) do s.wet[k] = v end
    for ft, t in pairs(HEIGHT.pixels) do
        s.pixels[ft] = {}
        for k, v in pairs(t) do s.pixels[ft][k] = v end
    end
    return s
end
local function loadSave(s)
    for k, v in pairs(s.member) do W.member.cells[k] = v end
    for k, v in pairs(s.age) do W.age.cells[k] = v end
    for k, v in pairs(s.wet) do W.wet.cells[k] = v end
    for ft, t in pairs(s.pixels) do
        HEIGHT.pixels[ft] = {}
        for k, v in pairs(t) do HEIGHT.pixels[ft][k] = v end
    end
end

-- ═══════════════════════════════════════════════════════════
-- V. ROW 107: THE INDEX IS TRUSTED ONLY FROM ONE SAVE, AND A FOREIGN WIDTH IS REBUILT
-- ═══════════════════════════════════════════════════════════
group("V", function()
    -- The index file loaded, the two condition files did not (a save that lost them,
    -- or an index written beside other condition bytes). Its stale bit at (2,2) must
    -- not survive; the truth is the two recorded cells.
    T.ok("V0 [world] armed", world(100, { valueMaps = { membershipLoaded = true, conditionLoaded = false }, beforeArm = function()
        ENGINE.layerSet(W.member, 2, 2, 1)
        ENGINE.layerSet(W.member, 4, 4, 1)
        setCell(4, 4, 3, 100)
        setCell(5, 4, 3, 100)
    end }) == true)
    T.eq("V1 an index whose condition files did not load is not read: the layer is cleared and rebuilt from the truth, the stale bit is gone and the unlisted record is a member",
        runs() .. " | " .. stats() .. " | " .. bit(2, 2) .. bit(4, 4) .. bit(5, 4), "4:4-5 | 2/REBUILT/true | 011")

    -- The same bits with all three files loaded: the index is read as it is (the check
    -- lets a coherent save through).
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function()
        ENGINE.layerSet(W.member, 4, 4, 1)
        setCell(4, 4, 3, 100)
        setCell(5, 4, 3, 100)
    end })
    T.eq("V2 with the index and both condition files from the save, the index is read, and a record it does not list is not added",
        runs() .. " | " .. stats() .. " | " .. tostring(coord():isMember(5, 4)), "4:4-4 | 1/INDEX/true | false")

    -- A membership file of another width (8 cells a side against the grid's 16).
    WARN = {}
    T.ok("V3 [world] armed", world(100, { valueMaps = { membershipLoaded = true, membershipRes = 8 }, beforeArm = function()
        ENGINE.layerSet(W.member, 1, 1, 1)
        setCell(4, 4, 3, 100)
    end }) == true)
    T.eq("V4 a layer of another width is re-initialised at the grid's width and rebuilt from the truth, where it used to be left off",
        tostring(getBitVectorMapSize(W.member.id)) .. " | " .. runs() .. " | " .. stats() .. " | " .. bit(1, 1) .. bit(4, 4)
            .. " | " .. tostring(W.sys.materialWetness:membershipActive()),
        "16 | 4:4-4 | 1/REBUILT/true | 01 | true")
    T.eq("V5 and the log says so once", lines(WARN, "re-initialised at 16"), 1)
end)

-- ═══════════════════════════════════════════════════════════
-- E. ROW 108: AN EMPTY MEMBER WITH NO RECORD LEAVES THE INDEX
-- ═══════════════════════════════════════════════════════════
group("E", function()
    -- A saved index listing an empty record-less cell (2,2), a record-less cell holding
    -- straw (9,9: x 4..8, z 4..8) and a recorded cell (4,4).
    local function saved()
        ENGINE.layerSet(W.member, 2, 2, 1)
        ENGINE.layerSet(W.member, 9, 9, 1)
        ENGINE.layerSet(W.member, 4, 4, 1)
        setCell(4, 4, 3, 100)
        HEIGHT.fill(FT.STRAW, 4, 4, 8, 8, 25)
    end
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = saved })
    T.eq("E1 the empty record-less member leaves (its bit cleared); the straw cell and the recorded cell stay",
        runs() .. " | " .. stats() .. " | " .. bit(2, 2) .. bit(9, 9) .. bit(4, 4) .. " | " .. tostring(coord().membership.emptyLeft),
        "4:4-4 9:9-9 | 2/INDEX/true | 011 | 1")

    -- The same save armed while the height map is invalid: the native read answers 0,
    -- which is not an observation, so nothing leaves.
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function()
        saved()
        g_densityMapHeightManager.valid = false
    end })
    g_densityMapHeightManager.valid = true
    T.eq("E2 with the height map invalid at arm, no member leaves (an unreadable zero is unknown, not empty)",
        runs() .. " | " .. stats() .. " | " .. bit(2, 2), "2:2-2 4:4-4 9:9-9 | 3/INDEX/true | 1")

    -- The native fill read itself refused while the index is read (it raises): the
    -- occupancy is unknown, so nothing leaves.
    local realFill = DensityMapHeightUtil.getFillLevelAtArea
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function()
        saved()
        DensityMapHeightUtil.getFillLevelAtArea = function() error("fill read refused") end
    end })
    DensityMapHeightUtil.getFillLevelAtArea = realFill
    T.eq("E2b with the native fill read refused, the occupancy is unknown and no member leaves",
        runs() .. " | " .. stats(), "2:2-2 4:4-4 9:9-9 | 3/INDEX/true")

    -- The bit clear itself refused (the layer refuses every set): the cell stays a member
    -- in the cache, as its bit still is, and the index asks for a rebuild.
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function()
        saved()
        W.member.throwOnSet = true
    end })
    W.member.throwOnSet = nil
    T.eq("E2c a refused clear keeps the empty cell a member and marks the index rebuild-required (condition held until reconciled)",
        runs() .. " | " .. stats() .. " | " .. bit(2, 2), "2:2-2 4:4-4 9:9-9 | 3/INDEX/false | 1")

    -- The cell's own condition read failing (the wetness byte cannot be read, so the
    -- cells report wetnessAvailable false, GroundConditionCells.lua readConditionCell):
    -- whether it holds a record is unknown, so it stays, whatever the occupancy says.
    local realPoint = getBitVectorMapPoint
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function()
        saved()
        local wetBvm = W.wet.id
        getBitVectorMapPoint = function(bvm, gx, gz, first, num)
            if bvm == wetBvm and gx == 2 and gz == 2 then error("wetness byte unreadable") end
            return realPoint(bvm, gx, gz, first, num)
        end
    end })
    getBitVectorMapPoint = nil
    T.eq("E2d a member whose condition read fails stays, even over a known zero of material (unknown is never empty)",
        runs() .. " | " .. bit(2, 2) .. " | " .. tostring(coord().membership.emptyLeft), "2:2-2 4:4-4 9:9-9 | 1 | nil")

    -- Bob's case end to end: a real mower whose drop throws inside the native call. The
    -- carrier marks every envelope cell unavailable, which marks it a member; straw lies
    -- in one envelope cell (9,9), the rest hold nothing. The save carries those bits.
    world(100)
    HEIGHT.fill(FT.STRAW, 4, 4, 8, 8, 25)
    local v = select(1, ENGINE.newMower({ uid = "boom", x0 = 0, z0 = 0, width = 8, depth = 2, dropZ = 6 }))
    g_currentMission.vehicleSystem.vehicles[#g_currentMission.vehicleSystem.vehicles + 1] = v
    ENGINE.mowable[GRASS] = 400
    W.sys.hookManager:installMowerCarrierHook()
    HEIGHT.throwOnDrop = true
    local okT = pcall(ENGINE.tick, v, 16)
    local before = {}
    coord():enumerateMemberRuns(function(gz, gx0, gx1)
        for gx = gx0, gx1 do before[#before + 1] = gx .. ":" .. gz .. "=" .. tostring(coord():unavailableReason(gx, gz)) end
    end)
    local nBefore = #before
    local strawWasMember = coord():isMember(9, 9)
    T.ok("E3 [world] the drop threw, and the carrier made its envelope members (" .. table.concat(before, " ") .. ")",
        okT == false and nBefore >= 2 and strawWasMember
            and table.concat(before, " "):find("=NATIVE_ERROR", 1, true) ~= nil)
    local save = snapshotSave()
    world(100, { valueMaps = { membershipLoaded = true }, beforeArm = function() loadSave(save) end })
    T.eq("E4 after save and load, the empty envelope cells leave and the cell holding straw stays",
        runs() .. " | " .. stats() .. " | " .. tostring(coord().membership.emptyLeft == nBefore - 1),
        "9:9-9 | 1/INDEX/true | true")
end)

-- ═══════════════════════════════════════════════════════════
-- W. THE SAVE RECONCILES BEFORE IT WRITES THE LAYER FILES (text witness)
-- ═══════════════════════════════════════════════════════════
group("W", function()
    local src = SOURCE_TEXT["src/SoilFertilityManager.lua"]
    local r = src:find("gcc:reconcileMembership", 1, true) or src:find("pcall(gcc.reconcileMembership, gcc)", 1, true)
    local s = src:find("self.soilSystem.valueMaps:saveToSavegame(savegamePath)", 1, true)
    T.ok("W1 the save asks the coordinator to reconcile its index before the value maps write their files",
        r ~= nil and s ~= nil and r < s and (s - r) < 400)
end)
