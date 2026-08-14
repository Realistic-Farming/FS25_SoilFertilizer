-- =========================================================
-- FS25 Soil & Fertilizer - ESTABLISHMENT FAILURE (SF-18)
-- =========================================================
-- The keystone of the spatial-soil family. Seed that drowns during the
-- establishment window is PHYSICALLY ABSENT crop, never a yield discount.
--
-- In a wet spring, seed drilled into ground that genuinely waterlogs during
-- establishment never comes up: bare ground following the water's contour.
-- Packed seedbeds fail easier. The player replants (bounded only by the base
-- planting calendar), drains the cause, or carries the thin stand.
--
-- WINDOW: the sowing pass to first visible green. A daily THRESHOLD KILL inside
-- it: any ground whose positional moisture reaches waterlogged (weighted easier
-- on compacted seedbeds) has its young crop set to the never-came-up bare state,
-- once, through the shared deletion substrate.
--
-- SERVER ONLY. No money. No new handle. Absent SCS moisture = the feature is
-- inert, the stand is perfect, exactly today's behaviour.
--
-- THE WRITE TARGET (gated part, ANSWERED in the brief addendum 2026-07-22):
-- growth-state ZERO on the fruit's own plane reads as "no crop here", the
-- seeder re-sows onto it normally, and it is the cultivator/plow clearing
-- primitive. Write 0 AFTER the sow write, never cutFruitArea.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class EstablishmentFailure
EstablishmentFailure = {}
local EstablishmentFailure_mt = Class(EstablishmentFailure)

-- The daily kill threshold: SCS moisture (0-1) above which an establishing crop
-- is judged waterlogged. A compacted seedbed LOWERS the effective threshold.
EstablishmentFailure.WATERLOGGED_MOISTURE = 0.85
-- How much a fully compacted seedbed lowers the threshold (0..100 compaction scale).
EstablishmentFailure.COMPACTION_THRESHOLD_KNOCK = 0.20
-- Floor on the effective threshold after the compaction knock.
EstablishmentFailure.THRESHOLD_FLOOR = 0.5
-- SF-57 FROST: a hard frost during the establishment window kills the seed,
-- one frost is enough (the exact mirror of one soaking is enough). The read is
-- WeatherGuard's published field temperature (SF-49's pcall pattern), sampled by
-- the daily window check; absent WeatherGuard or a nil read = no frost cause.
-- Below-or-equal to this temperature (in C) is a kill. A named dial (Biological).
EstablishmentFailure.FROST_THRESHOLD_C = 0.0
-- SF-57 SEEDBED: the ground-type weight read once at sowing, multiplying the
-- trip points (moisture and frost). PLOWED/SEEDBED resists (1.0), CULTIVATED
-- normal (1.0), direct into untilled STUBBLE_TILLAGE eases the trip (0.85 of the
-- normal trip point). A named dial (Biological).
EstablishmentFailure.SEEDBED_WEIGHT = {
    PLOWED = 1.0, SEEDBED = 1.0, ROLLED_SEEDBED = 1.0,
    CULTIVATED = 1.0, STUBBLE_TILLAGE = 0.85,
}
-- SF-57 TENDER/HARDY: per fill type, whether frost is meant to kill it. Frost-
-- hardy types are exempt from the frost kill during the window and over winter.
-- Anchors: oilseed radish tender (winterkill-intended), winter wheat hardy. A
-- dial family; any future cover-crop fill type is vetted onto it before use.
EstablishmentFailure.FROST_TENDER = {
    oilseedRadish = true, OILSEEDRADISH = true, mustard = true, MUSTARD = true,
    phacelia = true, PHACELIA = true,
}
EstablishmentFailure.FROST_HARDY = {
    WHEAT = true, RYE = true, TRITICALE = true, BARLEY = true,
    wheat = true, rye = true, triticale = true, barley = true,
}
-- Severity dial. Neutral == the honest threshold. This is the Biological dial
-- through the vendered resolver (OptionScalingResolver, FS25_SettingsHub);
-- until the Option-Scaling Spine builds, the neutral identity (1.0) is the
-- honest real-world rate. One-line change when the resolver ships. No SF-local
-- knob (the brief's dial-neutral contract).
EstablishmentFailure.SEVERITY = 1.0
-- The maximum daily catch-up days (Time Guard absent path), matching SF's own.
EstablishmentFailure.MAX_DAILY_CATCHUP = 10
-- Time Guard accrual id + priority. Priority 95 sits AFTER the moisture store
-- (SCS-018, 90) and before any stress consumer / band refresh, which is the
-- pinned daily order: water settles, the dead are counted, then everyone reads
-- the day. Below 100: ground settles before any economy read.
EstablishmentFailure.DAILY_ACCURAL_ID = "SoilFertilizer_establishment_daily"
EstablishmentFailure.DAILY_ACCURAL_PRIORITY = 95

function EstablishmentFailure.new(manager)
    local self = setmetatable({}, EstablishmentFailure_mt)
    self.manager = manager
    self.isInitialized = false
    self._tgAccrualRegistered = false
    -- The shared deletion substrate machine (built once, verified in-mod shape).
    self._substrate = nil
    -- Frame-budgeted daily sweep state (mass-sowing spring day worst case).
    self._sweepQueue = nil
    self._sweepIndex = nil
    self._sweepPending = false
    self._lastFallbackDay = nil
    return self
end

function EstablishmentFailure:initialize()
    self.isInitialized = true
end

-- ============================================================
-- WINDOW STATE (brief section 3.1)
-- Set by the sowing chain; cleared when the crop reaches its FIRST VISIBLE
-- GREEN state sampled after the last pass. Every sowing pass extends the
-- window (re-drill = same case, brief 3.5).
-- ============================================================

-- Called from the sowing hook (onSowing). Opens or extends the ESTABLISHING
-- window for the field. seedbedWeight is SF-57's ground-type weight captured
-- once at the sowing position (a fact about how the seed went in, never
-- resampled during the window).
function EstablishmentFailure:onSowing(fieldId, seedbedWeight)
    if not fieldId or fieldId <= 0 then return end
    if not self.manager then return end
    local soilSystem = self.manager.soilSystem
    if not soilSystem then return end
    local field = soilSystem:getOrCreateField(fieldId, true)
    if not field then return end

    local day = soilSystem:_currentMonotonicDay()
    field.establishing = true
    field.establishingSowDay = day
    field.establishingKilled = false
    field.establishingKilledCells = {}
    if seedbedWeight ~= nil then
        field.seedbedWeight = seedbedWeight
    end
    SoilLogger.debug("[SF-18] field %d establishment window open (sow day %d, seedbed weight %.2f)",
        fieldId, day, field.seedbedWeight or 1.0)
end

-- The per-fruit first visible green state, derived like the wither precedent
-- derives comparable per-fruit states off fruitType (RWUtils.lua:44-52).
-- A named confirm in the brief, not derived agronomy.
---@param fruitDesc table
---@return number greenState
function EstablishmentFailure:_firstGreenState(fruitDesc)
    local green = 1
    if fruitDesc.minHarvestingGrowthState and fruitDesc.minHarvestingGrowthState > green then
        green = math.max(1, fruitDesc.minHarvestingGrowthState - 1)
    end
    return green
end

-- Live crop-state probe for a field (first visible green). Wrapped so any
-- engine hiccup reads "unknown" (window stays open, never a premature close).
-- Seam: overridden in the bench to drive the decision logic without a terrain.
---@param fieldId number
---@return number|nil growthState
function EstablishmentFailure:_sampleFieldGreenState(fieldId)
    if FieldState == nil then return nil end
    local fsField = nil
    if g_fieldManager and g_fieldManager.fields then
        for _, f in pairs(g_fieldManager.fields) do
            if f and f.farmland and f.farmland.id == fieldId then fsField = f; break end
        end
    end
    if not (fsField and fsField.posX and fsField.posZ) then return nil end
    local state = nil
    pcall(function()
        local fs = FieldState.new()
        fs:update(fsField.posX, fsField.posZ)
        if fs.isValid and fs.fruitTypeIndex and fs.growthState then
            state = fs.growthState
        end
    end)
    return state
end

-- Called from the daily check: closes the window once the crop has reached
-- first visible green, sampled live. Only a confirmed green closes it.
function EstablishmentFailure:closeWindowIfEstablished(fieldId, field, fruitDesc)
    if not field or not field.establishing then return end
    if not fruitDesc then return end
    local greenState = self:_firstGreenState(fruitDesc)
    local sampled = self:_sampleFieldGreenState(fieldId)
    if sampled == nil or sampled < greenState then return end
    field.establishing = false
    field.establishingSowDay = nil
    field.establishingKilled = false
    field.establishingKilledCells = nil
    SoilLogger.debug("[SF-18] field %d establishment window closed (crop green)", fieldId)
end

-- ============================================================
-- THE DAILY CHECK (brief section 3.2)
-- Once daily, never per-frame. For each establishing field, sample the moisture
-- store positionally at its grid resolution (the store's coarser fallback
-- degrades honestly); where moisture x severity >= threshold(compaction), mark
-- the region killed. One soaking is enough, no accumulator; idempotent per
-- region. Absent SCS = NOTHING thins, ever (brief 5.1).
-- ============================================================

-- The moisture source: g_currentMission.cropStressManager (the SCS-018 store's
-- positional getter), fallback getfenv. pcall-wrapped at the read site.
function EstablishmentFailure:_moistureSource()
    local cs = (g_currentMission and g_currentMission.cropStressManager)
        or (getfenv and getfenv(0) and getfenv(0).g_cropStressManager)
    if cs ~= nil and type(cs.getMoisture) == "function" then return cs end
    return nil
end

-- The neutral Biological severity. Awaiting the spine; see the class header.
function EstablishmentFailure:severity()
    return EstablishmentFailure.SEVERITY
end

-- Effective waterlogged threshold for a seedbed: base threshold knocked down by
-- the seedbed compaction (0..100), bounded by the floor. Per-cell compaction
-- where available, else the field scalar.
---@param field table
---@param compaction number|nil  per-cell compaction, or nil for the field scalar
---@return number threshold
function EstablishmentFailure:effectiveThreshold(field, compaction)
    local c = compaction or (field and field.compaction) or 0
    local knock = EstablishmentFailure.COMPACTION_THRESHOLD_KNOCK * (c / 100)
    local threshold = EstablishmentFailure.WATERLOGGED_MOISTURE - knock
    -- SF-57 SEEDBED: the ground-type weight captured once at sowing eases the
    -- trip point (a rough, untilled seedbed makes the kill fire at less wet).
    local w = field and field.seedbedWeight or 1.0
    threshold = threshold * w
    if threshold < EstablishmentFailure.THRESHOLD_FLOOR then
        threshold = EstablishmentFailure.THRESHOLD_FLOOR
    end
    return threshold
end

-- The effective frost trip point for a field, seedbed-weighted. Below-or-equal
-- to this is a hard frost kill during the establishment window.
---@return number|nil  temperature in C, or nil when no frost cause applies
function EstablishmentFailure:frostTripPoint(field)
    local w = field and field.seedbedWeight or 1.0
    return EstablishmentFailure.FROST_THRESHOLD_C * w
end

-- WeatherGuard's published field temperature (SF-49's pcall pattern). nil when
-- WeatherGuard is absent or the read fails: no frost cause, everything else
-- continues exactly as built.
function EstablishmentFailure:_readTemperature()
    local wg = (g_currentMission ~= nil and g_currentMission.weatherGuard) or nil
    if wg == nil or wg.getCurrentSky == nil then return nil end
    local ok, sky = pcall(function() return wg:getCurrentSky() end)
    if not ok or sky == nil then return nil end
    return sky.temperature
end

-- Is this fill type exempt from the frost kill (frost-hardy overwinter crop)?
function EstablishmentFailure:_isFrostHardy(fruitName)
    if not fruitName then return false end
    local up = string.upper(fruitName)
    return EstablishmentFailure.FROST_HARDY[fruitName] == true
        or EstablishmentFailure.FROST_HARDY[up] == true
end

-- The daily sweep. Builds the establishing-field queue once, processes up to the
-- DAILY_BATCH_SIZE-shaped frame budget per call, and leaves a pending flag so
-- the caller (SF's update loop, via checkDayFallback) continues across frames.
-- Called by the Time Guard accrual onSettle, or by checkDayFallback when Time
-- Guard is absent.
function EstablishmentFailure:dailyKillCheck(elapsedDays)
    if not self.isInitialized then return end
    if not self.manager or not self.manager.soilSystem then return end
    local soilSystem = self.manager.soilSystem

    if self._sweepQueue == nil then
        self._sweepQueue = {}
        for fieldId, field in pairs(soilSystem.fieldData) do
            -- A field whose window is open stays in the sweep even when some
            -- cells are already killed (partial stand): the remaining cells
            -- still get checked until they green or the whole stand fails.
            if field.establishing then
                self._sweepQueue[#self._sweepQueue + 1] = fieldId
            end
        end
        self._sweepIndex = 0
    end

    local budget = EstablishmentFailure.MAX_DAILY_CATCHUP
    if soilSystem.DAILY_BATCH_SIZE and soilSystem.DAILY_BATCH_SIZE > budget then
        budget = soilSystem.DAILY_BATCH_SIZE
    end

    local processed = 0
    while self._sweepIndex < #self._sweepQueue and processed < budget do
        self._sweepIndex = self._sweepIndex + 1
        local fieldId = self._sweepQueue[self._sweepIndex]
        local field = soilSystem.fieldData[fieldId]
        if field and field.establishing then
            self:_checkEstablishingField(fieldId, field)
        end
        processed = processed + 1
    end

    if self._sweepIndex >= #self._sweepQueue then
        self._sweepQueue = nil
        self._sweepIndex = nil
        self._sweepPending = false
        -- SF-57 WINTERKILL: once per day, after the establishing sweep, a hard
        -- frost over winter terminates a frost-TENDER cover crop standing
        -- outside its establishment window. The dead-standing shape is left
        -- intact so RSF-778's biomass probe still samples it; hardy crops are
        -- exempt. The crop-density write itself stays a noted refinement: this
        -- fires the event and the state, and the probe already clamps dead
        -- standing biomass to a sampleable value.
        self:_winterkillCheck()
    else
        self._sweepPending = true
    end
end

-- SF-57 WINTERKILL: frost-tender cover crops standing outside their window
-- (typically over winter) die on a hard frost. Tender-only; hardy is exempt.
function EstablishmentFailure:_winterkillCheck()
    local soilSystem = self.manager and self.manager.soilSystem
    if not soilSystem or not soilSystem.fieldData then return end
    local temp = self:_readTemperature()
    if temp == nil then return end
    for fieldId, field in pairs(soilSystem.fieldData) do
        if not field.establishing
            and not self:_isFrostHardy(field.sownCrop)
            and EstablishmentFailure.FROST_TENDER[field.sownCrop] then
            local trip = self:frostTripPoint(field)
            if temp <= trip and not field.winterKilled then
                field.winterKilled = true
                self:_notify("sf_notify_cover_winterkill", fieldId, "winterkill")
            end
        end
    end
end

-- One establishing field, one day: close the window if green, else run the
-- positional kill check.
function EstablishmentFailure:_checkEstablishingField(fieldId, field)
    -- Window close first: if the crop reached first visible green this pass,
    -- the window is over and nothing is killed.
    local fruitDesc = field.sownCrop and g_fruitTypeManager
        and g_fruitTypeManager:getFruitTypeByName(field.sownCrop) or nil
    self:closeWindowIfEstablished(fieldId, field, fruitDesc)
    if not field.establishing then return end

    local zone = SoilConstants and SoilConstants.ZONE
    local cellSize = zone and zone.CELL_SIZE or 10

    -- Enumerate the field's establishing cells on the shared zone grid.
    local cellList = {}
    local cells = field.zoneData or {}
    for _, cell in pairs(cells) do
        if type(cell.gx) == "number" and type(cell.gz) == "number" then
            cellList[#cellList + 1] = cell
        end
    end

    -- SF-57 FROST: a hard frost during the establishment window kills the seed,
    -- one frost is enough (the mirror of one soaking is enough). An INDEPENDENT
    -- cause: it runs whether or not a moisture signal exists, because a frost
    -- does not need a wet read. Field-uniform temperature, so a hard frost
    -- kills the establishing region as a whole; frost-hardy crops are exempt.
    -- Absent WeatherGuard or a nil read = no frost cause.
    do
        local temp = self:_readTemperature()
        if temp ~= nil and not self:_isFrostHardy(field.sownCrop) then
            local trip = self:frostTripPoint(field)
            if temp <= trip then
                local newly = {}
                if #cellList == 0 then
                    local verts = self:_fieldPolygonWorld(fieldId)
                    self:killRegion(fieldId, field, verts, fruitDesc)
                    field.establishingKilled = true
                    field.establishing = false
                    field.establishingSowDay = nil
                    self:_notify("sf_notify_establishment_frost", fieldId, "frost")
                else
                    for _, cell in ipairs(cellList) do
                        local key = cell.gx .. "," .. cell.gz
                        if not (field.establishingKilledCells and field.establishingKilledCells[key]) then
                            newly[#newly + 1] = cell
                        end
                    end
                    if #newly > 0 then
                        field.establishingKilledCells = field.establishingKilledCells or {}
                        for _, cell in ipairs(newly) do
                            field.establishingKilledCells[cell.gx .. "," .. cell.gz] = true
                        end
                        local regions = self:_groupRegions(newly)
                        local killedAny = false
                        for _, region in ipairs(regions) do
                            local rings = self:_regionPolygon(region, cellSize)
                            if rings and #rings > 0 then
                                self:killRegion(fieldId, field, rings, fruitDesc)
                                killedAny = true
                            end
                        end
                        if killedAny then
                            field.establishingKilled = true
                            local allKilled = true
                            for _, cell in ipairs(cellList) do
                                if not field.establishingKilledCells[cell.gx .. "," .. cell.gz] then
                                    allKilled = false
                                    break
                                end
                            end
                            if allKilled then
                                field.establishing = false
                                field.establishingSowDay = nil
                            end
                            self:_notify("sf_notify_establishment_frost", fieldId, "frost")
                        end
                    end
                end
                if not field.establishing then return end
            end
        end
    end

    -- NO SIGNAL = NO THINNING (absolute): absent SCS, absent read, nil
    -- moisture -> the moisture cause finds nothing to thin. Frost above has
    -- already run as its own cause.
    local cs = self:_moistureSource()
    if cs == nil then return end

    if #cellList == 0 then
        -- Coarser fallback, degrades honestly: the field aggregate decides for
        -- the whole establishing window (the store returns the field scalar).
        local ok, moisture = pcall(function() return cs:getMoisture(fieldId) end)
        if not ok or moisture == nil then return end
        local threshold = self:effectiveThreshold(field)
        if moisture * self:severity() >= threshold then
            local verts = self:_fieldPolygonWorld(fieldId)
            self:killRegion(fieldId, field, verts, fruitDesc)
            field.establishingKilled = true
            field.establishing = false
            field.establishingSowDay = nil
            SoilLogger.info("[SF-18] field %d establishment FAILED (waterlogged seedbed): crop set to never-came-up", fieldId)
        end
        return
    end

    -- Positional per-cell read at the store's grid resolution. Group the newly
    -- waterlogged cells into contiguous regions; write each region once.
    local newly = {}
    for _, cell in ipairs(cellList) do
        local key = cell.gx .. "," .. cell.gz
        if not (field.establishingKilledCells and field.establishingKilledCells[key]) then
            local x = cell.gx * cellSize + cellSize * 0.5
            local z = cell.gz * cellSize + cellSize * 0.5
            local ok, moisture = pcall(function() return cs:getMoisture(fieldId, x, z) end)
            if ok and moisture ~= nil then
                local threshold = self:effectiveThreshold(field, cell.compaction)
                if moisture * self:severity() >= threshold then
                    newly[#newly + 1] = cell
                end
            end
        end
    end

    if #newly > 0 then
        field.establishingKilledCells = field.establishingKilledCells or {}
        for _, cell in ipairs(newly) do
            field.establishingKilledCells[cell.gx .. "," .. cell.gz] = true
        end
        local regions = self:_groupRegions(newly)
        local killedAny = false
        for _, region in ipairs(regions) do
            local rings = self:_regionPolygon(region, cellSize)
            if rings and #rings > 0 then
                self:killRegion(fieldId, field, rings, fruitDesc)
                killedAny = true
            end
        end
        if killedAny then
            field.establishingKilled = true
            -- The whole stand has failed: every establishing cell is now killed.
            -- (Surviving cells keep the window open until they green.)
            local allKilled = true
            for _, cell in ipairs(cellList) do
                if not field.establishingKilledCells[cell.gx .. "," .. cell.gz] then
                    allKilled = false
                    break
                end
            end
            if allKilled then
                field.establishing = false
                field.establishingSowDay = nil
            end
        end
    end

end

-- SF-57 player notification (a new sf_notify_* key through the soil system's
-- showNotification helper, which gates on the player's showNotifications
-- setting). Fallback logs when the helper or l10n is unavailable.
function EstablishmentFailure:_notify(key, fieldId, cause)
    local ss = self.manager and self.manager.soilSystem
    if ss ~= nil and ss.showNotification ~= nil then
        local text = g_i18n and g_i18n:getText(key)
            or ("Establishment failed: " .. tostring(cause))
        pcall(function() ss:showNotification(text) end)
    end
    SoilLogger.info("[SF-57] field %d establishment FAILED (%s): crop set to never-came-up",
        fieldId, tostring(cause))
end

-- Group a list of {gx=,gz=} cells into contiguous 4-connected regions.
---@param cells table
---@return table regions
function EstablishmentFailure:_groupRegions(cells)
    local set = {}
    for _, c in ipairs(cells) do set[c.gx .. "," .. c.gz] = c end
    local regions = {}
    local visited = {}
    for _, c in ipairs(cells) do
        local key = c.gx .. "," .. c.gz
        if not visited[key] then
            local region = {}
            local queue = { c }
            visited[key] = true
            local head = 1
            while head <= #queue do
                local cur = queue[head]
                head = head + 1
                region[#region + 1] = cur
                for _, d in ipairs({ {1,0}, {-1,0}, {0,1}, {0,-1} }) do
                    local nk = (cur.gx + d[1]) .. "," .. (cur.gz + d[2])
                    if set[nk] and not visited[nk] then
                        visited[nk] = true
                        queue[#queue + 1] = set[nk]
                    end
                end
            end
            regions[#regions + 1] = region
        end
    end
    return regions
end

-- Build the outline ring(s) of a contiguous cell region as world-space polygons
-- ({x=,z=} points), by walking the boundary edges. Returns { ring, ... }.
---@param region table  list of {gx=,gz=}
---@param cellSize number
---@return table rings
function EstablishmentFailure:_regionPolygon(region, cellSize)
    local set = {}
    for _, c in ipairs(region) do set[c.gx .. "," .. c.gz] = true end

    local function cornerKey(x, z) return x .. "," .. z end
    local function hasCell(nx, nz) return set[nx .. "," .. nz] ~= nil end

    -- Directed boundary edges, interior on the left (region inside), so tracing
    -- walks each loop back to its start.
    local nextEdge = {}
    for _, c in ipairs(region) do
        local gx, gz = c.gx, c.gz
        -- bottom (gz-1 absent): (gx,gz) -> (gx+1,gz)
        if not hasCell(gx, gz - 1) then nextEdge[cornerKey(gx, gz)] = cornerKey(gx + 1, gz) end
        -- right (gx+1 absent): (gx+1,gz) -> (gx+1,gz+1)
        if not hasCell(gx + 1, gz) then nextEdge[cornerKey(gx + 1, gz)] = cornerKey(gx + 1, gz + 1) end
        -- top (gz+1 absent): (gx+1,gz+1) -> (gx,gz+1)
        if not hasCell(gx, gz + 1) then nextEdge[cornerKey(gx + 1, gz + 1)] = cornerKey(gx, gz + 1) end
        -- left (gx-1 absent): (gx,gz+1) -> (gx,gz)
        if not hasCell(gx - 1, gz) then nextEdge[cornerKey(gx, gz + 1)] = cornerKey(gx, gz) end
    end

    local rings = {}
    local used = {}
    local keys = {}
    for k in pairs(nextEdge) do keys[#keys + 1] = k end
    for _, startKey in ipairs(keys) do
        if not used[startKey] then
            local ring = {}
            local k = startKey
            local steps = 0
            while k and not used[k] and steps <= 4096 do
                used[k] = true
                local x, z = k:match("^(-?%d+),(-?%d+)$")
                if x then
                    ring[#ring + 1] = { x = tonumber(x) * cellSize, z = tonumber(z) * cellSize }
                end
                k = nextEdge[k]
                steps = steps + 1
                if k == startKey then break end
            end
            if #ring >= 3 then rings[#rings + 1] = ring end
        end
    end
    return rings
end

-- ============================================================
-- THE KILL WRITE (brief section 3.3)
-- ONCE per newly-killed region: set the crop density to the never-came-up bare
-- state (growth-state 0) on the fruit's own plane, through the shared deletion
-- substrate. The write's filter touches only young pre-emergence crop states;
-- bare ground carries none, mature states are never touched (brief 5.2).
-- VERIFIED WRITE PATH: the same single DensityMapModifier polygon machine
-- SoilLayerSystem.writeFieldToLayers ships in production
-- (clearPolygonPoints / addPolygonPointWorldCoords / executeSet), wrapped in
-- growthSystem:setIgnoreDensityChanges. The shared-substrate-with-CropDisease
-- agreement (one machine, two callers) is the standing contract; CropDisease's
-- delete is not built, so the machine lives here for both to reuse.
-- ============================================================

-- Build the shared substrate machine (idempotent). Verified in-mod shape; no
-- unverifiable multiModifier/polygon API is used.
function EstablishmentFailure:_ensureSubstrate()
    if self._substrate ~= nil then return self._substrate end
    local gs = g_currentMission and g_currentMission.growthSystem
    if gs == nil or DensityMapModifier == nil or type(DensityMapModifier.new) ~= "function" then
        return nil
    end
    self._substrate = { growthSystem = gs }
    return self._substrate
end

-- Write state 0 over the killed region(s). verts is either a list of {x=,z=}
-- points (one region) or a list of rings ({ {x,z},... }, ...). Guarded so an
-- engine hiccup never takes the daily pass down; a region with no fruit or no
-- polygon degrades honestly (nothing to write, nothing harmed).
---@param fieldId number
---@param field table
---@param verts table|nil
---@param fruitDesc table|nil
function EstablishmentFailure:killRegion(fieldId, field, verts, fruitDesc)
    local rings = verts
    if rings and rings[1] and rings[1].x ~= nil then
        rings = { rings }
    end
    if not rings or #rings == 0 then return end

    local substrate = self:_ensureSubstrate()
    if substrate == nil then
        SoilLogger.warning("[SF-18] field %d would fail establishment but the density substrate is unavailable (inert)", fieldId)
        return
    end
    -- Unsown ground is structurally immune: no fruit to clear (brief 5.2).
    if not fruitDesc or fruitDesc.terrainDataPlaneId == nil then return end

    local greenState = self:_firstGreenState(fruitDesc)
    local plane        = fruitDesc.terrainDataPlaneId
    local startChannel = fruitDesc.startStateChannel or 0
    local numChannels  = fruitDesc.numStateChannels or 1

    local ok, err = pcall(function()
        local modifier = DensityMapModifier.new(plane, startChannel, numChannels, g_terrainNode)
        local filter   = DensityMapFilter.new(modifier)
        -- Young pre-emergence band only: growth states 1..(first green - 1).
        -- State 0 (bare) carries none; states at/after first green are mature
        -- and must never be touched.
        filter:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, math.max(1, greenState - 1))

        substrate.growthSystem:setIgnoreDensityChanges(true)
        for _, ring in ipairs(rings) do
            if #ring >= 3 then
                modifier:clearPolygonPoints()
                for _, pt in ipairs(ring) do
                    modifier:addPolygonPointWorldCoords(pt.x, pt.z)
                end
                -- Write state 0 (never came up) to the matching young cells.
                modifier:executeSet(0, filter, nil)
            end
        end
        -- Clean bare contour: clear weed/spray overlays over the dead patch.
        self:_clearWeeds(rings)
        substrate.growthSystem:setIgnoreDensityChanges(false)
    end)
    if not ok then
        SoilLogger.error("[SF-18] field %d kill write failed: %s", fieldId, tostring(err))
    end
end

-- Best-effort weed clear over the killed region (RWUtils.witherArea's clean
-- contour). removeWeedArea takes a parallelogram; we pass the region AABB.
---@param rings table
function EstablishmentFailure:_clearWeeds(rings)
    if FSDensityMapUtil == nil or type(FSDensityMapUtil.removeWeedArea) ~= "function" then return end
    for _, ring in ipairs(rings) do
        local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
        for _, pt in ipairs(ring) do
            if pt.x < minX then minX = pt.x end
            if pt.x > maxX then maxX = pt.x end
            if pt.z < minZ then minZ = pt.z end
            if pt.z > maxZ then maxZ = pt.z end
        end
        if minX <= maxX and minZ <= maxZ then
            pcall(FSDensityMapUtil.removeWeedArea, minX, minZ, maxX, minZ, minX, maxZ)
        end
    end
end

-- Field polygon in world space ({x=,z=}), or nil. Mirrors the base game's
-- FieldManager polygon read (getPolygonPoints nodes -> world translation).
---@param fieldId number
---@return table|nil
function EstablishmentFailure:_fieldPolygonWorld(fieldId)
    local fsField = nil
    if g_fieldManager and g_fieldManager.fields then
        for _, f in pairs(g_fieldManager.fields) do
            if f and f.farmland and f.farmland.id == fieldId then fsField = f; break end
        end
    end
    if not fsField then return nil end
    local polyNodes = fsField.polygonPoints
    if type(fsField.getPolygonPoints) == "function" then
        local ok, pts = pcall(function() return fsField:getPolygonPoints() end)
        if ok and pts then polyNodes = pts end
    end
    if not polyNodes then return nil end
    local verts = {}
    for i = 1, #polyNodes do
        local nodeId = polyNodes[i]
        if nodeId and nodeId ~= 0 then
            local ok, wx, _, wz = pcall(getWorldTranslation, nodeId)
            if ok and wx then
                verts[#verts + 1] = { x = wx, z = wz }
            end
        end
    end
    if #verts < 3 then return nil end
    return verts
end

-- ============================================================
-- TIME GUARD ACCRUAL + FALLBACK (brief section 3.4 / section 2)
-- The daily kill registers as one day-cadence accrual on the simulation flow
-- class, priority after the moisture store. Time Guard absent: SF's own day
-- tracking (onEnvironmentUpdate monotonicDay catch-up) drives the fallback.
-- ============================================================
function EstablishmentFailure:registerDailyAccrual()
    if self._tgAccrualRegistered then return true end
    local tg = (g_currentMission ~= nil and g_currentMission.timeGuard) or g_timeGuard
    if tg == nil or type(tg.registerAccrual) ~= "function" then
        return false
    end
    -- Version-skew guard: an old Time Guard silently coerces an unknown
    -- flowClass to calendar. The simulation class ships in TimeGuard; if it is
    -- absent, do not register against a mislabelled flow.
    if TimeGuardScheduler ~= nil and TimeGuardScheduler.FLOW_CLASSES ~= nil
        and TimeGuardScheduler.FLOW_CLASSES.simulation ~= true then
        SoilLogger.info("[SF-18] TimeGuard has no simulation flow class; using SF day tracking")
        return false
    end
    local ok, err = pcall(function()
        tg:registerAccrual(EstablishmentFailure.DAILY_ACCURAL_ID, {
            cadence = "day",
            flowClass = "simulation",
            firstPeriodPolicy = "skip",
            priority = EstablishmentFailure.DAILY_ACCURAL_PRIORITY,
            onSettle = function(ctx)
                local days = (ctx ~= nil and ctx.boundariesCrossed) or 1
                self:dailyKillCheck(days)
            end,
        })
    end)
    if ok then
        self._tgAccrualRegistered = true
        SoilLogger.info("[SF-18] establishment kill registered with Time Guard (simulation flow)")
        return true
    end
    SoilLogger.warning("[SF-18] Time Guard registration failed: %s; using SF day tracking", tostring(err))
    return false
end

-- Fallback: called from SF's own day tracking (and from the per-frame pump for
-- the frame-budgeted sweep) when Time Guard is absent. Accepts the known
-- skipped-day limitation SF already carries.
function EstablishmentFailure:checkDayFallback()
    -- Continue a pending frame-budgeted sweep regardless of TG registration.
    if self._sweepPending then
        self:dailyKillCheck(1)
        return
    end
    if self._tgAccrualRegistered then return end
    local env = g_currentMission ~= nil and g_currentMission.environment
    if env == nil then return end
    local day = env.currentMonotonicDay or env.currentDay or 0
    if self._lastFallbackDay ~= nil and day ~= self._lastFallbackDay then
        self:dailyKillCheck(1)
    end
    self._lastFallbackDay = day
end

function EstablishmentFailure:delete()
    self.isInitialized = false
end
