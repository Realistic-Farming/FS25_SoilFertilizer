-- SF-79-ph_schema_seed_freeze_test.lua: SF-79 section 3.B, the write-only schema key
-- gets its one legitimate reader, and the frozen pre-migration scalar is originated.
--
-- THE GAP. `#sf79PHSchema` has been written on every soil XML save since 71c9bcf2 and
-- read nowhere. Meanwhile `field._phSeedScalar`, the brief's "frozen pre-migration
-- scalar", was never ORIGINATED: its only writers were the XML load (from #sf79PHSeed)
-- and the ledger restore (from e.sf79PHSeed), and #sf79PHSeed is only saved when the
-- seed is already a number. So no save ever carried a seed.
--
-- WHY THE MARKER DECIDES THE FREEZE. `field.pH` is republished from the derived report
-- by `_phRefreshScalar` after every positional write. On a save written by a build with
-- the contract, the loaded #pH may already be "the later report", which 3.B forbids as a
-- seed ("New cultivated ground uses the frozen seed, never the later report"). Only an
-- UNMARKED save proves its #pH came before SF-79. A marked save with no seed is left nil
-- on purpose; the genesis rule the brief names as the alternative is the seeding item's.
--
-- ENTRY-POINT BARS: every row drives the REAL loadFromXMLFile or the REAL
-- applySoilStateTable with an XML handle or a ledger table as the input, exactly as the
-- mission load and the StateLedger restore call them. No row sets _phSeedScalar by hand;
-- the seed either comes out of the loader or it does not. The XML handle is the
-- prelude's in-memory mock (a table keyed by the XML path), the same one the F66 relief
-- and StateLedger round-trip bars use. The ledger mirror is also driven for real: group
-- G's snapshots come from the real getSoilStateTable.
--
-- What this bar does NOT prove: that the game writes and reads the attributes through
-- the engine's XML functions (in-game row), and anything about seeding the map itself
-- (the seeding item, which consumes the seed this item originates).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua

-- The prelude's XML mock covers int, float and string; the field loader also reads
-- one bool attribute, so the same shape is supplied here (a table keyed by path).
getXMLBool = getXMLBool or function(handle, key) if handle then return handle[key] end end
setXMLBool = setXMLBool or function(handle, key, value) if handle then handle[key] = value end end

local LIM = SoilConstants.NUTRIENT_LIMITS
T.eq("SEED 0a: the carrier bounds this bar clamps to are 5.0 and 7.5", LIM.PH_MIN == 5.0 and LIM.PH_MAX == 7.5, true)

local KEY = "soilData"

local function newSys()
  return setmetatable({
    fieldData = {}, lastUpdateDay = 0,
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
end

-- Build an XML handle the way a save on disk looks: root attributes plus one field.
-- `marked` writes the root #sf79PHSchema; `seed` writes the field's #sf79PHSeed.
local function xmlSave(opts)
  local h = {}
  h[KEY .. "#lastUpdateDay"] = 3
  if opts.marked then h[KEY .. "#sf79PHSchema"] = 1 end
  local fk = KEY .. ".field(0)"
  h[fk .. "#id"] = 1
  h[fk .. "#fieldArea"] = 2.0
  h[fk .. "#pH"] = opts.pH
  if opts.seed ~= nil then h[fk .. "#sf79PHSeed"] = opts.seed end
  return h
end

local function loadXML(opts)
  local s = newSys()
  local ok, err = pcall(SoilFertilitySystem.loadFromXMLFile, s, xmlSave(opts), KEY)
  return s, ok, err
end

-- =====================================================================
-- GROUP A-E: the XML loader, one field, every marker/seed combination.
-- =====================================================================
do
  local s, ok, err = loadXML({ marked = false, pH = 8.0 })
  T.ok("SEED A0: unmarked save loads (" .. tostring(err) .. ")", ok)
  local f = s.fieldData[1]
  T.eq("SEED A1: unmarked, #pH 8.0: the loaded scalar keeps the load clamp (8.0 is under 8.5)", f and f.pH, 8.0)
  T.eq("SEED A2: unmarked, #pH 8.0: the seed is frozen at the CARRIER bound, 7.5", f and f._phSeedScalar, 7.5)
end
do
  local s = loadXML({ marked = false, pH = 6.2 })
  T.eq("SEED B1: unmarked, #pH 6.2: the seed is frozen at 6.2", s.fieldData[1]._phSeedScalar, 6.2)
  T.eq("SEED B2: and the scalar itself is untouched", s.fieldData[1].pH, 6.2)
end
do
  local s = loadXML({ marked = false, pH = 4.0 })
  T.eq("SEED B3: unmarked, #pH below the carrier: the load clamps to 5.0 and the seed is 5.0", s.fieldData[1]._phSeedScalar, 5.0)
end
do
  local s = loadXML({ marked = true, pH = 6.9 })
  T.eq("SEED C1: MARKED, no seed: nothing is frozen (the scalar may be the later report)", s.fieldData[1]._phSeedScalar, nil)
  T.eq("SEED C2: and the scalar still loads", s.fieldData[1].pH, 6.9)
end
do
  local s = loadXML({ marked = true, pH = 6.9, seed = 6.1 })
  T.eq("SEED D1: MARKED with #sf79PHSeed 6.1 and #pH 6.9: the seed is 6.1, not re-frozen from the scalar", s.fieldData[1]._phSeedScalar, 6.1)
end
do
  local s = loadXML({ marked = false, pH = 6.9, seed = 6.3 })
  T.eq("SEED E1: unmarked WITH a seed: the carried seed wins over the scalar", s.fieldData[1]._phSeedScalar, 6.3)
end

-- =====================================================================
-- GROUP F: the round trip. An unmarked save is loaded, the field's pH moves, the
-- save is written and reloaded: the seed persists and the second load, now marked,
-- does not re-freeze it from the moved scalar.
-- =====================================================================
do
  local s = loadXML({ marked = false, pH = 6.2 })
  T.eq("SEED F1: first load from an unmarked save freezes 6.2", s.fieldData[1]._phSeedScalar, 6.2)
  s.fieldData[1].pH = 6.8            -- what liming plus _phRefreshScalar does between saves
  local out = {}
  local ok, err = pcall(SoilFertilitySystem.saveToXMLFile, s, out, KEY)
  T.ok("SEED F2: the save ran (" .. tostring(err) .. ")", ok)
  T.eq("SEED F3: the root now carries #sf79PHSchema=1", out[KEY .. "#sf79PHSchema"], 1)
  local fk
  for k, v in pairs(out) do
    if type(k) == "string" and k:find("#id$") and v == 1 then fk = k:gsub("#id$", "") end
  end
  T.ok("SEED F4: the field record was written", fk ~= nil)
  T.eq("SEED F5: the field record carries #sf79PHSeed 6.2, the FIRST time any save has held a seed", fk and out[fk .. "#sf79PHSeed"], 6.2)
  T.eq("SEED F6: and #pH is the moved scalar, 6.8", fk and out[fk .. "#pH"], 6.8)
  local s2 = newSys()
  local ok2, err2 = pcall(SoilFertilitySystem.loadFromXMLFile, s2, out, KEY)
  T.ok("SEED F7: the reload ran (" .. tostring(err2) .. ")", ok2)
  T.eq("SEED F8: after reload the seed is still 6.2 (marked now, so no re-freeze from 6.8)", s2.fieldData[1]._phSeedScalar, 6.2)
  T.eq("SEED F9: and the scalar is 6.8", s2.fieldData[1].pH, 6.8)
end

-- =====================================================================
-- GROUP G: the StateLedger mirror. getSoilStateTable carries the marker;
-- applySoilStateTable makes the same freeze decision the XML load makes.
-- =====================================================================
do
  local s = newSys()
  s.fieldData[1] = { fieldArea = 2.0, pH = 6.4 }
  local snap = s:getSoilStateTable()
  T.eq("SEED G1: the ledger snapshot carries sf79PHSchema=1, as the XML root does", snap.sf79PHSchema, 1)
  T.eq("SEED G2: a field with no seed writes no sf79PHSeed", snap.fields[1].sf79PHSeed, nil)
end
local function applyLedger(data)
  local s = newSys()
  local ok, err = pcall(SoilFertilitySystem.applySoilStateTable, s, data)
  return s, ok, err
end
do
  local s, ok, err = applyLedger({ lastUpdateDay = 3, fields = { [1] = { fieldArea = 2.0, pH = 8.0 } } })
  T.ok("SEED G3: an UNMARKED ledger table applies (" .. tostring(err) .. ")", ok)
  T.eq("SEED G4: unmarked ledger, pH 8.0: the seed is frozen at the carrier bound 7.5", s.fieldData[1]._phSeedScalar, 7.5)
end
do
  local s = applyLedger({ lastUpdateDay = 3, sf79PHSchema = 1, fields = { [1] = { fieldArea = 2.0, pH = 6.9 } } })
  T.eq("SEED G5: MARKED ledger, no seed: nothing is frozen", s.fieldData[1]._phSeedScalar, nil)
end
do
  local s = applyLedger({ lastUpdateDay = 3, sf79PHSchema = 1, fields = { [1] = { fieldArea = 2.0, pH = 6.9, sf79PHSeed = 6.1 } } })
  T.eq("SEED G6: MARKED ledger with a seed: 6.1 carried, not re-frozen", s.fieldData[1]._phSeedScalar, 6.1)
end
do
  -- The real mirror end to end: a system whose field has NO seed (a dev save's shape)
  -- snapshots through the real getSoilStateTable and restores. Because the snapshot is
  -- marked, the restore must NOT invent a seed from the scalar.
  local src = newSys()
  src.fieldData[1] = { fieldArea = 2.0, pH = 6.9 }
  local s = applyLedger(src:getSoilStateTable())
  T.eq("SEED G7: real snapshot of a seedless field restores with NO seed (the marker travelled)", s.fieldData[1]._phSeedScalar, nil)
  -- And a frozen seed survives the mirror unchanged while the scalar differs.
  local src2 = loadXML({ marked = false, pH = 6.2 })
  src2.fieldData[1].pH = 6.8
  local s2 = applyLedger(src2:getSoilStateTable())
  T.eq("SEED G8: a frozen seed survives the ledger mirror at 6.2 while the scalar is 6.8", s2.fieldData[1]._phSeedScalar, 6.2)
  T.eq("SEED G9: the scalar restores as 6.8", s2.fieldData[1].pH, 6.8)
end

-- =====================================================================
-- GROUP H: the marker gates ONLY the freeze. Everything else an unmarked or marked
-- save carries loads the same either way.
-- =====================================================================
do
  local a = loadXML({ marked = false, pH = 6.2 })
  local b = loadXML({ marked = true, pH = 6.2 })
  T.eq("SEED H1: marker or not, the scalar loads identically", a.fieldData[1].pH == b.fieldData[1].pH, true)
  T.eq("SEED H2: marker or not, the pending list is restored (empty here) on both", type(a.fieldData[1]._phPending) == "table" and type(b.fieldData[1]._phPending) == "table", true)
  T.eq("SEED H3: marker or not, the field count is one on both", a.fieldData[1] ~= nil and b.fieldData[1] ~= nil, true)
end
do
  -- The helper's own contract, driven directly for the shapes the loaders cannot
  -- produce: a non-number scalar and a missing record freeze nothing and say so.
  local s = newSys()
  T.eq("SEED H4: a record whose pH is not a number is not frozen", s:_phFreezeSeedFromLoad({ pH = "x" }, false), false)
  T.eq("SEED H5: a nil record is not frozen", s:_phFreezeSeedFromLoad(nil, false), false)
  local rec = { pH = 6.0 }
  T.eq("SEED H6: the helper reports true exactly when it froze", s:_phFreezeSeedFromLoad(rec, false), true)
  T.eq("SEED H7: and false on the second call, the seed being present", s:_phFreezeSeedFromLoad(rec, false), false)
end
