-- =========================================================
-- FS25 Realistic Soil & Fertilizer - Precision Farming Bridge
-- =========================================================
-- Safe read-only wrapper around g_precisionFarming.
--
-- PF's Lua source is compiled/obfuscated. This bridge uses the
-- standard Giants global convention and wraps every call in pcall()
-- so any API change in a PF update silently falls back to SF
-- standalone mode rather than crashing.
--
-- OPERATING MODES
--   Standalone (PF absent or probe failed):
--     isActive = false — SF runs exactly as before, full N/P/K/pH/OM
--   PF Mode (PF active + API verified):
--     isActive = true — caller gates N/pH behaviour on this flag
--
-- PHASE 1 SCOPE (detection + diagnostics only)
--   No simulation changes are made here.
--   Use SoilPFDump console command to inspect the live PF global.
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

--- Create a new (uninitialised) bridge instance.
---@return PrecisionFarmingBridge
function PrecisionFarmingBridge:new()
    local o = setmetatable({}, PrecisionFarmingBridge_mt)
    o.isActive    = false
    o.apiVerified = false
    o.nitrogenMap = nil
    o.phMap       = nil
    o.soilMap     = nil
    o.yieldMap    = nil
    return o
end

--- Detect PF via g_modManager (the only reliable cross-mod channel in FS25).
--- Each mod runs in its own Lua env, so getfenv(0) globals are NOT visible
--- cross-mod. g_modManager is a shared C++ object visible to all mods.
--- Must be called after mission is fully ready (deferred init phase).
---@return boolean isActive
function PrecisionFarmingBridge:initialize()
    -- Primary: check g_modManager for the PF mod entry
    local pfMod = nil
    if g_modManager then
        local ok, result = pcall(function()
            return g_modManager:getModByName("FS25_precisionFarming")
        end)
        if ok then pfMod = result end
    end

    if pfMod == nil then
        -- Secondary: check if PF's specializations were registered (vehicle spec check)
        -- g_specializationManager is shared and populated by all mods at load time
        local hasPFSpec = false
        if g_specializationManager then
            local ok, spec = pcall(function()
                return g_specializationManager:getSpecializationByName("extendedSprayer")
            end)
            hasPFSpec = ok and spec ~= nil
        end

        if not hasPFSpec then
            SoilLogger.info("[PFBridge] Precision Farming not detected — standalone mode")
            return false
        end

        SoilLogger.info("[PFBridge] PF detected via specialization registry (g_modManager miss)")
    else
        SoilLogger.info("[PFBridge] PF detected via g_modManager: %s v%s",
            tostring(pfMod.modName or pfMod.name or "?"),
            tostring(pfMod.version or "?"))
    end

    -- PF is confirmed active. Map API is not cross-mod accessible (PF uses its
    -- own env). We set isActive for simulation gating; canReadMaps stays false
    -- unless a future PF version exposes maps on g_currentMission.
    self.isActive    = true
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

    if not self.canReadMaps then
        SoilLogger.info("[PFBridge] PF Mode active (detection only). " ..
            "N/pH yield penalties suppressed. Map read API not available.")
    end
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
    -- Determine field centre and approximate half-extents
    local cx = field.posX or (field.worldX) or 0
    local cz = field.posZ or (field.worldZ) or 0
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

--- Dump the full g_precisionFarming global to the game log.
--- Also scans for the actual PF global name if the default is nil.
--- Run via SoilPFDump console command.
function PrecisionFarmingBridge:dumpApi()
    print("[SoilPFDump] ===== Precision Farming API discovery =====")
    print(string.format("[SoilPFDump] Bridge status: isActive=%s  apiVerified=%s",
        tostring(self.isActive), tostring(self.apiVerified)))

    -- 1. g_modManager detection (primary cross-mod channel)
    print("[SoilPFDump] ----- g_modManager check -----")
    if g_modManager then
        local ok, pfMod = pcall(function()
            return g_modManager:getModByName("FS25_precisionFarming")
        end)
        if ok and pfMod then
            print(string.format("[SoilPFDump]   FOUND: FS25_precisionFarming  name=%s  version=%s  isLoaded=%s",
                tostring(pfMod.modName or pfMod.name or "?"),
                tostring(pfMod.version or "?"),
                tostring(pfMod.isLoaded or "?")))
        elseif ok then
            print("[SoilPFDump]   getModByName('FS25_precisionFarming') = nil")
        else
            print("[SoilPFDump]   getModByName error: " .. tostring(pfMod))
        end

        -- List all loaded mod names for reference
        local ok2, mods = pcall(function() return g_modManager.mods end)
        if ok2 and mods then
            print("[SoilPFDump]   Loaded mods:")
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
