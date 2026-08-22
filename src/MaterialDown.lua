-- =========================================================
-- FS25 Soil & Fertilizer - MATERIAL DOWN (SF-43)
-- =========================================================
-- The ground remembers how long cut material has been lying on it.
--
-- A farmer knows the swath went down Tuesday. Nothing in the game does. This adds
-- one 8-bit value-map layer holding HOW MANY DAYS material has lain at each spot,
-- aged by ONE filtered engine call per day, born when a machine is observed making
-- material, and cleared when the material genuinely leaves.
--
-- It makes NO farming rule of its own. The hay member reads it later and asks the
-- one question nothing else in the game can answer: how many days has this been
-- down - or refuses to say.
--
-- ENCODING (materialAge, minVal 0 / maxVal 254 so one raw step is exactly one day):
--   raw 0   = NO RECORD. Bare ground. Never ages into a record.
--   raw 1   = born today (0 full days down).
--   raw 255 = AT OR PAST THE CEILING. A REFUSAL TO RULE, never a value.
--
-- THE ONE DIRECTION THIS DESIGN FORBIDS is age looking FRESHER than it is. Every
-- rule below that seems fussy - the movement inheritance, the no-periodic-wipe
-- rule, the merge filter - exists to close a laundering path.
--
-- SERVER ONLY. The layer is excluded from MP sync and never allocated client-side
-- (SoilValueMaps asks 4+5, coupled). Bands cross to clients by event when the
-- reading surface ships; that surface is a later member and is not built here.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class MaterialDown
MaterialDown = MaterialDown or {}
local MaterialDown_mt = Class(MaterialDown)

MaterialDown.LAYER_KEY = "materialAge"

-- Every layer key this PACKAGE (SF-43 + its sibling SF-49) owns. The bind-time
-- self-check asserts each one resolves before the system arms. The sibling appends
-- its wetness key here when it builds; until then this list is correct at one entry.
MaterialDown.PACKAGE_LAYER_KEYS = { "materialAge" }

local RAW_NO_RECORD = 0
local RAW_BORN      = 1
local RAW_CEILING   = 255   -- SoilValueMaps.RAW_MAX; asserted against it at arm()

-- [SF-45] THE TRACKED MATERIAL SET - the configuration that gates birth-by-
-- observation. Engine fill-type NAMES, verified at source.
--
-- The layers themselves are material-blind by design, which is the whole point:
-- adding a second crop to this programme costs ONE ENTRY here plus whatever numbers
-- its own reader needs, and birth, ageing, condition, movement inheritance and the
-- collector's refusal-honest read then cover it automatically. STRAW is that
-- receipt - it joined for one line.
--
-- Any straw-specific MACHINERY (as opposed to a row) re-opens governance by
-- definition. If you find yourself adding a branch here, stop.
MaterialDown.TRACKED_MATERIALS = {
    GRASS_WINDROW    = true,   -- cut grass, the foundation's first material
    DRYGRASS_WINDROW = true,   -- hay: the cured form of that same swath
    STRAW            = true,   -- [SF-45] the second crop, and its entire build
    MEADOW_WINDROW   = true,   -- cut meadow grass (RULED 2026-07-31); see note below
}

-- NOTE ON MEADOW_WINDROW, because it is the one key here that is NOT an engine
-- fill type name and a later reader will otherwise "correct" it back out.
--
-- FS25 ships exactly three windrow fill types: GRASS_WINDROW, DRYGRASS_WINDROW and
-- a generic WINDROW. Mowing a meadow drops GRASS_WINDROW, by the converter at
-- maps_fruitTypes.xml:61 (from="MEADOW" to="GRASS_WINDROW"). There is no
-- MEADOW_WINDROW anywhere in the engine.
--
-- The birth gate never sees that fill type. It is handed a name SYNTHESIZED from
-- the FRUIT type by fruitTypeToWindrowName (HookManager.lua:115-119), which builds
-- FRUITNAME .. "_WINDROW", so mowing a meadow arrives here as "MEADOW_WINDROW".
-- This row is what admits it. Without the row, meadow mowing is refused at birth,
-- which is the 396-tracked-against-86-not-tracked split the live test produced.
--
-- This is SAFE because the name is used at the gate ONLY: noteMaterialAt tests it
-- and then writes an age band to a material-blind layer, so "MEADOW_WINDROW" is
-- never persisted and never read back. Spoilage (MaterialWetness) and the hay
-- member resolve the material at COLLECTION time from the fill type actually
-- picked up, which is the real GRASS_WINDROW and already has its rules.

---@param fillTypeName string|nil  engine fill-type name
---@return boolean tracked
function MaterialDown.isTrackedMaterial(fillTypeName)
    if fillTypeName == nil then return false end
    return MaterialDown.TRACKED_MATERIALS[tostring(fillTypeName):upper()] == true
end

-- Land type under observed material. All four AGE IDENTICALLY in v1 - material
-- lying out is weather, not soil simulation, which is exactly why sim-disabled
-- ground still counts. The branch exists because the consuming members
-- differentiate (grassland rules differ from arable), so the fact is captured at
-- birth rather than re-derived later against a field record that may have changed.
MaterialDown.LAND = {
    NORMAL       = 1,
    MEADOW       = 2,
    SIM_DISABLED = 3,
    NO_RECORD    = 4,   -- no field record under this position
}

-- Publication result status. Two named neutrals, per the v1 wire contract.
MaterialDown.RESULT = {
    OK          = "ok",           -- days is an exact integer
    NO_RECORD   = "noRecord",     -- nothing has been observed lying here
    CEILING     = "ceiling",      -- at or past the ceiling: we refuse to rule
    UNAVAILABLE = "unavailable",  -- layer absent, not armed, or not the server
}

-- Days-down publication bands. The day count is exact (it is a counter, not an
-- estimate), so it is published alongside; the band is what a reading surface
-- should lead with so nobody reads spurious precision into a number that only
-- moves once per day.
-- floor = the lowest day count in the band.
MaterialDown.BANDS = {
    { name = "veryOld",  floor = 60 },
    { name = "old",      floor = 30 },
    { name = "ageing",   floor = 14 },
    { name = "week",     floor = 7  },
    { name = "settling", floor = 4  },
    { name = "recent",   floor = 2  },
    { name = "fresh",    floor = 0  },
}

-- VALIDATION SWEEP ARMING. The four-quadrant presence rule's ratios are a bounced
-- confirm (SF-43 section 6, the numbers pass) and the base game's bunker 0.5 is
-- explicitly REJECTED as a default - a windrow's covered fraction never reaches
-- half. The mechanism below is built and testable, but it runs in REPORT-ONLY mode
-- until a real ratio lands, because clearing on a guessed threshold destroys
-- records that no later pass can reconstruct. Flip this when the numbers arrive.
MaterialDown.VALIDATION_ARMED = false
MaterialDown.PLACEHOLDER_PRESENCE_RATIO = 0.15   -- PLACEHOLDER, not a ruled number

-- =========================================================
-- Construction
-- =========================================================

function MaterialDown.new()
    local self = setmetatable({}, MaterialDown_mt)
    self.armed     = false
    self.valueMaps = nil
    -- Persisted watermark: the last game day whose age tick has been applied.
    -- Belt and braces against the scheduler's per-accrual retry (a throw AFTER the
    -- add would otherwise re-add map-wide on the next tick).
    self.ageAppliedThroughDay = nil
    -- Object ledger MECHANISM (built here, consumed by the bale member later).
    -- Keyed on an OPAQUE OWNER TOKEN; enumerate-not-list. NO rows in v1.
    self.objects   = {}
    -- [SF-49] Fields currently carrying a record, as a set. The sibling's drying
    -- pass needs per-field geometry (soil class is a per-field property), and
    -- probing every field on the map once a day to find the two that have a swath
    -- on them is the wrong shape. Maintained by the same calls that write the layer,
    -- so it costs nothing extra and cannot drift from the writes it mirrors.
    self.activeFields = {}
    self.stoodDown = false   -- true once a fence refused; the layer is inert
    return self
end

-- =========================================================
-- Bind-time self-check
-- =========================================================
-- The community fork declares the same SoilValueMaps global with byte-identical
-- filenames and NONE of our defs. Every store method returns early and SILENTLY
-- when a key is unknown, so without this check the whole system would look healthy
-- while recording nothing at all. Refuse to arm, loudly, exactly once.
--
-- Must run after every candidate has loaded AND after SoilValueMaps:initialize.
---@return boolean armed
function MaterialDown:arm(valueMaps)
    self.armed = false
    self.valueMaps = nil

    if g_server == nil then
        -- Not an error: the layer is server-only by design. Stay silently inert.
        return false
    end
    if valueMaps == nil or not valueMaps.available then
        SoilLogger.warning("[MaterialDown] value maps unavailable - MATERIAL DOWN stands down")
        return false
    end
    if valueMaps.applyRawDeltaToLayer == nil or valueMaps.setPolygonWhere == nil
       or valueMaps.hasAnyInBand == nil or valueMaps.readRawAtWorld == nil then
        SoilLogger.warning(
            "[MaterialDown] the SoilValueMaps in scope has none of the SF-43 methods - this is the " ..
            "community-fork collision (same global, same filenames, different code). MATERIAL DOWN stands down.")
        return false
    end
    if SoilValueMaps.RAW_MAX ~= RAW_CEILING then
        SoilLogger.warning("[MaterialDown] RAW_MAX is %s, expected %d - MATERIAL DOWN stands down",
            tostring(SoilValueMaps.RAW_MAX), RAW_CEILING)
        return false
    end

    for _, key in ipairs(MaterialDown.PACKAGE_LAYER_KEYS) do
        if valueMaps:getLayerEntry(key) == nil then
            SoilLogger.warning(
                "[MaterialDown] package layer '%s' did not resolve - MATERIAL DOWN stands down " ..
                "(every store call would no-op silently, so an inert system is the honest state)", key)
            return false
        end
    end

    self.valueMaps = valueMaps
    self.armed     = true
    self.stoodDown = false
    SoilLogger.info("[OK] MaterialDown armed (%d package layer(s), server-only)",
        #MaterialDown.PACKAGE_LAYER_KEYS)
    return true
end

function MaterialDown:isArmed()
    return self.armed and not self.stoodDown
end

-- Called by any fence that refuses. Once inert, the system stays inert for the
-- session rather than retrying a call that already proved it would fabricate.
function MaterialDown:_standDown(why)
    if self.stoodDown then return end
    self.stoodDown = true
    SoilLogger.warning("[MaterialDown] STANDING DOWN for this session: %s", tostring(why))
end

--- THE VERTEX SHAPE GATE, and it sits here rather than at the store on purpose.
---
--- Standing down is for a store that cannot do the work. It is NOT for a caller that
--- asked badly, and those two used to be the same event: every refused aimed write
--- assumed "polygon ops unavailable" and killed the layer for the session. So one
--- caller passing a flat {x1,z1,...} array instead of {{x=,z=},...} cost the whole
--- system, because indexing a number raises inside the store's pcall and the store
--- read that as an engine verdict.
---
--- Checking the shape BEFORE the call keeps both behaviours honest: rubbish never
--- reaches the store, and a refusal that comes back from a well-formed call really is
--- the fabrication fence firing, which must still stand the system down.
---@return boolean valid
function MaterialDown._isValidPolygon(verts)
    if type(verts) ~= "table" or #verts < 3 then return false end
    for i = 1, #verts do
        local v = verts[i]
        if type(v) ~= "table" or type(v.x) ~= "number" or type(v.z) ~= "number" then
            return false
        end
    end
    return true
end

--- Refuse a malformed polygon loudly, without disarming anything.
---@return boolean false, always
function MaterialDown:_refuseShape(where)
    SoilLogger.warning(
        "[MaterialDown] %s got a malformed polygon (expected {{x=,z=},...}) and refused it. " ..
        "The layer stays armed: this is a caller bug, not a store failure.", tostring(where))
    return false
end

-- =========================================================
-- The tick (Time Guard, day cadence)
-- =========================================================

--- The age accrual body. ONE engine call on the ordinary path, by construction:
--- at rawDelta 1 the saturating window in applyRawDeltaToLayer is empty.
---
--- The guard window excludes raw 0 (bare ground never ages into a record) and
--- raw 255 (a saturated pixel stops counting - the refusal is terminal).
---
--- ctx.proration is IGNORED, deliberately: a +1 raw add has no meaningful fraction,
--- and both accruals register with firstPeriodPolicy="skip" so no partial first
--- period is ever settled. A non-increasing ctx.monotonicDay is a no-op.
function MaterialDown:onAgeTick(ctx)
    if not self:isArmed() then return end

    local day = ctx and tonumber(ctx.monotonicDay)
    -- The scheduler's getter falls back to 0 rather than nil, so a missing clock
    -- reads as day 0 and simply never advances the watermark.
    if day == nil then return end

    -- IDEMPOTENCY. The scheduler retries a failed accrual with the SAME
    -- boundariesCrossed, so a throw after the add would re-add across the whole
    -- map. The watermark is checked before any add and persisted after it.
    if self.ageAppliedThroughDay ~= nil and day <= self.ageAppliedThroughDay then
        return
    end

    local boundaries = math.floor(tonumber(ctx.boundariesCrossed) or 1)
    if boundaries < 1 then boundaries = 1 end

    -- CATCH-UP is the same call with a larger delta plus the saturating second
    -- pass; applyRawDeltaToLayer owns both, and both are flat in area.
    local applied = self.valueMaps:applyRawDeltaToLayer(
        MaterialDown.LAYER_KEY, boundaries, RAW_BORN, RAW_CEILING - 1)

    if applied == nil then
        -- THE FABRICATION FENCE fired: executeAdd is unavailable or failed. The
        -- store refused rather than falling back to the block-walk that would
        -- invent records on bare ground. Honestly inert beats quietly inventing.
        self:_standDown("the aimed delta was refused by the store (see the SoilValueMaps warning above)")
        return
    end

    self.ageAppliedThroughDay = day
end

--- Everything that is NOT the age tick: the validation sweep and publication
--- bookkeeping. Separated so the tick above can stay a single engine call and
--- therefore cannot throw after its own add.
function MaterialDown:onMaintenanceTick(ctx)
    if not self:isArmed() then return end
    self:runValidationSweep()
end

-- =========================================================
-- Birth, movement, clearing
-- =========================================================

--- Resolve the land type under a position.
---
--- OPEN CONFIRM (SF-43 section 6): the no-fieldId lookup form on ground with no
--- field record. Until that is settled we return NO_RECORD and still record the
--- age, because material lying on unregistered ground is still material lying out.
function MaterialDown:resolveLandType(fieldId)
    if fieldId == nil then return MaterialDown.LAND.NO_RECORD end
    if FieldSentry_API == nil or FieldSentry_API.isFieldSimDisabled == nil then
        -- Neutral when absent: FieldSentry is optional, so an absent sentry means
        -- "ordinary field", never "do not record".
        return MaterialDown.LAND.NORMAL
    end
    local ok, disabled, _, meadow = pcall(FieldSentry_API.isFieldSimDisabled, fieldId)
    if not ok then return MaterialDown.LAND.NORMAL end
    if meadow  then return MaterialDown.LAND.MEADOW end
    -- Sim-disabled ground STILL AGES: lying out is weather, not soil simulation.
    if disabled then return MaterialDown.LAND.SIM_DISABLED end
    return MaterialDown.LAND.NORMAL
end

--- BIRTH. Material observed in `verts` with no record yet is dated today (raw 1).
---
--- The [0,0] band is the merge rule: a pixel that already carries an age is outside
--- the filter, so arriving material can NEVER lower an existing age. There is no
--- read-compare-write here and therefore nothing to race.
---
--- A machine we failed to observe leaves an UNRECORDED patch, which is a gap in
--- knowledge, not a defect - the read refuses on raw 0 rather than guessing.
--- [SF-45] `fillTypeName` gates the write against the tracked set. Passing a
--- material that is not tracked REFUSES: chaff behind a combine is not a swath, and
--- recording it would age something no member will ever read.
---
--- nil means the caller made no claim about the material, which is allowed and
--- records. The observation hook always knows its fill type and will always pass
--- one, so the gate bites where it matters; nil exists for callers that genuinely
--- only know "material is here" and for the bench.
---@return boolean recorded
function MaterialDown:noteMaterialAt(verts, fieldId, fillTypeName)
    if not self:isArmed() then return false end
    if not MaterialDown._isValidPolygon(verts) then
        return self:_refuseShape("noteMaterialAt")
    end
    if fillTypeName ~= nil and not MaterialDown.isTrackedMaterial(fillTypeName) then
        return false
    end
    local landType = self:resolveLandType(fieldId)
    local ok = self.valueMaps:setPolygonWhere(
        MaterialDown.LAYER_KEY, verts, RAW_BORN, RAW_NO_RECORD, RAW_NO_RECORD)
    if not ok then
        self:_standDown("the aimed write was refused by the store (polygon ops unavailable)")
        return false
    end
    self:markFieldActive(fieldId)
    return true, landType
end

--- MOVEMENT INHERITANCE - the anti-laundering rule. Skipping this defeats the
--- whole feature.
---
--- A tedder or windrower DROPS material into a different work area than it picks
--- up from, so most destinations have no record and would be born today. Raking a
--- week-old row would make it read fresh, which is precisely the direction this
--- design forbids.
---
--- RULE: a birth inside a movement operation inherits the SOURCE area's OLDEST
--- RECORDED BAND, probed downward band by band with the filtered-executeGet idiom.
---
---   * The CEILING band is probed FIRST. If any source pixel is at the ceiling the
---     destination inherits the ceiling too, so the refusal propagates rather than
---     collapsing into a number.
---   * The inherited value is the band's FLOOR, so it is an age some real pixel in
---     the source actually held. Never the average: an average invents an age no
---     pixel ever had, which is why readAverageOfPolygon is forbidden here.
---   * A source area with no record at all births today, correctly.
---@return boolean recorded
function MaterialDown:noteMaterialMoved(srcVerts, dstVerts, fieldId, fillTypeName)
    if not self:isArmed() then return false end
    if not MaterialDown._isValidPolygon(dstVerts) then
        return self:_refuseShape("noteMaterialMoved (destination)")
    end
    if fillTypeName ~= nil and not MaterialDown.isTrackedMaterial(fillTypeName) then
        return false
    end
    if not MaterialDown._isValidPolygon(srcVerts) then
        -- No usable source area: a birth, correctly, not a laundering path.
        return self:noteMaterialAt(dstVerts, fieldId, fillTypeName)
    end

    local vm = self.valueMaps

    -- The ceiling first, so a refusal propagates instead of being averaged away.
    local atCeiling = vm:hasAnyInBand(MaterialDown.LAYER_KEY, srcVerts, RAW_CEILING, RAW_CEILING)
    if atCeiling == nil then
        self:_standDown("the band probe was refused by the store (polygon ops unavailable)")
        return false
    end
    local inheritRaw = nil
    if atCeiling then
        inheritRaw = RAW_CEILING
    else
        for _, band in ipairs(MaterialDown.BANDS) do
            -- floor is in DAYS; raw = days + 1 because raw 1 is day 0.
            local bandLowRaw  = math.max(RAW_BORN, band.floor + 1)
            local bandHighRaw = RAW_CEILING - 1
            if inheritRaw == nil and bandLowRaw <= bandHighRaw then
                local present = vm:hasAnyInBand(MaterialDown.LAYER_KEY, srcVerts, bandLowRaw, bandHighRaw)
                if present == nil then
                    self:_standDown("the band probe was refused by the store (polygon ops unavailable)")
        return false
                end
                if present then inheritRaw = bandLowRaw end
            end
        end
    end

    -- No record anywhere in the source: this material is genuinely new here.
    if inheritRaw == nil then inheritRaw = RAW_BORN end

    local ok = vm:setPolygonWhere(
        MaterialDown.LAYER_KEY, dstVerts, inheritRaw, RAW_NO_RECORD, RAW_NO_RECORD)
    if not ok then
        self:_standDown("the aimed write was refused by the store (polygon ops unavailable)")
        return false
    end
    self:markFieldActive(fieldId)
    return true
end

--- CLEARING. Only where the material genuinely left, and only through the aimed
--- filter. There is NO periodic wipe anywhere in this system, ever: clearing to
--- raw 0 lets BIRTH re-date the pixel as today, which launders age in the one
--- direction the design forbids.
---@return boolean cleared
--- `fieldId` is optional and only drops the field from the active set; pass it when
--- the caller knows the field is now empty. Omitting it leaves the field active,
--- which costs a few wasted drying calls but never loses a record - the forgiving
--- direction.
function MaterialDown:noteMaterialGone(verts, fieldId)
    if not self:isArmed() then return false end
    if not MaterialDown._isValidPolygon(verts) then
        return self:_refuseShape("noteMaterialGone")
    end
    local ok = self.valueMaps:clearPolygonWhere(
        MaterialDown.LAYER_KEY, verts, RAW_BORN, RAW_CEILING)
    if not ok then
        self:_standDown("the filtered clear was refused by the store (polygon ops unavailable)")
        return false
    end
    self:markFieldClear(fieldId)
    return true
end

-- =========================================================
-- Validation sweep
-- =========================================================

--- Presence re-read against the engine: a record whose material is no longer there
--- should not keep ageing. See VALIDATION_ARMED above - the four-quadrant rule's
--- ratios are a bounced confirm, so this reports rather than clears until they land.
--- totalPixels == 0 is a no-op, not a clear.
function MaterialDown:runValidationSweep()
    if not self:isArmed() then return end
    if not MaterialDown.VALIDATION_ARMED then
        SoilLogger.debug(
            "[MaterialDown] validation sweep is REPORT-ONLY: the four-quadrant presence ratios are " ..
            "still a bounced confirm (the base game's bunker 0.5 is rejected as a default)")
        return
    end
    -- Intentionally unreachable until the numbers pass lands. The clearing half
    -- goes through noteMaterialGone so it can only ever use the aimed filter.
    SoilLogger.debug("[MaterialDown] validation sweep armed at ratio %.2f",
        MaterialDown.PLACEHOLDER_PRESENCE_RATIO)
end

-- =========================================================
-- Publication (v1's whole wire contract)
-- =========================================================

--- Band descriptor for an exact day count.
function MaterialDown.bandForDays(days)
    for _, band in ipairs(MaterialDown.BANDS) do
        if days >= band.floor then return band.name end
    end
    return MaterialDown.BANDS[#MaterialDown.BANDS].name
end

--- DAYS-DOWN at a world position, server-computed, with the two named neutrals.
---
--- This is the entire published surface in v1. Water-days and unknown-days arrive
--- with the sibling member; the object band arrives with the bale member.
---@return table result  { status, days, band } - days/band only when status == OK
function MaterialDown:getDaysDownAt(worldX, worldZ)
    local R = MaterialDown.RESULT
    if not self:isArmed() then return { status = R.UNAVAILABLE } end

    local raw = self.valueMaps:readRawAtWorld(MaterialDown.LAYER_KEY, worldX, worldZ)
    if raw == nil then return { status = R.UNAVAILABLE } end
    if raw <= RAW_NO_RECORD then return { status = R.NO_RECORD } end
    if raw >= RAW_CEILING then return { status = R.CEILING } end

    local days = raw - RAW_BORN   -- raw 1 is born today = 0 full days down
    return { status = R.OK, days = days, band = MaterialDown.bandForDays(days) }
end

-- =========================================================
-- Object ledger MECHANISM (no rows in v1)
-- =========================================================
-- Built here, consumed by the bale member later. Keyed on an OPAQUE OWNER TOKEN so
-- this system never needs to understand what the owner is, and enumerate-not-list
-- so no caller can take a reference to the live table and mutate it behind us.

--- [SF-49] Iterate the fields that currently carry a record. Enumerate-not-list so
--- no caller can take a reference to the live set and mutate it behind us.
function MaterialDown:enumerateActiveFields(fn)
    if type(fn) ~= "function" then return 0 end
    local n = 0
    for fieldId in pairs(self.activeFields) do
        fn(fieldId)
        n = n + 1
    end
    return n
end

function MaterialDown:markFieldActive(fieldId)
    if fieldId == nil then return end
    self.activeFields[fieldId] = true
end

function MaterialDown:markFieldClear(fieldId)
    if fieldId == nil then return end
    self.activeFields[fieldId] = nil
end

function MaterialDown:setObjectRecord(token, record)
    if token == nil then return false end
    self.objects[tostring(token)] = record
    return true
end

function MaterialDown:getObjectRecord(token)
    if token == nil then return nil end
    return self.objects[tostring(token)]
end

--- CREATE, the shape SF-46 specified as the mechanism's first consumer.
---
--- The difference from setObjectRecord is the whole point of having both: create
--- REFUSES an existing token. An owner minting a token it believes is fresh must not
--- be able to overwrite a row it cannot see, because the ledger is enumerate-not-list
--- and a silent clobber there is unobservable until the save is already wrong.
function MaterialDown:createObjectRecord(token, record)
    if token == nil or record == nil then return false end
    local key = tostring(token)
    if self.objects[key] ~= nil then return false end
    self.objects[key] = record
    return true
end

function MaterialDown:removeObjectRecord(token)
    if token == nil then return false end
    if self.objects[tostring(token)] == nil then return false end
    self.objects[tostring(token)] = nil
    return true
end

function MaterialDown:enumerateObjects(fn)
    if type(fn) ~= "function" then return 0 end
    local n = 0
    for token, record in pairs(self.objects) do
        fn(token, record)
        n = n + 1
    end
    return n
end

-- =========================================================
-- Persistence (StateLedger sidecar; merge-never-replace)
-- =========================================================

function MaterialDown:serialize()
    local objects = {}
    for token, record in pairs(self.objects) do objects[token] = record end
    local active = {}
    for fieldId in pairs(self.activeFields) do active[#active + 1] = fieldId end
    return {
        schema                = 1,
        ageAppliedThroughDay  = self.ageAppliedThroughDay,
        objects               = objects,
        activeFields          = active,
    }
end

--- MERGE, never replace.
---
--- StateLedger OMITS a block when serialize fails and cannot distinguish an omitted
--- block from a brand-new save (it decides resume-vs-defaults purely on data ~= nil).
--- A replace-on-nil would therefore wipe the watermark after ONE bad save, and a
--- lost watermark means the next tick re-ages the entire map.
function MaterialDown:deserialize(data)
    if type(data) ~= "table" then return false end

    if type(data.ageAppliedThroughDay) == "number" then
        -- Keep the FURTHEST-ON watermark. Going backwards would re-age the map.
        if self.ageAppliedThroughDay == nil or data.ageAppliedThroughDay > self.ageAppliedThroughDay then
            self.ageAppliedThroughDay = data.ageAppliedThroughDay
        end
    end

    if type(data.objects) == "table" then
        for token, record in pairs(data.objects) do
            if self.objects[token] == nil then self.objects[token] = record end
        end
    end

    -- Merge, never replace: a field the running session already knows carries
    -- material stays active even if the saved set predates it.
    if type(data.activeFields) == "table" then
        for _, fieldId in ipairs(data.activeFields) do
            self.activeFields[fieldId] = true
        end
    end
    return true
end

SoilLogger.info("MaterialDown (SF-43) loaded")
