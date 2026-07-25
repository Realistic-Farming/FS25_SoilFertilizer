-- duration_season_scaling_spec_test.lua - SF-31 / #740
--
-- A chemical's protection is an absolute in-game-day count tuned against a
-- reference season length (REFERENCE_DPP days per month). On a short 1-day-month
-- save an absolute 35-day fungicide covers ~3 game years (the #639/#740 bug), so
-- the application sites pass the count through SoilDuration.seasonScaled():
--
--     effectiveDays = max(1, round(baseDays * daysPerPeriod / REFERENCE_DPP))
--
-- daysPerPeriod comes from Time Guard's context; Time Guard absent means the
-- absolute count (today's behaviour). This test locks the mechanism and its two
-- deliberate exclusions (organic transition + fallow), so a tuning drift fails a
-- line rather than silently re-breaking short-calendar balance.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/utils/DurationScaling.lua

local scaled = SoilDuration.scaledDays
local REF = SoilConstants.DURATION.REFERENCE_DPP

-- ── 1. The reference constant is Tyson's ruling ──────────────────────────────
T.eq("REFERENCE_DPP is 3 (Tyson, 2026-07-23)", REF, 3)

-- ── 2. Reference-identity: a save at REFERENCE_DPP is unchanged ───────────────
T.eq("fungicide 35 unchanged at the reference season", scaled(35, 3), 35)
T.eq("herbicide 14 unchanged at the reference season", scaled(14, 3), 14)
T.eq("insecticide 30 unchanged at the reference season", scaled(30, 3), 30)

-- ── 3. The 12-day-year table (daysPerPeriod = 1) ─────────────────────────────
-- round(35/3)=12, round(14/3)=5, round(30/3)=10
T.eq("fungicide 35 -> 12 days at 1 day/month", scaled(35, 1), 12)
T.eq("herbicide 14 -> 5 days at 1 day/month", scaled(14, 1), 5)
T.eq("insecticide 30 -> 10 days at 1 day/month", scaled(30, 1), 10)

-- ── 4. Long-year growth (daysPerPeriod = 30) ─────────────────────────────────
T.eq("fungicide 35 -> 350 days at 30 days/month", scaled(35, 30), 350)

-- ── 5. The floor: never below one day ────────────────────────────────────────
T.eq("a 1-day base floors to 1 on a short save (round 0.33 -> 0 -> 1)", scaled(1, 1), 1)
T.eq("a 2-day base rounds to 1 on a short save", scaled(2, 1), 1)

-- ── 6. Degrade: Time Guard absent (daysPerPeriod nil) = absolute count ────────
T.eq("nil daysPerPeriod degrades to the absolute count", scaled(35, nil), 35)

-- ── 7. Same-fraction-of-any-year property ────────────────────────────────────
-- Doubling the season length doubles the cover; the ratio to the calendar holds.
T.eq("2x reference season doubles fungicide cover", scaled(35, 6), 70)
T.eq("2x reference season doubles insecticide cover", scaled(30, 6), 60)

-- ── 8. Exclusions: these are already season-honest and must NOT scale here ────
-- The organic transition normalises to YEARS via Time Guard at its own site;
-- the fallow threshold is multiplied by daysPerMonth at its read site. If either
-- ever gets wrapped in seasonScaled() it double-scales. We assert the raw
-- constants stay put as a drift tripwire.
T.eq("organic TRANSITION_DAYS untouched (excluded)", SoilConstants.ORGANIC.TRANSITION_DAYS[2], 120)
T.eq("fallow threshold untouched (excluded, scaled by daysPerMonth at its site)", SoilConstants.TIMING.FALLOW_THRESHOLD, 7)

-- ── 9. The Time Guard read wrapper (mocked mission) ──────────────────────────
local savedMission = g_currentMission

g_currentMission = nil
T.eq("getDaysPerPeriod is nil with no Time Guard", SoilDuration.getDaysPerPeriod(), nil)
T.eq("seasonScaled degrades to absolute with no Time Guard", SoilDuration.seasonScaled(35), 35)

g_currentMission = { timeGuard = { getContext = function() return { daysPerPeriod = 1 } end } }
T.eq("getDaysPerPeriod reads Time Guard's context", SoilDuration.getDaysPerPeriod(), 1)
T.eq("seasonScaled scales fungicide 35 -> 12 at 1 day/month via Time Guard", SoilDuration.seasonScaled(35), 12)

g_currentMission = savedMission
