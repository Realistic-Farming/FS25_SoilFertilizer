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
--- Is a full-screen drawn panel currently owning the screen?
---@return boolean
local function fullScreenPanelOpen(sfm)
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

    -- A FULL-SCREEN PANEL OWNS THE SCREEN, so the HUD stands down while one is up.
    --
    -- Without this the Soil Monitor's own text (the Good / Fair / Poor labels and
    -- the nutrient rows) reads straight THROUGH the panel drawn over it. A panel
    -- background is an overlay, and an overlay does not cover text that was
    -- already rendered underneath it, so a HUD cannot be hidden by painting on
    -- top of it. It has to not draw.
    --
    -- The rule is not new here. SoilHUD:draw already stands down for a base-game
    -- GUI (SoilHUD.lua:1302), and the four in-vehicle panels each carry the same
    -- getIsGuiVisible guard. None of them could see OUR panels, because those are
    -- drawn surfaces rather than g_gui ones, so the rule they all follow simply
    -- had a blind spot. This closes it in the one place that owns draw order.
    --
    -- The three panels are mutually exclusive by construction: the settings panel
    -- calls close() on itself before opening either tuning editor.
    if fullScreenPanelOpen(sfm) then
        if sfm.settingsPanel then sfm.settingsPanel:draw() end
        if sfm.tuningPanel then sfm.tuningPanel:draw() end
        if sfm.cropTuningPanel then sfm.cropTuningPanel:draw() end
        return
    end

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
        })
    end)

    if ok then
        SoilMasterHUDBridge.active = true
        SoilLogger.info("Registered soil HUD with MasterHUD (single draw loop + menu-suspend)")
    else
        SoilLogger.warning("MasterHUD registration failed: %s (using own draw hook)", tostring(err))
    end
end
