-- =========================================================
-- FS25 Realistic Soil & Fertilizer - StateLedger bridge
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Optional bridge to FS25_StateLedger. SoilFertilizer ships standalone, so this
-- is strictly delegate-when-present:
--   * StateLedger installed  -> the master save file is the LOAD source of truth
--     (soilData.xml is still written every save as a safety copy, so removing the
--     ledger later never loses data).
--   * StateLedger absent     -> nothing changes; soilData.xml is primary as always.
--
-- On the first load after installing the ledger onto an existing save, the ledger
-- has no soil block yet (deserialize delivers nil), so loadSoilData falls back to
-- importing the existing soilData.xml. From then on the ledger carries the state.
--
-- The cross-mod handle is g_currentMission.stateLedger (the bare g_stateLedger
-- global is only visible inside StateLedger's own mod environment). Registration
-- is order-independent: StateLedger delivers our deserialize exactly once, whether
-- we register before or after it parses the master file.
-- =========================================================

SoilStateLedgerBridge = SoilStateLedgerBridge or {}

-- Provisional module id. This is the persistence KEY inside the master file, so it
-- must be locked with Claude(A) before any release (a later rename orphans saved
-- soil data). Matches StateLedger's <Mod>_<Thing> example convention.
SoilStateLedgerBridge.MODULE_ID = "SoilFertilizer_Soil"
SoilStateLedgerBridge.SCHEMA    = 1

SoilStateLedgerBridge.active       = false   -- ledger present and we registered
SoilStateLedgerBridge.delivered    = false   -- deserialize has fired (once)
SoilStateLedgerBridge.pendingState = nil     -- cached table from deserialize (nil = new/no block)

-- Compose the full soil state: soil system fields + FieldSentry + lastSeenVersion.
-- Mirrors exactly what saveSoilData writes into soilData.xml.
function SoilStateLedgerBridge.buildState(mgr)
    local out = { schema = SoilStateLedgerBridge.SCHEMA }
    if mgr ~= nil and mgr.soilSystem ~= nil and mgr.soilSystem.getSoilStateTable ~= nil then
        out.soil = mgr.soilSystem:getSoilStateTable()
    end
    if FieldSentry_API ~= nil and FieldSentry_API.getStateTable ~= nil then
        out.fieldSentry = FieldSentry_API.getStateTable()
    end
    out.lastSeenVersion = (mgr ~= nil and mgr.lastSeenVersion) or ""
    return out
end

-- Apply the cached ledger state into the manager. Returns true if a real block was
-- applied, false when there is nothing to apply (new save / no block yet).
function SoilStateLedgerBridge.applyState(mgr)
    local data = SoilStateLedgerBridge.pendingState
    if type(data) ~= "table" or mgr == nil then return false end

    if mgr.soilSystem ~= nil and mgr.soilSystem.applySoilStateTable ~= nil then
        mgr.soilSystem:applySoilStateTable(data.soil)
    end
    if FieldSentry_API ~= nil and FieldSentry_API.applyStateTable ~= nil then
        FieldSentry_API.applyStateTable(data.fieldSentry)
    end
    mgr.lastSeenVersion = data.lastSeenVersion or ""
    return true
end

-- True when the ledger is the source of truth for this load (present, registered,
-- and it delivered an actual block). When present but empty, loadSoilData imports
-- the existing soilData.xml instead.
function SoilStateLedgerBridge.hasLedgerState()
    return SoilStateLedgerBridge.active
        and SoilStateLedgerBridge.delivered
        and SoilStateLedgerBridge.pendingState ~= nil
end

-- Register with StateLedger if present. Called at loadMission00Finished, after the
-- ledger has published its g_currentMission handle (Mission00.load).
function SoilStateLedgerBridge.register(mgr)
    -- Reset per-load so a map swap / reload starts clean.
    SoilStateLedgerBridge.active       = false
    SoilStateLedgerBridge.delivered    = false
    SoilStateLedgerBridge.pendingState = nil

    local ledger = (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
    if ledger == nil then
        SoilLogger.info("StateLedger not detected; soil data uses its own soilData.xml")
        return
    end
    if mgr == nil then return end

    local ok, err = pcall(function()
        ledger:registerModule(SoilStateLedgerBridge.MODULE_ID, {
            serialize = function()
                return SoilStateLedgerBridge.buildState(mgr)
            end,
            deserialize = function(data)
                SoilStateLedgerBridge.delivered    = true
                SoilStateLedgerBridge.pendingState = data   -- nil on a brand-new save
            end,
        })
    end)

    if ok then
        SoilStateLedgerBridge.active = true
        SoilLogger.info("Registered with StateLedger as '%s' (soilData.xml kept as safety copy)",
            SoilStateLedgerBridge.MODULE_ID)
    else
        SoilLogger.warning("StateLedger registration failed: %s (falling back to soilData.xml)", tostring(err))
    end
end
