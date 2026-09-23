-- RSF-F231-scout_entitlement_test.lua
--
-- RSF-F231: anyone who could reach the server could mark any field in the world as
-- scouted (the event handler discarded its own connection and wrote the field id off
-- the wire), and the console printed any field's learned agronomy. The repair brings
-- the field scout to the rule the mod already keeps for walked cells
-- (SpatialScouting.isRevealAuthorized): the acting farm must own the farmland or be
-- contracting its owner, both ordinary. The test sits on the WRITER, so every door
-- gates: the event (farm from the server's own player record), the hotkey, the
-- console scout and the dialog each supply the farm they act for; the console
-- readout gates on the same standing. A refusal writes nothing, flips nothing, sends
-- nothing and broadcasts nothing.
--
-- THE ENTRY-POINT BAR IS GROUP S. The world is engine state a bench may supply: a
-- farmland-owner map (FarmlandManager.lua:275-281, unknown land answers NO_OWNER 0),
-- farms with a contracting table (Farm.lua:476-478), a server player system whose
-- playersByConnection is filled as PlayerSystem:addPlayer fills it (:270) and read
-- as :233-235 reads it, and a local player record (Player.farmId). Nothing the code
-- under test must obtain for itself is hand-populated: no standing verdict, no
-- discovery flag, no console registry. Production is entered where it enters: the
-- real SoilSettingsGUI:registerConsoleCommands registers SoilScout and SoilResistance
-- through addConsoleCommand and the bar invokes them through that registry; the
-- network door is the real SoilScoutFieldEvent driven through a stream round trip,
-- so readStream calls run(connection) as Server.lua:436 does; the hotkey door is the
-- real SoilFertilityManager:onScoutInput; the dialog door is the real
-- SoilScoutDialog:_populate on a stub instance (no GUI is rendered).
--
-- Groups:
--   S  entry points on a listen host whose farm 1 owns fields 1 and 3, farm 2 owns
--      field 2, field 4 is unowned: console SoilScout through the registry, the
--      event through the stream
--   E  the event door: owner admitted and broadcast; a neighbour, a spectator, an
--      unknown connection and unowned land refused silently; a contractor admitted;
--      the host's own farm never stands in for a client's
--   H  the hotkey door: own field opens the dialog; a foreign field warns, opens nothing
--   C  a pure client: no optimistic flip and no event without standing
--   D  a dedicated server: no local farm, so its console refuses; the event still serves
--   R  the console readout gates on the same standing
--   G  the dialog door: a refused panel offers nothing to apply
--   P  privacy: a refused scout never hands over the named disease
--   U  unchanged: the walked-cell rule, the durable fact's shape, existing marks
--   SP singleplayer: the farm scouts the land it owns; land it has not bought (a field
--      mission's field among it) is refused, the reading declared to Design
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/DiseaseSystem.lua, src/ReleaseGate.lua, src/SpatialScouting.lua, src/SoilFertilitySystem.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/hooks/HookManager.lua, src/SoilFertilityManager.lua, src/settings/SoilSettingsGUI.lua, src/ui/SoilScoutDialog.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/network/NetworkEvents.lua

local S, SFS = SpatialScouting, SoilFertilitySystem
-- The dialog's chemical list formats prices through the engine's UIHelper (a GUI helper, not the subject).
UIHelper = UIHelper or { formatCurrencyValue = function(v) return tostring(v) end }

local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ── Engine state (fixture) ─────────────────────────────────────────────────────
-- Soil field ids are farmland ids. Farm 1 owns 1 and 3, farm 2 owns 2, 4 is unowned.
local OWNERS = { [1] = 1, [2] = 2, [3] = 1, [4] = 0 }
-- Farm 3 is contracting for farm 1 (Farm.contractingFor[1] = true).
local CONTRACTS = { [3] = { [1] = true } }

local function installFarmWorld()
  g_farmlandManager = { getFarmlandOwner = function(_, id) return OWNERS[id] or 0 end }
  g_farmManager = { getFarmById = function(_, farmId)
    if type(farmId) ~= "number" or farmId < 1 or farmId > 8 then return nil end
    return { farmId = farmId,
             getIsContractingFor = function(_, other) return (CONTRACTS[farmId] or {})[other] or false end }
  end }
end

--- A server player system shaped as PlayerSystem.lua:233-235 and :270.
local function newPlayerSystem()
  local ps = { playersByConnection = {} }
  function ps:getPlayerByConnection(connection) return self.playersByConnection[connection] end
  function ps:addPlayer(player) self.playersByConnection[player.connection] = player end
  return ps
end

local function newField(extra)
  local f = { activeDisease = "septoria", diseaseDiscovered = false, fieldEverScouted = false,
              diseasePressure = 40, lastCrop = "wheat", resistance = {}, fieldArea = 5, nutrientBuffer = {} }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

local function newSys()
  return setmetatable({ settings = { diseasePressure = true, showNotifications = false },
                        fieldData = { [1] = newField(), [2] = newField(), [3] = newField(), [4] = newField() } },
                      { __index = SFS })
end

local BROADCASTS, WARNINGS, SENT, OPENED = {}, {}, {}, {}
local CURRENT_FIELD = nil

--- A listen host (or dedicated server) world. opts: dedicated, noLocalPlayer, hostFarm.
local function hostWorld(opts)
  opts = opts or {}
  installFarmWorld()
  local ps = newPlayerSystem()
  BROADCASTS, WARNINGS, SENT, OPENED = {}, {}, {}, {}
  g_server = { broadcastEvent = function(_, ev) BROADCASTS[#BROADCASTS + 1] = ev end }
  g_client = nil
  g_dedicatedServer = nil
  if opts.dedicated then g_dedicatedServer = {} end
  g_localPlayer = { farmId = opts.hostFarm or 1 }
  if opts.noLocalPlayer then g_localPlayer = nil end
  g_currentMission = { missionDynamicInfo = { isMultiplayer = not opts.singleplayer }, playerSystem = ps,
                       environment = { currentDay = 1, daysPerPeriod = 1 }, missionInfo = {},
                       hud = { showBlinkingWarning = function(_, text) WARNINGS[#WARNINGS + 1] = text end } }
  local sys = newSys()
  g_SoilFertilityManager = { soilSystem = sys, settings = { enabled = true, diseasePressure = true },
                             soilHUD = { detectCurrentFieldId = function() return CURRENT_FIELD end } }
  return sys, ps
end

--- A pure client world whose local player is `farmId`; the farm world is the synced state.
local function clientWorld(farmId)
  installFarmWorld()
  BROADCASTS, WARNINGS, SENT, OPENED = {}, {}, {}, {}
  g_server = nil
  g_dedicatedServer = nil
  g_client = { getServerConnection = function() return { sendEvent = function(_, ev) SENT[#SENT + 1] = ev end } end }
  g_localPlayer = { farmId = farmId }
  g_currentMission = { missionDynamicInfo = { isMultiplayer = true },
                       environment = { currentDay = 1, daysPerPeriod = 1 }, missionInfo = {},
                       hud = { showBlinkingWarning = function(_, text) WARNINGS[#WARNINGS + 1] = text end } }
  local sys = newSys()
  g_SoilFertilityManager = { soilSystem = sys, settings = { enabled = true, diseasePressure = true },
                             soilHUD = { detectCurrentFieldId = function() return CURRENT_FIELD end } }
  return sys
end

--- A client connection registered on the server's player system, with its farm.
local function join(ps, farmId)
  local connection = { farmId = "never read from here" }
  ps:addPlayer({ connection = connection, farmId = farmId })
  return connection
end

-- ── The production entry points ────────────────────────────────────────────────
-- The console registry, filled by the real registerConsoleCommands.
local REG = {}
addConsoleCommand = function(name, _desc, callback, target) REG[name] = { callback = callback, target = target } end
local gui = SoilSettingsGUI.new()
gui:registerConsoleCommands()
local function console(name, arg)
  local e = REG[name]
  if e == nil then return nil end
  return e.target[e.callback](e.target, arg)
end

--- The network door: the real event through a stream round trip, so readStream runs
--- it with the receiving connection, as Server.lua:436 does.
local function sendScout(connection, fieldId)
  local s = _sfMockStream()
  SoilScoutFieldEvent.new(fieldId):writeStream(s, connection)
  SoilScoutFieldEvent.emptyNew():readStream(s, connection)
  T.eq("scout event: stream drained", s.r, #s.q + 1)
end

--- The hotkey door: the real onScoutInput on a manager whose HUD reports `fieldId`.
local realShow = SoilScoutDialog.show
SoilScoutDialog.show = function(fieldId) OPENED[#OPENED + 1] = fieldId end
local function hotkey(fieldId)
  CURRENT_FIELD = fieldId
  local mgr = setmetatable(g_SoilFertilityManager, { __index = SoilFertilityManager })
  SoilFertilityManager.onScoutInput(mgr)
end

local function flags(sys, fieldId)
  local f = sys.fieldData[fieldId]
  return tostring(f.diseaseDiscovered) .. "/" .. tostring(f.fieldEverScouted)
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
  local sys, ps = hostWorld()
  T.ok("S1 [reached] the real registerConsoleCommands registered SoilScout and SoilResistance",
    REG.SoilScout ~= nil and REG.SoilResistance ~= nil and type(REG.SoilScout.target[REG.SoilScout.callback]) == "function")
  local out = console("SoilScout", "1")
  T.ok("S2 the host's console scouts its own field: the report prints", type(out) == "string" and out:find("Field 1 Scouting Report", 1, true) ~= nil)
  T.eq("S3 and the writer set both flags", flags(sys, 1), "true/true")
  T.eq("S4 and broadcast one field update", #BROADCASTS, 1)
  out = console("SoilScout", "2")
  T.ok("S5 the host's console on a neighbour's field: refused, and it says so", type(out) == "string" and out:find("no standing", 1, true) ~= nil)
  T.eq("S6 nothing written on the neighbour's field", flags(sys, 2), "false/false")
  T.eq("S7 and nothing broadcast", #BROADCASTS, 1)
  -- The event door, from a joined client of farm 2.
  local conn2 = join(ps, 2)
  sendScout(conn2, 2)
  T.eq("S8 a client scouting its own field through the event: written", flags(sys, 2), "true/true")
  T.eq("S9 and broadcast", #BROADCASTS, 2)
  sendScout(conn2, 3)
  T.eq("S10 the same client on the host's field: refused, nothing written", flags(sys, 3), "false/false")
  T.eq("S11 and nothing broadcast, nothing said", #BROADCASTS .. "/" .. #WARNINGS, "2/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- E. THE EVENT DOOR
-- ══════════════════════════════════════════════════════════════════════════
group("E", function()
  local sys, ps = hostWorld()
  local conn1, conn2, conn3, conn0 = join(ps, 1), join(ps, 2), join(ps, 3), join(ps, 0)
  sendScout(conn1, 3)
  T.eq("E1 the owner's client is admitted", flags(sys, 3) .. "/" .. #BROADCASTS, "true/true/1")
  sendScout(conn2, 1)
  T.eq("E2 a neighbour is refused silently", flags(sys, 1) .. "/" .. #BROADCASTS, "false/false/1")
  sendScout(conn0, 2)
  T.eq("E3 a spectator (farm 0) is refused, even on land it names", flags(sys, 2) .. "/" .. #BROADCASTS, "false/false/1")
  sendScout({ stranger = true }, 1)
  T.eq("E4 a connection with no player record is refused, even on the host's own land", flags(sys, 1) .. "/" .. #BROADCASTS, "false/false/1")
  sendScout(conn1, 4)
  T.eq("E5 unowned land is refused for anyone (owner 0 is not ordinary)", flags(sys, 4) .. "/" .. #BROADCASTS, "false/false/1")
  sendScout(conn3, 1)
  T.eq("E6 a farm contracting for the owner is admitted", flags(sys, 1) .. "/" .. #BROADCASTS, "true/true/2")
  -- The host's own farm (1) owns field 3; the client of farm 2 must not inherit it.
  sys.fieldData[3] = newField()
  sendScout(conn2, 3)
  T.eq("E7 the host's local farm never stands in for a client's connection", flags(sys, 3), "false/false")
  -- An event run with no connection at all resolves to the host's own player, as the kneel does.
  SoilScoutFieldEvent.new(3):run(nil)
  T.eq("E8 run with no connection: the host's own farm, which owns field 3", flags(sys, 3), "true/true")
  T.eq("E9 the connection object carried no farm the code could have read", SoilNetworkEvents_FarmIdOfConnection(conn2), 2)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- H. THE HOTKEY DOOR
-- ══════════════════════════════════════════════════════════════════════════
group("H", function()
  local sys = hostWorld()
  hotkey(1)
  T.eq("H1 the hotkey on the host's own field scouts it and opens the dialog", flags(sys, 1) .. "/" .. tostring(OPENED[1]), "true/true/1")
  T.eq("H2 no warning for an admitted scout", #WARNINGS, 0)
  hotkey(2)
  T.eq("H3 the hotkey on a neighbour's field writes nothing", flags(sys, 2), "false/false")
  T.eq("H4 opens nothing", #OPENED, 1)
  T.eq("H5 and warns with the no-standing text", WARNINGS[1], g_i18n:getText("sf_scout_no_standing"))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. A PURE CLIENT
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
  local sys = clientWorld(2)
  hotkey(1)
  T.eq("C1 a client with no standing: no optimistic flip", flags(sys, 1), "false/false")
  T.eq("C2 no event sent, nothing opened, one warning", #SENT .. "/" .. #OPENED .. "/" .. #WARNINGS, "0/0/1")
  hotkey(2)
  T.eq("C3 a client on its own field: the optimistic flip, never the durable bit", flags(sys, 2), "true/false")
  T.eq("C4 one scout event for that field, and the dialog opens", #SENT .. "/" .. tostring(SENT[1] and SENT[1].fieldId) .. "/" .. tostring(OPENED[1]), "1/2/2")
  T.ok("C5 the event on the wire is the scout event (one field id, no farm)", SENT[1].fieldId == 2 and SENT[1].farmId == nil and SENT[1].actingFarmId == nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- D. A DEDICATED SERVER
-- ══════════════════════════════════════════════════════════════════════════
group("D", function()
  local sys, ps = hostWorld({ dedicated = true, noLocalPlayer = true })
  T.eq("D1 a dedicated server has no local farm", SFS.localScoutFarmId(), nil)
  local out = console("SoilScout", "1")
  T.ok("D2 its console cannot scout: refused, says so", type(out) == "string" and out:find("no standing", 1, true) ~= nil)
  T.eq("D3 nothing written", flags(sys, 1), "false/false")
  out = console("SoilResistance", "1")
  T.ok("D4 its readout is refused too", type(out) == "string" and out:find("no standing", 1, true) ~= nil)
  local conn1 = join(ps, 1)
  sendScout(conn1, 1)
  T.eq("D5 a joined owner still scouts through the event", flags(sys, 1) .. "/" .. #BROADCASTS, "true/true/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- R. THE CONSOLE READOUT
-- ══════════════════════════════════════════════════════════════════════════
group("R", function()
  local sys = hostWorld()
  sys.fieldData[1].fieldEverScouted = true
  local out = console("SoilResistance", "1")
  T.ok("R1 the readout on the host's own field prints the scouted state", type(out) == "string" and out:find("Scouted: YES", 1, true) ~= nil)
  out = console("SoilResistance", "2")
  T.ok("R2 on a neighbour's field it prints nothing but the refusal", type(out) == "string" and out:find("no standing", 1, true) ~= nil and out:find("Scouted", 1, true) == nil)
  out = console("SoilResistance", "999")
  T.ok("R3 an unknown field still reads as no soil data", type(out) == "string" and out:find("no soil data", 1, true) ~= nil)
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. THE DIALOG DOOR
-- ══════════════════════════════════════════════════════════════════════════
local function element() return { text = nil, setText = function(self, t) self.text = t end } end
local function dialogFor(fieldId)
  return setmetatable({ _fieldId = fieldId, scoutFieldId = element(), scoutDisease = element(), scoutSci = element(),
                        scoutPressure = element(), scoutReco = element(), scoutSelChem = element(), scoutHint = element() },
                      { __index = SoilScoutDialog })
end
group("G", function()
  local sys = hostWorld()
  local applied = 0
  sys.applyNamedFungicide = function() applied = applied + 1; return true, nil, {} end
  -- The panel's area read is the field-info collaborator, not the subject here.
  sys.getFieldInfo = function(_, fieldId) return { fieldArea = 5 } end
  local d = dialogFor(2)
  SoilScoutDialog._populate(d)
  T.eq("G1 the dialog on a neighbour's field says no standing", d.scoutDisease.text, "Your farm neither owns nor contracts this land. Nothing was scouted.")
  T.eq("G2 and wrote nothing", flags(sys, 2), "false/false")
  SoilScoutDialog.onClickApply(d)
  T.eq("G3 Apply on a refused panel sends nothing", applied, 0)
  d = dialogFor(1)
  SoilScoutDialog._populate(d)
  T.eq("G4 the dialog on the host's own field scouts it", flags(sys, 1), "true/true")
  T.ok("G5 and names the disease", d.scoutDisease.text ~= nil and d.scoutDisease.text ~= "" and d.scoutDisease.text:find("no standing", 1, true) == nil)
  -- The dialog acts for the LOCAL player's farm, not for farm 1: a client of farm 2.
  sys = clientWorld(2)
  sys.getFieldInfo = function(_, fieldId) return { fieldArea = 5 } end
  d = dialogFor(1)
  SoilScoutDialog._populate(d)
  T.eq("G6 on a client of farm 2 the dialog on farm 1's field is refused", flags(sys, 1) .. "/" .. #SENT, "false/false/0")
  d = dialogFor(2)
  SoilScoutDialog._populate(d)
  T.eq("G7 and on its own field it scouts (optimistic flip, one event)", flags(sys, 2) .. "/" .. #SENT, "true/false/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- P. PRIVACY
-- ══════════════════════════════════════════════════════════════════════════
group("P", function()
  local sys = hostWorld()
  local rep, refused = sys:scoutField(2, 1)
  T.eq("P1 a refused scout returns no report at all", tostring(rep) .. "/" .. tostring(refused), "nil/NO_STANDING")
  local later = sys:getScoutReport(2)
  T.eq("P2 and the field reads the same afterwards", tostring(later.discovered), "false")
  -- Once the owner has scouted, the current report is the full truth: a refused door
  -- must not read it back (Bob, #998).
  sys:scoutField(2, 2)
  rep, refused = sys:scoutField(2, 1)
  T.eq("P2b a neighbour refused on a field the owner has scouted still gets no report", tostring(rep) .. "/" .. tostring(refused) .. "/" .. tostring(sys:getScoutReport(2).diseaseId), "nil/NO_STANDING/septoria")
  rep, refused = sys:scoutField(3, nil)
  T.eq("P3 no farm at all is refused, never defaulted to farm 1", tostring(refused) .. "/" .. flags(sys, 3), "NO_STANDING/false/false")
  rep, refused = sys:scoutField(1, 1)
  T.eq("P4 an admitted scout names the disease and returns no refusal", tostring(rep.diseaseId) .. "/" .. tostring(refused), "septoria/nil")
  -- The rule module is the writer's authority; without it the writer fails closed.
  local saved = SpatialScouting
  SpatialScouting = nil
  rep, refused = sys:scoutField(3, 1)
  SpatialScouting = saved
  T.eq("P5 with the rule module absent the writer refuses rather than admits", tostring(refused) .. "/" .. flags(sys, 3), "NO_STANDING/false/false")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- U. UNCHANGED
-- ══════════════════════════════════════════════════════════════════════════
group("U", function()
  T.ok("U1 the walked-cell rule is the same function, unchanged", S.isRevealAuthorized(2, 2, false) and S.isRevealAuthorized(2, 3, true) and not S.isRevealAuthorized(2, 3, false) and not S.isRevealAuthorized(0, 2, true))
  local sys = hostWorld()
  sys:scoutField(1, 1)
  T.eq("U2 the durable fact keeps its shape", type(sys.fieldData[1].fieldEverScouted), "boolean")
  sys.fieldData[2].diseaseDiscovered, sys.fieldData[2].fieldEverScouted = true, true
  sys:scoutField(2, 1)
  T.eq("U3 an existing mark is not cleared by a refused scout", flags(sys, 2), "true/true")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- SP. SINGLEPLAYER
-- ══════════════════════════════════════════════════════════════════════════
-- The reading declared to Design (Bob, #998): a singleplayer farm does not own every
-- field, and the brief's item 4 gives singleplayer no exemption, so land the farm
-- has not bought (a field mission's field among it) is refused exactly as the walk
-- and the kneel already refuse it. Whether singleplayer or an active field mission
-- should give standing is Arissani's question, on the DESIGN-CHECK row.
group("SP", function()
  local sys = hostWorld({ singleplayer = true })
  hotkey(1)
  T.eq("SP1 the singleplayer farm scouts the field it owns", flags(sys, 1) .. "/" .. tostring(OPENED[1]) .. "/" .. #WARNINGS, "true/true/1/0")
  hotkey(4)
  T.eq("SP2 land it has not bought (a field mission's field) is refused: nothing written, the warning shown", flags(sys, 4) .. "/" .. #OPENED .. "/" .. #WARNINGS, "false/false/1/1")
  local out = console("SoilScout", "4")
  T.ok("SP3 and the console says no standing on it", type(out) == "string" and out:find("no standing", 1, true) ~= nil)
  T.eq("SP4 no broadcast in singleplayer either way", #BROADCASTS, 0)
end)

SoilScoutDialog.show = realShow
