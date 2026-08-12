-- =========================================================
-- FS25 Realistic Soil & Fertilizer - TopographyCache bridges
-- =========================================================
-- SF-77's own persistence + sync. The distance-to-water table is a STATIC
-- table (dirty only on terrain invalidation), so it is the one thing worth
-- persisting and broadcasting. Height, slope and sinks are peer-derived and
-- stay local. Thin delegate-when-present registration, exactly the shape the
-- soil bridges use: no-op when StateLedger / NetworkSync is absent.
-- =========================================================

SoilTopographyBridge = {}

-- Provisional module ids (must be locked with Claude(A) before release, the
-- same <Mod>_<Thing> convention as the soil bridges).
SoilTopographyBridge.LEDGER_MODULE = "SoilFertilizer_Topography"
SoilTopographyBridge.SYNC_MODULE   = "SoilFertilizer_TopographySync"
SoilTopographyBridge.SYNC_CHANNEL  = "SoilFertilizer_TopographySync"

SoilTopographyBridge.ledgerActive = false
SoilTopographyBridge.syncActive   = false

function SoilTopographyBridge.register(mgr)
    local topo = mgr and mgr.topography
    if topo == nil then return end

    -- StateLedger: persist the static water-dist table.
    SoilTopographyBridge.ledgerActive = false
    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger ~= nil and type(ledger.registerModule) == "function" then
        local ok = pcall(function()
            ledger:registerModule(SoilTopographyBridge.LEDGER_MODULE, {
                serialize = function() return topo:getStateTable() end,
                deserialize = function(data) topo:applyStateTable(data) end,
            })
        end)
        if ok then
            SoilTopographyBridge.ledgerActive = true
            SoilLogger.info("[SF-77] TopographyCache registered with StateLedger")
        end
    end

    -- NetworkSync: deliver the static water-dist table to clients.
    SoilTopographyBridge.syncActive = false
    local ns = (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
    if ns ~= nil and type(ns.registerModule) == "function" then
        local ok = pcall(function()
            ns:registerModule(SoilTopographyBridge.SYNC_MODULE, {
                channel = SoilTopographyBridge.SYNC_CHANNEL,
                onWriteState = function() return topo:getStateTable() end,
                onReadState = function(data)
                    local t = mgr and mgr.topography
                    if t ~= nil then t:applyStateTable(data) end
                end,
            })
        end)
        if ok then
            SoilTopographyBridge.syncActive = true
            SoilLogger.info("[SF-77] TopographyCache registered with NetworkSync")
        end
    end
end

--- Mark the NetworkSync module dirty on a terrain invalidation (the static
--- table only changes then).
function SoilTopographyBridge.markDirty()
    if not SoilTopographyBridge.syncActive then return end
    local ns = (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
    if ns ~= nil then ns:markDirty(SoilTopographyBridge.SYNC_MODULE) end
end
