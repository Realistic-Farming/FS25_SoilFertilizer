-- =========================================================
-- FS25 Soil & Fertilizer - Harvest Contract Underwrite (#741 / SF-29)
-- =========================================================
-- Closes player report #741 "Harvest missions will never reach 100%".
--
-- Root cause (certified at source): base-game field missions only validate on UNOWNED
-- fields (AbstractFieldMission:validate -> not field:getHasOwner()), so every harvest
-- contract runs on neighbour ground. That ground rolls a poor soil profile and is excluded
-- from the daily sim, so SF's yield modifier cuts the delivered liters. HarvestMission's
-- completion is liters-based (deposited / expected, anchored to the full-health vanilla
-- ceiling from getMaxCutLiters()), so the contract can be fully harvested and still stall
-- far below 100% (the reporter's save: 11420 / 35403 L ~ 32%). AbstractMission:updateTick
-- only calls finish(SUCCESS) once getCompletion() >= 0.995, so it never completes and never
-- pays.
--
-- The fix (Tyson OPTION 2, Arissani blessed - "standalone, retained contract-mask"): wrap
-- HarvestMission.getCompletion and divide the vanilla completion by SF's OWN yield modifier
-- for that field. computeYieldModifier is the exact factor the combine hopper applied (and
-- it is frozen for the harvest run, #556), so dividing it out restores the completion the
-- field would have shown at full health - the vanilla expectation, and nothing more.
--
-- Bounds honoured (the SF-29 fence, each a cert gate):
--   * NO soil write, NO applyRetroactiveHarvest - this only reads computeYieldModifier and
--     corrects the mission's own completion metric.
--   * Delivery-time only - getCompletion is polled server-side as harvest/delivery progress;
--     the credit materialises only from liters actually harvested and delivered, so a partly
--     harvested field reads partly complete (no free money).
--   * Vanilla expectation is the ceiling - corrected completion is capped at 1.0, so the base
--     game pays exactly its own (unchanged) reward on SUCCESS; farm money is never touched.
--   * Server-authoritative - completion is a server value synced to clients; the correction
--     is gated on g_server and applied once, on the authority.
--   * Fail-safe - every guard miss and any error in the correction returns the vanilla value,
--     so the underwrite can only ever help a contract reach 100%, never break one.
--
-- Composes with the retained FieldSentry contract mask: orthogonal, no shared state. The
-- mask (isFieldSimDisabled) only skips the daily soil sim; it never touched the harvest
-- accounting. This does the opposite half and leaves the mask alone. (Bound 1 "the ground
-- lives" is deferred by design on this decoupled path - the field stays frozen as today; the
-- ground-lives behaviour arrives when the mask-flip ships with the NPC-soil drop.)
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class HarvestContractUnderwrite
HarvestContractUnderwrite = {}

-- AbstractMission:updateTick finishes a mission SUCCESS at completion >= 0.995 (the base
-- game's own "99.5% shows as 100%" margin). We mirror it so the messaging fires exactly
-- when the underwrite is what carries the contract across that same line.
HarvestContractUnderwrite.SUCCESS_THRESHOLD = 0.995

-- Reference to our installed wrapper, so install() is idempotent and reload-safe without a
-- stale boolean: if the class method is no longer ours (e.g. uninstallAll restored the
-- original), install() re-wraps; if it is still ours, install() is a no-op.
HarvestContractUnderwrite._wrapper = nil

-- i18n helper with an English fallback. The notification key ships in translation_en.xml;
-- other languages fall back to English until a translation pass (the dialogs use the same
-- pattern for not-yet-localized keys).
local function tr(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        local t = g_i18n:getText(key)
        if t ~= nil and t ~= "" then return t end
    end
    return fallback or key
end

--- Corrected completion for a base-game harvest contract on SF soil. Pure and fail-safe:
--- returns `vanilla` unchanged on any guard miss, and never exceeds 1.0.
---@param mission table   the HarvestMission instance (self)
---@param vanilla number  the mission's own getCompletion() result
---@return number completion
function HarvestContractUnderwrite.correct(mission, vanilla)
    if type(vanilla) ~= "number" then return vanilla end

    -- Master switch (server-side agronomy dial, no per-save setting).
    if not (SoilConstants and SoilConstants.HARVEST_UNDERWRITE
            and SoilConstants.HARVEST_UNDERWRITE.ENABLED) then
        return vanilla
    end

    -- Server-authoritative only. Clients mirror the synced completion; correcting there
    -- would double-apply.
    if g_server == nil then return vanilla end

    -- Already at (or past) success: nothing to underwrite.
    if vanilla >= 1.0 then return vanilla end

    -- The field's farmland id is SF's soil key in this codebase (fieldData is keyed by
    -- farmland id; the combine hook writes the same key). Use it, not field:getId().
    local field = mission.field
    local farmland = field and field.farmland
    local farmlandId = farmland and farmland.id
    if type(farmlandId) ~= "number" then return vanilla end

    local fruitTypeIndex = mission.fruitTypeIndex
    if type(fruitTypeIndex) ~= "number" or fruitTypeIndex <= 0 then return vanilla end

    local sfm = g_SoilFertilityManager
    local soil = sfm and sfm.soilSystem
    if soil == nil or type(soil.computeYieldModifier) ~= "function" then return vanilla end

    -- The SAME modifier the combine hopper applied to this field's harvest. It returns 1.0
    -- when SF is disabled or the field is untracked, which no-ops the underwrite correctly.
    local ym = soil:computeYieldModifier(farmlandId, fruitTypeIndex)
    if type(ym) ~= "number" or ym >= 1.0 or ym <= 0 then return vanilla end

    local corrected = vanilla / ym
    if corrected > 1.0 then corrected = 1.0 end

    -- One-shot player messaging the moment the underwrite is what completes the contract
    -- (vanilla would have stalled below success this poll).
    if corrected >= HarvestContractUnderwrite.SUCCESS_THRESHOLD
       and vanilla < HarvestContractUnderwrite.SUCCESS_THRESHOLD
       and not mission._sfUnderwriteNotified then
        mission._sfUnderwriteNotified = true
        HarvestContractUnderwrite._notify(mission, field)
    end

    return corrected
end

--- Host-side one-shot notification to the contract's own farm. No-op on a dedicated server
--- (no local player) or when the notification API is absent. Guarded by the caller's pcall.
---@param mission table
---@param field table|nil
function HarvestContractUnderwrite._notify(mission, field)
    local cm = g_currentMission
    if cm == nil or cm.addIngameNotification == nil then return end

    local lp = g_localPlayer
    if lp == nil or lp.farmId ~= mission.farmId then return end

    local fieldId = (field and field.getId and field:getId()) or "?"
    local text = string.format(
        tr("sf_underwrite_notify",
           "Harvest contract topped up on field %s: degraded soil compensated to the expected yield."),
        tostring(fieldId))

    local icon = (FSBaseMission and FSBaseMission.INGAME_NOTIFICATION_OK) or nil
    if icon ~= nil then
        cm:addIngameNotification(icon, text)
    end
    if SoilLogger then
        SoilLogger.info("Harvest underwrite: contract on field %s topped up (mission %s)",
            tostring(fieldId), tostring(mission.uniqueId))
    end
end

--- Install the class-level getCompletion override on HarvestMission. Idempotent and
--- reload-safe. Wraps (does not replace) the base method: the vanilla completion is computed
--- first, unchanged, then the underwrite adds its correction on top under a pcall, so a bug
--- in the correction can never break the base mission (it falls back to the vanilla value).
---@param hookManager table|nil  optional HookManager, for uninstall bookkeeping
---@return boolean installed
function HarvestContractUnderwrite.install(hookManager)
    if HarvestMission == nil or type(HarvestMission.getCompletion) ~= "function" then
        if SoilLogger then
            SoilLogger.info("Harvest underwrite: HarvestMission.getCompletion unavailable - skipped")
        end
        return false
    end

    -- Already ours (installAll re-ran without an uninstall): nothing to do.
    if HarvestMission.getCompletion == HarvestContractUnderwrite._wrapper then
        return true
    end

    local original = HarvestMission.getCompletion
    local wrapper = function(missionSelf)
        local vanilla = original(missionSelf)
        local ok, corrected = pcall(HarvestContractUnderwrite.correct, missionSelf, vanilla)
        if ok and type(corrected) == "number" then
            return corrected
        end
        return vanilla
    end

    HarvestContractUnderwrite._wrapper = wrapper
    HarvestMission.getCompletion = wrapper

    if hookManager and hookManager.register then
        hookManager:register(HarvestMission, "getCompletion", original,
            "HarvestMission.getCompletion (contract underwrite #741)")
    end

    if SoilLogger then
        SoilLogger.info("[OK] Harvest contract underwrite installed (HarvestMission.getCompletion)")
    end
    return true
end
