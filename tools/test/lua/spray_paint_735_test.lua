-- spray_paint_735_test.lua - #735/#762 spray painting on the value maps (RSF-762).
--   Painting moved out of markBoomCells into paintBoomStrip as a swept ADDITIVE
--   QUAD: each frame paints the parallelogram between the last PAINTED boom line
--   and the current one, then advances the anchor. Guards the dose math (the same
--   mass-conserving arithmetic as #735, now with the strip's own area as the
--   denominator), the no-stacking shape, the once-per-tick consume, the stale-dose
--   guard, and the self-heal: a tick whose dose guard fails does not advance the
--   anchor, so the next valid tick's quad spans the gap instead of orphaning it.
--   markBoomCells now only marks coverage (pass %, spray trail, zoneData), which
--   this test asserts by counting zero value-map writes from it.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.vmAvailable        = function() return true end
  s._getFieldPolyVerts = function() return nil end   -- polygon unavailable -> count all cells
  s._strips = {}
  s.valueMaps = {
    addPaintStrip = function(_self, key, sx, sz, wx, wz, hx, hz, delta)
      s._strips[#s._strips + 1] = { key = key, sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz, delta = delta }
    end,
  }
  s.fieldData = {}
  return s
end

local function newField(s, fid, area)
  local f = { fieldArea = area, sessionCoverageCells = {}, dailyCoverageCells = {}, zoneData = {} }
  s.fieldData[fid] = f
  return f
end

-- A 20 m east-west boom line whose travel moves it along +z.
local function line(x, z)
  return { { x = x, z = z }, { x = x + 20, z = z } }
end

local function stashDose(f, dN, area, time)
  f._sprayDose = { dN = dN, dP = 0, dK = 0, dPH = 0, dOM = 0,
                   area = area, time = time or g_currentMission.time, product = "FERT" }
end

-- strip area (m2) from the parallelogram corners: |(w-s) x (h-s)|
local function stripArea(sx, sz, wx, wz, hx, hz)
  return math.abs((wx - sx) * (hz - sz) - (wz - sz) * (hx - sx))
end

-- ── seed frame: dose math, mass conservation, no field-average repaint ──
do
  local s = newSys()
  local area = 0.003        -- this tick's covered area, hectares
  local f = newField(s, 1, 8.0)
  local DN = 0.03           -- this tick's field-average N delta, as applyFertilizer would stash
  stashDose(f, DN, area)

  s:paintBoomStrip(1, line(105, 105), "FERT")

  T.eq("762: one strip painted on the seed frame", #s._strips, 1)
  T.eq("762: seed paints only the nitrogen layer (others were 0)", s._strips[1].key, "nitrogen")

  local st = s._strips[1]
  local areaHa = stripArea(st.sx, st.sz, st.wx, st.wz, st.hx, st.hz) / 10000
  -- mass conservation: delta * stripAreaHa == dN * coveredArea
  T.near("762: seed dose conserves the tick's nutrient mass", st.delta * areaHa, DN * area, 1e-9)
  -- the local dose is per-strip, not the drifting field average
  T.ok("762: the painted dose is the local dose, not the field average", st.delta > DN)
end

-- ── swept quad: the second frame paints between the two lines, no stacking ──
do
  local s = newSys()
  local area = 0.004
  local f = newField(s, 1, 8.0)
  stashDose(f, 0.03, area)
  s:paintBoomStrip(1, line(105, 105), "FERT")   -- seed at line z=105
  stashDose(f, 0.03, area)                      -- next tick, next frame
  s:paintBoomStrip(1, line(105, 107), "FERT")   -- boom advanced 2 m

  T.eq("762: two frames paint two strips", #s._strips, 2)
  local st = s._strips[2]
  -- the quad's base is the PREVIOUS painted line, so it spans prev->cur with no gap
  T.eq("762: quad start is the previous line's start", st.sx, 105)
  T.eq("762: quad start z is the previous line's z", st.sz, 105)
  T.eq("762: quad width is the previous line's end", st.wx, 125)
  T.near("762: quad height is the current line's start", st.hz, 107, 1e-6)
  local areaHa = stripArea(st.sx, st.sz, st.wx, st.wz, st.hx, st.hz) / 10000
  T.near("762: quad dose conserves the tick's nutrient mass", st.delta * areaHa, 0.03 * area, 1e-9)
end

-- ── self-heal: a failed tick does not advance the anchor; the next spans the gap ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  stashDose(f, 0.03, 0.003)
  s:paintBoomStrip(1, line(105, 105), "FERT")   -- valid seed, anchor -> z=105
  stashDose(f, 0.03, 0.003, g_currentMission.time - 1)  -- stale dose: no paint, no advance
  s:paintBoomStrip(1, line(105, 108), "FERT")
  stashDose(f, 0.03, 0.004)
  s:paintBoomStrip(1, line(105, 110), "FERT")   -- valid again: quad spans 105->110

  T.eq("762: stale frame painted nothing", #s._strips, 2)
  local st = s._strips[2]
  -- the gap frame starts at the ORIGINAL anchor (z=105), not the skipped line (z=108)
  T.eq("762: self-heal - quad spans from the last PAINTED line", st.sz, 105)
  T.near("762: self-heal - quad reaches the current line", st.hz, 110, 1e-6)
end

-- ── consume-once: two hook sites in the same tick paint once ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  stashDose(f, 0.03, 0.003)
  s:paintBoomStrip(1, line(105, 105), "FERT")   -- first hook site paints + consumes
  s:paintBoomStrip(1, line(105, 105), "FERT")   -- second hook site same tick: dose spent
  T.eq("762: dose consumed in-tick, second hook site paints nothing", #s._strips, 1)
end

-- ── stale dose from a previous tick is never painted, anchor untouched ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  f._sprayDose = { dN = 0.03, dP = 0, dK = 0, dPH = 0, dOM = 0,
                   area = 0.003, time = g_currentMission.time - 1, product = "FERT" }
  s:paintBoomStrip(1, line(105, 105), "FERT")
  T.eq("762: a stale (previous-tick) dose is never painted", #s._strips, 0)
  T.eq("762: a stale dose does not advance the anchor", f._vmLastBoomLine, nil)
end

-- ── no dose stashed -> nothing paints ──
do
  local s = newSys()
  newField(s, 1, 8.0)
  s:paintBoomStrip(1, line(105, 105), "FERT")
  T.eq("762: no spray dose -> paintBoomStrip paints nothing", #s._strips, 0)
end

-- ── markBoomCells is coverage-only now: zero value-map writes ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  stashDose(f, 0.03, 0.003)
  s:markBoomCells(1, line(105, 105), true)
  T.eq("762: markBoomCells paints nothing (painting moved to paintBoomStrip)", #s._strips, 0)
  T.ok("762: markBoomCells still marks coverage",
       next(f.sessionCoverageCells) ~= nil)
end
