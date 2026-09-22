-- RSF-F226e-blocked_pass_billing_spec_test.lua
--
-- A pass we blocked for overlap must not be billed.
--
-- #964 stopped a blocked pass crediting nutrients. It still COST the player,
-- because external fill is billed inside native onStartWorkAreaProcessing, where
-- getExternalFill is called (Sprayer.lua:889) before any work area processes and
-- so before the block can reach anything. Six places bill there:
--   S1 native slurry buy        Sprayer.lua:407   money
--   S2 native slurry station    Sprayer.lua:413   STORED PRODUCT, not money (DIGESTATE :416)
--   S3 native manure buy        Sprayer.lua:430   money
--   S4 native manure station    Sprayer.lua:436   STORED PRODUCT, not money
--   S5 native fertilizer buy    Sprayer.lua:457   money
--   S6 our own custom-type 1.5x charge in Hook 9                  money
-- Each gets its own fixture, and every fixture is two-sided: the pass before the
-- block and the pass after it MUST bill, so a fixture that never bills at all
-- cannot pass as a suppression.
--
-- WHAT IS REAL AND WHAT IS A MODEL. The Hook 9 installer, its live-vehicle
-- propagation and the overlap prepend are the shipping code. The engine side is a
-- MODEL, written against the decompile: getExternalFill follows Sprayer.lua:383-465
-- and onStartWorkAreaProcessing follows :855-935 for the lines that matter here
-- (the tank read, the :889 call, the :890-900 branch on its return and the
-- :925-935 writes into workAreaParameters). The model is what lets S1-S5 be
-- separate cases rather than one "the original was not called" assertion.
--
-- THREE PASSES BLOCKED IN A ROW, NOT ONE. Returning (UNKNOWN, 0) on a blocked pass
-- looks right for one frame. It writes UNKNOWN into wap.sprayFillType, the next
-- prepend reads that stale value and returns before its block decision, and the
-- second frame is billed. One blocked frame cannot see that; the third can.
--
-- AND ONLY WHILE THE PRODUCT IS THE SAME ONE (Bob, #965 review). Repeating the
-- last billed type after the tank switched to an untracked product (herbicide)
-- kept the old trackable type in wap, so the prepend blocked the herbicide on
-- every pass. Group L pins that; group D pins the opposite case, a tank that runs
-- dry part way through a blocked stretch, which must keep repeating.
--
-- EVERY CASE RUNS INSIDE group(), so a Lua error fails a named row and the cases
-- after it still report, instead of the suite discarding the whole file.
--
--!load: src/utils/Logger.lua, src/config/Constants.lua, src/config/SoilBlends.lua, src/ReleaseGate.lua, src/ResistanceBands.lua, src/HybridStrains.lua, src/utils/SoilUtils.lua, src/SoilFertilitySystem.lua, src/hooks/HookManager.lua

local saved = {
    Sprayer = Sprayer, Utils = Utils, FillType = FillType, ToolType = ToolType,
    MoneyType = MoneyType, UIHelper = UIHelper,
    g_fillTypeManager = g_fillTypeManager, g_currentMission = g_currentMission,
    g_SoilFertilityManager = g_SoilFertilityManager, g_effectManager = g_effectManager,
    g_farmManager = g_farmManager, g_sprayTypeManager = g_sprayTypeManager,
    g_vehicleTypeManager = g_vehicleTypeManager,
}

-- The engine's own wrappers, as they are (utils/Utils.lua:380-393): the appended
-- form DISCARDS the old function's returns, and either form returns newFunc
-- itself when there is nothing to wrap.
Utils = {
    appendedFunction = function(oldFunc, newFunc)
        return oldFunc ~= nil and function(...) oldFunc(...) newFunc(...) end or newFunc
    end,
    prependedFunction = function(oldFunc, newFunc)
        return oldFunc ~= nil and function(...) newFunc(...) oldFunc(...) end or newFunc
    end,
}

FillType = { UNKNOWN = 0, LIQUIDMANURE = 10, DIGESTATE = 11, MANURE = 12,
             LIQUIDFERTILIZER = 41, FERTILIZER = 42, HERBICIDE = 43, LIME = 44, UREA = 200 }
ToolType = { UNDEFINED = 0 }
MoneyType = { PURCHASE_FERTILIZER = "PURCHASE_FERTILIZER" }
UIHelper = { formatCurrencyValue = function(v) return tostring(v) end }
g_effectManager = { startEffects = function() end, stopEffects = function() end }
g_vehicleTypeManager = nil

local NAMES = {}
for name, index in pairs(FillType) do NAMES[index] = name end
g_fillTypeManager = {
    getFillTypeByName  = function(_, n) local i = FillType[n] if i then return { index = i, name = n } end return nil end,
    getFillTypeByIndex = function(_, i) local n = NAMES[i] if n then return { index = i, name = n } end return nil end,
}
g_sprayTypeManager = {
    getSprayTypeByFillTypeIndex      = function() return { litersPerSecond = 1 } end,
    getSprayTypeIndexByFillTypeIndex = function(_, ft) return ft end,
}

--- Everything the pass touches, with a ledger of every charge and withdrawal.
local function newWorld(opts)
    local books = { money = 0, charges = 0, withdrawn = 0, stats = 0 }

    local function station(stock)
        return {
            stock = stock,
            -- LoadingStation:removeFillLevel returns the REMAINING delta, not the
            -- amount removed (LoadingStation.lua:220-234).
            removeFillLevel = function(st, _fillType, delta, _farmId)
                local take = math.min(st.stock, delta)
                st.stock = st.stock - take
                books.withdrawn = books.withdrawn + take
                return delta - take
            end,
        }
    end

    g_currentMission = {
        time = 100000,
        missionInfo = {
            helperSlurrySource  = opts.slurrySource or 1,
            helperManureSource  = opts.manureSource or 1,
            helperBuyFertilizer = opts.buyFertilizer == true,
        },
        economyManager = { getCostPerLiter = function() return 1 end },
        addMoney = function(_, amount)
            books.money = books.money + amount
            books.charges = books.charges + 1
        end,
        liquidManureLoadingStations = { station(100000) },
        manureLoadingStations       = { station(100000) },
        vehicleSystem = { vehicles = {} },
    }
    g_farmManager = { updateFarmStats = function() books.stats = books.stats + 1 end }

    g_SoilFertilityManager = {
        settings = { enabled = true, overlapPrevention = true, debugMode = false },
        soilSystem = { fieldData = { [7] = {
            -- A CELL MUST ALWAYS BE STAMPED, or the prepend returns before its block
            -- decision and every pass looks unblocked for the wrong reason.
            sessionCoverageCells = { ["1:1"] = true },
            sessionCoverageFraction = 0.5,
        } } },
    }

    -- A REAL HookManager underneath, not a bag of fields. billedExternalFill now
    -- resolves identity through self:resolveCustomProductIntent (RSF-F196 R3a), so a
    -- fixture without the class metatable hands the closure a manager production
    -- never does. Identity mirrors the priced set: UREA is the one custom product
    -- this bar knows, and nothing is refused.
    local hookMgr = setmetatable({
        register = function() end,
        registerCleanup = function() end,
        getFieldIdAtWorldPosition = function() return 7 end,
        customFillTypePrices = { [FillType.UREA] = 2.0 },
        customProductIndices = { [FillType.UREA] = true },
        refusedProducts = {},
    }, { __index = HookManager })
    return books, hookMgr
end

local function setCoverage(fraction)
    g_SoilFertilityManager.soilSystem.fieldData[7].sessionCoverageFraction = fraction
end

-- ── The engine model ────────────────────────────────────────────────────────

--- Sprayer:getExternalFill, Sprayer.lua:383-465.
local function nativeGetExternalFill(self, fillType, dt)
    local found = false
    local fui = self:getSprayerFillUnitIndex()
    local allowLiquidManure     = self:getFillUnitAllowsFillType(fui, FillType.LIQUIDMANURE)
    local allowDigestate        = self:getFillUnitAllowsFillType(fui, FillType.DIGESTATE)
    local allowManure           = self:getFillUnitAllowsFillType(fui, FillType.MANURE)
    local allowLiquidFertilizer = self:getFillUnitAllowsFillType(fui, FillType.LIQUIDFERTILIZER)
    local allowFertilizer       = self:getFillUnitAllowsFillType(fui, FillType.FERTILIZER)
    local allowHerbicide        = self:getFillUnitAllowsFillType(fui, FillType.HERBICIDE)
    local usage = 0
    local farmId = self:getActiveFarm()
    local statsFarmId = self:getLastTouchedFarmlandFarmId()
    local mi = g_currentMission.missionInfo

    if fillType == FillType.LIQUIDMANURE or (fillType == FillType.DIGESTATE
       or fillType == FillType.UNKNOWN and (allowLiquidManure or allowDigestate)) then
        if mi.helperSlurrySource == 2 then
            found = true
            fillType = FillType.LIQUIDMANURE
            usage = self:getSprayerUsage(fillType, dt)
            if self.isServer then
                local price = usage * 1 * 1.5
                g_farmManager:updateFarmStats(statsFarmId, "expenses", price)
                g_currentMission:addMoney(-price, farmId, MoneyType.PURCHASE_FERTILIZER)
            end
        elseif mi.helperSlurrySource > 2 then
            local st = g_currentMission.liquidManureLoadingStations[mi.helperSlurrySource - 2]
            if self.isServer and st ~= nil then
                usage = self:getSprayerUsage(FillType.LIQUIDMANURE, dt)
                if usage - st:removeFillLevel(FillType.LIQUIDMANURE, usage, farmId) > 1e-6 then
                    found = true
                    fillType = FillType.LIQUIDMANURE
                end
            end
        end
    elseif fillType == FillType.MANURE or fillType == FillType.UNKNOWN and allowManure then
        if mi.helperManureSource == 2 then
            found = true
            fillType = FillType.MANURE
            usage = self:getSprayerUsage(fillType, dt)
            if self.isServer then
                local price = usage * 1 * 1.5
                g_farmManager:updateFarmStats(statsFarmId, "expenses", price)
                g_currentMission:addMoney(-price, farmId, MoneyType.PURCHASE_FERTILIZER)
            end
        elseif mi.helperManureSource > 2 then
            local st = g_currentMission.manureLoadingStations[mi.helperManureSource - 2]
            if self.isServer and st ~= nil then
                usage = self:getSprayerUsage(FillType.MANURE, dt)
                if usage - st:removeFillLevel(FillType.MANURE, usage, farmId) > 1e-6 then
                    found = true
                    fillType = FillType.MANURE
                end
            end
        end
    elseif (fillType == FillType.FERTILIZER or (fillType == FillType.LIQUIDFERTILIZER
           or (fillType == FillType.HERBICIDE or (fillType == FillType.LIME
           or fillType == FillType.UNKNOWN and (allowLiquidFertilizer or (allowFertilizer or allowHerbicide))))))
           and mi.helperBuyFertilizer then
        found = true
        if fillType == FillType.UNKNOWN then
            if allowLiquidFertilizer then fillType = FillType.LIQUIDFERTILIZER
            elseif allowFertilizer then fillType = FillType.FERTILIZER
            elseif allowHerbicide then fillType = FillType.HERBICIDE end
        end
        usage = self:getSprayerUsage(fillType, dt)
        if self.isServer then
            local price = usage * 1 * 1.5
            g_farmManager:updateFarmStats(statsFarmId, "expenses", price)
            g_currentMission:addMoney(-price, farmId, MoneyType.PURCHASE_FERTILIZER)
        end
    end
    if found then
        return fillType, usage
    end
    return FillType.UNKNOWN, 0
end

--- The parts of Sprayer:onStartWorkAreaProcessing (:855-935) this bar depends on.
local function nativeOnStart(self, dt)
    local spec = self.spec_sprayer
    local fui = self:getSprayerFillUnitIndex()
    local sprayVehicle, sprayVehicleFillUnitIndex = nil, nil
    local fillType = self:getFillUnitFillType(fui)
    local usage = self:getSprayerUsage(fillType, dt)
    local sprayFillLevel = self:getFillUnitFillLevel(fui)
    if sprayFillLevel > 0 then
        sprayVehicle = self
        sprayVehicleFillUnitIndex = fui
    end
    local externalFillType, externalUsage
    if self:getIsSprayerExternallyFilled() and self:getIsTurnedOn() then
        externalFillType, externalUsage = self:getExternalFill(fillType, dt)   -- :889
        if externalFillType == FillType.UNKNOWN then                          -- :890
            externalUsage = sprayFillLevel
            externalFillType = fillType
        else
            sprayVehicle = nil
            sprayVehicleFillUnitIndex = nil
            usage = externalUsage
        end
    else
        externalUsage = sprayFillLevel
        externalFillType = fillType
    end
    local wap = spec.workAreaParameters
    wap.sprayFillType = externalFillType                                      -- :926
    wap.sprayFillLevel = externalUsage
    wap.usage = usage
    wap.sprayVehicle = sprayVehicle
    wap.sprayVehicleFillUnitIndex = sprayVehicleFillUnitIndex
    wap.isActive = false
end

--- Sprayer:processSprayerArea, the :314-330 guards.
local function nativeProcessSprayerArea(self, _workArea)
    local wap = self.spec_sprayer.workAreaParameters
    if self:getIsAIActive() and self.isServer and (wap.sprayFillType == nil or wap.sprayFillType == FillType.UNKNOWN) then
        self.rootVehicle.aiStops = self.rootVehicle.aiStops + 1                -- :316
        return 0, 0
    end
    if wap.sprayFillLevel <= 0 then return 0, 0 end                           -- :320
    wap.isActive = true
    return 250, 3
end

--- A sprayer with the three-copy chain for each work area, so the block has a
--- real captured pointer to swap. `functionNames` lets a case declare an area
--- under another name, which is how a mod alias reaches processSprayerArea.
local function newSprayer(opts)
    local tankType  = opts.tankType or FillType.UNKNOWN
    local tankLevel = opts.tankLevel or 0
    local allows = {}
    for _, ft in ipairs(opts.allows or {}) do allows[ft] = true end

    local v = {
        isServer = true,
        id = "veh1",
        lastSpeed = 8 / 3600,           -- 8 km/h in the engine's m/ms
        rootVehicle = { aiStops = 0 },
        spec_workArea = { workAreas = {} },
        spec_variableWorkWidth = { sections = { { isActive = true } } },
        _sfRootX = 10, _sfRootZ = 10,
        _soilLastCustomFillType = opts.lastCustom,
        getIsTurnedOn = function() return true end,
        getIsAIActive = function() return opts.ai == true end,
        getIsSprayerExternallyFilled = function() return true end,
        getSprayerFillUnitIndex = function() return 1 end,
        getFillUnitFillType  = function() return tankType end,
        -- RSF-F196 R1b: the empty-tank identity this bar used to model through the
        -- private _soilLastCustomFillType stamp now flows through the engine's own
        -- retained lastValidFillType (FillUnit.lua:699, synced at :482/:541). The
        -- stamp line above is left so the bar still proves a stale stamp is ignored.
        getFillUnitLastValidFillType = function() return opts.lastCustom or tankType end,
        getFillUnitFillLevel = function() return tankLevel end,
        getFillUnitAllowsFillType = function(_, _fui, ft) return allows[ft] == true end,
        getSprayerUsage = function() return 12 end,
        getActiveFarm = function() return 1 end,
        getLastTouchedFarmlandFarmId = function() return 1 end,
        getOwnerFarmId = function() return 1 end,
        getActiveSprayType = function() return nil end,
    }
    v.spec_sprayer = {
        usageScale = { workingWidth = 12, default = 1 },
        workAreaParameters = { sprayFillType = opts.startType or FillType.UNKNOWN,
                               sprayFillLevel = 0, usage = 0, isActive = false },
    }
    -- The instance copy of getExternalFill, the way copyTypeFunctionsInto leaves
    -- it. The real propagation step must replace it, or nothing below is reached.
    v.getExternalFill = nativeGetExternalFill
    v.processSprayerArea = nativeProcessSprayerArea
    for _, name in ipairs(opts.functionNames or { "processSprayerArea" }) do
        v[name] = v[name] or nativeProcessSprayerArea
        table.insert(v.spec_workArea.workAreas, { functionName = name, processingFunction = v[name] })
    end
    return v
end

--- Install the real hooks the way the mod does, on a fresh engine model.
local function install(opts)
    Sprayer = {
        getExternalFill = nativeGetExternalFill,
        onStartWorkAreaProcessing = nativeOnStart,
        onEndWorkAreaProcessing = function() end,
    }
    local books, hookMgr = newWorld(opts)
    local v = newSprayer(opts)
    g_currentMission.vehicleSystem.vehicles = { v }

    HookManager.installExternalFillHook(hookMgr)
    HookManager.propagateExternalFillHookToLiveVehicles(hookMgr)
    HookManager.installOverlapPreventionHook(hookMgr)
    return books, v
end

--- One frame, in the engine's order: start event, every captured pointer, end
--- event. `skipEnd` models a throw inside the work-area loop, which skips the end
--- event because WorkArea.lua:183 has no pcall.
local function frame(v, skipEnd)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    local sprayed = 0
    for _, wa in ipairs(v.spec_workArea.workAreas) do
        sprayed = sprayed + (wa.processingFunction(v, wa, 16))
    end
    if not skipEnd then Sprayer.onEndWorkAreaProcessing(v, 16, true) end
    return sprayed
end

local function billed(books) return books.charges + books.withdrawn end

--- The two-sided shape every site shares.
--- Pass 1 unblocked MUST bill. Passes 2-4 blocked MUST NOT. Pass 5 unblocked MUST bill.
local function siteCase(tag, opts, measure)
    local books, v = install(opts)
    T.ok(tag .. "a propagation replaced the instance copy, so the wrapper is what runs",
         v.getExternalFill ~= nativeGetExternalFill)

    setCoverage(0.5)
    local sprayed1 = frame(v)
    local after1 = measure(books)
    T.ok(tag .. "b an UNBLOCKED pass is billed, so this fixture reaches the site at all", after1 > 0)
    T.ok(tag .. "c and it sprayed", sprayed1 > 0)

    setCoverage(1.0)
    local sprayedBlocked = frame(v) + frame(v) + frame(v)
    T.eq(tag .. "d the block really fired on all three passes", sprayedBlocked, 0)
    T.eq(tag .. "e THREE BLOCKED PASSES IN A ROW BILL NOTHING", measure(books), after1)
    T.ok(tag .. "f wap still names a real fill type, so the next prepend can block again",
         v.spec_sprayer.workAreaParameters.sprayFillType ~= FillType.UNKNOWN)

    setCoverage(0.5)
    frame(v)
    T.ok(tag .. "g and billing resumes on the first unblocked pass after", measure(books) > after1)
    return books, v
end

--- Run one case. A Lua error inside it fails as a NAMED row for that case, and
--- the cases after it still run and report. Without this, a mutation that breaks
--- the return shape stops the whole file at its first error, and the suite then
--- discards every row the file had already printed, so the mutation dies on an
--- error instead of on a name.
local function group(tag, fn)
    local ok, err = pcall(fn)
    T.eq(tag .. "x the case ran to its end without a Lua error", ok and "clean" or tostring(err), "clean")
end

-- ── S: each of the six billing sites ────────────────────────────────────────

group("S1", function()
    siteCase("S1", { ai = true, slurrySource = 2, allows = { FillType.LIQUIDMANURE } },
        function(b) return b.charges end)
end)

group("S2", function()
    local books = siteCase("S2", { ai = true, slurrySource = 3, allows = { FillType.LIQUIDMANURE } },
        function(b) return b.withdrawn end)
    T.eq("S2h the station path is PRODUCT, and no money moved on it at all", books.charges, 0)
end)

group("S3", function()
    siteCase("S3", { ai = true, manureSource = 2, allows = { FillType.MANURE } },
        function(b) return b.charges end)
end)

group("S4", function()
    local books = siteCase("S4", { ai = true, manureSource = 3, allows = { FillType.MANURE } },
        function(b) return b.withdrawn end)
    T.eq("S4h the station path is PRODUCT, and no money moved on it at all", books.charges, 0)
end)

group("S5", function()
    siteCase("S5", { ai = true, buyFertilizer = true, allows = { FillType.LIQUIDFERTILIZER } },
        function(b) return b.charges end)
end)

group("S6", function()
    -- Our own charge, in the shape it actually takes: an AI helper in buy mode with
    -- an EMPTY tank, which reports UNKNOWN, so Hook 9 finds the product through the
    -- _soilLastCustomFillType stamp the sprayer-area hook leaves, charges its own
    -- price and never calls the original. A tank still reporting UREA would hide the
    -- every-other-frame defect, because native's tank fallback would put UREA back
    -- into wap by itself.
    local books, v = siteCase("S6", { ai = true, buyFertilizer = true, lastCustom = FillType.UREA,
                                      allows = { FillType.UREA } },
        function(b) return b.charges end)
    T.eq("S6h and the type it kept in wap is the custom one, not a vanilla fallback",
         v.spec_sprayer.workAreaParameters.sprayFillType, FillType.UREA)
    T.eq("S6i no station product moved for a custom type", books.withdrawn, 0)
end)

-- ── F: what the skip keys on ────────────────────────────────────────────────

group("F1", function()
    -- THE FLAG WITHOUT A SWAP. An area declared under another functionName is not
    -- swapped by the block (the name is pure XML, WorkArea.lua:257-266), but the
    -- overlap prepend sets the pass flag anyway. That area sprays, so the pass
    -- must be billed.
    local books, v = install({ ai = true, buyFertilizer = true, allows = { FillType.LIQUIDFERTILIZER },
                               functionNames = { "processSprayerAreaAlias" } })
    setCoverage(0.5)
    frame(v)
    local before = books.charges
    setCoverage(1.0)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    T.eq("F1 the prepend flagged the pass", v._sfOverlapBlockedPass, true)
    -- Read from the block's own record, not from the helper under test.
    local rec = v.spec_workArea.workAreas[1]._sfBlocked
    T.ok("F2 but swapped nothing, so the block is not in effect",
         rec == nil or rec.processSprayerArea == nil)
    T.ok("F3 THE PASS IS BILLED, because the alias area is about to spray", books.charges > before)
    local wa = v.spec_workArea.workAreas[1]
    T.ok("F4 and it does spray", wa.processingFunction(v, wa, 16) > 0)
end)

group("F5", function()
    -- THE SWAP WITHOUT THE FLAG. A throw inside the work-area loop skips the end
    -- event, so the restore does not run and the block record outlives its pass.
    -- The next pass clears the flag at its start and, with the overlap gone, does
    -- not block again. That pass is NOT ours to refuse: the nutrient hook's skip
    -- keys on the flag, and zero usage without the flag reaches its buy-mode
    -- injection (AI-1), which credits nutrients for a pass nobody paid for.
    local books, v = install({ ai = true, buyFertilizer = true, allows = { FillType.LIQUIDFERTILIZER } })
    setCoverage(0.5)
    frame(v)
    setCoverage(1.0)
    frame(v, true)                      -- blocked, and the end event never runs
    local before = books.charges
    local rec = v.spec_workArea.workAreas[1]._sfBlocked
    T.ok("F5 the block record survived the skipped restore",
         rec ~= nil and rec.processSprayerArea ~= nil)

    setCoverage(0.5)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    T.eq("F6 the next pass cleared the flag", v._sfOverlapBlockedPass, nil)
    T.ok("F7 SO IT IS BILLED, and never handed zero usage without the flag", books.charges > before)
    T.ok("F8 with real usage in wap for the nutrient hook to read",
         v.spec_sprayer.workAreaParameters.usage > 0)
end)

group("R", function()
    -- THE REPEATED TYPE IS THE LAST ONE BILLED, INCLUDING UNKNOWN. Buy mode off,
    -- product in the tank: the original returns UNKNOWN and native falls back to the
    -- tank (:890-892), drawing from sprayVehicle = self. A blocked pass must leave
    -- native on that same fallback. Repeating wap's own type instead would push it
    -- onto the external branch, which clears sprayVehicle.
    local books, v = install({ ai = true, buyFertilizer = false, tankType = FillType.LIQUIDFERTILIZER,
                               tankLevel = 900, allows = { FillType.LIQUIDFERTILIZER } })
    setCoverage(0.5)
    frame(v)
    T.eq("R1 buy mode is off, so the original resolved nothing external", v._sfLastExternalFillType, FillType.UNKNOWN)
    T.eq("R2 and native drew from the tank", v.spec_sprayer.workAreaParameters.sprayVehicle, v)

    setCoverage(1.0)
    frame(v)
    local wap = v.spec_sprayer.workAreaParameters
    T.eq("R3 a blocked pass keeps native on the tank fallback", wap.sprayVehicle, v)
    T.eq("R4 with the tank's own type", wap.sprayFillType, FillType.LIQUIDFERTILIZER)
    T.eq("R5 and nothing was billed on either pass", billed(books), 0)
end)

group("U", function()
    -- NEVER BILLED YET. A blocked pass can arrive before this wrapper has ever
    -- reached the billing path on this sprayer: product sprayed by hand from the
    -- tank covered the field, then a helper is hired in buy mode, and its first
    -- externally filled pass is already blocked. There is no last return to
    -- repeat, so the rule falls back to UNKNOWN, which puts native on the tank
    -- fallback (:890-892), the branch the engine itself takes when nothing
    -- external was found. Every other fixture bills first, so without this one
    -- the fallback is unreachable and any value there would pass.
    local books, v = install({ ai = true, buyFertilizer = true, tankType = FillType.LIQUIDFERTILIZER,
                               tankLevel = 900, startType = FillType.LIQUIDFERTILIZER,
                               allows = { FillType.LIQUIDFERTILIZER } })
    T.eq("U1 the wrapper has never reached the billing path on this sprayer", v._sfLastExternalFillType, nil)

    setCoverage(1.0)
    local sprayed = frame(v) + frame(v) + frame(v)
    local wap = v.spec_sprayer.workAreaParameters
    T.eq("U2 the block fired on its first three passes", sprayed, 0)
    T.eq("U3 and nothing was billed", billed(books), 0)
    T.eq("U4 NATIVE IS ON THE TANK FALLBACK, not handed an external type it never resolved",
         wap.sprayVehicle, v)
    T.eq("U5 with the tank's own type, so the next prepend can block again", wap.sprayFillType, FillType.LIQUIDFERTILIZER)
    T.eq("U6 blocked passes record nothing", v._sfLastExternalFillType, nil)

    setCoverage(0.5)
    frame(v)
    T.ok("U7 and the first unblocked pass is billed", books.charges > 0)
    T.eq("U8 which is the pass that records a type to repeat", v._sfLastExternalFillType, FillType.LIQUIDFERTILIZER)
end)

group("A", function()
    -- THE AI IS NOT STOPPED. A vehicle with a swapped area AND an alias area: on a
    -- blocked buy-mode pass the alias area still runs the real processSprayerArea.
    -- With a real repeated type it returns at :320, not at the out-of-fill stop at
    -- :316, which fires only on UNKNOWN.
    local books, v = install({ ai = true, buyFertilizer = true, allows = { FillType.LIQUIDFERTILIZER },
                               functionNames = { "processSprayerArea", "processSprayerAreaAlias" } })
    setCoverage(0.5)
    frame(v)
    local before = books.charges
    setCoverage(1.0)
    local sprayed = frame(v) + frame(v) + frame(v)
    T.eq("A1 three blocked passes, the alias area included, put nothing down", sprayed, 0)
    T.eq("A2 and bill nothing", books.charges, before)
    T.eq("A3 AND THE HELPER IS NEVER STOPPED FOR OUT OF FILL", v.rootVehicle.aiStops, 0)
end)

-- ── L and D: when the product in the tank changes during a blocked stretch ──

group("L", function()
    -- A DIFFERENT PRODUCT OVER COVERED GROUND (Bob, #965 review). The helper buys
    -- fertiliser from an empty tank and is billed, blocks over ground covered this
    -- session, then the tank is filled with herbicide. Herbicide is not a product
    -- the overlap rule tracks, so the block must let go of it within one pass.
    -- Repeating the last billed type put LIQUIDFERTILIZER back into wap on every
    -- pass, the prepend kept blocking on it, and the herbicide never went down.
    local books, v = install({ ai = true, buyFertilizer = true,
                               allows = { FillType.LIQUIDFERTILIZER, FillType.HERBICIDE } })
    setCoverage(0.5)
    frame(v)
    T.eq("L1 the helper bought fertiliser from an empty tank", v._sfLastExternalFillType, FillType.LIQUIDFERTILIZER)
    setCoverage(1.0)
    T.eq("L2 and blocked over covered ground", frame(v) + frame(v), 0)
    local before = billed(books)

    v.getFillUnitFillType  = function() return FillType.HERBICIDE end
    v.getFillUnitFillLevel = function() return 900 end
    local switchPass = frame(v)
    local wap = v.spec_sprayer.workAreaParameters
    T.eq("L3 the pass that meets the herbicide was still blocked, on the old type", switchPass, 0)
    T.eq("L4 and billed nothing", billed(books), before)
    T.eq("L5 WAP NAMES THE HERBICIDE AFTER ONE PASS, not the repeated fertiliser", wap.sprayFillType, FillType.HERBICIDE)

    local after = frame(v)
    T.eq("L6 so the next pass is not blocked", v._sfOverlapBlockedPass, nil)
    T.ok("L7 AND THE HERBICIDE GOES DOWN", after > 0)
    T.ok("L8 billed, because herbicide really was sprayed on that pass", billed(books) > before)
    T.eq("L9 and herbicide is now the type on record", v._sfLastExternalFillType, FillType.HERBICIDE)
end)

group("D", function()
    -- THE TANK RUNS DRY PART WAY THROUGH A BLOCKED STRETCH. The argument native
    -- passes goes from the tank's product to UNKNOWN. That is still the same helper
    -- buying the same product, and UNKNOWN is exactly the stale value the repeat
    -- keeps out of wap: returning UNKNOWN there would bill the pass after it, and
    -- an area the block did not swap would stop the helper for out of fill at :316.
    local books, v = install({ ai = true, buyFertilizer = true, tankType = FillType.LIQUIDFERTILIZER,
                               tankLevel = 900, allows = { FillType.LIQUIDFERTILIZER },
                               functionNames = { "processSprayerArea", "processSprayerAreaAlias" } })
    setCoverage(0.5)
    frame(v)
    T.ok("D1 billed with fertiliser in the tank", books.charges > 0)
    setCoverage(1.0)
    -- Still full, and the argument is the product the billing path saw. It must
    -- be repeated: UNKNOWN would send native to the tank fallback, whose level
    -- becomes sprayFillLevel, and the alias area would spray on a blocked pass.
    T.eq("D2 a blocked pass with the same product still in the tank puts nothing down", frame(v), 0)
    T.eq("D3 because it repeats the billed product with no fill level",
         v.spec_sprayer.workAreaParameters.sprayFillLevel, 0)
    local before = billed(books)

    v.getFillUnitFillType  = function() return FillType.UNKNOWN end
    v.getFillUnitFillLevel = function() return 0 end
    local sprayed = frame(v) + frame(v) + frame(v)
    T.eq("D4 three blocked passes after the tank ran dry put nothing down", sprayed, 0)
    T.eq("D5 AND BILL NOTHING, so no pass slipped through on a stale UNKNOWN", billed(books), before)
    T.eq("D6 wap still names the product", v.spec_sprayer.workAreaParameters.sprayFillType, FillType.LIQUIDFERTILIZER)
    T.eq("D7 and the helper was never stopped for out of fill", v.rootVehicle.aiStops, 0)
end)

-- ── W: the shape of what the wrapper returns ────────────────────────────────

group("W", function()
    -- Both returns survive the wrapper. Native destructures two at :889.
    local _, v = install({ ai = true, buyFertilizer = true, allows = { FillType.LIQUIDFERTILIZER } })
    setCoverage(0.5)
    local n = select("#", v:getExternalFill(FillType.UNKNOWN, 16))
    T.eq("W1 an unblocked call returns both values", n, 2)
    local ft, usage = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("W2 the resolved type", ft, FillType.LIQUIDFERTILIZER)
    T.eq("W3 and its usage", usage, 12)

    -- And so does a blocked one. A full pass first puts a trackable type into wap
    -- (the direct calls above never touch it); then the start event blocks and,
    -- with no end event, leaves the block record live, so the direct calls below
    -- are blocked calls.
    frame(v)
    setCoverage(1.0)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    T.eq("W4 the calls below are blocked ones", HookManager.isOverlapBlockedPass(v), true)
    T.eq("W5 a blocked call returns exactly two values", select("#", v:getExternalFill(FillType.UNKNOWN, 16)), 2)
    local bft, busage = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("W6 the repeated type", bft, FillType.LIQUIDFERTILIZER)
    T.eq("W7 and a usage that is the number zero", busage, 0)
end)

group("W8", function()
    -- NEVER BILLED, EMPTY TANK. wap still names the product sprayed by hand before
    -- the tank ran dry, so the first externally filled pass blocks. The argument
    -- is UNKNOWN, so the product check cannot decide it; only the never-billed
    -- fallback keeps a nil out of native's fill type.
    local _, v = install({ ai = true, buyFertilizer = true, startType = FillType.LIQUIDFERTILIZER,
                           allows = { FillType.LIQUIDFERTILIZER } })
    setCoverage(1.0)
    Sprayer.onStartWorkAreaProcessing(v, 16)
    T.eq("W8 this sprayer has never been billed", v._sfLastExternalFillType, nil)
    T.eq("W9 the call below is a blocked one", HookManager.isOverlapBlockedPass(v), true)
    local ft, usage = v:getExternalFill(FillType.UNKNOWN, 16)
    T.eq("W10 A NEVER-BILLED BLOCKED CALL RETURNS THE ENGINE'S UNKNOWN, never nil", ft, FillType.UNKNOWN)
    T.eq("W11 with zero usage", usage, 0)
    T.eq("W12 and native wrote UNKNOWN, not nil, into wap", v.spec_sprayer.workAreaParameters.sprayFillType, FillType.UNKNOWN)
end)

Sprayer, Utils, FillType, ToolType = saved.Sprayer, saved.Utils, saved.FillType, saved.ToolType
MoneyType, UIHelper = saved.MoneyType, saved.UIHelper
g_fillTypeManager, g_currentMission = saved.g_fillTypeManager, saved.g_currentMission
g_SoilFertilityManager, g_effectManager = saved.g_SoilFertilityManager, saved.g_effectManager
g_farmManager, g_sprayTypeManager = saved.g_farmManager, saved.g_sprayTypeManager
g_vehicleTypeManager = saved.g_vehicleTypeManager
