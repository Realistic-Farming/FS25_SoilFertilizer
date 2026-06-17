-- prelude.lua — minimal FS25 engine mock + tiny test framework.
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
