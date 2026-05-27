-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Bundled Soil Maps
-- =========================================================
-- Loads pre-baked GRLE files bundled inside the mod to provide
-- spatially-aware initial soil values on vanilla FS25 maps —
-- no map preparation required (same strategy as Precision Farming).
--
-- USAGE:
--   self.bundledMaps = SoilBundledMaps.new()
--   self.bundledMaps:initialize()            -- call after g_terrainNode available
--   local pH = self.bundledMaps:sampleAtWorldPos(worldX, worldZ)
--   self.bundledMaps:delete()
--
-- FALLBACK ORDER (in SoilFertilitySystem):
--   1. SoilLayerSystem (terrain info layers, map-prepared)
--   2. SoilBundledMaps (bundled GRLE, vanilla maps)
--   3. Randomized FIELD_DEFAULTS
-- =========================================================
-- Author: TisonK
-- =========================================================

-- Capture mod directory at source() time — g_currentModDirectory is nil after mission load
local MOD_DIRECTORY = g_currentModDirectory

---@class SoilBundledMaps
SoilBundledMaps = {}
local SoilBundledMaps_mt = Class(SoilBundledMaps)

-- ─────────────────────────────────────────────────────────
-- Map title keywords → GRLE filename
-- Lowercased match against g_currentMission.missionInfo.mapTitle
-- ─────────────────────────────────────────────────────────
local MAP_RULES = {
    { keywords = { "beyleron", "haut", "france" },              file = "mapFR.grle"     },
    { keywords = { "elmcreek", "riverbend", "springs" },        file = "mapUS.grle"     },
    { keywords = { "erlengrat", "alpine", "alpen" },            file = "mapAlpine.grle" },
    { keywords = { "zielonka", "stappenbach", "althofen" },     file = "mapEU.grle"     },
    { keywords = { "southamerica", "southam", "brasil" },       file = "mapSA.grle"     },
    { keywords = { "asia", "hokkaido", "japan" },               file = "mapAS.grle"     },
}
local FALLBACK_FILE  = "generic.grle"
local NOISE_FILE     = "ph_noise.grle"

-- ─────────────────────────────────────────────────────────
-- GRLE decode parameters (confirmed from grleConverter output)
--
-- All bundled files: Version 1, 1024×1024 px, 2-bit single channel
-- Values 0–3 represent 4 discrete pH zones.
-- PH_ZONE_MAP[raw] → pH value (update with Seb's zone definitions)
-- ─────────────────────────────────────────────────────────
local NUM_CHANNELS  = 2    -- 2-bit channel (4 values: 0-3)
local PH_CHANNEL    = 0    -- zero-based channel index

-- pH zone lookup: raw value 0-3 → semantic pH
-- !! Confirm with Seb what his 4 zones represent !!
-- Current assumption: 0=neutral descending toward acidic
local PH_ZONE_MAP = {
    [0] = 7.0,   -- zone 0: neutral/alkaline
    [1] = 6.5,   -- zone 1: slightly acidic
    [2] = 6.0,   -- zone 2: moderately acidic
    [3] = 5.5,   -- zone 3: acidic
}

-- Noise overlay: adds ±NOISE_AMPLITUDE pH micro-variation
-- Tiled at NOISE_TILE_FACTOR × the GRLE resolution.
local NOISE_CHANNELS      = 2    -- noise map is also 2-bit (values 0-3)
local NOISE_TILE_FACTOR   = 4   -- tile noise 4× across the map
local NOISE_AMPLITUDE     = 0.25 -- ± pH units from noise (scaled from 0-3 range)

-- ─────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────

function SoilBundledMaps.new()
    local self = setmetatable({}, SoilBundledMaps_mt)
    self.available    = false
    self.initialized  = false
    self.mapBVM       = nil   -- main regional GRLE BitVectorMap
    self.noiseBVM     = nil   -- ph_noise GRLE BitVectorMap
    self.mapW         = 0
    self.mapH         = 0
    self.noiseW       = 0
    self.noiseH       = 0
    self.terrainSize  = 0
    self.chosenFile   = nil
    return self
end

-- ─────────────────────────────────────────────────────────
-- Map detection — returns GRLE filename for current map
-- ─────────────────────────────────────────────────────────

local function detectMapFile()
    local title = ""
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.mapTitle then
        title = string.lower(g_currentMission.missionInfo.mapTitle)
    end
    if title ~= "" then
        for _, rule in ipairs(MAP_RULES) do
            for _, kw in ipairs(rule.keywords) do
                if string.find(title, kw, 1, true) then
                    SoilLogger.info("SoilBundledMaps: map title '%s' matched '%s' → %s", title, kw, rule.file)
                    return rule.file
                end
            end
        end
    end
    SoilLogger.info("SoilBundledMaps: no keyword match for map title '%s' → %s", title, FALLBACK_FILE)
    return FALLBACK_FILE
end

-- ─────────────────────────────────────────────────────────
-- Initialization — call after terrain is loaded
-- (SoilFertilitySystem:initialize() is the right place)
-- ─────────────────────────────────────────────────────────

function SoilBundledMaps:initialize()
    if self.initialized then return end
    self.initialized = true

    if not g_terrainNode or g_terrainNode == 0 then
        SoilLogger.warning("SoilBundledMaps: g_terrainNode not available — bundled maps disabled")
        return
    end

    self.terrainSize = getTerrainSize(g_terrainNode) or 0
    if self.terrainSize <= 0 then
        SoilLogger.warning("SoilBundledMaps: getTerrainSize returned 0 — bundled maps disabled")
        return
    end

    local mapsDir = MOD_DIRECTORY .. "resources/soilmaps/"

    -- Load regional map GRLE
    local mapFile     = detectMapFile()
    self.chosenFile   = mapFile
    local mapPath     = mapsDir .. mapFile

    self.mapBVM = createBitVectorMap("SoilBundledMap")
    if not self.mapBVM or self.mapBVM == 0 then
        SoilLogger.warning("SoilBundledMaps: createBitVectorMap failed")
        return
    end

    local ok = loadBitVectorMapFromFile(self.mapBVM, mapPath, NUM_CHANNELS)  -- 2 bits per pixel
    if not ok then
        SoilLogger.warning("SoilBundledMaps: failed to load %s", mapPath)
        delete(self.mapBVM)
        self.mapBVM = nil
        return
    end

    self.mapW, self.mapH = getBitVectorMapSize(self.mapBVM)
    SoilLogger.info("SoilBundledMaps: loaded %s (%dx%d px, %d ch)", mapFile, self.mapW, self.mapH, NUM_CHANNELS)

    -- Load noise GRLE (optional — graceful if missing)
    local noisePath = mapsDir .. NOISE_FILE
    self.noiseBVM   = createBitVectorMap("SoilNoiseMap")
    if self.noiseBVM and self.noiseBVM ~= 0 then
        local noiseOk = loadBitVectorMapFromFile(self.noiseBVM, noisePath, NOISE_CHANNELS)  -- 2 bits
        if noiseOk then
            self.noiseW, self.noiseH = getBitVectorMapSize(self.noiseBVM)
            SoilLogger.info("SoilBundledMaps: loaded %s (%dx%d px)", NOISE_FILE, self.noiseW, self.noiseH)
        else
            SoilLogger.warning("SoilBundledMaps: failed to load %s — noise overlay disabled", noisePath)
            delete(self.noiseBVM)
            self.noiseBVM = nil
        end
    end

    self.available = true
end

-- ─────────────────────────────────────────────────────────
-- World → pixel coordinate conversion
-- ─────────────────────────────────────────────────────────

local function worldToPixel(worldX, worldZ, terrainSize, w, h)
    local halfSize = terrainSize / 2
    local px = math.floor((worldX + halfSize) / terrainSize * w)
    local pz = math.floor((worldZ + halfSize) / terrainSize * h)
    px = math.max(0, math.min(w - 1, px))
    pz = math.max(0, math.min(h - 1, pz))
    return px, pz
end

-- ─────────────────────────────────────────────────────────
-- Sample pH at a world position.
-- Returns a clamped pH float, or nil if unavailable.
--
-- The GRLE files store 2-bit zone IDs (0-3).
-- PH_ZONE_MAP maps each zone to a pH value.
-- ph_noise.grle adds ±NOISE_AMPLITUDE micro-variation.
-- ─────────────────────────────────────────────────────────

function SoilBundledMaps:sampleAtWorldPos(worldX, worldZ)
    if not self.available or not self.mapBVM then return nil end

    local px, pz = worldToPixel(worldX, worldZ, self.terrainSize, self.mapW, self.mapH)

    -- Read 2-bit zone value (0-3) from regional map
    local raw = getBitVectorMapPoint(self.mapBVM, px, pz, PH_CHANNEL, NUM_CHANNELS)
    if raw == nil then return nil end

    -- Map zone ID → pH value
    local pH = PH_ZONE_MAP[raw] or PH_ZONE_MAP[0]

    -- Add noise overlay micro-variation if available
    -- noise is also 2-bit (0-3); map to ±NOISE_AMPLITUDE range
    if self.noiseBVM and self.noiseW > 0 then
        local nx = (px * NOISE_TILE_FACTOR) % self.noiseW
        local nz = (pz * NOISE_TILE_FACTOR) % self.noiseH
        local noiseRaw = getBitVectorMapPoint(self.noiseBVM, nx, nz, 0, NOISE_CHANNELS)
        if noiseRaw ~= nil then
            -- 0-3 → -1.0 to +1.0 → scale by amplitude
            local noiseMod = (noiseRaw / 3.0 - 0.5) * 2.0 * NOISE_AMPLITUDE
            pH = pH + noiseMod
        end
    end

    return math.max(5.0, math.min(8.5, pH))
end

-- ─────────────────────────────────────────────────────────
-- Farmland center helper (reuses AABB logic from SoilLayerSystem)
-- Returns cx, cz world coordinates of the farmland centre.
-- ─────────────────────────────────────────────────────────

function SoilBundledMaps:getFarmlandCenter(farmland)
    if farmland.x and farmland.z then
        return farmland.x, farmland.z
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
        if minX ~= math.huge then
            return (minX + maxX) / 2, (minZ + maxZ) / 2
        end
    end
    return nil, nil
end

-- ─────────────────────────────────────────────────────────
-- Cleanup
-- ─────────────────────────────────────────────────────────

function SoilBundledMaps:delete()
    if self.mapBVM and self.mapBVM ~= 0 then
        delete(self.mapBVM)
        self.mapBVM = nil
    end
    if self.noiseBVM and self.noiseBVM ~= 0 then
        delete(self.noiseBVM)
        self.noiseBVM = nil
    end
    self.available   = false
    self.initialized = false
end
