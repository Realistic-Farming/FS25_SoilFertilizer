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

-- ── no new player-facing string ──────────────────────────
T.eq("strings: barn fallback unchanged", DogEarlyWarning.BARN_WARNING_FALLBACK, "Your dog senses something wrong at Barn %s.")
T.eq("strings: field fallback unchanged", DogEarlyWarning.FIELD_WARNING_FALLBACK, "Your dog senses something wrong with Field #%s.")
T.eq("strings: barn key unchanged", DogEarlyWarning.BARN_WARNING_KEY, "sf_dog_barn_warning")
T.eq("cadence unchanged", DogEarlyWarning.CADENCE_MS, 60000)

g_currentMission = nil
g_farmlandManager = nil
g_i18n = nil
