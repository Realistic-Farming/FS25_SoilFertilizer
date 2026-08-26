-- sf18_kill_state_spec_test.lua
-- #878/#879: the SF-18 establishment kill write. Two properties locked here:
--   1. HARDENING (#878/#879): killRegion always releases setIgnoreDensityChanges
--      (false), even when the density write throws mid-way. A stuck toggle would
--      leave the growth system ignoring density changes for the rest of the
--      session, freezing crop visibility and re-drilling.
--   2. STATE (#879): a whole-stand kill clears SF's own sownCrop display bridge
--      (via _recordFullKill), so SF stops reporting a planted/growing crop the
--      vanilla PDA correctly shows as absent (state 0 on the fruit plane).
--      Partial kills keep the crop: surviving cells keep the window open.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/EstablishmentFailure.lua

local EF = EstablishmentFailure

local function newEF()
  return setmetatable({ manager = { soilSystem = {} } }, { __index = EF })
end

local fruitDesc = {
  terrainDataPlaneId = 4, startStateChannel = 0, numStateChannels = 4,
  minHarvestingGrowthState = 6,
}

local ring = { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 }, { x = 0, z = 10 } }

-- 1. HARDENING: a mid-write throw still releases the density-change toggle, and
--    the write error is swallowed (the daily pass never dies on an engine hiccup).
do
  local m = newEF()
  local calls = {}
  m._ensureSubstrate = function()
    return { growthSystem = { setIgnoreDensityChanges = function(_s, v) calls[#calls + 1] = v end } }
  end
  m._clearWeeds = function() end
  local realNew = DensityMapModifier.new
  DensityMapModifier.new = function(...)
    local mod = realNew(...)
    mod.executeSet = function() error("density write boom") end
    return mod
  end
  local ok = pcall(function() m:killRegion(7, {}, ring, fruitDesc) end)
  DensityMapModifier.new = realNew
  T.ok('harden.errorSwallowed', ok == true)
  T.ok('harden.toggledTrueThenFalse', #calls == 2 and calls[1] == true and calls[2] == false)
end

-- 2. STATE: _recordFullKill clears the whole SF display bridge on a full kill.
do
  local m = newEF()
  local field = { establishingKilled = false, establishing = true, establishingSowDay = 5, sownCrop = "OATS" }
  m:_recordFullKill(field)
  T.eq('state.killedFlag', field.establishingKilled, true)
  T.eq('state.windowClosed', field.establishing, false)
  T.ok('state.sowDayCleared', field.establishingSowDay == nil)
  T.ok('state.sownCropCleared', field.sownCrop == nil)
end

-- 3. INTEGRATION: the whole-field frost kill path goes through _recordFullKill,
--    so a killed field ends with no sownCrop (SF agrees the crop never came up).
do
  local m = newEF()
  g_currentMission.weatherGuard = { getCurrentSky = function() return { temperature = -3 } end }
  local field = {
    establishing = true, establishingSowDay = 5, establishingKilled = false,
    establishingKilledCells = {}, sownCrop = "OILSEEDRADISH", zoneData = {},
    compaction = 0,
  }
  m.manager.soilSystem = { fieldData = { [1] = field } }
  m._moistureSource = function() return nil end
  m._fieldPolygonWorld = function() return {} end
  m.killRegion = function() end
  m._groupRegions = function() return {} end
  m._notify = function() end
  m:_checkEstablishingField(1, field)
  T.ok('kill.sownCropCleared', field.sownCrop == nil)
  T.eq('kill.windowClosed', field.establishing, false)
end

-- 4. INTEGRATION: a PARTIAL kill keeps the crop. The moisture cell path kills
--    some cells, leaves others establishing, and sownCrop must survive.
do
  local m = newEF()
  g_currentMission.weatherGuard = nil   -- no frost cause: moisture alone
  m._moistureSource = function()
    return { getMoisture = function(_self, _fid, x) return (x < 10) and 1.0 or 0.0 end }
  end
  m.severity = function() return 1.0 end
  m.effectiveThreshold = function() return 0.5 end
  m._fieldPolygonWorld = function() return {} end
  m.killRegion = function() end
  m._groupRegions = function(cells)
    return { cells }
  end
  m._regionPolygon = function(_cells, _size) return { ring } end
  m._notify = function() end
  local field = {
    establishing = true, establishingSowDay = 3, establishingKilled = false,
    establishingKilledCells = {}, sownCrop = "CORN",
    zoneData = {
      ["0,0"] = { gx = 0, gz = 0, compaction = 0 },
      ["5,0"] = { gx = 5, gz = 0, compaction = 0 },
    },
  }
  m.manager.soilSystem = { fieldData = { [1] = field } }
  m:_checkEstablishingField(1, field)
  T.eq('partial.cropSurvives', field.sownCrop, "CORN")
  T.eq('partial.windowStillOpen', field.establishing, true)
end

T.summary()
