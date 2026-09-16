--
-- GroundConditionCells
--
-- RSF-F208, section 1 of GROUND-CONDITION-CONTRACT v1.5: the narrow exact
-- condition-cell surface over the two existing SoilValueMaps condition layers.
--
-- WHAT THIS IS NOT. It is not a new grid authority, a new clock, a second
-- quantity store or a change to nutrient/radius painting. MaterialDown still owns
-- age and MaterialWetness still owns wetness; this file only gives the Soil domain
-- coordinator a way to read and write ONE named cell exactly, which the existing
-- polygon/radius API cannot do. Every existing caller keeps its existing path.
--
-- WHY A SEPARATE MODIFIER. The contract requires a dedicated modifier and filter
-- per condition layer rather than reusing the layer's shared modifier. The shared
-- one is re-aimed by the daily weather passes; borrowing it here would mean a
-- condition write and a drying pass could re-aim each other mid-sequence. These
-- are ours and nothing else re-aims them.
--
-- WHY THE INSET MIDDLE HALF. A density modifier selects an AREA, and a cell-edge
-- aligned parallelogram is ambiguous at both edges: floating point decides whether
-- the neighbour is included. Selecting the middle half of the cell -
-- [(gx+.25)/N, (gz+.25)/N] to [(gx+.75)/N, (gz+.75)/N] in UV - lands strictly
-- inside one cell with a quarter-cell margin on every side. It is still only an
-- ASSUMPTION that this selects exactly one pixel, so we do not trust it: every
-- write runs a preflight that makes the engine prove it selected exactly one pixel
-- and that the pixel is the one we asked for, and refuses the write otherwise.
--
-- NATIVE BASIS, verified against the decompiled engine source, not from memory:
--   * DensityMapModifier:setParallelogramUVCoords(u0,v0,u1,v1,u2,v2,coordType)
--     is real and takes normalised terrain UV. Its only engine caller is
--     IndoorMask.lua:110-113, which converts world to UV as x/terrainSize + 0.5.
--     Our cell UV (gx+f)/resolution is the same space, because the layer spans the
--     terrain in `resolution` cells.
--   * modifier:executeGet(filter) returns THREE values, (sum, numPixels,
--     totalPixels) - see DensityMapHeightUtil.lua:107, FieldCourseField.lua:481,
--     PlaceableHusbandryMeadow.lua:435. With exactly one selected pixel the sum IS
--     that pixel's raw value, which is what makes the agreement check meaningful.
--   * getBitVectorMapPoint(bvm, px, pz, firstChannel, numChannels) is the existing
--     exact point read already used by SoilValueMaps:readRawAtWorld.
--
-- TWO NATIVE WRITES ARE NOT ATOMIC. Age and wetness are separate layers and
-- therefore separate engine writes. We never claim otherwise: a pair that does not
-- complete leaves the cell marked unavailable for BOTH components rather than
-- reporting a half-written pair as a good record.
--

GroundConditionCells = {}
local GroundConditionCells_mt = Class(GroundConditionCells)

-- Bits per pixel on the condition layers. Matches SoilValueMaps' own NUM_CHANNELS;
-- asserted against the layer defs at arm() rather than assumed.
local NUM_CHANNELS = 8

local RAW_MIN_VALUE = 0
local RAW_MAX_VALUE = 255

-- Age sentinels (MaterialDown owns their meaning; repeated here as VALIDATION
-- bounds only, and cross-checked against MaterialDown at arm()).
local AGE_NO_RECORD = 0     -- unknown / no record on positive material
local AGE_CEILING   = 255   -- the ceiling refusal, never an averaged day count

-- Wetness sentinels (MaterialWetness owns their meaning).
--   0        absent / uninitialised
--   24       unknown / refusal (sits inside the reserved 16-31 band)
--   32..255  known encoded values
-- Everything else in 1..31 is reserved and is NOT a writable condition value.
local WET_ABSENT   = 0
local WET_SENTINEL = 24
local WET_FLOOR    = 32

GroundConditionCells.AGE_NO_RECORD = AGE_NO_RECORD
GroundConditionCells.AGE_CEILING   = AGE_CEILING
GroundConditionCells.WET_ABSENT    = WET_ABSENT
GroundConditionCells.WET_SENTINEL  = WET_SENTINEL
GroundConditionCells.WET_FLOOR     = WET_FLOOR

-- Refusal reasons. Strings, because they travel into the coordinator's
-- availability overlay and into the bench, and a number would tell a reader
-- nothing at the call site.
GroundConditionCells.REFUSE_NOT_ARMED     = "NOT_ARMED"
GroundConditionCells.REFUSE_GEOMETRY      = "GEOMETRY_STALE"
GroundConditionCells.REFUSE_COORDS        = "COORDS_OUT_OF_RANGE"
GroundConditionCells.REFUSE_VALUE         = "VALUE_NOT_A_DOMAIN_RAW"
GroundConditionCells.REFUSE_REVISION      = "REVISION_MISMATCH"
GroundConditionCells.REFUSE_PREFLIGHT     = "PREFLIGHT_NOT_ONE_PIXEL"
GroundConditionCells.REFUSE_DISAGREE      = "PREFLIGHT_DISAGREED"
GroundConditionCells.REFUSE_WRITE_THREW   = "WRITE_THREW"
GroundConditionCells.REFUSE_READBACK      = "READBACK_MISMATCH"

-- =========================================================
-- Construction and bind
-- =========================================================

function GroundConditionCells.new()
    local self = setmetatable({}, GroundConditionCells_mt)
    self.armed      = false
    self.valueMaps  = nil
    self.ageEntry   = nil
    self.wetEntry   = nil
    self.ageMod     = nil
    self.ageFilter  = nil
    self.wetMod     = nil
    self.wetFilter  = nil
    -- Geometry identity. `epoch` changes whenever we rebind (a reload gives a new
    -- binding and therefore a new epoch), so a geometry captured before a reload
    -- cannot be used to write after one. `geometryRevision` moves if the layer
    -- geometry itself is re-established within one binding.
    self.epoch            = 0
    self.geometryRevision = 0
    self.terrainSize      = 0
    self.resolution       = 0
    return self
end

--- Bind to the live value maps. Server-only, like every other condition owner.
--- Refuses rather than half-arming: a surface that silently no-ops would let the
--- coordinator believe it had written a record it never wrote.
---@return boolean armed
function GroundConditionCells:arm(valueMaps)
    self.armed     = false
    self.valueMaps = nil
    self.ageEntry, self.wetEntry = nil, nil
    self.ageMod, self.ageFilter  = nil, nil
    self.wetMod, self.wetFilter  = nil, nil

    if g_server == nil then
        -- Server-only by design, and not an error. Stay silently inert.
        return false
    end
    if valueMaps == nil or not valueMaps.available then
        SoilLogger.warning("[GroundCells] value maps unavailable - ground condition cells stand down")
        return false
    end
    if valueMaps.getLayerEntry == nil or valueMaps.readRawAtWorld == nil then
        SoilLogger.warning(
            "[GroundCells] the SoilValueMaps in scope has none of the SF-43 methods - this is the " ..
            "community-fork collision (same global, same filenames, different code). Standing down.")
        return false
    end

    local ageKey = MaterialDown ~= nil and MaterialDown.LAYER_KEY or nil
    local wetKey = MaterialWetness ~= nil and MaterialWetness.LAYER_KEY or nil
    if ageKey == nil or wetKey == nil then
        SoilLogger.warning("[GroundCells] condition layer keys did not resolve - standing down")
        return false
    end

    local ageEntry = valueMaps:getLayerEntry(ageKey)
    local wetEntry = valueMaps:getLayerEntry(wetKey)
    if ageEntry == nil or wetEntry == nil then
        SoilLogger.warning(
            "[GroundCells] condition layer(s) did not resolve (age=%s wetness=%s) - standing down",
            tostring(ageEntry ~= nil), tostring(wetEntry ~= nil))
        return false
    end

    -- Both condition layers must share one geometry. A mismatch is not something
    -- we can average over: a cell index would mean two different squares of ground
    -- on the two layers, so condition is simply unavailable.
    local resolution  = valueMaps.resolution
    local terrainSize = valueMaps.terrainSize
    if type(resolution) ~= "number" or resolution <= 0
       or type(terrainSize) ~= "number" or terrainSize <= 0 then
        SoilLogger.warning("[GroundCells] layer geometry is not established (res=%s size=%s) - standing down",
            tostring(resolution), tostring(terrainSize))
        return false
    end

    -- The engine created both layers at SoilValueMaps.resolution; prove it rather
    -- than trust it, because a hand-supplied or migrated layer file can differ and
    -- the loader only warns.
    local okAge, ageW = pcall(getBitVectorMapSize, ageEntry.bvm)
    local okWet, wetW = pcall(getBitVectorMapSize, wetEntry.bvm)
    if okAge and okWet and type(ageW) == "number" and type(wetW) == "number" then
        if ageW ~= wetW then
            SoilLogger.warning(
                "[GroundCells] condition layers disagree on width (age=%d wetness=%d) - " ..
                "one cell index would mean two different squares of ground. Standing down.",
                ageW, wetW)
            return false
        end
        if ageW ~= resolution then
            SoilLogger.warning(
                "[GroundCells] condition layer width %d does not match the map resolution %d - standing down",
                ageW, resolution)
            return false
        end
    end
    -- getBitVectorMapSize being unavailable is not itself a refusal: the loader
    -- already refuses a mismatched width at load. We simply could not re-verify.

    -- Our own modifiers. Not the layer's shared ones (see the header note).
    local okMods, err = pcall(function()
        self.ageMod    = DensityMapModifier.new(ageEntry.bvm, 0, NUM_CHANNELS, g_terrainNode)
        self.ageFilter = DensityMapFilter.new(self.ageMod)
        self.wetMod    = DensityMapModifier.new(wetEntry.bvm, 0, NUM_CHANNELS, g_terrainNode)
        self.wetFilter = DensityMapFilter.new(self.wetMod)
    end)
    if not okMods then
        SoilLogger.warning("[GroundCells] could not build dedicated condition modifiers (%s) - standing down",
            tostring(err))
        self.ageMod, self.ageFilter, self.wetMod, self.wetFilter = nil, nil, nil, nil
        return false
    end

    self.valueMaps        = valueMaps
    self.ageEntry         = ageEntry
    self.wetEntry         = wetEntry
    self.resolution       = resolution
    self.terrainSize      = terrainSize
    self.epoch            = self.epoch + 1
    self.geometryRevision = self.geometryRevision + 1
    self.armed            = true

    SoilLogger.info("[OK] GroundConditionCells armed (%dx%d cells, %.2f m grain, epoch %d)",
        resolution, resolution, terrainSize / resolution, self.epoch)
    return true
end

function GroundConditionCells:isArmed()
    return self.armed
end

function GroundConditionCells:standDown(why)
    if self.armed then
        SoilLogger.warning("[GroundCells] standing down: %s", tostring(why))
    end
    self.armed = false
end

-- =========================================================
-- Geometry
-- =========================================================

--- A DETACHED description of the condition grid. Detached on purpose: the caller
--- may hold it across a call, and it must not be a live view that changes under
--- them. A geometry whose epoch or revision no longer matches is refused by every
--- read and write, which is what makes holding it safe.
---@return table|nil
function GroundConditionCells:getConditionGeometry()
    if not self.armed then return nil end
    local resolution = self.resolution
    return {
        epoch            = self.epoch,
        geometryRevision = self.geometryRevision,
        terrainSize      = self.terrainSize,
        resolution       = resolution,
        -- The layer spans the terrain centred on the origin, so the negative
        -- corner is at -terrainSize/2 on both axes. Stated explicitly so a caller
        -- does not have to re-derive the convention.
        originX          = -self.terrainSize * 0.5,
        originZ          = -self.terrainSize * 0.5,
        grainMetres      = self.terrainSize / resolution,
    }
end

--- True when `geometry` still describes the live grid.
function GroundConditionCells:isGeometryCurrent(geometry)
    if not self.armed or type(geometry) ~= "table" then return false end
    return geometry.epoch == self.epoch
       and geometry.geometryRevision == self.geometryRevision
       and geometry.resolution == self.resolution
       and geometry.terrainSize == self.terrainSize
end

local function isFinite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isCellIndex(n, resolution)
    return isFinite(n) and math.floor(n) == n and n >= 0 and n <= resolution - 1
end

--- World position to cell index, with the positive edge EXCLUSIVE.
--- Nonfinite or outside-map coordinates are rejected here, BEFORE any clamped
--- lookup: clamping an off-map coordinate would silently record condition against
--- the nearest edge cell, which is a wrong record rather than a missing one.
---@return number|nil gx, number|nil gz
function GroundConditionCells:worldToCell(geometry, worldX, worldZ)
    if not self:isGeometryCurrent(geometry) then return nil, nil end
    if not isFinite(worldX) or not isFinite(worldZ) then return nil, nil end

    local size = geometry.terrainSize
    local half = size * 0.5
    -- Positive edge exclusive: a coordinate exactly at +half belongs to no cell.
    if worldX < -half or worldX >= half or worldZ < -half or worldZ >= half then
        return nil, nil
    end

    local resolution = geometry.resolution
    local gx = math.floor((worldX + half) / size * resolution)
    local gz = math.floor((worldZ + half) / size * resolution)
    -- Floating point can still land one past the end at the very edge.
    if gx > resolution - 1 or gz > resolution - 1 or gx < 0 or gz < 0 then
        return nil, nil
    end
    return gx, gz
end

-- =========================================================
-- Exact cell read
-- =========================================================

--- Read one named cell exactly. No field mean, no display-row sample and no
--- nearest-cell fallback: an unreadable cell reports unavailable, because a
--- plausible substitute value is indistinguishable from a real record downstream.
---@return table result  { ageRaw, wetnessRaw, ageAvailable, wetnessAvailable,
---                        epoch, geometryRevision, refused }
function GroundConditionCells:readConditionCell(geometry, gx, gz)
    local blank = {
        ageRaw           = nil,
        wetnessRaw       = nil,
        ageAvailable     = false,
        wetnessAvailable = false,
        epoch            = self.epoch,
        geometryRevision = self.geometryRevision,
        refused          = nil,
    }

    if not self.armed then
        blank.refused = GroundConditionCells.REFUSE_NOT_ARMED
        return blank
    end
    if not self:isGeometryCurrent(geometry) then
        blank.refused = GroundConditionCells.REFUSE_GEOMETRY
        return blank
    end
    local resolution = geometry.resolution
    if not isCellIndex(gx, resolution) or not isCellIndex(gz, resolution) then
        blank.refused = GroundConditionCells.REFUSE_COORDS
        return blank
    end

    local okAge, ageRaw = pcall(getBitVectorMapPoint, self.ageEntry.bvm, gx, gz, 0, NUM_CHANNELS)
    local okWet, wetRaw = pcall(getBitVectorMapPoint, self.wetEntry.bvm, gx, gz, 0, NUM_CHANNELS)

    blank.ageAvailable     = okAge and type(ageRaw) == "number"
    blank.wetnessAvailable = okWet and type(wetRaw) == "number"
    if blank.ageAvailable     then blank.ageRaw     = ageRaw end
    if blank.wetnessAvailable then blank.wetnessRaw = wetRaw end
    return blank
end

-- =========================================================
-- Exact cell write
-- =========================================================

local function isWritableAgeRaw(raw)
    return isFinite(raw) and math.floor(raw) == raw
       and raw >= RAW_MIN_VALUE and raw <= RAW_MAX_VALUE
end

--- Wetness has reserved bytes that are not condition values. Writing one would
--- create a reading no reader can interpret, so refuse before touching the layer.
local function isWritableWetnessRaw(raw)
    if not (isFinite(raw) and math.floor(raw) == raw) then return false end
    if raw == WET_ABSENT or raw == WET_SENTINEL then return true end
    return raw >= WET_FLOOR and raw <= RAW_MAX_VALUE
end

GroundConditionCells.isWritableAgeRaw     = isWritableAgeRaw
GroundConditionCells.isWritableWetnessRaw = isWritableWetnessRaw

--- Aim one modifier at the inset middle half of cell (gx,gz) in terrain UV.
local function aimAtCell(modifier, gx, gz, resolution)
    local u0 = (gx + 0.25) / resolution
    local v0 = (gz + 0.25) / resolution
    local u1 = (gx + 0.75) / resolution
    local v1 = (gz + 0.75) / resolution
    -- start, width point, height point - the same argument order IndoorMask uses.
    modifier:setParallelogramUVCoords(u0, v0, u1, v0, u0, v1, DensityCoordType.POINT_POINT_POINT)
end

--- Prove the aimed region is exactly the one cell we mean, before writing it.
--- Selects over the whole value range so every pixel in the region counts, then
--- requires (a) exactly one pixel selected and (b) its value to equal the exact
--- point read at gx/gz. Either failing means our UV mapping does not mean what we
--- think it means on this map, and no write may follow.
---@return boolean ok, string|nil refusedReason, number|nil currentRaw
local function preflightCell(modifier, filter, bvm, gx, gz, resolution)
    local ok, sum, numPixels = pcall(function()
        aimAtCell(modifier, gx, gz, resolution)
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN_VALUE, RAW_MAX_VALUE)
        local s, n = modifier:executeGet(filter)
        return s, n
    end)
    -- pcall returns (true, s, n) on success; unpack carefully because a throw puts
    -- the message in the second slot.
    if not ok then
        return false, GroundConditionCells.REFUSE_WRITE_THREW, nil
    end
    if type(numPixels) ~= "number" or numPixels ~= 1 then
        return false, GroundConditionCells.REFUSE_PREFLIGHT, nil
    end

    local okPoint, pointRaw = pcall(getBitVectorMapPoint, bvm, gx, gz, 0, NUM_CHANNELS)
    if not okPoint or type(pointRaw) ~= "number" then
        return false, GroundConditionCells.REFUSE_DISAGREE, nil
    end
    -- With exactly one selected pixel the summed value IS that pixel's raw value.
    if type(sum) ~= "number" or sum ~= pointRaw then
        return false, GroundConditionCells.REFUSE_DISAGREE, nil
    end
    return true, nil, pointRaw
end

--- Write one layer's cell: preflight, set over the SAME region, exact readback.
---@return boolean ok, string|nil refusedReason
local function writeOneLayer(modifier, filter, bvm, gx, gz, resolution, raw)
    local okPre, refusal = preflightCell(modifier, filter, bvm, gx, gz, resolution)
    if not okPre then
        return false, refusal
    end

    local okSet = pcall(function()
        -- Re-aim: the preflight's executeGet may have consumed the aim, and an
        -- unaimed executeSet would paint whatever region was last set.
        aimAtCell(modifier, gx, gz, resolution)
        modifier:executeSet(raw)
    end)
    if not okSet then
        return false, GroundConditionCells.REFUSE_WRITE_THREW
    end

    local okBack, back = pcall(getBitVectorMapPoint, bvm, gx, gz, 0, NUM_CHANNELS)
    if not okBack or back ~= raw then
        return false, GroundConditionCells.REFUSE_READBACK
    end
    return true, nil
end

--- Write the age/wetness pair for one cell.
---
--- Contract rules encoded here:
---   * A failed preflight writes NOTHING.
---   * The two layer writes are separate engine calls and are NOT atomic. If the
---     pair does not complete, the caller is told `partial` and which component
---     landed, and the coordinator marks BOTH components unavailable for the cell.
---     We never report a half-written pair as a complete record.
---   * Surviving bytes and any native material are preserved: we do not roll back
---     a landed write by stamping a guessed previous value over it, because the
---     value we read before the write is not proof of what the ground now holds.
---     Recovery is an explicit resample by the coordinator, not a silent retry.
---
---@param expectedRevision number|nil  owner revision the caller last saw; nil skips the check
---@return table result { ok, partial, refused, ageWritten, wetnessWritten, previousAgeRaw, previousWetnessRaw }
function GroundConditionCells:writeConditionCell(geometry, gx, gz, expectedRevision, ageRaw, wetnessRaw)
    local result = {
        ok                 = false,
        partial            = false,
        refused            = nil,
        ageWritten         = false,
        wetnessWritten     = false,
        previousAgeRaw     = nil,
        previousWetnessRaw = nil,
    }

    if not self.armed then
        result.refused = GroundConditionCells.REFUSE_NOT_ARMED
        return result
    end
    if not self:isGeometryCurrent(geometry) then
        result.refused = GroundConditionCells.REFUSE_GEOMETRY
        return result
    end
    local resolution = geometry.resolution
    if not isCellIndex(gx, resolution) or not isCellIndex(gz, resolution) then
        result.refused = GroundConditionCells.REFUSE_COORDS
        return result
    end
    if expectedRevision ~= nil and expectedRevision ~= self.geometryRevision then
        result.refused = GroundConditionCells.REFUSE_REVISION
        return result
    end
    -- Validate BOTH values before either write, so a bad wetness cannot leave a
    -- landed age write behind it.
    if not isWritableAgeRaw(ageRaw) or not isWritableWetnessRaw(wetnessRaw) then
        result.refused = GroundConditionCells.REFUSE_VALUE
        return result
    end

    local before = self:readConditionCell(geometry, gx, gz)
    result.previousAgeRaw     = before.ageRaw
    result.previousWetnessRaw = before.wetnessRaw

    local okAge, ageRefusal = writeOneLayer(
        self.ageMod, self.ageFilter, self.ageEntry.bvm, gx, gz, resolution, ageRaw)
    if not okAge then
        -- Nothing landed on age. Wetness is untouched, so this is a clean refusal
        -- rather than a partial pair.
        result.refused = ageRefusal
        return result
    end
    result.ageWritten = true

    local okWet, wetRefusal = writeOneLayer(
        self.wetMod, self.wetFilter, self.wetEntry.bvm, gx, gz, resolution, wetnessRaw)
    if not okWet then
        -- Age landed, wetness did not. The cell now holds a pair we did not intend
        -- as a whole; it is unavailable, not a record.
        result.partial = true
        result.refused = wetRefusal
        return result
    end
    result.wetnessWritten = true

    result.ok = true
    return result
end
