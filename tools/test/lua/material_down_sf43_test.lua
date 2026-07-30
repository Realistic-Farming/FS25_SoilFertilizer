-- material_down_sf43_test.lua - MATERIAL DOWN (SF-43).
--
-- The layer records HOW MANY DAYS cut material has lain at each spot. The one
-- direction the design forbids is age reading FRESHER than it is, so most of what
-- is asserted here is a laundering path staying closed:
--   * the daily tick is ONE engine call and never touches bare ground or the ceiling
--   * a catch-up saturates the band the add's guard window has to exclude, so a long
--     sleep cannot leave a permanently frozen strip below the ceiling
--   * the fabrication fence refuses rather than falling back to the block-walk
--   * movement inheritance takes the oldest band's FLOOR (a real pixel's age), with
--     the ceiling probed first so a refusal propagates instead of being averaged
--   * birth writes only where there is no record, so nothing can lower an age
--   * the watermark is idempotent and merges forward, never backward
--
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua

DensityValueCompareType = DensityValueCompareType or { BETWEEN = 1, EQUAL = 2 }
DensityCoordType        = DensityCoordType        or { POINT_POINT_POINT = 1 }
g_server = g_server or {}

-- ── A store with a recording modifier ─────────────────────
local function makeStore()
  local calls, band = {}, {}
  local filter = {
    setValueCompareParams = function(_, _, low, high) band.low, band.high = low, high end,
  }
  local modifier = {
    setParallelogramWorldCoords  = function() end,
    clearPolygonPoints           = function() end,
    addPolygonPointWorldCoords   = function() end,
    executeAdd = function(_, delta) calls[#calls + 1] = { op = "add", delta = delta, low = band.low, high = band.high } end,
    executeSet = function(_, value) calls[#calls + 1] = { op = "set", value = value, low = band.low, high = band.high } end,
    executeGet = function() return 0, 0, 0 end,
  }
  local def
  for _, d in ipairs(SoilValueMaps.LAYER_DEFS) do
    if d.key == "materialAge" then def = d end
  end
  local vm = SoilValueMaps.new()
  vm.available     = true
  vm.hasExecuteAdd = true
  vm.terrainSize   = 2048
  vm.resolution    = 1024
  vm.layers        = { materialAge = { bvm = 1, modifier = modifier, filter = filter, def = def } }
  return vm, calls, def
end

-- ── 1. The layer definition ───────────────────────────────
local _, _, def = makeStore()
T.ok("materialAge def exists", def ~= nil)
T.eq("minVal 0", def.minVal, 0)
-- 254 is load-bearing: RAW_SPAN is 254, so unitsPerRaw is exactly 1 and one day is
-- one raw step with no quantisation error to accumulate over a season.
T.eq("maxVal 254 makes one raw step exactly one day", def.maxVal, SoilValueMaps.RAW_SPAN)
T.eq("no rawFloor (this layer never renders)", def.rawFloor, nil)
T.eq("no unknownRaw (its refusal is the ceiling, not a band)", def.unknownRaw, nil)
T.eq("serverOnly couples asks 4+5 in one flag", def.serverOnly, true)

-- ── 2. The ordinary daily tick is ONE engine call ─────────
local vm, calls = makeStore()
local applied = vm:applyRawDeltaToLayer("materialAge", 1, 1, 254)
T.eq("tick applies one raw step", applied, 1)
T.eq("ordinary tick is exactly one engine call", #calls, 1)
T.eq("that call is an add", calls[1].op, "add")
T.eq("add delta is 1", calls[1].delta, 1)
T.eq("guard window excludes raw 0 (bare ground never ages into a record)", calls[1].low, 1)
T.eq("guard window excludes the ceiling (a saturated pixel stops counting)", calls[1].high, 254)

-- ── 3. Catch-up saturates what the add window must exclude ─
vm, calls = makeStore()
vm:applyRawDeltaToLayer("materialAge", 30, 1, 254)
T.eq("catch-up is two calls, flat in area", #calls, 2)
T.eq("first is the add", calls[1].op, "add")
T.eq("add delta is the boundaries crossed", calls[1].delta, 30)
T.eq("add window stops short so nothing wraps past the ceiling", calls[1].high, 225)
T.eq("second is the saturating set", calls[2].op, "set")
T.eq("saturating pass writes the ceiling", calls[2].value, 255)
-- THE BUG THIS CLOSES: at delta 30 a pixel sitting at 230 is outside the add window
-- on this tick and on every tick after it. Without pass 2 that band freezes forever.
T.eq("saturating band starts where the add window ended", calls[2].low, 226)
T.eq("saturating band stops below the ceiling", calls[2].high, 254)

-- ── 4. An unrepresentable sleep clamps rather than wraps ───
vm, calls = makeStore()
vm:applyRawDeltaToLayer("materialAge", 5000, 1, 254)
T.eq("delta clamps to the raw span", calls[1].delta, SoilValueMaps.RAW_SPAN - 1)

-- ── 5. THE FABRICATION FENCE ──────────────────────────────
-- The block-walk fallback point-samples a block centre and executeSets the whole
-- 16 m block UNFILTERED, which births records on bare ground. On an age layer that
-- is fabrication, so the store must refuse instead. Honestly inert beats inventing.
vm, calls = makeStore()
vm.hasExecuteAdd = false
local refused = vm:applyRawDeltaToLayer("materialAge", 1, 1, 254)
T.eq("no executeAdd -> REFUSES (nil, not a silent 0)", refused, nil)
T.eq("and writes nothing at all", #calls, 0)

-- ── 6. Publication bands ──────────────────────────────────
T.eq("day 0 is fresh",      MaterialDown.bandForDays(0),  "fresh")
T.eq("day 1 is fresh",      MaterialDown.bandForDays(1),  "fresh")
T.eq("day 2 is recent",     MaterialDown.bandForDays(2),  "recent")
T.eq("day 7 is week",       MaterialDown.bandForDays(7),  "week")
T.eq("day 14 is ageing",    MaterialDown.bandForDays(14), "ageing")
T.eq("day 60 is veryOld",   MaterialDown.bandForDays(60), "veryOld")

-- ── A MaterialDown on a scriptable fake store ─────────────
local function makeSystem(present)
  local writes, probes = {}, {}
  local rawAt = 0
  local fake = {
    available = true,
    getLayerEntry = function() return {} end,
    applyRawDeltaToLayer = function(_, _, delta) writes[#writes + 1] = { op = "add", delta = delta }; return delta end,
    setPolygonWhere = function(_, _, _, value, low, high)
      writes[#writes + 1] = { op = "set", value = value, low = low, high = high }
      return true
    end,
    clearPolygonWhere = function(_, _, _, low, high)
      writes[#writes + 1] = { op = "clear", low = low, high = high }
      return true
    end,
    hasAnyInBand = function(_, _, _, low, high)
      probes[#probes + 1] = { low = low, high = high }
      for _, r in ipairs(present or {}) do
        if r >= low and r <= high then return true end
      end
      return false
    end,
    readRawAtWorld = function() return rawAt end,
  }
  local md = MaterialDown.new()
  md.armed     = true
  md.valueMaps = fake
  return md, writes, probes, function(r) rawAt = r end
end

-- ── 7. Publication: the two named neutrals ────────────────
local md, _, _, setRaw = makeSystem()
setRaw(0)
T.eq("raw 0 is NO RECORD, never day 0", md:getDaysDownAt(0, 0).status, MaterialDown.RESULT.NO_RECORD)
setRaw(255)
T.eq("raw 255 is the CEILING refusal, never a value", md:getDaysDownAt(0, 0).status, MaterialDown.RESULT.CEILING)
setRaw(1)
local r = md:getDaysDownAt(0, 0)
T.eq("raw 1 reads OK", r.status, MaterialDown.RESULT.OK)
T.eq("raw 1 is born today = 0 full days down", r.days, 0)
setRaw(8)
r = md:getDaysDownAt(0, 0)
T.eq("raw 8 is 7 days down", r.days, 7)
T.eq("and bands as a week", r.band, "week")

-- ── 8. The watermark is idempotent ────────────────────────
-- The scheduler retries a failed accrual with the SAME boundariesCrossed, so a
-- throw after the add would otherwise re-add across the whole map.
local writes
md, writes = makeSystem()
md:onAgeTick({ monotonicDay = 10, boundariesCrossed = 1 })
md:onAgeTick({ monotonicDay = 10, boundariesCrossed = 1 })
T.eq("the same day settles exactly once", #writes, 1)
md:onAgeTick({ monotonicDay = 11, boundariesCrossed = 1 })
T.eq("the next day does settle", #writes, 2)
md:onAgeTick({ monotonicDay = 9, boundariesCrossed = 1 })
T.eq("a day going backwards is a no-op", #writes, 2)

-- ── 9. Merge-never-replace on load ────────────────────────
-- StateLedger omits a block when serialize fails and cannot tell that from a brand
-- new save, so a replace-on-nil would wipe the watermark after ONE bad save - and a
-- lost watermark re-ages the entire map on the next tick.
md = makeSystem()
md.ageAppliedThroughDay = 40
md:deserialize({ ageAppliedThroughDay = 12 })
T.eq("an older saved watermark never moves it backwards", md.ageAppliedThroughDay, 40)
md:deserialize({ ageAppliedThroughDay = 55 })
T.eq("a further-on watermark is adopted", md.ageAppliedThroughDay, 55)
T.eq("a nil block changes nothing", md:deserialize(nil), false)
T.eq("and leaves the watermark intact", md.ageAppliedThroughDay, 55)

-- ── 10. Movement inheritance: the ceiling propagates ───────
local probes
md, writes, probes = makeSystem({ 255, 3 })
md:noteMaterialMoved({ {x=0,z=0}, {x=1,z=0}, {x=1,z=1} }, { {x=5,z=5}, {x=6,z=5}, {x=6,z=6} })
T.eq("the ceiling band is probed FIRST", probes[1].low, 255)
T.eq("a source at the ceiling makes the destination refuse too", writes[1].value, 255)

-- ── 11. Movement inheritance: the oldest band's floor ──────
-- Raking a week-old row must not make it read fresh. The inherited value is the
-- oldest present band's FLOOR, which is an age a real pixel in the source held -
-- never an average, which would invent an age no pixel ever had.
md, writes = makeSystem({ 15, 2 })
md:noteMaterialMoved({ {x=0,z=0}, {x=1,z=0}, {x=1,z=1} }, { {x=5,z=5}, {x=6,z=5}, {x=6,z=6} })
T.eq("inherits the oldest band floor (raw 15 = 14 days)", writes[1].value, 15)
T.ok("and is never the average of 15 and 2", writes[1].value ~= 8)

-- ── 12. Birth and merge-on-destination ────────────────────
md, writes = makeSystem({})
md:noteMaterialAt({ {x=0,z=0}, {x=1,z=0}, {x=1,z=1} }, nil)
T.eq("birth dates the pixel today", writes[1].value, 1)
-- The [0,0] band IS the merge rule: a pixel that already carries an age is outside
-- the filter, so arriving material can never lower an existing age, and there is no
-- read-compare-write for the engine to race.
T.eq("birth writes only where there is NO record (low)",  writes[1].low,  0)
T.eq("birth writes only where there is NO record (high)", writes[1].high, 0)

-- ── 13. Clearing never touches raw 0 ──────────────────────
-- No periodic wipe exists anywhere in this system: clearing to raw 0 lets birth
-- re-date the pixel as today, which launders age in the forbidden direction.
md, writes = makeSystem({})
md:noteMaterialGone({ {x=0,z=0}, {x=1,z=0}, {x=1,z=1} })
T.eq("clear targets written records only", writes[1].low, 1)
T.eq("clear covers up to and including the ceiling", writes[1].high, 255)

-- ── 14. A refused store call stands the system down ───────
md = makeSystem({})
md.valueMaps.setPolygonWhere = function() return false end
md:noteMaterialAt({ {x=0,z=0}, {x=1,z=0}, {x=1,z=1} }, nil)
T.eq("a refusal makes the system inert for the session", md:isArmed(), false)
