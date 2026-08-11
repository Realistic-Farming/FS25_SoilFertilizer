-- positional_capture_spec_test.lua - POSITIONAL HARVEST CAPTURE
--
-- Pins the brief's bar: the tally's conservation-in-area (weights sum to worked
-- area), the neutral-by-arithmetic fallback (absent cell reads the field
-- scalar), the bounded fraction [0,1], the field-switch reset, the NO-YIELD
-- fence (no hopper/volume surface), and empty-load safety.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/PositionalCapture.lua

local PC = PositionalCapture

-- â”€â”€ 1. Conservation + boundedness: the weighted sum tracks worked area â”€â”€â”€â”€â”€â”€â”€
do
    g_currentMission = { terrainSize = 4096 }
    g_server = {}
    g_server = {}
    local soil = { valueMaps = {
        available = true,
        readValueAtWorld = function(_self, _key, x, _z)
            -- contamination 0.4 in the west, 0.8 in the east
            if x < 0 then return 40 end
            return 80
        end,
    }, vmAvailable = function() return true end }

    local combine = {}
    -- Two cutter calls: area 10 at x=-5 (contam 0.4), area 30 at x=5 (contam 0.8).
    PC:accumulate(combine, 1, { diseasePressure = 50 }, soil, -5, 0, 10)
    PC:accumulate(combine, 1, { diseasePressure = 50 }, soil, 5, 0, 30)

    local tally = combine._pcTally
    T.near("worked area conserved", tally.area, 40, 1e-9)
    T.near("weighted sum = area-weighted integral", tally.weighted, 10*0.4 + 30*0.8, 1e-9)
    local frac = PC:loadFraction(combine)
    T.near("fraction = weighted / area", frac, (10*0.4 + 30*0.8) / 40, 1e-9)
    T.ok("fraction bounded [0,1]", frac >= 0 and frac <= 1)
end

-- â”€â”€ 2. Neutral-by-arithmetic: absent cell reads the field scalar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
do
    g_currentMission = { terrainSize = 4096 }
    g_server = {}
    local soil = { valueMaps = {
        available = true,
        readValueAtWorld = function() return nil end,   -- no pixel written
    }, vmAvailable = function() return true end }

    local combine = {}
    PC:accumulate(combine, 1, { diseasePressure = 60 }, soil, 0, 0, 20)
    local frac = PC:loadFraction(combine, { diseasePressure = 60 })
    T.near("absent cell -> field scalar fraction", frac, 0.6, 1e-9)
end

-- â”€â”€ 3. The field-switch reset: a load never mixes fields â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
do
    g_currentMission = { terrainSize = 4096 }
    g_server = {}
    local soil = { valueMaps = {
        available = true,
        readValueAtWorld = function() return 100 end,
    }, vmAvailable = function() return true end }

    local combine = {}
    PC:accumulate(combine, 1, { diseasePressure = 50 }, soil, 0, 0, 10)
    PC:accumulate(combine, 2, { diseasePressure = 0 }, soil, 0, 0, 10)  -- switch field
    T.eq("tally resets on field switch", combine._pcTally.area, 10)
    T.eq("tally tracks the new field", combine._pcTally.fieldId, 2)
end

-- â”€â”€ 4. The NO-YIELD fence: no hopper/volume surface exists â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
do
    -- The module exposes only accumulate/loadFraction/reset. It never writes
    -- liters, yield, or any quantity channel. Assert the surface is lean.
    T.eq("no yield surface", PC.modifyYield, nil)
    T.eq("no volume surface", PC.setHopperVolume, nil)
end

-- â”€â”€ 5. Empty-load safety: no tally yet -> field scalar fraction â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
do
    local frac = PC:loadFraction({}, { diseasePressure = 40 })
    T.near("empty load -> field scalar", frac, 0.4, 1e-9)
    local fracNil = PC:loadFraction({}, nil)
    T.eq("no field -> zero fraction", fracNil, 0)
end

-- â”€â”€ 6. Reset clears the tally â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
do
    g_currentMission = { terrainSize = 4096 }
    g_server = {}
    local soil = { valueMaps = { available = true, readValueAtWorld = function() return 50 end },
        vmAvailable = function() return true end }
    local combine = {}
    PC:accumulate(combine, 1, { diseasePressure = 50 }, soil, 0, 0, 20)
    PC:reset(combine)
    T.eq("reset clears the tally", combine._pcTally, nil)
end
