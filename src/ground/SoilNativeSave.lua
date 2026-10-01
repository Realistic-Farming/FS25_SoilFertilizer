-- =========================================================
-- FS25_SoilFertilizer - Soil's own native save boundary (GROUND-CONDITION-CONTRACT 6)
-- =========================================================
-- GROUND-CONDITION-CONTRACT v1.5 section 6 (:96) and the single preparation owner (:112);
-- SG-2 v2.3 :818-836 ("Soil-alone uses one Soil-owned equivalent for its two participants,
-- not one wrapper per domain"), with the SG-2 source and binding contract used as the
-- build specification, not an install dependency (:96). It is StockGuard's
-- SG_NATIVE_MATERIAL_SAVE_V1 (SG2-4a, FS25_StockGuard src/native/SGNativeMaterialSave.lua)
-- carried into Soil for the case where StockGuard does not own the boundary.
--
-- THE GAP. Soil writes its condition layers (materialAge, materialWetness and the ground
-- membership index, GRLE bit vector maps) inside the career XML chain, through
-- saveSoilData from the FSCareerMissionInfo.saveToXMLFile append. The terrain height image
-- those layers describe is written later: in a nonblocking save the controller only QUEUES
-- the height preparation (SavegameController.lua:556-568) and the game keeps running until
-- that task comes round. This boundary prepares the height image at the end of the same
-- chain, so the layers and the image describe one moment.
--
-- ONE OWNER AT A TIME (GCC :112, SG-2 :818). "Soil joins the attemptId through StockGuard's
-- boundary callback without installing a second wrap. Soil installs its own narrow boundary
-- only when StockGuard is absent at install, and releases it if StockGuard later appears
-- with that capability." So, per mission (installForMission):
--   * StockGuard present with nativeMaterialSave = 1 (getCapabilities on its mission handle):
--     Soil's participants register through registerNativeSaveParticipant and Soil installs
--     NOTHING on the controller. A refused registration leaves Soil's enhancement
--     unavailable; it never authorizes a second wrapper (:818).
--   * otherwise Soil installs its own boundary;
--   * StockGuard gaining the capability later (checked at mission start and at the start of
--     every save Soil's own boundary sees) releases Soil's: each wrapper still on top of the
--     controller method is unlinked, and one a later wrapper sits above becomes a pure
--     pass-through. That state lives in this module, never as a marker on SavegameController,
--     an engine class that outlives a mods reload (the GroundTipGate stacking form,
--     src/hooks/GroundTipGate.lua:19-28).
--
--   THE ATTEMPT. SavegameController:onSaveStartComplete (:373) is wrapped on the class; the
--   engine reaches it by name (saveWriteSavegameStart(..., "onSaveStartComplete", self),
--   :726). On a successful start (ERROR_OK with a staging directory) one attempt is
--   allocated from Soil's own counter, every registered participant's beginAttempt runs
--   BEFORE the original controller, and the controller is called exactly once.
--
--   THE FREEZE. For the length of the attempt an instance field on the controller's
--   career save (savegame:saveToXMLFile, :384) wraps the whole chain as it resolved then,
--   and at its END each participant's freezeAfterCareerXML runs: before the controller's
--   direct density-map writes in a blocking save (:400, :415, :560).
--
--   THE IMAGES. A READY answer names its payload file and its exact images. Each must be a
--   file the controller saves itself, under that map id, in its own order (fruit planes
--   and haulms, :392-423, then the height map, :556). An image or a payload file named by
--   two participants invalidates every participant naming it (SG-2 :831).
--
--   THE SAME-CALL PREPARE (nonblocking only). Each distinct image of a READY participant
--   is prepared at the freeze through the engine global, and when the controller's queued
--   closure later asks for that exact map and path, the guard skips that one call; the
--   closure still adds its ordinary SAVE_TASK_DENSITY_MAP (:564-566). A blocking save
--   prepares nothing: its direct writes follow in the same call.
--
--   THE ENGINE GLOBAL. The guard is written into the table that holds the callable,
--   getmetatable(_G).__index (mods.lua:489-495: a mod's _G is its own environment), only
--   while an attempt holds an association, and removed only while it is still ours.
--
--   THE RESULT. SavegameController:onSaveComplete (:672) is observed once per attempt:
--   every participant that began receives finishAttempt(context, errorCode,
--   finalSavegameDirectory), and context.results[id] says what the boundary decided for it.
--
-- NOT HERE: StockGuard's four same-call deferrals (SG-2 :565) are StockGuard's; Soil has no
-- material writer that re-enters the chain, and CD-15's admitted disease mutations
-- invalidate their attempt on re-entry rather than wait (:834). The blocking branch's
-- direct height write stays native.
-- =========================================================

SoilNativeSave = SoilNativeSave or {}
local M = SoilNativeSave
local M_mt = { __index = M }

M.PROFILE = "SOIL_NATIVE_SAVE_V1"
M.READY = "READY"
M.UNAVAILABLE = "UNAVAILABLE"
M.PENDING = "PENDING"
M.GUARDED_GLOBAL = "prepareSaveDensityMapToFile"
M.SUPPORTED_IMAGES = { FRUIT = true, HAULM = true, HEIGHT = true }

M.current = M.current
M.guard = M.guard
M.associations = M.associations or {}
M.logged = M.logged or {}

-- Soil's own wrappers on the controller (module state, never a marker on the engine class):
-- { class, entries = { name -> { original, wrapper, linked } } } while any exists, and whether
-- they run the boundary (false: pure pass-through).
local _wraps = nil
local _active = false

local function packn(...) return select("#", ...), { ... } end
local function log(fmt, ...) SoilLogger.info("[NativeSave] " .. fmt, ...) end
local function logOnce(key, fmt, ...)
    if M.logged[key] then return end
    M.logged[key] = true
    log(fmt, ...)
end
local function errorOk()
    return Savegame ~= nil and Savegame.ERROR_OK ~= nil and Savegame.ERROR_OK or nil
end

-- ---------------------------------------------------------
-- The per-mission boundary and its participants
-- ---------------------------------------------------------
function M.new(mission)
    local self = setmetatable({}, M_mt)
    self.mission = mission
    self.participants = {}      -- participantId -> spec (the owner's own table)
    self.order = {}             -- registration order of ids
    self.joined = {}            -- participantId -> true once registered on StockGuard
    self.nextAttemptId = 0
    self.attempt = nil
    self.lastAttempt = nil
    self.closed = false
    return self
end

--- Register a Soil participant: { beginAttempt, freezeAfterCareerXML, finishAttempt }.
function M:register(participantId, spec)
    if type(participantId) ~= "string" or participantId == "" or #participantId > 64 then return false, "INVALID_ID" end
    if type(spec) ~= "table" or type(spec.beginAttempt) ~= "function" or type(spec.freezeAfterCareerXML) ~= "function"
       or type(spec.finishAttempt) ~= "function" then
        return false, "INVALID_SPEC"
    end
    if self.closed then return false, "MISSION_ENDED" end
    local live = self.participants[participantId]
    if live ~= nil then
        if live == spec then return true end
        return false, "CONFLICT"
    end
    self.participants[participantId] = spec
    self.order[#self.order + 1] = participantId
    self:joinStockGuard()
    return true
end

--- The attempt ids continue after the highest one a load found, so a save never reuses one.
function M:seedAttempt(n)
    if type(n) == "number" and n == math.floor(n) and n > self.nextAttemptId then self.nextAttemptId = n end
end

function M:activate()
    if self.closed then return false end
    M.current = self
    return true
end

function M:close(reason)
    if self.attempt ~= nil then
        local ok, err = pcall(self.finish, self, self.attempt, reason or "SOIL_TEARDOWN", nil)
        if not ok then log("teardown finish failed (%s)", tostring(err)) end
    end
    local sg = self:stockGuardHandle()
    if sg ~= nil and type(sg.unregisterNativeSaveParticipant) == "function" then
        for id in pairs(self.joined) do pcall(sg.unregisterNativeSaveParticipant, id, self.participants[id]) end
    end
    self.participants, self.order, self.joined = {}, {}, {}
    self.closed = true
    if M.current == self then M.current = nil end
    M.releaseOwn()
    M.clearAssociations(nil)
    M.removeGuard()
end

-- ---------------------------------------------------------
-- StockGuard owns the boundary when it is present with the capability
-- ---------------------------------------------------------
function M:stockGuardHandle()
    local mission = self.mission or g_currentMission
    local sg = mission ~= nil and mission.stockGuard or nil
    if type(sg) ~= "table" then return nil end
    return sg
end

--- Does StockGuard's SG_NATIVE_MATERIAL_SAVE_V1 boundary own this mission's saves?
function M:stockGuardCapable()
    local sg = self:stockGuardHandle()
    if sg == nil or type(sg.getCapabilities) ~= "function" or type(sg.registerNativeSaveParticipant) ~= "function" then return false end
    local ok, caps = pcall(sg.getCapabilities)
    return ok and type(caps) == "table" and caps.nativeMaterialSave == 1
end

--- Join every registered participant to StockGuard's boundary. True when StockGuard owns
--- the boundary and every participant is registered on it.
function M:joinStockGuard()
    if self.closed or not self:stockGuardCapable() then return false end
    local sg = self:stockGuardHandle()
    local all = true
    for _, id in ipairs(self.order) do
        if not self.joined[id] then
            local ok, registered, why = pcall(sg.registerNativeSaveParticipant, id, self.participants[id])
            if ok and registered then
                self.joined[id] = true
                log("participant %s joined StockGuard's native save boundary", id)
            else
                all = false
                logOnce("join:" .. id, "participant %s could not join StockGuard's boundary (%s); its enhanced save is unavailable while StockGuard owns the boundary",
                    id, tostring(ok and why or registered))
            end
        end
    end
    return all
end

--- The install decision for this mission (GCC :112). Returns the mode: JOINED (StockGuard
--- owns the boundary; Soil installed nothing), JOIN_REFUSED (StockGuard owns it and refused a
--- participant; still nothing installed), or OWN (Soil's own boundary).
function M:installForMission(classes)
    self.classes = classes or self.classes or {}
    if self:stockGuardCapable() then
        self.mode = self:joinStockGuard() and "JOINED" or "JOIN_REFUSED"
        M.releaseOwn()
    else
        self.mode = M.installOwn(self.classes.SavegameController) and "OWN" or "NOT_INSTALLED"
    end
    log("native save boundary for this mission: %s", tostring(self.mode))
    return self.mode
end

--- StockGuard appeared with the capability after Soil installed its own: join it and
--- release Soil's. Called at mission start and at the start of each save Soil's own sees.
function M:reconsider()
    if self.closed or self.mode ~= "OWN" or not self:stockGuardCapable() then return false end
    self.mode = self:joinStockGuard() and "JOINED" or "JOIN_REFUSED"
    M.releaseOwn()
    log("StockGuard took the native save boundary; Soil's own is released (%s)", tostring(self.mode))
    return true
end

-- ---------------------------------------------------------
-- The attempt
-- ---------------------------------------------------------
function M.openAttempt(controller, errorCode, savegameDirectory)
    local self = M.current
    if self == nil or self.closed then return nil end
    local ok = errorOk()
    if ok == nil or errorCode ~= ok or savegameDirectory == nil then return nil end
    if type(controller) ~= "table" or type(controller.currentSavegame) ~= "table" then return nil end
    if self.attempt ~= nil then self:finish(self.attempt, "SOIL_ATTEMPT_SUPERSEDED", nil) end
    self.nextAttemptId = self.nextAttemptId + 1
    local context = {
        attemptId = self.nextAttemptId,
        mission = self.mission or g_currentMission,
        controller = controller,
        careerSave = controller.currentSavegame,
        stagingDirectory = savegameDirectory,
        isBlocking = controller.isSavingBlocking == true,
        ownBoundary = true,       -- Soil's own boundary: the participant names its images
        results = {},
    }
    local attempt = { context = context, controller = controller, members = {}, frozen = false, finished = false }
    for _, id in ipairs(self.order) do
        local spec = self.participants[id]
        attempt.members[#attempt.members + 1] = { id = id, spec = spec }
        local okBegin, err = pcall(spec.beginAttempt, context)
        if okBegin then
            context.results[id] = { state = M.PENDING }
        else
            context.results[id] = { state = M.UNAVAILABLE, reason = "BEGIN_FAILED" }
            log("participant %s failed at begin (%s); only it is unavailable for attempt %s", id, tostring(err), tostring(context.attemptId))
        end
    end
    self.attempt = attempt
    return attempt
end

function M.invalidatePending(attempt, reason)
    for _, m in ipairs(attempt.members) do
        local r = attempt.context.results[m.id]
        if r == nil or r.state == M.PENDING then attempt.context.results[m.id] = { state = M.UNAVAILABLE, reason = reason } end
    end
end

function M.wrapCareerSave(attempt)
    local careerSave = attempt.context.careerSave
    local chain = careerSave.saveToXMLFile
    if type(chain) ~= "function" then return false end
    local ownField = rawget(careerSave, "saveToXMLFile")
    local wrapper
    wrapper = function(obj, ...)
        if obj ~= careerSave or attempt.chainEntered then return chain(obj, ...) end
        attempt.chainEntered = true
        local n, r = packn(pcall(chain, obj, ...))
        if r[1] then
            local okFreeze, err = pcall(M.freeze, attempt)
            if not okFreeze then
                M.invalidatePending(attempt, "FREEZE_FAILED")
                log("freeze failed (%s); the native save continues, Soil's enhanced sections of attempt %s are unavailable", tostring(err), tostring(attempt.context.attemptId))
            end
        else
            M.invalidatePending(attempt, "CAREER_XML_FAILED")
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    rawset(careerSave, "saveToXMLFile", wrapper)
    attempt.careerWrap = { object = careerSave, wrapper = wrapper, ownField = ownField }
    return true
end

function M.unwrapCareerSave(attempt)
    local w = attempt.careerWrap
    if w == nil then return end
    attempt.careerWrap = nil
    if rawget(w.object, "saveToXMLFile") == w.wrapper then rawset(w.object, "saveToXMLFile", w.ownField) end
end

-- ---------------------------------------------------------
-- The native image set, in the controller's own order
-- ---------------------------------------------------------
function M.nativeImageSet(mission)
    local set = {}
    if getDensityMapFilename == nil then return set end
    local function claim(id, kind)
        if id == nil then return end
        local ok, filename = pcall(getDensityMapFilename, id)
        if ok and type(filename) == "string" and filename ~= "" and set[filename] == nil then set[filename] = { mapId = id, kind = kind } end
    end
    if g_fruitTypeManager ~= nil and type(g_fruitTypeManager.getFruitTypes) == "function" then
        for _, desc in pairs(g_fruitTypeManager:getFruitTypes()) do
            claim(desc.terrainDataPlaneId, "FRUIT")
            claim(desc.terrainDataPlaneIdHaulm, "HAULM")
        end
    end
    if mission ~= nil then claim(mission.terrainDetailHeightId, "HEIGHT") end
    return set
end

function M.validateFreeze(out)
    if type(out) ~= "table" then return nil, "FREEZE_ANSWER" end
    if out.state == M.UNAVAILABLE then return { state = M.UNAVAILABLE, reason = tostring(out.reason or "UNAVAILABLE") } end
    if out.state ~= M.READY then return nil, "FREEZE_STATE" end
    local file = out.payloadFile
    if type(file) ~= "string" or file == "" or #file > 128 or file:find("..", 1, true) ~= nil or file:find("[/\\:]") ~= nil then
        return nil, "PAYLOAD_FILE"
    end
    if type(out.images) ~= "table" then return nil, "IMAGES" end
    local images = {}
    for i, img in ipairs(out.images) do
        if type(img) ~= "table" or img.mapId == nil or type(img.nativeFilename) ~= "string" or img.nativeFilename == "" then return nil, "IMAGE:" .. i end
        images[i] = { mapId = img.mapId, nativeFilename = img.nativeFilename }
    end
    return { state = M.READY, payloadFile = file, images = images }
end

function M.freeze(attempt)
    if attempt.frozen then return end
    attempt.frozen = true
    local context = attempt.context
    local results = context.results
    for _, m in ipairs(attempt.members) do
        if results[m.id].state == M.PENDING then
            local ok, out = pcall(m.spec.freezeAfterCareerXML, context)
            local answer, why
            if ok then answer, why = M.validateFreeze(out) else why = "FREEZE_THREW" end
            if answer == nil then
                results[m.id] = { state = M.UNAVAILABLE, reason = why }
                if not ok then log("participant %s threw at freeze (%s); only it is unavailable", m.id, tostring(out)) end
            else
                results[m.id] = answer
            end
        end
    end
    local native = M.nativeImageSet(context.mission)
    local claims, payloads = {}, {}
    for _, m in ipairs(attempt.members) do
        local r = results[m.id]
        if r.state == M.READY then
            payloads[r.payloadFile] = payloads[r.payloadFile] or {}
            table.insert(payloads[r.payloadFile], m.id)
            for _, img in ipairs(r.images) do
                local n = native[img.nativeFilename]
                if n == nil or n.mapId ~= img.mapId or not M.SUPPORTED_IMAGES[n.kind] then
                    results[m.id] = { state = M.UNAVAILABLE, reason = "IMAGE_NOT_NATIVE" }
                    break
                end
            end
            if results[m.id].state == M.READY then
                for _, img in ipairs(r.images) do
                    claims[img.nativeFilename] = claims[img.nativeFilename] or {}
                    claims[img.nativeFilename][m.id] = true
                end
            end
        end
    end
    local function invalidate(ids, reason)
        for _, id in ipairs(ids) do results[id] = { state = M.UNAVAILABLE, reason = reason } end
    end
    for _, set in pairs(claims) do
        local ids = {}
        for id in pairs(set) do ids[#ids + 1] = id end
        if #ids > 1 then invalidate(ids, "DUPLICATE_MAP_PATH") end
    end
    for _, ids in pairs(payloads) do
        if #ids > 1 then invalidate(ids, "PAYLOAD_FILE_CONFLICT") end
    end
    if context.isBlocking then return end
    local dir = context.careerSave.savegameDirectory or context.stagingDirectory
    local prepared = {}
    for _, m in ipairs(attempt.members) do
        local r = results[m.id]
        if r.state == M.READY then
            for _, img in ipairs(r.images) do
                if prepared[img.nativeFilename] == nil then
                    local path = dir .. "/" .. img.nativeFilename
                    local okPrep = M.prepareNow(img.mapId, path)
                    prepared[img.nativeFilename] = okPrep
                    if okPrep then
                        M.associations[#M.associations + 1] = { attemptId = context.attemptId, mapId = img.mapId, path = path, consumed = false }
                    end
                end
                if prepared[img.nativeFilename] == false then
                    results[m.id] = { state = M.UNAVAILABLE, reason = "PREPARE_FAILED" }
                end
            end
        end
    end
    if #M.associations > 0 then
        local okGuard, why = M.ensureGuard()
        if not okGuard then
            for _, m in ipairs(attempt.members) do
                local r = results[m.id]
                if r.state == M.READY and #r.images > 0 then results[m.id] = { state = M.UNAVAILABLE, reason = "GUARD_UNAVAILABLE:" .. tostring(why) } end
            end
            M.clearAssociations(context.attemptId)
        end
    end
end

-- ---------------------------------------------------------
-- The prepare guard on the engine global
-- ---------------------------------------------------------
function M.resolveEngineTable(name)
    local mt = getmetatable(_G)
    local base = mt ~= nil and type(mt.__index) == "table" and mt.__index or nil
    if base ~= nil then
        if type(rawget(base, name)) == "function" then return base, "ENGINE" end
        return nil, "ENGINE_GLOBAL_ABSENT"
    end
    if type(rawget(_G, name)) == "function" then return _G, "ROOT" end
    return nil, "ENGINE_GLOBAL_ABSENT"
end

function M.prepareNow(mapId, path)
    local t = M.resolveEngineTable(M.GUARDED_GLOBAL)
    if t == nil then return false end
    local ok, err = pcall(rawget(t, M.GUARDED_GLOBAL), mapId, path)
    if not ok then log("same-call prepare of %s failed (%s)", tostring(path), tostring(err)) end
    return ok
end

function M.matchAssociation(mapId, path)
    for _, a in ipairs(M.associations) do
        if not a.consumed and a.mapId == mapId and a.path == path then return a end
    end
    return nil
end

function M.clearAssociations(attemptId)
    if attemptId == nil then M.associations = {} return end
    local keep = {}
    for _, a in ipairs(M.associations) do
        if a.attemptId ~= attemptId then keep[#keep + 1] = a
        elseif not a.consumed then
            log("the controller never asked to prepare %s for attempt %s; the image prepared at the freeze was not written by it", tostring(a.path), tostring(attemptId))
        end
    end
    M.associations = keep
end

function M.ensureGuard()
    if M.guard ~= nil then return true end
    local t, where = M.resolveEngineTable(M.GUARDED_GLOBAL)
    if t == nil then return false, where end
    local original = rawget(t, M.GUARDED_GLOBAL)
    local wrapper = function(mapId, path, ...)
        local a = M.matchAssociation(mapId, path)
        if a ~= nil then
            a.consumed = true
            return
        end
        return original(mapId, path, ...)
    end
    rawset(t, M.GUARDED_GLOBAL, wrapper)
    M.guard = { table = t, original = original, wrapper = wrapper }
    logOnce("guardTable", "prepare guard installed on the engine global %s (%s table)", M.GUARDED_GLOBAL, tostring(where))
    return true
end

function M.removeGuard()
    local g = M.guard
    if g == nil then return true end
    if rawget(g.table, M.GUARDED_GLOBAL) == g.wrapper then
        rawset(g.table, M.GUARDED_GLOBAL, g.original)
        M.guard = nil
        return true
    end
    logOnce("guardUnder", "prepare guard left in place under a later wrapper of %s; it passes every call through", M.GUARDED_GLOBAL)
    return false
end

-- ---------------------------------------------------------
-- The result
-- ---------------------------------------------------------
function M:finish(attempt, errorCode, finalSavegameDirectory)
    if attempt == nil or attempt.finished then return end
    attempt.finished = true
    if self.attempt == attempt then self.attempt = nil end
    local context = attempt.context
    M.invalidatePending(attempt, "NO_FREEZE")
    for _, m in ipairs(attempt.members) do
        local ok, err = pcall(m.spec.finishAttempt, context, errorCode, finalSavegameDirectory)
        if not ok then log("participant %s failed at finish (%s)", m.id, tostring(err)) end
    end
    M.clearAssociations(context.attemptId)
    M.removeGuard()
    local results = {}
    for id, r in pairs(context.results) do results[id] = { state = r.state, reason = r.reason } end
    self.lastAttempt = { attemptId = context.attemptId, errorCode = errorCode, results = results }
end

-- ---------------------------------------------------------
-- Soil's own wrappers on the controller (the class table read at call time)
-- ---------------------------------------------------------
local function aroundSaveStart(original, controller, errorCode, savegameDirectory, ...)
    -- StockGuard took the boundary since the install: release ours and pass this one through.
    local boundary = M.current
    if boundary ~= nil and boundary:reconsider() then return original(controller, errorCode, savegameDirectory, ...) end
    local attempt = nil
    local okOpen, result = pcall(M.openAttempt, controller, errorCode, savegameDirectory)
    if okOpen then attempt = result else log("attempt open failed (%s); the native save runs unchanged", tostring(result)) end
    if attempt ~= nil then
        local okWrap, wrapped = pcall(M.wrapCareerSave, attempt)
        if not okWrap or not wrapped then M.invalidatePending(attempt, "NO_CAREER_CHAIN") end
    end
    local n, r = packn(pcall(original, controller, errorCode, savegameDirectory, ...))
    if attempt ~= nil then
        M.unwrapCareerSave(attempt)
        if not attempt.chainEntered then M.invalidatePending(attempt, "NO_FREEZE") end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

local function aroundSaveComplete(original, controller, errorCode, finalSavegameDirectory, ...)
    local boundary = M.current
    if boundary ~= nil and boundary.attempt ~= nil and boundary.attempt.controller == controller then
        local ok, err = pcall(boundary.finish, boundary, boundary.attempt, errorCode, finalSavegameDirectory)
        if not ok then log("attempt finish failed (%s)", tostring(err)) end
    end
    return original(controller, errorCode, finalSavegameDirectory, ...)
end

M.AROUND = { onSaveStartComplete = aroundSaveStart, onSaveComplete = aroundSaveComplete }

--- Install Soil's own boundary on the controller class, or make the wrappers already in
--- place active again. Server only. Returns true when Soil's boundary is live.
function M.installOwn(SC)
    if g_server == nil then return false end
    if type(SC) ~= "table" or type(SC.onSaveStartComplete) ~= "function" or type(SC.onSaveComplete) ~= "function" then return false end
    if _wraps ~= nil and _wraps.class ~= SC then _wraps = nil end
    _wraps = _wraps or { class = SC, entries = {} }
    for name, around in pairs(M.AROUND) do
        local e = _wraps.entries[name]
        if e == nil or not e.linked then
            local original = SC[name]
            local wrapper
            wrapper = function(self, ...)
                if not _active then return original(self, ...) end
                return around(original, self, ...)
            end
            SC[name] = wrapper
            _wraps.entries[name] = { original = original, wrapper = wrapper, linked = true }
        end
    end
    _active = true
    return true
end

--- Release Soil's own boundary: each wrapper still on top of its method is unlinked; one a
--- later wrapper sits above stays in place as a pure pass-through (module state).
function M.releaseOwn()
    _active = false
    if _wraps == nil then return end
    local remaining = false
    for name, e in pairs(_wraps.entries) do
        if e.linked and _wraps.class[name] == e.wrapper then
            _wraps.class[name] = e.original
            e.linked = false
        elseif e.linked then
            remaining = true
        end
    end
    if not remaining then _wraps = nil end
end

--- Diagnostics and bench: is Soil's own boundary live, and are its wrappers in the chain?
function M.ownState()
    local linked = 0
    if _wraps ~= nil then for _, e in pairs(_wraps.entries) do if e.linked then linked = linked + 1 end end end
    return { active = _active, linked = linked }
end
