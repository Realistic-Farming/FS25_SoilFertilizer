-- SF-1154-credit_without_native_drain_entry_point_test.lua: issue #1154, a sprayer's tank barely
-- drains while the soil is credited as if the product had been applied.
--
-- THE DEFECT. The game drains the spray vehicle only when the sprayer's workAreaParameters.isActive is
-- true (Sprayer.lua onEndWorkAreaProcessing). Soil's area hook credits the soil on every tick it sees
-- product used, active or not (it must not gate on isActive: #764). A tick on which the game says "not
-- active" therefore credited nutrients for product that never left the tank. One reporter's debug log
-- counted 1259 credited ticks against 38 native drains over one 45 s pass: about 31 L credited, about
-- 1 L drained (game 1.25.1.0).
--
-- THE FIX. The litres the credit actually applied are counted where the credit is made (applySingle),
-- handed on after it, and taken out of the spray vehicle by HookManager.drainCreditedLitres, called from
-- the outermost append of Sprayer.onEndWorkAreaProcessing (after native and every other hook), through
-- the same call native makes, only when native did not make it.
--
-- ENTRY-POINT BAR. Every pass runs through Sprayer.onEndWorkAreaProcessing as the engine calls it:
-- the engine's own end-of-work-area drain (modelled, first in the chain: it drains wap.usage from
-- wap.sprayVehicle only when wap.isActive), then the real installSprayerAreaHook into the real
-- SoilFertilitySystem on the row-166 world, then the real installDrainTokenHook as the outermost
-- wrapper, in production's order. The tank is real (a unit whose level moves with every drain the
-- vehicle receives). The credit is measured at the soil's own entry (onFertilizerApplied and
-- onHerbicideAppliedDirect), so "credited" is never derived from the code under test. The invariant
-- every row states: the tank gives up exactly the litres the soil was credited.
--
--   A  an active tick: the game drains once, Soil adds no second drain
--   B  NAMED: a tick the game counts as not active drains what was credited
--   C  the same on a VWW rig (the credit is per section)
--   D  a run of mixed ticks (the reporter's shape: mostly inactive): the totals match
--   E  external fill (buy mode: no spray vehicle) and no tank unit: nothing drained
--   F  off a field: nothing credited, nothing drained; and a mark never outlives its tick
--   H  a crop-protection product (the direct route, no fertilizer profile)
--   I  the drain names the arguments native names: the tank's own fill type, the unload info of the
--      active spray type (or the default index)
--   U  UNIT rows, not entry-point: the guards the entry path cannot reach (a client, a mark that is
--      not a usable number)
--
-- Modelled, not real: the engine's own onEndWorkAreaProcessing (the 1.24.0.0 and 1.25.1.0 bodies are the
-- same), the vehicle and its tank, the map. Not covered: SF-73 target doses (the mark is never set for
-- one), the F196 FillUnit layer, a game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-166-protection_sprayer_world.lua

local group = PSW.group
local function near(a, b) return math.abs(a - b) < 1e-9 end

-- One sprayer world with a real tank, the engine's native drain first in the chain and the drain-token
-- hook installed last, as installAll does. opts.product, opts.vww, opts.sprayType.
local function newWorld(opts)
  opts = opts or {}
  local w = PSW.new({ product = opts.product or "LIQUIDFERTILIZER", areaHa = 1.0, noVww = opts.vww ~= true })
  local v = w.vehicle
  w.calls = {}                              -- every addFillUnitFillLevel the vehicle received
  w.start = w.units[1].fillLevel
  v.addFillUnitFillLevel = function(_, farmId, fuIdx, delta, fillType, _toolType, unloadInfo)
    w.calls[#w.calls + 1] = { farmId = farmId, fuIdx = fuIdx, delta = delta, fillType = fillType, unloadInfo = unloadInfo }
    local unit = w.units[fuIdx]
    if unit ~= nil then unit.fillLevel = unit.fillLevel + delta end
    return delta
  end
  v.spec_sprayer.unloadInfoIndex = 3
  v.getFillVolumeUnloadInfo = function(_, idx) return { index = idx } end
  v.getActiveSprayType = function() return opts.sprayType end

  -- The credit, measured at the soil's own entry points.
  w.credited = 0
  local sys = w.sys
  local realFert, realHerb = sys.onFertilizerApplied, sys.onHerbicideAppliedDirect
  sys.onFertilizerApplied = function(self, fId, ftIdx, litres, ...)
    local r = realFert(self, fId, ftIdx, litres, ...)
    if r == true then w.credited = w.credited + litres end
    return r
  end
  sys.onHerbicideAppliedDirect = function(self, fId, eff, litres, ...)
    w.credited = w.credited + litres
    if realHerb ~= nil then return realHerb(self, fId, eff, litres, ...) end
  end

  -- The engine's own Sprayer:onEndWorkAreaProcessing, first in the chain (Sprayer.lua: the same body in
  -- 1.24.0.0 and 1.25.1.0): it drains the spray vehicle ONLY when wap.isActive is true.
  local chain = Sprayer.onEndWorkAreaProcessing
  Sprayer.onEndWorkAreaProcessing = function(self, dt, ...)
    local wap = self.spec_sprayer.workAreaParameters
    if self.isServer and wap.isActive then
      local sprayVehicle = wap.sprayVehicle
      if sprayVehicle ~= nil then
        local unloadInfo = self:getFillVolumeUnloadInfo(self.spec_sprayer.unloadInfoIndex)
        sprayVehicle:addFillUnitFillLevel(self:getOwnerFarmId(), wap.sprayVehicleFillUnitIndex, -wap.usage,
          wap.sprayFillType, ToolType.UNDEFINED, unloadInfo)
      end
    end
    return chain(self, dt, ...)
  end
  -- Production installs the drain token last, so it is the outermost wrapper.
  w.hookMgr:installDrainTokenHook()

  function w:drop() return self.start - self.units[1].fillLevel end
  function w:setActive(active) self.vehicle.spec_sprayer.workAreaParameters.isActive = active end
  return w
end

group("A an active tick", function()
  local w = newWorld()
  w:setActive(true)
  w:tick(10, w:cells(1, 1))
  T.ok("A0 [reached] Soil credited 10 L on a tick the game counted as active", near(w.credited, 10))
  T.eq("A1 the game drained those 10 L once, and Soil added no second drain", w:drop() .. "/" .. #w.calls, "10/1")
end)

group("B a tick the game counts as not active", function()
  local w = newWorld()
  w:setActive(false)
  w:tick(10, w:cells(1, 1))
  T.ok("B0 [reached] Soil credited 10 L on a tick the game counted as not active", near(w.credited, 10))
  T.eq("B1 NAMED [entry point]: and the tank gave up exactly those 10 L", w:drop(), 10)
  T.eq("B2 through one drain call, which is Soil's", #w.calls, 1)
  T.eq("B3 the mark does not outlive its tick", w.vehicle._sfCreditedLitersThisTick, nil)
end)

group("C a VWW rig", function()
  local w = newWorld({ vww = true })
  w:setActive(false)
  w:tick(10, w:cells(1, 1))
  T.ok("C0 [reached] the sections credited litres on a tick the game counted as not active", w.credited > 0)
  T.ok("C1 the tank gave up what the sections credited", near(w:drop(), w.credited))
end)

group("D a run of mixed ticks", function()
  local w = newWorld()
  local activeTicks = 0
  for i = 1, 40 do
    local active = (i % 10 == 0)               -- the reporter's shape: mostly not active
    if active then activeTicks = activeTicks + 1 end
    w:setActive(active)
    w:tick(1, w:cells(i, i))
  end
  T.ok("D0 [reached] 40 ticks credited 40 L, only 4 of them counted active by the game", near(w.credited, 40) and activeTicks == 4)
  T.ok("D1 NAMED: the tank gave up exactly the 40 L credited, not the 4 L the game alone would have drained", near(w:drop(), w.credited))
end)

group("E nothing to drain", function()
  local w = newWorld()
  w:setActive(false)
  local wap = w.vehicle.spec_sprayer.workAreaParameters
  wap.sprayVehicle, wap.sprayVehicleFillUnitIndex = nil, nil     -- external fill, as buy mode leaves it
  w:tick(10, w:cells(1, 1))
  T.ok("E0 [reached] Soil credited on a tick with no spray vehicle", w.credited > 0)
  T.eq("E1 external fill: the tank is not drained a second way", w:drop() .. "/" .. #w.calls, "0/0")
  T.eq("E1b and the drain did not even try: nothing raised inside it, so no error was logged", w.hookMgr._sf1154DrainErrLogged, nil)

  local w2 = newWorld()
  w2:setActive(false)
  w2.vehicle.spec_sprayer.workAreaParameters.sprayVehicleFillUnitIndex = nil
  w2:tick(10, w2:cells(1, 1))
  T.ok("E2 [reached] credited with a spray vehicle but no fill unit", w2.credited > 0)
  T.eq("E3 no fill unit: no drain is attempted", #w2.calls, 0)

  local w3 = newWorld()
  w3:setActive(false)
  w3.vehicle.spec_sprayer.workAreaParameters.sprayVehicle = nil     -- a fill unit index with no vehicle behind it
  w3:tick(10, w3:cells(1, 1))
  T.eq("E4 no spray vehicle but a fill unit index: no drain is attempted and nothing raised inside the drain",
    #w3.calls .. "/" .. tostring(w3.hookMgr._sf1154DrainErrLogged), "0/nil")
end)

group("F off a field, and a mark never outlives its tick", function()
  local w = newWorld()
  w:setActive(false)
  w:tick(10, w:cells(1, 1))
  local after1 = w:drop()
  w.hookMgr.getFieldIdAtWorldPosition = function() return nil end   -- the next tick is off the field
  w:tick(10, w:cells(2, 2))
  T.eq("F0 [reached] the first tick drained its 10 L", after1, 10)
  T.eq("F1 a tick with no field credits nothing", w.credited, 10)
  T.eq("F2 and drains nothing: the first tick's mark is gone", w:drop() .. "/" .. #w.calls, "10/1")
end)

group("H a crop-protection product", function()
  local w = newWorld({ product = "HERBICIDE" })
  w:setActive(false)
  w:tick(10, w:cells(1, 1))
  T.ok("H0 [reached] Soil applied the herbicide directly on a tick the game counted as not active", w.credited > 0)
  T.ok("H1 the tank gave up what was applied", near(w:drop(), w.credited))
end)

group("I the drain names what native names", function()
  local w = newWorld()
  w:setActive(false)
  -- wap.sprayFillType can name another type than the tank holds (a multi-tank machine, #708); the
  -- removal names the unit's own type.
  w.vehicle.spec_sprayer.workAreaParameters.sprayFillType = PSW.FT.HERBICIDE.index
  w:tick(10, w:cells(1, 1))
  local call = w.calls[#w.calls]
  T.eq("I1 the drain names the tank's own fill type, not wap.sprayFillType", call and call.fillType, PSW.FT.LIQUIDFERTILIZER.index)
  T.eq("I2 as the farm that owns the sprayer, on its fill unit, as a removal",
    call and (call.farmId .. "/" .. call.fuIdx .. "/" .. tostring(near(call.delta, -10))), "1/1/true")
  T.eq("I3 with the unload info of the default index when no spray type is active", call and call.unloadInfo and call.unloadInfo.index, 3)

  local w2 = newWorld({ sprayType = { unloadInfoIndex = 5 } })
  w2:setActive(false)
  w2:tick(10, w2:cells(1, 1))
  local call2 = w2.calls[#w2.calls]
  T.eq("I4 and with the unload info of the active spray type when there is one", call2 and call2.unloadInfo and call2.unloadInfo.index, 5)
end)

group("U guards the entry path cannot reach (UNIT rows, not entry-point)", function()
  local function sprayer(mark, opts)
    opts = opts or {}
    local tank, calls = { fillLevel = 100 }, 0
    local v = {
      isServer = opts.client ~= true, _sfCreditedLitersThisTick = mark,
      getOwnerFarmId = function() return 1 end,
    }
    v.addFillUnitFillLevel = function(_, _, _, delta) calls = calls + 1 tank.fillLevel = tank.fillLevel + delta return delta end
    v.getFillUnitFillType = function() return PSW.FT.LIQUIDFERTILIZER.index end
    v.spec_sprayer = { workAreaParameters = { isActive = opts.active == true, sprayVehicle = v, sprayVehicleFillUnitIndex = 1,
      sprayFillType = PSW.FT.LIQUIDFERTILIZER.index } }
    return v, tank, function() return calls end
  end
  local v, tank, calls = sprayer(5)
  T.eq("U1 [reached] a usable mark on an inactive server tick drains it", tostring(HookManager.drainCreditedLitres(v)) .. "/" .. tank.fillLevel .. "/" .. calls(), "true/95/1")
  local vc, tankC, callsC = sprayer(5, { client = true })
  T.eq("U2 a client drains nothing, whatever the mark", tostring(HookManager.drainCreditedLitres(vc)) .. "/" .. tankC.fillLevel .. "/" .. callsC(), "false/100/0")
  local bad = { -3, 0, 0 / 0, math.huge, "5", true }
  local drained = 0
  for _, m in ipairs(bad) do
    local vb, _, callsB = sprayer(m)
    HookManager.drainCreditedLitres(vb)
    drained = drained + callsB()
  end
  T.eq("U3 a mark that is not a positive finite number drains nothing", drained, 0)
  local va = sprayer(5, { active = true })
  local okA = HookManager.drainCreditedLitres(va)
  T.eq("U4 a mark is cleared even when the game drained (no drain is added, none is left behind)", tostring(okA) .. "/" .. tostring(va._sfCreditedLitersThisTick), "false/nil")
end)

PSW.restore()
