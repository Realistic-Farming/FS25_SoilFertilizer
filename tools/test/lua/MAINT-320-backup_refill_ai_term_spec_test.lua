-- MAINT-320-backup_refill_ai_term_spec_test.lua: MAINTENANCE row 320, the backup refill's
-- AI test has a row that can fail.
--
-- With helperBuyFertilizer on, the sprayer hook's BUY-mode backup refill (installSprayerAreaHook,
-- issue #125) puts the litres a pass just used back into the tank and charges the farm, but only for
-- a hired worker: it tests the vehicle's AI state, then Courseplay's flags, and skips a vehicle a
-- player is in. #1098 took one term out of that test, `spec_aiVehicle.isActive`: it is true for an
-- unoccupied or parked implement too, so with it the refill charged a farm for a drain no worker
-- caused. The term was removed from three AI tests (#1098, #1137); this block had no row of its
-- own. Putting the term back at this block failed no row of
-- SF-1098-helperbuy_player_spec_test.lua, because its group 13 drives an empty pass that never
-- reaches the refill.
--
-- ENTRY-POINT BAR: every pass runs through the real installSprayerAreaHook into a real soil system
-- on the row-166 world (a real scanFields field, a real settings object, the field's own coverage).
-- The fixture supplies the world only: a priced custom product (the price map and the catalogue
-- membership the refill reads), the mission's helper-buy setting, the farm's money as a recorded
-- addMoney, and the AI state of the vehicle, set only as each case asks. One 10 L tick on 1.0 ha.
--
--   A  a hired worker (a job, getIsAIActive true, nobody entered): the tank gets its 10 L back and
--      the farm is charged 10 x the price. This is also the proof the block is reached, so B and C
--      below are not passing for want of getting there.
--   B  the case the row asks for: an unoccupied implement whose ONLY flag is
--      `spec_aiVehicle = { isActive = true }` (no job, no Courseplay, nobody entered): no charge
--      and the tank is not touched.
--   C  the same hired worker with the helper-buy setting off: no charge, no refill.
--
-- Targeted mutations (mutate_maint320.py): restore the removed term at this block (B fails); treat
-- every vehicle as AI (B fails); make the refill never happen (A fails); ignore the setting (C fails).
--
-- What this bar does NOT prove: the game's own AI state flags on a real vehicle (the engine's
-- getIsAIActive is modelled as the repo's other helper-buy benches model it), or the charge going
-- through the game's money pipeline.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group
local function near(a, b) return math.abs(a - b) < 1e-9 end

local PRICE  = 2.0          -- per litre
local LITERS = 10
local FARM   = 1

local savedMission = {
  missionInfo = g_currentMission.missionInfo, addMoney = g_currentMission.addMoney, time = g_currentMission.time,
}
local savedMoneyType = MoneyType
local money   -- { calls, spent, farm }

--- One world: the real hook on the row-166 world, the product priced and a custom product, the
--- helper-buy setting as asked, and the vehicle's AI state as the case asks.
local function refillWorld(opts)
  opts = opts or {}
  local w = PSW.new({ product = "FERTILIZER", noVww = true, areaHa = 1.0 })
  local idx = w.product.index
  w.hookMgr:ensureProductTables()
  w.hookMgr.customProductIndices[idx] = true
  w.hookMgr.customFillTypePrices = { [idx] = PRICE }

  money = { calls = 0, spent = 0, farm = nil }
  MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1 }
  g_currentMission.time = 1000
  g_currentMission.missionInfo = { helperBuyFertilizer = (opts.buy ~= false), helperSlurrySource = 1, helperManureSource = 1 }
  g_currentMission.addMoney = function(_, amount, farmId, _moneyType)
    money.calls = money.calls + 1
    money.spent = money.spent + amount
    money.farm = farmId
  end

  local v = w.vehicle
  v.ownerFarmId = FARM
  -- The engine's AI state, as the repo's other helper-buy benches model it: a vehicle is AI-active
  -- through its job; nobody is in it.
  v.getIsAIActive = function(self) return self.spec_aiJobVehicle ~= nil and self.spec_aiJobVehicle.job ~= nil end
  v.getIsEntered = function() return false end
  if opts.job then v.spec_aiJobVehicle = { job = {} } end
  if opts.aiVehicleActive then v.spec_aiVehicle = { isActive = true } end
  return w
end

local function runPass(opts)
  local w = refillWorld(opts)
  local before = w.units[1].fillLevel
  w:tick(LITERS, w:cells(1, 1))
  return w, before, w.units[1].fillLevel
end

group("A hired worker", function()
  local w, before, after = runPass({ job = true })
  T.ok("A0 [reached: the pass was counted through the real hook]", near(w:field().sessionCoverageHa or 0, LITERS / PSW.ratePerHa("FERTILIZER")))
  T.eq("A1 NAMED: a hired worker's pass is charged once", money.calls, 1)
  T.ok("A2 for the litres it used at the price, on the vehicle's farm", near(money.spent, -(LITERS * PRICE)) and money.farm == FARM)
  T.eq("A3 and the tank gets those litres back", after - before, LITERS)
end)

group("B unoccupied implement", function()
  local w, before, after = runPass({ aiVehicleActive = true })
  T.ok("B0 [reached: the pass was counted through the real hook]", near(w:field().sessionCoverageHa or 0, LITERS / PSW.ratePerHa("FERTILIZER")))
  T.ok("B1 [reached: the vehicle carries only the unsupported flag]",
       w.vehicle.spec_aiVehicle ~= nil and w.vehicle.spec_aiVehicle.isActive == true
       and w.vehicle.spec_aiJobVehicle == nil and w.vehicle.cp == nil and w.vehicle.spec_cpAIWorker == nil)
  T.eq("B2 NAMED: an unoccupied implement with only spec_aiVehicle.isActive is not charged", money.calls, 0)
  T.eq("B3 and no money moved", money.spent, 0)
  T.eq("B4 and the tank is not given litres back", after - before, 0)
end)

group("C setting off", function()
  local w, before, after = runPass({ job = true, buy = false })
  T.ok("C0 [reached: the pass was counted through the real hook]", near(w:field().sessionCoverageHa or 0, LITERS / PSW.ratePerHa("FERTILIZER")))
  T.eq("C1 with helperBuyFertilizer off a hired worker is not charged", money.calls, 0)
  T.eq("C2 and the tank is not given litres back", after - before, 0)
end)

PSW.restore()
g_currentMission.missionInfo, g_currentMission.addMoney, g_currentMission.time =
  savedMission.missionInfo, savedMission.addMoney, savedMission.time
MoneyType = savedMoneyType
