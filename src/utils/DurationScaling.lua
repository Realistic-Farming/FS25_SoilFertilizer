-- =========================================================
-- DurationScaling.lua - season-scaled durations (SF-31 / #740)
-- =========================================================
-- A day of chemical protection should feel the same length relative to the
-- farming calendar on any save. A fungicide tuned to 35 days at REFERENCE_DPP
-- days-per-month should still cover ~35 days at that season length, but
-- proportionally fewer on a short 1-day-month save (where 35 absolute days is
-- ~3 game years, the #639/#740 problem).
--
-- MECHANISM (Arissani's ruling; Tyson's reference constant):
--     effectiveDays = max(1, round(baseDays * daysPerPeriod / REFERENCE_DPP))
--
-- Season length is read from TIME GUARD'S CONTEXT, the suite's single
-- days-per-period authority (a locked ecosystem rule: never query the calendar
-- privately). When Time Guard is absent the duration DEGRADES to the absolute
-- shipped count, exactly the behaviour before this change.
--
-- ONLY the absolute chemical day-counts scale here (fungicide, herbicide,
-- insecticide). The organic transition (TRANSITION_DAYS) and the fallow
-- threshold are ALREADY season-honest at their read sites and must NOT pass
-- through this, or they double-scale.
-- =========================================================

SoilDuration = {}

--- Days-per-period from Time Guard's context, or nil when Time Guard is absent.
-- Reads the suite's single season-length authority; never queries the calendar
-- directly. Returns nil (not a default) so callers degrade to the absolute count.
function SoilDuration.getDaysPerPeriod()
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.getContext) ~= "function" then
        return nil
    end
    local ok, ctx = pcall(function() return tg:getContext() end)
    if not ok or type(ctx) ~= "table" then
        return nil
    end
    local dpp = ctx.daysPerPeriod
    if type(dpp) ~= "number" or dpp < 1 then
        return nil
    end
    return dpp
end

--- Pure season-scaling. `daysPerPeriod == nil` degrades to the absolute count.
-- Kept free of globals (beyond the REFERENCE_DPP constant) so it is unit-testable.
function SoilDuration.scaledDays(baseDays, daysPerPeriod)
    if type(baseDays) ~= "number" then
        return baseDays
    end
    if daysPerPeriod == nil then
        return baseDays                    -- Time Guard absent: absolute, as today
    end
    local ref = (SoilConstants and SoilConstants.DURATION and SoilConstants.DURATION.REFERENCE_DPP) or 3
    if ref < 1 then ref = 1 end
    local scaled = math.floor(baseDays * daysPerPeriod / ref + 0.5)   -- round half up
    if scaled < 1 then scaled = 1 end      -- floor: never below one day
    return scaled
end

--- Read Time Guard and season-scale a base duration in one call.
function SoilDuration.seasonScaled(baseDays)
    return SoilDuration.scaledDays(baseDays, SoilDuration.getDaysPerPeriod())
end
