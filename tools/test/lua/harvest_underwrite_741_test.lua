-- harvest_underwrite_741_test.lua - RSF-741 v1.13 items 1, 2 and 11 to 17: the harvest
-- underwrite corrects ONLY the delivered-grain component of a harvest contract's completion,
-- by the share SoilFertilizer's own yield reduction took.
--
-- The previous version of this file handed a bare scalar called `vanilla` to correct() and
-- never ran the native blend, so it encoded the very assumption RSF-741 found false: that
-- getCompletion is delivery progress. Here the completion is computed by a HarvestMission
-- model whose getCompletion is the decompiled body (missions/field/HarvestMission.lua:292-
-- 300: sell = min(deposited / expected / 0.93, 1); harvest = min(fieldCompletion / 0.98, 1);
-- blend by harvestCompletionFactor, 0.8 grain, 0.5 onion), and the underwrite reaches it
-- through its REAL install, the class wrapper that calls the original first.
--
-- LAYER: this file is the completion-math layer. The provenance record it reads is placed
-- on the SF field by hand, with its totals chosen to express an applied ratio, and
-- readiness is set by hand. The entry-point bar that ARMS the record through the mission
-- lifecycle and FILLS it through the real cutter and Combine hooks is
-- RSF-741-underwrite_entry_point_test.lua.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/HarvestContractUnderwrite.lua

local UW = HarvestContractUnderwrite
local FARMLAND, FRUIT, UID = 7, 14, "mission_7a"

-- ── the base-game class, as decompiled ──────────────────────────────────────────
AbstractMission = { SUCCESS_FACTOR = 0.98 }
HarvestMission = { NAME = "harvestMission", SUCCESS_FACTOR = 0.93 }
local HarvestMission_mt = { __index = HarvestMission }
function HarvestMission:getMissionTypeName() return HarvestMission.NAME end
function HarvestMission:getUniqueId() return self.uniqueId end
function HarvestMission:getIsRunning() return self.status == 3 end
function HarvestMission:getFieldCompletion() return self.fieldCompletion end
function HarvestMission:finishedPreparing() self.status = 3 end
-- HarvestMission.lua:292-300, verbatim in shape.
function HarvestMission:getCompletion()
  local sellCompletion = 1
  if self.expectedLiters > 0 then
    sellCompletion = math.min(self.depositedLiters / self.expectedLiters / HarvestMission.SUCCESS_FACTOR, 1)
  end
  local harvestCompletion = math.min(self:getFieldCompletion() / AbstractMission.SUCCESS_FACTOR, 1)
  local w = self.harvestCompletionFactor
  return math.min(1, w * harvestCompletion + (1 - w) * sellCompletion)
end
local nativeGetCompletion = HarvestMission.getCompletion

local function newMission(opts)
  opts = opts or {}
  return setmetatable({
    uniqueId = opts.uid or UID, fruitTypeIndex = opts.fruit or FRUIT, farmId = 1, status = 3,
    field = { farmland = { id = opts.farmland or FARMLAND }, getId = function() return 42 end },
    expectedLiters = opts.expected or 10000, depositedLiters = opts.deposited or 0,
    fieldCompletion = opts.cut or 0, harvestCompletionFactor = opts.hcf or 0.8,
  }, HarvestMission_mt)
end

-- ── the SF side: a field record carrying the provenance, readiness on ─────────────
local computeCalls = 0
local function soilWith(record)
  local fd = { [FARMLAND] = { harvestUnderwriteProvenance = record } }
  g_SoilFertilityManager = { soilSystem = { fieldData = fd,
    computeYieldModifier = function() computeCalls = computeCalls + 1; return 0.5 end } }
  return fd
end
local function record(ratio, opts)
  opts = opts or {}
  local pre = opts.pre or 1000
  return { missionUniqueId = opts.uid or UID, fruitTypeIndex = opts.fruit or FRUIT, armed = opts.armed ~= false,
           captureFault = opts.fault == true, preTotal = pre, postTotal = opts.post or pre * ratio, cutCount = 3 }
end

g_server = {}
g_localPlayer = nil
SoilConstants.HARVEST_UNDERWRITE.ENABLED = true
local notes = 0
g_currentMission = { addIngameNotification = function() notes = notes + 1 end }

-- The real install: the class wrapper over getCompletion, original first.
local hooks = {}
local installed = UW.install({ register = function(_, target, key, original, name) hooks[#hooks + 1] = { target = target, key = key, original = original } end })
UW.setCaptureReady(true)

-- ==============================================================================
-- A. the install (items 1 and 2)
-- ==============================================================================
T.ok("A1 install succeeded on a class that has getCompletion", installed == true)
T.ok("A2 the class method is now the underwrite's wrapper", HarvestMission.getCompletion ~= nativeGetCompletion)
do
  soilWith(record(0.5))
  local m = newMission({ cut = 0.49, deposited = 0 })
  T.near("A3 the wrapper calls the native blend first (half cut, no delivery)", m:getCompletion(), 0.8 * (0.49 / 0.98), 1e-12)
end

-- ==============================================================================
-- B. zero delivery earns zero credit, however much is cut (the reported defect)
-- ==============================================================================
do
  soilWith(record(0.5))
  local half = newMission({ cut = 0.49, deposited = 0 })
  T.near("B1 half cut, nothing delivered, ratio 0.5: exactly vanilla (0.40), not 0.80", half:getCompletion(), 0.4, 1e-12)
  local full = newMission({ cut = 0.98, deposited = 0 })
  T.near("B2 fully cut, nothing delivered: exactly vanilla 0.80", full:getCompletion(), 0.8, 1e-12)
  T.ok("B3 and it cannot finish (below the 0.995 line)", full:getCompletion() < 0.995)
  local onion = newMission({ cut = 0.98, deposited = 0, hcf = 0.5 })
  T.near("B4 onion weights (0.5/0.5), fully cut, nothing delivered: vanilla 0.50", onion:getCompletion(), 0.5, 1e-12)
end

-- ==============================================================================
-- C. partial delivery changes only the native delivery-weighted portion (items 12-14)
-- ==============================================================================
do
  soilWith(record(0.5))
  -- deposited so that sellVanilla = 0.25: 0.25 * 10000 * 0.93
  local m = newMission({ cut = 0.49, deposited = 0.25 * 10000 * 0.93 })
  local vanilla = 0.8 * 0.5 + 0.2 * 0.25
  T.near("C1 vanilla is the native blend", nativeGetCompletion(m), vanilla, 1e-12)
  -- sellCorrected = min(0.25 / 0.5, 1) = 0.5; corrected = vanilla + 0.2 * (0.5 - 0.25)
  T.near("C2 corrected adds only 0.2 * (0.50 - 0.25) = 0.05", m:getCompletion(), vanilla + 0.05, 1e-12)
  local onion = newMission({ cut = 0.49, deposited = 0.25 * 10000 * 0.93, hcf = 0.5 })
  local vOnion = 0.5 * 0.5 + 0.5 * 0.25
  T.near("C3 onion: the delivery weight is 0.5, so it adds 0.5 * 0.25", onion:getCompletion(), vOnion + 0.125, 1e-12)
  -- heavy delivery on a half-cut field: the corrected delivery component is capped at 1
  local heavy = newMission({ cut = 0.49, deposited = 0.9 * 10000 * 0.93 })
  local vHeavy = 0.8 * 0.5 + 0.2 * 0.9
  T.near("C4 sellCorrected is capped at 1: adds 0.2 * (1.0 - 0.9), never 0.2 * (1.8 - 0.9)", heavy:getCompletion(), vHeavy + 0.02, 1e-12)
end

-- ==============================================================================
-- D. an honest full harvest on degraded ground reaches 1.0 (grain and onion)
-- ==============================================================================
do
  for _, ratio in ipairs({ 0.32, 0.5, 0.77 }) do
    soilWith(record(ratio))
    -- A degraded field delivers ratio x what full health would: deposited = ratio * expected * 0.93.
    local grain = newMission({ cut = 0.98, deposited = ratio * 10000 * 0.93 })
    T.near("D1 grain, ratio " .. ratio .. ": fully cut and delivered reaches 1.0", grain:getCompletion(), 1.0, 1e-9)
    local onion = newMission({ cut = 0.98, deposited = ratio * 10000 * 0.93, hcf = 0.5 })
    T.near("D2 onion, ratio " .. ratio .. ": fully cut and delivered reaches 1.0", onion:getCompletion(), 1.0, 1e-9)
    local short = newMission({ cut = 0.98, deposited = 0.9 * ratio * 10000 * 0.93 })
    T.ok("D3 ratio " .. ratio .. ": delivering 90% of what the ground gave stays below the line", short:getCompletion() < 0.995)
  end
end

-- ==============================================================================
-- E. bounded and monotonic (item 15)
-- ==============================================================================
do
  local bad, nonMono = 0, 0
  for r = 1, 19 do
    soilWith(record(r / 20))
    for cut = 0, 10 do
      local prev = -1
      for d = 0, 20 do
        local m = newMission({ cut = cut * 0.098, deposited = d * 500 })
        local v, c = nativeGetCompletion(m), m:getCompletion()
        if not (c >= v - 1e-12 and c <= 1.0 + 1e-12) then bad = bad + 1 end
        if c < prev - 1e-12 then nonMono = nonMono + 1 end
        prev = c
      end
    end
  end
  T.eq("E1 corrected is always within [vanilla, 1.0]", bad, 0)
  T.eq("E2 corrected never falls as delivered litres rise", nonMono, 0)
end

-- ==============================================================================
-- F. every missing, invalid or unready input is vanilla passthrough (items 2, 11, 17)
-- ==============================================================================
do
  local function passes(label, rec, opts, setup, teardown)
    soilWith(rec)
    local m = newMission(opts or { cut = 0.98, deposited = 0.5 * 10000 * 0.93 })
    -- vanilla first: one case removes the native constant the native formula itself needs
    local v = nativeGetCompletion(m)
    if setup then setup(m) end
    local c = UW.correct(m, v)
    if teardown then teardown(m) end
    T.near("F " .. label .. " is vanilla", c, v, 1e-15)
  end
  passes("ratio 1.0 (SF took nothing)", record(1.0))
  passes("ratio above 1", record(1.2))
  passes("no record on the field", nil)
  passes("a faulted record", record(0.5, { fault = true }))
  passes("an unarmed record", record(0.5, { armed = false }))
  passes("a record for another mission (stale uniqueId)", record(0.5, { uid = "mission_old" }))
  passes("a record for another fruit", record(0.5, { fruit = 99 }))
  passes("a record with no material yet (pre 0)", record(0.5, { pre = 0, post = 0 }))
  passes("a record with non-finite totals", record(0.5, { pre = 0 / 0 }))
  passes("expected litres 0", record(0.5), { cut = 0.98, deposited = 100, expected = 0 })
  passes("expected litres not finite", record(0.5), { cut = 0.98, deposited = 100, expected = math.huge })
  passes("delivery weight out of range", record(0.5), { cut = 0.98, deposited = 4650, hcf = 1.5 })
  passes("provenance not ready", record(0.5), nil, function() UW.setCaptureReady(false) end, function() UW.setCaptureReady(true) end)
  passes("underwrite disabled", record(0.5), nil,
    function() SoilConstants.HARVEST_UNDERWRITE.ENABLED = false end, function() SoilConstants.HARVEST_UNDERWRITE.ENABLED = true end)
  passes("a pure client", record(0.5), nil, function() g_server = nil end, function() g_server = {} end)
  local savedSF = HarvestMission.SUCCESS_FACTOR
  passes("native success factor missing", record(0.5), nil,
    function() HarvestMission.SUCCESS_FACTOR = nil end, function() HarvestMission.SUCCESS_FACTOR = savedSF end)
  passes("no farmland on the field", record(0.5), nil, function(m) m.field.farmland = nil end)
  -- the depositedLiters guard: a negative or missing value is refused, not treated as 0
  soilWith(record(0.5))
  local neg = newMission({ cut = 0.98, deposited = 0 }); neg.depositedLiters = -5
  T.eq("F negative deposited litres is vanilla", UW.correct(neg, 0.5), 0.5)
  T.eq("F a non-number completion is returned as-is", UW.correct(neg, "x"), "x")
end

-- ==============================================================================
-- G. the yield modifier is never read (item 11)
-- ==============================================================================
do
  computeCalls = 0
  soilWith(record(0.5))
  newMission({ cut = 0.98, deposited = 4650 }):getCompletion()
  T.eq("G1 correct() never calls computeYieldModifier", computeCalls, 0)
end

-- ==============================================================================
-- H. the notification is one-shot and only when THIS correction crosses the line (item 16)
-- ==============================================================================
do
  soilWith(record(0.5))
  g_localPlayer = { farmId = 1 }
  FSBaseMission = FSBaseMission or { INGAME_NOTIFICATION_OK = 1 }
  notes = 0
  local m = newMission({ cut = 0.98, deposited = 0.5 * 10000 * 0.93 })
  m:getCompletion(); m:getCompletion()
  T.eq("H1 crossing the line notifies once, however often it is polled", notes, 1)
  notes = 0
  local already = newMission({ cut = 0.98, deposited = 10000 * 0.93 })   -- vanilla already 1.0
  already:getCompletion()
  T.eq("H2 a contract vanilla already completes notifies nothing", notes, 0)
  notes = 0
  local below = newMission({ cut = 0.98, deposited = 0.4 * 10000 * 0.93 })
  below:getCompletion()
  T.eq("H3 a correction that stays below the line notifies nothing", notes, 0)
  g_localPlayer = nil
end

-- restore the class for any file after this one
HarvestMission.getCompletion = nativeGetCompletion
UW.setCaptureReady(false)
UW._wrapper = nil
g_SoilFertilityManager = nil
