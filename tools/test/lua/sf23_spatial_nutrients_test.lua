-- sf23_spatial_nutrients_test.lua - SPATIAL NUTRIENTS (SF-23)
--
-- The leach / pH / harvest depletion split across the field's moisture bands,
-- normalised so band shares sum exactly to the field-level loss (CONSERVATION),
-- with the floor rule (settle against the RETURNED shift from applyDeltaToPolygon)
-- and neutral-when-absent degradation to the one-band uniform path.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialNutrients.lua

local SN = SpatialNutrients

-- A fake SCS manager whose getMoisture returns per-position values.
local function makeCsMgr(moistures)
  return {
    getMoisture = function(_self, _fid, x, z)
      local key = math.floor(x) .. "_" .. math.floor(z)
      return moistures[key], nil
    end,
    getSoilType = function() return nil end,   -- F157: not published
  }
end

local function sampleField(moistures)
  -- A 60x60 field square so the 10 m sampling step yields many samples.
  g_currentMission = { cropStressManager = makeCsMgr(moistures) }
  local field = { organicMatter = 4, fieldId = 1 }
  local poly = { {x=-30,z=-30}, {x=30,z=-30}, {x=30,z=30}, {x=-30,z=30} }
  local bands = SN:refreshBands(1, field, poly)
  field._snBands = bands
  return field, bands
end

-- ── 1. One band when SCS is absent (uniform fallback, today's behaviour) ─────
do
  g_currentMission = nil
  local field = { organicMatter = 4 }
  local bands = SN:refreshBands(1, field, { {x=-3,z=-3},{x=3,z=-3},{x=3,z=3},{x=-3,z=3} })
  T.eq("absent SCS -> one band", #bands, 1)
  T.eq("one band key 0", bands[1].key, 0)
end

-- ── 2. Bands split a wet/dry field ───────────────────────────────────────────
do
  -- Left half wet (0.9), right half dry (0.1). Grid at step 10 over a 60x60 field
  -- gives one sample per cell; the equal-count bucketing must produce >= 3 bands
  -- and a wet band with a higher moisture mean than a dry band.
  local moistures = {}
  for gx = -30, 20, 10 do
    for gz = -30, 20, 10 do
      local wet = (gx < 0)
      moistures[gx .. "_" .. gz] = wet and 0.9 or 0.1
    end
  end
  local field, bands = sampleField(moistures)
  T.ok("wet/dry field yields multiple bands", #bands > 1)
  -- The wettest band must carry a higher mean moisture than the driest.
  local minM, maxM = 1, 0
  for _, b in ipairs(bands) do
    if b.moisture < minM then minM = b.moisture end
    if b.moisture > maxM then maxM = b.moisture end
  end
  T.ok("wet band mean > dry band mean", maxM > minM)
end

-- ── 3. Conservation: band shares sum exactly to the field loss ───────────────
do
  local moistures = {}
  for gx = -30, 20, 10 do for gz = -30, 20, 10 do
    moistures[gx .. "_" .. gz] = ((gx + gz) % 50) / 50.0
  end end
  local field, bands = sampleField(moistures)
  T.ok("multi-band field for conservation test", #bands > 1)

  local vm = {
    available = true,
    applyDeltaToPolygon = function(_self, _key, _verts, delta)
      return delta   -- full application (floor not hit)
    end,
  }
  local soilSys = {
    valueMaps = vm,
    vmAvailable = function() return true end,
    _vmQueueFieldDelta = function(_self, f, key, d)
      f._vmPend = f._vmPend or {}
      f._vmPend[key] = (f._vmPend[key] or 0) + d
    end,
    _vmFlushFieldDeltas = function() end,
  }

  -- Queue a field-level leach of -10 nitrogen across the bands.
  SN:queueBandedDelta(soilSys, 1, field, "nitrogen", -10)
  -- Sum what landed in each band's pending store.
  local total = 0
  for _bandKey, keys in pairs(field._snPend) do
    for _k, v in pairs(keys) do total = total + v end
  end
  T.near("band shares sum to the field loss", total, -10, 1e-6)
end

-- ── 4. Floor rule: settle against the RETURNED shift ─────────────────────────
do
  local field = { organicMatter = 4, _snBands = {
    { key = 1, moisture = 0.8, points = { {x=-1,z=-1},{x=0,z=-1},{x=1,z=-1},{x=0,z=-2} } },
    { key = 2, moisture = 0.2, points = { {x=-1,z=1},{x=0,z=1},{x=1,z=1},{x=0,z=2} } },
  } }
  -- The map applies only HALF the requested shift (some pixels hit the floor).
  local vm = {
    available = true,
    applyDeltaToPolygon = function(_self, _key, _verts, delta)
      return delta * 0.5
    end,
  }
  local soilSys = {
    valueMaps = vm,
    vmAvailable = function() return true end,
    _vmQueueFieldDelta = function(_self, f, key, d)
      f._vmPend = f._vmPend or {}
      f._vmPend[key] = (f._vmPend[key] or 0) + d
    end,
  }
  -- Queue then flush; the un-applied half must remain in the pending store.
  SN:queueBandedDelta(soilSys, 1, field, "nitrogen", -10)
  SN:flushBands(soilSys, 1, field)
  local remaining = 0
  for _bandKey, keys in pairs(field._snPend) do
    for _k, v in pairs(keys) do remaining = remaining + v end
  end
  T.ok("un-applied remainder kept after floor settle", remaining < 0 and remaining > -6)
end

-- ── 5. Texture degrades to loam when SCS has no getter (F157) ────────────────
do
  g_currentMission = nil
  T.eq("no SCS -> loamy texture", SN:textureWeight({}), 1.0)
  g_currentMission = { cropStressManager = { getSoilType = function() return nil end,
                                             getFieldSoilType = function() return nil end } }
  T.eq("getter returns nil -> loamy texture", SN:textureWeight({}), 1.0)
  g_currentMission = nil
end

-- ── 6. Convex hull ───────────────────────────────────────────────────────────
do
  local hull = SN:convexHull({ {x=0,z=0},{x=2,z=0},{x=2,z=2},{x=0,z=2},{x=1,z=1} })
  T.eq("hull of a square has 4 corners", #hull, 4)
  local h2 = SN:convexHull({ {x=0,z=0},{x=1,z=0} })
  T.eq("degenerate hull is nil", h2, nil)
end

-- ── 7. getSoilValueAtWorld reads the value maps, nil when absent ─────────────
do
  local vm = {
    available = true,
    readValueAtWorld = function(_self, key, _x, _z)
      if key == "nitrogen" then return 42 end
      return nil
    end,
  }
  local soilSys = { valueMaps = vm, vmAvailable = function() return true end }
  T.eq("positional N read", SN:getSoilValueAtWorld(soilSys, "nitrogen", 1, 1), 42)
  T.eq("absent key -> nil", SN:getSoilValueAtWorld(soilSys, "phosphorus", 1, 1), nil)
end
