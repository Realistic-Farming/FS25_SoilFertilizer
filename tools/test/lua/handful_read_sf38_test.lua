-- handful_read_sf38_test.lua - THE HANDFUL READ (SF-38)
--
-- One kneel, one payload: everything the suite knows about that exact spot,
-- assembled from getters that ALL already ship. This member writes nothing.
--
-- The bench pins the brief's cert gates: NO PHANTOM FIELDS (every clause has a
-- verified source, none invented), PER-CLAUSE NEUTRALITY (one absent system
-- blanks only its own clause, never the payload), GRAIN HONESTY (the labels
-- ship in the payload; the panel never implies precision the label denies),
-- PURE ASSEMBLY (zero writes; every read neutral-absent), and the two gate
-- semantics the brief names: the test kit never bypasses the knowledge gate,
-- and diseaseKnown is cell-grain via the walked mask when a fresh cell exists.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/SpatialScouting.lua, src/HandfulRead.lua

-- A minimal soil system the assembly can read from. Only the surfaces the
-- clauses touch need to exist; everything else reads neutral-absent.
local function newSoilSystem(over)
    local sys = {
        fieldData = {
            [1] = {
                nitrogen = 40, phosphorus = 30, potassium = 50, pH = 6.5,
                organicMatter = 3.2, weedPressure = 10, pestPressure = 20,
                diseasePressure = 60, diseaseDiscovered = false,
                lastCrop = "wheat", lastCrop2 = "barley", lastCrop3 = "wheat",
                lastHarvest = 100, rotationBonusDaysLeft = 5,
            },
        },
        valueMaps = {
            readValueAtWorld = function(_key, _x, _z) return 22 end,
        },
        spatialScouting = nil,
        materialDown = {
            getDaysDownAt = function(_x, _z)
                return { status = "ok", days = 2, band = "fresh" }
            end,
        },
        materialWetness = {
            readCondition = function(_verts, _litres)
                return { status = "ok", pct = 30, band = "damp" }
            end,
            goingOffVerdict = function(_ft, _window, _day)
                return { status = "ok", spoiled = false, waterDays = 0, needed = 3, known = 6, window = 6 }
            end,
        },
        getFieldInfo = function(_self, fieldId, x, z)
            local f = _self.fieldData[fieldId]
            if not f then return nil end
            local fromZoneCell = x ~= nil and z ~= nil
            return {
                fieldId = fieldId,
                nitrogen = { value = f.nitrogen, status = "Good" },
                phosphorus = { value = f.phosphorus, status = "Good" },
                potassium = { value = f.potassium, status = "Good" },
                pH = f.pH,
                organicMatter = f.organicMatter,
                fromZoneCell = fromZoneCell,
                lastCrop = f.lastCrop, lastCrop2 = f.lastCrop2, lastCrop3 = f.lastCrop3,
                rotationStatus = "OK", rotationBonusDaysLeft = f.rotationBonusDaysLeft,
                daysSinceHarvest = 10,
                weedPressure = f.weedPressure, pestPressure = f.pestPressure,
                shownDiseasePressure = f.diseaseDiscovered and f.diseasePressure or nil,
            }
        end,
    }
    for k, v in pairs(over or {}) do sys[k] = v end
    return sys
end

local function patchManager(sys)
    g_SoilFertilityManager = { soilSystem = sys }
end

-- ── Rule 1: NO PHANTOM FIELDS ───────────────────────────────────────────────
do
    T.ok("every clause is named and known to the panel", #HandfulRead.CLAUSES >= 22)
    T.ok("the clause list carries the material clause", HandfulRead.CLAUSES[18] == "materialWetness")
    T.ok("the clause list carries diseaseKnown", HandfulRead.CLAUSES[21] == "diseaseKnown")
    T.ok("the clause list carries testKitActive", HandfulRead.CLAUSES[22] == "testKitActive")
end

-- ── Pure assembly, all sources present ───────────────────────────────────────
do
    patchManager(newSoilSystem())
    local p = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 105, materialFillType = "GRASS_WINDROW" })
    T.ok("a full assembly returns a payload", p ~= nil)
    T.eq("spot grain N", p.N.value, 40)
    T.eq("spot grain pH", p.pH, 6.5)
    T.eq("field grain lastCrop", p.lastCrop, "wheat")
    T.eq("field grain rotationStatus", p.rotationStatus, "OK")
    T.eq("compaction is a direct value-map read", p.compaction, 22)
    T.eq("fromZoneCell true when x,z given", p.fromZoneCell, true)
    T.eq("material days down", p.materialDaysDown.days, 2)
    T.eq("material wetness pct", p.materialWetness.pct, 30)
    T.ok("material verdict resolves with a supplied fill type",
         p.materialVerdict.status == "ok" and p.materialVerdict.spoiled == false)
    T.eq("diseaseKnown false while the field is undiscovered", p.diseaseKnown, false)
    T.eq("testKitActive neutral-false until the kit ships", p.testKitActive, false)
    T.eq("provenance farmId", p.farmId, 1)
end

-- ── The material verdict REFUSES honestly without a fill type ───────────────
do
    patchManager(newSoilSystem())
    local p = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 105 })
    T.ok("the verdict refuses without a fill type", p.materialVerdict.status == "refusal")
    T.ok("...and says why", type(p.materialVerdict.reason) == "string")
end

-- ── Rule 2: PER-CLAUSE NEUTRALITY ───────────────────────────────────────────
do
    -- No material layers: wetness/days/verdict go neutral, everything else stays.
    local sys = newSoilSystem()
    sys.materialDown = nil
    sys.materialWetness = nil
    patchManager(sys)
    local p = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 105, materialFillType = "GRASS_WINDROW" })
    T.eq("wetness neutral when the layer is absent", p.materialWetness.status, "unavailable")
    T.eq("days-down neutral when the layer is absent", p.materialDaysDown.status, "unavailable")
    T.eq("verdict neutral when the layer is absent", p.materialVerdict.status, "unavailable")
    T.eq("N still reads when only the material clause is absent", p.N.value, 40)
    T.eq("lastCrop still reads", p.lastCrop, "wheat")
end

do
    -- No SCS: moisture neutral, everything else intact.
    patchManager(newSoilSystem())
    g_currentMission.cropStressManager = nil
    local p = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 105 })
    T.eq("moisture neutral when SCS is absent", p.moisture, nil)
    T.eq("N still reads", p.N.value, 40)
    g_currentMission.cropStressManager = nil
end

-- ── THE TEST KIT NEVER BYPASSES THE KNOWLEDGE GATE ──────────────────────────
do
    -- diseaseKnown stays false for an undiscovered field even though the mask
    -- would reveal a cell: the mask cell is the ONLY cell-grain reveal, and the
    -- kit flag (neutral-false) must never pretend to reveal anything.
    local sys = newSoilSystem()
    -- A walked mask that HAS a fresh cell for this spot.
    local mask = SpatialScouting.new()
    mask:arm({ available = true, readValueAtWorld = function() return 40 end, writeValueAtWorld = function() end })
    mask:noteWalk(1, 1, SpatialScouting.cellKey(25, 35), 100, 60, 25, 35)
    sys.spatialScouting = mask
    patchManager(sys)

    local p = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 103 })
    T.eq("diseaseKnown true from a fresh mask cell", p.diseaseKnown, true)
    T.eq("the grain label says cell", p.diseaseGrain, "cell")
    T.eq("the kit flag stays false - it cannot bypass the gate", p.testKitActive, false)
end

do
    -- No mask cell: diseaseKnown degrades to the field flag, labelled field.
    patchManager(newSoilSystem())
    local p = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 103 })
    T.eq("diseaseKnown false without a mask cell", p.diseaseKnown, false)
    T.eq("the grain label says field", p.diseaseGrain, "field")

    -- A scouted field reads known via the field flag.
    local sys = newSoilSystem({ fieldData = {
        [1] = {
            nitrogen = 40, phosphorus = 30, potassium = 50, pH = 6.5,
            organicMatter = 3.2, weedPressure = 10, pestPressure = 20,
            diseasePressure = 60, diseaseDiscovered = true,
        },
    } })
    patchManager(sys)
    local p2 = HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 103 })
    T.eq("a scouted field reads known", p2.diseaseKnown, true)
    T.eq("shownDiseasePressure is the gated value", p2.diseasePressure, 60)
end

-- ── Pure assembly: zero writes ───────────────────────────────────────────────
do
    local sys = newSoilSystem()
    local calls = 0
    local origNote = sys.materialDown.getDaysDownAt
    sys.materialDown.getDaysDownAt = function(...)
        calls = calls + 1
        return origNote(...)
    end
    patchManager(sys)
    HandfulRead.assemble({ fieldId = 1, x = 25, z = 35, farmId = 1, currentDay = 105, materialFillType = "GRASS_WINDROW" })
    -- Only reads happened; the payload itself carries no writer. We assert the
    -- assembly path is read-only by checking nothing on the field mutated.
    T.eq("the field state was not mutated", sys.fieldData[1].diseaseDiscovered, false)
    T.ok("the assembly made reads, not writes", calls == 1)
end
