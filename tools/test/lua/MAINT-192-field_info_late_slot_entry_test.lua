-- MAINT-192-field_info_late_slot_entry_test.lua: MAINTENANCE row 192, Soil's rows in the
-- native FIELD INFO box (Bob's intake, Drafts/BOB-INTAKE-MAINT192-FIELDINFO-LATE-SLOT-2026-10-01.md).
--
-- The defect: the "late" row group was bound to PlayerHUDUpdater.fieldAddFruit, an FS22 name
-- no FS25 build has, so the late rows (Amend. burn risk; Drilling, the SF-30 advisory) never
-- displayed. fieldAddField, which adds the crop rows, was wrapped only by the extras scan,
-- which appends nothing. Soil's own "Yield" row sat in the early group, appended before the
-- override of the native "Yield bonus" row ran, so a growing field showed the number twice.
-- The label match used per-language fragments, and a wrapper that could never see the yield
-- row warned once a session that nothing matched.
--
-- ENTRY-POINT BAR. The real install, HookManager:installNativeFieldInfoHook, called on the
-- HookManager the real SoilFertilitySystem.new owns, wraps the engine's PlayerHUDUpdater. The
-- engine's own showFieldInfo then builds the box: fieldAddFarmland, fieldAddField,
-- fieldAddWeed and fieldAddFieldActions in that order (PlayerHUDUpdater.lua:227-242), each
-- body as the engine has it (:243-349). The rows Soil adds come from the real
-- getFieldInfo (field records built by the real scanFields) through the real SoilHUD.new
-- and buildFieldInfoLines. The field id is resolved by the hook itself, through its
-- `data` fallback (no player position here): the engine's FieldState farmlandId, the field
-- manager's mapping and Field:getId (Field.lua:117-123). Nothing hands Soil a row, a
-- field id or a label.
--
-- Modelled, not real: the density-map reads behind FieldState:update (C-side; the model
-- copies one laid ground), FieldState:getHarvestScaleMultiplier (the ground's multiplier),
-- the weed system's state labels, the box's draw (the active lines in order,
-- InfoDisplayKeyValueBox.lua:57-117) and SeasonalCropStress's getRainOutlook, which the
-- drilling advisory asks (SoilFertilitySystem:_drillingAdvisory). The engine's l10n texts
-- are registered as the base game's locale would load them. Engine bodies are copied with
-- the decompiler's lost identifiers restored from their control flow: the growth state at
-- :281-:291 and :335-:339 is fieldInfo.growthState, the fruit index at :329 is the one
-- tested at :328, and :297-:305 name the ground system and the bonus; addLine (:130-144)
-- assigns the new line it appends.
--
-- Groups:
--   E  English, a growing crop: one yield row (the native label, Soil's number), Soil's
--      rows on both sides of the crop rows, Amend. burn risk and Drilling after it and
--      before the weed and field-action rows, no row drawn twice, Fertilized suppressed,
--      no warning
--   C  English, a cut crop (Tyson's case): no native yield row, so Soil's "Yield" row
--      shows in the late block; no row drawn twice
--   R  Russian texts, a growing crop: the yield and Fertilized rows still match by key
--
-- Two-sided: on development 79c2a627 the late rows are absent, a growing field shows two
-- yield rows, the Russian rows are not matched, and the session warns.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/utils/DurationScaling.lua, src/config/SettingsSchema.lua, src/settings/Settings.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/ui/SoilHUD.lua

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── what the bar changes, saved and put back at the end ──
local GLOBALS = { "PlayerHUDUpdater", "FieldState", "FruitType", "FieldGroundType", "AccessHandler", "Platform",
                  "MathUtil", "g_fruitTypeManager", "g_fieldManager", "g_farmlandManager", "g_farmManager",
                  "g_SoilFertilityManager", "g_server", "g_localPlayer" }
local SAVED = {}
for _, k in ipairs(GLOBALS) do SAVED[k] = _G[k] end
local MISSION_KEYS = { "missionInfo", "weedSystem", "fieldGroundSystem", "cropStressManager", "controlledVehicle", "getFarmId" }
local SAVED_MISSION = {}
for _, k in ipairs(MISSION_KEYS) do SAVED_MISSION[k] = g_currentMission[k] end
local SAVED_FDM_SPRAY_LEVEL = FieldDensityMap.SPRAY_LEVEL
local SAVED_SPECTATOR = FarmManager.SPECTATOR_FARM_ID
local SAVED_TEXTS, SAVED_SUFFIX = g_i18n.texts, g_languageSuffix
local SAVED_LOG = { warning = SoilLogger.warning, info = SoilLogger.info }

-- ── engine enums and helpers (FarmManager.lua:5, AccessHandler.lua:2-3, MathUtil.lua:39-48, :228-230) ──
FruitType = { UNKNOWN = 0 }
FieldGroundType = { NONE = 0 }
FieldDensityMap.SPRAY_LEVEL = FieldDensityMap.SPRAY_LEVEL or 3
FarmManager.SPECTATOR_FARM_ID = 0
AccessHandler = { EVERYONE = 0, NOBODY = 2 ^ FarmManager.FARM_ID_SEND_NUM_BITS - 1 }
Platform = { playerInfo = { showNPCNames = false }, gameplay = { useLimeCounter = true, useRolling = false, hasWeeder = false } }
MathUtil = {
  round = function(value, precision)
    if value == nil then return nil end
    if not precision then return math.floor(value + 0.5) end
    local exp = 10 ^ precision
    return math.floor(value * exp + 0.5) / exp
  end,
  getDirectionFromYRotation = function(rotY) return math.sin(rotY), math.cos(rotY) end,
}

-- ── the engine's fruit type (FruitTypeDesc.lua:685-721, the state tests verbatim) ──
local FruitTypeDesc = {}
FruitTypeDesc.__index = FruitTypeDesc
function FruitTypeDesc:getIsHarvestable(growthState) return self.harvestTransitions[growthState] ~= nil end
function FruitTypeDesc:getIsCut(growthState) return self.cutStates[growthState] ~= nil end
function FruitTypeDesc:getIsGrowing(growthState)
  local maxGrowingState = self.minHarvestingGrowthState - 1
  if self.minPreparingGrowthState >= 0 then
    maxGrowingState = math.min(maxGrowingState, self.minPreparingGrowthState - 1)
  end
  return growthState > 0 and growthState <= maxGrowingState
end
function FruitTypeDesc:getIsPreparable(growthState)
  return self.minPreparingGrowthState <= growthState and growthState <= self.maxPreparingGrowthState
end
function FruitTypeDesc:getIsWithered(growthState) return self.witheredState ~= nil and self.witheredState == growthState end
function FruitTypeDesc:getIsWeedable(growthState) return self.minWeederState <= growthState and growthState <= self.maxWeederState end
function FruitTypeDesc:getIsHoeable(growthState) return self.minWeederHoeState <= growthState and growthState <= self.maxWeederHoeState end

-- A wheat-shaped desc: growing 1-7, ready 8, withered 9, cut 10.
local WHEAT = setmetatable({
  index = 2, name = "WHEAT", fillType = { title = "Wheat" },
  minHarvestingGrowthState = 8, maxHarvestingGrowthState = 8,
  minPreparingGrowthState = -1, maxPreparingGrowthState = -1,
  cutStates = { [10] = true }, witheredState = 9, harvestTransitions = { [8] = 10 },
  minWeederState = 1, maxWeederState = 2, minWeederHoeState = 1, maxWeederHoeState = 4,
}, FruitTypeDesc)
local GROWING, CUT = 3, 10

-- ── the ground the density maps would read ──
local GROUND = {}

-- ── the engine's FieldState (FieldState.lua:18-39 verbatim; :86-120 modelled) ──
FieldState = {}
local FieldState_mt = { __index = FieldState }
function FieldState.new(customMt)
  local self = setmetatable({}, customMt or FieldState_mt)
  self.isValid = false
  self.fruitTypeIndex = FruitType.UNKNOWN
  self.growthState = 0
  self.lastGrowthState = 0
  self.weedState = 0
  self.weedFactor = 0
  self.stoneLevel = 0
  self.groundType = FieldGroundType.NONE
  self.sprayLevel = 0
  self.sprayType = 0
  self.limeLevel = 0
  self.rollerLevel = 0
  self.plowLevel = 0
  self.stubbleShredLevel = 0
  self.waterLevel = 0
  self.farmlandId = 0
  self.ownerFarmId = AccessHandler.NOBODY
  return self
end
function FieldState:update(x, z)
  self.farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
  self.ownerFarmId = g_farmlandManager:getFarmlandOwner(self.farmlandId)
  self.lastFruitTypeIndex = self.fruitTypeIndex
  self.lastGrowthState = self.growthState
  self.isValid = true
  self.fruitTypeIndex = GROUND.fruitTypeIndex or FruitType.UNKNOWN
  self.growthState = GROUND.growthState or 0
  if self.fruitTypeIndex ~= self.lastFruitTypeIndex then self.lastGrowthState = 0 end
  self.weedState = GROUND.weedState or 0
  self.groundType = GROUND.groundType or FieldGroundType.NONE
  self.sprayLevel = GROUND.sprayLevel or 0
  self.limeLevel = GROUND.limeLevel or 0
  self.rollerLevel = GROUND.rollerLevel or 0
  self.plowLevel = GROUND.plowLevel or 0
end
function FieldState:getHarvestScaleMultiplier() return GROUND.harvestScale end

-- ── the engine's InfoDisplayKeyValueBox (:124-150; draw shows the active lines in order) ──
local Box = {}
Box.__index = Box
local function newBox() return setmetatable({ lines = {}, currentLineIndex = 0, doShowNextFrame = false }, Box) end
function Box:clear()
  for _, line in ipairs(self.lines) do line.isActive = false end
  self.currentLineIndex = 0
end
function Box:addLine(key, value, isWarning)
  self.currentLineIndex = self.currentLineIndex + 1
  local line = self.lines[self.currentLineIndex]
  if line == nil then
    line = { key = "", value = "", isWarning = false }
    table.insert(self.lines, line)
  end
  line.key = key
  line.value = value or ""
  line.isWarning = isWarning
  line.isActive = true
end
function Box:setTitle(title) self.title = title end
function Box:showNextFrame() self.doShowNextFrame = true end
local function drawn(box)
  local out = {}
  for _, line in ipairs(box.lines) do
    if line.isActive then out[#out + 1] = { key = line.key, value = line.value } end
  end
  return out
end

-- ── the engine's PlayerHUDUpdater (PlayerHUDUpdater.lua:227-349), a fresh class per world ──
local function newPlayerHUDUpdaterClass()
  local P = {}
  function P:showFieldInfo(posX, posZ, rotY)
    local fieldInfo = self.fieldInfo
    local dirX, dirZ = MathUtil.getDirectionFromYRotation(rotY)
    fieldInfo:update(posX + dirX * 2, posZ + dirZ * 2)
    if fieldInfo.groundType ~= FieldGroundType.NONE then
      local box = self.fieldBox
      box:clear()
      box:setTitle(g_i18n:getText("ui_fieldInfo"))
      self:fieldAddFarmland(fieldInfo, box)
      self:fieldAddField(fieldInfo, box)
      self:fieldAddWeed(fieldInfo, box)
      self:fieldAddFieldActions(fieldInfo, box)
      self.fieldInfoNeedsRebuild = false
      box:showNextFrame()
    end
  end
  function P.fieldAddFarmland(_, fieldInfo, box)
    local ownedByYou = false
    local ownerFarmId = fieldInfo.ownerFarmId
    local farmName
    if ownerFarmId == g_currentMission:getFarmId() and ownerFarmId ~= FarmManager.SPECTATOR_FARM_ID then
      farmName = g_i18n:getText("fieldInfo_ownerYou")
      ownedByYou = true
    elseif ownerFarmId == AccessHandler.EVERYONE or ownerFarmId == AccessHandler.NOBODY then
      local farmland = g_farmlandManager:getFarmlandById(fieldInfo.farmlandId)
      if farmland == nil then
        farmName = g_i18n:getText("fieldInfo_ownerNobody")
      else
        local npc = farmland:getNPC()
        farmName = npc ~= nil and npc.title or "Unknown"
      end
    else
      local farmland = g_farmManager:getFarmById(ownerFarmId)
      farmName = farmland == nil and "Unknown" or farmland.name
    end
    box:addLine(g_i18n:getText("fieldInfo_farmland"), (tostring(fieldInfo.farmlandId)))
    if Platform.playerInfo.showNPCNames then
      box:addLine(g_i18n:getText("fieldInfo_ownedBy"), farmName)
      return
    elseif ownedByYou then
      box:addLine(g_i18n:getText("fieldInfo_owned"))
    else
      box:addLine(g_i18n:getText("fieldInfo_notOwned"))
    end
  end
  function P.fieldAddField(_, fieldInfo, box)
    local fruitTypeIndex = fieldInfo.fruitTypeIndex
    local isGrowing = false
    if fruitTypeIndex ~= FruitType.UNKNOWN then
      local fruitTypeDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
      box:addLine(g_i18n:getText("statistic_fillType"), fruitTypeDesc.fillType.title)
      local growthState = fieldInfo.growthState
      local text = nil
      if fruitTypeDesc:getIsCut(growthState) then
        text = g_i18n:getText("ui_growthMapCut")
      elseif fruitTypeDesc:getIsWithered(growthState) then
        text = g_i18n:getText("ui_growthMapWithered")
      elseif fruitTypeDesc:getIsGrowing(growthState) then
        text = g_i18n:getText("ui_growthMapGrowing")
        isGrowing = true
      elseif fruitTypeDesc:getIsPreparable(growthState) then
        text = g_i18n:getText("ui_growthMapReadyToPrepareForHarvest")
        isGrowing = true
      elseif fruitTypeDesc:getIsHarvestable(growthState) then
        text = g_i18n:getText("ui_growthMapReadyToHarvest")
        isGrowing = true
      end
      if text ~= nil then
        box:addLine(g_i18n:getText("ui_mapOverviewGrowth"), text)
      end
    end
    local fieldGroundSystem = g_currentMission.fieldGroundSystem
    if isGrowing then
      local bonus = fieldInfo:getHarvestScaleMultiplier() - 1
      local bonusPercent = MathUtil.round(bonus * 100)
      box:addLine(g_i18n:getText("fieldInfo_yieldBonus"), string.format("+ %d %%", bonusPercent))
    end
    if fieldInfo.sprayLevel >= 0 then
      local maxSprayLevel = fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL)
      box:addLine(g_i18n:getText("ui_growthMapFertilized"), string.format("%d %%", fieldInfo.sprayLevel / maxSprayLevel * 100))
    end
  end
  function P.fieldAddFieldActions(_, fieldInfo, box)
    local missionInfo = g_currentMission.missionInfo
    if Platform.gameplay.useLimeCounter and (missionInfo.limeRequired and fieldInfo.limeLevel == 0) then
      box:addLine(g_i18n:getText("ui_growthMapNeedsLime"), nil, true)
    end
    if fieldInfo.plowLevel == 0 and missionInfo.plowingRequiredEnabled then
      box:addLine(g_i18n:getText("ui_growthMapNeedsPlowing"), nil, true)
    end
    if Platform.gameplay.useRolling and fieldInfo.rollerLevel > 0 then
      box:addLine(g_i18n:getText("ui_growthMapNeedsRolling"), nil, true)
    end
  end
  function P.fieldAddWeed(_, fieldInfo, box)
    if g_currentMission.missionInfo.weedsEnabled then
      local weedSystem = g_currentMission.weedSystem
      local fieldInfoStates = weedSystem:getFieldInfoStates()
      local weedState = fieldInfo.weedState
      local toolName = nil
      if weedState ~= 0 then
        local fruitTypeDesc = nil
        local fruitTypeIndex = fieldInfo.fruitTypeIndex or FruitType.UNKNOWN
        if fruitTypeIndex ~= nil then
          fruitTypeDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        end
        local growthState = fieldInfo.growthState
        if Platform.gameplay.hasWeeder then
          if (fruitTypeDesc == nil or fruitTypeDesc:getIsWeedable(growthState or 0)) and weedSystem:getWeederReplacements(false).weed.replacements[weedState] == 0 then
            toolName = g_i18n:getText("weed_destruction_weeder")
          end
          if toolName == nil and (fruitTypeDesc == nil or fruitTypeDesc:getIsHoeable(growthState)) and weedSystem:getWeederReplacements(true).weed.replacements[weedState] == 0 then
            toolName = g_i18n:getText("weed_destruction_hoe")
          end
        end
        if toolName == nil and (fruitTypeDesc == nil or fruitTypeDesc:getIsGrowing(growthState)) then
          toolName = g_i18n:getText("weed_destruction_herbicide")
        end
        local stateText = fieldInfoStates[weedState]
        if stateText ~= nil then
          box:addLine(stateText, toolName or "", true)
        end
      end
    else
      return
    end
  end
  return P
end

-- ── the base game's texts, as its locale would load them ──
local TEXTS = {
  en = {
    ui_fieldInfo = "Field info", fieldInfo_farmland = "Farmland", fieldInfo_owned = "Owned",
    fieldInfo_notOwned = "Not owned", fieldInfo_ownerYou = "You", statistic_fillType = "Crop type",
    ui_mapOverviewGrowth = "Growth", ui_growthMapGrowing = "Growing", ui_growthMapCut = "Cut",
    fieldInfo_yieldBonus = "Yield-bonus", ui_growthMapFertilized = "Fertilized",
    ui_growthMapNeedsLime = "Needs lime", weed_destruction_herbicide = "Herbicide",
  },
  -- No fragment the old lists carried matches either label.
  ru = {
    ui_fieldInfo = "Информация о поле", fieldInfo_farmland = "Участок", fieldInfo_owned = "В собственности",
    fieldInfo_notOwned = "Не в собственности", fieldInfo_ownerYou = "Вы", statistic_fillType = "Культура",
    ui_mapOverviewGrowth = "Рост", ui_growthMapGrowing = "Растёт", ui_growthMapCut = "Скошено",
    fieldInfo_yieldBonus = "Бонус урожая", ui_growthMapFertilized = "Удобрено",
    ui_growthMapNeedsLime = "Нужна известь", weed_destruction_herbicide = "Гербицид",
  },
}
local WEED_STATES = { en = { [1] = "Weeds (small)" }, ru = { [1] = "Сорняки (мелкие)" } }

-- ── one world: the engine, production's soil system and the installed hook ──
local W = {}
local function world(opts)
  local lang = opts.lang or "en"
  g_i18n.texts = {}
  for k, v in pairs(TEXTS[lang]) do g_i18n.texts[k] = v end
  g_languageSuffix = "_" .. lang
  W.lang = lang

  GROUND = { fruitTypeIndex = WHEAT.index, growthState = opts.growthState, weedState = 1, groundType = 1,
             sprayLevel = 1, limeLevel = 0, rollerLevel = 0, plowLevel = 1, harvestScale = 1.37, farmlandId = 7 }

  local fruitByIndex = { [WHEAT.index] = WHEAT }
  g_fruitTypeManager = setmetatable({ getFruitTypeByIndex = function(_, i) return fruitByIndex[i] end },
                                    { __index = SAVED.g_fruitTypeManager })
  local farmland = { id = 7, areaInHa = 1.0 }
  function farmland:getId() return self.id end
  local Field = {}
  function Field:getId()
    if self.farmland == nil then
      return nil
    else
      return self.farmland:getId()
    end
  end
  local fsField = setmetatable({ farmland = farmland, areaHa = 1.0, posX = 50, posZ = 50,
                                 getDensityMapPolygon = function() return "field7-polygon" end }, { __index = Field })
  g_fieldManager = { fields = { fsField }, farmlandIdFieldMapping = { [7] = fsField } }
  g_farmlandManager = {
    farmlands = { [7] = farmland },
    getFarmlandById = function(_, id) return id == 7 and farmland or nil end,
    getFarmlandOwner = function(_, id) return id == 7 and 1 or AccessHandler.NOBODY end,
    getFarmlandIdAtWorldPosition = function(_, _x, _z) return GROUND.farmlandId end,
  }
  g_farmManager = { getFarmById = function() return nil end }
  g_server = {}                      -- the host, single player included
  g_localPlayer = nil
  g_currentMission.controlledVehicle = nil
  g_currentMission.getFarmId = function() return 1 end
  g_currentMission.missionInfo = { weedsEnabled = true, limeRequired = true, plowingRequiredEnabled = false }
  g_currentMission.weedSystem = { getFieldInfoStates = function() return WEED_STATES[lang] end }
  g_currentMission.fieldGroundSystem = { getMaxValue = function(_, map) return map == FieldDensityMap.SPRAY_LEVEL and 2 or 0 end }
  -- SeasonalCropStress's published outlook, which the drilling advisory asks.
  W.outlookAsks = {}
  g_currentMission.cropStressManager = {
    getRainOutlook = function(_, horizon)
      W.outlookAsks[#W.outlookAsks + 1] = horizon
      return { likelihood = 0.1 }
    end,
  }

  W.warnings = {}
  SoilLogger.warning = function(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    W.warnings[#W.warnings + 1] = ok and s or tostring(fmt)
  end
  SoilLogger.info = function() end

  local settings = Settings.new(nil)
  settings.save = function() end
  local sys = SoilFertilitySystem.new(settings)
  sys:scanFields()
  local soilHUD = SoilHUD.new(sys, settings)
  g_SoilFertilityManager = { settings = settings, soilSystem = sys, soilHUD = soilHUD }
  W.sys, W.settings = sys, settings

  PlayerHUDUpdater = newPlayerHUDUpdaterClass()
  W.originals = {}
  for k, v in pairs(PlayerHUDUpdater) do W.originals[k] = v end
  W.installed = sys.hookManager:installNativeFieldInfoHook()
  W.hm = sys.hookManager

  W.hud = setmetatable({ fieldInfo = FieldState.new(), fieldBox = newBox() }, { __index = PlayerHUDUpdater })
  W.hud:showFieldInfo(50, 48, 0)
  W.rows = drawn(W.hud.fieldBox)
  return W
end

local function find(rows, key)
  for i, r in ipairs(rows) do if r.key == key then return i, r end end
  return nil
end
local function count(rows, keys)
  local n = 0
  for _, r in ipairs(rows) do
    for _, k in ipairs(keys) do if r.key == k then n = n + 1 end end
  end
  return n
end
local function listing(rows)
  local parts = {}
  for _, r in ipairs(rows) do parts[#parts + 1] = tostring(r.key) .. "=" .. tostring(r.value) end
  return table.concat(parts, " | ")
end
local function soilPercent()
  local info = W.sys:getFieldInfo(7)
  return info ~= nil and info.yieldEfficiency ~= nil and string.format("%d%%", math.floor(info.yieldEfficiency + 0.5)) or nil
end
local function hookWarnings()
  local n = 0
  for _, w in ipairs(W.warnings) do
    if w:find("field info hook", 1, true) or w:find("yield-bonus", 1, true) then n = n + 1 end
  end
  return n
end
local function repeated(rows)
  local seen, twice = {}, {}
  for _, r in ipairs(rows) do
    if seen[r.key] then twice[#twice + 1] = tostring(r.key) end
    seen[r.key] = true
  end
  return table.concat(twice, ", ")
end
local function inOrder(rows, keys)
  local last = 0
  for _, k in ipairs(keys) do
    local i = find(rows, k)
    if i == nil or i <= last then return false, k end
    last = i
  end
  return true
end

local EN = TEXTS.en
local SOIL_YIELD, SOIL_GRADE, BURN, DRILL = "Yield", "Soil Grade", "Amend. burn risk", "Drilling"

-- ══════════════════════════════════════════════════════════════════════════
-- E. ENGLISH, A GROWING CROP
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
  world({ growthState = GROWING })
  local rows = W.rows
  local wrapped = 0
  for _, name in ipairs({ "fieldAddFarmland", "fieldAddField", "fieldAddWeed", "fieldAddFieldActions" }) do
    if PlayerHUDUpdater[name] ~= W.originals[name] then wrapped = wrapped + 1 end
  end
  T.eq("E0 [reached: the real install wrapped the four field functions the engine calls]", tostring(W.installed) .. "/" .. wrapped, "true/4")
  local perName = {}
  for _, h in ipairs(W.hm.hooks or {}) do
    if h.target == PlayerHUDUpdater then perName[h.key] = (perName[h.key] or 0) + 1 end
  end
  T.eq("E0b each is wrapped once (fieldAddField is not in the extras scan as well)",
       tostring(perName.fieldAddFarmland) .. "/" .. tostring(perName.fieldAddField) .. "/" .. tostring(perName.fieldAddWeed) .. "/" .. tostring(perName.fieldAddFieldActions),
       "1/1/1/1")
  local pct = soilPercent()
  T.ok("E1 [reached: the box drew with Soil's rows, and Soil has a yield number for field 7] " .. listing(rows),
       pct ~= nil and find(rows, SOIL_GRADE) ~= nil and find(rows, EN.statistic_fillType) ~= nil)
  local _, bonus = find(rows, EN.fieldInfo_yieldBonus)
  T.eq("E2 NAMED: exactly one yield row, the native label carrying Soil's number",
       tostring(count(rows, { EN.fieldInfo_yieldBonus, SOIL_YIELD })) .. "/" .. tostring(bonus and bonus.value), "1/" .. tostring(pct))
  T.ok("E3 NAMED: the late rows display: Amend. burn risk and Drilling", find(rows, BURN) ~= nil and find(rows, DRILL) ~= nil)
  local ok, at = inOrder(rows, { EN.fieldInfo_owned, SOIL_GRADE, EN.statistic_fillType, EN.ui_mapOverviewGrowth,
                                 EN.fieldInfo_yieldBonus, BURN, DRILL, WEED_STATES.en[1], EN.ui_growthMapNeedsLime })
  T.ok("E4 NAMED: Farmland/Owned, Soil's early rows, Crop type, Growth, Yield-bonus, Soil's late rows, the weed row, the field actions (out of order at " .. tostring(at) .. ")", ok)
  T.eq("E4b NAMED: no row is drawn twice (each pass appends only its own group)", repeated(rows), "")
  T.eq("E5 NAMED: the native Fertilized row is suppressed", find(rows, EN.ui_growthMapFertilized), nil)
  T.eq("E6 NAMED: no field-info hook warning at install or draw (" .. table.concat(W.warnings, " || ") .. ")", hookWarnings(), 0)
  T.ok("E7 [reached: the drilling advisory asked SeasonalCropStress for its outlook, with a horizon]",
       #W.outlookAsks >= 1 and type(W.outlookAsks[1]) == "number" and W.outlookAsks[1] > 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. ENGLISH, A CUT CROP
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
  world({ growthState = CUT })
  local rows = W.rows
  local _, growth = find(rows, EN.ui_mapOverviewGrowth)
  T.eq("C1 [reached: the crop reads Cut, and the engine adds no yield-bonus row] " .. listing(rows),
       tostring(growth and growth.value) .. "/" .. tostring(find(rows, EN.fieldInfo_yieldBonus)), EN.ui_growthMapCut .. "/nil")
  local pct = soilPercent()
  local _, soilYield = find(rows, SOIL_YIELD)
  T.eq("C2 NAMED: Soil's own Yield row shows, once, with Soil's number",
       tostring(count(rows, { EN.fieldInfo_yieldBonus, SOIL_YIELD })) .. "/" .. tostring(soilYield and soilYield.value), "1/" .. tostring(pct))
  local ok, at = inOrder(rows, { SOIL_GRADE, EN.statistic_fillType, EN.ui_mapOverviewGrowth, SOIL_YIELD, DRILL,
                                 WEED_STATES.en[1], EN.ui_growthMapNeedsLime })
  T.ok("C3 NAMED: in the late block: after Growth, with Drilling, before the weed and field-action rows (out of order at " .. tostring(at) .. ")", ok)
  T.eq("C3b NAMED: no row is drawn twice", repeated(rows), "")
  T.eq("C4 a cut crop carries no burn risk", find(rows, BURN), nil)
  T.eq("C5 no field-info hook warning", hookWarnings(), 0)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. RUSSIAN TEXTS, A GROWING CROP
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
  world({ growthState = GROWING, lang = "ru" })
  local rows = W.rows
  local RU = TEXTS.ru
  T.ok("R0 [reached: the box drew in Russian] " .. listing(rows), find(rows, RU.statistic_fillType) ~= nil and find(rows, RU.ui_mapOverviewGrowth) ~= nil)
  local pct = soilPercent()
  local _, bonus = find(rows, RU.fieldInfo_yieldBonus)
  T.eq("R1 NAMED: exactly one yield row, the Russian native label carrying Soil's number",
       tostring(count(rows, { RU.fieldInfo_yieldBonus, SOIL_YIELD })) .. "/" .. tostring(bonus and bonus.value), "1/" .. tostring(pct))
  T.eq("R2 NAMED: the Russian Fertilized row is suppressed", find(rows, RU.ui_growthMapFertilized), nil)
  T.eq("R3 no field-info hook warning", hookWarnings(), 0)
end)

-- ── put the world back ──
for _, k in ipairs(GLOBALS) do _G[k] = SAVED[k] end
for _, k in ipairs(MISSION_KEYS) do g_currentMission[k] = SAVED_MISSION[k] end
FieldDensityMap.SPRAY_LEVEL = SAVED_FDM_SPRAY_LEVEL
FarmManager.SPECTATOR_FARM_ID = SAVED_SPECTATOR
g_i18n.texts, g_languageSuffix = SAVED_TEXTS, SAVED_SUFFIX
SoilLogger.warning, SoilLogger.info = SAVED_LOG.warning, SAVED_LOG.info
