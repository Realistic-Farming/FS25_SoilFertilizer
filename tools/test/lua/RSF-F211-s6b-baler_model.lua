-- RSF-F211-s6b-baler_model.lua - the Baler, FillUnit and Bale the part 2a bench runs.
--
-- NOT A TEST (no _test suffix). A bar lists it in --!load AFTER
-- RSF-F208-s3-engine_model.lua, whose height map, line geometry and pickup primitive it
-- uses. Bodies marked VERBATIM follow D:\FS25_Decoded\dataS\scripts_decompiled at the
-- cited lines, server side; where the decompile lost a local (a name used but never
-- declared) the local is restored and said so. Presentation (animations, sounds,
-- effects, dummy bales, joints, consumables) is abbreviated and said so; nothing that
-- decides a quantity is.

-- ── the engine surface these bodies call ────────────────────────────────────
ToolType = ToolType or { UNDEFINED = 0 }
NetworkUtil = NetworkUtil or {}
NetworkUtil.getObjectId = NetworkUtil.getObjectId or function(o) return o ~= nil and o.nodeId or nil end
BalerCreateBaleEvent = BalerCreateBaleEvent or { new = function(...) return { ... } end }
if g_server ~= nil and g_server.broadcastEvent == nil then g_server.broadcastEvent = function() end end
Logging = Logging or {}
Logging.error = Logging.error or function() end

-- ── Bale (objects/Bale.lua), the parts createBale uses ───────────────────────
-- A bale's node is a fresh number; register() is looked up on the Bale CLASS at call
-- time, so Soil's Bale.register wrap is the one that runs, as in the engine.
Bale = Bale or {}
BALER_MODEL = { nextNode = 70000, registered = {}, failLoad = false, onRegister = nil }
function Bale.new(isServer, isClient)
    BALER_MODEL.nextNode = BALER_MODEL.nextNode + 1
    return setmetatable({ isServer = isServer, isClient = isClient, nodeId = BALER_MODEL.nextNode, fillType = 0, fillLevel = 0, ownerFarmId = 0 }, { __index = Bale })
end
-- [RSF-F215] The native unique id: loadFromConfigXML sets a loaded one (Bale.lua:269-270)
-- and the item system assigns one otherwise (ItemSystem.lua:209-213); getUniqueId :805.
BALER_MODEL.nextUid = 1
function Bale:loadFromConfigXML(filename, _x, _y, _z, _rx, _ry, _rz, uniqueId)
    if BALER_MODEL.failLoad then return false end
    self.filename = filename
    if uniqueId ~= nil then
        self.uniqueId = uniqueId
    else
        self.uniqueId = string.format("bale%d", BALER_MODEL.nextUid)
        BALER_MODEL.nextUid = BALER_MODEL.nextUid + 1
    end
    return true
end
function Bale:getUniqueId() return self.uniqueId end
function Bale:setUniqueId(uniqueId) self.uniqueId = uniqueId end
-- :349 and the attributes object storage keeps (the fields this bench reads).
function Bale:getBaleAttributes()
    return { xmlFilename = self.filename, uniqueId = self.uniqueId, fillLevel = self.fillLevel, fillType = self.fillType, farmId = self.ownerFarmId }
end
function Bale:applyBaleAttributes(a) self.fillLevel, self.fillType, self.ownerFarmId = a.fillLevel, a.fillType, a.farmId end
function Bale:setFillType(ft) self.fillType = ft end
function Bale:getFillType() return self.fillType end
function Bale:setFillLevel(l) self.fillLevel = l end
function Bale:getFillLevel() return self.fillLevel end
function Bale:getCapacity() return self.fillLevel end
function Bale:setVariationId(v) self.variationId = v end
function Bale:setOwnerFarmId(f) self.ownerFarmId = f end
function Bale:getOwnerFarmId() return self.ownerFarmId end
function Bale:register()
    BALER_MODEL.registered[#BALER_MODEL.registered + 1] = self
    -- Another mod reacting to a registration (a stand-in): a bar sets it to register an
    -- unrelated object inside createBale.
    if BALER_MODEL.onRegister ~= nil then local cb = BALER_MODEL.onRegister BALER_MODEL.onRegister = nil cb(self) end
end
function Bale:mountKinematic() end
function Bale:setCanBeSold() end
function Bale:setNeedsSaving() end
function Bale:delete() self.deleted = true end

-- ── FillUnit:addFillUnitFillLevel (vehicles/specializations/FillUnit.lua:1103-1275) ──
-- The quantity path VERBATIM in effect: the access and tool-type refusals collapse to
-- `unit.refuse` (an early return 0 before any event, :1116-1141), the trailer mass limit
-- to `unit.massLimit` (reduces the request before the capacity clamp, :1127-1133), the
-- fill-type change and the empty reset as :1136-1165, the event raised with the reduced
-- request and the applied delta (:1203) through each listener spec class at call time,
-- and the applied delta returned (:1275). Presentation and sync are abbreviated.
FILLUNIT = {}
function FILLUNIT.add(self, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData)
    local unit = self.spec_fillUnit.fillUnits[fillUnitIndex]
    if unit == nil or unit.refuse then return 0 end
    if fillLevelDelta > 0 and unit.massLimit ~= nil then fillLevelDelta = math.min(fillLevelDelta, unit.massLimit) end
    local oldLevel = unit.fillLevel
    local capacity = unit.capacity == 0 and math.huge or unit.capacity
    if unit.fillType == fillTypeIndex then
        unit.fillLevel = math.max(0, math.min(capacity, oldLevel + fillLevelDelta))
    elseif fillLevelDelta > 0 then
        if oldLevel > 0 then FILLUNIT.add(self, farmId, fillUnitIndex, -math.huge, unit.fillType, toolType, fillPositionData) end
        unit.fillLevel = math.max(0, math.min(capacity, fillLevelDelta))
        unit.fillType = fillTypeIndex
    end
    if unit.fillLevel < 0.00001 then unit.fillLevel = 0 end
    if unit.fillLevel <= 0 then unit.fillType = FillType.UNKNOWN end
    local appliedDelta = unit.fillLevel - oldLevel
    for _, class in ipairs(self.eventListeners.onFillUnitFillLevelChanged or {}) do
        class.onFillUnitFillLevelChanged(self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta)
    end
    return appliedDelta
end

-- ── the Baler (vehicles/specializations/Baler.lua) ──────────────────────────
Baler = Baler or {}
Baler.CLIENT_DM_UPDATE_RADIUS = 50

-- :1863-1915 VERBATIM (the additive effect block's client half abbreviated).
function Baler:processBalerArea(workArea, _)
    local spec = self.spec_baler
    if not self.isServer and self.currentUpdateDistance > Baler.CLIENT_DM_UPDATE_RADIUS then
        return 0, 0
    end
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height)
    if self.isServer then
        spec.fillEffectType = FillType.UNKNOWN
    end
    local mission = self:getMissionByWorkArea(workArea)
    for fillTypeIndex, _ in pairs(spec.pickupFillTypes) do
        local pickedUpLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillTypeIndex, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, nil, false, nil)
        if pickedUpLiters > 0 then
            if self.isServer then
                spec.fillEffectType = fillTypeIndex
                if spec.additives.available and not spec.additives.appliedByBufferOverloading then
                    local fillTypeSupported = false
                    for i = 1, #spec.additives.fillTypes do
                        if fillTypeIndex == spec.additives.fillTypes[i] then
                            fillTypeSupported = true
                            break
                        end
                    end
                    if fillTypeSupported then
                        local additivesFillLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
                        if additivesFillLevel > 0 then
                            local usage = spec.additives.usage * pickedUpLiters
                            if usage > 0 then
                                pickedUpLiters = pickedUpLiters * (1 + 0.05 * math.min(additivesFillLevel / usage, 1))
                                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                            end
                        end
                    end
                end
            end
            spec.pickupFillTypes[fillTypeIndex] = spec.pickupFillTypes[fillTypeIndex] + pickedUpLiters
            spec.workAreaParameters.lastMissionUniqueId = mission ~= nil and mission:getUniqueId() or nil
            spec.workAreaParameters.lastPickedUpLiters = spec.workAreaParameters.lastPickedUpLiters + pickedUpLiters
            return pickedUpLiters, pickedUpLiters
        end
    end
    return 0, 0
end

-- :1954-1959 VERBATIM, with the local the decompile lost (`spec`) restored.
function Baler:onStartWorkAreaProcessing(_)
    local spec = self.spec_baler
    if self.isServer then
        spec.lastAreaBiggerZero = false
        spec.workAreaParameters.lastPickedUpLiters = 0
    end
end

-- :1960-2010 VERBATIM for the quantity path (the decompile's reused locals renamed:
-- the receiver is `fillUnitIndex`), the loading-state animation and dirty flags
-- abbreviated.
function Baler:onEndWorkAreaProcessing(_, _)
    local spec = self.spec_baler
    if self.isServer then
        local maxFillType = FillType.UNKNOWN
        local maxFillTypeFillLevel = 0
        for fillTypeIndex, fillLevel in pairs(spec.pickupFillTypes) do
            if maxFillTypeFillLevel < fillLevel then
                maxFillType = fillTypeIndex
                maxFillTypeFillLevel = fillLevel
            end
        end
        local pickedUpLiters = spec.workAreaParameters.lastPickedUpLiters
        if pickedUpLiters > 0 then
            spec.lastAreaBiggerZero = true
            local deltaLevel = pickedUpLiters * spec.fillScale
            local fillUnitIndex = spec.fillUnitIndex
            if spec.nonStopBaling then
                if spec.buffer.fillMainUnitAfterOverload and spec.buffer.unloadingStarted then
                    if self:getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0 then
                        fillUnitIndex = spec.buffer.fillUnitIndex
                    end
                else
                    fillUnitIndex = spec.buffer.fillUnitIndex
                end
            end
            self:setFillUnitFillType(fillUnitIndex, maxFillType)
            self:addFillUnitFillLevel(self:getOwnerFarmId(), fillUnitIndex, deltaLevel, maxFillType, ToolType.UNDEFINED)
        end
    end
end

-- :1155-1184 VERBATIM for the main unit on the server (the dummy-bale and animation
-- calls abbreviated; the buffer branch is part 2b's).
function Baler:onFillUnitFillLevelChanged(fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, _, appliedDelta)
    local spec = self.spec_baler
    if fillUnitIndex == spec.fillUnitIndex then
        if self.isServer and fillLevelDelta > 0 then
            if self:getFillUnitFreeCapacity(spec.fillUnitIndex) <= 0 then
                if self.isAddedToPhysics then
                    self:finishBale()
                else
                    spec.createBaleNextFrame = true
                end
                spec.fillUnitOverflowFillLevel = fillLevelDelta - appliedDelta
                return
            end
            if spec.fillUnitOverflowFillLevel > 0 and fillLevelDelta > 0 then
                local overflow = spec.fillUnitOverflowFillLevel
                spec.fillUnitOverflowFillLevel = 0
                spec.fillUnitOverflowFillLevel = overflow - self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, overflow, fillTypeIndex, toolType)
                return
            end
        end
    end
end

-- :1427-1454 VERBATIM (Logging.error kept).
function Baler:finishBale()
    local spec = self.spec_baler
    if spec.baleTypes ~= nil then
        local fillTypeIndex = self:getFillUnitFillType(spec.fillUnitIndex)
        if spec.hasUnloadingAnimation then
            if self:createBale(fillTypeIndex, self:getFillUnitCapacity(spec.fillUnitIndex)) then
                g_server:broadcastEvent(BalerCreateBaleEvent.new(self, fillTypeIndex, 0, NetworkUtil.getObjectId(spec.bales[#spec.bales].baleObject)), nil, nil, self)
                return
            end
            Logging.error("Failed to create bale!")
        else
            self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -math.huge, fillTypeIndex, ToolType.UNDEFINED)
            spec.buffer.unloadingStarted = false
            for fillType, _ in pairs(spec.pickupFillTypes) do
                spec.pickupFillTypes[fillType] = 0
            end
            if not self:createBale(fillTypeIndex, self:getFillUnitCapacity(spec.fillUnitIndex)) then
                Logging.error("Failed to create bale!")
                return
            end
            g_server:broadcastEvent(BalerCreateBaleEvent.new(self, fillTypeIndex, spec.bales[#spec.bales].time), nil, nil, self)
            if self:getFillUnitFillLevel(spec.fillUnitIndex) == 0 and spec.preSelectedBaleTypeIndex ~= spec.currentBaleTypeIndex then
                self:setBaleTypeIndex(spec.preSelectedBaleTypeIndex, true)
                return
            end
        end
    end
end

-- :1455-1570, the SERVER path: the bale record, Bale.new, loadFromConfigXML, the fill,
-- the owner, register(), the record appended when valid, isValid returned. The local
-- the decompile lost (`baleTypeDef`, the current bale type) is restored. Knotting
-- animation, consumables, the round mount and the square joint are abbreviated.
function Baler:createBale(baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId, loadFromSavegame)
    local spec = self.spec_baler
    local baleTypeDef = spec.baleTypes[spec.currentBaleTypeIndex]
    local isValid = false
    local bale = { filename = xmlFilename or spec.currentBaleXMLFilename, time = baleTime }
    bale.fillType = baleFillType
    bale.fillLevel = fillLevel
    if self.isServer then
        local baleObject = Bale.new(self.isServer, self.isClient)
        local x, y, z = getWorldTranslation(baleTypeDef.baleRootNode)
        if baleObject:loadFromConfigXML(bale.filename, x, y, z, 0, 0, 0) then
            baleObject:setFillType(baleFillType)
            baleObject:setFillLevel(fillLevel)
            baleObject:setVariationId(variationId or (spec.lastBaleVariationId or baleTypeDef.defaultBaleVariationId))
            if ownerFarmId == nil then
                baleObject:setOwnerFarmId(self:getBalerBaleOwnerFarmId(x, z), true)
            else
                baleObject:setOwnerFarmId(ownerFarmId, true)
            end
            baleObject:register()
            if spec.hasUnloadingAnimation then
                baleObject:mountKinematic(self, baleTypeDef.baleRootNode, 0, 0, 0, 0, 0, 0)
            else
                baleObject:setCanBeSold(false)
                baleObject:setNeedsSaving(false)
            end
            bale.baleObject = baleObject
            isValid = true
        end
    end
    if isValid then
        table.insert(spec.bales, bale)
    end
    return isValid
end

-- :928 in effect: the engine empties the round chamber when the bale leaves (dropBale /
-- unloading); a bar calls it to model that step.
function BALER_MODEL.clearChamber(v)
    return v:addFillUnitFillLevel(v:getOwnerFarmId(), v.spec_baler.fillUnitIndex, -math.huge, v:getFillUnitFillType(v.spec_baler.fillUnitIndex), ToolType.UNDEFINED)
end

--- A Baler as the engine builds it: its registered functions COPIED into the instance
--- (SpecializationUtil.copyTypeFunctionsInto, :141-145), the pickup work area's
--- pointer CAPTURED from the instance (WorkArea.lua:182-183), listeners dispatched
--- through the Baler class at call time. One pickup work area at x in [x0, x0 + width],
--- z in [z0, z0 + depth]. opts: capacity, round, fillScale, massLimit, additives =
--- { level, usage }, uid.
function BALER_MODEL.new(opts)
    local v = { isServer = true, isClient = false, currentUpdateDistance = 0, uniqueId = opts.uid or "baler", isAddedToPhysics = true }
    v.specClasses = { Baler }
    v.eventListeners = { onFillUnitFillLevelChanged = { Baler } }
    v.processBalerArea, v.finishBale, v.createBale = Baler.processBalerArea, Baler.finishBale, Baler.createBale
    local units = { [1] = { capacity = opts.capacity or 1000, fillLevel = 0, fillType = FillType.UNKNOWN, massLimit = opts.massLimit } }
    local additives = { available = false, fillTypes = {}, usage = 0, fillUnitIndex = 2 }
    if opts.additives ~= nil then
        units[2] = { capacity = 100000, fillLevel = opts.additives.level or 0, fillType = 99 }
        additives = { available = true, fillTypes = { ENGINE.FT.GRASS_WINDROW, ENGINE.FT.DRYGRASS_WINDROW }, usage = opts.additives.usage or 0.001, fillUnitIndex = 2 }
    end
    v.spec_fillUnit = { fillUnits = units }
    v.addFillUnitFillLevel = FILLUNIT.add
    v.getFillUnitFillLevel = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.fillLevel or 0 end
    v.getFillUnitCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.capacity or 0 end
    v.getFillUnitFreeCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and (u.capacity - u.fillLevel) or 0 end
    v.getFillUnitFillType = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.fillType or FillType.UNKNOWN end
    v.setFillUnitFillType = function(self, i, ft) local u = self.spec_fillUnit.fillUnits[i] if u and u.fillLevel <= 0 then u.fillType = ft end end
    v.getOwnerFarmId = function() return 1 end
    v.getMissionByWorkArea = function() return nil end
    v.getBalerBaleOwnerFarmId = function() return 1 end
    v.setBaleTypeIndex = function(self, i) self.spec_baler.currentBaleTypeIndex = i end
    v.spec_baler = {
        fillUnitIndex = 1, fillScale = opts.fillScale or 1, hasUnloadingAnimation = opts.round == true,
        pickupFillTypes = { [ENGINE.FT.GRASS_WINDROW] = 0, [ENGINE.FT.DRYGRASS_WINDROW] = 0, [ENGINE.FT.STRAW] = 0 },
        workAreaParameters = { lastPickedUpLiters = 0 }, additives = additives,
        fillUnitOverflowFillLevel = 0, nonStopBaling = false, buffer = { fillUnitIndex = 3, unloadingStarted = false },
        bales = {}, baleTypes = { { baleRootNode = { x = 0, y = 0, z = 0 }, defaultBaleVariationId = 1 } },
        currentBaleTypeIndex = 1, preSelectedBaleTypeIndex = 1, currentBaleXMLFilename = "bale.xml",
    }
    local x0, z0, w, d = opts.x0 or 0, opts.z0 or 0, opts.width or 4, opts.depth or 2
    local work = { index = 1, functionName = "processBalerArea", start = { x = x0, z = z0 }, width = { x = x0 + w, z = z0 }, height = { x = x0, z = z0 + d } }
    v.spec_workArea = { workAreas = { work } }
    work.processingFunction = v[work.functionName]
    return v, work
end

-- ── part 2b: the non-stop buffer, the partial round bale ────────────────────
MathUtil.round = MathUtil.round or function(v, decimals)
    local m = 10 ^ (decimals or 0)
    return math.floor(v * m + 0.5) / m
end
Baler.UNLOADING_CLOSED = Baler.UNLOADING_CLOSED or 1
Baler.UNLOADING_OPENING = Baler.UNLOADING_OPENING or 2
BalerSetIsUnloadingBaleEvent = BalerSetIsUnloadingBaleEvent or { sendEvent = function() end }

-- :996-1060 VERBATIM for the buffer-to-chamber transfer (the overload animation and the
-- additive effect's client half abbreviated; the decompile's reused locals renamed:
-- bufferLevel, bufferCapacity, mainCapacity, debited). The rest of onUpdateTick (bale
-- movement, speed limits, the deferred createBaleNextFrame at :815) is not this
-- bench's; a bar calls BALER_MODEL.updateTick, which looks the listener up on the Baler
-- class at call time, as SpecializationUtil.raiseEvent does.
function Baler:onUpdateTick(dt, _, _, _)
    local spec = self.spec_baler
    if not self.isServer or not spec.nonStopBaling then return end
    local isTurnedOn = self:getIsTurnedOn()
    local bufferLevel = self:getFillUnitFillLevel(spec.buffer.fillUnitIndex)
    if bufferLevel > 0 then
        local bufferCapacity = self:getFillUnitCapacity(spec.buffer.fillUnitIndex)
        if isTurnedOn and MathUtil.round(bufferLevel / bufferCapacity, 2) >= spec.buffer.overloadingStartFillLevelPct then
            local mainCapacity = self:getFillUnitCapacity(spec.fillUnitIndex)
            if (mainCapacity == 0 or (mainCapacity == math.huge or self:getFillUnitFreeCapacity(spec.fillUnitIndex) > 0)) and (not spec.buffer.unloadingStarted and spec.unloadingState == Baler.UNLOADING_CLOSED) then
                spec.buffer.unloadingStarted = true
                spec.buffer.overloadingTimer = 0
            end
        end
        if spec.buffer.unloadingStarted then
            spec.buffer.overloadingTimer = spec.buffer.overloadingTimer + dt
            if spec.buffer.overloadingTimer >= spec.buffer.overloadingDelay and self:getFillUnitFreeCapacity(spec.fillUnitIndex) > 0 then
                local rate = self:getFillUnitCapacity(spec.buffer.fillUnitIndex) / spec.buffer.overloadingDuration * dt
                local delta = math.min(rate, bufferLevel)
                local sourceFillType = self:getFillUnitFillType(spec.buffer.fillUnitIndex)
                local debited = self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.buffer.fillUnitIndex, -delta, sourceFillType, ToolType.UNDEFINED, nil)
                local mainType = self:getFillUnitFillType(spec.fillUnitIndex)
                if mainType ~= FillType.UNKNOWN then
                    sourceFillType = mainType
                end
                local overloadedLiters = -debited
                if spec.additives.available and spec.additives.appliedByBufferOverloading then
                    local fillTypeSupported = false
                    for i = 1, #spec.additives.fillTypes do
                        if sourceFillType == spec.additives.fillTypes[i] then
                            fillTypeSupported = true
                            break
                        end
                    end
                    if fillTypeSupported then
                        local additivesFillLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
                        if additivesFillLevel > 0 then
                            local usage = spec.additives.usage * overloadedLiters
                            if usage > 0 then
                                overloadedLiters = overloadedLiters * (1 + 0.05 * math.min(additivesFillLevel / usage, 1))
                                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                            end
                        end
                    end
                end
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, overloadedLiters, sourceFillType, ToolType.UNDEFINED, nil)
                if spec.buffer.fillLevelToEmpty > 0 then
                    spec.buffer.fillLevelToEmpty = math.max(spec.buffer.fillLevelToEmpty - delta, 0)
                    if spec.buffer.fillLevelToEmpty == 0 then
                        spec.platformDelayedDropping = true
                        spec.buffer.unloadingStarted = false
                    end
                end
            end
        end
    end
end

-- :1322-1349, the unfinished round bale's branch, and the state change that follows.
-- The decompile shadows a local in the buffer debit (it reads mainFillLevel minus
-- mainFillLevel, a zero as written); read as its evident intent: the buffer gives up
-- what the bale takes beyond the chamber, target minus the current chamber level.
-- Sounds and animations abbreviated.
function Baler:setIsUnloadingBale(isUnloadingBale, noEventSend)
    local spec = self.spec_baler
    if spec.hasUnloadingAnimation and isUnloadingBale and spec.unloadingState ~= Baler.UNLOADING_OPENING then
        if #spec.bales == 0 and spec.canUnloadUnfinishedBale then
            local fillTypeIndex = self:getFillUnitFillType(spec.fillUnitIndex)
            local fillLevel = self:getFillUnitFillLevel(spec.fillUnitIndex)
            if spec.buffer.fillUnitIndex ~= nil then
                fillLevel = fillLevel + self:getFillUnitFillLevel(spec.buffer.fillUnitIndex)
                if fillTypeIndex == FillType.UNKNOWN then
                    fillTypeIndex = self:getFillUnitFillType(spec.buffer.fillUnitIndex)
                end
            end
            if spec.unfinishedBaleThreshold < fillLevel then
                local delta = self:getFillUnitFreeCapacity(spec.fillUnitIndex)
                local mainFillLevel = math.min(fillLevel, self:getFillUnitCapacity(spec.fillUnitIndex))
                if spec.buffer.fillUnitIndex ~= nil then
                    local currentMain = self:getFillUnitFillLevel(spec.fillUnitIndex)
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.buffer.fillUnitIndex, -math.max(mainFillLevel - currentMain, 0), self:getFillUnitFillType(spec.buffer.fillUnitIndex), ToolType.UNDEFINED)
                end
                spec.lastBaleFillLevel = mainFillLevel
                self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, delta, fillTypeIndex, ToolType.UNDEFINED)
                spec.buffer.unloadingStarted = false
            end
        end
        BalerSetIsUnloadingBaleEvent.sendEvent(self, isUnloadingBale, noEventSend)
        spec.unloadingState = Baler.UNLOADING_OPENING
    end
end

-- :1590-1593 in effect: dropping the only bale gives it the stored real amount.
function BALER_MODEL.dropBale(v)
    local spec = v.spec_baler
    local bale = spec.bales[1]
    if bale == nil then return end
    if spec.lastBaleFillLevel ~= nil and #spec.bales == 1 then
        bale.baleObject:setFillLevel(spec.lastBaleFillLevel)
        spec.lastBaleFillLevel = nil
    end
    table.remove(spec.bales, 1)
end

--- The engine's onUpdateTick dispatch: the listener looked up on the class at call time.
function BALER_MODEL.updateTick(v, dt)
    Baler.onUpdateTick(v, dt)
end

--- A non-stop baler: BALER_MODEL.new plus the buffer unit (index 3), its transfer
--- parameters, and for a round one the unfinished-bale unloading. Its setIsUnloadingBale
--- is the registered function copied into the instance.
function BALER_MODEL.newNonStop(opts)
    local v, work = BALER_MODEL.new(opts)
    local spec = v.spec_baler
    v.spec_fillUnit.fillUnits[3] = { capacity = opts.bufferCapacity or 100, fillLevel = 0, fillType = FillType.UNKNOWN }
    v.setIsUnloadingBale = Baler.setIsUnloadingBale
    v.getIsTurnedOn = function() return true end
    spec.nonStopBaling = true
    spec.buffer = { fillUnitIndex = 3, unloadingStarted = false, overloadingStartFillLevelPct = opts.startPct or 0.5,
                    overloadingTimer = 0, overloadingDelay = 0, overloadingDuration = opts.duration or 1000, fillLevelToEmpty = 0 }
    spec.unloadingState = Baler.UNLOADING_CLOSED
    spec.canUnloadUnfinishedBale = opts.canUnloadUnfinishedBale == true
    spec.unfinishedBaleThreshold = opts.unfinishedBaleThreshold or 10
    if opts.bufferAdditives then spec.additives.appliedByBufferOverloading = true end
    return v, work
end

-- ── the ForageWagon (vehicles/specializations/ForageWagon.lua), part 2b ──────
ForageWagon = ForageWagon or {}

-- :138-203 VERBATIM (the decompile's reused locals renamed: `supportedFillTypes`, the
-- work returns `workedArea`; effects and dirty flags abbreviated).
function ForageWagon:processForageWagonArea(workArea)
    local spec = self.spec_forageWagon
    local lsx, lsy, lsz, lex, ley, lez = DensityMapHeightUtil.getLineByArea(workArea.start, workArea.width, workArea.height)
    local pickupLiters = 0
    if spec.workAreaParameters.forcedFillType == FillType.UNKNOWN then
        local supportedFillTypes = self:getFillUnitSupportedFillTypes(spec.fillUnitIndex)
        if supportedFillTypes ~= nil then
            for fillType, state in pairs(supportedFillTypes) do
                if state then
                    pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, fillType, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
                    if pickupLiters > 0 then
                        spec.workAreaParameters.forcedFillType = fillType
                        break
                    end
                end
            end
        end
    else
        pickupLiters = -DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, spec.workAreaParameters.forcedFillType, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
        if spec.workAreaParameters.forcedFillType == FillType.GRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.DRYGRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
        elseif spec.workAreaParameters.forcedFillType == FillType.DRYGRASS_WINDROW then
            pickupLiters = pickupLiters - DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, FillType.GRASS_WINDROW, lsx, lsy, lsz, lex, ley, lez, 0.5, nil, nil, false, nil)
        end
    end
    if self.isServer and spec.additives.available then
        local fillTypeSupported = false
        for i = 1, #spec.additives.fillTypes do
            if spec.workAreaParameters.forcedFillType == spec.additives.fillTypes[i] then
                fillTypeSupported = true
                break
            end
        end
        if fillTypeSupported then
            local additivesFillLevel = self:getFillUnitFillLevel(spec.additives.fillUnitIndex)
            if additivesFillLevel > 0 then
                local usage = spec.additives.usage * pickupLiters
                if usage > 0 then
                    pickupLiters = pickupLiters * (1 + 0.05 * math.min(additivesFillLevel / usage, 1))
                    self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.additives.fillUnitIndex, -usage, self:getFillUnitFillType(spec.additives.fillUnitIndex), ToolType.UNDEFINED)
                end
            end
        end
    end
    workArea.lastPickUpLiters = pickupLiters
    workArea.pickupParticlesActive = pickupLiters > 0
    spec.workAreaParameters.lastPickupLiters = spec.workAreaParameters.lastPickupLiters + pickupLiters
    spec.workAreaParameters.litersToFill = spec.workAreaParameters.litersToFill + pickupLiters
    if spec.workAreaParameters.forcedFillType ~= FillType.UNKNOWN then
        spec.lastFillType = spec.workAreaParameters.forcedFillType
    end
    local workedArea = 0
    if self.movingDirection == 1 then
        workedArea = MathUtil.vector3Length(lsx - lex, lsy - ley, lsz - lez) * self.lastMovedDistance
    end
    return workedArea, workedArea
end

-- :216-228 VERBATIM.
function ForageWagon:fillForageWagon()
    local spec = self.spec_forageWagon
    local loadInfo = self:getFillVolumeLoadInfo(spec.loadInfoIndex)
    local filledLiters = self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, spec.workAreaParameters.litersToFill, spec.lastFillType, ToolType.UNDEFINED, loadInfo)
    if filledLiters + 0.01 < spec.workAreaParameters.litersToFill then
        self:setIsTurnedOn(false)
        self:setPickupState(false)
    end
    spec.workAreaParameters.litersToFill = spec.workAreaParameters.litersToFill - filledLiters
    if spec.workAreaParameters.litersToFill < 0.01 then
        spec.workAreaParameters.litersToFill = 0
    end
end

-- :269-280 VERBATIM.
function ForageWagon:onStartWorkAreaProcessing(_)
    local spec = self.spec_forageWagon
    spec.workAreaParameters.forcedFillType = FillType.UNKNOWN
    local fillLevel = self:getFillUnitFillLevel(spec.fillUnitIndex)
    if self:getFillTypeChangeThreshold(spec.fillUnitIndex) < fillLevel then
        spec.workAreaParameters.forcedFillType = self:getFillUnitFillType(spec.fillUnitIndex)
    end
    if fillLevel == 0 and (spec.fillStartEffectDelay > 0 and spec.fillStartEffectTimer <= 0) then
        spec.fillStartEffectTimer = spec.fillStartEffectDelay
    end
    spec.workAreaParameters.lastPickupLiters = 0
end

-- :281-296 VERBATIM.
function ForageWagon:onEndWorkAreaProcessing(dt, _)
    local spec = self.spec_forageWagon
    if self.isServer and spec.workAreaParameters.lastPickupLiters > 0 then
        local allowToFill = true
        if spec.fillStartEffectTimer > 0 then
            spec.fillStartEffectTimer = spec.fillStartEffectTimer - dt
            if spec.fillStartEffectTimer > 0 then
                allowToFill = false
            end
        end
        if allowToFill then
            self:fillForageWagon()
        end
        spec.fillTimer = 500
    end
end

--- A ForageWagon as the engine builds it: registered functions copied into the
--- instance, the pickup pointer captured; one work area; the fill unit (index 1) of
--- `capacity` taking GRASS_WINDROW and DRYGRASS_WINDROW. opts: capacity, x0, z0, width,
--- depth, fillStartDelay (seconds as the XML gives it; the engine multiplies by 0.001
--- at load, so pass milliseconds' worth as the engine holds it), uid.
function BALER_MODEL.newWagon(opts)
    local v = { isServer = true, isClient = false, uniqueId = opts.uid or "wagon", movingDirection = 1, lastMovedDistance = 1 }
    v.specClasses = { ForageWagon }
    v.eventListeners = { onFillUnitFillLevelChanged = {} }
    v.processForageWagonArea, v.fillForageWagon = ForageWagon.processForageWagonArea, ForageWagon.fillForageWagon
    v.spec_fillUnit = { fillUnits = { [1] = { capacity = opts.capacity or 1000, fillLevel = 0, fillType = FillType.UNKNOWN } } }
    v.addFillUnitFillLevel = FILLUNIT.add
    v.getFillUnitFillLevel = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.fillLevel or 0 end
    v.getFillUnitCapacity = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.capacity or 0 end
    v.getFillUnitFillType = function(self, i) local u = self.spec_fillUnit.fillUnits[i] return u and u.fillType or FillType.UNKNOWN end
    v.getFillUnitSupportedFillTypes = function() return { [ENGINE.FT.GRASS_WINDROW] = true, [ENGINE.FT.DRYGRASS_WINDROW] = true } end
    v.getFillTypeChangeThreshold = function() return 0.05 end
    v.getFillVolumeLoadInfo = function() return nil end
    v.setIsTurnedOn = function(self, s) self.turnedOn = s end
    v.setPickupState = function(self, s) self.pickup = s end
    v.getOwnerFarmId = function() return 1 end
    v.spec_forageWagon = {
        fillUnitIndex = 1, loadInfoIndex = 1, lastFillType = FillType.UNKNOWN,
        additives = { available = false, fillTypes = {}, usage = 0 },
        fillStartEffectDelay = opts.fillStartDelay or 0, fillStartEffectTimer = 0, fillTimer = 0,
        workAreaParameters = { forcedFillType = FillType.UNKNOWN, lastPickupLiters = 0, litersToFill = 0 },
    }
    local x0, z0, w, d = opts.x0 or 0, opts.z0 or 0, opts.width or 4, opts.depth or 2
    local work = { index = 1, functionName = "processForageWagonArea", start = { x = x0, z = z0 }, width = { x = x0 + w, z = z0 }, height = { x = x0, z = z0 + d } }
    v.spec_workArea = { workAreas = { work } }
    work.processingFunction = v[work.functionName]
    return v, work
end

-- ── [RSF-F215] Object storage's bale class (placeables/specializations/PlaceableObjectStorage.lua) ──
-- The class is local there (:898) and registered as ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"]
-- (:881-889); the storage makes an instance with new() and calls addToStorage on it
-- (:427-433), so a method patched on the class reaches the instance. The paths a bale
-- that is not fermenting takes: in, its attributes kept and the bale deleted (:931-960,
-- the else branch); out, a new Bale from the attributes with the SAME unique id,
-- registered (:961-985).
PlaceableObjectStorage = PlaceableObjectStorage or {}
PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME or {}
local AbstractBaleObject = {}
AbstractBaleObject.REFERENCE_CLASS_NAME = "Bale"
function AbstractBaleObject.new() return setmetatable({}, { __index = AbstractBaleObject }) end
function AbstractBaleObject:addToStorage(storage, object, _loadedFromSavegame)
    self.baleAttributes = object:getBaleAttributes()
    object:delete()
end
function AbstractBaleObject:removeFromStorage(storage, x, y, z, rx, ry, rz)
    local baleObject = Bale.new(storage.isServer, storage.isClient)
    if baleObject:loadFromConfigXML(self.baleAttributes.xmlFilename, x, y, z, rx, ry, rz, self.baleAttributes.uniqueId) then
        baleObject:applyBaleAttributes(self.baleAttributes)
        baleObject:register()
    end
    return baleObject
end
PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"] = AbstractBaleObject
--- :427-433, addObjectToObjectStorage for a bale: the class's instance takes it in.
function BALER_MODEL.storeBale(storage, object)
    local abstract = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"].new()
    abstract:addToStorage(storage, object, false)
    return abstract
end
