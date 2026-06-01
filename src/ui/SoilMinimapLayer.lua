-- =========================================================
-- SoilMinimapLayer.lua
-- =========================================================
-- Renders a soil-nutrient heatmap on the HUD minimap using
-- the engine-native DensityMap Visualization Overlay API.
--
-- Strategy:
--   • Single overlay; generateDensityMapVisualizationOverlay is called
--     in-place — the engine keeps the previous result visible while the
--     new generation runs async, so there is no flicker.
--   • Only regenerates when spray data has changed (_dirty flag) or the
--     active layer changes — idle play costs nothing.
--   • getIsDensityMapVisualizationOverlayReady is polled every 200 ms,
--     not every frame, to avoid per-frame overhead.
--
-- Fallback: if createDensityMapVisualizationOverlay is unavailable (older
-- engine builds) SoilMapOverlay falls back to polygon-fill dots.
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
    self._overlay        = nil           -- single overlay; regenerated in-place
    self._buildInFlight  = false
    self._hasShownOnce   = false
    self._dirty          = true          -- force first build on init
    self._lastLayerIdx   = -1            -- detect layer-switch → force rebuild
    self._farmlandMap    = nil
    self._farmlandNumCh  = nil
    self._nextRebuildMs  = 0
    self._nextPollMs     = 0
    self._lastOverlayHandle = nil  -- track previous DMV handle to clear its state colors on layer switch
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

    self._overlay = createDensityMapVisualizationOverlay("SF_SoilHeatmap", resX, resY)

    if not self._overlay then
        SoilLogger.warning("SoilMinimapLayer: failed to create DMV overlay")
        return false
    end

    self._initialized = true
    SoilLogger.info("[OK] SoilMinimapLayer initialized (DMV overlay %dx%d, single-buffer)", resX, resY)
    return true
end

function SoilMinimapLayer:delete()
    -- Overlay handles are managed by the engine; nothing to free from Lua.
    self._initialized   = false
    self._overlay       = nil
    self._buildInFlight = false
end

-- Call this whenever spray data has been written to the GRLE (updatePixelForField).
-- Marks the overlay dirty so the next rebuild cycle will regenerate it.
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

    -- Detect layer change → mark dirty so we rebuild with the new colour ramp
    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0
    if layerIdx ~= self._lastLayerIdx then
        self._lastLayerIdx = layerIdx
        self._dirty = true
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
    if getIsDensityMapVisualizationOverlayReady(self._overlay) then
        self._buildInFlight = false
        self._hasShownOnce  = true
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
-- The GRLE is written with full 8-bit precision by updatePixelForField; the DMV just
-- reads fewer bits so all 16 state slots are used meaningfully.
local GRLE_FIRST_CH  = 4
local GRLE_NUM_CH    = 4
local GRLE_STATE_MAX = 15

function SoilMinimapLayer:_startBuild(soilMapOverlay)
    local layerIdx = self._lastLayerIdx
    if layerIdx <= 0 then return end

    local ov = self._overlay
    if not ov then return end

    self._dirty = false  -- clear before build; markDirty() during flight re-queues next cycle

    local layerSystem = self.soilSystem and self.soilSystem.layerSystem
    local fieldKey    = LAYER_FIELD_KEYS[layerIdx]

    SoilLogger.info("SoilMinimapLayer: _startBuild layerIdx=%d fieldKey=%s layerSysAvail=%s lastHandle=%s",
        layerIdx, tostring(fieldKey),
        tostring(layerSystem and layerSystem.available),
        tostring(self._lastOverlayHandle))

    -- ── Weed layer (game-native foliage density map) ──────────────────────────
    if fieldKey == "weed" and layerSystem and layerSystem.hasWeedLayer then
        local mapId, firstCh, numCh = layerSystem:getWeedMapData()
        SoilLogger.info("SoilMinimapLayer: weed path — mapId=%s firstCh=%s numCh=%s", tostring(mapId), tostring(firstCh), tostring(numCh))
        if mapId then
            if self._lastOverlayHandle and self._lastOverlayHandle ~= mapId then
                for s = 0, GRLE_STATE_MAX do
                    setDensityMapVisualizationOverlayStateColor(ov, self._lastOverlayHandle, 0, 0, GRLE_FIRST_CH, GRLE_NUM_CH, s, 0, 0, 0, 0)
                end
            end
            self._lastOverlayHandle = mapId
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
            self._usingDensityLayers = true
            generateDensityMapVisualizationOverlay(ov)
            self._buildInFlight = true
            SoilLogger.info("SoilMinimapLayer: weed DMV generate triggered (mapId=%s)", tostring(mapId))
            return
        end
    end

    -- ── Per-pixel GRLE path (nutrients + pest/disease/compaction) ─────────────
    if layerSystem and layerSystem.available and fieldKey and fieldKey ~= "weed" then
        local entry = layerSystem:getLayerEntryForField(fieldKey)
        SoilLogger.info("SoilMinimapLayer: GRLE path — entry=%s", entry and ("handle="..tostring(entry.handle)) or "NIL")
        if entry then
            local handle = entry.handle
            local def    = entry.def
            if self._lastOverlayHandle and self._lastOverlayHandle ~= handle then
                SoilLogger.info("SoilMinimapLayer: clearing prev handle %s states before configuring handle %s", tostring(self._lastOverlayHandle), tostring(handle))
                for s = 0, GRLE_STATE_MAX do
                    setDensityMapVisualizationOverlayStateColor(ov, self._lastOverlayHandle, 0, 0, GRLE_FIRST_CH, GRLE_NUM_CH, s, 0, 0, 0, 0)
                end
            end
            self._lastOverlayHandle = handle
            setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, GRLE_FIRST_CH, GRLE_NUM_CH, 0, 0, 0, 0, 0)
            for i = 1, GRLE_STATE_MAX do
                local semanticVal = def.minVal + (i / GRLE_STATE_MAX) * (def.maxVal - def.minVal)
                local r, g, b = soilMapOverlay:valueToLayerColor(layerIdx, semanticVal)
                setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, GRLE_FIRST_CH, GRLE_NUM_CH, i, r, g, b, 1.0)
            end
            self._usingDensityLayers = true
            generateDensityMapVisualizationOverlay(ov)
            self._buildInFlight = true
            SoilLogger.info("SoilMinimapLayer: GRLE DMV generate triggered handle=%s key=%s firstCh=%d numCh=%d", tostring(handle), tostring(fieldKey), GRLE_FIRST_CH, GRLE_NUM_CH)
            return
        end
    end

    -- ── Fallback: polygon-fill dots via SoilMapOverlay ────────────────────────
    SoilLogger.info("SoilMinimapLayer: fallback path — layerSysAvail=%s fieldKey=%s", tostring(layerSystem and layerSystem.available), tostring(fieldKey))
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

    if not self._usingDensityLayers then
        -- No GRLE density-map layers on this terrain — hand off to polygon centroid dots.
        -- mapSelf is the correct HUD minimap instance here (from drawFields hook),
        -- unlike the PDA ref stored in ingameMapRef which would hit the isFullscreen guard.
        local sfm = g_SoilFertilityManager
        if sfm and sfm.soilMapOverlay then
            sfm.soilMapOverlay:onDrawMinimap(mapSelf)
        end
        return
    end

    if not self._hasShownOnce then return end

    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0
    if layerIdx <= 0 then return end

    local ov = self._overlay
    if not ov then return end

    -- Map terrain-space → screen rect using the same math the game uses for
    -- its built-in BMP overlay layers (proven in v2.2.5).
    -- The DMV overlay covers the full terrain; mapExtension* describe the
    -- visible window.  We position + scale the overlay so the visible window
    -- exactly fills the minimap widget rect, then let the minimap clip it.
    local layout = mapSelf.layout
    if not layout then return end

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
    local rx = (px + x) - mx
    local ry = (py + y) - my

    -- Clip rect (circular minimap mask)
    local didClip = false
    local uL, vT, uR, vB = 0, 0, 1, 1
    if mapSelf.clipX1 ~= nil then
        local x1, y1 = mx, my
        local x2, y2 = mx + mw, my + mh
        local cx1, cy1 = mapSelf.clipX1, mapSelf.clipY1
        local cx2, cy2 = mapSelf.clipX2, mapSelf.clipY2
        local rx1 = math.max(x1, cx1); local ry1 = math.max(y1, cy1)
        local rx2 = math.min(x2, cx2); local ry2 = math.min(y2, cy2)
        if (rx2 - rx1) <= 0 or (ry2 - ry1) <= 0 then return end
        uL = (rx1 - x1) / (x2 - x1); vT = (ry1 - y1) / (y2 - y1)
        uR = (rx2 - x1) / (x2 - x1); vB = (ry2 - y1) / (y2 - y1)
        mx, my, mw, mh = rx1, ry1, rx2 - rx1, ry2 - ry1
        didClip = true
    end

    if didClip then
        setOverlayUVs(ov, uL, vT, uL, vB, uR, vT, uR, vB)
    end

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

    if didClip and Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
        setOverlayUVs(ov, unpack(Overlay.DEFAULT_UVS))
    end
end
