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
-- THE BLOCK IS THE PERMANENT GATE (RSF-F226 item 3). Every sprayer here reaches it
-- the way production does: installSprayerOverlapGate's class wrap of
-- VehicleSystem.addVehicle, called with the colon call Vehicle.lua:1044 makes. No
-- slot is wrapped by hand.
--
--!load: src/utils/Logger.lua, src/utils/SoilL10n.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local savedSprayer, savedUtils = Sprayer, Utils
local savedFT, savedMission, savedSFM = g_fillTypeManager, g_currentMission, g_SoilFertilityManager
local savedEffects = g_effectManager
local savedVehicleSystem = VehicleSystem

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
        settings = { enabled = true, overlapPrevention = true, debugMode = false, multiTankApplication = false },
        soilSystem = soilSys,
    }

    -- The vehicle system is a Class instance (VehicleSystem.lua:3, :6): the method
    -- lives on the class and the instance reaches it through __index.
    VehicleSystem = { addVehicle = function(_self, _vehicle) return true end }
    g_currentMission = { time = 100000,
        vehicleSystem = setmetatable({ vehicles = {} }, { __index = VehicleSystem }) }

    -- A REAL HookManager underneath, not a bag of fields. The hooks capture `self`
    -- and call its methods (RSF-F196 added resolveCustomProductIntent and the
    -- refused-product table, and a bare table has neither), so a fixture that omits
    -- the class metatable models a manager production never hands the closure. The
    -- fields below still override whatever the class would supply.
    local hookMgr = setmetatable({
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
        customFillTypePrices = {},
        -- Identity mirrors the priced set, which is the pre-F196 world this bar
        -- models: nothing priced here, so nothing custom, and no refusals.
        customProductIndices = {},
        refusedProducts = {},
    }, { __index = HookManager })
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

--- A new sprayer, registered through the production route: the gate reaches its
--- work area through the addVehicle class wrap, never by hand.
local function spawn(opts)
    local v = newSprayer(opts)
    g_currentMission.vehicleSystem:addVehicle(v)
    return v
end

--- Every real hook this bar needs, in the order installAll runs them: the gate
--- (right after harvest), the sprayer area hook, then overlap prevention.
local function installHooks(hookMgr, overlapFirst)
    HookManager.installSprayerOverlapGate(hookMgr)
    if overlapFirst then
        HookManager.installOverlapPreventionHook(hookMgr)
        HookManager.installSprayerAreaHook(hookMgr)
    else
        HookManager.installSprayerAreaHook(hookMgr)
        HookManager.installOverlapPreventionHook(hookMgr)
    end
end

--- Install the real hooks, drive a full pass, and report what the downstream
--- actually got.
local function runPass(opts)
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 250, 3 end }
    local seen, hookMgr = newWorld(opts)
    installHooks(hookMgr)

    local v = spawn(opts)
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
                onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 250, 3 end }
    local seen, hookMgr = newWorld({ coverageFraction = 1.0 })
    installHooks(hookMgr)

    local v = spawn({ usage = 12, fillLevel = 900, isActive = false })
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
    -- THE SKIP DOES NOT DEPEND ON THE ORDER OF THE TWO APPENDS.
    --
    -- The swap this gate replaced kept a second flag that its restore append
    -- cleared, so whether the nutrient hook could still see it depended on which
    -- append was registered first. The flag the skip reads is cleared only at the
    -- START of a pass, and nothing in the end event touches the slot. This case
    -- installs the two hooks in the OPPOSITE order to installAll, so the overlap
    -- append runs FIRST, and the skip must still hold.
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 250, 3 end }
    local seen, hookMgr = newWorld({ coverageFraction = 1.0 })
    installHooks(hookMgr, true)   -- overlap append FIRST, nutrient append SECOND

    local v = spawn({ usage = 12, fillLevel = 900, isActive = false })
    local gate = v.spec_workArea.workAreas[1].processingFunction
    Sprayer.onStartWorkAreaProcessing(v, 16)
    local drawn = gate(v, v.spec_workArea.workAreas[1], 16)
    T.eq("N12 the block still fires under the reversed install order", drawn, 0)
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.eq("N13 the end event left the gate in the slot and the flag set",
         v.spec_workArea.workAreas[1].processingFunction == gate and v._sfOverlapBlockedPass == true, true)
    T.eq("N14 and the skip held", seen.fertilizer, 0)
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
                onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 250, 3 end }
    local seen, hookMgr = newWorld({ coverageFraction = 1.0 })
    installHooks(hookMgr)

    local v = spawn({ usage = 12, fillLevel = 900, isActive = false })
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

do
    -- RSF-F226 FINDING 2: THE FLAG ALONE IS NOT A REFUSAL. The skip reads the ONE
    -- predicate billing and SF-73 read: the flag AND an active gate on the sprayer.
    -- A Sprayer-spec vehicle whose drain comes from another processor (a fertilizing
    -- seeder or cultivator, FertilizingSowingMachine.lua:105) has no
    -- processSprayerArea area, so nothing refuses its pass. The prepend never flags
    -- it (the entry-point bar pins that); this pins the reader, for any other writer
    -- of the flag.
    Sprayer = { onStartWorkAreaProcessing = function() end,
                onEndWorkAreaProcessing = function() end,
                processSprayerArea = function() return 250, 3 end }
    local seen, hookMgr = newWorld({ coverageFraction = 0.5 })
    installHooks(hookMgr)

    local v = newSprayer({ usage = 12, fillLevel = 900, isActive = true })
    v.spec_workArea.workAreas[1].functionName = "processSowingMachineArea"
    g_currentMission.vehicleSystem:addVehicle(v)
    T.eq("N19 a seeder's area carries no sprayer gate", HookManager.hasActiveSprayerGate(v), false)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    v._sfOverlapBlockedPass = true   -- a writer other than the prepend, mid-window
    Sprayer.onEndWorkAreaProcessing(v, 16, true)
    T.ok("N20 the drained product is credited: a flag with no gate refused nothing", seen.fertilizer > 0)
    T.ok("N21 and so is coverage", seen.coverage > 0)
end

Sprayer, Utils = savedSprayer, savedUtils
g_fillTypeManager, g_currentMission, g_SoilFertilityManager = savedFT, savedMission, savedSFM
g_effectManager = savedEffects
FillType, ToolType = savedFillType, savedToolType
VehicleSystem = savedVehicleSystem
