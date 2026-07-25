-- prelude.lua - minimal FS25 engine mock + tiny test framework.
-- Loaded first by run-tests.mjs, before any src module and the test file itself.
-- Only stubs what module load + the functions under test actually touch; extend as
-- new tests need more of the engine surface.

-- ── Lua 5.1 ↔ fengari (5.3) shims ──────────────────────────
unpack = unpack or table.unpack

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

g_i18n = { getText = function(_self, key) return key end }
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

-- ── FS25 Event system (stubs) ──────────────────────────────
-- Enough of the Event base + InitEventClass for a module's event classes to load
-- and for `SomeEvent.new()` / `:writeStream` / `:readStream` to dispatch in tests.
Event = Event or { new = function(mt) return setmetatable({}, mt) end }
function InitEventClass(class, name) class.className = name; return class end

-- ── Mock network stream ────────────────────────────────────
-- A typed FIFO standing in for an FS25 streamId. Every streamWriteX pushes a
-- {tag,value}; the paired streamReadX pops it and checks the tag. This turns the
-- classic MP desync bug (write order != read order, wrong width, count drift) into
-- a local assertion: a correct writeStream/readStream pair drains the FIFO exactly,
-- with zero type mismatches and zero underflows. No float32 truncation is modelled
-- (values pass through as Lua doubles), matching the repo's other round-trip tests.
function _sfMockStream()
  return { q = {}, r = 1, typeErrors = 0, underflows = 0 }
end

local function _sfPush(s, tag, v) s.q[#s.q + 1] = { t = tag, v = v } end
local function _sfPull(s, tag)
  local e = s.q[s.r]
  if e == nil then s.underflows = s.underflows + 1; return nil end
  s.r = s.r + 1
  if e.t ~= tag then s.typeErrors = s.typeErrors + 1 end
  return e.v
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
function streamWriteUIntN(s, v, _n) _sfPush(s, "uN", v) end
function streamReadUIntN(s, _n)     return _sfPull(s, "uN") end

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
