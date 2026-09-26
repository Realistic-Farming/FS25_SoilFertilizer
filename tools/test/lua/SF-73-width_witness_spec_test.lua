-- SF-73-width_witness_spec_test.lua
--
-- SF-73 section 3, the pre-spend width witness, asserted against the REAL
-- TargetFootprint. The Design raster preflight model (tests/SF-73-raster_preflight_
-- spec_test.lua) enumerated cells on a fixture grid; here the same rows run the
-- shipped enumeration (every fine cell whose square, grown by the guard, meets a
-- polygon) and the shipped classification, over a modelled engine surface (F.ENGINE's
-- shape: fruit plane reader, field ground, farmland id and access, engine field).
-- It proves the cell decision, not native raster alignment or frame cost.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua

local F = TargetFootprint
local C = TargetNutrientCore

-- An 8 x 8 m field of 1 m fine cells at the terrain's corner region.
local CELLS = {}
local function key(i, j) return i .. ":" .. j end
local function env(size)
  size = size or 64
  return {
    terrainSize = function() return size end,
    fruitGrain = function() return 1 end,
    fruitAt = function(x, z)
      local c = CELLS[key(math.floor(x + size / 2), math.floor(z + size / 2))]
      if c == nil then return nil end
      return c.fruit, c.growth or 3
    end,
    fruitDesc = function(i) return ({ [1] = { name = "WHEAT" }, [2] = { name = "BARLEY" }, [3] = { name = "GRASS" } })[i] end,
    onField = function(x, z) return CELLS[key(math.floor(x + size / 2), math.floor(z + size / 2))] ~= nil end,
    farmlandAt = function(x, z)
      local c = CELLS[key(math.floor(x + size / 2), math.floor(z + size / 2))]
      return c and c.farmland or 0
    end,
    canAccess = function(farmId, x, z)
      local c = CELLS[key(math.floor(x + size / 2), math.floor(z + size / 2))]
      return c ~= nil and c.owner == farmId
    end,
    engineFieldFor = function(farmlandId) return farmlandId ~= 0 and {} or nil end,
  }
end
local function fill()
  CELLS = {}
  for i = 32, 39 do for j = 32, 39 do CELLS[key(i, j)] = { fruit = 1, farmland = 7, owner = 1 } end end
end
local function opts()
  return {
    farmId = 1, env = env(), cache = {}, accessCache = {}, cropKeyCache = {},
    soilRecordFor = function(id) return id == 7 or id == 9 end,
    cropKeyFor = function(desc) return C.resolveCropKey(desc.name, SoilConstants.CROP_NUTRIENT_TARGETS,
      SoilConstants.PERENNIAL_FORAGE_NAMES, SoilConstants.SF73_CROP_ALIASES) end,
  }
end
local function box(x0, z0, x1, z1) return { { x = x0, z = z0 }, { x = x1, z = z0 }, { x = x1, z = z1 }, { x = x0, z = z1 } } end
local function run(polys) return F.witness(polys, opts()) end
-- world coordinates of cell (i, j) = [i - 32, i - 31); the field spans [0, 8)

fill()
local b0 = box(0.1, 0.1, 3.9, 3.9)
local count = F.forEachCell({ b0 }, 1, 0, 64, function() end)
T.eq("W4 without a guard every touched cell is counted (a 4 x 4 block)", count, 16)
local guarded = F.forEachCell({ b0 }, 1, 1, 64, function() end)
T.eq("W5 the one-cell outer guard adds the ring (6 x 6)", guarded, 36)
T.eq("W5b the guard ring at a field edge refuses before spend (unknown beyond it)", run({ b0 }).reasons[1], "UNKNOWN_GROUND")
-- an interior width, its guard ring still on the field
local b = box(1.1, 1.1, 4.9, 4.9)
local v = run({ b })
T.ok("W1 a uniform closed width is accepted", v.accepted)
T.eq("W2 its crop is published", v.cropKey, "wheat")
T.eq("W3 its field is published", v.farmlandId, 7)

CELLS[key(33, 34)] = { fruit = 2, farmland = 7, owner = 1 }
T.eq("W6 an interior crop strip a centre or corner sample would miss is refused", run({ b }).reasons[1], "MIXED_CROP")
CELLS[key(33, 34)] = { fruit = 1, farmland = 9, owner = 1 }
T.eq("W7 an interior second field is refused", run({ b }).reasons[1], "MIXED_FIELD")
-- access belongs to the farmland (FarmlandManager.farmlandMapping), so a denied cell is another farm's farmland
CELLS[key(33, 34)] = { fruit = 1, farmland = 9, owner = 2 }
local v8 = run({ b })
local denied = false
for _, r in ipairs(v8.reasons) do if r == "FARM_ACCESS" then denied = true end end
T.ok("W8 interior denied access is refused with FARM_ACCESS", denied and not v8.accepted)
CELLS[key(33, 34)] = nil
local vu = run({ b })
T.eq("W9 a missing cell is unknown ground", vu.reasons[1], "UNKNOWN_GROUND")
T.eq("W10 and UNDETERMINED, never a paid guess", vu.state, "UNDETERMINED")
fill()
CELLS[key(33, 34)] = { fruit = 3, farmland = 7, owner = 1 }
local vg = run({ b })
local hasUnsupported = false
for _, r in ipairs(vg.reasons) do if r == "UNSUPPORTED_CROP" then hasUnsupported = true end end
T.ok("W11 perennial forage under the width is UNSUPPORTED_CROP", hasUnsupported)
fill()
CELLS[key(33, 34)] = { fruit = 1, farmland = 7, owner = 1, growth = 9 }
local o = opts()
o.env.fruitDesc = function(i) return { name = "WHEAT", getIsCut = function(_, s) return s == 9 end } end
local vc = F.witness({ b }, o)
T.eq("W12 a cut (stubble) cell is not a growing crop to feed", vc.reasons[1], "UNSUPPORTED_CROP")

fill()
CELLS[key(35, 33)] = { fruit = 2, farmland = 7, owner = 1 }
local inner = box(1.1, 1.1, 2.9, 2.9)
local ng = F.forEachCell({ inner }, 1, 0, 64, function() end)
T.eq("W14 the unguarded interior touches only its own 2 x 2 cells", ng, 4)
T.eq("W15 the guard refuses early at a neighbouring strip", run({ inner }).reasons[1], "MIXED_CROP")
fill()
CELLS[key(35, 33)] = { fruit = 2, farmland = 7, owner = 1 }
local paint = box(4.6, 1.1, 5.6, 2.9)
T.eq("W16 the native paint polygon catches a strip the swept quad misses", run({ box(0.6, 0.6, 1.4, 1.4), paint }).reasons[1], "MIXED_CROP")
fill()
local rotated = { { x = 1, z = 1 }, { x = 3, z = 1 }, { x = 4, z = 2 }, { x = 2, z = 2 } }
T.ok("W17 a rotated convex polygon is enumerable and accepted", run({ rotated }).accepted)
local vo = run({ box(-33, 1, 1, 2) })
T.eq("W18 terrain the map does not cover cannot be labelled safe", vo.reasons[1], "OUTSIDE_MAP")
F.MAX_CELLS, saved = 10, F.MAX_CELLS
local vb = run({ box(0.1, 0.1, 7.9, 7.9) })
F.MAX_CELLS = 60000
T.eq("W19 a region over the cell budget is refused, never sampled thin", vb.reasons[1], "UNKNOWN_GROUND")

-- ── the swept quad ──────────────────────────────────────────────────────────
local verts, travel, area = F.sweptQuad({ ax = 0, az = 0, bx = 12, bz = 0 }, { ax = 0, az = 0.1, bx = 12, bz = 0.1 })
T.near("Q1 the swept quad's travel", travel, 0.1, 1e-9)
T.near("Q2 its area is width x travel", area, 1.2, 1e-9)
local _, travelSwap, areaSwap = F.sweptQuad({ ax = 0, az = 0, bx = 12, bz = 0 }, { ax = 12, az = 0.1, bx = 0, bz = 0.1 })
T.near("Q3 swapped tips are re-paired, never folded into a bow tie", areaSwap, 1.2, 1e-9)

-- ── the treatment geometry ──────────────────────────────────────────────────
WorkAreaType = { SPRAYER = 3 }
function getWorldTranslation(node) return node.x, 0, node.z end
local function wa(x0, x1, z, t) return { type = t or 3, start = { x = x0, z = z }, width = { x = x1, z = z }, height = { x = x0, z = z - 1 } } end
local function sprayer(areas, idx)
  return { spec_workArea = { workAreas = areas }, spec_sprayer = { usageScale = { workAreaIndex = idx } },
           getIsWorkAreaActive = function(_, a) return a.active ~= false end }
end
local g = F.treatmentGeometry(sprayer({ wa(-6, 6, 0) }))
T.near("G1 one active work area gives its own width", g and g.width, 12, 1e-9)
local g2 = F.treatmentGeometry(sprayer({ wa(-6, 0, 0), wa(0, 6, 0) }))
T.near("G2 collinear touching pieces merge into one line", g2 and g2.width, 12, 1e-9)
local g3, why3 = F.treatmentGeometry(sprayer({ wa(-6, -2, 0), wa(2, 6, 0) }))
T.eq("G3 disjoint pieces are refused rather than risk a double count", why3, "CELL_OVERLAP")
local tip = wa(-9, 9, 0, 1)   -- a wider non-sprayer area (an effect tip) never widens the width
local g4 = F.treatmentGeometry(sprayer({ wa(-6, 6, 0), tip }))
T.near("G4 only SPRAYER work areas count, never a wider other area", g4 and g4.width, 12, 1e-9)
local a1, a2 = wa(-6, 6, 0), wa(-8, 8, 0)
local g5 = F.treatmentGeometry(sprayer({ a1, a2 }, 2))
T.near("G5 usageScale.workAreaIndex selects exactly that area's moved corners", g5 and g5.width, 16, 1e-9)
a2.active = false
local g6 = F.treatmentGeometry(sprayer({ a1, a2 }, 2))
T.eq("G6 an inactive indexed area is no geometry", g6, nil)

T.summary()
