--
-- MaterialDownCodec
--
-- RSF-F215: the tagged recursive table codec MaterialDown's own-file save uses when
-- StateLedger is absent. The old fallback wrote only the schema and the age watermark
-- (SoilMaterialDownBridge.saveFallback before F215), so every object row and the active
-- field set were lost on a reload without StateLedger. This writes the complete detached
-- envelope instead.
--
-- FORMAT. A table is a list of entries under `<path>.entries.entry(i)`:
--   #kt  "s" | "n"            the key's type (a number key 5 and a string key "5" differ)
--   #k   the key, as a string (numbers as %.17g, which prints an integral value as an
--        integer string and round-trips every finite double exactly)
--   #vt  "s" | "n" | "b" | "t" the value's type
--   #v   the value for s, n and b ("true" | "false"); a "t" entry nests its own
--        `.entries` under the entry's path instead
-- Entries are written in a fixed order (number keys ascending, then string keys
-- ascending), so the same table always writes the same bytes.
--
-- REFUSALS. Encoding refuses a cycle, a key that is neither a finite number nor a
-- string, a value of any other type, and a non-finite number, rather than dropping it.
-- Decoding refuses an unknown tag, a repeated typed key, a missing or malformed value
-- and a non-finite number. A refusal returns nil and a reason; nothing half-built is
-- ever handed back.
--
-- The XML calls are the engine's plain handle API (setXMLString / getXMLString /
-- hasXMLProperty), the same family soilData.xml is written with.
--

MaterialDownCodec = MaterialDownCodec or {}
local C = MaterialDownCodec

C.MAX_DEPTH = 32

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function numberString(n)
    return string.format("%.17g", n)
end

--- Keys in a fixed order: number keys ascending, then string keys ascending.
local function orderedKeys(tbl)
    local nums, strs = {}, {}
    for k in pairs(tbl) do
        if type(k) == "number" then nums[#nums + 1] = k
        elseif type(k) == "string" then strs[#strs + 1] = k
        else return nil, "UNSUPPORTED_KEY" end
    end
    table.sort(nums)
    table.sort(strs)
    local out = {}
    for _, k in ipairs(nums) do out[#out + 1] = k end
    for _, k in ipairs(strs) do out[#out + 1] = k end
    return out
end

--- Check a table can be written, without writing anything: the same refusals encode
--- would meet, so a caller can refuse before it opens a file.
---@return boolean ok, string|nil reason
function C.validate(tbl, visiting, depth)
    if type(tbl) ~= "table" then return false, "NOT_A_TABLE" end
    visiting = visiting or {}
    depth = depth or 0
    if depth > C.MAX_DEPTH then return false, "TOO_DEEP" end
    if visiting[tbl] then return false, "CYCLE" end
    visiting[tbl] = true
    for k, v in pairs(tbl) do
        if type(k) == "number" then
            if not finite(k) then visiting[tbl] = nil return false, "NON_FINITE_KEY" end
        elseif type(k) ~= "string" then
            visiting[tbl] = nil
            return false, "UNSUPPORTED_KEY"
        end
        local vt = type(v)
        if vt == "number" then
            if not finite(v) then visiting[tbl] = nil return false, "NON_FINITE_VALUE" end
        elseif vt == "table" then
            local ok, why = C.validate(v, visiting, depth + 1)
            if not ok then visiting[tbl] = nil return false, why end
        elseif vt ~= "string" and vt ~= "boolean" then
            visiting[tbl] = nil
            return false, "UNSUPPORTED_VALUE"
        end
    end
    visiting[tbl] = nil
    return true
end

local function writeTable(xmlFile, path, tbl, depth)
    local keys, why = orderedKeys(tbl)
    if keys == nil then return false, why end
    for i, k in ipairs(keys) do
        local v = tbl[k]
        local ep = string.format("%s.entries.entry(%d)", path, i - 1)
        if type(k) == "number" then
            setXMLString(xmlFile, ep .. "#kt", "n")
            setXMLString(xmlFile, ep .. "#k", numberString(k))
        else
            setXMLString(xmlFile, ep .. "#kt", "s")
            setXMLString(xmlFile, ep .. "#k", k)
        end
        local vt = type(v)
        if vt == "string" then
            setXMLString(xmlFile, ep .. "#vt", "s")
            setXMLString(xmlFile, ep .. "#v", v)
        elseif vt == "number" then
            setXMLString(xmlFile, ep .. "#vt", "n")
            setXMLString(xmlFile, ep .. "#v", numberString(v))
        elseif vt == "boolean" then
            setXMLString(xmlFile, ep .. "#vt", "b")
            setXMLString(xmlFile, ep .. "#v", v and "true" or "false")
        else
            setXMLString(xmlFile, ep .. "#vt", "t")
            local ok, whyNested = writeTable(xmlFile, ep, v, depth + 1)
            if not ok then return false, whyNested end
        end
    end
    return true
end

--- Write `tbl` under `path`. Validates first, so a refused table writes nothing.
---@return boolean ok, string|nil reason
function C.encode(xmlFile, path, tbl)
    local ok, why = C.validate(tbl)
    if not ok then return false, why end
    return writeTable(xmlFile, path, tbl, 0)
end

local function readNumber(s)
    if type(s) ~= "string" then return nil end
    local n = tonumber(s)
    if not finite(n) then return nil end
    return n
end

local function readTable(xmlFile, path, depth)
    if depth > C.MAX_DEPTH then return nil, "TOO_DEEP" end
    local out, seen = {}, {}
    local i = 0
    while true do
        local ep = string.format("%s.entries.entry(%d)", path, i)
        if not hasXMLProperty(xmlFile, ep) then break end
        local kt = getXMLString(xmlFile, ep .. "#kt")
        local ks = getXMLString(xmlFile, ep .. "#k")
        local vt = getXMLString(xmlFile, ep .. "#vt")
        if ks == nil then return nil, "MISSING_KEY" end
        local key
        if kt == "n" then
            key = readNumber(ks)
            if key == nil then return nil, "BAD_NUMBER_KEY" end
        elseif kt == "s" then
            key = ks
        else
            return nil, "UNKNOWN_KEY_TAG"
        end
        local typedKey = kt .. ":" .. ks
        if seen[typedKey] then return nil, "REPEATED_KEY" end
        seen[typedKey] = true
        local value
        if vt == "s" then
            value = getXMLString(xmlFile, ep .. "#v")
            if value == nil then return nil, "MISSING_VALUE" end
        elseif vt == "n" then
            value = readNumber(getXMLString(xmlFile, ep .. "#v"))
            if value == nil then return nil, "BAD_NUMBER_VALUE" end
        elseif vt == "b" then
            local b = getXMLString(xmlFile, ep .. "#v")
            if b == "true" then value = true
            elseif b == "false" then value = false
            else return nil, "BAD_BOOLEAN" end
        elseif vt == "t" then
            local why
            value, why = readTable(xmlFile, ep, depth + 1)
            if value == nil then return nil, why end
        else
            return nil, "UNKNOWN_VALUE_TAG"
        end
        out[key] = value
        i = i + 1
    end
    return out
end

--- Read the table written under `path`.
---@return table|nil tbl, string|nil reason
function C.decode(xmlFile, path)
    return readTable(xmlFile, path, 0)
end

SoilLogger.info("MaterialDownCodec (RSF-F215) loaded")
