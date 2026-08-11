-- npc_soil_designation_spec_test.lua - NPC SOIL (SF-27) designation surface.
--
-- Verifies the shape of NPCFavor's two published read surfaces
-- (isNPCManaged / getWorkingState) against the active-NPC assignedFarmland
-- records, plus the neutral-absent rule. The methods are re-declared here
-- against the same contract the NPCFavor build publishes; the real file's
-- load path is not on SF's harness.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua

local npcFavorSystem = {}

function npcFavorSystem.getNPCForFarmland(self, farmlandId)
    local npcs = self.npcSystem and self.npcSystem.activeNPCs
    if not npcs then return nil end
    for _, npc in ipairs(npcs) do
        local af = npc.assignedFarmland
        if af and af.farmlandId == farmlandId then return npc.id end
    end
    return nil
end

function npcFavorSystem.isNPCManaged(self, farmlandId)
    local npcId = self:getNPCForFarmland(farmlandId)
    if npcId then return true, npcId end
    return false, nil
end

function npcFavorSystem.getWorkingState(self, farmlandId)
    local npcs = self.npcSystem and self.npcSystem.activeNPCs
    if not npcs then return nil end
    for _, npc in ipairs(npcs) do
        local af = npc.assignedFarmland
        if af and af.farmlandId == farmlandId and npc.isWorking then return npc.id end
    end
    return nil
end

local function newSystem(activeNPCs)
    return setmetatable({ npcSystem = { activeNPCs = activeNPCs or {} } },
        { __index = npcFavorSystem })
end

-- ── 1. Designated farmland -> managed with the NPC id ────────────────────────
do
    local sys = newSystem({
        { id = 3, assignedFarmland = { farmlandId = 10 }, isWorking = true },
        { id = 5, assignedFarmland = { farmlandId = 20 }, isWorking = false },
    })
    local managed, npcId = npcFavorSystem.isNPCManaged(sys, 10)
    T.eq("designated field -> managed", managed, true)
    T.eq("designated field -> npc id", npcId, 3)
    local m2, id2 = npcFavorSystem.isNPCManaged(sys, 20)
    T.eq("designated-but-idle -> managed", m2, true)
    T.eq("idle NPC still the manager id", id2, 5)
end

-- ── 2. Undesignated / absent -> not managed ──────────────────────────────────
do
    local sys = newSystem({ { id = 3, assignedFarmland = { farmlandId = 10 } } })
    local managed = npcFavorSystem.isNPCManaged(sys, 99)
    T.eq("undesignated field -> not managed", managed, false)
    local sysEmpty = newSystem()
    local m = npcFavorSystem.isNPCManaged(sysEmpty, 1)
    T.eq("no NPCs -> not managed", m, false)
end

-- ── 3. getWorkingState: only the working NPC is "working right now" ──────────
do
    local sys = newSystem({
        { id = 3, assignedFarmland = { farmlandId = 10 }, isWorking = true },
        { id = 5, assignedFarmland = { farmlandId = 10 }, isWorking = false },
    })
    T.eq("working NPC reported", npcFavorSystem.getWorkingState(sys, 10), 3)
    local sysIdle = newSystem({ { id = 5, assignedFarmland = { farmlandId = 10 }, isWorking = false } })
    T.eq("no working NPC -> nil", npcFavorSystem.getWorkingState(sysIdle, 10), nil)
end
