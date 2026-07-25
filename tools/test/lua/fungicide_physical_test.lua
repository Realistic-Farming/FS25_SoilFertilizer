-- fungicide_physical_test.lua - registration completeness for the 8 physical fungicides
-- (the 6 synthetic + the SULFUR/COPPER_HYDROXIDE organic pair, OM-209).
-- This is the POLIFOSKA-incident guard: a custom fill type must be wired into EVERY table
-- the sprayer path touches, or it bugs silently (wrong drain rate, no effect, no BUY mode).
-- It must also stay OUT of FERTILIZER_PROFILES so the sprayer hook takes the direct,
-- chemId-aware path (catalog control math) instead of the flat fertilizer path.
--!load: src/utils/Logger.lua, src/config/Constants.lua

local C = SoilConstants

T.ok("PHYSICAL_FUNGICIDES set exists", type(C.PHYSICAL_FUNGICIDES) == "table")
T.ok("PHYSICAL_FUNGICIDE_ORDER exists", type(C.PHYSICAL_FUNGICIDE_ORDER) == "table")
T.eq("order has 8 entries", #C.PHYSICAL_FUNGICIDE_ORDER, 8)

local baseRates = C.SPRAYER_RATE.BASE_RATES
local ftList = {}
for _, n in ipairs(C.FERTILIZER_TYPES) do ftList[n] = true end

for _, id in ipairs(C.PHYSICAL_FUNGICIDE_ORDER) do
  T.ok(id .. ": in PHYSICAL_FUNGICIDES set", C.PHYSICAL_FUNGICIDES[id] == true)
  T.ok(id .. ": in FUNGICIDE_CATALOG (control math)", C.FUNGICIDE_CATALOG[id] ~= nil)
  T.ok(id .. ": in DISEASE_PRESSURE.FUNGICIDE_TYPES (sprayer routing)", C.DISEASE_PRESSURE.FUNGICIDE_TYPES[id] ~= nil)
  T.ok(id .. ": in BASE_RATES (drain rate)", baseRates[id] ~= nil)
  T.eq(id .. ": BASE_RATES unit is liquid", baseRates[id] and baseRates[id].unit, "liquid")
  T.ok(id .. ": in FERTILIZER_TYPES list", ftList[id] == true)
  -- The load-bearing invariant: NOT a fertilizer profile, or the sprayer hook would route
  -- it through onFertilizerApplied at flat 1.0 and the per-disease control math never runs.
  T.ok(id .. ": NOT in FERTILIZER_PROFILES (stays on direct path)", C.FERTILIZER_PROFILES[id] == nil)
end

-- Set and order must describe the same six chemicals.
local orderSet = {}
for _, id in ipairs(C.PHYSICAL_FUNGICIDE_ORDER) do orderSet[id] = true end
local setCount = 0
for id in pairs(C.PHYSICAL_FUNGICIDES) do
  setCount = setCount + 1
  T.ok(id .. ": set member also in order list", orderSet[id] == true)
end
T.eq("set and order have the same count", setCount, #C.PHYSICAL_FUNGICIDE_ORDER)

-- OM-209 organic legality: sulfur + copper are the ONLY approved-input fungicides, so a
-- synthetic fungicide spray breaches organic cert (onFungicideAppliedDirect -> onInputApplied)
-- while sulfur/copper pass clean.
local approved = C.ORGANIC.APPROVED_INPUTS
T.ok("SULFUR in ORGANIC.APPROVED_INPUTS", approved.SULFUR == true)
T.ok("COPPER_HYDROXIDE in ORGANIC.APPROVED_INPUTS", approved.COPPER_HYDROXIDE == true)
for _, id in ipairs({ "PROPICONAZOLE", "AZOXYSTROBIN", "BOSCALID", "MANCOZEB", "METALAXYL", "TEBUCONAZOLE" }) do
  T.ok(id .. ": synthetic, NOT organic-approved (breaches cert)", approved[id] ~= true)
end
