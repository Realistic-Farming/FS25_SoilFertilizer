-- resistance_f68_relief_test.lua - F68 (the durability dial) and the F66 save relief.
--
-- F68: MAX_NATURAL looked like it made sulfur and copper more durable and did NOT. The
-- ceiling multiplies the build, divides the penalty and scales the bands, so it cancelled in
-- all three and both families saturated in exactly 20 passes. A constant that reads like a
-- dial and moves nothing is worse than a missing feature. The dial now lives on the build
-- rate, which is the only place the difference can land.
--
-- F66 relief: CD-9 shipped 2026-07-29 with a build that counted every boom section as a
-- full application. The meter landed 2026-08-01, but the damage is PERSISTED. Arissani
-- ruled the player should not stay burned by a choice the bug made for him.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/SpatialScouting.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/SoilFertilitySystem.lua

local R     = SoilConstants.RESISTANCE
local BUILD = R.BUILD_PER_APPLICATION
local RATES = SoilConstants.SPRAYER_RATE.BASE_RATES

local AREA_HA = 10
local function newField(extra)
  local f = {
    fieldArea = AREA_HA, _farmlandAreaConfirmed = true,
    sessionCoverageCells = { ["0:0"] = true },
    resistance = {}, diseasePressure = 50, nutrientBuffer = {},
  }
  for k, v in pairs(extra or {}) do f[k] = v end
  return f
end

local function newSys(field)
  local sys = setmetatable({
    fieldData = { [1] = field },
    settings  = { diseasePressure = true, showNotifications = false },
    reductions = {},
  }, { __index = SoilFertilitySystem })
  sys.trackSprayerCoverage = function() end
  sys.onFungicideAppliedIncremental = function(self, _, red) self.reductions[#self.reductions + 1] = red end
  return sys
end

local function sprayPasses(sys, chem, passes)
  local vol = AREA_HA * (RATES[chem] or RATES.FUNGICIDE).value
  for _ = 1, passes do
    for _ = 1, 100 do sys:onFungicideAppliedDirect(1, 1.0, vol / 100, chem) end
  end
end

-- ── F68: THE OLD ARITHMETIC, demonstrated so the defect is on record ─────────────────
--
-- With the ceiling as the only difference, both families take the SAME number of passes:
-- build 0.05*maxRes into a ceiling of maxRes is 20 passes whatever maxRes is.
do
  T.eq("F68: the ceiling alone gives synthetics 20 passes", math.floor(1 / BUILD), 20)
  T.eq("F68: ...and would have given naturals the same 20", math.floor(1 / BUILD), 20)
  T.ok("F68: so the dial cannot be the ceiling -- a real rate factor exists now",
       R.BUILD_RATE_NATURAL ~= R.BUILD_RATE_SYNTHETIC)
  T.eq("F68: synthetics build at full rate", R.BUILD_RATE_SYNTHETIC, 1.0)
  T.ok("F68: naturals build slower, not faster", R.BUILD_RATE_NATURAL < R.BUILD_RATE_SYNTHETIC)
end

-- The behaviour that constant is supposed to produce, measured through the real spray path.
do
  local syn, nat = newField(), newField()
  sprayPasses(newSys(syn), "PROPICONAZOLE", 20)
  sprayPasses(newSys(nat), "SULFUR", 20)

  T.near("F68: 20 passes saturate a synthetic", syn.resistance["3"], R.MAX_SYNTHETIC, 1e-6)
  T.ok("F68: 20 passes do NOT saturate a natural", nat.resistance["M2"] < R.MAX_NATURAL - 0.01)
  T.near("F68: a natural is at a quarter of its ceiling after 20 passes",
         nat.resistance["M2"] / R.MAX_NATURAL, R.BUILD_RATE_NATURAL, 1e-6)
end

do
  local nat = newField()
  local passes = math.floor(1 / (BUILD * R.BUILD_RATE_NATURAL))
  T.eq("F68: the natural ladder is 80 passes at the ruled 0.25", passes, 80)
  sprayPasses(newSys(nat), "SULFUR", passes)
  T.near("F68: and 80 passes DO saturate it", nat.resistance["M2"], R.MAX_NATURAL, 1e-6)
end

-- The dial must touch the BUILD only. The penalty and the bands still read off the ceiling,
-- so a natural at its ceiling is still fully finished -- it just takes four times as long.
do
  local field = newField({ resistance = { M2 = R.MAX_NATURAL } })
  local sys = newSys(field)
  sprayPasses(sys, "SULFUR", 1)
  local total = 0
  for _, r in ipairs(sys.reductions) do total = total + r end
  T.eq("F68: a saturated natural is still completely inert", total, 0)
end

-- THE FAIRNESS CASE that re-graded F68 to MEDIUM: an organic grower has exactly one legal
-- mix, so he cannot rotate. He must not burn out at a synthetic user's rate.
do
  local organic = newField({ organic = { state = SoilConstants.ORGANIC.STATE_CERTIFIED } })
  local conventional = newField()
  sprayPasses(newSys(organic), "SULFUR", 20)
  sprayPasses(newSys(conventional), "PROPICONAZOLE", 20)

  local orgRatio = organic.resistance["M2"] / R.MAX_NATURAL
  local convRatio = conventional.resistance["3"] / R.MAX_SYNTHETIC
  T.ok("F68: after equal use the organic grower is far less burned than the synthetic user",
       orgRatio < convRatio)
  T.near("F68: ...by exactly the ruled factor", orgRatio / convRatio, R.BUILD_RATE_NATURAL, 1e-6)
end

-- ── F66 SAVE RELIEF ──────────────────────────────────────────────────────────────────

local function loadSys()
  return setmetatable({ fieldData = {}, settings = {} }, { __index = SoilFertilitySystem })
end

-- An UNMARKED save predates the meter fix: its stored scores were put there by the defect.
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(false)
  local f = { resistance = { ["3"] = R.MAX_SYNTHETIC, ["M2"] = R.MAX_NATURAL } }
  sys:_finalizeLoadedField(1, f)
  T.ok("relief: an unmarked save has its resistance cleared", next(f.resistance) == nil)
  T.eq("relief: the clear is counted", sys._f66ReliefCleared, 1)
end

-- A MARKED save has already been relieved and must never be touched again, or a player
-- would lose legitimately earned resistance on every single load.
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(true)
  local f = { resistance = { ["3"] = 2.5 } }
  sys:_finalizeLoadedField(1, f)
  T.eq("relief: a marked save keeps its resistance", f.resistance["3"], 2.5)
  T.eq("relief: nothing was cleared", sys._f66ReliefCleared, 0)
end

-- Every field in an unmarked save is relieved, not just the first.
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(false)
  for i = 1, 5 do
    local f = { resistance = { ["3"] = R.MAX_SYNTHETIC } }
    sys:_finalizeLoadedField(i, f)
    T.ok("relief: field " .. i .. " cleared", next(f.resistance) == nil)
  end
  T.eq("relief: all five counted", sys._f66ReliefCleared, 5)
end

-- A field with no resistance at all is not counted as relieved (nothing to report).
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(false)
  sys:_finalizeLoadedField(1, { resistance = {} })
  sys:_finalizeLoadedField(2, {})
  T.eq("relief: empty fields are not counted", sys._f66ReliefCleared, 0)
end

-- Ending the pass disarms it, so a later field load in the same session cannot re-trigger.
do
  local sys = loadSys()
  sys._infoCalls = 0
  sys.info = function(s) s._infoCalls = s._infoCalls + 1 end
  sys:_beginF66ResistanceRelief(false)
  sys:_finalizeLoadedField(1, { resistance = { ["3"] = 5 } })
  sys:_endF66ResistanceRelief()
  T.ok("relief: the pass reports once", sys._infoCalls == 1)

  local f = { resistance = { ["3"] = 3.0 } }
  sys:_finalizeLoadedField(2, f)
  T.eq("relief: a field loaded after the pass ended is untouched", f.resistance["3"], 3.0)

  sys:_endF66ResistanceRelief()
  T.ok("relief: ending twice does not report twice", sys._infoCalls == 1)
end

-- A relieved save reports nothing when it had nothing to clear.
do
  local sys = loadSys()
  sys._infoCalls = 0
  sys.info = function(s) s._infoCalls = s._infoCalls + 1 end
  sys:_beginF66ResistanceRelief(false)
  sys:_endF66ResistanceRelief()
  T.eq("relief: a clean save logs nothing", sys._infoCalls, 0)
end

-- The marker travels on the StateLedger path too, or a ledger save would be re-relieved
-- on every load.
do
  local sys = setmetatable({ fieldData = {}, lastUpdateDay = 7 }, { __index = SoilFertilitySystem })
  local out = sys:getSoilStateTable()
  T.eq("relief: the ledger snapshot carries the marker", out.f66ResistanceReset, 1)
end

-- ── RSF-F237: THE RELIEF ALSO DROPS THE SCOUT BIT ────────────────────────────────────
--
-- A revealed field with no score for a mode bands WORKING (ResistanceBands.computeBand),
-- which is right for a field the farmer scouted and never burned. The relief manufactures
-- exactly that pair on a field that WAS burned: gate open, scores empty. So the relief
-- clears fieldEverScouted with the scores, and the field reads UNKNOWN until the next scout.

local B = SoilConstants.RESISTANCE.BANDS

-- The relieved field: scores gone, scout bit gone, disease identity untouched.
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(false)
  local f = { resistance = { ["3"] = R.MAX_SYNTHETIC }, fieldEverScouted = true, diseaseDiscovered = true }
  sys:_finalizeLoadedField(1, f)
  T.ok("F237: relieved field has its resistance cleared", next(f.resistance) == nil)
  T.eq("F237: relieved field drops fieldEverScouted", f.fieldEverScouted, false)
  T.eq("F237: ...as an explicit false, never nil", type(f.fieldEverScouted), "boolean")
  T.eq("F237: diseaseDiscovered is not touched", f.diseaseDiscovered, true)
  T.eq("F237: the clear is counted once", sys._f66ReliefCleared, 1)
  T.eq("F237: the classifier now says UNKNOWN for the zeroed mode",
       ResistanceBands.computeBand(f, "3"), B.UNKNOWN)
  T.eq("F237: ...and for a mode that never had a score", ResistanceBands.computeBand(f, "11"), B.UNKNOWN)
  T.eq("F237: the wire carries an empty band list for it", #ResistanceBands.encodeFieldBands(f), 0)
end

-- A field the relief does not enter keeps its bit: empty scores in a pending relief,
-- and any scores in a save that is already marked.
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(false)
  local empty = { resistance = {}, fieldEverScouted = true, diseaseDiscovered = true }
  sys:_finalizeLoadedField(1, empty)
  T.eq("F237: an empty-resistance field keeps its scout bit", empty.fieldEverScouted, true)
  T.eq("F237: ...and still bands WORKING for an unburned mode",
       ResistanceBands.computeBand(empty, "3"), B.WORKING)

  local marked = loadSys()
  marked:_beginF66ResistanceRelief(true)
  local kept = { resistance = { ["3"] = 2.5 }, fieldEverScouted = true }
  marked:_finalizeLoadedField(1, kept)
  T.eq("F237: a marked save keeps its scout bit", kept.fieldEverScouted, true)
  T.eq("F237: ...and its scores", kept.resistance["3"], 2.5)
end

-- A never-scouted field stays never-scouted through the relief (false in, false out).
do
  local sys = loadSys()
  sys:_beginF66ResistanceRelief(false)
  local f = { resistance = { ["3"] = 1.0 }, fieldEverScouted = false }
  sys:_finalizeLoadedField(1, f)
  T.eq("F237: false stays false", f.fieldEverScouted, false)
end

-- The explicit false must SURVIVE a save: both writers write it out as false/0 rather than
-- omitting it, because the loaders re-seed an ABSENT key from diseaseDiscovered.
do
  local sys = setmetatable({ fieldData = {}, lastUpdateDay = 7,
                             herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {} },
                           { __index = SoilFertilitySystem })
  sys.fieldData[1] = {
    resistance = {}, fieldEverScouted = false, diseaseDiscovered = true,
    fieldArea = 1, nutrientBuffer = {}, sessionCoverageCells = {},
  }
  local out = sys:getSoilStateTable()
  local e = nil
  if type(out.fields) == "table" then
    for _, v in pairs(out.fields) do e = v; break end
  end
  T.ok("F237: the ledger snapshot carries the field", e ~= nil)
  if e then
    T.eq("F237: the ledger writes fieldEverScouted as an explicit false", e.fieldEverScouted, false)
    T.eq("F237: ...next to a true diseaseDiscovered, which would otherwise re-seed it",
         e.diseaseDiscovered, true)
  end
end

-- Scouting again restores the bit through the server-only path, as today.
do
  -- Same shape as the CD-11 scout test: no activeDisease, so the report walk
  -- needs no disease system; the flags are the subject.
  local f = { resistance = { ["3"] = 1.0 }, fieldEverScouted = true, diseaseDiscovered = false }
  local sys = setmetatable({ settings = { diseasePressure = true }, fieldData = { [1] = f } },
                           { __index = SoilFertilitySystem })
  sys:_beginF66ResistanceRelief(false)
  sys:_finalizeLoadedField(1, f)
  T.eq("F237: relief cleared the bit before the scout", f.fieldEverScouted, false)
  local savedServer, savedMission = g_server, g_currentMission
  local savedFarmland, savedFarms = g_farmlandManager, g_farmManager
  g_server = {}
  g_currentMission = { missionDynamicInfo = { isMultiplayer = false } }
  -- [RSF-F231] the scout is made FOR farm 1, which owns farmland 1.
  g_farmlandManager = { getFarmlandOwner = function(_, id) return id == 1 and 1 or 0 end }
  g_farmManager = { getFarmById = function() return { getIsContractingFor = function() return false end } end }
  sys:scoutField(1, 1)
  g_server, g_currentMission = savedServer, savedMission
  g_farmlandManager, g_farmManager = savedFarmland, savedFarms
  T.eq("F237: a server scout sets the bit true again", f.fieldEverScouted, true)
  T.eq("F237: ...and the classifier is back to WORKING on the clean slate",
       ResistanceBands.computeBand(f, "3"), B.WORKING)
end
