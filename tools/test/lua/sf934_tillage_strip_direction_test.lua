-- sf934_tillage_strip_direction_test.lua - #934 tillage NPK flipping with travel direction.
--   The old vmLocalBump called SoilValueMaps:addValueAtWorld, a read-modify-SET: it
--   sampled ONE pixel under the implement root, added the delta, then stamped that
--   single result flat across a CELL_SIZE square. The square is wider than most
--   implements, so neighbouring passes overlapped and each pass copied its own
--   sampled pixel over the overlap. Driving back down the same track sampled a
--   different neighbour, so an unchanged POSITIVE delta could stamp the square DOWN:
--   N and K fell on one pass and rose on the next.
--
--   The contract this bench locks: every tillage write is ADDITIVE (addPaintStrip,
--   never addValueAtWorld), it follows the worked line rather than a fixed square,
--   consecutive ticks span the swept quad, the delta keeps the caller's sign in BOTH
--   travel directions, and every fallback (first tick, reversal, teleport, field
--   change, missing work line) is additive too - a point-write fallback would keep
--   the flattening stamp alive on exactly the ticks this bug appears on.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local painted, stamped

-- A soil system whose value maps record which primitive was used. addValueAtWorld is
-- present on purpose: the bench has to be able to SEE the destructive stamp if it
-- ever comes back, not just miss a call that was silently dropped.
local function newSystem(fieldId)
  painted, stamped = {}, {}
  local sys = setmetatable({
    _lastTillageFieldId = fieldId,
    valueMaps = {
      addPaintStrip = function(_vm, key, sx, sz, wx, wz, hx, hz, delta)
        painted[#painted + 1] = { key = key, sx = sx, sz = sz, wx = wx, wz = wz,
                                  hx = hx, hz = hz, delta = delta }
        return 1
      end,
      addValueAtWorld = function(_vm, key)
        stamped[#stamped + 1] = key
      end,
    },
  }, { __index = SoilFertilitySystem })
  sys.vmAvailable = function() return true end
  return sys
end

-- The Nth recorded paint, or an empty stand-in. A regression that stops painting
-- should fail these assertions cleanly rather than crash on a nil index.
local function P(i)
  return painted[i] or {}
end

-- Lateral span of a painted quad, -1 when the paint never happened.
local function span(p)
  if p == nil or p.sx == nil then return -1 end
  return p.wx - p.sx
end

-- Parallelogram area, the same 2D cross the painter uses. Returns -1 for a paint
-- that never happened, so the area assertions report a mismatch instead of erroring.
local function quadArea(p)
  if p == nil or p.sx == nil then return -1 end
  return math.abs((p.wx - p.sx) * (p.hz - p.sz) - (p.wz - p.sz) * (p.hx - p.sx))
end

-- The per-pixel delta the painter should hand the strip for a given quad area:
-- the caller's per-cell delta spread over the strip's own area (mass conserving).
local function expectedDelta(perCellDelta, areaM2)
  return perCellDelta * (SoilConstants.ZONE.CELL_AREA_HA / (areaM2 / 10000))
end

-- A 6 m implement, its work line running across the direction of travel.
local function lineAt(z) return { ax = 0, az = z, bx = 6, bz = z } end

-- ── First tick of a pass: seeds a thin strip, ADDITIVELY ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)

  T.eq("934: the first tick paints", #painted, 1)
  T.eq("934: the first tick NEVER stamps a sampled pixel", #stamped, 0)
  T.eq("934: it paints the caller's layer", P(1).key, "nitrogen")
  -- Seed strip: half-thickness max(0.5, 6*0.02) = 0.5 either side of the line.
  T.near("934: seed strip starts half a thickness behind the line", P(1).sz or 0, -0.5, 1e-9)
  T.near("934: seed strip ends half a thickness ahead of the line", P(1).hz or 0, 0.5, 1e-9)
  T.near("934: seed strip spans the full 6 m working width", span(P(1)), 6, 1e-9)
  T.near("934: seed area is width x thickness", quadArea(P(1)), 6, 1e-9)
end

-- ── Second tick: spans the swept quad between the two worked lines ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys._lastTillageLine = lineAt(3)          -- advanced 3 m along travel
  sys:vmLocalBump(3, 3, { nitrogen = 2 }, 5)

  local q = P(2)
  T.eq("934: the second tick paints additively too", #painted, 2)
  T.eq("934: still no stamp", #stamped, 0)
  T.near("934: quad base is the PREVIOUS worked line (start)", q.sz or -1, 0, 1e-9)
  T.near("934: quad base spans the working width", span(q), 6, 1e-9)
  T.near("934: quad travel edge is the CURRENT line", q.hz or 0, 3, 1e-9)
  T.near("934: swept area is width x travel", quadArea(q), 18, 1e-9)
  T.near("934: delta is the per-cell amount spread over the swept area",
         q.delta or 0, expectedDelta(2, 18), 1e-9)
end

-- ── THE BUG: reversing direction must not reverse the sign ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)   -- seed
  sys._lastTillageLine = lineAt(3)
  sys:vmLocalBump(3, 3, { nitrogen = 2 }, 5)   -- up the field
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)   -- back down the same track

  T.eq("934: three ticks, three additive paints", #painted, 3)
  T.eq("934: no stamp on any pass, in either direction", #stamped, 0)
  T.ok("934: the delta stays POSITIVE driving up the field", (P(2).delta or 0) > 0)
  T.ok("934: the delta stays POSITIVE driving back down", (P(3).delta or 0) > 0)
  T.near("934: the same pass in the opposite direction gets the same magnitude",
         P(3).delta or 0, P(2).delta or -1, 1e-9)
  T.near("934: the return quad sweeps the same area, not a bigger one",
         quadArea(P(3)), 18, 1e-9)
end

-- ── A negative delta stays negative (oxidation loses OM in both directions) ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { organicMatter = -1 }, 5)
  sys._lastTillageLine = lineAt(3)
  sys:vmLocalBump(3, 3, { organicMatter = -1 }, 5)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { organicMatter = -1 }, 5)

  T.ok("934: a loss stays a loss driving up", (P(2).delta or 0) < 0)
  T.ok("934: a loss stays a loss driving back", (P(3).delta or 0) < 0)
end

-- ── Teleport: never span the gap, seed a fresh strip ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys._lastTillageLine = lineAt(100)        -- 100 m in one tick, far past 3x the width
  sys:vmLocalBump(3, 100, { nitrogen = 2 }, 5)

  T.near("934: a teleport seeds a thin strip, not a 100 m quad",
         quadArea(P(2)), 6, 1e-9)
  T.eq("934: a teleport still never stamps", #stamped, 0)
end

-- ── Standing still: no forward progress seeds rather than painting a zero quad ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys._lastTillageLine = { ax = 0, az = 0.001, bx = 6, bz = 0.001 }   -- 1 mm of travel
  sys:vmLocalBump(3, 0.001, { nitrogen = 2 }, 5)

  T.near("934: a stationary tick seeds instead of painting a degenerate quad",
         quadArea(P(2)), 6, 1e-9)
end

-- ── Field change: a pass on one field never links to another ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys._lastTillageFieldId = 8               -- next field, same geometry
  sys._lastTillageLine = lineAt(3)
  sys:vmLocalBump(3, 3, { nitrogen = 2 }, 5)

  T.near("934: a new field seeds its own strip, it does not sweep from field 7",
         quadArea(P(2)), 6, 1e-9)
end

-- ── No work line at all: an additive square, still never a stamp ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = nil
  sys:vmLocalBump(10, 10, { nitrogen = 2 }, 5)

  T.eq("934: a missing work line still paints", #painted, 1)
  T.eq("934: a missing work line still never stamps", #stamped, 0)
  T.near("934: the fallback square uses the caller's radius as a half-span",
         span(P(1)), 10, 1e-9)
end

-- ── Degenerate work line (co-located nodes) must not silently paint nothing ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = { ax = 5, az = 5, bx = 5, bz = 5 }
  sys:vmLocalBump(5, 5, { nitrogen = 2 }, 5)

  T.eq("934: a degenerate span falls back rather than dropping the write", #painted, 1)
  T.eq("934: and the fallback is still additive", #stamped, 0)
end

-- ── Two writes in ONE tick share one footprint (residue, then oxidation) ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys._lastTillageLine = lineAt(3)
  sys:vmLocalBump(3, 3, { nitrogen = 2 }, 5)          -- residue incorporation
  sys:vmLocalBump(3, 3, { organicMatter = -1 }, 5)    -- oxidation, same tick

  T.near("934: the same tick paints both writes on the same ground (start)",
         P(3).sz or 0, P(2).sz or -1, 1e-9)
  T.near("934: the same tick paints both writes on the same ground (travel edge)",
         P(3).hz or 0, P(2).hz or -1, 1e-9)
  T.near("934: so the second write is not concentrated onto a reseeded thin strip",
         quadArea(P(3)), quadArea(P(2)), 1e-9)
end

-- ── Mass conservation: a wider sweep dilutes the same per-cell delta ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys._lastTillageLine = lineAt(3)
  sys:vmLocalBump(3, 3, { nitrogen = 2 }, 5)          -- 18 m2 sweep

  local sys2 = newSystem(7)
  sys2._lastTillageLine = lineAt(0)
  sys2:vmLocalBump(3, 0, { nitrogen = 2 }, 5)
  sys2._lastTillageLine = lineAt(6)
  sys2:vmLocalBump(3, 6, { nitrogen = 2 }, 5)         -- 36 m2 sweep, twice the ground
  local wide = P(2)

  T.near("934: twice the swept area carries half the per-pixel delta",
         (wide.delta or 0) * 2, expectedDelta(2, 18), 1e-9)
  T.near("934: the wide sweep really is twice the area", quadArea(wide), 36, 1e-9)
end

-- ── A zero delta writes nothing at all ──
do
  local sys = newSystem(7)
  sys._lastTillageLine = lineAt(0)
  sys:vmLocalBump(3, 0, { nitrogen = 0 }, 5)
  T.eq("934: a zero delta paints nothing", #painted, 0)
  T.eq("934: a zero delta stamps nothing", #stamped, 0)
end
