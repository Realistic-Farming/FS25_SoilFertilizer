-- =========================================================
-- FS25 Soil & Fertilizer - LEGACY GROUND TYPE INJECTION (SP01-187)
-- =========================================================
-- The Lua fallback main.lua runs at loadMission00Finished when this mission is
-- not joined to StockGuard's capacity load: the mod's solid fill types are
-- appended to g_densityMapHeightManager's tables after the engine built them,
-- each at numHeightTypes + 1, on a shallow copy of the FERTILIZER or MANURE
-- row. Moved here from main.lua unchanged, apart from the bound below, so a
-- bench can drive it the way main.lua's call site does.
--
-- THE BOUND. A map's height-type channels hold at most 2 ^ numChannels - 1
-- types; the engine logs a type past that and skips it
-- (DensityMapHeightManager.lua:208-211), with numChannels taken from the map's
-- densityMapHeightTypes#numChannels, default 6 (:117-118). This path had no
-- bound, which is how a full 6-channel map got POLIFOSKA at index 64
-- (savegame5). It now applies the engine's own rule: a type whose slot would
-- pass the cap is skipped, never written, and the skipped names are logged
-- once.
--
-- Every input is the map's and the mods' own data (the manager's channel count
-- and roster, the fill type names, the fixed order below), so a server and its
-- clients skip the same types and agree on every index.
--
-- SG-6's joined path (SoilCapacityIntegration.prepareGroundTypes) is separate
-- and keeps its all-or-nothing refusal; nothing here is shared with it.
-- =========================================================

SoilLegacyGroundTypes = SoilLegacyGroundTypes or {}

-- The solid fill types that need ground-tipping support, in the legacy order.
SoilLegacyGroundTypes.SOLID_TYPES = {
    "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA",
    "GYPSUM", "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE",
}

-- Which types use the organic (MANURE) template.
SoilLegacyGroundTypes.ORGANIC_SET = {
    COMPOST = true, BIOSOLIDS = true,
    CHICKEN_MANURE = true, PELLETIZED_MANURE = true,
}

--- The highest height-type index the map's channels can hold, by the engine's
--- own formula (DensityMapHeightManager.lua:208).
function SoilLegacyGroundTypes.maxIndex(dmhm)
    return 2 ^ (dmhm.heightTypeNumChannels or 6) - 1
end

--- Append every missing solid type that fits. Returns the number registered and
--- the list of names skipped for the cap, or nil when neither template exists.
function SoilLegacyGroundTypes.inject(dmhm, ftm)
    -- Two templates: FERTILIZER (light granular) for mineral types,
    -- MANURE (dark organic) for compost/biosolids/chicken manure/pelletized manure.
    -- Using the wrong template causes black/unlit pile rendering because the
    -- C++ material reference from the shallow copy drives the visual output.
    local tmplFert   = nil
    local tmplManure = nil
    local fertIdx    = ftm:getFillTypeIndexByName("FERTILIZER")
    local manureIdx  = ftm:getFillTypeIndexByName("MANURE")
    if fertIdx  then tmplFert   = dmhm.fillTypeIndexToHeightType[fertIdx]   end
    if manureIdx then tmplManure = dmhm.fillTypeIndexToHeightType[manureIdx] end

    -- Fall back to the other template if one is missing
    local tmpl = tmplFert or tmplManure
    if not tmpl then return nil end

    local maxIndex = SoilLegacyGroundTypes.maxIndex(dmhm)
    local registered, skipped = 0, {}
    for _, typeName in ipairs(SoilLegacyGroundTypes.SOLID_TYPES) do
        local idx = ftm:getFillTypeIndexByName(typeName)
        if idx and not dmhm.fillTypeIndexToHeightType[idx] then
            local nextSlot = dmhm.numHeightTypes + 1
            if nextSlot > maxIndex then
                skipped[#skipped + 1] = typeName
            else
                -- Shallow-copy the appropriate template so C++ object references
                -- (density map channel pointer, material, physics layer handle) are
                -- preserved. Organic types use MANURE to get the correct dark pile
                -- visual; mineral types use FERTILIZER for the light granular look.
                local srcTmpl = (SoilLegacyGroundTypes.ORGANIC_SET[typeName] and tmplManure) or tmplFert or tmpl
                local ht = {}
                for k, v in pairs(srcTmpl) do ht[k] = v end
                ht.allowsSmoothing  = false
                ht.canBeTipped      = true
                ht.fillTypeIndex    = idx
                ht.fillTypeName     = typeName
                ht.index            = nextSlot

                dmhm.fillTypeIndexToHeightType[idx]           = ht
                if dmhm.fillTypeNameToHeightType then
                    dmhm.fillTypeNameToHeightType[typeName]   = ht
                end
                dmhm.heightTypeIndexToFillTypeIndex[nextSlot] = idx
                dmhm.heightTypes[nextSlot]                    = ht
                dmhm.numHeightTypes                           = nextSlot
                registered = registered + 1
            end
        end
    end
    if #skipped > 0 then
        SoilLogger.warning("[TIP FIX] %d solid fill type(s) cannot be tipped to the ground: the map's %d height-type channel(s) hold %d types and all are in use. Skipped: %s",
            #skipped, dmhm.heightTypeNumChannels or 6, maxIndex, table.concat(skipped, ", "))
    end
    return registered, skipped
end
