-- =========================================================
-- FS25 Soil & Fertilizer - LIVESTOCK WARNING READER (RSF-F190)
-- =========================================================
-- The barn half of the dog's early warning gets what the crop half has always
-- had: one SoilFertilizer-owned function that answers a resolved question.
-- The crop branch asks soilSystem:getFieldInfo and tests info.activeDisease
-- for presence. The barn branch asks this reader and tests the return for
-- presence. Nothing above this file touches a provider field, a provider
-- method name or a disease name.
--
-- Contract (handoff v0.8, items 1 to 8):
--   isBarnActivelySick(placeable) -> true | nil
--     true  : at least one animal in the barn holds a disease record that is
--             active sickness (cured == false AND isCarrier == false, both real
--             booleans). Never a disease name, never a count.
--     nil   : everything else. Provider absent, diseases disabled, no records,
--             a healthy herd, a malformed record, a read that throws, a list
--             that cannot be walked. Nil means no warning, same as the crop half.
--
-- The provider's own animal:getHasAnyDisease() is a PRE-GATE, never the
-- verdict. Its value is that the provider evaluates its own disease manager and
-- its own enabled flag inside its own environment, so this mod never reaches
-- across the sandbox for g_diseaseManager. On the installed 1.2.6.0 that getter
-- is true for ANY attached record, cured animals and genetic carriers
-- included, so the per-record test below is the only thing between a true gate
-- and a false bark. On 1.3.2.1 the getter already refuses those rows; the
-- per-record test then costs nothing and changes no answer.
--
-- A malformed record (flags missing, nil or not booleans) does NOT count. This
-- is the opposite of DairyCore's RLBridge, which weights a herd score and
-- errs toward a penalty; the dog's own law is no false positives.
--
-- Containment: one bad animal never silences its siblings (per-animal pcall
-- here), and the dog wraps each barn separately so one bad barn never
-- silences the farm. Nothing is cached, no state is kept, no handle is
-- published on the mission. Read-only outside-mod bridge; no provider write.
-- =========================================================
-- Author: TisonK
-- =========================================================

LivestockWarningReader = LivestockWarningReader or {}

--- One disease record counts as active sickness only when both flags are
--- genuine booleans reading false. Anything else is not sickness for the dog.
---@param record any
---@return boolean
function LivestockWarningReader.isActiveRecord(record)
    if type(record) ~= "table" then return false end
    return record.cured == false and record.isCarrier == false
end

--- One animal is actively sick when the provider's own gate says true AND at
--- least one of its disease records counts. A carrier record on the animal
--- never silences a second, active record on the same animal.
---@param animal any
---@return boolean|nil  true when actively sick, nil otherwise
function LivestockWarningReader.isAnimalActivelySick(animal)
    if type(animal) ~= "table" or type(animal.getHasAnyDisease) ~= "function" then
        return nil
    end
    local okGate, gate = pcall(animal.getHasAnyDisease, animal)
    if not okGate or gate ~= true then return nil end

    local okWalk, sick = pcall(function()
        local records = animal.diseases
        if type(records) ~= "table" then return false end
        for _, record in ipairs(records) do
            if LivestockWarningReader.isActiveRecord(record) then return true end
        end
        return false
    end)
    if okWalk and sick == true then return true end
    return nil
end

--- One barn is actively sick when any animal in it is. Each animal is read
--- under its own protection so a throw on one cannot hide a sick sibling.
---@param placeable any  a placeable carrying spec_husbandryAnimals
---@return boolean|nil  true when actively sick, nil otherwise
function LivestockWarningReader.isBarnActivelySick(placeable)
    local okList, animals = pcall(function()
        local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
        local cs = spec ~= nil and spec.clusterSystem or nil
        if cs == nil or type(cs.getAnimals) ~= "function" then return nil end
        return cs:getAnimals()
    end)
    if not okList or type(animals) ~= "table" then return nil end

    for _, animal in ipairs(animals) do
        local okAnimal, sick = pcall(LivestockWarningReader.isAnimalActivelySick, animal)
        if okAnimal and sick == true then return true end
    end
    return nil
end
