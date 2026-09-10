-- SF-78 One Ground growth-hold conformance bar v2 (repo port).
--
-- GROUP A re-points to the SHIPPED One Ground surfaces: the previous repo bar
-- drove the retired 8m/600-point lattice capture, which is gone. These assertions
-- now pin the conformed module: paired carrier layers, no independent growth
-- subscription (register is a no-op), XML/StateLedger save-load, and the shipped
-- kernel/witness surface.
--
-- GROUPS B through I model the pure contract fixed by SF-78-SDS v2.5. They prove
-- reference behavior only. They do NOT prove native fruit-plane writes, polygon
-- clipping, real save bytes or duration, frame time, engine sync,
-- dedicated-server delivery or player understanding: those are the in-game
-- acceptance gates and the release stays LOCKED.
--
-- All fields, keys, states and populations are synthetic branch probes.
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/ViabilityMask.lua, src/integrations/OptionScalingResolver.lua, src/GrowthBlock.lua

local GB = GrowthBlock

-- ============================================================
-- GROUP A: SHIPPED ONE GROUND SURFACES (re-point).
-- ============================================================
do
    local current = GB.new({})
    current:initialize()

    T.eq("A1 shipped hold exposes an XML save method", type(current.saveToXMLFile), "function")
    T.eq("A2 shipped hold exposes an XML load method", type(current.loadFromXMLFile), "function")
    T.eq("A3 shipped hold exposes a StateLedger table serializer", type(current.getStateTable), "function")
    T.eq("A4 shipped source exposes a START growth handler", type(current.onStartGrowthPeriod), "function")
    T.eq("A5 shipped source exposes a FINISHED growth handler", type(current.onFinishedGrowthPeriod), "function")

    -- The hold owns no independent growth subscription: register is a no-op that
    -- reports ready so the manager's uniform member sweep is satisfied.
    T.eq("A6 shipped register is a no-op that reports ready", current:register(), true)

    -- Fail-open on the release owner, gates hard on the mask (checked in B/A).
    local oldReleaseGate = ReleaseGate
    ReleaseGate = nil
    T.eq("A7 shipped feature fail-opens when the release owner is unavailable",
        current:isLive(), true)
    ReleaseGate = oldReleaseGate

    -- The retired lattice helpers are gone.
    T.eq("A8 shipped hold derives no old 8m/600 lattice header", type(current._deriveHeader), "nil")
    T.eq("A9 shipped hold has no old ephemeral per-field capture builder",
        type(current._captureField), "nil")

    -- The witness socket stays nil off any current plan (no manager delegate here).
    T.eq("A10 shipped witness socket stays nil off-plan", current:getGrowthSurfaceWitness(7, 1, 1), nil)

    local layers = {}
    for _, def in ipairs(SoilValueMaps.LAYER_DEFS or {}) do layers[def.key] = true end
    T.eq("A11 shipped carrier has a growth-block state layer", layers.growthBlockState ~= nil, true)
    T.eq("A12 shipped carrier has a growth-block fruit layer", layers.growthBlockFruit ~= nil, true)

    local st = current:getStateTable()
    T.eq("A13 shipped state table carries a capture generation", type(st.captureGeneration), "number")
    T.eq("A14 shipped state table carries the per-farmland metadata", type(st.farmlands), "table")

    -- delete() is safe with nothing captured and clears the batch state.
    current:delete()
    T.eq("A15 shipped delete makes the hold uninitialized", current.isInitialized, false)
    T.eq("A16 shipped delete drops the active envelope", current._envelope, nil)
end

-- ============================================================
-- GROUP B: FRUIT BYTE PACK/UNPACK AND FLAG CLASSIFICATION.
--   low six bits fruit 1..63, bit 6 (64) ACTIVE, bit 7 (128) HELD, both invalid.
-- ============================================================
do
    T.eq("B1 pack ACTIVE sets bit 6", GB.packFruit(5, true, false), 69)
    T.eq("B2 pack HELD sets bit 7", GB.packFruit(5, false, true), 133)
    T.eq("B3 pack neither is bare fruit", GB.packFruit(5, false, false), 5)
    T.eq("B4 pack both flags is invalid", GB.packFruit(5, true, true), nil)
    T.eq("B5 pack rejects fruit 0", GB.packFruit(0, true, false), nil)
    T.eq("B6 pack rejects fruit above 63", GB.packFruit(64, true, false), nil)

    local f, a, h = GB.unpackFruit(69)
    T.eq("B7 unpack ACTIVE fruit", f, 5); T.eq("B7a unpack ACTIVE flag", a, true); T.eq("B7b unpack not held", h, false)
    f, a, h = GB.unpackFruit(133)
    T.eq("B8 unpack HELD fruit", f, 5); T.eq("B8a unpack not active", a, false); T.eq("B8b unpack HELD flag", h, true)
    f, a, h = GB.unpackFruit(5)
    T.eq("B9 unpack bare fruit", f, 5); T.eq("B9a unpack bare not active", a, false); T.eq("B9b unpack bare not held", h, false)
    T.eq("B10 unpack rejects both-flags byte", (GB.unpackFruit(197)), nil)  -- 5+64+128
    T.eq("B11 unpack rejects zero", (GB.unpackFruit(0)), nil)
    T.eq("B12 unpack rejects out-of-range", (GB.unpackFruit(255)), nil)

    T.eq("B13 classify ACTIVE byte", GB.classifyFruitByte(69), GB.CELL_ACTIVE)
    T.eq("B14 classify HELD byte", GB.classifyFruitByte(133), GB.CELL_HELD)
    T.eq("B15 classify bare byte is MISSED", GB.classifyFruitByte(5), GB.CELL_MISSED)
    T.eq("B16 classify both-flags byte is INVALID", GB.classifyFruitByte(197), GB.CELL_INVALID)
    T.eq("B17 classify zero byte is INVALID", GB.classifyFruitByte(0), GB.CELL_INVALID)

    -- Round-trip every fruit under each single flag.
    local roundTripOk = true
    for fruit = 1, GB.FRUIT_MAX do
        for _, flag in ipairs({ "active", "held", "none" }) do
            local packed = GB.packFruit(fruit, flag == "active", flag == "held")
            local uf, ua, uh = GB.unpackFruit(packed)
            if uf ~= fruit or ua ~= (flag == "active") or uh ~= (flag == "held") then
                roundTripOk = false
            end
        end
    end
    T.ok("B18 every fruit round-trips under each single flag", roundTripOk)
end

-- ============================================================
-- GROUP C: CAPTURED-STATE VALIDITY AND PAIR CLASSIFICATION.
-- ============================================================
do
    T.eq("C1 state 0 is valid", GB.isValidCapturedState(0), true)
    T.eq("C2 state 254 is valid", GB.isValidCapturedState(254), true)
    T.eq("C3 state 255 is invalid", GB.isValidCapturedState(255), false)
    T.eq("C4 negative state is invalid", GB.isValidCapturedState(-1), false)
    T.eq("C5 fractional state is invalid", GB.isValidCapturedState(3.5), false)
    T.eq("C6 non-number state is invalid", GB.isValidCapturedState("x"), false)

    local absent = { exists = false, loaded = false, resolution = 0 }
    local present = { exists = true, loaded = true, resolution = 2048 }
    T.eq("C7 neither layer + no claim is FRESH", GB.classifyPair(absent, absent, false, 2048), GB.PAIR_FRESH)
    T.eq("C8 both layers loaded at expected res is COMPLETE", GB.classifyPair(present, present, false, 2048), GB.PAIR_COMPLETE)
    T.eq("C9 one layer only is PAIR_INVALID", GB.classifyPair(present, absent, false, 2048), GB.PAIR_INVALID)
    T.eq("C10 resolution mismatch is PAIR_INVALID",
        GB.classifyPair({ exists = true, loaded = true, resolution = 1024 }, present, false, 2048), GB.PAIR_INVALID)
    T.eq("C11 no pair but metadata claims capture is PAIR_INVALID", GB.classifyPair(absent, absent, true, 2048), GB.PAIR_INVALID)
end

-- ============================================================
-- GROUP D: RESTORE TARGET AND THE R2 THREE-HALVES DISCRIMINATOR.
-- ============================================================
do
    T.eq("D1 one step held from current", GB.restoreTarget(2, 5, 1, 1), 4)
    T.eq("D2 deep queue clamps to captured", GB.restoreTarget(2, 5, 1, 3), 2)   -- 5-3=2
    T.eq("D3 cap*count below captured clamps to captured", GB.restoreTarget(2, 5, 2, 2), 2) -- 5-4=1 -> 2
    T.eq("D4 two steps for cap 2 count 1", GB.restoreTarget(2, 5, 2, 1), 3)     -- 5-2=3
    T.eq("D5 current not above captured yields nil", GB.restoreTarget(2, 2, 1, 1), nil)
    T.eq("D6 current below captured yields nil", GB.restoreTarget(5, 3, 1, 1), nil)
    T.eq("D7 zero steps would equal current, rejected", GB.restoreTarget(2, 5, 0, 1), nil)
    T.eq("D8 target never below captured", GB.restoreTarget(4, 5, 9, 9), 4)

    T.eq("D9 R2 passes all three halves", GB.passesR2(3, 3, 2, 5, false, false), true)
    T.eq("D10 R2 fails on fruit change", GB.passesR2(3, 4, 2, 5, false, false), false)
    T.eq("D11 R2 fails on cut current", GB.passesR2(3, 3, 2, 5, true, false), false)
    T.eq("D12 R2 fails on withered current", GB.passesR2(3, 3, 2, 5, false, true), false)
    T.eq("D13 R2 fails when current not above captured", GB.passesR2(3, 3, 5, 5, false, false), false)
    T.eq("D14 R2 fails on nil current fruit", GB.passesR2(3, nil, 2, 5, false, false), false)
end

-- ============================================================
-- GROUP E: ORDERED START/FINISHED BRACKETS (restore grammar).
-- ============================================================
do
    local b = GB.openBracket(4, true, 'SEASONAL', 7, {})
    T.eq("E1 bracket keeps first transition period", b.firstTransitionPeriod, 4)
    T.eq("E2 bracket target period is the immutable next", b.targetPeriod, 5)
    local wrap = GB.openBracket(12, true, 'SEASONAL', 7, {})
    T.eq("E3 target period wraps 12 to 1", wrap.targetPeriod, 1)

    T.eq("E4 no envelope is MISSING", GB.closeBracket(nil, 4, false, true, 7), GB.CLOSE_MISSING)
    T.eq("E5 pending growth is CLOSED_PENDING", GB.closeBracket(b, 4, true, true, 7), GB.CLOSE_PENDING)
    T.eq("E6 finished period mismatch is UNMATCHED", GB.closeBracket(b, 9, false, true, 7), GB.CLOSE_UNMATCHED)

    local disabled = GB.openBracket(4, true, 'DISABLED', 7, {})
    T.eq("E7 disabled mode is CLOSED_DISABLED", GB.closeBracket(disabled, 4, false, true, 7), GB.CLOSE_DISABLED)

    local gateDownStart = GB.openBracket(4, false, 'SEASONAL', 7, {})
    T.eq("E8 gate down at START is CLOSED_LOCKED", GB.closeBracket(gateDownStart, 4, false, true, 7), GB.CLOSE_LOCKED)
    T.eq("E9 gate down now is CLOSED_LOCKED", GB.closeBracket(b, 4, false, false, 7), GB.CLOSE_LOCKED)

    local stale = GB.openBracket(4, true, 'SEASONAL', 7, {})
    stale.globalStale = true
    T.eq("E10 global stale is CLOSED_STALE", GB.closeBracket(stale, 4, false, true, 7), GB.CLOSE_STALE)
    T.eq("E11 capture generation moved is CLOSED_STALE", GB.closeBracket(b, 4, false, true, 8), GB.CLOSE_STALE)

    T.eq("E12 drained, stable, gate live, same generation is RESTORE",
        GB.closeBracket(b, 4, false, true, 7), GB.CLOSE_RESTORE)
end

-- ============================================================
-- GROUP F: OPTION-SCALING RESTORE-CAP CONTRACT AND UNITS.
-- ============================================================
do
    T.eq("F1 declaration dial is agronomy", GB.RESTORE_DECLARATION.dial, "agronomy")
    T.eq("F2 declaration base is one step", GB.RESTORE_DECLARATION.base, 1)
    T.eq("F3 declaration clamps at one", GB.RESTORE_DECLARATION.clampMin, 1)
    T.eq("F4 declaration clamps at two", GB.RESTORE_DECLARATION.clampMax, 2)

    T.eq("F5 absent profile resolves neutral one step", GB.effectiveRestoreSteps(nil), 1)

    -- Clamp against a stubbed resolver so the clamp is proved independent of the
    -- resolver's own curve maths.
    local realResolve = OptionScalingResolver.resolve
    OptionScalingResolver.resolve = function() return 5 end
    T.eq("F6 resolver over-cap clamps to two", GB.effectiveRestoreSteps({}), 2)
    OptionScalingResolver.resolve = function() return 0 end
    T.eq("F7 resolver under-cap clamps to one", GB.effectiveRestoreSteps({}), 1)
    OptionScalingResolver.resolve = function() return 2 end
    T.eq("F8 resolver mid value passes through", GB.effectiveRestoreSteps({}), 2)
    OptionScalingResolver.resolve = function() return 1.6 end
    T.eq("F9 resolver value rounds then clamps", GB.effectiveRestoreSteps({}), 2)
    OptionScalingResolver.resolve = realResolve
end

-- ============================================================
-- GROUP G: POST-WRITE RESULT OWNS HELD/MISSED CLASSIFICATION.
-- ============================================================
do
    local cells = {
        { key = "1:1", fruitIndex = 3, targetState = 4 },
        { key = "1:2", fruitIndex = 3, targetState = 4 },
        { key = "1:3", fruitIndex = 3, targetState = 4 },
        { key = "1:4", fruitIndex = 3, targetState = 4 },
    }
    local actual = {
        ["1:1"] = { fruitIndex = 3, state = 4 },   -- verified -> HELD
        ["1:2"] = { fruitIndex = 3, state = 5 },   -- wrong state -> MISSED
        ["1:3"] = { fruitIndex = 9, state = 4 },   -- wrong fruit -> MISSED
        -- 1:4 absent -> MISSED
    }
    local restored, missed = GB.verifyPostWrite(cells, actual)
    T.eq("G1 one cell verified restored", restored, 1)
    T.eq("G2 three cells missed", missed, 3)
    T.eq("G3 verified cell flips to HELD", cells[1].outcome, GB.CELL_HELD)
    T.eq("G4 wrong-state cell is MISSED", cells[2].outcome, GB.CELL_MISSED)
    T.eq("G5 wrong-fruit cell is MISSED", cells[3].outcome, GB.CELL_MISSED)
    T.eq("G6 absent cell is MISSED", cells[4].outcome, GB.CELL_MISSED)
end

-- ============================================================
-- GROUP H: FIRST START CAPTURE / LATER START NEVER RECAPTURES.
-- ============================================================
do
    local oldMission = g_currentMission

    -- H1: first START with no value maps creates no envelope (no capture surface).
    local gbNoMaps = GB.new({ soilSystem = { valueMaps = { available = false } } })
    gbNoMaps:initialize()
    g_currentMission = { getIsServer = function() return true end, missionInfo = {} }
    gbNoMaps:onStartGrowthPeriod(4)
    T.eq("H1 first START with no carrier creates no envelope", gbNoMaps._envelope, nil)

    -- H2: with an active envelope, a later START routes to the later-start path and
    -- never recaptures. A matching stable receipt increments its transition count.
    local vm = {
        available = true, resolution = 2048,
        getGrowthInputToken = function() return { farmlandRevision = 1, unscopedRevision = 1 } end,
    }
    local plan = {
        planId = 'p1', planContentHash = 'h', polygonUnionFingerprint = 'g',
        farmlandInputRevision = 1, unscopedInputRevision = 1, settingsFingerprint = '',
        regions = {},
    }
    local gb = GB.new({
        soilSystem = { valueMaps = vm, fieldData = { [7] = {} },
                       _getFarmlandPolygons = function() return {} end },
        viability = { getCellGrowthInfo = function() return { blocked = true } end },
        getGrowthEligibleRegionPlan = function() return plan end,
    })
    gb:initialize()
    gb._envelope = GB.openBracket(4, true, 'SEASONAL', 3, {
        { farmlandId = 7, planId = 'p1', planContentHash = 'h', polygonUnionFingerprint = 'g',
          farmlandInputRevision = 1, unscopedInputRevision = 1, transitionCount = 1, stale = false },
    })
    gb._captureGeneration = 3
    g_currentMission = { getIsServer = function() return true end,
                         missionInfo = { growthMode = GrowthMode.SEASONAL } }
    gb:onStartGrowthPeriod(5)
    T.eq("H2 later START keeps the first transition period", gb._envelope.firstTransitionPeriod, 4)
    T.eq("H3 later START advances lastStartPeriod", gb._envelope.lastStartPeriod, 5)
    T.eq("H4 later START increments the stable receipt transition count",
        gb._envelope.receipts[1].transitionCount, 2)

    -- H5: a growth-mode change at a later START marks the batch globally stale.
    g_currentMission = { getIsServer = function() return true end,
                         missionInfo = { growthMode = GrowthMode.DAILY } }
    gb:onStartGrowthPeriod(6)
    T.eq("H5 growth-mode change stales the whole batch", gb._envelope.globalStale, true)

    g_currentMission = oldMission
end

-- ============================================================
-- GROUP I: FINISHED CLEANUP AND SAVE/LOAD ROUND-TRIP.
-- ============================================================
do
    local oldMission = g_currentMission
    g_currentMission = { getIsServer = function() return true end, missionInfo = {} }

    -- I1: FINISHED with no envelope is MISSING and does not throw.
    local gb0 = GB.new({})
    gb0:initialize()
    T.eq("I1 FINISHED with no envelope is MISSING", gb0:onFinishedGrowthPeriod(4, false), GB.CLOSE_MISSING)

    -- I2: pending growth retains the envelope (no restore, no clear).
    local gbP = GB.new({})
    gbP:initialize()
    gbP._envelope = GB.openBracket(4, true, 'SEASONAL', 1, {})
    gbP:onFinishedGrowthPeriod(4, true)
    T.ok("I2 pending growth retains the envelope", gbP._envelope ~= nil)

    -- I3: a DISABLED bracket rings but restores nothing, and the envelope clears
    -- UNCONDITIONALLY (the cert assertion: a surviving capture would wedge the
    -- next bracket forever).
    local gbD = GB.new({})
    gbD:initialize()
    gbD._envelope = GB.openBracket(4, true, 'DISABLED', 1, {})
    gbD._metadata = { [7] = { active = true } }
    gbD:onFinishedGrowthPeriod(4, false)
    T.eq("I3 disabled drained FINISHED clears the envelope", gbD._envelope, nil)
    T.eq("I3a unconditional cleanup drops active authority", gbD._metadata[7].active, false)

    g_currentMission = oldMission

    -- I4: metadata save/load round-trip through the XML mock.
    local src = GB.new({})
    src:initialize()
    src._captureGeneration = 9
    src._metadata = {
        [7] = { schema = 1, active = true, fruitRosterFingerprint = "wheat|barley",
                terrainResolution = 2048, truthGrainMetres = 4, polygonUnionFingerprint = "g7",
                planContentHash = "h7", settingsFingerprint = "", transitionCount = 3,
                lastTransitionPeriod = 6 },
    }
    local handle = {}
    src:saveToXMLFile(handle, "soilData.growthBlock")

    local dst = GB.new({})
    dst:initialize()
    dst:loadFromXMLFile(handle, "soilData.growthBlock")
    T.eq("I4 generation survives the round-trip", dst._captureGeneration, 9)
    local m = dst._metadata[7]
    T.ok("I5 farmland metadata survives the round-trip", m ~= nil)
    T.eq("I6 geometry fingerprint survives", m.polygonUnionFingerprint, "g7")
    T.eq("I7 plan content hash survives", m.planContentHash, "h7")
    T.eq("I8 transition count survives", m.transitionCount, 3)
    T.eq("I9 restored metadata stays pending validation", dst._pendingValidation[7], true)

    -- I10: StateLedger table round-trip mirrors XML.
    local ledgerState = src:getStateTable()
    local applied = GB.new({})
    applied:initialize()
    applied:applyStateTable(ledgerState)
    T.eq("I10 StateLedger generation round-trips", applied._captureGeneration, 9)
    T.ok("I11 StateLedger farmland metadata round-trips", applied._metadata[7] ~= nil)
end
