-- =========================================================
-- OrganicCertification.lua
-- =========================================================
-- Per-field organic certification as a thin state layer over the existing
-- soil substrate (OM, N/P/K, the input hooks). A field moves:
--
--   conventional  --(player opts in)-->  in_transition  --(enough days)-->  certified
--
-- Rules (design locked 2026-07-03):
--   - Entry is EXPLICIT OPT-IN only. Fields never auto-transition.
--   - Transition length is difficulty-scaled in in-game days (SoilConstants.ORGANIC.TRANSITION_DAYS).
--   - Applying any synthetic (non-approved) input to a transitioning OR certified
--     field is a breach: FULL RESET to conventional.
--
-- State lives on soilSystem.fieldData[fieldId].organic and is saved/loaded with
-- the rest of the per-field record. This module owns the LOGIC only.
--
-- SF owns this core; market premium / organic livestock / FarmTablet display are
-- downstream consumers in their own repos and only READ getFieldOrganicState().
-- =========================================================

OrganicCertification = {}
local OrganicCertification_mt = Class(OrganicCertification)

--- Constructor
-- @param soilSystem  SoilFertilitySystem (owns fieldData)
function OrganicCertification.new(soilSystem)
    local self = setmetatable({}, OrganicCertification_mt)
    self.soilSystem = soilSystem
    self.lastProcessedDay = nil
    return self
end

-- ---------------------------------------------------------
-- Wire encoding (network serialization)
-- ---------------------------------------------------------
-- The model stores state as a string; the network path (the NetworkSync bridge
-- scalars + every field event stream) carries a compact int enum so both sides
-- agree byte-for-byte. 0 conventional, 1 in_transition, 2 certified.
OrganicCertification.STATE_TO_INT = {
    [SoilConstants.ORGANIC.STATE_CONVENTIONAL] = 0,
    [SoilConstants.ORGANIC.STATE_TRANSITION]   = 1,
    [SoilConstants.ORGANIC.STATE_CERTIFIED]    = 2,
}
OrganicCertification.INT_TO_STATE = {
    [0] = SoilConstants.ORGANIC.STATE_CONVENTIONAL,
    [1] = SoilConstants.ORGANIC.STATE_TRANSITION,
    [2] = SoilConstants.ORGANIC.STATE_CERTIFIED,
}

--- Encode a string organic state to its wire int (defaults to 0 conventional).
function OrganicCertification.encodeState(state)
    return OrganicCertification.STATE_TO_INT[state] or 0
end

--- Decode a wire int back to the string organic state (defaults to conventional).
function OrganicCertification.decodeState(intVal)
    return OrganicCertification.INT_TO_STATE[intVal] or SoilConstants.ORGANIC.STATE_CONVENTIONAL
end

--- Read a field's organic state as a serializable tuple, defaulting a stateless
--- field to conventional/zeros. Returns stateInt, startDay, certifiedDay, breaches.
function OrganicCertification.encodeFieldOrganic(field)
    local o = field and field.organic
    if not o then return 0, 0, 0, 0 end
    return OrganicCertification.encodeState(o.state), o.startDay or 0, o.certifiedDay or 0, o.breaches or 0
end

--- Apply a decoded organic tuple onto a field table (server-authoritative sync).
--- Mirrors loadFieldState: a plain conventional field with no breaches keeps no
--- sub-table, so the wire never resurrects one where the model would not.
function OrganicCertification.applyFieldOrganic(field, stateInt, startDay, certifiedDay, breaches)
    if not field then return end
    local state = OrganicCertification.decodeState(stateInt)
    breaches = breaches or 0
    if state == SoilConstants.ORGANIC.STATE_CONVENTIONAL and breaches == 0 then
        field.organic = nil
        return
    end
    field.organic = {
        state        = state,
        startDay     = startDay or 0,
        certifiedDay = certifiedDay or 0,
        breaches     = breaches,
    }
end

-- ---------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------

--- Ensure a field record has an organic sub-table, defaulting to conventional.
-- @param field  fieldData entry
function OrganicCertification:ensureState(field)
    if not field then return end
    if not field.organic then
        field.organic = {
            state       = SoilConstants.ORGANIC.STATE_CONVENTIONAL,
            startDay    = 0,   -- monotonic day the transition began
            certifiedDay = 0,  -- monotonic day certification was reached
            breaches    = 0,   -- lifetime count of synthetic-input breaches
        }
    end
    return field.organic
end

--- Current monotonic in-game day (safe). Monotonic so day arithmetic is valid.
function OrganicCertification:getCurrentDay()
    if g_currentMission and g_currentMission.environment then
        return g_currentMission.environment.currentMonotonicDay
            or g_currentMission.environment.currentDay or 0
    end
    return 0
end

--- Active difficulty (1 Simple / 2 Realistic / 3 Hardcore), defaulting to 2.
function OrganicCertification:getDifficulty()
    local d
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        d = g_SoilFertilityManager.settings.difficulty
    end
    if type(d) ~= "number" or d < 1 or d > 3 then d = 2 end
    return d
end

--- In-game days required to complete the transition at the current difficulty.
function OrganicCertification:getTransitionDays()
    local list = SoilConstants.ORGANIC.TRANSITION_DAYS
    return list[self:getDifficulty()] or list[2] or 120
end

--- Is a fill type name allowed under organic rules?
-- @param fillTypeName  upper-case fill type name (e.g. "MANURE", "UREA")
-- @return boolean
function OrganicCertification:isApprovedInput(fillTypeName)
    if not fillTypeName then return true end
    return SoilConstants.ORGANIC.APPROVED_INPUTS[fillTypeName] == true
end

-- ---------------------------------------------------------
-- Read API (consumed by market / livestock / tablet, other repos)
-- ---------------------------------------------------------

--- Snapshot of a field's organic status.
-- @param fieldId  field id
-- @return table|nil  { state, daysAccrued, transitionDaysNeeded, certified, breaches }
function OrganicCertification:getFieldOrganicState(fieldId)
    local field = self.soilSystem and self.soilSystem.fieldData and self.soilSystem.fieldData[fieldId]
    if not field then return nil end
    self:ensureState(field)
    local o = field.organic
    local needed = self:getTransitionDays()
    local accrued = 0
    if o.state == SoilConstants.ORGANIC.STATE_TRANSITION then
        accrued = math.max(0, self:getCurrentDay() - (o.startDay or 0))
    end
    return {
        state = o.state,
        daysAccrued = accrued,
        transitionDaysNeeded = needed,
        certified = (o.state == SoilConstants.ORGANIC.STATE_CERTIFIED),
        breaches = o.breaches or 0,
    }
end

-- ---------------------------------------------------------
-- Transitions
-- ---------------------------------------------------------

--- Propagate an organic-state change everywhere it needs to show.
-- (1) Repaint the field's organicStatus map layer (singleplayer + server; the
-- value-map join sync carries the pixels to clients). (2) In multiplayer, broadcast
-- the field so every peer's cert state converges. Cert changes happen outside the
-- sprayer's throttled broadcast (a breach, a daily promotion, or an opt in/out), so
-- we push the field explicitly - including sold / inactive fields the daily pass
-- would skip. Organic rides in every field payload, so one broadcast carries it.
function OrganicCertification:applyStateChange(fieldId)
    if self.soilSystem and self.soilSystem.paintOrganicStatus then
        self.soilSystem:paintOrganicStatus(fieldId)
    end
    if g_server == nil then return end
    local mdi = g_currentMission and g_currentMission.missionDynamicInfo
    if not (mdi and mdi.isMultiplayer) then return end
    local field = self.soilSystem and self.soilSystem.fieldData and self.soilSystem.fieldData[fieldId]
    if field and SoilNetworkEvents_BroadcastFieldUpdate then
        SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
    end
end

--- Route an opt-in through the single-writer discipline (server-authoritative).
-- On a pure client this sends a request the server validates and applies; on the
-- server or in singleplayer it applies directly. Callers (console, UI) use this,
-- never optIn/optOut, so a client never mutates cert state locally.
function OrganicCertification:requestOptIn(fieldId)
    return self:_requestOpt(fieldId, true)
end

--- Route an opt-out through the single-writer discipline. See requestOptIn.
function OrganicCertification:requestOptOut(fieldId)
    return self:_requestOpt(fieldId, false)
end

function OrganicCertification:_requestOpt(fieldId, doOptIn)
    if fieldId == nil then return false, "No field selected" end
    -- Pure client: ask the server. It validates, applies, and broadcasts back, so
    -- the local state converges on the next field update rather than being set here.
    if g_server == nil and g_client ~= nil then
        if SoilOrganicOptEvent ~= nil then
            g_client:getServerConnection():sendEvent(SoilOrganicOptEvent.new(fieldId, doOptIn))
            return true, string.format("Requested organic %s for field %d; the server will apply it.",
                doOptIn and "transition" or "opt-out", fieldId)
        end
        return false, "Organic change unavailable (network not ready)"
    end
    -- Server or singleplayer: apply directly (optIn/optOut self-broadcast on success).
    if doOptIn then return self:optIn(fieldId) else return self:optOut(fieldId) end
end

--- Opt a field into the organic transition (conventional -> in_transition).
-- @param fieldId  field id
-- @return boolean success, string message
function OrganicCertification:optIn(fieldId)
    -- Server-authoritative floor: a pure client must never mutate cert state
    -- locally (it desyncs the lobby). Callers route through requestOptIn.
    if g_server == nil and g_client ~= nil then
        return false, "Organic changes are server-authoritative"
    end
    local field = self.soilSystem and self.soilSystem.fieldData and self.soilSystem.fieldData[fieldId]
    if not field then return false, string.format("Field %s is not tracked yet", tostring(fieldId)) end
    local o = self:ensureState(field)

    if o.state == SoilConstants.ORGANIC.STATE_CERTIFIED then
        return false, string.format("Field %d is already certified organic", fieldId)
    end
    if o.state == SoilConstants.ORGANIC.STATE_TRANSITION then
        return false, string.format("Field %d is already in transition", fieldId)
    end

    o.state = SoilConstants.ORGANIC.STATE_TRANSITION
    o.startDay = self:getCurrentDay()
    o.certifiedDay = 0
    self:applyStateChange(fieldId)
    return true, string.format("Field %d entered organic transition (%d days at current difficulty). Use only approved inputs.",
        fieldId, self:getTransitionDays())
end

--- Opt a field back out to conventional (loses transition/certification).
-- @param fieldId  field id
-- @return boolean success, string message
function OrganicCertification:optOut(fieldId)
    -- Server-authoritative floor (see optIn).
    if g_server == nil and g_client ~= nil then
        return false, "Organic changes are server-authoritative"
    end
    local field = self.soilSystem and self.soilSystem.fieldData and self.soilSystem.fieldData[fieldId]
    if not field then return false, string.format("Field %s is not tracked yet", tostring(fieldId)) end
    local o = self:ensureState(field)

    if o.state == SoilConstants.ORGANIC.STATE_CONVENTIONAL then
        return false, string.format("Field %d is already conventional", fieldId)
    end
    o.state = SoilConstants.ORGANIC.STATE_CONVENTIONAL
    o.startDay = 0
    o.certifiedDay = 0
    self:applyStateChange(fieldId)
    return true, string.format("Field %d reverted to conventional", fieldId)
end

--- Compliance check on every input application. Called from onFertilizerApplied.
-- A synthetic (non-approved) input on a transitioning or certified field is a
-- breach and resets the field to conventional.
-- @param fieldId       field id
-- @param fillTypeName  upper-case fill type name of the applied input
-- @return boolean breached
function OrganicCertification:onInputApplied(fieldId, fillTypeName)
    local field = self.soilSystem and self.soilSystem.fieldData and self.soilSystem.fieldData[fieldId]
    if not field or not field.organic then return false end
    local o = field.organic

    if o.state == SoilConstants.ORGANIC.STATE_CONVENTIONAL then
        return false  -- nothing to protect
    end
    if self:isApprovedInput(fillTypeName) then
        return false  -- allowed, no breach
    end

    -- Synthetic input on a protected field: full reset.
    o.breaches = (o.breaches or 0) + 1
    o.state = SoilConstants.ORGANIC.STATE_CONVENTIONAL
    o.startDay = 0
    o.certifiedDay = 0

    if SoilLogger then
        SoilLogger.info("Organic: field %d reset to conventional (synthetic input '%s' applied)",
            fieldId, tostring(fillTypeName))
    end
    self:notify(string.format("Field %d lost organic status: %s is not approved",
        fieldId, tostring(fillTypeName)))
    self:applyStateChange(fieldId)
    return true
end

--- Daily tick: promote transitioning fields that have served their time.
-- Uses the monotonic day for arithmetic (the caller only needs to trigger it
-- once per day-change; the actual day math must be monotonic).
function OrganicCertification:onDayChanged()
    local currentDay = self:getCurrentDay()
    if self.lastProcessedDay == currentDay then return end
    self.lastProcessedDay = currentDay

    local fieldData = self.soilSystem and self.soilSystem.fieldData
    if not fieldData then return end

    local needed = self:getTransitionDays()
    for fieldId, field in pairs(fieldData) do
        if type(field) == "table" and field.organic
            and field.organic.state == SoilConstants.ORGANIC.STATE_TRANSITION then
            local accrued = currentDay - (field.organic.startDay or currentDay)
            if accrued >= needed then
                field.organic.state = SoilConstants.ORGANIC.STATE_CERTIFIED
                field.organic.certifiedDay = currentDay
                if SoilLogger then
                    SoilLogger.info("Organic: field %d is now CERTIFIED organic", fieldId)
                end
                self:notify(string.format("Field %d is now certified organic!", fieldId))
                -- Broadcast this field itself; the daily pass covers only the active
                -- set, so a sold or inactive mid-transition field would otherwise
                -- promote on the host and stay stale on every client.
                self:applyStateChange(fieldId)
            end
        end
    end
end

--- Fire an in-game notification if the mission HUD is available.
function OrganicCertification:notify(text)
    if g_currentMission and g_currentMission.hud and g_currentMission.hud.showBlinkingWarning then
        pcall(function() g_currentMission.hud:showBlinkingWarning("[Organic] " .. text, 4000) end)
    end
end

-- ---------------------------------------------------------
-- Save / load (called from SoilFertilitySystem field loop)
-- ---------------------------------------------------------

function OrganicCertification:saveFieldState(xmlFile, fieldKey, field)
    if not field or not field.organic then return end
    local o = field.organic
    setXMLString(xmlFile, fieldKey .. "#organicState", o.state or SoilConstants.ORGANIC.STATE_CONVENTIONAL)
    setXMLInt(xmlFile, fieldKey .. "#organicStartDay", o.startDay or 0)
    setXMLInt(xmlFile, fieldKey .. "#organicCertifiedDay", o.certifiedDay or 0)
    setXMLInt(xmlFile, fieldKey .. "#organicBreaches", o.breaches or 0)
end

function OrganicCertification:loadFieldState(xmlFile, fieldKey, field)
    if not field then return end
    local state = getXMLString(xmlFile, fieldKey .. "#organicState")
    if state == nil or state == "" then return end  -- default conventional, no sub-table needed
    field.organic = {
        state        = state,
        startDay     = getXMLInt(xmlFile, fieldKey .. "#organicStartDay") or 0,
        certifiedDay = getXMLInt(xmlFile, fieldKey .. "#organicCertifiedDay") or 0,
        breaches     = getXMLInt(xmlFile, fieldKey .. "#organicBreaches") or 0,
    }
end

-- ---------------------------------------------------------
-- Console commands
-- ---------------------------------------------------------

--- Resolve a field id from a console arg, falling back to the HUD's current field.
function OrganicCertification:resolveFieldId(arg)
    local id = tonumber(arg)
    if id then return id end
    if g_SoilFertilityManager and g_SoilFertilityManager.soilHUD then
        return g_SoilFertilityManager.soilHUD.cachedFieldId
    end
    return nil
end

function OrganicCertification:registerConsoleCommands()
    addConsoleCommand("SoilOrganicStatus", "Show a field's organic certification status", "consoleOrganicStatus", self)
    addConsoleCommand("SoilOrganicOptIn", "Start organic transition on a field", "consoleOrganicOptIn", self)
    addConsoleCommand("SoilOrganicOptOut", "Revert a field to conventional", "consoleOrganicOptOut", self)
end

function OrganicCertification:consoleOrganicStatus(arg)
    local fieldId = self:resolveFieldId(arg)
    if not fieldId then return "Usage: SoilOrganicStatus <fieldId> (or stand on a field)" end
    local s = self:getFieldOrganicState(fieldId)
    if not s then return string.format("Field %d is not tracked", fieldId) end
    if s.state == SoilConstants.ORGANIC.STATE_TRANSITION then
        return string.format("Field %d: IN TRANSITION - %d / %d days (breaches: %d)",
            fieldId, s.daysAccrued, s.transitionDaysNeeded, s.breaches)
    elseif s.state == SoilConstants.ORGANIC.STATE_CERTIFIED then
        return string.format("Field %d: CERTIFIED ORGANIC (breaches: %d)", fieldId, s.breaches)
    end
    return string.format("Field %d: conventional (breaches: %d)", fieldId, s.breaches)
end

function OrganicCertification:consoleOrganicOptIn(arg)
    local fieldId = self:resolveFieldId(arg)
    if not fieldId then return "Usage: SoilOrganicOptIn <fieldId> (or stand on a field)" end
    local _, msg = self:requestOptIn(fieldId)
    return msg
end

function OrganicCertification:consoleOrganicOptOut(arg)
    local fieldId = self:resolveFieldId(arg)
    if not fieldId then return "Usage: SoilOrganicOptOut <fieldId> (or stand on a field)" end
    local _, msg = self:requestOptOut(fieldId)
    return msg
end
