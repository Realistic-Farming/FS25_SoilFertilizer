-- Run from the SoilFertilizer repository root. Engine-independent contract.
local calls = {}
Utils = {prependedFunction = function(original, before)
    return function(...)
        before(...)
        return original(...)
    end
end}
MPLoadingScreen = {initializeLoading = function(screen)
    calls[#calls + 1] = {kind = "loading", screen = screen}
end}
FillTypeDesc = {
    addDistanceTexture = function(fillType, constr, index)
        calls[#calls + 1] = {kind = "original", fillType = fillType, index = index}
        return "original-result"
    end,
}

dofile("src/integrations/PnhDistanceTextureBridge.lua")
local bridge = PnhDistanceTextureBridge
assert(bridge.install())
assert(bridge.install()) -- a reload must not add a second wrapper
assert(bridge.installMissionRearm("FS25_SoilFertilizer"))
assert(bridge.installMissionRearm("FS25_SoilFertilizer"))

local pnh = {
    name = "SEPARATED_MANURE",
    layerTextures = {distanceFilename =
        "C:\\Game\\pdlc\\pumpsAndHosesPack\\data\\fillTypes\\separated_manureDistance_diffuse.png"},
}
local constr = {addTexture = function(_, index, path, channels)
    calls[#calls + 1] = {kind = "native", index = index, path = path, channels = channels}
end}

assert(FillTypeDesc.addDistanceTexture(pnh, constr, 60) == true)
assert(#calls == 1 and calls[1].kind == "native")
assert(calls[1].index == 60 and calls[1].channels == 3)
assert(calls[1].path == "data/fillPlanes/distance/manureDistance_diffuse.png")
assert(pnh.layerTextures.distanceFilename:find("separated_manureDistance_diffuse.png", 1, true))

local other = {name = "SEPARATED_MANURE", layerTextures = {distanceFilename =
    "C:/Game/otherMod/data/fillTypes/separated_manureDistance_diffuse.png"}}
assert(FillTypeDesc.addDistanceTexture(other, constr, 61) == "original-result")
assert(calls[2].kind == "original" and calls[2].fillType == other)

other.name = "OTHER"
other.layerTextures.distanceFilename = pnh.layerTextures.distanceFilename
assert(FillTypeDesc.addDistanceTexture(other, constr, 62) == "original-result")
assert(calls[3].kind == "original")

bridge.disable()
assert(FillTypeDesc.addDistanceTexture(pnh, constr, 63) == "original-result")
assert(calls[4].kind == "original" and calls[4].index == 63)
MPLoadingScreen.initializeLoading({missionDynamicInfo = {mods = {
    {modName = "FS25_SoilFertilizer"}, {modName = "pdlc_pumpsAndHosesPack"},
}}})
assert(bridge.active)
assert(FillTypeDesc.addDistanceTexture(pnh, constr, 64) == true)
assert(calls[6].kind == "native")
MPLoadingScreen.initializeLoading({missionDynamicInfo = {mods = {
    {modName = "pdlc_pumpsAndHosesPack"},
}}})
assert(not bridge.active)
assert(FillTypeDesc.addDistanceTexture(pnh, constr, 65) == "original-result")
assert(calls[8].kind == "original")
print("PNH distance texture bridge: mission rearm assertions passed")
