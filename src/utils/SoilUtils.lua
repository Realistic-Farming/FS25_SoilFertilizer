-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Shared Utilities
-- =========================================================
-- Author: TisonK
-- =========================================================

SoilUtils = {}

--- Returns true if the local player has admin rights.
--- Single-player: always true. Dedicated server console: always true.
--- Multiplayer client: checks master-user flag.
function SoilUtils.isPlayerAdmin()
    if not g_currentMission then return false end
    if not (g_currentMission.missionDynamicInfo and
            g_currentMission.missionDynamicInfo.isMultiplayer) then
        return true
    end
    if g_dedicatedServer then return true end
    local user = g_currentMission.userManager and
                 g_currentMission.userManager:getUserByUserId(g_currentMission.playerUserId)
    return user ~= nil and user:getIsMasterUser()
end

--- Returns the localized display name for a crop given its internal fruit-type name
--- (e.g. "WHEAT", "GREENRYE"). Soil data stores the raw uppercase identifier; rendering
--- it directly (capitalised, underscores → spaces) showed English names to every locale -
--- the Bodenmonitor mistranslation in #635. Each fruit type owns a fill type whose .title
--- is already localized by the engine, so resolve through that. Falls back to a prettified
--- raw name when no fruit/fill type matches (custom or unknown crops still read cleanly).
--- Returns nil for empty/nil input so callers can show their own "Fallow" label.
function SoilUtils.getCropDisplayName(name)
    if not name or name == "" then return nil end
    if g_fruitTypeManager then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(name)
        if fruitType and fruitType.fillType and fruitType.fillType.title
           and fruitType.fillType.title ~= "" then
            return fruitType.fillType.title
        end
    end
    return (name:sub(1, 1):upper() .. name:sub(2):lower()):gsub("_", " ")
end

--- Resolves the authoritative fill-type INDEX for a sprayer/spreader (issue #708).
---
--- The physical tank contents are the ground truth for what is actually being applied.
--- When AI/Courseplay restarts the implement at a headland turn, vanilla
--- Sprayer:onStartWorkAreaProcessing can resolve wap.sprayFillType through the AI's
--- fill-type selection / external-source path. On machines with multiple eligible fill
--- units this leaves wap.sprayFillType pointing at a different fill type than what is
--- physically loaded, which both mislabels the HUD "Pass:" line AND credits the wrong
--- nutrient profile to the soil.
---
--- Rule: if getSprayerFillUnitIndex() + getFillUnitFillType() returns a valid, non-UNKNOWN
--- type, the physical tank wins. Only when the tank reads empty/UNKNOWN - external-fill
--- BUY mode, or a source trailer feeding an empty sprayer - do we keep the passed-in
--- fallback (typically wap.sprayFillType), which then legitimately carries the intended
--- product. All pcall-wrapped so a malformed modded sprayer can never crash the caller.
---
--- @param sprayer table  the Sprayer-spec vehicle
--- @param fallbackIndex number|nil  index to use when the tank is empty/UNKNOWN
--- @return number|nil  the resolved fill-type index (physical tank, else fallbackIndex)
function SoilUtils.resolveSprayerFillTypeIndex(sprayer, fallbackIndex)
    if not sprayer or sprayer.getSprayerFillUnitIndex == nil or sprayer.getFillUnitFillType == nil then
        return fallbackIndex
    end
    local okFui, fillUnitIndex = pcall(function() return sprayer:getSprayerFillUnitIndex() end)
    if okFui and fillUnitIndex then
        local okFt, tankFt = pcall(function() return sprayer:getFillUnitFillType(fillUnitIndex) end)
        if okFt and tankFt and tankFt > 0 and tankFt ~= FillType.UNKNOWN then
            return tankFt
        end
    end
    return fallbackIndex
end
