-- sf_application_dot_delta_test.lua: the narrow-tool application dot ADDS this
-- tick's delta over its 5 m square instead of SETTING the field scalar there.
--
-- Drives the REAL applyFertilizer with a value-map stand-in that records every
-- additive write (addPaintStrip) and every stamp (writeValueAtWorld). The defect
-- was the second kind: the dot wrote field.nitrogen over a 5 m square through an
-- unfiltered set, levelling every pixel there to the field average and erasing the
-- per-pixel record the boom strip had built. The repair routes the dot through the
-- strip's own additive primitive with the same expression the scalar update uses.
--
-- What this bar does NOT prove: density-map execution (the primitive is a stand-in),
-- the dose MAGNITUDE (the field-average delta on a 25 m2 square is carried from the
-- pH dot and is a MAINTENANCE item), or seeding (none, like the strip: the birth
-- seeder covers the field polygon and the primitive skips unrecorded pixels).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local PROFILES = SoilConstants.FERTILIZER_PROFILES
local RR  = SoilConstants.DIFFICULTY.REPLENISHMENT_MULTIPLIERS[3]   -- settings.replenishmentRate = 3
local TUN = SoilConstants.TUNING.RATE_MULT[3]                        -- getTuningMult default index

-- Fill-type indices are fixtures; the names are the shipped profile keys.
local FT_FERT, FT_MANURE, FT_LIME, FT_TEST = 21, 22, 23, 24
local NAMES = { [FT_FERT] = "FERTILIZER", [FT_MANURE] = "MANURE", [FT_LIME] = "LIME", [FT_TEST] = "DOT_TEST" }

local savedFTM = g_fillTypeManager
g_fillTypeManager = {
  getFillTypeByIndex = function(_, idx)
    local n = NAMES[idx]
    return n and { name = n, index = idx } or nil
  end,
}
-- A synthetic profile with one ZERO coefficient, so a layer must be skipped, and OM present.
PROFILES.DOT_TEST = { N = 10, P = 0, K = 5, OM = 2 }

local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings  = { enabled = true, replenishmentRate = 3, showNotifications = false }
  s.fieldData = {}
  s._strips, s._stamps = {}, {}
  s.valueMaps = {
    available = true,
    addPaintStrip = function(_self, key, sx, sz, wx, wz, hx, hz, delta)
      s._strips[#s._strips + 1] = { key = key, sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz, delta = delta }
      return delta
    end,
    writeValueAtWorld = function(_self, key, x, z, value, r)
      s._stamps[#s._stamps + 1] = { key = key, x = x, z = z, value = value, r = r }
    end,
  }
  return s
end

local function newField(s, fid, areaHa)
  local f = {
    fieldArea = areaHa, _farmlandAreaConfirmed = true,
    -- not a new session, so applyFertilizer's area re-resolution is skipped
    sessionCoverageCells = { seeded = true },
    nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.5,
  }
  s.fieldData[fid] = f
  return f
end

local function at(t) g_currentMission.time = t end
local function strips(s, key)
  local out = {}
  for _, st in ipairs(s._strips) do if st.key == key then out[#out + 1] = st end end
  return out
end
-- The scalar update's own expression: entry.X * ((liters / 1000) / areaInHa * rrMult) * tunFert
local function factorFor(liters, areaHa) return (liters / 1000) / areaHa * RR * TUN end

-- =====================================================================
-- GROUP A: one narrow-tool tick. Additive, this tick's delta, the same square.
-- =====================================================================
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 100, 200
  at(5000)
  local n0 = f.nitrogen
  s:applyFertilizer(1, FT_FERT, 2.0, nil)

  T.eq("DOT A1: no field-scalar stamp reaches the map (writeValueAtWorld never called)", #s._stamps, 0)
  T.eq("DOT A2: three additive writes, one per FERTILIZER layer", #s._strips, 3)
  local fac = factorFor(2.0, 4.0)
  local n = strips(s, "nitrogen")[1]
  T.ok("DOT A3: the nitrogen layer is written", n ~= nil)
  T.near("DOT A4: the nitrogen delta is this tick's field-average delta, entry.N * factor * tunFert",
         n.delta, PROFILES.FERTILIZER.N * fac, 1e-9)
  T.near("DOT A5: the painted delta equals the scalar's own increment this tick", n.delta, f.nitrogen - n0, 1e-9)
  T.ok("DOT A6: the delta is not the field scalar the stamp used to write", math.abs(n.delta - f.nitrogen) > 1)
  T.eq("DOT A7: start corner is (x-2.5, z-2.5)",  n.sx == 97.5  and n.sz == 197.5, true)
  T.eq("DOT A8: width corner is (x+2.5, z-2.5)",  n.wx == 102.5 and n.wz == 197.5, true)
  T.eq("DOT A9: height corner is (x-2.5, z+2.5)", n.hx == 97.5  and n.hz == 202.5, true)
  T.near("DOT A10: phosphorus carries its own coefficient", strips(s, "phosphorus")[1].delta, PROFILES.FERTILIZER.P * fac, 1e-9)
  T.near("DOT A11: potassium carries its own coefficient",  strips(s, "potassium")[1].delta,  PROFILES.FERTILIZER.K * fac, 1e-9)
  T.eq("DOT A12: no pH or OM write for a product without them", #strips(s, "pH") + #strips(s, "organicMatter"), 0)
  local p = strips(s, "phosphorus")[1]
  T.ok("DOT A13: every layer paints the same square", p.sx == n.sx and p.sz == n.sz and p.wx == n.wx and p.hz == n.hz)
end

-- =====================================================================
-- GROUP B: a zero coefficient paints no layer; OM is a layer like the others.
-- =====================================================================
do
  local s = newSys(); newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  s:applyFertilizer(1, FT_TEST, 1.0, nil)
  T.eq("DOT B1: a zero coefficient paints no layer (P = 0 skipped)", #strips(s, "phosphorus"), 0)
  T.eq("DOT B2: N, K and OM painted", #s._strips, 3)
  T.near("DOT B3: organic matter delta is entry.OM * factor * tunFert",
         strips(s, "organicMatter")[1].delta, 2 * factorFor(1.0, 4.0), 1e-9)
  T.eq("DOT B4: no stamp", #s._stamps, 0)
end
do
  local s = newSys(); newField(s, 1, 2.5)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  s:applyFertilizer(1, FT_MANURE, 14.0, nil)
  T.eq("DOT B5: a shipped four-nutrient product (MANURE) paints four layers", #s._strips, 4)
  T.near("DOT B6: MANURE organic matter delta", strips(s, "organicMatter")[1].delta, PROFILES.MANURE.OM * factorFor(14.0, 2.5), 1e-9)
  T.eq("DOT B7: no stamp", #s._stamps, 0)
end

-- =====================================================================
-- GROUP C: a zero-litre tick (every pass's first tick has dt 0) paints nothing.
-- The stamp used to write the scalar regardless of litres.
-- =====================================================================
do
  local s = newSys(); newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  s:applyFertilizer(1, FT_FERT, 0, nil)
  T.eq("DOT C1: a zero-litre tick paints nothing", #s._strips, 0)
  T.eq("DOT C2: and stamps nothing", #s._stamps, 0)
end

-- =====================================================================
-- GROUP D: consecutive ticks are independent adds at their own positions.
-- =====================================================================
do
  local s = newSys(); newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  s:applyFertilizer(1, FT_FERT, 2.0, nil)
  s._lastSprayX, s._lastSprayZ = 10, 12; at(5016)
  s:applyFertilizer(1, FT_FERT, 3.0, nil)
  local ns = strips(s, "nitrogen")
  T.eq("DOT D1: two ticks, two nitrogen squares", #ns, 2)
  T.near("DOT D2: the second square carries only its own tick's delta, not a running total",
         ns[2].delta, PROFILES.FERTILIZER.N * factorFor(3.0, 4.0), 1e-9)
  T.near("DOT D3: the second square sits at the second position", ns[2].sz, 9.5, 1e-9)
  -- Stated, not hidden: the dot has no travel geometry, so consecutive squares
  -- overlap. Overlap-free painting is the strip's job; the dot is the narrow-tool
  -- fallback and its magnitude is a MAINTENANCE item.
  T.ok("DOT D4: consecutive squares overlap (documented shape, not a defect this bar pins)", ns[1].hz > ns[2].sz)
end

-- =====================================================================
-- GROUP E: two sections of one tick (VWW) each paint their OWN call's delta.
-- The tick stash (sd) accumulates for the strip; the dot must not read it.
-- =====================================================================
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  s:applyFertilizer(1, FT_FERT, 2.0, nil)
  s:applyFertilizer(1, FT_FERT, 2.0, nil)   -- second section, same tick
  local ns = strips(s, "nitrogen")
  local one = PROFILES.FERTILIZER.N * factorFor(2.0, 4.0)
  T.eq("DOT E1: two sections in one tick paint twice", #ns, 2)
  T.near("DOT E2: each section paints its own delta, not the tick's accumulated stash", ns[2].delta, one, 1e-9)
  T.near("DOT E3: the stash did accumulate both (the strip, not the dot, owns the tick total)", f._sprayDose.dN, 2 * one, 1e-9)
end

-- =====================================================================
-- GROUP F: the deferral gate is unchanged. The flag is the PREVIOUS tick's.
-- =====================================================================
local function tickWithFlag(flag)
  local s = newSys(); local f = newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  f._vmBoomPaintTime = flag
  s:applyFertilizer(1, FT_FERT, 2.0, nil)
  return s
end
T.eq("DOT F1: a boom paint 100 ms ago defers the dot",              #tickWithFlag(4900)._strips, 0)
T.eq("DOT F2: a boom paint 499 ms ago still defers",                #tickWithFlag(4501)._strips, 0)
T.eq("DOT F3: a boom paint 500 ms ago no longer defers",            #tickWithFlag(4500)._strips, 3)
T.eq("DOT F4: no boom paint yet (a tool's first tick) reaches the dot", #tickWithFlag(nil)._strips, 3)
T.eq("DOT F5: a flag from the future (clock reset) does not defer", #tickWithFlag(5050)._strips, 3)
T.eq("DOT F6: a deferred tick stamps nothing either",               #tickWithFlag(4900)._stamps, 0)

-- =====================================================================
-- GROUP G: no position, or no value maps: nothing painted, scalar still moves.
-- =====================================================================
do
  local s = newSys(); newField(s, 1, 4.0); at(5000)
  s:applyFertilizer(1, FT_FERT, 2.0, nil)
  T.eq("DOT G1: no sprayer position, no dot", #s._strips + #s._stamps, 0)
end
do
  local s = newSys(); local f = newField(s, 1, 4.0); at(5000)
  s._lastSprayX, s._lastSprayZ = 10, 10
  s.valueMaps.available = false
  local n0 = f.nitrogen
  s:applyFertilizer(1, FT_FERT, 2.0, nil)
  T.eq("DOT G2: value maps unavailable, no dot and no error", #s._strips + #s._stamps, 0)
  T.ok("DOT G3: the field scalar still moved", f.nitrogen > n0)
end

-- =====================================================================
-- GROUP H: pH. With the positional writer present the dot goes through it (SF-79,
-- unchanged). Without it, the fallback is the same additive square, no stamp.
-- =====================================================================
do
  local s = newSys(); newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  -- Shadow the writer on the instance so this row does not depend on which files
  -- the harness has loaded: the fallback is the path of a system without it.
  s._applyPHFootprint = false
  s:applyFertilizer(1, FT_LIME, 2.0, nil)
  local ph = strips(s, "pH")
  T.eq("DOT H1: the pH fallback paints one additive square", #ph, 1)
  T.near("DOT H2: with this tick's delta, not the field pH", ph[1].delta, PROFILES.LIME.pH * factorFor(2.0, 4.0), 1e-9)
  T.eq("DOT H3: on the same 5 m square", ph[1].sx == 7.5 and ph[1].hz == 12.5, true)
  T.eq("DOT H4: and never the stamp", #s._stamps, 0)
end
do
  local s = newSys(); newField(s, 1, 4.0)
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  local savedPH = PositionalPH
  PositionalPH = PositionalPH or { OP_DELTA = "delta", SCOPE_POINT = "point" }
  local OPD, SCP = PositionalPH.OP_DELTA, PositionalPH.SCOPE_POINT
  local calls = {}
  s._applyPHFootprint = function(_self, fid, req) calls[#calls + 1] = req; return {} end
  s._phRefreshScalar  = function() end
  s:applyFertilizer(1, FT_LIME, 2.0, nil)
  PositionalPH = savedPH
  T.eq("DOT H5: with the positional writer present the pH dot goes through it", #calls, 1)
  T.eq("DOT H6: as a point delta at the sprayer position",
       calls[1].operation == OPD and calls[1].scope == SCP and calls[1].x == 10 and calls[1].z == 10, true)
  T.near("DOT H7: carrying the same expression", calls[1].value, PROFILES.LIME.pH * factorFor(2.0, 4.0), 1e-9)
  T.eq("DOT H8: and the pH strip primitive is not also written", #strips(s, "pH"), 0)
  T.eq("DOT H9: no stamp", #s._stamps, 0)
end

-- =====================================================================
-- GROUP J: at the scalar ceiling the dot still adds the tick's delta. Per-pixel
-- saturation belongs to the primitive, exactly as for the strip (SF-30).
-- =====================================================================
do
  local s = newSys(); local f = newField(s, 1, 4.0)
  f.nitrogen = SoilConstants.NUTRIENT_LIMITS.MAX
  s._lastSprayX, s._lastSprayZ = 10, 10; at(5000)
  s:applyFertilizer(1, FT_FERT, 2.0, nil)
  T.eq("DOT J1: the scalar stays clamped at the ceiling", f.nitrogen, SoilConstants.NUTRIENT_LIMITS.MAX)
  T.near("DOT J2: the dot still adds the unclamped tick delta (the primitive saturates per pixel)",
         strips(s, "nitrogen")[1].delta, PROFILES.FERTILIZER.N * factorFor(2.0, 4.0), 1e-9)
end

PROFILES.DOT_TEST = nil
g_fillTypeManager = savedFTM
