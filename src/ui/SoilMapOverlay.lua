---@class SoilMapOverlay
SoilMapOverlay = {}
local SoilMapOverlay_mt = Class(SoilMapOverlay)

-- ── i18n helper ───────────────────────────────────────────
local SF_MOD_NAME = g_currentModName

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_MOD_NAME]
    local i18n   = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local text = i18n:getText(key)
        if text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

-- ── Constants ─────────────────────────────────────────────
SoilMapOverlay.LAYER_COUNT    = 10
SoilMapOverlay.ALPHA          = 0.72

-- Sampling constants
SoilMapOverlay.SAMPLE_UPDATE_INTERVAL_MS = 2000
SoilMapOverlay.POLYGON_STEP     = 10     -- world-unit grid spacing for polygon sampling (meters)
-- Point budgets per density level (1=Low, 2=Medium, 3=High).
-- These are the BASE values for a standard 2048m map. At runtime the budget is
-- scaled up proportionally with terrain size so large maps (4x, 16x, 64x) get the
-- same visual coverage density without hitting the cap mid-field-list.
SoilMapOverlay.DENSITY_POINTS   = {8000, 20000, 40000}

-- Status colors (match SoilHUD palette)
SoilMapOverlay.C_POOR = {0.88, 0.25, 0.25}
SoilMapOverlay.C_FAIR = {0.90, 0.82, 0.18}
SoilMapOverlay.C_GOOD = {0.25, 0.85, 0.25}
-- Okabe-Ito colorblind-safe palette (orange / yellow / blue)
SoilMapOverlay.CB_POOR = {0.90, 0.37, 0.00}
SoilMapOverlay.CB_FAIR = {0.94, 0.86, 0.00}
SoilMapOverlay.CB_GOOD = {0.00, 0.45, 0.70}

-- Per-layer accent color
SoilMapOverlay.LAYER_ACCENT = {
    [0] = {0.45, 0.45, 0.45},  -- Off:     grey
    [1] = {0.20, 0.55, 1.00},  -- N:       blue
    [2] = {1.00, 0.55, 0.10},  -- P:       orange
    [3] = {0.65, 0.25, 0.90},  -- K:       purple
    [4] = {0.10, 0.78, 0.75},  -- pH:      teal
    [5] = {0.60, 0.35, 0.10},  -- OM:      brown
    [6] = {0.95, 0.25, 0.25},  -- Urgency: red
    [7] = {0.20, 0.70, 0.20},  -- Weed:    dark green
    [8] = {0.85, 0.75, 0.10},  -- Pest:    amber
    [9] = {0.80, 0.10, 0.80},  -- Disease: magenta
    [10] = {0.55, 0.30, 0.10}, -- Compaction: dark brown/orange
}

-- i18n key per layer index (0 = Off)
SoilMapOverlay.LAYER_KEYS = {
    [0] = "sf_map_layer_off",
    [1] = "sf_map_layer_n",
    [2] = "sf_map_layer_p",
    [3] = "sf_map_layer_k",
    [4] = "sf_map_layer_ph",
    [5] = "sf_map_layer_om",
    [6] = "sf_map_layer_urgency",
    [7] = "sf_map_layer_weed",
    [8] = "sf_map_layer_pest",
    [9] = "sf_map_layer_disease",
    [10] = "sf_map_layer_compaction",
}

-- Inverted layers: high value = bad (urgency / pressures)
SoilMapOverlay.INVERTED_LAYERS = {[6]=true,[7]=true,[8]=true,[9]=true,[10]=true}

-- ── Constructor ───────────────────────────────────────────

---@param soilSystem SoilFertilitySystem
---@param settings Settings
---@return SoilMapOverlay
function SoilMapOverlay.new(soilSystem, settings)
    local self = setmetatable({}, SoilMapOverlay_mt)
    self.soilSystem    = soilSystem
    self.settings      = settings

    self.samplePoints = {}
    self.displayValues = nil
    self.nextSampleUpdateTime = 0
    self.isMapOpen = false
    self.isReady = false

    -- Cache of polygon fill points per field: fieldId → array of {x, z} world coords.
    -- Populated lazily in getFieldFillPoints; cleared on requestRefresh.
    self.fieldPolyCache = {}

    -- Minimap overlay: one centroid dot per field (updated on same cadence as samplePoints)
    self.minimapCentroids = {}
    self.nextMinimapUpdateTime = 0

    -- Manual Button Rects for click detection
    self.buttonRects = {}

    -- Cell inspection tooltip: set by onMapClick, cleared on layer change or re-click
    self.selectedCell = nil   -- { worldX, worldZ, farmlandId, info }

    return self
end

-- ── Initialize ────────────────────────────────────────────

function SoilMapOverlay:initialize()
    SoilLogger.info("SoilMapOverlay: initialized (DMF Heatmap Mode)")
end

-- ── Delete ────────────────────────────────────────────────

function SoilMapOverlay:delete()
    self.samplePoints = {}
    SoilLogger.info("SoilMapOverlay: deleted")
end

-- ── PDA Integration ───────────────────────────────────────

function SoilMapOverlay:getDisplayValues()
    -- Return empty table to keep native code happy, but we draw manually
    return {}
end

function SoilMapOverlay:getAverageHealth()
    if not self.soilSystem or not self.soilSystem.fieldData then return 0.75 end
    
    local sum = 0
    local count = 0
    for farmlandId, _ in pairs(self.soilSystem.fieldData) do
        sum = sum + self.soilSystem:getFieldUrgency(farmlandId)
        count = count + 1
    end
    
    if count == 0 then return 1.0 end
    
    local avgUrgency = sum / count
    return math.clamp(1.0 - (avgUrgency / 100), 0, 1)
end

function SoilMapOverlay:getDefaultFilterState()
    return {}
end

function SoilMapOverlay:getSelectedFilterCount(filterStates)
    return 0
end

function SoilMapOverlay:requestRefresh()
    self.nextSampleUpdateTime = 0
    self.nextMinimapUpdateTime = 0
    self.fieldPolyCache = {}
end

-- ── Layer selection ───────────────────────────────────────

function SoilMapOverlay:setLayer(layerIdx)
    if self.settings.activeMapLayer == layerIdx then return end
    self.settings.activeMapLayer = layerIdx
    self.selectedCell = nil  -- dismiss tooltip on layer switch
    self:requestRefresh()
    SoilLogger.debug("SoilMapOverlay: layer set to %d (%s)", layerIdx, g_i18n:getText(SoilMapOverlay.LAYER_KEYS[layerIdx] or "unknown"))
end

function SoilMapOverlay:cycleLayer()
    local active = self.settings.activeMapLayer or 0
    local next = (active % SoilMapOverlay.LAYER_COUNT) + 1
    self:setLayer(next)
end

-- Alias used by SoilMapFrame; equivalent to requestRefresh
function SoilMapOverlay:requestGenerate()
    self:requestRefresh()
end

-- ── Sidebar Clicks ────────────────────────────────────────

function SoilMapOverlay:onSideBarClick(posX, posY)
    for _, rect in ipairs(self.buttonRects) do
        if posX >= rect.x1 and posX <= rect.x2 and posY >= rect.y1 and posY <= rect.y2 then
            if rect.action == "report" then
                if SoilPDAScreen then SoilPDAScreen.toggle() end
                return true
            elseif rect.action == "treatment" then
                if SoilPDAScreen then SoilPDAScreen.showTreatment() end
                return true
            elseif rect.action == "disable" then
                self:setLayer(0)
                return true
            elseif rect.index then
                -- Toggle: re-clicking the active layer turns the overlay off
                local newIdx = (self.settings.activeMapLayer == rect.index) and 0 or rect.index
                self:setLayer(newIdx)
                return true
            end
        end
    end
    return false
end

-- ── Polygon Fill Helpers ──────────────────────────────────

-- Ray-casting point-in-polygon test (2D, XZ plane).
-- verts is an array of {x, z} tables.
local function isPointInPoly(px, pz, verts)
    local n = #verts
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local xi, zi = verts[i].x, verts[i].z
        local xj, zj = verts[j].x, verts[j].z
        if ((zi > pz) ~= (zj > pz)) and
           (px < (xj - xi) * (pz - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- Return an array of world {x, z} sample points that fill the field polygon.
--- Results are cached in self.fieldPolyCache keyed by fsField.fieldId + step.
--- Points outside the polygon are rejected.
---@param fsField table FS25 Field object with polygonPoints and fieldId
---@param step    number  World-unit grid spacing in meters (caller-computed)
---@return table Array of {x, z}
function SoilMapOverlay:getFieldFillPoints(fsField, step)
    step = step or SoilMapOverlay.POLYGON_STEP
    local cacheKey = (fsField.fieldId or tostring(fsField)) .. "@" .. step
    if self.fieldPolyCache[cacheKey] then
        return self.fieldPolyCache[cacheKey]
    end

    local pts = {}

    -- Collect polygon vertices from the i3d node array
    local polyNodes = fsField.polygonPoints
    local verts = {}
    if polyNodes and #polyNodes > 0 then
        for i = 1, #polyNodes do
            local nodeId = polyNodes[i]
            if nodeId and nodeId ~= 0 then
                local ok, wx, _, wz = pcall(getWorldTranslation, nodeId)
                if ok and wx then
                    table.insert(verts, {x = wx, z = wz})
                end
            end
        end
    end

    -- Fallback: if polygon data unavailable, return the single centroid point
    if #verts < 3 then
        if fsField.posX and fsField.posZ then
            table.insert(pts, {x = fsField.posX, z = fsField.posZ})
        end
        self.fieldPolyCache[cacheKey] = pts
        return pts
    end

    -- Compute bounding box
    local minX, maxX = verts[1].x, verts[1].x
    local minZ, maxZ = verts[1].z, verts[1].z
    for i = 2, #verts do
        if verts[i].x < minX then minX = verts[i].x end
        if verts[i].x > maxX then maxX = verts[i].x end
        if verts[i].z < minZ then minZ = verts[i].z end
        if verts[i].z > maxZ then maxZ = verts[i].z end
    end

    -- Grid-sample the bounding box, keep points inside the polygon
    -- (step is the caller-supplied world-unit spacing, already terrain-scaled)
    -- Offset start by half-step so points land near field centre, not edges
    local startX = minX + step * 0.5
    local startZ = minZ + step * 0.5
    local x = startX
    while x <= maxX do
        local z = startZ
        while z <= maxZ do
            if isPointInPoly(x, z, verts) then
                table.insert(pts, {x = x, z = z})
            end
            z = z + step
        end
        x = x + step
    end

    -- Ensure at least the centroid if the grid produced nothing
    -- (can happen for very small or narrow fields)
    if #pts == 0 and fsField.posX and fsField.posZ then
        table.insert(pts, {x = fsField.posX, z = fsField.posZ})
    end

    self.fieldPolyCache[cacheKey] = pts
    return pts
end

-- ── Point Sampling (DMF Pattern) ─────────────────────────

-- Extract the per-cell value for a given overlay layer index (1-5 only).
-- Must be defined before updateSamplePoints to be in scope as an upvalue.
local function getCellLayerValue(cell, layerIdx)
    if layerIdx == 1 then return cell.N
    elseif layerIdx == 2 then return cell.P
    elseif layerIdx == 3 then return cell.K
    elseif layerIdx == 4 then return cell.pH
    elseif layerIdx == 5 then return cell.OM
    elseif layerIdx == 6 then
        -- Urgency calculation (local approximation)
        local n = cell.N or 0
        local p = cell.P or 0
        local k = cell.K or 0
        -- Simplified urgency for map: inverse of NPK average relative to 100
        return 100 - (n + p + k) / 3
    elseif layerIdx == 7 then return cell.weedPressure
    elseif layerIdx == 8 then return cell.pestPressure
    elseif layerIdx == 9 then return cell.diseasePressure
    elseif layerIdx == 10 then return cell.compaction
    end
    return nil
end

function SoilMapOverlay:updateSamplePoints(force)
    local now = (g_currentMission and g_currentMission.time) or g_time or 0
    if not force and now < self.nextSampleUpdateTime then
        return
    end

    self.nextSampleUpdateTime = now + SoilMapOverlay.SAMPLE_UPDATE_INTERVAL_MS

    self.samplePoints = {}

    local layerIdx = self.settings.activeMapLayer or 0
    if layerIdx <= 0 then
        SoilLogger.debug("SoilMapOverlay: No active layer selected")
        return
    end

    if g_currentMission == nil or g_fieldManager == nil then
        SoilLogger.debug("SoilMapOverlay: Sampling aborted - mission or fieldManager nil")
        return
    end

    -- Fill each field polygon with a grid of coloured sample points.
    -- We match fields to our soil data via farmland.id (the key fieldData uses).
    -- getFieldFillPoints() handles the grid sampling and caching; it falls back to
    -- a single centroid point for very small fields or when polygon data is absent.
    local fields = g_fieldManager.fields
    if fields == nil then
        SoilLogger.debug("SoilMapOverlay: g_fieldManager.fields is nil")
        return
    end

    -- Scale sampling step proportional to terrain size so large maps
    -- (4x, 16x, 64x) get the same screen-pixel density as a standard 2048m map.
    local terrainSize = (g_currentMission and g_currentMission.terrainSize) or 2048
    local mapScale    = math.max(1.0, terrainSize / 2048.0)
    local scaledStep  = SoilMapOverlay.POLYGON_STEP * mapScale

    -- Resolve point budget from the player's density setting (localOnly, default Medium).
    -- Scale the budget proportionally with map area (mapScale²) so large maps don't exhaust
    -- the cap before all fields are drawn — a 4x map needs ~16x the points of a standard map.
    local densityLevel = (self.settings and self.settings.overlayDensity) or 2
    local basePoints   = SoilMapOverlay.DENSITY_POINTS[densityLevel] or SoilMapOverlay.DENSITY_POINTS[2]
    local maxPoints    = math.floor(basePoints * mapScale * mapScale)

    local totalPoints = 0
    for _, fsField in ipairs(fields) do
        if fsField and fsField.farmland then
            local farmlandId = fsField.farmland.id
            if farmlandId and farmlandId > 0 then
                local info = self.soilSystem:getFieldInfo(farmlandId)
                if info then
                    local polyPts = self:getFieldFillPoints(fsField, scaledStep)
                    -- Per-pixel path: when GRLE density map layers are available (layers 1-5),
                    -- read the soil value at each sample point directly from the layer so that
                    -- sprayed sub-areas show different colours from unsprayed areas.
                    -- Falls back to per-field average for layers 6-9 or when layers are absent.
                    local layerSystem = self.soilSystem and self.soilSystem.layerSystem
                    local grleLayerName = layerSystem and layerSystem.available and LAYER_GRLE_NAME[layerIdx]
                    if grleLayerName then
                        -- GRLE per-pixel path: maps that ship custom density-map info layers
                        for _, pt in ipairs(polyPts) do
                            if totalPoints < maxPoints then
                                local val = layerSystem:readValueAtWorld(grleLayerName, pt.x, pt.z)
                                local r, g, b
                                if val ~= nil then
                                    r, g, b = self:valueToLayerColor(layerIdx, val)
                                else
                                    r, g, b = self:getLayerColor(layerIdx, info, farmlandId)
                                end
                                table.insert(self.samplePoints, {x = pt.x, z = pt.z, r = r, g = g, b = b})
                                totalPoints = totalPoints + 1
                            end
                        end
                    elseif layerIdx >= 1 and layerIdx <= 10 then
                        -- zoneData per-cell path: standard maps, layers 1-10.
                        -- Cells that have been modified show their local value; unvisited cells
                        -- fall back to the field average so the map is always fully coloured.
                        local fieldEntry = self.soilSystem.fieldData and self.soilSystem.fieldData[farmlandId]
                        local zoneData = fieldEntry and fieldEntry.zoneData
                        local zone = SoilConstants.ZONE
                        for _, pt in ipairs(polyPts) do
                            if totalPoints < maxPoints then
                                local r, g, b
                                if zoneData then
                                    local cx = math.floor(pt.x / zone.CELL_SIZE)
                                    local cz = math.floor(pt.z / zone.CELL_SIZE)
                                    local cellKey = tostring(cx * 10000 + cz)
                                    local cell = zoneData[cellKey]
                                    if cell then
                                        local val = getCellLayerValue(cell, layerIdx)
                                        if val then r, g, b = self:valueToLayerColor(layerIdx, val) end
                                    end
                                end
                                if not r then r, g, b = self:getLayerColor(layerIdx, info, farmlandId) end
                                table.insert(self.samplePoints, {x = pt.x, z = pt.z, r = r, g = g, b = b})
                                totalPoints = totalPoints + 1
                            end
                        end
                    else
                        -- Fallback for any other layers (usually 0/off or future)
                        local r, g, b = self:getLayerColor(layerIdx, info, farmlandId)
                        for _, pt in ipairs(polyPts) do
                            if totalPoints < maxPoints then
                                table.insert(self.samplePoints, {x = pt.x, z = pt.z, r = r, g = g, b = b})
                                totalPoints = totalPoints + 1
                            end
                        end
                    end
                end
            end
        end
    end

    if totalPoints > 0 then
        SoilLogger.debug("SoilMapOverlay: Sampled %d polygon fill points for layer %d (fields: %d)",
                        totalPoints, layerIdx, #fields)
    else
        SoilLogger.debug("SoilMapOverlay: No fields found to sample (fields count: %d)", #fields)
    end
end

-- ── Draw (called by hook) ────────────────────────────────

function SoilMapOverlay:onDraw(frame, mapElement, ingameMap, pageIndex)
    self:updateSamplePoints(false)

    if #self.samplePoints == 0 then return end

    -- Use the layout-based bounds (DFF pattern) — ingameMap:getPosition() does not exist.
    local mapX, mapY, mapWidth, mapHeight = self:getMapRenderBounds(frame, ingameMap)
    if mapX == nil or mapWidth == nil or mapHeight == nil then return end

    local layerIdx = self.settings.activeMapLayer or 0
    if layerIdx <= 0 then return end

    local mapMaxX = mapX + mapWidth
    local mapMaxY = mapY + mapHeight

    -- Compute tile size from world-to-screen scale so tiles fill edge-to-edge at any zoom level.
    -- Use the same terrain-scaled step as the sampler so tiles match sample density exactly.
    local terrainSz = (g_currentMission and g_currentMission.terrainSize) or 2048
    local drawStep  = SoilMapOverlay.POLYGON_STEP * math.max(1.0, terrainSz / 2048.0)
    local sizeX, sizeY
    local probeX, probeZ = 0, 0
    local ax, ay = self:worldToScreenPosition(ingameMap, probeX, probeZ)
    local bx, by = self:worldToScreenPosition(ingameMap, probeX + drawStep, probeZ)
    local cx, cy = self:worldToScreenPosition(ingameMap, probeX, probeZ + drawStep)
    if ax and bx and cx then
        local dxX = math.abs(bx - ax)
        local dyZ = math.abs(cy - ay)
        -- Add 15% overlap so adjacent tiles don't leave hairline gaps
        sizeX = math.max(dxX * 1.15, 0.0005)
        sizeY = math.max(dyZ * 1.15, 0.0005)
    else
        sizeX, sizeY = getNormalizedScreenValues(10, 10)
    end
    local halfX, halfY = sizeX * 0.5, sizeY * 0.5

    -- Derive affine transform coefficients from the 3 probe points.
    -- The map is a linear projection so this is exact at any zoom/pan level.
    -- Replaces a per-point worldToScreenPosition() engine call with arithmetic,
    -- cutting ~40k Lua→C++ calls per frame down to the 3 probes above.
    local scaleXX = (bx - ax) / drawStep
    local scaleYX = (by - ay) / drawStep
    local scaleXZ = (cx - ax) / drawStep
    local scaleYZ = (cy - ay) / drawStep

    for _, point in ipairs(self.samplePoints) do
        local screenX = ax + point.x * scaleXX + point.z * scaleXZ
        local screenY = ay + point.x * scaleYX + point.z * scaleYZ
        if screenX >= mapX and screenX <= mapMaxX
           and screenY >= mapY and screenY <= mapMaxY then
            drawFilledRect(screenX - halfX, screenY - halfY, sizeX, sizeY,
                           point.r, point.g, point.b, SoilMapOverlay.ALPHA)
        end
    end

    -- Draw the cell inspection tooltip on top of tiles
    self:drawCellTooltip(ingameMap, mapX, mapY, mapWidth, mapHeight)
end

function SoilMapOverlay:worldToScreenPosition(ingameMap, worldX, worldZ)
    if ingameMap == nil then return nil, nil end
    -- Use fullScreenLayout when available (matches getMapRenderBounds), fall back to active layout
    local layout = ingameMap.fullScreenLayout or ingameMap.layout
    if layout == nil or layout.getMapObjectPosition == nil then return nil, nil end

    local worldSizeX = ingameMap.worldSizeX or g_currentMission.terrainSize or 2048
    local worldSizeZ = ingameMap.worldSizeZ or g_currentMission.terrainSize or 2048

    if worldSizeX == 0 or worldSizeZ == 0 then return nil, nil end

    -- DFF pattern: use worldCenterOffsetX/Z directly (0 for centered maps)
    local objectX = (worldX + (ingameMap.worldCenterOffsetX or 0)) / worldSizeX
    local objectZ = (worldZ + (ingameMap.worldCenterOffsetZ or 0)) / worldSizeZ

    objectX = objectX * (ingameMap.mapExtensionScaleFactor or 1) + (ingameMap.mapExtensionOffsetX or 0)
    objectZ = objectZ * (ingameMap.mapExtensionScaleFactor or 1) + (ingameMap.mapExtensionOffsetZ or 0)

    return layout:getMapObjectPosition(objectX, objectZ, 0, 0)
end

--- Invert worldToScreenPosition: convert a screen coordinate back to world XZ.
--- Uses the same 3-probe affine method as onDraw so the result is exact.
---@param ingameMap table
---@param screenX   number  Normalized screen X
---@param screenY   number  Normalized screen Y
---@return number|nil worldX
---@return number|nil worldZ
function SoilMapOverlay:screenToWorldPosition(ingameMap, screenX, screenY)
    local terrainSz = (g_currentMission and g_currentMission.terrainSize) or 2048
    local drawStep  = SoilMapOverlay.POLYGON_STEP * math.max(1.0, terrainSz / 2048.0)

    local ax, ay = self:worldToScreenPosition(ingameMap, 0, 0)
    local bx, by = self:worldToScreenPosition(ingameMap, drawStep, 0)
    local cx, cy = self:worldToScreenPosition(ingameMap, 0, drawStep)
    if not ax then return nil, nil end

    -- Affine matrix: screen = A * world  →  world = A^-1 * screen
    local mxx = (bx - ax) / drawStep
    local myx = (by - ay) / drawStep
    local mxz = (cx - ax) / drawStep
    local myz = (cy - ay) / drawStep

    -- Solve 2x2: [mxx mxz; myx myz] * [X; Z] = [screenX-ax; screenY-ay]
    local det = mxx * myz - mxz * myx
    if math.abs(det) < 1e-12 then return nil, nil end

    local dx = screenX - ax
    local dy = screenY - ay
    local worldX =  (myz * dx - mxz * dy) / det
    local worldZ = (-myx * dx + mxx * dy) / det
    return worldX, worldZ
end

--- Called from SoilMapHooks.onMouseEvent when the soil page is active and the
--- user clicks the map area. Finds which soil cell was clicked and stores it
--- as self.selectedCell for drawing the tooltip in onDraw.
---@param ingameMap table   The IngameMap object
---@param screenX   number  Normalized screen X of click
---@param screenY   number  Normalized screen Y of click
function SoilMapOverlay:onMapClick(ingameMap, screenX, screenY)
    local worldX, worldZ = self:screenToWorldPosition(ingameMap, screenX, screenY)
    if not worldX then
        self.selectedCell = nil
        return
    end

    -- Snap to cell grid
    local zone     = SoilConstants.ZONE
    local cellSize = zone.CELL_SIZE
    local cellCX   = math.floor(worldX / cellSize)
    local cellCZ   = math.floor(worldZ / cellSize)

    -- If user clicked the already-selected cell, deselect (toggle)
    if self.selectedCell
       and self.selectedCell.cellCX == cellCX
       and self.selectedCell.cellCZ == cellCZ then
        self.selectedCell = nil
        return
    end

    local farmlandId = g_farmlandManager and g_farmlandManager:getFarmlandAtWorldPosition(worldX, worldZ)
    if type(farmlandId) == "table" then farmlandId = farmlandId.id end
    if not farmlandId or farmlandId <= 0 then
        self.selectedCell = nil
        return
    end

    -- Cell centre
    local cellWorldX = cellCX * cellSize + cellSize * 0.5
    local cellWorldZ = cellCZ * cellSize + cellSize * 0.5

    local info = self.soilSystem and self.soilSystem:getFieldInfo(farmlandId, cellWorldX, cellWorldZ)
    if not info then
        self.selectedCell = nil
        return
    end

    self.selectedCell = {
        cellCX    = cellCX,
        cellCZ    = cellCZ,
        worldX    = cellWorldX,
        worldZ    = cellWorldZ,
        farmlandId = farmlandId,
        info      = info,
    }
    SoilLogger.debug("SoilMapOverlay: cell selected field=%s cell=[%d,%d]",
        tostring(farmlandId), cellCX, cellCZ)
end

--- Draw the cell-inspection tooltip over the selected cell on the PDA map.
---@param ingameMap table
---@param mapX      number  Left edge of map render area (normalized)
---@param mapY      number  Bottom edge of map render area (normalized)
---@param mapWidth  number
---@param mapHeight number
function SoilMapOverlay:drawCellTooltip(ingameMap, mapX, mapY, mapWidth, mapHeight)
    local sel = self.selectedCell
    if not sel then return end

    local sx, sy = self:worldToScreenPosition(ingameMap, sel.worldX, sel.worldZ)
    if not sx then return end

    sx = math.max(mapX, math.min(mapX + mapWidth,  sx))
    sy = math.max(mapY, math.min(mapY + mapHeight, sy))

    local info = sel.info
    local ppm  = SoilConstants.PPM_DISPLAY or { N = 1, P = 1, K = 1 }

    -- getNormalizedScreenValues(widthPx, heightPx) → normalizedW, normalizedH
    -- Always capture both return values and use the one that matches the axis.
    local boxW,  boxH   = getNormalizedScreenValues(200, 168)
    local padX,  _      = getNormalizedScreenValues(10,  0)
    local _,     lineH  = getNormalizedScreenValues(0,   15)
    local _,     titleH = getNormalizedScreenValues(0,   22)
    local _,     textSz = getNormalizedScreenValues(0,   11)
    local _,     titSz  = getNormalizedScreenValues(0,   13)
    local _,     bdrT   = getNormalizedScreenValues(0,   1)
    local dotSz, _      = getNormalizedScreenValues(5,   0)

    -- Box position: prefer right of anchor, flip left if it overflows
    local gapX = getNormalizedScreenValues(16, 0)
    local bx = sx + gapX
    if bx + boxW > mapX + mapWidth then
        bx = sx - boxW - gapX
    end
    local by = sy - boxH * 0.5
    by = math.max(mapY, math.min(mapY + mapHeight - boxH, by))

    -- Highlight dot
    drawFilledRect(sx - dotSz * 0.5, sy - dotSz * 0.5, dotSz, dotSz, 1, 1, 1, 0.95)

    -- Connector line
    local lineEndX = (bx > sx) and bx or (bx + boxW)
    local _, lineH1 = getNormalizedScreenValues(0, 1)
    drawFilledRect(math.min(sx, lineEndX), sy - lineH1 * 0.5,
                   math.abs(lineEndX - sx), lineH1, 0.6, 0.7, 0.9, 0.5)

    -- Background + borders
    drawFilledRect(bx, by, boxW, boxH, 0.04, 0.04, 0.07, 0.93)
    drawFilledRect(bx,               by + boxH - bdrT, boxW, bdrT, 0.4, 0.65, 1.0, 0.8)
    drawFilledRect(bx,               by,               boxW, bdrT, 0.4, 0.65, 1.0, 0.4)
    drawFilledRect(bx,               by,               bdrT, boxH, 0.4, 0.65, 1.0, 0.4)
    drawFilledRect(bx + boxW - bdrT, by,               bdrT, boxH, 0.4, 0.65, 1.0, 0.4)

    -- Title bar
    local titleY = by + boxH - titleH
    setTextBold(true)
    setTextColor(0.65, 0.85, 1.0, 1.0)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    renderText(bx + padX, titleY + titleH * 0.5, titSz,
               string.format("Field %d  [%d, %d]", sel.farmlandId, sel.cellCX, sel.cellCZ))
    setTextBold(false)
    drawFilledRect(bx + padX, titleY - bdrT, boxW - padX * 2, bdrT, 0.4, 0.65, 1.0, 0.3)

    -- Row helper: label left, value right, at absolute screen Y
    local function row(label, value, absY, r, g, b)
        local midY = absY + lineH * 0.5
        setTextColor(0.55, 0.55, 0.62, 1.0)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(bx + padX, midY, textSz, label)
        setTextColor(r, g, b, 1.0)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(bx + boxW - padX, midY, textSz, value)
    end

    local ttPOOR, ttFAIR, ttGOOD = self:statusColors()
    local function nColor(status)
        if status == "Good" then return ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif status == "Fair" then return ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else return ttPOOR[1], ttPOOR[2], ttPOOR[3] end
    end
    local function phColor(ph)
        local rc = SoilConstants.REPORT_COLORS
        if ph >= rc.PH_GOOD_LOW and ph <= rc.PH_GOOD_HIGH then return ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif ph >= rc.PH_FAIR_LOW and ph <= rc.PH_FAIR_HIGH then return ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else return ttPOOR[1], ttPOOR[2], ttPOOR[3] end
    end
    local function omColor(om)
        local rc = SoilConstants.REPORT_COLORS
        if om >= rc.OM_GOOD then return ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif om >= rc.OM_FAIR then return ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else return ttPOOR[1], ttPOOR[2], ttPOOR[3] end
    end
    local function pressureColor(pct)
        local wp = SoilConstants.WEED_PRESSURE
        if pct < wp.LOW then return ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif pct < wp.MEDIUM then return ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else return ttPOOR[1], ttPOOR[2], ttPOOR[3] end
    end

    -- Rows step downward from just below the title divider
    local rowY = titleY - lineH * 1.15
    row("Nitrogen (N)",   string.format("%d ppm", math.floor(info.nitrogen.value   * ppm.N + 0.5)), rowY, nColor(info.nitrogen.status)) ; rowY = rowY - lineH
    row("Phosphorus (P)", string.format("%d ppm", math.floor(info.phosphorus.value * ppm.P + 0.5)), rowY, nColor(info.phosphorus.status)) ; rowY = rowY - lineH
    row("Potassium (K)",  string.format("%d ppm", math.floor(info.potassium.value  * ppm.K + 0.5)), rowY, nColor(info.potassium.status)) ; rowY = rowY - lineH
    row("pH",             string.format("%.1f",   info.pH),                                         rowY, phColor(info.pH)) ; rowY = rowY - lineH
    row("Organic Matter", string.format("%.1f%%", info.organicMatter),                              rowY, omColor(info.organicMatter)) ; rowY = rowY - lineH * 0.8

    drawFilledRect(bx + padX, rowY + lineH * 0.4, boxW - padX * 2, bdrT, 0.3, 0.3, 0.4, 0.4)
    rowY = rowY - lineH * 0.6

    local wp = math.floor((info.weedPressure    or 0) + 0.5)
    local pp = math.floor((info.pestPressure    or 0) + 0.5)
    local dp = math.floor((info.diseasePressure or 0) + 0.5)
    row("Weed",    string.format("%d%%", wp), rowY, pressureColor(wp)) ; rowY = rowY - lineH
    row("Pest",    string.format("%d%%", pp), rowY, pressureColor(pp)) ; rowY = rowY - lineH
    row("Disease", string.format("%d%%", dp), rowY, pressureColor(dp))

    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
end

-- ── Sidebar Rendering ─────────────────────────────────────

function SoilMapOverlay:getSidebarBounds(frame)
    local minW, _ = getNormalizedScreenValues(230, 0)
    local marginX, marginY = getNormalizedScreenValues(8, 8)
    local safeX, safeY = getNormalizedScreenValues(6, 6)
    
    local panelX = safeX + marginX
    local panelWidth = minW

    if frame.filterList then
        panelX = frame.filterList.absPosition[1]
        panelWidth = frame.filterList.absSize[1]
    end

    -- Top Y starts below the selector - added extra margin to avoid dots clipping
    local topY = 0.82 
    if frame.mapOverviewSelector then
        local _, extraMargin = getNormalizedScreenValues(0, 45) -- Push buttons down
        topY = frame.mapOverviewSelector.absPosition[2] - extraMargin
    end

    return panelX, topY, panelWidth
end

function SoilMapOverlay:onDrawHud(frame)
    self.buttonRects = {}
    
    local panelX, topY, panelWidth = self:getSidebarBounds(frame)
    local _, buttonH = getNormalizedScreenValues(0, 38)
    local _, marginY = getNormalizedScreenValues(0, 4)
    local _, textSize = getNormalizedScreenValues(0, 15)
    local padX, _ = getNormalizedScreenValues(10, 0)
    local accentW, _ = getNormalizedScreenValues(4, 0)

    local activeIdx = self.settings.activeMapLayer or 0

    -- 1. Draw 9 Nutrient Buttons (from top down)
    local currentY = topY - buttonH
    for i = 1, SoilMapOverlay.LAYER_COUNT do
        local isActive = (i == activeIdx)
        
        local bgR, bgG, bgB = 0.05, 0.05, 0.05
        if isActive then bgR, bgG, bgB = 0.12, 0.12, 0.12 end
        drawFilledRect(panelX, currentY, panelWidth, buttonH, bgR, bgG, bgB, 0.85)
        
        local color = SoilMapOverlay.LAYER_ACCENT[i]
        drawFilledRect(panelX, currentY, accentW, buttonH, color[1], color[2], color[3], 1.0)
        
        if isActive then
            self:drawThinBorder(panelX, currentY, panelWidth, buttonH, 0.8, 0.8, 0.8, 0.5)
        end

        local key = SoilMapOverlay.LAYER_KEYS[i]
        local name = (g_i18n and g_i18n:getText(key)) or key
        
        setTextBold(isActive)
        setTextColor(isActive and 1 or 0.8, isActive and 1 or 0.8, isActive and 1 or 0.8, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(panelX + padX + accentW, currentY + buttonH * 0.3, textSize, name)
        
        table.insert(self.buttonRects, {
            x1 = panelX, y1 = currentY, 
            x2 = panelX + panelWidth, y2 = currentY + buttonH,
            index = i
        })

        currentY = currentY - buttonH - marginY
    end

    -- 2. Separator line
    local _, sepH    = getNormalizedScreenValues(0, 1)
    local _, sepGap  = getNormalizedScreenValues(0, 6)
    currentY = currentY - sepGap
    drawFilledRect(panelX, currentY, panelWidth, sepH, 0.45, 0.45, 0.45, 0.45)
    currentY = currentY - sepH - sepGap

    -- 3. Action buttons
    local _, actionH      = getNormalizedScreenValues(0, 30)
    local _, actionMargin = getNormalizedScreenValues(0, 3)

    local actionButtons = {
        { key = "sf_map_btn_report",    label = "Farm Overview",  action = "report"    },
        { key = "sf_map_btn_treatment", label = "Treatment Plan", action = "treatment" },
        { key = "sf_map_btn_disable",   label = "Disable Overlay",action = "disable"   },
    }

    for _, btn in ipairs(actionButtons) do
        drawFilledRect(panelX, currentY, panelWidth, actionH, 0.07, 0.07, 0.13, 0.88)
        drawFilledRect(panelX, currentY, accentW, actionH, 0.55, 0.55, 0.78, 1.0)
        self:drawThinBorder(panelX, currentY, panelWidth, actionH, 0.4, 0.4, 0.6, 0.55)

        setTextBold(false)
        setTextColor(0.80, 0.80, 1.0, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(panelX + padX + accentW, currentY + actionH * 0.28, textSize,
                   tr(btn.key, btn.label))

        table.insert(self.buttonRects, {
            x1 = panelX, y1 = currentY,
            x2 = panelX + panelWidth, y2 = currentY + actionH,
            action = btn.action,
        })

        currentY = currentY - actionH - actionMargin
    end

    -- 4. Color legend (only when a layer is active)
    if activeIdx > 0 then
        self:drawLegend(panelX, currentY - sepGap, panelWidth)
    end

    -- 5. Draw Health Summary (Anchored to BOTTOM area per DMF pattern)
    local _, summaryH = getNormalizedScreenValues(0, 74)
    local _, panelMargin = getNormalizedScreenValues(0, 8)
    local _, safeY = getNormalizedScreenValues(0, 6)
    local _, upOffset = getNormalizedScreenValues(0, 15) -- Extra push up
    
    local summaryY = safeY + panelMargin + upOffset
    -- Check if native buttons exist and are visible
    if frame.buttonDeselectAllText ~= nil and frame.buttonDeselectAllText:getIsVisible() then
        summaryY = frame.buttonDeselectAllText.absPosition[2] + frame.buttonDeselectAllText.absSize[2] + panelMargin + upOffset
    elseif frame.buttonHelpText ~= nil and frame.buttonHelpText:getIsVisible() then
        summaryY = frame.buttonHelpText.absPosition[2] + frame.buttonHelpText.absSize[2] + panelMargin + upOffset
    end
    
    self:drawSummaryAt(frame, panelX, summaryY, panelWidth, summaryH)
end

function SoilMapOverlay:drawSummaryAt(frame, panelX, panelY, panelWidth, panelHeight)
    local padX, padY = getNormalizedScreenValues(11, 9)
    local _, titleSize = getNormalizedScreenValues(0, 16)
    local _, statusSize = getNormalizedScreenValues(0, 13)
    local _, barHeight = getNormalizedScreenValues(0, 11)
    local _, rowGap = getNormalizedScreenValues(0, 8)
    local indicatorWidth, indicatorHeightPad = getNormalizedScreenValues(2, 2)

    local health = self:getAverageHealth()
    local healthPercent = math.floor(health * 100 + 0.5)
    
    local barX = panelX + padX
    local barY = panelY + padY + statusSize + rowGap
    local barWidth = panelWidth - padX * 2
    local headerY = barY + barHeight + rowGap
    local statusY = panelY + padY

    drawFilledRect(panelX, panelY, panelWidth, panelHeight, 0.03, 0.03, 0.03, 0.86)
    self:drawThinBorder(panelX, panelY, panelWidth, panelHeight, 0.62, 0.62, 0.62, 0.78)

    drawFilledRect(barX, barY, barWidth, barHeight, 0.12, 0.12, 0.12, 0.94)
    self:drawHealthGradientBar(barX, barY, barWidth, barHeight)
    self:drawThinBorder(barX, barY, barWidth, barHeight, 0.82, 0.82, 0.82, 0.76)

    local markerX = barX + barWidth * health
    drawFilledRect(markerX - indicatorWidth * 0.5, barY - indicatorHeightPad, indicatorWidth, barHeight + indicatorHeightPad * 2, 1, 1, 1, 0.94)

    setTextBold(true)
    setTextColor(0.93, 0.93, 0.93, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(barX, headerY, titleSize, g_i18n:getText("sf_map_health_overall") or "Average Soil Health")

    setTextAlignment(RenderText.ALIGN_RIGHT)
    renderText(barX + barWidth, headerY, titleSize, string.format("%d%%", healthPercent))

    local statusText = "Growth Conditions: Optimal"
    if health < 0.4 then statusText = "Growth Conditions: Poor"
    elseif health < 0.7 then statusText = "Growth Conditions: Fair" end

    setTextBold(false)
    setTextColor(0.80, 0.80, 0.80, 0.95)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(barX, statusY, statusSize, statusText)
    
    setTextColor(1, 1, 1, 1)
end

-- ── Color Legend ─────────────────────────────────────────

function SoilMapOverlay:drawLegend(panelX, bottomY, panelWidth)
    local _, legendH   = getNormalizedScreenValues(0, 24)
    local padX, _      = getNormalizedScreenValues(10, 0)
    local dotSzX, dotSzY = getNormalizedScreenValues(9, 9)
    local _, textSz    = getNormalizedScreenValues(0, 11)
    local dotGapX, _   = getNormalizedScreenValues(4, 0)

    local legendY = bottomY - legendH

    drawFilledRect(panelX, legendY, panelWidth, legendH, 0.04, 0.04, 0.04, 0.80)
    self:drawThinBorder(panelX, legendY, panelWidth, legendH, 0.35, 0.35, 0.35, 0.5)

    local lPOOR, lFAIR, lGOOD = self:statusColors()
    local items = {
        { r = lPOOR[1], g = lPOOR[2], b = lPOOR[3],
          key = "sf_pda_map_legend_poor", label = "Poor" },
        { r = lFAIR[1], g = lFAIR[2], b = lFAIR[3],
          key = "sf_pda_map_legend_fair", label = "Fair" },
        { r = lGOOD[1], g = lGOOD[2], b = lGOOD[3],
          key = "sf_pda_map_legend_good", label = "Good" },
    }

    local colWidth = (panelWidth - padX * 2) / #items
    local dotCenterY = legendY + (legendH - dotSzY) * 0.5

    for i, item in ipairs(items) do
        local itemX = panelX + padX + (i - 1) * colWidth
        drawFilledRect(itemX, dotCenterY, dotSzX, dotSzY, item.r, item.g, item.b, 0.92)
        self:drawThinBorder(itemX, dotCenterY, dotSzX, dotSzY, 0, 0, 0, 0.5)
        setTextBold(false)
        setTextColor(0.72, 0.72, 0.72, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(itemX + dotSzX + dotGapX, dotCenterY, textSz, tr(item.key, item.label))
    end
end

function SoilMapOverlay:drawThinBorder(x, y, width, height, r, g, b, a)
    local borderX, borderY = getNormalizedScreenValues(1, 1)
    drawFilledRect(x - borderX, y - borderY, width + borderX * 2, borderY, r, g, b, a)
    drawFilledRect(x - borderX, y + height, width + borderX * 2, borderY, r, g, b, a)
    drawFilledRect(x - borderX, y, borderX, height, r, g, b, a)
    drawFilledRect(x + width, y, borderX, height, r, g, b, a)
end

function SoilMapOverlay:drawHealthGradientBar(x, y, width, height)
    local steps = 34
    local stepWidth = width / steps
    for i = 0, steps - 1 do
        local t = (i + 0.5) / steps
        local r, g, b
        if t <= 0.5 then
            local alpha = t / 0.5
            r = 0.88 + (0.90 - 0.88) * alpha
            g = 0.25 + (0.82 - 0.25) * alpha
            b = 0.25 + (0.18 - 0.25) * alpha
        else
            local alpha = (t - 0.5) / 0.5
            r = 0.90 + (0.25 - 0.90) * alpha
            g = 0.82 + (0.85 - 0.82) * alpha
            b = 0.18 + (0.25 - 0.18) * alpha
        end
        drawFilledRect(x + i * stepWidth, y, stepWidth + 0.00001, height, r, g, b, 0.94)
    end
end

function SoilMapOverlay:getMapRenderBounds(frame, ingameMap)
    local layout = nil
    if frame ~= nil and frame.ingameMapBase ~= nil and frame.ingameMapBase.fullScreenLayout ~= nil then
        layout = frame.ingameMapBase.fullScreenLayout
    elseif ingameMap ~= nil and ingameMap.fullScreenLayout ~= nil then
        layout = ingameMap.fullScreenLayout
    end

    if layout == nil or layout.getMapSize == nil or layout.getMapPosition == nil then
        return nil, nil, nil, nil
    end

    local mapX, mapY = layout:getMapPosition()
    local mapW, mapH = layout:getMapSize()
    return mapX, mapY, mapW, mapH
end

-- ── Layer density-map layer names (indices 1-5 have GRLE layers) ─────────────
-- Maps overlay layer index → SoilLayerSystem layer name.
-- Layers 6-9 are computed values (urgency, weed, pest, disease) with no GRLE.
local LAYER_GRLE_NAME = {
    [1] = "infoLayer_soilN",
    [2] = "infoLayer_soilP",
    [3] = "infoLayer_soilK",
    [4] = "infoLayer_soilPH",
    [5] = "infoLayer_soilOM",
}

-- Returns poor, fair, good color tables based on colorblind setting.
function SoilMapOverlay:statusColors()
    if self.settings and self.settings.colorblindMode then
        return SoilMapOverlay.CB_POOR, SoilMapOverlay.CB_FAIR, SoilMapOverlay.CB_GOOD
    end
    return SoilMapOverlay.C_POOR, SoilMapOverlay.C_FAIR, SoilMapOverlay.C_GOOD
end

-- Convert a raw decoded value (from the density map layer) to a colour.
-- Mirrors the same thresholds used in getLayerColor so the per-pixel path
-- matches the per-field fallback path exactly.
---@param layerIdx integer  1-5 (soil nutrient layers)
---@param val      number   Decoded semantic float from readValueAtWorld
function SoilMapOverlay:valueToLayerColor(layerIdx, val)
    local POOR, FAIR, GOOD = self:statusColors()
    local T    = SoilConstants.STATUS_THRESHOLDS

    if layerIdx == 1 then
        if val < T.nitrogen.poor     then return POOR[1], POOR[2], POOR[3]
        elseif val < T.nitrogen.fair then return FAIR[1], FAIR[2], FAIR[3]
        else                              return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 2 then
        if val < T.phosphorus.poor     then return POOR[1], POOR[2], POOR[3]
        elseif val < T.phosphorus.fair then return FAIR[1], FAIR[2], FAIR[3]
        else                                return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 3 then
        if val < T.potassium.poor     then return POOR[1], POOR[2], POOR[3]
        elseif val < T.potassium.fair then return FAIR[1], FAIR[2], FAIR[3]
        else                               return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 4 then
        if val >= 6.5 and val <= 7.0   then return GOOD[1], GOOD[2], GOOD[3]
        elseif val >= 5.5 and val <= 7.5 then return FAIR[1], FAIR[2], FAIR[3]
        else                                  return POOR[1], POOR[2], POOR[3] end
    elseif layerIdx == 5 then
        if val >= 4.0     then return GOOD[1], GOOD[2], GOOD[3]
        elseif val >= 2.5 then return FAIR[1], FAIR[2], FAIR[3]
        else                   return POOR[1], POOR[2], POOR[3] end
    end

    return GOOD[1], GOOD[2], GOOD[3]
end

-- ── Layer color logic ─────────────────────────────────────

function SoilMapOverlay:getLayerColor(layerIdx, info, farmlandId)
    local POOR, FAIR, GOOD = self:statusColors()
    local T    = SoilConstants.STATUS_THRESHOLDS

    if layerIdx == 1 then
        local v = info.nitrogen and info.nitrogen.value or 0
        if v < T.nitrogen.poor     then return POOR[1], POOR[2], POOR[3]
        elseif v < T.nitrogen.fair then return FAIR[1], FAIR[2], FAIR[3]
        else                            return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 2 then
        local v = info.phosphorus and info.phosphorus.value or 0
        if v < T.phosphorus.poor     then return POOR[1], POOR[2], POOR[3]
        elseif v < T.phosphorus.fair then return FAIR[1], FAIR[2], FAIR[3]
        else                              return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 3 then
        local v = info.potassium and info.potassium.value or 0
        if v < T.potassium.poor     then return POOR[1], POOR[2], POOR[3]
        elseif v < T.potassium.fair then return FAIR[1], FAIR[2], FAIR[3]
        else                             return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 4 then
        local pH = info.pH or 7.0
        if pH >= 6.5 and pH <= 7.0 then     return GOOD[1], GOOD[2], GOOD[3]
        elseif pH >= 5.5 and pH <= 7.5 then return FAIR[1], FAIR[2], FAIR[3]
        else                                return POOR[1], POOR[2], POOR[3] end
    elseif layerIdx == 5 then
        local om = info.organicMatter or 0
        if om >= 4.0     then return GOOD[1], GOOD[2], GOOD[3]
        elseif om >= 2.5 then return FAIR[1], FAIR[2], FAIR[3]
        else                  return POOR[1], POOR[2], POOR[3] end
    elseif layerIdx == 6 then
        local u = self.soilSystem:getFieldUrgency(farmlandId)
        if u > 66     then return POOR[1], POOR[2], POOR[3]
        elseif u > 33 then return FAIR[1], FAIR[2], FAIR[3]
        else               return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 7 then
        local v = info.weedPressure or 0
        if v > 50     then return POOR[1], POOR[2], POOR[3]
        elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
        else               return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 8 then
        local v = info.pestPressure or 0
        if v > 50     then return POOR[1], POOR[2], POOR[3]
        elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
        else               return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 9 then
        local v = info.diseasePressure or 0
        if v > 50     then return POOR[1], POOR[2], POOR[3]
        elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
        else               return GOOD[1], GOOD[2], GOOD[3] end
    elseif layerIdx == 10 then
        local v = info.compaction or 0
        if v > 60     then return POOR[1], POOR[2], POOR[3]
        elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
        else               return GOOD[1], GOOD[2], GOOD[3] end
    end

    return GOOD[1], GOOD[2], GOOD[3]
end

-- ── Minimap Overlay ───────────────────────────────────────
-- Builds one {x, z, r, g, b} centroid entry per field using field.posX/posZ.
-- Called on a 4.5-second throttle (same cadence as the PDA sample points).
-- requestRefresh() resets nextMinimapUpdateTime so a layer change takes effect
-- immediately instead of waiting for the next tick.

function SoilMapOverlay:updateMinimapCentroids(force)
    local now = (g_currentMission and g_currentMission.time) or g_time or 0
    if not force and now < self.nextMinimapUpdateTime then return end
    self.nextMinimapUpdateTime = now + SoilMapOverlay.SAMPLE_UPDATE_INTERVAL_MS

    self.minimapCentroids = {}

    local layerIdx = self.settings.activeMapLayer or 0
    if layerIdx <= 0 then return end

    if not g_currentMission or not g_fieldManager then return end
    local fields = g_fieldManager.fields
    if not fields then return end

    local zone = SoilConstants.ZONE
    for _, fsField in ipairs(fields) do
        if fsField and fsField.farmland then
            local farmlandId = fsField.farmland.id
            if farmlandId and farmlandId > 0 then
                local info = self.soilSystem:getFieldInfo(farmlandId)
                if info then
                    -- 1. Restore Centroid Dot (Low-res status)
                    local x = fsField.posX or 0
                    local z = fsField.posZ or 0
                    local r, g, b = self:getLayerColor(layerIdx, info, farmlandId)
                    table.insert(self.minimapCentroids, {x = x, z = z, r = r, g = g, b = b, isCell = false})

                    -- 2. Add High-res pixels for worked areas (if data exists)
                    local fieldEntry = self.soilSystem.fieldData and self.soilSystem.fieldData[farmlandId]
                    if fieldEntry and fieldEntry.zoneData then
                        for cellKey, cell in pairs(fieldEntry.zoneData) do
                            local keyNum = tonumber(cellKey)
                            if keyNum then
                                local cx = math.floor(keyNum / 10000)
                                local cz = keyNum % 10000
                                local cellX = cx * zone.CELL_SIZE + zone.CELL_SIZE/2
                                local cellZ = cz * zone.CELL_SIZE + zone.CELL_SIZE/2
                                local val = getCellLayerValue(cell, layerIdx)
                                if val then
                                    local cr, cg, cb = self:valueToLayerColor(layerIdx, val)
                                    table.insert(self.minimapCentroids, {x = cellX, z = cellZ, r = cr, g = cg, b = cb, isCell = true})
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Renders the active soil layer as coloured centroid dots on the HUD minimap.
-- Guards: skips when PDA is open (fullscreen), minimap is hidden (state ≤ 1),
-- no layer is selected, or running on a dedicated server (no HUD).
-- Uses ingameMap.layout:getMapObjectPosition() for world→screen projection;
-- the layout handles clipping automatically (circle clips to circle, etc.).

function SoilMapOverlay:onDrawMinimap(ingameMap)
    if ingameMap == nil then return end
    if ingameMap.isFullscreen then return end
    if ingameMap.state == nil or ingameMap.state <= 1 then return end
    -- Suppress minimap dots when any full-screen GUI is open (pause menu, dialogs, etc.)
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end

    local layerIdx = self.settings.activeMapLayer or 0
    if layerIdx <= 0 then return end

    if g_client == nil then return end  -- server-only mode has no HUD

    self:updateMinimapCentroids()
    if #self.minimapCentroids == 0 then return end

    local layout = ingameMap.layout
    if layout == nil or layout.getMapObjectPosition == nil then return end

    local alpha = SoilMapOverlay.ALPHA * 0.80
    local wSizeX = ingameMap.worldSizeX or 2048
    local wSizeZ = ingameMap.worldSizeZ or 2048
    local offX   = ingameMap.worldCenterOffsetX or (wSizeX * 0.5)
    local offZ   = ingameMap.worldCenterOffsetZ or (wSizeZ * 0.5)
    local scale  = ingameMap.mapExtensionScaleFactor or 0.5
    local extX   = ingameMap.mapExtensionOffsetX or 0.25
    local extZ   = ingameMap.mapExtensionOffsetZ or 0.25

    for _, centroid in ipairs(self.minimapCentroids) do
        local objectX = (centroid.x + offX) / wSizeX * scale + extX
        local objectZ = (centroid.z + offZ) / wSizeZ * scale + extZ
        local ok, screenX, screenY, _, visible = pcall(layout.getMapObjectPosition, layout, objectX, objectZ, 0, 0, 0, false)
        if ok and visible and screenX and screenY then
            local size = centroid.isCell and 3 or 7
            local dotSz = getNormalizedScreenValues(size, size)
            local halfDot = dotSz * 0.5
            drawFilledRect(screenX - halfDot, screenY - halfDot, dotSz, dotSz,
                           centroid.r, centroid.g, centroid.b, alpha)
        end
    end

    -- Phase 2: Live Graphical Report next to minimap
    self:drawMiniReport(ingameMap)
end

function SoilMapOverlay:drawMiniReport(ingameMap)
    if not self.settings.showMiniReport then return end
    
    local hud = g_SoilFertilityManager and g_SoilFertilityManager.hud
    if not hud then return end

    local x, y, z = getWorldTranslation(g_localPlayer.rootNode)
    -- FS25 API: getFarmlandAtWorldPosition usually returns the ID (integer)
    local farmlandId = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    if type(farmlandId) == "table" and farmlandId.id then farmlandId = farmlandId.id end
    
    -- Edit mode visibility: always show a placeholder if in edit mode
    local info = nil
    if farmlandId and farmlandId > 0 then
        info = self.soilSystem:getFieldInfo(farmlandId, x, z)
    end

    if not info and not hud.editMode then return end

    -- Use stabilized coordinates from SoilHUD
    local s = hud.reportScale or 1.0
    local reportW, reportH = getNormalizedScreenValues(45 * s, 120 * s)
    local reportX = hud.reportX
    local reportY = hud.reportY

    -- Default fallback if not moved yet (dock to minimap)
    if reportX == 0.18 then 
        local layout = ingameMap.layout
        local mmX, mmY, mmW, mmH
        if layout and layout.getMapPosition and layout.getMapSize then
            mmX, mmY = layout:getMapPosition()
            mmW, mmH = layout:getMapSize()
            reportX = mmX + mmW + 0.005
            reportY = mmY + (mmH - reportH) * 0.5
        else
            reportX, reportY = 0.18, 0.015
        end
        -- Sync back to HUD so mouse collision matches
        hud.reportX = reportX
        hud.reportY = reportY
    end

    -- Update the rect in HUD for mouse collision
    hud.miniReportRect = { x = reportX, y = reportY, w = reportW, h = reportH }

    -- Glass-morphism background
    drawFilledRect(reportX, reportY, reportW, reportH, 0.02, 0.02, 0.03, 0.65)
    self:drawThinBorder(reportX, reportY, reportW, reportH, 0.5, 0.5, 0.6, 0.4)

    -- Edit mode indicator (Orange Pulse)
    if hud.editMode then
        local pulse = 0.55 + 0.45 * math.sin((g_currentMission and g_currentMission.time or 0) * 0.004)
        self:drawThinBorder(reportX, reportY, reportW, reportH, 1.0, 0.55, 0.10, pulse)
        
        -- If off-field, draw "EDIT" label
        if not info then
            local _, textSz = getNormalizedScreenValues(0, 12 * s)
            setTextBold(true)
            setTextColor(1, 0.6, 0.1, 1)
            setTextAlignment(RenderText.ALIGN_CENTER)
            renderText(reportX + reportW*0.5, reportY + reportH*0.5, textSz, "MOVE")
            return
        end
    end

    if not info then return end

    local barW, barH = reportW * 0.4, reportH * 0.75
    local innerX = reportX + (reportW - barW) * 0.5
    local innerY = reportY + (reportH - barH) * 0.5
    
    -- Draw 5 vertical tiny bars (N, P, K, pH, OM)
    local labels = {"N", "P", "K", "pH", "OM"}
    local values = {
        (info.nitrogen and info.nitrogen.value or 0) / 100,
        (info.phosphorus and info.phosphorus.value or 0) / 100,
        (info.potassium and info.potassium.value or 0) / 100,
        ((info.pH or 6.0) - 4.5) / 3.0,
        (info.organicMatter or 0) / 10.0
    }
    
    local segH = barH / #labels
    local subBarW = barW * 0.6
    local _, textSize = getNormalizedScreenValues(0, 10 * s)

    for i = 1, #labels do
        local cy = innerY + (i-1) * segH
        local val = math.clamp(values[#labels - i + 1], 0, 1)
        local accent = SoilMapOverlay.LAYER_ACCENT[#labels - i + 1]
        
        drawFilledRect(innerX, cy + 0.002*s, subBarW, segH - 0.004*s, 0.1, 0.1, 0.1, 0.8)
        drawFilledRect(innerX, cy + 0.002*s, subBarW * val, segH - 0.004*s, accent[1], accent[2], accent[3], 0.9)
        
        setTextBold(true)
        setTextColor(0.9, 0.9, 0.9, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(innerX + subBarW + 0.002*s, cy + 0.005*s, textSize, labels[#labels - i + 1])
    end
end

SoilLogger.info("SoilMapOverlay loaded")