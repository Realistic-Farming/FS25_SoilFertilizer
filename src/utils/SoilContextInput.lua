-- =========================================================
-- RSF-F201: context-qualified input registration (mod-private copy)
-- =========================================================
-- One participant's private copy of the F201 shape. It is not a shared registry
-- or dispatcher: every ecosystem mod that registers actions in both the PLAYER
-- and VEHICLE contexts carries its own copy under its own global name, and no
-- other mod reads or writes this one.
--
-- WHY. The engine keys an action event by action name, target object and
-- trigger shape only (InputEvent:makeId, InputEvent.lua:56-61). Registering the
-- same action with the same target in PLAYER and VEHICLE therefore produces one
-- identifier and one global slot, so whichever context is torn down first wipes
-- the other context's handle. The key still fires, but the handle the mod
-- holds is dead: no help-strip row, no label, no active/visible control.
--
-- WHAT THIS DOES (F201 items 2, 3, 5, 6, 7 and lifetime details 2, 4, 5, 6).
--   * Per-context private forwarding targets, so the two registrations never
--     share an identifier. A target forwards to the live owner's handler with
--     the engine's argument and return sequence untouched.
--   * Membership is asked of the wrap's own context by walking the native
--     lists (binding.contexts[name].actionEvents[action]) and matching action,
--     owned target, callback and the three trigger flags. A non-nil stored id
--     is never treated as presence. If a matching event exists but the stored
--     id was lost, the existing event.id is recovered rather than re-registered.
--   * Reconciliation is one batch per participant and context: no delta means
--     no begin/end at all; a nonempty delta is one bracket for that context.
--   * The captured predecessor is always called. The in-flight flag covers
--     only this participant's own injection.
--   * The wrapper record lives on the persistent home table the caller names
--     and is never restored per mission. Mission teardown retires the owner
--     and makes old targets inert; it does not unhook neighbours.
--   * A private per-update-interval attempt memo bounds registration attempts
--     without a timer. It is cleared at the top of the mod's update callback.
--
-- Trigger codes, for the record (InputEvent.lua:59-61): down=1, up=2, always=4.
-- =========================================================

SoilContextInput = SoilContextInput or {}

local M = SoilContextInput

--- Trigger flags compared directly. nil and false are the same shape, which is
--- how the engine normalises them before InputEvent.new.
local function triggerMatches(ev, up, down, always)
    return (ev.triggerUp == true) == (up == true)
        and (ev.triggerDown == true) == (down == true)
        and (ev.triggerAlways == true) == (always == true)
end

--- F201 item 3: find this participant's own event for an action in a NAMED
--- context. Every table on the path is guarded separately; any missing part is
--- "no match". The query creates nothing and calls no setter.
function M.findOwnedEvent(binding, contextName, actionName, target, callback, up, down, always)
    if binding == nil or contextName == nil or actionName == nil or target == nil then return nil end
    local contexts = binding.contexts
    if type(contexts) ~= "table" then return nil end
    local ctx = contexts[contextName]
    if type(ctx) ~= "table" then return nil end
    local nameActions = binding.nameActions
    if type(nameActions) ~= "table" then return nil end
    local action = nameActions[actionName]
    if action == nil then return nil end
    local lists = ctx.actionEvents
    if type(lists) ~= "table" then return nil end
    local list = lists[action]
    if type(list) ~= "table" then return nil end
    for i = 1, #list do
        local ev = list[i]
        if ev ~= nil and ev.actionName == actionName and ev.targetObject == target
            and ev.callback == callback and triggerMatches(ev, up, down, always) then
            return ev
        end
    end
    return nil
end

--- Returns the session-lived hook record kept on `home[key]`, creating it once.
--- `home` must be a table that survives mission teardown (a latched class or
--- module table), never a per-mission manager instance.
function M.record(home, key)
    local r = home[key]
    if r == nil then
        r = {
            installed      = false,  -- wrappers installed once per loaded script environment
            active         = false,  -- an owner is bound to the current mission
            owner          = nil,
            mission        = nil,
            playerOriginal = nil,    -- captured predecessors, never restored per mission
            vehicleOriginal = nil,
            inFlight       = false,  -- this participant's own injection is running
            targets        = {},     -- contextName -> forwarding target for the current owner
            memo           = {},     -- per-update-interval attempt admission
        }
        home[key] = r
    end
    return r
end

--- Builds one forwarding target for a context. The callbacks are created once
--- per target and resolve the handler on the live owner at call time, so a
--- retired target forwards to nobody and the engine's argument list passes
--- through untouched (InputEvent.lua:50).
local function newTarget(record, contextName, specs)
    local target = {
        __f201Context   = contextName,
        __f201Owner     = record.owner,
        __f201Live      = true,
        __f201Callbacks = {},
    }
    for _, spec in ipairs(specs) do
        local handlerName = spec.handler
        target.__f201Callbacks[spec.action] = function(_, ...)
            if not target.__f201Live then return end
            local owner = target.__f201Owner
            if owner == nil then return end
            local fn = owner[handlerName]
            if fn == nil then return end
            return fn(owner, ...)
        end
    end
    return target
end

--- Binds the current owner and mission and creates fresh forwarding targets.
--- Old targets are made inert first. Installs no wrapper.
function M.activate(record, owner, mission, specsByContext)
    -- Same owner, same mission: already bound. Re-minting targets here would
    -- orphan the live registrations and the engine would refuse the re-adds
    -- (same action and trigger already resident), which is item 10's silent
    -- failure. A stacked reload copy therefore adopts the binding instead.
    if record.active and record.owner == owner and record.mission == mission then return end
    -- Same mission, different owner: keep the live targets and re-point them.
    -- Minting new targets here would leave the old registrations resident and
    -- the engine would refuse every re-add on the action+trigger check.
    if record.active and record.mission == mission and next(record.targets) ~= nil then
        record.owner = owner
        for _, t in pairs(record.targets) do
            t.__f201Owner = owner
            t.__f201Live = true
        end
        record.memo = {}
        return
    end
    for _, old in pairs(record.targets) do
        old.__f201Live = false
        old.__f201Owner = nil
    end
    record.targets = {}
    record.owner   = owner
    record.mission = mission
    for contextName, specs in pairs(specsByContext) do
        record.targets[contextName] = newTarget(record, contextName, specs)
    end
    record.memo   = {}
    record.active = true
end

--- Mission retirement (F201 item 7, detail 5): mark inactive, make old targets
--- inert, release owner and mission references, clear admission. Does NOT
--- restore captured methods and opens no begin/end during teardown.
function M.retire(record)
    record.active = false
    for _, t in pairs(record.targets) do
        t.__f201Live = false
        t.__f201Owner = nil
    end
    record.targets = {}
    record.owner   = nil
    record.mission = nil
    record.memo    = {}
end

--- Detail 6: clear the private attempt memo. Call first thing in the mod's
--- existing update callback, before enabled/pause guards and recovery doors.
function M.resetAdmission(record)
    record.memo = {}
end

--- Detail 4: registration is allowed only for the bound owner of the current
--- client mission that is not exiting. Reads mission.isExitingGame, never sets it.
function M.canRegister(record)
    if not record.active or record.owner == nil then return false end
    local mission = g_currentMission
    if mission == nil or record.mission ~= mission then return false end
    if mission.isExitingGame then return false end
    if mission.getIsClient ~= nil and not mission:getIsClient() then return false end
    return true
end

--- Detail 3: local input ownership. A PLAYER callback carries its own owner in
--- inputComponent.player.isOwner; late recovery and VEHICLE paths need the live
--- local owning player. Ownership is never fabricated.
function M.hasLocalOwner(inputComponent)
    if inputComponent ~= nil then
        local p = inputComponent.player
        return p ~= nil and p.isOwner == true
    end
    local p = g_localPlayer
    return p ~= nil and p.isOwner == true
end

--- Detail 2: one batch per participant and context.
---
--- specs: array of
---   { action = "SF_TOGGLE_HUD",       -- InputAction key
---     handler = "onToggleHUDInput",   -- method name resolved on the owner at call time
---     idField = "toggleHUDEventId",   -- optional owner field that keeps the event id
---     present = function(owner) ... end,  -- optional; false = deliberately absent / obsolete
---     after   = function(binding, id, owner) ... end,  -- optional text/visibility/priority
---     up = false, down = true, always = false, startActive = true, callbackState = nil }
---
--- Returns added, removed. Throws only what the native calls throw, after the
--- matching close has been attempted and local protection released.
function M.reconcile(record, binding, contextName, specs)
    binding = binding or g_inputBinding
    if binding == nil or InputAction == nil or contextName == nil then return 0, 0 end
    if not M.canRegister(record) then return 0, 0 end
    if record.inFlight then return 0, 0 end
    local target = record.targets[contextName]
    if target == nil then return 0, 0 end
    local owner = record.owner

    local ctx = (type(binding.contexts) == "table") and binding.contexts[contextName] or nil
    local memoKey = ctx or contextName
    local memo = record.memo[memoKey]
    if memo == nil then
        memo = {}
        record.memo[memoKey] = memo
    end

    local missing, obsolete = {}, {}
    for _, spec in ipairs(specs) do
        local actionName = InputAction[spec.action]
        -- A missing InputAction is a deliberately absent action: no event, no warning (item 4).
        if actionName ~= nil then
            local callback = target.__f201Callbacks[spec.action]
            local up, down, always = spec.up == true, spec.down ~= false, spec.always == true
            local wanted = (spec.present == nil) or (spec.present(owner) == true)
            local ev = M.findOwnedEvent(binding, contextName, actionName, target, callback, up, down, always)
            if wanted then
                if ev ~= nil then
                    -- Present: retain the native event and recover its existing id (item 3).
                    if spec.idField ~= nil and owner[spec.idField] ~= ev.id then
                        owner[spec.idField] = ev.id
                    end
                elseif not memo[actionName] then
                    missing[#missing + 1] = { spec = spec, actionName = actionName, callback = callback,
                                              up = up, down = down, always = always }
                end
            elseif ev ~= nil then
                -- Obsolete owned event (ownership changed): remove only our own (item 4).
                obsolete[#obsolete + 1] = { spec = spec, ev = ev, actionName = actionName }
            end
        end
    end

    if #missing == 0 and #obsolete == 0 then
        return 0, 0  -- complete valid expected set: no transaction (item 5)
    end

    record.inFlight = true
    local opened = false
    local added, removed = 0, 0
    local ok, err = pcall(function()
        binding:beginActionEventsModification(contextName)
        opened = true
        -- The bracket may have created the context; key the memo by the live one.
        local liveCtx = (type(binding.contexts) == "table") and binding.contexts[contextName] or nil
        if liveCtx ~= nil and liveCtx ~= memoKey then
            record.memo[liveCtx] = memo
        end
        for _, item in ipairs(obsolete) do
            binding:removeActionEvent(item.ev.id)
            if item.spec.idField ~= nil and owner[item.spec.idField] == item.ev.id then
                owner[item.spec.idField] = nil
            end
            memo[item.actionName] = nil
            removed = removed + 1
        end
        for _, item in ipairs(missing) do
            -- Mark before the native call, whatever it returns or throws (detail 6).
            memo[item.actionName] = true
            local regOk, id = binding:registerActionEvent(
                item.actionName, target, item.callback,
                item.up, item.down, item.always,
                item.spec.startActive ~= false, item.spec.callbackState)
            if regOk and id ~= nil then
                if item.spec.idField ~= nil then owner[item.spec.idField] = id end
                if item.spec.after ~= nil then item.spec.after(binding, id, owner) end
                added = added + 1
            end
            -- A false return is unavailability: keep the mark, continue the batch.
        end
    end)
    -- Always attempt the matching close if we opened, then release local protection (item 6).
    local closeOk, closeErr = true, nil
    if opened then
        closeOk, closeErr = pcall(binding.endActionEventsModification, binding)
    end
    record.inFlight = false
    if not ok then error(err, 0) end
    if not closeOk then error(closeErr, 0) end
    return added, removed
end

--- Installs the PLAYER wrapper once per loaded script environment. The captured
--- predecessor is called unconditionally on every invocation; this
--- participant's injection runs only for the local owning player of the bound
--- mission and only when its own injection is not already in flight.
function M.installPlayerWrapper(record, playerSpecs)
    record.playerSpecs = playerSpecs
    if record.playerOriginal ~= nil then return true end
    if PlayerInputComponent == nil or PlayerInputComponent.registerActionEvents == nil then return false end
    record.playerOriginal = PlayerInputComponent.registerActionEvents
    PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
        record.playerOriginal(inputComponent, ...)
        if record.inFlight then return end
        if not M.hasLocalOwner(inputComponent) then return end
        if not M.canRegister(record) then return end
        M.reconcile(record, g_inputBinding, PlayerInputComponent.INPUT_CONTEXT_NAME, record.playerSpecs)
    end
    return true
end

--- Installs the VEHICLE-end wrapper once. Same predecessor and in-flight rules.
--- The context name is captured before the predecessor resets it. Membership is
--- then asked of the VEHICLE context by name, not of whatever is live.
function M.installVehicleWrapper(record, vehicleSpecs)
    record.vehicleSpecs = vehicleSpecs
    if record.vehicleOriginal ~= nil then return true end
    if InputBinding == nil or InputBinding.endActionEventsModification == nil then return false end
    record.vehicleOriginal = InputBinding.endActionEventsModification
    InputBinding.endActionEventsModification = function(binding, ignoreCheck)
        local contextName = ""
        if binding ~= nil and binding.registrationContext ~= nil
            and binding.registrationContext ~= InputBinding.NO_REGISTRATION_CONTEXT then
            contextName = binding.registrationContext.name or ""
        end
        record.vehicleOriginal(binding, ignoreCheck)
        if Vehicle == nil or contextName ~= Vehicle.INPUT_CONTEXT_NAME then return end
        if record.inFlight then return end
        if not M.hasLocalOwner(nil) then return end
        if not M.canRegister(record) then return end
        M.reconcile(record, binding, Vehicle.INPUT_CONTEXT_NAME, record.vehicleSpecs)
    end
    return true
end

--- Post-load catch-up (detail 6): one complete PLAYER reconciliation from an
--- existing post-load door, only if the local owning player and the native
--- PLAYER context already exist. Creates no context and no timer.
function M.catchUpPlayer(record, playerSpecs)
    local binding = g_inputBinding
    if binding == nil or PlayerInputComponent == nil then return 0, 0 end
    if not M.hasLocalOwner(nil) then return 0, 0 end
    local contexts = binding.contexts
    if type(contexts) ~= "table" or contexts[PlayerInputComponent.INPUT_CONTEXT_NAME] == nil then return 0, 0 end
    return M.reconcile(record, binding, PlayerInputComponent.INPUT_CONTEXT_NAME, playerSpecs)
end
