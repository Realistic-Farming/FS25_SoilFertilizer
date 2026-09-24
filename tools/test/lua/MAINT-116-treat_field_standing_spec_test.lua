-- MAINT-116-treat_field_standing_spec_test.lua
--
-- MAINTENANCE row 116: the menu fungicide treatment (SoilTreatFieldEvent, the SoilTreat
-- console command, the scout dialog's Apply) acts only for the farm that asked, on a
-- field that farm owns or is contracting for, and charges that farm alone. The test
-- sits on the WRITER, applyNamedFungicide, as RSF-F231 put the scout's: every door
-- supplies the farm it acts for, the network door from the server's own player record
-- (FSBaseMission:getFarmId, modelled line for line), the console and the dialog from
-- the local player. A refusal writes nothing, charges nobody, broadcasts nothing. The
-- charge has no fallback: a treatment with no farm is refused before any write.
--
-- The world is engine state a bench may supply (as RSF-F231's): a farmland-owner map
-- (FarmlandManager.lua:275-281, unknown land answers 0), farms with a contracting
-- table (Farm.lua:476-478) behind the engine's canFarmAccessOtherId
-- (AccessHandler.lua:35-49), a mission whose getFarmId reads its player records
-- (FSBaseMission.lua:1067-1085, :1098) and whose addMoney records every charge. Nothing
-- the code under test must obtain for itself is hand-populated: no standing verdict,
-- no charge, no pressure. The network door is the real SoilTreatFieldEvent through a
-- stream round trip; the console door is the real consoleCommandTreat; the dialog door
-- is the real SoilScoutDialog:onClickApply on a stub instance (no GUI is rendered).
--
--!env: modenv
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/DiseaseSystem.lua, src/ReleaseGate.lua, src/SpatialScouting.lua, src/SoilFertilitySystem.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/hooks/HookManager.lua, src/SoilFertilityManager.lua, src/settings/SoilSettingsGUI.lua, src/ui/SoilScoutDialog.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/network/NetworkEvents.lua

local SFS = SoilFertilitySystem
UIHelper = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }
MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1 }   -- the engine's enum; only its presence matters here
local INFO, WARN = {}, {}
SoilLogger.info = function(fmt, ...) INFO[#INFO + 1] = string.format(fmt, ...) end
SoilLogger.debug = function() end
SoilLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
SoilLogger.error = function(fmt, ...) WARN[#WARN + 1] = "ERROR " .. string.format(fmt, ...) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── engine state ────────────────────────────────────────────────────────────
-- Soil field ids are farmland ids. Farm 1 owns 1 and 3, farm 2 owns 2, 4 is unowned.
-- PROTHIOCONAZOLE is a menu chemical (not one of the physical tank products every door
-- turns away before the writer).
local OWNERS = { [1] = 1, [2] = 2, [3] = 1, [4] = 0 }
-- Farm 3 is contracting for farm 1 (Farm.contractingFor[1] = true).
local CONTRACTS = { [3] = { [1] = true } }
AccessHandler = { EVERYONE = 0, NOBODY = 2 ^ 4 - 1 }
local function farmWorld()
    g_farmlandManager = { getFarmlandOwner = function(_, id) return OWNERS[id] or 0 end }
    g_farmManager = { getFarmById = function(_, farmId)
        if type(farmId) ~= "number" or farmId < 1 or farmId > 8 then return nil end
        return { farmId = farmId, getIsContractingFor = function(_, other) return (CONTRACTS[farmId] or {})[other] or false end }
    end }
end
-- AccessHandler.lua:35-49, as decompiled.
local function accessHandler()
    return { canFarmAccessOtherId = function(_, farmId, objectFarmId)
        if objectFarmId == AccessHandler.EVERYONE then return true
        elseif objectFarmId == AccessHandler.NOBODY then return false
        elseif objectFarmId == farmId then return true
        else
            local f = g_farmManager:getFarmById(farmId)
            if f == nil then return false end
            return f:getIsContractingFor(objectFarmId)
        end
    end }
end
local function conn(isServer, streamId)
    return { isServer = isServer, streamId = streamId,
        getIsServer = function(self) return self.isServer end,
        getIsLocal = function(self) return self.streamId == 0 end }
end
local FROM_FARM1, FROM_FARM2, FROM_FARM3, UNPLAYERED = conn(false, 7), conn(false, 8), conn(false, 9), conn(false, 10)
local AT_CLIENT_FROM_SERVER = conn(true, 1)

local function newField()
    return { activeDisease = "septoria", diseaseDiscovered = true, fieldEverScouted = true, diseasePressure = 40,
             fungicideDaysLeft = 0, lastCrop = "wheat", resistance = {}, fieldArea = 5, nutrientBuffer = {}, zoneData = {} }
end
local W = {}
local function newSys(singleplayer)
    return setmetatable({
        settings = { diseasePressure = true, fertilizerCosts = true, weatherSource = 1, diseaseMoisture = 2, diseaseDifficulty = 2,
                     showNotifications = false, debugMode = false, enabled = true },
        fieldData = { [1] = newField(), [2] = newField(), [3] = newField(), [4] = newField() },
        fungicideAppliedDay = {},
    }, { __index = SFS })
end
--- side: "host" (a listen host), "client" (a pure client of opts.farm), "dedi" (a
--- dedicated server, no local player) or "sp" (singleplayer). The mission's player
--- records: farm 1, farm 2 and farm 3 connections.
local function world(side, opts)
    opts = opts or {}
    farmWorld()
    W.charges, W.broadcasts, W.sent = {}, {}, {}
    local server = { broadcastEvent = function(_, ev) W.broadcasts[#W.broadcasts + 1] = ev end }
    local client = { getServerConnection = function() return { sendEvent = function(_, ev) W.sent[#W.sent + 1] = ev end } end }
    if side == "host" then g_server, g_client = server, client
    elseif side == "client" then g_server, g_client = nil, client
    elseif side == "dedi" then g_server, g_client = server, nil
    else g_server, g_client = server, client end
    g_dedicatedServer = side == "dedi" and {} or nil
    g_localPlayer = (side ~= "dedi") and { farmId = opts.farm or 1 } or nil
    local mission = {
        environment = { currentDay = 5, currentSeason = 2, daysPerPeriod = 1 },
        missionDynamicInfo = { isMultiplayer = side ~= "sp" },
        missionInfo = {},
        connectionsToPlayer = { [FROM_FARM1] = { farmId = 1 }, [FROM_FARM2] = { farmId = 2 }, [FROM_FARM3] = { farmId = 3 } },
        hud = { showBlinkingWarning = function() end },
        accessHandler = accessHandler(),
        addMoney = function(_, amount, farmId, moneyType) W.charges[#W.charges + 1] = { amount = amount, farmId = farmId, moneyType = moneyType } end,
        getIsServer = function() return g_server ~= nil end,
        getPlayerByConnection = function(self, c) return self.connectionsToPlayer[c] end,
    }
    mission.getFarmId = function(self, connection)   -- FSBaseMission.lua:1067-1085
        if self:getIsServer() then
            if g_localPlayer == nil or connection ~= nil then
                if connection == nil then return nil end
                local player = self:getPlayerByConnection(connection)
                if player == nil then return nil end
                return player.farmId
            else
                return g_localPlayer.farmId
            end
        else
            return g_localPlayer == nil and 0 or g_localPlayer.farmId
        end
    end
    g_currentMission = mission
    local sys = newSys()
    sys.getFieldInfo = function(_, fieldId) return { fieldArea = 5 } end   -- the dialog's area read, a collaborator
    g_SoilFertilityManager = { soilSystem = sys, settings = sys.settings, soilHUD = { detectCurrentFieldId = function() return nil end } }
    W.sys = sys
    return sys
end
local function pressure(fieldId) return W.sys.fieldData[fieldId].diseasePressure end
--- Treated: the writer stamps the chemical and the protection days on the field.
local function treated(fieldId)
    local f = W.sys.fieldData[fieldId]
    return f.lastFungicide == "PROTHIOCONAZOLE" and (f.fungicideDaysLeft or 0) > 0
end
local function charged()
    local out = {}
    for _, c in ipairs(W.charges) do out[#out + 1] = c.farmId .. (c.amount < 0 and "-" or "+") end
    return table.concat(out, ",")
end
local function deliver(fieldId, connection)
    local s = _sfMockStream()
    SoilTreatFieldEvent.new(fieldId, "PROTHIOCONAZOLE"):writeStream(s, connection)
    SoilTreatFieldEvent.emptyNew():readStream(s, connection)
    return _sfStreamFaults(s)
end
local function element() return { text = nil, setText = function(self, t) self.text = t end } end
local function dialogFor(fieldId)
    return setmetatable({ _fieldId = fieldId, _chemList = { "PROTHIOCONAZOLE" }, _chemIdx = 1,
                          scoutFieldId = element(), scoutDisease = element(), scoutSci = element(), scoutPressure = element(),
                          scoutReco = element(), scoutSelChem = element(), scoutHint = element() },
                        { __index = SoilScoutDialog })
end

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE NETWORK DOOR ON A LISTEN HOST
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
    world("host")
    local faults = deliver(1, FROM_FARM2)
    T.eq("E1 farm 2's client treating farm 1's field is refused: no write, no charge, no broadcast (the stream itself is clean)",
        pressure(1) .. "/" .. #W.charges .. "/" .. #W.broadcasts .. "/" .. faults, "40/0/0/0")
    deliver(1, FROM_FARM1)
    T.eq("E2 the owner's client treats its field: the chemical stamped, protection on, its own farm charged once, the field broadcast",
        tostring(treated(1)) .. "/" .. tostring(pressure(1) <= 40) .. "/" .. charged() .. "/" .. #W.broadcasts, "true/true/1-/1")
    deliver(3, FROM_FARM3)
    T.eq("E3 farm 3, contracting for farm 1, treats farm 1's field 3 and its own farm pays", tostring(treated(3)) .. "/" .. charged(), "true/1-,3-")
    deliver(2, FROM_FARM3)
    T.eq("E4 the same contractor is refused on farm 2's field", pressure(2) .. "/" .. charged(), "40/1-,3-")
    deliver(1, UNPLAYERED)
    T.eq("E5 a connection with no player record is refused, and the host is never billed for it", charged() .. "/" .. #W.broadcasts, "1-,3-/2")
    deliver(4, FROM_FARM1)
    T.eq("E6 unowned land is nobody's to treat", pressure(4) .. "/" .. charged(), "40/1-,3-")
    world("dedi")
    deliver(2, FROM_FARM2)
    deliver(1, FROM_FARM2)
    T.eq("E7 a dedicated server applies the same rule: own field treated and charged, the other's refused", tostring(treated(2)) .. "/" .. tostring(treated(1)) .. "/" .. charged(), "true/false/2-")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. THE LOCAL DOORS ACT FOR THIS MACHINE'S FARM
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    world("host")
    local out = SoilSettingsGUI.consoleCommandTreat({}, "PROTHIOCONAZOLE", "3")
    T.eq("L1 the host's console treats its own field and its farm pays", tostring(treated(3)) .. "/" .. charged() .. "/" .. tostring(type(out) == "string" and out:find("no standing", 1, true) == nil), "true/1-/true")
    out = SoilSettingsGUI.consoleCommandTreat({}, "PROTHIOCONAZOLE", "2")
    T.eq("L2 the host's console on farm 2's field is refused with the standing line, nothing written or charged",
        pressure(2) .. "/" .. charged() .. "/" .. tostring(out), "40/1-/Field 2: no standing (this machine's farm neither owns nor contracts the land); nothing treated")
    local d = dialogFor(1)
    SoilScoutDialog.onClickApply(d)
    T.eq("L3 the host's dialog treats its own field (the panel then re-populates, so the hint is the panel's)", tostring(treated(1)) .. "/" .. charged(), "true/1-,1-")
    d = dialogFor(2)
    SoilScoutDialog.onClickApply(d)
    T.eq("L4 the host's dialog on farm 2's field is refused with the standing hint", pressure(2) .. "/" .. charged() .. "/" .. tostring(d.scoutHint.text),
        "40/1-,1-/Your farm neither owns nor contracts this land. Nothing was treated.")
    world("dedi")
    out = SoilSettingsGUI.consoleCommandTreat({}, "PROTHIOCONAZOLE", "1")
    T.eq("L5 a dedicated server's console has no farm and is refused on any field, nobody charged", pressure(1) .. "/" .. #W.charges .. "/" .. tostring(out:find("no standing", 1, true) ~= nil), "40/0/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A PURE CLIENT
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    world("client", { farm = 2 })
    local d = dialogFor(2)
    SoilScoutDialog.onClickApply(d)
    T.eq("C1 a client of farm 2 on its own field sends the request and writes nothing locally",
        #W.sent .. "/" .. tostring(W.sent[1] and W.sent[1].fieldId) .. "/" .. tostring(treated(2)) .. "/" .. #W.charges, "1/2/false/0")
    d = dialogFor(1)
    SoilScoutDialog.onClickApply(d)
    T.eq("C2 on farm 1's field it is refused locally against the synced owner, nothing sent", #W.sent .. "/" .. tostring(d.scoutHint.text), "1/Your farm neither owns nor contracts this land. Nothing was treated.")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. NO FARM, NO TREATMENT, NO FALLBACK
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    world("host")
    local ok, key = W.sys:applyNamedFungicide(1, "PROTHIOCONAZOLE", { charge = true })
    T.eq("N1 the writer with no farm refuses before any write and charges nobody (no fallback to the host's farm or farm 1)",
        tostring(ok) .. "/" .. tostring(key) .. "/" .. pressure(1) .. "/" .. #W.charges, "false/sf_treat_no_standing/40/0")
    ok, key = W.sys:applyNamedFungicide(1, "PROTHIOCONAZOLE", { charge = true, farmId = 0 })
    T.eq("N2 farm 0 (a spectator) is refused the same way", tostring(ok) .. "/" .. tostring(key) .. "/" .. #W.charges, "false/sf_treat_no_standing/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- SP. SINGLEPLAYER: THE FARM TREATS THE LAND IT OWNS
-- ══════════════════════════════════════════════════════════════════════════
group("SP", function()
    world("sp")
    local out = SoilSettingsGUI.consoleCommandTreat({}, "PROTHIOCONAZOLE", "1")
    T.eq("SP1 in singleplayer the console treats an owned field and charges farm 1", tostring(treated(1)) .. "/" .. charged(), "true/1-")
    out = SoilSettingsGUI.consoleCommandTreat({}, "PROTHIOCONAZOLE", "4")
    T.eq("SP2 land the farm has not bought is refused (the reading declared in the PR)", pressure(4) .. "/" .. tostring(out:find("no standing", 1, true) ~= nil), "40/true")
end)

T.summary()
