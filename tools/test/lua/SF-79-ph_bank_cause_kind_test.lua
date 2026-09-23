-- SF-79-ph_bank_cause_kind_test.lua: the positional pH sub-step bank keeps its
-- remainders separate per cause, kind and domain in USE, not only in storage
-- (MAINTENANCE row 72; Bob's cold verdict on #979).
--
-- THE DEFECT. _phAddPending stored cause and kind; _phTakePending took every
-- remainder on the domain regardless, and _phApplyField summed them into whatever
-- operation ran now. A plow NORMALIZE remainder (a magnitude, "toward 7.0") could be
-- added to a rain DELTA (a signed change): for a field above 7.0 the plow wanted the
-- value to fall, and its banked positive magnitude made the rain's delta less
-- negative. Bounded under one raw step per mixing event, wrong in direction, silent.
-- SF-79 3.B: "Sub-step scheduled FIELD remainders stay separate per cause/kind/domain".
--
-- THE ENTRY-POINT BAR IS GROUP A: the REAL onPlowing and the REAL applyRainEffects,
-- through the REAL _phApplyField, _phTakePending and _phAddPending, against a stub
-- of the pH map only (the footprint and the report, as the accepted plow bar does).
-- No row writes a remainder by hand: every banked amount arrives through a
-- production caller. Group B drives the bank's own functions directly for the rules
-- the two callers cannot reach (another cause of the same kind, another domain, a
-- caller with no cause). Groups C and D are the two save paths, XML and the
-- StateLedger mirror, with an older save's cause-less remainder dropped and said.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/PositionalPH.lua

local savedEnv = g_currentMission.environment
g_currentMission.environment = { currentDay = 5 }

local UPR = PositionalPH.unitsPerRaw()          -- one raw pH step, about 0.0098
T.ok("BANK 0: one raw step is a small positive number", UPR > 0.009 and UPR < 0.011)

local function num(x)
  if type(x) ~= "number" then return tostring(x) end
  local r = math.floor(x * 1e6 + 0.5) / 1e6
  if r == math.floor(r) then return string.format("%d", math.floor(r)) end
  return tostring(r)
end

--- The bank as "cause:kind:amount" in order, amounts in raw steps to 4 places.
local function bank(s, fieldId)
  local out = {}
  for _, p in ipairs(s.fieldData[fieldId]._phPending or {}) do
    out[#out + 1] = tostring(p.cause) .. ":" .. tostring(p.kind) .. ":" .. num(math.floor((p.amount or 0) / UPR * 10000 + 0.5) / 10000)
  end
  return table.concat(out, ",")
end

--- A system with one 2 ha field ABOVE 7.0, the real writer on a stub map.
local function newRoutedSys(pH)
  local s = setmetatable({
    settings = { enabled = true, plowingBonus = true, rainEffects = true, weedPressure = false,
                 pestPressure = false, diseasePressure = false, residueIncorporation = false },
    fieldData = { [3] = { fieldArea = 2.0, pH = pH, organicMatter = 3.0, nitrogen = 50,
                          phosphorus = 50, potassium = 50, sessionCoverageCells = {} } },
    activeFieldIds = { [3] = true },
    herbicideAppliedDay = {}, insecticideAppliedDay = {}, fungicideAppliedDay = {},
    valueMaps = nil, lastUpdateDay = 0,
  }, { __index = SoilFertilitySystem })
  s._plowAreaToday = {}
  local map = { value = pH, footprints = {} }
  s._applyPHFootprint = function(_self, fieldId, req)
    map.footprints[#map.footprints + 1] = req
    if req.operation == PositionalPH.OP_NORMALIZE then
      local v, lo, hi, step = map.value, req.targetLow, req.targetHigh, req.value
      if v < lo then map.value = math.min(lo, v + step) elseif v > hi then map.value = math.max(hi, v - step) end
    elseif req.operation == PositionalPH.OP_DELTA then
      map.value = map.value + req.value
    end
    return { status = PositionalPH.STATUS_APPLIED }
  end
  s._ensurePHReport = function() return { status = PositionalPH.REPORT_CURRENT, value = map.value } end
  s._getFarmlandPolygons = function() return { { { x = 0, z = 0 }, { x = 10, z = 0 }, { x = 10, z = 10 } } } end
  return s, map
end

--- The rain tick length that makes applyRainEffects' pH DELTA exactly `steps` raw steps.
local function rainDtFor(steps)
  local rain = SoilConstants.RAIN
  local tun = (SoilConstants.TUNING and SoilConstants.TUNING.ZERO_MULT and SoilConstants.TUNING.ZERO_MULT[3]) or 1.0
  return steps * UPR / (rain.LEACH_BASE_FACTOR * rain.PH_ACIDIFICATION * tun)
end

-- =====================================================================
-- GROUP A: the real plow and the real rain through the real bank.
-- =====================================================================
local s, map = newRoutedSys(7.3)
local KEY = s:_phDomainKey(3)
do
  s:onPlowing(3, 0.05, false, 0)                      -- 0.05 of 2 ha: 0.1 x 0.025 = 0.0025, sub-step
  T.eq("BANK A1 [world] a small plow's NORMALIZE is below one step: nothing written, banked under plow/NORMALIZE",
    tostring(#map.footprints) .. "/" .. bank(s, 3), "0/plow:NORMALIZE:0.254")
  s:applyRainEffects(rainDtFor(1.2), 1.0)             -- a rain DELTA of -1.2 steps on its own
  T.eq("BANK A2 the rain's own DELTA crosses a step and IS written: the plow's remainder did not cancel it",
    tostring(#map.footprints) .. "/" .. tostring(map.footprints[1] and map.footprints[1].operation) .. "/" .. num(map.footprints[1] and map.footprints[1].value / UPR or 0) .. "/" .. tostring(map.footprints[1] and map.footprints[1].source),
    "1/DELTA/-1/rain")
  T.near("BANK A3 and the map fell by exactly one step", map.value, 7.3 - UPR, 1e-9)
  T.eq("BANK A4 the bank now holds the plow's magnitude AND the rain's residual, each under its own cause and kind",
    bank(s, 3), "plow:NORMALIZE:0.254,rain:DELTA:-0.2")
end
do
  s:onPlowing(3, 0.05, false, 0)
  s:onPlowing(3, 0.05, false, 0)
  T.eq("BANK A5 two more small plows accumulate under plow/NORMALIZE (0.762 step) and write nothing yet",
    tostring(#map.footprints) .. "/" .. bank(s, 3), "1/rain:DELTA:-0.2,plow:NORMALIZE:0.762")
  local before = map.value
  s:onPlowing(3, 0.05, false, 0)                      -- the fourth crosses one step: 1.016
  local fp = map.footprints[2]
  T.eq("BANK A6 the fourth plow crosses a step and is written as a NORMALIZE toward 7.0 of one step, from the plow",
    tostring(#map.footprints) .. "/" .. tostring(fp and fp.operation) .. "/" .. num(fp and fp.targetLow or 0) .. "/" .. num(fp and fp.value / UPR or 0) .. "/" .. tostring(fp and fp.source),
    "2/NORMALIZE/7/1/plow")
  T.near("BANK A7 the field above 7.0 FALLS by one step (the plow's direction, never a rain delta's sign)", map.value, before - UPR, 1e-9)
  T.eq("BANK A8 the rain's residual is untouched by the plow, and the plow keeps its own residual",
    bank(s, 3), "rain:DELTA:-0.2,plow:NORMALIZE:0.016")
end

-- =====================================================================
-- GROUP B: the bank's own rules, reached directly.
-- =====================================================================
do
  s:_phApplyField(3, PositionalPH.OP_DELTA, -0.3 * UPR, nil, nil, 'scorch')
  T.eq("BANK B1 a DELTA of ANOTHER cause does not take the rain's DELTA residual: three entries, three causes",
    bank(s, 3), "rain:DELTA:-0.2,plow:NORMALIZE:0.016,scorch:DELTA:-0.3")
  s:_phApplyField(3, PositionalPH.OP_NORMALIZE, 0.2 * UPR, 7.0, 7.0, 'daily')
  T.eq("BANK B2 a NORMALIZE of another cause does not take the plow's NORMALIZE residual",
    bank(s, 3), "rain:DELTA:-0.2,plow:NORMALIZE:0.016,scorch:DELTA:-0.3,daily:NORMALIZE:0.2")
  s:_phApplyField(3, PositionalPH.OP_DELTA, -0.6 * UPR, nil, nil, 'scorch')
  T.eq("BANK B3 the same cause and kind DOES take its own residual (scorch -0.3 joins -0.6: -0.9, still sub-step, re-banked as one)",
    bank(s, 3), "rain:DELTA:-0.2,plow:NORMALIZE:0.016,daily:NORMALIZE:0.2,scorch:DELTA:-0.9")
  local other = s:_phTakePending(3, KEY .. "|other", 'rain', PositionalPH.OP_DELTA)
  T.eq("BANK B4 another domain takes nothing and leaves the bank whole", tostring(#other) .. "/" .. tostring(#s.fieldData[3]._phPending), "0/4")
  local mine = s:_phTakePending(3, KEY, 'rain', PositionalPH.OP_DELTA)
  T.eq("BANK B5 the matching domain, cause and kind takes exactly its entry", tostring(#mine) .. "/" .. num(mine[1] and mine[1].amount / UPR or 0) .. "/" .. bank(s, 3),
    "1/-0.2/plow:NORMALIZE:0.016,daily:NORMALIZE:0.2,scorch:DELTA:-0.9")
  s:_phAddPending(3, 'rain', PositionalPH.OP_DELTA, mine[1].amount, KEY)   -- put it back for the save groups
  s:_phApplyField(3, PositionalPH.OP_DELTA, -0.3 * UPR, nil, nil, 'daily')
  T.eq("BANK B5b the SAME cause with the OTHER kind does not take the residual either: a daily DELTA leaves the daily NORMALIZE banked",
    bank(s, 3), "plow:NORMALIZE:0.016,daily:NORMALIZE:0.2,scorch:DELTA:-0.9,rain:DELTA:-0.2,daily:DELTA:-0.3")
end
do
  local lines = {}
  local realPrint = print
  print = function(x) lines[#lines + 1] = tostring(x) realPrint(x) end
  local before = bank(s, 3)
  local okNil = s:_phAddPending(3, nil, PositionalPH.OP_DELTA, 0.1 * UPR, KEY)
  local okKind = s:_phAddPending(3, 'rain', 'SET', 0.1 * UPR, KEY)
  local okEmpty = s:_phAddPending(3, '', PositionalPH.OP_NORMALIZE, 0.1 * UPR, KEY)
  local okNan = s:_phAddPending(3, 'rain', PositionalPH.OP_DELTA, 0 / 0, KEY)
  local okZero = s:_phAddPending(3, 'rain', PositionalPH.OP_DELTA, 0, KEY)
  print = realPrint
  T.eq("BANK B6 a remainder with no cause, a kind that is not an operation, an empty cause, a NaN amount or a zero amount is never banked",
    tostring(okNil) .. tostring(okKind) .. tostring(okEmpty) .. tostring(okNan) .. tostring(okZero) .. "/" .. tostring(bank(s, 3) == before), "falsefalsefalsefalsefalse/true")
  local warned = 0
  for _, l in ipairs(lines) do if l:find("was not banked", 1, true) then warned = warned + 1 end end
  T.eq("BANK B7 the refusal of a cause-less remainder is said once, not per call", warned, 1)
end

-- =====================================================================
-- GROUP C: the XML save path round-trips the separated bank; an older save's
-- cause-less remainder is dropped and said once.
-- =====================================================================
do
  local out, fk = {}, "soilData.field(0)"
  s:_phSaveFieldXML(out, fk, s.fieldData[3])
  T.eq("BANK C1 the save writes every entry with its cause and kind", tostring(out[fk .. "#sf79PHPendingCount"]) .. "/" .. tostring(out[fk .. ".sf79PHPending(0)#cause"]) .. "/" .. tostring(out[fk .. ".sf79PHPending(0)#kind"]), "5/plow/NORMALIZE")
  local s2 = newRoutedSys(7.3)
  s2:_phLoadFieldXML(out, fk, s2.fieldData[3])
  T.eq("BANK C2 the reload restores the same five entries, cause and kind intact", bank(s2, 3), bank(s, 3))
  T.eq("BANK C3 and their domain keys", s2.fieldData[3]._phPending[1].domainKey == KEY and s2.fieldData[3]._phPending[5].domainKey == KEY, true)
end
do
  -- An older save: entries written before the bank had a cause on every remainder.
  local old, fk = {}, "soilData.field(0)"
  old[fk .. "#sf79PHPendingCount"] = 3
  old[fk .. ".sf79PHPending(0)#cause"] = ''
  old[fk .. ".sf79PHPending(0)#kind"] = ''
  old[fk .. ".sf79PHPending(0)#amount"] = 0.4 * UPR
  old[fk .. ".sf79PHPending(0)#domainKey"] = KEY
  old[fk .. ".sf79PHPending(1)#cause"] = 'rain'
  old[fk .. ".sf79PHPending(1)#kind"] = PositionalPH.OP_DELTA
  old[fk .. ".sf79PHPending(1)#amount"] = -0.2 * UPR
  old[fk .. ".sf79PHPending(1)#domainKey"] = KEY
  old[fk .. ".sf79PHPending(2)#cause"] = 'plow'
  old[fk .. ".sf79PHPending(2)#kind"] = ''
  old[fk .. ".sf79PHPending(2)#amount"] = 0.3 * UPR
  old[fk .. ".sf79PHPending(2)#domainKey"] = KEY
  local lines = {}
  local realPrint = print
  print = function(x) lines[#lines + 1] = tostring(x) realPrint(x) end
  local s3 = newRoutedSys(7.3)
  s3:_phLoadFieldXML(old, fk, s3.fieldData[3])
  print = realPrint
  T.eq("BANK C4 an older save's remainders without a cause or a kind are dropped; the complete one is kept", bank(s3, 3), "rain:DELTA:-0.2")
  local said = 0
  for _, l in ipairs(lines) do if l:find("2 banked remainder(s) in the xml save", 1, true) and l:find("dropped", 1, true) then said = said + 1 end end
  T.eq("BANK C5 and the drop is said once for the field, with the count and the save path", said, 1)
end

-- =====================================================================
-- GROUP D: the StateLedger mirror, the second save path, makes the same decision.
-- =====================================================================
do
  local snap = s:getSoilStateTable()
  T.eq("BANK D1 the mirror carries every entry with its cause and kind", tostring(#snap.fields[3].sf79PHPending) .. "/" .. tostring(snap.fields[3].sf79PHPending[1].cause) .. "/" .. tostring(snap.fields[3].sf79PHPending[1].kind), "5/plow/NORMALIZE")
  local d = newRoutedSys(7.3)
  d:applySoilStateTable(snap)
  T.eq("BANK D2 the ledger restore keeps the same five entries", bank(d, 3), bank(s, 3))
  local lines = {}
  local realPrint = print
  print = function(x) lines[#lines + 1] = tostring(x) realPrint(x) end
  local d2 = newRoutedSys(7.3)
  d2:applySoilStateTable({ lastUpdateDay = 3, sf79PHSchema = 1, fields = { [3] = { fieldArea = 2.0, pH = 7.3, sf79PHPending = {
    { cause = '', kind = '', amount = 0.4 * UPR, domainKey = KEY },
    { cause = 'rain', kind = PositionalPH.OP_DELTA, amount = -0.2 * UPR, domainKey = KEY },
    { cause = 'plow', kind = '', amount = 0.3 * UPR, domainKey = KEY },
    { cause = 'daily', kind = PositionalPH.OP_NORMALIZE, amount = 0.1 * UPR },
  } } } })
  print = realPrint
  T.eq("BANK D3 an older mirror's entries without a cause, a kind or a domain are dropped; the complete one is kept", bank(d2, 3), "rain:DELTA:-0.2")
  local said = 0
  for _, l in ipairs(lines) do if l:find("3 banked remainder(s) in the ledger save", 1, true) and l:find("dropped", 1, true) then said = said + 1 end end
  T.eq("BANK D4 said once for the field, with the count and the save path", said, 1)
end

g_currentMission.environment = savedEnv
