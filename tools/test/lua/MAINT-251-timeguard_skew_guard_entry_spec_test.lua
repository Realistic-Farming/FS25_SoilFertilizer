-- MAINT-251-timeguard_skew_guard_entry_spec_test.lua
--
-- MAINTENANCE row 251: Soil's Time Guard version-skew guard fires on a Time Guard without the simulation
-- flow class, at all three sites.
--
-- THE DEFECT THIS PINS (development ab39998): EstablishmentFailure:registerDailyAccrual read the bare global
-- TimeGuardScheduler, which Time Guard defines in its OWN mod environment (mods.lua:482-505), and
-- GrowthCredit:registerDailyAccrual and ViabilityMask:registerDailyAccrual read tg.flowClasses, a field Time
-- Guard never publishes. So on Time Guard v1.0.0.0 (fa74ff8; FLOW_CLASSES calendar, usage, event:
-- TimeGuardScheduler.lua:29), which shipped, all three registered a soil process that Time Guard then coerced
-- to the calendar class (TimeGuardScheduler.lua:66-69). The simulation class first shipped in v1.0.1.0.
-- SF-53's fixture invented tg.flowClasses, which is why no bench saw it.
--
-- THE FIX: each site reads the class list through the instance, tg.scheduler.FLOW_CLASSES, nil-safe. Time
-- Guard publishes no flow-class field, so this reads its internal scheduler: TimeGuard.lua:38 sets
-- self.scheduler = TimeGuardScheduler.new(self) in every version, and the instance's metatable comes from
-- Class(TimeGuardScheduler), whose __index is the class table (shared/class.lua:15).
--
-- THE ENTRY-POINT BAR IS GROUP E. Production's activation, SoilFertilityManager:activateSoilSystem, runs on
-- a manager carrying the three real modules built by their own constructors as SoilFertilityManager.new
-- builds them (:156, :161, :170), on the server. Time Guard is reachable only as the mission's handle, and
-- it is modelled to its real shape: registerAccrual delegates to a scheduler whose class table is reached
-- through its metatable, and an unknown flowClass is coerced to calendar as TimeGuardScheduler.lua:66-69
-- does. The soil store is the world: activation only needs its initialize() to return.
--
--   E0  [reached] Soil's environment has no TimeGuardScheduler; activation ran and reached Time Guard
--   E1  a current Time Guard (simulation listed): all three register under simulation
--   E2  a v1.0.0.0 Time Guard (no simulation): none registers, nothing is coerced, the fallback stays
--   E3  a Time Guard with no scheduler table: all three register as before (the read is nil-safe)
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/maps/SoilValueMaps.lua, src/integrations/OptionScalingResolver.lua, src/EstablishmentFailure.lua, src/ViabilityMask.lua, src/GrowthCredit.lua, src/SoilFertilityManager.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local SOIL_ENV = _ENV

local V100 = { calendar = true, usage = true, event = true }                     -- v1.0.0.0, fa74ff8
local CURRENT = { calendar = true, usage = true, event = true, simulation = true } -- v1.0.1.0 and later

--- A Time Guard of the given class list (nil: no scheduler table at all). Returns it and the list of
--- registrations it accepted, as "<id>=<class it filed them under>".
local function timeGuard(classes)
  local filed = {}
  local SchedulerClass = { FLOW_CLASSES = classes }
  local scheduler = nil
  if classes ~= nil then
    scheduler = setmetatable({ accruals = {} }, { __index = SchedulerClass })   -- Class(): __index = members
  end
  local tg = {
    scheduler = scheduler,
    registerAccrual = function(_self, id, spec)
      -- TimeGuard:registerAccrual -> scheduler:registerAccrual (TimeGuard.lua:344-346); an unknown class is
      -- coerced to calendar (TimeGuardScheduler.lua:66-69).
      local known = (classes or CURRENT)
      local fc = spec.flowClass or "calendar"
      if not known[fc] then fc = "calendar" end
      filed[#filed + 1] = tostring(id) .. "=" .. fc
      return true
    end,
    unregisterAccrual = function() return true end,
  }
  return tg, filed
end

--- Production's activation on a fresh manager, against the given Time Guard. Returns the manager.
local function activate(tg)
  g_server = {}
  g_timeGuard = nil
  g_currentMission = {
    timeGuard = tg,
    environment = { currentMonotonicDay = 10, currentDay = 10, currentSeason = 1, daysPerPeriod = 3 },
    missionInfo = { savegameDirectory = "bench" },
  }
  local mgr = setmetatable({ modName = "FS25_SoilFertilizer", disableGUI = true, lastSeenVersion = "bench",
                             settings = { enabled = true },
                             soilSystem = { initialize = function() end } }, { __index = SoilFertilityManager })
  mgr.establishment = EstablishmentFailure.new(mgr)
  mgr.viability = ViabilityMask.new(mgr)
  mgr.growthCredit = GrowthCredit.new(mgr)
  SoilFertilityManager.activateSoilSystem(mgr)
  return mgr
end

local function flags(mgr)
  return tostring(mgr.establishment._tgAccrualRegistered == true) .. "/"
      .. tostring(mgr.viability._tgAccrualRegistered == true) .. "/"
      .. tostring(mgr.growthCredit._tgAccrualRegistered == true)
end

local function classesFiled(filed)
  local out = {}
  for _, f in ipairs(filed) do out[#out + 1] = f:match("=(.*)$") end
  table.sort(out)
  return table.concat(out, ",")
end

group("E", function()
  T.eq("E0 Soil's environment has no TimeGuardScheduler (it is Time Guard's own global)",
    rawget(SOIL_ENV, "TimeGuardScheduler"), nil)

  local tg, filed = timeGuard(CURRENT)
  local mgr = activate(tg)
  T.ok("E0 [reached] production's activateSoilSystem reached Time Guard for all three modules", #filed == 3, tostring(#filed))
  T.eq("E1 a current Time Guard: all three register, each under the simulation class", classesFiled(filed), "simulation,simulation,simulation")
  T.eq("E1 and each module records the registration", flags(mgr), "true/true/true")

  tg, filed = timeGuard(V100)
  mgr = activate(tg)
  T.eq("E2 [entry point] NAMED (row 251): a v1.0.0.0 Time Guard gets no registration at all, so nothing is coerced to calendar",
    #filed, 0)
  T.eq("E2 and no module records one: each stays on Soil's own day tracking", flags(mgr), "false/false/false")

  tg, filed = timeGuard(nil)
  mgr = activate(tg)
  T.eq("E3 a Time Guard with no scheduler table: all three register as before (the read is nil-safe)",
    classesFiled(filed) .. " " .. flags(mgr), "simulation,simulation,simulation true/true/true")
end)

g_server, g_currentMission = nil, nil
