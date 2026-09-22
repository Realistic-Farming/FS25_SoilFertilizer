-- prelude.lua - minimal FS25 engine mock + tiny test framework.
-- Loaded first by run-tests.mjs, before any src module and the test file itself.
-- Only stubs what module load + the functions under test actually touch; extend as
-- new tests need more of the engine surface.

-- ── Lua 5.1 ↔ fengari (5.3) shims ──────────────────────────
unpack = unpack or table.unpack

-- getfenv was removed in 5.2. FS25 runs 5.1, so mod files use getfenv(0) to
-- publish a global handle (UIHelper does, at :73). Level 0 means the global
-- environment, which here is _G, and that is the only level any of our source
-- asks for. Returning _G for every level is wrong in general and exactly right
-- for what the sources actually do with it.
if getfenv == nil then
  function getfenv(_level) return _G end
end
if setfenv == nil then
  function setfenv(_f, _env) return _f end
end

-- ── FS25 engine globals (stubs) ────────────────────────────
-- Class(base): FS25's OO helper. Returns a metatable whose __index chains to base,
-- which is enough for `setmetatable({}, Class(Foo))` and method dispatch in tests.
function Class(base)
  local mt = {}
  mt.__index = base or mt
  return mt
end

function getWorldTranslation(_node) return 0, 0, 0 end
function getTerrainHeightAtWorldPos(_node, _x, _y, _z) return 0 end
g_terrainNode = nil

g_currentMission = {
  time = 1000,
  environment = { currentDay = 1, daysPerPeriod = 1 },
  missionInfo = {},
}

-- The engine's own global: main.lua:33 sets it to "_en", and main.lua:1187 (and
-- NPCManager.lua:358) reassign it to the client's language suffix at runtime. It is
-- here because getText's missing sentence interpolates it, so a harness that
-- hardcodes the suffix renders a sentence no client ever produces. A bar that wants
-- a non-English client assigns this and puts it back.
g_languageSuffix = "_en"

-- i18n, modelled on the engine rather than on a convenient shim. I18N.lua:175
-- getText returns texts[name] and, when the key is absent, the sentence
-- "Missing '<key>' in l10n<suffix>.xml" with g_languageSuffix interpolated at
-- I18N.lua:186 - never nil, never "" and never the
-- "$l10n_" XML attribute prefix. I18N.lua:194 hasText answers whether the key
-- exists at all, and is false for a nil name. The harness loads no locale file,
-- so by default NO key exists: a gate written the engine's way takes its English
-- fallback here, which is the honest result. A test that needs a translated
-- string registers it with g_i18n:setText(key, text) or by assigning its own
-- object, as several already do.
g_i18n = {
  texts = {},
  setText = function(self, key, value) self.texts[key] = value end,
  hasText = function(self, key)
    if key == nil then return false end
    return self.texts[key] ~= nil
  end,
  getText = function(self, key)
    local ret = self.texts[key]
    if ret == nil then
      return string.format("Missing '%s' in l10n%s.xml", tostring(key), tostring(g_languageSuffix))
    end
    return ret
  end,
}
g_messageCenter = { subscribe = function() end, unsubscribe = function() end, publish = function() end }

-- Minimal in-memory XML mock: the file handle is a plain table keyed by the XML path
-- string, enough for save/load round-trip tests. Extend if a test needs more types.
function setXMLInt(handle, key, value) if handle then handle[key] = value end end
function getXMLInt(handle, key) if handle then return handle[key] end end
function setXMLFloat(handle, key, value) if handle then handle[key] = value end end
function getXMLFloat(handle, key) if handle then return handle[key] end end
function setXMLString(handle, key, value) if handle then handle[key] = value end end
function getXMLString(handle, key) if handle then return handle[key] end end

-- Class tables some modules reference at load; harmless empty stubs.
HookManager = HookManager or { new = function() return {} end }

-- ── Density-map stubs (SF-18 establishment substrate + value-map tests) ──
-- The production substrate is a cached DensityMapModifier machine over the fruit
-- planes (clearPolygonPoints / addPolygonPointWorldCoords / executeSet), wrapped
-- in growthSystem:setIgnoreDensityChanges, per the verified in-mod write path
-- (SoilLayerSystem.writeFieldToLayers). These stubs keep the decision logic
-- (window state, threshold, no-signal-no-thinning, per-region kill) testable
-- without a terrain; a test asserts the write was ATTEMPTED through the stub.
DensityMapMultiModifier = DensityMapMultiModifier or {
  new = function()
    local m = { sets = 0, executed = 0 }
    m.addExecuteSet = function(_self, value)
      m.sets = m.sets + 1
      m._lastTarget = value
    end
    m.execute = function(_self) m.executed = m.executed + 1 end
    return m
  end,
}
DensityMapModifier = DensityMapModifier or {
  new = function()
    local m = { polygons = {}, writes = 0, target = nil }
    m.clearPolygonPoints = function(_self) m.polygons = {} end
    m.addPolygonPointWorldCoords = function(_self, x, z)
      m.polygons[#m.polygons + 1] = { x = x, z = z }
    end
    m.executeSet = function(_self, value, _filter)
      m.writes = m.writes + 1
      m.target = value
    end
    return m
  end,
}
DensityMapFilter = DensityMapFilter or {
  new = function()
    local f = { compares = 0, op = nil, a = nil, b = nil }
    f.setValueCompareParams = function(_self, op, a, b)
      f.compares = f.compares + 1
      f.op, f.a, f.b = op, a, b
    end
    return f
  end,
}
DensityValueCompareType = DensityValueCompareType or { GREATER = 1, BETWEEN = 2, EQUAL = 3 }
DensityRoundingMode = DensityRoundingMode or { INCLUSIVE = 1 }
GrowthMode = GrowthMode or { SEASONAL = 1, DAILY = 2, DISABLED = 3 }
FieldDensityMap = FieldDensityMap or { GROUND_TYPE = 1, SPRAY_TYPE = 2 }
FSDensityMapUtil = FSDensityMapUtil or { removeWeedArea = function() return true end }
g_fieldManager = g_fieldManager or { fields = {} }
g_fruitTypeManager = g_fruitTypeManager or {
  getFruitTypeByName = function(_self, name)
    if name == nil then return nil end
    return {
      name = name,
      index = 1,
      terrainDataPlaneId = 5,
      startStateChannel = 0,
      numStateChannels = 4,
      minHarvestingGrowthState = 6,
    }
  end,
  -- HayBet's fill-type index guard (g_fruitTypeManager and :getFillTypeIndexByName)
  -- previously saw a nil manager and short-circuited to nil; preserve that.
  getFillTypeIndexByName = function() return nil end,
}
g_currentMission.growthSystem = g_currentMission.growthSystem or {
  setIgnoreDensityChanges = function() end,
}
g_currentMission.fieldGroundSystem = g_currentMission.fieldGroundSystem or {
  getDensityMapData = function() return 1, 0, 1 end,
}

-- ── FS25 Event system (stubs) ──────────────────────────────
-- Enough of the Event base + InitEventClass for a module's event classes to load
-- and for `SomeEvent.new()` / `:writeStream` / `:readStream` to dispatch in tests.
Event = Event or { new = function(mt) return setmetatable({}, mt) end }
function InitEventClass(class, name) class.className = name; return class end

-- FarmManager: the farm-id wire width, which SoilScoutingMaskSyncEvent writes and
-- reads on both sides. Value taken from the decompiled engine at
-- farms/FarmManager.lua:2, not guessed: FARM_ID_SEND_NUM_BITS = 4.
--
-- Its absence is why that event had no round-trip test. The production code indexes
-- FarmManager for its width, the harness did not stand in for it, so the event could
-- not be exercised at all and its two UIntN sites were unguarded by construction.
-- MAX_NUM_FARMS is here because sf22_private_mask_spec_test.lua:19 declares
-- `FarmManager = FarmManager or { FARM_ID_SEND_NUM_BITS = 4, MAX_NUM_FARMS = 8 }`.
-- With this prelude stub present that `or` short-circuits, so the shared stub has to
-- be the COMPLETE one or that file silently stops stubbing what its comment says it
-- does. Nothing reads MAX_NUM_FARMS today, so it was latent rather than live.
--
-- A neat small instance of this document's own subject: the `or` idiom is exactly
-- what makes the shadowing silent.
FarmManager = FarmManager or { FARM_ID_SEND_NUM_BITS = 4, MAX_NUM_FARMS = 8 }

-- ── Mock network stream ────────────────────────────────────
-- A typed FIFO standing in for an FS25 streamId. Every streamWriteX pushes a
-- {tag,value}; the paired streamReadX pops it and checks the tag. This turns the
-- classic MP desync bug (write order != read order, wrong width, count drift) into
-- a local assertion: a correct writeStream/readStream pair drains the FIFO exactly,
-- with zero type mismatches and zero underflows. No float32 truncation is modelled
-- (values pass through as Lua doubles), matching the repo's other round-trip tests.
--
-- WIDTH IS NOW CHECKED, having been claimed and not checked since this mock was
-- written. The comment above has always listed "wrong width" among the bugs it turns
-- into an assertion, while streamWriteUIntN took the bit count as `_n` and threw it
-- away. A 3-bit write read back as 4 bits round-tripped perfectly clean, which is a
-- genuine desync: the engine packs and unpacks by that count, so the two sides
-- disagree about where every following field begins.
--
-- Two faults are counted, and they are different failures:
--   widthErrors  the read declared a different bit count than the write. In the
--                engine the reader then consumes the wrong number of bits and every
--                subsequent field is misaligned.
--   rangeErrors  the value does not fit the declared width, which is a violation of
--                the engine's own stated contract for this call.
--
--                An earlier draft of this comment said "the engine truncates
--                silently". That was a model, not a fact: streamWriteUIntN is
--                engine-native and its overflow behaviour is not observable from the
--                decompile, so what happens to an out-of-range value is unknown here
--                and this counter does not claim to know.
--
--                What IS verifiable is the contract, and the engine states it
--                itself. Its debug wrapper at debug/WrapFunctions.lua:718-725 guards
--                the identical predicate:
--                    if 2 ^ numBits - 1 < value or value < 0 then
--                        Logging.error("value %d out of bounds (%d bits, %d max)")
--                        printCallstack()
--                so both bounds and both failure directions are the engine's, not
--                ours.
--
--                And the guard REPORTS without PREVENTING. There is no early return
--                after Logging.error and printCallstack: storeStats runs and the
--                function ends `return engineStreamWriteUIntN(...)`, so the
--                out-of-range write proceeds regardless. That is why a bench check
--                earns its place, and it needs no assumption about which builds the
--                wrapper is active in. (Which is just as well: nothing in the
--                decompiled tree references WrapFunctions at all, so its activation
--                condition is not observable from here either. An earlier draft said
--                "runs only in debug builds", which was another model.)
--
--                Engine callers hold the contract at the call site rather than
--                relying on the primitive: NetworkUtil.lua:67 writes
--                math.floor(value * (2 ^ numBits - 1)), ForestryPhysicsRope.lua:162
--                scales by (2 ^ NUM_LENGTH_BITS - 1), and precisionFarming's
--                ExtendedCombine.lua:51 writes
--                math.min(math.floor(x), YIELD_MAX_VALUE) against the paired
--                YIELD_NUM_BITS. So an out-of-range write is a caller-contract
--                violation, true whatever the native function does with it.
--
-- Neither raises, for the same reason the existing counters do not: a test should see
-- the whole picture rather than dying on the first fault.
function _sfMockStream()
  return { q = {}, r = 1, typeErrors = 0, underflows = 0, widthErrors = 0, rangeErrors = 0 }
end

local function _sfPush(s, tag, v, width)
  if width ~= nil and type(v) == "number" then
    -- Values are unsigned by contract; 2^width - 1 is the largest that survives.
    if v < 0 or v > (2 ^ width) - 1 then s.rangeErrors = s.rangeErrors + 1 end
  end
  s.q[#s.q + 1] = { t = tag, v = v, w = width }
end

local function _sfPull(s, tag, width)
  local e = s.q[s.r]
  if e == nil then s.underflows = s.underflows + 1; return nil end
  s.r = s.r + 1
  if e.t ~= tag then s.typeErrors = s.typeErrors + 1 end
  if e.w ~= width then s.widthErrors = s.widthErrors + 1 end
  return e.v
end

--- Total faults on a stream. Prefer this to adding counters by hand at each call
--- site: a round-trip row written before widthErrors existed would keep passing
--- while ignoring it, which is how the width claim went unchecked in the first place.
function _sfStreamFaults(s)
  if s == nil then return -1 end
  return s.typeErrors + s.underflows + s.widthErrors + s.rangeErrors
end

function streamWriteInt32(s, v)    _sfPush(s, "i32", v) end
function streamReadInt32(s)         return _sfPull(s, "i32") end
function streamWriteFloat32(s, v)   _sfPush(s, "f32", v) end
function streamReadFloat32(s)       return _sfPull(s, "f32") end
function streamWriteUInt8(s, v)     _sfPush(s, "u8", v) end
function streamReadUInt8(s)         return _sfPull(s, "u8") end
function streamWriteString(s, v)    _sfPush(s, "str", v) end
function streamReadString(s)        return _sfPull(s, "str") end
function streamWriteBool(s, v)      _sfPush(s, "bool", v and true or false) end
function streamReadBool(s)          return _sfPull(s, "bool") end
function streamWriteUIntN(s, v, n)  _sfPush(s, "uN", v, n) end
function streamReadUIntN(s, n)      return _sfPull(s, "uN", n) end
function streamWriteUInt16(s, v)    _sfPush(s, "u16", v) end
function streamReadUInt16(s)         return _sfPull(s, "u16") end

-- ── tiny test framework ────────────────────────────────────
-- Results are emitted as ##TEST_ lines that run-tests.mjs parses out of stdout, so
-- ordinary log noise (SoilLogger.print, etc.) is ignored.
T = { _pass = 0, _fail = 0 }

local function _pass(name)
  T._pass = T._pass + 1
  print("##TEST_PASS " .. name)
end
local function _fail(name, msg)
  T._fail = T._fail + 1
  print("##TEST_FAIL " .. name .. " :: " .. tostring(msg))
end

function T.ok(name, cond, msg)
  if cond then _pass(name) else _fail(name, msg or "expected truthy, got " .. tostring(cond)) end
end

function T.eq(name, got, want)
  if got == want then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want " .. tostring(want)) end
end

function T.near(name, got, want, tol)
  tol = tol or 1e-6
  if type(got) == "number" and math.abs(got - want) <= tol then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want ~" .. tostring(want) .. " (tol " .. tol .. ")") end
end

function T.summary()
  print("##TEST_SUMMARY " .. T._pass .. " " .. T._fail)
end
