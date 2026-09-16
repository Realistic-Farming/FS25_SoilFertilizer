-- RSF-F208-ground_condition_cells_spec_test.lua
--
-- The ground-condition relocation foundation: the exact-cell surface (contract
-- section 1), the pre-operation settlement barrier and destination combine policy
-- (section 2), the owner revision and availability overlay (section 6), and the
-- published StockGuard admission interface (section 7).
--
-- WHY THERE IS A FAKE DENSITY ENGINE IN HERE. The whole point of section 1 is that
-- we do NOT trust the UV selection to hit exactly one cell; every write preflights
-- it and refuses when the engine disagrees. A stub that always behaves perfectly
-- would make those refusals unreachable and the bar would prove nothing. So the
-- engine below is built three ways on purpose: one that behaves, one that selects
-- two pixels, and one that reports a value the point read contradicts. The
-- refusal cases assert the BYTES DID NOT MOVE, not merely that a flag came back
-- false, because "refused" and "wrote it anyway and then said no" are the two
-- outcomes that actually differ for a player's save.
--
--!load: src/ground/GroundConditionCells.lua, src/ground/GroundConditionCoordinator.lua, src/ground/GroundConditionAdmission.lua

-- ── Substrate ────────────────────────────────────────────────────────────────

g_server = {}
g_terrainNode = 1

SoilLogger = {
  info = function() end, warning = function() end, debug = function() end, error = function() end,
}

DensityCoordType = { POINT_POINT_POINT = 1 }

MaterialDown    = { LAYER_KEY = "materialAge" }
MaterialWetness = { LAYER_KEY = "materialWetness" }

local RESOLUTION  = 8
local TERRAIN     = 64      -- 8 m per cell

-- A layer is a flat table of raw bytes keyed "gx:gz", plus a throw switch.
local function newLayer(fill)
  return { cells = {}, fill = fill or 0, throwOnSet = false, id = {} }
end

local function layerGet(layer, gx, gz)
  local v = layer.cells[gx .. ":" .. gz]
  if v == nil then return layer.fill end
  return v
end

-- The bit-vector point read the production code uses. Bound to whichever layers
-- the current scenario installed.
local BVMS = {}

getBitVectorMapPoint = function(bvm, gx, gz, _first, _num)
  local layer = BVMS[bvm]
  if layer == nil then error("unknown bvm") end
  return layerGet(layer, gx, gz)
end

getBitVectorMapSize = function(bvm)
  local layer = BVMS[bvm]
  if layer == nil then return nil end
  return layer.width or RESOLUTION
end

-- `mode` drives how the fake engine answers the preflight:
--   "good"      exactly the one aimed cell
--   "twoPixels" a coarser selection that takes in a neighbour
--   "disagree"  one pixel, but a summed value the point read contradicts
local ENGINE_MODE = "good"

DensityMapModifier = {
  new = function(bvm, _first, _num, _node)
    local m = { bvm = bvm, u0 = nil, v0 = nil, u1 = nil, v1 = nil }
    m.setParallelogramUVCoords = function(_self, u0, v0, u1, _v1b, _u2, v2, _coordType)
      -- start, width point, height point: the aimed box is (u0,v0)-(u1,v2).
      m.u0, m.v0, m.u1, m.v1 = u0, v0, u1, v2
    end
    m.executeGet = function(_self, _filter)
      local layer = BVMS[m.bvm]
      if m.u0 == nil then return 0, 0, 0 end
      -- Which cells does this box cover? A cell counts when its CENTRE is inside.
      local sum, n = 0, 0
      for gx = 0, RESOLUTION - 1 do
        for gz = 0, RESOLUTION - 1 do
          local cu, cv = (gx + 0.5) / RESOLUTION, (gz + 0.5) / RESOLUTION
          if cu >= m.u0 and cu <= m.u1 and cv >= m.v0 and cv <= m.v1 then
            sum = sum + layerGet(layer, gx, gz)
            n = n + 1
          end
        end
      end
      if ENGINE_MODE == "twoPixels" then return sum, n + 1, RESOLUTION * RESOLUTION end
      if ENGINE_MODE == "disagree" then return sum + 7, n, RESOLUTION * RESOLUTION end
      return sum, n, RESOLUTION * RESOLUTION
    end
    m.executeSet = function(_self, value, _filter)
      local layer = BVMS[m.bvm]
      if layer.throwOnSet then error("engine refused the set") end
      if m.u0 == nil then return end
      for gx = 0, RESOLUTION - 1 do
        for gz = 0, RESOLUTION - 1 do
          local cu, cv = (gx + 0.5) / RESOLUTION, (gz + 0.5) / RESOLUTION
          if cu >= m.u0 and cu <= m.u1 and cv >= m.v0 and cv <= m.v1 then
            layer.cells[gx .. ":" .. gz] = value
          end
        end
      end
    end
    return m
  end,
}

DensityMapFilter = {
  new = function() return { setValueCompareParams = function() end } end,
}

-- A value-maps double carrying the two condition layers.
local function newValueMaps(ageLayer, wetLayer, resolution)
  local age = ageLayer or newLayer(0)
  local wet = wetLayer or newLayer(0)
  BVMS[age.id] = age
  BVMS[wet.id] = wet
  return {
    available   = true,
    resolution  = resolution or RESOLUTION,
    terrainSize = TERRAIN,
    layers = {
      materialAge     = { bvm = age.id },
      materialWetness = { bvm = wet.id },
    },
    getLayerEntry  = function(self, key) return self.layers[key] end,
    readRawAtWorld = function() return nil end,
    _age = age, _wet = wet,
  }, age, wet
end

local function armedCells(ageLayer, wetLayer, resolution)
  ENGINE_MODE = "good"
  local vm, age, wet = newValueMaps(ageLayer, wetLayer, resolution)
  local cells = GroundConditionCells.new()
  local ok = cells:arm(vm)
  return cells, vm, age, wet, ok
end

-- ── Section 1: arming and geometry ───────────────────────────────────────────
do
  local cells, _vm, _age, _wet, ok = armedCells()
  T.eq("arm: a coherent pair of condition layers arms", ok, true)
  T.eq("arm: reports armed", cells:isArmed(), true)

  local g = cells:getConditionGeometry()
  T.eq("geometry: resolution", g.resolution, RESOLUTION)
  T.eq("geometry: terrain size", g.terrainSize, TERRAIN)
  T.eq("geometry: grain is terrain/resolution", g.grainMetres, TERRAIN / RESOLUTION)
  T.eq("geometry: origin is the negative corner", g.originX, -TERRAIN / 2)
  T.eq("geometry: origin z matches", g.originZ, -TERRAIN / 2)

  -- Detached: mutating the returned table must not move the live grid.
  g.resolution = 999
  T.eq("geometry: the returned table is detached",
       cells:getConditionGeometry().resolution, RESOLUTION)
  T.eq("geometry: a mutated copy is no longer current", cells:isGeometryCurrent(g), false)
end

do
  -- Layers that disagree on width cannot share a cell index.
  local age, wet = newLayer(0), newLayer(0)
  age.width, wet.width = 8, 16
  local cells = GroundConditionCells.new()
  local vm = newValueMaps(age, wet)
  T.eq("arm: mismatched layer widths refuse to arm", cells:arm(vm), false)
  T.eq("arm: and it is not armed afterwards", cells:isArmed(), false)
end

-- ── Section 1: world to cell, edges and nonsense ─────────────────────────────
do
  local cells = armedCells()
  local g = cells:getConditionGeometry()

  local gx, gz = cells:worldToCell(g, -TERRAIN / 2, -TERRAIN / 2)
  T.eq("worldToCell: the negative corner is cell 0", gx, 0)
  T.eq("worldToCell: negative corner z", gz, 0)

  gx = cells:worldToCell(g, TERRAIN / 2 - 0.001, 0)
  T.eq("worldToCell: just inside the positive edge is the last cell", gx, RESOLUTION - 1)

  gx = cells:worldToCell(g, TERRAIN / 2, 0)
  T.eq("worldToCell: the positive edge itself is EXCLUSIVE", gx, nil)

  gx = cells:worldToCell(g, -TERRAIN / 2 - 0.001, 0)
  T.eq("worldToCell: off the negative edge is refused", gx, nil)

  gx = cells:worldToCell(g, 0 / 0, 0)
  T.eq("worldToCell: NaN is refused, not clamped", gx, nil)
  gx = cells:worldToCell(g, math.huge, 0)
  T.eq("worldToCell: infinity is refused, not clamped", gx, nil)
end

-- ── Section 1: exact reads ───────────────────────────────────────────────────
do
  local cells, _vm, age, wet = armedCells()
  age.cells["3:4"] = 77
  wet.cells["3:4"] = 100
  local g = cells:getConditionGeometry()

  local r = cells:readConditionCell(g, 3, 4)
  T.eq("read: exact age", r.ageRaw, 77)
  T.eq("read: exact wetness", r.wetnessRaw, 100)
  T.eq("read: age available", r.ageAvailable, true)
  T.eq("read: wetness available", r.wetnessAvailable, true)

  local bad = cells:readConditionCell(g, RESOLUTION, 0)
  T.eq("read: an out-of-range cell is refused", bad.refused, GroundConditionCells.REFUSE_COORDS)
  T.eq("read: and reports no value rather than a nearest-cell substitute", bad.ageRaw, nil)

  local frac = cells:readConditionCell(g, 1.5, 2)
  T.eq("read: a fractional cell index is refused", frac.refused, GroundConditionCells.REFUSE_COORDS)

  local stale = cells:readConditionCell({ epoch = -1, geometryRevision = -1,
                                          resolution = RESOLUTION, terrainSize = TERRAIN }, 1, 1)
  T.eq("read: a stale geometry is refused", stale.refused, GroundConditionCells.REFUSE_GEOMETRY)
end

-- ── Section 1: the happy write ───────────────────────────────────────────────
do
  local cells, _vm, age, wet = armedCells()
  local g = cells:getConditionGeometry()

  local res = cells:writeConditionCell(g, 2, 5, cells.geometryRevision, 40, 60)
  T.eq("write: a good engine completes the pair", res.ok, true)
  T.eq("write: not partial", res.partial, false)
  T.eq("write: age landed", layerGet(age, 2, 5), 40)
  T.eq("write: wetness landed", layerGet(wet, 2, 5), 60)

  T.eq("write: the neighbour cell was NOT touched on age", layerGet(age, 3, 5), 0)
  T.eq("write: the neighbour cell was NOT touched on wetness", layerGet(wet, 2, 6), 0)
end

-- ── Section 1: the preflight actually refuses ────────────────────────────────
do
  local cells, _vm, age, wet = armedCells()
  local g = cells:getConditionGeometry()
  age.cells["2:5"], wet.cells["2:5"] = 11, 50

  ENGINE_MODE = "twoPixels"
  local res = cells:writeConditionCell(g, 2, 5, cells.geometryRevision, 40, 60)
  T.eq("preflight: a two-pixel selection refuses the write",
       res.refused, GroundConditionCells.REFUSE_PREFLIGHT)
  T.eq("preflight: and reports not ok", res.ok, false)
  -- The rule that matters: a failed preflight writes NOTHING.
  T.eq("preflight: the age byte did not move", layerGet(age, 2, 5), 11)
  T.eq("preflight: the wetness byte did not move", layerGet(wet, 2, 5), 50)
  ENGINE_MODE = "good"
end

do
  local cells, _vm, age, wet = armedCells()
  local g = cells:getConditionGeometry()
  age.cells["2:5"], wet.cells["2:5"] = 11, 50

  ENGINE_MODE = "disagree"
  local res = cells:writeConditionCell(g, 2, 5, cells.geometryRevision, 40, 60)
  T.eq("preflight: a summed value the point read contradicts refuses",
       res.refused, GroundConditionCells.REFUSE_DISAGREE)
  T.eq("preflight: disagreement writes nothing to age", layerGet(age, 2, 5), 11)
  T.eq("preflight: disagreement writes nothing to wetness", layerGet(wet, 2, 5), 50)
  ENGINE_MODE = "good"
end

-- ── Section 1: domain value validation happens BEFORE any write ──────────────
do
  local cells, _vm, age, wet = armedCells()
  local g = cells:getConditionGeometry()
  age.cells["1:1"], wet.cells["1:1"] = 5, 40

  -- 10 sits in the reserved 1..31 band and is not a wetness reading.
  local res = cells:writeConditionCell(g, 1, 1, cells.geometryRevision, 40, 10)
  T.eq("validate: a reserved wetness byte is refused", res.refused, GroundConditionCells.REFUSE_VALUE)
  -- This is the assertion that matters: validating AFTER the age write would have
  -- left a landed age byte behind a refused pair.
  T.eq("validate: and the age byte was not written first", layerGet(age, 1, 1), 5)
  T.eq("validate: wetness untouched", layerGet(wet, 1, 1), 40)

  T.eq("validate: wetness 0 (absent) is writable", GroundConditionCells.isWritableWetnessRaw(0), true)
  T.eq("validate: wetness 24 (unknown) is writable", GroundConditionCells.isWritableWetnessRaw(24), true)
  T.eq("validate: wetness 31 is NOT writable", GroundConditionCells.isWritableWetnessRaw(31), false)
  T.eq("validate: wetness 32 is writable", GroundConditionCells.isWritableWetnessRaw(32), true)
  T.eq("validate: a fractional age raw is refused", GroundConditionCells.isWritableAgeRaw(4.5), false)
  T.eq("validate: age 255 (the ceiling) is writable", GroundConditionCells.isWritableAgeRaw(255), true)
  T.eq("validate: age 256 is refused", GroundConditionCells.isWritableAgeRaw(256), false)
end

-- ── Section 1: a partial pair is reported as partial, not as a refusal ───────
do
  local cells, _vm, age, wet = armedCells()
  local g = cells:getConditionGeometry()
  age.cells["6:6"], wet.cells["6:6"] = 3, 40

  wet.throwOnSet = true
  local res = cells:writeConditionCell(g, 6, 6, cells.geometryRevision, 90, 70)
  T.eq("partial: not reported ok", res.ok, false)
  T.eq("partial: reported partial", res.partial, true)
  T.eq("partial: the age half really did land", layerGet(age, 6, 6), 90)
  T.eq("partial: the wetness half did not", layerGet(wet, 6, 6), 40)
  -- No rollback: the previous value is not proof of what the ground now holds.
  T.eq("partial: the landed half was NOT stamped back to its old value",
       layerGet(age, 6, 6) ~= 3, true)
  wet.throwOnSet = false
end

-- ── Section 2: the destination combine policy ────────────────────────────────
do
  local C = GroundConditionCoordinator.combine

  local empty = C({ occupied = false }, {})
  T.eq("combine: nothing survived and nothing arrived is empty", empty.empty, true)

  -- Zero-litre contributions import neither unknown nor refusal.
  local zero = C({ occupied = false }, {
    { litres = 0, ageRaw = 0,   wetnessRaw = 24 },
    { litres = 5, ageRaw = 40,  wetnessRaw = 60 },
  })
  T.eq("combine: a zero-litre unknown does not make the cell unknown", zero.ageRaw, 40)
  T.eq("combine: nor its wetness", zero.wetnessRaw, 60)

  -- Oldest age and wettest band win.
  local oldest = C({ occupied = false }, {
    { litres = 5, ageRaw = 40, wetnessRaw = 60 },
    { litres = 5, ageRaw = 90, wetnessRaw = 45 },
  })
  T.eq("combine: the oldest age wins", oldest.ageRaw, 90)
  T.eq("combine: the wettest band wins", oldest.wetnessRaw, 60)

  -- A worse destination is preserved: fresh material does not wash an old record out.
  local worse = C({ occupied = true, ageRaw = 200, wetnessRaw = 150 }, {
    { litres = 50, ageRaw = 1, wetnessRaw = 40 },
  })
  T.eq("combine: a surviving older destination is preserved", worse.ageRaw, 200)
  T.eq("combine: a surviving wetter destination is preserved", worse.wetnessRaw, 150)

  -- Positive unknown makes the component unknown.
  local unk = C({ occupied = false }, {
    { litres = 5, ageRaw = 40, wetnessRaw = 60 },
    { litres = 5, ageRaw = 0,  wetnessRaw = 60 },
  })
  T.eq("combine: a positive unknown age makes age unknown", unk.ageRaw, 0)
  T.eq("combine: but leaves a known wetness alone", unk.wetnessRaw, 60)

  -- The ceiling propagates as a refusal and is never averaged into days.
  local ceil = C({ occupied = false }, {
    { litres = 5, ageRaw = 40,  wetnessRaw = 60 },
    { litres = 5, ageRaw = 255, wetnessRaw = 60 },
  })
  T.eq("combine: the age ceiling propagates", ceil.ageRaw, 255)
  T.eq("combine: the ceiling is not averaged with 40", ceil.ageRaw ~= 147, true)

  -- Unknown outranks the ceiling: we cannot claim a mixture is at the ceiling when
  -- one contributor's age is not known at all.
  local both = C({ occupied = false }, {
    { litres = 5, ageRaw = 0,   wetnessRaw = 60 },
    { litres = 5, ageRaw = 255, wetnessRaw = 60 },
  })
  T.eq("combine: unknown outranks the ceiling", both.ageRaw, 0)

  -- Wetness absent on positive material is unknown, not dry.
  local absent = C({ occupied = false }, {
    { litres = 5, ageRaw = 40, wetnessRaw = 0 },
  })
  T.eq("combine: absent wetness on positive material reads unknown", absent.wetnessRaw, 24)
  T.eq("combine: and is NOT treated as bone dry", absent.wetnessRaw ~= 0, true)
end

-- ── Section 2: the settlement barrier ────────────────────────────────────────

local function newOwners(ageCursor, wetCursor, holdWetAt)
  local down = {
    armed = true, ageAppliedThroughDay = ageCursor, ticks = {},
    isArmed = function(self) return self.armed end,
    onAgeTick = function(self, ctx)
      self.ticks[#self.ticks + 1] = { day = ctx.monotonicDay, span = ctx.boundariesCrossed }
      self.ageAppliedThroughDay = ctx.monotonicDay
    end,
  }
  local wetn = {
    armed = true, appliedThroughDay = wetCursor, ticks = {},
    isArmed = function(self) return self.armed end,
    onConditionAccrual = function(self, ctx)
      self.ticks[#self.ticks + 1] = { day = ctx.monotonicDay, span = ctx.boundariesCrossed }
      if holdWetAt ~= nil then
        -- A held day: the owner retains its cursor rather than advancing over it.
        self.appliedThroughDay = holdWetAt
      else
        self.appliedThroughDay = ctx.monotonicDay
      end
    end,
  }
  return down, wetn
end

local function armedCoord(ageCursor, wetCursor, holdWetAt, day)
  local cells = armedCells()
  local down, wetn = newOwners(ageCursor, wetCursor, holdWetAt)
  local soilSystem = { _currentMonotonicDay = function() return day end }
  local coord = GroundConditionCoordinator.new()
  local ok = coord:arm(cells, down, wetn, soilSystem)
  return coord, cells, down, wetn, ok
end

do
  local coord, _cells, down, wetn = armedCoord(100, 100, nil, 105)
  local ok, reason = coord:runSettlementBarrier()
  T.eq("barrier: lagging cursors settle and the barrier passes", ok, true)
  T.eq("barrier: reason OK", reason, GroundConditionCoordinator.BARRIER_OK)
  T.eq("barrier: age was walked from ITS OWN cursor", down.ticks[1].span, 5)
  T.eq("barrier: age was walked to today", down.ticks[1].day, 105)
  T.eq("barrier: wetness was walked from ITS OWN cursor", wetn.ticks[1].span, 5)

  -- A second primitive in the same call must not re-walk the owners.
  coord:runSettlementBarrier()
  T.eq("barrier: a second primitive does not re-walk age", #down.ticks, 1)
  T.eq("barrier: nor wetness", #wetn.ticks, 1)
end

do
  -- Cursors already at today: nothing to settle, and nobody is touched.
  local coord, _cells, down, wetn = armedCoord(105, 105, nil, 105)
  T.eq("barrier: already-settled cursors pass", (coord:runSettlementBarrier()), true)
  T.eq("barrier: age owner was not called at all", #down.ticks, 0)
  T.eq("barrier: wetness owner was not called at all", #wetn.ticks, 0)
end

do
  -- A HELD weather day. The owner keeps its cursor, so pre-operation ground is not
  -- settled and enhanced condition must be unavailable for this operation.
  local coord, _cells, _down, wetn = armedCoord(100, 100, 102, 105)
  local ok, reason = coord:runSettlementBarrier()
  T.eq("barrier: a held weather day fails the barrier", ok, false)
  T.eq("barrier: and says the settle was incomplete",
       reason, GroundConditionCoordinator.BARRIER_SETTLE_FAILED)
  T.eq("barrier: the coordinator did NOT advance the owner's cursor itself",
       wetn.appliedThroughDay, 102)
end

do
  -- First installation: a nil cursor is not a licence to replay history.
  local coord, _cells, down = armedCoord(nil, 100, nil, 105)
  T.eq("barrier: a nil age cursor refuses rather than replaying", (coord:runSettlementBarrier()), false)
  T.eq("barrier: and the owner was never handed an invented span", #down.ticks, 0)
end

do
  -- The environment fallback is the SECOND source, and it works: a soil system
  -- that cannot answer still gets a day from the mission environment.
  local cells = armedCells()
  local down, wetn = newOwners(100, 100, nil)
  local coord = GroundConditionCoordinator.new()
  local savedEnv = g_currentMission ~= nil and g_currentMission.environment or nil
  g_currentMission = g_currentMission or {}
  g_currentMission.environment = { currentMonotonicDay = 105 }
  coord:arm(cells, down, wetn, { _currentMonotonicDay = function() return nil end })
  T.eq("barrier: falls back to the mission environment day", (coord:runSettlementBarrier()), true)
  T.eq("barrier: and used that day", down.ticks[1].day, 105)

  -- No trusted day from EITHER source: no barrier, and therefore no admission.
  local coord2 = GroundConditionCoordinator.new()
  local down2, wetn2 = newOwners(100, 100, nil)
  g_currentMission.environment = nil
  coord2:arm(cells, down2, wetn2, { _currentMonotonicDay = function() return nil end })
  local ok, reason = coord2:runSettlementBarrier()
  T.eq("barrier: no trusted day means no barrier", ok, false)
  T.eq("barrier: and it says so", reason, GroundConditionCoordinator.BARRIER_NO_CLOCK)
  T.eq("barrier: with no clock the owners are never called", #down2.ticks, 0)
  g_currentMission.environment = savedEnv
end

do
  -- Inert owners must not arm: the gated family is the normal shipping state.
  local cells = armedCells()
  local down, wetn = newOwners(100, 100, nil)
  down.armed = false
  local coord = GroundConditionCoordinator.new()
  T.eq("arm: an unarmed age owner refuses to arm the coordinator",
       coord:arm(cells, down, wetn, {}), false)
end

-- ── Section 6: revision and the availability overlay ─────────────────────────
do
  local coord, cells, _down, _wetn = armedCoord(105, 105, nil, 105)
  local g = cells:getConditionGeometry()

  local before = coord:getOwnerRevision()
  coord:applyProjection(g, 1, 2, { ageRaw = 40, wetnessRaw = 60, empty = false })
  local after = coord:getOwnerRevision()
  T.eq("revision: a movement moves the revision",
       GroundConditionCoordinator.revisionsEqual(before, after), false)
  T.eq("revision: two reads of an unchanged owner are equal",
       GroundConditionCoordinator.revisionsEqual(after, coord:getOwnerRevision()), true)

  T.eq("overlay: a clean write leaves the cell available", coord:isUnavailable(1, 2), false)

  -- Force a partial pair and prove the overlay records it.
  local wetLayer = BVMS[cells.wetEntry.bvm]
  wetLayer.throwOnSet = true
  coord:applyProjection(g, 4, 4, { ageRaw = 50, wetnessRaw = 70, empty = false })
  T.eq("overlay: a partial pair marks the cell unavailable", coord:isUnavailable(4, 4), true)
  T.eq("overlay: the reason records that it was partial",
       coord:unavailableReason(4, 4):sub(1, 7), "PARTIAL")
  T.eq("overlay: the count moved", coord:getUnavailableCount(), 1)

  -- Only a successful complete pair clears it.
  wetLayer.throwOnSet = false
  coord:applyProjection(g, 4, 4, { ageRaw = 50, wetnessRaw = 70, empty = false })
  T.eq("overlay: a complete pair clears the flag", coord:isUnavailable(4, 4), false)
  T.eq("overlay: and the count came back down", coord:getUnavailableCount(), 0)
end

do
  -- Clearing is allowed only on a KNOWN zero occupancy.
  local coord, cells = armedCoord(105, 105, nil, 105)
  local g = cells:getConditionGeometry()

  local cleared, why = coord:clearCellIfEmpty(g, 2, 2, { known = false })
  T.eq("clear: an unestablished occupancy check does not clear", cleared, false)
  T.eq("clear: it says why", why, "OCCUPANCY_UNKNOWN")
  T.eq("clear: and it marks the cell unavailable rather than wiping it",
       coord:isUnavailable(2, 2), true)

  cleared, why = coord:clearCellIfEmpty(g, 3, 3, { known = true, positive = true })
  T.eq("clear: a partial removal keeps the source condition", cleared, false)
  T.eq("clear: because the cell is still occupied", why, "STILL_OCCUPIED")

  cleared = coord:clearCellIfEmpty(g, 5, 5, { known = true, positive = false })
  T.eq("clear: a known-empty cell clears", cleared, true)
end

do
  -- The overlay survives save, and refuses a restore onto a different grid.
  local coord, cells = armedCoord(105, 105, nil, 105)
  coord:markUnavailable(1, 1, "TEST")
  local blob = coord:serialize()
  T.eq("save: the overlay serialises its cells", #blob.unavailable, 1)
  T.eq("save: stamped with the grid it was written for", blob.resolution, RESOLUTION)

  local coord2 = armedCoord(105, 105, nil, 105)
  T.eq("restore: a matching grid restores", coord2:deserialize(blob), true)
  T.eq("restore: and the cell is unavailable again", coord2:isUnavailable(1, 1), true)

  blob.resolution = 16
  local coord3 = armedCoord(105, 105, nil, 105)
  T.eq("restore: a different grid is refused rather than mapped onto wrong cells",
       coord3:deserialize(blob), false)
  T.eq("restore: and nothing was applied", coord3:isUnavailable(1, 1), false)
end

-- ── Section 7: the published admission interface ─────────────────────────────
do
  local coord, cells = armedCoord(105, 105, nil, 105)
  local admit = GroundConditionAdmission.new()
  T.eq("admit: arms on an armed coordinator", admit:arm(coord, cells), true)

  local caps = admit:getCapabilities()
  T.eq("caps: publishes groundCondition", caps.groundCondition ~= nil, true)
  T.eq("caps: at admission revision 1", caps.groundCondition.admissionRevision, 1)

  local gc = admit.groundCondition
  T.eq("caps: the table carries admitPrimitive", type(gc.admitPrimitive), "function")
  T.eq("caps: and deliverMovement", type(gc.deliverMovement), "function")

  -- A dot call, as the contract specifies.
  local lease = gc.admitPrimitive({ }, "TEDDER", {}, "area1")
  T.eq("admit: a well-formed primitive is admitted", lease.status, "ADMITTED")
  T.eq("admit: and carries a lease token", type(lease.leaseToken), "string")

  -- A colon call would hand us the table as the footprint.
  local colon = gc.admitPrimitive(gc, "TEDDER", {}, "area1")
  T.eq("admit: a colon call is refused, not read as a footprint", colon.status, "REFUSED")
  T.eq("admit: and says which mistake it was",
       colon.reason, GroundConditionAdmission.REFUSE_COLON_CALL)
  T.eq("admit: a colon call hands back no lease", colon.leaseToken, nil)

  local bad = gc.admitPrimitive(nil, "TEDDER", {}, "area1")
  T.eq("admit: a missing footprint is refused", bad.status, "REFUSED")
  T.eq("admit: as a bad-arguments refusal", bad.reason, GroundConditionAdmission.REFUSE_ARGS)

  -- Delivery projects into the cells.
  local out = gc.deliverMovement(lease.leaseToken, {
    cells = {
      { gx = 1, gz = 1,
        destination   = { occupied = false },
        contributions = { { litres = 10, ageRaw = 60, wetnessRaw = 80 } },
        occupancy     = { known = true, positive = true } },
    },
  })
  T.eq("deliver: the movement is projected", out.projected, 1)
  T.eq("deliver: nothing refused", out.refusedCells, 0)
  T.eq("deliver: the age byte landed", layerGet(BVMS[cells.ageEntry.bvm], 1, 1), 60)
  T.eq("deliver: the wetness byte landed", layerGet(BVMS[cells.wetEntry.bvm], 1, 1), 80)

  -- The lease closes with the primitive.
  T.eq("lease: a live lease is reported for its owner",
       admit:getOpenLeaseCount() >= 1, true)
  gc.closePrimitive(lease.leaseToken)
  local afterClose = gc.deliverMovement(lease.leaseToken, { cells = {} })
  T.eq("lease: delivering on a closed lease is refused", afterClose.status, "REFUSED")
  T.eq("lease: and says the lease is gone",
       afterClose.reason, GroundConditionAdmission.DELIVER_NO_LEASE)
end

do
  -- A refused barrier gives NO lease, and native work is expected to carry on.
  local coord, cells = armedCoord(100, 100, 102, 105)   -- wetness holds
  local admit = GroundConditionAdmission.new()
  admit:arm(coord, cells)
  local gc = admit.groundCondition
  local lease = gc.admitPrimitive({}, "MOWER", {}, "area1")
  T.eq("admit: a refused barrier refuses the primitive", lease.status, "REFUSED")
  T.eq("admit: and hands back no lease token", lease.leaseToken, nil)
  T.eq("admit: no lease was opened", admit:getOpenLeaseCount(), 0)
end

do
  -- A lease never survives a frame boundary.
  g_updateLoopIndex = 500
  local coord, cells = armedCoord(105, 105, nil, 105)
  local admit = GroundConditionAdmission.new()
  admit:arm(coord, cells)
  local gc = admit.groundCondition
  local lease = gc.admitPrimitive({}, "WINDROWER", {}, "area1")
  T.eq("lease: admitted in this frame", lease.status, "ADMITTED")

  g_updateLoopIndex = 501
  local late = gc.deliverMovement(lease.leaseToken, { cells = {} })
  T.eq("lease: a delivery in a later frame is refused", late.status, "REFUSED")
  T.eq("lease: because the lease crossed a frame",
       late.reason, GroundConditionAdmission.DELIVER_STALE_FRAME)
  g_updateLoopIndex = nil
end

do
  -- The capability is ABSENT when the coordinator did not arm. This is the state
  -- that ships today, and a consumer reading it must conclude Soil is absent.
  local cells = armedCells()
  local down, wetn = newOwners(100, 100, nil)
  down.armed = false
  local coord = GroundConditionCoordinator.new()
  coord:arm(cells, down, wetn, {})

  local admit = GroundConditionAdmission.new()
  T.eq("caps: the interface does not publish on an unarmed coordinator",
       admit:arm(coord, cells), false)
  T.eq("caps: getCapabilities carries no groundCondition at all",
       admit:getCapabilities().groundCondition, nil)
  T.eq("caps: and there is no groundCondition table to bind to",
       admit.groundCondition, nil)
end
