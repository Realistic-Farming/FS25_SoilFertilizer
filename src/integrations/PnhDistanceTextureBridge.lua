-- Pumps N' Hoses adds SEPARATED_MANURE as a ground-height type with its own
-- far-distance texture. With Soil's full material set on large maps, that one
-- extra native resource can cross the 255 distance-texture limit. Its diffuse,
-- normal, height and displacement materials remain the DLC's originals; only
-- the far-distance alias is shared with base-game manure.
PnhDistanceTextureBridge = PnhDistanceTextureBridge or {}

local bridge = PnhDistanceTextureBridge
local pnhSuffix = "pdlc/pumpsandhosespack/data/filltypes/separated_manuredistance_diffuse.png"
local manureAlias = "data/fillPlanes/distance/manureDistance_diffuse.png"

local function isPnhSeparatedManure(fillType)
    if fillType == nil or fillType.name ~= "SEPARATED_MANURE" then
        return false
    end
    local textures = fillType.layerTextures
    local filename = textures ~= nil and textures.distanceFilename or nil
    if type(filename) ~= "string" then
        return false
    end
    filename = filename:gsub("\\", "/"):lower()
    return filename:sub(-#pnhSuffix) == pnhSuffix
end

function bridge.install()
    bridge.active = true
    if bridge.installed then
        return true
    end
    if FillTypeDesc == nil or type(FillTypeDesc.addDistanceTexture) ~= "function" then
        return false
    end

    local previous = FillTypeDesc.addDistanceTexture
    FillTypeDesc.addDistanceTexture = function(fillType, distanceConstr, index, ...)
        if bridge.active and isPnhSeparatedManure(fillType) then
            -- Match FillTypeDesc:addDistanceTexture's native call and return value.
            -- Do not mutate the DLC descriptor, savegame or near material paths.
            distanceConstr:addTexture(index, manureAlias, 3)
            if not bridge.reported then
                bridge.reported = true
                print("[SoilFertilizer] PNH SEPARATED_MANURE far texture shares base manure distance alias")
            end
            return true
        end
        return previous(fillType, distanceConstr, index, ...)
    end
    bridge.installed = true
    return true
end

function bridge.disable()
    bridge.active = false
    bridge.reported = false
end

-- The mod's scripts are sourced only once per process, while the loading screen
-- runs for every selected save. Re-arm before its mod and map loading tasks run;
-- leave the wrapper dormant when Soil is absent from the next save's selection.
function bridge.installMissionRearm(soilModName)
    if bridge.missionRearmInstalled then
        return true
    end
    if MPLoadingScreen == nil or type(MPLoadingScreen.initializeLoading) ~= "function"
            or Utils == nil or type(Utils.prependedFunction) ~= "function" then
        return false
    end

    MPLoadingScreen.initializeLoading = Utils.prependedFunction(
        MPLoadingScreen.initializeLoading, function(screen)
            bridge.disable()
            local mods = screen.missionDynamicInfo and screen.missionDynamicInfo.mods or {}
            for _, item in ipairs(mods) do
                if item.modName == soilModName then
                    bridge.install()
                    break
                end
            end
        end)
    bridge.missionRearmInstalled = true
    return true
end
