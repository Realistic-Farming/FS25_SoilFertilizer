-- =========================================================
-- FS25 Soil & Fertilizer - Harvest Contract Underwrite (#741 / SF-29)
-- =========================================================
-- Closes player report #741 "Harvest missions will never reach 100%".
--
-- Root cause (certified at source): base-game field missions only validate on UNOWNED
-- fields (AbstractFieldMission:validate -> not field:getHasOwner()), so every harvest
-- contract runs on neighbour ground. That ground rolls a poor soil profile and is excluded
-- from the daily sim, so SF's yield modifier cuts the delivered liters. HarvestMission's
-- completion is liters-based (deposited / expected, anchored to the full-health vanilla
-- ceiling from getMaxCutLiters()), so the contract can be fully harvested and still stall
-- far below 100% (the reporter's save: 11420 / 35403 L ~ 32%). AbstractMission:updateTick
-- only calls finish(SUCCESS) once getCompletion() >= 0.995, so it never completes and never
-- pays.
--
-- SF-29 first shipped this by dividing the WHOLE completion by SF's yield modifier. That was
-- wrong (RSF-741): HarvestMission:getCompletion blends field-cut progress (80 percent for
-- grain, 50 for onion) with delivered-grain progress, so cutting a field without delivering
-- a litre could finish the contract. RSF-741 v1.13 with its v0.5 arming amendment repairs it:
--
--   * Field-cut progress is left exactly native. Only the delivered-grain component is
--     corrected, and only by the share SF's own reduction took: the healthy-versus-actual
--     material pair captured at the cutter and weighed through the Combine's own return
--     (items 4 to 9), carried by a record on the SF field that the mission lifecycle arms
--     (v0.5 item 3) and both save owners persist (item 10).
--   * corrected = vanilla + (1 - harvestCompletionFactor) * (sellCorrected - sellVanilla),
--     sellVanilla = min(deposited / expected / SUCCESS_FACTOR, 1), sellCorrected =
--     min(sellVanilla / appliedRatio, 1), clamped to [vanilla, 1] (items 12 to 15). No
--     delivery means no credit, however much has been cut.
--   * No soil, crop, yield, reward or farm-money value is written. Server-authoritative.
--     Every missing, faulted, stale or invalid input is vanilla passthrough (item 17).
--
-- Composes with the retained FieldSentry contract mask: orthogonal, no shared state. The
-- mask (isFieldSimDisabled) only skips the daily soil sim; it never touched the harvest
-- accounting. This does the opposite half and leaves the mask alone. (Bound 1 "the ground
-- lives" is deferred by design on this decoupled path - the field stays frozen as today; the
-- ground-lives behaviour arrives when the mask-flip ships with the NPC-soil drop.)
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class HarvestContractUnderwrite
HarvestContractUnderwrite = HarvestContractUnderwrite or {}

-- AbstractMission:updateTick finishes a mission SUCCESS at completion >= 0.995 (the base
-- game's own "99.5% shows as 100%" margin). We mirror it so the messaging fires exactly
-- when the underwrite is what carries the contract across that same line.
HarvestContractUnderwrite.SUCCESS_THRESHOLD = 0.995

-- Reference to our installed wrapper, so install() is idempotent and reload-safe without a
-- stale boolean: if the class method is no longer ours (e.g. uninstallAll restored the
-- original), install() re-wraps; if it is still ours, install() is a no-op.
HarvestContractUnderwrite._wrapper = nil

-- i18n helper with an English fallback. The notification key ships in translation_en.xml;
-- other languages fall back to English until a translation pass (the dialogs use the same
-- pattern for not-yet-localized keys).
local function tr(key, fallback)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        local t = g_i18n:getText(key)
        if t ~= nil and t ~= "" then return t end
    end
    return fallback or key
end

--- True when provenance can be trusted: every capture surface and the completion install
--- are live (item 9, set by HookManager:installHarvestUnderwrite).
function HarvestContractUnderwrite.isReady()
    return HarvestContractUnderwrite._captureReady == true
end

--- Corrected completion for a base-game harvest contract (RSF-741 items 11 to 17). Pure
--- apart from the one-shot notification, fail-safe, and never below vanilla or above 1.0.
---@param mission table   the HarvestMission instance (self)
---@param vanilla number  the mission's own getCompletion() result
---@return number completion
function HarvestContractUnderwrite.correct(mission, vanilla)
    if type(vanilla) ~= "number" then return vanilla end

    -- Master switch (server-side agronomy dial, no per-save setting).
    if not (SoilConstants and SoilConstants.HARVEST_UNDERWRITE
            and SoilConstants.HARVEST_UNDERWRITE.ENABLED) then
        return vanilla
    end

    -- Server-authoritative only. Clients mirror the synced completion; correcting there
    -- would double-apply.
    if g_server == nil then return vanilla end

    -- Already at (or past) success, or not a number we can reason about: nothing to do.
    if not HarvestContractUnderwrite._finite(vanilla) or vanilla >= 1.0 then return vanilla end

    -- Item 9: partial capture is not accepted.
    if not HarvestContractUnderwrite.isReady() then return vanilla end

    -- Item 11: the field key only LOCATES the SF record; the record itself must be armed,
    -- unfaulted and bound to this exact mission (saved uniqueId and fruit). No yield
    -- modifier is read and no freeze is consumed: the ratio is what the cutter measured.
    local field = mission.field
    local farmlandId = field and field.farmland and field.farmland.id
    if type(farmlandId) ~= "number" then return vanilla end
    local fruitTypeIndex = mission.fruitTypeIndex
    if type(fruitTypeIndex) ~= "number" or fruitTypeIndex <= 0 then return vanilla end
    local rec = HarvestContractUnderwrite.recordFor(mission)
    if rec == nil or rec.captureFault ~= false then return vanilla end
    local finite = HarvestContractUnderwrite._finite
    local pre, post = rec.preTotal, rec.postTotal
    if not (finite(pre) and pre > 0 and finite(post) and post >= 0) then return vanilla end
    local appliedRatio = post / pre
    -- Outside (0, 1) no degraded-yield underwrite is owed.
    if not (appliedRatio > 0 and appliedRatio < 1) then return vanilla end

    -- Item 17: every native input the correction reads must be present and valid; no
    -- default weight is invented.
    local expected, deposited = mission.expectedLiters, mission.depositedLiters
    local hcf = mission.harvestCompletionFactor
    local successFactor = HarvestMission and HarvestMission.SUCCESS_FACTOR
    if not (finite(expected) and expected > 0) then return vanilla end
    if not (finite(deposited) and deposited >= 0) then return vanilla end
    if not (finite(hcf) and hcf >= 0 and hcf <= 1) then return vanilla end
    if not (finite(successFactor) and successFactor > 0) then return vanilla end

    -- Items 12 to 15: correct only the delivered-grain component, at its native weight.
    local sellVanilla = math.min(deposited / expected / successFactor, 1)
    local sellCorrected = math.min(sellVanilla / appliedRatio, 1)
    local corrected = vanilla + (1 - hcf) * (sellCorrected - sellVanilla)
    if corrected < vanilla then corrected = vanilla end
    if corrected > 1.0 then corrected = 1.0 end

    -- Item 16: the one-shot notification, only when THIS correction carries the contract
    -- across the native success line while vanilla stays below it.
    if corrected >= HarvestContractUnderwrite.SUCCESS_THRESHOLD
       and vanilla < HarvestContractUnderwrite.SUCCESS_THRESHOLD
       and not mission._sfUnderwriteNotified then
        mission._sfUnderwriteNotified = true
        HarvestContractUnderwrite._notify(mission, field)
    end

    return corrected
end

--- Host-side one-shot notification to the contract's own farm. No-op on a dedicated server
--- (no local player) or when the notification API is absent. Guarded by the caller's pcall.
---@param mission table
---@param field table|nil
function HarvestContractUnderwrite._notify(mission, field)
    local cm = g_currentMission
    if cm == nil or cm.addIngameNotification == nil then return end

    local lp = g_localPlayer
    if lp == nil or lp.farmId ~= mission.farmId then return end

    local fieldId = (field and field.getId and field:getId()) or "?"
    local text = string.format(
        tr("sf_underwrite_notify",
           "Harvest contract topped up on field %s: degraded soil compensated to the expected yield."),
        tostring(fieldId))

    local icon = (FSBaseMission and FSBaseMission.INGAME_NOTIFICATION_OK) or nil
    if icon ~= nil then
        cm:addIngameNotification(icon, text)
    end
    if SoilLogger then
        SoilLogger.info("Harvest underwrite: contract on field %s topped up (mission %s)",
            tostring(fieldId), tostring(mission.uniqueId))
    end
end

-- =========================================================
-- RSF-741 v1.13 items 4 to 9: the capture surface
-- =========================================================
-- The underwrite is owed only on the delivered-grain share SoilFertilizer's own yield
-- reduction took away. That share is measured where the material is made, not guessed at
-- completion: every positive standing cut and pickup is BOUND to one mission at the work
-- area where its geometry exists, the cutter end turns one unanimous binding into a token,
-- and the existing Combine.addCutterArea wrapper weighs the healthy-versus-actual pair
-- through the Combine's own return. The record this feeds lives on the SoilFertilizer field
-- (fieldData[farmlandId].harvestUnderwriteProvenance), is armed by the mission lifecycle,
-- and is FAULTED, never guessed, whenever a step cannot be proven. A faulted, absent or
-- unready record leaves the contract exactly vanilla.
--
-- Everything here is server-side: the callers gate on the cutter's and combine's own
-- isServer, and a client's cutter ticks never create, change or fault a record.

-- Set by HookManager:installHarvestUnderwrite once the Combine wrapper, the standing capture
-- (inside the zone-yield processCutterArea wrapper), the pickup layer and the Cutter
-- start/end wrappers are all live. Item 9: partial capture is not accepted.
HarvestContractUnderwrite._captureReady = false
-- The one cutter-end token, alive only between the cutter end wrapper setting it and the
-- original end returning (the Combine call it feeds is synchronous inside that end).
HarvestContractUnderwrite._token = nil

local function finite(x)
    return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end
HarvestContractUnderwrite._finite = finite

function HarvestContractUnderwrite.setCaptureReady(ready)
    HarvestContractUnderwrite._captureReady = ready == true
end

local function soilSystem()
    local sfm = g_SoilFertilityManager
    return sfm and sfm.soilSystem
end

local function missionUid(mission)
    if type(mission.getUniqueId) == "function" then return mission:getUniqueId() end
    return mission.uniqueId
end

--- True for a base-game harvest contract (the class the underwrite serves).
function HarvestContractUnderwrite.isHarvestMission(mission)
    return type(mission) == "table" and HarvestMission ~= nil
        and type(mission.getMissionTypeName) == "function"
        and mission:getMissionTypeName() == HarvestMission.NAME
end

local function isRunning(mission)
    return type(mission.getIsRunning) == "function" and mission:getIsRunning() == true
end

--- The identity each path shipped with (v1.13 item 4): standing material is the mission's
--- FRUIT, matched to the cutter's post-call lastFruitType; pickup material is the mission's
--- FILL TYPE, matched to the cutter's post-call currentOutputFillType (pickup never writes
--- lastFruitType, Cutter.lua:669-705).
function HarvestContractUnderwrite.pathIdentity(mission, path)
    if path == "pickup" then return mission.fillTypeIndex end
    return mission.fruitTypeIndex
end

local function callIdentity(cutter, path)
    local spec = cutter.spec_cutter
    if spec == nil then return nil end
    if path == "pickup" then return spec.currentOutputFillType end
    return spec.workAreaParameters and spec.workAreaParameters.lastFruitType
end

--- The armed record bound to exactly this mission (same saved uniqueId and fruit), or nil.
--- Never creates a field record: a missing field stays vanilla (item 10).
function HarvestContractUnderwrite.recordFor(mission)
    local soil = soilSystem()
    local field = mission and mission.field
    local farmlandId = field and field.farmland and field.farmland.id
    if soil == nil or type(soil.fieldData) ~= "table" or type(farmlandId) ~= "number" then return nil end
    local fd = soil.fieldData[farmlandId]
    local rec = fd and fd.harvestUnderwriteProvenance
    if type(rec) ~= "table" or rec.armed ~= true then return nil end
    if rec.missionUniqueId == nil or rec.missionUniqueId ~= missionUid(mission) then return nil end
    if rec.fruitTypeIndex ~= mission.fruitTypeIndex then return nil end
    return rec
end

--- Fault the mission's armed record: the contract then stays vanilla for good. Never guesses.
function HarvestContractUnderwrite.fault(mission, reason)
    local rec = HarvestContractUnderwrite.recordFor(mission)
    if rec == nil or rec.captureFault == true then return false end
    rec.captureFault = true
    if SoilLogger then
        SoilLogger.info("Harvest underwrite: record for mission %s faulted (%s); that contract stays vanilla",
            tostring(rec.missionUniqueId), tostring(reason))
    end
    return true
end

local function faultRecord(rec, reason)
    if type(rec) ~= "table" or rec.captureFault == true then return end
    rec.captureFault = true
    if SoilLogger then
        SoilLogger.info("Harvest underwrite: record for mission %s faulted (%s); that contract stays vanilla",
            tostring(rec.missionUniqueId), tostring(reason))
    end
end
HarvestContractUnderwrite._faultRecord = faultRecord

local function missionList()
    local mm = g_missionManager
    if mm == nil then return {} end
    if type(mm.getMissions) == "function" then
        local ok, list = pcall(mm.getMissions, mm)
        if ok and type(list) == "table" then return list end
    end
    return type(mm.missions) == "table" and mm.missions or {}
end

--- The four positions native permission reads, in its order (WorkArea.lua onUpdateTick:
--- start, width, height, then the calculated fourth corner xw + (xh - xs), zw + (zh - zs)).
--- nil when any node cannot be read.
local function workAreaPoints(workArea)
    if type(workArea) ~= "table" or workArea.start == nil or workArea.width == nil or workArea.height == nil
        or type(getWorldTranslation) ~= "function" then
        return nil
    end
    local okS, xs, _, zs = pcall(getWorldTranslation, workArea.start)
    local okW, xw, _, zw = pcall(getWorldTranslation, workArea.width)
    local okH, xh, _, zh = pcall(getWorldTranslation, workArea.height)
    if not (okS and okW and okH) then return nil end
    if not (finite(xs) and finite(zs) and finite(xw) and finite(zw) and finite(xh) and finite(zh)) then return nil end
    return { { xs, zs }, { xw, zw }, { xh, zh }, { xw + (xh - xs), zw + (zh - zs) } }
end

--- Classify the missions found for one call. Exactly one identity match binds; several
--- matches fault those records; a running harvest mission found with the WRONG path
--- identity faults its record and never lets the call become non-mission.
local function classify(candidates, identity, path)
    local matches, wrong = {}, {}
    for _, m in ipairs(candidates) do
        if identity ~= nil and HarvestContractUnderwrite.pathIdentity(m, path) == identity then
            matches[#matches + 1] = m
        else
            wrong[#wrong + 1] = m
        end
    end
    for _, m in ipairs(wrong) do HarvestContractUnderwrite.fault(m, path .. " identity mismatch at the work area") end
    if #matches == 1 then return { kind = "mission", mission = matches[1] } end
    for _, m in ipairs(matches) do HarvestContractUnderwrite.fault(m, "ambiguous " .. path .. " binding") end
    return { kind = "fault" }
end

--- v1.13 item 4: bind one positive work-area call, where its geometry exists.
---@param cutter table   the cutter vehicle (server)
---@param workArea table the work area just processed
---@param path string    "standing" | "pickup"
---@return table binding { kind = "mission"|"fault"|"none", mission = m|nil }
function HarvestContractUnderwrite.bind(cutter, workArea, path)
    local farmId = nil
    if type(cutter.getActiveFarm) == "function" then
        local ok, f = pcall(cutter.getActiveFarm, cutter)
        if ok then farmId = f end
    end
    if farmId == nil then farmId = AccessHandler and AccessHandler.EVERYONE end
    local identity = callIdentity(cutter, path)

    -- Running harvest missions of the active farm. None at all is proof by itself: no map
    -- point, farmland or armed set can name a mission that is not running.
    local farmMissions = {}
    for _, m in ipairs(missionList()) do
        if HarvestContractUnderwrite.isHarvestMission(m) and isRunning(m) and m.farmId == farmId then
            farmMissions[#farmMissions + 1] = m
        end
    end
    if #farmMissions == 0 then return { kind = "none" } end

    local points = workAreaPoints(workArea)
    local mm = g_missionManager
    if points ~= nil and mm ~= nil and type(mm.getMissionAtWorldPosition) == "function" then
        local seen, found = {}, {}
        for _, p in ipairs(points) do
            local ok, m = pcall(mm.getMissionAtWorldPosition, mm, p[1], p[2])
            if ok and m ~= nil and not seen[m] and HarvestContractUnderwrite.isHarvestMission(m)
                and isRunning(m) and m.farmId == farmId then
                seen[m] = true
                found[#found + 1] = m
            end
        end
        if #found > 0 then return classify(found, identity, path) end
    end

    -- No mission at the points: the union of the four points' farmlands, scanned against
    -- each running mission's own field.farmland.id.
    local farmlands, nFarmlands = {}, 0
    local fm = g_farmlandManager
    if points ~= nil and fm ~= nil and type(fm.getFarmlandIdAtWorldPosition) == "function" then
        local notBuyable = FarmlandManager and FarmlandManager.NOT_BUYABLE_FARM_ID
        for _, p in ipairs(points) do
            local ok, id = pcall(fm.getFarmlandIdAtWorldPosition, fm, p[1], p[2])
            if ok and type(id) == "number" and id > 0 and id ~= notBuyable and not farmlands[id] then
                farmlands[id] = true
                nFarmlands = nFarmlands + 1
            end
        end
    end
    if nFarmlands > 0 then
        local found = {}
        for _, m in ipairs(farmMissions) do
            local id = m.field and m.field.farmland and m.field.farmland.id
            if id ~= nil and farmlands[id] then found[#found + 1] = m end
        end
        if #found > 0 then return classify(found, identity, path) end
        -- Geometry read and farmland named, and no running mission is there: proven non-mission.
        return { kind = "none" }
    end

    -- Geometry or farmland names nothing, so the call cannot be proven non-mission. Fault the
    -- armed records it could belong to (same farm, same path identity) when any exist.
    local faulted = false
    for _, m in ipairs(farmMissions) do
        if identity ~= nil and HarvestContractUnderwrite.pathIdentity(m, path) == identity
            and HarvestContractUnderwrite.recordFor(m) ~= nil then
            HarvestContractUnderwrite.fault(m, path .. " call with no readable geometry or farmland")
            faulted = true
        end
    end
    if faulted then return { kind = "fault" } end
    return { kind = "none" }
end

local function pending(cutter)
    local spec = cutter.spec_cutter
    if spec == nil then return nil end
    if spec._sf741 == nil then
        spec._sf741 = { healthyArea = 0, actualArea = 0, standing = {}, pickup = nil }
    end
    return spec._sf741
end

--- Cutter start (item 6): clear the pending material and bindings of the previous tick.
function HarvestContractUnderwrite.beginTick(cutter)
    local spec = cutter.spec_cutter
    if spec ~= nil then spec._sf741 = nil end
end

--- Standing cut (item 5), from inside the zone-yield processCutterArea wrapper, the one
--- place the native unscaled delta and the post-SF delta both exist. Every positive native
--- delta counts, whatever SF-14 did to it (no context, 1.0, fruit mismatch included).
---@param healthyDelta number the native lastMultiplierArea delta before SF scaling
---@param actualDelta number  the delta after SF scaling (equal when SF left it alone)
function HarvestContractUnderwrite.onStandingArea(cutter, workArea, healthyDelta, actualDelta)
    if HarvestContractUnderwrite._captureReady ~= true then return end
    if not (finite(healthyDelta) and healthyDelta > 0) then return end
    local p = pending(cutter)
    if p == nil then return end
    p.healthyArea = p.healthyArea + healthyDelta
    p.actualArea = p.actualArea + (finite(actualDelta) and actualDelta or 0)
    p.standing[#p.standing + 1] = HarvestContractUnderwrite.bind(cutter, workArea, "standing")
end

--- Pickup (item 5): the latest positive pickup call replaces the pending pickup identity;
--- its litres join the cutter end once, as engine lastLiters.
function HarvestContractUnderwrite.onPickup(cutter, workArea)
    if HarvestContractUnderwrite._captureReady ~= true then return end
    local p = pending(cutter)
    if p == nil then return end
    p.pickup = HarvestContractUnderwrite.bind(cutter, workArea, "pickup")
end

--- Cutter end (item 6): no spatial lookup. One unanimous mission matching its armed record
--- gets a token; disagreement faults every mission involved; otherwise no token.
---@return table|nil token
function HarvestContractUnderwrite.makeToken(cutter)
    if HarvestContractUnderwrite._captureReady ~= true then return nil end
    local spec = cutter.spec_cutter
    local wp = spec and spec.workAreaParameters
    if wp == nil or wp.combineVehicle == nil then return nil end
    local lastArea, lastLiters = wp.lastArea or 0, wp.lastLiters or 0
    if not (lastArea > 0 or lastLiters > 0) then return nil end
    local p = spec._sf741
    if p == nil then return nil end

    local bindings = {}
    for _, b in ipairs(p.standing) do bindings[#bindings + 1] = b end
    if lastLiters > 0 and p.pickup ~= nil then bindings[#bindings + 1] = p.pickup end

    local missions, seen, hasFault, hasNone = {}, {}, false, false
    for _, b in ipairs(bindings) do
        if b.kind == "mission" then
            if not seen[b.mission] then seen[b.mission] = true; missions[#missions + 1] = b.mission end
        elseif b.kind == "fault" then
            hasFault = true
        else
            hasNone = true
        end
    end
    if #missions == 0 then return nil end
    if #missions > 1 or hasFault or hasNone then
        for _, m in ipairs(missions) do HarvestContractUnderwrite.fault(m, "cutter end bindings disagree") end
        return nil
    end
    local mission = missions[1]
    local rec = HarvestContractUnderwrite.recordFor(mission)
    if rec == nil or rec.captureFault == true or not isRunning(mission) then return nil end
    return {
        combine          = wp.combineVehicle,
        mission          = mission,
        record           = rec,
        healthyArea      = p.healthyArea,
        actualArea       = wp.lastMultiplierArea or 0,   -- the exact value the engine converts
        lastLiters       = lastLiters,
        conversionFactor = spec.currentConversionFactor or 1,
    }
end

--- Combine side (items 7 and 8), BEFORE the original runs: take this combine's token, refuse
--- the non-linear additive branch, and recompute the actual litres from the token with the
--- LIVE Combine arguments (input fruit after Cutter's AI override). They must equal the live
--- litres, or the record is faulted. Returns the prepared weighting, or nil.
function HarvestContractUnderwrite.takeToken(combine, liters, inputFruitType, outputFillType)
    local token = HarvestContractUnderwrite._token
    if token == nil or token.combine ~= combine then return nil end
    HarvestContractUnderwrite._token = nil
    local rec = token.record

    local sc = combine.spec_combine
    local additives = sc and sc.additives
    if additives ~= nil and additives.available and type(additives.fillTypes) == "table" then
        for _, ft in ipairs(additives.fillTypes) do
            if ft == outputFillType then
                local ok, level = pcall(combine.getFillUnitFillLevel, combine, additives.fillUnitIndex)
                if not ok or not finite(level) or level > 0 then
                    faultRecord(rec, "active combine additive (non-linear yield)")
                    return nil
                end
            end
        end
    end

    local fm = g_fruitTypeManager
    if fm == nil or type(fm.getFruitTypeAreaLiters) ~= "function" then
        faultRecord(rec, "no fruit type manager at the Combine call")
        return nil
    end
    local cf = token.conversionFactor
    local actual = (fm:getFruitTypeAreaLiters(inputFruitType, token.actualArea, false) + token.lastLiters) * cf
    if not finite(actual) or not finite(liters) or math.abs(actual - liters) > 1e-9 then
        faultRecord(rec, "token litres do not match the live Combine litres")
        return nil
    end
    local healthy = (fm:getFruitTypeAreaLiters(inputFruitType, token.healthyArea, false) + token.lastLiters) * cf
    if not finite(healthy) or healthy < 0 then
        faultRecord(rec, "invalid healthy litres")
        return nil
    end
    return { record = rec, healthyLiters = healthy, liveLiters = liters }
end

--- Combine side, AFTER the original: a zero return is a normal skipped write (no totals, no
--- fault); a positive return weights the healthy litres by appliedDelta / liveLiters; a
--- negative or non-finite return faults.
function HarvestContractUnderwrite.recordApplied(prepared, applied)
    if prepared == nil then return end
    local rec = prepared.record
    if applied == 0 then return end
    if not finite(applied) or applied < 0 or not (prepared.liveLiters > 0) then
        faultRecord(rec, "invalid Combine return")
        return
    end
    local w = applied / prepared.liveLiters
    rec.preTotal = (rec.preTotal or 0) + prepared.healthyLiters * w
    rec.postTotal = (rec.postTotal or 0) + applied
    rec.cutCount = (rec.cutCount or 0) + 1
end

--- Combine side: the original raised. The token's record is faulted before the error travels on.
function HarvestContractUnderwrite.faultPrepared(prepared, reason)
    if prepared ~= nil then faultRecord(prepared.record, reason) end
end

-- =========================================================
-- RSF-741 v1.13 item 10: the record persists on the SoilFertilizer field
-- =========================================================
-- Seven flat keys, the same names on both save owners: XML attributes on the field node
-- (soilData.xml) and fields of the StateLedger projection entry. A key set that does not
-- describe a valid armed record is DISCARDED on load (absent = no record = vanilla), which
-- is also the meaning of an old save or ledger snapshot that has none of the keys. A stale
-- record is inert anyway: only a running mission with the same saved uniqueId and fruit
-- can consume it.
HarvestContractUnderwrite.KEYS = {
    "underwriteMissionUniqueId", "underwriteFruitTypeIndex", "underwriteArmed", "underwriteCaptureFault",
    "underwritePreTotal", "underwritePostTotal", "underwriteCutCount",
}

--- A record from the seven flat values, or nil when they do not describe a valid armed one.
function HarvestContractUnderwrite.recordFromFlat(src)
    if type(src) ~= "table" then return nil end
    local uid = src.underwriteMissionUniqueId
    local fruit = src.underwriteFruitTypeIndex
    local armed = src.underwriteArmed
    local fault = src.underwriteCaptureFault
    local pre, post, cuts = src.underwritePreTotal, src.underwritePostTotal, src.underwriteCutCount
    if type(uid) ~= "string" or uid == "" then return nil end
    if type(fruit) ~= "number" or fruit <= 0 or fruit ~= math.floor(fruit) then return nil end
    if armed ~= true or type(fault) ~= "boolean" then return nil end
    if not (finite(pre) and pre >= 0 and finite(post) and post >= 0) then return nil end
    if type(cuts) ~= "number" or cuts < 0 or cuts ~= math.floor(cuts) then return nil end
    -- No cut recorded yet means no material either way.
    if cuts == 0 and (pre ~= 0 or post ~= 0) then return nil end
    return { missionUniqueId = uid, fruitTypeIndex = fruit, armed = true, captureFault = fault,
             preTotal = pre, postTotal = post, cutCount = cuts }
end

--- Write a record's seven flat values into `out` (a ledger entry). Nothing for no record.
function HarvestContractUnderwrite.recordToFlat(rec, out)
    if type(rec) ~= "table" or type(out) ~= "table" then return end
    if HarvestContractUnderwrite.recordFromFlat({
        underwriteMissionUniqueId = rec.missionUniqueId, underwriteFruitTypeIndex = rec.fruitTypeIndex,
        underwriteArmed = rec.armed, underwriteCaptureFault = rec.captureFault == true,
        underwritePreTotal = rec.preTotal, underwritePostTotal = rec.postTotal, underwriteCutCount = rec.cutCount,
    }) == nil then
        return
    end
    out.underwriteMissionUniqueId = rec.missionUniqueId
    out.underwriteFruitTypeIndex  = rec.fruitTypeIndex
    out.underwriteArmed           = true
    out.underwriteCaptureFault    = rec.captureFault == true
    out.underwritePreTotal        = rec.preTotal
    out.underwritePostTotal       = rec.postTotal
    out.underwriteCutCount        = rec.cutCount
end

--- XML save owner: the seven attributes under the field node.
function HarvestContractUnderwrite.saveRecordXML(xmlFile, fieldKey, rec)
    local flat = {}
    HarvestContractUnderwrite.recordToFlat(rec, flat)
    if flat.underwriteMissionUniqueId == nil then return end
    setXMLString(xmlFile, fieldKey .. "#underwriteMissionUniqueId", flat.underwriteMissionUniqueId)
    setXMLInt(xmlFile, fieldKey .. "#underwriteFruitTypeIndex", flat.underwriteFruitTypeIndex)
    setXMLBool(xmlFile, fieldKey .. "#underwriteArmed", true)
    setXMLBool(xmlFile, fieldKey .. "#underwriteCaptureFault", flat.underwriteCaptureFault)
    setXMLFloat(xmlFile, fieldKey .. "#underwritePreTotal", flat.underwritePreTotal)
    setXMLFloat(xmlFile, fieldKey .. "#underwritePostTotal", flat.underwritePostTotal)
    setXMLInt(xmlFile, fieldKey .. "#underwriteCutCount", flat.underwriteCutCount)
end

--- XML load owner: a validated record, or nil.
function HarvestContractUnderwrite.loadRecordXML(xmlFile, fieldKey)
    return HarvestContractUnderwrite.recordFromFlat({
        underwriteMissionUniqueId = getXMLString(xmlFile, fieldKey .. "#underwriteMissionUniqueId"),
        underwriteFruitTypeIndex  = getXMLInt(xmlFile, fieldKey .. "#underwriteFruitTypeIndex"),
        underwriteArmed           = getXMLBool(xmlFile, fieldKey .. "#underwriteArmed"),
        underwriteCaptureFault    = getXMLBool(xmlFile, fieldKey .. "#underwriteCaptureFault"),
        underwritePreTotal        = getXMLFloat(xmlFile, fieldKey .. "#underwritePreTotal"),
        underwritePostTotal       = getXMLFloat(xmlFile, fieldKey .. "#underwritePostTotal"),
        underwriteCutCount        = getXMLInt(xmlFile, fieldKey .. "#underwriteCutCount"),
    })
end

--- Install the class-level getCompletion override on HarvestMission. Idempotent and
--- reload-safe. Wraps (does not replace) the base method: the vanilla completion is computed
--- first, unchanged, then the underwrite adds its correction on top under a pcall, so a bug
--- in the correction can never break the base mission (it falls back to the vanilla value).
---@param hookManager table|nil  optional HookManager, for uninstall bookkeeping
---@return boolean installed
function HarvestContractUnderwrite.install(hookManager)
    if HarvestMission == nil or type(HarvestMission.getCompletion) ~= "function" then
        if SoilLogger then
            SoilLogger.info("Harvest underwrite: HarvestMission.getCompletion unavailable - skipped")
        end
        return false
    end

    -- Already ours (installAll re-ran without an uninstall): nothing to do.
    if HarvestMission.getCompletion == HarvestContractUnderwrite._wrapper then
        return true
    end

    local original = HarvestMission.getCompletion
    local wrapper = function(missionSelf)
        local vanilla = original(missionSelf)
        local ok, corrected = pcall(HarvestContractUnderwrite.correct, missionSelf, vanilla)
        if ok and type(corrected) == "number" then
            return corrected
        end
        return vanilla
    end

    HarvestContractUnderwrite._wrapper = wrapper
    HarvestMission.getCompletion = wrapper

    if hookManager and hookManager.register then
        hookManager:register(HarvestMission, "getCompletion", original,
            "HarvestMission.getCompletion (contract underwrite #741)")
    end

    if SoilLogger then
        SoilLogger.info("[OK] Harvest contract underwrite installed (HarvestMission.getCompletion)")
    end
    return true
end
