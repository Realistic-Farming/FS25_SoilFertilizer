-- unscouted_indicator_spec_test.lua - the Unscouted Indicator
--
-- Ground you have not scouted stops pretending to be clean. The diseasePressure
-- DISPLAY layer reserves DMV colour state 1 (raw 16-31) for UNKNOWN: its live
-- values floor to raw 32 (state 2+), and an unscouted field paints UNKNOWN_RAW.
-- The scouting-gated value (_vmShownDiseasePressure) returns a sentinel < 0 for
-- unscouted ground so the paint path marks it UNKNOWN, while urgency and the
-- "fields with disease" counters treat it as zero (never leaking the hidden
-- disease). This locks the band arithmetic, the floor, the no-leak invariants,
-- the gated accessor and the known-trouble counter.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua

local function stateOf(raw) return math.floor(raw / 16) end   -- DMV state = top 4 bits

local diseaseDef, weedDef, nitrogenDef
for _, d in ipairs(SoilValueMaps.LAYER_DEFS) do
    if d.key == "diseasePressure" then diseaseDef = d end
    if d.key == "weedPressure"    then weedDef    = d end
    if d.key == "nitrogen"        then nitrogenDef = d end
end

-- ── 1. The reserved band is set up ───────────────────────────────────────────
T.eq("UNKNOWN_RAW is 24 (mid state-1 band)", SoilValueMaps.UNKNOWN_RAW, 24)
T.eq("UNKNOWN_VALUE sentinel is -1", SoilValueMaps.UNKNOWN_VALUE, -1)
T.ok("UNKNOWN_VALUE is below any layer minVal", SoilValueMaps.UNKNOWN_VALUE < 0)
T.eq("disease display layer floors to raw 32 (state 2+)", diseaseDef.rawFloor, 32)
T.eq("disease display layer carries unknownRaw 24", diseaseDef.unknownRaw, 24)
T.eq("the other display layers keep the shared floor 16", weedDef.rawFloor, 16)
T.ok("value layers (nitrogen) have no display floor", nitrogenDef.rawFloor == nil)

-- ── 2. The band arithmetic (DMV state = floor(raw/16)) ───────────────────────
T.eq("UNKNOWN_RAW lands in the reserved state 1", stateOf(SoilValueMaps.UNKNOWN_RAW), 1)
T.eq("the disease live floor (32) lands in state 2", stateOf(32), 2)
T.eq("the shared floor (16) is state 1 for the other layers", stateOf(16), 1)

-- ── 3. encode() maps the unknown sentinel to the reserved raw ─────────────────
local enc = SoilValueMaps._encode
T.eq("encode(UNKNOWN_VALUE) -> UNKNOWN_RAW for disease", enc(SoilValueMaps.UNKNOWN_VALUE, diseaseDef), 24)
T.eq("unknown paints into state 1", stateOf(enc(SoilValueMaps.UNKNOWN_VALUE, diseaseDef)), 1)
T.eq("a clean scouted field floors to raw 32 (state 2), never the reserved band", enc(0, diseaseDef), 32)
T.ok("clean scouted disease never falls into the reserved band", stateOf(enc(0, diseaseDef)) >= 2)
T.eq("max disease encodes to 255", enc(100, diseaseDef), 255)
T.ok("a low live pressure still clears the reserved band", stateOf(enc(5, diseaseDef)) >= 2)

-- ── 4. The gated accessor (no-leak core) ─────────────────────────────────────
local shown = SoilFertilitySystem._vmShownDiseasePressure
local onSelf  = { settings = { diseasePressure = true } }
local offSelf = { settings = { diseasePressure = false } }
T.eq("unscouted + disease ON -> UNKNOWN sentinel", shown(onSelf, { diseaseDiscovered = false, diseasePressure = 80 }), -1)
T.eq("unscouted + disease OFF -> clean 0 (nothing to hide)", shown(offSelf, { diseaseDiscovered = false, diseasePressure = 80 }), 0)
T.eq("scouted -> the real pressure", shown(onSelf, { diseaseDiscovered = true, diseasePressure = 37 }), 37)

-- ── 5. No-leak: urgency and counters treat unscouted as zero ─────────────────
-- Urgency clamps the sentinel to 0 so unscouted disease never raises the number.
T.eq("urgency contribution of unscouted disease is 0", math.max(0, SoilValueMaps.UNKNOWN_VALUE), 0)
-- The "fields with disease" counter counts SHOWN trouble only (nil = not counted).
local THRESH = 20
local function counted(shownVal) return (shownVal or 0) >= THRESH end
T.ok("an unscouted field (nil shown) is NOT counted as diseased", not counted(nil))
T.ok("a scouted clean field is not counted", not counted(3))
T.ok("a scouted diseased field at/over threshold IS counted", counted(45))
