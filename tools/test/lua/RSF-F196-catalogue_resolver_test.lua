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
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/hooks/HookManager.lua

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

-- ── DENSITY, and the unit the engine actually stores ─────────────────────────
-- FillTypeDesc.lua:71 reads physics#massPerLiter in KILOGRAMS and stores value*0.001,
-- over a default of 0.001 set at :13, so the stored field is TONNES per litre.
-- FillTypeManager.MASS_SCALE is 1. A comparison against a kg/ha rate that skips this
-- scale is out by a thousand, which is the unit error U2 exists to prevent.
do
    -- T.near, not T.eq: 0.00077 * 1000 is 0.7699999999999999 in binary floating
    -- point. The bar caught that on its first run, which is the right way round.
    T.near("F196 H1: a stored 0.00077 t/L reads as 0.77 kg/L, the UREA figure",
           HookManager.densityOf({ massPerLiter = 0.00077 }), 0.77, 1e-9)
    T.eq("F196 H2: the engine default 0.001 t/L reads as 1 kg/L",
         HookManager.densityOf({ massPerLiter = 0.001 }), 1)
    T.eq("F196 H3: nil fill type has no density", HookManager.densityOf(nil), nil)
    T.eq("F196 H4: a missing field has no density", HookManager.densityOf({}), nil)
    T.eq("F196 H5: zero is nonsense", HookManager.densityOf({ massPerLiter = 0 }), nil)
    T.eq("F196 H6: negative is nonsense", HookManager.densityOf({ massPerLiter = -0.5 }), nil)
    T.eq("F196 H7: a non-number is nonsense", HookManager.densityOf({ massPerLiter = "0.77" }), nil)
    -- NaN passes `> 0` in Lua only by failing it, but it also fails `<= 0`, so it
    -- reaches the multiply. The self-comparison is what catches it.
    local nan = 0 / 0
    T.eq("F196 H8: NaN does not survive as a density", HookManager.densityOf({ massPerLiter = nan }), nil)
    -- The limit, pinned so nobody later believes this detects an undeclared density.
    T.eq("F196 H9: an UNDECLARED density is indistinguishable from a declared 1 kg/L, and is accepted",
         HookManager.densityOf({ massPerLiter = 0.001 }), HookManager.densityOf({ massPerLiter = 0.001 }))
end

-- ── WHAT ACTUALLY PROTECTS THE DOSE, which is not the density test ───────────
-- Bob's finding in the F196 intake: 28 fill types in this mod declare
-- massPerLiter="0.001", one gram per litre, every crop-protection product and every
-- BLEND_* type. That is POSITIVE, so a nil-or-non-positive density test accepts it.
-- If such a product were ever treated as a dry product to be mass-dosed, the
-- conversion would be wrong by about a thousand and the density gate would not
-- object, because there is nothing invalid about the number.
--
-- So membership, not density, is what keeps a volume-dosed product out of the mass
-- path. This pins that boundary directly rather than trusting it.
do
    local cp = { massPerLiter = 0.001 }    -- a crop-protection product's declared density
    T.near("F196 I1: a 0.001 t/L product has a perfectly valid density of 1 kg/L",
           HookManager.densityOf(cp), 1, 1e-12)
    local DRY = {}
    for _, n in ipairs(HookManager.DRY_PRODUCT_NAMES) do DRY[n] = true end
    T.eq("F196 I2: the dry catalogue is exactly twelve products", #HookManager.DRY_PRODUCT_NAMES, 12)
    T.eq("F196 I3: a fungicide is not one of them, which is the real gate",
         DRY["PROPICONAZOLE"], nil)
    T.eq("F196 I4: nor is a blend", DRY["BLEND_A"], nil)
    T.eq("F196 I5: and the twelve are the ones R7 recovers",
         DRY["UREA"] and DRY["AN"] and DRY["POLIFOSKA"] and DRY["GYPSUM"], true)
    -- The point restated as a property: density cannot tell these apart, membership can.
    T.eq("F196 I6: density alone cannot distinguish a fungicide from a fertiliser",
         HookManager.densityOf({ massPerLiter = 0.001 }) ~= nil
         and HookManager.densityOf({ massPerLiter = 0.00077 }) ~= nil, true)
end

-- ── a nil density is not a product defect ────────────────────────────────────
-- FillTypeDesc.lua:13 and :71 mean the loader always writes a number, over the
-- schema default of 1 kg at :290. A nil only appears on an object that did not come
-- through the loader, so refusing it would fire the gate on fixtures rather than on
-- products. densityOf still answers nil, because it cannot assess one.
do
    T.eq("F196 J1: densityOf cannot assess a fill type with no massPerLiter",
         HookManager.densityOf({ name = "FIXTURE" }), nil)
end

-- ── R1/R1a/R6: the refusal at registration, and the retry that clears it ─────
-- A density-refused solid is RESOLVED BUT NOT REGISTERED, and its index goes in the
-- refused table. Refusal is then a fact read by name rather than inferred from a
-- zero, which matters because AI-1's entry condition is both dose fields being zero
-- or nil: a numeric refusal would be indistinguishable from an empty tank a helper
-- should refill.
--
-- This needs a synthetic invalid product. All twelve dry products in the shipped
-- fillTypes.xml declare a valid density (0.60 to 1.10 kg/L), so the gate fires on
-- nothing in today's configuration and there is no real product to point at.
do
    local savedFtm, savedStm = g_fillTypeManager, g_sprayTypeManager
    local declared = {}       -- name -> massPerLiter in t/L, nil means no such fill type
    local addedSprayTypes = {}

    g_fillTypeManager = {
        getFillTypeByName = function(_self, name)
            if declared[name] == nil then return nil end
            return { name = name, index = #name, massPerLiter = declared[name] }
        end,
        getFillTypeIndexByName = function(_self, name)
            if declared[name] == nil then return nil end
            return #name
        end,
    }
    g_sprayTypeManager = {
        getSprayTypeByName = function(_self, name)
            if name == "FERTILIZER" then return { litersPerSecond = 0.006, sprayGroundType = 3 } end
            if name == "LIQUIDFERTILIZER" then return { litersPerSecond = 0.0081, sprayGroundType = 2 } end
            return nil
        end,
        addSprayType = function(_self, name) addedSprayTypes[name] = true; return {} end,
    }

    local GY = #"GYPSUM"
    local mgr = HookManager.new()

    -- pass one: GYPSUM declares a negative density, UREA a good one
    declared["GYPSUM"] = -0.001
    declared["UREA"] = 0.00077
    addedSprayTypes = {}
    pcall(HookManager.registerCustomSprayTypes, mgr)
    T.eq("F196 K1: a negative density refuses the product", mgr:isRefusedProduct(GY), true)
    T.eq("F196 K2: and it is NOT registered as a spray type", addedSprayTypes["GYPSUM"], nil)
    T.eq("F196 K3: a valid sibling is unaffected and still registers", addedSprayTypes["UREA"], true)
    T.eq("F196 K4: the valid sibling is not refused", mgr:isRefusedProduct(#"UREA"), false)

    -- pass two: the retry finds it valid. R6 requires the entry to be removed
    -- atomically before the product is registered.
    declared["GYPSUM"] = 0.0011
    addedSprayTypes = {}
    pcall(HookManager.registerCustomSprayTypes, mgr)
    T.eq("F196 K5: a retry that resolves the density clears the refusal", mgr:isRefusedProduct(GY), false)
    T.eq("F196 K6: and the product registers on that pass", addedSprayTypes["GYPSUM"], true)

    -- zero is refused too, and refusal is by index rather than by name
    declared["GYPSUM"] = 0
    addedSprayTypes = {}
    pcall(HookManager.registerCustomSprayTypes, mgr)
    T.eq("F196 K7: a zero density refuses", mgr:isRefusedProduct(GY), true)
    T.eq("F196 K8: refusal is keyed by fill type index, not by name", mgr.refusedProducts[GY] ~= nil, true)

    -- a fill type that does not resolve at all leaves NO fabricated index (R1a)
    declared["GYPSUM"] = nil
    addedSprayTypes = {}
    local before = mgr:isRefusedProduct(GY)
    pcall(HookManager.registerCustomSprayTypes, mgr)
    T.eq("F196 K9: an unresolved name does not invent a refusal entry", mgr:isRefusedProduct(GY), before)

    g_fillTypeManager, g_sprayTypeManager = savedFtm, savedStm
end
