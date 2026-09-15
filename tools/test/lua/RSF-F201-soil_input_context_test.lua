--!load: tools/test/lua/f201_model_binding.lua, src/utils/SoilContextInput.lua, src/SoilFertilityManager.lua
-- RSF-F201, SoilFertilizer input through the REAL SoilContextInput +
-- SoilFertilityManager.installContextInput / registerPlayerContextInputEvents on
-- a minimal manager instance. Witnesses: a complete set opens no begin/end;
-- PLAYER and VEHICLE get distinct ids; the predecessor is called while this
-- participant's own injection is in flight; after a throw the close is attempted
-- and the flag released; retired targets stay inert; the old PLAYER purge and
-- rebuild are gone (PLAYER survives every cab pass). Model binding, not native.

local noop = function() end
SoilLogger = SoilLogger or {}
for _, k in ipairs({ "info", "warning", "error", "debug", "flushDebugLog" }) do SoilLogger[k] = SoilLogger[k] or noop end
GS_PRIO_HIGH = GS_PRIO_HIGH or 3

local ACTIONS = { "SF_TOGGLE_HUD", "SF_CYCLE_MAP_LAYER", "SF_OPEN_SETTINGS", "SF_HUD_DRAG", "SF_MINIMAP_ZOOM",
    "SF_SCOUT", "SF_TREATMENT", "SF_HANDFUL", "SF_RATE_UP", "SF_RATE_DOWN", "SF_TOGGLE_AUTO", "SF_VARIABLE_RATE" }
local b = F201Model.installEngine(ACTIONS)
local nativeCalls, predecessorEnds, predecessorSawInFlight = 0, 0, 0
PlayerInputComponent.registerActionEvents = function() nativeCalls = nativeCalls + 1 end
local nativePlayer = PlayerInputComponent.registerActionEvents
local realEnd = b.endActionEventsModification
local record  -- set after install
b.endActionEventsModification = function(self, ...)
    predecessorEnds = predecessorEnds + 1
    if record ~= nil and record.inFlight then predecessorSawInFlight = predecessorSawInFlight + 1 end
    return realEnd(self, ...)
end
local nativeVehicle = b.endActionEventsModification

local mission = { getIsClient = function() return true end, getIsServer = function() return true end }
g_currentMission = mission
g_masterHUD = nil
local hits = {}
local sfm = setmetatable({ soilHUD = {}, settingsPanel = {}, soilMapOverlay = {}, mission = mission }, { __index = SoilFertilityManager })
for _, h in ipairs({ "onToggleHUDInput", "onCycleMapLayerInput", "onOpenSettingsInput", "onHUDDragInput", "onMinimapZoomInput",
    "onScoutInput", "onTreatmentInput", "onHandfulInput", "onSprayerRateUpInput", "onSprayerRateDownInput",
    "onToggleAutoInput", "onVariableRateInput" }) do
    sfm[h] = function() hits[h] = (hits[h] or 0) + 1 end
end
g_SoilFertilityManager = sfm

-- GROUP A: install + activate
sfm:installContextInput(mission)
record = SoilContextInput.record(SoilFertilityManager, "_f201Input")
local wPlayer, wVehicle = PlayerInputComponent.registerActionEvents, InputBinding.endActionEventsModification
T.ok("F201 SF A1 PLAYER wrapper installed", wPlayer ~= nativePlayer)
T.ok("F201 SF A2 VEHICLE wrapper installed", wVehicle ~= nativeVehicle)
T.eq("F201 SF A3 owner bound on the class-table record", record.owner, sfm)
sfm:installContextInput(mission)
T.eq("F201 SF A4 second install stacks nothing", PlayerInputComponent.registerActionEvents, wPlayer)

-- GROUP B: full PLAYER set (standalone: 8), full VEHICLE set (9), distinct ids
wPlayer({ player = { isOwner = true } })
T.eq("F201 SF B1 predecessor called", nativeCalls, 1)
T.eq("F201 SF B2 eight on-foot actions", b:totalIn("PLAYER"), 8)
local pid = sfm.toggleHUDEventId
T.ok("F201 SF B3 on-foot toggle handle", pid ~= nil)
T.eq("F201 SF B4 on-foot settings row hidden", b.events[sfm.settingsPanelEventId].displayIsVisible, false)
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
T.eq("F201 SF B5 nine cab actions", b:totalIn("VEHICLE"), 9)
T.ok("F201 SF B6 cab toggle handle differs from on-foot", sfm.vehicleHUDEventId ~= nil and sfm.vehicleHUDEventId ~= pid)
T.eq("F201 SF B7 cab rate row on the F1 strip", b.events[sfm.rateUpEventId].displayIsVisible, true)
T.eq("F201 SF B8 cab rate row high priority", b.events[sfm.rateUpEventId].priority, GS_PRIO_HIGH)
T.eq("F201 SF B9 cab zoom row hidden", b.events[sfm.vehicleMinimapZoomEventId].displayIsVisible, false)
T.ok("F201 SF B10 PLAYER survives the cab pass (no purge, no rebuild)", b.events[pid] ~= nil and sfm.toggleHUDEventId == pid)
T.ok("F201 SF B11 the predecessor ran while our own injection was in flight", predecessorSawInFlight >= 1)

-- GROUP C: complete set opens no bracket, either door
local begun, attempts, ends = b.begun, b.attempts, predecessorEnds
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
T.eq("F201 SF C1 complete cab set: only the engine bracket", b.begun, begun + 1)
T.eq("F201 SF C2 only the engine close reached the predecessor", predecessorEnds, ends + 1)
wPlayer({ player = { isOwner = true } })
sfm:registerPlayerContextInputEvents(b)
T.eq("F201 SF C3 complete on-foot set: no registration from either door", b.attempts, attempts)

-- GROUP D: lost id recovered from the live event, not re-registered
sfm.scoutEventId = nil
sfm:update(0)  -- admission reset (the rest of update is nil-guarded on this minimal instance)
sfm:registerPlayerContextInputEvents(b)
T.ok("F201 SF D1 scout id recovered", sfm.scoutEventId ~= nil)
T.eq("F201 SF D2 without a registration", b.attempts, attempts)

-- GROUP E: a registration throw: close attempted, flag released, error propagated
b:deleteContext("VEHICLE")
sfm:update(0)
b.throwOnRegister = true
local ok, err = pcall(function() b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification() end)
b.throwOnRegister = false
T.ok("F201 SF E1 the throw propagates", not ok and tostring(err):find("synthetic") ~= nil)
T.eq("F201 SF E2 brackets balanced after the throw", b.begun, b.ended)
T.eq("F201 SF E3 in-flight released", record.inFlight, false)
sfm:update(0)
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
T.eq("F201 SF E4 next interval registers the cab set", b:totalIn("VEHICLE"), 9)

-- GROUP F: MasterHUD present retires the gated rows only
g_masterHUD = {}
sfm:update(0)
sfm:registerPlayerContextInputEvents(b)
T.eq("F201 SF F1 on-foot toggle and drag retired", b:totalIn("PLAYER"), 6)
T.eq("F201 SF F2 toggle handle cleared", sfm.toggleHUDEventId, nil)
T.ok("F201 SF F3 scout kept", b.events[sfm.scoutEventId] ~= nil)
g_masterHUD = nil

-- GROUP G: keys reach the owner; retire makes targets inert and restores nothing
local ev = b:first("VEHICLE", "SF_RATE_UP")
ev.callback(ev.targetObject, ev.actionName, 1)
T.eq("F201 SF G1 cab key reaches the owner", hits.onSprayerRateUpInput, 1)
SoilContextInput.retire(record)
ev.callback(ev.targetObject, ev.actionName, 1)
T.eq("F201 SF G2 retired target forwards nothing", hits.onSprayerRateUpInput, 1)
T.eq("F201 SF G3 PLAYER wrapper not restored", PlayerInputComponent.registerActionEvents, wPlayer)
T.eq("F201 SF G4 VEHICLE wrapper not restored", InputBinding.endActionEventsModification, wVehicle)
