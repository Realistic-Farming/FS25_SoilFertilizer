--!load: src/utils/Logger.lua
-- RSF-F202: bounded diagnostic history and truthful export announcement.
-- Ported from the certified bar (Office Tyson/mods/FS25_SoilFertilizer/
-- RSF-F202-debug_history_spec_test.lua) and re-pointed to the production ring
-- as the handoff requires: GROUP A now asserts the REPAIRED append (no head
-- removal, one slot write per append, no history reads), the real-source groups
-- seed history through the public SoilLogger.debug path instead of assigning
-- the buffer table (a ring's private count and cursor must agree with its
-- storage, so direct seeding is no longer a valid way in), and a new GROUP J
-- covers amendment item 10 (the one announcement, gated on the Lua save
-- wrapper's true result, after reset, ungated by debug mode). GROUPS E-I keep
-- the delivered REFERENCE ring untouched. Nothing here proves native XML
-- durability, filesystem behaviour, in-game cost, frame time or gameplay.
-- Capacity is always derived from the production module.

local CAPACITY = SoilLogger.DEBUG_BUF_MAX
local PREFIX = "[SoilFertilizer]"
local function P(msg) return PREFIX .. " DEBUG: " .. msg end
local ANNOUNCE_PREFIX = PREFIX .. " Debug log written: "

local function capturePrint(fn)
    local lines = {}
    local previousPrint = print
    print = function(value)
        lines[#lines + 1] = tostring(value)
    end
    local ok, err = pcall(fn)
    print = previousPrint
    return ok, err, lines
end

local function joinRecordMessages(records)
    local values = {}
    for i = 1, #records do
        values[i] = records[i].msg
    end
    return table.concat(values, ",")
end

local function expectedMessageSequence(total)
    local first = total - CAPACITY + 1
    if first < 1 then first = 1 end
    local values = {}
    for i = first, total do
        values[#values + 1] = "m" .. tostring(i)
    end
    return table.concat(values, ",")
end

local function expectedPrefixedSequence(total)
    local first = total - CAPACITY + 1
    if first < 1 then first = 1 end
    local values = {}
    for i = first, total do
        values[#values + 1] = P("m" .. tostring(i))
    end
    return table.concat(values, ",")
end

local function newXml(options)
    options = options or {}
    local xml = {
        data = {},
        events = {},
        saveCalls = 0,
        deleteCalls = 0,
    }
    function xml:setInt(key, value)
        self.events[#self.events + 1] = "setInt:" .. key
        if options.throwAt == "set" then error("synthetic set failure", 0) end
        self.data[key] = value
    end
    function xml:setString(key, value)
        self.events[#self.events + 1] = "setString:" .. key
        if options.throwAt == "setString" then error("synthetic string-set failure", 0) end
        if options.throwKey == key then error("synthetic later-field failure", 0) end
        self.data[key] = value
    end
    function xml:save()
        self.saveCalls = self.saveCalls + 1
        self.events[#self.events + 1] = "save"
        if options.throwAt == "save" then error("synthetic save failure", 0) end
        return options.normalReturn
    end
    function xml:delete()
        self.deleteCalls = self.deleteCalls + 1
        self.events[#self.events + 1] = "delete"
        if options.throwAt == "delete" then error("synthetic delete failure", 0) end
        return options.normalReturn
    end
    return xml
end

local function installRealFlushDoors(profileFn, createFn)
    SettingsManager = { getModProfileDir = profileFn }
    XMLFile = { create = createFn }
end

-- Export the real logger's logical history through a throwaway XML and read it
-- back as "t:msg" in written order. Returns the xml so callers can inspect it.
local function exportedSequence(xml)
    local n = xml.data["debugLog#count"]
    if n == nil then return nil end
    local parts = {}
    for i = 0, n - 1 do
        parts[#parts + 1] = tostring(xml.data["debugLog.entry(" .. i .. ")#t"]) .. ":" .. tostring(xml.data["debugLog.entry(" .. i .. ")#msg"])
    end
    return table.concat(parts, ",")
end

-- The only way to empty the production ring is the real flush boundary: a
-- successful export resets storage, cursor and count together. This drains
-- through that door (announcement captured, not asserted) so every group
-- starts from a coherent empty history. The public one-time warning flags are
-- cleared as the delivered bar did.
local function drainReal()
    installRealFlushDoors(function() return "/drain" end, function() return newXml({ normalReturn = true }) end)
    capturePrint(function() SoilLogger.flushDebugLog() end)
    SoilLogger._warnedTableInfoMsg = nil
    SoilLogger._warnedTableWarningMsg = nil
    SoilLogger._warnedTableErrorMsg = nil
end

-- Seed history through the public path: each entry's t becomes the mission
-- time at the call, its msg the format string. Prints are swallowed.
local function appendReal(entries)
    g_SoilFertilityManager = g_SoilFertilityManager or { settings = {} }
    g_SoilFertilityManager.settings = g_SoilFertilityManager.settings or {}
    g_SoilFertilityManager.settings.debugMode = true
    for _, entry in ipairs(entries) do
        g_currentMission = { time = entry.t }
        capturePrint(function() SoilLogger.debug(entry.msg) end)
    end
    return SoilLogger.debugBuffer
end

local function physicalEntries(buf)
    local n = 0
    for _ in pairs(buf) do n = n + 1 end
    return n
end

-- GROUP A: the production ring. Overflow performs no head removal, one slot
-- write per append, no history reads during append; the export keeps exactly
-- the newest CAPACITY records in order.
do
    drainReal()
    g_SoilFertilityManager = { settings = { debugMode = true } }
    g_currentMission = { time = 7100 }

    local previousPrint = print
    local previousRemove = table.remove
    local printed = {}
    local removeCalls = 0
    print = function(value) printed[#printed + 1] = tostring(value) end
    table.remove = function(target, index)
        if target == SoilLogger.debugBuffer then removeCalls = removeCalls + 1 end
        return previousRemove(target, index)
    end
    local ok, err = pcall(function()
        for i = 1, CAPACITY + 1 do
            SoilLogger.debug("m%d", i)
        end
    end)
    table.remove = previousRemove
    print = previousPrint

    T.ok("A1 repaired logger completes overflow", ok, err)
    T.eq("A2 repaired logger performs no head removal", removeCalls, 0)
    T.eq("A3 physical storage stays bounded at capacity", physicalEntries(SoilLogger.debugBuffer), CAPACITY)
    T.eq("A4 repaired logger prints every accepted debug line", #printed, CAPACITY + 1)

    local xml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/profile" end, function() return xml end)
    capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("A5 export count is the bounded logical history", xml.data["debugLog#count"], CAPACITY)
    local exported = {}
    for i = 0, CAPACITY - 1 do exported[#exported + 1] = xml.data["debugLog.entry(" .. i .. ")#msg"] end
    T.eq("A6 export is the newest capacity in oldest-to-newest order", table.concat(exported, ","), expectedPrefixedSequence(CAPACITY + 1))
    T.eq("A7 first exported record is the second accepted message", xml.data["debugLog.entry(0)#msg"], P("m2"))
    T.eq("A8 last exported record is the newest accepted message", xml.data["debugLog.entry(" .. (CAPACITY - 1) .. ")#msg"], P("m" .. tostring(CAPACITY + 1)))

    -- Independent observation of production append work: the storage table is
    -- replaced by an empty proxy right after the reset, so every slot write and
    -- every history read the real append path performs is counted. A shifter or
    -- a copier would show extra writes; a scanner would show reads.
    local backing, access = {}, { reads = 0, writes = 0 }
    SoilLogger.debugBuffer = setmetatable({}, {
        __index = function(_, key) access.reads = access.reads + 1 return backing[key] end,
        __newindex = function(_, key, value) access.writes = access.writes + 1 backing[key] = value end,
    })
    capturePrint(function()
        for i = 1, CAPACITY + 3 do SoilLogger.debug("m%d", i) end
    end)
    T.eq("A9 production append performs exactly one storage write per accepted message", access.writes, CAPACITY + 3)
    T.eq("A10 production append performs no history reads", access.reads, 0)
    T.eq("A11 production ring bounds physical storage after wrapping", physicalEntries(backing), CAPACITY)
    local proxyXml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/profile" end, function() return proxyXml end)
    capturePrint(function() SoilLogger.flushDebugLog() end)
    local proxied = {}
    for i = 0, CAPACITY - 1 do proxied[#proxied + 1] = proxyXml.data["debugLog.entry(" .. i .. ")#msg"] end
    T.eq("A12 wrapped production history exports the exact newest window", table.concat(proxied, ","), expectedPrefixedSequence(CAPACITY + 3))
    T.eq("A13 flush reads each retained record once through the storage", access.reads, CAPACITY)
end

-- GROUP B: real source preserves gating, formatting, print-before-append and
-- the timestamp expression. The decimal mission times are synthetic.
do
    drainReal()
    g_SoilFertilityManager = { settings = { debugMode = false } }
    g_currentMission = { time = 1234.9 }
    local previousFormat = string.format
    local formatCalls = 0
    string.format = function(...)
        formatCalls = formatCalls + 1
        return previousFormat(...)
    end
    local ok, err, blockedLines = capturePrint(function()
        SoilLogger.debug("blocked %s", {})
    end)
    string.format = previousFormat
    T.ok("B1 debug-off real call returns normally", ok, err)
    T.eq("B2 debug-off call prints nothing", #blockedLines, 0)
    T.eq("B3 debug-off call formats nothing inside the logger", formatCalls, 0)
    T.eq("B4 debug-off call retains no history", physicalEntries(SoilLogger.debugBuffer), 0)

    g_SoilFertilityManager.settings.debugMode = true
    local entriesSeenAtPrint = nil
    local lines = {}
    local previousPrint = print
    print = function(value)
        entriesSeenAtPrint = physicalEntries(SoilLogger.debugBuffer)
        lines[#lines + 1] = tostring(value)
    end
    local enabledOk, enabledErr = pcall(function()
        SoilLogger.debug("table=%s", {})
        SoilLogger.debug("count=%d", "wrong")
    end)
    print = previousPrint
    T.ok("B5 enabled formatted calls return normally", enabledOk, enabledErr)
    T.eq("B6 real logger prints before appending", entriesSeenAtPrint, 1)
    T.eq("B7 table argument keeps the existing coercion", lines[1], P("table=(table)"))
    T.eq("B8 failed format keeps the existing fallback text", lines[2], P("count=%d wrong"))
    T.eq("B9 timestamp floors existing mission milliseconds", SoilLogger.debugBuffer[1].t, 1234)

    g_currentMission = nil
    local nilMissionOk, nilMissionErr = capturePrint(function()
        SoilLogger.debug("no mission")
    end)
    T.ok("B10 nil-mission debug call returns normally", nilMissionOk, nilMissionErr)
    T.eq("B11 nil mission keeps timestamp zero", SoilLogger.debugBuffer[3].t, 0)

    g_SoilFertilityManager.settings.debugMode = false
    local offAgainOk, offAgainErr, offAgainLines = capturePrint(function()
        SoilLogger.debug("off again")
    end)
    g_SoilFertilityManager.settings.debugMode = true
    local onAgainOk, onAgainErr, onAgainLines = capturePrint(function()
        SoilLogger.debug("on again")
    end)
    T.ok("B12 second debug-off call returns normally", offAgainOk, offAgainErr)
    T.eq("B13 second debug-off call remains silent", #offAgainLines, 0)
    T.ok("B14 second debug-on call returns normally", onAgainOk, onAgainErr)
    T.eq("B15 second debug-on call prints once", #onAgainLines, 1)
    T.eq("B16 debug toggles retain only accepted calls", physicalEntries(SoilLogger.debugBuffer), 4)
end

-- GROUP C: public info/warning/error output and one-time table-format
-- warnings remain unchanged and do not enter debug history.
do
    drainReal()
    local marker = {}
    local ok, err, lines = capturePrint(function()
        SoilLogger.info("info %s", "one")
        SoilLogger.warning("warning %d", 2)
        SoilLogger.error("error %s", "three")
        SoilLogger.info(marker)
        SoilLogger.info(marker)
        SoilLogger.warning(marker)
        SoilLogger.warning(marker)
        SoilLogger.error(marker)
        SoilLogger.error(marker)
    end)
    local infoWarning = PREFIX .. " WARNING: SoilLogger.info format was a table (fix caller to pass string format)"
    local warningWarning = PREFIX .. " WARNING: SoilLogger.warning format was a table (fix caller to pass string format)"
    local errorWarning = PREFIX .. " WARNING: SoilLogger.error format was a table (fix caller to pass string format)"
    local counts = { info = 0, warning = 0, error = 0 }
    for _, line in ipairs(lines) do
        if line == infoWarning then counts.info = counts.info + 1 end
        if line == warningWarning then counts.warning = counts.warning + 1 end
        if line == errorWarning then counts.error = counts.error + 1 end
    end
    T.ok("C1 unchanged public logger calls return normally", ok, err)
    T.eq("C2 info output text remains unchanged", lines[1], PREFIX .. " info one")
    T.eq("C3 warning output text remains unchanged", lines[2], PREFIX .. " WARNING: warning 2")
    T.eq("C4 error output text remains unchanged", lines[3], PREFIX .. " ERROR: error three")
    T.eq("C5 info table warning remains one-time", counts.info, 1)
    T.eq("C6 warning table warning remains one-time", counts.warning, 1)
    T.eq("C7 error table warning remains one-time", counts.error, 1)
    T.eq("C8 non-debug public calls do not enter history", physicalEntries(SoilLogger.debugBuffer), 0)
end

-- GROUP D: the real flush preserves chronological zero-based XML, early-return
-- retention, propagation and clear-only-after-normal-return, now against the
-- ring's logical order. History is seeded through the public debug path.
do
    drainReal()
    local profileCalls, createCalls = 0, 0
    installRealFlushDoors(
        function() profileCalls = profileCalls + 1; return "/profile" end,
        function() createCalls = createCalls + 1; return newXml() end)
    SoilLogger.flushDebugLog()
    T.eq("D1 empty flush performs no profile lookup", profileCalls, 0)
    T.eq("D2 empty flush performs no XML creation", createCalls, 0)

    local missingProfileBuffer = appendReal({ { t = 10, msg = "m1" } })
    installRealFlushDoors(
        function() return nil end,
        function() createCalls = createCalls + 1; return newXml() end)
    SoilLogger.flushDebugLog()
    T.eq("D3 missing profile preserves the buffer object", SoilLogger.debugBuffer, missingProfileBuffer)
    T.eq("D4 missing profile does not create XML", createCalls, 0)

    local nilXmlBuffer = SoilLogger.debugBuffer
    appendReal({ { t = 20, msg = "m2" } })
    installRealFlushDoors(
        function() return "/profile" end,
        function(name, path, root)
            createCalls = createCalls + 1
            T.eq("D5 real flush keeps XML handle name", name, "sf_debugLog")
            T.eq("D6 real flush keeps XML path", path, "/profile/Debug/debug.xml")
            T.eq("D7 real flush keeps XML root", root, "debugLog")
            return nil
        end)
    SoilLogger.flushDebugLog()
    T.eq("D8 nil XML creation preserves the buffer object", SoilLogger.debugBuffer, nilXmlBuffer)

    local setBuffer = SoilLogger.debugBuffer
    appendReal({ { t = 30, msg = "m3" } })
    local setXml = newXml({ throwAt = "set" })
    installRealFlushDoors(function() return "/profile" end, function() return setXml end)
    local setOk, setErr = pcall(SoilLogger.flushDebugLog)
    T.eq("D9 throwing set propagates", setOk, false)
    T.eq("D10 throwing set keeps its error", setErr, "synthetic set failure")
    T.eq("D11 throwing set preserves the buffer object", SoilLogger.debugBuffer, setBuffer)
    T.eq("D12 throwing set reaches no save", setXml.saveCalls, 0)

    local saveBuffer = SoilLogger.debugBuffer
    appendReal({ { t = 40, msg = "m4" } })
    local saveXml = newXml({ throwAt = "save" })
    installRealFlushDoors(function() return "/profile" end, function() return saveXml end)
    local saveOk, saveErr = pcall(SoilLogger.flushDebugLog)
    T.eq("D13 throwing save propagates", saveOk, false)
    T.eq("D14 throwing save keeps its error", saveErr, "synthetic save failure")
    T.eq("D15 throwing save preserves the buffer object", SoilLogger.debugBuffer, saveBuffer)
    T.eq("D16 throwing save reaches no delete", saveXml.deleteCalls, 0)

    local deleteBuffer = SoilLogger.debugBuffer
    appendReal({ { t = 50, msg = "m5" } })
    local deleteXml = newXml({ throwAt = "delete" })
    installRealFlushDoors(function() return "/profile" end, function() return deleteXml end)
    local deleteOk, deleteErr, deleteLines = capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("D17 throwing delete propagates", deleteOk, false)
    T.eq("D18 throwing delete keeps its error", deleteErr, "synthetic delete failure")
    T.eq("D19 throwing delete preserves the buffer object", SoilLogger.debugBuffer, deleteBuffer)
    T.eq("D20 throwing delete occurs after one save", deleteXml.saveCalls, 1)
    T.eq("D20b throwing delete after a successful save announces nothing", #deleteLines, 0)

    -- Chronology: the five records above are still retained (every flush so
    -- far returned early or threw), so drain and seed a clean three.
    drainReal()
    local chronology = appendReal({
        { t = 61, msg = "oldest" },
        { t = 62, msg = "middle" },
        { t = 63, msg = "newest" },
    })
    local normalXml = newXml({ normalReturn = false })
    profileCalls = 0
    installRealFlushDoors(
        function() profileCalls = profileCalls + 1; return "/profile" end,
        function() return normalXml end)
    local _, _, falseLines = capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("D21 real flush writes the exact count", normalXml.data["debugLog#count"], 3)
    T.eq("D22 real flush writes chronological zero-based entries", exportedSequence(normalXml),
        "61:" .. P("oldest") .. ",62:" .. P("middle") .. ",63:" .. P("newest"))
    T.eq("D23 false save return still runs save once", normalXml.saveCalls, 1)
    T.eq("D24 false save return still runs delete once", normalXml.deleteCalls, 1)
    T.eq("D25 normal-return flush clears history", physicalEntries(SoilLogger.debugBuffer), 0)
    T.ok("D26 normal-return flush replaces the old buffer object", SoilLogger.debugBuffer ~= chronology)
    T.eq("D26b a false save return announces no success", #falseLines, 0)
    local profileAfterFlush = profileCalls
    SoilLogger.flushDebugLog()
    T.eq("D27 repeated empty flush performs no profile work", profileCalls, profileAfterFlush)

    g_SoilFertilityManager = { settings = { debugMode = true } }
    g_currentMission = { time = 99.8 }
    local postOk, postErr = capturePrint(function() SoilLogger.debug("fresh") end)
    T.ok("D28 post-flush debug starts normally", postOk, postErr)
    T.eq("D29 post-flush history starts at one", physicalEntries(SoilLogger.debugBuffer), 1)
    T.eq("D30 post-flush timestamp uses the current mission", SoilLogger.debugBuffer[1].t, 99)
    T.eq("D31 post-flush message belongs only to the fresh history", SoilLogger.debugBuffer[1].msg, P("fresh"))
    local freshXml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/profile" end, function() return freshXml end)
    capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("D31b post-flush export carries only the fresh record", freshXml.data["debugLog#count"], 1)
    T.eq("D31c post-flush export starts at index zero with the fresh record", freshXml.data["debugLog.entry(0)#msg"], P("fresh"))
end

-- Failure after partial export, and a wrapped history that fails then continues.
do
    drainReal()
    local original = appendReal({ { t = 1, msg = "first" }, { t = 2, msg = "second" }, { t = 3, msg = "third" } })
    installRealFlushDoors(function() return "/profile" end,
        function() error("synthetic create failure", 0) end)
    local ok, err = pcall(SoilLogger.flushDebugLog)
    T.eq("D32 XML create throw propagates", ok, false)
    T.eq("D33 XML create throw preserves the error", err, "synthetic create failure")
    local probe = newXml({ normalReturn = nil })
    installRealFlushDoors(function() return "/profile" end, function() return probe end)
    local lateXml = newXml({ throwKey = "debugLog.entry(1)#msg" })
    installRealFlushDoors(function() return "/profile" end, function() return lateXml end)
    ok, err = pcall(SoilLogger.flushDebugLog)
    T.eq("D36 later field throw propagates", ok, false)
    T.eq("D37 later field throw happens after the first record was exported", lateXml.data["debugLog.entry(0)#msg"], P("first"))
    T.eq("D35 later field throw retains the same source buffer", SoilLogger.debugBuffer, original)
    T.eq("D39 later field throw does not reach save", lateXml.saveCalls, 0)
    local afterXml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/profile" end, function() return afterXml end)
    capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("D34/D38 both throws preserved the complete logical history", exportedSequence(afterXml),
        "1:" .. P("first") .. ",2:" .. P("second") .. ",3:" .. P("third"))

    -- Wrapped history: a save throw keeps the exact window and cursor; the next
    -- append advances the window by one.
    drainReal()
    g_SoilFertilityManager = { settings = { debugMode = true } }
    g_currentMission = { time = 5 }
    capturePrint(function() for i = 1, CAPACITY + 1 do SoilLogger.debug("m%d", i) end end)
    local throwing = newXml({ throwAt = "save" })
    installRealFlushDoors(function() return "/profile" end, function() return throwing end)
    local wrappedOk = pcall(SoilLogger.flushDebugLog)
    T.eq("G-real save failure on a wrapped history propagates", wrappedOk, false)
    capturePrint(function() SoilLogger.debug("m%d", CAPACITY + 2) end)
    local windowXml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/profile" end, function() return windowXml end)
    capturePrint(function() SoilLogger.flushDebugLog() end)
    local window = {}
    for i = 0, CAPACITY - 1 do window[#window + 1] = windowXml.data["debugLog.entry(" .. i .. ")#msg"] end
    T.eq("G-real append after failure advances the exact newest window", table.concat(window, ","), expectedPrefixedSequence(CAPACITY + 2))
    T.eq("G-real wrapped export count stays at capacity", windowXml.data["debugLog#count"], CAPACITY)
end

-- Actual re-source: running the production chunk again initializes storage,
-- cursor and count together, so the first export after it carries only fresh
-- records. The chunk is read from the repository path the harness stages.
do
    drainReal()
    g_SoilFertilityManager = { settings = { debugMode = true } }
    g_currentMission = { time = 9001.9 }
    capturePrint(function()
        for i = 1, CAPACITY + 1 do SoilLogger.debug("old%d", i) end
    end)
    local loader
    local candidates = { "../../src/utils/Logger.lua", "src/utils/Logger.lua" }
    for _, path in ipairs(candidates) do
        if loader == nil and type(loadfile) == "function" then
            loader = loadfile(path)
        end
        if loader == nil and type(io) == "table" and io.open then
            local f = io.open(path, "r")
            if f then
                local src = f:read("*a")
                f:close()
                loader = load(src, "=Logger.lua")
            end
        end
    end
    T.ok("D40 existing runtime can load the exact declared staged Logger again", type(loader) == "function")
    if loader then
        local reloaded = pcall(loader)
        T.ok("D41 actual Logger re-source completes", reloaded)
        local xml = newXml({ normalReturn = true })
        installRealFlushDoors(function() return "/profile" end, function() return xml end)
        local freshOk = capturePrint(function() SoilLogger.debug("fresh after source") end)
        local flushOk = pcall(SoilLogger.flushDebugLog)
        T.ok("D42 first debug after actual re-source works", freshOk)
        T.ok("D43 first flush after actual re-source works", flushOk)
        T.eq("D44 actual re-source discards all prior logical history", xml.data["debugLog#count"], 1)
        T.eq("D45 actual re-source exports only the fresh message", xml.data["debugLog.entry(0)#msg"], P("fresh after source"))
        T.eq("D46 actual re-source preserves the fresh timestamp", xml.data["debugLog.entry(0)#t"], 9001)
    end
end

-- GROUP J: amendment item 10. One announcement, only on the Lua save
-- wrapper's true result, after the reset, at info level, ungated by debug
-- mode, with the XML count in the text; every other result is silent.
do
    drainReal()
    appendReal({ { t = 1, msg = "a" }, { t = 2, msg = "b" }, { t = 3, msg = "c" } })
    g_SoilFertilityManager.settings.debugMode = false   -- the SoilDebug off-edge has just disabled debug
    local trueXml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/mods/profile" end, function() return trueXml end)
    local entriesAtAnnounce
    local previousPrint = print
    local lines = {}
    print = function(value)
        lines[#lines + 1] = tostring(value)
        entriesAtAnnounce = physicalEntries(SoilLogger.debugBuffer)
    end
    local ok, err = pcall(SoilLogger.flushDebugLog)
    print = previousPrint
    T.ok("J1 true save flush returns normally", ok, err)
    T.eq("J2 exactly one line is printed", #lines, 1)
    T.eq("J3 the line is the info announcement with path and count", lines[1], ANNOUNCE_PREFIX .. "/mods/profile/Debug/debug.xml (3 entries)")
    T.eq("J4 the announced count equals the XML count", trueXml.data["debugLog#count"], 3)
    T.eq("J5 the announcement is printed after the reset", entriesAtAnnounce, 0)
    T.eq("J6 the announcement is not gated by debug mode", g_SoilFertilityManager.settings.debugMode, false)
    T.eq("J7 the announcement does not enter history", physicalEntries(SoilLogger.debugBuffer), 0)
    T.eq("J8 save ran once", trueXml.saveCalls, 1)
    T.eq("J9 delete ran once", trueXml.deleteCalls, 1)

    -- Nothing but boolean true admits the line.
    for _, result in ipairs({ { label = "false", value = false }, { label = "nil", value = nil }, { label = "number 1", value = 1 }, { label = "string", value = "ok" } }) do
        drainReal()
        appendReal({ { t = 7, msg = "x" } })
        local xml = newXml({ normalReturn = result.value })
        installRealFlushDoors(function() return "/profile" end, function() return xml end)
        local _, _, silent = capturePrint(function() SoilLogger.flushDebugLog() end)
        T.eq("J10 " .. result.label .. " save result announces nothing", #silent, 0)
        T.eq("J11 " .. result.label .. " save result still clears history (original boundary)", physicalEntries(SoilLogger.debugBuffer), 0)
        T.eq("J12 " .. result.label .. " save result still ran delete once", xml.deleteCalls, 1)
    end

    -- Early returns stay silent.
    drainReal()
    local _, _, emptyLines = capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("J13 empty flush announces nothing", #emptyLines, 0)
    appendReal({ { t = 8, msg = "y" } })
    installRealFlushDoors(function() return nil end, function() return newXml({ normalReturn = true }) end)
    local _, _, noProfileLines = capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("J14 missing profile announces nothing", #noProfileLines, 0)
    installRealFlushDoors(function() return "/profile" end, function() return nil end)
    local _, _, noXmlLines = capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("J15 nil XML creation announces nothing", #noXmlLines, 0)
    T.eq("J16 early returns preserved the history", physicalEntries(SoilLogger.debugBuffer), 1)

    -- A wrapped history announces the bounded count.
    drainReal()
    g_SoilFertilityManager = { settings = { debugMode = true } }
    g_currentMission = { time = 1 }
    capturePrint(function() for i = 1, CAPACITY + 9 do SoilLogger.debug("w%d", i) end end)
    local wrappedXml = newXml({ normalReturn = true })
    installRealFlushDoors(function() return "/p" end, function() return wrappedXml end)
    local _, _, wrappedLines = capturePrint(function() SoilLogger.flushDebugLog() end)
    T.eq("J17 wrapped export announces the bounded count", wrappedLines[1], ANNOUNCE_PREFIX .. "/p/Debug/debug.xml (" .. CAPACITY .. " entries)")
    T.eq("J18 wrapped export announces once", #wrappedLines, 1)
    drainReal()
end

-- GROUPS E-I: the delivered REFERENCE ring, kept exactly as the bar shipped it.
-- GROUP E: REFERENCE circular store for the fixed direction in brief:52-57.
-- Physical slots are private. The public model surface is append plus a logical
-- oldest-to-newest snapshot. Storage access is observed independently through the proxy below.
-- Observe physical model storage through an empty proxy, not a counter that
-- referenceAppend increments itself. Reads/writes here are reference evidence.
local function observedSlots()
    local values = {}
    local access = { reads = 0, writes = 0, entries = 0 }
    local slots = setmetatable({}, {
        __index = function(_, key)
            access.reads = access.reads + 1
            return values[key]
        end,
        __newindex = function(_, key, value)
            access.writes = access.writes + 1
            if values[key] == nil and value ~= nil then access.entries = access.entries + 1 end
            if values[key] ~= nil and value == nil then access.entries = access.entries - 1 end
            values[key] = value
        end,
    })
    return slots, access
end

local function initializeReference(ring)
    ring.slots, ring.access = observedSlots()
    ring.count = 0
    ring.oldest = 1
    return ring
end

local function newReferenceRing()
    return initializeReference({})
end

local function referenceAppend(ring, entry)
    local slot
    if ring.count < CAPACITY then
        slot = ((ring.oldest + ring.count - 1) % CAPACITY) + 1
        ring.count = ring.count + 1
    else
        slot = ring.oldest
        ring.oldest = (ring.oldest % CAPACITY) + 1
    end
    ring.slots[slot] = entry
end

local function referenceSnapshot(ring)
    local result = {}
    for offset = 0, ring.count - 1 do
        local slot = ((ring.oldest + offset - 1) % CAPACITY) + 1
        result[#result + 1] = ring.slots[slot]
    end
    return result
end

do
    local cases = {
        { label = "empty", total = 0 },
        { label = "one", total = 1 },
        { label = "capacity minus one", total = CAPACITY - 1 },
        { label = "capacity", total = CAPACITY },
        { label = "first wrap", total = CAPACITY + 1 },
        { label = "multiple wraps", total = CAPACITY * 3 + 7 },
    }
    for _, case in ipairs(cases) do
        local ring = newReferenceRing()
        for i = 1, case.total do
            referenceAppend(ring, { t = i, msg = "m" .. tostring(i) })
        end
        local appendReads, appendWrites = ring.access.reads, ring.access.writes
        local snapshot = referenceSnapshot(ring)
        local expectedCount = case.total
        if expectedCount > CAPACITY then expectedCount = CAPACITY end
        T.eq("E " .. case.label .. " keeps exact bounded count", #snapshot, expectedCount)
        T.eq("E " .. case.label .. " keeps exact last-history chronology", joinRecordMessages(snapshot), expectedMessageSequence(case.total))
        T.eq("E " .. case.label .. " performs one observed model slot write per append", appendWrites, case.total)
        T.eq("E " .. case.label .. " performs no model history reads during append", appendReads, 0)
        T.eq("E " .. case.label .. " bounds physical model storage", ring.access.entries, expectedCount)
    end
end

-- GROUP F: REFERENCE chronological flush uses Logger.lua:77-84 XML shape and
-- brief:55-56 reset boundary. Exact last-500 order is checked as one sequence.
local function referenceFlush(ring, xml)
    if ring.count == 0 or xml == nil then return false end
    local snapshot = referenceSnapshot(ring)
    xml:setInt("debugLog#count", #snapshot)
    for i = 1, #snapshot do
        local key = string.format("debugLog.entry(%d)", i - 1)
        xml:setInt(key .. "#t", snapshot[i].t)
        xml:setString(key .. "#msg", snapshot[i].msg)
    end
    xml:save()
    xml:delete()
    initializeReference(ring)
    return true
end

do
    local ring = newReferenceRing()
    for i = 1, CAPACITY + 1 do
        referenceAppend(ring, { t = i, msg = "m" .. tostring(i) })
    end
    local xml = newXml()
    local flushed = referenceFlush(ring, xml)
    local exported = {}
    for i = 0, CAPACITY - 1 do
        exported[#exported + 1] = xml.data["debugLog.entry(" .. i .. ")#msg"]
    end
    T.eq("F1 reference flush reports work", flushed, true)
    T.eq("F2 reference flush writes source-derived capacity", xml.data["debugLog#count"], CAPACITY)
    T.eq("F3 reference flush exports exact last-500 chronology", table.concat(exported, ","), expectedMessageSequence(CAPACITY + 1))
    T.eq("F4 reference flush resets logical count", ring.count, 0)
    T.eq("F5 reference flush resets oldest cursor", ring.oldest, 1)
    T.eq("F6 reference flush releases physical slots", ring.access.entries, 0)
    local eventCount = #xml.events
    T.eq("F7 repeated reference flush is empty", referenceFlush(ring, xml), false)
    T.eq("F8 repeated reference flush writes nothing", #xml.events, eventCount)
    referenceAppend(ring, { t = 8001, msg = "after1" })
    referenceAppend(ring, { t = 8002, msg = "after2" })
    T.eq("F9 post-flush reference history starts fresh", joinRecordMessages(referenceSnapshot(ring)), "after1,after2")
end

-- GROUP G: REFERENCE failure retains logical order and cursor before more wraps.
-- The modeled exception is not a claim about native XML failure modes.
do
    local ring = newReferenceRing()
    for i = 1, CAPACITY + 1 do
        referenceAppend(ring, { t = i, msg = "m" .. tostring(i) })
    end
    local before = joinRecordMessages(referenceSnapshot(ring))
    local oldestBefore = ring.oldest
    local xml = newXml({ throwAt = "save" })
    local ok, err = pcall(referenceFlush, ring, xml)
    T.eq("G1 reference save failure propagates", ok, false)
    T.eq("G2 reference save failure keeps its error", err, "synthetic save failure")
    T.eq("G3 reference save failure retains exact chronology", joinRecordMessages(referenceSnapshot(ring)), before)
    T.eq("G4 reference save failure retains oldest cursor", ring.oldest, oldestBefore)
    T.eq("G5 reference save failure retains bounded count", ring.count, CAPACITY)
    referenceAppend(ring, { t = CAPACITY + 2, msg = "m" .. tostring(CAPACITY + 2) })
    T.eq("G6 append after failure advances exact newest window", joinRecordMessages(referenceSnapshot(ring)), expectedMessageSequence(CAPACITY + 2))
end

-- GROUP H: independently observed model work rejects a manual history shift,
-- even when that bad candidate contains no table.remove and retains correct data.
do
    local badSlots, badAccess = observedSlots()
    for i = 1, CAPACITY do badSlots[i] = { t = i, msg = "m" .. tostring(i) } end
    badAccess.reads, badAccess.writes = 0, 0
    for i = 1, CAPACITY - 1 do badSlots[i] = badSlots[i + 1] end
    badSlots[CAPACITY] = { t = CAPACITY + 1, msg = "m" .. tostring(CAPACITY + 1) }
    local badReads, badWrites = badAccess.reads, badAccess.writes
    local sequence = {}
    for i = 1, CAPACITY do sequence[i] = badSlots[i] end
    T.eq("H1 deliberately bad shifter still retains correct records", joinRecordMessages(sequence), expectedMessageSequence(CAPACITY + 1))
    T.ok("H2 independent storage observation rejects its multiple writes", badWrites > 1)
    T.ok("H3 independent storage observation rejects its history scan", badReads > 0)

    local ring = newReferenceRing()
    for i = 1, CAPACITY + 1 do referenceAppend(ring, { t = i, msg = "m" .. tostring(i) }) end
    ring.access.reads, ring.access.writes = 0, 0
    referenceAppend(ring, { t = CAPACITY + 2, msg = "m" .. tostring(CAPACITY + 2) })
    T.eq("H4 independent observation sees one ring overwrite", ring.access.writes, 1)
    T.eq("H5 independent observation sees no ring history scan", ring.access.reads, 0)
end

-- GROUP I: reference metadata survives nil XML and failures after partial export.
do
    local cases = { "setString", "save", "delete" }
    for _, failure in ipairs(cases) do
        local ring = newReferenceRing()
        for i = 1, CAPACITY + 1 do referenceAppend(ring, { t = i, msg = "m" .. tostring(i) }) end
        local oldest, count = ring.oldest, ring.count
        local before = joinRecordMessages(referenceSnapshot(ring))
        T.eq("I " .. failure .. " nil XML reports no flush", referenceFlush(ring, nil), false)
        local options = failure == "setString" and { throwKey = "debugLog.entry(1)#msg" } or { throwAt = failure }
        local ok = pcall(referenceFlush, ring, newXml(options))
        T.eq("I " .. failure .. " reference exception propagates", ok, false)
        T.eq("I " .. failure .. " retains the whole logical history", joinRecordMessages(referenceSnapshot(ring)), before)
        T.eq("I " .. failure .. " retains count", ring.count, count)
        T.eq("I " .. failure .. " retains oldest", ring.oldest, oldest)
        referenceAppend(ring, { t = CAPACITY + 2, msg = "m" .. tostring(CAPACITY + 2) })
        T.eq("I " .. failure .. " can continue with the exact next window", joinRecordMessages(referenceSnapshot(ring)), expectedMessageSequence(CAPACITY + 2))
    end

    local ring = newReferenceRing()
    for i = 1, CAPACITY + 7 do referenceAppend(ring, { t = i, msg = "old" }) end
    initializeReference(ring)
    referenceAppend(ring, { t = 27, msg = "only fresh" })
    T.eq("I reinitialization drops the previous logical count", ring.count, 1)
    T.eq("I reinitialization gives a coherent fresh history", joinRecordMessages(referenceSnapshot(ring)), "only fresh")
end
