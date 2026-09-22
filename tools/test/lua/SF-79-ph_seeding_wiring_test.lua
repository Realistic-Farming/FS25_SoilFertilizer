-- SF-79-ph_seeding_wiring_test.lua: SF-79 section 3.B, the raw-zero pH seeding is wired.
--
-- THE STAKE, bigger than MAINTENANCE row 70 said. On main, pH was birth-seeded through
-- VM_NUTRIENT_KEYS. SF-79 slice 3 (f9e3db4a) removed pH from that list when the map
-- became the chemical authority, and nothing replaced the seed: _seedPHFootprint and
-- _migratePH existed with ZERO callers. The writer skips raw zero (RAW_MIN is 1, every
-- DELTA band starts at RAW_MIN) and still reports APPLIED. So on any save CREATED after
-- f9e3db4a, and on any field lazily created after load, the pH layer stayed raw zero:
-- lime wrote nothing, the report was EMPTY, pH read UNAVAILABLE. Unreleased (dev and
-- testers only) and it would have shipped with the next release.
--
-- THE REPAIR. seedValueMaps calls _migratePH for every field BEFORE the all-layers-
-- restored early return (per-layer, preservation-first: band [0,0] fills only unwritten
-- ground). _migratePH seeds from the frozen scalar (#982) or, when none was frozen, from
-- the existing genesis rule (_computeInitialSoil), NEVER from field.pH, which on a
-- marked-no-seed save is the later report; whichever value it used is then frozen.
-- getOrCreateField freezes a new field's genesis pH and seeds its footprint at once.
-- Both seed routines invalidate the report and bump _phMapRevision (getFieldInfo's
-- pHRevision), so a reader never serves the pre-seed report as current.
--
-- WHO POPULATES THE WORLD. Polygons come from the PRODUCTION resolver,
-- _getFarmlandPolygons over a g_fieldManager fixture through getWorldTranslation.
-- Seeds come from the real load (#982's freeze) or the real genesis rule. Only the
-- native map is a model: a 2 m pixel grid implementing setPolygonWhere /
-- applyRawDeltaToPolygonBand / readAverageRawInBand plus recording stubs for the
-- N/P/K/OM seeding calls. Nothing sets a seed by hand except where a row says so.
--
-- ENTRY-POINT BARS: groups A to D drive the real seedValueMaps (what activation, the
-- #880 deferred scan and the settings force-reseed all call); group E drives the real
-- getOrCreateField; group F drives the real PositionalPH.sampleWorkAreasPH for row 74.
--
-- What this bar does NOT prove: native density-map execution, the client cadence for a
-- mid-session seed, and engine load order. The TESTING row carries them.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua

local saved = { g_server = g_server, fields = g_fieldManager and g_fieldManager.fields,
                g_farmlandManager = g_farmlandManager, getWorldTranslation = getWorldTranslation,
                WorkAreaType = WorkAreaType, info = SoilLogger.info }
g_server = true

-- ── Two 20 m square fields on farmlands 1 and 2 ────────────────────────────────
local NODES = {}
local function square(fieldId, ox, oz)
  local ids = {}
  for i, c in ipairs({ { 0, 0 }, { 20, 0 }, { 20, 20 }, { 0, 20 } }) do
    local id = fieldId * 100 + i
    NODES[id] = { x = ox + c[1], z = oz + c[2] }
    ids[#ids + 1] = id
  end
  return { farmland = { id = fieldId }, polygonPoints = ids, posX = ox + 10, posZ = oz + 10 }
end
g_fieldManager = g_fieldManager or {}
g_fieldManager.fields = { square(1, 0, 0), square(2, 100, 0), square(3, 200, 0) }
getWorldTranslation = function(id) local p = NODES[id]; if p == nil then error("no node " .. tostring(id)) end return p.x, 0, p.z end
g_farmlandManager = { getFarmlandById = function(_s, id) return { id = id, areaInHa = 0.04 } end }

-- ── The native map model ───────────────────────────────────────────────────────
local RMIN, RMAX = SoilValueMaps.RAW_MIN, SoilValueMaps.RAW_MAX
local function inPoly(x, z, verts)
  local inside, j = false, #verts
  for i = 1, #verts do
    local a, b = verts[i], verts[j]
    if ((a.z > z) ~= (b.z > z)) and (x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x) then inside = not inside end
    j = i
  end
  return inside
end
local function newMap(phLoaded)
  local vm = { available = true, pixels = {}, calls = {}, loadedFromSave = phLoaded }
  local def = PositionalPH.phDef()
  function vm:getLayerEntry(layer) if layer == PositionalPH.PH_LAYER then return { def = def, loaded = phLoaded } end return { loaded = phLoaded } end
  function vm:getGrainMetres() return 2 end
  function vm:each(verts, fn)
    for x = 1, 299, 2 do for z = 1, 19, 2 do if inPoly(x, z, verts) then fn(x .. "," .. z) end end end
  end
  function vm:setPolygonWhere(layer, verts, raw, lo, hi)
    if layer ~= PositionalPH.PH_LAYER then return true end
    self:each(verts, function(k) local cur = self.pixels[k] or 0; if cur >= lo and cur <= hi then self.pixels[k] = raw end end)
    return true
  end
  function vm:applyRawDeltaToPolygonBand(layer, verts, d, lo, hi)
    if layer ~= PositionalPH.PH_LAYER then return {} end
    self:each(verts, function(k) local cur = self.pixels[k] or 0; if cur >= lo and cur <= hi then self.pixels[k] = cur + d end end)
    return {}
  end
  function vm:readAverageRawInBand(layer, verts, lo, hi)
    local sum, n = 0, 0
    self:each(verts, function(k) local cur = self.pixels[k] or 0; if cur >= lo and cur <= hi then sum = sum + cur; n = n + 1 end end)
    if n == 0 then return nil, 0 end
    return sum / n, n
  end
  function vm:readValueAtWorld(layer, x, z)
    local k = (math.floor(x / 2) * 2 + 1) .. "," .. (math.floor(z / 2) * 2 + 1)
    local raw = self.pixels[k]
    if raw == nil or raw == 0 then return nil end
    return PositionalPH.phValue(raw)
  end
  function vm:seedPolygon(key) self.calls[#self.calls + 1] = "seed:" .. key end
  function vm:seedPolygonByRelief() return false end
  function vm:paintPolygon(key) self.calls[#self.calls + 1] = "paint:" .. key end
  function vm:writeValueAtWorld(key) self.calls[#self.calls + 1] = "write:" .. key end
  function vm:_observeGrowthWrite() end
  return vm
end
local OX = { [1] = 0, [2] = 100, [3] = 200 }
local function paintOld(vm, fieldId, oldPH)   -- most pixels written at OLD, a strip (x below 4) raw zero
  local raw = PositionalPH.phRaw(oldPH)
  for x = OX[fieldId] + 1, OX[fieldId] + 19, 2 do for z = 1, 19, 2 do
    vm.pixels[x .. "," .. z] = (x - OX[fieldId] < 4) and 0 or raw
  end end
end
local function pixelsOf(vm, fieldId)
  local out = {}
  for x = OX[fieldId] + 1, OX[fieldId] + 19, 2 do for z = 1, 19, 2 do out[#out + 1] = vm.pixels[x .. "," .. z] or 0 end end
  return out
end
local function allEqual(list, want) for _, v in ipairs(list) do if v ~= want then return false end end return #list > 0 end
local function countEq(list, want) local n = 0 for _, v in ipairs(list) do if v == want then n = n + 1 end end return n end

local logged
local function captureInfo() logged = {}; SoilLogger.info = function(msg, ...) local ok, s = pcall(string.format, msg, ...); logged[#logged + 1] = ok and s or tostring(msg) end end
local function loggedMatching(needle) local n = 0 for _, s in ipairs(logged) do if s:find(needle, 1, true) then n = n + 1 end end return n end

local function newSys(phLoaded)
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true, replenishmentRate = 3 }
  s.fieldData = {}
  s.valueMaps = newMap(phLoaded)
  return s
end
local function addField(s, fid, pH, seed)
  s.fieldData[fid] = { fieldArea = 0.04, nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0,
                       pH = pH, zoneData = {}, sessionCoverageCells = {}, _phSeedScalar = seed }
end
local GEN = {}
do local o = newSys(false); for _, fid in ipairs({ 1, 2, 3 }) do GEN[fid] = o:_computeInitialSoil(fid).pH end end
local LIM = SoilConstants.NUTRIENT_LIMITS
local function clampPH(v) return math.max(LIM.PH_MIN, math.min(LIM.PH_MAX, v)) end
T.ok("SEEDW 0: the genesis pH differs from 6.0 and from 6.9 on the fields used below (a real difference to see)",
     math.abs(GEN[1] - 6.9) > 0.05 and math.abs(GEN[2] - 6.0) > 0.05)

-- =====================================================================
-- GROUP A: the layer is MISSING (a save created after f9e3db4a). The real seedValueMaps
-- seeds every field's polygons from its seed; a following lime DELTA then changes pixels.
-- The control, seeding removed, shows the same DELTA changing nothing: the stake.
-- =====================================================================
local LIME = 0.30
do
  captureInfo()
  local s = newSys(false)
  addField(s, 1, 6.9, 6.2)          -- a frozen seed from #982's load
  addField(s, 2, 6.0, nil)          -- no seed (marked-no-seed shape): genesis
  local ok, err = pcall(SoilFertilitySystem.seedValueMaps, s)
  T.ok("SEEDW A0: seedValueMaps ran (" .. tostring(err) .. ")", ok)
  T.ok("SEEDW A1: field 1's whole union is seeded from its FROZEN seed 6.2", allEqual(pixelsOf(s.valueMaps, 1), PositionalPH.phRaw(6.2)))
  T.ok("SEEDW A2: field 2 (no seed) is seeded from GENESIS, not from its scalar 6.0",
       allEqual(pixelsOf(s.valueMaps, 2), PositionalPH.phRaw(clampPH(GEN[2]))) and PositionalPH.phRaw(clampPH(GEN[2])) ~= PositionalPH.phRaw(6.0))
  T.eq("SEEDW A3: and that genesis value is now FROZEN as field 2's seed", s.fieldData[2]._phSeedScalar, clampPH(GEN[2]))
  T.eq("SEEDW A4: field 1's frozen seed is untouched", s.fieldData[1]._phSeedScalar, 6.2)
  T.eq("SEEDW A5: one pH seed line per seedValueMaps call, not per field", loggedMatching("[SF-79] pH seed:"), 1)
  T.ok("SEEDW A6: the line says layer restored=false, 2 fields, 2 polygons processed in band [0,0], 1 from a frozen seed, 1 from genesis",
       loggedMatching("layer restored=false, 2 field(s), 2 polygon(s) processed in band [0,0] (unwritten ground only; 1 from a frozen seed, 1 from genesis)") == 1)
  T.ok("SEEDW A7: the N/P/K/OM seed still ran for the missing layer", (function() for _, c in ipairs(s.valueMaps.calls) do if c == "seed:nitrogen" then return true end end return false end)())
  local before = pixelsOf(s.valueMaps, 1)
  s:_phApplyField(1, PositionalPH.OP_DELTA, LIME, nil, nil, 'application')
  local after = pixelsOf(s.valueMaps, 1)
  local moved = 0
  for i = 1, #before do if after[i] ~= before[i] then moved = moved + 1 end end
  T.eq("SEEDW A8: a following lime DELTA changes EVERY pixel of the seeded field", moved, #before)
end
do
  -- THE CONTROL: the same world with the migration removed. The DELTA changes nothing.
  local s = newSys(false)
  addField(s, 1, 6.9, 6.2)
  s._migratePH = function() return 0, nil end        -- seeding removed: the code before this item
  captureInfo()
  s:seedValueMaps()
  T.ok("SEEDW A9: control: the union stays raw zero", allEqual(pixelsOf(s.valueMaps, 1), 0))
  local res = s:_phApplyField(1, PositionalPH.OP_DELTA, LIME, nil, nil, 'application')
  T.ok("SEEDW A10: control: the writer still says APPLIED (the honest-looking failure)", res ~= nil and res.status == PositionalPH.STATUS_APPLIED)
  T.ok("SEEDW A11: control: and the same lime DELTA changed NOTHING (raw zero is outside every band)", allEqual(pixelsOf(s.valueMaps, 1), 0))
  local v, how = s:_phReportRead(1)
  T.eq("SEEDW A12: control: pH reads UNAVAILABLE", how, PositionalPH.READ_UNAVAILABLE)
end

-- =====================================================================
-- GROUP B: the layer is RESTORED with holes. Written pixels stay byte-identical; the
-- holes are filled from the seed. And GROUP C: loadedFromSave=true still runs it.
-- =====================================================================
do
  captureInfo()
  local s = newSys(true)               -- all layers restored from the save
  addField(s, 1, 6.9, 6.2)
  paintOld(s.valueMaps, 1, 6.0)         -- written at 6.0, with a raw-zero strip
  local before = pixelsOf(s.valueMaps, 1)
  local zeros = countEq(before, 0)
  T.ok("SEEDW B0: the fixture holds written pixels AND holes", zeros > 0 and zeros < #before)
  s:seedValueMaps()
  local after = pixelsOf(s.valueMaps, 1)
  local kept, filled = 0, 0
  for i = 1, #before do
    if before[i] ~= 0 and after[i] == before[i] then kept = kept + 1 end
    if before[i] == 0 and after[i] == PositionalPH.phRaw(6.2) then filled = filled + 1 end
  end
  T.eq("SEEDW B1: every written pixel is byte-identical after the migration", kept, #before - zeros)
  T.eq("SEEDW B2: every hole is filled from the seed", filled, zeros)
  T.eq("SEEDW C1: with every layer restored the migration STILL ran (the early return comes after it)", loggedMatching("[SF-79] pH seed: layer restored=true"), 1)
  T.eq("SEEDW C2: and the rest of the seeding was skipped as before", loggedMatching("seeding skipped"), 1)
  T.ok("SEEDW C3: N/P/K/OM were NOT reseeded on a restored save", (function() for _, c in ipairs(s.valueMaps.calls) do if c == "seed:nitrogen" then return false end end return true end)())
end

-- =====================================================================
-- GROUP D: marked-no-seed, the report and the revision. The seed is the genesis value,
-- not field.pH; after the seed the revision moved and the report is served CURRENT.
-- =====================================================================
do
  local s = newSys(false)
  addField(s, 2, 6.0, nil)             -- field.pH set UNEQUAL to genesis on purpose
  local rev0 = s._phMapRevision or 0
  local v0, how0 = s:_phReportRead(2)
  T.eq("SEEDW D0: before the seed the report is not served (raw zero everywhere)", how0, PositionalPH.READ_UNAVAILABLE)
  s:seedValueMaps()
  T.ok("SEEDW D1: the seed used is the GENESIS value, not field.pH", math.abs(s.fieldData[2]._phSeedScalar - clampPH(GEN[2])) < 1e-9 and math.abs(s.fieldData[2]._phSeedScalar - 6.0) > 0.05)
  T.ok("SEEDW D2: _phMapRevision moved (getFieldInfo's pHRevision comes from it)", (s._phMapRevision or 0) > rev0)
  local v, how = s:_phReportRead(2)
  T.eq("SEEDW D3: the report is served as the field report, not stale", how, PositionalPH.READ_FIELD)
  T.near("SEEDW D4: and equals the seed, quantised", v, PositionalPH.phValue(PositionalPH.phRaw(clampPH(GEN[2]))), 1e-9)
  -- _computeInitialSoil has no side effect on the record: the scalar is untouched by seeding.
  T.eq("SEEDW D5: seeding does not touch field.pH itself (the refresh is the writer's job)", s.fieldData[2].pH, 6.0)
end

-- =====================================================================
-- GROUP E: a LAZILY CREATED field (the real getOrCreateField). Its birth pH is frozen and
-- its footprint seeded before any write.
-- =====================================================================
do
  local s = newSys(false)
  local f = s:getOrCreateField(3, true)
  T.ok("SEEDW E0: the field was created", f ~= nil and s.fieldData[3] == f)
  T.eq("SEEDW E1: its seed is its own birth pH, clamped to the carrier", f._phSeedScalar, clampPH(f.pH))
  T.ok("SEEDW E2: its union is seeded from that value before any write", allEqual(pixelsOf(s.valueMaps, 3), PositionalPH.phRaw(clampPH(f.pH))))
  local v, how = s:_phReportRead(3)
  T.eq("SEEDW E3: and the report is served at once", how, PositionalPH.READ_FIELD)
  T.ok("SEEDW E4: _phMapRevision moved on the birth seed", (s._phMapRevision or 0) >= 1)
end
do
  -- Maps not up yet at birth: the seed is frozen, nothing is painted, and the load-time
  -- migration paints it later from the same frozen value.
  local s = newSys(false)
  s.valueMaps.available = false
  local f = s:getOrCreateField(3, true)
  T.eq("SEEDW E5: with the maps unavailable the birth pH is still frozen as the seed", f._phSeedScalar, clampPH(f.pH))
  s.valueMaps.available = true
  s:seedValueMaps()
  T.ok("SEEDW E6: and the migration later paints exactly that frozen value", allEqual(pixelsOf(s.valueMaps, 3), PositionalPH.phRaw(f._phSeedScalar)))
end
do
  local sg = g_server; g_server = nil
  local s = newSys(false)
  addField(s, 1, 6.9, 6.2)
  s:seedValueMaps()
  T.ok("SEEDW E7: a client seeds nothing (server-only, the polygons stay raw zero)", allEqual(pixelsOf(s.valueMaps, 1), 0))
  g_server = sg
end

-- =====================================================================
-- GROUP F: MAINTENANCE row 74. PositionalPH.sampleWorkAreasPH reads WorkAreaType.AUXILIARY
-- BARE: with the global supplied an auxiliary area is excluded; with it absent the read
-- raises, so a bench that forgets the global fails loudly instead of the guard failing
-- open (auxiliary areas counted).
-- =====================================================================
do
  WorkAreaType = { SPRAYER = 5, AUXILIARY = 9 }
  local s = newSys(false)
  addField(s, 1, 6.9, 6.2)
  s:seedValueMaps()
  NODES[9001], NODES[9002], NODES[9003], NODES[9004] = { x = 10, z = 10 }, { x = 10, z = 10 }, { x = 10, z = 10 }, { x = 10, z = 10 }
  local areas = { { type = WorkAreaType.SPRAYER, width = 9001, height = 9002 }, { type = WorkAreaType.AUXILIARY, width = 9003, height = 9004 } }
  local calls = 0
  local veh = { getIsWorkAreaActive = function() calls = calls + 1; return true end }
  local ph = PositionalPH.sampleWorkAreasPH(s, veh, areas)
  T.ok("SEEDW F1: with WorkAreaType supplied, the sample is the pH under the sprayer area", type(ph) == "number" and math.abs(ph - PositionalPH.phValue(PositionalPH.phRaw(6.2))) < 1e-9)
  T.eq("SEEDW F2: the AUXILIARY area is excluded before the vehicle is even asked (one active query, not two)", calls, 1)
  WorkAreaType = nil
  local okNil = pcall(PositionalPH.sampleWorkAreasPH, s, veh, areas)
  T.eq("SEEDW F3: with WorkAreaType ABSENT the bare read raises (fail closed; the bench supplies the global)", okNil, false)
  WorkAreaType = saved.WorkAreaType
end

SoilLogger.info = saved.info
g_server = saved.g_server
g_fieldManager.fields = saved.fields
g_farmlandManager, getWorldTranslation, WorkAreaType = saved.g_farmlandManager, saved.getWorldTranslation, saved.WorkAreaType
