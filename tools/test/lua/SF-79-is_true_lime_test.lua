-- SF-79-is_true_lime_test.lua: SF-79 section 3.A, the request field isTrueLime.
--
-- THE FIELD. The brief lists isTrueLime among the footprint request fields: "diagnostic
-- classification, not permission or a request to fabricate native credit". Before this
-- item nothing set it and nothing read it. It now answers one question: does this pass
-- ALSO earn vanilla lime credit? That is the engine's own axis, sprayType.isLime
-- (SprayTypeManager.lua:62, true only for a spray type registered as LIME), the flag
-- FSDensityMapUtil.updateSprayArea tests before calling updateLimeArea (:1296-1297).
--
-- TWO AXES THAT AGREE ON TODAY'S DATA AND ARE STILL DIFFERENT FACTS. The #437 burn gate
-- and the VR section curve classify lime by pH SIGN. On the shipped profiles only LIME
-- (+0.16) and LIQUIDLIME (+1.07) raise pH and both are LIME spray types, while GYPSUM
-- (-0.10) is neither, so a "classify by sign" implementation passes every row built from
-- real products. Group B is the divergence row that tells them apart. It is SYNTHETIC:
-- no shipped product raises pH without being a LIME spray type.
--
-- WHO POPULATES THE WORLD. The spray-type table is never hand-set. LIQUIDFERTILIZER,
-- FERTILIZER and LIME are registered first as the base types the engine supplies from
-- the map's sprayTypes XML; then the mod's OWN HookManager:registerCustomSprayTypes runs
-- and registers LIQUIDLIME and GYPSUM itself. Both go through a manager that implements
-- the engine rule verbatim (SprayTypeManager:addSprayType :39-81): isLime is derived
-- from the type name, only when the entry is first created, and the fill type index maps
-- to the spray type. No row sets isLime on anything.
--
-- ENTRY-POINT BAR: Group A. It drives the REAL onFertilizerApplied, then the REAL
-- paintBoomStrip at the same tick, the order the sprayer hook uses
-- (HookManager.lua:4905 then :5183/:5238). The writer is spied only to record the
-- request production built, and the spy still calls the real writer. The one stub on
-- this path is _phRefreshScalar, the report refresh that runs AFTER the request and is
-- not part of this item. The native map is a recorder, as in every SF-79 bar.
--
-- What this bar does NOT prove: that the live game's LIME and LIQUIDLIME spray types
-- carry isLime (the base LIME entry comes from map XML the decoded tree does not hold,
-- and a spray type is only typed on first creation), or that native Needs Lime is
-- untouched. Both are the in-game row.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua, src/hooks/HookManager.lua

local saved = {
  g_server = g_server, g_fillTypeManager = g_fillTypeManager, g_sprayTypeManager = g_sprayTypeManager,
  g_farmlandManager = g_farmlandManager, time = g_currentMission.time, print = print,
}
g_server = true
g_farmlandManager = nil     -- no burn verdict on this path: the burn is not what this bar tests
FillType = FillType or { UNKNOWN = 0 }

local PF = SoilConstants.FERTILIZER_PROFILES

-- ---------------------------------------------------------------------------
-- Fill types. Indices are fixtures; names are shipped profile keys, plus two
-- SYNTHETIC products for group B.
-- ---------------------------------------------------------------------------
local FT, BY_INDEX = {}, {}
local function declare(name, index, massPerLiter)
  FT[name] = { name = name, index = index, massPerLiter = massPerLiter }
  BY_INDEX[index] = FT[name]
end
declare("LIQUIDFERTILIZER", 1, 0.001)
declare("FERTILIZER",       2, 0.001)
declare("LIME",             3, 0.001)
declare("LIQUIDLIME",      10, 0.001)
declare("GYPSUM",          11, 0.0011)
declare("SF79_SYNTH_RAISER",  20, 0.001)   -- SYNTHETIC: raises pH, registered as FERTILIZER
declare("SF79_SYNTH_NOSPRAY", 21, 0.001)   -- SYNTHETIC: raises pH, no spray type at all
g_fillTypeManager = {
  getFillTypeByName      = function(_s, n) return FT[n] end,
  getFillTypeByIndex     = function(_s, i) return BY_INDEX[i] end,
  getFillTypeIndexByName = function(_s, n) return FT[n] and FT[n].index end,
}

-- ---------------------------------------------------------------------------
-- The spray-type manager: the engine's addSprayType rule, verbatim in behaviour.
-- ---------------------------------------------------------------------------
local STM = { sprayTypes = {}, nameToSprayType = {}, fillTypeIndexToSprayType = {}, numSprayTypes = 0 }
function STM:addSprayType(name, litersPerSecond, typeName, sprayGroundType, isBaseType)
  local key = string.upper(name)
  local fillType = g_fillTypeManager:getFillTypeByName(key)
  if fillType == nil then return nil end
  if isBaseType and self.nameToSprayType[key] ~= nil then return nil end
  local st = self.nameToSprayType[key]
  if st == nil then
    self.numSprayTypes = self.numSprayTypes + 1
    st = { name = key, index = self.numSprayTypes, fillType = key, litersPerSecond = litersPerSecond or 0 }
    local t = string.upper(typeName)
    st.isFertilizer = t == "FERTILIZER"
    st.isLime       = t == "LIME"
    st.isHerbicide  = t == "HERBICIDE"
    if not (st.isFertilizer or st.isLime or st.isHerbicide) then return nil end
    table.insert(self.sprayTypes, st)
    self.nameToSprayType[key] = st
    self.fillTypeIndexToSprayType[fillType.index] = st
  end
  st.litersPerSecond = litersPerSecond or st.litersPerSecond or 0
  st.sprayGroundType = sprayGroundType or st.sprayGroundType or 1
  return st
end
function STM:getSprayTypeByName(n) if n == nil then return nil end return self.nameToSprayType[string.upper(n)] end
function STM:getSprayTypeByIndex(i) if i == nil then return nil end return self.sprayTypes[i] end
function STM:getSprayTypeByFillTypeIndex(i) if i == nil then return nil end return self.fillTypeIndexToSprayType[i] end
g_sprayTypeManager = STM

-- The base types the engine supplies (map sprayTypes XML), through the same rule.
STM:addSprayType("LIQUIDFERTILIZER", 0.0081, "FERTILIZER", 2, true)
STM:addSprayType("FERTILIZER",       0.0060, "FERTILIZER", 3, true)
STM:addSprayType("LIME",             0.0040, "LIME",       4, true)

-- The mod's OWN registration registers LIQUIDLIME and GYPSUM.
local hm = HookManager.new()
local regOk, regErr = pcall(HookManager.registerCustomSprayTypes, hm)
T.ok("TL R0: the mod's own registerCustomSprayTypes ran (" .. tostring(regErr) .. ")", regOk)
local llST = STM:getSprayTypeByFillTypeIndex(FT.LIQUIDLIME.index)
local gyST = STM:getSprayTypeByFillTypeIndex(FT.GYPSUM.index)
T.ok("TL R1: LIQUIDLIME's spray type was created by that registration", llST ~= nil and llST.name == "LIQUIDLIME")
T.ok("TL R2: GYPSUM's spray type was created by that registration", gyST ~= nil and gyST.name == "GYPSUM")

-- Group B's synthetic spray type goes through the same engine rule, as FERTILIZER.
PF.SF79_SYNTH_RAISER  = { pH = 0.20 }
PF.SF79_SYNTH_NOSPRAY = { pH = 0.20 }
STM:addSprayType("SF79_SYNTH_RAISER", 0.005, "FERTILIZER", 3, false)

-- ---------------------------------------------------------------------------
-- The native map: a recorder. Every pH write the real writer asks for is kept,
-- with its geometry, so group C can compare two writes exactly.
-- ---------------------------------------------------------------------------
local function vertsKey(verts)
  local parts = {}
  for _, v in ipairs(verts) do parts[#parts + 1] = string.format("%.6f,%.6f", v.x, v.z) end
  return table.concat(parts, ";")
end
local function newVM()
  local vm = { available = true, ops = {} }
  local def = PositionalPH.phDef()
  function vm:getLayerEntry(layer) if layer == PositionalPH.PH_LAYER then return { def = def } end return nil end
  function vm:getGrainMetres() return 2 end
  function vm:setPolygonWhere(layer, verts, raw, lo, hi, gd)
    self.ops[#self.ops + 1] = string.format("set|%s|%d|%d|%d|%s|%s", layer, raw, lo, hi, vertsKey(verts), tostring(gd))
    return true
  end
  function vm:applyRawDeltaToPolygonBand(layer, verts, d, lo, hi, _opts, gd)
    self.ops[#self.ops + 1] = string.format("add|%s|%d|%d|%d|%s|%s", layer, d, lo, hi, vertsKey(verts), tostring(gd))
    return {}
  end
  function vm:addPaintStrip(layer) self.ops[#self.ops + 1] = "strip|" .. tostring(layer) end
  return vm
end

local FID = 7
local function newSys()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings  = { enabled = true, replenishmentRate = 3 }
  s.fieldData = { [FID] = { fieldArea = 2.0, _farmlandAreaConfirmed = true, sessionCoverageCells = { seeded = true },
                            nitrogen = 50, phosphorus = 50, potassium = 50, organicMatter = 3.0, pH = 6.0 } }
  s.valueMaps   = newVM()
  s.hookManager = hm
  s._lastSprayX, s._lastSprayZ = 20, 20
  s.showNotification = function() end
  -- The report refresh runs after the request and is outside this item.
  s._phRefreshScalar = function() end
  local reqs = {}
  s._applyPHFootprint = function(self, fieldId, req)
    reqs[#reqs + 1] = req
    return SoilFertilitySystem._applyPHFootprint(self, fieldId, req)
  end
  return s, reqs
end

-- One sprayer tick through production's entry point: onFertilizerApplied, then
-- paintBoomStrip at the same tick. Returns the requests by scope and the log lines.
local function sprayTick(product, liters)
  local s, reqs = newSys()
  g_currentMission.time = 5000
  local lines = {}
  print = function(line) lines[#lines + 1] = tostring(line) end
  local ok, err = pcall(function()
    s:onFertilizerApplied(FID, FT[product].index, liters, nil)
    s:paintBoomStrip(FID, { { x = 14, z = 20 }, { x = 26, z = 20 } }, product,
                     { ax = 14, az = 20, bx = 26, bz = 20 })
  end)
  print = saved.print
  local dot, strip
  for _, r in ipairs(reqs) do
    if r.scope == PositionalPH.SCOPE_POINT then dot = r end
    if r.scope == PositionalPH.SCOPE_STRIP then strip = r end
  end
  return { ok = ok, err = err, dot = dot, strip = strip, reqs = reqs, lines = lines, sys = s }
end

-- =====================================================================
-- GROUP A: real products through production's entry point (THE ENTRY-POINT BAR).
-- =====================================================================
local EXPECT = { LIME = true, LIQUIDLIME = true, GYPSUM = false }
for _, product in ipairs({ "LIME", "LIQUIDLIME", "GYPSUM" }) do
  local want = EXPECT[product]
  local r = sprayTick(product, 1000)
  T.ok("TL A0 " .. product .. ": the tick ran (" .. tostring(r.err) .. ")", r.ok)
  T.ok("TL A1 " .. product .. ": the narrow-tool dot reached the writer", r.dot ~= nil)
  T.ok("TL A2 " .. product .. ": the boom strip reached the writer", r.strip ~= nil)
  T.eq("TL A3 " .. product .. ": the dot request carries isTrueLime=" .. tostring(want), r.dot and r.dot.isTrueLime, want)
  T.eq("TL A4 " .. product .. ": the strip request carries isTrueLime=" .. tostring(want), r.strip and r.strip.isTrueLime, want)
  -- GROUP D rides the same tick: the existing 1000 L milestone line names the class.
  local milestone = {}
  for _, line in ipairs(r.lines) do
    if line:find("FertApply pH", 1, true) then milestone[#milestone + 1] = line end
  end
  T.eq("TL D1 " .. product .. ": exactly one milestone line for the 1000 L crossing", #milestone, 1)
  T.ok("TL D2 " .. product .. ": the milestone line says trueLime=" .. tostring(want),
       milestone[1] ~= nil and milestone[1]:find("trueLime=" .. tostring(want), 1, true) ~= nil)
  T.ok("TL D3 " .. product .. ": and still names the product",
       milestone[1] ~= nil and milestone[1]:find("type=" .. product, 1, true) ~= nil)
end
do
  -- Log frequency is unchanged: a tick that does not cross a 1000 L boundary is silent.
  local r = sprayTick("LIME", 10)
  local n = 0
  for _, line in ipairs(r.lines) do if line:find("FertApply pH", 1, true) then n = n + 1 end end
  T.eq("TL D4: a tick that crosses no 1000 L boundary prints no milestone line", n, 0)
end

-- =====================================================================
-- GROUP B: the divergence rows. SYNTHETIC products: a pH raiser that is not a LIME
-- spray type. The sign axis says lime; the native-credit axis says no.
-- =====================================================================
do
  local r = sprayTick("SF79_SYNTH_RAISER", 1000)
  T.ok("TL B0: SYNTHETIC raiser tick ran (" .. tostring(r.err) .. ")", r.ok)
  T.ok("TL B1: SYNTHETIC raiser: its pH is positive, so the sign axis would call it lime", PF.SF79_SYNTH_RAISER.pH > 0)
  T.eq("TL B2: SYNTHETIC raiser registered as FERTILIZER: dot says isTrueLime=false", r.dot and r.dot.isTrueLime, false)
  T.eq("TL B3: SYNTHETIC raiser registered as FERTILIZER: strip says isTrueLime=false", r.strip and r.strip.isTrueLime, false)
end
do
  local r = sprayTick("SF79_SYNTH_NOSPRAY", 1000)
  T.ok("TL B4: SYNTHETIC product with no spray type: tick ran (" .. tostring(r.err) .. ")", r.ok)
  T.eq("TL B5: SYNTHETIC product with no spray type: a nil spray type is false (dot)", r.dot and r.dot.isTrueLime, false)
  T.eq("TL B6: SYNTHETIC product with no spray type: a nil spray type is false (strip)", r.strip and r.strip.isTrueLime, false)
end

-- =====================================================================
-- GROUP C: the writer is blind to the field. The same request with isTrueLime true,
-- false and nil asks the map for exactly the same operations and returns the same
-- result. A writer that branched on it would be turning a diagnostic into permission.
-- =====================================================================
local SHAPES = {
  { name = "STRIP DELTA up",      req = { operation = PositionalPH.OP_DELTA, scope = PositionalPH.SCOPE_STRIP,
                                          sx = 0, sz = 0, wx = 12, wz = 0, hx = 0, hz = 1, value = 0.30, source = 'application' } },
  { name = "POINT DELTA down",    req = { operation = PositionalPH.OP_DELTA, scope = PositionalPH.SCOPE_POINT,
                                          x = 20, z = 20, value = -0.30, source = 'application' } },
  { name = "POLYGON NORMALIZE",   req = { operation = PositionalPH.OP_NORMALIZE, scope = PositionalPH.SCOPE_POLYGON,
                                          verts = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 } },
                                          value = 0.10, targetLow = 6.0, targetHigh = 7.0, source = 'daily' } },
  { name = "POLYGON SET",         req = { operation = PositionalPH.OP_SET, scope = PositionalPH.SCOPE_POLYGON,
                                          verts = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 } },
                                          value = 6.5, source = 'admin' } },
}
local function runWriter(base, flag)
  local s = newSys()
  local req = {}
  for k, v in pairs(base) do req[k] = v end
  req.isTrueLime = flag
  local res = SoilFertilitySystem._applyPHFootprint(s, FID, req)
  local b = res.bounds
  local resKey = string.format("%s|%s|%s|%s|%s", tostring(res.status), tostring(res.reason),
    tostring(res.mapRevision), tostring(res.reportDirty),
    b and string.format("%.6f,%.6f,%.6f,%.6f", b.minX, b.maxX, b.minZ, b.maxZ) or "nil")
  return table.concat(s.valueMaps.ops, "\n"), resKey, #s.valueMaps.ops
end
for _, shape in ipairs(SHAPES) do
  local opsT, resT, nT = runWriter(shape.req, true)
  local opsF, resF      = runWriter(shape.req, false)
  local opsN, resN      = runWriter(shape.req, nil)
  T.ok("TL C0 " .. shape.name .. ": the writer asked the map for something (not vacuous)", nT > 0)
  T.ok("TL C1 " .. shape.name .. ": isTrueLime=false asks for the same map operations as true", opsF == opsT)
  T.ok("TL C2 " .. shape.name .. ": isTrueLime=nil asks for the same map operations as true", opsN == opsT)
  T.eq("TL C3 " .. shape.name .. ": isTrueLime=false returns the same result as true", resF, resT)
  T.eq("TL C4 " .. shape.name .. ": isTrueLime=nil returns the same result as true", resN, resT)
end

PF.SF79_SYNTH_RAISER, PF.SF79_SYNTH_NOSPRAY = nil, nil
g_server, g_fillTypeManager, g_sprayTypeManager = saved.g_server, saved.g_fillTypeManager, saved.g_sprayTypeManager
g_farmlandManager, g_currentMission.time, print = saved.g_farmlandManager, saved.time, saved.print
