-- npc_soil_gate_spec_test.lua - NPC SOIL (SF-27)
--
-- Pins the brief's spec bar: the site-class predicate truth table (owned OR
-- NPC-managed), the fail-closed attribution gate (UNKNOWN = no player charge,
-- no booking), and the neutral-when-absent rule (no NPCFavor = exactly today).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/NpcSoilBridge.lua

local B = NpcSoilBridge

-- ── 1. isSimActive truth table (owned OR NPC-managed) ────────────────────────
do
  g_currentMission = nil
  T.eq("owned -> active",        B:isSimActive(1, 100), true)
  T.eq("unowned, unmanaged -> inactive", B:isSimActive(1, 0), false)
  T.eq("unowned, nil owner -> inactive", B:isSimActive(1, nil), false)
end

do
  -- NPCFavor present, field designated.
  g_currentMission = { npcFavorSystem = {
    isNPCManaged = function(_self, _fid) return true, 7 end,
    getWorkingState = function(_self, _fid) return 7 end,
  } }
  T.eq("unowned but NPC-managed -> active", B:isSimActive(1, 0), true)
  T.eq("unowned but NPC-managed, nil owner -> active", B:isSimActive(1, nil), true)
  T.eq("isNPCManaged returns (true, id)", (B:isNPCManaged(1)), true)
end

-- ── 2. Fail-closed attribution: designated field never bills the player ──────
do
  g_currentMission = { npcFavorSystem = {
    isNPCManaged = function(_self, _fid) return true, 7 end,
    getWorkingState = function(_self, _fid) return 7 end,
  } }
  T.eq("designated + working -> attributed", B:isNPCAttributed(1), true)
end

do
  -- Designated but nobody currently working: still NPC ground, never the bill.
  g_currentMission = { npcFavorSystem = {
    isNPCManaged = function(_self, _fid) return true, 7 end,
    getWorkingState = function(_self, _fid) return nil end,
  } }
  T.eq("designated, nobody working -> still attributed (fail closed)", B:isNPCAttributed(1), true)
end

-- ── 3. Neutral when NPCFavor absent: nothing is designated, nothing is active ─
do
  g_currentMission = nil
  T.eq("absent NPCFavor -> not managed", B:isNPCManaged(1), nil)
  T.eq("absent NPCFavor -> not attributed", B:isNPCAttributed(1), false)
  T.eq("absent NPCFavor -> unowned not active", B:isSimActive(1, 0), false)
  T.eq("absent NPCFavor -> owned still active", B:isSimActive(1, 42), true)
end

-- ── 4. A throwing NPCFavor surface fails closed (pcall) ──────────────────────
do
  g_currentMission = { npcFavorSystem = {
    isNPCManaged = function() error("boom") end,
    getWorkingState = function() error("boom") end,
  } }
  T.eq("throwing isNPCManaged -> nil (not managed)", B:isNPCManaged(1), nil)
  T.eq("throwing surface -> not attributed", B:isNPCAttributed(1), false)
end

-- ── 5. The capability marker is published on attach ──────────────────────────
do
  g_currentMission = { npcFavorSystem = nil }
  B:attach(g_currentMission)
  T.eq("capability marker published", g_currentMission.npcSoilBridge.capability, "npcSoilPhase2")
  T.eq("capabilityReady true after attach", B:capabilityReady(), true)
  g_currentMission = nil
end
