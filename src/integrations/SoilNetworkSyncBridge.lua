-- =========================================================
-- FS25 Realistic Soil & Fertilizer - NetworkSync bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_NetworkSync (bedrock mod 2). SoilFertilizer ships
-- standalone, so this is strictly delegate-when-present:
--   * NetworkSync installed -> the ongoing per-field soil deltas (harvest,
--     fertilize, weather, treatments, ...) are folded into NetworkSync's single
--     1Hz whole-field-map batch instead of a per-field SoilFieldUpdateEvent.
--   * NetworkSync absent     -> nothing changes; SF's own event classes carry
--     every delta exactly as before.
--
-- WHAT WE DELEGATE, AND WHAT WE DO NOT:
--   * Delegated: the ongoing per-field delta broadcasts (the 17 sim sites route
--     through SoilNetworkEvents_BroadcastFieldUpdate, which markDirty's this one
--     module when we are active). NetworkSync re-serializes the whole field map
--     on the next 1Hz tick and broadcasts it once.
--   * NOT delegated: SF's join full-sync (settings + the batched field push in
--     SoilRequestFullSyncEvent / onClientJoined) stays live. That path is
--     deliberately chunked (issues #212 / #228) and is our overflow-safe join
--     guarantee. NetworkSync's own join snapshot also fires when present, but we
--     do not rely on it for correctness. Settings are SettingsHub's domain, not
--     NetworkSync's, so they are untouched here.
--
-- ZERO ZONE CELLS ON THE WIRE: exactly like SoilFieldUpdateEvent, we send only
-- the field aggregate (no per-cell zoneData). A wide-boom pass can push a single
-- field's cell count into the thousands, which overflows the FS25 packet limit.
-- Clients reconstruct per-cell display from the aggregate on apply (same as the
-- event's run()), so the overlay stays correct.
--
-- SIZE CAVEAT (flag for the ledger): NetworkSync sends each module's array in ONE
-- un-chunked RealisticFarmingSyncEvent. On extreme maps (hundreds of fields) the
-- whole-field-map array approaches the same single-event size limit SF's batched
-- join path was built to avoid. NetworkSync has no per-module chunking today; if
-- that becomes a problem the fix belongs in NetworkSync (chunked module sends),
-- not here. Zero zone cells keeps this an order of magnitude below the old
-- thousands-of-cells overflow, so it is safe for realistic field counts.
--
-- The cross-mod handle is g_currentMission.networkSync (the bare g_networkSync
-- global is only visible inside NetworkSync's own mod environment). Registration
-- is order-independent.
-- =========================================================

SoilNetworkSyncBridge = SoilNetworkSyncBridge or {}

-- Provisional module id. This is the network CHANNEL and the join-snapshot key, so
-- it must be locked with Claude(A) before release (a later rename desyncs a mixed
-- lobby). Matches the <Mod>_<Thing> convention shared with StateLedger.
SoilNetworkSyncBridge.MODULE_ID = "SoilFertilizer_Sync"
SoilNetworkSyncBridge.CHANNEL   = "SoilFertilizer_Sync"

SoilNetworkSyncBridge.active = false   -- NetworkSync present and we registered

-- Ordered scalar schema. serializeFields and deserializeFields both walk this list,
-- so the write order and the read order can never drift. Order and clamp domains
-- mirror SoilFieldUpdateEvent's per-field payload exactly. NetworkSync auto-tags
-- each value int32-vs-float32 on the wire, so we push raw numbers here.
local FD  = SoilConstants.FIELD_DEFAULTS
local LIM = SoilConstants.NUTRIENT_LIMITS

SoilNetworkSyncBridge.SCALARS = {
    { key = "fieldArea",           def = 1.0,               min = 0.01,        max = nil },
    { key = "nitrogen",            def = FD.nitrogen,       min = LIM.MIN,     max = LIM.MAX },
    { key = "phosphorus",          def = FD.phosphorus,     min = LIM.MIN,     max = LIM.MAX },
    { key = "potassium",           def = FD.potassium,      min = LIM.MIN,     max = LIM.MAX },
    { key = "organicMatter",       def = FD.organicMatter,  min = LIM.MIN,     max = LIM.ORGANIC_MATTER_MAX },
    { key = "pH",                  def = FD.pH,             min = LIM.PH_MIN,  max = LIM.PH_MAX },
    { key = "rotationBonusDaysLeft", def = 0,               min = 0,           max = nil },
    { key = "lastHarvest",         def = 0,                 min = 0,           max = nil },
    { key = "fertilizerApplied",   def = 0,                 min = 0,           max = nil },
    { key = "weedPressure",        def = 0,                 min = 0,           max = 100 },
    { key = "herbicideDaysLeft",   def = 0,                 min = 0,           max = nil },
    { key = "pestPressure",        def = 0,                 min = 0,           max = 100 },
    { key = "insecticideDaysLeft", def = 0,                 min = 0,           max = nil },
    { key = "diseasePressure",     def = 0,                 min = 0,           max = 100 },
    { key = "fungicideDaysLeft",   def = 0,                 min = 0,           max = nil },
    { key = "dryDayCount",         def = 0,                 min = 0,           max = nil },
    { key = "burnDaysLeft",        def = 0,                 min = 0,           max = nil },
    { key = "coverageFraction",    def = 0,                 min = 0,           max = 1 },
    { key = "compaction",          def = 0,                 min = 0,           max = 100 },
}

local function clamp(v, lo, hi)
    v = tonumber(v) or 0
    if lo ~= nil and v < lo then v = lo end
    if hi ~= nil and v > hi then v = hi end
    return v
end

-- =========================================================
-- Pure serialize / deserialize (server writes, client reads)
-- =========================================================

-- Flatten the whole field map into one integer-indexed primitive array (the shape
-- NetworkSync expects). arr[1] = field count, then per field:
--   fieldId, <each SCALARS value>, lastCrop, lastCrop2, lastCrop3, activeDisease,
--   bufferCount, bufferCount x (fillTypeIndex, amount),
--   organicState, organicStartDay, organicCertifiedDay, organicBreaches,
--   diseaseDiscovered, bandCount, bandCount x (fracMode, band), fieldEverScouted
function SoilNetworkSyncBridge.serializeFields(fieldData)
    local arr = { 0 }   -- slot 1 reserved for the count
    local n = 0
    for fieldId, field in pairs(fieldData or {}) do
        n = n + 1
        arr[#arr + 1] = fieldId
        for _, s in ipairs(SoilNetworkSyncBridge.SCALARS) do
            local v = field[s.key]
            if v == nil then v = s.def end
            arr[#arr + 1] = v
        end
        arr[#arr + 1] = field.lastCrop      or ""
        arr[#arr + 1] = field.lastCrop2     or ""
        arr[#arr + 1] = field.lastCrop3     or ""
        arr[#arr + 1] = field.activeDisease or ""

        local buffer = field.nutrientBuffer or {}
        local bCount = 0
        for _ in pairs(buffer) do bCount = bCount + 1 end
        arr[#arr + 1] = bCount
        for ftIdx, amount in pairs(buffer) do
            arr[#arr + 1] = ftIdx
            arr[#arr + 1] = amount
        end

        -- Organic certification (state enum + startDay + certifiedDay + breaches).
        -- Without this the 1Hz whole-map apply below rebuilds each client field with
        -- no organic and wipes what the client held; sending it keeps cert true.
        local orgState, orgStart, orgCert, orgBreach = OrganicCertification.encodeFieldOrganic(field)
        arr[#arr + 1] = orgState
        arr[#arr + 1] = orgStart
        arr[#arr + 1] = orgCert
        arr[#arr + 1] = orgBreach

        -- The scout/discovery flag. It was NOT carried here before CD-11, while
        -- SoilFieldUpdateEvent has always sent it -- so _onReadState's wholesale replace
        -- (:250) dropped it on every apply and a scouted field silently reverted to
        -- unscouted on the client. Same defect class as the organic wipe above. CD-11's
        -- band gate reads this flag, so without it every band below would arrive and
        -- immediately read UNKNOWN.
        arr[#arr + 1] = field.diseaseDiscovered and 1 or 0

        -- CD-11 resistance bands, for exactly the reason organic sits above: this bridge's
        -- whole-map apply rebuilds every client field, so anything it does not carry is
        -- wiped within a second of arriving by any other path. The CD-11 brief names three
        -- handlers; this bridge is the FOURTH, and omitting it would have made the bands
        -- look like they synced and then silently vanish.
        local bandFlat = ResistanceBands.encodeFieldBands(field)
        arr[#arr + 1] = math.floor(#bandFlat / 2)
        for _, v in ipairs(bandFlat) do arr[#arr + 1] = v end
        -- CD-11: the durable scout bit rides after the bands, same order as NetworkEvents.
        arr[#arr + 1] = field.fieldEverScouted and 1 or 0
    end
    arr[1] = n
    return arr
end

-- Rebuild a { fieldId -> field } map from the flat array, applying the same clamps
-- as SoilFieldUpdateEvent. Pure: no live apply / zone reconstruction / layer write
-- (onReadState does those). Never crashes on a short or malformed array.
function SoilNetworkSyncBridge.deserializeFields(arr)
    local out = {}
    if type(arr) ~= "table" then return out end

    local i = 1
    local count = tonumber(arr[i]) or 0
    i = i + 1

    for _ = 1, count do
        local fieldId = arr[i]; i = i + 1
        if fieldId == nil then break end

        local field = { initialized = true, coveredCells = {}, coveredCellCount = 0, zoneData = {} }
        for _, s in ipairs(SoilNetworkSyncBridge.SCALARS) do
            field[s.key] = clamp(arr[i], s.min, s.max)
            i = i + 1
        end

        local lc  = arr[i]; i = i + 1
        local lc2 = arr[i]; i = i + 1
        local lc3 = arr[i]; i = i + 1
        local ad  = arr[i]; i = i + 1
        field.lastCrop      = (lc  ~= nil and lc  ~= "") and lc  or nil
        field.lastCrop2     = (lc2 ~= nil and lc2 ~= "") and lc2 or nil
        field.lastCrop3     = (lc3 ~= nil and lc3 ~= "") and lc3 or nil
        field.activeDisease = (ad  ~= nil and ad  ~= "") and ad  or nil
        field.activeDiseaseSeverity =
            (field.activeDisease and SoilDiseaseSystem) and SoilDiseaseSystem.yieldSeverity(field.activeDisease) or 1.0

        local bCount = tonumber(arr[i]) or 0; i = i + 1
        local buffer = {}
        for _ = 1, bCount do
            local ftIdx  = arr[i]; i = i + 1
            local amount = arr[i]; i = i + 1
            if ftIdx ~= nil then buffer[ftIdx] = amount end
        end
        field.nutrientBuffer = buffer

        -- Organic certification (same trailing order as serializeFields). Applied
        -- authoritatively so the client's cert state matches the server.
        local orgState  = tonumber(arr[i]) or 0; i = i + 1
        local orgStart  = tonumber(arr[i]) or 0; i = i + 1
        local orgCert   = tonumber(arr[i]) or 0; i = i + 1
        local orgBreach = tonumber(arr[i]) or 0; i = i + 1
        OrganicCertification.applyFieldOrganic(field, orgState, orgStart, orgCert, orgBreach)

        -- Discovery flag, then CD-11 bands (same trailing order as serializeFields).
        field.diseaseDiscovered = (tonumber(arr[i]) or 0) == 1; i = i + 1

        local bandCount = tonumber(arr[i]) or 0; i = i + 1
        if bandCount < 0 then bandCount = 0 end
        local bandFlat = {}
        for _ = 1, bandCount do
            bandFlat[#bandFlat + 1] = arr[i]; i = i + 1
            bandFlat[#bandFlat + 1] = arr[i]; i = i + 1
        end
        ResistanceBands.applyFieldBands(field, bandFlat)
        -- CD-11 durable scout bit, read right after the bands and put on the new table.
        field.fieldEverScouted = (tonumber(arr[i]) or 0) == 1; i = i + 1

        out[fieldId] = field
    end
    return out
end

-- =========================================================
-- NetworkSync callbacks (plain functions - called with no self)
-- =========================================================

-- Server: hand NetworkSync the whole field map for the next batch.
function SoilNetworkSyncBridge._onWriteState()
    local sfm = g_SoilFertilityManager
    local soilSys = sfm and sfm.soilSystem
    return SoilNetworkSyncBridge.serializeFields(soilSys and soilSys.fieldData or {})
end

-- Client: apply a received whole field map. Mirrors SoilFieldUpdateEvent:run -
-- preserve local zoneData and resync cells to the new aggregate, write GRLE layers
-- on pure clients, then refresh the minimap + map overlay once.
function SoilNetworkSyncBridge._onReadState(arr)
    local sfm = g_SoilFertilityManager
    local soilSys = sfm and sfm.soilSystem
    if soilSys == nil then return end

    local incoming = SoilNetworkSyncBridge.deserializeFields(arr)
    local pureClient = (g_server == nil)

    for fieldId, newField in pairs(incoming) do
        local existing = soilSys.fieldData[fieldId]
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

        soilSys.fieldData[fieldId] = newField

        -- On pure clients the sprayer hook never runs, so the GRLE layers that power
        -- the minimap heatmap are never written; write the field now to keep the
        -- minimap in sync. Skipped on listen-server hosts where the hook owns it.
        if pureClient then
            local layerSys = soilSys.layerSystem
            if layerSys and layerSys.available then
                local fsField = g_fieldManager and g_fieldManager.fields and g_fieldManager.fields[fieldId]
                layerSys:writeFieldToLayers(fieldId, newField, fsField)
            end
        end
    end

    if pureClient then
        local sml = sfm and sfm.soilMinimapLayer
        if sml then sml:markDirty() end
    end
    local overlay = sfm and sfm.soilMapOverlay
    if overlay then overlay:requestRefresh() end
end

-- =========================================================
-- Public: flag the module dirty for the next 1Hz batch.
-- =========================================================
-- Called by SoilNetworkEvents_BroadcastFieldUpdate at every delta site when we are
-- active. Per-field granularity collapses to "the field map changed"; NetworkSync
-- reserializes the whole map once on the next tick. No-op when we are not active.
function SoilNetworkSyncBridge.markFieldDirty()
    if not SoilNetworkSyncBridge.active then return end
    local ns = (g_currentMission and g_currentMission.networkSync) or g_networkSync
    if ns ~= nil then ns:markDirty(SoilNetworkSyncBridge.MODULE_ID) end
end

-- =========================================================
-- Registration (loadMission00Finished)
-- =========================================================
function SoilNetworkSyncBridge.register(mgr)
    -- Reset per-load so a map swap / reload starts clean.
    SoilNetworkSyncBridge.active = false

    local ns = (g_currentMission and g_currentMission.networkSync) or g_networkSync
    if ns == nil then
        SoilLogger.info("NetworkSync not detected; soil MP sync uses its own event classes")
        return
    end

    local ok, err = pcall(function()
        ns:registerModule(SoilNetworkSyncBridge.MODULE_ID, {
            channel      = SoilNetworkSyncBridge.CHANNEL,
            onWriteState = SoilNetworkSyncBridge._onWriteState,
            onReadState  = SoilNetworkSyncBridge._onReadState,
        })
    end)

    if ok then
        SoilNetworkSyncBridge.active = true
        SoilLogger.info("Registered with NetworkSync as '%s' (per-field soil deltas now batch through NetworkSync)",
            SoilNetworkSyncBridge.MODULE_ID)
    else
        SoilNetworkSyncBridge.active = false
        SoilLogger.warning("NetworkSync registration failed: %s (falling back to soil event classes)", tostring(err))
    end
end
