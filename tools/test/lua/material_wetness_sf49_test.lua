-- material_wetness_sf49_test.lua - WHAT THE SKY DID (SF-49).
--
-- The sibling answers how LONG material has lain; this one answers what CONDITION
-- the sky left it in. Most of what is pinned here is a silent-failure path:
--   * phase bounds ENCODED before they reach the filter - passing percentages raw
--     puts the boundaries at ~23 and ~15 percent while every call-count test passes
--   * the overflow guard INTERSECTED with the caller band, never replaced, and the
--     edge pass never writing outside the band the caller asked for
--   * a negative delta flooring at the caller's floor, so a drying step cannot walk
--     a low pixel down into the reserved sentinel band and turn a value into a refusal
--   * the sentinel excluded from the aggregate read - it decodes to bone-dry and
--     would pull a mixed pickup toward FIT
--   * the Celsius-to-Fahrenheit bridge, and an EMC table clamped, never extrapolated
--   * refusal propagation, and the season basis that silently dries out spring
--
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua

DensityValueCompareType = DensityValueCompareType or { BETWEEN = 1, EQUAL = 2 }
DensityCoordType        = DensityCoordType        or { POINT_POINT_POINT = 1 }
g_server = g_server or {}

local POLY = { {x=0,z=0}, {x=10,z=0}, {x=10,z=10}, {x=0,z=10} }

local function makeStore()
  local calls, band = {}, {}
  local filter = {
    setValueCompareParams = function(_, _, low, high) band.low, band.high = low, high end,
  }
  local modifier = {
    setParallelogramWorldCoords = function() end,
    clearPolygonPoints          = function() end,
    addPolygonPointWorldCoords  = function() end,
    executeAdd = function(_, delta) calls[#calls+1] = { op="add", delta=delta, low=band.low, high=band.high } end,
    executeSet = function(_, value) calls[#calls+1] = { op="set", value=value, low=band.low, high=band.high } end,
    executeGet = function() return 0, 0, 0 end,
  }
  local def
  for _, d in ipairs(SoilValueMaps.LAYER_DEFS) do
    if d.key == "materialWetness" then def = d end
  end
  local vm = SoilValueMaps.new()
  vm.available, vm.hasExecuteAdd = true, true
  vm.terrainSize, vm.resolution  = 2048, 1024
  vm.layers = { materialWetness = { bvm=1, modifier=modifier, filter=filter, def=def } }
  return vm, calls, def
end

-- ── 1. The layer definition and its sentinel ──────────────
local _, _, def = makeStore()
T.ok("materialWetness def exists", def ~= nil)
T.eq("percent wet basis, 0-100", def.maxVal, 100)
T.eq("serverOnly like its sibling", def.serverOnly, true)
-- The REFUSAL state reuses the store's OWN shipped sentinel pattern rather than a
-- parallel mechanism, so nothing can decode a refusal as an ordinary reading.
T.eq("sentinel reuses the shipped UNKNOWN_RAW", def.unknownRaw, SoilValueMaps.UNKNOWN_RAW)
T.eq("rawFloor keeps real readings above the sentinel band", def.rawFloor, 32)

-- ── 2. ENCODE THE BOUNDS BEFORE THEY REACH THE FILTER ─────
-- The exact numbers the brief cites. Getting this wrong puts the phase boundaries
-- at roughly 23 and 15 percent, and every call-count assertion still passes.
T.eq("60 percent encodes to raw 153", MaterialWetness.pctToRaw(60), 153)
T.eq("40 percent encodes to raw 103", MaterialWetness.pctToRaw(40), 103)
T.eq("100 percent is the top raw",    MaterialWetness.pctToRaw(100), 255)
T.eq("0 percent floors above the sentinel band", MaterialWetness.pctToRaw(0), 32)
T.ok("a raw inside the sentinel band is NOT a percentage", MaterialWetness.rawToPct(24) == nil)
T.ok("raw 0 is not a percentage either", MaterialWetness.rawToPct(0) == nil)
T.near("raw 153 decodes back to 60 percent", MaterialWetness.rawToPct(153), 60, 0.4)

-- The ruled phase drops, in raw steps.
T.eq("25 points is 64 raw steps", MaterialWetness.pointsToRawDelta(25), 64)
T.eq("18 points is 46 raw steps", MaterialWetness.pointsToRawDelta(18), 46)
T.eq("6 points is 15 raw steps",  MaterialWetness.pointsToRawDelta(6),  15)

-- ── 3. The guard is INTERSECTED, never replaced ───────────
local vm, calls = makeStore()
vm:applyRawDeltaToPolygonBand("materialWetness", POLY, 30, 100, 254)
T.eq("the caller's LOW bound is preserved exactly", calls[1].low, 100)
-- Silently widening the band back to the safe window would touch pixels the phase
-- table deliberately excluded.
T.eq("the HIGH bound shrinks to the safe bound", calls[1].high, 225)

-- ── 4. The edge pass never writes outside the caller band ──
vm, calls = makeStore()
vm:applyRawDeltaToPolygonBand("materialWetness", POLY, 30, 100, 240)
local edge = calls[2]
T.eq("edge pass exists for an overflowing top", edge.op, "set")
T.ok("edge low is inside the caller band", edge.low >= 100)
T.ok("edge high never exceeds the caller band", edge.high <= 240)

-- ── 5. A NEGATIVE delta floors where the caller says ──────
-- This is the sentinel protection: a bound-water step on a low pixel must park at
-- the floor, not walk down into the reserved band and become a REFUSAL.
vm, calls = makeStore()
vm:applyRawDeltaToPolygonBand("materialWetness", POLY, -50, 32, 255, { floorTo = 40 })
local addCall, setCall
for _, c in ipairs(calls) do
  if c.op == "add" then addCall = c else setCall = c end
end
T.eq("the add is a subtraction", addCall.delta, -50)
T.ok("the add only touches pixels with room to fall", addCall.low >= 51)
T.eq("everything below that is floored, not wrapped", setCall.value, 40)
T.ok("and the floor pass stays inside the caller band", setCall.low >= 32)

-- ── 6. A band outside the layer's raw range is a NO-OP ────
vm, calls = makeStore()
local applied = vm:applyRawDeltaToPolygonBand("materialWetness", POLY, 10, 300, 400)
T.eq("out-of-range band writes nothing", #calls, 0)
T.eq("and reports nothing applied", applied, 0)

-- ── 7. The fabrication fence carries over ─────────────────
vm, calls = makeStore()
vm.hasExecuteAdd = false
T.eq("no executeAdd -> REFUSES", vm:applyRawDeltaToPolygonBand("materialWetness", POLY, 10, 32, 255), nil)
T.eq("and writes nothing", #calls, 0)

-- ── 8. THE UNIT BRIDGE ────────────────────────────────────
-- The engine reports Celsius; the EMC table is indexed in Fahrenheit. A Celsius
-- value read as Fahrenheit lands in the wrong row and nothing complains.
T.near("0 C is 32 F",   MaterialWetness.celsiusToFahrenheit(0),   32,  1e-9)
T.near("100 C is 212 F", MaterialWetness.celsiusToFahrenheit(100), 212, 1e-9)
T.near("20 C is 68 F",  MaterialWetness.celsiusToFahrenheit(20),  68,  1e-9)

-- ── 9. EMC is CLAMPED at the table edges, never extrapolated ─
local emcCold = MaterialWetness.emcFor(60, -40)   -- far below the table's 40 F row
local emcHot  = MaterialWetness.emcFor(60, 200)   -- far above its 100 F row
local emcEdgeLow  = MaterialWetness.emcFor(60, (40 - 32) * 5 / 9)    -- exactly 40 F
local emcEdgeHigh = MaterialWetness.emcFor(60, (100 - 32) * 5 / 9)   -- exactly 100 F
T.near("below the table pins to the edge row", emcCold, emcEdgeLow,  1e-6)
T.near("above the table pins to the edge row", emcHot,  emcEdgeHigh, 1e-6)
T.ok("humidity below the table pins too", MaterialWetness.emcFor(0, 20) == MaterialWetness.emcFor(20, 20))
T.ok("higher humidity means a wetter floor",
     MaterialWetness.emcFor(90, 20) > MaterialWetness.emcFor(20, 20))
T.ok("warmer air means a drier floor",
     MaterialWetness.emcFor(60, 5) > MaterialWetness.emcFor(60, 35))

-- ── 10. The composite weather multiplier ──────────────────
local W = MaterialWetness.WEATHER_MULT
T.near("clear sky over dry ground dries fastest",
       MaterialWetness.weatherMultiplier(0, 0), W.high, 1e-9)
T.near("overcast over saturated ground is slowest",
       MaterialWetness.weatherMultiplier(1, 1), W.low, 1e-9)
T.near("the midpoint is neutral", MaterialWetness.weatherMultiplier(0.5, 0.5), W.mid, 1e-9)
T.ok("the spread is about threefold", W.high / W.low > 2.5 and W.high / W.low < 3.5)

-- ── 11. Condition bands ───────────────────────────────────
T.eq("70 percent is soaked", MaterialWetness.bandForPct(70), "soaked")
T.eq("45 percent is damp",   MaterialWetness.bandForPct(45), "damp")
T.eq("30 percent is curing", MaterialWetness.bandForPct(30), "curing")
T.eq("15 percent is fit",    MaterialWetness.bandForPct(15), "fit")

-- ── A wetness system on a scriptable fake store ───────────
local function makeSystem(opts)
  opts = opts or {}
  local fake = {
    available = true,
    getLayerEntry = function() return {} end,
    applyRawDeltaToPolygonBand = function() return 1 end,
    setPolygonWhere = function() return true end,
    hasAnyInBand = function(_, _, _, low, high)
      if opts.sentinel and low < 32 then return true end
      if low >= 32 then return opts.present ~= false end
      return false
    end,
    readAverageRawInBand = function() return opts.avgRaw or 153 end,
  }
  local mw = MaterialWetness.new()
  mw.armed, mw.valueMaps = true, fake
  return mw
end

-- ── 12. The read refuses rather than guessing ─────────────
local mw = makeSystem()
local R = MaterialWetness.RESULT
-- Quantity is NON-OPTIONAL: the engine hands it back and every base-game consumer
-- keeps it, so its absence is a caller bug, not a reason to invent an answer.
T.eq("nil quantity REFUSES",      mw:readCondition(POLY, nil).status, R.REFUSAL)
T.eq("zero quantity REFUSES",     mw:readCondition(POLY, 0).status,   R.REFUSAL)
T.eq("negative quantity REFUSES", mw:readCondition(POLY, -5).status,  R.REFUSAL)

local wet = makeSystem({ avgRaw = 180 })
local ok = wet:readCondition(POLY, 1200)
T.eq("a real pickup reads OK", ok.status, R.OK)
T.near("and reports its percentage", ok.pct, 70.5, 0.5)
T.eq("banded for the members", ok.band, "soaked")

-- The quantisation edge, pinned deliberately rather than left to be discovered.
-- 8 bits over 0-100 means one raw step is ~0.394 percent, and encode rounds to the
-- nearest step: 60 percent encodes to raw 153, which decodes back to 59.84. A value
-- written AT a band boundary can therefore land one band below it. That is inherent
-- to the encoding and harmless at these band widths, but it is real.
T.near("raw 153 decodes just under 60", MaterialWetness.rawToPct(153), 59.84, 0.02)
T.eq("so a boundary value bands one below", mw:readCondition(POLY, 1200).band, "damp")

-- ── 13. Refusal PROPAGATES; it does not average away ──────
-- The sentinel decodes to roughly nine percent - bone dry - so summing it into an
-- average would pull a mixed pickup toward FIT. One refusing cell refuses the lot.
local refusing = makeSystem({ sentinel = true })
T.eq("any refusing cell makes the whole answer a refusal",
     refusing:readCondition(POLY, 1200).status, R.REFUSAL)

local empty = makeSystem({ present = false })
T.eq("no material is its own answer, not a refusal",
     empty:readCondition(POLY, 1200).status, R.NO_MATERIAL)

-- ── 14. The Water Record freezes verdicts and stays bounded ─
mw = makeSystem()
mw:recordDay(5, true, "rain", false)
mw:recordDay(5, false, "none", false)   -- a second verdict for the same day
T.ok("a recorded verdict is FROZEN, never recomputed", mw.waterRecord[5].water == true)
mw.appliedThroughDay = 5
local count, known = mw:waterDaysInLast(6)
T.eq("one wet day in the window", count, 1)
T.eq("and only one day is actually known", known, 1)

for d = 1, MaterialWetness.WATER_RECORD_DAYS + 20 do mw:recordDay(100 + d, true, "rain", false) end
T.ok("the ring stays bounded", #mw.recordDays <= MaterialWetness.WATER_RECORD_DAYS)

-- ── 15. Merge-never-replace, same reason as the sibling ───
mw = makeSystem()
mw.appliedThroughDay = 40
mw:deserialize({ appliedThroughDay = 12 })
T.eq("an older cursor never moves it backwards", mw.appliedThroughDay, 40)
mw:deserialize({ appliedThroughDay = 55 })
T.eq("a further-on cursor is adopted", mw.appliedThroughDay, 55)
T.eq("a nil block changes nothing", mw:deserialize(nil), false)

-- ── 16. THE SEASON BASIS ──────────────────────────────────
-- getClimate rejects anything outside 1-4, and SeasonalCropStress normalises the
-- OTHER way for its own tables. Feeding SCS's spring (0) in here would return nil
-- every time and give a permanently dry spring that nothing would report.
mw = makeSystem()
T.ok("season 0 is rejected, not silently used", mw:readClimate(0) == nil)
T.ok("season 5 is rejected", mw:readClimate(5) == nil)
T.ok("a non-number season is rejected", mw:readClimate("spring") == nil)
