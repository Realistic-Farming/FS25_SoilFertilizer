-- MAINT-166-protection_sprayer_world.lua
--
-- A crop-protection sprayer pass through the REAL sprayer hook, into a REAL soil
-- system, for the protection-grant bars (MAINTENANCE row 166, #1030 bug 3). Loaded
-- after the prelude and the src files; a bar calls PSW.new(), drives passes with
-- world:tick(liters, cells), and calls PSW.restore() at the end.
--
-- What is real:
--   * HookManager.installSprayerAreaHook appends to Sprayer.onEndWorkAreaProcessing,
--     and every pass runs through that append (the fixture shape of RSF-F196 group G).
--   * The soil system is the SoilFertilitySystem class; the hook reaches its real
--     trackSprayerCoverage, on*AppliedDirect and markBoomCells. Only paintBoomStrip,
--     applyBurnEffect and applyScorchEffect are observers: display and burn effects
--     the grant does not read.
--   * The field record is made by the real scanFields over the map's field, and the
--     settings are a real Settings object (schema defaults). No fieldData entry and no
--     coverage fraction is written by hand: coverage comes from the passes.
--
-- What is modelled (the engine, not Soil):
--   * the map: one field on farmland 7, owned by farm 1, with g_fieldManager's
--     farmlandIdFieldMapping (FieldManager) and getDensityMapPolygon;
--   * the weed system: a map with weeds, a herbicide replacement table (fixture
--     states), and FieldState:update reading the weed state at the field's centre;
--   * FieldUpdateTask, which records every task enqueued (the weed-map write).
--   * the map's spray types (g_sprayTypeManager after Soil's registration), whose
--     litersPerSecond the hook's coverage estimate divides out (#1063). PSW.SPRAY_LPS.
--
-- Cells are 10 m (SoilConstants.ZONE.CELL_SIZE), 0.01 ha each; world:cells(from, to)
-- gives distinct cell centres along one row, so a pass covers exactly those cells.

PSW = {}

local FT = {
  HERBICIDE   = { name = "HERBICIDE",   index = 70, massPerLiter = 0.001 },
  INSECTICIDE = { name = "INSECTICIDE", index = 71, massPerLiter = 0.001 },
  FUNGICIDE   = { name = "FUNGICIDE",   index = 72, massPerLiter = 0.001 },
  PESTICIDE   = { name = "PESTICIDE",   index = 73, massPerLiter = 0.001 },
  PROPICONAZOLE = { name = "PROPICONAZOLE", index = 74, massPerLiter = 0.001 },
  FERTILIZER  = { name = "FERTILIZER",  index = 75, massPerLiter = 0.001 },
  LIQUIDFERTILIZER = { name = "LIQUIDFERTILIZER", index = 76, massPerLiter = 0.001 },
}
PSW.FT = FT

-- The map's spray types: litersPerSecond per product, as the engine holds them once Soil
-- has registered its own. Soil registers its crop protection at its rate over 36000
-- (registerCustomSprayTypes, HookManager.lua liquidNames: 100 L/ha); FERTILIZER and
-- LIQUIDFERTILIZER keep the base map's (0.0060 and 0.0081, the registration's own
-- defaults); PESTICIDE is another mod's product with its own figure. A bar derives an
-- expected rate from this table, never from the code: litres per hectare = lps x 36000.
PSW.SPRAY_LPS = {
  HERBICIDE = 100 / 36000, INSECTICIDE = 100 / 36000, FUNGICIDE = 100 / 36000,
  PROPICONAZOLE = 100 / 36000, PESTICIDE = 0.0026,
  FERTILIZER = 0.0060, LIQUIDFERTILIZER = 0.0081,
}
function PSW.ratePerHa(name) return PSW.SPRAY_LPS[name] * 36000 end

local saved = nil

--- A group that raises is reported as a named failing row, so a crash stays attributable.
function PSW.group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

function PSW.restore()
  if saved == nil then return end
  g_fillTypeManager, Sprayer, Utils, g_SoilFertilityManager = saved.ftm, saved.sprayer, saved.utils, saved.sfm
  g_sprayTypeManager = saved.stm
  g_fieldManager, g_farmlandManager, g_server = saved.fm, saved.flm, saved.server
  g_currentMission.missionDynamicInfo, g_currentMission.weedSystem = saved.mdi, saved.weed
  g_currentMission.addUpdateable, g_currentMission.removeUpdateable = saved.addU, saved.removeU
  FieldState, FieldUpdateTask = saved.fieldState, saved.fieldUpdateTask
  saved = nil
end

--- opts.product      fill type name the sprayer carries (default HERBICIDE)
--- opts.areaHa       the field's crop area (default 0.2 ha = 20 cells)
--- opts.centreWeed   the weed state FieldState reads at the field's centre (default 2, live)
--- opts.multiplayer  a multiplayer host (every event it broadcasts is recorded in world.events)
--- opts.noVww        a rig with no variable-width sections: coverage takes the hook's litres path
--- opts.secondTank   a fill type name for a real second fill unit (a multi-tank rig); world.units
function PSW.new(opts)
  opts = opts or {}
  if saved == nil then
    saved = {
      ftm = g_fillTypeManager, sprayer = Sprayer, utils = Utils, sfm = g_SoilFertilityManager,
      stm = g_sprayTypeManager,
      fm = g_fieldManager, flm = g_farmlandManager, server = g_server,
      mdi = g_currentMission.missionDynamicInfo, weed = g_currentMission.weedSystem,
      addU = g_currentMission.addUpdateable, removeU = g_currentMission.removeUpdateable,
      fieldState = FieldState, fieldUpdateTask = FieldUpdateTask,
    }
  end
  local world = { tasks = {}, events = {}, centreWeed = opts.centreWeed or 2, boom = {} }
  local areaHa = opts.areaHa or 0.2

  FillType = FillType or { UNKNOWN = 0 }
  ToolType = ToolType or { UNDEFINED = 0 }
  local byIndex, byName = {}, {}
  for _, ft in pairs(FT) do byIndex[ft.index] = ft; byName[ft.name] = ft end
  g_fillTypeManager = {
    getFillTypeByIndex = function(_, i) return byIndex[i] end,
    getFillTypeByName  = function(_, n) return byName[n] end,
  }
  local sprayTypes = {}
  for name, lps in pairs(PSW.SPRAY_LPS) do
    sprayTypes[FT[name].index] = { name = name, litersPerSecond = lps }
  end
  -- A bar that installs its own manager first (a registration bar) keeps it: every other
  -- method, and any index the map does not carry, goes to that manager.
  local underlying = g_sprayTypeManager
  local stm = {
    getSprayTypeByFillTypeIndex = function(_, i)
      if sprayTypes[i] ~= nil then return sprayTypes[i] end
      if underlying ~= nil and underlying.getSprayTypeByFillTypeIndex ~= nil then
        return underlying:getSprayTypeByFillTypeIndex(i)
      end
      return nil
    end,
  }
  if underlying ~= nil then
    for k, v in pairs(underlying) do
      if stm[k] == nil and type(v) == "function" then
        stm[k] = function(_, ...) return v(underlying, ...) end
      end
    end
  end
  g_sprayTypeManager = stm
  Utils = {
    prependedFunction = function(orig, new)
      return function(...) new(...) if orig then return orig(...) end end
    end,
    appendedFunction = function(orig, new)
      return function(...)
        local r = orig and { orig(...) } or {}
        new(...)
        return unpack(r)
      end
    end,
  }

  -- ── The map ──
  local farmland = { id = 7, areaInHa = areaHa }
  local fsField = {
    farmland = farmland, areaHa = areaHa, posX = 55, posZ = 5,
    getDensityMapPolygon = function() return "field7-polygon" end,
  }
  world.fsField = fsField
  g_fieldManager = { fields = { fsField }, farmlandIdFieldMapping = { [7] = fsField } }
  g_farmlandManager = {
    farmlands = { [7] = farmland },
    getFarmlandById = function(_, id) return id == 7 and farmland or nil end,
    getFarmlandOwner = function(_, id) return id == 7 and 1 or 0 end,
  }

  -- ── The weed engine ──
  g_currentMission.weedSystem = {
    getMapHasWeed = function() return true end,
    getHerbicideReplacements = function()
      return { weed = { replacements = { [1] = 5, [2] = 6, [3] = 7, [4] = 8 } } }
    end,
  }
  FieldState = { new = function()
    return { update = function(self, _x, _z) self.weedState = world.centreWeed end }
  end }
  FieldUpdateTask = { new = function()
    local task = { weedState = nil }
    function task:setField(f) self.field = f end
    function task:setArea(a) self.area = a end
    function task:setWeedState(s) self.weedState = s end
    function task:enqueue() world.tasks[#world.tasks + 1] = self end
    return task
  end }

  -- ── The peer ──
  g_server = { broadcastEvent = function(_, ev) world.events[#world.events + 1] = ev end }
  g_currentMission.missionDynamicInfo = { isMultiplayer = opts.multiplayer == true }
  -- The mission's updateable list: a multiplayer host's load scan hands the full field
  -- sync to it (broadcastAllFieldData). Recorded, not run: the bars do not need it.
  world.updateables = {}
  g_currentMission.addUpdateable = function(_, u) world.updateables[#world.updateables + 1] = u end
  g_currentMission.removeUpdateable = function() end

  -- ── The soil system ──
  local settings = Settings.new(nil)
  settings.save = function() end
  settings.overlapPrevention = SettingsSchema.validate("overlapPrevention", false)
  local sys = setmetatable({
    settings = settings, fieldData = {}, genesisActive = false, genesisSeed = 0,
    fieldsScanPending = false, scanRetryTimer = 0, scanRetryAttempts = 0,
    activeFieldIds = {}, _activeFieldList = {}, _activeListDirty = false,
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
    paintBoomStrip = function() end, applyBurnEffect = function() end, applyScorchEffect = function() end,
  }, { __index = SoilFertilitySystem })
  world.sys = sys
  g_SoilFertilityManager = { settings = settings, soilSystem = sys }
  sys:scanFields()

  -- ── The hook ──
  Sprayer = { onStartWorkAreaProcessing = function() end, onEndWorkAreaProcessing = function() end }
  local hm = HookManager.new()
  hm.register = function() end
  hm.getFieldIdAtWorldPosition = function() return 7 end
  hm.getBoomCellPositions = function() return world.boom end
  hm.getBoomLineEndpoints = function() return nil end
  world.hookMgr = hm
  -- Production wiring: the soil system owns the HookManager the hooks are installed
  -- from (SoilFertilitySystem.new, :165), so onFertilizerApplied's refusal check
  -- (RSF-F196 V7) reads the same refused-product table.
  sys.hookManager = hm
  world.installed = hm:installSprayerAreaHook()

  local product = FT[opts.product or "HERBICIDE"]
  world.product = product
  local units = { [1] = { fillLevel = 5000, fillType = product.index } }
  if opts.secondTank ~= nil then
    units[2] = { fillLevel = 5000, fillType = FT[opts.secondTank].index }
  end
  world.units = units
  local v = {
    isServer = true, id = "veh1",
    spec_workArea = { workAreas = {} },
    spec_variableWorkWidth = (not opts.noVww) and { sections = { { isActive = true } } } or nil,
    getIsTurnedOn = function() return true end,
    getLastSpeed  = function() return 8.0 end,
    getSprayerFillUnitIndex = function() return 1 end,
    getFillUnitFillLevel = function(_s, i) local u = units[i]; return u and u.fillLevel or 0 end,
    getFillUnitFillType  = function(_s, i) local u = units[i]; return u and u.fillType or 0 end,
    getOwnerFarmId = function() return 1 end,
    addFillUnitFillLevel = function() return 0 end,
    raiseDirtyFlags = function() end,
  }
  v.spec_sprayer = {
    workAreaParameters = {
      sprayFillType = product.index, usage = 0, sprayFillLevel = 5000, isActive = true,
      sprayVehicle = v, sprayVehicleFillUnitIndex = 1,
    },
    effects = {}, sprayTypes = {},
  }
  v.spec_fillUnit = { fillUnits = units }
  v.processSprayerArea = function() return 250, 3 end
  local wa = { functionName = "processSprayerArea" }
  wa.processingFunction = v.processSprayerArea
  table.insert(v.spec_workArea.workAreas, wa)
  world.vehicle = v

  --- Switch the active tank (unit 1) to another product, as a refill does.
  function world:setProduct(name)
    self.product = FT[name]
    self.units[1].fillType = FT[name].index
    self.vehicle.spec_sprayer.workAreaParameters.sprayFillType = FT[name].index
  end

  --- The field record scanFields made.
  function world:field() return self.sys.fieldData[7] end

  --- Distinct cell centres i = from..to along one row of the field.
  function world:cells(from, to)
    local pts = {}
    for i = from, to do pts[#pts + 1] = { x = 5 + 10 * (i - 1), z = 5 } end
    return pts
  end

  --- One sprayer pass through the real hook: `liters` this tick over `cells`.
  function world:tick(liters, cells)
    self.boom = cells or {}
    local veh = self.vehicle
    veh.spec_sprayer.workAreaParameters.usage = liters
    Sprayer.onStartWorkAreaProcessing(veh, 16)
    veh.spec_workArea.workAreas[1].processingFunction(veh, veh.spec_workArea.workAreas[1], 16)
    Sprayer.onEndWorkAreaProcessing(veh, 16, true)
  end

  return world
end
