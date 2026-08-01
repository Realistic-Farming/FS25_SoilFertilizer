-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Network Events
-- =========================================================
-- Multiplayer event classes for settings sync, full-state
-- handshake, per-field soil updates, and sprayer rate changes.
-- Flow: client requests → server validates/applies → broadcasts.
-- =========================================================
-- Author: TisonK
-- =========================================================

-- ========================================
-- SETTING CHANGE EVENT (Client -> Server)
-- ========================================
SoilSettingChangeEvent = {}
SoilSettingChangeEvent_mt = Class(SoilSettingChangeEvent, Event)

InitEventClass(SoilSettingChangeEvent, "SoilSettingChangeEvent")

function SoilSettingChangeEvent.emptyNew()
    return Event.new(SoilSettingChangeEvent_mt)
end

function SoilSettingChangeEvent.new(settingName, settingValue)
    local self = SoilSettingChangeEvent.emptyNew()
    self.settingName = settingName
    self.settingValue = settingValue
    return self
end

function SoilSettingChangeEvent:readStream(streamId, connection)
    self.settingName = streamReadString(streamId)
    local valueType = streamReadUInt8(streamId)

    if valueType == SoilConstants.NETWORK.VALUE_TYPE.BOOLEAN then
        self.settingValue = streamReadBool(streamId)
    elseif valueType == SoilConstants.NETWORK.VALUE_TYPE.NUMBER then
        self.settingValue = streamReadInt32(streamId)
    elseif valueType == SoilConstants.NETWORK.VALUE_TYPE.STRING then
        self.settingValue = streamReadString(streamId)
    end

    self:run(connection)
end

function SoilSettingChangeEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.settingName)

    if type(self.settingValue) == "boolean" then
        streamWriteUInt8(streamId, SoilConstants.NETWORK.VALUE_TYPE.BOOLEAN)
        streamWriteBool(streamId, self.settingValue)
    elseif type(self.settingValue) == "number" then
        streamWriteUInt8(streamId, SoilConstants.NETWORK.VALUE_TYPE.NUMBER)
        streamWriteInt32(streamId, self.settingValue)
    else
        streamWriteUInt8(streamId, SoilConstants.NETWORK.VALUE_TYPE.STRING)
        streamWriteString(streamId, tostring(self.settingValue))
    end
end

function SoilSettingChangeEvent:run(connection)
    -- SERVER ONLY: Validate and apply setting change
    if g_server == nil then return end

    -- Reject unknown settings and local-only settings - never apply to server state
    local def = SettingsSchema and SettingsSchema.byId and SettingsSchema.byId[self.settingName]
    if not def then
        SoilLogger.warning("Server: Rejected unknown setting '%s' from network event", tostring(self.settingName))
        return
    end
    if def.localOnly then return end

    -- Validate player is admin (master user)
    if not connection:getIsServer() then
        local user = g_currentMission.userManager and g_currentMission.userManager:getUserByConnection(connection)
        if not user or not user:getIsMasterUser() then
            SoilLogger.warning("Player %s (non-admin) tried to change settings - denied",
                user and user:getNickname() or "Unknown")
            return
        end
    end

    -- Validate the value against the schema before applying - without this an
    -- out-of-range number from a buggy/modified client (e.g. difficulty=99)
    -- would be stored in server state and broadcast to everyone.
    self.settingValue = SettingsSchema.validate(self.settingName, self.settingValue)
    if self.settingValue == nil then return end

    -- Apply setting on server
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local settings = g_SoilFertilityManager.settings
        local oldValue = settings[self.settingName]

        -- Update the setting
        settings[self.settingName] = self.settingValue
        settings:save()

        SoilLogger.info("Server: Setting '%s' changed from %s to %s",
            self.settingName, tostring(oldValue), tostring(self.settingValue))

        -- Re-initialize system if enabled state changed
        if self.settingName == "enabled" and g_SoilFertilityManager.soilSystem then
            if self.settingValue then
                -- Only re-initialize if the system is not already running
                if not g_SoilFertilityManager.soilSystem.isInitialized then
                    g_SoilFertilityManager.soilSystem:initialize()
                end
            end
        end

        -- Broadcast to ALL clients including the original sender.
        -- On dedicated servers the admin is a client - excluding them (old behaviour)
        -- meant their own panel never reflected the confirmed value (issue #208).
        if g_server then
            g_server:broadcastEvent(
                SoilSettingSyncEvent.new(self.settingName, self.settingValue)
            )
        end
    end
end

-- ========================================
-- SETTING SYNC EVENT (Server -> Clients)
-- ========================================
SoilSettingSyncEvent = {}
SoilSettingSyncEvent_mt = Class(SoilSettingSyncEvent, Event)

InitEventClass(SoilSettingSyncEvent, "SoilSettingSyncEvent")

function SoilSettingSyncEvent.emptyNew()
    return Event.new(SoilSettingSyncEvent_mt)
end

function SoilSettingSyncEvent.new(settingName, settingValue)
    local self = SoilSettingSyncEvent.emptyNew()
    self.settingName = settingName
    self.settingValue = settingValue
    return self
end

function SoilSettingSyncEvent:readStream(streamId, connection)
    self.settingName = streamReadString(streamId)
    local valueType = streamReadUInt8(streamId)

    if valueType == SoilConstants.NETWORK.VALUE_TYPE.BOOLEAN then
        self.settingValue = streamReadBool(streamId)
    elseif valueType == SoilConstants.NETWORK.VALUE_TYPE.NUMBER then
        self.settingValue = streamReadInt32(streamId)
    else
        self.settingValue = streamReadString(streamId)
    end

    self:run(connection)
end

function SoilSettingSyncEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.settingName)

    if type(self.settingValue) == "boolean" then
        streamWriteUInt8(streamId, SoilConstants.NETWORK.VALUE_TYPE.BOOLEAN)
        streamWriteBool(streamId, self.settingValue)
    elseif type(self.settingValue) == "number" then
        streamWriteUInt8(streamId, SoilConstants.NETWORK.VALUE_TYPE.NUMBER)
        streamWriteInt32(streamId, self.settingValue)
    else
        streamWriteUInt8(streamId, SoilConstants.NETWORK.VALUE_TYPE.STRING)
        streamWriteString(streamId, tostring(self.settingValue))
    end
end

function SoilSettingSyncEvent:run(connection)
    -- CLIENT ONLY: Receive setting update from server
    if g_client == nil then return end

    -- Local-only settings are never synced from server; keep each player's own value
    local def = SettingsSchema and SettingsSchema.byId and SettingsSchema.byId[self.settingName]
    if def and def.localOnly then return end

    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local oldValue = g_SoilFertilityManager.settings[self.settingName]
        g_SoilFertilityManager.settings[self.settingName] = self.settingValue

        SoilLogger.info("Client: Setting '%s' synced from %s to %s",
            self.settingName, tostring(oldValue), tostring(self.settingValue))

        -- A synced difficulty change must force the soften toggles on the client too, so
        -- it matches the server (which enforced in save() but only broadcasts the changed
        -- setting). Deterministic, so no extra sync traffic is needed. Cheap on any sync.
        if self.settingName == "difficulty"
            and g_SoilFertilityManager.settings.enforceBypassLock then
            g_SoilFertilityManager.settings:enforceBypassLock()
        end

        -- Refresh UI if open
        if g_SoilFertilityManager.settingsUI then
            g_SoilFertilityManager.settingsUI:refreshUI()
        end
    end
end

-- ========================================
-- FULL SYNC REQUEST (Client -> Server)
-- ========================================
SoilRequestFullSyncEvent = {}
SoilRequestFullSyncEvent_mt = Class(SoilRequestFullSyncEvent, Event)

InitEventClass(SoilRequestFullSyncEvent, "SoilRequestFullSyncEvent")

function SoilRequestFullSyncEvent.emptyNew()
    return Event.new(SoilRequestFullSyncEvent_mt)
end

function SoilRequestFullSyncEvent.new()
    return SoilRequestFullSyncEvent.emptyNew()
end

function SoilRequestFullSyncEvent:readStream(streamId, connection)
    self:run(connection)
end

function SoilRequestFullSyncEvent:writeStream(streamId, connection)
    -- No data needed
end

function SoilRequestFullSyncEvent:run(connection)
    -- SERVER ONLY: Send settings immediately, then stream field data in small
    -- batches so the main thread is never blocked for large maps (issue #212).
    if g_server == nil or not connection then return end
    if not g_SoilFertilityManager or not g_SoilFertilityManager.settings then return end

    local soilSystem = g_SoilFertilityManager.soilSystem
    local fieldData  = soilSystem and soilSystem.fieldData or {}

    -- Count fields
    local fieldCount = 0
    for _ in pairs(fieldData) do fieldCount = fieldCount + 1 end

    if soilSystem and soilSystem.fieldsScanPending then
        SoilLogger.warning("Server: Sync requested but field scan still pending (%d fields ready) - client will retry", fieldCount)
    else
        SoilLogger.info("Server: Sending full sync to client (%d fields)", fieldCount)
    end

    -- Step 1: send settings + empty fields immediately so the client
    -- unblocks and stops the retry timer right away.
    connection:sendEvent(SoilFullSyncEvent.new(g_SoilFertilityManager.settings, {}))

    -- Step 2: nothing to batch - we're done.
    if fieldCount == 0 then return end

    -- Step 3: build a sorted id list for deterministic batching.
    local fieldIds = {}
    for id in pairs(fieldData) do fieldIds[#fieldIds + 1] = id end
    table.sort(fieldIds)

    local batchSize    = SoilConstants.NETWORK.FULL_SYNC_BATCH_SIZE
    local batchDelay   = SoilConstants.NETWORK.FULL_SYNC_BATCH_DELAY
    local totalBatches = math.ceil(#fieldIds / batchSize)

    -- Step 4: Choose sync strategy based on server type.
    --
    -- Dedicated servers (g_dedicatedServer ~= nil) use a different connection
    -- lifecycle: the connection object captured in a closure is NOT guaranteed
    -- to remain valid across update ticks, causing the deferred batchDispatcher
    -- to crash with "attempt to call missing method" errors (issue #228).
    --
    -- Fix: on dedicated servers send all batches synchronously in a tight loop
    -- right now, while the connection is guaranteed alive. The main-thread-block
    -- concern that motivated batching (issue #212) is less of a problem on dedi
    -- servers which run headless without a render frame budget to protect.
    --
    -- On listen servers (local host / singleplayer) the original addUpdateable
    -- approach is kept so the UI stays responsive during large syncs.

    local isDedicatedServer = (g_dedicatedServer ~= nil)

    if isDedicatedServer then
        -- Dedicated server path: send all batches immediately in a loop.
        SoilLogger.info("Server: Dedicated server detected - sending %d fields in synchronous batches", fieldCount)
        for batchIndex = 1, totalBatches do
            local startIdx = (batchIndex - 1) * batchSize + 1
            local endIdx   = math.min(batchIndex * batchSize, #fieldIds)
            local batch    = {}
            for i = startIdx, endIdx do
                local id = fieldIds[i]
                batch[id] = fieldData[id]
            end
            local isLast = (batchIndex == totalBatches)
            connection:sendEvent(SoilFieldBatchSyncEvent.new(batch, isLast))
            SoilLogger.debug("Server: Field batch %d/%d sent (%d fields)", batchIndex, totalBatches, endIdx - startIdx + 1)
        end
    elseif g_currentMission and g_currentMission.addUpdateable then
        -- Listen server / local host path: drip-feed batches via addUpdateable
        -- so the render thread is not blocked for large maps (issue #212).
        local batchDispatcher = {
            batchIndex   = 1,
            timer        = 0,
            batchSize    = batchSize,
            batchDelay   = batchDelay,
            totalBatches = totalBatches,
            fieldIds     = fieldIds,
            fieldData    = fieldData,
            connection   = connection,

            update = function(self, dt)
                -- Guard: connection may have dropped or all batches sent
                if not self.connection or self.batchIndex > self.totalBatches then
                    g_currentMission:removeUpdateable(self)
                    return
                end

                -- Throttle: wait batchDelay ms between sends
                self.timer = self.timer + dt
                if self.timer < self.batchDelay then return end
                self.timer = 0

                local startIdx = (self.batchIndex - 1) * self.batchSize + 1
                local endIdx   = math.min(self.batchIndex * self.batchSize, #self.fieldIds)
                local batch    = {}
                for i = startIdx, endIdx do
                    local id = self.fieldIds[i]
                    batch[id] = self.fieldData[id]
                end

                local isLast = (self.batchIndex == self.totalBatches)
                self.connection:sendEvent(SoilFieldBatchSyncEvent.new(batch, isLast))

                SoilLogger.debug("Server: Field batch %d/%d sent (%d fields)",
                    self.batchIndex, self.totalBatches, endIdx - startIdx + 1)

                self.batchIndex = self.batchIndex + 1

                if isLast then
                    g_currentMission:removeUpdateable(self)
                end
            end
        }
        g_currentMission:addUpdateable(batchDispatcher)
        SoilLogger.info("Server: Batch dispatcher registered (%d batches of %d fields)", totalBatches, batchSize)
    else
        -- Fallback for edge cases: send everything at once (old blocking behaviour)
        SoilLogger.warning("Server: addUpdateable unavailable - sending all %d fields synchronously", fieldCount)
        local allBatch = {}
        for _, id in ipairs(fieldIds) do
            allBatch[id] = fieldData[id]
        end
        connection:sendEvent(SoilFieldBatchSyncEvent.new(allBatch, true))
    end

    -- REFINED: stream the per-pixel value maps after the field data
    -- (own dispatcher, interleaves safely with the field batch dispatcher).
    if SoilNetworkEvents_SendValueMaps then
        SoilNetworkEvents_SendValueMaps(connection)
    end
end

-- ========================================
-- FULL SYNC RESPONSE (Server -> Client)
-- ========================================
SoilFullSyncEvent = {}
SoilFullSyncEvent_mt = Class(SoilFullSyncEvent, Event)

InitEventClass(SoilFullSyncEvent, "SoilFullSyncEvent")

function SoilFullSyncEvent.emptyNew()
    return Event.new(SoilFullSyncEvent_mt)
end

function SoilFullSyncEvent.new(settings, fieldData)
    local self = SoilFullSyncEvent.emptyNew()
    self.settings = settings
    self.fieldData = fieldData or {}
    return self
end

function SoilFullSyncEvent:readStream(streamId, connection)
    self.settings = {}

    -- Read all non-local settings in schema order (matches writeStream iteration)
    for _, def in ipairs(SettingsSchema.definitions) do
        if not def.localOnly then
            if def.type == "boolean" then
                self.settings[def.id] = streamReadBool(streamId)
            elseif def.type == "number" then
                self.settings[def.id] = streamReadInt32(streamId)
            end
        end
    end

    -- Read field data
    self.fieldData = {}
    local fieldCount = streamReadInt32(streamId)
    local corruptionDetected = false

    for i = 1, fieldCount do
        local fieldId = streamReadInt32(streamId)
        local fieldArea = streamReadFloat32(streamId)
        local nitrogen = streamReadFloat32(streamId)
        local phosphorus = streamReadFloat32(streamId)
        local potassium = streamReadFloat32(streamId)
        local organicMatter = streamReadFloat32(streamId)
        local pH = streamReadFloat32(streamId)
        local lastCrop = streamReadString(streamId)
        local lastCrop2 = streamReadString(streamId)
        local lastCrop3 = streamReadString(streamId)
        local rotationBonusDaysLeft = streamReadInt32(streamId)
        local lastHarvest = streamReadInt32(streamId)
        local fertilizerApplied = streamReadFloat32(streamId)
        local weedPressure = streamReadFloat32(streamId)
        local herbDays = streamReadInt32(streamId)
        local pestPressure = streamReadFloat32(streamId)
        local pestDays = streamReadInt32(streamId)
        local diseasePressure = streamReadFloat32(streamId)
        local diseaseDays = streamReadInt32(streamId)
        local dryDays = streamReadInt32(streamId)
        local burnDays = streamReadInt32(streamId)
        local coverageFrac = streamReadFloat32(streamId)
        local compaction = streamReadFloat32(streamId)

        -- Read nutrient buffer (V1.7)
        local buffer = {}
        local bufferCount = streamReadInt32(streamId)
        for j = 1, bufferCount do
            local ftIdx = streamReadInt32(streamId)
            local amount = streamReadFloat32(streamId)
            buffer[ftIdx] = amount
        end

        -- Named active disease (appended last by writeStream)
        local activeDisease = streamReadString(streamId)
        if activeDisease == "" then activeDisease = nil end
        local diseaseDiscovered = streamReadBool(streamId)

        -- Organic certification (consume unconditionally to keep stream aligned)
        local orgState  = streamReadInt32(streamId)
        local orgStart  = streamReadInt32(streamId)
        local orgCert   = streamReadInt32(streamId)
        local orgBreach = streamReadInt32(streamId)
        -- CD-11 bands (consume unconditionally to keep the stream aligned)
        local resBands  = ResistanceBands.readStream(streamId)

        -- Validate and sanitize field data
        local function validateNumber(value, min, max, default, name)
            if type(value) ~= "number" or value ~= value then  -- Check for NaN
                SoilLogger.warning("Corrupt MP data: Field %d %s is invalid (NaN) - using default %s", fieldId, name, tostring(default))
                corruptionDetected = true
                return default
            end
            if value < min or value > max then
                SoilLogger.warning("Corrupt MP data: Field %d %s out of range (%s) - clamping to %s-%s", fieldId, name, tostring(value), tostring(min), tostring(max))
                corruptionDetected = true
                return math.max(min, math.min(max, value))
            end
            return value
        end

        -- Sanitize all numeric values
        nitrogen = validateNumber(nitrogen, SoilConstants.NUTRIENT_LIMITS.MIN, SoilConstants.NUTRIENT_LIMITS.MAX, 50, "nitrogen")
        phosphorus = validateNumber(phosphorus, SoilConstants.NUTRIENT_LIMITS.MIN, SoilConstants.NUTRIENT_LIMITS.MAX, 40, "phosphorus")
        potassium = validateNumber(potassium, SoilConstants.NUTRIENT_LIMITS.MIN, SoilConstants.NUTRIENT_LIMITS.MAX, 45, "potassium")
        organicMatter = validateNumber(organicMatter, SoilConstants.NUTRIENT_LIMITS.MIN, SoilConstants.NUTRIENT_LIMITS.ORGANIC_MATTER_MAX, 3.5, "organicMatter")
        pH = validateNumber(pH, SoilConstants.NUTRIENT_LIMITS.PH_MIN, SoilConstants.NUTRIENT_LIMITS.PH_MAX, SoilConstants.FIELD_DEFAULTS.pH, "pH")
        lastHarvest = validateNumber(lastHarvest, 0, 999999, 0, "lastHarvest")
        fertilizerApplied = validateNumber(fertilizerApplied, 0, 1000, 0, "fertilizerApplied")

        -- Validate fieldId
        if type(fieldId) ~= "number" or fieldId < 0 then
            SoilLogger.warning("Corrupt MP data: Invalid fieldId (%s) - skipping field", tostring(fieldId))
            corruptionDetected = true
        else
            self.fieldData[fieldId] = {
                fieldArea = math.max(0.01, fieldArea or 1.0),
                nitrogen = nitrogen,
                phosphorus = phosphorus,
                potassium = potassium,
                organicMatter = organicMatter,
                pH = pH,
                lastCrop = lastCrop,
                lastCrop2 = lastCrop2,
                lastCrop3 = lastCrop3,
                rotationBonusDaysLeft = rotationBonusDaysLeft,
                lastHarvest = lastHarvest,
                fertilizerApplied = fertilizerApplied,
                weedPressure = weedPressure,
                herbicideDaysLeft = herbDays,
                pestPressure = pestPressure,
                insecticideDaysLeft = pestDays,
                diseasePressure = diseasePressure,
                fungicideDaysLeft = diseaseDays,
                activeDisease = activeDisease,
                activeDiseaseSeverity = (activeDisease and SoilDiseaseSystem) and SoilDiseaseSystem.yieldSeverity(activeDisease) or 1.0,
                diseaseDiscovered = diseaseDiscovered or false,
                dryDayCount = dryDays,
                burnDaysLeft = burnDays,
                coverageFraction = math.max(0, math.min(1, coverageFrac or 0)),
                compaction = math.max(0, math.min(100, compaction or 0)),
                nutrientBuffer = buffer,
                initialized = true
            }
            -- Clear empty strings
            if self.fieldData[fieldId].lastCrop == "" then
                self.fieldData[fieldId].lastCrop = nil
            end
            if self.fieldData[fieldId].lastCrop2 == "" then
                self.fieldData[fieldId].lastCrop2 = nil
            end
            if self.fieldData[fieldId].lastCrop3 == "" then
                self.fieldData[fieldId].lastCrop3 = nil
            end
            OrganicCertification.applyFieldOrganic(self.fieldData[fieldId], orgState, orgStart, orgCert, orgBreach)
            ResistanceBands.applyFieldBands(self.fieldData[fieldId], resBands)
        end
    end

    -- Notify user if corruption was detected
    if corruptionDetected and g_currentMission and g_currentMission.hud then
        g_currentMission.hud:showBlinkingWarning(g_i18n:getText("sf_notify_sync_error"), 6000)
    end

    self:run(connection)
end

function SoilFullSyncEvent:writeStream(streamId, connection)
    -- Write all non-local settings in schema order (matches readStream iteration)
    for _, def in ipairs(SettingsSchema.definitions) do
        if not def.localOnly then
            if def.type == "boolean" then
                streamWriteBool(streamId, self.settings[def.id] == true)
            elseif def.type == "number" then
                streamWriteInt32(streamId, self.settings[def.id] or def.default)
            end
        end
    end

    -- Write field data
    local fieldCount = 0
    for _ in pairs(self.fieldData) do
        fieldCount = fieldCount + 1
    end
    streamWriteInt32(streamId, fieldCount)

    for fieldId, field in pairs(self.fieldData) do
        streamWriteInt32(streamId, fieldId)
        streamWriteFloat32(streamId, field.fieldArea or 1.0)
        streamWriteFloat32(streamId, field.nitrogen or SoilConstants.FIELD_DEFAULTS.nitrogen)
        streamWriteFloat32(streamId, field.phosphorus or SoilConstants.FIELD_DEFAULTS.phosphorus)
        streamWriteFloat32(streamId, field.potassium or SoilConstants.FIELD_DEFAULTS.potassium)
        streamWriteFloat32(streamId, field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter)
        streamWriteFloat32(streamId, field.pH or SoilConstants.FIELD_DEFAULTS.pH)
        streamWriteString(streamId, field.lastCrop or "")
        streamWriteString(streamId, field.lastCrop2 or "")
        streamWriteString(streamId, field.lastCrop3 or "")
        streamWriteInt32(streamId, field.rotationBonusDaysLeft or 0)
        streamWriteInt32(streamId, field.lastHarvest or 0)
        streamWriteFloat32(streamId, field.fertilizerApplied or 0)
        streamWriteFloat32(streamId, field.weedPressure or 0)
        streamWriteInt32(streamId, field.herbicideDaysLeft or 0)
        streamWriteFloat32(streamId, field.pestPressure or 0)
        streamWriteInt32(streamId, field.insecticideDaysLeft or 0)
        streamWriteFloat32(streamId, field.diseasePressure or 0)
        streamWriteInt32(streamId, field.fungicideDaysLeft or 0)
        streamWriteInt32(streamId, field.dryDayCount or 0)
        streamWriteInt32(streamId, field.burnDaysLeft or 0)
        streamWriteFloat32(streamId, field.coverageFraction or 0)
        streamWriteFloat32(streamId, field.compaction or 0)

        -- Write nutrient buffer (V1.7)
        local buffer = field.nutrientBuffer or {}
        local bCount = 0
        for _ in pairs(buffer) do bCount = bCount + 1 end
        streamWriteInt32(streamId, bCount)
        for ftIdx, amount in pairs(buffer) do
            streamWriteInt32(streamId, ftIdx)
            streamWriteFloat32(streamId, amount)
        end

        -- Named active disease (appended last to keep older alignment intact)
        streamWriteString(streamId, field.activeDisease or "")
        streamWriteBool(streamId, field.diseaseDiscovered or false)

        -- Organic certification (state enum + startDay + certifiedDay + breaches)
        local orgState, orgStart, orgCert, orgBreach = OrganicCertification.encodeFieldOrganic(field)
        streamWriteInt32(streamId, orgState)
        streamWriteInt32(streamId, orgStart)
        streamWriteInt32(streamId, orgCert)
        streamWriteInt32(streamId, orgBreach)

        -- CD-11: per-mode resistance bands (server-computed; never a raw score).
        ResistanceBands.writeStream(streamId, field)
    end
end

function SoilFullSyncEvent:run(connection)
    -- CLIENT ONLY: Receive settings from server.
    -- Field data is no longer bundled here; it arrives via SoilFieldBatchSyncEvent
    -- packets sent immediately after this one (issue #212 chunked-sync fix).
    if not g_client or not g_SoilFertilityManager then return end

    SoilLogger.info("Client: Received full sync header from server (settings + %d legacy fields)", self:getFieldCount())

    -- Apply all non-local settings from schema (auto-covers any new settings)
    local settings = g_SoilFertilityManager.settings
    for _, def in ipairs(SettingsSchema.definitions) do
        if not def.localOnly then
            settings[def.id] = self.settings[def.id]
        end
    end

    -- Legacy path: if the server sent field data inline (old server version),
    -- apply it directly so we stay backwards-compatible.
    local legacyCount = self:getFieldCount()
    if legacyCount > 0 and g_SoilFertilityManager.soilSystem then
        g_SoilFertilityManager.soilSystem.fieldData = self.fieldData
        SoilLogger.info("Client: Applied %d legacy inline fields", legacyCount)
    end

    -- Mark sync as received (stops retry timer).
    -- Field batches are additive; the retry guard is satisfied by the header.
    SoilNetworkEvents_OnFullSyncReceived()

    -- Refresh UI if open
    if g_SoilFertilityManager.settingsUI then
        g_SoilFertilityManager.settingsUI:refreshUI()
    end

    local diffNames = { "Simple", "Realistic", "Hardcore" }
    local diffName  = diffNames[settings.difficulty] or "Unknown"
    SoilLogger.info("Client: Settings synced - Enabled: %s, Difficulty: %s",
        tostring(settings.enabled), diffName)
end

function SoilFullSyncEvent:getFieldCount()
    local count = 0
    for _ in pairs(self.fieldData) do
        count = count + 1
    end
    return count
end

-- ========================================
-- FIELD BATCH SYNC EVENT (Server -> Client)
-- ========================================
-- Part of the chunked full-sync flow introduced in issue #212.
-- The server sends one of these per batch of fields after the initial
-- SoilFullSyncEvent (which carries settings + signals sync start).
-- isLast=true on the final batch so the client can finalise.
SoilFieldBatchSyncEvent = {}
SoilFieldBatchSyncEvent_mt = Class(SoilFieldBatchSyncEvent, Event)

InitEventClass(SoilFieldBatchSyncEvent, "SoilFieldBatchSyncEvent")

function SoilFieldBatchSyncEvent.emptyNew()
    return Event.new(SoilFieldBatchSyncEvent_mt)
end

function SoilFieldBatchSyncEvent.new(batchFields, isLast)
    local self = SoilFieldBatchSyncEvent.emptyNew()
    self.batchFields = batchFields or {}
    self.isLast      = isLast or false
    return self
end

function SoilFieldBatchSyncEvent:writeStream(streamId, connection)
    -- Count fields in this batch
    local count = 0
    for _ in pairs(self.batchFields) do count = count + 1 end

    streamWriteInt32(streamId, count)
    streamWriteBool(streamId, self.isLast)

    for fieldId, field in pairs(self.batchFields) do
        streamWriteInt32(streamId,   fieldId)
        streamWriteFloat32(streamId, field.fieldArea          or 1.0)
        streamWriteFloat32(streamId, field.nitrogen           or SoilConstants.FIELD_DEFAULTS.nitrogen)
        streamWriteFloat32(streamId, field.phosphorus         or SoilConstants.FIELD_DEFAULTS.phosphorus)
        streamWriteFloat32(streamId, field.potassium          or SoilConstants.FIELD_DEFAULTS.potassium)
        streamWriteFloat32(streamId, field.organicMatter      or SoilConstants.FIELD_DEFAULTS.organicMatter)
        streamWriteFloat32(streamId, field.pH                 or SoilConstants.FIELD_DEFAULTS.pH)
        streamWriteString(streamId,  field.lastCrop           or "")
        streamWriteString(streamId,  field.lastCrop2          or "")
        streamWriteString(streamId,  field.lastCrop3          or "")
        streamWriteInt32(streamId,   field.rotationBonusDaysLeft or 0)
        streamWriteInt32(streamId,   field.lastHarvest        or 0)
        streamWriteFloat32(streamId, field.fertilizerApplied  or 0)
        streamWriteFloat32(streamId, field.weedPressure       or 0)
        streamWriteInt32(streamId,   field.herbicideDaysLeft  or 0)
        streamWriteFloat32(streamId, field.pestPressure       or 0)
        streamWriteInt32(streamId,   field.insecticideDaysLeft or 0)
        streamWriteFloat32(streamId, field.diseasePressure    or 0)
        streamWriteInt32(streamId,   field.fungicideDaysLeft  or 0)
        streamWriteInt32(streamId,   field.dryDayCount        or 0)
        streamWriteInt32(streamId,   field.burnDaysLeft       or 0)
        streamWriteFloat32(streamId, field.coverageFraction   or 0)
        streamWriteFloat32(streamId, field.compaction         or 0)

        -- Nutrient buffer (V1.7)
        local buffer = field.nutrientBuffer or {}
        local bCount = 0
        for _ in pairs(buffer) do bCount = bCount + 1 end
        streamWriteInt32(streamId, bCount)
        for ftIdx, amount in pairs(buffer) do
            streamWriteInt32(streamId,   ftIdx)
            streamWriteFloat32(streamId, amount)
        end

        -- Zone cell data: per-cell soil state for the PDA cell-report overlay.
        -- Capped at 500 cells per field to prevent packet overflow on large fields.
        local zd = field.zoneData or {}
        local ZONE_SYNC_MAX = 500

        -- Pass 1: count without building an intermediate table
        local zdCount = 0
        for _ in pairs(zd) do
            zdCount = zdCount + 1
            if zdCount >= ZONE_SYNC_MAX then break end
        end
        streamWriteInt32(streamId, zdCount)

        -- Pass 2: serialize directly into the stream
        local sent = 0
        for cellKey, cell in pairs(zd) do
            if sent >= ZONE_SYNC_MAX then break end
            sent = sent + 1
            streamWriteInt32(streamId,   tonumber(cellKey) or 0)
            streamWriteFloat32(streamId, cell.N  or 0)
            streamWriteFloat32(streamId, cell.P  or 0)
            streamWriteFloat32(streamId, cell.K  or 0)
            streamWriteFloat32(streamId, cell.pH or 6.0)
            streamWriteFloat32(streamId, cell.OM or 0)
            streamWriteFloat32(streamId, cell.weedPressure    or 0)
            streamWriteFloat32(streamId, cell.pestPressure    or 0)
            streamWriteFloat32(streamId, cell.diseasePressure or 0)
            streamWriteFloat32(streamId, cell.compaction      or 0)
        end

        -- Named active disease (appended last to keep zone alignment intact)
        streamWriteString(streamId, field.activeDisease or "")
        streamWriteBool(streamId, field.diseaseDiscovered or false)

        -- Organic certification (state enum + startDay + certifiedDay + breaches)
        local orgState, orgStart, orgCert, orgBreach = OrganicCertification.encodeFieldOrganic(field)
        streamWriteInt32(streamId, orgState)
        streamWriteInt32(streamId, orgStart)
        streamWriteInt32(streamId, orgCert)
        streamWriteInt32(streamId, orgBreach)

        -- CD-11: per-mode resistance bands (server-computed; never a raw score).
        ResistanceBands.writeStream(streamId, field)
    end
end

function SoilFieldBatchSyncEvent:readStream(streamId, connection)
    local count  = streamReadInt32(streamId)
    self.isLast  = streamReadBool(streamId)
    self.batchFields = {}

    for _ = 1, count do
        local fieldId        = streamReadInt32(streamId)
        local fieldArea      = streamReadFloat32(streamId)
        local nitrogen       = streamReadFloat32(streamId)
        local phosphorus     = streamReadFloat32(streamId)
        local potassium      = streamReadFloat32(streamId)
        local organicMatter  = streamReadFloat32(streamId)
        local pH             = streamReadFloat32(streamId)
        local lastCrop       = streamReadString(streamId)
        local lastCrop2      = streamReadString(streamId)
        local lastCrop3      = streamReadString(streamId)
        local rotBonus       = streamReadInt32(streamId)
        local lastHarvest    = streamReadInt32(streamId)
        local fertApplied    = streamReadFloat32(streamId)
        local weedP          = streamReadFloat32(streamId)
        local herbDays       = streamReadInt32(streamId)
        local pestP          = streamReadFloat32(streamId)
        local pestDays       = streamReadInt32(streamId)
        local diseaseP       = streamReadFloat32(streamId)
        local diseaseDays    = streamReadInt32(streamId)
        local dryDays        = streamReadInt32(streamId)
        local burnDays       = streamReadInt32(streamId)
        local coverageFrac   = streamReadFloat32(streamId)
        local compaction     = streamReadFloat32(streamId)

        local buffer = {}
        local bCount = streamReadInt32(streamId)
        for _ = 1, bCount do
            local ftIdx  = streamReadInt32(streamId)
            local amount = streamReadFloat32(streamId)
            buffer[ftIdx] = amount
        end

        -- Zone cell data (added v2.1.6)
        local zd = {}
        local zdCount = streamReadInt32(streamId)
        for _ = 1, zdCount do
            local keyInt = streamReadInt32(streamId)
            local zN  = streamReadFloat32(streamId)
            local zP  = streamReadFloat32(streamId)
            local zK  = streamReadFloat32(streamId)
            local zpH = streamReadFloat32(streamId)
            local zOM = streamReadFloat32(streamId)
            zd[tostring(keyInt)] = {
                N               = math.max(0, math.min(100, zN)),
                P               = math.max(0, math.min(100, zP)),
                K               = math.max(0, math.min(100, zK)),
                pH              = math.max(5.0, math.min(8.5, zpH)),
                OM              = math.max(0, math.min(10, zOM)),
                weedPressure    = math.max(0, math.min(100, streamReadFloat32(streamId))),
                pestPressure    = math.max(0, math.min(100, streamReadFloat32(streamId))),
                diseasePressure = math.max(0, math.min(100, streamReadFloat32(streamId))),
                compaction      = math.max(0, math.min(100, streamReadFloat32(streamId))),
            }
        end

        -- Named active disease (consume unconditionally to keep stream aligned)
        local activeDisease = streamReadString(streamId)
        if activeDisease == "" then activeDisease = nil end
        local diseaseDiscovered = streamReadBool(streamId)

        -- Organic certification (consume unconditionally to keep stream aligned)
        local orgState  = streamReadInt32(streamId)
        local orgStart  = streamReadInt32(streamId)
        local orgCert   = streamReadInt32(streamId)
        local orgBreach = streamReadInt32(streamId)
        -- CD-11 bands (consume unconditionally to keep the stream aligned)
        local resBands  = ResistanceBands.readStream(streamId)

        if type(fieldId) == "number" and fieldId >= 0 then
            self.batchFields[fieldId] = {
                fieldArea             = math.max(0.01, fieldArea or 1.0),
                nitrogen              = math.max(SoilConstants.NUTRIENT_LIMITS.MIN, math.min(SoilConstants.NUTRIENT_LIMITS.MAX, nitrogen)),
                phosphorus            = math.max(SoilConstants.NUTRIENT_LIMITS.MIN, math.min(SoilConstants.NUTRIENT_LIMITS.MAX, phosphorus)),
                potassium             = math.max(SoilConstants.NUTRIENT_LIMITS.MIN, math.min(SoilConstants.NUTRIENT_LIMITS.MAX, potassium)),
                organicMatter         = math.max(SoilConstants.NUTRIENT_LIMITS.MIN, math.min(SoilConstants.NUTRIENT_LIMITS.ORGANIC_MATTER_MAX, organicMatter)),
                pH                    = math.max(SoilConstants.NUTRIENT_LIMITS.PH_MIN, math.min(SoilConstants.NUTRIENT_LIMITS.PH_MAX, pH)),
                lastCrop              = lastCrop ~= "" and lastCrop or nil,
                lastCrop2             = lastCrop2 ~= "" and lastCrop2 or nil,
                lastCrop3             = lastCrop3 ~= "" and lastCrop3 or nil,
                rotationBonusDaysLeft = math.max(0, rotBonus),
                lastHarvest           = math.max(0, lastHarvest),
                fertilizerApplied     = math.max(0, fertApplied),
                weedPressure          = math.max(0, math.min(100, weedP)),
                herbicideDaysLeft     = math.max(0, herbDays),
                pestPressure          = math.max(0, math.min(100, pestP)),
                insecticideDaysLeft   = math.max(0, pestDays),
                diseasePressure       = math.max(0, math.min(100, diseaseP)),
                fungicideDaysLeft     = math.max(0, diseaseDays),
                activeDisease         = activeDisease,
                activeDiseaseSeverity = (activeDisease and SoilDiseaseSystem) and SoilDiseaseSystem.yieldSeverity(activeDisease) or 1.0,
                diseaseDiscovered     = diseaseDiscovered or false,
                dryDayCount           = math.max(0, dryDays),
                burnDaysLeft          = math.max(0, burnDays),
                nutrientBuffer        = buffer,
                coverageFraction      = math.max(0, math.min(1, coverageFrac or 0)),
                coveredCells          = {},
                coveredCellCount      = 0,
                compaction            = math.max(0, math.min(100, compaction or 0)),
                zoneData              = zd,
                initialized           = true,
            }
            OrganicCertification.applyFieldOrganic(self.batchFields[fieldId], orgState, orgStart, orgCert, orgBreach)
            ResistanceBands.applyFieldBands(self.batchFields[fieldId], resBands)
        end
    end

    self:run(connection)
end

function SoilFieldBatchSyncEvent:run(connection)
    -- CLIENT ONLY: merge this batch into the local field table
    if g_client == nil then return end
    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then return end

    local soilSystem = g_SoilFertilityManager.soilSystem
    for fieldId, field in pairs(self.batchFields) do
        soilSystem.fieldData[fieldId] = field
    end

    SoilLogger.info("Client: Received field batch (%d fields, last=%s)", self:getBatchCount(), tostring(self.isLast))

    if self.isLast then
        -- Count total now that all batches are in
        local total = 0
        for _ in pairs(soilSystem.fieldData) do total = total + 1 end
        SoilLogger.info("Client: Full field sync complete (%d total fields)", total)

        -- Rebuild activeFieldIds from current farmland ownership state.
        -- scanFields() may have run before the server's ownership data arrived on
        -- the client, leaving activeFieldIds empty and the overlay blank. Now that
        -- fieldData is fully populated we re-check ownership and fill the set.
        if g_farmlandManager then
            for farmlandId in pairs(soilSystem.fieldData) do
                local owner = g_farmlandManager:getFarmlandOwner(farmlandId)
                if owner and owner > 0 then
                    soilSystem:_addToActiveSet(farmlandId)
                end
            end
            SoilLogger.info("Client: activeFieldIds rebuilt (%d owned fields)", (function()
                local n = 0; for _ in pairs(soilSystem.activeFieldIds) do n = n + 1 end; return n
            end)())
        end

        -- Force overlay to resample now that activeFieldIds is correct
        if g_SoilFertilityManager.soilMapOverlay then
            g_SoilFertilityManager.soilMapOverlay:requestRefresh()
        end

        -- Seed GRLE layers from the just-received fieldData so the DMV minimap
        -- heatmap is correct on join. On pure dedi-server clients the startup seed
        -- in SoilFertilityManager ran before fieldData arrived, so the GRLE was
        -- blank. Skipped on listen-server hosts where the sprayer hook owns GRLE.
        if g_server == nil then
            local layerSys = soilSystem.layerSystem
            if layerSys and layerSys.available then
                for fieldId, field in pairs(soilSystem.fieldData) do
                    local fsField = g_fieldManager and g_fieldManager.fields
                                 and g_fieldManager.fields[fieldId]
                    layerSys:writeFieldToLayers(fieldId, field, fsField)
                end
                local sfm = g_SoilFertilityManager
                if sfm and sfm.soilMinimapLayer then sfm.soilMinimapLayer:markDirty() end
                SoilLogger.info("Client: GRLE layers seeded from batch sync (%d fields)", total)
            end
        end

        -- Refresh any open UI panels
        if g_SoilFertilityManager.settingsUI then
            g_SoilFertilityManager.settingsUI:refreshUI()
        end
    end
end

function SoilFieldBatchSyncEvent:getBatchCount()
    local n = 0
    for _ in pairs(self.batchFields) do n = n + 1 end
    return n
end

-- ========================================
-- FIELD UPDATE DISPATCH (choke point)
-- ========================================
-- Single entry point for every ongoing per-field soil delta broadcast. When
-- FS25_NetworkSync is installed the delta is folded into its 1Hz whole-field-map
-- batch (one registered module) via markDirty; when it is absent this is the
-- original direct SoilFieldUpdateEvent broadcast. Server-guarded either way, so
-- the sim sites can call it unconditionally inside their multiplayer guards.
function SoilNetworkEvents_BroadcastFieldUpdate(fieldId, field)
    if SoilNetworkSyncBridge ~= nil and SoilNetworkSyncBridge.active then
        SoilNetworkSyncBridge.markFieldDirty()
        return
    end
    if g_server ~= nil and SoilFieldUpdateEvent ~= nil and field ~= nil then
        g_server:broadcastEvent(SoilFieldUpdateEvent.new(fieldId, field))
    end
end

-- ========================================
-- FIELD UPDATE EVENT (Server -> Clients)
-- ========================================
-- Sent when soil data changes (harvest, fertilizer) for a single field
SoilFieldUpdateEvent = {}
SoilFieldUpdateEvent_mt = Class(SoilFieldUpdateEvent, Event)

InitEventClass(SoilFieldUpdateEvent, "SoilFieldUpdateEvent")

function SoilFieldUpdateEvent.emptyNew()
    return Event.new(SoilFieldUpdateEvent_mt)
end

function SoilFieldUpdateEvent.new(fieldId, fieldData)
    local self = SoilFieldUpdateEvent.emptyNew()
    self.fieldId = fieldId
    self.field = fieldData
    return self
end

function SoilFieldUpdateEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)

    -- Read values with clamping to valid ranges (NPCFavor pattern)
    local fieldArea = streamReadFloat32(streamId)
    local nitrogen = streamReadFloat32(streamId)
    local phosphorus = streamReadFloat32(streamId)
    local potassium = streamReadFloat32(streamId)
    local organicMatter = streamReadFloat32(streamId)
    local pH = streamReadFloat32(streamId)
    local lastCrop = streamReadString(streamId)
    local lastCrop2 = streamReadString(streamId)
    local lastCrop3 = streamReadString(streamId)
    local rotationBonusDaysLeft = streamReadInt32(streamId)
    local lastHarvest = streamReadInt32(streamId)
    local fertilizerApplied = streamReadFloat32(streamId)
    local weedPressure = streamReadFloat32(streamId)
    local herbDays = streamReadInt32(streamId)
    local pestPressure = streamReadFloat32(streamId)
    local pestDays = streamReadInt32(streamId)
    local diseasePressure = streamReadFloat32(streamId)
    local diseaseDays = streamReadInt32(streamId)
    local dryDays = streamReadInt32(streamId)
    local burnDays = streamReadInt32(streamId)
    local coverageFrac = streamReadFloat32(streamId)
    local compaction = streamReadFloat32(streamId)

    -- Read nutrient buffer (V1.7)
    local buffer = {}
    local bCount = streamReadInt32(streamId)
    for i = 1, bCount do
        local ftIdx = streamReadInt32(streamId)
        local amount = streamReadFloat32(streamId)
        buffer[ftIdx] = amount
    end

    -- Zone cell data (added v2.1.6)
    local zd = {}
    local zdCount = streamReadInt32(streamId)
    for _ = 1, zdCount do
        local keyInt = streamReadInt32(streamId)
        local zN  = streamReadFloat32(streamId)
        local zP  = streamReadFloat32(streamId)
        local zK  = streamReadFloat32(streamId)
        local zpH = streamReadFloat32(streamId)
        local zOM = streamReadFloat32(streamId)
        zd[tostring(keyInt)] = {
            N               = math.max(0, math.min(100, zN)),
            P               = math.max(0, math.min(100, zP)),
            K               = math.max(0, math.min(100, zK)),
            pH              = math.max(5.0, math.min(8.5, zpH)),
            OM              = math.max(0, math.min(10, zOM)),
            weedPressure    = math.max(0, math.min(100, streamReadFloat32(streamId))),
            pestPressure    = math.max(0, math.min(100, streamReadFloat32(streamId))),
            diseasePressure = math.max(0, math.min(100, streamReadFloat32(streamId))),
            compaction      = math.max(0, math.min(100, streamReadFloat32(streamId))),
        }
    end

    -- Named active disease (appended last by writeStream)
    local activeDisease = streamReadString(streamId)
    if activeDisease == "" then activeDisease = nil end
    local diseaseDiscovered = streamReadBool(streamId)

    -- Organic certification (matches writeStream order: after the disease pair)
    local orgState  = streamReadInt32(streamId)
    local orgStart  = streamReadInt32(streamId)
    local orgCert   = streamReadInt32(streamId)
    local orgBreach = streamReadInt32(streamId)
    local resBands  = ResistanceBands.readStream(streamId)

    -- Clamp all values to valid ranges
    self.field = {
        fieldArea = math.max(0.01, fieldArea or 1.0),
        nitrogen = math.max(SoilConstants.NUTRIENT_LIMITS.MIN,
                           math.min(SoilConstants.NUTRIENT_LIMITS.MAX, nitrogen)),
        phosphorus = math.max(SoilConstants.NUTRIENT_LIMITS.MIN,
                             math.min(SoilConstants.NUTRIENT_LIMITS.MAX, phosphorus)),
        potassium = math.max(SoilConstants.NUTRIENT_LIMITS.MIN,
                            math.min(SoilConstants.NUTRIENT_LIMITS.MAX, potassium)),
        organicMatter = math.max(SoilConstants.NUTRIENT_LIMITS.MIN,
                                math.min(SoilConstants.NUTRIENT_LIMITS.ORGANIC_MATTER_MAX, organicMatter)),
        pH = math.max(SoilConstants.NUTRIENT_LIMITS.PH_MIN,
                     math.min(SoilConstants.NUTRIENT_LIMITS.PH_MAX, pH)),
        lastCrop = lastCrop,
        lastCrop2 = lastCrop2,
        lastCrop3 = lastCrop3,
        rotationBonusDaysLeft = math.max(0, rotationBonusDaysLeft),
        lastHarvest = math.max(0, lastHarvest),
        fertilizerApplied = math.max(0, fertilizerApplied),
        weedPressure = math.max(0, math.min(100, weedPressure)),
        herbicideDaysLeft = math.max(0, herbDays),
        pestPressure = math.max(0, math.min(100, pestPressure)),
        insecticideDaysLeft = math.max(0, pestDays),
        diseasePressure = math.max(0, math.min(100, diseasePressure)),
        fungicideDaysLeft = math.max(0, diseaseDays),
        activeDisease = activeDisease,
        activeDiseaseSeverity = (activeDisease and SoilDiseaseSystem) and SoilDiseaseSystem.yieldSeverity(activeDisease) or 1.0,
        diseaseDiscovered = diseaseDiscovered or false,
        dryDayCount = math.max(0, dryDays),
        burnDaysLeft = math.max(0, burnDays),
        nutrientBuffer   = buffer,
        coverageFraction = math.max(0, math.min(1, coverageFrac or 0)),
        coveredCells     = {},
        coveredCellCount = 0,
        compaction       = math.max(0, math.min(100, compaction or 0)),
        zoneData         = zd,
        initialized      = true
    }

    -- Clear empty strings
    if self.field.lastCrop == "" then
        self.field.lastCrop = nil
    end
    if self.field.lastCrop2 == "" then
        self.field.lastCrop2 = nil
    end
    if self.field.lastCrop3 == "" then
        self.field.lastCrop3 = nil
    end

    -- Attach the synced organic state so run()'s field replace carries it.
    OrganicCertification.applyFieldOrganic(self.field, orgState, orgStart, orgCert, orgBreach)
    ResistanceBands.applyFieldBands(self.field, resBands)

    self:run(connection)
end

function SoilFieldUpdateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteFloat32(streamId, self.field.fieldArea or 1.0)
    streamWriteFloat32(streamId, self.field.nitrogen or SoilConstants.FIELD_DEFAULTS.nitrogen)
    streamWriteFloat32(streamId, self.field.phosphorus or SoilConstants.FIELD_DEFAULTS.phosphorus)
    streamWriteFloat32(streamId, self.field.potassium or SoilConstants.FIELD_DEFAULTS.potassium)
    streamWriteFloat32(streamId, self.field.organicMatter or SoilConstants.FIELD_DEFAULTS.organicMatter)
    streamWriteFloat32(streamId, self.field.pH or SoilConstants.FIELD_DEFAULTS.pH)
    streamWriteString(streamId, self.field.lastCrop or "")
    streamWriteString(streamId, self.field.lastCrop2 or "")
    streamWriteString(streamId, self.field.lastCrop3 or "")
    streamWriteInt32(streamId, self.field.rotationBonusDaysLeft or 0)
    streamWriteInt32(streamId, self.field.lastHarvest or 0)
    streamWriteFloat32(streamId, self.field.fertilizerApplied or 0)
    streamWriteFloat32(streamId, self.field.weedPressure or 0)
    streamWriteInt32(streamId, self.field.herbicideDaysLeft or 0)
    streamWriteFloat32(streamId, self.field.pestPressure or 0)
    streamWriteInt32(streamId, self.field.insecticideDaysLeft or 0)
    streamWriteFloat32(streamId, self.field.diseasePressure or 0)
    streamWriteInt32(streamId, self.field.fungicideDaysLeft or 0)
    streamWriteInt32(streamId, self.field.dryDayCount or 0)
    streamWriteInt32(streamId, self.field.burnDaysLeft or 0)
    streamWriteFloat32(streamId, self.field.coverageFraction or 0)
    streamWriteFloat32(streamId, self.field.compaction or 0)

    -- Write nutrient buffer (V1.7)
    local buffer = self.field.nutrientBuffer or {}
    local bCount = 0
    for _ in pairs(buffer) do bCount = bCount + 1 end
    streamWriteInt32(streamId, bCount)
    for ftIdx, amount in pairs(buffer) do
        streamWriteInt32(streamId, ftIdx)
        streamWriteFloat32(streamId, amount)
    end

    -- Zone cell data: send 0 cells in per-update broadcasts.
    -- All zone cells are already synced to the field aggregate after each apply, so
    -- sending them here is redundant - and on large fields with wide-boom spreaders
    -- the cell count can reach thousands, overflowing the FS25 packet size limit and
    -- crashing the dedicated server. Clients fall back to getLayerColor() (aggregate)
    -- for any cells not in their local zoneData, so the overlay is still correct.
    streamWriteInt32(streamId, 0)

    -- Named active disease (appended last)
    streamWriteString(streamId, self.field.activeDisease or "")
    streamWriteBool(streamId, self.field.diseaseDiscovered or false)

    -- Organic certification (state enum + startDay + certifiedDay + breaches).
    -- Sent on every field update so the routine broadcast carries the field's
    -- organic standing instead of wiping it on the client's replace.
    local orgState, orgStart, orgCert, orgBreach = OrganicCertification.encodeFieldOrganic(self.field)
    streamWriteInt32(streamId, orgState)
    streamWriteInt32(streamId, orgStart)
    streamWriteInt32(streamId, orgCert)
    streamWriteInt32(streamId, orgBreach)

    -- CD-11: per-mode resistance BANDS, for the same reason organic rides along above --
    -- run() replaces the client's field table wholesale, so a value that does not travel
    -- is a value that gets wiped. Server-computed; a raw score never goes on the wire.
    ResistanceBands.writeStream(streamId, self.field)
end

function SoilFieldUpdateEvent:run(connection)
    -- CLIENT ONLY: Apply server-authoritative field data
    if g_client == nil then return end

    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then
        local soilSys = g_SoilFertilityManager.soilSystem
        local newField = self.field

        -- Preserve the client's local zoneData and sync all existing cells to the
        -- new aggregate values. The broadcast no longer ships zone cells (packet
        -- overflow risk on wide-boom spreaders), so we reconstruct per-cell display
        -- from the field aggregate - same as what applyFertilizer does server-side.
        local existing = soilSys.fieldData[self.fieldId]
        if existing and existing.zoneData then
            newField.zoneData = existing.zoneData
            for _, cell in pairs(newField.zoneData) do
                cell.N  = newField.nitrogen
                cell.P  = newField.phosphorus
                cell.K  = newField.potassium
                cell.pH = newField.pH
                cell.OM = newField.organicMatter
                cell.weedPressure    = newField.weedPressure    or cell.weedPressure
                cell.pestPressure    = newField.pestPressure    or cell.pestPressure
                cell.diseasePressure = newField.diseasePressure or cell.diseasePressure
                cell.compaction      = newField.compaction      or cell.compaction
            end
        end

        soilSys.fieldData[self.fieldId] = newField

        -- On pure dedi-server clients the sprayer hook never runs locally, so the
        -- GRLE layers (which power the DMV minimap heatmap) are never written.
        -- Write the updated field now so the minimap stays in sync with the HUD.
        -- Skipped on listen-server hosts (g_server ~= nil) where the hook writes
        -- per-pixel data directly and writeFieldToLayers would smear the average.
        if g_server == nil then
            local layerSys = soilSys.layerSystem
            if layerSys and layerSys.available then
                local fsField = g_fieldManager and g_fieldManager.fields
                             and g_fieldManager.fields[self.fieldId]
                layerSys:writeFieldToLayers(self.fieldId, newField, fsField)
                local sfm = g_SoilFertilityManager
                if sfm and sfm.soilMinimapLayer then sfm.soilMinimapLayer:markDirty() end
            end
        end

        -- Refresh overlay so the map tile updates on the client without waiting for the timer
        local overlay = g_SoilFertilityManager.soilMapOverlay
        if overlay then overlay:requestRefresh() end

        if g_SoilFertilityManager.settings.debugMode then
            SoilLogger.debug("Client: Field %d synced from server (N=%.1f, P=%.1f, K=%.1f)",
                self.fieldId, newField.nitrogen, newField.phosphorus, newField.potassium)
        end
    end
end

-- ========================================
-- TREAT FIELD EVENT (Client -> Server)
-- ========================================
-- A client asks the server to apply a named fungicide to a field via the spray
-- menu. The server is authoritative: it validates the chemical, applies the
-- effectiveness/pressure/protection math, charges the requesting farm, and
-- broadcasts the resulting field state via SoilFieldUpdateEvent.
SoilTreatFieldEvent = {}
SoilTreatFieldEvent_mt = Class(SoilTreatFieldEvent, Event)

InitEventClass(SoilTreatFieldEvent, "SoilTreatFieldEvent")

function SoilTreatFieldEvent.emptyNew()
    return Event.new(SoilTreatFieldEvent_mt)
end

function SoilTreatFieldEvent.new(fieldId, chemId)
    local self = SoilTreatFieldEvent.emptyNew()
    self.fieldId = fieldId
    self.chemId  = chemId
    return self
end

function SoilTreatFieldEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)
    self.chemId  = streamReadString(streamId)
    self:run(connection)
end

function SoilTreatFieldEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId or 0)
    streamWriteString(streamId, self.chemId or "")
end

function SoilTreatFieldEvent:run(connection)
    -- SERVER ONLY: authoritative application.
    if g_server == nil then return end
    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then return end
    if not SoilConstants.FUNGICIDE_CATALOG[self.chemId] then
        SoilLogger.warning("Server: Rejected unknown fungicide '%s' from treat request", tostring(self.chemId))
        return
    end
    if SoilConstants.PHYSICAL_FUNGICIDES and SoilConstants.PHYSICAL_FUNGICIDES[self.chemId] then
        SoilLogger.warning("Server: Rejected physical fungicide '%s' from menu treat request (spray the tank instead)", tostring(self.chemId))
        return
    end

    -- Charge the requesting player's farm.
    local farmId = nil
    if connection and not connection:getIsServer() and g_currentMission and g_currentMission.userManager then
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if user then farmId = user.farmId end
    end

    g_SoilFertilityManager.soilSystem:applyNamedFungicide(self.fieldId, self.chemId, {
        charge = true,
        farmId = farmId,
    })
end

-- ==========================================================================
-- SoilOrganicOptEvent (client -> server): a client asks the server to opt a field
-- into or out of the organic transition. Organic state is server-authoritative
-- (single-writer): the server validates and calls optIn/optOut, and those methods
-- self-broadcast the resulting field state to every peer. Mirrors SoilTreatFieldEvent.
-- ==========================================================================
SoilOrganicOptEvent = {}
SoilOrganicOptEvent_mt = Class(SoilOrganicOptEvent, Event)

InitEventClass(SoilOrganicOptEvent, "SoilOrganicOptEvent")

function SoilOrganicOptEvent.emptyNew()
    return Event.new(SoilOrganicOptEvent_mt)
end

function SoilOrganicOptEvent.new(fieldId, doOptIn)
    local self = SoilOrganicOptEvent.emptyNew()
    self.fieldId = fieldId
    self.doOptIn = doOptIn and true or false
    return self
end

function SoilOrganicOptEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)
    self.doOptIn = streamReadBool(streamId)
    self:run(connection)
end

function SoilOrganicOptEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId or 0)
    streamWriteBool(streamId, self.doOptIn)
end

function SoilOrganicOptEvent:run(connection)
    -- SERVER ONLY: authoritative opt in/out. optIn/optOut self-broadcast the
    -- resulting field state, so every client converges without extra work here.
    if g_server == nil then return end
    if not g_SoilFertilityManager or not g_SoilFertilityManager.organic then return end
    local organic = g_SoilFertilityManager.organic
    if self.doOptIn then
        organic:optIn(self.fieldId)
    else
        organic:optOut(self.fieldId)
    end
end

-- ==========================================================================
-- SoilScoutFieldEvent (client -> server): a client scouted a field. The server
-- marks the disease discovered (authoritative, farm-wide) and re-broadcasts the
-- field so every client's discovery gate opens. Discovery is monotonic, so no
-- validation beyond a known field is needed.
-- ==========================================================================
SoilScoutFieldEvent = {}
SoilScoutFieldEvent_mt = Class(SoilScoutFieldEvent, Event)

InitEventClass(SoilScoutFieldEvent, "SoilScoutFieldEvent")

function SoilScoutFieldEvent.emptyNew()
    return Event.new(SoilScoutFieldEvent_mt)
end

function SoilScoutFieldEvent.new(fieldId)
    local self = SoilScoutFieldEvent.emptyNew()
    self.fieldId = fieldId
    return self
end

function SoilScoutFieldEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)
    self:run(connection)
end

function SoilScoutFieldEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId or 0)
end

function SoilScoutFieldEvent:run(connection)
    -- SERVER ONLY: authoritative reveal (scoutField broadcasts the field update).
    if g_server == nil then return end
    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then return end
    g_SoilFertilityManager.soilSystem:scoutField(self.fieldId)
end

-- ========================================
-- HELPER FUNCTIONS
-- ========================================

-- Check if current player is admin
function SoilNetworkEvents_IsPlayerAdmin()
    return SoilUtils.isPlayerAdmin()
end

-- Send setting change request
function SoilNetworkEvents_RequestSettingChange(settingName, value)
    -- Local-only settings are applied on this client only - never sent to server
    local def = SettingsSchema and SettingsSchema.byId and SettingsSchema.byId[settingName]
    if def and def.localOnly then
        if g_SoilFertilityManager and g_SoilFertilityManager.settings then
            g_SoilFertilityManager.settings[settingName] = value
            g_SoilFertilityManager.settings:save()
        end
        return
    end

    if g_client then
        -- Client: send request to server
        g_client:getServerConnection():sendEvent(
            SoilSettingChangeEvent.new(settingName, value)
        )
        SoilLogger.info("Client: Requesting setting change '%s' = %s", settingName, tostring(value))
    else
        -- Server/Singleplayer: apply directly
        if g_SoilFertilityManager and g_SoilFertilityManager.settings then
            g_SoilFertilityManager.settings[settingName] = value
            g_SoilFertilityManager.settings:save()

            SoilLogger.info("Server: Setting '%s' changed to %s", settingName, tostring(value))

            -- Broadcast if multiplayer server
            if g_server then
                g_server:broadcastEvent(
                    SoilSettingSyncEvent.new(settingName, value)
                )
            end
        end
    end
end

-- Request full sync from server with retry logic using AsyncRetryHandler
local fullSyncRetryHandler = nil

function SoilNetworkEvents_InitializeRetryHandler()
    if fullSyncRetryHandler then return end

    fullSyncRetryHandler = AsyncRetryHandler.new({
        name = "FullSync",
        maxAttempts = SoilConstants.NETWORK.FULL_SYNC_MAX_ATTEMPTS,
        delays = {
            SoilConstants.NETWORK.FULL_SYNC_RETRY_INTERVAL,
            SoilConstants.NETWORK.FULL_SYNC_RETRY_INTERVAL,
            SoilConstants.NETWORK.FULL_SYNC_RETRY_INTERVAL
        },

        onAttempt = function()
            if not g_client or g_server then return end
            g_client:getServerConnection():sendEvent(SoilRequestFullSyncEvent.new())
            SoilLogger.info("Client: Requesting full sync (attempt %d/%d)",
                fullSyncRetryHandler:getAttempts(), fullSyncRetryHandler.maxAttempts)
        end,

        onSuccess = function()
            SoilLogger.info("Client: Full sync completed successfully")
        end,

        onFailure = function()
            SoilLogger.warning("Client: Full sync failed after max attempts")
        end
    })
end

function SoilNetworkEvents_RequestFullSync()
    if not g_client or g_server then return end

    SoilNetworkEvents_InitializeRetryHandler()
    fullSyncRetryHandler:reset()  -- re-arm in case handler completed a previous cycle (e.g. level reload)
    fullSyncRetryHandler:start()
end

-- Called from update loop to handle retry
function SoilNetworkEvents_UpdateSyncRetry(dt)
    if fullSyncRetryHandler then
        fullSyncRetryHandler:update(dt)
    end
end

-- Mark sync as received (called from SoilFullSyncEvent:run)
function SoilNetworkEvents_OnFullSyncReceived()
    if fullSyncRetryHandler then
        fullSyncRetryHandler:markSuccess()
    end
end

-- ========================================
-- SPRAYER RATE EVENT (Client -> Server -> All clients)
-- ========================================
-- Sent when the local player changes the application rate on a sprayer.
-- Server applies the change and rebroadcasts so all clients stay in sync.
SoilSprayerRateEvent = {}
SoilSprayerRateEvent_mt = Class(SoilSprayerRateEvent, Event)

InitEventClass(SoilSprayerRateEvent, "SoilSprayerRateEvent")

function SoilSprayerRateEvent.emptyNew()
    return Event.new(SoilSprayerRateEvent_mt)
end

-- vehicleNetId is the FS25 network object ID (from NetworkUtil.getObjectId).
-- Using the network ID on the wire avoids the streamWriteInt32(nil) crash that
-- occurs when a local i3d node handle is passed to NetworkUtil.getObjectId.
function SoilSprayerRateEvent.new(vehicleNetId, rateIndex)
    local self = SoilSprayerRateEvent.emptyNew()
    self.vehicleNetId = vehicleNetId
    self.rateIndex    = rateIndex
    return self
end

function SoilSprayerRateEvent:readStream(streamId, connection)
    self.vehicleNetId = streamReadInt32(streamId)
    self.rateIndex    = streamReadUInt8(streamId)
    self:run(connection)
end

function SoilSprayerRateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.vehicleNetId or 0)
    streamWriteUInt8(streamId, self.rateIndex or 1)
end

function SoilSprayerRateEvent:run(connection)
    local rm = g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager
    if rm == nil then return end

    local vehicle = NetworkUtil.getObject(self.vehicleNetId)
    if not vehicle then return end

    local steps = SoilConstants.SPRAYER_RATE.STEPS
    if self.rateIndex < 1 or self.rateIndex > #steps then return end

    rm:setIndex(vehicle.id, self.rateIndex)

    if g_server ~= nil then
        g_server:broadcastEvent(
            SoilSprayerRateEvent.new(self.vehicleNetId, self.rateIndex),
            nil,
            connection
        )
    end
end

--- Send a sprayer rate change. Works in SP, MP client, and MP server.
---@param vehicle table  The vehicle object (not vehicle.id)
---@param rateIndex number 1-based index into SPRAYER_RATE.STEPS
function SoilNetworkEvents_SendSprayerRate(vehicle, rateIndex)
    if g_client then
        local vehicleNetId = NetworkUtil.getObjectId(vehicle)
        if not vehicleNetId then return end
        g_client:getServerConnection():sendEvent(
            SoilSprayerRateEvent.new(vehicleNetId, rateIndex)
        )
    else
        local rm = g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager
        if rm then
            rm:setIndex(vehicle.id, rateIndex)
        end
    end
end

-- ========================================
-- SPRAYER AUTO-MODE EVENT (Client <-> Server)
-- ========================================
SoilSprayerAutoModeEvent = {}
SoilSprayerAutoModeEvent_mt = Class(SoilSprayerAutoModeEvent, Event)

InitEventClass(SoilSprayerAutoModeEvent, "SoilSprayerAutoModeEvent")

function SoilSprayerAutoModeEvent.emptyNew()
    return Event.new(SoilSprayerAutoModeEvent_mt)
end

function SoilSprayerAutoModeEvent.new(vehicleNetId, enabled)
    local self = SoilSprayerAutoModeEvent.emptyNew()
    self.vehicleNetId = vehicleNetId
    self.enabled      = enabled
    return self
end

function SoilSprayerAutoModeEvent:readStream(streamId, connection)
    self.vehicleNetId = streamReadInt32(streamId)
    self.enabled      = streamReadBool(streamId)
    self:run(connection)
end

function SoilSprayerAutoModeEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.vehicleNetId or 0)
    streamWriteBool(streamId, self.enabled == true)
end

function SoilSprayerAutoModeEvent:run(connection)
    local rm = g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager
    if rm == nil then return end

    local vehicle = NetworkUtil.getObject(self.vehicleNetId)
    if not vehicle then return end

    rm:setAutoMode(vehicle.id, self.enabled)

    if g_server then
        g_server:broadcastEvent(
            SoilSprayerAutoModeEvent.new(self.vehicleNetId, self.enabled),
            nil, connection
        )
    end
end

---@param vehicle table  The vehicle object (not vehicle.id)
---@param enabled boolean
function SoilNetworkEvents_SendSprayerAutoMode(vehicle, enabled)
    if g_client then
        local vehicleNetId = NetworkUtil.getObjectId(vehicle)
        if not vehicleNetId then return end
        g_client:getServerConnection():sendEvent(
            SoilSprayerAutoModeEvent.new(vehicleNetId, enabled)
        )
    else
        local rm = g_SoilFertilityManager and g_SoilFertilityManager.sprayerRateManager
        if rm then
            rm:setAutoMode(vehicle.id, enabled)
        end
    end
end

-- ========================================
-- FIELDSENTRY MANUAL-BLACKLIST TOGGLE (#651)
-- ========================================
-- Server-authoritative. A pure client sends a request; the server validates (admin),
-- applies it on FieldSentry, then broadcasts so every client mirrors the state for the
-- map-tab status readout. The server/host applies directly via the Send wrapper below.
SoilFieldSentryEvent = {}
SoilFieldSentryEvent_mt = Class(SoilFieldSentryEvent, Event)

InitEventClass(SoilFieldSentryEvent, "SoilFieldSentryEvent")

function SoilFieldSentryEvent.emptyNew()
    return Event.new(SoilFieldSentryEvent_mt)
end

function SoilFieldSentryEvent.new(fieldId, manual)
    local self = SoilFieldSentryEvent.emptyNew()
    self.fieldId = fieldId
    self.manual = manual
    return self
end

function SoilFieldSentryEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)
    self.manual = streamReadBool(streamId)
    self:run(connection)
end

function SoilFieldSentryEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteBool(streamId, self.manual)
end

function SoilFieldSentryEvent:run(connection)
    if g_server ~= nil then
        -- We are the server. A request from a client connection must be admin.
        if not connection:getIsServer() then
            local user = g_currentMission.userManager and
                         g_currentMission.userManager:getUserByConnection(connection)
            if not user or not user:getIsMasterUser() then
                SoilLogger.warning("FieldSentry: non-admin field toggle denied")
                return
            end
        end
        if FieldSentry_API then FieldSentry_API.setFieldManual(self.fieldId, self.manual) end
        -- Relay to all clients except the original sender (they already applied / asked).
        if g_server then
            g_server:broadcastEvent(SoilFieldSentryEvent.new(self.fieldId, self.manual), nil, connection)
        end
    else
        -- Client receiving the server's authoritative state: mirror it for the UI.
        if FieldSentry_API then FieldSentry_API.setFieldManual(self.fieldId, self.manual) end
    end
end

--- Set a field's manual blacklist with multiplayer sync.
--- Pure client: asks the server. Server/host: applies and broadcasts to clients.
---@param fieldId number
---@param manual boolean
function SoilNetworkEvents_SendFieldSentryToggle(fieldId, manual)
    if g_client and not g_server then
        g_client:getServerConnection():sendEvent(SoilFieldSentryEvent.new(fieldId, manual))
    else
        if FieldSentry_API then FieldSentry_API.setFieldManual(fieldId, manual) end
        if g_server then
            g_server:broadcastEvent(SoilFieldSentryEvent.new(fieldId, manual))
        end
    end
end

-- ========================================
-- FIELDSENTRY MEADOW TOGGLE (#651 Phase 3)
-- ========================================
-- Server-authoritative, mirrors the manual-blacklist toggle. A meadow field still
-- simulates (on grassland rules), so this only carries the persistent player intent.
SoilFieldMeadowEvent = {}
SoilFieldMeadowEvent_mt = Class(SoilFieldMeadowEvent, Event)

InitEventClass(SoilFieldMeadowEvent, "SoilFieldMeadowEvent")

function SoilFieldMeadowEvent.emptyNew()
    return Event.new(SoilFieldMeadowEvent_mt)
end

function SoilFieldMeadowEvent.new(fieldId, meadow)
    local self = SoilFieldMeadowEvent.emptyNew()
    self.fieldId = fieldId
    self.meadow = meadow
    return self
end

function SoilFieldMeadowEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)
    self.meadow = streamReadBool(streamId)
    self:run(connection)
end

function SoilFieldMeadowEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteBool(streamId, self.meadow)
end

function SoilFieldMeadowEvent:run(connection)
    if g_server ~= nil then
        if not connection:getIsServer() then
            local user = g_currentMission.userManager and
                         g_currentMission.userManager:getUserByConnection(connection)
            if not user or not user:getIsMasterUser() then
                SoilLogger.warning("FieldSentry: non-admin meadow toggle denied")
                return
            end
        end
        if FieldSentry_API then FieldSentry_API.setFieldMeadow(self.fieldId, self.meadow) end
        if g_server then
            g_server:broadcastEvent(SoilFieldMeadowEvent.new(self.fieldId, self.meadow), nil, connection)
        end
    else
        if FieldSentry_API then FieldSentry_API.setFieldMeadow(self.fieldId, self.meadow) end
    end
end

--- Set a field's meadow flag with multiplayer sync.
--- Pure client: asks the server. Server/host: applies and broadcasts to clients.
---@param fieldId number
---@param meadow boolean
function SoilNetworkEvents_SendFieldMeadowToggle(fieldId, meadow)
    if g_client and not g_server then
        g_client:getServerConnection():sendEvent(SoilFieldMeadowEvent.new(fieldId, meadow))
    else
        if FieldSentry_API then FieldSentry_API.setFieldMeadow(fieldId, meadow) end
        if g_server then
            g_server:broadcastEvent(SoilFieldMeadowEvent.new(fieldId, meadow))
        end
    end
end

-- ========================================
-- FIELDSENTRY CONTRACT-MASK STATUS SYNC (#654, FR5)
-- ========================================
-- Server -> clients only. The contract mask is evaluated server-side (refreshContract);
-- this mirrors the resulting reason enum to clients for the map-tab readout. Carries a
-- per-field sequence so clients drop stale / out-of-order packets (FieldSentry FIFO guard).
SoilFieldSentryStatusEvent = {}
SoilFieldSentryStatusEvent_mt = Class(SoilFieldSentryStatusEvent, Event)

InitEventClass(SoilFieldSentryStatusEvent, "SoilFieldSentryStatusEvent")

function SoilFieldSentryStatusEvent.emptyNew()
    return Event.new(SoilFieldSentryStatusEvent_mt)
end

function SoilFieldSentryStatusEvent.new(fieldId, reason, seq)
    local self = SoilFieldSentryStatusEvent.emptyNew()
    self.fieldId = fieldId
    self.reason  = reason
    self.seq     = seq
    return self
end

function SoilFieldSentryStatusEvent:readStream(streamId, connection)
    self.fieldId = streamReadInt32(streamId)
    self.reason  = streamReadUIntN(streamId, 3)   -- BLACKLIST enum 0..6 fits in 3 bits
    self.seq     = streamReadInt32(streamId)
    self:run(connection)
end

function SoilFieldSentryStatusEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteUIntN(streamId, self.reason or 0, 3)
    streamWriteInt32(streamId, self.seq or 0)
end

function SoilFieldSentryStatusEvent:run(connection)
    -- Clients only: apply the server's authoritative mask with the FIFO seq guard.
    if g_server == nil and FieldSentry_API and FieldSentry_API.applyMaskSync then
        FieldSentry_API.applyMaskSync(self.fieldId, self.reason, self.seq)
    end
end

-- Inject the broadcaster so FieldSentry can push mask changes without referencing the
-- network API itself. Server-only; nil-safe if FieldSentry is somehow absent.
if FieldSentry_Core then
    FieldSentry_Core.maskBroadcaster = function(fieldId, reason, seq)
        if g_server then
            g_server:broadcastEvent(SoilFieldSentryStatusEvent.new(fieldId, reason, seq))
        end
    end
end

-- ========================================
-- REFINED: PER-PIXEL VALUE MAP SYNC (Server -> Client)
-- ========================================
-- Streams the SoilValueMaps layers to joining clients as RLE-compressed rows
-- of the coarse sync grid (top 4 bits per pixel, max 512x512 - see
-- SoilValueMaps.SYNC_GRID). Sent after the field batch sync completes.
-- A trailing checksum event lets clients detect drift and request a resend.

local function sfGetValueMaps()
    local soilSys = g_SoilFertilityManager and g_SoilFertilityManager.soilSystem
    local vm = soilSys and soilSys.valueMaps
    if vm and vm.available then return vm end
    return nil
end

SoilValueMapChunkEvent = {}
SoilValueMapChunkEvent_mt = Class(SoilValueMapChunkEvent, Event)

InitEventClass(SoilValueMapChunkEvent, "SoilValueMapChunkEvent")

function SoilValueMapChunkEvent.emptyNew()
    return Event.new(SoilValueMapChunkEvent_mt)
end

--- layerIdx: 1-based index into SoilValueMaps.LAYER_DEFS
--- gyStart:  first sync-grid row carried by this chunk (0-based)
--- rows:     array of row arrays (4-bit states, 1-based Lua arrays)
--- isLast:   true on the final chunk of the final layer
function SoilValueMapChunkEvent.new(layerIdx, gyStart, rows, isLast)
    local self = SoilValueMapChunkEvent.emptyNew()
    self.layerIdx = layerIdx
    self.gyStart  = gyStart
    self.rows     = rows or {}
    self.isLast   = isLast or false
    return self
end

function SoilValueMapChunkEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.layerIdx)
    streamWriteUInt16(streamId, self.gyStart)
    streamWriteUInt8(streamId, #self.rows)
    streamWriteBool(streamId, self.isLast)
    for _, row in ipairs(self.rows) do
        streamWriteUInt16(streamId, #row)
        -- RLE: (state, runLength) pairs - soil rows are mostly long runs
        local i, n = 1, #row
        local runs = {}
        while i <= n do
            local state = row[i]
            local len = 1
            while i + len <= n and row[i + len] == state do len = len + 1 end
            runs[#runs + 1] = { state = state, len = len }
            i = i + len
        end
        streamWriteUInt16(streamId, #runs)
        for _, run in ipairs(runs) do
            streamWriteUIntN(streamId, run.state, 4)
            streamWriteUInt16(streamId, run.len)
        end
    end
end

function SoilValueMapChunkEvent:readStream(streamId, connection)
    self.layerIdx = streamReadUInt8(streamId)
    self.gyStart  = streamReadUInt16(streamId)
    local rowCount = streamReadUInt8(streamId)
    self.isLast   = streamReadBool(streamId)
    self.rows = {}
    for r = 1, rowCount do
        local rowLen  = streamReadUInt16(streamId)
        local numRuns = streamReadUInt16(streamId)
        local row = {}
        local idx = 1
        for _ = 1, numRuns do
            local state = streamReadUIntN(streamId, 4)
            local len   = streamReadUInt16(streamId)
            for _ = 1, len do
                if idx <= rowLen then
                    row[idx] = state
                    idx = idx + 1
                end
            end
        end
        self.rows[r] = row
    end
    self:run(connection)
end

function SoilValueMapChunkEvent:run(connection)
    -- CLIENT ONLY
    if g_server ~= nil then return end
    local vm = sfGetValueMaps()
    if not vm then return end
    local def = SoilValueMaps.LAYER_DEFS[self.layerIdx]
    if not def then return end
    -- [SF-43 ask 4] Defence in depth at the one call site that can destroy a layer.
    -- The server never streams a serverOnly layer, but clearLayer immediately below
    -- is a whole-map UNFILTERED executeSet(0), so a stray or malformed chunk must
    -- not be able to reach it. Refuse rather than trust the sender.
    if def.serverOnly == true then return end

    -- First chunk of a layer (gyStart == 0): wipe residual local paint so the
    -- server stream can converge. Without this, state-0 cells used to skip and
    -- leftover pixels kept checksums permanently drifted.
    if self.gyStart == 0 and vm.clearLayer then
        vm:clearLayer(def.key)
    end

    for i, row in ipairs(self.rows) do
        vm:applySyncRow(def.key, self.gyStart + (i - 1), row)
    end

    if self.isLast then
        local syncedLayers = 0
        for _, d in ipairs(SoilValueMaps.LAYER_DEFS) do
            if d.serverOnly ~= true then syncedLayers = syncedLayers + 1 end
        end
        SoilLogger.info("Client: value map sync complete (%d layers)", syncedLayers)
        local minimapLayer = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
        if minimapLayer then minimapLayer:markDirty() end
        local mapOverlay = g_SoilFertilityManager and g_SoilFertilityManager.soilMapOverlay
        if mapOverlay then mapOverlay:requestRefresh() end
    end
end

-- ── Checksum verification ─────────────────────────────────

--- Per-layer checksum: sum of all sync-grid states + count of non-zero cells.
--- Cheap to compute on both sides (reads the coarse grid, not full resolution).
local function sfComputeLayerChecksum(vm, layerKey)
    local stride  = vm:getSyncStride()
    local numRows = math.floor(vm.resolution / stride)
    local sum, nonZero = 0, 0
    for gy = 0, numRows - 1 do
        local row = vm:readSyncRow(layerKey, gy)
        if row then
            for _, state in ipairs(row) do
                sum = sum + state
                if state > 0 then nonZero = nonZero + 1 end
            end
        end
    end
    return sum, nonZero
end

SoilValueMapChecksumEvent = {}
SoilValueMapChecksumEvent_mt = Class(SoilValueMapChecksumEvent, Event)

InitEventClass(SoilValueMapChecksumEvent, "SoilValueMapChecksumEvent")

function SoilValueMapChecksumEvent.emptyNew()
    return Event.new(SoilValueMapChecksumEvent_mt)
end

--- checksums: DENSE array of { layerIdx = n, sum = n, nonZero = n }.
---
--- [SF-43 ask 4] Each entry CARRIES its layerIdx. This used to be a positional
--- array whose position was read back as the LAYER_DEFS index, which meant skipping
--- any layer would silently shift every checksum after it onto the wrong layer -
--- the client would then "detect drift" on a layer that was fine and resync it
--- forever. Carrying the index is the same shape the row-streaming work list below
--- already uses, and it is what makes the sync opt-out safe to add at all.
function SoilValueMapChecksumEvent.new(checksums)
    local self = SoilValueMapChecksumEvent.emptyNew()
    self.checksums = checksums or {}
    return self
end

function SoilValueMapChecksumEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, #self.checksums)
    for _, cs in ipairs(self.checksums) do
        streamWriteUInt8(streamId, cs.layerIdx or 0)
        streamWriteInt32(streamId, cs.sum)
        streamWriteInt32(streamId, cs.nonZero)
    end
end

function SoilValueMapChecksumEvent:readStream(streamId, connection)
    local count = streamReadUInt8(streamId)
    self.checksums = {}
    for i = 1, count do
        self.checksums[i] = {
            layerIdx = streamReadUInt8(streamId),
            sum      = streamReadInt32(streamId),
            nonZero  = streamReadInt32(streamId),
        }
    end
    self:run(connection)
end

-- Per-layer client resync attempt counts for this session. Caps the storm when
-- a layer still cannot converge after clear+reapply (e.g. transient race).
local sfValueMapResyncAttempts = {}
local SF_VALUE_MAP_RESYNC_MAX = 2

function SoilValueMapChecksumEvent:run(connection)
    -- CLIENT ONLY: compare against the local maps; request a resync when a
    -- layer has drifted (tolerance covers coarse-grid quantisation noise).
    if g_server ~= nil then return end
    local vm = sfGetValueMaps()
    if not vm then return end

    for _, cs in ipairs(self.checksums) do
        -- [SF-43 ask 4] Index comes from the entry, never from its position.
        local layerIdx = cs.layerIdx
        local def = layerIdx and SoilValueMaps.LAYER_DEFS[layerIdx]
        -- A serverOnly layer was never allocated here, so it has nothing to compare
        -- and must never be resynced. Defensive: the server does not send one.
        if def and def.serverOnly == true then def = nil end
        if def then
            local localSum, localNonZero = sfComputeLayerChecksum(vm, def.key)
            local sumDrift = math.abs(localSum - cs.sum)
            local tolerance = math.max(64, cs.nonZero * 0.02)   -- 2% of painted cells
            if sumDrift > tolerance then
                local attempts = sfValueMapResyncAttempts[layerIdx] or 0
                if attempts >= SF_VALUE_MAP_RESYNC_MAX then
                    if attempts == SF_VALUE_MAP_RESYNC_MAX then
                        SoilLogger.warning(
                            "Client: value map '%s' still drifted after %d resyncs (local sum=%d server=%d) - stopping requests this session",
                            def.key, SF_VALUE_MAP_RESYNC_MAX, localSum, cs.sum)
                        sfValueMapResyncAttempts[layerIdx] = attempts + 1  -- only log once
                    end
                else
                    sfValueMapResyncAttempts[layerIdx] = attempts + 1
                    SoilLogger.warning("Client: value map '%s' drifted (local sum=%d server=%d) - requesting resync (%d/%d)",
                        def.key, localSum, cs.sum, attempts + 1, SF_VALUE_MAP_RESYNC_MAX)
                    if g_client then
                        g_client:getServerConnection():sendEvent(SoilRequestValueMapEvent.new(layerIdx))
                    end
                end
            else
                sfValueMapResyncAttempts[layerIdx] = 0
            end
        end
    end
end

-- ── Layer resync request (Client -> Server) ───────────────

SoilRequestValueMapEvent = {}
SoilRequestValueMapEvent_mt = Class(SoilRequestValueMapEvent, Event)

InitEventClass(SoilRequestValueMapEvent, "SoilRequestValueMapEvent")

function SoilRequestValueMapEvent.emptyNew()
    return Event.new(SoilRequestValueMapEvent_mt)
end

--- layerIdx: 1-based LAYER_DEFS index, or 0 = all layers
function SoilRequestValueMapEvent.new(layerIdx)
    local self = SoilRequestValueMapEvent.emptyNew()
    self.layerIdx = layerIdx or 0
    return self
end

function SoilRequestValueMapEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.layerIdx)
end

function SoilRequestValueMapEvent:readStream(streamId, connection)
    self.layerIdx = streamReadUInt8(streamId)
    self:run(connection)
end

function SoilRequestValueMapEvent:run(connection)
    if g_server == nil or not connection then return end
    SoilNetworkEvents_SendValueMaps(connection, self.layerIdx > 0 and self.layerIdx or nil)
end

-- ── Server-side dispatch ──────────────────────────────────

--- Stream the value map layers to one client connection.
--- onlyLayerIdx: optional 1-based LAYER_DEFS index to resend a single layer.
--- Mirrors the field-batch strategy: synchronous on dedicated servers,
--- drip-fed via addUpdateable on listen servers to protect the render thread.
function SoilNetworkEvents_SendValueMaps(connection, onlyLayerIdx)
    if g_server == nil or not connection then return end
    local vm = sfGetValueMaps()
    if not vm then return end

    local stride  = vm:getSyncStride()
    local numRows = math.floor(vm.resolution / stride)
    if numRows <= 0 then return end

    local ROWS_PER_EVENT = 16

    -- Build the (layerIdx, gyStart) work list
    local work = {}
    for layerIdx, def in ipairs(SoilValueMaps.LAYER_DEFS) do
        -- [SF-43 ask 4] A serverOnly layer is never streamed, not even on an
        -- explicit single-layer resync request: the client has no such layer.
        if def.serverOnly ~= true and (onlyLayerIdx == nil or layerIdx == onlyLayerIdx) then
            local gy = 0
            while gy < numRows do
                work[#work + 1] = { layerIdx = layerIdx, key = def.key, gyStart = gy }
                gy = gy + ROWS_PER_EVENT
            end
        end
    end
    if #work == 0 then return end

    local function buildChunk(item, isLast)
        local rows = {}
        local gyEnd = math.min(item.gyStart + ROWS_PER_EVENT - 1, numRows - 1)
        for gy = item.gyStart, gyEnd do
            rows[#rows + 1] = vm:readSyncRow(item.key, gy) or {}
        end
        return SoilValueMapChunkEvent.new(item.layerIdx, item.gyStart, rows, isLast)
    end

    -- [SF-43 ask 4] SKIP serverOnly layers entirely rather than sending a sentinel:
    -- sfComputeLayerChecksum walks the whole sync grid, so a sentinel would still
    -- pay the full cost per unsynced layer for a number nobody may act on.
    local function buildChecksums()
        local checksums = {}
        for layerIdx, def in ipairs(SoilValueMaps.LAYER_DEFS) do
            if def.serverOnly ~= true then
                local sum, nonZero = sfComputeLayerChecksum(vm, def.key)
                checksums[#checksums + 1] = { layerIdx = layerIdx, sum = sum, nonZero = nonZero }
            end
        end
        return checksums
    end

    if g_dedicatedServer ~= nil or g_currentMission == nil
       or g_currentMission.addUpdateable == nil then
        -- Synchronous path (connection lifetime guaranteed - see issue #228)
        for i, item in ipairs(work) do
            connection:sendEvent(buildChunk(item, i == #work))
        end
        connection:sendEvent(SoilValueMapChecksumEvent.new(buildChecksums()))
        SoilLogger.info("Server: value maps sent synchronously (%d chunks)", #work)
    else
        -- Listen server: drip-feed chunks across frames
        local dispatcher = {
            index      = 1,
            timer      = 0,
            delay      = 40,   -- ms between chunks
            work       = work,
            connection = connection,
            update = function(dsp, dt)
                if not dsp.connection or dsp.index > #dsp.work then
                    g_currentMission:removeUpdateable(dsp)
                    return
                end
                dsp.timer = dsp.timer + dt
                if dsp.timer < dsp.delay then return end
                dsp.timer = 0

                local isLast = (dsp.index == #dsp.work)
                dsp.connection:sendEvent(buildChunk(dsp.work[dsp.index], isLast))
                dsp.index = dsp.index + 1

                if isLast then
                    dsp.connection:sendEvent(SoilValueMapChecksumEvent.new(buildChecksums()))
                    g_currentMission:removeUpdateable(dsp)
                end
            end,
        }
        g_currentMission:addUpdateable(dispatcher)
        SoilLogger.info("Server: value map dispatcher registered (%d chunks)", #work)
    end
end

--- Broadcast checksums to all clients (periodic drift detection).
function SoilNetworkEvents_BroadcastValueMapChecksums()
    if g_server == nil then return end
    local vm = sfGetValueMaps()
    if not vm then return end
    -- [SF-43 ask 4] The broadcast twin of buildChecksums above: same skip, same
    -- explicit layerIdx. These two must stay in lockstep - a divergence here is
    -- exactly the positional bug the carried index was added to make impossible.
    local checksums = {}
    for layerIdx, def in ipairs(SoilValueMaps.LAYER_DEFS) do
        if def.serverOnly ~= true then
            local sum, nonZero = sfComputeLayerChecksum(vm, def.key)
            checksums[#checksums + 1] = { layerIdx = layerIdx, sum = sum, nonZero = nonZero }
        end
    end
    g_server:broadcastEvent(SoilValueMapChecksumEvent.new(checksums))
end

SoilLogger.info("Network events system loaded")