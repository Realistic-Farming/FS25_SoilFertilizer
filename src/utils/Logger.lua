-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Logger
-- =========================================================
-- Centralized logging with consistent [SoilFertilizer] prefix
-- and debug-mode gating
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class SoilLogger
SoilLogger = {}

local PREFIX = "[SoilFertilizer]"

SoilLogger.debugBuffer    = {}
SoilLogger.DEBUG_BUF_MAX  = 500

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
        local buf = SoilLogger.debugBuffer
        buf[#buf + 1] = {
            t   = g_currentMission and math.floor(g_currentMission.time or 0) or 0,
            msg = line,
        }
        if #buf > SoilLogger.DEBUG_BUF_MAX then
            table.remove(buf, 1)
        end
    end
end

--- Flush buffered debug messages to Debug/debug.xml in the mod profile folder.
--- Called when debug mode is turned off or the game session ends.
function SoilLogger.flushDebugLog()
    local buf = SoilLogger.debugBuffer
    if #buf == 0 then return end
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if not base then return end
    local xml = XMLFile.create("sf_debugLog", base .. "/Debug/debug.xml", "debugLog")
    if not xml then return end
    xml:setInt("debugLog#count", #buf)
    for i, entry in ipairs(buf) do
        local key = string.format("debugLog.entry(%d)", i - 1)
        xml:setInt(key .. "#t", entry.t)
        xml:setString(key .. "#msg", entry.msg)
    end
    xml:save()
    xml:delete()
    SoilLogger.debugBuffer = {}
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
