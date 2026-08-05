-- =========================================================
-- Realistic Farming Esc — shared module registry (NO HOST)
-- =========================================================
-- Law: Ash Office/NOTE-Wizard-Esc-NO-HOST-module-stack-LAW-2026-08-02.md
-- Published ONLY on g_currentMission.rfEscModules (+ env g_rfEscModules).
-- Never rfPdaHost / elected Soil owner.
-- =========================================================

RfEscModules = {}
local RfEscModules_mt = Class(RfEscModules)

local function _publish(reg)
    local env = getfenv(0)
    env.g_rfEscModules = reg
    if g_currentMission ~= nil then
        g_currentMission.rfEscModules = reg
        -- Kill peer-host / Soil-host handles (product law).
        g_currentMission.rfPdaHost = nil
    end
    env.g_rfPdaHost = nil
end

function RfEscModules.new()
    local self = setmetatable({}, RfEscModules_mt)
    self.modules = {}
    self.activeModuleId = nil
    self.listeners = {}
    return self
end

--- Ensure singleton registry (not a content host).
---@return table
function RfEscModules.getOrCreate()
    local env = getfenv(0)
    local reg = (g_currentMission and g_currentMission.rfEscModules) or env.g_rfEscModules
    if reg == nil then
        reg = RfEscModules.new()
    end
    _publish(reg)
    return reg
end

---@param listener fun()
function RfEscModules:addChangeListener(listener)
    if type(listener) == "function" then
        table.insert(self.listeners, listener)
    end
end

function RfEscModules:_notify()
    for _, fn in ipairs(self.listeners) do
        pcall(fn)
    end
end

--- Register or replace a module joiner.
---@param def table { id, title, order, icon?, blurb?, isAvailable, onShow, onHide?, onWageOptionChanged?, onWageReset? }
function RfEscModules:registerModule(def)
    if def == nil or def.id == nil or def.id == "" then
        return false
    end
    self.modules[def.id] = {
        id = def.id,
        title = def.title or def.id,
        blurb = def.blurb,
        order = tonumber(def.order) or 100,
        icon = def.icon,
        isAvailable = def.isAvailable or function() return true end,
        onShow = def.onShow,
        onHide = def.onHide,
        onWageOptionChanged = def.onWageOptionChanged,
        onWageReset = def.onWageReset,
    }
    if self.activeModuleId == nil then
        self.activeModuleId = def.id
    end
    self:_notify()
    return true
end

-- Compat alias during greenfield migrate (same table, not a host).
function RfEscModules:registerPanel(def)
    return self:registerModule(def)
end

---@param id string
function RfEscModules:unregisterModule(id)
    if id == nil then return end
    local wasActive = self.activeModuleId == id
    self.modules[id] = nil
    if wasActive then
        self.activeModuleId = nil
        local list = self:getModules()
        if list[1] ~= nil then
            self.activeModuleId = list[1].id
        end
    end
    self:_notify()
end

function RfEscModules:unregisterPanel(id)
    self:unregisterModule(id)
end

---@return table[]
function RfEscModules:getModules()
    local list = {}
    for _, def in pairs(self.modules) do
        local ok, available = pcall(def.isAvailable)
        if ok and available then
            table.insert(list, def)
        end
    end
    table.sort(list, function(a, b)
        if a.order == b.order then
            return tostring(a.id) < tostring(b.id)
        end
        return a.order < b.order
    end)
    return list
end

function RfEscModules:getPanels()
    return self:getModules()
end

---@param id string
function RfEscModules:selectModule(id)
    if id == nil or self.modules[id] == nil then
        return false
    end
    local ok, available = pcall(self.modules[id].isAvailable)
    if not (ok and available) then
        return false
    end
    self.activeModuleId = id
    self:_notify()
    return true
end

function RfEscModules:selectPanel(id)
    return self:selectModule(id)
end

---@return table|nil
function RfEscModules:getActiveModule()
    if self.activeModuleId == nil then
        return nil
    end
    return self.modules[self.activeModuleId]
end

function RfEscModules:getActivePanel()
    return self:getActiveModule()
end
