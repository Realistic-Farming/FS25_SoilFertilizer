-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Logger
-- =========================================================
-- Centralized logging with consistent [SoilFertilizer] prefix
-- and debug-mode gating
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilLogger
SoilLogger = SoilLogger or {}

local PREFIX = "[SoilFertilizer]"

SoilLogger.debugBuffer    = {}
SoilLogger.DEBUG_BUF_MAX  = 500

-- RSF-F202: the debug history is a bounded circular store. debugBuffer holds
-- the physical slots; these two file-local values are the private ring
-- bookkeeping (index of the oldest retained record, and how many are
-- retained). They are initialized here, alongside the fresh buffer, so a
-- re-source of this chunk resets storage and metadata together. Physical
-- slot order is private; the logical order is oldest to newest. Never derive
-- count or order from #debugBuffer or ipairs over it.
local historyOldest = 1
local historyCount  = 0

--- Coerce format args that string.format cannot stringify (tables, userdata).
local function coerceFormatArg(v)
    local t = type(v)
    if t == "table" then
        return "(table)"
    end
    return v
end

--- Safe string.format: msg is always coerced to string before prefix concat.
local function safeFormat(prefix, msg, ...)
    local fmt = tostring(msg or "")
    local n = select("#", ...)
    if n == 0 then
        return prefix .. fmt
    end

    local args = { ... }
    for i = 1, n do
        args[i] = coerceFormatArg(args[i])
    end

    local ok, formatted = pcall(string.format, prefix .. fmt, unpack(args))
    if ok then
        return formatted
    end

    local parts = { prefix .. fmt }
    for i = 1, n do
        parts[#parts + 1] = tostring(args[i])
    end
    return table.concat(parts, " ")
end

--- Log a debug message (only shown when debugMode is enabled)
function SoilLogger.debug(msg, ...)
    if g_SoilFertilityManager and g_SoilFertilityManager.settings and g_SoilFertilityManager.settings.debugMode then
        local line = safeFormat(PREFIX .. " DEBUG: ", msg, ...)
        print(line)
        -- RSF-F202: one slot write per accepted message. While the ring is
        -- not full the next free slot is taken; once full the oldest slot is
        -- overwritten and the oldest cursor advances. No shift, no copy, no
        -- scan of the history on append.
        local buf = SoilLogger.debugBuffer
        local slot
        if historyCount < SoilLogger.DEBUG_BUF_MAX then
            slot = ((historyOldest + historyCount - 1) % SoilLogger.DEBUG_BUF_MAX) + 1
            historyCount = historyCount + 1
        else
            slot = historyOldest
            historyOldest = (historyOldest % SoilLogger.DEBUG_BUF_MAX) + 1
        end
        buf[slot] = {
            t   = g_currentMission and math.floor(g_currentMission.time or 0) or 0,
            msg = line,
        }
    end
end

--- Flush buffered debug messages to Debug/debug.xml in the mod profile folder.
--- Called by the SoilDebug console command when it switches debug mode off, and
--- at session teardown (SoilFertilityManager:delete). The other debug-off
--- routes (game settings, the mod panel toggle, the tablet System Settings row,
--- SettingsHub Control Center, SoilResetSettings and the panel's admin Reset)
--- save the setting without exporting.
--- RSF-F202: walks the ring oldest to newest and writes the same zero-based
--- keys as before. Storage and bookkeeping reset together only after save and
--- delete both return normally; exceptions propagate with the history intact.
--- One info line announces the written file only when the Lua XML save
--- wrapper reported true; false, nil or anything else announces nothing.
function SoilLogger.flushDebugLog()
    local buf = SoilLogger.debugBuffer
    if historyCount == 0 then return end
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if not base then return end
    local xml = XMLFile.create("sf_debugLog", base .. "/Debug/debug.xml", "debugLog")
    if not xml then return end
    local written = historyCount
    local first = historyOldest
    xml:setInt("debugLog#count", written)
    for offset = 0, written - 1 do
        local slot = ((first + offset - 1) % SoilLogger.DEBUG_BUF_MAX) + 1
        local entry = buf[slot]
        local key = string.format("debugLog.entry(%d)", offset)
        xml:setInt(key .. "#t", entry.t)
        xml:setString(key .. "#msg", entry.msg)
    end
    local saveSucceeded = xml:save()
    xml:delete()
    SoilLogger.debugBuffer = {}
    historyOldest = 1
    historyCount = 0
    if saveSucceeded == true then
        SoilLogger.info("Debug log written: %s/Debug/debug.xml (%d entries)", base, written)
    end
end

--- Log an info message (always shown)
function SoilLogger.info(msg, ...)
    if type(msg) == "table" and not SoilLogger._warnedTableInfoMsg then
        SoilLogger._warnedTableInfoMsg = true
        print(PREFIX .. " WARNING: SoilLogger.info format was a table (fix caller to pass string format)")
    end
    print(safeFormat(PREFIX .. " ", msg, ...))
end

--- Log a warning message (always shown)
function SoilLogger.warning(msg, ...)
    if type(msg) == "table" and not SoilLogger._warnedTableWarningMsg then
        SoilLogger._warnedTableWarningMsg = true
        print(PREFIX .. " WARNING: SoilLogger.warning format was a table (fix caller to pass string format)")
    end
    print(safeFormat(PREFIX .. " WARNING: ", msg, ...))
end

--- Log an error message (always shown)
function SoilLogger.error(msg, ...)
    if type(msg) == "table" and not SoilLogger._warnedTableErrorMsg then
        SoilLogger._warnedTableErrorMsg = true
        print(PREFIX .. " WARNING: SoilLogger.error format was a table (fix caller to pass string format)")
    end
    print(safeFormat(PREFIX .. " ERROR: ", msg, ...))
end
