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
-- THIS TEST LOADS ANOTHER REPOSITORY'S WORKING TREE BY RELATIVE PATH. The two
-- ../FS25_MarketDynamics entries below are not pinned to a commit, a tag or a
-- branch. They read whatever that clone happens to be checked out on at the
-- moment the suite runs. Two people running this at the same time on the same
-- machine can get different meanings from the same assertions.
--
-- TODAY THE GREEN IS CORRECT. MarketDynamics main and development apply the
-- pooled OrganicPremium modifier, and so does the MD-16 branch while its md16
-- modules are not loaded: its MarketEngine resolves Md16SaleComponents to nil,
-- takes the "no retirement and no capture" path, and composes exactly as
-- development does. With the sibling clone on development or on the MD-16
-- branch, these assertions describe the behaviour that ships today.
--
-- WHAT THE GREEN CANNOT SEE. MD-16 (MarketDynamics PR #153, still a draft)
-- retires OrganicPremium by excluding it BY NAME inside MarketEngine's
-- composition loop, reading Md16SaleComponents.RETIRED_MODIFIER. The load list
-- below does not include the md16 modules, so this file never exercises that
-- retirement. It is blind to MD-16's retired state.
--
-- IT BECOMES A FALSE GREEN WHEN MD-16 MERGES. From then on modDesc loads the
-- md16 modules in the game and the premium is retired there, while this file,
-- still without them, keeps passing at the premium value.
--
-- THE TRIPWIRE IS ALREADY CORRECT. The "recalculate moves the price for an
-- organic seller" assertion expects 11.333. With the md16 modules on the load
-- list it fails at 10.0 (observed 2026-09-17 against MD-16 at 6851a19, and it is
-- the only assertion in this file that fails). It is not missing; it is
-- unreachable while md16 is absent from the load list.
--
-- IT CANNOT BE CLOSED FROM THIS SIDE YET. src/md16 does not exist on
-- MarketDynamics development, and a --!load of a missing file fails the whole
-- file, so adding the md16 modules today would break this suite for anyone whose
-- sibling clone is on development.
--
-- SO: WHEN MD-16 MERGES, UPDATE THIS FILE IN THE SAME CYCLE. Add
-- ../FS25_MarketDynamics/src/md16/Md16Material.lua and then
-- ../FS25_MarketDynamics/src/md16/Md16SaleComponents.lua (which depends on it)
-- to the load list after MarketEngine.lua, in the order modDesc loads them, and
-- move the "recalculate moves the price for an organic seller" expectation to
-- the base price. That is the only expectation that moves. The direct modifier
-- calls call the registered function itself, which a composition-point exclusion
-- does not touch, and the conventional-seller, clamp B and pure-client
-- assertions come out the same either way. Merging MD-16 without this update
-- leaves this file green and lying.
--
-- ONE MORE CONSEQUENCE OF THE RELATIVE PATH: this file fails outright in any git
-- worktree that is not sited as a sibling of FS25_MarketDynamics, because the
-- path does not resolve. That is not a bug in the test; it is the same coupling
-- seen from a second direction.
-- =============================================================================
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua, ../FS25_MarketDynamics/src/MarketEngine.lua, ../FS25_MarketDynamics/src/OrganicPremiumBridge.lua

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

-- THIS IS THE TRIPWIRE described in the header. It expects the premium to be
-- applied, which is correct for every shipped MarketDynamics today. Once the md16
-- modules are on the load list it fails with 10.0 against 11.333 (observed
-- against MD-16 at 6851a19). That is correct and is the signal to finish the
-- update. If you are reading this because it just went red, do not "fix" it by
-- keeping the premium value or by taking md16 back off the load list: under MD-16
-- the premium is retired and the expected value is the base, 10.
currentFarmId = 1    -- farm with a positive organic share
engine:_recalculate(WHEAT)
T.near("premium: recalculate moves the price for an organic seller",
    engine:getPrice(WHEAT), 10 * (1.0 + 0.20 * frac), 1e-6)

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
