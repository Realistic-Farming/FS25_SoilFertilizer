-- sf57_establishment_causes_test.lua
-- SF-57 establishment causes: a hard frost during the establishment window kills
-- the seed (one frost is enough), a rough seedbed eases the trip points, and a
-- frost-tender cover crop winter-kills over winter. Rides SF-18's binary
-- threshold-kill frame: no graded scale, no snap counter, a killed cell is
-- killed. Absent WeatherGuard = no frost cause.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/EstablishmentFailure.lua

g_currentMission = { _isServer = true, environment = { currentMonotonicDay = 10 } }
function g_currentMission:getIsServer() return self._isServer end
g_SoilFertilityManager = { settings = { difficulty = 2, showNotifications = false } }
g_fillTypeManager = {}

local function ef()
  return setmetatable({ manager = { soilSystem = {} } }, { __index = EstablishmentFailure })
end

-- 1. THE SEEDBED WEIGHT EASES THE TRIP POINT.
do
  local m = ef()
  local field = { compaction = 0, seedbedWeight = nil }
  T.near('seedbed.neutralWeight', m:effectiveThreshold(field), 0.85, 1e-9)
  local rough = { compaction = 0, seedbedWeight = 0.85 }
  T.near('seedbed.stubbleEasesTrip', m:effectiveThreshold(rough), 0.85 * 0.85, 1e-9)
  local plowed = { compaction = 0, seedbedWeight = 1.0 }
  T.near('seedbed.plowedResists', m:effectiveThreshold(plowed), 0.85, 1e-9)
end

-- 2. THE FROST TRIP POINT IS SEEDBED-WEIGHTED TOO.
do
  local m = ef()
  T.eq('frost.neutralPoint', m:frostTripPoint({}), 0.0)
  T.near('frost.stubbleLowersPoint', m:frostTripPoint({ seedbedWeight = 0.85 }), 0.0, 1e-9)
end

-- 3. TENDER VS HARDY.
do
  local m = ef()
  T.eq('hardy.wheatExempt', m:_isFrostHardy("WHEAT"), true)
  T.eq('hardy.ryeExempt', m:_isFrostHardy("rye"), true)
  T.eq('tender.oilseedRadishNotExempt', m:_isFrostHardy("oilseedRadish"), false)
  T.eq('tender.unknownNotExempt', m:_isFrostHardy("SOMETHING"), false)
end

-- 4. NO WEATHERGURAD = NO FROST CAUSE (nil read, never a crash).
do
  local m = ef()
  g_currentMission.weatherGuard = nil
  T.eq('frost.noWeatherGuardIsNil', m:_readTemperature(), nil)
end

-- 5. THE FROST KILL FIRES ON A HARD FROST DURING THE WINDOW.
do
  local m = ef()
  g_currentMission.weatherGuard = { getCurrentSky = function() return { temperature = -3 } end }
  local killed = {}
  local field = {
    establishing = true, establishingSowDay = 5, establishingKilled = false,
    establishingKilledCells = {}, sownCrop = "OILSEEDRADISH", zoneData = {},
    compaction = 0,
  }
  m.manager.soilSystem = { fieldData = { [1] = field } }
  m._moistureSource = function() return nil end   -- no moisture signal: frost alone
  m._fieldPolygonWorld = function() return {} end
  m.killRegion = function(_s, _fid, _f, _verts, _fd) killed[#killed + 1] = _fid end
  m._groupRegions = function() return {} end
  m._notify = function() end
  m:_checkEstablishingField(1, field)
  T.eq('frost.killedTheField', killed[1], 1)
  T.eq('frost.windowClosed', field.establishing, false)
end

-- 6. A FROST-HARDY CROP SURVIVES THE SAME FROST.
do
  local m = ef()
  g_currentMission.weatherGuard = { getCurrentSky = function() return { temperature = -3 } end }
  local killed = {}
  local field = {
    establishing = true, establishingSowDay = 5, establishingKilled = false,
    establishingKilledCells = {}, sownCrop = "WHEAT", zoneData = {},
  }
  m.manager.soilSystem = { fieldData = { [1] = field } }
  m._moistureSource = function() return nil end
  m.killRegion = function(_s, _fid, _f, _verts, _fd) killed[#killed + 1] = _fid end
  m._groupRegions = function() return {} end
  m._notify = function() end
  m:_checkEstablishingField(1, field)
  T.eq('frost.hardySurvives', #killed, 0)
  T.eq('frost.hardyWindowStays', field.establishing, true)
end

-- 7. WINTERKILL: A FROST-TENDER COVER CROP DIES OVER WINTER, HARDY IS EXEMPT.
do
  local m = ef()
  g_currentMission.weatherGuard = { getCurrentSky = function() return { temperature = -5 } end }
  local notified = {}
  m._notify = function(_self, key, _fid, _cause) notified[#notified + 1] = key end
  m.manager.soilSystem.fieldData = {
    [1] = { establishing = false, sownCrop = "oilseedRadish", winterKilled = false },
    [2] = { establishing = false, sownCrop = "WHEAT", winterKilled = false },
  }
  m:_winterkillCheck()
  T.eq('winterkill.tenderDies', m.manager.soilSystem.fieldData[1].winterKilled, true)
  T.eq('winterkill.hardySurvives', m.manager.soilSystem.fieldData[2].winterKilled, false)
  T.ok('winterkill.notified', #notified >= 1)
end

T.summary()
