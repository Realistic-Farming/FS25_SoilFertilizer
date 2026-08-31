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

-- BUILD 19:38: reload-safe like the HUD classes - the table AND the active flag
-- survive Ctrl+R, or the hot-reload delivery block at the end could never fire.
SoilMasterHUDBridge = SoilMasterHUDBridge or {}

SoilMasterHUDBridge.HUD_ID = "SoilFertilizer_HUD"
SoilMasterHUDBridge.active = SoilMasterHUDBridge.active or false   -- survives reload; register() re-derives it

--- Does SoilFertilizer currently own the whole screen?
---
--- ONE implementation, two callers, and they ask the same question:
---   * drawStack, below, to stand OUR OWN HUD down (the single-mod half, #834).
---   * MasterHUD, as the subscribe spec's isFullscreen, to stand every OTHER
---     companion's HUD down (the cross-mod half, #835).
--- The two arrived on separate branches and each had its own copy of this check.
--- They are collapsed here rather than left side by side, because two functions
--- answering one question is how they drift apart later.
---
--- The cross-mod half only has an effect when MasterHUD is present, since
--- MasterHUD is what owns cross-mod ordering. Standalone, each mod draws its own
--- stack and cannot see the others.
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

--- Keep every independently positioned Soil vehicle panel in lockstep with the
--- suite editor.  The standalone SF_HUD_DRAG callback already does this; the
--- MasterHUD bridge previously toggled only the main Soil Monitor, leaving the
--- sprayer/spreader/slurry and harvester panels invisible and therefore
--- impossible to place from the suite-wide editor.
---@param enabled boolean
function SoilMasterHUDBridge.setEditMode(enabled)
    local sfm = g_SoilFertilityManager
        or (g_currentMission ~= nil and g_currentMission.soilFertilityManager or nil)
    if sfm == nil then return end

    local panels = { sfm.soilHUD, sfm.sprayerInfoPanel, sfm.harvesterPanel }
    for _, panel in pairs(panels) do
        if panel ~= nil then
            if enabled then
                if not panel.editMode and panel.enterEditMode ~= nil then panel:enterEditMode() end
            elseif panel.exitEditMode ~= nil and panel.editMode then
                panel:exitEditMode()
            end
        end
    end
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
    if SoilMasterHUDBridge.isFullscreen() then
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

SoilMasterHUDBridge.CAB_ID = "SoilFertilizer_CabTools"

--- [SF-51] In-cab TOOL readouts, kept alive through suite hide-all
--- (BUILD 22:36; shape banked on BUILD 22:20). Hiding "HUDs" means the
--- monitor, trails and minimap chrome - not flying blind mid-spray. This
--- second subscription carries visibleWhenHudsHidden = true and draws ONLY
--- while huds are hidden: when they are visible, drawStack already draws the
--- same panels, and drawing twice would double the alpha and fight the drag
--- handles.
function SoilMasterHUDBridge.drawCabTools()
    local hud = SoilMasterHUDBridge._hud
    if hud == nil or hud.hudsHidden ~= true then return end
    local sfm = g_SoilFertilityManager
    if sfm == nil then return end
    if SoilMasterHUDBridge.isFullscreen() then return end

    -- The application-rate strip alone, not the whole Soil Monitor: SoilHUD:draw
    -- would bring the monitor back, which is exactly what hide-all removes.
    if sfm.soilHUD and sfm.soilHUD.drawSprayerRatePanel then
        sfm.soilHUD:drawSprayerRatePanel()
    end
    if sfm.variableRatePanel then sfm.variableRatePanel:draw() end
    if sfm.smartSensorPanel then sfm.smartSensorPanel:draw() end
    if sfm.sprayerInfoPanel then sfm.sprayerInfoPanel:draw() end
    if sfm.harvesterPanel then sfm.harvesterPanel:draw() end
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
        -- [SF-51] Keep the hud handle for drawCabTools' hudsHidden check, and
        -- register the keep-alive cab-tools subscription. pcall'd separately:
        -- an older MasterHUD without the flag simply draws it as a normal
        -- self-draw, and the function's own hudsHidden guard then makes it a
        -- no-op - graceful on every version pairing.
        SoilMasterHUDBridge._hud = hud
        pcall(function()
            hud:subscribe(SoilMasterHUDBridge.CAB_ID, {
                draw = SoilMasterHUDBridge.drawCabTools,
                visibleWhenHudsHidden = true,
            })
        end)
        SoilLogger.info("Registered soil HUD with MasterHUD (single draw loop + menu-suspend + cab-tools keep-alive)")
        -- Suite layout edit reaches the Soil Monitor and every independent
        -- in-vehicle panel, including placeholders when no matching implement is
        -- currently controlled.
        if hud.registerEditListener ~= nil then
            hud:registerEditListener(SoilMasterHUDBridge.HUD_ID, {
                enter = function()
                    SoilMasterHUDBridge.setEditMode(true)
                end,
                exit = function()
                    SoilMasterHUDBridge.setEditMode(false)
                end,
            })
        end
    else
        SoilLogger.warning("MasterHUD registration failed: %s (using own draw hook)", tostring(err))
    end
end

-- =========================================================
-- BUILD 19:38 hot-reload delivery: register() only runs at mission load, so a
-- Ctrl+R push of this file alone would define the new edit listener without
-- ever registering it. This top-level block re-runs the registration on reload.
-- BUILD 20:40 (George 20:35, Brian 20:07): delivery is NOT gated on .active - the
-- gated shape skips silently whenever the boot-time bridge predates the flag
-- (exactly how Moisture lost its listener this session). register() is idempotent
-- (subscribe and registerEditListener both replace by id), so firing on every
-- live source pass is safe; on a cold source pass the mission handle does not
-- exist yet and this stays a no-op.
local __hud = (g_currentMission ~= nil and g_currentMission.masterHUD) or g_masterHUD
if __hud ~= nil then
    pcall(function() SoilMasterHUDBridge.register() end)
end
