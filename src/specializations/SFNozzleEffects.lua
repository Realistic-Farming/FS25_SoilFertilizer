-- SFNozzleEffects — per-nozzle effects specialization for SF mod sprayers.
-- Registers the vehicle.sprayer.nozzles XML schema and creates the
-- spec_extendedSprayerEffects data structure so HookManager's overlap
-- suppression code can query section-to-nozzle mapping without PF.
--
-- Design: effectNode is intentionally nil on each effectData record.
-- The ESE shader-suppress path in HookManager skips nil effectNodes,
-- while the base-game section.effects setVisibility path handles the
-- actual visual suppression. No PF dependency — ever.

SFNozzleEffects = {}
SFNozzleEffects.SPEC_TABLE_NAME = "spec_extendedSprayerEffects"

function SFNozzleEffects.initSpecialization()
    local schema = Vehicle.xmlSchema
    schema:setXMLSpecializationType("SFNozzleEffects")

    schema:register(XMLValueType.INT,        "vehicle.sprayer.nozzles(?)#foldingConfigurationIndex", "Folding config index for this nozzle group", 1)
    schema:register(XMLValueType.NODE_INDEX, "vehicle.sprayer.nozzles(?).nozzle(?)#node",            "Nozzle anchor node")
    schema:register(XMLValueType.VECTOR_TRANS,"vehicle.sprayer.nozzles(?).nozzle(?)#translation",   "Translation offset from anchor node")
    schema:register(XMLValueType.VECTOR_ROT,  "vehicle.sprayer.nozzles(?).nozzle(?)#rotation",      "Rotation offset from anchor node")

    schema:setXMLSpecializationType()
end

function SFNozzleEffects.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Sprayer, specializations)
end

function SFNozzleEffects.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "getNumExtendedSprayerNozzleEffectsActive", SFNozzleEffects.getNumExtendedSprayerNozzleEffectsActive)
end

function SFNozzleEffects.registerOverwrittenFunctions(vehicleType)
    -- intentionally empty — do not suppress base-game getAreEffectsVisible
end

function SFNozzleEffects.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad",     SFNozzleEffects)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", SFNozzleEffects)
end

function SFNozzleEffects:onLoad(savegame)
    local spec = self[SFNozzleEffects.SPEC_TABLE_NAME]

    spec.sprayerEffects        = {}
    spec.sprayerEffectsBySection = {}
    spec.hasCustomEffects      = false
    spec.numCustomEffects      = 0
    spec.pwmEnabled            = false
    spec.effectFadeTime        = 250
    spec.effectsDirty          = false

    -- Collect nozzle anchor nodes for the active folding configuration.
    -- Stored temporarily; section mapping happens in onPostLoad once VWW is ready.
    spec.pendingNozzles = {}
    self.xmlFile:iterate("vehicle.sprayer.nozzles", function(_, nozzlesKey)
        local foldingIdx = self.xmlFile:getValue(nozzlesKey .. "#foldingConfigurationIndex", 1)
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

    -- Determine the dead-band half-width around center (matches ESE logic)
    local minWidth = 1
    if spec_vww.sectionNodes and #spec_vww.sectionNodes > 0 then
        local sn = spec_vww.sectionNodes[1]
        local startX = sn.startTransX or (sn.startTrans and sn.startTrans[1]) or 1
        minWidth = math.abs(startX)
    end

    for _, nozzleNode in ipairs(spec.pendingNozzles) do
        local ok, xOffset = pcall(function()
            local x, _, _ = localToLocal(nozzleNode, self:getParentComponent(nozzleNode), 0, 0, 0)
            return x
        end)
        if not ok then xOffset = 0 end

        -- Map nozzle X position to VWW section index (mirrors ESE initExtendedSprayerNozzleEffect)
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

        -- effectNode is nil: we have no shader plane, only an anchor node.
        -- HookManager's ESE path skips nil effectNodes; section.effects handles visuals.
        local effectData = {
            effectNode   = nil,
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
    -- hasCustomEffects stays false: base-game getAreEffectsVisible is not overridden
end

function SFNozzleEffects:getNumExtendedSprayerNozzleEffectsActive()
    return 1, 1
end
