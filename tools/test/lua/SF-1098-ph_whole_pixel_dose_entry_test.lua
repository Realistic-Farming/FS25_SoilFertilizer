-- SF-1098-ph_whole_pixel_dose_entry_test.lua: one lime pass gives each pixel one pass's dose.
--
-- THE REPORT (#1098, #911). One lime pass took covered ground to pH 7.5, at any rate,
-- AUTO on or off, solid or liquid. The dose chain was right; the write was not. Each
-- sprayer tick moves the boom a few centimetres, and a value-map pixel is about 2 m.
-- paintBoomStrip handed the pass's full per-hectare pH to the positional writer as a
-- delta over the tick's thin quad, and the engine's polygon add puts that whole delta
-- on every pixel the polygon reaches. Dozens of ticks reached each pixel, so it
-- saturated at PH_MAX within a metre or two.
--
-- THE FIX (PositionalPH _phPassStrip). pH keeps its own pass anchor. A tick with too
-- little travel carries its dose; a tick that closes a quad writes the carried dose's
-- density, once, to each pixel whose CENTRE lies in the quad, through a square half a
-- pixel wide inside it. Successive quads tile the pass, so each pixel gets one dose.
--
-- THE ENTRY-POINT BAR (R-18). Every tick runs the REAL onFertilizerApplied, then the
-- REAL paintBoomStrip at the same time, the order the sprayer hook uses, through the
-- REAL _phPassStrip and _applyPHFootprint. The native map is a pixel raster with the
-- quantizer's raw steps. How the engine fills a polygon onto pixels is not documented
-- anywhere (decompile, LUADOC, the references), so the raster runs both readings: a
-- pixel is written when its CENTRE is inside the polygon, or when the polygon TOUCHES
-- it with any area. The fix has to hold under both. The raster fills the convex hull of
-- the points it is given, which is the parallelogram the old strip scope meant (its
-- point order s, w, h, w+h-s draws a crossed polygon). Its geometry is the bench's own
-- code, never PositionalPH's, so it cannot agree with production by sharing a helper.
-- Set by hand: the report refresh (_phRefreshScalar, after the write, not this item).
--
-- Groups: E the entry, A a pass under the centre rule, B the same under the touch
-- rule, C slow travel, D fast travel, K quad edges exactly on pixel centres, R an
-- angled pass, S a stop mid-pass, G a pause and resume, J a jump, Q the written squares.
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

-- Fill and spray types: LIME as the engine registers it (a LIME spray type).
local FT = { LIME = { name = "LIME", index = 3, massPerLiter = 0.001 } }
g_fillTypeManager = {
  getFillTypeByName      = function(_s, n) return FT[n] end,
  getFillTypeByIndex     = function(_s, i) return i == 3 and FT.LIME or nil end,
  getFillTypeIndexByName = function(_s, n) return FT[n] and FT[n].index end,
}
local LIME_ST = { name = "LIME", index = 1, fillType = "LIME", isLime = true, litersPerSecond = 0.09 }
g_sprayTypeManager = {
  getSprayTypeByName          = function(_s, n) return n and string.upper(n) == "LIME" and LIME_ST or nil end,
  getSprayTypeByIndex         = function(_s, i) return i == 1 and LIME_ST or nil end,
  getSprayTypeByFillTypeIndex = function(_s, i) return i == 3 and LIME_ST or nil end,
}

-- ---------------------------------------------------------------------------
-- The raster: 2 m pixels on a 2048 m map, raw steps per pixel, two fill rules.
-- ---------------------------------------------------------------------------
local TERRAIN, GRAIN = 2048, 2
local HALF, N = TERRAIN / 2, TERRAIN / GRAIN
local DEF = PositionalPH.phDef()
local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
local START_PH = 6.0
local START_RAW = PositionalPH.phRaw(START_PH, DEF)

local function cross(o, a, b) return (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x) end
local function hull(pts)                  -- Andrew's monotone chain, counter-clockwise
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
-- Centre rule: strictly inside the convex hull (on an edge counts as outside).
local function strictlyInside(h, x, z)
  local pt = { x = x, z = z }
  for i = 1, #h do
    if cross(h[i], h[i % #h + 1], pt) <= 1e-12 then return false end
  end
  return true
end
-- Touch rule: the hull and the pixel square overlap with positive area (separating axes).
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
  local vm = { available = true, terrainSize = TERRAIN, raw = {}, rule = rule, polys = 0 }
  function vm:getLayerEntry(layer) if layer == PositionalPH.PH_LAYER then return { def = DEF } end return nil end
  function vm:getGrainMetres() return GRAIN end
  function vm:get(i, j) return self.raw[j * N + i] or START_RAW end
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
  function vm:setPolygonWhere(_layer, verts, rawValue, lo, hi)
    self.polys = self.polys + 1
    for _, c in ipairs(self:cells(verts)) do
      local cur = self:get(c[1], c[2])
      if cur >= lo and cur <= hi then self.raw[c[2] * N + c[1]] = rawValue end
    end
    return true
  end
  function vm:applyRawDeltaToPolygonBand(_layer, verts, d, lo, hi)
    for _, c in ipairs(self:cells(verts)) do
      local cur = self:get(c[1], c[2])
      if cur >= lo and cur <= hi then self.raw[c[2] * N + c[1]] = cur + d end
    end
    return {}
  end
  function vm:addPaintStrip() end
  return vm
end

local FID = 7
local function newSys(rule)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings  = { enabled = true, replenishmentRate = 3 }
  s.fieldData = { [FID] = { fieldArea = 20.0, _farmlandAreaConfirmed = true, sessionCoverageCells = { seeded = true },
                            nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = START_PH } }
  s.valueMaps   = newRaster(rule)
  s.hookManager = HookManager.new()
  s._lastSprayX, s._lastSprayZ = 0, 0
  s.showNotification = function() end
  s._phRefreshScalar = function() end
  s.reqs = {}
  s._applyPHFootprint = function(self, fieldId, req)
    self.reqs[#self.reqs + 1] = req
    return SoilFertilitySystem._applyPHFootprint(self, fieldId, req)
  end
  return s
end

-- One pass. The boom (width W) runs perpendicular to its heading; each tick moves it
-- `step` metres along the heading. Litres follow the travel, as Soil's own usage hook
-- drains them (actual speed, nothing below 0.5 km/h; HookManager.lua:9816): `litres`
-- per `step`, none while standing, and a jump sprays no more than three normal ticks.
-- Returns the per-tick pass density from the stashed dose (sd.dPH * sd.area / tick ha).
local BOOM_W = 12
local function runPass(s, o)
  local hx, hz = math.sin(o.heading or 0), math.cos(o.heading or 0)   -- travel direction
  local px, pz = hz, -hx                                              -- along the boom
  local density, prevD
  local perM = o.litres / o.step
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
    s:onFertilizerApplied(FID, FT.LIME.index, perM * math.min(moved, 3 * o.step), nil)
    local sd = s.fieldData[FID]._sprayDose
    if density == nil and sd and sd.dPH and o.step and o.step > 0 then
      density = sd.dPH * sd.area / (BOOM_W * o.step / 10000)
    end
    s:paintBoomStrip(FID, { { x = ax, z = az }, { x = bx, z = bz } }, "LIME", { ax = ax, az = az, bx = bx, bz = bz })
  end
  print = quiet
  return density
end

-- Pixels whose centre lies inside the region swept from distance d0 to d1 along the
-- heading, within the boom: the ground the pass covered, by the bench's own geometry.
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

-- Every pixel inside `inside` gained `want` raw steps (within `tol`); every other
-- pixel the raster holds is unchanged. Returns counts for the row messages.
local function audit(vm, inside, want, tol)
  local good, bad, outside, saturated, worst = 0, 0, 0, 0, nil
  for key in pairs(inside) do
    local gain = (vm.raw[key] or START_RAW) - START_RAW
    if math.abs(gain - want) <= tol then good = good + 1 else bad = bad + 1; worst = worst or gain end
    if (vm.raw[key] or START_RAW) >= RMAX then saturated = saturated + 1 end
  end
  for key, v in pairs(vm.raw) do
    if not inside[key] and v ~= START_RAW then outside = outside + 1 end
  end
  return { good = good, bad = bad, outside = outside, saturated = saturated, worst = worst }
end

-- Distance along the heading to the pass's last written line (its held anchor), or to
-- the last tick's line when the code under test keeps no pH pass (development).
local function endOf(s, o)
  local p = s.fieldData[FID]._phPass
  local hx, hz = math.sin(o.heading or 0), math.cos(o.heading or 0)
  if p == nil or p.anchor == nil then return (o.travel and o.travel(o.ticks)) or o.step * o.ticks end
  local a = p.anchor
  return ((a.ax + a.bx) / 2 - o.x0) * hx + ((a.az + a.bz) / 2 - o.z0) * hz
end

-- A spy on the quads the pass hands to centresInQuad: their length along the travel.
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

local LITRES = 0.175     -- about 3,170 L/ha at 4.6 cm a tick on a 12 m boom

-- =====================================================================
-- E: the entry reaches the writer through the new scope.
-- =====================================================================
local A_OPTS = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 870, litres = LITRES }
group("E entry", function()
  local s = newSys("centre")
  local density = runPass(s, A_OPTS)
  T.ok("E1 [reached: onFertilizerApplied stashed a pH dose, density " .. tostring(density) .. "]", density ~= nil and density > 0)
  local cells = 0
  for _, r in ipairs(s.reqs) do if r.scope == PositionalPH.SCOPE_CELLS then cells = cells + 1 end end
  T.ok("E2 [reached: paintBoomStrip wrote pH through the CELLS scope, " .. cells .. " writes]", cells > 0)
  local strips = 0
  for _, r in ipairs(s.reqs) do if r.scope == PositionalPH.SCOPE_STRIP then strips = strips + 1 end end
  T.eq("E3 and never through the old per-tick STRIP scope", strips, 0)
end)

-- A pass of about 40 m: centre rule, then touch rule.
for _, rule in ipairs({ "centre", "touch" }) do
  local tag = rule == "centre" and "A" or "B"
  group(tag .. " " .. rule .. " rule", function()
    local s = newSys(rule)
    local density = runPass(s, A_OPTS)
    local want = PositionalPH.rawDeltaFor(density)
    local last = A_OPTS.step * A_OPTS.ticks
    -- The pass's first line is the seed (its tick's spray fell behind it); the last
    -- written line is the anchor the pass holds now.
    local endAlong = endOf(s, A_OPTS)
    local r = audit(s.valueMaps, sweptCentres(A_OPTS, 0, endAlong), want, 1)
    T.ok(tag .. "0 [reached: the pass crossed " .. (r.good + r.bad) .. " pixel centres, " .. want .. " raw steps a pass]",
         r.good + r.bad > 100 and want > 5)
    T.eq(tag .. "1 NAMED (" .. rule .. "): every pixel the pass crossed gained one pass's dose, within one raw step (worst " .. tostring(r.worst) .. ")", r.bad, 0)
    T.eq(tag .. "2 NAMED (" .. rule .. "): no pixel saturated at PH_MAX", r.saturated, 0)
    T.eq(tag .. "3 (" .. rule .. "): no pixel outside the swept ground changed", r.outside, 0)
    T.ok(tag .. "4 (" .. rule .. "): the pass reached its end (" .. string.format("%.2f", endAlong) .. " of " .. last .. " m)", endAlong > last - 0.1)
  end)
end

-- C: slow travel, 2 cm a tick: two held ticks per write; the carried dose lands.
group("C slow travel", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.02, ticks = 1000, litres = LITRES * 0.02 / 0.046 }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = PositionalPH.rawDeltaFor(density)
  local r = audit(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("C1 NAMED: at 2 cm a tick every crossed pixel still gains one pass's dose (worst " .. tostring(r.worst) .. ")", r.bad, 0)
  T.eq("C2 and nothing outside changes", r.outside, 0)
end)

-- D: fast travel, 30 cm a tick: every tick writes, several centres per write.
group("D fast travel", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.3, ticks = 140, litres = LITRES * 0.3 / 0.046 }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = PositionalPH.rawDeltaFor(density)
  local r = audit(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("D1 at 30 cm a tick every crossed pixel gains one pass's dose (worst " .. tostring(r.worst) .. ")", r.bad, 0)
  T.eq("D2 and nothing outside changes", r.outside, 0)
end)

-- K: lines land exactly on pixel-centre rows (z = 101, 103, ...): a centre on an edge
-- two quads share must be dosed once, not twice and not never.
group("K exact edges", function()
  local o = { x0 = 106, z0 = 100, step = 0.125, ticks = 320, litres = LITRES * 0.125 / 0.046 }
  local s = newSys("centre")
  local density = runPass(s, o)
  local want = PositionalPH.rawDeltaFor(density)
  -- Centres on the start line are never dosed (the seed line), centres on the end line
  -- belong to the next quad; sweptCentres is strict on both ends for that reason.
  local r = audit(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.ok("K0 [reached: quads ended exactly on " .. (r.good + r.bad) .. " centres]", r.good + r.bad > 50)
  T.eq("K1 NAMED: a centre on a shared quad edge is dosed exactly once (worst " .. tostring(r.worst) .. ")", r.bad, 0)
  T.eq("K2 and nothing outside changes", r.outside, 0)
end)

-- R: an angled pass, heading 30 degrees.
group("R angled pass", function()
  local o = { x0 = 207.3, z0 = 300.4, step = 0.046, ticks = 870, litres = LITRES, heading = math.rad(30) }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = PositionalPH.rawDeltaFor(density)
  local r = audit(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("R1 NAMED: at a 30 degree heading every crossed pixel gains one pass's dose (worst " .. tostring(r.worst) .. ")", r.bad, 0)
  T.eq("R2 and nothing outside changes", r.outside, 0)
end)

-- S: the sprayer stands still for 200 ticks mid-pass with the boom on (no travel).
group("S standing still", function()
  local o = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 1070, litres = LITRES,
              travel = function(k) if k < 300 then return k * 0.046 elseif k < 500 then return 300 * 0.046 else return (k - 200) * 0.046 end end }
  local s = newSys("touch")
  local density = runPass(s, o)
  local want = PositionalPH.rawDeltaFor(density)
  local r = audit(s.valueMaps, sweptCentres(o, 0, endOf(s, o)), want, 1)
  T.eq("S1 NAMED: standing still for 200 ticks mid-pass, then moving on, still gives every crossed pixel one pass's dose (worst " .. tostring(r.worst) .. ")", r.bad, 0)
  T.eq("S2 and nothing outside the swept ground changes", r.outside, 0)
end)

-- G: the boom pauses for 2 s (no spray, no paint) and resumes 10 m on; the ground in
-- between was never sprayed and must not be dosed.
group("G pause and resume", function()
  local s = newSys("centre")
  local o1 = { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 435, litres = LITRES }
  local density = runPass(s, o1)
  local want = PositionalPH.rawDeltaFor(density)
  local o2 = { x0 = 107.3, z0 = 100.4 + 0.046 * 435 + 10, step = 0.046, ticks = 435, litres = LITRES,
               t0 = 100000 + 435 * 16 + 2000 }
  clearQuads()
  runPass(s, o2)
  local afterPause = longestQuad()
  local gap = sweptCentres(o1, 0.046 * 435 + 0.5, 0.046 * 435 + 9.5)
  local touched = 0
  for key in pairs(gap) do if (s.valueMaps.raw[key] or START_RAW) ~= START_RAW then touched = touched + 1 end end
  T.eq("G1 NAMED: a pause then a resume 10 m on doses none of the ground between", touched, 0)
  local r = audit(s.valueMaps, sweptCentres(o2, 0, endOf(s, o2)), want, 1)
  T.eq("G2 and the resumed pass doses its own ground once", r.bad, 0)
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
  local touched = 0
  for key in pairs(gap) do if (s.valueMaps.raw[key] or START_RAW) ~= START_RAW then touched = touched + 1 end end
  T.eq("J1 a 100 m jump doses none of the ground it jumped", touched, 0)
  T.ok("J2 NAMED: no quad was closed across the jump (longest " .. string.format("%.2f", longestQuad()) .. " m)", longestQuad() < 1)
end)

-- Q: every written square lies inside one pixel, so no fill rule reaches a neighbour.
group("Q squares", function()
  local s = newSys("touch")
  runPass(s, { x0 = 107.3, z0 = 100.4, step = 0.046, ticks = 200, litres = LITRES })
  local squares, spill = 0, 0
  for _, r in ipairs(s.reqs) do
    if r.scope == PositionalPH.SCOPE_CELLS then
      for _, c in ipairs(r.cells) do
        squares = squares + 1
        local h = r.halfSize
        local touched = s.valueMaps:cells({ { x = c.x - h, z = c.z - h }, { x = c.x + h, z = c.z - h },
                                            { x = c.x + h, z = c.z + h }, { x = c.x - h, z = c.z + h } })
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
