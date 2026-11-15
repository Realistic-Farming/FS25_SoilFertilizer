-- om_213_organic_premium_test.lua - OM-213 organic market premium (structural bar).
--   Exercises the REAL shipped SF OrganicCertification provenance ledger + the REAL
--   MDM MarketEngine + the REAL OrganicPremiumBridge modifier, stubbed only at the
--   engine surface. Closes H5's structural half: a non-1.0 modifier genuinely moves
--   `_recalculate`'s output on the engine, and clamp B clips at 3.0. The end-to-end
--   SellingStation observation (the premium visible at a sell point) is the in-game
--   acceptance item this bar deliberately does not pretend to cover.
--
-- =============================================================================
-- READ THIS BEFORE TRUSTING A GREEN RESULT FROM THIS FILE.
--
-- THIS TEST LOADS ANOTHER REPOSITORY'S WORKING TREE BY RELATIVE PATH. The
-- ../FS25_MarketDynamics entries below are not pinned to a commit, a tag or a
-- branch. They read whatever that clone happens to be checked out on at the
-- moment the suite runs. Two people running this at the same time on the same
-- machine can get different meanings from the same assertions.
--
-- MD-16 MERGED (MarketDynamics #153, 2026-11-06), AND THIS FILE NOW READS IT.
-- MarketEngine excludes the pooled OrganicPremium modifier BY NAME inside its
-- composition loop, reading Md16SaleComponents.RETIRED_MODIFIER. So the md16
-- modules that carry that name are on the load list below, after
-- MarketEngine.lua, in the order modDesc loads them: Md16Material, then
-- Md16SaleComponents, which depends on it. Without them MarketEngine composes
-- as it did before MD-16, and this file was green at a premium the game no
-- longer pays (21 of 21, 2026-11-11). The "MD-16 retirement is loaded" rows
-- below fail if they ever drop off the list again.
--
-- WHAT MOVED, AND ONLY THAT: the market-wide quote for an organic seller is
-- now the base price, not base * (1 + 0.20 * frac). The direct modifier calls
-- still return the premium, because the bridge still registers its function
-- and the exclusion happens at the composition point, not in the function.
-- The conventional-seller, clamp B and pure-client rows come out the same.
--
-- WHAT THIS FILE DOES NOT COVER. MD-16 pays its replacement per load, at the
-- sale: MarketDynamics' Md16SalePhase (MarketDynamics #177) reads StockGuard's
-- record of the sold litres and the harvestOrganicOriginV1 this mod puts on
-- them. That is proved by MarketDynamics' own sale bar
-- (MD-16-sale_phase_wiring_spec_test.lua) and in game; it needs StockGuard, so
-- this Soil-side structural bar does not stand it up.
--
-- THE SIBLING STATES THAT EXIST TODAY ALL WORK: MarketDynamics development
-- (since #153) and its feat/MD-16-material-sale-value branch both carry
-- src/md16/Md16Material.lua and Md16SaleComponents.lua. A sibling clone on a
-- commit from before #153 has no src/md16 and fails this file at load, which
-- is the honest answer: that MarketDynamics still pays the pooled premium.
--
-- ONE MORE CONSEQUENCE OF THE RELATIVE PATH: this file fails outright in any git
-- worktree that is not sited as a sibling of FS25_MarketDynamics, because the
-- path does not resolve. That is not a bug in the test; it is the same coupling
-- seen from a second direction.
-- =============================================================================
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, ../FS25_MarketDynamics/src/MarketEngine.lua, ../FS25_MarketDynamics/src/md16/Md16Material.lua, ../FS25_MarketDynamics/src/md16/Md16SaleComponents.lua, ../FS25_MarketDynamics/src/OrganicPremiumBridge.lua

-- ── engine-surface stubs ────────────────────────────────
MDMLog = { info = function() end, warn = function() end, debug = function() end }

g_SoilFertilityManager = { settings = {}, soilSystem = nil }
local organic = OrganicCertification.new(nil)
g_SoilFertilityManager.organic = organic

-- Strict market-wide reading: the modifier resolves the LOCAL/server farm via
-- g_currentMission:getFarmId() (the test controls it through `currentFarmId`).
g_MarketDynamics = {
    priceModifiers = {},
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

-- Strict market-wide reading: the modifier resolves the LOCAL/server farm via
-- g_currentMission:getFarmId(). Nil (dedicated server) -> opt out.
local currentFarmId = 0
g_currentMission.getFarmId = function() return currentFarmId end

currentFarmId = 0
T.eq("premium: no farm (dedicated server) opts out", fn({ fillTypeIndex = WHEAT }), nil)

currentFarmId = 2     -- farm 2 has no fraction
T.eq("premium: zero-fraction farm opts out", fn({ fillTypeIndex = WHEAT }), nil)

-- farm 3: a single certified harvest -> a full 1.0 organic share
setField(3, newField(C.STATE_CERTIFIED))
organic:recordHarvest(3, 3, WHEAT, 1000)
currentFarmId = 3
T.near("premium: full organic share pays the full multiplier",
    fn({ fillTypeIndex = WHEAT }), OrganicPremiumBridge.ORGANIC_PREMIUM.CERTIFIED)

-- farm 1 now has 2/3 organic wheat: multiplier = 1 + 0.20 * (2/3) ≈ 1.1333
currentFarmId = 1
local frac = organic:getFarmOrganicFraction(1, WHEAT)
T.near("premium: partial share pays a proportional multiplier", fn({ fillTypeIndex = WHEAT }), 1.0 + 0.20 * frac, 1e-9)

local sfAbsent = g_SoilFertilityManager.organic
g_SoilFertilityManager.organic = nil
T.eq("premium: SF absent opts out", fn({ fillTypeIndex = WHEAT }), nil)
g_SoilFertilityManager.organic = sfAbsent

-- ── the modifier moves the REAL engine's price, clamp B clips ──
-- MD-15 made MarketEngine:_recalculate server-side only: a pure client (g_server nil)
-- keeps the authoritative quote it received and never composes. This bench drives the
-- engine as the host, the same way MD's own MD-15 bench does (g_server = {}), so the
-- modifier product and clamp B actually run.
g_server = {}
local engine = MarketEngine.new()
engine.prices[WHEAT] = { base = 10, volatilityFactor = 1.0, modifiers = {}, current = 10, history = {} }
g_MarketDynamics.marketEngine = engine

-- THE ROW THAT MOVED. Before MD-16 an organic seller's market-wide quote was
-- 10 * (1 + 0.20 * frac) = 11.333 here. MD-16 retires the pooled premium at
-- the composition point, so the quote is the base, 10, for every seller. If
-- this goes back to 11.333, the md16 modules are off the load list or the
-- retirement no longer names the modifier the bridge registers; do not "fix"
-- it by restoring the premium value.
T.ok("premium: MD-16 retirement is loaded from the sibling MarketDynamics",
    Md16SaleComponents ~= nil and type(MarketEngine.getSaleQuoteComponents) == "function")
T.eq("premium: MD-16 retires exactly the modifier the bridge registers",
    Md16SaleComponents and Md16SaleComponents.RETIRED_MODIFIER, OrganicPremiumBridge.MODIFIER_NAME)
currentFarmId = 1    -- farm with a positive organic share
engine:_recalculate(WHEAT)
T.near("premium: recalculate leaves an organic seller's quote at the base (MD-16 retired the pooled premium)",
    engine:getPrice(WHEAT), 10, 1e-6)
T.near("premium: and the captured sale components exclude it too",
    engine:getSaleQuoteComponents(WHEAT) and engine:getSaleQuoteComponents(WHEAT).otherConsumerProduct, 1.0, 1e-9)
T.near("premium: while the bridge's own function still answers the premium when called",
    fn({ fillTypeIndex = WHEAT }), 1.0 + 0.20 * frac, 1e-9)

currentFarmId = 2    -- no organic share -> vanilla price
engine:_recalculate(WHEAT)
T.near("premium: recalculate leaves a conventional seller's price unchanged",
    engine:getPrice(WHEAT), 10, 1e-6)

-- clamp B: a modifier beyond the ruled band clips at 3.0
g_MarketDynamics.priceModifiers["TestClamp"] = function() return 4.0 end
engine.prices[WHEAT].current = 10
currentFarmId = 1
engine:_recalculate(WHEAT)
T.near("premium: clamp B clips the composition band at 3.0", engine:getPrice(WHEAT), 30, 1e-6)
g_MarketDynamics.priceModifiers["TestClamp"] = nil

-- pure-client witness: with no server, _recalculate keeps the received quote and the
-- organic modifier is never composed locally (the host's quote is authoritative).
g_server = nil
engine.prices[WHEAT].current = 12.5
currentFarmId = 1
engine:_recalculate(WHEAT)
T.near("premium: a pure client keeps the received quote (MD-15 guard)", engine:getPrice(WHEAT), 12.5, 1e-9)

-- registration lifecycle
OrganicPremiumBridge.unregister()
T.eq("premium: modifier unregistered", g_MarketDynamics.priceModifiers["OrganicPremium"], nil)

T.summary()
