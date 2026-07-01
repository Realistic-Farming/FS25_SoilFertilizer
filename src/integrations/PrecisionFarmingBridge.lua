-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Precision Farming detection
-- =========================================================
-- Soil & Fertilizer is intentionally NOT compatible with Precision Farming.
-- This helper exists only to DETECT whether PF is active in the current
-- savegame, so SoilFertilityManager can stand down (disable itself) instead
-- of running a second, conflicting nutrient simulation alongside PF.
--
-- There is no PF integration here: no map reads, no fill-type injection, no
-- data exchange, nothing written into PF. Detection to back off, nothing more.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class PrecisionFarmingBridge
PrecisionFarmingBridge = {}
local PrecisionFarmingBridge_mt = { __index = PrecisionFarmingBridge }

-- PF's mod directory name. Both g_modIsLoaded and missionDynamicInfo.mods
-- key on this exact name.
PrecisionFarmingBridge.PF_MOD_NAME = "FS25_precisionFarming"

--- Create a new (uninitialised) detector instance.
---@return PrecisionFarmingBridge
function PrecisionFarmingBridge:new()
    local o = setmetatable({}, PrecisionFarmingBridge_mt)
    o.isActive    = false
    o.detectedVia = nil     -- which signal proved PF active, for logging only
    return o
end

--- Detect whether Precision Farming is ACTIVE in the current savegame.
---
--- Uses the same "loaded into THIS running save" signals the base game uses,
--- so a mod that is merely installed-but-disabled does not trip detection:
---   Tier 1: g_modIsLoaded[name]    - engine table, true only for loaded mods.
---   Tier 2: missionDynamicInfo.mods - the active-mods list for this session.
--- Must be called after the mission is ready (deferred init phase).
---@return boolean isActive
function PrecisionFarmingBridge:initialize()
    local PF_MOD_NAME = PrecisionFarmingBridge.PF_MOD_NAME
    self.isActive    = false
    self.detectedVia = nil

    -- Tier 1 (authoritative): engine-maintained "is this mod loaded right now" table.
    pcall(function()
        if g_modIsLoaded ~= nil and g_modIsLoaded[PF_MOD_NAME] then
            self.isActive    = true
            self.detectedVia = "g_modIsLoaded"
        end
    end)

    -- Tier 2 (fallback): the active-mods list for this session, in case
    -- g_modIsLoaded is not yet populated at our init time.
    if not self.isActive then
        pcall(function()
            local dynInfo = (g_currentMission and g_currentMission.missionDynamicInfo)
                         or (g_mpLoadingScreen and g_mpLoadingScreen.missionDynamicInfo)
            local mods = dynInfo and dynInfo.mods
            if mods then
                for _, modInfo in ipairs(mods) do
                    if modInfo.modName == PF_MOD_NAME then
                        self.isActive    = true
                        self.detectedVia = "missionDynamicInfo.mods"
                        break
                    end
                end
            end
        end)
    end

    if self.isActive then
        SoilLogger.info("[PFBridge] Precision Farming active (detected via %s) - SF will stand down",
            tostring(self.detectedVia))
    else
        SoilLogger.info("[PFBridge] Precision Farming not active in this savegame - standalone mode")
    end

    return self.isActive
end
