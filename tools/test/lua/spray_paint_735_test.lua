-- spray_paint_735_test.lua - #735 per-cell spray painting on the value maps.
--   markBoomCells paints each newly-covered cell with the correct LOCAL dose (the
--   field-average delta applyFertilizer stashed, scaled up by fieldArea / the area
--   covered this tick), exactly once per session. A uniform pass then shows a uniform
--   result instead of the reported false low->high gradient (red where you started,
--   green where you finished, because the running field average drifts up mid-pass).
--   Guards the dose math, the once-per-cell dedup, the per-tick consume, and the guards
--   that keep a stale or absent dose from painting.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local CELL_HA = SoilConstants.ZONE.CELL_AREA_HA   -- 0.01 ha per 10 m cell

local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.vmAvailable        = function() return true end
  s._getFieldPolyVerts = function() return nil end   -- polygon unavailable -> count all cells
  s._adds = {}
  s.valueMaps = {
    addValueAtWorld = function(_self, key, x, z, delta, _r)
      s._adds[#s._adds + 1] = { key = key, x = x, z = z, delta = delta }
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

-- three points in three distinct 10 m cells
local function threePts()
  return { { x = 105, z = 105 }, { x = 115, z = 105 }, { x = 125, z = 105 } }
end

local function stashDose(f, dN, area)
  f._sprayDose = { dN = dN, dP = 0, dK = 0, dPH = 0, dOM = 0,
                   area = area, time = g_currentMission.time, product = "FERT" }
end

-- ── dose math + uniformity ──────────────────────────────────
do
  local s = newSys()
  local area = 10.0
  local f = newField(s, 1, area)
  local DN = 0.03   -- this tick's field-average N delta, as applyFertilizer would stash
  stashDose(f, DN, area)

  s:markBoomCells(1, threePts(), true)

  T.eq("735: one N add per newly-covered cell", #s._adds, 3)
  local expect = DN * (area / (3 * CELL_HA))
  T.near("735: per-cell dose = avg delta x fieldArea/coveredArea", s._adds[1].delta, expect, 1e-6)
  T.ok("735: a uniform pass paints every covered cell the SAME (no gradient)",
       s._adds[1].delta == s._adds[2].delta and s._adds[2].delta == s._adds[3].delta)
  T.ok("735: the local dose is much larger than the drifting field-average delta",
       s._adds[1].delta > DN)
  local allN = true
  for _, a in ipairs(s._adds) do if a.key ~= "nitrogen" then allN = false end end
  T.ok("735: only the nitrogen layer is painted (dP/dK/dPH/dOM were 0)", allN)
end

-- ── dedup: re-covering the same cells this session does not repaint ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  stashDose(f, 0.02, 8.0)
  s:markBoomCells(1, threePts(), true)
  T.eq("735: first pass paints the three cells", #s._adds, 3)
  s:markBoomCells(1, threePts(), true)   -- same cells, still same session
  T.eq("735: re-covering the same cells adds nothing (once-per-cell dedup)", #s._adds, 3)
end

-- ── consume: a second call THIS tick with NEW cells does not double-apply ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  stashDose(f, 0.02, 8.0)
  s:markBoomCells(1, threePts(), true)
  T.eq("735: first hook site paints", #s._adds, 3)
  s:markBoomCells(1, { { x = 205, z = 205 }, { x = 215, z = 205 } }, true)  -- new cells, dose spent
  T.eq("735: dose consumed in-tick, second hook site paints nothing", #s._adds, 3)
end

-- ── stale dose from a previous tick is never painted ──
do
  local s = newSys()
  local f = newField(s, 1, 8.0)
  f._sprayDose = { dN = 0.02, dP = 0, dK = 0, dPH = 0, dOM = 0,
                   area = 8.0, time = g_currentMission.time - 1, product = "FERT" }  -- old tick
  s:markBoomCells(1, threePts(), true)
  T.eq("735: a stale (previous-tick) dose is never painted", #s._adds, 0)
end

-- ── no dose stashed -> display-only markBoomCells paints nothing ──
do
  local s = newSys()
  newField(s, 1, 8.0)
  s:markBoomCells(1, threePts(), true)
  T.eq("735: no spray dose -> markBoomCells paints nothing", #s._adds, 0)
end
