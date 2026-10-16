-- SF-1098-helperbuy_player_spec_test.lua
--
-- #1098: a sprayer holding a Soil product spends money and does NOT drain its
-- tank while helperBuyFertilizer is on.
--
-- WHAT THIS FILE PINS. The reported symptom is two effects at once - money
-- leaves AND the tank stays full - so every row here asserts BOTH, never one.
-- An earlier reading of mine claimed the F196 layer "charges on the drain, so
-- the tank empties"; that was wrong, and it was wrong because it stopped
-- before the branch's return. The billed branch does
--
--     return fillLevelDelta        -- WITHOUT calling predecessor
--
-- so FillUnit.addFillUnitFillLevel never applies the negative delta while
-- still reporting it as applied. Prose cannot be trusted on this; the rows
-- below drive the real wrapper and measure both effects.
--
-- WHAT IT DOES NOT CLAIM. Nothing here says the reporter's session reached
-- the state in group 5. That row constructs a stale-job state deliberately
-- and is labelled as constructed. The engine extract available to me is
-- 1.20.0.0 and the reporter ran 1.24.0.0.
--
--!load: tools/test/lua/SF-995-engine_model.lua, src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/DiseaseSystem.lua, src/utils/SoilUtils.lua, src/utils/SoilContextInput.lua, src/OrganicCertification.lua, src/config/SettingsSchema.lua, src/FieldSentry.lua, src/maps/SoilValueMaps.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

-- The repo's existing convention for these globals, as
-- MAINT-229-section_boom_world.lua declares them.
FillType = FillType or { UNKNOWN = 0 }
ToolType = ToolType or { UNDEFINED = 0 }
-- MoneyType matters more than it looks: the charge is inside a pcall, so
-- without this the addMoney call raises on a nil index and is swallowed
-- silently. The tank would still go unchanged, so the fixture would show
-- the symptom's tank half with no money half and read as 'no charge'.
MoneyType = MoneyType or { PURCHASE_FERTILIZER = 1 }
-- Utils.appendedFunction verbatim from the extract, Utils.lua:491-500.
-- installSprayerAreaHook composes with it, and the composer semantics
-- (original first, appended second, return value discarded) are what
-- the group 13 rows below run through.
Utils = Utils or {}
Utils.appendedFunction = Utils.appendedFunction or function(oldFunc, newFunc)
  if oldFunc ~= nil then
    return function(...)
      oldFunc(...)
      newFunc(...)
    end
  else
    return newFunc
  end
end

local CUSTOM_IDX   = 7301      -- a Soil custom product index
local PRICE        = 2.0       -- per litre
local FU_IDX       = 1
local LITERS       = 50        -- applied this call
local DELTA        = -LITERS   -- the drain the engine asks for

-- ── A FillUnit class whose predecessor really moves the tank ──
-- If the wrapper calls through, fillLevel drops. If it returns without
-- calling through, fillLevel does not move. That difference IS the bug.
local tank
local function newFillUnitClass()
  return {
    addFillUnitFillLevel = function(vehicle, farmId, fillUnitIndex,
                                    fillLevelDelta, fillTypeIndex, toolType,
                                    fillPositionData)
      tank = tank + fillLevelDelta
      return fillLevelDelta
    end,
  }
end

-- ── Money, recorded rather than eyeballed ──
local money, moneyCalls
local function resetMoney()
  money, moneyCalls = 0, 0
end

-- ── A sprayer whose product identity resolves through the real resolver ──
local function newVehicle(opts)
  opts = opts or {}
  local v = {
    id = 42,
    ownerFarmId = 1,
    getSprayerFillUnitIndex = function() return FU_IDX end,
    getFillUnitFillType = function(_, _) return CUSTOM_IDX end,
  }
  -- AI state. Each route is set only when the scenario asks for it, so a row
  -- can say exactly which flag made the predicate true.
  if opts.job then v.spec_aiJobVehicle = { job = {} } end
  if opts.cpModern then v.spec_cpAIWorker = { isActive = true } end
  if opts.cpLegacy then v.cp = { isActive = true } end
  v.getIsAIActive = function()
    -- Mirrors the engine: Vehicle:getIsAIActive recurses to the attacher and
    -- otherwise returns false; AIJobVehicle adds `or job ~= nil`.
    if opts.attacher ~= nil then return opts.attacher.getIsAIActive() end
    return (v.spec_aiJobVehicle ~= nil and v.spec_aiJobVehicle.job ~= nil)
  end
  v.getIsEntered = function() return opts.entered == true end
  return v
end

local function newHookManager()
  local hm = setmetatable({ hooks = {} }, { __index = HookManager })
  hm.hooks = {}
  return hm
end

-- Drive one application and report what moved.
local function applyOnce(hm, v)
  tank = 1000
  resetMoney()
  v._sfF196DrainToken = { fuIdx = FU_IDX, delta = DELTA,
                          fillType = CUSTOM_IDX }
  local reported = FillUnit.addFillUnitFillLevel(v, 1, FU_IDX, DELTA,
                                                 CUSTOM_IDX, nil, nil)
  return { tankAfter = tank, spent = money, charges = moneyCalls,
           reported = reported }
end

-- Install the real hook onto a fresh fake FillUnit, then publish the price
-- map the wrapper reads at CALL time (the design states the wrapper does not
-- capture it, so setting it after install is faithful, not a shortcut).
local function install(opts)
  opts = opts or {}
  FillUnit = newFillUnitClass()
  g_fillTypeManager = {
    getFillTypeByIndex = function(_, idx)
      if idx == CUSTOM_IDX then return { name = "SOILTEST_DRY" } end
      return { name = "UNKNOWN" }
    end,
  }
  g_currentMission = {
    time = 1000,
    missionInfo = {
      helperBuyFertilizer = (opts.buySetting ~= false),
      helperSlurrySource = 1,
      helperManureSource = 1,
    },
    addMoney = function(_, amount, farmId, moneyType, a, b)
      money = money + amount
      moneyCalls = moneyCalls + 1
    end,
  }
  local hm = newHookManager()
  hm:installPurchaseRefillHook()
  hm:ensureProductTables()
  hm.customProductIndices[CUSTOM_IDX] = true
  hm.customFillTypePrices = { [CUSTOM_IDX] = PRICE }
  return hm
end

-- ══════════════════════════════════════════════════════════
-- 1. THE SYMPTOM, as behaviour: predicate TRUE
--    This is the row CORRECT-821 asked for.
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({ job = true })          -- buy predicate satisfied
  local r = applyOnce(hm, v)

  T.ok("1a: the buy predicate is satisfied, so this row is not vacuous",
       r.charges > 0)
  T.eq("1b: money LEFT the farm", r.spent, -(LITERS * PRICE))
  T.eq("1c: and the tank did NOT move, which together with 1b is exactly the "
       .. "#1098 symptom", tank, 1000)
  T.eq("1d: while the wrapper still REPORTED the delta as applied, which is "
       .. "why native onEndWorkAreaProcessing believes the product was used",
       r.reported, DELTA)
end

-- ══════════════════════════════════════════════════════════
-- 2. Predicate FALSE: the correct behaviour, and the control for group 1
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({})                      -- no AI of any kind
  local r = applyOnce(hm, v)

  T.eq("2a: a player-driven vehicle with no AI flag is NOT charged",
       r.charges, 0)
  T.eq("2b: no money moved", r.spent, 0)
  T.eq("2c: and the tank DID drain, because the wrapper called through",
       tank, 1000 + DELTA)
  T.ok("2d: so group 1 is measuring the predicate, not the harness",
       tank ~= 1000)
end

-- ══════════════════════════════════════════════════════════
-- 3. The setting off restores the drain even with AI active
-- ══════════════════════════════════════════════════════════
do
  local hm = install({ buySetting = false })
  local v = newVehicle({ job = true })
  local r = applyOnce(hm, v)

  T.eq("3a: with helperBuyFertilizer off nothing is charged", r.charges, 0)
  T.eq("3b: and the tank drains", tank, 1000 + DELTA)
end

-- ══════════════════════════════════════════════════════════
-- 4. A seated player while a worker drives, which the packet says must
--    NOT be treated as manual control
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({ job = true, entered = true })
  local r = applyOnce(hm, v)

  T.ok("4a: a hired worker still buys while the player rides along, so a "
       .. "blanket isEntered rule would break vanilla helper purchase",
       r.charges > 0)
  T.eq("4b: money left the farm as helper purchase intends",
       r.spent, -(LITERS * PRICE))
end

-- ══════════════════════════════════════════════════════════
-- 5. Courseplay-flagged worker: purchase must keep working
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({ cpModern = true })
  local r = applyOnce(hm, v)
  T.ok("5a: a Courseplay-driven worker still buys (modern spec flag)",
       r.charges > 0)

  local hm2 = install()
  local v2 = newVehicle({ cpLegacy = true })
  local r2 = applyOnce(hm2, v2)
  T.ok("5b: and the legacy Courseplay flag too", r2.charges > 0)
end

-- ══════════════════════════════════════════════════════════
-- 6. No duplicate purchase: the token is consumed once
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({ job = true })
  local r = applyOnce(hm, v)
  T.eq("6a: the first application charges once", r.charges, 1)

  -- Second call with no fresh token: the wrapper must fall through.
  resetMoney()
  local before = tank
  FillUnit.addFillUnitFillLevel(v, 1, FU_IDX, DELTA, CUSTOM_IDX, nil, nil)
  T.eq("6b: a second call without a fresh token does NOT charge again",
       moneyCalls, 0)
  T.eq("6c: and it drains normally", tank, before + DELTA)
  T.eq("6d: the token was consumed", v._sfF196DrainToken, nil)
end

-- ══════════════════════════════════════════════════════════
-- 7. CONSTRUCTED stale-job state, with a manual driver
--
--    NOT evidence that the reporter's session reached this. The engine
--    clears spec_aiJobVehicle.job inside aiJobFinished's own
--    `if self:getIsAIActive()` guard, so a job ended by a route that does
--    not reach that call leaves the term set with nobody driving. This row
--    shows what the current predicate does in that state.
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({ job = true, entered = true })   -- player seated
  local r = applyOnce(hm, v)

  T.ok("7a: with a stale job term and a seated player, the predicate is "
       .. "STILL true", r.charges > 0)
  T.eq("7b: money leaves", r.spent, -(LITERS * PRICE))
  T.eq("7c: and the tank does not move, so a stale job term alone reproduces "
       .. "#1098 exactly", tank, 1000)
  T.ok("7d: this row CONSTRUCTS that state and does not prove the reporter "
       .. "reached it", true)
end

-- ══════════════════════════════════════════════════════════
-- 8. The attacher recursion, which the packet asked me to check
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local tractor = { getIsAIActive = function() return true end }
  local implement = newVehicle({ attacher = tractor })
  local r = applyOnce(hm, implement)

  T.ok("8a: a towed implement answers for its ATTACHER, so the predicate can "
       .. "be satisfied from the tractor rather than the implement",
       r.charges > 0)
  T.eq("8b: and the implement's own tank is the one that does not move",
       tank, 1000)
end

-- ══════════════════════════════════════════════════════════
-- 9. The dead route: spec_aiVehicle.isActive does not exist in 1.20
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  local v = newVehicle({})
  v.spec_aiVehicle = {}            -- present but with no isActive field
  local r = applyOnce(hm, v)

  T.eq("9a: an spec_aiVehicle table with no isActive field charges nothing, "
       .. "confirming that route contributes only when a field the 1.20 "
       .. "engine never sets is present", r.charges, 0)
  T.eq("9b: and the tank drains normally", tank, 1000 + DELTA)
end

-- ══════════════════════════════════════════════════════════
-- 10. REPAIR-824: the diagnostic must be truthful and aimable
--
--     Each row below corresponds to one review finding. The first matters
--     most: my 819 report claimed unreadable predicates render "na" while
--     the code rendered them "n", so the report described a discipline the
--     code did not implement.
-- ══════════════════════════════════════════════════════════
local function armDiag(opts)
  opts = opts or {}
  local D = HookManager.DIAG1098
  D.enabled = true
  D.fired = false
  D.armVehicleId = opts.armVehicleId
  D.armProduct = opts.armProduct
  return D
end
local function disarmDiag()
  local D = HookManager.DIAG1098
  D.enabled = false
  D.fired = false
  D.armVehicleId = nil
  D.armProduct = nil
end
local function captureDiag(fn)
  local lines = {}
  local realPrint = print
  print = function(...) lines[#lines + 1] = tostring((...)) end
  local ok, err = pcall(fn)
  print = realPrint
  local out = {}
  for _, l in ipairs(lines) do
    if l:find("[1098-BUY]", 1, true) then out[#out + 1] = l end
  end
  return out, ok, err
end

do
  -- FINDING 1: sampled once, and unknown stays na
  local hm = install()
  local D = armDiag()
  local v = newVehicle({ job = true })
  local calls = 0
  v.getIsSprayerExternallyFilled = function()
    calls = calls + 1
    return false
  end
  local lines = captureDiag(function() applyOnce(hm, v) end)
  disarmDiag()
  T.eq("10a: the external-fill predicate is sampled EXACTLY ONCE",
       calls, 1)
  T.eq("10b: and exactly one diagnostic line is produced", #lines, 1)
  T.ok("10c: a predicate that really is false reads n",
       (lines[1] or ""):find("extFill=n", 1, true) ~= nil)

  -- the same predicate ABSENT must read na, not n
  local hm2 = install()
  armDiag()
  local v2 = newVehicle({ job = true })
  v2.getIsSprayerExternallyFilled = nil
  local lines2 = captureDiag(function() applyOnce(hm2, v2) end)
  disarmDiag()
  T.ok("10d: an ABSENT predicate reads na, not n, which is the discipline "
       .. "my 819 report claimed and the code did not have",
       (lines2[1] or ""):find("extFill=na", 1, true) ~= nil)

  -- and one that RAISES must also read na
  local hm3 = install()
  armDiag()
  local v3 = newVehicle({ job = true })
  v3.getIsSprayerExternallyFilled = function() error("boom") end
  local lines3 = captureDiag(function() applyOnce(hm3, v3) end)
  disarmDiag()
  T.ok("10e: a predicate that RAISES also reads na",
       (lines3[1] or ""):find("extFill=na", 1, true) ~= nil)

  -- vanilla returns a TABLE on success; that must read y, not n
  local hm4 = install()
  armDiag()
  local v4 = newVehicle({ job = true })
  v4.getIsSprayerExternallyFilled = function() return { rootVehicle = true } end
  local lines4 = captureDiag(function() applyOnce(hm4, v4) end)
  disarmDiag()
  T.ok("10f: vanilla's TABLE return reads y, so the renderer does not test "
       .. "== true", (lines4[1] or ""):find("extFill=y", 1, true) ~= nil)
end

do
  -- FINDING 2: planned and observed are separate, and observed is measured
  local hm = install()
  armDiag()
  local v = newVehicle({ job = true })
  v.getFillUnitFillLevel = function() return 1000 end
  local lines = captureDiag(function() applyOnce(hm, v) end)
  disarmDiag()
  local line = lines[1] or ""
  T.ok("10g: the INTENDED charge is labelled plannedCharge",
       line:find("plannedCharge=", 1, true) ~= nil)
  T.ok("10h: and the measured effects are separate fields",
       line:find("moneyObs=", 1, true) ~= nil
       and line:find("tankObs=", 1, true) ~= nil)
  -- 825: the old form accepted moneyObs=0 as well as na, which is exactly
  -- the fabricated zero the planned-vs-observed split exists to prevent.
  -- With no readable balance the field MUST be na and must NOT be 0.
  T.ok("10i: with NO readable balance the observation is na",
       line:find("moneyObs=na", 1, true) ~= nil)
  T.ok("10i2: and is NOT a fabricated zero",
       line:find("moneyObs=0", 1, true) == nil)
end

do
  -- FINDING 3: a non-target decision must NOT consume the one shot
  local hm = install()
  armDiag({ armVehicleId = 777 })
  local other = newVehicle({ job = true })        -- id 42, not the target
  local target = newVehicle({ job = true })
  target.id = 777
  local lines = captureDiag(function()
    applyOnce(hm, other)                          -- must not fire
    applyOnce(hm, target)                         -- must fire
  end)
  disarmDiag()
  T.eq("10j: exactly one line, and the non-target decision did not consume "
       .. "the shot", #lines, 1)
  T.ok("10k: and it is the TARGET vehicle",
       (lines[1] or ""):find("veh=777", 1, true) ~= nil)
end

do
  -- FINDING 4: a diagnostic failure must not reach the billing path
  local hm = install()
  armDiag()
  local v = newVehicle({ job = true })
  -- A root whose getIsEntered raises: the recorder must absorb it.
  v.rootVehicle = { getIsEntered = function() error("hostile root") end }
  local lines, ok = captureDiag(function() applyOnce(hm, v) end)
  disarmDiag()
  T.eq("10l: a raising predicate inside the recorder does NOT propagate "
       .. "into the billing path", ok, true)
  T.ok("10m: and the hostile read is reported as na",
       (lines[1] or ""):find("enteredRoot=na", 1, true) ~= nil)

  -- disabled build: no line at all, and billing still works
  local hm2 = install()
  disarmDiag()
  local v2 = newVehicle({ job = true })
  local lines2 = captureDiag(function()
    local r = applyOnce(hm2, v2)
    T.ok("10n: billing still happens with the diagnostic disabled",
         r.charges > 0)
  end)
  T.eq("10o: and a disabled build emits nothing", #lines2, 0)
end

-- ══════════════════════════════════════════════════════════
-- 11. REPAIR-825: attribution, filter semantics, honest zero
-- ══════════════════════════════════════════════════════════
do
  -- FINDING 1: a TOWED sprayer whose ROOT carries the job. Before this fix
  -- the line read aiActive=y with job=na and the responsible term was
  -- unnamed, which defeats the whole point of the trace.
  local hm = install()
  armDiag()
  local tractor = { id = 900, spec_aiJobVehicle = { job = {} },
                    getIsAIActive = function() return true end }
  local implement = newVehicle({ attacher = tractor })   -- own job: absent
  implement.rootVehicle = tractor
  local lines = captureDiag(function() applyOnce(hm, implement) end)
  disarmDiag()
  local line = lines[1] or ""

  T.ok("11a: the decision was billed through the attacher chain",
       line:find("billed=y", 1, true) ~= nil)
  T.ok("11b: the IMPLEMENT's own job flag is absent, reported as na",
       line:find(" job=na", 1, true) ~= nil)
  T.ok("11c: and the ROOT's job flag is reported as y, so the term that "
       .. "made the predicate true is NAMED",
       line:find("rootJob=y", 1, true) ~= nil)
  T.ok("11d: the root is identified distinctly from the implement",
       line:find("veh=42", 1, true) ~= nil
       and line:find("root=900", 1, true) ~= nil)
  T.ok("11e: and the root's own AI accessor is reported",
       line:find("rootAiActive=y", 1, true) ~= nil)
end

do
  -- FINDING 2: armProduct is a RAW fill-type filter, identical on both
  -- paths. Billed path first.
  local hm = install()
  armDiag({ armProduct = CUSTOM_IDX })
  local v = newVehicle({ job = true })
  local lines = captureDiag(function() applyOnce(hm, v) end)
  disarmDiag()
  T.eq("11f: the raw-type filter matches on the BILLED path", #lines, 1)
  T.ok("11g: and the line reports both the resolved product and the raw type",
       (lines[1] or ""):find("product=", 1, true) ~= nil
       and (lines[1] or ""):find("rawType=", 1, true) ~= nil)

  -- Delegated path: no AI, so the wrapper delegates and still records.
  local hm2 = install()
  armDiag({ armProduct = CUSTOM_IDX })
  local v2 = newVehicle({})
  local lines2 = captureDiag(function() applyOnce(hm2, v2) end)
  disarmDiag()
  T.eq("11h: the SAME filter value matches on the DELEGATED path, which it "
       .. "could not do while the two sites passed different parameters",
       #lines2, 1)
  T.ok("11i: and that path is labelled delegated and not billed",
       (lines2[1] or ""):find("path=f196-delegated", 1, true) ~= nil
       and (lines2[1] or ""):find("billed=n", 1, true) ~= nil)

  -- A non-matching raw type must not fire at all.
  local hm3 = install()
  armDiag({ armProduct = 999999 })
  local v3 = newVehicle({ job = true })
  local lines3 = captureDiag(function() applyOnce(hm3, v3) end)
  disarmDiag()
  T.eq("11j: a non-matching raw type produces no line", #lines3, 0)
end

do
  -- FINDING 3 companion: a genuinely MEASURED zero must still read 0.00,
  -- so the stricter 10i does not simply ban zero.
  local hm = install()
  armDiag()
  local v = newVehicle({ job = true })
  local bal = 5000
  g_currentMission.getMoney = function(_, _) return bal end
  v.getFillUnitFillLevel = function() return 800 end
  local lines = captureDiag(function() applyOnce(hm, v) end)
  disarmDiag()
  local line = lines[1] or ""
  T.ok("11k: a readable balance that did not change reads as a measured "
       .. "0.00, so the stricter test bans fabrication and not zero itself",
       line:find("moneyObs=0.00", 1, true) ~= nil)
  T.ok("11l: and the tank observation is likewise a real measurement",
       line:find("tankObs=0.00", 1, true) ~= nil)
end

-- ══════════════════════════════════════════════════════════
-- 12. TINA'S NATIVE STATE (TEST-RF-SOIL-1098-DIAG826-TINA-007)
--
--     Her one-shot trace, verbatim:
--       path=f196-billed veh=676 root=613 billed=y
--       aiActive=n job=na aiVehActive=y cpModern=na cpLegacy=na
--       rootAiActive=n rootJob=n rootAiVehActive=y
--       fieldwork=n enteredRoot=y
--
--     So NOTHING that means "a helper is driving" was true: no active job,
--     no Courseplay, no fieldwork, the player in the tractor. The only term
--     that was true is spec_aiVehicle.isActive.
--
--     In the 1.20 extract that spec holds agentAttachments and a debug box
--     and has NO isActive at all, so Soil's route 2 reads a field whose
--     meaning it assumes. These rows model her state exactly and must show
--     money unchanged and the tank draining.
-- ══════════════════════════════════════════════════════════
do
  local hm = install()
  -- Her implement: an spec_aiVehicle carrying isActive, and nothing else.
  local v = newVehicle({})
  v.id = 676
  v.spec_aiVehicle = { isActive = true }
  v.getIsEntered = function() return false end          -- no cab, enteredSelf=na
  v.rootVehicle = {
    id = 613,
    spec_aiVehicle = { isActive = true },
    spec_aiJobVehicle = { job = nil },                  -- rootJob=n
    getIsAIActive = function() return false end,        -- rootAiActive=n
    getIsFieldWorkActive = function() return false end, -- fieldwork=n
    getIsEntered = function() return true end,          -- enteredRoot=y
  }
  local r = applyOnce(hm, v)

  T.eq("12a: TINA'S STATE, Buy ON: money must NOT move for a manually "
       .. "driven sprayer with no job, no Courseplay and no fieldwork",
       r.spent, 0)
  T.eq("12b: and the tank MUST drain", tank, 1000 + DELTA)
  T.eq("12c: so the decision must be delegated, not billed", r.charges, 0)
end

do
  -- The semantics that must survive the fix: a REAL hired worker still buys
  -- even though its spec_aiVehicle may also carry isActive.
  local hm = install()
  local v = newVehicle({ job = true })
  v.spec_aiVehicle = { isActive = true }
  local r = applyOnce(hm, v)
  T.ok("12d: a genuine hired worker (active job) STILL buys", r.charges > 0)
  T.eq("12e: and money leaves as helper purchase intends",
       r.spent, -(LITERS * PRICE))
end

do
  -- And Courseplay still buys with no job and no aiVehicle flag at all.
  local hm = install()
  local v = newVehicle({ cpModern = true })
  v.spec_aiVehicle = nil
  local r = applyOnce(hm, v)
  T.ok("12f: a Courseplay worker STILL buys", r.charges > 0)
end

-- ══════════════════════════════════════════════════════════
-- 13. REVIEW-828: the two REMAINING spec_aiVehicle.isActive sites
--
--     827 removed the term from isInBuyMode only. The same unsupported
--     inference still sits in the spray-usage injection and in the backup
--     refill detection. The injection one is the more serious of the two:
--     it can fabricate usage for an otherwise EMPTY pass, which changes
--     APPLICATION and not merely money.
--
--     These rows drive the real Sprayer.onEndWorkAreaProcessing hook with
--     Tina's observed flags: spec_aiVehicle.isActive true, no job, no CP,
--     no fieldwork, manual driving.
-- ══════════════════════════════════════════════════════════
local function newSprayerClass()
  return { onEndWorkAreaProcessing = function() end }
end

local function installAreaHook(hm)
  Sprayer = newSprayerClass()
  g_sprayTypeManager = {
    getSprayTypeByFillTypeIndex = function(_, _)
      return { litersPerSecond = 2 }
    end,
  }
  hm:installSprayerAreaHook()
  return hm
end

-- A manually driven sprayer with Tina's exact flags and an EMPTY pass.
local function newAreaSelf()
  local s = {
    id = 676,
    isServer = true,
    lastSpeed = 10 / 3600,              -- ~10 km/h, above the 0.5 gate
    spec_aiVehicle = { isActive = true },   -- the unsupported term
    ownerFarmId = 1,
    spec_sprayer = {
      usageScale = { workingWidth = 12, default = 1, fillTypeScales = {} },
      workAreaParameters = {
        usage = 0, sprayFillLevel = 0, sprayFillType = CUSTOM_IDX,
        sprayVehicle = {},
      },
    },
  }
  s.getIsAIActive = function() return false end        -- aiActive=n
  s.getIsEntered = function() return false end         -- unoccupied implement
  s.getActiveSprayType = function() return { usageScale =
    { workingWidth = 12, default = 1, fillTypeScales = {} } } end
  s.getWorkAreaWidth = function() return 12 end
  s.getSprayerFillUnitIndex = function() return FU_IDX end
  s.getFillUnitFillType = function() return CUSTOM_IDX end
  s.getFillUnitFillLevel = function() return 1000 end
  s.rootVehicle = s
  return s
end

do
  local hm = install()
  installAreaHook(hm)
  g_SoilFertilityManager = {
    soilSystem = { hookManager = hm },
    settings = { enabled = true, nutrientCycles = true },
  }

  local s = newAreaSelf()
  resetMoney()
  local ok, err = pcall(function()
    Sprayer.onEndWorkAreaProcessing(s, 1000, true)
  end)

  T.ok("13a: the hook ran without raising", ok, tostring(err))
  T.eq("13b: SPRAY-USAGE INJECTION must NOT fabricate usage for a manually "
       .. "driven sprayer on an empty pass",
       s.spec_sprayer.workAreaParameters.usage, 0)
  T.eq("13c: nor a fabricated sprayFillLevel",
       s.spec_sprayer.workAreaParameters.sprayFillLevel, 0)
  T.eq("13d: and no money is taken for that fabricated dose",
       moneyCalls, 0)
end

do
  -- The semantics that must survive: a GENUINE helper still gets the
  -- injection, because that is what buy mode is for.
  local hm = install()
  installAreaHook(hm)
  g_SoilFertilityManager = {
    soilSystem = { hookManager = hm },
    settings = { enabled = true, nutrientCycles = true },
  }

  local s = newAreaSelf()
  s.spec_aiVehicle = nil
  s.spec_aiJobVehicle = { job = {} }          -- a real hired worker
  s.getIsAIActive = function() return true end
  resetMoney()
  local ok = pcall(function()
    Sprayer.onEndWorkAreaProcessing(s, 1000, true)
  end)
  T.ok("13e: the hook ran for the helper case", ok)
  T.ok("13f: a GENUINE hired worker still gets buy-mode usage injected, so "
       .. "the fix does not disable helper buying",
       s.spec_sprayer.workAreaParameters.usage > 0)
end
