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

    -- [SF-49] The hay member reads the wetness layer to decide
    -- whether material is fit. A sentinel or refused condition
    -- always blocks conversion - the conservative direction.
    md:enumerateActiveFields(function(fieldId)
        if type(fieldId) ~= "number" then return end
        pcall(function()
            self:_settleField(fieldId, md, mw)
        end)
    end)
end

--- Process one active field on the settle pass.
---@param fieldId number
---@param md MaterialDown
---@param mw MaterialWetness
function HayBet:_settleField(fieldId, md, mw)
    -- Get the field polygon from the field manager.
    local verts = self:_getFieldPolygon(fieldId)
    if not verts then return end

    -- [FIND] Check if material-age records exist in this field
    local mdOk, hasAge = pcall(function()
        return md.valueMaps:hasAnyInBand(
            MaterialDown.LAYER_KEY, verts, 1, 254)
    end)
    if not mdOk or not hasAge then return end

    -- Check if there is actual grass on the ground
    local grassFT  = self:_fillTypeIndex("GRASS_WINDROW")
    if not grassFT then return end
    local sx, sz = verts[1], verts[2]
    local wx, wz = verts[3], verts[4]
    local hx, hz = verts[5], verts[7]   -- third vertex = hx, fourth vertex Z = hz
    -- Actually use the correct vertices: bounding box {minX,minZ, maxX,minZ, maxX,maxZ, minX,maxZ}
    -- start = (minX, minZ), width = (maxX, minZ), height = (minX, maxZ)
    sx, sz = verts[1], verts[2]
    wx, wz = verts[3], verts[4]
    hx, hz = verts[7], verts[8]   -- minX, maxZ

    local fillOk, fillLevel = pcall(function()
        return DensityMapHeightUtil.getFillLevelAtArea(grassFT, sx, sz, wx, wz, hx, hz)
    end)
    if not fillOk or not fillLevel or fillLevel <= 0 then return end

    -- [CONDITION READ] Check if the grass is fit enough to cure
    local condition = mw:readCondition(verts, fillLevel)
    if condition.status ~= "ok" then return end
    if condition.pct > HayBet.FIT_PCT then return end

    -- [CONVERT] Gated on the bounced confirm
    if not HayBet.ENABLE_CONVERSION then return end

    local hayFT = self:_fillTypeIndex("DRYGRASS_WINDROW")
    if not hayFT then return end

    local convOk = pcall(function()
        DensityMapHeightUtil.changeFillTypeAtArea(
            sx, sz, wx, wz, hx, hz, grassFT, hayFT)
    end)
    if convOk then
        SoilLogger.debug("[HayBet] settle convert: field %d, grass -> hay (condition=%.1f%%)",
            fieldId, condition.pct)
    end
end

-- =========================================================
-- Fill type index cache
-- =========================================================

local _fillTypeCache = {}

--- Resolve a fill type name to its numeric index, cached.
---@param name string  e.g. "GRASS_WINDROW"
---@return number|nil
function HayBet:_fillTypeIndex(name)
    if _fillTypeCache[name] ~= nil then return _fillTypeCache[name] end
    local idx = g_fruitTypeManager and g_fruitTypeManager:getFillTypeIndexByName(name)
    _fillTypeCache[name] = idx
    return idx
end

-- =========================================================
-- Field polygon (from the field manager)
-- =========================================================

function HayBet:_getFieldPolygon(fieldId)
    if g_fieldManager == nil then return nil end
    local ok, field = pcall(function()
        return g_fieldManager:getFieldByFarmlandId(fieldId)
    end)
    if not ok or not field then return nil end
    local poly = field.polygon or (field.fieldPolygon and field.fieldPolygon.points)
    if not poly or #poly < 3 then return nil end

    -- THE OUTPUT IS {{x=,z=}, ...}, NOT A FLAT ARRAY. Every store method reads v.x
    -- and v.z; a flat array indexes a number inside the store's pcall, which used to
    -- be mistaken for "the engine has no polygon ops" and latched every aimed write
    -- in the mod off for the session. The store now refuses a malformed polygon
    -- without latching, but the shape still has to be right for anything to be read
    -- or written at all.
    --
    -- The source can arrive either way, so both are accepted and normalised here.
    local verts = {}
    if type(poly[1]) == "table" then
        for _, p in ipairs(poly) do
            if type(p.x) == "number" and type(p.z) == "number" then
                verts[#verts + 1] = { x = p.x, z = p.z }
            end
        end
    else
        for i = 1, #poly - 1, 2 do
            local x, z = poly[i], poly[i + 1]
            if type(x) == "number" and type(z) == "number" then
                verts[#verts + 1] = { x = x, z = z }
            end
        end
    end

    if #verts < 3 then return nil end
    return verts
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

    -- Read the condition at the work area
    local condition = mw:readCondition(verts, 1)
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
    local applied = nil
    local ok = pcall(function()
        applied = mw.valueMaps:applyRawDeltaToPolygonBand(
            MaterialWetness.LAYER_KEY, verts, -delta,
            MaterialWetness.RAW_FLOOR, SoilValueMaps.RAW_MAX - 1)
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
            -- Read the condition for this correction area
            local condition = mw:readCondition(verts, 1)
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
