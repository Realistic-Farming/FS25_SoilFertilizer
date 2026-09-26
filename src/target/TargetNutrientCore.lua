-- =========================================================
-- FS25 Realistic Soil & Fertilizer - SF-73 target core
-- =========================================================
-- The pure arithmetic of target-accurate N/P/K (SF-73 Implementation v1.1,
-- sections 4 and 6): the crop window per nutrient, the litre inversion, the
-- binding nutrient, the final physical quantity, the crop relationship, the
-- result precedence and the decimal sequence order. No engine call and no state:
-- TargetApplication owns the vehicle, the footprint and the writes, and asks
-- this file every question that has one right numeric answer.
-- =========================================================

TargetNutrientCore = TargetNutrientCore or {}
local C = TargetNutrientCore

C.SCHEMA = 1

C.NUTRIENTS = { "N", "P", "K" }
C.LAYER_KEY = { N = "nitrogen", P = "phosphorus", K = "potassium" }

C.STATE = {
    NOT_APPLICABLE     = "NOT_APPLICABLE",
    UNDETERMINED       = "UNDETERMINED",
    INACTIVE           = "INACTIVE",
    REACHED            = "REACHED",
    SHORT_BINDING      = "SHORT_BINDING",
    SHORT_HARDWARE     = "SHORT_HARDWARE",
    SHORT_SUPPLY       = "SHORT_SUPPLY",
    SHORT_QUANTIZED    = "SHORT_QUANTIZED",
    APPLICATION_FAILED = "APPLICATION_FAILED",
}

-- One display state is chosen in this order once NOT_APPLICABLE is resolved
-- (section 6). Every applicable reason is kept beside it.
C.PRECEDENCE = {
    "APPLICATION_FAILED", "UNDETERMINED", "INACTIVE", "SHORT_SUPPLY",
    "SHORT_HARDWARE", "SHORT_BINDING", "SHORT_QUANTIZED", "REACHED",
}

C.REASON = {
    UNKNOWN_PRODUCT             = "UNKNOWN_PRODUCT",
    UNSUPPORTED_CROP            = "UNSUPPORTED_CROP",
    MIXED_CROP                  = "MIXED_CROP",
    MIXED_FIELD                 = "MIXED_FIELD",
    UNKNOWN_GROUND              = "UNKNOWN_GROUND",
    OUTSIDE_MAP                 = "OUTSIDE_MAP",
    FARM_ACCESS                 = "FARM_ACCESS",
    SOWABILITY_UNKNOWN          = "SOWABILITY_UNKNOWN",
    NOZZLE_PARTIAL              = "NOZZLE_PARTIAL",
    CELL_OVERLAP                = "CELL_OVERLAP",
    CULTIVATION_NO_TARGET       = "CULTIVATION_NO_TARGET",
    SOURCE_CONTRACT_UNAVAILABLE = "SOURCE_CONTRACT_UNAVAILABLE",
    DOUBLED_AMOUNT_ACTIVE       = "DOUBLED_AMOUNT_ACTIVE",
    FOOTPRINT_PRIMING           = "FOOTPRINT_PRIMING",
}

-- The reason codes in their wire order (the result event sends an index into this).
C.REASON_ORDER = {
    "UNKNOWN_PRODUCT", "UNSUPPORTED_CROP", "MIXED_CROP", "MIXED_FIELD",
    "UNKNOWN_GROUND", "OUTSIDE_MAP", "FARM_ACCESS", "SOWABILITY_UNKNOWN",
    "NOZZLE_PARTIAL", "CELL_OVERLAP", "CULTIVATION_NO_TARGET",
    "SOURCE_CONTRACT_UNAVAILABLE", "DOUBLED_AMOUNT_ACTIVE", "FOOTPRINT_PRIMING",
}

C.REL = {
    BELOW        = "BELOW",
    APPROACHING  = "APPROACHING",
    IDEAL        = "IDEAL",
    ABOVE        = "ABOVE",
    UNDETERMINED = "UNDETERMINED",
}

C.KNOWLEDGE = { KNOWN = "KNOWN", PARTIAL = "PARTIAL", UNAVAILABLE = "UNAVAILABLE" }

C.SCOPE = { FOOTPRINT = "FOOTPRINT", FIELD_REPORT = "FIELD_REPORT", LOCAL = "LOCAL" }

-- Quality: ANALYSIS is an aggregate over ground; TRUTH is a map pixel read.
C.QUALITY = { ANALYSIS = "ANALYSIS", TRUTH = "TRUTH" }

--- A finite number (not NaN, not infinite).
function C.finite(x)
    return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end
local finite = C.finite

--- One carrier raw step: (layerMax - layerMin) / 254.
---@return number|nil
function C.carrierStep(layerMin, layerMax)
    if not finite(layerMin) or not finite(layerMax) or layerMax <= layerMin then return nil end
    return (layerMax - layerMin) / 254
end

--- The crop window for one nutrient: upper is the crop optimum, lower sits two
--- carrier steps below it, and the aim is its centre.
---@return table|nil { lower, upper, aim, width }
function C.window(opt, step)
    if not finite(opt) or not finite(step) or step <= 0 then return nil end
    local upper = opt
    local lower = upper - 2 * step
    return { lower = lower, upper = upper, aim = (lower + upper) * 0.5, width = upper - lower }
end

--- Where a value sits against its crop window. APPROACHING is the one window
--- width directly below the lower edge; further down is BELOW.
---@return string rel, number|nil distance, number|nil width
function C.relationship(value, win)
    if not finite(value) or type(win) ~= "table" or not finite(win.lower) or not finite(win.upper) then
        return C.REL.UNDETERMINED, nil, nil
    end
    local width = win.upper - win.lower
    if value > win.upper then return C.REL.ABOVE, nil, width end
    if value >= win.lower then return C.REL.IDEAL, nil, width end
    local distance = win.lower - value
    if distance <= width then return C.REL.APPROACHING, distance, width end
    return C.REL.BELOW, distance, width
end

--- The litres that raise one nutrient by `need` over `ha` hectares: the inverse of
--- applyFertilizer's credit, coefficient x mass-equivalent litres / 1000 / area x
--- replenishment x tuning. nil for anything non-finite or non-positive.
---@return number|nil
function C.litresFor(need, ha, coef, unitFactor, rr, tuning)
    if not finite(need) or not finite(ha) or not finite(coef) or not finite(unitFactor)
       or not finite(rr) or not finite(tuning) then
        return nil
    end
    if need < 0 or ha <= 0 or coef <= 0 or unitFactor <= 0 or rr <= 0 or tuning <= 0 then return nil end
    return need * ha * 1000 / (coef * unitFactor * rr * tuning)
end

--- The forward credit of `litres` over `ha`: what applyFertilizer adds per nutrient.
---@return number|nil
function C.creditFor(litres, ha, coef, unitFactor, rr, tuning)
    if not finite(litres) or not finite(ha) or not finite(coef) or not finite(unitFactor)
       or not finite(rr) or not finite(tuning) then
        return nil
    end
    if ha <= 0 then return nil end
    return coef * litres * unitFactor * rr * tuning / (1000 * ha)
end

--- The binding nutrient. A zero coefficient does not constrain; a supplied nutrient
--- whose remaining need is zero does, at zero litres. The smallest participating
--- litres bind, ties in the order N, P, K.
---@param needs table   { N=, P=, K= } remaining need (>= 0)
---@param coefs table   { N=, P=, K= } product coefficients
---@return number|nil litres, string|nil binding, table perNutrient, string|nil failure
function C.bindingLitres(needs, coefs, ha, unitFactor, rr, tuning)
    local best, binding = nil, nil
    local per = {}
    for _, n in ipairs(C.NUTRIENTS) do
        local coef = coefs and coefs[n] or 0
        if finite(coef) and coef > 0 then
            local l = C.litresFor(needs and needs[n], ha, coef, unitFactor, rr, tuning)
            if l == nil then return nil, nil, per, "INVALID" end
            per[n] = l
            if best == nil or l < best then best, binding = l, n end
        elseif not finite(coef) or coef < 0 then
            return nil, nil, per, "INVALID"
        end
    end
    if best == nil then return nil, nil, per, "NO_NPK" end
    return best, binding, per, nil
end

--- The final physical quantity: min(target, native 1x capacity, modified capacity,
--- available source). A nil supply is unlimited (helper buy). Also names what
--- limited it: nil when the target itself, "HARDWARE", "SUPPLY", or both.
---@return number|nil quantity, table limits { hardware=bool, supply=bool }
function C.accept(target, cap, supply, modifier)
    local limits = { hardware = false, supply = false }
    if not finite(target) or not finite(cap) or not finite(modifier) then return nil, limits end
    if supply == nil then supply = math.huge end
    if supply ~= math.huge and not finite(supply) then return nil, limits end
    if target < 0 or cap < 0 or supply < 0 or modifier < 0 then return nil, limits end
    local hardware = math.min(cap, cap * modifier)
    local q = math.min(target, hardware, supply)
    if q < target then
        if hardware <= q then limits.hardware = true end
        if supply <= q then limits.supply = true end
    end
    return q, limits
end

--- The one display state, by precedence.
---@param flags table  { [STATE] = true }
---@return string
function C.displayState(flags)
    for _, s in ipairs(C.PRECEDENCE) do
        if flags[s] then return s end
    end
    return C.STATE.UNDETERMINED
end

-- ── the decimal sequence ───────────────────────────────────────────────────
-- A bounded nonnegative decimal string, compared by normalised length and then
-- lexicographically: no float conversion and no narrow-integer wrap.
C.SEQ_MAX_DIGITS = 18

local function normalizeSeq(s)
    if type(s) ~= "string" or #s == 0 or #s > C.SEQ_MAX_DIGITS or not s:match("^%d+$") then return nil end
    s = s:gsub("^0+", "")
    if s == "" then s = "0" end
    return s
end
C.normalizeSeq = normalizeSeq

--- True when `incoming` is strictly greater than `existing`.
function C.seqGreater(incoming, existing)
    local a, b = normalizeSeq(incoming), normalizeSeq(existing)
    if a == nil or b == nil then return false end
    if #a ~= #b then return #a > #b end
    return a > b
end

--- The next sequence after `s`, or nil when it would exceed the bound (the caller
--- then opens a new epoch).
function C.seqNext(s)
    local a = normalizeSeq(s)
    if a == nil then return nil end
    local digits = {}
    for i = 1, #a do digits[i] = a:byte(i) - 48 end
    local i = #digits
    while i >= 1 do
        if digits[i] < 9 then
            digits[i] = digits[i] + 1
            break
        end
        digits[i] = 0
        i = i - 1
    end
    local out
    if i < 1 then out = "1" .. string.rep("0", #digits)
    else
        local parts = {}
        for j = 1, #digits do parts[j] = string.char(48 + digits[j]) end
        out = table.concat(parts)
    end
    if #out > C.SEQ_MAX_DIGITS then return nil end
    return out
end

-- ── the owning crop table ──────────────────────────────────────────────────

--- The supported crop key for a fruit name: explicit perennial-forage exclusion and
--- shipped-fruit alias resolution first, then membership of the owning crop-target
--- table. `default` never counts: default agronomy is not a supported crop.
---@param fruitName string|nil
---@param targets table        SoilConstants.CROP_NUTRIENT_TARGETS
---@param perennials table|nil SoilConstants.PERENNIAL_FORAGE_NAMES
---@param aliases table|nil    SoilConstants.SF73_CROP_ALIASES
---@return string|nil
function C.resolveCropKey(fruitName, targets, perennials, aliases)
    if type(fruitName) ~= "string" or fruitName == "" or type(targets) ~= "table" then return nil end
    local raw = string.lower(fruitName)
    perennials = perennials or {}
    if perennials[raw] then return nil end
    local key = (aliases and aliases[raw]) or raw
    if perennials[key] or key == "default" then return nil end
    local entry = targets[key]
    if type(entry) ~= "table" then return nil end
    for _, n in ipairs(C.NUTRIENTS) do
        local t = entry[n]
        if type(t) ~= "table" or not finite(t.opt) then return nil end
    end
    return key
end

--- The three windows for a supported crop, on carrier layers given by their bounds.
---@param entry table   CROP_NUTRIENT_TARGETS[key]
---@param bounds table  { N={min,max}, P=..., K=... }
---@return table|nil windows { N=win, P=win, K=win }, table steps
function C.cropWindows(entry, bounds)
    if type(entry) ~= "table" or type(bounds) ~= "table" then return nil end
    local wins, steps = {}, {}
    for _, n in ipairs(C.NUTRIENTS) do
        local b = bounds[n]
        local step = b and C.carrierStep(b.min, b.max)
        local t = entry[n]
        local w = step and t and C.window(t.opt, step)
        if w == nil then return nil end
        wins[n], steps[n] = w, step
    end
    return wins, steps
end

--- Copy a plain table deeply (results leave the host only as copies).
function C.copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = C.copy(v) end
    return r
end
