-- SF-2m-nutrient_whole_pixel_dose_entry_test.lua: one fertilizer pass gives each
-- pixel one pass's dose of N, P, K and organic matter.
--
-- THE REPORT (Tyson's screenshot, Soil Layers, Nitrogen): stripes along the
-- driving direction. Each sprayer tick moves the boom a few centimetres, and a
-- value-map pixel is about 2 m. paintBoomStrip handed each tick's N/P/K/OM to
-- addPaintStrip as a delta over that tick's thin quad (or, under 5 cm of travel,
-- a 1 m seed strip), so a pixel took a varying number of tick doses depending on
-- how quads happened to land on it.
--
-- THE FIX (#1125's pH pass write, given to N/P/K/OM: _nutrientPassStrip). The
-- pass keeps its own anchor (field._nutrientPass), apart from pH's. A tick with
-- too little travel carries its dose; a tick that closes a quad writes the
-- carried dose's density, once, to each pixel whose CENTRE lies in the quad,
-- through a square half a pixel wide inside it. Successive quads tile the pass,
-- so each pixel gets one dose, for all four keys together.
--
-- THE ROUNDING ADDENDUM (Tyson, 2026-10-16). addPaintStrip floors its raw delta
-- toward zero, so every pass under-applied by up to one raw step per pixel (P and
-- K about 14% for compost at 1.0x). _nutrientPassStrip now adds half a raw step
-- away from zero before the write, turning that floor into round-to-nearest. The
-- raster's own vm:getLayerEntry returns the real per-key def (minVal/maxVal) so
-- this rounding is actually exercised rather than skipped by a nil def.
--
-- THE ENTRY-POINT BAR (R-18). Every tick runs the REAL onFertilizerApplied, then
-- the REAL paintBoomStrip at the same time, the order the sprayer hook uses,
-- through the REAL _nutrientPassStrip. addPaintStrip itself is MODELLED on the
-- raster, not the real engine: production's addPaintStrip (SoilValueMaps.lua)
-- converts a semantic delta to raw steps via rawDelta = floor(delta / unitsPerRaw)
-- toward zero (unitsPerRaw = (maxVal - minVal) / 254), skips any pixel at raw 0
-- ("no data"), and clamps the add at RAW_MAX -- that arithmetic is reproduced here
-- exactly (read from SoilValueMaps.lua:773-838), but WHICH pixels a parallelogram
-- reaches is not documented anywhere (decompile, LUADOC, the references), so the
-- raster runs both fill readings, as SF-1098's pH bar does: a pixel is written
-- when its CENTRE is inside the parallelogram, or when the parallelogram TOUCHES
-- it with any area. The fix has to hold under both. The raster's geometry (hull,
-- centre/touch test) is the bench's own code, never PositionalPH's or
-- SoilValueMaps', so it cannot agree with production by sharing a helper.
--
-- Groups: E the entry (squares not strips, pH untouched), A a pass under the
-- centre rule, B the same under the touch rule, C slow travel, D fast travel, K
-- quad edges exactly on pixel centres, R an angled pass, S a stop mid-pass, G a
-- pause and resume, J a jump, P a product change, DOT the narrow-tool dot, F the
-- PositionalPH-absent fallback, Q the written squares.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group crashed]", false, tostring(err)) end
end

local saved = { g_server = g_server, g_fillTypeManager = g_fillTypeManager,
  g_sprayTypeManager = g_sprayTypeManager, g_farmlandManager = g_farmlandManager,
  time = g_currentMission.time, print = print }
g_server = true
g_farmlandManager = nil
FillType = FillType or { UNKNOWN = 0 }

-- Fill types: COMPOST and BIOSOLIDS as FERTILIZER_PROFILES carries them (dry
-- products; a flat 0.001 t/L = 1 kg/L density, same stub convention SF-1098 uses
-- for LIME). Both carry N, P, K and organic matter (Constants.lua:621/622).
-- LIME is kept only for the E group's pH-regression probe.
local FT = {
  COMPOST   = { name = "COMPOST",   index = 5, massPerLiter = 0.001 },
  BIOSOLIDS = { name = "BIOSOLIDS", index = 6, massPerLiter = 0.001 },
  LIME      = { name = "LIME",      index = 3, massPerLiter = 0.001 },
}
local BY_INDEX = { [3] = FT.LIME, [5] = FT.COMPOST, [6] = FT.BIOSOLIDS }
g_fillTypeManager = {
  getFillTypeByName      = function(_s, n) return FT[n] end,
  getFillTypeByIndex     = function(_s, i) return BY_INDEX[i] end,
  getFillTypeIndexByName = function(_s, n) return FT[n] and FT[n].index end,
}
local LIME_ST = { name = "LIME", index = 1, fillType = "LIME", isLime = true, litersPerSecond = 0.09 }
g_sprayTypeManager = {
  getSprayTypeByName          = function(_s, n) return n and string.upper(n) == "LIME" and LIME_ST or nil end,
  getSprayTypeByIndex         = function(_s, i) return i == 1 and LIME_ST or nil end,
  getSprayTypeByFillTypeIndex = function(_s, i) return i == 3 and LIME_ST or nil end,
}

-- ---------------------------------------------------------------------------
-- The raster: 2 m pixels on a 2048 m map, one raw layer per nutrient key, two
-- fill rules. addPaintStrip models production's own arithmetic (see header);
-- everything else (hull, cells, centre/touch) is SF-1098's raster verbatim.
-- ---------------------------------------------------------------------------
local TERRAIN, GRAIN = 2048, 2
local HALF, N = TERRAIN / 2, TERRAIN / GRAIN
local RAW_MIN, RAW_MAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX

local KEYS = { "nitrogen", "phosphorus", "potassium", "organicMatter" }
local DEF  = {
  nitrogen      = { minVal = 0, maxVal = 100 },
  phosphorus    = { minVal = 0, maxVal = 100 },
  potassium     = { minVal = 0, maxVal = 100 },
  organicMatter = { minVal = 0, maxVal = 10 },
}
local UPR = {}
for _, k in ipairs(KEYS) do UPR[k] = (DEF[k].maxVal - DEF[k].minVal) / 254 end

-- Starting semantic field state (matches the field scalar defaults below) encoded
-- the same way SoilValueMaps.encode does: raw = 1 + floor(fraction*254 + 0.5).
local function encodeStart(value, def)
  local fraction = (value - def.minVal) / (def.maxVal - def.minVal)
  return RAW_MIN + math.floor(fraction * 254 + 0.5)
end
local START = { nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0 }
local START_RAW = {}
for _, k in ipairs(KEYS) do START_RAW[k] = encodeStart(START[k], DEF[k]) end

-- Production's rawDelta: floor(delta / unitsPerRaw) toward zero (SoilValueMaps.lua:779).
-- This is addPaintStrip's own arithmetic and stays the write-side model (callsite
-- inside the raster's addPaintStrip below): addPaintStrip itself still floors.
local function rawDeltaFor(delta, upr)
  if delta == 0 then return 0 end
  if delta >= 0 then return math.floor(delta / upr) end
  return -math.floor(-delta / upr)
end

-- [Tyson 2026-10-16] _nutrientPassStrip now adds half a raw step away from zero
-- before the value ever reaches addPaintStrip, turning its floor into round-to-
-- nearest (SPEC-2b-rounding-addendum.md). This is the HAND expectation for a
-- pass's dose post-rounding: the same adjustment production makes, then the same
-- floor. Only used to compute `want`, never inside the raster's own addPaintStrip.
local function roundedRawDeltaFor(delta, upr)
  if delta == 0 then return 0 end
  local half = 0.5 * upr
  return rawDeltaFor(delta + (delta > 0 and half or -half), upr)
end

local function cross(o, a, b) return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x) end
local function hull(pts)
  local p = {}
  for _, v in ipairs(pts) do p[#p + 1] = { x = v.x, z = v.z } end
  table.sort(p, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.z < b.z end)
  if #p < 3 then return p end
  local lower, upper = {}, {}
  for _, v in ipairs(p) do
    while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], v) <= 0 do table.remove(lower) end
    lower[#lower + 1] = v
  end
  for i = #p, 1, -1 do
    local v = p[i]
    while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], v) <= 0 do table.remove(upper) end
    upper[#upper + 1] = v
  end
  table.remove(lower); table.remove(upper)
  for _, v in ipairs(upper) do lower[#lower + 1] = v end
  return lower
end
local function strictlyInside(h, x, z)
  local pt = { x = x, z = z }
  for i = 1, #h do
    if cross(h[i], h[i % #h + 1], pt) <= 1e-12 then return false end
  end
  return true
end
local function overlaps(h, x0, z0, x1, z1)
  local sq = { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } }
  local function sep(poly)
    for i = 1, #poly do
      local a, b = poly[i], poly[i % #poly + 1]
      local nx, nz = -(b.z - a.z), b.x - a.x
      local minA, maxA, minB, maxB = math.huge, -math.huge, math.huge, -math.huge
      for _, v in ipairs(h)  do local d = v.x * nx + v.z * nz; minA = math.min(minA, d); maxA = math.max(maxA, d) end
      for _, v in ipairs(sq) do local d = v.x * nx + v.z * nz; minB = math.min(minB, d); maxB = math.max(maxB, d) end
      if maxA <= minB + 1e-9 or maxB <= minA + 1e-9 then return true end
    end
    return false
  end
  return not (sep(h) or sep(sq))
end

local function newRaster(rule)
  local vm = { available = true, terrainSize = TERRAIN, rule = rule, polys = 0, calls = {} }
  vm.raw = {}
  for _, k in ipairs(KEYS) do vm.raw[k] = {} end
  -- [Tyson 2026-10-16] Real defs so _nutrientPassStrip's half-step rounding is
  -- actually exercised, not skipped: minVal/maxVal per SoilValueMaps.lua:50-54.
  function vm:getLayerEntry(layer) local d = DEF[layer]; return d ~= nil and { def = d } or nil end
  function vm:getGrainMetres() return GRAIN end
  function vm:cells(verts)
    local h = hull(verts)
    local out = {}
    if #h < 3 then return out end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, v in ipairs(h) do
      minX = math.min(minX, v.x); maxX = math.max(maxX, v.x); minZ = math.min(minZ, v.z); maxZ = math.max(maxZ, v.z)
    end
    for j = math.floor((minZ + HALF) / GRAIN), math.floor((maxZ + HALF) / GRAIN) do
      for i = math.floor((minX + HALF) / GRAIN), math.floor((maxX + HALF) / GRAIN) do
        local x0, z0 = -HALF + i * GRAIN, -HALF + j * GRAIN
        local hit
        if self.rule == "centre" then hit = strictlyInside(h, x0 + GRAIN / 2, z0 + GRAIN / 2)
        else hit = overlaps(h, x0, z0, x0 + GRAIN, z0 + GRAIN) end
        if hit then out[#out + 1] = { i, j } end
      end
    end
    return out
  end
  -- Production arithmetic (SoilValueMaps.lua addPaintStrip, :773-838): rawDelta
  -- via unitsPerRaw, a pixel below raw 1 (no data) is skipped, a pixel that would
  -- overflow the add's window saturates at RAW_MAX (mirrored at RAW_MIN for a
  -- negative delta), everything else adds rawDelta. None of our four keys carries
  -- a rawFloor, so rawLow is plain RAW_MIN.
  function vm:addPaintStrip(key, sx, sz, wx, wz, hx, hz, delta)
    self.polys = self.polys + 1
    self.calls[#self.calls + 1] = { key = key, sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz, delta = delta }
    local def = DEF[key]
    if def == nil then return 0 end   -- a key this bar does not model (e.g. pH, if ever reached)
    local upr = UPR[key]
    local rawDelta = rawDeltaFor(delta, upr)
    if rawDelta == 0 then return 0 end
    local verts = { { x = sx, z = sz }, { x = wx, z = wz }, { x = hx, z = hz }, { x = wx + hx - sx, z = wz + hz - sz } }
    local layer = self.raw[key]
    local start = START_RAW[key]
    local rawLow = RAW_MIN
    for _, c in ipairs(self:cells(verts)) do
      local idx = c[2] * N + c[1]
      local cur = layer[idx] or start
      if rawDelta > 0 then
        if cur >= math.max(rawLow, RAW_MAX - rawDelta + 1) and cur <= RAW_MAX then
          layer[idx] = RAW_MAX
        elseif cur >= rawLow and cur <= RAW_MAX - rawDelta then
          layer[idx] = cur + rawDelta
        end
        -- else cur < rawLow: raw "no data" pixel, skipped (never happens here; the
        -- raster is pre-seeded, exactly as a field already under management is).
      else
        if cur >= rawLow and cur <= math.min(RAW_MAX, rawLow - rawDelta - 1) then
          layer[idx] = rawLow
        elseif cur >= rawLow - rawDelta and cur <= RAW_MAX then
          layer[idx] = cur + rawDelta
        end
      end
    end
    return delta
  end
  return vm
end

local FID = 7
local function newSys(rule)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings  = { enabled = true, replenishmentRate = 3 }   -- idx 3 = Normal = 1.0x (Constants.lua:84)
  s.fieldData = { [FID] = { fieldArea = 20.0, _farmlandAreaConfirmed = true, sessionCoverageCells = { seeded = true },
                            nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.0 } }
  s.valueMaps   = newRaster(rule)
  s.hookManager = HookManager.new()
  s._lastSprayX, s._lastSprayZ = 0, 0
  s.showNotification = function() end
  s.reqs = {}   -- pH's _applyPHFootprint requests, for the E group's regression probe
  s._applyPHFootprint = function(self, fieldId, req)
    self.reqs[#self.reqs + 1] = req
    return SoilFertilitySystem._applyPHFootprint(self, fieldId, req)
  end
  return s
end

-- One pass. BOOM_W-wide boom perpendicular to heading, `step` metres per tick.
-- `o.fillIndex` defaults to COMPOST. Returns the per-pass semantic density for
-- each key, captured from the FIRST tick's stashed dose: density = sd.dKey *
-- sd.area / tick-quad-area-in-ha. This is the hand-derivable "one pass's dose"
-- the spec describes, constant across ticks because the application rate
-- (litres per metre travelled) is constant.
local BOOM_W = 12
local function runPass(s, o)
  local hx, hz = math.sin(o.heading or 0), math.cos(o.heading or 0)
  local px, pz = hz, -hx
  local density, prevD
  local perM = o.litres / o.step
  local fillIndex = o.fillIndex or FT.COMPOST.index
  local quiet = print
  print = function() end
  for k = 0, o.ticks do
    g_currentMission.time = (o.t0 or 100000) + k * 16
    local d = (o.travel and o.travel(k)) or k * o.step
    local moved = prevD == nil and o.step or math.abs(d - prevD)
    prevD = d
    local cx, cz = o.x0 + hx * d, o.z0 + hz * d
    local ax, az = cx - px * BOOM_W / 2, cz - pz * BOOM_W / 2
    local bx, bz = cx + px * BOOM_W / 2, cz + pz * BOOM_W / 2
    s:onFertilizerApplied(FID, fillIndex, perM * math.min(moved, 3 * o.step), nil)
    local sd = s.fieldData[FID]._sprayDose
    if density == nil and sd and sd.dN and o.step and o.step > 0 then
      local tickHa = (BOOM_W * o.step) / 10000
      density = {
        nitrogen      = sd.dN  * sd.area / tickHa,
        phosphorus    = sd.dP  * sd.area / tickHa,
        potassium     = sd.dK  * sd.area / tickHa,
        organicMatter = sd.dOM * sd.area / tickHa,
      }
    end
    s:paintBoomStrip(FID, { { x = ax, z = az }, { x = bx, z = bz } }, "FERT", { ax = ax, az = az, bx = bx, bz = bz })
  end
  print = quiet
  return density
end

-- Pixels whose centre lies inside the region swept from distance d0 to d1 along
-- the heading, within the boom (SF-1098's sweptCentres, verbatim).
local function sweptCentres(o, d0, d1)
  local hx, hz = math.sin(o.heading or 0), math.cos(o.heading or 0)
  local px, pz = hz, -hx
  local set = {}
  local margin = BOOM_W + math.abs(d1 - d0) + 4
  local i0, i1 = math.floor((o.x0 - margin + HALF) / GRAIN), math.floor((o.x0 + margin + HALF) / GRAIN)
  local j0, j1 = math.floor((o.z0 - margin + HALF) / GRAIN), math.floor((o.z0 + margin + 2 * margin + HALF) / GRAIN)
  for j = j0, j1 do
    for i = i0, i1 do
      local cx, cz = -HALF + (i + 0.5) * GRAIN, -HALF + (j + 0.5) * GRAIN
      local along = (cx - o.x0) * hx + (cz - o.z0) * hz
      local across = (cx - o.x0) * px + (cz - o.z0) * pz
      if along > d0 + 1e-9 and along < d1 - 1e-9 and math.abs(across) < BOOM_W / 2 - 1e-9 then set[j * N + i] = true end
    end
  end
  return set
end

-- Every pixel inside `inside` gained `want` raw steps (within `tol`) on layer
-- `key`; every other pixel the raster holds for that key is unchanged.
local function auditKey(vm, key, inside, want, tol)
  local good, bad, outside, saturated, worst = 0, 0, 0, 0, nil
  local layer = vm.raw[key]
  local start = START_RAW[key]
  for idx in pairs(inside) do
    local gain = (layer[idx] or start) - start
    if math.abs(gain - want) <= tol then good = good + 1 else bad = bad + 1; worst = worst or gain end
    if (layer[idx] or start) >= RAW_MAX then saturated = saturated + 1 end
  end
  for idx, v in pairs(layer) do
    if not inside[idx] and v ~= start then outside = outside + 1 end
  end
  return { good = good, bad = bad, outside = outside, saturated = saturated, worst = worst }
end
-- All four keys together: one combined claim, per-key counts for diagnosis.
local function auditAll(vm, inside, want, tol)
  local r, totalBad, totalOutside, totalSat = {}, 0, 0, 0
  for _, key in ipairs(KEYS) do
    r[key] = auditKey(vm, key, inside, want[key], tol)
    totalBad = totalBad + r[key].bad
    totalOutside = totalOutside + r[key].outside
    totalSat = totalSat + r[key].saturated
  end
  r.totalBad, r.totalOutside, r.totalSaturated = totalBad, totalOutside, totalSat
  return r
end
local function fmtBad(r)
  return string.format("N=%d P=%d K=%d OM=%d", r.nitrogen.bad, r.phosphorus.bad, r.potassium.bad, r.organicMatter.bad)
end

-- Distance along the heading to the pass's last written line (the held anchor),
-- or the last tick's line when the code under test keeps no nutrient pass.
local function endOf(s, o)
  local p = s.fieldData[FID]._nutrientPass
  local hx, hz = math.sin(o.heading or 0), math.cos(o.heading or 0)
  if p == nil or p.anchor == nil then return (o.travel and o.travel(o.ticks)) or o.step * o.ticks end
  local a = p.anchor
  return ((a.ax + a.bx) / 2 - o.x0) * hx + ((a.az + a.bz) / 2 - o.z0) * hz
end

-- A spy on the quads handed to centresInQuad: their length along the travel.
-- Shared with pH (#1125); only the nutrient groups below ever call clearQuads.
local QUADS = {}
local realCentres = PositionalPH.centresInQuad
if realCentres ~= nil then
  PositionalPH.centresInQuad = function(quad, grain, terrain)
    local m1x, m1z = (quad[1].x + quad[2].x) / 2, (quad[1].z + quad[2].z) / 2
    local m2x, m2z = (quad[3].x + quad[4].x) / 2, (quad[3].z + quad[4].z) / 2
    QUADS[#QUADS + 1] = math.sqrt((m2x - m1x) ^ 2 + (m2z - m1z) ^ 2)
    return realCentres(quad, grain, terrain)
  end
end
local function clearQuads() for k in pairs(QUADS) do QUADS[k] = nil end end
local function longestQuad() local m = 0 for _, l in ipairs(QUADS) do if l > m then m = l end end return m end

-- Count of calls to addPaintStrip for a nutrient key whose first edge (sx,sz) to
-- (wx,wz) is about `width` metres long: 1.0 m for a _nutrientPassStrip square
-- (2 * grain * CELL_HALF = 2*2*0.25), 5.0 m for the applyFertilizer narrow-tool
-- dot (2*2.5), ~12 m (BOOM_W) for the old per-tick strip/seed.
local function callsNear(vm, width, tol)
  local n = 0
  for _, c in ipairs(vm.calls) do
    if DEF[c.key] then
      local w = math.sqrt((c.wx - c.sx) ^ 2 + (c.wz - c.sz) ^ 2)
      if math.abs(w - width) <= tol then n = n + 1 end
    end
  end
  return n
end

-- about 5,000 L/ha at 4.6 cm a tick on a 12 m boom (COMPOST's BASE_RATE is 5000
-- kg/ha dry, and the stub density above is 1 kg/L, so this is one designed pass).
local LITRES = 0.276
-- about 4,500 L/ha the same way, matching BIOSOLIDS' BASE_RATE of 4500 kg/ha.
local LITRES_B = 0.248

-- =====================================================================
-- E: the entry reaches the writer through the new scope, as per-pixel squares,
-- never a boom-wide strip, and pH is untouched.
-- =====================================================================
local A_OPTS = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 870, litres = LITRES }
group("E entry", function()
  local s = newSys("centre")
  local density = runPass(s, A_OPTS)
  T.ok("E1 [reached: onFertilizerApplied stashed N/P/K/OM, density N=" .. tostring(density and density.nitrogen)
       .. " P=" .. tostring(density and density.phosphorus) .. " K=" .. tostring(density and density.potassium)
       .. " OM=" .. tostring(density and density.organicMatter) .. "]",
       density ~= nil and density.nitrogen > 0 and density.phosphorus > 0
       and density.potassium > 0 and density.organicMatter > 0)
  local squares = callsNear(s.valueMaps, 1.0, 1e-6)
  T.ok("E2 [reached: " .. squares .. " per-pixel squares written for N/P/K/OM]", squares > 0)
  local wide = callsNear(s.valueMaps, BOOM_W, 1.0)
  T.eq("E3 NAMED: never a boom-wide strip for N/P/K/OM while the pass is active", wide, 0)

  -- pH regression probe: a LIME pass on a fresh system still goes through
  -- _phPassStrip (its CELLS request to _applyPHFootprint), exactly as #1125 left
  -- it; Change 2 only inserts AFTER the pH block and never touches it.
  local sPH = newSys("centre")
  runPass(sPH, { x0 = 207.3, z0 = 400.4, step = 0.046, ticks = 300, litres = 0.175, fillIndex = FT.LIME.index })
  local cells = 0
  for _, r in ipairs(sPH.reqs) do if r.scope == PositionalPH.SCOPE_CELLS then cells = cells + 1 end end
  T.ok("E4 NAMED: pH still goes through _phPassStrip's CELLS request (" .. cells .. " writes)", cells > 0)
end)

-- A pass of about 40 m: centre rule, then touch rule.
for _, rule in ipairs({ "centre", "touch" }) do
  local tag = rule == "centre" and "A" or "B"
  group(tag .. " " .. rule .. " rule", function()
    local s = newSys(rule)
    local density = runPass(s, A_OPTS)
    local want = {}
    for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
    local last = A_OPTS.step * A_OPTS.ticks
    local endAlong = endOf(s, A_OPTS)
    -- tol 0, not 1: the 2026-10-16 rounding addendum turns addPaintStrip's floor
    -- into round-to-nearest, so the right answer is now exact, not "within a
    -- step" -- a tolerance of 1 would silently absorb a dropped rounding step
    -- (floor and round differ by at most 1), which is exactly how M9 survived
    -- the first run of this battery. Confirmed clean at tol 0 on the fix.
    local r = auditAll(s.valueMaps, sweptCentres(A_OPTS, 0, endAlong), want, 0)
    T.ok(tag .. "0 [reached: want N=" .. want.nitrogen .. " P=" .. want.phosphorus
         .. " K=" .. want.potassium .. " OM=" .. want.organicMatter .. " raw steps a pass]",
         want.nitrogen > 0 and want.phosphorus > 0 and want.potassium > 0 and want.organicMatter > 0)
    T.eq(tag .. "1 NAMED (" .. rule .. "): every pixel the pass crossed gained exactly one pass's "
         .. "rounded dose of N, P, K and OM (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
    T.eq(tag .. "2 NAMED (" .. rule .. "): no pixel saturated at RAW_MAX on any of the four keys", r.totalSaturated, 0)
    T.eq(tag .. "3 (" .. rule .. "): no pixel outside the swept ground changed", r.totalOutside, 0)
    T.ok(tag .. "4 (" .. rule .. "): the pass reached its end (" .. string.format("%.2f", endAlong) .. " of " .. last .. " m)", endAlong > last - 0.1)
  end)
end

-- C: slow travel, 2 cm a tick: several held ticks per write; the carried dose lands.
group("C slow travel", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.02, ticks = 1000, litres = LITRES * 0.02 / 0.046 }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = {}
  for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
  local r = auditAll(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("C1 NAMED: at 2 cm a tick every crossed pixel still gains one pass's dose of N, P, K and OM (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.eq("C2 and nothing outside changes", r.totalOutside, 0)
end)

-- D: fast travel, 30 cm a tick: every tick writes, several centres per write.
group("D fast travel", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.3, ticks = 140, litres = LITRES * 0.3 / 0.046 }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = {}
  for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
  local r = auditAll(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("D1 at 30 cm a tick every crossed pixel gains one pass's dose of N, P, K and OM (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.eq("D2 and nothing outside changes", r.totalOutside, 0)
end)

-- K: lines land exactly on pixel-centre rows (z = 100, 102, ...).
group("K exact edges", function()
  local o = { x0 = 106, z0 = 100, step = 0.125, ticks = 320, litres = LITRES * 0.125 / 0.046 }
  local s = newSys("centre")
  local density = runPass(s, o)
  local want = {}
  for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
  local r = auditAll(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.ok("K0 [reached: quads ended exactly on " .. (r.nitrogen.good + r.nitrogen.bad) .. " centres]",
       r.nitrogen.good + r.nitrogen.bad > 50)
  T.eq("K1 NAMED: a centre on a shared quad edge is dosed exactly once, for N, P, K and OM (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.eq("K2 and nothing outside changes", r.totalOutside, 0)
end)

-- R: an angled pass, heading 30 degrees.
group("R angled pass", function()
  local o = { x0 = 207.3, z0 = 300.4, step = 0.046, ticks = 870, litres = LITRES, heading = math.rad(30) }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = {}
  for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
  local r = auditAll(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("R1 NAMED: at a 30 degree heading every crossed pixel gains one pass's dose of N, P, K and OM (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.eq("R2 and nothing outside changes", r.totalOutside, 0)
end)

-- S: the sprayer stands still for 200 ticks mid-pass with the boom on.
group("S standing still", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 1070, litres = LITRES,
              travel = function(k) if k < 300 then return k * 0.046 elseif k < 500 then return 300 * 0.046 else return (k - 200) * 0.046 end end }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = {}
  for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
  local r = auditAll(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("S1 NAMED: standing still for 200 ticks mid-pass, then moving on, still gives every crossed pixel "
       .. "one pass's dose of N, P, K and OM (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.eq("S2 and nothing outside the swept ground changes", r.totalOutside, 0)
end)

-- G: the boom pauses for 2 s and resumes 10 m on; the ground in between must
-- never be dosed, and no quad may span the gap.
group("G pause and resume", function()
  local s = newSys("centre")
  local o1 = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 435, litres = LITRES }
  local density = runPass(s, o1)
  local want = {}
  for _, k in ipairs(KEYS) do want[k] = roundedRawDeltaFor(density[k], UPR[k]) end
  local o2 = { x0 = 107.3, z0 = 100.4 + 0.046 * 435 + 10, step = 0.046, ticks = 435, litres = LITRES,
               t0 = 100000 + 435 * 16 + 2000 }
  clearQuads()
  runPass(s, o2)
  local afterPause = longestQuad()
  local gap = sweptCentres(o1, 0.046 * 435 + 0.5, 0.046 * 435 + 9.5)
  local touchedN, touchedOM = 0, 0
  for key in pairs(gap) do
    if (s.valueMaps.raw.nitrogen[key] or START_RAW.nitrogen) ~= START_RAW.nitrogen then touchedN = touchedN + 1 end
    if (s.valueMaps.raw.organicMatter[key] or START_RAW.organicMatter) ~= START_RAW.organicMatter then touchedOM = touchedOM + 1 end
  end
  T.eq("G1 NAMED: a pause then a resume 10 m on doses none of the ground between (N touched " .. touchedN .. ", OM touched " .. touchedOM .. ")",
       touchedN + touchedOM, 0)
  local r = auditAll(s.valueMaps, sweptCentres(o2, 0, endOf(s, o2)), want, 1)
  T.eq("G2 and the resumed pass doses its own ground once (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.ok("G3 NAMED: after the pause no quad was closed across the gap (longest " .. string.format("%.2f", afterPause) .. " m)", afterPause < 1)
end)

-- J: a jump of 100 m mid-pass (a teleport) never spans the gap.
group("J jump", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 870, litres = LITRES,
              travel = function(k) if k < 435 then return k * 0.046 else return k * 0.046 + 100 end end }
  local s = newSys("touch")
  clearQuads()
  runPass(s, o)
  local gap = sweptCentres(o, 435 * 0.046 + 0.5, 435 * 0.046 + 99.5)
  local touchedN = 0
  for key in pairs(gap) do if (s.valueMaps.raw.nitrogen[key] or START_RAW.nitrogen) ~= START_RAW.nitrogen then touchedN = touchedN + 1 end end
  T.eq("J1 a 100 m jump doses none of the ground it jumped (N touched " .. touchedN .. ")", touchedN, 0)
  T.ok("J2 NAMED: no quad was closed across the jump (longest " .. string.format("%.2f", longestQuad()) .. " m)", longestQuad() < 1)
end)

-- P: a product change mid-field ends the pass: the ground sprayed after the
-- change gets only the SECOND product's dose, never a mix with the carry the
-- first product left behind.
group("P product change", function()
  local s = newSys("centre")
  local o1 = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 300, litres = LITRES, fillIndex = FT.COMPOST.index }
  runPass(s, o1)
  local o2 = { x0 = 107.3, z0 = 100.4 + 0.046 * 300, step = 0.046, ticks = 300, litres = LITRES_B,
               fillIndex = FT.BIOSOLIDS.index, t0 = 100000 + 300 * 16 }
  clearQuads()
  local density2 = runPass(s, o2)
  local want2 = {}
  for _, k in ipairs(KEYS) do want2[k] = roundedRawDeltaFor(density2[k], UPR[k]) end
  local r = auditAll(s.valueMaps, sweptCentres(o2, 0, endOf(s, o2)), want2, 1)
  T.eq("P1 NAMED: a product change mid-field ends the pass; the ground sprayed after it gets only "
       .. "BIOSOLIDS' own pass dose, not a mix with COMPOST's carry (bad " .. fmtBad(r) .. ")", r.totalBad, 0)
  T.ok("P2 NAMED: the first post-change quad does not span back into the first product's ground (longest "
       .. string.format("%.2f", longestQuad()) .. " m)", longestQuad() < 1)
  local passProduct = s.fieldData[FID]._nutrientPass and s.fieldData[FID]._nutrientPass.product
  T.eq("P3 NAMED: the pass anchor itself is keyed to the new product (BIOSOLIDS), not left reading the "
       .. "old one (COMPOST), so a later gap or jump check never compares against a stale product",
       passProduct, "BIOSOLIDS")
end)

-- DOT: during a slow pass (2 cm a tick, 120 ticks) the narrow-tool dot in
-- applyFertilizer (the 5 m square, boomRecent check) writes nothing after the
-- first tick: paintBoomStrip sets field._vmBoomPaintTime every tick now, so
-- boomRecent is true from the second tick on. The dot fires once per key on
-- that first tick (COMPOST carries all four), so one tick of dot writes is
-- FOUR calls (N, P, K, OM), confirmed by probing a single-tick pass (ticks = 0)
-- separately: still exactly 4, all on that one tick.
group("DOT narrow-tool dot", function()
  local s = newSys("centre")
  local o = { x0 = 500.0, z0 = 500.0, step = 0.02, ticks = 120, litres = LITRES * 0.02 / 0.046 }
  runPass(s, o)
  local dots = callsNear(s.valueMaps, 5.0, 1e-6)
  T.ok("DOT0 [reached: " .. dots .. " narrow-tool dot writes over 121 ticks]", dots > 0)
  T.eq("DOT1 NAMED: the narrow-tool dot writes only on the first tick, once per key "
       .. "(N, P, K, OM = 4 calls), nothing for the other 120 ticks", dots, 4)
end)

-- F: with PositionalPH = nil, the old strip path still writes N (fallback
-- unchanged): the new branch is gated on PositionalPH being loaded, so without
-- it the tick-strip write at the bottom of paintBoomStrip still runs.
group("F PositionalPH absent fallback", function()
  local savedPH = PositionalPH
  PositionalPH = nil
  local s = newSys("centre")
  local o = { x0 = 800.0, z0 = 800.0, step = 0.046, ticks = 60, litres = LITRES }
  runPass(s, o)
  PositionalPH = savedPH
  local wide = callsNear(s.valueMaps, BOOM_W, 1.5)
  T.ok("F1 NAMED: without PositionalPH the old strip path still writes nitrogen (boom-wide calls " .. wide .. ")", wide > 0)
  local squares = callsNear(s.valueMaps, 1.0, 1e-6)
  T.eq("F2 and never through the new per-pixel squares (PositionalPH is absent)", squares, 0)
end)

-- Q: every nutrient square lies inside exactly one pixel, under either fill rule.
group("Q squares", function()
  local s = newSys("touch")
  runPass(s, { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 200, litres = LITRES })
  local squares, spill = 0, 0
  for _, c in ipairs(s.valueMaps.calls) do
    if DEF[c.key] then
      local w = math.sqrt((c.wx - c.sx) ^ 2 + (c.wz - c.sz) ^ 2)
      if math.abs(w - 1.0) < 1e-6 then
        squares = squares + 1
        local verts = { { x = c.sx, z = c.sz }, { x = c.wx, z = c.wz }, { x = c.hx, z = c.hz },
                        { x = c.wx + c.hx - c.sx, z = c.wz + c.hz - c.sz } }
        local touched = s.valueMaps:cells(verts)
        if #touched ~= 1 then spill = spill + 1 end
      end
    end
  end
  T.ok("Q0 [reached: " .. squares .. " squares written]", squares > 0)
  T.eq("Q1 NAMED: every written square touches exactly one pixel", spill, 0)
end)

PositionalPH.centresInQuad = realCentres
g_server, g_fillTypeManager, g_sprayTypeManager = saved.g_server, saved.g_fillTypeManager, saved.g_sprayTypeManager
g_farmlandManager, g_currentMission.time, print = saved.g_farmlandManager, saved.time, saved.print
