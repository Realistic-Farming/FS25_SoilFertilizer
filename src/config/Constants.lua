-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Constants
-- =========================================================
-- All tunable values: timing, difficulty, nutrient limits,
-- crop extraction rates, fertilizer profiles, HUD config.
-- Single source of truth — modify here, not in system code.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilConstants
SoilConstants = {}

-- ========================================
-- TIMING
-- ========================================
SoilConstants.TIMING = {
    UPDATE_INTERVAL = 30000,     -- ms between periodic checks
    FALLOW_THRESHOLD = 7,        -- days before fallow recovery kicks in
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
-- PLOWING
-- ========================================
-- Thresholds for plowing operations
SoilConstants.PLOWING = {
    MIN_DEPTH_FOR_PLOWING = 0.15,  -- Minimum working depth (meters) to qualify as deep plowing
    PEST_PRESSURE_REDUCTION    = 30,  -- Points removed from pest pressure on plowing
    DISEASE_PRESSURE_REDUCTION = 40,  -- Points removed from disease pressure on plowing
}

-- ========================================
-- CULTIVATION (shallow tillage — non-plowing passes)
-- ========================================
-- WEED_PRESSURE_REDUCTION set to 100 so a single full cultivation pass fully clears
-- weed pressure (the hook fires per-area tick, clamped to 0 by math.max).
-- Agronomically correct: shallow tillage disrupts annual weed seedlings entirely;
-- only perennial roots survive, which the game does not distinguish.
SoilConstants.CULTIVATION = {
    WEED_PRESSURE_REDUCTION    = 100, -- Full reset (was 20 — insufficient for clearing all weeds)
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
--   • Small OM boost in tilled strips (some sub-surface matter incorporated)
-- The RidgeTiller FS25 spec (processRidgeTillerArea / RIDGEFORMER work area)
-- is completely separate from Cultivator.processCultivatorArea, so a dedicated
-- hook is required.
SoilConstants.STRIP_TILL = {
    WEED_PRESSURE_REDUCTION    = 15,  -- pts; less than cultivator (partial surface coverage)
    PEST_PRESSURE_REDUCTION    = 12,  -- pts; more than cultivator (deep knife action)
    DISEASE_PRESSURE_REDUCTION = 10,  -- pts; less than cultivator (residue left in place)
    OM_BOOST                   = 0.10, -- % OM increase per pass (tilled-strip incorporation)
    -- No pH normalization — strip-till does not invert soil horizons
}

-- ========================================
-- RESIDUE INCORPORATION (Issue #338)
-- ========================================
-- When post-harvest tillage works stubble and straw residue back into
-- the soil, it decomposes and releases a small amount of organic matter
-- and nutrients (especially N and K from cereal straw, P is minimal).
-- Each tillage type has its own incorporation efficiency:
--   Plow      : deepest incorporation — highest OM and N release
--   Cultivator: shallow mixing — moderate OM release, small NPK
--   Strip-till: partial surface coverage — lowest incorporation
--   Sowing    : direct-drill openers disturb minimal residue
--
-- All values are per-pass additive boosts (on the 0-100 scale for N/P/K,
-- and on the 0-10 OM scale). They are small by design — straw residue
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
--   Strip-till: OM+0.03, N+0.2, P+0.02,K+0.15 (15% — only tilled strips)
--   Direct-drill: OM+0.02, N+0.1, P+0.01,K+0.08 (10% — opener disturbance only)
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
        OM = 0.05,
        N  = 1.2,
        P  = 0.4,
        K  = 0.8,
    },
    DIRECT_DRILL = {
        OM = 0.03,
        N  = 0.6,
        P  = 0.2,
        K  = 0.4,
    },
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
-- CHOPPED STRAW / CHAFF ORGANIC MATTER GAIN
-- ========================================
-- When a combine chops straw instead of dropping it, the material decomposes
-- into the soil and adds organic matter (realistic agricultural behaviour).
-- OM is a concentration — gain uses (areaHa / fieldAreaHa) * strawRatio * OM_RATE.
-- A complete field harvest at strawRatio=1.0 adds exactly OM_RATE to the field,
-- regardless of field size. Partial passes add a proportional fraction.
-- Example: full 5ha field, strawRatio=0.5 → 0.5 × 0.20 = 0.10 OM
SoilConstants.CHOPPED_STRAW = {
    OM_RATE = 0.20,   -- OM gain per full-field harvest at strawRatio=1.0
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
}

-- ========================================
-- CROP ROTATION
-- ========================================
SoilConstants.CROP_ROTATION = {
    LEGUME_BONUS_N_PER_DAY = 0.5,   -- N added per day during bonus window
    LEGUME_BONUS_DAYS       = 3,     -- spring bonus lasts this many days
    FATIGUE_MULTIPLIER      = 1.15,  -- nutrient extraction ×1.15 for same-crop consecutive seasons
    LEGUMES = { soybean = true, peas = true, beans = true, luzerne = true, clover = true },
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
SoilConstants.FERTILIZER_PROFILES = {
    -- Base game (NPK balanced)
    LIQUIDFERTILIZER  = { N=79.2, P=198.0, K=44.5 },          -- 93.5 L/ha: ~20N, ~10P, ~15K ppm
    FERTILIZER        = { N=41.1, P=164.6, K=24.7 },          -- 225 kg/ha: ~25N, ~20P, ~20K ppm
    MANURE            = { N=0.53, P=0.25,  K=0.45, OM=0.04 }, -- 14000 L/ha: ~7N, ~3.5P, ~6K pts/pass (UNL beef N:P:K ratio)
    LIQUIDMANURE      = { N=0.50, P=0.35,  K=0.65, OM=0.03 }, -- Slurry — dairy N:P:K 1:0.70:1.33 (UNL g1335)
    DIGESTATE         = { N=1.32, P=0.80,  K=0.80, OM=0.04 }, -- Digestate — 12,600 L/ha → ~50N/6P/40K ppm per pass (calibrated with real farmer input)
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
    GYPSUM            = { pH=-0.10, OM=0.22 }, -- 1500 kg/ha: -0.25 pH shift, OM boost

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
    COMPOST           = { N=0.74, P=0.55, K=0.55, OM=0.60 }, -- 5000 kg/ha
    BIOSOLIDS         = { N=2.05, P=1.20, K=1.23, OM=0.45 }, -- 4500 kg/ha: ~+9N, +5P, +5K pts/pass
    CHICKEN_MANURE    = { N=3.70, P=2.80, K=2.78, OM=0.55 }, -- 2000 kg/ha: ~+7N, +5P, +5K pts/pass
    PELLETIZED_MANURE = { N=16.4, P=8.20, K=18.5, OM=0.40 }, -- 450 kg/ha:  ~+7N, +3P, +8K pts/pass

    -- Crop protection products (Handled via effectiveness calculation)
    INSECTICIDE = { pestReduction = 1.0 },
    FUNGICIDE   = { diseaseReduction = 1.0 },
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
-- Legumes (soybean, peas, beans) have low N targets — they fix atmospheric N.
-- Root crops (potato, sugarbeet) have very high K targets — they partition K into tubers.
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
-- Nothing in the simulation changes — these multipliers are display-only.
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
        luzerne    = "tolerant",   -- legume forage — fixes own N
        clover     = "tolerant",   -- legume forage — fixes own N
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

    -- Crops that are not row-crop harvests; skip yield forecast for these
    NON_CROP_NAMES = {
        grass = true, drygrass = true, poplar = true, oilseedradish = true,
        luzerne = true, clover = true,
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
        [1] = { x = 0.850, y = 0.70 },  -- Top Right
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
        [1] = 0.42,  -- Clear  (was 0.25 — raised so panel stays visible)
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
    BURN_PH_DROP_RISK         = 0.15,  -- pH units lost on probabilistic burn
    BURN_PH_DROP_CERTAIN      = 0.30,  -- pH units lost on guaranteed burn
    BURN_N_DRAIN_RISK         = 5.0,   -- N points lost on probabilistic burn
    BURN_N_DRAIN_CERTAIN      = 12.0,  -- N points lost on guaranteed burn
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
        -- Crop protection — 100 L/ha = realistic water+product carrier mixture
        -- (1.5 L/ha was pure active ingredient dose; 100-150 L/ha is field-realistic)
        INSECTICIDE = { value = 100.0, unit = "liquid" },
        FUNGICIDE   = { value = 100.0, unit = "liquid" },
        HERBICIDE   = { value = 100.0, unit = "liquid" },
        -- Fallback for unrecognized fill types
        DEFAULT           = { value =    93.5, unit = "liquid" },
    },

    -- Target nutrient levels for Auto-Rate Control
    -- Used when SF_TOGGLE_AUTO is active on a sprayer
    AUTO_RATE_TARGETS = {
        N  = 80,
        P  = 50,   -- was 70 (42 ppm); lowered to 50 (30 ppm) — above most crop P optima without over-shooting
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
    WEED_STATE_WITHERED  = 7,   -- small withered — visible brown weeds

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
    -- (insects disperse when the host crop is removed)
    HARVEST_RESET_FRACTION = 0.30,

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
    DRY_DAYS_THRESHOLD = 3,    -- after this many dry days, decay begins
    DRY_DECAY_RATE     = 0.5,  -- pts/day removed during dry period

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
SoilConstants.COMPACTION = {
    HEAVY_VEHICLE_THRESHOLD_T = 8.0,   -- tonnes (Vehicle:getTotalMass returns tonnes)
    COMPACTION_PER_PASS       = 8.0,   -- points added per heavy-vehicle pass over a cell (once/day/cell).
                                       -- Sized to clear the minimap heatmap's lowest visible bucket
                                       -- (top-4-bit DMV → first colour at ~6.3%) so a single pass shows.
    NATURAL_DECAY_PER_DAY     = 0.5,   -- points removed per game day (natural recovery)
    SUBSOILER_REDUCTION       = 15.0,  -- points removed per subsoiler pass
    MAX_COMPACTION            = 100.0,
    NUTRIENT_PENALTY_MAX      = 0.20,  -- max 20% extra nutrient extraction at max compaction
    -- Driving-based compaction: any heavy vehicle moving across a field compacts the
    -- cell under it, whether or not it is working (spraying/harvesting/tilling have
    -- their own hooks too). Sampled on a short timer so the wheels lay a continuous
    -- trail instead of one tile every 30 s.
    CHECK_INTERVAL_MS         = 1000,  -- how often the driving check samples vehicle position
    MIN_MOVE_DISTANCE_M       = 2.0,   -- must move at least this far between samples (skip when parked)
    MAX_SEGMENT_M             = 30.0,  -- if the vehicle jumped more than this between samples assume a
                                       -- teleport/fast-travel and don't paint a compaction line across the gap
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
}

-- ========================================
-- VARIABLE RATE APPLICATION (System 3)
-- ========================================
-- Per-section rate multiplier derived from the nutrient deficit at each section's soil cell.
-- The manual rate setting acts as a ceiling; variable rate cannot exceed it.
SoilConstants.VARIABLE_RATE = {
    NUTRIENT_TARGET = 70,     -- "well stocked" level — same as Smart Sensor NUTRIENT_TARGET
    MIN_RATE        = 0.30,   -- minimum multiplier (field at or above target → light top-up pass)
    MAX_RATE        = 1.50,   -- maximum multiplier (completely depleted cell)
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
    DEFAULT_OM = {2.0, 4.0, 6.0, 8.0, 10.0},    -- Starting organic matter (%)
    RATE_MULT  = {0.25, 0.50, 1.0, 1.50, 2.0},  -- Depletion / efficiency multiplier
    ZERO_MULT  = {0.0,  0.50, 1.0, 1.50, 2.0},  -- Stress/effect multiplier (0 = disabled)
}

SoilLogger.info("Constants loaded")