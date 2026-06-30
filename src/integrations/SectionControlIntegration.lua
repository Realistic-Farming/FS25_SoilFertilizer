-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Section Control Integration
-- =========================================================
-- Reads spec_variableWorkWidth.sections[i].isActive to determine
-- what fraction of the sprayer boom is actively spraying this frame.
-- When outer sections are shut off at field boundaries, SF scales
-- the nutrient credit to match the actual portion of boom working.
--
-- COMPATIBILITY
--   Works with vanilla VariableWorkWidth (spec_variableWorkWidth).
--   Gracefully degrades to 1.0 (no-op) if spec is absent.
--
-- WHY wap.usage IS ALREADY SCALED
--   VariableWorkWidth.getIsWorkAreaActive gates each work area on
--   section.isActive (LUADOC-verified).  The vanilla tank-drain path
--   therefore already reduces wap.usage proportionally.
--   We apply coverageFraction on top so that:
--     a) effectiveLiters stays correct when rateMultiplier != 1.0
--     b) future per-section field attribution has a clean hook point
-- =========================================================
-- Author: TisonK
-- =========================================================

--- Returns the fraction of the sprayer boom that is active this frame.
--- Returns 1.0 for vehicles without VariableWorkWidth or when all sections are on.
---@param vehicle table
---@return number coverageFraction 0.0–1.0  (1.0 = all sections on or no VWW)
function SoilUtils.getSectionCoverageFraction(vehicle)
    local vww = vehicle.spec_variableWorkWidth
    if vww == nil or vww.sections == nil or #vww.sections == 0 then
        return 1.0
    end

    local active = 0
    local total  = #vww.sections
    for _, section in ipairs(vww.sections) do
        -- isCenter sections are never added to sectionsLeft/sectionsRight so
        -- updateSectionStates never touches their isActive flag - guard explicitly.
        if section.isActive or section.isCenter then
            active = active + 1
        end
    end

    return total > 0 and (active / total) or 1.0
end

if VariableWorkWidth ~= nil then
    SoilLogger.info("[SectionControl] VariableWorkWidth found - section coverage fraction helper active")
else
    SoilLogger.info("[SectionControl] VariableWorkWidth not found - coverage helper returns 1.0 (no-op)")
end
