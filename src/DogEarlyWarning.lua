-- =========================================================
-- CD-13: Dog Early-Warning System
-- =========================================================
-- Owning a base-game dog placeable switches on a free,
-- passive, farm-wide crop disease early-warning. It tells
-- the player WHICH field is off, never the disease name or
-- severity (the paid ProStaff rungs sit above it). No false
-- positives: fires only on a named active infection
-- (activeDisease ~= nil), never on raw pressure alone.
-- =========================================================

DogEarlyWarning = DogEarlyWarning or {}

DogEarlyWarning.CADENCE_MS = 60000

-- RSF-F192: the two warning templates resolve through the mod's own locale
-- keys. The English sentences below are the exact conservative fallback when
-- the lookup is unavailable, the key is absent, the template is not a string,
-- or it does not carry exactly one string placeholder. They are not a
-- substitute for shipping the keys in every locale file.
DogEarlyWarning.FIELD_WARNING_KEY = "sf_dog_field_warning"
DogEarlyWarning.BARN_WARNING_KEY  = "sf_dog_barn_warning"
DogEarlyWarning.FIELD_WARNING_FALLBACK = "Your dog senses something wrong with Field #%s."
DogEarlyWarning.BARN_WARNING_FALLBACK  = "Your dog senses something wrong at Barn %s."

--- True when `fmt` carries exactly one unescaped %s and no other conversion.
--- "%%" is a literal percent and does not count; a trailing lone % is rejected.
local function hasOneStringPlaceholder(fmt)
    if type(fmt) ~= "string" or fmt == "" then return false end
    local stripped = fmt:gsub("%%%%", "")
    if stripped:find("%%$") then return false end
    local count, other = 0, false
    for conv in stripped:gmatch("%%[%-%+ #0]*%d*%.?%d*([%a])") do
        if conv == "s" then count = count + 1 else other = true end
    end
    return count == 1 and not other
end

--- Resolve one warning sentence with the field or barn identifier inserted.
--- Never throws: every lookup and format runs under pcall, and the English
--- fallback is used whenever the localized template cannot be trusted.
---@param key string        the locale key
---@param fallback string   the exact English sentence
---@param id any            field or barn identifier
---@return string
function DogEarlyWarning.formatWarning(key, fallback, id)
    local template = nil
    pcall(function()
        local i18n = g_i18n
        if i18n == nil or type(i18n.hasText) ~= "function" or type(i18n.getText) ~= "function" then
            return
        end
        if i18n:hasText(key) ~= true then return end
        local text = i18n:getText(key)
        if hasOneStringPlaceholder(text) then template = text end
    end)
    local ident = tostring(id)
    local ok, msg = pcall(string.format, template or fallback, ident)
    if ok and type(msg) == "string" then return msg end
    ok, msg = pcall(string.format, fallback, ident)
    if ok and type(msg) == "string" then return msg end
    return fallback
end

-- RSF-F190 own-farm privacy (Implementation brief v1.0, certified; over #1054): the
-- warning belongs only to the actual local player's current farm. Detection may keep
-- an internal cache for every farm it scans (a server scans them all), but a barn row
-- reaches this machine's HUD or getter only for the presentation context: the actual
-- g_localPlayer and its ordinary current farm (SpatialScouting.isOrdinaryFarmId), with
-- no requested, default or administrator farm. A dedicated server has none, and
-- presents no barn. Each barn row keeps a private transient binding to the placeable it
-- was scanned from; before any exposure the binding must still be a current roster
-- husbandry, not being deleted, owned by the context farm, with a live doghouse. The
-- crop branch is kept exactly as it was for its own owner (CD-15).
function DogEarlyWarning.new(soilSystem)
    local self = {}
    setmetatable(self, { __index = DogEarlyWarning })
    self.soilSystem = soilSystem
    self.warnings = {}
    self.lastScan = 0
    self.notifiedFields = {}
    self.ctx = nil                -- { actor, farmId }: the presentation context in force
    self.subscribed = false
    self:subscribe()
    return self
end

--- The presentation context: the actual local player object and its ordinary current
--- farm, or nil (no player, a dedicated server, a malformed actor, a spectator or any
--- non-ordinary farm).
---@return table|nil actor, number|nil farmId
function DogEarlyWarning.presentationContext()
    local actor = g_localPlayer
    if type(actor) ~= "table" then return nil, nil end
    local farmId = actor.farmId
    local ordinary
    if SpatialScouting ~= nil and type(SpatialScouting.isOrdinaryFarmId) == "function" then
        ordinary = SpatialScouting.isOrdinaryFarmId(farmId)
    else
        ordinary = type(farmId) == "number" and farmId == math.floor(farmId) and farmId >= 1 and farmId <= 8
    end
    if not ordinary then return nil, nil end
    return actor, farmId
end

--- Drop one farm's livestock rows (and with them their private bindings) and its
--- livestock notification keys. Crop rows and crop keys stay with their owner.
function DogEarlyWarning:_clearLivestock(farmId)
    if farmId == nil then return end
    local rows = self.warnings[farmId]
    if rows ~= nil then
        local kept = {}
        for _, r in ipairs(rows) do
            if r.type == "crop" then kept[#kept + 1] = r end
        end
        self.warnings[farmId] = #kept > 0 and kept or nil
    end
    local notified = self.notifiedFields[farmId]
    if notified ~= nil then
        for key in pairs(notified) do
            if key:sub(-5) ~= "_crop" then notified[key] = nil end
        end
    end
end

--- Bring the presentation context up to date. A change of actor or farm (or a first
--- context) clears the livestock presentation of the old and the new context farm
--- before anything can be exposed again; another farm's internal detection stays.
--- Idempotent: an unchanged context does nothing.
---@return boolean changed
function DogEarlyWarning:_refreshContext()
    local actor, farmId = DogEarlyWarning.presentationContext()
    local ctx = self.ctx
    if ctx == nil and actor == nil then return false end
    if ctx ~= nil and ctx.actor == actor and ctx.farmId == farmId then return false end
    if ctx ~= nil then self:_clearLivestock(ctx.farmId) end
    if farmId ~= nil then self:_clearLivestock(farmId) end
    self.ctx = actor ~= nil and { actor = actor, farmId = farmId } or nil
    return true
end

--- PLAYER_FARM_CHANGED (MessageCenter calls it as (target, player)). Only the local
--- player's own switch matters, and one switch may publish twice: refresh is idempotent.
function DogEarlyWarning:onPlayerFarmChanged(player)
    if player == nil or player ~= g_localPlayer then return end
    self:_refreshContext()
end

--- The dog's own subscriber target (never SoilScoutingBridge's), on every topology.
---@return boolean subscribed
function DogEarlyWarning:subscribe()
    if self.subscribed then return true end
    if g_messageCenter == nil or type(g_messageCenter.subscribe) ~= "function" then return false end
    if MessageType == nil or MessageType.PLAYER_FARM_CHANGED == nil then return false end
    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, DogEarlyWarning.onPlayerFarmChanged, self)
    self.subscribed = true
    return true
end

--- Mission delete: release the subscription, every binding and every key.
function DogEarlyWarning:delete()
    if self.subscribed and g_messageCenter ~= nil and type(g_messageCenter.unsubscribe) == "function"
            and MessageType ~= nil and MessageType.PLAYER_FARM_CHANGED ~= nil then
        g_messageCenter:unsubscribe(MessageType.PLAYER_FARM_CHANGED, self, DogEarlyWarning.onPlayerFarmChanged)
    end
    self.subscribed = false
    self.warnings = {}
    self.notifiedFields = {}
    self.ctx = nil
end

--- Is this barn row's scanned placeable still a current roster husbandry, not being
--- deleted, owned by `farmId`? Its display id never establishes ownership.
function DogEarlyWarning:_barnStillOwned(row, farmId)
    local p = row._binding
    if p == nil then return false end
    local ok, owned = pcall(function()
        if p.spec_husbandryAnimals == nil then return false end
        local ps = g_currentMission and g_currentMission.placeableSystem
        if ps == nil or type(ps.placeables) ~= "table" then return false end
        local inRoster = false
        for _, q in ipairs(ps.placeables) do
            if q == p then inRoster = true break end
        end
        if not inRoster then return false end
        if type(p.getIsBeingDeleted) == "function" then
            if p:getIsBeingDeleted() then return false end
        elseif p.markedForDeletion or p.isDeleting or p.isDeleted then
            return false
        end
        if p.getOwnerFarmId == nil then return false end
        return p:getOwnerFarmId() == farmId
    end)
    return ok and owned == true
end

--- Is this crop row's field still owned by `farmId` (the CD-15 actor-matching crop
--- contract for a getter)? Unknown ownership omits it.
function DogEarlyWarning:_cropStillOwned(row, farmId)
    local ok, owner = pcall(function()
        local farmland = g_farmlandManager
        if farmland == nil or farmland.getFarmlandOwner == nil then return nil end
        return farmland:getFarmlandOwner(row.fieldId)
    end)
    return ok and owner == farmId
end

function DogEarlyWarning:hasDogOnFarm(farmId)
    local found = false
    pcall(function()
        local doghouses = g_currentMission and g_currentMission.doghouses
        if doghouses ~= nil then
            for doghouse, _ in pairs(doghouses) do
                if doghouse ~= nil and doghouse.getOwnerFarmId ~= nil then
                    if doghouse:getOwnerFarmId() == farmId then
                        found = true
                        return
                    end
                end
            end
            return
        end
        local ps = g_currentMission and g_currentMission.placeableSystem
        if ps == nil or ps.placeables == nil then return end
        for _, p in ipairs(ps.placeables) do
            if p ~= nil and PlaceableDoghouse ~= nil
                    and SpecializationUtil.hasSpecialization(PlaceableDoghouse, p.specializations) then
                local owner = nil
                if p.getOwnerFarmId ~= nil then owner = p:getOwnerFarmId() end
                if owner == farmId then
                    found = true
                    return
                end
            end
        end
    end)
    return found
end

function DogEarlyWarning:scan(farmId)
    self:_refreshContext()
    if not self:hasDogOnFarm(farmId) then
        -- The crop owner's existing early return (its rows go, its keys stay as before),
        -- and dog loss clears this farm's livestock presentation and keys.
        self:_clearLivestock(farmId)
        self.warnings[farmId] = nil
        return
    end
    local prior = self.warnings[farmId]

    -- The crop walk builds a temporary candidate and commits it only when the whole
    -- walk succeeds. A missing field list, or a throw after partial work, is an
    -- unavailable walk: the prior crop rows and keys stay, and no crop notification runs.
    local cropRows, cropComplete = nil, false
    local okWalk = pcall(function()
        local fields = g_currentMission.fieldManager:getFields()
        if fields == nil then return end
        local candidate = {}
        local farmland = g_farmlandManager
        for _, field in ipairs(fields) do
            local fid = field.farmland and field.farmland.id
            if fid ~= nil then
                local owner = nil
                pcall(function()
                    if farmland ~= nil and farmland.getFarmlandOwner ~= nil then
                        owner = farmland:getFarmlandOwner(fid)
                    end
                end)
                if owner == farmId and self.soilSystem ~= nil then
                    local info = nil
                    pcall(function() info = self.soilSystem:getFieldInfo(fid) end)
                    if info ~= nil and info.activeDisease ~= nil then
                        candidate[#candidate + 1] = {
                            fieldId = fid,
                            type = "crop",
                        }
                    end
                end
            end
        end
        cropRows = candidate
    end)
    cropComplete = okWalk and cropRows ~= nil
    if not cropComplete then
        cropRows = {}
        for _, r in ipairs(prior or {}) do
            if r.type == "crop" then cropRows[#cropRows + 1] = r end
        end
    end

    -- RSF-F190: livestock barns. Same shape as the crop line above: ask one
    -- SoilFertilizer-owned function (LivestockWarningReader) and test its
    -- return for presence. Nothing here touches a provider field, a provider
    -- method name, a disease name or the provider's manager; the reader's
    -- own gate learns provider presence and the diseases-enabled state
    -- through the provider's method. Each barn is read under its own
    -- protection so one bad barn cannot silence the farm; the reader
    -- contains failures per animal so one bad animal cannot silence a barn.
    -- The slice is rebuilt on every scan, independent of the crop walk, and each row
    -- keeps a private binding to its placeable. A pure client walks only its own
    -- context farm's barns, from the provider state it received.
    local barnRows = {}
    local ctxFarm = self.ctx and self.ctx.farmId or nil
    local walkBarns = g_server ~= nil or farmId == ctxFarm
    local placeables = nil
    pcall(function()
        local ps = g_currentMission and g_currentMission.placeableSystem
        if ps ~= nil and type(ps.placeables) == "table" then placeables = ps.placeables end
    end)
    if walkBarns and placeables ~= nil and LivestockWarningReader ~= nil then
        for _, p in ipairs(placeables) do
            pcall(function()
                if p.spec_husbandryAnimals == nil then return end
                local pOwner = nil
                if p.getOwnerFarmId ~= nil then pOwner = p:getOwnerFarmId() end
                if pOwner ~= farmId then return end
                if LivestockWarningReader.isBarnActivelySick(p) ~= nil then
                    local barnId = nil
                    pcall(function() barnId = p:getUniqueId() end)
                    barnRows[#barnRows + 1] = {
                        fieldId = barnId or "barn",
                        type = "livestock",
                        _binding = p,
                    }
                end
            end)
        end
    end

    local flagged = {}
    for _, r in ipairs(cropRows) do flagged[#flagged + 1] = r end
    for _, r in ipairs(barnRows) do flagged[#flagged + 1] = r end
    self.warnings[farmId] = #flagged > 0 and flagged or nil
    self:_notify(farmId, flagged, cropComplete)
end

--- The one post-scan notifier, over the farm's complete mixed list. The crop branch is
--- unchanged (its key set before its HUD call, its prune) and runs only when the crop
--- walk completed (`cropComplete`, true when omitted). The barn branch runs on every
--- call, for the presentation context's farm only: the authorized set is the barn rows
--- whose bindings are still owned by that farm with a live doghouse; a barn key is
--- pruned only when no authorized row uses it, and marked only after the HUD call was
--- made and returned without error.
function DogEarlyWarning:_notify(farmId, flagged, cropComplete)
    if cropComplete == nil then cropComplete = true end
    self:_refreshContext()
    if self.notifiedFields[farmId] == nil then
        self.notifiedFields[farmId] = {}
    end
    local notified = self.notifiedFields[farmId]

    if cropComplete then
        for _, w in ipairs(flagged) do
            if w.type == "crop" then
                local key = tostring(w.fieldId) .. "_" .. w.type
                if not notified[key] then
                    notified[key] = true
                    local msg = DogEarlyWarning.formatWarning(DogEarlyWarning.FIELD_WARNING_KEY,
                        DogEarlyWarning.FIELD_WARNING_FALLBACK, w.fieldId)
                    pcall(function()
                        if g_currentMission ~= nil and g_currentMission.hud ~= nil
                                and g_currentMission.hud.showBlinkingWarning ~= nil then
                            g_currentMission.hud:showBlinkingWarning(msg, 5000)
                        end
                    end)
                end
            end
        end
        local activeCrop = {}
        for _, w in ipairs(flagged) do
            if w.type == "crop" then activeCrop[tostring(w.fieldId) .. "_" .. w.type] = true end
        end
        for key in pairs(notified) do
            if key:sub(-5) == "_crop" and not activeCrop[key] then
                notified[key] = nil
            end
        end
    end

    local ctxFarm = self.ctx and self.ctx.farmId or nil
    local authorized, active = {}, {}
    if ctxFarm ~= nil and farmId == ctxFarm and self:hasDogOnFarm(farmId) then
        for _, w in ipairs(flagged) do
            if w.type ~= "crop" and self:_barnStillOwned(w, farmId) then
                authorized[#authorized + 1] = w
                active[tostring(w.fieldId) .. "_" .. w.type] = true
            end
        end
    end
    for key in pairs(notified) do
        if key:sub(-5) ~= "_crop" and not active[key] then
            notified[key] = nil
        end
    end
    for _, w in ipairs(authorized) do
        local key = tostring(w.fieldId) .. "_" .. w.type
        if not notified[key] then
            local msg = DogEarlyWarning.formatWarning(DogEarlyWarning.BARN_WARNING_KEY,
                DogEarlyWarning.BARN_WARNING_FALLBACK, w.fieldId)
            local hud = g_currentMission ~= nil and g_currentMission.hud or nil
            if hud ~= nil and hud.showBlinkingWarning ~= nil then
                local ok = pcall(function() hud:showBlinkingWarning(msg, 5000) end)
                if ok then notified[key] = true end
            end
        end
    end
end

--- The published list API: a fresh list of fresh {fieldId, type} copies for the
--- presentation context's own farm, or a fresh empty list (another farm, no context, a
--- context the update has not caught up with yet, no live dog). It never writes the
--- cache, the keys or the cadence, and it never returns a binding. An empty list is not
--- a claim of healthy ground or a healthy herd.
function DogEarlyWarning:getWarnings(farmId)
    local out = {}
    local actor, ctxFarm = DogEarlyWarning.presentationContext()
    local ctx = self.ctx
    if actor == nil or ctx == nil or ctx.actor ~= actor or ctx.farmId ~= ctxFarm or farmId ~= ctxFarm then
        return out
    end
    if not self:hasDogOnFarm(ctxFarm) then return out end
    for _, r in ipairs(self.warnings[ctxFarm] or {}) do
        local keep
        if r.type == "crop" then
            keep = self:_cropStillOwned(r, ctxFarm)
        else
            keep = self:_barnStillOwned(r, ctxFarm)
        end
        if keep then out[#out + 1] = { fieldId = r.fieldId, type = r.type } end
    end
    return out
end

function DogEarlyWarning:update(dt)
    -- The context check runs before the cadence return, so a late or changed actor
    -- never meets an old context's barn rows.
    self:_refreshContext()
    self.lastScan = self.lastScan + dt
    if self.lastScan < DogEarlyWarning.CADENCE_MS then return end
    self.lastScan = 0

    pcall(function()
        local fm = g_farmManager
        if fm == nil or fm.getFarms == nil then return end
        for _, farm in pairs(fm:getFarms() or {}) do
            if farm ~= nil and farm.farmId ~= nil and farm.farmId > 0 then
                self:scan(farm.farmId)
            end
        end
    end)
end
