-- ============================================================
-- TopographyCache.lua  (SF-77)
--
-- THE LOAD-TIME TOPOGRAPHY CACHE. Terrain-derived facts computed once
-- at map load, invalidated never recomputed: an adaptive grid (12-48 m
-- by map size, floor rounding, 180k hard cap) in row-major order,
-- carrying per-cell height, slope class, sink data and (ROUND-2)
-- distance-to-water from the engine height field and the water plane.
--
-- WHY IT IS A CACHE AND NOT A READER: runtime hydrology (SCS-042
-- runoff) and field genesis (SF-76) re-sample terrain height every
-- pass. The same height sampled a thousand times is a thousand
-- engine calls. This module computes the grid ONCE at load, marks
-- cells STALE on a terrain edit, and answers shaped defaults (never
-- nil) for stale cells so a consumer never waits on a resample.
--
-- ROUND-2 SUPERSESSION (2026-08-09): distance-to-water IS in v1,
-- server-computed once, persisted in the cache's own StateLedger
-- module and delivered via a NetworkSync module (a static table,
-- dirty only on terrain invalidation). Height, slope and sinks stay
-- peer-derived. No v2 remains on this axis.
--
-- CONSUMERS: SF-76 first (field genesis), SCS-042 second (runoff,
-- held on SCS-041). This module ships neutral: nothing reads it
-- until a consumer wires in.
-- ============================================================

TopographyCache = {}
local TopographyCache_mt = Class(TopographyCache)

-- Grid constants (the brief's numbers).
TopographyCache.CELL_MIN_M = 12
TopographyCache.CELL_MAX_M = 48
TopographyCache.HARD_CELL_CAP = 180000

-- Slope classes, in percent rise. A flat map stays flat; a 20% hillside is
-- steep. These are the shaped defaults a consumer reads for a stale cell.
TopographyCache.SLOPE_FLAT      = "flat"       -- 0-2%
TopographyCache.SLOPE_GENTLE    = "gentle"     -- 2-6%
TopographyCache.SLOPE_MODERATE  = "moderate"   -- 6-12%
TopographyCache.SLOPE_STEEP     = "steep"      -- >12%

-- Shaped defaults for a stale cell: never nil, so a consumer never has to
-- branch on "is the answer ready". A stale cell reads as if the ground is
-- flat, not a sink, and its water distance is unknown (nil is honest here:
-- the water plane moved and we have not re-measured it).
TopographyCache.STALE_DEFAULT = {
    height       = 0,
    slope        = TopographyCache.SLOPE_FLAT,
    sink         = false,
    waterDist    = nil,
}

-- ============================================================
-- THE ADAPTIVE GRID (pure, bench-driven)
-- ============================================================

--- Pick the cell size for a terrain: the smallest in [12, 48] whose floor
--- cell count stays at or under the 180k hard cap. Floor rounding per the
--- brief; a terrain larger than 48 m resolution can hold still exceeds the
--- cap, in which case the axis count is floored to the cap (the grid is
--- clamped, never oversized).
---@param terrainSize number the map's terrain size in metres
---@return number cellSize
function TopographyCache.pickCellSize(terrainSize)
    terrainSize = tonumber(terrainSize) or 2048
    for size = TopographyCache.CELL_MIN_M, TopographyCache.CELL_MAX_M do
        local axis = math.floor(terrainSize / size)
        if axis > 0 and axis * axis <= TopographyCache.HARD_CELL_CAP then
            return size
        end
    end
    return TopographyCache.CELL_MAX_M
end

--- Axis count for a terrain at a cell size (floor rounding), clamped so the
--- product never exceeds the hard cap. Pure.
---@param terrainSize number
---@param cellSize number
---@return number axisX
---@return number axisZ
function TopographyCache.axisCount(terrainSize, cellSize)
    local axis = math.max(1, math.floor(terrainSize / cellSize))
    local capAxis = math.floor(math.sqrt(TopographyCache.HARD_CELL_CAP))
    if axis > capAxis then axis = capAxis end
    return axis, axis
end

--- Row-major flat index for a grid cell.
---@param gx number
---@param gz number
---@param axisX number
---@return number
function TopographyCache.index(gx, gz, axisX)
    return gz * axisX + gx + 1
end

--- Grid cell indices at a world position. FS25 terrain spans
--- -terrainSize/2 .. +terrainSize/2 (0-centred), so the index is
--- floor((worldPos + size/2) / cellSize). nil when off the map.
---@param x number
---@param z number
---@param terrainSize number
---@param cellSize number
---@return number|nil gx
---@return number|nil gz
function TopographyCache.cellIndicesAtWorld(x, z, terrainSize, cellSize)
    local gx = math.floor((x + terrainSize * 0.5) / cellSize)
    local gz = math.floor((z + terrainSize * 0.5) / cellSize)
    if gx < 0 or gz < 0 then return nil, nil end
    local axis = TopographyCache.axisCount(terrainSize, cellSize)
    if gx >= axis or gz >= axis then return nil, nil end
    return gx, gz
end

--- World centre of a grid cell (the point the height is sampled at).
---@param gx number
---@param gz number
---@param terrainSize number
---@param cellSize number
---@return number x
---@return number z
function TopographyCache.cellCentre(gx, gz, terrainSize, cellSize)
    return gx * cellSize - terrainSize * 0.5 + cellSize * 0.5,
           gz * cellSize - terrainSize * 0.5 + cellSize * 0.5
end

-- ============================================================
-- SLOPE + SINK CLASSIFICATION (pure, bench-driven)
-- ============================================================

--- Slope class from a rise over a horizontal run. Pure.
---@param risePct number percent rise (dh / run * 100)
---@return string class
function TopographyCache.slopeClass(risePct)
    risePct = tonumber(risePct) or 0
    if risePct < 0 then risePct = 0 end
    if risePct <= 2 then return TopographyCache.SLOPE_FLAT end
    if risePct <= 6 then return TopographyCache.SLOPE_GENTLE end
    if risePct <= 12 then return TopographyCache.SLOPE_MODERATE end
    return TopographyCache.SLOPE_STEEP
end

--- Classify a cell from its own height and its four cardinal neighbours'
--- heights (all supplied as a { n, s, e, w, self } height set; nil neighbour
--- = map edge, treated as flat in that direction). Pure.
---@param heights table { self, n, s, e, w }
---@param cellSize number
---@return string slope
---@return boolean sink
function TopographyCache.classify(heights, cellSize)
    if heights == nil or type(heights.self) ~= "number" then
        return TopographyCache.SLOPE_FLAT, false
    end
    cellSize = tonumber(cellSize) or 1
    local maxRise = 0
    for _, key in ipairs({ "n", "s", "e", "w" }) do
        local h = heights[key]
        if type(h) == "number" then
            local rise = math.abs(h - heights.self) / cellSize * 100
            if rise > maxRise then maxRise = rise end
        end
    end
    local slope = TopographyCache.slopeClass(maxRise)

    -- A sink is strictly lower than every cardinal neighbour that exists.
    local sink = true
    local anyNeighbour = false
    for _, key in ipairs({ "n", "s", "e", "w" }) do
        local h = heights[key]
        if type(h) == "number" then
            anyNeighbour = true
            if h <= heights.self then sink = false end
        end
    end
    if not anyNeighbour then sink = false end
    return slope, sink
end

-- ============================================================
-- DISTANCE-TO-WATER (pure multi-source flood, ROUND-2)
-- ============================================================

--- Fill a distance-to-water grid from a water mask, in metres, by
--- multi-source BFS. Pure and deterministic: given the same mask and grid
--- the answer is identical every call (bench-asserted). A cell whose whole
--- neighbourhood never reaches water stays nil (honest: no measured water).
---@param waterMask table flat index -> true for water cells
---@param axisX number
---@param axisZ number
---@param cellSize number
---@return table dist  flat index -> metres (0 for water cells)
function TopographyCache.waterDistances(waterMask, axisX, axisZ, cellSize)
    local dist = {}
    local queue = {}
    local head = 1
    local total = axisX * axisZ

    for idx = 1, total do
        if waterMask[idx] then
            dist[idx] = 0
            queue[#queue + 1] = idx
        end
    end

    local function neighbors(idx)
        local gx = (idx - 1) % axisX
        local gz = math.floor((idx - 1) / axisX)
        local out = {}
        if gx > 0 then out[#out + 1] = idx - 1 end
        if gx < axisX - 1 then out[#out + 1] = idx + 1 end
        if gz > 0 then out[#out + 1] = idx - axisX end
        if gz < axisZ - 1 then out[#out + 1] = idx + axisX end
        return out
    end

    while head <= #queue do
        local cur = queue[head]
        head = head + 1
        local nextDist = (dist[cur] or 0) + cellSize
        for _, nb in ipairs(neighbors(cur)) do
            if dist[nb] == nil then
                dist[nb] = nextDist
                queue[#queue + 1] = nb
            end
        end
    end
    return dist
end

-- ============================================================
-- THE MODULE INSTANCE
-- ============================================================

function TopographyCache.new(manager)
    local self = setmetatable({}, TopographyCache_mt)
    self.manager = manager
    self.isInitialized = false
    self.cellSize = TopographyCache.CELL_MIN_M
    self.axisX = 0
    self.axisZ = 0
    self.terrainSize = 2048
    self._cells = {}       -- flat: index -> { height, slope, sink }
    self._waterDist = {}   -- flat: index -> metres or nil
    self._stale = {}       -- set of flat indices marked stale
    self._buildMs = 0      -- measurement gate: load cost on this map
    return self
end

function TopographyCache:initialize()
    self.isInitialized = true
end

--- The grid's world geometry.
---@return number cellSize, number axisX, number axisZ, number terrainSize
function TopographyCache:grid()
    return self.cellSize, self.axisX, self.axisZ, self.terrainSize
end

-- ============================================================
-- THE BUILD (map load, server-authoritative)
-- ============================================================

--- Build the grid from the engine height field and water plane. Server-only
--- by the distance-to-water's nature; clients receive the table through
--- NetworkSync. Records the build cost in ms (the measurement gate).
function TopographyCache:build()
    local mission = g_currentMission
    if mission == nil then return false end
    local terrainSize = tonumber(mission.terrainSize) or 2048
    self.terrainSize = terrainSize
    self.cellSize = TopographyCache.pickCellSize(terrainSize)
    self.axisX, self.axisZ = TopographyCache.axisCount(terrainSize, self.cellSize)

    local started = (g_realClock and g_realClock:getTime()) or 0
    local total = self.axisX * self.axisZ
    local heights = {}
    local waterMask = {}
    local terrainNode = g_terrainNode

    for gz = 0, self.axisZ - 1 do
        for gx = 0, self.axisX - 1 do
            local x, z = TopographyCache.cellCentre(gx, gz, terrainSize, self.cellSize)
            local h = 0
            if terrainNode ~= nil then
                local ok, v = pcall(getTerrainHeightAtWorldPos, terrainNode, x, 0, z)
                if ok then h = v or 0 end
            end
            local idx = TopographyCache.index(gx, gz, self.axisX)
            heights[idx] = h
            self._cells[idx] = { height = h, slope = TopographyCache.SLOPE_FLAT, sink = false }
        end
    end

    -- Classify slope + sink after the full height pass (neighbours needed).
    for gz = 0, self.axisZ - 1 do
        for gx = 0, self.axisX - 1 do
            local idx = TopographyCache.index(gx, gz, self.axisX)
            local set = { self = heights[idx] }
            if gx > 0 then set.w = heights[idx - 1] end
            if gx < self.axisX - 1 then set.e = heights[idx + 1] end
            if gz > 0 then set.n = heights[idx - self.axisX] end
            if gz < self.axisZ - 1 then set.s = heights[idx + self.axisX] end
            local slope, sink = TopographyCache.classify(set, self.cellSize)
            self._cells[idx].slope = slope
            self._cells[idx].sink = sink
        end
    end

    -- Water plane: a cell is water when the water surface sits above its
    -- terrain height. One raycast per cell at build; the cost is recorded.
    local envArea = mission.environmentAreaSystem
    if envArea ~= nil and type(envArea.getWaterYAtWorldPosition) == "function" then
        for gz = 0, self.axisZ - 1 do
            for gx = 0, self.axisX - 1 do
                local x, z = TopographyCache.cellCentre(gx, gz, terrainSize, self.cellSize)
                local idx = TopographyCache.index(gx, gz, self.axisX)
                local ok, waterY = pcall(envArea.getWaterYAtWorldPosition, envArea, x, 100, z)
                if ok and type(waterY) == "number" and waterY > (self._cells[idx].height or 0) then
                    waterMask[idx] = true
                end
            end
        end
    end

    self._waterDist = TopographyCache.waterDistances(waterMask, self.axisX, self.axisZ, self.cellSize)
    self._stale = {}
    self.isInitialized = true

    local elapsed = (g_realClock and g_realClock:getTime()) or 0
    self._buildMs = math.max(0, elapsed - started)
    SoilLogger.info(string.format(
        "[SF-77] TopographyCache built: %d x %d @ %d m (%d cells), water reach %.1f%%, build %.1f ms",
        self.axisX, self.axisZ, self.cellSize, self.axisX * self.axisZ,
        (self:_waterReach() * 100), self._buildMs))
    return true
end

function TopographyCache:_waterReach()
    local reached, total = 0, 0
    for _ in pairs(self._waterDist) do reached = reached + 1 end
    total = self.axisX * self.axisZ
    if total == 0 then return 0 end
    return reached / total
end

-- ============================================================
-- THE READ PATH (consumers: SF-76 first, SCS-042 second)
-- ============================================================

--- Shaped answer at a world position: height, slope class, sink flag, and
--- distance to water in metres (nil when the water plane never reached that
--- cell, which is honest rather than a fabricated number). A stale cell
--- returns the shaped default, never nil.
---@param x number
---@param z number
---@return table|nil cell
function TopographyCache:getCellInfo(x, z)
    if not self.isInitialized then return nil end
    local gx, gz = TopographyCache.cellIndicesAtWorld(x, z, self.terrainSize, self.cellSize)
    if gx == nil then return nil end
    local idx = TopographyCache.index(gx, gz, self.axisX)

    if self._stale[idx] then
        return TopographyCache.STALE_DEFAULT
    end

    local cell = self._cells[idx]
    if cell == nil then return TopographyCache.STALE_DEFAULT end
    return {
        height    = cell.height,
        slope     = cell.slope,
        sink      = cell.sink,
        waterDist = self._waterDist[idx],
    }
end

-- ============================================================
-- TERRAIN EDIT INVALIDATION
-- ============================================================

--- Mark cells stale on a terrain edit (called by the deformation syncer's
--- cell update listener). Stale answers are shaped defaults; the next build
--- re-measures. Never recomputes on the spot: the brief's "invalidated never
--- recomputed" is about this module not resampling per read.
function TopographyCache:markAreaStale(cellX, cellZ, cellId)
    -- Convert the syncer's cell to a world position, then to our grid cells.
    local syncer = g_currentMission and g_currentMission.terrainDeformationSyncer
    if syncer == nil or not self.isInitialized then return end
    local cellSize = syncer.cellSize or 2
    local startX = cellX * cellSize - self.terrainSize * 0.5
    local startZ = cellZ * cellSize - self.terrainSize * 0.5

    local gx0, gz0 = TopographyCache.cellIndicesAtWorld(startX, startZ, self.terrainSize, self.cellSize)
    local gx1, gz1 = TopographyCache.cellIndicesAtWorld(startX + cellSize, startZ + cellSize, self.terrainSize, self.cellSize)
    if gx0 == nil then return end
    gx1 = gx1 or gx0; gz1 = gz1 or gz0
    for gz = gz0, gz1 do
        for gx = gx0, gx1 do
            if gx >= 0 and gz >= 0 and gx < self.axisX and gz < self.axisZ then
                self._stale[TopographyCache.index(gx, gz, self.axisX)] = true
            end
        end
    end
    self._markCount = (self._markCount or 0) + 1
end

--- Install the terrain deformation listener (server-only). One listener on
--- the syncer cells the grid covers; edits mark the covering grid cells stale.
function TopographyCache:installTerrainListener()
    local syncer = g_currentMission and g_currentMission.terrainDeformationSyncer
    if syncer == nil or not self.isInitialized then return false end
    if type(syncer.addCellUpdateListener) ~= "function" then return false end

    local cellSize = syncer.cellSize or 2
    local perAxis = math.ceil(self.terrainSize / cellSize)
    local ok = pcall(function()
        for cx = 0, perAxis - 1 do
            for cz = 0, perAxis - 1 do
                syncer:addCellUpdateListener(self, cx, cz)
            end
        end
    end)
    if ok then
        self._listenerInstalled = true
        SoilLogger.info("[SF-77] Terrain edit listener installed (%d syncer cells)", perAxis * perAxis)
    end
    return ok
end

function TopographyCache:onTerrainDeformationSyncerUpdate(cellX, cellZ, cellId)
    self:markAreaStale(cellX, cellZ, cellId)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function TopographyCache:delete()
    self.isInitialized = false
    if self._listenerInstalled then
        local syncer = g_currentMission and g_currentMission.terrainDeformationSyncer
        if syncer ~= nil and type(syncer.removeCellUpdateListener) == "function" then
            local cellSize = syncer.cellSize or 2
            local perAxis = math.ceil(self.terrainSize / cellSize)
            pcall(function()
                for cx = 0, perAxis - 1 do
                    for cz = 0, perAxis - 1 do
                        syncer:removeCellUpdateListener(self, cx, cz)
                    end
                end
            end)
        end
        self._listenerInstalled = false
    end
    self._cells = {}
    self._waterDist = {}
    self._stale = {}
end

-- ============================================================
-- THE CACHE'S OWN PERSISTENCE + SYNC (ROUND-2)
-- The distance-to-water table is static (dirty only on terrain
-- invalidation), so it is the one thing worth persisting and
-- broadcasting. Height, slope and sinks are peer-derived and stay
-- local. These are thin bridges; the StateLedger and NetworkSync
-- registrations live beside the soil bridges in main.lua.
-- ============================================================

function TopographyCache:getStateTable()
    return {
        schema    = 1,
        cellSize  = self.cellSize,
        axisX     = self.axisX,
        axisZ     = self.axisZ,
        waterDist = self._waterDist,
    }
end

function TopographyCache:applyStateTable(data)
    if type(data) ~= "table" or data.schema ~= 1 then return false end
    if not self.isInitialized then return false end
    -- Only apply when the grid matches; a different map's table is not ours.
    if data.cellSize ~= self.cellSize or data.axisX ~= self.axisX or data.axisZ ~= self.axisZ then
        return false
    end
    self._waterDist = data.waterDist or {}
    return true
end
