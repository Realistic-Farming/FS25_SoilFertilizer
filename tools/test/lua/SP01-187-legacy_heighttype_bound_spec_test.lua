-- SP01-187-legacy_heighttype_bound_spec_test.lua
--
-- SP01-187 part (c): the legacy ground type fallback wrote height types past the
-- map's cap. main.lua's loadedMission appended every missing solid at
-- numHeightTypes + 1 with no bound, which is how savegame5 got POLIFOSKA at index
-- 64 on a 6-channel map. The engine's own rule (DensityMapHeightManager.lua:208-211)
-- is 2 ^ numChannels - 1 types, numChannels from the map XML, default 6 (:117-118);
-- a type past it is logged and skipped. The legacy path now applies that rule.
--
-- THE ENTRY-POINT BAR IS GROUP S. The roster is not hand-filled: every row, the
-- base map's and Soil's own xml/densityMapHeightTypes.xml (read from the repo as
-- text), enters through a model of the engine's own registration routine
-- (loadDensityMapHeightTypeFromXML :197-221, sortHeightTypes :187-196), cap included.
-- Then SoilLegacyGroundTypes.inject runs exactly as main.lua's loadedMission calls
-- it; group T pins that call site and the source line as TEXT, because main.lua
-- sources the whole mod and cannot load under the bench.
--
-- Groups:
--   S  the entry-point bar: a full 6-channel map with Soil's XML registered by the
--      engine; POLIFOSKA would be index 64 and is skipped, logged once
--   N  near full with Soil's XML refused: what fits is registered, the rest skipped
--   C  controls, cap not reached: every type registered as before
--   L  a saved mapping that already holds POLIFOSKA at 64 (savegame5's case)
--   M  a server and a client build the same roster and skip the same types
--   G  SG-6's joined path keeps its all-or-nothing refusal
--   T  source witness: main.lua's source line and call site
--
-- What this bar does NOT prove: how the engine treats terrain pixels an old save
-- tipped at an index its channels cannot hold, the texture array rebuild, or
-- tipping in a game. The heap ceiling itself is a Design question, not this row.
--
--!load: src/utils/Logger.lua, src/hooks/SoilLegacyGroundTypes.lua, src/hooks/SoilCapacityIntegration.lua
--!text: src/main.lua, xml/densityMapHeightTypes.xml, src/hooks/SoilCapacityIntegration.lua

local L = SoilLegacyGroundTypes
local SOLIDS = { "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA", "GYPSUM", "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE" }

-- ── log capture: SoilLogger prints through the global print, so the capture is
-- scoped to one injection call (the test framework reports through print too).
local LOG = {}
local function inject(hm, fm)
    local realPrint = print
    LOG = {}
    print = function(s) LOG[#LOG + 1] = tostring(s) end
    local ok, registered, skipped = pcall(L.inject, hm, fm)
    print = realPrint
    if not ok then error(registered, 0) end
    return registered, skipped
end
local function warnings()
    local out = {}
    for _, l in ipairs(LOG) do if l:find("WARNING", 1, true) then out[#out + 1] = l end end
    return out
end

-- ── the fill type manager: base names, the two templates, Soil's twelve ─────────
local function newFillManager(baseCount)
    local names = { "UNKNOWN", "FERTILIZER", "MANURE" }
    for i = 1, baseCount do names[#names + 1] = string.format("BASE%02d", i) end
    for _, n in ipairs(SOLIDS) do names[#names + 1] = n end
    local byName, byIndex = {}, {}
    for i, n in ipairs(names) do byName[n] = i byIndex[i] = n end
    return { getFillTypeIndexByName = function(_, n) return byName[n] end,
             getFillTypeNameByIndex = function(_, i) return byIndex[i] end, _byName = byName }
end

-- ── the engine's DensityMapHeightManager, modelled from the decompile ──────────
-- initDataStructures (:41-50), loadDensityMapHeightTypes' channel count (:117-118),
-- loadDensityMapHeightTypeFromXML's cap and insertion (:197-221), sortHeightTypes
-- (:187-196), saveToXMLFile (:170-185) and loadFromXMLFile (:150-168).
local function newManager(numChannels)
    return { heightTypes = {}, fillTypeNameToHeightType = {}, fillTypeIndexToHeightType = {}, heightTypeIndexToFillTypeIndex = {},
             numHeightTypes = 0, heightTypeNumChannels = math.max(numChannels or 6, 6), tipTypeMappings = {}, engineErrors = {} }
end
local function sortHeightTypes(hm)
    table.sort(hm.heightTypes, function(a, b) return a.fillTypeIndex < b.fillTypeIndex end)
    hm.heightTypeIndexToFillTypeIndex = {}
    for i = 1, #hm.heightTypes do
        hm.heightTypes[i].index = i
        hm.heightTypeIndexToFillTypeIndex[i] = hm.heightTypes[i].fillTypeIndex
    end
end
local function engineRegister(hm, fm, name)
    local idx = fm:getFillTypeIndexByName(name)
    if idx == nil then return end   -- :201-203, "has invalid fill type"
    if hm.fillTypeNameToHeightType[name] ~= nil then return end
    local maxNum = 2 ^ hm.heightTypeNumChannels - 1
    if maxNum <= hm.numHeightTypes then
        hm.engineErrors[#hm.engineErrors + 1] = name
        return
    end
    hm.numHeightTypes = hm.numHeightTypes + 1
    local ht = { index = hm.numHeightTypes, fillTypeName = name, fillTypeIndex = idx, maxSurfaceAngle = 0.45, canBeTipped = true,
                 material = name == "MANURE" and "dark" or "granular" }
    table.insert(hm.heightTypes, ht)
    hm.fillTypeNameToHeightType[name] = ht
    hm.fillTypeIndexToHeightType[idx] = ht
    hm.heightTypeIndexToFillTypeIndex[ht.index] = idx
    sortHeightTypes(hm)
end
local function saveMapping(hm)
    local out = {}
    for _, ht in ipairs(hm.heightTypes) do out[#out + 1] = { fillType = ht.fillTypeName, index = ht.index } end
    return out
end
local function loadMapping(hm, saved)
    hm.tipTypeMappings = {}
    for _, e in ipairs(saved) do hm.tipTypeMappings[string.lower(e.fillType)] = e.index end
end

-- Soil's own height-type XML, read from the repo: the names the engine is handed.
local function soilXmlNames()
    local out = {}
    for n in (SOURCE_TEXT["xml/densityMapHeightTypes.xml"] or ""):gmatch('fillTypeName="([%w_]+)"') do out[#out + 1] = n end
    return out
end

--- Load one map: the base roster (FERTILIZER, MANURE and `base` more) through the
--- engine, then Soil's XML through the engine unless `xmlRefused`.
local function loadMap(opts)
    local fm = newFillManager(opts.base)
    local hm = newManager(opts.channels)
    engineRegister(hm, fm, "FERTILIZER")
    engineRegister(hm, fm, "MANURE")
    for i = 1, opts.base do engineRegister(hm, fm, string.format("BASE%02d", i)) end
    if not opts.xmlRefused then for _, n in ipairs(soilXmlNames()) do engineRegister(hm, fm, n) end end
    return hm, fm
end

local function maxIndexOf(hm)
    local m = 0
    for i, ht in pairs(hm.heightTypes) do if i > m then m = i end if ht.index > m then m = ht.index end end
    return m
end
local function slotOf(hm, fm, name) local ht = hm.fillTypeIndexToHeightType[fm:getFillTypeIndexByName(name)] return ht and ht.index or nil end
local function consistent(hm)
    for i = 1, hm.numHeightTypes do
        local ht = hm.heightTypes[i]
        if ht == nil or ht.index ~= i or hm.heightTypeIndexToFillTypeIndex[i] ~= ht.fillTypeIndex or hm.fillTypeIndexToHeightType[ht.fillTypeIndex] ~= ht then return false end
    end
    return hm.heightTypes[hm.numHeightTypes + 1] == nil
end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end

-- ══════════════════════════════════════════════════════════════════════════
-- S. THE ENTRY-POINT BAR: a full 6-channel map, POLIFOSKA would be index 64
-- ══════════════════════════════════════════════════════════════════════════
group("S", function()
    T.eq("S0 Soil's XML hands the engine eleven solids and not POLIFOSKA", table.concat(soilXmlNames(), ","),
        "UREA,AN,AMS,MAP,DAP,POTASH,GYPSUM,COMPOST,BIOSOLIDS,CHICKEN_MANURE,PELLETIZED_MANURE")
    local hm, fm = loadMap({ base = 50 })
    T.eq("S1 the engine filled the map to its cap of 63 with no refusal of its own", hm.numHeightTypes .. "/" .. string.format("%d", L.maxIndex(hm)) .. "/" .. #hm.engineErrors, "63/63/0")
    local registered, skipped = inject(hm, fm)
    T.eq("S2 POLIFOSKA is skipped, nothing is registered", tostring(registered) .. "/" .. table.concat(skipped, ","), "0/POLIFOSKA")
    T.eq("S3 no height type above the cap exists, the roster is untouched", hm.numHeightTypes .. "/" .. maxIndexOf(hm) .. "/" .. tostring(slotOf(hm, fm, "POLIFOSKA")) .. "/" .. tostring(consistent(hm)), "63/63/nil/true")
    local w = warnings()
    T.eq("S4 one warning names the skipped type and the map's cap", #w .. "|" .. tostring(w[1]),
        "1|[SoilFertilizer] WARNING: [TIP FIX] 1 solid fill type(s) cannot be tipped to the ground: the map's 6 height-type channel(s) hold 63 types and all are in use. Skipped: POLIFOSKA")
    local again = inject(hm, fm)
    T.eq("S5 a repeat call skips the same type again, with one warning", tostring(again) .. "/" .. hm.numHeightTypes .. "/" .. #warnings(), "0/63/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- N. Near full, Soil's XML refused: what fits is registered, the rest skipped
-- ══════════════════════════════════════════════════════════════════════════
group("N", function()
    local hm, fm = loadMap({ base = 58, xmlRefused = true })
    T.eq("N1 sixty rows before the fallback", hm.numHeightTypes, 60)
    local registered, skipped = inject(hm, fm)
    T.eq("N2 three fit, in the fixed order, at 61 to 63", tostring(registered) .. "/" .. slotOf(hm, fm, "UREA") .. "," .. slotOf(hm, fm, "AN") .. "," .. slotOf(hm, fm, "AMS"), "3/61,62,63")
    T.eq("N3 the nine that do not fit are skipped by name", table.concat(skipped, ","), "MAP,DAP,POTASH,POLIFOSKA,GYPSUM,COMPOST,BIOSOLIDS,CHICKEN_MANURE,PELLETIZED_MANURE")
    T.eq("N4 no index above 63, the maps agree", hm.numHeightTypes .. "/" .. maxIndexOf(hm) .. "/" .. tostring(consistent(hm)), "63/63/true")
    T.eq("N5 one warning for the nine", #warnings(), 1)
    T.eq("N6 the registered rows are the template shallow copies the old path made", hm.heightTypes[61].material .. "/" .. tostring(hm.heightTypes[61].canBeTipped) .. "/" .. tostring(hm.heightTypes[61].allowsSmoothing), "granular/true/false")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. Controls: the cap is not reached, every type registers as before
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local hm, fm = loadMap({ base = 38, xmlRefused = true })
    local registered, skipped = inject(hm, fm)
    local slots = {}
    for _, n in ipairs(SOLIDS) do slots[#slots + 1] = tostring(slotOf(hm, fm, n)) end
    T.eq("C1 all twelve appended at 41 to 52 in the fixed order, nothing skipped, nothing logged",
        tostring(registered) .. "/" .. #skipped .. "/" .. #warnings() .. "/" .. table.concat(slots, ","), "12/0/0/41,42,43,44,45,46,47,48,49,50,51,52")
    T.eq("C2 organics take the MANURE row, minerals FERTILIZER", hm.heightTypes[slotOf(hm, fm, "COMPOST")].material .. "/" .. hm.heightTypes[slotOf(hm, fm, "UREA")].material, "dark/granular")
    local hm2, fm2 = loadMap({ base = 38 })
    local r2, s2 = inject(hm2, fm2)
    T.eq("C3 with Soil's XML registered by the engine, only POLIFOSKA is appended, at 52", tostring(r2) .. "/" .. #s2 .. "/" .. tostring(slotOf(hm2, fm2, "POLIFOSKA")) .. "/" .. tostring(consistent(hm2)), "1/0/52/true")
    local hm3, fm3 = loadMap({ base = 58, xmlRefused = true, channels = 7 })
    local r3, s3 = inject(hm3, fm3)
    T.eq("C4 a 7-channel map allows 127, so all twelve fit past 63", tostring(r3) .. "/" .. #s3 .. "/" .. string.format("%d", L.maxIndex(hm3)) .. "/" .. maxIndexOf(hm3), "12/0/127/72")
    local fm4 = newFillManager(0)
    local hm4 = newManager(6)
    engineRegister(hm4, fm4, "WHEAT")
    T.eq("C5 no template: nil, as main.lua's warning branch expects, and nothing written", tostring(inject(hm4, fm4)) .. "/" .. hm4.numHeightTypes, "nil/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- L. A saved mapping that already holds POLIFOSKA at 64 (savegame5's case)
-- ══════════════════════════════════════════════════════════════════════════
group("L", function()
    -- The save as the unbounded path left it: the full map plus POLIFOSKA at 64.
    local old, oldFm = loadMap({ base = 50 })
    local polifoska = oldFm:getFillTypeIndexByName("POLIFOSKA")
    local ht = { index = 64, fillTypeName = "POLIFOSKA", fillTypeIndex = polifoska }
    old.heightTypes[64], old.numHeightTypes = ht, 64
    local saved = saveMapping(old)
    T.eq("L1 the old save's mapping holds POLIFOSKA at 64", (function() for _, e in ipairs(saved) do if e.fillType == "POLIFOSKA" then return e.index end end end)(), 64)
    -- The next load of that save: the engine reads the mapping (FSBaseMission.lua:1372),
    -- builds the same map, and Soil's fallback runs at loadMission00Finished.
    local hm, fm = loadMap({ base = 50 })
    loadMapping(hm, saved)
    local registered, skipped = inject(hm, fm)
    T.eq("L2 the saved 64 does not steer the fallback: POLIFOSKA is skipped, nothing past 63", tostring(registered) .. "/" .. table.concat(skipped, ",") .. "/" .. maxIndexOf(hm), "0/POLIFOSKA/63")
    T.eq("L3 the saved mapping is left as the engine read it", tostring(hm.tipTypeMappings.polifoska), "64")
    local resaved = saveMapping(hm)
    local highest, hasPolifoska = 0, false
    for _, e in ipairs(resaved) do if e.index > highest then highest = e.index end if e.fillType == "POLIFOSKA" then hasPolifoska = true end end
    T.eq("L4 the next save carries 63 rows, none past 63 and no POLIFOSKA: the stale 64 is not written again", #resaved .. "/" .. highest .. "/" .. tostring(hasPolifoska), "63/63/false")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- M. A server and a client build the same roster and skip the same types
-- ══════════════════════════════════════════════════════════════════════════
group("M", function()
    local function roster(isServer)
        g_server = isServer and {} or nil
        local hm, fm = loadMap({ base = 58, xmlRefused = true })
        local _, skipped = inject(hm, fm)
        local rows = {}
        for i = 1, hm.numHeightTypes do rows[#rows + 1] = hm.heightTypes[i].fillTypeName .. "@" .. i end
        g_server = nil
        return table.concat(rows, ","), table.concat(skipped, ",")
    end
    local sRows, sSkipped = roster(true)
    local cRows, cSkipped = roster(false)
    T.ok("M1 server and client agree on every index", sRows == cRows and sRows:find("AMS@63", 1, true) ~= nil)
    T.eq("M2 and on the skipped names", tostring(sSkipped == cSkipped) .. "/" .. sSkipped, "true/MAP,DAP,POTASH,POLIFOSKA,GYPSUM,COMPOST,BIOSOLIDS,CHICKEN_MANURE,PELLETIZED_MANURE")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- G. SG-6's joined path keeps its all-or-nothing refusal
-- ══════════════════════════════════════════════════════════════════════════
group("G", function()
    local hm, fm = loadMap({ base = 58, xmlRefused = true })
    local before = hm.numHeightTypes
    local ok, reason, name = SoilCapacityIntegration.prepareGroundTypes(hm, fm, L.maxIndex(hm))
    T.eq("G1 at the same cap SG-6 still refuses the whole set, naming the first type past it", tostring(ok) .. "/" .. tostring(reason) .. "/" .. tostring(name), "false/GROUND_CAPACITY/MAP")
    T.eq("G2 and writes nothing, where the legacy path would have written three", hm.numHeightTypes - before, 0)
    T.ok("G3 SG-6's module does not call the legacy injection", not (SOURCE_TEXT["src/hooks/SoilCapacityIntegration.lua"] or ""):find("SoilLegacyGroundTypes", 1, true))
end)

-- ══════════════════════════════════════════════════════════════════════════
-- T. Source witness: main.lua's source line and loadedMission's call site
-- ══════════════════════════════════════════════════════════════════════════
group("T", function()
    local main = SOURCE_TEXT and SOURCE_TEXT["src/main.lua"] or ""
    T.ok("T1 main.lua sources the module", main:find('source(modDirectory .. "src/hooks/SoilLegacyGroundTypes.lua")', 1, true) ~= nil)
    local joined = main:find("SoilCapacityIntegration.isJoined(mission)", 1, true)
    local call = main:find("local registered = SoilLegacyGroundTypes.inject(dmhm, ftm)", 1, true)
    local gate = main:find("if registered > 0 then", 1, true)
    T.ok("T2 loadedMission calls the injection in the not-joined branch, before the tip gate it decides", joined ~= nil and call ~= nil and gate ~= nil and joined < call and call < gate)
    local _, calls = main:gsub("SoilLegacyGroundTypes%.inject%(", "")
    T.eq("T3 once, and main.lua no longer appends a height type itself", calls .. "/" .. tostring(main:find("numHeightTypes + 1", 1, true) ~= nil) .. "/" .. tostring(main:find("heightTypes[nextSlot]", 1, true) ~= nil), "1/false/false")
end)

