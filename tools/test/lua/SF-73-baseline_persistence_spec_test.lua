-- SF-73-baseline_persistence_spec_test.lua
--
-- SF-73 section 6: the field-owned sf73UnknownNPK marker and the three frozen N/P/K
-- baselines, through BOTH of Soil's save paths, driven through the real writers and
-- readers: saveToXMLFile / loadFromXMLFile (the in-memory XML handle of the prelude)
-- and getSoilStateTable / applySoilStateTable (the StateLedger block). The rules
-- (the Design lifecycle model, re-pointed at production):
--   * an UNMARKED save freezes its baseline from its own loaded scalars, once;
--   * a MARKED save keeps only a valid stored set; a missing or invalid one is
--     unavailable and never re-freezes from a later report;
--   * a field born in session freezes at creation; a re-roll re-establishes it;
--   * a reload leaves no vehicle target state behind (a new controller holds none).
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/target/TargetNutrientCore.lua, src/target/TargetFootprint.lua, src/target/TargetApplication.lua, src/SoilFertilitySystem.lua

local TA = TargetApplication
-- the prelude's XML handle carries ints, floats and strings; bools the same way (XMLFile)
getXMLBool = getXMLBool or function(handle, key) if handle then return handle[key] end end
setXMLBool = setXMLBool or function(handle, key, value) if handle then handle[key] = value end end

local function newSys(fields)
  return setmetatable({
    fieldData = fields or {}, lastUpdateDay = 0, settings = { enabled = true },
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
  }, { __index = SoilFertilitySystem })
end
local function field(n, p, k)
  return { fieldArea = 2.0, nitrogen = n, phosphorus = p, potassium = k, organicMatter = 3.0, pH = 6.5,
           zoneData = {} }
end

-- ── the XML path ─────────────────────────────────────────────────────────────
do
  -- An UNMARKED save (written before SF-73): its loaded scalars are the legitimate
  -- pre-SF-73 values and freeze once.
  local xml = {}
  setXMLInt(xml, "soilData.field(0)#id", 7)
  setXMLFloat(xml, "soilData.field(0)#nitrogen", 41)
  setXMLFloat(xml, "soilData.field(0)#phosphorus", 32)
  setXMLFloat(xml, "soilData.field(0)#potassium", 27)
  local sys = newSys()
  sys:loadFromXMLFile(xml, "soilData")
  local b = sys.fieldData[7]._sf73Baseline
  T.eq("X1 an unmarked save freezes its baseline from the loaded scalars", b and (b.N .. "/" .. b.P .. "/" .. b.K), "41/32/27")

  -- SF-73 raises N; the save carries the marker and the ORIGINAL baseline.
  sys.fieldData[7].nitrogen = 60
  local out = {}
  sys:saveToXMLFile(out, "soilData")
  T.eq("X2 the save writes the root marker", getXMLInt(out, "soilData#sf73UnknownNPK"), 1)
  T.eq("X3 the save writes the frozen N baseline, not the later report", getXMLFloat(out, "soilData.field(0)#sf73BaseN"), 41)
  T.eq("X4 the later report is saved separately as the field scalar", getXMLFloat(out, "soilData.field(0)#nitrogen"), 60)

  local re = newSys()
  re:loadFromXMLFile(out, "soilData")
  local b2 = re.fieldData[7]._sf73Baseline
  T.eq("X5 the reload keeps the original baseline", b2 and b2.N, 41)
  T.eq("X6 and the changed report separately", re.fieldData[7].nitrogen, 60)
end
do
  -- A MARKED save that lost its baseline must not freeze the later report.
  local xml = {}
  setXMLInt(xml, "soilData#sf73UnknownNPK", 1)
  setXMLInt(xml, "soilData.field(0)#id", 7)
  setXMLFloat(xml, "soilData.field(0)#nitrogen", 60)
  setXMLFloat(xml, "soilData.field(0)#phosphorus", 50)
  setXMLFloat(xml, "soilData.field(0)#potassium", 50)
  local sys = newSys()
  sys:loadFromXMLFile(xml, "soilData")
  T.eq("X7 a marked save with no baseline freezes nothing", sys.fieldData[7]._sf73Baseline, nil)
  T.eq("X8 and records it unavailable", sys.fieldData[7]._sf73BaselineUnavailable, true)
  local out = {}
  sys:saveToXMLFile(out, "soilData")
  T.eq("X9 an unavailable baseline is never written from the later report", getXMLFloat(out, "soilData.field(0)#sf73BaseN"), nil)
  T.eq("X10 raw-zero initialization refuses without a baseline", TA.new(sys):initializeRawZero(7, sys.fieldData[7], {}), false)
end
do
  -- An invalid stored baseline (non-finite, out of range) is unavailable.
  local xml = {}
  setXMLInt(xml, "soilData#sf73UnknownNPK", 1)
  setXMLInt(xml, "soilData.field(0)#id", 7)
  setXMLFloat(xml, "soilData.field(0)#nitrogen", 60)
  setXMLFloat(xml, "soilData.field(0)#sf73BaseN", 0 / 0)
  setXMLFloat(xml, "soilData.field(0)#sf73BaseP", 1)
  setXMLFloat(xml, "soilData.field(0)#sf73BaseK", 2)
  local sys = newSys()
  sys:loadFromXMLFile(xml, "soilData")
  T.eq("X11 an invalid stored baseline is unavailable", sys.fieldData[7]._sf73Baseline, nil)
  local xml2 = {}
  setXMLInt(xml2, "soilData#sf73UnknownNPK", 1)
  setXMLInt(xml2, "soilData.field(0)#id", 7)
  setXMLFloat(xml2, "soilData.field(0)#sf73BaseN", 120)
  setXMLFloat(xml2, "soilData.field(0)#sf73BaseP", 1)
  setXMLFloat(xml2, "soilData.field(0)#sf73BaseK", 2)
  local sys2 = newSys()
  sys2:loadFromXMLFile(xml2, "soilData")
  T.eq("X12 an out-of-range stored baseline is unavailable", sys2.fieldData[7]._sf73Baseline, nil)
  local xml3 = {}
  setXMLInt(xml3, "soilData.field(0)#id", 7)
  setXMLFloat(xml3, "soilData.field(0)#nitrogen", 0)
  setXMLFloat(xml3, "soilData.field(0)#phosphorus", 0)
  setXMLFloat(xml3, "soilData.field(0)#potassium", 0)
  local sys3 = newSys()
  sys3:loadFromXMLFile(xml3, "soilData")
  T.eq("X13 a legitimate zero from an unmarked save is accepted", sys3.fieldData[7]._sf73Baseline and sys3.fieldData[7]._sf73Baseline.N, 0)
end
do
  -- A field never touched by SF-73 in a marked session still saves a baseline: its
  -- scalars have had no SF-73 change, so they are frozen rather than lost.
  local sys = newSys({ [9] = field(33, 22, 11) })
  local out = {}
  sys:saveToXMLFile(out, "soilData")
  T.eq("X14 an untouched field saves its current scalars as its baseline", getXMLFloat(out, "soilData.field(0)#sf73BaseN"), 33)
end

-- ── the StateLedger path ─────────────────────────────────────────────────────
do
  local src = newSys({ [7] = field(41, 32, 27) })
  TA.freezeBaseline(src.fieldData[7])
  src.fieldData[7].nitrogen = 60
  local snap = src:getSoilStateTable()
  T.eq("L1 the ledger block mirrors the marker", snap.sf73UnknownNPK, 1)
  T.eq("L2 and carries the frozen baseline", snap.fields[7].sf73BaseN, 41)
  local dst = newSys()
  dst:applySoilStateTable(snap)
  T.eq("L3 a ledger reload keeps the original baseline", dst.fieldData[7]._sf73Baseline and dst.fieldData[7]._sf73Baseline.N, 41)
  T.eq("L4 and the later report separately", dst.fieldData[7].nitrogen, 60)

  local marked = { sf73UnknownNPK = 1, fields = { [7] = { nitrogen = 60, phosphorus = 50, potassium = 50 } } }
  local dst2 = newSys()
  dst2:applySoilStateTable(marked)
  T.eq("L5 a marked snapshot without a baseline freezes nothing", dst2.fieldData[7]._sf73Baseline, nil)
  T.eq("L6 and is unavailable", dst2.fieldData[7]._sf73BaselineUnavailable, true)

  local older = { fields = { [7] = { nitrogen = 44, phosphorus = 33, potassium = 22 } } }
  local dst3 = newSys()
  dst3:applySoilStateTable(older)
  T.eq("L7 a snapshot from before SF-73 freezes its own loaded scalars", dst3.fieldData[7]._sf73Baseline and dst3.fieldData[7]._sf73Baseline.N, 44)
end

-- ── creation, re-roll and reload ─────────────────────────────────────────────
do
  local f = field(38, 29, 31)
  T.ok("B1 a fresh field freezes once", TA.freezeBaseline(f))
  f.nitrogen = 70
  T.ok("B2 a second freeze never moves a frozen baseline", not TA.freezeBaseline(f))
  T.eq("B3 the baseline is the value before the change", f._sf73Baseline.N, 38)
  local u = field(38, 29, 31)
  u._sf73BaselineUnavailable = true
  T.ok("B4 an unavailable field never freezes lazily", not TA.freezeBaseline(u))
end
do
  -- the reload rule: a new controller carries no vehicle state, plan, result or anchor
  local sys = newSys()
  local ta1 = TA.new(sys)
  local vehicle = {}
  ta1.states[vehicle] = { result = { doseState = "REACHED" }, hold = { anchor = {} } }
  local ta2 = TA.new(sys)
  T.eq("R1 a reloaded controller has no state for an old vehicle", ta2.states[vehicle], nil)
  T.eq("R2 and no result for it", ta2:getApplicationTargetResult(vehicle), nil)
  ta1:reset()
  T.eq("R3 reset forgets vehicle results and anchors", next(ta1.states), nil)
end

T.summary()
