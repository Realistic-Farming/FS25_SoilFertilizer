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
    {
        name        = "soilN",          -- i3d short name; engine saves as infoLayer_soilN.grle
        field       = "nitrogen",       -- key in fieldData
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,                -- 256 steps over 0-100 → ~0.39 units per step
        numChannels = 8,
    },
    {
        name        = "soilP",
        field       = "phosphorus",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
    },
    {
        name        = "soilK",
        field       = "potassium",
        minVal      = 0,
        maxVal      = 100,
        numBits     = 8,
        numChannels = 8,
    },
    {
        name        = "soilPH",
        field       = "pH",
        minVal      = 5.0,              -- FS25 soil pH never goes below 5
        maxVal      = 7.5,
        numBits     = 8,
        numChannels = 8,
    },
    {
        name        = "soilOM",
        field       = "organicMatter",
        minVal      = 0,
        maxVal      = 10,
        numBits     = 8,
        numChannels = 8,
    },
}

local MAX_ENCODED = 255  -- (2^8) - 1

-- ─────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────

function SoilLayerSystem.new()
    local self = setmetatable({}, SoilLayerSystem_mt)
    -- layerHandles[layerDef.name] = { handle, modifier, def }
    self.layerHandles = {}
    self.initialized  = false
    self.available    = false   -- true when ≥1 layer successfully registered
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
-- Read back the AVERAGE encoded value across a farmland
-- polygon and return the decoded semantic float.
-- Samples a grid of world points across the farmland AABB.
-- Used during scanFields to initialise fieldData from an
-- existing GRLE (e.g. a fresh savegame or a pre-seeded map).
-- ─────────────────────────────────────────────────────────

---@param layerName string
---@param farmland  table    FS25 farmland object (has .x .z .width .height or polygon)
---@return number|nil  Semantic average, or nil if layer missing / no valid reads
function SoilLayerSystem:readAverageForFarmland(layerName, farmland)
    if not self.available then return nil end

    local entry = self.layerHandles[layerName]
    if not entry then return nil end

    -- Determine bounding box from farmland fields
    local cx, cz, hw, hh
    if farmland.x and farmland.z then
        -- Some maps expose world-space center + half-extents
        cx = farmland.x
        cz = farmland.z
        hw = (farmland.width  and farmland.width  / 2) or 50
        hh = (farmland.height and farmland.height / 2) or 50
    elseif farmland.polygon and #farmland.polygon >= 2 then
        -- Derive AABB from polygon points (format: {x1, z1, x2, z2, ...})
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
        -- Absolute fallback: can't determine farmland boundary
        return nil
    end

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

---@param fieldId  number
---@param fieldData table  The fieldData[fieldId] table
---@param farmland  table  FS25 farmland object for the field
function SoilLayerSystem:writeFieldToLayers(fieldId, fieldData, farmland)
    if not self.available then return end
    if not fieldData or not farmland then return end

    -- Determine bounding box (same logic as readAverageForFarmland)
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
        if minX == math.huge then return end
        cx = (minX + maxX) / 2
        cz = (minZ + maxZ) / 2
        hw = (maxX - minX) / 2
        hh = (maxZ - minZ) / 2
    else
        return
    end

    -- Paint entire AABB with the current field value for each layer
    for _, def in ipairs(LAYER_DEFS) do
        local entry = self.layerHandles[def.name]
        if entry and fieldData[def.field] ~= nil then
            local encoded = encode(fieldData[def.field], def)
            local modifier = entry.modifier
            local filter   = DensityMapFilter.new(modifier)
            -- Parallelogram covering the full AABB
            modifier:setParallelogramWorldCoords(
                cx - hw, cz - hh,
                cx + hw, cz - hh,
                cx - hw, cz + hh,
                DensityCoordType.POINT_POINT_POINT
            )
            modifier:executeSet(encoded, filter, nil)
        end
    end

    SoilLogger.debug("SoilLayerSystem: painted field %d to density layers", fieldId)
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
function SoilLayerSystem:readFieldFromLayers(fieldId, fieldData, farmland)
    if not self.available then return false end

    local anyRead = false
    for _, def in ipairs(LAYER_DEFS) do
        local entry = self.layerHandles[def.name]
        if entry then
            local avg = self:readAverageForFarmland(def.name, farmland)
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