-- =========================================================
-- FS25 Soil & Fertilizer - MATERIAL DOWN bridges (SF-43)
-- =========================================================
-- Two optional-mod bridges for the MATERIAL DOWN system, kept together because
-- they are the system's only outside contact:
--
--   1. TIME GUARD - two day-cadence accruals. SoilFertilizer had NO Time Guard
--      integration before this brief, so this is new plumbing, not a contract
--      change on their side.
--   2. STATE LEDGER - the watermark + object sidecar, delegate-when-present with
--      an own-XML fallback.
--
-- Both are strictly delegate-when-present. Neither mod is a hard dependency.
-- =========================================================
-- Author: TisonK
-- =========================================================

SoilMaterialDownBridge = SoilMaterialDownBridge or {}

-- =========================================================
-- Time Guard
-- =========================================================

SoilMaterialDownBridge.ACCRUAL_AGE         = "SoilFertilizer_MaterialDown_age"
SoilMaterialDownBridge.ACCRUAL_MAINTENANCE = "SoilFertilizer_MaterialDown_maintenance"

-- Settle order for the WHOLE ground-material package, fixed here so the sibling
-- member registers into a known sequence instead of negotiating one later:
--
--   10  member conversion / spoil resolution   (SF-44 HayBet)
--   20  THIS mod's age tick                    <- time exists before the day's weather
--   30  the sibling's condition accrual (dry, wet, record)
--   40  publication / maintenance              (SF-46's ladder pass rides this slot)
--
-- The ordering is the point: a day's age must be settled BEFORE the sibling applies
-- that day's weather to it, or the two members disagree about what day it is.
SoilMaterialDownBridge.PRIORITY = {
    MEMBER_RESOLUTION = 10,
    AGE_TICK          = 20,
    CONDITION_ACCRUAL = 30,   -- reserved for the sibling; nothing registers it here
    PUBLICATION       = 40,   -- maintenance, and SF-46's ladder pass
}

SoilMaterialDownBridge.timeGuardActive = false

local function getTimeGuard()
    return (g_currentMission ~= nil and g_currentMission.timeGuard) or nil
end

--- Register the two accruals. Server only: the layer does not exist elsewhere.
---
--- firstPeriodPolicy = "skip" on BOTH, stated explicitly because the scheduler's
--- SILENT default is "prorate", which would retroactively settle the partial period
--- the mod happened to load in - ageing material that predates the layer entirely.
--- Both onSettle bodies ignore ctx.proration, which is meaningless for a +1 raw add.
---@return boolean registered
function SoilMaterialDownBridge.registerAccruals(materialDown)
    SoilMaterialDownBridge.timeGuardActive = false
    if materialDown == nil then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        -- Neutral when absent, and deliberately NOT papered over with a private
        -- day counter: a second clock beside Time Guard's is the same class of
        -- mistake as a private sky. Records are still born and still read; they
        -- simply do not age until Time Guard is present.
        SoilLogger.info(
            "[MaterialDown] Time Guard not detected - material ages nowhere. Records are still " ..
            "created and read; no private clock is minted to fill the gap.")
        return false
    end

    local okAge = false
    local okMaint = false
    local ok, err = pcall(function()
        okAge = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_AGE, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.AGE_TICK,
            onSettle          = function(ctx) materialDown:onAgeTick(ctx) end,
        })
        okMaint = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_MAINTENANCE, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.PUBLICATION,
            onSettle          = function(ctx) materialDown:onMaintenanceTick(ctx) end,
        })
    end)

    if not ok then
        SoilLogger.warning("[MaterialDown] Time Guard registration failed: %s", tostring(err))
        return false
    end
    if not (okAge and okMaint) then
        SoilLogger.warning("[MaterialDown] Time Guard rejected an accrual (age=%s maintenance=%s)",
            tostring(okAge), tostring(okMaint))
        return false
    end

    SoilMaterialDownBridge.timeGuardActive = true
    SoilLogger.info("[OK] MaterialDown registered two day accruals with Time Guard (skip, prio %d/%d)",
        SoilMaterialDownBridge.PRIORITY.AGE_TICK, SoilMaterialDownBridge.PRIORITY.PUBLICATION)
    return true
end

SoilMaterialDownBridge.ACCRUAL_CONDITION = "SoilFertilizer_MaterialWetness_condition"

--- [SF-49] The condition accrual, registered into the slot the sibling reserved so
--- it settles AFTER the age tick. The ordering is the point: a day's age must be
--- settled before that day's weather is applied to it, or the two members disagree
--- about what day it is.
---
--- firstPeriodPolicy = "skip" for the same stated reason as the sibling's pair - the
--- scheduler's silent default is "prorate", which would retroactively wet or dry
--- material that predates the layer.
---@return boolean registered
function SoilMaterialDownBridge.registerConditionAccrual(materialWetness)
    if materialWetness == nil then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[MaterialWetness] Time Guard not detected - condition never accrues")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_CONDITION, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.CONDITION_ACCRUAL,
            onSettle          = function(ctx) materialWetness:onConditionAccrual(ctx) end,
        })
    end)
    if not ok or not okReg then
        SoilLogger.warning("[MaterialWetness] Time Guard registration failed: %s", tostring(err))
        return false
    end
    SoilLogger.info("[OK] MaterialWetness registered its condition accrual (skip, prio %d)",
        SoilMaterialDownBridge.PRIORITY.CONDITION_ACCRUAL)
    return true
end

function SoilMaterialDownBridge.unregisterAccruals()
    local tg = getTimeGuard()
    if tg == nil or tg.unregisterAccrual == nil then return end
    pcall(function()
        tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_AGE)
        tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_MAINTENANCE)
        tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_CONDITION)
        if SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER then
            tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER)
        end
        if SoilMaterialDownBridge.ACCRUAL_LADDER then
            tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_LADDER)
        end
    end)
    SoilMaterialDownBridge.timeGuardActive = false
end

-- =========================================================
-- Hay Member (SF-44 - THE HAY BET)
-- =========================================================

SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER = "SoilFertilizer_HayBet_resolution"

--- Register the hay member resolution on the MEMBER_RESOLUTION
--- slot (priority 10, before the age tick). Called once per game
--- day to run the settle pass - read condition, decide spoil, and
--- (when the conversion confirm lands) convert grass to hay.
---@param hayBet HayBet|nil
---@return boolean registered
function SoilMaterialDownBridge.registerHayMember(hayBet)
    if hayBet == nil or not hayBet:isArmed() then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[HayBet] Time Guard not detected - settle pass never fires")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.MEMBER_RESOLUTION,
            onSettle          = function(ctx) hayBet:onSettle(ctx) end,
        })
    end)
    if not ok or not okReg then
        SoilLogger.warning("[HayBet] Time Guard registration failed: %s", tostring(err))
        return false
    end

    SoilLogger.info("[OK] HayBet registered its day settle (prio %d)", SoilMaterialDownBridge.PRIORITY.MEMBER_RESOLUTION)
    return true
end

-- =========================================================
-- Yard Ladder (SF-46 - THE YARD LADDER)
-- =========================================================

SoilMaterialDownBridge.ACCRUAL_LADDER = "SoilFertilizer_YardLadder_pass"

--- Register the yard ladder's daily pass on the PUBLICATION slot
--- (priority 40), the everything-else day accrual the brief names.
--- Never the one-call age tick: this pass is linear in ledger rows
--- and makes no engine pass, so it has no business sharing a slot
--- with the whole-layer walk.
---
--- Accruals are keyed by NAME, so riding the same priority as the
--- maintenance accrual is a shared slot, not a collision.
---@param yardLadder YardLadder|nil
---@return boolean registered
function SoilMaterialDownBridge.registerLadderPass(yardLadder)
    if yardLadder == nil or not yardLadder:isArmed() then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[YardLadder] Time Guard not detected - ladder pass never fires")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_LADDER, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.PUBLICATION,
            onSettle          = function(ctx) yardLadder:onLadderPass(ctx) end,
        })
    end)
    if not ok or not okReg then
        SoilLogger.warning("[YardLadder] Time Guard registration failed: %s", tostring(err))
        return false
    end

    SoilLogger.info("[OK] YardLadder registered its daily pass (prio %d)", SoilMaterialDownBridge.PRIORITY.PUBLICATION)
    return true
end

-- =========================================================
-- State Ledger sidecar
-- =========================================================

SoilMaterialDownBridge.MODULE_ID  = "SoilFertilizer_MaterialDown"
SoilMaterialDownBridge.XML_FILE   = "sfMaterialDown.xml"
SoilMaterialDownBridge.ledgerActive = false

local function getLedger()
    return (g_currentMission ~= nil and g_currentMission.stateLedger) or nil
end

local function xmlPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
       or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. SoilMaterialDownBridge.XML_FILE
end

--- Register the sidecar with StateLedger when present.
---
--- deserialize MERGES, never replaces. StateLedger OMITS a block when serialize
--- fails and cannot tell an omitted block from a brand-new save (it chooses
--- resume-vs-defaults purely on data ~= nil). A replace-on-nil would wipe the
--- watermark after ONE bad save, and a lost watermark re-ages the entire map on the
--- next tick. MaterialDown:deserialize keeps the furthest-on watermark for the same
--- reason, so the merge is enforced on both sides of this boundary.
---
--- [RSF-F215] The ledger is the active backend only when registerModule RETURNS true
--- (StateLedger.lua:51-78 returns false for a malformed registration); a call that
--- merely did not throw is not a registration.
function SoilMaterialDownBridge.registerLedger(materialDown)
    SoilMaterialDownBridge.ledgerActive = false
    if materialDown == nil then return false end
    if g_server == nil then return false end

    local ledger = getLedger()
    if ledger == nil or ledger.registerModule == nil then
        SoilLogger.info("[MaterialDown] StateLedger not detected - using %s",
            SoilMaterialDownBridge.XML_FILE)
        return false
    end

    local registered = false
    local ok, err = pcall(function()
        registered = ledger:registerModule(SoilMaterialDownBridge.MODULE_ID, {
            serialize = function()
                return materialDown:serialize()
            end,
            deserialize = function(data)
                -- nil on a brand-new save AND on an omitted block: merge handles both.
                if data ~= nil then materialDown:deserialize(data, MaterialDown.BACKEND.STATELEDGER) end
            end,
        }) == true
    end)

    if not ok or not registered then
        SoilLogger.warning("[MaterialDown] StateLedger registration failed: %s (using %s)",
            ok and "registerModule returned false" or tostring(err), SoilMaterialDownBridge.XML_FILE)
        return false
    end

    SoilMaterialDownBridge.ledgerActive = true
    SoilLogger.info("[OK] MaterialDown registered with StateLedger as '%s'",
        SoilMaterialDownBridge.MODULE_ID)
    return true
end

-- [SF-49] The Water Record's own ledger module. ONE NOUN, PINNED: this string is a
-- persistence key, so a later rename orphans every saved verdict.
SoilMaterialDownBridge.WATER_MODULE_ID = "SoilFertilizer_MaterialWaterBook"
SoilMaterialDownBridge.waterLedgerActive = false

--- Register the Water Record sidecar. Merge-never-replace on the far side, for the
--- same reason as the sibling's: an omitted block is indistinguishable from a new
--- save, and a replace-on-nil would erase frozen verdicts that cannot be recomputed
--- (the climate roll reads the CURRENT season, so a past day would change its answer).
function SoilMaterialDownBridge.registerWaterLedger(materialWetness)
    SoilMaterialDownBridge.waterLedgerActive = false
    if materialWetness == nil then return false end
    if g_server == nil then return false end

    local ledger = getLedger()
    if ledger == nil or ledger.registerModule == nil then
        SoilLogger.info("[MaterialWetness] StateLedger not detected - the Water Record is session-only")
        return false
    end

    local ok, err = pcall(function()
        ledger:registerModule(SoilMaterialDownBridge.WATER_MODULE_ID, {
            serialize   = function() return materialWetness:serialize() end,
            deserialize = function(data)
                if data ~= nil then materialWetness:deserialize(data) end
            end,
        })
    end)
    if not ok then
        SoilLogger.warning("[MaterialWetness] StateLedger registration failed: %s", tostring(err))
        return false
    end
    SoilMaterialDownBridge.waterLedgerActive = true
    SoilLogger.info("[OK] MaterialWetness registered with StateLedger as '%s'",
        SoilMaterialDownBridge.WATER_MODULE_ID)
    return true
end

-- =========================================================
-- [RSF-F215] The career marker, the own file and the save invocation
-- =========================================================
-- THE MARKER. careerSavegame.soilFertilizer.materialDown in the career XML the native
-- save builds (FSCareerMissionInfo:saveToXMLFile keeps it as missionInfo.xmlFile,
-- FSCareerMissionInfo.lua:248-258, and SavegameController captures it after this hook,
-- SavegameController.lua:646/:650): #schema, #backend (STATELEDGER | OWN_FILE),
-- #generation, #state. Written UNAVAILABLE first, EXPECTED only once a complete
-- snapshot is frozen and, on the own-file backend, written. A load trusts modern rows
-- only when that marker, the backend it names and the payload's generation agree.
--
-- THE OWN FILE. sfMaterialDown.xml carries the whole envelope through MaterialDownCodec
-- (tagged entries, exact numbers). A file from before F215 carries only #schema and
-- #ageAppliedThroughDay and still loads as a legacy payload.
--
-- THE INVOCATION. A wrapper in front of FSCareerMissionInfo.saveToXMLFile opens one save
-- invocation before the native body and every appended hook (Soil's and StateLedger's,
-- in whichever order the mods loaded), so both freeze and read the same envelope.

SoilMaterialDownBridge.MARKER_KEY  = "careerSavegame.soilFertilizer.materialDown"
SoilMaterialDownBridge.FILE_FORMAT = "tagged1"
SoilMaterialDownBridge._saveInvocation = 0

local function careerPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
       or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/careerSavegame.xml"
end

local function exactString(n) return string.format("%.17g", n) end

--- The marker as the last save left it, read from careerSavegame.xml on disk.
---@return table|nil marker  { schema, backend, generation, state }; nil when absent
function SoilMaterialDownBridge.readCareerMarker()
    local path = careerPath()
    if path == nil or loadXMLFile == nil or fileExists == nil or not fileExists(path) then return nil end
    local marker = nil
    local ok = pcall(function()
        local xmlFile = loadXMLFile("sfCareerMarker", path)
        if xmlFile == nil or xmlFile == 0 then return end
        local key = SoilMaterialDownBridge.MARKER_KEY
        if hasXMLProperty(xmlFile, key) then
            marker = {
                schema     = tonumber(getXMLString(xmlFile, key .. "#schema")),
                backend    = getXMLString(xmlFile, key .. "#backend"),
                generation = tonumber(getXMLString(xmlFile, key .. "#generation")),
                state      = getXMLString(xmlFile, key .. "#state"),
            }
        end
        delete(xmlFile)
    end)
    if not ok then return { state = "UNREADABLE" } end
    return marker
end

--- Open the load: the marker and whether this is a genuine new career. A new career's
--- native missionInfo is not valid until its first save (FSCareerMissionInfo.lua:27,
--- :117), so a valid missionInfo is a world that was saved before.
function SoilMaterialDownBridge.beginLoad(materialDown)
    if materialDown == nil or g_server == nil then return end
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local newCareer = mi ~= nil and mi.isValid == false
    local marker = nil
    if not newCareer then marker = SoilMaterialDownBridge.readCareerMarker() end
    materialDown:beginLoad(marker, newCareer)
end

function SoilMaterialDownBridge.writeMarker(xmlFile, backend, generation, state)
    if xmlFile == nil or xmlFile == 0 then return false end
    local key = SoilMaterialDownBridge.MARKER_KEY
    local ok = pcall(function()
        setXMLString(xmlFile, key .. "#schema", exactString(MaterialDown.ENVELOPE_SCHEMA))
        setXMLString(xmlFile, key .. "#backend", tostring(backend))
        setXMLString(xmlFile, key .. "#generation", exactString(generation or 0))
        setXMLString(xmlFile, key .. "#state", state)
    end)
    return ok
end

--- Open one native save invocation (the wrapper in front of the career save).
function SoilMaterialDownBridge.openSaveInvocation()
    SoilMaterialDownBridge._saveInvocation = SoilMaterialDownBridge._saveInvocation + 1
    local sfm = g_SoilFertilityManager
    local md = sfm ~= nil and sfm.soilSystem ~= nil and sfm.soilSystem.materialDown or nil
    if md ~= nil and type(md.openSaveInvocation) == "function" then
        md:openSaveInvocation(SoilMaterialDownBridge._saveInvocation)
    end
end

--- Install the invocation wrapper once. It keeps the native call's own returns.
function SoilMaterialDownBridge.installSaveInvocation()
    if SoilMaterialDownBridge._invocationInstalled then return true end
    if FSCareerMissionInfo == nil or type(FSCareerMissionInfo.saveToXMLFile) ~= "function" then return false end
    local original = FSCareerMissionInfo.saveToXMLFile
    FSCareerMissionInfo.saveToXMLFile = function(missionInfo, ...)
        pcall(SoilMaterialDownBridge.openSaveInvocation)
        return original(missionInfo, ...)
    end
    SoilMaterialDownBridge._invocationInstalled = true
    return true
end

--- Write the envelope to sfMaterialDown.xml through the codec. True only when the file
--- was created (a nonzero handle), every entry encoded, and saveXMLFile returned true.
---@return boolean ok, string|nil reason
function SoilMaterialDownBridge.writeOwnFile(envelope)
    local path = xmlPath()
    if path == nil or createXMLFile == nil then return false, "NO_PATH" end
    local result, reason = false, nil
    local ok, err = pcall(function()
        local xmlFile = createXMLFile("sfMaterialDown", path, "materialDown")
        if xmlFile == nil or xmlFile == 0 then reason = "CREATE_FAILED" return end
        setXMLString(xmlFile, "materialDown#format", SoilMaterialDownBridge.FILE_FORMAT)
        -- The legacy reader's two attributes, so a downgraded Soil still finds its watermark.
        setXMLInt(xmlFile, "materialDown#schema", MaterialDown.ENVELOPE_SCHEMA)
        if envelope.ageAppliedThroughDay ~= nil then
            setXMLInt(xmlFile, "materialDown#ageAppliedThroughDay", envelope.ageAppliedThroughDay)
        end
        local encoded, why = MaterialDownCodec.encode(xmlFile, "materialDown.envelope", envelope)
        if encoded then
            result = saveXMLFile(xmlFile) == true
            if not result then reason = "SAVE_FAILED" end
        else
            reason = "ENCODE_" .. tostring(why)
        end
        delete(xmlFile)
    end)
    if not ok then return false, tostring(err) end
    return result, reason
end

--- Save the store: marker UNAVAILABLE, freeze the one envelope, write the own file on
--- that backend, then EXPECTED only for a complete snapshot that reached its backend.
--- Runs only while the family is armed and its load was decided; a save from a session
--- where the family is off writes nothing, and the next live load treats the world as
--- legacy rather than trusting stale files.
function SoilMaterialDownBridge.saveStore(materialDown, missionInfo)
    if materialDown == nil or g_server == nil then return end
    if type(materialDown.isArmed) ~= "function" or not materialDown:isArmed() then return end
    if materialDown.loadState == nil or materialDown.loadState == MaterialDown.LOAD.PENDING then return end
    missionInfo = missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo or nil)
    local careerXml = missionInfo ~= nil and missionInfo.xmlFile or nil
    local backend = SoilMaterialDownBridge.ledgerActive and MaterialDown.BACKEND.STATELEDGER or MaterialDown.BACKEND.OWN_FILE

    SoilMaterialDownBridge.writeMarker(careerXml, backend, 0, "UNAVAILABLE")
    local envelope = materialDown:freezeEnvelope()
    local reached, why = true, nil
    if backend == MaterialDown.BACKEND.OWN_FILE then
        reached, why = SoilMaterialDownBridge.writeOwnFile(envelope)
    end
    if envelope.saveStatus == MaterialDown.SAVE_STATUS.COMPLETE and reached then
        local marked = SoilMaterialDownBridge.writeMarker(careerXml, backend, envelope.saveGeneration, "EXPECTED")
        materialDown.lastSaveFailed = not marked
        if not marked then
            SoilLogger.warning("[MaterialDown] save: the career marker could not be written; the next load treats the store as legacy")
        end
    else
        materialDown.lastSaveFailed = true
        -- [MAINTENANCE row 137] The generation is in the marker in both states: the ground
        -- index's stamp (soilData.xml) is compared with it at the next arm whatever this
        -- backend's result, so a store that could not save does not cost the index a rebuild.
        SoilMaterialDownBridge.writeMarker(careerXml, backend, envelope.saveGeneration, "UNAVAILABLE")
        SoilLogger.warning("[MaterialDown] save: the store was not saved as complete (%s, %s); the marker says UNAVAILABLE",
            tostring(envelope.saveStatus), tostring(why or envelope.reason))
    end
end

-- =========================================================
-- [MAINTENANCE row 137] The ground membership index's stamp
-- =========================================================
-- The index (a value-map layer) is trusted at the next arm only when it carries the
-- generation of the save it was written in. soilData.xml carries the stamp, written by the
-- save only after the membership, age and wetness layers all saved; the career marker
-- carries the generation. RSF-F213's reading of section 5's "epoch" as the store's file set
-- (#1012) is replaced by this stamp.

SoilMaterialDownBridge.INDEX_STAMP_KEY = "soilData.groundMembership#generation"

--- This save's generation, frozen once per invocation (MaterialDown:freezeEnvelope), or
--- nil when the store is not armed or its load not decided.
function SoilMaterialDownBridge.saveGenerationFor(materialDown)
    if materialDown == nil or type(materialDown.isArmed) ~= "function" or not materialDown:isArmed() then return nil end
    if materialDown.loadState == nil or materialDown.loadState == MaterialDown.LOAD.PENDING then return nil end
    local ok, envelope = pcall(materialDown.freezeEnvelope, materialDown)
    if not ok or type(envelope) ~= "table" then return nil end
    return envelope.saveGeneration
end

--- The index stamp the last save left in soilData.xml, or nil.
function SoilMaterialDownBridge.readIndexStamp()
    local mi = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local dir = mi ~= nil and mi.savegameDirectory or nil
    if dir == nil or loadXMLFile == nil or fileExists == nil then return nil end
    local path = dir .. "/soilData.xml"
    if not fileExists(path) then return nil end
    local stamp = nil
    pcall(function()
        local xmlFile = loadXMLFile("sfIndexStamp", path)
        if xmlFile == nil or xmlFile == 0 then return end
        stamp = tonumber(getXMLString(xmlFile, SoilMaterialDownBridge.INDEX_STAMP_KEY))
        delete(xmlFile)
    end)
    return stamp
end

--- Kept for callers of the pre-F215 name.
function SoilMaterialDownBridge.saveFallback(materialDown, missionInfo)
    SoilMaterialDownBridge.saveStore(materialDown, missionInfo)
end

--- Read sfMaterialDown.xml and deliver it as the own-file backend's payload, whatever
--- the active backend: the marker names which backend is authoritative, and finishLoad
--- takes only that one. A file from before F215 delivers its watermark as a legacy
--- payload; an unreadable file delivers an UNREADABLE payload, never nothing.
function SoilMaterialDownBridge.loadFallback(materialDown)
    if materialDown == nil then return end
    if g_server == nil then return end
    local path = xmlPath()
    if path == nil or loadXMLFile == nil or fileExists == nil or not fileExists(path) then return end

    local payload = nil
    local ok, err = pcall(function()
        local xmlFile = loadXMLFile("sfMaterialDown", path)
        if xmlFile == nil or xmlFile == 0 then payload = { saveStatus = "UNREADABLE", reason = "LOAD_FAILED" } return end
        local format = getXMLString(xmlFile, "materialDown#format")
        if format == SoilMaterialDownBridge.FILE_FORMAT then
            local envelope, why = MaterialDownCodec.decode(xmlFile, "materialDown.envelope")
            if envelope ~= nil then payload = envelope
            else payload = { saveStatus = "UNREADABLE", reason = why } end
        elseif format == nil then
            local day = getXMLInt(xmlFile, "materialDown#ageAppliedThroughDay")
            payload = { ageAppliedThroughDay = day }
        else
            payload = { saveStatus = "UNREADABLE", reason = "UNKNOWN_FORMAT" }
        end
        delete(xmlFile)
    end)
    if not ok then
        SoilLogger.warning("[MaterialDown] fallback load failed: %s", tostring(err))
        payload = { saveStatus = "UNREADABLE", reason = "ERROR" }
    end
    if payload ~= nil then materialDown:deserialize(payload, MaterialDown.BACKEND.OWN_FILE) end
end
