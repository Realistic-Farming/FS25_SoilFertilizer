-- MAINT-320-backup_refill_ai_term_spec_test.lua: MAINTENANCE row 320, the backup refill's
-- AI test has a row that can fail.
--
-- With helperBuyFertilizer on, the sprayer hook's BUY-mode backup refill (installSprayerAreaHook,
-- issue #125) puts the litres a pass just used back into the tank and charges the farm, but only for
-- a hired worker: it tests the vehicle's AI state, then Courseplay's flags, and skips a vehicle a
-- player is in. #1098 took one term out of that test, `spec_aiVehicle.isActive`: it is true for an
-- unoccupied or parked implement too, so with it the refill could charge a farm for a drain no worker
-- caused (the `not isEntered` guard below the test blocked the one case seen, which is not what makes
-- the test valid). The term was removed from three AI tests (#1098, #1137); this block had no row of
-- its own. Putting the term back at this block failed no row of
-- SF-1098-helperbuy_player_spec_test.lua, because its group 13 drives an empty pass that never
-- reaches the refill.
--
-- ENTRY-POINT BAR: every pass runs through the real installSprayerAreaHook into a real soil system
-- on the row-166 world (a real scanFields field, a real settings object, the field's own coverage).
-- The product is UAN32, a custom product, and the two tables the refill reads about it, the identity
-- catalogue (customProductIndices) and the price map (customFillTypePrices), are filled by the real
-- HookManager:registerCustomSprayTypes (the production load path that rebuilds both; the purchase
-- refill hook rebuilds the price map too), never written by hand. Base-game FERTILIZER is not used:
-- production puts it in neither table, so a FERTILIZER pass stops at the refill's gate and never
-- reaches the AI test.
--
-- What is MODELLED (the engine, not Soil):
--   * the fill type manager's getFillTypeIndexByName, as FillTypeManager.lua:305 has it (upper-cases
--     the name, returns the index or nil), over the world's fill types plus UAN32;
--   * the spray type manager's addSprayType and its lookups, as SprayTypeManager.lua:60-142 keep
--     them (a spray type keyed by its fill type's index, litersPerSecond as registered), seeded with
--     the base map's LIQUIDFERTILIZER, FERTILIZER, LIME and FUNGICIDE entries registration borrows
--     its ground type from;
--   * the mission's helper-buy setting, the farm's money as a recorded addMoney, and the AI state of
--     the vehicle (set only as each case asks);
--   * the native Sprayer.onEndWorkAreaProcessing, which does nothing in this world (MAINT-166 world,
--     line 261), so the tank is never drained and A3 below measures +10 L on an undrained tank, not a
--     restoration of a drained one. The block's own writes are what move the level.
-- One 10 L tick on 1.0 ha.
--
-- Values written here and not read from the code: UAN32's price 1.60 per litre (the fallback table
-- in HookManager.lua), its rate 60.8 L/ha (SoilConstants SPRAYER_RATE.BASE_RATES.UAN32), the product's
-- fill type index 78 (an index the world does not already use). Hired worker: 10 L x 1.60 = 16 charged
-- (A2 expects -16 on farm 1), +10 L in the tank (A3), coverage 10 / 60.8 ha (A0, B0, C0).
--
--   R  the registration: before it, UAN32 is in neither table; after the real registerCustomSprayTypes
--      it is in the catalogue and priced 1.60, its spray type carries the registered rate, and base
--      FERTILIZER is in neither (the reason this bar does not use it).
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
-- Removing the registration (registerCustomSprayTypes returning at once, or no longer calling the
-- catalogue or price rebuild) fails R and A.
--
-- What this bar does NOT prove: the game's own AI state flags on a real vehicle (the engine's
-- getIsAIActive is modelled as the repo's other helper-buy benches model it), the charge going
-- through the game's money pipeline, or the engine's real fill type list resolving UAN32 (the world
-- supplies it).
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group
local function near(a, b) return math.abs(a - b) < 1e-9 end

local PRODUCT = "UAN32"
local PRICE   = 1.60          -- per litre, the fallback table's figure for UAN32
local RATE    = 60.8          -- litres per hectare, UAN32's registered rate
local LITERS  = 10
local FARM    = 1
local UAN_INDEX = 78

local savedMission = {
  missionInfo = g_currentMission.missionInfo, addMoney = g_currentMission.addMoney, time = g_currentMission.time,
}
local savedMoneyType = MoneyType
local savedStm = g_sprayTypeManager
local money   -- { calls, spent, farm }

--- The map's spray type manager as the engine keeps it (SprayTypeManager.lua:60-142), holding the
--- base types registration borrows a ground type from. Spray types added through addSprayType are
--- keyed by their fill type's index, like fillTypeIndexToSprayType.
local function newSprayTypeManager()
  local m = { byName = {}, byFillType = {}, count = 0 }
  m.byName.LIQUIDFERTILIZER = { name = "LIQUIDFERTILIZER", litersPerSecond = 0.0081, sprayGroundType = 1 }
  m.byName.FERTILIZER       = { name = "FERTILIZER",       litersPerSecond = 0.0060, sprayGroundType = 1 }
  m.byName.LIME             = { name = "LIME",             litersPerSecond = 0.0060, sprayGroundType = 2 }
  m.byName.FUNGICIDE        = { name = "FUNGICIDE",        litersPerSecond = 0.0026, sprayGroundType = 3 }
  function m:addSprayType(name, litersPerSecond, _typeName, sprayGroundType, _isBaseType)
    local ft = g_fillTypeManager:getFillTypeByName(string.upper(name))
    if ft == nil then return nil end
    local st = self.byName[ft.name]
    if st == nil then
      self.count = self.count + 1
      st = { name = ft.name, index = self.count, litersPerSecond = litersPerSecond or 0 }
      self.byName[ft.name] = st
      self.byFillType[ft.index] = st
    end
    st.litersPerSecond = litersPerSecond or st.litersPerSecond
    st.sprayGroundType = sprayGroundType or st.sprayGroundType or 1
    return st
  end
  function m:getSprayTypeByName(name)
    if name == nil then return nil end
    return self.byName[string.upper(name)]
  end
  function m:getSprayTypeByFillTypeIndex(index)
    if index == nil then return nil end
    return self.byFillType[index]
  end
  return m
end

--- One world: the real hook on the row-166 world, the real registration run (it fills the catalogue
--- and the price map), the helper-buy setting as asked, and the vehicle's AI state as the case asks.
--- `w.before` records what the two tables held before registration.
local function refillWorld(opts)
  opts = opts or {}
  PSW.FT[PRODUCT] = { name = PRODUCT, index = UAN_INDEX, massPerLiter = 0.001 }
  g_sprayTypeManager = newSprayTypeManager()
  local w = PSW.new({ product = PRODUCT, noVww = true, areaHa = 1.0 })
  local idx = w.product.index

  -- The engine's FillTypeManager:getFillTypeIndexByName (FillTypeManager.lua:305): the name is
  -- upper-cased; an unknown name gives nil.
  local nameToIndex = {}
  for _, ft in pairs(PSW.FT) do nameToIndex[ft.name] = ft.index end
  g_fillTypeManager.getFillTypeIndexByName = function(_, name)
    if name then name = string.upper(name) end
    return nameToIndex[name]
  end

  local hm = w.hookMgr
  w.before = { catalogued = hm:isCustomProduct(idx), price = hm.customFillTypePrices and hm.customFillTypePrices[idx] }
  hm:registerCustomSprayTypes()

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

group("R registration", function()
  local w = refillWorld({ job = true })
  local hm, idx = w.hookMgr, w.product.index
  T.ok("R1 [before registration UAN32 is in neither table]", w.before.catalogued == false and w.before.price == nil)
  T.ok("R2 NAMED: registerCustomSprayTypes put UAN32 in the identity catalogue", hm:isCustomProduct(idx) == true)
  T.ok("R3 NAMED: registerCustomSprayTypes priced UAN32 at 1.60 per litre",
       type(hm.customFillTypePrices) == "table" and hm.customFillTypePrices[idx] ~= nil and near(hm.customFillTypePrices[idx], PRICE))
  local st = g_sprayTypeManager:getSprayTypeByFillTypeIndex(idx)
  T.ok("R4 its spray type is the registered one, 60.8 L/ha", st ~= nil and near(st.litersPerSecond * 36000, RATE))
  local ferti = PSW.FT.FERTILIZER.index
  T.ok("R5 base FERTILIZER is in neither table (why this bar is not run on it)",
       hm:isCustomProduct(ferti) == false and (hm.customFillTypePrices or {})[ferti] == nil)
end)

group("A hired worker", function()
  local w, before, after = runPass({ job = true })
  T.ok("A0 [reached: the pass was counted through the real hook]", near(w:field().sessionCoverageHa or 0, LITERS / RATE))
  T.eq("A1 NAMED: a hired worker's pass is charged once", money.calls, 1)
  T.ok("A2 for the litres it used at the price, on the vehicle's farm", near(money.spent, -(LITERS * PRICE)) and money.farm == FARM)
  T.eq("A3 and the tank gets those litres back", after - before, LITERS)
end)

group("B unoccupied implement", function()
  local w, before, after = runPass({ aiVehicleActive = true })
  T.ok("B0 [reached: the pass was counted through the real hook]", near(w:field().sessionCoverageHa or 0, LITERS / RATE))
  T.ok("B1 [reached: the vehicle carries only the unsupported flag]",
       w.vehicle.spec_aiVehicle ~= nil and w.vehicle.spec_aiVehicle.isActive == true
       and w.vehicle.spec_aiJobVehicle == nil and w.vehicle.cp == nil and w.vehicle.spec_cpAIWorker == nil)
  T.eq("B2 NAMED: an unoccupied implement with only spec_aiVehicle.isActive is not charged", money.calls, 0)
  T.eq("B3 and no money moved", money.spent, 0)
  T.eq("B4 and the tank is not given litres back", after - before, 0)
end)

group("C setting off", function()
  local w, before, after = runPass({ job = true, buy = false })
  T.ok("C0 [reached: the pass was counted through the real hook]", near(w:field().sessionCoverageHa or 0, LITERS / RATE))
  T.eq("C1 with helperBuyFertilizer off a hired worker is not charged", money.calls, 0)
  T.eq("C2 and the tank is not given litres back", after - before, 0)
end)

PSW.restore()
PSW.FT[PRODUCT] = nil
g_sprayTypeManager = savedStm
g_currentMission.missionInfo, g_currentMission.addMoney, g_currentMission.time =
  savedMission.missionInfo, savedMission.addMoney, savedMission.time
MoneyType = savedMoneyType
