-- FILL TYPE INDEX WIDTH FLOOR: absorbing FillType Extender's capability.
--
-- We raise FillTypeManager.SEND_NUM_BITS from the engine default of 8 to 9 so a
-- player can drop FTE. The whole risk of this change sits in one word: it must
-- RAISE and never SET, because Realistic Livestock raises the same constant to 10
-- at its own file load, and sourcing order decides who runs first. An
-- unconditional assignment would truncate a width RL had already established, and
-- the symptom would be a multiplayer desync on a stranger's server rather than
-- anything visible on the machine that caused it.
--
-- NOT A FIX FOR OUR FILL TYPE ERRORS, and the bar says so because the code says
-- so. That premise was tested and is false: FTE was loaded and active at width 9
-- while this mod emitted those errors, and the engine's own cap error
-- (FillTypeManager.lua:206) appears zero times across six sessions. The real cause
-- was the deferred-init defect fixed in #970.
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
    T.eq("A1: the floor is 9, matching FillType Extender exactly", FLOOR, 9)

    local m = manager(DEFAULT_BITS)
    local raised, width = SoilFillTypeWidth.applyFloor(m)
    T.eq("A2: the engine default of 8 is raised", raised, true)
    T.eq("A3: to exactly 9", m.SEND_NUM_BITS, 9)
    T.eq("A4: and the new width is reported back", width, 9)
end

-- ── GROUP B: it must never LOWER, which is the whole risk ────────────────────
do
    -- Realistic Livestock sourced first and set 10.
    local m = manager(RL_BITS)
    local raised, width = SoilFillTypeWidth.applyFloor(m)
    T.eq("B1: a width of 10 is NOT lowered to 9", m.SEND_NUM_BITS, 10)
    T.eq("B2: and the call reports it did not raise", raised, false)
    T.eq("B3: reporting the width actually in force, not our floor", width, 10)

    -- Anything above the floor is left alone, not just 10.
    for _, bits in ipairs({ 9, 10, 11, 12, 16 }) do
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
    T.eq("C4: and the width is still 9, not 10 or 18", m.SEND_NUM_BITS, 9)
    T.eq("C5: the second call reports the width in force", secondWidth, 9)
end

-- ── GROUP D: the width is read LIVE, never captured ──────────────────────────
-- If applyFloor cached the width it first saw, a later call would decide against
-- a number that no longer exists. Other mods write this constant during sourcing,
-- so that is a real sequence and not a hypothetical one.
do
    local m = manager(DEFAULT_BITS)
    SoilFillTypeWidth.applyFloor(m)             -- now 9
    m.SEND_NUM_BITS = RL_BITS                   -- RL sources after us and raises to 10
    local raised = SoilFillTypeWidth.applyFloor(m)
    T.eq("D1: a later call sees 10, not the 8 it first saw", raised, false)
    T.eq("D2: and leaves RL's width alone", m.SEND_NUM_BITS, 10)

    -- The reverse direction: something lowers it back below the floor.
    m.SEND_NUM_BITS = DEFAULT_BITS
    local raisedAgain = SoilFillTypeWidth.applyFloor(m)
    T.eq("D3: and it raises again when the live value is below the floor", raisedAgain, true)
    T.eq("D4: back to 9", m.SEND_NUM_BITS, 9)
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
    T.eq("F2: at our floor, 511", SoilFillTypeWidth.maxFillTypes(9), 511)
    T.eq("F3: at Realistic Livestock's 10, 1023", SoilFillTypeWidth.maxFillTypes(10), 1023)

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
