-- yard_ladder_sf46_test.lua - THE YARD LADDER (SF-46).
--
-- The member that holds a per-bale CONDITION row, walks it up a shelter ladder once
-- per day, and ends it in one condemnation event. These assertions are written the
-- house way: they pin the failures that would otherwise be SILENT, not the happy path.
--
-- Four of them exist because the first cut of this member got them wrong, and every
-- one of those four would have shipped green under a call-count test:
--
--   * THE TOKEN IS NOT THE NODE ID. Scenegraph node ids do not survive a save. A
--     nodeId token orphans every row on reload, hands each bale a fresh condition,
--     and leaves the dead rows in the savegame forever. Nothing in game would have
--     looked wrong for the first hour.
--   * NO TRANSIENT REACHES THE LEDGER. MaterialDown:serialize copies records
--     wholesale, so a live Bale reference parked on a row goes to the serializer.
--   * BIRTH WETNESS IS NOT LADDER UNITS. Seeding condition from the seasonal stub
--     would open a winter bale at 75 of a 100 ceiling and blow both ruled horizons.
--   * A REFUSED READ IS NOT A VALUE. It falls to the stub; it never becomes a zero.
--
-- The horizon assertions at the end are the balance guard: if someone retunes a rate
-- without retuning the thresholds, the ruled "about a wet week / about 2.5 wet weeks"
-- stops being true, and that is the assertion that says so.
--
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/YardLadder.lua

DensityValueCompareType = DensityValueCompareType or { BETWEEN = 1, EQUAL = 2 }
DensityCoordType        = DensityCoordType        or { POINT_POINT_POINT = 1 }
g_server = g_server or {}
function entityExists(_node) return true end

-- ── Fixtures ──────────────────────────────────────────────

local function makeDown()
  local fake = {
    available = true,
    getLayerEntry = function() return {} end,
    setPolygonWhere = function() return true end,
    clearPolygonWhere = function() return true end,
    hasAnyInBand = function() return false end,
    readRawAtWorld = function() return 0 end,
    applyRawDeltaToLayer = function(_, _, d) return d end,
  }
  local md = MaterialDown.new()
  md.armed, md.valueMaps = true, fake
  return md
end

-- A stand-in sky member. `wetDays` decides the day verdict; `read` decides what the
-- birth condition read answers.
local function makeSky(opts)
  opts = opts or {}
  return {
    isArmed = function() return true end,
    readCondition = function(_self, verts, litres)
      opts.sawLitres = litres
      opts.sawVerts  = verts
      -- Default: baled FIT, so a fixture bale opens at zero condition and the ladder
      -- sections below measure the ladder rather than the birth handicap.
      return opts.read or { status = MaterialWetness.RESULT.OK, pct = 15 }
    end,
    -- Mirrors the real contract: "how many of the last n days brought water, and how
    -- many of those n do I have a record for". It must scale with n, or a span test
    -- silently measures the fixture instead of the code.
    waterDaysInLast = function(_self, n, _day)
      n = math.max(1, math.floor(tonumber(n) or 1))
      if opts.known == 0 then return 0, 0 end
      return (opts.wet and n or 0), n
    end,
  }
end

local function makeHay() return { isArmed = function() return true end } end

local function makeLadder(skyOpts)
  local md  = makeDown()
  local sky = makeSky(skyOpts)
  local yl  = YardLadder.new()
  yl:arm(md, sky, makeHay())
  return yl, md, sky
end

-- Outdoors unless a test says otherwise.
MaterialWetness.isSheltered = function() return false end

-- ── 1. The token is opaque and minted, never the node id ──
-- The bug this pins: a nodeId-derived token silently orphans every row on reload.

local yl, md = makeLadder()
yl:onBaleCreated(4242, { getFillLevel = function() return 100 end }, "STRAW", 100, 1, 100)

local seenToken, seenRow
md:enumerateObjects(function(t, r) seenToken, seenRow = t, r end)

T.ok("a birth creates exactly one row", seenToken ~= nil)
T.ok("the token does not contain the node id", seenToken:find("4242") == nil)
T.eq("the token is the minted first serial", seenToken, "yl_1")

-- ── 2. No transient ever reaches the ledger record ────────
-- MaterialDown:serialize copies records wholesale, so anything on the row is saved.

T.eq("the row holds no live bale reference", seenRow._baleObject, nil)
T.eq("the row holds no bale reference under any name", seenRow.bale, nil)
T.eq("the row holds no node id", seenRow.nodeId, nil)
T.eq("the row holds no sampled position", seenRow.lastPosX, nil)
for k, v in pairs(seenRow) do
  T.ok("row field '" .. k .. "' is plain data", type(v) ~= "userdata" and type(v) ~= "function")
end

-- ── 3. create REFUSES an existing token ───────────────────
-- set would clobber. The ledger is enumerate-not-list, so a silent clobber is
-- unobservable until the save is already wrong.

local md2 = makeDown()
T.ok("create takes a fresh token", md2:createObjectRecord("yl_1", { condition = 5 }))
T.ok("create refuses a token already present", not md2:createObjectRecord("yl_1", { condition = 9 }))
T.eq("and the original row is untouched", md2:getObjectRecord("yl_1").condition, 5)
T.ok("set still overwrites, which is why both exist", md2:setObjectRecord("yl_1", { condition = 9 }))

-- ── 4. THE BIRTH AXIS, ruled by Arissani 2026-07-30 ───────
-- A bale made from FIT material opens at zero; the penalty is for how far ABOVE the
-- safe-baling line the material was when it was baled. One point above the line costs
-- one wet-day equivalent. These four rows are the ruling's own walk, so if the ladder
-- is retuned without the handicap following it, this is where it shows.

T.eq("baled at the fit line opens at zero", YardLadder.birthCondition(20), 0)
T.eq("baled below the line is still zero, never negative", YardLadder.birthCondition(12), 0)
T.eq("baled at 25 opens at thirty", YardLadder.birthCondition(25), 30)
T.eq("baled at 27 is born already going off", YardLadder.birthCondition(27), 42)
T.ok("and 27 really is past the going-off edge", YardLadder.birthCondition(27) >= YardLadder.RATES.GOING_OFF_AT)
T.eq("baled at 30 opens at sixty", YardLadder.birthCondition(30), 60)
T.ok("and 30 condemns inside a wet week",
     YardLadder.birthCondition(30) + 7 * YardLadder.RATES.WET_OUTDOOR >= YardLadder.RATES.CONDEMN_AT)
T.ok("a bale baled at 25 goes off inside two wet days",
     YardLadder.birthCondition(25) + 2 * YardLadder.RATES.WET_OUTDOOR >= YardLadder.RATES.GOING_OFF_AT)

-- The handicap is expressed as a wet-day equivalent, so it tracks the wet rate rather
-- than standing beside it as a second number that can drift.
T.eq("one point above the line is exactly one wet day",
     YardLadder.birthCondition(YardLadder.fitPct() + 1), YardLadder.RATES.WET_OUTDOOR)

-- The fit line is agronomy-fixed and there is ONE of them in the mod.
T.eq("the fit line is 20 percent", YardLadder.fitPct(), 20)

-- End to end through a birth: wetness is recorded in its own right AND drives the
-- opening condition. Both, not either.
yl, md = makeLadder({ read = { status = MaterialWetness.RESULT.OK, pct = 25 } })
yl:onBaleCreated(1, { getFillLevel = function() return 100 end }, "DRYGRASS_WINDROW", 100, 1, 100)
local row = md:getObjectRecord("yl_1")
T.eq("the wetness read is kept as its own quantity", row.birthWetnessPct, 25)
T.eq("and it opens the ladder at the ruled handicap", row.condition, 30)

-- A bale baled dry is born clean even though its wetness is recorded.
yl, md = makeLadder({ read = { status = MaterialWetness.RESULT.OK, pct = 14 } })
yl:onBaleCreated(1, { getFillLevel = function() return 100 end }, "DRYGRASS_WINDROW", 100, 1, 100)
row = md:getObjectRecord("yl_1")
T.eq("dry hay records its wetness", row.birthWetnessPct, 14)
T.eq("and opens at zero", row.condition, 0)

-- ── 5. A bale we cannot vouch for opens at ZERO ───────────
-- Refusal propagates all the way out as nil. The old seasonal stub (65/55/70/75) was
-- a WETNESS estimate and was never a condition, so it is deleted rather than disabled:
-- a bought or pre-existing bale is not pre-condemned on a guess.

g_currentMission.environment.currentSeason = 4   -- winter, the old stub's harshest cell
yl, md = makeLadder({ read = { status = MaterialWetness.RESULT.REFUSAL } })
yl:onBaleCreated(1, { getFillLevel = function() return 100 end }, "STRAW", 100, 1, 100)
row = md:getObjectRecord("yl_1")
T.eq("an unreadable birth records no wetness at all", row.birthWetnessPct, nil)
T.eq("and is NOT a wetness of zero either", row.birthWetnessPct, nil)
T.eq("and opens at zero condition", row.condition, 0)
T.eq("the seasonal stub is gone, not merely unused", YardLadder.SEASONAL_BIRTH, nil)
T.eq("an unknown wetness maps to zero condition", YardLadder.birthCondition(nil), 0)

-- ── 6. Litres is passed, and it is the bale's own ─────────
-- nil, zero or negative returns REFUSAL inside readCondition. Passing the wrong
-- quantity is a caller bug, so pin what the caller actually hands over.

local skyOpts = { read = { status = MaterialWetness.RESULT.OK, pct = 20 } }
yl, md = makeLadder(skyOpts)
yl:onBaleCreated(1, { getFillLevel = function() return 3100 end }, "STRAW", 3100, 1, 4000)
T.eq("the birth read is given the newborn bale's own fill level", skyOpts.sawLitres, 3100)
T.ok("and a polygon it can actually read", skyOpts.sawVerts ~= nil and #skyOpts.sawVerts >= 3)

-- ── 7. The re-attach heuristic, and accept-and-log ────────
-- A reload is the common door a known bale comes back through, not storage.

yl, md = makeLadder()
yl:onBaleCreated(10, {}, "STRAW", 100, 1, 100)
md:getObjectRecord("yl_1").condition = 55        -- weathered a while

yl._live, yl._byNode = {}, {}                    -- the reload: transients are gone
yl:onBaleCreated(999, {}, "STRAW", 100, 1, 100)  -- same farm, fill and capacity

local rowCount = 0
md:enumerateObjects(function() rowCount = rowCount + 1 end)
T.eq("a matching bale re-attaches instead of making a second row", rowCount, 1)
T.eq("and it keeps the condition it had earned", md:getObjectRecord("yl_1").condition, 55)
T.eq("the new node now addresses the old row", yl._byNode[999], "yl_1")

-- A bale that matches nothing is accepted as new, never silently folded into a row
-- that is not its own.
yl:onBaleCreated(1000, {}, "WHEAT", 100, 1, 100)
rowCount = 0
md:enumerateObjects(function() rowCount = rowCount + 1 end)
T.eq("a non-matching bale gets its own row", rowCount, 2)

-- ── 8. The ladder: rates, shelter, dwell, wrap ────────────

local function passOnce(ladder, day)
  ladder:onLadderPass({ monotonicDay = day })
end

-- Wet outdoor day: the full ruled rate.
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passOnce(yl, 10)
T.eq("a wet outdoor day costs the ruled 6", md:getObjectRecord("yl_1").condition, 6)

-- Dry outdoor day: the split the addendum corrected in, so a dry summer cannot
-- condemn a yard falsely.
yl, md = makeLadder({ wet = false })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passOnce(yl, 10)
T.eq("a dry outdoor day costs the ruled 1", md:getObjectRecord("yl_1").condition, 1)

-- Under a roof: the corrected 0.15, not the 0.4 placeholder.
MaterialWetness.isSheltered = function() return true end
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passOnce(yl, 10)
T.near("a roof multiplies the wet rate by the ruled 0.15", md:getObjectRecord("yl_1").condition, 0.9, 0.0001)

-- No mask at all reads as outdoors: neutral when absent.
MaterialWetness.isSheltered = function() return nil end
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passOnce(yl, 10)
T.eq("an unavailable mask reads as outdoors, not as free shelter", md:getObjectRecord("yl_1").condition, 6)
MaterialWetness.isSheltered = function() return false end

-- Dwell at day grain: a bale that moved was in transit and is not charged for it.
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passOnce(yl, 10)
local afterFirst = md:getObjectRecord("yl_1").condition
getWorldTranslation = function() return 100, 0, 100 end   -- hauled overnight
passOnce(yl, 11)
T.eq("a bale that moved since yesterday accrues nothing", md:getObjectRecord("yl_1").condition, afterFirst)
passOnce(yl, 12)                                          -- parked at the new spot
T.eq("and a parked trailer starts accruing again", md:getObjectRecord("yl_1").condition, afterFirst + 6)
getWorldTranslation = function() return 0, 0, 0 end

-- Wrap is absolute armour in v1: one clock per bale, and it is the engine's.
g_currentMission.baleManager = { getFermentationTime = function() return 5000 end }
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "DRYGRASS_WINDROW", 100, 1, 100)
passOnce(yl, 10)
T.eq("a fermenting bale is untouched by the ladder", md:getObjectRecord("yl_1").condition, 0)
g_currentMission.baleManager = nil

-- A day the Water Record cannot reach is a refusal, and a refusal is not a wet day.
yl, md = makeLadder({ known = 0 })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passOnce(yl, 10)
T.eq("an unreachable day takes the dry rate, never the wet one", md:getObjectRecord("yl_1").condition, 1)

-- ── 8b. A time skip charges the SPAN, not one day ─────────
-- Found in game 2026-07-31: two bales left outdoors across roughly a simulated year
-- via the tablet, still sitting there. The pass read ctx.monotonicDay and accrued a
-- single day per settle, so a year-long skip cost one dry day. Both siblings already
-- read ctx.boundariesCrossed (MaterialDown:264, MaterialWetness:472); this one did
-- not, and nothing in the suite asked.

local function passSpan(ladder, day, boundaries)
  ladder:onLadderPass({ monotonicDay = day, boundariesCrossed = boundaries })
end

-- A hundred dry days is exactly the condemnation threshold at 1/day.
yl, md = makeLadder({ wet = false })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passSpan(yl, 110, 30)
T.eq("thirty dry days cost thirty, not one", md:getObjectRecord("yl_1").condition, 30)

-- The wet split comes from the Water Record over the whole span, in one read.
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passSpan(yl, 110, 10)
T.eq("a ten day span of wet days costs the wet rate throughout",
     md:getObjectRecord("yl_1").condition, 10 * YardLadder.RATES.WET_OUTDOOR)

-- Days the record cannot reach are DRY, never wet: neutral when absent, and the
-- direction that cannot condemn a yard on evidence we do not have.
yl, md = makeLadder({ known = 0 })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
passSpan(yl, 110, 50)
T.eq("an unreachable span takes the dry rate for every day",
     md:getObjectRecord("yl_1").condition, 50 * YardLadder.RATES.DRY_OUTDOOR)

-- The headline: a skipped year must actually kill an unsheltered bale.
local killed = false
yl, md = makeLadder({ wet = false })
yl:onBaleCreated(1, { setFillLevel = function() end, delete = function() killed = true end },
                 "STRAW", 100, 1, 100)
passSpan(yl, 400, 365)
T.ok("a bale left outdoors for a skipped year is condemned", killed)
T.eq("and its row is gone", md:getObjectRecord("yl_1"), nil)

-- A missing or nonsense boundary count degrades to one day rather than zero, so a
-- scheduler that omits it still ages the yard.
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
yl:onLadderPass({ monotonicDay = 110 })
T.eq("no boundary count still charges one day",
     md:getObjectRecord("yl_1").condition, YardLadder.RATES.WET_OUTDOOR)

-- ── 9. Bands and condemnation ─────────────────────────────

yl, md = makeLadder()
yl:onBaleCreated(1, {}, "STRAW", 100, 1, 100)
row = md:getObjectRecord("yl_1")

row.condition = 39.9
T.eq("just under the going-off edge is still fresh", (yl:getConditionBand("yl_1")), YardLadder.BAND.FRESH)
row.condition = 40
T.eq("the ruled 40 opens the going-off band", (yl:getConditionBand("yl_1")), YardLadder.BAND.GOING_OFF)
row.condition = 99.9
T.eq("just under terminal is still only going off", (yl:getConditionBand("yl_1")), YardLadder.BAND.GOING_OFF)
row.condition = 100
T.eq("the ruled 100 is terminal", (yl:getConditionBand("yl_1")), YardLadder.BAND.CONDEMNED)

T.eq("the band is reachable by the node a caller actually holds",
     (yl:getConditionBandForNode(1)), YardLadder.BAND.CONDEMNED)

-- Condemnation is ONE event: empty it, then delete it, and the row dies with it.
local emptied, deleted = false, false
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, {
  setFillLevel = function(_, v) emptied = (v == 0) end,
  delete       = function() deleted = true end,
}, "STRAW", 100, 1, 100)
md:getObjectRecord("yl_1").condition = 99
passOnce(yl, 10)
T.ok("terminal condition empties the bale first", emptied)
T.ok("then deletes it", deleted)
T.eq("and the row dies with it", md:getObjectRecord("yl_1"), nil)

-- Terminal with no live reference must not leave a silently immortal bale: the row
-- goes and the warning is the only trace, which is what makes it findable.
yl, md = makeLadder({ wet = true })
yl:onBaleCreated(1, nil, "STRAW", 100, 1, 100)
md:getObjectRecord("yl_1").condition = 99
passOnce(yl, 10)
T.eq("a terminal row with no bale reference is still dropped", md:getObjectRecord("yl_1"), nil)

-- A bale leaving by any other door takes its row with it.
yl, md = makeLadder()
yl:onBaleCreated(77, {}, "STRAW", 100, 1, 100)
yl:onBaleRemoved(77)
T.eq("a removed bale takes its row", md:getObjectRecord("yl_1"), nil)
T.eq("and its node index entry", yl._byNode[77], nil)

-- ── 10. The ruled horizons still hold ─────────────────────
-- The balance guard. If a rate moves without the thresholds moving, the addendum's
-- promise ("going off about a wet week, condemned about 2.5 wet weeks") quietly stops
-- being true. This is where that shows.

local R = YardLadder.RATES
local wetDaysToGoingOff = R.GOING_OFF_AT / R.WET_OUTDOOR
local wetDaysToCondemn  = R.CONDEMN_AT / R.WET_OUTDOOR
T.near("outdoors, going off lands at about a wet week", wetDaysToGoingOff, 7, 1)
T.near("and condemnation at about 2.5 wet weeks", wetDaysToCondemn, 17.5, 1.5)

-- The roof rung is the believable shed-year the correction was made for: roughly 7x
-- kinder than open ground, not the 2.5x the 0.4 placeholder gave.
T.near("a roof is about 7x kinder than open ground", 1 / R.ROOF_MULTIPLIER, 6.67, 0.5)

-- Dry days are nearly free, which is the half of the correction that stops a dry
-- summer condemning a yard.
T.ok("a dry day costs a fraction of a wet one", R.DRY_OUTDOOR * 5 < R.WET_OUTDOOR)

-- The enclosed rung is NOT here on purpose. The engine's shelter predicate is binary
-- (verified: no three-state predicate exists in the reference), so v1 ships two rungs
-- and charges unverifiable cover at the roof rate rather than exempting it. If a
-- three-state predicate ever lands, this is the assertion to come back to.
T.eq("v1 ships two shelter rungs, outdoors and roof", R.ROOF_MULTIPLIER < 1 and 2 or 0, 2)
