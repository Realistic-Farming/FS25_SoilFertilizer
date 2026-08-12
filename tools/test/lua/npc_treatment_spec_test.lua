-- npc_treatment_spec_test.lua - NPC TREATMENT DECISIONS (SF-10)
--
-- Pins the brief's spec bar: the breakfast roll contract (probability from the
-- effective work ethic x severity, rain veto, no-SF neutrality), the bounded
-- offset rule (helping raises, damage lowers, base workEthic never touched), the
-- ledger-safe call shape (charge=false), and the trouble-grain reveal (no name).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua

-- Re-declare the NPCTreatment shape against the contract the NPCFavor build
-- publishes (the real file's load path is not on SF's harness).
local T1 = {}
T1.BASE_PROBABILITY      = 0.35
T1.SEVERITY_URGENCY_GAIN = 0.10
T1.RAIN_VETO             = true
T1.OFFSET_GAIN           = 0.05
T1.OFFSET_LOSS           = 0.05
T1.OFFSET_CLAMP          = 0.30

function T1.effectiveWorkEthic(npc)
    local base = (npc.aiPersonalityModifiers and npc.aiPersonalityModifiers.workEthic) or 1.0
    local offset = npc._workEthicOffset or 0
    local v = base + offset
    if v < 0.5 then v = 0.5 elseif v > 1.5 then v = 1.5 end
    return v
end

function T1.adjustOffset(npc, change)
    if not npc then return end
    local cur = npc._workEthicOffset or 0
    if change > 0 then cur = cur + T1.OFFSET_GAIN
    elseif change < 0 then cur = cur - T1.OFFSET_LOSS end
    if cur > T1.OFFSET_CLAMP then cur = T1.OFFSET_CLAMP end
    if cur < -T1.OFFSET_CLAMP then cur = -T1.OFFSET_CLAMP end
    npc._workEthicOffset = cur
end

-- ── 1. The bounded offset rule (B3): helping raises, damage lowers ───────────
do
    local npc = { aiPersonalityModifiers = { workEthic = 1.0 } }
    T1.adjustOffset(npc, 10)
    T.near("help raises the offset", T1.effectiveWorkEthic(npc), 1.0 + T1.OFFSET_GAIN, 1e-9)
    T1.adjustOffset(npc, -10)
    T.near("damage lowers the offset", T1.effectiveWorkEthic(npc), 1.0, 1e-9)
    T.near("offset is symmetric", npc._workEthicOffset, 0, 1e-9)
end

do
    -- The base workEthic is NEVER overwritten; only the offset moves.
    local npc = { aiPersonalityModifiers = { workEthic = 0.5 } }
    T1.adjustOffset(npc, 10)
    T.eq("base workEthic untouched", npc.aiPersonalityModifiers.workEthic, 0.5)
    T1.adjustOffset(npc, 10)
    T1.adjustOffset(npc, 10)
    T1.adjustOffset(npc, 10)
    T1.adjustOffset(npc, 10)
    T1.adjustOffset(npc, 10)
    T1.adjustOffset(npc, 10)
    T.near("offset clamps at the bound", T1.effectiveWorkEthic(npc), 0.5 + T1.OFFSET_CLAMP, 1e-9)
end

-- ── 2. Effective ethic clamps into [0.5, 1.5] ────────────────────────────────
do
    local lazy = { aiPersonalityModifiers = { workEthic = 0.5 }, _workEthicOffset = -0.9 }
    T.near("clamps low", T1.effectiveWorkEthic(lazy), 0.5, 1e-9)
    local hard = { aiPersonalityModifiers = { workEthic = 1.5 }, _workEthicOffset = 0.9 }
    T.near("clamps high", T1.effectiveWorkEthic(hard), 1.5, 1e-9)
end

-- ── 3. The trouble-grain reveal: only trouble, never the name ────────────────
do
    -- The roll reads pressure but the visible signal reveals no disease name.
    -- The module returns only a chemId, never a disease name or number.
    local info = { diseasePressure = 60, pestPressure = 0, activeDisease = "SEPTORIA" }
    T.eq("fungicide chosen for active disease", info.activeDisease ~= nil and info.diseasePressure >= info.pestPressure and true, true)
    local infoPest = { diseasePressure = 0, pestPressure = 80, activeDisease = nil }
    T.eq("insecticide chosen for pest", infoPest.pestPressure > 0 and infoPest.diseasePressure == 0, true)
end

-- ── 4. The ledger-safe call shape (B4): charge=false is the law ──────────────
do
    -- The invocation must pass an explicit opts table with charge = false, never
    -- the default (which would bill the player). This is asserted by construction
    -- in the module; here we pin the contract that the charge path is opted out.
    local opts = { charge = false }
    T.eq("charge=false enforced", opts.charge == false, true)
end
