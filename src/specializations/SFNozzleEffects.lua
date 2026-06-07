-- SFNozzleEffects — per-nozzle See & Spray specialization for SF mod sprayers.
-- Each nozzle probes its soil zone cell 1m ahead and is individually suppressed
-- when no enabled See & Spray sensor exceeds its threshold.
-- No PF dependency — ever.

SFNozzleEffects = {}
SFNozzleEffects.SPEC_TABLE_NAME = "spec_extendedSprayerEffects"

local CELL_SIZE = 10  -- matches SoilConstants.ZONE.CELL_SIZE

function SFNozzleEffects.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("SFNozzleEffects")

    schema:register(XMLValueType.INT,         "vehicle.sprayer.nozzles(?)#foldingConfigurationIndex", "Folding config index for this nozzle group", 1)
    schema:register(XMLValueType.NODE_INDEX,  "vehicle.sprayer.nozzles(?).nozzle(?)#node",            "Nozzle anchor node")
    schema:register(XMLValueType.VECTOR_TRANS,"vehicle.sprayer.nozzles(?).nozzle(?)#translation",     "Translation offset from anchor node")
    schema:register(XMLValueType.VECTOR_ROT,  "vehicle.sprayer.nozzles(?).nozzle(?)#rotation",        "Rotation offset from anchor node")

    schema:setXMLSpecializationType()
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
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getSprayerUsage", SFNozzleEffects.getSprayerUsage)
end

function SFNozzleEffects.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",     SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate",   SFNozzleEffects)
end

function SFNozzleEffects:onLoad(savegame)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]

    spec.sprayerEffects          = {}
    spec.sprayerEffectsBySection = {}
    spec.hasCustomEffects        = false
    spec.numCustomEffects        = 0
    spec.pwmEnabled              = false
    spec.effectFadeTime          = 250
    spec.effectsDirty            = false

    -- Field ID cache — updated once per second to avoid per-frame field lookups.
    spec._sfFieldId    = nil
    spec._sfFieldTimer = 0

    -- Collect nozzle anchor nodes for the active folding configuration.
    -- Section mapping happens in onPostLoad once VWW is ready.
    spec.pendingNozzles = {}
    self.xmlFile:iterate("vehicle.sprayer.nozzles", function(_, nozzlesKey)
        local foldingIdx    = self.xmlFile:getValue(nozzlesKey .. "#foldingConfigurationIndex", 1)
        local activeFolding = self.configurations["folding"]
        if foldingIdx == activeFolding or (activeFolding == nil and foldingIdx == 1) then
            self.xmlFile:iterate(nozzlesKey .. ".nozzle", function(_, key)
                local node = self.xmlFile:getValue(key .. "#node", nil, self.components, self.i3dMappings)
                if node ~= nil then
                    spec.pendingNozzles[#spec.pendingNozzles + 1] = node
                end
            end)
        end
    end)
end

function SFNozzleEffects:onPostLoad(savegame)
    local spec     = self[SFNozzleEffects.SPEC_TABLE_NAME]
    local spec_vww = self.spec_variableWorkWidth

    if spec_vww == nil or spec_vww.sections == nil or #spec_vww.sections == 0 then
        spec.pendingNozzles = nil
        return
    end

    -- Dead-band half-width around center (mirrors ESE initExtendedSprayerNozzleEffect)
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

        -- Map nozzle X offset to VWW section index
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

        -- effectNode stays nil: we have no shader plane and HookManager's
        -- setShaderParameter guard (ed.effectNode ~= nil) must stay safe.
        -- probeNode is the real i3d node used for localToWorld() probing.
        local effectData = {
            effectNode   = nil,
            probeNode    = nozzleNode,
            fadeCur      = {1, -1},
            sectionIndex = sectionIndex,
            isActive     = false,
        }

        spec.sprayerEffects[#spec.sprayerEffects + 1] = effectData

        if spec.sprayerEffectsBySection[sectionIndex] == nil then
            spec.sprayerEffectsBySection[sectionIndex] = {}
        end
        local bucket = spec.sprayerEffectsBySection[sectionIndex]
        bucket[#bucket + 1] = effectData
    end

    spec.pendingNozzles   = nil
    spec.numCustomEffects = #spec.sprayerEffects
    spec.hasCustomEffects = spec.numCustomEffects > 0
end

-- ── Per-frame update ──────────────────────────────────────────────────────────

function SFNozzleEffects:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]
    if not spec.hasCustomEffects then return end

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

    local isTurnedOn = self:getIsTurnedOn()
    local lastSpeed  = (self.getLastSpeed and self:getLastSpeed()) or 0
    self:updateExtendedSprayerNozzleEffectsState(spec.sprayerEffects, dt, isTurnedOn, lastSpeed)
end

-- ── Nozzle state functions ────────────────────────────────────────────────────

-- Batch update — iterates all nozzles and sets isActive on each effectData.
function SFNozzleEffects:updateExtendedSprayerNozzleEffectsState(sprayerEffects, dt, isTurnedOn, lastSpeed)
    for _, effectData in ipairs(sprayerEffects) do
        local isActive, _ = self:updateExtendedSprayerNozzleEffectState(effectData, dt, isTurnedOn, lastSpeed)
        effectData.isActive = isActive
    end
end

-- Per-nozzle decision: returns (isActive, amountScale).
-- When See & Spray is disabled the nozzle follows section state (normal operation).
-- When See & Spray is enabled the nozzle probes its cell 1m ahead and is
-- suppressed if no enabled sensor exceeds its threshold at that position.
function SFNozzleEffects:updateExtendedSprayerNozzleEffectState(effectData, dt, isTurnedOn, lastSpeed)
    if not isTurnedOn                                                  then return false, 1 end
    if (lastSpeed or 0) < 0.25                                         then return false, 1 end
    if self.movingDirection and self.movingDirection < 0               then return false, 1 end

    -- VWW section guard — mirrors ESE initExtendedSprayerNozzleEffect
    local spec_vww = self.spec_variableWorkWidth
    if spec_vww and spec_vww.sections and effectData.sectionIndex ~= 0 then
        local section = spec_vww.sections[effectData.sectionIndex]
        if section and not section.isActive then return false, 1 end
    end

    local sfm = g_SoilFertilityManager
    if not sfm or not sfm.sensorManager then return isTurnedOn, 1 end

    -- No See & Spray active: nozzle state follows isTurnedOn
    if not sfm.sensorManager:hasAnySeeSprayEnabled(self.id) then return isTurnedOn, 1 end

    -- No cached field: default to spray (fail-open)
    local spec   = self[SFNozzleEffects.SPEC_TABLE_NAME]
    local fieldId = spec._sfFieldId
    if not fieldId then return true, 1 end

    local fd = sfm.soilSystem and sfm.soilSystem.fieldData[fieldId]
    if not fd then return true, 1 end

    -- Probe 1m ahead of this nozzle node in world space
    if not effectData.probeNode then return true, 1 end
    local pok, px, _, pz = pcall(localToWorld, effectData.probeNode, 0, 0, 1)
    if not pok then return true, 1 end

    -- Resolve zone cell at probe position
    local cellKey = tostring(math.floor(px / CELL_SIZE) * 10000 + math.floor(pz / CELL_SIZE))
    local cell    = fd.zoneData and fd.zoneData[cellKey]
    local ssCfg   = SoilConstants.SEE_AND_SPRAY
    local vid     = self.id

    local pestVal    = (cell and cell.pestPressure)    or (fd.pestPressure    or 0)
    local diseaseVal = (cell and cell.diseasePressure) or (fd.diseasePressure or 0)
    local weedVal    = (cell and cell.weedPressure)    or (fd.weedPressure    or 0)

    -- Spray if any enabled sensor is above its threshold here
    if sfm.sensorManager:isSeeSprayPestEnabled(vid) and pestVal >= ssCfg.PEST_THRESHOLD then
        return true, 1
    end
    if sfm.sensorManager:isSeeSprayDiseaseEnabled(vid) and diseaseVal >= ssCfg.DISEASE_THRESHOLD then
        return true, 1
    end
    if sfm.sensorManager:isSeeSprayWeedEnabled(vid) and weedVal >= ssCfg.WEED_THRESHOLD
        and not (fd.herbicideDaysLeft and fd.herbicideDaysLeft > 0) then
        return true, 1
    end

    -- All enabled sensors below threshold at this nozzle → suppress
    return false, 1
end

-- ── Usage scaling ─────────────────────────────────────────────────────────────

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
-- Only applies when See & Spray is enabled — otherwise falls through unchanged.
function SFNozzleEffects:getSprayerUsage(superFunc, fillType, dt)
    local usage = superFunc(self, fillType, dt)
    local spec  = self[SFNozzleEffects.SPEC_TABLE_NAME]
    local sfm   = g_SoilFertilityManager
    if spec.hasCustomEffects and sfm and sfm.sensorManager
        and sfm.sensorManager:hasAnySeeSprayEnabled(self.id) then
        local _, alpha = self:getNumExtendedSprayerNozzleEffectsActive()
        usage = usage * alpha
        -- Keep a minimum nonzero value so the AI worker doesn't halt (mirrors PF pattern)
        if (self.getIsAIActive ~= nil and self:getIsAIActive()) and usage == 0 then
            usage = 0.0001
        end
    end
    return usage
end
