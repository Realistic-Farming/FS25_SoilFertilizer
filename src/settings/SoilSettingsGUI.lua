-- =========================================================
-- FS25 Realistic Soil & Fertilizer (Settings GUI)
-- =========================================================
-- Author: TisonK (modified)
-- =========================================================
---@class SoilSettingsGUI

SoilSettingsGUI = {}
local SoilSettingsGUI_mt = Class(SoilSettingsGUI)

-- Route a setting change through the network layer so all MP clients are notified.
-- Falls back to direct mutation only when the network layer is not yet ready.
local function requestSettingChange(settingId, value)
    if SoilNetworkEvents_RequestSettingChange then
        SoilNetworkEvents_RequestSettingChange(settingId, value)
    else
        g_SoilFertilityManager.settings[settingId] = value
        g_SoilFertilityManager.settings:save()
    end
end

function SoilSettingsGUI.new()
    local self = setmetatable({}, SoilSettingsGUI_mt)
    return self
end

function SoilSettingsGUI:registerConsoleCommands()
    addConsoleCommand("SoilSetDifficulty", "Set difficulty (1=Simple, 2=Realistic, 3=Hardcore)", "consoleCommandSetDifficulty", self)
    addConsoleCommand("SoilEnable", "Enable Soil Mod", "consoleCommandSoilEnable", self)
    addConsoleCommand("SoilDisable", "Disable Soil Mod", "consoleCommandSoilDisable", self)
    addConsoleCommand("SoilSetFertility", "Enable/disable fertility system (true/false)", "consoleCommandSetFertility", self)
    addConsoleCommand("SoilSetNutrients", "Enable/disable nutrient cycles (true/false)", "consoleCommandSetNutrients", self)
    addConsoleCommand("SoilSetFertilizerCosts", "Enable/disable fertilizer costs (true/false)", "consoleCommandSetFertilizerCosts", self)
    addConsoleCommand("SoilSetNotifications", "Enable/disable notifications (true/false)", "consoleCommandSetNotifications", self)
    addConsoleCommand("SoilSetSeasonalEffects", "Enable/disable seasonal effects (true/false)", "consoleCommandSetSeasonalEffects", self)
    addConsoleCommand("SoilSetRainEffects", "Enable/disable rain effects (true/false)", "consoleCommandSetRainEffects", self)
    addConsoleCommand("SoilSetPlowingBonus", "Enable/disable plowing bonus (true/false)", "consoleCommandSetPlowingBonus", self)
    addConsoleCommand("SoilShowSettings", "Show current settings", "consoleCommandShowSettings", self)
    addConsoleCommand("SoilFieldInfo", "Show field soil information (fieldId)", "consoleCommandFieldInfo", self)
    addConsoleCommand("SoilFieldForecast", "Show yield forecast for field", "consoleCommandFieldForecast", self)
    addConsoleCommand("SoilListFields", "List all fields with soil data", "consoleCommandListFields", self)
    addConsoleCommand("SoilResetSettings", "Reset all settings to defaults", "consoleCommandResetSettings", self)
    addConsoleCommand("SoilSaveData", "Force save soil data", "consoleCommandSaveData", self)
    addConsoleCommand("SoilDebug", "Toggle debug mode", "consoleCommandDebug", self)
    addConsoleCommand("SoilDrainVehicle", "Drain custom fertilizer from current vehicle/implements (50% refund)", "consoleCommandDrainVehicle", self)
    addConsoleCommand("SoilPFDump", "Dump Precision Farming bridge API for integration diagnostics", "consoleCommandPFDump", self)
    addConsoleCommand("soilfertility", "Show all soil commands", "consoleCommandHelp", self)

    SoilLogger.info("Console commands registered")
end

function SoilSettingsGUI:consoleCommandHelp()
    print("=== Soil & Fertilizer Mod Console Commands ===")
    print("soilfertility - Show this help")
    print("SoilEnable/Disable - Toggle mod")
    print("SoilSetDifficulty 1|2|3 - Set difficulty")
    print("SoilSetFertility true|false - Toggle fertility system")
    print("SoilSetNutrients true|false - Toggle nutrient cycles")
    print("SoilSetFertilizerCosts true|false - Toggle fertilizer costs")
    print("SoilSetNotifications true|false - Toggle notifications")
    print("SoilSetSeasonalEffects true|false - Toggle seasonal effects")
    print("SoilSetRainEffects true|false - Toggle rain effects")
    print("SoilSetPlowingBonus true|false - Toggle plowing bonus")
    print("SoilShowSettings - Show current settings")
    print("SoilFieldInfo <fieldId> - Show soil info for field")
    print("SoilFieldForecast <fieldId> - Show yield forecast for field")
    print("SoilListFields - List all fields with soil data")
    print("SoilResetSettings - Reset to defaults")
    print("SoilSaveData - Force save soil data")
    print("SoilDebug - Toggle debug mode")
    print("SoilDrainVehicle - Drain custom fertilizer from vehicle/implements (50% refund)")
    print("SoilPFDump - Dump Precision Farming API for integration diagnostics")
    print("soilSetState <fieldId> <N> <P> <K> <pH> <OM> - Set state for a field")
    print("soilRecoverField [fieldId] - Recover field to default values")
    print("==============================================")
    return "Type 'soilfertility' for more info"
end

function SoilSettingsGUI:consoleCommandSetDifficulty(difficulty)
    local diff = tonumber(difficulty)
    if not diff or diff < 1 or diff > 3 then
        SoilLogger.warning("Invalid difficulty. Use 1 (Simple), 2 (Realistic), or 3 (Hardcore)")
        return "Invalid difficulty"
    end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        requestSettingChange("difficulty", diff)
        local diffNames = {[1]="Simple", [2]="Realistic", [3]="Hardcore"}
        return string.format("Difficulty set to: %s", diffNames[diff] or tostring(diff))
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSoilEnable()
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        requestSettingChange("enabled", true)
        if g_SoilFertilityManager.soilSystem then
            g_SoilFertilityManager.soilSystem:initialize()
        end
        return "Soil & Fertilizer Mod enabled"
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSoilDisable()
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        requestSettingChange("enabled", false)
        return "Soil & Fertilizer Mod disabled"
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetFertility(enabled)
    if enabled == nil then return "Usage: SoilSetFertility true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("fertilitySystem", newVal)
        return string.format("Fertility system %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetNutrients(enabled)
    if enabled == nil then return "Usage: SoilSetNutrients true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("nutrientCycles", newVal)
        return string.format("Nutrient cycles %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetFertilizerCosts(enabled)
    if enabled == nil then return "Usage: SoilSetFertilizerCosts true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("fertilizerCosts", newVal)
        return string.format("Fertilizer costs %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetNotifications(enabled)
    if enabled == nil then return "Usage: SoilSetNotifications true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("showNotifications", newVal)
        return string.format("Notifications %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetSeasonalEffects(enabled)
    if enabled == nil then return "Usage: SoilSetSeasonalEffects true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("seasonalEffects", newVal)
        return string.format("Seasonal effects %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetRainEffects(enabled)
    if enabled == nil then return "Usage: SoilSetRainEffects true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("rainEffects", newVal)
        return string.format("Rain effects %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSetPlowingBonus(enabled)
    if enabled == nil then return "Usage: SoilSetPlowingBonus true|false" end
    local enable = enabled:lower()
    if enable ~= "true" and enable ~= "false" then return "Invalid value. Use 'true' or 'false'" end
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = (enable == "true")
        requestSettingChange("plowingBonus", newVal)
        return string.format("Plowing bonus %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandDebug()
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local newVal = not g_SoilFertilityManager.settings.debugMode
        if not newVal then
            -- Flush buffered debug messages to Debug/debug.xml before turning off
            SoilLogger.flushDebugLog()
        end
        requestSettingChange("debugMode", newVal)
        return string.format("Debug mode %s", newVal and "enabled" or "disabled")
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandSaveData()
    if g_SoilFertilityManager then
        g_SoilFertilityManager:saveSoilData()
        SoilSettingsGUI.writeSoilExport(g_SoilFertilityManager.soilSystem)
        return "Soil data saved"
    end
    return "Error: Soil Mod not initialized"
end

--- Write a full snapshot of all field nutrient data to Debug/soil_export.xml.
function SoilSettingsGUI.writeSoilExport(soilSystem)
    if not soilSystem then return end
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if not base then return end
    local xml = XMLFile.create("sf_soilExport", base .. "/Debug/soil_export.xml", "soilExport")
    if not xml then return end
    local day = g_currentMission and g_currentMission.environment and g_currentMission.environment.currentDay or 0
    xml:setInt("soilExport#day", day)
    local idx = 0
    for fieldId, fd in pairs(soilSystem.fieldData or {}) do
        local key = string.format("soilExport.field(%d)", idx)
        xml:setInt  (key .. "#id",              fieldId)
        xml:setInt  (key .. "#nitrogen",         fd.nitrogen        or 0)
        xml:setInt  (key .. "#phosphorus",       fd.phosphorus      or 0)
        xml:setInt  (key .. "#potassium",        fd.potassium       or 0)
        xml:setFloat(key .. "#organicMatter",    fd.organicMatter   or 0)
        xml:setFloat(key .. "#pH",               fd.pH              or 7.0)
        xml:setString(key .. "#lastCrop",        fd.lastCrop        or "")
        xml:setInt  (key .. "#lastHarvest",      fd.lastHarvest     or 0)
        xml:setFloat(key .. "#fertilizerApplied",fd.fertilizerApplied or 0)
        xml:setInt  (key .. "#weedPressure",     fd.weedPressure    or 0)
        xml:setInt  (key .. "#pestPressure",     fd.pestPressure    or 0)
        xml:setInt  (key .. "#diseasePressure",  fd.diseasePressure or 0)
        xml:setInt  (key .. "#compaction",       fd.compaction      or 0)
        idx = idx + 1
    end
    xml:setInt("soilExport#fieldCount", idx)
    xml:save()
    xml:delete()
    SoilLogger.info("Soil export written: %s/Debug/soil_export.xml (%d fields)", base, idx)
end

function SoilSettingsGUI:consoleCommandShowSettings()
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        local s = g_SoilFertilityManager.settings
        local info = string.format(
            "=== Soil & Fertilizer Mod Settings ===\n" ..
            "Enabled: %s\nDebug Mode: %s\nFertility System: %s\nNutrient Cycles: %s\nFertilizer Costs: %s\nDifficulty: %s\nNotifications: %s\n" ..
            "Seasonal Effects: %s\nRain Effects: %s\nPlowing Bonus: %s\nFields Tracked: %d\n" ..
            "================================",
            tostring(s.enabled), tostring(s.debugMode), tostring(s.fertilitySystem),
            tostring(s.nutrientCycles), tostring(s.fertilizerCosts),
            s:getDifficultyName(), tostring(s.showNotifications),
            tostring(s.seasonalEffects), tostring(s.rainEffects), tostring(s.plowingBonus),
            g_SoilFertilityManager.soilSystem and g_SoilFertilityManager.soilSystem:getFieldCount() or 0
        )
        print(info)
        return info
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandFieldInfo(fieldId)
    local fid = tonumber(fieldId)
    if not fid then return "Usage: SoilFieldInfo <fieldId>" end
    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then
        local info = g_SoilFertilityManager.soilSystem:getFieldInfo(fid)
        if info then
            local fInfo = string.format(
                "=== Field %d Soil Information ===\n" ..
                "Nitrogen: %d (%s)\nPhosphorus: %d (%s)\nPotassium: %d (%s)\n" ..
                "Organic Matter: %.1f%%\npH: %.1f\n" ..
                "Last Crop: %s\nDays Since Harvest: %d\nFertilizer Applied: %.0fL\n" ..
                "Needs Fertilization: %s\n" ..
                "================================",
                fid,
                info.nitrogen.value, info.nitrogen.status,
                info.phosphorus.value, info.phosphorus.status,
                info.potassium.value, info.potassium.status,
                info.organicMatter,
                info.pH,
                info.lastCrop or "None",
                info.daysSinceHarvest,
                info.fertilizerApplied,
                info.needsFertilization and "Yes" or "No"
            )
            print(fInfo)
            SoilSettingsGUI.writeFieldDump(fid, info)
            return fInfo
        else
            return "Field not found or not initialized"
        end
    end
    return "Error: Soil Mod not initialized"
end

--- Write a single field's soil data to Debug/field_dump.xml.
function SoilSettingsGUI.writeFieldDump(fid, info)
    local base = SettingsManager and SettingsManager.getModProfileDir and SettingsManager.getModProfileDir()
    if not base then return end
    local xml = XMLFile.create("sf_fieldDump", base .. "/Debug/field_dump.xml", "fieldDump")
    if not xml then return end
    local day = g_currentMission and g_currentMission.environment and g_currentMission.environment.currentDay or 0
    xml:setInt("fieldDump#fieldId", fid)
    xml:setInt("fieldDump#day",     day)
    xml:setInt  ("fieldDump.nutrients#nitrogen",      info.nitrogen.value)
    xml:setString("fieldDump.nutrients#nitrogenStatus", info.nitrogen.status)
    xml:setInt  ("fieldDump.nutrients#phosphorus",    info.phosphorus.value)
    xml:setString("fieldDump.nutrients#phosphorusStatus", info.phosphorus.status)
    xml:setInt  ("fieldDump.nutrients#potassium",     info.potassium.value)
    xml:setString("fieldDump.nutrients#potassiumStatus", info.potassium.status)
    xml:setFloat("fieldDump.nutrients#organicMatter", info.organicMatter)
    xml:setFloat("fieldDump.nutrients#pH",            info.pH)
    xml:setString("fieldDump.status#lastCrop",        info.lastCrop or "")
    xml:setInt  ("fieldDump.status#daysSinceHarvest", info.daysSinceHarvest)
    xml:setFloat("fieldDump.status#fertilizerApplied",info.fertilizerApplied)
    xml:setBool ("fieldDump.status#needsFertilization", info.needsFertilization)
    xml:save()
    xml:delete()
    SoilLogger.info("Field dump written: %s/Debug/field_dump.xml", base)
end

function SoilSettingsGUI:consoleCommandFieldForecast(fieldId)
    local fid = tonumber(fieldId)
    if not fid then return "Usage: SoilFieldForecast <fieldId>" end
    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then
        local info = g_SoilFertilityManager.soilSystem:getFieldInfo(fid)
        if info then
            local ys       = SoilConstants.YIELD_SENSITIVITY
            local cropLower = info.lastCrop and string.lower(info.lastCrop) or nil

            -- Skip non-crop fields (grass, poplar, etc.)
            if cropLower and ys.NON_CROP_NAMES[cropLower] then
                return string.format("Field %d: crop '%s' has no yield forecast (non-row-crop)", fid, cropLower)
            end

            local tier     = ys.CROP_TIERS[cropLower] or ys.DEFAULT_TIER
            local tierData = ys.TIERS[tier]
            local thresh   = ys.OPTIMAL_THRESHOLD

            local nDef   = math.max(0, thresh - info.nitrogen.value)   / thresh
            local pDef   = math.max(0, thresh - info.phosphorus.value) / thresh
            local kDef   = math.max(0, thresh - info.potassium.value)  / thresh
            local avgDef = (nDef + pDef + kDef) / 3

            local penalty    = math.min(ys.MAX_PENALTY, avgDef * tierData.scale)
            local penaltyPct = math.floor(penalty * 100 + 0.5)
            -- Use getFieldUrgency so this score matches the Soil Report sort order
            local urgency    = math.floor(g_SoilFertilityManager.soilSystem:getFieldUrgency(fid) + 0.5)

            -- Recommendations
            local recs = {}
            if info.nitrogen.value   < thresh then table.insert(recs, "Apply Nitrogen")   end
            if info.phosphorus.value < thresh then table.insert(recs, "Apply Phosphorus") end
            if info.potassium.value  < thresh then table.insert(recs, "Apply Potassium")  end
            if info.pH < 6.0                  then table.insert(recs, "Apply Lime")       end
            if (info.weedPressure or 0) > 20  then table.insert(recs, "Apply Herbicide") end

            local recStr = #recs > 0 and table.concat(recs, ", ") or "None required"

            local fInfo = string.format(
                "=== Field %d Yield Forecast ===\n" ..
                "Crop Tier: %s (%s)\n" ..
                "Projected Yield Penalty: %d%%\n" ..
                "Overall Urgency Score: %d / 100\n" ..
                "Recommendations: %s\n" ..
                "================================",
                fid, tierData.label, cropLower or "None",
                penaltyPct, urgency, recStr
            )
            print(fInfo)
            return fInfo
        else
            return "Field not found or not initialized"
        end
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandListFields()
    if g_SoilFertilityManager and g_SoilFertilityManager.soilSystem then
        local sys    = g_SoilFertilityManager.soilSystem
        local lines  = {"=== Tracked Field Soil Data ==="}

        local sorted = {}
        for fieldId, _ in pairs(sys.fieldData) do
            table.insert(sorted, fieldId)
        end
        table.sort(sorted)

        if #sorted == 0 then
            table.insert(lines, "  No fields tracked yet.")
        else
            for _, fieldId in ipairs(sorted) do
                local f = sys.fieldData[fieldId]
                table.insert(lines, string.format(
                    "  Field %d:  N=%.1f  P=%.1f  K=%.1f  pH=%.1f  OM=%.2f%%",
                    fieldId, f.nitrogen, f.phosphorus, f.potassium, f.pH, f.organicMatter))
            end
        end

        table.insert(lines, string.format("Total: %d field(s)", #sorted))
        table.insert(lines, "================================")

        local result = table.concat(lines, "\n")
        print(result)
        return result
    end
    return "Error: Soil Mod not initialized"
end

function SoilSettingsGUI:consoleCommandResetSettings()
    if g_SoilFertilityManager and g_SoilFertilityManager.settings then
        g_SoilFertilityManager.settings:resetToDefaults()
        if g_SoilFertilityManager.soilSystem then
            g_SoilFertilityManager.soilSystem:initialize()
        end
        if g_SoilFertilityManager.settingsUI then
            g_SoilFertilityManager.settingsUI:refreshUI()
        end
        return "Soil Mod settings reset to default!"
    end
    return "Error: Soil Mod not initialized"
end

-- =========================================================
-- SoilDrainVehicle: empty custom fill types from the current
-- vehicle and all attached implements, with a 50% refund.
-- =========================================================
-- Liquid sprayers have no Dischargeable spec — vanilla FS25
-- offers no way to drain them. This command is the escape
-- hatch so players can switch products without wasting them.
function SoilSettingsGUI:consoleCommandDrainVehicle()
    if not g_currentMission then
        return "Error: No active mission"
    end

    local fm = g_fillTypeManager
    if not fm then return "Error: FillTypeManager not available" end

    -- Build a set of custom fill type indices this mod manages
    local customNames = {
        "UREA","AMS","MAP","DAP","POTASH","COMPOST","BIOSOLIDS",
        "CHICKEN_MANURE","PELLETIZED_MANURE","GYPSUM",
        "UAN32","UAN28","ANHYDROUS","STARTER","LIQUIDLIME",
        "INSECTICIDE","FUNGICIDE",
        "LIQUID_UREA","LIQUID_AMS","LIQUID_MAP","LIQUID_DAP","LIQUID_POTASH",
    }
    local customSet = {}
    local priceTable = {}
    -- Prices match FALLBACK_PRICES in installPurchaseRefillHook
    local fallbackPrices = {
        UREA=1.65, AMS=1.40, MAP=1.95, DAP=1.75, POTASH=1.80,
        COMPOST=0.60, BIOSOLIDS=0.55, CHICKEN_MANURE=0.50,
        PELLETIZED_MANURE=0.70, GYPSUM=0.80,
        UAN32=1.60, UAN28=1.50, ANHYDROUS=1.85, STARTER=1.70,
        LIQUIDLIME=1.20, INSECTICIDE=1.20, FUNGICIDE=1.30,
        LIQUID_UREA=1.70, LIQUID_AMS=1.45, LIQUID_MAP=2.00,
        LIQUID_DAP=1.80, LIQUID_POTASH=1.85,
    }
    for _, name in ipairs(customNames) do
        local idx = fm:getFillTypeIndexByName(name)
        if idx then
            customSet[idx] = name
            priceTable[idx] = fallbackPrices[name] or 1.0
        end
    end

    -- Find the controlled vehicle
    local vehicle = nil
    if g_localPlayer then
        local ok, inVeh = pcall(function() return g_localPlayer:getIsInVehicle() end)
        if ok and inVeh then
            local ok2, v = pcall(function() return g_localPlayer:getCurrentVehicle() end)
            if ok2 and v then vehicle = v end
        end
    end
    if not vehicle and g_currentMission.controlledVehicle then
        vehicle = g_currentMission.controlledVehicle
    end
    if not vehicle then
        return "Error: No vehicle currently controlled. Enter a vehicle first."
    end

    -- Collect root vehicle + all attached implements recursively
    local function collectVehicles(v, list)
        table.insert(list, v)
        local ok, impls = pcall(function() return v:getAttachedImplements() end)
        if ok and impls then
            for _, impl in ipairs(impls) do
                if impl.object then
                    collectVehicles(impl.object, list)
                end
            end
        end
    end
    local targets = {}
    collectVehicles(vehicle, targets)

    local totalRefund  = 0
    local totalDrained = 0
    local report       = {}

    local isServer = g_currentMission:getIsServer()
    local farmId   = vehicle:getOwnerFarmId() or 1

    for _, veh in ipairs(targets) do
        local spec = veh.spec_fillUnit
        if spec and spec.fillUnits then
            for fuIdx, fillUnit in ipairs(spec.fillUnits) do
                local currentType = fillUnit.fillType
                if currentType and customSet[currentType] then
                    local level = fillUnit.fillLevel or 0
                    if level > 0 then
                        local typeName = customSet[currentType]
                        local refund   = level * priceTable[currentType] * 0.5

                        if isServer then
                            pcall(function()
                                veh:addFillUnitFillLevel(farmId, fuIdx, -level, currentType, ToolType.UNDEFINED, nil)
                            end)
                            pcall(function()
                                g_currentMission:addMoney(refund, farmId, MoneyType.PURCHASE_FERTILIZER, true, true)
                            end)
                        end

                        totalDrained = totalDrained + level
                        totalRefund  = totalRefund  + refund
                        table.insert(report, string.format(
                            "  %s: %.0f L/kg drained → refund $%.0f", typeName, level, refund))
                        SoilLogger.info("SoilDrainVehicle: drained %.0f of %s, refund $%.0f",
                            level, typeName, refund)
                    end
                end
            end
        end
    end

    if #report == 0 then
        return "No custom fertilizer found in vehicle or attached implements."
    end

    if not isServer then
        table.insert(report, "(Note: not host — drain logged only; run on the host for full effect)")
    end

    local summary = string.format(
        "=== SoilDrainVehicle ===\n%s\nTotal: %.0f L/kg drained | Refund: $%.0f (50%%)\n========================",
        table.concat(report, "\n"), totalDrained, totalRefund
    )
    print(summary)
    return summary
end

function SoilSettingsGUI:consoleCommandSetState(fieldId, n, p, k, ph, om)
    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then
        return "Error: Soil Mod not initialized"
    end
    
    local sys = g_SoilFertilityManager.soilSystem
    local fid = tonumber(fieldId)
    
    if not fid then
        -- If no args, tell them to use the UI
        if g_SoilFertilityManager.settingsUI and g_SoilFertilityManager.settingsUI.panel then
            local panel = g_SoilFertilityManager.settingsUI.panel
            if not panel.isVisible then
                panel:open()
            end
            panel.page = "admin"
            return "Opened settings panel. Navigate to Admin -> Set Field State."
        end
        return "Usage: soilSetState <fieldId> <N> <P> <K> <pH> <OM>"
    end
    
    local N = tonumber(n)
    local P = tonumber(p)
    local K = tonumber(k)
    local pH = tonumber(ph)
    local OM = tonumber(om)
    
    if not N or not P or not K or not pH or not OM then
        return "Usage: soilSetState <fieldId> <N> <P> <K> <pH> <OM>"
    end
    
    local field = sys.fieldData[fid]
    if not field then
        sys:initializeField(fid, "wheat")
        field = sys.fieldData[fid]
        if not field then return "Error: Could not initialize field " .. tostring(fid) end
    end
    
    field.nitrogen = N
    field.phosphorus = P
    field.potassium = K
    field.pH = pH
    field.organicMatter = OM
    
    local isServer = g_currentMission and g_currentMission:getIsServer()
    if isServer then
        g_SoilFertilityManager:saveSoilData()
    end
    
    local msg = string.format("Field %d state set to N:%.0f, P:%.0f, K:%.0f, pH:%.1f, OM:%.1f", fid, N, P, K, pH, OM)
    if not isServer then msg = msg .. " (Client only! Run on server to persist)" end
    return msg
end

function SoilSettingsGUI:consoleCommandRecoverField(fieldId)
    if not g_SoilFertilityManager or not g_SoilFertilityManager.soilSystem then
        return "Error: Soil Mod not initialized"
    end
    
    local sys = g_SoilFertilityManager.soilSystem
    local fid = tonumber(fieldId)
    
    if not fid then
        -- try to get player field
        local function getPlayerFieldId()
            local x, z = nil, nil
            if g_localPlayer and g_localPlayer.rootNode then
                local ok, wx, _, wz = pcall(getWorldTranslation, g_localPlayer.rootNode)
                if ok and wx then x, z = wx, wz end
            end
            if x == nil and g_currentMission and g_currentMission.controlledVehicle then
                local v = g_currentMission.controlledVehicle
                if v and v.rootNode then
                    local ok, wx, _, wz = pcall(getWorldTranslation, v.rootNode)
                    if ok and wx then x, z = wx, wz end
                end
            end
            if x == nil then return nil end
            if g_fieldManager then
                local ok, f = pcall(function() return g_fieldManager:getFieldAtWorldPosition(x, z) end)
                if ok and f and f.farmland and f.farmland.id then return f.farmland.id end
            end
            if g_farmlandManager then
                local ok, farmland = pcall(function() return g_farmlandManager:getFarmlandAtWorldPosition(x, z) end)
                if ok and farmland and farmland.id and farmland.id > 0 then return farmland.id end
            end
            return nil
        end
        fid = getPlayerFieldId()
        if not fid then
            return "Usage: soilRecoverField <fieldId> (or stand on a field)"
        end
    end
    
    local defaults = SoilConstants and SoilConstants.FIELD_DEFAULTS or {
        nitrogen=50, phosphorus=50, potassium=50, pH=6.5, organicMatter=5.0
    }
    
    local field = sys.fieldData[fid]
    if not field then
        sys:initializeField(fid, "wheat")
        field = sys.fieldData[fid]
        if not field then return "Error: Could not initialize field " .. tostring(fid) end
    end
    
    field.nitrogen = defaults.nitrogen
    field.phosphorus = defaults.phosphorus
    field.potassium = defaults.potassium
    field.pH = defaults.pH
    field.organicMatter = defaults.organicMatter
    
    local isServer = g_currentMission and g_currentMission:getIsServer()
    if isServer then
        g_SoilFertilityManager:saveSoilData()
    end
    
    local msg = string.format("Field %d recovered to defaults.", fid)
    if not isServer then msg = msg .. " (Client only! Run on server to persist)" end
    return msg
end

function SoilSettingsGUI:consoleCommandPFDump()
    if g_SoilFertilityManager and g_SoilFertilityManager.pfBridge then
        g_SoilFertilityManager.pfBridge:dumpApi()
        return "PF dump written — check the console output above"
    end
    print("[SoilPFDump] SF bridge not yet initialised — load a savegame first, then run SoilPFDump")
    return "Bridge not ready — load savegame first"
end
