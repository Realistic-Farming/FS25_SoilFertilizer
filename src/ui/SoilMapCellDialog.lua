--- Soil Map Cell Inspection Dialog
-- @author TisonK
-- @version 1.0.0.1

SoilMapCellDialog = {}
local SoilMapCellDialog_mt = Class(SoilMapCellDialog, ScreenElement)

-- Capture mod name at load time — g_currentModName is only valid during loading.
local SF_MOD_NAME = g_currentModName

-- Resolve a translation key using the mod-scoped i18n instance.
local function tr(key, fallback)
    local modEnv = g_modEnvironments and g_modEnvironments[SF_MOD_NAME]
    local i18n = (modEnv and modEnv.i18n) or g_i18n
    if i18n then
        local ok, text = pcall(function() return i18n:getText(key) end)
        if ok and text and text ~= "" and text ~= ("$l10n_" .. key) then
            return text
        end
    end
    return fallback or key
end

function SoilMapCellDialog.new(target, custom_mt)
    local self = ScreenElement.new(target, custom_mt or SoilMapCellDialog_mt)
    
    self.soilSystem = g_soilFertilitySystem
    self.overlay = g_soilMapOverlay
    
    return self
end

function SoilMapCellDialog:onOpen()
    SoilMapCellDialog:superClass().onOpen(self)

    if self.mapElement then
        self.mapElement:setMapCenter(0.5, 0.5)
        self.mapElement:setMapZoom(1.0)
    end

    if self.detailsGroup then
        self.detailsGroup:setVisible(false)
    end

    if self.hintText then
        self.hintText:setVisible(true)
        self.hintText:setText(tr("sf_cell_click_hint", "Click map to inspect cell"))
    end

    if self.overlay then
        self.overlay.isMapOpen = true
    end

    -- Auto-show data for the current player/vehicle position so the dialog
    -- is never blank on open — onClickMap handles the "no farmland here" case
    -- gracefully by keeping the hint visible.
    local x, z = SoilMapCellDialog._getPlayerWorldXZ()
    if x ~= nil then
        self:onClickMap(x, z)
    end
end

-- Returns the current player/vehicle world X, Z position (or nil, nil on failure).
function SoilMapCellDialog._getPlayerWorldXZ()
    if g_localPlayer then
        if type(g_localPlayer.getPosition) == "function" then
            local ok, x, y, z = pcall(g_localPlayer.getPosition, g_localPlayer)
            if ok and x then return x, z end
        end
        if g_localPlayer.rootNode then
            local ok, x, y, z = pcall(getWorldTranslation, g_localPlayer.rootNode)
            if ok and x then return x, z end
        end
        if type(g_localPlayer.getIsInVehicle) == "function" and g_localPlayer:getIsInVehicle() then
            local v = type(g_localPlayer.getCurrentVehicle) == "function" and g_localPlayer:getCurrentVehicle()
            if v and v.rootNode then
                local ok, x, y, z = pcall(getWorldTranslation, v.rootNode)
                if ok and x then return x, z end
            end
        end
    end
    if g_currentMission then
        if g_currentMission.player and g_currentMission.player.rootNode then
            local ok, x, y, z = pcall(getWorldTranslation, g_currentMission.player.rootNode)
            if ok and x then return x, z end
        end
        if g_currentMission.controlledVehicle and g_currentMission.controlledVehicle.rootNode then
            local ok, x, y, z = pcall(getWorldTranslation, g_currentMission.controlledVehicle.rootNode)
            if ok and x then return x, z end
        end
    end
    return nil, nil
end

function SoilMapCellDialog:onClose()
    SoilMapCellDialog:superClass().onClose(self)
    if self.overlay then
        self.overlay.isMapOpen = false
    end
end

function SoilMapCellDialog:onCancel()
    self:close()
end

local function getCellLayerValue(cell, layerIdx)
    if layerIdx == 1 then return cell.n or cell.N
    elseif layerIdx == 2 then return cell.p or cell.P
    elseif layerIdx == 3 then return cell.k or cell.K
    elseif layerIdx == 4 then return cell.ph or cell.pH
    elseif layerIdx == 5 then return cell.om or cell.OM
    elseif layerIdx == 6 then
        local n = cell.n or cell.N or 0
        local p = cell.p or cell.P or 0
        local k = cell.k or cell.K or 0
        return 100 - (n + p + k) / 3
    elseif layerIdx == 7 then return cell.weedPressure
    elseif layerIdx == 8 then return cell.pestPressure
    elseif layerIdx == 9 then return cell.diseasePressure
    elseif layerIdx == 10 then return cell.compaction
    end
    return nil
end

function SoilMapCellDialog:onClickMap(worldX, worldZ)
    local farmlandId = g_farmlandManager:getFarmlandAtWorldPosition(worldX, worldZ)
    local zone = SoilConstants.ZONE
    local cellX = math.floor(worldX / zone.CELL_SIZE)
    local cellZ = math.floor(worldZ / zone.CELL_SIZE)
    local cellKey = tostring(cellX * 10000 + cellZ)
    
    local fieldEntry = self.soilSystem.fieldData and self.soilSystem.fieldData[farmlandId]
    local zoneData = fieldEntry and fieldEntry.zoneData and fieldEntry.zoneData[cellKey]
    
    if zoneData then
        if self.detailsGroup then self.detailsGroup:setVisible(true) end
        if self.hintText then self.hintText:setVisible(false) end
        
        if self.valFieldId then self.valFieldId:setText(farmlandId > 0 and tostring(farmlandId) or "--") end
        if self.valCoords then self.valCoords:setText(string.format("[%d, %d]", cellX, cellZ)) end
        
        if self.valN then self.valN:setText(string.format("%.1f kg/ha", zoneData.n or zoneData.N or 0)) end
        if self.valP then self.valP:setText(string.format("%.1f kg/ha", zoneData.p or zoneData.P or 0)) end
        if self.valK then self.valK:setText(string.format("%.1f kg/ha", zoneData.k or zoneData.K or 0)) end
        if self.valPH then self.valPH:setText(string.format("%.2f", zoneData.ph or zoneData.pH or 7.0)) end
        if self.valOM then self.valOM:setText(string.format("%.2f%%", zoneData.om or zoneData.OM or 2.0)) end
        
        if self.valWeed then self.valWeed:setText(string.format("%d%%", zoneData.weedPressure or 0)) end
        if self.valPest then self.valPest:setText(string.format("%d%%", zoneData.pestPressure or 0)) end
        if self.valDisease then self.valDisease:setText(string.format("%d%%", zoneData.diseasePressure or 0)) end
        if self.valCompaction then self.valCompaction:setText(string.format("%d%%", zoneData.compaction or 0)) end
    else
        local info = self.soilSystem:getFieldInfo(farmlandId)
        if info then
            if self.detailsGroup then self.detailsGroup:setVisible(true) end
            if self.hintText then self.hintText:setVisible(false) end
            if self.valFieldId then self.valFieldId:setText(tostring(farmlandId)) end
            if self.valCoords then self.valCoords:setText(string.format("[%d, %d] (Avg)", cellX, cellZ)) end
            
            if self.valN then self.valN:setText(string.format("%.1f kg/ha", info.n or info.nitrogen and info.nitrogen.value or 0)) end
            if self.valP then self.valP:setText(string.format("%.1f kg/ha", info.p or info.phosphorus and info.phosphorus.value or 0)) end
            if self.valK then self.valK:setText(string.format("%.1f kg/ha", info.k or info.potassium and info.potassium.value or 0)) end
            if self.valPH then self.valPH:setText(string.format("%.2f", info.ph or info.pH or 7.0)) end
            if self.valOM then self.valOM:setText(string.format("%.2f%%", info.om or info.organicMatter or 2.0)) end
            if self.valWeed then self.valWeed:setText(string.format("%d%%", info.weedPressure or 0)) end
            if self.valPest then self.valPest:setText(string.format("%d%%", info.pestPressure or 0)) end
            if self.valDisease then self.valDisease:setText(string.format("%d%%", info.diseasePressure or 0)) end
            if self.valCompaction then self.valCompaction:setText(string.format("%d%%", info.compaction or 0)) end
        else
            if self.detailsGroup then self.detailsGroup:setVisible(false) end
            if self.hintText then
                self.hintText:setVisible(true)
                self.hintText:setText(tr("sf_cell_no_data", "No soil data at this location"))
            end
        end
    end
end

function SoilMapCellDialog:onDrawPostIngameMap(mapElement)
    if not self.overlay then return end
    
    local layerIdx = self.overlay.settings.activeMapLayer or 0
    if layerIdx <= 0 then return end
    
    local zone = SoilConstants.ZONE
    -- Use a fixed size for dots on the dialog map
    local sizeX = 0.003
    local sizeY = 0.004
    
    local worldSizeX = mapElement.worldSizeX or (g_currentMission and g_currentMission.terrainSize) or 2048
    local worldSizeZ = mapElement.worldSizeZ or (g_currentMission and g_currentMission.terrainSize) or 2048
    
    if self.soilSystem and self.soilSystem.fieldData then
        for farmlandId, fieldEntry in pairs(self.soilSystem.fieldData) do
            if fieldEntry.zoneData then
                for cellKey, cell in pairs(fieldEntry.zoneData) do
                    local keyNum = tonumber(cellKey)
                    if keyNum then
                        local cx = math.floor(keyNum / 10000)
                        local cz = keyNum % 10000
                        local worldX = cx * zone.CELL_SIZE + zone.CELL_SIZE/2
                        local worldZ = cz * zone.CELL_SIZE + zone.CELL_SIZE/2
                        
                        local objectX = (worldX + (mapElement.worldCenterOffsetX or 0)) / worldSizeX
                        local objectZ = (worldZ + (mapElement.worldCenterOffsetZ or 0)) / worldSizeZ
                        
                        objectX = objectX * (mapElement.mapExtensionScaleFactor or 1) + (mapElement.mapExtensionOffsetX or 0)
                        objectZ = objectZ * (mapElement.mapExtensionScaleFactor or 1) + (mapElement.mapExtensionOffsetZ or 0)
                        
                        local ok, screenX, screenY = pcall(mapElement.layout.getMapObjectPosition, mapElement.layout, objectX, objectZ, 0, 0)
                        if ok and screenX then
                            local val = getCellLayerValue(cell, layerIdx)
                            if val then
                                local r, g, b = self.overlay:valueToLayerColor(layerIdx, val)
                                -- Draw using standard engine drawRect
                                drawRect(screenX - sizeX/2, screenY - sizeY/2, sizeX, sizeY, r, g, b, 0.7)
                            end
                        end
                    end
                end
            end
        end
    end
end
