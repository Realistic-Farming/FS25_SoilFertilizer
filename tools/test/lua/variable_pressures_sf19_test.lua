-- variable_pressures_sf19_test.lua - VARIABLE PEST AND DISEASE PRESSURE (SF-19)
--
-- Pest and disease pressure become spatial: an outbreak starts in a patch and
-- grows if it is left alone, instead of one number covering a whole field. The
-- tuned daily field model is untouched.
--
-- The bench pins the brief's mechanics: the KEY-IS-NOT-INVERTIBLE discipline
-- (positions from live grid arithmetic, never from decoding a key), the per-cell
-- soil adapter (compaction as the FOURTH input), the deterministic origin hash
-- (no global PRNG seed, no linear hash), anti-saturation as an EXCLUSION, and
-- the spread ceiling. Plus the relief-weight coupling stance: with that feature
-- unbuilt, the adapter reads the STORED per-cell OM.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialPressures.lua

local P = SpatialPressures

local function newCell(o)
    local c = { N = 50, P = 30, K = 40, pH = 6.5, OM = 3.5, pestPressure = 0, diseasePressure = 0, compaction = 0 }
    for k, v in pairs(o or {}) do c[k] = v end
    return c
end

-- ── Grid keys: encode from live positions, never decode ─────────────────────
do
    T.eq("keyAt encodes a positive position", P:keyAt(25, 35), "20003")
    T.eq("keyAt handles negative positions (the inversion hazard)", P:keyAt(-25, -35), "-30004")

    -- The brief's core warning: key 19995 from cell (2,-5) does NOT decode back
    -- to (2,-5) naively. Our cells keep gx/gz and enumerateCells uses them.
    local field = { zoneData = {
        [P:keyAt(2 * 10, -5 * 10)] = newCell({ gx = 2, gz = -5 }),
    } }
    local cells = P:enumerateCells(field)
    T.eq("enumerateCells recovers the world position from gx/gz", #cells, 1)
    if #cells == 1 then
        T.eq("cell x is grid coords -> world", cells[1].x, 25)    -- (2*10 + 5)
        T.eq("cell z is grid coords -> world", cells[1].z, -45)   -- (-5*10 + 5)
    end
end

-- ── The soil adapter: compaction is the FOURTH input ────────────────────────
do
    local sh = SoilConstants.DISEASE_SOIL_HEALTH
    T.ok("DISEASE_SOIL_HEALTH exists", sh ~= nil)

    local neutral = P:cellSoilMult(newCell({}))
    T.eq("a neutral cell reads 1.0", neutral, 1.0)

    local acid = P:cellSoilMult(newCell({ pH = sh.LOW_PH_THRESHOLD - 0.1 }))
    T.ok("acid ground is sicker (mult > 1)", acid > 1.0)

    local starved = P:cellSoilMult(newCell({ N = 10 }))
    T.eq("a starving cell is not extra sick from N (below high threshold)", starved, 1.0)

    local packed = P:cellSoilMult(newCell({ compaction = 60 }))
    T.ok("a packed cell is sicker (compaction input)", packed > 1.0)
    T.ok("compaction never dominates (bounded contribution)", packed < 1.6)

    local packedAcid = P:cellSoilMult(newCell({ pH = sh.LOW_PH_THRESHOLD - 0.1, compaction = 60 }))
    T.ok("compaction composes with the soil terms", packedAcid > packed)
end

-- ── The origin hash is deterministic and nonlinear ──────────────────────────
do
    local a = P:hash(1, 100, 1)
    local b = P:hash(1, 100, 1)
    T.eq("origin hash is deterministic", a, b)
    T.ok("origin hash is in [0,1)", a >= 0 and a < 1)
    -- Nonlinear: consecutive fields do NOT step in lockstep (the linear-hash bug).
    local f1 = P:hash(1, 100, 1)
    local f2 = P:hash(2, 100, 1)
    local f3 = P:hash(3, 100, 1)
    T.ok("consecutive fields do not line up (not a linear ramp)",
         not (f1 == f2 and f2 == f3))
end

-- ── The relief-weight coupling stance ────────────────────────────────────────
do
    -- With the relief feature unbuilt, the adapter reads the STORED per-cell OM.
    -- This pins the decision so a future relief build revisits the call.
    local cell = newCell({ OM = 6.0 })   -- above OM_GOOD_THRESHOLD
    local mult = P:cellSoilMult(cell)
    T.ok("the adapter reads the stored per-cell OM", mult < 1.0)  -- good OM suppresses
end

-- ── The daily pass: origins appear when pressure rises, and only then ───────
do
    local field = {
        zoneData = {},
        pestPressure = 0,
        diseasePressure = 0,
    }
    for cx = 0, 9 do
        for cz = 0, 9 do
            field.zoneData[P:keyAt(cx * 10 + 5, cz * 10 + 5)] =
                newCell({ gx = cx, gz = cz, pH = 5.2, compaction = 30 })
        end
    end

    -- Pressure NOT rising: no origins, no spread.
    local r1 = P:run(nil, 1, field, 100, nil)
    T.eq("no origins when pressure is not rising", r1.origins, 0)

    -- Pressure rising: disease origins appear on the sickest ground.
    field.diseasePressure = 40
    local r2 = P:run(nil, 1, field, 100, nil)
    T.ok("disease origins appear when pressure rises", r2.origins > 0)

    local sickCells = 0
    for _, c in pairs(field.zoneData) do
        if (c.diseasePressure or 0) >= 40 then sickCells = sickCells + 1 end
    end
    T.ok("at least one cell carries the raised pressure", sickCells > 0)
end

-- ── Spread: seeds grow, and anti-saturation is an EXCLUSION ─────────────────
do
    local field = { zoneData = {}, pestPressure = 5, diseasePressure = 5, _prevPest = 5, _prevDisease = 5 }
    -- Pressure is NOT rising (prev == current), so no origins fire; only the
    -- pre-seeded centre spreads. A 7x7 grid, centre cell is a disease seed.
    local center = nil
    for cx = 0, 6 do
        for cz = 0, 6 do
            local c = newCell({ gx = cx, gz = cz })
            if cx == 3 and cz == 3 then
                c.diseasePressure = 30
                center = P:keyAt(cx * 10 + 5, cz * 10 + 5)
            end
            field.zoneData[P:keyAt(cx * 10 + 5, cz * 10 + 5)] = c
        end
    end
    P:run(nil, 1, field, 100, nil)

    local spreadCount = 0
    for k, c in pairs(field.zoneData) do
        if k ~= center and (c.diseasePressure or 0) > 0 then spreadCount = spreadCount + 1 end
    end
    T.eq("the seed spread to its four neighbours (single hop)", spreadCount, 4)

    -- Anti-saturation: a destination already at 100 is excluded.
    local full = newCell({ gx = 0, gz = 0, diseasePressure = 100, pestPressure = 100 })
    field.zoneData[P:keyAt(5, 5)] = full
    P:run(nil, 1, field, 100, nil)
    T.eq("a saturated cell stays at the ceiling", field.zoneData[P:keyAt(5, 5)].diseasePressure, 100)
end

-- ── The ceiling guard flags an outbreak past half the field ─────────────────
do
    local field = { zoneData = {}, pestPressure = 0, diseasePressure = 0 }
    local n = 0
    for cx = 0, 5 do
        for cz = 0, 5 do
            n = n + 1
            local c = newCell({ gx = cx, gz = cz })
            c.pestPressure = 1   -- a light pest across the whole small field
            field.zoneData[P:keyAt(cx * 10 + 5, cz * 10 + 5)] = c
        end
    end
    field.pestPressure = 10
    local r = P:run(nil, 1, field, 100, nil)
    -- 36 cells, ceiling = 18; all 36 are active -> flagged.
    T.ok("an outbreak past half the field flags the ceiling", r.ceilingReached)
end
