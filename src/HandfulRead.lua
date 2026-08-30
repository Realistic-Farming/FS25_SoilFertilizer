-- =========================================================
-- FS25 Soil & Fertilizer - THE HANDFUL READ (SF-38)
-- =========================================================
-- One kneel, one payload: everything the suite knows about that exact spot,
-- assembled from getters that ALL already ship. Each clause carries its honest
-- GRAIN (spot/cell/field) and its own gate. THIS MEMBER WRITES NOTHING.
--
-- THE PAYLOAD SHAPE IS FROZEN AT THIS BUILD: the panel (Wizard's brief to
-- follow) renders it verbatim, so a clause added or renamed later is a re-open
-- here, never a quiet edit there.
--
-- The request shape is this module's one call: `HandfulRead.assemble(ctx)`
-- where ctx carries { fieldId, x, z, farmId, currentDay, materialFillType }.
-- The material verdict needs the fill type because the ground-material layers
-- are MATERIAL-BLIND on purpose (hay and straw share one layer); the kneel or
-- its caller knows what the player is standing over, and the verdict is honest
-- refusal when no fill type is supplied.
--
-- The disease gate's CELL grain (diseaseKnown per knelt cell) arrives via the
-- walked mask (SF-26), which the kneel writes to. Until a mask cell exists,
-- diseaseKnown degrades to the field's own diseaseDiscovered flag (field
-- grain), and the label says which.
-- =========================================================
-- Author: TisonK
-- =========================================================

HandfulRead = HandfulRead or {}

-- The frozen clause list. The panel renders these; a new clause needs a new
-- source verification and a contract re-open (rule 1: no phantom fields).
HandfulRead.CLAUSES = {
    "N", "P", "K", "pH", "OM",
    "compaction",
    "diseasePressure",
    "pestPressure", "weedPressure",
    "moisture",
    "lastCrop", "lastCrop2", "lastCrop3",
    "rotationStatus", "rotationBonusDaysLeft", "daysSinceHarvest",
    "organicState",
    "materialWetness", "materialDaysDown", "materialVerdict",
    "diseaseKnown",
    "testKitActive",
}

-- =========================================================
-- Helpers (the house read contract: pcall + handle + neutral-absent)
-- =========================================================

local function farmIdOf(ctx)
    -- [SF-22] Only an ordinary farm (1..8) may key knowledge. A spectator,
    -- guided-tour, invalid or unresolved farm returns nil - never farm 1 - so a
    -- non-farmer viewer composes nothing and the mask stays private.
    if SpatialScouting.isOrdinaryFarmId(ctx.farmId) then return ctx.farmId end
    if g_localPlayer and SpatialScouting.isOrdinaryFarmId(g_localPlayer.farmId) then
        return g_localPlayer.farmId
    end
    if g_currentMission and type(g_currentMission.getFarmId) == "function" then
        local ok, id = pcall(function() return g_currentMission:getFarmId() end)
        if ok and SpatialScouting.isOrdinaryFarmId(id) then return id end
    end
    return nil
end

local function currentDay()
    return g_currentMission and g_currentMission.environment
        and g_currentMission.environment.currentDay or 0
end

--- Safe cross-mod moisture read (SCS facade, read-only across the firewall).
--- Neutral (nil) when SCS is absent or the read fails. The handle is the
--- mission bridge, mirroring SoilFertilitySystem's own SCS-001 reader.
---@return number|nil
local function readMoisture(fieldId)
    local csMgr = g_currentMission and g_currentMission.cropStressManager
    if csMgr == nil or type(csMgr.getMoisture) ~= "function" then return nil end
    local ok, m = pcall(csMgr.getMoisture, csMgr, fieldId)
    if ok and type(m) == "number" then return m end
    return nil
end

--- Point read of the material wetness layer at (x, z). Builds a one-cell square
--- around the spot (the same ZONE grid the walked mask and the rest of the
--- suite use; no second grid). The sentinel band reads as the honest refusal,
--- and refusal propagates: it is never averaged away.
---@return table result  { status, pct, band } or { status } on refusal/unavailable
local function readWetnessAt(ctx, soilSystem)
    local mw = soilSystem and soilSystem.materialWetness
    if mw == nil or type(mw.readCondition) ~= "function" then
        return { status = "unavailable" }
    end
    local cs = SoilConstants.ZONE.CELL_SIZE
    local half = cs * 0.5
    local x, z = ctx.x, ctx.z
    local verts = {
        { x = x - half, z = z - half },
        { x = x + half, z = z - half },
        { x = x + half, z = z + half },
        { x = x - half, z = z + half },
    }
    -- Litres is NON OPTIONAL on readCondition; a handful is a handful. The
    -- value only gates nil/zero refusal; it does not bias the mass-weighted
    -- mean, so 1.0 stands in for "some material under the hand".
    return mw:readCondition(verts, 1.0)
end

--- Point read of the material age layer (days down) at (x, z).
---@return table result  { status, days, band }
local function readDaysDownAt(ctx, soilSystem)
    local md = soilSystem and soilSystem.materialDown
    if md == nil or type(md.getDaysDownAt) ~= "function" then
        return { status = "unavailable" }
    end
    return md:getDaysDownAt(ctx.x, ctx.z)
end

--- THE MATERIAL VERDICT. The layers are material-blind, so the verdict's spoil
--- rain-days depend on the fill type the CALLER supplies. Honest refusal when
--- no fill type is given: the suite cannot answer "going off" for a material it
--- cannot name, and it must not guess one.
---@return table result  { status, spoiled, waterDays, needed, known, window }
local function readVerdict(ctx, soilSystem)
    local mw = soilSystem and soilSystem.materialWetness
    if mw == nil or type(mw.goingOffVerdict) ~= "function" then
        return { status = "unavailable" }
    end
    if not ctx.materialFillType then
        return { status = "refusal", reason = "no material fill type supplied" }
    end
    local daysDown = ctx._daysDown and ctx._daysDown.days
    if daysDown == nil then daysDown = MaterialWetness.WATER_RECORD_DAYS or 6 end
    return mw:goingOffVerdict(ctx.materialFillType, daysDown, ctx.currentDay or currentDay())
end

--- diseaseKnown: cell-grain via the walked mask when a fresh cell exists, else
--- the field's own diseaseDiscovered flag (field grain). The label (below)
--- says which. This is the ONLY clause with a cell/field grain split, and it is
--- the knowledge gate's own flag - never a bypass.
---@return boolean
local function readDiseaseKnown(ctx, soilSystem, field)
    local scouting = soilSystem and soilSystem.spatialScouting
    if scouting and scouting:isArmed() and scouting.isFresh then
        local farmId = farmIdOf(ctx)
        if farmId and ctx.x and ctx.z then
            local key = SpatialScouting.cellKey(ctx.x, ctx.z)
            if scouting:isFresh(farmId, ctx.fieldId, key, ctx.currentDay or currentDay()) then
                return true, "cell"
            end
        end
    end
    if field and field.diseaseDiscovered then return true, "field" end
    return false, "field"
end

---@return boolean
local function readTestKit(ctx)
    local mgr = g_currentMission and g_currentMission.proStaffManager
    if mgr and type(mgr.hasSoilTestKit) == "function" then
        local fid = farmIdOf(ctx)
        if fid then
            local ok, val = pcall(mgr.hasSoilTestKit, mgr, fid)
            if ok then return val == true end
        end
    end
    return false
end

-- =========================================================
-- The assembly
-- =========================================================

--- THE ONE CALL. Assemble the frozen payload for a spot.
---@param ctx table  { fieldId, x, z, farmId?, currentDay?, materialFillType? }
---@return table payload
function HandfulRead.assemble(ctx)
    if ctx == nil or not ctx.fieldId or not ctx.x or not ctx.z then
        return nil
    end
    ctx.currentDay = ctx.currentDay or currentDay()

    local soilSystem = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
    local info = soilSystem and soilSystem.getFieldInfo
        and soilSystem:getFieldInfo(ctx.fieldId, ctx.x, ctx.z) or nil
    local field = soilSystem and soilSystem.fieldData and soilSystem.fieldData[ctx.fieldId]

    -- Material clause read once, so wetness, days-down and the verdict agree on
    -- the same spot read.
    local days = readDaysDownAt(ctx, soilSystem)
    ctx._daysDown = days
    local wet = readWetnessAt(ctx, soilSystem)
    local verdict = readVerdict(ctx, soilSystem)
    local diseaseKnown, diseaseGrain = readDiseaseKnown(ctx, soilSystem, field)

    local organic = nil
    if OrganicCertification and type(OrganicCertification.getFieldOrganicState) == "function" then
        local ok, o = pcall(function()
            return OrganicCertification:getFieldOrganicState(ctx.fieldId)
        end)
        if ok and o ~= nil then organic = o end
    end

    local compaction = nil
    if soilSystem and soilSystem.valueMaps and soilSystem.valueMaps.readValueAtWorld then
        local ok, v = pcall(function()
            return soilSystem.valueMaps:readValueAtWorld("compaction", ctx.x, ctx.z)
        end)
        if ok and v ~= nil then compaction = v end
    end

    local farmId = farmIdOf(ctx)

    return {
        -- spot grain, qualitative always (exact numbers behind the test kit)
        N = info and info.nitrogen or nil,
        P = info and info.phosphorus or nil,
        K = info and info.potassium or nil,
        pH = info and info.pH or nil,
        OM = info and info.organicMatter or nil,
        fromZoneCell = info and info.fromZoneCell or false,
        -- spot grain, qualitative always
        compaction = compaction,
        -- disease: field now, cell when the walked mask holds a fresh cell; the
        -- label says which
        diseasePressure = (info and info.shownDiseasePressure) or nil,
        diseaseDiscovered = field and field.diseaseDiscovered or false,
        diseaseGrain = diseaseGrain,
        -- field grain, UNGATED (no gated form exists at source)
        pestPressure = info and info.pestPressure or nil,
        weedPressure = info and info.weedPressure or nil,
        -- field grain, neutral if SCS absent
        moisture = readMoisture(ctx.fieldId),
        -- field grain, none
        lastCrop = info and info.lastCrop or nil,
        lastCrop2 = info and info.lastCrop2 or nil,
        lastCrop3 = info and info.lastCrop3 or nil,
        rotationStatus = info and info.rotationStatus or nil,
        rotationBonusDaysLeft = info and info.rotationBonusDaysLeft or 0,
        daysSinceHarvest = info and info.daysSinceHarvest or 0,
        -- field grain, none
        organicState = organic,
        -- spot grain, qualitative always, NEUTRAL when nothing lies there
        materialWetness = wet.status == "ok" and { pct = wet.pct, band = wet.band } or { status = wet.status },
        materialDaysDown = days.status == "ok" and { days = days.days, band = days.band } or { status = days.status },
        materialVerdict = verdict,
        -- the knowledge gate's own flag
        diseaseKnown = diseaseKnown,
        -- farm grain, none, neutral-false until the test-kit member ships
        testKitActive = readTestKit(ctx),
        -- provenance for the panel
        farmId = farmId,
        fieldId = ctx.fieldId,
        x = ctx.x,
        z = ctx.z,
        currentDay = ctx.currentDay,
        -- the frozen clause list rides the payload so the panel can iterate it
        clauses = HandfulRead.CLAUSES,
    }
end
