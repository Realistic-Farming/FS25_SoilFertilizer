-- SF-79-reroll_ph_routing_test.lua: SF-79 section 3.C, both soil re-rolls reach the pH map.
--
-- THE GAP. rerollAllFields (console SoilRerollFields) and rerollUnownedFields (console
-- SoilRerollUnownedFields) set `field.pH = soil.pH` and call vmSeedField(fieldId, true).
-- vmSeedField walks VM_NUTRIENT_KEYS, which lost pH in f9e3db4a when the map became the
-- chemical authority. So the pH map kept its old pixels: getFieldInfo's FIELD_REPORT
-- showed the OLD mean at once, and _phRefreshScalar wrote that old mean back over the
-- scalar after the field's next pH write. The re-roll was invisible and then undone,
-- the same shape as the plow before #979. 3.C: "Route ... reroll/admin/recovery through
-- the writer."
--
-- WHO POPULATES THE WORLD. The parcel polygons come from the PRODUCTION resolver,
-- _getFarmlandPolygons, reading a g_fieldManager.fields fixture through
-- getWorldTranslation, never a hand-built domain. The re-rolled values come from the
-- real _computeInitialSoil. Only the native map is a model: a pixel grid at 2 m grain
-- implementing setPolygonWhere / applyRawDeltaToPolygonBand / readAverageRawInBand
-- (the three calls the writer and the report make) plus recording stubs for the
-- N/P/K/OM seeding calls. Ownership is a g_farmlandManager fixture and NPC status a
-- NpcSoilBridge fixture, both stated here because rerollUnownedFields reads them.
--
-- ENTRY-POINT BARS: every group drives rerollAllFields or rerollUnownedFields
-- themselves, the functions the two console commands call, over the real PositionalPH
-- writer, report and refresh.
--
-- What this bar does NOT prove: native density-map execution, how a joined client
-- learns a re-roll, and the console commands' server gate. Those are the in-game row.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua

local saved = { g_server = g_server, fields = g_fieldManager and g_fieldManager.fields,
                g_farmlandManager = g_farmlandManager, NpcSoilBridge = NpcSoilBridge,
                getWorldTranslation = getWorldTranslation, getFarmId = g_currentMission.getFarmId }
g_server = true

-- ---------------------------------------------------------------------------
-- The world: three 20 m square fields on farmlands 1, 2 and 9, as g_fieldManager
-- holds them (polygonPoints are node ids; getWorldTranslation resolves them).
-- ---------------------------------------------------------------------------
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
g_fieldManager.fields = { square(1, 0, 0), square(2, 100, 0), square(9, 200, 0) }
getWorldTranslation = function(id) local p = NODES[id]; if p == nil then error("no node " .. tostring(id)) end return p.x, 0, p.z end
g_farmlandManager = {
  getFarmlandById = function(_s, id) return { id = id, areaInHa = 0.04 } end,
  getFarmlandOwner = function(_s, id) if id == 1 then return 1 end return 0 end,   -- farm 1 owns field 1
}
NpcSoilBridge = { isNPCManaged = function(_s, id) return id == 9 end }              -- field 9 is NPC ground
g_currentMission.getFarmId = function() return 1 end                                -- the player is farm 1

-- ---------------------------------------------------------------------------
-- The native map model: pixels at 2 m grain, keyed "x,z", raw 0..255 for the pH
-- layer. Polygon membership by even-odd on the pixel centre.
-- ---------------------------------------------------------------------------
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
local function newMap()
  local vm = { available = true, pixels = {}, calls = {} }
  local def = PositionalPH.phDef()
  function vm:getLayerEntry(layer) if layer == PositionalPH.PH_LAYER then return { def = def, loaded = true } end return { loaded = true } end
  function vm:getGrainMetres() return 2 end
  function vm:each(verts, fn)
    for x = 1, 299, 2 do for z = 1, 19, 2 do
      if inPoly(x, z, verts) then fn(x .. "," .. z) end
    end end
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
  function vm:seedPolygon(key) self.calls[#self.calls + 1] = "seed:" .. key end
  function vm:seedPolygonByRelief() return false end
  function vm:paintPolygon(key) self.calls[#self.calls + 1] = "paint:" .. key end
  function vm:writeValueAtWorld(key) self.calls[#self.calls + 1] = "write:" .. key end
  function vm:_observeGrowthWrite() end
  return vm
end
-- Pre-existing map state for one field: most of it at an OLD written value, a strip
-- (x below 4 in field-local coordinates) never written (raw 0).
local function paintOld(vm, fieldId, oldPH)
  local ox = ({ [1] = 0, [2] = 100, [9] = 200 })[fieldId]
  local raw = PositionalPH.phRaw(oldPH)
  for x = ox + 1, ox + 19, 2 do for z = 1, 19, 2 do
    vm.pixels[x .. "," .. z] = (x - ox < 4) and 0 or raw
  end end
end
local function pixelsOf(vm, fieldId)
  local ox = ({ [1] = 0, [2] = 100, [9] = 200 })[fieldId]
  local out = {}
  for x = ox + 1, ox + 19, 2 do for z = 1, 19, 2 do out[#out + 1] = vm.pixels[x .. "," .. z] or 0 end end
  return out
end
local function allEqual(list, want)
  for _, v in ipairs(list) do if v ~= want then return false end end
  return #list > 0
end
local function sameList(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local OLD = 6.0
local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true, replenishmentRate = 3 }
  s.fieldData = {}
  for _, fid in ipairs({ 1, 2, 9 }) do
    s.fieldData[fid] = { fieldArea = 0.04, nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0,
                         pH = OLD, zoneData = {}, sessionCoverageCells = {} }
  end
  s.valueMaps = newMap()
  for _, fid in ipairs({ 1, 2, 9 }) do paintOld(s.valueMaps, fid, OLD) end
  return s
end

-- The genesis oracle: the same deterministic rule the re-roll uses.
local oracle = newSys()
local GEN = {}
for _, fid in ipairs({ 1, 2, 9 }) do GEN[fid] = oracle:_computeInitialSoil(fid).pH end
local RAW_GEN = {}
for fid, v in pairs(GEN) do RAW_GEN[fid] = PositionalPH.phRaw(v) end
T.ok("RR 0a: the genesis pH differs from the old map value on every field (a real change to see)",
     math.abs(GEN[1] - OLD) > 0.05 and math.abs(GEN[2] - OLD) > 0.05 and math.abs(GEN[9] - OLD) > 0.05)
T.ok("RR 0b: the genesis pH is off the raw grid on field 1, so a missing refresh is visible",
     math.abs(PositionalPH.phValue(RAW_GEN[1]) - GEN[1]) > 1e-6)
T.ok("RR 0c: before any re-roll, field 1 holds old pixels AND raw-zero ground",
     (function() local p = pixelsOf(oracle.valueMaps, 1); local zeros, olds = 0, 0
        for _, v in ipairs(p) do if v == 0 then zeros = zeros + 1 elseif v == PositionalPH.phRaw(OLD) then olds = olds + 1 end end
        return zeros > 0 and olds > 0 and zeros + olds == #p end)())

-- =====================================================================
-- GROUP A: rerollAllFields, the map and the report.
-- =====================================================================
do
  local s = newSys()
  local reqs = {}
  local real = s._applyPHFootprint
  s._applyPHFootprint = function(self, fid, req) reqs[#reqs + 1] = { fid = fid, req = req }; return real(self, fid, req) end
  local ok, err = pcall(SoilFertilitySystem.rerollAllFields, s)
  T.ok("RR A0: rerollAllFields ran (" .. tostring(err) .. ")", ok)
  T.eq("RR A1: the writer was asked once per field", #reqs, 3)
  local byField = {}
  for _, r in ipairs(reqs) do byField[r.fid] = r.req end
  T.eq("RR A2: as a SET", byField[1] and byField[1].operation, PositionalPH.OP_SET)
  T.eq("RR A3: over the FIELD domain", byField[1] and byField[1].scope, PositionalPH.SCOPE_FIELD)
  T.eq("RR A4: with the reroll source token", byField[1] and byField[1].source, "reroll")
  T.near("RR A5: at the re-rolled scalar (the genesis value)", byField[1] and byField[1].value, GEN[1], 1e-9)
  T.ok("RR A6: every union pixel of field 1 now equals phRaw(new pH), the raw-zero strip included",
       allEqual(pixelsOf(s.valueMaps, 1), RAW_GEN[1]))
  T.ok("RR A7: and of fields 2 and 9", allEqual(pixelsOf(s.valueMaps, 2), RAW_GEN[2]) and allEqual(pixelsOf(s.valueMaps, 9), RAW_GEN[9]))
  local rep, how = s:_phReportRead(1)
  T.eq("RR A8: the report after the re-roll is CURRENT and served as the field report", how, PositionalPH.READ_FIELD)
  T.near("RR A9: and equals the new pH, quantised", rep, PositionalPH.phValue(RAW_GEN[1]), 1e-9)
  T.eq("RR A10: the scalar was refreshed to exactly the report value", s.fieldData[1].pH, rep)
  T.ok("RR A11: the N/P/K/OM seed still ran (vmSeedField untouched)",
       (function() for _, c in ipairs(s.valueMaps.calls) do if c == "seed:nitrogen" then return true end end return false end)())
  T.ok("RR A12: and vmSeedField never seeded pH itself (the gap is real: the writer is pH's only path)",
       (function() for _, c in ipairs(s.valueMaps.calls) do if c == "seed:pH" or c == "paint:pH" then return false end end return true end)())
end

-- =====================================================================
-- GROUP B: THE CONSEQUENCE, two-sided. Re-roll, then lime, then the refresh the
-- next pH write performs. Routed: the scalar tracks the NEW base. Control with the
-- routing removed: the scalar snaps back to the OLD mean.
-- =====================================================================
local LIME = 0.30
do
  local s = newSys()
  s:rerollAllFields()
  local afterReroll = s.fieldData[1].pH
  s:_phApplyField(1, PositionalPH.OP_DELTA, LIME, nil, nil, 'application')   -- lime through the real adapter, refresh inside
  local tracked = s.fieldData[1].pH
  T.ok("RR B1: routed: after the re-roll the scalar is the new base", math.abs(afterReroll - GEN[1]) < 0.01)
  T.ok("RR B2: routed: liming moves the scalar UP FROM THE NEW BASE", tracked > afterReroll and math.abs(tracked - (GEN[1] + LIME)) < 0.02)
end
do
  local s = newSys()
  s._phRerollField = function() end            -- the routing removed: today's code before this item
  s:rerollAllFields()
  local afterReroll = s.fieldData[1].pH
  T.ok("RR B3: control: the scalar alone says the new base", math.abs(afterReroll - GEN[1]) < 1e-9)
  T.ok("RR B4: control: but the map still holds the OLD pixels", allEqual((function() local p, out = pixelsOf(s.valueMaps, 1), {}
       for _, v in ipairs(p) do if v ~= 0 then out[#out + 1] = v end end return out end)(), PositionalPH.phRaw(OLD)))
  s:_phApplyField(1, PositionalPH.OP_DELTA, LIME, nil, nil, 'application')
  local snapped = s.fieldData[1].pH
  T.ok("RR B5: control: the next pH write republishes the OLD mean plus the lime, the re-roll UNDONE",
       math.abs(snapped - (OLD + LIME)) < 0.02 and math.abs(snapped - (GEN[1] + LIME)) > 0.05)
end

-- =====================================================================
-- GROUP C: rerollUnownedFields. The owned field and the NPC field keep their pixels
-- byte for byte; the unowned field is re-rolled through the writer.
-- =====================================================================
do
  local s = newSys()
  local before1, before9 = pixelsOf(s.valueMaps, 1), pixelsOf(s.valueMaps, 9)
  local reqs = {}
  local real = s._applyPHFootprint
  s._applyPHFootprint = function(self, fid, req) reqs[#reqs + 1] = fid; return real(self, fid, req) end
  local ok, err = pcall(function() return s:rerollUnownedFields() end)
  T.ok("RR C0: rerollUnownedFields ran (" .. tostring(err) .. ")", ok)
  T.eq("RR C1: exactly one field went to the writer", #reqs, 1)
  T.eq("RR C2: the unowned, non-NPC one", reqs[1], 2)
  T.ok("RR C3: the owned field's pixels are byte-identical before and after", sameList(before1, pixelsOf(s.valueMaps, 1)))
  T.ok("RR C4: the NPC-managed field's pixels are byte-identical before and after", sameList(before9, pixelsOf(s.valueMaps, 9)))
  T.ok("RR C5: the unowned field's union pixels all equal phRaw(new pH)", allEqual(pixelsOf(s.valueMaps, 2), RAW_GEN[2]))
  T.eq("RR C6: the owned scalar is untouched", s.fieldData[1].pH, OLD)
  T.eq("RR C7: the unowned scalar was refreshed to the quantised map value", s.fieldData[2].pH, PositionalPH.phValue(RAW_GEN[2]))
end

-- =====================================================================
-- GROUP D: the writer absent. Both re-rolls still run, and nothing is painted for pH,
-- which is what this branch did before the item.
-- =====================================================================
do
  local s = newSys()
  s._applyPHFootprint = false
  local before = pixelsOf(s.valueMaps, 1)
  local ok, err = pcall(SoilFertilitySystem.rerollAllFields, s)
  T.ok("RR D1: rerollAllFields survives a missing writer (" .. tostring(err) .. ")", ok)
  T.ok("RR D2: and leaves the pH pixels alone", sameList(before, pixelsOf(s.valueMaps, 1)))
  local ok2, err2 = pcall(function() return s:rerollUnownedFields() end)
  T.ok("RR D3: rerollUnownedFields survives a missing writer (" .. tostring(err2) .. ")", ok2)
end

g_server = saved.g_server
g_fieldManager.fields = saved.fields
g_farmlandManager, NpcSoilBridge, getWorldTranslation = saved.g_farmlandManager, saved.NpcSoilBridge, saved.getWorldTranslation
g_currentMission.getFarmId = saved.getFarmId
