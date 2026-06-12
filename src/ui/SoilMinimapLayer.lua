-- =========================================================
-- SoilMinimapLayer.lua
-- =========================================================
-- Renders a soil-nutrient heatmap on the HUD minimap using
-- the engine-native DensityMap Visualization Overlay API.
--
-- Strategy:
--   • One DMV overlay per layer, created lazily on first switch.
--     The engine allows max 8 unique GRLE handles per overlay;
--     using separate overlays means each overlay only ever sees
--     its own single handle — no accumulation, no engine limit hit.
--   • State colours are configured once per overlay and never
--     change at runtime, so re-generation after field data changes
--     is just generateDensityMapVisualizationOverlay(ov) with no
--     colour reconfiguration needed.
--   • generateDensityMapVisualizationOverlay is called in-place —
--     the engine keeps the previous result visible while the new
--     generation runs async, so there is no flicker.
--   • Only regenerates when data has changed (_dirty flag) or the
--     active layer changes — idle play costs nothing.
--   • getIsDensityMapVisualizationOverlayReady is polled every
--     200 ms, not every frame, to avoid per-frame overhead.
--
-- Fallback: if createDensityMapVisualizationOverlay is unavailable
-- (older engine builds) SoilMapOverlay falls back to polygon dots.
-- =========================================================

SoilMinimapLayer = {}
SoilMinimapLayer_mt = Class(SoilMinimapLayer)

SoilMinimapLayer.OVERLAY_RESOLUTION  = 512   -- texture resolution (width = height)
SoilMinimapLayer.REFRESH_INTERVAL_MS = 3000  -- max rebuild cadence when dirty (ms)
SoilMinimapLayer.POLL_INTERVAL_MS    = 200   -- how often to check if build finished (ms)

function SoilMinimapLayer.new(soilSystem, settings)
    local self = setmetatable({}, SoilMinimapLayer_mt)
    self.soilSystem = soilSystem
    self.settings   = settings
    self._initialized    = false
    -- Per-layer overlay table: [layerIdx] = { ov, configured, inFlight, hasShown }
    self._overlays       = {}
    self._resX           = SoilMinimapLayer.OVERLAY_RESOLUTION
    self._resY           = SoilMinimapLayer.OVERLAY_RESOLUTION
    self._buildInFlight  = false   -- tracks the CURRENT layer's in-flight state
    self._usingDensityLayers = false
    self._dirty          = true    -- force first build on init
    self._lastLayerIdx   = -1      -- detect layer-switch → force rebuild
    self._farmlandMap    = nil
    self._farmlandNumCh  = nil
    self._nextRebuildMs  = 0
    self._nextPollMs     = 0
    return self
end

-- ── Lifecycle ─────────────────────────────────────────────

function SoilMinimapLayer:initialize()
    if g_dedicatedServer then return false end
    if createDensityMapVisualizationOverlay == nil then
        SoilLogger.warning("SoilMinimapLayer: createDensityMapVisualizationOverlay not available — using polygon-fill fallback")
        return false
    end
    if not g_farmlandManager then return false end

    local farmlandMap = g_farmlandManager:getLocalMap()
    if not farmlandMap then
        SoilLogger.warning("SoilMinimapLayer: farmlandManager:getLocalMap() returned nil")
        return false
    end
    self._farmlandMap   = farmlandMap
    self._farmlandNumCh = getBitVectorMapNumChannels(farmlandMap)

    -- Match resolution to MapOverlayGenerator if possible
    local resX, resY = SoilMinimapLayer.OVERLAY_RESOLUTION, SoilMinimapLayer.OVERLAY_RESOLUTION
    local mog = g_currentMission and g_currentMission.mapOverlayGenerator
    if mog and MapOverlayGenerator and MapOverlayGenerator.OVERLAY_RESOLUTION then
        local fsRes = MapOverlayGenerator.OVERLAY_RESOLUTION.FOLIAGE_STATE
        if fsRes then
            local rx, ry = fsRes[1], fsRes[2]
            if rx and ry then
                if mog.adjustedOverlayResolution then
                    local ax, ay = mog:adjustedOverlayResolution({rx, ry})
                    if ax and ay then resX, resY = ax, ay else resX, resY = rx, ry end
                else
                    resX, resY = rx, ry
                end
            end
        end
    end
    self._resX = resX
    self._resY = resY

    -- Plain pixel overlay for drawing harvest trail dots on the minimap
    self._dotOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")

    self._initialized = true
    SoilLogger.info("[OK] SoilMinimapLayer initialized (per-layer DMV overlays %dx%d, lazy-created)", resX, resY)
    return true
end

function SoilMinimapLayer:delete()
    -- Overlay handles are managed by the engine; nothing to free from Lua.
    self._initialized = false
    self._overlays    = {}
    self._buildInFlight = false
    if self._dotOverlay and self._dotOverlay ~= 0 then
        delete(self._dotOverlay)
        self._dotOverlay = nil
    end
end

-- Mark the current layer's overlay dirty so the next rebuild cycle regenerates it.
-- Call this whenever GRLE data has been updated (spray, harvest, daily tick).
function SoilMinimapLayer:markDirty()
    self._dirty = true
end

-- ── Update / build cycle ──────────────────────────────────

function SoilMinimapLayer:update(dt, soilMapOverlay)
    if not self._initialized then return end

    local now = (g_currentMission and g_currentMission.time) or 0

    -- Poll async build (throttled — not every frame)
    if now >= self._nextPollMs then
        self._nextPollMs = now + SoilMinimapLayer.POLL_INTERVAL_MS
        self:_pollBuildFinished()
    end

    -- Detect layer change → mark dirty so we rebuild with the new layer's overlay
    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0
    if layerIdx ~= self._lastLayerIdx then
        self._lastLayerIdx  = layerIdx
        self._dirty         = true
        self._buildInFlight = false  -- cancel any in-flight build from the previous layer
    end

    -- Only rebuild when dirty and the previous build has finished
    if self._dirty and not self._buildInFlight and now >= self._nextRebuildMs then
        self._nextRebuildMs = now + SoilMinimapLayer.REFRESH_INTERVAL_MS
        self:_startBuild(soilMapOverlay)
    end
end

function SoilMinimapLayer:_pollBuildFinished()
    if not self._buildInFlight then return end
    if not getIsDensityMapVisualizationOverlayReady then return end
    local layerIdx = self._lastLayerIdx
    local entry = self._overlays[layerIdx]
    if not entry then return end
    if getIsDensityMapVisualizationOverlayReady(entry.ov) then
        entry.inFlight    = false
        entry.hasShown    = true
        self._buildInFlight = false
    end
end

-- Maps settings.activeMapLayer index → SoilLayerSystem field key.
-- Indices must match SoilMapOverlay.LAYER_KEYS exactly.
-- [6] urgency is computed (no GRLE); [7] weed uses the game WeedSystem foliage map.
local LAYER_FIELD_KEYS = {
    [1]  = "nitrogen",
    [2]  = "phosphorus",
    [3]  = "potassium",
    [4]  = "pH",
    [5]  = "organicMatter",
    -- [6] = urgency: computed from N/P/K — no density map layer
    [7]  = "weed",
    [8]  = "pestPressure",
    [9]  = "diseasePressure",
    [10] = "compaction",
}

-- Engine limit: 16 state colour entries per DMV overlay configuration.
-- We read only the top 4 bits of each 8-bit GRLE byte (firstChannel=4, numChannels=4)
-- which maps the full 0-255 byte range to 16 coarser states (0=transparent, 1-15=colour).
local GRLE_FIRST_CH  = 4
local GRLE_NUM_CH    = 4
local GRLE_STATE_MAX = 15

-- Returns or lazily creates the overlay entry for layerIdx.
-- Each overlay is dedicated to exactly one GRLE handle, avoiding the engine's
-- 8-unique-handle-per-overlay limit when cycling through all soil layers.
function SoilMinimapLayer:_getOrCreateOverlay(layerIdx)
    if self._overlays[layerIdx] then return self._overlays[layerIdx] end
    local ov = createDensityMapVisualizationOverlay("SF_Heatmap_" .. layerIdx, self._resX, self._resY)
    if not ov then
        SoilLogger.warning("SoilMinimapLayer: failed to create overlay for layer %d", layerIdx)
        return nil
    end
    local entry = { ov = ov, configured = false, inFlight = false, hasShown = false }
    self._overlays[layerIdx] = entry
    SoilLogger.info("SoilMinimapLayer: created overlay for layer %d", layerIdx)
    return entry
end

function SoilMinimapLayer:_startBuild(soilMapOverlay)
    local layerIdx = self._lastLayerIdx
    if layerIdx <= 0 then return end

    self._dirty = false  -- clear before build; markDirty() during flight re-queues next cycle

    local layerSystem = self.soilSystem and self.soilSystem.layerSystem
    local fieldKey    = LAYER_FIELD_KEYS[layerIdx]

    -- ── Weed layer (game-native foliage density map) ──────────────────────────
    if fieldKey == "weed" and layerSystem and layerSystem.hasWeedLayer then
        local mapId, firstCh, numCh = layerSystem:getWeedMapData()
        if mapId then
            local entry = self:_getOrCreateOverlay(layerIdx)
            if entry then
                local ov = entry.ov
                if not entry.configured then
                    local weedColors = {
                        {0.95, 0.85, 0.20},
                        {0.95, 0.70, 0.10},
                        {0.90, 0.55, 0.05},
                        {0.85, 0.35, 0.05},
                        {0.80, 0.20, 0.05},
                    }
                    local maxState = math.max(1, (2 ^ (numCh or 4)) - 1)
                    for state = 1, maxState do
                        local ci  = math.min(state, #weedColors)
                        local r, g, b = weedColors[ci][1], weedColors[ci][2], weedColors[ci][3]
                        setDensityMapVisualizationOverlayStateColor(ov, mapId, 0, 0, firstCh or 0, numCh or 4, state, r, g, b, 0.85)
                    end
                    entry.configured = true
                    SoilLogger.info("SoilMinimapLayer: weed overlay configured (mapId=%s firstCh=%s numCh=%s)", tostring(mapId), tostring(firstCh), tostring(numCh))
                end
                self._usingDensityLayers = true
                generateDensityMapVisualizationOverlay(ov)
                entry.inFlight    = true
                self._buildInFlight = true
                return
            end
        end
    end

    -- ── Per-pixel GRLE path (nutrients + pest/disease/compaction) ─────────────
    -- Each layer gets its own dedicated overlay so each overlay only ever has
    -- one GRLE handle registered — avoids the engine's 8-handle-per-overlay limit.
    if layerSystem and layerSystem.available and fieldKey and fieldKey ~= "weed" then
        local grleEntry = layerSystem:getLayerEntryForField(fieldKey)
        if grleEntry then
            local ovEntry = self:_getOrCreateOverlay(layerIdx)
            if ovEntry then
                local ov     = ovEntry.ov
                local handle = grleEntry.handle
                local def    = grleEntry.def
                -- Configure state colours once; they don't change at runtime.
                if not ovEntry.configured then
                    setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, GRLE_FIRST_CH, GRLE_NUM_CH, 0, 0, 0, 0, 0)
                    for i = 1, GRLE_STATE_MAX do
                        local semanticVal = def.minVal + (i / GRLE_STATE_MAX) * (def.maxVal - def.minVal)
                        local r, g, b = soilMapOverlay:valueToLayerColor(layerIdx, semanticVal)
                        setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, GRLE_FIRST_CH, GRLE_NUM_CH, i, r, g, b, 1.0)
                    end
                    ovEntry.configured = true
                    SoilLogger.info("SoilMinimapLayer: GRLE overlay configured handle=%s key=%s firstCh=%d numCh=%d", tostring(handle), tostring(fieldKey), GRLE_FIRST_CH, GRLE_NUM_CH)
                end
                self._usingDensityLayers = true
                generateDensityMapVisualizationOverlay(ov)
                ovEntry.inFlight    = true
                self._buildInFlight = true
                return
            end
        end
    end

    -- ── Fallback: polygon-fill dots via SoilMapOverlay ────────────────────────
    self._usingDensityLayers = false
end

-- ── Rendering ─────────────────────────────────────────────

-- Called from IngameMap.drawFields with the actual IngameMap instance being drawn.
-- Fires for both the HUD minimap and the PDA fullscreen map — guards handle each.
function SoilMinimapLayer:draw(mapSelf)
    if not self._initialized then return end
    if not mapSelf then return end

    -- IngameMap:setFullscreen(true) is used for the M-key / PDA full map view.
    -- Minimap size states (1=small, 2=medium, 3=large) keep isFullscreen=false.
    if mapSelf.isFullscreen then return end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end

    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0

    if not self._usingDensityLayers then
        -- No GRLE density-map layers on this terrain — hand off to polygon centroid dots.
        local sfm = g_SoilFertilityManager
        if sfm and sfm.soilMapOverlay then
            sfm.soilMapOverlay:onDrawMinimap(mapSelf)
        end
        -- Still show the layer indicator in the polygon fallback path
        if layerIdx > 0 then
            self:drawLayerIndicator(mapSelf:getPosition(), mapSelf:getWidth(), mapSelf:getHeight(), layerIdx)
        end
        return
    end

    if layerIdx <= 0 then return end

    -- Map terrain-space → screen rect using the same math the game uses for
    -- its built-in BMP overlay layers (proven in v2.2.5).
    local layout = mapSelf.layout
    if not layout then return end

    -- Draw the layer indicator before any overlay-readiness or layout-type guards
    -- that might return early. mapSelf inherits HUDElement — getPosition/getWidth/
    -- getHeight return the minimap widget's screen-space bounds.
    self:drawLayerIndicator(mapSelf:getPosition(), mapSelf:getWidth(), mapSelf:getHeight(), layerIdx)

    -- Circle minimap rotates with the vehicle heading; our terrain-space overlay doesn't
    -- transform correctly in that coordinate frame and drifts. Skip until fixed (#578).
    if layout:isa(IngameMapLayoutCircle) then return end

    local ovEntry = self._overlays[layerIdx]
    if not ovEntry or not ovEntry.hasShown then return end

    local ov = ovEntry.ov
    if not ov then return end

    local w, h   = layout:getMapSize()
    local x, y   = layout:getMapPosition()
    local px, py
    if layout.getMapPivot then px, py = layout:getMapPivot() end
    px = px or (x + w * 0.5)
    py = py or (y + h * 0.5)

    local extX = mapSelf.mapExtensionOffsetX    or 0
    local extZ = mapSelf.mapExtensionOffsetZ    or 0
    local scl  = mapSelf.mapExtensionScaleFactor or 1

    -- Full-terrain screen rect at current zoom
    local mx = x + w * extX
    local my = y + h * extZ
    local mw = w * scl
    local mh = h * scl
    -- Rotation pivot: absolute screen coordinates of the map centre.
    -- px/py are already in screen space from layout:getMapPivot() (or widget centre).
    local rx = px
    local ry = py

    -- Always clip the overlay to the minimap widget bounds.
    -- mapSelf.clipX1 is passed as a draw-call parameter, not stored as a property, so it
    -- is nil here. Fall back to the widget rect from layout so that on large maps (16x etc.)
    -- where mapExtensionScaleFactor > 1 and the terrain rect extends beyond the widget,
    -- we still extract the correct UV slice and don't render an oversized off-screen rect.
    local cx1 = mapSelf.clipX1 or x
    local cy1 = mapSelf.clipY1 or y
    local cx2 = mapSelf.clipX2 or (x + w)
    local cy2 = mapSelf.clipY2 or (y + h)

    local x1, y1 = mx, my
    local x2, y2 = mx + mw, my + mh
    if x1 == x2 or y1 == y2 then return end

    local rx1 = math.max(x1, cx1); local ry1 = math.max(y1, cy1)
    local rx2 = math.min(x2, cx2); local ry2 = math.min(y2, cy2)
    if (rx2 - rx1) <= 0 or (ry2 - ry1) <= 0 then return end

    local uL = (rx1 - x1) / (x2 - x1); local vT = (ry1 - y1) / (y2 - y1)
    local uR = (rx2 - x1) / (x2 - x1); local vB = (ry2 - y1) / (y2 - y1)
    mx, my, mw, mh = rx1, ry1, rx2 - rx1, ry2 - ry1

    setOverlayUVs(ov, uL, vT, uL, vB, uR, vT, uR, vB)

    if layout.getMapRotation then
        local rot = layout:getMapRotation()
        if rot and rot ~= 0 then
            setOverlayRotation(ov, rot, rx, ry)
        end
    end

    local alpha = 0.72
    if layout.getMapAlpha then
        local a = layout:getMapAlpha()
        if a then alpha = math.sqrt(a) * 0.72 end
    end
    setOverlayColor(ov, 1, 1, 1, alpha)
    renderOverlay(ov, mx, my, mw, mh)

    if Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
        setOverlayUVs(ov, unpack(Overlay.DEFAULT_UVS))
    end

    if not self.settings or self.settings.showWorkTrail ~= false then
        self:drawHarvestTrailDots(mapSelf)
        self:drawTillageTrailDots(mapSelf)
    end
end

-- Short labels for each layer index (displayed in minimap corner).
local LAYER_LABEL = {
    [1]  = "N",        [2]  = "P",      [3]  = "K",
    [4]  = "pH",       [5]  = "OM",     [6]  = "!",
    [7]  = "Weed",     [8]  = "Pest",   [9]  = "Disease",
    [10] = "Compact",
}
-- Matching accent colours (same palette as SoilMapOverlay.LAYER_COLORS).
local LAYER_LABEL_COLOR = {
    [1]  = {0.40, 0.90, 0.40},  [2]  = {0.40, 0.70, 1.00},
    [3]  = {0.90, 0.70, 0.25},  [4]  = {0.80, 0.40, 1.00},
    [5]  = {0.60, 0.35, 0.10},  [6]  = {0.95, 0.25, 0.25},
    [7]  = {0.20, 0.70, 0.20},  [8]  = {0.85, 0.75, 0.10},
    [9]  = {0.80, 0.10, 0.80},  [10] = {0.55, 0.30, 0.10},
}

-- Draws a small "N", "pH", etc. tag in the top-left corner of the minimap widget.
-- mx/my = bottom-left of the (clipped) minimap rect; mw/mh = size.
function SoilMinimapLayer:drawLayerIndicator(mx, my, mw, mh, layerIdx)
    local label = LAYER_LABEL[layerIdx]
    if not label then return end

    local col = LAYER_LABEL_COLOR[layerIdx] or {1, 1, 1}
    local sz  = 0.014   -- larger for readability
    local pad = 0.005

    -- Top-left corner: y goes up from bottom, so top = my + mh
    local tx = mx + pad
    local ty = my + mh - sz - pad

    -- Dark semi-transparent pill background
    if self._dotOverlay and self._dotOverlay ~= 0 then
        local bgW = sz * (#label * 0.62 + 0.4)
        local bgH = sz * 1.35
        setOverlayColor(self._dotOverlay, 0, 0, 0, 0.52)
        renderOverlay(self._dotOverlay, tx - pad * 0.5, ty - pad * 0.3, bgW, bgH)
    end

    -- Text with shadow
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(0, 0, 0, 0.70)
    renderText(tx + 0.0008, ty - 0.0008, sz, label)
    setTextColor(col[1], col[2], col[3], 0.95)
    renderText(tx, ty, sz, label)

    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

--- Draws earth-brown/tan pixel dots on the minimap for each tilled cell today.
--- Dark brown = plow pass, tan = cultivate pass.
function SoilMinimapLayer:drawTillageTrailDots(mapSelf)
    local dotOv = self._dotOverlay
    if not dotOv or dotOv == 0 then return end

    local soilSys = self.soilSystem
    if not soilSys or not soilSys.fieldData then return end

    local layout = mapSelf and (mapSelf.fullScreenLayout or mapSelf.layout)
    if not layout or not layout.getMapObjectPosition then return end

    local worldSizeX = mapSelf.worldSizeX or (g_currentMission and g_currentMission.terrainSize) or 2048
    local worldSizeZ = mapSelf.worldSizeZ or (g_currentMission and g_currentMission.terrainSize) or 2048
    if worldSizeX == 0 or worldSizeZ == 0 then return end

    local extX = mapSelf.mapExtensionOffsetX    or 0
    local extZ = mapSelf.mapExtensionOffsetZ    or 0
    local scl  = mapSelf.mapExtensionScaleFactor or 1
    local offX = mapSelf.worldCenterOffsetX     or 0
    local offZ = mapSelf.worldCenterOffsetZ     or 0

    local dotSz = 0.0038
    local half  = dotSz * 0.5

    for _, field in pairs(soilSys.fieldData) do
        local pts = field.tillageTrailPts
        if pts then
            for _, pt in ipairs(pts) do
                if pt.isPlow then
                    setOverlayColor(dotOv, 0.55, 0.28, 0.05, 0.65)
                else
                    setOverlayColor(dotOv, 0.72, 0.52, 0.22, 0.60)
                end
                local objX = ((pt.wx + offX) / worldSizeX) * scl + extX
                local objZ = ((pt.wz + offZ) / worldSizeZ) * scl + extZ
                local sx, sy = layout:getMapObjectPosition(objX, objZ, 0, 0)
                if sx and sy then
                    renderOverlay(dotOv, sx - half, sy - half, dotSz, dotSz)
                end
            end
        end
    end
end

--- Draws amber pixel dots on the minimap for each harvested cell in the current session.
function SoilMinimapLayer:drawHarvestTrailDots(mapSelf)
    local dotOv = self._dotOverlay
    if not dotOv or dotOv == 0 then return end

    local soilSys = self.soilSystem
    if not soilSys or not soilSys.fieldData then return end

    local layout = mapSelf and (mapSelf.fullScreenLayout or mapSelf.layout)
    if not layout or not layout.getMapObjectPosition then return end

    local worldSizeX = mapSelf.worldSizeX or (g_currentMission and g_currentMission.terrainSize) or 2048
    local worldSizeZ = mapSelf.worldSizeZ or (g_currentMission and g_currentMission.terrainSize) or 2048
    if worldSizeX == 0 or worldSizeZ == 0 then return end

    local extX = mapSelf.mapExtensionOffsetX    or 0
    local extZ = mapSelf.mapExtensionOffsetZ    or 0
    local scl  = mapSelf.mapExtensionScaleFactor or 1
    local offX = mapSelf.worldCenterOffsetX     or 0
    local offZ = mapSelf.worldCenterOffsetZ     or 0

    local dotSz = 0.0038
    local half  = dotSz * 0.5

    setOverlayColor(dotOv, 0.95, 0.65, 0.10, 0.60)

    for _, field in pairs(soilSys.fieldData) do
        local pts = field.harvestTrailPts
        if pts then
            for _, pt in ipairs(pts) do
                local objX = ((pt.wx + offX) / worldSizeX) * scl + extX
                local objZ = ((pt.wz + offZ) / worldSizeZ) * scl + extZ
                local sx, sy = layout:getMapObjectPosition(objX, objZ, 0, 0)
                if sx and sy then
                    renderOverlay(dotOv, sx - half, sy - half, dotSz, dotSz)
                end
            end
        end
    end
end
