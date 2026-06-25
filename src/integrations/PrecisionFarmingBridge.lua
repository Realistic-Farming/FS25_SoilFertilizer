-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Precision Farming Bridge
-- =========================================================
-- Safe cross-mod wrapper around Precision Farming.
--
-- PF's Lua source is compiled/obfuscated. This bridge detects PF via the
-- engine's own active-mod signals (g_modIsLoaded / missionDynamicInfo.mods)
-- and wraps every API call in pcall() so any PF update silently falls back to
-- SF standalone mode rather than crashing.
--
-- OPERATING MODES
--   Standalone (PF absent or probe failed):
--     isActive = false — SF runs exactly as before, full N/P/K/pH/OM
--   PF Mode (PF active):
--     isActive = true — SF excludes N from yield-penalty averaging
--     (PF's ExtendedCombine already applies an N-based penalty)
--     HookManager relays SF fill types to PF's nitrogen map via
--     a LIQUIDFERTILIZER volume swap (Phase 3 relay).
--
-- Use SoilPFDump console command for live API diagnostics.
-- =========================================================
-- Author: TisonK
-- =========================================================

---@class PrecisionFarmingBridge
PrecisionFarmingBridge = {}
local PrecisionFarmingBridge_mt = { __index = PrecisionFarmingBridge }

-- PF nitrogen map range (from PrecisionFarming.xml: 45 states, 0-220 kg/ha)
PrecisionFarmingBridge.PF_N_MAX_KG_HA = 220
-- PF pH map range (from PrecisionFarming.xml: 32 states, 4.5-8.25)
PrecisionFarmingBridge.PF_PH_MIN = 4.5
PrecisionFarmingBridge.PF_PH_MAX = 8.25
-- PF's mod directory name. Confirmed against ThundR's PF Configurator
-- (THCore.lua: getActiveMod("FS25_precisionFarming")) and the base-game DLC.
-- Both g_modIsLoaded and missionDynamicInfo.mods key on this exact name.
PrecisionFarmingBridge.PF_MOD_NAME = "FS25_precisionFarming"

--- Create a new (uninitialised) bridge instance.
---@return PrecisionFarmingBridge
function PrecisionFarmingBridge:new()
    local o = setmetatable({}, PrecisionFarmingBridge_mt)
    o.isActive    = false
    o.detectedVia = nil     -- which signal proved PF active ("g_modIsLoaded" / "missionDynamicInfo.mods")
    o.apiVerified = false
    o.thpfActive  = false   -- true when FS25_0_THPFConfigurator is also loaded
    o.nitrogenMap = nil
    o.phMap       = nil
    o.soilMap     = nil
    o.yieldMap    = nil     -- reserved: PF does not yet expose yield map via a shared C++ object
    return o
end

--- Detect whether Precision Farming is ACTIVE in the current savegame.
---
--- Root-cause fix for the long-standing "false PF detected" frustration:
--- the old check used g_modManager:getModByName(), which only confirms a mod is
--- PRESENT in the mods folder (it is a registry/metadata lookup — see how the
--- base game's StoreManager uses it purely for .title/.isDLC). It returns a
--- descriptor even for a mod the player did NOT enable for this savegame, so SF
--- would disable itself for anyone who merely had the PF DLC installed.
---
--- We now use the same signals the BASE GAME and other nutrient mods use, both of
--- which mean "loaded into THIS running save" (so installed-but-disabled no longer
--- trips detection):
---   Tier 1: g_modIsLoaded[name] — engine table, true only for loaded mods
---           (used by TypeManager, StoreManager, VehicleCamera, and our own
---            FS25_SeasonalCropStress for FS25_MoistureSystem).
---   Tier 2: missionDynamicInfo.mods — the active-mods list for this session
---           (the exact channel ThundR's PF Configurator reads to find PF).
--- getModByName is kept ONLY for diagnostics (SoilPFDump), never as the trigger.
--- Must be called after the mission is ready (deferred init phase).
---@return boolean isActive
function PrecisionFarmingBridge:initialize()
    local PF_MOD_NAME = PrecisionFarmingBridge.PF_MOD_NAME
    self.isActive    = false
    self.detectedVia = nil

    -- Tier 1 (authoritative): engine-maintained "is this mod loaded right now" table.
    pcall(function()
        if g_modIsLoaded ~= nil and g_modIsLoaded[PF_MOD_NAME] then
            self.isActive    = true
            self.detectedVia = "g_modIsLoaded"
        end
    end)

    -- Tier 2 (fallback / cross-check): the active-mods list for this session.
    -- Covers the rare case where g_modIsLoaded is not yet populated at our init
    -- time. Each entry's .modName is the mod directory name.
    if not self.isActive then
        pcall(function()
            local dynInfo = (g_currentMission and g_currentMission.missionDynamicInfo)
                         or (g_mpLoadingScreen and g_mpLoadingScreen.missionDynamicInfo)
            local mods = dynInfo and dynInfo.mods
            if mods then
                for _, modInfo in ipairs(mods) do
                    if modInfo.modName == PF_MOD_NAME then
                        self.isActive    = true
                        self.detectedVia = "missionDynamicInfo.mods"
                        break
                    end
                end
            end
        end)
    end

    if not self.isActive then
        SoilLogger.info("[PFBridge] Precision Farming not active in this savegame — standalone mode")
        return false
    end

    SoilLogger.info("[PFBridge] Precision Farming active (detected via %s) — SF defers N/pH to PF",
        tostring(self.detectedVia))

    -- Map API is not cross-mod accessible (PF uses its own env). isActive gates
    -- the simulation; canReadMaps stays false unless a future PF version exposes
    -- maps on g_currentMission.
    self.apiVerified = false  -- no map API access in this version
    self.canReadMaps = false

    -- Try to find maps via g_currentMission (in case PF registered them there)
    local mission = g_currentMission
    if mission then
        self.nitrogenMap = mission.nitrogenMap or mission.pfNitrogenMap
        self.phMap       = mission.phMap       or mission.pfPhMap
        self.soilMap     = mission.soilMap     or mission.pfSoilMap
        if self.nitrogenMap or self.phMap then
            local ok = pcall(function()
                if self.nitrogenMap then self.nitrogenMap:getValueAtWorldPos(0,0) end
                if self.phMap       then self.phMap:getValueAtWorldPos(0,0) end
            end)
            if ok then
                self.apiVerified = true
                self.canReadMaps = true
                SoilLogger.info("[PFBridge] Map API found on g_currentMission — read enabled")
            end
        end
    end

    -- Detect [TH] Precision Farming Configurator (FS25_0_THPFConfigurator).
    -- When present, it reads our <thPFConfig> block from modDesc.xml and injects
    -- our fill types into PF's nitrogen/pH maps directly — no relay needed.
    -- Same "loaded in this save" rule as PF itself: g_modIsLoaded first, with the
    -- active-mods list as a fallback (never getModByName, which sees installed-only).
    pcall(function()
        if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_0_THPFConfigurator"] then
            self.thpfActive = true
            return
        end
        local dynInfo = (g_currentMission and g_currentMission.missionDynamicInfo)
                     or (g_mpLoadingScreen and g_mpLoadingScreen.missionDynamicInfo)
        local mods = dynInfo and dynInfo.mods
        if mods then
            for _, modInfo in ipairs(mods) do
                if modInfo.modName == "FS25_0_THPFConfigurator" then
                    self.thpfActive = true
                    break
                end
            end
        end
    end)

    if self.thpfActive then
        SoilLogger.info("[PFBridge] Mode: PF + THPF Configurator — fill type integration via modDesc.xml declarations")
    elseif self.canReadMaps then
        SoilLogger.info("[PFBridge] Mode: PF standalone (map read enabled) — relay active for custom fill types")
    else
        SoilLogger.info("[PFBridge] Mode: PF standalone (detection only) — relay active for custom fill types")
    end

    -- PHASE 5 NOTE: Write-back to PF's nitrogenMap/phMap is not currently possible.
    -- FS25 mods run in isolated Lua environments; there is no cross-mod write API
    -- on any shared C++ object. SF changes to N (rain leaching, seasonal effects,
    -- fallow recovery) cannot propagate to PF's spatial maps in this architecture.
    -- If a future PF version exposes a write API on g_currentMission, implement
    -- write-back here: call setValueAtWorldPos(x, z, value) inside a pcall() guard,
    -- converting SF's 0-100 scale back to kg/ha via (value / 100) * PF_N_MAX_KG_HA.
    self.canWriteMaps = false

    return true
end

-- =========================================================
-- READ API (all calls guarded with pcall)
-- =========================================================

--- Get nitrogen at world position.
---@param x number world X
---@param z number world Z
---@return number|nil kg/ha (0-220), or nil on error/inactive
function PrecisionFarmingBridge:getNitrogenAt(x, z)
    if not self.isActive or not self.nitrogenMap then return nil end
    local ok, val = pcall(function() return self.nitrogenMap:getValueAtWorldPos(x, z) end)
    return ok and val or nil
end

--- Get pH at world position.
---@param x number world X
---@param z number world Z
---@return number|nil pH (4.5-8.25), or nil on error/inactive
function PrecisionFarmingBridge:getPhAt(x, z)
    if not self.isActive or not self.phMap then return nil end
    local ok, val = pcall(function() return self.phMap:getValueAtWorldPos(x, z) end)
    return ok and val or nil
end

--- Get soil type at world position.
---@param x number world X
---@param z number world Z
---@return number|nil soil type 1-4, or nil on error/inactive
function PrecisionFarmingBridge:getSoilTypeAt(x, z)
    if not self.isActive or not self.soilMap then return nil end
    local ok, val = pcall(function() return self.soilMap:getValueAtWorldPos(x, z) end)
    return ok and val or nil
end

--- Sample field average nitrogen by probing a 3x3 grid across field bounds.
--- Returns the mean of all successful samples, or nil if no samples succeed.
---@param field table FS25 field object (has .worldX, .worldZ, .fieldDimensions or similar)
---@return number|nil average kg/ha
function PrecisionFarmingBridge:getFieldNitrogenAvg(field)
    if not self.isActive or not self.nitrogenMap then return nil end
    if not field then return nil end
    return self:_sampleFieldGrid(field, function(x, z)
        local ok, v = pcall(function() return self.nitrogenMap:getValueAtWorldPos(x, z) end)
        return ok and v or nil
    end)
end

--- Sample field average pH by probing a 3x3 grid across field bounds.
---@param field table FS25 field object
---@return number|nil average pH (4.5-8.25)
function PrecisionFarmingBridge:getFieldPhAvg(field)
    if not self.isActive or not self.phMap then return nil end
    if not field then return nil end
    return self:_sampleFieldGrid(field, function(x, z)
        local ok, v = pcall(function() return self.phMap:getValueAtWorldPos(x, z) end)
        return ok and v or nil
    end)
end

--- Internal: sample a 3x3 grid of world positions across a field and average the results.
--- Uses field.posX / field.posZ if available, falls back to (0, 0) centre.
---@param field table
---@param sampler function(x, z) -> number|nil
---@return number|nil average of non-nil samples
function PrecisionFarmingBridge:_sampleFieldGrid(field, sampler)
    local cx = field.posX or field.worldX or 0
    local cz = field.posZ or field.worldZ or 0
    if cx == 0 and cz == 0 then
        SoilLogger.debug("[PFBridge] _sampleFieldGrid: no position found on field object — sampling around world origin")
    end
    -- Use a fixed half-size of 30 m; fine for diagnostic/calibration purposes
    local hw = 30
    local sum, count = 0, 0
    for ox = -1, 1 do
        for oz = -1, 1 do
            local v = sampler(cx + ox * hw, cz + oz * hw)
            if v ~= nil then
                sum   = sum + v
                count = count + 1
            end
        end
    end
    return count > 0 and (sum / count) or nil
end

-- =========================================================
-- PF FILL TYPE INJECTION
-- =========================================================

-- N content (kg N per litre) for SF's custom nitrogen fill types.
-- Used by the PF relay mechanism: when one of these is sprayed, our hook swaps
-- workAreaParameters to an equivalent LIQUIDFERTILIZER volume before PF's hook fires,
-- so PF paints its nitrogen map with the correct N amount.
-- Calibrated to real-world chemistry relative to PF's baseline:
--   FERTILIZER       = 0.27 kg N/L
--   LIQUIDFERTILIZER = 0.39 kg N/L  ← relay reference
PrecisionFarmingBridge.SF_FILL_TYPE_N_AMOUNTS = {
    UAN32         = 0.42,   -- UAN 32% N solution, density ~1.32 kg/L
    UAN28         = 0.37,   -- UAN 28% N solution, density ~1.28 kg/L
    ANHYDROUS     = 0.50,   -- Anhydrous ammonia 82% N (volume basis)
    AMS           = 0.21,   -- Ammonium sulfate 21% N
    UREA          = 0.46,   -- Urea 46% N
    AN            = 0.34,   -- Ammonium nitrate 34.5% N
    LIQUID_UREA   = 0.32,   -- Liquid urea solution ~29% N
    LIQUID_AMS    = 0.24,   -- AMS solution ~21% N
    LIQUID_DAP    = 0.18,   -- DAP solution 18-46-0
    LIQUID_MAP    = 0.11,   -- MAP solution 11-52-0
    -- LIQUID_POTASH: 0% N — not relayed
}

-- PF's LIQUIDFERTILIZER N content (from PrecisionFarming.xml <nAmount>) used as relay baseline.
PrecisionFarmingBridge.PF_LF_N_KG_PER_L = 0.39

--- Register SF's custom fill types in PF's recognition set (fertilizerFillTypes).
--- This makes PF's UI show the type in its sprayer panel.
--- N map painting is handled by the relay in HookManager, not by PF's internal lookup.
---@param nitrogenMap table PF nitrogenMap object from extendedSprayer spec
function PrecisionFarmingBridge:injectCustomFillTypes(nitrogenMap)
    if not nitrogenMap or not nitrogenMap.fertilizerFillTypes then
        SoilLogger.warning("[PFBridge] injectCustomFillTypes: fertilizerFillTypes not found — skipping")
        self.fillTypesInjected = true
        return
    end

    local fillTypes = nitrogenMap.fertilizerFillTypes
    local ok, errMsg = pcall(function()
        local injected = 0
        for fillTypeName in pairs(self.SF_FILL_TYPE_N_AMOUNTS) do
            if g_fillTypeManager then
                local ft = g_fillTypeManager:getFillTypeByName(fillTypeName)
                if ft and ft.index then
                    fillTypes[ft.index] = ft.index
                    injected = injected + 1
                end
            end
        end
        SoilLogger.info("[PFBridge] Registered %d SF fill types in PF recognition set", injected)
    end)

    if not ok then
        SoilLogger.warning("[PFBridge] injectCustomFillTypes: pcall failed — %s", tostring(errMsg))
    end
    self.fillTypesInjected = true
end

-- =========================================================
-- UNIT CONVERSION HELPERS
-- =========================================================

--- Convert PF nitrogen (kg/ha) to SF internal scale (0-100).
--- PF optimal for most crops is ~110-170 kg/ha; SF optimal is 55.
--- We map 220 kg/ha → 100, so 110 kg/ha → 50 (SF "fair" threshold).
---@param kgHa number
---@return number 0-100
function PrecisionFarmingBridge:nitrogenToSFScale(kgHa)
    return math.min(100, math.max(0, (kgHa / self.PF_N_MAX_KG_HA) * 100))
end

--- Convert PF pH (4.5-8.25) to SF internal pH (5.0-7.5).
--- Clamps to SF range.
---@param pfPH number
---@return number SF pH (5.0-7.5)
function PrecisionFarmingBridge:pfPhToSF(pfPH)
    return math.min(7.5, math.max(5.0, pfPH))
end

-- =========================================================
-- DIAGNOSTICS
-- =========================================================

--- Dump Precision Farming detection state and API discovery to the game log.
--- Shows the authoritative "loaded in this save" signals (g_modIsLoaded /
--- missionDynamicInfo.mods) alongside the installed-only g_modManager view, so a
--- player can see at a glance whether PF is merely installed vs actually active.
--- Run via SoilPFDump console command.
function PrecisionFarmingBridge:dumpApi()
    local PF_MOD_NAME = PrecisionFarmingBridge.PF_MOD_NAME
    print("[SoilPFDump] ===== Precision Farming API discovery =====")
    print(string.format("[SoilPFDump] Bridge status: isActive=%s  detectedVia=%s  apiVerified=%s",
        tostring(self.isActive), tostring(self.detectedVia), tostring(self.apiVerified)))

    -- 0. AUTHORITATIVE detection — the two "loaded in THIS save" signals SF trusts.
    print("[SoilPFDump] ----- active-mod detection (authoritative) -----")
    local t1 = nil
    pcall(function() t1 = (g_modIsLoaded ~= nil) and g_modIsLoaded[PF_MOD_NAME] or nil end)
    print(string.format("[SoilPFDump]   Tier1 g_modIsLoaded['%s'] = %s", PF_MOD_NAME, tostring(t1)))
    local t2 = false
    pcall(function()
        local dynInfo = (g_currentMission and g_currentMission.missionDynamicInfo)
                     or (g_mpLoadingScreen and g_mpLoadingScreen.missionDynamicInfo)
        local mods = dynInfo and dynInfo.mods
        if mods then
            for _, modInfo in ipairs(mods) do
                if modInfo.modName == PF_MOD_NAME then t2 = true break end
            end
        end
    end)
    print(string.format("[SoilPFDump]   Tier2 missionDynamicInfo.mods contains '%s' = %s", PF_MOD_NAME, tostring(t2)))

    -- 1. g_modManager — INSTALLED check only (diagnostic). A non-nil result here
    --    while Tier1/Tier2 are false means PF is in the mods folder but NOT enabled
    --    for this savegame — the exact case the old detector wrongly treated as active.
    print("[SoilPFDump] ----- g_modManager check (installed only, NOT used to trigger) -----")
    if g_modManager then
        local ok, pfMod = pcall(function()
            return g_modManager:getModByName(PF_MOD_NAME)
        end)
        if ok and pfMod then
            print(string.format("[SoilPFDump]   INSTALLED: %s  name=%s  version=%s  isLoaded=%s",
                PF_MOD_NAME,
                tostring(pfMod.modName or pfMod.name or "?"),
                tostring(pfMod.version or "?"),
                tostring(pfMod.isLoaded or "?")))
        elseif ok then
            print(string.format("[SoilPFDump]   getModByName('%s') = nil (not installed)", PF_MOD_NAME))
        else
            print("[SoilPFDump]   getModByName error: " .. tostring(pfMod))
        end

        -- List all INSTALLED mod names matching precis/farm for reference
        local ok2, mods = pcall(function() return g_modManager.mods end)
        if ok2 and mods then
            print("[SoilPFDump]   Installed mods (precis/farm):")
            for _, m in ipairs(mods) do
                local n = m.modName or m.name or "?"
                if tostring(n):lower():find("precis") or tostring(n):lower():find("farm") then
                    print(string.format("[SoilPFDump]     %s  v%s", tostring(n), tostring(m.version or "?")))
                end
            end
        end
    else
        print("[SoilPFDump]   g_modManager is nil")
    end

    -- 2. Specialization registry check
    print("[SoilPFDump] ----- Specialization registry -----")
    if g_specializationManager then
        local pfSpecs = {"extendedSprayer","extendedCombine","extendedMower",
                         "extendedSowingMachine","soilSampler","cropSensor","weedSpotSpray"}
        for _, sname in ipairs(pfSpecs) do
            local ok, spec = pcall(function()
                return g_specializationManager:getSpecializationByName(sname)
            end)
            print(string.format("[SoilPFDump]   spec '%s' = %s", sname,
                (ok and spec ~= nil) and "FOUND" or "nil"))
        end
    else
        print("[SoilPFDump]   g_specializationManager is nil")
    end

    -- 3. g_currentMission — broad scan for any non-standard table/userdata fields
    print("[SoilPFDump] ----- g_currentMission broad scan -----")
    if g_currentMission then
        local mOk, mErr = pcall(function()
            -- Check specific PF candidate field names
            local candidates = {
                "precisionFarming","nitrogenMap","phMap","soilMap","yieldMap",
                "coverMap","seedRateMap","pfMod","pf","precision",
            }
            for _, cname in ipairs(candidates) do
                local v = g_currentMission[cname]
                if v ~= nil then
                    print(string.format("[SoilPFDump]   g_currentMission.%s = %s  FOUND", cname, type(v)))
                end
            end
        end)
        if not mOk then print("[SoilPFDump]   scan error: " .. tostring(mErr)) end
    else
        print("[SoilPFDump]   g_currentMission is nil")
    end

    -- 4. Bridge summary
    print("[SoilPFDump] ----- Bridge status -----")
    print(string.format("[SoilPFDump]   isActive=%s  canReadMaps=%s  apiVerified=%s",
        tostring(self.isActive), tostring(self.canReadMaps or false), tostring(self.apiVerified)))
    print("[SoilPFDump] ==========================================")
end
