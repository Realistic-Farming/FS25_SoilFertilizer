-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Constants
-- =========================================================
-- All tunable values: timing, difficulty, nutrient limits,
-- crop extraction rates, fertilizer profiles, HUD config.
-- Single source of truth - modify here, not in system code.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilConstants
SoilConstants = SoilConstants or {}

-- ========================================
-- TIMING
-- ========================================
SoilConstants.TIMING = {
    UPDATE_INTERVAL = 30000,     -- ms between periodic checks
    FALLOW_THRESHOLD = 7,        -- days before fallow recovery kicks in (already season-scaled at its read site by daysPerMonth; do NOT season-scale again, see DURATION)
    MAX_DAILY_CATCHUP = 10,      -- cap on skipped days simulated in one catch-up pass
}

-- ========================================
-- DURATION SCALING (SF-31 / #740)
-- ========================================
-- The absolute chemical day-counts (fungicide/herbicide/insecticide) are tuned
-- against a reference season length. On a short 1-day-month save an absolute
-- 35-day fungicide would cover ~3 game years (the #639/#740 problem), so at the
-- application sites those counts pass through SoilDuration.seasonScaled(), which
-- reads days-per-period from Time Guard's context and scales:
--     effectiveDays = max(1, round(baseDays * daysPerPeriod / REFERENCE_DPP))
-- A save at REFERENCE_DPP days-per-month is unchanged; shorter saves scale down.
-- REFERENCE_DPP is the days-per-month the shipped duration constants were tuned
-- against (Tyson's ruling, 2026-07-23). Time Guard absent -> the absolute count.
-- EXCLUSIONS (already season-honest, must NOT double-scale): the organic
-- TRANSITION_YEARS (year-normalised via Time Guard at its own read site,
-- OrganicCertification:getTransitionDays) and the fallow threshold (multiplied
-- by daysPerMonth at its read site).
-- The drilling-window advisory: how far ahead the outlook reads (in days,
-- season-scaled via SoilDuration), the rain-likelihood at which a window turns
-- risky, and the ground-moisture below which the risky form is softened. These
-- are honest defaults, not derived agronomy; a balance-pass number.
SoilConstants.DRILLING = {
    ESTABLISHMENT_HORIZON_DAYS = 7,
    RISKY_LIKELIHOOD           = 0.4,
    WET_GROUND_MOISTURE        = 0.5,
}

SoilConstants.DURATION = {
    REFERENCE_DPP = 3,   -- days-per-month the chemical durations were tuned at
}

-- ========================================
-- DIFFICULTY MULTIPLIERS
-- ========================================
SoilConstants.DIFFICULTY = {
    EASY = 1,
    NORMAL = 2,
    HARD = 3,
    MULTIPLIERS = {
        [1] = 0.7,   -- Simple
        [2] = 1.0,   -- Realistic
        [3] = 1.5,   -- Hardcore
    },
    -- Fertilizer replenishment speed (applied to nutrient gain per litre)
    REPLENISHMENT_MULTIPLIERS = {
        [1] = 0.25,  -- Very Slow
        [2] = 0.50,  -- Slow
        [3] = 1.00,  -- Normal (default)
        [4] = 1.50,  -- Fast
        [5] = 2.00,  -- Very Fast
    }
}

-- ========================================
-- DEFAULT FIELD VALUES
-- ========================================
-- These defaults are calibrated to match the base game's initial field state:
--   pH 6.0  → "slightly acidic" in our system, consistent with base game "needs liming" at game start
--   N/P/K   → "fair" range (below optimal), consistent with base game "needs fertilizing" at game start
-- Players address both systems simultaneously: apply lime → base game lime state + our pH both rise;
-- apply fertilizer → base game fertilizer state + our N/P/K both rise.
-- Fields already saved in soilData.xml are not affected; only new/untracked fields use these values.
SoilConstants.FIELD_DEFAULTS = {
    nitrogen = 40,
    phosphorus = 30,
    potassium = 35,
    organicMatter = 3.5,
    pH = 6.0,
}

-- ========================================
-- FIELD VARIATION (initial soil diversity)
-- ========================================
-- Spread applied to a fresh field's starting nutrients so the map isn't uniform.
-- Two components are summed (see SoilFertilitySystem:getOrCreateField):
--   • REGIONAL - a smooth low-frequency gradient over the farmland centre, so
--     neighbouring fields share a similar profile and the map forms believable
--     good/poor regions (this is what answers "no variability", issue #632).
--   • NOISE - per-field jitter that decorrelates individual fields within a region.
-- N/P/K amounts are fractions of the base value; pH/OM are absolute units.
-- "Dramatic" spread (#632 follow-up): widened so fields differ enough that you
-- should inspect a field before buying it. Some land is genuinely poor, some rich.
-- Regional gives believable good/poor REGIONS; noise decorrelates fields within them.
SoilConstants.FIELD_VARIATION = {
    NPK_REGIONAL = 0.40,    -- ±40% of base N/P/K from the regional gradient
    NPK_NOISE    = 0.30,    -- ±30% of base N/P/K per-field noise
    OM_REGIONAL  = 2.5,     -- ± organic-matter points from the regional gradient
    OM_NOISE     = 2.5,     -- ± organic-matter points per-field noise
    PH_REGIONAL  = 0.7,     -- ± pH units from the regional gradient
    PH_NOISE     = 0.5,     -- ± pH units per-field noise
    REGION_FREQ  = 0.0016,  -- spatial frequency of the gradient (~1 cycle per ~620 m)
}

-- ========================================
-- RELIEF WEIGHT (SF-20)
-- ========================================
-- Organic matter varies within a field by where each patch sits in that field's
-- own relief: water and material collect downhill, so LOW ground is richer.
-- Painted into the organicMatter value map at seed time (and as the base fill on
-- the legacy migration); nothing new is stored and nothing new goes on the wire.
SoilConstants.RELIEF = {
    -- Peak-to-peak OM variation across one field, as a FRACTION of that field's
    -- own OM stock. The brief's balance anchor is roughly 5-20% of stock.
    -- This is the AGRONOMY dial magnitude of the suite difficulty framework,
    -- resolved through the vendored resolver (OptionScalingResolver,
    -- FS25_SettingsHub) when the Option-Scaling Spine ships. Until then the
    -- neutral identity below is the honest value. One-line change when the
    -- resolver lands, and deliberately NOT a SoilFertilizer setting (the brief's
    -- dial-neutral contract: this mod already carries two local difficulty axes).
    AMPLITUDE_FRACTION = 0.15,
    -- Neutral identity for the Agronomy dial until the spine resolves it.
    AGRONOMY_SCALE = 1.0,
    -- Height range (metres) across a field below which the field carries no
    -- relief information. Under it every deviation is zero and seeding falls
    -- back to the existing cosmetic spread, so a flat field looks exactly as it
    -- does today rather than becoming a flat colour block.
    MIN_RANGE = 1.5,
    -- Terrain-sample and paint block size (metres). Matches the existing seed
    -- block size; sampling finer than the heightmap unit returns interpolation
    -- rather than information.
    BLOCK_SIZE = 8,
    -- Floor on the computed amplitude (OM points). Below this the deviation is
    -- not worth a second pass over the polygon.
    MIN_AMPLITUDE = 0.05,
}

-- ========================================
-- PLOWING
-- ========================================
-- Thresholds for plowing operations
SoilConstants.PLOWING = {
    MIN_DEPTH_FOR_PLOWING = 0.15,  -- Minimum working depth (meters) to qualify as deep plowing
    PEST_PRESSURE_REDUCTION    = 30,  -- Points removed from pest pressure on plowing
    -- #737 option D: was 40, which cleared roughly six years of disease accumulation
    -- (~6.8 pts/year) in a single pass and pinned the pressure near zero for anyone
    -- who ploughs at all. 18 clears about 2.6 years: a real reset, not an erase.
    -- Holds the STRICT physical ordering the constants file documents, by how much
    -- infected residue each implement buries:
    --     plough 18  >  cultivator 15  >  strip-till 10 (residue left on the surface)
    DISEASE_PRESSURE_REDUCTION = 18,
}

-- ========================================
-- CULTIVATION (shallow tillage - non-plowing passes)
-- ========================================
-- WEED_PRESSURE_REDUCTION set to 100 so a single full cultivation pass fully clears
-- weed pressure (the hook fires per-area tick, clamped to 0 by math.max).
-- Agronomically correct: shallow tillage disrupts annual weed seedlings entirely;
-- only perennial roots survive, which the game does not distinguish.
SoilConstants.CULTIVATION = {
    WEED_PRESSURE_REDUCTION    = 100, -- Full reset (was 20 - insufficient for clearing all weeds)
    PEST_PRESSURE_REDUCTION    = 10,
    DISEASE_PRESSURE_REDUCTION = 15,
}

-- ========================================
-- STRIP-TILL / RIDGE TILLER
-- ========================================
-- Strip-till (e.g. Orthman) tills narrow 6-8" deep knife-bands (~30% of
-- field surface).  Surface residue stays in the untilled zones, so:
--   • Weeds: LESS effective than full cultivator (partial coverage)
--   • Pests: MORE effective than cultivator (deep knife disrupts soil larvae)
--   • Disease: LESS than cultivator (residue left on surface → spore habitat)
--   • No pH normalization (no soil layer inversion)
--   • OM: modest net gain per pass - its residue incorporation (below) less its
--     light oxidation (OM_DYNAMICS.OXIDATION.STRIP_TILL). The old separate OM_BOOST
--     (+0.10/pass) was RETIRED into this single residue+oxidation gradient (#738), so
--     strip-till has one gain term and one loss term like every other tillage type.
--     Its generosity is preserved by its LOW oxidation (0.02), not a bloated gain.
-- The RidgeTiller FS25 spec (processRidgeTillerArea / RIDGEFORMER work area)
-- is completely separate from Cultivator.processCultivatorArea, so a dedicated
-- hook is required.
SoilConstants.STRIP_TILL = {
    WEED_PRESSURE_REDUCTION    = 15,  -- pts; less than cultivator (partial surface coverage)
    PEST_PRESSURE_REDUCTION    = 12,  -- pts; more than cultivator (deep knife action)
    DISEASE_PRESSURE_REDUCTION = 10,  -- pts; less than cultivator (residue left in place)
    -- OM_BOOST retired into the residue+oxidation gradient (#738). No pH normalization.
}

-- ========================================
-- RESIDUE INCORPORATION (Issue #338)
-- ========================================
-- When post-harvest tillage works stubble and straw residue back into
-- the soil, it decomposes and releases a small amount of organic matter
-- and nutrients (especially N and K from cereal straw, P is minimal).
-- Each tillage type has its own incorporation efficiency:
--   Plow      : deepest incorporation - highest OM and N release
--   Cultivator: shallow mixing - moderate OM release, small NPK
--   Strip-till: partial surface coverage - lowest incorporation
--   Sowing    : direct-drill openers disturb minimal residue
--
-- All values are per-pass additive boosts (on the 0-100 scale for N/P/K,
-- and on the 0-10 OM scale). They are small by design - straw residue
-- decomposes over weeks/months, so a single tillage pass incorporates
-- only a fraction. The plowingBonus setting gates the plow path; all
-- other paths are gated by the new residueIncorporation setting.
--
-- Agronomic reference (Midwestern US extension, kg/ha per tonne of straw):
--   Cereal straw typically contains: N=6, P=0.8, K=12, C=430 (kg/tonne)
--   OM contribution ≈ 40-50% of straw C converted to stable humus over 1+ yr
--   A single tillage pass incorporates ~30-60% of surface residue.
--   At 4-6 t/ha straw (wheat/maize at game scale), that translates to:
--   Plow:      OM+0.12, N+0.8, P+0.1, K+0.6  (60% incorporation efficiency)
--   Cultivator:OM+0.06, N+0.4, P+0.05,K+0.3  (30% incorporation)
--   Strip-till: OM+0.03, N+0.2, P+0.02,K+0.15 (15% - only tilled strips)
--   Direct-drill: OM+0.02, N+0.1, P+0.01,K+0.08 (10% - opener disturbance only)
SoilConstants.RESIDUE_INCORPORATION = {
    PLOW = {
        OM = 0.15,   -- increased from 0.12
        N  = 5.0,    -- increased from 0.8 for game visibility
        P  = 1.5,    -- increased from 0.1
        K  = 3.5,    -- increased from 0.6
    },
    CULTIVATOR = {
        OM = 0.08,   -- increased from 0.06
        N  = 2.5,    -- increased from 0.4
        P  = 0.8,    -- increased from 0.05
        K  = 1.8,    -- increased from 0.3
    },
    STRIP_TILL = {
        OM = 0.05,   -- increased from 0.03 for game visibility
        N  = 1.2,    -- increased from 0.2
        P  = 0.4,    -- increased from 0.02
        K  = 0.8,    -- increased from 0.15
    },
    DIRECT_DRILL = {
        OM = 0.03,   -- increased from 0.02 for game visibility
        N  = 0.6,    -- increased from 0.1
        P  = 0.2,    -- increased from 0.01
        K  = 0.4,    -- increased from 0.08
    },
}

-- ========================================
-- CROP INCORPORATION (Issue #674 - green manure / cover-crop / failed-crop tillage)
-- ========================================
-- Working a STANDING or dead crop into the soil - green manure, an over-wintered
-- cover crop, a failed/burned crop, or a tall stubble - releases far more organic
-- matter and nitrogen than tilling bare soil. This is applied ON TOP of residue
-- incorporation, and ONLY when a crop is actually detected at the work position
-- (via a FieldState query in the onStartWorkAreaProcessing probe, before the tool
-- clears the fruit). Values below are the maximum per full-field pass at full crop
-- biomass; they are scaled by the crop's biomass factor (0..1, from growth state)
-- and the processed area fraction. Gated by the existing residueIncorporation setting.
--
-- Agronomic basis: incorporating a green-manure / cover crop (e.g. oilseed radish,
-- mustard, clover) returns the whole standing biomass to the soil - typically several
-- tonnes/ha of fresh matter - versus only surface straw for stubble residue.
SoilConstants.CROP_INCORPORATION = {
    PLOW       = { OM = 1.2,  N = 6.0, P = 1.2, K = 4.0 },  -- deep inversion - fullest burial
    CULTIVATOR = { OM = 0.7,  N = 3.5, P = 0.7, K = 2.2 },  -- shallow mixing
    MULCHER    = { OM = 0.6,  N = 2.5, P = 0.5, K = 1.5 },  -- surface chop, no soil inversion
    SOWING     = { OM = 0.4,  N = 2.0, P = 0.4, K = 1.2 },  -- #778 direct drill: opener slot only, no inversion
    MIN_BIOMASS = 0.30,   -- floor biomass factor once an established crop (past seedling) is detected
    SEEDLING_GROWTH_STATE = 1,  -- growth states at/below this are negligible biomass (just emerged)
}

-- ========================================
-- NUTRIENT LIMITS
-- ========================================
SoilConstants.NUTRIENT_LIMITS = {
    MIN = 0,
    MAX = 100,
    ORGANIC_MATTER_MAX = 10,
    PH_MIN = 5.0,
    PH_MAX = 7.5,
    PH_NEUTRAL_LOW = 6.5,
    PH_NEUTRAL_HIGH = 7.0,
    -- Single authoritative optimal pH target used by yield urgency, auto-rate, and
    -- any future calculations.  6.5 is the agronomic mid-point.
    PH_OPTIMAL = 6.5,
}

-- ========================================
-- NUTRIENT RECOVERY RATES (per day, fallow fields)
-- ========================================
-- Adjusted for 0-100 scale (slower natural recovery rate)
SoilConstants.FALLOW_RECOVERY = {
    nitrogen = 0.07,      -- ~1 year to recover 25 points
    phosphorus = 0.03,    -- Phosphorus recovers slower
    potassium = 0.05,     -- Moderate recovery
    organicMatter = 0.01, -- Organic matter accumulates very slowly
}

-- ========================================
-- ORGANIC MATTER DYNAMICS (#695)
-- ========================================
-- Humus oxidizes continuously. Without organic returns, a field under active cropping
-- slowly loses OM; an idle (fallow) field still nets positive because FALLOW_RECOVERY
-- adds organicMatter on top of this decay (0.01 recovery − 0.005 decay = +0.005/day).
-- Deep tillage (plowing) accelerates the loss by exposing buried humus to air.
-- All on the 0-10 OM scale; per-day rates are month-normalised by the caller.
SoilConstants.OM_DYNAMICS = {
    DAILY_DECAY = 0.005, -- passive humus oxidation, OM pts/day
    DECAY_FLOOR = 1.0,   -- passive decay never pushes OM below this (degraded mineral soil)

    -- #738 no-till OM: per-tillage OXIDATION gradient. OM burned per full pass by
    -- disturbing/aerating buried humus. Monotone with soil disturbance:
    --   plough (deep inversion) > cultivator (topsoil mix) > strip-till (knife bands)
    --   > direct-drill (opener slot, none).
    -- STEEP at the top on purpose: the plough's oxidation (0.14) approaches its own
    -- residue burst (0.15), so a ploughed field nets near-flat and slowly mines OM
    -- against daily decay, while a no-till field builds it. Together with the residue
    -- incorporation gains and the no-till daily credit below, the SEASON OM trajectory
    -- ranks direct-drill > strip-till > cultivator > plough (the #738 ruled ordering).
    -- Magnitudes are XML-configurable and Agronomy-dial-scalable (Tyson's to tune).
    OXIDATION = {
        PLOW         = 0.14,  -- was the lone PLOW_OXIDATION_LOSS 0.10; steepened for the gradient
        CULTIVATOR   = 0.06,
        STRIP_TILL   = 0.02,
        DIRECT_DRILL = 0.00,  -- opener disturbance does not aerate buried humus
    },

    -- #738 no-till seasonal credit: OM/day gained by a field under an ACTIVE crop
    -- that was DRILLED INTO UNTILLED RESIDUE (no plough/cultivator/strip pass since the
    -- last harvest) - the preserved residue mat slowly humifying. Applied on the daily
    -- pass, fenced against the fallow OM recovery (only while a crop grows) so the two
    -- never stack. Smaller than the daily decay it offsets, so a no-till field still
    -- loses a little OM day to day but far less than a tilled one, and skips the
    -- per-pass oxidation hit entirely - the season-long reason no-till builds carbon.
    NO_TILL_DAILY_CREDIT = 0.004,

    TILLAGE_DECOMPOSITION = {
        PLOWED   = 1.0,
        STUBBLE  = 0.8,
        UNTILLED = 0.6,
    },
}

-- ========================================
-- MEADOW PROFILE (FieldSentry Phase 3, #651)
-- ========================================
-- Daily grassland rates used when a field is flagged as a meadow in FieldSentry. Opt-in
-- per field, so this never affects normal cropland. A meadow follows grassland rules
-- instead of crop-rotation rules: gentle nutrient regrowth (root turnover + clover/legume
-- fixation in the sward), a slow creep in organic matter, slow pH drift, and no rotation
-- or seasonal-harvest penalties. Slightly more generous than bare fallow because an
-- established sward cycles nutrients better than open ground. All TUNABLE - these want
-- in-game balancing against real pasture behaviour.
SoilConstants.MEADOW = {
    REGROW_N        = 0.10,   -- N points/day regrown
    REGROW_P        = 0.04,
    REGROW_K        = 0.06,
    OM_GAIN         = 0.01,   -- organic matter % points/day (slow build, matches fallow)
    PH_DRIFT_FACTOR = 0.5,    -- pH normalises at half the cropland rate
    PRESSURE_DECAY  = 2.0,    -- weed/pest/disease pressure points shed per day on grass
}

-- ========================================
-- CHOPPED STRAW / CHAFF ORGANIC MATTER GAIN
-- ========================================
-- When a combine chops straw instead of dropping it, the material decomposes
-- into the soil and adds organic matter (realistic agricultural behaviour).
-- OM is a concentration - gain uses (areaHa / fieldAreaHa) * strawRatio * OM_RATE.
-- A complete field harvest at strawRatio=1.0 adds exactly OM_RATE to the field,
-- regardless of field size. Partial passes add a proportional fraction.
-- Example: full 5ha field, strawRatio=0.5 → 0.5 × 0.20 = 0.10 OM
SoilConstants.CHOPPED_STRAW = {
    OM_RATE = 0.06,   -- OM gain per full-field harvest at strawRatio=1.0 (lowered from 0.20:
                      -- straw is fresh carbon that takes months to stabilise into humus, #695)
}

-- ========================================
-- SEASONAL EFFECTS (per day)
-- ========================================
-- Adjusted for 0-100 scale (subtle seasonal changes)
SoilConstants.SEASONAL_EFFECTS = {
    SPRING_NITROGEN_BOOST = 0.03,  -- Small spring boost from biological activity
    FALL_NITROGEN_LOSS = 0.02,     -- Gradual fall depletion
    SPRING_SEASON = 1,
    FALL_SEASON = 3,
    WINTER_SEASON = 4,             -- dormancy: legume N fixation pauses (#674)
}

-- ========================================
-- CROP ROTATION
-- ========================================
SoilConstants.CROP_ROTATION = {
    LEGUME_BONUS_N_PER_DAY  = 0.5,   -- N added per day during the post-crop spring bonus window
    LEGUME_BONUS_DAYS       = 3,     -- spring bonus lasts this many days
    LEGUME_GROWTH_N_PER_DAY = 0.15,  -- small live N trickle while a legume is standing (nodule fixation surplus, #674) - deliberately well below the post-crop bonus so we don't double-count
    FATIGUE_MULTIPLIER      = 1.15,  -- nutrient extraction ×1.15 for same-crop consecutive seasons
    -- alfalfa == luzerne (NA vs EU name); greenbean/green_beans match field beans.
    -- All fix nitrogen, so rotating away from them earns the spring N bonus (#694).
    LEGUMES = { soybean = true, peas = true, beans = true, luzerne = true, clover = true,
                alfalfa = true, greenbean = true, green_beans = true },
}

-- ========================================
-- pH NORMALIZATION (per day)
-- ========================================
SoilConstants.PH_NORMALIZATION = {
    RATE = 0.01,
}

-- ========================================
-- RAIN EFFECTS
-- ========================================
-- Adjusted for 0-100 nutrient scale
SoilConstants.RAIN = {
    LEACH_BASE_FACTOR = 0.00000008,  -- base leach per dt per rainScale (÷12 for scale adjustment)
    NITROGEN_MULTIPLIER = 5,         -- nitrogen leaches most (mobile nutrient)
    POTASSIUM_MULTIPLIER = 2,        -- potassium moderate leaching
    PHOSPHORUS_MULTIPLIER = 0.5,     -- phosphorus binds to soil (least mobile)
    PH_ACIDIFICATION = 0.1,          -- rain acidification multiplier
    MIN_RAIN_THRESHOLD = 0.1,        -- minimum rainScale to trigger effects

    -- SCS-001 irrigation-driven leaching (reads SeasonalCropStress moisture, SF-side).
    -- Sustained soil moisture (rain AND irrigation) costs nutrients, so irrigation is a
    -- trade-off, not a free yield lever. Neutral (no effect) when SCS is absent. Numbers
    -- are conservative + VISIBLE-first anchors; final values ride the Soil balance pass.
    IRRIGATION_LEACH_THRESHOLD = 0.55,   -- SCS moisture (0-1) above which a non-rain field leaches
    IRRIGATION_LEACH_SCALE     = 0.40,   -- how hard saturated irrigation drives leaching vs rain (<1 = gentler)
    MOISTURE_LEACH_GAIN        = 0.50,   -- extra leaching from sustained moisture (amplifies the rain factor)
    OM_LEACH_DAMPEN            = 0.50,   -- high organic matter (0-10) softens the moisture add (buffer)
    IRRIGATION_LEACH_INTERVAL_MS = 30000,-- throttle for the no-rain irrigation leach pass (accumulated dt)
    -- #740 filled-day irrigation: on a short-month FILLED-wet day SF supplies the
    -- precipitation, so SCS's rain-reflecting moisture LEVEL is not counted (it would
    -- double-count). Real irrigation is still counted, read as the irrigation-only RATE
    -- (getIrrigationRate, moisture-gain per hour) and normalized to a 0-1 intensity
    -- against this reference before driving leach. Matches SCS's default flowRatePerHour
    -- (0.018); SF-side tunable, so it stays decoupled from SCS internals.
    IRRIGATION_RATE_LEACH_REF  = 0.018,  -- irrigation rate (per-hour gain) that counts as full-intensity irrigation
}

-- ========================================
-- CROP EXTRACTION RATES (per 1,000 liters harvested)
-- ========================================
-- Calibrated for 0-100 nutrient scale (normalized by field area)
-- Typical 1-hectare field yields ~8,000L, resulting in 15-25% nutrient depletion
-- Example: 8,000L wheat depletes 16N, 6.4P, 12K (from defaults 50N, 40P, 45K)
SoilConstants.CROP_EXTRACTION = {
    wheat      = { N=2.00, P=0.80, K=1.50 },  -- Moderate N demand, standard grain
    barley     = { N=1.80, P=0.80, K=1.40 },  -- Similar to wheat, slightly less
    maize      = { N=2.30, P=1.00, K=2.00 },  -- High N/P demand, large biomass
    canola     = { N=2.70, P=1.20, K=2.20 },  -- High N demand, oilseed
    soybean    = { N=3.20, P=1.30, K=1.70 },  -- Highest N (compensates for fixation)
    sunflower  = { N=2.50, P=1.10, K=2.30 },  -- Moderate-high demand
    potato     = { N=3.80, P=1.70, K=5.40 },  -- Very high K demand (tuber crop)
    sugarbeet  = { N=3.30, P=1.50, K=5.80 },  -- Extreme K demand (root crop)
    oat        = { N=1.80, P=0.90, K=1.60 },  -- Light feeder
    rye        = { N=2.00, P=0.80, K=1.80 },  -- Moderate demand
    triticale  = { N=2.10, P=1.00, K=1.90 },  -- Hybrid characteristics
    sorghum    = { N=2.30, P=0.90, K=1.80 },  -- Efficient nutrient user
    peas       = { N=2.90, P=1.10, K=2.00 },  -- Legume, moderate demand
    beans      = { N=3.00, P=1.20, K=2.10 },  -- Legume, similar to peas

    -- Expanded coverage (issue #630, seeded from Arissani's crop NPK dataset).
    -- Values stay on the existing unitless 0-100 depletion scale and are tuned
    -- relative to the agronomically-similar crop above, NOT mapped 1:1 from the
    -- CSV's kg/ha (those are uptake/demand figures, not our depletion units).
    -- These retire the generic fallback for the common base + modded map crops.
    rice          = { N=2.00, P=1.05, K=1.60 },  -- Paddy cereal, higher P than wheat
    ricelonggrain = { N=2.10, P=1.10, K=1.70 },  -- Long-grain variant, slightly hungrier
    cotton        = { N=2.40, P=1.10, K=2.00 },  -- Fibre crop, steady N/K draw
    sugarcane     = { N=2.80, P=1.30, K=3.50 },  -- High biomass, heavy K feeder
    carrot        = { N=2.60, P=1.20, K=3.80 },  -- Root crop, high K demand
    parsnip       = { N=2.40, P=1.20, K=3.50 },  -- Root crop, similar to carrot
    beetroot      = { N=2.80, P=1.30, K=4.00 },  -- Root crop, very high K
    onion         = { N=2.50, P=1.20, K=2.50 },  -- Bulb crop, moderate-high demand
    spinach       = { N=2.20, P=0.90, K=1.60 },  -- Leafy green, N-driven
    spelt         = { N=1.90, P=0.80, K=1.60 },  -- Ancient wheat, light cereal
    rye_mf        = { N=2.00, P=0.80, K=1.80 },  -- Multifruit rye alias (= rye)
    greenbean     = { N=3.00, P=1.20, K=2.10 },  -- Legume, as field beans
    green_beans   = { N=3.00, P=1.20, K=2.10 },  -- Legume name variant
    mustard       = { N=2.20, P=0.90, K=1.60 },  -- Brassica oilseed/catch crop
}

-- Perennial forage crops (mowable, regrow after a cut without re-seeding).
-- Used by issue #629: organic fertilizer (slurry/manure/digestate) spread on these
-- while the sward is short (growthState below minHarvestingGrowthState) does NOT
-- trigger the OM amendment-burn penalty, matching real meadow/pasture management.
-- Keys are lowercase FS25 fruit-type names.
SoilConstants.PERENNIAL_FORAGE_NAMES = {
    grass      = true,
    meadow     = true,
    drygrass   = true,
    fieldgrass = true,
    ryegrass   = true,
    alfalfa    = true,
    luzerne    = true,
    clover     = true,
}

-- Default extraction for unknown crops (average cereal)
SoilConstants.CROP_EXTRACTION_DEFAULT = { N=2.10, P=0.90, K=1.70 }

-- Forage extraction rates for mowed crops (grass, alfalfa, clover, etc.)
-- These crops are not in CROP_EXTRACTION because they are not direct-threshed;
-- their nutrient removal is triggered by the Mower hook (area-based, not liter-based).
-- Calibrated per MOWER_HA_FACTOR unit: mowing 1 ha of grass removes ~8 N-units
-- (~57% of a 1-ha wheat harvest), reflecting a single cutting in a multi-cut season.
SoilConstants.CROP_EXTRACTION_FORAGE = { N=1.40, P=0.55, K=1.80 }

-- Mower area calibration factor.
-- Formula: depletion = rates[nutrient] * areaHa * MOWER_HA_FACTOR * difficultyMult
-- At factor=6.0, grass/alfalfa: N=8.4, P=3.3, K=10.8 units depleted per ha per cut.
-- Compare: wheat harvest 1ha at 7000L → N=14.7, P=6.3, K=11.9. Forage ~57% of grain.
SoilConstants.MOWER_HA_FACTOR = 6.0

-- Harvest area calibration factor.
-- addCutterArea's liters parameter is a 0/1 flag, not actual yield volume.
-- Area is used instead; this factor scales it to match extraction rate calibration.
-- Value = typical yield in L/ha / 1000 = 8000/1000 = 8.0.
-- Formula: factor = (areaHa / fieldAreaHa) * HARVEST_HA_FACTOR
-- At factor=8.0, wheat 1ha: N=16, P=6.4, K=12 depleted (matches extraction rate comments).
SoilConstants.HARVEST_HA_FACTOR = 8.0

-- ========================================
-- FERTILIZER PROFILES (per 1,000 liters applied)
-- ========================================
-- Calibrated for 0-100 nutrient scale (normalized by field area)
-- UPDATED V1.7: Coefficients are now volume-normalized relative to baseRates
-- to produce realistic soil-test responses (Mehlich-3 ppm) in one pass.
-- Formula: coeff = (target_ppm / display_mult) / (baseRate * 0.9 / 1000)
-- Amendment burn (#437) tuning. A freshly-sown / seedling annual has no leaf canopy to
-- scorch, so applying starter fertilizer or a pre-plant amendment at/just after seeding
-- must NOT burn it (#681). The burn only applies once the crop has established past this
-- fraction of the way to its harvest-ready growth state.
SoilConstants.AMEND_BURN = {
    ANNUAL_SEEDLING_FRACTION = 0.33,
    -- Gradual build-up (#688): the burn ramps toward these caps over the same metered
    -- application time as the over-application burn (SPRAYER_RATE.BURN_FULL_DAMAGE_MS),
    -- instead of jumping to the cap on first contact. An accidental brush or a slide onto
    -- the field costs only a small slice, so you have time to shut the sprayer off.
    LIME_MAX = 0.80,   -- lime/LIQUIDLIME on an established crop, fully built up
    OM_MAX   = 0.20,   -- organic amendment (slurry/manure/digestate) fully built up
    -- Finished compost is gentler than fresh slurry/manure on an established crop: stabilized
    -- humus carries no free salt or ammonia to scorch the canopy, so it caps well below OM_MAX.
    -- Agronomic constant (true at every difficulty, not a spine dial) - Arissani, 2026-07-24.
    COMPOST_MAX = 0.08,
}

SoilConstants.FERTILIZER_PROFILES = {
    -- Base game (NPK balanced)
    LIQUIDFERTILIZER  = { N=79.2, P=198.0, K=44.5 },          -- 93.5 L/ha: ~20N, ~10P, ~15K ppm
    FERTILIZER        = { N=41.1, P=164.6, K=24.7 },          -- 225 kg/ha: ~25N, ~20P, ~20K ppm
    MANURE            = { N=0.53, P=0.25,  K=0.45, OM=0.04 }, -- 14000 L/ha: ~7N, ~3.5P, ~6K pts/pass (UNL beef N:P:K ratio)
    LIQUIDMANURE      = { N=0.50, P=0.35,  K=0.65, OM=0.03 }, -- Slurry - dairy N:P:K 1:0.70:1.33 (UNL g1335)
    DIGESTATE         = { N=1.32, P=0.80,  K=0.80, OM=0.04 }, -- Digestate - 12,600 L/ha → ~50N/6P/40K ppm per pass (calibrated with real farmer input)
    LIME              = { pH=0.16 },                          -- 2500 kg/ha: +0.40 pH shift per pass (~3 passes to correct pH 5.5→6.5)
    LIQUIDLIME        = { pH=1.07 },                          -- 374  L/ha: +0.40 pH shift per pass (rate corrected from 2800→374 L/ha)

    -- Nitrogen sources (high-concentration)
    UAN32             = { N=243.6, P=0.00, K=0.00 }, -- 60.8 L/ha: ~40N ppm
    UAN28             = { N=210.0, P=0.00, K=0.00 }, -- 60.8 L/ha: ~35N ppm
    ANHYDROUS         = { N=793.6, P=0.00, K=0.00 }, -- 28.0 L/ha: ~60N ppm (strongest)
    AMS               = { N=66.2,  P=0.00, K=0.00 }, -- 168 kg/ha: ~30N ppm
    UREA              = { N=154.6, P=0.00, K=0.00 }, -- 168 kg/ha: ~70N ppm
    AN                = { N=114.0, P=0.00, K=0.00 }, -- 200 kg/ha: ~62N ppm (AN 34.5% N)

    -- Starter fertilizer (High-P pop-up)
    STARTER           = { N=63.5, P=595.0, K=0.00 }, -- 46.8 L/ha: ~8N, ~15P ppm

    -- Gypsum: mild pH lowering + OM/structure boost
    GYPSUM            = { pH=-0.10, OM=0.03 }, -- 1500 kg/ha: -0.25 pH shift; gypsum is Ca/S, not a humus source - minimal OM (#695)

    -- Phosphorus & potassium sources (Dry bulk)
    MAP               = { N=11.1, P=411.5, K=0.00 }, -- 225 kg/ha: ~45P ppm
    DAP               = { N=16.4, P=329.2, K=0.00 }, -- 225 kg/ha: ~40P ppm
    POTASH            = { N=0.00, P=0.00, K=100.0 }, -- 225 kg/ha: ~22.5 K pts/pass; 70-90 kg/ha ≈ 7-9 pts (realistic 1-pass fix)
    POLIFOSKA         = { N=5.4, P=143.0, K=50.0 },  -- 6-20-30 NPK compound; 250 kg/ha: ~1.4N +36P +12.5K ppm

    -- Liquid equivalents (match dry profiles)
    LIQUID_UREA       = { N=154.6, P=0.00, K=0.00 },
    LIQUID_AMS        = { N=66.2,  P=0.00, K=0.00 },
    LIQUID_MAP        = { N=11.1, P=411.5, K=0.00 },
    LIQUID_DAP        = { N=16.4, P=329.2, K=0.00 },
    LIQUID_POTASH     = { N=0.00, P=0.00, K=100.0 },

    -- Organic / slow-release
    -- OM gains lowered to realistic first-season humus conversion (~10-15% of applied
    -- carbon stabilises in year one). N/P/K unchanged - only the humus build rate (#695).
    COMPOST           = { N=0.74, P=0.55, K=0.55, OM=0.12 }, -- 5000 kg/ha
    BIOSOLIDS         = { N=2.05, P=1.20, K=1.23, OM=0.10 }, -- 4500 kg/ha: ~+9N, +5P, +5K pts/pass
    CHICKEN_MANURE    = { N=3.70, P=2.80, K=2.78, OM=0.10 }, -- 2000 kg/ha: ~+7N, +5P, +5K pts/pass
    PELLETIZED_MANURE = { N=16.4, P=8.20, K=18.5, OM=0.08 }, -- 450 kg/ha:  ~+7N, +3P, +8K pts/pass

    -- Crop protection products (Handled via effectiveness calculation)
    INSECTICIDE = { pestReduction = 1.0 },
    FUNGICIDE   = { diseaseReduction = 1.0 },
}

-- ========================================
-- HEAT SCORCH (CD-14): the correct dose on the wrong day
-- ========================================
-- Products whose active ingredient damages the SOIL under a standing established
-- crop when sprayed hot (pH down, nitrogen drained; the crop is not killed and
-- the chemical still works). shift lowers the product's risk temperature:
--   riskT    = HEAT_RISK_BASE - shift          (first scorch risk here)
--   certainT = riskT + HEAT_BAND_WIDTH         (full band damage at/above here)
-- HEAT_RISK_BASE / HEAT_BAND_WIDTH and the per-band caps live in SPRAYER_RATE.
-- SHIP stand-ins marked ARISSANI'S at the unlock (steward C2); every number here
-- is a ratio-pass candidate recorded awaiting the spine. v1 carries no lime/OM
-- amendment entries (the table fence: nothing with entry.pH/entry.OM).
SoilConstants.HEAT_SENSITIVITY = {
    SULFUR           = { shift = 4 },  -- elemental S oxidises hot; the classic case
    COPPER_HYDROXIDE = { shift = 2 },
}

-- ========================================
-- ORGANIC CERTIFICATION (per-field state layer over the OM substrate)
-- ========================================
-- A field moves conventional -> in_transition -> certified by being farmed with
-- ONLY organic-approved inputs for a difficulty-scaled number of in-game days.
-- Applying any synthetic input to a transitioning/certified field is a breach:
-- full reset to conventional (Tison's call). Entry is explicit opt-in only.
SoilConstants.ORGANIC = {
    STATE_CONVENTIONAL = "conventional",
    STATE_TRANSITION   = "in_transition",
    STATE_CERTIFIED    = "certified",

    -- Transition length in ORGANIC YEARS, indexed by difficulty (1 Simple /
    -- 2 Realistic / 3 Hardcore). Resolved to a day threshold at read time via Time
    -- Guard's days-per-period, so "N years" means N in-game years on any save
    -- (OrganicCertification:getTransitionDays). A raw day count silently turned
    -- the intended multi-year commitment into anything from months to decades
    -- depending on days-per-month. Values are the INDICATIVE easy<standard<hard
    -- set (standard ~3 years per the USDA/SARE anchor); the exact per-difficulty
    -- values ride the Option-Scaling Spine + the balance pass.
    TRANSITION_YEARS = { 2, 3, 5 },

    -- Yield factor vs an optimally synthetic-fertilised field. Organic amendments +
    -- high OM offset part of this through the existing OM_YIELD pipeline, so these
    -- are deliberately mild; the real reward is the market premium (other repo).
    TRANSITION_YIELD = { 0.95, 0.90, 0.85 },
    CERTIFIED_YIELD  = { 0.97, 0.92, 0.88 },

    -- Synthetic input on a transitioning/certified field = full reset to conventional.
    BREACH_FULL_RESET = true,

    -- Inputs allowed under organic rules, keyed by fill type name. Anything applied
    -- that is NOT in here counts as a synthetic breach. These are the OM-building
    -- amendments plus the mined mineral conditioners (lime, gypsum). Biosolids are
    -- intentionally excluded (sewage sludge is prohibited in organic certification).
    APPROVED_INPUTS = {
        MANURE            = true,
        LIQUIDMANURE      = true,
        DIGESTATE         = true,
        COMPOST           = true,
        CHICKEN_MANURE    = true,
        PELLETIZED_MANURE = true,
        LIME              = true,
        LIQUIDLIME        = true,
        GYPSUM            = true,
        -- Organic-approved crop protection (OM-209): the mineral preventatives
        -- allowed under organic rules. Their fungicide application does NOT breach
        -- cert; the synthetic fungicides (not listed here) do. See onFungicideAppliedDirect.
        SULFUR            = true,
        COPPER_HYDROXIDE  = true,
    },
}

-- List of recognized fertilizer fill type names (for reference/iteration)
SoilConstants.FERTILIZER_TYPES = {
    -- Base game
    "LIQUIDFERTILIZER", "FERTILIZER", "MANURE", "LIQUIDMANURE", "DIGESTATE", "LIME",
    -- Nitrogen sources
    "UAN32", "UAN28", "ANHYDROUS", "AMS", "UREA", "AN",
    -- Starter
    "STARTER",
    -- Gypsum
    "GYPSUM",
    -- P&K sources
    "MAP", "DAP", "POTASH", "POLIFOSKA",
    -- Liquid equivalents
    "LIQUID_UREA", "LIQUID_AMS", "LIQUID_MAP", "LIQUID_DAP", "LIQUID_POTASH",
    -- Organic
    "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE",
    -- Lime variants
    "LIQUIDLIME",
    -- Crop protection
    "INSECTICIDE", "FUNGICIDE",
    -- Physical named fungicides (6-chemical kit): buyable tanks sprayed like FUNGICIDE
    "PROPICONAZOLE", "AZOXYSTROBIN", "BOSCALID", "MANCOZEB", "METALAXYL", "TEBUCONAZOLE",
    -- Organic-approved preventatives (OM-209): same sprayed-tank path, organic-legal
    "SULFUR", "COPPER_HYDROXIDE",
}

-- ========================================
-- BIG BAG CAPACITY
-- ========================================
-- Capacity (in litres) for all BigBag objects.
-- Real IBC / FIBC bags hold 500–1000 kg of dry product or 1000 L of liquid,
-- so the in-game bags use a realistic 1,000 L capacity.
-- Change this value here and update the matching capacity/startFillLevel
-- attributes in every objects/bigBag/*/bigBag_*.xml and multiPurchase*.xml.
SoilConstants.BIGBAG = {
    CAPACITY = 1000,  -- litres per bag
}

-- ========================================
-- SINGLE-NUTRIENT PURCHASABLE FILL TYPES
-- ========================================
-- These fill types are declared in modDesc.xml <fillTypes> and are available
-- for purchase at in-game shops when compatible equipment mods are installed.
-- The entries here mirror the pricePerLiter values in modDesc.xml so that any
-- Lua code performing cost estimates or HUD display can read a single source.
--
-- Nutrient targeting:
--   ANHYDROUS  →  N only  (82-0-0)
--   MAP        →  P-heavy (11-52-0)
--   POTASH     →  K only  (0-0-60)
SoilConstants.PURCHASABLE_SINGLE_NUTRIENT = {
    ANHYDROUS = {
        pricePerLiter = 1.85,   -- ~50 % premium over base LIQUIDFERTILIZER
        fillUnit      = "liquid",
        primaryNutrient = "N",
        description   = "Anhydrous Ammonia 82-0-0",
    },
    MAP = {
        pricePerLiter = 1.95,   -- ~60 % premium; P is the scarcest macro
        fillUnit      = "dry",
        primaryNutrient = "P",
        description   = "Monoammonium Phosphate 11-52-0",
    },
    POTASH = {
        pricePerLiter = 1.80,   -- ~50 % premium over base granular FERTILIZER
        fillUnit      = "dry",
        primaryNutrient = "K",
        description   = "Muriate of Potash 0-0-60",
    },
}

-- ========================================
-- NUTRIENT STATUS THRESHOLDS
-- ========================================
SoilConstants.STATUS_THRESHOLDS = {
    nitrogen   = { poor = 30, fair = 50 },
    phosphorus = { poor = 25, fair = 40 },  -- was 45; lowered to match CROP_NUTRIENT_TARGETS default P.opt (40)
    potassium  = { poor = 20, fair = 40 },
}

-- ========================================
-- CROP NUTRIENT TARGETS (per-crop min / optimal, internal 0-100 scale)
-- ========================================
-- min = minimum for acceptable growth (below = crop-specific deficiency)
-- opt = optimal level for full yield (at/above = no yield penalty)
-- Legumes (soybean, peas, beans) have low N targets - they fix atmospheric N.
-- Root crops (potato, sugarbeet) have very high K targets - they partition K into tubers.
-- Fallback "default" is used for unrecognised crops.
SoilConstants.CROP_NUTRIENT_TARGETS = {
    wheat      = { N = { min = 35, opt = 55 }, P = { min = 25, opt = 40 }, K = { min = 25, opt = 40 } },
    barley     = { N = { min = 25, opt = 45 }, P = { min = 20, opt = 35 }, K = { min = 20, opt = 35 } },
    maize      = { N = { min = 40, opt = 60 }, P = { min = 25, opt = 40 }, K = { min = 30, opt = 45 } },
    canola     = { N = { min = 45, opt = 65 }, P = { min = 30, opt = 45 }, K = { min = 30, opt = 45 } },
    soybean    = { N = { min = 15, opt = 30 }, P = { min = 30, opt = 50 }, K = { min = 35, opt = 55 } },
    sunflower  = { N = { min = 35, opt = 55 }, P = { min = 25, opt = 40 }, K = { min = 35, opt = 55 } },
    potato     = { N = { min = 45, opt = 65 }, P = { min = 35, opt = 55 }, K = { min = 60, opt = 80 } },
    sugarbeet  = { N = { min = 45, opt = 65 }, P = { min = 35, opt = 55 }, K = { min = 65, opt = 85 } },
    oat        = { N = { min = 25, opt = 45 }, P = { min = 20, opt = 35 }, K = { min = 20, opt = 35 } },
    oats       = { N = { min = 25, opt = 45 }, P = { min = 20, opt = 35 }, K = { min = 20, opt = 35 } },
    rye        = { N = { min = 25, opt = 45 }, P = { min = 20, opt = 35 }, K = { min = 20, opt = 35 } },
    triticale  = { N = { min = 35, opt = 55 }, P = { min = 25, opt = 40 }, K = { min = 25, opt = 40 } },
    sorghum    = { N = { min = 30, opt = 50 }, P = { min = 20, opt = 35 }, K = { min = 25, opt = 40 } },
    peas       = { N = { min = 15, opt = 30 }, P = { min = 25, opt = 45 }, K = { min = 30, opt = 50 } },
    beans      = { N = { min = 15, opt = 30 }, P = { min = 25, opt = 45 }, K = { min = 30, opt = 50 } },
    luzerne    = { N = { min = 10, opt = 20 }, P = { min = 25, opt = 45 }, K = { min = 30, opt = 50 } },
    clover     = { N = { min = 10, opt = 20 }, P = { min = 25, opt = 45 }, K = { min = 30, opt = 50 } },
    default    = { N = { min = 30, opt = 50 }, P = { min = 25, opt = 40 }, K = { min = 20, opt = 40 } },
}

-- ========================================
-- PPM DISPLAY SCALE
-- ========================================
-- Converts the internal 0-100 nutrient scale to soil-test PPM values for
-- HUD and Report display.  Calibrated so that the fair→good status boundary
-- aligns with standard agronomic lab benchmarks (Mehlich-3 / ammonium-acetate):
--   N: Good >150 ppm  (plant-available nitrogen)
--   P: Good >27 ppm   (Bray/Mehlich-3 phosphorus; lab "Good" ~25-30 ppm)
--   K: Good >160 ppm  (Mehlich-3 potassium; lab "Good" ~150 ppm)
-- The bar in the HUD still runs 0-100 % (internal), where 100 % represents
-- the luxury-level ceiling (300 ppm N, 60 ppm P, 400 ppm K).
-- Nothing in the simulation changes - these multipliers are display-only.
SoilConstants.PPM_DISPLAY = {
    N = 3.0,   -- internal 50 (fair→good boundary) = 150 ppm
    P = 0.6,   -- internal 45 (fair→good boundary) = 27 ppm
    K = 4.0,   -- internal 40 (fair→good boundary) = 160 ppm
}

-- Threshold for "needs fertilization" warning
SoilConstants.FERTILIZATION_THRESHOLDS = {
    nitrogen = 30,
    phosphorus = 25,
    potassium = 20,
    pH = 5.5,
}

-- Urgency score threshold for critical field alerts
SoilConstants.CRITICAL_ALERT_THRESHOLD = 50

-- ========================================
-- YIELD SENSITIVITY (Issue #81 interim HUD warning)
-- ========================================
-- Nutrient levels >= OPTIMAL_THRESHOLD (0-100 scale) → no yield penalty.
-- Below that, penalty scales with how far each nutrient has dropped and
-- how demanding the crop is.  Max penalty is capped at MAX_PENALTY.
--
-- Formula (per nutrient): deficit_fraction = max(0, threshold - value) / threshold
-- Combined deficit = average of N, P, K deficit fractions
-- Raw penalty      = combined_deficit * tier.scale
-- Final penalty %  = min(MAX_PENALTY, raw_penalty) * 100
SoilConstants.YIELD_SENSITIVITY = {
    -- Nutrients must be at or above this value (0–100) for full yield.
    -- Set to 50 so that reaching GOOD crop-target status translates to near-full yield.
    -- At 70 a field green on all nutrients still showed a 12-15% yield penalty,
    -- which confused players who were above their crop targets.
    OPTIMAL_THRESHOLD = 50,

    -- Hard cap on how much yield can be lost to nutrient stress
    MAX_PENALTY = 0.50,

    -- Tier definitions: scale how harshly the deficit translates to a penalty
    TIERS = {
        tolerant  = { scale = 0.50, label = "Tolerant"  },  -- barley, oat, sunflower
        moderate  = { scale = 1.00, label = "Moderate"  },  -- wheat, canola, maize, etc.
        demanding = { scale = 2.00, label = "Demanding" },  -- potato, sugarbeet, soybean
    },

    -- Crop name (lowercased fruitDesc.name) → sensitivity tier
    CROP_TIERS = {
        -- Tolerant: manage well even in poor soil
        barley     = "tolerant",
        oat        = "tolerant",
        oats       = "tolerant",   -- alternate name
        sunflower  = "tolerant",
        rye        = "tolerant",
        sorghum    = "tolerant",
        luzerne    = "tolerant",   -- legume forage - fixes own N
        alfalfa    = "tolerant",   -- == luzerne (NA name); fixes own N (#694)
        clover     = "tolerant",   -- legume forage - fixes own N
        -- Moderate: standard response to nutrient levels
        wheat      = "moderate",
        canola     = "moderate",
        maize      = "moderate",
        triticale  = "moderate",
        peas       = "moderate",
        beans      = "moderate",
        -- Demanding: yield falls sharply with nutrient stress
        potato     = "demanding",
        sugarbeet  = "demanding",
        soybean    = "demanding",
    },

    DEFAULT_TIER = "moderate",

    -- Organic matter yield influence (#695). OM is a long-term soil-health investment:
    -- rich humus gives a small bonus, depleted soil a penalty. Bands on the 0-10 OM scale.
    -- The healthy band starts at the default field OM (3.5) so a fresh/average field sits
    -- exactly at no-penalty, and only neglected (declining) or invested (rising) soils move.
    OM_YIELD = {
        BONUS_THRESHOLD = 5.0,   -- OM at/above this earns the full bonus
        BONUS_MAX       = 0.05,  -- +5% yield at/above BONUS_THRESHOLD
        HEALTHY_LOW     = 3.5,   -- 3.5–5.0 = healthy baseline, no penalty (matches default OM)
        PENALTY_MID     = 2.0,   -- 2.0–3.5 ramps 0 → PENALTY_MID_MAX
        PENALTY_MID_MAX = 0.10,  -- -10% at PENALTY_MID
        PENALTY_MAX     = 0.25,  -- -25% as OM approaches 0
    },

    -- Crops that are not row-crop harvests; skip yield forecast for these
    NON_CROP_NAMES = {
        grass = true, meadow = true, drygrass = true, fieldgrass = true, ryegrass = true,
        poplar = true, oilseedradish = true,
        luzerne = true, clover = true, alfalfa = true,
    },
}

-- ========================================
-- REPORT COLOR THRESHOLDS
-- ========================================
-- pH/OM ranges for color-coded report display
SoilConstants.REPORT_COLORS = {
    PH_GOOD_LOW  = 6.0,
    PH_GOOD_HIGH = 7.0,
    PH_FAIR_LOW  = 5.5,
    PH_FAIR_HIGH = 7.5,
    OM_GOOD      = 4.0,
    OM_FAIR      = 2.5,
}

-- ========================================
-- HUD DISPLAY
-- ========================================
SoilConstants.HUD = {
    PANEL_WIDTH = 0.15,
    PANEL_HEIGHT = 0.15,

    -- Position presets (matched to hudPosition setting values 1-5)
    POSITIONS = {
        -- BUILD 14:39 (Sam DESIGN 14:20, Vera SUBMIT 14:12): factory default preset
        -- [1] moves into the mid-right lane at (0.580, 0.480), computed from the
        -- panel's LIVE dimensions - SoilHUD.BASE_W is now 0.180 (the PANEL_WIDTH 0.15
        -- above is a stale constant this math must not use): right edge 0.760, and
        -- with BASE_H 0.228 the top edge is 0.708, inside Sam's <=0.760 / <=0.709
        -- bounds and AABB-clear of Tax and World Events. y is the overlay BOTTOM.
        -- Presets 2-5 are player choices and stay untouched.
        -- Wizard 2026-08-22: preset [1] updated to the suite layout Wizard
        -- arranged in-game (right column, above Tax).
        [1] = { x = 0.798902, y = 0.534630 },  -- Suite home (factory default)
        [2] = { x = 0.010, y = 0.70 },  -- Top Left
        [3] = { x = 0.850, y = 0.20 },  -- Bottom Right
        [4] = { x = 0.010, y = 0.20 },  -- Bottom Left
        [5] = { x = 0.850, y = 0.45 },  -- Center Right
    },

    -- Color themes (matched to hudColorTheme setting values 1-4)
    COLOR_THEMES = {
        [1] = { r = 0.4, g = 1.0, b = 0.4 },  -- Green (default farming theme)
        [2] = { r = 0.4, g = 0.8, b = 1.0 },  -- Blue (cool tech theme)
        [3] = { r = 1.0, g = 0.7, b = 0.2 },  -- Amber (high contrast)
        [4] = { r = 0.9, g = 0.9, b = 0.9 },  -- Mono (minimalist grayscale)
    },

    -- Transparency levels (matched to hudTransparency setting values 1-5).
    -- Clear was previously 0.25 but {0.05,0.05,0.05} @ 0.25 alpha is nearly
    -- invisible on most in-game backgrounds, making the HUD appear to vanish.
    TRANSPARENCY_LEVELS = {
        [1] = 0.42,  -- Clear  (was 0.25 - raised so panel stays visible)
        [2] = 0.58,  -- Light  (was 0.50)
        [3] = 0.70,  -- Medium (default, unchanged)
        [4] = 0.85,  -- Dark   (unchanged)
        [5] = 1.00,  -- Solid  (unchanged)
    },

    -- Font size multipliers (matched to hudFontSize setting values 1-3)
    FONT_SIZE_MULTIPLIERS = {
        [1] = 0.85,  -- Small
        [2] = 1.00,  -- Medium (default)
        [3] = 1.20,  -- Large
    },

    NORMAL_LINE_HEIGHT = 0.016,

    -- RENDER ORDER NOTES:
    -- FS25 Giants Engine does not provide explicit render layer/Z-order APIs
    -- Overlay render order is determined by:
    --   1. Callback timing (we use FSBaseMission.update)
    --   2. Call order within frame
    --   3. Mod load order
    -- Our HUD renders AFTER game UI init, BEFORE debug overlays
    -- If experiencing conflicts with other mods, users should:
    --   - Adjust HUD position via settings (5 presets available)
    --   - Check mod load order in mods menu
    -- Visibility checks ensure we don't render over critical UI (menus, dialogs, etc)
}

-- ========================================
-- ZONE CELL GRID (per-area overlay coloring)
-- ========================================
-- Each zone cell covers CELL_SIZE × CELL_SIZE world meters.
-- CELL_AREA_HA must equal (CELL_SIZE^2 / 10000).
-- These values must match SoilMapOverlay.POLYGON_STEP (10 m).
SoilConstants.ZONE = {
    CELL_SIZE        = 10,    -- meters per cell side
    CELL_AREA_HA     = 0.01,  -- hectares per cell (10×10 m = 0.01 ha)
    -- A cell stamped less than this many ms ago won't trigger overlap suppression.
    -- At 6 km/h a sprayer crosses a 10m cell in ~6 s; 10 s gives safe headroom.
    OVERLAP_GRACE_MS = 10000,
}

-- ========================================
-- FERTILIZER COVERAGE TRACKING (v2)
-- ========================================
-- A fertilizer pass requires MIN_FULL_CREDIT fraction of the field to be
-- physically covered before the "fully treated" notification fires.
-- Coverage is tracked per-field daily via the cell grid shared with ZONE.
SoilConstants.COVERAGE = {
    MIN_FULL_CREDIT = 0.70,  -- 70% of field cells must be visited for full-treated notification
    PROTECTION_THRESHOLD = 0.80,  -- 80% session coverage required before crop-protection "active" status is granted (issue #441)
}

-- ========================================
-- NETWORK SYNC
-- ========================================
SoilConstants.NETWORK = {
    FULL_SYNC_MAX_ATTEMPTS = 3,
    FULL_SYNC_RETRY_INTERVAL = 5000, -- ms

    -- Chunked full-sync: fields are split into batches to avoid blocking the
    -- main thread for large maps (issue #212 - 255-field timeout/crash).
    FULL_SYNC_BATCH_SIZE = 32,       -- fields per packet
    FULL_SYNC_BATCH_DELAY = 50,      -- ms between batches (one per ~3 frames)

    -- Network value type encoding
    VALUE_TYPE = {
        BOOLEAN = 0,
        NUMBER = 1,
        STRING = 2,
    }
}

-- ========================================
-- SPRAYER APPLICATION RATE
-- ========================================
-- 20 stepped rate multipliers (0.10x – 2.00x in 0.10 increments).
-- DEFAULT_INDEX = 10 → 1.0x (no change from base behaviour).
-- The HUD displays real units (gal/ac or L/ha) by multiplying each step
-- against the BASE_RATE for the currently loaded fertilizer fill type.
-- Burn effects apply when nutrient-rich fertilizer is over-applied:
--   > BURN_RISK_THRESHOLD      : probabilistic pH/N burn (prob scales with excess)
--   >= BURN_GUARANTEED_THRESHOLD: guaranteed burn every application
SoilConstants.SPRAYER_RATE = {
    STEPS = {
        0.10, 0.20, 0.30, 0.40, 0.50,
        0.60, 0.70, 0.80, 0.90, 1.00,
        1.10, 1.20, 1.30, 1.40, 1.50,
        1.60, 1.70, 1.80, 1.90, 2.00,
    },
    DEFAULT_INDEX             = 10,    -- 1.0x
    BURN_RISK_THRESHOLD       = 1.25,  -- above this: chance of burn
    BURN_GUARANTEED_THRESHOLD = 1.50,  -- at or above this: burn every time
    BURN_PH_DROP_RISK         = 0.15,  -- max pH lost over a full pass in the risk band (scaled by excess)
    BURN_PH_DROP_CERTAIN      = 0.30,  -- max pH lost over a full pass at/above the guaranteed threshold
    BURN_N_DRAIN_RISK         = 5.0,   -- max N lost over a full pass in the risk band (scaled by excess)
    BURN_N_DRAIN_CERTAIN      = 12.0,  -- max N lost over a full pass at/above the guaranteed threshold
    -- The burn is metered by how long you over-apply, not fired per tick:
    -- onEndWorkAreaProcessing runs every physics tick and once per active boom
    -- section, so applyBurnEffect docks a slice each tick proportional to elapsed
    -- over-spray time, capped per pass at the BURN_*_CERTAIN/RISK magnitudes
    -- above. A brief overlap costs a small slice; BURN_FULL_DAMAGE_MS of
    -- continuous over-spray reaches the full magnitude. Sibling boom sections in
    -- one tick add dt == 0, so a wide boom never multiplies the penalty. A gap
    -- longer than BURN_PASS_GAP_MS (boom lifted, headland turn) starts a fresh pass.
    BURN_PASS_GAP_MS          = 1500,  -- ms of over-spray inactivity that ends a burn pass
    BURN_FULL_DAMAGE_MS       = 8000,  -- ms of continuous over-spray to reach full burn magnitude

    -- Heat scorch (CD-14) risk band on the temperature scale, deg C.
    -- riskT = HEAT_RISK_BASE - HEAT_SENSITIVITY[product].shift; the band is
    -- HEAT_BAND_WIDTH wide, so certain damage sits at riskT + HEAT_BAND_WIDTH.
    -- Between risk and certain the per-pass caps scale linearly with the excess,
    -- the rate burn's exact clamp shape. SHIP stand-ins marked ARISSANI'S at the
    -- unlock (steward C2); ratio-pass candidates recorded awaiting the spine.
    HEAT_RISK_BASE             = 30,    -- deg C: first scorch risk for a shift-0 product
    HEAT_BAND_WIDTH            = 6,     -- deg C: risk grows to certainty across this band
    SCORCH_PH_DROP_RISK        = 0.15,  -- max pH lost over a full scorch pass in the risk band (scaled by excess)
    SCORCH_PH_DROP_CERTAIN     = 0.30,  -- max pH lost over a full scorch pass at/above certainT
    SCORCH_N_DRAIN_RISK        = 5.0,   -- max N drained over a full scorch pass in the risk band (scaled by excess)
    SCORCH_N_DRAIN_CERTAIN     = 12.0,  -- max N drained over a full scorch pass at/above certainT
    FERTILIZER_COVERAGE_THRESHOLD = 0.90, -- % field coverage needed before nutrients are credited (V1.6 Realism Update)

    -- Reference application rates at 1.0x (step 10) per fill type.
    -- unit = "liquid" → value in L/ha;  unit = "dry" → value in kg/ha.
    -- actual_display_rate = STEPS[idx] * BASE_RATES[name].value
    BASE_RATES = {
        -- Base game
        LIQUIDFERTILIZER  = { value =    93.5, unit = "liquid" },  -- 10 gal/ac
        FERTILIZER        = { value =   225.0, unit = "dry"    },  -- ~200 lb/ac
        MANURE            = { value = 14000.0, unit = "liquid" },  -- ~1500 gal/ac
        LIQUIDMANURE      = { value = 14000.0, unit = "liquid" },  -- FS25 fill type name for slurry
        DIGESTATE         = { value = 14000.0, unit = "liquid" },
        LIME              = { value =  2500.0, unit = "dry"    },  -- ~2230 lb/ac
        LIQUIDLIME        = { value =   374.0, unit = "liquid" },  -- 40 gal/ac (real fluid lime; was 2800 which was 6× too high)
        -- Nitrogen sources
        UAN32             = { value =    60.8, unit = "liquid" },  -- ~6.5 gal/ac
        UAN28             = { value =    60.8, unit = "liquid" },
        ANHYDROUS         = { value =    28.0, unit = "liquid" },  -- ~3 gal/ac
        AMS               = { value =   168.0, unit = "dry"    },  -- ~150 lb/ac
        UREA              = { value =   168.0, unit = "dry"    },
        AN                = { value =   200.0, unit = "dry"    },  -- ~178 lb/ac (200 kg/ha typical UK rate)
        LIQUID_UREA       = { value =   168.0, unit = "liquid" },
        LIQUID_AMS        = { value =   168.0, unit = "liquid" },
        -- Starter / P&K sources
        STARTER           = { value =    46.8, unit = "liquid" },  -- ~5 gal/ac
        MAP               = { value =   225.0, unit = "dry"    },
        DAP               = { value =   225.0, unit = "dry"    },
        POTASH            = { value =   225.0, unit = "dry"    },
        POLIFOSKA         = { value =   250.0, unit = "dry"    },
        LIQUID_MAP        = { value =   225.0, unit = "liquid" },
        LIQUID_DAP        = { value =   225.0, unit = "liquid" },
        LIQUID_POTASH     = { value =   225.0, unit = "liquid" },
        -- Organic / slow-release
        PELLETIZED_MANURE = { value =   450.0, unit = "dry"    },  -- ~400 lb/ac
        COMPOST           = { value =  5000.0, unit = "dry"    },
        BIOSOLIDS         = { value =  4500.0, unit = "dry"    },
        CHICKEN_MANURE    = { value =  2000.0, unit = "dry"    },
        GYPSUM            = { value =  1500.0, unit = "dry"    },
        -- Crop protection - 100 L/ha = realistic water+product carrier mixture
        -- (1.5 L/ha was pure active ingredient dose; 100-150 L/ha is field-realistic)
        INSECTICIDE = { value = 100.0, unit = "liquid" },
        FUNGICIDE   = { value = 100.0, unit = "liquid" },
        -- Physical named fungicides (6-chemical kit) - same carrier rate as generic FUNGICIDE
        PROPICONAZOLE = { value = 100.0, unit = "liquid" },
        AZOXYSTROBIN  = { value = 100.0, unit = "liquid" },
        BOSCALID      = { value = 100.0, unit = "liquid" },
        MANCOZEB      = { value = 100.0, unit = "liquid" },
        METALAXYL     = { value = 100.0, unit = "liquid" },
        TEBUCONAZOLE  = { value = 100.0, unit = "liquid" },
        -- Organic-approved preventatives (OM-209) - same carrier rate as generic FUNGICIDE
        SULFUR           = { value = 100.0, unit = "liquid" },
        COPPER_HYDROXIDE = { value = 100.0, unit = "liquid" },
        HERBICIDE   = { value = 100.0, unit = "liquid" },
        -- Fallback for unrecognized fill types
        DEFAULT           = { value =    93.5, unit = "liquid" },
    },

    -- Target nutrient levels for Auto-Rate Control
    -- Used when SF_TOGGLE_AUTO is active on a sprayer
    AUTO_RATE_TARGETS = {
        N  = 80,
        P  = 50,   -- was 70 (42 ppm); lowered to 50 (30 ppm) - above most crop P optima without over-shooting
        K  = 75,
        -- Aligned to PH_OPTIMAL (6.5) so auto-lime stops at the agronomic optimum.
        pH = 6.5,
        OM = 5.0
    },

    -- Fill types whose auto-rate is driven by OM deficit (not NPK)
    OM_PRIMARY_PRODUCTS = {
        MANURE          = true,
        LIQUIDMANURE    = true,
        DIGESTATE       = true,
        COMPOST         = true,
        BIOSOLIDS       = true,
        CHICKEN_MANURE  = true,
        PELLETIZED_MANURE = true,
    },

    -- Unit conversions for display
    L_PER_HA_TO_GAL_PER_AC = 0.10694,  -- multiply L/ha by this for gal/ac
    KG_PER_HA_TO_LB_PER_AC = 0.89218,  -- multiply kg/ha by this for lb/ac
}

-- ========================================
-- WEED PRESSURE (Issue #98, updated #378)
-- ========================================
-- Field-level 0-100 score derived from FS25's native weed density map
-- (FieldState.weedFactor). The game handles weed growth, canopy suppression,
-- herbicide effects, and tillage resets natively; we read the result each day.
-- Herbicide application also gives an immediate UI response (HERBICIDE_* keys).
-- Harvest applies a yield penalty proportional to pressure tier.
SoilConstants.WEED_PRESSURE = {
    -- Herbicide fill type names → effectiveness multiplier (0.0-1.0)
    -- Any fill type not listed here is NOT treated as herbicide
    -- NOTE: PESTICIDE is the vanilla FS25 / PF insecticide fill type ("Rovarló szer" in HU).
    -- It belongs in INSECTICIDE_TYPES, NOT here. Listing it here caused PESTICIDE sprays to
    -- reduce weed pressure instead of pest pressure (bug: 0% pest protection after full tank).
    HERBICIDE_TYPES = {
        HERBICIDE = 1.0,
    },
    -- Pressure points removed on a single full-field herbicide application.
    -- 100 = one full-field pass at the reference rate (100 L/ha) fully clears any pressure tier.
    -- Partial tank coverage scales proportionally: 50% field covered → 50 pts removed.
    -- Matches cultivation weed clearing (WEED_PRESSURE_REDUCTION = 100 already).
    HERBICIDE_PRESSURE_REDUCTION = 100,

    -- Number of in-game days the HUD "herbicide active" indicator stays lit after application
    HERBICIDE_DURATION_DAYS = 14,

    -- Nutrient Depletion by Weeds (Issue #327)
    -- Daily nutrient drain at 100% weed pressure (scales linearly with pressure)
    NUTRIENT_DEPLETION_N = 0.8, -- Nitrogen loss per day at max weed pressure
    NUTRIENT_DEPLETION_P = 0.4, -- Phosphorus loss per day at max weed pressure
    NUTRIENT_DEPLETION_K = 0.6, -- Potassium loss per day at max weed pressure

    -- Harvest yield penalty at each pressure tier
    YIELD_PENALTY_LOW    = 0.00,  -- 0-20:  none
    YIELD_PENALTY_MID    = 0.05,  -- 20-50: -5%
    YIELD_PENALTY_HIGH   = 0.15,  -- 50-75: -15%
    YIELD_PENALTY_PEAK   = 0.30,  -- 75-100: -30%

    -- HUD tier thresholds
    LOW    = 20,
    MEDIUM = 50,
    HIGH   = 75,

    -- FS25 density-map weed state integers (matches EasyDevControls / LUADOC)
    -- 0 = no weeds, 1-6 = living stages, 7-9 = withered (dying/brown visual)
    WEED_STATE_CLEAR     = 0,
    WEED_STATE_WITHERED  = 7,   -- small withered - visible brown weeds

    -- Maximum weed pressure increase per daily update.
    -- Prevents the snap-to-game-weedFactor spike on reload/time-skip (issue #536).
    -- Decreases still happen immediately so herbicide/cultivation relief is instant.
    MAX_DAILY_INCREASE   = 20,
}

-- ========================================
-- PEST PRESSURE
-- ========================================
-- Per-field 0-100 insect/pest infestation score.
-- Grows daily, peaks in summer, rain accelerates it.
-- Insecticide spray reduces pressure and suppresses regrowth.
-- Harvest disperses the pest population (resets to 30% of current).
SoilConstants.PEST_PRESSURE = {
    -- Daily base growth rate (points/day) by current pressure tier
    GROWTH_RATE_LOW    = 0.8,   -- 0-20:  slow colonisation phase
    GROWTH_RATE_MID    = 1.5,   -- 20-50: active infestation
    GROWTH_RATE_HIGH   = 1.0,   -- 50-75: density self-limiting
    GROWTH_RATE_PEAK   = 0.3,   -- 75-100: near carrying capacity

    -- Seasonal growth multipliers (season index: 1=Spring 2=Summer 3=Fall 4=Winter)
    SEASONAL_SPRING = 1.1,
    SEASONAL_SUMMER = 1.8,   -- peak insect activity
    SEASONAL_FALL   = 0.6,
    SEASONAL_WINTER = 0.05,  -- near dormancy

    -- Rain bonus added to base daily rate when raining
    RAIN_BONUS = 0.3,

    -- Crop susceptibility multipliers (lowercased fruitDesc.name → multiplier)
    -- Any crop NOT listed here defaults to 1.0
    CROP_SUSCEPTIBILITY = {
        potato    = 1.4,
        sugarbeet = 1.4,
        canola    = 1.4,
        soybean   = 1.3,
        maize     = 1.2,
        sunflower = 1.2,
        wheat     = 0.8,
        barley    = 0.7,
        oats      = 0.7,
        rye       = 0.7,
        sorghum   = 0.7,
    },

    -- Insecticide fill type names → effectiveness multiplier (0.0-1.0)
    INSECTICIDE_TYPES = {
        INSECTICIDE = 1.0,  -- SF custom fill type
        PESTICIDE   = 1.0,  -- vanilla FS25 / PF fill type ("Rovarló szer" / bug spray)
    },
    -- Pressure points removed on a single full-field insecticide application.
    -- 100 = one full pass at reference rate fully clears any pressure tier.
    INSECTICIDE_PRESSURE_REDUCTION = 100,
    -- Days insecticide suppresses pest growth after application
    INSECTICIDE_DURATION_DAYS = 30,

    -- On harvest: pest pressure resets to this fraction of current value
    -- (insects disperse when the host crop is removed).
    -- #737 option D: was 0.30. Pest grows ~8.52 pts/year at the low tier, and with
    -- an annual harvest the pre-harvest steady state is P = A / (1 - f), so at
    -- f = 0.30 the field converged on 12.2 and could NEVER reach the first costing
    -- tier at 20. At f = 0.60 the steady peak is 21.3, so a neglected field crosses
    -- 20 over a couple of years and holds in the low band, while a harvest still
    -- disperses well over a third: a real reset, not a no-op.
    HARVEST_RESET_FRACTION = 0.60,

    -- Harvest yield penalty at each pressure tier
    YIELD_PENALTY_LOW    = 0.00,  -- 0-20:  none
    YIELD_PENALTY_MID    = 0.05,  -- 20-50: -5%
    YIELD_PENALTY_HIGH   = 0.12,  -- 50-75: -12%
    YIELD_PENALTY_PEAK   = 0.20,  -- 75-100: -20%

    -- HUD tier thresholds (mirrors WEED_PRESSURE)
    LOW    = 20,
    MEDIUM = 50,
    HIGH   = 75,
}

-- ========================================
-- DISEASE PRESSURE
-- ========================================
-- Per-field 0-100 fungal/crop disease score.
-- Rain is the primary driver. Peaks in spring and fall.
-- Fungicide spray reduces pressure and suppresses regrowth.
-- Extended dry weather causes natural decay.
SoilConstants.DISEASE_PRESSURE = {
    -- Daily base growth rate (points/day) by current pressure tier
    GROWTH_RATE_LOW    = 0.6,   -- 0-20:  initial infection
    GROWTH_RATE_MID    = 1.2,   -- 20-50: active spread
    GROWTH_RATE_HIGH   = 0.8,   -- 50-75: density self-limiting
    GROWTH_RATE_PEAK   = 0.2,   -- 75-100: near maximum

    -- Seasonal growth multipliers (season: 1=Spring 2=Summer 3=Fall 4=Winter)
    SEASONAL_SPRING = 1.5,   -- fungal window: cool+moist
    SEASONAL_SUMMER = 0.9,
    SEASONAL_FALL   = 1.3,   -- second fungal window
    SEASONAL_WINTER = 0.1,

    -- Rain is the primary driver: extra points/day added during active rain
    RAIN_BONUS = 1.0,

    -- Dry weather decay: pressure points lost per day when it has NOT rained
    -- for DRY_DAYS_THRESHOLD consecutive days.
    -- NOTE: tracking consecutive dry days requires a new field: `field.dryDayCount`
    -- (integer, default 0). Increment each day without rain, reset to 0 on rain.
    DRY_DAYS_THRESHOLD = 3,    -- after this many dry days, growth is DAMPED (see DRY_GROWTH_MULT)
    DRY_DECAY_RATE     = 0.5,  -- pts/day removed once a real drought is reached

    -- #737 option D: a dry spell used to REPLACE growth entirely (the decay branch was
    -- an `elseif`, so any dry day past the threshold skipped the growth path and the
    -- field only ever lost pressure). Combined with the plough reset that pinned disease
    -- near zero permanently. Now a dry day inside the fungal window still grows, at a
    -- damped rate, and outright decay waits for a genuine drought at a higher threshold.
    -- The freeze-at-zero goes; the drought signal stays.
    DRY_GROWTH_MULT        = 0.40,  -- dry-day growth as a fraction of the wet base rate
    -- Multiplier on the climate's dry threshold at which decay takes over from damped
    -- growth. Keeps the climate scaling intact: Temperate damps from 3 dry days and
    -- decays from 6, Wet damps from 14 and decays from 28.
    -- RULED (#737): the smallest value leaving a clear damped band before decay at every
    -- climate is precisely the shape the ruling described. Confirmed, not merely tolerated.
    DROUGHT_THRESHOLD_MULT = 2.0,

    -- Crop susceptibility multipliers (lowercased fruitDesc.name → multiplier)
    CROP_SUSCEPTIBILITY = {
        wheat     = 1.3,   -- fusarium / septoria risk
        canola    = 1.3,   -- sclerotinia risk
        potato    = 1.4,   -- blight risk
        soybean   = 1.2,
        maize     = 1.1,
        barley    = 0.8,
        rye       = 0.7,
        sorghum   = 0.7,
    },

    -- Fungicide fill type names → effectiveness multiplier
    FUNGICIDE_TYPES = {
        FUNGICIDE = 1.0,
        -- Physical named fungicides (6-chemical kit). Base multiplier 1.0; the per-disease
        -- control rate is applied at spray time in onFungicideAppliedDirect via the catalog.
        PROPICONAZOLE = 1.0, AZOXYSTROBIN = 1.0, BOSCALID = 1.0,
        MANCOZEB = 1.0, METALAXYL = 1.0, TEBUCONAZOLE = 1.0,
        -- Organic-approved preventatives (OM-209): same base multiplier; catalog control at spray time
        SULFUR = 1.0, COPPER_HYDROXIDE = 1.0,
    },
    -- Pressure points removed on a single full-field fungicide application.
    -- 100 = one full pass at reference rate fully clears any pressure tier.
    FUNGICIDE_PRESSURE_REDUCTION = 100,
    -- Days fungicide suppresses disease growth after application
    FUNGICIDE_DURATION_DAYS = 35,

    -- Harvest yield penalty at each pressure tier
    YIELD_PENALTY_LOW    = 0.00,  -- 0-20:  none
    YIELD_PENALTY_MID    = 0.05,  -- 20-50: -5%
    YIELD_PENALTY_HIGH   = 0.15,  -- 50-75: -15%
    YIELD_PENALTY_PEAK   = 0.25,  -- 75-100: -25%

    -- HUD tier thresholds
    LOW    = 20,
    MEDIUM = 50,
    HIGH   = 75,
}

-- ========================================
-- DISEASE CLIMATE MOISTURE (1=Arid … 4=Wet)
-- ========================================
-- Each entry multiplies the disease-pressure constants at runtime.
-- growthMult     : scales all four GROWTH_RATE_* tiers
-- rainBonusMult  : scales RAIN_BONUS added per rainy day
-- dryThreshold   : overrides DRY_DAYS_THRESHOLD (consecutive dry days before decay)
-- dryDecayMult   : scales DRY_DECAY_RATE (pts/day removed during dry stretch)
-- fungicideMult  : scales FUNGICIDE_DURATION_DAYS (shorter in wet climates)
SoilConstants.DISEASE_CLIMATE_MOISTURE = {
    [1] = { growthMult = 0.5,  rainBonusMult = 0.5,  dryThreshold = 2,  dryDecayMult = 1.5,  fungicideMult = 1.3  }, -- Arid
    [2] = { growthMult = 1.0,  rainBonusMult = 1.0,  dryThreshold = 3,  dryDecayMult = 1.0,  fungicideMult = 1.0  }, -- Temperate (baseline)
    [3] = { growthMult = 1.5,  rainBonusMult = 1.6,  dryThreshold = 6,  dryDecayMult = 0.5,  fungicideMult = 0.75 }, -- Humid
    [4] = { growthMult = 2.0,  rainBonusMult = 2.5,  dryThreshold = 14, dryDecayMult = 0.2,  fungicideMult = 0.6  }, -- Wet
}

-- ========================================
-- CLIMATE PRECIPITATION PRESETS (#740)
-- ========================================
-- The `weatherSource` setting picks where SF's rain-driven modifiers (leaching, disease
-- wet/dry, pest rain-bonus) read precipitation from. weatherSource == 1 = the true
-- in-game weather (default, unchanged). 2/3/4 = these synthetic presets, which the game
-- weather cannot: on short (e.g. 1-day) months the real weather is almost always dry, so
-- the rain-driven effects rarely fire. A preset instead derives a per-day wet/dry from a
-- SEEDED per-day roll against the season's rain probability, keeping the dry-day build-up
-- and wet-day spike that disease/pest depend on.
--   PROB[season]      : fraction of days that rain in that season (the seeded roll's threshold)
--   INTENSITY[season] : the rainScale used on a wet day (drives leaching + wet-day effects)
--   Seasons: 1=spring, 2=summer, 3=autumn, 4=winter (the engine's currentSeason is
--            1-indexed; SeasonalCropStress normalizes the same 1-4 to its 0-based
--            tables, so PROB[currentSeason] indexes correctly with NO offset).
--   PROB[season] : the season's RAIN-DAY FRACTION (target fraction of days that rain).
--   INTENSITY    : the rainScale a FILLED-wet day returns (one value per climate).
-- The weatherSource setting now selects a CLIMATE BIAS (2=Arid/3=Normal/4=Wet) for the
-- short-month FILL; 1 = the opt-out (pure real weather, no fill). #740 reshape: real
-- weather stays primary and the fill only tops up the rain a compressed calendar skips.
-- This only changes what SF's soil math ASSUMES; it never changes the game's visual
-- weather. RULED by Arissani's balance pass 2026-07-25 (rain-day % -> fraction). All tunable.
SoilConstants.CLIMATE_PRECIP = {
    [2] = { -- Arid: dry summers, light rain
        PROB      = { [1] = 0.20, [2] = 0.10, [3] = 0.18, [4] = 0.16 },
        INTENSITY = 0.40,
    },
    [3] = { -- Normal / temperate (default climate bias)
        PROB      = { [1] = 0.40, [2] = 0.20, [3] = 0.38, [4] = 0.32 },
        INTENSITY = 0.55,
    },
    [4] = { -- Wet: frequent rain, wet winters
        PROB      = { [1] = 0.65, [2] = 0.35, [3] = 0.62, [4] = 0.55 },
        INTENSITY = 0.80,
    },
}

-- #740 short-month FILL engagement (RULED by Arissani's balance pass 2026-07-25). The
-- fill only engages as the month shortens: w = clamp((REF - dpm) / (REF - 1), 0, 1)^EXP,
-- where dpm = daysPerPeriod (the calendar's days-per-month). w = 0 at/above SAMPLING_REFERENCE
-- (byte-identical to real weather), rising to 1 at a 1-day month. It gates the wet-day
-- FREQUENCY (how often a dry day is filled toward the season shortfall), never intensity.
-- SAMPLING_REFERENCE is its OWN constant - deliberately NOT DURATION.REFERENCE_DPP (that is
-- a chemical-duration reference; anchoring the fill on 3 would give common 3+ day saves zero
-- fill). ENGAGEMENT_EXPONENT is the one tuning dial (feel: 10d ~0.05, 7d ~0.2, 4d ~0.5, 1d ~1).
SoilConstants.SHORT_MONTH_FILL = {
    SAMPLING_REFERENCE = 15,   -- days-per-month at/above which the fill is off (weather samples adequately)
    ENGAGEMENT_EXPONENT = 2.5, -- curve steepness; higher = fill stays low until the month is very short
}

-- ========================================
-- DISEASE & CHEMICAL MANAGEMENT (named crop-specific diseases)
-- ========================================
-- A naming + chemistry layer over the diseasePressure scalar above. The scalar
-- engine still drives the infection LEVEL (0-100); this layer:
--   • names the active infection per crop + current weather (field.activeDisease)
--   • scales the yield bite by the named disease's severity
--   • gates which fungicide clears it well (effectiveness matrix)
-- Treatment is MENU / console driven (select chemical → pay → apply). It is NOT a
-- set of physical fill types - the generic FUNGICIDE fill type above still works
-- for vanilla spraying. Pure data here; logic lives in DiseaseSystem.lua.

-- Canonical disease categories. Every named disease maps to exactly one. Fungicide
-- effectiveness is defined per category (mirrors the agronomy effectiveness chart).
SoilConstants.DISEASE_CATEGORIES = {
    "powdery_mildew", "rust", "blotch", "septoria", "fhb", "leaf_spot",
    "frogeye", "anthracnose", "ascochyta", "white_mold", "sclerotinia",
    "verticillium", "blight", "root_rot", "pasmo",
}

-- Per-disease definitions (flat id → traits). Referenced by DISEASE_REGISTRY.
--   cat    : effectiveness category (see above)
--   sci    : scientific name (international - not localized)
--   nameKey: l10n key suffix → "sf_dis_<id>" for the common display name
--   cool   : true = favored by cool temps, false = favored by warm temps, nil = any
--   wet    : true = favored by wet/humid weather (rain pushes it harder)
--   season : {spring, summer, fall} selection weights (winter ≈ dormant)
--   yMin/yMax : fractional yield impact range used for severity scaling
SoilConstants.DISEASE_DEFS = {
    -- Cereals / grains
    septoria_tritici   = { cat="septoria",       sci="Zymoseptoria tritici",        cool=true,  wet=true,  season={1.5,0.8,1.2}, yMin=0.15, yMax=0.30 },
    fhb                = { cat="fhb",             sci="Fusarium graminearum",        cool=false, wet=true,  season={1.0,1.3,1.2}, yMin=0.20, yMax=0.40 },
    ergot              = { cat="fhb",             sci="Claviceps purpurea",          cool=true,  wet=true,  season={1.4,0.6,1.1}, yMin=0.05, yMax=0.30 },
    stripe_rust        = { cat="rust",            sci="Puccinia striiformis",        cool=true,  wet=true,  season={1.4,0.9,1.0}, yMin=0.10, yMax=0.25 },
    leaf_rust          = { cat="rust",            sci="Puccinia triticina",          cool=false, wet=true,  season={1.0,1.2,1.2}, yMin=0.08, yMax=0.18 },
    powdery_mildew     = { cat="powdery_mildew",  sci="Blumeria graminis",           cool=true,  wet=false, season={1.4,1.0,0.9}, yMin=0.05, yMax=0.15 },
    tan_spot           = { cat="leaf_spot",       sci="Drechslera tritici-repentis", cool=false, wet=false, season={0.9,1.2,1.0}, yMin=0.10, yMax=0.20 },
    net_blotch         = { cat="blotch",          sci="Pyrenophora teres",           cool=true,  wet=true,  season={1.3,0.9,1.1}, yMin=0.10, yMax=0.20 },
    ramularia          = { cat="leaf_spot",       sci="Ramularia collo-cygni",       cool=true,  wet=true,  season={1.2,1.0,1.0}, yMin=0.08, yMax=0.18 },
    crown_rust         = { cat="rust",            sci="Puccinia coronata",           cool=false, wet=true,  season={1.0,1.2,1.2}, yMin=0.10, yMax=0.22 },
    leaf_blotch        = { cat="blotch",          sci="Rhynchosporium secalis",      cool=true,  wet=true,  season={1.3,0.8,1.1}, yMin=0.10, yMax=0.18 },
    -- Maize / sorghum
    nclb               = { cat="leaf_spot",       sci="Exserohilum turcicum",        cool=false, wet=true,  season={0.9,1.3,1.1}, yMin=0.10, yMax=0.25 },
    common_rust        = { cat="rust",            sci="Puccinia sorghi",             cool=false, wet=true,  season={0.9,1.2,1.1}, yMin=0.08, yMax=0.18 },
    gray_leaf_spot     = { cat="leaf_spot",       sci="Cercospora zeae-maydis",      cool=false, wet=true,  season={0.8,1.3,1.2}, yMin=0.12, yMax=0.28 },
    -- Oilseeds / roots
    sclerotinia_stem   = { cat="sclerotinia",     sci="Sclerotinia sclerotiorum",    cool=true,  wet=true,  season={1.2,1.0,1.3}, yMin=0.15, yMax=0.35 },
    sunflower_rust     = { cat="rust",            sci="Puccinia helianthi",          cool=false, wet=true,  season={0.9,1.2,1.2}, yMin=0.08, yMax=0.18 },
    downy_mildew       = { cat="root_rot",        sci="Plasmopara halstedii",        cool=true,  wet=true,  season={1.3,0.9,1.0}, yMin=0.05, yMax=0.25 },
    late_blight        = { cat="blight",          sci="Phytophthora infestans",      cool=true,  wet=true,  season={1.2,1.0,1.4}, yMin=0.25, yMax=0.55 },
    early_blight       = { cat="leaf_spot",       sci="Alternaria solani",           cool=false, wet=true,  season={0.9,1.3,1.1}, yMin=0.10, yMax=0.25 },
    cercospora_leaf    = { cat="leaf_spot",       sci="Cercospora beticola",         cool=false, wet=true,  season={0.8,1.3,1.2}, yMin=0.12, yMax=0.28 },
    -- Pulses
    frogeye            = { cat="frogeye",         sci="Cercospora sojina",           cool=false, wet=true,  season={0.9,1.3,1.1}, yMin=0.10, yMax=0.20 },
    white_mold         = { cat="white_mold",      sci="Sclerotinia sclerotiorum",    cool=true,  wet=true,  season={1.1,1.0,1.3}, yMin=0.15, yMax=0.35 },
    phytophthora_root  = { cat="root_rot",        sci="Phytophthora sojae",          cool=false, wet=true,  season={1.0,1.2,1.0}, yMin=0.05, yMax=0.25 },
    asian_rust         = { cat="rust",            sci="Phakopsora pachyrhizi",       cool=false, wet=true,  season={0.8,1.3,1.3}, yMin=0.10, yMax=0.30 },
    ascochyta_blight   = { cat="ascochyta",       sci="Ascochyta spp.",              cool=true,  wet=true,  season={1.4,0.8,1.1}, yMin=0.15, yMax=0.40 },
    bean_anthracnose   = { cat="anthracnose",     sci="Colletotrichum lindemuthianum", cool=false, wet=true, season={0.9,1.3,1.1}, yMin=0.10, yMax=0.25 },
    root_rot           = { cat="root_rot",        sci="Fusarium / Rhizoctonia spp.", cool=nil,   wet=true,  season={1.0,1.0,1.1}, yMin=0.05, yMax=0.20 },
    -- Forage
    verticillium_wilt  = { cat="verticillium",    sci="Verticillium albo-atrum",     cool=false, wet=false, season={1.0,1.2,1.0}, yMin=0.20, yMax=0.40 },
    leaf_spot          = { cat="leaf_spot",       sci="Cercospora / Septoria spp.",  cool=true,  wet=true,  season={1.1,1.0,1.2}, yMin=0.10, yMax=0.25 },
    alfalfa_rust       = { cat="rust",            sci="Uromyces striatus",           cool=false, wet=true,  season={1.0,1.1,1.2}, yMin=0.08, yMax=0.18 },
    clover_anthracnose = { cat="anthracnose",     sci="Colletotrichum trifolii",     cool=false, wet=true,  season={0.9,1.3,1.0}, yMin=0.10, yMax=0.20 },
    -- Specialty grains
    pasmo              = { cat="pasmo",           sci="Septoria linicola",           cool=true,  wet=true,  season={1.2,1.0,1.2}, yMin=0.10, yMax=0.25 },
    anthracnose        = { cat="anthracnose",     sci="Colletotrichum spp.",         cool=false, wet=true,  season={0.9,1.3,1.1}, yMin=0.08, yMax=0.20 },
    rust               = { cat="rust",            sci="Puccinia spp.",               cool=false, wet=true,  season={1.0,1.1,1.2}, yMin=0.10, yMax=0.25 },
    -- Root / earth (tropical)
    taro_leaf_blight   = { cat="blight",          sci="Phytophthora colocasiae",     cool=false, wet=true,  season={1.0,1.4,1.2}, yMin=0.30, yMax=0.60 },
    corm_rot           = { cat="root_rot",        sci="Pythium / Fusarium spp.",     cool=false, wet=true,  season={0.9,1.2,1.2}, yMin=0.10, yMax=0.40 },
    early_leaf_spot    = { cat="leaf_spot",       sci="Cercospora arachidicola",     cool=false, wet=true,  season={1.0,1.3,1.0}, yMin=0.15, yMax=0.35 },
    late_leaf_spot     = { cat="leaf_spot",       sci="Cercosporidium personatum",   cool=false, wet=true,  season={0.8,1.2,1.3}, yMin=0.15, yMax=0.40 },
    peanut_rust        = { cat="rust",            sci="Puccinia arachidis",          cool=false, wet=true,  season={0.9,1.2,1.2}, yMin=0.08, yMax=0.18 },
    pod_rot            = { cat="sclerotinia",     sci="Sclerotinia sclerotiorum",    cool=true,  wet=true,  season={1.0,1.0,1.3}, yMin=0.10, yMax=0.25 },

    -- CD-10 HYBRID STRAINS. Reachable ONLY through the resistance-gated pre-pass in
    -- _updateActiveDisease, never through selectDisease's weighted roll -- which is why this
    -- id is deliberately absent from DISEASE_REGISTRY and every per-crop candidate list.
    --
    -- `cat` is a BRAND-NEW, EMPTY category on purpose. No physical fungicide's `eff` table
    -- carries it, so every chemical falls through to DISEASE_DEFAULT_EFFECTIVENESS (0.25) --
    -- a uniform ceiling rather than a hand-tuned scatter. That is the SDS 5.3 taste call, and
    -- this build takes the uniform shape: it makes the hybrid's difficulty a property of the
    -- RESISTANCE the player built rather than of a table someone balanced by feel.
    --
    -- `requiresModes` is the RULED CONTROL FACTOR's hook (2026-07-30, Arissani delegated).
    -- Without it a blend would answer a hybrid no better than one fresh jug, because
    -- max-over-partners control composed with a flat 0.25 default collapses to 0.25 either
    -- way. Its presence is also the flag that the factor applies at all; ordinary diseases
    -- carry no requiresModes and nothing about them changes.
    --
    -- COUNT IS SEVEN (ruled 2026-08-01): one resistant complex per crop family, plus the
    -- default kept for unfamilied and modded crops. The rows differ ONLY in `sci`, the
    -- display key, and the yield band; `cat` and `requiresModes` stay IDENTICAL on all
    -- seven so the ruled control factor and isHybrid hold on every one.
    --
    -- The yield band is where families are allowed to differ because that is an agronomic
    -- statement rather than a dial: a root crop's blight complex genuinely costs more than
    -- a forage stand's leaf complex. The shipped 0.25 to 0.45 sits in the middle where it
    -- should; root sits above it and forage below it, per the brief's own example.
    resistant_complex          = { cat="resistant_complex", sci="Multi-resistant complex",       cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.25, yMax=0.45, requiresModes=2 },
    resistant_complex_cereal   = { cat="resistant_complex", sci="Multi-resistant cereal complex",  cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.20, yMax=0.40, requiresModes=2 },
    resistant_complex_maize    = { cat="resistant_complex", sci="Multi-resistant maize complex",   cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.20, yMax=0.40, requiresModes=2 },
    resistant_complex_oilseed  = { cat="resistant_complex", sci="Multi-resistant oilseed complex", cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.25, yMax=0.45, requiresModes=2 },
    resistant_complex_root     = { cat="resistant_complex", sci="Multi-resistant root complex",    cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.30, yMax=0.55, requiresModes=2 },
    resistant_complex_pulse    = { cat="resistant_complex", sci="Multi-resistant pulse complex",   cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.20, yMax=0.40, requiresModes=2 },
    resistant_complex_forage   = { cat="resistant_complex", sci="Multi-resistant forage complex",  cool=false, wet=true, season={1.0,1.1,1.1}, yMin=0.15, yMax=0.30, requiresModes=2 },
}

-- Crop → its candidate diseases (lowercased internal fruit name → list of DISEASE_DEFS ids).
-- Unknown crops fall back to DISEASE_REGISTRY_DEFAULT. Keys cover base FS25 fruit names plus
-- common multifruit/mod crops named in the disease proposal.
SoilConstants.DISEASE_REGISTRY = {
    wheat       = { "septoria_tritici", "fhb", "stripe_rust", "powdery_mildew", "tan_spot", "leaf_rust" },
    barley      = { "net_blotch", "powdery_mildew", "leaf_rust", "ramularia" },
    oat         = { "crown_rust", "powdery_mildew", "leaf_blotch" },
    rye         = { "powdery_mildew", "ergot", "stripe_rust", "leaf_rust", "fhb" },
    spelt       = { "stripe_rust", "septoria_tritici", "ergot", "powdery_mildew" },
    triticale   = { "powdery_mildew", "fhb", "tan_spot", "leaf_rust" },
    maize       = { "nclb", "common_rust", "gray_leaf_spot" },
    sorghum     = { "leaf_spot", "rust", "anthracnose" },
    canola      = { "sclerotinia_stem", "leaf_spot", "white_mold" },
    sunflower   = { "sclerotinia_stem", "sunflower_rust", "downy_mildew" },
    potato      = { "late_blight", "early_blight" },
    sugarbeet   = { "cercospora_leaf", "rust", "powdery_mildew" },
    soybean     = { "frogeye", "white_mold", "phytophthora_root", "asian_rust" },
    pea         = { "ascochyta_blight", "white_mold", "root_rot" },
    peas        = { "ascochyta_blight", "white_mold", "root_rot" },
    driedpeas   = { "ascochyta_blight", "white_mold", "root_rot" },
    chickpea    = { "ascochyta_blight", "powdery_mildew" },
    chickpeas   = { "ascochyta_blight", "powdery_mildew" },
    lentil      = { "ascochyta_blight", "white_mold", "root_rot" },
    lentils     = { "ascochyta_blight", "white_mold", "root_rot" },
    greenbean   = { "white_mold", "bean_anthracnose", "ascochyta_blight" },
    bean        = { "white_mold", "bean_anthracnose", "ascochyta_blight" },
    beans       = { "white_mold", "bean_anthracnose", "ascochyta_blight" },
    pintobean   = { "white_mold", "bean_anthracnose", "ascochyta_blight" },
    pintobeans  = { "white_mold", "bean_anthracnose", "ascochyta_blight" },
    alfalfa     = { "verticillium_wilt", "leaf_spot", "alfalfa_rust" },
    luzerne     = { "verticillium_wilt", "leaf_spot", "alfalfa_rust" },
    clover      = { "clover_anthracnose", "powdery_mildew", "leaf_spot", "rust" },
    whiteclover = { "clover_anthracnose", "powdery_mildew" },
    redclover   = { "leaf_spot", "rust" },
    grass       = { "leaf_spot", "rust", "powdery_mildew" },
    meadow      = { "leaf_spot", "rust", "powdery_mildew" },
    greenrye    = { "powdery_mildew", "leaf_blotch" },
    miscanthus  = { "leaf_spot", "rust" },
    mint        = { "powdery_mildew", "leaf_spot" },
    linseed     = { "pasmo", "sclerotinia_stem" },
    flax        = { "pasmo", "sclerotinia_stem" },
    buckwheat   = { "powdery_mildew", "anthracnose" },
    millet      = { "powdery_mildew", "rust" },
    mustard     = { "sclerotinia_stem", "rust" },
    poppy       = { "powdery_mildew", "leaf_spot" },
    sesame      = { "anthracnose", "leaf_spot" },
    safflower   = { "rust", "sclerotinia_stem" },
    cotton      = { "leaf_spot", "rust" },
    taro        = { "taro_leaf_blight", "corm_rot" },
    peanut      = { "early_leaf_spot", "late_leaf_spot", "peanut_rust", "pod_rot" },
    peanuts     = { "early_leaf_spot", "late_leaf_spot", "peanut_rust", "pod_rot" },
}
SoilConstants.DISEASE_REGISTRY_DEFAULT = { "leaf_spot", "rust", "powdery_mildew" }

-- Crop family for the CD-10 hybrid count ruling (2026-08-01): ONE resistant complex per
-- crop family, the default kept for everything else. The family is the right unit because
-- resistance breeds in a FIELD, across a rotation, through the disease pool a rotation
-- shares. Mint and cotton are deliberately absent: a herb and a fibre crop are each their
-- own world, and they fall to the default rather than to a bucket invented for them.
-- Lowercase crop key -> family name; every DISEASE_REGISTRY key resolves here or to the
-- default (the drift test in the CD-10 hybrid-family bench asserts exactly that).
--
-- NOTE THE NAME IS HYBRID_CROP_FAMILY, NOT CROP_FAMILY: that name is already a blessed
-- rotation-planner contract at line ~1698 (getCropFamily, read by DiseaseSystem.rotationMult)
-- with a DIFFERENT taxonomy (wheat=grain, maize=grain, mint=forage, cotton=other, peanut=root).
-- The hybrid brief named its table CROP_FAMILY but that slot is taken; a second assignment
-- of the same name would silently overwrite the rotation planner's table and change how it
-- scores crop chains. This table carries the hybrid ruling's OWN taxonomy (cereal, maize,
-- oilseed, root, pulse, forage) and is read only by HybridStrains.strainForPair.
SoilConstants.HYBRID_CROP_FAMILY = {
    -- cereal
    wheat      = "cereal", barley = "cereal", oat = "cereal", rye = "cereal",
    spelt      = "cereal", triticale = "cereal", greenrye = "cereal",
    buckwheat  = "cereal", millet = "cereal",
    -- maize
    maize      = "maize", sorghum = "maize",
    -- oilseed
    canola     = "oilseed", sunflower = "oilseed", mustard = "oilseed",
    linseed    = "oilseed", flax = "oilseed", poppy = "oilseed",
    sesame     = "oilseed", safflower = "oilseed",
    -- root
    potato     = "root", sugarbeet = "root", taro = "root",
    -- pulse
    soybean    = "pulse", pea = "pulse", peas = "pulse", driedpeas = "pulse",
    chickpea   = "pulse", chickpeas = "pulse", lentil = "pulse", lentils = "pulse",
    greenbean  = "pulse", bean = "pulse", beans = "pulse", pintobean = "pulse",
    pintobeans = "pulse", peanut = "pulse", peanuts = "pulse",
    -- forage
    alfalfa    = "forage", luzerne = "forage", clover = "forage",
    whiteclover = "forage", redclover = "forage", grass = "forage",
    meadow     = "forage", miscanthus = "forage",
}

-- Effectiveness fallback for any (chemical, category) pair not explicitly listed.
SoilConstants.DISEASE_DEFAULT_EFFECTIVENESS = 0.25

-- ========================================
-- CD-10 HYBRID STRAINS
-- ========================================
-- A field sprayed with the same one or two modes for long enough breeds an infection no
-- single chemical answers well. RESISTANCE.HYBRID_THRESHOLD (0.7) is the eligibility
-- fraction; these are the rest of the dials.
SoilConstants.HYBRID = {
    -- Candidacy weight per FRAC mode. Eligibility (3.2) decides which pairs QUALIFY;
    -- candidacy decides which qualifying pair actually FIRES. Weighting by real FRAC risk
    -- is not optional -- treating all mode-pairs as equal candidates was ruled out.
    --
    -- SINGLE-SITE modes are where resistance genuinely breeds: the fungus has one lock to
    -- pick. MULTISITE modes weight to ZERO, and that zero is doing real work -- a pair
    -- containing one is ELIGIBLE under the threshold arithmetic and still fires nothing,
    -- which is exactly the "weight low or to zero" the brief calls for.
    --
    -- Note M3 MANCOZEB: it is multisite but SYNTHETIC, so unlike M1/M2 it builds at the full
    -- rate and can genuinely reach the threshold. Zeroing it is a chemistry statement, not a
    -- side effect of it being slow -- multisite chemistry does not select for cross-resistance.
    --
    -- THE CURVE IS A FLAGGED SUBSTITUTION: the exact weighting is one of Arissani's four open
    -- CD-10 feel calls. This is the stated default shape, built per the brief's authorisation.
    MODE_RISK = {
        ["3"]  = 1.00,   -- DMI / triazole      - single-site, high risk
        ["11"] = 1.00,   -- QoI / strobilurin   - single-site, high risk (notorious for it)
        ["7"]  = 0.90,   -- SDHI                - single-site, high risk
        ["4"]  = 0.80,   -- phenylamide         - single-site, high risk
        M1     = 0.00,   -- copper   - MULTISITE, never a hybrid parent
        M2     = 0.00,   -- sulfur   - MULTISITE, never a hybrid parent
        M3     = 0.00,   -- mancozeb - MULTISITE, never a hybrid parent
    },
    -- Risk for a mode not listed above (a future chemical). Conservative: assume single-site
    -- until someone says otherwise, because the failure direction that matters is a hybrid
    -- that never fires, not one that fires slightly too readily.
    DEFAULT_MODE_RISK = 0.75,

    -- Re-onset cooldown after a hybrid clears, in CALENDAR MONTHS. Measured against
    -- daysPerPeriod exactly as the resistance decay is, so it is one real month on a 1-day
    -- month and on a 28-day month alike.
    --
    -- FLAGGED SUBSTITUTION: the length is another of Arissani's four open feel calls; one
    -- month is the brief's stated default.
    REONSET_COOLDOWN_MONTHS = 1,
}

-- Fungicide catalog. Menu-selectable chemicals (no physical fill type).
--   group   : chemistry family (for UI grouping + resistance-rotation tracking)
--   tier    : 1 basic / 2 intermediate / 3 advanced (progression flavor)
--   costPerHa : $/ha (converted from the proposal's $/acre × 2.471, rounded)
--   win     : { start, end } growth-stage fraction 0..1 where the product is on-window
--   prot    : base protection days (scaled by climate fungicideMult at apply time)
--   seedTreatment : true = applied pre-plant (knocks starting pressure, long protection)
--   eff     : category → 0..1 control rate (unlisted categories → DEFAULT_EFFECTIVENESS)
SoilConstants.FUNGICIDE_CATALOG = {
    -- ── Triazoles (broad-spectrum systemic) ─────────────────────────────────
    PROPICONAZOLE   = { group="triazole", tier=2, costPerHa=44, win={0.30,0.75}, prot=14,
        eff={ powdery_mildew=.90, rust=.90, blotch=.90, septoria=.90, fhb=.80, leaf_spot=.70,
              verticillium=.85, anthracnose=.55, ascochyta=.55, white_mold=.40, sclerotinia=.40,
              frogeye=.55, pasmo=.70 } },
    TEBUCONAZOLE    = { group="triazole", tier=2, costPerHa=52, win={0.30,0.70}, prot=14,
        eff={ fhb=.88, septoria=.85, blotch=.80, ascochyta=.80, leaf_spot=.78, rust=.82,
              powdery_mildew=.80, anthracnose=.70, white_mold=.55, sclerotinia=.55, frogeye=.60,
              verticillium=.70, pasmo=.70 } },
    PROTHIOCONAZOLE = { group="triazole", tier=3, costPerHa=62, win={0.25,0.65}, prot=16,
        eff={ rust=.92, septoria=.92, fhb=.92, blotch=.90, powdery_mildew=.88, leaf_spot=.85,
              ascochyta=.80, anthracnose=.75, white_mold=.65, sclerotinia=.65, frogeye=.70,
              verticillium=.80, pasmo=.80 } },
    FLUSILAZOLE     = { group="triazole", tier=2, costPerHa=40, win={0.20,0.40}, prot=12,
        eff={ powdery_mildew=.85, rust=.70, leaf_spot=.70, blotch=.70, septoria=.70, fhb=.55 } },
    CYPROCONAZOLE   = { group="triazole", tier=2, costPerHa=43, win={0.20,0.50}, prot=13,
        eff={ rust=.85, powdery_mildew=.82, blotch=.75, leaf_spot=.72, ascochyta=.70, septoria=.72 } },
    DIFENOCONAZOLE  = { group="triazole", tier=2, costPerHa=46, win={0.20,0.45}, prot=13,
        eff={ rust=.85, powdery_mildew=.82, septoria=.82, anthracnose=.75, leaf_spot=.78, blotch=.78 } },
    -- ── Strobilurins (QoI, fast-acting preventative/curative) ───────────────
    AZOXYSTROBIN    = { group="strobilurin", tier=2, costPerHa=54, win={0.25,0.70}, prot=14,
        eff={ leaf_spot=.90, anthracnose=.88, frogeye=.88, rust=.82, blotch=.78, blight=.55,
              ascochyta=.70, white_mold=.70, sclerotinia=.60, septoria=.70, powdery_mildew=.65,
              fhb=.60, verticillium=.70, pasmo=.75 } },
    PYRACLOSTROBIN  = { group="strobilurin", tier=3, costPerHa=58, win={0.25,0.65}, prot=14,
        eff={ leaf_spot=.88, frogeye=.88, anthracnose=.85, ascochyta=.80, rust=.82, blotch=.80,
              white_mold=.68, sclerotinia=.62, blight=.50 } },
    TRIFLOXYSTROBIN = { group="strobilurin", tier=2, costPerHa=53, win={0.30,0.70}, prot=14,
        eff={ powdery_mildew=.82, rust=.82, septoria=.80, leaf_spot=.80, blotch=.78 } },
    -- ── SDHI (succinate dehydrogenase, longer residual, late season) ────────
    BOSCALID        = { group="sdhi", tier=3, costPerHa=62, win={0.40,0.80}, prot=18,
        eff={ white_mold=.90, sclerotinia=.90, anthracnose=.82, ascochyta=.85, leaf_spot=.80,
              frogeye=.80, blight=.55, verticillium=.50 } },
    PENTHIOPYRAD    = { group="sdhi", tier=3, costPerHa=64, win={0.40,0.70}, prot=18,
        eff={ frogeye=.85, anthracnose=.82, leaf_spot=.82, white_mold=.80, ascochyta=.78, sclerotinia=.78 } },
    -- ── Contact protectants (multi-site, budget, preventative) ──────────────
    CHLOROTHALONIL  = { group="contact", tier=1, costPerHa=30, win={0.20,0.60}, prot=10,
        eff={ powdery_mildew=.60, rust=.60, blotch=.60, septoria=.65, fhb=.55, leaf_spot=.62,
              anthracnose=.60, ascochyta=.55, white_mold=.50, sclerotinia=.58, frogeye=.55,
              verticillium=.45, blight=.45, pasmo=.55 } },
    MANCOZEB        = { group="contact", tier=1, costPerHa=25, win={0.20,0.50}, prot=10,
        eff={ leaf_spot=.60, rust=.58, powdery_mildew=.55, anthracnose=.58, blotch=.55,
              septoria=.55, blight=.50 } },
    MANEB           = { group="contact", tier=1, costPerHa=19, win={0.20,0.50}, prot=9,
        eff={ leaf_spot=.52, anthracnose=.50, rust=.50, blotch=.48, powdery_mildew=.45 } },
    -- ── Specialty (oomycete / crop-specific) ────────────────────────────────
    METALAXYL       = { group="specialty", tier=2, costPerHa=42, win={0.10,0.35}, prot=14,
        eff={ root_rot=.88, blight=.80, downy_mildew=.85 } },
    FOSETYL_AL      = { group="specialty", tier=3, costPerHa=50, win={0.15,0.50}, prot=12,
        eff={ blight=.90, root_rot=.80 } },
    THIOPHANATE_METHYL = { group="specialty", tier=2, costPerHa=47, win={0.30,0.70}, prot=14,
        eff={ ascochyta=.82, anthracnose=.80, leaf_spot=.78, sclerotinia=.75, white_mold=.70 } },
    -- ── Early-season foliar preventatives ───────────────────────────────────
    SULFUR          = { group="preventative", tier=1, costPerHa=18, win={0.10,0.30}, prot=8,
        eff={ powdery_mildew=.70, rust=.50 } },
    COPPER_HYDROXIDE = { group="preventative", tier=1, costPerHa=27, win={0.15,0.35}, prot=9,
        eff={ leaf_spot=.55, rust=.55, blight=.50, anthracnose=.50 } },
    -- ── Seed treatments (pre-plant) ─────────────────────────────────────────
    FLUDIOXONIL     = { group="seed", tier=1, costPerHa=20, win={0.0,0.10}, prot=30, seedTreatment=true,
        eff={ root_rot=.70 } },
    METALAXYL_M     = { group="seed", tier=2, costPerHa=24, win={0.0,0.10}, prot=30, seedTreatment=true,
        eff={ root_rot=.80, blight=.60 } },
    THIRAM          = { group="seed", tier=1, costPerHa=18, win={0.0,0.10}, prot=25, seedTreatment=true,
        eff={ root_rot=.55, leaf_spot=.45 } },
    CAPTAN          = { group="seed", tier=1, costPerHa=20, win={0.0,0.10}, prot=25, seedTreatment=true,
        eff={ root_rot=.55, anthracnose=.55 } },
}

-- Ordered chemical id list for stable UI / console iteration.
SoilConstants.FUNGICIDE_ORDER = {
    "PROPICONAZOLE", "TEBUCONAZOLE", "PROTHIOCONAZOLE", "FLUSILAZOLE", "CYPROCONAZOLE", "DIFENOCONAZOLE",
    "AZOXYSTROBIN", "PYRACLOSTROBIN", "TRIFLOXYSTROBIN",
    "BOSCALID", "PENTHIOPYRAD",
    "CHLOROTHALONIL", "MANCOZEB", "MANEB",
    "METALAXYL", "FOSETYL_AL", "THIOPHANATE_METHYL",
    "SULFUR", "COPPER_HYDROXIDE",
    "FLUDIOXONIL", "METALAXYL_M", "THIRAM", "CAPTAN",
}

-- Physical fungicides: the catalog chemicals that also ship as buyable, sprayable fill
-- types (the 6-chemical kit + the sulfur/copper organic pair, OM-209). They stay in
-- recommend()/the scout list so scouting still names them as the right control, but the
-- menu/console INSTANT-apply paths reject them (you load the tank and spray instead).
-- Spraying routes into the catalog control math via onFungicideAppliedDirect. This set is
-- the single source of truth for "is physical". SULFUR/COPPER_HYDROXIDE are additionally
-- the organic-legal pair (see ORGANIC.APPROVED_INPUTS); the six synthetics breach cert.
SoilConstants.PHYSICAL_FUNGICIDE_ORDER = { "PROPICONAZOLE", "AZOXYSTROBIN", "BOSCALID", "MANCOZEB", "METALAXYL", "TEBUCONAZOLE", "SULFUR", "COPPER_HYDROXIDE" }
SoilConstants.PHYSICAL_FUNGICIDES = {
    PROPICONAZOLE = true, AZOXYSTROBIN = true, BOSCALID = true,
    MANCOZEB = true, METALAXYL = true, TEBUCONAZOLE = true,
    SULFUR = true, COPPER_HYDROXIDE = true,
}

-- Treatment mechanics (timing, weather, disease-stage gating).
SoilConstants.DISEASE_TREATMENT = {
    OUT_OF_WINDOW_MULT = 0.60,  -- effectiveness factor when applied outside the chemical's window
    RAIN_PENALTY       = 0.30,  -- effectiveness lost if applied while raining (washoff)
    -- Disease-stage curative falloff: early infection treats well, late does not.
    STAGE_EARLY_MAX    = 25,    -- pressure ≤ this = early infection
    STAGE_LATE_MIN     = 75,    -- pressure ≥ this = late infection
    STAGE_EARLY_EFF    = 1.00,  -- multiplier at/below early
    STAGE_LATE_EFF     = 0.40,  -- multiplier at/above late (linear between)
    -- Pressure removed = effectiveness × this (100 = a fully effective spray clears any tier).
    MAX_PRESSURE_REDUCTION = 100,
    MIN_EFFECTIVE      = 0.30,  -- below this control rate, treatment is "ineffective" (UI warning)
}

-- Disease difficulty (independent of the mod-wide difficulty). 1=Easy 2=Normal 3=Hard.
SoilConstants.DISEASE_DIFFICULTY = {
    [1] = { pressureMult = 0.60, fungicideEffMult = 1.15 }, -- Easy
    [2] = { pressureMult = 1.00, fungicideEffMult = 1.00 }, -- Normal
    [3] = { pressureMult = 1.30, fungicideEffMult = 0.90 }, -- Hard
}

-- Soil-health → disease pressure modifiers (multiply daily build-up).
SoilConstants.DISEASE_SOIL_HEALTH = {
    LOW_PH_THRESHOLD  = 6.0,  LOW_PH_MULT  = 1.20,  -- acidic soil = more disease
    HIGH_N_THRESHOLD  = 80,   HIGH_N_MULT  = 1.15,  -- lush high-N canopy = white mold / mildew
    OM_GOOD_THRESHOLD = 4.0,  OM_GOOD_MULT = 0.85,  -- good organic matter suppresses disease
}

-- Crop family classification (lowercased fruit name → family) for rotation scoring.
SoilConstants.CROP_FAMILY = {
    wheat="grain", barley="grain", oat="grain", rye="grain", spelt="grain", triticale="grain",
    maize="grain", sorghum="grain", millet="grain", buckwheat="grain", greenrye="grain",
    soybean="pulse", pea="pulse", peas="pulse", driedpeas="pulse", chickpea="pulse", chickpeas="pulse",
    lentil="pulse", lentils="pulse", greenbean="pulse", bean="pulse", beans="pulse",
    pintobean="pulse", pintobeans="pulse",
    canola="oilseed", sunflower="oilseed", linseed="oilseed", flax="oilseed", mustard="oilseed",
    poppy="oilseed", sesame="oilseed", safflower="oilseed",
    alfalfa="forage", luzerne="forage", clover="forage", whiteclover="forage", redclover="forage",
    grass="forage", meadow="forage", miscanthus="forage", mint="forage",
    potato="root", sugarbeet="root", taro="root", peanut="root", peanuts="root", carrot="root",
    parsnip="root", beetroot="root", cotton="other",
}

-- Rotation-planner candidate pool (published contract, #739). The single source
-- of truth for the curated crops the rotation surfaces project: a small set that
-- always exercises the three rotation outcomes (a legume for Bonus, a neutral
-- cereal for OK, plus the same-crop Fatigue row the caller adds). The field-detail
-- dialog's Rotation Foresight and the rotation planner both read THIS pool, so the
-- two surfaces can never disagree. Names are lowercase; getFruitTypeByName
-- upper-cases internally so they resolve on any map. Blessed for external readers
-- via SoilFertilitySystem:getRotationCandidatePool().
SoilConstants.ROTATION_CANDIDATE_POOL = {
    LEGUME  = { "soybean", "peas", "clover", "alfalfa" },
    NEUTRAL = { "wheat", "barley", "maize", "canola" },
}

-- Rotation → disease pressure modifiers (multiply daily build-up).
SoilConstants.DISEASE_ROTATION = {
    MONO_2YR_MULT  = 1.50,  -- same crop last 2 harvests
    MONO_3YR_MULT  = 1.80,  -- same crop last 3 harvests (e.g. peanuts replant)
    SAME_FAMILY_2  = 1.20,  -- different crop but same family 2 yrs (shared pathogens)
    ROTATE_MULT    = 0.75,  -- previous crop a different family
    ROTATE_3YR_MULT= 0.55,  -- three distinct families in a row
    LEGUME_BREAK_MULT = 0.60, -- a pulse or forage in the recent history breaks disease cycle
}

-- ========================================
-- SOIL MAP OVERLAY (SoilMapOverlay.lua)
-- ========================================
-- Legend panel geometry expressed as fractions of the map render area.
SoilConstants.MAP_OVERLAY = {
    LEGEND_MARGIN  = 0.02,  -- gap from map corner (fraction of map width)
    LEGEND_W_FRAC  = 0.13,  -- legend panel width   (fraction of map width)
    LEGEND_H_FRAC  = 0.17,  -- legend panel height  (fraction of map height)
}

-- ========================================
-- COMPACTION (P2-D)
-- ========================================
-- Compaction is modelled on real agronomy (Penn State / Missouri extension), not raw
-- mass. Two independent terms, scaled by soil moisture:
--   * SURFACE  ∝ ground contact pressure ≈ tire inflation pressure. Wide/flotation/
--     aired-down tyres spread the load → low pressure → little surface packing.
--   * SUBSOIL  ∝ axle load (regardless of tyres). ~10 t/axle damages subsoil; <5 t/axle
--     does not. This is the permanent-damage term a big tyre can't avoid.
--   * MOISTURE multiplier: wet soil compacts far worse ("hydraulic ram"); dry soil resists.
-- The numbers in SoilCompactionModel are calibrated against the contact-pressure
-- references in those sources (e.g. a 1360 kg car on tiny patches ≈ 827 kPa).
SoilConstants.COMPACTION = {
    -- Relevance gate: skip the whole calculation for light vehicles (cars, quads, UTVs).
    -- This is a perf/gameplay floor only - it is NOT the old "≥8 t = compact" rule.
    HEAVY_VEHICLE_THRESHOLD_T = 3.0,   -- tonnes (Vehicle:getTotalMass returns tonnes)

    -- Surface term: ground contact pressure → points. When Variable Tire Pressure is
    -- installed we read its live pressure (bar) directly; otherwise we approximate the
    -- contact pressure from live wheel geometry (see SoilCompactionModel).
    GROUND_PRESSURE = {
        FLOOR_KPA          = 80.0,   -- below this, no surface compaction (good flotation tyres / field mode)
        REF_KPA            = 250.0,  -- at/above this, full surface compaction (narrow road tyres / road mode)
        SURFACE_MAX        = 6.0,    -- max surface points per pass at/above REF_KPA
        BAR_TO_KPA         = 100.0,  -- 1 bar = 100 kPa (VTP reports pressure in bar)
        CONTACT_OFFSET_KPA = 10.0,   -- surface contact pressure ≈ tyre pressure + ~1-2 psi (PSU)
        CONTACT_LENGTH_FACTOR = 0.35,-- geometry fallback: contact-patch length ≈ radius × this
    },

    -- Subsoil term: axle load → points. Independent of tyre size (deep damage).
    AXLE_LOAD = {
        FLOOR_T         = 5.0,   -- <5 t/axle: no subsoil compaction (PSU)
        REF_T           = 10.0,  -- 10 t/axle: full subsoil compaction (PSU)
        SUBSOIL_MAX     = 3.0,   -- max subsoil points per pass at/above REF_T
        WHEELS_PER_AXLE = 2,     -- mass/axle estimate when wheel layout can't be resolved
    },

    -- Moisture multiplier applied to (surface + subsoil). Driven by a decaying wetness
    -- value that rises while raining and fades over DECAY_HOURS after the rain stops.
    MOISTURE = {
        DRY_MULT    = 0.6,   -- dry soil resists compaction
        WET_MULT    = 1.5,   -- saturated soil transfers stress straight down ("hydraulic ram")
        DECAY_HOURS = 12.0,  -- in-game hours for soil to dry back to DRY_MULT after rain
    },

    -- Legacy fallback: points added when a caller has no computed pressure (kept so any
    -- path that calls onCompaction without a points value still does something sane).
    COMPACTION_PER_PASS       = 6.0,
    NATURAL_DECAY_PER_DAY     = 0.5,   -- points removed per game day (natural recovery)
    -- Taproot bio-drilling (#687, long-term): deep-rooting crops drive roots through
    -- compacted layers and ease compaction as they grow. A small daily reduction while
    -- the crop stands, on top of natural decay - a slow passive helper, never a subsoiler
    -- replacement. Scaled per crop: oilseed radish is the classic bio-driller; canola less so.
    TAPROOT_DECOMPACT_PER_DAY = 0.4,   -- base points/day at full strength while standing
    TAPROOT_CROPS             = { oilseedradish = 1.0, canola = 0.5 },
    SUBSOILER_REDUCTION       = 15.0,  -- points removed per subsoiler pass (clears the deep pan)
    PLOW_RELIEF               = 3.0,   -- points removed per plow pass - a plough only loosens the
                                       -- topsoil it inverts; the deep pan stays, so it relieves far
                                       -- less than a subsoiler. Keeps the subsoiler meaningful and
                                       -- stops routine ploughing from erasing compaction (#687).
    -- Grassland compaction relief (#680). A grassland weeder (isGrasslandWeeder: aerators,
    -- sward renovators) works the sward WITHOUT destroying it, so it can ease pasture
    -- compaction without a reseed - but only a partial amount (it is not a deep subsoiler).
    GRASSLAND_RELIEF          = 3.0,   -- points removed per generic grassland-weeder pass
    -- Deep grassland sward-lifters (e.g. Latapia 5P1H) ARE built as Cultivator+isSubsoiler,
    -- so they already get the full SUBSOILER_REDUCTION - but as cultivators they destroy the
    -- grass. Tools whose configFileName matches one of these lowercase substrings are treated
    -- as grass-preserving: SF snapshots the sward before the pass and restores it after, so the
    -- deep tool decompacts without forcing a reseed. Extend freely as more mods are confirmed.
    GRASSLAND_DEEP_TOOLS      = { "latapia" },
    GRASS_RESTORE_DEBOUNCE_MS = 1000,  -- min gap between whole-field sward restores per field
    MAX_COMPACTION            = 100.0,
    NUTRIENT_PENALTY_MAX      = 0.20,  -- max 20% extra nutrient extraction at max compaction
    YIELD_PENALTY_MAX         = 0.15,  -- max 15% direct yield loss at max compaction (#713):
                                       -- compacted soil restricts roots, so the crop yields less
                                       -- even when N/P/K are topped up. Scales linearly with compaction.
    -- Driving-based compaction: any heavy vehicle moving across a field compacts the
    -- cell under it, whether or not it is working (spraying/harvesting/tilling have
    -- their own hooks too). Sampled on a short timer so the wheels lay a continuous
    -- trail instead of one tile every 30 s.
    CHECK_INTERVAL_MS         = 1000,  -- how often the driving check samples vehicle position
    MIN_MOVE_DISTANCE_M       = 2.0,   -- must move at least this far between samples (skip when parked)
    MAX_SEGMENT_M             = 30.0,  -- if the vehicle jumped more than this between samples assume a
                                       -- teleport/fast-travel and don't paint a compaction line across the gap

    -- SF-55 TRAFFIC ON WET GROUND (trafficDrag): a loaded wheel crossing wet ground
    -- bruises a standing crop, quietly worse at harvest. Own small layer, bounded
    -- 0.0-0.3 AT THE WRITE, composed read-only at SF-14's harvest read as
    -- effective = capturedEfficiency * (1 - trafficDrag), never written into
    -- yieldEfficiency (the second-writer fence). Dials per Authority #1, all
    -- AWAITING-SPINE: the cap is SF-55's own small dial; the magnitude and the
    -- wetness threshold are neutral defaults until the spine lands.
    TRAFFIC_DRAG = {
        MAGNITUDE_PER_EVENT = 0.05,    -- trafficDrag accrued per wet-ground traffic event
        CAP                 = 0.3,     -- layer bound: the composed read never falls more than 30% off SF-14
        WETNESS_THRESHOLD   = 0.5,     -- blended wetness (0..1) at/above which ground reads "wet" for bruising
        MIN_STANDING_GROWTH_STATE = 1, -- growthState at/above which a crop is "standing" (confirm 1)
    },
}

-- ========================================
-- SEE & SPRAY (System 2)
-- ========================================
-- Per-cell pressure thresholds (0-100 scale, same as PEST/DISEASE/WEED_PRESSURE tiers).
-- Sections are suppressed when the cell value is BELOW the threshold.
SoilConstants.SEE_AND_SPRAY = {
    PEST_THRESHOLD    = 10,   -- suppress if cell pestPressure    < 10
    DISEASE_THRESHOLD = 10,   -- suppress if cell diseasePressure < 10
    WEED_THRESHOLD    = 15,   -- suppress if cell weedPressure    < 15 (weeds need more to justify spraying)
    -- #678 variable-rate See & Spray: pressure (0-100) at or above which a section
    -- runs at full rate. Between the suppress threshold and this value the section
    -- ramps from MIN_RATE up to MAX_RATE. Only used when per-vehicle Variable Rate
    -- is enabled; otherwise See & Spray stays hard on/off.
    FULL_RATE_PRESSURE = 50,
}

-- ========================================
-- VARIABLE RATE APPLICATION (System 3)
-- ========================================
-- Per-section rate multiplier derived from the nutrient deficit at each section's soil cell.
-- The manual rate setting acts as a ceiling; variable rate cannot exceed it.
-- CD-9: Per-MOA disease resistance tuning values
-- RESISTANCE_BUILD_PER_APPLICATION: fractional immunity gained per full-rate pass of one MOA
-- RESISTANCE_DECAY_MONTHLY: multiplier applied per unused month (calendar-normalized)
-- HYBRID_THRESHOLD: resistance level at which ≥2 modes triggers hybrid onset
-- RESISTANCE_MAX_SYNTHETIC: ceiling for synthetic MOA scores (10 = 100% immunity)
-- RESISTANCE_MAX_NATURAL: ceiling for natural/bio MOA scores (5 = 50% immunity)
SoilConstants.RESISTANCE = {
    BUILD_PER_APPLICATION = 0.05,
    DECAY_MONTHLY         = 0.85,
    HYBRID_THRESHOLD      = 0.7,
    MAX_SYNTHETIC         = 10,
    MAX_NATURAL           = 5,

    -- CD-11: the BAND enum a client may see. Resistance is simulated as a raw score, but
    -- a raw score is never rendered and (by default) never travels: the server computes a
    -- band and the client reads only that. UNKNOWN is a first-class value, NOT an absence
    -- -- an unscouted or unsynced field reads UNKNOWN and must never fall back to WORKING,
    -- or a client renders "your fungicide is fine" about ground it has never looked at.
    BANDS = {
        UNKNOWN  = -1,   -- never scouted, or not yet synced. Distinct from every real band.
        WORKING  = 0,    -- the chemical still does what the label says
        SLIPPING = 1,    -- measurably weaker; rotate the mode of action
        FINISHED = 2,    -- effectiveness is provably zero on this mode
    },

    -- Band cut points, as a FRACTION of the mode's own ceiling (MAX_SYNTHETIC /
    -- MAX_NATURAL), so naturals and synthetics band on the same scale.
    --
    -- FINISHED is ANCHORED at 1.0 by the CD-11 SDS and is not a tuning knob: at ratio 1.0
    -- the build's own penalty is (1 - score/maxRes) = 0, so the chemical is provably inert.
    -- SLIPPING is the open tuning question the SDS left to engineering; it is a named
    -- constant precisely so it can be retuned without touching the sync path.
    BAND_CUT_SLIPPING = 0.5,
    BAND_CUT_FINISHED = 1.0,

    -- FRAC modes that cap at MAX_NATURAL rather than MAX_SYNTHETIC.
    --
    -- Keyed by MODE, not by chemical, because field.resistance is keyed by mode. (The
    -- CD-11 brief's pseudocode calls isNaturalFungicide(mode); that cannot work -- it takes
    -- a fill-type name like "SULFUR", so every mode returns false and a saturated natural
    -- would band against the synthetic ceiling and read half-clean.)
    --
    -- Mirrors the natural entries of SoilFertilitySystem's MODE_FOR_FILLTYPE (SULFUR -> M2,
    -- COPPER_HYDROXIDE -> M1). resistance_bands_cd11_test asserts the two agree, so adding
    -- a natural chemical without updating this fails the suite rather than shipping a
    -- silently wrong ceiling.
    NATURAL_MODES = { M1 = true, M2 = true },

    -- F68: THE DURABILITY DIAL, and it has to live on the BUILD RATE rather than the ceiling.
    --
    -- MAX_NATURAL looks like it makes sulfur and copper more durable. It does not, and this
    -- was certified at three sites: the ceiling MULTIPLIES the build, DIVIDES the penalty
    -- (1 - score/maxRes) and SCALES the bands (a fraction of that same ceiling), so it
    -- cancels in all three. Synthetic: 0.05 x 10 = 0.5 per pass into a ceiling of 10 = 20
    -- passes. Natural: 0.05 x 5 = 0.25 into a ceiling of 5 = ALSO exactly 20 passes. The
    -- penalty at pass N is 1 - 0.05N either way. Anyone tuning MAX_NATURAL to make sulfur
    -- last longer would change nothing and believe they had -- which is worse than a missing
    -- feature, because the constant reads like a dial.
    --
    -- So the real dial is here, applied to the BUILD TERM ONLY. The ceiling keeps its one
    -- honest job: setting where FINISHED sits.
    --
    -- THE AGRONOMY: sulfur and copper are MULTISITE -- they attack the fungus at many
    -- biochemical points at once, so it has to defeat all of them. FRAC grades the M-group
    -- LOW resistance risk on decades of field use with almost no documented resistance. A
    -- triazole hits ONE site, and a fungus picks one lock far faster than twelve.
    --
    -- AND THE FAIRNESS REASON, which is what re-graded F68 from LOW to MEDIUM: by CD-12's
    -- own ruling an organic grower has exactly ONE legal mix, so he cannot rotate modes --
    -- there is nothing to rotate to. Under the old arithmetic he burned out his only
    -- chemistry at precisely the rate of a farmer hammering one synthetic by choice. The
    -- system punished him identically for a decision he was never offered.
    --
    -- 0.25 gives roughly 80 full-rate passes to saturation against the synthetic's 20.
    -- Ruled by Tyson 2026-08-01 on Claude(A)'s recommendation. This is the tuning knob:
    -- raise it to burn naturals faster, lower it to make them nearer-permanent.
    BUILD_RATE_NATURAL   = 0.25,
    BUILD_RATE_SYNTHETIC = 1.0,
}

SoilConstants.VARIABLE_RATE = {
    NUTRIENT_TARGET = 70,     -- "well stocked" level - same as Smart Sensor NUTRIENT_TARGET
    MIN_RATE        = 0.30,   -- minimum multiplier (field at or above target → light top-up pass)
    MAX_RATE        = 1.50,   -- maximum multiplier (completely depleted cell)
    PH_OPTIMAL      = 6.5,   -- optimal pH target (reuse NUTRIENT_LIMITS.PH_OPTIMAL)
    PH_CURVE_FLOOR  = 5.0,   -- max rate at pH <= floor (reuse NUTRIENT_LIMITS.PH_MIN)
}

-- ========================================
-- TUNING EDITOR LOOK-UP TABLES
-- ========================================
-- 5-step sliders for the Constants Tuning Editor.
-- Index 3 = default (×1.0 or base value).  Admin-only panel maps
-- settings integer 1-5 → actual simulation value via these tables.
SoilConstants.TUNING = {
    DEFAULT_N  = {15, 30,  50,  75, 100},       -- Starting nitrogen  (points); idx 3 = fair (~FIELD_DEFAULTS)
    DEFAULT_P  = {15, 25,  35,  50,  70},        -- Starting phosphorus (points)
    DEFAULT_K  = {10, 20,  40,  65, 100},        -- Starting potassium  (points); idx 3 = fair (~FIELD_DEFAULTS)
    DEFAULT_PH = {5.5, 6.0, 6.5, 7.0, 7.5},     -- Starting pH
    DEFAULT_OM = {2.0, 3.0, 4.5, 6.5, 9.0},     -- Starting organic matter (%); idx 3 lowered 6.0→4.5 (#632) so fields aren't uniformly rich
    RATE_MULT  = {0.25, 0.50, 1.0, 1.50, 2.0},  -- Depletion / efficiency multiplier
    ZERO_MULT  = {0.0,  0.50, 1.0, 1.50, 2.0},  -- Stress/effect multiplier (0 = disabled)
}

-- ========================================
-- HARVEST CONTRACT UNDERWRITE (#741 / SF-29)
-- ========================================
-- Base-game harvest contracts only ever run on UNOWNED (neighbour) fields, which roll a
-- poor soil profile and sit excluded from the daily sim. SF's yield modifier then cuts the
-- delivered liters, so the contract's liters-based completion (anchored to a full-health
-- expectation) never reaches 100% - a field can be fully harvested and still read ~32%
-- (#741). The underwrite tops the contract's OWN completion accounting up to the vanilla
-- expectation at delivery by dividing out SF's own yield modifier. It writes no soil, moves
-- no farm money (the base game pays its own reward on success), and is capped at 1.0 so it
-- can never exceed the vanilla amount. Composes cleanly with the RETAINED FieldSentry
-- contract mask (orthogonal: the mask skips the daily sim, this corrects harvest accounting).
SoilConstants.HARVEST_UNDERWRITE = {
    ENABLED = true,   -- master switch for the #741 completability guarantee (server-side)
}

SoilLogger.info("Constants loaded")