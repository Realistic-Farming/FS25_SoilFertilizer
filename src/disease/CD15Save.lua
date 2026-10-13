-- =========================================================
-- FS25 Soil & Fertilizer - CD-15 local disease: the save participant (step 1b)
-- =========================================================
-- CD-15 implementation brief v1.14 (certificate 08-CD15):
--   :85       the saved envelope: the selected backend (soilData.xml, or StateLedger when it
--             is the load source) stores ONE `extensions.cd15Disease` header (schema 1,
--             attemptId, geometryFingerprint, payloadFile, the deduplicated native fruit and
--             haulm filenames), never a second copy of the live cell tree;
--   :218      the single native-staged soilDisease.xml payload: header namespace, attempt
--             and geometry, the occurrence sequence, ordered tiles and cells with every
--             schema-1 field, sorted mode maps, operationIds, and the day-work state needed
--             to finish a day exactly once; explicit counts, finite values, unique keys,
--             names and geometry validate before anything is applied;
--   :89-93    the attempt allocated before the career chain, the payload frozen at its end
--             with every distinct actual fruit and haulm image named for the same-call
--             prepare, the completion written only on the controller's ERROR_OK into the
--             FINAL directory; no save on mission delete;
--   :97-101   restore after native loading reads header, payload and marker as ONE attempt,
--             mints nothing; no evidence at all is the ratified clean first activation; an
--             invalid header, an orphan payload, a missing completion, a header mismatch or
--             conflicting geometry QUARANTINES, never a nicer clean grid.
-- Family native save composition (:690-706): CD-15 is a second participant on Soil's own
-- boundary (SoilNativeSave), which joins StockGuard's when StockGuard owns the save. No second
-- wrapper. Unlike the ground-condition participant, CD-15 names its images on both boundaries.
--
-- THE HEADER is composed once per attempt (headerForSave) and written by both writers inside
-- the career chain: saveSoilData into soilData.xml, and the StateLedger bridge's buildState.
-- A save made outside any native save (the console's saveSoilData) carries forward the header
-- that describes the files on disk, since it rewrites soilData.xml and nothing else.
--
-- A QUARANTINED session (Desk's ruling on Tyson's word, 2026-10-05, Bob's reading): every save
-- writes a header marked QUARANTINED with its reason and the original attemptId, no payload and
-- no images, so the next load stays quarantined. The exits are an administrator deleting the
-- CD-15 evidence, or step 3's admitted recovery entry (:228). Design is asked before step 2
-- whether a quarantine should have an earlier exit.
--
-- RESTORE waits for two things, whichever comes last: the native restore barrier (a Soil-owned
-- observer after the mission instance's onFinishedLoading, BaseMission.lua:215) and the header
-- the selected backend delivers in loadSoilData (mission start). Until it decides, the model
-- holds every day's work (CD15Model RESTORING).
--
-- NOT HERE: the re-entry invalidation for admitted writers (:91, family :704) lands with step
-- 2's and 3's writers, its only callers; discovery and admission are 1c, which reads the
-- discovery cursor this payload already carries.
--
-- Server only: no event, no stream field, no string, no setting. A client never registers,
-- writes or reads any of this.
-- =========================================================

CD15Save = CD15Save or {}
local S = CD15Save
local S_mt = { __index = S }

S.PARTICIPANT_ID = "soilCd15Disease"
S.PAYLOAD_FILE = "soilDisease.xml"
S.SCHEMA = 1
S.HEADER_KEY = "soilData.extensions.cd15Disease"
S.ROOT = "soilDisease"
S.SAVED, S.QUARANTINED = "SAVED", "QUARANTINED"
S.READY, S.UNAVAILABLE = "READY", "UNAVAILABLE"
S.MAX_IMAGES = 256
S.MAX_QUEUE = 1024
S.MAX_OPS = 1024

-- The captured day input's fields (CD15Day.captureInput), each with its kind.
S.INPUT_FIELDS = {
    { "day", "int" }, { "daysPerMonth", "num" }, { "rainScale", "num" }, { "isWet", "bool" }, { "season", "optint" },
    { "isCool", "bool" }, { "diseaseEnabled", "bool" }, { "cropRotation", "bool" }, { "growthMult", "num" },
    { "dryThreshold", "num" }, { "dryDecayMult", "num" }, { "rainBonusMult", "num" }, { "pressureMult", "num" },
    { "tuningDiseaseGrowth", "num" }, { "hybridLive", "bool" }, { "decayPerDay", "num" }, { "low", "num" },
}

S.current = S.current

function S.log(fmt, ...) SoilLogger.info("[CD15] " .. fmt, ...) end

function S.new(mission, model)
    local self = setmetatable({}, S_mt)
    self.mission = mission
    self.modelRef = model
    self.pending = nil          -- { attemptId, images, header, headerWritten, payloadWritten }
    self.loadedDir = nil        -- the loaded save's directory, read at install
    self.installHeader = nil    -- the soilData.xml header found on disk at install
    self.evidenceAtInstall = false
    self.barrierPassed = false
    self.loadedSeen = false     -- the selected backend delivered (or declared no) header
    self.loadedHeader = nil
    self.headerSource = nil
    self.decided = false
    self.diskHeader = nil       -- the header that describes the files on disk now
    self.quarantine = nil       -- { reason, originalAttemptId }
    self.spec = {
        beginAttempt = function(context) self:beginAttempt(context) end,
        freezeAfterCareerXML = function(context) return self:freezeAfterCareerXML(context) end,
        finishAttempt = function(context, errorCode, finalDir) self:finishAttempt(context, errorCode, finalDir) end,
    }
    return self
end

function S:model()
    local sfm = g_SoilFertilityManager
    local sys = sfm ~= nil and sfm.soilSystem or nil
    local m = sys ~= nil and sys.cd15 or nil
    if m ~= nil then return m end
    return self.modelRef
end

--- main.lua's loadedMission, right after the native save install, server only: the participant,
--- registered on Soil's boundary for this mission (which joins StockGuard's when it owns the
--- save), the disk evidence of the loaded save, the restore barrier, and the model held until
--- the restore decides. Returns the participant.
function S.installForMission(mission)
    if g_server == nil then return nil end
    local sfm = g_SoilFertilityManager
    local model = sfm ~= nil and sfm.soilSystem ~= nil and sfm.soilSystem.cd15 or nil
    if model == nil then return nil end
    if S.current ~= nil then S.current:close() end
    local self = S.new(mission, model)
    S.current = self
    model:awaitRestore()
    local mi = (mission ~= nil and mission.missionInfo) or nil
    self.loadedDir = mi ~= nil and mi.savegameDirectory or nil
    self:readInstallEvidence()
    local boundary = SoilNativeSave ~= nil and SoilNativeSave.current or nil
    if boundary ~= nil then
        local ok, registered, why = pcall(boundary.register, boundary, S.PARTICIPANT_ID, self.spec)
        if not ok or not registered then
            S.log("save participant not registered (%s); local disease saves carry no payload this mission", tostring(ok and why or registered))
        end
    else
        S.log("no native save boundary this mission; local disease saves carry no payload")
    end
    self:installFinishedLoadingObserver()
    return self
end

function S:close()
    self:removeFinishedLoadingObserver()
    if S.current == self then S.current = nil end
end

--- What the loaded save's directory holds of CD-15, before any backend delivers: the
--- soilData.xml header and whether a payload file exists.
function S:readInstallEvidence()
    local dir = self.loadedDir
    if type(dir) ~= "string" or dir == "" or fileExists == nil then return end
    local payload = fileExists(dir .. "/" .. S.PAYLOAD_FILE)
    local header = nil
    local path = dir .. "/soilData.xml"
    if loadXMLFile ~= nil and fileExists(path) then
        local x = loadXMLFile("sfCd15Evidence", path)
        if x ~= nil and x ~= 0 then
            local ok, h = pcall(S.readHeaderXML, x, S.HEADER_KEY)
            if ok then header = h end
            delete(x)
        end
    end
    self.installHeader = header
    self.evidenceAtInstall = payload == true or header ~= nil
end

-- ---------------------------------------------------------
-- The restore barrier (BaseMission:finishLoadingTask -> onFinishedLoading)
-- ---------------------------------------------------------
function S:installFinishedLoadingObserver()
    local mission = self.mission
    if mission == nil or type(mission.onFinishedLoading) ~= "function" or self.finishedLoadingWrapper ~= nil then
        -- No barrier to wait for (a mission already loaded, or none): the barrier counts as passed.
        self.barrierPassed = true
        return
    end
    local host = self
    local original = mission.onFinishedLoading
    local wrapper = function(m, ...)
        local results = { original(m, ...) }
        if host.mission == m and S.current == host then pcall(host.onBarrier, host) end
        return unpack(results)
    end
    self.finishedLoadingWrapper, self.finishedLoadingOriginal = wrapper, original
    mission.onFinishedLoading = wrapper
end

function S:removeFinishedLoadingObserver()
    local mission = self.mission
    if mission ~= nil and self.finishedLoadingWrapper ~= nil and mission.onFinishedLoading == self.finishedLoadingWrapper then
        mission.onFinishedLoading = self.finishedLoadingOriginal
    end
    self.finishedLoadingWrapper, self.finishedLoadingOriginal = nil, nil
end

function S:onBarrier()
    self.barrierPassed = true
    self:tryRestore()
end

--- loadSoilData's report of the header the selected backend holds (nil: none). Only the first
--- report of a mission counts: a later re-activation reads the same save again.
function S.noteLoadedHeader(header, source)
    local self = S.current
    if self == nil or self.loadedSeen then return end
    self.loadedSeen = true
    self.loadedHeader = header
    self.headerSource = source
    self:tryRestore()
end

--- loadSoilData's XML path: the header in the soilData.xml it loaded.
function S.noteLoadedXML(xmlFile)
    local ok, h = pcall(S.readHeaderXML, xmlFile, S.HEADER_KEY)
    if not ok then h = { schema = -1, status = "UNREADABLE" } end
    S.noteLoadedHeader(h, "XML")
end

function S:tryRestore()
    if self.decided or not self.barrierPassed or not self.loadedSeen then return end
    self.decided = true
    local ok, err = pcall(self.decide, self)
    if not ok then
        S.log("restore decision failed (%s)", tostring(err))
        self:enterQuarantine("RESTORE_ERROR", nil)
    end
end

-- ---------------------------------------------------------
-- The restore decision: header, payload and marker as one attempt (:85, :93, :101)
-- ---------------------------------------------------------
function S:decide()
    local model = self:model()
    if model == nil then return end
    local header = self.loadedHeader
    local dir = self.loadedDir
    local path = (type(dir) == "string" and dir ~= "") and (dir .. "/" .. S.PAYLOAD_FILE) or nil
    local payloadExists = path ~= nil and fileExists ~= nil and fileExists(path) == true
    if header == nil then
        if payloadExists then return self:enterQuarantine("ORPHAN_PAYLOAD", nil) end
        self.diskHeader = nil
        model:firstActivation()
        S.log("local disease: no earlier CD-15 evidence; the clean first-activation baseline (earlier history unavailable)")
        return
    end
    local h, why = S.validHeader(header)
    if h == nil then return self:enterQuarantine("HEADER_INVALID:" .. tostring(why), S.attemptOf(header)) end
    self.diskHeader = h
    if h.status == S.QUARANTINED then return self:enterQuarantine("CARRIED:" .. tostring(h.reason), h.originalAttemptId) end
    if SoilNativeSave ~= nil and SoilNativeSave.current ~= nil then SoilNativeSave.current:seedAttempt(h.attemptId) end
    if not model:ensureGeometry() then return self:enterQuarantine("GEOMETRY_UNAVAILABLE:" .. tostring(model.reason), h.attemptId) end
    if h.geometryFingerprint ~= model.geometry.fingerprint then return self:enterQuarantine("GEOMETRY_MISMATCH", h.attemptId) end
    if not payloadExists then return self:enterQuarantine("PAYLOAD_MISSING", h.attemptId) end
    local decoded, whyP = S.readPayload(path, h, model.geometry)
    if decoded == nil then return self:enterQuarantine(tostring(whyP), h.attemptId) end
    model:importSaved(decoded)
    S.log("local disease restored from attempt %d: %d cells, %d pending days, occurrence sequence %d",
        h.attemptId, decoded.store.count, #decoded.queue, decoded.occurrenceSeq)
end

function S:enterQuarantine(reason, originalAttemptId)
    self.quarantine = { reason = reason, originalAttemptId = originalAttemptId }
    local model = self:model()
    if model ~= nil then model:quarantine(reason) end
    S.log("local disease QUARANTINED (%s): the saved evidence did not form one valid attempt; nothing was restored or reinitialized", tostring(reason))
end

function S.attemptOf(h)
    if type(h) ~= "table" then return nil end
    local a = h.attemptId or h.originalAttemptId
    if CD15Grid.isInteger(a) then return a end
    return nil
end

-- ---------------------------------------------------------
-- The header
-- ---------------------------------------------------------
--- Validate a delivered header. Returns a normalized copy, or nil and the first failing field.
function S.validHeader(h)
    if type(h) ~= "table" then return nil, "NOT_TABLE" end
    if h.schema ~= S.SCHEMA then return nil, "SCHEMA:" .. tostring(h.schema) end
    local out = { schema = S.SCHEMA, status = h.status }
    if h.status == S.QUARANTINED then
        if type(h.reason) ~= "string" or h.reason == "" then return nil, "REASON" end
        if h.originalAttemptId ~= nil and not CD15Grid.isInteger(h.originalAttemptId) then return nil, "ORIGINAL_ATTEMPT" end
        out.reason, out.originalAttemptId = h.reason, h.originalAttemptId
        return out
    end
    if h.status ~= S.SAVED then return nil, "STATUS:" .. tostring(h.status) end
    if not CD15Grid.isInteger(h.attemptId) or h.attemptId < 1 then return nil, "ATTEMPT" end
    if type(h.geometryFingerprint) ~= "string" or h.geometryFingerprint == "" then return nil, "GEOMETRY" end
    if h.payloadFile ~= S.PAYLOAD_FILE then return nil, "PAYLOAD_FILE" end
    if type(h.images) ~= "table" then return nil, "IMAGES" end
    local n = h.imageCount or #h.images
    if not CD15Grid.isInteger(n) or n < 0 or n > S.MAX_IMAGES then return nil, "IMAGE_COUNT" end
    local seen, images = {}, {}
    for i = 1, n do
        local f = h.images[i]
        if type(f) ~= "string" or f == "" or seen[f] then return nil, "IMAGE:" .. i end
        seen[f] = true
        images[i] = f
    end
    out.attemptId, out.geometryFingerprint, out.payloadFile, out.images = h.attemptId, h.geometryFingerprint, h.payloadFile, images
    return out
end

function S.copyHeader(h)
    if h == nil then return nil end
    local out = {}
    for k, v in pairs(h) do
        if type(v) == "table" then
            local t = {}
            for i, f in ipairs(v) do t[i] = f end
            out[k] = t
        else
            out[k] = v
        end
    end
    return out
end

--- The header from StateLedger's block (a plain table, or nil).
function S.headerFromTable(t)
    if type(t) ~= "table" then return nil end
    return S.copyHeader(t)
end

--- Read the header at `key` of a loaded XML file. nil when no header attribute is there.
function S.readHeaderXML(x, key)
    local h = {
        schema = getXMLInt(x, key .. "#schema"),
        status = getXMLString(x, key .. "#status"),
        attemptId = getXMLInt(x, key .. "#attemptId"),
        geometryFingerprint = getXMLString(x, key .. "#geometryFingerprint"),
        payloadFile = getXMLString(x, key .. "#payloadFile"),
        reason = getXMLString(x, key .. "#reason"),
        originalAttemptId = getXMLInt(x, key .. "#originalAttemptId"),
        imageCount = getXMLInt(x, key .. ".images#count"),
        images = {},
    }
    if h.schema == nil and h.status == nil and h.attemptId == nil and h.geometryFingerprint == nil and h.payloadFile == nil
       and h.reason == nil and h.imageCount == nil then
        return nil
    end
    if CD15Grid.isInteger(h.imageCount) and h.imageCount >= 0 and h.imageCount <= S.MAX_IMAGES then
        for i = 1, h.imageCount do
            h.images[i] = getXMLString(x, string.format("%s.images.image(%d)#file", key, i - 1))
        end
    end
    return h
end

function S.writeHeaderXMLAt(x, key, h)
    setXMLInt(x, key .. "#schema", h.schema)
    setXMLString(x, key .. "#status", h.status)
    if h.attemptId ~= nil then setXMLInt(x, key .. "#attemptId", h.attemptId) end
    if h.geometryFingerprint ~= nil then setXMLString(x, key .. "#geometryFingerprint", h.geometryFingerprint) end
    if h.payloadFile ~= nil then setXMLString(x, key .. "#payloadFile", h.payloadFile) end
    if h.reason ~= nil then setXMLString(x, key .. "#reason", h.reason) end
    if h.originalAttemptId ~= nil then setXMLInt(x, key .. "#originalAttemptId", h.originalAttemptId) end
    if h.images ~= nil then
        setXMLInt(x, key .. ".images#count", #h.images)
        for i, f in ipairs(h.images) do setXMLString(x, string.format("%s.images.image(%d)#file", key, i - 1), f) end
    end
end

--- The header this save writes. Inside a native save it is the attempt's, composed once and
--- shared by both writers; outside one, the header that describes the files on disk.
function S:headerForSave()
    local p = self.pending
    if p ~= nil then
        if not p.composed then
            p.composed = true
            p.header = self:composeHeader(p)
        end
        return p.header
    end
    if self.decided then return self.diskHeader end
    return self.installHeader
end

function S:composeHeader(p)
    local model = self:model()
    local rs = model ~= nil and model.restoreState or nil
    if model ~= nil and model.failed ~= nil then return self:quarantineHeader("MODEL_FAILED:" .. tostring(model.failed)) end
    if rs == CD15Model.RESTORED or rs == CD15Model.FIRST_ACTIVATION then
        if model.geometry ~= nil then
            local files = {}
            for i, img in ipairs(p.images) do files[i] = img.nativeFilename end
            return { schema = S.SCHEMA, status = S.SAVED, attemptId = p.attemptId, geometryFingerprint = model.geometry.fingerprint,
                     payloadFile = S.PAYLOAD_FILE, images = files }
        end
        -- Never bound to a grid: nothing of this session is CD-15 state.
        if self.diskHeader == nil then return nil end
        return self:quarantineHeader("NOT_BOUND:" .. tostring(model.reason))
    end
    if rs == CD15Model.QUARANTINED then return self:quarantineHeader(nil) end
    -- The restore never decided this session (no backend delivered).
    if self.evidenceAtInstall or self.loadedHeader ~= nil then return self:quarantineHeader("NOT_RESTORED") end
    return nil
end

--- A QUARANTINED header: the session's own quarantine carried, or a new reason.
function S:quarantineHeader(reason)
    local q = self.quarantine
    local r, original
    if q ~= nil then
        r, original = q.reason, q.originalAttemptId
        -- A carried quarantine keeps its first reason.
        local carried = type(r) == "string" and r:match("^CARRIED:(.*)$") or nil
        if carried ~= nil then r = carried end
    else
        r = reason or "UNKNOWN"
        original = S.attemptOf(self.diskHeader) or S.attemptOf(self.installHeader)
    end
    return { schema = S.SCHEMA, status = S.QUARANTINED, reason = r, originalAttemptId = original }
end

--- saveSoilData's call, inside the career chain: the header into soilData.xml.
function S:writeHeaderXML(xmlFile)
    local h = self:headerForSave()
    if h ~= nil then S.writeHeaderXMLAt(xmlFile, S.HEADER_KEY, h) end
    if self.pending ~= nil then self.pending.headerWritten = h ~= nil end
end

-- ---------------------------------------------------------
-- The participant
-- ---------------------------------------------------------
--- Every distinct actual fruit and haulm image, deduplicated by native filename as the
--- controller does (SavegameController.lua:392-424), sorted by filename.
function S.imageList(mission)
    local out = {}
    if SoilNativeSave == nil then return out end
    for filename, n in pairs(SoilNativeSave.nativeImageSet(mission)) do
        if n.kind == "FRUIT" or n.kind == "HAULM" then out[#out + 1] = { mapId = n.mapId, nativeFilename = filename } end
    end
    table.sort(out, function(a, b) return a.nativeFilename < b.nativeFilename end)
    return out
end

function S:beginAttempt(context)
    self.pending = { attemptId = context.attemptId, images = S.imageList(context.mission or self.mission or g_currentMission),
                     composed = false, header = nil, headerWritten = false, payloadWritten = false }
end

function S:freezeAfterCareerXML(context)
    local p = self.pending
    if p == nil or p.attemptId ~= context.attemptId then return { state = S.UNAVAILABLE, reason = "NO_ATTEMPT" } end
    local h = p.header
    if not p.composed or h == nil then return { state = S.UNAVAILABLE, reason = "NO_HEADER" } end
    if h.status ~= S.SAVED then return { state = S.UNAVAILABLE, reason = h.status } end
    if not p.headerWritten then return { state = S.UNAVAILABLE, reason = "HEADER_NOT_WRITTEN" } end
    local model = self:model()
    if model == nil or model.geometry == nil or model.geometry.fingerprint ~= h.geometryFingerprint then return { state = S.UNAVAILABLE, reason = "GEOMETRY" } end
    local save = context.careerSave
    local dir = (save ~= nil and save.savegameDirectory) or context.stagingDirectory
    if type(dir) ~= "string" or dir == "" then return { state = S.UNAVAILABLE, reason = "NO_DIRECTORY" } end
    local ok, why = S.writePayload(dir .. "/" .. S.PAYLOAD_FILE, h, model)
    if not ok then return { state = S.UNAVAILABLE, reason = "PAYLOAD:" .. tostring(why) } end
    p.payloadWritten = true
    local images = {}
    for i, img in ipairs(p.images) do images[i] = { mapId = img.mapId, nativeFilename = img.nativeFilename } end
    return { state = S.READY, payloadFile = S.PAYLOAD_FILE, images = images }
end

function S:finishAttempt(context, errorCode, finalDir)
    local p = self.pending
    if p == nil or p.attemptId ~= context.attemptId then return end
    self.pending = nil
    local ok = Savegame ~= nil and errorCode == Savegame.ERROR_OK
    local mine = context.results ~= nil and context.results[S.PARTICIPANT_ID] or nil
    local reason = nil
    if not ok then reason = "SAVE_FAILED:" .. tostring(errorCode)
    elseif type(finalDir) ~= "string" or finalDir == "" then reason = "NO_FINAL_DIRECTORY"
    elseif mine == nil or mine.state ~= S.READY then reason = "NOT_READY:" .. tostring(mine and mine.reason)
    elseif not p.payloadWritten then reason = "NO_PAYLOAD"
    end
    if reason == nil then
        local okM, why = S.writeCompletion(finalDir .. "/" .. S.PAYLOAD_FILE, p.attemptId)
        if not okM then reason = "MARKER:" .. tostring(why) end
    end
    -- What the disk holds now: a completed save wrote this attempt's soilData.xml.
    if ok and type(finalDir) == "string" and finalDir ~= "" then
        self.diskHeader = p.headerWritten and p.header or nil
    end
    self.lastFinish = { attemptId = p.attemptId, written = reason == nil, reason = reason }
    if reason ~= nil and p.header ~= nil and p.header.status == S.SAVED then
        S.log("attempt %s: no local disease completion (%s); this save's local disease loads quarantined", tostring(p.attemptId), reason)
    end
end

--- The completion, in soilDisease.xml in the FINAL directory.
function S.writeCompletion(path, attemptId)
    if loadXMLFile == nil then return false, "NO_XML" end
    if fileExists ~= nil and not fileExists(path) then return false, "PAYLOAD_NOT_IN_FINAL_DIRECTORY" end
    local x = loadXMLFile("sfCd15Marker", path)
    if x == nil or x == 0 then return false, "LOAD" end
    if getXMLInt(x, S.ROOT .. "#attemptId") ~= attemptId then
        delete(x)
        return false, "ATTEMPT_MISMATCH"
    end
    setXMLInt(x, S.ROOT .. "#completeAttemptId", attemptId)
    local saved = saveXMLFile(x)
    delete(x)
    if saved == false then return false, "SAVE" end
    return true
end

-- ---------------------------------------------------------
-- The payload (:218)
-- ---------------------------------------------------------
function S.num(v) return string.format("%.17g", v) end
function S.bool(v) return v and "true" or "false" end

function S.sortedNames(map)
    local names = {}
    for k in pairs(map or {}) do names[#names + 1] = k end
    table.sort(names)
    return names
end

function S.writeModeMap(x, prefix, map, valueAttr)
    local names = S.sortedNames(map)
    setXMLInt(x, prefix .. "#count", #names)
    for i, name in ipairs(names) do
        local base = string.format("%s.m(%d)", prefix, i - 1)
        setXMLString(x, base .. "#name", name)
        setXMLString(x, base .. "#" .. valueAttr, S.num(map[name]))
    end
end

function S.writeInput(x, base, input)
    for _, f in ipairs(S.INPUT_FIELDS) do
        local v = input[f[1]]
        if v ~= nil then
            if f[2] == "bool" then setXMLString(x, base .. "#" .. f[1], S.bool(v)) else setXMLString(x, base .. "#" .. f[1], S.num(v)) end
        end
    end
end

function S.writeCell(x, base, c)
    if c.cropName ~= nil then setXMLString(x, base .. "#cropName", c.cropName) end
    if c.cropOccurrence ~= nil then setXMLString(x, base .. "#cropOccurrence", c.cropOccurrence) end
    if c.lastResetOccurrence ~= nil then setXMLString(x, base .. "#lastResetOccurrence", c.lastResetOccurrence) end
    if c.diseaseName ~= nil then setXMLString(x, base .. "#diseaseName", c.diseaseName) end
    setXMLString(x, base .. "#pressure", S.num(c.pressure))
    if c.hybridCooldownExpiryDay ~= nil then setXMLString(x, base .. "#hybridCooldownExpiryDay", S.num(c.hybridCooldownExpiryDay)) end
    setXMLString(x, base .. "#discovered", S.bool(c.discovered))
    if c.lastSettledDay ~= nil then setXMLString(x, base .. "#lastSettledDay", S.num(c.lastSettledDay)) end
    setXMLString(x, base .. "#sourceRevision", S.num(c.sourceRevision))
    setXMLString(x, base .. "#dryDayCount", S.num(c.dryDayCount))
    setXMLString(x, base .. "#geometryFingerprint", c.geometryFingerprint)
    setXMLInt(x, base .. ".history#count", #c.cropHistory)
    for i, h in ipairs(c.cropHistory) do
        local hb = string.format("%s.history.h(%d)", base, i - 1)
        setXMLString(x, hb .. "#occurrenceId", h.occurrenceId)
        setXMLString(x, hb .. "#cropName", h.cropName)
    end
    S.writeModeMap(x, base .. ".resistance", c.resistance, "score")
    S.writeModeMap(x, base .. ".protection", c.protection, "expiry")
    local t = c.dailyTreatment
    if t ~= nil then
        setXMLString(x, base .. ".treatment#day", S.num(t.day))
        setXMLString(x, base .. ".treatment#reduction", S.num(t.reduction))
        S.writeModeMap(x, base .. ".treatment.dose", t.doseByMode or {}, "dose")
        local ops = {}
        for _, id in ipairs(t.operationIds) do ops[#ops + 1] = id end
        -- A list is the saved form; anything else would be lost silently, so the encode refuses
        -- (the participant is then UNAVAILABLE for that save, never a payload missing ids).
        local n = 0
        for _ in pairs(t.operationIds) do n = n + 1 end
        if n ~= #ops then error("OPERATION_IDS_NOT_A_LIST") end
        setXMLInt(x, base .. ".treatment.ops#count", #ops)
        for i, id in ipairs(ops) do setXMLString(x, string.format("%s.treatment.ops.op(%d)#id", base, i - 1), id) end
    end
    local w = c.nativeCropWitness
    if w ~= nil then
        local names = S.sortedNames(w)
        setXMLInt(x, base .. ".witness#count", #names)
        for i, name in ipairs(names) do
            local v = w[name]
            local fb = string.format("%s.witness.f(%d)", base, i - 1)
            local kind = type(v)
            if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then error("WITNESS_FIELD:" .. name) end
            setXMLString(x, fb .. "#name", name)
            setXMLString(x, fb .. "#type", kind)
            setXMLString(x, fb .. "#value", (kind == "number" and S.num(v)) or (kind == "boolean" and S.bool(v)) or v)
        end
    end
end

function S.encodePayload(x, h, model)
    local R = S.ROOT
    local work = model:exportWork()
    setXMLString(x, R .. "#namespace", CD15Grid.NAMESPACE)
    setXMLInt(x, R .. "#schema", S.SCHEMA)
    setXMLInt(x, R .. "#attemptId", h.attemptId)
    setXMLString(x, R .. "#geometryFingerprint", h.geometryFingerprint)
    setXMLString(x, R .. "#occurrenceSeq", S.num(work.occurrenceSeq))
    setXMLString(x, R .. "#discoveryCursor", S.num(work.discoveryCursor))
    if work.lastDay ~= nil then setXMLString(x, R .. "#lastDay", S.num(work.lastDay)) end
    if work.lastClosedDay ~= nil then setXMLString(x, R .. "#lastClosedDay", S.num(work.lastClosedDay)) end
    setXMLInt(x, R .. ".gaps#count", #work.gaps)
    for i, g in ipairs(work.gaps) do
        local gb = string.format("%s.gaps.gap(%d)", R, i - 1)
        setXMLString(x, gb .. "#from", S.num(g.from))
        setXMLString(x, gb .. "#to", S.num(g.to))
        setXMLString(x, gb .. "#reason", tostring(g.reason))
    end
    setXMLInt(x, R .. ".queue#count", #work.queue)
    for i, w in ipairs(work.queue) do
        local wb = string.format("%s.queue.work(%d)", R, i - 1)
        setXMLString(x, wb .. "#phase", w.phase)
        S.writeInput(x, wb .. ".input", w.input)
        if w.phase == "SPREAD" then
            setXMLString(x, wb .. "#scursor", S.num(w.scursor))
            setXMLInt(x, wb .. ".sources#count", #w.sources)
            for j, s in ipairs(w.sources) do
                local sb = string.format("%s.sources.source(%d)", wb, j - 1)
                setXMLString(x, sb .. "#gx", S.num(s.gx))
                setXMLString(x, sb .. "#gz", S.num(s.gz))
                setXMLString(x, sb .. "#diseaseName", s.diseaseName)
                S.writeModeMap(x, sb .. ".resistance", s.resistance, "score")
            end
        end
    end
    -- Tiles by tz then tx, populated keys ascending (:216).
    local tiles = {}
    for _, tile in pairs(model.store.tiles) do tiles[#tiles + 1] = tile end
    table.sort(tiles, function(a, b) if a.tz ~= b.tz then return a.tz < b.tz end return a.tx < b.tx end)
    setXMLInt(x, R .. ".tiles#count", #tiles)
    for i, tile in ipairs(tiles) do
        local tb = string.format("%s.tiles.tile(%d)", R, i - 1)
        setXMLString(x, tb .. "#tx", S.num(tile.tx))
        setXMLString(x, tb .. "#tz", S.num(tile.tz))
        setXMLInt(x, tb .. "#count", #tile.keys)
        for j, k in ipairs(tile.keys) do
            local cb = string.format("%s.cell(%d)", tb, j - 1)
            setXMLString(x, cb .. "#key", S.num(k))
            S.writeCell(x, cb, tile.cells[k])
        end
    end
end

function S.writePayload(path, h, model)
    if createXMLFile == nil or saveXMLFile == nil then return false, "NO_XML" end
    local x = createXMLFile("sfCd15Payload", path, S.ROOT)
    if x == nil or x == 0 then return false, "CREATE" end
    local ok, err = pcall(S.encodePayload, x, h, model)
    if not ok then
        delete(x)
        return false, "ENCODE:" .. tostring(err)
    end
    local saved = saveXMLFile(x)
    delete(x)
    if saved == false then return false, "SAVE" end
    return true
end

--- A decoder over one loaded payload: each read either returns a valid value or raises
--- { cd15 = reason }, caught by readPayload.
function S.decoder(x)
    local d = {}
    function d.fail(why) error({ cd15 = why }, 0) end
    function d.str(path) return getXMLString(x, path) end
    function d.reqStr(path, maxBytes)
        local v = getXMLString(x, path)
        if type(v) ~= "string" or v == "" or #v > (maxBytes or 256) then d.fail("STRING:" .. path) end
        return v
    end
    function d.optStr(path, maxBytes)
        local v = getXMLString(x, path)
        if v == nil then return nil end
        if v == "" or #v > (maxBytes or 256) then d.fail("STRING:" .. path) end
        return v
    end
    function d.optNum(path)
        local s = getXMLString(x, path)
        if s == nil then return nil end
        local v = tonumber(s)
        if not CD15Grid.isFinite(v) then d.fail("NUMBER:" .. path) end
        return v
    end
    function d.reqNum(path)
        local v = d.optNum(path)
        if v == nil then d.fail("NUMBER:" .. path) end
        return v
    end
    function d.optInt(path)
        local v = d.optNum(path)
        if v ~= nil and not CD15Grid.isInteger(v) then d.fail("INTEGER:" .. path) end
        return v
    end
    function d.reqInt(path)
        local v = d.reqNum(path)
        if not CD15Grid.isInteger(v) then d.fail("INTEGER:" .. path) end
        return v
    end
    function d.reqBool(path)
        local s = getXMLString(x, path)
        if s == "true" then return true elseif s == "false" then return false end
        d.fail("BOOL:" .. path)
    end
    function d.count(path, max)
        local n = getXMLInt(x, path)
        if not CD15Grid.isInteger(n) or n < 0 or n > max then d.fail("COUNT:" .. path) end
        return n
    end
    --- A sorted mode map: names strictly ascending (unique), values by `check`.
    function d.modeMap(prefix, valueAttr, check)
        local n = d.count(prefix .. "#count", 4096)
        local out, last = {}, nil
        for i = 0, n - 1 do
            local base = string.format("%s.m(%d)", prefix, i)
            local name = d.reqStr(base .. "#name", 64)
            if last ~= nil and not (name > last) then d.fail("MODE_ORDER:" .. prefix) end
            local v = d.reqNum(base .. "#" .. valueAttr)
            if not check(v) then d.fail("MODE_VALUE:" .. prefix) end
            out[name], last = v, name
        end
        return out
    end
    return d
end

function S.readCell(d, base)
    local c = {
        cropName = d.optStr(base .. "#cropName", 64),
        cropHistory = {},
        cropOccurrence = d.optStr(base .. "#cropOccurrence", 128),
        lastResetOccurrence = d.optStr(base .. "#lastResetOccurrence", 128),
        diseaseName = d.optStr(base .. "#diseaseName", 64),
        pressure = d.reqNum(base .. "#pressure"),
        hybridCooldownExpiryDay = d.optInt(base .. "#hybridCooldownExpiryDay"),
        discovered = d.reqBool(base .. "#discovered"),
        lastSettledDay = d.optInt(base .. "#lastSettledDay"),
        sourceRevision = d.reqInt(base .. "#sourceRevision"),
        dryDayCount = d.reqInt(base .. "#dryDayCount"),
        geometryFingerprint = d.reqStr(base .. "#geometryFingerprint", 256),
    }
    local nh = d.count(base .. ".history#count", CD15Grid.HISTORY_MAX)
    for i = 0, nh - 1 do
        local hb = string.format("%s.history.h(%d)", base, i)
        c.cropHistory[i + 1] = { occurrenceId = d.reqStr(hb .. "#occurrenceId", 128), cropName = d.reqStr(hb .. "#cropName", 64) }
    end
    c.resistance = d.modeMap(base .. ".resistance", "score", function(v) return v >= 0 end)
    c.protection = d.modeMap(base .. ".protection", "expiry", CD15Grid.isInteger)
    if d.str(base .. ".treatment#day") ~= nil then
        local t = { day = d.reqInt(base .. ".treatment#day"), reduction = d.reqNum(base .. ".treatment#reduction"), operationIds = {} }
        t.doseByMode = d.modeMap(base .. ".treatment.dose", "dose", function(v) return v >= 0 end)
        local n = d.count(base .. ".treatment.ops#count", S.MAX_OPS)
        local seen = {}
        for i = 0, n - 1 do
            local id = d.reqStr(string.format("%s.treatment.ops.op(%d)#id", base, i), 128)
            if seen[id] then d.fail("DUPLICATE_OPERATION:" .. base) end
            seen[id] = true
            t.operationIds[i + 1] = id
        end
        c.dailyTreatment = t
    end
    if d.str(base .. ".witness.f(0)#name") ~= nil or d.str(base .. ".witness#count") ~= nil then
        local n = d.count(base .. ".witness#count", 64)
        local w, last = {}, nil
        for i = 0, n - 1 do
            local fb = string.format("%s.witness.f(%d)", base, i)
            local name = d.reqStr(fb .. "#name", 64)
            if last ~= nil and not (name > last) then d.fail("WITNESS_ORDER:" .. base) end
            local kind = d.reqStr(fb .. "#type", 16)
            local v
            if kind == "number" then v = d.reqNum(fb .. "#value")
            elseif kind == "boolean" then v = d.reqBool(fb .. "#value")
            elseif kind == "string" then v = d.reqStr(fb .. "#value", 256)
            else d.fail("WITNESS_TYPE:" .. base) end
            w[name], last = v, name
        end
        c.nativeCropWitness = w
    end
    return c
end

function S.readInput(d, base)
    local input = {}
    for _, f in ipairs(S.INPUT_FIELDS) do
        local path = base .. "#" .. f[1]
        if f[2] == "bool" then input[f[1]] = d.reqBool(path)
        elseif f[2] == "int" then input[f[1]] = d.reqInt(path)
        elseif f[2] == "optint" then input[f[1]] = d.optInt(path)
        else input[f[1]] = d.reqNum(path) end
    end
    if input.daysPerMonth <= 0 then d.fail("DAYS_PER_MONTH:" .. base) end
    return input
end

--- Decode and validate the whole payload against its header and the live geometry before
--- anything is applied. Returns { store, lastDay, lastClosedDay, gaps, queue, occurrenceSeq,
--- discoveryCursor }, or nil and the reason.
function S.decodePayload(x, h, geom)
    local d = S.decoder(x)
    local R = S.ROOT
    if d.str(R .. "#namespace") ~= CD15Grid.NAMESPACE then d.fail("NAMESPACE") end
    if getXMLInt(x, R .. "#schema") ~= S.SCHEMA then d.fail("PAYLOAD_SCHEMA") end
    if getXMLInt(x, R .. "#attemptId") ~= h.attemptId then d.fail("ATTEMPT_MISMATCH") end
    if getXMLInt(x, R .. "#completeAttemptId") ~= h.attemptId then d.fail("NOT_COMPLETE") end
    if d.str(R .. "#geometryFingerprint") ~= h.geometryFingerprint or h.geometryFingerprint ~= geom.fingerprint then d.fail("GEOMETRY_MISMATCH") end
    local out = {
        occurrenceSeq = d.reqInt(R .. "#occurrenceSeq"),
        discoveryCursor = d.reqInt(R .. "#discoveryCursor"),
        lastDay = d.optInt(R .. "#lastDay"),
        lastClosedDay = d.optInt(R .. "#lastClosedDay"),
        gaps = {}, queue = {},
    }
    if out.occurrenceSeq < 0 or out.discoveryCursor < 0 then d.fail("CURSOR") end
    local ng = d.count(R .. ".gaps#count", CD15Model.GAPS_KEPT)
    for i = 0, ng - 1 do
        local gb = string.format("%s.gaps.gap(%d)", R, i)
        out.gaps[i + 1] = { from = d.reqInt(gb .. "#from"), to = d.reqInt(gb .. "#to"), reason = d.reqStr(gb .. "#reason", 128) }
    end
    -- The cells.
    local store = CD15Grid.newStore()
    local perSide = math.ceil(geom.resolution / CD15Grid.TILE)
    local nt = d.count(R .. ".tiles#count", perSide * perSide)
    local lastTz, lastTx = nil, nil
    for i = 0, nt - 1 do
        local tb = string.format("%s.tiles.tile(%d)", R, i)
        local tx, tz = d.reqInt(tb .. "#tx"), d.reqInt(tb .. "#tz")
        if tx < 0 or tz < 0 or tx >= perSide or tz >= perSide then d.fail("TILE_RANGE") end
        if lastTz ~= nil and (tz < lastTz or (tz == lastTz and tx <= lastTx)) then d.fail("TILE_ORDER") end
        lastTz, lastTx = tz, tx
        local nc = d.count(tb .. "#count", CD15Grid.TILE * CD15Grid.TILE)
        if nc == 0 then d.fail("EMPTY_TILE") end
        local lastKey = nil
        for j = 0, nc - 1 do
            local cb = string.format("%s.cell(%d)", tb, j)
            local k = d.reqInt(cb .. "#key")
            if k < 0 or k >= CD15Grid.TILE * CD15Grid.TILE then d.fail("KEY_RANGE") end
            if lastKey ~= nil and k <= lastKey then d.fail("KEY_ORDER") end
            lastKey = k
            local c = S.readCell(d, cb)
            if c.geometryFingerprint ~= geom.fingerprint then d.fail("CELL_GEOMETRY") end
            local gx, gz = CD15Grid.cellOf(tx, tz, k)
            if not CD15Grid.onGrid(geom, gx, gz) then d.fail("CELL_OFF_GRID") end
            local okPut, why = store:put(gx, gz, c)
            if not okPut then d.fail("CELL:" .. tostring(why)) end
        end
    end
    out.store = store
    -- The day work.
    local nq = d.count(R .. ".queue#count", S.MAX_QUEUE)
    for i = 0, nq - 1 do
        local wb = string.format("%s.queue.work(%d)", R, i)
        local phase = d.reqStr(wb .. "#phase", 16)
        if phase ~= "SETTLE" and phase ~= "SPREAD" then d.fail("PHASE") end
        local w = { phase = phase, input = S.readInput(d, wb .. ".input") }
        if phase == "SPREAD" then
            local ns = d.count(wb .. ".sources#count", store.count)
            w.sources = {}
            for j = 0, ns - 1 do
                local sb = string.format("%s.sources.source(%d)", wb, j)
                local gx, gz = d.reqInt(sb .. "#gx"), d.reqInt(sb .. "#gz")
                if not CD15Grid.onGrid(geom, gx, gz) then d.fail("SOURCE_OFF_GRID") end
                local name = d.reqStr(sb .. "#diseaseName", 64)
                if not CD15Grid.isDiseaseName(name) then d.fail("SOURCE_DISEASE") end
                local tx, tz, k = CD15Grid.tileOf(gx, gz)
                w.sources[j + 1] = { gx = gx, gz = gz, tx = tx, tz = tz, localKey = k, diseaseName = name,
                                     resistance = d.modeMap(sb .. ".resistance", "score", function(v) return v >= 0 end) }
            end
            w.scursor = d.reqInt(wb .. "#scursor")
            if w.scursor < 1 or w.scursor > ns + 1 then d.fail("SPREAD_CURSOR") end
        end
        out.queue[i + 1] = w
    end
    return out
end

function S.readPayload(path, h, geom)
    if loadXMLFile == nil then return nil, "NO_XML" end
    local x = loadXMLFile("sfCd15Payload", path)
    if x == nil or x == 0 then return nil, "PAYLOAD_UNREADABLE" end
    local ok, result = pcall(S.decodePayload, x, h, geom)
    delete(x)
    if ok then return result end
    if type(result) == "table" and result.cd15 ~= nil then return nil, "PAYLOAD:" .. tostring(result.cd15) end
    return nil, "PAYLOAD_ERROR:" .. tostring(result)
end
