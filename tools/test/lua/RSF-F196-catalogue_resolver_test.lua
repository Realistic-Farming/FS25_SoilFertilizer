-- RSF-F196-catalogue_resolver_test.lua - identity, kept apart from price.
--
-- This bar covers V12/V12b (one name population, one catalogue, membership only)
-- and R1b (the one bounded product-intent resolver). It does NOT cover refusal;
-- that arrives with the clause that writes refusedProducts.
--
-- WHY IDENTITY IS ITS OWN CONTRACT. The repair's whole shape rests on "refuses the
-- right product", and that is not a checkable claim until identity is established
-- independently of price. A resolver reviewed against a stubbed catalogue proves
-- the chain runs, not that it answers with the product a player is holding.
--
-- The engine facts this leans on, read from D:\FS25_Decoded\dataS\scripts_decompiled:
--   FillUnit:getFillUnitLastValidFillType   FillUnit.lua:699
--   lastValidFillType is retained at empty and synced in FillUnit's own stream,
--   :482 initial and :541 update, so a client joining after the tank emptied
--   reaches the same product with no new event and no transmitted verdict.
--
-- Locked here:
--   ONE POPULATION          the price installer and the catalogue read the same
--                           list, and the list does not grow when rebuilt twice.
--   MEMBERSHIP ONLY         a catalogue entry says nothing about price, and a
--                           product with no price is still a member.
--   CANDIDATE ORDER         direct, then current, then last-valid, and current
--                           outranks last-valid so a real product switch wins.
--   NON-MEMBERS ARE NOT INTENT   every candidate is filtered by membership; a
--                           vanilla product reached through any step is not intent.
--   NO GUESSING             a fresh empty unit with no last-valid custom product
--                           has no intent, rather than a fabricated one.
--   NOTHING THROWS          a vehicle missing any of the three accessors answers
--                           nil rather than raising, because this runs inside the
--                           engine's own call path.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/hooks/HookManager.lua

FillType = FillType or {}
FillType.UNKNOWN = 0

-- ── a fill type manager with a fixed, known name-to-index map ────────────────
local NAMES = {}          -- name -> index
local nextIndex = 10
local function defineFillType(name)
    nextIndex = nextIndex + 1
    NAMES[name] = nextIndex
    return nextIndex
end

for _, n in ipairs(HookManager.buildCustomNamePopulation()) do defineFillType(n) end
local VANILLA = defineFillType("FERTILIZER")      -- deliberately NOT in the population

g_fillTypeManager = {
    getFillTypeIndexByName = function(_self, name) return NAMES[name] end,
}

local UREA = NAMES["UREA"]
local POTASH = NAMES["POTASH"]
local COMPOST = NAMES["COMPOST"]

-- ── ONE POPULATION ───────────────────────────────────────────────────────────
do
    local a = HookManager.buildCustomNamePopulation()
    local b = HookManager.buildCustomNamePopulation()
    T.eq("F196 A1: the population is the same length on a second call", #a, #b)
    T.ok("F196 A2: it is not empty", #a > 0)
    -- The blend list is APPENDED by SoilBlends.appendNames, so handing out a shared
    -- table would grow it every rebuild. A fresh table each call is the guard.
    T.ok("F196 A3: two calls return different tables, so appending cannot accumulate", a ~= b)
    local seen, dupes = {}, 0
    for _, n in ipairs(a) do
        if seen[n] then dupes = dupes + 1 end
        seen[n] = true
    end
    T.eq("F196 A4: the population carries no duplicate name", dupes, 0)
    T.ok("F196 A5: it includes the dry products R7 recovers, AN and POLIFOSKA among them",
         seen["AN"] == true and seen["POLIFOSKA"] == true and seen["UREA"] == true)
end

-- ── MEMBERSHIP ONLY ──────────────────────────────────────────────────────────
local hm = HookManager.new()
do
    T.eq("F196 B1: a fresh manager has an empty catalogue", next(hm.customProductIndices), nil)
    T.eq("F196 B2: and an empty refused table", next(hm.refusedProducts), nil)
    local n = hm:rebuildCustomProductCatalogue()
    T.ok("F196 B3: the rebuild resolved every name in the population", n == #HookManager.buildCustomNamePopulation())
    T.eq("F196 B4: a custom product is a member", hm:isCustomProduct(UREA), true)
    T.eq("F196 B5: a vanilla product is not", hm:isCustomProduct(VANILLA), false)
    T.eq("F196 B6: nil is not a member and does not throw", hm:isCustomProduct(nil), false)
    T.eq("F196 B7: membership says nothing about refusal", hm:isRefusedProduct(UREA), false)
    -- Price is never consulted: there is no price table in this fixture at all, and
    -- the catalogue is complete regardless.
    T.eq("F196 B8: the catalogue is complete with no price table in existence",
         hm:isCustomProduct(POTASH), true)
    local again = hm:rebuildCustomProductCatalogue()
    T.eq("F196 B9: rebuilding is idempotent, not additive", again, n)
end

-- ── a sprayer stand-in, one fill unit, each accessor independently controllable ──
local function sprayerWith(opts)
    opts = opts or {}
    local s = {}
    if not opts.noFuiAccessor then
        s.getSprayerFillUnitIndex = function()
            if opts.fuiThrows then error("boom") end
            return opts.fui or 1
        end
    end
    if not opts.noCurrentAccessor then
        s.getFillUnitFillType = function(_self, _idx)
            if opts.currentThrows then error("boom") end
            return opts.current
        end
    end
    if not opts.noLastValidAccessor then
        s.getFillUnitLastValidFillType = function(_self, _idx)
            if opts.lastValidThrows then error("boom") end
            return opts.lastValid
        end
    end
    return s
end

-- ── CANDIDATE ORDER ──────────────────────────────────────────────────────────
do
    local s = sprayerWith({ current = POTASH, lastValid = COMPOST })
    T.eq("F196 C1: a direct catalogue member wins over the tank",
         hm:resolveCustomProductIntent(s, UREA), UREA)
    T.eq("F196 C2: with no direct type, the current tank product wins",
         hm:resolveCustomProductIntent(s, nil), POTASH)
    T.eq("F196 C3: UNKNOWN as the direct type is not a candidate, the tank answers",
         hm:resolveCustomProductIntent(s, FillType.UNKNOWN), POTASH)

    local emptied = sprayerWith({ current = FillType.UNKNOWN, lastValid = COMPOST })
    T.eq("F196 C4: an emptied tank falls through to last-valid, the late-join answer",
         hm:resolveCustomProductIntent(emptied, nil), COMPOST)

    local switched = sprayerWith({ current = POTASH, lastValid = COMPOST })
    T.eq("F196 C5: current outranks last-valid, so a real product switch wins at once",
         hm:resolveCustomProductIntent(switched, nil), POTASH)
end

-- ── NON-MEMBERS ARE NOT INTENT ───────────────────────────────────────────────
do
    T.eq("F196 D1: a vanilla direct type is not intent",
         hm:resolveCustomProductIntent(sprayerWith({}), VANILLA), nil)
    T.eq("F196 D2: a vanilla product in the tank is not intent",
         hm:resolveCustomProductIntent(sprayerWith({ current = VANILLA }), nil), nil)
    T.eq("F196 D3: a vanilla last-valid is not intent",
         hm:resolveCustomProductIntent(sprayerWith({ current = FillType.UNKNOWN, lastValid = VANILLA }), nil), nil)
    -- The filter is membership, not "not UNKNOWN": a direct vanilla type must not
    -- shortcut past the tank, and a custom tank behind it must still be found.
    T.eq("F196 D4: a vanilla direct type does not mask a custom tank behind it",
         hm:resolveCustomProductIntent(sprayerWith({ current = UREA }), VANILLA), UREA)
end

-- ── NO GUESSING ──────────────────────────────────────────────────────────────
do
    local fresh = sprayerWith({ current = FillType.UNKNOWN, lastValid = FillType.UNKNOWN })
    T.eq("F196 E1: a fresh empty unit has no custom intent",
         hm:resolveCustomProductIntent(fresh, nil), nil)
    local nilTank = sprayerWith({ current = nil, lastValid = nil })
    T.eq("F196 E2: nil readings are not intent either",
         hm:resolveCustomProductIntent(nilTank, nil), nil)
end

-- ── NOTHING THROWS ───────────────────────────────────────────────────────────
do
    T.eq("F196 F1: a nil sprayer answers nil", hm:resolveCustomProductIntent(nil, nil), nil)
    T.eq("F196 F2: a nil sprayer with a direct member still answers the member",
         hm:resolveCustomProductIntent(nil, UREA), UREA)
    T.eq("F196 F3: no getSprayerFillUnitIndex at all",
         hm:resolveCustomProductIntent(sprayerWith({ noFuiAccessor = true }), nil), nil)
    T.eq("F196 F4: getSprayerFillUnitIndex raising",
         hm:resolveCustomProductIntent(sprayerWith({ fuiThrows = true }), nil), nil)
    T.eq("F196 F5: no getFillUnitFillType, last-valid still reached",
         hm:resolveCustomProductIntent(sprayerWith({ noCurrentAccessor = true, lastValid = COMPOST }), nil), COMPOST)
    T.eq("F196 F6: getFillUnitFillType raising, last-valid still reached",
         hm:resolveCustomProductIntent(sprayerWith({ currentThrows = true, lastValid = COMPOST }), nil), COMPOST)
    T.eq("F196 F7: no getFillUnitLastValidFillType, an older engine shape",
         hm:resolveCustomProductIntent(sprayerWith({ current = FillType.UNKNOWN, noLastValidAccessor = true }), nil), nil)
    T.eq("F196 F8: getFillUnitLastValidFillType raising",
         hm:resolveCustomProductIntent(sprayerWith({ current = FillType.UNKNOWN, lastValidThrows = true }), nil), nil)
    local ok = pcall(function() hm:resolveCustomProductIntent(sprayerWith({ fuiThrows = true }), nil) end)
    T.ok("F196 F9: a raising accessor does not propagate out of the resolver", ok)
end

-- ── an empty catalogue refuses everything, which is the pre-registration state ──
do
    local cold = HookManager.new()
    T.eq("F196 G1: before any rebuild, a custom index is not yet intent",
         cold:resolveCustomProductIntent(sprayerWith({ current = UREA }), UREA), nil)
    T.eq("F196 G2: and membership is false rather than nil", cold:isCustomProduct(UREA), false)
end
