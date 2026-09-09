-- SF-53 One Ground growth-credit conformance bar v5 (repo port).
--
-- GROUP A re-points to the SHIPPED One Ground surfaces (Stage 6A): the current
-- repo bar drove the retired lattice store, which is gone. These assertions now
-- pin the conformed module: paired carrier layers, a literal-true Time Guard
-- registration, XML/StateLedger save-load, ordered START/FINISHED brackets fed
-- by the manager dispatch, the pack/witness contract and honest unregistration.
--
-- GROUPS B through I model the pure contract fixed by SF-53-SDS.md v2.6. They
-- prove reference behavior only. They do not prove native fruit-plane writes,
-- polygon clipping, real save bytes or duration, frame time, engine sync,
-- dedicated-server delivery or player understanding.
--
-- All fields, keys, day counts and populations are synthetic branch probes.
-- The 4096-square count is the current carrier cap, not a production claim.
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/ViabilityMask.lua, src/integrations/OptionScalingResolver.lua, src/GrowthCredit.lua

-- ============================================================
-- GROUP A: SHIPPED ONE GROUND SURFACES (Stage 6A re-point).
-- ============================================================
do
    local current = GrowthCredit.new({})
    current:initialize()

    T.eq("A1 shipped bank exposes an XML save method", type(current.saveToXMLFile), "function")
    T.eq("A2 shipped bank exposes an XML load method", type(current.loadFromXMLFile), "function")
    T.eq("A3 shipped bank exposes a StateLedger table serializer", type(current.getStateTable), "function")
    T.eq("A4 shipped source exposes a START growth handler", type(current.onStartGrowthPeriod), "function")

    local oldMission = g_currentMission
    local oldTimeGuard = g_timeGuard
    local registerCalls = 0
    local acceptRegistration = false
    g_timeGuard = nil
    g_currentMission = {
        timeGuard = {
            flowClasses = { simulation = true },
            registerAccrual = function()
                registerCalls = registerCalls + 1
                return acceptRegistration
            end,
        },
    }
    local registration = GrowthCredit.new({})
    registration:initialize()
    T.eq("A7 shipped register reaches Time Guard once", registration:registerDailyAccrual(), false)
    T.eq("A8 shipped source treats a literal-false Time Guard return as unregistered",
        registration._tgAccrualRegistered, false)
    T.eq("A9 shipped source did invoke the refusing provider", registerCalls, 1)

    -- Honest lifecycle: a true return registers; delete then unregisters and drops
    -- the flag. A false return registered nothing, so delete has nothing to drop.
    local unregisterCalls = 0
    acceptRegistration = true
    g_currentMission.timeGuard.unregisterAccrual = function()
        unregisterCalls = unregisterCalls + 1
        return true
    end
    T.eq("A9b shipped true return registers the accrual", registration:registerDailyAccrual(), true)
    registration:delete()
    T.eq("A10 shipped delete unregisters the registered Time Guard accrual",
        unregisterCalls, 1)
    T.eq("A11 shipped delete clears the registration flag",
        registration._tgAccrualRegistered, false)

    g_currentMission = oldMission
    g_timeGuard = oldTimeGuard

    local oldReleaseGate = ReleaseGate
    ReleaseGate = nil
    T.eq("A12 shipped feature fail-opens when the release owner is unavailable",
        current:isLive(), true)
    ReleaseGate = oldReleaseGate

    -- The Option-Scaling profile read follows the vendored readProfile/resolve
    -- contract through the settings hub; absent hub or profile stays neutral.
    local oldResolverMission = g_currentMission
    g_currentMission = {
        settingsHub = {
            getValue = function(_self, _module, key)
                if key == OptionScalingResolver.PRESET_KEY then return "punishing" end
                if key == OptionScalingResolver.dialKey("agronomy") then return 2 end
                if key == OptionScalingResolver.switchKey("agronomy") then return true end
                return nil
            end,
        },
    }
    local periods, days = GrowthCredit.effectiveThresholdDays(nil, 2)
    T.eq("A13a absent profile resolves neutral two-period threshold", periods, 2)
    local hardProfile = { dials = { agronomy = 2 }, switches = { agronomy = true } }
    periods, days = GrowthCredit.effectiveThresholdDays(hardProfile, 2)
    T.eq("A13b shipped resolver honours the agronomy intensity", periods, 3)
    g_currentMission = oldResolverMission

    T.eq("A14 shipped bank derives no old 8m/600 lattice step constant usage",
        type(current._deriveHeader), "nil")

    -- Credit socket returns days plus a provenance witness, nil off-field.
    local credit, witness = current:readCreditAt(7, 1, 1)
    T.eq("A15 shipped credit socket stays nil off-field", credit, nil)
    T.eq("A16 shipped credit socket stays witnessless off-field", witness, nil)

    local currentLayers = {}
    for _, def in ipairs(SoilValueMaps.LAYER_DEFS or {}) do currentLayers[def.key] = true end
    T.eq("A17 shipped carrier has a growth-credit days layer",
        currentLayers.growthCreditDays ~= nil, true)
    T.eq("A18 shipped carrier has a growth-credit fruit layer",
        currentLayers.growthCreditFruit ~= nil, true)
end

local function newBank(thresholdDays)
    return { thresholdDays = thresholdDays, cells = {}, generation = 0 }
end

local function accrueCell(bank, key, fruitIndex, isExcellent, days)
    local existing = bank.cells[key]
    if fruitIndex == nil then
        bank.cells[key] = nil
        bank.generation = bank.generation + 1
        return nil
    end
    if existing ~= nil and existing.fruitIndex ~= fruitIndex then
        existing = nil
        bank.cells[key] = nil
    end
    if not isExcellent then return existing end
    if existing == nil then
        existing = { creditDays = 0, fruitIndex = fruitIndex }
        bank.cells[key] = existing
    end
    existing.creditDays = math.min(bank.thresholdDays,
        existing.creditDays + math.max(0, days or 0))
    bank.generation = bank.generation + 1
    return existing
end

local function witnessDays(crossed, sameFruit, sameInput, sameGeometry,
    sameSettings, excellent)
    if not excellent then return 0 end
    if sameFruit and sameInput and sameGeometry and sameSettings then
        return math.max(0, crossed or 0)
    end
    return 1
end

-- ============================================================
-- GROUP B: BANK IDENTITY, TOTAL DAYS AND EVIDENCE-BOUNDED CATCH-UP.
-- ============================================================
do
    local bank = newBank(6)
    local first = accrueCell(bank, "7:10:20", 3, true, 1)
    T.eq("B1 first accrual stores fruit identity before payout", first.fruitIndex, 3)
    T.eq("B2 first excellent day earns one day", first.creditDays, 1)

    local normal = accrueCell(bank, "7:10:20", 3, false, 1)
    T.eq("B3 normal day pauses rather than erases total credit",
        normal.creditDays, 1)

    local same = accrueCell(bank, "7:10:20", 3, true, 5)
    T.eq("B4 total credit caps at current threshold", same.creditDays, 6)

    local replacement = accrueCell(bank, "7:10:20", 4, true, 1)
    T.eq("B5 new crop identity cannot inherit the old bank",
        replacement.creditDays, 1)
    T.eq("B6 replacement bank belongs to the new crop", replacement.fruitIndex, 4)

    T.eq("B7 unknown or bare ground clears the bank",
        accrueCell(bank, "7:10:20", nil, true, 1), nil)
    T.eq("B8 cleared bank has no retained cell", bank.cells["7:10:20"], nil)

    T.eq("B9 unchanged witness earns every crossed day",
        witnessDays(5, true, true, true, true, true), 5)
    T.eq("B10 changed soil token credits at most the observed day",
        witnessDays(5, true, false, true, true, true), 1)
    T.eq("B11 changed fruit credits at most the observed day",
        witnessDays(5, false, true, true, true, true), 1)
    T.eq("B12 changed geometry credits at most the observed day",
        witnessDays(5, true, true, false, true, true), 1)
    T.eq("B13 changed settings credits at most the observed day",
        witnessDays(5, true, true, true, false, true), 1)
    T.eq("B14 non-excellent current ground earns no invented catch-up",
        witnessDays(5, true, true, true, true, false), 0)
end

local function copyCells(cells)
    local out = {}
    for i, c in ipairs(cells) do
        out[i] = {
            px = c.px, pz = c.pz, creditDays = c.creditDays,
            fruitIndex = c.fruitIndex,
        }
    end
    return out
end

local function encodeRuns(cells)
    local ordered = copyCells(cells)
    table.sort(ordered, function(a, b)
        if a.pz ~= b.pz then return a.pz < b.pz end
        return a.px < b.px
    end)
    local runs = {}
    for _, c in ipairs(ordered) do
        local last = runs[#runs]
        if last ~= nil and last.pz == c.pz
            and last.pxStart + last.length == c.px
            and last.creditDays == c.creditDays
            and last.fruitIndex == c.fruitIndex then
            last.length = last.length + 1
        else
            runs[#runs + 1] = {
                pz = c.pz, pxStart = c.px, length = 1,
                creditDays = c.creditDays, fruitIndex = c.fruitIndex,
            }
        end
    end
    return runs
end

local function decodeRuns(runs)
    local cells = {}
    for _, r in ipairs(runs) do
        for offset = 0, r.length - 1 do
            cells[#cells + 1] = {
                px = r.pxStart + offset,
                pz = r.pz,
                creditDays = r.creditDays,
                fruitIndex = r.fruitIndex,
            }
        end
    end
    return cells
end

local function cellsDigest(cells)
    local rows = {}
    for _, c in ipairs(cells) do
        rows[#rows + 1] = string.format("%d:%d:%d:%d",
            c.px, c.pz, c.creditDays, c.fruitIndex)
    end
    table.sort(rows)
    return table.concat(rows, "|")
end

local function theoreticalRunCount(width, height, alternating)
    if width <= 0 or height <= 0 then return 0 end
    if alternating then return width * height end
    return height
end

-- ============================================================
-- GROUP C: EXACT SPARSE RUN ROUND-TRIP AND ITS WORST-CASE COUNT.
-- ============================================================
do
    local cells = {
        { px = 2, pz = 1, creditDays = 3, fruitIndex = 5 },
        { px = 0, pz = 1, creditDays = 3, fruitIndex = 5 },
        { px = 1, pz = 1, creditDays = 3, fruitIndex = 5 },
        { px = 3, pz = 1, creditDays = 4, fruitIndex = 5 },
        { px = 0, pz = 2, creditDays = 4, fruitIndex = 8 },
    }
    local runs = encodeRuns(cells)
    T.eq("C1 equal consecutive cells collapse to one run", #runs, 3)
    T.eq("C2 first run begins at the lowest x", runs[1].pxStart, 0)
    T.eq("C3 first run keeps all three equal cells", runs[1].length, 3)
    T.eq("C4 credit change starts a new run", runs[2].creditDays, 4)
    T.eq("C5 row change starts a new run", runs[3].pz, 2)
    T.eq("C6 run decode round-trips exact cells",
        cellsDigest(decodeRuns(runs)), cellsDigest(cells))

    T.eq("C7 coherent 4096-square carrier needs one run per row",
        theoreticalRunCount(4096, 4096, false), 4096)
    T.eq("C8 alternating 4096-square carrier needs one run per cell",
        theoreticalRunCount(4096, 4096, true), 16777216)
    T.eq("C9 alternating worst case is 4096 times the coherent run count",
        theoreticalRunCount(4096, 4096, true)
            / theoreticalRunCount(4096, 4096, false), 4096)
    T.eq("C10 empty carrier serializes no runs",
        theoreticalRunCount(0, 4096, false), 0)

    local function twoLayerBytes(resolution)
        return 2 * resolution * resolution
    end
    T.eq("C11 two 1024-square 8-bit layers allocate 2 MiB",
        twoLayerBytes(1024), 2 * 1024 * 1024)
    T.eq("C12 two 2048-square 8-bit layers allocate 8 MiB",
        twoLayerBytes(2048), 8 * 1024 * 1024)
    T.eq("C13 two 4096-square 8-bit layers allocate 32 MiB",
        twoLayerBytes(4096), 32 * 1024 * 1024)

    local exactDef = { minVal = 0, maxVal = 254 }
    T.eq("C14 semantic zero encodes to raw one", SoilValueMaps._encode(0, exactDef), 1)
    T.eq("C15 maximum engine fruit index 63 encodes exactly",
        SoilValueMaps._encode(63, exactDef), 64)
    T.eq("C16 maximum current threshold 84 days encodes exactly",
        SoilValueMaps._encode(84, exactDef), 85)
    T.eq("C17 semantic 254 reaches raw 255 exactly",
        SoilValueMaps._encode(254, exactDef), 255)
    T.eq("C18 six fruit index bits support at most 63 fruit types", 2 ^ 6 - 1, 63)
    T.eq("C19 three periods at 28 days require 84 bank days", 3 * 28, 84)
    T.ok("C20 required bank days fit the exact 8-bit semantic range", 84 <= 254)
end

local function newCarrier()
    return { credit = {}, fruit = {} }
end

local function carrierSet(carrier, key, creditDays, fruitIndex)
    if creditDays == nil or creditDays <= 0 or fruitIndex == nil or fruitIndex <= 0 then
        carrier.credit[key] = nil
        carrier.fruit[key] = nil
        return false
    end
    carrier.credit[key] = creditDays
    carrier.fruit[key] = fruitIndex
    return true
end

local function carrierGet(carrier, key)
    local credit = carrier.credit[key]
    local fruit = carrier.fruit[key]
    if credit == nil or credit <= 0 or fruit == nil or fruit <= 0 then return nil end
    return credit, fruit
end

local function carrierSetWithInjectedHalfFailure(carrier, key, creditDays, fruitIndex,
    failSide)
    if failSide ~= "credit" then carrier.credit[key] = creditDays end
    if failSide ~= "fruit" then carrier.fruit[key] = fruitIndex end
    local credit = carrier.credit[key]
    local fruit = carrier.fruit[key]
    local valid = type(credit) == "number" and credit > 0 and credit <= 254
        and type(fruit) == "number" and fruit > 0 and fruit <= 63
    if not valid then
        carrier.credit[key] = nil
        carrier.fruit[key] = nil
        return false
    end
    return true
end

local function buildMetadata(header)
    return {
        schema = 1,
        fruitRosterFingerprint = header.fruitRosterFingerprint,
        terrainResolution = header.terrainResolution,
        truthGrainMetres = header.truthGrainMetres,
        farmlands = {
            [header.farmlandId] = {
                polygonUnionFingerprint = header.polygonUnionFingerprint,
                lastAccruedMonotonicDay = header.lastAccruedMonotonicDay,
            },
        },
    }
end

local function validateMetadata(state, expected)
    if state.schema ~= 1 then return false, "SCHEMA" end
    if state.fruitRosterFingerprint ~= expected.fruitRosterFingerprint then
        return false, "FRUIT_ROSTER"
    end
    if state.terrainResolution ~= expected.terrainResolution
        or state.truthGrainMetres ~= expected.truthGrainMetres then
        return false, "CARRIER"
    end
    local saved = state.farmlands[expected.farmlandId]
    if saved == nil or saved.polygonUnionFingerprint ~= expected.polygonUnionFingerprint then
        return false, "GEOMETRY"
    end
    return true, "PENDING_VALIDATION"
end

local function classifyPair(days, fruit, metadataClaimsBank, expectedResolution)
    local neitherExists = not days.exists and not fruit.exists
    if neitherExists and not metadataClaimsBank then return "FRESH" end
    local complete = days.exists and fruit.exists
        and days.loaded and fruit.loaded
        and days.resolution == expectedResolution
        and fruit.resolution == expectedResolution
    if complete then return "COMPLETE" end
    return "PAIR_INVALID"
end

-- ============================================================
-- GROUP D: TWO-LAYER BANK AND SMALL METADATA LOAD.
-- ============================================================
do
    local carrier = newCarrier()
    T.eq("D1 valid bank cell writes both carrier values",
        carrierSet(carrier, "7:0:0", 2, 3), true)
    local credit, fruit = carrierGet(carrier, "7:0:0")
    T.eq("D2 credit-days layer retains exact days", credit, 2)
    T.eq("D3 fruit layer retains exact fruit index", fruit, 3)

    T.eq("D4 zero credit clears both layers",
        carrierSet(carrier, "7:0:0", 0, 3), false)
    T.eq("D5 cleared credit is unavailable", carrierGet(carrier, "7:0:0"), nil)
    T.eq("D6 clear removes fruit identity too", carrier.fruit["7:0:0"], nil)

    carrierSet(carrier, "7:1:0", 84, 63)
    credit, fruit = carrierGet(carrier, "7:1:0")
    T.eq("D7 maximum required days remain exact", credit, 84)
    T.eq("D8 maximum engine fruit index remains exact", fruit, 63)

    local state = buildMetadata({
        fruitRosterFingerprint = "fruit-roster-a",
        terrainResolution = 2048,
        truthGrainMetres = 2,
        farmlandId = 7,
        polygonUnionFingerprint = "geom-7",
        lastAccruedMonotonicDay = 30,
    })
    T.eq("D9 metadata carries no cell runs", state.runs, nil)
    T.eq("D10 metadata carries last accrued day",
        state.farmlands[7].lastAccruedMonotonicDay, 30)

    local valid, status = validateMetadata(state, {
        fruitRosterFingerprint = "fruit-roster-a",
        terrainResolution = 2048,
        truthGrainMetres = 2,
        farmlandId = 7,
        polygonUnionFingerprint = "geom-7",
    })
    T.eq("D11 matching metadata retains carrier for validation", valid, true)
    T.eq("D12 restored bank is pending current-session validation",
        status, "PENDING_VALIDATION")

    valid, status = validateMetadata(state, {
        fruitRosterFingerprint = "fruit-roster-b",
        terrainResolution = 2048,
        truthGrainMetres = 2,
        farmlandId = 7,
        polygonUnionFingerprint = "geom-7",
    })
    T.eq("D13 changed fruit roster refuses numeric identity remap", valid, false)
    T.eq("D14 fruit roster refusal is explicit", status, "FRUIT_ROSTER")

    valid, status = validateMetadata(state, {
        fruitRosterFingerprint = "fruit-roster-a",
        terrainResolution = 4096,
        truthGrainMetres = 2,
        farmlandId = 7,
        polygonUnionFingerprint = "geom-7",
    })
    T.eq("D15 changed carrier resolution refuses remap", valid, false)
    T.eq("D16 carrier mismatch is explicit", status, "CARRIER")

    valid, status = validateMetadata(state, {
        fruitRosterFingerprint = "fruit-roster-a",
        terrainResolution = 2048,
        truthGrainMetres = 2,
        farmlandId = 7,
        polygonUnionFingerprint = "geom-changed",
    })
    T.eq("D17 changed geometry refuses remap", valid, false)
    T.eq("D18 geometry mismatch is explicit", status, "GEOMETRY")

    T.eq("D19 no files and no metadata is a fresh bank",
        classifyPair({ exists = false }, { exists = false }, false, 2048), "FRESH")
    T.eq("D20 both loaded files at expected resolution form a complete pair",
        classifyPair(
            { exists = true, loaded = true, resolution = 2048 },
            { exists = true, loaded = true, resolution = 2048 },
            true, 2048), "COMPLETE")
    T.eq("D21 days file without fruit file invalidates the pair",
        classifyPair(
            { exists = true, loaded = true, resolution = 2048 },
            { exists = false }, true, 2048), "PAIR_INVALID")
    T.eq("D22 fruit file without days file invalidates the pair",
        classifyPair(
            { exists = false },
            { exists = true, loaded = true, resolution = 2048 },
            true, 2048), "PAIR_INVALID")
    T.eq("D23 one failed load invalidates the pair",
        classifyPair(
            { exists = true, loaded = false, resolution = 2048 },
            { exists = true, loaded = true, resolution = 2048 },
            true, 2048), "PAIR_INVALID")
    T.eq("D24 one wrong resolution invalidates the pair",
        classifyPair(
            { exists = true, loaded = true, resolution = 1024 },
            { exists = true, loaded = true, resolution = 2048 },
            true, 2048), "PAIR_INVALID")
    T.eq("D25 metadata claiming bank while both files are absent invalidates pair",
        classifyPair({ exists = false }, { exists = false }, true, 2048),
        "PAIR_INVALID")

    local injected = newCarrier()
    T.eq("D26 one-sided credit write refuses logical commit",
        carrierSetWithInjectedHalfFailure(injected, "7:9:9", 4, 3, "fruit"), false)
    T.eq("D27 refused one-sided write clears credit half",
        injected.credit["7:9:9"], nil)
    T.eq("D28 refused one-sided write clears fruit half",
        injected.fruit["7:9:9"], nil)
end

local function newBracketQueue()
    return { nextSequence = 1, open = {} }
end

local function startBracket(queue, transitionPeriod, gateLive, growthMode, bankGeneration)
    local b = {
        sequence = queue.nextSequence,
        transitionPeriod = transitionPeriod,
        targetPeriod = transitionPeriod % 12 + 1,
        gateLiveAtStart = gateLive,
        growthMode = growthMode,
        bankGeneration = bankGeneration,
    }
    queue.nextSequence = queue.nextSequence + 1
    queue.open[#queue.open + 1] = b
    return b
end

local function finishBracket(queue, period, hasPendingGrowth, gateLiveNow,
    currentBankGeneration)
    local index = nil
    for i, b in ipairs(queue.open) do
        if b.transitionPeriod == period then index = i; break end
    end
    if index == nil then return nil, "MISSING" end
    local b = table.remove(queue.open, index)
    if hasPendingGrowth then return b, "CLOSED_PENDING" end
    if b.growthMode == "DISABLED" then return b, "CLOSED_DISABLED" end
    if not b.gateLiveAtStart or not gateLiveNow then return b, "CLOSED_LOCKED" end
    if b.bankGeneration ~= currentBankGeneration then return b, "CLOSED_STALE" end
    return b, "SPEND"
end

-- ============================================================
-- GROUP E: ORDERED START/FINISHED BRACKETS.
-- ============================================================
do
    local q = newBracketQueue()
    local first = startBracket(q, 5, true, "SEASONAL", 11)
    local second = startBracket(q, 6, true, "SEASONAL", 12)
    T.eq("E1 overlapping START receives distinct sequence", second.sequence, first.sequence + 1)
    T.eq("E2 first bracket derives immutable next seasonal period", first.targetPeriod, 6)
    T.eq("E3 second bracket derives its own target period", second.targetPeriod, 7)
    T.eq("E4 two START deliveries remain separately open", #q.open, 2)

    local closed, state = finishBracket(q, 5, true, true, 11)
    T.eq("E5 prior period matches its own bracket", closed.sequence, first.sequence)
    T.eq("E6 pending delivery closes without spend", state, "CLOSED_PENDING")
    T.eq("E7 next bracket remains open", #q.open, 1)

    closed, state = finishBracket(q, 6, false, true, 12)
    T.eq("E8 drained period matches the second bracket", closed.sequence, second.sequence)
    T.eq("E9 drained stable bracket is eligible to re-enumerate and spend", state, "SPEND")
    T.eq("E10 queue drains completely", #q.open, 0)

    local missing
    missing, state = finishBracket(q, 7, false, true, 12)
    T.eq("E11 FINISHED without START refuses", missing, nil)
    T.eq("E12 missing bracket names the refusal", state, "MISSING")

    local locked = newBracketQueue()
    startBracket(locked, 8, false, "SEASONAL", 20)
    _, state = finishBracket(locked, 8, false, true, 20)
    T.eq("E13 mid-bracket open cannot retroactively arm", state, "CLOSED_LOCKED")
    startBracket(locked, 9, true, "SEASONAL", 21)
    _, state = finishBracket(locked, 9, false, false, 21)
    T.eq("E14 mid-bracket close suppresses spend", state, "CLOSED_LOCKED")
    startBracket(locked, 10, true, "DISABLED", 22)
    _, state = finishBracket(locked, 10, false, true, 22)
    T.eq("E15 disabled growth rings but never rewards", state, "CLOSED_DISABLED")

    local stale = newBracketQueue()
    startBracket(stale, 11, true, "SEASONAL", 30)
    _, state = finishBracket(stale, 11, false, true, 31)
    T.eq("E16 changed bank generation suppresses spend and closes bracket",
        state, "CLOSED_STALE")
    local wrap = startBracket(stale, 12, true, "SEASONAL", 31)
    T.eq("E17 December transition derives period one with fixed wrap",
        wrap.targetPeriod, 1)
end

local function effectiveThreshold(profile, daysPerPeriod)
    local declaration = {
        dial = "agronomy", base = 2, neutral = 2,
        clampMin = 1, clampMax = 3,
    }
    local periods = OptionScalingResolver.resolve(declaration, profile)
    periods = math.max(1, math.floor(periods + 0.5))
    return periods, periods * daysPerPeriod
end

-- ============================================================
-- GROUP F: SHIPPED OPTION-SCALING CONTRACT AND UNITS.
-- ============================================================
do
    local periods, days = effectiveThreshold(nil, 3)
    T.eq("F1 absent profile keeps neutral two-period threshold", periods, 2)
    T.eq("F2 neutral threshold converts through days per period", days, 6)

    local off = { dials = { agronomy = 2 }, switches = { agronomy = false } }
    periods, days = effectiveThreshold(off, 3)
    T.eq("F3 switched-off dial keeps neutral behavior", periods, 2)
    T.eq("F4 switched-off dial does not kill the feature", days, 6)

    local hard = { dials = { agronomy = 2 }, switches = { agronomy = true } }
    periods, days = effectiveThreshold(hard, 3)
    T.eq("F5 agronomy intensity two rounds to three periods", periods, 3)
    T.eq("F6 three periods at three days each means nine excellent days", days, 9)

    local relaxed = { dials = { agronomy = 0 }, switches = { agronomy = true } }
    periods, days = effectiveThreshold(relaxed, 3)
    T.eq("F7 relaxed curve respects the one-period floor", periods, 1)
    T.eq("F8 one period at three days means three excellent days", days, 3)
end

local function verifyWrite(cells, actual)
    local reset, retained = 0, 0
    for _, cell in ipairs(cells) do
        local key = cell.key
        local observed = actual[key]
        if observed ~= nil and observed.fruitIndex == cell.fruitIndex
            and observed.state == cell.targetState then
            cell.creditDays = 0
            reset = reset + 1
        else
            retained = retained + 1
        end
    end
    return reset, retained
end

-- ============================================================
-- GROUP G: POST-WRITE RESULT OWNS CREDIT RESET.
-- ============================================================
do
    local cells = {
        { key = "a", fruitIndex = 3, targetState = 4, creditDays = 6 },
        { key = "b", fruitIndex = 3, targetState = 4, creditDays = 6 },
        { key = "c", fruitIndex = 3, targetState = 4, creditDays = 6 },
    }
    local reset, retained = verifyWrite(cells, {
        a = { fruitIndex = 3, state = 4 },
        b = { fruitIndex = 3, state = 3 },
        c = { fruitIndex = 4, state = 4 },
    })
    T.eq("G1 only verified target cell resets", reset, 1)
    T.eq("G2 filtered or identity-mismatched cells retain credit", retained, 2)
    T.eq("G3 verified cell credit becomes zero", cells[1].creditDays, 0)
    T.eq("G4 unchanged source-state cell keeps credit", cells[2].creditDays, 6)
    T.eq("G5 different fruit at target state keeps old bank unspent",
        cells[3].creditDays, 6)
end

local function creditWitness(bank, key, request)
    local cell = bank.cells[key]
    if cell == nil or request.server ~= true then return nil end
    if request.current ~= true or request.coversPoint ~= true then return nil end
    if request.carrierOwnerFarmlandId ~= nil
        and request.carrierOwnerFarmlandId ~= request.farmlandId then return nil end
    if cell.fruitIndex ~= request.fruitIndex then return nil end
    local banked = cell.creditDays >= bank.thresholdDays
    local deferredByHold = banked and request.capturedAtFirstStart == true
    return cell.creditDays, {
        farmlandId = request.farmlandId,
        polygonUnionFingerprint = request.polygonUnionFingerprint,
        coversPoint = true,
        siblingGeneration = bank.generation,
        current = true,
        fruitIndex = cell.fruitIndex,
        creditDays = cell.creditDays,
        thresholdDays = bank.thresholdDays,
        banked = banked,
        ready = banked and not deferredByHold,
        deferredByHold = deferredByHold,
    }
end

-- ============================================================
-- GROUP H: SIBLING WITNESS AND BAR LIMITS.
-- ============================================================
do
    local bank = newBank(6)
    bank.cells["7:1:1"] = { creditDays = 6, fruitIndex = 3 }
    bank.generation = 9
    local credit, witness = creditWitness(bank, "7:1:1", {
        server = true, current = true, coversPoint = true,
        farmlandId = 7, polygonUnionFingerprint = "geom-7", fruitIndex = 3,
    })
    T.eq("H1 current matching bank returns credit", credit, 6)
    T.eq("H2 witness carries farmland identity", witness.farmlandId, 7)
    T.eq("H3 witness carries polygon-union fingerprint",
        witness.polygonUnionFingerprint, "geom-7")
    T.eq("H4 witness proves point coverage", witness.coversPoint, true)
    T.eq("H5 witness carries sibling generation", witness.siblingGeneration, 9)
    T.eq("H6 threshold-ready bank reports ready", witness.ready, true)
    T.eq("H6a threshold-ready bank reports banked", witness.banked, true)

    local _, deferred = creditWitness(bank, "7:1:1", {
        server = true, current = true, coversPoint = true, capturedAtFirstStart = true,
        farmlandId = 7, carrierOwnerFarmlandId = 7,
        polygonUnionFingerprint = "geom-7", fruitIndex = 3,
    })
    T.eq("H6b active hold keeps the earned bank", deferred.banked, true)
    T.eq("H6c active hold prevents a ready-this-batch claim", deferred.ready, false)
    T.eq("H6d active hold publishes derived deferral", deferred.deferredByHold, true)

    local refused = creditWitness(bank, "7:1:1", {
        server = false, current = true, coversPoint = true,
        farmlandId = 7, polygonUnionFingerprint = "geom-7", fruitIndex = 3,
    })
    T.eq("H7 client credit truth is unavailable", refused, nil)
    refused = creditWitness(bank, "7:1:1", {
        server = true, current = false, coversPoint = true,
        farmlandId = 7, polygonUnionFingerprint = "geom-7", fruitIndex = 3,
    })
    T.eq("H8 stale bank is unavailable", refused, nil)
    refused = creditWitness(bank, "7:1:1", {
        server = true, current = true, coversPoint = true,
        farmlandId = 7, polygonUnionFingerprint = "geom-7", fruitIndex = 4,
    })
    T.eq("H9 wrong fruit identity is unavailable", refused, nil)
    refused = creditWitness(bank, "7:1:1", {
        server = true, current = true, coversPoint = true,
        farmlandId = 7, carrierOwnerFarmlandId = 9, fruitIndex = 3,
    })
    T.eq("H9a non-owner boundary bank is unavailable", refused, nil)

    T.ok("H10 pure model cannot prove native filter or polygon writes", true)
    T.ok("H11 pure count cannot prove real XML bytes or save duration", true)
    T.ok("H12 pure model cannot prove engine client synchronization", true)
    T.ok("H13 pure model cannot select a runtime frame budget", true)
end

-- ============================================================
-- GROUP I: GROWTH-SET R1 FARMLAND RECEIPTS, HOLD EXCLUSION AND COMPACT WITNESS.
-- SF-53-SDS.md:23-48. Literals 84, 128 and fruit 1..63 come from that
-- controlling block and the existing units table at SF-53-SDS.md:300.
-- ============================================================
local function packCredit(days, applied)
    if days < 0 or days > 84 then return nil end
    return days + (applied and 128 or 0)
end

local function unpackCredit(value)
    if type(value) ~= "number" or value < 0 or value > 212 then return nil end
    local applied = value >= 128
    return value % 128, applied
end

local function farmlandReceiptVector(receipts)
    table.sort(receipts, function(a, b) return a.farmlandId < b.farmlandId end)
    return receipts
end

local function maySpendCredit(capturedAtFirstStart, ready)
    return ready == true and capturedAtFirstStart ~= true
end

do
    local packed = packCredit(84, true)
    T.eq("I1 maximum bank plus applied witness fits one byte", packed, 212)
    local days, applied = unpackCredit(packed)
    T.eq("I2 low seven bits retain exact bank days", days, 84)
    T.eq("I3 high bit retains applied-this-crop witness", applied, true)
    T.eq("I4 later accrual can preserve the applied bit", packCredit(1, applied), 129)
    T.eq("I5 out-of-contract bank days refuse", packCredit(85, false), nil)

    local receipts = farmlandReceiptVector({
        {farmlandId=9,planId="p9",bankGeneration=4},
        {farmlandId=2,planId="p2",bankGeneration=7},
    })
    T.eq("I6 START bracket carries every farmland receipt", #receipts, 2)
    T.eq("I7 receipt vector is sorted by farmland id", receipts[1].farmlandId, 2)
    T.eq("I8 each farmland keeps its own plan id", receipts[2].planId, "p9")
    T.eq("I9 each farmland keeps its own bank generation", receipts[1].bankGeneration, 7)
    T.eq("I10 first-START blocked capture wins over ready credit",
        maySpendCredit(true, true), false)
    T.eq("I11 ready credit outside the hold capture may spend",
        maySpendCredit(false, true), true)
end

T.summary()
