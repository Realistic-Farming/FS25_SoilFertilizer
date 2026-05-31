-- =========================================================
-- SoilMinimapLayer.lua
-- =========================================================
-- Renders a soil-nutrient heatmap on the HUD minimap using
-- the engine-native DensityMap Visualization Overlay API.
--
-- Strategy (mirrors BMP_MiniMapLayers):
--   • One createDensityMapVisualizationOverlay per buffer (2 total).
--   • Before each generate, we call setDensityMapVisualizationOverlayStateColor
--     once per owned farmland using the farmland bit-vector map —
--     exactly how MapOverlayGenerator colours the farmland-ownership overlay.
--   • generateDensityMapVisualizationOverlay is async; we poll with
--     getIsDensityMapVisualizationOverlayReady and swap buffers on done.
--   • The show-buffer is rendered each frame in the IngameMap.drawFields hook.
--
-- Fallback: if createDensityMapVisualizationOverlay is unavailable (older
-- engine builds) SoilMapOverlay falls back to polygon-fill dots.
-- =========================================================

SoilMinimapLayer = {}
SoilMinimapLayer_mt = Class(SoilMinimapLayer)

SoilMinimapLayer.OVERLAY_RESOLUTION = 512  -- texture resolution (width = height)
SoilMinimapLayer.REFRESH_INTERVAL_MS = 2000  -- rebuild every 2 s

function SoilMinimapLayer.new(soilSystem, settings)
    local self = setmetatable({}, SoilMinimapLayer_mt)
    self.soilSystem = soilSystem
    self.settings   = settings
    self._initialized    = false
    self._overlays       = {nil, nil}   -- double buffer
    self._showIdx        = 1
    self._buildIdx       = 2
    self._buildInFlight  = false
    self._buildHandle    = nil          -- overlay handle currently generating
    self._hasShownOnce   = false
    self._farmlandMap    = nil
    self._farmlandNumCh  = nil
    self._nextRebuildMs  = 0
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

    self._overlays[1] = createDensityMapVisualizationOverlay("SF_SoilHeatmapA", resX, resY)
    self._overlays[2] = createDensityMapVisualizationOverlay("SF_SoilHeatmapB", resX, resY)

    if not self._overlays[1] or not self._overlays[2] then
        SoilLogger.warning("SoilMinimapLayer: failed to create double-buffer overlays")
        return false
    end

    self._initialized = true
    SoilLogger.info("[OK] SoilMinimapLayer initialized (DMV overlay %dx%d, double-buffered)", resX, resY)
    return true
end

function SoilMinimapLayer:delete()
    -- Overlay handles are managed by the engine; nothing to free from Lua.
    self._initialized   = false
    self._overlays      = {nil, nil}
    self._buildInFlight = false
    self._buildHandle   = nil
end

-- ── Update / build cycle ──────────────────────────────────

function SoilMinimapLayer:update(dt, soilMapOverlay)
    if not self._initialized then return end

    -- Poll async build
    self:_pollBuildFinished()

    -- Schedule rebuild
    local now = (g_currentMission and g_currentMission.time) or 0
    if now >= self._nextRebuildMs and not self._buildInFlight then
        self._nextRebuildMs = now + SoilMinimapLayer.REFRESH_INTERVAL_MS
        self:_startBuild(soilMapOverlay)
    end
end

function SoilMinimapLayer:_pollBuildFinished()
    if not self._buildInFlight or not self._buildHandle then return end
    if not getIsDensityMapVisualizationOverlayReady then return end
    if getIsDensityMapVisualizationOverlayReady(self._buildHandle) then
        -- Build done — swap buffers so the fresh overlay is now shown
        self._showIdx, self._buildIdx = self._buildIdx, self._showIdx
        self._buildInFlight = false
        self._buildHandle   = nil
        self._hasShownOnce  = true
    end
end

-- Maps PDA layer index to the SoilLayerSystem field key and GRLE layer name.
-- Layers 1-5 have per-pixel GRLE density maps; layers 6+ fall back to farmland coloring.
local LAYER_FIELD_KEYS = {
    [1] = "nitrogen",
    [2] = "phosphorus",
    [3] = "potassium",
    [4] = "pH",
    [5] = "organicMatter",
}

function SoilMinimapLayer:_startBuild(soilMapOverlay)
    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0
    if layerIdx <= 0 then return end

    local ov = self._overlays[self._buildIdx]
    if not ov then return end

    -- Clear previously-painted state colors so old data doesn't bleed through.
    if resetDensityMapVisualizationOverlay then
        resetDensityMapVisualizationOverlay(ov)
    end

    -- ── Per-pixel path (layers 1-5 with GRLE density maps) ───────────────────
    local layerSystem = self.soilSystem and self.soilSystem.layerSystem
    local fieldKey    = LAYER_FIELD_KEYS[layerIdx]

    if layerSystem and layerSystem.available and layerSystem.hasData and fieldKey then
        local entry = layerSystem:getLayerEntryForField(fieldKey)
        if entry then
            local handle = entry.handle
            local def    = entry.def
            -- Assign a color to every possible encoded value 0-255.
            -- Encoded value 0 means "no data written to this pixel" — keep transparent.
            -- Values 1-255 map to a decoded semantic float which gets a status color.
            for i = 1, 255 do
                local semanticVal = def.minVal + (i / 255.0) * (def.maxVal - def.minVal)
                local r, g, b = soilMapOverlay:valueToLayerColor(layerIdx, semanticVal)
                setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, 0, 8, i, r, g, b, 1.0)
            end
            self._usingDensityLayers = true
            generateDensityMapVisualizationOverlay(ov)
            self._buildHandle   = ov
            self._buildInFlight = true
            return
        end
    end

    -- ── Farmland-map fallback (layers 6-10, or maps without GRLE files) ───────
    -- SoilMapOverlay.onDrawMinimap already renders field polygon fill dots for
    -- this case (it skips only when _usingDensityLayers = true). We intentionally
    -- do NOT generate a DMV overlay here because the farmland ownership BVM covers
    -- entire purchased parcels including buildings, not just field polygons.
    self._usingDensityLayers = false
end

-- ── Rendering ─────────────────────────────────────────────

-- Called from IngameMap.drawFields (or FSBaseMission.draw as fallback).
-- mapSelf is the IngameMap instance.
function SoilMinimapLayer:draw(mapSelf)
    if not self._initialized then return end
    if not self._hasShownOnce then return end
    if not self._usingDensityLayers then return end
    if not mapSelf then return end

    -- Only render on the HUD minimap, never on the PDA fullscreen map.
    -- g_currentMission.hud.ingameMap is the authoritative HUD minimap instance.
    local hudMap = nil
    if g_currentMission and g_currentMission.hud then
        local hud = g_currentMission.hud
        hudMap = hud.ingameMap or hud.inGameMap or hud.minimap or hud.miniMap
    end
    if hudMap ~= nil and mapSelf ~= hudMap then return end

    if mapSelf.isFullscreen == true then return end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end

    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0
    if layerIdx <= 0 then return end

    local ov = self._overlays[self._showIdx]
    if not ov then return end

    -- Map world-rect → screen rect using the same layout helpers BMP uses
    local layout = mapSelf.layout
    if not layout then return end

    local w, h = layout:getMapSize()
    local x, y = layout:getMapPosition()
    local px, py = layout:getMapPivot()

    local extX = mapSelf.mapExtensionOffsetX    or 0
    local extZ = mapSelf.mapExtensionOffsetZ    or 0
    local scl  = mapSelf.mapExtensionScaleFactor or 1

    local mx = x + w * extX
    local my = y + h * extZ
    local mw = w * scl
    local mh = h * scl
    local rx = (px + x) - mx
    local ry = (py + y) - my

    -- Clip rect (circle minimap, etc.)
    local didClip  = false
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
        setOverlayRotation(ov, layout:getMapRotation(), rx, ry)
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
