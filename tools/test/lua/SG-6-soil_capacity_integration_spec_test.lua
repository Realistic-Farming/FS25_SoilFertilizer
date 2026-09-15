-- SG-6-soil_capacity_integration_spec_test.lua - the Soil half of SG-6.
--
-- Runs the real SoilCapacityIntegration and GroundTipGate against stubs for the
-- height manager, fill manager and engine predicate. Proves the protocol shape,
-- the joined-mode fence and its lifetime with the tip wrapper, and the ground
-- preparation contract: fixed order, skip-present, two templates, validate
-- before mutate with no partial insertion, consistent maps, idempotence and the
-- supplied map limit. The R3 fold discriminators from the family's SG-6
-- reference bar that concern Soil are re-run here against the built module.
-- main.lua's fence around the legacy block is read, not executed: main.lua
-- sources the whole mod and cannot load under the bench. Nothing here proves
-- native initialization, tipping, terrain layers, saves or multiplayer.
--
--!load: src/hooks/GroundTipGate.lua, src/hooks/SoilCapacityIntegration.lua

SoilLogger = SoilLogger or { info = function() end, warning = function() end, error = function() end }

local ORDER = { "UREA", "AN", "AMS", "MAP", "DAP", "POTASH", "POLIFOSKA", "GYPSUM", "COMPOST", "BIOSOLIDS", "CHICKEN_MANURE", "PELLETIZED_MANURE" }

-- A fill manager with native names plus the twelve solids (indices are arbitrary but stable).
local function newFillManager(missing)
    local names = { "UNKNOWN", "WHEAT", "FERTILIZER", "MANURE", "LIME" }
    for _, n in ipairs(ORDER) do
        if missing == nil or not missing[n] then names[#names + 1] = n end
    end
    local byName = {}
    for i, n in ipairs(names) do byName[n] = i end
    return { getFillTypeIndexByName = function(_, n) return byName[n] end, _byName = byName }
end

-- A height manager already holding the native rows (sorted) with the two templates.
local function newHeightManager(fm, present)
    local hm = { numHeightTypes = 0, heightTypes = {}, fillTypeNameToHeightType = {}, fillTypeIndexToHeightType = {}, heightTypeIndexToFillTypeIndex = {} }
    local function add(name, extra)
        local idx = fm._byName[name]
        local slot = hm.numHeightTypes + 1
        local ht = { index = slot, fillTypeName = name, fillTypeIndex = idx, canBeTipped = true, allowsSmoothing = false,
            maxSurfaceAngle = 0.45, fillToGroundScale = 1, collisionScale = 1, collisionBaseOffset = 0, minCollisionOffset = 0, maxCollisionOffset = 0.1 }
        for k, v in pairs(extra or {}) do ht[k] = v end
        hm.heightTypes[slot] = ht
        hm.fillTypeNameToHeightType[name] = ht
        hm.fillTypeIndexToHeightType[idx] = ht
        hm.heightTypeIndexToFillTypeIndex[slot] = idx
        hm.numHeightTypes = slot
    end
    add("WHEAT", { material = "grain-mat" })
    add("FERTILIZER", { material = "fert-mat", maxSurfaceAngle = 0.41 })
    add("MANURE", { material = "manure-mat", maxSurfaceAngle = 0.52 })
    for _, n in ipairs(present or {}) do add(n, { material = "xml-mat" }) end
    return hm
end

local function names(hm)
    local out = {}
    for i = 1, hm.numHeightTypes do out[#out + 1] = hm.heightTypes[i].fillTypeName end
    return table.concat(out, ",")
end

local function consistent(hm)
    for i = 1, hm.numHeightTypes do
        local ht = hm.heightTypes[i]
        if ht == nil or ht.index ~= i then return false, "index " .. i end
        if hm.heightTypeIndexToFillTypeIndex[i] ~= ht.fillTypeIndex then return false, "reverse " .. i end
        if hm.fillTypeIndexToHeightType[ht.fillTypeIndex] ~= ht then return false, "byIndex " .. i end
        if hm.fillTypeNameToHeightType[ht.fillTypeName] ~= ht then return false, "byName " .. i end
    end
    return true
end

local function freshProcess()
    SoilCapacityIntegration._resetForTests()
    GroundTipGate._resetForTests()
    DensityMapHeightUtil = { getCanTipToGround = function(idx) return idx == 99 end }
    g_densityMapHeightManager = { _valid = true, getIsValid = function(self) return self._valid end,
        fillTypeIndexToHeightType = { [1] = { canBeTipped = true }, [2] = { canBeTipped = false } } }
end

-- ── Protocol shape ────────────────────────────────────────────────────────────
do
    local api = SoilCapacityIntegration
    T.eq("protocol version is 2", api.protocolVersion, 2)
    T.eq("beginCapacityLoad is a function", type(api.beginCapacityLoad), "function")
    T.eq("prepareGroundTypes is a function", type(api.prepareGroundTypes), "function")
    T.eq("endCapacityLoad is a function", type(api.endCapacityLoad), "function")
    -- The family bar's preflight shape check, run against the real table.
    local function soilPreflight(selected, a)
        if selected and (type(a) ~= "table" or a.protocolVersion ~= 2 or type(a.beginCapacityLoad) ~= "function" or type(a.prepareGroundTypes) ~= "function" or type(a.endCapacityLoad) ~= "function") then return false, "SOIL_API" end
        return true, "OK"
    end
    T.eq("StockGuard preflight admits this protocol", (soilPreflight(true, api)), true)
    T.eq("dot call with a non-table mission is refused, not an error", api.beginCapacityLoad("mission"), false)
    -- A colon call shifts the arguments: the first parameter becomes the table itself.
    local ok = api:beginCapacityLoad({})
    T.eq("colon call binds the API table as the mission and then fails on the real mission", ok, true)
    T.eq("colon call left the API table as the joined mission, which a real mission rejects", api.beginCapacityLoad({}), false)
    SoilCapacityIntegration._resetForTests()
end

-- ── Joined mode fence and tip wrapper lifetime ──────────────────────────────
do
    freshProcess()
    local mission = { name = "m1" }
    -- Standalone first: the legacy path installs and enables the wrapper.
    GroundTipGate.install()
    GroundTipGate.enable()
    T.eq("control: active standalone wrapper overrides native false for an injected type", DensityMapHeightUtil.getCanTipToGround(2), false)
    T.eq("control: active standalone wrapper answers the type's own flag", DensityMapHeightUtil.getCanTipToGround(1), true)
    T.eq("joined mode begins true", SoilCapacityIntegration.beginCapacityLoad(mission), true)
    T.eq("joined mode disabled the legacy wrapper", GroundTipGate.isActive(), false)
    T.eq("disabled wrapper delegates to the captured predecessor (native false)", DensityMapHeightUtil.getCanTipToGround(1), false)
    T.eq("disabled wrapper delegates a predecessor true unchanged", DensityMapHeightUtil.getCanTipToGround(99), true)
    T.eq("isJoined identifies the exact mission", SoilCapacityIntegration.isJoined(mission), true)
    T.eq("isJoined refuses another table", SoilCapacityIntegration.isJoined({}), false)
    T.eq("begin is idempotent for the same mission", SoilCapacityIntegration.beginCapacityLoad(mission), true)
    T.eq("a different still-active mission is rejected", SoilCapacityIntegration.beginCapacityLoad({ name = "m2" }), false)
    T.eq("the rejected mission is not joined", SoilCapacityIntegration.isJoined({ name = "m2" }), false)
    -- Re-enabling from the legacy path while joined must not happen; main.lua skips the block.
    -- The gate itself still honours a direct enable, so the fence is main.lua's job:
    T.eq("end for a non-matching mission leaves the binding", (SoilCapacityIntegration.endCapacityLoad({ name = "other" })), true)
    T.eq("binding survives a non-matching end", SoilCapacityIntegration.isJoined(mission), true)
    T.eq("end for the matching mission clears it", (SoilCapacityIntegration.endCapacityLoad(mission)), true)
    T.eq("binding cleared", SoilCapacityIntegration.isJoined(mission), false)
    T.eq("legacy override stays disabled after end", GroundTipGate.isActive(), false)
    T.eq("repeat end is safe", (SoilCapacityIntegration.endCapacityLoad(mission)), true)
    T.eq("end with nil clears any binding", (function() SoilCapacityIntegration.beginCapacityLoad(mission) return SoilCapacityIntegration.endCapacityLoad(nil) end)(), true)
    T.eq("nil end cleared it", SoilCapacityIntegration.getJoinedMission(), nil)
    -- After end, a new mission may join.
    local m3 = { name = "m3" }
    T.eq("a new mission joins after the old one ended", SoilCapacityIntegration.beginCapacityLoad(m3), true)
    T.ok("the wrapper is still the single installed one", DensityMapHeightUtil.getCanTipToGround == GroundTipGate.getWrapper())
    SoilCapacityIntegration.endCapacityLoad(m3)
end

-- ── Preparation: fixed order, skip present, templates, maps, idempotence ───────
do
    freshProcess()
    local fm = newFillManager()
    local hm = newHeightManager(fm, { "UREA", "AN" })   -- two solids already registered by the map XML
    local before = names(hm)
    local ok, reason, name = SoilCapacityIntegration.prepareGroundTypes(hm, fm, 63)
    T.eq("prepare succeeds", ok, true)
    T.eq("no reason on success", reason, nil)
    T.eq("existing sorted rows untouched and missing rows appended in the fixed order", names(hm),
        before .. ",AMS,MAP,DAP,POTASH,POLIFOSKA,GYPSUM,COMPOST,BIOSOLIDS,CHICKEN_MANURE,PELLETIZED_MANURE")
    T.eq("present rows were not inserted a second time", hm.numHeightTypes, 5 + 10)
    T.ok("all four maps are consistent", (consistent(hm)))
    local urea = hm.fillTypeNameToHeightType["AMS"]
    T.eq("mineral row copies the FERTILIZER template material", urea.material, "fert-mat")
    T.eq("mineral row copies the FERTILIZER template angle", urea.maxSurfaceAngle, 0.41)
    local compost = hm.fillTypeNameToHeightType["COMPOST"]
    T.eq("organic row copies the MANURE template material", compost.material, "manure-mat")
    T.eq("organic row copies the MANURE template angle", compost.maxSurfaceAngle, 0.52)
    T.eq("new row is tippable", compost.canBeTipped, true)
    T.eq("new row does not smooth", compost.allowsSmoothing, false)
    T.eq("new row carries its own fill index", compost.fillTypeIndex, fm._byName["COMPOST"])
    T.ok("new row is a copy, not the template object", compost ~= hm.fillTypeNameToHeightType["MANURE"])
    T.eq("template object unchanged", hm.fillTypeNameToHeightType["MANURE"].fillTypeName, "MANURE")
    local after = names(hm)
    T.eq("repeat prepare is idempotent", (SoilCapacityIntegration.prepareGroundTypes(hm, fm, 63)), true)
    T.eq("repeat prepare inserted nothing", names(hm), after)
    T.eq("repeat prepare kept the count", hm.numHeightTypes, 15)
    -- The family bar's append-order discriminator: POLIFOSKA keeps its appended slot behind ZINC-like natives.
    T.eq("appended POLIFOSKA sits after every existing row", hm.fillTypeNameToHeightType["POLIFOSKA"].index, 10)
end

-- ── Preparation: validate before mutate, no partial insertion ────────────────
do
    freshProcess()
    -- Missing native fill for the seventh name: nothing before it is inserted either.
    local fm = newFillManager({ POLIFOSKA = true })
    local hm = newHeightManager(fm)
    local before = names(hm)
    local ok, reason, name = SoilCapacityIntegration.prepareGroundTypes(hm, fm, 63)
    T.eq("missing native fill refuses", ok, false)
    T.eq("with the stable reason", reason, "MISSING_NATIVE_FILL")
    T.eq("naming the offending type", name, "POLIFOSKA")
    T.eq("no partial insertion", names(hm), before)
    T.eq("count unchanged", hm.numHeightTypes, 3)

    -- Map limit exhausted midway: refuse the whole roster with the name that would not fit.
    local fm2 = newFillManager()
    local hm2 = newHeightManager(fm2)
    local ok2, reason2, name2 = SoilCapacityIntegration.prepareGroundTypes(hm2, fm2, 8)
    T.eq("exhausted map limit refuses", ok2, false)
    T.eq("with GROUND_CAPACITY", reason2, "GROUND_CAPACITY")
    T.eq("naming the first type that would exceed the limit (slots 4 to 8 hold UREA to DAP)", name2, "POTASH")
    T.eq("no partial insertion on capacity", hm2.numHeightTypes, 3)
    -- Exactly enough room succeeds.
    T.eq("exact room for twelve rows succeeds", (SoilCapacityIntegration.prepareGroundTypes(hm2, fm2, 15)), true)
    T.eq("all twelve appended", hm2.numHeightTypes, 15)

    -- Both templates missing: no row can be built.
    local fm3 = newFillManager()
    local hm3 = { numHeightTypes = 0, heightTypes = {}, fillTypeNameToHeightType = {}, fillTypeIndexToHeightType = {}, heightTypeIndexToFillTypeIndex = {} }
    local ok3, reason3, name3 = SoilCapacityIntegration.prepareGroundTypes(hm3, fm3, 63)
    T.eq("missing templates refuse", ok3, false)
    T.eq("with MISSING_TEMPLATE", reason3, "MISSING_TEMPLATE")
    T.eq("naming the first type", name3, "UREA")
    T.eq("nothing inserted without a template", hm3.numHeightTypes, 0)

    -- Only the MANURE template present: minerals fall back to it (as the legacy path does).
    local fm4 = newFillManager()
    local hm4 = { numHeightTypes = 0, heightTypes = {}, fillTypeNameToHeightType = {}, fillTypeIndexToHeightType = {}, heightTypeIndexToFillTypeIndex = {} }
    local mIdx = fm4._byName["MANURE"]
    local mt = { index = 1, fillTypeName = "MANURE", fillTypeIndex = mIdx, material = "manure-mat" }
    hm4.heightTypes[1] = mt; hm4.fillTypeNameToHeightType["MANURE"] = mt; hm4.fillTypeIndexToHeightType[mIdx] = mt; hm4.heightTypeIndexToFillTypeIndex[1] = mIdx; hm4.numHeightTypes = 1
    T.eq("single template still prepares", (SoilCapacityIntegration.prepareGroundTypes(hm4, fm4, 63)), true)
    T.eq("mineral falls back to the only template", hm4.fillTypeNameToHeightType["UREA"].material, "manure-mat")

    -- Invalid arguments are refused, not errors.
    T.eq("nil managers refused", (SoilCapacityIntegration.prepareGroundTypes(nil, fm, 63)), false)
    T.eq("non-integer limit refused", (SoilCapacityIntegration.prepareGroundTypes(newHeightManager(fm2), fm2, 6.5)), false)
    T.eq("zero limit refused", (SoilCapacityIntegration.prepareGroundTypes(newHeightManager(fm2), fm2, 0)), false)
end

-- ── The family bar's R3 discriminators against the built module ─────────────
do
    freshProcess()
    local mission = { name = "joined" }
    -- Joined before either preparation result; a failed prepare never releases the fence.
    T.eq("begin precedes prepare", SoilCapacityIntegration.beginCapacityLoad(mission), true)
    local fm = newFillManager({ AN = true })
    local hm = newHeightManager(fm)
    T.eq("prepare failure reported", (SoilCapacityIntegration.prepareGroundTypes(hm, fm, 63)), false)
    T.eq("failed preparation leaves joined mode in place", SoilCapacityIntegration.isJoined(mission), true)
    T.eq("failed preparation leaves the legacy wrapper disabled", GroundTipGate.isActive(), false)
    -- Standalone Soil save, quit, then a compatible StockGuard mission in one process:
    -- the earlier wrapper never makes a native-false material tippable in joined mode.
    SoilCapacityIntegration.endCapacityLoad(mission)
    GroundTipGate.install(); GroundTipGate.enable()
    T.eq("standalone mission: wrapper active", GroundTipGate.isActive(), true)
    SoilCapacityIntegration.endCapacityLoad(nil)   -- Soil unload
    T.eq("unload disables the surviving wrapper", GroundTipGate.isActive(), false)
    local sg = { name = "stockguard-mission" }
    SoilCapacityIntegration.beginCapacityLoad(sg)
    g_densityMapHeightManager.fillTypeIndexToHeightType[2] = { canBeTipped = true }   -- an injected-looking row
    T.eq("joined mode never returns the old blanket true for a native-false material", DensityMapHeightUtil.getCanTipToGround(2), false)
    g_densityMapHeightManager._valid = false
    T.eq("invalid manager follows the predecessor while disabled", DensityMapHeightUtil.getCanTipToGround(99), true)
    SoilCapacityIntegration.endCapacityLoad(sg)
end
