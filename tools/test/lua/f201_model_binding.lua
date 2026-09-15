-- RSF-F201 test fixture: a MODELED InputBinding for the per-mod F201 tests.
-- Not a reconstruction of the native class. It models only the facts the F201
-- design binds to by symbol: one registration slot (begin sets it, end resets
-- it), per-context action lists keyed by the action object, a global event
-- table keyed by makeId (action|target|triggerCode with down=1 up=2 always=4,
-- InputEvent.lua:56-61), and the duplicate refusal on action + trigger code
-- regardless of target (InputBinding.lua:629-633). removeActionEvent walks the
-- registration context when one is open and every context otherwise.
-- Loaded through --!load: before the production files; the test file then sets
-- InputBinding / g_inputBinding / PlayerInputComponent / Vehicle / InputAction.

F201Model = F201Model or {}

local function triggerCode(up, down, always)
    return (down and 1 or 0) + (up and 2 or 0) + (always and 4 or 0)
end

function F201Model.newBinding()
    local b = {
        contexts = {}, nameActions = {}, events = {},
        attempts = 0, created = 0, begun = 0, ended = 0, refused = 0,
        NO_REGISTRATION_CONTEXT = { name = "" },
        throwOnRegister = false, refuseAll = false,
    }
    b.registrationContext = b.NO_REGISTRATION_CONTEXT
    function b:context(name)
        if self.contexts[name] == nil then
            self.contexts[name] = { name = name, actionEvents = {}, eventOrderCounter = 1 }
        end
        return self.contexts[name]
    end
    function b:beginActionEventsModification(name)
        assert(name ~= nil and name ~= "", "model: begin needs a context name")
        self.begun = self.begun + 1
        self.registrationContext = self:context(name)
    end
    function b:endActionEventsModification()
        self.ended = self.ended + 1
        self.registrationContext = self.NO_REGISTRATION_CONTEXT
    end
    function b:registerActionEvent(actionName, target, callback, up, down, always, startActive, callbackState)
        self.attempts = self.attempts + 1
        if self.throwOnRegister then error("synthetic registration failure", 0) end
        if self.refuseAll then self.refused = self.refused + 1; return false, nil end
        local ctx = self.registrationContext
        assert(ctx ~= self.NO_REGISTRATION_CONTEXT, "model: registerActionEvent needs an open registration context")
        self.nameActions[actionName] = self.nameActions[actionName] or { name = actionName }
        local action = self.nameActions[actionName]
        ctx.actionEvents[action] = ctx.actionEvents[action] or {}
        local list = ctx.actionEvents[action]
        local code = triggerCode(up, down, always)
        for _, ev in ipairs(list) do
            if ev.actionName == actionName and triggerCode(ev.triggerUp, ev.triggerDown, ev.triggerAlways) == code then
                self.refused = self.refused + 1
                return false, nil
            end
        end
        local ev = {
            id = string.format("%s|%s|%d", tostring(actionName), tostring(target), code),
            actionName = actionName, targetObject = target, callback = callback,
            triggerUp = up == true, triggerDown = down == true, triggerAlways = always == true,
            isActive = startActive == true, callbackState = callbackState,
            displayIsVisible = nil, text = nil, priority = nil,
        }
        list[#list + 1] = ev
        self.events[ev.id] = ev
        self.created = self.created + 1
        return true, ev.id
    end
    function b:setActionEventTextVisibility(id, v) if self.events[id] then self.events[id].displayIsVisible = v end end
    function b:setActionEventActive(id, v) if self.events[id] then self.events[id].isActive = v end end
    function b:setActionEventText(id, t) if self.events[id] then self.events[id].text = t end end
    function b:setActionEventTextPriority(id, p) if self.events[id] then self.events[id].priority = p end end
    function b:setActionEventIcon(id, _i) end
    function b:getActionEventsHasBinding(id) return self.events[id] ~= nil end
    local function removeFrom(self, ctx, id)
        for _, list in pairs(ctx.actionEvents) do
            for i = #list, 1, -1 do
                if list[i].id == id then
                    self.events[id] = nil
                    table.remove(list, i)
                    return true
                end
            end
        end
        return false
    end
    function b:removeActionEvent(id)
        if self.registrationContext ~= self.NO_REGISTRATION_CONTEXT then
            removeFrom(self, self.registrationContext, id)
            return
        end
        for _, ctx in pairs(self.contexts) do
            if removeFrom(self, ctx, id) then return end
        end
    end
    function b:deleteContext(name)
        local ctx = self.contexts[name]
        if ctx ~= nil then
            for _, list in pairs(ctx.actionEvents) do
                for _, ev in ipairs(list) do self.events[ev.id] = nil end
            end
        end
        self.contexts[name] = nil
    end
    --- Test helpers, not engine API.
    function b:list(contextName, actionName)
        local ctx = self.contexts[contextName]
        local action = self.nameActions[actionName]
        if ctx == nil or action == nil then return {} end
        return ctx.actionEvents[action] or {}
    end
    function b:count(contextName, actionName) return #self:list(contextName, actionName) end
    function b:first(contextName, actionName) return self:list(contextName, actionName)[1] end
    function b:totalIn(contextName)
        local ctx = self.contexts[contextName]
        if ctx == nil then return 0 end
        local n = 0
        for _, list in pairs(ctx.actionEvents) do n = n + #list end
        return n
    end
    return b
end

--- Installs the engine-side globals the wrappers need and returns the binding.
function F201Model.installEngine(actionNames)
    local b = F201Model.newBinding()
    InputBinding, g_inputBinding = b, b
    Vehicle = Vehicle or {}
    Vehicle.INPUT_CONTEXT_NAME = "VEHICLE"
    PlayerInputComponent = PlayerInputComponent or {}
    PlayerInputComponent.INPUT_CONTEXT_NAME = "PLAYER"
    if PlayerInputComponent.registerActionEvents == nil then
        PlayerInputComponent.registerActionEvents = function() end
    end
    InputAction = InputAction or {}
    for _, n in ipairs(actionNames or {}) do InputAction[n] = n end
    g_localPlayer = { isOwner = true }
    return b
end
