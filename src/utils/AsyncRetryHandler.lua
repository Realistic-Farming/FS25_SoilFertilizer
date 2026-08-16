-- =========================================================
-- FS25 Realistic Soil & Fertilizer
-- =========================================================
-- Async Retry Handler - Exponential Backoff Pattern
-- =========================================================
-- Author: TisonK
-- =========================================================
---@class AsyncRetryHandler
-- Generic retry handler for async operations in FS25
-- Works in Lua 5.1, no coroutines needed

AsyncRetryHandler = {}
local AsyncRetryHandler_mt = Class(AsyncRetryHandler)

--- Create new retry handler for async operations
---@param config table Configuration with maxAttempts, delays, onAttempt, onSuccess, onFailure, condition, name
---@return AsyncRetryHandler
function AsyncRetryHandler.new(config)
    local self = setmetatable({}, AsyncRetryHandler_mt)

    -- Configuration
    self.maxAttempts = config.maxAttempts or 3
    self.delays = config.delays or {2000, 4000, 8000}  -- ms - exponential backoff
    self.onAttempt = config.onAttempt or function() end
    self.onSuccess = config.onSuccess or function() end
    self.onFailure = config.onFailure or function() end
    self.condition = config.condition or function() return false end
    -- BUILD 17:59: optional gate. When it returns false the operation is not ready to be
    -- tried at all, which is different from trying and failing: no attempt is spent and the
    -- handler stays pending. Defaults to always-open so existing callers are unchanged.
    self.canAttempt = config.canAttempt or function() return true end
    self.name = config.name or "AsyncOperation"

    -- State
    self.state = "idle"  -- idle, pending, success, failed
    self.attempts = 0
    self.lastAttemptTime = 0
    self.started = false

    return self
end

--- Start retry sequence
--- Begins attempting the operation with exponential backoff
---@return boolean True if started, false if already running
function AsyncRetryHandler:start()
    if self.state == "pending" then
        SoilLogger.debug("[%s] Already running", self.name)
        return false
    end

    self.state = "pending"
    self.attempts = 0
    self.started = true
    self:attempt()
    return true
end

-- Perform single attempt
function AsyncRetryHandler:attempt()
    if self.state ~= "pending" then return end

    -- BUILD 17:59: checked BEFORE the counter moves. A send that the engine will drop is not
    -- an attempt that failed, it is an attempt that never happened, and counting it is how
    -- the Judith join spent its whole budget before the event ids had even arrived.
    local gateOk, gateOpen = pcall(self.canAttempt)
    if not gateOk or not gateOpen then return end

    self.attempts = self.attempts + 1
    self.lastAttemptTime = g_currentMission and g_currentMission.time or 0

    SoilLogger.debug("[%s] Attempt %d/%d", self.name, self.attempts, self.maxAttempts)

    -- Execute attempt callback
    local success, result = pcall(self.onAttempt)
    if not success then
        SoilLogger.warning("[%s] Attempt %d failed: %s",
            self.name, self.attempts, tostring(result))
    end
end

-- Check if condition met (call from update loop)
function AsyncRetryHandler:checkCondition()
    if self.state ~= "pending" then return end

    local conditionMet = self.condition()
    if conditionMet then
        self:markSuccess()
    end
end

--- Mark operation as successful
--- Stops retry attempts and calls onSuccess callback
function AsyncRetryHandler:markSuccess()
    if self.state ~= "pending" then return end

    self.state = "success"
    self.started = false

    SoilLogger.info("[%s] Operation succeeded after %d attempts", self.name, self.attempts)

    local success, result = pcall(self.onSuccess)
    if not success then
        SoilLogger.warning("[%s] Success callback failed: %s",
            self.name, tostring(result))
    end
end

--- Update loop - call from main update loop
---@param dt number Delta time in milliseconds
function AsyncRetryHandler:update(dt)
    if self.state ~= "pending" then return end

    -- Check if condition already met
    self:checkCondition()
    if self.state ~= "pending" then return end

    -- BUILD 18:16 (Vera F1). Before the first successful attempt there is no delay window to
    -- compute at all: attempts is 0, delays is 1-based, so delays[0] is nil and `elapsed >= nil`
    -- throws in Lua 5.1. That killed this update loop on the very tick it was meant to be
    -- polling, so the first legal send after EVENT_IDS never happened. My defect from 17:59:
    -- gating attempt() broke the old invariant that attempts was always >= 1 by the time
    -- update() ran, and the delay maths still assumed it.
    --
    -- The zero-attempt case therefore gets its own branch, before any delay is looked up.
    -- Poll the gate every tick; attempt() still checks it before touching the counter, so a
    -- shut gate stays silent and free, and the tick it opens is attempt 1.
    if self.attempts == 0 then
        self:attempt()
        return
    end

    -- Calculate elapsed time
    local currentTime = g_currentMission and g_currentMission.time or 0
    local elapsed = currentTime - self.lastAttemptTime

    -- Get delay for current attempt. Clamped to 1 at the bottom as well as to #delays at the
    -- top: this table is 1-based and index 0 must never be read.
    local delayIndex = math.max(1, math.min(self.attempts, #self.delays))
    local retryDelay = self.delays[delayIndex] or 0

    -- Check for timeout
    if elapsed >= retryDelay then
        -- Hold quietly while the gate is shut. Checked before the "attempting again" log so a
        -- closed gate costs nothing and says nothing.
        local gateOk, gateOpen = pcall(self.canAttempt)
        if not gateOk or not gateOpen then return end

        if self.attempts < self.maxAttempts then
            SoilLogger.debug("[%s] Retry timeout, attempting again (%d/%d)",
                self.name, self.attempts + 1, self.maxAttempts)
            self:attempt()
        else
            -- Max attempts reached
            self.state = "failed"
            self.started = false

            SoilLogger.warning("[%s] Operation failed after %d attempts",
                self.name, self.maxAttempts)

            local success, result = pcall(self.onFailure)
            if not success then
                SoilLogger.warning("[%s] Failure callback error: %s",
                    self.name, tostring(result))
            end
        end
    end
end

-- Reset handler
function AsyncRetryHandler:reset()
    self.state = "idle"
    self.attempts = 0
    self.lastAttemptTime = 0
    self.started = false
    SoilLogger.debug("[%s] Reset", self.name)
end

-- Check if running
function AsyncRetryHandler:isPending()
    return self.state == "pending"
end

function AsyncRetryHandler:isComplete()
    return self.state == "success" or self.state == "failed"
end

function AsyncRetryHandler:getState()
    return self.state
end

function AsyncRetryHandler:getAttempts()
    return self.attempts
end
