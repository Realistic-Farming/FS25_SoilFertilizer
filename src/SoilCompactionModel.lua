-- =====================================================================================
-- SoilCompactionModel.lua
-- -------------------------------------------------------------------------------------
-- Ground-pressure compaction model, grounded in extension agronomy (Penn State,
-- Missouri) rather than raw vehicle mass. Compaction per pass is two independent terms,
-- scaled by a soil-moisture multiplier:
--
--   SURFACE  ∝ ground contact pressure ≈ tyre inflation pressure. Wide / flotation /
--             aired-down tyres spread the load → low pressure → little surface packing.
--   SUBSOIL  ∝ axle load (independent of tyres). ~10 t/axle damages subsoil; <5 t/axle
--             does not. The permanent-damage term that a big tyre cannot avoid.
--   MOISTURE multiplier: wet soil compacts far worse ("hydraulic ram"); dry resists.
--
-- Variable Tire Pressure (HotShotPepper, ModHub) integration:
--   When VTP is installed it exposes a live, transition-interpolated effective pressure
--   in bar via vehicle:vtpGetDashboardPressureBar(). Surface contact pressure ≈ tyre
--   inflation pressure (PSU), so we read that bar value DIRECTLY as our surface pressure
--   — airing down to FIELD mode automatically lowers compaction. With VTP absent we
--   approximate contact pressure from live wheel geometry instead.
--
-- The vehicle/VTP reads live here; the scoring math (scorePoints / advanceWetness) is
-- pure and unit-tested under tools/test.
-- =====================================================================================

SoilCompactionModel = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local GRAVITY = 9.81

-- -------------------------------------------------------------------------------------
-- PURE: compaction points for a single pass.
--   pressureKPa : surface contact pressure (nil → no surface term)
--   axleLoadT   : tonnes per axle  (nil → no subsoil term)
--   wetness01   : 0 (bone dry) .. 1 (saturated)
--   rateMult    : tuningCompactionRate multiplier (0 disables all build-up)
-- -------------------------------------------------------------------------------------
function SoilCompactionModel.scorePoints(pressureKPa, axleLoadT, wetness01, rateMult)
    local cp = SoilConstants and SoilConstants.COMPACTION
    if not cp then return 0 end

    rateMult = rateMult or 1.0
    if rateMult <= 0 then return 0 end
    wetness01 = clamp(wetness01 or 0, 0, 1)

    -- Surface term: contact pressure between FLOOR and REF maps linearly to 0..SURFACE_MAX.
    local surface = 0
    local gp = cp.GROUND_PRESSURE
    if gp and pressureKPa and pressureKPa > gp.FLOOR_KPA then
        local span = math.max(1e-6, gp.REF_KPA - gp.FLOOR_KPA)
        surface = gp.SURFACE_MAX * clamp((pressureKPa - gp.FLOOR_KPA) / span, 0, 1)
    end

    -- Subsoil term: axle load between FLOOR_T and REF_T maps linearly to 0..SUBSOIL_MAX.
    local subsoil = 0
    local al = cp.AXLE_LOAD
    if al and axleLoadT and axleLoadT > al.FLOOR_T then
        local span = math.max(1e-6, al.REF_T - al.FLOOR_T)
        subsoil = al.SUBSOIL_MAX * clamp((axleLoadT - al.FLOOR_T) / span, 0, 1)
    end

    -- Moisture multiplier scales the combined damage.
    local moist = 1.0
    local m = cp.MOISTURE
    if m then
        moist = m.DRY_MULT + (m.WET_MULT - m.DRY_MULT) * wetness01
    end

    return (surface + subsoil) * moist * rateMult
end

-- -------------------------------------------------------------------------------------
-- PURE: advance a decaying soil-wetness value (0..1).
--   Raining pins it to 1; otherwise it fades to 0 over MOISTURE.DECAY_HOURS.
-- -------------------------------------------------------------------------------------
function SoilCompactionModel.advanceWetness(prev, dtHours, isRaining)
    if isRaining then return 1.0 end
    prev = prev or 0
    local cp = SoilConstants and SoilConstants.COMPACTION
    local decayHours = (cp and cp.MOISTURE and cp.MOISTURE.DECAY_HOURS) or 12.0
    local dec = (dtHours or 0) / math.max(0.01, decayHours)
    return math.max(0, prev - dec)
end

-- -------------------------------------------------------------------------------------
-- VTP read: live effective contact pressure in kPa, or nil when VTP is not driving
-- this vehicle. Detection is by the registered getter + spec presence, never a guess.
-- -------------------------------------------------------------------------------------
function SoilCompactionModel.readVTPPressureKPa(vehicle)
    if vehicle == nil then return nil end
    if type(vehicle.vtpGetDashboardPressureBar) ~= "function" then return nil end
    if vehicle.spec_variableTirePressure == nil then return nil end
    local ok, bar = pcall(vehicle.vtpGetDashboardPressureBar, vehicle)
    if not ok or type(bar) ~= "number" or bar <= 0 then return nil end
    local gp = SoilConstants.COMPACTION.GROUND_PRESSURE
    return bar * gp.BAR_TO_KPA + gp.CONTACT_OFFSET_KPA
end

-- -------------------------------------------------------------------------------------
-- Geometry fallback: contact pressure ≈ (own weight) / (Σ tyre contact patch), where a
-- patch ≈ width × (radius × CONTACT_LENGTH_FACTOR). Reads live wheel geometry, so VTP's
-- physics-radius reduction is still partially reflected even on this path.
-- -------------------------------------------------------------------------------------
function SoilCompactionModel.readGeometryPressureKPa(vehicle, massT)
    if vehicle == nil or not massT or massT <= 0 then return nil end
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil then return nil end

    local gp = SoilConstants.COMPACTION.GROUND_PRESSURE
    local sumAreaM2 = 0
    for _, wheel in pairs(spec.wheels) do
        local phys = wheel.physics
        if phys then
            local width  = phys.wheelShapeWidth
            local radius = phys.radius
            if width and radius and width > 0 and radius > 0 then
                sumAreaM2 = sumAreaM2 + width * (radius * gp.CONTACT_LENGTH_FACTOR)
            end
        end
    end
    if sumAreaM2 <= 0 then return nil end

    local loadN = massT * 1000.0 * GRAVITY
    return (loadN / sumAreaM2) / 1000.0  -- Pa → kPa
end

-- Count distinct axles by bucketing wheels on their local Z position (handles duals,
-- where 4 wheels share one axle). Falls back to a wheel-count estimate.
local function countAxles(vehicle)
    local cp = SoilConstants.COMPACTION
    local perAxle = (cp.AXLE_LOAD and cp.AXLE_LOAD.WHEELS_PER_AXLE) or 2
    local spec = vehicle.spec_wheels
    if spec == nil or spec.wheels == nil then return 2 end

    local buckets, axleCount, wheelCount = {}, 0, 0
    for _, wheel in pairs(spec.wheels) do
        wheelCount = wheelCount + 1
        local phys = wheel.physics
        local z = phys and phys.positionZ
        if z then
            local key = math.floor(z * 2 + 0.5)  -- ~0.5 m buckets
            if not buckets[key] then
                buckets[key] = true
                axleCount = axleCount + 1
            end
        end
    end
    if axleCount > 0 then return axleCount end
    if wheelCount > 0 then return math.max(1, math.ceil(wheelCount / perAxle)) end
    return 2
end

local function readMass(vehicle, onlyThis)
    local ok, m = pcall(function() return vehicle:getTotalMass(onlyThis) end)
    if ok and type(m) == "number" and m > 0 then return m end
    return nil
end

-- -------------------------------------------------------------------------------------
-- Resolve (pressureKPa, axleLoadT, source) for a vehicle. Everything is self-consistent
-- to THIS vehicle (its own mass over its own wheels). Returns nil if mass is unreadable.
--   source ∈ "vtp" | "geometry"
-- -------------------------------------------------------------------------------------
function SoilCompactionModel.computeForVehicle(vehicle)
    if vehicle == nil then return nil end
    local massT = readMass(vehicle, true) or readMass(vehicle, false)
    if not massT then return nil end

    local source = "geometry"
    local pressureKPa = SoilCompactionModel.readVTPPressureKPa(vehicle)
    if pressureKPa then
        source = "vtp"
    else
        pressureKPa = SoilCompactionModel.readGeometryPressureKPa(vehicle, massT)
    end

    local axleLoadT = massT / countAxles(vehicle)
    return pressureKPa, axleLoadT, source
end

-- -------------------------------------------------------------------------------------
-- Convenience: full points value for a vehicle in one call (used by hooks).
-- Returns points (>=0) and the source string for logging.
-- -------------------------------------------------------------------------------------
function SoilCompactionModel.pointsForVehicle(vehicle, wetness01, rateMult)
    local pressureKPa, axleLoadT, source = SoilCompactionModel.computeForVehicle(vehicle)
    if pressureKPa == nil and axleLoadT == nil then return 0, source end
    return SoilCompactionModel.scorePoints(pressureKPa, axleLoadT, wetness01, rateMult), source
end

SoilLogger.info("SoilCompactionModel loaded")
