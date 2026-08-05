-- polygon_vertex_contract_test.lua - the aimed-write vertex contract.
--
-- Every aimed write in this mod goes through setPolygonRegion, which reads `v.x` and
-- `v.z` off each vertex. The contract is therefore {{x=,z=}, ...} and it is not
-- optional. SF-44's work-area helper returned a FLAT {x1,z1,x2,z2,...} array instead,
-- and the consequence was not a failed write:
--
--   indexing a number raises  ->  the raise is caught by setPolygonRegion's pcall
--   ->  the handler reads any failure as "the engine has no polygon ops"
--   ->  hasPolygonOps is latched false on the SHARED store
--   ->  probePolygonSupport never re-probes, because _polygonProbed is already set
--   ->  EVERY aimed write in the mod is dead for the rest of the session
--
-- So the first mown verge took the age layer, the wetness layer and the yard ladder
-- down together, and left one warning line behind to explain it. The fix is in two
-- halves and both are pinned here: the helper returns the right shape, AND a
-- malformed polygon from any future caller can no longer be mistaken for an engine
-- capability verdict.
--
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua

DensityValueCompareType = DensityValueCompareType or { BETWEEN = 1, EQUAL = 2 }
DensityCoordType        = DensityCoordType        or { POINT_POINT_POINT = 1 }
g_server = g_server or {}

local GOOD = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }
local FLAT = { 0, 0, 10, 0, 10, 10, 0, 10 }   -- the shape that caused the outage

-- A store with a working engine modifier behind it.
local function makeStore(opts)
  opts = opts or {}
  local points = {}
  local modifier = {
    clearPolygonPoints = function() points = {} end,
    addPolygonPointWorldCoords = function(_, x, z)
      if opts.engineRaises then error("engine refused") end
      points[#points + 1] = { x = x, z = z }
    end,
    executeSet = function() return true end,
  }
  local filter = { setValueCompareParams = function() end }
  local vm = setmetatable({}, { __index = SoilValueMaps })
  vm.available = true
  -- Both keys point at the same modifier: "testLayer" for the direct store
  -- assertions, MaterialDown.LAYER_KEY for the end-to-end cascade section.
  local entry = { modifier = modifier, filter = filter }
  vm.layers = { testLayer = entry, [MaterialDown.LAYER_KEY] = entry }
  return vm, function() return points end
end

-- ── 1. The good shape writes ──────────────────────────────

local vm, getPoints = makeStore()
T.ok("a {x=,z=} polygon writes", vm:setPolygonWhere("testLayer", GOOD, 1, 0, 0))
T.eq("and every vertex reached the engine", #getPoints(), 4)
T.eq("in world coords, not indices", getPoints()[2].x, 10)

-- ── 2. The flat shape is REFUSED, and does not latch ──────
-- This is the assertion that would have caught the outage.

vm = makeStore()
T.ok("a flat vertex array is refused", not vm:setPolygonWhere("testLayer", FLAT, 1, 0, 0))
T.ok("and the store does NOT conclude the engine lacks polygon ops", vm.hasPolygonOps ~= false)

-- The proof that it is not a latch: a correct write still lands afterwards.
T.ok("a good polygon still writes after a malformed one", vm:setPolygonWhere("testLayer", GOOD, 1, 0, 0))

-- Every partial shape a caller might invent is refused the same way.
vm = makeStore()
T.ok("vertices missing z are refused",
     not vm:setPolygonWhere("testLayer", { { x = 1 }, { x = 2 }, { x = 3 } }, 1, 0, 0))
T.ok("string coordinates are refused",
     not vm:setPolygonWhere("testLayer", { { x = "1", z = "1" }, { x = 2, z = 2 }, { x = 3, z = 3 } }, 1, 0, 0))
T.ok("and none of those disabled polygon ops", vm.hasPolygonOps ~= false)
T.ok("so a good polygon still writes", vm:setPolygonWhere("testLayer", GOOD, 1, 0, 0))

-- ── 3. A REAL engine failure still latches ────────────────
-- The distinction is the point. Refusing to latch on rubbish must not stop the store
-- noticing an engine that genuinely cannot do polygon ops.

vm = makeStore({ engineRaises = true })
T.ok("a well-formed polygon the engine rejects is refused", not vm:setPolygonWhere("testLayer", GOOD, 1, 0, 0))
T.eq("and THAT does latch, because it is a real capability verdict", vm.hasPolygonOps, false)

-- ── 4. The cascade, end to end through MaterialDown ───────
-- The outage was never really about one bad write. It was that one bad write stood
-- the whole system down.

local function makeDown(store)
  local md = MaterialDown.new()
  md.armed, md.valueMaps = true, store
  return md
end

vm = makeStore()
local md = makeDown(vm)
T.ok("a malformed birth polygon does not record", not md:noteMaterialAt(FLAT, 1, "STRAW"))
T.ok("and MaterialDown does NOT stand down for the session", not md.stoodDown)
T.ok("so the very next good birth still records", md:noteMaterialAt(GOOD, 1, "STRAW"))

-- The tracked-material gate is unaffected by any of this.
T.ok("an untracked material still refuses on a good polygon", not md:noteMaterialAt(GOOD, 1, "CHAFF"))
T.ok("and still does not stand the system down", not md.stoodDown)

-- ── 5. The shape the work-area helper must produce ────────
-- HookManager's buildWorkAreaPolygon is a local, so this pins the contract it has to
-- satisfy rather than the function itself: four corners of an axis-aligned box, each
-- an {x=,z=} table, in an order that encloses area.

local function boxPolygon(minX, minZ, maxX, maxZ)
  return {
    { x = minX, z = minZ },
    { x = maxX, z = minZ },
    { x = maxX, z = maxZ },
    { x = minX, z = maxZ },
  }
end

local box = boxPolygon(5, 5, 15, 25)
vm = makeStore()
T.eq("the work-area shape has four corners", #box, 4)
T.ok("each corner is a table", type(box[1]) == "table" and type(box[3]) == "table")
T.ok("each corner carries numeric x and z",
     type(box[1].x) == "number" and type(box[1].z) == "number")
T.ok("and the store accepts it", vm:setPolygonWhere("testLayer", box, 1, 0, 0))

-- Corners must not collapse: a zero-area box would write nothing and read as a
-- successful birth, which is the quiet half of the same failure class.
T.ok("the box encloses real area", box[1].x ~= box[2].x and box[2].z ~= box[3].z)

-- ── 6. Vertex COUNT guards must count vertices ────────────
-- The sibling failure. A guard written as `#verts < 6` is right for a flat array of
-- three points and rejects EVERY {x=,z=} polygon, because a four-corner work area is
-- length 4. It fails closed and silently: the tedder simply never dries anything.

T.eq("a four-corner polygon has length 4, not 8", #box, 4)
T.ok("so a `< 6` guard would reject it", #box < 6)
T.ok("and a `< 3` guard correctly admits it", not (#box < 3))

-- A degenerate two-point area is still refused by the correct guard.
T.ok("two points is not a polygon", #{ { x = 0, z = 0 }, { x = 1, z = 1 } } < 3)

-- ── 7. The sentinel floor is reachable by members ─────────
-- MaterialWetness.RAW_FLOOR was file-local, so a member reading it got nil and the
-- band floor collapsed to 0, quietly INCLUDING the reserved sentinel band in a read
-- that exists to exclude it.

T.eq("the sentinel floor is exported", type(MaterialWetness.RAW_FLOOR), "number")
T.ok("and it is above the reserved sentinel band", MaterialWetness.RAW_FLOOR > 24)
T.ok("a nil floor would have collapsed to zero", (tonumber(nil) or 0) == 0)
