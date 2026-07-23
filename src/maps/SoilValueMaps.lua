-- =========================================================
-- FS25 Realistic Soil & Fertilizer REFINED - Soil Value Maps
-- =========================================================
-- Engine-level per-pixel soil value storage, Precision-Farming
-- style. One runtime bit vector map per layer (N/P/K/pH/OM/
-- compaction) at ~2 m/pixel, created at runtime with
-- createBitVectorMap + loadBitVectorMapNew - no map preparation
-- or GRLE authoring required, works on every map.
--
-- Replaces the legacy 10-40 m Lua "zoneData" cell grid as the
-- per-pixel source of truth for the nutrient layers.
--
-- Storage encoding (8 bits per pixel):
--   raw 0       = "no data" (pixel never written - renders transparent)
--   raw 1..255  = semantic value linearly mapped over [minVal, maxVal]
--
-- Persistence: saveBitVectorMapToFile into the savegame folder
-- (sfSoilMap_<key>.grle), loadBitVectorMapFromFile on load.
--
-- API set used (confirmed FS25 GDN LUADOC / working in-mod code):
--   createBitVectorMap, loadBitVectorMapNew, loadBitVectorMapFromFile,
--   saveBitVectorMapToFile, getBitVectorMapSize, getBitVectorMapPoint,
--   DensityMapModifier (setParallelogramWorldCoords/executeSet/executeGet),
--   DensityMapFilter (setValueCompareParams), PerlinNoiseFilter.
-- =========================================================

---@class SoilValueMaps
SoilValueMaps = {}
local SoilValueMaps_mt = Class(SoilValueMaps)

-- Unscouted-disease marker (Unscouted Indicator). The diseasePressure DISPLAY
-- layer reserves DMV colour state 1 (raw 16-31) for UNKNOWN by flooring its live
-- values to raw 32 (state 2+). A pixel painted at UNKNOWN_RAW lands in that
-- reserved band and colours as the neutral "unscouted" tone, never as clean
-- green. Producers signal unknown by passing UNKNOWN_VALUE (a sentinel below the
-- layer's minVal) into the paint path; encode() maps it to the def's unknownRaw.
-- Defined before LAYER_DEFS so the diseasePressure def can reference UNKNOWN_RAW.
SoilValueMaps.UNKNOWN_RAW   = 24    -- mid state-1 band (16-31)
SoilValueMaps.UNKNOWN_VALUE = -1    -- sentinel semantic value = "not scouted"

-- ─────────────────────────────────────────────────────────
-- Layer definitions
-- Keys match fieldData keys (same convention as SoilLayerSystem).
-- ─────────────────────────────────────────────────────────
-- rawFloor: display layers clamp their encoded minimum to raw 16 so a painted
-- pixel always lands in DMV colour state >= 1. State 0 must stay transparent
-- (raw 0 = off-field "no data"), so without the floor a zero-pressure field
-- would render invisible instead of green.
SoilValueMaps.LAYER_DEFS = {
    { key = "nitrogen",        file = "sfSoilMap_N.grle",   minVal = 0,   maxVal = 100 },
    { key = "phosphorus",      file = "sfSoilMap_P.grle",   minVal = 0,   maxVal = 100 },
    { key = "potassium",       file = "sfSoilMap_K.grle",   minVal = 0,   maxVal = 100 },
    { key = "pH",              file = "sfSoilMap_PH.grle",  minVal = 5.0, maxVal = 7.5 },
    { key = "organicMatter",   file = "sfSoilMap_OM.grle",  minVal = 0,   maxVal = 10  },
    { key = "compaction",      file = "sfSoilMap_CP.grle",  minVal = 0,   maxVal = 100 },
    -- REFINED display layers (field-level agronomy rendered per-pixel)
    { key = "weedPressure",    file = "sfSoilMap_WP.grle",  minVal = 0,   maxVal = 100, rawFloor = 16 },
    { key = "pestPressure",    file = "sfSoilMap_PP.grle",  minVal = 0,   maxVal = 100, rawFloor = 16 },
    -- diseasePressure floors to raw 32 (DMV state 2), reserving state 1 (raw
    -- 16-31) for the UNKNOWN/unscouted marker. unknownRaw is painted directly
    -- when a field is not yet scouted, so unscouted never reads as clean green.
    { key = "diseasePressure", file = "sfSoilMap_DP.grle",  minVal = 0,   maxVal = 100, rawFloor = 32, unknownRaw = SoilValueMaps.UNKNOWN_RAW },
    { key = "urgency",         file = "sfSoilMap_UR.grle",  minVal = 0,   maxVal = 100, rawFloor = 16 },
    { key = "yieldEfficiency", file = "sfSoilMap_YE.grle",  minVal = 0,   maxVal = 100, rawFloor = 16 },
}

local NUM_CHANNELS = 8      -- bits per pixel
local RAW_MIN      = 1      -- raw 0 is reserved as "no data"
local RAW_MAX      = 255
local RAW_SPAN     = RAW_MAX - RAW_MIN   -- 254 usable steps

-- Map resolution: half the terrain size (2 m/px on 2048-4096 m maps, same
-- as Precision Farming), capped at 4096 px so 16x maps stay at 4 m/px and
-- six layers cost at most 6 x 16 MB.
local MIN_RESOLUTION = 1024
local MAX_RESOLUTION = 4096

-- ─────────────────────────────────────────────────────────
-- Encode / decode
-- ─────────────────────────────────────────────────────────

local function encode(value, def)
    -- Unknown marker (unscouted disease): a sentinel value below minVal encodes to
    -- the reserved state-1 raw so the pixel reads as UNKNOWN, never as clean.
    if def.unknownRaw and type(value) == "number" and value < def.minVal then
        return def.unknownRaw
    end
    local clamped  = math.max(def.minVal, math.min(def.maxVal, value or def.minVal))
    local fraction = (clamped - def.minVal) / (def.maxVal - def.minVal)
    local raw = RAW_MIN + math.floor(fraction * RAW_SPAN + 0.5)
    -- Display layers: never drop below the first visible DMV colour state
    if def.rawFloor and raw < def.rawFloor then raw = def.rawFloor end
    return raw
end
SoilValueMaps._encode = encode   -- test seam

local function decode(raw, def)
    if raw == nil or raw <= 0 then return nil end
    local fraction = (raw - RAW_MIN) / RAW_SPAN
    return def.minVal + fraction * (def.maxVal - def.minVal)
end

-- Semantic units represented by one raw step (used for delta quantisation)
local function unitsPerRaw(def)
    return (def.maxVal - def.minVal) / RAW_SPAN
end

-- ─────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────

function SoilValueMaps.new()
    local self = setmetatable({}, SoilValueMaps_mt)
    self.initialized  = false
    self.available    = false
    self.loadedFromSave = false   -- true when ALL layers restored from savegame files
    self.resolution   = 0
    self.terrainSize  = 0
    -- layers[key] = { bvm, modifier, filter, def, loaded }
    self.layers       = {}
    -- Perlin noise masks for seeding variation (1-bit maps + filters)
    self.noiseA       = nil
    self.noiseB       = nil
    self.noiseFilterA = nil
    self.noiseFilterB = nil
    -- Capability flags probed at runtime
    self.hasExecuteAdd  = false
    self.hasPolygonOps  = false
    self._polygonProbed = false
    return self
end

-- ─────────────────────────────────────────────────────────
-- Initialization
-- savegameDir: optional path; when the persisted map files exist
-- there they are restored, otherwise blank maps are created.
-- ─────────────────────────────────────────────────────────

function SoilValueMaps:initialize(savegameDir)
    if self.initialized then return end
    self.initialized = true

    if not g_terrainNode or g_terrainNode == 0 then
        SoilLogger.warning("SoilValueMaps: g_terrainNode not available - per-pixel maps disabled")
        return
    end
    if createBitVectorMap == nil or loadBitVectorMapNew == nil then
        SoilLogger.warning("SoilValueMaps: bit vector map API not available - per-pixel maps disabled")
        return
    end

    self.terrainSize = getTerrainSize(g_terrainNode) or 0
    if self.terrainSize <= 0 then
        SoilLogger.warning("SoilValueMaps: getTerrainSize returned 0 - per-pixel maps disabled")
        return
    end

    self.resolution = math.max(MIN_RESOLUTION,
                     math.min(MAX_RESOLUTION, math.floor(self.terrainSize / 2)))

    local loadedCount = 0
    for _, def in ipairs(SoilValueMaps.LAYER_DEFS) do
        local bvm = createBitVectorMap("SFVM_" .. def.key)
        if bvm == nil or bvm == 0 then
            SoilLogger.warning("SoilValueMaps: createBitVectorMap failed for %s", def.key)
        else
            local loaded = false
            if savegameDir and fileExists ~= nil then
                local path = savegameDir .. "/" .. def.file
                if fileExists(path) then
                    local ok = loadBitVectorMapFromFile(bvm, path, NUM_CHANNELS)
                    if ok then
                        -- Adopt the persisted resolution (may differ if the cap changed)
                        local w, _ = getBitVectorMapSize(bvm)
                        if w and w > 0 then self.resolution = w end
                        loaded = true
                        loadedCount = loadedCount + 1
                    else
                        SoilLogger.warning("SoilValueMaps: failed to load %s - creating blank", path)
                    end
                end
            end
            if not loaded then
                loadBitVectorMapNew(bvm, self.resolution, self.resolution, NUM_CHANNELS, false)
            end

            -- World-coordinate modifier: passing g_terrainNode maps world XZ onto
            -- the full map extent (GDN FS25 weed-control sample pattern).
            local modifier = DensityMapModifier.new(bvm, 0, NUM_CHANNELS, g_terrainNode)
            local filter   = DensityMapFilter.new(modifier)
            self.layers[def.key] = {
                bvm      = bvm,
                modifier = modifier,
                filter   = filter,
                def      = def,
                loaded   = loaded,
            }
        end
    end

    local layerCount = 0
    for _ in pairs(self.layers) do layerCount = layerCount + 1 end
    if layerCount == 0 then
        SoilLogger.warning("SoilValueMaps: no layers created - per-pixel maps disabled")
        return
    end

    self.available      = true
    self.loadedFromSave = (loadedCount == #SoilValueMaps.LAYER_DEFS)

    -- Probe executeAdd availability once (used for uniform field deltas)
    do
        local anyLayer
        for _, entry in pairs(self.layers) do anyLayer = entry break end
        self.hasExecuteAdd = anyLayer ~= nil and type(anyLayer.modifier.executeAdd) == "function"
    end

    self:_initNoiseMasks()

    local metersPerPx = self.terrainSize / self.resolution
    SoilLogger.info("[OK] SoilValueMaps: %d layers at %dx%d px (%.1f m/px)%s executeAdd=%s",
        layerCount, self.resolution, self.resolution, metersPerPx,
        self.loadedFromSave and " [restored from savegame]" or " [fresh]",
        tostring(self.hasExecuteAdd))
end

-- Two 1-bit Perlin masks used to decorate freshly-seeded fields with
-- within-field variation (GDN FS25 ExtendedWeedControl sample pattern).
function SoilValueMaps:_initNoiseMasks()
    if PerlinNoiseFilter == nil or PerlinNoiseFilter.new == nil then
        SoilLogger.debug("SoilValueMaps: PerlinNoiseFilter unavailable - seeding without noise")
        return
    end

    local ok, err = pcall(function()
        local res = self.resolution
        self.noiseA = createBitVectorMap("SFVM_noiseA")
        loadBitVectorMapNew(self.noiseA, res, res, 1, false)
        self.noiseB = createBitVectorMap("SFVM_noiseB")
        loadBitVectorMapNew(self.noiseB, res, res, 1, false)

        -- Deterministic seeds so SP/MP server reseeds identically per save
        local seedBase = 7349
        local perlinA1 = PerlinNoiseFilter.new(self.noiseA, 4, 3, 0.55, seedBase)
        local perlinA2 = PerlinNoiseFilter.new(self.noiseA, 6, 2, 0.50, seedBase + 11)
        local modA = DensityMapModifier.new(self.noiseA, 0, 1, g_terrainNode)
        modA:executeSet(1, perlinA1, perlinA2)

        local perlinB1 = PerlinNoiseFilter.new(self.noiseB, 3, 3, 0.60, seedBase + 101)
        local perlinB2 = PerlinNoiseFilter.new(self.noiseB, 5, 2, 0.45, seedBase + 211)
        local modB = DensityMapModifier.new(self.noiseB, 0, 1, g_terrainNode)
        modB:executeSet(1, perlinB1, perlinB2)

        -- Filters usable against the value-map modifiers (cross-map filtering,
        -- same pattern the base game uses for ground-type-filtered fruit ops)
        self.noiseFilterA = DensityMapFilter.new(self.noiseA, 0, 1)
        self.noiseFilterA:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
        self.noiseFilterB = DensityMapFilter.new(self.noiseB, 0, 1)
        self.noiseFilterB:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
    end)

    if not ok then
        SoilLogger.debug("SoilValueMaps: noise mask init failed (%s) - seeding without noise", tostring(err))
        self.noiseFilterA = nil
        self.noiseFilterB = nil
    end
end

function SoilValueMaps:delete()
    for _, entry in pairs(self.layers) do
        if entry.bvm and entry.bvm ~= 0 then delete(entry.bvm) end
    end
    self.layers = {}
    if self.noiseA and self.noiseA ~= 0 then delete(self.noiseA); self.noiseA = nil end
    if self.noiseB and self.noiseB ~= 0 then delete(self.noiseB); self.noiseB = nil end
    self.noiseFilterA = nil
    self.noiseFilterB = nil
    self.available   = false
    self.initialized = false
end

-- ─────────────────────────────────────────────────────────
-- Persistence
-- ─────────────────────────────────────────────────────────

function SoilValueMaps:saveToSavegame(savegameDir)
    if not self.available or not savegameDir then return end
    if saveBitVectorMapToFile == nil then
        SoilLogger.warning("SoilValueMaps: saveBitVectorMapToFile unavailable - maps not persisted")
        return
    end
    local saved = 0
    for _, entry in pairs(self.layers) do
        local path = savegameDir .. "/" .. entry.def.file
        local ok, err = pcall(saveBitVectorMapToFile, entry.bvm, path)
        if ok then saved = saved + 1
        else SoilLogger.warning("SoilValueMaps: save failed for %s: %s", path, tostring(err)) end
    end
    SoilLogger.info("SoilValueMaps: %d layer maps saved to %s", saved, savegameDir)
end

-- ─────────────────────────────────────────────────────────
-- Layer access helpers
-- ─────────────────────────────────────────────────────────

function SoilValueMaps:getLayerEntry(key)
    return self.layers[key]
end

--- Raw handle + display channel info for the DMV visualization overlay.
--- Reading the top 4 bits (firstChannel=4, numChannels=4) yields 16 colour
--- states; raw 0-15 (incl. the no-data sentinel) maps to state 0 = transparent.
function SoilValueMaps:getOverlayMapData(key)
    local entry = self.layers[key]
    if not entry then return nil end
    return entry.bvm, 4, 4, entry.def
end

local function worldToPixel(self, worldX, worldZ)
    local half = self.terrainSize * 0.5
    local res  = self.resolution
    local px = math.floor((worldX + half) / self.terrainSize * res)
    local pz = math.floor((worldZ + half) / self.terrainSize * res)
    px = math.max(0, math.min(res - 1, px))
    pz = math.max(0, math.min(res - 1, pz))
    return px, pz
end

-- ─────────────────────────────────────────────────────────
-- Point read / write
-- ─────────────────────────────────────────────────────────

--- Read the semantic value at a world position.
---@return number|nil value  nil when unavailable or pixel unwritten
function SoilValueMaps:readValueAtWorld(key, worldX, worldZ)
    if not self.available then return nil end
    local entry = self.layers[key]
    if not entry then return nil end
    local px, pz = worldToPixel(self, worldX, worldZ)
    local raw = getBitVectorMapPoint(entry.bvm, px, pz, 0, NUM_CHANNELS)
    return decode(raw, entry.def)
end

--- Write a semantic value into a square of half-size `radius` (meters).
function SoilValueMaps:writeValueAtWorld(key, worldX, worldZ, value, radius)
    if not self.available then return end
    local entry = self.layers[key]
    if not entry then return end
    local r = radius or 1.5
    local m = entry.modifier
    m:setParallelogramWorldCoords(
        worldX - r, worldZ - r,   -- start
        worldX + r, worldZ - r,   -- width point
        worldX - r, worldZ + r,   -- height point
        DensityCoordType.POINT_POINT_POINT)
    m:executeSet(encode(value, entry.def))
end

--- Read-modify-write delta at a position: reads the pixel under (x,z),
--- adds `delta`, writes the result back over the radius square. Used by
--- residue/amendment incorporation which applies local bumps.
function SoilValueMaps:addValueAtWorld(key, worldX, worldZ, delta, radius)
    if not self.available then return end
    local entry = self.layers[key]
    if not entry then return end
    local current = self:readValueAtWorld(key, worldX, worldZ)
    if current == nil then return end   -- unseeded ground: nothing to modify
    self:writeValueAtWorld(key, worldX, worldZ, current + delta, radius)
end

-- ─────────────────────────────────────────────────────────
-- Strip painting (sprayer boom / work areas)
-- ─────────────────────────────────────────────────────────

--- Paint the real work strip between two boom endpoints with a value.
--- ax/az..bx/bz span the boom laterally; halfThickness (meters) extends the
--- strip along the travel direction so consecutive frames form a continuous
--- painted band (PF-style strips instead of stamped cells).
function SoilValueMaps:paintStrip(key, ax, az, bx, bz, halfThickness, value)
    if not self.available then return end
    local entry = self.layers[key]
    if not entry then return end

    local dx, dz = bx - ax, bz - az
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then
        self:writeValueAtWorld(key, ax, az, value, halfThickness)
        return
    end
    -- Unit perpendicular (travel direction) of the boom line
    local ux, uz = -dz / len, dx / len
    local h = math.max(0.5, halfThickness or 1.5)

    local m = entry.modifier
    m:setParallelogramWorldCoords(
        ax - ux * h, az - uz * h,   -- start corner
        bx - ux * h, bz - uz * h,   -- width point  (along boom)
        ax + ux * h, az + uz * h,   -- height point (along travel)
        DensityCoordType.POINT_POINT_POINT)
    m:executeSet(encode(value, entry.def))
end

-- ─────────────────────────────────────────────────────────
-- Polygon / field-area operations
-- ─────────────────────────────────────────────────────────

-- Probe once whether the engine modifier supports polygon world coords
-- (clearPolygonPoints/addPolygonPointWorldCoords - the same API pair
-- SoilLayerSystem:writeFieldToLayers already uses in production).
local function probePolygonSupport(self, modifier)
    if self._polygonProbed then return self.hasPolygonOps end
    self._polygonProbed = true
    self.hasPolygonOps =
        type(modifier.clearPolygonPoints) == "function"
        and type(modifier.addPolygonPointWorldCoords) == "function"
    return self.hasPolygonOps
end

-- Apply a field polygon (array of {x=,z=}) as the modifier region.
-- Returns true on success, false when polygon ops are unsupported.
local function setPolygonRegion(self, modifier, verts)
    if not probePolygonSupport(self, modifier) then return false end
    local ok = pcall(function()
        modifier:clearPolygonPoints()
        for _, v in ipairs(verts) do
            modifier:addPolygonPointWorldCoords(v.x, v.z)
        end
    end)
    if not ok then
        self.hasPolygonOps = false
        return false
    end
    return true
end

-- Point-in-polygon (ray casting) for the grid fallback path
local function isPointInPoly(px, pz, verts)
    local n = #verts
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local xi, zi = verts[i].x, verts[i].z
        local xj, zj = verts[j].x, verts[j].z
        if ((zi > pz) ~= (zj > pz)) and
           (px < (xj - xi) * (pz - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Iterate a polygon as grid blocks, invoking fn(cx, cz, halfStep) per block
-- centre inside the polygon. Used when engine polygon ops are unavailable
-- and for per-block value computation during seeding.
local MAX_SEED_BLOCKS = 20000
local function forEachPolyBlock(verts, step, fn)
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        local v = verts[i]
        if v.x < minX then minX = v.x end
        if v.x > maxX then maxX = v.x end
        if v.z < minZ then minZ = v.z end
        if v.z > maxZ then maxZ = v.z end
    end
    -- Widen the step if the AABB would exceed the block budget
    local est = math.ceil((maxX - minX) / step) * math.ceil((maxZ - minZ) / step)
    if est > MAX_SEED_BLOCKS then
        step = step * math.ceil(math.sqrt(est / MAX_SEED_BLOCKS))
    end
    local half = step * 0.5
    local count = 0
    local x = minX + half
    while x <= maxX and count < MAX_SEED_BLOCKS do
        local z = minZ + half
        while z <= maxZ and count < MAX_SEED_BLOCKS do
            if isPointInPoly(x, z, verts) then
                fn(x, z, half)
                count = count + 1
            end
            z = z + step
        end
        x = x + step
    end
    return count
end

--- Paint an entire field polygon with a uniform semantic value.
function SoilValueMaps:paintPolygon(key, verts, value)
    if not self.available or not verts or #verts < 3 then return end
    local entry = self.layers[key]
    if not entry then return end
    local raw = encode(value, entry.def)
    local m = entry.modifier
    if setPolygonRegion(self, m, verts) then
        m:executeSet(raw)
    else
        forEachPolyBlock(verts, 8, function(cx, cz, half)
            m:setParallelogramWorldCoords(
                cx - half, cz - half, cx + half, cz - half, cx - half, cz + half,
                DensityCoordType.POINT_POINT_POINT)
            m:executeSet(raw)
        end)
    end
end

--- Seed a field polygon: paint the base value, then add +/- `spread`
--- (semantic units) of within-field variation so a fresh map looks like a
--- real PF soil map instead of a flat colour block.
--- With engine polygon ops + Perlin masks this is 3 modifier calls; the
--- fallback uses per-block deterministic hash noise.
function SoilValueMaps:seedPolygon(key, verts, baseValue, spread)
    if not self.available or not verts or #verts < 3 then return end
    local entry = self.layers[key]
    if not entry then return end
    local def = entry.def
    local m   = entry.modifier
    spread = spread or 0

    if spread > 0 and self.noiseFilterA and self.noiseFilterB
       and setPolygonRegion(self, m, verts) then
        m:executeSet(encode(baseValue, def))
        m:executeSet(encode(baseValue + spread, def), self.noiseFilterA)
        m:executeSet(encode(baseValue - spread, def), self.noiseFilterB)
        return
    end

    -- Fallback: per-block hash noise (deterministic in world coords)
    forEachPolyBlock(verts, 8, function(cx, cz, half)
        local v = baseValue
        if spread > 0 then
            local h = math.sin(cx * 0.147 + cz * 0.211) * 43758.5453
            local n = (h - math.floor(h)) * 2.0 - 1.0   -- -1..1
            v = baseValue + n * spread
        end
        m:setParallelogramWorldCoords(
            cx - half, cz - half, cx + half, cz - half, cx - half, cz + half,
            DensityCoordType.POINT_POINT_POINT)
        m:executeSet(encode(v, def))
    end)
end

--- Shift every written pixel of a field polygon by a semantic delta while
--- preserving spatial variation (daily processes, rain leaching, harvest
--- extraction). Deltas smaller than one raw step must be accumulated by the
--- caller (see SoilFertilitySystem field._mapPendingDelta) before calling.
--- Returns the semantic amount actually applied (0 when below one raw step).
function SoilValueMaps:applyDeltaToPolygon(key, verts, delta)
    if not self.available or not verts or #verts < 3 then return 0 end
    local entry = self.layers[key]
    if not entry then return 0 end
    local def = entry.def
    local upr = unitsPerRaw(def)
    local rawDelta = (delta >= 0) and math.floor(delta / upr) or -math.floor(-delta / upr)
    if rawDelta == 0 then return 0 end

    local m = entry.modifier
    local applied = rawDelta * upr

    if self.hasExecuteAdd then
        -- Filter guards: only touch written pixels, and never push a pixel
        -- past the raw range (which could wrap into the no-data sentinel).
        -- Display layers guard at their rawFloor so negative shifts can't
        -- drop pixels into the transparent DMV state.
        local rawLow = def.rawFloor or RAW_MIN
        local filter = entry.filter
        if rawDelta > 0 then
            filter:setValueCompareParams(DensityValueCompareType.BETWEEN, rawLow, RAW_MAX - rawDelta)
        else
            filter:setValueCompareParams(DensityValueCompareType.BETWEEN, rawLow - rawDelta, RAW_MAX)
        end
        local function run()
            m:executeAdd(rawDelta, filter)
        end
        if setPolygonRegion(self, m, verts) then
            local ok, err = pcall(run)
            if not ok then
                SoilLogger.debug("SoilValueMaps: executeAdd failed (%s) - disabling add path", tostring(err))
                self.hasExecuteAdd = false
                return 0
            end
        else
            local okAll = true
            forEachPolyBlock(verts, 16, function(cx, cz, half)
                m:setParallelogramWorldCoords(
                    cx - half, cz - half, cx + half, cz - half, cx - half, cz + half,
                    DensityCoordType.POINT_POINT_POINT)
                local ok = pcall(run)
                if not ok then okAll = false end
            end)
            if not okAll then
                self.hasExecuteAdd = false
                return 0
            end
        end
        return applied
    end

    -- No executeAdd on this engine build: approximate with a coarse-block
    -- read-shift-write that still preserves block-level variation.
    forEachPolyBlock(verts, 16, function(cx, cz, half)
        local current = self:readValueAtWorld(key, cx, cz)
        if current ~= nil then
            m:setParallelogramWorldCoords(
                cx - half, cz - half, cx + half, cz - half, cx - half, cz + half,
                DensityCoordType.POINT_POINT_POINT)
            m:executeSet(encode(current + applied, def))
        end
    end)
    return applied
end

--- Average semantic value over a field polygon via engine-side executeGet.
---@return number|nil avg, number pixelCount
function SoilValueMaps:readAverageOfPolygon(key, verts)
    if not self.available or not verts or #verts < 3 then return nil, 0 end
    local entry = self.layers[key]
    if not entry then return nil, 0 end
    local m = entry.modifier
    local filter = entry.filter
    -- Only count written pixels
    filter:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN, RAW_MAX)

    local sum, pixels = 0, 0
    if setPolygonRegion(self, m, verts) then
        local ok, acc, n = pcall(function()
            local a, cnt, _ = m:executeGet(filter)
            return a, cnt
        end)
        if ok and n and n > 0 then sum, pixels = acc, n end
    else
        forEachPolyBlock(verts, 16, function(cx, cz, half)
            m:setParallelogramWorldCoords(
                cx - half, cz - half, cx + half, cz - half, cx - half, cz + half,
                DensityCoordType.POINT_POINT_POINT)
            local ok, acc, n = pcall(function()
                local a, cnt, _ = m:executeGet(filter)
                return a, cnt
            end)
            if ok and n and n > 0 then
                sum = sum + acc
                pixels = pixels + n
            end
        end)
    end

    if pixels <= 0 then return nil, 0 end
    return decode(sum / pixels, entry.def), pixels
end

-- ─────────────────────────────────────────────────────────
-- Multiplayer sync support
-- Reads/writes coarse 4-bit state grids (top 4 bits) at a stride
-- so a join sync stays small; see NetworkEvents SoilValueMapChunkEvent.
-- ─────────────────────────────────────────────────────────

SoilValueMaps.SYNC_GRID = 512   -- synced grid is at most SYNC_GRID x SYNC_GRID

function SoilValueMaps:getSyncStride()
    return math.max(1, math.floor(self.resolution / SoilValueMaps.SYNC_GRID))
end

--- Read one sync row (grid row `gy`, 0-based) as an array of 4-bit states.
function SoilValueMaps:readSyncRow(key, gy)
    local entry = self.layers[key]
    if not entry then return nil end
    local stride = self:getSyncStride()
    local n = math.floor(self.resolution / stride)
    local pz = math.min(self.resolution - 1, gy * stride)
    local row = {}
    for gx = 0, n - 1 do
        local px = math.min(self.resolution - 1, gx * stride)
        local raw = getBitVectorMapPoint(entry.bvm, px, pz, 0, NUM_CHANNELS) or 0
        row[gx + 1] = math.floor(raw / 16)   -- top 4 bits = display state
    end
    return row
end

--- Apply one received sync row: paints stride-sized blocks with the state's
--- mid-range semantic value. State 0 = no data (skipped).
function SoilValueMaps:applySyncRow(key, gy, row)
    local entry = self.layers[key]
    if not entry then return end
    local def = entry.def
    local m = entry.modifier
    local stride = self:getSyncStride()
    local mPerPx = self.terrainSize / self.resolution
    local blockM = stride * mPerPx
    local half = self.terrainSize * 0.5

    local wz = (gy * stride) * mPerPx - half
    local gx = 0
    local n = #row
    while gx < n do
        local state = row[gx + 1]
        -- Run-length: extend over identical neighbouring states for fewer modifier calls
        local runStart = gx
        while gx + 1 < n and row[gx + 2] == state do gx = gx + 1 end
        if state and state > 0 then
            local raw = state * 16 + 8   -- mid of the 16-raw band
            local x1 = (runStart * stride) * mPerPx - half
            local x2 = ((gx + 1) * stride) * mPerPx - half
            m:setParallelogramWorldCoords(
                x1, wz, x2, wz, x1, wz + blockM,
                DensityCoordType.POINT_POINT_POINT)
            m:executeSet(math.min(RAW_MAX, raw))
        end
        gx = gx + 1
    end
end

-- ─────────────────────────────────────────────────────────
-- Debug / stats
-- ─────────────────────────────────────────────────────────

function SoilValueMaps:getDebugStats()
    if not self.available then return "SoilValueMaps: unavailable" end
    local lines = { string.format("SoilValueMaps: %dpx / %.0fm terrain (%.1f m/px), loadedFromSave=%s, executeAdd=%s, polygonOps=%s",
        self.resolution, self.terrainSize, self.terrainSize / self.resolution,
        tostring(self.loadedFromSave), tostring(self.hasExecuteAdd), tostring(self.hasPolygonOps)) }
    for _, def in ipairs(SoilValueMaps.LAYER_DEFS) do
        local entry = self.layers[def.key]
        if entry then
            local cx, cz = 0, 0
            local v = self:readValueAtWorld(def.key, cx, cz)
            lines[#lines + 1] = string.format("  %s: bvm=%s loaded=%s valueAt(0,0)=%s",
                def.key, tostring(entry.bvm), tostring(entry.loaded), tostring(v))
        end
    end
    return table.concat(lines, "\n")
end
