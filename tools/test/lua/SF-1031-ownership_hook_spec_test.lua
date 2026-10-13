-- SF-1031-ownership_hook_spec_test.lua: #1031, the ownership hook runs on a live buy
-- or sell.
--
-- HookManager:installOwnershipHook subscribes onOwnerChanged to
-- FARMLAND_OWNER_CHANGED with the HookManager as the callback target. With a target
-- the engine calls callback(target, ...) (MessageCenter.lua:100-101), and the publish
-- is (farmlandId, farmId, loadFromSavegame) (FarmlandManager.lua:320). The handler
-- had no target parameter, so loadFromSavegame received the farm id, 1 on a buy and
-- 0 on a sell, both truthy in Lua, and every live change returned unhandled: a bought
-- field never joined the active set until a reload, a sold one never left it.
--
-- ENTRY-POINT BAR: nothing below calls onOwnerChanged or onFieldOwnershipChanged.
--   * The world is built by the real SoilFertilitySystem:scanFields over the map's
--     fields, which creates every field's record and the initial active set from
--     ownership, as at load. No fieldData or activeFieldIds entry is written by hand.
--   * A buy or sell goes through a model of the engine's
--     FarmlandManager:setLandOwnership (:303-322), which publishes through a model
--     of the engine's MessageCenter (subscribe :24-37, unsubscribeAll :62-73, publish
--     :81-111) to the subscription the real installOwnershipHook made.
--   * Group S pins the model's dispatch shape (target first), so a model that calls
--     callback(...) without the target, and could not fail the way production
--     failed, would fail here instead.
--
--   S  the dispatch shape: the hook subscribed with the HookManager as target, and
--      a targeted subscriber receives (target, farmlandId, farmId, loadFromSavegame)
--   B  a live buy (single player or host): the field joins the active set, on the
--      record scanFields made
--   L  load (loadFromSavegame true): skipped
--   X  a live sell: the field leaves the active set, its layer colours are cleared,
--      its soil data is kept
--   N  a sell of NPC-managed ground: it stays active
--   C  a pure multiplayer client (the #1031 MP check): with the server's records
--      synced, a buy joins the client's own active set (the map overlay's input,
--      rebuilt the same way at join, NetworkEvents.lua:1064-1071) and a sell leaves
--      it; before the sync, a buy creates no record (getOrCreateField's client guard)
--   U  cleanup: uninstallAll unsubscribes by target and a later change reaches nothing
--
-- Targeted mutation: drop `_target`; B, X and C's joins and leaves must fail.
--
-- Not proven here: the engine's FarmlandStateEvent routing (read, not run: a client
-- calls setLandOwnership when the server's event arrives, FarmlandStateEvent.lua:30-31,
-- and the host through its broadcast to the local connection, :64 and
-- Server.lua:544), the daily simulation of a joined field, and the map overlay
-- drawing it.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/NpcSoilBridge.lua, src/hooks/HookManager.lua

-- A group that raises is reported as a named failing row, so a crash stays attributable.
local function group(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

local saved = {
  mc = g_messageCenter, mt = MessageType, flm = g_farmlandManager, fm = g_fieldManager,
  sfm = g_SoilFertilityManager, server = g_server, mdi = g_currentMission.missionDynamicInfo,
  npc = g_currentMission.npcFavorSystem, logErr = SoilLogger.error,
}

MessageType = MessageType or {}
MessageType.FARMLAND_OWNER_CHANGED = MessageType.FARMLAND_OWNER_CHANGED or "FARMLAND_OWNER_CHANGED"
local OWNER_CHANGED = MessageType.FARMLAND_OWNER_CHANGED

-- ── Engine model: MessageCenter (MessageCenter.lua, FS25 decompile) ─────────────
-- Two decompile artifacts are written as the engine means them: subscribe inserts
-- into the table it has just created, and publish advances past a kept subscriber.
local function newMessageCenter()
  local mc = { subscribers = {} }
  function mc:subscribe(messageType, callback, callbackTarget, argument, isOneShot)
    if messageType == nil or callback == nil then return end
    local subscribers = self.subscribers[messageType]
    if subscribers == nil then
      subscribers = {}
      self.subscribers[messageType] = subscribers
    end
    table.insert(subscribers, {
      callback = callback, callbackTarget = callbackTarget,
      argument = argument, isOneShot = isOneShot == true,
    })
  end
  function mc:unsubscribeAll(callbackTarget)
    for k, subscribers in pairs(self.subscribers) do
      for i = #subscribers, 1, -1 do
        if subscribers[i].callbackTarget == callbackTarget then table.remove(subscribers, i) end
      end
      if #subscribers == 0 then self.subscribers[k] = nil end
    end
  end
  function mc:publish(messageType, ...)
    local subscribers = self.subscribers[messageType]
    if subscribers == nil then return end
    local i = 1
    while true do
      local info = subscribers[i]
      if info == nil then break end
      if info.callbackTarget == nil then
        if info.argument == nil then info.callback(...) else info.callback(info.argument, ...) end
      elseif info.argument == nil then
        info.callback(info.callbackTarget, ...)
      else
        info.callback(info.callbackTarget, info.argument, ...)
      end
      if info.isOneShot then table.remove(subscribers, i) else i = i + 1 end
    end
  end
  return mc
end

-- ── Engine model: FarmlandManager (economy/FarmlandManager.lua, FS25 decompile) ─
local NO_OWNER = 0          -- FarmlandManager.NO_OWNER_FARM_ID (:2)
local NOT_BUYABLE = 255     -- FarmlandManager.NOT_BUYABLE_FARM_ID (:4, 8 bits)
local function newFarmlandManager(ids)
  local flm = { farmlands = {}, farmlandMapping = {} }
  for _, id in ipairs(ids) do flm.farmlands[id] = { id = id, areaInHa = 2.0 } end
  function flm:getFarmlandById(id) return self.farmlands[id] end
  function flm:getIsValidFarmlandId(id)                                    -- :296-302
    if id == nil or id == 0 or id < 0 then return false end
    return self:getFarmlandById(id) ~= nil
  end
  function flm:getFarmlandOwner(id)                                        -- :275-281
    if id == nil or self.farmlandMapping[id] == nil then return NO_OWNER end
    return self.farmlandMapping[id]
  end
  function flm:setLandOwnership(farmlandId, farmId, loadFromSavegame)      -- :303-322
    if not self:getIsValidFarmlandId(farmlandId) then return false end
    if farmId == nil or farmId < NO_OWNER or farmId == NOT_BUYABLE then return false end
    local farmland = self:getFarmlandById(farmlandId)
    if farmland == nil then return false end
    if loadFromSavegame == nil then loadFromSavegame = false end
    self.farmlandMapping[farmlandId] = farmId
    g_messageCenter:publish(MessageType.FARMLAND_OWNER_CHANGED, farmlandId, farmId, loadFromSavegame)
    return true
  end
  return flm
end

-- ── The world ───────────────────────────────────────────────────────────────────
--- The soil system shell: the constructor fields the paths under test touch
--- (SoilFertilitySystem.lua:242-244 for the active set), as deferred_scan_retry does.
local function newSystem()
  local s = setmetatable({}, { __index = SoilFertilitySystem })
  s.settings = { enabled = true }
  s.fieldData = {}
  s.genesisActive = false
  s.genesisSeed = 0
  s.fieldsScanPending = false
  s.scanRetryTimer = 0
  s.scanRetryAttempts = 0
  s.activeFieldIds = {}
  s._activeFieldList = {}
  s._activeListDirty = false
  s.cleared = {}
  -- The GRLE layer system is a collaborator: record what it is asked to do.
  s.layerSystem = {
    available = true,
    readFieldFromLayers = function() return true end,
    writeFieldToLayers = function() end,
    clearFieldFromLayers = function(_, fieldId) s.cleared[#s.cleared + 1] = fieldId end,
  }
  return s
end

--- farmlands 7, 8 and 9 on the map; 9 is owned by farm 1 in the savegame.
--- asClient: the peer is a pure multiplayer client. synced: the server's records
--- have arrived (a client's own scanFields skips, SoilFertilitySystem.lua:3017-3024).
local function newWorld(opts)
  opts = opts or {}
  local errors = {}
  SoilLogger.error = function(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
  g_messageCenter = newMessageCenter()
  g_farmlandManager = newFarmlandManager({ 7, 8, 9 })
  g_fieldManager = { fields = {} }
  for _, id in ipairs({ 7, 8, 9 }) do
    g_fieldManager.fields[#g_fieldManager.fields + 1] = { farmland = g_farmlandManager.farmlands[id], areaHa = 2.0 }
  end
  g_currentMission.npcFavorSystem = nil
  local sys = newSystem()
  g_SoilFertilityManager = { settings = { enabled = true }, soilSystem = sys }

  -- The savegame's ownership is read before the hook exists (loadFromSavegame true).
  g_farmlandManager:setLandOwnership(9, 1, true)

  -- The load scan, as the server (or single player) runs it.
  g_server = {}
  g_currentMission.missionDynamicInfo = { isMultiplayer = opts.asClient == true }
  if opts.asClient and not opts.synced then
    g_server = nil                     -- the client's own scan skips and waits for sync
  end
  sys:scanFields()
  if opts.asClient then
    g_server = nil                     -- from here on this peer is a pure client
  end

  local hm = HookManager.new()
  local installed = hm:installOwnershipHook()
  return sys, hm, installed, errors
end

local function isActive(sys, id) return sys.activeFieldIds[id] == true end

-- ── S: the dispatch shape ───────────────────────────────────────────────────────
group("S dispatch shape", function()
  local sys, hm, installed = newWorld()
  T.eq("S1 [reached: the real installOwnershipHook installed]", installed, true)
  local subs = g_messageCenter.subscribers[OWNER_CHANGED] or {}
  T.eq("S2 one subscription on FARMLAND_OWNER_CHANGED", #subs, 1)
  T.ok("S3 NAMED: its target is the HookManager (cleanup is unsubscribeAll(self))", subs[1] and subs[1].callbackTarget == hm)
  -- The model delivers target first, exactly as the engine does.
  local probeTarget, got = {}, nil
  g_messageCenter:subscribe(OWNER_CHANGED, function(...) got = { ... } end, probeTarget)
  g_farmlandManager:setLandOwnership(8, 1)
  T.ok("S4 a targeted subscriber receives its target first", got and got[1] == probeTarget)
  T.eq("S5 then farmlandId, farmId and loadFromSavegame (false by default)",
    got and (tostring(got[2]) .. ":" .. tostring(got[3]) .. ":" .. tostring(got[4])), "8:1:false")
end)

-- ── W / B: a live buy ───────────────────────────────────────────────────────────
group("B live buy", function()
  local sys, hm, installed, errors = newWorld()
  T.ok("B1 [reached: scanFields made records for every field]", sys.fieldData[7] ~= nil and sys.fieldData[8] ~= nil and sys.fieldData[9] ~= nil)
  T.eq("B2 [reached: the load set holds only the owned field]", tostring(isActive(sys, 7)) .. ":" .. tostring(isActive(sys, 9)), "false:true")
  local record7 = sys.fieldData[7]
  sys._activeListDirty = false
  g_farmlandManager:setLandOwnership(7, 1)
  T.eq("B3 NAMED: a field bought mid-session joins the active set", isActive(sys, 7), true)
  T.eq("B4 and the batch list is marked for rebuild, so the next daily batch includes it", sys._activeListDirty, true)
  T.ok("B5 on the record scanFields made (not a new one)", sys.fieldData[7] == record7)
  T.eq("B6 the hook raised nothing", #errors, 0)
end)

-- ── L: load is skipped ──────────────────────────────────────────────────────────
group("L load", function()
  local sys = newWorld()
  g_farmlandManager:setLandOwnership(7, 1, true)
  T.eq("L1 [reached: the mapping changed]", g_farmlandManager:getFarmlandOwner(7), 1)
  T.eq("L2 loadFromSavegame true is skipped: the field does not join here", isActive(sys, 7), false)
end)

-- ── X: a live sell ──────────────────────────────────────────────────────────────
group("X live sell", function()
  local sys, hm, installed, errors = newWorld()
  local record9 = sys.fieldData[9]
  local n9 = record9.nitrogen
  g_farmlandManager:setLandOwnership(9, NO_OWNER)
  T.eq("X1 NAMED: a field sold mid-session leaves the active set", isActive(sys, 9), false)
  T.eq("X2 NAMED: its layer colours are cleared", table.concat(sys.cleared, ","), "9")
  T.ok("X3 its soil data is kept (the same record, nitrogen unchanged)", sys.fieldData[9] == record9 and record9.nitrogen == n9)
  T.eq("X4 the hook raised nothing", #errors, 0)
end)

-- ── N: NPC-managed ground stays active on a sell ────────────────────────────────
group("N NPC-managed sell", function()
  local sys = newWorld()
  -- NPCFavor's own surface, as NpcSoilBridge reads it (NpcSoilBridge.lua:41-47, :51-64).
  g_currentMission.npcFavorSystem = { isNPCManaged = function(_, id) return id == 9, (id == 9) and 3 or nil end }
  g_farmlandManager:setLandOwnership(9, NO_OWNER)
  T.eq("N1 NPC-managed ground stays active when the farm sells it", isActive(sys, 9), true)
  T.eq("N2 and its layers are not cleared", #sys.cleared, 0)
  g_currentMission.npcFavorSystem = nil
end)

-- ── C: a pure multiplayer client ────────────────────────────────────────────────
group("C client", function()
  local sys, hm, installed, errors = newWorld({ asClient = true, synced = true })
  T.eq("C1 [reached: a pure client with the server's records]", tostring(g_server) .. ":" .. tostring(sys.fieldData[7] ~= nil), "nil:true")
  local record7 = sys.fieldData[7]
  g_farmlandManager:setLandOwnership(7, 1)
  T.eq("C2 NAMED: on a client a bought field joins the client's active set (the overlay's input)", isActive(sys, 7), true)
  T.ok("C3 on the synced record, which the client does not recreate", sys.fieldData[7] == record7)
  g_farmlandManager:setLandOwnership(9, NO_OWNER)
  T.eq("C4 NAMED: a sold field leaves it", isActive(sys, 9), false)
  T.eq("C5 and its layer colours are cleared on the client too (a display write)", table.concat(sys.cleared, ","), "9")
  T.eq("C6 the hook raised nothing", #errors, 0)

  local sys2, _, _, errors2 = newWorld({ asClient = true, synced = false })
  T.eq("C7 [reached: before the sync the client holds no records]", next(sys2.fieldData), nil)
  g_farmlandManager:setLandOwnership(7, 1)
  T.eq("C8 a buy before the sync creates no record on the client", sys2.fieldData[7], nil)
  T.eq("C9 and joins nothing", isActive(sys2, 7), false)
  T.eq("C10 the hook raised nothing", #errors2, 0)
end)

-- ── U: cleanup ──────────────────────────────────────────────────────────────────
group("U cleanup", function()
  local sys, hm = newWorld()
  hm.installed = true
  hm:uninstallAll()
  T.eq("U1 uninstallAll removes the subscription by target", g_messageCenter.subscribers[OWNER_CHANGED], nil)
  g_farmlandManager:setLandOwnership(7, 1)
  T.eq("U2 a later buy reaches nothing", isActive(sys, 7), false)
end)

g_messageCenter, MessageType, g_farmlandManager, g_fieldManager = saved.mc, saved.mt, saved.flm, saved.fm
g_SoilFertilityManager, g_server = saved.sfm, saved.server
g_currentMission.missionDynamicInfo, g_currentMission.npcFavorSystem = saved.mdi, saved.npc
SoilLogger.error = saved.logErr
