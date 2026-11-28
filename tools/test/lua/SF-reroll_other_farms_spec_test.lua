-- SF-reroll_other_farms_spec_test.lua: SoilRerollUnownedFields keeps EVERY farm's soil.
--
-- THE BUG. rerollUnownedFields kept a field only when its owner equalled
-- g_currentMission:getFarmId(), the farm running the command. On a multiplayer host that
-- is the host's farm, so every field owned by farms 2..n was re-rolled with the open
-- land: their N/P/K/pH/OM and fertilizerApplied were reset and the console then saved.
--
-- THE RULE. A field is re-rolled only when FarmlandManager:getFarmlandOwner answers
-- NO_OWNER_FARM_ID (0), the engine's answer for land nobody has bought
-- (FarmlandManager.lua getFarmlandOwner: nil id or unmapped id -> NO_OWNER_FARM_ID).
-- Anything else (a farm id, nil, a string, a getter that raises) is kept. No farmland
-- manager at all aborts. NPC-managed open land is still kept (B5).
--
-- The world here: farmland 1 is the host's (farm 1), 2 is farm 2's, 3 is farm 5's, 4 and 5
-- are open land, 6 is open NPC ground. The re-roll's helpers are recorded, not run: this
-- bar is about WHICH fields are touched. SF-79-reroll_ph_routing_test.lua covers what a
-- re-roll writes to the pH map.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/SoilFertilitySystem.lua, src/settings/SoilSettingsGUI.lua

local SFS = SoilFertilitySystem
SoilLogger.info = function() end
SoilLogger.debug = function() end
local WARN = {}
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end

local saved = { fm = g_farmlandManager, npc = NpcSoilBridge, ta = TargetApplication,
                getFarmId = g_currentMission and g_currentMission.getFarmId, FM = FarmlandManager }

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local OWNERS = { [1] = 1, [2] = 2, [3] = 5, [4] = 0, [5] = 0, [6] = 0 }

local function soil(n)
    return { nitrogen = n, phosphorus = n, potassium = n, organicMatter = 3.0, pH = 6.5,
             fertilizerApplied = 900, zoneData = { keep = true } }
end

-- A system whose re-roll helpers record the field they were called for.
local function newSys(fieldData)
    local touched = {}
    local sys = setmetatable({ fieldData = fieldData }, { __index = SFS })
    sys._computeInitialSoil = function(_, id)
        touched[#touched + 1] = id
        return { nitrogen = 11, phosphorus = 12, potassium = 13, organicMatter = 1.5, pH = 5.5 }
    end
    sys._prePopulateZoneData = function() end
    sys.vmSeedField = function() end
    sys._phRerollField = function() end
    return sys, touched
end

local function world(owners, getFarmId)
    g_farmlandManager = { getFarmlandOwner = function(_, id)
        if id == nil or owners[id] == nil then return 0 end
        return owners[id]
    end }
    NpcSoilBridge = { isNPCManaged = function(_, id) return id == 6 end }
    TargetApplication = nil
    g_currentMission.getFarmId = function() return getFarmId end
end

local function sixFields()
    local fd = {}
    for id = 1, 6 do fd[id] = soil(70) end
    return fd
end

local function sorted(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    return table.concat(c, ",")
end

-- ── R1: listen-server host (farm 1). Other farms' fields are kept. ─────────────
group("R1", function()
    world(OWNERS, 1)
    local fd = sixFields()
    local sys, touched = newSys(fd)
    local rerolled, skipped = sys:rerollUnownedFields()
    T.eq("R1a only the open, non-NPC land is re-rolled", sorted(touched), "4,5")
    T.eq("R1b counts: 2 re-rolled, 4 kept", tostring(rerolled) .. "/" .. tostring(skipped), "2/4")
    for _, id in ipairs({ 2, 3 }) do
        local f = fd[id]
        T.eq("R1c farm-owned field " .. id .. " keeps its N/P/K/pH/OM",
             string.format("%g/%g/%g/%g/%g", f.nitrogen, f.phosphorus, f.potassium, f.pH, f.organicMatter),
             "70/70/70/6.5/3")
        T.eq("R1d farm-owned field " .. id .. " keeps fertilizerApplied and zone data",
             tostring(f.fertilizerApplied) .. "/" .. tostring(f.zoneData.keep), "900/true")
    end
    T.eq("R1e the host's own field is kept", fd[1].nitrogen, 70)
    T.eq("R1f open land took the new roll", fd[4].nitrogen .. "/" .. fd[4].fertilizerApplied, "11/0")
    T.eq("R1g open NPC ground is kept (B5)", fd[6].nitrogen, 70)
end)

-- ── R2: whoever runs it, the result is the same. A dedicated server (farm id 0) used to
-- abort; it now re-rolls exactly the open land too, and a farm-2 host keeps farm 1's. ──
group("R2", function()
    for _, runner in ipairs({ 0, 2, nil }) do
        world(OWNERS, runner)
        local fd = sixFields()
        local sys, touched = newSys(fd)
        sys:rerollUnownedFields()
        T.eq("R2 runner farm " .. tostring(runner) .. ": only open land re-rolled", sorted(touched), "4,5")
    end
end)

-- ── R3: owner answers that are not a clean 0 fail CLOSED (kept). ───────────────
group("R3", function()
    local odd = { [1] = nil, [2] = "0", [3] = -1, [4] = 0, [5] = 0.0, [6] = 0 }
    WARN = {}
    g_farmlandManager = { getFarmlandOwner = function(_, id)
        if id == 1 then return nil end
        if id == 3 then error("engine raised") end
        return odd[id]
    end }
    NpcSoilBridge = nil
    local fd = sixFields()
    local sys, touched = newSys(fd)
    local ok, rerolled, skipped = pcall(sys.rerollUnownedFields, sys)
    T.ok("R3a a getter that raises does not abort the whole re-roll", ok)
    -- 4, 5 (0.0 == 0 in Lua) and 6 (NPC bridge absent) are open; 1 nil, 2 "0", 3 raised are kept
    T.eq("R3b nil, a string and a raising getter are all kept", sorted(touched), "4,5,6")
    T.eq("R3c counts", tostring(rerolled) .. "/" .. tostring(skipped), "3/3")
end)

-- ── R4: no farmland manager -> abort, nothing touched. ────────────────────────
group("R4", function()
    for _, fm in ipairs({ "nil", "no-method" }) do
        g_farmlandManager = (fm == "nil") and nil or {}
        WARN = {}
        local fd = sixFields()
        local sys, touched = newSys(fd)
        local rerolled, why = sys:rerollUnownedFields()
        T.eq("R4a " .. fm .. ": nothing re-rolled, abort signalled", #touched .. "/" .. tostring(rerolled), "0/nil")
        T.ok("R4d " .. fm .. ": the abort says why", type(why) == "string" and why:find("farmland manager") ~= nil)
        T.eq("R4b " .. fm .. ": every field unchanged", fd[4].nitrogen, 70)
        T.ok("R4c " .. fm .. ": a warning says why", #WARN == 1 and WARN[1]:find("aborting") ~= nil)
    end
end)

-- ── R5: the engine's own NO_OWNER_FARM_ID is the reference value when it exists. ──
group("R5", function()
    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    world(OWNERS, 1)
    local fd = sixFields()
    local sys, touched = newSys(fd)
    sys:rerollUnownedFields()
    T.eq("R5 with FarmlandManager.NO_OWNER_FARM_ID defined, the same fields", sorted(touched), "4,5")
    FarmlandManager = saved.FM
g_SoilFertilityManager, g_currentMission.getIsServer, SoilNetworkEvents_BroadcastFieldUpdate = saveMgr, saveIsServer, saveBcast
end)

-- ── R6: entries that are not fields are ignored, as before. ───────────────────
group("R6", function()
    world(OWNERS, 1)
    local fd = sixFields()
    fd.meta = soil(70)
    fd[7] = "not a table"
    local sys, touched = newSys(fd)
    sys:rerollUnownedFields()
    T.eq("R6 a string key and a non-table entry are skipped silently", sorted(touched), "4,5")
end)

-- ── R7: an NPC bridge that raises keeps the field and does not abort the run. ──
group("R7", function()
    world(OWNERS, 1)
    NpcSoilBridge = { isNPCManaged = function(_, id) if id == 5 then error("bridge raised") end return id == 6 end }
    local fd = sixFields()
    local sys, touched = newSys(fd)
    local ok = pcall(sys.rerollUnownedFields, sys)
    T.ok("R7a a raising NPC bridge does not abort the re-roll", ok)
    T.eq("R7b the field it raised on is kept; other open land is re-rolled", sorted(touched), "4")
end)

-- ── R8: the console door. An abort is reported as one and saves nothing; a re-roll
-- saves and sends the re-rolled fields (and only those) to joined clients. ─────────
local saveMgr, saveIsServer, saveBcast = g_SoilFertilityManager, g_currentMission.getIsServer, SoilNetworkEvents_BroadcastFieldUpdate
group("R8", function()
    local saves, sent = 0, {}
    g_currentMission.getIsServer = function() return true end
    SoilNetworkEvents_BroadcastFieldUpdate = function(id, field)
        sent[#sent + 1] = tostring(id) .. (type(field) == "table" and "" or "!nofield")
    end
    local fd = sixFields()
    local sys = newSys(fd)
    g_SoilFertilityManager = { soilSystem = sys, saveSoilData = function() saves = saves + 1 end }
    local gui = setmetatable({}, { __index = SoilSettingsGUI })

    g_farmlandManager = nil
    local msg = gui:consoleCommandRerollUnownedFields()
    T.ok("R8a an abort says so", msg:find("aborted", 1, true) ~= nil and msg:find("saved", 1, true) == nil)
    T.eq("R8b and neither saves nor sends", saves .. "/" .. #sent, "0/0")

    world(OWNERS, 1)
    msg = gui:consoleCommandRerollUnownedFields()
    T.ok("R8c a re-roll reports its counts", msg:find("2 field", 1, true) ~= nil and msg:find("no farm owns", 1, true) ~= nil)
    table.sort(sent)
    T.eq("R8d saves once and sends exactly the re-rolled fields, with their data", saves .. "/" .. table.concat(sent, ","), "1/4,5")

    local allOwned = {}
    for id, owner in pairs(OWNERS) do allOwned[id] = (owner == 0) and 9 or owner end
    world(allOwned, 1)
    sent = {}
    gui:consoleCommandRerollUnownedFields()
    T.eq("R8e nothing re-rolled: saved, nothing sent", saves .. "/" .. #sent, "2/0")
end)

-- ── R9: NPC ground answered with a truthy non-boolean is still kept. ───────────
group("R9", function()
    world(OWNERS, 1)
    NpcSoilBridge = { isNPCManaged = function(_, id) if id == 5 then return 3 end return nil end }  -- an npc id
    local fd = sixFields()
    local sys, touched = newSys(fd)
    sys:rerollUnownedFields()
    T.eq("R9 a truthy NPC answer keeps the field", sorted(touched), "4,6")
end)

g_farmlandManager, NpcSoilBridge, TargetApplication = saved.fm, saved.npc, saved.ta
if g_currentMission then g_currentMission.getFarmId = saved.getFarmId end
FarmlandManager = saved.FM
g_SoilFertilityManager, g_currentMission.getIsServer, SoilNetworkEvents_BroadcastFieldUpdate = saveMgr, saveIsServer, saveBcast
