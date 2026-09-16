-- RSF-F226d-overlap_nutrient_skip_spec_test.lua
--
-- A pass we blocked for overlap must credit nothing.
--
-- THE DEFECT THIS PINS, which shipped live in #959 and was ungated. Our overlap
-- block stops the engine's two paths: no updateSprayArea so no native ground
-- paint, and isActive stays false so the native tank draw at Sprayer.lua:940
-- never fires. But SoilFertilizer has a THIRD path. installSprayerAreaHook
-- appends to Sprayer.onEndWorkAreaProcessing and credits nutrients and coverage
-- ITSELF, gating on sprayFillLevel > 0 and usage > 0 rather than on isActive.
-- Both of those are computed inside native onStartWorkAreaProcessing (begins
-- Sprayer.lua:855, usage at :928), which runs BEFORE any work area processes and
-- is untouched by our block. So the block cost the player nothing from the tank
-- and the nutrients landed anyway: free fertiliser for driving back over ground
-- already sprayed, with no error and nothing in the log.
--
-- THE TRAP, AND WHY N5-N8 MATTER MORE THAN N1-N4. The obvious fix is to gate the
-- nutrient hook on isActive. That reintroduces #764 exactly. On an already
-- fertilised field vanilla's density map returns changedArea 0, so isActive is
-- false while product genuinely IS consumed, and gating there silently drops
-- every real application. The hook's own comment says so and was written to
-- prevent precisely that fix. N5-N8 are that regression, standing.
--
-- Both sides drive the REAL installer and the REAL appended function, and assert
-- on the REAL downstream calls (soilSystem:onFertilizerApplied for nutrients,
-- soilSystem:trackSprayerCoverage for coverage). A test that checked our own flag
-- would pass against a build where the flag is set and never read.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local savedSprayer, savedUtils = Sprayer, Utils
local savedFT, savedMission, savedSFM = g_fillTypeManager, g_currentMission, g_SoilFertilityManager
local savedEffects = g_effectManager

-- The overlap hook drives boom section effects on both ends of the pass. They are
-- not what this bar is about, but they have to exist for the real hook to run.
g_effectManager = { startEffects = function() end, stopEffects = function() end }

-- The empty-tank residual fix (issue #764's AI-stop half) reads both of these
-- before our skip is reached, so they have to be present for the pass to run.
local savedFillType, savedToolType = FillType, ToolType
FillType = FillType or { UNKNOWN = 0, FERTILIZER = 42 }
ToolType = ToolType or { UNDEFINED = 0 }

Utils = {
    prependedFunction = function(orig, new)
        return function(...) new(...) if orig then return orig(...) end end
    end,
    appendedFunction = function(orig, new)
        return function(...)
            local r = orig and { orig(...) } or {}
            new(...)
            return unpack(r)
        end
    end,
}

g_currentMission = { time = 100000 }
g_fillTypeManager = {
    getFillTypeByName = function(_, n)
        if n == "FERTILIZER" then return { index = 42, name = "FERTILIZER" } end
        return nil
    end,
    getFillTypeByIndex = function(_, i)
        if i == 42 then return { index = 42, name = "FERTILIZER" } end
        return nil
    end,
}

--- Everything the nutrient hook reaches for through hookMgrRef, plus counters for
--- the two downstream credits we actually care about.
local function newWorld(opts)
    opts = opts or {}
    local seen = { fertilizer = 0, coverage = 0, resolved = 0 }

    local soilSys = {
        fieldData = { [7] = { sessionCoverageCells = {}, sessionCoverageFraction = 0.0 } },
        onFertilizerApplied         = function() seen.fertilizer = seen.fertilizer + 1 end,
        trackSprayerCoverage        = function() seen.coverage = seen.coverage + 1 end,
        markBoomCells               = function() end,
        paintBoomStrip              = function() end,
        applyBurnEffect             = function() end,
        applyScorchEffect           = function() end,
        onHerbicideAppliedDirect    = function() end,
        onInsecticideAppliedDirect  = function() end,
        onFungicideAppliedDirect    = function() end,
    }
    -- A CELL MUST ALWAYS BE STAMPED. With sessionCoverageCells empty the prepend
    -- returns long before it reaches the block decision, so a fixture built that
    -- way never exercises the decline path at all: it exits early and looks
    -- identical to a pass that considered blocking and chose not to. Mutation F4
    -- survived on exactly that. The FRACTION is what decides whether the block
    -- arms, so the partial case keeps its cell and lowers the fraction.
    soilSys.fieldData[7].sessionCoverageCells = { ["1:1"] = true }
    soilSys.fieldData[7].sessionCoverageFraction = opts.coverageFraction or 0.5

    g_SoilFertilityManager = {
        settings = { enabled = true, overlapPrevention = true, debugMode = false },
        soilSystem = soilSys,
    }

    local hookMgr = {
        hooks = {},
        register = function() end,
        registerCleanup = function() end,
        getFieldIdAtWorldPosition = function() return 7 end,
        getBoomCellPositions = function() return { { x = 10, z = 10 } } end,
        getBoomLineEndpoints = function() return nil end,
        -- The VWW section loop writes straight into this pre-allocated scratch
        -- table. Leaving it nil throws inside the hook's outer pcall, which looks
        -- exactly like a guard refusing the pass: a silent zero credit.
        _sectionScratch = {},
        _settings = { multiTankApplication = false },
        customFillTypePrices = {},
    }
    return seen, hookMgr
end

--- A sprayer the way the engine builds one, with the three-copy chain for the
--- work area so the overlap block has something real to refuse.
local function newSprayer(opts)
    local classTable = {}
    local v = {
        isServer = true,
        id = "veh1",
        spec_workArea = { workAreas = {} },
        spec_variableWorkWidth = { sections = { { isActive = true } } },
        _sfRootX = 10, _sfRootZ = 10,
        getIsTurnedOn = function() return true end,
        getLastSpeed  = function() return 8.0 end,
        getSprayerFillUnitIndex = function() return 1 end,
        getFillUnitFillLevel = function() return 900 end,
        getFillUnitFillType  = function() return 42 end,
        getOwnerFarmId = function() return 1 end,
        addFillUnitFillLevel = function() return 0 end,
    }
    v.spec_sprayer = {
        workAreaParameters = {
            sprayFillType  = 42,
            usage          = opts.usage,
            sprayFillLevel = opts.fillLevel,
            -- THE #764 SHAPE: the engine painted nothing this frame, so isActive is
            -- false, and product was consumed anyway.
            isActive       = opts.isActive == true,
        },
        effects = {}, sprayTypes = {},
    }
    classTable.processSprayerArea = function() return 250, 3 end
    v.processSprayerArea = classTable.processSprayerArea
    local wa = { functionName = "processSprayerArea" }
    wa.processingFunction = v.processSprayerArea
    table.insert(v.spec_workArea.workAreas, wa)
    return v
end

--- Install both real hooks in the same order the mod does (sprayer area first at
--- the top of the install sequence, overlap prevention later), drive a full pass,
--- and report what the downstream actually got.
local function runPass(opts)
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end }
    local seen, hookMgr = newWorld(opts)
    HookManager.installSprayerAreaHook(hookMgr)
    HookManager.installOverlapPreventionHook(hookMgr)

    local v = newSprayer(opts)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    local drawn = v.spec_workArea.workAreas[1].processingFunction(v, v.spec_workArea.workAreas[1], 16)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    return seen, v, drawn
end

-- ── N: a blocked overlapping pass credits nothing ───────────────────────────
do
    -- Session coverage at 100 percent on the field under the root makes every
    -- section already-sprayed ground, which is what arms the block.
    local seen, v, drawn = runPass({ coverageFraction = 1.0, usage = 12, fillLevel = 900, isActive = false })

    T.eq("N1 THE BLOCK FIRES, so this fixture reaches the case at all", drawn, 0)
    T.eq("N2 and the pass is flagged as blocked", v._sfOverlapBlockedPass, true)
    T.eq("N3 NO NUTRIENTS are credited for ground we never touched", seen.fertilizer, 0)
    T.eq("N4 and no coverage either", seen.coverage, 0)
    T.ok("N4b the skip said so in the log rather than failing silently",
         v._sfOverlapSkipLogAt ~= nil)
end

do
    -- ISSUE #764, STANDING. No overlap, so no block: an ordinary pass on a field
    -- the vanilla density map considers already full. isActive is FALSE and
    -- product IS consumed. This must still credit, and it is the case a fix that
    -- gates on isActive destroys.
    local seen, v, drawn = runPass({ coverageFraction = nil, usage = 12, fillLevel = 900, isActive = false })

    T.eq("N5 nothing is blocked, so the real spray function ran", drawn, 250)
    T.eq("N6 and the pass carries no overlap flag", v._sfOverlapBlockedPass, nil)
    T.ok("N7 #764 STANDS: nutrients are credited though isActive is false", seen.fertilizer > 0)
    T.ok("N8 and so is coverage", seen.coverage > 0)
    T.eq("N8b with no overlap skip logged", v._sfOverlapSkipLogAt, nil)
end

do
    -- The flag is per-pass. A blocked pass must not poison the pass after it,
    -- which is the failure a flag cleared in the wrong place would produce.
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end }
    local seen, hookMgr = newWorld({ coverageFraction = 1.0 })
    HookManager.installSprayerAreaHook(hookMgr)
    HookManager.installOverlapPreventionHook(hookMgr)

    local v = newSprayer({ usage = 12, fillLevel = 900, isActive = false })
    Sprayer.onStartWorkAreaProcessing(v, 16)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.eq("N9 the first pass is blocked and credits nothing", seen.fertilizer, 0)

    -- Now the overlap is gone. Same vehicle, next pass.
    g_SoilFertilityManager.soilSystem.fieldData[7].sessionCoverageFraction = 0.5
    Sprayer.onStartWorkAreaProcessing(v, 16)
    T.eq("N10 the next pass clears the flag at its START", v._sfOverlapBlockedPass, nil)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.ok("N11 and credits normally, so a blocked pass does not poison the next",
         seen.fertilizer > 0)
end

do
    -- THE REASON THIS USES ITS OWN FLAG RATHER THAN _sfSprayAreaBlocked.
    --
    -- _sfSprayAreaBlocked is cleared by the overlap hook's RESTORE append on
    -- onEndWorkAreaProcessing. Whether the nutrient hook can still see it
    -- therefore depends on which append was registered first. In the shipping
    -- install sequence installSprayerAreaHook runs early and
    -- installOverlapPreventionHook much later, so the nutrient append happens to
    -- run before the restore clears it, and reading that flag would work.
    --
    -- It would work by coincidence. This case installs the two hooks in the
    -- OPPOSITE order so the restore append runs FIRST, which is the arrangement
    -- that breaks a fix resting on _sfSprayAreaBlocked. The skip must still hold,
    -- because a live consumable correctness rule must not depend on the
    -- registration order of two appends.
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end }
    local seen, hookMgr = newWorld({ coverageFraction = 1.0 })
    HookManager.installOverlapPreventionHook(hookMgr)   -- restore append FIRST
    HookManager.installSprayerAreaHook(hookMgr)         -- nutrient append SECOND

    local v = newSprayer({ usage = 12, fillLevel = 900, isActive = false })
    Sprayer.onStartWorkAreaProcessing(v, 16)
    local drawn = v.spec_workArea.workAreas[1].processingFunction(v, v.spec_workArea.workAreas[1], 16)
    T.eq("N12 the block still fires under the reversed install order", drawn, 0)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.eq("N13 _sfSprayAreaBlocked has ALREADY been cleared by the restore append",
         v._sfSprayAreaBlocked, nil)
    T.eq("N14 but the skip still held, because it does not read that flag",
         seen.fertilizer, 0)
    T.eq("N15 and no coverage was credited either", seen.coverage, 0)
end

do
    -- THE CLEAR MUST SIT ABOVE EVERY EARLY RETURN IN THE PREPEND, which is what
    -- Iris means by clearing in the current window. A pass whose prepend bails out
    -- before reaching the block decision still has to clear a previous pass's flag,
    -- or the nutrient hook reads a stale one and silently refuses to credit real
    -- work. Here the second pass bails at the overlapPrevention check, the
    -- earliest exit the hook has.
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end }
    local seen, hookMgr = newWorld({ coverageFraction = 1.0 })
    HookManager.installSprayerAreaHook(hookMgr)
    HookManager.installOverlapPreventionHook(hookMgr)

    local v = newSprayer({ usage = 12, fillLevel = 900, isActive = false })
    Sprayer.onStartWorkAreaProcessing(v, 16)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.eq("N16 the first pass is blocked and credits nothing", seen.fertilizer, 0)
    T.eq("N16b and it really did set the flag", v._sfOverlapBlockedPass, true)

    -- The player turns overlap prevention off. The prepend now returns at its
    -- earliest exit, before any block decision.
    g_SoilFertilityManager.settings.overlapPrevention = false
    Sprayer.onStartWorkAreaProcessing(v, 16)
    T.eq("N17 the flag is STILL cleared, though the prepend returned early",
         v._sfOverlapBlockedPass, nil)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.ok("N18 so the pass credits normally instead of inheriting a stale refusal",
         seen.fertilizer > 0)
end

Sprayer, Utils = savedSprayer, savedUtils
g_fillTypeManager, g_currentMission, g_SoilFertilityManager = savedFT, savedMission, savedSFM
g_effectManager = savedEffects
FillType, ToolType = savedFillType, savedToolType
