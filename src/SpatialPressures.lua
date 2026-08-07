-- =========================================================
-- FS25 Soil & Fertilizer - VARIABLE PEST AND DISEASE PRESSURE (SF-19)
-- =========================================================
-- Pest and disease pressure become spatial: an outbreak starts in a patch and
-- grows if it is left alone, instead of one number covering a whole field.
--
-- The tuned daily field model is UNTOUCHED. It keeps answering "how hard is the
-- year pressing." This adds only WHERE the pressure lands and how it moves.
--
-- Mechanism (from the brief, section 3):
--   1. ORIGIN: when the daily model raises pressure, pick a cell rather than
--      the whole field. Disease weights wet, packed, starved and acid ground
--      (a per-cell soil adapter over the shipped soilHealthMult inputs, plus
--      compaction as a FOURTH input, the brief's add). Pest weights distance
--      from the field boundary (roughly 10-30m, fading, not hard-edged).
--   2. SPREAD: seed and stamp, not diffusion. Infected spots are seeds; growth
--      widens one or spawns a fresh spot a short offset away. Work is
--      proportional to seeds, not cells. ANTI-SATURATION IS AN EXCLUSION: a
--      destination already at maximum is excluded; a seed with nowhere to grow
--      stops being a seed. Pest spreads faster, disease slower.
--   3. CEILING: an untreated outbreak must not exceed roughly HALF a field's
--      area in ONE in-game month at the easiest difficulty.
--   4. THE KEY IS NOT SAFELY INVERTIBLE FOR NEGATIVE COORDINATES. We choose a
--      WORLD POSITION inside the field and derive the key from it. We NEVER
--      enumerate keys and decode them back to positions.
--
-- Server-only. Writes only the zoneData store SoilFertilizer already owns and
-- persists. No new handle, no money, no other mod's model.
-- =========================================================
-- Author: TisonK
-- =========================================================

SpatialPressures = {}

SpatialPressures.ENABLED = true

-- Tunables (the brief's numbers; awaiting the SF-19 spine split, one-line changes)
-- The pending spine split is ruled: the pest half routes onto Agronomy, the
-- disease half onto Biological. Until the spine builds, these four dials are the
-- neutral default character (same awaiting-the-spine form as EmergencyLoan).
SpatialPressures.PEST_EDGE_MIN_M   = 10      -- edge band inner radius (m)
SpatialPressures.PEST_EDGE_MAX_M   = 30      -- edge band outer radius (m)
SpatialPressures.CEILING_FRACTION  = 0.5     -- max outbreak = half the field
SpatialPressures.SEED_CAP          = 200     -- max seeds scanned per day per field

-- A local, stable, NONLINEAR generator for outbreak placement. The brief warns
-- against both seeding the global PRNG and using a linear hash (which put every
-- field's outbreak in lockstep). fract(sin(x)) is the shipped idiom for stable
-- nonlinearity across save and load; a local instance avoids the shared global.
local function fract(x)
    return x - math.floor(x)
end

local function hash2(seedA, seedB)
    return fract(math.sin(seedA * 127.1 + seedB * 311.7) * 43758.5453123)
end

--- The deterministic hash for a (fieldId, day, slot) triple. Used for ORIGIN
--- placement so the same field on the same day picks the same cells (stable
--- across save/load), without touching the global PRNG.
---@param fieldId number
---@param day number
---@param slot number
---@return number  in [0,1)
function SpatialPressures:hash(fieldId, day, slot)
    return hash2(fieldId * 1009 + day, slot * 733 + fieldId)
end

-- =========================================================
-- Cell geometry
-- =========================================================

--- Enumerate a field's zoneData cells with their WORLD CENTRE POSITIONS.
--- Positions are derived FROM the live zone grid arithmetic, never by decoding
--- a stored key. Returns { { key, x, z, cell }, ... }.
---@param field table
---@return table cells
function SpatialPressures:enumerateCells(field)
    local out = {}
    local zone = SoilConstants.ZONE
    for key, cell in pairs(field.zoneData or {}) do
        -- Recover the grid coords from the KEY only via the known layout:
        -- key = tostring(cx*10000+cz). For negative cx/cz this string is NOT
        -- safely invertible, so we instead store grid coords on the cell when
        -- it was created. Cells created by _prePopulateZoneData and the spray
        -- path carry them; a cell without them is skipped (never guessed).
        if type(cell.gx) == "number" and type(cell.gz) == "number" then
            out[#out + 1] = {
                key = key,
                x   = cell.gx * zone.CELL_SIZE + zone.CELL_SIZE * 0.5,
                z   = cell.gz * zone.CELL_SIZE + zone.CELL_SIZE * 0.5,
                cell = cell,
            }
        end
    end
    return out
end

--- Cell key from a WORLD POSITION. Encode from live positions only; never
--- decode a key back into a position.
---@param x number
---@param z number
---@return string
function SpatialPressures:keyAt(x, z)
    local cs = SoilConstants.ZONE.CELL_SIZE
    local cx = math.floor(x / cs)
    local cz = math.floor(z / cs)
    return tostring(cx * 10000 + cz)
end

-- =========================================================
-- The soil adapter (disease weighting). THE RELIEF-WEIGHT COUPLING:
-- the relief feature (SF-20) is NOT built, so the adapter reads the STORED
-- per-cell OM (never a weighted value). If relief-weight ever builds, this
-- call must be revisited and the choice stated (the brief: read the WEIGHTED
-- value, Arissani's call).
-- =========================================================

--- The disease soil multiplier for ONE CELL. Mirrors the field-level
--- soilHealthMult inputs but with cell values, and adds compaction as a fourth
--- input (the brief's add: headlands become disease-prone from the player's own
--- turning). Returns a multiplier >= 1 (sicker ground grows pressure faster).
---@param cell table  a zoneData cell (.pH/.N/.OM/.compaction)
---@return number mult
function SpatialPressures:cellSoilMult(cell)
    local sh = SoilConstants.DISEASE_SOIL_HEALTH
    if not sh or not cell then return 1.0 end
    local mult = 1.0
    local ph = cell.pH or 6.5
    local n  = cell.N  or 50
    local om = cell.OM or 3.5
    if ph < sh.LOW_PH_THRESHOLD then mult = mult * sh.LOW_PH_MULT end
    if n  > sh.HIGH_N_THRESHOLD then mult = mult * sh.HIGH_N_MULT end
    if om >= sh.OM_GOOD_THRESHOLD then mult = mult * sh.OM_GOOD_MULT end
    -- Compaction: a packed cell is sicker. Linear 1.0 at 0 up to a cap; never
    -- lets an empty category dominate (the term is additive, not the whole).
    local comp = cell.compaction or 0
    if comp > 0 then
        mult = mult * (1.0 + math.min(0.5, comp / 100.0))
    end
    return mult
end

--- The pest edge weight for a cell: favours the field boundary (roughly
--- 10-30m, fading rather than hard-edged). distanceToEdge is metres.
---@param distanceToEdge number|nil
---@return number weight  in [0,1]
function SpatialPressures:pestEdgeWeight(distanceToEdge)
    if distanceToEdge == nil then return 0.0 end
    if distanceToEdge <= SpatialPressures.PEST_EDGE_MIN_M then return 1.0 end
    if distanceToEdge >= SpatialPressures.PEST_EDGE_MAX_M then return 0.0 end
    -- linear fade across the band
    local t = (SpatialPressures.PEST_EDGE_MAX_M - distanceToEdge)
        / (SpatialPressures.PEST_EDGE_MAX_M - SpatialPressures.PEST_EDGE_MIN_M)
    return math.max(0.0, math.min(1.0, t))
end

-- =========================================================
-- The daily pass
-- =========================================================

--- Run the spatial pass for one field on one day. Server-only, called from
--- _processOneDailyField AFTER the field-level pest/disease values are computed.
---
--- The field-level model owns the AGGREGATE pressure; this pass distributes it
--- onto the per-cell store and adds ORIGIN + SPREAD. It writes ONLY zoneData
--- cells (the store the mod already owns and persists).
---
---@param selfSoilSystem table  the SoilFertilitySystem (for settings reads)
---@param fieldId number
---@param field table
---@param day number
---@param fieldPoly table|nil  { x, z } verts or nil (edge distance disabled)
---@return table result  { origins, seeds, ceilingReached }
function SpatialPressures:run(selfSoilSystem, fieldId, field, day, fieldPoly)
    if not SpatialPressures.ENABLED then return { origins = 0, seeds = 0, ceilingReached = false } end
    if not field or not field.zoneData then
        return { origins = 0, seeds = 0, ceilingReached = false }
    end

    local cells = self:enumerateCells(field)
    if #cells == 0 then
        return { origins = 0, seeds = 0, ceilingReached = false }
    end

    local zone = SoilConstants.ZONE
    local half = zone.CELL_SIZE * 0.5
    local cellCount = #cells

    -- Precompute per-cell edge distance (metres) once per day, cheap: distance
    -- from the cell centre to the field polygon. nil when no polygon is given
    -- (edge weighting degrades to uniform, pest still spreads from origins).
    local distances = {}
    if fieldPoly and #fieldPoly >= 3 then
        for i, c in ipairs(cells) do
            distances[i] = self:_distanceToPoly(c.x, c.z, fieldPoly)
        end
    end

    -- ── ORIGIN ──────────────────────────────────────────────────────────────
    -- When the daily model raised pressure, pick cells weighted by soil (disease)
    -- or edge (pest) instead of the whole field. The number of origins scales
    -- with how hard the year is pressing, so a calm year spawns none.
    local origins = 0
    local pestRaised  = (field.pestPressure    or 0) > (field._prevPest    or 0)
    local diseaseRaised = (field.diseasePressure or 0) > (field._prevDisease or 0)

    if diseaseRaised then
        local weights, totalW = {}, 0
        for i, c in ipairs(cells) do
            local w = self:cellSoilMult(c.cell)
            weights[i] = w
            totalW = totalW + w
        end
        -- Spawn 1 origin per ~25 cells, min 1 when pressure is rising.
        local count = math.max(1, math.floor(cellCount / 25))
        for s = 1, count do
            local r = self:hash(fieldId, day, s)
            local acc = 0
            local pick = nil
            local guard = 0
            while pick == nil and guard < cellCount do
                guard = guard + 1
                acc = acc + (weights[guard] or 1.0)
                if acc >= r * (totalW or 1.0) then pick = guard end
            end
            if pick then
                local c = cells[pick]
                c.cell.diseasePressure = math.max(c.cell.diseasePressure or 0,
                    field.diseasePressure or 0)
                origins = origins + 1
            end
        end
    end

    if pestRaised then
        -- pest origin: edge-weighted pick
        local weights, totalW = {}, 0
        for i, c in ipairs(cells) do
            local w = 0.5 + self:pestEdgeWeight(distances[i])
            weights[i] = w
            totalW = totalW + w
        end
        local count = math.max(1, math.floor(cellCount / 25))
        for s = 1, count do
            local r = self:hash(fieldId, day * 7 + 13, s)
            local acc = 0
            local pick = nil
            local guard = 0
            while pick == nil and guard < cellCount do
                guard = guard + 1
                acc = acc + (weights[guard] or 1.0)
                if acc >= r * (totalW or 1.0) then pick = guard end
            end
            if pick then
                local c = cells[pick]
                c.cell.pestPressure = math.max(c.cell.pestPressure or 0,
                    field.pestPressure or 0)
                origins = origins + 1
            end
        end
    end

    -- ── SPREAD ──────────────────────────────────────────────────────────────
    -- Seed and stamp. Seeds are cells already carrying pressure; growth either
    -- widens a seed's value or spawns a fresh spot a short offset away. Work is
    -- proportional to seeds, not cells. SNAPSHOT the seed set BEFORE spreading
    -- so a cell seeded this pass does not seed again in the same pass (single
    -- hop per day; keeps pest-faster / disease-slower meaningful).
    local seeds = 0
    local ceilingReached = false
    local ceilingCells = math.floor(cellCount * SpatialPressures.CEILING_FRACTION)

    local seedList = {}
    for _, c in ipairs(cells) do
        if (c.cell.pestPressure or 0) > 0 or (c.cell.diseasePressure or 0) > 0 then
            seedList[#seedList + 1] = c
        end
    end

    for _, c in ipairs(seedList) do
        if seeds >= SpatialPressures.SEED_CAP then break end
        local seedPest    = (c.cell.pestPressure    or 0)
        local seedDisease = (c.cell.diseasePressure or 0)
        -- Anti-saturation: a destination already at maximum is excluded.
        -- A seed whose every neighbour is at maximum stops being a seed
        -- (it has nowhere to grow) - handled below by skipping full cells.
        seeds = seeds + 1
        local spreadTo = { {1,0}, {-1,0}, {0,1}, {0,-1} }
        for _, d in ipairs(spreadTo) do
            local nx = c.x + d[1] * zone.CELL_SIZE
            local nz = c.z + d[2] * zone.CELL_SIZE
            local nkey = self:keyAt(nx, nz)
            local ncell = field.zoneData[nkey]
            if ncell then
                local fullPest    = (ncell.pestPressure    or 0) >= 100
                local fullDisease = (ncell.diseasePressure or 0) >= 100
                -- A seed with every neighbour full stops growing (no where).
                if fullPest and fullDisease then
                    -- skip; this seed is spent
                else
                    -- Pest spreads faster, disease slower.
                    if not fullPest and seedPest > 0 then
                        ncell.pestPressure = math.min(100, (ncell.pestPressure or 0) + 8)
                    end
                    if not fullDisease and seedDisease > 0 then
                        ncell.diseasePressure = math.min(100, (ncell.diseasePressure or 0) + 4)
                    end
                end
            end
        end
    end

    -- Ceiling: count non-zero disease/pest cells. If over half the field, this
    -- is flagged (the daily field model keeps the aggregate capped; this is the
    -- spread ceiling guard).
    local active = 0
    for _, c in ipairs(cells) do
        if (c.cell.diseasePressure or 0) > 0 or (c.cell.pestPressure or 0) > 0 then
            active = active + 1
        end
    end
    ceilingReached = active >= ceilingCells and ceilingCells > 0

    -- Remember the field aggregate for next day's origin comparison.
    field._prevPest    = field.pestPressure    or 0
    field._prevDisease = field.diseasePressure or 0

    return { origins = origins, seeds = seeds, ceilingReached = ceilingReached }
end

--- Distance from a point to a polygon (metres). Standard winding-rule point-in-
--- polygon plus edge distance; enough for the fade band. Returns nil for a
--- point OUTSIDE the polygon (edge weighting only applies inside the field).
---@param x number
---@param z number
---@param poly table  { x, z } verts
---@return number|nil distanceToEdge
function SpatialPressures:_distanceToPoly(x, z, poly)
    -- quick inside test (ray cast)
    local inside = false
    local n = #poly
    local j = n
    for i = 1, n do
        local xi, zi = poly[i].x, poly[i].z
        local xj, zj = poly[j].x, poly[j].z
        if ((zi > z) ~= (zj > z)) and
           (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    if not inside then return nil end

    -- distance to nearest polygon edge
    local best = math.huge
    for i = 1, n do
        local ax, az = poly[i].x, poly[i].z
        local bx, bz = poly[(i % n) + 1].x, poly[(i % n) + 1].z
        local dx, dz = bx - ax, bz - az
        local len2 = dx * dx + dz * dz
        local t = 0
        if len2 > 0 then
            t = ((x - ax) * dx + (z - az) * dz) / len2
            t = math.max(0, math.min(1, t))
        end
        local px, pz = ax + t * dx, az + t * dz
        local d = (x - px) * (x - px) + (z - pz) * (z - pz)
        if d < best then best = d end
    end
    return math.sqrt(best)
end
