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
    [7]  = "weed",              -- WeedSystem foliage density map (read-only)
    [8]  = "pestPressure",      -- soilPest GRLE
    [9]  = "diseasePressure",   -- soilDisease GRLE
    [10] = "compaction",        -- soilCompaction GRLE
}

function SoilMinimapLayer:_startBuild(soilMapOverlay)
    local layerIdx = self.settings and (self.settings.activeMapLayer or 0) or 0
    if layerIdx <= 0 then return end

    local ov = self._overlays[self._buildIdx]
    if not ov then return end

    if resetDensityMapVisualizationOverlay then
        resetDensityMapVisualizationOverlay(ov)
    end

    local layerSystem = self.soilSystem and self.soilSystem.layerSystem
    local fieldKey    = LAYER_FIELD_KEYS[layerIdx]

    -- ── Weed layer (game-native foliage density map) ──────────────────────────
    if fieldKey == "weed" and layerSystem and layerSystem.hasWeedLayer then
        local mapId, firstCh, numCh = layerSystem:getWeedMapData()
        if mapId then
            -- State 0 = no weed → transparent.
            -- States 1-N = weed present → yellow → orange-red by growth stage.
            local weedColors = {
                {0.95, 0.85, 0.20},  -- state 1: seedling — yellow
                {0.95, 0.70, 0.10},  -- state 2
                {0.90, 0.55, 0.05},  -- state 3
                {0.85, 0.35, 0.05},  -- state 4
                {0.80, 0.20, 0.05},  -- state 5+: mature — deep red-orange
            }
            local maxState = math.max(1, (2 ^ (numCh or 4)) - 1)
            for state = 1, maxState do
                local ci  = math.min(state, #weedColors)
                local r, g, b = weedColors[ci][1], weedColors[ci][2], weedColors[ci][3]
                -- Signature: (overlay, mapId, maskMapId, fieldMask, firstChannel, numChannels, state, r, g, b, a)
                setDensityMapVisualizationOverlayStateColor(ov, mapId, 0, 0, firstCh or 0, numCh or 4, state, r, g, b, 0.85)
            end
            self._usingDensityLayers = true
            generateDensityMapVisualizationOverlay(ov)
            self._buildHandle   = ov
            self._buildInFlight = true
            return
        end
    end

    -- ── Per-pixel path (nutrients + pest/disease/compaction GRLE layers) ──────
    -- layerSystem.hasData is set true only after writeFieldToLayers has pushed real
    -- soil values into the GRLE.  Without this guard the overlay generates but shows
    -- nothing (all pixels state 0 = transparent) and the polygon-dot fallback is
    -- suppressed, leaving the minimap blank for new or not-yet-loaded games.
    if layerSystem and layerSystem.available and layerSystem.hasData and fieldKey and fieldKey ~= "weed" then
        local entry = layerSystem:getLayerEntryForField(fieldKey)
        if entry then
            local handle = entry.handle
            local def    = entry.def
            -- Engine limit: 16 state color sets. Read top 4 bits of the 8-bit value.
            -- Signature: (overlay, mapId, maskMapId, fieldMask, firstChannel, numChannels, state, r, g, b, a)
            -- State 0 = raw bits 4-7 = 0 (unwritten/near-zero) → always transparent.
            -- State 0 = raw bits 4-7 = 0 (unwritten/near-zero) → always transparent.
            -- No masking: our GRLE starts as all-zeros; writeFieldToLayers only paints
            -- field AABBs, so only field areas ever have non-zero state values.
            -- Unmasked rendering therefore naturally restricts coloring to field areas.
            setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, 4, 4, 0, 0, 0, 0, 0)
            for i = 1, 15 do
                local semanticVal = def.minVal + (i / 15.0) * (def.maxVal - def.minVal)
                local r, g, b = soilMapOverlay:valueToLayerColor(layerIdx, semanticVal)
                setDensityMapVisualizationOverlayStateColor(ov, handle, 0, 0, 4, 4, i, r, g, b, 1.0)
            end
            self._usingDensityLayers = true
            generateDensityMapVisualizationOverlay(ov)
            self._buildHandle   = ov
            self._buildInFlight = true
            return
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

    -- PDA fullscreen map has isFullscreen as a truthy integer (1) while the HUD minimap has nil.
    -- Using a truthy check (not == true) correctly blocks PDA without blocking HUD.
    if mapSelf.isFullscreen then return end
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end

    -- Secondary identity guard: when the HUD minimap ref is resolvable, only draw on that instance.
    local hudMap = nil
    if g_currentMission and g_currentMission.hud then
        local hud = g_currentMission.hud
        hudMap = hud.ingameMap or hud.inGameMap or hud.minimap or hud.miniMap
    end
    if hudMap ~= nil and mapSelf ~= hudMap then return end

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

    local ov = self._overlays[self._showIdx]
    if not ov then return end

    -- Map world-rect to screen rect using the layout helpers.
    -- The DMV overlay covers the full terrain in UV space (0,0)→(1,1).
    -- We use UV mapping to select only the visible window defined by
    -- mapExtensionOffsetX/Z (pan) and mapExtensionScaleFactor (zoom),
    -- rendering the result at the full minimap screen rect.
    local layout = mapSelf.layout
    if not layout then return end

    local w, h = layout:getMapSize()
    local x, y = layout:getMapPosition()

    local extX = mapSelf.mapExtensionOffsetX    or 0
    local extZ = mapSelf.mapExtensionOffsetZ    or 0
    local scl  = mapSelf.mapExtensionScaleFactor or 1

    -- Visible terrain window in UV space (U = east-west, V = south-north)
    local uL = extX
    local uR = extX + scl
    local vB = extZ
    local vT = extZ + scl

    -- Render destination: full minimap screen rect
    local rx, ry, rw, rh = x, y, w, h

    -- Clip rect (circular minimap mask) — adjust screen rect and UV together
    local didClip = false
    if mapSelf.clipX1 ~= nil then
        local cx1, cy1 = mapSelf.clipX1, mapSelf.clipY1
        local cx2, cy2 = mapSelf.clipX2, mapSelf.clipY2
        local sx1 = math.max(x, cx1); local sy1 = math.max(y, cy1)
        local sx2 = math.min(x + w, cx2); local sy2 = math.min(y + h, cy2)
        if (sx2 - sx1) <= 0 or (sy2 - sy1) <= 0 then return end
        -- Remap UV to the clipped sub-region of the full minimap
        local uPerPx = scl / w
        local vPerPx = scl / h
        uL = extX + (sx1 - x) * uPerPx
        uR = extX + (sx2 - x) * uPerPx
        vB = extZ + (sy1 - y) * vPerPx
        vT = extZ + (sy2 - y) * vPerPx
        rx, ry, rw, rh = sx1, sy1, sx2 - sx1, sy2 - sy1
        didClip = true
    end

    -- UV corners: (bottom-left, top-left, bottom-right, top-right)
    setOverlayUVs(ov, uL, vB, uL, vT, uR, vB, uR, vT)

    if layout.getMapRotation then
        local rot = layout:getMapRotation()
        if rot and rot ~= 0 then
            setOverlayRotation(ov, rot, x + w * 0.5, y + h * 0.5)
        end
    end

    local alpha = 0.72
    if layout.getMapAlpha then
        local a = layout:getMapAlpha()
        if a then alpha = math.sqrt(a) * 0.72 end
    end
    setOverlayColor(ov, 1, 1, 1, alpha)
    renderOverlay(ov, rx, ry, rw, rh)

    if Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
        setOverlayUVs(ov, unpack(Overlay.DEFAULT_UVS))
    end
end
