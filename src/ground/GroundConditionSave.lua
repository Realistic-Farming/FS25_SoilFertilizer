-- =========================================================
-- FS25_SoilFertilizer - the ground-condition save participant (GROUND-CONDITION-CONTRACT 6)
-- =========================================================
-- GCC v1.5 section 6 (:96): "All condition/membership/availability saves participate in the
-- same Soil save boundary and the coordinated native physical snapshot ... Failure to pair
-- condition with the relevant physical snapshot is unavailable, not a fresh profile or
-- evidence that material disappeared." This is the participant that pairs Soil's condition
-- layers (materialAge, materialWetness and the ground membership index, written by
-- saveSoilData inside the career XML chain) with the terrain height image of the same save,
-- on whichever native save boundary owns the save: Soil's own (SoilNativeSave) or
-- StockGuard's SG_NATIVE_MATERIAL_SAVE_V1, which Soil joins (SG-2 :818-830).
--
-- THE STAMP. Every soilData.xml this build writes carries soilData.nativeSave#schema = 1,
-- whatever happens; an attempt that began also writes #attemptId. At the attempt's result,
-- on success, #completeAttemptId is written into soilData.xml in the FINAL directory, never
-- the staging one. A save before this build has no stamp and loads as it always has
-- (legacy). A stamped save is PAIRED only when its attempt and its completion agree;
-- otherwise it is UNPAIRED, including a save no boundary ran for (Bob's condition on B5: a
-- boundary whose hooks are dead must not make a save read as legacy).
--
-- THE IMAGES. On Soil's own boundary the participant names the height image, and the
-- boundary prepares it in the same call. Joined to StockGuard it names none: Soil condition
-- "shares SG2's height association ... it does not request another height prepare" (SG-2
-- :824), and a second claim on the same file would invalidate both (StockGuard
-- SGNativeMaterialSave.lua:382). So, joined, the completion also requires StockGuard's own
-- ground participant (sg2Ground) READY in that attempt: otherwise nothing paired the height
-- image with this attempt.
--
-- ON RELOAD the verdict is read at install (loadMission00Finished), from the directory
-- MaterialDown's sidecar is read from at the same point, before the store decides at mission
-- start (YardLadder.lua:246, GroundConditionCoordinator.lua:692); loadSoilData runs after that
-- decision (SoilFertilityManager.lua:590 before :649), too late to read it. An UNPAIRED save
-- marks every condition cell unavailable through the coordinator's availability overlay
-- (GCC :31) when the store decides: the bytes are kept, never cleared (:96, :62).
--
-- OUT-OF-BAND SAVES. saveSoilData also runs outside any native save, from five console
-- commands (SoilSettingsGUI.lua:70-77: SoilSaveData, soilSetState, soilRecoverField,
-- SoilRerollFields, SoilRerollUnownedFields): it rewrites the layers in the live savegame
-- directory at a moment no height image describes. (The version dialog's "don't show again"
-- writes lastSeenVersion alone, in place: SoilFertilityManager:persistLastSeenVersion.) Such a soilData.xml carries the
-- stamp and no attempt, and loads UNPAIRED: the layers on disk no longer pair with the
-- height image (:96). A normal save afterwards pairs them again.
-- =========================================================

GroundConditionSave = GroundConditionSave or {}
local S = GroundConditionSave
local S_mt = { __index = S }

S.PARTICIPANT_ID = "soilGroundCondition"
S.SG2_GROUND = "sg2Ground"          -- StockGuard's ground participant (SGGround.lua:49)
S.SCHEMA = 1
S.KEY = "soilData.nativeSave"
S.PAYLOAD_FILE = "soilData.xml"
S.LEGACY, S.PAIRED, S.UNPAIRED = "LEGACY", "PAIRED", "UNPAIRED"
S.READY, S.UNAVAILABLE = "READY", "UNAVAILABLE"
S.UNPAIRED_REASON = "NATIVE_SAVE_UNPAIRED"

S.current = S.current
S.lastVerdict = S.lastVerdict

local function log(fmt, ...) SoilLogger.info("[NativeSave] " .. fmt, ...) end

function S.new(mission)
    local self = setmetatable({}, S_mt)
    self.mission = mission
    self.pending = nil      -- { attemptId, own, wrote, layers }
    self.spec = {
        beginAttempt = function(context) self:beginAttempt(context) end,
        freezeAfterCareerXML = function(context) return self:freezeAfterCareerXML(context) end,
        finishAttempt = function(context, errorCode, finalDir) self:finishAttempt(context, errorCode, finalDir) end,
    }
    return self
end

--- The install main.lua runs at loadMission00Finished, server only: the boundary for this
--- mission with this participant on it, decided by SoilNativeSave:installForMission (Soil's
--- own, or StockGuard's when it has the capability). Returns the boundary and participant.
function S.installForMission(mission)
    S.lastVerdict = nil     -- module state outlives a mission: never apply another load's verdict
    if g_server == nil or SoilNativeSave == nil then return nil end
    local boundary = SoilNativeSave.new(mission)
    boundary:activate()
    S.noteSavedVerdict(mission)
    local condition = S.new(mission)
    condition:activate()
    boundary:register(S.PARTICIPANT_ID, condition.spec)
    boundary:installForMission({ SavegameController = SavegameController })
    return boundary, condition
end

function S:activate() S.current = self end
function S:close()
    if S.current == self then S.current = nil end
    S.lastVerdict = nil
end

-- ---------------------------------------------------------
-- The participant
-- ---------------------------------------------------------
function S:beginAttempt(context)
    self.pending = { attemptId = context.attemptId, own = context.ownBoundary == true, wrote = false, layers = false }
end

--- Called by saveSoilData inside the chain, before soilData.xml is written: the stamp, and
--- this attempt's id on the first soilData.xml of the attempt. `layersSaved` is whether the
--- membership, age and wetness layers all saved this call.
function S:stampSoilData(xmlFile, layersSaved)
    setXMLInt(xmlFile, S.KEY .. "#schema", S.SCHEMA)
    local p = self.pending
    if p ~= nil and not p.wrote then
        setXMLInt(xmlFile, S.KEY .. "#attemptId", p.attemptId)
        p.wrote = true
        p.layers = layersSaved == true
    end
end

function S:freezeAfterCareerXML(context)
    local p = self.pending
    if p == nil or p.attemptId ~= context.attemptId then return { state = S.UNAVAILABLE, reason = "NO_ATTEMPT" } end
    if not p.wrote then return { state = S.UNAVAILABLE, reason = "NO_SOIL_DATA" } end
    if not p.layers then return { state = S.UNAVAILABLE, reason = "LAYERS_NOT_SAVED" } end
    local images = {}
    if p.own then
        local mission = context.mission or self.mission or g_currentMission
        local id = mission ~= nil and mission.terrainDetailHeightId or nil
        local file = id ~= nil and getDensityMapFilename ~= nil and getDensityMapFilename(id) or nil
        if id == nil or type(file) ~= "string" or file == "" then return { state = S.UNAVAILABLE, reason = "NO_HEIGHT_IMAGE" } end
        images[1] = { mapId = id, nativeFilename = file }
    end
    return { state = S.READY, payloadFile = S.PAYLOAD_FILE, images = images }
end

function S:finishAttempt(context, errorCode, finalDir)
    local p = self.pending
    if p == nil or p.attemptId ~= context.attemptId then return end
    self.pending = nil
    local results = context.results or {}
    local mine = results[S.PARTICIPANT_ID]
    local reason = nil
    if Savegame == nil or errorCode ~= Savegame.ERROR_OK then reason = "SAVE_FAILED:" .. tostring(errorCode)
    elseif type(finalDir) ~= "string" or finalDir == "" then reason = "NO_FINAL_DIRECTORY"
    elseif mine == nil or mine.state ~= S.READY then reason = "NOT_READY:" .. tostring(mine and mine.reason)
    elseif not p.own then
        local g = results[S.SG2_GROUND]
        if g == nil or g.state ~= S.READY then reason = "STOCKGUARD_GROUND_NOT_READY:" .. tostring(g and (g.reason or g.state)) end
    end
    if reason == nil then
        local ok, why = S.writeCompletion(finalDir .. "/" .. S.PAYLOAD_FILE, p.attemptId)
        if not ok then reason = "MARKER:" .. tostring(why) end
    end
    self.lastFinish = { attemptId = p.attemptId, written = reason == nil, reason = reason }
    if reason ~= nil then
        log("attempt %s: no ground-condition completion (%s); the condition of this save is unavailable on load", tostring(p.attemptId), reason)
    end
end

--- The completion, in soilData.xml in the FINAL directory.
function S.writeCompletion(path, attemptId)
    if loadXMLFile == nil then return false, "NO_XML" end
    if fileExists ~= nil and not fileExists(path) then return false, "SOIL_DATA_NOT_IN_FINAL_DIRECTORY" end
    local xmlFile = loadXMLFile("sfNativeSave", path)
    if xmlFile == nil or xmlFile == 0 then return false, "LOAD" end
    if getXMLInt(xmlFile, S.KEY .. "#attemptId") ~= attemptId then
        delete(xmlFile)
        return false, "ATTEMPT_MISMATCH"
    end
    setXMLInt(xmlFile, S.KEY .. "#completeAttemptId", attemptId)
    local saved = saveXMLFile(xmlFile)
    delete(xmlFile)
    if saved == false then return false, "SAVE" end
    return true
end

-- ---------------------------------------------------------
-- The load verdict
-- ---------------------------------------------------------
--- Read the stamp of a loaded soilData.xml. Returns { state, reason, attemptId, completeAttemptId }.
function S.readVerdict(xmlFile)
    local schema = getXMLInt(xmlFile, S.KEY .. "#schema")
    if schema == nil then return { state = S.LEGACY } end
    local attempt = getXMLInt(xmlFile, S.KEY .. "#attemptId")
    local complete = getXMLInt(xmlFile, S.KEY .. "#completeAttemptId")
    local v = { attemptId = attempt, completeAttemptId = complete }
    if schema ~= S.SCHEMA then v.state, v.reason = S.UNPAIRED, "SCHEMA:" .. tostring(schema)
    elseif attempt == nil then v.state, v.reason = S.UNPAIRED, "NO_ATTEMPT"
    elseif complete ~= attempt then v.state, v.reason = S.UNPAIRED, "NOT_COMPLETE"
    else v.state = S.PAIRED end
    return v
end

--- Read the loaded save's soilData.xml stamp and note it. No file (a new career): nothing.
function S.noteSavedVerdict(mission)
    local mi = (mission ~= nil and mission.missionInfo) or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or loadXMLFile == nil or fileExists == nil then return nil end
    local path = dir .. "/" .. S.PAYLOAD_FILE
    if not fileExists(path) then return nil end
    local xmlFile = loadXMLFile("sfNativeSaveVerdict", path)
    if xmlFile == nil or xmlFile == 0 then return nil end
    local ok, verdict = pcall(S.readVerdict, xmlFile)
    delete(xmlFile)
    if not ok or type(verdict) ~= "table" then return nil end
    S.noteLoad(verdict)
    return verdict
end

--- Record the verdict of this load, and seed the boundary's attempt ids past it.
function S.noteLoad(verdict)
    S.lastVerdict = verdict
    if SoilNativeSave ~= nil and SoilNativeSave.current ~= nil then
        SoilNativeSave.current:seedAttempt(math.max(verdict.attemptId or 0, verdict.completeAttemptId or 0))
    end
    if verdict.state == S.UNPAIRED then
        log("soilData.xml did not pair with its height image (%s); ground condition loads unavailable", tostring(verdict.reason))
    end
end

--- The coordinator's overlay decided: an UNPAIRED load marks every member cell unavailable.
--- Returns how many runs were marked.
function S.applyVerdict(coordinator)
    local v = S.lastVerdict
    if v == nil or v.state ~= S.UNPAIRED or coordinator == nil then return 0 end
    local reason = S.UNPAIRED_REASON .. ":" .. tostring(v.reason)
    return coordinator:enumerateMemberRuns(function(gz, gx0, gx1)
        for gx = gx0, gx1 do coordinator:markUnavailable(gx, gz, reason, true) end
    end)
end
