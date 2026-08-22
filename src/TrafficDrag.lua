-- =====================================================================================
-- TrafficDrag.lua
-- -------------------------------------------------------------------------------------
-- SF-55 TRAFFIC ON WET GROUND: the pure arithmetic behind the trafficDrag layer. A
-- loaded wheel crossing wet ground bruises a standing crop, quietly worse at harvest.
-- The engine already destroys a standing crop outright under a moving, contacting
-- wheel (binary, WheelDestruction:update -> destroyFruitArea); this is the softer,
-- real case, recorded on SF-55's own bounded layer, composed read-only at SF-14's
-- harvest read, never written into yieldEfficiency (the second-writer fence).
--
-- Everything here is engine-free except the two thin engine-facing helpers
-- (resolveVehicleList / readStandingCrop / getMonotonicDay), so the bench can prove
-- the invariants without a terrain. The write-time machinery lives in
-- SoilFertilityManager:_checkVehicleCompaction (driving pass).
-- =====================================================================================

TrafficDrag = TrafficDrag or {}

-- -------------------------------------------------------------------------------------
-- WETNESS BLEND (Engineering confirm 2). SCS's field-level moisture (0..1, nil when
-- absent or untracked) and SF's rain-scalar fallback (0..1) are blended by MAX: either
-- signal saying "wet" is sufficient, and the max guarantees the SCS upgrade can never
-- make compaction behave DRIER than the calibrated rain-scaled baseline. When SCS is
-- absent the rain scalar is used exactly as today (byte-identical for the nil case).
-- -------------------------------------------------------------------------------------
function TrafficDrag.blendWetness(scsMoisture, rainScalar)
    if scsMoisture == nil then
        return rainScalar or 0
    end
    local r = rainScalar or 0
    if scsMoisture >= r then return scsMoisture end
    return r
end

-- -------------------------------------------------------------------------------------
-- BOUNDED ACCRUAL (the drag cap binds at write time, Steward invariant). current + delta
-- clamped to [0, cap]. A bruised cell is never a stuck state: the cap guarantees the
-- composed read at harvest never falls more than CAP off SF-14's captured value. A nil
-- current (unrecorded cell) reads as 0, so the first traffic event BIRTHS the record.
-- -------------------------------------------------------------------------------------
function TrafficDrag.accrue(current, delta, cap)
    local nextVal = (current or 0) + delta
    if nextVal < 0 then return 0 end
    if nextVal > cap then return cap end
    return nextVal
end

-- -------------------------------------------------------------------------------------
-- CELL KEY for the dedupe, on the same cell grid as onCompaction's precedent
-- (cell-and-day SHAPE only; the day SOURCE is corrected, see getMonotonicDay).
-- -------------------------------------------------------------------------------------
function TrafficDrag.cellKey(worldX, worldZ, cellSize)
    local s = cellSize or 10
    local cx = math.floor(worldX / s)
    local cz = math.floor(worldZ / s)
    return tostring(cx * 10000 + cz)
end

-- -------------------------------------------------------------------------------------
-- THE DAY SOURCE (brief section 7): TimeGuard's monotonicDay, NEVER
-- g_currentMission.environment.currentDay (the correction this design makes to the
-- onCompaction precedent it cites). Returns nil when TimeGuard is absent: the drag
-- accrual then stands down - no private clock is minted to fill the gap, matching the
-- suite's convention (MaterialDown / MaterialWetness). Verified: TimeGuard attaches as
-- g_currentMission.timeGuard (main.lua:41) and getContext returns monotonicDay
-- (TimeGuard.lua:273-285).
-- -------------------------------------------------------------------------------------
function TrafficDrag.getMonotonicDay()
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.getContext) ~= "function" then return nil end
    local ok, ctx = pcall(function() return tg:getContext() end)
    if not ok or type(ctx) ~= "table" then return nil end
    return tonumber(ctx.monotonicDay)
end

-- -------------------------------------------------------------------------------------
-- DEDUPE: cell-and-day key, once per cell per day. Fires when the key is not yet marked
-- for that day; marking is separate so the bench can assert the exact window.
-- -------------------------------------------------------------------------------------
function TrafficDrag.dedupeFired(dedupeTable, cellKey, day)
    if not dedupeTable then return false end
    return dedupeTable[cellKey] == day
end

function TrafficDrag.markDedupe(dedupeTable, cellKey, day)
    if not dedupeTable then dedupeTable = {} end
    dedupeTable[cellKey] = day
    return dedupeTable
end

-- -------------------------------------------------------------------------------------
-- THE F111 ENUMERATION SHAPE: every server-side vehicle. The codebase's established
-- list resolution (HookManager.lua:6831-6833): vehicleSystem.vehicles first, mission.
-- vehicles as the older-API fallback. Replaces getPlayerVehicle() - nil on a dedicated
-- server, single-vehicle on a listen server - as the source of which vehicle(s) the
-- pass considers.
-- -------------------------------------------------------------------------------------
function TrafficDrag.resolveVehicleList()
    return (g_currentMission ~= nil and g_currentMission.vehicleSystem
            and g_currentMission.vehicleSystem.vehicles) or
           (g_currentMission ~= nil and g_currentMission.vehicles) or {}
end

-- -------------------------------------------------------------------------------------
-- STANDING-CROP TEST (Engineering confirm 1): a crop present AND growing. Uses the
-- engine's point read FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z), which returns
-- (fruitTypeIndex, growthState) in one call - verified in-mod (GrowthCredit:412-419) and
-- in the LUADOC (CropRowAdjustedNodes.md:323). FieldState was the alternative but
-- RealisticWeather appends to FieldState.update (RW fields/FieldState.lua:27); this
-- point read is cheaper and sits outside RW's twelve named overwrites.
--
-- The drag gate is a strict subset of the engine's own destruction gate: destroyFruitArea
-- (WheelDestruction.lua:41 -> updateWheelDestructionArea) removes fruit under a contacting
-- wheel at ANY present growth state, so a cell the engine just emptied reads no crop and
-- the drag never fires into it. growthState >= MIN_STANDING_GROWTH_STATE excludes the
-- just-sown / just-harvested state-0 cells.
-- -------------------------------------------------------------------------------------
function TrafficDrag.isStandingCrop(fruitTypeIndex, growthState, minState)
    if type(fruitTypeIndex) ~= "number" then return false end
    if FruitType ~= nil and FruitType.UNKNOWN ~= nil and fruitTypeIndex == FruitType.UNKNOWN then
        return false
    end
    if type(growthState) ~= "number" then return false end
    return growthState >= (minState or 1)
end

function TrafficDrag.readStandingCrop(x, z)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.getFruitTypeIndexAtWorldPos) ~= "function" then
        return nil, nil
    end
    local ok, fruitIndex, state = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok or fruitIndex == nil or state == nil then return nil, nil end
    return fruitIndex, state
end

-- -------------------------------------------------------------------------------------
-- READ-TIME COMPOSITION (the SF-14 addendum, documented here and named on SF-14's
-- staged brief): effective = capturedEfficiency * (1 - trafficDrag). A cell with no drag
-- record (nil) composes as identity. This is the READ contract only; SF-55 never writes
-- yieldEfficiency, and SF-14's harvest read is the party that applies this. Not wired
-- here - until the addendum lands on SF-14's brief, trafficDrag persists correctly and
-- composes with nothing (a build-sequencing note, not a defect).
-- -------------------------------------------------------------------------------------
function TrafficDrag.composeRead(capturedEfficiency, trafficDrag)
    if trafficDrag == nil then return capturedEfficiency end
    return capturedEfficiency * (1 - trafficDrag)
end

SoilLogger.info("TrafficDrag loaded")
