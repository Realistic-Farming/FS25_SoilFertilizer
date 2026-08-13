-- =========================================================
-- FS25 Realistic Soil & Fertilizer - MasterHUD bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_MasterHUD. SoilFertilizer ships standalone, so this is
-- delegate-when-present:
--   * MasterHUD installed -> SF registers its whole HUD draw stack (Soil Monitor,
--     in-vehicle panels, spray/harvest/tillage trails, minimap overlay) as a
--     self-draw. MasterHUD then owns the single draw loop, the menu/dialog suspend,
--     and cross-mod ordering, so SF's HUD stacks cleanly with the rest of the
--     ecosystem instead of every mod hooking FSBaseMission.draw independently.
--   * MasterHUD absent -> SF's own FSBaseMission.draw hook runs the exact same
--     stack, exactly as before.
--
-- subscribe() is MasterHUD's path for self-drawn / world-space content (its own
-- header calls out SoilFertilizer's trails as the example): the element draws its
-- own positioned content, MasterHUD only owns ordering + suspend, it does not lay
-- it out. That is exactly SF's shape, so nothing about the panels' own positioning
-- changes. drawStack() is the single source of the draw body, shared with the
-- fallback hook so the two paths can never diverge.
-- =========================================================

SoilMasterHUDBridge = {}

SoilMasterHUDBridge.HUD_ID = "SoilFertilizer_HUD"
SoilMasterHUDBridge.active = false   -- MasterHUD present and we registered

-- The full SF HUD draw stack. Byte-for-byte the same order as the standalone
-- FSBaseMission.draw hook. Resolves the manager from the canonical global so it
-- can be driven either by MasterHUD or by SF's own hook.
--- Does SoilFertilizer currently own the whole screen?
---
--- Passed to MasterHUD as the subscribe spec's isFullscreen so that while one of
--- our full-screen panels is open, EVERY other companion's HUD stands down too.
--- Our own HUD is handled inside drawStack; this is the cross-mod half, and it
--- only has an effect when MasterHUD is present, since MasterHUD is what owns
--- cross-mod ordering. Standalone, each mod still draws its own stack.
---
--- Called every frame from MasterHUD's draw loop, so it stays a cheap read of
--- state that already exists and never computes anything.
---@return boolean
function SoilMasterHUDBridge.isFullscreen()
    local sfm = g_SoilFertilityManager
    if sfm == nil then return false end
    for _, p in ipairs({ sfm.settingsPanel, sfm.tuningPanel, sfm.cropTuningPanel }) do
        if p ~= nil and type(p.isOpen) == "function" and p:isOpen() then
            return true
        end
    end
    return false
end

function SoilMasterHUDBridge.drawStack()
    local sfm = g_SoilFertilityManager
    if sfm == nil then return end

    if sfm.soilHUD then sfm.soilHUD:draw() end
    if sfm.settingsPanel then sfm.settingsPanel:draw() end
    if sfm.tuningPanel then sfm.tuningPanel:draw() end
    if sfm.cropTuningPanel then sfm.cropTuningPanel:draw() end
    if sfm.variableRatePanel then sfm.variableRatePanel:draw() end
    if sfm.smartSensorPanel then sfm.smartSensorPanel:draw() end
    if sfm.sprayerInfoPanel then sfm.sprayerInfoPanel:draw() end
    if sfm.harvesterPanel then sfm.harvesterPanel:draw() end

    -- Soil layer overlay on the HUD minimap (bottom-left). Uses the ingameMap ref
    -- captured at map-load time (g_currentMission.ingameMap is nil in FS25).
    if sfm.soilMapOverlay then
        local ingameMap = sfm.soilMapOverlay.ingameMapRef
            or (g_currentMission and g_currentMission.ingameMap)
        if ingameMap then
            sfm.soilMapOverlay:onDrawMinimap(ingameMap)
        end
    end
end

-- Register with MasterHUD if present. Called at loadMission00Finished, after the
-- HUD has published its g_currentMission handle (Mission00.load).
function SoilMasterHUDBridge.register(mgr)
    SoilMasterHUDBridge.active = false

    local hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
    if hud == nil then
        SoilLogger.info("MasterHUD not detected; soil HUD uses its own draw hook")
        return
    end

    local ok, err = pcall(function()
        hud:subscribe(SoilMasterHUDBridge.HUD_ID, {
            draw = SoilMasterHUDBridge.drawStack,
            -- Declares that SF owns the whole screen while one of its panels is
            -- open, so MasterHUD stands every OTHER companion's HUD down. Without
            -- it, the Income and Tax HUDs render their text before our panel and
            -- read straight through it, because an overlay does not cover text
            -- already drawn underneath. Optional on MasterHUD's side, so an older
            -- MasterHUD simply ignores it and behaves exactly as before.
            isFullscreen = SoilMasterHUDBridge.isFullscreen,
        })
    end)

    if ok then
        SoilMasterHUDBridge.active = true
        SoilLogger.info("Registered soil HUD with MasterHUD (single draw loop + menu-suspend)")
    else
        SoilLogger.warning("MasterHUD registration failed: %s (using own draw hook)", tostring(err))
    end
end
