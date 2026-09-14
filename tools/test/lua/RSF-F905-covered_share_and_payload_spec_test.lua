-- RSF-F905 COVERED SHARE AND PAYLOAD PAIR. This bar defends the two decision
-- tables where the brief carried contradictions through two review rounds: the
-- missing-versus-empty coverage read, and the value-versus-known-flag payload.
--
-- GROUP A asserts the payload INVARIANTS on real source: the bridge scalar list is
-- untouched (still twenty, no pair entry, compaction last) because the pair is
-- serialized explicitly outside that walk (brief item 9). GROUPS B to F are the pure
-- reference contracts supplied with the brief; they prove the decision tables are
-- self-consistent and that their cases are distinguishable. GROUPS G onward drive
-- the REAL bodies: the scaled slice, the covered-share read, the applyFertilizer
-- gate, the bridge pair and its shape refusal, the publisher, and four of the five
-- display surfaces (the HUD row counter, the native field-info line, the PDA merge and
-- the treatment tip; the HUD update body's text pair is asserted through the
-- reference model in Group E, not driven). They do not prove density-map execution,
-- engine stream IO, savegame durability, rendering or real multiplayer transport.
--
-- All cell counts, shares and tick durations below are test fixtures, not
-- transcribed agronomy and not live-map measurements.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/OrganicCertification.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/integrations/SoilNetworkSyncBridge.lua, src/ui/SoilHUD.lua, src/ui/RfPdaSoilMerge.lua, src/ui/SoilTreatmentRates.lua

local EPS = 0.000000001 -- pure-Lua arithmetic tolerance, not a simulation tolerance

-- =====================================================================
-- GROUP A: REAL SOURCE INVARIANTS. The SCALARS walk is not the carrier.
-- =====================================================================

local SCALARS = SoilNetworkSyncBridge and SoilNetworkSyncBridge.SCALARS
T.ok("F905 A1: the bridge scalar list loaded from real source", type(SCALARS) == "table")

local scalarCount, hasPenalty, hasKnown, hasBurnDays = 0, false, false, false
for _, s in ipairs(SCALARS or {}) do
  scalarCount = scalarCount + 1
  if s.key == "amendBurnPenalty" then hasPenalty = true end
  if s.key == "amendBurnKnown"   then hasKnown   = true end
  if s.key == "burnDaysLeft"     then hasBurnDays = true end
end

T.eq("F905 A2: the scalar list still carries exactly twenty entries", scalarCount, 20)
T.eq("F905 A3: amendBurnPenalty is NOT a SCALARS entry (it is written explicitly)", hasPenalty, false)
T.eq("F905 A4: the companion known flag is NOT a SCALARS entry (the walk cannot compute it)", hasKnown, false)
T.eq("F905 A5: burnDaysLeft is present, so the list read is the real one", hasBurnDays, true)
T.eq("F905 A6: compaction is still the last scalar, so the pair follows the walk",
     SCALARS[scalarCount] and SCALARS[scalarCount].key, "compaction")

-- pHReportValid is the precedent the brief follows for the pair and deliberately
-- does NOT follow for the write side. Both facts are asserted from real source.
local phValid
for _, s in ipairs(SCALARS or {}) do
  if s.key == "pHReportValid" then phValid = s end
end
T.ok("F905 A7: pHReportValid exists as the paired-flag precedent", phValid ~= nil)
T.eq("F905 A8: that precedent is a bool scalar", phValid and phValid.bool, true)
T.eq("F905 A9: that precedent defaults to one, which is why its write side is unsafe to copy",
     phValid and phValid.def, 1)

-- =====================================================================
-- GROUP B: THE COVERAGE DECISION TABLE. Missing is not empty.
-- =====================================================================

local MISSING, MEASURED = "MISSING", "MEASURED"

-- Reference contract for brief items 4 and 5.
local function coverageRead(boomPoints, polyVerts, burnableFlags)
  if boomPoints == nil then return MISSING, nil end
  if polyVerts == nil then return MISSING, nil end
  local sampled, burnable = 0, 0
  for i = 1, #boomPoints do
    if polyVerts.contains(boomPoints[i]) then
      sampled = sampled + 1
      if burnableFlags[i] then burnable = burnable + 1 end
    end
  end
  if sampled == 0 then return MEASURED, 0.0 end
  return MEASURED, burnable / sampled
end

local allIn = { contains = function() return true end }
local allOut = { contains = function() return false end }
local pts8 = { 1, 2, 3, 4, 5, 6, 7, 8 }

local st, share = coverageRead(pts8, allIn, { true, true, true, true, true, true, true, true })
T.eq("F905 B1: a pass entirely over standing crop measures a full share state", st, MEASURED)
T.near("F905 B2: and that share is one", share, 1.0, EPS)

st, share = coverageRead(pts8, allIn, { false, false, false, false, false, false, false, false })
T.eq("F905 B3: a pass entirely over cut or flattened ground measures", st, MEASURED)
T.near("F905 B4: and accrues nothing", share, 0.0, EPS)

st, share = coverageRead(pts8, allIn, { true, false, false, true, false, true, false, false })
T.eq("F905 B5: a mixed pass measures", st, MEASURED)
T.near("F905 B6: and accrues in proportion to the standing part", share, 3 / 8, EPS)

st, share = coverageRead(pts8, allOut, { true, true, true, true, true, true, true, true })
T.eq("F905 B7: a polygon that rejects every cell is still a MEASURED read", st, MEASURED)
T.near("F905 B8: and its share is a real zero, not a fallback", share, 0.0, EPS)

st, share = coverageRead(nil, allIn, {})
T.eq("F905 B9: a boom that produced no points is a MISSING read", st, MISSING)
T.eq("F905 B10: and yields no share at all", share, nil)

st, share = coverageRead(pts8, nil, { true })
T.eq("F905 B11: an unavailable field polygon is a MISSING read", st, MISSING)
T.eq("F905 B12: and is never turned into a count-everything share", share, nil)

local emptyState = select(1, coverageRead(pts8, allOut, { true }))
local missingState = select(1, coverageRead(nil, allIn, {}))
T.ok("F905 B13: MEASURED-zero and MISSING are distinguishable outcomes", emptyState ~= missingState)

-- =====================================================================
-- GROUP C: INCREMENT ARITHMETIC. The share can only ever reduce the charge.
-- =====================================================================

local function slice(stored, maxPen, dt, fullMs, gapMs, shareIn)
  local cur = stored or 0
  if dt > 0 and dt <= gapMs and fullMs > 0 then
    local inc = maxPen * (dt / fullMs) * shareIn
    local ramped = math.min(maxPen, cur + inc)
    cur = math.max(cur, ramped)
  end
  return cur
end

local MAXPEN, FULL, GAP = 0.80, 8000, 1500

T.near("F905 C1: the first tick of a pass accrues nothing, as the clock intends",
       slice(nil, MAXPEN, 0, FULL, GAP, 1.0), 0.0, EPS)
T.near("F905 C2: a full-coverage tick accrues the unscaled increment",
       slice(0, MAXPEN, 1000, FULL, GAP, 1.0), MAXPEN * (1000 / FULL), EPS)
T.near("F905 C3: a three-eighths share accrues three eighths of it",
       slice(0, MAXPEN, 1000, FULL, GAP, 3 / 8), MAXPEN * (1000 / FULL) * (3 / 8), EPS)
T.near("F905 C4: a zero share accrues nothing while the clock still runs",
       slice(0.25, MAXPEN, 1000, FULL, GAP, 0.0), 0.25, EPS)

local acc = 0
for _ = 1, 40 do acc = slice(acc, MAXPEN, 1000, FULL, GAP, 1.0) end
T.near("F905 C5: sustained full coverage reaches the cap and stops there", acc, MAXPEN, EPS)

acc = 0
for _ = 1, 40 do acc = slice(acc, MAXPEN, 1000, FULL, GAP, 0.25) end
T.ok("F905 C6: a scaled pass can never exceed the designed cap", acc <= MAXPEN + EPS)

T.near("F905 C7: a later lighter tick never reduces what was already charged",
       slice(0.50, MAXPEN, 1000, FULL, GAP, 0.0), 0.50, EPS)
T.near("F905 C8: a gap longer than the pass window accrues nothing",
       slice(0.10, MAXPEN, GAP + 1, FULL, GAP, 1.0), 0.10, EPS)

-- =====================================================================
-- GROUP D: THE PAYLOAD PAIR. Absence must not read as a confirmed zero.
-- =====================================================================

local function clamp(v, lo, hi)
  v = tonumber(v) or 0
  if lo ~= nil and v < lo then v = lo end
  if hi ~= nil and v > hi then v = hi end
  return v
end

-- Write side, brief item 8: ONLY the owner serializes this payload, so the flag it
-- writes is known, always. Presence of the key is deliberately NOT consulted.
local function writePair(field)
  return { field.amendBurnPenalty or 0, 1 }
end

local function readPair(arr, i)
  local value = clamp(arr[i], 0, 1)
  local known = clamp(arr[i + 1], 0, 1) == 1
  return value, known
end

local w = writePair({ amendBurnPenalty = 0.42 })
local v, k = readPair(w, 1)
T.near("F905 D1: a real penalty round trips by value", v, 0.42, EPS)
T.eq("F905 D2: and arrives marked known", k, true)

w = writePair({ amendBurnPenalty = 0 })
v, k = readPair(w, 1)
T.near("F905 D3: a server that genuinely sent zero round trips as zero", v, 0.0, EPS)
T.eq("F905 D4: and is still marked known", k, true)

w = writePair({})
v, k = readPair(w, 1)
T.near("F905 D5: a field the owner has cleared writes an authoritative zero", v, 0.0, EPS)
T.eq("F905 D5b: and the owner marks that zero KNOWN, which is what keeps the host risk row alive", k, true)

v, k = readPair({}, 1)
T.near("F905 D6: an absent element clamps to zero, exactly as the reader does today", v, 0.0, EPS)
T.eq("F905 D7: but the flag makes that zero read as NOT known, not as confirmed no burn", k, false)

local function presenceFlagWrite(field) return (field.amendBurnPenalty ~= nil) and 1 or 0 end
T.eq("F905 D8: a presence-derived flag calls a cleared field NOT known, which silences the host row",
     presenceFlagWrite({}), 0)
T.eq("F905 D9: the owner-written flag calls that same field known, which is the repair",
     writePair({})[2], 1)
T.ok("F905 D10: the two disagree on exactly the case the certificate named",
     presenceFlagWrite({}) ~= writePair({})[2])

local function applyArray(arr, fieldCount, valuesPerField)
  local cursor = 1 + (fieldCount * valuesPerField)
  if cursor ~= #arr + 1 then return false end
  return true
end
T.eq("F905 D11: an array whose walk lands exactly at the end is applied",
     applyArray({ 1, 2, 3, 4 }, 2, 2), true)
T.eq("F905 D12: a longer array than the reader expects is refused whole",
     applyArray({ 1, 2, 3, 4, 5 }, 2, 2), false)
T.eq("F905 D13: a shorter array than the reader expects is refused whole",
     applyArray({ 1, 2, 3 }, 2, 2), false)

-- =====================================================================
-- GROUP E: THREE STATES ON THE SCREEN, AND THE ROW COUNT THAT MATCHES.
-- =====================================================================

local function surfaces(known, penalty, risk)
  local showPct  = known and penalty > 0
  local showRisk = known and penalty <= 0 and risk == true
  local rows = (showPct and 1 or 0) + (showRisk and 1 or 0)
  return showPct, showRisk, rows
end

local pct, rsk, rows = surfaces(true, 0.42, true)
T.eq("F905 E1: a known burn shows the percentage", pct, true)
T.eq("F905 E2: and suppresses the pre-emptive warning", rsk, false)
T.eq("F905 E3: and counts one row", rows, 1)

pct, rsk, rows = surfaces(true, 0, true)
T.eq("F905 E4: a known zero on an at-risk crop shows the warning only", rsk, true)
T.eq("F905 E5: and no percentage", pct, false)
T.eq("F905 E6: and counts one row", rows, 1)

pct, rsk, rows = surfaces(false, 0, true)
T.eq("F905 E7: a client that does not know shows no percentage", pct, false)
T.eq("F905 E8: and never asserts a confirmed no burn", rsk, false)
T.eq("F905 E9: and counts no rows, so the panel height agrees with its contents", rows, 0)

local function mergeGroup(members)
  local allKnown, worst = true, 0
  for _, m in ipairs(members) do
    if not m.known then allKnown = false end
    if m.known and m.penalty > worst then worst = m.penalty end
  end
  if not allKnown then return false, 0 end
  return true, worst
end

local gk, gp = mergeGroup({ { known = true, penalty = 0 }, { known = true, penalty = 0.30 } })
T.eq("F905 E10: a group of known members is known", gk, true)
T.near("F905 E11: and reports its worst member rather than an average", gp, 0.30, EPS)

gk, gp = mergeGroup({ { known = true, penalty = 0.30 }, { known = false, penalty = 0 } })
T.eq("F905 E12: one unknown member makes the whole group not known", gk, false)
local gpct, grsk = surfaces(gk, gp, true)
T.eq("F905 E13: so the grouped row shows no percentage", gpct, false)
T.eq("F905 E14: and does not warn about a burn it cannot rule out", grsk, false)

-- =====================================================================
-- GROUP F: THE PUBLISHER RULE. The owner knows; a client knows what it got.
-- =====================================================================

local function publish(isOwner, record)
  local value = record.amendBurnPenalty or 0
  local known = isOwner or (record.amendBurnKnown == true)
  return value, known
end

local pv, pk = publish(true, {})
T.near("F905 F1: a host field never limed publishes zero", pv, 0.0, EPS)
T.eq("F905 F2: and publishes it as KNOWN", pk, true)

pv, pk = publish(true, { amendBurnPenalty = 0.30 })
T.near("F905 F3: a host field mid-burn publishes its number", pv, 0.30, EPS)
T.eq("F905 F4: known", pk, true)

pv, pk = publish(false, {})
T.eq("F905 F5: a client with no delivered flag is NOT known", pk, false)

pv, pk = publish(false, { amendBurnPenalty = 0.30, amendBurnKnown = true })
T.near("F905 F6: a client that received the pair publishes the number", pv, 0.30, EPS)
T.eq("F905 F7: and is known", pk, true)

pv, pk = publish(false, { amendBurnPenalty = 0, amendBurnKnown = true })
T.eq("F905 F8: a client that received an authoritative zero is known", pk, true)

local hv, hk = publish(true, {})
local hp, hr = surfaces(hk, hv, true)
T.eq("F905 F9: a host field cleared at harvest still shows the pre-emptive risk row", hr, true)
T.eq("F905 F10: and shows no percentage", hp, false)

-- =====================================================================
-- GROUP G: THE REAL SLICE. applyAmendmentBurnSlice with the share argument.
-- =====================================================================

local SR = SoilConstants.SPRAYER_RATE
local FULL_MS  = SR.BURN_FULL_DAMAGE_MS
local LIME_MAX = SoilConstants.AMEND_BURN.LIME_MAX

local function newSys(field, extra)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { enabled = true, showNotifications = false },
  }, { __index = SoilFertilitySystem })
  for k, val in pairs(extra or {}) do sys[k] = val end
  return sys
end
local function at(t) g_currentMission.time = t end

do
  local field = {}
  local sys = newSys(field)
  at(0);    sys:applyAmendmentBurnSlice(field, LIME_MAX)          -- two-arg call: burn_test.lua's shape
  at(1000); sys:applyAmendmentBurnSlice(field, LIME_MAX)
  T.near("F905 G1: a nil share is today's full increment (burn_test shape stays valid)",
         field.amendBurnPenalty, LIME_MAX * (1000 / FULL_MS), 1e-9)
end

do
  local field = {}
  local sys = newSys(field)
  at(0);    sys:applyAmendmentBurnSlice(field, LIME_MAX, 3 / 8)
  at(1000); sys:applyAmendmentBurnSlice(field, LIME_MAX, 3 / 8)
  T.near("F905 G2: a measured share scales the real increment",
         field.amendBurnPenalty, LIME_MAX * (1000 / FULL_MS) * (3 / 8), 1e-9)
end

do
  local field = { amendBurnPenalty = 0.25 }
  local sys = newSys(field)
  at(0);    sys:applyAmendmentBurnSlice(field, LIME_MAX, 0)
  at(1000); sys:applyAmendmentBurnSlice(field, LIME_MAX, 0)
  T.near("F905 G3: a zero share accrues nothing", field.amendBurnPenalty, 0.25, 1e-9)
  T.eq("F905 G4: but the pass clock still advanced", field._amendBurnTickTime, 1000)
  at(2000); sys:applyAmendmentBurnSlice(field, LIME_MAX, 1)
  T.near("F905 G5: so the next burnable tick charges one slice off the open pass, not a fresh first tick",
         field.amendBurnPenalty, 0.25 + LIME_MAX * (1000 / FULL_MS), 1e-9)
end

-- =====================================================================
-- GROUP H: THE REAL COVERED-SHARE READ. computeCoveredBurnShare on real source.
-- =====================================================================

local CELL = SoilConstants.ZONE.CELL_SIZE
-- A square field polygon covering cells 0..9 on both axes (0 to 10 cells).
local SQUARE = { {x = 0, z = 0}, {x = 10 * CELL, z = 0}, {x = 10 * CELL, z = 10 * CELL}, {x = 0, z = 10 * CELL} }
local function cellPt(cx, cz, dx, dz) return { x = cx * CELL + (dx or 1), z = cz * CELL + (dz or 1) } end

-- Engine stubs: one fruit desc, established at gs >= 2 (minH 6 * 0.33 -> 2), cut at 8.
local savedGetByIndex = g_fruitTypeManager.getFruitTypeByIndex
local savedDensity = FSDensityMapUtil.getFruitTypeIndexAtWorldPos
g_fruitTypeManager.getFruitTypeByIndex = function(_self, idx)
  if idx == 1 then return { name = "WHEAT", index = 1, minHarvestingGrowthState = 6, cutStates = { [8] = true } } end
  return nil
end
-- cropAt maps "cx_cz" -> { fruitIndex, growthState } (nil entry = bare ground)
local cropAt = {}
local readLog = {}
FSDensityMapUtil.getFruitTypeIndexAtWorldPos = function(x, z)
  local key = math.floor(x / CELL) .. "_" .. math.floor(z / CELL)
  readLog[#readLog + 1] = { x = x, z = z }
  local c = cropAt[key]
  if c == nil then return nil end
  return c[1], c[2]
end

-- The polygon source is the real _getFarmlandPolygons cache: a farmland id maps to an
-- ARRAY of parcel polygons (false = resolved-but-unavailable). Field 1 is the square.
local function shareSys(polygons, extraFarmlands)
  local field = {}
  local sys = newSys(field)
  local entry = { polygons }
  if polygons == false then entry = false end
  sys._farmlandPolygons = { [1] = entry }
  for fid, polys in pairs(extraFarmlands or {}) do sys._farmlandPolygons[fid] = polys end
  return sys, field
end

do
  local sys, field = shareSys(SQUARE)
  T.eq("F905 H1: nil boom points is a MISSING read (nil)", sys:computeCoveredBurnShare(1, field, nil), nil)
  T.eq("F905 H2: an empty boom set is a MISSING read (nil)", sys:computeCoveredBurnShare(1, field, {}), nil)
end

do
  local sys, field = shareSys(false)   -- polygon resolved-but-unavailable, cached false
  cropAt = { ["1_1"] = { 1, 5 } }
  T.eq("F905 H3: an unavailable field polygon is a MISSING read, never count-everything",
       sys:computeCoveredBurnShare(1, field, { cellPt(1, 1) }), nil)
  T.eq("F905 H3b: and that failure is sticky per farmland (the cache holds false), so the point verdict stays",
       sys:computeCoveredBurnShare(1, field, { cellPt(1, 1) }), nil)
end

do
  local sys, field = shareSys(SQUARE)
  cropAt = { ["1_1"] = { 1, 5 }, ["2_1"] = { 1, 5 }, ["3_1"] = { 1, 5 }, ["4_1"] = { 1, 5 } }
  local pts = { cellPt(1, 1), cellPt(2, 1), cellPt(3, 1), cellPt(4, 1) }
  T.near("F905 H4: a pass entirely over established crop is a share of one",
         sys:computeCoveredBurnShare(1, field, pts), 1.0, EPS)
end

do
  local sys, field = shareSys(SQUARE)
  -- 8 cells: 3 established (gs 5), 2 cut (gs 8, exempt), 1 seedling (gs 1, exempt), 2 bare
  cropAt = {
    ["0_0"] = { 1, 5 }, ["1_0"] = { 1, 8 }, ["2_0"] = { 1, 8 }, ["3_0"] = { 1, 5 },
    ["4_0"] = { 1, 1 }, ["5_0"] = { 1, 5 }, ["6_0"] = nil, ["7_0"] = nil,
  }
  local pts = {}
  for cx = 0, 7 do pts[#pts + 1] = cellPt(cx, 0) end
  T.near("F905 H5: a mixed pass accrues in proportion (3 burnable of 8 sampled)",
         sys:computeCoveredBurnShare(1, field, pts), 3 / 8, EPS)
end

do
  local sys, field = shareSys(SQUARE)
  cropAt = { ["1_1"] = { 1, 5 } }
  -- Three points in the same cell count once; the second cell is bare.
  local pts = { cellPt(1, 1, 1, 1), cellPt(1, 1, 4, 7), cellPt(1, 1, 9, 2), cellPt(2, 1) }
  T.near("F905 H6: points are deduplicated to cells the way markBoomCells does",
         sys:computeCoveredBurnShare(1, field, pts), 1 / 2, EPS)
end

do
  local sys, field = shareSys(SQUARE)
  cropAt = { ["12_12"] = { 1, 5 }, ["13_12"] = { 1, 5 } }
  local pts = { cellPt(12, 12), cellPt(13, 12) }   -- all outside the 0..9 square
  T.near("F905 H7: a polygon that rejects every cell is a real share of zero, not a missing read",
         sys:computeCoveredBurnShare(1, field, pts), 0.0, EPS)
end

do
  local sys, field = shareSys(SQUARE)
  cropAt = { ["9_5"] = { 1, 5 }, ["10_5"] = { 1, 5 } }
  readLog = {}
  -- Cell 9 has its centre at 95 (inside); cell 10 has its centre at 105 (outside).
  local pts = { cellPt(9, 5, 9, 1), cellPt(10, 5, 0.5, 1) }
  local s = sys:computeCoveredBurnShare(1, field, pts)
  T.near("F905 H8: membership is decided at the cell centre (headland overhang does not vote)", s, 1.0, EPS)
  T.eq("F905 H9: exactly one density read, for the admitted cell", #readLog, 1)
  T.near("F905 H10: and the crop is read at that same cell centre, x", readLog[1].x, 9.5 * CELL, EPS)
  T.near("F905 H11: and z", readLog[1].z, 5.5 * CELL, EPS)
end

do
  local sys, field = shareSys(SQUARE)
  cropAt = { ["1_1"] = { 1, 5 }, ["2_1"] = nil }
  local pts = { cellPt(1, 1), cellPt(2, 1) }
  local first = sys:computeCoveredBurnShare(1, field, pts)
  cropAt = { ["1_1"] = nil, ["2_1"] = nil }   -- ground changes underneath; same points table
  local again = sys:computeCoveredBurnShare(1, field, pts)
  T.near("F905 H12: sibling sections passing the SAME points table reuse the cached share", again, first, EPS)
  local fresh = sys:computeCoveredBurnShare(1, field, { cellPt(1, 1), cellPt(2, 1) })
  T.near("F905 H13: a new points table (next tick) is recomputed", fresh, 0.0, EPS)
end

do
  -- Farmland 2 is a single cell at (0,0). Crop stands only in cell (5,5), which farmland
  -- 1 admits and farmland 2 rejects, so the two verdicts must DIFFER.
  local oneCell = { {x = 0, z = 0}, {x = CELL, z = 0}, {x = CELL, z = CELL}, {x = 0, z = CELL} }
  local sys, field = shareSys(SQUARE, { [2] = { oneCell } })
  local other = {}
  cropAt = { ["5_5"] = { 1, 5 } }
  local pts = { cellPt(0, 0), cellPt(5, 5) }
  T.near("F905 H14: the metered field's own polygon decides (field 1 admits both cells, one burnable)",
         sys:computeCoveredBurnShare(1, field, pts), 1 / 2, EPS)
  T.near("F905 H15: a section metering another field uses THAT field's polygon (admits only the bare cell)",
         sys:computeCoveredBurnShare(2, other, pts), 0.0, EPS)
  T.eq("F905 H16: and the caches never cross fields", other._amendBurnShareSrc == pts and field._amendBurnShareSrc == pts, true)
end

do
  -- Bob's blocker: a farmland carrying TWO parcels. The first-match helper would reject
  -- every cell on the second parcel and switch the burn off there for good (F347 by
  -- another road). The parcel union admits a cell inside ANY parcel.
  local parcelA = { {x = 0, z = 0}, {x = 2 * CELL, z = 0}, {x = 2 * CELL, z = 2 * CELL}, {x = 0, z = 2 * CELL} }
  local parcelB = { {x = 5 * CELL, z = 5 * CELL}, {x = 7 * CELL, z = 5 * CELL}, {x = 7 * CELL, z = 7 * CELL}, {x = 5 * CELL, z = 7 * CELL} }
  local field = {}
  local sys = newSys(field)
  sys._farmlandPolygons = { [1] = { parcelA, parcelB } }
  cropAt = { ["5_5"] = { 1, 5 }, ["6_6"] = { 1, 5 } }
  local pts = { cellPt(5, 5), cellPt(6, 6) }   -- entirely on the SECOND parcel
  T.near("F905 H19: a pass on the second parcel of a shared farmland measures a full share, not zero",
         sys:computeCoveredBurnShare(1, field, pts), 1.0, EPS)
  local sys2 = newSys({})
  sys2._farmlandPolygons = { [1] = { parcelA } }   -- what the first-match contract would have given
  T.near("F905 H20: (evidence) the first parcel alone would have rejected every cell and read a real zero",
         sys2:computeCoveredBurnShare(1, {}, pts), 0.0, EPS)
end

do
  local sys, field = shareSys(SQUARE)
  cropAt = { ["1_1"] = { 1, 5 } }
  local pts = { cellPt(1, 1) }
  local boom = FSDensityMapUtil.getFruitTypeIndexAtWorldPos
  FSDensityMapUtil.getFruitTypeIndexAtWorldPos = function() error("density map not ready") end
  T.eq("F905 H17: a FAILED engine read is a MISSING read (nil), never zero burnable cells",
       sys:computeCoveredBurnShare(1, field, pts), nil)
  FSDensityMapUtil.getFruitTypeIndexAtWorldPos = nil
  T.eq("F905 H18: no engine per-cell get at all is a MISSING read (nil)",
       sys:computeCoveredBurnShare(1, field, { cellPt(1, 1) }), nil)
  FSDensityMapUtil.getFruitTypeIndexAtWorldPos = boom
end

-- =====================================================================
-- GROUP I: THE REAL GATE. applyFertilizer with the measured share (F347 closed).
-- =====================================================================

local savedFillMgr = g_fillTypeManager
g_fillTypeManager = { getFillTypeByIndex = function(_self, idx)
  if idx == 7 then return { name = "LIME", index = 7 } end
  return nil
end }

local function gateSys(field)
  -- Enough soil on the record for the nutrient side of applyFertilizer to run clean,
  -- so the whole real body executes (no pcall hiding a regression past the gate).
  field.pH = 6.5; field.nitrogen = 50; field.phosphorus = 40; field.potassium = 30
  field.organicMatter = 3; field.fieldArea = 2
  local polygons = field._polyVerts   -- fixture shorthand: SQUARE or false
  field._polyVerts = nil
  local entry = { polygons }
  if polygons == false then entry = false end
  local notices = {}
  local sys = newSys(field, {
    _farmlandPolygons = { [1] = entry },
    showNotification = function(_self, title, body) notices[#notices + 1] = title end,
    -- getOrCreateField is the only manager-side dependency; the field record is supplied.
    getOrCreateField = function(self, fieldId) return self.fieldData[fieldId] end,
  })
  return sys, notices
end

do
  local field = { _polyVerts = SQUARE, _amendBurnNotified = true }   -- flag ALREADY set: the F347 trap
  local sys, notices = gateSys(field)
  cropAt = { ["1_1"] = { 1, 5 } }
  local function tick(t) at(t); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) }) end
  tick(0); tick(1000); tick(2000)
  T.near("F905 I1: with the notification flag out of the gate, a sustained pass accrues across ticks (F347)",
         field.amendBurnPenalty, LIME_MAX * (2000 / FULL_MS), 1e-9)
  T.eq("F905 I2: and the already-set flag throttles the toast, not the burn", #notices, 0)
end

do
  local field = { _polyVerts = SQUARE }
  local sys, notices = gateSys(field)
  cropAt = { ["1_1"] = { 1, 5 } }
  at(0);    sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  at(1000); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  at(2000); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  T.eq("F905 I3: the toast fires exactly once per field per crop cycle", #notices, 1)
  T.eq("F905 I4: and it is the lime toast", notices[1], "sf_notify_lime_crop_title")
end

do
  local field = { _polyVerts = SQUARE }
  local sys, notices = gateSys(field)
  cropAt = { ["1_1"] = { 1, 8 } }   -- cut: exempt, so a measured share of zero
  at(0);    sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  at(1000); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  T.eq("F905 I5: a measured zero share accrues nothing", field.amendBurnPenalty, nil)
  T.eq("F905 I6: but the pass clock ran (the slice was called at share zero)", field._amendBurnTickTime, 1000)
  T.eq("F905 I7: and no toast fires for a tick that charged nothing", #notices, 0)
  cropAt = { ["1_1"] = { 1, 5 } }
  at(2000); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  T.near("F905 I8: the next burnable tick charges one slice off the still-open pass",
         field.amendBurnPenalty, LIME_MAX * (1000 / FULL_MS), 1e-9)
  T.eq("F905 I9: and the toast fires now, when something was charged", #notices, 1)
end

do
  -- MEASURED decides: the single-point verdict is not consulted when a share exists.
  local field = { _polyVerts = SQUARE }
  local sys = gateSys(field)
  sys._lastSprayX, sys._lastSprayZ = 5, 5
  local pointSampled = false
  local savedFarmland = g_farmlandManager
  g_farmlandManager = { getFarmlandAtWorldPosition = function() pointSampled = true; return nil end }
  cropAt = { ["1_1"] = { 1, 5 } }
  at(0); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  T.eq("F905 I10: a measured share replaces the single-point sample entirely", pointSampled, false)
  -- MISSING keeps today's verdict: with no boom points the point path runs.
  at(1000); sys:applyFertilizer(1, 7, 10, nil)
  T.eq("F905 I11: a missing coverage read falls back to the single-point verdict", pointSampled, true)
  g_farmlandManager = savedFarmland
end

do
  -- MISSING read with no crop at the point: nothing runs, exactly as today (no clock either).
  local field = { _polyVerts = false }
  local sys, notices = gateSys(field)
  at(0);    sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  at(1000); sys:applyFertilizer(1, 7, 10, { cellPt(1, 1) })
  T.eq("F905 I12: a missing read with no point verdict available runs no slice", field._amendBurnTickTime, nil)
  T.eq("F905 I13: and never toasts", #notices, 0)
end

g_fillTypeManager = savedFillMgr
g_fruitTypeManager.getFruitTypeByIndex = savedGetByIndex
FSDensityMapUtil.getFruitTypeIndexAtWorldPos = savedDensity

-- =====================================================================
-- GROUP J: THE REAL BRIDGE. The pair rides explicitly, and the shape is refused whole.
-- =====================================================================

local B = SoilNetworkSyncBridge
local function bridgeField(over)
  local f = { fieldArea = 2.0, nitrogen = 50, phosphorus = 40, potassium = 30, organicMatter = 3, pH = 6.5,
              lastCrop = "wheat", nutrientBuffer = {}, compaction = 4 }
  for k, val in pairs(over or {}) do f[k] = val end
  return f
end

do
  local arr = B.serializeFields({ [3] = bridgeField({ amendBurnPenalty = 0.42 }) })
  -- arr[1] count, arr[2] fieldId, arr[3..22] the twenty scalars, then the pair.
  T.near("F905 J1: the value sits immediately after the twentieth scalar", arr[23], 0.42, EPS)
  T.eq("F905 J2: the flag follows it and is written as known by the owner", arr[24], 1)
  T.eq("F905 J3: then the crop names continue in their old order", arr[25], "wheat")
  local out, ok = B.deserializeFields(arr)
  T.eq("F905 J4: a well-formed array walks to exactly #arr + 1 and is accepted", ok, true)
  T.near("F905 J5: the value round trips", out[3].amendBurnPenalty, 0.42, EPS)
  T.eq("F905 J6: and arrives known", out[3].amendBurnKnown, true)
end

do
  local out, ok = B.deserializeFields(B.serializeFields({ [3] = bridgeField() }))
  T.eq("F905 J7: a field that has never carried a penalty writes an authoritative zero", out[3].amendBurnPenalty, 0)
  T.eq("F905 J8: marked KNOWN by the owner, not derived from presence", out[3].amendBurnKnown, true)
end

do
  local good = B.serializeFields({ [3] = bridgeField({ amendBurnPenalty = 0.42 }), [5] = bridgeField() })
  local longer = {}
  for i, val in ipairs(good) do longer[i] = val end
  longer[#longer + 1] = 7
  local shorter = {}
  for i = 1, #good - 1 do shorter[i] = good[i] end
  local _, okLong = B.deserializeFields(longer)
  local _, okShort = B.deserializeFields(shorter)
  T.eq("F905 J9: an array longer than the walk expects is flagged", okLong, false)
  T.eq("F905 J10: an array shorter than the walk expects is flagged", okShort, false)
  local _, okNil = B.deserializeFields(nil)
  T.eq("F905 J11: a non-table is flagged", okNil, false)

  -- _onReadState refuses whole: no field is written on a misaligned array.
  local savedMgr = g_SoilFertilityManager
  local existing = { nitrogen = 1, amendBurnPenalty = 0.10, amendBurnKnown = true }
  local soilSys = { fieldData = { [3] = existing } }
  g_SoilFertilityManager = { soilSystem = soilSys }
  B._onReadState(longer)
  T.eq("F905 J12: a misaligned array writes NO field (the client keeps its last good copy)",
       soilSys.fieldData[3] == existing and soilSys.fieldData[5] == nil, true)
  B._onReadState(good)
  T.ok("F905 J13: a well-formed array is applied", soilSys.fieldData[3] ~= existing and soilSys.fieldData[5] ~= nil)
  T.near("F905 J14: and the pair landed on the client record", soilSys.fieldData[3].amendBurnPenalty, 0.42, EPS)
  T.eq("F905 J15: known", soilSys.fieldData[3].amendBurnKnown, true)
  g_SoilFertilityManager = savedMgr
end

-- =====================================================================
-- GROUP K: THE REAL PUBLISHER. getFieldInfo publishes the owner test or the delivered flag.
-- =====================================================================

local function pubSys(fieldOver)
  local field = { nitrogen = 40, phosphorus = 30, potassium = 50, pH = 6.5, organicMatter = 3,
                  weedPressure = 0, pestPressure = 0, diseasePressure = 0, lastCrop = "wheat",
                  lastHarvest = 0, rotationBonusDaysLeft = 0, diseaseDiscovered = false }
  for k, val in pairs(fieldOver or {}) do field[k] = val end
  local s = setmetatable({
    fieldData = { [1] = field },
    settings  = { enabled = false, diseasePressure = true },
  }, { __index = SoilFertilitySystem })
  s._getFieldPolyVerts = function() return nil end
  return s
end

do
  local savedServer = g_server
  g_server = nil
  local info = pubSys({}):getFieldInfo(1)
  T.eq("F905 K1: a client record with no delivered flag publishes NOT known", info.amendBurnKnown, false)
  T.eq("F905 K2: and the number stays the arithmetic zero every consumer already reads", info.amendBurnPenalty, 0)
  info = pubSys({ amendBurnPenalty = 0.30, amendBurnKnown = true }):getFieldInfo(1)
  T.eq("F905 K3: a client that received the pair publishes known", info.amendBurnKnown, true)
  T.near("F905 K4: with the delivered number", info.amendBurnPenalty, 0.30, EPS)
  g_server = {}
  info = pubSys({}):getFieldInfo(1)
  T.eq("F905 K5: the owner (server, single player included) publishes a never-limed field as KNOWN", info.amendBurnKnown, true)
  T.eq("F905 K6: zero", info.amendBurnPenalty, 0)
  g_server = savedServer
end

-- =====================================================================
-- GROUP L: THE FIVE SURFACES ON REAL SOURCE, one table of triples through all of them.
-- =====================================================================

local savedMgr2 = g_SoilFertilityManager
g_SoilFertilityManager = { settings = {} }
local hud = setmetatable({}, { __index = SoilHUD })

local function infoOf(known, pen, risk)
  return { amendBurnKnown = known, amendBurnPenalty = pen, amendBurnRisk = risk,
           nitrogen = { value = 60, status = "Good" }, phosphorus = { value = 60, status = "Good" },
           potassium = { value = 60, status = "Good" },
           pH = 6.5, organicMatter = 3, weedPressure = 0, pestPressure = 0, diseasePressure = 0,
           fieldArea = 1, lastCrop = "wheat" }
end

local function hasBurnRiskLine(info)
  for _, l in ipairs(hud:buildFieldInfoLines(info)) do
    if l.label == "sf_fieldinfo_burn_risk" then return true end
  end
  return false
end

-- The canonical table: known, penalty, risk -> rows, pct row, risk row
local TABLE = {
  { true,  0.42, true,  1, true,  false, "known burn" },
  { true,  0,    true,  1, false, true,  "known zero at risk" },
  { true,  0,    false, 0, false, false, "known zero not at risk" },
  { false, 0,    true,  0, false, false, "not known, at risk" },
  { false, 0.42, true,  0, false, false, "not known, stale number" },
}
for _, row in ipairs(TABLE) do
  local known, pen, risk, rows, pctRow, riskRow, label = row[1], row[2], row[3], row[4], row[5], row[6], row[7]
  local info = infoOf(known, pen, risk)
  T.eq("F905 L rows (" .. label .. ")", hud:getDetailRowCount(info), rows)
  T.eq("F905 L field-info risk line (" .. label .. ")", hasBurnRiskLine(info), riskRow)
  -- The merge of a single member is the member itself; a two-member group of this
  -- member and a known-zero sibling must agree with the single-field verdict.
  local merged = RfPdaSoilMerge.aggregateInfo({ info, infoOf(true, 0, false) })
  T.eq("F905 L merged known (" .. label .. ")", merged.amendBurnKnown, known)
  T.near("F905 L merged penalty (" .. label .. ")", merged.amendBurnPenalty, known and pen or 0, EPS)
  local ep, er = surfaces(merged.amendBurnKnown, merged.amendBurnPenalty, merged.amendBurnRisk)
  T.eq("F905 L merged pct row agrees (" .. label .. ")", ep, pctRow)
  T.eq("F905 L merged risk row agrees (" .. label .. ")", er, riskRow)
end

do
  local merged = RfPdaSoilMerge.aggregateInfo({ infoOf(true, 0.10, false), infoOf(true, 0.30, true) })
  T.near("F905 L1: the grouped penalty is the worst known member, not an average", merged.amendBurnPenalty, 0.30, EPS)
  merged = RfPdaSoilMerge.aggregateInfo({ infoOf(true, 0.30, false), infoOf(false, 0, true) })
  T.eq("F905 L2: one not-known member makes the group not known", merged.amendBurnKnown, false)
  T.eq("F905 L3: and the group publishes no penalty it cannot stand behind", merged.amendBurnPenalty, 0)
end

-- The HUD update text pair, driven through the real update body's burn block is heavy;
-- the row counter and the field-info line above are the two real guards the brief
-- names besides it, and the treatment tip below is the fifth surface.
do
  local savedI18n = g_i18n
  local function tipFor(info)
    g_SoilFertilityManager = {
      settings = {},
      soilSystem = { getFieldInfo = function() return info end },
    }
    return SoilTreatmentRates.buildNextStepLine(1) or ""
  end
  local function lowPh(known, pen, risk)
    local i = infoOf(known, pen, risk)
    i.pH = 5.2
    i.nitrogen = { value = 90 }; i.phosphorus = { value = 90 }; i.potassium = { value = 90 }
    i.fieldArea = 1
    return i
  end
  local function hasWait(body) return body:find("rf_pda_treat_burn_amend", 1, true) ~= nil or body:find("Wait:", 1, true) ~= nil end
  T.eq("F905 L4: the tip warns on a known zero at risk (today's behaviour on a host)", hasWait(tipFor(lowPh(true, 0, true))), true)
  T.eq("F905 L5: the tip is silent once a KNOWN burn exists (no more 'wait' on a scorched crop)", hasWait(tipFor(lowPh(true, 0.42, true))), false)
  T.eq("F905 L6: the tip is silent on a client that does not know", hasWait(tipFor(lowPh(false, 0, true))), false)
  T.eq("F905 L7: the tip is silent when not at risk", hasWait(tipFor(lowPh(true, 0, false))), false)
  g_i18n = savedI18n
end

g_SoilFertilityManager = savedMgr2
