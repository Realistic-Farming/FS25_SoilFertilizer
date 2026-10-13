-- SoilBlends.lua - CD-12: THE TANK MIX.
--
-- A farmer can buy eight physical fungicides and spray any one of them. He cannot spray two
-- at once, which in real disease management is the most important thing he would do: a mix
-- of two modes of action stops either one from carrying the whole selection pressure.
--
-- A fill type cannot be created at runtime, so every mix a player can ever hold must exist
-- at load. That constraint is the right architecture rather than merely the permitted one:
-- the fungicide consequence chain carries only the fill type NAME, so a self-describing
-- name is the only form that cannot part company from the liquid it labels when a tank is
-- saved, split, transferred or sold.
--
-- THE LOAD-BEARING RULE OF THIS WHOLE SYSTEM: registration for a crop-protection fill type
-- spans nine or more sites across two files, and missing one is INVISIBLE -- an uncalibrated
-- rate looks like it works; a missed density-map remap means no ground state is ever
-- written at all. So nothing here is hand-maintained. This table is the one source of truth
-- and every list is derived from it by a loop.
--
-- Loaded immediately after Constants.lua: it reads PHYSICAL_FUNGICIDE_ORDER and writes the
-- derived entries back into SoilConstants, so every later module sees a complete picture.

SoilBlends = SoilBlends or {}

SoilBlends.PREFIX = "BLEND_"

--- [blendName] = { partnerA, partnerB }, alphabetical.
SoilBlends.TABLE = {}
--- Array of blend names, alphabetical. The registration loops iterate this.
SoilBlends.ORDER = {}

-- ── Build the 28 pairs from the eight shipped chemicals ───────────────────────────────
--
-- The key is BLEND_ plus the two partner names in ALPHABETICAL order, so exactly one key
-- exists per unordered pair.
--
-- THE VALUE IS AN EXPLICIT LIST AND IS NEVER PRODUCED BY PARSING THE KEY. Both names are
-- in hand before the key is built, so they are stored directly. This matters:
-- COPPER_HYDROXIDE contains an underscore, so BLEND_COPPER_HYDROXIDE_SULFUR cannot be
-- split on "_" -- a parser would read it as COPPER + HYDROXIDE + SULFUR. A lookup cannot be
-- mis-parsed.
--
-- EVERY PAIR EXISTS AND THERE ARE NO REFUSALS, including the two earlier drafts refused:
-- same-FRAC pairs (propiconazole + tebuconazole, both group 3) are resistance-neutral under
-- the partner-count divisor and better on spectrum, and organic-plus-synthetic pairs are
-- legal to MAKE and correctly break certification when sprayed.
do
    local names = {}
    for _, n in ipairs(SoilConstants.PHYSICAL_FUNGICIDE_ORDER) do names[#names + 1] = n end
    table.sort(names)

    for i = 1, #names do
        for j = i + 1, #names do
            local a, b = names[i], names[j]           -- a < b, so the key is canonical
            local key = SoilBlends.PREFIX .. a .. "_" .. b
            SoilBlends.TABLE[key] = { a, b }
            SoilBlends.ORDER[#SoilBlends.ORDER + 1] = key
        end
    end
    table.sort(SoilBlends.ORDER)
end

--- The partner list for a blend, or nil for anything that is not one.
--- NIL MEANS "behave exactly as before" everywhere this is consulted.
---@param name string|nil
---@return table|nil   { partnerA, partnerB }
function SoilBlends.getPartners(name)
    if name == nil then return nil end
    return SoilBlends.TABLE[name]
end

---@return boolean
function SoilBlends.isBlend(name)
    return name ~= nil and SoilBlends.TABLE[name] ~= nil
end

--- Append every blend name to an existing array (the registration lists in HookManager).
--- Returns the same list for convenience.
---@param list table
---@return table
function SoilBlends.appendNames(list)
    for _, name in ipairs(SoilBlends.ORDER) do list[#list + 1] = name end
    return list
end

--- Add every blend name as a key in a set-style table.
---@param set table
---@param value any   value to store (defaults to true)
---@return table
function SoilBlends.addToSet(set, value)
    if value == nil then value = true end
    for _, name in ipairs(SoilBlends.ORDER) do set[name] = value end
    return set
end

-- ── Derived registrations into SoilConstants ──────────────────────────────────────────

do
    local DP = SoilConstants.DISEASE_PRESSURE
    local RATES = SoilConstants.SPRAYER_RATE.BASE_RATES

    for _, blend in ipairs(SoilBlends.ORDER) do
        local partners = SoilBlends.TABLE[blend]

        -- THE FIRST GATE. HookManager's spray dispatch reads FUNGICIDE_TYPES before the
        -- field is even resolved; a name absent from it sprays, drains the tank, costs the
        -- money and does nothing at all. Base multiplier 1.0 exactly as the eight singles
        -- carry -- the real per-disease control is applied at spray time from the catalog.
        DP.FUNGICIDE_TYPES[blend] = 1.0

        -- Application rate: the mean of the partners', so a blend calibrates like the
        -- chemicals in it rather than falling back to generic FUNGICIDE.
        local sum, n = 0, 0
        for _, p in ipairs(partners) do
            local r = RATES[p]
            if r and r.value then sum = sum + r.value; n = n + 1 end
        end
        RATES[blend] = { value = (n > 0) and (sum / n) or RATES.FUNGICIDE.value, unit = "liquid" }

        -- The custom fill-type roster this mod already maintains for its own types.
        SoilConstants.FERTILIZER_TYPES[#SoilConstants.FERTILIZER_TYPES + 1] = blend
    end
end

-- ── Organic legality: ONE positive entry, and it is COMPUTED rather than asserted ──────
--
-- isApprovedInput is a bare set lookup: a name absent from APPROVED_INPUTS breaches. That
-- default is already correct for 27 of the 28 -- a tank holding any synthetic should break
-- certification, and it does, with no code change and no name decomposition.
--
-- THE INVARIANT (authority #4, added when CD-12 re-triggered it): only a blend whose EVERY
-- partner is independently approved may join that set, and the breach evaluator must NEVER
-- be taught to decompose a composite name. Legality is decided at the table, once, by
-- membership.
--
-- Deriving it from the partners rather than hardcoding BLEND_COPPER_HYDROXIDE_SULFUR makes
-- that invariant STRUCTURAL: a future organic-approved chemical admits its all-approved
-- blends automatically, and no synthetic pair can ever slip in by a typo.
do
    local approved = SoilConstants.ORGANIC.APPROVED_INPUTS
    for _, blend in ipairs(SoilBlends.ORDER) do
        local allApproved = true
        for _, p in ipairs(SoilBlends.TABLE[blend]) do
            if approved[p] ~= true then allApproved = false; break end
        end
        if allApproved then approved[blend] = true end
    end
end
