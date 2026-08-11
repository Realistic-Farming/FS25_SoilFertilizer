-- =========================================================
-- FS25 Soil & Fertilizer - NEIGHBOUR CROSSING (SF-21)
-- =========================================================
-- The hedge stops being a wall: what arrives at a field's edge depends on what
-- is actually across it. Upgrades the variable-pressures build's edge mechanism
-- exactly as that brief reserved ("built so it can later ask what is on the
-- other side of a boundary"). Entirely inside SoilFertilizer; NPCFavor untouched.
--
-- Mechanism (from the brief):
--   B1. THE CROSSING PRE-PASS (the core; the completion gate is LAW). At the day
--       boundary, BEFORE the first daily mutation batch, a read-only pass over
--       the active fields samples a fixed short distance across each edge band
--       and stores the sampled NEIGHBOUR pressure in a transient per-day
--       snapshot. The sample uses the shipped two-step verbatim
--       (getFieldAtWorldPosition guarded, then farmland.id; then the cell key
--       into that field's zoneData with the scalar fallback). Nothing resolved =
--       wilderness (nil). The snapshot is transient: never saved, never synced.
--   B2. PEST: the arc weight recomposition. The edge-arrival weight becomes
--       GENERIC-OUTSIDE BASELINE (unchanged, every edge) x NEIGHBOUR MODIFIER
--       (1.0 for nil/zero; bounded amplification for pressure, monotonic). The
--       existing faster-rate ceiling still caps the result; anti-saturation
--       exclusion untouched. A zero-pressure district reproduces today's
--       behaviour EXACTLY.
--   B3. DISEASE: conducive-gated boundary seeding. Where the snapshot shows
--       infected ground across an arc AND boundary moisture is conducive (the
--       published SCS read, pcall, neutral-absent: absent = no disease crossing,
--       pest unaffected), roll the slow crossing; a success seeds a BOUNDARY-CELL
--       ORIGIN through the pressure build's own origin entry (never a direct
--       interior cell write). THE PROTECTION FENCE IS LAW: never seed onto
--       ground inside its active treatment-protection window (field-level
--       fungicideDaysLeft > 0).
--   B4. Constants: sampling distance (cells), modifier bound, disease crossing
--       rate, conducive threshold - all ratio-pass-tunable, conservative defaults.
--
-- Server-only. The snapshot is transient (per-day, cleared each day). No new
-- save surface, no new network surface, no money.
-- =========================================================
-- Author: TisonK
-- =========================================================

NeighbourCrossing = {}

NeighbourCrossing.ENABLED = true

-- Tunables (the brief's conservative defaults; ratio-pass-tunable later).
NeighbourCrossing.SAMPLE_DISTANCE_CELLS = 1   -- how far past the boundary to sample (cells)
NeighbourCrossing.MODIFIER_MAX          = 2.0 -- pest arc amplification cap (bounded, monotonic)
NeighbourCrossing.DISEASE_RATE          = 0.25-- per-arc daily roll for a disease crossing
NeighbourCrossing.CONDUCIVE_THRESHOLD   = 0.6 -- SCS boundary moisture 0-1 above which disease crosses
NeighbourCrossing.ARC_SAMPLES           = 4   -- samples per edge band arc

-- =========================================================
-- B1. The crossing pre-pass
-- =========================================================

--- Sample the neighbour pressure across one edge band of the field. Walks the
--- field polygon edges, and for each edge takes ARC_SAMPLES points just OUTSIDE
--- the boundary (SAMPLE_DISTANCE_CELLS), resolves the neighbour field at each
--- point, and reads its pest/disease pressure (cell where present, scalar
--- fallback). Returns the per-arc neighbour pressure table.
---@param selfHookMgr table the HookManager (for getFieldIdAtWorldPosition)
---@param selfSoilSystem table the SoilFertilitySystem (for fieldData reads)
---@param fieldId number
---@param field table
---@param poly table field polygon verts {x,z}
---@return table arcs  array of { pest = number, disease = number } per sampled arc
function NeighbourCrossing:sampleFieldNeighbours(selfHookMgr, selfSoilSystem, fieldId, field, poly)
    local arcs = {}
    if not selfHookMgr or not selfSoilSystem or not poly or #poly < 3 then return arcs end

    local zone = SoilConstants.ZONE
    local dist = NeighbourCrossing.SAMPLE_DISTANCE_CELLS * zone.CELL_SIZE
    local n = #poly
    local perEdge = math.max(1, math.floor(NeighbourCrossing.ARC_SAMPLES / n))

    -- Walk each polygon edge; step along it, sample just outside.
    for i = 1, n do
        local ax, az = poly[i].x, poly[i].z
        local bx, bz = poly[(i % n) + 1].x, poly[(i % n) + 1].z
        local dx, dz = bx - ax, bz - az
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.001 then
            local ux, uz = dx / len, dz / len
            -- outward normal (rotate edge direction -90 degrees)
            local nx, nz = -uz, ux
            for s = 0, perEdge - 1 do
                local t = (s + 0.5) / perEdge
                local px = ax + ux * (t * len) + nx * dist
                local pz = az + uz * (t * len) + nz * dist
                local otherId = selfHookMgr:getFieldIdAtWorldPosition(px, pz)
                if otherId and otherId ~= fieldId and otherId > 0 then
                    local other = selfSoilSystem.fieldData[otherId]
                    if other then
                        -- cell key into the neighbour's zoneData, scalar fallback
                        local cellKey = tostring(math.floor(px / zone.CELL_SIZE) * 10000
                            + math.floor(pz / zone.CELL_SIZE))
                        local cell = other.zoneData and other.zoneData[cellKey]
                        arcs[#arcs + 1] = {
                            pest    = (cell and cell.pestPressure)    or (other.pestPressure    or 0),
                            disease = (cell and cell.diseasePressure) or (other.diseasePressure or 0),
                        }
                    end
                end
            end
        end
    end
    return arcs
end

--- The B1 snapshot: run the pre-pass over all active fields and store the
--- transient per-day neighbour-pressure snapshot. Returns the snapshot table
--- { [fieldId] = arcs }. Called once per day BEFORE the daily mutation batches.
---@param selfHookMgr table
---@param selfSoilSystem table
---@return table snapshot
function NeighbourCrossing:runPrePass(selfHookMgr, selfSoilSystem)
    local snapshot = {}
    local fields = selfSoilSystem and selfSoilSystem.fieldData
    if not fields or not selfHookMgr then return snapshot end
    for fieldId, field in pairs(fields) do
        local poly = selfSoilSystem:_getFieldPolyVerts(fieldId, field)
        if poly then
            snapshot[fieldId] = self:sampleFieldNeighbours(selfHookMgr, selfSoilSystem, fieldId, field, poly)
        end
    end
    return snapshot
end

--- Whether the crossing pre-pass is complete for this field on this day. The
--- completion gate is LAW: daily mutation batches must not run before the flag.
---@param snapshot table the per-day snapshot
---@param fieldId number
---@return boolean
function NeighbourCrossing:snapshotReady(snapshot, fieldId)
    return snapshot ~= nil and snapshot[fieldId] ~= nil
end

-- =========================================================
-- B2. Pest arc weight recomposition
-- =========================================================

--- The neighbour modifier for one arc: generic-outside baseline x neighbour
--- modifier. 1.0 for nil/zero pressure (today's exact behaviour); bounded
--- amplification for pressure, monotonic.
---@param arc table|nil  { pest = number, ... } from the snapshot, nil for wilderness
---@return number modifier
function NeighbourCrossing:neighbourPestModifier(arc)
    if not arc then return 1.0 end
    local p = arc.pest or 0
    if p <= 0 then return 1.0 end
    -- Monotonic, bounded: pressure 100 -> MODIFIER_MAX, pressure 0 -> 1.0.
    local m = 1.0 + (NeighbourCrossing.MODIFIER_MAX - 1.0) * (p / 100.0)
    return math.min(NeighbourCrossing.MODIFIER_MAX, math.max(1.0, m))
end

-- =========================================================
-- B3. Disease conducive-gated boundary seeding
-- =========================================================

--- Boundary moisture at a point, via the published SCS read
--- (getMoisture(fieldId, x, z), the moisture store's positional read). pcall,
--- neutral: absent SCS / throwing read = nil (no disease crossing, pest
--- unaffected).
---@param fieldId number the field being seeded (the moisture gate is its ground)
---@param x number
---@param z number
---@return number|nil moisture 0..1
function NeighbourCrossing:boundaryMoisture(fieldId, x, z)
    local csMgr = g_currentMission and g_currentMission.cropStressManager
    if not csMgr then return nil end
    local ok, m = pcall(csMgr.getMoisture, csMgr, fieldId, x, z)
    if ok and type(m) == "number" then return m end
    return nil
end

--- Whether an arc is conducive for disease crossing: infected neighbour across
--- the arc AND boundary moisture above the threshold.
---@param fieldId number the field being seeded
---@param field table the field being seeded
---@param arc table|nil neighbour pressure across the arc
---@return boolean
function NeighbourCrossing:arcConducive(fieldId, field, arc)
    if not arc or (arc.disease or 0) <= 0 then return false end
    -- Field-level boundary moisture: sample at the field centre for stability
    -- (the gate is a field-level conducive check, not a per-arc pixel read).
    local cx, cz = 0, 0
    if field and field._snCenter then cx, cz = field._snCenter.x, field._snCenter.z end
    local m = self:boundaryMoisture(fieldId, cx, cz)
    if m == nil then return false end   -- absent SCS = no disease crossing
    return m >= NeighbourCrossing.CONDUCIVE_THRESHOLD
end

--- Roll disease boundary seeding for one field. For each conducive arc, roll the
--- slow crossing; a success seeds a BOUNDARY-CELL ORIGIN through the pressure
--- build's own origin entry. THE PROTECTION FENCE IS LAW: a protected field
--- (fungicideDaysLeft > 0) seeds nothing.
---@param selfSoilSystem table
---@param fieldId number
---@param field table
---@param arcs table the field's arc snapshot
---@param day number
---@return number seedsPlaced
function NeighbourCrossing:rollDiseaseCrossing(selfSoilSystem, fieldId, field, arcs, day)
    if (field.fungicideDaysLeft or 0) > 0 then return 0 end   -- the protection fence
    if not arcs or #arcs == 0 then return 0 end

    local seedsPlaced = 0
    for i, arc in ipairs(arcs) do
        local conductive = self:arcConducive(fieldId, field, arc)
        if conductive and SpatialPressures and SpatialPressures.ENABLED then
            local r = SpatialPressures:hash(fieldId, day, i + 1000)
            if r < NeighbourCrossing.DISEASE_RATE then
                -- Seed a boundary origin through the pressure build's own entry.
                local ok, seeded = pcall(SpatialPressures.seedBoundaryOrigin, SpatialPressures,
                    selfSoilSystem, fieldId, field, day)
                if ok and seeded then seedsPlaced = seedsPlaced + 1 end
            end
        end
    end
    return seedsPlaced
end

-- =========================================================
-- Day-cadence hook: the crossing pre-pass + the disease roll. Called from the
-- daily pass BEFORE the mutation batches (the completion gate is LAW).
-- =========================================================

---@param selfHookMgr table
---@param selfSoilSystem table
---@param fieldId number
---@param field table
---@param day number
---@return number seedsPlaced
function NeighbourCrossing:runDaily(selfHookMgr, selfSoilSystem, fieldId, field, day)
    if not NeighbourCrossing.ENABLED then return 0 end
    if not selfSoilSystem or not field then return 0 end
    local poly = selfSoilSystem:_getFieldPolyVerts(fieldId, field)
    if not poly then return 0 end
    local arcs = self:sampleFieldNeighbours(selfHookMgr, selfSoilSystem, fieldId, field, poly)
    if #arcs == 0 then return 0 end
    return self:rollDiseaseCrossing(selfSoilSystem, fieldId, field, arcs, day)
end
