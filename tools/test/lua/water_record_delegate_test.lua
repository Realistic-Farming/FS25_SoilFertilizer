-- water_record_delegate_test.lua - SF-49 the Water Record published at the manager.
--
-- SeasonalCropStress's caught-up-hour (SCS-037 round 2) reconstructs the rain
-- switch across a skipped day from SoilFertilizer's Water Record. The record
-- lives three internal fields deep, so the read is delegated onto the manager,
-- the one handle that crosses the mod boundary. This pins that delegate.
--
-- The delegate is NEUTRAL, not a claim: nil means "we do not know", never
-- "it was dry". A closed ground_material gate, a missing or unarmed wetness
-- subsystem, a throwing read, and an empty record all return nil.
--!load: src/utils/Logger.lua, src/maps/SoilValueMaps.lua, src/MaterialDown.lua, src/MaterialWetness.lua, src/ReleaseGate.lua, src/SoilFertilityManager.lua

g_server = g_server or {}

-- A lightweight manager carrying the REAL delegate method off the class table,
-- plus a fake soilSystem holding a real MaterialWetness.
local function makeManager(mw)
  local mgr = { soilSystem = { materialWetness = mw } }
  mgr.getWaterDaysInLast = SoilFertilityManager.getWaterDaysInLast
  return mgr
end

local function makeArmedWetness()
  local mw = MaterialWetness.new()
  mw.armed, mw.stoodDown = true, false
  mw.appliedThroughDay = 10
  mw:recordDay(10, true,  "rain",  false)
  mw:recordDay(9,  false, "none",  false)
  return mw
end

-- ── 1. A real record answers (count, known) ───────────────
local mgr = makeManager(makeArmedWetness())
local count, known = mgr:getWaterDaysInLast(6)
T.eq("wet days forwarded", count, 1)
T.eq("known days forwarded", known, 2)

-- ── 2. All-dry-but-known is a claim, not a nil ────────────
-- The record reaches back and says every day was dry. That is an answer, and
-- only known == 0 is the truth "we do not know".
local mwDry = MaterialWetness.new()
mwDry.armed, mwDry.stoodDown = true, false
mwDry.appliedThroughDay = 10
mwDry:recordDay(10, false, "none", false)
local mgrDry = makeManager(mwDry)
count, known = mgrDry:getWaterDaysInLast(6)
T.eq("all dry returns zero wet", count, 0)
T.eq("all dry is still known", known, 1)

-- ── 3. known == 0 is nil, not zero ────────────────────────
-- An empty record does not claim it was dry. It returns nil so the consumer
-- falls back to its honest approximation instead of trusting a zero.
local mgrEmpty = makeManager(MaterialWetness.new())
T.eq("empty record is nil", mgrEmpty:getWaterDaysInLast(6), nil)

-- ── 4. Absent subsystem is nil, never a throw ─────────────
local mgrNoMw = makeManager(nil)
T.eq("no wetness subsystem is nil", mgrNoMw:getWaterDaysInLast(6), nil)
local mgrNoSoil = { soilSystem = nil }
mgrNoSoil.getWaterDaysInLast = SoilFertilityManager.getWaterDaysInLast
T.eq("no soilSystem is nil", mgrNoSoil:getWaterDaysInLast(6), nil)

-- ── 5. Unarmed subsystem is nil ───────────────────────────
local mwStand = makeArmedWetness()
mwStand.stoodDown = true
local mgrStand = makeManager(mwStand)
T.eq("stood-down wetness is nil", mgrStand:getWaterDaysInLast(6), nil)

-- ── 6. A throwing read is swallowed into nil ──────────────
local mwAngry = makeArmedWetness()
mwAngry.waterDaysInLast = function() error("boom") end
local mgrAngry = makeManager(mwAngry)
T.eq("throwing read is nil", mgrAngry:getWaterDaysInLast(6), nil)

-- ── 7. The ground_material gate closed is nil ─────────────
-- ground_material is in the EXPERIMENTAL set, so a settings object that refuses
-- experimental systems closes it. The record exists; the gate still wins.
local savedSfm = _G.g_SoilFertilityManager
_G.g_SoilFertilityManager = {
  settings = { allowsExperimentalSystems = function() return false end },
}
local mgrGated = makeManager(makeArmedWetness())
T.eq("gate closed is nil even with a record", mgrGated:getWaterDaysInLast(6), nil)
_G.g_SoilFertilityManager = savedSfm

-- ── 8. ThroughDay is forwarded untouched ──────────────────
-- The plumbing is additive and nil-defaulted: the explicit cursor reaches the
-- record as-is, exactly what SCS-037 round 2 will call with.
local mgrFwd = makeManager(makeArmedWetness())
count, known = mgrFwd:getWaterDaysInLast(6, 10)
T.eq("explicit throughDay forwarded", count, 1)
T.eq("explicit throughDay known", known, 2)

T.summary()
