-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Soil Layer System
-- =========================================================
-- Bridges the Lua-side fieldData tables to actual FS25
-- terrain density map layers (GRLE files).
--
-- ARCHITECTURE:
--   fieldData[id].nitrogen  ←→  infoLayer_soilN   (8-bit, channels 0-7)
--   fieldData[id].phosphorus ←→ infoLayer_soilP   (8-bit, channels 0-7)
--   fieldData[id].potassium  ←→ infoLayer_soilK   (8-bit, channels 0-7)
--   fieldData[id].pH         ←→ infoLayer_soilPH  (8-bit, channels 0-7, range 5.0-7.5 mapped to 0-255)
--   fieldData[id].organicMatter ←→ infoLayer_soilOM (8-bit, channels 0-7, range 0-10 mapped to 0-255)
--
-- WHY THIS IS NEEDED:
--   Without density map layers the mod stores one value per farmland ID.
--   That means every pixel of "Field 3" shares one N value — no per-pixel
--   variation, no real heatmap, no integration with FSDensityMapUtil or the
--   native MapOverlayGenerator. This file provides:
--     1.  Layer registration (getInfoLayerFromTerrain per nutrient).
--     2.  DensityMapModifier wrappers so other code can read/write pixels.
--     3.  Two-way sync: fieldData ↔ density map (per-farmland polygon average
--         on read; per-pixel write on fertilizer/harvest events).
--     4.  Graceful fallback — if a layer cannot be found on the terrain (map
--         doesn't ship the GRLE) the system falls back silently to the
--         fieldData-only path that was already working.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilLayerSystem
SoilLayerSystem = {}
local SoilLayerSystem_mt = Class(SoilLayerSystem)

-- ─────────────────────────────────────────────────────────
-- Layer definitions: name, value range for encode/decode
-- ─────────────────────────────────────────────────────────
-- Each entry maps to one GRLE file declared in the map XML.
-- encode/decode convert between the 0-255 storage value and
-- the semantic float value used by the rest of the mod.
-- ─────────────────────────────────────────────────────────
local LAYER_DEFS = {
    -- ── Nutrients ────────────────────────────────────────────
    -- perPixel=true: written per-pixel by spray events (updatePixelForField).
    -- writeFieldToLayers skips these to preserve per-pixel precision.
    {
        name        = "soilN",          -- i3d short name; engine saves as infoLayer_soilN.grle
        field       = "nitrogen",       -- key in fieldData
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,                -- 256 steps over 0-100 → ~0.39 units per step
        numChannels = 8,
        perPixel    = true,
    },
    {
        name        = "soilP",
        field       = "phosphorus",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
        perPixel    = true,
    },
    {
        name        = "soilK",
        field       = "potassium",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
        perPixel    = true,
    },
    {
        name        = "soilPH",
        field       = "pH",
        minVal      = 5.0,
        maxVal      = 7.5,
        numBits     = 8,
        numChannels = 8,
        perPixel    = true,
    },
    {
        name        = "soilOM",
        field       = "organicMatter",
        minVal      = 0,
        maxVal      = 10,
        numBits     = 8,
        numChannels = 8,
        perPixel    = true,
    },
    -- ── Biotic / physical pressure ───────────────────────────
    -- perPixel=false (default): no spray hooks; daily update paints field AABB.
    {
        name        = "soilPest",
        field       = "pestPressure",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
    },
    {
        name        = "soilDisease",
        field       = "diseasePressure",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
    },
    {
        name        = "soilCompaction",
        field       = "compaction",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
    },
    -- Note: weed is NOT in LAYER_DEFS — it is read from the game's
    -- native WeedSystem foliage density map (see weed* fields below).
}

local MAX_ENCODED = 255  -- (2^8) - 1

-- ─────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────

function SoilLayerSystem.new()
    local self = setmetatable({}, SoilLayerSystem_mt)
    -- layerHandles[layerDef.name] = { handle, modifier, def }
    self.layerHandles    = {}
    self.initialized     = false
    self.available       = false   -- true when ≥1 layer successfully registered
    -- Weed layer (game-native foliage density map — read-only)
    self.hasWeedLayer    = false
    self.weedMapId       = nil     -- raw density map id from weedSystem:getDensityMapData()
    self.weedFirstCh     = nil
    self.weedNumCh       = nil
    return self
end

-- ─────────────────────────────────────────────────────────
-- Encode / Decode helpers
-- ─────────────────────────────────────────────────────────

---@param value number  Semantic value (e.g. 65 for nitrogen %)
---@param def   table   Layer definition entry
---@return number       Integer 0-255 for storage
local function encode(value, def)
    local clamped = math.max(def.minVal, math.min(def.maxVal, value or def.minVal))
    local fraction = (clamped - def.minVal) / (def.maxVal - def.minVal)
    return math.floor(fraction * MAX_ENCODED + 0.5)
end

---@param raw  number  Integer 0-255 read from GRLE
---@param def  table   Layer definition entry
---@return number      Semantic float value
local function decode(raw, def)
    local fraction = (raw or 0) / MAX_ENCODED
    return def.minVal + fraction * (def.maxVal - def.minVal)
end

-- ─────────────────────────────────────────────────────────
-- Initialization — call after g_terrainNode is valid
-- (inside SoilFertilitySystem:initialize or later)
-- ─────────────────────────────────────────────────────────

function SoilLayerSystem:initialize()
    if self.initialized then return end

    if not g_terrainNode or g_terrainNode == 0 then
        SoilLogger.warning("SoilLayerSystem: g_terrainNode not available — layer integration disabled")
        self.initialized = true
        return
    end

    local registered = 0
    local missing    = 0

    for _, def in ipairs(LAYER_DEFS) do
        local handle = getInfoLayerFromTerrain(g_terrainNode, def.name)
        if handle ~= nil and handle ~= 0 then
            -- Build a DensityMapModifier spanning all bits of this layer
            local modifier = DensityMapModifier.new(handle, 0, def.numBits, g_terrainNode)
            -- Cache a reusable DensityMapFilter so per-pixel reads don't allocate
            -- a new filter object per call (avoids GC pressure on 40k-point samples).
            local filter = DensityMapFilter.new(modifier)
            self.layerHandles[def.name] = {
                handle   = handle,
                modifier = modifier,
                filter   = filter,
                def      = def,
            }
            registered = registered + 1
            SoilLogger.info("[OK] Soil layer registered: %s (handle=%s)", def.name, tostring(handle))
        else
            missing = missing + 1
            SoilLogger.debug(
                "Soil layer not found on terrain: %s (per-pixel map unavailable, using fieldData)",
                def.name
            )
        end
    end

    self.available    = registered > 0
    self.initialized  = true

    if self.available then
        SoilLogger.info(
            "SoilLayerSystem: %d/%d layers registered (%d missing — falling back to fieldData for those)",
            registered, #LAYER_DEFS, missing
        )
    else
        SoilLogger.info("SoilLayerSystem: No terrain layers — using fieldData storage (normal for most maps)")
    end

    -- ── Weed layer (game-native, read-only) ───────────────────────────────────
    -- FS25 tracks weed presence via WeedSystem which owns a foliage density map.
    -- We sample it to derive per-field weed pressure rather than simulating it.
    local weedSystem = g_currentMission and g_currentMission.weedSystem
    if weedSystem ~= nil then
        local ok, mapId, firstCh, numCh = pcall(function()
            return weedSystem:getDensityMapData()
        end)
        if ok and mapId and mapId ~= 0 then
            self.hasWeedLayer = true
            self.weedMapId    = mapId
            self.weedFirstCh  = firstCh or 0
            self.weedNumCh    = numCh   or 4
            SoilLogger.info("[OK] Weed density map found (mapId=%s, ch=%d+%d)",
                tostring(mapId), self.weedFirstCh, self.weedNumCh)
        else
            SoilLogger.debug("SoilLayerSystem: WeedSystem present but getDensityMapData failed — weed pressure uses simulation")
        end
    else
        SoilLogger.debug("SoilLayerSystem: No WeedSystem — weed pressure uses simulation fallback")
    end
end

-- ─────────────────────────────────────────────────────────
-- Sample the game's native weed density map across a farmland
-- bounding box and return the fraction of pixels that have any
-- weed present (non-zero state), as a value 0.0–1.0.
-- Returns nil if the weed layer is not available.
-- ─────────────────────────────────────────────────────────

---@param farmland table  FS25 farmland object
---@return number|nil  0.0–1.0 weed coverage fraction, or nil
function SoilLayerSystem:readWeedCoverageForFarmland(farmland)
    if not self.hasWeedLayer or not self.weedMapId then return nil end

    local cx, cz, hw, hh
    if farmland.x and farmland.z then
        cx = farmland.x
        cz = farmland.z
        hw = (farmland.width  and farmland.width  / 2) or 50
        hh = (farmland.height and farmland.height / 2) or 50
    elseif farmland.polygon and #farmland.polygon >= 2 then
        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
        for i = 1, #farmland.polygon, 2 do
            local px = farmland.polygon[i]
            local pz = farmland.polygon[i + 1]
            if px and pz then
                if px < minX then minX = px end
                if px > maxX then maxX = px end
                if pz < minZ then minZ = pz end
                if pz > maxZ then maxZ = pz end
            end
        end
        if minX == math.huge then return nil end
        cx = (minX + maxX) / 2
        cz = (minZ + maxZ) / 2
        hw = (maxX - minX) / 2
        hh = (maxZ - minZ) / 2
    else
        return nil
    end

    local ok, modifier = pcall(function()
        return DensityMapModifier.new(self.weedMapId, self.weedFirstCh, self.weedNumCh, g_terrainNode)
    end)
    if not ok or not modifier then return nil end

    local STEPS  = 8
    local weedCount = 0
    local total     = 0

    for xi = 0, STEPS - 1 do
        for zi = 0, STEPS - 1 do
            local wx = (cx - hw) + (xi / (STEPS - 1)) * (hw * 2)
            local wz = (cz - hh) + (zi / (STEPS - 1)) * (hh * 2)
            modifier:setParallelogramWorldCoords(wx, wz, wx + 0.1, wz, wx, wz + 0.1, DensityCoordType.POINT_POINT_POINT)
            local val, _, _ = modifier:executeGet(DensityMapFilter.new(modifier), nil)
            if val ~= nil then
                total = total + 1
                if val > 0 then weedCount = weedCount + 1 end
            end
        end
    end

    if total == 0 then return 0 end
    return weedCount / total
end

-- ─────────────────────────────────────────────────────────
-- Expose weed map data for minimap/PDA overlay rendering.
-- Returns (mapId, firstChannel, numChannels) or nil.
-- ─────────────────────────────────────────────────────────

function SoilLayerSystem:getWeedMapData()
    if not self.hasWeedLayer then return nil end
    return self.weedMapId, self.weedFirstCh, self.weedNumCh
end

-- ─────────────────────────────────────────────────────────
-- Write a single nutrient value at a world position
-- Called from applyFertilizer / onHarvest every frame
-- while the vehicle is moving across the field.
-- ─────────────────────────────────────────────────────────

---@param layerName string   e.g. "infoLayer_soilN"
---@param worldX    number   World X coordinate
---@param worldZ    number   World Z coordinate
---@param value     number   Semantic value to write (clamped by layer def)
---@param radius    number   Brush radius in metres (default 1.0)
function SoilLayerSystem:writeValueAtWorld(layerName, worldX, worldZ, value, radius)
    if not self.available then return end

    local entry = self.layerHandles[layerName]
    if not entry then return end

    local encoded = encode(value, entry.def)
    local r = radius or 1.0

    -- Modifier: set a circular area to the encoded integer
    local modifier  = entry.modifier
    local filter    = DensityMapFilter.new(modifier)
    -- No filter — write unconditionally to all pixels in radius
    modifier:setParallelogramWorldCoords(worldX - r, worldZ - r, worldX + r, worldZ - r, worldX - r, worldZ + r, DensityCoordType.POINT_POINT_POINT)
    modifier:executeSet(encoded, filter, nil)
end

-- ─────────────────────────────────────────────────────────
-- Read the decoded semantic value at a single world position.
-- Uses a cached DensityMapFilter (set during initialize) to avoid
-- per-call allocation when sampling 40k+ overlay points.
-- Returns nil if the layer is unavailable or the read fails.
-- ─────────────────────────────────────────────────────────

---@param layerName string  e.g. "infoLayer_soilN"
---@param worldX    number
---@param worldZ    number
---@return number|nil  Semantic float value, or nil on failure
function SoilLayerSystem:readValueAtWorld(layerName, worldX, worldZ)
    if not self.available then return nil end
    local entry = self.layerHandles[layerName]
    if not entry then return nil end

    local modifier = entry.modifier
    local filter   = entry.filter  -- reuse cached filter
    modifier:setParallelogramWorldCoords(
        worldX, worldZ,
        worldX + 0.1, worldZ,
        worldX, worldZ + 0.1,
        DensityCoordType.POINT_POINT_POINT
    )
    local val, _, _ = modifier:executeGet(filter, nil)
    if val == nil then return nil end
    return decode(val, entry.def)
end

-- ─────────────────────────────────────────────────────────
-- Derive the AABB (cx, cz, hw, hh) for a FS25 Field object.
-- FS25 Field objects have polygonPoints (scene node IDs) and
-- posX/posZ (centroid).  Farmland objects have NO geometry.
-- Returns cx, cz, hw, hh or nil on failure.
-- ─────────────────────────────────────────────────────────
local function getFieldAABB(fsField)
    if not fsField then return nil end

    -- Primary: derive AABB from polygon node world positions
    local polyNodes = fsField.polygonPoints
    if polyNodes and #polyNodes >= 3 then
        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
        for i = 1, #polyNodes do
            local nodeId = polyNodes[i]
            if nodeId and nodeId ~= 0 then
                local ok, wx, _, wz = pcall(getWorldTranslation, nodeId)
                if ok and wx then
                    if wx < minX then minX = wx end
                    if wx > maxX then maxX = wx end
                    if wz < minZ then minZ = wz end
                    if wz > maxZ then maxZ = wz end
                end
            end
        end
        if minX ~= math.huge then
            return (minX + maxX) / 2, (minZ + maxZ) / 2,
                   (maxX - minX) / 2, (maxZ - minZ) / 2
        end
    end

    -- Fallback: use centroid + area-based half-extents
    local cx = fsField.posX
    local cz = fsField.posZ
    if cx and cz then
        local area   = fsField.areaHa or (fsField.farmland and fsField.farmland.areaInHa) or 1.0
        local halfSide = math.sqrt(area * 10000) / 2
        return cx, cz, halfSide, halfSide
    end

    return nil
end

-- ─────────────────────────────────────────────────────────
-- Look up the FS25 Field object for a given farmland ID.
-- Returns nil when g_fieldManager is unavailable.
-- ─────────────────────────────────────────────────────────
local function getFieldByFarmlandId(farmlandId)
    if not g_fieldManager or not g_fieldManager.fields then return nil end
    for _, f in ipairs(g_fieldManager.fields) do
        if f and f.farmland and f.farmland.id == farmlandId then
            return f
        end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────
-- Read back the AVERAGE encoded value across a field polygon
-- and return the decoded semantic float.
-- Samples a grid of world points across the field AABB.
-- Used during scanFields to initialise fieldData from an
-- existing GRLE (e.g. a fresh savegame or a pre-seeded map).
-- fsField must be a FS25 Field object (has polygonPoints).
-- ─────────────────────────────────────────────────────────

---@param layerName string
---@param fsField   table    FS25 Field object (field.farmland.id is the key)
---@return number|nil  Semantic average, or nil if layer missing / no valid reads
function SoilLayerSystem:readAverageForFarmland(layerName, fsField)
    if not self.available then return nil end

    local entry = self.layerHandles[layerName]
    if not entry then return nil end

    local cx, cz, hw, hh = getFieldAABB(fsField)
    if not cx then return nil end

    -- Sample a 5×5 grid across the AABB
    local STEPS = 5
    local sum   = 0
    local count = 0
    local modifier = entry.modifier
    local filter   = DensityMapFilter.new(modifier)

    for xi = 0, STEPS - 1 do
        for zi = 0, STEPS - 1 do
            local wx = (cx - hw) + (xi / (STEPS - 1)) * (hw * 2)
            local wz = (cz - hh) + (zi / (STEPS - 1)) * (hh * 2)

            modifier:setParallelogramWorldCoords(wx, wz, wx + 0.1, wz, wx, wz + 0.1, DensityCoordType.POINT_POINT_POINT)
            local val, _, _ = modifier:executeGet(filter, nil)
            if val ~= nil then
                sum   = sum + val
                count = count + 1
            end
        end
    end

    if count == 0 then return nil end
    return decode(math.floor(sum / count + 0.5), entry.def)
end

-- ─────────────────────────────────────────────────────────
-- Write ALL nutrients for a field to their layers.
-- Call this after loading XML save data (fieldData already
-- has the values — push them to the density maps so the
-- visual heatmap matches what's stored).
-- ─────────────────────────────────────────────────────────

---@param fieldId   number
---@param fieldData table   The fieldData[fieldId] table
---@param fsFieldOrFarmland table  FS25 Field object preferred; farmland ID used to look up Field if needed
function SoilLayerSystem:writeFieldToLayers(fieldId, fieldData, fsFieldOrFarmland)
    if not self.available then return end
    if not fieldData then return end

    -- Resolve to a Field object (which has polygonPoints for AABB).
    -- Callers may pass a Field object directly, or a farmland object (which has no geometry).
    -- When a farmland object is passed, look up the Field via g_fieldManager.
    local fsField = fsFieldOrFarmland
    if fsField and not fsField.polygonPoints and not fsField.posX then
        -- Likely a farmland object — look up the corresponding Field
        fsField = getFieldByFarmlandId(fieldId)
    end

    local cx, cz, hw, hh = getFieldAABB(fsField)
    if not cx then
        SoilLogger.debug("SoilLayerSystem: writeFieldToLayers skipped field %d (no geometry)", fieldId)
        return
    end

    -- Paint entire AABB with the current field value for non-perPixel layers only.
    -- perPixel layers (N/P/K/pH/OM) are written per-pixel by spray events and must
    -- not be bulk-overwritten here or the per-pixel precision is lost.
    for _, def in ipairs(LAYER_DEFS) do
        if not def.perPixel then
            local entry = self.layerHandles[def.name]
            if entry and fieldData[def.field] ~= nil then
                local encoded = encode(fieldData[def.field], def)
                local modifier = entry.modifier
                local filter   = DensityMapFilter.new(modifier)
                modifier:setParallelogramWorldCoords(
                    cx - hw, cz - hh,
                    cx + hw, cz - hh,
                    cx - hw, cz + hh,
                    DensityCoordType.POINT_POINT_POINT
                )
                modifier:executeSet(encoded, filter, nil)
            end
        end
    end

    SoilLogger.debug("SoilLayerSystem: painted field %d to density layers", fieldId)
end

-- ─────────────────────────────────────────────────────────
-- Clear ALL nutrient layers for a field (write 0 to entire
-- AABB).  Call this for unowned fields so the unmasked DMV
-- only colours owned field areas.
-- ─────────────────────────────────────────────────────────

---@param fieldId          number
---@param fsFieldOrFarmland table|nil  Field or farmland object; nil → looks up by fieldId
function SoilLayerSystem:clearFieldFromLayers(fieldId, fsFieldOrFarmland)
    if not self.available then return end

    local fsField = fsFieldOrFarmland
    if fsField and not fsField.polygonPoints and not fsField.posX then
        fsField = getFieldByFarmlandId(fieldId)
    elseif not fsField then
        fsField = getFieldByFarmlandId(fieldId)
    end

    local cx, cz, hw, hh = getFieldAABB(fsField)
    if not cx then return end

    for _, def in ipairs(LAYER_DEFS) do
        local entry = self.layerHandles[def.name]
        if entry then
            local modifier = entry.modifier
            local filter   = DensityMapFilter.new(modifier)
            modifier:setParallelogramWorldCoords(
                cx - hw, cz - hh,
                cx + hw, cz - hh,
                cx - hw, cz + hh,
                DensityCoordType.POINT_POINT_POINT
            )
            modifier:executeSet(0, filter, nil)
        end
    end

    SoilLogger.debug("SoilLayerSystem: cleared GRLE for field %d", fieldId)
end

-- ─────────────────────────────────────────────────────────
-- Incremental write at a world position for a specific
-- nutrient layer.  Use this inside applyFertilizer /
-- onHarvest for per-pixel real-time updates.
-- ─────────────────────────────────────────────────────────

---@param fieldKey  string  e.g. "nitrogen"
---@param worldX    number
---@param worldZ    number
---@param newValue  number  Already-clamped semantic value from fieldData
---@param radius    number  Brush size metres (default 2.0)
function SoilLayerSystem:updatePixelForField(fieldKey, worldX, worldZ, newValue, radius)
    if not self.available then return end
    radius = radius or 2.0

    -- Find the layer def for this fieldKey
    local targetDef, targetEntry
    for _, def in ipairs(LAYER_DEFS) do
        if def.field == fieldKey then
            targetDef   = def
            targetEntry = self.layerHandles[def.name]
            break
        end
    end

    if not targetDef or not targetEntry then return end

    local encoded = encode(newValue, targetDef)
    local modifier = targetEntry.modifier
    local filter   = DensityMapFilter.new(modifier)
    modifier:setParallelogramWorldCoords(
        worldX - radius, worldZ - radius,
        worldX + radius, worldZ - radius,
        worldX - radius, worldZ + radius,
        DensityCoordType.POINT_POINT_POINT
    )
    modifier:executeSet(encoded, filter, nil)
end

-- ─────────────────────────────────────────────────────────
-- Initialise fieldData FROM existing density maps.
-- Called from scanFields() when the layers exist but
-- fieldData has no entry yet (e.g. first time on a map
-- that ships pre-seeded GRLE files).
-- Returns true if any layer value was read successfully.
-- ─────────────────────────────────────────────────────────

---@param fieldId  number
---@param fieldData table  The fieldData[fieldId] table (modified in-place)
---@param farmland  table  FS25 farmland object
---@return boolean
function SoilLayerSystem:readFieldFromLayers(fieldId, fieldData, fsField)
    if not self.available then return false end

    -- Resolve to a Field object if a farmland was passed
    if fsField and not fsField.polygonPoints and not fsField.posX then
        fsField = getFieldByFarmlandId(fieldId)
    end
    if not fsField then return false end

    local anyRead = false
    for _, def in ipairs(LAYER_DEFS) do
        local entry = self.layerHandles[def.name]
        if entry then
            local avg = self:readAverageForFarmland(def.name, fsField)
            if avg ~= nil then
                fieldData[def.field] = avg
                anyRead = true
            end
        end
    end

    if anyRead then
        SoilLogger.debug("SoilLayerSystem: seeded field %d from density layers", fieldId)
    end
    return anyRead
end

-- ─────────────────────────────────────────────────────────
-- Returns the layer entry (handle + modifier + def) for a
-- given nutrient field key, or nil if unavailable.
---@param fieldKey string  e.g. "nitrogen"
---@return table|nil
function SoilLayerSystem:getLayerEntryForField(fieldKey)
    if not self.available then return nil end
    for _, def in ipairs(LAYER_DEFS) do
        if def.field == fieldKey then
            return self.layerHandles[def.name]
        end
    end
    return nil
end

-- ─────────────────────────────────────────────────────────
-- Cleanup
-- ─────────────────────────────────────────────────────────

function SoilLayerSystem:delete()
    self.layerHandles = {}
    self.available    = false
    self.initialized  = false
end