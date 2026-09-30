-- =========================================================
-- FS25 Soil & Fertilizer - CD-15 local disease: the grid (step 1a)
-- =========================================================
-- CD-15 implementation brief v1.14 (certificate 08-CD15):
--   :67-81   the schema-1 cell record, names saved as names, validated before use;
--   :97-99   the ratified clean first-activation baseline (Arissani, 2026-09-13);
--   :83-85   geometry: the native map size and the loaded Soil fine-map transform,
--            with a geometry fingerprint;
--   :216     one sparse 32x32 tile representation: tx = floor(gx/32),
--            tz = floor(gz/32), localKey = (gz - 32*tz)*32 + (gx - 32*tx) in 0..1023;
--            populated keys only, sorted ascending; tile order tz then tx; complete
--            independent records, never averaged or merged.
--
-- THE FINE GEOMETRY is Soil's value maps (src/maps/SoilValueMaps.lua): one pixel of
-- terrainSize / resolution metres over a map centred on the origin. A CD-15 cell is
-- one value-map pixel. The same geometry the #953 probe measured the fruit planes
-- against (src/probe/CD15NativeCellProbe.lua:96-120, terrainFacts :217-222).
--
-- Server only. Nothing outside CD-15 reads this in step 1.
-- =========================================================

CD15Grid = CD15Grid or {}
local G = CD15Grid

G.SCHEMA = 1
G.NAMESPACE = "cd15Disease"
G.TILE = 32
G.HISTORY_MAX = 3

local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
local function isInteger(n) return isFinite(n) and n == math.floor(n) end
local function nonempty(s, maxBytes) return type(s) == "string" and s ~= "" and #s <= (maxBytes or 128) end
G.isFinite, G.isInteger = isFinite, isInteger

-- ---------------------------------------------------------
-- The schema-1 cell record (:67-81)
-- ---------------------------------------------------------
--- A canonical disease name: one the catalogue defines (SoilConstants.DISEASE_DEFS).
function G.isDiseaseName(name)
    return nonempty(name, 64) and SoilConstants ~= nil and type(SoilConstants.DISEASE_DEFS) == "table" and SoilConstants.DISEASE_DEFS[name] ~= nil
end

local function validModeMap(t, valueCheck)
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do
        if not nonempty(k, 64) or not valueCheck(v) then return false end
    end
    return true
end

--- Validate one record. Returns the record, or nil and the first failing field.
function G.validCell(c)
    if type(c) ~= "table" then return nil, "NOT_TABLE" end
    if c.cropName ~= nil and not nonempty(c.cropName, 64) then return nil, "CROP_NAME" end
    if type(c.cropHistory) ~= "table" or #c.cropHistory > G.HISTORY_MAX then return nil, "CROP_HISTORY" end
    for i, h in ipairs(c.cropHistory) do
        if type(h) ~= "table" or not nonempty(h.occurrenceId, 128) or not nonempty(h.cropName, 64) then return nil, "CROP_HISTORY:" .. i end
    end
    if c.cropOccurrence ~= nil and not nonempty(c.cropOccurrence, 128) then return nil, "CROP_OCCURRENCE" end
    if c.lastResetOccurrence ~= nil and not nonempty(c.lastResetOccurrence, 128) then return nil, "LAST_RESET_OCCURRENCE" end
    if c.diseaseName ~= nil and not G.isDiseaseName(c.diseaseName) then return nil, "DISEASE_NAME" end
    if not isFinite(c.pressure) or c.pressure < 0 or c.pressure > 100 then return nil, "PRESSURE" end
    if not validModeMap(c.resistance, function(v) return isFinite(v) and v >= 0 end) then return nil, "RESISTANCE" end
    if not validModeMap(c.protection, isInteger) then return nil, "PROTECTION" end
    if c.hybridCooldownExpiryDay ~= nil and not isInteger(c.hybridCooldownExpiryDay) then return nil, "HYBRID_COOLDOWN" end
    if type(c.discovered) ~= "boolean" then return nil, "DISCOVERED" end
    if c.lastSettledDay ~= nil and not isInteger(c.lastSettledDay) then return nil, "LAST_SETTLED_DAY" end
    if not isInteger(c.sourceRevision) or c.sourceRevision < 0 then return nil, "SOURCE_REVISION" end
    if not isInteger(c.dryDayCount) or c.dryDayCount < 0 then return nil, "DRY_DAY_COUNT" end
    if c.dailyTreatment ~= nil then
        local t = c.dailyTreatment
        if type(t) ~= "table" or not isInteger(t.day) or not validModeMap(t.doseByMode or {}, function(v) return isFinite(v) and v >= 0 end)
           or not isFinite(t.reduction) or type(t.operationIds) ~= "table" then
            return nil, "DAILY_TREATMENT"
        end
    end
    if c.nativeCropWitness ~= nil and (type(c.nativeCropWitness) ~= "table" or not nonempty(c.nativeCropWitness.basis, 64)) then return nil, "NATIVE_CROP_WITNESS" end
    if not nonempty(c.geometryFingerprint, 256) then return nil, "GEOMETRY_FINGERPRINT" end
    if c.diseaseName == nil and c.discovered then return nil, "DISCOVERED_WITHOUT_IDENTITY" end
    return c
end

--- The ratified clean baseline (:97): pressure 0, no active identity, resistance {},
--- protection {}, empty harvested history, no cooldown, no claimed earlier treatment.
--- It is the new model's starting point, not a claim that old ground was clean.
function G.baselineCell(geometryFingerprint)
    return {
        cropName = nil, cropHistory = {}, cropOccurrence = nil, lastResetOccurrence = nil,
        diseaseName = nil, pressure = 0, resistance = {}, protection = {},
        hybridCooldownExpiryDay = nil, discovered = false, lastSettledDay = nil,
        sourceRevision = 0, dryDayCount = 0, dailyTreatment = nil, nativeCropWitness = nil,
        geometryFingerprint = geometryFingerprint,
    }
end

--- A detached deep copy of a record (spread and settlement never share tables).
function G.copyCell(c)
    local out = {}
    for k, v in pairs(c) do
        if type(v) == "table" then
            local t = {}
            for k2, v2 in pairs(v) do
                if type(v2) == "table" then
                    local t2 = {}
                    for k3, v3 in pairs(v2) do t2[k3] = v3 end
                    t[k2] = t2
                else
                    t[k2] = v2
                end
            end
            out[k] = t
        else
            out[k] = v
        end
    end
    return out
end

-- ---------------------------------------------------------
-- The sparse 32x32 tile store (:216)
-- ---------------------------------------------------------
--- (tx, tz, localKey) for a fine cell.
function G.tileOf(gx, gz)
    local tx, tz = math.floor(gx / G.TILE), math.floor(gz / G.TILE)
    return tx, tz, (gz - G.TILE * tz) * G.TILE + (gx - G.TILE * tx)
end

--- The fine cell of (tx, tz, localKey).
function G.cellOf(tx, tz, localKey)
    local lz = math.floor(localKey / G.TILE)
    return tx * G.TILE + (localKey - lz * G.TILE), tz * G.TILE + lz
end

local Store = {}
local Store_mt = { __index = Store }

function G.newStore()
    return setmetatable({ tiles = {}, count = 0 }, Store_mt)
end

local function tileKey(tx, tz) return tostring(tz) .. ":" .. tostring(tx) end

function Store:get(gx, gz)
    local tx, tz, k = G.tileOf(gx, gz)
    local tile = self.tiles[tileKey(tx, tz)]
    return tile ~= nil and tile.cells[k] or nil
end

--- Insert or replace one validated record. Returns true, or false and a reason.
function Store:put(gx, gz, record)
    if not isInteger(gx) or not isInteger(gz) or gx < 0 or gz < 0 then return false, "COORDINATES" end
    local ok, why = G.validCell(record)
    if not ok then return false, why end
    local tx, tz, k = G.tileOf(gx, gz)
    local key = tileKey(tx, tz)
    local tile = self.tiles[key]
    if tile == nil then
        tile = { tx = tx, tz = tz, keys = {}, cells = {} }
        self.tiles[key] = tile
    end
    if tile.cells[k] == nil then
        -- Keep the populated keys sorted ascending (:216).
        local i = #tile.keys + 1
        while i > 1 and tile.keys[i - 1] > k do
            tile.keys[i] = tile.keys[i - 1]
            i = i - 1
        end
        tile.keys[i] = k
        self.count = self.count + 1
    end
    tile.cells[k] = record
    return true
end

function Store:remove(gx, gz)
    local tx, tz, k = G.tileOf(gx, gz)
    local key = tileKey(tx, tz)
    local tile = self.tiles[key]
    if tile == nil or tile.cells[k] == nil then return false end
    tile.cells[k] = nil
    for i, v in ipairs(tile.keys) do
        if v == k then table.remove(tile.keys, i) break end
    end
    if #tile.keys == 0 then self.tiles[key] = nil end
    self.count = self.count - 1
    return true
end

--- Every populated cell in the store's order: tiles by tz then tx, keys ascending.
--- Returns a detached list of { gx, gz, tx, tz, localKey }; records are read by get.
function Store:orderedCells()
    local tiles = {}
    for _, tile in pairs(self.tiles) do tiles[#tiles + 1] = tile end
    table.sort(tiles, function(a, b) if a.tz ~= b.tz then return a.tz < b.tz end return a.tx < b.tx end)
    local out = {}
    for _, tile in ipairs(tiles) do
        for _, k in ipairs(tile.keys) do
            local gx, gz = G.cellOf(tile.tx, tile.tz, k)
            out[#out + 1] = { gx = gx, gz = gz, tx = tile.tx, tz = tile.tz, localKey = k }
        end
    end
    return out
end

--- Source order for spread (:122): ascending (tz, tx, localKey).
function G.sourceOrderLess(a, b)
    if a.tz ~= b.tz then return a.tz < b.tz end
    if a.tx ~= b.tx then return a.tx < b.tx end
    return a.localKey < b.localKey
end

-- ---------------------------------------------------------
-- Geometry (:83-85)
-- ---------------------------------------------------------
--- Resolve the fine geometry from Soil's live value maps and the native crop map size.
--- Returns the geometry, or nil and a reason; never a guessed grid.
---@param valueMaps table SoilValueMaps (available, terrainSize, resolution)
---@param nativeMapSize number getDensityMapSize of the default fruit data plane
function G.resolveGeometry(valueMaps, nativeMapSize)
    if type(valueMaps) ~= "table" or valueMaps.available ~= true then return nil, "NO_FINE_MAP" end
    local terrainSize, resolution = valueMaps.terrainSize, valueMaps.resolution
    if not isFinite(terrainSize) or terrainSize <= 0 or not isInteger(resolution) or resolution <= 0 then return nil, "FINE_MAP_SIZE" end
    if not isInteger(nativeMapSize) or nativeMapSize <= 0 then return nil, "NATIVE_MAP_SIZE" end
    local geom = {
        namespace = G.NAMESPACE, schema = G.SCHEMA, terrainSize = terrainSize, resolution = resolution,
        nativeMapSize = nativeMapSize, cellSize = terrainSize / resolution, origin = "CENTRED",
    }
    geom.fingerprint = string.format("%s:%d;terrain=%.17g;fine=%d;native=%d;origin=%s",
        geom.namespace, geom.schema, terrainSize, resolution, nativeMapSize, geom.origin)
    return geom
end

--- The fine cell holding a world position, half-open: the negative edge admits, the
--- positive edge and off-map refuse (nil), never clamped (the probe's cellOfWorld).
function G.cellOfWorld(geom, x, z)
    if geom == nil or not isFinite(x) or not isFinite(z) then return nil end
    local half = geom.terrainSize / 2
    if x < -half or z < -half or x >= half or z >= half then return nil end
    return math.floor((x + half) / geom.cellSize), math.floor((z + half) / geom.cellSize)
end

--- The world centre of a fine cell.
function G.cellCentre(geom, gx, gz)
    local half = geom.terrainSize / 2
    return -half + (gx + 0.5) * geom.cellSize, -half + (gz + 0.5) * geom.cellSize
end

--- Is (gx, gz) on the fine grid?
function G.onGrid(geom, gx, gz)
    return geom ~= nil and isInteger(gx) and isInteger(gz) and gx >= 0 and gz >= 0 and gx < geom.resolution and gz < geom.resolution
end
