-- =========================================================
-- FS25 Soil & Fertilizer - MATERIAL DOWN bridges (SF-43)
-- =========================================================
-- Two optional-mod bridges for the MATERIAL DOWN system, kept together because
-- they are the system's only outside contact:
--
--   1. TIME GUARD - two day-cadence accruals. SoilFertilizer had NO Time Guard
--      integration before this brief, so this is new plumbing, not a contract
--      change on their side.
--   2. STATE LEDGER - the watermark + object sidecar, delegate-when-present with
--      an own-XML fallback.
--
-- Both are strictly delegate-when-present. Neither mod is a hard dependency.
-- =========================================================
-- Author: TisonK
-- =========================================================

SoilMaterialDownBridge = {}

-- =========================================================
-- Time Guard
-- =========================================================

SoilMaterialDownBridge.ACCRUAL_AGE         = "SoilFertilizer_MaterialDown_age"
SoilMaterialDownBridge.ACCRUAL_MAINTENANCE = "SoilFertilizer_MaterialDown_maintenance"

-- Settle order for the WHOLE ground-material package, fixed here so the sibling
-- member registers into a known sequence instead of negotiating one later:
--
--   10  member conversion / spoil resolution   (SF-44 HayBet)
--   20  THIS mod's age tick                    <- time exists before the day's weather
--   30  the sibling's condition accrual (dry, wet, record)
--   40  publication / maintenance              (SF-46's ladder pass rides this slot)
--
-- The ordering is the point: a day's age must be settled BEFORE the sibling applies
-- that day's weather to it, or the two members disagree about what day it is.
SoilMaterialDownBridge.PRIORITY = {
    MEMBER_RESOLUTION = 10,
    AGE_TICK          = 20,
    CONDITION_ACCRUAL = 30,   -- reserved for the sibling; nothing registers it here
    PUBLICATION       = 40,   -- maintenance, and SF-46's ladder pass
}

SoilMaterialDownBridge.timeGuardActive = false

local function getTimeGuard()
    return (g_currentMission ~= nil and g_currentMission.timeGuard) or nil
end

--- Register the two accruals. Server only: the layer does not exist elsewhere.
---
--- firstPeriodPolicy = "skip" on BOTH, stated explicitly because the scheduler's
--- SILENT default is "prorate", which would retroactively settle the partial period
--- the mod happened to load in - ageing material that predates the layer entirely.
--- Both onSettle bodies ignore ctx.proration, which is meaningless for a +1 raw add.
---@return boolean registered
function SoilMaterialDownBridge.registerAccruals(materialDown)
    SoilMaterialDownBridge.timeGuardActive = false
    if materialDown == nil then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        -- Neutral when absent, and deliberately NOT papered over with a private
        -- day counter: a second clock beside Time Guard's is the same class of
        -- mistake as a private sky. Records are still born and still read; they
        -- simply do not age until Time Guard is present.
        SoilLogger.info(
            "[MaterialDown] Time Guard not detected - material ages nowhere. Records are still " ..
            "created and read; no private clock is minted to fill the gap.")
        return false
    end

    local okAge = false
    local okMaint = false
    local ok, err = pcall(function()
        okAge = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_AGE, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.AGE_TICK,
            onSettle          = function(ctx) materialDown:onAgeTick(ctx) end,
        })
        okMaint = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_MAINTENANCE, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.PUBLICATION,
            onSettle          = function(ctx) materialDown:onMaintenanceTick(ctx) end,
        })
    end)

    if not ok then
        SoilLogger.warning("[MaterialDown] Time Guard registration failed: %s", tostring(err))
        return false
    end
    if not (okAge and okMaint) then
        SoilLogger.warning("[MaterialDown] Time Guard rejected an accrual (age=%s maintenance=%s)",
            tostring(okAge), tostring(okMaint))
        return false
    end

    SoilMaterialDownBridge.timeGuardActive = true
    SoilLogger.info("[OK] MaterialDown registered two day accruals with Time Guard (skip, prio %d/%d)",
        SoilMaterialDownBridge.PRIORITY.AGE_TICK, SoilMaterialDownBridge.PRIORITY.PUBLICATION)
    return true
end

SoilMaterialDownBridge.ACCRUAL_CONDITION = "SoilFertilizer_MaterialWetness_condition"

--- [SF-49] The condition accrual, registered into the slot the sibling reserved so
--- it settles AFTER the age tick. The ordering is the point: a day's age must be
--- settled before that day's weather is applied to it, or the two members disagree
--- about what day it is.
---
--- firstPeriodPolicy = "skip" for the same stated reason as the sibling's pair - the
--- scheduler's silent default is "prorate", which would retroactively wet or dry
--- material that predates the layer.
---@return boolean registered
function SoilMaterialDownBridge.registerConditionAccrual(materialWetness)
    if materialWetness == nil then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[MaterialWetness] Time Guard not detected - condition never accrues")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_CONDITION, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.CONDITION_ACCRUAL,
            onSettle          = function(ctx) materialWetness:onConditionAccrual(ctx) end,
        })
    end)
    if not ok or not okReg then
        SoilLogger.warning("[MaterialWetness] Time Guard registration failed: %s", tostring(err))
        return false
    end
    SoilLogger.info("[OK] MaterialWetness registered its condition accrual (skip, prio %d)",
        SoilMaterialDownBridge.PRIORITY.CONDITION_ACCRUAL)
    return true
end

function SoilMaterialDownBridge.unregisterAccruals()
    local tg = getTimeGuard()
    if tg == nil or tg.unregisterAccrual == nil then return end
    pcall(function()
        tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_AGE)
        tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_MAINTENANCE)
        tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_CONDITION)
        if SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER then
            tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER)
        end
        if SoilMaterialDownBridge.ACCRUAL_LADDER then
            tg:unregisterAccrual(SoilMaterialDownBridge.ACCRUAL_LADDER)
        end
    end)
    SoilMaterialDownBridge.timeGuardActive = false
end

-- =========================================================
-- Hay Member (SF-44 — THE HAY BET)
-- =========================================================

SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER = "SoilFertilizer_HayBet_resolution"

--- Register the hay member resolution on the MEMBER_RESOLUTION
--- slot (priority 10, before the age tick). Called once per game
--- day to run the settle pass — read condition, decide spoil, and
--- (when the conversion confirm lands) convert grass to hay.
---@param hayBet HayBet|nil
---@return boolean registered
function SoilMaterialDownBridge.registerHayMember(hayBet)
    if hayBet == nil or not hayBet:isArmed() then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[HayBet] Time Guard not detected - settle pass never fires")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_HAY_MEMBER, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.MEMBER_RESOLUTION,
            onSettle          = function(ctx) hayBet:onSettle(ctx) end,
        })
    end)
    if not ok or not okReg then
        SoilLogger.warning("[HayBet] Time Guard registration failed: %s", tostring(err))
        return false
    end

    SoilLogger.info("[OK] HayBet registered its day settle (prio %d)", SoilMaterialDownBridge.PRIORITY.MEMBER_RESOLUTION)
    return true
end

-- =========================================================
-- Yard Ladder (SF-46 — THE YARD LADDER)
-- =========================================================

SoilMaterialDownBridge.ACCRUAL_LADDER = "SoilFertilizer_YardLadder_pass"

--- Register the yard ladder's daily pass on the PUBLICATION slot
--- (priority 40), the everything-else day accrual the brief names.
--- Never the one-call age tick: this pass is linear in ledger rows
--- and makes no engine pass, so it has no business sharing a slot
--- with the whole-layer walk.
---
--- Accruals are keyed by NAME, so riding the same priority as the
--- maintenance accrual is a shared slot, not a collision.
---@param yardLadder YardLadder|nil
---@return boolean registered
function SoilMaterialDownBridge.registerLadderPass(yardLadder)
    if yardLadder == nil or not yardLadder:isArmed() then return false end
    if g_server == nil then return false end

    local tg = getTimeGuard()
    if tg == nil or tg.registerAccrual == nil then
        SoilLogger.info("[YardLadder] Time Guard not detected - ladder pass never fires")
        return false
    end

    local okReg = false
    local ok, err = pcall(function()
        okReg = tg:registerAccrual(SoilMaterialDownBridge.ACCRUAL_LADDER, {
            cadence           = "day",
            flowClass         = "calendar",
            firstPeriodPolicy = "skip",
            priority          = SoilMaterialDownBridge.PRIORITY.PUBLICATION,
            onSettle          = function(ctx) yardLadder:onLadderPass(ctx) end,
        })
    end)
    if not ok or not okReg then
        SoilLogger.warning("[YardLadder] Time Guard registration failed: %s", tostring(err))
        return false
    end

    SoilLogger.info("[OK] YardLadder registered its daily pass (prio %d)", SoilMaterialDownBridge.PRIORITY.PUBLICATION)
    return true
end

-- =========================================================
-- State Ledger sidecar
-- =========================================================

SoilMaterialDownBridge.MODULE_ID  = "SoilFertilizer_MaterialDown"
SoilMaterialDownBridge.XML_FILE   = "sfMaterialDown.xml"
SoilMaterialDownBridge.ledgerActive = false

local function getLedger()
    return (g_currentMission ~= nil and g_currentMission.stateLedger) or nil
end

local function xmlPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
       or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. SoilMaterialDownBridge.XML_FILE
end

--- Register the sidecar with StateLedger when present.
---
--- deserialize MERGES, never replaces. StateLedger OMITS a block when serialize
--- fails and cannot tell an omitted block from a brand-new save (it chooses
--- resume-vs-defaults purely on data ~= nil). A replace-on-nil would wipe the
--- watermark after ONE bad save, and a lost watermark re-ages the entire map on the
--- next tick. MaterialDown:deserialize keeps the furthest-on watermark for the same
--- reason, so the merge is enforced on both sides of this boundary.
function SoilMaterialDownBridge.registerLedger(materialDown)
    SoilMaterialDownBridge.ledgerActive = false
    if materialDown == nil then return false end
    if g_server == nil then return false end

    local ledger = getLedger()
    if ledger == nil or ledger.registerModule == nil then
        SoilLogger.info("[MaterialDown] StateLedger not detected - using %s",
            SoilMaterialDownBridge.XML_FILE)
        return false
    end

    local ok, err = pcall(function()
        ledger:registerModule(SoilMaterialDownBridge.MODULE_ID, {
            serialize = function()
                return materialDown:serialize()
            end,
            deserialize = function(data)
                -- nil on a brand-new save AND on an omitted block: merge handles both.
                if data ~= nil then materialDown:deserialize(data) end
            end,
        })
    end)

    if not ok then
        SoilLogger.warning("[MaterialDown] StateLedger registration failed: %s (using %s)",
            tostring(err), SoilMaterialDownBridge.XML_FILE)
        return false
    end

    SoilMaterialDownBridge.ledgerActive = true
    SoilLogger.info("[OK] MaterialDown registered with StateLedger as '%s'",
        SoilMaterialDownBridge.MODULE_ID)
    return true
end

-- [SF-49] The Water Record's own ledger module. ONE NOUN, PINNED: this string is a
-- persistence key, so a later rename orphans every saved verdict.
SoilMaterialDownBridge.WATER_MODULE_ID = "SoilFertilizer_MaterialWaterBook"
SoilMaterialDownBridge.waterLedgerActive = false

--- Register the Water Record sidecar. Merge-never-replace on the far side, for the
--- same reason as the sibling's: an omitted block is indistinguishable from a new
--- save, and a replace-on-nil would erase frozen verdicts that cannot be recomputed
--- (the climate roll reads the CURRENT season, so a past day would change its answer).
function SoilMaterialDownBridge.registerWaterLedger(materialWetness)
    SoilMaterialDownBridge.waterLedgerActive = false
    if materialWetness == nil then return false end
    if g_server == nil then return false end

    local ledger = getLedger()
    if ledger == nil or ledger.registerModule == nil then
        SoilLogger.info("[MaterialWetness] StateLedger not detected - the Water Record is session-only")
        return false
    end

    local ok, err = pcall(function()
        ledger:registerModule(SoilMaterialDownBridge.WATER_MODULE_ID, {
            serialize   = function() return materialWetness:serialize() end,
            deserialize = function(data)
                if data ~= nil then materialWetness:deserialize(data) end
            end,
        })
    end)
    if not ok then
        SoilLogger.warning("[MaterialWetness] StateLedger registration failed: %s", tostring(err))
        return false
    end
    SoilMaterialDownBridge.waterLedgerActive = true
    SoilLogger.info("[OK] MaterialWetness registered with StateLedger as '%s'",
        SoilMaterialDownBridge.WATER_MODULE_ID)
    return true
end

--- Own-XML fallback save. Runs only when StateLedger is absent; the ledger owns the
--- state when present so nothing writes it twice.
function SoilMaterialDownBridge.saveFallback(materialDown)
    if materialDown == nil or SoilMaterialDownBridge.ledgerActive then return end
    if g_server == nil then return end
    local path = xmlPath()
    if path == nil or createXMLFile == nil then return end

    local state = materialDown:serialize()
    local ok, err = pcall(function()
        local xmlFile = createXMLFile("sfMaterialDown", path, "materialDown")
        if xmlFile == nil then return end
        setXMLInt(xmlFile, "materialDown#schema", state.schema or 1)
        if state.ageAppliedThroughDay ~= nil then
            setXMLInt(xmlFile, "materialDown#ageAppliedThroughDay", state.ageAppliedThroughDay)
        end
        saveXMLFile(xmlFile)
        delete(xmlFile)
    end)
    if not ok then
        SoilLogger.warning("[MaterialDown] fallback save failed: %s", tostring(err))
    end
end

--- Own-XML fallback load. Also MERGES (through MaterialDown:deserialize), so a
--- missing or unreadable file leaves whatever the ledger already delivered intact.
function SoilMaterialDownBridge.loadFallback(materialDown)
    if materialDown == nil or SoilMaterialDownBridge.ledgerActive then return end
    if g_server == nil then return end
    local path = xmlPath()
    if path == nil or loadXMLFile == nil or fileExists == nil or not fileExists(path) then return end

    local ok, err = pcall(function()
        local xmlFile = loadXMLFile("sfMaterialDown", path)
        if xmlFile == nil then return end
        local day = getXMLInt(xmlFile, "materialDown#ageAppliedThroughDay")
        delete(xmlFile)
        if day ~= nil then
            materialDown:deserialize({ ageAppliedThroughDay = day })
        end
    end)
    if not ok then
        SoilLogger.warning("[MaterialDown] fallback load failed: %s", tostring(err))
    end
end
