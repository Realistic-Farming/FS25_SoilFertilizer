-- FILL TYPE INDEX WIDTH FLOOR: absorbing FillType Extender's capability.
--
-- We raise FillTypeManager.SEND_NUM_BITS from the engine default of 8 to 10, a cap
-- of 1023 fill types, so players on large maps do not need FTE. The whole risk of
-- this change sits in one word: it must RAISE and never SET, because other mods
-- write this same constant at their own file load and sourcing order decides who
-- runs first. An unconditional assignment would truncate a width another mod had
-- already established, and the symptom would be a multiplayer desync on a
-- stranger's server rather than anything visible on the machine that caused it.
--
-- WHY 10 AND NOT FTE'S 9. A 9-bit floor caps at 511, and the one heavy modset
-- anyone has measured carries at least 513 live fill types, so 9 would not load
-- it. F3b and F3c pin that as arithmetic rather than leaving it as an argument.
--
-- TWO CLAIMS THAT LOOK ALIKE AND ARE NOT THE SAME CLAIM. Only the second justifies
-- this change, and conflating them cost an evening:
--   1. "Our fill type warnings are caused by the 255 cap, and FTE prevents them."
--      FALSE. They fired with FTE loaded AND with FTE disabled, about 27 seconds
--      before gameplay began. They were the deferred-init defect, fixed in #970.
--   2. "Some large maps genuinely exceed 255 fill types." TRUE. Known cases: Null
--      Creek, Witcombe, No Creek. Measured case: 513+ live engine indices in a
--      tester's River Bend session.
-- Nothing in this bar has anything to do with claim 1.
--
-- Engine facts this bar encodes, each read from D:\FS25_Decoded at the line:
--   FillTypeManager.lua:6        SEND_NUM_BITS = 8, the default we raise from
--   FillTypeManager.lua:203-204  addFillType recomputes 2^SEND_NUM_BITS - 1 on
--                                EVERY call, reading the class field live, which
--                                is why a raise before registration is enough
--   FillTypeManager.lua:76-78    addModWithFillTypes only table.inserts into
--                                modsToLoad, so mod fill types are QUEUED, not
--                                registered, when modDesc is read
--   mission00.lua:261            loadModFillTypes runs later, as an async task
--   mods.lua:933-937             extraSourceFiles are sourced before both
--
-- What this bar does NOT prove: that the engine honours the wider field on the
-- wire, that a dedicated server and a client agree on it, or anything about the
-- two SIGNED Baler sites. Those are network facts and belong to the TESTING row.
--
--!load: src/utils/SoilFillTypeWidth.lua

local DEFAULT_BITS = 8    -- FillTypeManager.lua:6
local RL_BITS      = 10   -- Realistic Livestock's floor
local FLOOR        = SoilFillTypeWidth.FLOOR_BITS

local function manager(bits)
    return { SEND_NUM_BITS = bits }
end

-- ── GROUP A: the floor itself ────────────────────────────────────────────────
do
    T.eq("A1: the floor is 10, deliberately ABOVE FillType Extender's 9", FLOOR, 10)

    local m = manager(DEFAULT_BITS)
    local raised, width = SoilFillTypeWidth.applyFloor(m)
    T.eq("A2: the engine default of 8 is raised", raised, true)
    T.eq("A3: to exactly 10", m.SEND_NUM_BITS, 10)
    T.eq("A4: and the new width is reported back", width, 10)
end

-- ── GROUP B: it must never LOWER, which is the whole risk ────────────────────
do
    -- Realistic Livestock sourced first and set 10. We now match that exactly, so
    -- this is the equal case rather than the above case: still no write, because
    -- the guard raises only when strictly below the floor.
    local m = manager(RL_BITS)
    local raised, width = SoilFillTypeWidth.applyFloor(m)
    T.eq("B1: a width already at 10 is left alone", m.SEND_NUM_BITS, 10)
    T.eq("B2: and the call reports it did not raise", raised, false)
    T.eq("B3: reporting the width actually in force", width, 10)

    -- A width ABOVE ours, which other ecosystem mods do set, must never be lowered.
    -- This is the case that would desync a stranger's server.
    local hi = manager(12)
    SoilFillTypeWidth.applyFloor(hi)
    T.eq("B3b: a width of 12 is NOT lowered to our 10", hi.SEND_NUM_BITS, 12)

    for _, bits in ipairs({ 10, 11, 12, 16 }) do
        local mm = manager(bits)
        SoilFillTypeWidth.applyFloor(mm)
        T.eq("B4: width " .. bits .. " is left untouched", mm.SEND_NUM_BITS, bits)
    end
end

-- ── GROUP C: a second raise is a no-op ───────────────────────────────────────
do
    local m = manager(DEFAULT_BITS)
    local firstRaised = SoilFillTypeWidth.applyFloor(m)
    local secondRaised, secondWidth = SoilFillTypeWidth.applyFloor(m)
    local thirdRaised = SoilFillTypeWidth.applyFloor(m)

    T.eq("C1: the first call raises", firstRaised, true)
    T.eq("C2: the second does not", secondRaised, false)
    T.eq("C3: nor the third", thirdRaised, false)
    T.eq("C4: and the width is still 10, not 20", m.SEND_NUM_BITS, 10)
    T.eq("C5: the second call reports the width in force", secondWidth, 10)
end

-- ── GROUP D: the width is read LIVE, never captured ──────────────────────────
-- If applyFloor cached the width it first saw, a later call would decide against
-- a number that no longer exists. Other mods write this constant during sourcing,
-- so that is a real sequence and not a hypothetical one.
do
    local m = manager(DEFAULT_BITS)
    SoilFillTypeWidth.applyFloor(m)             -- now 10
    m.SEND_NUM_BITS = 12                        -- something else raises higher after us
    local raised = SoilFillTypeWidth.applyFloor(m)
    T.eq("D1: a later call sees 12, not the 8 it first saw", raised, false)
    T.eq("D2: and leaves the higher width alone", m.SEND_NUM_BITS, 12)

    -- The reverse direction: something lowers it back below the floor.
    m.SEND_NUM_BITS = DEFAULT_BITS
    local raisedAgain = SoilFillTypeWidth.applyFloor(m)
    T.eq("D3: and it raises again when the live value is below the floor", raisedAgain, true)
    T.eq("D4: back to 10", m.SEND_NUM_BITS, 10)
end

-- ── GROUP E: a malformed or absent manager is survived, never written to ─────
-- This runs at source time, before anything of ours is loaded. It must not be the
-- reason a mod fails to load.
do
    local ok, raised = pcall(SoilFillTypeWidth.applyFloor, nil)
    T.ok("E1: a nil manager does not throw", ok)

    ok, raised = pcall(SoilFillTypeWidth.applyFloor, "not a table")
    T.ok("E2: a non-table manager does not throw", ok)
    T.eq("E2: and reports no raise", ok and raised, false)

    local m = { SEND_NUM_BITS = "8" }           -- a string, not a number
    ok, raised = pcall(SoilFillTypeWidth.applyFloor, m)
    T.ok("E3: a non-numeric width does not throw", ok)
    T.eq("E3: and reports no raise", ok and raised, false)
    T.eq("E3: and the field is left exactly as found", m.SEND_NUM_BITS, "8")

    local empty = {}
    ok, raised = pcall(SoilFillTypeWidth.applyFloor, empty)
    T.ok("E4: an absent width does not throw", ok)
    T.eq("E4: and reports no raise", ok and raised, false)
    T.eq("E4: and no field is invented on the manager", empty.SEND_NUM_BITS, nil)
end

-- ── GROUP F: what the width actually buys, mirroring the engine's own formula ─
do
    T.eq("F1: at the engine default, 255 fill types", SoilFillTypeWidth.maxFillTypes(8), 255)
    T.eq("F2: at FillType Extender's 9, 511, which is BELOW the measured 513", SoilFillTypeWidth.maxFillTypes(9), 511)
    T.eq("F3: at our floor of 10, 1023", SoilFillTypeWidth.maxFillTypes(10), 1023)
    -- The reason the floor is 10 and not 9, as a number rather than an argument.
    --
    -- CITED SO IT CAN BE RE-RUN RATHER THAN TRUSTED. A bench asserting a bare
    -- measurement reads as settled fact while being uncheckable by the next reader,
    -- which makes it weaker than not asserting it at all. Bob raised exactly that
    -- and was right to: he could not reach this log, because it is not in any game
    -- log path. On his machine the equivalent numbers are 474 prices and a highest
    -- index of 495, which is a different machine and a different modset.
    --
    -- Source: Wizard's River Bend session, 2026-09-21, delivered through Discord to
    --   C:\Users\tison\.claude\channels\discord\inbox\1790024913586-1551700977298706484.txt
    -- Two lines carry it, and the second is the one that matters:
    --   :3083  "[MDM] MarketEngine: snapshotted 491 base prices"  (a COUNT)
    --   :6229  "[MDM] MarketScreenGraph: seeded buffer for fillType 513"  (an INDEX,
    --          the highest in the file)
    -- Note 491 also appears as an index at :6207, so count and index must not be
    -- crossed here; the count line is :3083 and nothing else.
    --
    -- WHY AN INDEX OF 513 CAN EXIST AT ALL, which is the corroboration rather than
    -- the observation: 513 is impossible under a 511 cap, so something raised the
    -- width. FS25_RealisticLivestockRM is loaded at :1161 of that log and raises it
    -- to 10 at file load, silently, with no print of its own. So that setup reaches
    -- 513 only because RL is already raising it, and WITHOUT RL it would not load
    -- at 9. That is precisely F3b's claim, arrived at from the opposite direction.
    --
    -- Why the index is the lower bound on the registry: MarketEngine keys prices by
    -- fillType.index taken from g_fillTypeManager:getFillTypes(), and addFillType
    -- assigns index = #fillTypes + 1, so an index of 513 means at least 513 were
    -- registered. And the entries are live rather than restored junk: MDM restored
    -- 576 rows from a legacy save by raw index, but cleanupStaleEntries purges any
    -- index absent from the live registry, it is called unconditionally on the
    -- server path, and the log shows zero purges. That it RAN is provable rather
    -- than assumed, because "economic model latched" is logged from six lines after
    -- the purge call and is present in the file.
    local MEASURED = 513
    T.ok("F3b: 9 bits would NOT load the measured 513-fill-type setup",
        SoilFillTypeWidth.maxFillTypes(9) < MEASURED)
    T.ok("F3c: our floor of 10 does", SoilFillTypeWidth.maxFillTypes(FLOOR) >= MEASURED)
    -- F3d is the SAME conclusion with no measurement in it at all. StockGuard's own
    -- cited record puts Realistic Livestock at 10, so sitting there gives one agreed
    -- floor instead of two competing ones. If the log above is ever lost, the reason
    -- for 10 over 9 survives in this assertion alone.
    local RL_RECORDED_FLOOR = 10   -- StockGuard SGCapacity.ADAPTERS, realisticLivestock
    T.eq("F3d: and 10 is where Realistic Livestock already sits, measurement aside",
        FLOOR, RL_RECORDED_FLOOR)

    -- The Baler's two SIGNED sites (Baler.lua:672, :712) cover
    -- -2^(bits-1) .. 2^(bits-1)-1, while the cap above is unsigned. The signed
    -- ceiling is therefore always BELOW the index ceiling, at every width, which
    -- is why raising the constant relocates the bale wrap rather than removing it.
    local function signedMax(bits) return 2 ^ (bits - 1) - 1 end
    T.ok("F4: at 8, indices above 127 wrap while the cap allows 255",
        signedMax(8) == 127 and SoilFillTypeWidth.maxFillTypes(8) == 255)
    T.ok("F5: at 9, indices above 255 wrap while the cap allows 511",
        signedMax(9) == 255 and SoilFillTypeWidth.maxFillTypes(9) == 511)
    T.ok("F6: the signed ceiling is below the index cap at EVERY width, so no",
        signedMax(8) < SoilFillTypeWidth.maxFillTypes(8)
        and signedMax(9) < SoilFillTypeWidth.maxFillTypes(9)
        and signedMax(10) < SoilFillTypeWidth.maxFillTypes(10)
        and signedMax(16) < SoilFillTypeWidth.maxFillTypes(16))
    -- F6 continued: ...value of this constant fixes the Baler. Raising 8 to 9 is
    -- still a strict improvement for any save at or below 255 fill types, which is
    -- every save that can reach the defect today.
end

-- ── GROUP G: the one load line, driven as main.lua's call site drives it ────────
-- main.lua does exactly this: applyFloor(), then loadLine(raised, width), then
-- print the line if there is one. Tyson's ruling of 2026-09-22: when another mod
-- has already satisfied the floor, say so, so a log alone shows the floor is in
-- force. A tester's log with no "raised" line read as a possible miss for an
-- evening until FS25_ProductionStorageControl was found setting 10 before us.
do
    local function callSite(bits)
        local m = manager(bits)
        local raised, width = SoilFillTypeWidth.applyFloor(m)
        return SoilFillTypeWidth.loadLine(raised, width)
    end
    local line8 = callSite(DEFAULT_BITS)
    T.ok("G1: at the engine default of 8 the line is the RAISED line, naming 10 and 1023",
        line8 ~= nil and line8:find("width raised to 10 (1023 fill types)", 1, true) ~= nil)
    T.ok("G2: and it is not the already line", line8 ~= nil and line8:find("already", 1, true) == nil)

    local line10 = callSite(RL_BITS)
    T.ok("G3: at 10 (Realistic Livestock, ProductionStorageControl got there first) the line is the ALREADY line naming 10 and 1023",
        line10 ~= nil and line10:find("width already 10 (1023 fill types)", 1, true) ~= nil)
    T.ok("G4: naming the floor it satisfies", line10 ~= nil and line10:find("floor 10 satisfied", 1, true) ~= nil)
    T.ok("G5: and it is not the raised line", line10 ~= nil and line10:find("raised to", 1, true) == nil)

    local line11 = callSite(11)
    T.ok("G6: at 11 the already line names 11 and 2047, the width IN FORCE, and still floor 10",
        line11 ~= nil and line11:find("width already 11 (2047 fill types)", 1, true) ~= nil
        and line11:find("floor 10 satisfied", 1, true) ~= nil)

    T.eq("G7: an unreadable manager (applyFloor gave false, nil) prints nothing", SoilFillTypeWidth.loadLine(false, nil), nil)
    T.eq("G8: raised with a non-number width is still nothing, never a malformed line", SoilFillTypeWidth.loadLine(true, nil), nil)
    T.ok("G9: exactly one line per load: neither carries an embedded newline",
        line8 ~= nil and line10 ~= nil and line8:find("\n", 1, true) == nil and line10:find("\n", 1, true) == nil)
    T.ok("G10: both start with the [SoilFertilizer] prefix so a log grep finds them",
        line8 ~= nil and line10 ~= nil and line8:sub(1, 16) == "[SoilFertilizer]" and line10:sub(1, 16) == "[SoilFertilizer]")
    T.ok("G11: the already line says it is the width AT SoilFertilizer load (a later mod can still change it) and that FTE is not required",
        line10 ~= nil and line10:find("at SoilFertilizer load", 1, true) ~= nil
        and line10:find("FillType Extender is not required", 1, true) ~= nil)
    T.ok("G12: loadLine never printed anything itself (pure: main.lua owns the print)", type(SoilFillTypeWidth.loadLine) == "function")
end
