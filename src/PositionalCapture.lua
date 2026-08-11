-- =========================================================
-- FS25 Soil & Fertilizer - POSITIONAL HARVEST CAPTURE
-- =========================================================
-- The load remembers where it grew: the harvested load's contamination fraction
-- becomes the AREA-weighted integral of the ground the header actually crossed,
-- instead of the field average. Litres in this path are a 0/1 flag; area is the
-- reliable value.
--
-- B1 THE TALLY (this module, SF, independently buildable and inert). Per cutter
-- call in the harvest hook: read the contamination at the combine position and
-- accumulate {workedArea, workedArea x cellContamination} on the harvesting
-- vehicle (transient, server-side). The honest grain is per-call centre
-- sampling; empty/absent cells read the field scalar (neutrality is the
-- arithmetic, no branch). NEVER touches the hopper/yield path for volume.
--
-- B2 THE HANDOFF (a rider on the feed-provenance build). Where that build
-- consumes the harvest bus, the load's contaminatedFraction =
-- tally.weighted / tally.area (field scalar when the tally is empty). Not built
-- here; this module exposes the tally read for it.
--
-- Invariants: conservation-in-area (weights sum to worked area; fraction
-- bounded [0,1]); NO YIELD CHANNEL (zero effect on quantity or modifiers);
-- neutral-by-arithmetic; the NPC attribution gate upstream unchanged.
-- =========================================================
-- Author: TisonK
-- =========================================================

PositionalCapture = {}

PositionalCapture.ENABLED = true

-- The contamination read key on the value maps (the disease display layer).
PositionalCapture.CONTAM_KEY = "diseasePressure"

-- =========================================================
-- B1. The tally
-- =========================================================

--- The per-vehicle tally table (created lazily on the vehicle).
---@param vehicle table the harvesting combine
---@return table tally  { area = number, weighted = number, fieldId = number }
function PositionalCapture:_tally(vehicle)
    if not vehicle._pcTally then
        vehicle._pcTally = { area = 0, weighted = 0, fieldId = 0 }
    end
    return vehicle._pcTally
end

--- Read the contamination fraction at a world position: the value-map pixel
--- (disease pressure 0..1), or nil when unavailable / absent.
---@param selfSoilSystem table the SoilFertilitySystem
---@param x number
---@param z number
---@return number|nil contamination
function PositionalCapture:readContamination(selfSoilSystem, x, z)
    if not selfSoilSystem or not selfSoilSystem:vmAvailable() then return nil end
    return selfSoilSystem.valueMaps:readValueAtWorld(PositionalCapture.CONTAM_KEY, x, z)
end

--- Accumulate one cutter call into the vehicle tally. Area-weighted; empty or
--- absent cells read the field scalar (neutrality is the arithmetic).
---@param vehicle table the harvesting combine
---@param fieldId number
---@param field table the fieldData entry
---@param selfSoilSystem table the SoilFertilitySystem
---@param x number combine position
---@param z number combine position
---@param area number the worked area this call (the reliable value)
function PositionalCapture:accumulate(vehicle, fieldId, field, selfSoilSystem, x, z, area)
    if not PositionalCapture.ENABLED then return end
    if not vehicle or not area or area <= 0 then return end
    if g_server == nil then return end   -- server-side tally only

    local tally = self:_tally(vehicle)
    -- A field switch (combine moved to a new field) resets the tally so a load
    -- never mixes contamination across fields.
    if tally.fieldId ~= fieldId then
        tally.area, tally.weighted, tally.fieldId = 0, 0, fieldId
    end

    local contamination = self:readContamination(selfSoilSystem, x, z)
    if contamination == nil then
        -- Absent cell: the field scalar (disease 0..100 -> 0..1 fraction).
        contamination = (field and field.diseasePressure or 0) / 100.0
    else
        contamination = math.max(0, math.min(1, contamination / 100.0))
    end

    tally.area     = tally.area     + area
    tally.weighted = tally.weighted + area * contamination
end

--- The current load's contamination fraction: weighted / area, bounded [0,1].
--- Field scalar when the tally is empty (no cells captured yet).
---@param vehicle table
---@param field table|nil the fieldData entry (for the empty-load fallback)
---@return number fraction
function PositionalCapture:loadFraction(vehicle, field)
    local tally = vehicle and vehicle._pcTally
    if not tally or tally.area <= 0 then
        return (field and field.diseasePressure or 0) / 100.0
    end
    local f = tally.weighted / tally.area
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return f
end

--- Reset the tally (new load / vehicle unload). Called on hopper unload.
---@param vehicle table
function PositionalCapture:reset(vehicle)
    if vehicle then vehicle._pcTally = nil end
end
