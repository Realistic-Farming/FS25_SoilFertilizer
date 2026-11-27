-- MAINT-346-weed_state_boundary_hook_spec_test.lua
--
-- MAINTENANCE row 346. The first native weed state that means "weeds gone" (maps_weed.xml: a herbicide
-- turns states 1 to 6 into 0 or 7 to 9, and 7 to 9 are the withered result) was a literal in two places:
-- the credit hook's `ws == 0 or ws >= 7` (HookManager.installSeeAndSprayHook) and the per-nozzle decision's
-- own copy. It is one value now, SoilConstants.SEE_AND_SPRAY.WEED_STATE_WITHERED_FROM, read by both.
--
-- THE ENTRY-POINT BAR, hook side. Every case runs the real hook chain through the MAINT-232 world (the real
-- Sprayer.onStartWorkAreaProcessing wrappers, the real SoilSensorManager) with a HERBICIDE boom that has
-- See & Spray, and the native weed state 3 over the whole field. Only the shared boundary moves between cases,
-- so a hook that still carried its own literal would not follow it. The nozzle side is group W8 of
-- MAINT-343-see_spray_herbicide_engine_weed_spec_test.lua.
--
-- Groups:
--   B   the shipped boundary is 7; state 3 is a target at 7 and at 4; moved to 3, state 3 is gone;
--       control: no weeds at all (state 0) skips
--
-- What this does NOT prove: the engine's weed table on a map other than the base-game one, or anything in game.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilSensorManager.lua, src/specializations/SFNozzleEffects.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, tools/test/lua/MAINT-232-section_sample_world.lua

local W, boom, install, tick, spraying = SSW.W, SSW.boom, SSW.install, SSW.tick, SSW.spraying
local SS = SoilConstants.SEE_AND_SPRAY
local shipped = SS.WEED_STATE_WITHERED_FROM

local function fields()
    local base = function() return { zoneData = {}, pestPressure = 0, diseasePressure = 0, weedPressure = 0 } end
    return { [7] = base(), [8] = base() }
end
-- native weed state 3 under every section; the boundary set to b; which sections spray
local function run(b)
    SS.WEED_STATE_WITHERED_FROM = b
    W.weeds, W.splitX = { { -30, 30 } }, math.huge
    install(fields())
    local v = boom("HERBICIDE", true)
    tick(v)
    return spraying(v)
end

T.eq("B0 the shipped boundary is 7 (maps_weed.xml: 7 to 9 are the withered result)", shipped, 7)
T.ok("B1 at the shipped boundary, native state 3 is a target: the sections spray", run(7) ~= "")
T.ok("B2 boundary 4: state 3 is still a target, the sections spray", run(4) ~= "")
T.eq("B3 boundary moved to 3: state 3 is 'weeds gone' for the hook, every section skips", run(3), "")
-- control: native state 0 (no weeds anywhere) is "weeds gone" at the shipped boundary, whatever the boundary is
SS.WEED_STATE_WITHERED_FROM = shipped
W.weeds, W.splitX = {}, math.huge
install(fields())
local v0 = boom("HERBICIDE", true)
tick(v0)
T.eq("B4 control: no native weeds anywhere, every section skips", spraying(v0), "")
SS.WEED_STATE_WITHERED_FROM = shipped
