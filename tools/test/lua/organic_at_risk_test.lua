-- organic_at_risk_test.lua
-- OM-219: the AT-RISK classification (OrganicCertification:isFieldAtRisk) that
-- the sprayer/spreader hook's advisory HUD warning reads. This is the SAME
-- classification onInputApplied uses for the real breach (isApprovedInput +
-- getFieldOrganicState) - no new compliance rule, so these cases mirror what
-- would otherwise breach the field if the input were actually applied.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/OrganicCertification.lua

g_SoilFertilityManager = { settings = { difficulty = 2 } }
g_currentMission = { environment = { currentMonotonicDay = 10 } }

local function certWithField(state)
  local cert = setmetatable({}, { __index = OrganicCertification })
  cert.soilSystem = {
    fieldData = {
      [1] = { organic = { state = state, startDay = 0, certifiedDay = 0, breaches = 0 } },
    },
  }
  return cert
end

-- 1. Non-approved input on a TRANSITION field: at risk.
do
  local cert = certWithField(SoilConstants.ORGANIC.STATE_TRANSITION)
  T.ok("synthetic on transitioning field is at risk", cert:isFieldAtRisk(1, "UREA") == true)
end

-- 2. Non-approved input on a CERTIFIED field: at risk.
do
  local cert = certWithField(SoilConstants.ORGANIC.STATE_CERTIFIED)
  T.ok("synthetic on certified field is at risk", cert:isFieldAtRisk(1, "AZOXYSTROBIN") == true)
end

-- 3. Non-approved input on a CONVENTIONAL field: nothing to protect yet.
do
  local cert = certWithField(SoilConstants.ORGANIC.STATE_CONVENTIONAL)
  T.ok("synthetic on conventional field is NOT at risk", cert:isFieldAtRisk(1, "UREA") == false)
end

-- 4/5. Approved inputs are never at risk, on either protected state.
do
  local certT = certWithField(SoilConstants.ORGANIC.STATE_TRANSITION)
  T.ok("MANURE on transitioning field is NOT at risk", certT:isFieldAtRisk(1, "MANURE") == false)

  local certC = certWithField(SoilConstants.ORGANIC.STATE_CERTIFIED)
  T.ok("SULFUR on certified field is NOT at risk", certC:isFieldAtRisk(1, "SULFUR") == false)
  T.ok("COPPER_HYDROXIDE on certified field is NOT at risk", certC:isFieldAtRisk(1, "COPPER_HYDROXIDE") == false)
end

-- 6. Untracked field: no data, no crash, not at risk.
do
  local cert = certWithField(SoilConstants.ORGANIC.STATE_CERTIFIED)
  T.ok("unknown field id does not error and is NOT at risk", cert:isFieldAtRisk(999, "UREA") == false)
end

-- 7. No fill type name (isApprovedInput treats nil as approved): never at risk.
do
  local cert = certWithField(SoilConstants.ORGANIC.STATE_CERTIFIED)
  T.ok("nil fill type name is NOT at risk", cert:isFieldAtRisk(1, nil) == false)
end

-- 8. Classification matches onInputApplied's own breach decision exactly - the
-- AT-RISK check must never diverge from the real consequence it is warning about.
do
  local cert = certWithField(SoilConstants.ORGANIC.STATE_TRANSITION)
  local atRisk = cert:isFieldAtRisk(1, "MANCOZEB")
  local breached = cert:onInputApplied(1, "MANCOZEB")
  T.eq("AT-RISK agrees with the real breach outcome", atRisk, breached)
end

T.summary()
