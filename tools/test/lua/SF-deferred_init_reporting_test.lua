-- DEFERRED FILL-TYPE INIT: the retry must not report a failure it never established.
--
-- On 2026-09-21 a healthy singleplayer load produced two alarming warnings and a
-- working feature. That combination is a false-bug-report generator, and at least
-- one report was already read as a map compatibility problem. Three defects:
--
-- 1. THE GIVE-UP WAS UNCONDITIONAL. `_deferredRetryCount = 121` was assigned as a
--    "stop" sentinel once spray types completed, and the unconditional `+ 1` at the
--    top of the next tick walked it to 122, which WAS the give-up branch. So the
--    success path and the failure path reached the same warning. Both warnings
--    appear exactly once in a log whose logger does not deduplicate
--    (SoilLogger.warning prints every call), which proves the body ran one tick and
--    retried zero times. The message said "after 120 retries".
--
-- 2. ZERO NAMES CHECKED WAS REPORTED AS ZERO NAMES FOUND. reapplyFillUnitPatch
--    iterated `self._fuSolidNames or {}`. Before installFillUnitHook runs that field
--    is nil, so the loop body never executed, `found` stayed 0 and missingNames
--    stayed empty. The `found == 0` branch then announced "custom fill types still
--    unavailable (missing: )" with nothing after the colon. That empty list in the
--    real log is this bug showing through.
--
-- 3. THE TEXT INVENTED A DIAGNOSIS, volunteering "dedicated server or modded map may
--    have incomplete fill type loading". Nothing at that point had established
--    either. That guess is why a night went into a fill-type cap that was never
--    involved: the engine's own cap error appears zero times across six sessions.
--
-- Timeline this bar encodes, from that log:
--   19:49:55.179  both warnings, during LOAD
--   19:51:24.700  Entered Gameplay, ie. isMissionStarted becomes true only here
--   19:51:28.150  the dependency actually arrives
-- The warnings preceded the mission by ~89s and the dependency by ~93s.
--
-- Drives the real SoilFertilityManager:_updateDeferredInit and the real
-- HookManager:reapplyFillUnitPatch. It does not prove engine timing, rendering, or
-- dedicated-server behaviour; it proves what this code reports for a given state.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua, src/SoilFertilityManager.lua

-- ── Capture what the mod actually logs ───────────────────────────────────────
local logged = { warning = {}, info = {}, debug = {} }
local function captureLogs()
    logged = { warning = {}, info = {}, debug = {} }
    SoilLogger.warning = function(msg, ...)
        local ok, s = pcall(string.format, msg, ...)
        table.insert(logged.warning, ok and s or tostring(msg))
    end
    SoilLogger.info = function(msg, ...)
        local ok, s = pcall(string.format, msg, ...)
        table.insert(logged.info, ok and s or tostring(msg))
    end
    SoilLogger.debug = function(msg, ...)
        local ok, s = pcall(string.format, msg, ...)
        table.insert(logged.debug, ok and s or tostring(msg))
    end
end

local function joined(list) return table.concat(list, " || ") end
local function countMatching(list, needle)
    local n = 0
    for _, s in ipairs(list) do if s:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ── A hook manager whose completion we control ───────────────────────────────
-- opts.sprayComplete  - value for _sprayTypesComplete
-- opts.patchResult    - what reapplyFillUnitPatch returns
-- opts.solidNames     - _fuSolidNames (nil models "installFillUnitHook has not run")
local function newHookManager(opts)
    local hm = {
        _sprayTypesComplete = opts.sprayComplete,
        _fuSolidNames = opts.solidNames,
        calls = { spray = 0, patch = 0, effect = 0, silo = 0 },
    }
    function hm:registerCustomSprayTypes() self.calls.spray = self.calls.spray + 1 end
    function hm:reapplyFillUnitPatch() self.calls.patch = self.calls.patch + 1; return opts.patchResult end
    function hm:reapplyEffectTypeRemap() self.calls.effect = self.calls.effect + 1 end
    function hm:patchExistingSilos() self.calls.silo = self.calls.silo + 1 end
    return hm
end

local function newManager(hm)
    return { soilSystem = { hookManager = hm } }
end

local function setMission(started)
    g_currentMission = { isMissionStarted = started }
end

local TIMEOUT = SoilConstants.TIMING.DEFERRED_INIT_TIMEOUT
local FRAME = 16  -- ms, a normal frame delta

-- ── GROUP A: a load-time tick never reports anything ─────────────────────────
-- This is the regression bar for defect 1. Under the old code this state produced
-- the give-up warning; the mission had not even started.
do
    captureLogs()
    setMission(false)   -- still loading, "Entered Gameplay" has not happened
    local hm = newHookManager({ sprayComplete = true, patchResult = false, solidNames = nil })
    local mgr = newManager(hm)

    -- Far more ticks than the old 120 budget, all of them during load.
    for _ = 1, 500 do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end

    T.eq("A1: nothing is warned during load", #logged.warning, 0)
    T.ok("A2: no give-up claim during load", joined(logged.warning):find("Gave up") == nil)
    T.eq("A3: the retry is still live, not given up", mgr._deferredInitDone, nil)
    T.eq("A4: no mission time has been spent", mgr._deferredInitMs, nil)
    T.eq("A5: it really did keep retrying all 500 ticks", hm.calls.patch, 500)
end

-- ── GROUP B: success is silent and never reaches the give-up branch ──────────
-- The exact shape of the 2026-09-21 defect: spray types complete, and under the old
-- code the next tick warned anyway.
do
    captureLogs()
    setMission(true)
    local hm = newHookManager({ sprayComplete = true, patchResult = true, solidNames = { "UREA" } })
    local mgr = newManager(hm)

    for _ = 1, 50 do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end

    T.eq("B1: success warns nothing at all", #logged.warning, 0)
    T.eq("B2: the deferred init is marked done", mgr._deferredInitDone, true)
    T.eq("B3: work stops after completion, it does not spin", hm.calls.patch, 1)
    T.ok("B4: no give-up text on the success path",
        joined(logged.warning):find("Gave up") == nil)
end

-- ── GROUP C: an incomplete run waits, then gives up ONCE, with facts ─────────
do
    captureLogs()
    setMission(true)
    local hm = newHookManager({ sprayComplete = false, patchResult = false, solidNames = nil })
    local mgr = newManager(hm)

    -- One frame short of the ceiling: still quiet, still trying.
    local ticks = math.floor(TIMEOUT / FRAME)
    for _ = 1, ticks - 1 do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end
    T.eq("C1: silent right up to the ceiling", #logged.warning, 0)
    T.eq("C2: still retrying at the ceiling", mgr._deferredInitDone, nil)

    -- Cross it.
    for _ = 1, 5 do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end
    T.eq("C3: gives up exactly once, not once per frame",
        countMatching(logged.warning, "Gave up"), 1)
    T.eq("C4: marked done so it stops", mgr._deferredInitDone, true)

    local w = joined(logged.warning)
    T.ok("C5: the warning states elapsed mission time", w:find("after gameplay started", 1, true) ~= nil)
    T.ok("C6: it reports sprayTypesComplete as a fact", w:find("sprayTypesComplete=false", 1, true) ~= nil)
    T.ok("C7: it reports the re-patch result as a fact", w:find("fillUnitRepatch=false", 1, true) ~= nil)
    T.ok("C8: it reports whether the hook ever installed", w:find("fillUnitHookInstalled=false", 1, true) ~= nil)

    -- Defect 3: no invented diagnosis.
    T.ok("C9: does not blame a dedicated server", w:lower():find("dedicated server") == nil)
    T.ok("C10: does not blame a modded map", w:lower():find("modded map") == nil)
    T.ok("C11: does not claim a retry count it never performed", w:find("120 retries", 1, true) == nil)
    T.ok("C12: says plainly that it establishes no cause",
        w:find("No cause is established", 1, true) ~= nil)
end

-- ── GROUP D: the ceiling is mission time, and load ticks do not spend it ─────
do
    captureLogs()
    local hm = newHookManager({ sprayComplete = false, patchResult = false, solidNames = nil })
    local mgr = newManager(hm)

    -- Spend well over the timeout while still loading.
    setMission(false)
    local ticks = math.floor(TIMEOUT / FRAME) + 200
    for _ = 1, ticks do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end
    T.eq("D1: a whole timeout's worth of LOAD ticks spends no budget", mgr._deferredInitMs, nil)
    T.eq("D2: and warns nothing", #logged.warning, 0)

    -- Now the mission starts and the dependency arrives 3.45s later, as in the log.
    setMission(true)
    for _ = 1, math.floor(3450 / FRAME) do SoilFertilityManager._updateDeferredInit(mgr, FRAME) end
    T.eq("D3: still no warning 3.45s into gameplay", #logged.warning, 0)

    hm._sprayTypesComplete = true
    hm._fuSolidNames = { "UREA" }
    hm.reapplyFillUnitPatch = function(s) s.calls.patch = s.calls.patch + 1; return true end
    SoilFertilityManager._updateDeferredInit(mgr, FRAME)

    T.eq("D4: it completes when the dependency finally arrives", mgr._deferredInitDone, true)
    T.eq("D5: and it never warned", #logged.warning, 0)
    T.eq("D6: the late completion is reported once, as info",
        countMatching(logged.info, "re-patch complete"), 1)
end

-- ── GROUP E: the real reapplyFillUnitPatch, nil names vs genuinely missing ───
-- Defect 2. These drive the shipped HookManager function, not a model of it.
do
    captureLogs()
    -- E1: _fuSolidNames nil means installFillUnitHook has not run. Nothing was
    -- CHECKED, so nothing may be reported as unavailable.
    local hm = { _fuFm = { getFillTypeIndexByName = function() return nil end } }
    setmetatable(hm, { __index = HookManager })
    local ok, ret = pcall(HookManager.reapplyFillUnitPatch, hm)
    T.ok("E1: the call does not throw with nil names", ok)
    T.eq("E1: it reports not-done", ok and ret, false)
    T.eq("E1: and warns nothing at all", #logged.warning, 0)
    T.ok("E1: it says so at debug level instead",
        countMatching(logged.debug, "has not run yet") == 1)

    -- E2: the empty "(missing: )" line is exactly what must never appear again.
    T.ok("E2: no empty missing-list warning",
        joined(logged.warning):find("missing: )", 1, true) == nil)

    -- E3: names present but none resolvable IS a real finding, and still warns,
    -- naming what it looked for. This is the case the guard is actually for.
    captureLogs()
    local hm2 = {
        _fuFm = { getFillTypeIndexByName = function() return nil end },
        _fuSolidNames = { "UREA", "AN" },
    }
    setmetatable(hm2, { __index = HookManager })
    local ok2, ret2 = pcall(HookManager.reapplyFillUnitPatch, hm2)
    T.ok("E3: the call does not throw", ok2)
    T.eq("E3: it reports not-done", ok2 and ret2, false)
    T.eq("E3: looked-and-found-nothing DOES warn", countMatching(logged.warning, "still unavailable"), 1)
    T.ok("E3: and the warning names what it looked for",
        joined(logged.warning):find("UREA", 1, true) ~= nil)
end
