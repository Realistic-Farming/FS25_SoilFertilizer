-- zone_yield_sf14_test.lua
-- SF-14 ZONE YIELD OF THE ESTABLISHED CROP: the executable bar for the
-- per-cell growth-time capture, the area-weighted harvest read, and THE
-- CALIBRATION INVARIANT the whole system rests on: a uniform untrafficked
-- field's area-weighted read reconciles against computeYieldModifier output
-- for the same inputs. The capture formula IS the same single source of truth
-- (`_yieldModifierFromNutrients`) evaluated with the CELL's own N/P/K, clamped
-- to the band at write time, so on a uniform field every captured cell equals
-- computeYieldModifier output and the read reconciles by construction.
--
-- THE BAND is AWAITING-SPINE: 0.7..1.15 around 1.0 is the stated neutral
-- default, locked here so a later edit is a deliberate act. A field whose
-- modifier would fall outside the band is BOUNDED by the band's own
-- floor/ceiling (the brief's named "bounded divergence", never unbounded).
--
-- SF-14 v2.0 (REPLACEMENT): capture rides the engine's FINISHED_GROWTH_PERIOD
-- message (one drained delivery = one capture pass), the read is a pre-cut
-- spatial context (`preparePreCutContext`) over the true work-area polygon,
-- fruit-masked, area-weighted per SF-25's ratified rule. The daily accrual
-- and the hopper FillUnit yield-modifier hook are gone.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua, src/ViabilityMask.lua, src/ZoneYield.lua

local ZY = ZoneYield

-- 1. THE BAND IS ONE GROUPED DECLARATION with the neutral defaults.
do
  T.near('band.floor', ZY.BAND_FLOOR, 0.7, 1e-9)
  T.near('band.ceiling', ZY.BAND_CEILING, 1.15, 1e-9)
  T.ok('band.ordered', ZY.BAND_FLOOR < 1.0 and 1.0 < ZY.BAND_CEILING)
  -- The daily accrual id/priority are GONE in the v2.0 replacement.
  T.eq('band.noDailyAccrualId', ZY.DAILY_ACCURAL_ID, nil)
  T.eq('band.noDailyAccrualPriority', ZY.DAILY_ACCURAL_PRIORITY, nil)
end

-- The stub soil system carrying the real shared formula, exactly as yield_test
-- builds it. Everything below reconciles through THIS formula.
local function newSys(fieldData)
  return setmetatable({
    settings = {
      enabled          = true,
      nutrientCycles   = true,
      weedPressure     = false,
      pestPressure     = false,
      diseasePressure  = false,
      compactionEnabled = false,
    },
    fieldData = fieldData or {},
  }, { __index = SoilFertilitySystem })
end

local WHEAT = { name = 'wheat', index = 1, terrainDataPlaneId = 5,
                startStateChannel = 0, numStateChannels = 4,
                minHarvestingGrowthState = 6, maxHarvestingGrowthState = 8,
                minForageGrowthState = 6 }

-- 2. THE CAPTURE FORMULA, per cell. On a uniform field (every cell carries the
--    field-average N/P/K), captureScore MUST equal computeYieldModifier output
--    for the same inputs - the reconciliation invariant.
do
  local sys = newSys({ [1] = { nitrogen = 80, phosphorus = 80, potassium = 80, organicMatter = 3.5 } })
  local prevFtm = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function(_self, _i) return WHEAT end }
  local field = { nitrogen = 80, phosphorus = 80, potassium = 80, organicMatter = 3.5 }

  -- Full-nutrient uniform field: no penalty, modifier 1.0 (in band).
  local mod = sys:computeYieldModifier(1, 1)
  local captured = ZY.captureScore(sys, field, 'wheat', 80, 80, 80)
  T.near('calib.fullNutrientsModifier', mod, 1.0, 1e-9)
  T.near('calib.fullNutrientsReconciles', captured, mod, 1e-9)

  -- Uniformly deficient field, still in band: 40 < threshold 50 → 0.8.
  sys.fieldData[2] = { nitrogen = 40, phosphorus = 40, potassium = 40, organicMatter = 3.5 }
  local field2 = { nitrogen = 40, phosphorus = 40, potassium = 40, organicMatter = 3.5 }
  field2.frozenYieldModifier = nil
  local mod2 = sys:computeYieldModifier(2, 1)
  local captured2 = ZY.captureScore(sys, field2, 'wheat', 40, 40, 40)
  T.near('calib.deficientInBand', mod2, 0.8, 1e-6)
  T.near('calib.deficientReconciles', captured2, mod2, 1e-6)

  -- A NON-uniform field: the per-cell score tracks its own N/P/K, not the
  -- field average - a rich pocket captures richer than a poor pocket.
  local rich = ZY.captureScore(sys, field, 'wheat', 90, 90, 90)
  local poor = ZY.captureScore(sys, field, 'wheat', 20, 20, 20)
  T.ok('calib.richBeatsPoor', rich > poor)

  -- BAND BOUND: a starved uniform field would compute below the band floor
  -- (0.5 at MAX_PENALTY); the capture clamps to the band's floor, the named
  -- "bounded lower yield", never lower.
  local starvedMod = sys:_yieldModifierFromNutrients(
    { organicMatter = 3.5 }, 'wheat', 0, 0, 0, nil)
  T.ok('calib.starvedWouldBeBelowFloor', starvedMod < ZY.BAND_FLOOR)
  T.near('calib.starvedClampsToFloor', ZY.captureScore(sys, field, 'wheat', 0, 0, 0), ZY.BAND_FLOOR, 1e-9)
  -- The ceiling clamp is exercised directly through a stub whose raw formula
  -- exceeds the band (the real formula's OM bonus tops out at ~1.05, inside the
  -- band, so this is a defensive bound, not a reachable path).
  local overCeiling = { _yieldModifierFromNutrients = function() return 1.3 end }
  T.near('calib.ceilingClamp', ZY.captureScore(overCeiling, {}, 'wheat', 60, 60, 60), ZY.BAND_CEILING, 1e-9)
  -- An unreadable cell (nil inputs) captures the band's neutral, never "dead".
  T.near('calib.nilInputsNeutral', ZY.captureScore(sys, field, 'wheat', nil, nil, nil), 1.0, 1e-9)
  g_fruitTypeManager = prevFtm
end

-- 3. THE AREA-WEIGHTED AGGREGATION (SF-25's ratified positional integral).
do
  T.near('agg.uniform', ZY.aggregateAreaWeighted({ {value=0.85, area=1}, {value=0.85, area=1} }), 0.85, 1e-9)
  local mixed = ZY.aggregateAreaWeighted({
    {value=1.0, area=2}, {value=0.5, area=2}, {value=0.9, area=2},
  })
  T.near('agg.weightedMean', mixed, 0.8, 1e-9)
  -- Unwritten cells (value nil) contribute no area; empty input is nil, never 0.
  local partial = ZY.aggregateAreaWeighted({ {value=nil, area=1}, {value=1.0, area=1} })
  T.near('agg.unwrittenSkipped', partial, 1.0, 1e-9)
  T.eq('agg.emptyIsNil', ZY.aggregateAreaWeighted({}), nil)
  T.eq('agg.nilIsNil', ZY.aggregateAreaWeighted(nil), nil)
end

-- 4. THE SF-55 COMPOSITION LINE (addendum 2026-08-05). A nil drag reads as
--    zero, so the read is unchanged until SF-55 lands.
do
  T.near('drag.nilIsIdentity', ZY.composeDrag(0.9, nil), 0.9, 1e-9)
  T.near('drag.dragScales', ZY.composeDrag(1.0, 0.2), 0.8, 1e-9)
  T.near('drag.dragBounded', ZY.composeDrag(1.0, 5.0), 0.0, 1e-9)
  T.near('drag.capturedBounded', ZY.composeDrag(9.0, nil), ZY.BAND_CEILING, 1e-9)
  T.near('drag.nilCaptured', ZY.composeDrag(nil, 0.5), 1.0, 1e-9)
end

-- 5. POINT-IN-POLYGON (pure ray cast) + the capture lattice derivation.
do
  local square = { {x=0,z=0}, {x=80,z=0}, {x=80,z=80}, {x=0,z=80} }
  T.ok('pip.inside', ZY.pointInPolygon(40, 40, square))
  T.ok('pip.outside', not ZY.pointInPolygon(90, 40, square))
  T.ok('pip.onEdge', ZY.pointInPolygon(0, 40, square))
  -- A concave polygon: a point in the notch is outside.
  local concave = { {x=0,z=0}, {x=80,z=0}, {x=80,z=80}, {x=40,z=40}, {x=0,z=80} }
  T.ok('pip.concaveNotchOutside', not ZY.pointInPolygon(40, 60, concave))
  T.ok('pip.concaveArmInside', ZY.pointInPolygon(20, 20, concave))
  -- Fewer than 3 verts is never inside.
  T.ok('pip.degenerate', not ZY.pointInPolygon(1, 1, { {x=0,z=0}, {x=1,z=1} }))

  -- Lattice: an 80x80 field at 8 m step yields 100 centres, all inside.
  local zy = ZY.new({})
  local pts = zy:_deriveCapturePoints(square)
  T.eq('lattice.count', #pts, 100)
  T.ok('lattice.allInside', (function()
    for _, p in ipairs(pts) do
      if not ZY.pointInPolygon(p.x, p.z, square) then return false end
    end
    return true
  end)())
  -- A huge field coarsens to stay at or below CAPTURE_MAX_POINTS.
  local huge = { {x=0,z=0}, {x=4000,z=0}, {x=4000,z=4000}, {x=0,z=4000} }
  local bigPts = zy:_deriveCapturePoints(huge)
  T.ok('lattice.capped', #bigPts <= ZY.CAPTURE_MAX_POINTS)
end

-- 6. THE CAPTURE PASS: rides FINISHED_GROWTH_PERIOD, reads N/P/K per cell
--    through the value maps (three reads), writes the clamped score to the
--    yieldEfficiency layer, and sets the ready marker only after a write.
do
  local zy = ZY.new({})
  zy.isInitialized = true

  local written = {}
  local vm = {
    available = true,
    readValueAtWorld = function(_self, key, _x, _z)
      if key == 'nitrogen' then return 80 end
      if key == 'phosphorus' then return 80 end
      if key == 'potassium' then return 80 end
      return nil
    end,
    writeValueAtWorld = function(_self, key, x, z, value, _radius)
      if key == 'yieldEfficiency' then written[#written + 1] = { x = x, z = z, v = value } end
    end,
  }
  local ss = {
    fieldData = { [7] = { lastCrop = 'wheat',
                          _polyVerts = { {x=0,z=0}, {x=80,z=0}, {x=80,z=80}, {x=0,z=80} } } },
    _getFieldPolyVerts = function(_self, _fid, field) return field._polyVerts end,
    valueMaps = vm,
  }
  zy.manager = { soilSystem = ss, viability = { enabled = true,
    getCellGrowthInfo = function() return {} end } }

  -- _resolveLiveFruit consults g_fieldManager for a live FieldState at the
  -- field centre. Mock a field whose FieldState reports wheat (index 1).
  local prevFM = g_fieldManager
  local prevFS = FieldState
  local prevFT = FruitType
  FruitType = { UNKNOWN = 0 }
  FieldState = { new = function() return { fruitTypeIndex = 1, update = function() end } end }
  g_fieldManager = { fields = { { farmland = { id = 7 }, posX = 40, posZ = 40 } } }
  local prevFTM = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function(_self, _i) return WHEAT end }

  local n = zy:runCapturePass()
  T.ok('pass.captureRan', n == 1)
  T.ok('pass.wroteCells', #written > 0)
  -- A uniform field: every written cell is the field-average modifier, 1.0
  -- (stored as percent, 100).
  local allOne = true
  for _, w in ipairs(written) do
    if math.abs(w.v - 100) > 1e-6 then allOne = false end
  end
  T.ok('pass.uniformAllOne', allOne)
  -- The ready marker is set after a successful write.
  T.ok('pass.readyMarker', ss.fieldData[7].zoneYieldCaptureReady == true)

  -- A field with NO live fruit captures nothing and sets no marker.
  FieldState = { new = function() return { fruitTypeIndex = FruitType.UNKNOWN, update = function() end } end }
  ss.fieldData[8] = { _polyVerts = { {x=0,z=0}, {x=80,z=0}, {x=80,z=80}, {x=0,z=80} } }
  g_fieldManager.fields = { { farmland = { id = 8 }, posX = 40, posZ = 40 } }
  local n2 = zy:runCapturePass()
  T.ok('pass.noFruitSkips', n2 == 0)
  T.eq('pass.noFruitNoMarker', ss.fieldData[8].zoneYieldCaptureReady, nil)

  g_fruitTypeManager = prevFTM
  g_fieldManager = prevFM
  FieldState = prevFS
  FruitType = prevFT
end

-- 7. THE PRE-CUT SPATIAL CONTEXT: preparePreCutContext resolves the fruit,
--    field, and capture, then reads the fruit-filtered yieldEfficiency polygon
--    (or the drag lattice) BEFORE the destructive base Cutter call.
do
  local zy = ZY.new({})
  zy.isInitialized = true

  -- Value maps: readAverageOfPolygon returns a uniform captured field (95%),
  -- readValueAtWorld returns 95 for yieldEfficiency and nil for drag.
  local vm = {
    available = true,
    readAverageOfPolygon = function(_self, key, _verts, _filter)
      if key == 'yieldEfficiency' then return 95, 1 end
      return nil, 0
    end,
    readValueAtWorld = function(_self, key, _x, _z)
      if key == 'yieldEfficiency' then return 95 end
      return nil
    end,
  }
  local ss = {
    fieldData = { [3] = { zoneYieldCaptureReady = true } },
    valueMaps = vm,
  }
  zy.manager = { soilSystem = ss, viability = { enabled = true,
    getCellGrowthInfo = function() return {} end } }

  -- Field resolution: g_fieldManager returns field 3 at the start corner.
  local prevFM = g_fieldManager
  g_fieldManager = { getFieldAtWorldPosition = function(_self, _x, _z)
    return { farmland = { id = 3 } }
  end }

  -- Fruit preflight: FSDensityMapUtil.getFruitArea returns positive area for
  -- the candidate fruit index.
  local prevFDU = FSDensityMapUtil
  FSDensityMapUtil = { getFruitArea = function(_idx, _x, _z, _x2, _z2, _x3, _z3, _prep, _forage)
    return 100
  end }

  -- Fruit filter cache: DensityMapFilter stub from prelude.
  local prevFTM = g_fruitTypeManager
  g_fruitTypeManager = { getFruitTypeByIndex = function(_self, _i) return WHEAT end }

  -- FieldSentry: not disabled, so the spatial path is taken.
  local prevFSAPI = FieldSentry_API
  FieldSentry_API = {
    refreshContract = function() end,
    isFieldSimDisabled = function() return false, nil, false, nil end,
  }
  local prevFSCore = FieldSentry_Core
  FieldSentry_Core = { BLACKLIST = { NPC = 'npc' } }

  -- Work-area geometry: a parallelogram via node identity -> world translation.
  local nodes = {
    start  = { 0,  0 },
    width  = { 40, 0 },
    height = { 0,  8 },
  }
  local prevGWT = getWorldTranslation
  getWorldTranslation = function(node)
    local p = nodes[node]
    if p then return p[1], 0, p[2] end
    return 0, 0, 0
  end

  local cutter = {
    spec_cutter = {
      allowsForageGrowthState = false,
      workAreaParameters = { fruitTypeIndicesToUse = { 1 } },
    },
  }
  local workArea = { start = 'start', width = 'width', height = 'height' }

  -- Spatial path: captured field, fruit present, positive area -> polygon read.
  local ctx = zy:preparePreCutContext(cutter, workArea)
  T.ok('ctx.spatialPath', ctx ~= nil and ctx.path == 'spatial')
  T.near('ctx.spatialScalar', ctx and ctx.scalar, 0.95, 1e-6)
  T.eq('ctx.spatialField', ctx and ctx.fieldId, 3)
  T.eq('ctx.spatialFruit', ctx and ctx.fruitTypeIndex, 1)

  -- No fresh capture yet -> fallback context (never zero yield).
  ss.fieldData[3].zoneYieldCaptureReady = nil
  local ctxFb = zy:preparePreCutContext(cutter, workArea)
  T.ok('ctx.fallbackPath', ctxFb ~= nil and ctxFb.path == 'fallback')
  T.eq('ctx.fallbackScalar', ctxFb and ctxFb.scalar, nil)

  -- Contract-exempt field -> contract path.
  ss.fieldData[3].zoneYieldCaptureReady = true
  FieldSentry_API.isFieldSimDisabled = function() return true, 'npc', false, { contractExempt = true } end
  local ctxC = zy:preparePreCutContext(cutter, workArea)
  T.ok('ctx.contractPath', ctxC ~= nil and ctxC.path == 'contract')

  -- Not live -> nil.
  zy.manager.viability.enabled = false
  T.eq('ctx.notLiveIsNil', zy:preparePreCutContext(cutter, workArea), nil)
  zy.manager.viability.enabled = true

  -- No value maps -> nil.
  zy.manager.soilSystem.valueMaps = nil
  T.eq('ctx.noMapsIsNil', zy:preparePreCutContext(cutter, workArea), nil)
  zy.manager.soilSystem.valueMaps = vm

  getWorldTranslation = prevGWT
  FieldSentry_Core = prevFSCore
  FieldSentry_API = prevFSAPI
  g_fruitTypeManager = prevFTM
  FSDensityMapUtil = prevFDU
  g_fieldManager = prevFM
end

-- 8. THE PUBLISHED READ + GATE: the family's live gate and the socket
--    ViabilityMask's contract carries.
do
  local zy = ZY.new({})
  zy.isInitialized = true
  local prev = g_SoilFertilityManager
  g_SoilFertilityManager = { settings = { experimentalSystems = true,
    allowsExperimentalSystems = function(self) return self.experimentalSystems end } }
  zy.manager.viability = { enabled = true, getCellGrowthInfo = function() return nil end }
  T.ok('live.liveWhenOptInOn', zy:isLive() == true)
  -- Mask disabled gates hard even when the gate is open.
  zy.manager.viability = { enabled = false, getCellGrowthInfo = function() return nil end }
  T.ok('live.maskOffGatesHard', zy:isLive() == false)
  g_SoilFertilityManager = prev

  -- readCapturedEfficiency: nil when not live; reads the layer when live.
  zy.manager.viability = { enabled = true }
  zy.manager.soilSystem = { valueMaps = { available = true,
    readValueAtWorld = function(_self, _key, _x, _z) return 85 end } }
  T.near('socket.readsLayer', zy:readCapturedEfficiency(1, 0, 0), 0.85, 1e-6)
  zy.manager.soilSystem = nil
  T.eq('socket.noMapsIsNil', zy:readCapturedEfficiency(1, 0, 0), nil)

  -- The socket resolves through ViabilityMask:getCellGrowthInfo, so a family
  -- consumer sees capturedEfficiency where the old contract promised nil.
  local vm = { available = true,
    readValueAtWorld = function(_self, key, _x, _z)
      if key == 'yieldEfficiency' then return 92 end
      if key == 'nitrogen' then return 60 end
      return nil
    end }
  zy.manager = { soilSystem = { valueMaps = vm }, viability = { enabled = true,
    getCellGrowthInfo = function() return nil end } }
  local mask = ViabilityMask.new({ zoneYield = zy, soilSystem = { valueMaps = vm } })
  local info = mask:getCellGrowthInfo(1, 0, 0)
  T.near('socket.viaGetCellGrowthInfo', info and info.capturedEfficiency, 0.92, 1e-6)
end

T.summary()
