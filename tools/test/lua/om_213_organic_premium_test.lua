-- om_213_organic_premium_test.lua - OM-213 organic market premium (structural bar).
--   Exercises the REAL shipped SF OrganicCertification provenance ledger + the REAL
--   MDM MarketEngine + the REAL OrganicPremiumBridge modifier, stubbed only at the
--   engine surface. Closes H5's structural half: a non-1.0 modifier genuinely moves
--   `_recalculate`'s output on the engine, and clamp B clips at 3.0. The end-to-end
--   SellingStation observation (the premium visible at a sell point) is the in-game
--   acceptance item this bar deliberately does not pretend to cover.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, ../FS25_MarketDynamics/src/MarketEngine.lua, ../FS25_MarketDynamics/src/OrganicPremiumBridge.lua

-- ── engine-surface stubs ────────────────────────────────
MDMLog = { info = function() end, warn = function() end, debug = function() end }

g_SoilFertilityManager = { settings = {}, soilSystem = nil }
local organic = OrganicCertification.new(nil)
g_SoilFertilityManager.organic = organic

-- The engine-side farm context the modifier reads (set by PriceHook at sale).
g_MarketDynamics = {
    priceModifiers = {},
    _organicSellingFarmId = 0,
    registerPriceModifier = function(_self, name, fn)
        g_MarketDynamics.priceModifiers[name] = fn
        return true
    end,
    unregisterPriceModifier = function(_self, name)
        g_MarketDynamics.priceModifiers[name] = nil
        return true
    end,
    marketEngine = nil,
}

local C = SoilConstants.ORGANIC
local WHEAT = 5

-- ── provenance blend arithmetic ─────────────────────────
-- A certified field's harvest raises the share; conventional dilutes it.
local function newField(state)
    return { organic = { state = state, startDay = 0, certifiedDay = 0, breaches = 0 } }
end

local function setField(fid, f)
    organic.soilSystem = { fieldData = { [fid] = f } }
end

T.ok("premium: default fraction is zero for an unknown farm/type",
    organic:getFarmOrganicFraction(1, WHEAT) == 0)

local f1 = newField(C.STATE_CERTIFIED)
setField(1, f1)
organic:recordHarvest(1, 1, WHEAT, 1000)      -- certified first 1000 L
T.near("premium: certified harvest sets fraction to 1", organic:getFarmOrganicFraction(1, WHEAT), 1.0)

f1.organic.state = C.STATE_CONVENTIONAL
organic:recordHarvest(1, 1, WHEAT, 1000)      -- conventional 1000 L dilutes to 0.5
T.near("premium: conventional harvest dilutes the share", organic:getFarmOrganicFraction(1, WHEAT), 0.5)

f1.organic.state = C.STATE_CERTIFIED
organic:recordHarvest(1, 1, WHEAT, 1000)      -- certified 1000 L raises to 2/3
T.near("premium: later certified harvest re-raises the share", organic:getFarmOrganicFraction(1, WHEAT), 2 / 3, 1e-9)

T.ok("premium: transition-state harvest counts as conventional",
    organic:getFarmOrganicFraction(1, 8) == 0)
setField(1, newField(C.STATE_TRANSITION))
organic:recordHarvest(1, 1, 8, 500)
T.near("premium: transition fold leaves the share conventional", organic:getFarmOrganicFraction(1, 8), 0)

T.ok("premium: guards reject junk harvest args", organic:recordHarvest(1, 0, WHEAT, 100) == nil)
T.ok("premium: per-farm isolation holds", organic:getFarmOrganicFraction(2, WHEAT) == 0)

-- ── persistence round trip (XML safety copy) ─────────────
local xml = {}
organic:saveFractionsXML(xml, "soil")
organic:applyFractionsTable({})
T.eq("premium: XML save/load round trip", organic:getFarmOrganicFraction(1, WHEAT), 0)
organic:loadFractionsXML(xml, "soil")
T.near("premium: fractions restored from XML", organic:getFarmOrganicFraction(1, WHEAT), 2 / 3, 1e-9)

-- ── modifier behaviour ──────────────────────────────────
OrganicPremiumBridge.register()
T.eq("premium: modifier registered with the registry", g_MarketDynamics.priceModifiers["OrganicPremium"] ~= nil, true)

local fn = g_MarketDynamics.priceModifiers["OrganicPremium"]

g_MarketDynamics._organicSellingFarmId = 0
T.eq("premium: no selling-farm context opts out", fn({ fillTypeIndex = WHEAT }), nil)

g_MarketDynamics._organicSellingFarmId = 2     -- farm 2 has no fraction
T.eq("premium: zero-fraction farm opts out", fn({ fillTypeIndex = WHEAT }), nil)

-- farm 3: a single certified harvest -> a full 1.0 organic share
setField(3, newField(C.STATE_CERTIFIED))
organic:recordHarvest(3, 3, WHEAT, 1000)
g_MarketDynamics._organicSellingFarmId = 3
T.near("premium: full organic share pays the full multiplier",
    fn({ fillTypeIndex = WHEAT }), OrganicPremiumBridge.ORGANIC_PREMIUM.CERTIFIED)

-- farm 1 now has 2/3 organic wheat: multiplier = 1 + 0.20 * (2/3) ≈ 1.1333
g_MarketDynamics._organicSellingFarmId = 1
local frac = organic:getFarmOrganicFraction(1, WHEAT)
T.near("premium: partial share pays a proportional multiplier", fn({ fillTypeIndex = WHEAT }), 1.0 + 0.20 * frac, 1e-9)

local sfAbsent = g_SoilFertilityManager.organic
g_SoilFertilityManager.organic = nil
T.eq("premium: SF absent opts out", fn({ fillTypeIndex = WHEAT }), nil)
g_SoilFertilityManager.organic = sfAbsent

-- ── the modifier moves the REAL engine's price, clamp B clips ──
local engine = MarketEngine.new()
engine.prices[WHEAT] = { base = 10, volatilityFactor = 1.0, modifiers = {}, current = 10, history = {} }
g_MarketDynamics.marketEngine = engine

g_MarketDynamics._organicSellingFarmId = 1    -- farm with a positive organic share
engine:_recalculate(WHEAT)
T.near("premium: recalculate moves the price for an organic seller",
    engine:getPrice(WHEAT), 10 * (1.0 + 0.20 * frac), 1e-6)

g_MarketDynamics._organicSellingFarmId = 2    -- no organic share -> vanilla price
engine:_recalculate(WHEAT)
T.near("premium: recalculate leaves a conventional seller's price unchanged",
    engine:getPrice(WHEAT), 10, 1e-6)

-- clamp B: a modifier beyond the ruled band clips at 3.0
g_MarketDynamics.priceModifiers["TestClamp"] = function() return 4.0 end
engine.prices[WHEAT].current = 10
g_MarketDynamics._organicSellingFarmId = 1
engine:_recalculate(WHEAT)
T.near("premium: clamp B clips the composition band at 3.0", engine:getPrice(WHEAT), 30, 1e-6)
g_MarketDynamics.priceModifiers["TestClamp"] = nil

-- registration lifecycle
OrganicPremiumBridge.unregister()
T.eq("premium: modifier unregistered", g_MarketDynamics.priceModifiers["OrganicPremium"], nil)

T.summary()
