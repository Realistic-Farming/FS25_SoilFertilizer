-- SFNozzleEffects — per-nozzle See & Spray specialization for SF mod sprayers.
-- Clones sprayerNozzleEffect.i3d once per nozzle, animates with shader parameters,
-- and individually suppresses nozzles when no enabled See & Spray sensor exceeds
-- its threshold 1m ahead. Mirrors PF's ExtendedSprayerEffects pattern.
-- No PF dependency — ever.

SFNozzleEffects = {}
SFNozzleEffects.SPEC_TABLE_NAME = "spec_FS25_SoilFertilizer.sfNozzleEffects"

-- Fade direction vectors (mirrors PF ESE constants)
SFNozzleEffects.FADE_DIR_OFF   = {0,  0}
SFNozzleEffects.FADE_DIR_START = {0,  1}
SFNozzleEffects.FADE_DIR_STOP  = {0, -1}

local STATE_OFF         = 0
local STATE_ON          = 1
local STATE_TURNING_ON  = 2
local STATE_TURNING_OFF = 3

local CELL_SIZE = 10   -- matches SoilConstants.ZONE.CELL_SIZE
local FADE_TIME = 250  -- ms, matches PF effectFadeTime

-- Class-level shared state — one i3d template serves all vehicle instances.
SFNozzleEffects._templateNode = nil
SFNozzleEffects._i3dReady     = false

-- Called from main.lua after module load, before any vehicles instantiate.
function SFNozzleEffects.init(modDir)

    local path = modDir .. "shared/sprayerNozzleEffect.i3d"
    g_i3DManager:loadI3DFileAsync(path, true, true, SFNozzleEffects._onI3DLoaded, nil, {})
end

function SFNozzleEffects._onI3DLoaded(_, i3dNode, failedReason, args)
    if i3dNode ~= nil and i3dNode ~= 0 then
        SFNozzleEffects._templateNode = getChildAt(i3dNode, 0)
        unlink(SFNozzleEffects._templateNode)
        delete(i3dNode)
        SFNozzleEffects._i3dReady = true
        SoilLogger.info("[SFNozzleEffects] Effect i3d loaded — shader plane template ready")
    else
        SoilLogger.warning("[SFNozzleEffects] sprayerNozzleEffect.i3d failed to load (reason=%s) — shader effects disabled, fluid scaling still active", tostring(failedReason))
    end
end

-- ── Helper: clone effect nodes onto all nozzles (called once template is ready) ─

local function sfSetupEffectNodes(vehicle)
    local spec = vehicle[SFNozzleEffects.SPEC_TABLE_NAME]
    if not spec or not SFNozzleEffects._templateNode then return end

    local material = g_materialManager and g_materialManager:getMaterial(FillType.LIQUIDFERTILIZER, "sprayer", 1)

    for _, effectData in ipairs(spec.sprayerEffects) do
        local ok, effectNode = pcall(clone, SFNozzleEffects._templateNode, false, false, false)
        if ok and effectNode and effectNode ~= 0 then
            if material then setMaterial(effectNode, material, 0) end

            -- Initialise shader params — nozzle starts fully OFF
            effectData.fadeCur = {1, -1}
            setShaderParameter(effectNode, "fadeProgress", effectData.fadeCur[1], effectData.fadeCur[2], 0, 0, false)
            setShaderParameter(effectNode, "offsetUV",     math.random(), math.random(), 0, 0, false)
            setShaderParameter(effectNode, "isPulsating",  0, nil, nil, nil, false)
            setShaderParameter(effectNode, "blinkMulti",   1, 1, 100, math.random() * 100, false)

            -- Attach to nozzle anchor (probeNode is the physical nozzle transform node)
            link(effectData.probeNode, effectNode)

            effectData.effectNode = effectNode
            effectData.state      = STATE_OFF
            effectData.fadeDir    = SFNozzleEffects.FADE_DIR_OFF
        end
    end

    SoilLogger.info("[SFNozzleEffects] %d effect nodes linked on %s",
        spec.numCustomEffects, tostring(vehicle.configFileName))
end

-- ── Specialization registration ───────────────────────────────────────────────

function SFNozzleEffects.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("SFNozzleEffects")

    schema:register(XMLValueType.INT,          "vehicle.sprayer.nozzles(?)#foldingConfigurationIndex", "Folding config index for this nozzle group", 1)
    schema:register(XMLValueType.NODE_INDEX,   "vehicle.sprayer.nozzles(?).nozzle(?)#node",            "Nozzle anchor node")
    schema:register(XMLValueType.VECTOR_TRANS, "vehicle.sprayer.nozzles(?).nozzle(?)#translation",     "Translation offset from anchor node")
    schema:register(XMLValueType.VECTOR_ROT,   "vehicle.sprayer.nozzles(?).nozzle(?)#rotation",        "Rotation offset from anchor node")

    schema:setXMLSpecializationType()

    -- Register See & Spray as Yes/No shop configurations (one per target type).
    -- Mirrors PF WeedSpotSpray.initSpecialization() pattern exactly.
    if g_vehicleConfigurationManager then
        g_vehicleConfigurationManager:addConfigurationType(
            "sfSeeSprayWeed",
            g_i18n:getText("sf_config_seeSprayWeed"),
            "sfSeeSprayWeed",
            VehicleConfigurationItem
        )
        g_vehicleConfigurationManager:addConfigurationType(
            "sfSeeSprayPest",
            g_i18n:getText("sf_config_seeSprayPest"),
            "sfSeeSprayPest",
            VehicleConfigurationItem
        )
        g_vehicleConfigurationManager:addConfigurationType(
            "sfSeeSprayDisease",
            g_i18n:getText("sf_config_seeSprayDisease"),
            "sfSeeSprayDisease",
            VehicleConfigurationItem
        )
    end
end

function SFNozzleEffects.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Sprayer, specializations)
end

function SFNozzleEffects.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "getNumExtendedSprayerNozzleEffectsActive",  SFNozzleEffects.getNumExtendedSprayerNozzleEffectsActive)
    SpecializationUtil.registerFunction(vehicleType, "updateExtendedSprayerNozzleEffectsState",   SFNozzleEffects.updateExtendedSprayerNozzleEffectsState)
    SpecializationUtil.registerFunction(vehicleType, "updateExtendedSprayerNozzleEffectState",    SFNozzleEffects.updateExtendedSprayerNozzleEffectState)
end

function SFNozzleEffects.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getSprayerUsage",      SFNozzleEffects.getSprayerUsage)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getAreEffectsVisible", SFNozzleEffects.getAreEffectsVisible)
end

function SFNozzleEffects.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad",  SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",     SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",   SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete",   SFNozzleEffects)
end

-- ── onPreLoad — read vehicle purchase configurations ─────────────────────────

function SFNozzleEffects:onPreLoad(savegame)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]
    -- configurations["sfSeeSprayWeed"] = 1 → No, 2 → Yes  (FS25 Yes/No convention)
    spec.seeSprayWeed    = (self.configurations["sfSeeSprayWeed"]    or 1) > 1
    spec.seeSprayPest    = (self.configurations["sfSeeSprayPest"]    or 1) > 1
    spec.seeSprayDisease = (self.configurations["sfSeeSprayDisease"] or 1) > 1
    SoilLogger.debug("[SFNozzleEffects] onPreLoad: seeSprayWeed=%s seeSprayPest=%s seeSprayDisease=%s",
        tostring(spec.seeSprayWeed), tostring(spec.seeSprayPest), tostring(spec.seeSprayDisease))
end

-- ── onLoad — read nozzle nodes from XML ──────────────────────────────────────

function SFNozzleEffects:onLoad(savegame)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]

    spec.sprayerEffects          = {}
    spec.sprayerEffectsBySection = {}
    spec.hasCustomEffects        = false
    spec.numCustomEffects        = 0
    spec.pwmEnabled              = false
    spec.effectFadeTime          = FADE_TIME
    spec.effectsDirty            = false
    spec._effectsPending         = false

    spec._sfFieldId    = nil
    spec._sfFieldTimer = 0

    spec._groundTypeMapId   = nil
    spec._groundTypeFirstCh = 0
    spec._groundTypeNumCh   = 0

    spec.pendingNozzles = {}
    SoilLogger.debug("[SFNozzleEffects] onLoad: %s", tostring(self.configFileName))

    local groupCount = 0
    self.xmlFile:iterate("vehicle.sprayer.nozzles", function(_, nozzlesKey)
        groupCount = groupCount + 1
        local foldingIdx    = self.xmlFile:getValue(nozzlesKey .. "#foldingConfigurationIndex", 1)
        local activeFolding = self.configurations["folding"]
        local isActive = (foldingIdx == activeFolding) or (activeFolding == nil and foldingIdx == 1)
        SoilLogger.debug("[SFNozzleEffects]   nozzle group %d: foldingIdx=%s activeFolding=%s isActive=%s",
            groupCount, tostring(foldingIdx), tostring(activeFolding), tostring(isActive))
        if isActive then
            self.xmlFile:iterate(nozzlesKey .. ".nozzle", function(_, key)
                local node = self.xmlFile:getValue(key .. "#node", nil, self.components, self.i3dMappings)
                if node ~= nil then
                    spec.pendingNozzles[#spec.pendingNozzles + 1] = node
                end
            end)
        end
    end)
    SoilLogger.debug("[SFNozzleEffects] onLoad done: %d groups, %d nozzles pending",
        groupCount, #spec.pendingNozzles)
end

-- ── onPostLoad — section mapping then effect node setup ───────────────────────

function SFNozzleEffects:onPostLoad(savegame)
    local spec     = self[SFNozzleEffects.SPEC_TABLE_NAME]
    local spec_vww = self.spec_variableWorkWidth

    if spec_vww == nil or spec_vww.sections == nil or #spec_vww.sections == 0 then
        spec.pendingNozzles = nil
        return
    end

    local minWidth = 1
    if spec_vww.sectionNodes and #spec_vww.sectionNodes > 0 then
        local sn     = spec_vww.sectionNodes[1]
        local startX = sn.startTransX or (sn.startTrans and sn.startTrans[1]) or 1
        minWidth     = math.abs(startX)
    end

    for _, nozzleNode in ipairs(spec.pendingNozzles) do
        local ok, xOffset = pcall(function()
            local x, _, _ = localToLocal(nozzleNode, self:getParentComponent(nozzleNode), 0, 0, 0)
            return x
        end)
        if not ok then xOffset = 0 end

        local sectionIndex = 0
        if xOffset > minWidth and spec_vww.sectionsLeft then
            for _, section in ipairs(spec_vww.sectionsLeft) do
                if xOffset <= section.widthAbs then
                    sectionIndex = section.index
                    break
                end
            end
        elseif xOffset < -minWidth and spec_vww.sectionsRight then
            for _, section in ipairs(spec_vww.sectionsRight) do
                if xOffset >= section.widthAbs then
                    sectionIndex = section.index
                    break
                end
            end
        end

        local effectData = {
            effectNode   = nil,               -- populated by sfSetupEffectNodes once i3d ready
            probeNode    = nozzleNode,         -- physical anchor — used for localToWorld probing
            fadeCur      = {1, -1},            -- shader fade progress: {1,-1} = fully off
            fadeDir      = SFNozzleEffects.FADE_DIR_OFF,
            state        = STATE_OFF,
            sectionIndex = sectionIndex,
            isActive     = false,
        }

        spec.sprayerEffects[#spec.sprayerEffects + 1] = effectData

        if spec.sprayerEffectsBySection[sectionIndex] == nil then
            spec.sprayerEffectsBySection[sectionIndex] = {}
        end
        spec.sprayerEffectsBySection[sectionIndex][#spec.sprayerEffectsBySection[sectionIndex] + 1] = effectData
    end

    spec.pendingNozzles   = nil

    -- Cache ground-type density map channels for the field boundary check.
    -- Must extract only the GROUND_TYPE channel; reading the full terrainDetailId
    -- packs in angle/spray bits that can be non-zero even on headland grass.
    if g_currentMission and g_currentMission.fieldGroundSystem then
        local mapId, firstCh, numCh = g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
        spec._groundTypeMapId   = mapId
        spec._groundTypeFirstCh = firstCh
        spec._groundTypeNumCh   = numCh
    end

    spec.numCustomEffects = #spec.sprayerEffects
    spec.hasCustomEffects = spec.numCustomEffects > 0

    if spec.hasCustomEffects then
        if SFNozzleEffects._i3dReady then
            sfSetupEffectNodes(self)
        else
            spec._effectsPending = true   -- retry in onUpdate once i3d has landed
        end
    end
end

-- ── onDelete — release all cloned effect nodes ────────────────────────────────

function SFNozzleEffects:onDelete()
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]
    if not spec then return end
    for _, effectData in ipairs(spec.sprayerEffects or {}) do
        if effectData.effectNode then
            delete(effectData.effectNode)
            effectData.effectNode = nil
        end
    end
end

-- ── onUpdate — field ID cache, nozzle state, shader fade animation ────────────

function SFNozzleEffects:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]
    if not spec.hasCustomEffects then
        -- Non-custom-nozzle vehicles (e.g. Condor) still need the field ID cache when
        -- See & Spray is purchased so that getSprayerUsage can gate consumption
        -- when there is no target pressure.
        local hasAny = spec.seeSprayWeed or spec.seeSprayPest or spec.seeSprayDisease
        if hasAny then
            spec._sfFieldTimer = spec._sfFieldTimer + dt
            if spec._sfFieldTimer >= 1000 then
                spec._sfFieldTimer = 0
                local sfm = g_SoilFertilityManager
                if sfm and sfm.soilSystem then
                    local pok, rx, _, rz = pcall(getWorldTranslation, self.rootNode)
                    if pok and rx then
                        local fieldId = nil
                        local fok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(rx, rz) end)
                        if fok and f and f.farmland then
                            fieldId = f.farmland.id
                        elseif g_farmlandManager then
                            local lok, fl = pcall(function() return g_farmlandManager:getFarmlandAtWorldPosition(rx, rz) end)
                            if lok and fl and fl.id and fl.id > 0 then fieldId = fl.id end
                        end
                        spec._sfFieldId = fieldId
                    end
                end
            end
        end
        return
    end

    -- Deferred effect node setup: i3d may not have been ready at onPostLoad time.
    if spec._effectsPending then
        if SFNozzleEffects._i3dReady then
            sfSetupEffectNodes(self)
            spec._effectsPending = false
        else
            return  -- still waiting; fluid scaling still inactive but no crash
        end
    end

    -- Refresh field ID cache once per second from vehicle root position.
    spec._sfFieldTimer = spec._sfFieldTimer + dt
    if spec._sfFieldTimer >= 1000 then
        spec._sfFieldTimer = 0
        local sfm = g_SoilFertilityManager
        if sfm and sfm.soilSystem then
            local pok, rx, _, rz = pcall(getWorldTranslation, self.rootNode)
            if pok and rx then
                local fieldId = nil
                local fok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(rx, rz) end)
                if fok and f and f.farmland then
                    fieldId = f.farmland.id
                elseif g_farmlandManager then
                    local lok, fl = pcall(function() return g_farmlandManager:getFarmlandAtWorldPosition(rx, rz) end)
                    if lok and fl and fl.id and fl.id > 0 then fieldId = fl.id end
                end
                spec._sfFieldId = fieldId
            end
        end
    end

    -- Update per-nozzle active state (also triggers fade direction transitions).
    local isTurnedOn = self:getIsTurnedOn()
    local lastSpeed  = tonumber(self.getLastSpeed and self:getLastSpeed()) or 0
    self:updateExtendedSprayerNozzleEffectsState(spec.sprayerEffects, dt, isTurnedOn, lastSpeed)

    -- Animate shader fade transitions for any nozzle with an effect node.
    for _, effectData in ipairs(spec.sprayerEffects) do
        local effectNode = effectData.effectNode
        if effectNode then
            local state = effectData.state
            if state == STATE_TURNING_ON or state == STATE_TURNING_OFF then
                local fadeCur = effectData.fadeCur
                local fadeDir = effectData.fadeDir
                fadeCur[1] = math.max(-1, math.min(1, fadeCur[1] + fadeDir[1] * (dt / FADE_TIME)))
                fadeCur[2] = math.max(-1, math.min(1, fadeCur[2] + fadeDir[2] * (dt / FADE_TIME)))
                setShaderParameter(effectNode, "fadeProgress", fadeCur[1], fadeCur[2], 0, 0, false)

                if state == STATE_TURNING_OFF and fadeCur[2] <= -1 then
                    effectData.state   = STATE_OFF
                    effectData.fadeDir = SFNozzleEffects.FADE_DIR_OFF
                elseif state == STATE_TURNING_ON and fadeCur[2] >= 1 then
                    effectData.state   = STATE_ON
                    effectData.fadeDir = SFNozzleEffects.FADE_DIR_OFF
                end
            end
        end
    end
end

-- ── Nozzle state functions ────────────────────────────────────────────────────

-- Batch update: sets isActive on each effectData and fires fade transitions.
function SFNozzleEffects:updateExtendedSprayerNozzleEffectsState(sprayerEffects, dt, isTurnedOn, lastSpeed)
    for _, effectData in ipairs(sprayerEffects) do
        local isActive, _ = self:updateExtendedSprayerNozzleEffectState(effectData, dt, isTurnedOn, lastSpeed)

        if isActive ~= effectData.isActive then
            effectData.isActive = isActive

            if effectData.effectNode then
                if isActive then
                    if effectData.state == STATE_OFF or effectData.state == STATE_TURNING_OFF then
                        effectData.state   = STATE_TURNING_ON
                        effectData.fadeDir = SFNozzleEffects.FADE_DIR_START
                    end
                else
                    if effectData.state == STATE_ON or effectData.state == STATE_TURNING_ON then
                        effectData.state   = STATE_TURNING_OFF
                        effectData.fadeDir = SFNozzleEffects.FADE_DIR_STOP
                    end
                end
            end
        end
    end
end

-- Per-nozzle decision: returns (isActive, amountScale).
-- Checks in order: sprayer state → section active → field boundary → See & Spray threshold.
function SFNozzleEffects:updateExtendedSprayerNozzleEffectState(effectData, dt, isTurnedOn, lastSpeed)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]

    if not isTurnedOn                                      then return false, 1 end
    if (lastSpeed or 0) < 0.25                             then return false, 1 end
    if self.movingDirection and self.movingDirection < 0   then return false, 1 end

    local spec_vww = self.spec_variableWorkWidth
    if spec_vww and spec_vww.sections and effectData.sectionIndex ~= 0 then
        local section = spec_vww.sections[effectData.sectionIndex]
        if section and not section.isActive then return false, 1 end
    end

    -- Passes 1-3 and See & Spray threshold checks only apply when at least one See & Spray
    -- feature is purchased.  Without it every active VWW section sprays normally, matching
    -- vanilla behaviour (all nozzles on regardless of field-boundary or nutrient state).
    local hasAny = spec.seeSprayWeed or spec.seeSprayPest or spec.seeSprayDisease
    if not hasAny then return isTurnedOn, 1 end

    -- Resolve fill type once — shared by Pass 3 nutrient check and See & Spray below.
    local sprayerSpec = self.spec_sprayer
    local wap = sprayerSpec and sprayerSpec.workAreaParameters
    local fillTypeIndex = wap and wap.sprayFillType
    local ft
    if fillTypeIndex and fillTypeIndex ~= 0 then
        ft = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    end

    if not ft then return isTurnedOn, 1 end

    -- Classify the fill type before probing so field-boundary passes can be selectively
    -- applied.  Passes 1+2 only gate See & Spray chemicals (herbicide / insecticide /
    -- fungicide).  Fertilisers must NOT be gated — outer boom sections that cross the
    -- headland edge while the vehicle is inside the field should still spray.
    local ssCfg     = SoilConstants.SEE_AND_SPRAY
    local isPest    = spec.seeSprayPest    and SoilConstants.PEST_PRESSURE.INSECTICIDE_TYPES[ft.name]
    local isDisease = spec.seeSprayDisease and SoilConstants.DISEASE_PRESSURE.FUNGICIDE_TYPES[ft.name]
    local isWeed    = spec.seeSprayWeed    and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES[ft.name]

    -- Probe nozzle world position once — reused for all passes below.
    local probeX, probeZ
    if effectData.probeNode then
        local ok, nx, _, nz = pcall(getWorldTranslation, effectData.probeNode)
        if ok and nx then probeX, probeZ = nx, nz end
    end

    -- Farmland ID resolved from the nozzle probe position (filled by Pass 2).
    -- Used for the threshold check so the tractor body being on the headland or a road
    -- does not suppress nozzles that are still over the crop (spec._sfFieldId is cached
    -- from the vehicle root and can be nil during headland turns).
    local nozzleFarmId = nil

    if probeX then
        -- Passes 1+2: field-boundary checks — See & Spray chemicals only.
        -- Fertiliser outer boom sections crossing the headland must not be gated here.
        if isPest or isDisease or isWeed then
            -- Pass 1: GROUND_TYPE channel — off-field (grass / road) → suppress.
            if spec._groundTypeMapId then
                local rawBits = getDensityAtWorldPos(spec._groundTypeMapId, probeX, 0, probeZ)
                local groundTypeValue = bit32.band(
                    bit32.rshift(rawBits, spec._groundTypeFirstCh),
                    2 ^ spec._groundTypeNumCh - 1)
                if groundTypeValue == 0 then return false, 1 end
            end

            -- Pass 2: farmland ID — crossing onto an adjacent parcel → suppress.
            -- Save the validated farmland ID so the threshold check can use the nozzle
            -- probe position instead of the vehicle-root cache (spec._sfFieldId).
            if g_farmlandManager then
                local nFarmId = g_farmlandManager:getFarmlandIdAtWorldPosition(probeX, probeZ)
                local vFarmId = spec._sfFieldId
                if nFarmId == 0 or (vFarmId and vFarmId > 0 and nFarmId ~= vFarmId) then
                    return false, 1
                end
                if nFarmId > 0 then nozzleFarmId = nFarmId end
            end
        end

        -- Pass 3: nutrient adequacy — suppress visual when this cell already has enough
        -- of every nutrient the current fill type contributes.  Fertilisers only (never
        -- triggers for herbicide / insecticide / fungicide which have no FERTILIZER_PROFILE).
        local sfm3 = g_SoilFertilityManager
        local prof  = SoilConstants.FERTILIZER_PROFILES and SoilConstants.FERTILIZER_PROFILES[ft.name]
        if sfm3 and sfm3.soilSystem and prof then
            local fieldId3 = nozzleFarmId or spec._sfFieldId
            local fd3 = fieldId3 and sfm3.soilSystem.fieldData[fieldId3]
            if fd3 then
                local cellKey = tostring(math.floor(probeX / CELL_SIZE) * 10000 + math.floor(probeZ / CELL_SIZE))
                local cell    = fd3.zoneData and fd3.zoneData[cellKey]
                local cellN  = (cell and cell.N)  or fd3.nitrogen      or 0
                local cellP  = (cell and cell.P)  or fd3.phosphorus    or 0
                local cellK  = (cell and cell.K)  or fd3.potassium     or 0
                local cellPH = (cell and cell.pH) or fd3.pH            or SoilConstants.NUTRIENT_LIMITS.PH_OPTIMAL
                local cellOM = (cell and cell.OM) or fd3.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter
                local tgt     = SoilConstants.SPRAYER_RATE.AUTO_RATE_TARGETS
                local adequate, anyCriteria = true, false
                if (prof.N  or 0) > 0 then adequate = adequate and (cellN  >= tgt.N );  anyCriteria = true end
                if (prof.P  or 0) > 0 then adequate = adequate and (cellP  >= tgt.P );  anyCriteria = true end
                if (prof.K  or 0) > 0 then adequate = adequate and (cellK  >= tgt.K );  anyCriteria = true end
                if (prof.pH or 0) > 0 then adequate = adequate and (cellPH >= tgt.pH);  anyCriteria = true end
                local omProd = SoilConstants.SPRAYER_RATE.OM_PRIMARY_PRODUCTS
                if omProd and omProd[ft.name] then adequate = adequate and (cellOM >= tgt.OM); anyCriteria = true end
                if anyCriteria and adequate then return false, 1 end
            end
        end
    end

    -- Not a targeted See & Spray chemical — spray normally (fertilisers reach here).
    if not isPest and not isDisease and not isWeed then return isTurnedOn, 1 end

    -- See & Spray threshold checks (per-cell using probeNode 1m ahead).
    -- Fail-closed: suppress the nozzle until a target is positively confirmed.
    local sfm = g_SoilFertilityManager
    if not sfm then return false, 1 end

    -- Prefer the farmland ID resolved from the nozzle probe position (Pass 2).
    -- Fall back to the vehicle-root cache only when the probe position was unavailable.
    local fieldId = nozzleFarmId or spec._sfFieldId
    if not fieldId then return false, 1 end

    local fd = sfm.soilSystem and sfm.soilSystem.fieldData[fieldId]
    if not fd then return false, 1 end

    if not effectData.probeNode then return false, 1 end
    local pok, px, _, pz = pcall(localToWorld, effectData.probeNode, 0, 0, 1)
    if not pok then return false, 1 end

    local cellKey = tostring(math.floor(px / CELL_SIZE) * 10000 + math.floor(pz / CELL_SIZE))
    local cell    = fd.zoneData and fd.zoneData[cellKey]

    local pestVal    = (cell and cell.pestPressure)    or (fd.pestPressure    or 0)
    local diseaseVal = (cell and cell.diseasePressure) or (fd.diseasePressure or 0)
    local weedVal    = (cell and cell.weedPressure)    or (fd.weedPressure    or 0)

    if isPest    and pestVal    >= ssCfg.PEST_THRESHOLD    then return true, 1 end
    if isDisease and diseaseVal >= ssCfg.DISEASE_THRESHOLD then return true, 1 end
    if isWeed    and weedVal    >= ssCfg.WEED_THRESHOLD
        and not (fd.herbicideDaysLeft and fd.herbicideDaysLeft > 0) then return true, 1 end

    return false, 1
end

-- ── Overwritten functions ─────────────────────────────────────────────────────

-- Field-level See & Spray check for non-custom-nozzle vehicles (hasCustomEffects=false).
-- Returns true → spray normally; false → suppress (no target pressure in this field).
-- Fail-closed for See & Spray chemicals: suppress until a target is positively confirmed.
-- Non-See&Spray fill types (fertilisers) are classified first and always return true.
local function sfCheckFieldSeeSpraysTarget(spec, ft)
    if not ft then return true end
    local ssCfg     = SoilConstants.SEE_AND_SPRAY
    local isPest    = spec.seeSprayPest    and SoilConstants.PEST_PRESSURE.INSECTICIDE_TYPES[ft.name]
    local isDisease = spec.seeSprayDisease and SoilConstants.DISEASE_PRESSURE.FUNGICIDE_TYPES[ft.name]
    local isWeed    = spec.seeSprayWeed    and SoilConstants.WEED_PRESSURE.HERBICIDE_TYPES[ft.name]
    -- Not a See & Spray chemical (e.g. fertiliser) → always spray regardless of field state.
    if not isPest and not isDisease and not isWeed then return true end
    -- It IS a See & Spray chemical — require a positive confirmation before allowing fluid.
    local sfm = g_SoilFertilityManager
    if not sfm then return false end
    local fieldId = spec._sfFieldId
    if not fieldId then return false end
    local fd = sfm.soilSystem and sfm.soilSystem.fieldData[fieldId]
    if not fd then return false end
    if isPest    and (fd.pestPressure    or 0) >= ssCfg.PEST_THRESHOLD    then return true end
    if isDisease and (fd.diseasePressure or 0) >= ssCfg.DISEASE_THRESHOLD then return true end
    if isWeed    and (fd.weedPressure    or 0) >= ssCfg.WEED_THRESHOLD
        and not (fd.herbicideDaysLeft and fd.herbicideDaysLeft > 0)       then return true end
    return false
end

-- Suppress vanilla spray particle effects — our shader planes handle the visual.
-- Non-custom vehicles always delegate to vanilla; usage gating is in getSprayerUsage.
function SFNozzleEffects:getAreEffectsVisible(superFunc)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]
    if spec.hasCustomEffects then return false end
    return superFunc(self)
end

-- Returns (numActive, fraction) of nozzles currently active.
function SFNozzleEffects:getNumExtendedSprayerNozzleEffectsActive()
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]
    if not spec or not spec.hasCustomEffects or spec.numCustomEffects == 0 then
        return 1, 1
    end
    local numActive = 0
    for _, ed in ipairs(spec.sprayerEffects) do
        if ed.isActive then numActive = numActive + 1 end
    end
    return numActive, numActive / spec.numCustomEffects
end

-- Scale spray fluid consumption by the fraction of active nozzles.
-- Non-custom-nozzle vehicles with See & Spray purchased drop to zero when no target.
function SFNozzleEffects:getSprayerUsage(superFunc, fillType, dt)
    local usage = superFunc(self, fillType, dt)
    local spec  = self[SFNozzleEffects.SPEC_TABLE_NAME]
    local hasAny = spec.seeSprayWeed or spec.seeSprayPest or spec.seeSprayDisease
    if spec.hasCustomEffects and hasAny then
        local numActive, alpha = self:getNumExtendedSprayerNozzleEffectsActive()
        usage = usage * alpha
        if (self.getIsAIActive ~= nil and self:getIsAIActive()) and usage == 0 then
            usage = 0.0001
        end
    elseif not spec.hasCustomEffects and hasAny then
        local sprayerSpec = self.spec_sprayer
        local wap = sprayerSpec and sprayerSpec.workAreaParameters
        local fillTypeIndex = wap and wap.sprayFillType
        local ft = (fillTypeIndex and fillTypeIndex ~= 0)
            and g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if not sfCheckFieldSeeSpraysTarget(spec, ft) then
            usage = 0
            if (self.getIsAIActive ~= nil and self:getIsAIActive()) then usage = 0.0001 end
        end
    end
    return usage
end
