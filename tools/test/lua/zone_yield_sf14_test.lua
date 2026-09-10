-- zone_yield_sf14_test.lua
-- SF-14 One Ground zone-yield conformance bar v2 (repo port).
--
-- GROUP A re-points to the SHIPPED One Ground surfaces: the previous repo bar
-- drove the retired 8 m / 600-point lattice capture and the farmland-wide crop
-- identity, which are gone. These assertions now pin the conformed module:
-- SF-52 plan consumption, polygon-fruit receipts, the capture job pump, the
-- rotated drag lattice, XML/StateLedger save-load, and the shipped kernel.
--
-- GROUPS B through I model the pure contract fixed by the SF-14 One Ground
-- amendment. They prove reference behavior only. They do NOT prove native
-- fruit-plane writes, polygon clipping, real save bytes, frame time, engine
-- sync, dedicated-server delivery or player understanding: those are the
-- in-game acceptance gates and the release stays LOCKED.
--
-- All fields, keys, states and populations are synthetic branch probes.
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/ViabilityMask.lua, src/integrations/OptionScalingResolver.lua, src/ZoneYield.lua

local ZY = ZoneYield

-- ============================================================
-- GROUP A: SHIPPED ONE GROUND SURFACES (re-point).
-- ============================================================
do
    local current = ZY.new({})
    current:initialize()

    T.eq("A1 shipped yield exposes an XML save method", type(current.saveToXMLFile), "function")
    T.eq("A2 shipped yield exposes an XML load method", type(current.loadFromXMLFile), "function")
    T.eq("A3 shipped yield exposes a StateLedger table serializer", type(current.getStateTable), "function")
    T.eq("A4 shipped yield exposes a StateLedger table applier", type(current.applyStateTable), "function")
    T.eq("A5 shipped source exposes a FINISHED growth handler", type(current.onFinishedGrowthPeriod), "function")
    T.eq("A6 shipped source exposes the pre-cut context", type(current.preparePreCutContext), "function")
    T.eq("A7 shipped source exposes the first-cut freeze", type(current.onFirstCut), "function")
    T.eq("A8 shipped source exposes the sowing door", type(current.onSowingWorkArea), "function")
    T.eq("A9 shipped source exposes the job pump", type(current.advanceJobs), "function")
    T.eq("A10 shipped source exposes the SF-54 witness", type(current.getGrowthSurfaceWitness), "function")

    -- The yield owns no independent growth subscription: register is a no-op that
    -- reports ready, and the retired registration entry point installs nothing.
    T.eq("A11 shipped register is a no-op that reports ready", current:register(), true)
    T.eq("A12 retired registration installs no independent subscription", current:registerGrowthMessage(), true)

    -- Fail-open on the release owner.
    local oldReleaseGate = ReleaseGate
    ReleaseGate = nil
    T.eq("A13 shipped feature fail-opens when the release owner is unavailable", current:isLive(), true)
    ReleaseGate = oldReleaseGate

    -- The retired lattice and farmland-wide identity helpers are gone.
    T.eq("A14 shipped yield derives no old 8m/600 lattice", type(current._deriveCapturePoints), "nil")
    T.eq("A15 shipped yield has no old ephemeral per-field capture builder", type(current._captureField), "nil")
    T.eq("A16 shipped yield has no old farmland-wide live-fruit resolver", type(current._resolveLiveFruit), "nil")

    -- The new durable stores exist.
    T.eq("A17 shipped yield holds a polygon-fruit receipt map", type(current._receipts), "table")
    T.eq("A18 shipped yield holds a contract fallback map", type(current._fallbacks), "table")
    T.eq("A19 shipped yield holds an ordered job queue", type(current._queue), "table")

    -- The band and drag ceiling are one grouped declaration.
    T.near("A20 band floor is the shipped rail", ZY.BAND_FLOOR, 0.7, 1e-9)
    T.near("A21 band ceiling is the shipped rail", ZY.BAND_CEILING, 1.15, 1e-9)
    T.eq("A22 fruit roster is six bits", ZY.FRUIT_MAX, 63)
    T.eq("A23 drag candidate ceiling is 256", ZY.DRAG_MAX_CANDIDATES, 256)

    -- The capture carrier is the shipped yieldEfficiency layer.
    local layers = {}
    for _, def in ipairs(SoilValueMaps.LAYER_DEFS or {}) do layers[def.key] = true end
    T.eq("A24 shipped carrier has the yieldEfficiency layer", layers.yieldEfficiency ~= nil, true)

    -- delete() is safe with nothing captured and clears the batch state.
    current:delete()
    T.eq("A25 shipped delete makes the yield uninitialized", current.isInitialized, false)
    T.eq("A26 shipped delete drops the job queue", #current._queue, 0)
end

-- ============================================================
-- GROUP B: CAPTURED SCALAR AND THE AGRONOMY VARIATION SCALE.
--   captured = clamp(baseline + (localRaw - baseline) * scale, 0.70, 1.15)
-- ============================================================
do
    -- A neutral scale returns localRaw exactly (the calibration invariant).
    T.near("B1 neutral scale returns localRaw", ZY.capturedScalar(0.8, 1.0, 1.0), 1.0, 1e-9)
    T.near("B2 uniform ground reconciles with the baseline", ZY.capturedScalar(0.9, 0.9, 1.0), 0.9, 1e-9)
    T.near("B3 uniform ground reconciles under any scale", ZY.capturedScalar(0.9, 0.9, 0.5), 0.9, 1e-9)
    -- A scale below one damps the deviation around the baseline.
    T.near("B4 half scale halves the deviation", ZY.capturedScalar(0.8, 1.0, 0.5), 0.9, 1e-9)
    -- A scale above one amplifies the deviation around the baseline.
    T.near("B5 one-and-a-half scale amplifies the deviation", ZY.capturedScalar(0.8, 1.0, 1.5), 1.1, 1e-9)
    -- The absolute band rail binds.
    T.near("B6 floor clamps", ZY.capturedScalar(1.0, 0.0, 1.0), ZY.BAND_FLOOR, 1e-9)
    T.near("B7 ceiling clamps", ZY.capturedScalar(1.0, 2.0, 1.0), ZY.BAND_CEILING, 1e-9)
    T.near("B8 missing inputs are neutral", ZY.capturedScalar(nil, nil, nil), 1.0, 1e-9)
    T.near("B9 missing localRaw is the baseline", ZY.capturedScalar(0.85, nil, 1.0), 0.85, 1e-9)

    -- The declaration is the fixed Agronomy deviation contract.
    T.eq("B10 declaration dial is agronomy", ZY.VARIATION_DECLARATION.dial, "agronomy")
    T.eq("B11 declaration base is one", ZY.VARIATION_DECLARATION.base, 1)
    T.eq("B12 declaration neutral is one", ZY.VARIATION_DECLARATION.neutral, 1)
    T.eq("B13 declaration clamps at one half", ZY.VARIATION_DECLARATION.clampMin, 0.5)
    T.eq("B14 declaration clamps at one and a half", ZY.VARIATION_DECLARATION.clampMax, 1.5)

    -- Absent profile resolves neutral one.
    T.near("B15 absent profile is neutral", ZY.effectiveVariationScale(nil), 1.0, 1e-9)

    -- Clamp against a stubbed resolver so the clamp is proved independent of the
    -- resolver's own curve maths.
    local realResolve = OptionScalingResolver.resolve
    OptionScalingResolver.resolve = function() return 5 end
    T.near("B16 resolver over-cap clamps to one and a half", ZY.effectiveVariationScale({}), 1.5, 1e-9)
    OptionScalingResolver.resolve = function() return 0 end
    T.near("B17 resolver under-cap clamps to one half", ZY.effectiveVariationScale({}), 0.5, 1e-9)
    OptionScalingResolver.resolve = function() return 1.25 end
    T.near("B18 resolver mid value passes through", ZY.effectiveVariationScale({}), 1.25, 1e-9)
    OptionScalingResolver.resolve = realResolve
end

-- ============================================================
-- GROUP C: DESCRIPTOR/ROUTE ADMISSION (brief 3.4).
-- ============================================================
do
    local function desc(over)
        local d = {
            name = "wheat", terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
            cutState = 9, numGrowthStates = 8,
            minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
            minForageGrowthState = 0, regrows = false,
        }
        for k, v in pairs(over or {}) do d[k] = v end
        return d
    end

    T.eq("C1 valid standard descriptor joins STANDARD", ZY.classifyCapability(desc()), ZY.ROUTE_STANDARD)
    T.eq("C2 valid regrowing descriptor joins REGROWING",
        ZY.classifyCapability(desc({ regrows = true, firstRegrowthState = 1 })), ZY.ROUTE_REGROWING)
    T.eq("C3 forage-only descriptor joins FORAGE",
        ZY.classifyCapability(desc({ minHarvestingGrowthState = 0, maxHarvestingGrowthState = 0, minForageGrowthState = 4 })),
        ZY.ROUTE_FORAGE)
    T.eq("C4 nil descriptor is SCALAR", ZY.classifyCapability(nil), ZY.ROUTE_SCALAR)
    T.eq("C5 no terrain plane is SCALAR",
        ZY.classifyCapability((function() local d = desc(); d.terrainDataPlaneId = nil; return d end)()),
        ZY.ROUTE_SCALAR)
    T.eq("C6 no state channels is SCALAR",
        ZY.classifyCapability(desc({ numStateChannels = 0 })), ZY.ROUTE_SCALAR)
    T.eq("C7 no cut state is SCALAR", ZY.classifyCapability(desc({ cutState = 0 })), ZY.ROUTE_SCALAR)
    T.eq("C8 no growth-state count is SCALAR",
        ZY.classifyCapability(desc({ numGrowthStates = 0 })), ZY.ROUTE_SCALAR)
    T.eq("C9 unordered harvest range is SCALAR",
        ZY.classifyCapability(desc({ minHarvestingGrowthState = 8, maxHarvestingGrowthState = 6 })), ZY.ROUTE_SCALAR)
    T.eq("C10 zero harvest range is SCALAR",
        ZY.classifyCapability(desc({ minHarvestingGrowthState = 0, maxHarvestingGrowthState = 0 })), ZY.ROUTE_SCALAR)
    T.eq("C11 regrowing without firstRegrowthState is SCALAR",
        ZY.classifyCapability(desc({ regrows = true, firstRegrowthState = nil })), ZY.ROUTE_SCALAR)
    T.eq("C12 regrowing forage descriptor still joins REGROWING",
        ZY.classifyCapability(desc({ minHarvestingGrowthState = 0, maxHarvestingGrowthState = 0,
            minForageGrowthState = 4, regrows = true, firstRegrowthState = 1 })), ZY.ROUTE_REGROWING)

    T.eq("C13 FORAGE is a forage route", ZY.isForageRoute(desc(), ZY.ROUTE_FORAGE), true)
    T.eq("C14 STANDARD is not a forage route", ZY.isForageRoute(desc(), ZY.ROUTE_STANDARD), false)
    T.eq("C15 regrowing forage-only is a forage route",
        ZY.isForageRoute(desc({ minHarvestingGrowthState = 0, maxHarvestingGrowthState = 0, minForageGrowthState = 4 }),
            ZY.ROUTE_REGROWING), true)
    T.eq("C16 regrowing standard is not a forage route",
        ZY.isForageRoute(desc(), ZY.ROUTE_REGROWING), false)

    T.eq("C17 regrows with a first state is regrowing",
        ZY.isRegrowing(desc({ regrows = true, firstRegrowthState = 1 })), true)
    T.eq("C18 regrows without a first state is not regrowing",
        ZY.isRegrowing(desc({ regrows = true, firstRegrowthState = nil })), false)
    T.eq("C19 non-regrowing descriptor is not regrowing", ZY.isRegrowing(desc()), false)
end

-- ============================================================
-- GROUP D: REGROWTH THAW AND THE ROTATED DRAG SUBDIVISION.
-- ============================================================
do
    T.eq("D1 zero old area and positive regrowth thaws", ZY.regrowthThawed(0, 5), true)
    T.eq("D2 zero old area and zero regrowth stays frozen", ZY.regrowthThawed(0, 0), false)
    T.eq("D3 partial harvest stays frozen", ZY.regrowthThawed(2, 5), false)
    T.eq("D4 negative old area counts as zero", ZY.regrowthThawed(-1, 5), true)
    T.eq("D5 missing operands never thaw", ZY.regrowthThawed(nil, 5), false)
    T.eq("D6 missing regrowth operand never thaws", ZY.regrowthThawed(0, nil), false)

    local nx, ny = ZY.dragSubdivisions(40, 8, 256)
    T.ok("D7 subdivisions are positive", nx >= 1 and ny >= 1)
    T.ok("D8 subdivisions respect the candidate ceiling", nx * ny <= 256)
    T.ok("D9 the long axis gets at least as many cells", nx >= ny)

    local sx, sy = ZY.dragSubdivisions(8, 40, 256)
    T.ok("D10 a swapped shape swaps the subdivision", sy >= sx)
    T.ok("D11 swapped subdivisions respect the ceiling", sx * sy <= 256)

    local tx, ty = ZY.dragSubdivisions(1, 1, 256)
    T.ok("D12 a square fills the ceiling", tx * ty <= 256 and tx * ty >= 64)

    local zx, zy = ZY.dragSubdivisions(0, 8, 256)
    T.eq("D13 a degenerate edge falls to one cell", zx, 1)
    T.eq("D14 a degenerate edge keeps the other axis one", zy, 1)
end

-- ============================================================
-- GROUP E: SF-55 COMPOSITION AND THE AREA-WEIGHTED INTEGRAL.
-- ============================================================
do
    T.near("E1 nil drag is identity", ZY.composeDrag(0.9, nil), 0.9, 1e-9)
    T.near("E2 drag scales the captured value", ZY.composeDrag(1.0, 0.2), 0.8, 1e-9)
    T.near("E3 drag is bounded to one", ZY.composeDrag(1.0, 5.0), 0.0, 1e-9)
    T.near("E4 captured is bounded at the ceiling", ZY.composeDrag(9.0, nil), ZY.BAND_CEILING, 1e-9)
    T.near("E5 nil captured is neutral", ZY.composeDrag(nil, 0.5), 1.0, 1e-9)

    T.near("E6 uniform aggregation", ZY.aggregateAreaWeighted({ { value = 0.85, area = 1 }, { value = 0.85, area = 1 } }), 0.85, 1e-9)
    T.near("E7 area-weighted mean", ZY.aggregateAreaWeighted({
        { value = 1.0, area = 2 }, { value = 0.5, area = 2 }, { value = 0.9, area = 2 },
    }), 0.8, 1e-9)
    T.near("E8 unwritten candidates contribute no area",
        ZY.aggregateAreaWeighted({ { value = nil, area = 1 }, { value = 1.0, area = 1 } }), 1.0, 1e-9)
    T.eq("E9 empty input is nil", ZY.aggregateAreaWeighted({}), nil)
    T.eq("E10 nil input is nil", ZY.aggregateAreaWeighted(nil), nil)
    -- Accepted values aggregate by NATIVE fruit area, not by candidate count.
    T.near("E11 native area weights accepted values",
        ZY.aggregateAreaWeighted({ { value = 1.0, area = 1 }, { value = 0.5, area = 3 } }), 0.625, 1e-9)
end

-- ============================================================
-- GROUP F: RECEIPT IDENTITY, STATUS GRAMMAR AND THE FIRST-CUT FREEZE.
-- ============================================================
do
    T.eq("F1 receipt key is farmland|polygon|fruit", ZY.receiptKey(3, "fpA", 1), "3|fpA|1")
    T.eq("F2 receipt key separates fruit", ZY.receiptKey(3, "fpA", 2), "3|fpA|2")
    T.eq("F3 statuses are distinct", ZY.STATUS_PENDING ~= ZY.STATUS_READY, true)
    T.eq("F4 spatial and fallback freezes are distinct", ZY.STATUS_FROZEN_SPATIAL ~= ZY.STATUS_FROZEN_FALLBACK, true)

    local oldMission = g_currentMission
    local oldFTM = g_fruitTypeManager
    g_currentMission = { getIsServer = function() return true end, missionInfo = {} }
    g_fruitTypeManager = { getFruitTypeByIndex = function() return { name = "wheat" } end }

    local vm = { available = true, resolution = 2048 }
    local ss = { fieldData = { [7] = { nitrogen = 80, phosphorus = 80, potassium = 80, organicMatter = 3.5 } },
                 valueMaps = vm,
                 _getFarmlandPolygons = function() return {} end,
                 _yieldModifierFromNutrients = function() return 0.9 end }
    local zy = ZY.new({ soilSystem = ss, viability = { enabled = true, getCellGrowthInfo = function() return {} end } })
    zy:initialize()
    zy._receipts[ZY.receiptKey(7, "fpA", 1)] = {
        farmlandId = 7, sourcePolygonFingerprint = "fpA", fruitTypeIndex = 1, status = ZY.STATUS_READY,
    }

    -- A positive spatial first cut freezes the exact spatial receipt.
    local okSpatial = zy:onFirstCut({ path = "spatial", fieldId = 7, fruitTypeIndex = 1,
        sourcePolygonFingerprint = "fpA", forageRoute = false })
    T.eq("F5 spatial first cut freezes", okSpatial, true)
    T.eq("F6 the spatial receipt is FROZEN_SPATIAL",
        zy._receipts[ZY.receiptKey(7, "fpA", 1)].status, ZY.STATUS_FROZEN_SPATIAL)
    T.eq("F7 the freeze stores the fallback scalar",
        type(zy._receipts[ZY.receiptKey(7, "fpA", 1)].fallbackScalar), "number")
    T.eq("F8 the contract fallback map holds the scalar", type(zy._fallbacks["7|1"].scalar), "number")

    -- A fallback path freezes only the contract fallback, never a spatial receipt.
    zy._receipts[ZY.receiptKey(7, "fpB", 2)] = {
        farmlandId = 7, sourcePolygonFingerprint = "fpB", fruitTypeIndex = 2, status = ZY.STATUS_READY,
    }
    local okFallback = zy:onFirstCut({ path = "fallback", fieldId = 7, fruitTypeIndex = 2,
        sourcePolygonFingerprint = "fpB", forageRoute = true })
    T.eq("F9 a fallback first cut freezes no spatial receipt", okFallback, false)
    T.eq("F10 the fallback receipt is untouched",
        zy._receipts[ZY.receiptKey(7, "fpB", 2)].status, ZY.STATUS_READY)
    T.eq("F11 the fallback map records the forage route", zy._fallbacks["7|2"].forageRoute, true)

    -- A nil context is safe.
    T.eq("F12 nil first cut is safe", zy:onFirstCut(nil), false)

    g_currentMission = oldMission
    g_fruitTypeManager = oldFTM
end

-- ============================================================
-- GROUP G: THE CAPTURE JOB PUMP (queue, bounded advance, drift, failure).
-- ============================================================
do
    local function newWheat(over)
        local d = {
            name = "wheat", terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
            cutState = 9, numGrowthStates = 8,
            minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
            minForageGrowthState = 0, regrows = false,
            getIsCut = function() return false end,
            getIsWithered = function() return false end,
        }
        for k, v in pairs(over or {}) do d[k] = v end
        return d
    end

    local function newPlan(over)
        local p = {
            planId = "p1", planContentHash = "h1", polygonUnionFingerprint = "g1",
            carrierOwnershipHash = "o1", farmlandInputRevision = 1, unscopedInputRevision = 1,
            settingsFingerprint = "", executionGrainMetres = 4,
            regions = {
                { key = "1:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
                  carrierOwnerFarmlandId = 7, writableForFarmland = true },
                { key = "2:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
                  carrierOwnerFarmlandId = 7, writableForFarmland = true },
            },
        }
        for k, v in pairs(over or {}) do p[k] = v end
        return p
    end

    local function newVM()
        local store = {}
        local vm = { available = true, resolution = 2048, _store = store, _failN = false }
        function vm:getGrowthInputToken(_fid)
            return { farmlandRevision = 1, unscopedRevision = 1, globalRevision = 1 }
        end
        function vm:readValueAtWorld(key, x, z)
            if key == "nitrogen" then
                if self._failN then return nil end
                return 80
            end
            if key == "phosphorus" or key == "potassium" then return 80 end
            return store[key .. ":" .. x .. ":" .. z]
        end
        function vm:writeValueAtWorld(key, x, z, value, _r)
            store[key .. ":" .. x .. ":" .. z] = value
        end
        function vm:readAverageOfPolygon(key, _verts, _filter)
            if key == "yieldEfficiency" then return 95, 1 end
            return nil, 0
        end
        return vm
    end

    local oldMission = g_currentMission
    local oldFTM = g_fruitTypeManager
    local oldFDU = FSDensityMapUtil
    g_currentMission = { getIsServer = function() return true end,
                         missionInfo = { growthMode = GrowthMode.SEASONAL } }
    g_fruitTypeManager = { getFruitTypeByIndex = function() return newWheat() end }
    FSDensityMapUtil = {
        getFruitTypeIndexAtWorldPos = function() return 1, 6 end,
        getFruitArea = function() return 100 end,
    }

    local plan = newPlan()
    local vm = newVM()
    local ss = { fieldData = { [7] = { nitrogen = 80, phosphorus = 80, potassium = 80, organicMatter = 3.5 } },
                 valueMaps = vm,
                 _getFarmlandPolygons = function() return {} end,
                 _yieldModifierFromNutrients = function() return 1.0 end }
    local zy = ZY.new({ soilSystem = ss,
                        viability = { enabled = true, getCellGrowthInfo = function() return {} end },
                        getGrowthEligibleRegionPlan = function() return plan end })
    zy:initialize()

    -- A drained FINISHED queues one ordered farmland job.
    zy:onFinishedGrowthPeriod(4, false)
    T.eq("G1 drained FINISHED queues one job", #zy._queue, 1)
    T.eq("G2 the job targets the tracked farmland", zy._queue[1] and zy._queue[1].farmlandId, 7)
    T.eq("G3 the job enumerates both owned regions", zy._queue[1] and #zy._queue[1].regions, 2)
    T.eq("G4 the observed pair starts PENDING (no receipt yet)",
        zy._receipts[ZY.receiptKey(7, "fpA", 1)], nil)

    -- A zero budget leaves the job PENDING.
    T.eq("G5 a zero budget advances nothing", zy:advanceJobs(0), 0)
    T.eq("G6 a zero budget keeps the job queued", #zy._queue, 1)
    T.eq("G7 a zero budget mints no receipt", zy._receipts[ZY.receiptKey(7, "fpA", 1)], nil)

    -- A positive budget completes the job and publishes one generation.
    local used = zy:advanceJobs(100)
    T.ok("G8 the positive budget spent operations", used >= 2)
    T.eq("G9 a completed job leaves the queue", #zy._queue, 0)
    T.ok("G10 the observed pair becomes READY",
        zy._receipts[ZY.receiptKey(7, "fpA", 1)] ~= nil
        and zy._receipts[ZY.receiptKey(7, "fpA", 1)].status == ZY.STATUS_READY)
    T.eq("G11 the committed generation advanced", zy._captureGeneration, 1)
    local wrote100 = false
    for _, v in pairs(vm._store) do if v == 100 then wrote100 = true end end
    T.ok("G12 the captured layer holds the percent", wrote100)

    -- Drift before commit cancels the unfinished job and leaves no READY receipt.
    plan.planContentHash = "h1"
    local zy2 = ZY.new({ soilSystem = ss,
                         viability = { enabled = true, getCellGrowthInfo = function() return {} end },
                         getGrowthEligibleRegionPlan = function() return plan end })
    zy2:initialize()
    zy2:onFinishedGrowthPeriod(4, false)
    plan.planContentHash = "drifted"
    zy2:advanceJobs(100)
    T.eq("G13 drift cancels the job", #zy2._queue, 0)
    T.eq("G14 drift leaves no READY receipt", zy2._receipts[ZY.receiptKey(7, "fpA", 1)], nil)
    T.eq("G15 drift publishes no generation", zy2._captureGeneration, 0)

    -- One missing N/P/K input fails the whole farmland job.
    plan.planContentHash = "h1"
    vm._failN = false
    local zy3 = ZY.new({ soilSystem = ss,
                         viability = { enabled = true, getCellGrowthInfo = function() return {} end },
                         getGrowthEligibleRegionPlan = function() return plan end })
    zy3:initialize()
    zy3:onFinishedGrowthPeriod(4, false)
    vm._failN = true
    zy3:advanceJobs(100)
    T.eq("G16 a failed read empties the queue", #zy3._queue, 0)
    T.eq("G17 a failed job mints no receipt", zy3._receipts[ZY.receiptKey(7, "fpA", 1)], nil)
    T.eq("G18 a failed job publishes no generation", zy3._captureGeneration, 0)
    vm._failN = false

    g_currentMission = oldMission
    g_fruitTypeManager = oldFTM
    FSDensityMapUtil = oldFDU
end

-- ============================================================
-- GROUP H: THE HARVEST READ (spatial, fallback, contract, drag).
-- ============================================================
do
    local function newWheat(over)
        local d = {
            name = "wheat", terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
            cutState = 9, numGrowthStates = 8,
            minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
            minForageGrowthState = 0, regrows = false,
            getIsCut = function() return false end,
            getIsWithered = function() return false end,
        }
        for k, v in pairs(over or {}) do d[k] = v end
        return d
    end

    local plan = {
        planId = "p1", planContentHash = "h1", polygonUnionFingerprint = "g1",
        carrierOwnershipHash = "o1", farmlandInputRevision = 1, unscopedInputRevision = 1,
        settingsFingerprint = "", executionGrainMetres = 4,
        regions = {
            { key = "1:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
              carrierOwnerFarmlandId = 7, writableForFarmland = true },
            { key = "2:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
              carrierOwnerFarmlandId = 7, writableForFarmland = true },
        },
    }
    local vm = {
        available = true, resolution = 2048,
        getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1 } end,
        readAverageOfPolygon = function(_self, key, _verts, _filter)
            if key == "yieldEfficiency" then return 95, 1 end
            return nil, 0
        end,
        readValueAtWorld = function(_self, key, _x, _z)
            if key == "yieldEfficiency" then return 95 end
            return nil
        end,
    }
    local ss = { fieldData = { [7] = { nitrogen = 80, phosphorus = 80, potassium = 80, organicMatter = 3.5 } },
                 valueMaps = vm,
                 _getFarmlandPolygons = function() return {} end,
                 _yieldModifierFromNutrients = function() return 1.0 end }
    local zy = ZY.new({ soilSystem = ss,
                        viability = { enabled = true, getCellGrowthInfo = function() return {} end },
                        getGrowthEligibleRegionPlan = function() return plan end })
    zy:initialize()

    local oldMission = g_currentMission
    local oldFM = g_fieldManager
    local oldFTM = g_fruitTypeManager
    local oldFDU = FSDensityMapUtil
    local oldGWT = getWorldTranslation
    local oldFSAPI = FieldSentry_API
    local oldFSCore = FieldSentry_Core

    g_currentMission = { getIsServer = function() return true end, missionInfo = {} }
    g_fieldManager = { getFieldAtWorldPosition = function() return { farmland = { id = 7 } } end }
    g_fruitTypeManager = { getFruitTypeByIndex = function() return newWheat() end }
    FSDensityMapUtil = { getFruitArea = function() return 100 end }
    FieldSentry_API = { refreshContract = function() end,
                        isFieldSimDisabled = function() return false, nil, false, nil end }
    FieldSentry_Core = { BLACKLIST = { NPC = "npc" } }

    local nodes = { start = { 0, 0 }, width = { 40, 0 }, height = { 0, 8 } }
    getWorldTranslation = function(node)
        local p = nodes[node]
        if p then return p[1], 0, p[2] end
        return 0, 0, 0
    end
    local cutter = { spec_cutter = { allowsForageGrowthState = false,
        workAreaParameters = { fruitTypeIndicesToUse = { 1 } } } }
    local workArea = { start = "start", width = "width", height = "height" }

    -- No receipt -> fallback, never zero yield.
    local ctxFb = zy:preparePreCutContext(cutter, workArea)
    T.ok("H1 no receipt takes the fallback path", ctxFb ~= nil and ctxFb.path == "fallback")
    T.eq("H2 the fallback names the farmland", ctxFb and ctxFb.fieldId, 7)
    T.eq("H3 the fallback names the fruit", ctxFb and ctxFb.fruitTypeIndex, 1)
    T.eq("H4 the fallback scalar is nil (caller uses the frozen scalar)", ctxFb and ctxFb.scalar, nil)

    -- A READY receipt -> spatial polygon read.
    zy._receipts[ZY.receiptKey(7, "fpA", 1)] = {
        farmlandId = 7, sourcePolygonFingerprint = "fpA", fruitTypeIndex = 1, status = ZY.STATUS_READY,
    }
    local ctxSp = zy:preparePreCutContext(cutter, workArea)
    T.ok("H5 a READY receipt takes the spatial path", ctxSp ~= nil and ctxSp.path == "spatial")
    T.near("H6 the spatial scalar is the polygon mean over 100", ctxSp and ctxSp.scalar, 0.95, 1e-6)
    T.eq("H7 the spatial context carries the source polygon", ctxSp and ctxSp.sourcePolygonFingerprint, "fpA")

    -- Contract-exempt field -> contract path.
    FieldSentry_API.isFieldSimDisabled = function() return true, "npc", false, { contractExempt = true } end
    local ctxC = zy:preparePreCutContext(cutter, workArea)
    T.ok("H8 a contract-exempt field takes the contract path", ctxC ~= nil and ctxC.path == "contract")
    FieldSentry_API.isFieldSimDisabled = function() return false, nil, false, nil end

    -- Not live -> nil.
    zy.manager.viability.enabled = false
    T.eq("H9 not live is nil", zy:preparePreCutContext(cutter, workArea), nil)
    zy.manager.viability.enabled = true

    -- No value maps -> nil.
    zy.manager.soilSystem.valueMaps = nil
    T.eq("H10 no maps is nil", zy:preparePreCutContext(cutter, workArea), nil)
    zy.manager.soilSystem.valueMaps = vm

    -- Positive drag routes through the rotated drag lattice.
    vm.readAverageOfPolygon = function(_self, key, _verts, _filter)
        if key == "trafficDrag" then return 0.2, 1 end
        if key == "yieldEfficiency" then return 95, 1 end
        return nil, 0
    end
    vm.readValueAtWorld = function(_self, key, _x, _z)
        if key == "yieldEfficiency" then return 95 end
        if key == "trafficDrag" then return 0.2 end
        return nil
    end
    local ctxDrag = zy:preparePreCutContext(cutter, workArea)
    T.ok("H11 positive drag still returns the spatial path", ctxDrag ~= nil and ctxDrag.path == "spatial")
    T.near("H12 the drag path composes captured times one-minus-drag", ctxDrag and ctxDrag.scalar, 0.95 * 0.8, 1e-6)

    -- A boundary region owned by another farmland fails the owner proof.
    plan.regions[1].carrierOwnerFarmlandId = 8
    local ctxBoundary = zy:preparePreCutContext(cutter, workArea)
    T.ok("H13 a non-owner boundary key falls back", ctxBoundary ~= nil and ctxBoundary.path == "fallback")
    plan.regions[1].carrierOwnerFarmlandId = 7

    getWorldTranslation = oldGWT
    FieldSentry_API = oldFSAPI
    FieldSentry_Core = oldFSCore
    FSDensityMapUtil = oldFDU
    g_fruitTypeManager = oldFTM
    g_fieldManager = oldFM
    g_currentMission = oldMission
end

-- ============================================================
-- GROUP I: SAVE/LOAD, WITNESS, SOWING DOOR AND TEARDOWN.
-- ============================================================
do
    local oldMission = g_currentMission
    local oldFTM = g_fruitTypeManager
    local oldFDU = FSDensityMapUtil
    g_currentMission = { getIsServer = function() return true end, missionInfo = {} }
    g_fruitTypeManager = { getFruitTypeByIndex = function()
        return { name = "wheat", terrainDataPlaneId = 5, startStateChannel = 0, numStateChannels = 4,
                 cutState = 9, numGrowthStates = 8,
                 minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
                 getIsCut = function() return false end, getIsWithered = function() return false end }
    end }
    FSDensityMapUtil = { getFruitTypeIndexAtWorldPos = function() return 1, 6 end,
                         getFruitArea = function() return 100 end }

    -- Save/load round-trip of bounded metadata.
    local src = ZY.new({})
    src:initialize()
    src._captureGeneration = 9
    src._receipts[ZY.receiptKey(7, "fpA", 1)] = {
        farmlandId = 7, sourcePolygonFingerprint = "fpA", fruitTypeIndex = 1,
        status = ZY.STATUS_FROZEN_SPATIAL, captureGeneration = 9,
        planContentHash = "h7", carrierOwnershipHash = "o7", polygonUnionFingerprint = "g7",
        settingsFingerprint = "", fallbackScalar = 0.88, forageRoute = true,
    }
    src._fallbacks["7|1"] = { scalar = 0.88, forageRoute = true, generation = 9 }
    local handle = {}
    src:saveToXMLFile(handle, "soilData.zoneYield")

    local dst = ZY.new({})
    dst:initialize()
    dst:loadFromXMLFile(handle, "soilData.zoneYield")
    T.eq("I1 generation survives the round-trip", dst._captureGeneration, 9)
    local r = dst._receipts[ZY.receiptKey(7, "fpA", 1)]
    T.ok("I2 receipt survives the round-trip", r ~= nil)
    T.eq("I3 receipt status survives", r and r.status, ZY.STATUS_FROZEN_SPATIAL)
    T.eq("I4 receipt polygon survives", r and r.sourcePolygonFingerprint, "fpA")
    T.eq("I5 receipt plan hash survives", r and r.planContentHash, "h7")
    T.near("I6 receipt fallback scalar survives", r and r.fallbackScalar, 0.88, 1e-6)
    T.eq("I7 receipt forage route survives", r and r.forageRoute, true)
    T.eq("I8 restored receipt stays pending validation", dst._pendingValidation[7], true)
    T.near("I9 fallback scalar survives the round-trip", dst._fallbacks["7|1"].scalar, 0.88, 1e-6)
    T.eq("I10 fallback forage route survives", dst._fallbacks["7|1"].forageRoute, true)

    -- A schema mismatch clears the durable spatial state.
    local bad = {}
    bad["soilData.zoneYield#schema"] = 99
    local dst2 = ZY.new({})
    dst2:initialize()
    dst2:loadFromXMLFile(bad, "soilData.zoneYield")
    T.eq("I11 a schema mismatch clears the receipts", next(dst2._receipts), nil)

    -- StateLedger table round-trip mirrors XML.
    local ledgerState = src:getStateTable()
    local applied = ZY.new({})
    applied:initialize()
    applied:applyStateTable(ledgerState)
    T.eq("I12 StateLedger generation round-trips", applied._captureGeneration, 9)
    T.ok("I13 StateLedger receipt round-trips", applied._receipts[ZY.receiptKey(7, "fpA", 1)] ~= nil)
    T.ok("I14 StateLedger fallback round-trips", applied._fallbacks["7|1"] ~= nil)

    -- Witness: nil off-plan, a matching record on-plan.
    local plan = {
        planId = "p1", planContentHash = "h1", polygonUnionFingerprint = "g1",
        carrierOwnershipHash = "o1", farmlandInputRevision = 1, unscopedInputRevision = 1,
        settingsFingerprint = "", executionGrainMetres = 4,
        regions = {
            { key = "1:1", sourcePolygonFingerprint = "fpA", blocked = false, area = 16,
              carrierOwnerFarmlandId = 7, writableForFarmland = true },
        },
    }
    local vm = { available = true, resolution = 2048,
        getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1 } end,
        readValueAtWorld = function(_self, key, _x, _z)
            if key == "yieldEfficiency" then return 92 end
            return nil
        end }
    local zy = ZY.new({ soilSystem = { fieldData = { [7] = {} }, valueMaps = vm,
                                        _getFarmlandPolygons = function() return {} end },
                        viability = { enabled = true, getCellGrowthInfo = function() return {} end },
                        getGrowthEligibleRegionPlan = function() return plan end })
    zy:initialize()
    zy._receipts[ZY.receiptKey(7, "fpA", 1)] = {
        farmlandId = 7, sourcePolygonFingerprint = "fpA", fruitTypeIndex = 1, status = ZY.STATUS_READY,
    }
    T.eq("I15 witness off-plan is nil", zy:getGrowthSurfaceWitness(7, 100, 100), nil)
    local w = zy:getGrowthSurfaceWitness(7, 6, 6)
    T.ok("I16 witness on-plan is present", w ~= nil)
    T.eq("I17 witness reports the matching status", w and w.status, ZY.STATUS_READY)
    T.eq("I18 witness reports the matching fruit", w and w.fruitTypeIndex, 1)
    T.eq("I19 witness reports the captured percent", w and w.capturedPercent, 92)

    -- Sowing door clears only the matching source-polygon receipts.
    local oldGWT = getWorldTranslation
    getWorldTranslation = function(node)
        local p = ({ start = { 0, 0 }, width = { 40, 0 }, height = { 0, 8 } })[node]
        if p then return p[1], 0, p[2] end
        return 0, 0, 0
    end
    local cleared = zy:onSowingWorkArea({ start = "start", width = "width", height = "height" })
    T.eq("I20 the sowing door clears the matching receipt", cleared, 1)
    T.eq("I21 the matching receipt is gone", zy._receipts[ZY.receiptKey(7, "fpA", 1)], nil)
    getWorldTranslation = oldGWT

    -- delete() clears the durable state.
    zy:delete()
    T.eq("I22 delete drops the receipts", next(zy._receipts), nil)
    T.eq("I23 delete drops the fallbacks", next(zy._fallbacks), nil)
    T.eq("I24 delete drops the queue", #zy._queue, 0)

    g_currentMission = oldMission
    g_fruitTypeManager = oldFTM
    FSDensityMapUtil = oldFDU
end

T.summary()
