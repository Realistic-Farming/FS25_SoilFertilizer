-- SF-1057-compaction_radius_original_test.lua - the geometry fallback's tyre size (#1057).
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilCompactionModel.lua
--
-- The geometry fallback sums a contact patch per wheel and divides the vehicle's weight
-- by it. It read the live physics radius, so a mod that shrinks that radius at runtime
-- (Mud System Physics airing down or sinking, Use Your Tyres wear) shrank the patch and
-- RAISED Soil's pressure: the opposite of the model's own design, where aired-down tyres
-- compact less. It now reads radiusOriginal, the tyre's loaded size, which the engine
-- sets once from the wheel XML (WheelPhysics:loadFromXML, :63-68 at game 1.24.0.0:
-- radius, then radiusOriginal = radius), and falls back to the live radius only when
-- radiusOriginal is missing.
--
-- ENTRY POINT (R-18): every row goes through SoilCompactionModel.pointsForVehicle, the
-- function both production callers use (SoilFertilityManager.lua:1767, the per-vehicle
-- traffic pass; HookManager.lua:3525, the harvest pass), and through computeForVehicle
-- and its VTP check. readGeometryPressureKPa is never called directly. The fixture's
-- wheels carry radius, radiusOriginal and wheelShapeWidth the way loadFromXML leaves
-- them (radiusOriginal = radius), and a row then shrinks radius the way a mod would.
--
-- Expected values are derived by hand from the formula and the constants: a 12 t tractor,
-- two front wheels 0.5 m wide at 0.7 m radius, two rear wheels 0.6 m wide at 0.8 m, on
-- two axles. Patch = 2(0.5 x 0.7 x 0.35) + 2(0.6 x 0.8 x 0.35) = 0.581 m2. Pressure =
-- 12000 x 9.81 / 0.581 = 202616.18 Pa = 202.616179 kPa. Surface = 6 x (202.616179 - 80)
-- / 170 = 4.3276298; subsoil at 6 t per axle = 3 x (6 - 5) / 5 = 0.6; dry (x 0.6) =
-- 2.9565779 points.

local cp = SoilConstants.COMPACTION
local gp = cp.GROUND_PRESSURE
local M = SoilCompactionModel

local BASE_KPA = 202.61617900172
local BASE_POINTS_DRY = 2.9565779083

-- A wheel as WheelPhysics:loadFromXML leaves it: radiusOriginal = radius.
local function wheel(width, radius, z)
  return { physics = { wheelShapeWidth = width, radius = radius, radiusOriginal = radius, positionZ = z } }
end
local function tractor(wheels, extra)
  local v = { spec_wheels = { wheels = wheels } }
  function v:getTotalMass(onlyThis) return 12 end
  for k, x in pairs(extra or {}) do v[k] = x end
  return v
end
local function baseWheels()
  return { wheel(0.5, 0.7, 1.5), wheel(0.5, 0.7, 1.5), wheel(0.6, 0.8, -1.0), wheel(0.6, 0.8, -1.0) }
end
-- Shrink every wheel's live radius the way a mod would; radiusOriginal stays.
local function shrunk(factor)
  local ws = baseWheels()
  for _, w in ipairs(ws) do w.physics.radius = w.physics.radius * factor end
  return ws
end

-- ── Row 1: base game, radius == radiusOriginal ───────────
do
  local v = tractor(baseWheels())
  local kpa, axleT, src = M.computeForVehicle(v)
  T.near("1: base game pressure is the hand-derived 202.616 kPa", kpa, BASE_KPA, 1e-6)
  T.near("1: axle load is 6 t on two axles", axleT, 6.0, 1e-9)
  T.eq("1: source is geometry", src, "geometry")
  local pts, src2 = M.pointsForVehicle(v, 0)
  T.near("1: base game points on dry ground are the hand-derived 2.9566", pts, BASE_POINTS_DRY, 1e-6)
  T.eq("1: pointsForVehicle reports geometry", src2, "geometry")
  local wet = M.pointsForVehicle(v, 0.5)
  T.near("1: at half wetness the same terms scale by 1.05", wet, (4.3276298471 + 0.6) * 1.05, 1e-6)
end

-- ── Row 2: the live radius shrunk 6% and 32% (the reporter's two MSP cases) ──
for _, f in ipairs({ 0.94, 0.68 }) do
  local v = tractor(shrunk(f))
  local kpa = M.computeForVehicle(v)
  T.near("2: live radius x" .. f .. ": pressure equals the base game", kpa, BASE_KPA, 1e-6)
  T.near("2: live radius x" .. f .. ": points equal the base game", (M.pointsForVehicle(v, 0)), BASE_POINTS_DRY, 1e-6)
  -- What the live read gave, for the record: the patch shrank by f, the pressure rose by 1/f.
  T.ok("2: live radius x" .. f .. ": the old live-read pressure would have been higher", BASE_KPA / f > BASE_KPA + 1)
end

-- ── Row 3: no radiusOriginal (a mod-overridden wheel load) falls back to radius ──
do
  local ws = baseWheels()
  for _, w in ipairs(ws) do w.physics.radiusOriginal = nil end
  T.near("3: every wheel without radiusOriginal: the live radius stands in, pressure as base", M.computeForVehicle(tractor(ws)), BASE_KPA, 1e-6)
  local one = baseWheels()
  one[1].physics.radiusOriginal = nil
  T.near("3: one wheel without radiusOriginal still counts its patch", M.computeForVehicle(tractor(one)), BASE_KPA, 1e-6)
  T.near("3: and its points", (M.pointsForVehicle(tractor(one), 0)), BASE_POINTS_DRY, 1e-6)
end

-- ── Row 4: a mixed vehicle sums the loaded sizes ─────────
do
  local ws = baseWheels()
  ws[1].physics.radius = 0.7 * 0.68          -- one wheel aired down or sunk
  ws[2].physics.radiusOriginal = nil         -- one mod-overridden wheel, live radius 0.7
  T.near("4: one shrunk wheel, one fallback wheel, two normal: pressure as base", M.computeForVehicle(tractor(ws)), BASE_KPA, 1e-6)
  local big = baseWheels()
  big[3].physics.radiusOriginal = 1.0        -- a wheel whose loaded size is larger than its live radius
  local sum = 2 * (0.5 * 0.7 * 0.35) + (0.6 * 1.0 * 0.35) + (0.6 * 0.8 * 0.35)
  T.near("4: each wheel's patch uses its own loaded size", M.computeForVehicle(tractor(big)), 12000 * 9.81 / sum / 1000, 1e-6)
end

-- ── Row 5: a VTP vehicle takes the VTP read; the geometry is never read ──
do
  local reads = 0
  local function counted(w)
    local raw = w.physics
    w.physics = setmetatable({ positionZ = raw.positionZ }, { __index = function(_, k)
      if k == "radius" or k == "radiusOriginal" or k == "wheelShapeWidth" then reads = reads + 1 end
      return raw[k]
    end })
    return w
  end
  local ws = {}
  for _, w in ipairs(shrunk(0.68)) do ws[#ws + 1] = counted(w) end
  local v = tractor(ws, { spec_variableTirePressure = {} })
  function v:vtpGetDashboardPressureBar() return 1.0 end
  local kpa, _, src = M.computeForVehicle(v)
  T.eq("5: source is vtp", src, "vtp")
  T.near("5: VTP pressure is bar x 100 + the contact offset", kpa, 1.0 * gp.BAR_TO_KPA + gp.CONTACT_OFFSET_KPA, 1e-9)
  local pts, src2 = M.pointsForVehicle(v, 0)
  T.eq("5: pointsForVehicle reports vtp", src2, "vtp")
  T.near("5: VTP points are the pure score of 110 kPa at 6 t/axle", pts, M.scorePoints(110, 6.0, 0, 1.0), 1e-9)
  T.eq("5: the geometry (radius, radiusOriginal, width) was never read", reads, 0)
  local plain = tractor(baseWheels(), { spec_variableTirePressure = {} })
  function plain:vtpGetDashboardPressureBar() return 1.0 end
  T.near("5: the shrunk and the unshrunk VTP vehicle score the same", pts, (M.pointsForVehicle(plain, 0)), 1e-12)
end

-- ── Row 6: the zero, negative and nil guards on width and radius ──
do
  local function withBad(mutator)
    local ws = baseWheels()
    mutator(ws[1].physics)
    return M.computeForVehicle(tractor(ws))
  end
  -- Base minus wheel 1's patch: the bad wheel is skipped, the rest still count.
  local lessOne = 12000 * 9.81 / (0.581 - 0.5 * 0.7 * 0.35) / 1000
  T.near("6: width 0 skips the wheel", withBad(function(p) p.wheelShapeWidth = 0 end), lessOne, 1e-6)
  T.near("6: negative width skips the wheel", withBad(function(p) p.wheelShapeWidth = -0.5 end), lessOne, 1e-6)
  T.near("6: nil width skips the wheel", withBad(function(p) p.wheelShapeWidth = nil end), lessOne, 1e-6)
  T.near("6: radiusOriginal 0 skips the wheel", withBad(function(p) p.radiusOriginal = 0 end), lessOne, 1e-6)
  T.near("6: negative radiusOriginal skips the wheel", withBad(function(p) p.radiusOriginal = -0.7 end), lessOne, 1e-6)
  T.near("6: nil radiusOriginal and radius 0 skips the wheel", withBad(function(p) p.radiusOriginal = nil; p.radius = 0 end), lessOne, 1e-6)
  T.near("6: nil radiusOriginal and nil radius skips the wheel", withBad(function(p) p.radiusOriginal = nil; p.radius = nil end), lessOne, 1e-6)
  local none = baseWheels()
  for _, w in ipairs(none) do w.physics.wheelShapeWidth = 0 end
  local kpa, axleT = M.computeForVehicle(tractor(none))
  T.eq("6: no usable wheel gives no pressure", kpa, nil)
  T.near("6: the subsoil term still stands", axleT, 6.0, 1e-9)
  T.near("6: and the points are the subsoil term only", (M.pointsForVehicle(tractor(none), 0)), 0.6 * 0.6, 1e-9)
  T.eq("6: a vehicle with no wheel spec gives no pressure", (M.computeForVehicle(tractor(nil))), nil)
end
