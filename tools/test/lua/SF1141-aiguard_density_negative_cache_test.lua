-- SF1141-aiguard_density_negative_cache_test.lua
--
-- GitHub issue #1141 (joeynuggetz, Courseplay compat): an AI job running over
-- already-worked ground called the installAIFruitRequirementGuard() wrapper on
-- AIVehicleUtil.getAIAreaOfVehicle every tick, and the implement's custom density
-- map (the sprayer's weed/stone map) was one the engine rejects for
-- getDensityMapSize ("invalid type"). pcall stops that from being a fatal Lua
-- error, but the engine logs its own "invalid type" line on every call regardless
-- of pcall, and measure() only cached a SUCCESSFUL read, so a rejected mapId was
-- probed again on the very next tick. One field produced 519 log lines in 42
-- seconds and 26,988 total before the player stopped the job.
--
-- THE ENTRY-POINT BAR: this drives the REAL installAIFruitRequirementGuard() and
-- the REAL wrapped AIVehicleUtil.getAIAreaOfVehicle it installs, exactly as
-- AIDriveStrategyFieldCourse calls it every update tick. Nothing below reaches
-- into HookManager's private measure()/stripMismatched() closures; the only hook
-- into the fix is counting calls to the mocked native getDensityMapSize, which
-- stands in for the engine call the bug report's log shows repeating.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

-- The ground-type map (id "ground") always measures cleanly, exactly like any
-- ordinary map load; the implement's custom map (id "bad_custom") is the one the
-- engine rejects, matching the reporter's "Entity ... has invalid type" line.
g_currentMission.fieldGroundSystem.getDensityMapData = function()
    return "ground"
end

local calls = {}
getDensityMapSize = function(mapId)
    calls[mapId] = (calls[mapId] or 0) + 1
    if mapId == "ground" then return 2048 end
    if mapId == "good_custom" then return 2048 end
    if mapId == "mismatch_custom" then return 1024 end
    if tostring(mapId):find("^bad_") then
        -- The real engine call logs its own "invalid type" error and raises, which
        -- is exactly what the installed pcall in measure() is there to catch.
        error("Entity 'bad_custom' for 'object' has invalid type in method 'getDensityMapSize'.")
    end
    return nil
end

AIVehicleUtil = AIVehicleUtil or {}
local originalCalls = 0
AIVehicleUtil.getAIAreaOfVehicle = function(vehicle, ...)
    originalCalls = originalCalls + 1
    return "area-from-original", vehicle
end

local hm = setmetatable({ hooks = {} }, { __index = HookManager })
local installed = hm:installAIFruitRequirementGuard()
T.ok("A0 guard installs when getDensityMapSize and AIVehicleUtil are present", installed == true)

local vehicle = {
    spec_aiImplement = {
        requiredFruitTypes = { { customMapId = "bad_custom" } },
        prohibitedFruitTypes = {},
    },
}

-- Five ticks, the way AIDriveStrategyFieldCourse:update drives this every frame.
for _ = 1, 5 do
    AIVehicleUtil.getAIAreaOfVehicle(vehicle)
end

T.eq("A1 the rejected custom map is probed exactly once across 5 ticks, not 5 times",
    calls.bad_custom, 1)
T.eq("A2 the wrapper still reaches the original function every tick",
    originalCalls, 5)
T.ok("A3 an unmeasurable entry is left in place, not dropped (left-alone, not stripped)",
    #vehicle.spec_aiImplement.requiredFruitTypes == 1)

-- A mapId the engine measures successfully is unaffected: still read once and
-- cached, same as before this fix. Distinct mapId from "ground" so this is not
-- riding on the ground map's own cache warmed above.
vehicle.spec_aiImplement.requiredFruitTypes = { { customMapId = "good_custom" } }
for _ = 1, 3 do
    AIVehicleUtil.getAIAreaOfVehicle(vehicle)
end
T.eq("A4 a measurable custom map is still probed once and cached, same as before this fix",
    calls.good_custom, 1)

-- ---------------------------------------------------------------------------------------
-- More ways the rejection cache has to hold. Each row builds a FRESH guard (a new mission
-- load builds a new closure and so a new cache) on top of the same mocked original, then
-- drives the wrapper the way the engine's per-tick caller does.
-- ---------------------------------------------------------------------------------------
local warnings = {}
local realWarning = SoilLogger.warning
SoilLogger.warning = function(msg, ...)
    local ok, s = pcall(string.format, tostring(msg), ...)
    warnings[#warnings + 1] = ok and s or tostring(msg)
end

local function freshGuard(groundId)
    for k in pairs(calls) do calls[k] = nil end
    for k in pairs(warnings) do warnings[k] = nil end
    originalCalls = 0
    AIVehicleUtil.getAIAreaOfVehicle = function(vehicle, ...)
        originalCalls = originalCalls + 1
        return "area-from-original", vehicle
    end
    g_currentMission.fieldGroundSystem.getDensityMapData = function() return groundId end
    local h = setmetatable({ hooks = {} }, { __index = HookManager })
    return h:installAIFruitRequirementGuard()
end

local function ticks(vehicle, n)
    for _ = 1, n do AIVehicleUtil.getAIAreaOfVehicle(vehicle) end
end

-- A5: the guard's own job is unchanged. A map that measures fine but at another size than
-- the ground map is still dropped, and an already-built query is rebuilt once.
freshGuard("ground")
local rebuilt = 0
local mismatchVehicle = {
    spec_aiImplement = { requiredFruitTypes = { { customMapId = "mismatch_custom" } }, prohibitedFruitTypes = {}, fieldCropyQuery = {} },
    updateFieldCropsQuery = function() rebuilt = rebuilt + 1 end,
}
ticks(mismatchVehicle, 3)
T.eq("A5 a measurable map at another size than the ground map is still dropped, and the query rebuilt once",
    #mismatchVehicle.spec_aiImplement.requiredFruitTypes .. "/" .. rebuilt .. "/" .. (calls.mismatch_custom or 0), "0/1/1")

-- A6: the ground-type map is the one the engine rejects. It is probed once, not every tick,
-- and the custom entry is left in place because nothing can be compared.
freshGuard("bad_ground")
local groundVehicle = {
    spec_aiImplement = { requiredFruitTypes = { { customMapId = "good_custom" } }, prohibitedFruitTypes = {} },
}
ticks(groundVehicle, 5)
T.eq("A6 a rejected GROUND map is probed once across 5 ticks", calls.bad_ground, 1)
T.eq("A6b and the custom entry that cannot be compared is left in place", #groundVehicle.spec_aiImplement.requiredFruitTypes, 1)

-- A7: the prohibited list goes through the same cache.
freshGuard("ground")
local prohibitedVehicle = {
    spec_aiImplement = { requiredFruitTypes = {}, prohibitedFruitTypes = { { customMapId = "bad_custom" } } },
}
ticks(prohibitedVehicle, 5)
T.eq("A7 a rejected map in the PROHIBITED list is probed once across 5 ticks", calls.bad_custom, 1)

-- A8: the cache belongs to the guard, not to a vehicle or a list: two vehicles and both lists
-- naming the same rejected map cost one probe in all.
freshGuard("ground")
local vA = { spec_aiImplement = { requiredFruitTypes = { { customMapId = "bad_custom" } }, prohibitedFruitTypes = {} } }
local vB = { spec_aiImplement = { requiredFruitTypes = {}, prohibitedFruitTypes = { { customMapId = "bad_custom" } } } }
ticks(vA, 5)
ticks(vB, 5)
T.eq("A8 one rejected map shared by two vehicles and both lists is probed once in all", calls.bad_custom, 1)

-- A9: the one warning per unmeasurable map is kept (once, not once per tick).
freshGuard("ground")
local warnVehicle = {
    spec_aiImplement = { requiredFruitTypes = { { customMapId = "bad_custom" } }, prohibitedFruitTypes = {} },
}
ticks(warnVehicle, 5)
local couldNot = 0
for _, w in ipairs(warnings) do
    if w:find("Could not measure", 1, true) then couldNot = couldNot + 1 end
end
T.eq("A9 an unmeasurable map is reported once, not once per tick", couldNot, 1)

-- A10: a map the engine answers with nil (no error) is a failed measurement too, and is
-- probed once, not every tick.
freshGuard("ground")
local nilVehicle = {
    spec_aiImplement = { requiredFruitTypes = { { customMapId = "nil_custom" } }, prohibitedFruitTypes = {} },
}
ticks(nilVehicle, 5)
T.eq("A10 a map the engine answers with nil is probed once across 5 ticks", calls.nil_custom, 1)

SoilLogger.warning = realWarning
