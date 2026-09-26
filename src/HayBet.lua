-- =========================================================
-- FS25 Soil & Fertilizer - THE HAY BET (SF-44)
-- =========================================================
-- Grass cures by the sky into hay, spoils in the swath, and the
-- machines stop lying. One settle pass, one tedder interaction,
-- one read-time spoil verdict.
--
-- CONVERSION is gated on ENABLE_CONVERSION (false by default)
-- because the base-game confirm that changeFillTypeAtArea accepts
-- windrow height types is BOUNCED. When it lands, flip the flag.
-- Until then the settle pass only reads and reports, never writes.
--
-- SERVER ONLY. No new layer, no new store, no new state, no sync.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class HayBet
HayBet = HayBet or {}
local HayBet_mt = Class(HayBet)

-- The fit boundary: moisture at or below this threshold means the
-- grass is dry enough to cure as hay. Ruled 20% (raw 52).
HayBet.FIT_PCT       = 20
HayBet.FIT_RAW       = 52   -- math.floor(20 / 100 * 254) with brief's ruling
-- Tedder one-time drying delta: 8 percentage points (raw ~20).
-- Conservative edge of Pattey's published 15-30% acceleration.
HayBet.TED_DELTA_PCT = 8
HayBet.TED_DELTA_RAW = 20
-- Spoil threshold: how many separate rain-days before going-off.
-- Ruled 3 for hay.
HayBet.SPOIL_RAIN_DAYS = 3

-- CONVERSION GATE. Flip to true when the base-game confirm lands
-- that DensityMapHeightUtil.changeFillTypeAtArea accepts windrow
-- height types. Until then, the settle pass reads and reports but
-- never converts, and the tedder applies its drying delta without
-- the corrective pass.
HayBet.ENABLE_CONVERSION = false

-- =========================================================
-- Construction
-- =========================================================

function HayBet.new()
    local self = setmetatable({}, HayBet_mt)
    self.materialDown    = nil
    self.materialWetness = nil
    self.armed           = false
    -- Pending-corrections queue: flat vertex arrays enqueued by
    -- the tedder hook and drained at end of frame.
    self._correctionQueue = {}
    return self
end

---@param materialDown    MaterialDown
---@param materialWetness MaterialWetness
function HayBet:arm(materialDown, materialWetness)
    self.armed = false
    if materialDown == nil or not materialDown:isArmed() then
        SoilLogger.info("[HayBet] MaterialDown not armed - standing down")
        return false
    end
    if materialWetness == nil or not materialWetness:isArmed() then
        SoilLogger.info("[HayBet] MaterialWetness not armed - standing down")
        return false
    end
    self.materialDown    = materialDown
    self.materialWetness = materialWetness
    self.armed           = true
    SoilLogger.info("[OK] HayBet armed (fit=%d%%, ted-delta=%d%%, spoil=%d rain-days, conversion=%s)",
        HayBet.FIT_PCT, HayBet.TED_DELTA_PCT, HayBet.SPOIL_RAIN_DAYS,
        tostring(HayBet.ENABLE_CONVERSION))
    return true
end

function HayBet:isArmed()
    return self.armed
end

-- =========================================================
-- Settle pass (priority 10, before the age tick)
-- =========================================================
-- Called once per game day in the MEMBER_RESOLUTION slot. Reads
-- condition for active fields and converts grass to hay where
-- the grass is fit. The conversion write is gated on the
-- ENABLE_CONVERSION flag.

function HayBet:onSettle(ctx)
    if not self:isArmed() then return end
    if g_server == nil then return end

    local md = self.materialDown
    local mw = self.materialWetness
    if not md:isArmed() or not mw:isArmed() then return end

    -- [SF-49] The hay member reads the wetness layer to decide whether material is fit.
    -- A sentinel, unknown or refused condition always blocks conversion - the
    -- conservative direction.
    --
    -- [MAINTENANCE row 123] WHAT THE DAY COST. GROUND-CONDITION-CONTRACT section 5 asks for
    -- the dense-map worst case to be measured before the scheduling is settled, and this
    -- settle reads every field that holds tracked material in one call. So each settled
    -- day says, once, at info level: the fields visited, the engine reads the readers made
    -- (native volume reads and cell condition reads, counted in MaterialWetness), the
    -- whole settle's milliseconds by the engine's clock (getTimeSec, seconds, the clock
    -- the engine's own frame budgets use) and the costliest single field. The family is
    -- armed only with Experimental Systems on, so with the gate off nothing is logged.
    local clock = type(getTimeSec) == "function" and getTimeSec or nil
    local v0, c0 = MaterialWetness.nativeReads or 0, MaterialWetness.cellReads or 0
    local t0 = clock ~= nil and clock() or nil
    local fields, worst = 0, nil
    for _, fieldId in ipairs(self:_settleFieldIds(md, mw)) do
        local fv, fc = MaterialWetness.nativeReads or 0, MaterialWetness.cellReads or 0
        local ft = clock ~= nil and clock() or nil
        pcall(function()
            self:_settleField(fieldId, md, mw)
        end)
        local reads = ((MaterialWetness.nativeReads or 0) - fv) + ((MaterialWetness.cellReads or 0) - fc)
        local ms = ft ~= nil and (clock() - ft) * 1000 or 0
        fields = fields + 1
        if worst == nil or ms > worst.ms or (ms == worst.ms and reads > worst.reads) then
            worst = { fieldId = fieldId, reads = reads, ms = ms }
        end
    end
    local volume = (MaterialWetness.nativeReads or 0) - v0
    local cells = (MaterialWetness.cellReads or 0) - c0
    local total = t0 ~= nil and (clock() - t0) * 1000 or 0
    SoilLogger.info("[HayBet] settle cost: day %s, %d field(s), %d engine read(s) (%d volume, %d cell), %.2f ms; costliest field %s: %d read(s), %.2f ms",
        tostring(ctx ~= nil and ctx.monotonicDay or "?"), fields, volume + cells, volume, cells, total,
        worst ~= nil and tostring(worst.fieldId) or "none", worst ~= nil and worst.reads or 0, worst ~= nil and worst.ms or 0)
end

--- [RSF-F211] The fields to settle, ascending and once each: MaterialDown's active set
--- and the fields holding ground-membership cells. The active set is marked only by the
--- combine's straw birth and a save load, so a mown grass field never entered it and
--- the settle never reached one; the membership index (RSF-F213) is where the machines
--- record the material they put down.
function HayBet:_settleFieldIds(md, mw)
    local out, seen = {}, {}
    local function add(fieldId)
        if type(fieldId) == "number" and fieldId > 0 and not seen[fieldId] then
            seen[fieldId] = true
            out[#out + 1] = fieldId
        end
    end
    md:enumerateActiveFields(add)
    if type(mw.memberFieldIds) == "function" then
        for _, fieldId in ipairs(mw:memberFieldIds()) do add(fieldId) end
    end
    table.sort(out)
    return out
end

--- Process one active field on the settle pass.
---
--- [RSF-F211] The decision is a STANDING read: the GRASS_WINDROW actually lying inside
--- the field's polygons, each Soil cell weighted by its native volume and clipped to the
--- field (MaterialWetness:standingSnapshot / readStandingCondition). The old read took
--- a numeric getFillLevelAtArea over table entries (always an error) and an area mean
--- that weighted a thin wet strip like a heavy dry swath.
---@param fieldId number
---@param md MaterialDown
---@param mw MaterialWetness
function HayBet:_settleField(fieldId, md, mw)
    local polygons = self:_getFieldPolygons(fieldId)
    if not polygons then return end

    local grassFT = self:_fillTypeIndex("GRASS_WINDROW")
    if not grassFT then return end

    local snapshot, why = mw:standingSnapshot(grassFT, polygons)
    if snapshot == nil then
        SoilLogger.debug("[HayBet] settle: field %d standing read refused (%s)", fieldId, tostring(why))
        return
    end

    -- [FIND] Tracked material only: at least one of the grass cells carries an age
    -- record (the same materialAge layer the store's band read looked at, read on the
    -- cells the decision covers).
    local tracked = false
    for _, id in ipairs(snapshot.order) do
        local ageRaw = snapshot.parts[id].ageRaw
        if type(ageRaw) == "number" and ageRaw > 0 then tracked = true break end
    end
    if not tracked then return end

    -- [CONDITION READ] Only a complete, known, standing-basis answer can decide.
    local condition = mw:readStandingCondition(snapshot)
    if condition.status ~= MaterialWetness.RESULT.OK or condition.basis ~= MaterialWetness.BASIS.STANDING then return end
    if condition.pct > HayBet.FIT_PCT then return end

    -- [CONVERT] Gated on the bounced confirm
    if not HayBet.ENABLE_CONVERSION then return end

    local hayFT = self:_fillTypeIndex("DRYGRASS_WINDROW")
    if not hayFT then return end
    local coord = mw:groundCoordinator()
    if coord == nil then return end

    -- Over the cells the decision read, each through its own box (a general polygon is
    -- never passed as six parallelogram numbers).
    local changed = 0
    for _, id in ipairs(snapshot.order) do
        local p = snapshot.parts[id]
        local x0, z0, x1, z1 = coord:cellWorldBox(p.gx, p.gz)
        if x0 ~= nil then
            local ok, n = pcall(DensityMapHeightUtil.changeFillTypeAtArea, x0, z0, x1, z0, x0, z1, grassFT, hayFT)
            if ok and type(n) == "number" then changed = changed + n end
        end
    end
    SoilLogger.debug("[HayBet] settle convert: field %d, grass -> hay over %d cell(s), %.0f L (condition=%.1f%%)",
        fieldId, #snapshot.order, changed, condition.pct)
end

-- =========================================================
-- Fill type index (live, never cached)
-- =========================================================

--- [RSF-F211] Resolve a fill type name through the current mission's fill type manager
--- (FillTypeManager:getFillTypeIndexByName, fillTypes/FillTypeManager.lua:305), never
--- the fruit type manager, which has no such method. nil, UNKNOWN or a type the height
--- map cannot hold is unavailable. Not cached: an index is only good for the fill
--- registry it came from.
---@param name string  e.g. "GRASS_WINDROW"
---@return number|nil
function HayBet:_fillTypeIndex(name)
    local ftm = g_fillTypeManager
    if ftm == nil or type(ftm.getFillTypeIndexByName) ~= "function" then return nil end
    local ok, idx = pcall(ftm.getFillTypeIndexByName, ftm, name)
    if not ok or type(idx) ~= "number" then return nil end
    if not MaterialWetness.nativeTypeUsable(idx) then return nil end
    return idx
end

-- =========================================================
-- Field polygons (every field on the farmland)
-- =========================================================

--- [RSF-F211] The field's polygons as point tables, through the system's own farmland
--- resolution (SoilFertilitySystem:_getFarmlandPolygons, SF-52: every engine field on
--- the farmland, from g_fieldManager.fields and each field's polygon nodes). The old
--- lookup called g_fieldManager:getFieldByFarmlandId, which the engine does not have
--- (FieldManager.lua:387-396 offers getFieldById and getFields), and read field shapes
--- the engine's Field does not carry.
---@return table|nil polygons  { { {x=,z=}, ... }, ... }
function HayBet:_getFieldPolygons(fieldId)
    local mw = self.materialWetness
    local ss = mw ~= nil and mw.soilSystem or nil
    if ss == nil or type(ss._getFarmlandPolygons) ~= "function" then return nil end
    local ok, polygons = pcall(ss._getFarmlandPolygons, ss, fieldId)
    if not ok or type(polygons) ~= "table" or #polygons == 0 then return nil end
    return polygons
end

-- =========================================================
-- Tedder interaction (the drying delta + corrective queue)
-- =========================================================

--- Apply the tedder's one-time drying delta to the condition
--- layer over the given vertices. Clamps at the equilibrium
--- floor; the sentinel band passes through untouched.
---@param verts table  vertex array {{x=,z=}, ...}
---@return boolean applied
function HayBet:applyTedderDelta(verts)
    -- #verts is a COUNT OF VERTICES, not of numbers. The old guard read `< 6`, which
    -- was correct for a flat {x1,z1,...} array and silently rejects every polygon
    -- once the shape is {x=,z=} objects: a four-corner work area is length 4.
    if not self:isArmed() or not verts or #verts < 3 then return false end
    local mw = self.materialWetness
    if not mw:isArmed() then return false end

    -- Read the condition at the work area: a PROBE (RSF-F211), the machine asking
    -- what is under it; the delta it drives is not a material output.
    local condition = mw:probeCondition(verts)
    if condition.status ~= "ok" then return false end

    -- Apply the drying delta via a raw delta add on the condition
    -- (wetness) layer. The sentinel band (raw 1 to RAW_FLOOR-1) is
    -- excluded by the filter, so a refusal-conservative block is
    -- never dried lower than it already reads.
    local newPct = condition.pct - HayBet.TED_DELTA_PCT
    if newPct < 0 then newPct = 0 end

    -- The delta to apply: how many raw units to subtract
    local currentRaw = MaterialWetness.pctToRaw and MaterialWetness.pctToRaw(condition.pct) or math.floor(condition.pct * 2.54)
    local targetRaw = MaterialWetness.pctToRaw and MaterialWetness.pctToRaw(newPct) or math.floor(newPct * 2.54)
    local delta = currentRaw - targetRaw
    if delta <= 0 then return false end

    -- SCOPED TO THE WORKED AREA, not the whole layer. applyRawDeltaToLayer walks
    -- every pixel on the map, so the tedder was drying every swath in the world by
    -- eight points each time it passed over one of them. The brief says "over the
    -- worked area" and the polygon-banded call is the one that means it.
    -- THE EQUILIBRIUM FLOOR (SF-44: "clamps at the equilibrium floor; the sentinel
    -- passes through untouched"; row 106): the drying passes' own rule, the live sky's
    -- EMC ceiling and never inside the reserved band. A pixel the step would carry
    -- below it parks there; one already drier is left as it is. With no sky there is
    -- no EMC to read, and the floor is RAW_FLOOR, so the sentinel still stays untouched.
    local floorTo = MaterialWetness.RAW_FLOOR
    local sky = mw:readSky()
    if sky ~= nil then floorTo = math.max(MaterialWetness.emcRawFor(sky), MaterialWetness.RAW_FLOOR) end
    local applied = nil
    local ok = pcall(function()
        applied = mw.valueMaps:applyRawDeltaToPolygonBand(
            MaterialWetness.LAYER_KEY, verts, -delta,
            MaterialWetness.RAW_FLOOR, SoilValueMaps.RAW_MAX - 1,
            { floorTo = floorTo })
    end)
    return ok and applied ~= nil
end

--- Enqueue a work area's vertex list for the end-of-frame
--- corrective pass. The queue is drained by onUpdate.
---@param verts table  vertex array {{x=,z=}, ...}
function HayBet:enqueueCorrection(verts)
    if not verts or #verts < 3 then return end
    self._correctionQueue[#self._correctionQueue + 1] = verts
end

--- Drain the correction queue. For each enqueued area, check
--- the condition: where the material is NOT fit (still wet),
--- convert hay back to grass. This is the drop-then-correct
--- honesty gate.
--- Called at end of frame from the mod's update loop.
function HayBet:drainCorrectionQueue()
    if not self:isArmed() then return end
    if not HayBet.ENABLE_CONVERSION then
        -- Without conversion enabled, just clear the queue
        self._correctionQueue = {}
        return
    end
    if #self._correctionQueue == 0 then return end

    local mw = self.materialWetness
    local queue = self._correctionQueue
    self._correctionQueue = {}

    local grassFT = self:_fillTypeIndex("GRASS_WINDROW")
    local hayFT   = self:_fillTypeIndex("DRYGRASS_WINDROW")
    if not grassFT or not hayFT then return end

    for _, verts in ipairs(queue) do
        pcall(function()
            -- Read the condition for this correction area (a probe, RSF-F211)
            local condition = mw:probeCondition(verts)
            if condition.status ~= "ok" then return end
            -- Only correct if still wet (above fit)
            if condition.pct <= HayBet.FIT_PCT then return end

            -- Convert hay back to grass. start / width / height corners, read off
            -- the {x=,z=} vertices rather than a flat number pair.
            local sx, sz = verts[1].x, verts[1].z
            local wx, wz = verts[2].x, verts[2].z
            local hx, hz = verts[4] and verts[4].x or verts[3].x,
                           verts[4] and verts[4].z or verts[3].z
            DensityMapHeightUtil.changeFillTypeAtArea(
                sx, sz, wx, wz, hx, hz, hayFT, grassFT)
            SoilLogger.debug("[HayBet] corrective: hay -> grass (condition=%.1f%%)",
                condition.pct)
        end)
    end
end

-- =========================================================
-- Spoil verdict (read-time, never a write)
-- =========================================================

--- Derive the spoil verdict for a block of material: at read
--- time, check rain-days-down against the ruled count.
---
--- This is the hay member's contribution to the published read
--- surface. The verdicts are read at the same time as days-down
--- and condition.
---
---@param daysDown    number  full days the material has been lying
---@param rainDays    number  count of rain-days in that window
---@return string verdict  "fresh" | "goingOff" | "spoiled" | "unknown"
function HayBet:spoilVerdict(daysDown, rainDays)
    if type(daysDown) ~= "number" or daysDown < 0 then return "unknown" end
    if type(rainDays) ~= "number" or rainDays < 0 then return "unknown" end

    -- Insufficient data: the window is shorter than the spoil count
    if rainDays < HayBet.SPOIL_RAIN_DAYS then
        if rainDays == 0 then
            return "fresh"
        end
        return "unknown"   -- REFUSAL: not enough rain history to rule
    end

    return "goingOff"
end

-- =========================================================
-- End-of-frame update (drains the correction queue)
-- =========================================================

--- Called from the mod's update loop (FSBaseMission.update hook)
--- to drain the tedder's corrective queue at end of frame.
function HayBet:onUpdate()
    self:drainCorrectionQueue()
end

SoilLogger.info("HayBet (SF-44) loaded")
