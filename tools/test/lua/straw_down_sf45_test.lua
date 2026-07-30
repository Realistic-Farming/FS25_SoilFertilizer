-- straw_down_sf45_test.lua - STRAW DOWN (SF-45).
--
-- The shortest brief the ground-material programme will ship, and this is its
-- receipt. The design ruled that a SECOND crop must cost a configuration row and a
-- thin rulebook, or the foundation was wrong. So the assertions here are not really
-- about straw - they are about the foundation holding:
--
--   * straw joins the tracked set as ONE ENTRY, and birth/ageing/condition/movement
--     then cover it with no straw-specific machinery anywhere
--   * its spoil count lives in the READER, never in a layer, so the same water
--     history can ruin hay and spare straw
--
-- If a future change adds a straw BRANCH rather than a straw ROW, that re-opens
-- governance by definition - and these tests are where it would first show.
--
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua

DensityValueCompareType = DensityValueCompareType or { BETWEEN = 1, EQUAL = 2 }
DensityCoordType        = DensityCoordType        or { POINT_POINT_POINT = 1 }
g_server = g_server or {}

local POLY = { {x=0,z=0}, {x=10,z=0}, {x=10,z=10} }

-- ── 1. Straw is in the tracked set, and it is one row ─────
T.ok("STRAW is tracked",            MaterialDown.isTrackedMaterial("STRAW"))
T.ok("cut grass is tracked",        MaterialDown.isTrackedMaterial("GRASS_WINDROW"))
T.ok("hay is tracked",              MaterialDown.isTrackedMaterial("DRYGRASS_WINDROW"))
-- Chaff comes off the same combine and is NOT a swath: recording it would age
-- something no member will ever read.
T.ok("chaff is not tracked",        not MaterialDown.isTrackedMaterial("CHAFF"))
T.ok("an unknown fill type is not tracked", not MaterialDown.isTrackedMaterial("SUNFLOWER"))
T.ok("nil is not tracked",          not MaterialDown.isTrackedMaterial(nil))
T.ok("the lookup is case-insensitive", MaterialDown.isTrackedMaterial("straw"))

-- ── 2. Birth is gated by the set, not by a straw branch ───
local function makeDown()
  local writes = {}
  local fake = {
    available = true,
    getLayerEntry = function() return {} end,
    setPolygonWhere = function(_, _, _, value) writes[#writes+1] = value; return true end,
    clearPolygonWhere = function() return true end,
    hasAnyInBand = function() return false end,
    readRawAtWorld = function() return 0 end,
    applyRawDeltaToLayer = function(_, _, d) return d end,
  }
  local md = MaterialDown.new()
  md.armed, md.valueMaps = true, fake
  return md, writes
end

local md, writes = makeDown()
T.ok("straw births", md:noteMaterialAt(POLY, 1, "STRAW"))
T.eq("and lands as born-today like any other material", writes[1], 1)

md, writes = makeDown()
T.ok("an untracked material REFUSES", not md:noteMaterialAt(POLY, 1, "CHAFF"))
T.eq("and writes nothing at all", #writes, 0)

md, writes = makeDown()
T.ok("an unnamed material still records", md:noteMaterialAt(POLY, 1, nil))
T.eq("because the caller made no claim to check", #writes, 1)

md, writes = makeDown()
T.ok("movement is gated the same way", not md:noteMaterialMoved(POLY, POLY, 1, "CHAFF"))
T.eq("and writes nothing", #writes, 0)

-- The foundation is material-blind: straw took the SAME code path, so there is no
-- straw-specific write, ageing rule, or inheritance rule to test. That absence is
-- the point of the brief.
T.eq("straw needed exactly one set entry", MaterialDown.TRACKED_MATERIALS.STRAW, true)

-- ── 3. The spoil count lives in the READER ────────────────
T.eq("straw spoils at 4 rain-days", MaterialWetness.spoilRainDaysFor("STRAW"), 4)
T.eq("hay spoils at 3",             MaterialWetness.spoilRainDaysFor("DRYGRASS_WINDROW"), 3)
T.eq("cut grass spoils at 3",       MaterialWetness.spoilRainDaysFor("GRASS_WINDROW"), 3)
T.eq("a material with no rule returns nil", MaterialWetness.spoilRainDaysFor("CHAFF"), nil)
T.eq("nil returns nil",             MaterialWetness.spoilRainDaysFor(nil), nil)

-- ── 4. THE ASSERTION THAT MATTERS ─────────────────────────
-- The same weather, read through two materials, must give two verdicts. If this
-- ever collapses to one answer, the count has drifted into the layer.
local mw = MaterialWetness.new()
mw.armed = true
for d = 1, 6 do
  -- three wet days out of six
  mw:recordDay(d, d <= 3, "rain", false)
end
mw.appliedThroughDay = 6

local hay   = mw:goingOffVerdict("DRYGRASS_WINDROW", 6)
local straw = mw:goingOffVerdict("STRAW", 6)
T.eq("both verdicts are answerable", hay.status, MaterialWetness.RESULT.OK)
T.eq("three rain-days on the record", hay.waterDays, 3)
T.ok("three rain-days RUIN hay",      hay.spoiled)
T.ok("the same three days SPARE straw", not straw.spoiled)
T.eq("because straw needs a fourth", straw.needed, 4)

mw:recordDay(7, true, "rain", false)
mw.appliedThroughDay = 7
T.ok("a fourth wet day takes straw too", mw:goingOffVerdict("STRAW", 7).spoiled)

-- ── 5. Refusal honesty on a short record ──────────────────
-- A confident "not spoiled" built on three remembered days out of twenty is a lie.
local short = mw:goingOffVerdict("STRAW", 20)
T.eq("a window the record cannot cover REFUSES", short.status, MaterialWetness.RESULT.REFUSAL)
T.ok("and says how far it actually reaches", short.known < short.window)
T.eq("a material with no spoil rule refuses too",
     mw:goingOffVerdict("CHAFF", 6).status, MaterialWetness.RESULT.REFUSAL)
