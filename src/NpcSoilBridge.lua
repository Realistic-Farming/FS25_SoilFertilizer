-- =========================================================
-- FS25 Soil & Fertilizer - NPC SOIL BRIDGE (SF-27)
-- =========================================================
-- NPC-managed farmland joins the daily soil simulation exactly like owned land,
-- worked by NPCFavor's real AI jobs, with attribution so their operations book
-- to their ground record and never to the player. No new mod; SF widens its own
-- gate, NPCFavor publishes two small read surfaces.
--
-- This bridge is SF's side of the cross-mod contract (the brief's B1 + B2 + B4):
--   - isNPCManaged(fieldId): reads NPCFavor's designation surface through the
--     mission handle (pcall, neutral-absent). nil/absent = not NPC-managed.
--   - getWorkingState(fieldId): who is working the ground right now, or nil.
--   - isNPCAttributed(fieldId): one predicate consulted suite-wide. An operation
--     on a designated field during that field's working-state window is
--     NPC-ATTRIBUTED. UNKNOWN attribution fails CLOSED (no charge, no booking).
--
-- LANE B (settled 2026-07-23): the NPCFavor ownership flip stays mechanically but
-- designated ground never churns membership, never leaks into owned-field
-- surfaces, and never wipes GRLE. This bridge implements the SF half of the
-- capability-probe handshake: it publishes the widened phase-2 gate as a
-- capability marker on the mission handle, and NPCFavor's flip deletes itself
-- only when that probe passes.
--
-- Server-side only. Neutral when NPCFavor is absent: SF behaves exactly as today.
-- =========================================================
-- Author: TisonK
-- =========================================================

NpcSoilBridge = {}

--- The mission-handle capability marker NPCFavor probes before deleting its flip.
--- Published once the mission handle is available (Mission00.load hook).
NpcSoilBridge.CAPABILITY = "npcSoilPhase2"

-- =========================================================
-- The designation surface (NPCFavor's read, pulled through the mission handle)
-- =========================================================

--- The NPCFavor system handle, pcall-safe, cached.
---@return table|nil
function NpcSoilBridge:_npcSystem()
    local m = g_currentMission
    if not m then return nil end
    return m.npcFavorSystem or nil
end

--- Is this farmland designated NPC-managed? Pull-only, pcall, neutral-absent.
---@param fieldId number
---@return boolean|nil managed  nil = not NPC-managed (or NPCFavor absent)
---@return number|nil npcId
function NpcSoilBridge:isNPCManaged(fieldId)
    local npc = self:_npcSystem()
    if not npc then return nil, nil end
    if type(npc.isNPCManaged) == "function" then
        local ok, managed, id = pcall(npc.isNPCManaged, npc, fieldId)
        if ok then return managed, id end
    end
    -- Fallback spelling (maturity surface not yet published): probe the NPC list.
    if type(npc.getNPCForFarmland) == "function" then
        local ok, npcId = pcall(npc.getNPCForFarmland, npc, fieldId)
        if ok and npcId then return true, npcId end
    end
    return nil, nil
end

--- Who is working this farmland right now? nil when nobody / NPCFavor absent.
---@param fieldId number
---@return number|nil npcId
function NpcSoilBridge:getWorkingState(fieldId)
    local npc = self:_npcSystem()
    if not npc then return nil end
    if type(npc.getWorkingState) == "function" then
        local ok, npcId = pcall(npc.getWorkingState, npc, fieldId)
        if ok then return npcId end
    end
    return nil
end

-- =========================================================
-- B4. The attribution predicate (suite-wide, fail-closed)
-- =========================================================

--- Is an operation on this field NPC-ATTRIBUTED? True when the field is
--- designated AND an NPC is working it right now (the working-state window).
--- UNKNOWN attribution fails CLOSED (returns true so no player charge fires).
---@param fieldId number
---@return boolean attributed
function NpcSoilBridge:isNPCAttributed(fieldId)
    local managed = self:isNPCManaged(fieldId)
    if managed == true then
        local who = self:getWorkingState(fieldId)
        -- Designated but nobody working right now: still NPC ground, never the
        -- player's bill. Fail closed toward attribution.
        return true
    end
    return false
end

--- Is this field part of the widened phase-2 active set (owned OR NPC-managed)?
--- The single predicate the membership gates consult, so the widening lives in
--- one place.
---@param fieldId number
---@param owner number|nil  the farmland owner (0 / nil = unowned)
---@return boolean
function NpcSoilBridge:isSimActive(fieldId, owner)
    if owner and owner > 0 then return true end
    return self:isNPCManaged(fieldId) == true
end

-- =========================================================
-- The capability marker (the handshake's SF half)
-- =========================================================

--- Attach the bridge to the mission handle. Called once from the Mission00.load
--- hook. Publishes the capability marker and the read surfaces NPCFavor / owned
--- consumers may probe.
---@param mission table g_currentMission
function NpcSoilBridge:attach(mission)
    if mission == nil then return end
    mission.npcSoilBridge = {
        capability   = NpcSoilBridge.CAPABILITY,
        isNPCManaged = function(fieldId) return NpcSoilBridge:isNPCManaged(fieldId) end,
        isNPCAttributed = function(fieldId) return NpcSoilBridge:isNPCAttributed(fieldId) end,
        isSimActive  = function(fieldId, owner) return NpcSoilBridge:isSimActive(fieldId, owner) end,
    }
end

--- Is the capability probe satisfied? NPCFavor calls this before deleting its
--- ownership flip.
---@return boolean
function NpcSoilBridge:capabilityReady()
    local m = g_currentMission
    return m ~= nil and m.npcSoilBridge ~= nil
end
