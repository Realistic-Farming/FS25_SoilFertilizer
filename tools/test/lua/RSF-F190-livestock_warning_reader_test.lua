-- RSF-F190-livestock_warning_reader_test.lua - the dog's barn half asks one
-- SoilFertilizer-owned reader and tests presence (RSF-F190, handoff v0.8).
--!load: src/LivestockWarningReader.lua, src/DogEarlyWarning.lua
--
-- Acceptance discriminators from the 6A record, section 10: active, cured,
-- carrier, mixed-record, healthy, provider absent, diseases disabled,
-- malformed record and thrown read each to their own return; the same set
-- against both provider gate shapes (1.2.6.0: any attached record satisfies
-- the getter; 1.3.2.1: only a not-cured, not-carrier record does); containment
-- proven not to silence a barn or a farm; and proven unchanged: crop warning,
-- same-farm filter, dog gate, dedupe key and its clearing, delivery, and no
-- new player-facing string.
--
-- The provider fixtures below model only what the reader is allowed to see:
-- animal.getHasAnyDisease() and animal.diseases, each record carrying cured
-- and isCarrier as the provider's constructor, XML load and stream read write
-- them (Disease.lua:10,15 on 1.2.6.0).
--
-- The Realistic Livestock 1.4.0.0 delta (brief v1.0, amendment v0.9) adds a
-- section near the end: the record-state table, the provider's own 1.4 gate
-- line for line, and the entry-point bar through dog:update, the call
-- src/main.lua:972 makes.

local R = LivestockWarningReader

-- ── record fixtures ──────────────────────────────────────
local function rec(cured, carrier) return { type = "x", cured = cured, isCarrier = carrier } end
local ACTIVE   = function() return rec(false, false) end
local CURED    = function() return rec(true,  false) end
local CARRIER  = function() return rec(false, true)  end

-- Provider gate shapes. ANY = 1.2.6.0 (#self.diseases > 0 with diseases enabled);
-- STRICT = 1.3.2.1 (true only where a record is neither cured nor a carrier).
local function gateAny(self)
  return self._enabled and #self.diseases > 0
end
local function gateStrict(self)
  if not self._enabled then return false end
  for _, d in ipairs(self.diseases) do
    if not d.cured and not d.isCarrier then return true end
  end
  return false
end

local function animal(records, opts)
  opts = opts or {}
  local a = { diseases = records, _enabled = opts.enabled ~= false }
  if opts.noGetter then return a end
  if opts.gateThrows then
    a.getHasAnyDisease = function() error("provider boom") end
  elseif opts.gateNil then
    a.getHasAnyDisease = function() return nil end
  elseif opts.gateReturns ~= nil then
    a.getHasAnyDisease = function() return opts.gateReturns end
  else
    a.getHasAnyDisease = opts.strict and gateStrict or gateAny
  end
  return a
end

local function barn(animals, opts)
  opts = opts or {}
  local p = { spec_husbandryAnimals = { clusterSystem = { getAnimals = function() return animals end } } }
  if opts.listThrows then
    p.spec_husbandryAnimals.clusterSystem.getAnimals = function() error("list boom") end
  end
  p.getOwnerFarmId = function() return opts.farm or 1 end
  p.getUniqueId = function() if opts.idThrows then error("id boom") end return opts.id or "B1" end
  return p
end

-- ── the reader never throws to its caller ────────────────
-- Run first, so a guard that goes missing fails a named row here instead of
-- only crashing a later direct call.
local walkBoom = function() return { diseases = { setmetatable({}, { __index = function() error("walk boom") end }) }, getHasAnyDisease = function() return true end } end
T.eq("no throw: record nil", (pcall(R.isActiveRecord, nil)), true)
T.eq("no throw: record number", (pcall(R.isActiveRecord, 5)), true)
T.eq("no throw: animal nil", (pcall(R.isAnimalActivelySick, nil)), true)
T.eq("no throw: animal number", (pcall(R.isAnimalActivelySick, 42)), true)
T.eq("no throw: gate throws", (pcall(R.isAnimalActivelySick, animal({ ACTIVE() }, { gateThrows = true }))), true)
T.eq("no throw: record walk throws", (pcall(R.isAnimalActivelySick, walkBoom())), true)
T.eq("no throw: barn nil", (pcall(R.isBarnActivelySick, nil)), true)
T.eq("no throw: barn list throws", (pcall(R.isBarnActivelySick, barn({}, { listThrows = true }))), true)
T.eq("no throw: barn list not a table", (pcall(R.isBarnActivelySick, { spec_husbandryAnimals = { clusterSystem = { getAnimals = function() return 5 end } } })), true)
T.eq("no throw: barn with an animal whose field read raises",
     (pcall(R.isBarnActivelySick, barn({ setmetatable({}, { __index = function() error("field boom") end }), animal({ ACTIVE() }) }))), true)

-- ── isActiveRecord: the per-record law ───────────────────
T.eq("record: active counts", R.isActiveRecord(ACTIVE()), true)
T.eq("record: cured does not count", R.isActiveRecord(CURED()), false)
T.eq("record: carrier does not count", R.isActiveRecord(CARRIER()), false)
T.eq("record: cured carrier does not count", R.isActiveRecord(rec(true, true)), false)
T.eq("record: malformed nil cured does not count", R.isActiveRecord({ cured = nil, isCarrier = false }), false)
T.eq("record: malformed nil carrier does not count", R.isActiveRecord({ cured = false, isCarrier = nil }), false)
T.eq("record: malformed string flags do not count", R.isActiveRecord({ cured = "false", isCarrier = "false" }), false)
T.eq("record: malformed numeric flags do not count", R.isActiveRecord({ cured = 0, isCarrier = 0 }), false)
T.eq("record: non-table does not count", R.isActiveRecord("sick"), false)
T.eq("record: nil does not count", R.isActiveRecord(nil), false)

-- ── isAnimalActivelySick against BOTH gate shapes ────────
for _, shape in ipairs({ { name = "1.2.6.0 any-record gate", strict = false }, { name = "1.3.2.1 strict gate", strict = true } }) do
  local s = shape.strict
  local n = shape.name
  T.eq(n .. ": active -> true", R.isAnimalActivelySick(animal({ ACTIVE() }, { strict = s })), true)
  T.eq(n .. ": cured only -> nil", R.isAnimalActivelySick(animal({ CURED() }, { strict = s })), nil)
  T.eq(n .. ": carrier only -> nil", R.isAnimalActivelySick(animal({ CARRIER() }, { strict = s })), nil)
  T.eq(n .. ": cured + carrier -> nil", R.isAnimalActivelySick(animal({ CURED(), CARRIER() }, { strict = s })), nil)
  T.eq(n .. ": carrier + active (mixed) -> true", R.isAnimalActivelySick(animal({ CARRIER(), ACTIVE() }, { strict = s })), true)
  T.eq(n .. ": active + cured (mixed, active first) -> true", R.isAnimalActivelySick(animal({ ACTIVE(), CURED() }, { strict = s })), true)
  T.eq(n .. ": cured + carrier + active -> true", R.isAnimalActivelySick(animal({ CURED(), CARRIER(), ACTIVE() }, { strict = s })), true)
  T.eq(n .. ": healthy (no records) -> nil", R.isAnimalActivelySick(animal({}, { strict = s })), nil)
  T.eq(n .. ": diseases disabled with an active record -> nil", R.isAnimalActivelySick(animal({ ACTIVE() }, { strict = s, enabled = false })), nil)
  T.eq(n .. ": malformed only -> nil", R.isAnimalActivelySick(animal({ { cured = nil, isCarrier = nil } }, { strict = s })), nil)
  T.eq(n .. ": malformed + active -> true", R.isAnimalActivelySick(animal({ { cured = "x" }, ACTIVE() }, { strict = s })), true)
end

-- ── the gate is a gate, never the verdict ────────────────
T.eq("gate true but records table missing -> nil", R.isAnimalActivelySick(animal(nil, { gateReturns = true })), nil)
T.eq("gate true but records not a table -> nil", R.isAnimalActivelySick(animal("nope", { gateReturns = true })), nil)
T.eq("gate true, only cured rows (1.2.6.0 over-broad case) -> nil", R.isAnimalActivelySick(animal({ CURED(), CURED() }, { gateReturns = true })), nil)
T.eq("gate false with an active record -> nil (gate refused)", R.isAnimalActivelySick(animal({ ACTIVE() }, { gateReturns = false })), nil)
T.eq("gate nil (1.2.6.0 raw falsy diseasesEnabled) -> nil", R.isAnimalActivelySick(animal({ ACTIVE() }, { gateNil = true })), nil)
T.eq("gate truthy non-boolean (1) -> nil, strict true required", R.isAnimalActivelySick(animal({ ACTIVE() }, { gateReturns = 1 })), nil)
T.eq("gate truthy non-boolean ('true') -> nil", R.isAnimalActivelySick(animal({ ACTIVE() }, { gateReturns = "true" })), nil)

-- ── provider absent / unavailable shapes ─────────────────
T.eq("provider absent: animal without getter -> nil", R.isAnimalActivelySick(animal({ ACTIVE() }, { noGetter = true })), nil)
T.eq("gate throws -> nil", R.isAnimalActivelySick(animal({ ACTIVE() }, { gateThrows = true })), nil)
T.eq("animal nil -> nil", R.isAnimalActivelySick(nil), nil)
T.eq("animal not a table -> nil", R.isAnimalActivelySick(42), nil)
do
  -- a record walk that throws (metatable __index raising) is contained to nil
  local bad = setmetatable({}, { __index = function() error("walk boom") end })
  local a = { diseases = { bad }, getHasAnyDisease = function() return true end }
  T.eq("record walk throws -> nil", R.isAnimalActivelySick(a), nil)
end

-- ── isBarnActivelySick: per-animal containment ───────────
T.eq("barn: healthy herd -> nil", R.isBarnActivelySick(barn({ animal({}), animal({ CURED() }) })), nil)
T.eq("barn: one sick animal -> true", R.isBarnActivelySick(barn({ animal({}), animal({ ACTIVE() }) })), true)
T.eq("barn: throwing animal then sick animal -> true (containment)",
     R.isBarnActivelySick(barn({ animal({ ACTIVE() }, { gateThrows = true }), animal({ ACTIVE() }) })), true)
T.eq("barn: walk-throwing animal then sick animal -> true (containment)",
     R.isBarnActivelySick(barn({
       { diseases = { setmetatable({}, { __index = function() error("x") end }) }, getHasAnyDisease = function() return true end },
       animal({ ACTIVE() }),
     })), true)
T.eq("barn: an animal whose field read raises, then a sick animal -> true (containment)",
     R.isBarnActivelySick(barn({ setmetatable({}, { __index = function() error("field boom") end }), animal({ ACTIVE() }) })), true)
T.eq("barn: only sick animal throws -> nil (accepted limit)",
     R.isBarnActivelySick(barn({ animal({}), animal({ ACTIVE() }, { gateThrows = true }) })), nil)
T.eq("barn: non-table entries in the list are skipped", R.isBarnActivelySick(barn({ "junk", 7, animal({ ACTIVE() }) })), true)
T.eq("barn: empty list -> nil", R.isBarnActivelySick(barn({})), nil)
T.eq("barn: list read throws -> nil", R.isBarnActivelySick(barn({ animal({ ACTIVE() }) }, { listThrows = true })), nil)
T.eq("barn: getAnimals returns non-table -> nil", R.isBarnActivelySick({ spec_husbandryAnimals = { clusterSystem = { getAnimals = function() return 5 end } } }), nil)
T.eq("barn: no cluster system -> nil", R.isBarnActivelySick({ spec_husbandryAnimals = {} }), nil)
T.eq("barn: no husbandry spec -> nil", R.isBarnActivelySick({}), nil)
T.eq("barn: nil placeable -> nil", R.isBarnActivelySick(nil), nil)
T.eq("barn: return is a boolean, never a disease name", type(R.isBarnActivelySick(barn({ animal({ ACTIVE() }) }))), "boolean")

-- ── the dog's scan through the real DogEarlyWarning ──────
local shown
local function mission(placeables, opts)
  opts = opts or {}
  shown = {}
  local dh = { getOwnerFarmId = function() return opts.dogFarm or 1 end }
  g_currentMission = {
    doghouses = opts.noDog and {} or { [dh] = true },
    placeableSystem = { placeables = placeables },
    fieldManager = { getFields = function() return opts.fields or {} end },
    hud = { showBlinkingWarning = function(_self, msg, ms) shown[#shown + 1] = { msg = msg, ms = ms } end },
  }
  g_farmlandManager = opts.farmland
  g_i18n = nil
end
local function scanFarm(dog, farmId)
  dog:scan(farmId or 1)
  return dog:getWarnings(farmId or 1)
end
local function keysOf(dog, farmId)
  local out = {}
  for k in pairs(dog.notifiedFields[farmId or 1] or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

do
  mission({ barn({ animal({ ACTIVE() }) }, { id = "B7" }) })
  local dog = DogEarlyWarning.new({})
  local w = scanFarm(dog)
  T.eq("dog: sick barn is flagged once", #w, 1)
  T.eq("dog: flagged type is livestock", w[1].type, "livestock")
  T.eq("dog: flagged id is the placeable unique id", w[1].fieldId, "B7")
  T.eq("dog: one HUD warning", #shown, 1)
  T.eq("dog: barn sentence is the existing fallback with the id", shown[1].msg, "Your dog senses something wrong at Barn B7.")
  T.eq("dog: HUD duration unchanged", shown[1].ms, 5000)
  T.eq("dog: dedupe key shape unchanged", keysOf(dog)[1], "B7_livestock")
end

do
  mission({ barn({ animal({ CURED() }), animal({ CARRIER() }) }) })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: cured and carrier only -> no warning", #scanFarm(dog), 0)
  T.eq("dog: nothing shown", #shown, 0)
end

do
  mission({ barn({ animal({ ACTIVE() }, { noGetter = true }) }) })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: provider absent -> no warning", #scanFarm(dog), 0)
end

do
  mission({ barn({ animal({ ACTIVE() }, { enabled = false }) }) })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: diseases disabled -> no warning", #scanFarm(dog), 0)
end

do
  -- same-farm filter: the sick barn belongs to farm 2
  mission({ barn({ animal({ ACTIVE() }) }, { farm = 2, id = "B2" }) })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: other farm's sick barn ignored", #scanFarm(dog, 1), 0)
end

do
  -- dog gate: no doghouse on the farm
  mission({ barn({ animal({ ACTIVE() }) }) }, { noDog = true })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: no doghouse -> no warning", #scanFarm(dog), 0)
  T.eq("dog: no doghouse -> nothing shown", #shown, 0)
end

do
  -- per-barn containment: a barn whose owner lookup throws, then a sick barn
  local badBarn = barn({ animal({ ACTIVE() }) }, { id = "BAD" })
  badBarn.getOwnerFarmId = function() error("owner boom") end
  local badId = barn({ animal({ ACTIVE() }) }, { idThrows = true })
  mission({ badBarn, badId, barn({ animal({ ACTIVE() }) }, { id = "GOOD" }) })
  local dog = DogEarlyWarning.new({})
  local w = scanFarm(dog)
  T.eq("dog: bad barns do not silence the farm", #w, 2)
  T.eq("dog: barn with throwing id falls back to 'barn'", w[1].fieldId, "barn")
  T.eq("dog: later good barn still flagged", w[2].fieldId, "GOOD")
end

do
  -- placeable list unavailable: quiet, no throw
  g_currentMission = { doghouses = { [{ getOwnerFarmId = function() return 1 end }] = true },
                       fieldManager = { getFields = function() return {} end },
                       hud = { showBlinkingWarning = function() end } }
  local dog = DogEarlyWarning.new({})
  local ok = pcall(dog.scan, dog, 1)
  T.eq("dog: no placeable system -> scan does not throw", ok, true)
  T.eq("dog: no placeable system -> no warning", #dog:getWarnings(1), 0)
end

do
  -- non-husbandry placeables are skipped, husbandry without cluster is quiet
  mission({ {}, { spec_husbandryAnimals = {} }, { getOwnerFarmId = function() return 1 end } })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: non-barn placeables -> no warning", #scanFarm(dog), 0)
end

do
  -- dedupe and clearing across scans: warn once while sick, clear when healthy, warn again after
  local herd = { animal({ ACTIVE() }) }
  local b = barn(herd, { id = "B9" })
  mission({ b })
  local dog = DogEarlyWarning.new({})
  scanFarm(dog); scanFarm(dog)
  T.eq("dog: two sick scans show one warning", #shown, 1)
  herd[1].diseases[1].cured = true
  scanFarm(dog)
  T.eq("dog: cured herd clears the warning", #dog:getWarnings(1), 0)
  T.eq("dog: cured herd clears the dedupe key", #keysOf(dog), 0)
  herd[1].diseases[1].cured = false
  scanFarm(dog)
  T.eq("dog: re-infection warns again", #shown, 2)
end

do
  -- crop half unchanged: a field with an active disease still warns beside a healthy barn
  local fields = { { farmland = { id = 5 } } }
  mission({ barn({ animal({}) }) }, { fields = fields, farmland = { getFarmlandOwner = function() return 1 end } })
  local dog = DogEarlyWarning.new({ getFieldInfo = function() return { activeDisease = "late_blight" } end })
  local w = scanFarm(dog)
  T.eq("dog: crop warning still fires", #w, 1)
  T.eq("dog: crop type unchanged", w[1].type, "crop")
  T.eq("dog: crop sentence unchanged", shown[1].msg, "Your dog senses something wrong with Field #5.")
end

do
  -- reader missing entirely (defensive): scan stays quiet on barns, crop half unaffected
  local saved = LivestockWarningReader
  LivestockWarningReader = nil
  mission({ barn({ animal({ ACTIVE() }) }) })
  local dog = DogEarlyWarning.new({})
  T.eq("dog: reader absent -> no barn warning, no throw", #scanFarm(dog), 0)
  LivestockWarningReader = saved
end

-- ── Realistic Livestock 1.4.0.0: the record-state delta ──
-- Brief v1.0 on amendment v0.9. A 1.4 record carries a string state and
-- isCarrier, never cured (Disease.lua constructor, XML load and save, and
-- streams at tag v1.4.0.0). The rows above stay as the legacy shape's bar.
local function srec(state, carrier) return { type = "x", state = state, isCarrier = carrier == true } end
local INFECTIOUS = function() return srec("INFECTIOUS") end
local EXPOSED    = function() return srec("EXPOSED") end
local RECOVERED  = function() return srec("RECOVERED") end
local DEAD       = function() return srec("DEAD") end

T.eq("v1.4 record: INFECTIOUS counts", R.isActiveRecord(INFECTIOUS()), true)
T.eq("v1.4 record: EXPOSED (the hidden phase) does not count", R.isActiveRecord(EXPOSED()), false)
T.eq("v1.4 record: RECOVERED does not count", R.isActiveRecord(RECOVERED()), false)
T.eq("v1.4 record: DEAD does not count", R.isActiveRecord(DEAD()), false)
T.eq("v1.4 record: SUSCEPTIBLE (in the enum, never held) does not count", R.isActiveRecord(srec("SUSCEPTIBLE")), false)
T.eq("v1.4 record: unknown state SICK does not count", R.isActiveRecord(srec("SICK")), false)
T.eq("v1.4 record: lower-case infectious does not count", R.isActiveRecord(srec("infectious")), false)
T.eq("v1.4 record: numeric state does not count", R.isActiveRecord({ state = 1, isCarrier = false }), false)
T.eq("v1.4 record: boolean state does not count", R.isActiveRecord({ state = true, isCarrier = false }), false)
T.eq("v1.4 record: table state does not count", R.isActiveRecord({ state = {}, isCarrier = false }), false)
T.eq("v1.4 record: state false with both legacy flags false does not count (present, not a string, no fall-through)",
     R.isActiveRecord({ state = false, cured = false, isCarrier = false }), false)
T.eq("v1.4 record: INFECTIOUS carrier counts, as the provider's own rule does", R.isActiveRecord(srec("INFECTIOUS", true)), true)
T.eq("v1.4 record: state wins, EXPOSED with both legacy flags false does not count",
     R.isActiveRecord({ state = "EXPOSED", cured = false, isCarrier = false }), false)
T.eq("v1.4 record: state wins, RECOVERED with both legacy flags false does not count",
     R.isActiveRecord({ state = "RECOVERED", cured = false, isCarrier = false }), false)
T.eq("v1.4 record: state wins, unknown state with both legacy flags false does not count",
     R.isActiveRecord({ state = "SICK", cured = false, isCarrier = false }), false)
T.eq("v1.4 record: state wins, INFECTIOUS with cured = true still counts",
     R.isActiveRecord({ state = "INFECTIOUS", cured = true, isCarrier = false }), true)
T.eq("v1.4 record: nil state, no cured (a client's out-of-range ordinal) does not count",
     R.isActiveRecord({ state = nil, isCarrier = false }), false)

-- The provider's own 1.4.0.0 gate, Animal:getHasAnyDisease at
-- RealisticLivestock_Animal.lua:1942-1954 (tag v1.4.0.0, e914c2f8), line for
-- line: false with no manager, diseases off or no diseases table; otherwise
-- true when any record passes RLDiseaseStatus.isDiseased (RLDiseaseStatus.lua
-- :72-74, state == STATE.INFECTIOUS; STATE values equal their keys,
-- RLDiseaseRecord.lua:39-45). Not a stub that returns true.
local STATE14 = { SUSCEPTIBLE = "SUSCEPTIBLE", EXPOSED = "EXPOSED", INFECTIOUS = "INFECTIOUS", RECOVERED = "RECOVERED", DEAD = "DEAD" }
local function isDiseased14(record) return record.state == STATE14.INFECTIOUS end
local function gate14(self)
  if g_diseaseManager == nil or not g_diseaseManager.diseasesEnabled or self.diseases == nil then
    return false
  end
  for _, disease in ipairs(self.diseases) do
    if isDiseased14(disease) then
      return true
    end
  end
  return false
end
local function animal14(records, opts)
  opts = opts or {}
  local a = { diseases = records }
  if opts.noGetter then return a end
  if opts.gateThrows then
    a.getHasAnyDisease = function() error("provider boom") end
  else
    a.getHasAnyDisease = gate14
  end
  return a
end

local savedDM, savedFM = g_diseaseManager, g_farmManager
g_diseaseManager = { diseasesEnabled = true }
T.eq("v1.4 animal: INFECTIOUS -> true", R.isAnimalActivelySick(animal14({ INFECTIOUS() })), true)
T.eq("v1.4 animal: EXPOSED only -> nil", R.isAnimalActivelySick(animal14({ EXPOSED() })), nil)
T.eq("v1.4 animal: RECOVERED only -> nil", R.isAnimalActivelySick(animal14({ RECOVERED() })), nil)
T.eq("v1.4 animal: DEAD only -> nil", R.isAnimalActivelySick(animal14({ DEAD() })), nil)
T.eq("v1.4 animal: EXPOSED + INFECTIOUS (mixed) -> true", R.isAnimalActivelySick(animal14({ EXPOSED(), INFECTIOUS() })), true)
T.eq("v1.4 animal: RECOVERED + DEAD + INFECTIOUS (mixed) -> true", R.isAnimalActivelySick(animal14({ RECOVERED(), DEAD(), INFECTIOUS() })), true)
T.eq("v1.4 animal: INFECTIOUS carrier -> true", R.isAnimalActivelySick(animal14({ srec("INFECTIOUS", true) })), true)
T.eq("v1.4 animal: EXPOSED carrier (a genetic carrier for life) -> nil", R.isAnimalActivelySick(animal14({ srec("EXPOSED", true) })), nil)
T.eq("v1.4 animal: unknown state SICK only -> nil", R.isAnimalActivelySick(animal14({ srec("SICK") })), nil)
T.eq("v1.4 animal: unknown state SICK + INFECTIOUS -> true", R.isAnimalActivelySick(animal14({ srec("SICK"), INFECTIOUS() })), true)
T.eq("v1.4 animal: healthy (no records) -> nil", R.isAnimalActivelySick(animal14({})), nil)
T.eq("v1.4 animal: diseases table nil -> nil", R.isAnimalActivelySick(animal14(nil)), nil)
T.eq("v1.4 animal: getter absent -> nil", R.isAnimalActivelySick(animal14({ INFECTIOUS() }, { noGetter = true })), nil)
T.eq("v1.4 animal: getter throws -> nil", R.isAnimalActivelySick(animal14({ INFECTIOUS() }, { gateThrows = true })), nil)
g_diseaseManager.diseasesEnabled = false
T.eq("v1.4 animal: diseases disabled with INFECTIOUS -> nil", R.isAnimalActivelySick(animal14({ INFECTIOUS() })), nil)
g_diseaseManager = nil
T.eq("v1.4 animal: no disease manager with INFECTIOUS -> nil", R.isAnimalActivelySick(animal14({ INFECTIOUS() })), nil)
g_diseaseManager = { diseasesEnabled = true }
T.eq("v1.4 barn: EXPOSED and RECOVERED animals only -> nil",
     R.isBarnActivelySick(barn({ animal14({ EXPOSED() }), animal14({ RECOVERED() }) })), nil)
T.eq("v1.4 barn: one INFECTIOUS animal among EXPOSED and RECOVERED -> true",
     R.isBarnActivelySick(barn({ animal14({ EXPOSED() }), animal14({ RECOVERED(), INFECTIOUS() }), animal14({ EXPOSED() }) })), true)
T.eq("v1.4 barn: throwing getter then INFECTIOUS animal -> true (containment)",
     R.isBarnActivelySick(barn({ animal14({ INFECTIOUS() }, { gateThrows = true }), animal14({ INFECTIOUS() }) })), true)
g_diseaseManager.diseasesEnabled = false
T.eq("v1.4 barn: diseases disabled -> nil", R.isBarnActivelySick(barn({ animal14({ INFECTIOUS() }) })), nil)

do
  -- Entry-point bar (R-18): the dog's production call, dogWarning:update(dt)
  -- from FSBaseMission.update (src/main.lua:972), reaching the farm through
  -- g_farmManager:getFarms() as update does; scan is never called directly.
  -- The barn is a fixture: the placeable registry is the engine's and the
  -- animal list is the provider's, so no offline bench can build them. The
  -- gate is the provider's own 1.4 rule above.
  g_diseaseManager = { diseasesEnabled = true }
  local sick = INFECTIOUS()
  mission({ barn({ animal14({ EXPOSED() }), animal14({ RECOVERED() }), animal14({ EXPOSED(), sick }) }, { id = "B14" }) })
  g_farmManager = { getFarms = function() return { { farmId = 1 } } end }
  local dog = DogEarlyWarning.new({})
  dog:update(59999)
  T.eq("v1.4 entry: under the 60 s cadence nothing is read", #shown, 0)
  dog:update(1)
  T.eq("v1.4 entry: one HUD warning from dog:update", #shown, 1)
  T.eq("v1.4 entry: the barn fallback sentence with the placeable's id", shown[1] and shown[1].msg, "Your dog senses something wrong at Barn B14.")
  T.eq("v1.4 entry: 5000 ms", shown[1] and shown[1].ms, 5000)
  T.eq("v1.4 entry: dedupe key", table.concat(keysOf(dog), ","), "B14_livestock")
  dog:update(60000)
  T.eq("v1.4 entry: unchanged barn, no second warning", #shown, 1)
  sick.state = "RECOVERED"
  dog:update(60000)
  T.eq("v1.4 entry: recovered, no warning", #shown, 1)
  T.eq("v1.4 entry: recovered clears the key", #keysOf(dog), 0)
  sick.state = "INFECTIOUS"
  g_diseaseManager.diseasesEnabled = false
  dog:update(60000)
  T.eq("v1.4 entry: diseases disabled, no warning", #shown, 1)
  g_diseaseManager.diseasesEnabled = true
  dog:update(60000)
  T.eq("v1.4 entry: enabled again, the dog warns again", #shown, 2)
end
g_diseaseManager, g_farmManager = savedDM, savedFM

-- ── no new player-facing string ──────────────────────────
T.eq("strings: barn fallback unchanged", DogEarlyWarning.BARN_WARNING_FALLBACK, "Your dog senses something wrong at Barn %s.")
T.eq("strings: field fallback unchanged", DogEarlyWarning.FIELD_WARNING_FALLBACK, "Your dog senses something wrong with Field #%s.")
T.eq("strings: barn key unchanged", DogEarlyWarning.BARN_WARNING_KEY, "sf_dog_barn_warning")
T.eq("cadence unchanged", DogEarlyWarning.CADENCE_MS, 60000)

g_currentMission = nil
g_farmlandManager = nil
g_i18n = nil
