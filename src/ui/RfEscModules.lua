-- =========================================================
-- Realistic Farming Esc — shared module registry (NO HOST)
-- =========================================================
-- Law: Ash Office/NOTE-Wizard-Esc-NO-HOST-module-stack-LAW-2026-08-02.md
-- Published ONLY on g_currentMission.rfEscModules (+ env g_rfEscModules).
-- Never rfPdaHost / elected Soil owner.
-- Module home (2026-08-09): cold → soilFertilizer; session last-closed;
-- optional SettingsHub escLastModuleId (enum soft-detect). First-register
-- lottery is NOT the product default.
-- =========================================================

RfEscModules = {}
local RfEscModules_mt = Class(RfEscModules)

local HUB_MOD_ID = "RfEsc"
local HUB_KEY = "escLastModuleId"
-- SettingsHub validates enum only (no freeform string). Keep in sync with joiners.
local HUB_ENUM = {
    "soilFertilizer",
    "workerCosts",
    "seasonalCropStress",
    "marketDynamics",
    "income",
    "tax",
    "dairy",
    "npcFavor",
    "fertilizerDepot",
}

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
    self._lastClosedModuleId = nil
    self._userHasChosenModule = false
    self._settingsHubBound = false
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

---@param id string|nil
---@return boolean
function RfEscModules:_moduleAvailable(id)
    if id == nil or id == "" then
        return false
    end
    local def = self.modules[id]
    if def == nil then
        return false
    end
    local ok, available = pcall(def.isAvailable)
    return ok and available == true
end

function RfEscModules:_ensureSettingsHub()
    if self._settingsHubBound then
        return
    end
    local hub = g_currentMission ~= nil and g_currentMission.settingsHub or nil
    if hub == nil or type(hub.registerModule) ~= "function" then
        return
    end
    local reg = self
    local ok = pcall(function()
        hub:registerModule(HUB_MOD_ID, {
            adminSettings = {
                {
                    id = HUB_KEY,
                    type = "enum",
                    values = HUB_ENUM,
                    default = "soilFertilizer",
                    adminOnly = false,
                    label = "Esc RF last module",
                },
            },
            onChange = function(key, value)
                if key == HUB_KEY and type(value) == "string" and value ~= "" then
                    reg._lastClosedModuleId = value
                    reg._userHasChosenModule = true
                end
            end,
        })
    end)
    self._settingsHubBound = ok == true
end

---@return string|nil
function RfEscModules:_readHubLastModuleId()
    self:_ensureSettingsHub()
    local hub = g_currentMission ~= nil and g_currentMission.settingsHub or nil
    if hub == nil or type(hub.getValue) ~= "function" then
        return nil
    end
    local ok, value = pcall(function()
        return hub:getValue(HUB_MOD_ID, HUB_KEY)
    end)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

---@param id string
function RfEscModules:_writeHubLastModuleId(id)
    if id == nil or id == "" then
        return
    end
    local allowed = false
    for _, v in ipairs(HUB_ENUM) do
        if v == id then
            allowed = true
            break
        end
    end
    if not allowed then
        return
    end
    self:_ensureSettingsHub()
    local hub = g_currentMission ~= nil and g_currentMission.settingsHub or nil
    if hub == nil or type(hub.setValue) ~= "function" then
        return
    end
    pcall(function()
        hub:setValue(HUB_MOD_ID, HUB_KEY, id)
    end)
end

--- Cold / reopen home: session last → SettingsHub durable → Soil → first sorted.
---@return string|nil
function RfEscModules:resolveHomeModuleId()
    if self:_moduleAvailable(self._lastClosedModuleId) then
        return self._lastClosedModuleId
    end
    local hubId = self:_readHubLastModuleId()
    if self:_moduleAvailable(hubId) then
        return hubId
    end
    if self:_moduleAvailable("soilFertilizer") then
        return "soilFertilizer"
    end
    local list = self:getModules()
    if list[1] ~= nil then
        return list[1].id
    end
    return nil
end

--- Persist last module (select + frame close). Soft-detect SettingsHub write.
---@param id string|nil
function RfEscModules:rememberClosedModule(id)
    if id == nil or id == "" then
        return
    end
    if self.modules[id] == nil then
        return
    end
    self._lastClosedModuleId = id
    self._userHasChosenModule = true
    self:_writeHubLastModuleId(id)
end

--- Apply home without listener notify (single onShow on subsequent refreshContent).
---@return boolean
function RfEscModules:applyHomeModuleQuiet()
    local id = self:resolveHomeModuleId()
    if id == nil then
        return false
    end
    self.activeModuleId = id
    self._userHasChosenModule = true
    return true
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
        -- Vera F2 2026-08-07: registerModule whitelists fields, so this was being
        -- dropped and the door could never ask the active module to open its own
        -- deep screen. Guests register it; keep it.
        onOpenFullMarket = def.onOpenFullMarket,
        -- Same trap, 2026-08-09: a handler missing from this list is silently
        -- discarded and the Esc Crop Stress buttons would do nothing.
        onOpenConsultant = def.onOpenConsultant,
        onOpenSchedule = def.onOpenSchedule,
        onPaintConsultant = def.onPaintConsultant,
        -- Same trap again, BUILD 15:46: the CS guest registers onPivotRemote on
        -- its module def (CsRfPdaGuest.lua) but it was missing here, so it was
        -- silently discarded and active.onPivotRemote was always nil. The Esc
        -- PIVOT buttons only worked through the global CsRfPdaGuest fallback.
        onPivotRemote = def.onPivotRemote,
    }
    -- Product default is resolveHomeModuleId (Soil / last / hub), not first-register.
    -- Leave activeModuleId nil until applyHomeModuleQuiet / selectModule.
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
        local home = self:resolveHomeModuleId()
        if home ~= nil then
            self.activeModuleId = home
        else
            local list = self:getModules()
            if list[1] ~= nil then
                self.activeModuleId = list[1].id
            end
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
    self:rememberClosedModule(id)
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
