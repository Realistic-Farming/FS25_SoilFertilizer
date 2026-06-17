-- fieldsentry_test.lua — FieldSentry Phase 1 backend gate (#651).
-- The module itself is dependency-free; the last block also loads the soil system to
-- prove the freeze gate in _processOneDailyField actually skips a blacklisted field.
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/FieldSentry.lua, src/SoilFertilitySystem.lua

local BL = FieldSentry_Core.BLACKLIST

-- ── status API ─────────────────────────────────────────────
do
  FieldSentry_API.reset()
  local disabled, reason = FieldSentry_API.isFieldSimDisabled(99)
  T.ok("unknown field is not disabled", disabled == false)
  T.eq("unknown field reason is NONE", reason, BL.NONE)
end

do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(1, true)
  local disabled, reason = FieldSentry_API.isFieldSimDisabled(1)
  T.ok("setFieldManual(true) disables the field", disabled == true)
  T.eq("manual blacklist reason is MANUAL", reason, BL.MANUAL)

  FieldSentry_API.setFieldManual(1, false)
  T.ok("setFieldManual(false) re-enables the field",
       FieldSentry_API.isFieldSimDisabled(1) == false)
end

do
  FieldSentry_API.reset()
  T.ok("toggleFieldManual: first toggle sleeps", FieldSentry_API.toggleFieldManual(2) == true)
  T.ok("toggleFieldManual: second toggle wakes", FieldSentry_API.toggleFieldManual(2) == false)
end

do
  FieldSentry_API.reset()
  T.ok("isFieldManual: false for unknown field", FieldSentry_API.isFieldManual(50) == false)
  FieldSentry_API.setFieldManual(50, true)
  T.ok("isFieldManual: true after blacklist", FieldSentry_API.isFieldManual(50) == true)
end

do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(3, true)
  local s = FieldSentry_API.getUIStatus(3)
  T.ok("getUIStatus: isSimulationDisabled true", s.isSimulationDisabled == true)
  T.eq("getUIStatus: reasonName maps the enum", s.reasonName, "manual")
  T.ok("getUIStatus: isMeadow defaults false", s.isMeadow == false)
end

do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(7, true)
  FieldSentry_API.setFieldManual(2, true)
  FieldSentry_API.setFieldManual(5, true)
  local list = FieldSentry_API.getManualBlacklist()
  T.eq("getManualBlacklist: count", #list, 3)
  T.ok("getManualBlacklist: sorted ascending", list[1] == 2 and list[2] == 5 and list[3] == 7)
  FieldSentry_API.reset()
  T.eq("reset clears the registry", #FieldSentry_API.getManualBlacklist(), 0)
end

-- ── hot path allocates nothing ─────────────────────────────
do
  FieldSentry_API.reset()
  local _, _, _, hints = FieldSentry_API.isFieldSimDisabled(123)
  T.ok("hot path returns a hints table (shared empty in Phase 1)", type(hints) == "table")
end

-- ── persistence round-trip (save → reset → load) ───────────
do
  FieldSentry_API.reset()
  FieldSentry_API.setFieldManual(4, true)
  FieldSentry_API.setFieldManual(11, true)

  local xml = {}  -- in-memory XML handle (see prelude mock)
  FieldSentry_API.saveToXMLFile(xml, "soilData.fieldSentry")

  FieldSentry_API.reset()
  T.eq("persistence: state cleared before load", #FieldSentry_API.getManualBlacklist(), 0)

  FieldSentry_API.loadFromXMLFile(xml, "soilData.fieldSentry")
  local list = FieldSentry_API.getManualBlacklist()
  T.eq("persistence: round-trip restores count", #list, 2)
  T.ok("persistence: round-trip restores the right ids", list[1] == 4 and list[2] == 11)
  T.ok("persistence: restored field reports disabled",
       FieldSentry_API.isFieldSimDisabled(11) == true)
end

-- ── freeze gate: blacklisted field is skipped by the daily sim ──
do
  FieldSentry_API.reset()
  local sys = setmetatable({
    fieldData         = {},
    settings          = { enabled = true, nutrientCycles = true },
    _dailyBatchDay    = 1,
    _dailyBatchSeason = 1,
  }, { __index = SoilFertilitySystem })

  -- A non-blacklisted field would have nutrientBuffer reset to {} immediately;
  -- a slept field early-returns before that, so the sentinel survives.
  local field = { nutrientBuffer = { sentinel = true }, pH = 6.5, nitrogen = 40 }
  sys.fieldData[1] = field

  FieldSentry_API.setFieldManual(1, true)
  sys:_processOneDailyField(1, field)
  T.ok("freeze gate: slept field's daily pass is skipped (sentinel survives)",
       field.nutrientBuffer.sentinel == true)
end
