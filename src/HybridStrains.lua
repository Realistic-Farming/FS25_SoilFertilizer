-- HybridStrains.lua - CD-10: hybrid disease types (multi-mode resistance strains).
--
-- A player can currently dodge the resistance consequence by rotating modes, and nothing
-- punishes building resistance in several modes at once. This is that consequence: ground
-- pushed past the threshold in two or more modes can breed an infection no single chemical
-- answers well.
--
-- WHAT THIS IS NOT: a second concurrent infection. `field.activeDisease` is a hard scalar and
-- CD-10 does not change its shape -- a hybrid id rides it exactly as every other disease id
-- does, and is opaque to every existing reader (severity, discovery, save, sync, DairyCore).
-- It is also not a reading surface; the player learns about it through CD-11's contract.
--
-- THE ONE THING THAT MAKES THIS SAFE TO SHIP: F66. Built against the unmetered resistance
-- build, this would have fired on almost any two-mode spray pass rather than as an earned
-- seasons-long consequence, inverting the entire design intent. That was a HARD build-order
-- gate (Steward CD10-C1) and it cleared with b60677f8.

HybridStrains = HybridStrains or {}

-- ── Eligibility (the threshold arithmetic) ────────────────────────────────────────────
--
-- Resistance scores are NOT on a universal 0-1 scale: a synthetic mode's ceiling is 10, a
-- natural's is 5. HYBRID_THRESHOLD is a FRACTION of each mode's OWN ceiling, never an
-- absolute score. Comparing a raw score against 0.7 would fire on almost every mode almost
-- immediately.
--
-- Worked: two synthetic modes gate at >= 7.0 each. A synthetic paired with a natural gates
-- the natural side at >= 3.5 and the synthetic side stays >= 7.0.
--
-- THE CEILING COMES FROM ResistanceBands.ceilingForMode, NOT from isNaturalFungicide(mode).
-- The CD-10 brief's own loop shape said the latter; it is a type error (that function takes a
-- fill-type NAME like "SULFUR", while field.resistance is keyed by MODE like "M2"), it
-- returns nil for every mode, and every mode would have read the SYNTHETIC ceiling. The
-- corrected mapping is per CHEMICAL and lives in RESISTANCE.NATURAL_MODES -- note M3
-- MANCOZEB is multisite yet synthetic, so an "M-prefix means natural" test is wrong too.
---@param field table
---@param mode string
---@return boolean
--
-- THE EPSILON, and it is not fudge. Resistance accrues as ~50 tiny additions per boom pass,
-- so a field that has had exactly the design's number of full passes lands a hair BELOW the
-- threshold rather than on it: measured, 14 passes gives 6.999999999999895 against a
-- threshold of 7.0, short by 1.05e-13. Without tolerance the hybrid fires one pass later
-- than the arithmetic says, and anyone tuning HYBRID_THRESHOLD would find the numbers did
-- not mean what they read. The epsilon is relative and ~1e-9 -- eleven orders of magnitude
-- below the smallest change a player could ever perceive, and far above accumulated drift.
local ELIGIBILITY_EPSILON = 1e-9

function HybridStrains.isModeEligible(field, mode)
    local scores = field and field.resistance
    if type(scores) ~= "table" then return false end
    local score = scores[mode]
    if type(score) ~= "number" then return false end
    local threshold = SoilConstants.RESISTANCE.HYBRID_THRESHOLD * ResistanceBands.ceilingForMode(mode)
    return score >= threshold * (1 - ELIGIBILITY_EPSILON)
end

--- Every mode on this field at or past its own threshold fraction, sorted for determinism.
---@param field table
---@return table   array of mode strings
function HybridStrains.eligibleModes(field)
    local out = {}
    local scores = field and field.resistance
    if type(scores) ~= "table" then return out end
    for mode in pairs(scores) do
        if HybridStrains.isModeEligible(field, mode) then out[#out + 1] = mode end
    end
    table.sort(out)
    return out
end

--- Candidacy weight for a mode pair. Zero means "eligible but never fires".
---@return number
function HybridStrains.pairWeight(m1, m2)
    local risk = SoilConstants.HYBRID.MODE_RISK
    local d = SoilConstants.HYBRID.DEFAULT_MODE_RISK
    local r1 = risk[m1]; if r1 == nil then r1 = d end
    local r2 = risk[m2]; if r2 == nil then r2 = d end
    -- Multiplicative: ONE multisite partner is enough to make the pair a non-candidate,
    -- which is the agronomy -- multisite chemistry does not select for cross-resistance.
    return r1 * r2
end

--- The pair that fires, or nil when none qualifies with a non-zero weight.
---
--- Selection is FULLY DETERMINISTIC and must never depend on table-iteration order: the
--- eligible list is sorted, pairs are walked in that order, and ties break on the
--- lexicographically-first pair. A hostile iteration order must produce the same answer.
---@param field table
---@return string|nil m1, string|nil m2, number weight
function HybridStrains.selectPair(field)
    local modes = HybridStrains.eligibleModes(field)   -- already sorted
    local bestA, bestB, bestW = nil, nil, 0
    for i = 1, #modes do
        for j = i + 1, #modes do
            local w = HybridStrains.pairWeight(modes[i], modes[j])
            -- Strictly greater: the first pair seen in sorted order keeps a tie, which IS
            -- the lexicographic tie-break because the outer walk is over sorted modes.
            if w > bestW then bestA, bestB, bestW = modes[i], modes[j], w end
        end
    end
    if bestW <= 0 then return nil, nil, 0 end
    return bestA, bestB, bestW
end

-- ── The re-onset cooldown ─────────────────────────────────────────────────────────────
--
-- Once a hybrid has been active on a field and clears, re-onset is blocked there for one
-- calendar month. Measured against daysPerPeriod exactly as the resistance decay is, so it
-- is one real month whatever the month length setting.
--
-- The expiry is PERSISTED (one int on the existing per-field save), and that is a
-- deliberate, flagged departure from the brief's "no new persisted state". A cooldown that a
-- save-and-reload defeats is not a cooldown -- it would silently do nothing, which is worse
-- than not shipping it. It is not synced: onset is server-side only and no client ever
-- computes it, so a client has no use for the value.
---@param daysPerMonth number
---@return number days
function HybridStrains.cooldownDays(daysPerMonth)
    return (SoilConstants.HYBRID.REONSET_COOLDOWN_MONTHS or 1) * math.max(1, daysPerMonth or 1)
end

---@return boolean
function HybridStrains.isInCooldown(field, currentDay)
    local until_ = field and field.hybridBlockedUntilDay
    if type(until_) ~= "number" then return false end
    return (currentDay or 0) < until_
end

--- Arm the cooldown. Called when a hybrid infection clears.
function HybridStrains.beginCooldown(field, currentDay, daysPerMonth)
    if not field then return end
    field.hybridBlockedUntilDay = (currentDay or 0) + HybridStrains.cooldownDays(daysPerMonth)
end

---@return boolean
function HybridStrains.isHybrid(diseaseId)
    local def = diseaseId and SoilConstants.DISEASE_DEFS[diseaseId]
    return def ~= nil and def.requiresModes ~= nil
end

--- The hybrid id a qualifying pair breeds. ONE resistant complex per crop family (the
--- 2026-08-01 count ruling): resolve the field's current crop to its family and return
--- resistant_complex_<family>; with no family, return the default resistant_complex.
---
--- THE EXPLICIT LOOKUP REPLACES THE OLD pairs() SCAN, and that replacement is a defect
--- fix filed as F94. The scan was exact while exactly one row qualified and a coin toss
--- at seven: Lua guarantees no pairs() iteration order, and two processes can iterate
--- the same table differently, so a dedicated server and a joining client could pick
--- DIFFERENT strains from identical data with nothing raised on either side. The lookup
--- removes the non-determinism by construction and is cheaper than the scan.
---@param field table
---@param _m1 string
---@param _m2 string
---@return string|nil
function HybridStrains.strainForPair(field, _m1, _m2)
    local crop = field and field.lastCrop
    if type(crop) == "string" and crop ~= "" then
        local family = SoilConstants.HYBRID_CROP_FAMILY[string.lower(crop)]
        if family ~= nil then return "resistant_complex_" .. family end
    end
    return "resistant_complex"
end

--- THE PRE-PASS. Returns a hybrid disease id when this field should breed one, else nil.
---
--- Runs inside _updateActiveDisease AFTER that day's resistance decay, so a mode that decays
--- below threshold on the same day it would otherwise have qualified reads as ineligible.
--- That ordering is confirmed in source, not assumed: decay and the onset call are both
--- inside _processOneDailyField and decay is first.
---@param field table
---@param currentDay number
---@return string|nil hybridId, string|nil m1, string|nil m2
function HybridStrains.selectOnset(field, currentDay)
    if not field then return nil end
    if HybridStrains.isInCooldown(field, currentDay) then return nil end
    local m1, m2 = HybridStrains.selectPair(field)
    if not m1 then return nil end
    local id = HybridStrains.strainForPair(field, m1, m2)
    if not id then return nil end
    return id, m1, m2
end

-- ── THE RULED CONTROL FACTOR (2026-07-30, Arissani delegated) ─────────────────────────
--
-- The problem it closes, between two individually correct designs: CD-12 scores a blend's
-- control as the MAX over its partners, and a hybrid's brand-new category defaults every
-- chemical to 0.25. Composed, a blend would answer a hybrid no better than one fresh jug --
-- which defeats the hybrid's entire reason for existing.
--
-- The factor: scale the catalog multiplier by min(1, freshModesApplied / requiresModes),
-- where a FRESH mode is one whose resistance on this field is BELOW the eligibility
-- fraction. A single fill contributes one mode; a blend contributes its partners' DISTINCT
-- modes; a burned partner contributes nothing fresh.
--
-- Worked: single fresh jug 0.5x, blend spanning two fresh modes 1.0x, blend with one burned
-- partner 0.5x, two partners sharing one mode 0.5x.
--
-- THE ZERO CASE, and the reading matters. The bench bar says a blend of two burned partners
-- "scores 0x fresh scaling" but that "the base 0.25 category default still applies unscaled
-- by ruling, so the spray is poor, never zero-by-arithmetic". Multiplying by zero would
-- contradict the second half, so zero fresh modes means the factor is NOT APPLIED rather
-- than applied as 0. The spray is still correctly inert in that case -- CD-9's own
-- max-over-partners resistance penalty zeroes it, which is the right mechanism for it and
-- keeps this factor from being a second, hidden way to reach zero.
---@param field table
---@param diseaseId string
---@param chemIds table   array of applied chemical names (one for a jug, partners for a blend)
---@return number   multiplier in (0, 1]
function HybridStrains.freshModeFactor(field, diseaseId, chemIds)
    local def = diseaseId and SoilConstants.DISEASE_DEFS[diseaseId]
    local requires = def and def.requiresModes
    if not requires or requires <= 0 then return 1.0 end   -- ordinary disease: nothing changes

    local seen, fresh = {}, 0
    for _, chem in ipairs(chemIds or {}) do
        local mode = SoilFertilitySystem.getModeForFillType(chem)
        if mode and not seen[mode] then
            seen[mode] = true
            if not HybridStrains.isModeEligible(field, mode) then fresh = fresh + 1 end
        end
    end

    if fresh <= 0 then return 1.0 end   -- see THE ZERO CASE above
    return math.min(1.0, fresh / requires)
end
