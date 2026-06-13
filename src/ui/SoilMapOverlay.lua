---@class SoilMapOverlay
SoilMapOverlay = {}
local SoilMapOverlay_mt = Class(SoilMapOverlay)

-- ── i18n helper ───────────────────────────────────────────
local SF_MOD_NAME = g_currentModName

local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_MOD_NAME]
    local i18n   = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        -- pcall-wrap getText for parity with the other UI panels' tr() helpers —
        -- a missing/malformed l10n entry should fall back, never crash the overlay.
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
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
SoilMapOverlay.POLYGON_STEP        = 10  -- world-unit grid spacing for polygon sampling (meters)
SoilMapOverlay.MINIMAP_POLYGON_STEP = 12  -- world-unit step for minimap polygon fill — denser for solid-fill look
SoilMapOverlay.MINIMAP_DOT_SIZE     = 4   -- screen pixels per fill point (overlapping dots = solid field fill)
-- Point budgets per density level (1=Low, 2=Medium, 3=High).
-- These are the BASE values for a standard 2048m map. At runtime the budget is
-- scaled up proportionally with terrain size so large maps (4x, 16x, 64x) get the
-- same visual coverage density without hitting the cap mid-field-list.
SoilMapOverlay.DENSITY_POINTS   = {8000, 20000, 40000}

-- Status colors kept for colorblind fallback and any legacy uses
SoilMapOverlay.C_POOR = {0.88, 0.25, 0.25}
SoilMapOverlay.C_FAIR = {0.90, 0.82, 0.18}
SoilMapOverlay.C_GOOD = {0.25, 0.85, 0.25}
-- Okabe-Ito colorblind-safe palette (orange / yellow / blue)
SoilMapOverlay.CB_POOR = {0.90, 0.37, 0.00}
SoilMapOverlay.CB_FAIR = {0.94, 0.86, 0.00}
SoilMapOverlay.CB_GOOD = {0.00, 0.45, 0.70}

-- ── Gradient helpers ──────────────────────────────────────
-- Shared red→amber→green gradient.  t=0 is worst (red), t=1 is best (green).
-- These are the same three stop-colors used in drawHealthGradientBar.
local function healthGradient(t)
    t = math.max(0, math.min(1, t))
    local r, g, b
    if t <= 0.5 then
        local a = t / 0.5
        r = 0.88 + (0.90 - 0.88) * a
        g = 0.25 + (0.82 - 0.25) * a
        b = 0.25 + (0.18 - 0.25) * a
    else
        local a = (t - 0.5) / 0.5
        r = 0.90 + (0.25 - 0.90) * a
        g = 0.82 + (0.85 - 0.82) * a
        b = 0.18 + (0.25 - 0.18) * a
    end
    return r, g, b
end

-- Normalises a raw per-layer value to a 0-1 health fraction (0=worst, 1=best).
-- layerIdx: 1=N, 2=P, 3=K, 4=pH, 5=OM, 6=Urgency, 7=Weed, 8=Pest, 9=Disease, 10=Compaction
local function layerValueToT(layerIdx, val)
    if     layerIdx == 1 then return math.max(0, math.min(1, val / 100))        -- N   0-100
    elseif layerIdx == 2 then return math.max(0, math.min(1, val / 100))        -- P   0-100
    elseif layerIdx == 3 then return math.max(0, math.min(1, val / 100))        -- K   0-100
    elseif layerIdx == 4 then                                                    -- pH  5.0-7.5, bell around 6.75
        return math.max(0, math.min(1, 1 - math.abs(val - 6.75) / 1.75))
    elseif layerIdx == 5 then return math.max(0, math.min(1, val / 4.0))        -- OM  0-10, green at 4+
    elseif layerIdx == 10 then                                                   -- Compaction: steep ramp so a
        -- single heavy pass (~8%) already reads as a warning tint, not "good" green.
        -- 0% = green, ~40%+ = full red (rather than the gentle 0-100 ramp below).
        return math.max(0, math.min(1, 1 - val / 40))
    else   return math.max(0, math.min(1, 1 - val / 100)) end                   -- pressure/urgency layers: inverted
end

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

-- Minimap zoom: class-level so layout hooks (which have no self) can read it.
-- Levels: 1=default, 2=2× zoom in, 4=4× zoom in.
SoilMapOverlay.minimapZoomLevels   = {1, 2, 4}
SoilMapOverlay.minimapZoomFactor   = 1   -- target zoom level
SoilMapOverlay.minimapZoomSmoothed = 1   -- smooth-interpolated value

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

    -- PDA DMV double-buffer overlay (async density-map visualization)
    self._pdaDMVAvailable  = false
    self._pdaOverlays      = {nil, nil}
    self._pdaShowIdx       = 1
    self._pdaBuildIdx      = 2
    self._pdaBuildInFlight = false
    self._pdaBuildHandle   = nil
    self._pdaHasShownOnce  = false
    self._pdaUsingDMV      = false
    self._pdaActiveLayer   = -1
    self._pdaNextBuildMs   = 0

    return self
end

-- ── Initialize ────────────────────────────────────────────

function SoilMapOverlay:initialize()
    SoilLogger.info("SoilMapOverlay: initialized (DMF Heatmap Mode)")
    self:installMinimapZoomHooks()

    if createDensityMapVisualizationOverlay and not g_dedicatedServer then
        local resX, resY = 1024, 1024
        local mog = g_currentMission and g_currentMission.mapOverlayGenerator
        if mog and MapOverlayGenerator and MapOverlayGenerator.OVERLAY_RESOLUTION then
            local fsRes = MapOverlayGenerator.OVERLAY_RESOLUTION.FOLIAGE_STATE
            if fsRes and fsRes[1] and fsRes[2] then resX, resY = fsRes[1], fsRes[2] end
        end
        self._pdaOverlays[1] = createDensityMapVisualizationOverlay("SF_PDAHeatmapA", resX, resY)
        self._pdaOverlays[2] = createDensityMapVisualizationOverlay("SF_PDAHeatmapB", resX, resY)
        self._pdaDMVAvailable = (self._pdaOverlays[1] ~= nil and self._pdaOverlays[2] ~= nil)
        if self._pdaDMVAvailable then
            SoilLogger.info("[OK] SoilMapOverlay PDA DMV overlays created (%dx%d)", resX, resY)
        else
            SoilLogger.warning("SoilMapOverlay: PDA DMV overlay creation failed — polygon fallback active")
        end
    end
end

-- ── Delete ────────────────────────────────────────────────

function SoilMapOverlay:delete()
    self.samplePoints      = {}
    self._pdaOverlays      = {nil, nil}
    self._pdaBuildInFlight = false
    self._pdaBuildHandle   = nil
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
    self.nextSampleUpdateTime  = 0
    self.nextMinimapUpdateTime = 0
    self.fieldPolyCache        = {}
    self._pdaNextBuildMs       = 0
    self._pdaActiveLayer       = -1   -- force DMV rebuild on next draw
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

-- ── PDA DMV overlay (density-map visualization) ───────────

-- Maps SoilMapOverlay layer index → SoilLayerSystem field key for GRLE layers.
-- Layer 6 (urgency) is computed and has no GRLE; layer 7 (weed) uses WeedSystem.
local PDA_LAYER_GRLE = {
    [1]  = "nitrogen",
    [2]  = "phosphorus",
    [3]  = "potassium",
    [4]  = "pH",
    [5]  = "organicMatter",
    [8]  = "pestPressure",
    [9]  = "diseasePressure",
    [10] = "compaction",
}

function SoilMapOverlay:_pdaPollBuildFinished()
    if not self._pdaBuildInFlight or not self._pdaBuildHandle then return end
    if not getIsDensityMapVisualizationOverlayReady then return end
    if getIsDensityMapVisualizationOverlayReady(self._pdaBuildHandle) then
        self._pdaShowIdx, self._pdaBuildIdx = self._pdaBuildIdx, self._pdaShowIdx
        self._pdaBuildInFlight = false
        self._pdaBuildHandle   = nil
        self._pdaHasShownOnce  = true
    end
end

function SoilMapOverlay:_pdaKickBuild(layerIdx)
    local ov = self._pdaOverlays[self._pdaBuildIdx]
    if not ov then return end

    if resetDensityMapVisualizationOverlay then
        resetDensityMapVisualizationOverlay(ov)
    end

    local layerSystem = self.soilSystem and self.soilSystem.layerSystem

    -- Weed layer: game-native foliage density map
    if layerIdx == 7 and layerSystem and layerSystem.hasWeedLayer then
        local mapId, firstCh, numCh = layerSystem:getWeedMapData()
        if mapId then
            local weedColors = {
                {0.95, 0.85, 0.20}, {0.95, 0.70, 0.10}, {0.90, 0.55, 0.05},
                {0.85, 0.35, 0.05}, {0.80, 0.20, 0.05},
            }
            local maxState = math.max(1, (2 ^ (numCh or 4)) - 1)
            for state = 1, maxState do
                local ci = math.min(state, #weedColors)
                local r, g, b = weedColors[ci][1], weedColors[ci][2], weedColors[ci][3]
                -- Signature: (overlay, mapId, maskMapId, fieldMask, firstChannel, numChannels, state, r, g, b, a)
                setDensityMapVisualizationOverlayStateColor(ov, mapId, 0, 0, firstCh or 0, numCh or 4, state, r, g, b, 0.85)
            end
            self._pdaUsingDMV = true
            generateDensityMapVisualizationOverlay(ov)
            self._pdaBuildHandle   = ov
            self._pdaBuildInFlight = true
            return
        end
    end

    -- GRLE-backed layers (N/P/K/pH/OM/Pest/Disease/Compaction)
    -- State 0 (unwritten GRLE pixels) is mapped to transparent, so generating the
    -- overlay early is safe — unpopulated areas stay invisible until data is written.
    local fieldKey = PDA_LAYER_GRLE[layerIdx]
    if fieldKey and layerSystem and layerSystem.available then
        local entry = layerSystem:getLayerEntryForField(fieldKey)
        if entry then
            local handle = entry.handle
            local def    = entry.def
            -- Engine limit: 16 state color sets. Read top 4 bits of the 8-bit value.
            -- Signature: (overlay, mapId, maskMapId, fieldMask, firstChannel, numChannels, state, r, g, b, a)
            -- maskMapId=0, fieldMask=0 (no mask), firstChannel=4 reads bits 4-7 → 16 states.
            -- State 0 = raw 0-15 (unwritten/near-zero) → transparent.
            setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, 4, 4, 0, 0, 0, 0, 0)
            for i = 1, 15 do
                local semanticVal = def.minVal + (i / 15.0) * (def.maxVal - def.minVal)
                local r, g, b = self:valueToLayerColor(layerIdx, semanticVal)
                setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, 4, 4, i, r, g, b, 1.0)
            end
            self._pdaUsingDMV = true
            generateDensityMapVisualizationOverlay(ov)
            self._pdaBuildHandle   = ov
            self._pdaBuildInFlight = true
            return
        end
    end

    -- No DMV for this layer (urgency = layer 6, or GRLE not yet available)
    self._pdaUsingDMV = false
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
            elseif rect.action == "help" then
                if SoilOverlayHelpDialog then SoilOverlayHelpDialog.show() end
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

-- Maps overlay layer index → SoilLayerSystem layer name.
-- Must be declared here (before updateSamplePoints) to be in scope as an upvalue.
-- Layers 6-9 are computed values with no GRLE layer.
local LAYER_GRLE_NAME = {
    [1] = "soilN",
    [2] = "soilP",
    [3] = "soilK",
    [4] = "soilPH",
    [5] = "soilOM",
}

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
    -- Only owned fields are sampled — activeFieldIds is maintained by the ownership
    -- hook and already represents the correct set for both SP and MP.
    local fields = g_fieldManager.fields
    if fields == nil then
        SoilLogger.debug("SoilMapOverlay: g_fieldManager.fields is nil")
        return
    end
    local activeFieldIds = self.soilSystem and self.soilSystem.activeFieldIds or {}

    -- Sample step = zone cell size so every cell is sampled exactly once.
    -- POLYGON_STEP * mapScale was wrong for large maps: on a 4096m map it gave
    -- 20m step while CELL_SIZE stayed 10m, so every other row/column of zone
    -- cells was skipped and each visible tile was 4× the actual data resolution.
    local cellSz    = SoilConstants.ZONE.CELL_SIZE  -- 10m on 2048-4096m maps, scales on larger maps
    local scaledStep = cellSz

    -- Point budget: base × (mapArea / baseArea) so coverage density is consistent
    -- regardless of map size. CELL_SIZE already scales with map so the ratio stays right.
    local terrainSize = (g_currentMission and g_currentMission.terrainSize) or 2048
    local mapScale    = math.max(1.0, terrainSize / 2048.0)
    local densityLevel = (self.settings and self.settings.overlayDensity) or 2
    local basePoints   = SoilMapOverlay.DENSITY_POINTS[densityLevel] or SoilMapOverlay.DENSITY_POINTS[2]
    local maxPoints    = math.floor(basePoints * mapScale * mapScale)

    local totalPoints = 0
    for _, fsField in ipairs(fields) do
        if fsField and fsField.farmland then
            local farmlandId = fsField.farmland.id
            if farmlandId and farmlandId > 0 and activeFieldIds[farmlandId] then
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
                        -- Cells that have been measured (sprayer/harvester passed) show their
                        -- real local value at full opacity. Unvisited cells fall back to the
                        -- field-level average at half opacity so the map stays fully coloured
                        -- but players can tell measured zones from estimated ones.
                        local fieldEntry = self.soilSystem.fieldData and self.soilSystem.fieldData[farmlandId]
                        local zoneData = fieldEntry and fieldEntry.zoneData
                        local zone = SoilConstants.ZONE
                        for _, pt in ipairs(polyPts) do
                            if totalPoints < maxPoints then
                                local r, g, b, a
                                -- Draw position: use cell centre so the dot on-screen
                                -- aligns exactly with the zone cell the tooltip reads.
                                local dotX, dotZ = pt.x, pt.z
                                if zoneData then
                                    local cx = math.floor(pt.x / zone.CELL_SIZE)
                                    local cz = math.floor(pt.z / zone.CELL_SIZE)
                                    local cellKey = tostring(cx * 10000 + cz)
                                    local cell = zoneData[cellKey]
                                    if cell then
                                        local val = getCellLayerValue(cell, layerIdx)
                                        if val then
                                            r, g, b = self:valueToLayerColor(layerIdx, val)
                                            a = 1.0   -- measured: full opacity
                                            -- Anchor dot at cell centre so it matches tooltip lookup
                                            dotX = cx * zone.CELL_SIZE + zone.CELL_SIZE * 0.5
                                            dotZ = cz * zone.CELL_SIZE + zone.CELL_SIZE * 0.5
                                        end
                                    end
                                end
                                if not r then
                                    r, g, b = self:getLayerColor(layerIdx, info, farmlandId)
                                    a = 0.45  -- estimated (field average): dimmed
                                end
                                table.insert(self.samplePoints, {x = dotX, z = dotZ, r = r, g = g, b = b, a = a})
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
    local layerIdx = self.settings.activeMapLayer or 0
    if layerIdx <= 0 then return end

    local mapX, mapY, mapWidth, mapHeight = self:getMapRenderBounds(frame, ingameMap)
    if mapX == nil or mapWidth == nil or mapHeight == nil then return end

    -- PDA always uses polygon tiles (field-clamped, works without GRLE data)
    self:updateSamplePoints(false)

    if #self.samplePoints > 0 then
        local mapMaxX = mapX + mapWidth
        local mapMaxY = mapY + mapHeight

        local drawStep = SoilConstants.ZONE.CELL_SIZE
        local ax, ay = self:worldToScreenPosition(ingameMap, 0, 0)
        local bx, by = self:worldToScreenPosition(ingameMap, drawStep, 0)
        local cx, cy = self:worldToScreenPosition(ingameMap, 0, drawStep)
        local sizeX, sizeY
        if ax and bx and cx then
            sizeX = math.max(math.abs(bx - ax) * 1.15, 0.0005)
            sizeY = math.max(math.abs(cy - ay) * 1.15, 0.0005)
        else
            sizeX, sizeY = getNormalizedScreenValues(10, 10)
        end
        local halfX, halfY = sizeX * 0.5, sizeY * 0.5

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
                               point.r, point.g, point.b, (point.a or 1.0) * SoilMapOverlay.ALPHA)
            end
        end
    end

    -- Draw the cell inspection tooltip on top of the overlay
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
        cellCX       = cellCX,
        cellCZ       = cellCZ,
        worldX       = cellWorldX,
        worldZ       = cellWorldZ,
        farmlandId   = farmlandId,
        info         = info,
        fromZoneCell = info.fromZoneCell or false,
    }
    -- Force overlay refresh so tile colors match the freshly-read tooltip data
    self.nextSampleUpdateTime = 0
    SoilLogger.debug("SoilMapOverlay: cell selected field=%s cell=[%d,%d]",
        tostring(farmlandId), cellCX, cellCZ)
end

--- Draw the cell-inspection tooltip over the selected cell on the PDA map.
--- Content is layer-specific: only data relevant to the active layer is shown.
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

    local info     = sel.info
    local layerIdx = self.settings.activeMapLayer or 1
    local est      = not sel.fromZoneCell
    local ppm      = SoilConstants.PPM_DISPLAY or { N = 1, P = 1, K = 1 }

    local ttPOOR, ttFAIR, ttGOOD = self:statusColors()
    local DIM = { 0.55, 0.55, 0.62 }
    local NEU = { 0.85, 0.85, 0.90 }

    local function fmtV(s) return est and (s .. "~") or s end
    local function clrStatus(status)
        if status == "Good" then return ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif status == "Fair" then return ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else return ttPOOR[1], ttPOOR[2], ttPOOR[3] end
    end
    local function clrPct(pct, low, med)
        if pct < low then return ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif pct < med then return ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else return ttPOOR[1], ttPOOR[2], ttPOOR[3] end
    end
    local function cropTitle(name)
        if not name or name == "" then return nil end
        return (name:sub(1,1):upper() .. name:sub(2):lower()):gsub("_", " ")
    end

    -- Build layer-specific row list: each entry { label, value, r, g, b }
    local rows = {}
    local function addRow(lbl, val, r, g, b)
        rows[#rows + 1] = { label = lbl, value = val, r = r, g = g, b = b }
    end

    if layerIdx >= 1 and layerIdx <= 3 then
        -- ── Nutrient layer (N / P / K) ──────────────────────────
        local nInfo, ppmMul, lbl
        if     layerIdx == 1 then nInfo = info.nitrogen;   ppmMul = ppm.N; lbl = "Nitrogen (N)"
        elseif layerIdx == 2 then nInfo = info.phosphorus; ppmMul = ppm.P; lbl = "Phosphorus (P)"
        else                       nInfo = info.potassium;  ppmMul = ppm.K; lbl = "Potassium (K)" end

        local val = (nInfo.value or 0) * ppmMul
        addRow(lbl, fmtV(string.format("%d ppm", math.floor(val + 0.5))), clrStatus(nInfo.status))

        local targKey = (layerIdx == 1) and "N" or (layerIdx == 2) and "P" or "K"
        local ct = info.cropTargets
        if ct and ct[targKey] then
                local target = ct[targKey].opt * ppmMul
                local gap    = val - target
                local crop   = cropTitle(info.lastCrop) or "Crop"
                addRow("Target (" .. crop .. ")", string.format("%d ppm", math.floor(target + 0.5)), NEU[1], NEU[2], NEU[3])
                if gap >= 0 then
                    addRow("Gap", string.format("+%d ppm", math.floor(gap + 0.5)), ttGOOD[1], ttGOOD[2], ttGOOD[3])
                else
                    addRow("Gap", string.format("%d ppm needed", math.floor(-gap + 0.5)), ttPOOR[1], ttPOOR[2], ttPOOR[3])
                end
            else
                local crop = cropTitle(info.lastCrop)
                addRow("Target", crop and ("No data: " .. crop) or "No crop planted", DIM[1], DIM[2], DIM[3])
            end

    elseif layerIdx == 4 then
        -- ── pH layer ────────────────────────────────────────────
        local pH = math.floor(((info.pH or 7.0) * 10) + 0.5) / 10
        local condLabel, actionLabel, condR, condG, condB
        if pH >= 6.5 and pH <= 7.0 then
            condLabel = "Optimal";              actionLabel = "None needed"
            condR, condG, condB = ttGOOD[1], ttGOOD[2], ttGOOD[3]
        elseif pH > 7.0 and pH <= 7.5 then
            condLabel = "Over-limed";           actionLabel = "Allow to normalize"
            condR, condG, condB = ttPOOR[1], ttPOOR[2], ttPOOR[3]
        elseif pH > 7.5 then
            condLabel = "Severely over-limed";  actionLabel = "Apply sulfur"
            condR, condG, condB = ttPOOR[1], ttPOOR[2], ttPOOR[3]
        elseif pH >= 5.5 then
            condLabel = "Slightly acidic";      actionLabel = "Apply lime"
            condR, condG, condB = ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else
            condLabel = "Very acidic";          actionLabel = "Apply lime urgently"
            condR, condG, condB = ttPOOR[1], ttPOOR[2], ttPOOR[3]
        end
        addRow("pH",        fmtV(string.format("%.1f", pH)), condR, condG, condB)
        addRow("Condition", condLabel,   condR, condG, condB)
        addRow("Treatment", actionLabel, NEU[1], NEU[2], NEU[3])

    elseif layerIdx == 5 then
        -- ── Organic Matter ──────────────────────────────────────
        local om = math.floor(((info.organicMatter or 0) * 10) + 0.5) / 10
        local rc = SoilConstants.REPORT_COLORS
        local omR, omG, omB, hint
        if om >= (rc and rc.OM_GOOD or 4.0) then
            omR, omG, omB = ttGOOD[1], ttGOOD[2], ttGOOD[3]
            hint = "Healthy — maintain with straw"
        elseif om >= (rc and rc.OM_FAIR or 2.5) then
            omR, omG, omB = ttFAIR[1], ttFAIR[2], ttFAIR[3]
            hint = "Incorporate straw / manure"
        else
            omR, omG, omB = ttPOOR[1], ttPOOR[2], ttPOOR[3]
            hint = "Low — add manure or digestate"
        end
        addRow("Organic Matter", fmtV(string.format("%.1f%%", om)), omR, omG, omB)
        addRow("Tip",            hint, NEU[1], NEU[2], NEU[3])

    elseif layerIdx == 6 then
        -- ── Field Urgency ───────────────────────────────────────
        local urgency = self.soilSystem and self.soilSystem:getFieldUrgency(sel.farmlandId) or 0
        local uR, uG, uB
        if urgency > 66 then uR, uG, uB = ttPOOR[1], ttPOOR[2], ttPOOR[3]
        elseif urgency > 33 then uR, uG, uB = ttFAIR[1], ttFAIR[2], ttFAIR[3]
        else uR, uG, uB = ttGOOD[1], ttGOOD[2], ttGOOD[3] end
        addRow("Urgency", string.format("%d / 100", math.floor(urgency + 0.5)), uR, uG, uB)

        local T = SoilConstants.STATUS_THRESHOLDS
        local limLabel = "Balanced"
        local limR, limG, limB = ttGOOD[1], ttGOOD[2], ttGOOD[3]
        local worst = 0
        local function checkNutrient(val, thresh, name)
            if val < thresh then
                local def = thresh - val
                if def > worst then
                    worst = def; limLabel = name
                    limR, limG, limB = ttPOOR[1], ttPOOR[2], ttPOOR[3]
                end
            end
        end
        checkNutrient(info.nitrogen.value   or 0, (T.nitrogen   and T.nitrogen.fair)   or 50, "Nitrogen (N)")
        checkNutrient(info.phosphorus.value or 0, (T.phosphorus and T.phosphorus.fair) or 30, "Phosphorus (P)")
        checkNutrient(info.potassium.value  or 0, (T.potassium  and T.potassium.fair)  or 80, "Potassium (K)")
        addRow("Limiting", limLabel, limR, limG, limB)

        local crop = cropTitle(info.lastCrop) or "Fallow"
        addRow("Crop", crop, NEU[1], NEU[2], NEU[3])

    elseif layerIdx == 7 then
        -- ── Weed Pressure ───────────────────────────────────────
        local wp     = math.floor((info.weedPressure or 0) + 0.5)
        local wConst = SoilConstants.WEED_PRESSURE or {}
        local wLow, wMed = wConst.LOW or 20, wConst.MEDIUM or 50
        addRow("Weed Pressure", string.format("%d%%", wp), clrPct(wp, wLow, wMed))
        if info.herbicideActive then
            addRow("Herbicide", "Active", ttGOOD[1], ttGOOD[2], ttGOOD[3])
        elseif wp >= wLow then
            addRow("Herbicide", "Not applied", ttFAIR[1], ttFAIR[2], ttFAIR[3])
        else
            addRow("Herbicide", "Not needed", NEU[1], NEU[2], NEU[3])
        end

    elseif layerIdx == 8 then
        -- ── Pest Pressure ───────────────────────────────────────
        local pp = math.floor((info.pestPressure or 0) + 0.5)
        addRow("Pest Pressure", string.format("%d%%", pp), clrPct(pp, 20, 50))
        if info.insecticideActive then
            addRow("Insecticide", "Active", ttGOOD[1], ttGOOD[2], ttGOOD[3])
        elseif pp >= 20 then
            addRow("Insecticide", "Not applied", ttFAIR[1], ttFAIR[2], ttFAIR[3])
        else
            addRow("Insecticide", "Not needed", NEU[1], NEU[2], NEU[3])
        end

    elseif layerIdx == 9 then
        -- ── Disease Pressure ────────────────────────────────────
        local dp = math.floor((info.diseasePressure or 0) + 0.5)
        addRow("Disease Pressure", string.format("%d%%", dp), clrPct(dp, 20, 50))
        if info.fungicideActive then
            addRow("Fungicide", "Active", ttGOOD[1], ttGOOD[2], ttGOOD[3])
        elseif dp >= 20 then
            addRow("Fungicide", "Not applied", ttFAIR[1], ttFAIR[2], ttFAIR[3])
        else
            addRow("Fungicide", "Not needed", NEU[1], NEU[2], NEU[3])
        end

    elseif layerIdx == 10 then
        -- ── Compaction ──────────────────────────────────────────
        local comp = math.floor((info.compaction or 0) + 0.5)
        local cR, cG, cB, action
        if comp < 25 then
            cR, cG, cB = ttGOOD[1], ttGOOD[2], ttGOOD[3]; action = "No action needed"
        elseif comp < 60 then
            cR, cG, cB = ttFAIR[1], ttFAIR[2], ttFAIR[3]; action = "Subsoiling recommended"
        else
            cR, cG, cB = ttPOOR[1], ttPOOR[2], ttPOOR[3]; action = "Subsoiling urgent"
        end
        addRow("Compaction", string.format("%d%%", comp), cR, cG, cB)
        addRow("Treatment",  action, cR, cG, cB)
    else
        return
    end

    if #rows == 0 then return end

    -- ── Box sizing: height grows with row count ───────────────
    local nRows   = #rows
    local boxW, _ = getNormalizedScreenValues(200, 0)
    local padX, _ = getNormalizedScreenValues(10,  0)
    local _, lineH  = getNormalizedScreenValues(0, 15)
    local _, titleH = getNormalizedScreenValues(0, 22)
    local _, textSz = getNormalizedScreenValues(0, 11)
    local _, titSz  = getNormalizedScreenValues(0, 13)
    local _, bdrT   = getNormalizedScreenValues(0,  1)
    local dotSz, _  = getNormalizedScreenValues(5,  0)
    local boxH = titleH + lineH * nRows + lineH * 0.9

    -- ── Box position ─────────────────────────────────────────
    local gapX = getNormalizedScreenValues(16, 0)
    local bx = sx + gapX
    if bx + boxW > mapX + mapWidth then bx = sx - boxW - gapX end
    local by = sy - boxH * 0.5
    by = math.max(mapY, math.min(mapY + mapHeight - boxH, by))

    -- ── Highlight dot + connector ─────────────────────────────
    drawFilledRect(sx - dotSz * 0.5, sy - dotSz * 0.5, dotSz, dotSz, 1, 1, 1, 0.95)
    local lineEndX = (bx > sx) and bx or (bx + boxW)
    local _, lineH1 = getNormalizedScreenValues(0, 1)
    drawFilledRect(math.min(sx, lineEndX), sy - lineH1 * 0.5,
                   math.abs(lineEndX - sx), lineH1, 0.6, 0.7, 0.9, 0.5)

    -- ── Background + borders ──────────────────────────────────
    drawFilledRect(bx, by, boxW, boxH, 0.04, 0.04, 0.07, 0.93)
    drawFilledRect(bx,               by + boxH - bdrT, boxW, bdrT, 0.4, 0.65, 1.0, 0.8)
    drawFilledRect(bx,               by,               boxW, bdrT, 0.4, 0.65, 1.0, 0.4)
    drawFilledRect(bx,               by,               bdrT, boxH, 0.4, 0.65, 1.0, 0.4)
    drawFilledRect(bx + boxW - bdrT, by,               bdrT, boxH, 0.4, 0.65, 1.0, 0.4)

    -- ── Title bar ─────────────────────────────────────────────
    local titleY = by + boxH - titleH
    setTextBold(true)
    setTextColor(0.65, 0.85, 1.0, 1.0)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_MIDDLE)
    renderText(bx + padX, titleY + titleH * 0.5, titSz,
               string.format("Field %d  [%d, %d]", sel.farmlandId, sel.cellCX, sel.cellCZ))
    setTextBold(false)
    drawFilledRect(bx + padX, titleY - bdrT, boxW - padX * 2, bdrT, 0.4, 0.65, 1.0, 0.3)

    -- ── Data rows ─────────────────────────────────────────────
    local rowY = titleY - lineH * 1.1
    for _, r in ipairs(rows) do
        local midY = rowY + lineH * 0.5
        setTextColor(DIM[1], DIM[2], DIM[3], 1.0)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(bx + padX, midY, textSz, r.label)
        setTextColor(r.r, r.g, r.b, 1.0)
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(bx + boxW - padX, midY, textSz, r.value)
        rowY = rowY - lineH
    end

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
        { key = "sf_map_btn_report",    label = "Farm Overview",   action = "report"    },
        { key = "sf_map_btn_treatment", label = "Treatment Plan",  action = "treatment" },
        { key = "sf_map_btn_disable",   label = "Disable Overlay", action = "disable"   },
        { key = "sf_map_btn_help",      label = "Help",            action = "help"      },
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
    local _, legendH = getNormalizedScreenValues(0, 24)
    local padX, _    = getNormalizedScreenValues(10, 0)
    local _, barH    = getNormalizedScreenValues(0, 7)
    local _, textSz  = getNormalizedScreenValues(0, 11)

    local legendY  = bottomY - legendH
    local barY     = legendY + (legendH - barH) * 0.5
    local barX     = panelX + padX
    local barW     = panelWidth - padX * 2

    drawFilledRect(panelX, legendY, panelWidth, legendH, 0.04, 0.04, 0.04, 0.80)
    self:drawThinBorder(panelX, legendY, panelWidth, legendH, 0.35, 0.35, 0.35, 0.5)

    if self.settings and self.settings.colorblindMode then
        -- Colorblind: keep 3 discrete swatches
        local POOR, FAIR, GOOD = self:statusColors()
        local _, dotSz = getNormalizedScreenValues(0, 9)
        local dotGapX, _ = getNormalizedScreenValues(4, 0)
        local items = {
            { c = POOR, key = "sf_pda_map_legend_poor", label = "Poor" },
            { c = FAIR, key = "sf_pda_map_legend_fair", label = "Fair" },
            { c = GOOD, key = "sf_pda_map_legend_good", label = "Good" },
        }
        local colW   = barW / #items
        local dotCY  = legendY + (legendH - dotSz) * 0.5
        for i, item in ipairs(items) do
            local ix = barX + (i - 1) * colW
            drawFilledRect(ix, dotCY, dotSz, dotSz, item.c[1], item.c[2], item.c[3], 0.92)
            self:drawThinBorder(ix, dotCY, dotSz, dotSz, 0, 0, 0, 0.5)
            setTextBold(false)
            setTextColor(0.72, 0.72, 0.72, 1)
            setTextAlignment(RenderText.ALIGN_LEFT)
            renderText(ix + dotSz + dotGapX, dotCY, textSz, tr(item.key, item.label))
        end
    else
        -- Gradient bar with "Poor" / "Good" end labels
        local steps = 40
        local stepW = barW / steps
        for i = 0, steps - 1 do
            local r, g, b = healthGradient(i / (steps - 1))
            drawFilledRect(barX + i * stepW, barY, stepW + 0.00001, barH, r, g, b, 0.92)
        end
        self:drawThinBorder(barX, barY, barW, barH, 0.25, 0.25, 0.25, 0.5)

        local labelY = legendY + (legendH - barH) * 0.5 - textSz * 1.1
        setTextBold(false)
        setTextColor(0.72, 0.72, 0.72, 1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        renderText(barX, labelY, textSz, tr("sf_pda_map_legend_poor", "Poor"))
        setTextAlignment(RenderText.ALIGN_RIGHT)
        renderText(barX + barW, labelY, textSz, tr("sf_pda_map_legend_good", "Good"))
    end

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
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
        local r, g, b = healthGradient((i + 0.5) / steps)
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

-- Returns poor, fair, good color tables based on colorblind setting.
function SoilMapOverlay:statusColors()
    if self.settings and self.settings.colorblindMode then
        return SoilMapOverlay.CB_POOR, SoilMapOverlay.CB_FAIR, SoilMapOverlay.CB_GOOD
    end
    return SoilMapOverlay.C_POOR, SoilMapOverlay.C_FAIR, SoilMapOverlay.C_GOOD
end

-- Convert a raw decoded value (from the density map layer) to a gradient colour.
---@param layerIdx integer
---@param val      number
function SoilMapOverlay:valueToLayerColor(layerIdx, val)
    if self.settings and self.settings.colorblindMode then
        local POOR, FAIR, GOOD = self:statusColors()
        local T = SoilConstants.STATUS_THRESHOLDS
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
            local pH = math.floor((val * 10) + 0.5) / 10
            if pH >= 6.5 and pH <= 7.0 then return GOOD[1], GOOD[2], GOOD[3]
            elseif pH >= 5.5           then return FAIR[1], FAIR[2], FAIR[3]
            else                            return POOR[1], POOR[2], POOR[3] end
        elseif layerIdx == 5 then
            if val >= 4.0     then return GOOD[1], GOOD[2], GOOD[3]
            elseif val >= 2.5 then return FAIR[1], FAIR[2], FAIR[3]
            else                   return POOR[1], POOR[2], POOR[3] end
        end
        return GOOD[1], GOOD[2], GOOD[3]
    end
    return healthGradient(layerValueToT(layerIdx, val))
end

-- ── Layer color logic ─────────────────────────────────────

function SoilMapOverlay:getLayerColor(layerIdx, info, farmlandId)
    -- Colorblind mode: keep 3-step discrete palette
    if self.settings and self.settings.colorblindMode then
        local POOR, FAIR, GOOD = self:statusColors()
        local T = SoilConstants.STATUS_THRESHOLDS
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
            local pH = math.floor(((info.pH or 7.0) * 10) + 0.5) / 10
            if pH >= 6.5 and pH <= 7.0 then    return GOOD[1], GOOD[2], GOOD[3]
            elseif pH >= 5.5           then    return FAIR[1], FAIR[2], FAIR[3]
            else                               return POOR[1], POOR[2], POOR[3] end
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
            if v > 50 then return POOR[1], POOR[2], POOR[3]
            elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
            else return GOOD[1], GOOD[2], GOOD[3] end
        elseif layerIdx == 8 then
            local v = info.pestPressure or 0
            if v > 50 then return POOR[1], POOR[2], POOR[3]
            elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
            else return GOOD[1], GOOD[2], GOOD[3] end
        elseif layerIdx == 9 then
            local v = info.diseasePressure or 0
            if v > 50 then return POOR[1], POOR[2], POOR[3]
            elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
            else return GOOD[1], GOOD[2], GOOD[3] end
        elseif layerIdx == 10 then
            local v = info.compaction or 0
            if v > 60 then return POOR[1], POOR[2], POOR[3]
            elseif v > 20 then return FAIR[1], FAIR[2], FAIR[3]
            else return GOOD[1], GOOD[2], GOOD[3] end
        end
        return GOOD[1], GOOD[2], GOOD[3]
    end

    -- Gradient mode: map field-level value to continuous color
    local val
    if     layerIdx == 1 then val = info.nitrogen     and info.nitrogen.value     or 0
    elseif layerIdx == 2 then val = info.phosphorus   and info.phosphorus.value   or 0
    elseif layerIdx == 3 then val = info.potassium    and info.potassium.value    or 0
    elseif layerIdx == 4 then val = info.pH           or 7.0
    elseif layerIdx == 5 then val = info.organicMatter or 0
    elseif layerIdx == 6 then val = self.soilSystem:getFieldUrgency(farmlandId)
    elseif layerIdx == 7 then val = info.weedPressure  or 0
    elseif layerIdx == 8 then val = info.pestPressure  or 0
    elseif layerIdx == 9 then val = info.diseasePressure or 0
    elseif layerIdx == 10 then val = info.compaction   or 0
    else   val = 100 end

    return healthGradient(layerValueToT(layerIdx, val))
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

    local activeFieldIds = self.soilSystem and self.soilSystem.activeFieldIds or {}
    local zone = SoilConstants.ZONE
    local mmStep = zone.CELL_SIZE  -- match zone data resolution exactly

    for _, fsField in ipairs(fields) do
        if fsField and fsField.farmland then
            local farmlandId = fsField.farmland.id
            if farmlandId and farmlandId > 0 and activeFieldIds[farmlandId] then
                local info = self.soilSystem:getFieldInfo(farmlandId)
                if info then
                    -- Field-average color: fallback for polygon points with no zone data
                    local avgR, avgG, avgB = self:getLayerColor(layerIdx, info, farmlandId)

                    -- Per-cell zone data (nil when field has never been worked)
                    local fieldEntry = self.soilSystem.fieldData and self.soilSystem.fieldData[farmlandId]
                    local zoneData   = fieldEntry and fieldEntry.zoneData

                    -- Single pass: for each polygon fill point look up its zone cell.
                    -- If zone data exists there, show the cell's individual value so
                    -- sprayed vs unsprayed areas paint different colors. Otherwise fall
                    -- back to the field average. Eliminates the old two-pass approach
                    -- (polygon fill + separate zone overlay) which suffered from a 10m
                    -- vs 12m grid mismatch and 3px vs 4px dot-size bleed-through.
                    local fillPoints = self:getFieldFillPoints(fsField, mmStep)
                    if #fillPoints > 0 then
                        for _, pt in ipairs(fillPoints) do
                            local pr, pg, pb = avgR, avgG, avgB
                            if zoneData then
                                local cx   = math.floor(pt.x / zone.CELL_SIZE)
                                local cz   = math.floor(pt.z / zone.CELL_SIZE)
                                local cell = zoneData[tostring(cx * 10000 + cz)]
                                if cell then
                                    local val = getCellLayerValue(cell, layerIdx)
                                    if val then
                                        pr, pg, pb = self:valueToLayerColor(layerIdx, val)
                                    end
                                end
                            end
                            table.insert(self.minimapCentroids, {x = pt.x, z = pt.z, r = pr, g = pg, b = pb})
                        end
                    else
                        local x = fsField.posX or 0
                        local z = fsField.posZ or 0
                        table.insert(self.minimapCentroids, {x = x, z = z, r = avgR, g = avgG, b = avgB})
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

    -- When the GRLE heatmap overlay (SoilMinimapLayer) is active and rendering
    -- per-pixel NPK data, skip centroid dots — the overlay already paints the minimap.
    local sml = g_SoilFertilityManager and g_SoilFertilityManager.soilMinimapLayer
    if sml and sml._initialized and sml._usingDensityLayers then
        return
    end

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
            local dotSz  = getNormalizedScreenValues(SoilMapOverlay.MINIMAP_DOT_SIZE * SoilMapOverlay.minimapZoomSmoothed, SoilMapOverlay.MINIMAP_DOT_SIZE * SoilMapOverlay.minimapZoomSmoothed)
            local halfDot = dotSz * 0.5
            drawFilledRect(screenX - halfDot, screenY - halfDot, dotSz, dotSz,
                           centroid.r, centroid.g, centroid.b, alpha)
        end
    end

    -- Phase 2: Live Graphical Report next to minimap
end

-- (drawMiniReport removed — per-cell data shown via PDA map overlay tiles)

-- ── Minimap Zoom ──────────────────────────────────────────

-- Hooks IngameMapLayoutCircle and IngameMapLayoutSquare at the class level.
-- Called once from initialize(). Guards against double-hooking on level reload.
function SoilMapOverlay:installMinimapZoomHooks()
    local function hookLayout(layoutClass, name)
        if not layoutClass or layoutClass._sfZoomHooked then return end

        local origSet = layoutClass.setWorldSize
        layoutClass.setWorldSize = function(layout, ...)
            if origSet then origSet(layout, ...) end
            layout._sfOrigWorldSizeFactor = layout.worldSizeFactor
        end

        local origUpdate = layoutClass.updateScreenValues
        layoutClass.updateScreenValues = function(layout, ...)
            if layout._sfOrigWorldSizeFactor ~= nil then
                layout.worldSizeFactor = layout._sfOrigWorldSizeFactor * SoilMapOverlay.minimapZoomSmoothed
            end
            if origUpdate then origUpdate(layout, ...) end
        end

        layoutClass._sfZoomHooked = true
        SoilLogger.info("SoilMapOverlay: minimap zoom hooks installed (%s)", name)
    end

    hookLayout(IngameMapLayoutCircle, "Circle")
    hookLayout(IngameMapLayoutSquare, "Square")
    hookLayout(IngameMapLayoutSquareLarge, "SquareLarge")
end

-- Cycles through minimapZoomLevels: 1x → 2x → 4x → 1x → …
function SoilMapOverlay:cycleMinimapZoom()
    local levels = SoilMapOverlay.minimapZoomLevels
    for i, level in ipairs(levels) do
        if level == SoilMapOverlay.minimapZoomFactor then
            SoilMapOverlay.minimapZoomFactor = levels[i % #levels + 1]
            return
        end
    end
    SoilMapOverlay.minimapZoomFactor = levels[1]
end

-- Smoothly interpolates minimapZoomSmoothed toward minimapZoomFactor and
-- calls layout:updateScreenValues() when a change is in progress.
function SoilMapOverlay:updateMinimapZoom(dt)
    local target  = SoilMapOverlay.minimapZoomFactor
    local current = SoilMapOverlay.minimapZoomSmoothed
    if current == target then return end

    local speed = 0.005 * math.abs(target - current)
    if current < target then
        SoilMapOverlay.minimapZoomSmoothed = math.min(current + speed * dt, target)
    else
        SoilMapOverlay.minimapZoomSmoothed = math.max(current - speed * dt, target)
    end

    local hud = g_currentMission and g_currentMission.hud
    local ingameMap = hud and hud.ingameMap
    if ingameMap and ingameMap.layout and ingameMap.layout.updateScreenValues then
        ingameMap.layout:updateScreenValues()
    end
end

SoilLogger.info("SoilMapOverlay loaded")